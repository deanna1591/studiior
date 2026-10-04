-- =============================================================================
-- Decision 59 — the monthly schedule email: plain vs confirm version by the
-- switch, the cover rule with {hours}, and the re-send. UUID space 59a0.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_true(label text, actual boolean) returns void language plpgsql as $$
begin if actual then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_false(label text, actual boolean) returns void language plpgsql as $$
begin if actual is not null and not actual then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected false, got %', label, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_num(label text, actual bigint, want bigint) returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (%)', label, actual;
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_contains(label text, hay text, needle text) returns void language plpgsql as $$
begin if hay is not null and position(needle in hay) > 0 then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  % not found in: %', label, needle, left(coalesce(hay,'null'), 200); end if; end $$;
create or replace function expect_absent(label text, hay text, needle text) returns void language plpgsql as $$
begin if hay is null or position(needle in hay) = 0 then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  % SHOULD be absent but is in: %', label, needle, left(coalesce(hay,'null'), 200); end if; end $$;
create or replace function expect_raises(label text, code text, stmt text) returns void language plpgsql as $$
begin begin execute stmt; raise exception 'FAIL  %  expected % but nothing raised', label, code;
  exception when others then
    if SQLSTATE = code then raise notice 'PASS  %  (%)', label, code;
    else raise exception 'FAIL  %  expected %, got % (%)', label, code, SQLSTATE, SQLERRM; end if; end; end $$;

-- --- Fixtures ----------------------------------------------------------------
-- SA: publication on, confirmations OFF, cover_escalation_hours 12.
-- SB: publication on, confirmations ON,  cover_escalation_hours 5.
insert into auth.users (id) values
  ('59a05901-0000-0000-0000-0000000000a1'),  -- SA owner
  ('59a05901-0000-0000-0000-0000000000a2'),  -- SA I1 (login)
  ('59a05901-0000-0000-0000-0000000000a4'),  -- SA front desk
  ('59a05901-0000-0000-0000-0000000000b1'),  -- SB owner/manager
  ('59a05901-0000-0000-0000-0000000000b2');  -- SB I3 (login)
insert into profiles (id, email) values
  ('59a05901-0000-0000-0000-0000000000a1','59a0-oa@example.com'),
  ('59a05901-0000-0000-0000-0000000000a2','59a0-a2@example.com'),
  ('59a05901-0000-0000-0000-0000000000a4','59a0-a4@example.com'),
  ('59a05901-0000-0000-0000-0000000000b1','59a0-ob@example.com'),
  ('59a05901-0000-0000-0000-0000000000b2','59a0-b2@example.com');
insert into studios (id, name, slug, timezone, currency, status) values
  ('59a05901-0000-0000-0000-000000000001','Studio A','studio-a-59','Europe/Prague','CZK','active'),
  ('59a05901-0000-0000-0000-000000000002','Studio B','studio-b-59','Europe/Prague','CZK','active');
insert into studio_settings (studio_id, publication_enabled, assignment_confirmations, cover_escalation_hours) values
  ('59a05901-0000-0000-0000-000000000001', true, false, 12),
  ('59a05901-0000-0000-0000-000000000002', true, true, 5);
