-- =============================================================================
-- Migration 095 — a recurring membership gets a period, and a cash studio can
-- see who owes it money
--
-- activate_purchase() wrote status, price, credits and auto_renew, and left
-- current_period_start, current_period_end and renews_on NULL. A recurring
-- membership with no period is one nothing can bill, renew or expire: §7.3's
-- grace window is computed from current_period_end, the member screen cannot
-- say when it renews, and book_class()'s past_due allowance —
--   now() < coalesce(ms.current_period_end, now()) + grace
-- — collapses to `now() < now() + grace`, which is TRUE FOREVER. A past-due
-- member would have kept booking indefinitely.
--
-- WHY DECISION 16'S OWN TEST DID NOT CATCH IT, which is the part worth
-- keeping: it DOES use a recurring plan, and it compares the cash membership
-- and the Stripe membership field for field. Both were NULL. The Stripe half
-- is driven by a `checkout.session.completed`, whose object carries no
-- current_period_* — those arrive in a later subscription event the test never
-- sends. So the assertion held, and it held because NEITHER side did the
-- thing. Two implementations agreeing proves nothing when both are wrong; it
-- is "a guard that never fires looks exactly like a guard that passes" wearing
-- an equality check.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- One definition of "a billing period later"
--
-- Computed in the STUDIO'S LOCAL TIME and converted back, never by adding an
-- interval to a timestamptz. A month added to an instant is added in UTC, so a
-- 07:00 period boundary in Prague becomes 06:00 or 08:00 across a clock
-- change and the billing day drifts. Same trap generate_occurrences() was
-- written around.
-- -----------------------------------------------------------------------------
create or replace function plan_period_end(
  p_plan_id uuid, p_from timestamptz)
returns timestamptz
language plpgsql stable security definer set search_path = public as $$
declare pl membership_plans%rowtype; v_tz text; v_n int;
begin
  select * into pl from membership_plans where id = p_plan_id;
  if not found then
    raise exception 'no such plan' using errcode = 'PT404';
  end if;
  -- A pack or a drop-in has no period. Answering with one would invent a
  -- renewal date for something that does not renew.
  if pl.type <> 'recurring' or pl.billing_interval is null then
    return null;
  end if;
  select s.timezone into v_tz from studios s where s.id = pl.studio_id;
  v_n := greatest(1, coalesce(pl.billing_interval_count, 1));

  return ((p_from at time zone v_tz) + make_interval(
            weeks  => case when pl.billing_interval = 'week'    then v_n else 0 end,
            months => case when pl.billing_interval = 'month'   then v_n
                           when pl.billing_interval = 'quarter' then v_n * 3
                           else 0 end,
            years  => case when pl.billing_interval = 'year'    then v_n else 0 end
          )) at time zone v_tz;
end $$;

comment on function plan_period_end(uuid, timestamptz) is
  'One billing interval after the given instant, in the studio''s own clock. '
  'Null for anything that does not recur.';


-- -----------------------------------------------------------------------------
-- One definition of "frozen right now"
--
-- §7.4's freeze is a PAIR OF DATES, and `status = 'frozen'` is a separate fact
-- that a studio may or may not have set. book_class() has always read the
-- dates — `not (freeze_start is not null and freeze_end is not null and today
-- between them)` — so anything else reading only the status disagrees with the
-- one place it already matters. The first version of the renewal guard below
-- did exactly that and cheerfully renewed a frozen membership.
--
-- book_class() keeps its inline copy; rewriting it is not this migration's
-- business. Everything migration 095 adds asks here.
-- -----------------------------------------------------------------------------
create or replace function membership_frozen_now(p_membership_id uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select ms.status = 'frozen'
         or (ms.freeze_start is not null and ms.freeze_end is not null
             and studio_today(ms.studio_id) between ms.freeze_start and ms.freeze_end)
       from memberships ms where ms.id = p_membership_id), false)
$$;

