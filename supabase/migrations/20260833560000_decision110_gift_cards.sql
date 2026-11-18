-- Decision 110 — gift cards, and Decision 103(f) full-credit checkout.
--
-- Anyone buys a gift card for a studio from the public {member host}/gift page
-- without an account: an amount from the studio's presets or any amount >= the
-- studio minimum (default PHP 500), the recipient and buyer names/emails, an
-- optional message and delivery date. Payment is through Xendit; nothing is
-- issued until the payment succeeds. On success the buyer gets a receipt with
-- the code and the recipient gets the card on the delivery date; the full amount
-- becomes gift credit (member_credits, reason 'gift_credit') when a member of the
-- studio redeems the code, applied at checkout before any payment. The buyer is
-- emailed when the card is claimed.
--
-- THE ANON SURFACE BECOMES EXACTLY FOURTEEN. gift_card_begin joins the list: a
-- logged-out buyer has no session, so (as with xendit_webhook) the credential is
-- the call itself. It validates the amount against the studio presets and the
-- minimum, is rate-limited (10 begins/min/studio, 3/min/email), writes ONLY the
-- pending gift_cards + xendit_purchases rows, and returns ONLY the secret
-- ciphertext (useless without the env-only key, decrypted server-side) so the
-- server action can open the Xendit session — it echoes no stored data. The
-- ISSUE reuses the existing anon xendit_webhook: its success path is
-- xendit_activate_success_internal, which gains the gift arm. studio_by_slug
-- gains the gift presets + gift_enabled (no new surface).
--
-- Decision 103(f): when credit on the account covers the WHOLE total, the
-- purchase completes at once with no payment page and a payments row of
-- source 'credit'. dashboard_revenue and studio_revenue_between EXCLUDE a
-- source-credit payment, so gift money is counted once, at the sale. The credit
-- reader counts reservation and gift credit together; gift credit is applied
-- first. The reservation full-credit path already lives in reserve_free_first
-- (103e, credit_covered), so xendit_begin_reservation is NOT re-issued here.
--
-- member_bootstrap is NOT re-issued: its reservation_credit_cents already SUMS
-- every member_credits row (any reason, not voided), so it carries gift credit.
--
-- creates: gift_code(uuid), gift_card_begin(uuid, int, text, text, text, text, text, date), gift_card_redeem(text), gift_card_void(uuid, text), gift_card_resend(uuid)
-- re-issues: consume_reservation_credit(uuid, uuid, integer), xendit_fail_purchase_internal(uuid, text, text), xendit_activate_success_internal(uuid, text, text), xendit_begin_purchase(uuid, uuid), xendit_begin_product_purchase(uuid, uuid, integer), studio_by_slug(text), studio_revenue_between(uuid, timestamptz, timestamptz), dashboard_source_label(text), dashboard_revenue(uuid, date, date), sales_history(uuid, date, date, uuid, text), sales_totals(uuid, date, date, uuid, text)

-- ===========================================================================
-- 1. Settings: gift presets, the minimum, and the on/off switch.
-- ===========================================================================
alter table studio_settings
  add column if not exists gift_enabled   boolean not null default false,
  add column if not exists gift_presets   int[]   not null default array[100000, 250000, 500000],
  add column if not exists gift_min_cents  int     not null default 50000;

alter table studio_settings drop constraint if exists gift_min_nonneg;
alter table studio_settings add constraint gift_min_nonneg check (gift_min_cents >= 0);

comment on column studio_settings.gift_enabled is
  'Decision 110: the public gift-card page is on. Off by default.';
comment on column studio_settings.gift_presets is
  'Decision 110: the suggested gift amounts (minor units). Default PHP 1,000 / 2,500 / 5,000.';
comment on column studio_settings.gift_min_cents is
  'Decision 110: the smallest gift amount a buyer may choose (minor units). Default PHP 500.';

-- ===========================================================================
-- 2. payments.source — 'credit' for a full-credit (Decision 103(f)) payment.
--    Not new cash; the revenue readers exclude it.
-- ===========================================================================
alter table payments add column if not exists source text;
comment on column payments.source is
  'Decision 103(f): credit for a payment settled entirely from account credit '
  '(no processor). Excluded from revenue so gift money is counted once, at sale.';

