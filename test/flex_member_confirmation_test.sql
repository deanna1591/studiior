-- =============================================================================
-- Flex booking confirmation, member-facing — Decision 21 amendment (migration
-- 20260831970000). UUID space f1ec, checked free. Run after `supabase db reset`.
-- =============================================================================
-- A member who books a flex class that has not yet been decided is told "waiting
-- for confirmation by <deadline>", and told the outcome either way at the
-- deadline — NEVER why (no minimum, no headcount, no "not enough people"). The
-- language is always about THEIR booking. Core/always classes are unchanged.
--
--   1. member_pending_bookings / flex_deadline_for expose the deadline both ways
--      (hours_before AND previous_day_at); a core class is not pending.
--   2. the booking email is flex_booking_pending (not booking_confirmed) while
--      undecided; a core booking stays booking_confirmed.
--   3. the sweep commits a flex class -> flex_booking_confirmed, idempotent, and
--      the booking is no longer pending.
--   4. the sweep cancels for unmet_minimum -> flex_booking_not_confirmed (NOT
--      class_cancelled), the credit is restored, and {next_three} lists only
--      upcoming scheduled published classes with a free space.
--   5. a MANUAL studio_fault cancellation still uses class_cancelled.
--   6. another studio's member cannot read flex_deadline_for (PT403).
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
create or replace function expect_raise(label text, sql text, want_sqlstate text)
returns void language plpgsql as $$
begin
  execute sql;
  raise exception 'FAIL  %  expected % but nothing raised', label, want_sqlstate;
exception when others then
  if SQLSTATE = want_sqlstate then raise notice 'PASS  %  (raised %)', label, want_sqlstate;
  else raise exception 'FAIL  %  expected %, got % (%)', label, want_sqlstate, SQLSTATE, SQLERRM; end if;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('f1ecf1ec-0000-0000-0000-0000000000a1'),   -- owner P & Q & Z
  ('f1ecf1ec-0000-0000-0000-0000000000e1'),   -- P member M1 (unlimited)
  ('f1ecf1ec-0000-0000-0000-0000000000e2'),   -- P member M2 (class pack)
  ('f1ecf1ec-0000-0000-0000-0000000000e3'),   -- P member M3 (unlimited)
  ('f1ecf1ec-0000-0000-0000-0000000000f1'),   -- Q member MQ (unlimited)
  ('f1ecf1ec-0000-0000-0000-0000000000c1');   -- Z member MZ (unlimited)
insert into profiles (id, email) values
  ('f1ecf1ec-0000-0000-0000-0000000000a1','f1ec-owner@example.com'),
  ('f1ecf1ec-0000-0000-0000-0000000000e1','f1ec-m1@example.com'),
  ('f1ecf1ec-0000-0000-0000-0000000000e2','f1ec-m2@example.com'),
  ('f1ecf1ec-0000-0000-0000-0000000000e3','f1ec-m3@example.com'),
  ('f1ecf1ec-0000-0000-0000-0000000000f1','f1ec-mq@example.com'),
  ('f1ecf1ec-0000-0000-0000-0000000000c1','f1ec-mz@example.com');

insert into studios (id, name, slug, timezone, currency, status) values
  ('f1ecf1ec-0000-0000-0000-000000000001','Flex P','f1ec-p','Europe/Prague','CZK','active'),
  ('f1ecf1ec-0000-0000-0000-000000000002','Flex Q','f1ec-q','Asia/Manila','PHP','active'),
  ('f1ecf1ec-0000-0000-0000-000000000003','Flex Z','f1ec-z','Europe/Prague','CZK','active');

