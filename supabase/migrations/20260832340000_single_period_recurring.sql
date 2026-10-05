-- Decision 66 — recurring plans online, one period at a time (no saved card).
--
-- creates: advance_membership_period_run(uuid), sweep_membership_expiring()
-- re-issues: advance_membership_period(uuid), xendit_begin_purchase(uuid, uuid),
--   xendit_activate_success_internal(uuid, text),
--   sales_history(uuid, date, date, uuid, text)
--
-- A recurring plan is bought online as a SINGLE period, exactly like a pack
-- (Decision 40 Part A): no saved card, no Xendit subscription, auto_renew false.
-- Renewing is the member's action — the same one-time checkout — and extends the
-- existing membership from its OLD end (Decision 3 resets credits), never a
-- second membership. Automatic renewal with a saved card is Decision 67.

-- =============================================================================
-- 1. Schema: a purchase can name the membership it renews. A renewal still has
--    plan_id set, so 63b's "exactly one of plan_id/product_order_id" CHECK holds.
-- =============================================================================
alter table xendit_purchases
  add column renews_membership_id uuid references memberships on delete set null;

-- =============================================================================
-- 2. The 7-days-before reminder template. Unlisted in notification_wanted, so it
--    sends (the documented default).
-- =============================================================================
insert into notification_templates (key, subject, text_body, html_body, note) values
  ('membership_expiring',
   'Your {plan_name} at {studio_name} ends soon',
   E'Hi {first_name},\n\nYour {plan_name} at {studio_name} ends on {ends_on}. To keep going, renew for another period — it takes a moment and there is nothing to set up:\n\n{renew_url}\n\n— {studio_name}',
   '<p>Hi {first_name},</p><p>Your <strong>{plan_name}</strong> at {studio_name} ends on {ends_on}. To keep going, renew for another period — it takes a moment and there is nothing to set up.</p><p><a href="{renew_url}">Renew now</a></p><p>— {studio_name}</p>',
   'Decision 66: a recurring membership bought one period at a time is 7 days from its end.')
on conflict (key) do nothing;

