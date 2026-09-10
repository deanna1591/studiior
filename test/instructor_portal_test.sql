-- =============================================================================
-- The instructor portal — migration 097. UUID space beef, checked free.
-- =============================================================================
-- Every one of Reform Collective's six instructors had staff_id null, so none
-- could sign in and every instructor notification ever built was queued for
-- somebody with no address. This suite covers the invite that fixes that, and
-- the §14 boundary the portal has to hold: an instructor learns enough to
-- teach the class well and nothing about the person's contact details or their
-- documents.
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
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual,'null'); end if;
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
  execute stmt; raise exception 'FAIL  %  expected % but nothing was raised', label, want_sqlstate;
exception when others then
  if sqlstate = want_sqlstate then raise notice 'PASS  %  (got %)', label, sqlstate;
  elsif sqlstate = 'P0001' and sqlerrm like 'FAIL%' then raise;
  else raise exception 'FAIL  %  expected %, got % (%)', label, want_sqlstate, sqlstate, sqlerrm; end if;
end $$;

-- ===========================================================================
-- TWO STUDIOS, in two timezones, decided in one run.
-- ===========================================================================
insert into auth.users (id) values
  ('beefbeef-0000-0000-0000-0000000000a1'),   -- studio A owner
  ('beefbeef-0000-0000-0000-0000000000b1');   -- studio B owner
insert into profiles (id, email, full_name) values
  ('beefbeef-0000-0000-0000-0000000000a1','beef-a-owner@example.com','A Owner'),
  ('beefbeef-0000-0000-0000-0000000000b1','beef-b-owner@example.com','B Owner');
insert into studios (id, name, slug, timezone, currency, country, status) values
  ('beefbeef-0000-0000-0000-00000000000a','Manila Movement','beef-manila','Asia/Manila','PHP','PH','active'),
  ('beefbeef-0000-0000-0000-00000000000b','Prague Pilates','beef-prague','Europe/Prague','CZK','CZ','active');
insert into studio_settings (studio_id, checkin_window_enforced) values
  ('beefbeef-0000-0000-0000-00000000000a', false),
  ('beefbeef-0000-0000-0000-00000000000b', false);
insert into locations (id, studio_id, name, timezone, is_primary) values
  ('beefbeef-0000-0000-0000-0000000000fa','beefbeef-0000-0000-0000-00000000000a','Main','Asia/Manila',true),
  ('beefbeef-0000-0000-0000-0000000000fb','beefbeef-0000-0000-0000-00000000000b','Main','Europe/Prague',true);
insert into studio_staff (studio_id, user_id, email, role) values
  ('beefbeef-0000-0000-0000-00000000000a','beefbeef-0000-0000-0000-0000000000a1','beef-a-owner@example.com','owner'),
  ('beefbeef-0000-0000-0000-00000000000b','beefbeef-0000-0000-0000-0000000000b1','beef-b-owner@example.com','owner');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('beefbeef-0000-0000-0000-00000000c001','beefbeef-0000-0000-0000-00000000000a','beefbeef-0000-0000-0000-0000000000fa','Reformer Room',8),
  ('beefbeef-0000-0000-0000-00000000c002','beefbeef-0000-0000-0000-00000000000b','beefbeef-0000-0000-0000-0000000000fb','Studio',8);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('beefbeef-0000-0000-0000-00000000d001','beefbeef-0000-0000-0000-00000000000a','Reformer',60,8),
  ('beefbeef-0000-0000-0000-00000000d002','beefbeef-0000-0000-0000-00000000000b','Mat',60,8);

-- THREE INSTRUCTORS, in the three states this feature exists to tell apart:
-- one with an email waiting to be asked, one with none at all, and one at the
-- other studio entirely.
insert into instructors (id, studio_id, display_name, status) values
  ('beefbeef-0000-0000-0000-00000000e001','beefbeef-0000-0000-0000-00000000000a','Isla Teacher','active'),
  ('beefbeef-0000-0000-0000-00000000e002','beefbeef-0000-0000-0000-00000000000a','Noemi Noemail','active'),
  ('beefbeef-0000-0000-0000-00000000e003','beefbeef-0000-0000-0000-00000000000b','Otto Elsewhere','active');

