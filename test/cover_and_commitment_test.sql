-- =============================================================================
-- Decision 18 — availability as a standing pattern, commitments, and cover
-- Migrations 053, 054 and 055. UUID space c0de, checked free.
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

create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual then raise notice 'PASS  %  (got true)', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null');
  end if;
end $$;

create or replace function expect_raises(label text, stmt text, want_sqlstate text)
returns void language plpgsql as $$
begin
  execute stmt;
  raise exception 'FAIL  %  expected % but nothing was raised', label, want_sqlstate;
exception when others then
  if sqlstate = want_sqlstate then
    raise notice 'PASS  %  (got %)', label, sqlstate;
  elsif sqlstate = 'P0001' and sqlerrm like 'FAIL%' then raise;
  else
    raise exception 'FAIL  %  expected %, got % (%)', label, want_sqlstate, sqlstate, sqlerrm;
  end if;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('c0dec0de-0000-0000-0000-0000000000a1'),   -- owner
  ('c0dec0de-0000-0000-0000-0000000000a2'),   -- front desk
  ('c0dec0de-0000-0000-0000-0000000000a3'),   -- instructor one, the one who asks
  ('c0dec0de-0000-0000-0000-0000000000a4'),   -- instructor two, the cover
  ('c0dec0de-0000-0000-0000-0000000000a5'),   -- manager
  ('c0dec0de-0000-0000-0000-0000000000b1');   -- a member
insert into profiles (id, email, full_name) values
  ('c0dec0de-0000-0000-0000-0000000000a1','cov-owner@example.com','Ovi Owner'),
  ('c0dec0de-0000-0000-0000-0000000000a2','cov-desk@example.com','Des Kay'),
  ('c0dec0de-0000-0000-0000-0000000000a3','cov-one@example.com','Ines One'),
  ('c0dec0de-0000-0000-0000-0000000000a4','cov-two@example.com','Ivo Two'),
  ('c0dec0de-0000-0000-0000-0000000000a5','cov-mgr@example.com','Man Ager'),
  ('c0dec0de-0000-0000-0000-0000000000b1','cov-mem@example.com','Mem Ber');

insert into studios (id, name, slug, timezone, currency, status) values
  ('c0dec0de-0000-0000-0000-000000000001','Cover Studio','cover-test','Europe/Prague','CZK','active');
insert into studio_settings (studio_id, cover_escalation_hours, cancellation_cutoff_minutes)
  values ('c0dec0de-0000-0000-0000-000000000001', 4, 720);
