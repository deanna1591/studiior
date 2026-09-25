-- =============================================================================
-- Decision 39 — instructor class reminders. The Sunday "your week" digest and
-- the evening-before "tomorrow" reminder.
-- UUID space: 9e39
--
-- The sweep's threshold is a fixed studio-local clock (Sunday >=18:00 weekly,
-- >=19:00 evening-before), which cannot be hit deterministically from the wall
-- clock — so sweep_instructor_class_reminders(p_now) is called at chosen instants.
-- The dow/hour gate runs exactly as it does against now().
-- =============================================================================
\set SR '''9e399e39-0000-0000-0000-000000000001'''
\set SO '''9e399e39-0000-0000-0000-000000000002'''
\set SP '''9e399e39-0000-0000-0000-000000000003'''

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want::text,'null'), coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if coalesce(actual,false) then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_raises(label text, sql text, code text)
returns void language plpgsql as $$
begin
  execute sql;
  raise exception 'FAIL  %  expected % , nothing raised', label, code;
exception when others then
  if sqlstate = code then raise notice 'PASS  %  (got %)', label, code;
  else raise exception 'FAIL  %  expected %, got % (%)', label, code, sqlstate, sqlerrm; end if;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('9e399e39-0000-0000-0000-0000000a0001'),   -- RA login (SR)
  ('9e399e39-0000-0000-0000-0000000a0002'),   -- OA login (SO)
  ('9e399e39-0000-0000-0000-0000000a0003');   -- PA login (SP)
insert into profiles (id, email) values
  ('9e399e39-0000-0000-0000-0000000a0001','9e39-ra@example.com'),
  ('9e399e39-0000-0000-0000-0000000a0002','9e39-oa@example.com'),
  ('9e399e39-0000-0000-0000-0000000a0003','9e39-pa@example.com');

-- SR: reminders ON, publication OFF (every month published). SO: reminders OFF.
-- SP: reminders ON, publication ON with NOTHING published (the unpublished case).
insert into studios (id, name, slug, timezone, currency, status) values
  ('9e399e39-0000-0000-0000-000000000001','Reminders On','rem-on','Europe/Prague','CZK','active'),
  ('9e399e39-0000-0000-0000-000000000002','Reminders Off','rem-off','Europe/Prague','CZK','active'),
  ('9e399e39-0000-0000-0000-000000000003','Reminders Unpub','rem-unpub','Europe/Prague','CZK','active');
insert into studio_settings (studio_id, instructor_class_reminders, publication_enabled) values
  ('9e399e39-0000-0000-0000-000000000001', true,  false),
  ('9e399e39-0000-0000-0000-000000000002', false, false),
  ('9e399e39-0000-0000-0000-000000000003', true,  true);
