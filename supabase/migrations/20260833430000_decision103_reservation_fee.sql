-- Decision 103 — reservation fee for the free class.
--
-- A studio may charge a small reservation fee when a first-timer books their
-- free class. The fee is not a charge for the class: show up and it comes back
-- as account credit, don't show up or cancel late and the studio keeps it. Off
-- by default; touches only free first class bookings.
--
-- The seat is held as pending_payment (the existing drop-in window), Xendit
-- takes the fee, and the webhook completes the comp free seat (book_first_free_run).
-- An abandoned hold is swept by the existing sweep_unpaid_dropins. The fee money
-- comes back as a cash-value account credit (member_credits), applied automatically
-- at the next plan/pack/merch checkout. Existing free bookings get a one-off
-- "pay or lose your spot" flow when the studio sets an applies-from date.
--
-- A reservation credit never reduces an online payment below the processor
-- minimum (2000 minor units); any remainder stays on the account. This keeps a
-- single Xendit session positive and avoids a zero-amount checkout.
--
-- creates: reservation_credit_available(uuid, uuid), consume_reservation_credit(uuid, uuid, integer), write_reservation_credit(uuid), reserve_free_first(uuid), xendit_begin_reservation(uuid, uuid), book_first_free_run(uuid), tg_reservation_credit(), member_reservation_dues(uuid), sweep_free_reservation_dues()
-- re-issues: xendit_activate_success_internal(uuid, text), xendit_begin_purchase(uuid, uuid), xendit_begin_product_purchase(uuid, uuid, integer), xendit_fail_purchase_internal(uuid, text, text), record_refund(uuid, integer, text, boolean), member_wallet(uuid), member_plan_overview(uuid), queue_booking_notifications(uuid), template_sample_context(uuid, text, text), member_bootstrap(text)

-- ===========================================================================
-- 1. Settings.
-- ===========================================================================
alter table studio_settings
  add column if not exists free_first_reservation_fee_cents int not null default 0,
  add column if not exists free_first_reservation_from date;

alter table studio_settings drop constraint if exists free_first_reservation_fee_nonneg;
alter table studio_settings add constraint free_first_reservation_fee_nonneg
  check (free_first_reservation_fee_cents >= 0);

comment on column studio_settings.free_first_reservation_fee_cents is
  'Decision 103: the reservation fee charged when a first-timer books their free '
  'class, in minor units. 0 = off. Comes back as account credit on attendance.';
comment on column studio_settings.free_first_reservation_from is
  'Decision 103: when set, existing free bookings for classes on or after this '
  'date are asked to pay the reservation fee or be released. Null = new only.';

-- ===========================================================================
-- 2. payments.kind — a new column; a reservation fee carries kind='reservation_fee'.
-- ===========================================================================
alter table payments add column if not exists kind text;
comment on column payments.kind is
  'Decision 103: payment kind. reservation_fee for a free-class reservation fee; '
  'null for ordinary plan/drop-in/product/group payments.';

-- ===========================================================================
-- 3. xendit_purchases — a third target: a held free-first booking. And the
--    credit applied to a plan/product checkout (consumed on activation).
-- ===========================================================================
alter table xendit_purchases
  add column if not exists booking_id uuid references bookings on delete set null,
  add column if not exists credit_applied_cents int not null default 0;

-- The 20260832320000 check (xendit_purchase_one_target) named the plan/product
-- XOR; drop any such CHECK and widen to exactly one of the three targets.
do $$
declare r record;
begin
  for r in
    select conname from pg_constraint
     where conrelid = 'xendit_purchases'::regclass and contype = 'c'
       and pg_get_constraintdef(oid) ilike '%plan_id%product_order_id%'
  loop
    execute format('alter table xendit_purchases drop constraint %I', r.conname);
  end loop;
end $$;
alter table xendit_purchases drop constraint if exists xendit_purchases_one_target;
alter table xendit_purchases add constraint xendit_purchases_one_target
  check (num_nonnulls(plan_id, product_order_id, booking_id) = 1);

-- ===========================================================================
-- 4. member_credits — a cash-value account credit store (credit_ledger is class
--    credits only). Unused = amount_cents - used_cents while voided_at is null.
-- ===========================================================================
create table if not exists member_credits (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid not null references studios on delete cascade,
  member_id     uuid not null references members on delete cascade,
  amount_cents  int  not null check (amount_cents > 0),
  used_cents    int  not null default 0 check (used_cents >= 0 and used_cents <= amount_cents),
  currency      char(3) not null,
  reason        text not null,
  payment_id    uuid references payments on delete set null,
  booking_id    uuid references bookings on delete set null,
  voided_at     timestamptz,
  created_at    timestamptz not null default now()
);
create index if not exists member_credits_member_idx
  on member_credits (studio_id, member_id, created_at)
  where voided_at is null;
-- One reservation credit per booking (idempotency for write_reservation_credit).
create unique index if not exists member_credits_booking_reason_uniq
  on member_credits (booking_id, reason) where booking_id is not null;

alter table member_credits enable row level security;

drop policy if exists member_credits_self_read on member_credits;
create policy member_credits_self_read on member_credits for select to authenticated
  using (exists (select 1 from members m
                  where m.id = member_credits.member_id and m.user_id = auth.uid()));

drop policy if exists member_credits_staff_read on member_credits;
create policy member_credits_staff_read on member_credits for select to authenticated
  using (coalesce(is_desk_up(studio_id), false));

grant select on member_credits to authenticated;
grant all on member_credits to service_role;

-- ===========================================================================
-- 5. Credit helpers.
-- ===========================================================================
create or replace function reservation_credit_available(p_studio_id uuid, p_member_id uuid)
returns int language sql stable security definer set search_path = public as $$
  select coalesce(sum(amount_cents - used_cents), 0)::int
    from member_credits
   where studio_id = p_studio_id and member_id = p_member_id and voided_at is null;
$$;
revoke execute on function reservation_credit_available(uuid, uuid) from public, anon, authenticated;
grant  execute on function reservation_credit_available(uuid, uuid) to service_role;

-- Consume up to p_amount from the member's unused credits, oldest first. Bounded
-- per credit (used_cents <= amount_cents) so a race can never over-consume one.
create or replace function consume_reservation_credit(p_studio_id uuid, p_member_id uuid, p_amount_cents int)
returns int language plpgsql security definer set search_path = public as $$
declare r record; v_left int := greatest(coalesce(p_amount_cents, 0), 0); v_take int; v_done int := 0;
begin
  for r in
    select id, (amount_cents - used_cents) as remaining
      from member_credits
     where studio_id = p_studio_id and member_id = p_member_id and voided_at is null
       and amount_cents > used_cents
     order by created_at, id
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

