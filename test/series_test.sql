-- =============================================================================
-- Recurring classes: the form's database half
-- Migration 064. UUID space 5e21, checked free.
-- =============================================================================
-- What this suite is really for: before 064, editing a series DOUBLED the
-- studio's timetable for a year and changing its capacity did nothing at all.
-- Both are asserted here directly, so the fix cannot quietly come undone.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then
    raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else
    raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null');
  end if;
end $$;

create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then
    raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else
    raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null');
  end if;
end $$;

create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual then raise notice 'PASS  %  (got true)', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null');
  end if;
end $$;

create or replace function expect_raises(label text, stmt text, want_sqlstate text)
returns void language plpgsql as $$
begin
  execute stmt;
  raise exception 'FAIL  %  expected % but nothing was raised', label, want_sqlstate;
exception when others then
  if sqlstate = want_sqlstate then raise notice 'PASS  %  (got %)', label, sqlstate;
  elsif sqlstate = 'P0001' and sqlerrm like 'FAIL%' then raise;
  else raise exception 'FAIL  %  expected %, got % (%)', label, want_sqlstate, sqlstate, sqlerrm;
  end if;
end $$;

-- --- Fixtures ---------------------------------------------------------------
insert into auth.users (id) values
  ('5e215e21-0000-0000-0000-0000000000a1'),
  ('5e215e21-0000-0000-0000-0000000000a2'),
  ('5e215e21-0000-0000-0000-0000000000a3');
insert into profiles (id, email, full_name) values
  ('5e215e21-0000-0000-0000-0000000000a1','ser-owner@example.com','Sera Owner'),
  ('5e215e21-0000-0000-0000-0000000000a2','ser-desk@example.com','Des Kaye'),
  ('5e215e21-0000-0000-0000-0000000000a3','ser-outsider@example.com','Otto Sider');

insert into studios (id, name, slug, timezone, currency, status) values
  ('5e215e21-0000-0000-0000-000000000001','Series Studio','ser-test','Europe/Prague','CZK','active'),
  ('5e215e21-0000-0000-0000-000000000002','Other Studio','ser-other','Europe/Prague','CZK','active');
-- Pinned at 365 days. Migration 068 moved the default from twelve months to
-- sixty days; this suite is about what an EDIT does to a materialised year, so
-- it states the horizon it needs rather than inheriting whatever ships.
insert into studio_settings (studio_id, occurrence_horizon_days) values
  ('5e215e21-0000-0000-0000-000000000001', 365),
  ('5e215e21-0000-0000-0000-000000000002', 365);
insert into locations (id, studio_id, name, is_primary) values
  ('5e215e21-0000-0000-0000-00000000000c','5e215e21-0000-0000-0000-000000000001','Main',true),
  ('5e215e21-0000-0000-0000-00000000000d','5e215e21-0000-0000-0000-000000000002','Main',true);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('5e215e21-0000-0000-0000-00000000aa01','5e215e21-0000-0000-0000-000000000001','5e215e21-0000-0000-0000-0000000000a1','ser-owner@example.com','owner'),
  ('5e215e21-0000-0000-0000-00000000aa02','5e215e21-0000-0000-0000-000000000001','5e215e21-0000-0000-0000-0000000000a2','ser-desk@example.com','front_desk'),
  ('5e215e21-0000-0000-0000-00000000aa03','5e215e21-0000-0000-0000-000000000002','5e215e21-0000-0000-0000-0000000000a3','ser-outsider@example.com','owner');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('5e215e21-0000-0000-0000-00000000ee01','5e215e21-0000-0000-0000-000000000001','5e215e21-0000-0000-0000-00000000000c','Room A',12),
  ('5e215e21-0000-0000-0000-00000000ee02','5e215e21-0000-0000-0000-000000000001','5e215e21-0000-0000-0000-00000000000c','Room B',12);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('5e215e21-0000-0000-0000-00000000cc01','5e215e21-0000-0000-0000-000000000001','Reformer',50,10),
  ('5e215e21-0000-0000-0000-00000000cc02','5e215e21-0000-0000-0000-000000000001','Barre',45,10);
insert into instructors (id, studio_id, display_name) values
  ('5e215e21-0000-0000-0000-00000000d101','5e215e21-0000-0000-0000-000000000001','Ida Teacher'),
  ('5e215e21-0000-0000-0000-00000000d102','5e215e21-0000-0000-0000-000000000001','Ivo Teacher');
insert into members (id, studio_id, first_name, last_name, email, status) values
  ('5e215e21-0000-0000-0000-00000000b101','5e215e21-0000-0000-0000-000000000001','Mira','Member','ser-mira@example.com','active');

set role authenticated;
select set_config('request.jwt.claim.sub','5e215e21-0000-0000-0000-0000000000a1',false);

-- =============================================================================
-- 1. Retiming a series MOVES its classes; it does not make a second copy
-- =============================================================================
-- The proven bug this migration exists for: 52 occurrences at 07:00 became 104
-- at 07:00 and 08:00, and the studio was teaching the same class twice a week
-- for a year.
insert into class_series
  (id, studio_id, location_id, class_type_id, name, room_id, capacity,
   duration_minutes, rrule, starts_on, time_of_day)
values ('5e215e21-0000-0000-0000-00000000f001','5e215e21-0000-0000-0000-000000000001',
        '5e215e21-0000-0000-0000-00000000000c','5e215e21-0000-0000-0000-00000000cc01',
        'Reformer Flow','5e215e21-0000-0000-0000-00000000ee01',
        10, 50, 'FREQ=WEEKLY;BYDAY=TU', current_date, '07:00');

select set_config('t.before',
  (select count(*)::text from class_occurrences
    where series_id = '5e215e21-0000-0000-0000-00000000f001'), false);
select expect_true('a new series materialises a year of classes',
  current_setting('t.before')::int > 45);

-- Preview first. It must change nothing at all.
select set_config('t.prev',
  (select update_series('5e215e21-0000-0000-0000-00000000f001','Reformer Flow',
     '5e215e21-0000-0000-0000-00000000cc01','5e215e21-0000-0000-0000-00000000ee01',
     null, 10, 50, 'FREQ=WEEKLY;BYDAY=TU', current_date, null, '08:00', null,
     null, false)::text), false);
select expect_true('a preview asks for confirmation',
  (current_setting('t.prev')::jsonb ->> 'requires_confirmation')::boolean);
