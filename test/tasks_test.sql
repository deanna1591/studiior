-- =============================================================================
-- Decision 78c (Act) — migrations 20260832640000..690000
-- =============================================================================
-- UUID space a78c, checked free. Run after `supabase db reset`.
--
-- at_risk creates one task, a second sweep none, a check-in or recovery closes
-- it; drifting sends the soft email once per 30 days and raises a hidden FYI
-- task; tasks off writes nothing; the daily health refresh runs once per studio
-- per day; instructor_roster_notes guards; a template override wins and reset
-- restores; the retention board's drifting/at_risk sections; the brief line.
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
  ('a78c0000-0000-0000-0000-0000000000a0'),  -- owner (TA/TB/TC)
  ('a78c0000-0000-0000-0000-000000000e07');  -- a plain member (guard test)
insert into profiles (id, email) select id, id::text||'@example.com' from auth.users where id::text like 'a78c%';

insert into studios (id, name, slug, timezone, currency, status) values
  ('a78c0000-0000-0000-0000-000000000001','Tasks A','a78c-a','Asia/Manila','PHP','active'),
  ('a78c0000-0000-0000-0000-000000000002','Tasks B','a78c-b','Asia/Manila','PHP','active'),
  ('a78c0000-0000-0000-0000-000000000003','Tasks C','a78c-c','Asia/Manila','PHP','active');
select set_config('t.today', (now() at time zone 'Asia/Manila')::date::text, false);

insert into studio_settings (studio_id, retention_tasks_enabled, retention_tasks_to, time_format, checkin_window_enforced) values
  ('a78c0000-0000-0000-0000-000000000001', true,  'owner_manager', '24h', false),
  ('a78c0000-0000-0000-0000-000000000002', false, 'owner_manager', '24h', false),
  ('a78c0000-0000-0000-0000-000000000003', true,  'owner_manager', '24h', false);
insert into locations (id, studio_id, name, is_primary) values
  ('a78c0000-0000-0000-0000-00000000000a','a78c0000-0000-0000-0000-000000000001','Main',true);
insert into studio_staff (studio_id, user_id, email, role) values
  ('a78c0000-0000-0000-0000-000000000001','a78c0000-0000-0000-0000-0000000000a0','a78c-ow@example.com','owner');
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('a78c0000-0000-0000-0000-0000000cc001','a78c0000-0000-0000-0000-000000000001','Reformer',50,10);
insert into instructors (id, studio_id, display_name, status) values
  ('a78c0000-0000-0000-0000-0000000d1001','a78c0000-0000-0000-0000-000000000001','Ada Example','active');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('a78c0000-0000-0000-0000-0000000ee001','a78c0000-0000-0000-0000-000000000001','a78c0000-0000-0000-0000-00000000000a','R1',20);

insert into members (id, studio_id, user_id, first_name, last_name, email, phone, status, joined_on, source, health_band, health_reason) values
  ('a78c0000-0000-0000-0000-00000000ad01','a78c0000-0000-0000-0000-000000000001',null,'Ar','One','ar1@example.com','0917000001','active',current_date-60,'walk_in','at_risk','Was coming weekly, 21 days since'),
  ('a78c0000-0000-0000-0000-00000000ad02','a78c0000-0000-0000-0000-000000000001',null,'Ar','Two','ar2@example.com','0917000002','active',current_date-60,'walk_in','at_risk','Was coming weekly, 21 days since'),
  ('a78c0000-0000-0000-0000-00000000ad03','a78c0000-0000-0000-0000-000000000001',null,'Ar','Three','ar3@example.com','0917000003','active',current_date-60,'walk_in','at_risk','Was coming weekly, 21 days since'),
  ('a78c0000-0000-0000-0000-00000000ad04','a78c0000-0000-0000-0000-000000000001',null,'Dr','One','dr1@example.com','0917000004','active',current_date-60,'walk_in','drifting','Rhythm has slowed'),
  ('a78c0000-0000-0000-0000-00000000ad05','a78c0000-0000-0000-0000-000000000001',null,'Dr','Two','dr2@example.com','0917000005','active',current_date-60,'walk_in','drifting','Rhythm has slowed'),
  ('a78c0000-0000-0000-0000-00000000ad06','a78c0000-0000-0000-0000-000000000001',null,'Fresh','Face','ff@example.com','0917000006','lead',current_date-1,'self_signup','new','New'),
  ('a78c0000-0000-0000-0000-00000000ad07','a78c0000-0000-0000-0000-000000000001','a78c0000-0000-0000-0000-000000000e07','Plain','Member','pm@example.com','0917000007','active',current_date-5,'walk_in','healthy','Coming regularly'),
  ('a78c0000-0000-0000-0000-00000000ad20','a78c0000-0000-0000-0000-000000000002',null,'TB','AtRisk','tbar@example.com','0917000020','active',current_date-60,'walk_in','at_risk','Was coming weekly'),
  ('a78c0000-0000-0000-0000-00000000ad30','a78c0000-0000-0000-0000-000000000003',null,'TC','Member','tcm@example.com','0917000030','active',current_date-5,'walk_in','new','New');

