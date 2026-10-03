-- =============================================================================
-- Decision 54 item 4 — the Fill tool's "already confirmed" tick.
-- =============================================================================
-- UUID space c054, checked free. Run after `supabase db reset`.
--
-- assign_instructors gains p_confirmed (default false). When true it stamps
-- assignment_confirmed_by and cancels the Decision 38 ask for each class the
-- engine assigned (the same bypass as the Schedule Assign panel); when false
-- the per-instructor coalesced ask is queued. A studio with
-- assignment_confirmations ON and a LOGIN instructor is the only place this is
-- observable.
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

-- --- Fixtures: one Prague studio, assignment_confirmations ON ----------------
insert into studios (id, name, slug, timezone, currency, status) values
  ('c054c054-0000-0000-0000-000000000001','Fill Confirm','c054-fc','Europe/Prague','CZK','active');
insert into studio_settings (studio_id, assignment_confirmations) values
  ('c054c054-0000-0000-0000-000000000001', true);
insert into locations (id, studio_id, name, is_primary) values
  ('c054c054-0000-0000-0000-0000000000aa','c054c054-0000-0000-0000-000000000001','Main',true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('c054c054-0000-0000-0000-000000001a01','c054c054-0000-0000-0000-000000000001','c054c054-0000-0000-0000-0000000000aa','RA',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('c054c054-0000-0000-0000-00000007c7a1','c054c054-0000-0000-0000-000000000001','Reformer',50,10);
-- An owner (runs the Fill — the confirm bypass is manager-gated), and a LOGIN
-- instructor (queue_assignment_request only fires for a login).
insert into auth.users (id) values
  ('c054c054-0000-0000-0000-0000000000a1'), ('c054c054-0000-0000-0000-00000000d101');
insert into profiles (id, email) values
  ('c054c054-0000-0000-0000-0000000000a1','c054-owner@example.com'),
  ('c054c054-0000-0000-0000-00000000d101','c054-d1@example.com');
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('c054c054-0000-0000-0000-0000000550a1','c054c054-0000-0000-0000-000000000001','c054c054-0000-0000-0000-0000000000a1','c054-owner@example.com','owner'),
  ('c054c054-0000-0000-0000-000000055d01','c054c054-0000-0000-0000-000000000001','c054c054-0000-0000-0000-00000000d101','c054-d1@example.com','instructor');
insert into instructors (id, studio_id, display_name, staff_id) values
  ('c054c054-0000-0000-0000-00000000d1aa','c054c054-0000-0000-0000-000000000001','Dana One','c054c054-0000-0000-0000-000000055d01');
-- Qualified for Reformer; no availability rows (available everywhere) and no
-- validity dates (valid on any date), so the engine will assign her.
insert into instructor_class_types (studio_id, instructor_id, class_type_id) values
  ('c054c054-0000-0000-0000-000000000001','c054c054-0000-0000-0000-00000000d1aa','c054c054-0000-0000-0000-00000007c7a1');

-- One OPEN occurrence, 10 days out at 07:00 Prague (publication off -> published).
insert into class_occurrences
  (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, booked_count,
   starts_at, ends_at, status)
values
  ('c054c054-0000-0000-0000-00000ccc0001','c054c054-0000-0000-0000-000000000001','c054c054-0000-0000-0000-0000000000aa',
   'c054c054-0000-0000-0000-00000007c7a1','c054c054-0000-0000-0000-000000001a01', null, 'Reformer', 10, 0,
   ((current_date + 10) + time '07:00') at time zone 'Europe/Prague',
   ((current_date + 10) + time '07:50') at time zone 'Europe/Prague', 'scheduled');

-- =============================================================================
-- 1. Fill WITH the tick (p_confirmed = true): assigned + confirmed, no ask.
--    Run as the OWNER — the confirm bypass is manager-gated.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','c054c054-0000-0000-0000-0000000000a1',false);
select assign_instructors('c054c054-0000-0000-0000-000000000001',
                          current_date, current_date + 20, false, true);
reset role;

select expect_true('tick: the open class was assigned to the login instructor',
  (select instructor_id = 'c054c054-0000-0000-0000-00000000d1aa'
     from class_occurrences where id='c054c054-0000-0000-0000-00000ccc0001'));
select expect_true('tick: it is stamped confirmed (assignment_confirmed_at set)',
  (select assignment_confirmed_at is not null
     from class_occurrences where id='c054c054-0000-0000-0000-00000ccc0001'));
select expect_num('tick: NO Decision 38 ask was left queued',
  (select count(*) from notifications
     where studio_id='c054c054-0000-0000-0000-000000000001'
       and template_key='assignment_confirmation_request' and status='scheduled')::bigint, 0);

-- =============================================================================
-- 2. Reset, Fill WITHOUT the tick: assigned + NOT confirmed + the ask queued.
-- =============================================================================
update class_occurrences
   set instructor_id = null, staffing = 'open',
       assignment_requested_at = null, assignment_confirmed_at = null, assignment_confirmed_by = null
 where id = 'c054c054-0000-0000-0000-00000ccc0001';
delete from notifications where studio_id = 'c054c054-0000-0000-0000-000000000001';

set role authenticated;
select set_config('request.jwt.claim.sub','c054c054-0000-0000-0000-0000000000a1',false);
select assign_instructors('c054c054-0000-0000-0000-000000000001',
                          current_date, current_date + 20, false, false);
reset role;

select expect_true('no tick: the open class was still assigned',
  (select instructor_id = 'c054c054-0000-0000-0000-00000000d1aa'
     from class_occurrences where id='c054c054-0000-0000-0000-00000ccc0001'));
select expect_true('no tick: it is NOT confirmed (assignment_confirmed_at null)',
  (select assignment_confirmed_at is null
     from class_occurrences where id='c054c054-0000-0000-0000-00000ccc0001'));
select expect_true('no tick: a Decision 38 ask was queued',
  (select count(*) > 0 from notifications
     where studio_id='c054c054-0000-0000-0000-000000000001'
       and template_key='assignment_confirmation_request' and status='scheduled'));

select 'fill_confirm_test: all assertions passed' as result;