-- Write the attendance/on-time-cancel credit for a reservation-paid free booking.
-- Idempotent on (booking_id, reason).
create or replace function write_reservation_credit(p_booking_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype; pay payments%rowtype;
begin
  select * into b from bookings where id = p_booking_id;
  if not found then return; end if;
  if exists (select 1 from member_credits
              where booking_id = p_booking_id and reason = 'reservation_credit') then
    return;
  end if;
  select * into pay from payments
   where booking_id = p_booking_id and kind = 'reservation_fee'
     and status in ('succeeded', 'partially_refunded')
   order by created_at limit 1;
  if not found then return; end if;
  insert into member_credits (studio_id, member_id, amount_cents, currency, reason,
                              payment_id, booking_id)
  values (pay.studio_id, b.member_id, pay.amount_cents - coalesce(pay.refunded_cents, 0),
          pay.currency, 'reservation_credit', pay.id, p_booking_id);
end $$;
revoke execute on function write_reservation_credit(uuid) from public, anon, authenticated;
grant  execute on function write_reservation_credit(uuid) to service_role;

-- ===========================================================================
-- 6. reserve_free_first — hold a free-first seat as pending_payment, so the fee
--    can be taken before the comp seat is completed. Mirrors book_first_free's
--    gates; writes NO guest_passes row (that is the webhook's job, so an
--    abandoned hold swept by sweep_unpaid_dropins consumes no free class).
-- ===========================================================================
create or replace function reserve_free_first(p_occurrence_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare
  v_occ class_occurrences%rowtype; v_member members%rowtype; v_set studio_settings%rowtype;
  v_ser class_series%rowtype; v_cfg_tier guarantee_tier; v_elig jsonb; v_free int; v_booking uuid;
begin
  select * into v_occ from class_occurrences where id = p_occurrence_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;

  select * into v_member from members where studio_id = v_occ.studio_id and user_id = auth.uid();
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_authorised'); end if;

  select * into v_set from studio_settings where studio_id = v_occ.studio_id;
  if coalesce(v_set.free_first_reservation_fee_cents, 0) <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_reservation_fee');
  end if;

  v_elig := free_first_eligibility(v_occ.studio_id, v_member.id);
  if not (v_elig ->> 'ok')::boolean then return v_elig; end if;

  if v_occ.status <> 'scheduled' then return jsonb_build_object('ok', false, 'reason', 'class_not_bookable'); end if;
  if v_occ.starts_at <= now() then return jsonb_build_object('ok', false, 'reason', 'class_in_past'); end if;
  if not month_published(v_occ.studio_id, v_occ.starts_at) then
    return jsonb_build_object('ok', false, 'reason', 'month_not_published'); end if;
  if studio_hides_unstaffed(v_occ.studio_id) and v_occ.staffing <> 'assigned' then
    return jsonb_build_object('ok', false, 'reason', 'not_staffed_yet'); end if;
  if v_occ.hidden_from_members then
    return jsonb_build_object('ok', false, 'reason', 'class_hidden'); end if;
  if v_occ.starts_at > now() + make_interval(days => coalesce(v_set.booking_window_days, 30)) then
    return jsonb_build_object('ok', false, 'reason', 'outside_booking_window'); end if;
  if v_occ.starts_at < now() + make_interval(mins => coalesce(v_set.booking_cutoff_minutes, 0)) then
    return jsonb_build_object('ok', false, 'reason', 'past_booking_cutoff'); end if;
  if v_occ.free_first_override = 'closed' then
    return jsonb_build_object('ok', false, 'reason', 'free_first_closed_here'); end if;
  if not coalesce(v_set.free_first_peak_allowed, true) and occurrence_is_peak(p_occurrence_id) then
    return jsonb_build_object('ok', false, 'reason', 'peak_not_allowed'); end if;

  if v_occ.series_id is not null then select * into v_ser from class_series where id = v_occ.series_id; end if;
  v_cfg_tier := coalesce(v_occ.guarantee_tier,
                         case when v_occ.flex then 'flex'::guarantee_tier end,
                         v_ser.guarantee_tier,
                         case when v_ser.flex then 'flex'::guarantee_tier end,
                         'core'::guarantee_tier);
  if coalesce(v_set.free_first_core_only, false) and v_cfg_tier <> 'core'
     and v_occ.free_first_override is distinct from 'open' then
    return jsonb_build_object('ok', false, 'reason', 'flex_not_allowed'); end if;
  if v_occ.series_id is not null and not coalesce(v_ser.free_first_allowed, true)
     and v_occ.free_first_override is distinct from 'open' then
    return jsonb_build_object('ok', false, 'reason', 'not_trial_class'); end if;
  if v_set.free_first_seats_per_class is not null
     and (select count(*) from bookings b
           where b.occurrence_id = p_occurrence_id and b.status = 'booked'
             and b.payment_source = 'comp'
             and exists (select 1 from guest_passes gp
                          where gp.guest_booking_id = b.id and gp.host_member_id is null))
         >= v_set.free_first_seats_per_class then
    return jsonb_build_object('ok', false, 'reason', 'free_seats_full'); end if;

  v_free := v_occ.capacity - occurrence_seats_taken(p_occurrence_id) - occurrence_seats_held(p_occurrence_id);
  if v_free < 1 then return jsonb_build_object('ok', false, 'reason', 'class_full'); end if;

  -- Hold the seat: a comp booking in pending_payment, no guest_passes yet. The
  -- AFTER-INSERT notification trigger sends nothing (status <> 'booked'), and the
  -- existing sweep_unpaid_dropins (status='pending_payment' and hold_until is null)
  -- frees it if the member abandons Xendit.
  insert into bookings (studio_id, occurrence_id, member_id, status, source,
                        payment_source, provisional, confirmed_at, booked_at)
  values (v_occ.studio_id, p_occurrence_id, v_member.id, 'pending_payment', 'member', 'comp',
          false, null, now())
  returning id into v_booking;
  update class_occurrences set booked_count = booked_count + 1 where id = p_occurrence_id;

  return jsonb_build_object('ok', true, 'booking_id', v_booking,
    'fee_cents', v_set.free_first_reservation_fee_cents);
end $$;
revoke execute on function reserve_free_first(uuid) from public, anon;
grant  execute on function reserve_free_first(uuid) to authenticated, service_role;

-- ===========================================================================
-- 7. xendit_begin_reservation — a reservation purchase against the held seat.
-- ===========================================================================
create or replace function xendit_begin_reservation(p_studio_id uuid, p_booking_id uuid)
returns table(purchase_id uuid, amount_cents int, currency char(3))
language plpgsql security definer set search_path = public as $$
declare v_member uuid; b bookings%rowtype; v_fee int; v_ccy char(3); v_id uuid;
begin
  select id into v_member from members where studio_id = p_studio_id and user_id = auth.uid();
  if v_member is null then
    raise exception 'you are not a member of that studio' using errcode = 'PT403';
  end if;
  if not exists (select 1 from studio_payment_providers where studio_id = p_studio_id and provider = 'xendit') then
    raise exception 'this studio is not set up to take online payments' using errcode = 'PT409';
  end if;

  select * into b from bookings where id = p_booking_id;
  if b.id is null or b.member_id <> v_member or b.studio_id <> p_studio_id
     or b.status <> 'pending_payment' or b.payment_source <> 'comp' then
    raise exception 'that is not a held reservation' using errcode = 'PT409';
  end if;

  select ss.free_first_reservation_fee_cents into v_fee from studio_settings ss where ss.studio_id = p_studio_id;
  if coalesce(v_fee, 0) <= 0 then
    raise exception 'this studio has no reservation fee' using errcode = 'PT409';
  end if;
  select st.currency into v_ccy from studios st where st.id = p_studio_id;

  insert into xendit_purchases (studio_id, member_id, booking_id, amount_cents, currency)
  values (p_studio_id, v_member, p_booking_id, v_fee, v_ccy)
  returning id into v_id;

  return query select v_id, v_fee, v_ccy;
end $$;
revoke execute on function xendit_begin_reservation(uuid, uuid) from public, anon;
grant  execute on function xendit_begin_reservation(uuid, uuid) to authenticated, service_role;

-- ===========================================================================
-- 8. book_first_free_run — complete a held reservation into the comp free seat.
--    The split of book_first_free: the webhook calls this after payment. Does
--    NOT queue the confirmation email (the internal queues it after writing the
--    reservation payment, so the reservation sentence reads the payment).
-- ===========================================================================
create or replace function book_first_free_run(p_booking_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare
  v_b bookings%rowtype; v_occ class_occurrences%rowtype; v_member members%rowtype;
  v_set studio_settings%rowtype; v_head int; v_cut timestamptz; v_prov boolean; v_pass uuid;
begin
  select * into v_b from bookings where id = p_booking_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if v_b.status = 'booked' and v_b.payment_source = 'comp' then
    return jsonb_build_object('ok', true, 'already', true);
  end if;
  if v_b.status <> 'pending_payment' or v_b.payment_source <> 'comp' then
    return jsonb_build_object('ok', false, 'reason', 'not_a_held_reservation');
  end if;

  select * into v_occ from class_occurrences where id = v_b.occurrence_id;
  select * into v_member from members where id = v_b.member_id;
  select * into v_set from studio_settings where studio_id = v_b.studio_id;

  v_head := occurrence_seats_taken(v_occ.id);
  select cutoff_at into v_cut from occurrence_guarantee_run(v_occ.id);
  v_prov := v_set.free_first_confirm_at is not null and v_cut is not null and v_head < v_set.free_first_confirm_at;

  perform set_config('studiior.free_first', '1', true);

  update bookings
     set status = 'booked', provisional = v_prov,
         confirmed_at = case when v_prov then null else now() end
   where id = p_booking_id;

  insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email,
                            occurrence_id, guest_booking_id, status, waiver_signed_at)
  values (v_b.studio_id, null, v_member.id, lower(btrim(v_member.email)),
          v_occ.id, p_booking_id,
          case when v_member.waiver_signed_at is not null then 'confirmed' else 'invited' end,
          v_member.waiver_signed_at)
  on conflict (studio_id, normalize_email_key(guest_email)) do update
    set host_member_id   = excluded.host_member_id,
        guest_member_id  = excluded.guest_member_id,
        occurrence_id    = excluded.occurrence_id,
        guest_booking_id = excluded.guest_booking_id,
        status           = excluded.status,
        waiver_signed_at = excluded.waiver_signed_at
  returning id into v_pass;

  perform confirm_provisional_seats_run(v_occ.id);
  return jsonb_build_object('ok', true, 'guest_pass_id', v_pass, 'provisional', v_prov);
end $$;
revoke execute on function book_first_free_run(uuid) from public, anon, authenticated;
grant  execute on function book_first_free_run(uuid) to service_role;

-- ===========================================================================
-- 9. The attendance / on-time-cancel credit hook. A reservation-paid free
--    booking: attended OR on-time cancelled -> credit; no-show / late cancel ->
--    kept (nothing). A trigger, because a booking's status is changed from more
--    places than any one caller remembers.
-- ===========================================================================
create or replace function tg_reservation_credit()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.status is distinct from new.status
     and new.status in ('attended', 'cancelled')
     and exists (select 1 from payments p
                  where p.booking_id = new.id and p.kind = 'reservation_fee'
                    and p.status in ('succeeded', 'partially_refunded')) then
    perform write_reservation_credit(new.id);
  end if;
  return new;
end $$;

revoke execute on function tg_reservation_credit() from public, anon, authenticated;
grant  execute on function tg_reservation_credit() to service_role;

drop trigger if exists tg_reservation_credit on bookings;
create trigger tg_reservation_credit
  after update of status on bookings
  for each row execute function tg_reservation_credit();

-- ===========================================================================
-- 10. xendit_activate_success_internal — re-issued (from 20260832480000) with a
--     reservation branch FIRST, and credit consumption on plan/product success.
-- ===========================================================================
create or replace function xendit_activate_success_internal(p_purchase_id uuid, p_payment_id text)
returns text
language plpgsql security definer set search_path = public as $$
declare p xendit_purchases%rowtype; v_ms uuid; v_prior text;
        v_group uuid; v_is_group boolean;
        o product_orders%rowtype; prod products%rowtype;
begin
  select * into p from xendit_purchases where id = p_purchase_id for update;
  if p.id is null then return 'unknown_purchase'; end if;
  if p.status = 'succeeded' then return 'already_succeeded'; end if;
  v_prior := p.status;

  if p.booking_id is not null then
    -- Decision 103: record the reservation fee FIRST, then complete the held
    -- free-first seat. The seat flip to 'booked' fires bookings_queue_notifications,
    -- which reads the now-present reservation payment to add its sentence. A
    -- reservation purchase never consumes credit itself.
    insert into payments (studio_id, member_id, booking_id, kind, amount_cents, currency,
                          status, provider, reference, description, paid_at)
    values (p.studio_id, p.member_id, p.booking_id, 'reservation_fee', p.amount_cents, p.currency,
            'succeeded', 'xendit', nullif(p_payment_id, ''), 'Reservation fee', now());
    perform book_first_free_run(p.booking_id);

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
                          status, provider, reference, description, paid_at)
    values (p.studio_id, p.member_id, o.id, p.amount_cents, p.currency, 'succeeded', 'xendit',
            nullif(p_payment_id, ''), prod.name || ' ×' || o.quantity, now());

    if p.credit_applied_cents > 0 then
      perform consume_reservation_credit(p.studio_id, p.member_id, p.credit_applied_cents);
    end if;

    perform queue_notification(
      p.studio_id, p.member_id, 'product_order_paid',
      jsonb_build_object('product', prod.name, 'quantity', o.quantity),
      'product_order_paid:' || o.id::text);

  else
    select type = 'group' into v_is_group from membership_plans where id = p.plan_id;
    if v_is_group then
      v_group := activate_purchase(p.studio_id, p.member_id, p.plan_id, p.amount_cents, p.currency, null, null, false);
      insert into payments (studio_id, member_id, group_purchase_id, amount_cents, currency,
                            status, provider, reference, description, paid_at)
      select p.studio_id, p.member_id, v_group, p.amount_cents, p.currency, 'succeeded', 'xendit',
             nullif(p_payment_id, ''), mp.name, now()
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
                          status, provider, reference, description, paid_at)
    select p.studio_id, p.member_id, v_ms, p.amount_cents, p.currency, 'succeeded', 'xendit',
           nullif(p_payment_id, ''), mp.name, now()
      from membership_plans mp where mp.id = p.plan_id;
    end if;

    -- Decision 103: a plan/pack purchase consumes any reservation credit applied
    -- at begin (the amount at Xendit was already reduced by this).
    if p.credit_applied_cents > 0 then
      perform consume_reservation_credit(p.studio_id, p.member_id, p.credit_applied_cents);
    end if;
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
revoke execute on function xendit_activate_success_internal(uuid, text) from public, anon, authenticated;
grant  execute on function xendit_activate_success_internal(uuid, text) to service_role;

