-- =============================================================================
-- Decision 79a — the retention page: snapshot, email, bulk, contacts, outcomes,
-- snooze. Migrations 20260832780000..20260832840000. UUID space 7e9a, free.
-- Run after `supabase db reset`.
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
create or replace function login(uid text) returns void language plpgsql as $$
begin
  -- Session-level (false), so the claim persists across psql statements. An empty
  -- uid clears the claim to NULL (not ''), so auth.uid() returns null rather than
  -- failing to cast '' to uuid.
  if coalesce(uid, '') = '' then
    perform set_config('request.jwt.claim.sub', null, false);
    perform set_config('request.jwt.claims', null, false);
  else
    perform set_config('request.jwt.claim.sub', uid, false);
    perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role','authenticated')::text, false);
  end if;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('7e9a0000-0000-0000-0000-0000000000a0'),  -- owner
  ('7e9a0000-0000-0000-0000-0000000000a1'),  -- manager
  ('7e9a0000-0000-0000-0000-0000000000a2'),  -- front desk
  ('7e9a0000-0000-0000-0000-0000000000a3'),  -- instructor login
  ('7e9a0000-0000-0000-0000-0000000000f1');  -- a member login (own-read control)
insert into profiles (id, email, full_name)
  select id, id::text||'@example.com', 'Staff Person' from auth.users where id::text like '7e9a%';

insert into studios (id, name, slug, timezone, currency, status, contact_email) values
  ('7e9a0000-0000-0000-0000-000000000001','Retention A','7e9a-a','Europe/Prague','CZK','active','desk@a.example.com');
insert into studio_settings (studio_id, retention_tasks_to, time_format, booking_window_days, checkin_window_enforced) values
  ('7e9a0000-0000-0000-0000-000000000001','owner_manager','24h',30,false);
insert into locations (id, studio_id, name, is_primary) values
  ('7e9a0000-0000-0000-0000-00000000000a','7e9a0000-0000-0000-0000-000000000001','Main',true);
insert into studio_staff (studio_id, user_id, email, role, status) values
  ('7e9a0000-0000-0000-0000-000000000001','7e9a0000-0000-0000-0000-0000000000a0','owner@a.example.com','owner','active'),
  ('7e9a0000-0000-0000-0000-000000000001','7e9a0000-0000-0000-0000-0000000000a1','mgr@a.example.com','manager','active'),
  ('7e9a0000-0000-0000-0000-000000000001','7e9a0000-0000-0000-0000-0000000000a2','desk@a.example.com','front_desk','active');
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('7e9a0000-0000-0000-0000-0000000cc001','7e9a0000-0000-0000-0000-000000000001','Reformer Flow',50,10);
insert into instructors (id, studio_id, staff_id, display_name, status) values
  ('7e9a0000-0000-0000-0000-0000000d1001','7e9a0000-0000-0000-0000-000000000001',
    (select id from studio_staff where user_id='7e9a0000-0000-0000-0000-0000000000a3'), 'Nikko Example','active');
-- give the instructor a studio_staff row so the login resolves to them
insert into studio_staff (studio_id, user_id, email, role, status) values
  ('7e9a0000-0000-0000-0000-000000000001','7e9a0000-0000-0000-0000-0000000000a3','nikko@a.example.com','instructor','active');
update instructors set staff_id = (select id from studio_staff where user_id='7e9a0000-0000-0000-0000-0000000000a3')
 where id='7e9a0000-0000-0000-0000-0000000d1001';

-- Plans
insert into membership_plans (id, studio_id, name, type, price_cents, currency, billing_interval, credits_per_period, visibility, status) values
  ('7e9a0000-0000-0000-0000-00000000f001','7e9a0000-0000-0000-0000-000000000001','Unlimited Monthly','recurring',200000,'CZK','month',null,'public','active');

-- A class yesterday with the instructor, for last-class / usual-class.
insert into class_occurrences (id, studio_id, location_id, class_type_id, instructor_id, name, starts_at, ends_at, capacity, status) values
  ('7e9a0000-0000-0000-0000-00000000cc10','7e9a0000-0000-0000-0000-000000000001','7e9a0000-0000-0000-0000-00000000000a',
   '7e9a0000-0000-0000-0000-0000000cc001','7e9a0000-0000-0000-0000-0000000d1001','Reformer Flow',
   now() - interval '9 days', now() - interval '9 days' + interval '50 min', 10, 'scheduled');

