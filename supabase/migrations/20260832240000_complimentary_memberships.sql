-- Decision 61 — complimentary memberships are granted, not sold.
--
-- creates: grant_complimentary_membership(uuid, uuid, date, text)
-- re-issues: sweep_membership_periods(), dashboard_revenue(uuid, date, date),
--   sales_history(uuid, date, date, uuid, text),
--   member_plan_overview(uuid), mark_membership_paid(uuid, integer, text),
--   refund_membership(uuid, integer, text, boolean)
--
-- A manager-up grants an ongoing FREE membership (owner, managers, friends of
-- the studio) — a real membership with no payments row and no sale. It reuses
-- activate_purchase for the membership + credits (NO payment row), then stamps
-- complimentary / reason / end date and audits. Money figures that read
-- `payments` exclude it naturally; the two that count `memberships` rows
-- (dashboard_revenue.memberships_sold, sales_history) are re-issued to exclude
-- it; sales_totals.count follows sales_history. The period sweep never marks a
-- comp past_due — it rolls the period forward (or ends it on expires_on).
-- mark_membership_paid / refund_membership refuse a comp. Inert until granted.

alter table memberships
  add column if not exists complimentary boolean not null default false,
  add column if not exists complimentary_reason text;

comment on column memberships.complimentary is
  'Decision 61: an ongoing free membership the studio GRANTED (no payment, no sale). '
  'Excluded from revenue / memberships-sold / Sales; cannot be marked paid or refunded. '
  'A comp recurring membership rolls its period with no due; its end date (if any) is expires_on.';

-- ============================================================================
-- Re-issue: sweep_membership_periods — a comp is never past_due; it rolls.
-- ============================================================================
create or replace function sweep_membership_periods()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare n_due int := 0; n_rolled int := 0; n_ended int := 0; r record;
begin
  if not is_service_context() then
    raise exception 'this is a scheduled job, not a user action' using errcode = 'PT403';
  end if;

  with lapsed as (
    update memberships ms
       set status = 'past_due'
      from membership_plans pl
     where pl.id = ms.plan_id and pl.type = 'recurring'
       and ms.status = 'active'
       and ms.stripe_subscription_id is null
       and ms.current_period_end is not null
       and ms.current_period_end <= now()
       -- §7.4: a frozen membership is not overdue, it is paused. Its period
       -- end is meaningless while the freeze runs.
       and not membership_frozen_now(ms.id)
       -- Decision 61: a complimentary membership is never "due" — handled below.
       and not coalesce(ms.complimentary, false)
    returning ms.id, ms.studio_id, ms.status)
  insert into membership_events (studio_id, membership_id, type, from_status, to_status)
  select l.studio_id, l.id, 'period_lapsed', 'active', 'past_due' from lapsed l;
  get diagnostics n_due = row_count;

  -- Decision 61: a complimentary recurring membership whose period has ended
  -- either ENDS (its granted end date, expires_on, has passed) or ROLLS to the
  -- next period with no payment due. Never past_due.
  for r in
    select ms.id, ms.studio_id,
           (ms.expires_on is not null
            and ms.expires_on < studio_today(ms.studio_id)) as past_end
      from memberships ms
      join membership_plans pl on pl.id = ms.plan_id
     where pl.type = 'recurring'
       and ms.status = 'active'
       and coalesce(ms.complimentary, false)
       and ms.current_period_end is not null
       and ms.current_period_end <= now()
       and not membership_frozen_now(ms.id)
  loop
    if r.past_end then
      update memberships set status = 'expired', cancelled_at = now(),
             cancellation_reason = 'complimentary period ended'
       where id = r.id;
      insert into membership_events (studio_id, membership_id, type, from_status, to_status)
      values (r.studio_id, r.id, 'complimentary_ended', 'active', 'expired');
      n_ended := n_ended + 1;
    else
      perform advance_membership_period(r.id);
      n_rolled := n_rolled + 1;
    end if;
  end loop;

  return jsonb_build_object('marked_past_due', n_due,
                            'complimentary_rolled', n_rolled,
                            'complimentary_ended', n_ended);
end $$;

