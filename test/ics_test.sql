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

insert into studios (id, name, slug, timezone, currency, status, contact_email) values
  ('ca1eca1e-0000-0000-0000-000000000001','ICS Studio','ca1e','Europe/Prague','CZK','active','studio@ca1e.example.com');
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
-- 1. A BOOKING → A VALID MEMBER VEVENT ON THE CONFIRMATION (an INVITATION now)
-- =============================================================================
-- The booking insert (fixtures) fired the notification trigger. The EMAILED
-- calendar is METHOD:REQUEST with ORGANIZER + ATTENDEE = the member — the only
-- shape Gmail turns into a card (Decision 33 amendment, migration 174).
select expect_true('the confirmation exists',
  exists(select 1 from notifications where dedupe_key = 'booking_confirmed:ca1eca1e-0000-0000-0000-0000000bb001'));
select expect_true('its .ics is a well-formed VCALENDAR, METHOD REQUEST',
  (select ics_of('booking_confirmed:ca1eca1e-0000-0000-0000-0000000bb001')) ~ 'BEGIN:VCALENDAR'
   and (select ics_of('booking_confirmed:ca1eca1e-0000-0000-0000-0000000bb001')) ~ 'METHOD:REQUEST'
   and (select ics_of('booking_confirmed:ca1eca1e-0000-0000-0000-0000000bb001')) ~ 'END:VEVENT');
select expect_true('it carries ORGANIZER = the studio contact email',
  (select ics_of('booking_confirmed:ca1eca1e-0000-0000-0000-0000000bb001'))
    ~ 'ORGANIZER:mailto:studio@ca1e.example.com');
select expect_true('it carries ATTENDEE = the member email with RSVP',
  (select ics_of('booking_confirmed:ca1eca1e-0000-0000-0000-0000000bb001'))
    ~ 'ATTENDEE;RSVP=TRUE;PARTSTAT=NEEDS-ACTION:mailto:ca1e-m1@example.com');
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
-- Part 3: the emailed date carries the four-digit year.
select expect_true('the confirmation payload when carries the four-digit year',
  (select payload ->> 'when' from notifications
    where dedupe_key = 'booking_confirmed:ca1eca1e-0000-0000-0000-0000000bb001')
    ~ (' ' || extract(year from now())::text || ','));

-- Capture the member SEQUENCE at booking time.
select set_config('t.seq_book', ics_seq(ics_of('booking_confirmed:ca1eca1e-0000-0000-0000-0000000bb001'))::text, false);

-- =============================================================================
-- 2. A MOVE → SAME UID, HIGHER SEQUENCE, still an invitation (METHOD:REQUEST)
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
select expect_true('...and the move is still an invitation (METHOD:REQUEST)',
  (select ics_of(dedupe_key) from notifications
    where template_key='class_moved' and member_id='ca1eca1e-0000-0000-0000-0000000000b1' limit 1)
    ~ 'METHOD:REQUEST');

-- =============================================================================
-- 3. A CANCEL → METHOD:CANCEL, SAME UID, HIGHER SEQUENCE, same ORGANIZER/ATTENDEE
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
select expect_true('...at a HIGHER SEQUENCE than the confirm for that UID',
  ics_seq(ics_of('class_cancelled:ca1eca1e-0000-0000-0000-00000000a001:ca1eca1e-0000-0000-0000-0000000000b1'))
    > current_setting('t.seq_book')::bigint);
select expect_true('...carrying the same ORGANIZER and the member ATTENDEE',
  (select ics_of('class_cancelled:ca1eca1e-0000-0000-0000-00000000a001:ca1eca1e-0000-0000-0000-0000000000b1'))
    ~ 'ORGANIZER:mailto:studio@ca1e.example.com'
  and (select ics_of('class_cancelled:ca1eca1e-0000-0000-0000-00000000a001:ca1eca1e-0000-0000-0000-0000000000b1'))
    ~ 'ATTENDEE;RSVP=TRUE;PARTSTAT=NEEDS-ACTION:mailto:ca1e-m1@example.com');

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

-- The instructor per-booking email was replaced by the coalesced per-class alert
-- (Decision 33 amendment, migration 167) — email_each_booking and the
-- booking_for_instructor path are gone. That behaviour is covered by
-- test/instructor_alerts_test.sql (UUID `a1e7`).

-- =============================================================================
-- 5. THE DOWNLOAD ROUTE IS UNCHANGED: METHOD:PUBLISH, no ATTENDEE (a file the
--    member adds, not an invitation). member_class_ics as the booking's owner.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub', 'ca1eca1e-0000-0000-0000-0000000000b1', false);
select expect_true('download .ics stays METHOD:PUBLISH',
  member_class_ics('ca1eca1e-0000-0000-0000-00000000a001') ~ 'METHOD:PUBLISH');
select expect_true('download .ics has NO ATTENDEE and NO ORGANIZER',
  member_class_ics('ca1eca1e-0000-0000-0000-00000000a001') !~ 'ATTENDEE'
  and member_class_ics('ca1eca1e-0000-0000-0000-00000000a001') !~ 'ORGANIZER');
reset role;
select set_config('request.jwt.claim.sub', null, false);

-- =============================================================================
-- 6. THE EMPTY-ATTACHMENT FIX: single-line base64 that round-trips (migration 174).
--    This is the exact expression send_via_resend builds the attachment with.
-- =============================================================================
select set_config('t.ics', ics_of('booking_confirmed:ca1eca1e-0000-0000-0000-0000000bb001'), false);
select expect_num('the attachment base64 contains no newline (was wrapped every 76 chars)',
  position(chr(10) in translate(encode(convert_to(current_setting('t.ics'),'UTF8'),'base64'), E'\n',''))::bigint, 0);
select expect_true('...and it decodes back to the identical .ics bytes',
  convert_from(decode(translate(encode(convert_to(current_setting('t.ics'),'UTF8'),'base64'), E'\n',''), 'base64'), 'UTF8')
    = current_setting('t.ics'));
select expect_true('the raw base64 WAS wrapped (the bug we fixed): it contains a newline before stripping',
  position(chr(10) in encode(convert_to(current_setting('t.ics'),'UTF8'),'base64')) > 0);

select 'ics part A suite finished' as done;
