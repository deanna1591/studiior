-- =============================================================================
-- purge_demo_data deletes exactly what is_demo marks. Nothing else, by any path.
-- Migration 062. UUID space deed, checked free.
-- =============================================================================
-- Written because it did not. class_occurrences.series_id -> class_series is
-- ON DELETE CASCADE, so deleting a demo series took every occurrence of it
-- whatever the occurrence's own is_demo said — on production, 1,036 real
-- classes and everything hanging off them.
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
create or replace function expect_raises(label text, stmt text, want_sqlstate text)
returns void language plpgsql as $$
begin
  execute stmt; raise exception 'FAIL  %  expected % but nothing was raised', label, want_sqlstate;
exception when others then
  if sqlstate = want_sqlstate then raise notice 'PASS  %  (got %)', label, sqlstate;
  elsif sqlstate = 'P0001' and sqlerrm like 'FAIL%' then raise;
  else raise exception 'FAIL  %  expected %, got % (%)', label, want_sqlstate, sqlstate, sqlerrm; end if;
end $$;

-- --- Fixtures ---------------------------------------------------------------
insert into auth.users (id) values ('deeddeed-0000-0000-0000-0000000000a1');
insert into profiles (id, email, full_name) values
  ('deeddeed-0000-0000-0000-0000000000a1','purge-ops@example.com','Ops Admin');
insert into platform_admins (user_id, email, note) values
  ('deeddeed-0000-0000-0000-0000000000a1','purge-ops@example.com','purge suite');
insert into studios (id, name, slug, timezone, currency, status) values
  ('deeddeed-0000-0000-0000-000000000001','Purge Studio','purge-suite','Europe/Prague','CZK','active');
insert into studio_settings (studio_id, checkin_window_enforced)
  values ('deeddeed-0000-0000-0000-000000000001', false);
insert into locations (id, studio_id, name, is_primary) values
  ('deeddeed-0000-0000-0000-00000000000c','deeddeed-0000-0000-0000-000000000001','Main',true);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('deeddeed-0000-0000-0000-00000000aa01','deeddeed-0000-0000-0000-000000000001','deeddeed-0000-0000-0000-0000000000a1','purge-ops@example.com','owner');

-- Demo data first, as an operator would generate it to show the studio around.
set role authenticated;
select set_config('request.jwt.claim.sub','deeddeed-0000-0000-0000-0000000000a1',false);
select set_config('t.gen', (select generate_demo_data('deeddeed-0000-0000-0000-000000000001')::text), false);
reset role;
select expect_true('demo data generated',
  (current_setting('t.gen')::jsonb ->> 'occurrences')::int > 0);

-- REAL records, entered through the app afterwards. Every is_demo table that a
-- studio actually fills in by hand.
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('deeddeed-0000-0000-0000-00000000cc01','deeddeed-0000-0000-0000-000000000001','Real Reformer',50,10);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('deeddeed-0000-0000-0000-00000000ee01','deeddeed-0000-0000-0000-000000000001','deeddeed-0000-0000-0000-00000000000c','Real Room',10);
insert into instructors (id, studio_id, display_name) values
  ('deeddeed-0000-0000-0000-00000000d101','deeddeed-0000-0000-0000-000000000001','Real Teacher One'),
  ('deeddeed-0000-0000-0000-00000000d102','deeddeed-0000-0000-0000-000000000001','Real Teacher Two');
insert into instructor_availability
  (studio_id, instructor_id, day_of_week, starts_at_time, ends_at_time, is_available)
select 'deeddeed-0000-0000-0000-000000000001','deeddeed-0000-0000-0000-00000000d101', d, '07:00','19:00', true
  from generate_series(1,5) d;
insert into instructor_commitments
  (studio_id, instructor_id, starts_on, min_per_week, target_per_week)
values ('deeddeed-0000-0000-0000-000000000001','deeddeed-0000-0000-0000-00000000d101', current_date - 10, 4, 8);
insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, validity_days) values
  ('deeddeed-0000-0000-0000-000000000b01','deeddeed-0000-0000-0000-000000000001','Real Pack','class_pack', 500000,'CZK', 10, 180);