-- AR2 already has an at_risk task AND a recent check-in (so the sweep closes it).
insert into member_tasks (id, studio_id, member_id, kind, reason, assigned_role, created_at) values
  ('a78c0000-0000-0000-0000-00000000f002','a78c0000-0000-0000-0000-000000000001','a78c0000-0000-0000-0000-00000000ad02','at_risk','old','owner_manager', now()-interval '2 days'),
  ('a78c0000-0000-0000-0000-00000000f003','a78c0000-0000-0000-0000-000000000001','a78c0000-0000-0000-0000-00000000ad03','at_risk','old','owner_manager', now()-interval '2 days');
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, starts_at, ends_at, capacity, booked_count, status, staffing) values
  ('a78c0000-0000-0000-0000-00000000cc10','a78c0000-0000-0000-0000-000000000001','a78c0000-0000-0000-0000-00000000000a','a78c0000-0000-0000-0000-0000000cc001','a78c0000-0000-0000-0000-0000000ee001','a78c0000-0000-0000-0000-0000000d1001','Reformer', now()+interval '2 days', now()+interval '2 days'+interval '50 min',10,2,'scheduled','assigned'),
  ('a78c0000-0000-0000-0000-00000000cc11','a78c0000-0000-0000-0000-000000000001','a78c0000-0000-0000-0000-00000000000a','a78c0000-0000-0000-0000-0000000cc001','a78c0000-0000-0000-0000-0000000ee001','a78c0000-0000-0000-0000-0000000d1001','Reformer', now()-interval '10 days', now()-interval '10 days'+interval '50 min',10,1,'scheduled','assigned');
-- AR2's check-in, after the task was created
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source) values
  ('a78c0000-0000-0000-0000-00000000bb02','a78c0000-0000-0000-0000-000000000001','a78c0000-0000-0000-0000-00000000cc11','a78c0000-0000-0000-0000-00000000ad02','attended','member','drop_in');
insert into check_ins (studio_id, member_id, occurrence_id, booking_id, checked_in_at, method) values
  ('a78c0000-0000-0000-0000-000000000001','a78c0000-0000-0000-0000-00000000ad02','a78c0000-0000-0000-0000-00000000cc11','a78c0000-0000-0000-0000-00000000bb02', now()-interval '1 hour','self');
-- AR3 recovers: flip the band to healthy so the sweep closes the task.
update members set health_band='healthy' where id='a78c0000-0000-0000-0000-00000000ad03';
-- DR2 already got a keep_drifting email recently (within 30 days).
insert into notifications (studio_id, recipient_type, member_id, template_key, channel, payload, dedupe_key, scheduled_for, status, created_at) values
  ('a78c0000-0000-0000-0000-000000000001','member','a78c0000-0000-0000-0000-00000000ad05','keep_drifting','email','{}'::jsonb,'keep_drifting:prior', now(),'sent', now()-interval '5 days');
-- FF (ad06) booked into the upcoming class (first-timer: no prior check-in); DR1 too (drifting roster note).
insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source) values
  ('a78c0000-0000-0000-0000-000000000001','a78c0000-0000-0000-0000-00000000cc10','a78c0000-0000-0000-0000-00000000ad06','booked','member','comp'),
  ('a78c0000-0000-0000-0000-000000000001','a78c0000-0000-0000-0000-00000000cc10','a78c0000-0000-0000-0000-00000000ad04','booked','member','drop_in');

