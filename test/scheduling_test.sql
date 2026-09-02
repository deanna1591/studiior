-- =============================================================================
-- Decision 17 — open shifts, applications, and the one scheduling path
-- Migrations 047 and 048. UUID space f00d, checked free.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then
    raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else
    raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null');
  end if;
end $$;

create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then
    raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else
    raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null');
  end if;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('f00df00d-0000-0000-0000-0000000000a1'),   -- owner
  ('f00df00d-0000-0000-0000-0000000000a2'),   -- front desk
  ('f00df00d-0000-0000-0000-0000000000a3'),   -- instructor one
  ('f00df00d-0000-0000-0000-0000000000a4'),   -- instructor two
  ('f00df00d-0000-0000-0000-0000000000a5'),   -- manager
  ('f00df00d-0000-0000-0000-0000000000b1');   -- a member
insert into profiles (id, email, full_name) values
  ('f00df00d-0000-0000-0000-0000000000a1','sch-owner@example.com','Ovi Owner'),
  ('f00df00d-0000-0000-0000-0000000000a2','sch-desk@example.com','Des Kay'),
  ('f00df00d-0000-0000-0000-0000000000a3','sch-one@example.com','Ines One'),
  ('f00df00d-0000-0000-0000-0000000000a4','sch-two@example.com','Ivo Two'),
  ('f00df00d-0000-0000-0000-0000000000a5','sch-mgr@example.com','Man Ager'),
  ('f00df00d-0000-0000-0000-0000000000b1','sch-mem@example.com','Mem Ber');

insert into studios (id, name, slug, timezone, currency, status) values
  ('f00df00d-0000-0000-0000-000000000001','Shift Studio','shift-test','Europe/Prague','CZK','active');
insert into studio_settings (studio_id) values ('f00df00d-0000-0000-0000-000000000001');
insert into locations (id, studio_id, name, is_primary) values
  ('f00df00d-0000-0000-0000-00000000000c','f00df00d-0000-0000-0000-000000000001','Main',true);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('f00df00d-0000-0000-0000-00000000aa01','f00df00d-0000-0000-0000-000000000001','f00df00d-0000-0000-0000-0000000000a1','sch-owner@example.com','owner'),
  ('f00df00d-0000-0000-0000-00000000aa02','f00df00d-0000-0000-0000-000000000001','f00df00d-0000-0000-0000-0000000000a2','sch-desk@example.com','front_desk'),
  ('f00df00d-0000-0000-0000-00000000aa03','f00df00d-0000-0000-0000-000000000001','f00df00d-0000-0000-0000-0000000000a3','sch-one@example.com','instructor'),
  ('f00df00d-0000-0000-0000-00000000aa04','f00df00d-0000-0000-0000-000000000001','f00df00d-0000-0000-0000-0000000000a4','sch-two@example.com','instructor'),
  ('f00df00d-0000-0000-0000-00000000aa05','f00df00d-0000-0000-0000-000000000001','f00df00d-0000-0000-0000-0000000000a5','sch-mgr@example.com','manager');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('f00df00d-0000-0000-0000-00000000ee01','f00df00d-0000-0000-0000-000000000001','f00df00d-0000-0000-0000-00000000000c','Room A',10),
  ('f00df00d-0000-0000-0000-00000000ee02','f00df00d-0000-0000-0000-000000000001','f00df00d-0000-0000-0000-00000000000c','Room B',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('f00df00d-0000-0000-0000-00000000cc01','f00df00d-0000-0000-0000-000000000001','Reformer',60,10);
-- staff_id references studio_staff(id), NOT a user id.
insert into instructors (id, studio_id, staff_id, display_name) values
  ('f00df00d-0000-0000-0000-00000000d101','f00df00d-0000-0000-0000-000000000001','f00df00d-0000-0000-0000-00000000aa03','Ines One'),
  ('f00df00d-0000-0000-0000-00000000d102','f00df00d-0000-0000-0000-000000000001','f00df00d-0000-0000-0000-00000000aa04','Ivo Two');
insert into members (id, studio_id, user_id, first_name, last_name, email, joined_on, status, waiver_signed_at) values
  ('f00df00d-0000-0000-0000-00000000dd01','f00df00d-0000-0000-0000-000000000001',
   'f00df00d-0000-0000-0000-0000000000b1','Mem','Ber','schmem@example.com', current_date - 20, 'active', now());

-- Two classes, tomorrow, in the two rooms.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               instructor_id, capacity, starts_at, ends_at, status, staffing) values
  ('f00df00d-0000-0000-0000-00000000f001','f00df00d-0000-0000-0000-000000000001',
   'f00df00d-0000-0000-0000-00000000000c','f00df00d-0000-0000-0000-00000000cc01',
   'f00df00d-0000-0000-0000-00000000ee01','Reformer','f00df00d-0000-0000-0000-00000000d101', 10,
   date_trunc('day', now()) + interval '1 day 9 hours',
   date_trunc('day', now()) + interval '1 day 10 hours', 'scheduled', 'assigned'),
  ('f00df00d-0000-0000-0000-00000000f002','f00df00d-0000-0000-0000-000000000001',
   'f00df00d-0000-0000-0000-00000000000c','f00df00d-0000-0000-0000-00000000cc01',
   'f00df00d-0000-0000-0000-00000000ee02','Reformer','f00df00d-0000-0000-0000-00000000d102', 10,
   date_trunc('day', now()) + interval '1 day 9 hours 30 minutes',
   date_trunc('day', now()) + interval '1 day 10 hours 30 minutes', 'scheduled', 'assigned');