insert into members (id, studio_id, first_name, last_name, email, joined_on, status, waiver_signed_at) values
  ('deeddeed-0000-0000-0000-00000000dd01','deeddeed-0000-0000-0000-000000000001','Real','Member','realpurge@example.com', current_date - 30, 'active', now());
insert into class_series
  (id, studio_id, location_id, class_type_id, name, instructor_id, room_id,
   capacity, duration_minutes, rrule, starts_on, time_of_day)
values ('deeddeed-0000-0000-0000-00000000f501','deeddeed-0000-0000-0000-000000000001',
        'deeddeed-0000-0000-0000-00000000000c','deeddeed-0000-0000-0000-00000000cc01',
        'Real Series','deeddeed-0000-0000-0000-00000000d101','deeddeed-0000-0000-0000-00000000ee01',
        10, 50, 'FREQ=WEEKLY;BYDAY=TU', current_date, '08:00');

-- THE CASE THAT DESTROYED PRODUCTION: migration 057's generator materialising
-- REAL occurrences against a DEMO series, which is what the nightly job does to
-- every series a studio has, demo or not.
select set_config('t.demo_series', (select id::text from class_series
  where studio_id='deeddeed-0000-0000-0000-000000000001' and is_demo limit 1), false);
insert into class_occurrences
  (id, studio_id, location_id, series_id, class_type_id, name, capacity,
   starts_at, ends_at, status, staffing, series_slot_at)
values ('deeddeed-0000-0000-0000-00000000f001','deeddeed-0000-0000-0000-000000000001',
        'deeddeed-0000-0000-0000-00000000000c', current_setting('t.demo_series')::uuid,
        'deeddeed-0000-0000-0000-00000000cc01','Real class on a demo series', 10,
        now() + interval '10 days', now() + interval '10 days 50 minutes',
        'scheduled','open', now() + interval '10 days');
-- And a real booking on it, so the loss would reach a member.
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source) values
  ('deeddeed-0000-0000-0000-00000000bb01','deeddeed-0000-0000-0000-000000000001',
   'deeddeed-0000-0000-0000-00000000f001','deeddeed-0000-0000-0000-00000000dd01','booked','comp');

select set_config('t.before', (select demo_purge_census('deeddeed-0000-0000-0000-000000000001')::text), false);

-- =============================================================================
-- The purge
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','deeddeed-0000-0000-0000-0000000000a1',false);
select set_config('t.purge', (select purge_demo_data('deeddeed-0000-0000-0000-000000000001')::text), false);
reset role;

select expect_true('the purge removed demo members',
  (current_setting('t.purge')::jsonb ->> 'members')::int > 0);
select expect_num('and no demo row of any kind is left',
  ((select count(*) from members where studio_id='deeddeed-0000-0000-0000-000000000001' and is_demo)
 + (select count(*) from class_occurrences where studio_id='deeddeed-0000-0000-0000-000000000001' and is_demo)
 + (select count(*) from class_series where studio_id='deeddeed-0000-0000-0000-000000000001' and is_demo)
 + (select count(*) from instructors where studio_id='deeddeed-0000-0000-0000-000000000001' and is_demo)
 + (select count(*) from rooms where studio_id='deeddeed-0000-0000-0000-000000000001' and is_demo)
 + (select count(*) from class_types where studio_id='deeddeed-0000-0000-0000-000000000001' and is_demo)
 + (select count(*) from membership_plans where studio_id='deeddeed-0000-0000-0000-000000000001' and is_demo))::bigint, 0);

-- --- EVERY real row survives ------------------------------------------------
select expect_num('real instructors survive',
  (select count(*) from instructors
    where studio_id='deeddeed-0000-0000-0000-000000000001' and not is_demo)::bigint, 2);
select expect_num('real availability survives',
  (select count(*) from instructor_availability
    where instructor_id='deeddeed-0000-0000-0000-00000000d101')::bigint, 5);
select expect_num('real commitments survive',
  (select count(*) from instructor_commitments
    where studio_id='deeddeed-0000-0000-0000-000000000001')::bigint, 1);
select expect_num('real members survive',
  (select count(*) from members
    where studio_id='deeddeed-0000-0000-0000-000000000001' and not is_demo)::bigint, 1);
select expect_num('real class types survive',
  (select count(*) from class_types
    where studio_id='deeddeed-0000-0000-0000-000000000001' and not is_demo)::bigint, 1);