insert into locations (id, studio_id, name, is_primary) values
  ('c0dec0de-0000-0000-0000-00000000000c','c0dec0de-0000-0000-0000-000000000001','Main',true);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('c0dec0de-0000-0000-0000-00000000aa01','c0dec0de-0000-0000-0000-000000000001','c0dec0de-0000-0000-0000-0000000000a1','cov-owner@example.com','owner'),
  ('c0dec0de-0000-0000-0000-00000000aa02','c0dec0de-0000-0000-0000-000000000001','c0dec0de-0000-0000-0000-0000000000a2','cov-desk@example.com','front_desk'),
  ('c0dec0de-0000-0000-0000-00000000aa03','c0dec0de-0000-0000-0000-000000000001','c0dec0de-0000-0000-0000-0000000000a3','cov-one@example.com','instructor'),
  ('c0dec0de-0000-0000-0000-00000000aa04','c0dec0de-0000-0000-0000-000000000001','c0dec0de-0000-0000-0000-0000000000a4','cov-two@example.com','instructor'),
  ('c0dec0de-0000-0000-0000-00000000aa05','c0dec0de-0000-0000-0000-000000000001','c0dec0de-0000-0000-0000-0000000000a5','cov-mgr@example.com','manager');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('c0dec0de-0000-0000-0000-00000000ee01','c0dec0de-0000-0000-0000-000000000001','c0dec0de-0000-0000-0000-00000000000c','Room A',10),
  ('c0dec0de-0000-0000-0000-00000000ee02','c0dec0de-0000-0000-0000-000000000001','c0dec0de-0000-0000-0000-00000000000c','Room B',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('c0dec0de-0000-0000-0000-00000000cc01','c0dec0de-0000-0000-0000-000000000001','Reformer',50,10);
insert into instructors (id, studio_id, staff_id, display_name) values
  ('c0dec0de-0000-0000-0000-00000000d101','c0dec0de-0000-0000-0000-000000000001','c0dec0de-0000-0000-0000-00000000aa03','Ines One'),
  ('c0dec0de-0000-0000-0000-00000000d102','c0dec0de-0000-0000-0000-000000000001','c0dec0de-0000-0000-0000-00000000aa04','Ivo Two');
insert into members (id, studio_id, user_id, first_name, last_name, email, joined_on, status, waiver_signed_at) values
  ('c0dec0de-0000-0000-0000-00000000dd01','c0dec0de-0000-0000-0000-000000000001',
   'c0dec0de-0000-0000-0000-0000000000b1','Mem','Ber','covmem@example.com', current_date - 60, 'active', now());
insert into notification_preferences (studio_id, member_id) values
  ('c0dec0de-0000-0000-0000-000000000001','c0dec0de-0000-0000-0000-00000000dd01');

-- =============================================================================
-- 1. A whole week entered in one go, including copy-to-days
-- =============================================================================
-- The commitment first, because the pattern's effective dates default from it.
set role authenticated;
select set_config('request.jwt.claim.sub','c0dec0de-0000-0000-0000-0000000000a1',false);

insert into instructor_commitments
  (id, studio_id, instructor_id, starts_on, ends_on, min_per_week, target_per_week, shift_preference)
values ('c0dec0de-0000-0000-0000-00000000c101','c0dec0de-0000-0000-0000-000000000001',
        'c0dec0de-0000-0000-0000-00000000d101', current_date - 30, current_date + 60, 9, 12, 'both');

-- Mon-Thu identical (this IS what copy-to-days produces: the client copies the
-- ranges into the form and the whole week arrives as one payload), Friday
-- afternoon only, Saturday and Sunday stated as unavailable by being present
-- with no ranges.
select expect_num('a week goes in as one call, 9 ranges',
  set_instructor_availability('c0dec0de-0000-0000-0000-00000000d101', $j$[
    {"day":0,"ranges":[]},
    {"day":1,"ranges":[{"from":"11:00","to":"12:00"},{"from":"13:00","to":"17:00"}]},
    {"day":2,"ranges":[{"from":"11:00","to":"12:00"},{"from":"13:00","to":"17:00"}]},
    {"day":3,"ranges":[{"from":"11:00","to":"12:00"},{"from":"13:30","to":"17:00"}]},
    {"day":4,"ranges":[{"from":"11:00","to":"12:00"},{"from":"13:30","to":"17:00"}]},
    {"day":5,"ranges":[{"from":"13:00","to":"17:00"}]},
    {"day":6,"ranges":[]}
  ]$j$::jsonb)::bigint, 9);

select expect_num('Monday and Tuesday came out identical — the copy landed',
  (select count(distinct (starts_at_time, ends_at_time))
     from instructor_availability
    where instructor_id = 'c0dec0de-0000-0000-0000-00000000d101'
      and day_of_week in (1,2))::bigint, 2);

select expect_num('a day present with no ranges writes nothing and reads Unavailable',
  (select count(*) from instructor_availability
    where instructor_id = 'c0dec0de-0000-0000-0000-00000000d101'
      and day_of_week in (0,6))::bigint, 0);

select expect_text('effective_from defaulted from the commitment, not from today',
  (select min(effective_from)::text from instructor_availability
    where instructor_id = 'c0dec0de-0000-0000-0000-00000000d101' and day_of_week is not null),
  (current_date - 30)::text);

-- Re-entering the week REPLACES it rather than adding to it. This is the whole
-- reason the function takes a payload instead of a row.
select expect_num('re-entering the week replaces it',
  set_instructor_availability('c0dec0de-0000-0000-0000-00000000d101', $j$[
    {"day":1,"ranges":[{"from":"09:00","to":"12:00"}]}
  ]$j$::jsonb)::bigint, 1);
select expect_num('Monday now has one range, not three',
  (select count(*) from instructor_availability
    where instructor_id = 'c0dec0de-0000-0000-0000-00000000d101' and day_of_week = 1)::bigint, 1);
select expect_num('and a day absent from the payload was left alone',
  (select count(*) from instructor_availability
    where instructor_id = 'c0dec0de-0000-0000-0000-00000000d101' and day_of_week = 2)::bigint, 2);

select expect_raises('a range that ends before it starts is refused',
  $q$select set_instructor_availability('c0dec0de-0000-0000-0000-00000000d101',
      '[{"day":1,"ranges":[{"from":"17:00","to":"09:00"}]}]'::jsonb)$q$, 'PT422');

-- Dated exceptions are a separate act and must not be swept away by a week edit.
select expect_num('a dated exception, unavailable all day',
  set_availability_exception('c0dec0de-0000-0000-0000-00000000d101',
    current_date + 7, '[]'::jsonb, 'Away')::bigint, 1);
select expect_num('re-entering the week leaves the exception alone',
  (select set_instructor_availability('c0dec0de-0000-0000-0000-00000000d101',
     '[{"day":1,"ranges":[{"from":"09:00","to":"12:00"}]}]'::jsonb)
   from (select 1) _
   ) ::bigint, 1);
select expect_num('the exception survived',
  (select count(*) from instructor_availability
    where instructor_id = 'c0dec0de-0000-0000-0000-00000000d101'
      and exception_date = current_date + 7)::bigint, 1);

select expect_text('and instructor_available_at honours it over the weekly pattern',
  instructor_available_at('c0dec0de-0000-0000-0000-00000000d101',
    (current_date + 7)::timestamp + interval '10 hours',
    (current_date + 7)::timestamp + interval '11 hours')::text, 'false');

-- The instructor writes their own; a different instructor does not.
select set_config('request.jwt.claim.sub','c0dec0de-0000-0000-0000-0000000000a3',false);
select expect_num('the instructor may write their own',
  set_instructor_availability('c0dec0de-0000-0000-0000-00000000d101',
    '[{"day":3,"ranges":[{"from":"08:00","to":"12:00"}]}]'::jsonb)::bigint, 1);
select set_config('request.jwt.claim.sub','c0dec0de-0000-0000-0000-0000000000a4',false);
select expect_raises('another instructor may not',
  $q$select set_instructor_availability('c0dec0de-0000-0000-0000-00000000d101',
      '[{"day":3,"ranges":[{"from":"08:00","to":"12:00"}]}]'::jsonb)$q$, 'PT403');

-- Decision 18: a commitment you can lower yourself is not a commitment.
select set_config('request.jwt.claim.sub','c0dec0de-0000-0000-0000-0000000000a3',false);
update instructor_commitments set min_per_week = 1
 where id = 'c0dec0de-0000-0000-0000-00000000c101';
select expect_num('an instructor cannot lower their own minimum',
  (select min_per_week from instructor_commitments
    where id = 'c0dec0de-0000-0000-0000-00000000c101')::bigint, 9);
select expect_num('but they can read the agreement they are party to',
  (select count(*) from instructor_commitments
    where instructor_id = 'c0dec0de-0000-0000-0000-00000000d101')::bigint, 1);

select expect_text('the editor reads back the shape it draws',
  (instructor_availability_week('c0dec0de-0000-0000-0000-00000000d101')
     -> 'exceptions' -> 0 ->> 'available'), 'false');

-- =============================================================================
-- 2. Requesting cover leaves the class exactly where it was
-- =============================================================================
reset role;
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               instructor_id, capacity, starts_at, ends_at, status, staffing) values
  -- Three days out: a request, not yet an emergency.
  ('c0dec0de-0000-0000-0000-00000000f001','c0dec0de-0000-0000-0000-000000000001',
   'c0dec0de-0000-0000-0000-00000000000c','c0dec0de-0000-0000-0000-00000000cc01',
   'c0dec0de-0000-0000-0000-00000000ee01','Reformer Flow','c0dec0de-0000-0000-0000-00000000d101', 10,
   now() + interval '3 days', now() + interval '3 days 50 minutes', 'scheduled', 'assigned'),
  -- Two hours out: inside the 4-hour escalation window.
  ('c0dec0de-0000-0000-0000-00000000f002','c0dec0de-0000-0000-0000-000000000001',
   'c0dec0de-0000-0000-0000-00000000000c','c0dec0de-0000-0000-0000-00000000cc01',
   'c0dec0de-0000-0000-0000-00000000ee02','Reformer Beginners','c0dec0de-0000-0000-0000-00000000d101', 10,
   now() + interval '2 hours', now() + interval '2 hours 50 minutes', 'scheduled', 'assigned');
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source) values
  ('c0dec0de-0000-0000-0000-00000000bb01','c0dec0de-0000-0000-0000-000000000001',
   'c0dec0de-0000-0000-0000-00000000f001','c0dec0de-0000-0000-0000-00000000dd01','booked','comp');
