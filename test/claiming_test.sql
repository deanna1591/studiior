-- =============================================================================
-- Instructor claiming — the per-tenant inverted staffing model (migration 149)
-- =============================================================================
-- UUID space c1a1, checked free. Run after `supabase db reset`.
--
-- A claiming studio publishes UNASSIGNED core/flex classes; instructors claim
-- them (apply_for_shift); staff approve (approve_shift_application, reused). The
-- new behaviour: a per-instructor CORE weekly cap (soft), flex uncapped, pending
-- claims counting toward the cap, the claim list filtered to what an instructor
-- can take, the validity-window hard gate, and a claiming-off studio unchanged.
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
  if actual then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_false(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual is not null and not actual then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected false, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('c1a1c1a1-0000-0000-0000-0000000000a1'),  -- owner A
  ('c1a1c1a1-0000-0000-0000-0000000000d1'),  -- instructor X (cap default 3)
  ('c1a1c1a1-0000-0000-0000-0000000000d2'),  -- instructor Y (cap 1)
  ('c1a1c1a1-0000-0000-0000-0000000000d3'),  -- instructor W (validity blocked)
  ('c1a1c1a1-0000-0000-0000-0000000000b1'),  -- owner B (claiming off)
  ('c1a1c1a1-0000-0000-0000-0000000000e1');  -- instructor at B
insert into profiles (id, email) values
  ('c1a1c1a1-0000-0000-0000-0000000000a1','c1a1-owner-a@example.com'),
  ('c1a1c1a1-0000-0000-0000-0000000000d1','c1a1-x@example.com'),
  ('c1a1c1a1-0000-0000-0000-0000000000d2','c1a1-y@example.com'),
  ('c1a1c1a1-0000-0000-0000-0000000000d3','c1a1-w@example.com'),
  ('c1a1c1a1-0000-0000-0000-0000000000b1','c1a1-owner-b@example.com'),
  ('c1a1c1a1-0000-0000-0000-0000000000e1','c1a1-e@example.com');

-- Studio A: claiming ON, Monday weeks, default core cap 3. Studio S: claiming ON,
-- SUNDAY weeks (the week-boundary proof). Studio B: claiming OFF.
insert into studios (id, name, slug, timezone, currency, status) values
  ('c1a1c1a1-0000-0000-0000-000000000001','Claim A','claim-a','Europe/Prague','CZK','active'),
  ('c1a1c1a1-0000-0000-0000-000000000002','Claim S','claim-s','Europe/Prague','CZK','active'),
  ('c1a1c1a1-0000-0000-0000-000000000003','Assign B','assign-b','Europe/Prague','CZK','active');
insert into studio_settings (studio_id, claiming_enabled, publication_enabled, core_claim_default_cap, week_starts_on) values
  ('c1a1c1a1-0000-0000-0000-000000000001', true,  true, 3, 1),
  ('c1a1c1a1-0000-0000-0000-000000000002', true,  true, 3, 0),   -- Sunday-start
  ('c1a1c1a1-0000-0000-0000-000000000003', false, false, 3, 1);  -- assigned model
insert into locations (id, studio_id, name, is_primary) values
  ('c1a1c1a1-0000-0000-0000-00000000000a','c1a1c1a1-0000-0000-0000-000000000001','Main',true),
  ('c1a1c1a1-0000-0000-0000-000000000005','c1a1c1a1-0000-0000-0000-000000000002','Main',true),
  ('c1a1c1a1-0000-0000-0000-00000000000b','c1a1c1a1-0000-0000-0000-000000000003','Main',true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('c1a1c1a1-0000-0000-0000-0000000ee0a1','c1a1c1a1-0000-0000-0000-000000000001','c1a1c1a1-0000-0000-0000-00000000000a','R',10),
  ('c1a1c1a1-0000-0000-0000-0000000ee051','c1a1c1a1-0000-0000-0000-000000000002','c1a1c1a1-0000-0000-0000-000000000005','R',10),
  ('c1a1c1a1-0000-0000-0000-0000000ee0b1','c1a1c1a1-0000-0000-0000-000000000003','c1a1c1a1-0000-0000-0000-00000000000b','R',10);
-- Core class type (guarantee_tier default 'core') and a flex one (flex=true).
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('c1a1c1a1-0000-0000-0000-0000000cc0a1','c1a1c1a1-0000-0000-0000-000000000001','Core Reformer',50,10),
  ('c1a1c1a1-0000-0000-0000-0000000cc0a2','c1a1c1a1-0000-0000-0000-000000000001','Second Type',50,10),
  ('c1a1c1a1-0000-0000-0000-0000000cc051','c1a1c1a1-0000-0000-0000-000000000002','Core Reformer',50,10),
  ('c1a1c1a1-0000-0000-0000-0000000cc0b1','c1a1c1a1-0000-0000-0000-000000000003','Core Reformer',50,10);

insert into studio_staff (id, studio_id, user_id, email, role) values
  ('c1a1c1a1-0000-0000-0000-000000aa00a1','c1a1c1a1-0000-0000-0000-000000000001','c1a1c1a1-0000-0000-0000-0000000000a1','c1a1-owner-a@example.com','owner'),
  ('c1a1c1a1-0000-0000-0000-000000aa00d1','c1a1c1a1-0000-0000-0000-000000000001','c1a1c1a1-0000-0000-0000-0000000000d1','c1a1-x@example.com','instructor'),
  ('c1a1c1a1-0000-0000-0000-000000aa00d2','c1a1c1a1-0000-0000-0000-000000000001','c1a1c1a1-0000-0000-0000-0000000000d2','c1a1-y@example.com','instructor'),
  ('c1a1c1a1-0000-0000-0000-000000aa00d3','c1a1c1a1-0000-0000-0000-000000000001','c1a1c1a1-0000-0000-0000-0000000000d3','c1a1-w@example.com','instructor'),
  ('c1a1c1a1-0000-0000-0000-000000aa00b1','c1a1c1a1-0000-0000-0000-000000000003','c1a1c1a1-0000-0000-0000-0000000000b1','c1a1-owner-b@example.com','owner'),
  ('c1a1c1a1-0000-0000-0000-000000aa00e1','c1a1c1a1-0000-0000-0000-000000000003','c1a1c1a1-0000-0000-0000-0000000000e1','c1a1-e@example.com','instructor');
insert into instructors (id, studio_id, display_name, staff_id, core_weekly_cap) values
  ('c1a1c1a1-0000-0000-0000-0000000d00d1','c1a1c1a1-0000-0000-0000-000000000001','Xavier Claim','c1a1c1a1-0000-0000-0000-000000aa00d1', null),  -- default 3
  ('c1a1c1a1-0000-0000-0000-0000000d00d2','c1a1c1a1-0000-0000-0000-000000000001','Yolanda Claim','c1a1c1a1-0000-0000-0000-000000aa00d2', 1),    -- cap 1
  ('c1a1c1a1-0000-0000-0000-0000000d00d3','c1a1c1a1-0000-0000-0000-000000000001','Willa Claim','c1a1c1a1-0000-0000-0000-000000aa00d3', null),
  ('c1a1c1a1-0000-0000-0000-0000000d00e1','c1a1c1a1-0000-0000-0000-000000000003','Ed Assign','c1a1c1a1-0000-0000-0000-000000aa00e1', null);
-- X, Y qualified for Core Reformer; W qualified too. (Second Type left unmapped
-- for X so the claim list can label it "not down to teach this".)
insert into instructor_class_types (studio_id, instructor_id, class_type_id) values
  ('c1a1c1a1-0000-0000-0000-000000000001','c1a1c1a1-0000-0000-0000-0000000d00d1','c1a1c1a1-0000-0000-0000-0000000cc0a1'),
  ('c1a1c1a1-0000-0000-0000-000000000001','c1a1c1a1-0000-0000-0000-0000000d00d2','c1a1c1a1-0000-0000-0000-0000000cc0a1'),
  ('c1a1c1a1-0000-0000-0000-000000000001','c1a1c1a1-0000-0000-0000-0000000d00d3','c1a1c1a1-0000-0000-0000-0000000cc0a1');

-- The class month = the month of (current_date + 21). All classes are that month.
-- X and Y submit approved availability for it; W submits it too BUT also carries a
-- standing pattern whose window has ended, so instructor_valid_on is false for W.
insert into availability_submissions (studio_id, instructor_id, period_start, status) values
  ('c1a1c1a1-0000-0000-0000-000000000001','c1a1c1a1-0000-0000-0000-0000000d00d1', date_trunc('month',(current_date+21))::date, 'approved'),
  ('c1a1c1a1-0000-0000-0000-000000000001','c1a1c1a1-0000-0000-0000-0000000d00d2', date_trunc('month',(current_date+21))::date, 'approved'),
  ('c1a1c1a1-0000-0000-0000-000000000001','c1a1c1a1-0000-0000-0000-0000000d00d3', date_trunc('month',(current_date+21))::date, 'approved');
-- W's standing pattern ended in the past -> valid_on false for a future class.
insert into instructor_availability (instructor_id, studio_id, day_of_week, starts_at_time, ends_at_time, effective_from, effective_to, approval_status)
select 'c1a1c1a1-0000-0000-0000-0000000d00d3','c1a1c1a1-0000-0000-0000-000000000001', d, '06:00','22:00', current_date-60, current_date-30, 'approved'
  from generate_series(0,6) d;

-- Five CORE classes on ONE day (current_date+21) at different times (same studio
-- week trivially), plus two FLEX, plus one "Second Type" (X not qualified). All
-- open (unassigned) and in a published month.
insert into class_occurrences
  (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, booked_count, starts_at, ends_at, status, flex)
values
  ('c1a1c1a1-0000-0000-0000-000000c00001','c1a1c1a1-0000-0000-0000-000000000001','c1a1c1a1-0000-0000-0000-00000000000a','c1a1c1a1-0000-0000-0000-0000000cc0a1','c1a1c1a1-0000-0000-0000-0000000ee0a1',null,'Core Reformer',10,0,((current_date+21)+time '07:00') at time zone 'Europe/Prague',((current_date+21)+time '07:50') at time zone 'Europe/Prague','scheduled',false),
  ('c1a1c1a1-0000-0000-0000-000000c00002','c1a1c1a1-0000-0000-0000-000000000001','c1a1c1a1-0000-0000-0000-00000000000a','c1a1c1a1-0000-0000-0000-0000000cc0a1','c1a1c1a1-0000-0000-0000-0000000ee0a1',null,'Core Reformer',10,0,((current_date+21)+time '09:00') at time zone 'Europe/Prague',((current_date+21)+time '09:50') at time zone 'Europe/Prague','scheduled',false),
  ('c1a1c1a1-0000-0000-0000-000000c00003','c1a1c1a1-0000-0000-0000-000000000001','c1a1c1a1-0000-0000-0000-00000000000a','c1a1c1a1-0000-0000-0000-0000000cc0a1','c1a1c1a1-0000-0000-0000-0000000ee0a1',null,'Core Reformer',10,0,((current_date+21)+time '11:00') at time zone 'Europe/Prague',((current_date+21)+time '11:50') at time zone 'Europe/Prague','scheduled',false),
  ('c1a1c1a1-0000-0000-0000-000000c00004','c1a1c1a1-0000-0000-0000-000000000001','c1a1c1a1-0000-0000-0000-00000000000a','c1a1c1a1-0000-0000-0000-0000000cc0a1','c1a1c1a1-0000-0000-0000-0000000ee0a1',null,'Core Reformer',10,0,((current_date+21)+time '13:00') at time zone 'Europe/Prague',((current_date+21)+time '13:50') at time zone 'Europe/Prague','scheduled',false),
  ('c1a1c1a1-0000-0000-0000-000000c00005','c1a1c1a1-0000-0000-0000-000000000001','c1a1c1a1-0000-0000-0000-00000000000a','c1a1c1a1-0000-0000-0000-0000000cc0a1','c1a1c1a1-0000-0000-0000-0000000ee0a1',null,'Core Reformer',10,0,((current_date+21)+time '15:00') at time zone 'Europe/Prague',((current_date+21)+time '15:50') at time zone 'Europe/Prague','scheduled',false),
  ('c1a1c1a1-0000-0000-0000-000000f00001','c1a1c1a1-0000-0000-0000-000000000001','c1a1c1a1-0000-0000-0000-00000000000a','c1a1c1a1-0000-0000-0000-0000000cc0a1','c1a1c1a1-0000-0000-0000-0000000ee0a1',null,'Core Reformer',10,0,((current_date+22)+time '07:00') at time zone 'Europe/Prague',((current_date+22)+time '07:50') at time zone 'Europe/Prague','scheduled',true),
  ('c1a1c1a1-0000-0000-0000-000000f00002','c1a1c1a1-0000-0000-0000-000000000001','c1a1c1a1-0000-0000-0000-00000000000a','c1a1c1a1-0000-0000-0000-0000000cc0a1','c1a1c1a1-0000-0000-0000-0000000ee0a1',null,'Core Reformer',10,0,((current_date+22)+time '09:00') at time zone 'Europe/Prague',((current_date+22)+time '09:50') at time zone 'Europe/Prague','scheduled',true),
  ('c1a1c1a1-0000-0000-0000-000000270001','c1a1c1a1-0000-0000-0000-000000000001','c1a1c1a1-0000-0000-0000-00000000000a','c1a1c1a1-0000-0000-0000-0000000cc0a2','c1a1c1a1-0000-0000-0000-0000000ee0a1',null,'Second Type',10,0,((current_date+23)+time '07:00') at time zone 'Europe/Prague',((current_date+23)+time '07:50') at time zone 'Europe/Prague','scheduled',false);
-- Publish studio A's class month.
insert into schedule_publications (studio_id, month, published_at, auto) values
  ('c1a1c1a1-0000-0000-0000-000000000001', date_trunc('month',(current_date+21))::date, now(), false);

-- =============================================================================
-- 0. THE CLAIM LIST is filtered to what X can actually take (pristine open set,
--    read BEFORE any claim mutates staffing away from 'open').
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','c1a1c1a1-0000-0000-0000-0000000000d1',false);  -- X
select set_config('t.cl', instructor_claimable('c1a1c1a1-0000-0000-0000-0000000d00d1', date_trunc('month',(current_date+21))::date)::text, false);
select expect_true('X can claim (has availability for the month)', (current_setting('t.cl')::jsonb ->> 'can_claim')::boolean);
-- The Second Type class is in the list but marked not-qualified (labelled, not hidden).
select expect_false('the Second Type class X is not qualified for is flagged qualified=false',
  (select (c ->> 'qualified')::boolean from jsonb_array_elements(current_setting('t.cl')::jsonb -> 'classes') c
     where c ->> 'id' = 'c1a1c1a1-0000-0000-0000-000000270001'));
select expect_true('...while a Core Reformer class is qualified=true',
  (select (c ->> 'qualified')::boolean from jsonb_array_elements(current_setting('t.cl')::jsonb -> 'classes') c
     where c ->> 'id' = 'c1a1c1a1-0000-0000-0000-000000c00005'));
select expect_text('...each class carries its configured tier',
  (select c ->> 'tier' from jsonb_array_elements(current_setting('t.cl')::jsonb -> 'classes') c
     where c ->> 'id' = 'c1a1c1a1-0000-0000-0000-000000f00001'), 'flex');

-- THE HORIZON: instructors see the full occurrence horizon (further than members
-- book), one block per month. The month X has availability for is claimable with
-- its classes; a month X has NOT submitted is flagged no_availability, not blank.
select set_config('t.hz', instructor_claim_horizon('c1a1c1a1-0000-0000-0000-0000000d00d1')::text, false);
select expect_true('horizon: the month X has availability for is claimable',
  (select (m ->> 'can_claim')::boolean from jsonb_array_elements(current_setting('t.hz')::jsonb -> 'months') m
     where m ->> 'month' = to_char(date_trunc('month',(current_date+21)),'YYYY-MM')));
select expect_true('...and carries that month''s open classes',
  (select jsonb_array_length(m -> 'classes') > 0 from jsonb_array_elements(current_setting('t.hz')::jsonb -> 'months') m
     where m ->> 'month' = to_char(date_trunc('month',(current_date+21)),'YYYY-MM')));
select expect_true('horizon: a month with no availability is flagged (actionable), not blank',
  exists(select 1 from jsonb_array_elements(current_setting('t.hz')::jsonb -> 'months') m
          where m ->> 'reason' = 'no_availability'));

-- =============================================================================
-- 1. CORE CAP — cannot claim a 4th; pending counts; different caps
-- =============================================================================
select set_config('request.jwt.claim.sub','c1a1c1a1-0000-0000-0000-0000000000d1',false);  -- X (cap 3)
select expect_true('X claims core #1', (apply_for_shift('c1a1c1a1-0000-0000-0000-000000c00001')::jsonb ->> 'ok')::boolean);
select expect_true('X claims core #2', (apply_for_shift('c1a1c1a1-0000-0000-0000-000000c00002')::jsonb ->> 'ok')::boolean);
select expect_true('X claims core #3', (apply_for_shift('c1a1c1a1-0000-0000-0000-000000c00003')::jsonb ->> 'ok')::boolean);
-- All three are PENDING (nobody approved). The 4th must be refused BY THE PENDING
-- COUNT — proving pending claims count toward the cap.
select set_config('t.x4', apply_for_shift('c1a1c1a1-0000-0000-0000-000000c00004')::text, false);
select expect_false('X cannot claim a 4th core (3 pending already)', (current_setting('t.x4')::jsonb ->> 'ok')::boolean);
select expect_text('...refused for over_cap', current_setting('t.x4')::jsonb ->> 'reason', 'over_cap');
select expect_num('...at 3 of a cap of 3', (current_setting('t.x4')::jsonb ->> 'current')::bigint, 3);
select expect_num('...cap is 3 (the studio default)', (current_setting('t.x4')::jsonb ->> 'cap')::bigint, 3);

-- Y has cap 1: one core, then refused at her own smaller cap.
select set_config('request.jwt.claim.sub','c1a1c1a1-0000-0000-0000-0000000000d2',false);  -- Y (cap 1)
select expect_true('Y claims core #1', (apply_for_shift('c1a1c1a1-0000-0000-0000-000000c00004')::jsonb ->> 'ok')::boolean);
select set_config('t.y2', apply_for_shift('c1a1c1a1-0000-0000-0000-000000c00005')::text, false);
select expect_false('Y cannot claim a 2nd core — held to HER cap of 1', (current_setting('t.y2')::jsonb ->> 'ok')::boolean);
select expect_num('...Y''s cap is 1, not the studio default', (current_setting('t.y2')::jsonb ->> 'cap')::bigint, 1);

-- =============================================================================
-- 2. ASK ANYWAY — over-cap claim recorded and approvable by staff
-- =============================================================================
select set_config('request.jwt.claim.sub','c1a1c1a1-0000-0000-0000-0000000000d1',false);  -- X
select set_config('t.x4b', apply_for_shift('c1a1c1a1-0000-0000-0000-000000c00004', null, true)::text, false);  -- over_cap_ack
select expect_true('X asks anyway and the 4th is created', (current_setting('t.x4b')::jsonb ->> 'ok')::boolean);
select expect_true('...flagged over_cap', (current_setting('t.x4b')::jsonb ->> 'over_cap')::boolean);
reset role;
select expect_true('the over-cap application is on file, flagged',
  (select over_cap from shift_applications where occurrence_id='c1a1c1a1-0000-0000-0000-000000c00004'
     and instructor_id='c1a1c1a1-0000-0000-0000-0000000d00d1'));
-- Staff can approve past the cap.
set role authenticated;
select set_config('request.jwt.claim.sub','c1a1c1a1-0000-0000-0000-0000000000a1',false);  -- owner A
select expect_true('staff approve the over-cap claim',
  (select (approve_shift_application(id)::jsonb ->> 'approved') is not null
     from shift_applications where occurrence_id='c1a1c1a1-0000-0000-0000-000000c00004'
       and instructor_id='c1a1c1a1-0000-0000-0000-0000000d00d1' and status='pending'));
reset role;
select expect_text('...and the class is now assigned to X',
  (select instructor_id::text from class_occurrences where id='c1a1c1a1-0000-0000-0000-000000c00004'),
  'c1a1c1a1-0000-0000-0000-0000000d00d1');
select expect_text('...Y''s competing claim on it was auto-declined',
  (select status from shift_applications where occurrence_id='c1a1c1a1-0000-0000-0000-000000c00004'
     and instructor_id='c1a1c1a1-0000-0000-0000-0000000d00d2'), 'declined');
select expect_num('...and Y was notified of the decline',
  (select count(*) from notifications where template_key='shift_declined'
     and user_id='c1a1c1a1-0000-0000-0000-0000000000d2')::bigint, 1);

-- =============================================================================
-- 3. FLEX IS UNCAPPED
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','c1a1c1a1-0000-0000-0000-0000000000d1',false);  -- X (already 3 core + 1 approved-over)
select expect_true('X claims flex #1 despite being over the core cap',
  (apply_for_shift('c1a1c1a1-0000-0000-0000-000000f00001')::jsonb ->> 'ok')::boolean);
select expect_true('X claims flex #2 — flex has no limit',
  (apply_for_shift('c1a1c1a1-0000-0000-0000-000000f00002')::jsonb ->> 'ok')::boolean);

-- =============================================================================
-- 4. VALIDITY WINDOW — a hard gate, cannot claim at all
-- =============================================================================
select set_config('request.jwt.claim.sub','c1a1c1a1-0000-0000-0000-0000000000d3',false);  -- W (pattern ended)
select set_config('t.w', apply_for_shift('c1a1c1a1-0000-0000-0000-000000c00005')::text, false);
select expect_false('W cannot claim — the class is outside her validity window', (current_setting('t.w')::jsonb ->> 'ok')::boolean);
select expect_text('...refused outside_validity', current_setting('t.w')::jsonb ->> 'reason', 'outside_validity');

-- =============================================================================
-- 5. AN INSTRUCTOR WITH NO MONTH AVAILABILITY is told why, not shown a list
-- =============================================================================
select set_config('request.jwt.claim.sub','c1a1c1a1-0000-0000-0000-0000000000d3',false);  -- W
-- give W no availability for THIS month so can_claim_month is false
reset role;
delete from availability_submissions where instructor_id='c1a1c1a1-0000-0000-0000-0000000d00d3';
delete from instructor_availability where instructor_id='c1a1c1a1-0000-0000-0000-0000000d00d3';
set role authenticated;
select set_config('request.jwt.claim.sub','c1a1c1a1-0000-0000-0000-0000000000d3',false);
select set_config('t.wl', instructor_claimable('c1a1c1a1-0000-0000-0000-0000000d00d3', date_trunc('month',(current_date+21))::date)::text, false);
select expect_false('W with no availability for the month cannot claim', (current_setting('t.wl')::jsonb ->> 'can_claim')::boolean);
select expect_text('...and is told why', current_setting('t.wl')::jsonb ->> 'reason', 'no_availability');
reset role;

-- =============================================================================
-- 6. THE CAP IS PER STUDIO WEEK IN LOCAL TIME (Sunday-start proves it)
-- =============================================================================
-- Studio S starts weeks on SUNDAY. Two core classes: one on a Sunday and one on
-- the Saturday six days later are the SAME studio week; a Monday-based count
-- (date_trunc('week')) would split them. instructor_week_claim_load must count 2.
-- Find the next Sunday on/after current_date+14.
insert into instructors (id, studio_id, display_name, staff_id) values
  ('c1a1c1a1-0000-0000-0000-0000000d0051','c1a1c1a1-0000-0000-0000-000000000002','Sam Sun', null);
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, booked_count, starts_at, ends_at, status)
select 'c1a1c1a1-0000-0000-0000-000000050001','c1a1c1a1-0000-0000-0000-000000000002','c1a1c1a1-0000-0000-0000-000000000005','c1a1c1a1-0000-0000-0000-0000000cc051','c1a1c1a1-0000-0000-0000-0000000ee051','c1a1c1a1-0000-0000-0000-0000000d0051','Core Reformer',10,0,
  (v_sun + time '09:00') at time zone 'Europe/Prague', (v_sun + time '09:50') at time zone 'Europe/Prague','scheduled'
from (select (current_date+14) + ((7 - extract(dow from (current_date+14))::int) % 7) as v_sun) q;
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, booked_count, starts_at, ends_at, status)
select 'c1a1c1a1-0000-0000-0000-000000050002','c1a1c1a1-0000-0000-0000-000000000002','c1a1c1a1-0000-0000-0000-000000000005','c1a1c1a1-0000-0000-0000-0000000cc051','c1a1c1a1-0000-0000-0000-0000000ee051','c1a1c1a1-0000-0000-0000-0000000d0051','Core Reformer',10,0,
  ((v_sun+6) + time '09:00') at time zone 'Europe/Prague', ((v_sun+6) + time '09:50') at time zone 'Europe/Prague','scheduled'
