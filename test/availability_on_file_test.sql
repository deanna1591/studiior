-- =============================================================================
-- Decision 46 amendment — availability "on file" (submission OR standing pattern)
-- is shown and is not nagged for. UUID space: 46f0
--
-- instructor_month_covered five cases (+ a pattern ending before the month =
-- 'none'); the page reader returns the pattern's ranges + source='pattern'; the
-- reminder sweep queues nothing for a covered or published month but still for an
-- uncovered unpublished one (RED-proven); Home state is derived from the same.
-- =============================================================================
\set S '''46f046f0-0000-0000-0000-000000000001'''

create or replace function expect_true(label text, actual boolean) returns void language plpgsql as $$
begin if coalesce(actual,false) then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_num(label text, actual bigint, want bigint) returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (%)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_text(label text, actual text, want text) returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (%)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if; end $$;

-- Period under test: next month (what availability_cycle collects).
select set_config('t.period', (date_trunc('month', current_date + interval '1 month'))::date::text, false);
select set_config('t.pend',   (date_trunc('month', current_date + interval '1 month') + interval '1 month' - interval '1 day')::date::text, false);

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('46f046f0-0000-0000-0000-0000000000a1'),  -- owner
  ('46f046f0-0000-0000-0000-0000000000c1'),  -- I_sub login
  ('46f046f0-0000-0000-0000-0000000000c2'),  -- I_app login
  ('46f046f0-0000-0000-0000-0000000000c4'),  -- I_pat login
  ('46f046f0-0000-0000-0000-0000000000c5');  -- I_none login
insert into profiles (id, email) values
  ('46f046f0-0000-0000-0000-0000000000a1','46f0-o@example.com'),
  ('46f046f0-0000-0000-0000-0000000000c1','46f0-sub@example.com'),
  ('46f046f0-0000-0000-0000-0000000000c2','46f0-app@example.com'),
  ('46f046f0-0000-0000-0000-0000000000c4','46f0-pat@example.com'),
  ('46f046f0-0000-0000-0000-0000000000c5','46f0-none@example.com');

insert into studios (id, name, slug, timezone, currency, status) values
  (:S,'OnFile','onfile','Europe/Prague','CZK','active');
-- Reminders on, due_day 1 so the sweep always fires (today >= 1st of this month).
insert into studio_settings (studio_id, availability_reminders_enabled, availability_due_day) values
  (:S, true, 1);
insert into locations (id, studio_id, name, is_primary) values
  ('46f046f0-0000-0000-0000-00000000000a',:S,'Main',true);

insert into studio_staff (id, studio_id, user_id, email, role, status) values
  ('46f046f0-0000-0000-0000-000000aa00a1',:S,'46f046f0-0000-0000-0000-0000000000a1','46f0-o@example.com','owner','active'),
  ('46f046f0-0000-0000-0000-000000aa00c1',:S,'46f046f0-0000-0000-0000-0000000000c1','46f0-sub@example.com','instructor','active'),
  ('46f046f0-0000-0000-0000-000000aa00c2',:S,'46f046f0-0000-0000-0000-0000000000c2','46f0-app@example.com','instructor','active'),
  ('46f046f0-0000-0000-0000-000000aa00c4',:S,'46f046f0-0000-0000-0000-0000000000c4','46f0-pat@example.com','instructor','active'),
  ('46f046f0-0000-0000-0000-000000aa00c5',:S,'46f046f0-0000-0000-0000-0000000000c5','46f0-none@example.com','instructor','active');

insert into instructors (id, studio_id, display_name, staff_id) values
  ('46f046f0-0000-0000-0000-00000000d001',:S,'Sue Submitted', '46f046f0-0000-0000-0000-000000aa00c1'),
  ('46f046f0-0000-0000-0000-00000000d002',:S,'Ava Approved',  '46f046f0-0000-0000-0000-000000aa00c2'),
  ('46f046f0-0000-0000-0000-00000000d003',:S,'Chase Changes', null),  -- changes_requested, no login (unit only)
  ('46f046f0-0000-0000-0000-00000000d004',:S,'Pat Pattern',   '46f046f0-0000-0000-0000-000000aa00c4'),
  ('46f046f0-0000-0000-0000-00000000d005',:S,'Nina None',     '46f046f0-0000-0000-0000-000000aa00c5'),
  ('46f046f0-0000-0000-0000-00000000d006',:S,'Ex Pired',      null);  -- pattern ended before month (unit only)

