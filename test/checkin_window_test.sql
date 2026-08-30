-- =============================================================================
-- STUDIIOR — CHECK-IN WINDOW TEST (Business Rules §8, migration 007)
--
-- The window opens 60 minutes before the class starts and closes 30 minutes
-- after it ends. Enforced by a trigger, so it holds on every insert path.
--
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -f test/checkin_window_test.sql
--
-- Local stack only — it inserts fixtures.
-- =============================================================================

\set ON_ERROR_STOP on
set client_min_messages = notice;

create or replace function expect_checkin(label text, p_booking uuid, p_member uuid,
                                          p_occ uuid, p_studio uuid, p_at timestamptz,
                                          want_ok boolean)
returns void language plpgsql as $$
declare got_ok boolean;
begin
  begin
    insert into check_ins (studio_id, booking_id, member_id, occurrence_id,
                           checked_in_at, method)
    values (p_studio, p_booking, p_member, p_occ, p_at, 'staff');
    got_ok := true;
    delete from check_ins where booking_id = p_booking;   -- leave no trace
  exception when others then
    got_ok := false;
  end;

  if got_ok = want_ok then
    raise notice 'PASS  %  (%)', label, case when got_ok then 'accepted' else 'refused' end;
  else
    raise exception 'FAIL  %  expected %, got %', label,
      case when want_ok then 'accepted' else 'refused' end,
      case when got_ok then 'accepted' else 'refused' end;
  end if;
end $$;

-- --- Fixtures: studio W, its own UUID space -------------------------------

insert into studios (id, name, slug, timezone, currency) values
  ('99999999-0000-0000-0000-000000000001','Window Studio','window-test','Europe/Prague','CZK');
insert into studio_settings (studio_id) values ('99999999-0000-0000-0000-000000000001');
insert into locations (id, studio_id, name) values
  ('99999999-0000-0000-0000-00000000000c','99999999-0000-0000-0000-000000000001','Main');

-- A class that started an hour ago and ended ten minutes ago, so "before",
-- "during" and "after" are all expressible relative to now().
insert into class_occurrences
  (id, studio_id, location_id, name, capacity, starts_at, ends_at, status)
values
  ('99999999-0000-0000-0000-0000000000f1','99999999-0000-0000-0000-000000000001',
   '99999999-0000-0000-0000-00000000000c','Reformer Flow', 8,
   now() - interval '60 minutes', now() - interval '10 minutes', 'completed');

insert into members (id, studio_id, first_name, last_name, email, waiver_signed_at) values
  ('99999999-0000-0000-0000-0000000000d1','99999999-0000-0000-0000-000000000001',
   'Wanda','Windowtest','wanda.windowtest@example.com', now());

insert into bookings (id, studio_id, occurrence_id, member_id, status, source) values
  ('99999999-0000-0000-0000-0000000000b1','99999999-0000-0000-0000-000000000001',
   '99999999-0000-0000-0000-0000000000f1','99999999-0000-0000-0000-0000000000d1',
   'booked','member');

-- =============================================================================
-- 1. The window, with defaults (opens 60 before start, closes 30 after end)
-- =============================================================================

-- starts_at is now-60m, so the window opened at now-120m.
select expect_checkin('61 minutes before start is too early',
  '99999999-0000-0000-0000-0000000000b1','99999999-0000-0000-0000-0000000000d1',
  '99999999-0000-0000-0000-0000000000f1','99999999-0000-0000-0000-000000000001',
  now() - interval '121 minutes', false);

select expect_checkin('exactly 60 minutes before start is inside',
  '99999999-0000-0000-0000-0000000000b1','99999999-0000-0000-0000-0000000000d1',
  '99999999-0000-0000-0000-0000000000f1','99999999-0000-0000-0000-000000000001',
  now() - interval '120 minutes', true);

select expect_checkin('at the start time',
  '99999999-0000-0000-0000-0000000000b1','99999999-0000-0000-0000-0000000000d1',
  '99999999-0000-0000-0000-0000000000f1','99999999-0000-0000-0000-000000000001',
  now() - interval '60 minutes', true);

-- §8: late arrival still counts as attended, so mid-class must be accepted.
select expect_checkin('late arrival, mid-class, still counts',
  '99999999-0000-0000-0000-0000000000b1','99999999-0000-0000-0000-0000000000d1',
  '99999999-0000-0000-0000-0000000000f1','99999999-0000-0000-0000-000000000001',
  now() - interval '30 minutes', true);

-- ends_at is now-10m, so the window closes at now+20m.
select expect_checkin('20 minutes after the end is still inside',
  '99999999-0000-0000-0000-0000000000b1','99999999-0000-0000-0000-0000000000d1',
  '99999999-0000-0000-0000-0000000000f1','99999999-0000-0000-0000-000000000001',
  now() + interval '19 minutes', true);

select expect_checkin('31 minutes after the end is too late',
  '99999999-0000-0000-0000-0000000000b1','99999999-0000-0000-0000-0000000000d1',
  '99999999-0000-0000-0000-0000000000f1','99999999-0000-0000-0000-000000000001',
  now() + interval '21 minutes', false);

select expect_checkin('a day early is refused',
  '99999999-0000-0000-0000-0000000000b1','99999999-0000-0000-0000-0000000000d1',
  '99999999-0000-0000-0000-0000000000f1','99999999-0000-0000-0000-000000000001',
  now() - interval '1 day', false);

-- =============================================================================
-- 2. The bounds are settings, not constants in the trigger
-- =============================================================================

update studio_settings set checkin_opens_minutes_before = 240
 where studio_id = '99999999-0000-0000-0000-000000000001';

select expect_checkin('widening the setting widens the window',
  '99999999-0000-0000-0000-0000000000b1','99999999-0000-0000-0000-0000000000d1',
  '99999999-0000-0000-0000-0000000000f1','99999999-0000-0000-0000-000000000001',
  now() - interval '121 minutes', true);

update studio_settings set checkin_opens_minutes_before = 60
 where studio_id = '99999999-0000-0000-0000-000000000001';

-- =============================================================================
-- 3. The documented escape hatch
-- =============================================================================

update studio_settings set checkin_window_enforced = false
 where studio_id = '99999999-0000-0000-0000-000000000001';

select expect_checkin('with enforcement off, a day early is accepted',
  '99999999-0000-0000-0000-0000000000b1','99999999-0000-0000-0000-0000000000d1',
  '99999999-0000-0000-0000-0000000000f1','99999999-0000-0000-0000-000000000001',
  now() - interval '1 day', true);

update studio_settings set checkin_window_enforced = true
 where studio_id = '99999999-0000-0000-0000-000000000001';

select expect_checkin('and switching it back on refuses again',
  '99999999-0000-0000-0000-0000000000b1','99999999-0000-0000-0000-0000000000d1',
  '99999999-0000-0000-0000-0000000000f1','99999999-0000-0000-0000-000000000001',
  now() - interval '1 day', false);

-- =============================================================================
-- 4. It is a trigger, so it holds on paths that never touch the app
-- =============================================================================

do $$
declare seeded int;
begin
  -- The seed writes 700+ historical check-ins directly. If the trigger were
  -- wrong about the window, db reset itself would have failed.
  select count(*) into seeded from check_ins
   where studio_id = '11111111-0000-0000-0000-000000000001';
  if seeded < 100 then
    raise exception 'FAIL  expected the seed to have written check-ins, found %', seeded;
  end if;
  raise notice 'PASS  seeded historical check-ins pass the window  (got %)', seeded;
end $$;

select 'ALL CHECK-IN WINDOW TESTS PASSED' as result;
