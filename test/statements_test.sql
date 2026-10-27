-- =============================================================================
-- STUDIIOR — DECISION 75a: STATEMENTS (occurrence history, attendance
-- finalisation, member activity statement)
--
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/statements_test.sql
--
-- Space: 57a7. Local only — inserts fixtures. Never run against production.
-- =============================================================================

\set ON_ERROR_STOP on
set client_min_messages = notice;

create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if;
end $$;
create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if;
end $$;

-- ---- Fixtures ---------------------------------------------------------------
insert into studios (id, name, slug, timezone, currency) values
  ('57a70000-0000-0000-0000-00000000a001','Statement Studio','stmt57a7','Europe/Prague','CZK'),
  ('57a70000-0000-0000-0000-00000000a002','Other Studio','other57a7','Europe/Prague','CZK');
insert into studio_settings (studio_id, finalise_attendance, finalise_days_after, suspension_enabled) values
  ('57a70000-0000-0000-0000-00000000a001', true, 1, false),
  ('57a70000-0000-0000-0000-00000000a002', false, 1, false);
insert into locations (id, studio_id, name, is_primary) values
  ('57a70000-0000-0000-0000-00000000aa01','57a70000-0000-0000-0000-00000000a001','Main',true),
  ('57a70000-0000-0000-0000-00000000ab01','57a70000-0000-0000-0000-00000000a002','Main',true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('57a70000-0000-0000-0000-00000000dd01','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-00000000aa01','RA',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('57a70000-0000-0000-0000-0000000c7a01','57a70000-0000-0000-0000-00000000a001','Reformer',50,10),
  ('57a70000-0000-0000-0000-0000000c7a02','57a70000-0000-0000-0000-00000000a002','Reformer',50,10);

-- An instructor WITH a login (so the finalisation reminder has a recipient).
insert into auth.users (id) values ('57a70000-0000-0000-0000-0000000f9001');
insert into profiles (id, email) values ('57a70000-0000-0000-0000-0000000f9001','57a7-instr@t');
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('57a70000-0000-0000-0000-0000005f0001','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-0000000f9001','57a7-instr@t','instructor');
insert into instructors (id, studio_id, display_name, staff_id) values
  ('57a70000-0000-0000-0000-0000000d0a01','57a70000-0000-0000-0000-00000000a001','Ira One','57a70000-0000-0000-0000-0000005f0001');

-- An owner (manager-up), for the staff read of member_activity.
insert into auth.users (id) values ('57a70000-0000-0000-0000-0000000f1001');
insert into profiles (id, email) values ('57a70000-0000-0000-0000-0000000f1001','57a7-owner@t');
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('57a70000-0000-0000-0000-0000005f0002','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-0000000f1001','57a7-owner@t','owner');

-- =============================================================================
-- A. occurrence_events — the trigger captures each kind of change.
-- =============================================================================
insert into class_occurrences (id, studio_id, location_id, class_type_id, name, capacity,
  starts_at, ends_at, instructor_id, room_id, guarantee_tier)
values ('57a70000-0000-0000-0000-0000000ec001','57a70000-0000-0000-0000-00000000a001',
  '57a70000-0000-0000-0000-00000000aa01','57a70000-0000-0000-0000-0000000c7a01','Reformer', 10,
  now()+interval '3 days', now()+interval '3 days 50 min','57a70000-0000-0000-0000-0000000d0a01',
  '57a70000-0000-0000-0000-00000000dd01','core');

update class_occurrences set starts_at = starts_at + interval '2 hours', ends_at = ends_at + interval '2 hours'
 where id='57a70000-0000-0000-0000-0000000ec001';
select expect_num('75a events: a time change writes a moved event',
  (select count(*) from occurrence_events where occurrence_id='57a70000-0000-0000-0000-0000000ec001' and kind='moved'), 1);

update class_occurrences set instructor_id = null where id='57a70000-0000-0000-0000-0000000ec001';
select expect_num('75a events: clearing the instructor writes instructor_changed',
  (select count(*) from occurrence_events where occurrence_id='57a70000-0000-0000-0000-0000000ec001' and kind='instructor_changed'), 1);

update class_occurrences set committed_at = now() where id='57a70000-0000-0000-0000-0000000ec001';
select expect_num('75a events: setting committed_at writes a committed event',
  (select count(*) from occurrence_events where occurrence_id='57a70000-0000-0000-0000-0000000ec001' and kind='committed'), 1);

update class_occurrences set status='cancelled', cancelled_at=now(), cancellation_cause='studio_fault'
 where id='57a70000-0000-0000-0000-0000000ec001';
select expect_num('75a events: status->cancelled writes a cancelled event',
  (select count(*) from occurrence_events where occurrence_id='57a70000-0000-0000-0000-0000000ec001' and kind='cancelled'), 1);
select expect_text('75a events: the cancelled event carries the cause in after',
  (select after->>'cause' from occurrence_events where occurrence_id='57a70000-0000-0000-0000-0000000ec001' and kind='cancelled'), 'studio_fault');

update class_occurrences set status='scheduled', cancelled_at=null where id='57a70000-0000-0000-0000-0000000ec001';
select expect_num('75a events: cancelled->scheduled writes a reopened event',
  (select count(*) from occurrence_events where occurrence_id='57a70000-0000-0000-0000-0000000ec001' and kind='reopened'), 1);

update class_occurrences set booked_count = booked_count + 1 where id='57a70000-0000-0000-0000-0000000ec001';
select expect_num('75a events: a booked_count bump writes nothing (5 events total)',
  (select count(*) from occurrence_events where occurrence_id='57a70000-0000-0000-0000-0000000ec001'), 5);

-- =============================================================================
-- B. finalise_attendance_sweep — booked -> no_show past the boundary, switch-gated.
-- =============================================================================
insert into members (id, studio_id, first_name, last_name, email, status) values
  ('57a70000-0000-0000-0000-0000000b0001','57a70000-0000-0000-0000-00000000a001','Bea','One','57a7-b1@t','active'),
  ('57a70000-0000-0000-0000-0000000b0002','57a70000-0000-0000-0000-00000000a001','Bo','Two','57a7-b2@t','active');
insert into class_occurrences (id, studio_id, location_id, class_type_id, name, capacity, starts_at, ends_at, instructor_id, status)
values ('57a70000-0000-0000-0000-0000000ec002','57a70000-0000-0000-0000-00000000a001',
  '57a70000-0000-0000-0000-00000000aa01','57a70000-0000-0000-0000-0000000c7a01','Reformer',10,
  now()-interval '1 day 2 hours', now()-interval '1 day 1 hour','57a70000-0000-0000-0000-0000000d0a01','scheduled');
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at) values
  ('57a70000-0000-0000-0000-0000000bb201','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-0000000ec002','57a70000-0000-0000-0000-0000000b0001','booked','member','drop_in', now()-interval '2 days');
insert into members (id, studio_id, first_name, last_name, email, status) values
  ('57a70000-0000-0000-0000-0000000c0001','57a70000-0000-0000-0000-00000000a002','Cy','One','57a7-c1@t','active');
insert into class_occurrences (id, studio_id, location_id, class_type_id, name, capacity, starts_at, ends_at, status)
values ('57a70000-0000-0000-0000-0000000ec003','57a70000-0000-0000-0000-00000000a002',
  '57a70000-0000-0000-0000-00000000ab01','57a70000-0000-0000-0000-0000000c7a02','Reformer',10,
  now()-interval '1 day 2 hours', now()-interval '1 day 1 hour','scheduled');
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at) values
  ('57a70000-0000-0000-0000-0000000bb301','57a70000-0000-0000-0000-00000000a002','57a70000-0000-0000-0000-0000000ec003','57a70000-0000-0000-0000-0000000c0001','booked','member','drop_in', now()-interval '2 days');
