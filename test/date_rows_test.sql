-- =============================================================================
-- Decision 18(d): dates with their own hours. UUID space a18d, checked free.
-- Run after `supabase db reset`.
--
-- Ada (login) has a standing Wednesday pattern and an APPROVED submission for
-- next month (P): Mondays 09:00 to 12:00 by weekday, plus date rows: a Tuesday
-- with 08:00 to 15:00 (a day the weekday rows do not have), a Monday with
-- 14:00 to 18:00 (different hours) and a Monday marked off. Bo (no login) has a
-- standing Monday pattern and a NOT YET APPROVED submission whose date row marks
-- a Monday off; it must not count.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'BAD  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual then raise notice 'PASS  %', label;
  else raise exception 'BAD  %  expected true, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_txt(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (%)', label, coalesce(actual,'null');
  else raise exception 'BAD  %  expected "%", got "%"', label, want, coalesce(actual,'null'); end if;
end $$;
create or replace function expect_raises(label text, stmt text, want_sqlstate text)
returns void language plpgsql as $$
begin
  execute stmt; raise exception 'BAD  %  expected % but nothing was raised', label, want_sqlstate;
exception when others then
  if sqlstate = want_sqlstate then raise notice 'PASS  %  (got %)', label, sqlstate;
  elsif sqlstate = 'P0001' and sqlerrm like 'BAD%' then raise;
  else raise exception 'BAD  %  expected %, got % (%)', label, want_sqlstate, sqlstate, sqlerrm; end if;
end $$;

insert into studios (id, name, slug, timezone, currency, status) values
  ('a18da18d-0000-0000-0000-0000000000a1','Dates Studio','a18d-sa','Europe/Prague','CZK','active');
insert into studio_settings (studio_id, require_waiver) values ('a18da18d-0000-0000-0000-0000000000a1', false);
insert into auth.users (id) values ('a18da18d-0000-0000-0000-0000000000f3');
insert into profiles (id, email) values ('a18da18d-0000-0000-0000-0000000000f3','a18d-inst@example.com');
insert into studio_staff (id, studio_id, user_id, email, role, status) values
  ('a18da18d-0000-0000-0000-00000005f003','a18da18d-0000-0000-0000-0000000000a1','a18da18d-0000-0000-0000-0000000000f3','a18d-inst@example.com','instructor','active');
insert into instructors (id, studio_id, staff_id, display_name) values
  ('a18da18d-0000-0000-0000-00000000d101','a18da18d-0000-0000-0000-0000000000a1','a18da18d-0000-0000-0000-00000005f003','Ada Example'),
  ('a18da18d-0000-0000-0000-00000000d102','a18da18d-0000-0000-0000-0000000000a1',null,'Bo Fictitious');

create temp table t as select date_trunc('month', current_date + interval '1 month')::date as p,
  date_trunc('month', current_date + interval '2 month')::date as p2,
  date_trunc('month', current_date)::date as cur;
alter table t add column m1 date, add column wed date;
update t set m1 = p + ((1 - extract(dow from p)::int + 7) % 7),
             wed = cur + ((3 - extract(dow from cur)::int + 7) % 7);
grant select on t to authenticated;

-- f(instructor, date, from, to): the availability function at that local time.
create or replace function pg_temp.av(i uuid, d date, f time, tt time) returns boolean
language sql as $$ select instructor_available_at_run(i, (d + f) at time zone 'Europe/Prague', (d + tt) at time zone 'Europe/Prague') $$;

-- Standing patterns (submission null).
insert into instructor_availability (studio_id, instructor_id, day_of_week, starts_at_time, ends_at_time, approval_status) values
  ('a18da18d-0000-0000-0000-0000000000a1','a18da18d-0000-0000-0000-00000000d101',3,'09:00','17:00','approved'),
  ('a18da18d-0000-0000-0000-0000000000a1','a18da18d-0000-0000-0000-00000000d102',1,'09:00','17:00','approved');