-- Counted from the data rather than from `before`, because whether today's
-- class exists depends on which weekday the suite is run on — and an edit is
-- only ever effective from tomorrow.
select expect_num('a preview counts every class it would move',
  (current_setting('t.prev')::jsonb ->> 'will_move')::bigint,
  (select count(*) from class_occurrences
    where series_id = '5e215e21-0000-0000-0000-00000000f001'
      and (series_slot_at at time zone 'Europe/Prague')::date
          > (now() at time zone 'Europe/Prague')::date)::bigint);
select expect_num('a preview adds nothing',
  (current_setting('t.prev')::jsonb ->> 'will_add')::bigint, 0);
select expect_num('and a preview writes nothing',
  (select count(*) from class_occurrences
    where series_id = '5e215e21-0000-0000-0000-00000000f001')::bigint,
  current_setting('t.before')::bigint);
select expect_text('...not even to the series row',
  (select time_of_day::text from class_series
    where id = '5e215e21-0000-0000-0000-00000000f001'), '07:00:00');

-- Now do it.
select set_config('t.app',
  (select update_series('5e215e21-0000-0000-0000-00000000f001','Reformer Flow',
     '5e215e21-0000-0000-0000-00000000cc01','5e215e21-0000-0000-0000-00000000ee01',
     null, 10, 50, 'FREQ=WEEKLY;BYDAY=TU', current_date, null, '08:00', null,
     null, true)::text), false);
select expect_true('applying reports ok', (current_setting('t.app')::jsonb ->> 'ok')::boolean);
select expect_num('THE COUNT DOES NOT MOVE — the timetable was not duplicated',
  (select count(*) from class_occurrences
    where series_id = '5e215e21-0000-0000-0000-00000000f001')::bigint,
  current_setting('t.before')::bigint);
select expect_num('...and only one time survives',
  (select count(distinct (starts_at at time zone 'Europe/Prague')::time)
     from class_occurrences where series_id = '5e215e21-0000-0000-0000-00000000f001'
       and (starts_at at time zone 'Europe/Prague')::date
           > (now() at time zone 'Europe/Prague')::date)::bigint, 1);
select expect_text('...and it is the new one',
  (select distinct (starts_at at time zone 'Europe/Prague')::time::text
     from class_occurrences where series_id = '5e215e21-0000-0000-0000-00000000f001'
       and (starts_at at time zone 'Europe/Prague')::date
           > (now() at time zone 'Europe/Prague')::date), '08:00:00');

-- The other half of the duplication: the moved rows must keep holding their
-- recurrence, or the nightly job finds every new slot empty and refills it.
select set_config('t.regen',
  (select generate_occurrences('5e215e21-0000-0000-0000-00000000f001')::text), false);
select expect_num('a nightly run after an edit creates nothing',
  (current_setting('t.regen')::jsonb ->> 'created')::bigint, 0);
select expect_num('and no two rows share a slot',
  (select count(*) from (
     select series_slot_at from class_occurrences
      where series_id = '5e215e21-0000-0000-0000-00000000f001'
      group by 1 having count(*) > 1) x)::bigint, 0);

-- A series edit is not fifty-two exceptions. Marked, the nightly job would
-- never touch any of them again and the studio's timetable would freeze.
select expect_num('a series edit marks no occurrence as an exception',
  (select count(*) from class_occurrences
    where series_id = '5e215e21-0000-0000-0000-00000000f001' and is_exception)::bigint, 0);

-- =============================================================================
-- 2. Editing capacity reaches the classes that already exist
-- =============================================================================
-- The quiet half of the bug: the series said 20 and every materialised class
-- stayed on 10, which looks exactly like nothing having happened.
select update_series('5e215e21-0000-0000-0000-00000000f001','Reformer Flow',
  '5e215e21-0000-0000-0000-00000000cc01','5e215e21-0000-0000-0000-00000000ee01',
  null, 12, 50, 'FREQ=WEEKLY;BYDAY=TU', current_date, null, '08:00', null,
  null, true);
select expect_num('a capacity change reaches every future class',
  (select count(*) from class_occurrences
    where series_id = '5e215e21-0000-0000-0000-00000000f001' and capacity <> 12
      and (series_slot_at at time zone 'Europe/Prague')::date
          > (now() at time zone 'Europe/Prague')::date)::bigint, 0);
select expect_num('and the name follows it',
  (select count(*) from class_occurrences
    where series_id = '5e215e21-0000-0000-0000-00000000f001'
      and name <> 'Reformer Flow')::bigint, 0);

-- =============================================================================
-- 3. The past is never rewritten, and neither is a class somebody has moved
-- =============================================================================
reset role;
select set_config('request.jwt.claims', null, false);
select set_config('request.jwt.claim.sub', null, false);

-- A series that has been running for six weeks, with history behind it.
insert into class_series
  (id, studio_id, location_id, class_type_id, name, room_id, capacity,
   duration_minutes, rrule, starts_on, time_of_day)
values ('5e215e21-0000-0000-0000-00000000f002','5e215e21-0000-0000-0000-000000000001',
        '5e215e21-0000-0000-0000-00000000000c','5e215e21-0000-0000-0000-00000000cc01',
        'Morning Mat','5e215e21-0000-0000-0000-00000000ee02',
        10, 50, 'FREQ=WEEKLY;BYDAY=WE', current_date - 42, '09:00');
-- Six weeks of history the generator will never make, inserted the way the seed
-- does: behind today, so no edit may touch it.
insert into class_occurrences
  (id, studio_id, location_id, series_id, class_type_id, name, room_id, capacity,
   starts_at, ends_at, status, staffing, series_slot_at)
select ('5e215e21-0000-0000-0000-0000000f2' || lpad(n::text,3,'0'))::uuid,
       '5e215e21-0000-0000-0000-000000000001','5e215e21-0000-0000-0000-00000000000c',
       '5e215e21-0000-0000-0000-00000000f002','5e215e21-0000-0000-0000-00000000cc01',
       'Morning Mat','5e215e21-0000-0000-0000-00000000ee02',10,
       d, d + interval '50 min', 'completed', 'open', d
  from (select generate_series(1,6) n) g,
       lateral (select ((current_date - (7*g.n))::date + time '09:00')
                       at time zone 'Europe/Prague' as d) x;

set role authenticated;
select set_config('request.jwt.claim.sub','5e215e21-0000-0000-0000-0000000000a1',false);

-- And one future class the studio has already dragged somewhere else.
select set_config('t.excid', (select id::text from class_occurrences
  where series_id = '5e215e21-0000-0000-0000-00000000f002'
    and starts_at > now() order by starts_at offset 2 limit 1), false);