-- Members: unconverted (free class), at_risk, drifting, expiring, lapsed.
insert into members (id, studio_id, first_name, last_name, email, phone, status, joined_on, last_visit_at, first_visit_at, lifetime_visits, health_band, health_reason) values
  ('7e9a0000-0000-0000-0000-00000000e001','7e9a0000-0000-0000-0000-000000000001','Uma','Unconv','uma@ex.com','+420 1','lead',    (now()-interval '9 days')::date, now()-interval '9 days', now()-interval '9 days', 1, null, null),
  ('7e9a0000-0000-0000-0000-00000000e002','7e9a0000-0000-0000-0000-000000000001','Ava','Atrisk','ava@ex.com','+420 2','active', (now()-interval '90 days')::date, now()-interval '16 days', now()-interval '90 days', 20, 'at_risk', 'Was coming about every 4 days, last visit 16 days ago.'),
  ('7e9a0000-0000-0000-0000-00000000e003','7e9a0000-0000-0000-0000-000000000001','Dan','Drift','dan@ex.com','+420 3','active',  (now()-interval '120 days')::date, now()-interval '25 days', now()-interval '120 days', 30, 'drifting', 'Not been in for a while.'),
  ('7e9a0000-0000-0000-0000-00000000e004','7e9a0000-0000-0000-0000-000000000001','Eve','Expire','eve@ex.com','+420 4','active', (now()-interval '60 days')::date, now()-interval '2 days', now()-interval '60 days', 25, 'healthy', null),
  ('7e9a0000-0000-0000-0000-00000000e005','7e9a0000-0000-0000-0000-000000000001','Leo','Lapsed','leo@ex.com','+420 5','active', (now()-interval '200 days')::date, now()-interval '40 days', now()-interval '200 days', 40, 'healthy', null),
  ('7e9a0000-0000-0000-0000-00000000e006','7e9a0000-0000-0000-0000-000000000001','Del','Eted','del@ex.com','+420 6','inactive', (now()-interval '30 days')::date, null, null, 0, null, null);
update members set deleted_at = now() where id = '7e9a0000-0000-0000-0000-00000000e006';

-- An import row so the booking-less (historical) check-ins are valid.
insert into imports (id, studio_id, type, filename, status) values
  ('7e9a0000-0000-0000-0000-0000000a1111','7e9a0000-0000-0000-0000-000000000001','attendance','seed.csv','complete');
-- Uma's free class (a comp booking + attendance), and a check-in for usual-class.
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source, booked_at) values
  ('7e9a0000-0000-0000-0000-00000000b001','7e9a0000-0000-0000-0000-000000000001','7e9a0000-0000-0000-0000-00000000cc10','7e9a0000-0000-0000-0000-00000000e001','attended','comp', now()-interval '9 days');
update members set waiver_signed_at = now() - interval '9 days' where id='7e9a0000-0000-0000-0000-00000000e001';
-- Uma's free-first record (host-null): makes her plan_state 'free_only'.
insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email, occurrence_id, guest_booking_id, status, waiver_signed_at) values
  ('7e9a0000-0000-0000-0000-000000000001', null, '7e9a0000-0000-0000-0000-00000000e001','uma@ex.com','7e9a0000-0000-0000-0000-00000000cc10','7e9a0000-0000-0000-0000-00000000b001','confirmed', now()-interval '9 days');
insert into check_ins (id, studio_id, occurrence_id, booking_id, member_id, checked_in_at, method, import_id) values
  ('7e9a0000-0000-0000-0000-0000000c1001','7e9a0000-0000-0000-0000-000000000001','7e9a0000-0000-0000-0000-00000000cc10','7e9a0000-0000-0000-0000-00000000b001','7e9a0000-0000-0000-0000-00000000e001', now()-interval '9 days', 'self', null),
  ('7e9a0000-0000-0000-0000-0000000c1002','7e9a0000-0000-0000-0000-000000000001','7e9a0000-0000-0000-0000-00000000cc10',null,'7e9a0000-0000-0000-0000-00000000e002', now()-interval '16 days', 'import', '7e9a0000-0000-0000-0000-0000000a1111');

