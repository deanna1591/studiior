-- =============================================================================
-- Decision 96 — Reopen availability before the cut-off. UUID space: 9601
--
-- reopen on an APPROVED month before the due day succeeds (submission and its
-- instructor_availability rows flip to changes_requested = editable again, the
-- availability_changes_requested email is queued); the note defaults to
-- "Reopened by {studio} so you can make changes." when none is given and is the
-- given note otherwise; AFTER the due day it refuses cutoff_passed (PT409) and
-- leaves the submission approved; front desk is PT403. The cut-off is read from
-- availability_cycle(...)->>'due_on', the one source.
--
-- Future period (2 months ahead, due ~20th of next month) is BEFORE the cut-off;
-- this month's period (due ~20th of last month) is AFTER it. Both anchored to
-- date_trunc('month', now()), weeks clear of the exact instant, so date-robust.
-- =============================================================================
\set S '''96010000-0000-0000-0000-000000000001'''

create or replace function expect_true(label text, actual boolean) returns void language plpgsql as $$
begin if coalesce(actual,false) then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_text(label text, actual text, want text) returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (%)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if; end $$;

select set_config('t.future', (date_trunc('month', now() + interval '2 months'))::date::text, false);
select set_config('t.past',   (date_trunc('month', now()))::date::text, false);

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('96010000-0000-0000-0000-0000000000a1'),  -- owner
  ('96010000-0000-0000-0000-0000000000f1'),  -- front desk
  ('96010000-0000-0000-0000-0000000000c1'),  -- I_future login
  ('96010000-0000-0000-0000-0000000000c2'),  -- I_future2 login
  ('96010000-0000-0000-0000-0000000000c3');  -- I_past login
insert into profiles (id, email) values
  ('96010000-0000-0000-0000-0000000000a1','9601-o@example.com'),
  ('96010000-0000-0000-0000-0000000000f1','9601-fd@example.com'),
  ('96010000-0000-0000-0000-0000000000c1','9601-c1@example.com'),
  ('96010000-0000-0000-0000-0000000000c2','9601-c2@example.com'),
  ('96010000-0000-0000-0000-0000000000c3','9601-c3@example.com');

-- UTC studio so the studio-local date is unambiguous; due day 20.
insert into studios (id, name, slug, timezone, currency, status) values
  (:S,'Reopen Co','reopenco','UTC','CZK','active');
insert into studio_settings (studio_id, availability_due_day) values (:S, 20);
insert into locations (id, studio_id, name, is_primary) values
  ('96010000-0000-0000-0000-00000000000a',:S,'Main',true);

insert into studio_staff (id, studio_id, user_id, email, role, status) values
  ('96010000-0000-0000-0000-000000aa00a1',:S,'96010000-0000-0000-0000-0000000000a1','9601-o@example.com','owner','active'),
  ('96010000-0000-0000-0000-000000aa00f1',:S,'96010000-0000-0000-0000-0000000000f1','9601-fd@example.com','front_desk','active'),
  ('96010000-0000-0000-0000-000000aa00c1',:S,'96010000-0000-0000-0000-0000000000c1','9601-c1@example.com','instructor','active'),
  ('96010000-0000-0000-0000-000000aa00c2',:S,'96010000-0000-0000-0000-0000000000c2','9601-c2@example.com','instructor','active'),
  ('96010000-0000-0000-0000-000000aa00c3',:S,'96010000-0000-0000-0000-0000000000c3','9601-c3@example.com','instructor','active');

insert into instructors (id, studio_id, display_name, staff_id) values
  ('96010000-0000-0000-0000-00000000d001',:S,'Fiona Future',  '96010000-0000-0000-0000-000000aa00c1'),
  ('96010000-0000-0000-0000-00000000d002',:S,'Freya Future2', '96010000-0000-0000-0000-000000aa00c2'),
  ('96010000-0000-0000-0000-00000000d003',:S,'Petra Past',    '96010000-0000-0000-0000-000000aa00c3');

-- APPROVED submissions: two for the future period (before cut-off), one for this
-- month's period (after cut-off).
insert into availability_submissions (id, studio_id, instructor_id, period_start, status, submitted_at, reviewed_at) values
  ('96010000-0000-0000-0000-0000000b0001',:S,'96010000-0000-0000-0000-00000000d001', current_setting('t.future')::date, 'approved', now(), now()),
  ('96010000-0000-0000-0000-0000000b0002',:S,'96010000-0000-0000-0000-00000000d002', current_setting('t.future')::date, 'approved', now(), now()),
  ('96010000-0000-0000-0000-0000000b0003',:S,'96010000-0000-0000-0000-00000000d003', current_setting('t.past')::date,   'approved', now(), now());

