-- =============================================================================
-- Decision 18(c): staff edit a month's submission in place
-- (staff_edit_availability_submission). UUID space a18c, checked free.
-- Run after `supabase db reset`.
--
-- One Prague studio: an owner, a front desk login and an instructor with a
-- login. The instructor has a standing weekly pattern, an APPROVED submission
-- for next month (Tue and Thu 09:00 to 20:00) and a submission for the month
-- after. A class assigned to them on a Thursday next month is what the edit
-- leaves uncovered.
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
  ('a18ca18c-0000-0000-0000-0000000000a1','Edit Studio','a18c-sa','Europe/Prague','CZK','active');
insert into studio_settings (studio_id, require_waiver) values ('a18ca18c-0000-0000-0000-0000000000a1', false);
insert into locations (id, studio_id, name, is_primary) values
  ('a18ca18c-0000-0000-0000-0000000000aa','a18ca18c-0000-0000-0000-0000000000a1','Main',true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('a18ca18c-0000-0000-0000-00000000aa01','a18ca18c-0000-0000-0000-0000000000a1','a18ca18c-0000-0000-0000-0000000000aa','RA',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('a18ca18c-0000-0000-0000-0000000c7a01','a18ca18c-0000-0000-0000-0000000000a1','Reformer',50,10);
insert into auth.users (id) values
  ('a18ca18c-0000-0000-0000-0000000000f1'), ('a18ca18c-0000-0000-0000-0000000000f2'),
  ('a18ca18c-0000-0000-0000-0000000000f3');
insert into profiles (id, email) values
  ('a18ca18c-0000-0000-0000-0000000000f1','a18c-owner@example.com'),
  ('a18ca18c-0000-0000-0000-0000000000f2','a18c-desk@example.com'),
  ('a18ca18c-0000-0000-0000-0000000000f3','a18c-inst@example.com');
insert into studio_staff (id, studio_id, user_id, email, role, status) values
  ('a18ca18c-0000-0000-0000-00000005f001','a18ca18c-0000-0000-0000-0000000000a1','a18ca18c-0000-0000-0000-0000000000f1','a18c-owner@example.com','owner','active'),
  ('a18ca18c-0000-0000-0000-00000005f002','a18ca18c-0000-0000-0000-0000000000a1','a18ca18c-0000-0000-0000-0000000000f2','a18c-desk@example.com','front_desk','active'),
  ('a18ca18c-0000-0000-0000-00000005f003','a18ca18c-0000-0000-0000-0000000000a1','a18ca18c-0000-0000-0000-0000000000f3','a18c-inst@example.com','instructor','active');
insert into instructors (id, studio_id, staff_id, display_name) values
  ('a18ca18c-0000-0000-0000-00000000d101','a18ca18c-0000-0000-0000-0000000000a1','a18ca18c-0000-0000-0000-00000005f003','Ada Example');

-- Next month (P), the month after (P2), and a Thursday in P.
create temp table t as
select date_trunc('month', current_date + interval '1 month')::date as p,
       (date_trunc('month', current_date + interval '2 month'))::date as p2;
alter table t add column thu date;
update t set thu = p + ((4 - extract(dow from p)::int + 7) % 7) + 7;
grant select on t to authenticated;

-- The standing weekly pattern (submission null): Mon 07:00 to 21:00.
insert into instructor_availability (id, studio_id, instructor_id, day_of_week, starts_at_time, ends_at_time, approval_status)
values ('a18ca18c-0000-0000-0000-0000000aa001','a18ca18c-0000-0000-0000-0000000000a1','a18ca18c-0000-0000-0000-00000000d101',1,'07:00','21:00','approved');

-- P approved (Tue, Thu 09:00 to 20:00); P2 submitted (Fri 09:00 to 12:00).
insert into availability_submissions (id, studio_id, instructor_id, period_start, status, submitted_at)
select 'a18ca18c-0000-0000-0000-0000000005a1'::uuid,'a18ca18c-0000-0000-0000-0000000000a1'::uuid,'a18ca18c-0000-0000-0000-00000000d101'::uuid, p, 'approved', now() from t
union all
select 'a18ca18c-0000-0000-0000-0000000005a2'::uuid,'a18ca18c-0000-0000-0000-0000000000a1'::uuid,'a18ca18c-0000-0000-0000-00000000d101'::uuid, p2, 'submitted', now() from t;
insert into instructor_availability (studio_id, instructor_id, day_of_week, starts_at_time, ends_at_time, submission_id, approval_status)
values
  ('a18ca18c-0000-0000-0000-0000000000a1','a18ca18c-0000-0000-0000-00000000d101',2,'09:00','20:00','a18ca18c-0000-0000-0000-0000000005a1','approved'),
  ('a18ca18c-0000-0000-0000-0000000000a1','a18ca18c-0000-0000-0000-00000000d101',4,'09:00','20:00','a18ca18c-0000-0000-0000-0000000005a1','approved'),
  ('a18ca18c-0000-0000-0000-0000000000a1','a18ca18c-0000-0000-0000-00000000d101',5,'09:00','12:00','a18ca18c-0000-0000-0000-0000000005a2','submitted');

-- A class assigned to Ada on the Thursday in P, 10:00 Prague.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, starts_at, ends_at, status)
select 'a18ca18c-0000-0000-0000-00000000c001'::uuid,'a18ca18c-0000-0000-0000-0000000000a1'::uuid,'a18ca18c-0000-0000-0000-0000000000aa'::uuid,
       'a18ca18c-0000-0000-0000-0000000c7a01'::uuid,'a18ca18c-0000-0000-0000-00000000aa01'::uuid,'a18ca18c-0000-0000-0000-00000000d101'::uuid,
       'Thursday Reformer', 10, (thu + time '10:00') at time zone 'Europe/Prague', (thu + time '10:50') at time zone 'Europe/Prague', 'scheduled'
  from t;

-- ---- front desk is refused ------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub','a18ca18c-0000-0000-0000-0000000000f2',false);
select expect_raises('front desk cannot edit a submission',
  $q$select staff_edit_availability_submission('a18ca18c-0000-0000-0000-0000000005a1', '[]'::jsonb)$q$, 'PT403');

-- ---- the owner edits: Tue 10:00 to 20:00, Thu removed, Wed added, a date added
select set_config('request.jwt.claim.sub','a18ca18c-0000-0000-0000-0000000000f1',false);
select set_config('t.res', staff_edit_availability_submission('a18ca18c-0000-0000-0000-0000000005a1',
  jsonb_build_array(
    jsonb_build_object('day', 2, 'from', '10:00', 'to', '20:00'),
    jsonb_build_object('day', 3, 'from', '09:00', 'to', '12:00'),
    jsonb_build_object('date', (select p + 13 from t), 'from', '08:00', 'to', '15:00')))::text, false);
select expect_raises('a date outside the month is refused',
  $q$select staff_edit_availability_submission('a18ca18c-0000-0000-0000-0000000005a1',
     jsonb_build_array(jsonb_build_object('date', (select p2 + 2 from t), 'from', '08:00', 'to', '15:00')))$q$, 'PT422');
select expect_raises('a time that ends before it starts is refused',
  $q$select staff_edit_availability_submission('a18ca18c-0000-0000-0000-0000000005a1',
     jsonb_build_array(jsonb_build_object('day', 1, 'from', '12:00', 'to', '09:00')))$q$, 'PT422');
select set_config('request.jwt.claim.sub','',false);
reset role;

select expect_txt('the edit returned ok', current_setting('t.res')::jsonb ->> 'ok', 'true');
select expect_num('that submission now holds exactly the three new rows',
  (select count(*) from instructor_availability where submission_id = 'a18ca18c-0000-0000-0000-0000000005a1')::bigint, 3);
select expect_true('...Tuesday reads 10:00 to 20:00',
  exists (select 1 from instructor_availability where submission_id = 'a18ca18c-0000-0000-0000-0000000005a1'
            and day_of_week = 2 and starts_at_time = '10:00' and ends_at_time = '20:00'));
select expect_true('...the date row is stored with the submission (date set, weekday null)',
  exists (select 1 from instructor_availability where submission_id = 'a18ca18c-0000-0000-0000-0000000005a1'
            and exception_date is not null and day_of_week is null and starts_at_time = '08:00'));
select expect_num('the weekly pattern row is untouched',
  (select count(*) from instructor_availability where id = 'a18ca18c-0000-0000-0000-0000000aa001'
     and submission_id is null and day_of_week = 1 and starts_at_time = '07:00' and ends_at_time = '21:00')::bigint, 1);
select expect_num('the other month''s submission is untouched',
  (select count(*) from instructor_availability where submission_id = 'a18ca18c-0000-0000-0000-0000000005a2'
     and day_of_week = 5 and starts_at_time = '09:00' and ends_at_time = '12:00')::bigint, 1);
select expect_txt('the approved submission stays approved',
  (select status from availability_submissions where id = 'a18ca18c-0000-0000-0000-0000000005a1'), 'approved');
select expect_num('...and every one of its rows is approved',
  (select count(*) from instructor_availability where submission_id = 'a18ca18c-0000-0000-0000-0000000005a1'
     and approval_status = 'approved')::bigint, 3);
select expect_num('one audit row availability.submission_edited',
  (select count(*) from audit_logs where action = 'availability.submission_edited'
     and entity_id = 'a18ca18c-0000-0000-0000-0000000005a1')::bigint, 1);
select expect_num('...carrying the two before rows',
  (select jsonb_array_length(before -> 'rows') from audit_logs where action = 'availability.submission_edited'
     and entity_id = 'a18ca18c-0000-0000-0000-0000000005a1')::bigint, 2);
select expect_num('...and the three after rows',
  (select jsonb_array_length(after -> 'rows') from audit_logs where action = 'availability.submission_edited'
     and entity_id = 'a18ca18c-0000-0000-0000-0000000005a1')::bigint, 3);
select expect_num('exactly one availability_edited_by_studio email to the instructor',
  (select count(*) from notifications where template_key = 'availability_edited_by_studio'
     and user_id = 'a18ca18c-0000-0000-0000-0000000000f3')::bigint, 1);
select expect_txt('...whose change lines read as recorded',
  (select payload ->> 'change_lines' from notifications where template_key = 'availability_edited_by_studio'
     and user_id = 'a18ca18c-0000-0000-0000-0000000000f3'),
  'Tue 09:00 to 20:00 is now 10:00 to 20:00' || E'\n' || 'Wed 09:00 to 12:00 added' || E'\n'
  || 'Thu 09:00 to 20:00 removed' || E'\n'
  || (select to_char(p + 13, 'FMDy FMDD Mon') from t) || ' 08:00 to 15:00 added');
select expect_txt('...and the month in the subject line',
  (select payload ->> 'month' from notifications where template_key = 'availability_edited_by_studio'
     and user_id = 'a18ca18c-0000-0000-0000-0000000000f3'),
  (select to_char(p, 'FMMonth YYYY') from t));
select expect_num('the Thursday class is now outside the hours (count returned)',
  (current_setting('t.res')::jsonb ->> 'outside_count')::bigint, 1);
select expect_num('...and the assignment stays',
  (select count(*) from class_occurrences where id = 'a18ca18c-0000-0000-0000-00000000c001'
     and instructor_id = 'a18ca18c-0000-0000-0000-00000000d101')::bigint, 1);
select expect_txt('the email renders with nothing stripped',
  (select coalesce(array_to_string(r.stripped, ','), '') from notifications n
     cross join lateral render_notification(n.id) r
    where n.template_key = 'availability_edited_by_studio' and n.user_id = 'a18ca18c-0000-0000-0000-0000000000f3'), '');

-- A save with no change sends no second email (and still audits).
set role authenticated;
select set_config('request.jwt.claim.sub','a18ca18c-0000-0000-0000-0000000000f1',false);
select set_config('t.res2', staff_edit_availability_submission('a18ca18c-0000-0000-0000-0000000005a1',
  jsonb_build_array(
    jsonb_build_object('day', 2, 'from', '10:00', 'to', '20:00'),
    jsonb_build_object('day', 3, 'from', '09:00', 'to', '12:00'),
    jsonb_build_object('date', (select p + 13 from t), 'from', '08:00', 'to', '15:00')))::text, false);
select set_config('request.jwt.claim.sub','',false);
reset role;
select expect_num('an unchanged save sends no second email',
  (select count(*) from notifications where template_key = 'availability_edited_by_studio'
     and user_id = 'a18ca18c-0000-0000-0000-0000000000f3')::bigint, 1);

select expect_num('anon surface is EXACTLY FOURTEEN',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not like 'expect_%')::bigint, 14);
select expect_true('the inbox table is closed to anon reads with RLS on',
  not has_table_privilege('anon','public.resend_webhook_inbox','select')
  and (select relrowsecurity from pg_class where oid = 'public.resend_webhook_inbox'::regclass));

select 'submission_edit_test: all assertions passed' as done;