\echo ''
\echo '=== 1. THE PREREQUISITE — an instructor with no staff row cannot be reached ==='
select expect_num('an instructor with no staff row has no address at all',
  (select count(*) from instructors i
    where i.id = 'beefbeef-0000-0000-0000-00000000e001'
      and instructor_user_id(i.id) is null), 1);
-- instructors.staff_id IS A studio_staff ID, NOT A USER ID. Migration 054
-- passed it straight into queue_shift_notice() three times.
select expect_true('and staff_id, when it exists, points at studio_staff and not at auth.users',
  (select count(*) = 1 from information_schema.table_constraints tc
     join information_schema.constraint_column_usage ccu on ccu.constraint_name = tc.constraint_name
    where tc.table_name = 'instructors' and tc.constraint_type = 'FOREIGN KEY'
      and ccu.table_name = 'studio_staff'));

\echo ''
\echo '=== 2. THE INVITE ==='
set role authenticated;
select set_config('request.jwt.claim.sub','beefbeef-0000-0000-0000-0000000000a1',false);

-- AN INSTRUCTOR WITH NO EMAIL IS REFUSED BY NAME, rather than queueing a
-- notification with a null address — which is precisely what has been
-- happening silently to all six of Reform Collective's.
select expect_raises('an instructor with no email cannot be invited',
  $$ select invite_instructor('beefbeef-0000-0000-0000-00000000e002', null) $$, 'PT422');
select expect_raises('nor with something that is not an address',
  $$ select invite_instructor('beefbeef-0000-0000-0000-00000000e002', 'not-an-email') $$, 'PT422');

select set_config('t.inv', invite_instructor(
  'beefbeef-0000-0000-0000-00000000e001','isla@example.com')::text, false);
select expect_true('inviting creates the staff row the instructor was missing',
  (select staff_id is not null from instructors where id = 'beefbeef-0000-0000-0000-00000000e001'));
select expect_text('as an instructor of that studio, not yet joined',
  (select ss.role::text || '/' || ss.status from studio_staff ss
     join instructors i on i.staff_id = ss.id
    where i.id = 'beefbeef-0000-0000-0000-00000000e001'), 'instructor/invited');
select expect_true('with no login until they claim it',
  (select ss.user_id is null from studio_staff ss
     join instructors i on i.staff_id = ss.id
    where i.id = 'beefbeef-0000-0000-0000-00000000e001'));
select expect_num('and exactly one email is queued',
  (select count(*) from notifications
    where studio_id = 'beefbeef-0000-0000-0000-00000000000a'
      and template_key = 'instructor_invite'), 1);
reset role;

select set_config('t.tok',
  (select regexp_replace(payload ->> 'claim_url', '.*/', '') from notifications
    where template_key = 'instructor_invite'
      and studio_id = 'beefbeef-0000-0000-0000-00000000000a'
    order by created_at desc limit 1), false);

-- A RESEND SUPERSEDES. Migration 073 learned this the hard way: keying the
-- dedupe on the person made a resend silently do nothing, and the suite passed
-- because the assertion for it was missing.
set role authenticated;
select set_config('request.jwt.claim.sub','beefbeef-0000-0000-0000-0000000000a1',false);
select invite_instructor('beefbeef-0000-0000-0000-00000000e001','isla@example.com');
reset role;
select expect_num('a resend sends a second email',
  (select count(*) from notifications
    where studio_id = 'beefbeef-0000-0000-0000-00000000000a'
      and template_key = 'instructor_invite'), 2);
select expect_num('and leaves exactly one live invite, not two',
  (select count(*) from studio_invites
    where instructor_id = 'beefbeef-0000-0000-0000-00000000e001' and accepted_at is null), 1);
set role anon;
select expect_text('so the first link is dead',
  instructor_invite_preview(current_setting('t.tok')) ->> 'state', 'invalid');
reset role;

select set_config('t.tok',
  (select regexp_replace(payload ->> 'claim_url', '.*/', '') from notifications
    where template_key = 'instructor_invite'
      and studio_id = 'beefbeef-0000-0000-0000-00000000000a'
    order by created_at desc limit 1), false);