-- ===========================================================================
-- 11. xendit_fail_purchase_internal — re-issued (from 20260832320000) with a
--     reservation (booking_id) branch: the held seat is freed by the drop-in
--     sweep, so the fail just marks the purchase (no plan/product to touch).
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
    -- Decision 103: a reservation. The held pending_payment seat is released by
    -- sweep_unpaid_dropins; nothing to release here and no email (the class page
    -- tells the member "Your spot wasn't held. Book again.").
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
-- 12. xendit_begin_purchase — re-issued (from 20260832560000) applying a
--     reservation credit (capped so at least 2000 minor units are paid online),
--     returning the credit applied. Drop+recreate: a new return column.
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

  -- Decision 103: apply any reservation credit, capped so the online payment is
  -- never below the processor minimum (2000 minor units). The remainder stays.
  v_avail := reservation_credit_available(p_studio_id, v_member);
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
-- 13. xendit_begin_product_purchase — re-issued (from 20260832320000) applying
--     a reservation credit the same way. Drop+recreate: a new return column.
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
-- 14. record_refund — re-issued (from 20260832310000) voiding the UNUSED
--     remainder of a reservation credit when its reservation fee is refunded.
-- ===========================================================================
create or replace function record_refund(
  p_payment_id uuid, p_amount_cents int default null, p_reason text default null,
  p_restock boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  pay      payments%rowtype;
  plan     membership_plans%rowtype;
  ms       memberships%rowtype;
  o        product_orders%rowtype;
  prod     products%rowtype;
  v_amount int;
  v_total  int;
  v_full   boolean;
  v_bal    int;
  v_take   int := 0;
begin
  select * into pay from payments where id = p_payment_id for update;
  if not found then
    raise exception 'no such payment' using errcode = 'PT404';
  end if;
  if not is_manager_up(pay.studio_id) then
    raise exception 'refunds are the owner''s or a manager''s to make'
      using errcode = 'PT403';
  end if;
  if pay.status not in ('succeeded', 'partially_refunded') then
    raise exception 'a % payment cannot be refunded', pay.status using errcode = 'PT409';
  end if;

  v_amount := coalesce(p_amount_cents, pay.amount_cents - pay.refunded_cents);
  if v_amount <= 0 or v_amount > pay.amount_cents - pay.refunded_cents then
    raise exception 'that is more than is left to refund' using errcode = 'PT400';
  end if;

  v_total := pay.refunded_cents + v_amount;
  v_full  := v_total >= pay.amount_cents;

  update payments
     set refunded_cents = v_total,
         refunded_at = now(),
         refund_reason = coalesce(p_reason, refund_reason),
         status = (case when v_full then 'refunded' else 'partially_refunded' end)::payment_status,
         updated_at = now()
   where id = p_payment_id;

  if v_full and pay.membership_id is not null then
    select * into ms from memberships where id = pay.membership_id;
    select * into plan from membership_plans where id = ms.plan_id;

    if plan.type = 'class_pack' then
      select coalesce(sum(delta), 0) into v_bal
        from credit_ledger
       where studio_id = pay.studio_id and member_id = pay.member_id;

      v_take := least(coalesce(ms.credits_remaining, 0), greatest(v_bal, 0));
      if v_take > 0 then
        insert into credit_ledger (studio_id, member_id, membership_id, delta, reason,
                                   balance_after, actor_user_id)
        values (pay.studio_id, pay.member_id, ms.id, -v_take, 'manual',
                v_bal - v_take, auth.uid());
        update memberships set credits_remaining = coalesce(credits_remaining, 0) - v_take
         where id = ms.id;
      end if;
    end if;

    update memberships
       set status = 'cancelled', cancelled_at = now(),
           cancellation_reason = coalesce(p_reason, 'refunded')
     where id = ms.id and status <> 'cancelled';

    insert into membership_events (studio_id, membership_id, type, from_status,
                                   to_status, actor_user_id, metadata)
    values (pay.studio_id, ms.id, 'cancelled', ms.status, 'cancelled', auth.uid(),
            jsonb_build_object('reason', p_reason, 'payment_id', p_payment_id,
                               'credits_removed', v_take));
  end if;

  -- Decision 103: refunding a reservation fee removes the UNUSED remainder of its
  -- credit (used stays used — a member cannot keep a credit from money returned).
  if pay.kind = 'reservation_fee' then
    update member_credits
       set used_cents = amount_cents, voided_at = now()
     where payment_id = p_payment_id and voided_at is null;
  end if;

  if p_restock and pay.product_order_id is not null then
    select * into o from product_orders where id = pay.product_order_id;
    if o.id is not null then
      select * into prod from products where id = o.product_id;
      if prod.track_stock then
        update products set stock = stock + o.quantity where id = o.product_id;
        insert into stock_movements (studio_id, product_id, delta, reason, order_id, created_by)
        values (o.studio_id, o.product_id, o.quantity, 'refund_restock', o.id, auth.uid());
      end if;
      update product_orders set status = 'refunded' where id = o.id;
    end if;
  end if;

  return jsonb_build_object('payment_id', p_payment_id, 'refunded_cents', v_total,
                            'full', v_full, 'credits_removed', v_take);
end $$;
revoke execute on function record_refund(uuid, int, text, boolean) from public, anon, authenticated;
grant  execute on function record_refund(uuid, int, text, boolean) to authenticated;

-- ===========================================================================
-- 15. member_wallet — re-issued (from 20260833200000) with the reservation-fee
--     item label and a credits array (unused reservation credits).
-- ===========================================================================
create or replace function member_wallet(p_studio_id uuid)
returns jsonb
language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare
  v_member   members%rowtype;
  v_dropin   int;
  v_ccy      text;
  v_payments jsonb;
  v_online   jsonb;
  v_desk     jsonb;
  v_credits  jsonb;
begin
  select * into v_member from members
   where user_id = auth.uid() and studio_id = p_studio_id and deleted_at is null;
  if not found then
    raise exception 'not a member of this studio' using errcode = 'PT403';
  end if;

  select currency into v_ccy from studios where id = p_studio_id;

  select price_cents into v_dropin
    from membership_plans
   where studio_id = p_studio_id and type = 'drop_in'
     and visibility = 'public' and status = 'active'
   order by price_cents asc
   limit 1;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id,
      'amount_cents', p.amount_cents,
      'currency', p.currency,
      'status', p.status::text,
      'refunded_cents', coalesce(p.refunded_cents, 0),
      'refunded_at', p.refunded_at,
      'provider', p.provider::text,
      'method', p.method,
      'card_brand', p.card_brand,
      'card_last4', p.card_last4,
      'invoice_no', p.invoice_no,
      'received_by', p.received_by,
      'kind', p.kind,
      'at', coalesce(p.paid_at, p.created_at),
      'item', case when p.kind = 'reservation_fee' then 'Reservation fee'
                   else coalesce(mp.name, prod.name, coalesce(occ.name, ct.name), gpl.name,
                                 nullif(p.description, ''), 'Payment') end
    ) order by coalesce(p.paid_at, p.created_at) desc), '[]'::jsonb)
  into v_payments
    from payments p
    left join memberships ms       on ms.id   = p.membership_id
    left join membership_plans mp  on mp.id   = ms.plan_id
    left join product_orders po    on po.id   = p.product_order_id
    left join products prod        on prod.id = po.product_id
    left join bookings b           on b.id    = p.booking_id
    left join class_occurrences occ on occ.id = b.occurrence_id
    left join class_types ct       on ct.id   = occ.class_type_id
    left join group_purchases gp   on gp.id   = p.group_purchase_id
    left join membership_plans gpl on gpl.id  = gp.plan_id
   where p.member_id = v_member.id
     and (p.status = 'succeeded' or coalesce(p.refunded_cents, 0) > 0);

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', xp.id,
      'amount_cents', xp.amount_cents,
      'currency', xp.currency,
      'status', xp.status,
      'at', xp.created_at,
      'item', coalesce(mp.name, prod.name, 'Payment')
    ) order by xp.created_at desc), '[]'::jsonb)
  into v_online
    from xendit_purchases xp
    left join membership_plans mp on mp.id   = xp.plan_id
    left join product_orders po   on po.id   = xp.product_order_id
    left join products prod       on prod.id = po.product_id
   where xp.member_id = v_member.id
     and xp.status is distinct from 'succeeded'
     and xp.booking_id is null;

  select coalesce(jsonb_agg(jsonb_build_object(
      'booking_id', b.id,
      'occurrence_id', occ.id,
      'item', coalesce(occ.name, ct.name),
      'starts_at', occ.starts_at,
      'due_cents', v_dropin,
      'currency', v_ccy
    ) order by occ.starts_at asc), '[]'::jsonb)
  into v_desk
    from bookings b
    join class_occurrences occ on occ.id = b.occurrence_id
    left join class_types ct   on ct.id  = occ.class_type_id
   where b.member_id = v_member.id
     and b.payment_source = 'drop_in'
     and b.status in ('booked', 'pending_payment')
     and occ.starts_at > now()
     and not exists (
       select 1 from payments pay
        where pay.booking_id = b.id
          and pay.status in ('succeeded', 'partially_refunded'));

  -- Decision 103: unused reservation credits.
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', mc.id,
      'amount_cents', mc.amount_cents - mc.used_cents,
      'currency', mc.currency,
      'at', mc.created_at
    ) order by mc.created_at asc), '[]'::jsonb)
  into v_credits
    from member_credits mc
   where mc.member_id = v_member.id and mc.studio_id = p_studio_id
     and mc.voided_at is null and mc.amount_cents > mc.used_cents;

  return jsonb_build_object('payments', v_payments, 'online', v_online,
                            'desk', v_desk, 'credits', v_credits);
