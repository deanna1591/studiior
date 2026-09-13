-- =============================================================================
-- Instructor check-in for pay — Decision 28, migration 135
-- =============================================================================
-- UUID space 9a4d, checked free. Run after `supabase db reset`.
--
-- A class that ran writes its pay record HELD; the instructor checks in within
-- the window and it confirms; outside the window is refused; a held record is
-- computed, visible and not payable; a manager releases one with a reason and it
-- audits; closing a period with a held record is refused; a not-running class is
-- auto-confirmed and needs no check-in; an instructor cannot confirm another's
-- class. Two studios in one run.
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
begin if actual then raise notice 'PASS  %', label; else raise exception 'FAIL  %  expected true', label; end if; end $$;
create or replace function as_state(uid text, sql text) returns text language plpgsql as $$
declare r text;
begin
  perform set_config('request.jwt.claim.sub', uid, true); set local role authenticated;
  begin execute sql into r; return coalesce(r,'null'); exception when others then return 'ERR:'||sqlstate; end;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('9a4d9a4d-0000-0000-0000-0000000000a1'),  -- owner/manager (A + B)
  ('9a4d9a4d-0000-0000-0000-0000000000d1'),  -- instructor A login
  ('9a4d9a4d-0000-0000-0000-0000000000d2');  -- instructor B login
insert into profiles (id, email) select id, id::text||'@example.com' from auth.users where id::text like '9a4d9a4d%';

insert into studios (id, name, slug, timezone, currency, status) values
  ('9a4d9a4d-0000-0000-0000-000000000001','Pay A','9a4d-a','UTC','USD','active'),
  ('9a4d9a4d-0000-0000-0000-000000000002','Pay B','9a4d-b','UTC','USD','active');
insert into studio_settings (studio_id, guarantees_enabled) values
  ('9a4d9a4d-0000-0000-0000-000000000001', true),
  ('9a4d9a4d-0000-0000-0000-000000000002', true);
insert into locations (id, studio_id, name, is_primary) values
  ('9a4d9a4d-0000-0000-0000-00000000000a','9a4d9a4d-0000-0000-0000-000000000001','Main',true),
  ('9a4d9a4d-0000-0000-0000-00000000000b','9a4d9a4d-0000-0000-0000-000000000002','Main',true);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('9a4d9a4d-0000-0000-0000-0000000aa001','9a4d9a4d-0000-0000-0000-000000000001','9a4d9a4d-0000-0000-0000-0000000000a1','9a4d-owa@example.com','owner'),
  ('9a4d9a4d-0000-0000-0000-0000000aa0d1','9a4d9a4d-0000-0000-0000-000000000001','9a4d9a4d-0000-0000-0000-0000000000d1','9a4d-ia@example.com','instructor'),
  ('9a4d9a4d-0000-0000-0000-0000000aa0d2','9a4d9a4d-0000-0000-0000-000000000002','9a4d9a4d-0000-0000-0000-0000000000d2','9a4d-ib@example.com','instructor');
insert into instructors (id, studio_id, staff_id, display_name, status) values
  ('9a4d9a4d-0000-0000-0000-0000000d0001','9a4d9a4d-0000-0000-0000-000000000001','9a4d9a4d-0000-0000-0000-0000000aa0d1','Ins A','active'),
  ('9a4d9a4d-0000-0000-0000-0000000d0002','9a4d9a4d-0000-0000-0000-000000000002','9a4d9a4d-0000-0000-0000-0000000aa0d2','Ins B','active');
