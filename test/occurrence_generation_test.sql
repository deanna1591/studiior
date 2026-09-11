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
-- Pinned at 365 days, not left on the default: migration 068 moved that default
-- from twelve months to sixty days, and an assertion about "the horizon" should
-- be reading the studio's setting rather than agreeing with whatever the column
-- currently ships with.
insert into studio_settings (studio_id, occurrence_horizon_days) values
  ('0ccc0ccc-0000-0000-0000-000000000001', 365),
  ('0ccc0ccc-0000-0000-0000-000000000002', 365);
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
select expect_text('the horizon is the studio''s own number of days, to the day',
  (select max((starts_at at time zone 'Europe/Prague')::date)
     from class_occurrences where series_id = '0ccc0ccc-0000-0000-0000-00000000f001')::text,
  (select max(d)::date::text from generate_series(
     (now() at time zone 'Europe/Prague')::date,
     (now() at time zone 'Europe/Prague')::date + 365,
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
update studio_settings set occurrence_horizon_days = 30
 where studio_id = '0ccc0ccc-0000-0000-0000-000000000002';
delete from class_occurrences where series_id = '0ccc0ccc-0000-0000-0000-00000000f002';
set role authenticated;
select set_config('request.jwt.claim.sub','0ccc0ccc-0000-0000-0000-0000000000a2',false);
select set_config('t.short',
  (select generate_occurrences('0ccc0ccc-0000-0000-0000-00000000f002')::text), false);
select expect_true('a thirty-day horizon materialises about four weeks',
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

-- =============================================================================
-- 7. Shortening the horizon, which used to do nothing at all
-- =============================================================================
-- Migration 068. Before it, `generate_occurrences()` only ever inserted, so a
-- studio could shorten the setting, run the nightly job and still be carrying a
-- year of classes nobody had agreed to teach. Proved on real data before the
-- fix: set to two months, ran the job, furthest class unchanged at 2027-09-09.
reset role;
select set_config('request.jwt.claim.sub', null, false);
update studio_settings set occurrence_horizon_days = 365
 where studio_id = '0ccc0ccc-0000-0000-0000-000000000001';
set role authenticated;
select set_config('request.jwt.claim.sub','0ccc0ccc-0000-0000-0000-0000000000a1',false);
select generate_occurrences('0ccc0ccc-0000-0000-0000-00000000f001');

select set_config('t.h0', (select count(*)::text from class_occurrences
  where series_id = '0ccc0ccc-0000-0000-0000-00000000f001' and status = 'scheduled'), false);
select expect_true('a year-long horizon is carrying a year of classes',
  current_setting('t.h0')::int > 45);

-- The preview writes nothing.
select set_config('t.prev', (select set_occurrence_horizon(
  '0ccc0ccc-0000-0000-0000-000000000001', 60, false)::text), false);
select expect_true('shortening asks first',
  (current_setting('t.prev')::jsonb ->> 'requires_confirmation')::boolean);
select expect_true('...and says how many classes it would remove',
  (current_setting('t.prev')::jsonb ->> 'will_delete')::int > 30);
select expect_num('...having removed none of them yet',
  (select count(*) from class_occurrences
    where series_id = '0ccc0ccc-0000-0000-0000-00000000f001'
      and status = 'scheduled')::bigint, current_setting('t.h0')::bigint);
select expect_num('...and left the setting alone',
  (select occurrence_horizon_days from studio_settings
    where studio_id = '0ccc0ccc-0000-0000-0000-000000000001')::bigint, 365);

select set_config('t.app', (select set_occurrence_horizon(
  '0ccc0ccc-0000-0000-0000-000000000001', 60, true)::text), false);
select expect_true('applying it reports ok', (current_setting('t.app')::jsonb ->> 'ok')::boolean);
select expect_num('the setting is what the studio asked for',
  (select occurrence_horizon_days from studio_settings
    where studio_id = '0ccc0ccc-0000-0000-0000-000000000001')::bigint, 60);
select expect_num('nothing is scheduled past the new edge',
  (select count(*) from class_occurrences
    where series_id = '0ccc0ccc-0000-0000-0000-00000000f001'
      and status = 'scheduled'
      and (starts_at at time zone 'Europe/Prague')::date
          > (now() at time zone 'Europe/Prague')::date + 60)::bigint, 0);
select expect_true('...and what is inside it is untouched',
  (select count(*) from class_occurrences
    where series_id = '0ccc0ccc-0000-0000-0000-00000000f001'
      and status = 'scheduled') between 7 and 10);

-- DELETED, not cancelled. A cancelled row keeps its series_slot_at, and the
-- unique index on (series_id, series_slot_at) would then make the hole
-- permanent — the studio lengthens the horizon again and the generator skips
-- every slot it had cancelled. Proved by lengthening it right back.
reset role;
select set_config('request.jwt.claim.sub', null, false);
select expect_num('the removed classes are gone, not sitting there cancelled',
  (select count(*) from class_occurrences
    where series_id = '0ccc0ccc-0000-0000-0000-00000000f001'
      and status = 'cancelled')::bigint, 0);
set role authenticated;
select set_config('request.jwt.claim.sub','0ccc0ccc-0000-0000-0000-0000000000a1',false);
select set_occurrence_horizon('0ccc0ccc-0000-0000-0000-000000000001', 365, true);
select expect_num('...so lengthening it again refills the calendar completely',
  (select count(*) from class_occurrences
    where series_id = '0ccc0ccc-0000-0000-0000-00000000f001'
      and status = 'scheduled')::bigint, current_setting('t.h0')::bigint);

-- =============================================================================
-- 8. What a horizon may never delete
-- =============================================================================
-- A member booked on a class eight months out, a class somebody has moved, a
-- class a human assigned, and a one-off nobody generated.
reset role;
select set_config('request.jwt.claim.sub', null, false);
insert into members (id, studio_id, first_name, last_name, email, status) values
  ('0ccc0ccc-0000-0000-0000-0000000000c1','0ccc0ccc-0000-0000-0000-000000000001',
   'Mona','Faraway','occ-mona@example.com','active');
select set_config('t.far', (select id::text from class_occurrences
  where series_id = '0ccc0ccc-0000-0000-0000-00000000f001'
    and starts_at > now() + interval '200 days' order by starts_at limit 1), false);
insert into bookings (studio_id, occurrence_id, member_id, status)
values ('0ccc0ccc-0000-0000-0000-000000000001', current_setting('t.far')::uuid,
        '0ccc0ccc-0000-0000-0000-0000000000c1', 'booked');

set role authenticated;
select set_config('request.jwt.claim.sub','0ccc0ccc-0000-0000-0000-0000000000a1',false);
select set_config('t.ref', (select set_occurrence_horizon(
  '0ccc0ccc-0000-0000-0000-000000000001', 60, true)::text), false);
select expect_text('a booking beyond the new edge refuses the whole change',
  current_setting('t.ref')::jsonb ->> 'reason', 'members_booked_beyond_horizon');
select expect_num('...naming the class rather than counting it',
  jsonb_array_length(current_setting('t.ref')::jsonb -> 'blocked')::bigint, 1);
select expect_true('...with a date somebody can act on',
  (current_setting('t.ref')::jsonb -> 'blocked' -> 0 ->> 'local') is not null);
select expect_num('...and CONFIRMED still means refused: nothing was deleted',
  (select count(*) from class_occurrences
    where series_id = '0ccc0ccc-0000-0000-0000-00000000f001'
      and status = 'scheduled')::bigint, current_setting('t.h0')::bigint);
select expect_num('...and the setting did not move either',
  (select occurrence_horizon_days from studio_settings
    where studio_id = '0ccc0ccc-0000-0000-0000-000000000001')::bigint, 365);

-- Clear the booking; keep a moved class and a manually assigned one.
reset role;
select set_config('request.jwt.claim.sub', null, false);
delete from bookings where occurrence_id = current_setting('t.far')::uuid;
update class_occurrences set is_exception = true where id = current_setting('t.far')::uuid;
select set_config('t.far2', (select id::text from class_occurrences
  where series_id = '0ccc0ccc-0000-0000-0000-00000000f001'
    and starts_at > now() + interval '200 days'
    and id <> current_setting('t.far')::uuid order by starts_at limit 1), false);
update class_occurrences
   set assigned_by = '0ccc0ccc-0000-0000-0000-0000000000a1'
 where id = current_setting('t.far2')::uuid;
-- A one-off, with no series at all: typed by a person for eight months out.
insert into class_occurrences
  (id, studio_id, location_id, class_type_id, name, capacity, starts_at, ends_at, status, staffing)
values ('0ccc0ccc-0000-0000-0000-00000000f0f1','0ccc0ccc-0000-0000-0000-000000000001',
        '0ccc0ccc-0000-0000-0000-00000000000c','0ccc0ccc-0000-0000-0000-00000000cc01',
        'Deliberate one-off', 10,
        ((current_date + 250) + time '11:00') at time zone 'Europe/Prague',
        ((current_date + 250) + time '11:50') at time zone 'Europe/Prague',
        'scheduled','open');

set role authenticated;
select set_config('request.jwt.claim.sub','0ccc0ccc-0000-0000-0000-0000000000a1',false);
select set_config('t.keep', (select set_occurrence_horizon(
  '0ccc0ccc-0000-0000-0000-000000000001', 60, true)::text), false);
select expect_true('it goes through once nobody is booked',
  (current_setting('t.keep')::jsonb ->> 'ok')::boolean);
select expect_num('a class somebody had moved is kept, and reported',
  (current_setting('t.keep')::jsonb ->> 'kept_edited')::bigint, 1);
select expect_num('...as is one a human assigned an instructor to',
  (current_setting('t.keep')::jsonb ->> 'kept_manual')::bigint, 1);
reset role;
select set_config('request.jwt.claim.sub', null, false);
select expect_true('...and both are still there',
  (select count(*) from class_occurrences
    where id in (current_setting('t.far')::uuid, current_setting('t.far2')::uuid)) = 2);
select expect_num('a one-off nobody generated is never swept away by a horizon',
  (select count(*) from class_occurrences
    where id = '0ccc0ccc-0000-0000-0000-00000000f0f1')::bigint, 1);

-- Who may move it, and what it will accept.
set role authenticated;
select set_config('request.jwt.claim.sub','0ccc0ccc-0000-0000-0000-0000000000a2',false);
select expect_raises('another studio''s owner cannot change this one''s horizon',
  $q$select set_occurrence_horizon('0ccc0ccc-0000-0000-0000-000000000001', 90, true)$q$, 'PT403');
select set_config('request.jwt.claim.sub','0ccc0ccc-0000-0000-0000-0000000000a1',false);
select expect_raises('a horizon of three days is refused',
  $q$select set_occurrence_horizon('0ccc0ccc-0000-0000-0000-000000000001', 3, true)$q$, 'PT422');
select expect_raises('...and so is one of five years',
  $q$select set_occurrence_horizon('0ccc0ccc-0000-0000-0000-000000000001', 1825, true)$q$, 'PT422');

-- The default a new studio gets.
reset role;
select set_config('request.jwt.claim.sub', null, false);
insert into studios (id, name, slug, timezone, currency, status) values
  ('0ccc0ccc-0000-0000-0000-000000000003','Fresh Studio','occ-fresh','Europe/Prague','CZK','active');
insert into studio_settings (studio_id) values ('0ccc0ccc-0000-0000-0000-000000000003');
select expect_num('a new studio starts on sixty days, not twelve months',
  (select occurrence_horizon_days from studio_settings
    where studio_id = '0ccc0ccc-0000-0000-0000-000000000003')::bigint, 60);

-- =============================================================================
-- 9. THE CALENDAR'S RANGE, IN TWO TIMEZONES, IN ONE RUN
-- =============================================================================
-- The staff calendar rendered an empty grid for every day. Two of the three
-- causes are day-boundary maths, and neither could be caught by a fixture whose
-- studio, server and browser all share a zone. This suite already has one
-- studio in Europe/Prague and one in Asia/Manila; both are asked here.
--
-- A 07:00 Manila class is stored at 23:00 UTC the PREVIOUS day. Anything that
-- compares the stored instant against a date — rather than converting first —
-- loses it, which for a Manila studio is every morning class it runs.
reset role;
select set_config('request.jwt.claim.sub', null, false);
insert into class_occurrences
  (id, studio_id, location_id, class_type_id, room_id, name, capacity, instructor_id,
   starts_at, ends_at, status, staffing)
values
  -- Manila: 07:00 and 17:00 on Wednesday 18 November, exactly as reported.
  ('0ccc0ccc-0000-0000-0000-00000000ff01','0ccc0ccc-0000-0000-0000-000000000002',
   '0ccc0ccc-0000-0000-0000-00000000000d','0ccc0ccc-0000-0000-0000-00000000cc02',
   '0ccc0ccc-0000-0000-0000-00000000ee03','MNL MORNING',10,'0ccc0ccc-0000-0000-0000-00000000d102',
   (date '2026-11-18' + time '07:00') at time zone 'Asia/Manila',
   (date '2026-11-18' + time '07:50') at time zone 'Asia/Manila','scheduled','assigned'),
  ('0ccc0ccc-0000-0000-0000-00000000ff02','0ccc0ccc-0000-0000-0000-000000000002',
   '0ccc0ccc-0000-0000-0000-00000000000d','0ccc0ccc-0000-0000-0000-00000000cc02',
   '0ccc0ccc-0000-0000-0000-00000000ee03','MNL EVENING',10,'0ccc0ccc-0000-0000-0000-00000000d102',
   (date '2026-11-18' + time '17:00') at time zone 'Asia/Manila',
   (date '2026-11-18' + time '17:50') at time zone 'Asia/Manila','scheduled','assigned'),
  -- Manila, late the night BEFORE: 23:30 on the 17th, which is 15:30 UTC on the
  -- 17th. It must not leak into the 18th.
  ('0ccc0ccc-0000-0000-0000-00000000ff03','0ccc0ccc-0000-0000-0000-000000000002',
   '0ccc0ccc-0000-0000-0000-00000000000d','0ccc0ccc-0000-0000-0000-00000000cc02',
   '0ccc0ccc-0000-0000-0000-00000000ee03','MNL LATE NIGHT',10,null,
   (date '2026-11-17' + time '23:30') at time zone 'Asia/Manila',
   (date '2026-11-18' + time '00:20') at time zone 'Asia/Manila','scheduled','open'),
  -- Prague, 07:00 on the same date: 06:00 UTC, the other side of the boundary.
  ('0ccc0ccc-0000-0000-0000-00000000ff04','0ccc0ccc-0000-0000-0000-000000000001',
   '0ccc0ccc-0000-0000-0000-00000000000c','0ccc0ccc-0000-0000-0000-00000000cc01',
   '0ccc0ccc-0000-0000-0000-00000000ee01','PRG MORNING',10,'0ccc0ccc-0000-0000-0000-00000000d101',
   (date '2026-11-18' + time '07:00') at time zone 'Europe/Prague',
   (date '2026-11-18' + time '07:50') at time zone 'Europe/Prague','scheduled','assigned');

select expect_text('a 07:00 Manila class is stored the previous day in UTC',
  (select to_char(starts_at at time zone 'UTC','YYYY-MM-DD HH24:MI')
     from class_occurrences where id = '0ccc0ccc-0000-0000-0000-00000000ff01'),
  '2026-11-17 23:00');

set role authenticated;
select set_config('request.jwt.claim.sub','0ccc0ccc-0000-0000-0000-0000000000a2',false);
select set_config('t.mnl', (select count(*)::text from schedule_range(
  '0ccc0ccc-0000-0000-0000-000000000002', date '2026-11-18', date '2026-11-18')), false);
select expect_text('Manila''s 18 November returns both of that day''s classes',
  current_setting('t.mnl'), '2');
select expect_text('...at the times the studio actually runs them',
  (select string_agg(local_start, ',' order by local_start) from schedule_range(
     '0ccc0ccc-0000-0000-0000-000000000002', date '2026-11-18', date '2026-11-18')),
  '07:00,17:00');
select expect_text('...and the 23:30 the night before stays on the 17th',
  (select string_agg(occ_name, ',') from schedule_range(
     '0ccc0ccc-0000-0000-0000-000000000002', date '2026-11-17', date '2026-11-17')),
  'MNL LATE NIGHT');
select expect_num('...so a day range never double-counts a boundary class',
  (select count(*) from schedule_range(
     '0ccc0ccc-0000-0000-0000-000000000002', date '2026-11-17', date '2026-11-18'))::bigint, 3);
select expect_num('the visible hours can be derived from the rows themselves',
  (select max(end_minutes) from schedule_range(
     '0ccc0ccc-0000-0000-0000-000000000002', date '2026-11-18', date '2026-11-18'))::bigint,
  17 * 60 + 50);

-- The same date, the other studio, the other side of UTC. Same call, same run.
select set_config('request.jwt.claim.sub','0ccc0ccc-0000-0000-0000-0000000000a1',false);
select expect_text('Prague''s 18 November returns Prague''s class',
  (select string_agg(occ_name || ' ' || local_start, ',') from schedule_range(
     '0ccc0ccc-0000-0000-0000-000000000001', date '2026-11-18', date '2026-11-18')
   where occ_name like 'PRG%'), 'PRG MORNING 07:00');
select expect_num('...and none of Manila''s',
  (select count(*) from schedule_range(
     '0ccc0ccc-0000-0000-0000-000000000001', date '2026-11-18', date '2026-11-18')
    where occ_name like 'MNL%')::bigint, 0);

-- studio_today is the studio's day, not the server's.
select expect_text('the studio''s today is asked of the studio',
  studio_today('0ccc0ccc-0000-0000-0000-000000000002')::text,
  (now() at time zone 'Asia/Manila')::date::text);

-- Guards.
select set_config('request.jwt.claim.sub','0ccc0ccc-0000-0000-0000-0000000000a1',false);
select expect_raises('another studio''s owner cannot read this one''s timetable',
  $q$select * from schedule_range('0ccc0ccc-0000-0000-0000-000000000002',
       date '2026-11-18', date '2026-11-18')$q$, 'PT403');
select expect_raises('a range that ends before it starts is refused',
  $q$select * from schedule_range('0ccc0ccc-0000-0000-0000-000000000001',
       date '2026-11-18', date '2026-11-01')$q$, 'PT400');
select expect_raises('and a year in one call is a mistake, not a request',
  $q$select * from schedule_range('0ccc0ccc-0000-0000-0000-000000000001',
       date '2026-01-01', date '2026-12-31')$q$, 'PT422');

-- =============================================================================
-- 10. An empty day must be able to say where the classes ARE
-- =============================================================================
-- The Manila studio's 07:00 class on 18 November is stored at 23:00 UTC on the
-- 17th. Asked from the 17th, the next day with classes is the EIGHTEENTH — the
-- studio's day, not the instant's. Everything else here is compared against the
-- data rather than against a literal, because this suite's other sections put
-- occurrences on this studio too.
set role authenticated;
select set_config('request.jwt.claim.sub','0ccc0ccc-0000-0000-0000-0000000000a2',false);

select expect_text('the next day with classes is the studio''s day, not the instant''s',
  next_class_day('0ccc0ccc-0000-0000-0000-000000000002', date '2026-11-17') ->> 'next',
  '2026-11-18');
select expect_num('...and it says how many are on it',
  (next_class_day('0ccc0ccc-0000-0000-0000-000000000002', date '2026-11-17')
    ->> 'classes_that_day')::bigint,
  (select count(*) from schedule_range('0ccc0ccc-0000-0000-0000-000000000002',
     date '2026-11-18', date '2026-11-18')));
select expect_text('an empty day points at the real next one, whatever is on the timetable',
  next_class_day('0ccc0ccc-0000-0000-0000-000000000002', date '2026-10-01') ->> 'next',
  (select min((starts_at at time zone 'Asia/Manila')::date)::text
     from class_occurrences
    where studio_id = '0ccc0ccc-0000-0000-0000-000000000002' and status <> 'cancelled'
      and (starts_at at time zone 'Asia/Manila')::date > date '2026-10-01'));
select expect_text('past the end of the timetable it points backwards instead',
  next_class_day('0ccc0ccc-0000-0000-0000-000000000002', date '2030-01-01') ->> 'previous',
  (select max((starts_at at time zone 'Asia/Manila')::date)::text
     from class_occurrences
    where studio_id = '0ccc0ccc-0000-0000-0000-000000000002' and status <> 'cancelled'));
select expect_true('...and there is no next one to point at',
  (next_class_day('0ccc0ccc-0000-0000-0000-000000000002', date '2030-01-01') -> 'next') = 'null'::jsonb);
select expect_true('...while still saying the studio HAS a timetable',
  (next_class_day('0ccc0ccc-0000-0000-0000-000000000002', date '2030-01-01') ->> 'has_any')::boolean);

select set_config('request.jwt.claim.sub','0ccc0ccc-0000-0000-0000-0000000000a1',false);
select expect_raises('another studio''s owner cannot ask where this one''s classes are',
  $q$select next_class_day('0ccc0ccc-0000-0000-0000-000000000002', date '2026-10-01')$q$, 'PT403');
reset role;

-- =============================================================================
-- 11. STUDIO CLOSURES, in two timezones, in one run
-- =============================================================================
-- Migration 074. Prague closes a whole day; Manila closes an afternoon on the
-- same date. Both are asked in one pass, because a closure is a studio-local
-- date and a fixture where both studios share a zone would prove nothing.
reset role;
select set_config('request.jwt.claim.sub', null, false);

-- A weekday series in each studio, running well past the closure dates.
insert into class_series
  (id, studio_id, location_id, class_type_id, room_id, name, capacity,
   duration_minutes, rrule, starts_on, time_of_day)
values
  ('0ccc0ccc-0000-0000-0000-00000000c001','0ccc0ccc-0000-0000-0000-000000000001',
   '0ccc0ccc-0000-0000-0000-00000000000c','0ccc0ccc-0000-0000-0000-00000000cc01',
   '0ccc0ccc-0000-0000-0000-00000000ee02','PRG Daily', 10, 50,
   'FREQ=WEEKLY;BYDAY=SU,MO,TU,WE,TH,FR,SA', current_date, '11:00'),
  ('0ccc0ccc-0000-0000-0000-00000000c002','0ccc0ccc-0000-0000-0000-000000000002',
   '0ccc0ccc-0000-0000-0000-00000000000d','0ccc0ccc-0000-0000-0000-00000000cc02',
   '0ccc0ccc-0000-0000-0000-00000000ee03','MNL Morning', 10, 50,
   'FREQ=WEEKLY;BYDAY=SU,MO,TU,WE,TH,FR,SA', current_date, '08:00');
insert into class_series
  (id, studio_id, location_id, class_type_id, room_id, name, capacity,
   duration_minutes, rrule, starts_on, time_of_day)
values
  ('0ccc0ccc-0000-0000-0000-00000000c003','0ccc0ccc-0000-0000-0000-000000000002',
   '0ccc0ccc-0000-0000-0000-00000000000d','0ccc0ccc-0000-0000-0000-00000000cc02',
   '0ccc0ccc-0000-0000-0000-00000000ee03','MNL Afternoon', 10, 50,
   'FREQ=WEEKLY;BYDAY=SU,MO,TU,WE,TH,FR,SA', current_date, '15:00');

select set_config('t.cd', (current_date + 20)::text, false);

-- ---- the generator skips a closed period --------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub','0ccc0ccc-0000-0000-0000-0000000000a1',false);
-- Scoped to the series under test: this suite's earlier sections put other
-- Prague series on the calendar, so a whole-day count is a count of them too.
select expect_num('before closing, Prague has a class that day',
  (select count(*) from class_occurrences
    where series_id = '0ccc0ccc-0000-0000-0000-00000000c001' and status = 'scheduled'
      and (starts_at at time zone 'Europe/Prague')::date = current_setting('t.cd')::date)::bigint, 1);

select close_studio('0ccc0ccc-0000-0000-0000-000000000001',
  current_setting('t.cd')::date, current_setting('t.cd')::date,
  'Refit', null, null, true);
select expect_num('closing takes the class off the calendar',
  (select count(*) from class_occurrences
    where series_id = '0ccc0ccc-0000-0000-0000-00000000c001' and status = 'scheduled'
      and (starts_at at time zone 'Europe/Prague')::date = current_setting('t.cd')::date)::bigint, 0);
select expect_num('...and the generator does not put it back',
  (generate_occurrences('0ccc0ccc-0000-0000-0000-00000000c001') ->> 'created')::bigint, 0);
select expect_true('...and says it skipped it because the studio is shut',
  (generate_occurrences('0ccc0ccc-0000-0000-0000-00000000c001') ->> 'closed')::int > 0);
select expect_num('the day either side is untouched',
  (select count(*) from class_occurrences
    where series_id = '0ccc0ccc-0000-0000-0000-00000000c001' and status = 'scheduled'
      and (starts_at at time zone 'Europe/Prague')::date
          = current_setting('t.cd')::date + 1)::bigint, 1);

-- ---- one studio's closure is not the other's ----------------------------
select set_config('request.jwt.claim.sub','0ccc0ccc-0000-0000-0000-0000000000a2',false);
select expect_num('Manila is open on the day Prague is shut',
  (select count(*) from class_occurrences
    where series_id in ('0ccc0ccc-0000-0000-0000-00000000c002','0ccc0ccc-0000-0000-0000-00000000c003')
      and status = 'scheduled'
      and (starts_at at time zone 'Asia/Manila')::date = current_setting('t.cd')::date)::bigint, 2);

-- ---- a PARTIAL day only takes the classes inside its hours --------------
select close_studio('0ccc0ccc-0000-0000-0000-000000000002',
  current_setting('t.cd')::date, current_setting('t.cd')::date,
  'Afternoon deep clean', time '14:00', time '18:00', true);
select expect_num('a partial closure leaves the morning class alone',
  (select count(*) from class_occurrences
    where series_id in ('0ccc0ccc-0000-0000-0000-00000000c002','0ccc0ccc-0000-0000-0000-00000000c003')
      and status = 'scheduled'
      and (starts_at at time zone 'Asia/Manila')::date = current_setting('t.cd')::date)::bigint, 1);
select expect_text('...and the one left is the morning one',
  (select name from class_occurrences
    where series_id in ('0ccc0ccc-0000-0000-0000-00000000c002','0ccc0ccc-0000-0000-0000-00000000c003')
      and status = 'scheduled'
      and (starts_at at time zone 'Asia/Manila')::date = current_setting('t.cd')::date), 'MNL Morning');
select expect_num('...and regenerating does not bring the afternoon back',
  (generate_occurrences('0ccc0ccc-0000-0000-0000-00000000c003') ->> 'created')::bigint, 0);
select expect_num('...while the morning series still generates',
  (generate_occurrences('0ccc0ccc-0000-0000-0000-00000000c002') ->> 'closed')::bigint, 0);

-- The predicate itself, in the studio's own clock.
reset role;
select set_config('request.jwt.claim.sub', null, false);
select expect_true('15:00 Manila is inside a 14:00-18:00 Manila closure',
  studio_closed_at('0ccc0ccc-0000-0000-0000-000000000002',
    (current_setting('t.cd')::date + time '15:00') at time zone 'Asia/Manila',
    (current_setting('t.cd')::date + time '15:50') at time zone 'Asia/Manila'));
select expect_true('08:00 Manila is not',
  not studio_closed_at('0ccc0ccc-0000-0000-0000-000000000002',
    (current_setting('t.cd')::date + time '08:00') at time zone 'Asia/Manila',
    (current_setting('t.cd')::date + time '08:50') at time zone 'Asia/Manila'));
-- The same INSTANT as Manila's 15:00 is 09:00 in Prague, which Prague's own
-- whole-day closure covers and Manila's afternoon one has nothing to say about.
select expect_true('a closure is read in the studio it belongs to, not in UTC',
  studio_closed_at('0ccc0ccc-0000-0000-0000-000000000001',
    (current_setting('t.cd')::date + time '11:00') at time zone 'Europe/Prague',
    (current_setting('t.cd')::date + time '11:50') at time zone 'Europe/Prague'));

-- ---- reopening regenerates, and resurrects nothing ----------------------
set role authenticated;
select set_config('request.jwt.claim.sub','0ccc0ccc-0000-0000-0000-0000000000a1',false);
select set_config('t.cl', (select id::text from studio_closures
  where studio_id='0ccc0ccc-0000-0000-0000-000000000001'), false);
select set_config('t.re', (select reopen_studio(current_setting('t.cl')::uuid)::text), false);
select expect_true('reopening reports what stays cancelled rather than hiding it',
  (current_setting('t.re')::jsonb ->> 'still_cancelled')::int > 0);
reset role;
select set_config('request.jwt.claim.sub', null, false);
-- SCOPED TO THE SERIES, like the assertions twenty lines above and for the
-- reason their own comment gives: this suite's earlier sections put other
-- Prague classes on the calendar, and a whole-studio count on this date is a
-- count of those too. `t.cd` is current_date + 20, so WHICH of them land here
-- depends on the weekday the suite is run — these two passed for as long as
-- that date happened to be clear and failed the first time it was not. The
-- third instance of "an unfiltered count(*) is a count of whatever ran first",
-- after scheduling_test.sql's notifications and onboarding_test.sql's invites.
select expect_num('the cancelled class is STILL cancelled — members were told it was off',
  (select count(*) from class_occurrences
    where series_id = '0ccc0ccc-0000-0000-0000-00000000c001'
      and (starts_at at time zone 'Europe/Prague')::date = current_setting('t.cd')::date
      and status = 'cancelled')::bigint, 1);
select expect_num('...and nothing new was created in its slot',
  (select count(*) from class_occurrences
    where series_id = '0ccc0ccc-0000-0000-0000-00000000c001'
      and (starts_at at time zone 'Europe/Prague')::date = current_setting('t.cd')::date
      and status = 'scheduled')::bigint, 0);

-- A closure BEYOND what has been generated is the case where reopening really
-- does bring classes back: there was never a row to cancel.
set role authenticated;
select set_config('request.jwt.claim.sub','0ccc0ccc-0000-0000-0000-0000000000a1',false);
select set_config('t.far', (current_setting('t.cd')::date + 200)::text, false);
select close_studio('0ccc0ccc-0000-0000-0000-000000000001',
  current_setting('t.far')::date, current_setting('t.far')::date, 'Far future', null, null, true);
reset role;
select set_config('request.jwt.claim.sub', null, false);
update studio_settings set occurrence_horizon_days = 400
 where studio_id = '0ccc0ccc-0000-0000-0000-000000000001';
select generate_occurrences('0ccc0ccc-0000-0000-0000-00000000c001');
select expect_num('a closure ahead of the horizon means the class is never made',
  (select count(*) from class_occurrences
    where series_id='0ccc0ccc-0000-0000-0000-00000000c001'
      and (starts_at at time zone 'Europe/Prague')::date = current_setting('t.far')::date)::bigint, 0);
set role authenticated;
select set_config('request.jwt.claim.sub','0ccc0ccc-0000-0000-0000-0000000000a1',false);
select set_config('t.re2', (select reopen_studio((select id from studio_closures
  where studio_id='0ccc0ccc-0000-0000-0000-000000000001'
    and starts_on = current_setting('t.far')::date))::text), false);
reset role;
select set_config('request.jwt.claim.sub', null, false);
select expect_num('...and reopening makes it, because there was nothing to resurrect',
  (select count(*) from class_occurrences
    where series_id='0ccc0ccc-0000-0000-0000-00000000c001'
      and (starts_at at time zone 'Europe/Prague')::date = current_setting('t.far')::date
      and status = 'scheduled')::bigint, 1);