\echo ''
\echo '--- the claim, twice ---'
set role anon;
-- A token is a bearer credential: the preview shows enough to know you are in
-- the right place and nothing else.
select expect_text('the preview names the studio', 
  instructor_invite_preview(current_setting('t.tok')) ->> 'studio_name', 'Manila Movement');
select expect_true('and carries no member or business data at all',
  (select not (instructor_invite_preview(current_setting('t.tok')) ?| array['bio','classes','pay','members'])));
select expect_text('a short password is refused',
  claim_instructor_account(current_setting('t.tok'), 'short') ->> 'state', 'password_too_short');
select expect_text('the claim works once',
  claim_instructor_account(current_setting('t.tok'), 'a-real-password', 'Isla Teacher') ->> 'state', 'ok');
select expect_text('and the same link cannot be used again',
  claim_instructor_account(current_setting('t.tok'), 'another-password') ->> 'state', 'used');
reset role;

select expect_true('the instructor now has a login',
  (select instructor_user_id('beefbeef-0000-0000-0000-00000000e001') is not null));
select expect_text('and the staff row has joined',
  (select ss.status from studio_staff ss join instructors i on i.staff_id = ss.id
    where i.id = 'beefbeef-0000-0000-0000-00000000e001'), 'active');
-- The whole point: every instructor notification built so far can now reach
-- this person, where before it returned null and the cover flow honestly
-- reported them as unreachable.
select expect_num('so a shift notice finally has somewhere to go',
  (select count(*) from studio_staff ss
    where ss.id = (select staff_id from instructors where id = 'beefbeef-0000-0000-0000-00000000e001')
      and ss.user_id = instructor_user_id('beefbeef-0000-0000-0000-00000000e001')), 1);

select set_config('t.isla', instructor_user_id('beefbeef-0000-0000-0000-00000000e001')::text, false);

\echo ''
\echo '=== 3. THE ROSTER — §14, and what an instructor must NOT learn ==='
-- A class Isla teaches, with three members: one who has been before, one on
-- their first ever class, and one whose notes an instructor must not see.
insert into members (id, studio_id, first_name, last_name, preferred_name, email, phone,
                     date_of_birth, joined_on, status, created_at) values
  ('beefbeef-0000-0000-0000-00000000ee01','beefbeef-0000-0000-0000-00000000000a','Regina','Regular','Reggie','regina@example.com','+63 900 111 1111', date '1990-04-04', current_date - 200,'active', now()),
  ('beefbeef-0000-0000-0000-00000000ee02','beefbeef-0000-0000-0000-00000000000a','Newton','Newcomer',null,'newton@example.com','+63 900 222 2222', date '1992-06-06', current_date - 2,'active', now()),
  ('beefbeef-0000-0000-0000-00000000ee03','beefbeef-0000-0000-0000-00000000000a','Priya','Private',null,'priya@example.com','+63 900 333 3333', null, current_date - 100,'active', now());

insert into class_occurrences (id, studio_id, location_id, class_type_id, name, instructor_id,
                               room_id, capacity, starts_at, ends_at, status)
values ('beefbeef-0000-0000-0000-0000000000c1','beefbeef-0000-0000-0000-00000000000a',
        'beefbeef-0000-0000-0000-0000000000fa','beefbeef-0000-0000-0000-00000000d001',
        'Reformer','beefbeef-0000-0000-0000-00000000e001','beefbeef-0000-0000-0000-00000000c001', 8,
        (studio_today('beefbeef-0000-0000-0000-00000000000a') + 1 + time '07:00') at time zone 'Asia/Manila',
        (studio_today('beefbeef-0000-0000-0000-00000000000a') + 1 + time '08:00') at time zone 'Asia/Manila',
        'scheduled'),
       -- A class taught by NOBODY Isla is, at the other studio.
       ('beefbeef-0000-0000-0000-0000000000c2','beefbeef-0000-0000-0000-00000000000b',
        'beefbeef-0000-0000-0000-0000000000fb','beefbeef-0000-0000-0000-00000000d002',
        'Mat','beefbeef-0000-0000-0000-00000000e003','beefbeef-0000-0000-0000-00000000c002', 8,
        (studio_today('beefbeef-0000-0000-0000-00000000000b') + 1 + time '18:00') at time zone 'Europe/Prague',
        (studio_today('beefbeef-0000-0000-0000-00000000000b') + 1 + time '19:00') at time zone 'Europe/Prague',
        'scheduled');