select move_occurrence(current_setting('t.excid')::uuid,
  (select starts_at + interval '1 day' from class_occurrences where id = current_setting('t.excid')::uuid),
  (select ends_at   + interval '1 day' from class_occurrences where id = current_setting('t.excid')::uuid),
  null, null, true, false);
select expect_true('moving one class marks it as an exception',
  (select is_exception from class_occurrences where id = current_setting('t.excid')::uuid));

select set_config('t.hist', (select string_agg(
  (starts_at at time zone 'Europe/Prague')::time::text, ',' order by starts_at)
   from class_occurrences where series_id = '5e215e21-0000-0000-0000-00000000f002'
     and starts_at < now()), false);
select set_config('t.excat', (select starts_at::text from class_occurrences
  where id = current_setting('t.excid')::uuid), false);

select set_config('t.f2',
  (select update_series('5e215e21-0000-0000-0000-00000000f002','Morning Mat',
     '5e215e21-0000-0000-0000-00000000cc01','5e215e21-0000-0000-0000-00000000ee02',
     null, 10, 50, 'FREQ=WEEKLY;BYDAY=WE', current_date - 42, null, '10:30', null,
     null, true)::text), false);

select expect_text('six weeks of history keep the time they were taught at',
  (select string_agg((starts_at at time zone 'Europe/Prague')::time::text, ',' order by starts_at)
     from class_occurrences where series_id = '5e215e21-0000-0000-0000-00000000f002'
       and starts_at < now()), current_setting('t.hist'));
select expect_text('a class already moved is left exactly where it was put',
  (select starts_at::text from class_occurrences where id = current_setting('t.excid')::uuid),
  current_setting('t.excat'));
select expect_num('...and the edit says so rather than silently skipping it',
  (current_setting('t.f2')::jsonb ->> 'left_as_edited')::bigint, 1);
select expect_num('everything else moved to the new time',
  (select count(*) from class_occurrences
    where series_id = '5e215e21-0000-0000-0000-00000000f002'
      and starts_at > now() and not is_exception
      and (starts_at at time zone 'Europe/Prague')::time <> '10:30')::bigint, 0);

-- =============================================================================
-- 4. Dropping a day: refused when somebody is booked, cancelled when nobody is
-- =============================================================================
insert into class_series
  (id, studio_id, location_id, class_type_id, name, room_id, capacity,
   duration_minutes, rrule, starts_on, time_of_day)
values ('5e215e21-0000-0000-0000-00000000f003','5e215e21-0000-0000-0000-000000000001',
        '5e215e21-0000-0000-0000-00000000000c','5e215e21-0000-0000-0000-00000000cc02',
        'Barre Express','5e215e21-0000-0000-0000-00000000ee02',
        10, 45, 'FREQ=WEEKLY;BYDAY=MO,TH', current_date, '18:00');

select set_config('t.mon', (select count(*)::text from class_occurrences
  where series_id = '5e215e21-0000-0000-0000-00000000f003'
    and extract(dow from starts_at at time zone 'Europe/Prague') = 1), false);
select expect_true('a two-day rule makes both days', current_setting('t.mon')::int > 40);

-- Drop Monday with nobody booked.
select set_config('t.drop',
  (select update_series('5e215e21-0000-0000-0000-00000000f003','Barre Express',
     '5e215e21-0000-0000-0000-00000000cc02','5e215e21-0000-0000-0000-00000000ee02',
     null, 10, 45, 'FREQ=WEEKLY;BYDAY=TH', current_date, null, '18:00', null,
     null, true)::text), false);
select expect_num('dropping a day cancels the classes it made',
  (current_setting('t.drop')::jsonb ->> 'cancelled')::bigint,
  current_setting('t.mon')::bigint);
select expect_num('...and none of them is left scheduled',
  (select count(*) from class_occurrences
    where series_id = '5e215e21-0000-0000-0000-00000000f003' and status = 'scheduled'
      and extract(dow from starts_at at time zone 'Europe/Prague') = 1)::bigint, 0);
select expect_num('...cancelled, not deleted — the record survives',
  (select count(*) from class_occurrences
    where series_id = '5e215e21-0000-0000-0000-00000000f003' and status = 'cancelled')::bigint,
  current_setting('t.mon')::bigint);

-- Put Monday back. The cancelled rows still hold their slots, so if restoring
-- did not reach them the generator would skip every one and the studio's Monday
-- would stay empty for a year with nothing reporting an error.
select set_config('t.back',
  (select update_series('5e215e21-0000-0000-0000-00000000f003','Barre Express',
     '5e215e21-0000-0000-0000-00000000cc02','5e215e21-0000-0000-0000-00000000ee02',
     null, 10, 45, 'FREQ=WEEKLY;BYDAY=MO,TH', current_date, null, '18:00', null,
     null, true)::text), false);
select expect_num('putting a dropped day back restores the classes it cancelled',
  (current_setting('t.back')::jsonb ->> 'restored')::bigint,
  current_setting('t.mon')::bigint);
select expect_num('...and Monday is on again',
  (select count(*) from class_occurrences
    where series_id = '5e215e21-0000-0000-0000-00000000f003' and status = 'scheduled'
      and extract(dow from starts_at at time zone 'Europe/Prague') = 1)::bigint,
  current_setting('t.mon')::bigint);
select expect_num('...without a second copy of it',
  (select count(*) from class_occurrences
    where series_id = '5e215e21-0000-0000-0000-00000000f003'
      and extract(dow from starts_at at time zone 'Europe/Prague') = 1)::bigint,
  current_setting('t.mon')::bigint);
reset role;
select set_config('request.jwt.claim.sub', null, false);
select set_config('t.booked', (select id::text from class_occurrences
  where series_id = '5e215e21-0000-0000-0000-00000000f003' and status = 'scheduled'
    and extract(dow from starts_at at time zone 'Europe/Prague') = 1
  order by starts_at limit 1), false);
update class_occurrences set booked_count = 1 where id = current_setting('t.booked')::uuid;
insert into bookings (studio_id, occurrence_id, member_id, status)
values ('5e215e21-0000-0000-0000-000000000001', current_setting('t.booked')::uuid,
        '5e215e21-0000-0000-0000-00000000b101','booked');
set role authenticated;
select set_config('request.jwt.claim.sub','5e215e21-0000-0000-0000-0000000000a1',false);

