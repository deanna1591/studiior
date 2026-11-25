-- =============================================================================
-- Decision 103(c) — an unpaid reservation hold never looks booked
-- (migration 20260833490000). UUID space d10c, checked free.
-- =============================================================================
-- Covers: a reservation hold reads as 'pending_payment' (not 'booked') in
-- member_pending_bookings, with a hold expiry and NO flex deadline; it is absent
-- from the roster/digest attendee count while it holds a seat for capacity; a
-- re-tap of book_class on the held class fails (the app swaps that to the
-- "finish paying, or cancel" line because a hold is present); cancel releases the
-- hold and frees the seat; the sweep cancels the hold AND expires the matching
-- pending xendit purchase; and a BOOKED free seat that owes the fee is still
-- booked and shows the fee due (pay-to-keep). Anon stays FIFTEEN.
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

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('d10c0000-0000-0000-0000-0000000000a1'),  -- owner
  ('d10c0000-0000-0000-0000-0000000000e1'),  -- M1 hold
  ('d10c0000-0000-0000-0000-0000000000e2'),  -- M2 pay-to-keep
  ('d10c0000-0000-0000-0000-0000000000e3');  -- M3 sweep
insert into profiles (id, email)
  select id, id::text||'@example.com' from auth.users where id::text like 'd10c0000%';

insert into studios (id, name, slug, timezone, currency, status) values
  ('d10c0000-0000-0000-0000-000000000001','Hold A','d10c-s','Asia/Manila','PHP','active');
insert into studio_settings (studio_id, free_first_class_enabled, require_waiver,
                             cancellation_cutoff_minutes, dropin_payment_window_minutes,
                             free_first_reservation_fee_cents, free_first_reservation_from) values
  ('d10c0000-0000-0000-0000-000000000001', true, false, 720, 15, 0,
   (now() at time zone 'Asia/Manila')::date);
insert into locations (id, studio_id, name, is_primary) values
  ('d10c0000-0000-0000-0000-00000000000a','d10c0000-0000-0000-0000-000000000001','Main',true);
insert into studio_staff (studio_id, user_id, email, role) values
  ('d10c0000-0000-0000-0000-000000000001','d10c0000-0000-0000-0000-0000000000a1','d10c-ow@example.com','owner');
insert into members (id, studio_id, user_id, first_name, last_name, email, status) values
  ('d10c0000-0000-0000-0000-0000000000f1','d10c0000-0000-0000-0000-000000000001','d10c0000-0000-0000-0000-0000000000e1','Mem','One','h1@example.com','lead'),
  ('d10c0000-0000-0000-0000-0000000000f2','d10c0000-0000-0000-0000-000000000001','d10c0000-0000-0000-0000-0000000000e2','Mem','Two','h2@example.com','lead'),
  ('d10c0000-0000-0000-0000-0000000000f3','d10c0000-0000-0000-0000-000000000001','d10c0000-0000-0000-0000-0000000000e3','Mem','Three','h3@example.com','lead');

insert into studio_payment_providers
  (studio_id, provider, secret_key_ciphertext, callback_token_ciphertext, callback_token_sha256,
   key_last4, test_mode, connected_by) values
  ('d10c0000-0000-0000-0000-000000000001','xendit','v1.x','v1.y',
   encode(digest('goodtoken','sha256'),'hex'), 'tok0', true, 'd10c0000-0000-0000-0000-0000000000a1');

insert into rooms (id, studio_id, location_id, name, capacity) values
  ('d10c0000-0000-0000-0000-00000000b001','d10c0000-0000-0000-0000-000000000001','d10c0000-0000-0000-0000-00000000000a','Studio',20),
  ('d10c0000-0000-0000-0000-00000000b002','d10c0000-0000-0000-0000-000000000001','d10c0000-0000-0000-0000-00000000000a','Studio 2',20),
  ('d10c0000-0000-0000-0000-00000000b003','d10c0000-0000-0000-0000-000000000001','d10c0000-0000-0000-0000-00000000000a','Studio 3',20);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('d10c0000-0000-0000-0000-0000000cf001','d10c0000-0000-0000-0000-000000000001','Reformer',50,20);