insert into bookings (id, studio_id, occurrence_id, member_id, status, source, booked_at) values
  ('beefbeef-0000-0000-0000-00000000bb01','beefbeef-0000-0000-0000-00000000000a','beefbeef-0000-0000-0000-0000000000c1','beefbeef-0000-0000-0000-00000000ee01','booked','staff', now()),
  ('beefbeef-0000-0000-0000-00000000bb02','beefbeef-0000-0000-0000-00000000000a','beefbeef-0000-0000-0000-0000000000c1','beefbeef-0000-0000-0000-00000000ee02','booked','staff', now()),
  ('beefbeef-0000-0000-0000-00000000bb03','beefbeef-0000-0000-0000-00000000000a','beefbeef-0000-0000-0000-0000000000c1','beefbeef-0000-0000-0000-00000000ee03','booked','staff', now());

-- Regina has been before; Newton and Priya have not.
insert into class_occurrences (id, studio_id, location_id, class_type_id, name, instructor_id,
                               room_id, capacity, starts_at, ends_at, status)
values ('beefbeef-0000-0000-0000-0000000000c3','beefbeef-0000-0000-0000-00000000000a',
        'beefbeef-0000-0000-0000-0000000000fa','beefbeef-0000-0000-0000-00000000d001',
        'Reformer','beefbeef-0000-0000-0000-00000000e001','beefbeef-0000-0000-0000-00000000c001', 8,
        now() - interval '7 days', now() - interval '7 days' + interval '1 hour', 'completed');
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, booked_at) values
  ('beefbeef-0000-0000-0000-00000000bb04','beefbeef-0000-0000-0000-00000000000a','beefbeef-0000-0000-0000-0000000000c3','beefbeef-0000-0000-0000-00000000ee01','attended','staff', now() - interval '8 days');
insert into check_ins (studio_id, booking_id, member_id, occurrence_id, checked_in_at, method) values
  ('beefbeef-0000-0000-0000-00000000000a','beefbeef-0000-0000-0000-00000000bb04','beefbeef-0000-0000-0000-00000000ee01','beefbeef-0000-0000-0000-0000000000c3', now() - interval '7 days','staff');

-- Three notes: a pinned injury an instructor SHOULD see, a pinned
-- managers-only one they must NOT, and an unpinned one that is not for the
-- roster at all.
insert into member_notes (studio_id, member_id, author_user_id, category, body, pinned, managers_only) values
  ('beefbeef-0000-0000-0000-00000000000a','beefbeef-0000-0000-0000-00000000ee01','beefbeef-0000-0000-0000-0000000000a1','injury','Right shoulder — no overhead load.', true, false),
  ('beefbeef-0000-0000-0000-00000000000a','beefbeef-0000-0000-0000-00000000ee03','beefbeef-0000-0000-0000-0000000000a1','general','Disputed an invoice in March.', true, true),
  ('beefbeef-0000-0000-0000-00000000000a','beefbeef-0000-0000-0000-00000000ee01','beefbeef-0000-0000-0000-0000000000a1','general','Prefers the window reformer.', false, false);

-- A medical document on file. §14 and migration 059 keep these manager-up;
-- front desk see everything except the medical one and an instructor sees none.
insert into member_documents (studio_id, member_id, kind, filename, storage_path, uploaded_by) values
  ('beefbeef-0000-0000-0000-00000000000a','beefbeef-0000-0000-0000-00000000ee01','medical','shoulder-mri.pdf','beefbeef/med.pdf','beefbeef-0000-0000-0000-0000000000a1');

set role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.isla'), false);
select set_config('t.r', instructor_roster('beefbeef-0000-0000-0000-0000000000c1')::text, false);

select expect_num('the roster shows everybody booked in',
  jsonb_array_length(current_setting('t.r')::jsonb -> 'members'), 3);