-- =============================================================================
-- 1. What cannot physically overlap does not
-- =============================================================================
do $$
begin
  -- Same room, overlapping time.
  insert into class_occurrences (studio_id, location_id, class_type_id, room_id, name,
                                 capacity, starts_at, ends_at, staffing)
  values ('f00df00d-0000-0000-0000-000000000001','f00df00d-0000-0000-0000-00000000000c',
          'f00df00d-0000-0000-0000-00000000cc01','f00df00d-0000-0000-0000-00000000ee01','Clash', 10,
          date_trunc('day', now()) + interval '1 day 9 hours 30 minutes',
          date_trunc('day', now()) + interval '1 day 10 hours 30 minutes', 'open');
  raise exception 'FAIL  two classes were put in one room at once';
exception when exclusion_violation then
  raise notice 'PASS  a room cannot hold two classes at once';
end $$;

do $$
begin
  insert into class_occurrences (studio_id, location_id, class_type_id, room_id, name,
                                 instructor_id, capacity, starts_at, ends_at, staffing)
  values ('f00df00d-0000-0000-0000-000000000001','f00df00d-0000-0000-0000-00000000000c',
          'f00df00d-0000-0000-0000-00000000cc01','f00df00d-0000-0000-0000-00000000ee02','Clash',
          'f00df00d-0000-0000-0000-00000000d101', 10,
          date_trunc('day', now()) + interval '1 day 9 hours 30 minutes',
          date_trunc('day', now()) + interval '1 day 10 hours 30 minutes', 'assigned');
  raise exception 'FAIL  one instructor was put in two classes at once';
exception when exclusion_violation then
  raise notice 'PASS  an instructor cannot teach two classes at once';
end $$;

-- A cancelled class must not hold a room it is not using.
update class_occurrences set status = 'cancelled' where id = 'f00df00d-0000-0000-0000-00000000f001';
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               capacity, starts_at, ends_at, staffing)
values ('f00df00d-0000-0000-0000-00000000f003','f00df00d-0000-0000-0000-000000000001',
        'f00df00d-0000-0000-0000-00000000000c','f00df00d-0000-0000-0000-00000000cc01',
        'f00df00d-0000-0000-0000-00000000ee01','Replacement', 10,
        date_trunc('day', now()) + interval '1 day 9 hours',
        date_trunc('day', now()) + interval '1 day 10 hours', 'open');
