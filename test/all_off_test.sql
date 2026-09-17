-- =============================================================================
-- The CANARY: a studio that has turned NOTHING on. Migration-independent.
-- UUID space 0ff0. Run after `supabase db reset`.
-- =============================================================================
-- Two defaults have already leaked — core_unmet_pay_pct at 50 for every studio,
-- and record_class_pay writing records for studios that never configured
-- payroll. Both were defaults that DID something rather than sat there. This
-- studio is the standing proof against the next one: it inserts studio_settings
-- with ONLY its studio_id, so every opt-in flag takes its default, and it
-- carries a real substrate — instructors, a timetable with a cancelled and a
-- past class, members with bookings, a silent roster past its deadline. Then
-- every feature sweep is run against it, and the assertion is that the whole
-- opt-in surface is inert: no pay, no periods, no roster written, no infraction,
-- no peak, nothing in reporting about instructor cost, and the Pay surfaces off.
--
-- If a future default starts DOING something to a studio that opted into
-- nothing, one of these assertions breaks. That is the point of it.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin if actual then raise notice 'PASS  %', label; else raise exception 'FAIL  %  expected true', label; end if; end $$;
-- Runs a sweep and fails the suite loudly if it raises — a cron that errors on an
-- untouched studio is exactly the kind of thing this canary is here to catch.
create or replace function run_sweep(label text, sql text) returns void language plpgsql as $$
begin execute sql; raise notice 'RAN   %', label;
exception when others then raise exception 'SWEEP FAILED %: %', label, sqlerrm; end $$;

-- --- The untouched studio -----------------------------------------------------
insert into studios (id,name,slug,timezone,currency,status) values
  ('0ff00ff0-0000-0000-0000-000000000001','All Off','0ff0-a','UTC','USD','active');
-- ONLY the studio_id: every opt-in flag defaults, nothing is turned on.
insert into studio_settings (studio_id) values ('0ff00ff0-0000-0000-0000-000000000001');
insert into locations (id,studio_id,name,is_primary) values
  ('0ff00ff0-0000-0000-0000-00000000000a','0ff00ff0-0000-0000-0000-000000000001','Main',true);
-- Instructors with NO logins (the ordinary case) — so staffing sweeps have
-- somebody to consider but nobody to email.
insert into instructors (id,studio_id,display_name,status) values
  ('0ff00ff0-0000-0000-0000-0000000d0001','0ff00ff0-0000-0000-0000-000000000001','Ada','active'),
  ('0ff00ff0-0000-0000-0000-0000000d0002','0ff00ff0-0000-0000-0000-000000000001','Bea','active');
insert into class_types (id,studio_id,name,duration_minutes,default_capacity) values
  ('0ff00ff0-0000-0000-0000-0000000cc001','0ff00ff0-0000-0000-0000-000000000001','Reformer',50,8);
insert into rooms (id,studio_id,location_id,name,capacity) values
  ('0ff00ff0-0000-0000-0000-0000000ee001','0ff00ff0-0000-0000-0000-000000000001','0ff00ff0-0000-0000-0000-00000000000a','R1',8);
-- A timetable: a class that already ran, one cancelled by the studio, one ahead.
insert into class_occurrences (id,studio_id,location_id,class_type_id,room_id,instructor_id,name,starts_at,ends_at,capacity,booked_count,status) values
  ('0ff00ff0-0000-0000-0000-00000000c001','0ff00ff0-0000-0000-0000-000000000001','0ff00ff0-0000-0000-0000-00000000000a','0ff00ff0-0000-0000-0000-0000000cc001','0ff00ff0-0000-0000-0000-0000000ee001','0ff00ff0-0000-0000-0000-0000000d0001','Ran', now()-interval '2 days', now()-interval '2 days'+interval '50 min',8,1,'scheduled'),
  ('0ff00ff0-0000-0000-0000-00000000c002','0ff00ff0-0000-0000-0000-000000000001','0ff00ff0-0000-0000-0000-00000000000a','0ff00ff0-0000-0000-0000-0000000cc001','0ff00ff0-0000-0000-0000-0000000ee001','0ff00ff0-0000-0000-0000-0000000d0001','Ahead', now()+interval '2 days', now()+interval '2 days'+interval '50 min',8,1,'scheduled');