insert into locations (id, studio_id, name, is_primary) values
  ('9e399e39-0000-0000-0000-0000000100a1','9e399e39-0000-0000-0000-000000000001','Main',true),
  ('9e399e39-0000-0000-0000-0000000100a2','9e399e39-0000-0000-0000-000000000002','Main',true),
  ('9e399e39-0000-0000-0000-0000000100a3','9e399e39-0000-0000-0000-000000000003','Main',true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('9e399e39-0000-0000-0000-0000000ee0a1','9e399e39-0000-0000-0000-000000000001','9e399e39-0000-0000-0000-0000000100a1','Studio A',10),
  ('9e399e39-0000-0000-0000-0000000ee0a2','9e399e39-0000-0000-0000-000000000002','9e399e39-0000-0000-0000-0000000100a2','Studio A',10),
  ('9e399e39-0000-0000-0000-0000000ee0a3','9e399e39-0000-0000-0000-000000000003','9e399e39-0000-0000-0000-0000000100a3','Studio A',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('9e399e39-0000-0000-0000-0000000cc0a1','9e399e39-0000-0000-0000-000000000001','Reformer',50,10),
  ('9e399e39-0000-0000-0000-0000000cc0a2','9e399e39-0000-0000-0000-000000000002','Reformer',50,10),
  ('9e399e39-0000-0000-0000-0000000cc0a3','9e399e39-0000-0000-0000-000000000003','Reformer',50,10);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('9e399e39-0000-0000-0000-0000005a0001','9e399e39-0000-0000-0000-000000000001','9e399e39-0000-0000-0000-0000000a0001','9e39-ra@example.com','instructor'),
  ('9e399e39-0000-0000-0000-0000005a0002','9e399e39-0000-0000-0000-000000000002','9e399e39-0000-0000-0000-0000000a0002','9e39-oa@example.com','instructor'),
  ('9e399e39-0000-0000-0000-0000005a0003','9e399e39-0000-0000-0000-000000000003','9e399e39-0000-0000-0000-0000000a0003','9e39-pa@example.com','instructor');
-- RA: login (SR). RN: NO login (SR). OA: login (SO). PA: login (SP).
insert into instructors (id, studio_id, display_name, staff_id) values
  ('9e399e39-0000-0000-0000-0000000d0001','9e399e39-0000-0000-0000-000000000001','Rae Ann','9e399e39-0000-0000-0000-0000005a0001'),
  ('9e399e39-0000-0000-0000-0000000d00c0','9e399e39-0000-0000-0000-000000000001','Nol Login', null),
  ('9e399e39-0000-0000-0000-0000000d0002','9e399e39-0000-0000-0000-000000000002','Ola Off','9e399e39-0000-0000-0000-0000005a0002'),
  ('9e399e39-0000-0000-0000-0000000d0003','9e399e39-0000-0000-0000-000000000003','Pat Unpub','9e399e39-0000-0000-0000-0000005a0003');

-- The Sunday of THIS week (date_trunc('week') is Monday, +6 = Sunday), so the
-- "week ahead" window (Mon..Sun) is next week whatever day the suite runs on.
select set_config('t.sun', (date_trunc('week', current_date)::date + 6)::text, false);

-- SR classes. Monday and Thursday of next week are inside the weekly window;
-- the Thursday one is also "tomorrow" for the evening run. The +22 class is
-- outside the week entirely, so the weekly digest must not list it.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id,
   name, starts_at, ends_at, capacity, booked_count, status) values
  ('9e399e39-0000-0000-0000-00000000c001','9e399e39-0000-0000-0000-000000000001','9e399e39-0000-0000-0000-0000000100a1',
   '9e399e39-0000-0000-0000-0000000cc0a1','9e399e39-0000-0000-0000-0000000ee0a1','9e399e39-0000-0000-0000-0000000d0001',
   'Week Mon', (current_setting('t.sun')::date + 1 + time '07:00') at time zone 'Europe/Prague',
   (current_setting('t.sun')::date + 1 + time '07:50') at time zone 'Europe/Prague', 10, 3, 'scheduled'),
  ('9e399e39-0000-0000-0000-00000000c002','9e399e39-0000-0000-0000-000000000001','9e399e39-0000-0000-0000-0000000100a1',
   '9e399e39-0000-0000-0000-0000000cc0a1','9e399e39-0000-0000-0000-0000000ee0a1','9e399e39-0000-0000-0000-0000000d0001',
   'Eve Thu', (current_setting('t.sun')::date + 4 + time '07:00') at time zone 'Europe/Prague',
   (current_setting('t.sun')::date + 4 + time '07:50') at time zone 'Europe/Prague', 10, 5, 'scheduled'),
  ('9e399e39-0000-0000-0000-00000000c0af','9e399e39-0000-0000-0000-000000000001','9e399e39-0000-0000-0000-0000000100a1',
   '9e399e39-0000-0000-0000-0000000cc0a1','9e399e39-0000-0000-0000-0000000ee0a1','9e399e39-0000-0000-0000-0000000d0001',
   'Far Class', (current_setting('t.sun')::date + 22 + time '07:00') at time zone 'Europe/Prague',
   (current_setting('t.sun')::date + 22 + time '07:50') at time zone 'Europe/Prague', 10, 1, 'scheduled'),
  -- RN (no login) has a class in the same window — must be excluded everywhere.
  ('9e399e39-0000-0000-0000-00000000c0c0','9e399e39-0000-0000-0000-000000000001','9e399e39-0000-0000-0000-0000000100a1',
   '9e399e39-0000-0000-0000-0000000cc0a1','9e399e39-0000-0000-0000-0000000ee0a1','9e399e39-0000-0000-0000-0000000d00c0',
   'NoLogin Mon', (current_setting('t.sun')::date + 1 + time '08:00') at time zone 'Europe/Prague',
   (current_setting('t.sun')::date + 1 + time '08:50') at time zone 'Europe/Prague', 10, 2, 'scheduled'),
  -- OA on the OFF studio.
  ('9e399e39-0000-0000-0000-00000000c0a2','9e399e39-0000-0000-0000-000000000002','9e399e39-0000-0000-0000-0000000100a2',
   '9e399e39-0000-0000-0000-0000000cc0a2','9e399e39-0000-0000-0000-0000000ee0a2','9e399e39-0000-0000-0000-0000000d0002',
   'Off Mon', (current_setting('t.sun')::date + 1 + time '07:00') at time zone 'Europe/Prague',
   (current_setting('t.sun')::date + 1 + time '07:50') at time zone 'Europe/Prague', 10, 4, 'scheduled'),
  -- PA on the publication-ON studio with NOTHING published → unpublished month.
  ('9e399e39-0000-0000-0000-00000000c0a3','9e399e39-0000-0000-0000-000000000003','9e399e39-0000-0000-0000-0000000100a3',
   '9e399e39-0000-0000-0000-0000000cc0a3','9e399e39-0000-0000-0000-0000000ee0a3','9e399e39-0000-0000-0000-0000000d0003',
   'Unpub Mon', (current_setting('t.sun')::date + 1 + time '09:00') at time zone 'Europe/Prague',
   (current_setting('t.sun')::date + 1 + time '09:50') at time zone 'Europe/Prague', 10, 6, 'scheduled');

-- =============================================================================
-- 1. Reminders OFF: nothing at all before the sweep runs.
-- =============================================================================
select expect_num('no reminder notifications exist before the sweep',
  (select count(*) from notifications
     where template_key in ('instructor_week_ahead','instructor_tomorrow'))::bigint, 0);

-- =============================================================================
-- 2. WEEKLY digest — fire at the Sunday 18:30 studio-local threshold.
-- =============================================================================
select set_config('t.now_w', ((current_setting('t.sun')::date + time '18:30') at time zone 'Europe/Prague')::text, false);
select sweep_instructor_class_reminders(current_setting('t.now_w')::timestamptz);

select expect_num('exactly ONE weekly digest for the ON studio (RA only)',
  (select count(*) from notifications where studio_id = :SR
     and template_key = 'instructor_week_ahead')::bigint, 1);
select expect_true('...addressed to RA''s login',
  (select user_id = '9e399e39-0000-0000-0000-0000000a0001' from notifications
     where studio_id = :SR and template_key = 'instructor_week_ahead' limit 1));
select expect_true('...it lists exactly RA''s week: both in-window classes',
  (select payload ->> 'class_list' like '%Week Mon%' and payload ->> 'class_list' like '%Eve Thu%'
     from notifications where studio_id = :SR and template_key = 'instructor_week_ahead' limit 1));
select expect_true('...and NOT the class outside the week',
  (select payload ->> 'class_list' not like '%Far Class%'
     from notifications where studio_id = :SR and template_key = 'instructor_week_ahead' limit 1));
select expect_true('...and NOT the no-login instructor''s class',
  (select payload ->> 'class_list' not like '%NoLogin%'
     from notifications where studio_id = :SR and template_key = 'instructor_week_ahead' limit 1));
select expect_true('...each line carries the time / class / room / headcount-capacity',
  (select payload ->> 'class_list' like '%07:00 Week Mon · Studio A · 3/10%'
     from notifications where studio_id = :SR and template_key = 'instructor_week_ahead' limit 1));

-- No-login instructor gets nothing.
select expect_num('the no-login instructor is never sent a weekly digest',
  (select count(*) from notifications where template_key = 'instructor_week_ahead'
     and payload ->> 'class_list' like '%NoLogin%')::bigint, 0);
-- The OFF studio queues nothing though its instructor WOULD qualify.
select expect_num('the OFF studio queues no weekly digest',
  (select count(*) from notifications where studio_id = :SO
     and template_key = 'instructor_week_ahead')::bigint, 0);
-- The publication-ON studio with nothing published: the week is unpublished.
select expect_num('an unpublished month queues no weekly digest',
  (select count(*) from notifications where studio_id = :SP
     and template_key = 'instructor_week_ahead')::bigint, 0);

-- =============================================================================
-- 3. Second run the same day queues nothing (dedupe per instructor per Monday).
-- =============================================================================
select sweep_instructor_class_reminders(current_setting('t.now_w')::timestamptz);
select expect_num('a second weekly run the same day adds no digest',
  (select count(*) from notifications where studio_id = :SR
     and template_key = 'instructor_week_ahead')::bigint, 1);

-- =============================================================================
-- 4. EVENING-BEFORE — fire at 19:00 the day before RA's Thursday class
--    (Wednesday 19:00 → tomorrow is Thursday). It lists exactly tomorrow.
-- =============================================================================
select set_config('t.now_e', ((current_setting('t.sun')::date + 3 + time '19:00') at time zone 'Europe/Prague')::text, false);
select sweep_instructor_class_reminders(current_setting('t.now_e')::timestamptz);

select expect_num('exactly ONE evening-before reminder for RA',
  (select count(*) from notifications where studio_id = :SR
     and template_key = 'instructor_tomorrow')::bigint, 1);
select expect_true('...it lists exactly tomorrow''s class',
  (select payload ->> 'class_list' like '%Eve Thu%'
     from notifications where studio_id = :SR and template_key = 'instructor_tomorrow' limit 1));
select expect_true('...and NOT Monday''s class (not tomorrow)',
  (select payload ->> 'class_list' not like '%Week Mon%'
     from notifications where studio_id = :SR and template_key = 'instructor_tomorrow' limit 1));

-- =============================================================================
-- 5. Second evening run the same day queues nothing.
-- =============================================================================
select sweep_instructor_class_reminders(current_setting('t.now_e')::timestamptz);
select expect_num('a second evening run the same day adds no reminder',
  (select count(*) from notifications where studio_id = :SR
     and template_key = 'instructor_tomorrow')::bigint, 1);

-- =============================================================================
-- 6. Guard: the sweep is a background job. A signed-in user has no grant to it
--    at all (the grant is the boundary), so the attempt is 42501 — stronger than
--    the in-body is_service_context() PT403.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','9e399e39-0000-0000-0000-0000000a0001',false);
select expect_raises('a signed-in user cannot run the reminder sweep at all',
  'select sweep_instructor_class_reminders()', '42501');
reset role; select set_config('request.jwt.claim.sub', null, false);

select 'instructor_reminders suite finished' as done;