-- Pre-seed TA's daily health-refresh row so the sweep SKIPS the refresh and our
-- manual bands survive (the refresh recomputes from attendance, which these
-- fixtures do not have). The refresh itself is tested on TC below.
insert into job_runs (job_key, run_for, status)
values ('health_refresh:a78c0000-0000-0000-0000-000000000001', current_setting('t.today')::date, 'done');

-- =============================================================================
-- 1. THE TASK RULES — one sweep on TA.
-- =============================================================================
select set_config('t.s1', convert_keep_sweep('a78c0000-0000-0000-0000-000000000001')::text, false);

select expect_num('at_risk creates exactly one task for AR1',
  (select count(*) from member_tasks where member_id='a78c0000-0000-0000-0000-00000000ad01' and kind='at_risk' and status='open'), 1);
select expect_true('the at_risk task carries the member name (rendered from task_at_risk_message)',
  (select suggested_message like '%Ar%' from member_tasks where member_id='a78c0000-0000-0000-0000-00000000ad01' and kind='at_risk' and status='open'));
select expect_text('the at_risk reason is the health reason',
  (select reason from member_tasks where member_id='a78c0000-0000-0000-0000-00000000ad01' and kind='at_risk' and status='open'), 'Was coming weekly, 21 days since');
select expect_text('a check-in closes the at_risk task (recovered)',
  (select status||':'||coalesce(close_note,'') from member_tasks where id='a78c0000-0000-0000-0000-00000000f002'), 'dismissed:recovered');
select expect_text('a recovered band closes the at_risk task',
  (select status||':'||coalesce(close_note,'') from member_tasks where id='a78c0000-0000-0000-0000-00000000f003'), 'dismissed:recovered');
-- drifting: the soft email (DR1 first time) and a hidden FYI task
select expect_num('drifting sends one keep_drifting email to DR1',
  (select count(*) from notifications where member_id='a78c0000-0000-0000-0000-00000000ad04' and template_key='keep_drifting' and status='scheduled'), 1);
select expect_num('DR1 gets a hidden drifting_fyi task',
  (select count(*) from member_tasks where member_id='a78c0000-0000-0000-0000-00000000ad04' and kind='drifting_fyi' and status='open'), 1);
select expect_num('DR2 (emailed 5 days ago) gets NO second keep_drifting within 30 days',
  (select count(*) from notifications where member_id='a78c0000-0000-0000-0000-00000000ad05' and template_key='keep_drifting' and status='scheduled'), 0);

-- second sweep: no new task, no new email
select set_config('t.s2', convert_keep_sweep('a78c0000-0000-0000-0000-000000000001')::text, false);
select expect_num('a second sweep creates no second at_risk task',
  (select count(*) from member_tasks where member_id='a78c0000-0000-0000-0000-00000000ad01' and kind='at_risk' and status='open'), 1);
select expect_num('a second sweep sends no second keep_drifting to DR1',
  (select count(*) from notifications where member_id='a78c0000-0000-0000-0000-00000000ad04' and template_key='keep_drifting'), 1);

-- =============================================================================
-- 2. TASKS OFF — TB writes nothing.
-- =============================================================================
select set_config('t.tb', convert_keep_sweep('a78c0000-0000-0000-0000-000000000002')::text, false);
select expect_num('tasks off => no task rows',
  (select count(*) from member_tasks mt join members m on m.id=mt.member_id where m.studio_id='a78c0000-0000-0000-0000-000000000002'), 0);
select expect_num('tasks off => no keep_drifting',
  (select count(*) from notifications n join members m on m.id=n.member_id where m.studio_id='a78c0000-0000-0000-0000-000000000002' and n.template_key='keep_drifting'), 0);

-- =============================================================================
-- 3. HEALTH REFRESH — runs once per studio per day (TC, not pre-seeded).
-- =============================================================================
select set_config('t.c1', convert_keep_sweep('a78c0000-0000-0000-0000-000000000003')::text, false);
select set_config('t.c2', convert_keep_sweep('a78c0000-0000-0000-0000-000000000003')::text, false);
select expect_num('the health refresh leaves exactly one job_runs row for the day',
  (select count(*) from job_runs where job_key='health_refresh:a78c0000-0000-0000-0000-000000000003'), 1);

