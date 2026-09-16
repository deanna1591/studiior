-- =============================================================================
-- Auto-accept cover (156), claim-then-drop reliability (156), and the silent
-- availability-narrowing gap (155). UUID space c0e5.
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
create or replace function expect_text(label text, actual text, want text) returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (%)', label, actual;
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if; end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('c0e5c0e5-0000-0000-0000-0000000000a1'),  -- owner
  ('c0e5c0e5-0000-0000-0000-0000000000d1'),  -- R (requester)
  ('c0e5c0e5-0000-0000-0000-0000000000d2');  -- T (taker)
insert into profiles (id, email) values
  ('c0e5c0e5-0000-0000-0000-0000000000a1','c0e5-o@example.com'),
  ('c0e5c0e5-0000-0000-0000-0000000000d1','c0e5-r@example.com'),
  ('c0e5c0e5-0000-0000-0000-0000000000d2','c0e5-t@example.com');
insert into studios (id, name, slug, timezone, currency, status) values
  ('c0e5c0e5-0000-0000-0000-000000000001','Cover A','cover-a','Europe/Prague','CZK','active');
insert into studio_settings (studio_id, cover_auto_accept_enabled, cover_escalation_hours) values
  ('c0e5c0e5-0000-0000-0000-000000000001', true, 4);
insert into locations (id, studio_id, name, is_primary) values
  ('c0e5c0e5-0000-0000-0000-00000000000a','c0e5c0e5-0000-0000-0000-000000000001','Main',true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('c0e5c0e5-0000-0000-0000-0000000ee0a1','c0e5c0e5-0000-0000-0000-000000000001','c0e5c0e5-0000-0000-0000-00000000000a','R',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('c0e5c0e5-0000-0000-0000-0000000cc0a1','c0e5c0e5-0000-0000-0000-000000000001','Reformer',50,10);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('c0e5c0e5-0000-0000-0000-000000aa00a1','c0e5c0e5-0000-0000-0000-000000000001','c0e5c0e5-0000-0000-0000-0000000000a1','c0e5-o@example.com','owner'),
  ('c0e5c0e5-0000-0000-0000-000000aa00d1','c0e5c0e5-0000-0000-0000-000000000001','c0e5c0e5-0000-0000-0000-0000000000d1','c0e5-r@example.com','instructor'),
  ('c0e5c0e5-0000-0000-0000-000000aa00d2','c0e5c0e5-0000-0000-0000-000000000001','c0e5c0e5-0000-0000-0000-0000000000d2','c0e5-t@example.com','instructor');
insert into instructors (id, studio_id, display_name, staff_id) values
  ('c0e5c0e5-0000-0000-0000-0000000d00d1','c0e5c0e5-0000-0000-0000-000000000001','Rae Requester','c0e5c0e5-0000-0000-0000-000000aa00d1'),
  ('c0e5c0e5-0000-0000-0000-0000000d00d2','c0e5c0e5-0000-0000-0000-000000000001','Tao Taker','c0e5c0e5-0000-0000-0000-000000aa00d2');
insert into instructor_class_types (studio_id, instructor_id, class_type_id) values
  ('c0e5c0e5-0000-0000-0000-000000000001','c0e5c0e5-0000-0000-0000-0000000d00d1','c0e5c0e5-0000-0000-0000-0000000cc0a1'),
  ('c0e5c0e5-0000-0000-0000-000000000001','c0e5c0e5-0000-0000-0000-0000000d00d2','c0e5c0e5-0000-0000-0000-0000000cc0a1');
-- Both available all week (approved standing pattern), so valid_on + available_at hold.
insert into instructor_availability (instructor_id, studio_id, day_of_week, starts_at_time, ends_at_time, approval_status)
select i, 'c0e5c0e5-0000-0000-0000-000000000001', d, '00:00','23:59','approved'
  from (values ('c0e5c0e5-0000-0000-0000-0000000d00d1'::uuid),('c0e5c0e5-0000-0000-0000-0000000d00d2'::uuid)) x(i),
       generate_series(0,6) d;

-- =============================================================================
-- 1. (c) request_cover on a CLAIMED class records the drop for reliability
-- =============================================================================
-- Class C, assigned to R, that R CLAIMED (an approved shift application).
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, booked_count, starts_at, ends_at, status)
values ('c0e5c0e5-0000-0000-0000-000000c00001','c0e5c0e5-0000-0000-0000-000000000001','c0e5c0e5-0000-0000-0000-00000000000a','c0e5c0e5-0000-0000-0000-0000000cc0a1','c0e5c0e5-0000-0000-0000-0000000ee0a1','c0e5c0e5-0000-0000-0000-0000000d00d1','Reformer',10,0, now()+interval '5 days', now()+interval '5 days'+interval '50 min','scheduled');
insert into shift_applications (id, studio_id, occurrence_id, instructor_id, status, approved_at)
values ('c0e5c0e5-0000-0000-0000-000000a00001','c0e5c0e5-0000-0000-0000-000000000001','c0e5c0e5-0000-0000-0000-000000c00001','c0e5c0e5-0000-0000-0000-0000000d00d1','approved', now());

set role authenticated;
select set_config('request.jwt.claim.sub','c0e5c0e5-0000-0000-0000-0000000000d1',false);  -- R
select expect_true('R can request cover on the class they claimed',
  (request_cover('c0e5c0e5-0000-0000-0000-000000c00001','cannot make it')::jsonb ->> 'ok')::boolean);
reset role;
select expect_true('...and the claim is stamped withdrawn (reliability counts it)',
  (select withdrawn_at is not null from shift_applications where id='c0e5c0e5-0000-0000-0000-000000a00001'));
set role authenticated;
select set_config('request.jwt.claim.sub','c0e5c0e5-0000-0000-0000-0000000000d1',false);
select expect_num('instructor_reliability shows the withdrawal',
  (instructor_reliability('c0e5c0e5-0000-0000-0000-0000000d00d1') ->> 'withdrawn')::bigint, 1);
select expect_num('...and still counts the approval (applied then withdrawn)',
  (instructor_reliability('c0e5c0e5-0000-0000-0000-0000000d00d1') ->> 'approved')::bigint, 1);
reset role;

-- =============================================================================
-- 2. (a) auto-accept: the first qualified instructor takes an urgent cover
-- =============================================================================
-- Urgent class U (2 hours out), assigned to R, a pending cover request on it.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, booked_count, starts_at, ends_at, status)
values ('c0e5c0e5-0000-0000-0000-000000c00002','c0e5c0e5-0000-0000-0000-000000000001','c0e5c0e5-0000-0000-0000-00000000000a','c0e5c0e5-0000-0000-0000-0000000cc0a1','c0e5c0e5-0000-0000-0000-0000000ee0a1','c0e5c0e5-0000-0000-0000-0000000d00d1','Reformer',10,0, now()+interval '2 hours', now()+interval '2 hours'+interval '50 min','scheduled');
insert into cover_requests (studio_id, occurrence_id, instructor_id, status)
values ('c0e5c0e5-0000-0000-0000-000000000001','c0e5c0e5-0000-0000-0000-000000c00002','c0e5c0e5-0000-0000-0000-0000000d00d1','pending');