-- One cancelled by the studio: the shape that leaked in 139 (a cancel writing a
-- pay record). With no payroll AND no rate on file it must write nothing.
insert into class_occurrences (id,studio_id,location_id,class_type_id,room_id,instructor_id,name,starts_at,ends_at,capacity,booked_count,status,cancellation_cause,cancelled_at) values
  ('0ff00ff0-0000-0000-0000-00000000c003','0ff00ff0-0000-0000-0000-000000000001','0ff00ff0-0000-0000-0000-00000000000a','0ff00ff0-0000-0000-0000-0000000cc001','0ff00ff0-0000-0000-0000-0000000ee001','0ff00ff0-0000-0000-0000-0000000d0001','Off', now()-interval '1 day', now()-interval '1 day'+interval '50 min',8,0,'cancelled','studio_fault', now());
insert into members (id,studio_id,first_name,last_name,email) values
  ('0ff00ff0-0000-0000-0000-0000000ba001','0ff00ff0-0000-0000-0000-000000000001','Mel',' Off','0ff0-m1@example.com'),
  ('0ff00ff0-0000-0000-0000-0000000ba002','0ff00ff0-0000-0000-0000-000000000001','Nia','Off','0ff0-m2@example.com');
-- A booking on the class that ran, left 'booked' and never checked in — the
-- absence a no-show sweep would mark IF suspension were on.
insert into bookings (id,studio_id,occurrence_id,member_id,status) values
  ('0ff00ff0-0000-0000-0000-0000000b0001','0ff00ff0-0000-0000-0000-000000000001','0ff00ff0-0000-0000-0000-00000000c001','0ff00ff0-0000-0000-0000-0000000ba001','booked'),
  ('0ff00ff0-0000-0000-0000-0000000b0002','0ff00ff0-0000-0000-0000-000000000001','0ff00ff0-0000-0000-0000-00000000c002','0ff00ff0-0000-0000-0000-0000000ba002','booked');
-- A silent instructor past a roster deadline — carry-forward must not fire.
insert into roster_confirmations (studio_id,instructor_id,month,notified_at,confirmed_at) values
  ('0ff00ff0-0000-0000-0000-000000000001','0ff00ff0-0000-0000-0000-0000000d0001','2026-11-01', now()-interval '40 days', now()-interval '35 days'),
  ('0ff00ff0-0000-0000-0000-000000000001','0ff00ff0-0000-0000-0000-0000000d0001','2026-12-01', now()-interval '20 days', null);

-- Ada gets a LOGIN, a class next week, and the studio's ask/due days are set to
-- TODAY — so the weekly-confirmation and availability sweeps WOULD email her if
-- the gates weren't holding. That is what makes "0 notifications" mean the
-- switch, not the absence of somebody to email.
insert into auth.users (id) values ('0ff00ff0-0000-0000-0000-0000000000a1');
insert into profiles (id, email) values ('0ff00ff0-0000-0000-0000-0000000000a1','0ff0-ada@example.com');
insert into studio_staff (id,studio_id,user_id,email,role) values
  ('0ff00ff0-0000-0000-0000-0000000aa001','0ff00ff0-0000-0000-0000-000000000001','0ff00ff0-0000-0000-0000-0000000000a1','0ff0-ada@example.com','instructor');
