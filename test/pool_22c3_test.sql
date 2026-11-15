-- Pooled build: Decision 26(c) invite-needs-plan, Decision 21 runs-regardless,
-- Decision 22 member_bootstrap flags, Decision 103(b) credit-back email, and the
-- non-recurring expiry sweep. UUID space 22c3.
--
-- Run after `supabase db reset`:
--   psql "$DB" -f test/pool_22c3_test.sql

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
begin
  if actual then raise notice 'PASS  %  (got true)', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_false(label text, actual boolean)
returns void language plpgsql as $$
begin
  if not coalesce(actual, true) then raise notice 'PASS  %  (got false)', label;
  else raise exception 'FAIL  %  expected false, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if;
end $$;

-- =============================================================================
-- Fixtures
-- =============================================================================
insert into auth.users (id) values
  ('22c30000-0000-0000-0000-0000000000e1'),  -- host WITH plan
  ('22c30000-0000-0000-0000-0000000000e2'),  -- host WITHOUT plan (lead)
  ('22c30000-0000-0000-0000-0000000000e9'),  -- instructor login
  ('22c30000-0000-0000-0000-0000000000ea');  -- owner login
insert into profiles (id, email)
  select id, id::text||'@example.com' from auth.users where id::text like '22c30000%';

insert into studios (id, name, slug, timezone, currency, status) values
  ('22c30000-0000-0000-0000-0000000000a1','Pool SA','22c3-a','Europe/Prague','CZK','active');

insert into studio_settings (studio_id, guest_passes_enabled, guest_invites_members_only,
                             guarantees_enabled, flex_enabled, core_min_bookings, flex_min_bookings,
                             free_first_reservation_fee_cents, require_waiver, checkin_window_enforced) values
  ('22c30000-0000-0000-0000-0000000000a1', true, true, true, true, 1, 2, 15000, false, false);

insert into locations (id, studio_id, name) values
  ('22c30000-0000-0000-0000-00000000000a','22c30000-0000-0000-0000-0000000000a1','Main');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('22c30000-0000-0000-0000-0000000e0001','22c30000-0000-0000-0000-0000000000a1','22c30000-0000-0000-0000-00000000000a','R1',10),
  ('22c30000-0000-0000-0000-0000000e0002','22c30000-0000-0000-0000-0000000000a1','22c30000-0000-0000-0000-00000000000a','R2',10),
  ('22c30000-0000-0000-0000-0000000e0003','22c30000-0000-0000-0000-0000000000a1','22c30000-0000-0000-0000-00000000000a','R3',10),
  ('22c30000-0000-0000-0000-0000000e0004','22c30000-0000-0000-0000-0000000000a1','22c30000-0000-0000-0000-00000000000a','R4',10),
  ('22c30000-0000-0000-0000-0000000e0005','22c30000-0000-0000-0000-0000000000a1','22c30000-0000-0000-0000-00000000000a','R5',10),
  ('22c30000-0000-0000-0000-0000000e0006','22c30000-0000-0000-0000-0000000000a1','22c30000-0000-0000-0000-00000000000a','R6',10),
  ('22c30000-0000-0000-0000-0000000e0007','22c30000-0000-0000-0000-0000000000a1','22c30000-0000-0000-0000-00000000000a','R7',10);
insert into class_types (id, studio_id, name, status, duration_minutes, default_capacity) values
  ('22c30000-0000-0000-0000-0000000c0001','22c30000-0000-0000-0000-0000000000a1','Reformer','active',50,10);

insert into studio_staff (id, studio_id, user_id, email, role, status) values
  ('22c30000-0000-0000-0000-000000050001','22c30000-0000-0000-0000-0000000000a1','22c30000-0000-0000-0000-0000000000e9','coach@example.com','instructor','active'),
  ('22c30000-0000-0000-0000-00000005000a','22c30000-0000-0000-0000-0000000000a1','22c30000-0000-0000-0000-0000000000ea','owner2@example.com','owner','active');
insert into instructors (id, studio_id, staff_id, display_name, status) values
  ('22c30000-0000-0000-0000-000000010001','22c30000-0000-0000-0000-0000000000a1','22c30000-0000-0000-0000-000000050001','Ada Coach','active');