-- c1 (M1 hold), c2 (M2 pay-to-keep), c3 (M3 sweep) — each in its own room, future.
insert into class_occurrences (id, studio_id, class_type_id, room_id, location_id, name, starts_at, ends_at,
                               capacity, status, staffing) values
  ('d10c0000-0000-0000-0000-00000000c001','d10c0000-0000-0000-0000-000000000001','d10c0000-0000-0000-0000-0000000cf001','d10c0000-0000-0000-0000-00000000b001','d10c0000-0000-0000-0000-00000000000a','Reformer Flow', now()+interval '3 day', now()+interval '3 day'+interval '50 min', 20,'scheduled','assigned'),
  ('d10c0000-0000-0000-0000-00000000c002','d10c0000-0000-0000-0000-000000000001','d10c0000-0000-0000-0000-0000000cf001','d10c0000-0000-0000-0000-00000000b002','d10c0000-0000-0000-0000-00000000000a','Reformer Flow', now()+interval '4 day', now()+interval '4 day'+interval '50 min', 20,'scheduled','assigned'),
  ('d10c0000-0000-0000-0000-00000000c003','d10c0000-0000-0000-0000-000000000001','d10c0000-0000-0000-0000-0000000cf001','d10c0000-0000-0000-0000-00000000b003','d10c0000-0000-0000-0000-00000000000a','Reformer Flow', now()+interval '5 day', now()+interval '5 day'+interval '50 min', 20,'scheduled','assigned');