select set_config('t.refuse',
  (select update_series('5e215e21-0000-0000-0000-00000000f003','Barre Express',
     '5e215e21-0000-0000-0000-00000000cc02','5e215e21-0000-0000-0000-00000000ee02',
     null, 10, 45, 'FREQ=WEEKLY;BYDAY=TH', current_date, null, '18:00', null,
     null, true)::text), false);
select expect_text('dropping a day somebody is booked on is refused',
  current_setting('t.refuse')::jsonb ->> 'reason', 'members_booked_on_dropped_classes');
select expect_num('...and the refusal names the class rather than counting it',
  jsonb_array_length(current_setting('t.refuse')::jsonb -> 'blocked')::bigint, 1);
select expect_true('...with a date a person can act on',
  (current_setting('t.refuse')::jsonb -> 'blocked' -> 0 ->> 'local') is not null);
select expect_num('...and CONFIRMED still means refused: nothing was cancelled',
  (select count(*) from class_occurrences
    where series_id = '5e215e21-0000-0000-0000-00000000f003' and status = 'scheduled'
      and extract(dow from starts_at at time zone 'Europe/Prague') = 1)::bigint,
  current_setting('t.mon')::bigint);


-- =============================================================================
-- 5. Business Rules §5: capacity may not fall below what is booked
-- =============================================================================
reset role;
select set_config('request.jwt.claim.sub', null, false);
update class_occurrences set booked_count = 5 where id = current_setting('t.booked')::uuid;
set role authenticated;
select set_config('request.jwt.claim.sub','5e215e21-0000-0000-0000-0000000000a1',false);

select set_config('t.cap',
  (select update_series('5e215e21-0000-0000-0000-00000000f003','Barre Express',
     '5e215e21-0000-0000-0000-00000000cc02','5e215e21-0000-0000-0000-00000000ee02',
     null, 3, 45, 'FREQ=WEEKLY;BYDAY=MO,TH', current_date, null, '18:00', null,
     null, true)::text), false);
select expect_text('cutting capacity below what is booked is refused',
  current_setting('t.cap')::jsonb ->> 'reason', 'capacity_below_booked');
select expect_num('...naming the class, not a count',
  jsonb_array_length(current_setting('t.cap')::jsonb -> 'over_capacity')::bigint, 1);
select expect_num('...and it reports how many are on it',
  (current_setting('t.cap')::jsonb -> 'over_capacity' -> 0 ->> 'booked')::bigint, 5);
select expect_num('...and nothing was written',
  (select capacity from class_occurrences
    where id = current_setting('t.booked')::uuid)::bigint, 10);
-- The system never silently picks who loses their spot, so raising is fine.
select update_series('5e215e21-0000-0000-0000-00000000f003','Barre Express',
  '5e215e21-0000-0000-0000-00000000cc02','5e215e21-0000-0000-0000-00000000ee02',
  null, 14, 45, 'FREQ=WEEKLY;BYDAY=MO,TH', current_date, null, '18:00', null, null, true);
select expect_num('raising it is ordinary',
  (select capacity from class_occurrences
    where id = current_setting('t.booked')::uuid)::bigint, 14);

-- =============================================================================
-- 6. A rule the parser cannot read never reaches the database
-- =============================================================================
-- The form only offers what rrule_weekdays() understands, but the form is not
-- the boundary. PT422 out of the edit, not a nightly job that quietly makes a
-- monthly series weekly.
select expect_raises('FREQ=MONTHLY is refused at save time',
  $$select update_series('5e215e21-0000-0000-0000-00000000f001','Reformer Flow',
      '5e215e21-0000-0000-0000-00000000cc01','5e215e21-0000-0000-0000-00000000ee01',
      null, 12, 50, 'FREQ=MONTHLY;BYMONTHDAY=1', current_date, null, '08:00', null,
      null, true)$$, 'PT422');
select expect_raises('a weekly rule with no BYDAY is refused',
  $$select update_series('5e215e21-0000-0000-0000-00000000f001','Reformer Flow',
      '5e215e21-0000-0000-0000-00000000cc01','5e215e21-0000-0000-0000-00000000ee01',
      null, 12, 50, 'FREQ=WEEKLY', current_date, null, '08:00', null,
      null, true)$$, 'PT422');
select expect_raises('an unrecognised day is refused',
  $$select update_series('5e215e21-0000-0000-0000-00000000f001','Reformer Flow',
      '5e215e21-0000-0000-0000-00000000cc01','5e215e21-0000-0000-0000-00000000ee01',
      null, 12, 50, 'FREQ=WEEKLY;BYDAY=TU,XX', current_date, null, '08:00', null,
      null, true)$$, 'PT422');
select expect_raises('COUNT=0 is refused rather than making a series of nothing',
  $$select update_series('5e215e21-0000-0000-0000-00000000f001','Reformer Flow',
      '5e215e21-0000-0000-0000-00000000cc01','5e215e21-0000-0000-0000-00000000ee01',
      null, 12, 50, 'FREQ=WEEKLY;BYDAY=TU;COUNT=0', current_date, null, '08:00', null,
      null, true)$$, 'PT422');
select expect_num('and a refused rule leaves the series with the one it had',
  (select count(*) from class_series
    where id = '5e215e21-0000-0000-0000-00000000f001'
      and rrule = 'FREQ=WEEKLY;BYDAY=TU')::bigint, 1);

-- =============================================================================
-- 7. COUNT ends the series; it does not slide forward every night
-- =============================================================================
-- Proved before the fix: a COUNT=4 series produced 4 occurrences, then 8 after
-- one later run, and would have climbed for as long as the cron ran. COUNT is
-- resolved once, to a date, and from then on it is an end date like any other.
-- rrule_last_date is an internal: revoked from authenticated, like rrule_part
-- and rrule_weekdays. Asked as postgres, which is who actually calls it.
reset role;
select expect_text('COUNT resolves to the date of the last recurrence',
  rrule_last_date('FREQ=WEEKLY;BYDAY=TU;COUNT=4', date '2026-09-01')::text,
  '2026-09-22');
select expect_text('...and INTERVAL stretches it',
  rrule_last_date('FREQ=WEEKLY;BYDAY=TU;COUNT=4;INTERVAL=2', date '2026-09-01')::text,
  '2026-10-13');
select expect_text('...and the earlier of UNTIL and COUNT wins',
  rrule_last_date('FREQ=WEEKLY;BYDAY=TU;COUNT=4;UNTIL=20260908', date '2026-09-01')::text,
  '2026-09-08');
select expect_text('an unbounded rule has no end date',
  coalesce(rrule_last_date('FREQ=WEEKLY;BYDAY=TU', date '2026-09-01')::text, 'none'), 'none');