-- Plans: a recurring (unlimited) plan, and a non-recurring pack (for the sweep).
insert into membership_plans (id, studio_id, name, type, price_cents, currency, billing_interval,
                              credits_per_period, credits, validity_days, status, visibility) values
  ('22c30000-0000-0000-0000-000000090001','22c30000-0000-0000-0000-0000000000a1','Unlimited','recurring',500000,'CZK','month',null,null,null,'active','public'),
  ('22c30000-0000-0000-0000-000000090002','22c30000-0000-0000-0000-0000000000a1','5-Pack','class_pack',140000,'CZK',null,null,5,30,'active','public');

-- Members: host-with-plan, host-without-plan (lead), credit members, sweep members.
insert into members (id, studio_id, user_id, first_name, last_name, email, status, waiver_signed_at) values
  ('22c30000-0000-0000-0000-00000000f001','22c30000-0000-0000-0000-0000000000a1','22c30000-0000-0000-0000-0000000000e1','Hera','Plan','hera@example.com','active', now()),
  ('22c30000-0000-0000-0000-00000000f002','22c30000-0000-0000-0000-0000000000a1','22c30000-0000-0000-0000-0000000000e2','Leo','Lead','leo@example.com','lead', now()),
  ('22c30000-0000-0000-0000-00000000f003','22c30000-0000-0000-0000-0000000000a1',null,'Cia','Credit','cia@example.com','lead', now()),
  ('22c30000-0000-0000-0000-00000000f03b','22c30000-0000-0000-0000-0000000000a1',null,'Noa','Noshow','noa@example.com','lead', now()),
  ('22c30000-0000-0000-0000-00000000f03c','22c30000-0000-0000-0000-0000000000a1',null,'Ona','Ontime','ona@example.com','lead', now()),
  ('22c30000-0000-0000-0000-00000000f004','22c30000-0000-0000-0000-0000000000a1',null,'Exp','Pack','exp@example.com','active', now()),
  ('22c30000-0000-0000-0000-00000000f005','22c30000-0000-0000-0000-0000000000a1',null,'Fut','Pack','fut@example.com','active', now());

-- Host-with-plan holds an active unlimited membership (credits_remaining null).
insert into memberships (studio_id, member_id, plan_id, status, price_cents, currency, starts_on, credits_remaining, current_period_end) values
  ('22c30000-0000-0000-0000-0000000000a1','22c30000-0000-0000-0000-00000000f001','22c30000-0000-0000-0000-000000090001','active',500000,'CZK',current_date,null, now()+interval '20 days');
-- Sweep: a non-recurring pack, active, expired yesterday -> should expire.
insert into memberships (studio_id, member_id, plan_id, status, price_cents, currency, starts_on, credits_remaining, expires_on) values
  ('22c30000-0000-0000-0000-0000000000a1','22c30000-0000-0000-0000-00000000f004','22c30000-0000-0000-0000-000000090002','active',140000,'CZK',current_date-40, 2, (studio_today('22c30000-0000-0000-0000-0000000000a1') - 1)),
  ('22c30000-0000-0000-0000-0000000000a1','22c30000-0000-0000-0000-00000000f005','22c30000-0000-0000-0000-000000090002','active',140000,'CZK',current_date-10, 3, (studio_today('22c30000-0000-0000-0000-0000000000a1') + 1));