-- SA: a class that ended 30 min ago TODAY — before the midnight(day+1) boundary.
insert into class_occurrences (id, studio_id, location_id, class_type_id, name, capacity, starts_at, ends_at, status)
values ('57a70000-0000-0000-0000-0000000ec004','57a70000-0000-0000-0000-00000000a001',
  '57a70000-0000-0000-0000-00000000aa01','57a70000-0000-0000-0000-0000000c7a01','Reformer',10,
  now()-interval '90 min', now()-interval '30 min','scheduled');
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at) values
  ('57a70000-0000-0000-0000-0000000bb401','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-0000000ec004','57a70000-0000-0000-0000-0000000b0002','booked','member','drop_in', now()-interval '2 days');

select finalise_attendance_sweep();

select expect_text('75a finalise: SA yesterday booking -> no_show',
  (select status::text from bookings where id='57a70000-0000-0000-0000-0000000bb201'), 'no_show');
select expect_text('75a finalise: no_show_at stamped, actor null',
  (select case when no_show_at is not null and no_show_by is null then 'stamped' else 'no' end
     from bookings where id='57a70000-0000-0000-0000-0000000bb201'), 'stamped');
select expect_text('75a finalise: the occurrence is stamped finalised',
  (select case when attendance_finalised_at is not null then 'yes' else 'no' end
     from class_occurrences where id='57a70000-0000-0000-0000-0000000ec002'), 'yes');
select expect_num('75a finalise: NO infraction created',
  (select count(*) from member_infractions where member_id='57a70000-0000-0000-0000-0000000b0001'), 0);
