-- =============================================================================
-- Decision 42b — bulk changes on recurring classes. UUID space b012, checked free.
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
create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual,'null'); end if;
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

-- A weekday three days out and the same weekday a week later, both in horizon;
-- the series rule repeats weekly on that day.
select set_config('t.by',  upper(left(to_char((current_date + 3)::date, 'Dy'), 2)), false);
select set_config('t.d1',  (current_date + 3)::text, false);
select set_config('t.d2',  (current_date + 10)::text, false);
select set_config('t.past',(current_date - 7)::text, false);

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('b012b012-0000-0000-0000-0000000000a1'),  -- owner
  ('b012b012-0000-0000-0000-0000000000a2'),  -- manager
  ('b012b012-0000-0000-0000-0000000000a3');  -- instructor (non-manager)
insert into profiles (id, email) values
  ('b012b012-0000-0000-0000-0000000000a1','b012-owner@example.com'),
  ('b012b012-0000-0000-0000-0000000000a2','b012-mgr@example.com'),
  ('b012b012-0000-0000-0000-0000000000a3','b012-instr@example.com');

insert into studios (id, name, slug, timezone, currency, status) values
  ('b012b012-0000-0000-0000-000000000001','Bulk','b012-a','Europe/Prague','CZK','active'),
  ('b012b012-0000-0000-0000-0000000000ff','Other','b012-f','Europe/Prague','CZK','active');
insert into studio_settings (studio_id, guarantees_enabled, flex_enabled) values
  ('b012b012-0000-0000-0000-000000000001', true, true),
  ('b012b012-0000-0000-0000-0000000000ff', true, true);
