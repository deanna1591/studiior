-- creates: promo_sale_cents(int, int), promotion_bounds(uuid), plan_price_now_run(uuid, timestamptz), promo_price_reader(uuid), plan_price_now(uuid, timestamptz), plan_prices_now(uuid), promotion_save(uuid, uuid, text, int, date, date, uuid[]), promotion_end_now(uuid), promotion_archive(uuid), promotions_list(uuid, boolean), late_cancel_seat_kind(uuid), late_cancel_returns(uuid, uuid[]), return_booking_credit(uuid, text)
-- re-issues: xendit_begin_purchase(uuid, uuid), xendit_activate_success_internal(uuid, text, text), sell_plan_at_desk(uuid, uuid, uuid, text, text, boolean), record_manual_payment_run(uuid, uuid, text, integer, text, uuid, uuid, char, text, text, timestamptz, text), sales_history(uuid, date, date, uuid, text), sales_totals(uuid, date, date, uuid, text), render_email(uuid, text, text, text, text, text, jsonb, text, text), convert_keep_sweep(uuid, timestamptz), retention_email_context(uuid, text), template_sample_context(uuid, text, text), free_first_eligibility_run(uuid, uuid, uuid), member_has_had_free(uuid, uuid), member_activity(uuid, date, date)
--
-- Step 12: Decision 117 promotions and Decision 36 (a) staff return a late
-- cancel's credit. Every re-issue is byte-faithful from its TRUE newest
-- definition with only the change named above it:
--   xendit_begin_purchase       20260833630000:507   charges plan_price_now_run's price; stores list/promo/discount
--   xendit_activate_success_internal 20260833580000:1036  copies list/promo/discount onto the plan payment
--   sell_plan_at_desk           20260832970000:736   the sale price
--   record_manual_payment_run   20260832970000:149   records the promotion when the amount is the sale price
--   sales_history               20260833580000:1737  + discount_cents, discount_pct (DROP + recreate)
--   sales_totals                20260833580000:1949  + discounts {count, total_cents}
--   render_email                20260833660000:16    {offer_price} and {promo_line} from offer_plan_id; empty {promo_line} paragraph dropped
--   convert_keep_sweep          20260833190000:452   + offer_plan_id in the convert payload
--   retention_email_context     20260833550000:1266  + offer_plan_id; {offer_price} is the live (sale) price
--   template_sample_context     20260833650000:1349  + offer_plan_id
--   free_first_eligibility_run  20260833370000:255   a late-cancelled comp seat that was returned does not count
--   member_has_had_free         20260833370000       the same
--   member_activity             20260833550000:857   + the staff-only "Credit returned by" arm
-- ===========================================================================
-- 1. Decision 117: plan_promotions, and the price columns on a checkout and a
--    payment. A promotion is a percent off chosen one-time plans for a date
--    range in studio time. Writes go through the definer RPCs only.
-- ===========================================================================
create table plan_promotions (
  id          uuid primary key default gen_random_uuid(),
  studio_id   uuid not null references studios(id) on delete cascade,
  name        text not null check (length(btrim(name)) between 1 and 60),
  pct         int  not null check (pct between 1 and 90),
  starts_on   date not null,
  ends_on     date not null,
  plan_ids    uuid[] not null default '{}',
  ended_at    timestamptz,
  archived_at timestamptz,
  created_by  uuid references profiles(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint plan_promotions_dates check (ends_on >= starts_on)
);
create index plan_promotions_studio on plan_promotions (studio_id, starts_on);
alter table plan_promotions enable row level security;
revoke all on plan_promotions from anon;
grant select on plan_promotions to authenticated;
grant all on plan_promotions to service_role;
create policy plan_promotions_desk_read on plan_promotions for select to authenticated
  using (coalesce(is_desk_up(studio_id), false));
-- A member reads their own studio's promotions (the name on a receipt, the tag
-- on a plan). Nothing on the row is private; prices are what members see.
create policy plan_promotions_member_read on plan_promotions for select to authenticated
  using (studio_id in (select auth_member_studios()));

alter table payments
  add column if not exists list_price_cents int,
  add column if not exists promotion_id uuid references plan_promotions(id) on delete set null,
  add column if not exists discount_cents int;
alter table xendit_purchases
  add column if not exists list_price_cents int,
  add column if not exists promotion_id uuid references plan_promotions(id) on delete set null,
  add column if not exists discount_cents int;

-- ===========================================================================
-- 2. The price. One rounding (half up to the whole currency unit), one window.
-- ===========================================================================
create or replace function promo_sale_cents(p_list_cents int, p_pct int)
returns int language sql immutable set search_path = public as $$
  select ((p_list_cents::bigint * (100 - p_pct) + 5000) / 10000 * 100)::int;
$$;
revoke execute on function promo_sale_cents(int, int) from public, anon;
grant  execute on function promo_sale_cents(int, int) to authenticated, service_role;

-- The instants a promotion covers: 00:00 of the start day to the end of the end
-- day in studio time, or "End now" if that came first.
create or replace function promotion_bounds(p_promotion_id uuid)
returns table (start_at timestamptz, end_at timestamptz)
language sql stable security definer set search_path = public as $$
  select (pp.starts_on::timestamp at time zone s.timezone),
         least(((pp.ends_on + 1)::timestamp at time zone s.timezone),
               coalesce(pp.ended_at, 'infinity'::timestamptz))
    from plan_promotions pp join studios s on s.id = pp.studio_id
   where pp.id = p_promotion_id;
$$;
revoke execute on function promotion_bounds(uuid) from public, anon, authenticated;
grant  execute on function promotion_bounds(uuid) to service_role;

-- plan_price_now_run: unguarded, the one definition every checkout, email and
-- screen reads. Recurring plans never carry a promotion.
create or replace function plan_price_now_run(p_plan_id uuid, p_at timestamptz default now())
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare mp membership_plans%rowtype; v_tz text; pp plan_promotions%rowtype; v_sale int;
begin
  select * into mp from membership_plans where id = p_plan_id;
  if not found then return null; end if;
  select timezone into v_tz from studios where id = mp.studio_id;
  if mp.type <> 'recurring' then
    select p.* into pp
      from plan_promotions p
     where p.studio_id = mp.studio_id and mp.id = any (p.plan_ids) and p.archived_at is null
       and p_at >= (p.starts_on::timestamp at time zone v_tz)
       and p_at <  ((p.ends_on + 1)::timestamp at time zone v_tz)
       and (p.ended_at is null or p_at < p.ended_at)
     order by p.created_at
     limit 1;
  end if;
  if pp.id is null then
    return jsonb_build_object('plan_id', mp.id, 'list_cents', mp.price_cents, 'price_cents', mp.price_cents,
      'discount_cents', 0, 'currency', mp.currency, 'promotion_id', null, 'promotion_name', null,
      'pct', null, 'ends_on', null, 'ends_label', null);
  end if;
  v_sale := promo_sale_cents(mp.price_cents, pp.pct);
  return jsonb_build_object('plan_id', mp.id, 'list_cents', mp.price_cents, 'price_cents', v_sale,
    'discount_cents', mp.price_cents - v_sale, 'currency', mp.currency,
    'promotion_id', pp.id, 'promotion_name', pp.name, 'pct', pp.pct,
    'ends_on', pp.ends_on, 'ends_label', to_char(pp.ends_on, 'FMDy FMDD FMMon'));
end $$;
revoke execute on function plan_price_now_run(uuid, timestamptz) from public, anon, authenticated;
grant  execute on function plan_price_now_run(uuid, timestamptz) to service_role;

-- Who may read a studio's prices: its members, its staff (instructors at the
-- desk too), or the service.
create or replace function promo_price_reader(p_studio_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select is_service_context()
      or exists (select 1 from members m where m.studio_id = p_studio_id
                   and m.user_id = auth.uid() and m.deleted_at is null)
      or exists (select 1 from studio_staff ss where ss.studio_id = p_studio_id
                   and ss.user_id = auth.uid() and ss.status = 'active');
$$;
revoke execute on function promo_price_reader(uuid) from public, anon, authenticated;
grant  execute on function promo_price_reader(uuid) to service_role;

create or replace function plan_price_now(p_plan_id uuid, p_at timestamptz default now())
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid;
begin
  select studio_id into v_studio from membership_plans where id = p_plan_id;
  if v_studio is null then raise exception 'no such plan' using errcode = 'PT404'; end if;
  if not promo_price_reader(v_studio) then
    raise exception 'that is not your studio' using errcode = 'PT403';
  end if;
  return plan_price_now_run(p_plan_id, p_at);
end $$;
revoke execute on function plan_price_now(uuid, timestamptz) from public, anon;
grant  execute on function plan_price_now(uuid, timestamptz) to authenticated, service_role;

-- One call per screen: every non-archived plan of the studio, priced now.
create or replace function plan_prices_now(p_studio_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not promo_price_reader(p_studio_id) then
    raise exception 'that is not your studio' using errcode = 'PT403';
  end if;
  return coalesce((select jsonb_agg(plan_price_now_run(mp.id, now()))
                     from membership_plans mp
                    where mp.studio_id = p_studio_id and mp.status <> 'archived'), '[]'::jsonb);
end $$;
revoke execute on function plan_prices_now(uuid) from public, anon;
grant  execute on function plan_prices_now(uuid) to authenticated, service_role;

-- ===========================================================================
-- 3. Promotions: save, end now, archive, list. Manager-up; every change audited.
-- ===========================================================================
create or replace function promotion_save(
  p_studio_id uuid, p_promotion_id uuid, p_name text, p_pct int,
  p_starts_on date, p_ends_on date, p_plan_ids uuid[])
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_tz text; v_today date; v_old plan_promotions%rowtype; v_id uuid; v_name text;
        r record; v_ids uuid[];
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers set promotions' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  v_today := (now() at time zone v_tz)::date;
  v_name := btrim(coalesce(p_name, ''));
  v_ids := array(select distinct unnest(coalesce(p_plan_ids, '{}'::uuid[])));

  if p_promotion_id is not null then
    select * into v_old from plan_promotions where id = p_promotion_id and studio_id = p_studio_id;
    if not found then raise exception 'no such promotion' using errcode = 'PT404'; end if;
    if v_old.archived_at is not null or v_old.ended_at is not null
       or now() >= (v_old.starts_on::timestamp at time zone v_tz) then
      return jsonb_build_object('ok', false, 'reason', 'started',
        'message', 'This promotion has started. End it and create a new one.');
    end if;
  end if;

  if v_name = '' or length(v_name) > 60 then
    return jsonb_build_object('ok', false, 'reason', 'name_required', 'message', 'Give the promotion a name.');
  end if;
  if p_pct is null or p_pct < 1 or p_pct > 90 then
    return jsonb_build_object('ok', false, 'reason', 'pct_range',
      'message', 'The percent off is a whole number from 1 to 90.');
  end if;
  if p_starts_on is null or p_ends_on is null or p_ends_on < p_starts_on then
    return jsonb_build_object('ok', false, 'reason', 'dates', 'message', 'The end date is before the start date.');
  end if;
  if p_starts_on < v_today then
    return jsonb_build_object('ok', false, 'reason', 'start_past', 'message', 'The start date is in the past.');
  end if;
  if coalesce(array_length(v_ids, 1), 0) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_plans', 'message', 'Tick at least one plan.');
  end if;

  for r in select u.id, mp.id as plan_id, mp.name, mp.type, mp.status
             from unnest(v_ids) u(id)
             left join membership_plans mp on mp.id = u.id and mp.studio_id = p_studio_id loop
    if r.plan_id is null or r.status = 'archived' then
      return jsonb_build_object('ok', false, 'reason', 'plan_unknown', 'message', 'One of those plans is not on sale here.');
    end if;
    if r.type = 'recurring' then
      return jsonb_build_object('ok', false, 'reason', 'plan_recurring',
        'message', r.name || ' is a recurring membership and cannot carry a promotion.');
    end if;
  end loop;

  -- One promotion per plan at a time: no overlap with another live or scheduled one.
  for r in select mp.name as plan_name, pp.name as other, pp.starts_on,
                  case when pp.ended_at is not null then (pp.ended_at at time zone v_tz)::date
                       else pp.ends_on end as other_end
             from plan_promotions pp
             join membership_plans mp on mp.id = any (pp.plan_ids)
            where pp.studio_id = p_studio_id and pp.archived_at is null
              and pp.id is distinct from p_promotion_id
              and mp.id = any (v_ids)
              -- an ended promotion only overlaps on time it still had to run
              and (pp.ended_at is null
                   or pp.ended_at > greatest((p_starts_on::timestamp at time zone v_tz), now()))
              and pp.starts_on <= p_ends_on
              and (case when pp.ended_at is not null then (pp.ended_at at time zone v_tz)::date
                        else pp.ends_on end) >= p_starts_on
            order by mp.name limit 1 loop
    return jsonb_build_object('ok', false, 'reason', 'overlap',
      'message', r.plan_name || ' already has ' || r.other || ' from '
                 || to_char(r.starts_on, 'FMDy FMDD FMMon') || ' to ' || to_char(r.other_end, 'FMDy FMDD FMMon') || '.');
  end loop;

  if p_promotion_id is null then
    insert into plan_promotions (studio_id, name, pct, starts_on, ends_on, plan_ids, created_by)
    values (p_studio_id, v_name, p_pct, p_starts_on, p_ends_on, v_ids, auth.uid())
    returning id into v_id;
  else
    update plan_promotions set name = v_name, pct = p_pct, starts_on = p_starts_on, ends_on = p_ends_on,
           plan_ids = v_ids, updated_at = now()
     where id = p_promotion_id;
    v_id := p_promotion_id;
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (p_studio_id, auth.uid(),
          case when p_promotion_id is null then 'promotion.created' else 'promotion.updated' end,
          'plan_promotions', v_id,
          case when p_promotion_id is null then null else to_jsonb(v_old) end,
          (select to_jsonb(pp) from plan_promotions pp where pp.id = v_id));
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;
revoke execute on function promotion_save(uuid, uuid, text, int, date, date, uuid[]) from public, anon;
grant  execute on function promotion_save(uuid, uuid, text, int, date, date, uuid[]) to authenticated, service_role;

create or replace function promotion_end_now(p_promotion_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_old plan_promotions%rowtype; v_s timestamptz; v_e timestamptz;
begin
  select * into v_old from plan_promotions where id = p_promotion_id;
  if not found then raise exception 'no such promotion' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(v_old.studio_id), false) then
    raise exception 'only owners and managers set promotions' using errcode = 'PT403';
  end if;
  select start_at, end_at into v_s, v_e from promotion_bounds(p_promotion_id);
  if v_old.archived_at is not null or now() < v_s or now() >= v_e then
    return jsonb_build_object('ok', false, 'reason', 'not_running', 'message', 'This promotion is not running.');
  end if;
  update plan_promotions set ended_at = now(), updated_at = now() where id = p_promotion_id;
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (v_old.studio_id, auth.uid(), 'promotion.ended', 'plan_promotions', p_promotion_id,
          to_jsonb(v_old), (select to_jsonb(pp) from plan_promotions pp where pp.id = p_promotion_id));
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function promotion_end_now(uuid) from public, anon;
grant  execute on function promotion_end_now(uuid) to authenticated, service_role;

-- Archive takes a finished (or never-started) promotion off the list. A running
-- one is ended first.
create or replace function promotion_archive(p_promotion_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_old plan_promotions%rowtype; v_s timestamptz; v_e timestamptz;
begin
  select * into v_old from plan_promotions where id = p_promotion_id;
  if not found then raise exception 'no such promotion' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(v_old.studio_id), false) then
    raise exception 'only owners and managers set promotions' using errcode = 'PT403';
  end if;
  if v_old.archived_at is not null then
    return jsonb_build_object('ok', false, 'reason', 'archived', 'message', 'This promotion is already archived.');
  end if;
  select start_at, end_at into v_s, v_e from promotion_bounds(p_promotion_id);
  if now() >= v_s and now() < v_e then
    return jsonb_build_object('ok', false, 'reason', 'running', 'message', 'End the promotion before archiving it.');
  end if;
  update plan_promotions set archived_at = now(), updated_at = now() where id = p_promotion_id;
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (v_old.studio_id, auth.uid(), 'promotion.archived', 'plan_promotions', p_promotion_id,
          to_jsonb(v_old), (select to_jsonb(pp) from plan_promotions pp where pp.id = p_promotion_id));
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function promotion_archive(uuid) from public, anon;
grant  execute on function promotion_archive(uuid) to authenticated, service_role;

create or replace function promotions_list(p_studio_id uuid, p_include_archived boolean default false)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(is_manager_up(p_studio_id), false) and not is_service_context() then
    raise exception 'only owners and managers see promotions' using errcode = 'PT403';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', pp.id, 'name', pp.name, 'pct', pp.pct,
      'starts_on', pp.starts_on, 'ends_on', pp.ends_on, 'ended_at', pp.ended_at,
      'archived_at', pp.archived_at,
      'status', case when pp.archived_at is not null then 'archived'
                     when now() < b.start_at then 'scheduled'
                     when now() < b.end_at then 'running'
                     else 'ended' end,
      'plan_ids', to_jsonb(pp.plan_ids),
      'plan_names', (select coalesce(jsonb_agg(mp.name order by mp.name), '[]'::jsonb)
                       from membership_plans mp where mp.id = any (pp.plan_ids)),
      'sold', (select count(*) from payments p where p.promotion_id = pp.id
                 and p.status in ('succeeded', 'partially_refunded')),
      'discount_cents', (select coalesce(sum(p.discount_cents), 0) from payments p where p.promotion_id = pp.id
                 and p.status in ('succeeded', 'partially_refunded')))
      order by pp.starts_on desc, pp.created_at desc)
      from plan_promotions pp
      cross join lateral promotion_bounds(pp.id) b
     where pp.studio_id = p_studio_id and (p_include_archived or pp.archived_at is null)), '[]'::jsonb);
end $$;
revoke execute on function promotions_list(uuid, boolean) from public, anon;
grant  execute on function promotions_list(uuid, boolean) to authenticated, service_role;

