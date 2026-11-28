-- =============================================================================
-- Step 14 (migration 20260833760000): 103 (m) a settled free first class counts
-- and is never released, 103 (n) pays at the studio, 103 (o) check-in returns
-- credit for a covered seat, 21 (g) run a cancelled class anyway, 108 (d).
-- =============================================================================
-- UUID space 14f0, checked free. Run after `supabase db reset`.
--
-- Built from the real cases: Kai's Sat 28 Nov 07:00 (two first-timers, ₱500
-- paid each, flex minimum 2, confirm-at 3) runs and nobody is released; a free
-- seat whose fee is still unpaid is released at the cut-off and the class is
-- cancelled, then Run it anyway brings both seats back with no double credit;
-- pays at the studio confirms and counts with no emails and no release; Paid at
-- studio records the fee and check-in then returns it; a covered seat checked
-- in gets its credit back and a no-show keeps it; the daily check names both
-- watchdog items; a studio cancel is never offered Run it anyway.
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
  ('14f00000-0000-0000-0000-0000000000a1'),  -- owner
  ('14f00000-0000-0000-0000-0000000000a2'),  -- front desk
  ('14f00000-0000-0000-0000-0000000000a3');  -- Kai (instructor)
insert into profiles (id, email)
  select id, id::text || '@example.com' from auth.users where id::text like '14f00000%';

insert into studios (id, name, slug, timezone, currency, status) values
  ('14f00000-0000-0000-0000-000000000001','Step Fourteen','s14-studio','Asia/Manila','PHP','active');
insert into studio_settings (studio_id, free_first_class_enabled, require_waiver, cancellation_cutoff_minutes,
                             flex_enabled, flex_min_bookings, flex_deadline_mode, flex_deadline_hours,
                             free_first_confirm_at, free_first_reservation_fee_cents, free_first_reservation_from)
values ('14f00000-0000-0000-0000-000000000001', true, false, 720,
        true, 2, 'hours_before', 12, 3, 50000, current_date - 5);
insert into locations (id, studio_id, name, is_primary) values
  ('14f00000-0000-0000-0000-00000000000a','14f00000-0000-0000-0000-000000000001','Main',true);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('14f00000-0000-0000-0000-0000000005a1','14f00000-0000-0000-0000-000000000001','14f00000-0000-0000-0000-0000000000a1','s14-owner@example.com','owner'),
  ('14f00000-0000-0000-0000-0000000005a2','14f00000-0000-0000-0000-000000000001','14f00000-0000-0000-0000-0000000000a2','s14-desk@example.com','front_desk'),
  ('14f00000-0000-0000-0000-0000000005a3','14f00000-0000-0000-0000-000000000001','14f00000-0000-0000-0000-0000000000a3','s14-kai@example.com','instructor');
insert into instructors (id, studio_id, staff_id, display_name) values
  ('14f00000-0000-0000-0000-0000000000c1','14f00000-0000-0000-0000-000000000001','14f00000-0000-0000-0000-0000000005a3','Kai Coach');
insert into instructor_rate_versions (studio_id, instructor_id, effective_from, currency, base_rate_cents,
                                      per_head_rate_cents, per_head_threshold)
values ('14f00000-0000-0000-0000-000000000001','14f00000-0000-0000-0000-0000000000c1', current_date - 30, 'PHP', 90000, 7500, 2);

insert into members (id, studio_id, first_name, last_name, email, status)
select ('14f00000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid,
       '14f00000-0000-0000-0000-000000000001', 'First' || n, 'Timer', 's14-m' || n || '@example.com', 'lead'
  from generate_series(11, 22) n;

insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('14f00000-0000-0000-0000-0000000000f1','14f00000-0000-0000-0000-000000000001','Reformer',50,6);
insert into rooms (id, studio_id, location_id, name, capacity)
select ('14f00000-0000-0000-0000-00000000b00' || n)::uuid, '14f00000-0000-0000-0000-000000000001',
       '14f00000-0000-0000-0000-00000000000a', 'Room ' || n, 6
  from generate_series(1, 6) n;

-- A: Kai's 07:00, cut-off passed, not started.  B: same shape, one fee unpaid.
-- E: three days out (chips, pays at the studio, covered).  G: studio-cancelled.
insert into class_occurrences (id, studio_id, class_type_id, room_id, location_id, instructor_id, name,
                               starts_at, ends_at, capacity, status, staffing, flex, minimum_bookings)
values
  ('14f00000-0000-0000-0000-00000000c0a1','14f00000-0000-0000-0000-000000000001','14f00000-0000-0000-0000-0000000000f1','14f00000-0000-0000-0000-00000000b001','14f00000-0000-0000-0000-00000000000a','14f00000-0000-0000-0000-0000000000c1','REFORMER FLOW', now() + interval '2 hours', now() + interval '2 hours 50 minutes', 6, 'scheduled','assigned', true, 2),
  ('14f00000-0000-0000-0000-00000000c0b1','14f00000-0000-0000-0000-000000000001','14f00000-0000-0000-0000-0000000000f1','14f00000-0000-0000-0000-00000000b002','14f00000-0000-0000-0000-00000000000a','14f00000-0000-0000-0000-0000000000c1','REFORMER SCULPT', now() + interval '3 hours 10 minutes', now() + interval '4 hours', 6, 'scheduled','assigned', true, 2),
  ('14f00000-0000-0000-0000-00000000c0e1','14f00000-0000-0000-0000-000000000001','14f00000-0000-0000-0000-0000000000f1','14f00000-0000-0000-0000-00000000b003','14f00000-0000-0000-0000-00000000000a','14f00000-0000-0000-0000-0000000000c1','REFORMER BURN', now() + interval '3 days', now() + interval '3 days 50 minutes', 6, 'scheduled','assigned', true, 2),
  ('14f00000-0000-0000-0000-00000000c0d1','14f00000-0000-0000-0000-000000000001','14f00000-0000-0000-0000-0000000000f1','14f00000-0000-0000-0000-00000000b004','14f00000-0000-0000-0000-00000000000a','14f00000-0000-0000-0000-0000000000c1','REFORMER POWER', now() + interval '4 days', now() + interval '4 days 50 minutes', 6, 'scheduled','assigned', true, 2);

-- A free first seat: comp, provisional (confirm-at 3), with its host-null pass.
create or replace function s14_seat(p_booking uuid, p_occ uuid, p_member uuid) returns void language plpgsql as $$
begin
  insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source, provisional, booked_at)
  values (p_booking, '14f00000-0000-0000-0000-000000000001', p_occ, p_member, 'booked', 'comp', true, now() - interval '3 days');
  insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email, occurrence_id, guest_booking_id, status)
  select '14f00000-0000-0000-0000-000000000001', null, m.id, lower(m.email), p_occ, p_booking, 'confirmed'
    from members m where m.id = p_member;
  update class_occurrences set booked_count = occurrence_seats_taken(p_occ) where id = p_occ;
