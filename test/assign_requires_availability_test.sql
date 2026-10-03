-- =============================================================================
-- Decision 46 — "no stated availability means not available" (per-studio switch),
-- end dates under it, and the published-month availability lock.
-- =============================================================================
-- UUID space 46a1, checked free. Run after `supabase db reset`.
--
-- SA (Prague) carries the switch and the instructors; SB proves the cycle reader
-- does not cross studios. The switch defaults OFF; turning it ON makes
-- instructor_available_at_run answer false for an instructor with nothing on
-- file, so the AUTOMATIC engine leaves a class open — while the MANUAL Schedule
-- assign still places them with a warning (Decision 9, untouched).
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'BAD  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual then raise notice 'PASS  %', label;
  else raise exception 'BAD  %  expected true, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_txt(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (%)', label, coalesce(actual,'null');
  else raise exception 'BAD  %  expected "%", got "%"', label, want, coalesce(actual,'null'); end if;
end $$;
create or replace function expect_raises(label text, stmt text, want_sqlstate text)
returns void language plpgsql as $$
begin
  execute stmt; raise exception 'BAD  %  expected % but nothing was raised', label, want_sqlstate;
exception when others then
  if sqlstate = want_sqlstate then raise notice 'PASS  %  (got %)', label, sqlstate;
  elsif sqlstate = 'P0001' and sqlerrm like 'BAD%' then raise;
  else raise exception 'BAD  %  expected %, got % (%)', label, want_sqlstate, sqlstate, sqlerrm; end if;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into studios (id, name, slug, timezone, currency, status) values
  ('46a146a1-0000-0000-0000-0000000000a1','Avail A','46a1-sa','Europe/Prague','CZK','active'),
  ('46a146a1-0000-0000-0000-0000000000b1','Avail B','46a1-sb','Europe/Prague','CZK','active');
insert into studio_settings (studio_id, require_waiver) values
  ('46a146a1-0000-0000-0000-0000000000a1', false),
  ('46a146a1-0000-0000-0000-0000000000b1', false);