-- ============================================================================
-- Re-issue: dashboard_revenue — memberships_sold excludes complimentary.
-- ============================================================================
create or replace function dashboard_revenue(
  p_studio_id uuid, p_from date, p_to date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tz text; v_currency char(3); v_today date;
  v_f0 timestamptz; v_t1 timestamptz;
  v_span int; v_pf0 timestamptz; v_pt1 timestamptz;
  v_total bigint; v_prior bigint; v_refunds bigint; v_ever bigint;
  v_series jsonb; v_sources jsonb; v_counts jsonb;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'revenue is for owners and managers' using errcode = 'PT403';
  end if;
  select s.timezone, s.currency into v_tz, v_currency from studios s where s.id = p_studio_id;
  if v_tz is null then raise exception 'no such studio' using errcode = 'PT404'; end if;
  if p_to < p_from then
    raise exception 'the range ends before it starts' using errcode = 'PT422';
  end if;

  v_today := studio_today(p_studio_id);
  select day_start into v_f0 from studio_day_bounds(p_studio_id, p_from);
  select day_start into v_t1 from studio_day_bounds(p_studio_id, p_to + 1);
  v_span := (p_to - p_from) + 1;
  select day_start into v_pf0 from studio_day_bounds(p_studio_id, p_from - v_span);
  select day_start into v_pt1 from studio_day_bounds(p_studio_id, p_from);

  v_total := studio_revenue_between(p_studio_id, v_f0, v_t1);
  v_prior := studio_revenue_between(p_studio_id, v_pf0, v_pt1);
  select coalesce(sum(p.amount_cents),0)::bigint into v_ever from payments p
   where p.studio_id = p_studio_id and p.status in ('succeeded','partially_refunded');

  select coalesce(sum(r.amount_cents),0)::bigint into v_refunds
    from refunds r join payments p on p.id = r.payment_id
   where p.studio_id = p_studio_id
     and r.created_at >= v_f0 and r.created_at < v_t1;

  -- One row per day of the range, including the days with nothing: a line
  -- chart that skips its empty days draws a slope where there was a gap.
  select coalesce(jsonb_agg(jsonb_build_object('date', d.day, 'cents', coalesce(x.cents,0))
                            order by d.day), '[]'::jsonb)
    into v_series
    from generate_series(p_from, p_to, interval '1 day') g(day_ts)
    cross join lateral (select g.day_ts::date as day) d
    left join lateral (
      select coalesce(sum(p.amount_cents),0)::bigint as cents
        from payments p
       where p.studio_id = p_studio_id and p.status in ('succeeded','partially_refunded')
         and (coalesce(p.paid_at, p.created_at) at time zone v_tz)::date = d.day
    ) x on true;

  -- By source. A payment reaches its category through what it PAID FOR: the
  -- membership's plan type, or the booking's payment_source, or the class
  -- type's session_kind for a private. Never through a category column on the
  -- payment, which nothing writes.
  with classified as (
    select p.amount_cents,
           case
             when ct.session_kind in ('private','duo','trio') then 'private'
             when pl.type = 'recurring'  then 'membership'
             when pl.type = 'class_pack' then 'pack'
             when pl.type = 'trial'      then 'trial'
             when b.payment_source = 'drop_in' then 'drop_in'
             when pl.type = 'drop_in'    then 'drop_in'
             else 'other'
           end as src
      from payments p
      left join memberships ms on ms.id = p.membership_id
      left join membership_plans pl on pl.id = ms.plan_id
      left join bookings b on b.id = p.booking_id
      left join class_occurrences o on o.id = b.occurrence_id
      left join class_types ct on ct.id = o.class_type_id
     where p.studio_id = p_studio_id and p.status in ('succeeded','partially_refunded')
       and coalesce(p.paid_at, p.created_at) >= v_f0
       and coalesce(p.paid_at, p.created_at) <  v_t1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'source', src, 'label', dashboard_source_label(src), 'cents', cents,
           'pct', case when v_total = 0 then 0 else round(100.0 * cents / v_total) end)
           order by cents desc), '[]'::jsonb)
    into v_sources
    from (select src, sum(amount_cents)::bigint as cents from classified group by src) s;

  -- The other metrics 4.4 lists beside revenue.
  select jsonb_build_object(
      'bookings', (select count(*) from bookings b
                    where b.studio_id = p_studio_id and b.status <> 'waitlisted'
                      and b.booked_at >= v_f0 and b.booked_at < v_t1),
      'memberships_sold', (select count(*) from memberships ms
                    where ms.studio_id = p_studio_id
                      and ms.created_at >= v_f0 and ms.created_at < v_t1
                      -- Decision 61: a complimentary membership is not a sale.
                      and not coalesce(ms.complimentary, false)),
      'refunds_cents', v_refunds)
    into v_counts;

  return jsonb_build_object(
    'from', p_from, 'to', p_to, 'days', v_span, 'currency', v_currency,
    'state', case when v_ever = 0 then 'empty' else 'ok' end,
    'total_cents', v_total,
    'trend', dashboard_trend(v_total, v_prior, 'the ' || v_span || ' days before'),
    'series', v_series, 'by_source', v_sources, 'counts', v_counts,
    'empty_hint', 'Every payment you take shows up here — by day, and split by what it was for. Record a payment at the desk or connect Stripe and this starts filling.');