end $$;
create or replace function s14_fee(p_booking uuid) returns void language plpgsql as $$
begin
  insert into payments (studio_id, member_id, booking_id, kind, amount_cents, currency, status, provider, description, paid_at)
  select b.studio_id, b.member_id, b.id, 'reservation_fee', 50000, 'PHP', 'succeeded', 'xendit', 'Reservation fee', now() - interval '3 days'
    from bookings b where b.id = p_booking;
end $$;

-- =============================================================================
-- 1. 103 (m): Kai's case. Two first-timers, ₱500 paid each, flex minimum 2,
--    confirm-at 3. At the cut-off the class runs and nobody is released.
-- =============================================================================
select s14_seat('14f00000-0000-0000-0000-0000000b0a11','14f00000-0000-0000-0000-00000000c0a1','14f00000-0000-0000-0000-000000000011');
select s14_seat('14f00000-0000-0000-0000-0000000b0a12','14f00000-0000-0000-0000-00000000c0a1','14f00000-0000-0000-0000-000000000012');
select s14_fee('14f00000-0000-0000-0000-0000000b0a11');
select s14_fee('14f00000-0000-0000-0000-0000000b0a12');
select expect_num('a paid fee confirms the free seat at once (not provisional)',
  (select count(*) from bookings where occurrence_id = '14f00000-0000-0000-0000-00000000c0a1' and provisional), 0);

select set_config('t.a', (evaluate_commitment('14f00000-0000-0000-0000-00000000c0a1') ->> 'decision'), false);
select expect_text('Kai''s 07:00 is committed at the cut-off', current_setting('t.a'), 'committed');
select expect_num('both first-timers are still booked',
  (select count(*) from bookings where occurrence_id = '14f00000-0000-0000-0000-00000000c0a1' and status = 'booked'), 2);
select expect_num('no free seat was released',
  (select count(*) from bookings where occurrence_id = '14f00000-0000-0000-0000-00000000c0a1' and release_reason = 'trial_not_confirmed'), 0);
select expect_num('no reservation credit was written back',
  (select count(*) from member_credits where booking_id in ('14f00000-0000-0000-0000-0000000b0a11','14f00000-0000-0000-0000-0000000b0a12')), 0);
select expect_num('Kai is paid on two seats used (75 (l))',
  (select (basis ->> 'seats_used')::int from instructor_pay_records where occurrence_id = '14f00000-0000-0000-0000-00000000c0a1' and type = 'class'), 2);
select expect_num('Kai''s pay line is the base rate',
  (select amount_cents from instructor_pay_records where occurrence_id = '14f00000-0000-0000-0000-00000000c0a1' and type = 'class'), 90000);

-- =============================================================================
-- 2. An unpaid free seat is still released at the cut-off and does not count:
--    B has one paid first-timer and one unpaid, so it is cancelled.
-- =============================================================================
select s14_seat('14f00000-0000-0000-0000-0000000b0b13','14f00000-0000-0000-0000-00000000c0b1','14f00000-0000-0000-0000-000000000013');
select s14_seat('14f00000-0000-0000-0000-0000000b0b14','14f00000-0000-0000-0000-00000000c0b1','14f00000-0000-0000-0000-000000000014');
select s14_fee('14f00000-0000-0000-0000-0000000b0b14');
select set_config('t.b', (evaluate_commitment('14f00000-0000-0000-0000-00000000c0b1') ->> 'decision'), false);
select expect_text('B is not running (one settled seat, minimum 2)', current_setting('t.b'), 'not_running');
select expect_text('the unpaid first-timer was released',
  (select release_reason::text from bookings where id = '14f00000-0000-0000-0000-0000000b0b13'), 'trial_not_confirmed');