select expect_num('75a finalise: instructor reminder queued once',
  (select count(*) from notifications where template_key='instructor_unmarked_bookings' and dedupe_key='unmarked:57a70000-0000-0000-0000-0000000ec002'), 1);
select expect_text('75a finalise: SB (switch off) booking is NOT marked',
  (select status::text from bookings where id='57a70000-0000-0000-0000-0000000bb301'), 'booked');
select expect_text('75a finalise: SA today class (before boundary) is NOT marked',
  (select status::text from bookings where id='57a70000-0000-0000-0000-0000000bb401'), 'booked');

select finalise_attendance_sweep();
select expect_num('75a finalise: a second run queues no second reminder',
  (select count(*) from notifications where template_key='instructor_unmarked_bookings' and dedupe_key='unmarked:57a70000-0000-0000-0000-0000000ec002'), 1);

-- =============================================================================
-- C. member_activity — one row per event, running balance, the invariant.
-- =============================================================================
insert into auth.users (id) values ('57a70000-0000-0000-0000-0000000e0b01'),('57a70000-0000-0000-0000-0000000e0b02');
insert into profiles (id, email) values ('57a70000-0000-0000-0000-0000000e0b01','57a7-m1u@t'),('57a70000-0000-0000-0000-0000000e0b02','57a7-m2u@t');
insert into members (id, studio_id, first_name, last_name, email, status, user_id, joined_on) values
  ('57a70000-0000-0000-0000-0000000e0a01','57a70000-0000-0000-0000-00000000a001','Mia','One','57a7-m1@t','active','57a70000-0000-0000-0000-0000000e0b01', current_date-30),
  ('57a70000-0000-0000-0000-0000000e0a02','57a70000-0000-0000-0000-00000000a001','Mo','Two','57a7-m2@t','active','57a70000-0000-0000-0000-0000000e0b02', current_date-30);
insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, validity_days) values
  ('57a70000-0000-0000-0000-0000000f0a01','57a70000-0000-0000-0000-00000000a001','10-Pack','class_pack',500000,'CZK',10,180);
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on, credits_remaining) values
  ('57a70000-0000-0000-0000-0000000a5001','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-0000000e0a01','57a70000-0000-0000-0000-0000000f0a01','active',500000,'CZK',current_date,8);
-- t0 purchase +10 (bal 10) + a payment that claims it
insert into credit_ledger (id, studio_id, member_id, membership_id, delta, reason, balance_after, created_at) values
  ('57a70000-0000-0000-0000-0000000ed001','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-0000000e0a01','57a70000-0000-0000-0000-0000000a5001',10,'purchase',10, now()-interval '20 days');
insert into payments (id, studio_id, member_id, membership_id, amount_cents, currency, status, provider, description, paid_at, created_at) values
  ('57a70000-0000-0000-0000-0000000fa001','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-0000000e0a01','57a70000-0000-0000-0000-0000000a5001',500000,'CZK','succeeded','manual','10-Pack', now()-interval '20 days', now()-interval '20 days');
insert into class_occurrences (id, studio_id, location_id, class_type_id, name, capacity, starts_at, ends_at, status) values
  ('57a70000-0000-0000-0000-0000000ec011','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-00000000aa01','57a70000-0000-0000-0000-0000000c7a01','Reformer',10, now()-interval '15 days', now()-interval '15 days'+interval '50 min','scheduled'),
  ('57a70000-0000-0000-0000-0000000ec012','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-00000000aa01','57a70000-0000-0000-0000-0000000c7a01','Reformer',10, now()-interval '14 days', now()-interval '14 days'+interval '50 min','scheduled'),
  ('57a70000-0000-0000-0000-0000000ec013','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-00000000aa01','57a70000-0000-0000-0000-0000000c7a01','Reformer',10, now()-interval '13 days', now()-interval '13 days'+interval '50 min','scheduled');
-- Bookings first (credit_entry_id null), then the ledger rows (booking_id FK),
-- then link credit_entry_id — the book_class order (circular FK between the two).
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, membership_id, booked_at) values
  ('57a70000-0000-0000-0000-0000000bb011','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-0000000ec011','57a70000-0000-0000-0000-0000000e0a01','attended','member','class_pack','57a70000-0000-0000-0000-0000000a5001', now()-interval '16 days');
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, membership_id, booked_at, cancelled_at, release_reason) values
  ('57a70000-0000-0000-0000-0000000bb012','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-0000000ec012','57a70000-0000-0000-0000-0000000e0a01','cancelled','member','class_pack','57a70000-0000-0000-0000-0000000a5001', now()-interval '15 days', now()-interval '15 days'+interval '1 hour','member_cancelled');
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, membership_id, booked_at, cancelled_at, is_late_cancel) values
  ('57a70000-0000-0000-0000-0000000bb013','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-0000000ec013','57a70000-0000-0000-0000-0000000e0a01','late_cancelled','member','class_pack','57a70000-0000-0000-0000-0000000a5001', now()-interval '14 days', now()-interval '14 days'+interval '10 hours', true);