update class_occurrences set booked_count = 1 where id = 'c0dec0de-0000-0000-0000-00000000f001';

set role authenticated;
select set_config('request.jwt.claim.sub','c0dec0de-0000-0000-0000-0000000000a3',false);
select set_config('t.req1', (select request_cover('c0dec0de-0000-0000-0000-00000000f001',
                                                 'Hospital appointment') ->> 'request_id'), false);

select expect_text('the class is STILL assigned to the instructor who asked',
  (select staffing::text from class_occurrences where id = 'c0dec0de-0000-0000-0000-00000000f001'),
  'assigned');
select expect_text('and still has their name on it',
  (select instructor_id::text from class_occurrences where id = 'c0dec0de-0000-0000-0000-00000000f001'),
  'c0dec0de-0000-0000-0000-00000000d101');
reset role;
-- What actually keeps the instructor on the class. Not the CHECK constraint,
-- which never fires: tg_derive_staffing() runs first and rewrites staffing to
-- agree with instructor_id, so this UPDATE succeeds and changes nothing. Worth
-- an assertion precisely because reading the constraint would tell you it
-- raises.
reset role;
update class_occurrences set staffing = 'open'
 where id = 'c0dec0de-0000-0000-0000-00000000f001';
select expect_text('a stray release is silently corrected, not refused',
  (select staffing::text from class_occurrences where id = 'c0dec0de-0000-0000-0000-00000000f001'),
  'assigned');
select expect_true('and the instructor is still on it',
  (select instructor_id is not null from class_occurrences
    where id = 'c0dec0de-0000-0000-0000-00000000f001'));
set role authenticated;

reset role;
select expect_num('the members were told nothing, because nothing has changed',
  (select count(*) from notifications
    where template_key = 'instructor_substituted'
      and studio_id = 'c0dec0de-0000-0000-0000-000000000001')::bigint, 0);