select expect_text('the paid first-timer was released by the class cancel, not the confirm-at rule',
  (select release_reason::text from bookings where id = '14f00000-0000-0000-0000-0000000b0b14'), 'studio_released');
select expect_num('the cancel returned the paid fee as credit',
  (select count(*) from member_credits where booking_id = '14f00000-0000-0000-0000-0000000b0b14' and voided_at is null), 1);

-- 108 (d) item 19 fires for B.
select expect_true('daily check: a flex class cancelled with a settled first-timer',
  (daily_money_check('14f00000-0000-0000-0000-000000000001') -> 'items')::text
    like '%Flex class cancelled at the cut-off with first-timers whose fee was settled:%');

-- =============================================================================
-- 3. 21 (g): Run it anyway brings B back, both seats, no double credit.
-- =============================================================================

set role authenticated; select set_config('request.jwt.claim.sub','14f00000-0000-0000-0000-0000000000a1',false);
select set_config('t.prev_offered', (run_anyway_preview('14f00000-0000-0000-0000-00000000c0b1') ->> 'offered'), false);
select set_config('t.prev_n', jsonb_array_length(run_anyway_preview('14f00000-0000-0000-0000-00000000c0b1') -> 'members')::text, false);
select set_config('t.run', (run_cancelled_class_anyway('14f00000-0000-0000-0000-00000000c0b1'))::text, false);
select set_config('t.run2', (run_cancelled_class_anyway('14f00000-0000-0000-0000-00000000c0b1') ->> 'reason'), false);
select set_config('request.jwt.claim.sub','',false); reset role;

select expect_text('the preview offers Run it anyway', current_setting('t.prev_offered'), 'true');
select expect_text('the preview lists the two who come back', current_setting('t.prev_n'), '2');
select expect_text('Run it anyway restored two seats', (current_setting('t.run')::jsonb ->> 'restored'), '2');
select expect_text('B is scheduled again', (select status::text from class_occurrences where id = '14f00000-0000-0000-0000-00000000c0b1'), 'scheduled');
select expect_text('B is pinned to run for that date', (select guarantee_tier::text from class_occurrences where id = '14f00000-0000-0000-0000-00000000c0b1'), 'always');
select expect_true('B is committed', (select committed_at is not null from class_occurrences where id = '14f00000-0000-0000-0000-00000000c0b1'));
select expect_num('both seats are booked and confirmed',
  (select count(*) from bookings where occurrence_id = '14f00000-0000-0000-0000-00000000c0b1' and status = 'booked' and not provisional), 2);
select expect_num('both free first classes are back on (host-null passes)',
  (select count(*) from guest_passes where guest_booking_id in ('14f00000-0000-0000-0000-0000000b0b13','14f00000-0000-0000-0000-0000000b0b14') and host_member_id is null), 2);
select expect_num('the returned credit is gone (the fee holds the seat again)',
  (select count(*) from member_credits where booking_id = '14f00000-0000-0000-0000-0000000b0b14'), 0);
select expect_num('the paid fee is still on the seat, no new charge',
  (select count(*) from payments where booking_id = '14f00000-0000-0000-0000-0000000b0b14' and kind = 'reservation_fee'), 1);
select expect_num('one "You''re still on" email to each restored member',
  (select count(*) from notifications where template_key = 'class_restored'
     and member_id in ('14f00000-0000-0000-0000-000000000013','14f00000-0000-0000-0000-000000000014')), 2);
select expect_num('one notice to Kai',
  (select count(*) from notifications where template_key = 'class_restored_coach'), 1);
select expect_text('a second press is refused, so nobody is emailed twice', current_setting('t.run2'), 'not_cancelled');
select expect_num('an occurrence.restored audit row',
  (select count(*) from audit_logs where action = 'occurrence.restored' and entity_id = '14f00000-0000-0000-0000-00000000c0b1'), 1);
select expect_num('Kai is paid on two seats used for B',
  (select (basis ->> 'seats_used')::int from instructor_pay_records where occurrence_id = '14f00000-0000-0000-0000-00000000c0b1' and type = 'class'), 2);
select expect_true('the restored email renders clean',
  (select coalesce(array_length(stripped, 1), 0) = 0 and subject = 'You''re still on for REFORMER SCULPT, First13'
     from render_notification((select id from notifications where template_key = 'class_restored'
                                 and member_id = '14f00000-0000-0000-0000-000000000013'))));

-- A studio-cancelled class is not offered.
update class_occurrences set status = 'cancelled', cancellation_cause = 'studio_fault', cancelled_at = now()
 where id = '14f00000-0000-0000-0000-00000000c0d1';