-- -----------------------------------------------------------------------------
-- Activation writes the period
--
-- Re-issued from migration 050's FILE with the period added — `create or
-- replace` keeps the ACL, where a drop would hand it back the hosted default
-- grant for anon and authenticated.
--
-- starts_on also stops being `current_date`. That is the SERVER's day: a
-- Manila studio selling a membership at 07:00 local is at 23:00 UTC the day
-- before, so every morning sale was dated yesterday and every period computed
-- from it was a day short.
-- -----------------------------------------------------------------------------
create or replace function activate_purchase(
  p_studio_id uuid, p_member_id uuid, p_plan_id uuid, p_price_cents int,
  p_currency char(3), p_stripe_customer text default null,
  p_stripe_subscription text default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  plan membership_plans%rowtype; v_ms uuid; v_bal int;
  v_today date; v_start timestamptz; v_end timestamptz;
begin
  select * into plan from membership_plans
   where id = p_plan_id and studio_id = p_studio_id;
  if not found then
    raise exception 'no such plan for this studio' using errcode = 'PT404';
  end if;
  if not exists (select 1 from members where id = p_member_id and studio_id = p_studio_id) then
    raise exception 'that member does not belong to this studio' using errcode = 'PT403';
  end if;

  v_today := studio_today(p_studio_id);
  v_start := now();
  -- Null for a pack, a drop-in and a trial, which is what makes the columns
  -- mean something: a period present is a thing that renews.
  v_end   := plan_period_end(plan.id, v_start);

  insert into memberships (
    studio_id, member_id, plan_id, status, price_cents, currency, starts_on,
    current_period_start, current_period_end, renews_on, credits_reset_at,
    credits_remaining, expires_on, auto_renew,
    stripe_customer_id, stripe_subscription_id
  ) values (
    p_studio_id, p_member_id, plan.id,
    (case when plan.type = 'trial' then 'trialing' else 'active' end)::membership_status,
    -- §7.1: the price agreed at purchase, snapshotted. Never re-read from the
    -- plan afterwards, so editing a plan cannot reprice anybody already on it.
    coalesce(p_price_cents, plan.price_cents),
    coalesce(nullif(p_currency, ''), plan.currency),
    v_today,
    v_start, v_end,
    -- renews_on is the period end as one of the STUDIO's dates.
    (v_end at time zone (select s.timezone from studios s where s.id = p_studio_id))::date,
    -- Decision 3: no rollover. The allowance resets at the period boundary
    -- rather than accumulating, and only where there is an allowance at all —
    -- Decision 12 makes a null credits_per_period mean unlimited.
    case when plan.type = 'recurring' and plan.credits_per_period is not null
         then v_end end,
    case when plan.type = 'class_pack' then plan.credits else plan.credits_per_period end,
    case when plan.type = 'class_pack' and plan.validity_days is not null
         then v_today + plan.validity_days end,
    plan.type = 'recurring',
    p_stripe_customer, nullif(p_stripe_subscription, '')
  ) returning id into v_ms;

  -- §6: a pack's classes arrive as ledger rows. credits_remaining above is a
  -- cache of this, written in the same transaction and never independently.
  if plan.type = 'class_pack' and coalesce(plan.credits, 0) > 0 then
    select coalesce(sum(delta), 0) into v_bal
      from credit_ledger where studio_id = p_studio_id and member_id = p_member_id;
    insert into credit_ledger (studio_id, member_id, membership_id, delta, reason,
                               balance_after, expires_at, actor_user_id)
    values (p_studio_id, p_member_id, v_ms, plan.credits, 'purchase',
            v_bal + plan.credits,
            case when plan.validity_days is not null
                 then (v_today + plan.validity_days + 1)::timestamptz end,
            auth.uid());
  end if;

  insert into membership_events (studio_id, membership_id, type, to_status, actor_user_id)
  values (p_studio_id, v_ms, 'created',
          (case when plan.type = 'trial' then 'trialing' else 'active' end)::membership_status,
          auth.uid());

  return v_ms;
end $$;

-- -----------------------------------------------------------------------------
-- Renewal, for a studio with no webhook to roll the period forward
--
-- THE PERIOD ADVANCES FROM current_period_end, NEVER FROM TODAY. Paying four
-- days early must not shorten the next month, and paying four days late must
-- not move the anniversary to the 14th for ever. The billing day a member
-- agreed to is the one they keep.
--
-- A payment so late that one interval forward is STILL in the past leaves the
-- membership past due, and says so. That is correct rather than awkward: a
-- member two months behind owes two months, the desk records the second
-- payment, and the list below goes on showing them until they are square.
-- Rolling to today instead would quietly forgive the arrears and drift the
-- billing day at the same time.
--
-- Frozen is left alone deliberately. Taking cash is not a decision to unfreeze
-- somebody, and §7.4 is a separate conversation.
-- -----------------------------------------------------------------------------
create or replace function advance_membership_period(p_membership_id uuid)
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
  if not (is_desk_up(ms.studio_id) or is_service_context()) then
    raise exception 'only staff can renew a membership' using errcode = 'PT403';
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
  -- A membership that somehow has no period end (one sold before this
  -- migration) starts its first period now rather than raising — the studio
  -- should not have to repair data to take money.
  v_from := coalesce(ms.current_period_end, now());
  v_end  := plan_period_end(pl.id, v_from);

  v_status := case when v_end > now() then 'active' else 'past_due' end::membership_status;

  update memberships
     set current_period_start = v_from,
         current_period_end   = v_end,
         renews_on            = (v_end at time zone v_tz)::date,
         status               = v_status,
         -- Decision 3 again: reset, never add.
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
    -- The desk needs to know it is not square yet, on the spot.
    'still_owing', v_end <= now(),
    'periods_behind', case when v_end > now() then 0
      else greatest(1, ceil(extract(epoch from (now() - v_end)) /
        nullif(extract(epoch from (v_end - v_from)), 0))::int) end);
end $$;
create or replace function public.record_manual_payment(p_studio_id uuid, p_member_id uuid, p_kind text, p_amount_cents integer, p_method text, p_plan_id uuid DEFAULT NULL::uuid, p_booking_id uuid DEFAULT NULL::uuid, p_currency character DEFAULT NULL::bpchar, p_method_note text DEFAULT NULL::text, p_reference text DEFAULT NULL::text, p_paid_at timestamp with time zone DEFAULT now(), p_description text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_currency char(3);
  v_ms       uuid;
  v_payment  uuid;
  v_confirmed boolean := false;
  v_plan_name text;
  v_renewing uuid;
  v_renewal  jsonb;
begin
  if not is_desk_up(p_studio_id) then
    raise exception 'only staff can record a payment' using errcode = 'PT403';
  end if;
  -- Lockout (migration 044). The studio's own subscription to Studiior has
  -- lapsed past its grace period. Reads stay open everywhere so nothing looks
  -- lost; this is one of the four places where DOING something stops.
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
    -- RENEW OR SELL, and the difference is whether they are already on this
    -- plan. A studio taking cash has no webhook to roll a period forward, so
    -- the desk taking next month's money IS the renewal — and creating a
    -- second membership for it would leave the member holding two, with two
    -- periods and two allowances, which is what "it just made another one"
    -- looks like three months later.
    --
    -- A payment for a DIFFERENT plan is a plan change and still creates a new
    -- membership, as it always did. A pack is never a renewal: it has no
    -- period, and buying a second one is buying a second one.
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
      v_renewal := advance_membership_period(v_renewing);
    else
      -- The same function the Stripe webhook calls. Not a copy of it.
      v_ms := activate_purchase(p_studio_id, p_member_id, p_plan_id,
                                p_amount_cents, v_currency);
    end if;
    select name into v_plan_name from membership_plans where id = p_plan_id;

  elsif p_kind = 'dropin' then
    if p_booking_id is null then
      raise exception 'which booking?' using errcode = 'PT400';
    end if;
    v_confirmed := confirm_dropin_payment(p_studio_id, p_booking_id);
  end if;

  insert into payments (
    studio_id, member_id, membership_id, booking_id, amount_cents, currency,
    status, provider, method, method_note, reference, description,
    paid_at, recorded_by
  ) values (
    p_studio_id, p_member_id, v_ms, p_booking_id, p_amount_cents, v_currency,
    'succeeded', 'manual', p_method, p_method_note, p_reference,
    coalesce(p_description,
             case p_kind when 'plan' then v_plan_name
                         when 'dropin' then 'Drop-in class'
                         else 'Payment' end),
    coalesce(p_paid_at, now()), auth.uid()
  ) returning id into v_payment;

  -- If a held seat was waiting on this, it is a real booking now and the
  -- confirmation goes out — the same trigger, on the same status change, as
  -- when Stripe confirms one.
  return jsonb_build_object(
    'payment_id', v_payment,
    'membership_id', v_ms,
    'booking_confirmed', v_confirmed,
    -- Present only when this renewed something, so the desk is told on the
    -- spot what the money bought — and told when it is still not enough.
    'renewed', v_renewal
  );
end $function$;

-- -----------------------------------------------------------------------------
-- The nightly pass that makes a lapsed period mean something
--
-- SCOPED TO MEMBERSHIPS WITH NO STRIPE SUBSCRIPTION, which is the whole gap.
-- A Connect subscription rolls its own period forward through
-- customer.subscription.updated and says past_due through
-- invoice.payment_failed; sweeping those here would mark a member past due for
-- the minutes between a successful renewal and its webhook arriving.
--
-- §7.3 does the rest and is untouched: grace from payment_grace_days, then new
-- bookings blocked and existing ones standing. This only supplies the status
-- and the date that window is measured from — which is exactly what was
-- missing, since `now() < coalesce(null, now()) + grace` is true forever.
-- -----------------------------------------------------------------------------
create or replace function sweep_membership_periods()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare n_due int := 0;
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
    returning ms.id, ms.studio_id, ms.status)
  insert into membership_events (studio_id, membership_id, type, from_status, to_status)
  select l.studio_id, l.id, 'period_lapsed', 'active', 'past_due' from lapsed l;
  get diagnostics n_due = row_count;

  return jsonb_build_object('marked_past_due', n_due);
end $$;

-- -----------------------------------------------------------------------------
-- WHO OWES THE STUDIO MONEY
--
-- The single most useful screen for a studio with no card provider, and it did
-- not exist anywhere. Overdue first, then due soon, with what they owe and how
-- long it has been.
--
-- Subscription-backed memberships are excluded: Stripe collects those and a
-- studio does not chase them at the desk. Frozen, cancelled and expired are
-- excluded too — a paused membership is not a debt.
--
-- The amount owed is the membership's OWN price_cents, never the plan's. §7.1
-- snapshots the price at purchase precisely so that editing a plan does not
-- reprice anybody already on it, and a chase list quoting the new price would
-- undo that at the counter.
-- -----------------------------------------------------------------------------
create or replace function memberships_due(
  p_studio_id uuid, p_within_days int default 7)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_today date; v_currency char(3); v_rows jsonb; v_ever int;
begin
  if not (is_desk_up(p_studio_id) or is_service_context()) then
    raise exception 'this is for the people who take the money'
      using errcode = 'PT403', hint = 'Permissions §9 gives front desk payments.';
  end if;
  select s.currency into v_currency from studios s where s.id = p_studio_id;
  if v_currency is null then raise exception 'no such studio' using errcode = 'PT404'; end if;
  v_today := studio_today(p_studio_id);

  select count(*) into v_ever
    from memberships ms join membership_plans pl on pl.id = ms.plan_id
   where ms.studio_id = p_studio_id and pl.type = 'recurring';

  select coalesce(jsonb_agg(to_jsonb(x) order by x.days_overdue desc, x.due_on, x.member_name),
                  '[]'::jsonb)
    into v_rows from (
    select ms.id                as membership_id,
           m.id                 as member_id,
           m.first_name || ' ' || m.last_name as member_name,
           m.email,
           pl.id                as plan_id,
           pl.name              as plan_name,
           ms.price_cents       as owed_cents,
           ms.currency,
           ms.status::text      as status,
           (ms.current_period_end at time zone s.timezone)::date as due_on,
           greatest(0, v_today - (ms.current_period_end at time zone s.timezone)::date)
             as days_overdue,
           (select max(p.paid_at) from payments p
             where p.membership_id = ms.id and p.status = 'succeeded') as last_paid_at,
           '/members/' || m.id || '/payment?plan=' || pl.id as record_href,
           '/members/' || m.id as member_href
      from memberships ms
      join membership_plans pl on pl.id = ms.plan_id
      join members m on m.id = ms.member_id
      join studios s on s.id = ms.studio_id
     where ms.studio_id = p_studio_id
       and pl.type = 'recurring'
       and ms.status in ('active', 'past_due')
       and ms.stripe_subscription_id is null
       and ms.current_period_end is not null
       and (ms.current_period_end at time zone s.timezone)::date
             <= v_today + greatest(0, p_within_days)
       and not membership_frozen_now(ms.id)
       and m.status <> 'archived') x;

  return jsonb_build_object(
    'today', v_today, 'currency', v_currency, 'within_days', p_within_days,
    -- 'empty' is a studio that sells no recurring plans at all; 'clear' is one
    -- where everybody is paid up. A screen that cannot tell those apart says
    -- "nobody owes you anything" to a studio whose memberships are all on
    -- Stripe, which is true and useless.
    'state', case when v_ever = 0 then 'empty'
                  when jsonb_array_length(v_rows) = 0 then 'clear'
                  else 'ok' end,
    'rows', v_rows,
    'overdue_count', (select count(*) from jsonb_array_elements(v_rows) r
                       where (r ->> 'days_overdue')::int > 0),
    'overdue_cents', (select coalesce(sum((r ->> 'owed_cents')::bigint), 0)
                        from jsonb_array_elements(v_rows) r
                       where (r ->> 'days_overdue')::int > 0),
    'due_soon_count', (select count(*) from jsonb_array_elements(v_rows) r
                        where (r ->> 'days_overdue')::int = 0),
    'empty_hint', 'Recurring memberships you collect yourself show up here as they fall due — who owes you, how much, and how long it has been. Sell a monthly plan and this becomes your Monday morning.',
    'clear_hint', 'Everybody is paid up.');
end $$;

-- -----------------------------------------------------------------------------
-- Closed by default, then opened to exactly who needs each one.
-- -----------------------------------------------------------------------------
revoke execute on function membership_frozen_now(uuid) from public, anon, authenticated;
grant execute on function membership_frozen_now(uuid) to authenticated, service_role;
revoke execute on function plan_period_end(uuid, timestamptz) from public, anon, authenticated;
revoke execute on function advance_membership_period(uuid) from public, anon, authenticated;
revoke execute on function sweep_membership_periods() from public, anon, authenticated;
revoke execute on function memberships_due(uuid, int) from public, anon, authenticated;

grant execute on function plan_period_end(uuid, timestamptz) to service_role;
grant execute on function sweep_membership_periods() to service_role;
-- Guarded desk-up inside; §9 gives front desk payments, and the desk is
-- exactly who chases and records them.
grant execute on function advance_membership_period(uuid) to authenticated, service_role;
grant execute on function memberships_due(uuid, int) to authenticated, service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('studiior-membership-periods');
  end if;
exception when others then null;
end $$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    -- 03:20, between the generator at 03:10 and the recount at 03:40.
    perform cron.schedule('studiior-membership-periods', '20 3 * * *',
      $c$select sweep_membership_periods()$c$);
  end if;
end $$;