-- B1 consume -1 (bal 9); B2 -1 (bal 8) then +1 refund (bal 9); B3 -1 (bal 8), no refund.
insert into credit_ledger (id, studio_id, member_id, membership_id, delta, reason, booking_id, balance_after, created_at) values
  ('57a70000-0000-0000-0000-0000000ed002','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-0000000e0a01','57a70000-0000-0000-0000-0000000a5001',-1,'booking','57a70000-0000-0000-0000-0000000bb011',9, now()-interval '16 days'),
  ('57a70000-0000-0000-0000-0000000ed003','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-0000000e0a01','57a70000-0000-0000-0000-0000000a5001',-1,'booking','57a70000-0000-0000-0000-0000000bb012',8, now()-interval '15 days'),
  ('57a70000-0000-0000-0000-0000000ed004','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-0000000e0a01','57a70000-0000-0000-0000-0000000a5001', 1,'cancellation_refund','57a70000-0000-0000-0000-0000000bb012',9, now()-interval '15 days'+interval '1 hour'),
  ('57a70000-0000-0000-0000-0000000ed005','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-0000000e0a01','57a70000-0000-0000-0000-0000000a5001',-1,'booking','57a70000-0000-0000-0000-0000000bb013',8, now()-interval '14 days');
update bookings set credit_entry_id = '57a70000-0000-0000-0000-0000000ed002' where id='57a70000-0000-0000-0000-0000000bb011';
update bookings set credit_entry_id = '57a70000-0000-0000-0000-0000000ed003' where id='57a70000-0000-0000-0000-0000000bb012';
update bookings set credit_entry_id = '57a70000-0000-0000-0000-0000000ed005' where id='57a70000-0000-0000-0000-0000000bb013';
-- A manual adjustment +2 (bal 10), claimed by no event -> "Credits added"
insert into credit_ledger (id, studio_id, member_id, membership_id, delta, reason, balance_after, created_at) values
  ('57a70000-0000-0000-0000-0000000ed006','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-0000000e0a01','57a70000-0000-0000-0000-0000000a5001',2,'manual',10, now()-interval '13 days');

-- ---- Decision 83: plan_name / due_cents / is_free_first on the statement ------
-- On Mo Two (e0a02), so e0a01's counts above are untouched. A public drop-in plan
-- gives an unpaid drop-in a price to show.
insert into membership_plans (id, studio_id, name, type, price_cents, currency, visibility, status) values
  ('57a70000-0000-0000-0000-0000000f0a02','57a70000-0000-0000-0000-00000000a001','Drop-in','drop_in',15000,'CZK','public','active');
insert into class_occurrences (id, studio_id, location_id, class_type_id, name, capacity, starts_at, ends_at, status) values
  ('57a70000-0000-0000-0000-0000000ecd01','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-00000000aa01','57a70000-0000-0000-0000-0000000c7a01','Reformer',10, now()-interval '12 days', now()-interval '12 days'+interval '50 min','scheduled'),
  ('57a70000-0000-0000-0000-0000000ecd02','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-00000000aa01','57a70000-0000-0000-0000-0000000c7a01','Reformer',10, now()-interval '11 days', now()-interval '11 days'+interval '50 min','scheduled'),
  ('57a70000-0000-0000-0000-0000000ecf01','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-00000000aa01','57a70000-0000-0000-0000-0000000c7a01','Reformer',10, now()-interval '10 days', now()-interval '10 days'+interval '50 min','scheduled'),
  ('57a70000-0000-0000-0000-0000000ece01','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-00000000aa01','57a70000-0000-0000-0000-0000000c7a01','Reformer',10, now()-interval '9 days', now()-interval '9 days'+interval '50 min','scheduled');
-- (b) an UNPAID drop-in (no payment) and a PAID one (a succeeded payment).
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at) values
  ('57a70000-0000-0000-0000-000000bbd001','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-0000000ecd01','57a70000-0000-0000-0000-0000000e0a02','booked','member','drop_in', now()-interval '12 days'),
  ('57a70000-0000-0000-0000-000000bbd002','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-0000000ecd02','57a70000-0000-0000-0000-0000000e0a02','booked','member','drop_in', now()-interval '11 days');
insert into payments (id, studio_id, member_id, booking_id, amount_cents, currency, status, provider, description, paid_at, created_at) values
  ('57a70000-0000-0000-0000-0000000fa002','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-0000000e0a02','57a70000-0000-0000-0000-000000bbd002',15000,'CZK','succeeded','manual','Drop-in', now()-interval '11 days', now()-interval '11 days');