set role authenticated;
select set_config('request.jwt.claim.sub','5e215e21-0000-0000-0000-0000000000a1',false);

-- A series that ran four times, ten weeks ago. Nothing may generate from it now.
insert into class_series
  (id, studio_id, location_id, class_type_id, name, capacity,
   duration_minutes, rrule, starts_on, time_of_day)
values ('5e215e21-0000-0000-0000-00000000f004','5e215e21-0000-0000-0000-000000000001',
        '5e215e21-0000-0000-0000-00000000000c','5e215e21-0000-0000-0000-00000000cc01',
        'Four Week Course', 10, 50, 'FREQ=WEEKLY;BYDAY=TU;COUNT=4', current_date - 70, '19:30');
select expect_num('a finished COUNT series materialises nothing',
  (select count(*) from class_occurrences
    where series_id = '5e215e21-0000-0000-0000-00000000f004')::bigint, 0);
select expect_num('...and a later nightly run still makes nothing',
  (generate_occurrences('5e215e21-0000-0000-0000-00000000f004') ->> 'created')::bigint, 0);

-- Beside it, an identical unbounded rule, so "0" is the COUNT and not a broken
-- generator.
insert into class_series
  (id, studio_id, location_id, class_type_id, name, capacity,
   duration_minutes, rrule, starts_on, time_of_day)
values ('5e215e21-0000-0000-0000-00000000f005','5e215e21-0000-0000-0000-000000000001',
        '5e215e21-0000-0000-0000-00000000000c','5e215e21-0000-0000-0000-00000000cc01',
        'Ongoing Course', 10, 50, 'FREQ=WEEKLY;BYDAY=TU', current_date - 70, '20:30');
select expect_true('the same rule without COUNT still fills the horizon',
  (select count(*) from class_occurrences
    where series_id = '5e215e21-0000-0000-0000-00000000f005') > 45);

-- =============================================================================
-- 8. The series instructor is a default, never an override
-- =============================================================================
-- 061: assigned_by marks a human choosing a PERSON. An edit that pushed the
-- series' instructor over one is an edit undoing somebody's decision.
insert into class_series
  (id, studio_id, location_id, class_type_id, name, capacity,
   duration_minutes, rrule, starts_on, time_of_day)
values ('5e215e21-0000-0000-0000-00000000f006','5e215e21-0000-0000-0000-000000000001',
        '5e215e21-0000-0000-0000-00000000000c','5e215e21-0000-0000-0000-00000000cc01',
        'Evening Flow', 10, 50, 'FREQ=WEEKLY;BYDAY=FR', current_date, '17:00');

select set_config('t.manual', (select id::text from class_occurrences
  where series_id = '5e215e21-0000-0000-0000-00000000f006' and starts_at > now()
  order by starts_at limit 1), false);
select move_occurrence(current_setting('t.manual')::uuid, null, null,
  '5e215e21-0000-0000-0000-00000000d102', null, true, false);
select expect_true('a human assignment is marked as one',
  (select assigned_by is not null from class_occurrences
    where id = current_setting('t.manual')::uuid));

select update_series('5e215e21-0000-0000-0000-00000000f006','Evening Flow',
  '5e215e21-0000-0000-0000-00000000cc01', null,
  '5e215e21-0000-0000-0000-00000000d101', 10, 50, 'FREQ=WEEKLY;BYDAY=FR',
  current_date, null, '17:00', null, null, true);
select expect_text('the series instructor lands on the classes nobody chose for',
  (select display_name from instructors i join class_occurrences o on o.instructor_id = i.id
    where o.series_id = '5e215e21-0000-0000-0000-00000000f006'
      and o.id <> current_setting('t.manual')::uuid
      and o.starts_at > now() order by o.starts_at limit 1), 'Ida Teacher');
select expect_text('...and does not overwrite the one a person picked',
  (select display_name from instructors i join class_occurrences o on o.instructor_id = i.id
    where o.id = current_setting('t.manual')::uuid), 'Ivo Teacher');

-- =============================================================================
-- 9. Who may edit a timetable
-- =============================================================================
select set_config('request.jwt.claim.sub','5e215e21-0000-0000-0000-0000000000a2',false);
select expect_raises('front desk cannot edit a series',
  $$select update_series('5e215e21-0000-0000-0000-00000000f006','Evening Flow',
      '5e215e21-0000-0000-0000-00000000cc01', null, null, 10, 50,
      'FREQ=WEEKLY;BYDAY=FR', current_date, null, '17:00', null, null, false)$$, 'PT403');

-- The caller the guard has never seen: staff of another studio entirely, which
-- is the shape migration 020 was written for.
select set_config('request.jwt.claim.sub','5e215e21-0000-0000-0000-0000000000a3',false);
select expect_raises('another studio''s owner cannot edit this one''s series',
  $$select update_series('5e215e21-0000-0000-0000-00000000f006','Hijacked',
      '5e215e21-0000-0000-0000-00000000cc01', null, null, 10, 50,
      'FREQ=WEEKLY;BYDAY=FR', current_date, null, '17:00', null, null, false)$$, 'PT403');
select expect_num('...and they cannot even read it',
  (select count(*) from class_series
    where id = '5e215e21-0000-0000-0000-00000000f006')::bigint, 0);

-- =============================================================================
-- 10. The setup checklist knows what "fill November" needs
-- =============================================================================
-- A studio could tick every item, open the fill screen and get an empty month.
select set_config('request.jwt.claim.sub','5e215e21-0000-0000-0000-0000000000a1',false);
select expect_true('qualifications start unticked, because an empty mapping means nothing',
  not (studio_setup_state('5e215e21-0000-0000-0000-000000000001')
        -> 'qualifications' ->> 'done')::boolean);

select set_instructor_class_types('5e215e21-0000-0000-0000-00000000d101',
  array['5e215e21-0000-0000-0000-00000000cc01']::uuid[]);
select expect_true('one instructor mapped is not the roster mapped',
  not (studio_setup_state('5e215e21-0000-0000-0000-000000000001')
        -> 'qualifications' ->> 'done')::boolean);
select set_instructor_class_types('5e215e21-0000-0000-0000-00000000d102',
  array['5e215e21-0000-0000-0000-00000000cc02']::uuid[]);
select expect_true('...and with every instructor mapped it ticks',
  (studio_setup_state('5e215e21-0000-0000-0000-000000000001')
    -> 'qualifications' ->> 'done')::boolean);

