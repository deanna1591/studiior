-- =============================================================================
-- Instructors submit their own availability, and confirm their own week
-- Migrations 066 and 067. UUID space 1f5e, checked free.
-- =============================================================================
-- TWO STUDIOS ON DIFFERENT SETTINGS, IN ONE RUN. Every day and window in
-- migration 067 is a per-studio column, and a constant hiding behind a default
-- reads exactly like a setting until a second studio arrives. Studio A is set
-- so that TODAY is its ask day; studio B so that today is not. Both are checked
-- in the same sweep.
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
  if sqlstate = want_sqlstate then raise notice 'PASS  %  (got %)', label, sqlstate;
  elsif sqlstate = 'P0001' and sqlerrm like 'FAIL%' then raise;
  else raise exception 'FAIL  %  expected %, got % (%)', label, want_sqlstate, sqlstate, sqlerrm;
  end if;
end $$;

-- --- Fixtures ---------------------------------------------------------------
insert into auth.users (id) values
  ('1f5e1f5e-0000-0000-0000-0000000000a1'),   -- studio A owner
  ('1f5e1f5e-0000-0000-0000-0000000000a2'),   -- studio A instructor, with a login
  ('1f5e1f5e-0000-0000-0000-0000000000a3'),   -- studio A second instructor
  ('1f5e1f5e-0000-0000-0000-0000000000b1');   -- studio B owner
insert into profiles (id, email, full_name) values
  ('1f5e1f5e-0000-0000-0000-0000000000a1','iss-owner-a@example.com','Ola A'),
  ('1f5e1f5e-0000-0000-0000-0000000000a2','iss-ines@example.com','Ines Instructor'),
  ('1f5e1f5e-0000-0000-0000-0000000000a3','iss-ivo@example.com','Ivo Instructor'),
  ('1f5e1f5e-0000-0000-0000-0000000000b1','iss-owner-b@example.com','Ola B');

insert into studios (id, name, slug, timezone, currency, status) values
  ('1f5e1f5e-0000-0000-0000-000000000001','Self Serve A','iss-a','Europe/Prague','CZK','active'),
  ('1f5e1f5e-0000-0000-0000-000000000002','Self Serve B','iss-b','Europe/Prague','CZK','active');

-- THE SETTINGS DIFFER, and every date below is computed from them rather than
-- from a weekday name. Studio A: today is its ask day, its remind day and its
-- escalate day, with a 3-day escalation window. Studio B: tomorrow is, with a
-- 7-day window — so nothing of B's may appear in a sweep run today.
--
-- "TODAY" IS THE STUDIO'S DAY, NOT THE SERVER'S. Both studios are in Prague and
-- the sweep asks on the studio-local weekday; this fixture used current_date,
-- which is UTC, and for the two hours a night when Prague is already tomorrow
-- the suite set the ask day to yesterday and failed — found at 22:31 UTC while
-- checking migration 112. The same trap `starts_on` was in (migration 095).
select set_config('t.today', (now() at time zone 'Europe/Prague')::date::text, false);
insert into studio_settings
  (studio_id, availability_due_day,
   week_confirm_ask_dow, week_confirm_remind_dow, week_confirm_escalate_dow,
   week_confirm_escalate_days)
values
  ('1f5e1f5e-0000-0000-0000-000000000001', 20,
   extract(dow from current_setting('t.today')::date)::int,
   extract(dow from current_setting('t.today')::date)::int,
   extract(dow from current_setting('t.today')::date)::int, 3),
  ('1f5e1f5e-0000-0000-0000-000000000002', 5,
   extract(dow from current_setting('t.today')::date + 1)::int,
   extract(dow from current_setting('t.today')::date + 1)::int,
   extract(dow from current_setting('t.today')::date + 1)::int, 7);