select expect_num('real rooms survive',
  (select count(*) from rooms
    where studio_id='deeddeed-0000-0000-0000-000000000001' and not is_demo)::bigint, 1);
select expect_num('real plans survive',
  (select count(*) from membership_plans
    where studio_id='deeddeed-0000-0000-0000-000000000001' and not is_demo)::bigint, 1);
select expect_num('real series survive',
  (select count(*) from class_series
    where studio_id='deeddeed-0000-0000-0000-000000000001' and not is_demo)::bigint, 1);

-- THE ONE THAT MATTERED. A real class materialised against a demo series.
select expect_num('a real class on a demo series survives the series being purged',
  (select count(*) from class_occurrences
    where id='deeddeed-0000-0000-0000-00000000f001')::bigint, 1);
select expect_true('...detached from the series rather than deleted with it',
  (select series_id is null from class_occurrences
    where id='deeddeed-0000-0000-0000-00000000f001'));
select expect_num('...and the member keeps the booking on it',
  (select count(*) from bookings
    where id='deeddeed-0000-0000-0000-00000000bb01' and status='booked')::bigint, 1);

-- Every real occurrence the generator made against demo series, not just that one.
select expect_true('every real occurrence survives, not merely the fixture one',
  (select count(*) > 1 from class_occurrences
    where studio_id='deeddeed-0000-0000-0000-000000000001' and not is_demo));

-- The census the function does on itself.
select expect_true('the purge reports what it kept',
  (current_setting('t.purge')::jsonb -> 'real_rows_kept') is not null);
select expect_true('and nothing real went missing between before and after',
  (select bool_and((current_setting('t.purge')::jsonb -> 'real_rows_kept' ->> k)::int
                   >= (current_setting('t.before')::jsonb ->> k)::int)
     from jsonb_object_keys(current_setting('t.before')::jsonb) k));

-- =============================================================================
-- generate_demo_data can be re-run afterwards
-- =============================================================================
-- Its ids are derived from the studio id, so a second generation writes the
-- same primary keys — which is only safe if the purge really removed them.
set role authenticated;
select set_config('request.jwt.claim.sub','deeddeed-0000-0000-0000-0000000000a1',false);
select set_config('t.gen2', (select generate_demo_data('deeddeed-0000-0000-0000-000000000001')::text), false);
reset role;
select expect_true('demo data regenerates cleanly after a purge',
  (current_setting('t.gen2')::jsonb ->> 'occurrences')::int > 0);
select expect_num('...and the real rows are still there afterwards',
  (select count(*) from instructors
    where studio_id='deeddeed-0000-0000-0000-000000000001' and not is_demo)::bigint, 2);
select expect_num('...and the real class is still there too',
  (select count(*) from class_occurrences
    where id='deeddeed-0000-0000-0000-00000000f001')::bigint, 1);

-- And purging again is clean.
set role authenticated;
select set_config('request.jwt.claim.sub','deeddeed-0000-0000-0000-0000000000a1',false);
select expect_true('a second purge runs and still keeps the real rows',
  (purge_demo_data('deeddeed-0000-0000-0000-000000000001') ->> 'real_rows_kept') is not null);
reset role;
select expect_num('real instructors still there after two rounds',
  (select count(*) from instructors
    where studio_id='deeddeed-0000-0000-0000-000000000001' and not is_demo)::bigint, 2);
select expect_num('real availability still there after two rounds',
  (select count(*) from instructor_availability
    where instructor_id='deeddeed-0000-0000-0000-00000000d101')::bigint, 5);

-- Only a platform admin, unchanged.
set role authenticated;
select set_config('request.jwt.claim.sub','deeddeed-0000-0000-0000-0000000000a1',false);
reset role;
insert into auth.users (id) values ('deeddeed-0000-0000-0000-0000000000b9');
insert into profiles (id, email, full_name) values
  ('deeddeed-0000-0000-0000-0000000000b9','notops@example.com','Not Ops');
set role authenticated;
select set_config('request.jwt.claim.sub','deeddeed-0000-0000-0000-0000000000b9',false);
select expect_raises('a signed-in user who is not a platform admin cannot purge',
  $q$select purge_demo_data('deeddeed-0000-0000-0000-000000000001')$q$, 'PT403');