end $$;
revoke execute on function member_wallet(uuid) from public, anon;
grant execute on function member_wallet(uuid) to authenticated, service_role;

-- ===========================================================================
-- 16. member_plan_overview — re-issued (from 20260833290000) with
--     reservation_credit_cents (the unused reservation credit, for the chip).
-- ===========================================================================
drop function if exists member_plan_overview(uuid);
create function member_plan_overview(p_studio_id uuid)
returns table (
  id uuid, first_name text, last_name text, email text, status text,
  lifetime_visits int, last_visit_at timestamptz,
  health_band text, health_reason text, user_id uuid,
  membership_id uuid, current_plan_name text, plan_type text,
  membership_status text, expires_on date, credits_remaining int,
  had_free_class boolean, has_ever_paid boolean, plan_state text,
  complimentary boolean, free_stage text, has_unpaid_booking boolean,
  joined_on date, desk_pay_blocked boolean, reservation_credit_cents int
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare v_tz text; v_today date;
  v_cutover constant timestamptz := '2026-11-09 00:00:00+00';
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
           m.health_band::text as health_band, m.health_reason, m.user_id,
           m.joined_on, m.desk_pay_blocked_at
      from members m
     where m.studio_id = p_studio_id and m.status <> 'archived'
       and m.deleted_at is null
  ),
  live as (
    select distinct on (ms.member_id)
           ms.member_id, ms.id as membership_id, ms.status as ms_status,
           ms.expires_on, ms.credits_remaining, mp.name as plan_name, mp.type as plan_type,
           ms.complimentary,
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
  ),
  comp as (
    select b.member_id,
           bool_or(b.status = 'attended') as any_attended,
           bool_or(b.status = 'booked')   as any_booked,
           bool_or(b.status = 'no_show')  as any_no_show,
           bool_or(b.status = 'late_cancelled'
                   and b.cancelled_at >= v_cutover) as any_late_cancel,
           max(o.starts_at) filter (where b.status = 'no_show') as last_no_show_at
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
     where b.studio_id = p_studio_id
       and b.payment_source = 'comp'
       and b.status in ('booked','attended','no_show','late_cancelled')
     group by b.member_id
  ),
  unpaid as (
    select distinct b.member_id
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
     where b.studio_id = p_studio_id
       and b.payment_source = 'drop_in'
       and b.status in ('booked','pending_payment')
       and o.starts_at > now()
       and not exists (select 1 from payments p
                        where p.booking_id = b.id
                          and p.status in ('succeeded','partially_refunded'))
  ),
  rescred as (
    select member_id, sum(amount_cents - used_cents)::int as cents
      from member_credits
     where studio_id = p_studio_id and voided_at is null and amount_cents > used_cents
     group by member_id
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
         coalesce(live.complimentary, false) as complimentary,
         case
           when comp.any_attended then 'taken'
           when comp.any_booked   then 'booked'
           when comp.any_no_show
                and not exists (
                  select 1 from bookings b2
                  join class_occurrences o2 on o2.id = b2.occurrence_id
                  where b2.member_id = mem.id and b2.studio_id = p_studio_id
                    and b2.status not in ('cancelled','late_cancelled')
                    and o2.starts_at > comp.last_no_show_at
                ) then 'missed'
           when comp.any_late_cancel then 'late_cancel'
           else null
         end as free_stage,
         (unpaid.member_id is not null) as has_unpaid_booking,
         mem.joined_on,
         (mem.desk_pay_blocked_at is not null) as desk_pay_blocked,
         coalesce(rescred.cents, 0) as reservation_credit_cents
    from mem
    left join live    on live.member_id = mem.id
    left join paid    on paid.member_id = mem.id
    left join freebie on freebie.member_id = mem.id
    left join comp    on comp.member_id = mem.id
    left join unpaid  on unpaid.member_id = mem.id
    left join rescred on rescred.member_id = mem.id;
end $$;
revoke all on function member_plan_overview(uuid) from public, anon;
grant execute on function member_plan_overview(uuid) to authenticated, service_role;

-- ===========================================================================
-- 17. queue_booking_notifications — re-issued (from 20260833080000) adding the
--     reservation sentence to the confirmation when a reservation fee was paid.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.queue_booking_notifications(p_booking_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  b bookings%rowtype; o class_occurrences%rowtype; m members%rowtype;
  st studio_settings%rowtype; s studios%rowtype;
  v_when text; v_where text; n int := 0; v_remind timestamptz;
  v_manage text;
  v_is_free boolean; v_ff_txt text; v_ff_html text;
  v_deadline timestamptz;
  v_cutoff timestamptz;
  v_fmt text;
  v_cancel_deadline text;
  v_resv_fee int; v_resv_txt text; v_resv_html text;
begin
  select * into b from bookings where id = p_booking_id;
  if not found or b.status <> 'booked' then return 0; end if;

  if current_setting('studiior.suppress_booking_email', true) = '1' then return 0; end if;

  select * into o  from class_occurrences where id = b.occurrence_id;
  select * into m  from members            where id = b.member_id;
  select * into s  from studios            where id = b.studio_id;
  select * into st from studio_settings    where studio_id = b.studio_id;
  v_fmt := coalesce(st.time_format, '24h');

  v_when  := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY, ')
             || fmt_clock(o.starts_at, s.timezone, v_fmt);
  v_where := coalesce((select ', in ' || r.name from rooms r where r.id = o.room_id), '');
  v_manage := 'https://' || s.slug || '.'
              || coalesce(notification_setting('member_app_domain'), 'studiior.app')
              || '/class/' || o.id;

  v_is_free := current_setting('studiior.free_first', true) = '1'
    or (b.payment_source = 'comp'
        and exists (select 1 from guest_passes gp
                     where gp.guest_booking_id = b.id and gp.host_member_id is null));

  -- Decision 103: the reservation sentence, when this free booking paid a fee.
  select amount_cents into v_resv_fee from payments
   where booking_id = b.id and kind = 'reservation_fee'
     and status in ('succeeded', 'partially_refunded') limit 1;
  if v_resv_fee is not null then
    v_resv_txt  := E'\n\nYour ' || fmt_money(v_resv_fee, s.currency)
                   || ' reservation fee comes off your next purchase when you show up.';
    v_resv_html := '<p>Your ' || fmt_money(v_resv_fee, s.currency)
                   || ' reservation fee comes off your next purchase when you show up.</p>';
  else
    v_resv_txt := ''; v_resv_html := '';
  end if;

  v_ff_txt  := (case when v_is_free then E'\n\nThis one''s on us — your first class is free.' else '' end) || v_resv_txt;
  v_ff_html := (case when v_is_free then '<p>This one''s on us — your first class is free.</p>' else '' end) || v_resv_html;

  select deadline_at into v_deadline from flex_deadline_for_run(o.id);

  if b.payment_source = 'comp' and b.provisional then
    select cutoff_at into v_cutoff from occurrence_guarantee_run(o.id);
    if queue_notification(b.studio_id, b.member_id, 'free_booking_pending',
          jsonb_build_object('class_name', o.name, 'when', v_when,
            'cutoff_long', fmt_clock(v_cutoff, s.timezone, v_fmt) || ' on ' || to_char(v_cutoff at time zone s.timezone, 'FMDay FMDD FMMonth YYYY'),
            'manage_link', v_manage, 'book_url', member_portal_url(b.studio_id, '/book'),
            'booking_id', b.id, 'occurrence_id', o.id),
          'booking_confirmed:' || b.id) is not null then n := n + 1; end if;
  elsif v_is_free then
    v_cancel_deadline :=
      fmt_clock(o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)), s.timezone, v_fmt)
      || ' on ' || to_char(
        (o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)))
          at time zone s.timezone, 'FMDay FMDD FMMonth YYYY');
    if queue_notification(b.studio_id, b.member_id, 'free_booking_confirmed',
          jsonb_build_object('class_name', o.name,
            'day',  to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth'),
            'time', fmt_clock(o.starts_at, s.timezone, v_fmt),
            'cancel_deadline', v_cancel_deadline,
            'manage_link', v_manage,
            'book_url', member_portal_url(b.studio_id, '/book'),
            'reservation_line', v_resv_txt, 'reservation_html', v_resv_html,
            'occurrence_id', o.id),
          'booking_confirmed:' || b.id) is not null then n := n + 1; end if;
  elsif v_deadline is not null then
    if queue_notification(b.studio_id, b.member_id, 'flex_booking_pending',
          jsonb_build_object('class_name', o.name, 'when', v_when,
            'deadline_short', to_char(v_deadline at time zone s.timezone, 'FMDy ')
                              || fmt_clock(v_deadline, s.timezone, v_fmt),
            'deadline_long', fmt_clock(v_deadline, s.timezone, v_fmt) || ' on ' || to_char(v_deadline at time zone s.timezone, 'FMDay FMDD FMMonth YYYY'),
            'manage_link', v_manage, 'book_url', member_portal_url(b.studio_id, '/book'),
            'booking_id', b.id, 'occurrence_id', o.id),
          'booking_confirmed:' || b.id) is not null then n := n + 1; end if;
  else
    if queue_notification(b.studio_id, b.member_id, 'booking_confirmed',
          jsonb_build_object('class_name', o.name, 'when', v_when, 'where_line', v_where,
                             'manage_link', v_manage,
                             'book_url', member_portal_url(b.studio_id, '/book'),
                             'free_first_line', v_ff_txt, 'free_first_html', v_ff_html,
                             'booking_id', b.id, 'occurrence_id', o.id),
          'booking_confirmed:' || b.id) is not null then n := n + 1; end if;
  end if;

  v_remind := o.starts_at - make_interval(hours => coalesce(st.reminder_hours_before, 12));
  if v_remind > now() then
    if queue_notification(b.studio_id, b.member_id, 'class_reminder',
          jsonb_build_object('class_name', o.name,
                             'when_short', 'tomorrow',
                             'when_time', fmt_clock(o.starts_at, s.timezone, v_fmt),
                             'manage_link', v_manage, 'book_url', member_portal_url(b.studio_id, '/book'),
                             'where_line', v_where),
          'class_reminder:' || b.id, v_remind) is not null then n := n + 1; end if;
  end if;

  return n;
