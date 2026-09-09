-- =============================================================================
-- Data model §5 — the nightly job that materialises occurrences
-- Migration 057. UUID space 0ccc, checked free.
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

-- --- Fixtures: TWO studios, in two timezones -------------------------------
insert into auth.users (id) values
  ('0ccc0ccc-0000-0000-0000-0000000000a1'),
  ('0ccc0ccc-0000-0000-0000-0000000000a2');
insert into profiles (id, email, full_name) values
  ('0ccc0ccc-0000-0000-0000-0000000000a1','occ-owner-a@example.com','Ola One'),
  ('0ccc0ccc-0000-0000-0000-0000000000a2','occ-owner-b@example.com','Ola Two');

insert into studios (id, name, slug, timezone, currency, status) values
  ('0ccc0ccc-0000-0000-0000-000000000001','Prague Studio','occ-prague','Europe/Prague','CZK','active'),
  ('0ccc0ccc-0000-0000-0000-000000000002','Manila Studio','occ-manila','Asia/Manila','PHP','active');
insert into studio_settings (studio_id) values
  ('0ccc0ccc-0000-0000-0000-000000000001'),
  ('0ccc0ccc-0000-0000-0000-000000000002');
insert into locations (id, studio_id, name, is_primary) values
  ('0ccc0ccc-0000-0000-0000-00000000000c','0ccc0ccc-0000-0000-0000-000000000001','Main',true),
  ('0ccc0ccc-0000-0000-0000-00000000000d','0ccc0ccc-0000-0000-0000-000000000002','Main',true);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('0ccc0ccc-0000-0000-0000-00000000aa01','0ccc0ccc-0000-0000-0000-000000000001','0ccc0ccc-0000-0000-0000-0000000000a1','occ-owner-a@example.com','owner'),
  ('0ccc0ccc-0000-0000-0000-00000000aa02','0ccc0ccc-0000-0000-0000-000000000002','0ccc0ccc-0000-0000-0000-0000000000a2','occ-owner-b@example.com','owner');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('0ccc0ccc-0000-0000-0000-00000000ee01','0ccc0ccc-0000-0000-0000-000000000001','0ccc0ccc-0000-0000-0000-00000000000c','Room A',10),
  ('0ccc0ccc-0000-0000-0000-00000000ee02','0ccc0ccc-0000-0000-0000-000000000001','0ccc0ccc-0000-0000-0000-00000000000c','Room B',10),
  ('0ccc0ccc-0000-0000-0000-00000000ee03','0ccc0ccc-0000-0000-0000-000000000002','0ccc0ccc-0000-0000-0000-00000000000d','Room M',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('0ccc0ccc-0000-0000-0000-00000000cc01','0ccc0ccc-0000-0000-0000-000000000001','Reformer',50,10),
  ('0ccc0ccc-0000-0000-0000-00000000cc02','0ccc0ccc-0000-0000-0000-000000000002','Mat',50,10);
insert into instructors (id, studio_id, display_name) values
  ('0ccc0ccc-0000-0000-0000-00000000d101','0ccc0ccc-0000-0000-0000-000000000001','Ivy Prague'),
  ('0ccc0ccc-0000-0000-0000-00000000d102','0ccc0ccc-0000-0000-0000-000000000002','Ines Manila');

-- =============================================================================
-- 1. A series materialises on create, and twice produces no duplicates
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','0ccc0ccc-0000-0000-0000-0000000000a1',false);

-- The insert itself fires the trigger — §5's "immediately on series create".
insert into class_series
  (id, studio_id, location_id, class_type_id, name, instructor_id, room_id,
   capacity, duration_minutes, rrule, starts_on, time_of_day)
values ('0ccc0ccc-0000-0000-0000-00000000f001','0ccc0ccc-0000-0000-0000-000000000001',
        '0ccc0ccc-0000-0000-0000-00000000000c','0ccc0ccc-0000-0000-0000-00000000cc01',
        'Reformer Flow','0ccc0ccc-0000-0000-0000-00000000d101','0ccc0ccc-0000-0000-0000-00000000ee01',
        10, 50, 'FREQ=WEEKLY;BYDAY=TU', current_date - 30, '07:00');

select set_config('t.first', (select count(*)::text from class_occurrences
  where series_id = '0ccc0ccc-0000-0000-0000-00000000f001'), false);

select expect_true('creating a series materialises it immediately',
  current_setting('t.first')::int > 45);
select expect_num('and nothing lands in the past',
  (select count(*) from class_occurrences
    where series_id = '0ccc0ccc-0000-0000-0000-00000000f001'
      and (starts_at at time zone 'Europe/Prague')::date
          < (now() at time zone 'Europe/Prague')::date)::bigint, 0);
select expect_text('the horizon is twelve months to the day',
  (select max((starts_at at time zone 'Europe/Prague')::date)
     from class_occurrences where series_id = '0ccc0ccc-0000-0000-0000-00000000f001')::text,
  (select max(d)::date::text from generate_series(
     (now() at time zone 'Europe/Prague')::date,
     ((now() at time zone 'Europe/Prague')::date + interval '12 months')::date,
     interval '1 day') d
   where extract(dow from d) = 2));

-- Running it again is the whole point of the unique index.
select set_config('t.again',
  (select generate_occurrences('0ccc0ccc-0000-0000-0000-00000000f001')::text), false);
select expect_num('a second run creates nothing',
  (current_setting('t.again')::jsonb ->> 'created')::bigint, 0);
select expect_num('...and skips every one it already made',
  (current_setting('t.again')::jsonb ->> 'skipped')::bigint,
  current_setting('t.first')::bigint);
select expect_num('...so the row count has not moved',
  (select count(*) from class_occurrences
    where series_id = '0ccc0ccc-0000-0000-0000-00000000f001')::bigint,
  current_setting('t.first')::bigint);
select expect_num('and no two rows share a slot',
  (select count(*) from (
     select series_id, series_slot_at from class_occurrences
      where series_id = '0ccc0ccc-0000-0000-0000-00000000f001'
      group by 1,2 having count(*) > 1) x)::bigint, 0);

-- =============================================================================
-- 2. An occurrence edited away from its series survives regeneration
-- =============================================================================
-- The case that makes is_exception matter, and the one the flag alone does not
-- cover: a class moved to ANOTHER DAY leaves no row in its original slot, so a
-- generator keyed on starts_at sees a gap and fills it. series_slot_at is what
-- keeps the moved row holding its origin.
reset role;
select set_config('t.moved', (select id::text from class_occurrences
  where series_id = '0ccc0ccc-0000-0000-0000-00000000f001'
    and starts_at > now() + interval '20 days'
  order by starts_at limit 1), false);
select set_config('t.slot', (select series_slot_at::text from class_occurrences
  where id = current_setting('t.moved')::uuid), false);

update class_occurrences
   set starts_at = starts_at + interval '2 days 11 hours',
       ends_at   = ends_at   + interval '2 days 11 hours'
 where id = current_setting('t.moved')::uuid;

select expect_true('moving an occurrence marks it as an exception',
  (select is_exception from class_occurrences where id = current_setting('t.moved')::uuid));
select expect_text('...and it keeps the slot it came from',
  (select series_slot_at::text from class_occurrences
    where id = current_setting('t.moved')::uuid), current_setting('t.slot'));

set role authenticated;
select set_config('request.jwt.claim.sub','0ccc0ccc-0000-0000-0000-0000000000a1',false);
select set_config('t.after',
  (select generate_occurrences('0ccc0ccc-0000-0000-0000-00000000f001')::text), false);

select expect_num('regenerating does NOT refill the vacated slot',
  (current_setting('t.after')::jsonb ->> 'created')::bigint, 0);
select expect_num('...so the member is not given two classes where the studio made one',
  (select count(*) from class_occurrences
    where series_id = '0ccc0ccc-0000-0000-0000-00000000f001')::bigint,
  current_setting('t.first')::bigint);
select expect_true('...and the moved class is still where the studio put it',
  (select starts_at > (current_setting('t.slot')::timestamptz + interval '2 days')
     from class_occurrences where id = current_setting('t.moved')::uuid));
select expect_true('the exception is still flagged after a regeneration',
  (select is_exception from class_occurrences where id = current_setting('t.moved')::uuid));

-- =============================================================================
-- 3. A DST-crossing series keeps its LOCAL time
-- =============================================================================
-- Europe/Prague leaves summer time on the last Sunday of October. A 07:00 class
-- is 05:00Z before and 06:00Z after; if the generator added intervals instead
-- of converting per occurrence, the local time would drift by an hour and a
-- 7am class would stop being a 7am class.
select expect_num('every occurrence is 07:00 local, on both sides of the change',
  (select count(distinct (starts_at at time zone 'Europe/Prague')::time)
     from class_occurrences
    where series_id = '0ccc0ccc-0000-0000-0000-00000000f001'
      and is_exception = false)::bigint, 1);
select expect_text('...and that one local time is 07:00',
  (select distinct (starts_at at time zone 'Europe/Prague')::time::text
     from class_occurrences
    where series_id = '0ccc0ccc-0000-0000-0000-00000000f001'
      and is_exception = false), '07:00:00');
select expect_num('the UTC offset really does change underneath it',
  (select count(distinct starts_at::time)
     from class_occurrences
    where series_id = '0ccc0ccc-0000-0000-0000-00000000f001'
      and is_exception = false)::bigint, 2);

-- =============================================================================
-- 4. Two studios in one cron run
-- =============================================================================
-- The shape that broke the morning brief: a loop over studios inside ONE
-- transaction, where the second studio hit the first one's leftover temp table.
select set_config('request.jwt.claim.sub','0ccc0ccc-0000-0000-0000-0000000000a2',false);
insert into class_series
  (id, studio_id, location_id, class_type_id, name, instructor_id, room_id,
   capacity, duration_minutes, rrule, starts_on, time_of_day, status)
values ('0ccc0ccc-0000-0000-0000-00000000f002','0ccc0ccc-0000-0000-0000-000000000002',
        '0ccc0ccc-0000-0000-0000-00000000000d','0ccc0ccc-0000-0000-0000-00000000cc02',
        'Mat','0ccc0ccc-0000-0000-0000-00000000d102','0ccc0ccc-0000-0000-0000-00000000ee03',
        10, 50, 'FREQ=WEEKLY;BYDAY=WE', current_date, '18:00', 'ended');

select expect_num('a series that has ended materialises nothing',
  (select count(*) from class_occurrences
    where series_id = '0ccc0ccc-0000-0000-0000-00000000f002')::bigint, 0);

reset role;
-- Clear the day's claims so the sweep actually runs both studios.
delete from job_runs where job_key like 'occurrences:%';
update class_series set status = 'active' where id = '0ccc0ccc-0000-0000-0000-00000000f002';
delete from class_occurrences where series_id = '0ccc0ccc-0000-0000-0000-00000000f002';
delete from job_runs where job_key like 'occurrences:%';

select set_config('t.cron', (select generate_all_occurrences()::text), false);
select expect_true('the cron ran more than one studio',
  (current_setting('t.cron')::jsonb ->> 'studios')::int >= 2);
select expect_num('no studio failed',
  (current_setting('t.cron')::jsonb ->> 'failed_studios')::bigint, 0);
select expect_true('the SECOND studio got its occurrences too',
  (select count(*) > 45 from class_occurrences
    where series_id = '0ccc0ccc-0000-0000-0000-00000000f002'));
select expect_text('...at 18:00 Manila, not 18:00 Prague',
  (select distinct (starts_at at time zone 'Asia/Manila')::time::text
     from class_occurrences where series_id = '0ccc0ccc-0000-0000-0000-00000000f002'), '18:00:00');
select expect_num('both studios are claimed in job_runs, done',
  (select count(*) from job_runs
    where job_key like 'occurrences:0ccc0ccc%' and status = 'done')::bigint, 2);

-- A second run the same day is a no-op, like every other claimed job.
select set_config('t.cron2', (select generate_all_occurrences()::text), false);
select expect_num('running the cron twice in one local day claims nothing new',
  (current_setting('t.cron2')::jsonb ->> 'studios')::bigint, 0);

set role authenticated;
select set_config('request.jwt.claim.sub','0ccc0ccc-0000-0000-0000-0000000000a1',false);
select expect_raises('and a signed-in user cannot run the sweep at all',
  $q$select generate_all_occurrences()$q$, '42501');

-- =============================================================================
-- 5. A collision reports the occurrence, not the whole run
-- =============================================================================
-- One class in the way must not cost the studio the other fifty-one weeks.
reset role;
insert into class_occurrences
  (studio_id, location_id, class_type_id, name, instructor_id, room_id, capacity,
   starts_at, ends_at, status)
select '0ccc0ccc-0000-0000-0000-000000000001','0ccc0ccc-0000-0000-0000-00000000000c',
       '0ccc0ccc-0000-0000-0000-00000000cc01','Blocker',
       '0ccc0ccc-0000-0000-0000-00000000d101','0ccc0ccc-0000-0000-0000-00000000ee02',
       10,
       -- d::date, and it matters. generate_series over dates resolves to the
       -- TIMESTAMPTZ overload, so `d + time` is already an instant and
       -- `at time zone` then converts it the OTHER way — these blockers landed
       -- at 13:00 Prague instead of 09:00 and clashed with nothing. Casting to
       -- date makes it a naive local timestamp again, which is what
       -- `at time zone` is for.
       ((d::date + time '09:00') at time zone 'Europe/Prague'),
       ((d::date + time '09:00') at time zone 'Europe/Prague') + interval '50 minutes',
       'scheduled'
  -- Step a DAY at a time and filter to Thursdays. Stepping seven days from
  -- today only ever lands on today's weekday, so the filter matched nothing and
  -- no blocker was inserted at all — a clash test with nothing to clash with.
  from generate_series((now() at time zone 'Europe/Prague')::date + 1,
                       (now() at time zone 'Europe/Prague')::date + 28,
                       interval '1 day') d
 where extract(dow from d) = 4;

set role authenticated;
select set_config('request.jwt.claim.sub','0ccc0ccc-0000-0000-0000-0000000000a1',false);
insert into class_series
  (id, studio_id, location_id, class_type_id, name, instructor_id, room_id,
   capacity, duration_minutes, rrule, starts_on, time_of_day)
values ('0ccc0ccc-0000-0000-0000-00000000f003','0ccc0ccc-0000-0000-0000-000000000001',
        '0ccc0ccc-0000-0000-0000-00000000000c','0ccc0ccc-0000-0000-0000-00000000cc01',
        'Clasher','0ccc0ccc-0000-0000-0000-00000000d101','0ccc0ccc-0000-0000-0000-00000000ee01',
        10, 50, 'FREQ=WEEKLY;BYDAY=TH', current_date, '09:00');

-- The trigger has already run at INSERT and done exactly this work, conflicts
-- and all, so a call now would truthfully report created:0. Clear what it made
-- and run the function once, cleanly, to read the whole report.
reset role;
delete from class_occurrences where series_id = '0ccc0ccc-0000-0000-0000-00000000f003';
set role authenticated;
select set_config('request.jwt.claim.sub','0ccc0ccc-0000-0000-0000-0000000000a1',false);
select set_config('t.clash',
  (select generate_occurrences('0ccc0ccc-0000-0000-0000-00000000f003')::text), false);
select expect_true('the clashing weeks are reported',
  jsonb_array_length(current_setting('t.clash')::jsonb -> 'conflicts') >= 2);
select expect_text('...and named as an instructor clash',
  (current_setting('t.clash')::jsonb -> 'conflicts' -> 0 ->> 'reason'), 'instructor_busy');
select expect_true('...while every other week was still created',
  (current_setting('t.clash')::jsonb ->> 'created')::int > 40);
select expect_num('the run made every week except the ones that clashed',
  (select count(*) from class_occurrences
    where series_id = '0ccc0ccc-0000-0000-0000-00000000f003')::bigint,
  (current_setting('t.clash')::jsonb ->> 'created')::bigint);

-- =============================================================================
-- 6. The horizon is a studio setting, and the rule is parsed not guessed
-- =============================================================================
reset role;
update studio_settings set occurrence_horizon_months = 1
 where studio_id = '0ccc0ccc-0000-0000-0000-000000000002';
delete from class_occurrences where series_id = '0ccc0ccc-0000-0000-0000-00000000f002';
set role authenticated;
select set_config('request.jwt.claim.sub','0ccc0ccc-0000-0000-0000-0000000000a2',false);
select set_config('t.short',
  (select generate_occurrences('0ccc0ccc-0000-0000-0000-00000000f002')::text), false);
select expect_true('a one-month horizon materialises about four weeks',
  (current_setting('t.short')::jsonb ->> 'created')::int between 4 and 5);

-- Loudly, rather than generating something weekly and wrong. The REFUSAL LANDS
-- ON THE UPDATE, because the materialise trigger runs inside it — so a studio
-- cannot save a recurrence rule the product would quietly fail to honour. That
-- is a better place for it to fail than the first nightly run.
select expect_raises('a rule this parser does not understand cannot even be saved',
  $q$update class_series set rrule = 'FREQ=MONTHLY;BYMONTHDAY=1'
      where id = '0ccc0ccc-0000-0000-0000-00000000f002'$q$, 'PT422');
select expect_text('...and the series keeps the rule it had',
  (select rrule from class_series where id = '0ccc0ccc-0000-0000-0000-00000000f002'),
  'FREQ=WEEKLY;BYDAY=WE');

-- =============================================================================
-- 7. Who may materialise
-- =============================================================================
select set_config('request.jwt.claim.sub','0ccc0ccc-0000-0000-0000-0000000000a2',false);
select expect_raises('an owner of another studio cannot materialise this one',
  $q$select generate_occurrences('0ccc0ccc-0000-0000-0000-00000000f001')$q$, 'PT403');
select expect_raises('and an unknown series is refused',
  $q$select generate_occurrences('0ccc0ccc-0000-0000-0000-0000000000ff')$q$, 'PT404');