update instructors set staff_id='0ff00ff0-0000-0000-0000-0000000aa001' where id='0ff00ff0-0000-0000-0000-0000000d0001';
insert into class_occurrences (id,studio_id,location_id,class_type_id,room_id,instructor_id,name,starts_at,ends_at,capacity,booked_count,status) values
  ('0ff00ff0-0000-0000-0000-00000000c004','0ff00ff0-0000-0000-0000-000000000001','0ff00ff0-0000-0000-0000-00000000000a','0ff00ff0-0000-0000-0000-0000000cc001','0ff00ff0-0000-0000-0000-0000000ee001','0ff00ff0-0000-0000-0000-0000000d0001','Next week', now()+interval '8 days', now()+interval '8 days'+interval '50 min',8,0,'scheduled');
update studio_settings set
  week_confirm_ask_dow = extract(dow from (now())::date)::int,
  availability_due_day = greatest(1, least(28, extract(day from (now())::date)::int))
 where studio_id = '0ff00ff0-0000-0000-0000-000000000001';

-- Baseline notifications for this studio (fixtures may queue booking confirms);
-- what matters is that the SWEEPS add none.
create temp table _off_base as
  select count(*) c from notifications where studio_id = '0ff00ff0-0000-0000-0000-000000000001';

-- --- Run every feature sweep --------------------------------------------------
select run_sweep('no_shows',              'select sweep_no_shows()');
select run_sweep('roster_carry',          'select sweep_roster_carry()');
select run_sweep('commitments',           'select sweep_commitments()');
select run_sweep('week_confirmations',    'select sweep_week_confirmations()');
select run_sweep('availability_reminders','select sweep_availability_reminders()');
select run_sweep('challenges',            'select sweep_challenges()');
select run_sweep('guest_waivers',         'select sweep_guest_waivers()');
select run_sweep('peak_cutoff_reminders', 'select sweep_peak_cutoff_reminders()');
select run_sweep('instructor_confirms',   'select sweep_instructor_confirmations()');
select run_sweep('waitlist',              'select sweep_waitlist()');
select run_sweep('cover_escalations',     'select sweep_cover_escalations()');

-- =============================================================================
-- Inert: the whole opt-in surface wrote nothing for this studio.
-- =============================================================================
\set S '0ff00ff0-0000-0000-0000-000000000001'
select expect_num('no instructor pay records',
  (select count(*) from instructor_pay_records where studio_id = :'S'), 0);
select expect_num('no pay periods',
  (select count(*) from pay_periods where studio_id = :'S'), 0);
select expect_num('no pay settlements',
  (select count(*) from instructor_pay_settlements where studio_id = :'S'), 0);
select expect_num('no rate versions (none were ever created)',
  (select count(*) from instructor_rate_versions where studio_id = :'S'), 0);
select expect_num('no occurrence was ever committed (guarantees off)',
  (select count(*) from class_occurrences where studio_id = :'S' and committed_at is not null), 0);
select expect_num('no peak allowance rows',
  (select count(*) from peak_allowance_ledger where studio_id = :'S'), 0);
select expect_num('no infractions',
  (select count(*) from member_infractions where studio_id = :'S'), 0);
select expect_num('the absent member was NOT marked no-show (suspension off gates the sweep)',
  (select count(*) from bookings where studio_id = :'S' and status = 'no_show'), 0);
select expect_num('no challenges',
  (select count(*) from challenges where studio_id = :'S'), 0);
select expect_num('no challenge participants',
  (select count(*) from challenge_participants where studio_id = :'S'), 0);
select expect_num('no guest passes',
  (select count(*) from guest_passes where studio_id = :'S'), 0);
select expect_num('no publication rows',
  (select count(*) from schedule_publications where studio_id = :'S'), 0);
select expect_num('no roster was carried (carry-forward off)',
  (select count(*) from roster_confirmations where studio_id = :'S' and carried_at is not null), 0);
select expect_num('the silent instructor is not even DUE a carry (the switch is off)',
  (select count(*) from roster_carry_due(:'S', date '2026-12-01')), 0);
select expect_num('the sweeps queued no notifications for this studio (a login instructor, an in-window class, and still nothing)',
  (select count(*) from notifications where studio_id = :'S') - (select c from _off_base), 0);