end $function$;
revoke execute on function queue_booking_notifications(uuid) from public, anon, authenticated;
grant  execute on function queue_booking_notifications(uuid) to service_role;

-- ===========================================================================
-- 18. Templates.
-- ===========================================================================
-- free_booking_confirmed gains the reservation sentence (always supplied empty
-- when no fee). text_body + html_body.
update notification_templates set
  text_body = E'{class_name} on {day} is confirmed — see you at {time}. This is your free first class: if you can''t make it, cancel before {cancel_deadline} or rebook another class, otherwise the free class is used.{reservation_line}\n\nManage your booking: {manage_link}',
  html_body = '<p><strong>{class_name}</strong> on {day} is confirmed — see you at {time}.</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{class_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">{day} · {time}</div></td></tr></table>
<p>This is your free first class: if you can&#39;t make it, cancel before {cancel_deadline} or rebook another class, otherwise the free class is used.</p>
{reservation_html}
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{manage_link}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Manage your booking</a></td></tr></table>'
 where key = 'free_booking_confirmed';

-- The two new reservation templates (80a frame; buttons use {accent}/{accent_on}).
insert into notification_templates (key, subject, text_body, html_body, note) values
('free_reservation_due',
 'A {fee} reservation fee now holds your free class on {day}',
 E'Hi {first_name},\n\nFrom {from_date} a {fee} reservation fee holds free class bookings.\n\nThis is a reservation fee, not a charge for the class. Show up and the {fee} is credited back to your account to use on class packages or merchandise. If you don''t show up or cancel late, the fee is not refunded.\n\nPay it by {deadline} to keep your spot, or cancel if you''d rather not. If we don''t hear from you by then, we''ll release the spot and your free class stays yours to rebook.\n\nPay {fee} to keep my spot: {pay_url}\nCancel my booking: {cancel_url}',
 '<p>Hi {first_name},</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{class_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">{day} · {time}</div></td></tr></table>
<p>From {from_date} a {fee} reservation fee holds free class bookings.</p>
<p>This is a reservation fee, not a charge for the class. Show up and the {fee} is credited back to your account to use on class packages or merchandise. If you don&#39;t show up or cancel late, the fee is not refunded.</p>
<p>Pay it by {deadline} to keep your spot, or cancel if you&#39;d rather not. If we don&#39;t hear from you by then, we&#39;ll release the spot and your free class stays yours to rebook.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{pay_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Pay {fee} to keep my spot</a></td></tr></table>
<p><a href="{cancel_url}" style="color:#57534E">Cancel my booking</a></p>
<p>{studio_name}</p>',
 'Decision 103: a reservation fee is now required for an existing free booking.'),