select expect_text('a cancelled class stops holding its room',
  (select name from class_occurrences where id = 'f00df00d-0000-0000-0000-00000000f003'), 'Replacement');

-- And the consequence, which is correct rather than inconvenient: once the room
-- has been given to somebody else, the cancelled class cannot simply be
-- un-cancelled back into it. Staff have to move one of them, which is exactly
-- what you would want a system to insist on.
do $$
begin
  update class_occurrences set status = 'scheduled' where id = 'f00df00d-0000-0000-0000-00000000f001';
  raise exception 'FAIL  a cancelled class was restored on top of its replacement';
exception when exclusion_violation then
  raise notice 'PASS  un-cancelling into a room that has been given away is refused';
end $$;

-- Clear the replacement so the rest of the suite has its room back.
delete from class_occurrences where id = 'f00df00d-0000-0000-0000-00000000f003';
update class_occurrences set status = 'scheduled' where id = 'f00df00d-0000-0000-0000-00000000f001';

-- =============================================================================
-- 2. Moving a class goes through one path, and asks about members
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','f00df00d-0000-0000-0000-0000000000a1',false);

select expect_text('a clean move is allowed',
  (select move_occurrence('f00df00d-0000-0000-0000-00000000f001',
     date_trunc('day', now()) + interval '1 day 14 hours',
     date_trunc('day', now()) + interval '1 day 15 hours') ->> 'ok'), 'true');

-- Onto the other class's room and time.
select expect_text('a move into an occupied room is refused with a reason',
  (select move_occurrence('f00df00d-0000-0000-0000-00000000f001',
     (select starts_at from class_occurrences where id='f00df00d-0000-0000-0000-00000000f002'),
     (select ends_at   from class_occurrences where id='f00df00d-0000-0000-0000-00000000f002'),
     p_room_id => 'f00df00d-0000-0000-0000-00000000ee02') ->> 'reason'), 'room_busy');

select expect_text('...and the class did not move',
  (select (starts_at = date_trunc('day', now()) + interval '1 day 14 hours')::text
     from class_occurrences where id='f00df00d-0000-0000-0000-00000000f001'), 'true');

-- Front desk cannot touch the timetable at all.
select set_config('request.jwt.claim.sub','f00df00d-0000-0000-0000-0000000000a2',false);
do $$
begin
  perform move_occurrence('f00df00d-0000-0000-0000-00000000f001',
    date_trunc('day', now()) + interval '1 day 16 hours',
    date_trunc('day', now()) + interval '1 day 17 hours');
  raise exception 'FAIL  front desk moved a class';
exception when sqlstate 'PT403' then
  raise notice 'PASS  front desk cannot move a class';
end $$;
reset role;

-- A member books, and now moving it has to ask.
insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source)
values ('f00df00d-0000-0000-0000-000000000001','f00df00d-0000-0000-0000-00000000f001',
        'f00df00d-0000-0000-0000-00000000dd01','booked','staff','drop_in');
update class_occurrences set booked_count = 1 where id='f00df00d-0000-0000-0000-00000000f001';

set role authenticated;
select set_config('request.jwt.claim.sub','f00df00d-0000-0000-0000-0000000000a1',false);
select expect_text('with a member booked, the first attempt refuses and asks',
  (select move_occurrence('f00df00d-0000-0000-0000-00000000f001',
     date_trunc('day', now()) + interval '1 day 16 hours',
     date_trunc('day', now()) + interval '1 day 17 hours') ->> 'requires_confirmation'), 'true');
select expect_text('...saying how many people it affects',
  (select move_occurrence('f00df00d-0000-0000-0000-00000000f001',
     date_trunc('day', now()) + interval '1 day 16 hours',
     date_trunc('day', now()) + interval '1 day 17 hours') ->> 'booked_count'), '1');