-- Occurrences.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               starts_at, ends_at, capacity, booked_count, status,
                               instructor_id, guarantee_tier, flex, minimum_bookings, committed_at) values
  -- GUEST: roomy, future, for book_guest.
  ('22c30000-0000-0000-0000-0000000c0001','22c30000-0000-0000-0000-0000000000a1','22c30000-0000-0000-0000-00000000000a','22c30000-0000-0000-0000-0000000c0001','22c30000-0000-0000-0000-0000000e0001','Guest Class', now()+interval '120 min', now()+interval '170 min',10,0,'scheduled', null,null,true,2,null),
  -- FLEX future (set_occurrence_always_runs on/off).
  ('22c30000-0000-0000-0000-0000000c0002','22c30000-0000-0000-0000-0000000000a1','22c30000-0000-0000-0000-00000000000a','22c30000-0000-0000-0000-0000000c0001','22c30000-0000-0000-0000-0000000e0002','Flex Future', now()+interval '300 min', now()+interval '350 min',8,1,'scheduled', null,null,true,2,null),
  -- STARTED flex (lock test).
  ('22c30000-0000-0000-0000-0000000c0003','22c30000-0000-0000-0000-0000000000a1','22c30000-0000-0000-0000-00000000000a','22c30000-0000-0000-0000-0000000c0001','22c30000-0000-0000-0000-0000000e0003','Flex Started', now()-interval '120 min', now()-interval '70 min',8,1,'scheduled', null,null,true,2,null),
  -- CREDIT (reservation credit on check-in).
  ('22c30000-0000-0000-0000-0000000c0004','22c30000-0000-0000-0000-0000000000a1','22c30000-0000-0000-0000-00000000000a','22c30000-0000-0000-0000-0000000c0001','22c30000-0000-0000-0000-0000000e0004','Credit Class', now()+interval '180 min', now()+interval '230 min',10,3,'scheduled', null,null,false,null,null),
  -- DIGEST: always-runs today, assigned to the login instructor.
  ('22c30000-0000-0000-0000-0000000c0005','22c30000-0000-0000-0000-0000000000a1','22c30000-0000-0000-0000-00000000000a','22c30000-0000-0000-0000-0000000c0001','22c30000-0000-0000-0000-0000000e0005','AlwaysClass', ((now() at time zone 'Europe/Prague')::date + time '14:00') at time zone 'Europe/Prague', ((now() at time zone 'Europe/Prague')::date + time '14:50') at time zone 'Europe/Prague',8,2,'scheduled','22c30000-0000-0000-0000-000000010001','always',false,null,null),
  -- DIGEST: flex pending today (uncommitted) -> NOT in Running.
  ('22c30000-0000-0000-0000-0000000c0006','22c30000-0000-0000-0000-0000000000a1','22c30000-0000-0000-0000-00000000000a','22c30000-0000-0000-0000-0000000c0001','22c30000-0000-0000-0000-0000000e0006','FlexPending', ((now() at time zone 'Europe/Prague')::date + time '15:00') at time zone 'Europe/Prague', ((now() at time zone 'Europe/Prague')::date + time '15:50') at time zone 'Europe/Prague',8,1,'scheduled','22c30000-0000-0000-0000-000000010001',null,true,2,null),
  -- DIGEST: committed flex today -> in Running (baseline unchanged).
  ('22c30000-0000-0000-0000-0000000c0007','22c30000-0000-0000-0000-0000000000a1','22c30000-0000-0000-0000-00000000000a','22c30000-0000-0000-0000-0000000c0001','22c30000-0000-0000-0000-0000000e0007','CommittedFlex', ((now() at time zone 'Europe/Prague')::date + time '16:00') at time zone 'Europe/Prague', ((now() at time zone 'Europe/Prague')::date + time '16:50') at time zone 'Europe/Prague',8,3,'scheduled','22c30000-0000-0000-0000-000000010001',null,true,2, now());
update class_occurrences set booked_at_cutoff = 3 where id = '22c30000-0000-0000-0000-0000000c0007';

-- Pre-book both hosts on the GUEST class (comp), so book_guest adds only the
-- guest seat and the plan gate is tested in isolation of the host's own booking.
insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source) values
  ('22c30000-0000-0000-0000-0000000000a1','22c30000-0000-0000-0000-0000000c0001','22c30000-0000-0000-0000-00000000f001','booked','member','comp'),
  ('22c30000-0000-0000-0000-0000000000a1','22c30000-0000-0000-0000-0000000c0001','22c30000-0000-0000-0000-00000000f002','booked','member','comp');
update class_occurrences set booked_count = 2 where id = '22c30000-0000-0000-0000-0000000c0001';

