-- =============================================================================
-- Decision 33 Part A — the .ics builder, email attachment, instructor opt-in.
-- Migration 161. UUID space ca1e, checked free.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual then raise notice 'PASS  %  (got true)', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function ics_of(p_dedupe text) returns text
language sql as $$ select notification_ics(id) from notifications where dedupe_key = p_dedupe $$;
create or replace function ics_seq(p_ics text) returns bigint
language sql as $$ select (substring(p_ics from 'SEQUENCE:([0-9]+)'))::bigint $$;

-- --- Fixtures ---------------------------------------------------------------
insert into auth.users (id) values
  ('ca1eca1e-0000-0000-0000-0000000000a1'),   -- owner
  ('ca1eca1e-0000-0000-0000-0000000000c1'),   -- instructor login
  ('ca1eca1e-0000-0000-0000-0000000000b1'),   -- member 1
  ('ca1eca1e-0000-0000-0000-0000000000b2');   -- member 2
insert into profiles (id, email, full_name) values
  ('ca1eca1e-0000-0000-0000-0000000000a1','ca1e-owner@example.com','Ora Owner'),
  ('ca1eca1e-0000-0000-0000-0000000000c1','ca1e-coach@example.com','Cyd Coach'),
  ('ca1eca1e-0000-0000-0000-0000000000b1','ca1e-m1@example.com','Mem One'),
  ('ca1eca1e-0000-0000-0000-0000000000b2','ca1e-m2@example.com','Mem Two');

insert into studios (id, name, slug, timezone, currency, status) values
  ('ca1eca1e-0000-0000-0000-000000000001','ICS Studio','ca1e','Europe/Prague','CZK','active');
insert into studio_settings (studio_id) values ('ca1eca1e-0000-0000-0000-000000000001');
insert into locations (id, studio_id, name, timezone, is_primary, status, address) values
  ('ca1eca1e-0000-0000-0000-00000000000c','ca1eca1e-0000-0000-0000-000000000001','Main','Europe/Prague',true,'active',
   jsonb_build_object('line1','Reformer Row 3','city','Prague','postal_code','110 00','country','CZ'));
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('ca1eca1e-0000-0000-0000-0000000000e1','ca1eca1e-0000-0000-0000-000000000001','ca1eca1e-0000-0000-0000-00000000000c','Studio A',8);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('ca1eca1e-0000-0000-0000-0000000000c9','ca1eca1e-0000-0000-0000-000000000001','Reformer Flow',50,8);

-- Owner + instructor staff rows (the instructor has a LOGIN, so a per-booking
-- email can actually reach them).
insert into studio_staff (id, studio_id, user_id, role, status, email) values
  ('ca1eca1e-0000-0000-0000-000000005501','ca1eca1e-0000-0000-0000-000000000001','ca1eca1e-0000-0000-0000-0000000000a1','owner','active','ca1e-owner@example.com'),
  ('ca1eca1e-0000-0000-0000-000000005502','ca1eca1e-0000-0000-0000-000000000001','ca1eca1e-0000-0000-0000-0000000000c1','instructor','active','ca1e-coach@example.com');
insert into instructors (id, studio_id, staff_id, display_name) values
  ('ca1eca1e-0000-0000-0000-0000000000d1','ca1eca1e-0000-0000-0000-000000000001','ca1eca1e-0000-0000-0000-000000005502','Cyd Coach');

insert into members (id, studio_id, user_id, first_name, last_name, email, status) values
  ('ca1eca1e-0000-0000-0000-0000000000b1','ca1eca1e-0000-0000-0000-000000000001','ca1eca1e-0000-0000-0000-0000000000b1','Mem','One','ca1e-m1@example.com','active'),
  ('ca1eca1e-0000-0000-0000-0000000000b2','ca1eca1e-0000-0000-0000-000000000001','ca1eca1e-0000-0000-0000-0000000000b2','Mem','Two','ca1e-m2@example.com','active');

-- A future, assigned class (publication off → published, so instructor emails fire).
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id,
                               instructor_id, name, capacity, starts_at, ends_at)
values ('ca1eca1e-0000-0000-0000-00000000a001','ca1eca1e-0000-0000-0000-000000000001',
        'ca1eca1e-0000-0000-0000-00000000000c','ca1eca1e-0000-0000-0000-0000000000c9',
        'ca1eca1e-0000-0000-0000-0000000000e1','ca1eca1e-0000-0000-0000-0000000000d1',
        'Reformer Flow',8, now() + interval '3 days', now() + interval '3 days' + interval '50 min');