-- An open at_risk task for Ava.
insert into member_tasks (studio_id, member_id, kind, reason, suggested_message, assigned_role, status) values
  ('7e9a0000-0000-0000-0000-000000000001','7e9a0000-0000-0000-0000-00000000e002','at_risk','16 days away','Hi Ava, we miss you!','owner_manager','open');

-- Expiring membership (ends in 5 days), lapsed membership (ended 10 days ago).
insert into memberships (id, studio_id, member_id, plan_id, status, starts_on, expires_on, auto_renew, price_cents, currency) values
  ('7e9a0000-0000-0000-0000-00000000a502','7e9a0000-0000-0000-0000-000000000001','7e9a0000-0000-0000-0000-00000000e002','7e9a0000-0000-0000-0000-00000000f001','active',(now()-interval '20 days')::date,(now()+interval '40 days')::date,false,200000,'CZK'),
  ('7e9a0000-0000-0000-0000-00000000a504','7e9a0000-0000-0000-0000-000000000001','7e9a0000-0000-0000-0000-00000000e004','7e9a0000-0000-0000-0000-00000000f001','active',(now()-interval '25 days')::date,(now()+interval '5 days')::date,false,200000,'CZK'),
  ('7e9a0000-0000-0000-0000-00000000a505','7e9a0000-0000-0000-0000-000000000001','7e9a0000-0000-0000-0000-00000000e005','7e9a0000-0000-0000-0000-00000000f001','expired',(now()-interval '40 days')::date,(now()-interval '10 days')::date,false,200000,'CZK');

-- The health band is a cached column the check-in/membership triggers recompute,
-- so pin it LAST (after every triggering insert) for the two band-driven sections.
update members set health_band='at_risk', health_reason='Was coming about every 4 days, last visit 16 days ago.'
 where id='7e9a0000-0000-0000-0000-00000000e002';
update members set health_band='drifting', health_reason='Not been in for a while.'
 where id='7e9a0000-0000-0000-0000-00000000e003';
-- Link Ava to a member login, for the member_sees_ai_drafts (79b) privacy check.
update members set user_id='7e9a0000-0000-0000-0000-0000000000f1' where id='7e9a0000-0000-0000-0000-00000000e002';

-- =============================================================================
-- Readers
-- =============================================================================
select set_config('t.snap', member_snapshot('7e9a0000-0000-0000-0000-00000000e002')::text, false);
select expect_text('snapshot: plan_state', (current_setting('t.snap')::jsonb)->>'plan_state', 'on_plan');
select expect_text('snapshot: health_band', (current_setting('t.snap')::jsonb)->>'health_band', 'at_risk');
select expect_true('snapshot: task present', ((current_setting('t.snap')::jsonb)->'task'->>'kind') = 'at_risk');
select expect_true('snapshot: journey is an array', jsonb_typeof((current_setting('t.snap')::jsonb)->'journey') = 'array');
select expect_num('snapshot: visits_30d counts the one recent', (((current_setting('t.snap')::jsonb)->>'visits_30d'))::bigint, 1);

select set_config('t.snapu', member_snapshot('7e9a0000-0000-0000-0000-00000000e001')::text, false);
select expect_text('snapshot (unconverted): plan_state free_only', (current_setting('t.snapu')::jsonb)->>'plan_state', 'free_only');
select expect_text('snapshot (unconverted): usual_class', (current_setting('t.snapu')::jsonb)->>'usual_class', 'Reformer Flow');

select set_config('t.ctx', retention_email_context('7e9a0000-0000-0000-0000-00000000e002','at_risk')::text, false);
select expect_text('context: first_name', (current_setting('t.ctx')::jsonb)->>'first_name', 'Ava');
select expect_text('context: studio_name', (current_setting('t.ctx')::jsonb)->>'studio_name', 'Retention A');
select expect_text('context: last_class', (current_setting('t.ctx')::jsonb)->>'last_class', 'Reformer Flow');
select expect_true('context: book_url is the member host', (current_setting('t.ctx')::jsonb)->>'book_url' like 'https://7e9a-a.%/book');