-- A MEMBER'S FIRST EVER CLASS is the fact that decides how the next hour goes.
select expect_true('somebody who has never been is flagged as a first-timer',
  (select (m ->> 'first_timer')::boolean from jsonb_array_elements(current_setting('t.r')::jsonb -> 'members') m
    where m ->> 'name' like 'Newton%'));
select expect_true('and somebody who has been is not',
  (select (m ->> 'first_timer')::boolean = false from jsonb_array_elements(current_setting('t.r')::jsonb -> 'members') m
    where m ->> 'name' like 'Reggie%'));
select expect_text('the preferred name is what they are called',
  (select m ->> 'name' from jsonb_array_elements(current_setting('t.r')::jsonb -> 'members') m
    where m ->> 'name' like 'Reggie%'), 'Reggie Regular');

-- Pinned notes reach the roster. That is the screen that makes an instructor
-- good at their job: knowing about the shoulder BEFORE the class.
select expect_num('a pinned injury note reaches the instructor',
  (select jsonb_array_length(m -> 'pinned_notes') from jsonb_array_elements(current_setting('t.r')::jsonb -> 'members') m
    where m ->> 'name' like 'Reggie%'), 1);
select expect_true('and says what it is about',
  (select (m -> 'pinned_notes' -> 0 ->> 'body') like '%shoulder%'
     from jsonb_array_elements(current_setting('t.r')::jsonb -> 'members') m
    where m ->> 'name' like 'Reggie%'));

-- THE THREE THINGS §14 KEEPS FROM THEM.
select expect_num('a managers-only note does NOT',
  (select jsonb_array_length(m -> 'pinned_notes') from jsonb_array_elements(current_setting('t.r')::jsonb -> 'members') m
    where m ->> 'name' like 'Priya%'), 0);
select expect_true('the managers-only text appears nowhere in the answer at all',
  current_setting('t.r') not like '%Disputed an invoice%');
select expect_true('no email address is anywhere in it',
  current_setting('t.r') not like '%@example.com%');
select expect_true('nor a phone number',
  current_setting('t.r') not like '%+63 900%');
select expect_true('nor any document on file',
  current_setting('t.r') not like '%med.pdf%'
  and current_setting('t.r') not like '%shoulder-mri%');
-- An unpinned note is not roster material either; pinning is the act that
-- puts something in front of an instructor.
select expect_true('and an unpinned note stays off it',
  current_setting('t.r') not like '%window reformer%');

-- §8: an instructor MAY check somebody in. They may not correct a no-show or
-- create a walk-in, so the screen does not draw those.
select expect_text('the roster says check-in is theirs to do',
  current_setting('t.r')::jsonb ->> 'can_check_in', 'true');
insert into check_ins (studio_id, booking_id, member_id, occurrence_id, method)
values ('beefbeef-0000-0000-0000-00000000000a','beefbeef-0000-0000-0000-00000000bb01',
        'beefbeef-0000-0000-0000-00000000ee01','beefbeef-0000-0000-0000-0000000000c1','staff');
select expect_num('and an instructor really can write a check-in',
  (select count(*) from check_ins
    where booking_id = 'beefbeef-0000-0000-0000-00000000bb01'), 1);

-- SOMEBODY ELSE'S CLASS IS SOMEBODY ELSE'S MEMBERS.
select expect_raises('a roster for a class they do not teach is refused',
  $$ select instructor_roster('beefbeef-0000-0000-0000-0000000000c2') $$, 'PT403');
reset role;

\echo ''
\echo '=== 4. THEIR OWN WEEK, THEIR OWN PAY, THEIR OWN RECORD ==='
set role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.isla'), false);
select set_config('t.w', instructor_week('beefbeef-0000-0000-0000-00000000e001',
  studio_today('beefbeef-0000-0000-0000-00000000000a'),
  studio_today('beefbeef-0000-0000-0000-00000000000a') + 6)::text, false);

select expect_num('their week shows the class they are teaching',
  jsonb_array_length(current_setting('t.w')::jsonb -> 'classes'), 1);