insert into locations (id, studio_id, name, is_primary) values
  ('1f5e1f5e-0000-0000-0000-00000000000c','1f5e1f5e-0000-0000-0000-000000000001','Main',true),
  ('1f5e1f5e-0000-0000-0000-00000000000d','1f5e1f5e-0000-0000-0000-000000000002','Main',true);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('1f5e1f5e-0000-0000-0000-00000000aa01','1f5e1f5e-0000-0000-0000-000000000001','1f5e1f5e-0000-0000-0000-0000000000a1','iss-owner-a@example.com','owner'),
  ('1f5e1f5e-0000-0000-0000-00000000aa02','1f5e1f5e-0000-0000-0000-000000000001','1f5e1f5e-0000-0000-0000-0000000000a2','iss-ines@example.com','instructor'),
  ('1f5e1f5e-0000-0000-0000-00000000aa03','1f5e1f5e-0000-0000-0000-000000000001','1f5e1f5e-0000-0000-0000-0000000000a3','iss-ivo@example.com','instructor'),
  ('1f5e1f5e-0000-0000-0000-00000000bb01','1f5e1f5e-0000-0000-0000-000000000002','1f5e1f5e-0000-0000-0000-0000000000b1','iss-owner-b@example.com','owner');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('1f5e1f5e-0000-0000-0000-00000000ee01','1f5e1f5e-0000-0000-0000-000000000001','1f5e1f5e-0000-0000-0000-00000000000c','Room A',10),
  ('1f5e1f5e-0000-0000-0000-00000000ee02','1f5e1f5e-0000-0000-0000-000000000001','1f5e1f5e-0000-0000-0000-00000000000c','Room B',10),
  ('1f5e1f5e-0000-0000-0000-00000000ee03','1f5e1f5e-0000-0000-0000-000000000002','1f5e1f5e-0000-0000-0000-00000000000d','Room M',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('1f5e1f5e-0000-0000-0000-00000000cc01','1f5e1f5e-0000-0000-0000-000000000001','Reformer',50,10),
  ('1f5e1f5e-0000-0000-0000-00000000cc02','1f5e1f5e-0000-0000-0000-000000000002','Mat',50,10);
-- staff_id is a studio_staff id, not an auth user id — instructor_user_id()
-- is the join, and the notification helpers take the auth id.
insert into instructors (id, studio_id, staff_id, display_name) values
  ('1f5e1f5e-0000-0000-0000-00000000d101','1f5e1f5e-0000-0000-0000-000000000001','1f5e1f5e-0000-0000-0000-00000000aa02','Ines'),
  ('1f5e1f5e-0000-0000-0000-00000000d102','1f5e1f5e-0000-0000-0000-000000000001','1f5e1f5e-0000-0000-0000-00000000aa03','Ivo'),
  -- No login: the ordinary case, and the one with no address anywhere.
  ('1f5e1f5e-0000-0000-0000-00000000d103','1f5e1f5e-0000-0000-0000-000000000001',null,'Iris Nologin'),
  ('1f5e1f5e-0000-0000-0000-00000000d201','1f5e1f5e-0000-0000-0000-000000000002','1f5e1f5e-0000-0000-0000-00000000bb01','Bea');

-- =============================================================================
-- 1. A STAFF-ENTERED PATTERN IS ALREADY APPROVED, and still feeds the engine
-- =============================================================================
-- The requirement that decides whether this migration was safe to ship: every
-- instructor_availability row that existed before 066 was entered by staff, and
-- staff entry IS the approval.
set role authenticated;
select set_config('request.jwt.claim.sub','1f5e1f5e-0000-0000-0000-0000000000a1',false);

select set_instructor_class_types('1f5e1f5e-0000-0000-0000-00000000d101',
  array['1f5e1f5e-0000-0000-0000-00000000cc01']::uuid[]);
select set_instructor_class_types('1f5e1f5e-0000-0000-0000-00000000d102',
  array['1f5e1f5e-0000-0000-0000-00000000cc01']::uuid[]);

select set_instructor_availability('1f5e1f5e-0000-0000-0000-00000000d101',
  $j$[{"day":0,"ranges":[{"from":"06:00","to":"22:00"}]},
      {"day":1,"ranges":[{"from":"06:00","to":"22:00"}]},
      {"day":2,"ranges":[{"from":"06:00","to":"22:00"}]},
      {"day":3,"ranges":[{"from":"06:00","to":"22:00"}]},
      {"day":4,"ranges":[{"from":"06:00","to":"22:00"}]},
      {"day":5,"ranges":[{"from":"06:00","to":"22:00"}]},
      {"day":6,"ranges":[{"from":"06:00","to":"22:00"}]}]$j$::jsonb);

reset role;
select expect_num('a staff-entered pattern is stored as approved, with no review step',
  (select count(*) from instructor_availability
    where instructor_id = '1f5e1f5e-0000-0000-0000-00000000d101'
      and approval_status <> 'approved')::bigint, 0);
select expect_num('...and it belongs to no submission',
  (select count(*) from instructor_availability
    where instructor_id = '1f5e1f5e-0000-0000-0000-00000000d101'
      and submission_id is not null)::bigint, 0);

set role authenticated;
select set_config('request.jwt.claim.sub','1f5e1f5e-0000-0000-0000-0000000000a1',false);
select expect_true('...and the engine still reads it',
  instructor_available_at('1f5e1f5e-0000-0000-0000-00000000d101',
    (current_date + 8 + time '09:00') at time zone 'Europe/Prague',
    (current_date + 8 + time '09:50') at time zone 'Europe/Prague'));

-- Six classes next week, so there is something to assign and later to confirm.
reset role;
insert into class_occurrences
  (studio_id, location_id, class_type_id, room_id, name, capacity,
   starts_at, ends_at, status, staffing)
select '1f5e1f5e-0000-0000-0000-000000000001','1f5e1f5e-0000-0000-0000-00000000000c',
       '1f5e1f5e-0000-0000-0000-00000000cc01',
       (case when i % 2 = 0 then '1f5e1f5e-0000-0000-0000-00000000ee01'
                            else '1f5e1f5e-0000-0000-0000-00000000ee02' end)::uuid,
       'Reformer', 10,
       ((current_date + 8) + time '09:00' + make_interval(hours => i)) at time zone 'Europe/Prague',
       ((current_date + 8) + time '09:50' + make_interval(hours => i)) at time zone 'Europe/Prague',
       'scheduled', 'open'
  from generate_series(0,5) i;

set role authenticated;
select set_config('request.jwt.claim.sub','1f5e1f5e-0000-0000-0000-0000000000a1',false);
select set_config('t.fill', (select assign_instructors('1f5e1f5e-0000-0000-0000-000000000001')::text), false);
select expect_num('all six go to the one instructor with an approved pattern',
  (current_setting('t.fill')::jsonb ->> 'assigned')::bigint, 6);
reset role;
select expect_num('...and Ivo, who has stated nothing, is a candidate too',
  (select count(*) from class_occurrences
    where instructor_id = '1f5e1f5e-0000-0000-0000-00000000d102')::bigint, 3);

-- =============================================================================
-- 2. A SUBMITTED PATTERN DOES NOT REACH THE ENGINE UNTIL SOMEBODY APPROVES IT
-- =============================================================================
-- Ivo submits next month, saying he can only teach mornings. Until it is
-- approved the engine must behave exactly as it did before he pressed submit.
set role authenticated;
select set_config('request.jwt.claim.sub','1f5e1f5e-0000-0000-0000-0000000000a3',false);
select set_config('t.period', (date_trunc('month', current_date) + interval '1 month')::date::text, false);

select set_config('t.sub', (select submit_availability('1f5e1f5e-0000-0000-0000-00000000d102',
  current_setting('t.period')::date,
  $j$[{"day":1,"ranges":[{"from":"06:00","to":"10:00"}]},
      {"day":3,"ranges":[{"from":"06:00","to":"10:00"}]}]$j$::jsonb)::text), false);

select expect_text('an instructor submitting lands as submitted, not approved',
  current_setting('t.sub')::jsonb ->> 'status', 'submitted');
select expect_true('...and is not auto-approved',
  not (current_setting('t.sub')::jsonb ->> 'auto_approved')::boolean);
select expect_num('...writing a row per range',
  (current_setting('t.sub')::jsonb ->> 'ranges')::bigint, 2);

reset role;
select expect_num('the rows are stored unapproved',
  (select count(*) from instructor_availability
    where submission_id = (current_setting('t.sub')::jsonb ->> 'submission_id')::uuid
      and approval_status = 'submitted')::bigint, 2);

set role authenticated;
select set_config('request.jwt.claim.sub','1f5e1f5e-0000-0000-0000-0000000000a1',false);
-- 15:00 on a Tuesday inside the submitted month: outside what Ivo offered, and
-- he has no standing pattern at all. Unapproved, he is still "stated nothing",
-- which means available — the pre-submission answer, unchanged.
select set_config('t.tue', (select d::text from generate_series(
    current_setting('t.period')::date, current_setting('t.period')::date + 27, interval '1 day') d
  where extract(dow from d) = 2 limit 1), false);
select expect_true('a pattern waiting for approval narrows nothing',
  instructor_available_at('1f5e1f5e-0000-0000-0000-00000000d102',
    (current_setting('t.tue')::date + time '15:00') at time zone 'Europe/Prague',
    (current_setting('t.tue')::date + time '15:50') at time zone 'Europe/Prague'));

-- Approval is manager-up. The instructor cannot approve their own.
select set_config('request.jwt.claim.sub','1f5e1f5e-0000-0000-0000-0000000000a3',false);
select expect_raises('an instructor cannot approve their own availability',
  format($$select approve_availability_submission(%L)$$,
         current_setting('t.sub')::jsonb ->> 'submission_id'), 'PT403');

-- And a manager approves it.
select set_config('request.jwt.claim.sub','1f5e1f5e-0000-0000-0000-0000000000a1',false);
select set_config('t.appr', (select approve_availability_submission(
  (current_setting('t.sub')::jsonb ->> 'submission_id')::uuid)::text), false);
select expect_true('a manager approves it', (current_setting('t.appr')::jsonb ->> 'ok')::boolean);
select expect_true('...and the instructor is told, because this one has a login',
  (current_setting('t.appr')::jsonb ->> 'notified')::boolean);

select expect_true('NOW the pattern narrows: 15:00 is outside what he offered',
  not instructor_available_at('1f5e1f5e-0000-0000-0000-00000000d102',
    (current_setting('t.tue')::date + time '15:00') at time zone 'Europe/Prague',
    (current_setting('t.tue')::date + time '15:50') at time zone 'Europe/Prague'));
select set_config('t.mon', (select d::text from generate_series(
    current_setting('t.period')::date, current_setting('t.period')::date + 27, interval '1 day') d
  where extract(dow from d) = 1 limit 1), false);
select expect_true('...and 07:00 on a Monday, which he did offer, is fine',
  instructor_available_at('1f5e1f5e-0000-0000-0000-00000000d102',
    (current_setting('t.mon')::date + time '07:00') at time zone 'Europe/Prague',
    (current_setting('t.mon')::date + time '07:50') at time zone 'Europe/Prague'));

-- The month is a complete statement about that month, so it answers instead of
-- the standing pattern rather than alongside it. Ines has a 7-day 06:00-22:00
-- standing pattern; her submitted month says Mondays only.
select set_config('request.jwt.claim.sub','1f5e1f5e-0000-0000-0000-0000000000a2',false);
select set_config('t.sub2', (select submit_availability('1f5e1f5e-0000-0000-0000-00000000d101',
  current_setting('t.period')::date,
  $j$[{"day":1,"ranges":[{"from":"06:00","to":"22:00"}]}]$j$::jsonb)::text), false);
select set_config('request.jwt.claim.sub','1f5e1f5e-0000-0000-0000-0000000000a1',false);
select approve_availability_submission((current_setting('t.sub2')::jsonb ->> 'submission_id')::uuid);
select expect_true('an approved month REPLACES the standing pattern for its days',
  not instructor_available_at('1f5e1f5e-0000-0000-0000-00000000d101',
    (current_setting('t.tue')::date + time '09:00') at time zone 'Europe/Prague',
    (current_setting('t.tue')::date + time '09:50') at time zone 'Europe/Prague'));
select expect_true('...and the standing pattern is untouched outside that month',
  instructor_available_at('1f5e1f5e-0000-0000-0000-00000000d101',
    (current_date + 8 + time '09:00') at time zone 'Europe/Prague',
    (current_date + 8 + time '09:50') at time zone 'Europe/Prague'));
reset role;
select expect_num('...and nothing was deleted to achieve it',
  (select count(*) from instructor_availability
    where instructor_id = '1f5e1f5e-0000-0000-0000-00000000d101'
      and submission_id is null)::bigint, 7);

-- =============================================================================
-- 3. Changes requested, and a resubmission
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','1f5e1f5e-0000-0000-0000-0000000000a1',false);
select expect_raises('a review with no reason is refused',
  format($$select request_availability_changes(%L, '  ')$$,
         current_setting('t.sub')::jsonb ->> 'submission_id'), 'PT422');
select set_config('t.chg', (select request_availability_changes(
  (current_setting('t.sub')::jsonb ->> 'submission_id')::uuid,
  'We need you on Wednesday evenings too.')::text), false);
select expect_true('changes can be requested, with a note', (current_setting('t.chg')::jsonb ->> 'ok')::boolean);
select expect_true('...and asking for changes stops the pattern counting again',
  instructor_available_at('1f5e1f5e-0000-0000-0000-00000000d102',
    (current_setting('t.tue')::date + time '15:00') at time zone 'Europe/Prague',
    (current_setting('t.tue')::date + time '15:50') at time zone 'Europe/Prague'));

select set_config('request.jwt.claim.sub','1f5e1f5e-0000-0000-0000-0000000000a3',false);
select submit_availability('1f5e1f5e-0000-0000-0000-00000000d102',
  current_setting('t.period')::date,
  $j$[{"day":1,"ranges":[{"from":"06:00","to":"10:00"}]},
      {"day":3,"ranges":[{"from":"06:00","to":"22:00"}]}]$j$::jsonb);
reset role;
select expect_num('resubmitting edits the same month rather than making a second claim on it',
  (select count(*) from availability_submissions
    where instructor_id = '1f5e1f5e-0000-0000-0000-00000000d102'
      and period_start = current_setting('t.period')::date)::bigint, 1);
select expect_text('...and it answers the note rather than leaving it standing',
  (select note from availability_submissions
    where instructor_id = '1f5e1f5e-0000-0000-0000-00000000d102'
      and period_start = current_setting('t.period')::date), null);
select expect_text('...back to submitted',
  (select status from availability_submissions
    where instructor_id = '1f5e1f5e-0000-0000-0000-00000000d102'
      and period_start = current_setting('t.period')::date), 'submitted');

-- =============================================================================
-- 4. A manager entering it for somebody is entering it approved
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','1f5e1f5e-0000-0000-0000-0000000000a1',false);
select set_config('t.sub3', (select submit_availability('1f5e1f5e-0000-0000-0000-00000000d103',
  current_setting('t.period')::date,
  $j$[{"day":2,"ranges":[{"from":"08:00","to":"12:00"}]}]$j$::jsonb)::text), false);
select expect_text('a manager submitting on somebody''s behalf lands approved',
  current_setting('t.sub3')::jsonb ->> 'status', 'approved');
select expect_true('...and says so, rather than leaving a manager waiting to review their own typing',
  (current_setting('t.sub3')::jsonb ->> 'auto_approved')::boolean);

-- =============================================================================
-- 5. COMMITMENTS GATE NOTHING
-- =============================================================================
-- Migration 065: a hiring expectation and a performance measure, never a
-- scheduling input. Somebody offering four hours against an agreed nine a week
-- is still approved if staff approve it.
reset role;
insert into instructor_commitments
  (studio_id, instructor_id, starts_on, min_per_week, target_per_week)
values ('1f5e1f5e-0000-0000-0000-000000000001','1f5e1f5e-0000-0000-0000-00000000d101',
        current_date - 30, 9, 12);
set role authenticated;
select set_config('request.jwt.claim.sub','1f5e1f5e-0000-0000-0000-0000000000a2',false);
select set_config('t.thin', (select submit_availability('1f5e1f5e-0000-0000-0000-00000000d101',
  (current_setting('t.period')::date + interval '1 month')::date,
  $j$[{"day":1,"ranges":[{"from":"09:00","to":"10:00"}]}]$j$::jsonb)::text), false);
select set_config('request.jwt.claim.sub','1f5e1f5e-0000-0000-0000-0000000000a1',false);
select expect_true('a pattern far under the agreed minimum is still approvable',
  (approve_availability_submission(
    (current_setting('t.thin')::jsonb ->> 'submission_id')::uuid) ->> 'ok')::boolean);

-- =============================================================================
-- 6. THE MONTHLY CYCLE IS THE SETTING, per studio
-- =============================================================================
-- Pure arithmetic on an explicit period, so this says the same thing whatever
-- day the suite is run on. Studio A collects by the 20th, studio B by the 5th.
reset role;
update studio_settings set availability_due_day = 20 where studio_id = '1f5e1f5e-0000-0000-0000-000000000001';
update studio_settings set availability_due_day = 5  where studio_id = '1f5e1f5e-0000-0000-0000-000000000002';
set role authenticated;
select set_config('request.jwt.claim.sub','1f5e1f5e-0000-0000-0000-0000000000a1',false);
select expect_text('studio A''s December pattern is due on 20 November',
  availability_cycle('1f5e1f5e-0000-0000-0000-000000000001', date '2026-12-01') ->> 'due_on',
  '2026-11-20');
select set_config('request.jwt.claim.sub','1f5e1f5e-0000-0000-0000-0000000000b1',false);
select expect_text('...and studio B''s on 5 November, from the same code',
  availability_cycle('1f5e1f5e-0000-0000-0000-000000000002', date '2026-12-01') ->> 'due_on',
  '2026-11-05');
select expect_text('...and February works, because the day is capped at 28',
  availability_cycle('1f5e1f5e-0000-0000-0000-000000000002', date '2027-03-01') ->> 'due_on',
  '2027-02-05');

-- Who has not answered, which is the list that replaces chasing six people.
select set_config('request.jwt.claim.sub','1f5e1f5e-0000-0000-0000-0000000000a1',false);
select set_config('t.cyc', (select availability_cycle('1f5e1f5e-0000-0000-0000-000000000001',
  current_setting('t.period')::date)::text), false);
select expect_num('the cycle lists every active instructor',
  jsonb_array_length(current_setting('t.cyc')::jsonb -> 'instructors')::bigint, 3);
select expect_num('...and counts who has still not submitted',
  (current_setting('t.cyc')::jsonb ->> 'not_submitted')::bigint, 0);
select expect_num('...and how many are waiting on the studio',
  (current_setting('t.cyc')::jsonb ->> 'awaiting_review')::bigint, 1);
select expect_true('...naming the one with no login, who cannot be emailed',
  (select bool_or((x ->> 'has_login')::boolean = false)
     from jsonb_array_elements(current_setting('t.cyc')::jsonb -> 'instructors') x));

-- The reminder agrees with the published due date. Both branches assert: this
-- is the invariant that matters — the nudge, the list and the date all read one
-- column — and it holds on any day the suite is run.
reset role;
update studio_settings set availability_due_day = 1 where studio_id = '1f5e1f5e-0000-0000-0000-000000000002';
select set_config('t.overdue_b',
  (select (availability_cycle('1f5e1f5e-0000-0000-0000-000000000002') ->> 'overdue')), false);
select set_config('t.q_b', (select queue_availability_reminders('1f5e1f5e-0000-0000-0000-000000000002')::text), false);
select expect_true(
  case when current_setting('t.overdue_b')::boolean
       then 'past the due day, the instructor who has not submitted is reminded'
       else 'before the due day, nobody is reminded early' end,
  case when current_setting('t.overdue_b')::boolean
       then current_setting('t.q_b')::int > 0
       else current_setting('t.q_b')::int = 0 end);

-- Studio A's instructors have all submitted or been entered, so nobody is
-- chased whatever the date says.
update studio_settings set availability_due_day = 1 where studio_id = '1f5e1f5e-0000-0000-0000-000000000001';
select expect_num('somebody who has already submitted is never chased',
  queue_availability_reminders('1f5e1f5e-0000-0000-0000-000000000001')::bigint, 0);

-- =============================================================================
-- 7. THE WEEK IS ASKED ABOUT ON THE STUDIO'S OWN DAY
-- =============================================================================
-- Studio A: today IS its ask day. Studio B: tomorrow is. One sweep, two
-- answers — which is the whole reason these are columns and not constants.
reset role;
select set_config('request.jwt.claims', null, false);
select set_config('request.jwt.claim.sub', null, false);
select set_config('t.sweep', (select sweep_week_confirmations()::text), false);
-- The suites share one db reset, so a bare count here would be a count of
-- whatever ran first. Compared against every active studio instead: the thing
-- worth asserting is that the sweep skips none of them.
select expect_num('the sweep covers every active studio, not just the first',
  (current_setting('t.sweep')::jsonb ->> 'studios')::bigint,
  (select count(*) from studios where status = 'active'));
select expect_num('studio A is asked, because today is its ask day',
  (select count(*) from notifications
    where studio_id = '1f5e1f5e-0000-0000-0000-000000000001'
      and template_key = 'week_confirm_ask')::bigint, 2);
select expect_num('studio B is not, because its ask day is tomorrow',
  (select count(*) from notifications
    where studio_id = '1f5e1f5e-0000-0000-0000-000000000002'
      and template_key = 'week_confirm_ask')::bigint, 0);
select expect_num('the instructor with no login is not asked, having no address',
  (select count(*) from notifications n
    where n.studio_id = '1f5e1f5e-0000-0000-0000-000000000001'
      and n.template_key = 'week_confirm_ask'
      and n.user_id is null)::bigint, 0);
select set_config('t.sweep2', (select sweep_week_confirmations()::text), false);
select expect_num('running it twice on the same day asks nobody again',
  (select count(*) from notifications
    where studio_id = '1f5e1f5e-0000-0000-0000-000000000001'
      and template_key = 'week_confirm_ask')::bigint, 2);

-- =============================================================================
-- 8. ONE ACTION FOR THE WHOLE WEEK
-- =============================================================================
select set_config('t.week', (select (studio_week_start('1f5e1f5e-0000-0000-0000-000000000001',
  current_setting('t.today')::date) + 7)::text), false);
set role authenticated;
select set_config('request.jwt.claim.sub','1f5e1f5e-0000-0000-0000-0000000000a2',false);
select set_config('t.iw', (select instructor_week('1f5e1f5e-0000-0000-0000-00000000d101',
  current_setting('t.week')::date)::text), false);
select expect_num('Ines has three classes next week',
  jsonb_array_length(current_setting('t.iw')::jsonb -> 'classes')::bigint, 3);
select expect_num('...all of them unanswered',
  (current_setting('t.iw')::jsonb ->> 'unanswered')::bigint, 3);

select set_config('t.cw', (select confirm_week('1f5e1f5e-0000-0000-0000-00000000d101',
  current_setting('t.week')::date)::text), false);
select expect_num('confirming the week confirms every class in it',
  (current_setting('t.cw')::jsonb ->> 'confirmed')::bigint, 3);
select expect_num('...leaving nothing unanswered',
  (instructor_week('1f5e1f5e-0000-0000-0000-00000000d101',
    current_setting('t.week')::date) ->> 'unanswered')::bigint, 0);
reset role;
select expect_num('...and not one of them became an open shift',
  (select count(*) from class_occurrences
    where instructor_id = '1f5e1f5e-0000-0000-0000-00000000d101'
      and staffing <> 'assigned')::bigint, 0);

-- Asking for cover on ONE class leaves the rest confirmed.
set role authenticated;
select set_config('request.jwt.claim.sub','1f5e1f5e-0000-0000-0000-0000000000a3',false);
select set_config('t.one', (select id::text from class_occurrences
  where instructor_id = '1f5e1f5e-0000-0000-0000-00000000d102'
  order by starts_at limit 1), false);
select request_cover(current_setting('t.one')::uuid, 'Dentist');
select set_config('t.cw2', (select confirm_week('1f5e1f5e-0000-0000-0000-00000000d102',
  current_setting('t.week')::date)::text), false);
select expect_num('asking for cover on one class leaves the other two to confirm',
  (current_setting('t.cw2')::jsonb ->> 'confirmed')::bigint, 2);
select expect_num('...and the covered one is reported, not silently skipped',
  (current_setting('t.cw2')::jsonb ->> 'cover_requested')::bigint, 1);
reset role;
select expect_true('...the covered class is NOT confirmed',
  (select instructor_confirmed_at is null from class_occurrences
    where id = current_setting('t.one')::uuid));
select expect_true('...and it still has its instructor: a cover request is not a release',
  (select instructor_id = '1f5e1f5e-0000-0000-0000-00000000d102' from class_occurrences
    where id = current_setting('t.one')::uuid));
set role authenticated;
select set_config('request.jwt.claim.sub','1f5e1f5e-0000-0000-0000-0000000000a1',false);
select expect_num('...and it counts as answered, so nobody is chased about it',
  (instructor_week('1f5e1f5e-0000-0000-0000-00000000d102',
    current_setting('t.week')::date) ->> 'unanswered')::bigint, 0);

-- =============================================================================
-- 9. ESCALATION IS ABOUT THE NEXT FEW DAYS, NOT THE WHOLE WEEK
-- =============================================================================
-- A Friday class unconfirmed on Sunday is not yet a problem. Two classes for
-- Iris, one the day after tomorrow and one in six days, both unconfirmed.
--
-- Studio A's week is moved to start TODAY first, so both classes sit inside one
-- week whatever day the suite is run on — and so studio_week_start() is asked
-- to honour `week_starts_on`, which has been a setting since migration 001 and
-- which date_trunc('week') would silently ignore.
reset role;
update studio_settings set week_starts_on = extract(dow from current_setting('t.today')::date)::int
 where studio_id = '1f5e1f5e-0000-0000-0000-000000000001';
select expect_text('the studio''s week starts on the day it says it does',
  studio_week_start('1f5e1f5e-0000-0000-0000-000000000001', current_setting('t.today')::date)::text,
  current_setting('t.today'));
insert into class_occurrences
  (studio_id, location_id, class_type_id, room_id, name, capacity, instructor_id,
   starts_at, ends_at, status, staffing)
values
  ('1f5e1f5e-0000-0000-0000-000000000001','1f5e1f5e-0000-0000-0000-00000000000c',
   '1f5e1f5e-0000-0000-0000-00000000cc01','1f5e1f5e-0000-0000-0000-00000000ee01',
   'Soon', 10, '1f5e1f5e-0000-0000-0000-00000000d103',
   ((current_setting('t.today')::date + 2) + time '07:00') at time zone 'Europe/Prague',
   ((current_setting('t.today')::date + 2) + time '07:50') at time zone 'Europe/Prague', 'scheduled', 'assigned'),
  ('1f5e1f5e-0000-0000-0000-000000000001','1f5e1f5e-0000-0000-0000-00000000000c',
   '1f5e1f5e-0000-0000-0000-00000000cc01','1f5e1f5e-0000-0000-0000-00000000ee01',
   'Later', 10, '1f5e1f5e-0000-0000-0000-00000000d103',
   ((current_setting('t.today')::date + 6) + time '07:00') at time zone 'Europe/Prague',
   ((current_setting('t.today')::date + 6) + time '07:50') at time zone 'Europe/Prague', 'scheduled', 'assigned');

set role authenticated;
select set_config('request.jwt.claim.sub','1f5e1f5e-0000-0000-0000-0000000000a1',false);
select set_config('t.esc', (select unconfirmed_summary('1f5e1f5e-0000-0000-0000-000000000001',
  studio_week_start('1f5e1f5e-0000-0000-0000-000000000001', current_setting('t.today')::date), 3)::text), false);
select expect_num('inside a three-day window only the near class is escalated',
  (current_setting('t.esc')::jsonb ->> 'classes')::bigint, 1);
select expect_text('...and the line names people, not classes one by one',
  current_setting('t.esc')::jsonb ->> 'line',
  '1 instructor has not confirmed 1 class this week');
select expect_num('...one instructor, once',
  (current_setting('t.esc')::jsonb ->> 'instructors')::bigint, 1);
select expect_true('...with which classes, so staff can act without hunting',
  jsonb_array_length(current_setting('t.esc')::jsonb -> 'detail' -> 0 -> 'list') = 1);

-- Widen the window and the far class appears. Same function, same data: the
-- window is doing the work, not a filter somewhere else.
select set_config('t.esc7', (select unconfirmed_summary('1f5e1f5e-0000-0000-0000-000000000001',
  studio_week_start('1f5e1f5e-0000-0000-0000-000000000001', current_setting('t.today')::date), 7)::text), false);
select expect_num('a seven-day window sees both',
  (current_setting('t.esc7')::jsonb ->> 'classes')::bigint, 2);

-- A class that has already run is nobody's alarm.
reset role;
insert into class_occurrences
  (studio_id, location_id, class_type_id, room_id, name, capacity, instructor_id,
   starts_at, ends_at, status, staffing)
values
  ('1f5e1f5e-0000-0000-0000-000000000001','1f5e1f5e-0000-0000-0000-00000000000c',
   '1f5e1f5e-0000-0000-0000-00000000cc01','1f5e1f5e-0000-0000-0000-00000000ee02',
   'Gone', 10, '1f5e1f5e-0000-0000-0000-00000000d103',
   ((current_setting('t.today')::date - 1) + time '07:00') at time zone 'Europe/Prague',
   ((current_setting('t.today')::date - 1) + time '07:50') at time zone 'Europe/Prague', 'scheduled', 'assigned');
set role authenticated;
select set_config('request.jwt.claim.sub','1f5e1f5e-0000-0000-0000-0000000000a1',false);
select expect_num('a class that already happened is not escalated',
  (unconfirmed_summary('1f5e1f5e-0000-0000-0000-000000000001',
    studio_week_start('1f5e1f5e-0000-0000-0000-000000000001', current_setting('t.today')::date), 7) ->> 'classes')::bigint, 2);

-- =============================================================================
-- 10. CONFIRMING LATE CLEARS IT, SILENTLY
-- =============================================================================
-- Two, not three: yesterday's class is outside this week, and confirming a
-- week does not reach back into one that has gone.
select expect_num('the studio can confirm on somebody''s behalf',
  (confirm_week('1f5e1f5e-0000-0000-0000-00000000d103',
    studio_week_start('1f5e1f5e-0000-0000-0000-000000000001', current_setting('t.today')::date)) ->> 'confirmed')::bigint, 2);
select expect_true('...and the alarm is simply gone',
  (unconfirmed_summary('1f5e1f5e-0000-0000-0000-000000000001',
    studio_week_start('1f5e1f5e-0000-0000-0000-000000000001', current_setting('t.today')::date), 7) ->> 'line') is null);
reset role;
select expect_num('...with nothing recorded about having been late',
  (select count(*) from notifications
    where studio_id = '1f5e1f5e-0000-0000-0000-000000000001'
      and template_key = 'week_unconfirmed')::bigint, 0);

-- =============================================================================
-- 11. The escalation email is one email, and only on the studio's own day
-- =============================================================================
reset role;
-- Put a near class back into the unconfirmed state.
update class_occurrences set instructor_confirmed_at = null
 where studio_id = '1f5e1f5e-0000-0000-0000-000000000001' and name in ('Soon','Later');
select set_config('request.jwt.claims', null, false);
select set_config('request.jwt.claim.sub', null, false);
select sweep_week_confirmations();
select expect_num('the studio gets ONE line, not one alarm per class',
  (select count(*) from notifications
    where studio_id = '1f5e1f5e-0000-0000-0000-000000000001'
      and template_key = 'week_unconfirmed')::bigint, 1);
select expect_num('...and studio B, whose escalate day is tomorrow, gets none',
  (select count(*) from notifications
    where studio_id = '1f5e1f5e-0000-0000-0000-000000000002'
      and template_key = 'week_unconfirmed')::bigint, 0);
select expect_true('...and the line says who, in words',
  (select payload ->> 'line' like '%not confirmed%' from notifications
    where studio_id = '1f5e1f5e-0000-0000-0000-000000000001'
      and template_key = 'week_unconfirmed' limit 1));
select sweep_week_confirmations();
select expect_num('...and the same day cannot send it twice',
  (select count(*) from notifications
    where studio_id = '1f5e1f5e-0000-0000-0000-000000000001'
      and template_key = 'week_unconfirmed')::bigint, 1);

-- The whole point of the restraint: nothing was released.
select expect_num('an unconfirmed class is still assigned, not an open shift',
  (select count(*) from class_occurrences
    where studio_id = '1f5e1f5e-0000-0000-0000-000000000001'
      and name in ('Soon','Later') and staffing = 'assigned')::bigint, 2);

reset role;
select set_config('request.jwt.claim.sub', null, false);
select 'instructor self-service suite finished' as done;