-- (c) a free first class: a comp booking with a host-null guest pass.
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at) values
  ('57a70000-0000-0000-0000-000000bbf001','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-0000000ecf01','57a70000-0000-0000-0000-0000000e0a02','booked','member','comp', now()-interval '10 days');
insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email, occurrence_id, guest_booking_id, status) values
  ('57a70000-0000-0000-0000-00000000a001', null, '57a70000-0000-0000-0000-0000000e0a02','57a7-m2@t','57a70000-0000-0000-0000-0000000ecf01','57a70000-0000-0000-0000-000000bbf001','confirmed');
-- (d) a moved class she holds a live booking on.
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at) values
  ('57a70000-0000-0000-0000-000000bbe001','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-0000000ece01','57a70000-0000-0000-0000-0000000e0a02','booked','member','drop_in', now()-interval '9 days');
insert into occurrence_events (studio_id, occurrence_id, kind, at) values
  ('57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-0000000ece01','moved', now()-interval '9 days'+interval '1 hour');

-- ---- Decision 83 (a): e0a03 for a no-show-from-a-plan, a desk purchase (method +
-- recorder + classes + valid-to), and a plan that ended. Separate member, so the
-- e0a01/e0a02 counts above are untouched. The owner gets a recorder full name.
update profiles set full_name = 'Olive Owner' where id = '57a70000-0000-0000-0000-0000000f1001';
insert into auth.users (id) values ('57a70000-0000-0000-0000-0000000e0b03');
insert into profiles (id, email) values ('57a70000-0000-0000-0000-0000000e0b03','57a7-m3u@t');
insert into members (id, studio_id, first_name, last_name, email, status, user_id, joined_on) values
  ('57a70000-0000-0000-0000-0000000e0a03','57a70000-0000-0000-0000-00000000a001','Max','Three','57a7-m3@t','active','57a70000-0000-0000-0000-0000000e0b03', current_date-40);
insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, validity_days) values
  ('57a70000-0000-0000-0000-0000000f0a03','57a70000-0000-0000-0000-00000000a001','5-Pack','class_pack',250000,'CZK',5,90);
-- A cancelled membership (ended, NOT refunded) with a 2-credit forfeit at the end.
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on, expires_on, credits_remaining, cancelled_at) values
  ('57a70000-0000-0000-0000-0000000a5003','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-0000000e0a03','57a70000-0000-0000-0000-0000000f0a03','cancelled',250000,'CZK',current_date-20, current_date+30, 0, now()-interval '2 days');
insert into payments (id, studio_id, member_id, membership_id, amount_cents, currency, status, provider, method, recorded_by, description, paid_at, created_at) values
  ('57a70000-0000-0000-0000-0000000fa003','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-0000000e0a03','57a70000-0000-0000-0000-0000000a5003',250000,'CZK','succeeded','manual','cash','57a70000-0000-0000-0000-0000000f1001','5-Pack', now()-interval '20 days', now()-interval '20 days');
insert into class_occurrences (id, studio_id, location_id, class_type_id, name, capacity, starts_at, ends_at, instructor_id, status) values
  ('57a70000-0000-0000-0000-0000000ec014','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-00000000aa01','57a70000-0000-0000-0000-0000000c7a01','Reformer',10, now()-interval '17 days', now()-interval '17 days'+interval '50 min','57a70000-0000-0000-0000-0000000d0a01','scheduled');
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, membership_id, booked_at, no_show_at) values
  ('57a70000-0000-0000-0000-000000bb0014','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-0000000ec014','57a70000-0000-0000-0000-0000000e0a03','no_show','member','class_pack','57a70000-0000-0000-0000-0000000a5003', now()-interval '18 days', now()-interval '17 days');
-- +5 purchase (bal 5), -1 the no-show's consume (bal 4), -2 the end forfeit (bal 2).
insert into credit_ledger (id, studio_id, member_id, membership_id, delta, reason, balance_after, created_at) values
  ('57a70000-0000-0000-0000-0000000ed010','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-0000000e0a03','57a70000-0000-0000-0000-0000000a5003', 5,'purchase',5, now()-interval '20 days');
insert into credit_ledger (id, studio_id, member_id, membership_id, delta, reason, booking_id, balance_after, created_at) values
  ('57a70000-0000-0000-0000-0000000ed012','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-0000000e0a03','57a70000-0000-0000-0000-0000000a5003',-1,'booking','57a70000-0000-0000-0000-000000bb0014',4, now()-interval '18 days');