from (select (current_date+14) + ((7 - extract(dow from (current_date+14))::int) % 7) as v_sun) q;
-- The following Sunday (v_sun+7) is a DIFFERENT week — the control.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, booked_count, starts_at, ends_at, status)
select 'c1a1c1a1-0000-0000-0000-000000050003','c1a1c1a1-0000-0000-0000-000000000002','c1a1c1a1-0000-0000-0000-000000000005','c1a1c1a1-0000-0000-0000-0000000cc051','c1a1c1a1-0000-0000-0000-0000000ee051','c1a1c1a1-0000-0000-0000-0000000d0051','Core Reformer',10,0,
  ((v_sun+7) + time '09:00') at time zone 'Europe/Prague', ((v_sun+7) + time '09:50') at time zone 'Europe/Prague','scheduled'
from (select (current_date+14) + ((7 - extract(dow from (current_date+14))::int) % 7) as v_sun) q;

select expect_num('Sunday + the Saturday six days later are ONE studio week (count 2)',
  (instructor_week_claim_load('c1a1c1a1-0000-0000-0000-0000000d0051',
     (select starts_at from class_occurrences where id='c1a1c1a1-0000-0000-0000-000000050001')) ->> 'core')::bigint, 2);

-- =============================================================================
-- 7. A CLAIMING-OFF STUDIO is unchanged — no cap, the assigned-model cover apply
-- =============================================================================
-- Studio B: an open cover shift, claiming off. apply_for_shift behaves as today
-- (no cap gate, no validity/publication gate).
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, booked_count, starts_at, ends_at, status, staffing) values
  ('c1a1c1a1-0000-0000-0000-000000b00001','c1a1c1a1-0000-0000-0000-000000000003','c1a1c1a1-0000-0000-0000-00000000000b','c1a1c1a1-0000-0000-0000-0000000cc0b1','c1a1c1a1-0000-0000-0000-0000000ee0b1',null,'Core Reformer',10,0,((current_date+3)+time '07:00') at time zone 'Europe/Prague',((current_date+3)+time '07:50') at time zone 'Europe/Prague','scheduled','open');
select expect_false('a claiming-OFF studio has no claiming switch on', claiming_enabled('c1a1c1a1-0000-0000-0000-000000000003'));
set role authenticated;
select set_config('request.jwt.claim.sub','c1a1c1a1-0000-0000-0000-0000000000e1',false);  -- instructor at B
select expect_true('at a claiming-off studio the cover apply still works (no cap, no gates)',
  (apply_for_shift('c1a1c1a1-0000-0000-0000-000000b00001')::jsonb ->> 'ok')::boolean);
reset role;

select 'claiming_test: all assertions passed' as done;
