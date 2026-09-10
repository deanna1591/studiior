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

create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual then raise notice 'PASS  %  (got true)', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if;
end $$;

create or replace function expect_raises(label text, stmt text, want_sqlstate text)
returns void language plpgsql as $$
begin
  execute stmt;
  raise exception 'FAIL  %  expected % but nothing was raised', label, want_sqlstate;
exception when others then
  if sqlstate = want_sqlstate then raise notice 'PASS  %  (got %)', label, sqlstate;
  elsif sqlstate = 'P0001' and sqlerrm like 'FAIL%' then raise;
  else raise exception 'FAIL  %  expected %, got % (%)', label, want_sqlstate, sqlstate, sqlerrm; end if;
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
-- SCOPED TO THIS STUDIO. The suites share one `db reset` and this counted every
-- row in the table, so it was correct only for as long as no other suite wrote
-- the same template. The cover suite does, and this went from 4 to 6 without
-- anything in scheduling changing.
select expect_num('the studio is told, once per manager-or-above',
  (select count(*) from notifications where studio_id='f00df00d-0000-0000-0000-000000000001'
    and template_key='shift_application_received'), 4);
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
  (select count(*) from notifications where studio_id='f00df00d-0000-0000-0000-000000000001'
    and template_key='shift_approved'), 1);
select expect_num('...and so is the one who was not chosen',
  (select count(*) from notifications where studio_id='f00df00d-0000-0000-0000-000000000001'
    and template_key='shift_declined'), 1);
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

-- CHANGED BY DECISION 18, which overturns this edge of Decision 17 rather than
-- extending it. Withdrawing used to clear instructor_id and set staffing to
-- 'open' with nobody's approval — unconditional self-release. Decision 18 says
-- staff always approve, however urgent, so withdrawing now raises a cover
-- request and the instructor stays on the class until a person decides. The old
-- assertions are kept below, inverted, because what they used to assert is
-- exactly what must no longer happen.
select expect_text('withdrawing does NOT release the class any more',
  (select staffing::text from class_occurrences where id='f00df00d-0000-0000-0000-00000000f002'), 'assigned');
select expect_text('...the instructor is still on it',
  (select (instructor_id is not null)::text from class_occurrences where id='f00df00d-0000-0000-0000-00000000f002'), 'true');
select expect_text('...and it says so, rather than reporting a release',
  (current_setting('t.withdrew')::jsonb ->> 'still_assigned'), 'true');
select expect_num('...a cover request was raised instead',
  (select count(*) from cover_requests
    where occurrence_id='f00df00d-0000-0000-0000-00000000f002' and status='pending'), 1);
select expect_num('...the studio is told, owner and manager both',
  (select count(*) from notifications where studio_id='f00df00d-0000-0000-0000-000000000001'
    and template_key in ('cover_requested','cover_urgent')), 2);
-- The number is the point: "nobody is teaching this" and "nobody is teaching
-- this and somebody is coming" are different emergencies.
select expect_text('...and told how many members are expecting a class',
  (select (payload ->> 'booked_line' like '%1 member is booked%')::text from notifications
    where studio_id='f00df00d-0000-0000-0000-000000000001'
      and template_key in ('cover_requested','cover_urgent') limit 1), 'true');
select expect_num('...and the members keep their bookings',
  (select count(*) from bookings
    where occurrence_id='f00df00d-0000-0000-0000-00000000f002' and status='booked'), 1);

-- =============================================================================
-- 5. What a move costs (migration 050)
-- =============================================================================
-- A swap: two instructors exchange two simultaneous classes. The end state is
-- valid and every intermediate one is not, which is what DEFERRABLE is for.
update class_occurrences set instructor_id = 'f00df00d-0000-0000-0000-00000000d101',
       staffing = 'assigned' where id = 'f00df00d-0000-0000-0000-00000000f001';
update class_occurrences set starts_at = date_trunc('day', now()) + interval '2 days 9 hours',
       ends_at = date_trunc('day', now()) + interval '2 days 10 hours'
 where id = 'f00df00d-0000-0000-0000-00000000f001';
update class_occurrences set instructor_id = 'f00df00d-0000-0000-0000-00000000d102',
       staffing = 'assigned',
       starts_at = date_trunc('day', now()) + interval '2 days 9 hours',
       ends_at = date_trunc('day', now()) + interval '2 days 10 hours'
 where id = 'f00df00d-0000-0000-0000-00000000f002';

