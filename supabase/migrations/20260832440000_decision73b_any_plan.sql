-- Decision 73b (extension) — Pay now offers EVERY plan, and ANY plan settles
-- the held booking. Same Decision 73 scope, no new decision.
--
-- 73b (migration 243) applied a drop_in plan's fresh credit to the buyer's
-- oldest unpaid app-booked drop-in. This generalises that: the apply runs for
-- ANY member plan activation through xendit_activate_success_internal. If the
-- buyer holds unpaid app-booked drop-ins, the new membership settles the OLDEST
-- one:
--   * credit-granting plans (drop_in, class_pack, trial) consume one credit
--     through the existing credit_ledger path (book_class §6) and link the
--     booking as a class_pack seat;
--   * a limited recurring plan (per-period credits) consumes one credit and
--     links the booking as a membership seat;
--   * an unlimited recurring plan links the booking as a membership seat with
--     NO credit consumed.
-- In every case payment_source flips drop_in → the membership source
-- (class_pack or membership), so the booking is paid and drops out of the 73a
-- cap's unpaid count.
--
-- ONE booking per activation; replay-idempotent (xendit_activate_success_internal
-- returns 'already_succeeded' before reaching the apply, and the apply no-ops
-- once the membership's usable credit is spent / it already covers nothing).
--
-- COVERAGE reuses book_class's own building blocks rather than re-implementing a
-- different notion of eligibility: the identical class_type_ids jsonb test, and
-- occurrence_is_peak + peak_allowance_state for a membership-priority plan on a
-- peak class (a pack/drop_in cannot carry an allowance — migration 104's CHECK —
-- so it is never peak-gated, exactly as in book_class §3b). A plan that does not
-- cover the held class leaves the booking untouched. (Plan visibility is not a
-- coverage test: book_class's §2.2 walk does not filter a HELD membership on
-- visibility, so a staff-only plan the member now holds covers normally — adding
-- a visibility gate here would be a DIFFERENT eligibility than book_class's.)
--
-- Placement unchanged: the apply is called ONLY from
-- xendit_activate_success_internal (the online member purchase). activate_purchase
-- itself is untouched, so the desk (record_manual_payment) and Stripe
-- plan-activation paths do not auto-apply. A Stripe-held drop-in (status
-- pending_payment) is deliberately NOT the apply target; it settles through its
-- own checkout.
--
-- The 243 helper apply_dropin_credit_to_unpaid is renamed to apply_plan_to_unpaid
-- (it is no longer drop-in-only) and dropped. No new anon surface — both
-- functions are service-role only. Anon stays THIRTEEN.
--
-- creates: apply_plan_to_unpaid(uuid, uuid, uuid)
-- re-issues: xendit_activate_success_internal(uuid, text)

-- The 243 helper was drop-in-only; apply_plan_to_unpaid supersedes it. It has no
-- caller but xendit_activate_success_internal (re-issued below to the new name).
drop function if exists apply_dropin_credit_to_unpaid(uuid, uuid, uuid);

-- =============================================================================
-- 1. apply_plan_to_unpaid — settle the member's OLDEST unpaid app-booked drop-in
--    with the just-activated membership, mirroring book_class §2.2 + §3b + §6.
-- =============================================================================
create or replace function apply_plan_to_unpaid(
  p_studio_id uuid, p_member_id uuid, p_membership_id uuid
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_tz           text;
  v_type         text;
  v_remaining    int;
  v_expires      date;
  v_restrictions jsonb;
  v_pay          payment_source;
  v_consume      boolean;
  v_booking      uuid;
  v_occurrence   uuid;
  v_class_type   uuid;
  v_starts       timestamptz;
  v_covers       boolean;
  v_peak         jsonb;
  v_balance      int;
  v_ledger       uuid;
begin
  -- The just-activated membership. Lock it: credits_remaining is a cache written
  -- in the same transaction as the ledger row. A replay (or a second call) finds
  -- no usable credit / an already-settled booking and returns — idempotent.
  select s.timezone, mp.type, ms.credits_remaining, ms.expires_on, mp.restrictions
    into v_tz, v_type, v_remaining, v_expires, v_restrictions
    from memberships ms
    join membership_plans mp on mp.id = ms.plan_id
    join studios s on s.id = ms.studio_id
   where ms.id = p_membership_id
   for update of ms;
  if v_type is null then return null; end if;

  -- The paying source and whether it consumes a credit — EXACTLY book_class
  -- §2.2's priority CASE for a single membership:
  --   priority 1  unlimited recurring  -> membership, no consume
  --   priority 2  limited recurring    -> membership, consume
  --   priority 3  pack/drop_in/trial   -> class_pack, consume
  --   else        no usable credit     -> nothing to apply
  if v_type = 'recurring' and v_remaining is null then
    v_pay := 'membership'; v_consume := false;          -- unlimited
  elsif v_type = 'recurring' and coalesce(v_remaining, 0) > 0 then
    v_pay := 'membership'; v_consume := true;           -- limited, has credits
  elsif v_type in ('class_pack', 'drop_in', 'trial') and coalesce(v_remaining, 0) > 0 then
    v_pay := 'class_pack'; v_consume := true;           -- pack credits
  else
    return null;                                        -- nothing usable
  end if;

  -- The OLDEST unpaid drop-in: a booked (not pending_payment — the Stripe hold
  -- settles through its own checkout, untouched here) drop_in seat with no
  -- succeeded/partially-refunded payment. The same unpaid set the 73a cap counts.
  -- Its occurrence's class type and start are read for the coverage check below.
  select b.id, o.id, o.class_type_id, o.starts_at
    into v_booking, v_occurrence, v_class_type, v_starts
    from bookings b
    join class_occurrences o on o.id = b.occurrence_id
   where b.member_id = p_member_id and b.studio_id = p_studio_id
     and b.payment_source = 'drop_in'
     and b.status = 'booked'
     and not exists (select 1 from payments p
                      where p.booking_id = b.id
                        and p.status in ('succeeded', 'partially_refunded'))
   order by b.created_at asc
   limit 1
   for update of b;
  if v_booking is null then
    return null;  -- no unpaid drop-in; the credit stays on the membership
  end if;

  -- COVERAGE — book_class's own tests, applied to this one membership against
  -- the held class. (a) class-type restriction: the identical class_type_ids
  -- jsonb test (empty/absent covers everything).
  v_covers := (v_restrictions -> 'class_type_ids') is null
           or jsonb_typeof(v_restrictions -> 'class_type_ids') <> 'array'
           or jsonb_array_length(v_restrictions -> 'class_type_ids') = 0
           or (v_class_type is not null
               and jsonb_exists(v_restrictions -> 'class_type_ids', v_class_type::text));
  if not v_covers then
    return null;  -- the plan does not cover this class type — booking untouched
  end if;

  -- (b) peak — only a membership-priority plan can carry an allowance
  -- (book_class §3b); peak_allowance_state is null for a plan with no allowance
  -- and for a studio with the switch off. Exhausted -> the plan would not have
  -- booked this class, so it does not settle it either.
  if v_pay = 'membership' and occurrence_is_peak(v_occurrence) then
    v_peak := peak_allowance_state(p_membership_id, (v_starts at time zone v_tz)::date);
    if v_peak is not null and (v_peak ->> 'remaining')::int <= 0 then
      return null;  -- peak allowance exhausted — booking untouched
    end if;
  end if;

  -- Consume one credit through the existing ledger path (book_class §6) when the
  -- source consumes: a reversing ledger row carrying balance_after, the cache
  -- decremented in the same transaction, the booking's credit_entry_id set. An
  -- unlimited membership consumes nothing (credit_entry_id stays null).
  if v_consume then
    select coalesce(sum(delta), 0) into v_balance
      from credit_ledger
     where studio_id = p_studio_id and member_id = p_member_id;

    insert into credit_ledger (
      studio_id, member_id, membership_id, delta, reason,
      booking_id, balance_after, expires_at, actor_user_id
    ) values (
      p_studio_id, p_member_id, p_membership_id, -1, 'booking',
      v_booking, v_balance - 1,
      case when v_expires is not null then (v_expires + 1)::timestamp at time zone v_tz end,
      null
    ) returning id into v_ledger;

    update memberships set credits_remaining = credits_remaining - 1
     where id = p_membership_id;
  end if;

  -- Relink the booking to the membership and flip it off drop_in, so it is paid
  -- and no longer counts toward the 73a unpaid-booking cap.
  update bookings
     set payment_source = v_pay, membership_id = p_membership_id,
         credit_entry_id = v_ledger
   where id = v_booking;

  return v_booking;
end $$;
revoke execute on function apply_plan_to_unpaid(uuid, uuid, uuid) from public, anon, authenticated;
grant  execute on function apply_plan_to_unpaid(uuid, uuid, uuid) to service_role;

-- =============================================================================
-- 2. xendit_activate_success_internal — re-issued from 20260832430000. The
--    product branch and the shared tail are byte-for-byte; the only change is
--    the apply call, now apply_plan_to_unpaid (any plan, not drop-in only).
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

    -- Decision 73b (extension): ANY plan bought online settles the buyer's
    -- OLDEST unpaid app-booked drop-in — the new membership is applied to that
    -- booking (a credit consumed unless it is an unlimited membership) so it no
    -- longer counts toward the 73a unpaid-booking cap. The helper no-ops unless
    -- v_ms has a usable credit (or is unlimited) AND covers the held class, so a
    -- non-covering plan, or one with nothing usable, passes through untouched.
    -- Idempotent: a replay returns 'already_succeeded' above before reaching here.
    perform apply_plan_to_unpaid(p.studio_id, p.member_id, v_ms);

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
-- Anon surface stays EXACTLY THIRTEEN (both functions are service-role only).
-- =============================================================================
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then
    raise exception 'anon surface is % functions, expected exactly 13', n;
  end if;
end $$;