-- Submissions for the collected (next) month.
insert into availability_submissions (id, studio_id, instructor_id, period_start, status, submitted_at) values
  ('46f046f0-0000-0000-0000-0000000b0001',:S,'46f046f0-0000-0000-0000-00000000d001', current_setting('t.period')::date, 'submitted', now()),
  ('46f046f0-0000-0000-0000-0000000b0002',:S,'46f046f0-0000-0000-0000-00000000d002', current_setting('t.period')::date, 'approved',  now()),
  ('46f046f0-0000-0000-0000-0000000b0003',:S,'46f046f0-0000-0000-0000-00000000d003', current_setting('t.period')::date, 'changes_requested', now());

-- I_pat: a STANDING pattern (submission_id null, approved) covering the month,
-- with a dated end AFTER the month (so pattern_ends_on is that date).
insert into instructor_availability (studio_id, instructor_id, day_of_week, starts_at_time, ends_at_time, effective_from, effective_to, approval_status, is_available) values
  (:S,'46f046f0-0000-0000-0000-00000000d004',1,'09:00','17:00', current_date, (current_setting('t.pend')::date + 30), 'approved', true),
  (:S,'46f046f0-0000-0000-0000-00000000d004',3,'10:00','14:00', current_date, (current_setting('t.pend')::date + 30), 'approved', true);
-- I_expired: a pattern that ENDED before the collected month → not covering.
insert into instructor_availability (studio_id, instructor_id, day_of_week, starts_at_time, ends_at_time, effective_from, effective_to, approval_status, is_available) values
  (:S,'46f046f0-0000-0000-0000-00000000d006',1,'09:00','17:00', current_date - 60, current_date, 'approved', true);

reset role;

-- =============================================================================
-- (1) instructor_month_covered — the five cases + a pattern ending before.
-- =============================================================================
select expect_text('submitted submission → submitted',
  instructor_month_covered('46f046f0-0000-0000-0000-00000000d001', current_setting('t.period')::date), 'submitted');
select expect_text('approved submission → approved',
  instructor_month_covered('46f046f0-0000-0000-0000-00000000d002', current_setting('t.period')::date), 'approved');
select expect_text('changes_requested submission → changes_requested',
  instructor_month_covered('46f046f0-0000-0000-0000-00000000d003', current_setting('t.period')::date), 'changes_requested');
select expect_text('no submission, a covering pattern → pattern',
  instructor_month_covered('46f046f0-0000-0000-0000-00000000d004', current_setting('t.period')::date), 'pattern');
select expect_text('nothing on file → none',
  instructor_month_covered('46f046f0-0000-0000-0000-00000000d005', current_setting('t.period')::date), 'none');
select expect_text('a pattern ending BEFORE the month → none',
  instructor_month_covered('46f046f0-0000-0000-0000-00000000d006', current_setting('t.period')::date), 'none');

-- =============================================================================
-- (2) availability_submission_week — pattern ranges + source. (manager-or-
--     instructor guarded, no service bypass — read as the owner.)
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','46f046f0-0000-0000-0000-0000000000a1',false);
select expect_text('page reader: I_pat source = pattern',
  (availability_submission_week('46f046f0-0000-0000-0000-00000000d004', current_setting('t.period')::date) ->> 'source'), 'pattern');
select expect_num('...and returns the pattern days (Mon + Wed)',
  jsonb_array_length(availability_submission_week('46f046f0-0000-0000-0000-00000000d004', current_setting('t.period')::date) -> 'days'), 2);
select expect_text('...with pattern_ends_on = the dated end (not open)',
  (availability_submission_week('46f046f0-0000-0000-0000-00000000d004', current_setting('t.period')::date) ->> 'pattern_ends_on'),
  (current_setting('t.pend')::date + 30)::text);
select expect_text('...the Monday range is 09:00–17:00',
  ((availability_submission_week('46f046f0-0000-0000-0000-00000000d004', current_setting('t.period')::date) -> 'days' -> 0 -> 'ranges' -> 0 ->> 'from')
   || '-' ||
   (availability_submission_week('46f046f0-0000-0000-0000-00000000d004', current_setting('t.period')::date) -> 'days' -> 0 -> 'ranges' -> 0 ->> 'to')),
  '09:00-17:00');
