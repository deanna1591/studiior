-- =============================================================================
-- Decision 103(e) — a paid reservation fee always lands (migration 20260833500000).
-- UUID space d10e, checked free.
-- =============================================================================
-- Covers: a hold outlives booked_at+15min while its invoice is open (hold_until
-- governs); a Xendit expiry releases the hold at once; a late success with a free
-- seat restores + confirms through the real book_first_free_run; a late success
-- with a full class credits the fee + sends the lost-seat email; reservation
-- credit of at least the fee books with no Xendit and consumes the credit; credit
-- below the fee still charges; the eight Journey lines (a hold is never Booked);
-- the Sales grouping; the five profile states. Anon stays THIRTEEN.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual then raise notice 'PASS  %  (got true)', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if;
end $$;

-- Complete a held reservation as the webhook would.
create or replace function d10e_complete(p_booking uuid) returns void language plpgsql as $$
declare v_pur uuid;
begin
  select id into v_pur from xendit_purchases where booking_id = p_booking order by created_at desc limit 1;
  perform xendit_activate_success_internal(v_pur, 'py-' || left(p_booking::text, 8));
end $$;
-- Has member_activity a row of this kind for this member?
create or replace function d10e_has_kind(p_member uuid, p_kind text) returns boolean
language sql security definer set search_path = public as $$
  select exists (select 1 from member_activity(p_member, '2000-01-01', '2100-01-01') where kind = p_kind);
$$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('d10e0000-0000-0000-0000-0000000000a1'),
  ('d10e0000-0000-0000-0000-0000000000e1'),('d10e0000-0000-0000-0000-0000000000e2'),
  ('d10e0000-0000-0000-0000-0000000000e3'),('d10e0000-0000-0000-0000-0000000000e4'),
  ('d10e0000-0000-0000-0000-0000000000e5'),('d10e0000-0000-0000-0000-0000000000e6'),
  ('d10e0000-0000-0000-0000-0000000000e7'),('d10e0000-0000-0000-0000-0000000000e8');
insert into profiles (id, email)
  select id, id::text||'@example.com' from auth.users where id::text like 'd10e0000%';

insert into studios (id, name, slug, timezone, currency, status) values
  ('d10e0000-0000-0000-0000-000000000001','Fee E','d10e-s','Asia/Manila','PHP','active');
insert into studio_settings (studio_id, free_first_class_enabled, require_waiver,
                             cancellation_cutoff_minutes, dropin_payment_window_minutes,
                             free_first_reservation_fee_cents, free_first_confirm_at,
                             free_first_reservation_from) values
  ('d10e0000-0000-0000-0000-000000000001', true, false, 720, 15, 50000, null,
   (now() at time zone 'Asia/Manila')::date);
insert into locations (id, studio_id, name, is_primary) values
  ('d10e0000-0000-0000-0000-00000000000a','d10e0000-0000-0000-0000-000000000001','Main',true);
insert into studio_staff (studio_id, user_id, email, role) values
  ('d10e0000-0000-0000-0000-000000000001','d10e0000-0000-0000-0000-0000000000a1','d10e-ow@example.com','owner');
insert into members (id, studio_id, user_id, first_name, last_name, email, status) values
  ('d10e0000-0000-0000-0000-0000000000f1','d10e0000-0000-0000-0000-000000000001','d10e0000-0000-0000-0000-0000000000e1','M','One','e1@example.com','lead'),
  ('d10e0000-0000-0000-0000-0000000000f2','d10e0000-0000-0000-0000-000000000001','d10e0000-0000-0000-0000-0000000000e2','M','Two','e2@example.com','lead'),
  ('d10e0000-0000-0000-0000-0000000000f3','d10e0000-0000-0000-0000-000000000001','d10e0000-0000-0000-0000-0000000000e3','M','Three','e3@example.com','lead'),
  ('d10e0000-0000-0000-0000-0000000000f4','d10e0000-0000-0000-0000-000000000001','d10e0000-0000-0000-0000-0000000000e4','M','Four','e4@example.com','lead'),
  ('d10e0000-0000-0000-0000-0000000000f5','d10e0000-0000-0000-0000-000000000001','d10e0000-0000-0000-0000-0000000000e5','M','Five','e5@example.com','lead'),
  ('d10e0000-0000-0000-0000-0000000000f6','d10e0000-0000-0000-0000-000000000001','d10e0000-0000-0000-0000-0000000000e6','M','Six','e6@example.com','lead'),
  ('d10e0000-0000-0000-0000-0000000000f7','d10e0000-0000-0000-0000-000000000001','d10e0000-0000-0000-0000-0000000000e7','M','Seven','e7@example.com','lead'),
  ('d10e0000-0000-0000-0000-0000000000f8','d10e0000-0000-0000-0000-000000000001','d10e0000-0000-0000-0000-0000000000e8','M','Eight','e8@example.com','lead');
