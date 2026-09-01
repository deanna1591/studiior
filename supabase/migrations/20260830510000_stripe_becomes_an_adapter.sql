-- =============================================================================
-- Migration 041: Stripe stops being the foundation and becomes the first adapter
-- =============================================================================
-- Decision 16. Migration 038's checkout handler created the membership, the
-- ledger row and the audit event itself. Migration 040 moved that work into
-- activate_purchase() and confirm_dropin_payment() so the manual path could
-- reach it, and this rewires Stripe to call the same two functions.
--
-- The point is not tidiness. "A manual payment activates a membership
-- identically to a Stripe one" is only true if there is ONE implementation; two
-- that agree today drift the first time somebody changes one of them. After
-- this migration the Stripe handler decides nothing about what a purchase
-- grants — it records who paid, by what provider, and calls the same code.
--
-- Every payments row Stripe writes is stamped provider = 'stripe', so revenue
-- reporting can separate what a provider moved from what the studio banked
-- itself, which is the whole reason the column exists.
-- =============================================================================

create or replace function stripe_handle_checkout_completed(
  p_studio_id uuid, p_obj jsonb
) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_kind      text := p_obj -> 'metadata' ->> 'kind';
  v_member    uuid := nullif(p_obj -> 'metadata' ->> 'member_id', '')::uuid;
  v_plan      uuid := nullif(p_obj -> 'metadata' ->> 'plan_id', '')::uuid;
  v_booking   uuid := nullif(p_obj -> 'metadata' ->> 'booking_id', '')::uuid;
  v_snapshot  int  := nullif(p_obj -> 'metadata' ->> 'price_cents', '')::int;
  v_currency  char(3) := upper(coalesce(p_obj ->> 'currency', 'usd'));
  v_amount    int  := coalesce((p_obj ->> 'amount_total')::int, v_snapshot, 0);
  v_ms        uuid;
begin
  if v_member is not null and not exists (
    select 1 from members where id = v_member and studio_id = p_studio_id
  ) then
    raise exception 'that member does not belong to this studio' using errcode = 'PT403';
  end if;

  if v_kind = 'dropin' then
    perform confirm_dropin_payment(p_studio_id, v_booking);

    update payments
       set status = 'succeeded', paid_at = now(), provider = 'stripe',
           stripe_payment_intent_id = p_obj ->> 'payment_intent',
           amount_cents = v_amount, currency = v_currency, updated_at = now()
     where booking_id = v_booking and studio_id = p_studio_id and status = 'pending';

    if not found then
      insert into payments (studio_id, member_id, booking_id, amount_cents, currency,
                            status, provider, description, stripe_payment_intent_id, paid_at)
      values (p_studio_id, v_member, v_booking, v_amount, v_currency,
              'succeeded', 'stripe', 'Drop-in class', p_obj ->> 'payment_intent', now());
    end if;
    return 'dropin_paid';
  end if;

  -- The shared grant. Everything about what a plan gives a member — the
  -- snapshot, the pack credits, the expiry, the audit row — lives there and is
  -- identical to what the front desk gets when they record cash.
  v_ms := activate_purchase(p_studio_id, v_member, v_plan,
                            coalesce(v_snapshot, v_amount), v_currency,
                            p_obj ->> 'customer', nullif(p_obj ->> 'subscription', ''));

  insert into payments (studio_id, member_id, membership_id, amount_cents, currency,
                        status, provider, description, stripe_payment_intent_id, paid_at)
  select p_studio_id, v_member, v_ms, v_amount, v_currency, 'succeeded', 'stripe',
         mp.name, p_obj ->> 'payment_intent', now()
    from membership_plans mp where mp.id = v_plan;

  return 'membership_created';
end $$;

-- The other two writers, stamped with the provider they came from.
create or replace function stripe_handle_invoice_paid(p_studio_id uuid, p_obj jsonb)
returns text
language plpgsql security definer set search_path = public as $$
declare
  ms   memberships%rowtype;
  plan membership_plans%rowtype;
  v_start timestamptz; v_end timestamptz; v_bal int;
