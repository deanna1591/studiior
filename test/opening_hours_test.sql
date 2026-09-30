-- =============================================================================
-- Studio opening hours (Decision 44). UUID space 0d44.
-- =============================================================================
-- A studio may set one opening window (open_time, close_time, studio-local).
-- Optional, unset by default. A class INSIDE hours starts within [open, close]
-- (the end may run past close). Outside is a WARNING at creation, never a block.
-- occurrence_outside_hours is the one predicate; false when hours are unset.
-- Run after `supabase db reset`.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin if actual then raise notice 'PASS  %', label; else raise exception 'FAIL  %  expected true', label; end if; end $$;
create or replace function expect_false(label text, actual boolean)
returns void language plpgsql as $$
begin if not actual then raise notice 'PASS  %', label; else raise exception 'FAIL  %  expected false', label; end if; end $$;

-- create_occurrence as a manager; returns the result jsonb (or the sqlstate).
create or replace function co44(uid text, studio uuid, ct uuid, room uuid, startt timestamptz) returns jsonb
language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claim.sub', uid, true); set local role authenticated;
  begin
    select create_occurrence(studio, ct, startt, startt + interval '50 min', null, room) into r;
  exception when others then r := jsonb_build_object('err', sqlstate); end;
  reset role;
  return r;
end $$;
create or replace function warns44(res jsonb, w text) returns boolean language sql as $$
  select coalesce((select bool_or(x = w) from jsonb_array_elements_text(res -> 'warnings') x), false);
$$;

-- --- Fixtures ----------------------------------------------------------------
-- Studio A: Europe/Prague, opening 06:00–22:00. Studio B: Asia/Manila, same
-- window. Studio C: no hours set (the unset case).
insert into auth.users (id) values ('0d440d44-0000-0000-0000-0000000000a1');
insert into profiles (id, email) values ('0d440d44-0000-0000-0000-0000000000a1','0d44-own@example.com');
insert into studios (id,name,slug,timezone,currency,status) values
  ('0d440d44-0000-0000-0000-000000000001','Hours Prague','0d44-a','Europe/Prague','CZK','active'),
  ('0d440d44-0000-0000-0000-000000000002','Hours Manila','0d44-b','Asia/Manila','PHP','active'),
  ('0d440d44-0000-0000-0000-000000000003','No Hours','0d44-c','Europe/Prague','CZK','active');
insert into studio_settings (studio_id, open_time, close_time) values
  ('0d440d44-0000-0000-0000-000000000001','06:00','22:00'),
  ('0d440d44-0000-0000-0000-000000000002','06:00','22:00'),
  ('0d440d44-0000-0000-0000-000000000003', null,   null);
insert into studio_staff (id,studio_id,user_id,email,role) values
  ('0d440d44-0000-0000-0000-0000000a0001','0d440d44-0000-0000-0000-000000000001','0d440d44-0000-0000-0000-0000000000a1','0d44-o1@example.com','owner'),
  ('0d440d44-0000-0000-0000-0000000a0002','0d440d44-0000-0000-0000-000000000002','0d440d44-0000-0000-0000-0000000000a1','0d44-o2@example.com','owner'),
  ('0d440d44-0000-0000-0000-0000000a0003','0d440d44-0000-0000-0000-000000000003','0d440d44-0000-0000-0000-0000000000a1','0d44-o3@example.com','owner');
insert into locations (id,studio_id,name,is_primary) values
  ('0d440d44-0000-0000-0000-00000000000a','0d440d44-0000-0000-0000-000000000001','M',true),
  ('0d440d44-0000-0000-0000-00000000000b','0d440d44-0000-0000-0000-000000000002','M',true),
  ('0d440d44-0000-0000-0000-00000000000c','0d440d44-0000-0000-0000-000000000003','M',true);
insert into rooms (id,studio_id,location_id,name,capacity) values
  ('0d440d44-0000-0000-0000-0000000ee001','0d440d44-0000-0000-0000-000000000001','0d440d44-0000-0000-0000-00000000000a','R',8),
  ('0d440d44-0000-0000-0000-0000000ee002','0d440d44-0000-0000-0000-000000000002','0d440d44-0000-0000-0000-00000000000b','R',8),
  ('0d440d44-0000-0000-0000-0000000ee003','0d440d44-0000-0000-0000-000000000003','0d440d44-0000-0000-0000-00000000000c','R',8);
insert into class_types (id,studio_id,name,duration_minutes,default_capacity) values
  ('0d440d44-0000-0000-0000-0000000cc001','0d440d44-0000-0000-0000-000000000001','Reformer',50,8),
  ('0d440d44-0000-0000-0000-0000000cc002','0d440d44-0000-0000-0000-000000000002','Reformer',50,8),
  ('0d440d44-0000-0000-0000-0000000cc003','0d440d44-0000-0000-0000-000000000003','Reformer',50,8);

-- =============================================================================
-- 1. The CHECK constraint: both-or-neither, open < close.
-- =============================================================================
do $$ begin
  begin
    update studio_settings set open_time='22:00', close_time='06:00'
     where studio_id='0d440d44-0000-0000-0000-000000000001';
    raise exception 'FAIL  open >= close was accepted';
  exception when check_violation then raise notice 'PASS  open >= close is rejected';
  end;