set role authenticated;
-- Counted with `reset role`, deliberately. notifications is under RLS and an
-- instructor session cannot see a staff row — counting from inside one returns
-- 0 whether or not the row was written, which is a test that cannot fail.
reset role;
select expect_num('owner and manager were both told, front desk was not',
  (select count(*) from notifications
    where template_key = 'cover_requested'
      and studio_id = 'c0dec0de-0000-0000-0000-000000000001')::bigint, 2);
set role authenticated;
select expect_num('asking twice does not raise a second request',
  (select count(*) from cover_requests
    where occurrence_id = 'c0dec0de-0000-0000-0000-00000000f001' and status = 'pending')::bigint, 1);
select expect_text('and says so rather than erroring',
  (select request_cover('c0dec0de-0000-0000-0000-00000000f001') ->> 'already_open'), 'true');

-- No self-release, at any notice. There is no function that lets them.
select expect_raises('an instructor cannot answer their own request',
  $q$select approve_cover_request(current_setting('t.req1')::uuid, 'open')$q$, 'PT403');
select set_config('request.jwt.claim.sub','c0dec0de-0000-0000-0000-0000000000a2',false);
select expect_raises('nor can front desk',
  $q$select approve_cover_request(current_setting('t.req1')::uuid, 'open')$q$, 'PT403');
select expect_text('and the class is untouched after both refusals',
  (select staffing::text from class_occurrences where id = 'c0dec0de-0000-0000-0000-00000000f001'),
  'assigned');

-- =============================================================================
-- 3. A same-day request escalates
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','c0dec0de-0000-0000-0000-0000000000a3',false);
-- One call, both facts read off it. Calling request_cover twice returns
-- `already_open` on the second and no verdict at all — which is correct, and
-- would have made this assertion read null forever.
select set_config('t.res2', (select request_cover('c0dec0de-0000-0000-0000-00000000f002')::text), false);
select set_config('t.req2', (current_setting('t.res2')::jsonb ->> 'request_id'), false);

select expect_text('a request two hours out is urgent on arrival',
  (current_setting('t.res2')::jsonb ->> 'urgent'), 'true');
reset role;
select expect_num('and shouted immediately rather than waiting for the sweep',
  (select count(*) from notifications
    where template_key = 'cover_urgent'
      and studio_id = 'c0dec0de-0000-0000-0000-000000000001')::bigint, 2);
set role authenticated;
select expect_true('it is stamped as escalated',
  (select escalated_at is not null from cover_requests where id = current_setting('t.req2')::uuid));
select expect_text('and it too left the instructor on the class',
  (select staffing::text from class_occurrences where id = 'c0dec0de-0000-0000-0000-00000000f002'),
  'assigned');

-- The sweep is for the request that was raised early and became urgent later.
reset role;
update cover_requests set escalated_at = null where id = current_setting('t.req1')::uuid;
update class_occurrences set starts_at = now() + interval '3 hours',
                             ends_at   = now() + interval '3 hours 50 minutes'
 where id = 'c0dec0de-0000-0000-0000-00000000f001';
select expect_num('the sweep catches a request that has become urgent since',
  sweep_cover_escalations()::bigint, 1);
select expect_num('running it again shouts nothing twice',
  sweep_cover_escalations()::bigint, 0);

set role authenticated;
select set_config('request.jwt.claim.sub','c0dec0de-0000-0000-0000-0000000000a1',false);
-- 42501, not PT403: the GRANT refuses it at the door, before the body's own
-- is_service_context() check ever runs. That check is the second line — it is
-- what stops service_role being handed to something that is not the cron.
select expect_raises('and a signed-in user cannot run the sweep at all',
  $q$select sweep_cover_escalations()$q$, '42501');

-- =============================================================================
-- 4. Approving into an open shift lands in Decision 17's flow
-- =============================================================================
select set_config('request.jwt.claim.sub','c0dec0de-0000-0000-0000-0000000000a5',false);
select expect_text('a manager opens it up',
  (select approve_cover_request(current_setting('t.req1')::uuid, 'open') ->> 'ok'), 'true');
select expect_text('the class is now an open shift',
  (select staffing::text from class_occurrences where id = 'c0dec0de-0000-0000-0000-00000000f001'),
  'open');
select expect_true('with nobody on it',
  (select instructor_id is null from class_occurrences where id = 'c0dec0de-0000-0000-0000-00000000f001'));
select expect_text('the request records how it was settled',
  (select resolution from cover_requests where id = current_setting('t.req1')::uuid), 'opened');
reset role;
select expect_num('and the instructor who asked was told they are off it',
  (select count(*) from notifications
    where template_key = 'cover_approved'
      and studio_id = 'c0dec0de-0000-0000-0000-000000000001')::bigint, 1);
set role authenticated;