insert into studio_payment_providers
  (studio_id, provider, secret_key_ciphertext, callback_token_ciphertext, callback_token_sha256,
   key_last4, test_mode, connected_by) values
  ('d10e0000-0000-0000-0000-000000000001','xendit','v1.x','v1.y',
   encode(digest('tok','sha256'),'hex'), 'tok0', true, 'd10e0000-0000-0000-0000-0000000000a1');
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('d10e0000-0000-0000-0000-0000000cf001','d10e0000-0000-0000-0000-000000000001','Reformer',50,20);
-- eight rooms, so no occurrence shares a slot.
insert into rooms (id, studio_id, location_id, name, capacity)
  select ('d10e0000-0000-0000-0000-00000000b00'||g)::uuid,'d10e0000-0000-0000-0000-000000000001',
         'd10e0000-0000-0000-0000-00000000000a','R'||g, 20 from generate_series(1,8) g;
-- c1..c7 future (each own room); c4 is capacity 1 (for the full-class credit case).
insert into class_occurrences (id, studio_id, class_type_id, room_id, location_id, name, starts_at, ends_at,
                               capacity, status, staffing)
  select ('d10e0000-0000-0000-0000-00000000c00'||g)::uuid,'d10e0000-0000-0000-0000-000000000001',
         'd10e0000-0000-0000-0000-0000000cf001',('d10e0000-0000-0000-0000-00000000b00'||g)::uuid,
         'd10e0000-0000-0000-0000-00000000000a','Reformer Flow',
         now()+(g||' day')::interval, now()+(g||' day')::interval+interval '50 min',
         case when g=4 then 1 else 20 end,'scheduled','assigned'
    from generate_series(1,7) g;

-- =============================================================================
-- 1. HOLD OUTLIVES booked_at+15min WHILE THE INVOICE IS OPEN (hold_until governs).
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','d10e0000-0000-0000-0000-0000000000e1',false);
select set_config('t.bk1', (reserve_free_first('d10e0000-0000-0000-0000-00000000c001') ->> 'booking_id'), false);
select set_config('t.pur1', (select purchase_id::text from xendit_begin_reservation(
   'd10e0000-0000-0000-0000-000000000001', current_setting('t.bk1')::uuid)), false);
select set_config('request.jwt.claim.sub','',false); reset role;
-- xendit_begin_reservation set hold_until 30 min out and hold_reason 'reservation'.
select expect_true('hold: hold_until is set ~30 min out',
  (select hold_until > now() + interval '25 min' from bookings where id = current_setting('t.bk1')::uuid));
select expect_text('hold: hold_reason reservation',
  (select hold_reason from bookings where id = current_setting('t.bk1')::uuid), 'reservation');
-- Age booked_at past the 15-min window but keep hold_until in the future.
update bookings set booked_at = now() - interval '20 min' where id = current_setting('t.bk1')::uuid;
select sweep_unpaid_dropins();
select expect_text('hold outlives 15 min while the invoice is open (still pending_payment)',
  (select status::text from bookings where id = current_setting('t.bk1')::uuid), 'pending_payment');
-- Past hold_until: the sweep cancels it.
update bookings set hold_until = now() - interval '1 min' where id = current_setting('t.bk1')::uuid;
select sweep_unpaid_dropins();
select expect_text('past hold_until, the sweep cancels the hold',
  (select status::text from bookings where id = current_setting('t.bk1')::uuid), 'cancelled');