-- T sees it as available to take.
set role authenticated;
select set_config('request.jwt.claim.sub','c0e5c0e5-0000-0000-0000-0000000000d2',false);  -- T
select expect_num('the urgent cover is on T''s "cover needed now" list',
  jsonb_array_length(cover_available_to('c0e5c0e5-0000-0000-0000-0000000d00d2') -> 'classes'), 1);
select expect_true('T takes it — no staff approval',
  (accept_cover('c0e5c0e5-0000-0000-0000-000000c00002')::jsonb ->> 'ok')::boolean);
reset role;
select expect_text('...the class is now T''s',
  (select instructor_id::text from class_occurrences where id='c0e5c0e5-0000-0000-0000-000000c00002'),
  'c0e5c0e5-0000-0000-0000-0000000d00d2');
select expect_text('...the cover request is covered by T',
  (select covered_by::text from cover_requests where occurrence_id='c0e5c0e5-0000-0000-0000-000000c00002'),
  'c0e5c0e5-0000-0000-0000-0000000d00d2');
select expect_num('...R was told it is covered',
  (select count(*) from notifications where template_key='cover_approved' and user_id='c0e5c0e5-0000-0000-0000-0000000000d1')::bigint, 1);

-- A FAR class (10 days out) with a cover request cannot be auto-taken.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, booked_count, starts_at, ends_at, status)
values ('c0e5c0e5-0000-0000-0000-000000c00003','c0e5c0e5-0000-0000-0000-000000000001','c0e5c0e5-0000-0000-0000-00000000000a','c0e5c0e5-0000-0000-0000-0000000cc0a1','c0e5c0e5-0000-0000-0000-0000000ee0a1','c0e5c0e5-0000-0000-0000-0000000d00d1','Reformer',10,0, now()+interval '10 days', now()+interval '10 days'+interval '50 min','scheduled');
insert into cover_requests (studio_id, occurrence_id, instructor_id, status)
values ('c0e5c0e5-0000-0000-0000-000000000001','c0e5c0e5-0000-0000-0000-000000c00003','c0e5c0e5-0000-0000-0000-0000000d00d1','pending');
set role authenticated;
select set_config('request.jwt.claim.sub','c0e5c0e5-0000-0000-0000-0000000000d2',false);
select expect_num('a far cover is NOT on the take-now list',
  jsonb_array_length(cover_available_to('c0e5c0e5-0000-0000-0000-0000000d00d2') -> 'classes'), 0);
do $$ begin
  begin perform accept_cover('c0e5c0e5-0000-0000-0000-000000c00003');
    raise exception 'FAIL  a far cover was auto-taken';
  exception when sqlstate 'PT409' then raise notice 'PASS  a far cover needs approving, not auto-taken';
  end;