-- P: hours_before with a huge window, so every class in the next week is ALREADY
--    past its cutoff and evaluable — the sweep/confirm/cancel studio.
-- Q: previous_day_at 20:00 — the other deadline shape, for the pending copy.
-- Publication OFF on all three (month_published -> true), so booking is not
-- gated by publication; the published clause of {next_three} is proved in the
-- publication-ON block at the end.
insert into studio_settings (studio_id, flex_enabled, flex_deadline_mode, flex_deadline_time, flex_deadline_hours) values
  ('f1ecf1ec-0000-0000-0000-000000000001', true, 'hours_before',    '20:00', 168),
  ('f1ecf1ec-0000-0000-0000-000000000002', true, 'previous_day_at', '20:00', 168),
  ('f1ecf1ec-0000-0000-0000-000000000003', true, 'hours_before',    '20:00', 168);

insert into locations (id, studio_id, name, is_primary) values
  ('f1ecf1ec-0000-0000-0000-0000000000a0','f1ecf1ec-0000-0000-0000-000000000001','Main',true),
  ('f1ecf1ec-0000-0000-0000-0000000000b0','f1ecf1ec-0000-0000-0000-000000000002','Main',true),
  ('f1ecf1ec-0000-0000-0000-0000000000c0','f1ecf1ec-0000-0000-0000-000000000003','Main',true);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('f1ecf1ec-0000-0000-0000-0000000aa001','f1ecf1ec-0000-0000-0000-000000000001','f1ecf1ec-0000-0000-0000-0000000000a1','f1ec-owner@example.com','owner'),
  ('f1ecf1ec-0000-0000-0000-0000000bb001','f1ecf1ec-0000-0000-0000-000000000002','f1ecf1ec-0000-0000-0000-0000000000a1','f1ec-owner-q@example.com','owner'),
  ('f1ecf1ec-0000-0000-0000-0000000cc001','f1ecf1ec-0000-0000-0000-000000000003','f1ecf1ec-0000-0000-0000-0000000000a1','f1ec-owner-z@example.com','owner');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('f1ecf1ec-0000-0000-0000-000000ee0001','f1ecf1ec-0000-0000-0000-000000000001','f1ecf1ec-0000-0000-0000-0000000000a0','R1',10),
  ('f1ecf1ec-0000-0000-0000-000000ee0002','f1ecf1ec-0000-0000-0000-000000000002','f1ecf1ec-0000-0000-0000-0000000000b0','R1',10),
  ('f1ecf1ec-0000-0000-0000-000000ee0003','f1ecf1ec-0000-0000-0000-000000000003','f1ecf1ec-0000-0000-0000-0000000000c0','R1',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('f1ecf1ec-0000-0000-0000-000000cc0001','f1ecf1ec-0000-0000-0000-000000000001','Reformer',50,10),
  ('f1ecf1ec-0000-0000-0000-000000cc0002','f1ecf1ec-0000-0000-0000-000000000002','Mat',50,10),
  ('f1ecf1ec-0000-0000-0000-000000cc0003','f1ecf1ec-0000-0000-0000-000000000003','Reformer',50,10);

insert into members (id, studio_id, user_id, first_name, last_name, email, joined_on, status, waiver_signed_at) values
  ('f1ecf1ec-0000-0000-0000-000000dd0001','f1ecf1ec-0000-0000-0000-000000000001','f1ecf1ec-0000-0000-0000-0000000000e1','M','One','f1ec-m1@example.com', current_date-30,'active', now()),
  ('f1ecf1ec-0000-0000-0000-000000dd0002','f1ecf1ec-0000-0000-0000-000000000001','f1ecf1ec-0000-0000-0000-0000000000e2','M','Two','f1ec-m2@example.com', current_date-30,'active', now()),
  ('f1ecf1ec-0000-0000-0000-000000dd0003','f1ecf1ec-0000-0000-0000-000000000001','f1ecf1ec-0000-0000-0000-0000000000e3','M','Three','f1ec-m3@example.com', current_date-30,'active', now()),
  ('f1ecf1ec-0000-0000-0000-000000dd00f1','f1ecf1ec-0000-0000-0000-000000000002','f1ecf1ec-0000-0000-0000-0000000000f1','M','Q','f1ec-mq@example.com', current_date-30,'active', now()),
  ('f1ecf1ec-0000-0000-0000-000000dd00c1','f1ecf1ec-0000-0000-0000-000000000003','f1ecf1ec-0000-0000-0000-0000000000c1','M','Z','f1ec-mz@example.com', current_date-30,'active', now());

insert into membership_plans (id, studio_id, name, type, price_cents, currency, billing_interval, credits, credits_per_period, status) values
  ('f1ecf1ec-0000-0000-0000-0000000c0001','f1ecf1ec-0000-0000-0000-000000000001','Unlimited','recurring',250000,'CZK','month',null,null,'active'),
  ('f1ecf1ec-0000-0000-0000-0000000c0002','f1ecf1ec-0000-0000-0000-000000000001','5-Class Pack','class_pack',500000,'CZK',null,5,null,'active'),
  ('f1ecf1ec-0000-0000-0000-0000000c00f2','f1ecf1ec-0000-0000-0000-000000000002','Unlimited','recurring',250000,'PHP','month',null,null,'active'),
  ('f1ecf1ec-0000-0000-0000-0000000c00c2','f1ecf1ec-0000-0000-0000-000000000003','Unlimited','recurring',250000,'CZK','month',null,null,'active');
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on, credits_remaining, expires_on) values
  ('f1ecf1ec-0000-0000-0000-0000000c1001','f1ecf1ec-0000-0000-0000-000000000001','f1ecf1ec-0000-0000-0000-000000dd0001','f1ecf1ec-0000-0000-0000-0000000c0001','active',250000,'CZK',current_date-30,null,null),
  ('f1ecf1ec-0000-0000-0000-0000000c1002','f1ecf1ec-0000-0000-0000-000000000001','f1ecf1ec-0000-0000-0000-000000dd0002','f1ecf1ec-0000-0000-0000-0000000c0002','active',500000,'CZK',current_date-30,5,current_date+60),
  ('f1ecf1ec-0000-0000-0000-0000000c1003','f1ecf1ec-0000-0000-0000-000000000001','f1ecf1ec-0000-0000-0000-000000dd0003','f1ecf1ec-0000-0000-0000-0000000c0001','active',250000,'CZK',current_date-30,null,null),
  ('f1ecf1ec-0000-0000-0000-0000000c10f1','f1ecf1ec-0000-0000-0000-000000000002','f1ecf1ec-0000-0000-0000-000000dd00f1','f1ecf1ec-0000-0000-0000-0000000c00f2','active',250000,'PHP',current_date-30,null,null),
  ('f1ecf1ec-0000-0000-0000-0000000c10c1','f1ecf1ec-0000-0000-0000-000000000003','f1ecf1ec-0000-0000-0000-000000dd00c1','f1ecf1ec-0000-0000-0000-0000000c00c2','active',250000,'CZK',current_date-30,null,null);