update bookings set credit_entry_id='57a70000-0000-0000-0000-0000000ed012' where id='57a70000-0000-0000-0000-000000bb0014';
insert into credit_ledger (id, studio_id, member_id, membership_id, delta, reason, balance_after, created_at) values
  ('57a70000-0000-0000-0000-0000000ed011','57a70000-0000-0000-0000-00000000a001','57a70000-0000-0000-0000-0000000e0a03','57a70000-0000-0000-0000-0000000a5003',-2,'manual',2, now()-interval '2 days');

set role authenticated;
select set_config('request.jwt.claim.sub','57a70000-0000-0000-0000-0000000e0b01',false);

select expect_num('75a invariant: statement credit_delta sums to the ledger total',
  (select coalesce(sum(credit_delta),0) from member_activity('57a70000-0000-0000-0000-0000000e0a01','2000-01-01','2030-01-01')), 10);
select expect_num('75a stmt: a purchase row',
  (select count(*) from member_activity('57a70000-0000-0000-0000-0000000e0a01','2000-01-01','2030-01-01') where kind='purchase'), 1);
select expect_num('75a stmt: a booked row carries -1',
  (select credit_delta from member_activity('57a70000-0000-0000-0000-0000000e0a01','2000-01-01','2030-01-01') where booking_id='57a70000-0000-0000-0000-0000000bb011' and kind='booked'), -1);
select expect_num('75a stmt: the timely cancellation carries +1',
  (select credit_delta from member_activity('57a70000-0000-0000-0000-0000000e0a01','2000-01-01','2030-01-01') where booking_id='57a70000-0000-0000-0000-0000000bb012' and kind='cancelled'), 1);
select expect_text('75a stmt: the late cancel is "class used" with 0 delta',
  (select detail||'/'||credit_delta from member_activity('57a70000-0000-0000-0000-0000000e0a01','2000-01-01','2030-01-01') where booking_id='57a70000-0000-0000-0000-0000000bb013' and kind='late_cancelled'), 'Class used/0');
select expect_num('75a stmt: the manual +2 is its own Credits added line',
  (select credit_delta from member_activity('57a70000-0000-0000-0000-0000000e0a01','2000-01-01','2030-01-01') where kind='credits_added'), 2);
select expect_num('75a balance: the booked B1 row shows balance 9',
  (select balance_after from member_activity('57a70000-0000-0000-0000-0000000e0a01','2000-01-01','2030-01-01') where booking_id='57a70000-0000-0000-0000-0000000bb011' and kind='booked'), 9);
select expect_num('75a balance: the manual adjustment row shows balance 10 (final)',
  (select balance_after from member_activity('57a70000-0000-0000-0000-0000000e0a01','2000-01-01','2030-01-01') where kind='credits_added'), 10);
select expect_num('75a: no ledger entry appears twice (non-zero-delta rows == ledger rows)',
  (select count(*) from member_activity('57a70000-0000-0000-0000-0000000e0a01','2000-01-01','2030-01-01') where credit_delta <> 0), 6);

select set_config('request.jwt.claim.sub','57a70000-0000-0000-0000-0000000e0b02',false);
do $$
declare st text;
begin
  begin
    perform * from member_activity('57a70000-0000-0000-0000-0000000e0a01','2000-01-01','2030-01-01');
    st := 'NO_RAISE';
  exception when others then st := sqlstate;
  end;
  perform expect_text('75a scope: another member is refused PT403', st, 'PT403');
end $$;
reset role;

set role authenticated;
select set_config('request.jwt.claim.sub','57a70000-0000-0000-0000-0000000f1001',false);
-- 7 member-visible rows (purchase, booked ×3, cancelled, late_cancelled, credits
-- added) + the staff-only joined row = 8. B1 is 'attended' but has no check_ins
-- row, so it is one 'booked' line, not a separate 'attended' line.
select expect_num('75a scope: staff can read the member statement',
  (select count(*) from member_activity('57a70000-0000-0000-0000-0000000e0a01','2000-01-01','2030-01-01')), 8);
select expect_num('75a staff: the staff-only joined row is present',
  (select count(*) from member_activity('57a70000-0000-0000-0000-0000000e0a01','2000-01-01','2030-01-01') where kind='joined'), 1);
reset role;

-- =============================================================================
-- C2. Decision 83 — plan_name / due_cents / is_free_first (read as the owner).
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','57a70000-0000-0000-0000-0000000f1001',false);
-- (a) a booking drawn from a pack names the plan (balance 9 is asserted above).
select expect_text('83 stmt: a pack booking names its plan',
  (select plan_name from member_activity('57a70000-0000-0000-0000-0000000e0a01','2000-01-01','2030-01-01') where booking_id='57a70000-0000-0000-0000-0000000bb011' and kind='booked'), '10-Pack');