set role authenticated;
select set_config('request.jwt.claim.sub','f00df00d-0000-0000-0000-0000000000a1',false);
select expect_text('two instructors can swap two simultaneous classes',
  (select swap_instructors('f00df00d-0000-0000-0000-00000000f001',
                           'f00df00d-0000-0000-0000-00000000f002') ->> 'swapped'), 'true');
reset role;
select expect_text('...and they really did swap',
  (select (instructor_id = 'f00df00d-0000-0000-0000-00000000d102')::text
     from class_occurrences where id = 'f00df00d-0000-0000-0000-00000000f001'), 'true');

-- But the end state is still enforced: you cannot COMMIT a double-booking.
do $$
begin
  set constraints occ_instructor_no_overlap deferred;
  update class_occurrences set instructor_id = 'f00df00d-0000-0000-0000-00000000d102'
   where id = 'f00df00d-0000-0000-0000-00000000f002';
  set constraints occ_instructor_no_overlap immediate;
  raise exception 'FAIL  a double-booking survived to commit';
exception when exclusion_violation then
  raise notice 'PASS  deferring tolerates the journey, never the destination';
end $$;

-- A blocked move now names what is in the way.
set role authenticated;
select set_config('request.jwt.claim.sub','f00df00d-0000-0000-0000-0000000000a1',false);
select expect_text('a blocked move names the class in the way',
  (select move_occurrence('f00df00d-0000-0000-0000-00000000f001',
     (select starts_at from class_occurrences where id='f00df00d-0000-0000-0000-00000000f002'),
     (select ends_at   from class_occurrences where id='f00df00d-0000-0000-0000-00000000f002'),
     p_room_id => (select room_id from class_occurrences where id='f00df00d-0000-0000-0000-00000000f002'),
     p_confirm => true) -> 'blocked_by' ->> 'name'), 'Reformer');
reset role;

-- Significance, and the free cancellation it owes.
update class_occurrences set booked_count = 1 where id='f00df00d-0000-0000-0000-00000000f001';
insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source)
values ('f00df00d-0000-0000-0000-000000000001','f00df00d-0000-0000-0000-00000000f001',
        'f00df00d-0000-0000-0000-00000000dd01','booked','staff','class_pack')
on conflict do nothing;

set role authenticated;
select set_config('request.jwt.claim.sub','f00df00d-0000-0000-0000-0000000000a1',false);
select expect_text('a fifteen-minute nudge is not significant',
  (select move_occurrence('f00df00d-0000-0000-0000-00000000f001',
     date_trunc('day', now()) + interval '2 days 9 hours 15 minutes',
     date_trunc('day', now()) + interval '2 days 10 hours 15 minutes',
     p_confirm => true) ->> 'significant'), 'false');
select expect_num('...so nobody is owed a free cancellation',
  (select count(*) from bookings
    where occurrence_id='f00df00d-0000-0000-0000-00000000f001' and free_cancel_until is not null), 0);

select expect_text('moving it to the evening is significant',
  (select move_occurrence('f00df00d-0000-0000-0000-00000000f001',
     date_trunc('day', now()) + interval '2 days 18 hours',
     date_trunc('day', now()) + interval '2 days 19 hours',
     p_confirm => true) ->> 'significant'), 'true');
select expect_num('...and every booked member may now cancel without penalty',
  (select count(*) from bookings
    where occurrence_id='f00df00d-0000-0000-0000-00000000f001' and free_cancel_until is not null), 1);
reset role;

-- That grant beats the studio's cutoff, which is the whole point: they agreed
-- to a time and the studio changed it.
select expect_text('a granted free cancellation is not a late cancellation',
  (select (cancel_booking((select id from bookings
                            where occurrence_id='f00df00d-0000-0000-0000-00000000f001'
                              and status='booked' limit 1))).status::text), 'cancelled');

-- The undo window.
select expect_num('the evening move queued an email',
  (select count(*) from notifications
    where template_key='class_moved' and studio_id='f00df00d-0000-0000-0000-000000000001'), 1);
update class_occurrences set booked_count = 1 where id='f00df00d-0000-0000-0000-00000000f001';
insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source)
values ('f00df00d-0000-0000-0000-000000000001','f00df00d-0000-0000-0000-00000000f001',
        'f00df00d-0000-0000-0000-00000000dd01','booked','staff','class_pack');
set role authenticated;
select set_config('request.jwt.claim.sub','f00df00d-0000-0000-0000-0000000000a1',false);
select expect_text('dragging it straight back reads as an undo',
  (select move_occurrence('f00df00d-0000-0000-0000-00000000f001',
     date_trunc('day', now()) + interval '2 days 9 hours 15 minutes',
     date_trunc('day', now()) + interval '2 days 10 hours 15 minutes',
     p_confirm => true) ->> 'undo'), 'true');