-- ===========================================================================
-- 3. gift_cards — EXTEND the initial-schema stub (001) to the Decision 110
--    shape. The stub is unused (no code writes it) and empty, so the old NOT
--    NULL columns drop to nullable and the new ones are added. RLS is already
--    on and gift_staff (desk-up, FOR ALL) already covers staff read; a member
--    is not desk-up, so a member never reads the table (redeem is an RPC).
--    payments.gift_card_id already has its FK (001).
-- ===========================================================================
alter table gift_cards
  alter column code_hash            drop not null,
  alter column code_last4           drop not null,
  alter column initial_amount_cents drop not null,
  alter column balance_cents        drop not null,
  add column if not exists code text,
  add column if not exists amount_cents int,
  add column if not exists currency char(3),
  add column if not exists buyer_name text,
  add column if not exists buyer_email text,
  add column if not exists buyer_member_id uuid references members on delete set null,
  add column if not exists delivery_date date,
  add column if not exists issued_at timestamptz,
  add column if not exists redeemed_by_member_id uuid references members on delete set null,
  add column if not exists redeemed_at timestamptz,
  add column if not exists credit_id uuid references member_credits on delete set null,
  add column if not exists voided_at timestamptz,
  add column if not exists voided_by uuid references profiles on delete set null,
  add column if not exists void_reason text;

alter table gift_cards alter column status set default 'pending';
alter table gift_cards drop constraint if exists gift_cards_status_chk;
alter table gift_cards add constraint gift_cards_status_chk
  check (status in ('pending', 'active', 'redeemed', 'void'));
alter table gift_cards drop constraint if exists gift_cards_amount_pos;
alter table gift_cards add constraint gift_cards_amount_pos
  check (amount_cents is null or amount_cents > 0);

create unique index if not exists gift_cards_code_uniq
  on gift_cards (studio_id, code) where code is not null;
create index if not exists gift_cards_c110_rate_idx
  on gift_cards (studio_id, created_at);

grant select on gift_cards to authenticated;
grant all on gift_cards to service_role;

-- ===========================================================================
-- 4. xendit_purchases: a fourth target (a gift card), and a nullable member
--    (a logged-out gift buyer has none). Widen the one-target XOR.
-- ===========================================================================
alter table xendit_purchases alter column member_id drop not null;
alter table xendit_purchases
  add column if not exists gift_card_id uuid references gift_cards on delete set null;

alter table xendit_purchases drop constraint if exists xendit_purchases_one_target;
alter table xendit_purchases add constraint xendit_purchases_one_target
  check (num_nonnulls(plan_id, product_order_id, booking_id, gift_card_id) = 1);

-- ===========================================================================
-- 5. gift_code — mint a unique {STUDIO}-XXXX-XXXX code (no 0/O/1/I).
-- ===========================================================================
create or replace function gift_code(p_studio_id uuid)
returns text language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare
  v_prefix text; v_alpha text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_body text; v_code text; i int; v_try int := 0;
begin
  select upper(left(regexp_replace(coalesce(slug, ''), '[^a-zA-Z0-9]', '', 'g'), 4))
    into v_prefix from studios where id = p_studio_id;
  if coalesce(v_prefix, '') = '' then v_prefix := 'GIFT'; end if;
  loop
    v_body := '';
    for i in 1..8 loop
      v_body := v_body || substr(v_alpha, 1 + (get_byte(gen_random_bytes(1), 0) % length(v_alpha)), 1);
    end loop;
    v_code := v_prefix || '-' || substr(v_body, 1, 4) || '-' || substr(v_body, 5, 4);
    exit when not exists (select 1 from gift_cards where studio_id = p_studio_id and code = v_code);
    v_try := v_try + 1;
    if v_try > 30 then raise exception 'could not mint a gift code'; end if;
  end loop;
  return v_code;
end $$;
revoke execute on function gift_code(uuid) from public, anon, authenticated;
grant  execute on function gift_code(uuid) to service_role;

-- ===========================================================================
-- 6. consume_reservation_credit — re-issued (from 20260833430000) so GIFT credit
--    is applied before reservation credit (then oldest first).
-- ===========================================================================
create or replace function consume_reservation_credit(p_studio_id uuid, p_member_id uuid, p_amount_cents int)
returns int language plpgsql security definer set search_path = public as $$
declare r record; v_left int := greatest(coalesce(p_amount_cents, 0), 0); v_take int; v_done int := 0;
begin
  for r in
    select id, (amount_cents - used_cents) as remaining
      from member_credits
     where studio_id = p_studio_id and member_id = p_member_id and voided_at is null
       and amount_cents > used_cents
     order by (reason = 'gift_credit') desc, created_at, id
     for update
  loop
    exit when v_left <= 0;
    v_take := least(r.remaining, v_left);
    update member_credits set used_cents = used_cents + v_take where id = r.id;
    v_left := v_left - v_take;
    v_done := v_done + v_take;
  end loop;
  return v_done;
end $$;
revoke execute on function consume_reservation_credit(uuid, uuid, int) from public, anon, authenticated;
grant  execute on function consume_reservation_credit(uuid, uuid, int) to service_role;