select expect_true('availability is on the list',
  studio_setup_state('5e215e21-0000-0000-0000-000000000001') ? 'availability');
select expect_true('commitments are on the list',
  studio_setup_state('5e215e21-0000-0000-0000-000000000001') ? 'commitments');
-- Not the same weight, and saying they are is the "6 of 7 forever" mistake in a
-- new place: the engine fills without either, and says so when it does.
select expect_true('availability is nice-to-have, not outstanding',
  (studio_setup_state('5e215e21-0000-0000-0000-000000000001')
    -> 'availability' ->> 'optional')::boolean);
select expect_true('commitments too',
  (studio_setup_state('5e215e21-0000-0000-0000-000000000001')
    -> 'commitments' ->> 'optional')::boolean);
select expect_true('qualifications are not — they are what makes fill return nothing',
  not (studio_setup_state('5e215e21-0000-0000-0000-000000000001')
        -> 'qualifications' ->> 'optional')::boolean);

select expect_true('availability starts unticked with no pattern on file',
  not (studio_setup_state('5e215e21-0000-0000-0000-000000000001')
        -> 'availability' ->> 'done')::boolean);
select set_instructor_availability('5e215e21-0000-0000-0000-00000000d101',
  $j$[{"day":1,"ranges":[{"from":"07:00","to":"20:00"}]}]$j$::jsonb);
select expect_true('one instructor with a pattern is not the roster covered',
  not (studio_setup_state('5e215e21-0000-0000-0000-000000000001')
        -> 'availability' ->> 'done')::boolean);
select set_instructor_availability('5e215e21-0000-0000-0000-00000000d102',
  $j$[{"day":2,"ranges":[{"from":"07:00","to":"20:00"}]}]$j$::jsonb);
select expect_true('...and ticks once every instructor has one',
  (studio_setup_state('5e215e21-0000-0000-0000-000000000001')
    -> 'availability' ->> 'done')::boolean);

-- =============================================================================
-- Migrations 077 and 078: archive, end, delete — and the cascade behind delete
-- =============================================================================
-- The delete guard's reason for existing, reproduced before it was written:
-- deleting a series with history returned DELETE 1, no error, and took 35
-- occurrences, 84 bookings and 63 check-ins with it. RLS has always allowed a
-- manager that through PostgREST; only the button was missing.

select set_config('request.jwt.claim.sub','5e215e21-0000-0000-0000-0000000000a1',false);
set local role authenticated;

-- --- Fixtures: three series in the three states that matter -----------------
-- A: has run, and has bookings.            delete refused
-- B: only future classes, nobody booked.   delete allowed
-- C: future classes, one of them booked.   archive keeps that one
insert into class_series (id, studio_id, location_id, class_type_id, name, room_id,
                          capacity, duration_minutes, rrule, starts_on, time_of_day)
values
 ('5e215e21-0000-0000-0000-00000000fa01','5e215e21-0000-0000-0000-000000000001',
  '5e215e21-0000-0000-0000-00000000000c','5e215e21-0000-0000-0000-00000000cc01',
  'HISTORY BURN','5e215e21-0000-0000-0000-00000000ee01',10,50,
  'FREQ=WEEKLY;BYDAY=MO', current_date - 60, '07:00'),
 ('5e215e21-0000-0000-0000-00000000fa02','5e215e21-0000-0000-0000-000000000001',
  '5e215e21-0000-0000-0000-00000000000c','5e215e21-0000-0000-0000-00000000cc01',
  'TYPO SERIES','5e215e21-0000-0000-0000-00000000ee02',10,50,
  'FREQ=WEEKLY;BYDAY=TU', current_date + 1, '11:00'),
 ('5e215e21-0000-0000-0000-00000000fa03','5e215e21-0000-0000-0000-000000000001',
  '5e215e21-0000-0000-0000-00000000000c','5e215e21-0000-0000-0000-00000000cc02',
  'REFORMER BURN 07:00','5e215e21-0000-0000-0000-00000000ee01',10,45,
  'FREQ=WEEKLY;BYDAY=WE', current_date + 1, '19:00');

-- A's history. Inserted directly, the way the seed builds history: the
-- generator only ever makes the future.
insert into class_occurrences (id, studio_id, location_id, series_id, class_type_id,
                               name, room_id, capacity, starts_at, ends_at, status, series_slot_at)
select ('5e215e21-0000-0000-0000-0000000fa1' || lpad(g::text,2,'0'))::uuid,
       '5e215e21-0000-0000-0000-000000000001','5e215e21-0000-0000-0000-00000000000c',
       '5e215e21-0000-0000-0000-00000000fa01','5e215e21-0000-0000-0000-00000000cc01',
       'HISTORY BURN','5e215e21-0000-0000-0000-00000000ee01',10,
       ((current_date - (g * 7))::date + time '07:00') at time zone 'Europe/Prague',
       ((current_date - (g * 7))::date + time '07:50') at time zone 'Europe/Prague',
       'completed',
       ((current_date - (g * 7))::date + time '07:00') at time zone 'Europe/Prague'
  from generate_series(1, 4) g;   -- ::date on the loop variable: generate_series
                                  -- over dates yields timestamptz and converts
                                  -- the wrong way. CLAUDE.md's own trap.

insert into bookings (id, studio_id, occurrence_id, member_id, status)
select ('5e215e21-0000-0000-0000-0000000fb1' || lpad(g::text,2,'0'))::uuid,
       '5e215e21-0000-0000-0000-000000000001',
       ('5e215e21-0000-0000-0000-0000000fa1' || lpad(g::text,2,'0'))::uuid,
       '5e215e21-0000-0000-0000-00000000b101','attended'
  from generate_series(1, 4) g;

-- Migration 007's check-in window refuses a check-in on a class that ended days
-- ago, which is right. checkin_window_enforced is the documented way off.
update studio_settings set checkin_window_enforced = false
 where studio_id = '5e215e21-0000-0000-0000-000000000001';
insert into check_ins (id, studio_id, member_id, occurrence_id, booking_id, method)
values ('5e215e21-0000-0000-0000-0000000fc101','5e215e21-0000-0000-0000-000000000001',
        '5e215e21-0000-0000-0000-00000000b101','5e215e21-0000-0000-0000-0000000fa101',
        '5e215e21-0000-0000-0000-0000000fb101','qr');
update studio_settings set checkin_window_enforced = true
 where studio_id = '5e215e21-0000-0000-0000-000000000001';