-- The three gates 142 added, at their defaults for a studio that inserted only
-- its studio_id.
select expect_true('weekly confirmation is OFF by default (142 flipped it)',
  (select coalesce(week_confirm_enabled, true) from studio_settings where studio_id = :'S') = false);
select expect_true('availability reminders are OFF by default (their own new switch)',
  (select coalesce(availability_reminders_enabled, true) from studio_settings where studio_id = :'S') = false);
select expect_true('studio_uses_seat_caps is false — no seat-cap UI',
  studio_uses_seat_caps(:'S') = false);

-- =============================================================================
-- Invisible: reporting says nothing about the features it never turned on.
-- =============================================================================
select expect_true('studio_uses_payroll is false (no Pay in the rail, no pay tab in the portal)',
  studio_uses_payroll(:'S') = false);
select expect_true('the guest KPI is null (absent from the dashboard, not zero)',
  dashboard_guest_kpi(:'S') is null);
select expect_true('the challenge KPI is null (absent, not zero)',
  dashboard_challenge_kpi(:'S') is null);
-- Decision 30 (free first class): off by default, no trace. Eligibility refuses
-- with not_enabled before anything else, the KPI is absent (not zero), and no
-- free-first ledger row (a host-null guest pass) exists for a studio that never
-- turned it on.
select expect_true('free_first_eligibility refuses with not_enabled',
  free_first_eligibility(:'S', '0ff00ff0-0000-0000-0000-0000000ba002') ->> 'reason' = 'not_enabled');
select expect_true('the free-first KPI is null (absent, not zero)',
  dashboard_free_first_kpi(:'S') is null);
select expect_num('no free-first ledger row (host-null guest pass) exists',
  (select count(*) from guest_passes where studio_id = :'S' and host_member_id is null), 0);

-- =============================================================================
-- Teeth: the switch is the only thing holding the silence. Turn guarantees ON,
-- put a rate on file, and the SAME kind of cancellation now writes a record —
-- so every zero above was the opt-in being off, not an empty studio.
-- =============================================================================
insert into instructor_rate_versions (studio_id,instructor_id,effective_from,currency,base_rate_cents) values
  (:'S','0ff00ff0-0000-0000-0000-0000000d0001', current_date-10,'USD',90000);
update studio_settings set guarantees_enabled = true where studio_id = :'S';
insert into class_occurrences (id,studio_id,location_id,class_type_id,room_id,instructor_id,name,starts_at,ends_at,capacity,booked_count,status) values
  ('0ff00ff0-0000-0000-0000-00000000c009',:'S','0ff00ff0-0000-0000-0000-00000000000a','0ff00ff0-0000-0000-0000-0000000cc001','0ff00ff0-0000-0000-0000-0000000ee001','0ff00ff0-0000-0000-0000-0000000d0001','Teeth', now()+interval '5 days', now()+interval '5 days'+interval '50 min',8,0,'scheduled');
update class_occurrences set status='cancelled', cancellation_cause='studio_fault', cancelled_at=now()
 where id='0ff00ff0-0000-0000-0000-00000000c009';
select expect_num('teeth: with guarantees ON and a rate on file, the identical cancellation DOES write a record',
  (select count(*) from instructor_pay_records where studio_id = :'S'), 1);

-- Teeth for the weekly-confirmation gate: turn it ON and the login instructor
-- with an in-window class on the ask day IS asked — so the zero above was the
-- switch being off, not the sweep having nobody to email.
update studio_settings set week_confirm_enabled = true where studio_id = :'S';
select run_sweep('week_confirmations (on)', 'select sweep_week_confirmations()');
select expect_num('teeth: with weekly confirmation ON, the login instructor IS asked to confirm',
  (select count(*) from notifications where studio_id = :'S' and template_key = 'week_confirm_ask'), 1);

do $$ begin raise notice 'all_off_test: all assertions passed'; end $$;