select expect_text('...and it still has not moved',
  (select (starts_at = date_trunc('day', now()) + interval '1 day 14 hours')::text
     from class_occurrences where id='f00df00d-0000-0000-0000-00000000f001'), 'true');

select expect_text('confirmed, it moves',
  (select move_occurrence('f00df00d-0000-0000-0000-00000000f001',
     date_trunc('day', now()) + interval '1 day 16 hours',
     date_trunc('day', now()) + interval '1 day 17 hours',
     p_confirm => true) ->> 'ok'), 'true');
reset role;

select expect_num('...and the member is told, because they would otherwise turn up at the old time',
  (select count(*) from notifications
    where studio_id = 'f00df00d-0000-0000-0000-000000000001' and template_key = 'class_moved'), 1);
select expect_text('...an email they cannot switch off',
  (select notification_wanted('f00df00d-0000-0000-0000-00000000dd01','class_moved')::text), 'true');

-- =============================================================================
-- 3. Open shifts: apply, approve, and the edges Decision 17 settles
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','f00df00d-0000-0000-0000-0000000000a1',false);
select move_occurrence('f00df00d-0000-0000-0000-00000000f002', p_clear_instructor => true);
reset role;

select expect_text('a class published without an instructor is an open shift',
  (select staffing::text from class_occurrences where id='f00df00d-0000-0000-0000-00000000f002'), 'open');

-- Both instructors want it. Decision 17: every application stands until staff
-- pick one.
set role authenticated;
select set_config('request.jwt.claim.sub','f00df00d-0000-0000-0000-0000000000a3',false);
select set_config('t.app1', (select apply_for_shift('f00df00d-0000-0000-0000-00000000f002') ->> 'application_id'), false);
select set_config('request.jwt.claim.sub','f00df00d-0000-0000-0000-0000000000a4',false);
select set_config('t.app2', (select apply_for_shift('f00df00d-0000-0000-0000-00000000f002') ->> 'application_id'), false);
reset role;

select expect_text('one application moves it to pending approval',
  (select staffing::text from class_occurrences where id='f00df00d-0000-0000-0000-00000000f002'), 'pending_approval');
select expect_num('both applications stand until staff decide',
  (select count(*) from shift_applications
    where occurrence_id='f00df00d-0000-0000-0000-00000000f002' and status='pending'), 2);
-- Two applications, and the studio has an owner and a manager: four rows.
select expect_num('the studio is told, once per manager-or-above',
  (select count(*) from notifications where template_key='shift_application_received'), 4);
-- Front desk is deliberately not among them. Who teaches a class is not
-- something they can do anything about, and a notification you cannot act on
-- is the thing that teaches people to ignore notifications.
select expect_num('...and front desk is not told, because they cannot act on it',
  (select count(*) from notifications
    where template_key='shift_application_received'
      and user_id = 'f00df00d-0000-0000-0000-0000000000a2'), 0);

-- An instructor cannot apply twice.
set role authenticated;
select set_config('request.jwt.claim.sub','f00df00d-0000-0000-0000-0000000000a3',false);
do $$
begin
  perform apply_for_shift('f00df00d-0000-0000-0000-00000000f002');
  raise exception 'FAIL  an instructor applied twice';
exception when sqlstate 'PT409' then
  raise notice 'PASS  an instructor cannot apply for the same shift twice';
end $$;
reset role;

-- Nor can somebody who is not an instructor there.
set role authenticated;
select set_config('request.jwt.claim.sub','f00df00d-0000-0000-0000-0000000000a2',false);
do $$
begin
  perform apply_for_shift('f00df00d-0000-0000-0000-00000000f002');
  raise exception 'FAIL  front desk applied for a shift';
exception when sqlstate 'PT403' then
  raise notice 'PASS  somebody who is not an instructor cannot apply';