insert into bookings (id, studio_id, occurrence_id, member_id, status) values
  ('ca1eca1e-0000-0000-0000-0000000bb001','ca1eca1e-0000-0000-0000-000000000001',
   'ca1eca1e-0000-0000-0000-00000000a001','ca1eca1e-0000-0000-0000-0000000000b1','booked');
update class_occurrences set booked_count = 1 where id = 'ca1eca1e-0000-0000-0000-00000000a001';

-- =============================================================================
-- 1. A BOOKING → A VALID MEMBER VEVENT ON THE CONFIRMATION
-- =============================================================================
-- The booking insert (fixtures) fired the notification trigger.
select expect_true('the confirmation exists',
  exists(select 1 from notifications where dedupe_key = 'booking_confirmed:ca1eca1e-0000-0000-0000-0000000bb001'));
select expect_true('its .ics is a well-formed VCALENDAR, METHOD PUBLISH',
  (select ics_of('booking_confirmed:ca1eca1e-0000-0000-0000-0000000bb001')) ~ 'BEGIN:VCALENDAR'
   and (select ics_of('booking_confirmed:ca1eca1e-0000-0000-0000-0000000bb001')) ~ 'METHOD:PUBLISH'
   and (select ics_of('booking_confirmed:ca1eca1e-0000-0000-0000-0000000bb001')) ~ 'END:VEVENT');
select expect_true('UID is the booking id',
  (select ics_of('booking_confirmed:ca1eca1e-0000-0000-0000-0000000bb001'))
    ~ 'UID:ca1eca1e-0000-0000-0000-0000000bb001');
select expect_true('DTSTART is a UTC instant',
  (select ics_of('booking_confirmed:ca1eca1e-0000-0000-0000-0000000bb001')) ~ 'DTSTART:[0-9]{8}T[0-9]{6}Z');
select expect_true('SUMMARY is the class name',
  (select ics_of('booking_confirmed:ca1eca1e-0000-0000-0000-0000000bb001')) ~ 'SUMMARY:Reformer Flow');
select expect_true('the confirmation body carries the Manage link',
  (select payload ->> 'manage_link' from notifications
    where dedupe_key = 'booking_confirmed:ca1eca1e-0000-0000-0000-0000000bb001') like '%/class/ca1eca1e-0000-0000-0000-00000000a001');

-- Capture the member SEQUENCE at booking time.
select set_config('t.seq_book', ics_seq(ics_of('booking_confirmed:ca1eca1e-0000-0000-0000-0000000bb001'))::text, false);

-- =============================================================================
-- 2. A MOVE → SAME UID, HIGHER SEQUENCE
-- =============================================================================
-- The move touches the occurrence (updated_at), which the member SEQUENCE takes
-- the greater of — so class_moved updates the calendar event in place.
-- Simulate a move: the occurrence's time changes, which bumps its updated_at
-- (the class_occurrences_updated trigger) exactly as move_occurrence's own
-- UPDATE does. queue_class_moved then queues the member notice.
select pg_sleep(1);
update class_occurrences
   set starts_at = now() + interval '4 days',
       ends_at   = now() + interval '4 days' + interval '50 min'
 where id = 'ca1eca1e-0000-0000-0000-00000000a001';
select queue_class_moved('ca1eca1e-0000-0000-0000-00000000a001', now() + interval '3 days');

select expect_true('class_moved carries the same UID (the booking)',
  (select ics_of(dedupe_key) from notifications
    where template_key='class_moved' and member_id='ca1eca1e-0000-0000-0000-0000000000b1' limit 1)
    ~ 'UID:ca1eca1e-0000-0000-0000-0000000bb001');
select expect_true('...at a HIGHER sequence than the confirmation',
  (select ics_seq(ics_of(dedupe_key)) from notifications
    where template_key='class_moved' and member_id='ca1eca1e-0000-0000-0000-0000000000b1' limit 1)
    > current_setting('t.seq_book')::bigint);