-- Decision 17's machinery, unchanged.
select set_config('request.jwt.claim.sub','c0dec0de-0000-0000-0000-0000000000a4',false);
select set_config('t.app1', (select apply_for_shift('c0dec0de-0000-0000-0000-00000000f001') ->> 'application_id'), false);
select expect_num('the other instructor can apply for it',
  (select count(*) from shift_applications
    where occurrence_id = 'c0dec0de-0000-0000-0000-00000000f001' and status = 'pending')::bigint, 1);

select set_config('request.jwt.claim.sub','c0dec0de-0000-0000-0000-0000000000a5',false);
-- approve_shift_application returns {approved, warnings, auto_declined}; it has
-- no `ok` key, unlike move_occurrence. Asserting on the id it gives back.
select expect_true('and approving the application assigns them',
  (select approve_shift_application(current_setting('t.app1')::uuid) ->> 'approved') is not null);
select expect_text('the class is staffed again',
  (select staffing::text from class_occurrences where id = 'c0dec0de-0000-0000-0000-00000000f001'),
  'assigned');
reset role;
select expect_num('and THEY were told they have a class',
  (select count(*) from notifications
    where template_key = 'shift_approved'
      and studio_id = 'c0dec0de-0000-0000-0000-000000000001')::bigint, 1);
set role authenticated;

-- =============================================================================
-- 5. Approving by assigning someone, and what the members hear
-- =============================================================================
-- The 2-hour class, with a member booked, inside the 12-hour cancellation
-- cutoff — so Decision 2's free cancellation applies.
reset role;
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source) values
  ('c0dec0de-0000-0000-0000-00000000bb02','c0dec0de-0000-0000-0000-000000000001',
   'c0dec0de-0000-0000-0000-00000000f002','c0dec0de-0000-0000-0000-00000000dd01','booked','comp');
update class_occurrences set booked_count = 1 where id = 'c0dec0de-0000-0000-0000-00000000f002';

set role authenticated;
select set_config('request.jwt.claim.sub','c0dec0de-0000-0000-0000-0000000000a1',false);
select set_config('t.assign2', (select approve_cover_request(current_setting('t.req2')::uuid,
  'assign', 'c0dec0de-0000-0000-0000-00000000d102')::text), false);
select expect_text('the owner assigns a named replacement',
  (current_setting('t.assign2')::jsonb ->> 'ok'), 'true');
select expect_text('the class is taught by the replacement',
  (select instructor_id::text from class_occurrences where id = 'c0dec0de-0000-0000-0000-00000000f002'),
  'c0dec0de-0000-0000-0000-00000000d102');
reset role;
select expect_num('the booked member was told about the substitution',
  (select count(*) from notifications
    where template_key = 'instructor_substituted'
      and studio_id = 'c0dec0de-0000-0000-0000-000000000001')::bigint, 1);
set role authenticated;
select expect_true('Decision 2: announced inside the cutoff, so they may cancel free',
  (select free_cancel_until is not null from bookings
    where id = 'c0dec0de-0000-0000-0000-00000000bb02'));
select expect_text('and it says the replacement was reachable',
  (current_setting('t.assign2')::jsonb ->> 'cover_notified'), 'true');
reset role;
select expect_num('and the replacement was told they now have a class',
  (select count(*) from notifications
    where template_key = 'instructor_assigned'
      and studio_id = 'c0dec0de-0000-0000-0000-000000000001')::bigint, 1);
set role authenticated;
select expect_raises('answering a settled request twice is refused',
  $q$select decline_cover_request(current_setting('t.req2')::uuid)$q$, 'PT409');

-- Declining leaves everything exactly as it was — that is the point.
reset role;
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               instructor_id, capacity, starts_at, ends_at, status, staffing) values
  ('c0dec0de-0000-0000-0000-00000000f003','c0dec0de-0000-0000-0000-000000000001',
   'c0dec0de-0000-0000-0000-00000000000c','c0dec0de-0000-0000-0000-00000000cc01',
   'c0dec0de-0000-0000-0000-00000000ee01','Barre','c0dec0de-0000-0000-0000-00000000d101', 10,
   now() + interval '5 days', now() + interval '5 days 50 minutes', 'scheduled', 'assigned');
set role authenticated;
select set_config('request.jwt.claim.sub','c0dec0de-0000-0000-0000-0000000000a3',false);
select set_config('t.req3', (select request_cover('c0dec0de-0000-0000-0000-00000000f003') ->> 'request_id'), false);
select set_config('request.jwt.claim.sub','c0dec0de-0000-0000-0000-0000000000a1',false);
select expect_text('a declined request returns the instructor to the class explicitly',
  (select decline_cover_request(current_setting('t.req3')::uuid, 'Nobody free')
     ->> 'still_assigned_to'), 'c0dec0de-0000-0000-0000-00000000d101');
select expect_text('and the class never moved',
  (select staffing::text from class_occurrences where id = 'c0dec0de-0000-0000-0000-00000000f003'),
  'assigned');
reset role;
select expect_num('they were told they are still on it',
  (select count(*) from notifications
    where template_key = 'cover_declined'
      and studio_id = 'c0dec0de-0000-0000-0000-000000000001')::bigint, 1);