-- Studio P classes. hours_before 200 => every one below is past its cutoff.
insert into class_occurrences
  (id, studio_id, location_id, class_type_id, room_id, name, capacity, instructor_id,
   starts_at, ends_at, status, staffing, flex, minimum_bookings)
values
  -- CAND_OK1 (+1d): scheduled, space, published -> a {next_three} candidate.
  ('f1ecf1ec-0000-0000-0000-0000000c0101','f1ecf1ec-0000-0000-0000-000000000001','f1ecf1ec-0000-0000-0000-0000000000a0',
   'f1ecf1ec-0000-0000-0000-000000cc0001','f1ecf1ec-0000-0000-0000-000000ee0001','Cand Open One',10,null,
   ((current_date+1)+time '09:00') at time zone 'Europe/Prague', ((current_date+1)+time '09:50') at time zone 'Europe/Prague','scheduled','open',false,1),
  -- CAND_FULL (+2d): capacity 1, will be filled -> excluded from {next_three}.
  ('f1ecf1ec-0000-0000-0000-0000000c0102','f1ecf1ec-0000-0000-0000-000000000001','f1ecf1ec-0000-0000-0000-0000000000a0',
   'f1ecf1ec-0000-0000-0000-000000cc0001','f1ecf1ec-0000-0000-0000-000000ee0001','Cand Full',1,null,
   ((current_date+2)+time '09:00') at time zone 'Europe/Prague', ((current_date+2)+time '09:50') at time zone 'Europe/Prague','scheduled','open',false,1),
  -- CAND_OK2 (+3d): scheduled, space, published -> a {next_three} candidate.
  ('f1ecf1ec-0000-0000-0000-0000000c0103','f1ecf1ec-0000-0000-0000-000000000001','f1ecf1ec-0000-0000-0000-0000000000a0',
   'f1ecf1ec-0000-0000-0000-000000cc0001','f1ecf1ec-0000-0000-0000-000000ee0001','Cand Open Two',10,null,
   ((current_date+3)+time '09:00') at time zone 'Europe/Prague', ((current_date+3)+time '09:50') at time zone 'Europe/Prague','scheduled','open',false,1),
  -- F_CONFIRM (+4d): flex min 1, one booking -> commits.
  ('f1ecf1ec-0000-0000-0000-0000000c0111','f1ecf1ec-0000-0000-0000-000000000001','f1ecf1ec-0000-0000-0000-0000000000a0',
   'f1ecf1ec-0000-0000-0000-000000cc0001','f1ecf1ec-0000-0000-0000-000000ee0001','Reformer Confirm',10,null,
   ((current_date+4)+time '08:00') at time zone 'Europe/Prague', ((current_date+4)+time '08:50') at time zone 'Europe/Prague','scheduled','open',true,1),
  -- F_FAIL (+5d): flex min 2, one booking -> not running.
  ('f1ecf1ec-0000-0000-0000-0000000c0112','f1ecf1ec-0000-0000-0000-000000000001','f1ecf1ec-0000-0000-0000-0000000000a0',
   'f1ecf1ec-0000-0000-0000-000000cc0001','f1ecf1ec-0000-0000-0000-000000ee0001','Reformer Shortfall',10,null,
   ((current_date+5)+time '08:00') at time zone 'Europe/Prague', ((current_date+5)+time '08:50') at time zone 'Europe/Prague','scheduled','open',true,2),
  -- F_MANUAL (+6d): flex, one booking -> a MANUAL studio_fault cancellation.
  ('f1ecf1ec-0000-0000-0000-0000000c0113','f1ecf1ec-0000-0000-0000-000000000001','f1ecf1ec-0000-0000-0000-0000000000a0',
   'f1ecf1ec-0000-0000-0000-000000cc0001','f1ecf1ec-0000-0000-0000-000000ee0001','Reformer Manual',10,null,
   ((current_date+6)+time '08:00') at time zone 'Europe/Prague', ((current_date+6)+time '08:50') at time zone 'Europe/Prague','scheduled','open',true,1),
  -- F_CORE (+7d): NOT flex -> never pending, booking is an ordinary receipt.
  ('f1ecf1ec-0000-0000-0000-0000000c0114','f1ecf1ec-0000-0000-0000-000000000001','f1ecf1ec-0000-0000-0000-0000000000a0',
   'f1ecf1ec-0000-0000-0000-000000cc0001','f1ecf1ec-0000-0000-0000-000000ee0001','Reformer Core',10,null,
   ((current_date+7)+time '08:00') at time zone 'Europe/Prague', ((current_date+7)+time '08:50') at time zone 'Europe/Prague','scheduled','open',false,1);