-- ===========================================================================
-- 7. xendit_fail_purchase_internal — re-issued (from 20260833500000) with a gift
--    branch: a failed/expired gift purchase voids the pending card.
-- ===========================================================================
create or replace function xendit_fail_purchase_internal(p_purchase_id uuid, p_status text, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare p xendit_purchases%rowtype; o product_orders%rowtype; prod products%rowtype; n int;
begin
  select * into p from xendit_purchases where id = p_purchase_id for update;
  if p.id is null or p.status in ('succeeded') then return; end if;

  update xendit_purchases
     set status = p_status, failure_reason = p_reason, completed_at = now(), updated_at = now()
   where id = p_purchase_id and status = 'pending';

  if p.booking_id is not null then
    -- Decision 103(e): release the held seat at once rather than waiting for the
    -- sweep. No email (the class page tells the member "Your spot wasn't held.").
    if exists (select 1 from bookings b where b.id = p.booking_id and b.status = 'pending_payment') then
      perform cancel_booking(p.booking_id);
    end if;
    return;
  elsif p.gift_card_id is not null then
    -- Decision 110: the gift was never issued (payment failed). Void the pending
    -- card so a later card is minted fresh; nobody is emailed.
    update gift_cards set status = 'void', voided_at = now(), void_reason = coalesce(p_reason, 'payment failed')
     where id = p.gift_card_id and status = 'pending';
    return;
  elsif p.product_order_id is not null then
    select * into o from product_orders where id = p.product_order_id for update;
    update product_orders set status = 'cancelled'
     where id = p.product_order_id and status in ('reserved', 'pending');
    get diagnostics n = row_count;
    if n = 1 then
      select * into prod from products where id = o.product_id for update;
      if prod.track_stock then
        update products set stock = stock + o.quantity where id = prod.id;
        insert into stock_movements (studio_id, product_id, delta, reason, order_id)
        values (p.studio_id, prod.id, o.quantity, 'release', o.id);
      end if;
    end if;
    perform queue_notification(
      p.studio_id, p.member_id, 'xendit_purchase_failed',
      jsonb_build_object('plan_name', (select name from products where id = o.product_id)),
      'xendit_failed:' || p_purchase_id::text);
  else
    perform queue_notification(
      p.studio_id, p.member_id, 'xendit_purchase_failed',
      jsonb_build_object('plan_name', (select name from membership_plans where id = p.plan_id)),
      'xendit_failed:' || p_purchase_id::text);
  end if;
end $$;
revoke execute on function xendit_fail_purchase_internal(uuid, text, text) from public, anon, authenticated;
grant  execute on function xendit_fail_purchase_internal(uuid, text, text) to service_role;

-- ===========================================================================
-- 8. xendit_activate_success_internal — DROP+recreate (from 20260833500000)
--    with: (a) a GIFT branch that issues the card, mints the code, emails the
--    buyer and schedules the recipient; (b) a p_source arg so a Decision 103(f)
--    full-credit completion writes a 'credit' payment (provider manual, no
--    reference); (c) ONE credit-consume at the end (covers plan, product and the
--    gift-is-never-paid-with-credit no-op). The webhook's 2-arg call resolves to
--    p_source default 'xendit'.
-- ===========================================================================
drop function if exists xendit_activate_success_internal(uuid, text);
create function xendit_activate_success_internal(p_purchase_id uuid, p_payment_id text, p_source text default 'xendit')
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
    update gift_cards set status = 'active', code = v_code, issued_at = now()
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
        'redeem_url', member_portal_url(p.studio_id, '/account/redeem'),
        'studio_name', (select name from studios where id = p.studio_id)),
      'gift_card_sent:' || gc.id::text, v_send);

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
                            status, provider, source, reference, description, paid_at)
      select p.studio_id, p.member_id, v_group, p.amount_cents, p.currency, 'succeeded', v_prov,
             v_src, v_ref, mp.name, now()
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
                          status, provider, source, reference, description, paid_at)
    select p.studio_id, p.member_id, v_ms, p.amount_cents, p.currency, 'succeeded', v_prov,
           v_src, v_ref, mp.name, now()
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
revoke execute on function xendit_activate_success_internal(uuid, text, text) from public, anon, authenticated;
grant  execute on function xendit_activate_success_internal(uuid, text, text) to service_role;