begin
  select * into ms from memberships
   where studio_id = p_studio_id
     and stripe_subscription_id = nullif(p_obj ->> 'subscription', '');
  if not found then
    return 'no_matching_membership';
  end if;
  select * into plan from membership_plans where id = ms.plan_id;

  v_start := to_timestamp((p_obj -> 'lines' -> 'data' -> 0 -> 'period' ->> 'start')::bigint);
  v_end   := to_timestamp((p_obj -> 'lines' -> 'data' -> 0 -> 'period' ->> 'end')::bigint);

  update memberships
     set status = 'active',
         current_period_start = coalesce(v_start, current_period_start),
         current_period_end   = coalesce(v_end, current_period_end),
         renews_on            = coalesce(v_end::date, renews_on),
         credits_remaining    = case when plan.type = 'recurring'
                                     then plan.credits_per_period
                                     else credits_remaining end,
         credits_reset_at     = coalesce(v_end, credits_reset_at)
   where id = ms.id;

  if plan.type = 'recurring' and plan.credits_per_period is not null then
    select coalesce(sum(delta), 0) into v_bal
      from credit_ledger where studio_id = p_studio_id and member_id = ms.member_id;
    insert into credit_ledger (studio_id, member_id, membership_id, delta, reason,
                               balance_after, expires_at)
    values (p_studio_id, ms.member_id, ms.id, plan.credits_per_period, 'period_grant',
            v_bal + plan.credits_per_period, v_end);
  end if;

  insert into payments (studio_id, member_id, membership_id, amount_cents, currency,
                        status, provider, description, stripe_invoice_id, paid_at)
  values (p_studio_id, ms.member_id, ms.id, coalesce((p_obj ->> 'amount_paid')::int, 0),
          upper(coalesce(p_obj ->> 'currency', ms.currency)), 'succeeded', 'stripe',
          coalesce(plan.name, 'Membership'), p_obj ->> 'id', now());

  insert into membership_events (studio_id, membership_id, type, from_status, to_status)
  values (p_studio_id, ms.id, 'renewed', ms.status, 'active');

  return 'renewed';
end $$;

create or replace function stripe_handle_invoice_failed(p_studio_id uuid, p_obj jsonb)
returns text
language plpgsql security definer set search_path = public as $$
declare ms memberships%rowtype;
begin
  select * into ms from memberships
   where studio_id = p_studio_id
     and stripe_subscription_id = nullif(p_obj ->> 'subscription', '');
  if not found then
    return 'no_matching_membership';
  end if;

  update memberships set status = 'past_due' where id = ms.id;

  insert into payments (studio_id, member_id, membership_id, amount_cents, currency,
                        status, provider, description, stripe_invoice_id,
                        failure_code, failure_message, attempt_count)
  values (p_studio_id, ms.member_id, ms.id, coalesce((p_obj ->> 'amount_due')::int, 0),
          upper(coalesce(p_obj ->> 'currency', ms.currency)), 'failed', 'stripe',
          'Membership payment', p_obj ->> 'id',
          p_obj -> 'last_finalization_error' ->> 'code',
          p_obj -> 'last_finalization_error' ->> 'message',
          coalesce((p_obj ->> 'attempt_count')::int, 1));

  insert into membership_events (studio_id, membership_id, type, from_status, to_status)
  values (p_studio_id, ms.id, 'payment_failed', ms.status, 'past_due');

  perform queue_payment_failed(ms.id);
  return 'past_due';
end $$;

-- A drop-and-recreate would have re-opened these; create or replace keeps the
-- ACL, but re-asserting costs nothing and migration 034 owes the same.
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
   where nsp.nspname = 'public' and p.proname like 'stripe_handle%'
     and (has_function_privilege('anon', p.oid, 'execute')
          or has_function_privilege('authenticated', p.oid, 'execute'));
  if n > 0 then
    raise exception 'migration 041 left % stripe handler(s) open to a client role', n;
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- The setup checklist stops nagging about a provider a studio may never want
--
-- Migration 039 made connect_stripe derive from a connected account, which was
-- right when a provider was the only way to take money. Under Decision 16 a
-- studio may quite reasonably never connect one, and an item that can never be
-- ticked is an item that trains people to ignore the list.
-- -----------------------------------------------------------------------------
-- The DEFAULT carries it, not an UPDATE. Migrations run against an empty
-- database before the seed creates a single studio, so an UPDATE here touches
-- nothing and every studio created afterwards gets '{}' — the item would have
-- gone on nagging exactly as before, silently.
alter table studio_settings
  add column if not exists setup_optional_items text[] not null
  default array['connect_stripe'];

update studio_settings
   set setup_optional_items = array['connect_stripe']
 where not ('connect_stripe' = any (setup_optional_items));

comment on column studio_settings.setup_optional_items is
  'Checklist items that are nice to have rather than outstanding. '
  'connect_stripe is here because Decision 16 makes an online provider '
  'optional — a studio that takes cash is finished, not incomplete.';