-- =============================================================================
-- 1. Decision 26(c): invite_needs_plan when the switch is on and no plan.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','22c30000-0000-0000-0000-0000000000e1',false);
select set_config('t.g_plan', (book_guest('22c30000-0000-0000-0000-0000000c0001','newguest1@example.com','New','One'))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_true('26c: host WITH a plan invites ok', (current_setting('t.g_plan')::jsonb->>'ok')::boolean);

set role authenticated; select set_config('request.jwt.claim.sub','22c30000-0000-0000-0000-0000000000e2',false);
select set_config('t.g_noplan', (book_guest('22c30000-0000-0000-0000-0000000c0001','newguest2@example.com','New','Two'))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_false('26c: host WITHOUT a plan is refused', (current_setting('t.g_noplan')::jsonb->>'ok')::boolean);
select expect_text('26c: the reason is invite_needs_plan', current_setting('t.g_noplan')::jsonb->>'reason', 'invite_needs_plan');
select expect_num('26c: no guest row created for the refused invite', (select count(*) from guest_passes
   where host_member_id = '22c30000-0000-0000-0000-00000000f002'), 0);

-- Switch OFF: the lead host can invite.
update studio_settings set guest_invites_members_only = false where studio_id = '22c30000-0000-0000-0000-0000000000a1';
set role authenticated; select set_config('request.jwt.claim.sub','22c30000-0000-0000-0000-0000000000e2',false);
select set_config('t.g_off', (book_guest('22c30000-0000-0000-0000-0000000c0001','newguest3@example.com','New','Three'))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_true('26c: switch off -> the lead host invites ok', (current_setting('t.g_off')::jsonb->>'ok')::boolean);

-- =============================================================================
-- 2. Decision 22 / 26(c): member_bootstrap flags.
-- =============================================================================
-- Switch back ON for the bootstrap flag test.
update studio_settings set guest_invites_members_only = true where studio_id = '22c30000-0000-0000-0000-0000000000a1';
set role authenticated; select set_config('request.jwt.claim.sub','22c30000-0000-0000-0000-0000000000e1',false);
select expect_true('bootstrap: guarantees_enabled true',
  (select guarantees_enabled from member_bootstrap('22c3-a')));
select expect_true('bootstrap: host WITH a plan can_invite_guest true',
  (select can_invite_guest from member_bootstrap('22c3-a')));
select set_config('request.jwt.claim.sub','22c30000-0000-0000-0000-0000000000e2',false);
select expect_false('bootstrap: lead host can_invite_guest false (switch on)',
  (select can_invite_guest from member_bootstrap('22c3-a')));
select set_config('request.jwt.claim.sub','',false); reset role;
-- Switch off -> lead host can invite.
update studio_settings set guest_invites_members_only = false where studio_id = '22c30000-0000-0000-0000-0000000000a1';
set role authenticated; select set_config('request.jwt.claim.sub','22c30000-0000-0000-0000-0000000000e2',false);
select expect_true('bootstrap: switch off -> lead host can_invite_guest true',
  (select can_invite_guest from member_bootstrap('22c3-a')));
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- 3. Decision 21: set_occurrence_always_runs.
-- =============================================================================
-- A non-manager is refused.
set role authenticated; select set_config('request.jwt.claim.sub','22c30000-0000-0000-0000-0000000000e9',false);
do $$ begin
  perform set_occurrence_always_runs('22c30000-0000-0000-0000-0000000c0002', true);
  raise exception 'FAIL  21: a non-manager was NOT refused';
exception when sqlstate 'PT403' then raise notice 'PASS  21: non-manager refused PT403';
end $$;
select set_config('request.jwt.claim.sub','',false); reset role;

-- An OWNER turns it ON: guarantee_tier -> always, flex/min kept.
set role authenticated; select set_config('request.jwt.claim.sub','22c30000-0000-0000-0000-0000000000ea',false);
select set_occurrence_always_runs('22c30000-0000-0000-0000-0000000c0002', true);
select expect_text('21: on -> guarantee_tier is always',
  (select guarantee_tier::text from class_occurrences where id = '22c30000-0000-0000-0000-0000000c0002'), 'always');
select expect_true('21: on -> flex flag untouched (still true)',
  (select flex from class_occurrences where id = '22c30000-0000-0000-0000-0000000c0002'));
select expect_num('21: on -> minimum_bookings untouched (still 2)',
  (select minimum_bookings from class_occurrences where id = '22c30000-0000-0000-0000-0000000c0002'), 2);
select expect_num('21: on -> one always_runs_set audit row',
  (select count(*) from audit_logs where entity_id = '22c30000-0000-0000-0000-0000000c0002' and action = 'occurrence.always_runs_set'), 1);
-- effective tier is now 'always' (occurrence_guarantee_run is service-only).
reset role;
select expect_text('21: occurrence_guarantee_run tier is always',
  (select tier::text from occurrence_guarantee_run('22c30000-0000-0000-0000-0000000c0002')), 'always');
set role authenticated; select set_config('request.jwt.claim.sub','22c30000-0000-0000-0000-0000000000ea',false);

-- Turn it OFF: guarantee_tier -> null, back to flex.
select set_occurrence_always_runs('22c30000-0000-0000-0000-0000000c0002', false);
select expect_true('21: off -> guarantee_tier is null',
  (select guarantee_tier is null from class_occurrences where id = '22c30000-0000-0000-0000-0000000c0002'));
select expect_num('21: off -> one always_runs_cleared audit row',
  (select count(*) from audit_logs where entity_id = '22c30000-0000-0000-0000-0000000c0002' and action = 'occurrence.always_runs_cleared'), 1);
reset role;
select expect_text('21: off -> effective tier back to flex',
  (select tier::text from occurrence_guarantee_run('22c30000-0000-0000-0000-0000000c0002')), 'flex');
set role authenticated; select set_config('request.jwt.claim.sub','22c30000-0000-0000-0000-0000000000ea',false);

-- Locked once the class has started (PT409).
do $$ begin
  perform set_occurrence_always_runs('22c30000-0000-0000-0000-0000000c0003', true);
  raise exception 'FAIL  21: a started class was NOT locked';
exception when sqlstate 'PT409' then raise notice 'PASS  21: started class locked PT409';
end $$;
-- Locked once committed (the committed digest class).
do $$ begin
  perform set_occurrence_always_runs('22c30000-0000-0000-0000-0000000c0007', true);
  raise exception 'FAIL  21: a committed class was NOT locked';
exception when sqlstate 'PT409' then raise notice 'PASS  21: committed class locked PT409';
end $$;
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- 4. Decision 21 build note: the digest lists an always-runs class under
--    Running the morning before, exactly as a core/committed class does.
-- =============================================================================
select set_config('t.dig', instructor_digest_block('22c30000-0000-0000-0000-0000000000a1',
  '22c30000-0000-0000-0000-000000010001', (now() at time zone 'Europe/Prague')::date)::text, false);
select expect_num('digest: two Running (always + committed), flex-pending excluded',
  (current_setting('t.dig')::jsonb->>'n_running')::bigint, 2);
select expect_true('digest: the always-runs class is in Running',
  (current_setting('t.dig')::jsonb->>'going_ahead_text') like '%AlwaysClass%');
select expect_true('digest: the committed flex class is in Running',
  (current_setting('t.dig')::jsonb->>'going_ahead_text') like '%CommittedFlex%');
select expect_false('digest: the uncommitted flex class is NOT in Running',
  (current_setting('t.dig')::jsonb->>'going_ahead_text') like '%FlexPending%');

-- =============================================================================
-- 5. Decision 103(b): the credit-back email on a check-in only.
-- =============================================================================
-- CIA: a comp free seat with a succeeded reservation fee. Checking in writes the
-- credit AND queues exactly one free_reservation_credited.
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source) values
  ('22c30000-0000-0000-0000-0000000b0001','22c30000-0000-0000-0000-0000000000a1','22c30000-0000-0000-0000-0000000c0004','22c30000-0000-0000-0000-00000000f003','booked','member','comp');
insert into payments (studio_id, member_id, booking_id, amount_cents, currency, status, kind) values
  ('22c30000-0000-0000-0000-0000000000a1','22c30000-0000-0000-0000-00000000f003','22c30000-0000-0000-0000-0000000b0001',15000,'CZK','succeeded','reservation_fee');
update bookings set status = 'attended' where id = '22c30000-0000-0000-0000-0000000b0001';
select expect_num('103b: attended -> one reservation credit', (select count(*) from member_credits
   where member_id = '22c30000-0000-0000-0000-00000000f003' and reason = 'reservation_credit'), 1);
select expect_num('103b: attended -> exactly one free_reservation_credited email',
  (select count(*) from notifications where member_id = '22c30000-0000-0000-0000-00000000f003'
     and template_key = 'free_reservation_credited'), 1);
select expect_true('103b: the email payload carries the fee and class name',
  (select payload->>'fee' is not null and payload->>'class_name' = 'Credit Class'
     from notifications where member_id = '22c30000-0000-0000-0000-00000000f003'
      and template_key = 'free_reservation_credited' limit 1));

-- NOA: a no-show writes no credit and queues no email.
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source) values
  ('22c30000-0000-0000-0000-0000000b003b','22c30000-0000-0000-0000-0000000000a1','22c30000-0000-0000-0000-0000000c0004','22c30000-0000-0000-0000-00000000f03b','booked','member','comp');
insert into payments (studio_id, member_id, booking_id, amount_cents, currency, status, kind) values
  ('22c30000-0000-0000-0000-0000000000a1','22c30000-0000-0000-0000-00000000f03b','22c30000-0000-0000-0000-0000000b003b',15000,'CZK','succeeded','reservation_fee');
update bookings set status = 'no_show' where id = '22c30000-0000-0000-0000-0000000b003b';
select expect_num('103b: no-show -> no reservation credit', (select count(*) from member_credits
   where member_id = '22c30000-0000-0000-0000-00000000f03b' and reason = 'reservation_credit'), 0);
select expect_num('103b: no-show -> no free_reservation_credited email',
  (select count(*) from notifications where member_id = '22c30000-0000-0000-0000-00000000f03b'
     and template_key = 'free_reservation_credited'), 0);

-- ONA: an on-time cancel writes the credit (Decision 103) but NO email (not a
-- check-in). This proves the attended-gate on the email.
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, free_cancel_until) values
  ('22c30000-0000-0000-0000-0000000b003c','22c30000-0000-0000-0000-0000000000a1','22c30000-0000-0000-0000-0000000c0004','22c30000-0000-0000-0000-00000000f03c','booked','member','comp', now()+interval '1 day');