-- Board carries the new columns and the five sections.
select expect_num('board: five sections present', (select count(distinct section) from retention_board('7e9a0000-0000-0000-0000-000000000001')), 5);

-- =============================================================================
-- send_retention_email — notification + contact + task link + journey
-- =============================================================================
select set_config('t.send', send_retention_email('7e9a0000-0000-0000-0000-00000000e002','at_risk','We miss you','<p>hi</p>','hi')::text, false);
select expect_true('send: ok', ((current_setting('t.send')::jsonb)->>'ok')::boolean);
select expect_num('send: one retention notification', (select count(*) from notifications where member_id='7e9a0000-0000-0000-0000-00000000e002' and template_key='retention'), 1);
select expect_text('send: notification body carries the composer html', (select payload->>'body_html' from notifications where member_id='7e9a0000-0000-0000-0000-00000000e002' and template_key='retention'), '<p>hi</p>');
select expect_num('send: one member_contacts row (email)', (select count(*) from member_contacts where member_id='7e9a0000-0000-0000-0000-00000000e002' and method='email'), 1);
select expect_text('send: the at_risk task is now contacted', (select status from member_tasks where member_id='7e9a0000-0000-0000-0000-00000000e002' and kind='at_risk'), 'contacted');
select expect_true('send: the task is linked to the contact', (select contact_id is not null from member_tasks where member_id='7e9a0000-0000-0000-0000-00000000e002' and kind='at_risk'));
select expect_num('send: the contact shows in the Journey', (select count(*) from member_activity('7e9a0000-0000-0000-0000-00000000e002','2000-01-01','2100-01-01') where kind='contacted'), 1);
-- Second send the same day → duplicate (dedupe), no second notification.
select expect_text('send: a second send today is a duplicate', (send_retention_email('7e9a0000-0000-0000-0000-00000000e002','at_risk','x','<p>x</p>','x')::jsonb)->>'reason', 'duplicate');

-- record_contact for a task-less section (drifting), shows in the Journey.
select set_config('t.rec', record_contact('7e9a0000-0000-0000-0000-00000000e003','drifting','viber')::text, false);
select expect_num('record_contact: one viber row', (select count(*) from member_contacts where member_id='7e9a0000-0000-0000-0000-00000000e003' and method='viber'), 1);
select expect_num('record_contact: shows in Journey', (select count(*) from member_activity('7e9a0000-0000-0000-0000-00000000e003','2000-01-01','2100-01-01') where kind='contacted'), 1);

-- =============================================================================
-- Bulk — cap and skips
-- =============================================================================
select set_config('t.bulk', send_retention_email_bulk(array['7e9a0000-0000-0000-0000-00000000e004','7e9a0000-0000-0000-0000-00000000e006']::uuid[],'expiring','Renew','<p>r</p>','r')::text, false);
select expect_num('bulk: one sent (the live member)', (((current_setting('t.bulk')::jsonb)->>'sent'))::bigint, 1);
select expect_text('bulk: the deleted member is skipped', (current_setting('t.bulk')::jsonb)->'skipped'->0->>'reason', 'deleted');
-- cap at 50
do $$ declare ids uuid[]; begin
  select array_agg(gen_random_uuid()) into ids from generate_series(1,51);
  begin perform send_retention_email_bulk(ids,'expiring','s','<p>b</p>','b');
    raise exception 'FAIL  bulk over 50 should be refused';
  exception when sqlstate 'PT400' then raise notice 'PASS  bulk over 50 refused PT400'; end;
end $$;

-- =============================================================================
-- Snooze — hides the row until due
-- =============================================================================
select expect_true('board: Eve (expiring) is on the board before snooze',
  exists(select 1 from retention_board('7e9a0000-0000-0000-0000-000000000001') where member_id='7e9a0000-0000-0000-0000-00000000e004'));
select set_config('t.sn', snooze_task(null,'7e9a0000-0000-0000-0000-00000000e004','expiring',7)::text, false);
select expect_true('snooze: a follow_up task was created with a future due_at',
  exists(select 1 from member_tasks where member_id='7e9a0000-0000-0000-0000-00000000e004' and kind='follow_up' and status='open' and due_at > now()));