insert into instructor_rate_versions (studio_id, instructor_id, effective_from, currency, base_rate_cents) values
  ('9a4d9a4d-0000-0000-0000-000000000001','9a4d9a4d-0000-0000-0000-0000000d0001', current_date - 30, 'USD', 5000),
  ('9a4d9a4d-0000-0000-0000-000000000002','9a4d9a4d-0000-0000-0000-0000000d0002', current_date - 30, 'USD', 6000);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('9a4d9a4d-0000-0000-0000-0000000cc001','9a4d9a4d-0000-0000-0000-000000000001','Reformer',50,8),
  ('9a4d9a4d-0000-0000-0000-0000000cc002','9a4d9a4d-0000-0000-0000-000000000002','Reformer',50,8);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('9a4d9a4d-0000-0000-0000-0000000ee001','9a4d9a4d-0000-0000-0000-000000000001','9a4d9a4d-0000-0000-0000-00000000000a','R1',8),
  ('9a4d9a4d-0000-0000-0000-0000000ee002','9a4d9a4d-0000-0000-0000-000000000001','9a4d9a4d-0000-0000-0000-00000000000a','R2',8),
  ('9a4d9a4d-0000-0000-0000-0000000ee003','9a4d9a4d-0000-0000-0000-000000000001','9a4d9a4d-0000-0000-0000-00000000000a','R3',8),
  ('9a4d9a4d-0000-0000-0000-0000000ee00b','9a4d9a4d-0000-0000-0000-000000000002','9a4d9a4d-0000-0000-0000-00000000000b','R1',8);

-- Occurrences. RAN_NOW is in progress (window open). RAN_OLD finished >30min ago
-- (window closed). NOTRUN is cancelled/unmet_minimum. B_RAN for studio B.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name,
       starts_at, ends_at, capacity, booked_count, booked_at_cutoff, status) values
  ('9a4d9a4d-0000-0000-0000-00000000c001','9a4d9a4d-0000-0000-0000-000000000001','9a4d9a4d-0000-0000-0000-00000000000a','9a4d9a4d-0000-0000-0000-0000000cc001','9a4d9a4d-0000-0000-0000-0000000ee001','9a4d9a4d-0000-0000-0000-0000000d0001','Ran Now', now()-interval '10 min', now()+interval '40 min',8,3,3,'scheduled'),
  ('9a4d9a4d-0000-0000-0000-00000000c002','9a4d9a4d-0000-0000-0000-000000000001','9a4d9a4d-0000-0000-0000-00000000000a','9a4d9a4d-0000-0000-0000-0000000cc001','9a4d9a4d-0000-0000-0000-0000000ee002','9a4d9a4d-0000-0000-0000-0000000d0001','Ran Old', now()-interval '3 h', now()-interval '130 min',8,4,4,'scheduled'),
  ('9a4d9a4d-0000-0000-0000-00000000c003','9a4d9a4d-0000-0000-0000-000000000001','9a4d9a4d-0000-0000-0000-00000000000a','9a4d9a4d-0000-0000-0000-0000000cc001','9a4d9a4d-0000-0000-0000-0000000ee003','9a4d9a4d-0000-0000-0000-0000000d0001','Not Run', now()+interval '3 h', now()+interval '230 min',8,0,0,'scheduled'),
  ('9a4d9a4d-0000-0000-0000-00000000c00b','9a4d9a4d-0000-0000-0000-000000000002','9a4d9a4d-0000-0000-0000-00000000000b','9a4d9a4d-0000-0000-0000-0000000cc002','9a4d9a4d-0000-0000-0000-0000000ee00b','9a4d9a4d-0000-0000-0000-0000000d0002','B Ran', now()-interval '10 min', now()+interval '40 min',8,2,2,'scheduled');

-- Commit the three that ran -> the trigger writes a HELD pay record for each.
update class_occurrences set committed_at = now() where id in
  ('9a4d9a4d-0000-0000-0000-00000000c001','9a4d9a4d-0000-0000-0000-00000000c002','9a4d9a4d-0000-0000-0000-00000000c00b');
-- Cancel the not-running one (unmet_minimum) -> auto-confirmed pay record.
update class_occurrences set status='cancelled', cancellation_cause='unmet_minimum' where id='9a4d9a4d-0000-0000-0000-00000000c003';

-- =============================================================================
-- Held on write; not-running auto-confirmed.
-- =============================================================================
select expect_num('a class that ran is written HELD (confirmed_at null)',
  (select count(*) from instructor_pay_records where occurrence_id='9a4d9a4d-0000-0000-0000-00000000c001' and confirmed_at is null), 1);
select expect_true('a not-running class is auto-confirmed, method auto',
  (select confirmed_at is not null and confirm_method='auto' from instructor_pay_records where occurrence_id='9a4d9a4d-0000-0000-0000-00000000c003'));