-- =============================================================================
-- 4. INSTRUCTOR ROSTER NOTES — guard + the flags.
-- =============================================================================
-- as the owner (manager-up): the upcoming class's booked members, flags set
select expect_true('a first-timer is flagged',
  (select first_timer from instructor_roster_notes('a78c0000-0000-0000-0000-00000000cc10') where member_id='a78c0000-0000-0000-0000-00000000ad06'));
select expect_true('a drifting member is flagged (open drifting_fyi)',
  (select drifting from instructor_roster_notes('a78c0000-0000-0000-0000-00000000cc10') where member_id='a78c0000-0000-0000-0000-00000000ad04'));
-- a plain member is refused
set role authenticated; select set_config('request.jwt.claim.sub','a78c0000-0000-0000-0000-000000000e07',false);
do $$ begin perform * from instructor_roster_notes('a78c0000-0000-0000-0000-00000000cc10'); exception when others then perform set_config('t.gn', sqlstate, false); end $$;
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('a non-instructor, non-manager is refused', current_setting('t.gn'), 'PT403');

-- =============================================================================
-- 5. TEMPLATE OVERRIDE — wins over the default, reset restores.
-- =============================================================================
insert into notification_templates_overrides (studio_id, key, subject, body, body_html, updated_by) values
  ('a78c0000-0000-0000-0000-000000000001','keep_drifting','Miss you, {first_name}!',
   'Hi {first_name}, pop back to {studio_name} soon.',
   '<p>Hi {first_name}, pop back to <strong>{studio_name}</strong> soon.</p>',
   'a78c0000-0000-0000-0000-0000000000a0');
select queue_notification('a78c0000-0000-0000-0000-000000000001','a78c0000-0000-0000-0000-00000000ad01','keep_drifting',
  jsonb_build_object('first_name','Ar','studio_name','Tasks A','schedule_url','x'),'ovr:'||gen_random_uuid()::text) as qid \gset
select expect_text('the override subject wins', (select subject from render_notification(:'qid')), 'Miss you, Ar!');
select expect_true('the override html wins (strong, not raw markup)',
  (select html_body like '%<strong>Tasks A</strong>%' from render_notification(:'qid')));
-- reset: delete the override => default template renders again
delete from notification_templates_overrides where studio_id='a78c0000-0000-0000-0000-000000000001' and key='keep_drifting';
select queue_notification('a78c0000-0000-0000-0000-000000000001','a78c0000-0000-0000-0000-00000000ad01','keep_drifting',
  jsonb_build_object('first_name','Ar','studio_name','Tasks A','schedule_url','x'),'ovr2:'||gen_random_uuid()::text) as qid2 \gset
select expect_text('after reset, the default subject renders', (select subject from render_notification(:'qid2')), 'We haven''t seen you at Tasks A');

-- =============================================================================
-- 6. RETENTION BOARD sections + counts + the brief line.
-- =============================================================================
select expect_true('AR1 shows in the At risk section',
  exists(select 1 from retention_board('a78c0000-0000-0000-0000-000000000001') where member_id='a78c0000-0000-0000-0000-00000000ad01' and section='at_risk'));
select expect_true('DR1 shows in the Drifting section',
  exists(select 1 from retention_board('a78c0000-0000-0000-0000-000000000001') where member_id='a78c0000-0000-0000-0000-00000000ad04' and section='drifting'));
select expect_num('retention_counts reports at_risk',
  (retention_counts('a78c0000-0000-0000-0000-000000000001') ->> 'at_risk')::bigint, 1);
select expect_num('retention_counts reports drifting (DR1 + DR2)',
  (retention_counts('a78c0000-0000-0000-0000-000000000001') ->> 'drifting')::bigint, 2);
select set_config('t.brief', generate_morning_brief('a78c0000-0000-0000-0000-000000000001')::text, false);
select expect_true('the brief carries the retention_health line',
  exists(select 1 from ai_insights where studio_id='a78c0000-0000-0000-0000-000000000001' and type='retention_health'));

select 'tasks_test: all assertions passed' as done;