-- ===========================================================================
-- 9. xendit_begin_purchase — re-issued (from 20260833430000) with Decision 103(f)
--    full-credit: when credit covers the whole price, complete now (no Xendit)
--    through xendit_activate_success_internal(..., 'credit') and return due 0.
-- ===========================================================================
drop function if exists xendit_begin_purchase(uuid, uuid);
create function xendit_begin_purchase(p_studio_id uuid, p_plan_id uuid)
returns table(purchase_id uuid, amount_cents int, currency char(3), credit_applied_cents int)
language plpgsql security definer set search_path = public as $$
declare v_member uuid; mp membership_plans%rowtype; v_id uuid; v_renew uuid;
        v_avail int; v_applied int; v_due int;
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
    raise exception 'The intro offer is for first-timers — you''ve had yours. Choose a pack or membership instead.'
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

  v_avail := reservation_credit_available(p_studio_id, v_member);

  -- Decision 103(f): credit covers the whole total. No Xendit, no floor; complete
  -- now and return due 0 so the app lands straight on the success screen.
  if v_avail >= mp.price_cents then
    insert into xendit_purchases (studio_id, member_id, plan_id, amount_cents, currency,
                                  renews_membership_id, credit_applied_cents)
    values (p_studio_id, v_member, p_plan_id, mp.price_cents, mp.currency, v_renew, mp.price_cents)
    returning id into v_id;
    perform xendit_activate_success_internal(v_id, null, 'credit');
    return query select v_id, 0, mp.currency, mp.price_cents;
    return;
  end if;

  -- Partial (or no) credit: cap so the online payment is >= the processor minimum.
  v_applied := least(greatest(v_avail, 0), greatest(mp.price_cents - 2000, 0));
  v_due := mp.price_cents - v_applied;

  insert into xendit_purchases (studio_id, member_id, plan_id, amount_cents, currency,
                                renews_membership_id, credit_applied_cents)
  values (p_studio_id, v_member, p_plan_id, v_due, mp.currency, v_renew, v_applied)
  returning id into v_id;

  return query select v_id, v_due, mp.currency, v_applied;
end $$;
revoke execute on function xendit_begin_purchase(uuid, uuid) from public, anon;
grant  execute on function xendit_begin_purchase(uuid, uuid) to authenticated, service_role;

-- ===========================================================================
-- 10. xendit_begin_product_purchase — re-issued (from 20260833430000) with the
--     same Decision 103(f) full-credit path.
-- ===========================================================================
drop function if exists xendit_begin_product_purchase(uuid, uuid, integer);
create function xendit_begin_product_purchase(p_studio_id uuid, p_product_id uuid, p_quantity int)
returns table(purchase_id uuid, amount_cents int, currency char(3), credit_applied_cents int)
language plpgsql security definer set search_path = public as $$
declare v_member uuid; prod products%rowtype; v_order uuid; v_id uuid; v_amount int;
        v_avail int; v_applied int; v_due int;
begin
  select id into v_member from members where studio_id = p_studio_id and user_id = auth.uid();
  if v_member is null then
    raise exception 'you are not a member of that studio' using errcode = 'PT403';
  end if;
  if not exists (select 1 from studio_payment_providers where studio_id = p_studio_id and provider = 'xendit') then
    raise exception 'this studio is not set up to take online payments' using errcode = 'PT409';
  end if;

  select * into prod from products where id = p_product_id and studio_id = p_studio_id for update;
  if prod.id is null then
    raise exception 'that product is not on sale' using errcode = 'PT404';
  end if;
  if prod.status <> 'active' then
    raise exception 'That product is no longer on sale.' using errcode = 'PT409';
  end if;
  if p_quantity is null or p_quantity < 1 then
    raise exception 'how many?' using errcode = 'PT400';
  end if;
  if prod.track_stock and prod.stock < p_quantity then
    raise exception 'Only % left.', prod.stock using errcode = 'PT409';
  end if;

  v_amount := prod.price_cents * p_quantity;

  insert into product_orders (studio_id, product_id, member_id, quantity, unit_price_cents,
                              currency, status, channel, created_by)
  values (p_studio_id, p_product_id, v_member, p_quantity, prod.price_cents,
          prod.currency, 'reserved', 'app', auth.uid())
  returning id into v_order;

  if prod.track_stock then
    update products set stock = stock - p_quantity where id = p_product_id;
    insert into stock_movements (studio_id, product_id, delta, reason, order_id, created_by)
    values (p_studio_id, p_product_id, -p_quantity, 'reserve', v_order, auth.uid());
  end if;

  v_avail := reservation_credit_available(p_studio_id, v_member);

  if v_avail >= v_amount then
    insert into xendit_purchases (studio_id, member_id, product_order_id, amount_cents, currency, credit_applied_cents)
    values (p_studio_id, v_member, v_order, v_amount, prod.currency, v_amount)
    returning id into v_id;
    perform xendit_activate_success_internal(v_id, null, 'credit');
    return query select v_id, 0, prod.currency, v_amount;
    return;
  end if;

  v_applied := least(greatest(v_avail, 0), greatest(v_amount - 2000, 0));
  v_due := v_amount - v_applied;

  insert into xendit_purchases (studio_id, member_id, product_order_id, amount_cents, currency, credit_applied_cents)
  values (p_studio_id, v_member, v_order, v_due, prod.currency, v_applied)
  returning id into v_id;

  return query select v_id, v_due, prod.currency, v_applied;
