-- =============================================================================
-- Decisions 43 + 42a — auto-assigner off by default, assign/unassign from the
-- Schedule for a period, clear a month. UUID space a543, checked free.
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
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual then raise notice 'PASS  %  (got true)', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_false(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual is not null and not actual then raise notice 'PASS  %  (got false)', label;
  else raise exception 'FAIL  %  expected false, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if;
end $$;
create or replace function expect_raises(label text, sql text, want_sqlstate text)
returns void language plpgsql as $$
begin
  execute sql;
  raise exception 'FAIL  %  expected % but nothing raised', label, want_sqlstate;
exception when others then
  if SQLSTATE = want_sqlstate then raise notice 'PASS  %  (raised %)', label, want_sqlstate;
  else raise exception 'FAIL  %  expected %, got % (%)', label, want_sqlstate, SQLSTATE, SQLERRM; end if;
end $$;

-- The target month for the scope/clear fixtures — two months out, safely future
-- and a whole calendar month clear of "this month" boundaries.
select set_config('t.m', date_trunc('month', current_date + interval '2 months')::date::text, false);

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('a543a543-0000-0000-0000-0000000000a1'),  -- owner SA
  ('a543a543-0000-0000-0000-00000000d101'),  -- D1 login
  ('a543a543-0000-0000-0000-00000000d102'),  -- D2 login
  ('a543a543-0000-0000-0000-00000000d103'),  -- D3 login
  ('a543a543-0000-0000-0000-0000000ada01'),  -- Ada login (availability)
  ('a543a543-0000-0000-0000-0000000000b1'),  -- owner SB
  ('a543a543-0000-0000-0000-0000000e1b01'),  -- E1 login (SB)
  ('a543a543-0000-0000-0000-0000000000c1'),  -- owner SC
  ('a543a543-0000-0000-0000-0000000c2a01');  -- manager SC
insert into profiles (id, email) values
  ('a543a543-0000-0000-0000-0000000000a1','a543-owner-a@example.com'),
  ('a543a543-0000-0000-0000-00000000d101','a543-d1@example.com'),
  ('a543a543-0000-0000-0000-00000000d102','a543-d2@example.com'),
  ('a543a543-0000-0000-0000-00000000d103','a543-d3@example.com'),
  ('a543a543-0000-0000-0000-0000000ada01','a543-ada@example.com'),
  ('a543a543-0000-0000-0000-0000000000b1','a543-owner-b@example.com'),
  ('a543a543-0000-0000-0000-0000000e1b01','a543-e1@example.com'),
  ('a543a543-0000-0000-0000-0000000000c1','a543-owner-c@example.com'),
  ('a543a543-0000-0000-0000-0000000c2a01','a543-mgr-c@example.com');

insert into studios (id, name, slug, timezone, currency, status) values
  ('a543a543-0000-0000-0000-000000000001','Hand Assign','a543-a','Europe/Prague','CZK','active'),
  ('a543a543-0000-0000-0000-000000000002','Auto On','a543-b','Europe/Prague','CZK','active'),
  ('a543a543-0000-0000-0000-000000000003','Publish','a543-c','Europe/Prague','CZK','active');
-- SA: auto OFF (default), confirmations ON, publication OFF.
-- SB: auto ON.  SC: auto OFF, publication ON.
insert into studio_settings (studio_id, auto_assign_open_classes, assignment_confirmations, publication_enabled) values
  ('a543a543-0000-0000-0000-000000000001', false, true,  false),
  ('a543a543-0000-0000-0000-000000000002', true,  false, false),
  ('a543a543-0000-0000-0000-000000000003', false, false, true);
insert into locations (id, studio_id, name, is_primary) values
  ('a543a543-0000-0000-0000-0000000000aa','a543a543-0000-0000-0000-000000000001','Main',true),
  ('a543a543-0000-0000-0000-0000000000bb','a543a543-0000-0000-0000-000000000002','Main',true),
  ('a543a543-0000-0000-0000-0000000000cc','a543a543-0000-0000-0000-000000000003','Main',true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('a543a543-0000-0000-0000-000000001a01','a543a543-0000-0000-0000-000000000001','a543a543-0000-0000-0000-0000000000aa','RA',10),
  ('a543a543-0000-0000-0000-000000001b01','a543a543-0000-0000-0000-000000000001','a543a543-0000-0000-0000-0000000000aa','RB',10),
  ('a543a543-0000-0000-0000-000000001b02','a543a543-0000-0000-0000-000000000002','a543a543-0000-0000-0000-0000000000bb','RB',10),
  ('a543a543-0000-0000-0000-000000001c01','a543a543-0000-0000-0000-000000000003','a543a543-0000-0000-0000-0000000000cc','RC',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('a543a543-0000-0000-0000-00000007c7a1','a543a543-0000-0000-0000-000000000001','Reformer',50,10),
  ('a543a543-0000-0000-0000-00000007c7b1','a543a543-0000-0000-0000-000000000002','Reformer',50,10),
  ('a543a543-0000-0000-0000-00000007c7c1','a543a543-0000-0000-0000-000000000003','Reformer',50,10);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('a543a543-0000-0000-0000-0000000550a1','a543a543-0000-0000-0000-000000000001','a543a543-0000-0000-0000-0000000000a1','a543-owner-a@example.com','owner'),
  ('a543a543-0000-0000-0000-000000055d01','a543a543-0000-0000-0000-000000000001','a543a543-0000-0000-0000-00000000d101','a543-d1@example.com','instructor'),
  ('a543a543-0000-0000-0000-000000055d02','a543a543-0000-0000-0000-000000000001','a543a543-0000-0000-0000-00000000d102','a543-d2@example.com','instructor'),
  ('a543a543-0000-0000-0000-000000055d03','a543a543-0000-0000-0000-000000000001','a543a543-0000-0000-0000-00000000d103','a543-d3@example.com','instructor'),
  ('a543a543-0000-0000-0000-000000055da1','a543a543-0000-0000-0000-000000000001','a543a543-0000-0000-0000-0000000ada01','a543-ada@example.com','instructor'),
  ('a543a543-0000-0000-0000-0000000550b1','a543a543-0000-0000-0000-000000000002','a543a543-0000-0000-0000-0000000000b1','a543-owner-b@example.com','owner'),
  ('a543a543-0000-0000-0000-000000055e01','a543a543-0000-0000-0000-000000000002','a543a543-0000-0000-0000-0000000e1b01','a543-e1@example.com','instructor'),
  ('a543a543-0000-0000-0000-0000000550c1','a543a543-0000-0000-0000-000000000003','a543a543-0000-0000-0000-0000000000c1','a543-owner-c@example.com','owner'),
  ('a543a543-0000-0000-0000-00000055c2a1','a543a543-0000-0000-0000-000000000003','a543a543-0000-0000-0000-0000000c2a01','a543-mgr-c@example.com','manager');
insert into instructors (id, studio_id, display_name, staff_id) values
  ('a543a543-0000-0000-0000-00000000d1aa','a543a543-0000-0000-0000-000000000001','Dana One','a543a543-0000-0000-0000-000000055d01'),
  ('a543a543-0000-0000-0000-00000000d2aa','a543a543-0000-0000-0000-000000000001','Deb Two','a543a543-0000-0000-0000-000000055d02'),
  ('a543a543-0000-0000-0000-00000000d3aa','a543a543-0000-0000-0000-000000000001','Dot Three','a543a543-0000-0000-0000-000000055d03'),
  ('a543a543-0000-0000-0000-0000000adaaa','a543a543-0000-0000-0000-000000000001','Ada Avail','a543a543-0000-0000-0000-000000055da1'),
  ('a543a543-0000-0000-0000-0000000e1bbb','a543a543-0000-0000-0000-000000000002','Ed One','a543a543-0000-0000-0000-000000055e01'),
  ('a543a543-0000-0000-0000-0000000f1ccc','a543a543-0000-0000-0000-000000000003','Fay One',null);
-- Everyone qualified for their studio's Reformer.
insert into instructor_class_types (studio_id, instructor_id, class_type_id) values
  ('a543a543-0000-0000-0000-000000000001','a543a543-0000-0000-0000-00000000d1aa','a543a543-0000-0000-0000-00000007c7a1'),
  ('a543a543-0000-0000-0000-000000000001','a543a543-0000-0000-0000-00000000d2aa','a543a543-0000-0000-0000-00000007c7a1'),
  ('a543a543-0000-0000-0000-000000000001','a543a543-0000-0000-0000-00000000d3aa','a543a543-0000-0000-0000-00000007c7a1'),
  ('a543a543-0000-0000-0000-000000000001','a543a543-0000-0000-0000-0000000adaaa','a543a543-0000-0000-0000-00000007c7a1'),
  ('a543a543-0000-0000-0000-000000000002','a543a543-0000-0000-0000-0000000e1bbb','a543a543-0000-0000-0000-00000007c7b1');
-- Ada states Monday 06:00-08:00 only, open-ended — so she is VALID on any date
-- (no block) but UNAVAILABLE at any other time (the Decision 37c warning).
insert into instructor_availability (studio_id, instructor_id, day_of_week, starts_at_time, ends_at_time, is_available) values
  ('a543a543-0000-0000-0000-000000000001','a543a543-0000-0000-0000-0000000adaaa',1,'06:00','08:00',true);

-- A member on each studio where bookings matter.
insert into members (id, studio_id, first_name, last_name, email) values
  ('a543a543-0000-0000-0000-00000003e0c1','a543a543-0000-0000-0000-000000000003','Mem','C','a543-mem-c@example.com');

-- =============================================================================
-- 1. DECISION 43 — switch OFF: a new series materialises all OPEN, nobody
--    assigned, no Decision 38 request. (SA, auto off, confirmations on.)
-- =============================================================================
insert into class_series (id, studio_id, location_id, class_type_id, name, room_id, instructor_id,
   capacity, duration_minutes, rrule, starts_on, time_of_day)
values ('a543a543-0000-0000-0000-000000005e43','a543a543-0000-0000-0000-000000000001',
        'a543a543-0000-0000-0000-0000000000aa','a543a543-0000-0000-0000-00000007c7a1','Decision43',
        'a543a543-0000-0000-0000-000000001a01', null,
        10,50,'FREQ=WEEKLY;BYDAY=MO,TH', current_date + 1, '07:00');
select expect_true('switch off: the series materialised some occurrences',
  (select count(*) > 0 from class_occurrences where series_id='a543a543-0000-0000-0000-000000005e43'));
select expect_true('switch off: EVERY occurrence is open and unassigned',
  (select count(*) = count(*) filter (where instructor_id is null and staffing='open')
     from class_occurrences where series_id='a543a543-0000-0000-0000-000000005e43'));
select expect_num('switch off: no Decision 38 request stamped',
  (select count(*) from class_occurrences
     where series_id='a543a543-0000-0000-0000-000000005e43' and assignment_requested_at is not null)::bigint, 0);
-- The availability auto-fill path is gated too: setting D1's availability at the
-- switch-OFF studio runs no engine, so the open series stays open.
set role authenticated; select set_config('request.jwt.claim.sub','a543a543-0000-0000-0000-0000000000a1',false);
select set_instructor_availability('a543a543-0000-0000-0000-00000000d1aa',
  '[{"day":1,"ranges":[{"from":"00:00","to":"23:59"}]},{"day":4,"ranges":[{"from":"00:00","to":"23:59"}]}]'::jsonb);
reset role; select set_config('request.jwt.claim.sub', null, false);
select expect_true('switch off: an availability change does NOT auto-fill',
  (select count(*) = count(*) filter (where instructor_id is null)
     from class_occurrences where series_id='a543a543-0000-0000-0000-000000005e43'));

-- =============================================================================
-- 2. DECISION 43 — switch ON: today's behaviour, the engine runs. (SB.) The
--    materialise/assign trigger fires assign BEFORE materialise on a fresh
--    INSERT (so a bare insert fills nothing even on main); the engine runs on
--    the availability path, which is where the switch is observable — ON fills
--    the open occurrences, OFF (above) does not.
-- =============================================================================
insert into class_series (id, studio_id, location_id, class_type_id, name, room_id, instructor_id,
   capacity, duration_minutes, rrule, starts_on, time_of_day)
values ('a543a543-0000-0000-0000-000000005e44','a543a543-0000-0000-0000-000000000002',
        'a543a543-0000-0000-0000-0000000000bb','a543a543-0000-0000-0000-00000007c7b1','AutoOn',
        'a543a543-0000-0000-0000-000000001b02', null,
        10,50,'FREQ=WEEKLY;BYDAY=MO,TH', current_date + 1, '07:00');
select expect_true('switch on: the series materialised open occurrences',
  (select count(*) > 0 from class_occurrences where series_id='a543a543-0000-0000-0000-000000005e44'));
-- Setting E1's availability (switch ON) runs the engine, which fills the open
-- occurrences with the qualified, available instructor — today's behaviour.
set role authenticated; select set_config('request.jwt.claim.sub','a543a543-0000-0000-0000-0000000000b1',false);
select set_instructor_availability('a543a543-0000-0000-0000-0000000e1bbb',
  '[{"day":1,"ranges":[{"from":"00:00","to":"23:59"}]},{"day":4,"ranges":[{"from":"00:00","to":"23:59"}]}]'::jsonb);
reset role; select set_config('request.jwt.claim.sub', null, false);
select expect_true('switch on: the engine assigned the qualified instructor',
  (select count(*) > 0 from class_occurrences
     where series_id='a543a543-0000-0000-0000-000000005e44'
       and instructor_id='a543a543-0000-0000-0000-0000000e1bbb' and staffing='assigned'));

-- =============================================================================
-- Fixtures for the Decision 42a scope tests (SA): series with NO instructor,
-- occurrences inserted directly in the target month (and one next month).
-- =============================================================================
-- 'month' scope series SM.
insert into class_series (id, studio_id, location_id, class_type_id, name, room_id, instructor_id,
   capacity, duration_minutes, rrule, starts_on, time_of_day)
values ('a543a543-0000-0000-0000-000000005001','a543a543-0000-0000-0000-000000000001',
        'a543a543-0000-0000-0000-0000000000aa','a543a543-0000-0000-0000-00000007c7a1','Month Series',
        'a543a543-0000-0000-0000-000000001a01', null, 10,50,
        'FREQ=WEEKLY;BYDAY=MO', current_date + interval '6 months', '07:00');
-- A SECOND series SO, to prove scope never touches another series.
insert into class_series (id, studio_id, location_id, class_type_id, name, room_id, instructor_id,
   capacity, duration_minutes, rrule, starts_on, time_of_day)
values ('a543a543-0000-0000-0000-000000005002','a543a543-0000-0000-0000-000000000001',
        'a543a543-0000-0000-0000-0000000000aa','a543a543-0000-0000-0000-00000007c7a1','Other Series',
        'a543a543-0000-0000-0000-000000001b01', null, 10,50,
        'FREQ=WEEKLY;BYDAY=TU', current_date + interval '6 months', '08:00');
-- 'until' series SU.
insert into class_series (id, studio_id, location_id, class_type_id, name, room_id, instructor_id,
   capacity, duration_minutes, rrule, starts_on, time_of_day)
values ('a543a543-0000-0000-0000-000000005003','a543a543-0000-0000-0000-000000000001',
        'a543a543-0000-0000-0000-0000000000aa','a543a543-0000-0000-0000-00000007c7a1','Until Series',
        'a543a543-0000-0000-0000-000000001a01', null, 10,50,
        'FREQ=WEEKLY;BYDAY=WE', current_date + interval '6 months', '09:00');
-- clash series SC1 + a one-off occurrence D1 already teaches at the clash time.
insert into class_series (id, studio_id, location_id, class_type_id, name, room_id, instructor_id,
   capacity, duration_minutes, rrule, starts_on, time_of_day)
values ('a543a543-0000-0000-0000-000000005004','a543a543-0000-0000-0000-000000000001',
        'a543a543-0000-0000-0000-0000000000aa','a543a543-0000-0000-0000-00000007c7a1','Clash Series',
        'a543a543-0000-0000-0000-000000001a01', null, 10,50,
        'FREQ=WEEKLY;BYDAY=FR', current_date + interval '6 months', '11:00');

-- Occurrences, inserted directly at controlled instants in the target month 'm'.
insert into class_occurrences
  (id, studio_id, location_id, class_type_id, room_id, series_id, name, capacity,
   starts_at, ends_at, status, staffing)
values
  -- SM: three in month m, one in m+1.
  ('a543a543-0000-0000-0000-000000030001','a543a543-0000-0000-0000-000000000001','a543a543-0000-0000-0000-0000000000aa','a543a543-0000-0000-0000-00000007c7a1','a543a543-0000-0000-0000-000000001a01','a543a543-0000-0000-0000-000000005001','Month Series',10,
   (current_setting('t.m')::date + 3 + time '07:00') at time zone 'Europe/Prague',(current_setting('t.m')::date + 3 + time '07:50') at time zone 'Europe/Prague','scheduled','open'),
  ('a543a543-0000-0000-0000-000000030002','a543a543-0000-0000-0000-000000000001','a543a543-0000-0000-0000-0000000000aa','a543a543-0000-0000-0000-00000007c7a1','a543a543-0000-0000-0000-000000001a01','a543a543-0000-0000-0000-000000005001','Month Series',10,
   (current_setting('t.m')::date + 10 + time '07:00') at time zone 'Europe/Prague',(current_setting('t.m')::date + 10 + time '07:50') at time zone 'Europe/Prague','scheduled','open'),
  ('a543a543-0000-0000-0000-000000030003','a543a543-0000-0000-0000-000000000001','a543a543-0000-0000-0000-0000000000aa','a543a543-0000-0000-0000-00000007c7a1','a543a543-0000-0000-0000-000000001a01','a543a543-0000-0000-0000-000000005001','Month Series',10,
   (current_setting('t.m')::date + 17 + time '07:00') at time zone 'Europe/Prague',(current_setting('t.m')::date + 17 + time '07:50') at time zone 'Europe/Prague','scheduled','open'),
  ('a543a543-0000-0000-0000-000000030004','a543a543-0000-0000-0000-000000000001','a543a543-0000-0000-0000-0000000000aa','a543a543-0000-0000-0000-00000007c7a1','a543a543-0000-0000-0000-000000001a01','a543a543-0000-0000-0000-000000005001','Month Series',10,
   ((current_setting('t.m')::date + interval '1 month')::date + 3 + time '07:00') at time zone 'Europe/Prague',((current_setting('t.m')::date + interval '1 month')::date + 3 + time '07:50') at time zone 'Europe/Prague','scheduled','open'),
  -- SO: one in month m (different series, same room is fine, different time).
  ('a543a543-0000-0000-0000-000000060001','a543a543-0000-0000-0000-000000000001','a543a543-0000-0000-0000-0000000000aa','a543a543-0000-0000-0000-00000007c7a1','a543a543-0000-0000-0000-000000001b01','a543a543-0000-0000-0000-000000005002','Other Series',10,
   (current_setting('t.m')::date + 4 + time '08:00') at time zone 'Europe/Prague',(current_setting('t.m')::date + 4 + time '08:50') at time zone 'Europe/Prague','scheduled','open'),
  -- SU: three in month m.
  ('a543a543-0000-0000-0000-000000040001','a543a543-0000-0000-0000-000000000001','a543a543-0000-0000-0000-0000000000aa','a543a543-0000-0000-0000-00000007c7a1','a543a543-0000-0000-0000-000000001a01','a543a543-0000-0000-0000-000000005003','Until Series',10,
   (current_setting('t.m')::date + 4 + time '09:00') at time zone 'Europe/Prague',(current_setting('t.m')::date + 4 + time '09:50') at time zone 'Europe/Prague','scheduled','open'),
  ('a543a543-0000-0000-0000-000000040002','a543a543-0000-0000-0000-000000000001','a543a543-0000-0000-0000-0000000000aa','a543a543-0000-0000-0000-00000007c7a1','a543a543-0000-0000-0000-000000001a01','a543a543-0000-0000-0000-000000005003','Until Series',10,
   (current_setting('t.m')::date + 11 + time '09:00') at time zone 'Europe/Prague',(current_setting('t.m')::date + 11 + time '09:50') at time zone 'Europe/Prague','scheduled','open'),
  ('a543a543-0000-0000-0000-000000040003','a543a543-0000-0000-0000-000000000001','a543a543-0000-0000-0000-0000000000aa','a543a543-0000-0000-0000-00000007c7a1','a543a543-0000-0000-0000-000000001a01','a543a543-0000-0000-0000-000000005003','Until Series',10,
   (current_setting('t.m')::date + 18 + time '09:00') at time zone 'Europe/Prague',(current_setting('t.m')::date + 18 + time '09:50') at time zone 'Europe/Prague','scheduled','open'),
  -- SC1: two in month m.
  ('a543a543-0000-0000-0000-0000000c0001','a543a543-0000-0000-0000-000000000001','a543a543-0000-0000-0000-0000000000aa','a543a543-0000-0000-0000-00000007c7a1','a543a543-0000-0000-0000-000000001a01','a543a543-0000-0000-0000-000000005004','Clash Series',10,
   (current_setting('t.m')::date + 6 + time '11:00') at time zone 'Europe/Prague',(current_setting('t.m')::date + 6 + time '11:50') at time zone 'Europe/Prague','scheduled','open'),
  ('a543a543-0000-0000-0000-0000000c0002','a543a543-0000-0000-0000-000000000001','a543a543-0000-0000-0000-0000000000aa','a543a543-0000-0000-0000-00000007c7a1','a543a543-0000-0000-0000-000000001a01','a543a543-0000-0000-0000-000000005004','Clash Series',10,
   (current_setting('t.m')::date + 13 + time '11:00') at time zone 'Europe/Prague',(current_setting('t.m')::date + 13 + time '11:50') at time zone 'Europe/Prague','scheduled','open'),
  -- A one-off D1 already teaches at the clash time (m+13 11:00, OTHER room).
  ('a543a543-0000-0000-0000-0000000c8001','a543a543-0000-0000-0000-000000000001','a543a543-0000-0000-0000-0000000000aa','a543a543-0000-0000-0000-00000007c7a1','a543a543-0000-0000-0000-000000001b01',null,'Clash Fixed',10,
   (current_setting('t.m')::date + 13 + time '11:00') at time zone 'Europe/Prague',(current_setting('t.m')::date + 13 + time '11:50') at time zone 'Europe/Prague','scheduled','assigned'),
  -- Ada's class, outside her hours (15:00): valid_on true, available_at false.
  ('a543a543-0000-0000-0000-0000000a9001','a543a543-0000-0000-0000-000000000001','a543a543-0000-0000-0000-0000000000aa','a543a543-0000-0000-0000-00000007c7a1','a543a543-0000-0000-0000-000000001a01',null,'Ada Class',10,
   (current_setting('t.m')::date + 8 + time '15:00') at time zone 'Europe/Prague',(current_setting('t.m')::date + 8 + time '15:50') at time zone 'Europe/Prague','scheduled','open');
-- Give the clash one-off its instructor (D1) directly.
update class_occurrences set instructor_id='a543a543-0000-0000-0000-00000000d1aa', staffing='assigned'
 where id='a543a543-0000-0000-0000-0000000c8001';

-- =============================================================================
-- 3. 'month' scope: assigns this series' month-m occurrences from this one
--    forward, never the next-month one, never another series. (p_confirmed=false
--    → one coalesced request for the instructor.)
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','a543a543-0000-0000-0000-0000000000a1',false);  -- owner SA
select set_config('t.r3', (select assign_occurrences_for_period(
  'a543a543-0000-0000-0000-000000030001','a543a543-0000-0000-0000-00000000d1aa','month',null,false)::text), false);
reset role; select set_config('request.jwt.claim.sub', null, false);
select expect_num('month: assigned the three month-m occurrences',
  (current_setting('t.r3')::jsonb ->> 'assigned')::bigint, 3);
select expect_num('month: no skips',
  jsonb_array_length(current_setting('t.r3')::jsonb -> 'skipped')::bigint, 0);
select expect_true('month: all three month-m occurrences carry D1',
  (select count(*) = 3 from class_occurrences
     where series_id='a543a543-0000-0000-0000-000000005001'
       and instructor_id='a543a543-0000-0000-0000-00000000d1aa'
       and id in ('a543a543-0000-0000-0000-000000030001','a543a543-0000-0000-0000-000000030002','a543a543-0000-0000-0000-000000030003')));
select expect_true('month: the NEXT-month occurrence is untouched (still open)',
  (select instructor_id is null and staffing='open' from class_occurrences where id='a543a543-0000-0000-0000-000000030004'));
select expect_true('month: the OTHER series is untouched',
  (select instructor_id is null from class_occurrences where id='a543a543-0000-0000-0000-000000060001'));
select expect_true('series template is NEVER touched',
  (select instructor_id is null from class_series where id='a543a543-0000-0000-0000-000000005001'));
select expect_num('month (p_confirmed false): exactly ONE coalesced request for D1',
  (select count(*) from notifications where template_key='assignment_confirmation_request'
     and user_id='a543a543-0000-0000-0000-00000000d101' and status='scheduled')::bigint, 1);
select expect_num('...and none of the three is confirmed',
  (select count(*) from class_occurrences where series_id='a543a543-0000-0000-0000-000000005001'
     and assignment_confirmed_at is not null)::bigint, 0);

-- =============================================================================
-- 4. 'until' scope: this series, this one through p_until inclusive.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','a543a543-0000-0000-0000-0000000000a1',false);
select set_config('t.r4', (select assign_occurrences_for_period(
  'a543a543-0000-0000-0000-000000040001','a543a543-0000-0000-0000-00000000d2aa','until',
  (current_setting('t.m')::date + 11)::date, false)::text), false);
reset role; select set_config('request.jwt.claim.sub', null, false);
select expect_num('until: assigned the two occurrences up to the date',
  (current_setting('t.r4')::jsonb ->> 'assigned')::bigint, 2);
select expect_true('until: u1 and u2 carry D2',
  (select count(*)=2 from class_occurrences where instructor_id='a543a543-0000-0000-0000-00000000d2aa'
     and id in ('a543a543-0000-0000-0000-000000040001','a543a543-0000-0000-0000-000000040002')));
select expect_true('until: u3 (after the date) is untouched',
  (select instructor_id is null and staffing='open' from class_occurrences where id='a543a543-0000-0000-0000-000000040003'));

-- =============================================================================
-- 5. 'one' scope: assigns exactly this occurrence.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','a543a543-0000-0000-0000-0000000000a1',false);
select set_config('t.r5', (select assign_occurrences_for_period(
  'a543a543-0000-0000-0000-0000000c0001','a543a543-0000-0000-0000-00000000d3aa','one',null,false)::text), false);
reset role; select set_config('request.jwt.claim.sub', null, false);
select expect_num('one: assigned exactly one', (current_setting('t.r5')::jsonb ->> 'assigned')::bigint, 1);
select expect_true('one: c1 carries D3, c2 still open',
  (select (select instructor_id from class_occurrences where id='a543a543-0000-0000-0000-0000000c0001')='a543a543-0000-0000-0000-00000000d3aa'
      and (select instructor_id is null from class_occurrences where id='a543a543-0000-0000-0000-0000000c0002')));

-- =============================================================================
-- 6. double-booking → skipped with reason, the rest assigned. D1 assigned to
--    clash series 'month' from c0001 forward: c0001 (m+6) assigns, c0002 (m+13
--    11:00) clashes with the one-off D1 already teaches → skipped.
-- =============================================================================
-- First clear D3 off c0001 so D1 can take the clash series cleanly.
update class_occurrences set instructor_id=null, staffing='open' where id='a543a543-0000-0000-0000-0000000c0001';
set role authenticated;
select set_config('request.jwt.claim.sub','a543a543-0000-0000-0000-0000000000a1',false);
select set_config('t.r6', (select assign_occurrences_for_period(
  'a543a543-0000-0000-0000-0000000c0001','a543a543-0000-0000-0000-00000000d1aa','month',null,false)::text), false);
reset role; select set_config('request.jwt.claim.sub', null, false);
select expect_num('clash: one assigned (c0001)', (current_setting('t.r6')::jsonb ->> 'assigned')::bigint, 1);
select expect_num('clash: one skipped (c0002)',
  jsonb_array_length(current_setting('t.r6')::jsonb -> 'skipped')::bigint, 1);
select expect_true('clash: the skip names the instructor and reads "already teaches"',
  (current_setting('t.r6')::jsonb -> 'skipped' -> 0 ->> 'reason') like 'Dana One already teaches%at that time');
select expect_true('clash: c0002 was NOT reassigned (still open)',
  (select instructor_id is null from class_occurrences where id='a543a543-0000-0000-0000-0000000c0002'));

-- =============================================================================
-- 7. p_confirmed TRUE: assignment_confirmed_by stamped, NO request queued.
--    (Deb Two, SU u3, which is still open.)
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','a543a543-0000-0000-0000-0000000000a1',false);
select set_config('t.r7', (select assign_occurrences_for_period(
  'a543a543-0000-0000-0000-000000040003','a543a543-0000-0000-0000-00000000d3aa','one',null,true)::text), false);
reset role; select set_config('request.jwt.claim.sub', null, false);
select expect_true('confirmed: assignment_confirmed_by is the acting manager',
  (select assignment_confirmed_by = 'a543a543-0000-0000-0000-0000000000a1'
     from class_occurrences where id='a543a543-0000-0000-0000-000000040003'));
select expect_num('confirmed: NO scheduled request for D3 (digest cancelled)',
  (select count(*) from notifications where template_key='assignment_confirmation_request'
     and user_id='a543a543-0000-0000-0000-00000000d103' and status='scheduled')::bigint, 0);

-- =============================================================================
-- 8. UNASSIGN → open + the pending Decision 38 request withdrawn.
--    m0002 currently carries D1 (from the 'month' assign) and D1 has a pending
--    digest. Unassign m0001/m0002/m0003 'month' from m0001 → all open, and the
--    digest that listed them is withdrawn (D1 has nothing else pending).
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','a543a543-0000-0000-0000-0000000000a1',false);
select set_config('t.r8', (select assign_occurrences_for_period(
  'a543a543-0000-0000-0000-000000030001', null, 'month', null, false)::text), false);
reset role; select set_config('request.jwt.claim.sub', null, false);
select expect_num('unassign: three returned to open',
  (current_setting('t.r8')::jsonb ->> 'assigned')::bigint, 3);
select expect_true('unassign: all three are open with no instructor',
  (select count(*)=3 from class_occurrences
     where id in ('a543a543-0000-0000-0000-000000030001','a543a543-0000-0000-0000-000000030002','a543a543-0000-0000-0000-000000030003')
       and instructor_id is null and staffing='open'));
select expect_num('unassign: the per-occurrence request stamp is cleared',
  (select count(*) from class_occurrences
     where id in ('a543a543-0000-0000-0000-000000030001','a543a543-0000-0000-0000-000000030002','a543a543-0000-0000-0000-000000030003')
       and assignment_requested_at is not null)::bigint, 0);
-- The withdrawn classes are gone from D1's coalesced digest. (D1 still has a
-- digest for the Clash Series it kept from test 6 — the resync recomputes,
-- it does not blanket-delete.)
select expect_false('unassign: the withdrawn Month Series is gone from D1''s digest',
  (select exists (select 1 from notifications where template_key='assignment_confirmation_request'
     and user_id='a543a543-0000-0000-0000-00000000d101' and status='scheduled'
     and payload ->> 'class_list' like '%Month Series%')));

-- =============================================================================
-- 9. outside-availability → WARNING present, assignment STILL made. (Ada, 15:00.)
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','a543a543-0000-0000-0000-0000000000a1',false);
select set_config('t.r9', (select assign_occurrences_for_period(
  'a543a543-0000-0000-0000-0000000a9001','a543a543-0000-0000-0000-0000000adaaa','one',null,false)::text), false);
reset role; select set_config('request.jwt.claim.sub', null, false);
select expect_num('availability: still assigned', (current_setting('t.r9')::jsonb ->> 'assigned')::bigint, 1);
select expect_true('availability: the outside_availability warning is present',
  (current_setting('t.r9')::jsonb -> 'warnings') ? 'outside_availability');
select expect_true('availability: Ada is on the class',
  (select instructor_id='a543a543-0000-0000-0000-0000000adaaa' from class_occurrences where id='a543a543-0000-0000-0000-0000000a9001'));

-- =============================================================================
-- 10. non-manager → PT403.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','a543a543-0000-0000-0000-00000000d101',false);  -- D1 (instructor)
select expect_raises('a non-manager cannot assign from the Schedule',
  'select assign_occurrences_for_period(''a543a543-0000-0000-0000-000000060001''::uuid, ''a543a543-0000-0000-0000-00000000d2aa''::uuid, ''one'', null, false)',
  'PT403');
reset role; select set_config('request.jwt.claim.sub', null, false);

-- =============================================================================
-- CLEAR-MONTH fixtures (SC, publication on): three months — P published+booking,
-- Q published+no-booking, R draft+booking.
-- =============================================================================
select set_config('t.p', date_trunc('month', current_date + interval '2 months')::date::text, false);
select set_config('t.q', (date_trunc('month', current_date + interval '2 months') + interval '1 month')::date::text, false);
select set_config('t.rr', (date_trunc('month', current_date + interval '2 months') + interval '2 months')::date::text, false);

insert into class_occurrences
  (id, studio_id, location_id, class_type_id, room_id, series_id, name, capacity,
   instructor_id, staffing, starts_at, ends_at, status)
values
  ('a543a543-0000-0000-0000-000000020001','a543a543-0000-0000-0000-000000000003','a543a543-0000-0000-0000-0000000000cc','a543a543-0000-0000-0000-00000007c7c1','a543a543-0000-0000-0000-000000001c01',null,'P class',10,
   'a543a543-0000-0000-0000-0000000f1ccc','assigned',(current_setting('t.p')::date + 5 + time '07:00') at time zone 'Europe/Prague',(current_setting('t.p')::date + 5 + time '07:50') at time zone 'Europe/Prague','scheduled'),
  ('a543a543-0000-0000-0000-0000000d0001','a543a543-0000-0000-0000-000000000003','a543a543-0000-0000-0000-0000000000cc','a543a543-0000-0000-0000-00000007c7c1','a543a543-0000-0000-0000-000000001c01',null,'Q class',10,
   'a543a543-0000-0000-0000-0000000f1ccc','assigned',(current_setting('t.q')::date + 5 + time '07:00') at time zone 'Europe/Prague',(current_setting('t.q')::date + 5 + time '07:50') at time zone 'Europe/Prague','scheduled'),
  ('a543a543-0000-0000-0000-000000010001','a543a543-0000-0000-0000-000000000003','a543a543-0000-0000-0000-0000000000cc','a543a543-0000-0000-0000-00000007c7c1','a543a543-0000-0000-0000-000000001c01',null,'R class',10,
   'a543a543-0000-0000-0000-0000000f1ccc','assigned',(current_setting('t.rr')::date + 5 + time '07:00') at time zone 'Europe/Prague',(current_setting('t.rr')::date + 5 + time '07:50') at time zone 'Europe/Prague','scheduled');
-- Publish P and Q (R stays a draft).
set role authenticated; select set_config('request.jwt.claim.sub','a543a543-0000-0000-0000-0000000000c1',false);
select publish_month('a543a543-0000-0000-0000-000000000003', current_setting('t.p')::date);
select publish_month('a543a543-0000-0000-0000-000000000003', current_setting('t.q')::date);
reset role; select set_config('request.jwt.claim.sub', null, false);
-- A member booking on P (published) and on R (draft).
insert into bookings (studio_id, occurrence_id, member_id, status) values
  ('a543a543-0000-0000-0000-000000000003','a543a543-0000-0000-0000-000000020001','a543a543-0000-0000-0000-00000003e0c1','booked'),
  ('a543a543-0000-0000-0000-000000000003','a543a543-0000-0000-0000-000000010001','a543a543-0000-0000-0000-00000003e0c1','booked');

-- =============================================================================
-- 11. clear_month: published + bookings, OWNER WITHOUT acknowledge → PT409.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','a543a543-0000-0000-0000-0000000000c1',false);  -- owner SC
select expect_raises('clear: published+bookings, owner but no acknowledge, is refused',
  'select clear_month_assignments(''a543a543-0000-0000-0000-000000000003''::uuid, '''|| current_setting('t.p') ||'''::date, true, false)',
  'PT409');
reset role; select set_config('request.jwt.claim.sub', null, false);
select expect_true('clear: the refused month''s class keeps its instructor',
  (select instructor_id is not null from class_occurrences where id='a543a543-0000-0000-0000-000000020001'));

-- =============================================================================
-- 12. clear_month: published + ZERO bookings → allowed, template cleared on ask.
-- =============================================================================
-- Give Q a series template (on SC) so the template-clear has something to clear.
insert into class_series (id, studio_id, location_id, class_type_id, name, room_id, instructor_id,
   capacity, duration_minutes, rrule, starts_on, time_of_day)
values ('a543a543-0000-0000-0000-00000000d5e1','a543a543-0000-0000-0000-000000000003',
        'a543a543-0000-0000-0000-0000000000cc','a543a543-0000-0000-0000-00000007c7c1','Q Series',
        'a543a543-0000-0000-0000-000000001c01','a543a543-0000-0000-0000-0000000f1ccc',10,50,
        'FREQ=WEEKLY;BYDAY=MO', current_date + interval '6 months', '07:00');
update class_occurrences set series_id='a543a543-0000-0000-0000-00000000d5e1' where id='a543a543-0000-0000-0000-0000000d0001';
set role authenticated;
select set_config('request.jwt.claim.sub','a543a543-0000-0000-0000-0000000000c1',false);
select set_config('t.cq', (select clear_month_assignments(
  'a543a543-0000-0000-0000-000000000003', current_setting('t.q')::date, true)::text), false);
reset role; select set_config('request.jwt.claim.sub', null, false);
select expect_num('clear Q: one occurrence cleared', (current_setting('t.cq')::jsonb ->> 'cleared')::bigint, 1);
select expect_true('clear Q: the class is now open',
  (select instructor_id is null and staffing='open' from class_occurrences where id='a543a543-0000-0000-0000-0000000d0001'));
select expect_num('clear Q: one template cleared', (current_setting('t.cq')::jsonb ->> 'templates_cleared')::bigint, 1);
select expect_true('clear Q: the series template instructor is now null',
  (select instructor_id is null from class_series where id='a543a543-0000-0000-0000-00000000d5e1'));
select expect_true('clear Q: the PUBLISHED month P class is untouched (other month)',
  (select instructor_id is not null from class_occurrences where id='a543a543-0000-0000-0000-000000020001'));

-- =============================================================================
-- 13. clear_month: draft month + bookings → allowed.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','a543a543-0000-0000-0000-0000000000c1',false);
select set_config('t.cr', (select clear_month_assignments(
  'a543a543-0000-0000-0000-000000000003', current_setting('t.rr')::date, false)::text), false);
reset role; select set_config('request.jwt.claim.sub', null, false);
select expect_num('clear R (draft + booking): one cleared', (current_setting('t.cr')::jsonb ->> 'cleared')::bigint, 1);
select expect_true('clear R: the class is open',
  (select instructor_id is null and staffing='open' from class_occurrences where id='a543a543-0000-0000-0000-000000010001'));

-- =============================================================================
-- 14. clear_month: non-manager → PT403.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','a543a543-0000-0000-0000-0000000000a1',false);  -- owner of SA, not SC
select expect_raises('clear: a non-manager of the studio is refused',
  'select clear_month_assignments(''a543a543-0000-0000-0000-000000000003''::uuid, '''|| current_setting('t.rr') ||'''::date, false)',
  'PT403');
reset role; select set_config('request.jwt.claim.sub', null, false);

-- =============================================================================
-- 15–16. Decision 42a AMENDMENT — the OWNER may clear a published month with
--        bookings, with an explicit acknowledge; a MANAGER still cannot.
--        Run last, so P stays intact for test 12's cross-month isolation check.
-- =============================================================================
-- The N/M the owner acknowledgement names come from SQL (month_publication_facts),
-- not from TS: P has one member booked into one class.
select expect_num('facts: P names 1 booking member',
  (month_publication_facts('a543a543-0000-0000-0000-000000000003', current_setting('t.p')::date) ->> 'booking_members')::bigint, 1);
select expect_num('facts: P names 1 booking class',
  (month_publication_facts('a543a543-0000-0000-0000-000000000003', current_setting('t.p')::date) ->> 'booking_classes')::bigint, 1);

-- A MANAGER with acknowledge is still refused (amendment is owner-only).
set role authenticated;
select set_config('request.jwt.claim.sub','a543a543-0000-0000-0000-0000000c2a01',false);  -- manager SC
select expect_raises('clear: published+bookings, MANAGER with acknowledge, still refused',
  'select clear_month_assignments(''a543a543-0000-0000-0000-000000000003''::uuid, '''|| current_setting('t.p') ||'''::date, true, true)',
  'PT409');
reset role; select set_config('request.jwt.claim.sub', null, false);
select expect_true('clear: after the manager refusal P''s class keeps its instructor',
  (select instructor_id is not null from class_occurrences where id='a543a543-0000-0000-0000-000000020001'));

-- Snapshot the member's notification footprint and the booking before the clear.
select set_config('t.notif_before',
  (select count(*)::text from notifications where member_id='a543a543-0000-0000-0000-00000003e0c1'), false);

-- The OWNER with acknowledge clears it: instructor off, class open, bookings intact.
set role authenticated;
select set_config('request.jwt.claim.sub','a543a543-0000-0000-0000-0000000000c1',false);  -- owner SC
select set_config('t.cp', (select clear_month_assignments(
  'a543a543-0000-0000-0000-000000000003', current_setting('t.p')::date, true, true)::text), false);
reset role; select set_config('request.jwt.claim.sub', null, false);
select expect_num('clear P (owner + acknowledge): one cleared',
  (current_setting('t.cp')::jsonb ->> 'cleared')::bigint, 1);
select expect_true('clear P: the class is now open, instructor null',
  (select instructor_id is null and staffing='open' from class_occurrences where id='a543a543-0000-0000-0000-000000020001'));
-- Bookings untouched: same count, same status, same member on P's class.
select expect_num('clear P: the member booking still stands (not cancelled)',
  (select count(*)::bigint from bookings
    where occurrence_id='a543a543-0000-0000-0000-000000020001' and status='booked'
      and member_id='a543a543-0000-0000-0000-00000003e0c1'), 1);
select expect_num('clear P: no booking became cancelled',
  (select count(*)::bigint from bookings
    where occurrence_id='a543a543-0000-0000-0000-000000020001' and status='cancelled'), 0);
-- No member notification was queued by the clear (members are not told).
select expect_num('clear P: no member notification queued',
  (select count(*)::bigint from notifications where member_id='a543a543-0000-0000-0000-00000003e0c1'),
  current_setting('t.notif_before')::bigint);

select 'assign from schedule suite finished' as done;