end $$;
reset role;

-- Switch auto-accept OFF: accept_cover refuses even an urgent one.
update studio_settings set cover_auto_accept_enabled = false where studio_id='c0e5c0e5-0000-0000-0000-000000000001';
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, booked_count, starts_at, ends_at, status)
values ('c0e5c0e5-0000-0000-0000-000000c00004','c0e5c0e5-0000-0000-0000-000000000001','c0e5c0e5-0000-0000-0000-00000000000a','c0e5c0e5-0000-0000-0000-0000000cc0a1','c0e5c0e5-0000-0000-0000-0000000ee0a1','c0e5c0e5-0000-0000-0000-0000000d00d1','Reformer',10,0, now()+interval '3 hours', now()+interval '3 hours'+interval '50 min','scheduled');
insert into cover_requests (studio_id, occurrence_id, instructor_id, status)
values ('c0e5c0e5-0000-0000-0000-000000000001','c0e5c0e5-0000-0000-0000-000000c00004','c0e5c0e5-0000-0000-0000-0000000d00d1','pending');
set role authenticated;
select set_config('request.jwt.claim.sub','c0e5c0e5-0000-0000-0000-0000000000d2',false);
do $$ begin
  begin perform accept_cover('c0e5c0e5-0000-0000-0000-000000c00004');
    raise exception 'FAIL  auto-accept off but a cover was taken';
  exception when sqlstate 'PT409' then raise notice 'PASS  with auto-accept off the studio still approves cover itself';
  end;
end $$;
reset role;
update studio_settings set cover_auto_accept_enabled = true where studio_id='c0e5c0e5-0000-0000-0000-000000000001';

-- =============================================================================
-- 3. (b) narrowing standing availability flags the assignments it strands
-- =============================================================================
-- R is assigned to class B three days out, on that weekday; R is available then.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, booked_count, starts_at, ends_at, status)
select 'c0e5c0e5-0000-0000-0000-000000b00001','c0e5c0e5-0000-0000-0000-000000000001','c0e5c0e5-0000-0000-0000-00000000000a','c0e5c0e5-0000-0000-0000-0000000cc0a1','c0e5c0e5-0000-0000-0000-0000000ee0a1','c0e5c0e5-0000-0000-0000-0000000d00d1','Reformer',10,0,
  ((current_date+3)+time '08:00') at time zone 'Europe/Prague', ((current_date+3)+time '08:50') at time zone 'Europe/Prague','scheduled';
select expect_true('before: R is available for class B',
  instructor_available_at('c0e5c0e5-0000-0000-0000-0000000d00d1',
    (select starts_at from class_occurrences where id='c0e5c0e5-0000-0000-0000-000000b00001'),
    (select ends_at   from class_occurrences where id='c0e5c0e5-0000-0000-0000-000000b00001')));
select expect_num('before: no availability conflicts',
  (availability_conflicts('c0e5c0e5-0000-0000-0000-000000000001') ->> 'count')::bigint, 0);

-- R narrows: removes availability on B's weekday (empty ranges for that day).
set role authenticated;
select set_config('request.jwt.claim.sub','c0e5c0e5-0000-0000-0000-0000000000d1',false);  -- R
select set_instructor_availability('c0e5c0e5-0000-0000-0000-0000000d00d1',
  jsonb_build_array(jsonb_build_object('day', extract(dow from (current_date+3))::int, 'ranges', '[]'::jsonb)));
reset role;

select expect_false('after: R is no longer available for class B',
  instructor_available_at('c0e5c0e5-0000-0000-0000-0000000d00d1',
    (select starts_at from class_occurrences where id='c0e5c0e5-0000-0000-0000-000000b00001'),
    (select ends_at   from class_occurrences where id='c0e5c0e5-0000-0000-0000-000000b00001')));
select expect_true('after: class B shows as an availability conflict',
  exists(select 1 from jsonb_array_elements(availability_conflicts('c0e5c0e5-0000-0000-0000-000000000001') -> 'conflicts') c
          where c ->> 'occurrence_id' = 'c0e5c0e5-0000-0000-0000-000000b00001'));
select expect_true('...still assigned to R (NOT silently unstaffed)',
  (select instructor_id = 'c0e5c0e5-0000-0000-0000-0000000d00d1' from class_occurrences where id='c0e5c0e5-0000-0000-0000-000000b00001'));
select expect_num('...staff were told, same weight as an unstaffed class',
  (select count(*) from notifications where template_key='availability_narrowed_staff'
     and studio_id='c0e5c0e5-0000-0000-0000-000000000001')::bigint, 1);
select expect_num('...and R was told what they still hold',
  (select count(*) from notifications where template_key='availability_narrowed_instructor'
     and user_id='c0e5c0e5-0000-0000-0000-0000000000d1')::bigint, 1);

select 'cover_auto_test: all assertions passed' as done;