-- The held record is computed and visible (statement) but not payable.
select expect_num('the held record has its Decision 22 amount',
  (select amount_cents from instructor_pay_records where occurrence_id='9a4d9a4d-0000-0000-0000-00000000c001'), 5000);

-- =============================================================================
-- 7. An instructor cannot confirm someone else's class (B's instructor on A's class).
-- =============================================================================
select expect_true('an instructor cannot confirm another''s class',
  as_state('9a4d9a4d-0000-0000-0000-0000000000d2',
    $$ select instructor_confirm_class('9a4d9a4d-0000-0000-0000-00000000c001')::text $$) = 'ERR:PT403');
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- 2. Outside the window is refused.
-- =============================================================================
select expect_true('checking in after the window has closed is refused',
  as_state('9a4d9a4d-0000-0000-0000-0000000000d1',
    $$ select instructor_confirm_class('9a4d9a4d-0000-0000-0000-00000000c002')::text $$) = 'ERR:PT422');
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- 1. In the window, the instructor confirms and the record becomes payable.
-- =============================================================================
select expect_true('the instructor checks in within the window',
  (as_state('9a4d9a4d-0000-0000-0000-0000000000d1',
    $$ select instructor_confirm_class('9a4d9a4d-0000-0000-0000-00000000c001')::text $$)::jsonb ->> 'ok')::boolean);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_true('the record is now confirmed (method self, payable)',
  (select confirmed_at is not null and confirm_method='self' from instructor_pay_records where occurrence_id='9a4d9a4d-0000-0000-0000-00000000c001'));

-- =============================================================================
-- 5. Closing a period with a held record is refused, naming the count.
--    (Ran Old on studio A is still held.)
-- =============================================================================
select expect_true('closing a period with a held record is refused',
  as_state('9a4d9a4d-0000-0000-0000-0000000000a1',
    $$ select close_pay_period((select period_id from instructor_pay_records where occurrence_id='9a4d9a4d-0000-0000-0000-00000000c002'))::text $$) = 'ERR:PT409');
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- 4. A manager releases the held record with a reason; it audits.
-- =============================================================================
select expect_true('a manager releases the held record with a reason',
  (as_state('9a4d9a4d-0000-0000-0000-0000000000a1',
    $$ select confirm_class_for_pay('9a4d9a4d-0000-0000-0000-00000000c002','taught it, forgot to tap')::text $$)::jsonb ->> 'ok')::boolean);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_true('the release is method manager with the note',
  (select confirm_method='manager' and confirm_note='taught it, forgot to tap' from instructor_pay_records where occurrence_id='9a4d9a4d-0000-0000-0000-00000000c002'));
select expect_num('the release is audited',
  (select count(*) from audit_logs where action='pay_record.released' and studio_id='9a4d9a4d-0000-0000-0000-000000000001'), 1);

-- now the period has no held records -> close succeeds
select expect_true('with everything confirmed the period closes',
  (as_state('9a4d9a4d-0000-0000-0000-0000000000a1',
    $$ select close_pay_period((select period_id from instructor_pay_records where occurrence_id='9a4d9a4d-0000-0000-0000-00000000c002'))::text $$)::jsonb ->> 'ok')::boolean);
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- statement split + outstanding count + two studios.
-- =============================================================================
-- B still has a held record; A has none now.
select expect_num('studio A has no unconfirmed pay',
  studio_unconfirmed_pay_count('9a4d9a4d-0000-0000-0000-000000000001'), 0);
select expect_num('studio B has one unconfirmed pay (independent)',
  studio_unconfirmed_pay_count('9a4d9a4d-0000-0000-0000-000000000002'), 1);
-- statement held_cents for B's instructor
select expect_num('B statement shows the held amount separately',
  ((as_state('9a4d9a4d-0000-0000-0000-0000000000d2',
    $$ select pay_statement('9a4d9a4d-0000-0000-0000-0000000d0002', (select period_id from instructor_pay_records where occurrence_id='9a4d9a4d-0000-0000-0000-00000000c00b'))::text $$))::jsonb ->> 'held_cents')::bigint, 6000);
select set_config('request.jwt.claim.sub','',false); reset role;

do $$ begin raise notice 'instructor_checkin_test: all assertions passed'; end $$;
