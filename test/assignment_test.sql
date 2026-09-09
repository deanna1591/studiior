-- =============================================================================
-- Automatic instructor assignment — migrations 060 and 061
-- UUID space a55e, checked free.
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

-- --- Fixtures ---------------------------------------------------------------
insert into auth.users (id) values ('a55ea55e-0000-0000-0000-0000000000a1');
insert into profiles (id, email, full_name) values
  ('a55ea55e-0000-0000-0000-0000000000a1','asg-owner@example.com','Ola Owner');
insert into studios (id, name, slug, timezone, currency, status) values
  ('a55ea55e-0000-0000-0000-000000000001','Assign Studio','asg-test','Europe/Prague','CZK','active');
insert into studio_settings (studio_id) values ('a55ea55e-0000-0000-0000-000000000001');
insert into locations (id, studio_id, name, is_primary) values
  ('a55ea55e-0000-0000-0000-00000000000c','a55ea55e-0000-0000-0000-000000000001','Main',true);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('a55ea55e-0000-0000-0000-00000000aa01','a55ea55e-0000-0000-0000-000000000001','a55ea55e-0000-0000-0000-0000000000a1','asg-owner@example.com','owner');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('a55ea55e-0000-0000-0000-00000000ee01','a55ea55e-0000-0000-0000-000000000001','a55ea55e-0000-0000-0000-00000000000c','R1',10),
  ('a55ea55e-0000-0000-0000-00000000ee02','a55ea55e-0000-0000-0000-000000000001','a55ea55e-0000-0000-0000-00000000000c','R2',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('a55ea55e-0000-0000-0000-00000000cc01','a55ea55e-0000-0000-0000-000000000001','Reformer',50,10),
  ('a55ea55e-0000-0000-0000-00000000cc02','a55ea55e-0000-0000-0000-000000000001','Barre',45,12);

-- ANNA is qualified and available all week. BEN is qualified and available.
-- CARA is qualified but her pattern is valid for NOVEMBER ONLY. DAN is
-- available but qualified for nothing.
insert into instructors (id, studio_id, display_name) values
  ('a55ea55e-0000-0000-0000-00000000d101','a55ea55e-0000-0000-0000-000000000001','Anna'),
  ('a55ea55e-0000-0000-0000-00000000d102','a55ea55e-0000-0000-0000-000000000001','Ben'),
  ('a55ea55e-0000-0000-0000-00000000d103','a55ea55e-0000-0000-0000-000000000001','Cara'),
  ('a55ea55e-0000-0000-0000-00000000d104','a55ea55e-0000-0000-0000-000000000001','Dan');

insert into instructor_class_types (studio_id, instructor_id, class_type_id) values
  ('a55ea55e-0000-0000-0000-000000000001','a55ea55e-0000-0000-0000-00000000d101','a55ea55e-0000-0000-0000-00000000cc01'),
  ('a55ea55e-0000-0000-0000-000000000001','a55ea55e-0000-0000-0000-00000000d102','a55ea55e-0000-0000-0000-00000000cc01'),
  ('a55ea55e-0000-0000-0000-000000000001','a55ea55e-0000-0000-0000-00000000d103','a55ea55e-0000-0000-0000-00000000cc01');

-- Anna and Ben: every weekday, wide hours, no end date.
insert into instructor_availability
  (studio_id, instructor_id, day_of_week, starts_at_time, ends_at_time, effective_from, is_available)
select 'a55ea55e-0000-0000-0000-000000000001', i, d, '06:00','21:00', current_date - 30, true
  from unnest(array['a55ea55e-0000-0000-0000-00000000d101',
                    'a55ea55e-0000-0000-0000-00000000d102']::uuid[]) i,
       generate_series(0,6) d;
-- Dan too, so "available but unqualified" is a real case rather than an absent one.
insert into instructor_availability
  (studio_id, instructor_id, day_of_week, starts_at_time, ends_at_time, effective_from, is_available)
select 'a55ea55e-0000-0000-0000-000000000001','a55ea55e-0000-0000-0000-00000000d104', d,
       '06:00','21:00', current_date - 30, true from generate_series(0,6) d;
-- CARA: November 2026 only.
insert into instructor_availability
  (studio_id, instructor_id, day_of_week, starts_at_time, ends_at_time,
   effective_from, effective_to, is_available)
select 'a55ea55e-0000-0000-0000-000000000001','a55ea55e-0000-0000-0000-00000000d103', d,
       '06:00','21:00', date '2026-11-01', date '2026-11-30', true
  from generate_series(0,6) d;

insert into instructor_commitments
  (studio_id, instructor_id, starts_on, min_per_week, target_per_week, shift_preference)
values ('a55ea55e-0000-0000-0000-000000000001','a55ea55e-0000-0000-0000-00000000d101', current_date - 30, 2, 4, 'both'),
       ('a55ea55e-0000-0000-0000-000000000001','a55ea55e-0000-0000-0000-00000000d102', current_date - 30, 2, 4, 'both');

set role authenticated;
select set_config('request.jwt.claim.sub','a55ea55e-0000-0000-0000-0000000000a1',false);

-- =============================================================================
-- 1. The validity window is a hard gate — a November instructor is not a
--    December candidate
-- =============================================================================
select expect_text('Cara is valid inside her November window',
  instructor_valid_on('a55ea55e-0000-0000-0000-00000000d103', date '2026-11-10')::text, 'true');
select expect_text('...and not valid in December',
  instructor_valid_on('a55ea55e-0000-0000-0000-00000000d103', date '2026-12-10')::text, 'false');
select expect_text('...nor in October',
  instructor_valid_on('a55ea55e-0000-0000-0000-00000000d103', date '2026-10-10')::text, 'false');
-- Someone who has never opened the screen is NOT gated: never saying anything
-- is not the same as saying no, and gating them would empty the cover board.
select expect_text('an instructor with no pattern at all is not gated',
  instructor_valid_on('a55ea55e-0000-0000-0000-00000000d101', date '2030-01-01')::text, 'true');

-- A dated exception inside the window removes that specific date.
insert into instructor_availability (studio_id, instructor_id, exception_date, is_available)
values ('a55ea55e-0000-0000-0000-000000000001','a55ea55e-0000-0000-0000-00000000d103',
        date '2026-11-11', false);
select expect_text('a dated exception inside the window removes that day',
  instructor_available_at('a55ea55e-0000-0000-0000-00000000d103',
    timestamptz '2026-11-11 08:00+00', timestamptz '2026-11-11 09:00+00')::text, 'false');
select expect_text('...and leaves the rest of the window alone',
  instructor_available_at('a55ea55e-0000-0000-0000-00000000d103',
    timestamptz '2026-11-10 08:00+00', timestamptz '2026-11-10 09:00+00')::text, 'true');

-- =============================================================================
-- 2. Qualified but unavailable is LEFT OPEN, never assigned
-- =============================================================================
reset role;
-- One Reformer class at 05:00 local, before anybody's stated hours.
insert into class_occurrences
  (id, studio_id, location_id, class_type_id, room_id, name, capacity,
   starts_at, ends_at, status, staffing)
values ('a55ea55e-0000-0000-0000-00000000f001','a55ea55e-0000-0000-0000-000000000001',
        'a55ea55e-0000-0000-0000-00000000000c','a55ea55e-0000-0000-0000-00000000cc01',
        'a55ea55e-0000-0000-0000-00000000ee01','Reformer', 10,
        ((current_date + 3) + time '05:00') at time zone 'Europe/Prague',
        ((current_date + 3) + time '05:50') at time zone 'Europe/Prague',
        'scheduled', 'open');

set role authenticated;
select set_config('request.jwt.claim.sub','a55ea55e-0000-0000-0000-0000000000a1',false);
select set_config('t.r1', (select assign_instructors('a55ea55e-0000-0000-0000-000000000001')::text), false);
select expect_num('a class outside everyone''s hours is left open',
  (current_setting('t.r1')::jsonb ->> 'left_open')::bigint, 1);
select expect_num('...and nobody was assigned to it',
  (current_setting('t.r1')::jsonb ->> 'assigned')::bigint, 0);
select expect_text('...with the reason said in words',
  (current_setting('t.r1')::jsonb -> 'detail' -> 0 ->> 'why'),
  'nobody qualified has said they are free at this time');
select expect_text('...and it really is still an open shift',
  (select staffing::text from class_occurrences where id='a55ea55e-0000-0000-0000-00000000f001'), 'open');

-- =============================================================================
-- 3. Nobody qualified at all is a different reason, and also left open
-- =============================================================================
reset role;
insert into class_occurrences
  (id, studio_id, location_id, class_type_id, room_id, name, capacity,
   starts_at, ends_at, status, staffing)
values ('a55ea55e-0000-0000-0000-00000000f002','a55ea55e-0000-0000-0000-000000000001',
        'a55ea55e-0000-0000-0000-00000000000c','a55ea55e-0000-0000-0000-00000000cc02',
        'a55ea55e-0000-0000-0000-00000000ee02','Barre', 12,
        ((current_date + 3) + time '10:00') at time zone 'Europe/Prague',
        ((current_date + 3) + time '10:45') at time zone 'Europe/Prague',
        'scheduled', 'open');
set role authenticated;
select set_config('request.jwt.claim.sub','a55ea55e-0000-0000-0000-0000000000a1',false);
select set_config('t.r2', (select assign_instructors('a55ea55e-0000-0000-0000-000000000001')::text), false);
select expect_true('a class type nobody is down to teach is left open, named as such',
  (select bool_or(x ->> 'why' = 'nobody is down to teach this class type')
     from jsonb_array_elements(current_setting('t.r2')::jsonb -> 'detail') x));

-- =============================================================================
-- 4. Two qualified instructors are distributed toward their targets
-- =============================================================================
reset role;
-- Six Reformer classes in one week, inside everybody's hours, two rooms so
-- nothing collides on the room constraint.
insert into class_occurrences
  (studio_id, location_id, class_type_id, room_id, name, capacity,
   starts_at, ends_at, status, staffing)
select 'a55ea55e-0000-0000-0000-000000000001','a55ea55e-0000-0000-0000-00000000000c',
       'a55ea55e-0000-0000-0000-00000000cc01',
       (case when i % 2 = 0 then 'a55ea55e-0000-0000-0000-00000000ee01'
                            else 'a55ea55e-0000-0000-0000-00000000ee02' end)::uuid,
       'Reformer', 10,
       ((current_date + 7) + time '09:00' + make_interval(hours => i)) at time zone 'Europe/Prague',
       ((current_date + 7) + time '09:50' + make_interval(hours => i)) at time zone 'Europe/Prague',
       'scheduled', 'open'
  from generate_series(0,5) i;

set role authenticated;
select set_config('request.jwt.claim.sub','a55ea55e-0000-0000-0000-0000000000a1',false);
select set_config('t.r3', (select assign_instructors('a55ea55e-0000-0000-0000-000000000001')::text), false);
select expect_num('all six are filled',
  (current_setting('t.r3')::jsonb ->> 'assigned')::bigint, 6);

reset role;
select expect_num('Anna took three',
  (select count(*) from class_occurrences
    where instructor_id='a55ea55e-0000-0000-0000-00000000d101')::bigint, 3);
select expect_num('...and Ben took three — not one person taking everything',
  (select count(*) from class_occurrences
    where instructor_id='a55ea55e-0000-0000-0000-00000000d102')::bigint, 3);
select expect_num('Cara took none: her window is November and these are not',
  (select count(*) from class_occurrences
    where instructor_id='a55ea55e-0000-0000-0000-00000000d103')::bigint, 0);
select expect_num('Dan took none: available, but down to teach nothing',
  (select count(*) from class_occurrences
    where instructor_id='a55ea55e-0000-0000-0000-00000000d104')::bigint, 0);

-- The working, in words.
select expect_true('the run says why each person got theirs',
  (select bool_and(x ->> 'why' like '% classes that week, furthest below their target')
     from jsonb_array_elements(current_setting('t.r3')::jsonb -> 'detail') x
    where x ->> 'outcome' = 'assigned'));

-- =============================================================================
-- 5. Running twice changes nothing
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','a55ea55e-0000-0000-0000-0000000000a1',false);
select set_config('t.again', (select assign_instructors('a55ea55e-0000-0000-0000-000000000001')::text), false);
select expect_num('a second run assigns nothing new',
  (current_setting('t.again')::jsonb ->> 'assigned')::bigint, 0);
reset role;
select expect_num('...and Anna still has exactly three',
  (select count(*) from class_occurrences
    where instructor_id='a55ea55e-0000-0000-0000-00000000d101')::bigint, 3);

-- =============================================================================
-- 6. A manual assignment survives a re-run
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','a55ea55e-0000-0000-0000-0000000000a1',false);
select set_config('t.manual', (select id::text from class_occurrences
  where instructor_id='a55ea55e-0000-0000-0000-00000000d101' limit 1), false);
-- A human moves it to Ben. The trigger marks it; nothing at the call site has
-- to remember.
update class_occurrences set instructor_id = 'a55ea55e-0000-0000-0000-00000000d102'
 where id = current_setting('t.manual')::uuid;
select expect_true('a human assignment is marked as one',
  (select assigned_by is not null from class_occurrences
    where id = current_setting('t.manual')::uuid));

reset role;
-- Free it up so the engine would otherwise be tempted to fill it.
update class_occurrences set instructor_id = null, staffing = 'open'
 where id = current_setting('t.manual')::uuid;
set role authenticated;
select set_config('request.jwt.claim.sub','a55ea55e-0000-0000-0000-0000000000a1',false);
select set_config('t.r4', (select assign_instructors('a55ea55e-0000-0000-0000-000000000001')::text), false);
select expect_num('the engine will not touch a class a person has touched',
  (current_setting('t.r4')::jsonb ->> 'assigned')::bigint, 0);
reset role;
select expect_true('...so it stays exactly as the human left it',
  (select instructor_id is null and staffing = 'open' from class_occurrences
    where id = current_setting('t.manual')::uuid));

-- =============================================================================
-- 7. A dry run writes nothing
-- =============================================================================
reset role;
update class_occurrences set assigned_by = null
 where id = current_setting('t.manual')::uuid;
set role authenticated;
select set_config('request.jwt.claim.sub','a55ea55e-0000-0000-0000-0000000000a1',false);
select set_config('t.dry', (select assign_instructors(
  'a55ea55e-0000-0000-0000-000000000001', null, null, true)::text), false);
select expect_true('a dry run says what it would do',
  (current_setting('t.dry')::jsonb ->> 'assigned')::int >= 1);
reset role;
select expect_true('...and changes nothing',
  (select instructor_id is null from class_occurrences
    where id = current_setting('t.manual')::uuid));

-- =============================================================================
-- 8. No commitments: the fallback is stated, not silent
-- =============================================================================
reset role;
delete from instructor_commitments where studio_id = 'a55ea55e-0000-0000-0000-000000000001';
update class_occurrences set instructor_id = null, staffing = 'open', assigned_by = null
 where studio_id = 'a55ea55e-0000-0000-0000-000000000001' and class_type_id = 'a55ea55e-0000-0000-0000-00000000cc01'
   and starts_at > now() + interval '5 days';
set role authenticated;
select set_config('request.jwt.claim.sub','a55ea55e-0000-0000-0000-0000000000a1',false);
select set_config('t.r5', (select assign_instructors('a55ea55e-0000-0000-0000-000000000001')::text), false);
select expect_text('with no commitments the run SAYS it is falling back',
  (current_setting('t.r5')::jsonb ->> 'commitment_fallback'), 'true');
select expect_true('...and names who has none on file',
  jsonb_array_length(current_setting('t.r5')::jsonb -> 'no_commitment_for') >= 1);
select expect_true('...and the reason given is fewest classes, not a target',
  (select bool_and(x ->> 'why' like '% classes that week, fewest of the candidates%')
     from jsonb_array_elements(current_setting('t.r5')::jsonb -> 'detail') x
    where x ->> 'outcome' = 'assigned'));
reset role;
select expect_num('...and it still distributes rather than piling up',
  (select max(n) from (
     select count(*) as n from class_occurrences
      where studio_id='a55ea55e-0000-0000-0000-000000000001'
        and instructor_id is not null and starts_at > now() + interval '5 days'
      group by instructor_id) c)::bigint, 3);