select expect_true('board: Eve is now hidden (snoozed)',
  not exists(select 1 from retention_board('7e9a0000-0000-0000-0000-000000000001') where member_id='7e9a0000-0000-0000-0000-00000000e004'));

-- =============================================================================
-- Outcomes — the sweep
-- =============================================================================
-- Ava was emailed today (above). Give her a check-in 2 days later; the sweep at
-- +3 days should set outcome='visited', outcome_days=2.
insert into check_ins (id, studio_id, occurrence_id, booking_id, member_id, checked_in_at, method, import_id) values
  ('7e9a0000-0000-0000-0000-0000000c1003','7e9a0000-0000-0000-0000-000000000001','7e9a0000-0000-0000-0000-00000000cc10',null,'7e9a0000-0000-0000-0000-00000000e002', now()+interval '2 days', 'import', '7e9a0000-0000-0000-0000-0000000a1111');
select set_config('t.sw', retention_outcome_sweep(now()+interval '3 days')::text, false);
select expect_text('sweep: Ava visited', (select outcome from member_contacts where member_id='7e9a0000-0000-0000-0000-00000000e002' and method='email'), 'visited');
select expect_num('sweep: outcome_days is 2', (select outcome_days from member_contacts where member_id='7e9a0000-0000-0000-0000-00000000e002' and method='email'), 2);
-- Dan's viber contact: nothing after it; at +15 days → 'none' at day 14.
select set_config('t.sw2', retention_outcome_sweep(now()+interval '15 days')::text, false);
select expect_text('sweep: Dan has no change', (select outcome from member_contacts where member_id='7e9a0000-0000-0000-0000-00000000e003' and method='viber'), 'none');
select expect_num('sweep: Dan outcome_days 14', (select outcome_days from member_contacts where member_id='7e9a0000-0000-0000-0000-00000000e003' and method='viber'), 14);

-- retention_outcomes counts this month's contacts and the ones that came back.
select set_config('t.out', retention_outcomes('7e9a0000-0000-0000-0000-000000000001')::text, false);
select expect_true('outcomes: at least 2 contacted', (((current_setting('t.out')::jsonb)->>'contacted'))::int >= 2);
select expect_true('outcomes: 1 came back', (((current_setting('t.out')::jsonb)->>'came_back'))::int >= 1);

-- =============================================================================
-- Guards — front desk only when routed; instructor refused
-- =============================================================================
-- Front desk, routing = owner_manager → refused.
set role authenticated;
select login('7e9a0000-0000-0000-0000-0000000000a2');
do $$ begin
  begin perform member_snapshot('7e9a0000-0000-0000-0000-00000000e002');
    raise exception 'FAIL  front desk (not routed) should be refused';
  exception when sqlstate 'PT403' then raise notice 'PASS  front desk not routed → member_snapshot PT403'; end;
end $$;
reset role;
-- Route to front desk, then the same front desk is allowed.
update studio_settings set retention_tasks_to='front_desk' where studio_id='7e9a0000-0000-0000-0000-000000000001';
set role authenticated;
select login('7e9a0000-0000-0000-0000-0000000000a2');
select expect_true('front desk routed → member_snapshot works',
  (member_snapshot('7e9a0000-0000-0000-0000-00000000e002')->>'member_id') = '7e9a0000-0000-0000-0000-00000000e002');
reset role;
-- Instructor refused regardless.
set role authenticated;
select login('7e9a0000-0000-0000-0000-0000000000a3');
do $$ begin
  begin perform member_snapshot('7e9a0000-0000-0000-0000-00000000e002');
    raise exception 'FAIL  an instructor should be refused';
  exception when sqlstate 'PT403' then raise notice 'PASS  instructor → member_snapshot PT403'; end;
end $$;
do $$ begin
  begin perform send_retention_email('7e9a0000-0000-0000-0000-00000000e002','at_risk','s','<p>x</p>','x');
    raise exception 'FAIL  an instructor should be refused from sending';
  exception when sqlstate 'PT403' then raise notice 'PASS  instructor → send_retention_email PT403'; end;