-- =============================================================================
-- CREATING A CLASS ON THE CALENDAR (migration 089)
-- =============================================================================
-- Creation used to be a bare INSERT: no validity window, no availability check,
-- and a clash surfacing as a raw exclusion_violation. It now goes through the
-- same gate as move_occurrence(), with the same reason strings, so one screen
-- can render both.

select set_config('request.jwt.claim.sub','f00df00d-0000-0000-0000-0000000000a1',false);
set local role authenticated;

-- CLICKING AN INSTRUCTOR'S COLUMN ASSIGNS THEM.
create temporary table _c1 as select create_occurrence(
  'f00df00d-0000-0000-0000-000000000001',
  'f00df00d-0000-0000-0000-00000000cc01',
  (current_date + 3 + time '09:00') at time zone 'Europe/Prague',
  (current_date + 3 + time '09:50') at time zone 'Europe/Prague',
  'f00df00d-0000-0000-0000-00000000d101',
  'f00df00d-0000-0000-0000-00000000ee01') as r;
select expect_true('creating in an instructor''s column succeeds',
  (select (r->>'ok')::boolean from _c1));
select expect_text('...and assigns that instructor',
  (select instructor_id::text from class_occurrences
    where id = (select (r->>'occurrence_id')::uuid from _c1)),
  'f00df00d-0000-0000-0000-00000000d101');
select expect_text('...so the class is staffed, not an open shift',
  (select r->>'staffing' from _c1), 'assigned');
select expect_num('...and takes the class type''s capacity when none is given',
  (select capacity from class_occurrences
    where id = (select (r->>'occurrence_id')::uuid from _c1))::bigint,
  (select default_capacity from class_types where id='f00df00d-0000-0000-0000-00000000cc01')::bigint);
select expect_true('...as a ONE-OFF, with no series behind it',
  (select series_id is null from class_occurrences
    where id = (select (r->>'occurrence_id')::uuid from _c1)));

-- CLICKING UNASSIGNED CREATES AN OPEN SHIFT.
create temporary table _c2 as select create_occurrence(
  'f00df00d-0000-0000-0000-000000000001',
  'f00df00d-0000-0000-0000-00000000cc01',
  (current_date + 3 + time '11:00') at time zone 'Europe/Prague',
  (current_date + 3 + time '11:50') at time zone 'Europe/Prague',
  null,
  'f00df00d-0000-0000-0000-00000000ee01') as r;
select expect_text('creating in Unassigned leaves it open',
  (select r->>'staffing' from _c2), 'open');
select expect_true('...with nobody on it',
  (select instructor_id is null from class_occurrences
    where id = (select (r->>'occurrence_id')::uuid from _c2)));

-- THE NEW CLASS IS BOOKABLE IMMEDIATELY.
-- Inside the booking window on purpose: a class forty days out fails on
-- outside_booking_window, which would be §2.1 working and this assertion
-- proving nothing about whether a newly created class can be booked.
select expect_text('a class created this way can be booked straight away',
  (book_class((select (r->>'occurrence_id')::uuid from _c1),
              'f00df00d-0000-0000-0000-00000000dd01', 'staff', null, 'comp')).status::text,
  'booked');

-- A CLASH REFUSES AND NAMES WHAT IS IN THE WAY.
create temporary table _c3 as select create_occurrence(
  'f00df00d-0000-0000-0000-000000000001',
  'f00df00d-0000-0000-0000-00000000cc01',
  (current_date + 3 + time '09:20') at time zone 'Europe/Prague',
  (current_date + 3 + time '10:10') at time zone 'Europe/Prague',
  null,
  'f00df00d-0000-0000-0000-00000000ee01') as r;
select expect_true('a room already in use refuses',
  (select not (r->>'ok')::boolean from _c3));
select expect_text('...and says which of the two constraints it was',
  (select r->>'reason' from _c3), 'room_busy');
select expect_true('...and names the class in the way, with its time',
  (select (r->'blocked_by'->>'name') is not null
      and (r->'blocked_by'->>'at') is not null from _c3));
select expect_num('...and nothing was written',
  (select count(*) from class_occurrences
    where studio_id='f00df00d-0000-0000-0000-000000000001'
      and starts_at = (current_date + 3 + time '09:20') at time zone 'Europe/Prague'), 0);

