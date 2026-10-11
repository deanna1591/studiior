-- Decision 73b — Pay now: a drop_in plan bought online settles the buyer's
-- OLDEST unpaid app-booked drop-in.
--
-- 73a (migration 242) capped how many unpaid app bookings a member may hold and
-- refused a new one with `pay_first`. 73b is how they pay: the member taps "Pay
-- now" on an unpaid booking, which opens the studio's public active drop_in plan
-- through the EXISTING Xendit plan rail (/buy/{plan}?return=/class/{id} — no new
-- begin function, no xendit_purchases column). On activation of that purchase
-- the new credit is applied to the member's oldest unpaid drop-in: the booking
-- is relinked to the new membership, one credit is consumed through the existing
-- credit_ledger path (book_class §6), and its payment_source flips drop_in →
-- class_pack — so it is paid and no longer counts toward the cap.
--
-- Placement: the apply is called ONLY from xendit_activate_success_internal (the
-- online member purchase). activate_purchase itself is UNCHANGED, so the desk
-- (record_manual_payment) and Stripe plan-activation paths do not auto-apply —
-- "Desk payment unchanged" and "Stripe pending_payment path untouched" both
-- hold. A Stripe-held drop-in (status pending_payment) is deliberately NOT the
-- apply target; it settles through its own checkout.
--
-- Idempotent: xendit_activate_success_internal returns 'already_succeeded' on a
-- replay before reaching the apply, and the apply itself no-ops once the
-- membership's one drop_in credit is spent (credits_remaining = 0).
--
-- No new anon surface — both functions are service-role only. Anon stays THIRTEEN.
--
-- creates: apply_dropin_credit_to_unpaid(uuid, uuid, uuid)
-- re-issues: xendit_activate_success_internal(uuid, text)

-- =============================================================================
-- 1. apply_dropin_credit_to_unpaid — consume the fresh drop_in credit against
--    the member's OLDEST unpaid app-booked drop-in, mirroring book_class §6.
-- =============================================================================
create or replace function apply_dropin_credit_to_unpaid(
  p_studio_id uuid, p_member_id uuid, p_membership_id uuid
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_tz        text;
  v_type      text;
  v_remaining int;
  v_expires   date;
  v_booking   uuid;
  v_balance   int;
  v_ledger    uuid;
begin
  -- Only a drop_in-type membership with an unused credit applies. A replay
  -- (or a second call) finds credits_remaining = 0 and returns — idempotent.
  -- A recurring/pack extend (the renewal branch) is type <> 'drop_in', so this
  -- is a no-op there; only an online drop_in purchase reaches a credit here.
  select s.timezone, mp.type, ms.credits_remaining, ms.expires_on
    into v_tz, v_type, v_remaining, v_expires
    from memberships ms
    join membership_plans mp on mp.id = ms.plan_id
    join studios s on s.id = ms.studio_id
   where ms.id = p_membership_id
   for update of ms;

  if v_type is distinct from 'drop_in' or coalesce(v_remaining, 0) <= 0 then
    return null;
  end if;

  -- The OLDEST unpaid drop-in: a booked (not pending_payment — the Stripe hold
  -- settles through its own checkout, untouched here) drop_in seat with no
  -- succeeded/partially-refunded payment. The same unpaid set the 73a cap counts.
  select b.id into v_booking
    from bookings b
   where b.member_id = p_member_id and b.studio_id = p_studio_id
     and b.payment_source = 'drop_in'
     and b.status = 'booked'
     and not exists (select 1 from payments p
                      where p.booking_id = b.id
                        and p.status in ('succeeded', 'partially_refunded'))
   order by b.created_at asc
   limit 1
   for update;

  if v_booking is null then
    return null;  -- the credit stays on the membership, unused
  end if;

  -- Consume one credit through the existing ledger path (book_class §6): a
  -- reversing ledger row carrying balance_after, the cache decremented in the
  -- same transaction, and the booking relinked to the membership as a pack seat
  -- so it is paid and drops out of the cap's unpaid count.
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

  update bookings
     set payment_source = 'class_pack', membership_id = p_membership_id,
         credit_entry_id = v_ledger
   where id = v_booking;

  return v_booking;
end $$;
revoke execute on function apply_dropin_credit_to_unpaid(uuid, uuid, uuid) from public, anon, authenticated;
grant  execute on function apply_dropin_credit_to_unpaid(uuid, uuid, uuid) to service_role;

-- =============================================================================
-- 2. xendit_activate_success_internal — re-issued from 20260832340000. The
--    product branch and the shared tail are byte-for-byte; the only change is
--    the one apply_dropin_credit_to_unpaid call in the plan branch (73b).
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

    -- Decision 73b: a drop_in plan bought online settles the buyer's OLDEST
    -- unpaid app-booked drop-in — the credit is applied to that booking so it no
    -- longer counts toward the 73a unpaid-booking cap. The helper no-ops unless
    -- v_ms is a drop_in membership with an unused credit, so the renewal/pack
    -- branches pass through untouched. Idempotent: a replay returns
    -- 'already_succeeded' above before reaching here.
    perform apply_dropin_credit_to_unpaid(p.studio_id, p.member_id, v_ms);

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