-- Studio Q class: previous_day_at deadline, kept UNDECIDED (never swept).
insert into class_occurrences
  (id, studio_id, location_id, class_type_id, room_id, name, capacity, instructor_id,
   starts_at, ends_at, status, staffing, flex, minimum_bookings)
values
  ('f1ecf1ec-0000-0000-0000-0000000c0201','f1ecf1ec-0000-0000-0000-000000000002','f1ecf1ec-0000-0000-0000-0000000000b0',
   'f1ecf1ec-0000-0000-0000-000000cc0002','f1ecf1ec-0000-0000-0000-000000ee0002','Mat Pending',10,null,
   ((current_date+3)+time '07:00') at time zone 'Asia/Manila', ((current_date+3)+time '07:50') at time zone 'Asia/Manila','scheduled','open',true,1);

-- =============================================================================
-- 1. BOOKINGS + THE PENDING RECEIPT (the email branch)
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','f1ecf1ec-0000-0000-0000-0000000000e1',false);  -- M1
select expect_text('M1 books the flex class that will confirm',
  (book_class('f1ecf1ec-0000-0000-0000-0000000c0111','f1ecf1ec-0000-0000-0000-000000dd0001','member')).status::text, 'booked');
select expect_text('M1 books the flex class that will be MANUALLY cancelled',
  (book_class('f1ecf1ec-0000-0000-0000-0000000c0113','f1ecf1ec-0000-0000-0000-000000dd0001','member')).status::text, 'booked');