-- One future class of C, booked.
insert into bookings (id, studio_id, occurrence_id, member_id, status)
select '5e215e21-0000-0000-0000-0000000fb2ff','5e215e21-0000-0000-0000-000000000001',
       o.id,'5e215e21-0000-0000-0000-00000000b101','booked'
  from class_occurrences o
 where o.series_id = '5e215e21-0000-0000-0000-00000000fa03'
   and o.starts_at > now()
 order by o.starts_at limit 1;

-- --- What series_impact says before anybody presses anything ----------------
select expect_true('a series with history is not deletable',
  not (series_impact('5e215e21-0000-0000-0000-00000000fa01') -> 'delete' ->> 'allowed')::boolean);
select expect_true('...and the refusal names the classes that have run',
  (series_impact('5e215e21-0000-0000-0000-00000000fa01') -> 'delete' ->> 'blocked_by')
    like '%already run%');
select expect_true('...and names the bookings',
  (series_impact('5e215e21-0000-0000-0000-00000000fa01') -> 'delete' ->> 'blocked_by')
    like '%booking%');
select expect_true('...and offers archiving instead',
  (series_impact('5e215e21-0000-0000-0000-00000000fa01') -> 'delete' ->> 'effect')
    like '%Archive it instead%');
select expect_true('a series with only future unbooked classes IS deletable',
  (series_impact('5e215e21-0000-0000-0000-00000000fa02') -> 'delete' ->> 'allowed')::boolean);
select expect_num('...and it says how many classes go with it',
  (series_impact('5e215e21-0000-0000-0000-00000000fa02') -> 'delete' ->> 'removes')::bigint,
  (select count(*) from class_occurrences where series_id='5e215e21-0000-0000-0000-00000000fa02'));

-- The sentence the screen shows, in the shape it was asked for.
select expect_true('the archive preview reads as a sentence with counts in it',
  (series_impact('5e215e21-0000-0000-0000-00000000fa03') -> 'archive' ->> 'effect')
    ~ '^Archiving REFORMER BURN 07:00 removes [0-9]+ future classes\. 1 has members booked and will be kept\.$');

-- --- Delete, refused, and nothing lost --------------------------------------
-- Counted BEFORE, so the assertion is "nothing was lost" rather than a number
-- that happens to be right today. The reproduction this guard exists for showed
-- 35 occurrences, 84 bookings and 63 check-ins going silently.
create temporary table _keep as select
  (select count(*) from class_occurrences where series_id='5e215e21-0000-0000-0000-00000000fa01') as occ,
  (select count(*) from bookings b join class_occurrences o on o.id=b.occurrence_id
     where o.series_id='5e215e21-0000-0000-0000-00000000fa01') as bk,
  (select count(*) from check_ins c join class_occurrences o on o.id=c.occurrence_id
     where o.series_id='5e215e21-0000-0000-0000-00000000fa01') as ci;
select expect_true('the series under test really does have something to lose',
  (select occ > 0 and bk > 0 and ci > 0 from _keep));
select expect_raises('deleting a series with history is refused',
  $$delete from class_series where id = '5e215e21-0000-0000-0000-00000000fa01'$$, 'PT409');
select expect_num('...and not one class was lost',
  (select count(*) from class_occurrences where series_id='5e215e21-0000-0000-0000-00000000fa01'),
  (select occ from _keep));
select expect_num('...and not one booking',
  (select count(*) from bookings b join class_occurrences o on o.id=b.occurrence_id
    where o.series_id='5e215e21-0000-0000-0000-00000000fa01'), (select bk from _keep));
select expect_num('...and not one check-in',
  (select count(*) from check_ins c join class_occurrences o on o.id=c.occurrence_id
    where o.series_id='5e215e21-0000-0000-0000-00000000fa01'), (select ci from _keep));

-- A booking on a class that has NOT run is still a person with a place.
select expect_raises('a future booking alone blocks the delete',
  $$delete from class_series where id = '5e215e21-0000-0000-0000-00000000fa03'$$, 'PT409');

-- And a booking somebody cancelled is still a record of them.
update bookings set status = 'cancelled' where id = '5e215e21-0000-0000-0000-0000000fb2ff';
select expect_raises('a CANCELLED booking still blocks the delete',
  $$delete from class_series where id = '5e215e21-0000-0000-0000-00000000fa03'$$, 'PT409');
update bookings set status = 'booked' where id = '5e215e21-0000-0000-0000-0000000fb2ff';

-- --- Delete, allowed --------------------------------------------------------
select expect_true('the typo series has classes to lose',
  (select count(*) from class_occurrences where series_id='5e215e21-0000-0000-0000-00000000fa02') > 0);
delete from class_series where id = '5e215e21-0000-0000-0000-00000000fa02';
select expect_num('a future, unbooked series deletes', 
  (select count(*) from class_series where id='5e215e21-0000-0000-0000-00000000fa02'), 0);
select expect_num('...and its classes go with it',
  (select count(*) from class_occurrences where series_id='5e215e21-0000-0000-0000-00000000fa02'), 0);

-- --- Archive ----------------------------------------------------------------
select expect_true('archiving without confirming asks first',
  (archive_series('5e215e21-0000-0000-0000-00000000fa03') ->> 'confirm_required')::boolean);
select expect_text('...and changes nothing',
  (select status::text from class_series where id='5e215e21-0000-0000-0000-00000000fa03'), 'active');

create temporary table _pre as
select id, starts_at, status from class_occurrences
 where series_id = '5e215e21-0000-0000-0000-00000000fa03';

create temporary table _arch as
  select archive_series('5e215e21-0000-0000-0000-00000000fa03', true) as r;
select expect_text('archiving sets the status',
  (select status::text from class_series where id='5e215e21-0000-0000-0000-00000000fa03'), 'archived');
select expect_num('the booked future class is KEPT',
  (select count(*) from class_occurrences o
    where o.series_id='5e215e21-0000-0000-0000-00000000fa03'
      and exists (select 1 from bookings b where b.occurrence_id = o.id)), 1);
select expect_num('every other future class is removed',
  (select count(*) from class_occurrences o
    where o.series_id='5e215e21-0000-0000-0000-00000000fa03'
      and o.starts_at > now()
      and not exists (select 1 from bookings b where b.occurrence_id = o.id)), 0);
select expect_num('...and the result says how many it removed',
  (select (r->>'removed_future')::bigint from _arch),
  (select count(*) from _pre where starts_at > now() and status = 'scheduled') - 1);
select expect_true('...and tells the studio the booked one will still run',
  (select r->>'note' from _arch) like '%kept and will still run%');