-- Every time is the STUDIO's. A 07:00 Manila class is stored at 23:00 UTC the
-- previous day, and an instructor reading 23:00 would turn up on the wrong day.
select expect_text('at the time the studio runs it, not the server''s',
  (current_setting('t.w')::jsonb -> 'classes' -> 0 ->> 'local_start'), '07:00');
select expect_text('on the studio''s own date',
  (current_setting('t.w')::jsonb -> 'classes' -> 0 ->> 'local_date'),
  (studio_today('beefbeef-0000-0000-0000-00000000000a') + 1)::text);

select expect_raises('another instructor''s week is refused',
  $$ select instructor_week('beefbeef-0000-0000-0000-00000000e003', current_date, current_date + 6) $$, 'PT403');
select expect_raises('another instructor''s pay is refused',
  $$ select instructor_pay_summary('beefbeef-0000-0000-0000-00000000e003') $$, 'PT403');
select expect_raises('and another instructor''s record',
  $$ select instructor_recognition('beefbeef-0000-0000-0000-00000000e003') $$, 'PT403');
-- Their own is theirs.
select expect_text('their own pay answers',
  (instructor_pay_summary('beefbeef-0000-0000-0000-00000000e001') ->> 'state'), 'no_period');
select expect_num('their own record counts the class they have taught',
  (instructor_recognition('beefbeef-0000-0000-0000-00000000e001') ->> 'classes_taught')::bigint, 1);
-- Decision 10: a personal count, never a ranking. §12 note 20 is explicit.
select expect_true('and says out loud that it is not a leaderboard',
  (instructor_recognition('beefbeef-0000-0000-0000-00000000e001') ->> 'not_a_leaderboard') is not null);

-- Nothing about the STUDIO's business. An instructor opening this must not get
-- a dashboard of numbers about somebody else's company.
select expect_raises('an instructor cannot read the studio''s takings',
  $$ select dashboard_kpis('beefbeef-0000-0000-0000-00000000000a') $$, 'PT403');
select expect_raises('nor who owes it money',
  $$ select memberships_due('beefbeef-0000-0000-0000-00000000000a', 7) $$, 'PT403');
select expect_raises('nor the whole timetable',
  $$ select * from schedule_range('beefbeef-0000-0000-0000-00000000000a', current_date, current_date + 6) $$, 'PT403');
select expect_raises('nor invite anybody',
  $$ select invite_instructor('beefbeef-0000-0000-0000-00000000e002','someone@example.com') $$, 'PT403');
select expect_raises('nor see who has been invited',
  $$ select instructor_invite_status('beefbeef-0000-0000-0000-00000000000a') $$, 'PT403');
reset role;

\echo ''
\echo '=== 5. THE OTHER STUDIO, IN THE SAME RUN ==='
set role authenticated;
select set_config('request.jwt.claim.sub','beefbeef-0000-0000-0000-0000000000b1',false);
select expect_num('the other studio''s owner sees only their own instructors',
  (select count(*) from jsonb_array_elements(
     instructor_invite_status('beefbeef-0000-0000-0000-00000000000b')) r), 1);
select expect_text('and the one they see is theirs',
  (select r ->> 'display_name' from jsonb_array_elements(
     instructor_invite_status('beefbeef-0000-0000-0000-00000000000b')) r), 'Otto Elsewhere');
select expect_raises('they cannot invite the first studio''s instructor',
  $$ select invite_instructor('beefbeef-0000-0000-0000-00000000e002','x@example.com') $$, 'PT403');
reset role;

-- anon reaches the two pre-login surfaces and nothing else. These are the
-- eighth and ninth in the codebase and the count is deliberate.
set role anon;
select expect_text('anon may preview an invite',
  instructor_invite_preview('nonsense') ->> 'state', 'invalid');
select expect_raises('and nothing else the portal has',
  $$ select my_instructor() $$, '42501');
select expect_raises('nor a roster',
  $$ select instructor_roster('beefbeef-0000-0000-0000-0000000000c1') $$, '42501');
select expect_raises('nor anybody''s pay',
  $$ select instructor_pay_summary('beefbeef-0000-0000-0000-00000000e001') $$, '42501');
reset role;

select 'ALL INSTRUCTOR PORTAL TESTS PASSED' as result;
