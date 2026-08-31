-- =============================================================================
-- STUDIIOR — THE BRIEF SCHEDULER (migration 024)
--
--   a studio past its send time is picked up, one that is not is left alone,
--   a second run the same day does nothing, and the door pg_cron comes through
--   is a role check rather than a missing-JWT check.
--
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -f test/brief_schedule_test.sql
-- =============================================================================

\set ON_ERROR_STOP on
set client_min_messages = notice;

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

-- --- Fixtures: dddd ---------------------------------------------------------
--
-- Both studios share one timezone, chosen at run time as somewhere it is
-- currently late morning. "Send time minus an hour" and "send time in three
-- hours" then sit either side of now without either wrapping past midnight —
-- pick a zone where it is 23:40 and "in three hours" is tomorrow, which reads
-- as already past and the test asserts the opposite of what it means.

select set_config('s.tz',
  (select name from pg_timezone_names
    where (now() at time zone name)::time between '10:00' and '13:00'
    order by name limit 1), false);
select 'chosen zone: ' || current_setting('s.tz') ||
       ', local time there: ' || to_char(now() at time zone current_setting('s.tz'), 'HH24:MI') as fixture;

insert into auth.users (id) values ('dddddddd-0000-0000-0000-0000000000a1');
insert into profiles (id, email) values ('dddddddd-0000-0000-0000-0000000000a1','sched-owner@example.com');

insert into studios (id, name, slug, timezone, currency, status)
select 'dddddddd-0000-0000-0000-000000000001','Due Studio','sched-due',
       current_setting('s.tz'),'CZK','active';
insert into studios (id, name, slug, timezone, currency, status)
select 'dddddddd-0000-0000-0000-000000000002','Not Yet Studio','sched-notyet',
       current_setting('s.tz'),'CZK','active';

-- One send time already passed, one still to come.
insert into studio_settings (studio_id, morning_brief_send_at)
select 'dddddddd-0000-0000-0000-000000000001',
       ((now() at time zone current_setting('s.tz'))::time - interval '1 hour')::time;
insert into studio_settings (studio_id, morning_brief_send_at)
select 'dddddddd-0000-0000-0000-000000000002',
       ((now() at time zone current_setting('s.tz'))::time + interval '3 hours')::time;

insert into studio_staff (studio_id, user_id, email, role) values
  ('dddddddd-0000-0000-0000-000000000001','dddddddd-0000-0000-0000-0000000000a1','sched-owner@example.com','owner'),
  ('dddddddd-0000-0000-0000-000000000002','dddddddd-0000-0000-0000-0000000000a1','sched-owner@example.com','owner');

-- Something for the brief to have an opinion about.
insert into members (id, studio_id, first_name, last_name, email, joined_on, status,
                     lifetime_visits, last_visit_at, health_band, health_reason, health_signals)
select ('dddddddd-0000-0000-0000-0000000dd0' || to_char(i,'FM00'))::uuid,
       'dddddddd-0000-0000-0000-000000000001',
       'Sched' || i, 'Member', 'sched' || i || '@example.com',
       current_date - 300, 'active', 25, now() - interval '18 days',
       'at_risk', 'Was coming about every 4 days, last visit 18 days ago.',
       '["rhythm_deviation"]'
  from generate_series(1,3) i;

-- =============================================================================
-- 1. Who is due
-- =============================================================================

select expect_num('the studio past its send time is due',
  (select count(*) from studios_due_for_brief()
    where studio_id = 'dddddddd-0000-0000-0000-000000000001'), 1);
select expect_num('the studio whose time has not come is not',
  (select count(*) from studios_due_for_brief()
    where studio_id = 'dddddddd-0000-0000-0000-000000000002'), 0);
select expect_text('and due means the studio''s own local date, not the server''s',
  (select local_date::text from studios_due_for_brief()
    where studio_id = 'dddddddd-0000-0000-0000-000000000001'),
  (now() at time zone current_setting('s.tz'))::date::text);

-- =============================================================================
-- 2. The run
-- =============================================================================

select set_config('s.run1', run_due_morning_briefs()::text, false);

select expect_num('the due studio got a brief',
  (select count(*) from morning_briefs
    where studio_id = 'dddddddd-0000-0000-0000-000000000001'), 1);
select expect_num('the other studio got nothing',
  (select count(*) from morning_briefs
    where studio_id = 'dddddddd-0000-0000-0000-000000000002'), 0);
select expect_num('and the brief has the insights it should',
  (select count(*) from ai_insights
    where studio_id = 'dddddddd-0000-0000-0000-000000000001'), 3);
select expect_num('nothing failed',
  (current_setting('s.run1')::jsonb ->> 'failed')::bigint, 0);

select expect_num('one job_runs row for the studio and its local date',
  (select count(*) from job_runs
    where job_key = 'morning_brief:dddddddd-0000-0000-0000-000000000001'), 1);
select expect_text('marked done',
  (select status from job_runs
    where job_key = 'morning_brief:dddddddd-0000-0000-0000-000000000001'), 'done');
select expect_num('and none for the studio that was not due',
  (select count(*) from job_runs
    where job_key = 'morning_brief:dddddddd-0000-0000-0000-000000000002'), 0);