-- Past classes are the history and archiving must not touch them.
select expect_num('archiving a series does not touch what has already run',
  (select count(*) from class_occurrences where series_id='5e215e21-0000-0000-0000-00000000fa01'
     and starts_at <= now()), 4);

-- --- The checklist agrees with the choice -----------------------------------
-- studio_setup_state() derives 'schedule' from whether any class_occurrences
-- exist, not from series status, so archiving cannot un-tick a studio that
-- still has a timetable — and a studio that archived everything and had nothing
-- left really has no timetable, which is what it should then say.
select expect_true('archiving a series does not un-tick the timetable',
  (studio_setup_state('5e215e21-0000-0000-0000-000000000001')
    -> 'schedule' ->> 'done')::boolean);

-- --- An archived series makes no more classes -------------------------------
select expect_num('the generator creates nothing for an archived series',
  (generate_occurrences('5e215e21-0000-0000-0000-00000000fa03') ->> 'created')::bigint, 0);
select expect_true('...and says which status stopped it',
  (generate_occurrences('5e215e21-0000-0000-0000-00000000fa03') ->> 'reason') like '%archived%');

-- --- The column cannot be set by hand ---------------------------------------
-- The same UPDATE goes straight through PostgREST, so removing the option from
-- a form is not the boundary.
select expect_raises('status cannot reach archived by a plain update',
  $$update class_series set status = 'archived'
     where id = '5e215e21-0000-0000-0000-00000000fa01'$$, 'PT409');

-- --- Restore ----------------------------------------------------------------
create temporary table _res as
  select restore_series('5e215e21-0000-0000-0000-00000000fa03') as r;
select expect_true('restoring says cancelled classes are not resurrected',
  (select r->>'note' from _res) like '%stay cancelled%');
select expect_text('restoring puts it back',
  (select status::text from class_series where id='5e215e21-0000-0000-0000-00000000fa03'), 'active');
select expect_true('...and the calendar refills straight away',
  (select count(*) from class_occurrences
    where series_id='5e215e21-0000-0000-0000-00000000fa03' and starts_at > now()) > 1);
select expect_num('...without duplicating the class somebody was booked on',
  (select count(*) from bookings b join class_occurrences o on o.id = b.occurrence_id
    where o.series_id = '5e215e21-0000-0000-0000-00000000fa03'), 1);

-- --- Permissions ------------------------------------------------------------
select set_config('request.jwt.claim.sub','5e215e21-0000-0000-0000-0000000000a2',false);
select expect_raises('front desk cannot archive a series',
  $$select archive_series('5e215e21-0000-0000-0000-00000000fa01', true)$$, 'PT403');
select expect_raises('front desk cannot read the impact either',
  $$select series_impact('5e215e21-0000-0000-0000-00000000fa01')$$, 'PT403');
select set_config('request.jwt.claim.sub','5e215e21-0000-0000-0000-0000000000a3',false);
select expect_raises('another studio owner cannot archive it',
  $$select archive_series('5e215e21-0000-0000-0000-00000000fa01', true)$$, 'PT403');
select set_config('request.jwt.claim.sub','5e215e21-0000-0000-0000-0000000000a1',false);

-- --- End it on a date -------------------------------------------------------
select expect_true('the series still runs into the future before it is ended',
  (select count(*) from class_occurrences
    where series_id = '5e215e21-0000-0000-0000-00000000fa01'
      and starts_at > now() and status = 'scheduled') > 0);
select end_series('5e215e21-0000-0000-0000-00000000fa01', null, true) is not null as ended;
select expect_num('ending it stops the classes after the end date',
  (select count(*) from class_occurrences
    where series_id = '5e215e21-0000-0000-0000-00000000fa01'
      and starts_at > (studio_today('5e215e21-0000-0000-0000-000000000001') + 1)::timestamptz
      and status = 'scheduled'), 0);
select expect_text('...and the end date is recorded',
  (select ends_on::text from class_series where id='5e215e21-0000-0000-0000-00000000fa01'),
  studio_today('5e215e21-0000-0000-0000-000000000001')::text);
select expect_num('...while the four classes it already taught keep their place',
  (select count(*) from class_occurrences
    where series_id='5e215e21-0000-0000-0000-00000000fa01' and starts_at <= now()), 4);
select expect_text('...and the series is still readable rather than gone',
  (select name from class_series where id='5e215e21-0000-0000-0000-00000000fa01'), 'HISTORY BURN');

-- --- The demo purge must not be caught by the new guard ----------------------
-- A demo series HAS history, so a guard that counted it would refuse the purge.
-- purge_demo_data() detaches every real child first (migration 062) and its
-- census is the real protection; the guard steps aside for is_demo rows only.
insert into class_series (id, studio_id, location_id, class_type_id, name, room_id,
                          capacity, duration_minutes, rrule, starts_on, time_of_day, is_demo)
values ('5e215e21-0000-0000-0000-00000000fd01','5e215e21-0000-0000-0000-000000000001',
        '5e215e21-0000-0000-0000-00000000000c','5e215e21-0000-0000-0000-00000000cc01',
        'DEMO SERIES','5e215e21-0000-0000-0000-00000000ee02',10,50,
        'FREQ=WEEKLY;BYDAY=FR', current_date - 30, '06:00', true);
insert into class_occurrences (id, studio_id, location_id, series_id, class_type_id,
                               name, room_id, capacity, starts_at, ends_at, status, is_demo)
values ('5e215e21-0000-0000-0000-0000000fd101','5e215e21-0000-0000-0000-000000000001',
        '5e215e21-0000-0000-0000-00000000000c','5e215e21-0000-0000-0000-00000000fd01',
        '5e215e21-0000-0000-0000-00000000cc01','DEMO SERIES',
        '5e215e21-0000-0000-0000-00000000ee02',10,
        now() - interval '7 days', now() - interval '7 days' + interval '50 min',
        'completed', true);
insert into bookings (id, studio_id, occurrence_id, member_id, status, is_demo)
values ('5e215e21-0000-0000-0000-0000000fd201','5e215e21-0000-0000-0000-000000000001',
        '5e215e21-0000-0000-0000-0000000fd101','5e215e21-0000-0000-0000-00000000b101',
        'attended', true);
delete from class_series where id = '5e215e21-0000-0000-0000-00000000fd01';
select expect_num('the purge path is not blocked by the new guard',
  (select count(*) from class_series where id='5e215e21-0000-0000-0000-00000000fd01'), 0);

reset role;
select set_config('request.jwt.claim.sub', null, false);
select 'series suite finished' as done;