select set_config('request.jwt.claim.sub','f1ecf1ec-0000-0000-0000-0000000000e2',false);  -- M2 (pack)
select expect_text('M2 books the flex class that will NOT confirm',
  (book_class('f1ecf1ec-0000-0000-0000-0000000c0112','f1ecf1ec-0000-0000-0000-000000dd0002','member')).status::text, 'booked');
select set_config('request.jwt.claim.sub','f1ecf1ec-0000-0000-0000-0000000000e3',false);  -- M3
select expect_text('M3 fills the capacity-1 candidate (so it is FULL)',
  (book_class('f1ecf1ec-0000-0000-0000-0000000c0102','f1ecf1ec-0000-0000-0000-000000dd0003','member')).status::text, 'booked');
select expect_text('M3 books the CORE class',
  (book_class('f1ecf1ec-0000-0000-0000-0000000c0114','f1ecf1ec-0000-0000-0000-000000dd0003','member')).status::text, 'booked');
reset role;

select expect_num('a flex booking gets a PENDING receipt, not a confirmation',
  (select count(*) from notifications where template_key='flex_booking_pending'
     and member_id='f1ecf1ec-0000-0000-0000-000000dd0001'
     and payload->>'class_name'='Reformer Confirm'), 1);
select expect_num('...and NOT booking_confirmed for that flex booking',
  (select count(*) from notifications where template_key='booking_confirmed'
     and member_id='f1ecf1ec-0000-0000-0000-000000dd0001'
     and payload->>'class_name'='Reformer Confirm'), 0);
select expect_num('a CORE booking gets an ordinary booking_confirmed',
  (select count(*) from notifications where template_key='booking_confirmed'
     and member_id='f1ecf1ec-0000-0000-0000-000000dd0003'
     and payload->>'class_name'='Reformer Core'), 1);
select expect_num('...and no pending receipt for the core booking',
  (select count(*) from notifications where template_key='flex_booking_pending'
     and member_id='f1ecf1ec-0000-0000-0000-000000dd0003'
     and payload->>'class_name'='Reformer Core'), 0);

-- =============================================================================
-- 2. member_pending_bookings / flex_deadline_for — BOTH modes, core false
-- =============================================================================
-- The expected cutoffs, captured as the DB owner (occurrence_guarantee_run is
-- internal — a member cannot call it, which is the point of flex_deadline_for).
select set_config('t.cut_confirm',
  (select cutoff_at::text from occurrence_guarantee_run('f1ecf1ec-0000-0000-0000-0000000c0111')), false);
select set_config('t.cut_q',
  (select cutoff_at::text from occurrence_guarantee_run('f1ecf1ec-0000-0000-0000-0000000c0201')), false);

set role authenticated;
select set_config('request.jwt.claim.sub','f1ecf1ec-0000-0000-0000-0000000000e1',false);  -- M1
select expect_true('M1''s flex booking is pending, with the cutoff as pending_until',
  (select pending_until = current_setting('t.cut_confirm')::timestamptz
     from member_pending_bookings('f1ecf1ec-0000-0000-0000-000000000001')
    where occurrence_id='f1ecf1ec-0000-0000-0000-0000000c0111'));
