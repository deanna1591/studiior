-- =============================================================================
-- A one-off class can carry a guarantee tier (144). UUID space 0f17.
-- =============================================================================
-- create_occurrence() gains p_tier + p_min_bookings, set the set_series_guarantee
-- way. A flex one-off with nothing of the instructor's beside it comes back with
-- a `standalone_flex` warning — the one-off analog of standalone_count — and never
-- a refusal. Run after `supabase db reset`.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_txt(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin if actual then raise notice 'PASS  %', label; else raise exception 'FAIL  %  expected true', label; end if; end $$;

-- Call create_occurrence as a manager and return the result.
create or replace function co(uid text, studio uuid, ct uuid, room uuid, instr uuid,
                              tier text, minb int, startt timestamptz) returns jsonb
language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claim.sub', uid, true); set local role authenticated;
  begin
    select create_occurrence(studio, ct, startt, startt + interval '50 min',
                             instr, room, null, tier::guarantee_tier, minb) into r;
  exception when others then r := jsonb_build_object('err', sqlstate); end;
  reset role;
  return r;
end $$;
create or replace function warns(res jsonb, w text) returns boolean language sql as $$
  select coalesce((select bool_or(x = w) from jsonb_array_elements_text(res -> 'warnings') x), false);
$$;

-- --- Fixtures ----------------------------------------------------------------
-- Studio ON runs flex + guarantees; Studio OFF has flex off (the inert case).
insert into auth.users (id) values ('0f170f17-0000-0000-0000-0000000000a1');
insert into profiles (id, email) values ('0f170f17-0000-0000-0000-0000000000a1','0f17-own@example.com');
insert into studios (id,name,slug,timezone,currency,status) values
  ('0f170f17-0000-0000-0000-000000000001','Tier On','0f17-a','UTC','USD','active'),
  ('0f170f17-0000-0000-0000-000000000002','Tier Off','0f17-b','UTC','USD','active');
insert into studio_settings (studio_id, guarantees_enabled, flex_enabled, flex_min_bookings, core_min_bookings) values
  ('0f170f17-0000-0000-0000-000000000001', true,  true, 2, 3),
  ('0f170f17-0000-0000-0000-000000000002', false, false, 1, 1);
insert into studio_staff (id,studio_id,user_id,email,role) values
  ('0f170f17-0000-0000-0000-0000000a0001','0f170f17-0000-0000-0000-000000000001','0f170f17-0000-0000-0000-0000000000a1','0f17-o1@example.com','owner'),
  ('0f170f17-0000-0000-0000-0000000a0002','0f170f17-0000-0000-0000-000000000002','0f170f17-0000-0000-0000-0000000000a1','0f17-o2@example.com','owner');
insert into locations (id,studio_id,name,is_primary) values
  ('0f170f17-0000-0000-0000-00000000000a','0f170f17-0000-0000-0000-000000000001','M',true),
  ('0f170f17-0000-0000-0000-00000000000b','0f170f17-0000-0000-0000-000000000002','M',true);
insert into rooms (id,studio_id,location_id,name,capacity) values
  ('0f170f17-0000-0000-0000-0000000ee001','0f170f17-0000-0000-0000-000000000001','0f170f17-0000-0000-0000-00000000000a','R',8),
  ('0f170f17-0000-0000-0000-0000000ee002','0f170f17-0000-0000-0000-000000000002','0f170f17-0000-0000-0000-00000000000b','R',8);
insert into class_types (id,studio_id,name,duration_minutes,default_capacity) values
  ('0f170f17-0000-0000-0000-0000000cc001','0f170f17-0000-0000-0000-000000000001','Reformer',50,8),
  ('0f170f17-0000-0000-0000-0000000cc002','0f170f17-0000-0000-0000-000000000002','Reformer',50,8);
insert into instructors (id,studio_id,display_name,status) values
  ('0f170f17-0000-0000-0000-0000000d0001','0f170f17-0000-0000-0000-000000000001','Ivy','active'),
  ('0f170f17-0000-0000-0000-0000000d0002','0f170f17-0000-0000-0000-000000000001','Bea','active'),
  ('0f170f17-0000-0000-0000-0000000d0005','0f170f17-0000-0000-0000-000000000002','Eve','active');

\set U '0f170f17-0000-0000-0000-0000000000a1'
\set SON '0f170f17-0000-0000-0000-000000000001'
\set CT '0f170f17-0000-0000-0000-0000000cc001'
\set RM '0f170f17-0000-0000-0000-0000000ee001'
\set IVY '0f170f17-0000-0000-0000-0000000d0001'

-- =============================================================================
-- FLEX standalone: Ivy, nobody of hers beside it -> flagged.
-- =============================================================================
select co(:'U', :'SON', :'CT', :'RM', :'IVY', 'flex', null, '2026-12-05 10:00+00') as r \gset
select expect_true('a flex one-off is created (a warning, not a refusal)', (:'r'::jsonb ->> 'ok')::boolean);
select expect_true('a standalone flex one-off carries the standby warning',
  warns(:'r'::jsonb, 'standalone_flex'));
select expect_txt('the occurrence is stored flex',
  (select guarantee_tier::text from class_occurrences where id = (:'r'::jsonb ->> 'occurrence_id')::uuid), 'flex');
select expect_true('flex flag is set and the minimum falls back to the studio''s flex_min_bookings (2)',
  (select flex and minimum_bookings = 2 from class_occurrences where id = (:'r'::jsonb ->> 'occurrence_id')::uuid));

-- =============================================================================
-- CORE: no standalone warning; core_min_bookings falls back to the studio's (3).
-- =============================================================================
select co(:'U', :'SON', :'CT', :'RM', :'IVY', 'core', null, '2026-12-06 10:00+00') as r \gset
select expect_true('a core one-off does not carry the standalone warning',
  not warns(:'r'::jsonb, 'standalone_flex'));
select expect_true('core stored, flex off, core_min_bookings = 3',
  (select guarantee_tier = 'core' and not flex and core_min_bookings = 3
     from class_occurrences where id = (:'r'::jsonb ->> 'occurrence_id')::uuid));

-- =============================================================================
-- ALWAYS: runs regardless; never standalone-flagged.
-- =============================================================================
select co(:'U', :'SON', :'CT', :'RM', :'IVY', 'always', null, '2026-12-07 10:00+00') as r \gset
select expect_true('an always one-off carries no standalone warning',
  not warns(:'r'::jsonb, 'standalone_flex'));
select expect_txt('always stored',
  (select guarantee_tier::text from class_occurrences where id = (:'r'::jsonb ->> 'occurrence_id')::uuid), 'always');

-- =============================================================================
-- FLEX with a class of the SAME instructor beside it -> NOT standalone.
-- Ivy already teaches 09:00-09:50 that day (created here), the flex one is 10:00.
-- =============================================================================
insert into class_occurrences (id,studio_id,location_id,class_type_id,room_id,instructor_id,name,starts_at,ends_at,capacity,status)
 values ('0f170f17-0000-0000-0000-00000000c0aa',:'SON','0f170f17-0000-0000-0000-00000000000a',:'CT',:'RM',:'IVY','Neighbour','2026-12-08 09:00+00','2026-12-08 09:50+00',8,'scheduled');
select co(:'U', :'SON', :'CT', :'RM', :'IVY', 'flex', null, '2026-12-08 10:00+00') as r \gset
select expect_true('a flex one-off next to another class of the same instructor is NOT standalone',
  (:'r'::jsonb ->> 'ok')::boolean and not warns(:'r'::jsonb, 'standalone_flex'));

-- =============================================================================
-- FLEX at a studio with flex OFF: the tier is stored but inert, so no warning.
-- =============================================================================
select co(:'U', '0f170f17-0000-0000-0000-000000000002', '0f170f17-0000-0000-0000-0000000cc002',
          '0f170f17-0000-0000-0000-0000000ee002', '0f170f17-0000-0000-0000-0000000d0005',
          'flex', null, '2026-12-09 10:00+00') as r \gset
select expect_true('a flex one-off at a flex-off studio raises no standalone warning (inert)',
  (:'r'::jsonb ->> 'ok')::boolean and not warns(:'r'::jsonb, 'standalone_flex'));

-- =============================================================================
-- Teeth / back-compat.
-- =============================================================================
select expect_txt('a negative minimum is refused',
  (co(:'U', :'SON', :'CT', :'RM', :'IVY', 'flex', -1, '2026-12-10 10:00+00') ->> 'err'), 'PT422');
-- The 7-arg default path (no tier) still makes a core class.
do $$
declare r jsonb;
begin
  perform set_config('request.jwt.claim.sub', '0f170f17-0000-0000-0000-0000000000a1', true);
  set local role authenticated;
  select create_occurrence('0f170f17-0000-0000-0000-000000000001','0f170f17-0000-0000-0000-0000000cc001',
    '2026-12-11 10:00+00','2026-12-11 10:50+00','0f170f17-0000-0000-0000-0000000d0002',
    '0f170f17-0000-0000-0000-0000000ee001') into r;
  reset role;
  if (select guarantee_tier from class_occurrences where id = (r ->> 'occurrence_id')::uuid) is not distinct from 'core'::guarantee_tier
     or (select guarantee_tier from class_occurrences where id = (r ->> 'occurrence_id')::uuid) is null then
    raise notice 'PASS  the default (no-tier) create path still makes a core class';
  else raise exception 'FAIL  default create path did not make core'; end if;
end $$;

do $$ begin raise notice 'one_off_tier_test: all assertions passed'; end $$;