-- Each submission's rows, approved (the editable-again proxy is these flipping).
insert into instructor_availability (studio_id, instructor_id, day_of_week, starts_at_time, ends_at_time, effective_from, effective_to, approval_status, is_available, submission_id) values
  (:S,'96010000-0000-0000-0000-00000000d001',1,'09:00','17:00', current_date, current_date + 120, 'approved', true, '96010000-0000-0000-0000-0000000b0001'),
  (:S,'96010000-0000-0000-0000-00000000d002',2,'10:00','14:00', current_date, current_date + 120, 'approved', true, '96010000-0000-0000-0000-0000000b0002'),
  (:S,'96010000-0000-0000-0000-00000000d003',3,'08:00','12:00', current_date, current_date + 120, 'approved', true, '96010000-0000-0000-0000-0000000b0003');

reset role;

-- =============================================================================
-- (1) Reopen an approved month BEFORE the cut-off, no note → default sentence.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','96010000-0000-0000-0000-0000000000a1',false);

select expect_true('reopen (future, no note) returns ok',
  (reopen_availability_submission('96010000-0000-0000-0000-0000000b0001', null) ->> 'ok')::boolean);

select set_config('request.jwt.claim.sub','',false); reset role;

select expect_text('submission is now changes_requested',
  (select status from availability_submissions where id = '96010000-0000-0000-0000-0000000b0001'),
  'changes_requested');
select expect_text('submission note is the default sentence',
  (select note from availability_submissions where id = '96010000-0000-0000-0000-0000000b0001'),
  'Reopened by Reopen Co so you can make changes.');
select expect_text('the instructor row is editable again (changes_requested)',
  (select approval_status from instructor_availability where submission_id = '96010000-0000-0000-0000-0000000b0001'),
  'changes_requested');
select expect_true('availability_changes_requested email queued to the instructor login',
  exists(select 1 from notifications
          where studio_id = :S
            and template_key = 'availability_changes_requested'
            and user_id = '96010000-0000-0000-0000-0000000000c1'
            and payload ->> 'note' = 'Reopened by Reopen Co so you can make changes.'));

-- =============================================================================
-- (2) Reopen BEFORE the cut-off WITH a note → that note is used verbatim.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','96010000-0000-0000-0000-0000000000a1',false);
select reopen_availability_submission('96010000-0000-0000-0000-0000000b0002', 'We need you on Wednesday evenings too.');
select set_config('request.jwt.claim.sub','',false); reset role;

select expect_text('explicit note stored on the submission',
  (select note from availability_submissions where id = '96010000-0000-0000-0000-0000000b0002'),
  'We need you on Wednesday evenings too.');
select expect_true('explicit note carried in the email payload',
  exists(select 1 from notifications
          where template_key = 'availability_changes_requested'
            and user_id = '96010000-0000-0000-0000-0000000000c2'
            and payload ->> 'note' = 'We need you on Wednesday evenings too.'));

-- =============================================================================
-- (3) AFTER the cut-off → cutoff_passed (PT409), submission left approved.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','96010000-0000-0000-0000-0000000000a1',false);
do $$ begin
  perform reopen_availability_submission('96010000-0000-0000-0000-0000000b0003', null);
  raise exception 'FAIL  reopen after the cut-off should have refused';
exception
  when sqlstate 'PT409' then
    if position('cut-off' in sqlerrm) > 0 then
      raise notice 'PASS  reopen after the cut-off refused PT409 (%)', sqlerrm;
    else
      raise exception 'FAIL  PT409 but wrong message: %', sqlerrm;
    end if;
end $$;
select set_config('request.jwt.claim.sub','',false); reset role;

select expect_text('the past submission is still approved (unchanged)',
  (select status from availability_submissions where id = '96010000-0000-0000-0000-0000000b0003'),
  'approved');
select expect_text('the past submission rows are still approved',
  (select approval_status from instructor_availability where submission_id = '96010000-0000-0000-0000-0000000b0003'),
  'approved');

-- =============================================================================
-- (4) Front desk cannot reopen → PT403.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','96010000-0000-0000-0000-0000000000f1',false);
do $$ begin
  perform reopen_availability_submission('96010000-0000-0000-0000-0000000b0001', null);
  raise exception 'FAIL  front desk should not be able to reopen';
exception
  when sqlstate 'PT403' then raise notice 'PASS  front desk reopen refused PT403';
end $$;
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- (5) The public request_availability_changes still requires a note (unchanged).
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','96010000-0000-0000-0000-0000000000a1',false);
do $$ begin
  perform request_availability_changes('96010000-0000-0000-0000-0000000b0001', '   ');
  raise exception 'FAIL  request_availability_changes with a blank note should refuse';
exception
  when sqlstate 'PT422' then raise notice 'PASS  request_availability_changes still requires a note (PT422)';
end $$;
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- (6) Anon surface unchanged — the new functions are not anon.
-- =============================================================================
select expect_true('reopen_availability_submission is NOT anon',
  not has_function_privilege('anon','reopen_availability_submission(uuid, text)','execute'));
select expect_true('request_availability_changes_run is service-only (not authed, not anon)',
  not has_function_privilege('anon','request_availability_changes_run(uuid, text)','execute')
  and not has_function_privilege('authenticated','request_availability_changes_run(uuid, text)','execute'));

select 'reopen_availability_test PASS' as result;