select expect_text('flex_deadline_for reports the hours_before mode',
  (select mode from flex_deadline_for('f1ecf1ec-0000-0000-0000-0000000c0111')), 'hours_before');
-- The guard admits a member reading a bookable class they have not booked (no
-- PT403); CAND_OK2 is non-flex, so the answer is simply 'none' rather than a raise.
select expect_text('a member may read a bookable class they have NOT booked (no PT403)',
  (select mode from flex_deadline_for('f1ecf1ec-0000-0000-0000-0000000c0103')), 'none');

select set_config('request.jwt.claim.sub','f1ecf1ec-0000-0000-0000-0000000000e3',false);  -- M3
select expect_num('a CORE booking is NOT pending',
  (select count(*) from member_pending_bookings('f1ecf1ec-0000-0000-0000-000000000001')
     where occurrence_id='f1ecf1ec-0000-0000-0000-0000000c0114'), 0);
select expect_text('flex_deadline_for on a core class is (none)',
  (select mode from flex_deadline_for('f1ecf1ec-0000-0000-0000-0000000c0114')), 'none');
reset role;

-- Studio Q — the previous_day_at deadline shape.
set role authenticated;
select set_config('request.jwt.claim.sub','f1ecf1ec-0000-0000-0000-0000000000f1',false);  -- MQ
select expect_text('MQ books the pending Q class',
  (book_class('f1ecf1ec-0000-0000-0000-0000000c0201','f1ecf1ec-0000-0000-0000-000000dd00f1','member')).status::text, 'booked');
select expect_text('...its deadline mode is previous_day_at',
  (select mode from flex_deadline_for('f1ecf1ec-0000-0000-0000-0000000c0201')), 'previous_day_at');
select expect_true('...and MQ''s booking is pending with the night-before cutoff',
  (select pending_until = current_setting('t.cut_q')::timestamptz
     from member_pending_bookings('f1ecf1ec-0000-0000-0000-000000000002')
    where occurrence_id='f1ecf1ec-0000-0000-0000-0000000c0201'));
reset role;

-- =============================================================================
-- 3. PT403 — another studio's member cannot read the deadline
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','f1ecf1ec-0000-0000-0000-0000000000c1',false);  -- MZ (studio Z)
select expect_raise('MZ cannot read studio P''s flex deadline',
  $$select * from flex_deadline_for('f1ecf1ec-0000-0000-0000-0000000c0111')$$, 'PT403');
reset role;

-- =============================================================================
-- 4. THE SWEEP CONFIRMS — flex_booking_confirmed, idempotent
-- =============================================================================
select set_config('t.c1', (select evaluate_commitment('f1ecf1ec-0000-0000-0000-0000000c0111')::text), false);
select expect_text('F_CONFIRM committed', current_setting('t.c1')::jsonb ->> 'decision', 'committed');
set role authenticated;
select set_config('request.jwt.claim.sub','f1ecf1ec-0000-0000-0000-0000000000e1',false);  -- M1
select expect_true('...and it is no longer pending for M1',
  (select count(*) = 0 from member_pending_bookings('f1ecf1ec-0000-0000-0000-000000000001')
     where occurrence_id='f1ecf1ec-0000-0000-0000-0000000c0111'));
reset role;
select expect_num('...M1 was told it is confirmed',
  (select count(*) from notifications where template_key='flex_booking_confirmed'
     and member_id='f1ecf1ec-0000-0000-0000-000000dd0001'
     and payload->>'class_name'='Reformer Confirm'), 1);
-- Re-evaluating is a no-op (already committed) and cannot send a second one.
select evaluate_commitment('f1ecf1ec-0000-0000-0000-0000000c0111');
select expect_num('...a second evaluation sends no second confirmation (idempotent)',
  (select count(*) from notifications where template_key='flex_booking_confirmed'
     and member_id='f1ecf1ec-0000-0000-0000-000000dd0001'
     and payload->>'class_name'='Reformer Confirm'), 1);

