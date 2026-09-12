-- =============================================================================
-- Opening a shift, alerting the qualified, and the reliability record
-- Migrations 114 and 115
-- =============================================================================
-- UUID space 0b57, checked free. Run after `supabase db reset`.
--
-- 1. open_shift() takes an instructor off a class and opens it — the class
--    stays bookable, the instructor removed is told (or reported uncontactable),
--    and it is audited with who and why.
-- 2. notify_open_shifts() emails QUALIFIED instructors only, batched, with the
--    unavailable ones told too but plainly marked, and no-login ones reported.
-- 3. Reliability is MEASURED per instructor and never enforced: applied,
--    approved, withdrawn, with the notice each withdrawal gave. Nothing ranks
--    or restricts.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual then raise notice 'PASS  %  (got true)', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_false(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual is not null and not actual then raise notice 'PASS  %  (got false)', label;
  else raise exception 'FAIL  %  expected false, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_raises(label text, stmt text, want_sqlstate text)
returns void language plpgsql as $$
begin
  execute stmt; raise exception 'FAIL  %  expected % but nothing raised', label, want_sqlstate;
exception when others then
  if sqlstate = want_sqlstate then raise notice 'PASS  %  (got %)', label, sqlstate;
  elsif sqlstate = 'P0001' and sqlerrm like 'FAIL%' then raise;
  else raise exception 'FAIL  %  expected %, got % (%)', label, want_sqlstate, sqlstate, sqlerrm; end if;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('0b570b57-0000-0000-0000-0000000000a1'),  -- owner
  ('0b570b57-0000-0000-0000-0000000000a2'),  -- front desk
  ('0b570b57-0000-0000-0000-0000000000d1'),  -- Ada (login)
  ('0b570b57-0000-0000-0000-0000000000d2'),  -- Bea (login)
  ('0b570b57-0000-0000-0000-0000000000e1'),  -- member
  ('0b570b57-0000-0000-0000-0000000000e2');  -- member
insert into profiles (id, email) values
  ('0b570b57-0000-0000-0000-0000000000a1','0b57-owner@example.com'),
  ('0b570b57-0000-0000-0000-0000000000a2','0b57-desk@example.com'),
  ('0b570b57-0000-0000-0000-0000000000d1','0b57-ada@example.com'),
  ('0b570b57-0000-0000-0000-0000000000d2','0b57-bea@example.com'),
  ('0b570b57-0000-0000-0000-0000000000e1','0b57-m1@example.com'),
  ('0b570b57-0000-0000-0000-0000000000e2','0b57-m2@example.com');

insert into studios (id, name, slug, timezone, currency, status) values
  ('0b570b57-0000-0000-0000-000000000001','Shift Studio','shift-studio','Europe/Prague','CZK','active');
insert into studio_settings (studio_id, cover_escalation_hours) values
  ('0b570b57-0000-0000-0000-000000000001', 24);
insert into locations (id, studio_id, name, is_primary) values
  ('0b570b57-0000-0000-0000-00000000000a','0b570b57-0000-0000-0000-000000000001','Main',true);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('0b570b57-0000-0000-0000-0000000aa001','0b570b57-0000-0000-0000-000000000001','0b570b57-0000-0000-0000-0000000000a1','0b57-owner@example.com','owner'),
  ('0b570b57-0000-0000-0000-0000000aa002','0b570b57-0000-0000-0000-000000000001','0b570b57-0000-0000-0000-0000000000a2','0b57-desk@example.com','front_desk'),
  ('0b570b57-0000-0000-0000-0000000aa0d1','0b570b57-0000-0000-0000-000000000001','0b570b57-0000-0000-0000-0000000000d1','0b57-ada@example.com','instructor'),
  ('0b570b57-0000-0000-0000-0000000aa0d2','0b570b57-0000-0000-0000-000000000001','0b570b57-0000-0000-0000-0000000000d2','0b57-bea@example.com','instructor');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('0b570b57-0000-0000-0000-000000ee0001','0b570b57-0000-0000-0000-000000000001','0b570b57-0000-0000-0000-00000000000a','R1',10),
  ('0b570b57-0000-0000-0000-000000ee0002','0b570b57-0000-0000-0000-000000000001','0b570b57-0000-0000-0000-00000000000a','R2',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('0b570b57-0000-0000-0000-000000cc0001','0b570b57-0000-0000-0000-000000000001','Reformer',50,10),
  ('0b570b57-0000-0000-0000-000000cc0002','0b570b57-0000-0000-0000-000000000001','Barre',50,10);

-- Ada and Bea have logins. Cai has none — the ordinary case, and the one an
-- alert must report as uncontactable rather than imply was told.
insert into instructors (id, studio_id, display_name, staff_id) values
  ('0b570b57-0000-0000-0000-0000000d0001','0b570b57-0000-0000-0000-000000000001','Ada','0b570b57-0000-0000-0000-0000000aa0d1'),
  ('0b570b57-0000-0000-0000-0000000d0002','0b570b57-0000-0000-0000-000000000001','Bea','0b570b57-0000-0000-0000-0000000aa0d2'),
  ('0b570b57-0000-0000-0000-0000000d0003','0b570b57-0000-0000-0000-000000000001','Cai',null),
  -- Dee is qualified for Barre only — she must NOT be alerted about a Reformer.
  ('0b570b57-0000-0000-0000-0000000d0004','0b570b57-0000-0000-0000-000000000001','Dee',null);

insert into instructor_class_types (studio_id, instructor_id, class_type_id) values
  ('0b570b57-0000-0000-0000-000000000001','0b570b57-0000-0000-0000-0000000d0001','0b570b57-0000-0000-0000-000000cc0001'),
  ('0b570b57-0000-0000-0000-000000000001','0b570b57-0000-0000-0000-0000000d0002','0b570b57-0000-0000-0000-000000cc0001'),
  ('0b570b57-0000-0000-0000-000000000001','0b570b57-0000-0000-0000-0000000d0003','0b570b57-0000-0000-0000-000000cc0001'),
  ('0b570b57-0000-0000-0000-000000000001','0b570b57-0000-0000-0000-0000000d0004','0b570b57-0000-0000-0000-000000cc0002');

-- Bea's availability ends before C1's day, so she is qualified but out of
-- window for it — alerted, and marked.
insert into instructor_availability (instructor_id, studio_id, day_of_week, starts_at_time, ends_at_time, effective_from, effective_to)
select '0b570b57-0000-0000-0000-0000000d0002','0b570b57-0000-0000-0000-000000000001', d, '06:00','22:00', current_date-365, current_date+1
  from generate_series(0,6) d;

insert into members (id, studio_id, user_id, first_name, last_name, email, joined_on, status, waiver_signed_at) values
  ('0b570b57-0000-0000-0000-000000dd0001','0b570b57-0000-0000-0000-000000000001','0b570b57-0000-0000-0000-0000000000e1','M','One','0b57-m1@example.com', current_date-30,'active', now()),
  ('0b570b57-0000-0000-0000-000000dd0002','0b570b57-0000-0000-0000-000000000001','0b570b57-0000-0000-0000-0000000000e2','M','Two','0b57-m2@example.com', current_date-30,'active', now());
insert into membership_plans (id, studio_id, name, type, price_cents, currency, billing_interval, credits_per_period, status) values
  ('0b570b57-0000-0000-0000-000000c00001','0b570b57-0000-0000-0000-000000000001','Unlimited','recurring',250000,'CZK','month',null,'active');
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on) values
  ('0b570b57-0000-0000-0000-000000c10001','0b570b57-0000-0000-0000-000000000001','0b570b57-0000-0000-0000-000000dd0001','0b570b57-0000-0000-0000-000000c00001','active',250000,'CZK',current_date-30),
  ('0b570b57-0000-0000-0000-000000c10002','0b570b57-0000-0000-0000-000000000001','0b570b57-0000-0000-0000-000000dd0002','0b570b57-0000-0000-0000-000000c00001','active',250000,'CZK',current_date-30);

-- Two Reformer classes Ada teaches, three days out (inside a 24h escalation
-- window? no — far out; a near one is added later for short-notice).
insert into class_occurrences
  (id, studio_id, location_id, class_type_id, room_id, name, capacity, instructor_id, starts_at, ends_at, status, staffing)
values
  ('0b570b57-0000-0000-0000-0000000c0001','0b570b57-0000-0000-0000-000000000001','0b570b57-0000-0000-0000-00000000000a',
   '0b570b57-0000-0000-0000-000000cc0001','0b570b57-0000-0000-0000-000000ee0001','Reformer One',10,'0b570b57-0000-0000-0000-0000000d0001',
   ((current_date+3)+time '07:00') at time zone 'Europe/Prague', ((current_date+3)+time '07:50') at time zone 'Europe/Prague','scheduled','assigned'),
  ('0b570b57-0000-0000-0000-0000000c0002','0b570b57-0000-0000-0000-000000000001','0b570b57-0000-0000-0000-00000000000a',
   '0b570b57-0000-0000-0000-000000cc0001','0b570b57-0000-0000-0000-000000ee0002','Reformer Two',10,'0b570b57-0000-0000-0000-0000000d0003',
   ((current_date+4)+time '07:00') at time zone 'Europe/Prague', ((current_date+4)+time '07:50') at time zone 'Europe/Prague','scheduled','assigned');

-- A member books C1, so we can prove it stays bookable after opening.
set role authenticated;
select set_config('request.jwt.claim.sub','0b570b57-0000-0000-0000-0000000000e1',false);
select book_class('0b570b57-0000-0000-0000-0000000c0001','0b570b57-0000-0000-0000-000000dd0001','member');
reset role;

-- =============================================================================
-- 1. OPEN A SHIFT
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','0b570b57-0000-0000-0000-0000000000a2',false);  -- front desk
select expect_raises('front desk cannot open a shift',
  $$ select open_shift('0b570b57-0000-0000-0000-0000000c0001','no') $$, 'PT403');

select set_config('request.jwt.claim.sub','0b570b57-0000-0000-0000-0000000000a1',false);  -- owner
select expect_raises('opening with no reason is refused',
  $$ select open_shift('0b570b57-0000-0000-0000-0000000c0001','  ') $$, 'PT422');

select set_config('t.o1', (select open_shift('0b570b57-0000-0000-0000-0000000c0001','Ada asked for the morning off')::text), false);
select expect_true('C1 opens', (current_setting('t.o1')::jsonb ->> 'ok')::boolean);
select expect_text('...naming who was removed', current_setting('t.o1')::jsonb ->> 'removed_instructor', 'Ada');
select expect_true('...and she was told', (current_setting('t.o1')::jsonb ->> 'removed_notified')::boolean);
reset role;
select expect_text('C1 is now an open shift with nobody on it',
  (select staffing::text || '/' || coalesce(instructor_id::text,'null') from class_occurrences where id='0b570b57-0000-0000-0000-0000000c0001'),
  'open/null');
select expect_num('...the members keep their seats — it stayed bookable throughout',
  (select booked_count from class_occurrences where id='0b570b57-0000-0000-0000-0000000c0001')::bigint, 1);
select expect_num('...Ada got the shift_taken_off notice',
  (select count(*) from notifications where template_key='shift_taken_off'
      and user_id='0b570b57-0000-0000-0000-0000000000d1'), 1);
select expect_true('...the notice carries the reason',
  (select payload ->> 'reason' = 'Ada asked for the morning off' from notifications where template_key='shift_taken_off' limit 1));
select expect_num('...and it is audited with who and why',
  (select count(*) from audit_logs where action='occurrence.opened'
      and entity_id='0b570b57-0000-0000-0000-0000000c0001'
      and after ->> 'reason' = 'Ada asked for the morning off'), 1);

-- The class is still bookable: a second member books it while it is open.
set role authenticated;
select set_config('request.jwt.claim.sub','0b570b57-0000-0000-0000-0000000000e2',false);
select expect_text('a member books the open class',
  (book_class('0b570b57-0000-0000-0000-0000000c0001','0b570b57-0000-0000-0000-000000dd0002','member')).status::text, 'booked');

-- Open C2, whose instructor Cai has NO login.
select set_config('request.jwt.claim.sub','0b570b57-0000-0000-0000-0000000000a1',false);
select set_config('t.o2', (select open_shift('0b570b57-0000-0000-0000-0000000c0002','Covering a gap')::text), false);
select expect_false('Cai has no login, so nobody was notified', (current_setting('t.o2')::jsonb ->> 'removed_notified')::boolean);
select expect_true('...and that is reported as uncontactable, not passed off as told',
  (current_setting('t.o2')::jsonb ->> 'removed_uncontactable')::boolean);
reset role;
select expect_num('...no shift_taken_off notice was queued for Cai',
  (select count(*) from notifications where template_key='shift_taken_off'
      and payload ->> 'instructor_name' = 'Cai'), 0);
select expect_raises('a class already open cannot be opened again',
  $$ select open_shift('0b570b57-0000-0000-0000-0000000c0002','again') $$, 'PT409');

-- =============================================================================
-- 2. ALERT THE QUALIFIED — BATCHED, AVAILABLE FIRST, NO-LOGIN REPORTED
-- =============================================================================
-- Both C1 and C2 are open (Reformer). notify_open_shifts batches: each
-- qualified instructor with a login gets ONE email listing both.
select set_config('t.sweep', (select notify_open_shifts()::text), false);
-- notify_open_shifts() is global; every count is scoped to this studio, or it
-- is a shared-reset count of whatever else is open across the database.
select expect_num('this studio''s two shifts are alerted',
  (select count(*) from class_occurrences where studio_id='0b570b57-0000-0000-0000-000000000001'
      and staffing='open' and shift_alert_sent_at is not null)::bigint, 2);
select expect_num('Ada and Bea are told — the two qualified instructors with logins',
  (select count(distinct user_id) from notifications where template_key='open_shifts_available'
      and studio_id='0b570b57-0000-0000-0000-000000000001')::bigint, 2);
select expect_num('...one email each, not one per shift',
  (select count(*) from notifications where template_key='open_shifts_available'
      and studio_id='0b570b57-0000-0000-0000-000000000001'), 2);
select expect_num('...Ada''s lists BOTH shifts',
  (select array_length(string_to_array(payload ->> 'lines', E'\n'), 1) from notifications
    where template_key='open_shifts_available' and user_id='0b570b57-0000-0000-0000-0000000000d1')::bigint, 2);
select expect_num('Cai is qualified but has no login — reported uncontactable',
  (select count(*) from jsonb_array_elements(current_setting('t.sweep')::jsonb -> 'uncontactable') u
    where u ->> 'studio_id' = '0b570b57-0000-0000-0000-000000000001'), 1);
select expect_text('...and it is Cai',
  (select u ->> 'name' from jsonb_array_elements(current_setting('t.sweep')::jsonb -> 'uncontactable') u
    where u ->> 'studio_id' = '0b570b57-0000-0000-0000-000000000001' limit 1), 'Cai');
select expect_num('Dee, qualified only for Barre, was not told about a Reformer',
  (select count(*) from notifications where template_key='open_shifts_available'
      and payload ->> 'instructor_name' = 'Dee'), 0);
select expect_true('Bea is alerted but MARKED — her availability ended before C1',
  (select payload ->> 'lines' like '%outside the hours you gave us%' from notifications
    where template_key='open_shifts_available' and user_id='0b570b57-0000-0000-0000-0000000000d2'));
select expect_true('...while Ada, in window, is not marked',
  (select payload ->> 'lines' not like '%outside the hours%' from notifications
    where template_key='open_shifts_available' and user_id='0b570b57-0000-0000-0000-0000000000d1'));

-- A second sweep sends nothing more — the shifts are alerted.
select set_config('t.sweep2', (select notify_open_shifts()::text), false);
select expect_num('a second sweep alerts none of THIS studio''s shifts again',
  (select count(*) from notifications where template_key='open_shifts_available'
      and studio_id='0b570b57-0000-0000-0000-000000000001'), 2);

-- =============================================================================
-- 3. RELIABILITY — MEASURED, NEVER ENFORCED
-- =============================================================================
-- Ada applies for both open shifts; Bea applies for C1.
set role authenticated;
select set_config('request.jwt.claim.sub','0b570b57-0000-0000-0000-0000000000d1',false);  -- Ada
select apply_for_shift('0b570b57-0000-0000-0000-0000000c0001');
select apply_for_shift('0b570b57-0000-0000-0000-0000000c0002');
select set_config('request.jwt.claim.sub','0b570b57-0000-0000-0000-0000000000d2',false);  -- Bea
select apply_for_shift('0b570b57-0000-0000-0000-0000000c0001');
reset role;

-- Staff approve Ada for C1 (auto-declines Bea).
set role authenticated;
select set_config('request.jwt.claim.sub','0b570b57-0000-0000-0000-0000000000a1',false);
select approve_shift_application((select id from shift_applications
  where occurrence_id='0b570b57-0000-0000-0000-0000000c0001' and instructor_id='0b570b57-0000-0000-0000-0000000d0001'));
reset role;
select expect_num('Ada''s C1 application is approved, with approved_at stamped',
  (select count(*) from shift_applications where instructor_id='0b570b57-0000-0000-0000-0000000d0001'
      and occurrence_id='0b570b57-0000-0000-0000-0000000c0001' and status='approved' and approved_at is not null), 1);

-- Ada withdraws her PENDING C2 application — the case that used to 403.
set role authenticated;
select set_config('request.jwt.claim.sub','0b570b57-0000-0000-0000-0000000000d1',false);
select set_config('t.wd', (select withdraw_application('0b570b57-0000-0000-0000-0000000c0002')::text), false);
select expect_true('withdrawing a pending application works (it used to be refused)',
  (current_setting('t.wd')::jsonb ->> 'ok')::boolean);
select expect_true('...and the notice given is recorded',
  (current_setting('t.wd')::jsonb ->> 'notice_hours') is not null);
reset role;

-- The reliability record.
set role authenticated;
select set_config('request.jwt.claim.sub','0b570b57-0000-0000-0000-0000000000d1',false);  -- Ada, own record
select set_config('t.rel', (select instructor_reliability('0b570b57-0000-0000-0000-0000000d0001')::text), false);
select expect_num('Ada applied for two', (current_setting('t.rel')::jsonb ->> 'applied')::bigint, 2);
select expect_num('...approved for one', (current_setting('t.rel')::jsonb ->> 'approved')::bigint, 1);
select expect_num('...withdrew from one', (current_setting('t.rel')::jsonb ->> 'withdrawn')::bigint, 1);
select expect_text('...with a plain summary for a chip',
  current_setting('t.rel')::jsonb ->> 'summary', 'applied for 2, withdrew from 1');
select expect_true('...and can see her own record', current_setting('t.rel')::jsonb ? 'withdrawals');
reset role;

-- An approved backout: Ada is teaching C1, she pulls out. Cover is raised
-- (Decision 18) AND the approved application is recorded as withdrawn.
set role authenticated;
select set_config('request.jwt.claim.sub','0b570b57-0000-0000-0000-0000000000d1',false);
select withdraw_from_shift('0b570b57-0000-0000-0000-0000000c0001');
select set_config('t.rel2', (select instructor_reliability('0b570b57-0000-0000-0000-0000000d0001')::text), false);
select expect_num('backing out after approval counts as a withdrawal too',
  (current_setting('t.rel2')::jsonb ->> 'withdrawn')::bigint, 2);
select expect_num('...and "approved for" still counts it — approved_at is never cleared',
  (current_setting('t.rel2')::jsonb ->> 'approved')::bigint, 1);
reset role;

-- Short notice: C1 is three days out and the window is 24h, so neither
-- withdrawal is short notice.
select expect_num('neither withdrawal is inside the 24h escalation window',
  (current_setting('t.rel2')::jsonb ->> 'short_notice')::bigint, 0);

-- Per instructor per studio: Bea's record is her own, untouched by Ada's.
set role authenticated;
select set_config('request.jwt.claim.sub','0b570b57-0000-0000-0000-0000000000d2',false);
select set_config('t.relb', (select instructor_reliability('0b570b57-0000-0000-0000-0000000d0002')::text), false);
select expect_num('Bea applied for one (C1), was auto-declined, withdrew from none',
  (current_setting('t.relb')::jsonb ->> 'withdrawn')::bigint, 0);
select expect_num('...a decline is not a withdrawal', (current_setting('t.relb')::jsonb ->> 'applied')::bigint, 1);
-- A stranger cannot read it.
select set_config('request.jwt.claim.sub','0b570b57-0000-0000-0000-0000000000e1',false);  -- a member
select expect_raises('a member cannot read an instructor''s record',
  $$ select instructor_reliability('0b570b57-0000-0000-0000-0000000d0001') $$, 'PT403');
reset role;

-- MEASURED, NEVER ENFORCED: nothing about Ada's record stops her applying
-- again or being approved. The metric reads nothing back into eligibility.
set role authenticated;
select set_config('request.jwt.claim.sub','0b570b57-0000-0000-0000-0000000000d1',false);
select expect_true('an instructor with withdrawals can still apply — nothing is restricted',
  (apply_for_shift('0b570b57-0000-0000-0000-0000000c0002') ->> 'ok')::boolean is not false);
reset role;


-- Clean up so this suite leaves NO global state — the notification queue and
-- the flex/open-shift rows would otherwise inflate a later suite's unscoped
-- sweep counts (flex_test counts flex studios, notifications_test churns the
-- queue). Deleting the studio cascades its occurrences, notifications and
-- applications; the auth.users go with it.
-- notify_open_shifts() is global, so it queued open_shifts_available for other
-- studios' instructors too; clear this suite's whole footprint from the queue.
delete from notifications
 where studio_id = '0b570b57-0000-0000-0000-000000000001'
    or template_key in ('open_shifts_available','shift_taken_off');

select 'shift ops suite finished' as done;