end $$;
reset role;
select login('');

-- =============================================================================
-- Decision 79b — AI drafts (opt-in, default OFF)
-- =============================================================================
select expect_true('ai_drafts default OFF',
  (select ai_drafts_enabled = false from studio_settings where studio_id='7e9a0000-0000-0000-0000-000000000001'));
select expect_true('ai_draft_gate: enabled false when off',
  (ai_draft_gate('7e9a0000-0000-0000-0000-000000000001'::uuid)->>'enabled')::boolean = false);
update studio_settings set ai_drafts_enabled=true, studio_voice='Warm and brief.' where studio_id='7e9a0000-0000-0000-0000-000000000001';
select set_config('t.gate', ai_draft_gate('7e9a0000-0000-0000-0000-000000000001'::uuid)::text, false);
select expect_true('ai_draft_gate: enabled true when on', ((current_setting('t.gate')::jsonb)->>'enabled')::boolean);
select expect_text('ai_draft_gate: model', (current_setting('t.gate')::jsonb)->>'model', 'claude-sonnet-5-5');
select expect_num('ai_draft_gate: default cap 200', (((current_setting('t.gate')::jsonb)->>'cap'))::bigint, 200);
select expect_num('ai_draft_gate: used 0 to start', (((current_setting('t.gate')::jsonb)->>'used'))::bigint, 0);
-- record_ai_draft writes a usage row; ai_draft_count counts it.
select set_config('t.rec', record_ai_draft('7e9a0000-0000-0000-0000-000000000001'::uuid,'7e9a0000-0000-0000-0000-00000000e002','at_risk','claude-sonnet-5-5',120,48)::text, false);
select expect_num('record_ai_draft: one usage row', (select count(*) from ai_draft_usage where studio_id='7e9a0000-0000-0000-0000-000000000001'), 1);
select expect_num('ai_draft_count: 1', ai_draft_count('7e9a0000-0000-0000-0000-000000000001'::uuid), 1);
-- Cap reached: a cap of 1 and one used → the gate's used >= cap (the action refuses).
update notification_config set value='1' where key='ai_drafts_monthly_cap';
select set_config('t.gate2', ai_draft_gate('7e9a0000-0000-0000-0000-000000000001'::uuid)::text, false);
select expect_true('cap reached: used >= cap',
  (((current_setting('t.gate2')::jsonb)->>'used'))::int >= (((current_setting('t.gate2')::jsonb)->>'cap'))::int);
update notification_config set value='200' where key='ai_drafts_monthly_cap';
-- member_sees_ai_drafts for the linked member.
set role authenticated; select login('7e9a0000-0000-0000-0000-0000000000f1');
select expect_true('member_sees_ai_drafts true when the studio has it on', member_sees_ai_drafts());
reset role; select login('');
-- Guards: an instructor is refused the gate and record.
set role authenticated; select login('7e9a0000-0000-0000-0000-0000000000a3');
do $$ begin
  begin perform ai_draft_gate('7e9a0000-0000-0000-0000-000000000001'::uuid);
    raise exception 'FAIL  instructor should be refused ai_draft_gate';
  exception when sqlstate 'PT403' then raise notice 'PASS  instructor → ai_draft_gate PT403'; end;
end $$;
do $$ begin
  begin perform record_ai_draft('7e9a0000-0000-0000-0000-000000000001'::uuid,null,'at_risk','m',1,1);
    raise exception 'FAIL  instructor should be refused record_ai_draft';
  exception when sqlstate 'PT403' then raise notice 'PASS  instructor → record_ai_draft PT403'; end;
end $$;
reset role; select login('');
-- A member cannot read the usage log (manager-up only).
set role authenticated; select login('7e9a0000-0000-0000-0000-0000000000f1');
select expect_num('member cannot read ai_draft_usage (RLS)', (select count(*) from ai_draft_usage), 0);
reset role; select login('');

-- Anon surface unchanged: none of the new RPCs are anon.
select expect_num('anon surface stays THIRTEEN',
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and has_function_privilege('anon',p.oid,'execute')
      and p.proname not like 'expect_%' and p.proname not in ('login')), 13);

select 'retention_test: all assertions passed' as result;