-- =============================================================================
-- 5. THE SWEEP CANCELS (unmet_minimum) — flex_booking_not_confirmed, credit back
-- =============================================================================
select expect_num('M2''s pack has one credit spent before the cancellation',
  (select credits_remaining from memberships where id='f1ecf1ec-0000-0000-0000-0000000c1002')::bigint, 4);
select set_config('t.c2', (select evaluate_commitment('f1ecf1ec-0000-0000-0000-0000000c0112')::text), false);
select expect_text('the unmet-minimum class is not running', current_setting('t.c2')::jsonb ->> 'decision', 'not_running');
select expect_text('...cancelled for unmet_minimum',
  (select status||'/'||coalesce(cancellation_cause::text,'') from class_occurrences where id='f1ecf1ec-0000-0000-0000-0000000c0112'),
  'cancelled/unmet_minimum');
select expect_num('M2 is told the BOOKING was not confirmed (flex_booking_not_confirmed)',
  (select count(*) from notifications where template_key='flex_booking_not_confirmed'
     and member_id='f1ecf1ec-0000-0000-0000-000000dd0002'
     and payload->>'class_name'='Reformer Shortfall'), 1);
select expect_num('...and NOT class_cancelled (the amendment)',
  (select count(*) from notifications where template_key='class_cancelled'
     and member_id='f1ecf1ec-0000-0000-0000-000000dd0002'
     and payload->>'class_name'='Reformer Shortfall'), 0);
select expect_num('...the credit is back on M2''s pack',
  (select credits_remaining from memberships where id='f1ecf1ec-0000-0000-0000-0000000c1002')::bigint, 5);
select expect_num('...nobody was marked a late cancellation for the studio''s decision',
  (select count(*) from bookings where occurrence_id='f1ecf1ec-0000-0000-0000-0000000c0112' and is_late_cancel)::bigint, 0);

-- {next_three}: only upcoming, scheduled, published, with a free space.
select set_config('t.n3', (select payload->>'next_three_line' from notifications
   where template_key='flex_booking_not_confirmed' and member_id='f1ecf1ec-0000-0000-0000-000000dd0002' limit 1), false);
select expect_true('{next_three} lists a class WITH space (Cand Open One)',
  current_setting('t.n3') like '%Cand Open One%');
select expect_true('{next_three} lists the other class with space (Cand Open Two)',
  current_setting('t.n3') like '%Cand Open Two%');
select expect_false('{next_three} does NOT list the FULL candidate',
  current_setting('t.n3') like '%Cand Full%');

-- =============================================================================
-- 6. A MANUAL studio_fault CANCELLATION STILL USES class_cancelled
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','f1ecf1ec-0000-0000-0000-0000000000a1',false);  -- owner
select cancel_occurrence('f1ecf1ec-0000-0000-0000-0000000c0113', 'Instructor off sick', 'studio_fault');
reset role;
select expect_num('a studio_fault cancellation tells the member class_cancelled',
  (select count(*) from notifications where template_key='class_cancelled'
     and member_id='f1ecf1ec-0000-0000-0000-000000dd0001'
     and payload->>'class_name'='Reformer Manual'), 1);
select expect_num('...and NOT flex_booking_not_confirmed (only unmet_minimum is)',
  (select count(*) from notifications where template_key='flex_booking_not_confirmed'
     and member_id='f1ecf1ec-0000-0000-0000-000000dd0001'
     and payload->>'class_name'='Reformer Manual'), 0);

-- =============================================================================
-- 7. THE PUBLISHED CLAUSE OF {next_three} — a draft-month class is excluded
-- =============================================================================
-- Studio Z uses publication. Publish the month F_FAIL_Z and its published
-- candidate fall in; leave a far-future candidate's month a draft.
update studio_settings set publication_enabled = true where studio_id='f1ecf1ec-0000-0000-0000-000000000003';
select set_config('t.pz', (select publish_month('f1ecf1ec-0000-0000-0000-000000000003', date_trunc('month', current_date)::date)::text), false);
select publish_month('f1ecf1ec-0000-0000-0000-000000000003', date_trunc('month', current_date + 5)::date);