insert into locations (id, studio_id, name, is_primary) values
  ('46a146a1-0000-0000-0000-0000000000aa','46a146a1-0000-0000-0000-0000000000a1','Main',true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('46a146a1-0000-0000-0000-00000000aa01','46a146a1-0000-0000-0000-0000000000a1','46a146a1-0000-0000-0000-0000000000aa','RA',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('46a146a1-0000-0000-0000-0000000c7a01','46a146a1-0000-0000-0000-0000000000a1','Reformer',50,10);

-- Owner (manager), an instructor login for P1, an SB owner for the cross-studio guard.
insert into auth.users (id) values
  ('46a146a1-0000-0000-0000-0000000000f1'),
  ('46a146a1-0000-0000-0000-0000000000f2'),
  ('46a146a1-0000-0000-0000-0000000000f3');
insert into profiles (id, email) values
  ('46a146a1-0000-0000-0000-0000000000f1','46a1-owner@example.com'),
  ('46a146a1-0000-0000-0000-0000000000f2','46a1-inst@example.com'),
  ('46a146a1-0000-0000-0000-0000000000f3','46a1-sbowner@example.com');
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('46a146a1-0000-0000-0000-00000005f001','46a146a1-0000-0000-0000-0000000000a1','46a146a1-0000-0000-0000-0000000000f1','46a1-owner@example.com','owner'),
  ('46a146a1-0000-0000-0000-00000005f002','46a146a1-0000-0000-0000-0000000000a1','46a146a1-0000-0000-0000-0000000000f2','46a1-inst@example.com','instructor'),
  ('46a146a1-0000-0000-0000-00000005f003','46a146a1-0000-0000-0000-0000000000b1','46a146a1-0000-0000-0000-0000000000f3','46a1-sbowner@example.com','owner');

-- P1 has a login and NO availability; P2/P3 are for the predicate ranges.
insert into instructors (id, studio_id, staff_id, display_name) values
  ('46a146a1-0000-0000-0000-00000000d101','46a146a1-0000-0000-0000-0000000000a1','46a146a1-0000-0000-0000-00000005f002','Pat One'),
  ('46a146a1-0000-0000-0000-00000000d102','46a146a1-0000-0000-0000-0000000000a1',null,'Pat Two'),
  ('46a146a1-0000-0000-0000-00000000d103','46a146a1-0000-0000-0000-0000000000a1',null,'Pat Three');
insert into instructor_class_types (studio_id, instructor_id, class_type_id) values
  ('46a146a1-0000-0000-0000-0000000000a1','46a146a1-0000-0000-0000-00000000d101','46a146a1-0000-0000-0000-0000000c7a01');

-- Instants: a Monday ~2 weeks out (so this/next month, always future), plus
-- slots inside and outside a Monday 07:00–12:00 pattern, and a Monday 4 weeks on.
select set_config('t.mon', (date_trunc('week', (now() at time zone 'Europe/Prague')::date + 14))::date::text, false);
select set_config('t.in_s',   ((current_setting('t.mon')::date + time '08:00') at time zone 'Europe/Prague')::text, false);
select set_config('t.in_e',   ((current_setting('t.mon')::date + time '08:50') at time zone 'Europe/Prague')::text, false);
select set_config('t.late_s', ((current_setting('t.mon')::date + time '13:00') at time zone 'Europe/Prague')::text, false);
select set_config('t.late_e', ((current_setting('t.mon')::date + time '13:50') at time zone 'Europe/Prague')::text, false);
select set_config('t.tue_s',  ((current_setting('t.mon')::date + 1 + time '08:00') at time zone 'Europe/Prague')::text, false);
select set_config('t.tue_e',  ((current_setting('t.mon')::date + 1 + time '08:50') at time zone 'Europe/Prague')::text, false);
select set_config('t.fmon_s', ((current_setting('t.mon')::date + 28 + time '08:00') at time zone 'Europe/Prague')::text, false);
select set_config('t.fmon_e', ((current_setting('t.mon')::date + 28 + time '08:50') at time zone 'Europe/Prague')::text, false);

-- P2: an APPROVED submission for the Monday's month, Monday 07:00–12:00.
insert into availability_submissions (id, studio_id, instructor_id, period_start, status, submitted_at, reviewed_at)
values ('46a146a1-0000-0000-0000-00000000b201','46a146a1-0000-0000-0000-0000000000a1','46a146a1-0000-0000-0000-00000000d102',
        date_trunc('month', current_setting('t.mon')::date)::date, 'approved', now(), now());
insert into instructor_availability (studio_id, instructor_id, day_of_week, starts_at_time, ends_at_time, is_available, submission_id, approval_status)
values ('46a146a1-0000-0000-0000-0000000000a1','46a146a1-0000-0000-0000-00000000d102',1,'07:00','12:00',true,'46a146a1-0000-0000-0000-00000000b201','approved');

-- P3: a STANDING pattern Monday 07:00–12:00, effective only through mon+7.
insert into instructor_availability (studio_id, instructor_id, day_of_week, starts_at_time, ends_at_time, is_available, effective_from, effective_to, approval_status)
values ('46a146a1-0000-0000-0000-0000000000a1','46a146a1-0000-0000-0000-00000000d103',1,'07:00','12:00',true,
        current_setting('t.mon')::date - 30, current_setting('t.mon')::date + 7, 'approved');

-- One OPEN occurrence on the Monday for the engine test.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name, capacity, booked_count, starts_at, ends_at, status)
values ('46a146a1-0000-0000-0000-00000000cc01','46a146a1-0000-0000-0000-0000000000a1','46a146a1-0000-0000-0000-0000000000aa',
        '46a146a1-0000-0000-0000-0000000c7a01','46a146a1-0000-0000-0000-00000000aa01','Reformer',10,0,
        (current_setting('t.mon')::date + time '09:00') at time zone 'Europe/Prague',
        (current_setting('t.mon')::date + time '09:50') at time zone 'Europe/Prague','scheduled');

-- =============================================================================
-- A. instructor_available_at_run — the switch, submissions, standing patterns.
-- =============================================================================
-- Switch OFF (default): an instructor with nothing on file is available.
select expect_true('OFF: no rows → available (today''s behaviour)',
  instructor_available_at_run('46a146a1-0000-0000-0000-00000000d101', current_setting('t.in_s')::timestamptz, current_setting('t.in_e')::timestamptz));

update studio_settings set assign_requires_availability = true where studio_id = '46a146a1-0000-0000-0000-0000000000a1';

-- Switch ON: no rows → NOT available.
select expect_true('ON: no rows → not available',
  instructor_available_at_run('46a146a1-0000-0000-0000-00000000d101', current_setting('t.in_s')::timestamptz, current_setting('t.in_e')::timestamptz) = false);
-- ON + approved submission covering Monday 07:00–12:00: true inside, false outside.
select expect_true('ON: approved submission, Monday 08:00 inside → available',
  instructor_available_at_run('46a146a1-0000-0000-0000-00000000d102', current_setting('t.in_s')::timestamptz, current_setting('t.in_e')::timestamptz));
select expect_true('ON: approved submission, Monday 13:00 outside range → not available',
  instructor_available_at_run('46a146a1-0000-0000-0000-00000000d102', current_setting('t.late_s')::timestamptz, current_setting('t.late_e')::timestamptz) = false);
select expect_true('ON: approved submission, Tuesday → not available',
  instructor_available_at_run('46a146a1-0000-0000-0000-00000000d102', current_setting('t.tue_s')::timestamptz, current_setting('t.tue_e')::timestamptz) = false);
-- ON + standing pattern: covered Monday → true; a Monday after effective_to → false.
select expect_true('ON: standing pattern, covered Monday → available',
  instructor_available_at_run('46a146a1-0000-0000-0000-00000000d103', current_setting('t.in_s')::timestamptz, current_setting('t.in_e')::timestamptz));
select expect_true('ON: standing pattern past effective_to → not available',
  instructor_available_at_run('46a146a1-0000-0000-0000-00000000d103', current_setting('t.fmon_s')::timestamptz, current_setting('t.fmon_e')::timestamptz) = false);

-- =============================================================================
-- B. The automatic engine leaves a class open; the manual path assigns + warns.
-- =============================================================================
-- Switch ON: assign_instructors_run leaves OCC open (P1, the only qualified
-- instructor, has no availability).
select assign_instructors_run('46a146a1-0000-0000-0000-0000000000a1');
select expect_true('ON: engine leaves the class open (only candidate has no availability)',
  (select instructor_id is null and staffing = 'open' from class_occurrences where id = '46a146a1-0000-0000-0000-00000000cc01'));

-- RED proof: switch OFF, re-run → the same fixture assigns P1.
update studio_settings set assign_requires_availability = false where studio_id = '46a146a1-0000-0000-0000-0000000000a1';
select assign_instructors_run('46a146a1-0000-0000-0000-0000000000a1');
select expect_true('OFF: engine assigns P1 (no rows → available)',
  (select instructor_id = '46a146a1-0000-0000-0000-00000000d101' from class_occurrences where id = '46a146a1-0000-0000-0000-00000000cc01'));

-- Reset OCC to open, switch ON, and the MANUAL Schedule assign still places P1
-- WITH the outside_availability warning — Decision 9, untouched.
update class_occurrences set instructor_id = null where id = '46a146a1-0000-0000-0000-00000000cc01';
update studio_settings set assign_requires_availability = true where studio_id = '46a146a1-0000-0000-0000-0000000000a1';
set role authenticated;
select set_config('request.jwt.claim.sub','46a146a1-0000-0000-0000-0000000000f1',false);
select set_config('t.manual', assign_occurrences_for_period(
  '46a146a1-0000-0000-0000-00000000cc01','46a146a1-0000-0000-0000-00000000d101','one',null,true)::text, false);
reset role;
select expect_true('ON: manual assign still places P1 (Decision 9 — warn, not block)',
  (select instructor_id = '46a146a1-0000-0000-0000-00000000d101' from class_occurrences where id = '46a146a1-0000-0000-0000-00000000cc01'));
select expect_true('ON: manual assign returns the outside_availability warning',
  (current_setting('t.manual')::jsonb -> 'warnings') ? 'outside_availability');

-- =============================================================================
-- C. set_instructor_availability_rows — end date required under the switch.
-- =============================================================================
-- ON + open-ended standing pattern → PT400 with the exact sentence.
select expect_raises('ON: open-ended standing pattern refused PT400',
  $$ select set_instructor_availability_rows('46a146a1-0000-0000-0000-00000000d101',
       '[{"day":2,"ranges":[{"from":"07:00","to":"12:00"}]}]'::jsonb, current_date, null) $$, 'PT400');
-- ON + dated → accepted.
select expect_num('ON: dated standing pattern accepted',
  (select set_instructor_availability_rows('46a146a1-0000-0000-0000-00000000d101',
     '[{"day":2,"ranges":[{"from":"07:00","to":"12:00"}]}]'::jsonb, current_date, current_date + 60))::bigint, 1);
-- OFF + open-ended → accepted (today's behaviour byte-for-byte).
update studio_settings set assign_requires_availability = false where studio_id = '46a146a1-0000-0000-0000-0000000000a1';
select expect_num('OFF: open-ended standing pattern accepted',
  (select set_instructor_availability_rows('46a146a1-0000-0000-0000-00000000d101',
     '[{"day":3,"ranges":[{"from":"07:00","to":"12:00"}]}]'::jsonb, current_date, null))::bigint, 1);
update studio_settings set assign_requires_availability = true where studio_id = '46a146a1-0000-0000-0000-0000000000a1';

-- =============================================================================
-- D. submit_availability — a published month is locked to the instructor.
-- =============================================================================
-- Turn publication ON for SA and publish a future month; the instructor is
-- locked out of it, an unpublished month is fine, and the manager may still set it.
update studio_settings set publication_enabled = true where studio_id = '46a146a1-0000-0000-0000-0000000000a1';
select set_config('t.pubmonth', (date_trunc('month', (now() at time zone 'Europe/Prague')::date) + interval '1 month')::date::text, false);
select set_config('t.freemonth', (date_trunc('month', (now() at time zone 'Europe/Prague')::date) + interval '2 months')::date::text, false);
insert into schedule_publications (studio_id, month, published_by)
values ('46a146a1-0000-0000-0000-0000000000a1', current_setting('t.pubmonth')::date, '46a146a1-0000-0000-0000-0000000000f1');

-- As the instructor (P1 has the login f2): the published month is refused PT409.
set role authenticated;
select set_config('request.jwt.claim.sub','46a146a1-0000-0000-0000-0000000000f2',false);
select expect_raises('instructor: published month refused PT409',
  $$ select submit_availability('46a146a1-0000-0000-0000-00000000d101', current_setting('t.pubmonth')::date,
       '[{"day":1,"ranges":[{"from":"07:00","to":"12:00"}]}]'::jsonb, true) $$, 'PT409');
-- An unpublished month submits.
select expect_txt('instructor: unpublished month submits',
  (select submit_availability('46a146a1-0000-0000-0000-00000000d101', current_setting('t.freemonth')::date,
     '[{"day":1,"ranges":[{"from":"07:00","to":"12:00"}]}]'::jsonb, true) ->> 'status'), 'submitted');
reset role;
-- The manager may set the published month for them (manager path unchanged).
set role authenticated;
select set_config('request.jwt.claim.sub','46a146a1-0000-0000-0000-0000000000f1',false);
select expect_txt('manager: published month allowed → approved',
  (select submit_availability('46a146a1-0000-0000-0000-00000000d101', current_setting('t.pubmonth')::date,
     '[{"day":1,"ranges":[{"from":"07:00","to":"12:00"}]}]'::jsonb, true) ->> 'status'), 'approved');
reset role;

-- =============================================================================
-- E. The cycle-state reader — availability_cycle gives per-instructor state.
-- =============================================================================
-- Set up the collected month (next month, which availability_cycle defaults to)
-- with one submitted, one approved, one sent-back, one nothing.
select set_config('t.cyc', (date_trunc('month', (now() at time zone 'Europe/Prague')::date) + interval '1 month')::date::text, false);
delete from availability_submissions where studio_id = '46a146a1-0000-0000-0000-0000000000a1' and period_start = current_setting('t.cyc')::date;
insert into availability_submissions (studio_id, instructor_id, period_start, status) values
  ('46a146a1-0000-0000-0000-0000000000a1','46a146a1-0000-0000-0000-00000000d101', current_setting('t.cyc')::date, 'submitted'),
  ('46a146a1-0000-0000-0000-0000000000a1','46a146a1-0000-0000-0000-00000000d102', current_setting('t.cyc')::date, 'approved'),
  ('46a146a1-0000-0000-0000-0000000000a1','46a146a1-0000-0000-0000-00000000d103', current_setting('t.cyc')::date, 'changes_requested');

set role authenticated;
select set_config('request.jwt.claim.sub','46a146a1-0000-0000-0000-0000000000f1',false);
select set_config('t.cycle', availability_cycle('46a146a1-0000-0000-0000-0000000000a1', current_setting('t.cyc')::date)::text, false);
reset role;
select expect_txt('cycle: P1 submitted',
  (select e ->> 'status' from jsonb_array_elements((current_setting('t.cycle')::jsonb) -> 'instructors') e
    where e ->> 'instructor_id' = '46a146a1-0000-0000-0000-00000000d101'), 'submitted');
select expect_txt('cycle: P2 approved',
  (select e ->> 'status' from jsonb_array_elements((current_setting('t.cycle')::jsonb) -> 'instructors') e
    where e ->> 'instructor_id' = '46a146a1-0000-0000-0000-00000000d102'), 'approved');
select expect_txt('cycle: P3 sent back (changes_requested)',
  (select e ->> 'status' from jsonb_array_elements((current_setting('t.cycle')::jsonb) -> 'instructors') e
    where e ->> 'instructor_id' = '46a146a1-0000-0000-0000-00000000d103'), 'changes_requested');

-- Guard: an instructor cannot read it, and a cross-studio owner cannot either.
set role authenticated;
select set_config('request.jwt.claim.sub','46a146a1-0000-0000-0000-0000000000f2',false);
select expect_raises('cycle: instructor PT403',
  $$ select availability_cycle('46a146a1-0000-0000-0000-0000000000a1', current_setting('t.cyc')::date) $$, 'PT403');
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub','46a146a1-0000-0000-0000-0000000000f3',false);
select expect_raises('cycle: cross-studio owner PT403',
  $$ select availability_cycle('46a146a1-0000-0000-0000-0000000000a1', current_setting('t.cyc')::date) $$, 'PT403');
reset role;

select 'assign_requires_availability_test: all assertions passed' as result;