set role authenticated;

-- A replacement who is already teaching is refused, not forced.
reset role;
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               instructor_id, capacity, starts_at, ends_at, status, staffing) values
  ('c0dec0de-0000-0000-0000-00000000f004','c0dec0de-0000-0000-0000-000000000001',
   'c0dec0de-0000-0000-0000-00000000000c','c0dec0de-0000-0000-0000-00000000cc01',
   'c0dec0de-0000-0000-0000-00000000ee01','Mat','c0dec0de-0000-0000-0000-00000000d101', 10,
   now() + interval '9 days', now() + interval '9 days 50 minutes', 'scheduled', 'assigned'),
  ('c0dec0de-0000-0000-0000-00000000f005','c0dec0de-0000-0000-0000-000000000001',
   'c0dec0de-0000-0000-0000-00000000000c','c0dec0de-0000-0000-0000-00000000cc01',
   'c0dec0de-0000-0000-0000-00000000ee02','Mat','c0dec0de-0000-0000-0000-00000000d102', 10,
   now() + interval '9 days', now() + interval '9 days 50 minutes', 'scheduled', 'assigned');
set role authenticated;
select set_config('request.jwt.claim.sub','c0dec0de-0000-0000-0000-0000000000a3',false);
select set_config('t.req4', (select request_cover('c0dec0de-0000-0000-0000-00000000f004') ->> 'request_id'), false);
select set_config('request.jwt.claim.sub','c0dec0de-0000-0000-0000-0000000000a1',false);
select expect_text('a replacement who is already teaching then is refused',
  (select approve_cover_request(current_setting('t.req4')::uuid, 'assign',
     'c0dec0de-0000-0000-0000-00000000d102') ->> 'reason'), 'instructor_busy');
select expect_text('and the request is still open, so it stays visible',
  (select status from cover_requests where id = current_setting('t.req4')::uuid), 'pending');

-- An instructor with no login has no address anywhere in the schema —
-- `instructors` carries no email of its own — and that is the ORDINARY case,
-- not an edge: most instructors at a real studio never sign in. The assignment
-- still happens; the notification silently cannot, and the caller is told so
-- rather than being handed a success message implying an email went out.
reset role;
insert into instructors (id, studio_id, staff_id, display_name) values
  ('c0dec0de-0000-0000-0000-00000000d103','c0dec0de-0000-0000-0000-000000000001', null, 'Nolo Gin');
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               instructor_id, capacity, starts_at, ends_at, status, staffing) values
  ('c0dec0de-0000-0000-0000-00000000f006','c0dec0de-0000-0000-0000-000000000001',
   'c0dec0de-0000-0000-0000-00000000000c','c0dec0de-0000-0000-0000-00000000cc01',
   'c0dec0de-0000-0000-0000-00000000ee01','Mat','c0dec0de-0000-0000-0000-00000000d101', 10,
   now() + interval '12 days', now() + interval '12 days 50 minutes', 'scheduled', 'assigned');
set role authenticated;
select set_config('request.jwt.claim.sub','c0dec0de-0000-0000-0000-0000000000a3',false);
select set_config('t.req5', (select request_cover('c0dec0de-0000-0000-0000-00000000f006') ->> 'request_id'), false);
select set_config('request.jwt.claim.sub','c0dec0de-0000-0000-0000-0000000000a1',false);
select set_config('t.assign5', (select approve_cover_request(current_setting('t.req5')::uuid,
  'assign', 'c0dec0de-0000-0000-0000-00000000d103')::text), false);
select expect_text('assigning somebody with no login still works',
  (current_setting('t.assign5')::jsonb ->> 'ok'), 'true');
select expect_text('...and says plainly that they could not be told',
  (current_setting('t.assign5')::jsonb ->> 'cover_notified'), 'false');
select expect_text('...naming them, so the studio knows who to ring',
  (current_setting('t.assign5')::jsonb ->> 'cover_name'), 'Nolo Gin');

-- =============================================================================
-- 6. The brief notices both
-- =============================================================================
reset role;
-- Give Ines four complete weeks of two classes each against a minimum of nine.
insert into class_occurrences (studio_id, location_id, class_type_id, room_id, name,
                               instructor_id, capacity, starts_at, ends_at, status, staffing)
select 'c0dec0de-0000-0000-0000-000000000001','c0dec0de-0000-0000-0000-00000000000c',
       'c0dec0de-0000-0000-0000-00000000cc01','c0dec0de-0000-0000-0000-00000000ee01','Past',
       'c0dec0de-0000-0000-0000-00000000d101', 10,
       date_trunc('week', now()) - make_interval(weeks => w) + make_interval(days => d, hours => 9),
       date_trunc('week', now()) - make_interval(weeks => w) + make_interval(days => d, hours => 9, mins => 50),
       'completed', 'assigned'
  from generate_series(1,2) w, generate_series(0,1) d;

select expect_num('four classes in the last complete week, against a minimum of nine',
  (select classes from instructor_weekly_load('c0dec0de-0000-0000-0000-00000000d101', 2)
    order by week_start desc limit 1)::bigint, 2);