-- =============================================================================
-- 1. PAY-TO-KEEP: with the fee OFF, M2 books their free class (booked comp +
--    guest_pass); then the fee is turned on, and member_reservation_dues shows
--    the booking is STILL booked and owes the fee.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','d10c0000-0000-0000-0000-0000000000e2',false);
select set_config('t.bk2', (book_first_free('d10c0000-0000-0000-0000-00000000c002') ->> 'booking_id'), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('pay-to-keep: free booking is booked',
  (select status::text from bookings where id = current_setting('t.bk2')::uuid), 'booked');

update studio_settings set free_first_reservation_fee_cents = 15000
 where studio_id = 'd10c0000-0000-0000-0000-000000000001';

set role authenticated; select set_config('request.jwt.claim.sub','d10c0000-0000-0000-0000-0000000000e2',false);
select set_config('t.due', coalesce((select fee_cents::text from member_reservation_dues('d10c0000-0000-0000-0000-000000000001')
   where booking_id = current_setting('t.bk2')::uuid), 'none'), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('pay-to-keep: member_reservation_dues shows the fee due', current_setting('t.due'), '15000');
select expect_text('pay-to-keep: the booking is STILL booked (not a hold)',
  (select status::text from bookings where id = current_setting('t.bk2')::uuid), 'booked');

-- =============================================================================
-- 2. HOLD: M1 reserves c1 (fee on) -> a pending_payment comp hold with a xendit
--    purchase. member_pending_bookings shows it as pending_payment, with a hold
--    expiry and NO flex deadline. It holds a seat for capacity but is absent
--    from the roster/digest attendee count.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','d10c0000-0000-0000-0000-0000000000e1',false);
select set_config('t.bk1', (reserve_free_first('d10c0000-0000-0000-0000-00000000c001') ->> 'booking_id'), false);
select set_config('t.pur1', (select purchase_id::text from xendit_begin_reservation(
   'd10c0000-0000-0000-0000-000000000001', current_setting('t.bk1')::uuid)), false);
select set_config('t.st1', (select status from member_pending_bookings('d10c0000-0000-0000-0000-000000000001')
   where occurrence_id = 'd10c0000-0000-0000-0000-00000000c001'), false);
select set_config('t.hu1', (select (hold_until is not null)::text from member_pending_bookings('d10c0000-0000-0000-0000-000000000001')
   where occurrence_id = 'd10c0000-0000-0000-0000-00000000c001'), false);
select set_config('t.pu1', (select (pending_until is null)::text from member_pending_bookings('d10c0000-0000-0000-0000-000000000001')
   where occurrence_id = 'd10c0000-0000-0000-0000-00000000c001'), false);
select set_config('t.cnt1', (select count(*)::text from member_pending_bookings('d10c0000-0000-0000-0000-000000000001')
   where occurrence_id = 'd10c0000-0000-0000-0000-00000000c001'), false);
-- re-tap: book_class on the held class fails (the app swaps the reason to the
-- "finish paying, or cancel the hold" line because a pending_payment hold exists).
select set_config('t.retap', coalesce((book_class('d10c0000-0000-0000-0000-00000000c001','d10c0000-0000-0000-0000-0000000000f1','member')).failure_reason, 'none'), false);
select set_config('request.jwt.claim.sub','',false); reset role;

select expect_text('hold: member_pending_bookings reads pending_payment, not booked', current_setting('t.st1'), 'pending_payment');
select expect_text('hold: it carries a hold expiry', current_setting('t.hu1'), 'true');
select expect_text('hold: it carries NO flex deadline (pending_until null)', current_setting('t.pu1'), 'true');
select expect_text('hold: exactly one row for the class (never a second booked row)', current_setting('t.cnt1'), '1');
select expect_num('hold: the member has NO booked booking on the held class',
  (select count(*) from bookings where occurrence_id = 'd10c0000-0000-0000-0000-00000000c001'
     and member_id = 'd10c0000-0000-0000-0000-0000000000f1' and status = 'booked'), 0);
select expect_num('hold: it holds a seat for capacity (booked_count bumped)',
  (select booked_count from class_occurrences where id = 'd10c0000-0000-0000-0000-00000000c001'), 1);
select expect_num('hold: absent from the roster/digest attendee count (booked/attended)',
  (select count(*) from bookings where occurrence_id = 'd10c0000-0000-0000-0000-00000000c001'
     and status in ('booked','attended')), 0);
-- The re-tap: book_class refused (the row is not re-booked), and a hold is present
-- in member_pending_bookings -> the app shows the retap line, not "already on the list".
select expect_true('retap: book_class on the held class is refused (reason set)',
  current_setting('t.retap') <> 'none');
select expect_num('retap: still exactly one (held) booking, no second seat',
  (select count(*) from bookings where occurrence_id = 'd10c0000-0000-0000-0000-00000000c001'
     and member_id = 'd10c0000-0000-0000-0000-0000000000f1'), 1);

-- =============================================================================
-- 3. CANCEL releases the hold and frees the seat.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','d10c0000-0000-0000-0000-0000000000e1',false);
select set_config('t.cx', (cancel_booking(current_setting('t.bk1')::uuid))::text, false);
select set_config('t.pend1b', (select count(*)::text from member_pending_bookings('d10c0000-0000-0000-0000-000000000001')
   where occurrence_id = 'd10c0000-0000-0000-0000-00000000c001'), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('cancel: the held booking is cancelled',
  (select status::text from bookings where id = current_setting('t.bk1')::uuid), 'cancelled');
select expect_num('cancel: the seat is freed (booked_count back to 0)',
  (select booked_count from class_occurrences where id = 'd10c0000-0000-0000-0000-00000000c001'), 0);
select expect_text('cancel: the hold no longer appears in member_pending_bookings',
  current_setting('t.pend1b'), '0');

-- =============================================================================
-- 4. SWEEP: M3 holds c3; past the window, sweep_unpaid_dropins cancels the hold
--    AND expires the matching pending xendit purchase.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','d10c0000-0000-0000-0000-0000000000e3',false);
select set_config('t.bk3', (reserve_free_first('d10c0000-0000-0000-0000-00000000c003') ->> 'booking_id'), false);
select set_config('t.pur3', (select purchase_id::text from xendit_begin_reservation(
   'd10c0000-0000-0000-0000-000000000001', current_setting('t.bk3')::uuid)), false);
select set_config('request.jwt.claim.sub','',false); reset role;
-- Decision 103(e): a reservation hold lasts until its hold_until (the 30-minute
-- Xendit invoice window), not the 15-minute booked_at drop-in window, so the slow
-- payment can still land. Age hold_until past now; the sweep cancels only then.
update bookings set hold_until = now() - interval '1 min', booked_at = now() - interval '40 min'
   where id = current_setting('t.bk3')::uuid;
select set_config('t.sweep', sweep_unpaid_dropins()::text, false);
select expect_text('sweep: the aged hold is cancelled',
  (select status::text from bookings where id = current_setting('t.bk3')::uuid), 'cancelled');
select expect_text('sweep: the pending xendit purchase is expired',
  (select status from xendit_purchases where id = current_setting('t.pur3')::uuid), 'expired');
select expect_text('sweep: the expired purchase is marked hold_released',
  (select failure_reason from xendit_purchases where id = current_setting('t.pur3')::uuid), 'hold_released');
select expect_num('sweep: the seat is freed',
  (select booked_count from class_occurrences where id = 'd10c0000-0000-0000-0000-00000000c003'), 0);

-- =============================================================================
-- 5. GUARDS + anon FIFTEEN.
-- =============================================================================
do $t$ begin
  begin
    perform member_pending_bookings('d10c0000-0000-0000-0000-000000000001');
    raise exception 'FAIL  anon could read member_pending_bookings';
  exception when others then
    if sqlstate = '42501' then raise notice 'PASS  anon cannot execute member_pending_bookings (no grant)';
    else raise notice 'PASS  anon refused member_pending_bookings (%)', sqlstate; end if;
  end;
end $t$ language plpgsql;

select expect_num('anon surface EXACTLY FIFTEEN', (
  select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not in ('expect_num','expect_text','expect_true')
), 15);

\echo 'reservation_hold_test: all assertions passed'