-- Ada: approved P. Bo: submitted (not approved) P.
insert into availability_submissions (id, studio_id, instructor_id, period_start, status, submitted_at)
select 'a18da18d-0000-0000-0000-0000000005a1'::uuid,'a18da18d-0000-0000-0000-0000000000a1'::uuid,'a18da18d-0000-0000-0000-00000000d101'::uuid, p, 'approved', now() from t
union all
select 'a18da18d-0000-0000-0000-0000000005b1'::uuid,'a18da18d-0000-0000-0000-0000000000a1'::uuid,'a18da18d-0000-0000-0000-00000000d102'::uuid, p, 'submitted', now() from t;
insert into instructor_availability (studio_id, instructor_id, day_of_week, exception_date, starts_at_time, ends_at_time, is_available, submission_id, approval_status)
select 'a18da18d-0000-0000-0000-0000000000a1'::uuid,'a18da18d-0000-0000-0000-00000000d101'::uuid, 1, null::date, '09:00'::time,'12:00'::time, true,'a18da18d-0000-0000-0000-0000000005a1'::uuid,'approved' from t
union all select 'a18da18d-0000-0000-0000-0000000000a1','a18da18d-0000-0000-0000-00000000d101', null, m1 + 8, '08:00','15:00', true,'a18da18d-0000-0000-0000-0000000005a1','approved' from t
union all select 'a18da18d-0000-0000-0000-0000000000a1','a18da18d-0000-0000-0000-00000000d101', null, m1 + 7, '14:00','18:00', true,'a18da18d-0000-0000-0000-0000000005a1','approved' from t
union all select 'a18da18d-0000-0000-0000-0000000000a1','a18da18d-0000-0000-0000-00000000d101', null, m1 + 14, null, null, false,'a18da18d-0000-0000-0000-0000000005a1','approved' from t
union all select 'a18da18d-0000-0000-0000-0000000000a1','a18da18d-0000-0000-0000-00000000d102', null, m1 + 7, null, null, false,'a18da18d-0000-0000-0000-0000000005b1','submitted' from t;

-- ---- the function prefers the date row -------------------------------------
select expect_true('a date row adds a day the weekday rows do not have (Tue 09:00)',
  (select pg_temp.av('a18da18d-0000-0000-0000-00000000d101', m1 + 8, '09:00', '10:00') from t));
select expect_true('...a Tuesday without a date row is still not available',
  (select not pg_temp.av('a18da18d-0000-0000-0000-00000000d101', m1 + 1, '09:00', '10:00') from t));
select expect_true('a date row gives a Monday different hours (15:00 inside 14:00 to 18:00)',
  (select pg_temp.av('a18da18d-0000-0000-0000-00000000d101', m1 + 7, '15:00', '16:00') from t));
select expect_true('...and the weekday hours no longer apply on that date (10:00)',
  (select not pg_temp.av('a18da18d-0000-0000-0000-00000000d101', m1 + 7, '10:00', '11:00') from t));
select expect_true('a date row marks a Monday off',
  (select not pg_temp.av('a18da18d-0000-0000-0000-00000000d101', m1 + 14, '10:00', '11:00') from t));
select expect_true('an ordinary Monday follows the weekday rows (10:00)',
  (select pg_temp.av('a18da18d-0000-0000-0000-00000000d101', m1, '10:00', '11:00') from t));
select expect_true('the standing pattern still answers a date in the current month (Wed 10:00)',
  (select pg_temp.av('a18da18d-0000-0000-0000-00000000d101', wed, '10:00', '11:00') from t));
select expect_true('a not-yet-approved submission''s date row does not count (Bo, Monday off, pattern says yes)',
  (select pg_temp.av('a18da18d-0000-0000-0000-00000000d102', m1 + 7, '10:00', '11:00') from t));

-- ---- block-off behaviour unchanged; a standalone row wins over everything ---
set role authenticated;
select set_config('request.jwt.claim.sub','a18da18d-0000-0000-0000-0000000000f3',false);
select set_config('t.blk', (select instructor_block_dates(m1 + 8, m1 + 8, 'Dentist') from t)::text, false);
select set_config('request.jwt.claim.sub','',false);
reset role;
select expect_num('blocking a date writes one standalone unavailable row',
  (select count(*) from instructor_availability, t where instructor_id = 'a18da18d-0000-0000-0000-00000000d101'
     and exception_date = m1 + 8 and submission_id is null and not is_available)::bigint, 1);
select expect_true('...which wins over the submission''s date row (Tue 09:00 now not available)',
  (select not pg_temp.av('a18da18d-0000-0000-0000-00000000d101', m1 + 8, '09:00', '10:00') from t));
select expect_num('...and the submission''s date row is still there',
  (select count(*) from instructor_availability, t where submission_id = 'a18da18d-0000-0000-0000-0000000005a1'
     and exception_date = m1 + 8)::bigint, 1);