insert into locations (id, studio_id, name, is_primary) values
  ('59a05901-0000-0000-0000-00000000000a','59a05901-0000-0000-0000-000000000001','Main',true),
  ('59a05901-0000-0000-0000-00000000000b','59a05901-0000-0000-0000-000000000002','Main',true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('59a05901-0000-0000-0000-0000000ee0a1','59a05901-0000-0000-0000-000000000001','59a05901-0000-0000-0000-00000000000a','R',10),
  ('59a05901-0000-0000-0000-0000000ee0b1','59a05901-0000-0000-0000-000000000002','59a05901-0000-0000-0000-00000000000b','R',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('59a05901-0000-0000-0000-0000000cc0a1','59a05901-0000-0000-0000-000000000001','Reformer',50,10),
  ('59a05901-0000-0000-0000-0000000cc0b1','59a05901-0000-0000-0000-000000000002','Reformer',50,10);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('59a05901-0000-0000-0000-000000aa00a1','59a05901-0000-0000-0000-000000000001','59a05901-0000-0000-0000-0000000000a1','59a0-oa@example.com','owner'),
  ('59a05901-0000-0000-0000-000000aa00a2','59a05901-0000-0000-0000-000000000001','59a05901-0000-0000-0000-0000000000a2','59a0-a2@example.com','instructor'),
  ('59a05901-0000-0000-0000-000000aa00a4','59a05901-0000-0000-0000-000000000001','59a05901-0000-0000-0000-0000000000a4','59a0-a4@example.com','front_desk'),
  ('59a05901-0000-0000-0000-000000aa00b1','59a05901-0000-0000-0000-000000000002','59a05901-0000-0000-0000-0000000000b1','59a0-ob@example.com','owner'),
  ('59a05901-0000-0000-0000-000000aa00b2','59a05901-0000-0000-0000-000000000002','59a05901-0000-0000-0000-0000000000b2','59a0-b2@example.com','instructor');
-- SA instructors: I1 has a login, I2 does NOT.
insert into instructors (id, studio_id, display_name, staff_id) values
  ('59a05901-0000-0000-0000-0000000d00a2','59a05901-0000-0000-0000-000000000001','Ada One','59a05901-0000-0000-0000-000000aa00a2'),
  ('59a05901-0000-0000-0000-0000000d00a3','59a05901-0000-0000-0000-000000000001','Bo NoLogin', null),
  ('59a05901-0000-0000-0000-0000000d00b2','59a05901-0000-0000-0000-000000000002','Cy Three','59a05901-0000-0000-0000-000000aa00b2');

-- Classes NEXT MONTH (future → a draft until published), in each studio's zone.
-- SA: I1 gets 2, I2 (no login) gets 1. SB: I3 gets 1.
\set nm '(date_trunc(''month'', current_date) + interval ''1 month'')::date'
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, booked_count, starts_at, ends_at, status)
values
  ('59a05901-0000-0000-0000-0000000c0001','59a05901-0000-0000-0000-000000000001','59a05901-0000-0000-0000-00000000000a','59a05901-0000-0000-0000-0000000cc0a1','59a05901-0000-0000-0000-0000000ee0a1','59a05901-0000-0000-0000-0000000d00a2','Reformer Flow',10,0,
     ((date_trunc('month', current_date) + interval '1 month' + interval '9 days')::date + time '07:00') at time zone 'Europe/Prague',
     ((date_trunc('month', current_date) + interval '1 month' + interval '9 days')::date + time '07:50') at time zone 'Europe/Prague','scheduled'),
  ('59a05901-0000-0000-0000-0000000c0002','59a05901-0000-0000-0000-000000000001','59a05901-0000-0000-0000-00000000000a','59a05901-0000-0000-0000-0000000cc0a1','59a05901-0000-0000-0000-0000000ee0a1','59a05901-0000-0000-0000-0000000d00a2','Reformer Flow',10,0,
     ((date_trunc('month', current_date) + interval '1 month' + interval '11 days')::date + time '07:00') at time zone 'Europe/Prague',
     ((date_trunc('month', current_date) + interval '1 month' + interval '11 days')::date + time '07:50') at time zone 'Europe/Prague','scheduled'),
  ('59a05901-0000-0000-0000-0000000c0003','59a05901-0000-0000-0000-000000000001','59a05901-0000-0000-0000-00000000000a','59a05901-0000-0000-0000-0000000cc0a1','59a05901-0000-0000-0000-0000000ee0a1','59a05901-0000-0000-0000-0000000d00a3','Reformer Flow',10,0,
     ((date_trunc('month', current_date) + interval '1 month' + interval '10 days')::date + time '09:00') at time zone 'Europe/Prague',
     ((date_trunc('month', current_date) + interval '1 month' + interval '10 days')::date + time '09:50') at time zone 'Europe/Prague','scheduled'),
  ('59a05901-0000-0000-0000-0000000c00b1','59a05901-0000-0000-0000-000000000002','59a05901-0000-0000-0000-00000000000b','59a05901-0000-0000-0000-0000000cc0b1','59a05901-0000-0000-0000-0000000ee0b1','59a05901-0000-0000-0000-0000000d00b2','Reformer Flow',10,0,
     ((date_trunc('month', current_date) + interval '1 month' + interval '9 days')::date + time '07:00') at time zone 'Europe/Prague',
     ((date_trunc('month', current_date) + interval '1 month' + interval '9 days')::date + time '07:50') at time zone 'Europe/Prague','scheduled');

-- =============================================================================
-- 1. publish_month SA (confirmations OFF) → the plain version.
-- =============================================================================
select set_config('t.nm', (date_trunc('month', current_date) + interval '1 month')::date::text, false);
set role authenticated;
select set_config('request.jwt.claim.sub','59a05901-0000-0000-0000-0000000000a1',false);  -- SA owner
select set_config('t.pub', (publish_month('59a05901-0000-0000-0000-000000000001', current_setting('t.nm')::date)::text), false);
reset role;
select expect_num('publish SA notified exactly the ONE login instructor',
  (current_setting('t.pub')::jsonb ->> 'notified')::bigint, 1);
select expect_num('...and named the ONE with no login as unreachable',
  jsonb_array_length(current_setting('t.pub')::jsonb -> 'unreachable'), 1);

-- I1's notification is the PLAIN template.
select set_config('t.n1', (select id::text from notifications
  where user_id='59a05901-0000-0000-0000-0000000000a2' and template_key='month_roster_plain'
  order by created_at desc limit 1), false);
select expect_true('I1 got a month_roster_plain notification',
  current_setting('t.n1', true) is not null and current_setting('t.n1') <> '');
select expect_contains('plain subject states the schedule, not "confirm"',
  (select subject from render_notification(current_setting('t.n1')::uuid)), 'schedule at Studio A');
select expect_absent('plain subject has no "confirm"',
  (select subject from render_notification(current_setting('t.n1')::uuid)), 'confirm');
select expect_contains('plain body names the cover rule with the studio hours (12)',
  (select text_body from render_notification(current_setting('t.n1')::uuid)), 'at least 12 hours');
select expect_contains('plain body says ask a colleague directly',
  (select text_body from render_notification(current_setting('t.n1')::uuid)), 'ask a colleague directly');
select expect_absent('plain body has NO "please confirm"/"Confirm the month"',
  (select text_body from render_notification(current_setting('t.n1')::uuid)), 'Confirm the month');
select expect_contains('plain body lists the classes',
  (select text_body from render_notification(current_setting('t.n1')::uuid)), 'Reformer Flow');

-- No "confirm the month" ask shown: my_month_roster carries confirmations_on=false.
set role authenticated;
select set_config('request.jwt.claim.sub','59a05901-0000-0000-0000-0000000000a2',false);  -- I1
select expect_false('my_month_roster.confirmations_on is false (no prompt) for I1',
  (my_month_roster('59a05901-0000-0000-0000-0000000d00a2', current_setting('t.nm')::date) ->> 'confirmations_on')::boolean);
reset role;

-- =============================================================================
-- 2. publish_month SB (confirmations ON) → "please confirm" + cover sentence.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','59a05901-0000-0000-0000-0000000000b1',false);  -- SB owner
select publish_month('59a05901-0000-0000-0000-000000000002', current_setting('t.nm')::date);
reset role;
select set_config('t.n3', (select id::text from notifications
  where user_id='59a05901-0000-0000-0000-0000000000b2' and template_key='month_roster'
  order by created_at desc limit 1), false);
select expect_contains('confirm subject still says "please confirm"',
  (select subject from render_notification(current_setting('t.n3')::uuid)), 'please confirm');
select expect_contains('confirm body keeps "Confirm the month"',
  (select text_body from render_notification(current_setting('t.n3')::uuid)), 'Confirm the month');
select expect_contains('confirm body ALSO names the cover rule with SB hours (5)',
  (select text_body from render_notification(current_setting('t.n3')::uuid)), 'at least 5 hours');

-- =============================================================================
-- 3. Re-send (SA): one per login instructor, dedupe does NOT swallow a 2nd send,
--    no-login names returned, front desk + cross-studio PT403.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','59a05901-0000-0000-0000-0000000000a1',false);  -- SA owner
select set_config('t.r1', (resend_month_roster('59a05901-0000-0000-0000-000000000001', current_setting('t.nm')::date)::text), false);
reset role;
select expect_num('resend sent to the ONE login instructor',
  (current_setting('t.r1')::jsonb ->> 'sent')::bigint, 1);
select expect_num('...and returned the ONE no-login name',
  jsonb_array_length(current_setting('t.r1')::jsonb -> 'no_login'), 1);
select expect_contains('...the no-login name is Bo',
  current_setting('t.r1')::jsonb -> 'no_login' -> 0 ->> 'name', 'Bo NoLogin');

-- After publish (1) + one resend (1), I1 has 2 plain notifications.
select expect_num('publish + one resend = 2 plain notifications for I1',
  (select count(*) from notifications
    where user_id='59a05901-0000-0000-0000-0000000000a2' and template_key='month_roster_plain')::bigint, 2);
-- A SECOND resend is NOT swallowed by the dedupe key → 3.
set role authenticated;
select set_config('request.jwt.claim.sub','59a05901-0000-0000-0000-0000000000a1',false);
select resend_month_roster('59a05901-0000-0000-0000-000000000001', current_setting('t.nm')::date);
reset role;
select expect_num('a second resend is NOT swallowed by the dedupe → 3',
  (select count(*) from notifications
    where user_id='59a05901-0000-0000-0000-0000000000a2' and template_key='month_roster_plain')::bigint, 3);

-- Front desk at SA cannot resend.
set role authenticated;
select set_config('request.jwt.claim.sub','59a05901-0000-0000-0000-0000000000a4',false);  -- front desk
select expect_raises('front desk → PT403 on resend', 'PT403',
  $$ select resend_month_roster('59a05901-0000-0000-0000-000000000001', current_setting('t.nm')::date) $$);
-- A manager of SB cannot resend SA's roster.
select set_config('request.jwt.claim.sub','59a05901-0000-0000-0000-0000000000b1',false);  -- SB owner
select expect_raises('cross-studio → PT403 on resend', 'PT403',
  $$ select resend_month_roster('59a05901-0000-0000-0000-000000000001', current_setting('t.nm')::date) $$);
reset role;

-- =============================================================================
-- 4. publish_month's own once-per-month send is unchanged: a second publish does
--    NOT re-send (it returns already_published before the loop).
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','59a05901-0000-0000-0000-0000000000a1',false);  -- SA owner
select set_config('t.pub2', (publish_month('59a05901-0000-0000-0000-000000000001', current_setting('t.nm')::date)::text), false);
reset role;
select expect_true('a second publish is already_published',
  (current_setting('t.pub2')::jsonb ->> 'already_published')::boolean);
select expect_num('...and sends nothing more (notified 0)',
  (current_setting('t.pub2')::jsonb ->> 'notified')::bigint, 0);
select expect_num('...the publish-keyed notification for I1 is still exactly ONE',
  (select count(*) from notifications
    where dedupe_key = 'month_roster:59a05901-0000-0000-0000-0000000d00a2:' || current_setting('t.nm'))::bigint, 1);

select 'month_roster_test: all assertions passed' as result;