-- =============================================================================
-- 3. A second run the same day changes nothing
--
-- Twice over: the brief already exists so studios_due_for_brief() stops
-- offering the studio, and even if it did, job_runs has claimed the day.
-- =============================================================================

select set_config('s.gen1',
  (select generated_at::text from morning_briefs
    where studio_id = 'dddddddd-0000-0000-0000-000000000001'), false);

select set_config('s.run2', run_due_morning_briefs()::text, false);
select expect_num('the second run generates nothing',
  (current_setting('s.run2')::jsonb ->> 'generated')::bigint, 0);
select expect_num('still one brief',
  (select count(*) from morning_briefs
    where studio_id = 'dddddddd-0000-0000-0000-000000000001'), 1);
select expect_text('and it was not rewritten',
  (select generated_at::text from morning_briefs
    where studio_id = 'dddddddd-0000-0000-0000-000000000001'),
  current_setting('s.gen1'));
select expect_num('still one job_runs row',
  (select count(*) from job_runs
    where job_key = 'morning_brief:dddddddd-0000-0000-0000-000000000001'), 1);

-- The job_runs guard on its own: delete the brief so the studio looks due
-- again, and confirm the claim is what stops a second generation. This is the
-- case the unique constraint exists for — a retry after something went wrong
-- half way, not a tidy re-run.
delete from morning_briefs where studio_id = 'dddddddd-0000-0000-0000-000000000001';
delete from ai_insights   where studio_id = 'dddddddd-0000-0000-0000-000000000001';

select expect_num('with the brief gone the studio looks due again',
  (select count(*) from studios_due_for_brief()
    where studio_id = 'dddddddd-0000-0000-0000-000000000001'), 1);
select set_config('s.run3', run_due_morning_briefs()::text, false);
select expect_num('but job_runs has claimed the day, so it is skipped',
  (current_setting('s.run3')::jsonb ->> 'skipped')::bigint, 1);
select expect_num('and nothing was regenerated',
  (select count(*) from morning_briefs
    where studio_id = 'dddddddd-0000-0000-0000-000000000001'), 0);

-- A run that crashed leaves 'running', and must be retryable rather than
-- stuck for ever.
update job_runs set status = 'running', finished_at = null
 where job_key = 'morning_brief:dddddddd-0000-0000-0000-000000000001';
select set_config('s.run4', run_due_morning_briefs()::text, false);
select expect_num('a run left half finished is retried, not abandoned',
  (current_setting('s.run4')::jsonb ->> 'generated')::bigint, 1);
select expect_num('the retry incremented attempts rather than adding a row',
  (select attempts from job_runs
    where job_key = 'morning_brief:dddddddd-0000-0000-0000-000000000001'), 2);
select expect_num('and there is still exactly one row for the day',
  (select count(*) from job_runs
    where job_key = 'morning_brief:dddddddd-0000-0000-0000-000000000001'), 1);

-- =============================================================================
-- 4. The door pg_cron comes through
--
-- The whole point of migration 024's guard: trusted because of WHICH ROLE the
-- caller is, never because a JWT was missing. An authenticated session with no
-- JWT has a null auth.uid() and must still be refused.
-- =============================================================================

select expect_text('postgres, which is how pg_cron runs, is a service context',
  is_service_context()::text, 'true');

set role service_role;
select expect_text('so is service_role', is_service_context()::text, 'true');
reset role;

set role authenticated;
select set_config('request.jwt.claim.sub','', false);
select expect_text('an authenticated session with NO jwt has no uid',
  coalesce(auth.uid()::text, 'NULL'), 'NULL');
select expect_text('and is still not a service context — this is the hole 020 closed',
  is_service_context()::text, 'false');
do $$
begin
  perform run_due_morning_briefs();
  raise exception 'FAIL  an authenticated caller ran the scheduler';
exception when sqlstate 'PT403' then
  raise notice 'PASS  an authenticated caller cannot run the scheduler';
end $$;
reset role;

-- An owner is still refused the *scheduler*, while keeping their own ability
-- to generate their studio's brief by hand.
set role authenticated;
select set_config('request.jwt.claim.sub','dddddddd-0000-0000-0000-0000000000a1', false);
select expect_text('an owner is not a service context either',
  is_service_context()::text, 'false');
do $$
begin
  perform run_due_morning_briefs();
  raise exception 'FAIL  an owner ran the scheduler';
exception when sqlstate 'PT403' then
  raise notice 'PASS  an owner cannot run the scheduler';
end $$;
select expect_num('but can still generate their own studio''s brief',
  ((generate_morning_brief('dddddddd-0000-0000-0000-000000000001')) ->> 'insights')::bigint, 3);
reset role;

-- =============================================================================
-- 5. The job is actually scheduled
-- =============================================================================

select expect_num('pg_cron has exactly one Studiior brief job',
  (select count(*) from cron.job where jobname = 'studiior-morning-brief'), 1);
select expect_text('every fifteen minutes',
  (select schedule from cron.job where jobname = 'studiior-morning-brief'), '*/15 * * * *');
select expect_text('calling the scheduler, not the generator',
  (select command from cron.job where jobname = 'studiior-morning-brief'),
  'select run_due_morning_briefs()');
select expect_text('and it is switched on',
  (select active::text from cron.job where jobname = 'studiior-morning-brief'), 'true');

select 'ALL BRIEF SCHEDULE TESTS PASSED' as result;