-- (b) an unpaid drop-in shows the amount due and no plan; a paid one shows neither.
select expect_num('83 stmt: an unpaid drop-in shows the amount due',
  (select due_cents from member_activity('57a70000-0000-0000-0000-0000000e0a02','2000-01-01','2030-01-01') where booking_id='57a70000-0000-0000-0000-000000bbd001' and kind='booked'), 15000);
select expect_text('83 stmt: an unpaid drop-in has no plan name',
  (select coalesce(plan_name,'<null>') from member_activity('57a70000-0000-0000-0000-0000000e0a02','2000-01-01','2030-01-01') where booking_id='57a70000-0000-0000-0000-000000bbd001' and kind='booked'), '<null>');
select expect_text('83 stmt: a paid drop-in shows no amount due',
  (select coalesce(due_cents::text,'<null>') from member_activity('57a70000-0000-0000-0000-0000000e0a02','2000-01-01','2030-01-01') where booking_id='57a70000-0000-0000-0000-000000bbd002' and kind='booked'), '<null>');
-- (c) a free first class is flagged, with no plan.
select expect_text('83 stmt: a free first class is flagged is_free_first',
  (select case when is_free_first then 'yes' else 'no' end from member_activity('57a70000-0000-0000-0000-0000000e0a02','2000-01-01','2030-01-01') where booking_id='57a70000-0000-0000-0000-000000bbf001' and kind='free_first'), 'yes');
select expect_text('83 stmt: a free first class has no plan name',
  (select coalesce(plan_name,'<null>') from member_activity('57a70000-0000-0000-0000-0000000e0a02','2000-01-01','2030-01-01') where booking_id='57a70000-0000-0000-0000-000000bbf001' and kind='free_first'), '<null>');
-- (d) the moved occurrence still produces its row.
select expect_num('83 stmt: a moved occurrence row is present',
  (select count(*) from member_activity('57a70000-0000-0000-0000-0000000e0a02','2000-01-01','2030-01-01') where kind='rescheduled'), 1);
reset role;

-- =============================================================================
-- C3. Decision 83 (a) — occurrence_start, instructor_first, credits_left_after,
--     payment_method, recorded_by_name, plan_classes, plan_valid_to,
--     unused_credits, across the row kinds (read as the owner).
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','57a70000-0000-0000-0000-0000000f1001',false);

-- Booked from a plan: the class instant is carried for the "{Day} {date}, {time}" line.
select expect_text('83a: a booked row carries the class start',
  (select case when occurrence_start is not null then 'yes' else 'no' end from member_activity('57a70000-0000-0000-0000-0000000e0a01','2000-01-01','2030-01-01') where booking_id='57a70000-0000-0000-0000-0000000bb011' and kind='booked'), 'yes');

-- Cancelled in time: names the plan it returned to, and the balance after the return (9).
select expect_text('83a: a timely cancellation names the plan it returned to',
  (select plan_name from member_activity('57a70000-0000-0000-0000-0000000e0a01','2000-01-01','2030-01-01') where booking_id='57a70000-0000-0000-0000-0000000bb012' and kind='cancelled'), '10-Pack');
select expect_num('83a: a timely cancellation shows credits after the return',
  (select credits_left_after from member_activity('57a70000-0000-0000-0000-0000000e0a01','2000-01-01','2030-01-01') where booking_id='57a70000-0000-0000-0000-0000000bb012' and kind='cancelled'), 9);

-- Cancelled late: a class used from the plan, balance after (8).
select expect_num('83a: a late cancellation shows credits used (8 left)',
  (select credits_left_after from member_activity('57a70000-0000-0000-0000-0000000e0a01','2000-01-01','2030-01-01') where booking_id='57a70000-0000-0000-0000-0000000bb013' and kind='late_cancelled'), 8);

-- Online purchase (no method, no recorder): plan_classes carried, recorder null.
select expect_text('83a: an online purchase has no desk method',
  (select coalesce(payment_method,'<null>') from member_activity('57a70000-0000-0000-0000-0000000e0a01','2000-01-01','2030-01-01') where kind='purchase'), '<null>');
select expect_text('83a: an online purchase has no recorder name',
  (select coalesce(recorded_by_name,'<null>') from member_activity('57a70000-0000-0000-0000-0000000e0a01','2000-01-01','2030-01-01') where kind='purchase'), '<null>');
select expect_num('83a: a purchase carries the plan class count (10)',
  (select plan_classes from member_activity('57a70000-0000-0000-0000-0000000e0a01','2000-01-01','2030-01-01') where kind='purchase'), 10);