end $$;
revoke execute on function xendit_begin_product_purchase(uuid, uuid, integer) from public, anon;
grant  execute on function xendit_begin_product_purchase(uuid, uuid, integer) to authenticated, service_role;

-- ===========================================================================
-- 11. gift_card_begin — ANON. The fourteenth pre-login surface. Validates the
--     amount/presets/min, rate-limits, writes the pending card + purchase, and
--     returns ONLY the secret ciphertext (the xendit_checkout_context pattern).
-- ===========================================================================
create or replace function gift_card_begin(
  p_studio_id uuid, p_amount_cents int,
  p_buyer_name text default null, p_buyer_email text default null,
  p_recipient_name text default null, p_recipient_email text default null,
  p_message text default null, p_delivery_date date default null
) returns table(purchase_id uuid, amount_cents int, currency char(3),
                secret_key_ciphertext text, test_mode boolean)
language plpgsql security definer set search_path = public as $$
declare ss studio_settings%rowtype; v_ccy char(3); v_today date; v_tz text;
        v_gift uuid; v_id uuid; v_buyer text;
begin
  select * into ss from studio_settings where studio_id = p_studio_id;
  if ss.studio_id is null or not coalesce(ss.gift_enabled, false) then
    raise exception 'gift cards are not available' using errcode = 'PT404';
  end if;
  if not exists (select 1 from studio_payment_providers where studio_id = p_studio_id and provider = 'xendit') then
    raise exception 'this studio is not set up to take online payments' using errcode = 'PT409';
  end if;

  if p_amount_cents is null or p_amount_cents < coalesce(ss.gift_min_cents, 50000)
     or p_amount_cents > 100000000 then
    raise exception 'that amount is not allowed' using errcode = 'PT422';
  end if;
  if coalesce(nullif(btrim(p_buyer_email), ''), '') not like '%@%'
     or coalesce(nullif(btrim(p_recipient_email), ''), '') not like '%@%' then
    raise exception 'a buyer and a recipient email are needed' using errcode = 'PT422';
  end if;
  if length(coalesce(p_message, '')) > 200 then
    raise exception 'that message is too long' using errcode = 'PT422';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  v_today := (now() at time zone coalesce(v_tz, 'UTC'))::date;
  if p_delivery_date is not null and (p_delivery_date < v_today or p_delivery_date > v_today + 90) then
    raise exception 'that delivery date is out of range' using errcode = 'PT422';
  end if;

  v_buyer := lower(btrim(p_buyer_email));
  if (select count(*) from gift_cards where studio_id = p_studio_id
        and created_at > now() - interval '1 minute') >= 10 then
    raise exception 'too many right now, try again in a minute' using errcode = 'PT429';
  end if;
  if (select count(*) from gift_cards where studio_id = p_studio_id
        and lower(btrim(buyer_email)) = v_buyer
        and created_at > now() - interval '1 minute') >= 3 then
    raise exception 'too many right now, try again in a minute' using errcode = 'PT429';
  end if;

  select s.currency into v_ccy from studios s where s.id = p_studio_id;

  insert into gift_cards (studio_id, amount_cents, currency, status,
                          buyer_name, buyer_email, recipient_name, recipient_email,
                          message, delivery_date)
  values (p_studio_id, p_amount_cents, v_ccy, 'pending',
          nullif(btrim(p_buyer_name), ''), v_buyer,
          nullif(btrim(p_recipient_name), ''), lower(btrim(p_recipient_email)),
          nullif(btrim(p_message), ''), p_delivery_date)
  returning id into v_gift;

  insert into xendit_purchases (studio_id, member_id, gift_card_id, amount_cents, currency)
  values (p_studio_id, null, v_gift, p_amount_cents, v_ccy)
  returning id into v_id;

  return query
    select v_id, p_amount_cents, v_ccy, spp.secret_key_ciphertext, spp.test_mode
      from studio_payment_providers spp
     where spp.studio_id = p_studio_id and spp.provider = 'xendit';
end $$;
revoke execute on function gift_card_begin(uuid, int, text, text, text, text, text, date) from public;
grant  execute on function gift_card_begin(uuid, int, text, text, text, text, text, date) to anon, authenticated, service_role;