-- =============================================================================
-- 2. A XENDIT EXPIRY RELEASES THE HOLD AT ONCE.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','d10e0000-0000-0000-0000-0000000000e2',false);
select set_config('t.bk2', (reserve_free_first('d10e0000-0000-0000-0000-00000000c002') ->> 'booking_id'), false);
select set_config('t.pur2', (select purchase_id::text from xendit_begin_reservation(
   'd10e0000-0000-0000-0000-000000000001', current_setting('t.bk2')::uuid)), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select xendit_fail_purchase_internal(current_setting('t.pur2')::uuid, 'expired', 'session_expired');
select expect_text('invoice expiry releases the hold at once (cancelled, no sweep)',
  (select status::text from bookings where id = current_setting('t.bk2')::uuid), 'cancelled');

-- =============================================================================
-- 3. LATE SUCCESS WITH A FREE SEAT RESTORES AND CONFIRMS.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','d10e0000-0000-0000-0000-0000000000e3',false);
select set_config('t.bk3', (reserve_free_first('d10e0000-0000-0000-0000-00000000c003') ->> 'booking_id'), false);
select set_config('t.pur3', (select purchase_id::text from xendit_begin_reservation(
   'd10e0000-0000-0000-0000-000000000001', current_setting('t.bk3')::uuid)), false);
select set_config('request.jwt.claim.sub','',false); reset role;
-- The sweep released the hold before the payment landed.
select cancel_booking(current_setting('t.bk3')::uuid);
select expect_text('restore: the hold was released first', (select status::text from bookings where id=current_setting('t.bk3')::uuid), 'cancelled');
-- The late payment arrives: restore + confirm through the real completion.
select d10e_complete(current_setting('t.bk3')::uuid);
select expect_text('late success + free seat: booking restored to booked',
  (select status::text from bookings where id=current_setting('t.bk3')::uuid), 'booked');
select expect_text('restored booking is confirmed (confirm_at null)',
  (select (confirmed_at is not null)::text from bookings where id=current_setting('t.bk3')::uuid), 'true');
select expect_num('restore writes the once-ever host-null guest pass', (select count(*) from guest_passes
  where guest_booking_id=current_setting('t.bk3')::uuid and host_member_id is null), 1);
select expect_num('restore: the reservation fee is succeeded', (select count(*) from payments
  where booking_id=current_setting('t.bk3')::uuid and kind='reservation_fee' and status='succeeded'), 1);
select expect_num('restore: a free_booking_confirmed is queued', (select count(*) from notifications
  where member_id='d10e0000-0000-0000-0000-0000000000f3' and template_key='free_booking_confirmed'), 1);
select expect_num('restore: an audit reservation.restored row', (select count(*) from audit_logs
  where action='reservation.restored' and entity_id=current_setting('t.bk3')::uuid), 1);

-- =============================================================================
-- 4. LATE SUCCESS WITH A FULL CLASS CREDITS THE FEE + THE LOST-SEAT EMAIL.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','d10e0000-0000-0000-0000-0000000000e4',false);
select set_config('t.bk4', (reserve_free_first('d10e0000-0000-0000-0000-00000000c004') ->> 'booking_id'), false);
select set_config('t.pur4', (select purchase_id::text from xendit_begin_reservation(
   'd10e0000-0000-0000-0000-000000000001', current_setting('t.bk4')::uuid)), false);
select set_config('request.jwt.claim.sub','',false); reset role;
-- The hold is released, then the single seat is taken by someone else (M7).
select cancel_booking(current_setting('t.bk4')::uuid);
set role authenticated; select set_config('request.jwt.claim.sub','d10e0000-0000-0000-0000-0000000000e7',false);
select set_config('t.bk7', (book_first_free('d10e0000-0000-0000-0000-00000000c004') ->> 'booking_id'), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_num('c4 now full (capacity 1)', (select booked_count from class_occurrences where id='d10e0000-0000-0000-0000-00000000c004'), 1);
-- The late payment arrives: no seat -> credit + email, booking stays cancelled.
select d10e_complete(current_setting('t.bk4')::uuid);
select expect_text('full class: the booking stays cancelled',
  (select status::text from bookings where id=current_setting('t.bk4')::uuid), 'cancelled');
select expect_num('full class: the fee becomes a reservation credit', (select count(*) from member_credits
  where booking_id=current_setting('t.bk4')::uuid and reason='reservation_lost_seat' and amount_cents=50000), 1);
select expect_num('full class: the lost-seat email is queued', (select count(*) from notifications
  where member_id='d10e0000-0000-0000-0000-0000000000f4' and template_key='free_reservation_lost_seat'), 1);

-- =============================================================================
-- 5. CREDIT OF AT LEAST THE FEE BOOKS WITHOUT XENDIT AND CONSUMES THE CREDIT.
-- =============================================================================
insert into member_credits (studio_id, member_id, amount_cents, used_cents, currency, reason)
  values ('d10e0000-0000-0000-0000-000000000001','d10e0000-0000-0000-0000-0000000000f5',50000,0,'PHP','reservation_credit');
set role authenticated; select set_config('request.jwt.claim.sub','d10e0000-0000-0000-0000-0000000000e5',false);
select set_config('t.r5', reserve_free_first('d10e0000-0000-0000-0000-00000000c005')::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select set_config('t.bk5', (current_setting('t.r5')::jsonb ->> 'booking_id'), false);
select expect_text('credit covers the fee: credit_covered true',
  (current_setting('t.r5')::jsonb ->> 'credit_covered'), 'true');
select expect_text('credit-covered booking is booked comp',
  (select status::text from bookings where id=current_setting('t.bk5')::uuid), 'booked');
select expect_num('credit-covered: NO xendit purchase', (select count(*) from xendit_purchases where booking_id=current_setting('t.bk5')::uuid), 0);
select expect_num('credit-covered: the credit is consumed (50000 used)', (select coalesce(sum(used_cents),0) from member_credits
  where member_id='d10e0000-0000-0000-0000-0000000000f5' and reason='reservation_credit'), 50000);
select expect_num('credit-covered: an audit reservation.credit_used row', (select count(*) from audit_logs
  where action='reservation.credit_used' and entity_id=current_setting('t.bk5')::uuid), 1);
select expect_num('credit-covered: the once-ever guest pass is written', (select count(*) from guest_passes
  where guest_booking_id=current_setting('t.bk5')::uuid and host_member_id is null), 1);

-- =============================================================================
-- 6. CREDIT BELOW THE FEE STILL CHARGES (the normal hold path).
-- =============================================================================
insert into member_credits (studio_id, member_id, amount_cents, used_cents, currency, reason)
  values ('d10e0000-0000-0000-0000-000000000001','d10e0000-0000-0000-0000-0000000000f6',20000,0,'PHP','reservation_credit');
set role authenticated; select set_config('request.jwt.claim.sub','d10e0000-0000-0000-0000-0000000000e6',false);
select set_config('t.r6', reserve_free_first('d10e0000-0000-0000-0000-00000000c006')::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('credit below the fee: credit_covered is not set (normal path)',
  coalesce(current_setting('t.r6')::jsonb ->> 'credit_covered', 'none'), 'none');
select expect_text('credit below the fee: a pending_payment hold is created',
  (select status::text from bookings where id=(current_setting('t.r6')::jsonb ->> 'booking_id')::uuid), 'pending_payment');

-- =============================================================================
-- 7. THE JOURNEY LINES (a hold is never Booked) + 8. THE RELABEL.
-- =============================================================================
-- M3 restored: has reservation_fee_paid + reservation_restored + free_first (booked), not a 'booked' hold.
select expect_true('journey M3: reservation_fee_paid', d10e_has_kind('d10e0000-0000-0000-0000-0000000000f3','reservation_fee_paid'));
select expect_true('journey M3: reservation_restored',  d10e_has_kind('d10e0000-0000-0000-0000-0000000000f3','reservation_restored'));
-- M6 holds a live hold -> reservation_hold, never 'booked' (the relabel of a hold).
select expect_true('journey M6: reservation_hold (relabel)', d10e_has_kind('d10e0000-0000-0000-0000-0000000000f6','reservation_hold'));
select expect_true('journey M6: NOT booked for the hold',
  not exists (select 1 from member_activity('d10e0000-0000-0000-0000-0000000000f6','2000-01-01','2100-01-01')
              where kind='booked' and booking_id=(current_setting('t.r6')::jsonb ->> 'booking_id')::uuid));
-- M2 released its hold, never paid -> hold_released.
select expect_true('journey M2: hold_released', d10e_has_kind('d10e0000-0000-0000-0000-0000000000f2','hold_released'));
-- M4 credited (lost seat) -> reservation_credit_back.
select expect_true('journey M4: reservation_credit_back', d10e_has_kind('d10e0000-0000-0000-0000-0000000000f4','reservation_credit_back'));
-- M5 credit used -> reservation_credit_used.
select expect_true('journey M5: reservation_credit_used', d10e_has_kind('d10e0000-0000-0000-0000-0000000000f5','reservation_credit_used'));
-- M8 reserves + completes, then no-shows with the fee kept -> reservation_fee_kept.
set role authenticated; select set_config('request.jwt.claim.sub','d10e0000-0000-0000-0000-0000000000e8',false);
select set_config('t.bk8', (reserve_free_first('d10e0000-0000-0000-0000-00000000c007') ->> 'booking_id'), false);
select set_config('t.pur8', (select purchase_id::text from xendit_begin_reservation(
   'd10e0000-0000-0000-0000-000000000001', current_setting('t.bk8')::uuid)), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select d10e_complete(current_setting('t.bk8')::uuid);
update bookings set status='no_show', no_show_at=now() where id=current_setting('t.bk8')::uuid;
select expect_true('journey M8: reservation_fee_kept (no-show, no credit)',
  d10e_has_kind('d10e0000-0000-0000-0000-0000000000f8','reservation_fee_kept'));

-- =============================================================================
-- 9. SALES: reservation fees grouped + listed.
-- =============================================================================
select set_config('t.today', (now() at time zone 'Asia/Manila')::date::text, false);
select expect_true('sales_history lists a reservation_fee row with the class',
  exists (select 1 from sales_history('d10e0000-0000-0000-0000-000000000001',
            current_setting('t.today')::date, current_setting('t.today')::date)
          where plan_type='reservation_fee' and plan_name like 'Reservation%'));
-- M3, M4 and M8 paid online (real money received, even M4's whose fee later became
-- credit); M5 was credit-covered (no payment) so it is NOT counted.
select expect_num('sales_totals.reservation_fees count = the three online fees',
  ((sales_totals('d10e0000-0000-0000-0000-000000000001', current_setting('t.today')::date,
     current_setting('t.today')::date) -> 'reservation_fees' ->> 'count'))::bigint, 3);
select expect_num('sales_totals.reservation_fees total = 150000',
  ((sales_totals('d10e0000-0000-0000-0000-000000000001', current_setting('t.today')::date,
     current_setting('t.today')::date) -> 'reservation_fees' ->> 'total_cents'))::bigint, 150000);

-- =============================================================================
-- 10. PROFILE: member_reservation_fees — the five states.
-- =============================================================================
-- M3: paid + restored (seat held) -> 'held'. M8: paid + kept -> 'kept'. M4: the
-- lost-seat credit is on a member_credits row whose payment_id links the fee ->
-- 'credited'. Add a refunded fee and a used credit for the two remaining states.
select expect_text('profile M3 fee state held',
  (select state from member_reservation_fees('d10e0000-0000-0000-0000-0000000000f3') limit 1), 'held');
select expect_text('profile M8 fee state kept',
  (select state from member_reservation_fees('d10e0000-0000-0000-0000-0000000000f8') limit 1), 'kept');
select expect_text('profile M4 fee state credited',
  (select state from member_reservation_fees('d10e0000-0000-0000-0000-0000000000f4') limit 1), 'credited');
-- refunded: refund M3's fee.
select set_config('t.pay3', (select id::text from payments where booking_id=current_setting('t.bk3')::uuid and kind='reservation_fee'), false);
update payments set refunded_cents=50000, refunded_at=now(), status='refunded' where id=current_setting('t.pay3')::uuid;
select expect_text('profile M3 fee state refunded after a refund',
  (select state from member_reservation_fees('d10e0000-0000-0000-0000-0000000000f3') limit 1), 'refunded');
-- used: M4's lost-seat credit fully consumed -> 'used'.
update member_credits set used_cents=amount_cents where member_id='d10e0000-0000-0000-0000-0000000000f4' and reason='reservation_lost_seat';
select expect_text('profile M4 fee state used after the credit is consumed',
  (select state from member_reservation_fees('d10e0000-0000-0000-0000-0000000000f4') limit 1), 'used');

-- =============================================================================
-- 11. ANON STAYS EXACTLY THIRTEEN.
-- =============================================================================
select expect_num('anon surface is exactly thirteen',
  (select count(*) from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
    where ns.nspname='public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not in ('expect_num','expect_text','expect_true','d10e_complete','d10e_has_kind')), 13);

select 'reservation_e_test PASS' as result;