-- THE SAME INSTRUCTOR IN TWO PLACES AT ONCE.
create temporary table _c4 as select create_occurrence(
  'f00df00d-0000-0000-0000-000000000001',
  'f00df00d-0000-0000-0000-00000000cc01',
  (current_date + 3 + time '09:20') at time zone 'Europe/Prague',
  (current_date + 3 + time '10:10') at time zone 'Europe/Prague',
  'f00df00d-0000-0000-0000-00000000d101',
  'f00df00d-0000-0000-0000-00000000ee02') as r;
select expect_text('an instructor already teaching refuses too, and says so',
  (select r->>'reason' from _c4), 'instructor_busy');

-- DECISION 18: OUTSIDE THE VALIDITY WINDOW IS A REFUSAL, NOT A WARNING.
insert into instructor_availability (studio_id, instructor_id, day_of_week,
                                     starts_at_time, ends_at_time,
                                     effective_from, effective_to)
values ('f00df00d-0000-0000-0000-000000000001','f00df00d-0000-0000-0000-00000000d102',
        extract(dow from current_date + 41)::int, '06:00', '22:00',
        current_date, current_date + 5);
create temporary table _c5 as select create_occurrence(
  'f00df00d-0000-0000-0000-000000000001',
  'f00df00d-0000-0000-0000-00000000cc01',
  (current_date + 41 + time '09:00') at time zone 'Europe/Prague',
  (current_date + 41 + time '09:50') at time zone 'Europe/Prague',
  'f00df00d-0000-0000-0000-00000000d102',
  'f00df00d-0000-0000-0000-00000000ee01') as r;
select expect_text('a date outside the instructor''s agreed window is refused',
  (select r->>'reason' from _c5), 'outside_availability_dates');
select expect_true('...naming who and when, because that is what a person acts on',
  (select (r->'blocked_by'->>'who') is not null
      and (r->'blocked_by'->>'on') is not null from _c5));

-- DECISION 9: OUTSIDE STATED HOURS WARNS AND SAVES.
create temporary table _c6 as select create_occurrence(
  'f00df00d-0000-0000-0000-000000000001',
  'f00df00d-0000-0000-0000-00000000cc01',
  (current_date + 2 + time '23:00') at time zone 'Europe/Prague',
  (current_date + 2 + time '23:50') at time zone 'Europe/Prague',
  'f00df00d-0000-0000-0000-00000000d102',
  'f00df00d-0000-0000-0000-00000000ee01') as r;
select expect_true('outside stated hours SAVES',
  (select (r->>'ok')::boolean from _c6));
select expect_true('...and warns',
  (select r->'warnings' @> '["outside_availability"]'::jsonb from _c6));
select expect_true('...and the class really is there',
  (select exists (select 1 from class_occurrences
    where id = (select (r->>'occurrence_id')::uuid from _c6))));

-- A DRAGGED RANGE IS JUST A LONGER CLASS.
create temporary table _c7 as select create_occurrence(
  'f00df00d-0000-0000-0000-000000000001',
  'f00df00d-0000-0000-0000-00000000cc01',
  (current_date + 42 + time '07:00') at time zone 'Europe/Prague',
  (current_date + 42 + time '08:30') at time zone 'Europe/Prague',
  null, 'f00df00d-0000-0000-0000-00000000ee01', 4) as r;
select expect_num('a dragged range sets the duration',
  (select extract(epoch from (ends_at - starts_at))::int / 60 from class_occurrences
    where id = (select (r->>'occurrence_id')::uuid from _c7))::bigint, 90);
select expect_num('...and a capacity given overrides the class type''s',
  (select capacity from class_occurrences
    where id = (select (r->>'occurrence_id')::uuid from _c7))::bigint, 4);

-- A class cannot end before it starts, and a class type from another studio is
-- not a class type this studio may use.
select expect_raises('a backwards range is refused',
  $$select create_occurrence('f00df00d-0000-0000-0000-000000000001',
      'f00df00d-0000-0000-0000-00000000cc01',
      (current_date + 43 + time '10:00') at time zone 'Europe/Prague',
      (current_date + 43 + time '09:00') at time zone 'Europe/Prague')$$, 'PT400');

-- PERMISSIONS: the same boundary the rest of the timetable has.
select set_config('request.jwt.claim.sub','f00df00d-0000-0000-0000-0000000000a2',false);
select expect_raises('front desk cannot create a class',
  $$select create_occurrence('f00df00d-0000-0000-0000-000000000001',
      'f00df00d-0000-0000-0000-00000000cc01',
      (current_date + 44 + time '10:00') at time zone 'Europe/Prague',
      (current_date + 44 + time '11:00') at time zone 'Europe/Prague')$$, 'PT403');
select set_config('request.jwt.claim.sub','f00df00d-0000-0000-0000-0000000000a1',false);