-- ===========================================================================
-- 12. gift_card_redeem — a member of the card's studio redeems a code into gift
--     credit. The full amount becomes a member_credits 'gift_credit' row.
-- ===========================================================================
create or replace function gift_card_redeem(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare gc gift_cards%rowtype; v_member members%rowtype; v_norm text; v_credit uuid;
begin
  v_norm := upper(regexp_replace(coalesce(p_code, ''), '[^a-zA-Z0-9]', '', 'g'));
  if v_norm = '' then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;

  select * into gc from gift_cards
   where code is not null
     and upper(regexp_replace(code, '[^a-zA-Z0-9]', '', 'g')) = v_norm
   limit 1;
  if gc.id is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;

  select * into v_member from members where studio_id = gc.studio_id and user_id = auth.uid();
  if v_member.id is null then
    raise exception 'you are not a member of that studio' using errcode = 'PT403';
  end if;

  if gc.status = 'void' then return jsonb_build_object('ok', false, 'reason', 'void'); end if;
  if gc.status = 'redeemed' then return jsonb_build_object('ok', false, 'reason', 'already_redeemed'); end if;
  if gc.status <> 'active' then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;

  insert into member_credits (studio_id, member_id, amount_cents, currency, reason)
  values (gc.studio_id, v_member.id, gc.amount_cents, gc.currency, 'gift_credit')
  returning id into v_credit;

  update gift_cards
     set status = 'redeemed', redeemed_by_member_id = v_member.id, redeemed_at = now(), credit_id = v_credit
   where id = gc.id;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (gc.studio_id, auth.uid(), 'gift_card.redeemed', 'gift_cards', gc.id,
          jsonb_build_object('amount_cents', gc.amount_cents, 'member_id', v_member.id));

  if nullif(btrim(coalesce(gc.buyer_email, '')), '') is not null then
    perform queue_notification(gc.studio_id, gc.buyer_member_id, 'gift_card_redeemed',
      jsonb_build_object('to_email', gc.buyer_email, 'buyer_name', coalesce(gc.buyer_name, 'there'),
        'recipient_name', coalesce(gc.recipient_name, 'your friend'),
        'amount', fmt_money(gc.amount_cents, gc.currency),
        'studio_name', (select name from studios where id = gc.studio_id)),
      'gift_card_redeemed:' || gc.id::text);
  end if;

  return jsonb_build_object('ok', true, 'amount_cents', gc.amount_cents,
    'amount', fmt_money(gc.amount_cents, gc.currency));
end $$;
revoke execute on function gift_card_redeem(text) from public, anon;
grant  execute on function gift_card_redeem(text) to authenticated, service_role;

-- ===========================================================================
-- 13. gift_card_void / gift_card_resend — manager-up. Voiding an unredeemed card
--     stops it; resending re-queues the recipient email for an active card.
-- ===========================================================================
create or replace function gift_card_void(p_gift_card_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare gc gift_cards%rowtype;
begin
  select * into gc from gift_cards where id = p_gift_card_id;
  if gc.id is null then raise exception 'no such gift card' using errcode = 'PT404'; end if;
  if not is_manager_up(gc.studio_id) then
    raise exception 'voiding a gift card is the owner''s or a manager''s to do' using errcode = 'PT403';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'a reason is needed' using errcode = 'PT400';
  end if;
  if gc.status = 'redeemed' then
    raise exception 'that card is already claimed' using errcode = 'PT409';
  end if;
  if gc.status = 'void' then
    raise exception 'that card is already void' using errcode = 'PT409';
  end if;
  update gift_cards set status = 'void', voided_at = now(), voided_by = auth.uid(), void_reason = p_reason
   where id = gc.id;
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (gc.studio_id, auth.uid(), 'gift_card.voided', 'gift_cards', gc.id,
          jsonb_build_object('reason', p_reason));
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function gift_card_void(uuid, text) from public, anon;
grant  execute on function gift_card_void(uuid, text) to authenticated, service_role;

create or replace function gift_card_resend(p_gift_card_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare gc gift_cards%rowtype;
begin
  select * into gc from gift_cards where id = p_gift_card_id;
  if gc.id is null then raise exception 'no such gift card' using errcode = 'PT404'; end if;
  if not is_manager_up(gc.studio_id) then
    raise exception 'resending a gift card is the owner''s or a manager''s to do' using errcode = 'PT403';
  end if;
  if gc.status <> 'active' or gc.code is null then
    raise exception 'that card cannot be resent' using errcode = 'PT409';
  end if;
  perform queue_notification(gc.studio_id, gc.redeemed_by_member_id, 'gift_card_sent',
    jsonb_build_object('to_email', gc.recipient_email,
      'recipient_name', coalesce(gc.recipient_name, 'there'),
      'buyer_name', coalesce(gc.buyer_name, 'A friend'),
      'code', gc.code, 'amount', fmt_money(gc.amount_cents, gc.currency),
      'message', coalesce(gc.message, ''),
      'redeem_url', member_portal_url(gc.studio_id, '/account/redeem'),
      'studio_name', (select name from studios where id = gc.studio_id)),
    'gift_card_resend:' || gc.id::text || ':' || floor(extract(epoch from now()))::text);
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function gift_card_resend(uuid) from public, anon;
grant  execute on function gift_card_resend(uuid) to authenticated, service_role;

-- ===========================================================================
-- 14. studio_by_slug — re-issued (from 20260832380000) with the gift presets +
--     gift_enabled + gift_min for the public /gift page. Stays the SAME anon
--     surface (drop+recreate re-grants anon).
-- ===========================================================================
drop function if exists studio_by_slug(text);
create function studio_by_slug(p_slug text)
 returns table(id uuid, name text, slug text, timezone text, currency text, logo_url text,
   theme_preset theme_preset, accent_color text, login_image_url text,
   login_image_focus_x smallint, login_image_focus_y smallint,
   free_first_class_enabled boolean, login_tagline text, install_welcome text, time_format text,
   android_package text, android_sha256_fingerprints text, ios_team_id text, ios_bundle_id text,
   gift_enabled boolean, gift_presets int[], gift_min_cents int)
 language sql stable security definer set search_path to 'public' as $function$
  select s.id, s.name, s.slug, s.timezone, s.currency,
         s.logo_url, s.theme_preset, s.accent_color, s.login_image_url,
         s.login_image_focus_x, s.login_image_focus_y,
         coalesce(ss.free_first_class_enabled, false),
         s.login_tagline, s.install_welcome,
         coalesce(ss.time_format, '24h'),
         s.android_package, s.android_sha256_fingerprints, s.ios_team_id, s.ios_bundle_id,
         coalesce(ss.gift_enabled, false),
         coalesce(ss.gift_presets, array[100000, 250000, 500000]),
         coalesce(ss.gift_min_cents, 50000)
    from studios s
    left join studio_settings ss on ss.studio_id = s.id
   where s.slug = p_slug and s.status = 'active'
$function$;
revoke execute on function studio_by_slug(text) from public;
grant  execute on function studio_by_slug(text) to anon, authenticated, service_role;

-- ===========================================================================
-- 15. studio_revenue_between — re-issued (from 20260831010000) EXCLUDING a
--     source-credit payment (Decision 103(f): gift money counted once, at sale).
-- ===========================================================================
create or replace function studio_revenue_between(
  p_studio_id uuid, p_from timestamptz, p_to timestamptz)
returns bigint
language sql stable security definer set search_path = public as $$
  select coalesce(sum(p.amount_cents), 0)::bigint
    from payments p
   where p.studio_id = p_studio_id
     and p.status in ('succeeded', 'partially_refunded')
     and coalesce(p.source, '') <> 'credit'
     and coalesce(p.paid_at, p.created_at) >= p_from
     and coalesce(p.paid_at, p.created_at) <  p_to
$$;

-- ===========================================================================
-- 16. dashboard_source_label — re-issued (from 20260833500000) with a gift label.
-- ===========================================================================
create or replace function dashboard_source_label(p_src text) returns text
language sql immutable as $$
  select case p_src
    when 'membership' then 'Memberships'
    when 'pack'       then 'Class packs'
    when 'drop_in'    then 'Drop-ins'
    when 'private'    then 'Private sessions'
    when 'trial'      then 'Trials'
    when 'merch'      then 'Merchandise'
    when 'reservation' then 'Reservation fees'
    when 'gift'       then 'Gift cards'
    else 'Other' end
$$;

-- ===========================================================================
-- 17. dashboard_revenue — re-issued (from 20260833500000) EXCLUDING source-credit
--     payments everywhere, and bucketing a gift sale as 'gift'.
-- ===========================================================================
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
   where p.studio_id = p_studio_id and p.status in ('succeeded','partially_refunded')
     and coalesce(p.source, '') <> 'credit';

  select coalesce(sum(r.amount_cents),0)::bigint into v_refunds
    from refunds r join payments p on p.id = r.payment_id
   where p.studio_id = p_studio_id
     and r.created_at >= v_f0 and r.created_at < v_t1;

  select coalesce(jsonb_agg(jsonb_build_object('date', d.day, 'cents', coalesce(x.cents,0))
                            order by d.day), '[]'::jsonb)
    into v_series
    from generate_series(p_from, p_to, interval '1 day') g(day_ts)
    cross join lateral (select g.day_ts::date as day) d
    left join lateral (
      select coalesce(sum(p.amount_cents),0)::bigint as cents
        from payments p
       where p.studio_id = p_studio_id and p.status in ('succeeded','partially_refunded')
         and coalesce(p.source, '') <> 'credit'
         and (coalesce(p.paid_at, p.created_at) at time zone v_tz)::date = d.day
    ) x on true;

  with classified as (
    select p.amount_cents,
           case
             when p.gift_card_id is not null then 'gift'
             when p.product_order_id is not null then 'merch'
             when p.kind = 'reservation_fee' and coalesce(p.method, '') <> 'reservation_credit' then 'reservation'
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
       and coalesce(p.source, '') <> 'credit'
       and coalesce(p.paid_at, p.created_at) >= v_f0
       and coalesce(p.paid_at, p.created_at) <  v_t1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'source', src, 'label', dashboard_source_label(src), 'cents', cents,
           'pct', case when v_total = 0 then 0 else round(100.0 * cents / v_total) end)
           order by cents desc), '[]'::jsonb)
    into v_sources
    from (select src, sum(amount_cents)::bigint as cents from classified group by src) s;

  select jsonb_build_object(
      'bookings', (select count(*) from bookings b
                    where b.studio_id = p_studio_id and b.status <> 'waitlisted'
                      and b.booked_at >= v_f0 and b.booked_at < v_t1),
      'memberships_sold', (select count(*) from memberships ms
                    where ms.studio_id = p_studio_id
                      and ms.created_at >= v_f0 and ms.created_at < v_t1
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

-- ===========================================================================
-- 18. sales_history — re-issued (from 20260833500000) with a GIFT sales arm.
-- ===========================================================================
create or replace function sales_history(
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
         false as is_renewal
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
         false as is_renewal
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

  order by bought_on desc;
end $$;
revoke all on function sales_history(uuid, date, date, uuid, text) from public, anon;
grant execute on function sales_history(uuid, date, date, uuid, text) to authenticated, service_role;

-- ===========================================================================
-- 19. sales_totals — re-issued (from 20260833540000) with two gift lines:
--     'Gift cards sold' (sale payments) and 'Gift credit redeemed' (source credit).
-- ===========================================================================
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

  return jsonb_build_object(
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
-- 20. The three gift templates (80a frame). The fourth "template" — a credit
--     line in checkout confirmations — is the existing CreditApplied checkout UI
--     (Decision 348): gift credit flows through the same reservation_credit_cents.
-- ===========================================================================
insert into notification_templates (key, subject, text_body, html_body, note) values
('gift_card_receipt',
 'Your gift card for {studio_name}',
 E'Hi {buyer_name},\n\nThank you. Your {amount} gift card for {studio_name} is on its way to {recipient_name}. The code is {code}.\n\nThey redeem it in their {studio_name} account.',
 '<p>Hi {buyer_name},</p>
<p>Thank you. Your <strong>{amount}</strong> gift card for {studio_name} is on its way to {recipient_name}.</p>
<p>The code is <strong>{code}</strong>.</p>
<p>{studio_name}</p>',
 'Decision 110: the buyer''s receipt, with the code, on payment.'),
('gift_card_sent',
 'A gift card for {studio_name}',
 E'Hi {recipient_name},\n\n{buyer_name} has sent you a {amount} gift card for {studio_name}.\n\n"{message}"\n\nYour code is {code}. Redeem it here: {redeem_url}',
 '<p>Hi {recipient_name},</p>
<p>{buyer_name} has sent you a <strong>{amount}</strong> gift card for {studio_name}.</p>
<p style="font-style:italic;color:#57534e">{message}</p>
<p>Your code is <strong>{code}</strong>.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{redeem_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Redeem your gift card</a></td></tr></table>
<p>{studio_name}</p>',
 'Decision 110: the recipient''s card, on the delivery date.'),
('gift_card_redeemed',
 'Your gift card was claimed',
 E'Hi {buyer_name},\n\n{recipient_name} has claimed the {amount} gift card you sent for {studio_name}. Thank you.',
 '<p>Hi {buyer_name},</p>
<p>{recipient_name} has claimed the <strong>{amount}</strong> gift card you sent for {studio_name}. Thank you.</p>
<p>{studio_name}</p>',
 'Decision 110: the buyer is told when the card is claimed.')
on conflict (key) do nothing;

-- ===========================================================================
-- 21. Anon stays EXACTLY FOURTEEN (the thirteen + gift_card_begin).
-- ===========================================================================
do $mig$ declare n int; begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 14 then raise exception 'anon surface is % (want 14)', n; end if;
end $mig$;