('free_reservation_released',
 'We released your spot in {class_name} on {day}',
 E'Hi {first_name},\n\nWe released your spot in {class_name} on {day}. Your free first class is still yours. Book again when you''re ready.\n\nBook a class: {book_url}',
 '<p>Hi {first_name},</p>
<p>We released your spot in <strong>{class_name}</strong> on {day}. Your free first class is still yours. Book again when you&#39;re ready.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{book_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Book a class</a></td></tr></table>
<p>{studio_name}</p>',
 'Decision 103: a reservation-fee free booking was released for non-payment.')
on conflict (key) do nothing;

-- Both reservation templates always send (not member-opt-outable account mail).
-- notification_wanted returns true for an unlisted template, so nothing to add.

-- ===========================================================================
-- 19. template_sample_context — re-issued (from 20260833420000) adding the
--     reservation tokens so the Templates preview / a test send / email_frame_test
--     render the reservation templates with nothing stripped.
-- ===========================================================================
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
    'offer_ends', v_offer_ends,
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
    'going_ahead', '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:12px 0;border-collapse:collapse"><tr><td colspan="3" style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;color:#14170E;padding:0 0 6px 0">Going ahead</td></tr><tr><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Time</th><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Class</th><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Booked</th></tr><tr><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">' || fmt_clock(((now() at time zone v_tz)::date + time '07:00') at time zone v_tz, v_tz, v_fmt) || '</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">Reformer Flow</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">4 of 6</td></tr><tr><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">' || fmt_clock(((now() at time zone v_tz)::date + time '18:00') at time zone v_tz, v_tz, v_fmt) || '</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">Barre</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">5 of 8</td></tr></table>',
    'going_ahead_text', 'Going ahead' || E'\n  ' || fmt_clock(((now() at time zone v_tz)::date + time '07:00') at time zone v_tz, v_tz, v_fmt) || '  Reformer Flow  4 of 6' || E'\n  ' || fmt_clock(((now() at time zone v_tz)::date + time '18:00') at time zone v_tz, v_tz, v_fmt) || '  Barre  5 of 8',
    'cancelled', '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:12px 0;border-collapse:collapse"><tr><td colspan="3" style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;color:#14170E;padding:0 0 6px 0">Cancelled, not enough bookings</td></tr><tr><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Time</th><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Class</th><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Booked</th></tr><tr><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">' || fmt_clock(((now() at time zone v_tz)::date + time '09:00') at time zone v_tz, v_tz, v_fmt) || '</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">Mat Pilates</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">1 of 3 needed</td></tr></table>',
    'cancelled_text', 'Cancelled, not enough bookings' || E'\n  ' || fmt_clock(((now() at time zone v_tz)::date + time '09:00') at time zone v_tz, v_tz, v_fmt) || '  Mat Pilates  1 of 3 needed')
  -- Decision 103: reservation tokens.
  || jsonb_build_object(
    'fee', v_fee,
    'from_date', to_char(now() at time zone v_tz, 'FMDD Mon'),
    'deadline', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD Mon') else 'the day before' end,
    'pay_url', member_portal_url(p_studio_id, '/class/' || coalesce(o.id::text, '')),
    'cancel_url', member_portal_url(p_studio_id, '/class/' || coalesce(o.id::text, '')),
    'reservation_line', '',
    'reservation_html', '');