-- =============================================================================
-- move_occurrence()'s timezone and its warning (migration 090)
-- =============================================================================
-- Both found by copying this function's shape into create_occurrence() and then
-- testing the copy. Neither was covered because every fixture in this suite
-- leaves availability EMPTY, and instructor_available_at() returns true for
-- somebody who has stated nothing — so the null date never had rows to fail
-- against. These fixtures state something.

select set_config('request.jwt.claim.sub','f00df00d-0000-0000-0000-0000000000a1',false);
set local role authenticated;

insert into class_occurrences (id, studio_id, location_id, class_type_id, name, room_id,
                               capacity, starts_at, ends_at)
values ('f00df00d-0000-0000-0000-000000000099','f00df00d-0000-0000-0000-000000000001',
        'f00df00d-0000-0000-0000-00000000000c','f00df00d-0000-0000-0000-00000000cc01',
        'Assign me','f00df00d-0000-0000-0000-00000000ee02',10,
        (current_date + 6 + time '14:00') at time zone 'Europe/Prague',
        (current_date + 6 + time '15:00') at time zone 'Europe/Prague');

-- Available all day, every day, for a year: assigning them must WORK. It used
-- to be refused as "outside the dates they agreed to", because v_tz was null on
-- this path and instructor_valid_on(instructor, null) is false.
insert into instructor_availability (studio_id, instructor_id, day_of_week,
                                     starts_at_time, ends_at_time, effective_from)
select 'f00df00d-0000-0000-0000-000000000001','f00df00d-0000-0000-0000-00000000d102',
       g, '00:00', '23:59', current_date - 365 from generate_series(0,6) g;

create temporary table _m1 as select move_occurrence(
  'f00df00d-0000-0000-0000-000000000099',
  p_instructor_id => 'f00df00d-0000-0000-0000-00000000d102',
  p_confirm => true) as r;
select expect_true('an instructor available every day CAN be assigned',
  (select (r->>'ok')::boolean from _m1));
select expect_true('...with no warning, because they really are available',
  (select r->'warnings' = '[]'::jsonb from _m1));

-- Narrow their hours so the class falls outside them: WARN, not refuse, and not
-- raise. `v_warnings || 'literal'` on a text[] raised 22P02 until 090.
delete from instructor_availability where instructor_id='f00df00d-0000-0000-0000-00000000d102';
insert into instructor_availability (studio_id, instructor_id, day_of_week,
                                     starts_at_time, ends_at_time, effective_from)
select 'f00df00d-0000-0000-0000-000000000001','f00df00d-0000-0000-0000-00000000d102',
       g, '05:00', '05:30', current_date - 365 from generate_series(0,6) g;

create temporary table _m2 as select move_occurrence(
  'f00df00d-0000-0000-0000-000000000099',
  p_instructor_id => 'f00df00d-0000-0000-0000-00000000d102',
  p_confirm => true) as r;
select expect_true('outside stated HOURS still saves',
  (select (r->>'ok')::boolean from _m2));
select expect_true('...and warns rather than raising',
  (select r->'warnings' @> '["outside_availability"]'::jsonb from _m2));

-- Outside the agreed DATES: refuse, and name the date. The date used to come
-- back null, which was the tell that the check itself had a null date.
delete from instructor_availability where instructor_id='f00df00d-0000-0000-0000-00000000d102';
insert into instructor_availability (studio_id, instructor_id, day_of_week,
                                     starts_at_time, ends_at_time, effective_from, effective_to)
select 'f00df00d-0000-0000-0000-000000000001','f00df00d-0000-0000-0000-00000000d102',
       g, '00:00', '23:59', current_date - 365, current_date - 1 from generate_series(0,6) g;

create temporary table _m3 as select move_occurrence(
  'f00df00d-0000-0000-0000-000000000099',
  p_instructor_id => 'f00df00d-0000-0000-0000-00000000d102',
  p_confirm => true) as r;
select expect_text('outside the agreed DATES is refused',
  (select r->>'reason' from _m3), 'outside_availability_dates');
select expect_true('...and the refusal names the date, which it could not before',
  (select (r->'blocked_by'->>'on') is not null from _m3));
delete from instructor_availability where instructor_id='f00df00d-0000-0000-0000-00000000d102';

reset role;
select expect_num('...and the unsent email is withdrawn rather than followed by a second',
  (select count(*) from notifications
    where template_key='class_moved' and studio_id='f00df00d-0000-0000-0000-000000000001'), 0);

select 'ALL SCHEDULING TESTS PASSED' as result;