insert into class_occurrences
  (id, studio_id, location_id, class_type_id, room_id, name, capacity, instructor_id,
   starts_at, ends_at, status, staffing, flex, minimum_bookings)
values
  -- Z candidate in a PUBLISHED month, with space.
  ('f1ecf1ec-0000-0000-0000-0000000c0301','f1ecf1ec-0000-0000-0000-000000000003','f1ecf1ec-0000-0000-0000-0000000000c0',
   'f1ecf1ec-0000-0000-0000-000000cc0003','f1ecf1ec-0000-0000-0000-000000ee0003','Z Published Open',10,null,
   ((current_date+2)+time '09:00') at time zone 'Europe/Prague', ((current_date+2)+time '09:50') at time zone 'Europe/Prague','scheduled','open',false,1),
  -- Z candidate in a DRAFT month (~2 months out), with space -> must be excluded.
  ('f1ecf1ec-0000-0000-0000-0000000c0302','f1ecf1ec-0000-0000-0000-000000000003','f1ecf1ec-0000-0000-0000-0000000000c0',
   'f1ecf1ec-0000-0000-0000-000000cc0003','f1ecf1ec-0000-0000-0000-000000ee0003','Z Draft Open',10,null,
   ((current_date+62)+time '09:00') at time zone 'Europe/Prague', ((current_date+62)+time '09:50') at time zone 'Europe/Prague','scheduled','open',false,1),
  -- Z flex class that will fail (min 2, one booking), in the published month.
  ('f1ecf1ec-0000-0000-0000-0000000c0311','f1ecf1ec-0000-0000-0000-000000000003','f1ecf1ec-0000-0000-0000-0000000000c0',
   'f1ecf1ec-0000-0000-0000-000000cc0003','f1ecf1ec-0000-0000-0000-000000ee0003','Z Shortfall',10,null,
   ((current_date+4)+time '08:00') at time zone 'Europe/Prague', ((current_date+4)+time '08:50') at time zone 'Europe/Prague','scheduled','open',true,2);

set role authenticated;
select set_config('request.jwt.claim.sub','f1ecf1ec-0000-0000-0000-0000000000c1',false);  -- MZ
select expect_text('MZ books the Z flex class that will be cut',
  (book_class('f1ecf1ec-0000-0000-0000-0000000c0311','f1ecf1ec-0000-0000-0000-000000dd00c1','member')).status::text, 'booked');
reset role;
select evaluate_commitment('f1ecf1ec-0000-0000-0000-0000000c0311');
select set_config('t.zn3', (select payload->>'next_three_line' from notifications
   where template_key='flex_booking_not_confirmed' and member_id='f1ecf1ec-0000-0000-0000-000000dd00c1' limit 1), false);
select expect_true('{next_three} lists the PUBLISHED-month class',
  current_setting('t.zn3') like '%Z Published Open%');
select expect_false('{next_three} does NOT list the DRAFT-month class',
  current_setting('t.zn3') like '%Z Draft Open%');

-- Clean up so this suite leaves no global state (the sweeps and the notification
-- queue would otherwise inflate a later suite's unscoped counts).
update studio_settings set flex_enabled = false, publication_enabled = false
 where studio_id in ('f1ecf1ec-0000-0000-0000-000000000001','f1ecf1ec-0000-0000-0000-000000000002','f1ecf1ec-0000-0000-0000-000000000003');
delete from notifications
 where studio_id in ('f1ecf1ec-0000-0000-0000-000000000001','f1ecf1ec-0000-0000-0000-000000000002','f1ecf1ec-0000-0000-0000-000000000003');

select 'flex member confirmation suite finished' as done;