end $function$;

-- ===========================================================================
-- 19b. member_reservation_dues — the member's own free bookings that now need the
--      reservation fee (the Home / class-page notice). Mirrors the sweep's "due"
--      set: a comp free booking on a class on/after the applies-from date, no
--      reservation fee paid, cut-off not passed.
-- ===========================================================================
create or replace function member_reservation_dues(p_studio_id uuid)
returns table(occurrence_id uuid, booking_id uuid, class_name text, starts_at timestamptz, fee_cents int)
language sql stable security definer set search_path = public as $$
  select o.id, b.id, o.name, o.starts_at, st.free_first_reservation_fee_cents
    from bookings b
    join members m             on m.id = b.member_id
    join class_occurrences o   on o.id = b.occurrence_id
    join studio_settings st    on st.studio_id = b.studio_id
    join studios s             on s.id = b.studio_id
   where m.user_id = auth.uid() and b.studio_id = p_studio_id
     and b.status = 'booked' and b.payment_source = 'comp'
     and coalesce(st.free_first_reservation_fee_cents, 0) > 0
     and st.free_first_reservation_from is not null
     and (o.starts_at at time zone s.timezone)::date >= st.free_first_reservation_from
     and o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)) > now()
     and exists (select 1 from guest_passes gp
                  where gp.guest_booking_id = b.id and gp.host_member_id is null)
     and not exists (select 1 from payments p
                      where p.booking_id = b.id and p.kind = 'reservation_fee'
                        and p.status in ('succeeded','partially_refunded'))
   order by o.starts_at;
$$;
revoke execute on function member_reservation_dues(uuid) from public, anon;
grant  execute on function member_reservation_dues(uuid) to authenticated, service_role;