select generate_morning_brief('c0dec0de-0000-0000-0000-000000000001');

select expect_num('the shortfall reached the brief',
  (select count(*) from ai_insights
    where studio_id = 'c0dec0de-0000-0000-0000-000000000001'
      and type = 'commitment_shortfall'
      and for_date = (now() at time zone 'Europe/Prague')::date)::bigint, 1);
select expect_text('and it names the instructor rather than a number',
  (select subject_type from ai_insights
    where studio_id = 'c0dec0de-0000-0000-0000-000000000001'
      and type = 'commitment_shortfall'
      and for_date = (now() at time zone 'Europe/Prague')::date), 'instructor');

select expect_num('the unanswered cover request reached the brief too',
  (select count(*) from ai_insights
    where studio_id = 'c0dec0de-0000-0000-0000-000000000001'
      and type = 'cover_unanswered'
      and for_date = (now() at time zone 'Europe/Prague')::date)::bigint, 1);
-- The SENTENCE's ordering, which is the if-block order inside brief_summary and
-- is not the same thing as the insight ranking tested below.
select expect_true('and the brief''s opening sentence leads with it',
  (select summary like '%needs cover%' from morning_briefs
    where studio_id = 'c0dec0de-0000-0000-0000-000000000001'
      and brief_date = (now() at time zone 'Europe/Prague')::date));

-- Ranked ABOVE an unstaffed class, which Decision 17 put above a declined card.
reset role;
-- Inside unstaffed_urgent_days (3), or it does not qualify at all: an open
-- shift with nobody booked five days out is deliberately not brief-worthy.
update class_occurrences set staffing = 'open', instructor_id = null,
                             starts_at = now() + interval '2 days',
                             ends_at   = now() + interval '2 days 50 minutes'
 where id = 'c0dec0de-0000-0000-0000-00000000f003';
update cover_requests set escalated_at = null, requested_at = now()
 where id = current_setting('t.req4')::uuid;
update class_occurrences set starts_at = now() + interval '2 hours',
                             ends_at = now() + interval '2 hours 50 minutes'
 where id = 'c0dec0de-0000-0000-0000-00000000f004';
delete from ai_insights where studio_id = 'c0dec0de-0000-0000-0000-000000000001';
delete from morning_briefs where studio_id = 'c0dec0de-0000-0000-0000-000000000001';
select generate_morning_brief('c0dec0de-0000-0000-0000-000000000001');

-- RANK IS ONLY OBSERVABLE THROUGH THE CAP. The first version of this ordered by
-- a CASE written here in the test, which put cover_unanswered first whatever
-- the function did — it asserted its own ORDER BY and passed with the rank set
-- to 2. What rank actually decides is which candidates survive `limit v_max`,
-- so the test squeezes the cap to one and asks what is left.
reset role;
insert into insight_config (studio_id, key, value, note) values
  ('c0dec0de-0000-0000-0000-000000000001', 'max_insights', 1,
   'Squeezed for the test: with one slot, rank is the only thing that decides.')
on conflict (studio_id, key) do update set value = 1;
delete from ai_insights where studio_id = 'c0dec0de-0000-0000-0000-000000000001';
delete from morning_briefs where studio_id = 'c0dec0de-0000-0000-0000-000000000001';
select generate_morning_brief('c0dec0de-0000-0000-0000-000000000001');

select expect_num('with an unstaffed class AND a shortfall also qualifying, there are rivals',
  (select count(*) from class_occurrences
    where studio_id = 'c0dec0de-0000-0000-0000-000000000001'
      and staffing <> 'assigned' and status = 'scheduled'
      and starts_at > now())::bigint, 1);
select expect_text('and the one slot goes to the urgent cover request',
  (select type from ai_insights
    where studio_id = 'c0dec0de-0000-0000-0000-000000000001'
      and for_date = (now() at time zone 'Europe/Prague')::date), 'cover_unanswered');

reset role;
update insight_config set value = 5
 where studio_id = 'c0dec0de-0000-0000-0000-000000000001' and key = 'max_insights';
delete from ai_insights where studio_id = 'c0dec0de-0000-0000-0000-000000000001';
delete from morning_briefs where studio_id = 'c0dec0de-0000-0000-0000-000000000001';
select generate_morning_brief('c0dec0de-0000-0000-0000-000000000001');
select expect_num('with room for both, the unstaffed class is there too',
  (select count(*) from ai_insights
    where studio_id = 'c0dec0de-0000-0000-0000-000000000001'
      and type = 'unstaffed_class'
      and for_date = (now() at time zone 'Europe/Prague')::date)::bigint, 1);

select expect_true('and every action_payload points somewhere the app serves',
  (select bool_and(action_payload ->> 'href' like '/shifts/cover%'
                   or action_payload ->> 'href' like '/instructors/%'
                   or action_payload ->> 'href' like '/schedule%'
                   or action_payload ->> 'href' like '/members/%'
                   or action_payload ->> 'href' like '/roster/%')
     from ai_insights
    where studio_id = 'c0dec0de-0000-0000-0000-000000000001'
      and for_date = (now() at time zone 'Europe/Prague')::date));