-- Free first: no plan credit touched.
select expect_text('83a: a free first class shows no plan credit',
  (select coalesce(credits_left_after::text,'<null>') from member_activity('57a70000-0000-0000-0000-0000000e0a02','2000-01-01','2030-01-01') where booking_id='57a70000-0000-0000-0000-000000bbf001' and kind='free_first'), '<null>');

-- An active membership never produces a plan_ended row.
select expect_num('83a: an active membership has no plan_ended row',
  (select count(*) from member_activity('57a70000-0000-0000-0000-0000000e0a01','2000-01-01','2030-01-01') where kind='plan_ended'), 0);

-- No-show from a plan: names the plan, the balance at the no-show (4), the instructor.
select expect_text('83a: a no-show from a plan names the plan',
  (select plan_name from member_activity('57a70000-0000-0000-0000-0000000e0a03','2000-01-01','2030-01-01') where booking_id='57a70000-0000-0000-0000-000000bb0014' and kind='no_show'), '5-Pack');
select expect_num('83a: a no-show from a plan shows the credits left (4)',
  (select credits_left_after from member_activity('57a70000-0000-0000-0000-0000000e0a03','2000-01-01','2030-01-01') where booking_id='57a70000-0000-0000-0000-000000bb0014' and kind='no_show'), 4);
select expect_text('83a: a no-show carries the instructor first name',
  (select instructor_first from member_activity('57a70000-0000-0000-0000-0000000e0a03','2000-01-01','2030-01-01') where booking_id='57a70000-0000-0000-0000-000000bb0014' and kind='no_show'), 'Ira');

-- No-show on an unpaid drop-in (b0001, section B): nothing owed, no plan, no credit.
select expect_text('83a: an unpaid drop-in no-show has no plan',
  (select coalesce(plan_name,'<null>') from member_activity('57a70000-0000-0000-0000-0000000b0001','2000-01-01','2030-01-01') where booking_id='57a70000-0000-0000-0000-0000000bb201' and kind='no_show'), '<null>');
select expect_text('83a: an unpaid drop-in no-show shows no credits left',
  (select coalesce(credits_left_after::text,'<null>') from member_activity('57a70000-0000-0000-0000-0000000b0001','2000-01-01','2030-01-01') where booking_id='57a70000-0000-0000-0000-0000000bb201' and kind='no_show'), '<null>');

-- Desk purchase: method, recorder name, plan class count, valid-to date.
select expect_text('83a: a desk purchase shows the method',
  (select payment_method from member_activity('57a70000-0000-0000-0000-0000000e0a03','2000-01-01','2030-01-01') where kind='purchase' and membership_id='57a70000-0000-0000-0000-0000000a5003'), 'cash');
select expect_text('83a: a desk purchase carries the recorder name',
  (select recorded_by_name from member_activity('57a70000-0000-0000-0000-0000000e0a03','2000-01-01','2030-01-01') where kind='purchase' and membership_id='57a70000-0000-0000-0000-0000000a5003'), 'Olive Owner');
select expect_num('83a: a desk purchase carries the plan class count (5)',
  (select plan_classes from member_activity('57a70000-0000-0000-0000-0000000e0a03','2000-01-01','2030-01-01') where kind='purchase' and membership_id='57a70000-0000-0000-0000-0000000a5003'), 5);
select expect_text('83a: a desk purchase carries the valid-to date',
  (select plan_valid_to::text from member_activity('57a70000-0000-0000-0000-0000000e0a03','2000-01-01','2030-01-01') where kind='purchase' and membership_id='57a70000-0000-0000-0000-0000000a5003'), (current_date+30)::text);

-- Plan ended (not a refund): one row, names the plan, counts the forfeited classes.
select expect_num('83a: an ended plan produces one plan_ended row',
  (select count(*) from member_activity('57a70000-0000-0000-0000-0000000e0a03','2000-01-01','2030-01-01') where kind='plan_ended'), 1);
select expect_text('83a: the ended plan names the plan',
  (select plan_name from member_activity('57a70000-0000-0000-0000-0000000e0a03','2000-01-01','2030-01-01') where kind='plan_ended'), '5-Pack');
select expect_num('83a: the ended plan shows classes unused (2)',
  (select unused_credits from member_activity('57a70000-0000-0000-0000-0000000e0a03','2000-01-01','2030-01-01') where kind='plan_ended'), 2);
reset role;

-- =============================================================================
-- D. Anon surface stays EXACTLY THIRTEEN
-- =============================================================================
select expect_num('75a: anon surface is exactly thirteen',
  (select count(*) from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
     where ns.nspname='public' and has_function_privilege('anon', p.oid, 'execute')
       and p.proname not like 'expect_%' and p.proname not in ('login','sig','psig')), 13);

do $$ begin raise notice 'ALL DECISION 75a ASSERTIONS PASSED'; end $$;