insert into locations (id, studio_id, name, is_primary) values
  ('b012b012-0000-0000-0000-0000000000aa','b012b012-0000-0000-0000-000000000001','Main',true),
  ('b012b012-0000-0000-0000-0000000000af','b012b012-0000-0000-0000-0000000000ff','Main',true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('b012b012-0000-0000-0000-000000001a01','b012b012-0000-0000-0000-000000000001','b012b012-0000-0000-0000-0000000000aa','R1',10),
  ('b012b012-0000-0000-0000-000000001b01','b012b012-0000-0000-0000-000000000001','b012b012-0000-0000-0000-0000000000aa','R2',10),
  ('b012b012-0000-0000-0000-0000000f1001','b012b012-0000-0000-0000-0000000000ff','b012b012-0000-0000-0000-0000000000af','RF',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('b012b012-0000-0000-0000-000000007c01','b012b012-0000-0000-0000-000000000001','Reformer',50,10),
  ('b012b012-0000-0000-0000-0000000f7c01','b012b012-0000-0000-0000-0000000000ff','Reformer',50,10);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('b012b012-0000-0000-0000-000000055a01','b012b012-0000-0000-0000-000000000001','b012b012-0000-0000-0000-0000000000a1','b012-owner@example.com','owner'),
  ('b012b012-0000-0000-0000-000000055a02','b012b012-0000-0000-0000-000000000001','b012b012-0000-0000-0000-0000000000a2','b012-mgr@example.com','manager'),
  ('b012b012-0000-0000-0000-000000055a03','b012b012-0000-0000-0000-000000000001','b012b012-0000-0000-0000-0000000000a3','b012-instr@example.com','instructor');
insert into instructors (id, studio_id, display_name, staff_id) values
  ('b012b012-0000-0000-0000-00000000f101','b012b012-0000-0000-0000-000000000001','Fay One',null),
  ('b012b012-0000-0000-0000-00000000f202','b012b012-0000-0000-0000-000000000001','Gus Two',null);
insert into members (id, studio_id, first_name, last_name, email) values
  ('b012b012-0000-0000-0000-00000003e001','b012b012-0000-0000-0000-000000000001','Mem','One','b012-m@example.com');

-- Build every occurrence by hand (materialise trigger off) so each test's rows
-- are exactly known. update_series calls generate_occurrences directly, so its
-- own adds are unaffected by this.
alter table class_series disable trigger class_series_materialise;

-- Series. Flex (min 2) for minimum/tier/preview; core for room/dates/instructor.
insert into class_series (id, studio_id, location_id, class_type_id, name, room_id, instructor_id,
   capacity, duration_minutes, rrule, starts_on, time_of_day, guarantee_tier, flex, minimum_bookings, status)
select v.id, 'b012b012-0000-0000-0000-000000000001','b012b012-0000-0000-0000-0000000000aa',
       'b012b012-0000-0000-0000-000000007c01', v.name, v.room, v.instr, 10, 50,
       'FREQ=WEEKLY;BYDAY=' || current_setting('t.by'),
       (current_date - 14), v.tm::time, v.tier::guarantee_tier, (v.tier='flex'), v.min, 'active'
from (values
  -- Distinct per-series times so occurrences never overlap in a room, and the
  -- series time matches its occurrences (a room change moves no times).
  ('b012b012-0000-0000-0000-000000005a01'::uuid,'Min A','06:00','b012b012-0000-0000-0000-000000001a01'::uuid, null::uuid, 'flex', 2),
  ('b012b012-0000-0000-0000-000000005b01'::uuid,'Min B','07:00','b012b012-0000-0000-0000-000000001a01'::uuid, null, 'flex', 2),
  ('b012b012-0000-0000-0000-000000005c01'::uuid,'Min C','08:00','b012b012-0000-0000-0000-000000001a01'::uuid, null, 'flex', 2),
  ('b012b012-0000-0000-0000-000000005e01'::uuid,'Tier', '09:00','b012b012-0000-0000-0000-000000001a01'::uuid, null, 'flex', 2),
  ('b012b012-0000-0000-0000-000000005d01'::uuid,'Prev', '10:00','b012b012-0000-0000-0000-000000001a01'::uuid, null, 'flex', 2),
  ('b012b012-0000-0000-0000-00000000e501'::uuid,'Instr','11:00','b012b012-0000-0000-0000-000000001a01'::uuid,'b012b012-0000-0000-0000-00000000f202'::uuid,'core', null),
  ('b012b012-0000-0000-0000-000000002001'::uuid,'Room OK','12:00','b012b012-0000-0000-0000-000000001a01'::uuid, null,'core', null),
  ('b012b012-0000-0000-0000-0000000020c1'::uuid,'Room Clash','13:00','b012b012-0000-0000-0000-000000001a01'::uuid, null,'core', null),
  ('b012b012-0000-0000-0000-00000000b101'::uuid,'Blocker','13:00','b012b012-0000-0000-0000-000000001b01'::uuid, null,'core', null),
  ('b012b012-0000-0000-0000-0000000eb001'::uuid,'Ends Book','14:00','b012b012-0000-0000-0000-000000001a01'::uuid, null,'core', null),
  ('b012b012-0000-0000-0000-0000000e0001'::uuid,'Ends OK','15:00','b012b012-0000-0000-0000-000000001a01'::uuid, null,'core', null),
  ('b012b012-0000-0000-0000-0000000a7001'::uuid,'Starts','16:00','b012b012-0000-0000-0000-000000001a01'::uuid, null,'core', null)
) as v(id,name,tm,room,instr,tier,min);

insert into class_series (id, studio_id, location_id, class_type_id, name, room_id, instructor_id,
   capacity, duration_minutes, rrule, starts_on, time_of_day, guarantee_tier, flex, minimum_bookings, status)
values ('b012b012-0000-0000-0000-00000000f051','b012b012-0000-0000-0000-0000000000ff','b012b012-0000-0000-0000-0000000000af',
        'b012b012-0000-0000-0000-0000000f7c01','Foreign',null,null,10,50,
        'FREQ=WEEKLY;BYDAY=' || current_setting('t.by'), (current_date - 14), '09:00'::time, 'flex', true, 2, 'active');

-- Occurrences. d1 09:00 unless noted; flex series carry flex+min, core series core.
insert into class_occurrences
  (id, studio_id, location_id, class_type_id, room_id, series_id, series_slot_at, name, capacity,
   instructor_id, staffing, starts_at, ends_at, status, booked_count, guarantee_tier, flex, minimum_bookings)
select o.id, 'b012b012-0000-0000-0000-000000000001','b012b012-0000-0000-0000-0000000000aa',
       'b012b012-0000-0000-0000-000000007c01', o.room, o.series,
       (o.day::date + o.tm) at time zone 'Europe/Prague', 'Bulk', 10, o.instr,
       (case when o.instr is null then 'open' else 'assigned' end)::staffing_state,
       (o.day::date + o.tm) at time zone 'Europe/Prague',
       (o.day::date + o.tm) at time zone 'Europe/Prague' + interval '50 min',
       o.st::occurrence_status, o.booked, o.tier::guarantee_tier, (o.tier='flex'), o.min
from (values
  -- Min A: future scheduled (updated), past (untouched), cancelled (untouched)
  ('b012b012-0000-0000-0000-000000000c01'::uuid,'b012b012-0000-0000-0000-000000005a01'::uuid,'b012b012-0000-0000-0000-000000001a01'::uuid,null::uuid, current_setting('t.d1'),'06:00'::time,'scheduled',0,'flex',2),
  ('b012b012-0000-0000-0000-000000000c02'::uuid,'b012b012-0000-0000-0000-000000005a01'::uuid,'b012b012-0000-0000-0000-000000001a01'::uuid,null,            current_setting('t.past'),'06:00'::time,'scheduled',0,'flex',2),
  ('b012b012-0000-0000-0000-000000000c03'::uuid,'b012b012-0000-0000-0000-000000005a01'::uuid,'b012b012-0000-0000-0000-000000001a01'::uuid,null,            current_setting('t.d2'),'06:00'::time,'cancelled',0,'flex',2),
  ('b012b012-0000-0000-0000-000000000c04'::uuid,'b012b012-0000-0000-0000-000000005b01'::uuid,'b012b012-0000-0000-0000-000000001a01'::uuid,null,            current_setting('t.d1'),'07:00'::time,'scheduled',0,'flex',2),
  ('b012b012-0000-0000-0000-000000000c05'::uuid,'b012b012-0000-0000-0000-000000005c01'::uuid,'b012b012-0000-0000-0000-000000001a01'::uuid,null,            current_setting('t.d1'),'08:00'::time,'scheduled',0,'flex',2),
  -- Tier
  ('b012b012-0000-0000-0000-000000000c06'::uuid,'b012b012-0000-0000-0000-000000005e01'::uuid,'b012b012-0000-0000-0000-000000001a01'::uuid,null,            current_setting('t.d1'),'09:00'::time,'scheduled',0,'flex',2),
  -- Prev
  ('b012b012-0000-0000-0000-000000000c07'::uuid,'b012b012-0000-0000-0000-000000005d01'::uuid,'b012b012-0000-0000-0000-000000001a01'::uuid,null,            current_setting('t.d1'),'10:00'::time,'scheduled',0,'flex',2),
  -- Instr: two future scheduled, instructor Gus (assigned)
  ('b012b012-0000-0000-0000-000000000c08'::uuid,'b012b012-0000-0000-0000-00000000e501'::uuid,'b012b012-0000-0000-0000-000000001a01'::uuid,'b012b012-0000-0000-0000-00000000f202'::uuid, current_setting('t.d1'),'11:00'::time,'scheduled',0,'core',null),
  ('b012b012-0000-0000-0000-000000000c09'::uuid,'b012b012-0000-0000-0000-00000000e501'::uuid,'b012b012-0000-0000-0000-000000001a01'::uuid,'b012b012-0000-0000-0000-00000000f202'::uuid, current_setting('t.d2'),'11:00'::time,'scheduled',0,'core',null),
  -- Room OK: d1 12:00 in R1 (R2 free at 12:00)
  ('b012b012-0000-0000-0000-000000000c0a'::uuid,'b012b012-0000-0000-0000-000000002001'::uuid,'b012b012-0000-0000-0000-000000001a01'::uuid,null,            current_setting('t.d1'),'12:00'::time,'scheduled',0,'core',null),
  -- Room Clash: d1 13:00 in R1
  ('b012b012-0000-0000-0000-000000000c0b'::uuid,'b012b012-0000-0000-0000-0000000020c1'::uuid,'b012b012-0000-0000-0000-000000001a01'::uuid,null,            current_setting('t.d1'),'13:00'::time,'scheduled',0,'core',null),
  -- Blocker: d1 13:00 in R2 (so Room Clash cannot move to R2 at 13:00)
  ('b012b012-0000-0000-0000-000000000c0c'::uuid,'b012b012-0000-0000-0000-00000000b101'::uuid,'b012b012-0000-0000-0000-000000001b01'::uuid,null,            current_setting('t.d1'),'13:00'::time,'scheduled',0,'core',null),
  -- Ends Book: d1 (empty) + d2 (BOOKED)
  ('b012b012-0000-0000-0000-000000000c0d'::uuid,'b012b012-0000-0000-0000-0000000eb001'::uuid,'b012b012-0000-0000-0000-000000001a01'::uuid,null,            current_setting('t.d1'),'14:00'::time,'scheduled',0,'core',null),
  ('b012b012-0000-0000-0000-000000000c0e'::uuid,'b012b012-0000-0000-0000-0000000eb001'::uuid,'b012b012-0000-0000-0000-000000001a01'::uuid,null,            current_setting('t.d2'),'14:00'::time,'scheduled',1,'core',null),
  -- Ends OK: d1 + d2 both empty
  ('b012b012-0000-0000-0000-000000000c0f'::uuid,'b012b012-0000-0000-0000-0000000e0001'::uuid,'b012b012-0000-0000-0000-000000001a01'::uuid,null,            current_setting('t.d1'),'15:00'::time,'scheduled',0,'core',null),
  ('b012b012-0000-0000-0000-000000000c10'::uuid,'b012b012-0000-0000-0000-0000000e0001'::uuid,'b012b012-0000-0000-0000-000000001a01'::uuid,null,            current_setting('t.d2'),'15:00'::time,'scheduled',0,'core',null),
  -- Starts: d1 (BOOKED) + d2
  ('b012b012-0000-0000-0000-000000000c11'::uuid,'b012b012-0000-0000-0000-0000000a7001'::uuid,'b012b012-0000-0000-0000-000000001a01'::uuid,null,            current_setting('t.d1'),'16:00'::time,'scheduled',1,'core',null),
  ('b012b012-0000-0000-0000-000000000c12'::uuid,'b012b012-0000-0000-0000-0000000a7001'::uuid,'b012b012-0000-0000-0000-000000001a01'::uuid,null,            current_setting('t.d2'),'16:00'::time,'scheduled',0,'core',null)
) as o(id,series,room,instr,day,tm,st,booked,tier,min);

insert into bookings (studio_id, occurrence_id, member_id, status) values
  ('b012b012-0000-0000-0000-000000000001','b012b012-0000-0000-0000-000000000c0e','b012b012-0000-0000-0000-00000003e001','booked'),
  ('b012b012-0000-0000-0000-000000000001','b012b012-0000-0000-0000-000000000c11','b012b012-0000-0000-0000-00000003e001','booked');

alter table class_series enable trigger class_series_materialise;

-- =============================================================================
-- 7 (first). PREVIEW WRITES NOTHING — checksum of studio B before and after.
-- =============================================================================
select set_config('t.ck0', (select md5(coalesce(string_agg(x, '|' order by x), '')) from (
  select id::text||coalesce(guarantee_tier::text,'')||coalesce(minimum_bookings::text,'')||coalesce(core_min_bookings::text,'')||coalesce(room_id::text,'')||coalesce(instructor_id::text,'')||coalesce(ends_on::text,'')||starts_on::text||coalesce(updated_at::text,'') as x
    from class_series where studio_id='b012b012-0000-0000-0000-000000000001'
  union all
  select id::text||status||coalesce(room_id::text,'')||coalesce(instructor_id::text,'')||coalesce(minimum_bookings::text,'')||coalesce(guarantee_tier::text,'')||starts_at::text||coalesce(updated_at::text,'') as x
    from class_occurrences where studio_id='b012b012-0000-0000-0000-000000000001'
) s), false);
set role authenticated;
select set_config('request.jwt.claim.sub','b012b012-0000-0000-0000-0000000000a2',false);  -- manager
select set_config('t.prev', (select bulk_update_series(array[
   'b012b012-0000-0000-0000-000000005a01','b012b012-0000-0000-0000-000000005d01']::uuid[],
   '{"minimum":5}'::jsonb, true)::text), false);
reset role; select set_config('request.jwt.claim.sub', null, false);
select expect_num('preview: two series would change', jsonb_array_length((current_setting('t.prev')::jsonb)->'changed'), 2);
select set_config('t.ck1', (select md5(coalesce(string_agg(x, '|' order by x), '')) from (
  select id::text||coalesce(guarantee_tier::text,'')||coalesce(minimum_bookings::text,'')||coalesce(core_min_bookings::text,'')||coalesce(room_id::text,'')||coalesce(instructor_id::text,'')||coalesce(ends_on::text,'')||starts_on::text||coalesce(updated_at::text,'') as x
    from class_series where studio_id='b012b012-0000-0000-0000-000000000001'
  union all
  select id::text||status||coalesce(room_id::text,'')||coalesce(instructor_id::text,'')||coalesce(minimum_bookings::text,'')||coalesce(guarantee_tier::text,'')||starts_at::text||coalesce(updated_at::text,'') as x
    from class_occurrences where studio_id='b012b012-0000-0000-0000-000000000001'
) s), false);
select expect_text('preview wrote nothing (checksum identical)', current_setting('t.ck1'), current_setting('t.ck0'));

-- =============================================================================
-- 1. MINIMUM on three flex series → series + future scheduled occ to 5;
--    past and cancelled untouched.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','b012b012-0000-0000-0000-0000000000a2',false);
select set_config('t.min', (select bulk_update_series(array[
   'b012b012-0000-0000-0000-000000005a01','b012b012-0000-0000-0000-000000005b01','b012b012-0000-0000-0000-000000005c01']::uuid[],
   '{"minimum":5}'::jsonb, false)::text), false);
reset role; select set_config('request.jwt.claim.sub', null, false);
select expect_num('minimum: three changed', jsonb_array_length((current_setting('t.min')::jsonb)->'changed'), 3);
select expect_num('minimum: Min A series minimum is 5',
  (select minimum_bookings from class_series where id='b012b012-0000-0000-0000-000000005a01'), 5);
select expect_num('minimum: Min A future scheduled occ is 5',
  (select minimum_bookings from class_occurrences where id='b012b012-0000-0000-0000-000000000c01'), 5);
select expect_num('minimum: Min A PAST occ untouched (still 2)',
  (select minimum_bookings from class_occurrences where id='b012b012-0000-0000-0000-000000000c02'), 2);
select expect_num('minimum: Min A CANCELLED occ untouched (still 2)',
  (select minimum_bookings from class_occurrences where id='b012b012-0000-0000-0000-000000000c03'), 2);
select expect_num('minimum: Min B and Min C occ are 5',
  (select count(*) from class_occurrences where id in
     ('b012b012-0000-0000-0000-000000000c04','b012b012-0000-0000-0000-000000000c05') and minimum_bookings=5), 2);

-- =============================================================================
-- 2. TIER flex → core, as set_series_guarantee does singly.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','b012b012-0000-0000-0000-0000000000a2',false);
select bulk_update_series(array['b012b012-0000-0000-0000-000000005e01']::uuid[],
   '{"tier":"core","minimum":3}'::jsonb, false);
reset role; select set_config('request.jwt.claim.sub', null, false);
select expect_text('tier: series is core', (select guarantee_tier::text from class_series where id='b012b012-0000-0000-0000-000000005e01'), 'core');
select expect_true('tier: series flex flag is false', (select not flex from class_series where id='b012b012-0000-0000-0000-000000005e01'));
select expect_text('tier: future occ is core', (select guarantee_tier::text from class_occurrences where id='b012b012-0000-0000-0000-000000000c06'), 'core');

-- =============================================================================
-- 3. ROOM change → Room OK re-roomed to R2; Room Clash refused (R2 taken at 09:00).
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','b012b012-0000-0000-0000-0000000000a2',false);
select set_config('t.room', (select bulk_update_series(array[
   'b012b012-0000-0000-0000-000000002001','b012b012-0000-0000-0000-0000000020c1']::uuid[],
   '{"room_id":"b012b012-0000-0000-0000-000000001b01"}'::jsonb, false)::text), false);
reset role; select set_config('request.jwt.claim.sub', null, false);
select expect_num('room: one changed', jsonb_array_length((current_setting('t.room')::jsonb)->'changed'), 1);
select expect_num('room: one refused', jsonb_array_length((current_setting('t.room')::jsonb)->'refused'), 1);
select expect_text('room: the refusal names the room clash',
  ((current_setting('t.room')::jsonb)->'refused'->0->>'reason'), 'the room is taken on some of its classes');
select expect_text('room: Room OK occ now in R2',
  (select room_id::text from class_occurrences where id='b012b012-0000-0000-0000-000000000c0a'), 'b012b012-0000-0000-0000-000000001b01');
select expect_text('room: Room Clash occ left in R1 (series rolled back)',
  (select room_id::text from class_occurrences where id='b012b012-0000-0000-0000-000000000c0b'), 'b012b012-0000-0000-0000-000000001a01');
select expect_text('room: Room Clash series room unchanged (R1)',
  (select room_id::text from class_series where id='b012b012-0000-0000-0000-0000000020c1'), 'b012b012-0000-0000-0000-000000001a01');

-- =============================================================================
-- 4. ENDS_ON earlier → Ends OK drops d2 (cancelled); Ends Book refused (d2 booked).
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','b012b012-0000-0000-0000-0000000000a2',false);
select set_config('t.ends', (select bulk_update_series(array[
   'b012b012-0000-0000-0000-0000000e0001','b012b012-0000-0000-0000-0000000eb001']::uuid[],
   ('{"ends_on":"' || current_setting('t.d1') || '"}')::jsonb, false)::text), false);
reset role; select set_config('request.jwt.claim.sub', null, false);
select expect_num('ends_on: one changed', jsonb_array_length((current_setting('t.ends')::jsonb)->'changed'), 1);
select expect_num('ends_on: one refused', jsonb_array_length((current_setting('t.ends')::jsonb)->'refused'), 1);
select expect_text('ends_on: the refusal names the later bookings',
  ((current_setting('t.ends')::jsonb)->'refused'->0->>'reason'), 'later classes have bookings');
select expect_text('ends_on: Ends OK d2 is cancelled (removed as update_series does)',
  (select status::text from class_occurrences where id='b012b012-0000-0000-0000-000000000c10'), 'cancelled');
select expect_text('ends_on: Ends Book d2 still scheduled (series refused)',
  (select status::text from class_occurrences where id='b012b012-0000-0000-0000-000000000c0e'), 'scheduled');

-- =============================================================================
-- 5. STARTS_ON later with a booked earlier occurrence → refused for that series.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','b012b012-0000-0000-0000-0000000000a2',false);
select set_config('t.starts', (select bulk_update_series(array['b012b012-0000-0000-0000-0000000a7001']::uuid[],
   ('{"starts_on":"' || current_setting('t.d2') || '"}')::jsonb, false)::text), false);
reset role; select set_config('request.jwt.claim.sub', null, false);
select expect_num('starts_on: refused', jsonb_array_length((current_setting('t.starts')::jsonb)->'refused'), 1);
select expect_text('starts_on: the refusal names the earlier bookings',
  ((current_setting('t.starts')::jsonb)->'refused'->0->>'reason'), 'earlier classes have bookings');
select expect_text('starts_on: the series starts_on is unchanged',
  (select starts_on::text from class_series where id='b012b012-0000-0000-0000-0000000a7001'), (current_date - 14)::text);

-- =============================================================================
-- 6. INSTRUCTOR template change → class_series.instructor_id only, zero occ touched.
-- =============================================================================
select set_config('t.occ_before', (select md5(string_agg(id::text||coalesce(instructor_id::text,'')||updated_at::text, '|' order by id))
   from class_occurrences where series_id='b012b012-0000-0000-0000-00000000e501'), false);
set role authenticated;
select set_config('request.jwt.claim.sub','b012b012-0000-0000-0000-0000000000a2',false);
select bulk_update_series(array['b012b012-0000-0000-0000-00000000e501']::uuid[],
   '{"instructor_id":"b012b012-0000-0000-0000-00000000f101"}'::jsonb, false);
reset role; select set_config('request.jwt.claim.sub', null, false);
select expect_text('instructor: series template is now Fay',
  (select instructor_id::text from class_series where id='b012b012-0000-0000-0000-00000000e501'), 'b012b012-0000-0000-0000-00000000f101');
select expect_text('instructor: NO occurrence row touched (same ids/instructor/updated_at)',
  (select md5(string_agg(id::text||coalesce(instructor_id::text,'')||updated_at::text, '|' order by id))
     from class_occurrences where series_id='b012b012-0000-0000-0000-00000000e501'),
  current_setting('t.occ_before'));

-- =============================================================================
-- 8. Another studio's series id mixed in, and an unknown id → PT403.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','b012b012-0000-0000-0000-0000000000a2',false);
select expect_raises('foreign: a series from another studio in the set is PT403',
  'select bulk_update_series(array[''b012b012-0000-0000-0000-000000005d01'',''b012b012-0000-0000-0000-00000000f051'']::uuid[], ''{"minimum":4}''::jsonb, false)',
  'PT403');
select expect_raises('foreign: an unknown series id is PT403',
  'select bulk_update_series(array[''b012b012-0000-0000-0000-000000005d01'',''b012b012-0000-0000-0000-000000000000'']::uuid[], ''{"minimum":4}''::jsonb, false)',
  'PT403');
reset role; select set_config('request.jwt.claim.sub', null, false);

-- =============================================================================
-- 10. Non-manager (instructor) → PT403.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','b012b012-0000-0000-0000-0000000000a3',false);
select expect_raises('non-manager: an instructor is refused PT403',
  'select bulk_update_series(array[''b012b012-0000-0000-0000-000000005d01'']::uuid[], ''{"minimum":4}''::jsonb, false)',
  'PT403');
reset role; select set_config('request.jwt.claim.sub', null, false);

-- =============================================================================
-- 9. One batch audit row per apply. Six applies ran above (minimum, tier, room,
--    ends, starts, instructor); preview and the raised calls write none.
-- =============================================================================
select expect_num('audit: one series.bulk_updated row per apply (6 applies)',
  (select count(*) from audit_logs where action='series.bulk_updated'
     and studio_id='b012b012-0000-0000-0000-000000000001'), 6);

select 'bulk series suite finished' as done;