end $$;
do $$ begin
  begin
    update studio_settings set open_time='06:00', close_time=null
     where studio_id='0d440d44-0000-0000-0000-000000000001';
    raise exception 'FAIL  one set one null was accepted';
  exception when check_violation then raise notice 'PASS  one set and one null is rejected';
  end;
end $$;

-- =============================================================================
-- 2. occurrence_outside_hours — the predicate.
-- =============================================================================
-- Prague 06:00–22:00.
select expect_false('a 22:00 start is INSIDE (close is inclusive; the class ends past close)',
  occurrence_outside_hours('0d440d44-0000-0000-0000-000000000001',
    ('2026-11-16 22:00'::timestamp at time zone 'Europe/Prague')));
select expect_true('a 22:15 start is OUTSIDE',
  occurrence_outside_hours('0d440d44-0000-0000-0000-000000000001',
    ('2026-11-16 22:15'::timestamp at time zone 'Europe/Prague')));
select expect_true('a 05:45 start is OUTSIDE',
  occurrence_outside_hours('0d440d44-0000-0000-0000-000000000001',
    ('2026-11-16 05:45'::timestamp at time zone 'Europe/Prague')));
select expect_false('a 07:00 start is INSIDE',
  occurrence_outside_hours('0d440d44-0000-0000-0000-000000000001',
    ('2026-11-16 07:00'::timestamp at time zone 'Europe/Prague')));

-- Timezone: a class stored in UTC that is 07:00 in Manila is INSIDE, judged in
-- the studio's own zone (07:00 Manila = 23:00 UTC the previous day).
select expect_false('07:00 Manila (stored UTC) is inside — judged in the studio zone',
  occurrence_outside_hours('0d440d44-0000-0000-0000-000000000002',
    ('2026-11-16 07:00'::timestamp at time zone 'Asia/Manila')));
select expect_true('...and a 23:00 UTC INSTANT is 07:00 Manila, still inside',
  not occurrence_outside_hours('0d440d44-0000-0000-0000-000000000002', '2026-11-15 23:00+00'::timestamptz));

-- Unset (Studio C): nothing is ever outside.
select expect_false('hours unset -> occurrence_outside_hours is false (whatever the time)',
  occurrence_outside_hours('0d440d44-0000-0000-0000-000000000003',
    ('2026-11-16 03:00'::timestamp at time zone 'Europe/Prague')));

-- =============================================================================
-- 3. create_occurrence surfaces 'outside_hours' as a WARNING, never a block.
-- =============================================================================
-- Each on a DISTINCT day so the late classes do not clash in the one room.
-- 22:15 Prague -> outside -> warned AND created.
select expect_true('a 22:15 one-off is created (ok)',
  (co44('0d440d44-0000-0000-0000-0000000000a1','0d440d44-0000-0000-0000-000000000001',
        '0d440d44-0000-0000-0000-0000000cc001','0d440d44-0000-0000-0000-0000000ee001',
        ('2026-11-16 22:15'::timestamp at time zone 'Europe/Prague')) ->> 'ok')::boolean);
select expect_true('...and carries the outside_hours warning',
  warns44(co44('0d440d44-0000-0000-0000-0000000000a1','0d440d44-0000-0000-0000-000000000001',
        '0d440d44-0000-0000-0000-0000000cc001','0d440d44-0000-0000-0000-0000000ee001',
        ('2026-11-17 22:20'::timestamp at time zone 'Europe/Prague')), 'outside_hours'));

-- 22:00 Prague -> inside -> no warning.
select expect_false('a 22:00 one-off carries NO outside_hours warning (inside)',
  warns44(co44('0d440d44-0000-0000-0000-0000000000a1','0d440d44-0000-0000-0000-000000000001',
        '0d440d44-0000-0000-0000-0000000cc001','0d440d44-0000-0000-0000-0000000ee001',
        ('2026-11-18 22:00'::timestamp at time zone 'Europe/Prague')), 'outside_hours'));

-- 05:45 Prague -> outside -> warned.
select expect_true('a 05:45 one-off carries the outside_hours warning',
  warns44(co44('0d440d44-0000-0000-0000-0000000000a1','0d440d44-0000-0000-0000-000000000001',
        '0d440d44-0000-0000-0000-0000000cc001','0d440d44-0000-0000-0000-0000000ee001',
        ('2026-11-19 05:45'::timestamp at time zone 'Europe/Prague')), 'outside_hours'));

-- Unset studio (C): a 03:00 class is never flagged (the all_off posture).
select expect_false('hours unset -> no outside_hours warning even at 03:00',
  warns44(co44('0d440d44-0000-0000-0000-0000000000a1','0d440d44-0000-0000-0000-000000000003',
        '0d440d44-0000-0000-0000-0000000cc003','0d440d44-0000-0000-0000-0000000ee003',
        ('2026-11-20 03:00'::timestamp at time zone 'Europe/Prague')), 'outside_hours'));

select 'opening_hours_test: all assertions passed' as result;
