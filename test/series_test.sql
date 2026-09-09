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
insert into studio_settings (studio_id) values
  ('5e215e21-0000-0000-0000-000000000001'),
  ('5e215e21-0000-0000-0000-000000000002');
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

reset role;
select set_config('request.jwt.claim.sub', null, false);
select 'series suite finished' as done;