end $$;

-- ============================================================================
-- Re-issue: sales_history — a complimentary membership is not a sale.
-- ============================================================================
create or replace function sales_history(
  p_studio_id uuid, p_from date, p_to date,
  p_plan_id uuid default null, p_status text default null
) returns table (
  membership_id uuid, member_id uuid, member_name text,
  plan_id uuid, plan_name text, plan_type text,
  amount_cents int, currency char(3), payment_source text,
  bought_on timestamptz, starts_on date, expires_on date, sale_status text
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
    -- The originating payment per membership (most recent refundable one).
    select distinct on (p.membership_id)
           p.membership_id, p.amount_cents, p.currency, p.provider, p.method, p.status as pstatus,
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
          end) as sale_status
    from memberships ms
    join members m on m.id = ms.member_id
    join membership_plans mp on mp.id = ms.plan_id
    left join pay on pay.membership_id = ms.id
   where ms.studio_id = p_studio_id
     -- Decision 61: a complimentary membership is not a sale.
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
   order by coalesce(pay.paid_ts, ms.created_at) desc;
end $$;

-- ============================================================================
-- Re-issue (DROP+recreate, +complimentary column): member_plan_overview.
-- ============================================================================
drop function if exists member_plan_overview(uuid);
create or replace function member_plan_overview(p_studio_id uuid)
returns table (
  id uuid, first_name text, last_name text, email text, status text,
  lifetime_visits int, last_visit_at timestamptz,
  health_band text, health_reason text, user_id uuid,
  membership_id uuid, current_plan_name text, plan_type text,
  membership_status text, expires_on date, credits_remaining int,
  had_free_class boolean, has_ever_paid boolean, plan_state text,
  complimentary boolean
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare v_tz text; v_today date;
begin
  if not (is_desk_up(p_studio_id) or is_service_context()) then
    raise exception 'that is another studio''s members' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios s where s.id = p_studio_id;
  v_today := (now() at time zone v_tz)::date;

  return query
  with mem as (
    select m.id, m.first_name, m.last_name, m.email, m.status::text as status,
           m.lifetime_visits, m.last_visit_at,
           m.health_band::text as health_band, m.health_reason, m.user_id
      from members m
     where m.studio_id = p_studio_id and m.status <> 'archived'
  ),
  -- The one membership to show per member: a usable (non-ended) one, the one
  -- with the furthest reach first.
  live as (
    select distinct on (ms.member_id)
           ms.member_id, ms.id as membership_id, ms.status as ms_status,
           ms.expires_on, ms.credits_remaining, mp.name as plan_name, mp.type as plan_type,
           ms.complimentary,
           -- usable right now?
           (ms.status in ('active','trialing','past_due','frozen')
            and (mp.type = 'recurring'
                 or coalesce(ms.credits_remaining,0) > 0)
            and (ms.expires_on is null or ms.expires_on >= v_today)) as usable
      from memberships ms
      join membership_plans mp on mp.id = ms.plan_id
     where ms.studio_id = p_studio_id and ms.status <> 'cancelled'
     order by ms.member_id,
              (ms.status in ('active','trialing','past_due','frozen')) desc,
              ms.expires_on desc nulls first, ms.created_at desc
  ),
  paid as (
    select distinct member_id from payments
     where studio_id = p_studio_id and status in ('succeeded','partially_refunded')
  ),
  freebie as (
    select distinct guest_member_id as member_id from guest_passes
     where studio_id = p_studio_id
  )
  select mem.id, mem.first_name, mem.last_name, mem.email, mem.status,
         mem.lifetime_visits, mem.last_visit_at, mem.health_band, mem.health_reason, mem.user_id,
         live.membership_id, live.plan_name, live.plan_type::text,
         live.ms_status::text, live.expires_on, live.credits_remaining,
         (freebie.member_id is not null) as had_free_class,
         (paid.member_id is not null) as has_ever_paid,
         case
           when coalesce(live.usable, false) then
             case when live.expires_on is not null
                       and live.expires_on <= v_today + 14 then 'expiring' else 'on_plan' end
           when paid.member_id is not null then 'expired'
           when freebie.member_id is not null then 'free_only'
           else 'none'
         end as plan_state,
         coalesce(live.complimentary, false) as complimentary
    from mem
    left join live    on live.member_id = mem.id
    left join paid    on paid.member_id = mem.id
    left join freebie on freebie.member_id = mem.id;
end $$;

-- ============================================================================
-- Re-issue: mark_membership_paid + refund_membership — refuse a comp.
-- ============================================================================
create or replace function mark_membership_paid(
  p_membership_id uuid, p_amount_cents int, p_method text default 'cash'
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare ms memberships%rowtype; v_paid int; v_method text;
begin
  select * into ms from memberships where id = p_membership_id for update;
  if not found then raise exception 'no such membership' using errcode = 'PT404'; end if;
  if not is_manager_up(ms.studio_id) then
    raise exception 'recording a payment is the owner''s or a manager''s to do' using errcode = 'PT403';
  end if;
  -- Decision 61: a complimentary membership is not a sale.
  if coalesce(ms.complimentary, false) then
    raise exception 'This membership is complimentary — there is nothing to pay or refund.' using errcode = 'PT409';
  end if;
  select count(*) into v_paid from payments
   where membership_id = ms.id and status in ('succeeded', 'partially_refunded');
  if v_paid > 0 then
    raise exception 'this purchase is already paid' using errcode = 'PT409';
  end if;
  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'enter the amount paid' using errcode = 'PT400';
  end if;
  v_method := coalesce(nullif(btrim(p_method), ''), 'cash');
  if v_method not in ('cash', 'bank_transfer', 'card_terminal', 'gcash', 'other') then
    raise exception 'unknown payment method' using errcode = 'PT400';
  end if;

  insert into payments (studio_id, member_id, membership_id, amount_cents, currency, status,
                        description, provider, method, recorded_by, paid_at)
  values (ms.studio_id, ms.member_id, ms.id, p_amount_cents, ms.currency, 'succeeded',
          'Marked paid at desk', 'manual', v_method, auth.uid(), now());

  -- A trial / past-due purchase becomes active once paid; a frozen one stays
  -- paused, an active one stays active.
  update memberships
     set status = case when status in ('trialing', 'past_due') then 'active'::membership_status
                       else status end,
         updated_at = now()
   where id = ms.id;

  insert into membership_events (studio_id, membership_id, type, from_status, to_status,
                                 actor_user_id, metadata)
  values (ms.studio_id, ms.id, 'payment', ms.status,
          case when ms.status in ('trialing', 'past_due') then 'active'::membership_status else ms.status end,
          auth.uid(),
          jsonb_build_object('amount_cents', p_amount_cents, 'method', v_method));

  return jsonb_build_object('ok', true, 'sentence', 'Marked paid.');
end $$;

create or replace function refund_membership(
  p_membership_id uuid, p_amount_cents int default null,
  p_reason text default null, p_end boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare ms memberships%rowtype; v_pay uuid;
begin
  select * into ms from memberships where id = p_membership_id for update;
  if not found then raise exception 'no such membership' using errcode = 'PT404'; end if;
  if not is_manager_up(ms.studio_id) then
    raise exception 'refunds are the owner''s or a manager''s to make' using errcode = 'PT403';
  end if;
  -- Decision 61: a complimentary membership is not a sale.
  if coalesce(ms.complimentary, false) then
    raise exception 'This membership is complimentary — there is nothing to pay or refund.' using errcode = 'PT409';
  end if;

  -- The membership's originating payment — the most recent one still carrying a
  -- refundable balance.
  select id into v_pay from payments
   where membership_id = ms.id and status in ('succeeded', 'partially_refunded')
   order by coalesce(paid_at, created_at) desc
   limit 1;
  if v_pay is null then
    raise exception 'nothing has been paid on this to refund' using errcode = 'PT409';
  end if;

  -- One refund implementation. record_refund handles partial/full, forfeits
  -- credits and cancels the membership on a full refund, and audits.
  perform record_refund(v_pay, p_amount_cents, p_reason);

  -- A partial refund that should also end the membership.
  if coalesce(p_end, false) then
    update memberships
       set status = 'cancelled', cancelled_at = now(),
           cancellation_reason = coalesce(nullif(btrim(p_reason), ''), 'refunded'),
           updated_at = now()
     where id = ms.id and status <> 'cancelled';
    if found then
      insert into membership_events (studio_id, membership_id, type, from_status, to_status,
                                     actor_user_id, metadata)
      values (ms.studio_id, ms.id, 'cancelled', ms.status, 'cancelled', auth.uid(),
              jsonb_build_object('reason', p_reason, 'via', 'refund'));
    end if;
  end if;

  return jsonb_build_object('ok', true, 'sentence',
    'Recorded. Refund the money in Xendit if it was paid there.');
end $$;

-- ============================================================================
-- grant_complimentary_membership — the writer. Manager-up. No payment row.
-- ============================================================================
create or replace function grant_complimentary_membership(
  p_member_id uuid, p_plan_id uuid,
  p_ends_on date default null, p_reason text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_studio uuid; v_name text; pl membership_plans%rowtype; v_ms uuid;
  v_reason text; v_today date;
begin
  select studio_id, (first_name || ' ' || last_name)
    into v_studio, v_name
    from members where id = p_member_id;
  if v_studio is null then
    raise exception 'no such member' using errcode = 'PT404';
  end if;
  if not is_manager_up(v_studio) then
    raise exception 'granting a complimentary membership is the owner''s or a manager''s to do'
      using errcode = 'PT403';
  end if;

  select * into pl from membership_plans where id = p_plan_id and studio_id = v_studio;
  if not found then
    raise exception 'no such plan for this studio' using errcode = 'PT404';
  end if;
  if pl.status <> 'active' then
    raise exception 'That plan is archived.' using errcode = 'PT409';
  end if;

  v_reason := nullif(btrim(coalesce(p_reason, '')), '');
  if v_reason is null then
    raise exception 'a reason is needed (e.g. owner, studio manager, ambassador)'
      using errcode = 'PT400';
  end if;

  v_today := studio_today(v_studio);
  if p_ends_on is not null and p_ends_on <= v_today then
    raise exception 'the end date has to be in the future' using errcode = 'PT400';
  end if;

  if exists (
    select 1 from memberships
     where member_id = p_member_id and plan_id = p_plan_id
       and status not in ('cancelled', 'expired')
  ) then
    raise exception 'They already have %.', pl.name using errcode = 'PT409';
  end if;

  -- Reuse activate_purchase for the membership + credits + the 'created' event.
  -- Price 0, no seat-cap gate (a grant is a deliberate off-book act), and
  -- crucially NO payments row is written (the caller writes that; we do not).
  v_ms := activate_purchase(v_studio, p_member_id, p_plan_id, 0, null::char(3),
                            null, null, false);

  -- Stamp it complimentary. expires_on carries the grant's end date (null = no
  -- end), overriding activate_purchase's pack-validity expiry for a comp.
  update memberships
     set complimentary = true, complimentary_reason = v_reason,
         expires_on = p_ends_on
   where id = v_ms;

  insert into membership_events (studio_id, membership_id, type, to_status, actor_user_id, metadata)
  values (v_studio, v_ms, 'complimentary_granted', 'active', auth.uid(),
          jsonb_build_object('reason', v_reason, 'ends_on', p_ends_on));

  return jsonb_build_object(
    'membership_id', v_ms,
    'message', 'Granted ' || pl.name || ' to ' || v_name ||
      case when p_ends_on is not null
           then ' until ' || to_char(p_ends_on, 'FMDD Mon YYYY')
           else ' with no end date' end || '.');
end $$;

revoke all on function grant_complimentary_membership(uuid, uuid, date, text) from public, anon;
grant execute on function grant_complimentary_membership(uuid, uuid, date, text) to authenticated, service_role;

-- member_plan_overview was dropped + recreated above; re-assert its ACL.
revoke all on function member_plan_overview(uuid) from public, anon;
grant execute on function member_plan_overview(uuid) to authenticated, service_role;