-- ===========================================================================
-- 4. xendit_begin_purchase (20260833630000:507): the sale price, fixed at begin.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.xendit_begin_purchase(p_studio_id uuid, p_plan_id uuid)
 RETURNS TABLE(purchase_id uuid, amount_cents integer, currency character, credit_applied_cents integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_member uuid; mp membership_plans%rowtype; v_id uuid; v_renew uuid;
        v_avail int; v_applied int; v_due int;
        v_pr jsonb; v_price int; v_list int; v_promo uuid; v_disc int;
begin
  select id into v_member from members where studio_id = p_studio_id and user_id = auth.uid();
  if v_member is null then
    raise exception 'you are not a member of that studio' using errcode = 'PT403';
  end if;
  if not exists (select 1 from studio_payment_providers where studio_id = p_studio_id and provider = 'xendit') then
    raise exception 'this studio is not set up to take online payments' using errcode = 'PT409';
  end if;

  select * into mp from membership_plans
   where id = p_plan_id and studio_id = p_studio_id and visibility = 'public' and status = 'active';
  if mp.id is null then
    raise exception 'that plan is not on sale' using errcode = 'PT404';
  end if;
  if mp.type not in ('class_pack', 'drop_in', 'trial', 'recurring', 'group') then
    raise exception 'that plan is not a one-time purchase' using errcode = 'PT422';
  end if;

  if p_plan_id = (select intro_offer_plan_id from studio_settings where studio_id = p_studio_id)
     and coalesce((select intro_offer_exclusive from studio_settings where studio_id = p_studio_id), false)
     and not coalesce((intro_window(v_member) ->> 'active')::boolean, false) then
    raise exception 'That plan is only available during your intro offer.' using errcode = 'PT409';
  end if;

  if mp.type = 'trial' and exists (
    select 1 from memberships ms
      join membership_plans mp2 on mp2.id = ms.plan_id
     where ms.member_id = v_member and ms.studio_id = p_studio_id and mp2.type = 'trial'
  ) then
    raise exception 'The intro offer is for first-timers and you have had yours. Choose a pack or membership instead.'
      using errcode = 'PT409';
  end if;

  if mp.type = 'recurring' then
    select ms.id into v_renew
      from memberships ms
     where ms.studio_id = p_studio_id and ms.member_id = v_member
       and ms.plan_id = p_plan_id and ms.status in ('active', 'past_due')
     order by ms.current_period_end desc nulls last
     limit 1;
  end if;

  if v_renew is null
     and mp.max_active_members is not null
     and coalesce((select ss.seat_caps_enabled from studio_settings ss
                    where ss.studio_id = p_studio_id), false)
     and plan_seats_taken(mp.id) >= mp.max_active_members
  then
    raise exception '% is full.', mp.name using errcode = 'PT409';
  end if;

  -- Decision 117: the price is fixed now, from the promotion in force.
  v_pr := plan_price_now_run(p_plan_id, now());
  v_price := (v_pr ->> 'price_cents')::int;
  v_promo := nullif(v_pr ->> 'promotion_id', '')::uuid;
  v_list  := case when v_promo is not null then (v_pr ->> 'list_cents')::int end;
  v_disc  := case when v_promo is not null then (v_pr ->> 'discount_cents')::int end;

  v_avail := reservation_credit_available(p_studio_id, v_member);

  -- Decision 103(f): credit covers the whole total. No Xendit, no floor; complete
  -- now and return due 0 so the app lands straight on the success screen.
  if v_avail >= v_price then
    insert into xendit_purchases (studio_id, member_id, plan_id, amount_cents, currency,
                                  renews_membership_id, credit_applied_cents,
                                  list_price_cents, promotion_id, discount_cents)
    values (p_studio_id, v_member, p_plan_id, v_price, mp.currency, v_renew, v_price,
            v_list, v_promo, v_disc)
    returning id into v_id;
    perform xendit_activate_success_internal(v_id, null, 'credit');
    return query select v_id, 0, mp.currency, v_price;
    return;
  end if;

  -- Partial (or no) credit: cap so the online payment is >= the processor minimum.
  v_applied := least(greatest(v_avail, 0), greatest(v_price - 2000, 0));
  v_due := v_price - v_applied;

  insert into xendit_purchases (studio_id, member_id, plan_id, amount_cents, currency,
                                renews_membership_id, credit_applied_cents,
                                list_price_cents, promotion_id, discount_cents)
  values (p_studio_id, v_member, p_plan_id, v_due, mp.currency, v_renew, v_applied,
          v_list, v_promo, v_disc)
  returning id into v_id;

  return query select v_id, v_due, mp.currency, v_applied;
end $function$;


-- ===========================================================================
-- 5. xendit_activate_success_internal (20260833580000:1036): the plan payment
--    carries the list price, promotion and discount fixed at begin.
-- ===========================================================================
create or replace function xendit_activate_success_internal(p_purchase_id uuid, p_payment_id text, p_source text default 'xendit')
returns text
language plpgsql security definer set search_path = public as $$
declare p xendit_purchases%rowtype; v_ms uuid; v_prior text;
        v_group uuid; v_is_group boolean;
        o product_orders%rowtype; prod products%rowtype;
        v_b bookings%rowtype; v_occ class_occurrences%rowtype; v_free int; v_pay_id uuid;
        gc gift_cards%rowtype; v_code text; v_prov payment_provider; v_src text; v_ref text; v_send timestamptz;
begin
  select * into p from xendit_purchases where id = p_purchase_id for update;
  if p.id is null then return 'unknown_purchase'; end if;
  if p.status = 'succeeded' then return 'already_succeeded'; end if;
  v_prior := p.status;

  -- A full-credit (Decision 103(f)) completion: the payment row is source credit,
  -- provider manual, no processor reference.
  v_prov := case when p_source = 'credit' then 'manual'::payment_provider else 'xendit'::payment_provider end;
  v_src  := nullif(p_source, 'xendit');
  v_ref  := case when p_source = 'credit' then null else nullif(p_payment_id, '') end;

  if p.booking_id is not null then
    insert into payments (studio_id, member_id, booking_id, kind, amount_cents, currency,
                          status, provider, source, reference, description, paid_at)
    values (p.studio_id, p.member_id, p.booking_id, 'reservation_fee', p.amount_cents, p.currency,
            'succeeded', v_prov, v_src, v_ref, 'Reservation fee', now())
    returning id into v_pay_id;
    select * into v_b from bookings where id = p.booking_id;
    if v_b.status in ('booked', 'pending_payment') then
      perform book_first_free_run(p.booking_id);
    else
      select * into v_occ from class_occurrences where id = v_b.occurrence_id;
      v_free := coalesce(v_occ.capacity, 0) - occurrence_seats_taken(v_occ.id)
                - occurrence_seats_held(v_occ.id);
      if v_occ.id is not null and v_occ.status = 'scheduled'
         and v_occ.starts_at > now() and v_free >= 1 then
        perform restore_reservation_booking(p.booking_id);
      else
        insert into member_credits (studio_id, member_id, amount_cents, currency, reason,
                                    payment_id, booking_id)
        values (p.studio_id, p.member_id, p.amount_cents, p.currency, 'reservation_lost_seat',
                v_pay_id, p.booking_id);
        perform queue_notification(p.studio_id, p.member_id, 'free_reservation_lost_seat',
          jsonb_build_object('fee', fmt_money(p.amount_cents, p.currency),
            'class_name', coalesce(v_occ.name, 'a class'),
            'plans_url', member_portal_url(p.studio_id, '/account/plan')),
          'free_reservation_lost_seat:' || p.booking_id::text);
      end if;
    end if;

  elsif p.gift_card_id is not null then
    -- Decision 110: issue the gift card. Mint the code, record the sale (a real
    -- payment, so it counts in revenue once; linked by gift_card_id). Email the
    -- buyer at once; schedule the recipient for the delivery date (now when none).
    select * into gc from gift_cards where id = p.gift_card_id for update;
    v_code := gift_code(p.studio_id);
    -- Decision 110(a): the composited card image (amount + code over the studio's
    -- card) is served by the member host's next/og route; its path is stored on
    -- the card at issue and carried on gift_card_sent.
    update gift_cards set status = 'active', code = v_code, issued_at = now(),
           card_image_path = '/giftcard/' || gc.id::text || '/' || v_code || '/' || gc.amount_cents::text
     where id = gc.id and status in ('pending', 'active');

    insert into payments (studio_id, member_id, gift_card_id, kind, amount_cents, currency,
                          status, provider, source, reference, description, paid_at)
    values (p.studio_id, p.member_id, gc.id, 'gift_card', p.amount_cents, p.currency,
            'succeeded', v_prov, v_src, v_ref, 'Gift card', now());

    perform queue_notification(p.studio_id, gc.buyer_member_id, 'gift_card_receipt',
      jsonb_build_object('to_email', gc.buyer_email, 'buyer_name', coalesce(gc.buyer_name, 'there'),
        'recipient_name', coalesce(gc.recipient_name, 'your friend'),
        'code', v_code, 'amount', fmt_money(p.amount_cents, p.currency),
        'studio_name', (select name from studios where id = p.studio_id)),
      'gift_card_receipt:' || gc.id::text);

    v_send := case
      when gc.delivery_date is null then now()
      else greatest(now(),
        ((gc.delivery_date::text || ' 08:00')::timestamp
          at time zone (select timezone from studios where id = p.studio_id))) end;
    perform queue_notification(p.studio_id, gc.redeemed_by_member_id, 'gift_card_sent',
      jsonb_build_object('to_email', gc.recipient_email,
        'recipient_name', coalesce(gc.recipient_name, 'there'),
        'buyer_name', coalesce(gc.buyer_name, 'A friend'),
        'code', v_code, 'amount', fmt_money(p.amount_cents, p.currency),
        'message', coalesce(gc.message, ''),
        'message_html', case when coalesce(btrim(gc.message), '') = '' then ''
          else '<p style="font-style:italic;color:#57534e">&ldquo;' || replace(replace(replace(gc.message, '&', '&amp;'), '<', '&lt;'), '>', '&gt;') || '&rdquo;</p>' end,
        'card_image_url', member_portal_url(p.studio_id,
          '/giftcard/' || gc.id::text || '/' || v_code || '/' || gc.amount_cents::text),
        'redeem_url', member_portal_url(p.studio_id, '/account/redeem'),
        'studio_name', (select name from studios where id = p.studio_id)),
      'gift_card_sent:' || gc.id::text, v_send);

  elsif p.private_occurrence_id is not null then
    -- Decision 116: a full-paid private. Record the 'private' payment against the
    -- booker's seat (so Sales buckets it by the occurrence), then confirm the
    -- session at once (commit, flip seats, tell everyone, write the flat pay line).
    insert into payments (studio_id, member_id, booking_id, kind, amount_cents, currency,
                          status, provider, source, reference, description, paid_at)
    select p.studio_id, p.member_id, (select b.id from bookings b
             where b.occurrence_id = p.private_occurrence_id and b.payment_source = 'private'
             order by b.created_at limit 1),
           'private', p.amount_cents, p.currency, 'succeeded', v_prov, v_src, v_ref,
           'Private session', now()
    returning id into v_pay_id;
    select * into v_occ from class_occurrences where id = p.private_occurrence_id;
    if v_occ.status = 'scheduled' and v_occ.starts_at > now() then
      perform private_confirm_run(p.private_occurrence_id);
    else
      -- a late success on a private already released (expired session): the
      -- money is never lost, it lands as account credit (the 103(e) rule).
      insert into member_credits (studio_id, member_id, amount_cents, currency, reason, payment_id)
      values (p.studio_id, p.member_id, p.amount_cents, p.currency, 'private_refund', v_pay_id);
    end if;

  elsif p.product_order_id is not null then
    select * into o from product_orders where id = p.product_order_id for update;
    select * into prod from products where id = o.product_id for update;

    update product_orders set status = 'paid' where id = o.id and status in ('reserved', 'pending');

    if prod.track_stock then
      update products set stock = stock + o.quantity where id = prod.id;
      insert into stock_movements (studio_id, product_id, delta, reason, order_id)
      values (p.studio_id, prod.id, o.quantity, 'release', o.id);
      update products set stock = stock - o.quantity where id = prod.id;
      insert into stock_movements (studio_id, product_id, delta, reason, order_id)
      values (p.studio_id, prod.id, -o.quantity, 'sale', o.id);
    end if;

    insert into payments (studio_id, member_id, product_order_id, amount_cents, currency,
                          status, provider, source, reference, description, paid_at)
    values (p.studio_id, p.member_id, o.id, p.amount_cents, p.currency, 'succeeded', v_prov,
            v_src, v_ref, prod.name || ' ×' || o.quantity, now());

    perform queue_notification(
      p.studio_id, p.member_id, 'product_order_paid',
      jsonb_build_object('product', prod.name, 'quantity', o.quantity),
      'product_order_paid:' || o.id::text);

  else
    select type = 'group' into v_is_group from membership_plans where id = p.plan_id;
    if v_is_group then
      v_group := activate_purchase(p.studio_id, p.member_id, p.plan_id, p.amount_cents, p.currency, null, null, false);
      insert into payments (studio_id, member_id, group_purchase_id, amount_cents, currency,
                            status, provider, source, reference, description, paid_at,
                            list_price_cents, promotion_id, discount_cents)
      select p.studio_id, p.member_id, v_group, p.amount_cents, p.currency, 'succeeded', v_prov,
             v_src, v_ref, mp.name, now(), p.list_price_cents, p.promotion_id, p.discount_cents
        from membership_plans mp where mp.id = p.plan_id;
    else
    if p.renews_membership_id is not null and exists (
         select 1 from memberships where id = p.renews_membership_id
            and status in ('active', 'past_due') and not membership_frozen_now(id)) then
      v_ms := p.renews_membership_id;
      perform advance_membership_period_run(p.renews_membership_id);
    else
      v_ms := activate_purchase(p.studio_id, p.member_id, p.plan_id, p.amount_cents, p.currency,
                                null, null, false);
      update memberships set auto_renew = false where id = v_ms;
    end if;

    perform apply_plan_to_unpaid(p.studio_id, p.member_id, v_ms);

    insert into payments (studio_id, member_id, membership_id, amount_cents, currency,
                          status, provider, source, reference, description, paid_at,
                          list_price_cents, promotion_id, discount_cents)
    select p.studio_id, p.member_id, v_ms, p.amount_cents, p.currency, 'succeeded', v_prov,
           v_src, v_ref, mp.name, now(), p.list_price_cents, p.promotion_id, p.discount_cents
      from membership_plans mp where mp.id = p.plan_id;
    end if;
  end if;

  -- ONE consume: a plan/product (and reservation, when not via reserve_free_first)
  -- purchase consumes any reservation/gift credit applied at begin. A gift sale
  -- never carries credit_applied, so this is a no-op there.
  if p.credit_applied_cents > 0 then
    perform consume_reservation_credit(p.studio_id, p.member_id, p.credit_applied_cents);
  end if;

  if v_prior = 'expired' then
    insert into audit_logs (studio_id, action, entity_table, entity_id, after)
    values (p.studio_id, 'xendit.expiry_overridden', 'xendit_purchases', p.id,
            jsonb_build_object('prior_status', v_prior,
                               'payment_id', nullif(p_payment_id, ''),
                               'note', 'paid after local expiry'));
  end if;

  update xendit_purchases
     set status = 'succeeded', xendit_payment_id = nullif(p_payment_id, ''),
         completed_at = now(), failure_reason = null, updated_at = now()
   where id = p_purchase_id;

  return case when v_prior = 'expired' then 'activated_after_expiry' else 'activated' end;
end $$;


-- ===========================================================================
-- 6. sell_plan_at_desk (20260832970000:736): the sale price.
-- ===========================================================================
create or replace function sell_plan_at_desk(p_occurrence uuid, p_member uuid, p_plan uuid,
                                             p_method text, p_reference text, p_use_for_today boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_scope text; v_occ class_occurrences%rowtype; mp membership_plans%rowtype;
        v_res jsonb; v_ms uuid; v_seat bookings%rowtype;
begin
  v_scope := instructor_scope(p_occurrence);
  if v_scope is not null then return jsonb_build_object('ok', false, 'reason', v_scope); end if;
  select * into v_occ from class_occurrences where id = p_occurrence;

  if p_method not in ('gcash','cash','card_terminal') then
    return jsonb_build_object('ok', false, 'reason', 'unknown payment method');
  end if;
  if not exists (select 1 from bookings where occurrence_id = p_occurrence and member_id = p_member
                  and status in ('booked','attended','pending_payment')) then
    return jsonb_build_object('ok', false, 'reason', 'member already has a seat in this class' );
  end if;
  select * into mp from membership_plans
   where id = p_plan and studio_id = v_occ.studio_id and status = 'active' and visibility = 'public';
  if not found then return jsonb_build_object('ok', false, 'reason', 'plan not for sale here'); end if;

  v_res := record_manual_payment_run(v_occ.studio_id, p_member, 'plan',
             (plan_price_now_run(p_plan, now()) ->> 'price_cents')::int, p_method,
             p_plan, null, null, null, nullif(btrim(coalesce(p_reference,'')), ''));
  v_ms := nullif(v_res ->> 'membership_id', '')::uuid;

  -- Use it for today: pay the member's unpaid drop-in in THIS class from the new
  -- plan (Decision 73b apply-on-activation), so its due becomes zero.
  if p_use_for_today and v_ms is not null then
    select * into v_seat from bookings
     where occurrence_id = p_occurrence and member_id = p_member and payment_source = 'drop_in'
       and status in ('booked','attended')
       and not exists (select 1 from payments p where p.booking_id = bookings.id and p.status in ('succeeded','partially_refunded'))
     limit 1;
    if found then perform apply_plan_to_unpaid(v_occ.studio_id, p_member, v_ms); end if;
  end if;

  return jsonb_build_object('ok', true, 'membership_id', v_ms, 'payment_id', v_res ->> 'payment_id',
    'renewed', v_res -> 'renewed');
end $$;


-- record_manual_payment_run (20260832970000:149): the promotion when the amount is the sale price.
create or replace function record_manual_payment_run(
  p_studio_id uuid, p_member_id uuid, p_kind text, p_amount_cents integer, p_method text,
  p_plan_id uuid default null, p_booking_id uuid default null, p_currency char default null,
  p_method_note text default null, p_reference text default null,
  p_paid_at timestamptz default now(), p_description text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_currency char(3);
  v_ms       uuid;
  v_payment  uuid;
  v_confirmed boolean := false;
  v_plan_name text;
  v_renewing uuid;
  v_renewal  jsonb;
  v_is_group boolean := false;
  v_group_purchase uuid;
  v_pr jsonb; v_list int; v_promo uuid; v_disc int;
begin
  if studio_is_locked(p_studio_id) then
    raise exception 'this studio''s Studiior subscription is not active'
      using errcode = 'PT402',
            hint = 'Reactivate it from Billing. Nothing has been deleted.';
  end if;

  if p_amount_cents is null or p_amount_cents < 0 then
    raise exception 'an amount is needed' using errcode = 'PT400';
  end if;
  if not exists (select 1 from members where id = p_member_id and studio_id = p_studio_id) then
    raise exception 'that member does not belong to this studio' using errcode = 'PT403';
  end if;

  select coalesce(p_currency, s.currency) into v_currency
    from studios s where s.id = p_studio_id;

  if p_kind = 'plan' then
    if p_plan_id is null then
      raise exception 'which plan?' using errcode = 'PT400';
    end if;
    select ms.id into v_renewing
      from memberships ms
      join membership_plans pl on pl.id = ms.plan_id
     where ms.studio_id = p_studio_id and ms.member_id = p_member_id
       and ms.plan_id = p_plan_id
       and pl.type = 'recurring'
       and ms.status in ('active', 'past_due')
     order by ms.current_period_end desc nulls last
     limit 1;

    if v_renewing is not null then
      v_ms := v_renewing;
      -- The UNGUARDED twin: record_manual_payment_run is also reached from the
      -- instructor desk (sell_plan_at_desk), where the caller is not desk/service
      -- and advance_membership_period's own guard would refuse. The desk/scope
      -- boundary is enforced by the caller (is_desk_up wrapper / instructor_scope).
      v_renewal := advance_membership_period_run(v_renewing);
    else
      v_ms := activate_purchase(p_studio_id, p_member_id, p_plan_id,
                                p_amount_cents, v_currency);
    end if;
    select name, type = 'group' into v_plan_name, v_is_group
      from membership_plans where id = p_plan_id;
    if v_is_group then v_group_purchase := v_ms; v_ms := null; end if;

  elsif p_kind = 'dropin' then
    if p_booking_id is null then
      raise exception 'which booking?' using errcode = 'PT400';
    end if;
    v_confirmed := confirm_dropin_payment(p_studio_id, p_booking_id);
  end if;

  -- Decision 117: the promotion is recorded only when the amount IS the sale
  -- price; any other typed amount is a manual price, recorded as typed.
  if p_kind = 'plan' and p_plan_id is not null then
    v_pr := plan_price_now_run(p_plan_id, now());
    if nullif(v_pr ->> 'promotion_id', '') is not null
       and p_amount_cents = (v_pr ->> 'price_cents')::int then
      v_promo := (v_pr ->> 'promotion_id')::uuid;
      v_list  := (v_pr ->> 'list_cents')::int;
      v_disc  := (v_pr ->> 'discount_cents')::int;
    end if;
  end if;

  insert into payments (
    studio_id, member_id, membership_id, group_purchase_id, booking_id, amount_cents, currency,
    status, provider, method, method_note, reference, description,
    paid_at, recorded_by, list_price_cents, promotion_id, discount_cents
  ) values (
    p_studio_id, p_member_id, v_ms, v_group_purchase, p_booking_id, p_amount_cents, v_currency,
    'succeeded', 'manual', p_method, p_method_note, p_reference,
    coalesce(p_description,
             case p_kind when 'plan' then v_plan_name
                         when 'dropin' then 'Drop-in class'
                         else 'Payment' end),
    coalesce(p_paid_at, now()), auth.uid(), v_list, v_promo, v_disc
  ) returning id into v_payment;

  return jsonb_build_object(
    'payment_id', v_payment,
    'membership_id', v_ms,
    'group_purchase_id', v_group_purchase,
    'booking_confirmed', v_confirmed,
    'renewed', v_renewal
  );
end $$;


-- ===========================================================================
-- 7. sales_history (20260833580000:1737): + discount_cents, discount_pct.
--    DROP + recreate (a returns-table change); grants re-asserted.
-- ===========================================================================
drop function if exists sales_history(uuid, date, date, uuid, text);
create or replace function sales_history(
  p_studio_id uuid, p_from date, p_to date,
  p_plan_id uuid default null, p_status text default null
) returns table (
  membership_id uuid, member_id uuid, member_name text,
  plan_id uuid, plan_name text, plan_type text,
  amount_cents int, currency char(3), payment_source text,
  bought_on timestamptz, starts_on date, expires_on date, sale_status text,
  is_renewal boolean,
  discount_cents int, discount_pct int
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare v_tz text; v_today date; v_f0 timestamptz; v_t1 timestamptz;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'sales are for owners and managers' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios s where s.id = p_studio_id;
  v_today := (now() at time zone v_tz)::date;
  select day_start into v_f0 from studio_day_bounds(p_studio_id, p_from);
  select day_start into v_t1 from studio_day_bounds(p_studio_id, p_to + 1);

  return query
  with pay as (
    select distinct on (p.membership_id)
           p.membership_id, p.amount_cents, p.currency, p.provider, p.method, p.status as pstatus,
           p.discount_cents, p.promotion_id,
           coalesce(p.paid_at, p.created_at) as paid_ts
      from payments p
     where p.studio_id = p_studio_id and p.membership_id is not null
     order by p.membership_id, coalesce(p.paid_at, p.created_at) desc
  )
  select ms.id, ms.member_id,
         (m.first_name || ' ' || m.last_name) as member_name,
         ms.plan_id, mp.name, mp.type::text,
         coalesce(pay.amount_cents, ms.price_cents) as amount_cents,
         ms.currency,
         coalesce(
           case when pay.provider = 'stripe' then 'Card (Stripe)'
                when pay.provider = 'xendit' then 'Card (Xendit)'
                when pay.method = 'gcash' then 'GCash'
                when pay.method = 'bank_transfer' then 'Bank transfer'
                when pay.method = 'card_terminal' then 'Card (terminal)'
                when pay.method = 'cash' then 'Cash'
                when pay.method = 'other' then 'Other'
                when pay.membership_id is not null then 'Recorded'
           end, 'Unpaid') as payment_source,
         coalesce(pay.paid_ts, ms.created_at) as bought_on,
         ms.starts_on, ms.expires_on,
         (case
            when pay.pstatus = 'refunded' then 'refunded'
            when ms.status = 'frozen' then 'frozen'
            when pay.membership_id is null or pay.pstatus = 'pending' then 'unpaid'
            when ms.status in ('cancelled', 'expired') then 'expired'
            when ms.expires_on is not null and ms.expires_on <= v_today + 14 then 'expiring'
            else 'active'
          end) as sale_status,
         (select count(*) from payments p2
           where p2.membership_id = ms.id
             and p2.status in ('succeeded', 'partially_refunded')) > 1 as is_renewal,
         pay.discount_cents,
         (select pp.pct from plan_promotions pp where pp.id = pay.promotion_id) as discount_pct
    from memberships ms
    join members m on m.id = ms.member_id
    join membership_plans mp on mp.id = ms.plan_id
    left join pay on pay.membership_id = ms.id
   where ms.studio_id = p_studio_id
     and not coalesce(ms.complimentary, false)
     and coalesce(pay.paid_ts, ms.created_at) >= v_f0
     and coalesce(pay.paid_ts, ms.created_at) <  v_t1
     and (p_plan_id is null or ms.plan_id = p_plan_id)
     and (p_status  is null or p_status = (case
            when pay.pstatus = 'refunded' then 'refunded'
            when ms.status = 'frozen' then 'frozen'
            when pay.membership_id is null or pay.pstatus = 'pending' then 'unpaid'
            when ms.status in ('cancelled', 'expired') then 'expired'
            when ms.expires_on is not null and ms.expires_on <= v_today + 14 then 'expiring'
            else 'active' end))

  union all

  select null::uuid, p.member_id,
         coalesce(m.first_name || ' ' || m.last_name, 'Walk-in') as member_name,
         null::uuid, (pr.name || ' ×' || po.quantity) as plan_name, 'merch' as plan_type,
         p.amount_cents, p.currency,
         (case when p.provider = 'xendit' then 'Card (Xendit)'
               when p.provider = 'stripe' then 'Card (Stripe)'
               when p.method = 'gcash' then 'GCash'
               when p.method = 'bank_transfer' then 'Bank transfer'
               when p.method = 'card_terminal' then 'Card (terminal)'
               when p.method = 'cash' then 'Cash'
               when p.method = 'other' then 'Other'
               else 'Recorded' end) as payment_source,
         coalesce(p.paid_at, p.created_at) as bought_on,
         null::date, null::date,
         (case when p.status in ('refunded','partially_refunded') or coalesce(p.refunded_cents,0) > 0
               then 'refunded' else 'active' end) as sale_status,
         false as is_renewal, null::int, null::int
    from payments p
    join product_orders po on po.id = p.product_order_id
    join products pr on pr.id = po.product_id
    left join members m on m.id = p.member_id
   where p.studio_id = p_studio_id and p.status in ('succeeded','partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1
     and p_plan_id is null
     and (p_status is null or p_status = (case
            when p.status in ('refunded','partially_refunded') or coalesce(p.refunded_cents,0) > 0
            then 'refunded' else 'active' end))

  union all

  select null::uuid, p.member_id,
         coalesce(m.first_name || ' ' || m.last_name, 'Walk-in') as member_name,
         null::uuid, ('Reservation · ' || coalesce(o.name, 'a class')) as plan_name,
         'reservation_fee' as plan_type,
         p.amount_cents, p.currency,
         (case when p.provider = 'xendit' then 'Card (Xendit)'
               when p.provider = 'stripe' then 'Card (Stripe)'
               when p.method = 'gcash' then 'GCash'
               when p.method = 'card_terminal' then 'Card (terminal)'
               when p.method = 'cash' then 'Cash'
               else 'Recorded' end) as payment_source,
         coalesce(p.paid_at, p.created_at) as bought_on,
         null::date, null::date,
         (case when p.status in ('refunded','partially_refunded') or coalesce(p.refunded_cents,0) > 0
               then 'refunded' else 'active' end) as sale_status,
         false as is_renewal, null::int, null::int
    from payments p
    left join bookings b on b.id = p.booking_id
    left join class_occurrences o on o.id = b.occurrence_id
    left join members m on m.id = p.member_id
   where p.studio_id = p_studio_id and p.kind = 'reservation_fee'
     and coalesce(p.method, '') <> 'reservation_credit'
     and p.status in ('succeeded','partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1
     and p_plan_id is null
     and (p_status is null or p_status = (case
            when p.status in ('refunded','partially_refunded') or coalesce(p.refunded_cents,0) > 0
            then 'refunded' else 'active' end))

  union all

  -- Decision 110: a gift card SALE (real cash; counted once, here). plan_type
  -- 'gift'; no membership, never a renewal. The redemption is NOT a sale.
  select null::uuid, p.member_id,
         coalesce(gc.buyer_name, 'Gift purchase') as member_name,
         null::uuid, ('Gift card · ' || coalesce(gc.recipient_name, gc.recipient_email, 'a friend')) as plan_name,
         'gift' as plan_type,
         p.amount_cents, p.currency,
         (case when p.provider = 'xendit' then 'Card (Xendit)'
               when p.provider = 'stripe' then 'Card (Stripe)'
               else 'Recorded' end) as payment_source,
         coalesce(p.paid_at, p.created_at) as bought_on,
         null::date, null::date,
         (case when p.status in ('refunded','partially_refunded') or coalesce(p.refunded_cents,0) > 0
               then 'refunded' else 'active' end) as sale_status,
         false as is_renewal, null::int, null::int
    from payments p
    join gift_cards gc on gc.id = p.gift_card_id
   where p.studio_id = p_studio_id and p.gift_card_id is not null
     and coalesce(p.source, '') <> 'credit'
     and p.status in ('succeeded','partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1
     and p_plan_id is null
     and (p_status is null or p_status = (case
            when p.status in ('refunded','partially_refunded') or coalesce(p.refunded_cents,0) > 0
            then 'refunded' else 'active' end))

  union all

  -- Decision 116: a private session sale (the booker's 'private' payment, cash
  -- or card; a source-credit rebook is not a sale). plan_type 'private'.
  select null::uuid, p.member_id,
         coalesce(m.first_name || ' ' || m.last_name, 'Walk-in') as member_name,
         null::uuid, ('Private · ' || coalesce(pst.name, 'session')) as plan_name,
         'private' as plan_type,
         p.amount_cents, p.currency,
         (case when p.provider = 'xendit' then 'Card (Xendit)'
               when p.provider = 'stripe' then 'Card (Stripe)'
               when p.method = 'gcash' then 'GCash'
               when p.method = 'bank_transfer' then 'Bank transfer'
               when p.method = 'card_terminal' then 'Card (terminal)'
               when p.method = 'cash' then 'Cash'
               when p.method = 'other' then 'Other'
               else 'Recorded' end) as payment_source,
         coalesce(p.paid_at, p.created_at) as bought_on,
         (o.starts_at at time zone v_tz)::date, null::date,
         (case when p.status in ('refunded','partially_refunded') or coalesce(p.refunded_cents,0) > 0
               then 'refunded' else 'active' end) as sale_status,
         false as is_renewal, null::int, null::int
    from payments p
    join bookings b on b.id = p.booking_id
    join class_occurrences o on o.id = b.occurrence_id
    left join private_session_types pst on pst.id = o.private_type_id
    left join members m on m.id = p.member_id
   where p.studio_id = p_studio_id and p.kind = 'private'
     and coalesce(p.source, '') <> 'credit'
     and p.status in ('succeeded','partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1
     and p_plan_id is null
     and (p_status is null or p_status = (case
            when p.status in ('refunded','partially_refunded') or coalesce(p.refunded_cents,0) > 0
            then 'refunded' else 'active' end))

  order by bought_on desc;
end $$;

revoke execute on function sales_history(uuid, date, date, uuid, text) from public, anon;
grant  execute on function sales_history(uuid, date, date, uuid, text) to authenticated, service_role;


-- sales_totals (20260833580000:1949): + discounts.
create or replace function sales_totals(
  p_studio_id uuid, p_from date, p_to date,
  p_plan_id uuid default null, p_status text default null
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_currency char(3); v_count int; v_gross bigint; v_refunded bigint; v_studio_total bigint;
  v_f0 timestamptz; v_t1 timestamptz; v_resv_count int; v_resv_total bigint;
  v_ref_count int; v_ref_total bigint;
  v_gift_count int; v_gift_total bigint; v_redeem_count int; v_redeem_total bigint;
  v_priv_count int; v_priv_total bigint; v_priv_coach bigint;
  v_disc_count int; v_disc_total bigint;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'sales are for owners and managers' using errcode = 'PT403';
  end if;
  select currency into v_currency from studios s where s.id = p_studio_id;
  select day_start into v_f0 from studio_day_bounds(p_studio_id, p_from);
  select day_start into v_t1 from studio_day_bounds(p_studio_id, p_to + 1);

  select count(*) into v_count
    from sales_history(p_studio_id, p_from, p_to, p_plan_id, p_status);

  select coalesce(sum(p.amount_cents), 0)::bigint,
         coalesce(sum(p.refunded_cents), 0)::bigint
    into v_gross, v_refunded
    from payments p
    left join memberships ms on ms.id = p.membership_id
   where p.studio_id = p_studio_id
     and p.status in ('succeeded', 'partially_refunded')
     and (p.membership_id is not null or p.product_order_id is not null)
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1
     and (p_plan_id is null or ms.plan_id = p_plan_id);

  v_studio_total := studio_revenue_between(p_studio_id, v_f0, v_t1);

  select count(*), coalesce(sum(p.amount_cents - coalesce(p.refunded_cents, 0)), 0)::bigint
    into v_resv_count, v_resv_total
    from payments p
   where p.studio_id = p_studio_id and p.kind = 'reservation_fee'
     and coalesce(p.method, '') <> 'reservation_credit'
     and p.status in ('succeeded', 'partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1;

  select count(*), coalesce(sum(pr.amount_cents), 0)::bigint
    into v_ref_count, v_ref_total
    from payment_refunds pr
   where pr.studio_id = p_studio_id and pr.status = 'succeeded'
     and coalesce(pr.settled_at, pr.created_at) >= v_f0
     and coalesce(pr.settled_at, pr.created_at) <  v_t1;

  -- Decision 110: gift cards sold (cash received), and gift credit redeemed
  -- (source credit, excluded from revenue — shown so the two can be reconciled).
  select count(*), coalesce(sum(p.amount_cents - coalesce(p.refunded_cents, 0)), 0)::bigint
    into v_gift_count, v_gift_total
    from payments p
   where p.studio_id = p_studio_id and p.gift_card_id is not null
     and coalesce(p.source, '') <> 'credit'
     and p.status in ('succeeded', 'partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1;

  select count(*), coalesce(sum(p.amount_cents), 0)::bigint
    into v_redeem_count, v_redeem_total
    from payments p
   where p.studio_id = p_studio_id and coalesce(p.source, '') = 'credit'
     and p.status in ('succeeded', 'partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1;

  -- Decision 116: private sessions sold in the period (cash/card, not a credit
  -- rebook), the coach pay read from each session's pay record, and the VAT
  -- split (12 percent inclusive, the Decision 88c invoice arithmetic).
  select count(*), coalesce(sum(p.amount_cents - coalesce(p.refunded_cents, 0)), 0)::bigint,
         coalesce(sum(coalesce((select ipr.amount_cents from instructor_pay_records ipr
                                 where ipr.occurrence_id = b.occurrence_id and ipr.type = 'class'
                                 limit 1), 0)), 0)::bigint
    into v_priv_count, v_priv_total, v_priv_coach
    from payments p
    join bookings b on b.id = p.booking_id
   where p.studio_id = p_studio_id and p.kind = 'private'
     and coalesce(p.source, '') <> 'credit'
     and p.status in ('succeeded', 'partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1;

  -- Decision 117: discounts given on sales in the period.
  select count(*), coalesce(sum(p.discount_cents), 0)::bigint
    into v_disc_count, v_disc_total
    from payments p
    left join memberships ms on ms.id = p.membership_id
   where p.studio_id = p_studio_id and p.promotion_id is not null
     and p.status in ('succeeded', 'partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1
     and (p_plan_id is null or ms.plan_id = p_plan_id);

  return jsonb_build_object(
    'discounts', jsonb_build_object('count', v_disc_count, 'total_cents', v_disc_total),
    'private', jsonb_build_object('count', v_priv_count, 'total_cents', v_priv_total,
      'after_vat_cents', round(v_priv_total / 1.12)::bigint,
      'vat_cents', v_priv_total - round(v_priv_total / 1.12)::bigint,
      'coach_pay_cents', v_priv_coach,
      'studio_keeps_cents', v_priv_total - v_priv_coach),
    'refunds', jsonb_build_object('count', v_ref_count, 'total_cents', v_ref_total),
    'reservation_fees', jsonb_build_object('count', v_resv_count, 'total_cents', v_resv_total),
    'gift_sold', jsonb_build_object('count', v_gift_count, 'total_cents', v_gift_total),
    'gift_redeemed', jsonb_build_object('count', v_redeem_count, 'total_cents', v_redeem_total),
    'count', v_count,
    'gross_cents', v_gross,
    'refunded_cents', v_refunded,
    'net_cents', v_gross - v_refunded,
    'studio_total_cents', v_studio_total,
    'currency', v_currency);
end $$;


-- ===========================================================================
-- 8. render_email (20260833660000:16): {offer_price} and {promo_line} resolved
--    from offer_plan_id at send time; an empty {promo_line} paragraph dropped.
--    No other token's behaviour changes.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.render_email(p_studio_id uuid, p_template_key text, p_recipient_type text, p_subject text, p_text text, p_html text, p_payload jsonb, p_first_name text DEFAULT NULL::text, p_recipient_role text DEFAULT NULL::text)
 RETURNS TABLE(subject text, text_body text, html_body text, stripped text[])
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s studios%rowtype;
  v_is_staff boolean; v_sub text; v_txt text; v_html text; k text; rule text; v_on text;
  v_addr text; v_link text; v_contact text; v_contact_html text; v_ig text;
  v_always boolean; v_foot_txt text; v_foot_html text;
  v_logo text; v_fmt text; v_occ_id uuid; v_class_line text; v_class_when text;
  v_tok text; v_stripped text[] := '{}';
  v_rows jsonb; v_rt_html text; v_rt_txt text; v_msg text;
  v_offer uuid; v_pr jsonb; v_promo text;
begin
  select * into s from studios where id = p_studio_id;
  select coalesce(time_format, '24h') into v_fmt from studio_settings where studio_id = p_studio_id;
  v_fmt := coalesce(v_fmt, '24h');
  v_is_staff := p_recipient_type = 'staff';
  v_sub := p_subject; v_txt := p_text; v_html := p_html;

  -- Decision 89 (b): a studio message keeps its paragraphs. {message_html} is
  -- rebuilt from the plain message (a blank line is a paragraph, a single break
  -- a <br>, Windows line endings normalised); {message} keeps its breaks.
  if p_payload ? 'message' then
    v_msg := regexp_replace(replace(replace(p_payload ->> 'message', E'\r\n', E'\n'), E'\r', E'\n'),
                            E'\n{3,}', E'\n\n', 'g');
    v_html := replace(v_html, '{message_html}', message_paragraphs_html(p_payload ->> 'message'));
    v_txt  := replace(v_txt,  '{message}', v_msg);
  end if;

  -- Decision 80 note: {roster_table}, from the payload's rows or, for the month
  -- roster emails, from the instructor's published classes that month.
  if coalesce(v_html, '') like '%{roster_table}%' or coalesce(v_txt, '') like '%{roster_table}%' then
    if p_payload ? 'roster_rows' then
      v_rows := p_payload -> 'roster_rows';
    elsif p_payload ? 'instructor_id' and p_payload ? 'month_ym' then
      select coalesce(jsonb_agg(jsonb_build_object(
               'day', to_char(o.starts_at at time zone s.timezone, 'FMDy FMDD FMMon'),
               'time', fmt_clock(o.starts_at, s.timezone, v_fmt),
               'class', coalesce(o.name, ct.name, 'Class')) order by o.starts_at), '[]'::jsonb)
        into v_rows
        from class_occurrences o
        left join class_types ct on ct.id = o.class_type_id
       where o.studio_id = p_studio_id
         and o.instructor_id = (p_payload ->> 'instructor_id')::uuid
         and o.status = 'scheduled'
         and to_char(o.starts_at at time zone s.timezone, 'YYYY-MM') = p_payload ->> 'month_ym';
    end if;
    if v_rows is not null then
      select rt.html, rt.txt into v_rt_html, v_rt_txt from roster_table_render(v_rows) rt;
      v_html := replace(v_html, '{roster_table}', v_rt_html);
      v_txt  := replace(v_txt,  '{roster_table}', v_rt_txt);
      v_sub  := replace(v_sub,  '{roster_table}', '');
    end if;
  end if;

  -- Decision 117: the offer plan's price as of the send, and {promo_line}.
  -- A paragraph that is only {promo_line} is dropped when the line is empty.
  v_offer := nullif(p_payload ->> 'offer_plan_id', '')::uuid;
  if v_offer is not null then
    v_pr := plan_price_now_run(v_offer, now());
    if v_pr is not null then
      p_payload := p_payload || jsonb_build_object(
        'offer_price', fmt_money((v_pr ->> 'price_cents')::int, v_pr ->> 'currency'),
        'promo_line', case when nullif(v_pr ->> 'promotion_id', '') is not null
                           then (v_pr ->> 'promotion_name') || ': ' || (v_pr ->> 'pct') || '% off until '
                                || (v_pr ->> 'ends_label')
                           else '' end);
    end if;
  end if;
  v_promo := coalesce(p_payload ->> 'promo_line', '');
  if v_promo = '' then
    v_html := regexp_replace(coalesce(v_html, ''), '<p[^>]*>\s*\{promo_line\}\s*</p>\s*', '', 'g');
    v_txt  := regexp_replace(coalesce(v_txt, ''), E'\n\n[ \t]*\{promo_line\}[ \t]*(?=\n\n)', '', 'g');
    v_txt  := regexp_replace(v_txt, E'\n[ \t]*\{promo_line\}[ \t]*(?=\n|$)', '', 'g');
    v_txt  := regexp_replace(v_txt, E'^[ \t]*\{promo_line\}[ \t]*\n*', '');
  end if;

  for k in select jsonb_object_keys(p_payload) loop
    v_sub  := replace(v_sub,  '{' || k || '}', coalesce(p_payload ->> k, ''));
    v_txt  := replace(v_txt,  '{' || k || '}', coalesce(p_payload ->> k, ''));
    v_html := replace(v_html, '{' || k || '}', coalesce(p_payload ->> k, ''));
  end loop;
  -- Decision 80 note: {flex_min} and {flex_cutoff} in every email.
  v_sub  := replace(replace(v_sub,  '{flex_min}', coalesce((select flex_min_bookings::text from studio_settings where studio_id = p_studio_id), '2')), '{flex_cutoff}', coalesce(flex_cutoff_words(p_studio_id), ''));
  v_txt  := replace(replace(v_txt,  '{flex_min}', coalesce((select flex_min_bookings::text from studio_settings where studio_id = p_studio_id), '2')), '{flex_cutoff}', coalesce(flex_cutoff_words(p_studio_id), ''));
  v_html := replace(replace(v_html, '{flex_min}', coalesce((select flex_min_bookings::text from studio_settings where studio_id = p_studio_id), '2')), '{flex_cutoff}', coalesce(flex_cutoff_words(p_studio_id), ''));
  for k in select unnest(array['first_name','studio_name']) loop
    v_sub  := replace(v_sub,  '{' || k || '}',
                      case k when 'first_name'
                             then coalesce(p_first_name, 'there')
                             else s.name end);
    v_txt  := replace(v_txt,  '{' || k || '}',
                      case k when 'first_name'
                             then coalesce(p_first_name, 'there')
                             else s.name end);
    v_html := replace(v_html, '{' || k || '}',
                      case k when 'first_name'
                             then coalesce(p_first_name, 'there')
                             else s.name end);
  end loop;

  -- Decision 80a fix: the class card's ONE detail line, built from the occurrence
  -- so every class email reads the same — Day · time · room · with {instructor},
  -- times via fmt_clock in the studio format, missing parts dropped cleanly.
  v_occ_id := nullif(p_payload ->> 'occurrence_id', '')::uuid;
  if v_occ_id is not null then
    select concat_ws(' · ',
             nullif(to_char(o.starts_at at time zone s.timezone, 'FMDy FMDD FMMon'), ''),
             fmt_clock(o.starts_at, s.timezone, v_fmt),
             nullif(rm.name, ''),
             nullif('with ' || split_part(coalesce(i.display_name, ''), ' ', 1), 'with '))
      into v_class_line
      from class_occurrences o
      left join rooms rm on rm.id = o.room_id
      left join instructors i on i.id = o.instructor_id
     where o.id = v_occ_id;
  end if;
  v_sub  := replace(v_sub,  '{class_line}', coalesce(v_class_line, ''));
  v_txt  := replace(v_txt,  '{class_line}', coalesce(v_class_line, ''));
  v_html := replace(v_html, '{class_line}', coalesce(v_class_line, ''));

  -- Decision 101: {class_when} — the instructor-facing class line, "Class on Day
  -- at time" plus the room ONLY when the studio has more than one. Resolved from
  -- occurrence_id, so every instructor template that carries it reads the same,
  -- and the room rule lives in one place. Known-optional (strip-exempt below).
  if v_occ_id is not null then
    select coalesce(o.name, ct.name, 'your class') || ' on '
           || to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth')
           || ' at ' || fmt_clock(o.starts_at, s.timezone, v_fmt)
           || case when (select count(*) from rooms where studio_id = s.id and status = 'active') > 1
                     and nullif(rm.name, '') is not null then ' in ' || rm.name else '' end
      into v_class_when
      from class_occurrences o
      left join class_types ct on ct.id = o.class_type_id
      left join rooms rm on rm.id = o.room_id
     where o.id = v_occ_id;
  end if;
  v_sub  := replace(v_sub,  '{class_when}', coalesce(v_class_when, ''));
  v_txt  := replace(v_txt,  '{class_when}', coalesce(v_class_when, ''));
  v_html := replace(v_html, '{class_when}', coalesce(v_class_when, ''));

  -- Decision 101: {schedule_link} — the instructor's own schedule. Filled for a
  -- staff recipient when the payload did not already supply it (the digest and a
  -- test send supply their own). Known-optional (strip-exempt below).
  if v_is_staff then
    v_sub  := replace(v_sub,  '{schedule_link}', instructor_portal_url(s.id, '/instructor/schedule'));
    v_txt  := replace(v_txt,  '{schedule_link}', instructor_portal_url(s.id, '/instructor/schedule'));
    v_html := replace(v_html, '{schedule_link}', instructor_portal_url(s.id, '/instructor/schedule'));
  end if;

  -- Accent (80a): a static template button carries {accent}/{accent_on}.
  rule := coalesce(s.accent_color, '#78716C');
  v_on := email_on_accent(rule);
  v_html := replace(replace(v_html, '{accent_on}', v_on), '{accent}', rule);
  v_txt  := replace(replace(v_txt,  '{accent_on}', v_on), '{accent}', rule);

  -- STRIP any residual {token}: a known-optional one silently, anything else to
  -- empty AND recorded in `stripped` (deliver_notification logs it). No token
  -- ever reaches a member.
  for v_tok in
    select distinct (regexp_matches(coalesce(v_sub,'') || E'\n' || coalesce(v_txt,'') || E'\n' || coalesce(v_html,''),
                                    '\{([a-z_][a-z0-9_]*)\}', 'g'))[1]
  loop
    if not (v_tok = any (array['where_line','free_first_line','free_first_html',
                               'next_three_line','next_three_html','system_text','system_html','class_line',
                               'class_when','schedule_link','replaces_line','replaces_html','roster_table',
                               'button','promo_line'])) then
      v_stripped := array_append(v_stripped, v_tok);
    end if;
    v_sub  := replace(v_sub,  '{' || v_tok || '}', '');
    v_txt  := replace(v_txt,  '{' || v_tok || '}', '');
    v_html := replace(v_html, '{' || v_tok || '}', '');
  end loop;

  select nullif(concat_ws(', ',
           nullif(l.address ->> 'line1', ''), nullif(l.address ->> 'line2', ''),
           nullif(l.address ->> 'city', ''), nullif(l.address ->> 'postal_code', ''),
           nullif(l.address ->> 'country', '')), '')
    into v_addr
    from locations l
   where l.studio_id = s.id and l.status = 'active'
   order by l.is_primary desc, l.created_at limit 1;

  if v_is_staff then
    v_link := coalesce(nullif(notification_setting('staff_app_origin'), ''),
                       'https://app.studiior.com') || '/billing';
  else
  v_link := 'https://' || s.slug || '.'
            || coalesce(notification_setting('member_app_domain'), 'studiior.app') || '/settings';
  end if;

  v_ig := nullif(s.instagram_handle, '');
  v_contact := nullif(concat_ws(' · ', s.contact_email, s.contact_phone,
                 case when v_ig is not null then '@' || v_ig else null end), '');
  v_contact_html := nullif(concat_ws(' · ', s.contact_email, s.contact_phone,
                 case when v_ig is not null
                      then '<a href="https://instagram.com/' || v_ig || '" style="color:#78716C">@' || v_ig || '</a>'
                      else null end), '');

  v_always := p_template_key in ('class_cancelled', 'instructor_substituted',
                                 'guest_invite', 'guest_host_cancelled',
                                 'guest_waiver_reminder', 'guest_waiver_host_nudge',
                                 'member_invite', 'payment_failed', 'staff_message',
                                 'platform_billing_warning', 'class_moved',
                                 'shift_application_received', 'shift_approved',
                                 'shift_declined', 'shift_withdrawn');

  v_foot_txt := concat_ws(E'\n',
    v_contact, v_addr,
    case when v_is_staff then case when p_recipient_role = 'owner' then 'Your billing: ' || v_link end
         when p_template_key in ('member_invite', 'instructor_invite', 'guest_invite', 'guest_waiver_reminder')
         then 'You are getting this because ' || s.name || ' set up your account.'
         when v_always
         then 'We always send this one. It is about your booking or your membership. '
              || 'Choose which other emails you get: ' || v_link
         else 'Choose which emails you get: ' || v_link end);

  v_foot_html := concat_ws('<br>',
    v_contact_html, v_addr,
    case when v_is_staff then case when p_recipient_role = 'owner' then '<a href="' || v_link || '" style="color:#78716C">Your billing</a>' end
         when p_template_key in ('member_invite', 'instructor_invite', 'guest_invite', 'guest_waiver_reminder')
         then 'You are getting this because ' || s.name || ' set up your account.'
         when v_always
         then 'We always send this one. It is about your booking or your membership. '
              || '<a href="' || v_link || '" style="color:#78716C">Choose which other emails you get</a>'
         else '<a href="' || v_link || '" style="color:#78716C">Choose which emails you get</a>' end);

  v_logo := case when s.logo_url is not null
    then '<img src="' || s.logo_url || '" alt="' || replace(s.name, '"', '')
         || '" width="40" height="40" style="display:block;border:0;border-radius:6px" />'
    else '<div style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;'
         || 'font-weight:600;font-size:18px;color:#14170E">' || s.name || '</div>' end;

  -- The FLUID frame. The content table ("sd-card") is width 100% / max-width 600px
  -- so it reflows on a phone; the <style> media query shrinks the padding and body
  -- text under 480px and caps images; the MSO ghost table stays 600 for Outlook.
  return query select v_sub, v_txt || E'\n\n--\n' || v_foot_txt,
    '<style>'
      || '.sd-body img{max-width:100%;height:auto}'
      || '@media only screen and (max-width:480px){'
      || '.sd-card{width:100%!important;border-radius:0!important}'
      || '.sd-pad{padding-left:16px!important;padding-right:16px!important}'
      || '.sd-body{font-size:14px!important;line-height:22px!important}'
      || '}'
      || '</style>'
      || '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" '
      || 'style="background:#F5F5F4;margin:0;padding:0;width:100%"><tr>'
      || '<td align="center" style="padding:24px 12px">'
      || '<!--[if mso]><table role="presentation" width="600" cellspacing="0" cellpadding="0" border="0"><tr><td><![endif]-->'
      || '<table role="presentation" width="100%" class="sd-card" cellspacing="0" cellpadding="0" border="0" '
      || 'style="width:100%;max-width:600px;background:#FFFFFF;border-radius:12px">'
      || '<tr><td class="sd-pad" style="padding:28px 28px 0 28px">'
      || v_logo
      || '<div style="height:3px;width:44px;background:' || rule || ';margin:16px 0 4px"></div>'
      || '</td></tr>'
      || '<tr><td class="sd-pad sd-body" style="padding:12px 28px 8px 28px;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;'
      || 'font-size:15px;line-height:22px;color:#14170E">'
      || v_html
      || '</td></tr>'
      || '<tr><td class="sd-pad" style="padding:16px 28px 28px 28px">'
      || '<div style="border-top:1px solid #E7E5E4;padding-top:14px;'
      || 'font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;'
      || 'font-size:13px;line-height:18px;color:#78716C">' || v_foot_html || '</div>'
      || '</td></tr></table>'
      || '<!--[if mso]></td></tr></table><![endif]-->'
      || '</td></tr></table>',
    v_stripped;
end $function$;


-- 9. convert_keep_sweep (20260833190000:452): + offer_plan_id.
CREATE OR REPLACE FUNCTION public.convert_keep_sweep(p_studio_id uuid, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  st studio_settings%rowtype;
  s  studios%rowtype;
  v_offer membership_plans%rowtype;
  v_tz text; v_fmt text; v_now_date date;
  v_plans text; v_book text; v_buy text;
  v_offer_name text; v_offer_price text; v_offer_detail text;
  r record;
  v_iw jsonb; v_ends timestamptz; v_end_date date;
  v_attended boolean; v_noshow boolean; v_notpurch boolean;
  v_class_date date; v_when text; v_offer_ends text;
  v_payload jsonb; v_sched timestamptz;
  km record; v_newer boolean; v_has_active boolean; v_mend date; v_auto boolean;
  v_kbuy text; v_kpayload jsonb;
  v_atrisk_tpl text; v_unconv_tpl text;
  n int := 0;
begin
  if not is_service_context() then
    raise exception 'this is a scheduled job, not a user action' using errcode = 'PT403';
  end if;

  select * into st from studio_settings where studio_id = p_studio_id;
  if not found or not (coalesce(st.convert_sequence_enabled, false)
                       or coalesce(st.keep_sequence_enabled, false)
                       or coalesce(st.retention_tasks_enabled, false)) then
    return jsonb_build_object('queued', 0);
  end if;
  select * into s from studios where id = p_studio_id;
  v_tz  := s.timezone;
  v_fmt := coalesce(st.time_format, '24h');
  v_now_date := (p_now at time zone v_tz)::date;

  v_plans := member_portal_url(p_studio_id, '/account/plan');
  v_book  := member_portal_url(p_studio_id, '/book');
  if st.intro_offer_plan_id is not null then
    select * into v_offer from membership_plans where id = st.intro_offer_plan_id;
  end if;
  if v_offer.id is not null then
    v_buy        := member_portal_url(p_studio_id, '/buy/' || v_offer.id::text);
    v_offer_name := v_offer.name;
    v_offer_price  := fmt_money(v_offer.price_cents, v_offer.currency);
    v_offer_detail := plan_card_detail(v_offer.id);
  else
    v_buy        := v_plans;
    v_offer_name := 'a membership';
    v_offer_price := ''; v_offer_detail := '';
  end if;

  if coalesce(st.retention_tasks_enabled, false) or coalesce(st.keep_sequence_enabled, false) then
    insert into job_runs (job_key, run_for, status)
    values ('health_refresh:' || p_studio_id::text, v_now_date, 'done')
    on conflict (job_key, run_for) do nothing;
    if found then perform refresh_studio_health(p_studio_id); end if;
  end if;

  -- Decision 78 (d): the signed-up-but-never-booked nudge. A member who joined,
  -- has never held a booking, and is still free-first eligible gets one email at
  -- day 1 and again at day 7 if nothing is booked. It asks for a booking rather
  -- than following a class, so it runs BEFORE the opening skip below and sends
  -- even before the studio has opened, as long as there are published bookable
  -- classes to pick from. Capped per studio per night, oldest sign-ups first; the
  -- WHERE excludes anyone already sent this step, so the cap counts new emails and
  -- the newest never starve behind an already-emailed older cohort.
  if coalesce(st.convert_sequence_enabled, false)
     and exists (select 1 from class_occurrences o
                  where o.studio_id = p_studio_id and o.status = 'scheduled' and not o.hidden_from_members
                    and o.starts_at > p_now and month_published(p_studio_id, o.starts_at)) then
    v_sched := quiet_hours_shift((v_now_date + time '10:00') at time zone v_tz, v_tz);
    for r in
      select m.id as member_id,
             coalesce(nullif(m.first_name, ''), 'there') as first_name,
             case when m.joined_on <= v_now_date - 7 then 7 else 1 end as step
        from members m
       where m.studio_id = p_studio_id
         and m.deleted_at is null
         and m.joined_on is not null
         and m.joined_on <= v_now_date - 1
         and not exists (select 1 from bookings b where b.member_id = m.id)
         and coalesce((free_first_eligibility_run(p_studio_id, m.id, null) ->> 'ok')::boolean, false)
         and not exists (select 1 from notifications nx
                          where nx.dedupe_key = 'convert_book_first:'
                            || (case when m.joined_on <= v_now_date - 7 then '7' else '1' end)
                            || ':' || m.id::text)
       order by m.joined_on asc, m.id
       limit greatest(coalesce(st.convert_book_first_daily_cap, 30), 0)
    loop
      v_payload := jsonb_build_object(
        'first_name', r.first_name, 'studio_name', s.name,
        'book_url', v_book, 'plans_url', v_plans);
      if queue_notification(p_studio_id, r.member_id, 'convert_book_first', v_payload,
            'convert_book_first:' || r.step::text || ':' || r.member_id::text, v_sched) is not null then n := n + 1; end if;
    end loop;
  end if;

  -- Decision 14(c): a studio that has not opened yet (no attended/checked-in
  -- class, or its first is still ahead) gets no convert/keep/retention action —
  -- nobody can have drifted before a class has run. The health refresh above
  -- still runs; member_health now returns insufficient_history for its members.
  if studio_opened_on(p_studio_id) is null
     or studio_opened_on(p_studio_id) > v_now_date then
    return jsonb_build_object('queued', n, 'skipped', 'not_opened');
  end if;

  select coalesce(ov.body, df.text_body) into v_unconv_tpl
    from notification_templates df
    left join notification_templates_overrides ov on ov.studio_id = p_studio_id and ov.key = 'task_unconverted_message'
   where df.key = 'task_unconverted_message';
  select coalesce(ov.body, df.text_body) into v_atrisk_tpl
    from notification_templates df
    left join notification_templates_overrides ov on ov.studio_id = p_studio_id and ov.key = 'task_at_risk_message'
   where df.key = 'task_at_risk_message';

  if coalesce(st.convert_sequence_enabled, false) then
  for r in
    select b.id as booking_id, b.member_id, b.status as bstatus,
           o.id as occ_id, o.starts_at, o.ends_at,
           coalesce(ct.name, 'your class') as class_name,
           split_part(coalesce(i.display_name, ''), ' ', 1) as instr_first,
           coalesce(nullif(m.first_name, ''), 'there') as first_name
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
      left join class_types ct on ct.id = o.class_type_id
      left join instructors i on i.id = o.instructor_id
      join members m on m.id = b.member_id
     where b.studio_id = p_studio_id
       and b.payment_source = 'comp'
       and m.deleted_at is null
       and not exists (select 1 from guest_passes gp
                        where gp.guest_booking_id = b.id and gp.host_member_id is not null)
  loop
    v_notpurch := not exists (select 1 from memberships ms where ms.member_id = r.member_id);
    v_attended := r.bstatus = 'attended'
                  or exists (select 1 from check_ins ci where ci.booking_id = r.booking_id);
    v_noshow   := r.bstatus = 'no_show';
    v_class_date := (r.starts_at at time zone v_tz)::date;
    v_iw   := intro_window(r.member_id, p_now);
    v_ends := nullif(v_iw ->> 'ends_at', '')::timestamptz;
    v_end_date := (v_ends at time zone v_tz)::date;
    v_when := to_char(r.starts_at at time zone v_tz, 'FMDay FMDD Mon') || ' at ' || fmt_clock(r.starts_at, v_tz, v_fmt);
    v_offer_ends := case when v_ends is not null then to_char(v_ends at time zone v_tz, 'FMDD Mon YYYY') else '' end;

    v_payload := jsonb_build_object(
      'first_name', r.first_name, 'studio_name', s.name,
      'class_name', r.class_name, 'when', v_when, 'occurrence_id', r.occ_id,
      'instructor_first_name', coalesce(nullif(r.instr_first, ''), 'your instructor'),
      'offer_plan_name', v_offer_name, 'offer_price', v_offer_price, 'offer_detail', v_offer_detail,
      'offer_ends', v_offer_ends, 'buy_url', v_buy,
      'plans_url', v_plans, 'book_url', v_book, 'offer_plan_id', v_offer.id);

    if r.bstatus = 'booked' and v_class_date = v_now_date + 1 then
      v_sched := quiet_hours_shift((v_now_date + time '18:00') at time zone v_tz, v_tz);
      if queue_notification(p_studio_id, r.member_id, 'convert_before_class', v_payload,
            'convert_before_class:' || r.booking_id::text, v_sched) is not null then n := n + 1; end if;
    end if;

    if v_noshow and v_notpurch and v_now_date = v_class_date + 1 then
      v_sched := quiet_hours_shift((v_now_date + time '10:00') at time zone v_tz, v_tz);
      if queue_notification(p_studio_id, r.member_id, 'convert_missed_you', v_payload,
            'convert_missed_you:' || r.booking_id::text, v_sched) is not null then n := n + 1; end if;
    end if;

    if v_attended and v_notpurch then
      if p_now >= r.ends_at + interval '2 hours' and p_now < r.ends_at + interval '26 hours' then
        v_sched := quiet_hours_shift(r.ends_at + interval '2 hours', v_tz);
        if queue_notification(p_studio_id, r.member_id, 'convert_after_class', v_payload,
              'convert_after_class:' || r.booking_id::text, v_sched) is not null then n := n + 1; end if;
      end if;
      if v_now_date = v_class_date + 3 then
        v_sched := quiet_hours_shift((v_now_date + time '10:00') at time zone v_tz, v_tz);
        if queue_notification(p_studio_id, r.member_id, 'convert_day3', v_payload,
              'convert_day3:' || r.booking_id::text, v_sched) is not null then n := n + 1; end if;
      end if;
      if v_now_date = v_class_date + 7 then
        v_sched := quiet_hours_shift((v_now_date + time '10:00') at time zone v_tz, v_tz);
        if queue_notification(p_studio_id, r.member_id, 'convert_day7', v_payload,
              'convert_day7:' || r.booking_id::text, v_sched) is not null then n := n + 1; end if;
        insert into member_tasks (studio_id, member_id, kind, reason, suggested_message, assigned_role)
        values (p_studio_id, r.member_id, 'unconverted_day7',
                'Free class ' || (v_now_date - v_class_date) || ' days ago, not yet booked again',
                replace(replace(replace(v_unconv_tpl, '{first_name}', r.first_name), '{studio_name}', s.name), '{offer_plan_name}', v_offer_name),
                st.retention_tasks_to)
        on conflict (member_id, kind) where status = 'open' do nothing;
      end if;
      if v_offer.id is not null and v_ends is not null and v_now_date = v_end_date then
        v_sched := quiet_hours_shift((v_now_date + time '10:00') at time zone v_tz, v_tz);
        if queue_notification(p_studio_id, r.member_id, 'convert_last_day', v_payload,
              'convert_last_day:' || r.booking_id::text || ':' || v_end_date::text, v_sched) is not null then n := n + 1; end if;
      end if;
    end if;
  end loop;
  end if;

  if coalesce(st.keep_sequence_enabled, false) then
    v_sched := quiet_hours_shift((v_now_date + time '10:00') at time zone v_tz, v_tz);
    for km in
      select ms.id as mid, ms.member_id, ms.plan_id, ms.status, ms.starts_on,
             ms.expires_on, ms.current_period_end, ms.credits_remaining,
             ms.auto_renew, ms.stripe_subscription_id,
             pl.name as plan_name, pl.type as plan_type, pl.status as plan_status,
             coalesce(nullif(m.first_name, ''), 'there') as first_name
        from memberships ms
        join membership_plans pl on pl.id = ms.plan_id
        join members m on m.id = ms.member_id
       where ms.studio_id = p_studio_id and m.deleted_at is null
    loop
      v_mend := coalesce(km.expires_on, (km.current_period_end at time zone v_tz)::date);
      v_auto := coalesce(km.auto_renew, false) or km.stripe_subscription_id is not null;
      v_newer := exists (select 1 from memberships ms2
                          where ms2.member_id = km.member_id and ms2.id <> km.mid
                            and ms2.status = 'active'
                            and coalesce(ms2.starts_on, '-infinity'::date) >= coalesce(km.starts_on, '-infinity'::date));
      v_has_active := exists (select 1 from memberships ms2
                               where ms2.member_id = km.member_id and ms2.status = 'active'
                                 and coalesce(ms2.expires_on, 'infinity'::date) > v_now_date);
      v_kbuy := case when coalesce(km.plan_status, 'active') <> 'archived'
                     then member_portal_url(p_studio_id, '/buy/' || km.plan_id::text)
                     else v_plans end;
      v_kpayload := jsonb_build_object(
        'first_name', km.first_name, 'studio_name', s.name,
        'plan_name', km.plan_name,
        'expires_on', case when v_mend is not null then to_char(v_mend, 'FMDD Mon YYYY') else '' end,
        'credits_left', coalesce(km.credits_remaining, 0),
        'buy_url', v_kbuy, 'book_url', v_book, 'schedule_url', v_book);

      if km.plan_type = 'recurring' and not v_auto and km.status in ('active', 'past_due')
         and not v_newer and v_mend is not null then
        if v_now_date = v_mend - 7 and queue_notification(p_studio_id, km.member_id, 'keep_renew_7',
              v_kpayload, 'keep_renew_7:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
        if v_now_date = v_mend - 1 and queue_notification(p_studio_id, km.member_id, 'keep_renew_1',
              v_kpayload, 'keep_renew_1:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
        if v_now_date = v_mend and queue_notification(p_studio_id, km.member_id, 'keep_renew_0',
              v_kpayload, 'keep_renew_0:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
        if v_now_date = v_mend + 3 and not v_has_active
           and queue_notification(p_studio_id, km.member_id, 'keep_lapsed_3',
              v_kpayload, 'keep_lapsed_3:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
      end if;

      if km.credits_remaining > 0 and km.expires_on is not null
         and km.status = 'active' and not v_newer then
        if v_now_date = km.expires_on - 7 and queue_notification(p_studio_id, km.member_id, 'keep_credits_7',
              v_kpayload, 'keep_credits_7:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
        if v_now_date = km.expires_on - 2 and queue_notification(p_studio_id, km.member_id, 'keep_credits_2',
              v_kpayload, 'keep_credits_2:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
      end if;

      if v_mend is not null and not v_has_active
         and not exists (select 1 from memberships ms3
                          where ms3.member_id = km.member_id
                            and coalesce(ms3.starts_on, '-infinity'::date) > v_mend) then
        if v_now_date = v_mend + 30 and queue_notification(p_studio_id, km.member_id, 'keep_winback_30',
              v_kpayload, 'keep_winback_30:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
        if v_now_date = v_mend + 60 and queue_notification(p_studio_id, km.member_id, 'keep_winback_60',
              v_kpayload, 'keep_winback_60:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
      end if;
    end loop;
  end if;

  if coalesce(st.retention_tasks_enabled, false) then
    update member_tasks mt
       set status = 'dismissed', closed_at = now(), close_note = 'recovered'
     where mt.studio_id = p_studio_id and mt.status = 'open'
       and mt.kind in ('at_risk', 'drifting_fyi')
       and ( coalesce((select m.health_band from members m where m.id = mt.member_id), 'new') in ('healthy', 'new')
          or exists (select 1 from check_ins ci where ci.member_id = mt.member_id and ci.checked_in_at > mt.created_at) );

    for km in
      select m.id as member_id, m.health_band as hb, m.health_reason as hr,
             coalesce(nullif(m.first_name, ''), 'there') as first_name
        from members m
       where m.studio_id = p_studio_id and m.status <> 'archived'
         and m.health_band in ('at_risk', 'drifting')
    loop
      if km.hb = 'at_risk' then
        insert into member_tasks (studio_id, member_id, kind, reason, suggested_message, assigned_role)
        values (p_studio_id, km.member_id, 'at_risk', km.hr,
                replace(replace(v_atrisk_tpl, '{first_name}', km.first_name), '{studio_name}', s.name),
                st.retention_tasks_to)
        on conflict (member_id, kind) where status = 'open' do nothing;
      elsif km.hb = 'drifting' then
        if not exists (select 1 from notifications nx where nx.member_id = km.member_id
                        and nx.template_key = 'keep_drifting' and nx.created_at > p_now - interval '30 days') then
          v_sched := quiet_hours_shift((v_now_date + time '10:00') at time zone v_tz, v_tz);
          if queue_notification(p_studio_id, km.member_id, 'keep_drifting',
                jsonb_build_object('first_name', km.first_name, 'studio_name', s.name, 'schedule_url', v_book, 'book_url', v_book),
                'keep_drifting:' || km.member_id::text || ':' || v_now_date::text, v_sched) is not null then n := n + 1; end if;
        end if;
        insert into member_tasks (studio_id, member_id, kind, reason, suggested_message, assigned_role)
        values (p_studio_id, km.member_id, 'drifting_fyi', km.hr, null, st.retention_tasks_to)
        on conflict (member_id, kind) where status = 'open' do nothing;
      end if;
    end loop;
  end if;

  return jsonb_build_object('queued', n);
end $function$;


-- retention_email_context (20260833550000:1266): + offer_plan_id.
CREATE OR REPLACE FUNCTION public.retention_email_context(p_member_id uuid, p_situation text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s studios%rowtype; st studio_settings%rowtype; m members%rowtype;
  v_studio uuid; v_tz text; v_today date;
  v_last_class text; v_last_date date; v_instr text;
  v_days int; v_plan text; v_expires date;
  v_offer membership_plans%rowtype; v_offer_name text; v_buy text; v_book text;
  v_offer_price text; v_offer_detail text;
  v_top_type text; v_top_count int; v_untried text;
begin
  select studio_id into v_studio from members where id = p_member_id;
  if v_studio is null then raise exception 'no such member' using errcode = 'PT404'; end if;
  if not retention_can_act(v_studio) then
    raise exception 'that is not your member' using errcode = 'PT403';
  end if;
  select * into s from studios where id = v_studio;
  select * into st from studio_settings where studio_id = v_studio;
  select * into m from members where id = p_member_id;
  v_tz := s.timezone;
  v_today := (now() at time zone v_tz)::date;

  select coalesce(ct.name, o.name, 'your class'),
         (o.starts_at at time zone v_tz)::date,
         split_part(coalesce(i.display_name, ''), ' ', 1)
    into v_last_class, v_last_date, v_instr
    from check_ins ci
    join class_occurrences o on o.id = ci.occurrence_id
    left join class_types ct on ct.id = o.class_type_id
    left join instructors i on i.id = o.instructor_id
   where ci.member_id = p_member_id
   order by ci.checked_in_at desc limit 1;
  if v_last_class is null then
    select coalesce(ct.name, o.name, 'your class'),
           (o.starts_at at time zone v_tz)::date,
           split_part(coalesce(i.display_name, ''), ' ', 1)
      into v_last_class, v_last_date, v_instr
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
      left join class_types ct on ct.id = o.class_type_id
      left join instructors i on i.id = o.instructor_id
     where b.member_id = p_member_id
     order by o.starts_at desc limit 1;
  end if;

  v_days := greatest(0, v_today - coalesce(m.last_visit_at::date, m.first_visit_at::date, v_last_date, v_today));

  select mp.name, coalesce(ms.expires_on, (ms.current_period_end at time zone v_tz)::date)
    into v_plan, v_expires
    from memberships ms join membership_plans mp on mp.id = ms.plan_id
   where ms.member_id = p_member_id
   order by (ms.status = 'active') desc,
            coalesce(ms.expires_on, (ms.current_period_end at time zone v_tz)::date, '-infinity'::date) desc
   limit 1;

  v_book := member_portal_url(v_studio, '/book');

  -- Decision 112 tokens: the member's most-attended class type and its count,
  -- and an active class type they have not tried.
  select ct.name, count(*) into v_top_type, v_top_count
    from check_ins ci
    join class_occurrences o on o.id = ci.occurrence_id
    join class_types ct on ct.id = o.class_type_id
   where ci.member_id = p_member_id
   group by ct.name order by count(*) desc, ct.name limit 1;
  select ct.name into v_untried
    from class_types ct
   where ct.studio_id = v_studio and ct.status = 'active'
     and not exists (select 1 from check_ins ci
                      join class_occurrences o2 on o2.id = ci.occurrence_id
                      where ci.member_id = p_member_id and o2.class_type_id = ct.id)
   order by ct.name limit 1;
  if st.intro_offer_plan_id is not null then
    select * into v_offer from membership_plans where id = st.intro_offer_plan_id;
  end if;
  if v_offer.id is not null then
    v_buy := member_portal_url(v_studio, '/buy/' || v_offer.id::text);
    v_offer_name := v_offer.name;
    v_offer_price  := fmt_money((plan_price_now_run(v_offer.id, now()) ->> 'price_cents')::int, v_offer.currency);
    v_offer_detail := plan_card_detail(v_offer.id);
  else
    v_buy := member_portal_url(v_studio, '/account/plan');
    v_offer_name := 'a membership';
    v_offer_price := ''; v_offer_detail := '';
  end if;

  return jsonb_build_object(
    'first_name', coalesce(nullif(m.first_name, ''), 'there'),
    'last_class', v_last_class,
    'last_class_date', case when v_last_date is not null then to_char(v_last_date, 'FMDD Mon') else '' end,
    'instructor_first', coalesce(nullif(v_instr, ''), 'your instructor'),
    'days_since', v_days::text,
    'plan_name', coalesce(v_plan, 'your plan'),
    'expires_on', case when v_expires is not null then to_char(v_expires, 'FMDay FMDD Mon') else '' end,
    'offer_plan_name', v_offer_name, 'offer_price', v_offer_price, 'offer_detail', v_offer_detail,
    'buy_url', v_buy, 'book_url', v_book, 'studio_name', s.name, 'offer_plan_id', v_offer.id,
    'top_class_type', coalesce(nullif(v_top_type,''), 'your usual class'),
    'top_class_count', coalesce(v_top_count, 0)::text,
    'untried_class_type', coalesce(nullif(v_untried,''), 'another class'));
end $function$;


-- template_sample_context (20260833650000:1349): + offer_plan_id.
CREATE OR REPLACE FUNCTION public.template_sample_context(p_studio_id uuid, p_to_email text, p_first_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s studios%rowtype; st studio_settings%rowtype; v_tz text; v_fmt text;
  v_plan membership_plans%rowtype; o record; v_when text; v_offer_ends text;
  v_n3 text; v_n3line text; v_n3html text; v_links text;
  v_clist text; v_roster text; v_roster_html text; v_li text;
  v_fee text;
begin
  select * into s from studios where id = p_studio_id;
  select * into st from studio_settings where studio_id = p_studio_id;
  v_tz := s.timezone; v_fmt := coalesce(st.time_format, '24h');
  v_fee := fmt_money(coalesce(nullif(st.free_first_reservation_fee_cents, 0), 15000), s.currency);

  select o2.id, coalesce(ct.name, o2.name, 'a class') as cname, o2.starts_at,
         rm.name as room, split_part(coalesce(i.display_name, ''), ' ', 1) as instr
    into o
    from class_occurrences o2
    left join class_types ct on ct.id = o2.class_type_id
    left join rooms rm on rm.id = o2.room_id
    left join instructors i on i.id = o2.instructor_id
   where o2.studio_id = p_studio_id and o2.status = 'scheduled' and o2.starts_at > now()
   order by o2.starts_at limit 1;

  if st.intro_offer_plan_id is not null then
    select * into v_plan from membership_plans where id = st.intro_offer_plan_id;
  end if;
  if v_plan.id is null then
    select * into v_plan from membership_plans
     where studio_id = p_studio_id and status = 'active' order by sort_order limit 1;
  end if;

  v_when := case when o.starts_at is not null
    then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD Mon') || ' at ' || fmt_clock(o.starts_at, v_tz, v_fmt)
    else '' end;
  v_offer_ends := to_char((now() + interval '14 days') at time zone v_tz, 'FMDD Mon YYYY');

  with s3(nm, ts) as (
    values
      ('Reformer Flow', ((((now() at time zone v_tz)::date + 1) + time '07:00') at time zone v_tz)),
      ('Barre',         ((((now() at time zone v_tz)::date + 2) + time '18:00') at time zone v_tz)),
      ('Mat Pilates',   ((((now() at time zone v_tz)::date + 3) + time '09:00') at time zone v_tz))
  )
  select
    string_agg(to_char(ts at time zone v_tz, 'FMDy ') || fmt_clock(ts, v_tz, v_fmt) || ' ' || nm, '; ' order by ts),
    string_agg('<a href="' || member_portal_url(p_studio_id, '/book') || '">'
               || to_char(ts at time zone v_tz, 'FMDy ') || fmt_clock(ts, v_tz, v_fmt) || ' ' || nm || '</a>', ', ' order by ts),
    string_agg(to_char(ts at time zone v_tz, 'FMDay FMDD FMMon, ') || fmt_clock(ts, v_tz, v_fmt) || ' ' || nm, E'\n' order by ts),
    string_agg('<li>' || to_char(ts at time zone v_tz, 'FMDay FMDD FMMon, ') || fmt_clock(ts, v_tz, v_fmt) || ' ' || nm || '</li>', '' order by ts)
    into v_n3, v_links, v_roster, v_li
    from s3;
  v_clist := v_roster;
  v_roster_html := '<ul style="margin:0;padding-left:20px">' || v_li || '</ul>';
  v_n3line := ' Here are the next ones with space: ' || v_n3 || '.';
  v_n3html := '<p>Here are the next ones with space: ' || v_links || '.</p>';

  return jsonb_build_object(
    'to_email', p_to_email,
    'first_name', p_first_name,
    'studio_name', s.name,
    'class_name', coalesce(o.cname, 'a class'),
    'occurrence_id', o.id,
    'when', v_when,
    'where_line', case when nullif(o.room, '') is not null then ', in ' || o.room else '' end,
    'when_short', 'tomorrow',
    'when_time', case when o.starts_at is not null then fmt_clock(o.starts_at, v_tz, v_fmt) else '' end,
    'day', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMonth') else 'Monday 9 November' end,
    'time', case when o.starts_at is not null then fmt_clock(o.starts_at, v_tz, v_fmt) else '' end,
    'deadline_short', case when o.starts_at is not null then fmt_clock(o.starts_at - interval '12 hours', v_tz, v_fmt) || ' ' || to_char((o.starts_at - interval '12 hours') at time zone v_tz, 'FMDy') else 'the evening before' end,
    'cancel_deadline', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD Mon') else 'the day before' end,
    'manage_link', member_portal_url(p_studio_id, '/class/' || coalesce(o.id::text, '')),
    'book_url', member_portal_url(p_studio_id, '/book'),
    'schedule_url', member_portal_url(p_studio_id, '/book'),
    'offer_plan_name', coalesce(v_plan.name, 'a membership'),
    'offer_detail', coalesce(plan_card_detail(v_plan.id), ''),
    'offer_price', case when v_plan.id is not null then fmt_money(v_plan.price_cents, v_plan.currency) else '' end,
    'offer_ends', v_offer_ends, 'offer_plan_id', v_plan.id,
    'buy_url', case when v_plan.id is not null then member_portal_url(p_studio_id, '/buy/' || v_plan.id::text) else member_portal_url(p_studio_id, '/account/plan') end,
    'plan_name', coalesce(v_plan.name, 'your plan'),
    'credits', '3', 'credits_left', '3',
    'expires_on', v_offer_ends, 'ends_on', v_offer_ends,
    'renew_url', case when v_plan.id is not null then member_portal_url(p_studio_id, '/buy/' || v_plan.id::text) else member_portal_url(p_studio_id, '/account/plan') end,
    'last_class', coalesce(o.cname, 'your class'),
    'last_class_date', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDD Mon') else '' end,
    'instructor_first', coalesce(nullif(o.instr, ''), 'your instructor'),
    'instructor_first_name', coalesce(nullif(o.instr, ''), 'your instructor'),
    'days_since', '10',
    'product', 'Grip socks', 'quantity', '1')
  || jsonb_build_object(
    'instructor_name', p_first_name,
    'href', instructor_portal_url(p_studio_id, '/instructor/schedule'),
    'schedule_link', instructor_portal_url(p_studio_id, '/instructor/schedule'),
    'booked_line', '3 booked',
    'count', '3',
    'plural', 's',
    'month', to_char(now() at time zone v_tz, 'FMMonth'),
    'period', 'this period',
    'due_on', to_char((now() + interval '3 days') at time zone v_tz, 'FMDay FMDD Mon'),
    'due_wording', 'soon',
    'hours', '12',
    'amount', fmt_money(90000, s.currency),
    'old_when', case when o.starts_at is not null
                     then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMonth YYYY, ') || fmt_clock(o.starts_at, v_tz, v_fmt)
                     else 'Monday 9 November, 07:00' end,
    'cancelled_count', '1',
    'booked', '4',
    'capacity', '8',
    'reason', 'cancelled by the studio',
    'claim_url', member_portal_url(p_studio_id, '/class/' || coalesce(o.id::text, '')))
  || jsonb_build_object(
    'next_three', v_n3,
    'next_three_line', v_n3line,
    'next_three_html', v_n3html,
    'class_list', v_clist,
    'roster', v_roster,
    'roster_html', v_roster_html)
  || jsonb_build_object(
    'staff_first_name', p_first_name,
    'member_name', coalesce(nullif(p_first_name, ''), 'A member'),
    'message', 'Hi, could I move my Saturday class to Sunday?',
    'message_html', 'Hi, could I move my Saturday class to Sunday?',
    'messages_url', member_portal_url(p_studio_id, '/messages'),
    'reply_url', coalesce(nullif(notification_setting('staff_app_origin'), ''), 'https://app.studiior.com') || '/messages')
  || jsonb_build_object(
    'old_class_name', coalesce(o.cname, 'a class'),
    'bookings_url', member_portal_url(p_studio_id, '/'))
  || jsonb_build_object(
    'class_name', coalesce(o.cname, 'a class'),
    'day', to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMonth'),
    'n_more', 2,
    'cutoff_time', coalesce(v_when, 'the cut-off'),
    'class_list_core', '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:12px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-size:16px;font-weight:600;color:#14170E">' || coalesce(o.cname, 'a class') || '</div><div style="font-size:14px;color:#57534E;margin-top:4px">' || coalesce(v_when, 'soon') || '</div><div style="font-size:13px;color:#78716C;margin-top:2px">3 in already · 4 spots left</div><table role="presentation" style="margin-top:12px"><tr><td style="border-radius:6px;background:{accent}"><a href="#" style="display:inline-block;padding:10px 20px;color:{accent_on};text-decoration:none;font-weight:600;border-radius:6px">Move me to this class</a></td></tr></table></td></tr></table>',
    'class_list_core_text', '- ' || coalesce(o.cname, 'a class') || ' · ' || coalesce(v_when, 'soon') || ' (3 in already, 4 spots left)')
  || jsonb_build_object(
    'n_running', 2, 'n_cancelled', 1,
    'pay_line', 'You''re paid on who''s checked in.',
    'going_ahead', '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:12px 0;border-collapse:collapse"><tr><td colspan="3" style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;color:#14170E;padding:0 0 6px 0">Running</td></tr><tr><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Time</th><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Class</th><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Booked</th></tr><tr><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">' || fmt_clock(((now() at time zone v_tz)::date + time '07:00') at time zone v_tz, v_tz, v_fmt) || '</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">Reformer Flow</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">4 of 6</td></tr><tr><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">' || fmt_clock(((now() at time zone v_tz)::date + time '18:00') at time zone v_tz, v_tz, v_fmt) || '</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">Barre</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">5 of 8</td></tr></table>',
    'going_ahead_text', 'Running' || E'\n  ' || fmt_clock(((now() at time zone v_tz)::date + time '07:00') at time zone v_tz, v_tz, v_fmt) || '  Reformer Flow  4 of 6' || E'\n  ' || fmt_clock(((now() at time zone v_tz)::date + time '18:00') at time zone v_tz, v_tz, v_fmt) || '  Barre  5 of 8',
    'cancelled', '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:12px 0;border-collapse:collapse"><tr><td colspan="3" style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;color:#14170E;padding:0 0 6px 0">Cancelled, not enough bookings</td></tr><tr><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Time</th><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Class</th><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Booked</th></tr><tr><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">' || fmt_clock(((now() at time zone v_tz)::date + time '09:00') at time zone v_tz, v_tz, v_fmt) || '</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">Mat Pilates</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">1 of 3 needed</td></tr></table>',
    'cancelled_text', 'Cancelled, not enough bookings' || E'\n  ' || fmt_clock(((now() at time zone v_tz)::date + time '09:00') at time zone v_tz, v_tz, v_fmt) || '  Mat Pilates  1 of 3 needed')
  -- Decision 103: reservation tokens.
  || jsonb_build_object(
    'fee', v_fee,
    'from_date', to_char(now() at time zone v_tz, 'FMDD Mon'),
    'deadline', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD Mon') else 'the day before' end,
    'plans_url', member_portal_url(p_studio_id, '/account/plan'),
    'pay_url', member_portal_url(p_studio_id, '/class/' || coalesce(o.id::text, '')),
    'cancel_url', member_portal_url(p_studio_id, '/class/' || coalesce(o.id::text, '')),
    'reservation_line', '',
    'reservation_html', '')
  -- Decision 103a: closure sample tokens so the Templates preview fills them.
  || jsonb_build_object(
    'from', to_char(now() at time zone v_tz, 'FMDy FMDD FMMon'),
    'to', to_char((now() + interval '2 days') at time zone v_tz, 'FMDy FMDD FMMon'),
    'resume_date', to_char((now() + interval '7 days') at time zone v_tz, 'FMDay FMDD FMMonth YYYY'),
    'notice', 'We are closed for renovations.',
    'class_list_html', closure_card_html('Reformer Flow', v_clist),
    'schedule_url', instructor_portal_url(p_studio_id, '/instructor/schedule'))
  -- Housekeeping: refund + credited-back tokens so those previews render clean.
  || jsonb_build_object(
    'method', 'GCash', 'reference', 'rfd-sample-0001',
    'plan_link', member_portal_url(p_studio_id, '/account/plan'), 'button', '')
  -- Step 11: the roster table rows and a two-paragraph sample message.
  || jsonb_build_object(
    'roster_rows', jsonb_build_array(
      jsonb_build_object('day', 'Mon 7 Dec', 'time', fmt_clock(timestamptz '2026-12-07 07:00+00', 'UTC', v_fmt), 'class', 'Reformer Flow'),
      jsonb_build_object('day', 'Wed 9 Dec', 'time', fmt_clock(timestamptz '2026-12-09 18:00+00', 'UTC', v_fmt), 'class', 'Reformer Sculpt')),
    'message', E'Hi! Just a reminder about tomorrow.\n\nBring grip socks and water.\nSee you there!',
    'message_html', 'Hi! Just a reminder about tomorrow.<br><br>Bring grip socks and water.<br>See you there!');
end $function$;


-- ===========================================================================
-- 10. free_first_eligibility_run (20260833370000:255) and member_has_had_free:
--     a late-cancelled comp seat staff returned does not count.
-- ===========================================================================
create or replace function free_first_eligibility_run(
  p_studio_id uuid, p_member_id uuid, p_exclude_booking uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_member members%rowtype;
  v_has_hostnull  boolean;
  v_noshow        int;
  v_late_cancel   int;
  v_comp_attended int;
  v_comp_live     int;
  v_other_qual    int;
  v_has_membership boolean;
  -- Decision 30(d, continued): a studio-independent cut-over. Late cancels on or
  -- after this use the free class; earlier ones are not reassessed.
  v_cutover constant timestamptz := '2026-11-09 00:00:00+00';
begin
  select * into v_member from members where id = p_member_id;
  if not found or v_member.studio_id <> p_studio_id then
    raise exception 'no such member here' using errcode = 'PT404';
  end if;

  if not coalesce((select free_first_class_enabled from studio_settings
                    where studio_id = p_studio_id), false) then
    return jsonb_build_object('ok', false, 'reason', 'not_enabled');
  end if;

  if exists (select 1 from members
              where studio_id = p_studio_id and id <> p_member_id
                and normalize_email_key(email) = normalize_email_key(v_member.email)) then
    return jsonb_build_object('ok', false, 'reason', 'already_member');
  end if;

  -- Decision 98: one free class per person. If a same-person twin (normalised
  -- name OR phone) of this member has already had a free class, this one is a
  -- duplicate. 'Make this their free class' overrides it (convert_booking_to_free_first).
  if exists (select 1 from same_person_match(p_studio_id, p_member_id) sp
              where member_has_had_free(p_studio_id, sp)) then
    return jsonb_build_object('ok', false, 'reason', 'duplicate');
  end if;

  if exists (select 1 from guest_passes
              where studio_id = p_studio_id and host_member_id is not null
                and normalize_email_key(guest_email) = normalize_email_key(v_member.email)) then
    return jsonb_build_object('ok', false, 'reason', 'already_had_free');
  end if;

  v_has_hostnull := exists (select 1 from guest_passes
              where studio_id = p_studio_id and host_member_id is null
                and normalize_email_key(guest_email) = normalize_email_key(v_member.email));

  if v_has_hostnull then
    select
      count(*) filter (where b.payment_source = 'comp' and b.status = 'no_show'),
      count(*) filter (where b.payment_source = 'comp' and b.status = 'late_cancelled'
                         and b.cancelled_at >= v_cutover
                         -- Decision 36 (a): staff returned it.
                         and not exists (select 1 from credit_ledger cl where cl.booking_id = b.id
                                          and cl.reason = 'cancellation_refund')),
      count(*) filter (where b.payment_source = 'comp' and b.status = 'attended'),
      count(*) filter (where b.payment_source = 'comp' and b.status in ('booked','waitlisted','pending_payment')),
      count(*) filter (where b.payment_source <> 'comp' and b.status in ('booked','waitlisted','attended','no_show','pending_payment'))
      into v_noshow, v_late_cancel, v_comp_attended, v_comp_live, v_other_qual
      from bookings b
     where b.member_id = p_member_id and b.studio_id = p_studio_id
       and (p_exclude_booking is null or b.id <> p_exclude_booking);
    v_has_membership := exists (select 1 from memberships ms where ms.member_id = p_member_id);

    if v_comp_attended > 0 or v_has_membership or v_comp_live > 0 or v_other_qual > 0 then
      return jsonb_build_object('ok', false, 'reason', 'already_had_free');
    elsif v_noshow >= 1 then
      -- Decision 30 (d): one no-show uses the free class.
      return jsonb_build_object('ok', false, 'reason', 'missed');
    elsif v_late_cancel >= 1 then
      -- Decision 30 (d, continued): a late cancel on/after the cut-over uses it.
      return jsonb_build_object('ok', false, 'reason', 'late_cancel');
    else
      return jsonb_build_object('ok', true);
    end if;
  end if;

  if exists (select 1 from bookings
              where member_id = p_member_id and studio_id = p_studio_id
                and status in ('booked','waitlisted','attended','no_show','pending_payment')
                and (p_exclude_booking is null or id <> p_exclude_booking)) then
    return jsonb_build_object('ok', false, 'reason', 'not_first');
  end if;

  return jsonb_build_object('ok', true);
end $$;

create or replace function member_has_had_free(p_studio_id uuid, p_member_id uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  -- "Had a free class" is a comp seat the member actually holds or used: a free
  -- first class is a comp booking (book_first_free writes both the comp booking
  -- AND the host-null pass), so the comp booking in a used state IS the test. A
  -- TIMELY-cancelled comp ('cancelled') is not counted — the gate restores it —
  -- so a lingering host-null pass must NOT be read as "had free" on its own.
  -- Decision 36 (a): a late-cancelled comp seat the studio returned is not counted.
  select exists (
    select 1 from bookings b
     where b.member_id = p_member_id and b.studio_id = p_studio_id
       and b.payment_source = 'comp'
       and b.status in ('booked','attended','no_show','late_cancelled')
       and not (b.status = 'late_cancelled'
                and exists (select 1 from credit_ledger cl where cl.booking_id = b.id
                             and cl.reason = 'cancellation_refund')));
$$;
revoke execute on function member_has_had_free(uuid, uuid) from public, anon, authenticated;
grant  execute on function member_has_had_free(uuid, uuid) to service_role;

-- 11. member_activity (20260833550000:857): + the staff-only credit_returned arm.
CREATE OR REPLACE FUNCTION public.member_activity(p_member_id uuid, p_from date, p_to date)
 RETURNS TABLE(at timestamp with time zone, kind text, title text, detail text, credit_delta integer, balance_after integer, amount_cents integer, currency text, occurrence_id uuid, booking_id uuid, membership_id uuid, plan_name text, due_cents integer, is_free_first boolean, occurrence_start timestamp with time zone, instructor_first text, credits_left_after integer, payment_method text, recorded_by_name text, plan_classes integer, plan_valid_to date, unused_credits integer, payment_source text, is_paid boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
declare v_studio uuid; v_is_staff boolean; v_owns boolean;
begin
  select studio_id into v_studio from members where id = p_member_id;
  if v_studio is null then raise exception 'no such member' using errcode = 'PT404'; end if;
  v_owns := exists (select 1 from members m where m.id = p_member_id and m.user_id = auth.uid());
  v_is_staff := coalesce(is_desk_up(v_studio), false) or is_service_context();
  if not (v_owns or v_is_staff) then
    raise exception 'that is not your statement' using errcode = 'PT403';
  end if;

  return query
  with led as (
    select cl.id, cl.delta, cl.reason::text as reason, cl.booking_id, cl.membership_id,
           cl.created_at,
           (sum(cl.delta) over (order by cl.created_at, cl.id))::int as bal,
           (sum(cl.delta) over (partition by cl.membership_id order by cl.created_at, cl.id))::int as membership_bal
      from credit_ledger cl
     where cl.member_id = p_member_id
  ),
  -- A purchase payment claims the Nth 'purchase' ledger row of its membership;
  -- a refunded payment claims the Nth negative 'manual' row of its membership.
  -- Rank joins, so each ledger id is claimed at most once; a grant with no
  -- payment (e.g. a complimentary membership) stays unclaimed and surfaces as its
  -- own "Credits added" line.
  purch_led as (
    select id, membership_id, row_number() over (partition by membership_id order by created_at, id) rn
      from led where reason = 'purchase' and membership_id is not null),
  purch_pay as (
    select p.id as payment_id, p.membership_id,
           row_number() over (partition by p.membership_id order by coalesce(p.paid_at, p.created_at), p.id) rn
      from payments p
     where p.member_id = p_member_id and p.membership_id is not null
       and p.status in ('succeeded', 'partially_refunded')),
  pay_grant as (
    select pp.payment_id, pl.id as ledger_id
      from purch_pay pp join purch_led pl on pl.membership_id = pp.membership_id and pl.rn = pp.rn),
  forfeit_led as (
    select id, membership_id, row_number() over (partition by membership_id order by created_at, id) rn
      from led where reason = 'manual' and delta < 0 and membership_id is not null),
  refund_pay as (
    select p.id as payment_id, p.membership_id,
           row_number() over (partition by p.membership_id order by coalesce(p.refunded_at, p.updated_at), p.id) rn
      from payments p
     where p.member_id = p_member_id and p.membership_id is not null
       and (p.refunded_at is not null or p.status in ('refunded', 'partially_refunded'))),
  pay_forfeit as (
    select rp.payment_id, fl.id as ledger_id
      from refund_pay rp join forfeit_led fl on fl.membership_id = rp.membership_id and fl.rn = rp.rn),
  ev as (
    -- Decision 95: a flex-rescue email was sent (staff only).
    select coalesce(nt.sent_at, nt.scheduled_for, nt.created_at) as at,
           'rescue_email' as kind, 'Rescue email sent' as title,
           case when nt.template_key = 'flex_rescue_2days'
                then 'Flex class still needs numbers'
                else 'Last call to move the booking' end as detail,
           null::uuid as ledger_id, null::int as amount_cents, null::text as currency,
           null::uuid as occurrence_id, null::uuid as booking_id, null::uuid as membership_id
      from notifications nt
     where nt.member_id = p_member_id and v_is_staff
       and nt.template_key in ('flex_rescue_2days','flex_rescue_final','free_rescue_2days','free_rescue_final')
    union all
    -- joined (staff only)
    select m.joined_on::timestamptz as at, 'joined' as kind, 'Joined the studio' as title,
           nullif('Came via ' || coalesce(m.source, ''), 'Came via ') as detail,
           null::uuid as ledger_id, null::int as amount_cents, null::text as currency,
           null::uuid as occurrence_id, null::uuid as booking_id, null::uuid as membership_id
      from members m where m.id = p_member_id and v_is_staff and m.joined_on is not null
    union all
    -- Decision 97: invited a guest (this member is the host). Derived from
    -- the invite snapshot, so it survives the guest's deletion or merge.
    select gp.invited_at as at, 'invited_guest' as kind,
           'Invited ' || coalesce(g.first_name, 'a guest') || ' to ' || coalesce(o.name, ct.name, 'a class') as title,
           null::text as detail,
           null::uuid as ledger_id, null::int as amount_cents, null::text as currency,
           gp.occurrence_id as occurrence_id, null::uuid as booking_id, null::uuid as membership_id
      from guest_passes gp
      join class_occurrences o on o.id = gp.occurrence_id
      left join class_types ct on ct.id = o.class_type_id
      left join members g on g.id = gp.guest_member_id
     where gp.host_member_id = p_member_id and gp.invited_at is not null
    union all
    -- Decision 97: invited by a host (this member is the guest). The host
    -- name is the invite snapshot, surviving the host's deletion or merge.
    select gp.invited_at as at, 'invited_by' as kind,
           'Invited by ' || coalesce(gp.host_name_at_invite, 'a member') as title,
           null::text as detail,
           null::uuid as ledger_id, null::int as amount_cents, null::text as currency,
           gp.occurrence_id as occurrence_id, null::uuid as booking_id, null::uuid as membership_id
      from guest_passes gp
     where gp.guest_member_id = p_member_id and gp.host_member_id is not null and gp.invited_at is not null
    union all
    -- Decision 97 (a): a member merged into this account (staff only). Read from
    -- the member.merged audit row so a past merge shows and the removed email survives.
    select al.created_at as at, 'merged' as kind,
           'Merged ' || coalesce(al.before->>'removed_email', 'an account') || ' into this account' as title,
           null::text as detail,
           null::uuid, null::int, null::text, null::uuid, null::uuid, null::uuid
      from audit_logs al
     where al.action = 'member.merged' and v_is_staff
       and (al.after->>'merged_into')::uuid = p_member_id
    union all
    -- Decision 100: a staff member booked a class for this member (staff only).
    -- Read from the booking.booked_by_staff audit row so the attribution survives.
    select al.created_at as at, 'booked_by_staff' as kind,
           'Booked by ' || coalesce(al.after->>'staff_first', 'the studio')
             || coalesce(' with ' || (al.after->>'source'), '') as title,
           null::text as detail,
           null::uuid, null::int, null::text, null::uuid, null::uuid, null::uuid
      from audit_logs al
     where al.action = 'booking.booked_by_staff' and v_is_staff
       and al.entity_id = p_member_id
    union all
    -- Decision 92 (b): removed from a class by staff. From the audit row, so the
    -- class name and the staff first name survive.
    select al.created_at as at, 'removed_by_studio' as kind,
           'Removed from ' || coalesce(al.after->>'class_name', 'a class')
             || ' by ' || coalesce(al.after->>'staff_first', 'the studio') as title,
           null::text as detail,
           null::uuid, null::int, null::text, null::uuid, al.entity_id, null::uuid
      from audit_logs al
     where al.action = 'booking.removed_by_staff' and v_is_staff
       and (al.before->>'member_id')::uuid = p_member_id
    union all
    -- Decision 36 (a): staff returned what a late cancel took (staff only). The
    -- credit itself rides the cancellation row, which claims its ledger entry.
    select al.created_at as at, 'credit_returned' as kind,
           'Credit returned by ' || coalesce(al.after->>'staff_first', 'the studio')
             || coalesce(': ' || nullif(al.after->>'note', ''), '') as title,
           null::text as detail,
           null::uuid, null::int, null::text, null::uuid, al.entity_id, null::uuid
      from audit_logs al
     where al.action = 'booking.credit_returned_by_studio' and v_is_staff
       and (al.before->>'member_id')::uuid = p_member_id

    union all
    -- booked / waitlisted / free first
    select b.booked_at,
           case when b.status = 'pending_payment' and b.payment_source = 'comp' then 'reservation_hold'
                when b.status = 'waitlisted' then 'waitlisted'
                when b.payment_source = 'comp'
                     and exists (select 1 from guest_passes gp where gp.guest_booking_id = b.id and gp.host_member_id is null)
                     then 'free_first'
                else 'booked' end,
           case when b.status = 'pending_payment' and b.payment_source = 'comp' then 'Payment pending for ' || coalesce(o.name, 'a class')
                when b.status = 'waitlisted' then 'Joined the waitlist for ' || coalesce(o.name, 'a class')
                when b.payment_source = 'comp'
                     and exists (select 1 from guest_passes gp where gp.guest_booking_id = b.id and gp.host_member_id is null)
                     then 'Booked a free first class — ' || coalesce(o.name, 'a class')
                when b.payment_source = 'group' then
                     (select case when gb.is_host
                                  then 'Group booking — ' || coalesce(o.name, 'a class') || ' · ' || mp.name
                                  else 'Booked by ' || hm.first_name || ' · ' || mp.name end
                        from group_bookings gb
                        join group_purchases gpu on gpu.id = gb.group_purchase_id
                        join membership_plans mp on mp.id = gpu.plan_id
                        join members hm on hm.id = gpu.host_member_id
                       where gb.booking_id = b.id)
                else 'Booked ' || coalesce(o.name, 'a class') end,
           case when b.payment_source = 'group' then
                  (select case when gb.is_host then (
                            select string_agg(coalesce(nullif(m2.first_name,''), m2.email), ', ')
                              from group_bookings gb2 join members m2 on m2.id = gb2.member_id
                             where gb2.group_purchase_id = gb.group_purchase_id and not gb2.is_host)
                          end
                     from group_bookings gb where gb.booking_id = b.id)
                when exists (select 1 from waitlist_offers wo where wo.booking_id = b.id and wo.outcome = 'accepted')
                then 'From the waitlist' end,
           b.credit_entry_id, null, null, b.occurrence_id, b.id, b.membership_id
      from bookings b left join class_occurrences o on o.id = b.occurrence_id
     where b.member_id = p_member_id
       and b.status in ('booked','attended','no_show','cancelled','late_cancelled','waitlisted','pending_payment')
    union all
    -- cancelled (carries the cancellation_refund, or 0 "class used")
    select b.cancelled_at,
           case when b.payment_source = 'comp'
                     and not exists (select 1 from guest_passes gp where gp.guest_booking_id = b.id and gp.host_member_id is null)
                     and not exists (select 1 from payments p2 where p2.booking_id = b.id and p2.kind = 'reservation_fee' and p2.status in ('succeeded','partially_refunded'))
                     then (case when exists (select 1 from audit_logs al where al.action = 'reservation.hold_released_by_staff' and al.entity_id = b.id) then 'hold_released_staff' else 'hold_released' end)
                when b.release_reason = 'studio_released' then 'studio_cancelled'
                when b.status = 'late_cancelled' or b.is_late_cancel then 'late_cancelled'
                else 'cancelled' end,
           case when b.payment_source = 'comp'
                     and not exists (select 1 from guest_passes gp where gp.guest_booking_id = b.id and gp.host_member_id is null)
                     and not exists (select 1 from payments p2 where p2.booking_id = b.id and p2.kind = 'reservation_fee' and p2.status in ('succeeded','partially_refunded'))
                     then (case when exists (select 1 from audit_logs al where al.action = 'reservation.hold_released_by_staff' and al.entity_id = b.id) then 'Hold released by the studio' else 'Hold released, not paid' end)
                when b.release_reason = 'studio_released' then 'Studio cancelled ' || coalesce(o.name, 'a class')
                when b.status = 'late_cancelled' or b.is_late_cancel then 'Cancelled late — ' || coalesce(o.name, 'a class')
                else 'Cancelled ' || coalesce(o.name, 'a class') end,
           case when b.release_reason = 'studio_released' then 'Credit returned'
                when (b.status = 'late_cancelled' or b.is_late_cancel)
                     and not exists (select 1 from led cl where cl.booking_id = b.id and cl.reason = 'cancellation_refund')
                then 'Class used' end,
           (select cl.id from led cl where cl.booking_id = b.id and cl.reason = 'cancellation_refund' order by cl.created_at, cl.id limit 1),
           null, null, b.occurrence_id, b.id, b.membership_id
      from bookings b left join class_occurrences o on o.id = b.occurrence_id
     where b.member_id = p_member_id and b.status in ('cancelled','late_cancelled')
       and not exists (select 1 from audit_logs al
                        where al.action = 'booking.removed_by_staff' and al.entity_id = b.id)
    union all
    -- checked in / attended
    select ci.checked_in_at, 'attended',
           case when o.id is null then 'Attended a class (imported)' else 'Attended ' || o.name end,
           null, null::uuid, null, null, ci.occurrence_id, ci.booking_id, null
      from check_ins ci left join class_occurrences o on o.id = ci.occurrence_id
     where ci.member_id = p_member_id
    union all
    -- no-show
    select coalesce(b.no_show_at, o.ends_at, b.updated_at), 'no_show',
           'Did not attend ' || coalesce(o.name, 'a class'), null,
           null::uuid, null, null, b.occurrence_id, b.id, b.membership_id
      from bookings b left join class_occurrences o on o.id = b.occurrence_id
     where b.member_id = p_member_id and b.status = 'no_show'
    union all
    -- purchase / refund / failed payment (carries the matched grant/forfeit)
    select coalesce(p.paid_at, p.created_at),
           case when p.refunded_at is not null or p.status in ('refunded','partially_refunded') then 'refund'
                when p.status = 'failed' then 'payment_failed'
                when p.kind = 'reservation_fee'
                     and exists (select 1 from bookings b2 where b2.id = p.booking_id and b2.status in ('no_show','late_cancelled'))
                     and not exists (select 1 from member_credits mc2 where mc2.booking_id = p.booking_id and mc2.reason = 'reservation_credit' and mc2.voided_at is null)
                     then 'reservation_fee_kept'
                when p.kind = 'reservation_fee' then 'reservation_fee_paid'
                else 'purchase' end,
           case when p.refunded_at is not null or p.status in ('refunded','partially_refunded') then 'Refund — ' || coalesce(p.description, 'a payment')
                when p.status = 'failed' then 'Payment failed — ' || coalesce(p.description, 'a payment')
                when p.kind = 'reservation_fee'
                     and exists (select 1 from bookings b2 where b2.id = p.booking_id and b2.status in ('no_show','late_cancelled'))
                     and not exists (select 1 from member_credits mc2 where mc2.booking_id = p.booking_id and mc2.reason = 'reservation_credit' and mc2.voided_at is null)
                     then 'Reservation fee kept'
                when p.kind = 'reservation_fee' then 'Reservation fee paid'
                else 'Bought ' || coalesce(p.description, 'a plan') end,
           null,
           case when p.refunded_at is not null or p.status in ('refunded','partially_refunded')
                then (select ledger_id from pay_forfeit pf where pf.payment_id = p.id)
                when p.status = 'failed' then null
                else (select ledger_id from pay_grant pg where pg.payment_id = p.id) end,
           case when p.refunded_at is not null then coalesce(p.refunded_cents, p.amount_cents) else p.amount_cents end,
           p.currency, null::uuid, p.booking_id, p.membership_id
      from payments p where p.member_id = p_member_id
    union all
    -- rescheduled / instructor changed, for occurrences the member holds a live booking on
    select oe.at,
           case when oe.kind = 'moved' then 'rescheduled' else 'instructor_changed' end,
           case when oe.kind = 'moved' then 'Class rescheduled — ' || coalesce(o.name, 'a class')
                else 'Instructor changed — ' || coalesce(o.name, 'a class') end,
           null, null::uuid, null, null, oe.occurrence_id, null, null
      from occurrence_events oe left join class_occurrences o on o.id = oe.occurrence_id
     where oe.kind in ('moved','instructor_changed')
       and exists (select 1 from bookings b where b.occurrence_id = oe.occurrence_id
                    and b.member_id = p_member_id and b.status <> 'cancelled')
    union all
    -- message_sent (staff only)
    select coalesce(msg.sent_at, msg.updated_at), 'message_sent', 'Message sent', msg.subject,
           null::uuid, null, null, null, null, null
      from messages msg
     where msg.member_id = p_member_id and v_is_staff and msg.status in ('queued','sent')
    union all
    -- contacted (staff only) — a task contacted the old way (no member_contacts
    -- row). A task linked to a contact (contact_id set) shows via the arm below.
    select mt.contacted_at, 'contacted', 'Contacted', mt.reason,
           null::uuid, null, null, null, null, null
      from member_tasks mt
     where mt.member_id = p_member_id and v_is_staff
       and mt.status = 'contacted' and mt.contacted_at is not null
       and mt.contact_id is null
    union all
    -- Decision 79: retention outreach logged in member_contacts (staff only).
    select mc.contacted_at, 'contacted',
           case when mc.method = 'email' then 'Emailed'
                when mc.method = 'viber' then 'Contacted (Viber)'
                when mc.method = 'call'  then 'Called'
                else 'Contacted (in person)' end
             || coalesce(' by ' || nullif(pr.full_name, ''), ''),
           mc.subject,
           null::uuid, null, null, null, null, null
      from member_contacts mc
      left join profiles pr on pr.id = mc.staff_id
     where mc.member_id = p_member_id and v_is_staff
    union all
    -- Decision 83 (a): a plan that ended (expired, or ended by staff) — NOT
    -- a refund, which tells its own story. Claims the end-forfeit ledger row
    -- so it is not also a bare "Credit adjustment"; unused = classes forfeited.
    select coalesce(ms2.cancelled_at, (ms2.expires_on)::timestamptz), 'plan_ended', 'Plan ended', null,
           (select cl.id from led cl
             where cl.membership_id = ms2.id and cl.reason = 'manual' and cl.delta < 0
               and cl.id not in (select ledger_id from pay_forfeit)
             order by cl.created_at desc, cl.id desc limit 1),
           null, null, null::uuid, null, ms2.id
      from memberships ms2
     where ms2.member_id = p_member_id
       and ms2.status in ('cancelled','expired')
       and coalesce(ms2.cancelled_at, (ms2.expires_on)::timestamptz) is not null
       and not exists (select 1 from payments p where p.membership_id = ms2.id
                        and (p.refunded_at is not null or p.status in ('refunded','partially_refunded')))
    union all
    -- Decision 103(e): reservation credit granted (attended, on-time cancel, or a
    -- lost seat). From member_credits, which the Journey did not read before.
    select mc.created_at, 'reservation_credit_back', 'Fee credited back', null::text,
           null::uuid, mc.amount_cents, mc.currency::text, null::uuid, mc.booking_id, null::uuid
      from member_credits mc
     where mc.member_id = p_member_id and mc.voided_at is null
       and mc.reason in ('reservation_credit', 'reservation_lost_seat')
    union all
    -- Decision 103(e): a released hold re-booked after the payment, or a
    -- reservation covered by credit. From audit_logs (entity = the booking).
    select al.created_at,
           case when al.action = 'reservation.credit_used' then 'reservation_credit_used'
                else 'reservation_restored' end,
           case when al.action = 'reservation.credit_used' then 'Credit used for a reservation'
                else 'Seat restored after payment' end,
           null::text, null::uuid, null::int, null::text, null::uuid, al.entity_id, null::uuid
      from audit_logs al
     where al.entity_table = 'bookings'
       and al.action in ('reservation.restored', 'reservation.repaired', 'reservation.credit_used')
       and exists (select 1 from bookings b where b.id = al.entity_id and b.member_id = p_member_id)
  ),
  claimed as (select distinct ledger_id from ev where ledger_id is not null),
  -- ledger rows no event claims: complimentary grants, manual adjustments,
  -- lockout, merch. Shown as their own credit lines.
  adj as (
    select l.created_at as at,
           case when l.reason = 'booking' then 'credit_used'
                when l.delta >= 0 then 'credits_added' else 'credit_adjustment' end as kind,
           case when l.reason = 'booking' then 'Class credit used'
                when l.reason = 'cancellation_refund' then 'Credit returned'
                when l.delta >= 0 then 'Credits added' else 'Credit adjustment' end as title,
           null::text as detail, l.id as ledger_id, null::int as amount_cents, null::text as currency,
           null::uuid as occurrence_id, l.booking_id, l.membership_id
      from led l where l.id not in (select ledger_id from claimed where ledger_id is not null)
  ),
  all_rows as (
    select * from ev
    union all
    select * from adj
  )
  select
    x.at, x.kind, x.title, x.detail,
    coalesce(l.delta, 0) as credit_delta,
    coalesce(l.bal,
             (select l2.bal from led l2 where l2.created_at <= x.at order by l2.created_at desc, l2.id desc limit 1),
             0) as balance_after,
    x.amount_cents, x.currency, x.occurrence_id, x.booking_id, x.membership_id,
    -- Decision 83. plan_name: the plan a booking drew from, a cancellation or a
    -- no-show consumed/returned to, or the ended plan. null on every other kind.
    case when x.kind in ('booked','cancelled','late_cancelled','studio_cancelled','no_show','plan_ended')
         then mp.name end as plan_name,
    -- due_cents: a LIVE unpaid drop-in booking only — the cheapest active public
    -- drop_in plan price, what Pay-now charges (bookings store no per-row price).
    case when x.kind = 'booked' and exists (
           select 1 from bookings b
            where b.id = x.booking_id and b.payment_source = 'drop_in' and b.status = 'booked'
              and not exists (select 1 from payments p
                               where p.booking_id = b.id and p.status in ('succeeded','partially_refunded')))
         then (select dp.price_cents from membership_plans dp
                where dp.studio_id = v_studio and dp.type = 'drop_in'
                  and dp.visibility = 'public' and dp.status = 'active'
                order by dp.price_cents asc, dp.sort_order asc, dp.id limit 1)
         end as due_cents,
    -- is_free_first: true on a free-first comp booking AND on its later cancel /
    -- no-show rows, so the helper can say "Free class used" / "Free class kept".
    (x.booking_id is not null and exists (
       select 1 from bookings b join guest_passes gp on gp.guest_booking_id = b.id
        where b.id = x.booking_id and b.payment_source = 'comp' and gp.host_member_id is null))
      as is_free_first,
    -- Decision 83 (a): the class instant + instructor, for the "{Day} {date},
    -- {time} with {instructor}" line (rowLine renders in the studio timezone).
    occ.starts_at as occurrence_start,
    nullif(split_part(coalesce(inst.display_name, ''), ' ', 1), '') as instructor_first,
    -- credits_left_after: the plan balance after this row. A no-show and a late
    -- cancel that used the credit carry no ledger of their own (the credit was
    -- spent at booking), so read that booking's consume row; a late cancel that
    -- refunded (consumes-off) has a refund ledger row, so coalesce keeps it. null
    -- = no plan credit touched (free first, unlimited, drop-in, money rows).
    case when x.kind in ('no_show','late_cancelled')
         then coalesce(l.membership_bal,
                       (select l2.membership_bal from led l2 join bookings b2 on b2.credit_entry_id = l2.id
                         where b2.id = x.booking_id))
         else l.membership_bal end as credits_left_after,
    -- payment_method / recorded_by_name: the money row's own payment (lateral,
    -- keyed on member + the arm's `at`). recorded_by is null for an online
    -- payment, so recorded_by_name is null unless it was taken at the desk.
    pm.method as payment_method,
    rec.full_name as recorded_by_name,
    case when x.kind = 'purchase' then coalesce(mp.credits, mp.credits_per_period) end as plan_classes,
    case when x.kind = 'purchase' then ms.expires_on end as plan_valid_to,
    case when x.kind = 'plan_ended' then abs(coalesce(l.delta, 0)) end as unused_credits,
    -- Decision 83 (a) follow-up: the booking's own payment_source (comp / drop_in /
    -- class_pack / membership / group), null for a non-booking row; and whether a
    -- booking row has a succeeded or partially_refunded payment, null otherwise.
    -- rowLine reads these to say "Complimentary" vs "Drop-in, paid" vs "due".
    (select b.payment_source::text from bookings b where b.id = x.booking_id) as payment_source,
    case when x.booking_id is not null
         then exists (select 1 from payments p
                       where p.booking_id = x.booking_id and p.status in ('succeeded','partially_refunded'))
         end as is_paid
  from all_rows x
  left join led l on l.id = x.ledger_id
  left join memberships ms on ms.id = x.membership_id
  left join membership_plans mp on mp.id = ms.plan_id
  left join class_occurrences occ on occ.id = x.occurrence_id
  left join instructors inst on inst.id = occ.instructor_id
  left join lateral (
    select p2.method, p2.recorded_by
      from payments p2
     where x.kind in ('purchase','refund','payment_failed')
       and p2.member_id = p_member_id
       and coalesce(p2.paid_at, p2.created_at) = x.at
     order by p2.id limit 1) pm on true
  left join profiles rec on rec.id = pm.recorded_by
  where x.at is not null and x.at::date between p_from and p_to
  order by x.at desc, x.kind;
end $function$;

-- ===========================================================================
-- 8. Decision 36 (a): return what a late cancel took. Desk-up. The booking stays
--    late_cancelled and the seat stays free. The marker is a cancellation_refund
--    ledger row on the booking (delta 1 for a credit, 0 otherwise), the same row
--    an on-time cancel writes, so "already returned" is one test. The reservation
--    fee (payments kind reservation_fee, member_credits) is never touched.
-- ===========================================================================

-- What kind of seat a late-cancelled booking was, and whether it was returned.
create or replace function late_cancel_seat_kind(p_booking_id uuid)
returns text
language sql stable security definer set search_path = public as $$
  select case
    when b.payment_source = 'drop_in' and exists (
           select 1 from payments p where p.booking_id = b.id and coalesce(p.kind, '') <> 'reservation_fee'
              and p.status in ('succeeded', 'partially_refunded')) then 'paid_drop_in'
    when b.payment_source = 'drop_in' then 'unpaid_drop_in'
    when b.credit_entry_id is not null then 'credit'
    when b.payment_source = 'comp' and exists (
           select 1 from guest_passes gp where gp.guest_booking_id = b.id and gp.host_member_id is null) then 'free_first'
    else 'other' end
  from bookings b where b.id = p_booking_id;
$$;
revoke execute on function late_cancel_seat_kind(uuid) from public, anon, authenticated;
grant  execute on function late_cancel_seat_kind(uuid) to service_role;

-- The roster and the Journey ask this once for their late-cancelled rows.
create or replace function late_cancel_returns(p_studio_id uuid, p_booking_ids uuid[])
returns table (booking_id uuid, seat_kind text, returned_at timestamptz, returned_by text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not (coalesce(is_desk_up(p_studio_id), false) or is_service_context()) then
    raise exception 'only studio staff return a credit' using errcode = 'PT403';
  end if;
  return query
  select b.id, late_cancel_seat_kind(b.id),
         cl.created_at,
         case when cl.id is null then null
              else coalesce(nullif(split_part((select full_name from profiles where id = cl.actor_user_id), ' ', 1), ''),
                            'the studio') end
    from bookings b
    left join lateral (select c.id, c.created_at, c.actor_user_id from credit_ledger c
                        where c.booking_id = b.id and c.reason = 'cancellation_refund'
                        order by c.created_at limit 1) cl on true
   where b.studio_id = p_studio_id and b.id = any (p_booking_ids) and b.status = 'late_cancelled';
end $$;
revoke execute on function late_cancel_returns(uuid, uuid[]) from public, anon;
grant  execute on function late_cancel_returns(uuid, uuid[]) to authenticated, service_role;

create or replace function return_booking_credit(p_booking_id uuid, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  b bookings%rowtype; o class_occurrences%rowtype; v_s studios%rowtype; m members%rowtype;
  v_kind text; v_entry credit_ledger%rowtype; v_ms memberships%rowtype; v_mid uuid;
  v_bal int; v_delta int := 0; v_prev record; v_staff text; v_fmt text; v_when text; v_class text;
  v_plan text; v_note text := nullif(btrim(coalesce(p_note, '')), ''); v_voided int := 0;
  v_strike boolean := false; v_line text; v_rem_before int; v_rem_after int;
begin
  select * into b from bookings where id = p_booking_id for update;
  if not found then raise exception 'no such booking' using errcode = 'PT404'; end if;
  if not (coalesce(is_desk_up(b.studio_id), false) or is_service_context()) then
    raise exception 'only studio staff return a credit' using errcode = 'PT403';
  end if;
  select * into v_s from studios where id = b.studio_id;

  if b.status <> 'late_cancelled' then
    return jsonb_build_object('ok', false, 'reason', 'not_late_cancelled',
      'message', 'This booking was not cancelled late, so there is nothing to return.');
  end if;

  select cl.created_at, cl.actor_user_id into v_prev
    from credit_ledger cl where cl.booking_id = b.id and cl.reason = 'cancellation_refund'
   order by cl.created_at limit 1;
  if found then
    return jsonb_build_object('ok', false, 'reason', 'already_returned',
      'message', 'Already returned on ' || to_char(v_prev.created_at at time zone v_s.timezone, 'FMDD Mon YYYY')
                 || ' by ' || coalesce(nullif(split_part((select full_name from profiles where id = v_prev.actor_user_id), ' ', 1), ''),
                                       'the studio') || '.');
  end if;

  v_kind := late_cancel_seat_kind(b.id);
  if v_kind = 'paid_drop_in' then
    return jsonb_build_object('ok', false, 'reason', 'paid_drop_in',
      'message', 'Nothing to return: this seat was paid as a drop-in. Refunds are under Payments.');
  end if;

  if b.credit_entry_id is not null then
    select * into v_entry from credit_ledger where id = b.credit_entry_id;
    v_mid := v_entry.membership_id;
  else
    v_mid := b.membership_id;
  end if;
  if v_mid is not null then
    select * into v_ms from memberships where id = v_mid;
    if v_ms.status in ('cancelled', 'expired')
       or exists (select 1 from payments p where p.membership_id = v_mid
                    and (p.status = 'refunded' or coalesce(p.refunded_cents, 0) > 0))
       or (v_kind = 'credit' and v_entry.expires_at is not null and v_entry.expires_at < now()) then
      return jsonb_build_object('ok', false, 'reason', 'plan_ended',
        'message', 'That plan has ended or been refunded, so nothing changes.');
    end if;
    v_plan := (select name from membership_plans where id = v_ms.plan_id);
    v_rem_before := v_ms.credits_remaining;
  end if;

  select coalesce(sum(delta), 0) into v_bal
    from credit_ledger where studio_id = b.studio_id and member_id = b.member_id;
  if v_kind = 'credit' then v_delta := 1; end if;

  insert into credit_ledger (studio_id, member_id, membership_id, delta, reason, booking_id,
                             balance_after, expires_at, actor_user_id)
  values (b.studio_id, b.member_id, v_mid, v_delta, 'cancellation_refund', b.id,
          v_bal + v_delta, case when v_kind = 'credit' then v_entry.expires_at end, auth.uid());
  if v_kind = 'credit' and v_mid is not null then
    update memberships set credits_remaining = coalesce(credits_remaining, 0) + 1 where id = v_mid
    returning credits_remaining into v_rem_after;
  else
    v_rem_after := v_rem_before;
  end if;

  update member_infractions
     set status = 'voided', voided_at = now(), voided_by = auth.uid(),
         voided_reason = coalesce('Credit returned by the studio: ' || v_note, 'Credit returned by the studio')
   where booking_id = b.id and status = 'active';
  get diagnostics v_voided = row_count;

  -- The desk-pay strike, only if this late cancel caused it and nothing else would.
  if b.payment_source = 'drop_in'
     and exists (select 1 from members x where x.id = b.member_id
                  and x.desk_pay_blocked_at is not null and x.desk_pay_blocked_reason = 'late_cancel')
     and not exists (
       select 1 from bookings x
        where x.member_id = b.member_id and x.id <> b.id
          and x.status in ('no_show', 'late_cancelled')
          and x.payment_source = 'drop_in'
          and not exists (select 1 from credit_ledger c where c.booking_id = x.id and c.reason = 'cancellation_refund')
          and not exists (select 1 from payments p where p.booking_id = x.id
                           and p.status in ('succeeded', 'partially_refunded'))) then
    perform set_config('studiior.desk_pay_system', '1', true);
    update members set desk_pay_blocked_at = null, desk_pay_blocked_reason = null, updated_at = now()
     where id = b.member_id;
    perform set_config('studiior.desk_pay_system', '', true);
    v_strike := true;
  end if;

  select * into o from class_occurrences where id = b.occurrence_id;
  select * into m from members where id = b.member_id;
  v_fmt   := coalesce((select time_format from studio_settings where studio_id = b.studio_id), '24h');
  v_class := coalesce(o.name, (select name from class_types where id = o.class_type_id), 'your class');
  v_when  := to_char(o.starts_at at time zone v_s.timezone, 'FMDay FMDD FMMon') || ' at '
             || fmt_clock(o.starts_at, v_s.timezone, v_fmt);
  v_staff := coalesce(nullif(split_part((select full_name from profiles where id = auth.uid()), ' ', 1), ''),
                      'the studio');
  v_line := case v_kind
    when 'credit' then 'The class credit is back on your ' || coalesce(v_plan, 'plan') || '.'
    when 'free_first' then 'Your free first class is yours again, so you can book it for another class.'
    else 'We have cleared the late cancellation, so it does not count against you.' end;

  perform queue_notification(b.studio_id, b.member_id, 'credit_returned_by_studio',
    jsonb_build_object(
      'first_name', m.first_name, 'studio_name', v_s.name,
      'class_name', v_class, 'when', v_when,
      'returned_line', v_line,
      'note_line', case when v_note is not null then ' Note from the studio: ' || v_note else '' end,
      'book_url', member_portal_url(b.studio_id, '/book')),
    'credit_returned_by_studio:' || b.id);

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (b.studio_id, auth.uid(), 'booking.credit_returned_by_studio', 'bookings', b.id,
          jsonb_build_object('member_id', b.member_id, 'status', b.status, 'balance', v_bal,
                             'credits_remaining', v_rem_before),
          jsonb_build_object('kind', v_kind, 'delta', v_delta, 'balance', v_bal + v_delta,
                             'credits_remaining', v_rem_after, 'note', v_note, 'staff_first', v_staff,
                             'class_name', v_class, 'when', v_when,
                             'infractions_voided', v_voided, 'desk_pay_restored', v_strike));

  return jsonb_build_object('ok', true, 'kind', v_kind, 'delta', v_delta, 'class_name', v_class,
    'when', v_when, 'infractions_voided', v_voided, 'desk_pay_restored', v_strike,
    'message', case v_kind when 'credit' then 'Credit returned to ' || coalesce(v_plan, 'their plan') || '.'
                           when 'free_first' then 'Their free first class is back.'
                           else 'The late cancellation is cleared.' end);
end $$;
revoke execute on function return_booking_credit(uuid, text) from public, anon;
grant  execute on function return_booking_credit(uuid, text) to authenticated, service_role;

-- ---- The email (platform default + Reform override in the studio voice) ----
insert into notification_templates (key, subject, text_body, html_body, note) values
('credit_returned_by_studio', 'Your credit for {class_name} is back',
 E'Hi {first_name},\n\nGood news about {class_name} on {when}: {returned_line}{note_line}\n\nBook another class: {book_url}\n\n{studio_name}',
 '<p>Hi {first_name},</p><p>Good news about {class_name} on {when}: {returned_line}{note_line}</p><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{book_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Book another class</a></td></tr></table><p>{studio_name}</p>',
 'Decision 36 (a). Staff returned what a late cancel took.')
on conflict (key) do nothing;
insert into notification_templates_overrides (studio_id, key, subject, body, body_html)
select s.id, 'credit_returned_by_studio', 'Your credit for {class_name} is back',
 E'Hi {first_name}!\n\nGood news about {class_name} on {when}: {returned_line}{note_line}\n\n[Book another class]({book_url}){button}\n\nSee you at the reformer!🎀\n\nRPC Studio',
 '<p>Hi {first_name}!</p><p>Good news about {class_name} on {when}: {returned_line}{note_line}</p><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{book_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Book another class</a></td></tr></table><p>See you at the reformer!🎀</p><p>RPC Studio</p>'
  from studios s where s.slug = 'reformcollective'
on conflict (studio_id, key) do nothing;

-- ---- {promo_line} on the plan and convert platform defaults ----------------
-- Its own paragraph above the plan card (or the button / sign-off when there is
-- no card); render_email drops the paragraph when the line is empty.
update notification_templates
   set html_body = case
         when html_body like '%<table%' then regexp_replace(html_body, '<table', '<p>{promo_line}</p><table')
         else regexp_replace(html_body, '<p>([^<]*\{studio_name\}[^<]*)</p>\s*$', '<p>{promo_line}</p><p>\1</p>') end,
       text_body = case
         when text_body like '%::: card%' then regexp_replace(text_body, '::: card', E'{promo_line}\n\n::: card')
         when text_body like E'%\n\n{buy_url}%' then regexp_replace(text_body, E'\n\n\\{buy_url\\}', E'\n\n{promo_line}\n\n{buy_url}')
         else regexp_replace(text_body, E'\n\n([^\n]*\\{studio_name\\}[^\n]*)$', E'\n\n{promo_line}\n\n\\1') end
 where key in ('convert_after_class','convert_day3','convert_day7','convert_last_day','convert_missed_you',
               'convert_week_2','convert_week_5')
   and html_body not like '%{promo_line}%';

-- ===========================================================================
-- 12. Anon stays EXACTLY FOURTEEN; the new tables are closed to anon.
-- ===========================================================================
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'expect\_%' and p.proname not in ('call_jsonb');
  if n <> 14 then raise exception 'anon surface is %, expected 14', n; end if;
  if has_table_privilege('anon', 'plan_promotions', 'select') then
    raise exception 'plan_promotions is readable by anon';
  end if;
end $$;