-- =============================================================================
-- 3. A CANCEL → METHOD:CANCEL, SAME UID
-- =============================================================================
select queue_occurrence_cancelled('ca1eca1e-0000-0000-0000-00000000a001');
select expect_true('class_cancelled carries METHOD:CANCEL and STATUS:CANCELLED',
  (select ics_of('class_cancelled:ca1eca1e-0000-0000-0000-00000000a001:ca1eca1e-0000-0000-0000-0000000000b1'))
    ~ 'METHOD:CANCEL'
  and (select ics_of('class_cancelled:ca1eca1e-0000-0000-0000-00000000a001:ca1eca1e-0000-0000-0000-0000000000b1'))
    ~ 'STATUS:CANCELLED');
select expect_true('...for the same UID, so the calendar removes it',
  (select ics_of('class_cancelled:ca1eca1e-0000-0000-0000-00000000a001:ca1eca1e-0000-0000-0000-0000000000b1'))
    ~ 'UID:ca1eca1e-0000-0000-0000-0000000bb001');

-- =============================================================================
-- 4. THE INSTRUCTOR EVENT: UID = OCCURRENCE, SEQUENCE RISES ON A NEW BOOKING
-- =============================================================================
select expect_true('an instructor event uses the occurrence id as UID',
  ics_instructor_vevent('ca1eca1e-0000-0000-0000-00000000a001', false)
    ~ 'UID:ca1eca1e-0000-0000-0000-00000000a001');
select set_config('t.seq_instr', ics_seq(ics_instructor_vevent('ca1eca1e-0000-0000-0000-00000000a001', false))::text, false);
-- A booking's booked_count write is an UPDATE on class_occurrences, which bumps
-- updated_at via the trigger — the same statement book_class runs.
select pg_sleep(1);
update class_occurrences set booked_count = booked_count + 1 where id = 'ca1eca1e-0000-0000-0000-00000000a001';
select expect_true('a new booking raises the instructor event''s SEQUENCE',
  ics_seq(ics_instructor_vevent('ca1eca1e-0000-0000-0000-00000000a001', false))
    > current_setting('t.seq_instr')::bigint);

-- =============================================================================
-- 5. INSTRUCTOR PER-BOOKING EMAIL: OFF → ZERO, ON → EXACTLY ONE, TO THEM ONLY
-- =============================================================================
-- A fresh class so the counts are clean.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id,
                               instructor_id, name, capacity, starts_at, ends_at)
values ('ca1eca1e-0000-0000-0000-00000000a002','ca1eca1e-0000-0000-0000-000000000001',
        'ca1eca1e-0000-0000-0000-00000000000c','ca1eca1e-0000-0000-0000-0000000000c9',
        'ca1eca1e-0000-0000-0000-0000000000e1','ca1eca1e-0000-0000-0000-0000000000d1',
        'Reformer Flow',8, now() + interval '5 days', now() + interval '5 days' + interval '50 min');

-- OFF (default): the booking-insert trigger queues no instructor email. (The
-- fixture booking bb001 was also inserted while off.)
insert into bookings (id, studio_id, occurrence_id, member_id, status) values
  ('ca1eca1e-0000-0000-0000-0000000bb002','ca1eca1e-0000-0000-0000-000000000001',
   'ca1eca1e-0000-0000-0000-00000000a002','ca1eca1e-0000-0000-0000-0000000000b1','booked');
select expect_num('opt-in OFF: no per-booking email to the instructor',
  (select count(*) from notifications where template_key = 'booking_for_instructor')::bigint, 0);

-- ON: a second booking's trigger queues exactly one, to that instructor and no one else.
update instructors set email_each_booking = true where id = 'ca1eca1e-0000-0000-0000-0000000000d1';
insert into bookings (id, studio_id, occurrence_id, member_id, status) values
  ('ca1eca1e-0000-0000-0000-0000000bb003','ca1eca1e-0000-0000-0000-000000000001',
   'ca1eca1e-0000-0000-0000-00000000a002','ca1eca1e-0000-0000-0000-0000000000b2','booked');
select expect_num('opt-in ON: exactly one per-booking email',
  (select count(*) from notifications where template_key = 'booking_for_instructor')::bigint, 1);
select expect_true('...to that instructor''s login, nobody else',
  (select user_id = 'ca1eca1e-0000-0000-0000-0000000000c1' from notifications
    where template_key = 'booking_for_instructor'));
select expect_true('...and it carries an instructor .ics (headcount, occurrence UID)',
  (select notification_ics(id) from notifications where template_key='booking_for_instructor')
    ~ 'UID:ca1eca1e-0000-0000-0000-00000000a002');

select 'ics part A suite finished' as done;