-- =============================================================================
-- 7. Tenancy, and the worker's scope
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','c0dec0de-0000-0000-0000-0000000000a3',false);
select expect_num('an instructor sees their studio''s cover requests and no others',
  (select count(*) from cover_requests
    where studio_id <> 'c0dec0de-0000-0000-0000-000000000001')::bigint, 0);

reset role;
insert into notifications (studio_id, recipient_type, user_id, template_key, channel,
                           payload, dedupe_key, scheduled_for, status)
values ('c0dec0de-0000-0000-0000-000000000001','staff',
        'c0dec0de-0000-0000-0000-0000000000a1','cover_urgent','push',
        '{}'::jsonb, 'cover-push-probe', now(), 'scheduled');
select send_due_notifications();
select expect_text('a push row is not claimed by the email worker',
  (select status::text from notifications where dedupe_key = 'cover-push-probe'), 'scheduled');

-- --- The three SECURITY DEFINER reads that had no guard (migration 056) ------
-- Found by asking the advisor query's SECOND question: not "is it reachable by
-- anon" but "is it reachable by AUTHENTICATED, and is anything inside it
-- standing in the way". It was not. An ordinary MEMBER of another studio —
-- not staff, not an instructor, no relationship at all — could read a whole
-- weekly availability pattern through the SECURITY DEFINER wrapper while the
-- direct table read correctly returned nothing. The direct read is asserted
-- here too, because it is what proves the leak was the wrapper stepping over a
-- policy that was doing its job, rather than the policy being wrong.
reset role;
insert into auth.users (id) values ('c0dec0de-0000-0000-0000-0000000000c1');
insert into profiles (id, email, full_name) values
  ('c0dec0de-0000-0000-0000-0000000000c1','cov-outsider@example.com','Otto Sider');
insert into studios (id, name, slug, timezone, currency, status) values
  ('c0dec0de-0000-0000-0000-000000000002','Other Studio','cover-other','Europe/Prague','CZK','active');
insert into studio_settings (studio_id) values ('c0dec0de-0000-0000-0000-000000000002');
insert into members (id, studio_id, user_id, first_name, last_name, email, joined_on, status) values
  ('c0dec0de-0000-0000-0000-00000000dd99','c0dec0de-0000-0000-0000-000000000002',
   'c0dec0de-0000-0000-0000-0000000000c1','Otto','Sider','ottosider@example.com', current_date, 'active');

set role authenticated;
select set_config('request.jwt.claim.sub','c0dec0de-0000-0000-0000-0000000000c1',false);
select expect_num('RLS already hid the rows from a member of another studio',
  (select count(*) from instructor_availability
    where instructor_id = 'c0dec0de-0000-0000-0000-00000000d101')::bigint, 0);
select expect_raises('...and the definer wrapper no longer steps over it',
  $q$select instructor_availability_week('c0dec0de-0000-0000-0000-00000000d101')$q$, 'PT403');
select expect_raises('...nor does the weekly load',
  $q$select * from instructor_weekly_load('c0dec0de-0000-0000-0000-00000000d101', 4)$q$, 'PT403');
select expect_raises('...nor 047''s availability check, which had it too',
  $q$select instructor_available_at('c0dec0de-0000-0000-0000-00000000d101', now(), now() + interval '1 hour')$q$, 'PT403');
-- An unknown id answers the same way, so the refusal cannot be used to probe
-- which instructor ids exist.
select expect_raises('an id that does not exist is refused identically',
  $q$select instructor_availability_week('c0dec0de-0000-0000-0000-0000000000ff')$q$, 'PT403');

-- And the people who SHOULD read it still can, or the guard is just a break.
select set_config('request.jwt.claim.sub','c0dec0de-0000-0000-0000-0000000000a5',false);
select expect_true('a manager of that studio still reads the pattern',
  (instructor_availability_week('c0dec0de-0000-0000-0000-00000000d101') -> 'days') is not null);
select set_config('request.jwt.claim.sub','c0dec0de-0000-0000-0000-0000000000a3',false);
select expect_true('and the instructor still reads their own',
  (instructor_availability_week('c0dec0de-0000-0000-0000-00000000d101') -> 'days') is not null);
select expect_raises('but not a colleague''s',
  $q$select instructor_availability_week('c0dec0de-0000-0000-0000-00000000d102')$q$, 'PT403');

-- --- Function exposure -------------------------------------------------------
select expect_num('no Decision 18 internal is reachable by anon',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('queue_instructor_assigned','sweep_cover_escalations')
      and has_function_privilege('anon', p.oid, 'execute'))::bigint, 0);
select expect_num('nor by any signed-in user',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('queue_instructor_assigned','sweep_cover_escalations')
      and has_function_privilege('authenticated', p.oid, 'execute'))::bigint, 0);