set role authenticated;
select set_config('request.jwt.claim.sub','a18da18d-0000-0000-0000-0000000000f3',false);
select expect_num('time off lists the block once and never a submission''s date row',
  (select count(*) from instructor_time_off())::bigint, 1);
select instructor_unblock_dates(m1 + 8, m1 + 8) from t;
select set_config('request.jwt.claim.sub','',false);
reset role;
select expect_true('unblocking removes only the standalone row: the date row answers again',
  (select pg_temp.av('a18da18d-0000-0000-0000-00000000d101', m1 + 8, '09:00', '10:00') from t));

-- A standalone date with different hours (the Time off sheet) wins too, and
-- clearing it leaves the submission's date row.
set role authenticated;
select set_config('request.jwt.claim.sub','a18da18d-0000-0000-0000-0000000000f3',false);
select set_availability_exception('a18da18d-0000-0000-0000-00000000d101', m1 + 7, '[{"from":"10:00","to":"11:00"}]'::jsonb, 'Swap') from t;
select set_config('request.jwt.claim.sub','',false);
reset role;
select expect_true('a standalone Different hours row wins (10:00 now available)',
  (select pg_temp.av('a18da18d-0000-0000-0000-00000000d101', m1 + 7, '10:00', '11:00') from t));
select expect_true('...and the submission''s 15:00 no longer applies',
  (select not pg_temp.av('a18da18d-0000-0000-0000-00000000d101', m1 + 7, '15:00', '16:00') from t));
set role authenticated;
select set_config('request.jwt.claim.sub','a18da18d-0000-0000-0000-0000000000f3',false);
select clear_availability_exception('a18da18d-0000-0000-0000-00000000d101', m1 + 7) from t;
select set_config('request.jwt.claim.sub','',false);
reset role;
select expect_true('clearing it leaves the submission''s date row (15:00 available again)',
  (select pg_temp.av('a18da18d-0000-0000-0000-00000000d101', m1 + 7, '15:00', '16:00') from t));

-- ---- the instructor's submit path accepts date rows -------------------------
set role authenticated;
select set_config('request.jwt.claim.sub','a18da18d-0000-0000-0000-0000000000f3',false);
select submit_availability('a18da18d-0000-0000-0000-00000000d101', p2,
  jsonb_build_array(
    jsonb_build_object('day', 2, 'ranges', jsonb_build_array(jsonb_build_object('from','09:00','to','12:00'))),
    jsonb_build_object('date', p2 + 3, 'ranges', jsonb_build_array(jsonb_build_object('from','08:00','to','15:00'))),
    jsonb_build_object('date', p2 + 4, 'unavailable', true)), false) from t;
select expect_raises('a date outside the month is refused at submit',
  $q$select submit_availability('a18da18d-0000-0000-0000-00000000d101', (select p2 from t),
     jsonb_build_array(jsonb_build_object('date', (select p + 2 from t), 'unavailable', true)), false)$q$, 'PT422');
select expect_num('the reader returns the month''s two dates',
  (select jsonb_array_length(availability_submission_week('a18da18d-0000-0000-0000-00000000d101', p2) -> 'dates') from t)::bigint, 2);
select set_config('request.jwt.claim.sub','',false);
reset role;
select expect_num('submit stored one weekday row and two date rows',
  (select count(*) from instructor_availability a join availability_submissions s on s.id = a.submission_id, t
    where s.instructor_id = 'a18da18d-0000-0000-0000-00000000d101' and s.period_start = t.p2)::bigint, 3);
select expect_num('...one of them a date marked off',
  (select count(*) from instructor_availability a join availability_submissions s on s.id = a.submission_id, t
    where s.instructor_id = 'a18da18d-0000-0000-0000-00000000d101' and s.period_start = t.p2
      and a.exception_date = t.p2 + 4 and not a.is_available)::bigint, 1);

select expect_num('anon surface is EXACTLY FIFTEEN',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not like 'expect_%')::bigint, 15);
select expect_true('the inbox table is closed to anon reads with RLS on',
  not has_table_privilege('anon','public.resend_webhook_inbox','select')
  and (select relrowsecurity from pg_class where oid = 'public.resend_webhook_inbox'::regclass));

select 'date_rows_test: all assertions passed' as done;