-- ===========================================================================
-- 20. sweep_free_reservation_dues — the existing-bookings flow. Queues the due
--     email for a free booking (no reservation fee paid) on/after the applies-from
--     date whose cut-off has not passed; releases one past its cut-off that was
--     asked and not paid. Every 15 minutes.
-- ===========================================================================
create or replace function sweep_free_reservation_dues(p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record; v_asked int := 0; v_released int := 0; v_tz text; v_s studios%rowtype;
        v_deadline timestamptz; v_day text; v_fmt text; v_res cancel_result;
begin
  if not is_service_context() then
    raise exception 'the reservation-dues sweep runs as the backend, not as a user'
      using errcode = 'PT403';
  end if;

  for r in
    select b.id as booking_id, b.studio_id, b.member_id, o.id as occ_id, o.name as cname,
           o.starts_at, st.cancellation_cutoff_minutes, st.free_first_reservation_fee_cents,
           st.free_first_reservation_from
      from bookings b
      join class_occurrences o   on o.id = b.occurrence_id
      join studio_settings st    on st.studio_id = b.studio_id
     where b.status = 'booked' and b.payment_source = 'comp'
       and st.free_first_reservation_from is not null
       and coalesce(st.free_first_reservation_fee_cents, 0) > 0
       and exists (select 1 from guest_passes gp
                    where gp.guest_booking_id = b.id and gp.host_member_id is null)
       and not exists (select 1 from payments p
                        where p.booking_id = b.id and p.kind = 'reservation_fee'
                          and p.status in ('succeeded','partially_refunded'))
  loop
    select timezone into v_tz from studios where id = r.studio_id;
    v_fmt := coalesce((select time_format from studio_settings where studio_id = r.studio_id), '24h');
    -- Only classes on/after the applies-from date (studio-local).
    if (r.starts_at at time zone v_tz)::date < r.free_first_reservation_from then
      continue;
    end if;
    v_deadline := r.starts_at - make_interval(mins => coalesce(r.cancellation_cutoff_minutes, 0));
    v_day := to_char(r.starts_at at time zone v_tz, 'FMDay FMDD FMMonth');

    if p_now < v_deadline then
      -- Ask once. The cut-off (deadline) has not passed.
      if queue_notification(r.studio_id, r.member_id, 'free_reservation_due',
            jsonb_build_object(
              'class_name', r.cname, 'day', v_day,
              'time', fmt_clock(r.starts_at, v_tz, v_fmt),
              'fee', fmt_money(r.free_first_reservation_fee_cents,
                               (select currency from studios where id = r.studio_id)),
              'from_date', to_char(r.free_first_reservation_from, 'FMDD Mon'),
              'deadline', fmt_clock(v_deadline, v_tz, v_fmt) || ' on '
                          || to_char(v_deadline at time zone v_tz, 'FMDay FMDD FMMonth'),
              'pay_url', member_portal_url(r.studio_id, '/class/' || r.occ_id),
              'cancel_url', member_portal_url(r.studio_id, '/class/' || r.occ_id)),
            'free_reservation_due:' || r.booking_id) is not null then
        v_asked := v_asked + 1;
      end if;
    else
      -- The cut-off has passed. Release ONLY if we asked (a due email went out)
      -- and it was not paid. Bookings never asked (cut-off already past when the
      -- date was set) are left as they are.
      if exists (select 1 from notifications
                  where dedupe_key = 'free_reservation_due:' || r.booking_id) then
        -- On-time path: set free_cancel_until so cancel_booking does not mark it
        -- a late cancel. The free class stays available (a cancelled comp seat
        -- remains free-first eligible, Decision 30d).
        update bookings set free_cancel_until = p_now + interval '1 hour' where id = r.booking_id;
        v_res := cancel_booking(r.booking_id);
        perform queue_notification(r.studio_id, r.member_id, 'free_reservation_released',
          jsonb_build_object('class_name', r.cname, 'day', v_day,
                             'book_url', member_portal_url(r.studio_id, '/book')),
          'free_reservation_released:' || r.booking_id);
        v_released := v_released + 1;
      end if;
    end if;
  end loop;

  return jsonb_build_object('asked', v_asked, 'released', v_released);
end $$;
revoke execute on function sweep_free_reservation_dues(timestamptz) from public, anon, authenticated;
grant  execute on function sweep_free_reservation_dues(timestamptz) to service_role;

do $$
begin
  if not exists (select 1 from cron.job where jobname = 'studiior-free-reservation-dues') then
    perform cron.schedule('studiior-free-reservation-dues', '*/15 * * * *',
      $c$select sweep_free_reservation_dues()$c$);
  end if;
end $$;

-- ===========================================================================
-- 21. member_bootstrap — re-issued (from 20260833320000) carrying the reservation
--     fee, so the member app shows the picker button and the checkout line.
-- ===========================================================================
drop function if exists member_bootstrap(text);
create function public.member_bootstrap(p_slug text)
 returns table(member_id uuid, studio_id uuid, first_name text, last_name text, preferred_name text, avatar_path text, status member_status, current_streak integer, lifetime_visits integer, studio_name text, studio_timezone text, logo_url text, theme_preset theme_preset, accent_color text, checkin_opens_minutes_before integer, checkin_closes_minutes_after integer, cancellation_cutoff_minutes integer, booking_cutoff_minutes integer, waitlist_enabled boolean, billing_status platform_status, billing_locked boolean, open_offers integer, guest_passes_enabled boolean, has_payment_provider boolean, booking_window_days integer, how_to_buy text, studio_contact_email text, xendit_enabled boolean, time_format text, trial_used boolean, messages_enabled boolean, has_unread_studio_message boolean, desk_pay_available boolean, payee_notice_name text, has_phone boolean, country text, free_first_reservation_fee_cents integer, currency text)
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select
    m.id, m.studio_id, m.first_name, m.last_name, m.preferred_name, m.avatar_url,
    m.status, coalesce(m.current_streak, 0), coalesce(m.lifetime_visits, 0),
    s.name, s.timezone, s.logo_url, s.theme_preset, s.accent_color,
    coalesce(st.checkin_opens_minutes_before, 60),
    coalesce(st.checkin_closes_minutes_after, 30),
    coalesce(st.cancellation_cutoff_minutes, 720),
    coalesce(st.booking_cutoff_minutes, 0),
    coalesce(st.waitlist_enabled, true),
    ps.status,
    coalesce(ps.status = 'locked', false),
    (select count(*)::int from waitlist_offers wo
       join bookings b on b.id = wo.booking_id
      where b.member_id = m.id
        and wo.responded_at is null
        and wo.expires_at > now()),
    coalesce(st.guest_passes_enabled, false),
    (s.stripe_account_id is not null),
    member_booking_window_days(m.id),
    st.how_to_buy,
    s.contact_email,
    exists (select 1 from studio_payment_providers spp
             where spp.studio_id = m.studio_id and spp.provider = 'xendit'),
    coalesce(st.time_format, '24h'),
    exists (select 1 from memberships ms
              join membership_plans mp on mp.id = ms.plan_id
             where ms.member_id = m.id and mp.type = 'trial'),
    coalesce(st.messages_enabled, false),
    coalesce(st.messages_enabled, false) and exists (
      select 1 from message_threads mt
        join thread_messages msg on msg.thread_id = mt.id
       where mt.member_id = m.id and msg.sender_kind = 'staff'
         and msg.created_at > coalesce(mt.last_member_read_at, 'epoch'::timestamptz)),
    not (
      (coalesce(st.desk_pay_mode, 'earned') = 'earned' and m.desk_pay_blocked_at is not null)
      or (coalesce(st.desk_pay_mode, 'earned') = 'first_visit_only'
          and exists (select 1 from bookings bdp
                       where bdp.member_id = m.id and bdp.studio_id = m.studio_id
                         and bdp.payment_source = 'drop_in' and bdp.status <> 'cancelled'))
    ),
    st.payee_notice_name,
    (nullif(btrim(coalesce(m.phone, '')), '') is not null),
    s.country,
    coalesce(st.free_first_reservation_fee_cents, 0),
    s.currency
  from members m
  join studios s on s.id = m.studio_id
  left join studio_settings st on st.studio_id = m.studio_id
  left join platform_subscriptions ps on ps.studio_id = m.studio_id
  where m.user_id = auth.uid()
    and s.slug = p_slug
  limit 1
$function$;
revoke execute on function member_bootstrap(text) from public, anon;
grant  execute on function member_bootstrap(text) to authenticated, service_role;

-- ===========================================================================
-- Anon surface — EXACTLY THIRTEEN (nothing added here is anon).
-- ===========================================================================
do $$
declare n int;
begin
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'expect_%'
     and p.proname not in ('login','sig','psig');
  if n <> 13 then
    raise exception 'anon surface drifted: expected 13, got %', n;
  end if;
end $$;