insert into payments (studio_id, member_id, booking_id, amount_cents, currency, status, kind) values
  ('22c30000-0000-0000-0000-0000000000a1','22c30000-0000-0000-0000-00000000f03c','22c30000-0000-0000-0000-0000000b003c',15000,'CZK','succeeded','reservation_fee');
update bookings set status = 'cancelled' where id = '22c30000-0000-0000-0000-0000000b003c';
select expect_num('103b: on-time cancel -> credit written', (select count(*) from member_credits
   where member_id = '22c30000-0000-0000-0000-00000000f03c' and reason = 'reservation_credit'), 1);
select expect_num('103b: on-time cancel -> NO credit-back email (not a check-in)',
  (select count(*) from notifications where member_id = '22c30000-0000-0000-0000-00000000f03c'
     and template_key = 'free_reservation_credited'), 0);

-- =============================================================================
-- 6. Audit: the sweep expires a non-recurring membership past its validity date.
-- =============================================================================
select set_config('t.sweep', sweep_membership_periods()::text, false);
select expect_num('sweep: at least one non-recurring membership expired',
  (current_setting('t.sweep')::jsonb->>'non_recurring_expired')::bigint, 1);
select expect_text('sweep: the past-date pack is now expired',
  (select status::text from memberships where member_id = '22c30000-0000-0000-0000-00000000f004'), 'expired');
select expect_num('sweep: one membership_expired event',
  (select count(*) from membership_events where membership_id =
     (select id from memberships where member_id = '22c30000-0000-0000-0000-00000000f004')
     and type = 'membership_expired'), 1);
select expect_text('sweep: a pack still inside its validity stays active',
  (select status::text from memberships where member_id = '22c30000-0000-0000-0000-00000000f005'), 'active');

select 'ALL POOL 22c3 ASSERTIONS PASSED' as result;