set role authenticated; select set_config('request.jwt.claim.sub','14f00000-0000-0000-0000-0000000000a1',false);
select set_config('t.g', (run_anyway_preview('14f00000-0000-0000-0000-00000000c0d1') ->> 'reason'), false);
select set_config('t.g2', (run_cancelled_class_anyway('14f00000-0000-0000-0000-00000000c0d1') ->> 'reason'), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('a studio cancel is not offered Run it anyway', current_setting('t.g'), 'not_offered');
select expect_text('a studio cancel is refused Run it anyway', current_setting('t.g2'), 'not_offered');

-- Front desk cannot run a cancelled class.
set role authenticated; select set_config('request.jwt.claim.sub','14f00000-0000-0000-0000-0000000000a2',false);
do $$ begin
  perform run_cancelled_class_anyway('14f00000-0000-0000-0000-00000000c0d1');
  raise exception 'FAIL  front desk ran a cancelled class';
exception when sqlstate 'PT403' then raise notice 'PASS  front desk cannot run a cancelled class (PT403)';
end $$;
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- 4. 103 (m) and (n) on a future class: a covered seat and a pays-at-the-studio
--    seat are confirmed, count in the chip and set the latch.
-- =============================================================================
select s14_seat('14f00000-0000-0000-0000-0000000b0e15','14f00000-0000-0000-0000-00000000c0e1','14f00000-0000-0000-0000-000000000015');
update bookings set reservation_credit_covered = true where id = '14f00000-0000-0000-0000-0000000b0e15';
insert into audit_logs (studio_id, action, entity_table, entity_id, after)
values ('14f00000-0000-0000-0000-000000000001','reservation.credit_used','bookings','14f00000-0000-0000-0000-0000000b0e15', jsonb_build_object('fee_cents', 50000));
select s14_seat('14f00000-0000-0000-0000-0000000b0e16','14f00000-0000-0000-0000-00000000c0e1','14f00000-0000-0000-0000-000000000016');

select expect_true('a covered seat is confirmed on booking',
  (select not provisional from bookings where id = '14f00000-0000-0000-0000-0000000b0e15'));
select expect_text('an unpaid seat reads not asked', free_seat_reservation_state_run('14f00000-0000-0000-0000-0000000b0e16') ->> 'state', 'not_asked');

set role authenticated; select set_config('request.jwt.claim.sub','14f00000-0000-0000-0000-0000000000a3',false);
do $$ begin
  perform set_free_fee_choice('14f00000-0000-0000-0000-0000000b0e16', 'studio', null);
  raise exception 'FAIL  a coach set pays at the studio';
exception when sqlstate 'PT403' then raise notice 'PASS  a coach cannot choose pays at the studio (PT403)';
end $$;
select set_config('request.jwt.claim.sub','14f00000-0000-0000-0000-0000000000a2',false);
select set_config('t.studio', (set_free_fee_choice('14f00000-0000-0000-0000-0000000b0e16', 'studio', 'cash at the desk') ->> 'state'), false);
select set_config('request.jwt.claim.sub','',false); reset role;

select expect_text('pays at the studio: the state is at_studio', current_setting('t.studio'), 'at_studio');
select expect_true('pays at the studio: confirmed, not provisional',
  (select not provisional from bookings where id = '14f00000-0000-0000-0000-0000000b0e16'));
select expect_num('the chip counts both settled first-timers', occurrence_paid_count_run('14f00000-0000-0000-0000-00000000c0e1'), 2);
select expect_true('the flex latch is set', (select flex_reached_minimum_at is not null from class_occurrences where id = '14f00000-0000-0000-0000-00000000c0e1'));
select expect_true('the member chip reads reached', (occurrence_flex_state_run('14f00000-0000-0000-0000-00000000c0e1') ->> 'reached_minimum')::boolean);
select expect_num('an audit row for pays at the studio',
  (select count(*) from audit_logs where action = 'reservation.pay_at_studio' and entity_id = '14f00000-0000-0000-0000-0000000b0e16'), 1);

select sweep_free_reservation_dues();
select expect_num('pays at the studio: no due, nudge, last call or release email',
  (select count(*) from notifications where dedupe_key like 'free_reservation_%:14f00000-0000-0000-0000-0000000b0e16%'), 0);
select expect_text('pays at the studio: still booked after the sweep',
  (select status::text from bookings where id = '14f00000-0000-0000-0000-0000000b0e16'), 'booked');

-- Paid at studio, as the coach, then check-in returns the fee as credit.
set role authenticated; select set_config('request.jwt.claim.sub','14f00000-0000-0000-0000-0000000000a3',false);
select set_config('t.paid', (record_reservation_paid_at_studio('14f00000-0000-0000-0000-0000000b0e16', 'cash', 'OR 123') ->> 'ok'), false);
select set_config('t.paid2', (record_reservation_paid_at_studio('14f00000-0000-0000-0000-0000000b0e16', 'cash', null) ->> 'reason'), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('the coach records Paid at studio', current_setting('t.paid'), 'true');
select expect_text('a second Paid at studio is refused', current_setting('t.paid2'), 'already_paid');
select expect_num('the fee is a succeeded payment of ₱500',
  (select amount_cents from payments where booking_id = '14f00000-0000-0000-0000-0000000b0e16' and kind = 'reservation_fee'), 50000);
select expect_text('the state is paid now', free_seat_reservation_state_run('14f00000-0000-0000-0000-0000000b0e16') ->> 'state', 'paid');

update class_occurrences set starts_at = now() - interval '10 minutes', ends_at = now() + interval '40 minutes'
 where id = '14f00000-0000-0000-0000-00000000c0e1';
update bookings set status = 'attended' where id = '14f00000-0000-0000-0000-0000000b0e16';
select expect_num('check-in returns the paid-at-studio fee as credit',
  (select amount_cents from member_credits where booking_id = '14f00000-0000-0000-0000-0000000b0e16'), 50000);

-- =============================================================================
-- 5. 103 (o): a covered seat checked in gets its credit back; a no-show keeps it.
-- =============================================================================
update bookings set status = 'attended' where id = '14f00000-0000-0000-0000-0000000b0e15';
select expect_num('a covered seat checked in gets ₱500 back',
  (select amount_cents from member_credits where booking_id = '14f00000-0000-0000-0000-0000000b0e15' and reason = 'reservation_credit'), 50000);
select expect_num('with one free_reservation_credited email',
  (select count(*) from notifications where dedupe_key = 'free_reservation_credited:14f00000-0000-0000-0000-0000000b0e15'), 1);

select s14_seat('14f00000-0000-0000-0000-0000000b0e17','14f00000-0000-0000-0000-00000000c0e1','14f00000-0000-0000-0000-000000000017');
update bookings set reservation_credit_covered = true where id = '14f00000-0000-0000-0000-0000000b0e17';
update bookings set status = 'no_show' where id = '14f00000-0000-0000-0000-0000000b0e17';
select expect_num('a covered no-show keeps the credit (nothing back)',
  (select count(*) from member_credits where booking_id = '14f00000-0000-0000-0000-0000000b0e17'), 0);

-- 108 (d) item 20: a pays-at-the-studio seat that came, with nothing recorded.
select s14_seat('14f00000-0000-0000-0000-0000000b0e18','14f00000-0000-0000-0000-00000000c0e1','14f00000-0000-0000-0000-000000000018');
update bookings set reservation_pay_at_studio = true where id = '14f00000-0000-0000-0000-0000000b0e18';
update bookings set status = 'no_show' where id = '14f00000-0000-0000-0000-0000000b0e18';
select expect_true('daily check: a reservation fee to collect at the studio',
  (daily_money_check('14f00000-0000-0000-0000-000000000001') -> 'items')::text
    like '%Reservation fee to collect at the studio: First18 Timer%');

-- Reverse order (Step 14 report): checked in first, then Paid at studio.
select s14_seat('14f00000-0000-0000-0000-0000000b0e19','14f00000-0000-0000-0000-00000000c0e1','14f00000-0000-0000-0000-000000000019');
update bookings set reservation_pay_at_studio = true where id = '14f00000-0000-0000-0000-0000000b0e19';
update bookings set status = 'attended' where id = '14f00000-0000-0000-0000-0000000b0e19';
select expect_num('reverse: checked in with the fee unpaid, no credit yet',
  (select count(*) from member_credits where booking_id = '14f00000-0000-0000-0000-0000000b0e19'), 0);
set role authenticated; select set_config('request.jwt.claim.sub','14f00000-0000-0000-0000-0000000000a3',false);
select set_config('t.rev', (record_reservation_paid_at_studio('14f00000-0000-0000-0000-0000000b0e19', 'cash', null) ->> 'ok'), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('reverse: Paid at studio recorded after check-in', current_setting('t.rev'), 'true');
select expect_num('reverse: the ₱500 comes back as credit when the payment is recorded',
  (select amount_cents from member_credits where booking_id = '14f00000-0000-0000-0000-0000000b0e19' and reason = 'reservation_credit'), 50000);

-- =============================================================================
-- 14b. 103 (p) staff_only, 21 (h), 22 (g), 111 (b), 97 (c), 24 (a).
-- =============================================================================
insert into auth.users (id) values ('14f00000-0000-0000-0000-0000000000a4');
insert into profiles (id, email) values ('14f00000-0000-0000-0000-0000000000a4', 's14-online@example.com');
insert into members (id, studio_id, first_name, last_name, email, status, user_id) values
  ('14f00000-0000-0000-0000-000000000031','14f00000-0000-0000-0000-000000000001','Online','Payer','s14-online@example.com','active','14f00000-0000-0000-0000-0000000000a4');
insert into class_occurrences (id, studio_id, class_type_id, room_id, location_id, instructor_id, name,
                               starts_at, ends_at, capacity, status, staffing)
values
  ('14f00000-0000-0000-0000-00000000c0f1','14f00000-0000-0000-0000-000000000001','14f00000-0000-0000-0000-0000000000f1','14f00000-0000-0000-0000-00000000b005','14f00000-0000-0000-0000-00000000000a','14f00000-0000-0000-0000-0000000000c1','REFORMER CORE', now() + interval '5 days', now() + interval '5 days 50 minutes', 6, 'scheduled','assigned'),
  ('14f00000-0000-0000-0000-00000000c0f2','14f00000-0000-0000-0000-000000000001','14f00000-0000-0000-0000-0000000000f1','14f00000-0000-0000-0000-00000000b005','14f00000-0000-0000-0000-00000000000a','14f00000-0000-0000-0000-0000000000c1','REFORMER DESK', now() + interval '6 days', now() + interval '6 days 50 minutes', 6, 'scheduled','assigned');

-- 103 (p): earned lets the member hold an unpaid desk seat; staff_only does not.
update studio_settings set desk_pay_mode = 'staff_only' where studio_id = '14f00000-0000-0000-0000-000000000001';
set role authenticated; select set_config('request.jwt.claim.sub','14f00000-0000-0000-0000-0000000000a4',false);
select set_config('t.p1', coalesce((book_class('14f00000-0000-0000-0000-00000000c0f1','14f00000-0000-0000-0000-000000000031','member')).failure_reason, 'none'), false);
select set_config('t.p2', (select desk_pay_available::text from member_bootstrap('s14-studio')), false);
select set_config('t.p3', coalesce((checkout_hold_class('14f00000-0000-0000-0000-00000000c0f1')).failure_reason, 'none'), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('staff_only: the member''s own unpaid drop-in is refused', current_setting('t.p1'), 'pay_online');
select expect_text('staff_only: desk_pay_available is false', current_setting('t.p2'), 'false');
select expect_text('staff_only: the online checkout hold still holds the seat', current_setting('t.p3'), 'none');
select expect_num('the checkout hold is one booked unpaid drop-in',
  (select count(*) from bookings where occurrence_id = '14f00000-0000-0000-0000-00000000c0f1'
     and member_id = '14f00000-0000-0000-0000-000000000031' and status = 'booked' and payment_source = 'drop_in'), 1);

-- the desk still books an unpaid drop-in for the member
set role authenticated; select set_config('request.jwt.claim.sub','14f00000-0000-0000-0000-0000000000a2',false);
select set_config('t.p4', coalesce((book_class('14f00000-0000-0000-0000-00000000c0f2','14f00000-0000-0000-0000-000000000031','front_desk')).failure_reason, 'none'), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('staff_only: front desk still books the member an unpaid drop-in', current_setting('t.p4'), 'none');

-- choose_pay_at_desk on a held seat: the member is refused, front desk is not.
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source, booked_at)
values ('14f00000-0000-0000-0000-0000000b0f31','14f00000-0000-0000-0000-000000000001','14f00000-0000-0000-0000-00000000c0e1',
        '14f00000-0000-0000-0000-000000000031','pending_payment','drop_in', now());
set role authenticated; select set_config('request.jwt.claim.sub','14f00000-0000-0000-0000-0000000000a4',false);
do $$ begin
  perform choose_pay_at_desk('14f00000-0000-0000-0000-0000000b0f31');
  perform set_config('t.p5', 'allowed', false);
exception when others then perform set_config('t.p5', sqlerrm, false);
end $$;
select set_config('request.jwt.claim.sub','14f00000-0000-0000-0000-0000000000a2',false);
select set_config('t.p6', (choose_pay_at_desk('14f00000-0000-0000-0000-0000000b0f31') ->> 'status'), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('staff_only: the member cannot choose pay at the studio', current_setting('t.p5'), 'Pay online to book this class.');
select expect_text('staff_only: front desk still can', current_setting('t.p6'), 'booked');
update studio_settings set desk_pay_mode = 'earned' where studio_id = '14f00000-0000-0000-0000-000000000001';

-- 21 (h): a core class switched to flex after the flex cut-off (12 h) under
-- the minimum. Refused without confirm, cancels with it.
insert into class_occurrences (id, studio_id, class_type_id, room_id, location_id, instructor_id, name,
                               starts_at, ends_at, capacity, status, staffing)
values
  ('14f00000-0000-0000-0000-00000000c0c9','14f00000-0000-0000-0000-000000000001','14f00000-0000-0000-0000-0000000000f1','14f00000-0000-0000-0000-00000000b006','14f00000-0000-0000-0000-00000000000a','14f00000-0000-0000-0000-0000000000c1','EVENING BURN', now() + interval '5 hours', now() + interval '5 hours 50 minutes', 6, 'scheduled','assigned'),
  ('14f00000-0000-0000-0000-00000000c0ca','14f00000-0000-0000-0000-000000000001','14f00000-0000-0000-0000-0000000000f1','14f00000-0000-0000-0000-00000000b006','14f00000-0000-0000-0000-00000000000a','14f00000-0000-0000-0000-0000000000c1','EVENING FLOW', now() + interval '7 hours', now() + interval '7 hours 50 minutes', 6, 'scheduled','assigned');
select s14_seat('14f00000-0000-0000-0000-0000000b0c91','14f00000-0000-0000-0000-00000000c0ca','14f00000-0000-0000-0000-000000000020');
select s14_seat('14f00000-0000-0000-0000-0000000b0c92','14f00000-0000-0000-0000-00000000c0ca','14f00000-0000-0000-0000-000000000021');
select s14_fee('14f00000-0000-0000-0000-0000000b0c91');
select s14_fee('14f00000-0000-0000-0000-0000000b0c92');

set role authenticated; select set_config('request.jwt.claim.sub','14f00000-0000-0000-0000-0000000000a1',false);
select set_config('t.h1', (set_occurrence_day_tier('14f00000-0000-0000-0000-00000000c0c9', 'flex') ->> 'reason'), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('flex after the cut-off, under the minimum: refused without confirm', current_setting('t.h1'), 'confirm_cancel');
select expect_text('the refused switch changed nothing',
  (select status::text || '/' || flex::text from class_occurrences where id = '14f00000-0000-0000-0000-00000000c0c9'), 'scheduled/false');
set role authenticated; select set_config('request.jwt.claim.sub','14f00000-0000-0000-0000-0000000000a1',false);
select set_config('t.h2', (set_occurrence_day_tier('14f00000-0000-0000-0000-00000000c0c9', 'flex', true) ->> 'cancelled'), false);
select set_config('t.h3', coalesce((set_occurrence_day_tier('14f00000-0000-0000-0000-00000000c0ca', 'flex') ->> 'reason'), 'none'), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('with confirm it switches and cancels at once', current_setting('t.h2'), 'true');
select expect_text('the cancelled class is unmet minimum',
  (select cancellation_cause::text from class_occurrences where id = '14f00000-0000-0000-0000-00000000c0c9'), 'unmet_minimum');
select expect_text('at the minimum it switches with no warning', current_setting('t.h3'), 'none');
select expect_text('and the class is still on',
  (select status::text || '/' || flex::text from class_occurrences where id = '14f00000-0000-0000-0000-00000000c0ca'), 'scheduled/true');

-- 22 (g): each change clears the studio's cached public schedule.
create or replace function s14_cache() returns void language sql as $$
  insert into public_schedule_cache (slug, days, payload, computed_at)
  values ('s14-studio', 60, '{}'::jsonb, now())
  on conflict do nothing;
$$;
create or replace function s14_cached() returns bigint language sql as $$
  select count(*) from public_schedule_cache where slug = 's14-studio';
$$;
select s14_cache();
select expect_num('the cache row is there', s14_cached(), 1);
update class_occurrences set guarantee_tier = 'always' where id = '14f00000-0000-0000-0000-00000000c0f1';
select expect_num('cache cleared on a tier change', s14_cached(), 0);
select s14_cache();
select cancel_occurrence('14f00000-0000-0000-0000-00000000c0f2', 'test', 'studio_fault');
select expect_num('cache cleared on a cancellation', s14_cached(), 0);
select s14_cache();
set role authenticated; select set_config('request.jwt.claim.sub','14f00000-0000-0000-0000-0000000000a1',false);
select set_config('t.g1', (run_cancelled_class_anyway('14f00000-0000-0000-0000-00000000c0c9') ->> 'ok'), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('Run it anyway on the class cancelled by the switch', current_setting('t.g1'), 'true');
select expect_num('cache cleared on Run it anyway', s14_cached(), 0);
select s14_cache();
update class_occurrences set starts_at = starts_at + interval '1 hour', ends_at = ends_at + interval '1 hour' where id = '14f00000-0000-0000-0000-00000000c0f1';
select expect_num('cache cleared on a move', s14_cached(), 0);
select s14_cache();
update class_occurrences set instructor_id = null where id = '14f00000-0000-0000-0000-00000000c0f1';
select expect_num('cache cleared on a coach change', s14_cached(), 0);
select s14_cache();
update class_occurrences set hidden_from_members = true where id = '14f00000-0000-0000-0000-00000000c0f1';
select expect_num('cache cleared on a visibility change', s14_cached(), 0);
select s14_cache();
update class_occurrences set capacity = 5 where id = '14f00000-0000-0000-0000-00000000c0f1';
select expect_num('cache cleared on a capacity change', s14_cached(), 0);
select s14_cache();
insert into class_occurrences (id, studio_id, class_type_id, room_id, location_id, name, starts_at, ends_at, capacity, status, staffing)
values ('14f00000-0000-0000-0000-00000000c0f3','14f00000-0000-0000-0000-000000000001','14f00000-0000-0000-0000-0000000000f1','14f00000-0000-0000-0000-00000000b005','14f00000-0000-0000-0000-00000000000a','NEW ONE', now() + interval '8 days', now() + interval '8 days 50 minutes', 6, 'scheduled','open');
select expect_num('cache cleared on a new occurrence', s14_cached(), 0);

-- 111 (b): a studio cancel that returns no money sends class_cancelled stating
-- what came back, and no payment_refunded.
select s14_seat('14f00000-0000-0000-0000-0000000b0f33','14f00000-0000-0000-0000-00000000c0f3','14f00000-0000-0000-0000-000000000022');
update bookings set provisional = false where id = '14f00000-0000-0000-0000-0000000b0f33';
select cancel_occurrence('14f00000-0000-0000-0000-00000000c0f3', 'roof leak', 'studio_fault');
select expect_text('the class-cancelled email says what came back',
  (select payload ->> 'returned_line' from notifications
    where template_key = 'class_cancelled' and member_id = '14f00000-0000-0000-0000-000000000022'
      and payload ->> 'occurrence_id' = '14f00000-0000-0000-0000-00000000c0f3'), 'Your free first class is still yours.');
select expect_num('and no payment_refunded email',
  (select count(*) from notifications where template_key = 'payment_refunded'
     and member_id = '14f00000-0000-0000-0000-000000000022'), 0);
select expect_true('the class-cancelled default carries the line, no em dash',
  (select text_body like '%{returned_line}%' and text_body not like '%—%' from notification_templates where key = 'class_cancelled'));

-- 97 (c): a test account is not counted in member health or the retention board.
insert into members (id, studio_id, first_name, last_name, email, status, health_band, health_reason, is_test_account) values
  ('14f00000-0000-0000-0000-000000000041','14f00000-0000-0000-0000-000000000001','Real','Risk','s14-r1@example.com','active','at_risk','Not in for six weeks', false),
  ('14f00000-0000-0000-0000-000000000042','14f00000-0000-0000-0000-000000000001','Test','Risk','s14-r2@example.com','active','at_risk','Not in for six weeks', true);
select expect_num('member health counts one at-risk member, not the test account',
  (select (b ->> 'count')::int from jsonb_array_elements(dashboard_health('14f00000-0000-0000-0000-000000000001') -> 'bands') b
    where b ->> 'band' = 'at_risk'), 1);
select expect_num('the retention board lists the real member',
  (select count(*) from retention_board('14f00000-0000-0000-0000-000000000001') where member_id = '14f00000-0000-0000-0000-000000000041'), 1);
select expect_num('and not the test account',
  (select count(*) from retention_board('14f00000-0000-0000-0000-000000000001') where member_id = '14f00000-0000-0000-0000-000000000042'), 0);

-- 24 (a): a plan capped at 2 sold.
insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, validity_days, status, visibility, max_sold)
values ('14f00000-0000-0000-0000-0000000000e1','14f00000-0000-0000-0000-000000000001','Founding Pack','class_pack',100000,'PHP',5,30,'active','public',2);
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on) values
  ('14f00000-0000-0000-0000-0000000000e2','14f00000-0000-0000-0000-000000000001','14f00000-0000-0000-0000-000000000011','14f00000-0000-0000-0000-0000000000e1','active',100000,'PHP',current_date);
select expect_true('one sold, not sold out', not plan_sold_out_run('14f00000-0000-0000-0000-0000000000e1'));
insert into xendit_purchases (id, studio_id, member_id, plan_id, amount_cents, currency, status)
values ('14f00000-0000-0000-0000-0000000000e3','14f00000-0000-0000-0000-000000000001','14f00000-0000-0000-0000-000000000012','14f00000-0000-0000-0000-0000000000e1',100000,'PHP','pending');
select expect_true('a pending checkout holds the second place: sold out', plan_sold_out_run('14f00000-0000-0000-0000-0000000000e1'));
do $$ begin
  insert into xendit_purchases (studio_id, member_id, plan_id, amount_cents, currency, status)
  values ('14f00000-0000-0000-0000-000000000001','14f00000-0000-0000-0000-000000000013','14f00000-0000-0000-0000-0000000000e1',100000,'PHP','pending');
  perform set_config('t.c1', 'allowed', false);
exception when others then perform set_config('t.c1', sqlerrm, false);
end $$;
select expect_text('an online checkout of a sold-out plan is refused', current_setting('t.c1'), 'This plan is sold out.');
do $$ begin
  perform record_manual_payment_run('14f00000-0000-0000-0000-000000000001','14f00000-0000-0000-0000-000000000014','plan',100000,'cash',
                                    '14f00000-0000-0000-0000-0000000000e1');
  perform set_config('t.c2', 'allowed', false);
exception when others then perform set_config('t.c2', sqlerrm, false);
end $$;
select expect_text('a desk sale of a sold-out plan is refused', current_setting('t.c2'), 'This plan is sold out.');
update xendit_purchases set status = 'expired' where id = '14f00000-0000-0000-0000-0000000000e3';
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on) values
  ('14f00000-0000-0000-0000-0000000000e4','14f00000-0000-0000-0000-000000000001','14f00000-0000-0000-0000-000000000015','14f00000-0000-0000-0000-0000000000e1','cancelled',100000,'PHP',current_date);
insert into payments (studio_id, member_id, membership_id, amount_cents, currency, status, provider, refunded_cents)
values ('14f00000-0000-0000-0000-000000000001','14f00000-0000-0000-0000-000000000015','14f00000-0000-0000-0000-0000000000e4',100000,'PHP','refunded','manual',100000);
select expect_num('a refunded sale does not count (1 sold)', plan_sold_count_run('14f00000-0000-0000-0000-0000000000e1'), 1);
select expect_true('so the plan is open again', not plan_sold_out_run('14f00000-0000-0000-0000-0000000000e1'));
insert into memberships (studio_id, member_id, plan_id, status, price_cents, currency, starts_on) values
  ('14f00000-0000-0000-0000-000000000001','14f00000-0000-0000-0000-000000000016','14f00000-0000-0000-0000-0000000000e1','active',100000,'PHP',current_date);
select expect_true('two sold: sold out', plan_sold_out_run('14f00000-0000-0000-0000-0000000000e1'));
update membership_plans set max_sold = 3 where id = '14f00000-0000-0000-0000-0000000000e1';
select expect_true('a raised cap reopens it', not plan_sold_out_run('14f00000-0000-0000-0000-0000000000e1'));
select expect_true('studio_by_slug carries sold_out for the buy page',
  exists (select 1 from studio_by_slug('s14-studio', true) s,
                 jsonb_array_elements(s.buy -> 'plans') p
           where p ->> 'id' = '14f00000-0000-0000-0000-0000000000e1' and p ? 'sold_out'));

-- Anon stays EXACTLY FIFTEEN and the new functions are closed to anon.
select expect_num('anon surface is exactly fifteen',
  (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not like 'expect\_%' and p.proname not like 's14\_%'), 15);
select expect_true('the Step 14b functions are not anon',
  not has_function_privilege('anon', 'checkout_hold_class(uuid)', 'execute')
  and not has_function_privilege('anon', 'plan_sold_states(uuid)', 'execute')
  and not has_function_privilege('anon', 'plan_sold_out_run(uuid)', 'execute')
  and not has_function_privilege('anon', 'set_occurrence_day_tier(uuid,text,boolean)', 'execute'));
select expect_true('the new functions are not anon',
  not has_function_privilege('anon', 'run_cancelled_class_anyway(uuid)', 'execute')
  and not has_function_privilege('anon', 'set_free_fee_choice(uuid,text,text)', 'execute')
  and not has_function_privilege('anon', 'record_reservation_paid_at_studio(uuid,text,text)', 'execute'));

do $$ begin raise notice 'step14_test: all assertions passed'; end $$;