select expect_text('page reader: I_none source = none, no days',
  (availability_submission_week('46f046f0-0000-0000-0000-00000000d005', current_setting('t.period')::date) ->> 'source')
   || ':' || jsonb_array_length(availability_submission_week('46f046f0-0000-0000-0000-00000000d005', current_setting('t.period')::date) -> 'days')::text,
  'none:0');
select expect_text('page reader: I_sub source = submission',
  (availability_submission_week('46f046f0-0000-0000-0000-00000000d001', current_setting('t.period')::date) ->> 'source'), 'submission');
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- (3) The reminder sweep — queue nothing for a covered month, still for an
--     uncovered one.
-- =============================================================================
select queue_availability_reminders(:S);
select expect_num('sweep: the uncovered instructor (None) is reminded',
  (select count(*) from notifications where template_key='availability_due'
     and user_id='46f046f0-0000-0000-0000-0000000000c5')::bigint, 1);
select expect_num('sweep: the pattern-covered instructor is NOT reminded',
  (select count(*) from notifications where template_key='availability_due'
     and user_id='46f046f0-0000-0000-0000-0000000000c4')::bigint, 0);
select expect_num('sweep: the submitted instructor is NOT reminded',
  (select count(*) from notifications where template_key='availability_due'
     and user_id='46f046f0-0000-0000-0000-0000000000c1')::bigint, 0);
select expect_num('sweep: the approved instructor is NOT reminded',
  (select count(*) from notifications where template_key='availability_due'
     and user_id='46f046f0-0000-0000-0000-0000000000c2')::bigint, 0);

-- RED: without the covered-skip (break instructor_month_covered → always 'none'),
-- the pattern-covered instructor WOULD be reminded.
delete from notifications where template_key='availability_due' and user_id='46f046f0-0000-0000-0000-0000000000c4';
create or replace function instructor_month_covered(p_instructor_id uuid, p_period_start date)
returns text language sql stable security definer set search_path = public as $$ select 'none'::text $$;
select queue_availability_reminders(:S);
select expect_num('RED: with the skip broken, the pattern-covered instructor IS reminded',
  (select count(*) from notifications where template_key='availability_due'
     and user_id='46f046f0-0000-0000-0000-0000000000c4')::bigint, 1);
-- Restore the real definition.
create or replace function instructor_month_covered(p_instructor_id uuid, p_period_start date)
returns text language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_status text; v_end date;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(v_studio), false)
     and p_instructor_id is distinct from auth_instructor_id(v_studio)
     and not is_service_context() then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;
  select status into v_status from availability_submissions
   where instructor_id = p_instructor_id and period_start = p_period_start;
  if v_status in ('submitted','approved','changes_requested') then return v_status; end if;
  v_end := (p_period_start + interval '1 month' - interval '1 day')::date;
  if exists (select 1 from instructor_availability a
              where a.instructor_id = p_instructor_id and a.submission_id is null
                and a.day_of_week is not null and a.approval_status = 'approved' and a.is_available = true
                and (a.effective_from is null or a.effective_from <= v_end)
                and (a.effective_to is null or a.effective_to >= p_period_start)) then return 'pattern'; end if;
  return 'none';
end $$;

-- A PUBLISHED month is never asked for: publish next month → the sweep queues 0.
delete from notifications where template_key='availability_due';
insert into schedule_publications (studio_id, month, published_by) values
  (:S, current_setting('t.period')::date, '46f046f0-0000-0000-0000-0000000000a1');
select expect_num('sweep: a published month queues nothing (returns 0)',
  queue_availability_reminders(:S)::bigint, 0);
select expect_num('...and the uncovered instructor got no reminder for the published month',
  (select count(*) from notifications where template_key='availability_due'
     and user_id='46f046f0-0000-0000-0000-0000000000c5')::bigint, 0);

-- --- cleanup -----------------------------------------------------------------
drop function expect_true(text, boolean);
drop function expect_num(text, bigint, bigint);
drop function expect_text(text, text, text);
select 'availability_on_file_test: all assertions passed' as result;