-- =============================================================================
-- 3. advance_membership_period_run — the unguarded extend. The anon webhook is
--    neither desk nor service context at RUNTIME (role is 'anon'), so it cannot
--    call the guarded wrapper (the amendment-9 trap). Body is the current
--    advance_membership_period minus the caller guard; the DATA guards (PT404,
--    non-recurring PT422, frozen/cancelled/expired PT409) stay.
-- =============================================================================
create function advance_membership_period_run(p_membership_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  ms memberships%rowtype; pl membership_plans%rowtype;
  v_from timestamptz; v_end timestamptz; v_tz text; v_status membership_status;
begin
  select * into ms from memberships where id = p_membership_id;
  if not found then
    raise exception 'no such membership' using errcode = 'PT404';
  end if;
  select * into pl from membership_plans where id = ms.plan_id;
  if pl.type <> 'recurring' then
    raise exception 'only a recurring membership has a period to advance'
      using errcode = 'PT422';
  end if;
  if ms.status not in ('active', 'past_due') or membership_frozen_now(p_membership_id) then
    raise exception 'a % membership is not renewed by taking a payment',
      case when membership_frozen_now(p_membership_id) then 'frozen' else ms.status::text end
      using errcode = 'PT409',
            hint = 'Frozen, cancelled and expired memberships are each their own decision.';
  end if;

  select s.timezone into v_tz from studios s where s.id = ms.studio_id;
  -- Extend from the OLD end (Decision 66: an early renewal never shortens the
  -- period); a membership with no end (pre-periods) starts now.
  v_from := coalesce(ms.current_period_end, now());
  v_end  := plan_period_end(pl.id, v_from);

  v_status := case when v_end > now() then 'active' else 'past_due' end::membership_status;

  update memberships
     set current_period_start = v_from,
         current_period_end   = v_end,
         renews_on            = (v_end at time zone v_tz)::date,
         status               = v_status,
         -- Decision 3: reset, never add.
         credits_remaining    = case when pl.credits_per_period is not null
                                     then pl.credits_per_period
                                     else credits_remaining end,
         credits_reset_at     = case when pl.credits_per_period is not null
                                     then v_end end
   where id = p_membership_id;

  insert into membership_events
    (studio_id, membership_id, type, from_status, to_status, actor_user_id, metadata)
  values (ms.studio_id, p_membership_id, 'renewed', ms.status, v_status, auth.uid(),
          jsonb_build_object('period_start', v_from, 'period_end', v_end));

  return jsonb_build_object(
    'membership_id', p_membership_id,
    'period_start', v_from,
    'period_end', v_end,
    'renews_on', (v_end at time zone v_tz)::date,
    'status', v_status,
    'still_owing', v_end <= now(),
    'periods_behind', case when v_end > now() then 0
      else greatest(1, ceil(extract(epoch from (now() - v_end)) /
        nullif(extract(epoch from (v_end - v_from)), 0))::int) end);
end $$;
revoke execute on function advance_membership_period_run(uuid) from public, anon, authenticated;
grant  execute on function advance_membership_period_run(uuid) to service_role;

-- advance_membership_period becomes a thin guarded wrapper — the desk path is
-- byte-unchanged (is_desk_up OR is_service_context, then delegate).
create or replace function advance_membership_period(p_membership_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_studio uuid;
begin
  select studio_id into v_studio from memberships where id = p_membership_id;
  if v_studio is null then
    raise exception 'no such membership' using errcode = 'PT404';
  end if;
  if not (is_desk_up(v_studio) or is_service_context()) then
    raise exception 'only staff can renew a membership' using errcode = 'PT403';
  end if;
  return advance_membership_period_run(p_membership_id);
end $$;
revoke execute on function advance_membership_period(uuid) from public, anon, authenticated;
grant  execute on function advance_membership_period(uuid) to authenticated, service_role;

-- =============================================================================
-- 4. xendit_begin_purchase — admit recurring (one period) and, on the renew
--    path, stamp renews_membership_id. Re-issued from 20260832260000 with the
--    type gate widened and the renew lookup added.
-- =============================================================================
create or replace function xendit_begin_purchase(p_studio_id uuid, p_plan_id uuid)
returns table(purchase_id uuid, amount_cents int, currency char(3))
language plpgsql security definer set search_path = public as $$
declare v_member uuid; mp membership_plans%rowtype; v_id uuid; v_renew uuid;
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
  -- Decision 66: a recurring plan is bought online as one period (no subscription
  -- yet — that is Decision 67). Decision 62 admits `trial`.
  if mp.type not in ('class_pack', 'drop_in', 'trial', 'recurring') then
    raise exception 'that plan is not a one-time purchase' using errcode = 'PT422';
  end if;

  -- Decision 62: an intro offer is bought once per person.
  if mp.type = 'trial' and exists (
    select 1 from memberships ms
      join membership_plans mp2 on mp2.id = ms.plan_id
     where ms.member_id = v_member
       and ms.studio_id = p_studio_id
       and mp2.type = 'trial'
  ) then
    raise exception 'The intro offer is for first-timers — you''ve had yours. Choose a pack or membership instead.'
      using errcode = 'PT409';
  end if;

  -- Decision 66: if the member already holds a live/past-due membership on this
  -- recurring plan, this checkout RENEWS it — decided at begin so the webhook,
  -- belt and reconcile all extend rather than create. (The same renew-vs-sell
  -- rule record_manual_payment uses for the desk.)
  if mp.type = 'recurring' then
    select ms.id into v_renew
      from memberships ms
     where ms.studio_id = p_studio_id and ms.member_id = v_member
       and ms.plan_id = p_plan_id and ms.status in ('active', 'past_due')
     order by ms.current_period_end desc nulls last
     limit 1;
  end if;

  insert into xendit_purchases (studio_id, member_id, plan_id, amount_cents, currency, renews_membership_id)
  values (p_studio_id, v_member, p_plan_id, mp.price_cents, mp.currency, v_renew)
  returning id into v_id;

  return query select v_id, mp.price_cents, mp.currency;
end $$;
revoke execute on function xendit_begin_purchase(uuid, uuid) from public, anon;
grant  execute on function xendit_begin_purchase(uuid, uuid) to authenticated, service_role;

-- =============================================================================
-- 5. xendit_activate_success_internal — the plan branch EXTENDS when the
--    purchase names a still-live/past-due membership, else activates a new one.
--    Re-issued from 20260832320000; the product branch and shared tail are
--    byte-for-byte, only the plan branch changed.
-- =============================================================================
create or replace function xendit_activate_success_internal(p_purchase_id uuid, p_payment_id text)
returns text
language plpgsql security definer set search_path = public as $$
declare p xendit_purchases%rowtype; v_ms uuid; v_prior text;
        o product_orders%rowtype; prod products%rowtype;
begin
  select * into p from xendit_purchases where id = p_purchase_id for update;
  if p.id is null then return 'unknown_purchase'; end if;
  if p.status = 'succeeded' then return 'already_succeeded'; end if;
  v_prior := p.status;

  if p.product_order_id is not null then
    -- A product purchase: mark the order paid, record the sale (the stock was
    -- decremented at reserve, so release the hold then record the sale — net
    -- zero to products.stock, the ledger balanced), a payments row tagged with
    -- the order (never a membership), and the "ready to collect" email. NEVER
    -- activate_purchase — a product touches no membership, credit or booking.
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
                          status, provider, reference, description, paid_at)
    values (p.studio_id, p.member_id, o.id, p.amount_cents, p.currency, 'succeeded', 'xendit',
            nullif(p_payment_id, ''), prod.name || ' ×' || o.quantity, now());

    perform queue_notification(
      p.studio_id, p.member_id, 'product_order_paid',
      jsonb_build_object('product', prod.name, 'quantity', o.quantity),
      'product_order_paid:' || o.id::text);

  else
    -- A plan purchase. Decision 66: when this purchase names a membership that
    -- is still active/past-due, EXTEND it one period from its old end; if that
    -- membership has drifted (cancelled/expired/frozen) or there is none, fall
    -- back to a fresh purchase. advance_membership_period_run is the UNGUARDED
    -- twin — the anon webhook is not desk/service at runtime.
    if p.renews_membership_id is not null and exists (
         select 1 from memberships where id = p.renews_membership_id
            and status in ('active', 'past_due') and not membership_frozen_now(id)) then
      v_ms := p.renews_membership_id;
      perform advance_membership_period_run(p.renews_membership_id);
    else
      v_ms := activate_purchase(p.studio_id, p.member_id, p.plan_id, p.amount_cents, p.currency,
                                null, null, false);
      -- Decision 66: an online recurring purchase is ONE period — no saved card,
      -- no auto-charge. activate_purchase sets auto_renew = (type='recurring');
      -- the online path renews by hand, so turn it off (harmless for a pack,
      -- which is already false). The extend branch above leaves it untouched.
      update memberships set auto_renew = false where id = v_ms;
    end if;

    insert into payments (studio_id, member_id, membership_id, amount_cents, currency,
                          status, provider, reference, description, paid_at)
    select p.studio_id, p.member_id, v_ms, p.amount_cents, p.currency, 'succeeded', 'xendit',
           nullif(p_payment_id, ''), mp.name, now()
      from membership_plans mp where mp.id = p.plan_id;
  end if;

  -- Expired is not final (see 20260831820000).
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
revoke execute on function xendit_activate_success_internal(uuid, text) from public, anon, authenticated;
grant  execute on function xendit_activate_success_internal(uuid, text) to service_role;

-- =============================================================================
-- 6. sweep_membership_expiring — the once-per-period 7-day reminder, for a
--    self-renew (auto_renew false, no subscription) recurring membership.
--    Dedupe on the membership + period-end date, so a renewed membership gets a
--    fresh reminder next period and never two for the same one.
-- =============================================================================
create function sweep_membership_expiring()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  if not is_service_context() then
    raise exception 'this is a scheduled job, not a user action' using errcode = 'PT403';
  end if;

  for r in
    select ms.id, ms.studio_id, ms.member_id, s.name as studio_name,
           pl.name as plan_name, s.timezone as tz,
           (ms.current_period_end at time zone s.timezone)::date as end_date
      from memberships ms
      join membership_plans pl on pl.id = ms.plan_id
      join studios s on s.id = ms.studio_id
     where pl.type = 'recurring'
       and ms.status = 'active'
       and ms.auto_renew = false
       and ms.stripe_subscription_id is null
       and ms.current_period_end is not null
       and not membership_frozen_now(ms.id)
       and (ms.current_period_end at time zone s.timezone)::date
             between (now() at time zone s.timezone)::date
                 and (now() at time zone s.timezone)::date + 7
  loop
    perform queue_notification(
      r.studio_id, r.member_id, 'membership_expiring',
      jsonb_build_object(
        'plan_name', r.plan_name,
        'ends_on', to_char(r.end_date, 'FMDD Mon YYYY'),
        'renew_url', member_portal_url(r.studio_id, '/account/plan')),
      'membership_expiring:' || r.id::text || ':' || r.end_date::text);
    n := n + 1;
  end loop;

  return jsonb_build_object('queued', n);
end $$;
revoke execute on function sweep_membership_expiring() from public, anon, authenticated;
grant  execute on function sweep_membership_expiring() to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin perform cron.unschedule('studiior-membership-expiring'); exception when others then null; end;
    -- 03:30, after the period sweep at 03:20.
    perform cron.schedule('studiior-membership-expiring', '30 3 * * *',
      $c$select sweep_membership_expiring()$c$);
  end if;
end $$;

-- =============================================================================
-- 7. sales_history — add is_renewal (the shown payment's membership has an
--    earlier succeeded payment). A new output column needs DROP + recreate; the
--    one-row-per-membership shape is unchanged. Re-issued from 20260832310000;
--    ACL re-asserted (a drop re-opens the hosted anon default).
-- =============================================================================
drop function if exists sales_history(uuid, date, date, uuid, text);
create function sales_history(
  p_studio_id uuid, p_from date, p_to date,
  p_plan_id uuid default null, p_status text default null
) returns table (
  membership_id uuid, member_id uuid, member_name text,
  plan_id uuid, plan_name text, plan_type text,
  amount_cents int, currency char(3), payment_source text,
  bought_on timestamptz, starts_on date, expires_on date, sale_status text,
  is_renewal boolean
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
         -- Decision 66: the row is a renewal when its membership has more than
         -- one succeeded payment (the shown one is the latest). No shape change.
         (select count(*) from payments p2
           where p2.membership_id = ms.id
             and p2.status in ('succeeded', 'partially_refunded')) > 1 as is_renewal
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

  -- Decision 63: merchandise sales. plan_type 'merch'; no membership, so never
  -- a renewal.
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
         false as is_renewal
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

  order by bought_on desc;
end $$;
revoke all on function sales_history(uuid, date, date, uuid, text) from public, anon;
grant execute on function sales_history(uuid, date, date, uuid, text) to authenticated, service_role;

-- =============================================================================
-- Anon surface unchanged — EXACTLY THIRTEEN (the sales_history drop+recreate is
-- re-asserted above; nothing here is anon).
-- =============================================================================
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % functions, expected exactly 13', n; end if;
end $$;