end $$;
-- And an instructor cannot approve themselves. Decision 9 still holds:
-- instructors never assign themselves, they ask.
select set_config('request.jwt.claim.sub','f00df00d-0000-0000-0000-0000000000a3',false);
do $$
begin
  perform approve_shift_application(current_setting('t.app1')::uuid);
  raise exception 'FAIL  an instructor approved their own application';
exception when sqlstate 'PT403' then
  raise notice 'PASS  an instructor cannot approve their own application';
end $$;
reset role;

-- Staff approve one. The other is declined in the same transaction and told.
set role authenticated;
select set_config('request.jwt.claim.sub','f00df00d-0000-0000-0000-0000000000a1',false);
select set_config('t.approved',
  (select approve_shift_application(current_setting('t.app1')::uuid)::text), false);
reset role;

select expect_num('approving one auto-declines the rest',
  ((current_setting('t.approved')::jsonb ->> 'auto_declined')::int), 1);
select expect_text('...the class is assigned',
  (select staffing::text from class_occurrences where id='f00df00d-0000-0000-0000-00000000f002'), 'assigned');
select expect_text('...to the instructor who was approved',
  (select (instructor_id = 'f00df00d-0000-0000-0000-00000000d101')::text
     from class_occurrences where id='f00df00d-0000-0000-0000-00000000f002'), 'true');
select expect_num('...the approved one is told',
  (select count(*) from notifications where template_key='shift_approved'), 1);
select expect_num('...and so is the one who was not chosen',
  (select count(*) from notifications where template_key='shift_declined'), 1);
select expect_num('no application is left pending',
  (select count(*) from shift_applications
    where occurrence_id='f00df00d-0000-0000-0000-00000000f002' and status='pending'), 0);

-- =============================================================================
-- 4. Withdrawal — the worst state in the system, so it is loud
-- =============================================================================
insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source)
values ('f00df00d-0000-0000-0000-000000000001','f00df00d-0000-0000-0000-00000000f002',
        'f00df00d-0000-0000-0000-00000000dd01','booked','staff','drop_in');
update class_occurrences set booked_count = 1 where id='f00df00d-0000-0000-0000-00000000f002';

set role authenticated;
select set_config('request.jwt.claim.sub','f00df00d-0000-0000-0000-0000000000a4',false);
do $$
begin
  perform withdraw_from_shift('f00df00d-0000-0000-0000-00000000f002');
  raise exception 'FAIL  an instructor withdrew from somebody else''s class';
exception when sqlstate 'PT403' then
  raise notice 'PASS  only the instructor teaching it can withdraw';
end $$;

select set_config('request.jwt.claim.sub','f00df00d-0000-0000-0000-0000000000a3',false);
select set_config('t.withdrew',
  (select withdraw_from_shift('f00df00d-0000-0000-0000-00000000f002')::text), false);
reset role;

select expect_text('withdrawing returns the class to open',
  (select staffing::text from class_occurrences where id='f00df00d-0000-0000-0000-00000000f002'), 'open');
select expect_text('...with nobody teaching it',
  (select (instructor_id is null)::text from class_occurrences where id='f00df00d-0000-0000-0000-00000000f002'), 'true');
select expect_num('...the studio is told, owner and manager both',
  (select count(*) from notifications where template_key='shift_withdrawn'), 2);
-- The number is the point: "nobody is teaching this" and "nobody is teaching
-- this and somebody is coming" are different emergencies.
select expect_text('...and told how many members are expecting a class',
  (select (payload ->> 'booked_line' like '%1 member is booked%')::text from notifications
    where template_key='shift_withdrawn' limit 1), 'true');
select expect_num('...and the members keep their bookings',
  (select count(*) from bookings
    where occurrence_id='f00df00d-0000-0000-0000-00000000f002' and status='booked'), 1);

select 'ALL SCHEDULING TESTS PASSED' as result;
