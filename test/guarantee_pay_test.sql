-- =============================================================================
-- Decision 22 — guarantee tiers, cutoff evaluation and instructor pay
-- Migrations 079-084. UUID space 9a17, checked free.
-- =============================================================================
-- The acceptance list this suite exists to hold, in order, plus the four teeth
-- checks that prove the assertions can fail.
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
create or replace function expect_raises(label text, stmt text, want_sqlstate text)
returns void language plpgsql as $$
begin
  execute stmt;
  raise exception 'FAIL  %  expected % but nothing was raised', label, want_sqlstate;
exception when others then
  if sqlstate = want_sqlstate then raise notice 'PASS  %  (got %)', label, sqlstate;
  elsif sqlstate = 'P0001' and sqlerrm like 'FAIL%' then raise;
  else raise exception 'FAIL  %  expected %, got % (%)', label, want_sqlstate, sqlstate, sqlerrm; end if;
end $$;

-- --- Fixtures ---------------------------------------------------------------
-- TWO STUDIOS IN DIFFERENT ZONES with different tiers, cutoffs and rates, run
-- through one sweep. A fixture where both share a zone and a setting tests
-- nothing about either being per studio.
insert into auth.users (id) values
  ('9a179a17-0000-0000-0000-0000000000a1'),
  ('9a179a17-0000-0000-0000-0000000000a2'),
  ('9a179a17-0000-0000-0000-0000000000a3'),
  ('9a179a17-0000-0000-0000-0000000000a4');
insert into profiles (id, email, full_name) values
  ('9a179a17-0000-0000-0000-0000000000a1','gp-owner-a@example.com','Ana Owner'),
  ('9a179a17-0000-0000-0000-0000000000a2','gp-owner-b@example.com','Ben Owner'),
  ('9a179a17-0000-0000-0000-0000000000a3','gp-coach-a@example.com','Cara Coach'),
  ('9a179a17-0000-0000-0000-0000000000a4','gp-coach-b@example.com','Dev Coach');

insert into studios (id, name, slug, timezone, currency, status) values
  ('9a179a17-0000-0000-0000-000000000001','Prague Pay','gp-prague','Europe/Prague','CZK','active'),
  ('9a179a17-0000-0000-0000-000000000002','Manila Pay','gp-manila','Asia/Manila','PHP','active');
insert into studio_settings (studio_id, occurrence_horizon_days) values
  ('9a179a17-0000-0000-0000-000000000001', 365),
  ('9a179a17-0000-0000-0000-000000000002', 365);
insert into locations (id, studio_id, name, is_primary) values
  ('9a179a17-0000-0000-0000-00000000000c','9a179a17-0000-0000-0000-000000000001','Main',true),
  ('9a179a17-0000-0000-0000-00000000000d','9a179a17-0000-0000-0000-000000000002','Main',true);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('9a179a17-0000-0000-0000-0000000055a1','9a179a17-0000-0000-0000-000000000001','9a179a17-0000-0000-0000-0000000000a1','gp-owner-a@example.com','owner'),
  ('9a179a17-0000-0000-0000-0000000055a2','9a179a17-0000-0000-0000-000000000002','9a179a17-0000-0000-0000-0000000000a2','gp-owner-b@example.com','owner'),
  ('9a179a17-0000-0000-0000-0000000055a3','9a179a17-0000-0000-0000-000000000001','9a179a17-0000-0000-0000-0000000000a3','gp-coach-a@example.com','instructor'),
  ('9a179a17-0000-0000-0000-0000000055a4','9a179a17-0000-0000-0000-000000000002','9a179a17-0000-0000-0000-0000000000a4','gp-coach-b@example.com','instructor');
insert into instructors (id, studio_id, staff_id, display_name) values
  ('9a179a17-0000-0000-0000-00000000d101','9a179a17-0000-0000-0000-000000000001','9a179a17-0000-0000-0000-0000000055a3','Cara Coach'),
  ('9a179a17-0000-0000-0000-00000000d102','9a179a17-0000-0000-0000-000000000002','9a179a17-0000-0000-0000-0000000055a4','Dev Coach');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('9a179a17-0000-0000-0000-00000000ee01','9a179a17-0000-0000-0000-000000000001','9a179a17-0000-0000-0000-00000000000c','Six',6),
  ('9a179a17-0000-0000-0000-00000000ee02','9a179a17-0000-0000-0000-000000000001','9a179a17-0000-0000-0000-00000000000c','Five',5),
  ('9a179a17-0000-0000-0000-00000000ee03','9a179a17-0000-0000-0000-000000000002','9a179a17-0000-0000-0000-00000000000d','Main',8);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity, session_kind) values
  ('9a179a17-0000-0000-0000-00000000cc01','9a179a17-0000-0000-0000-000000000001','Group',50,6,'group'),
  ('9a179a17-0000-0000-0000-00000000cc02','9a179a17-0000-0000-0000-000000000001','Private 1-on-1',50,1,'private'),
  ('9a179a17-0000-0000-0000-00000000cc03','9a179a17-0000-0000-0000-000000000002','Group MNL',50,8,'group');
insert into members (id, studio_id, first_name, last_name, email, status) values
  ('9a179a17-0000-0000-0000-0000000b1001','9a179a17-0000-0000-0000-000000000001','Mara','One','gp-m1@example.com','active'),
  ('9a179a17-0000-0000-0000-0000000b1002','9a179a17-0000-0000-0000-000000000001','Nils','Two','gp-m2@example.com','active'),
  ('9a179a17-0000-0000-0000-0000000b1003','9a179a17-0000-0000-0000-000000000001','Ola','Three','gp-m3@example.com','active'),
  ('9a179a17-0000-0000-0000-0000000b2001','9a179a17-0000-0000-0000-000000000002','Pia','Four','gp-m4@example.com','active');

-- Different tiers, different cutoffs, different rates.
update studio_settings set
  guarantees_enabled = true, core_min_bookings = 1, core_cutoff_hours = 12,
  core_unmet_pay_pct = 50, flex_enabled = true, flex_min_bookings = 2,
  flex_deadline_mode = 'previous_day_at', flex_deadline_time = '20:00',
  flex_unmet_pay_cents = 0, flex_standby_pay_cents = 15000, adjacency_minutes = 90
 where studio_id = '9a179a17-0000-0000-0000-000000000001';
update studio_settings set
  guarantees_enabled = true, core_min_bookings = 3, core_cutoff_hours = 2,
  core_unmet_pay_pct = 25, flex_enabled = false
 where studio_id = '9a179a17-0000-0000-0000-000000000002';

select set_config('request.jwt.claim.sub','9a179a17-0000-0000-0000-0000000000a1',false);
set role authenticated;
select set_instructor_rate('9a179a17-0000-0000-0000-00000000d101', current_date - 60,
  80000, 7500, 2, 20000, 150000, 200000, 250000, 'senior');
reset role;
select set_config('request.jwt.claim.sub','9a179a17-0000-0000-0000-0000000000a2',false);
set role authenticated;
select set_instructor_rate('9a179a17-0000-0000-0000-00000000d102', current_date - 60,
  50000, 0, 0, 0, null, null, null, 'standard');
reset role;

-- =============================================================================
-- 1. A STUDIO THAT NEVER SETS A TIER SEES NO CHANGE
-- =============================================================================
insert into studios (id, name, slug, timezone, currency, status) values
  ('9a179a17-0000-0000-0000-000000000003','Untouched','gp-untouched','Europe/Prague','CZK','active');
insert into studio_settings (studio_id) values ('9a179a17-0000-0000-0000-000000000003');
-- Its OWN owner. The first version of this asked studio 1's owner about studio
-- 3's class, which migration 086's guard correctly refused — the fixture was
-- reaching across a tenant boundary and the assertion had never noticed.
insert into auth.users (id) values ('9a179a17-0000-0000-0000-0000000000a5');
insert into profiles (id, email, full_name) values
  ('9a179a17-0000-0000-0000-0000000000a5','gp-owner-c@example.com','Cyd Owner');
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('9a179a17-0000-0000-0000-0000000055a5','9a179a17-0000-0000-0000-000000000003',
   '9a179a17-0000-0000-0000-0000000000a5','gp-owner-c@example.com','owner');
insert into locations (id, studio_id, name, is_primary) values
  ('9a179a17-0000-0000-0000-00000000000e','9a179a17-0000-0000-0000-000000000003','Main',true);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('9a179a17-0000-0000-0000-00000000cc04','9a179a17-0000-0000-0000-000000000003','Group',50,6);
insert into class_occurrences (id, studio_id, location_id, class_type_id, name, capacity, starts_at, ends_at)
values ('9a179a17-0000-0000-0000-000000009f01','9a179a17-0000-0000-0000-000000000003',
        '9a179a17-0000-0000-0000-00000000000e','9a179a17-0000-0000-0000-00000000cc04',
        'Ordinary class', 6, now() - interval '1 hour', now() - interval '10 min');

select set_config('request.jwt.claim.sub','9a179a17-0000-0000-0000-0000000000a5',false);
set role authenticated;
select expect_text('a studio with guarantees off has no cutoff to reach',
  (select cutoff_shape from occurrence_guarantee('9a179a17-0000-0000-0000-000000009f01')), 'none');
reset role;
select sweep_commitments() is not null as swept;
select expect_num('...and the sweep leaves its classes alone',
  (select count(*) from class_occurrences
    where studio_id='9a179a17-0000-0000-0000-000000000003'
      and (committed_at is not null or status <> 'scheduled'))::bigint, 0);
select expect_num('...and writes it no pay record',
  (select count(*) from instructor_pay_records
    where studio_id='9a179a17-0000-0000-0000-000000000003')::bigint, 0);

-- =============================================================================
-- 2. CORE: ONE BOOKING COMMITS AND PAYS IN FULL; ZERO DOES NOT RUN
-- =============================================================================
-- Both are past their 12-hour cutoff.
insert into class_occurrences (id, studio_id, location_id, class_type_id, name, room_id,
                               instructor_id, capacity, starts_at, ends_at)
values
 ('9a179a17-0000-0000-0000-00000000a001','9a179a17-0000-0000-0000-000000000001',
  '9a179a17-0000-0000-0000-00000000000c','9a179a17-0000-0000-0000-00000000cc01','Core with one',
  '9a179a17-0000-0000-0000-00000000ee01','9a179a17-0000-0000-0000-00000000d101',6,
  now() + interval '4 hours', now() + interval '4 hours 50 min'),
 ('9a179a17-0000-0000-0000-00000000a002','9a179a17-0000-0000-0000-000000000001',
  '9a179a17-0000-0000-0000-00000000000c','9a179a17-0000-0000-0000-00000000cc01','Core with none',
  '9a179a17-0000-0000-0000-00000000ee01','9a179a17-0000-0000-0000-00000000d101',6,
  now() + interval '5 hours', now() + interval '5 hours 50 min');
insert into bookings (id, studio_id, occurrence_id, member_id, status) values
  ('9a179a17-0000-0000-0000-0000000bb001','9a179a17-0000-0000-0000-000000000001',
   '9a179a17-0000-0000-0000-00000000a001','9a179a17-0000-0000-0000-0000000b1001','booked');

select sweep_commitments() is not null as swept;

select expect_true('core with one booking commits',
  (select committed_at is not null from class_occurrences where id='9a179a17-0000-0000-0000-00000000a001'));
select expect_num('...and is paid in full: base 800',
  (select amount_cents from instructor_pay_records where occurrence_id='9a179a17-0000-0000-0000-00000000a001')::bigint, 80000);
select expect_text('core with none does not run',
  (select status::text from class_occurrences where id='9a179a17-0000-0000-0000-00000000a002'), 'cancelled');
select expect_text('...and says why, typed',
  (select cancellation_cause::text from class_occurrences where id='9a179a17-0000-0000-0000-00000000a002'), 'unmet_minimum');
select expect_num('...and pays the holding rate: 50% of 800',
  (select amount_cents from instructor_pay_records where occurrence_id='9a179a17-0000-0000-0000-00000000a002')::bigint, 40000);
select expect_num('...and tells no member, because there are none',
  (select count(*) from notifications
    where template_key = 'class_cancelled'
      and dedupe_key like '%9a179a17-0000-0000-0000-00000000a002%')::bigint, 0);
select expect_num('...while the coach gets exactly one digest for both',
  (select count(*) from notifications
    where template_key = 'commitment_digest'
      and studio_id = '9a179a17-0000-0000-0000-000000000001')::bigint, 1);

-- =============================================================================
-- 3. COMMITTED IS TERMINAL
-- =============================================================================
select set_config('request.jwt.claim.sub','9a179a17-0000-0000-0000-0000000000a1',false);
set role authenticated;
select cancel_booking('9a179a17-0000-0000-0000-0000000bb001') is not null as cancelled;
reset role;
select expect_true('a committed class whose only member cancels stays committed',
  (select committed_at is not null from class_occurrences where id='9a179a17-0000-0000-0000-00000000a001'));
select expect_num('...and still pays in full',
  (select amount_cents from instructor_pay_records where occurrence_id='9a179a17-0000-0000-0000-00000000a001')::bigint, 80000);
select expect_num('...and the snapshot is what it was at the cutoff',
  (select booked_at_cutoff from class_occurrences where id='9a179a17-0000-0000-0000-00000000a001')::bigint, 1);

-- A NO-SHOW MUST NOT REDUCE PAY. booked_at_cutoff is the snapshot; attendance is
-- not consulted at all.
--
-- ITS OWN CLASS, with four at the cutoff and every one of them a no-show. The
-- first version of this asserted against a class that had picked up a later
-- booking, so counting live bookings instead of the snapshot still produced the
-- expected number and the assertion proved nothing. Four heads makes the ladder
-- visible too: 800 + 2 x 75 = 950, and a live count would give 800.
insert into class_occurrences (id, studio_id, location_id, class_type_id, name, room_id,
                               instructor_id, capacity, starts_at, ends_at,
                               booked_at_cutoff, committed_at)
values ('9a179a17-0000-0000-0000-00000000a003','9a179a17-0000-0000-0000-000000000001',
        '9a179a17-0000-0000-0000-00000000000c','9a179a17-0000-0000-0000-00000000cc01','Everyone no-showed',
        '9a179a17-0000-0000-0000-00000000ee01','9a179a17-0000-0000-0000-00000000d101',6,
        now() + interval '6 hours', now() + interval '6 hours 50 min', 4, now());
insert into bookings (id, studio_id, occurrence_id, member_id, status) values
  ('9a179a17-0000-0000-0000-0000000b9001','9a179a17-0000-0000-0000-000000000001',
   '9a179a17-0000-0000-0000-00000000a003','9a179a17-0000-0000-0000-0000000b1001','no_show'),
  ('9a179a17-0000-0000-0000-0000000b9002','9a179a17-0000-0000-0000-000000000001',
   '9a179a17-0000-0000-0000-00000000a003','9a179a17-0000-0000-0000-0000000b1002','no_show'),
  ('9a179a17-0000-0000-0000-0000000b9003','9a179a17-0000-0000-0000-000000000001',
   '9a179a17-0000-0000-0000-00000000a003','9a179a17-0000-0000-0000-0000000b1003','no_show');
select expect_num('four at the cutoff and nobody turned up still pays for four',
  (select amount_cents from instructor_pay_records
    where occurrence_id='9a179a17-0000-0000-0000-00000000a003')::bigint, 95000);
update bookings set status = 'no_show' where id = '9a179a17-0000-0000-0000-0000000bb001';
select expect_num('a no-show does not reduce what is owed',
  (select (compute_class_pay('9a179a17-0000-0000-0000-00000000a001') ->> 'amount_cents')::bigint), 80000);

-- =============================================================================
-- 4. A LATE BOOKING JOINS A COMMITTED CLASS, AND CANNOT REVIVE A DEAD ONE
-- =============================================================================
insert into bookings (id, studio_id, occurrence_id, member_id, status) values
  ('9a179a17-0000-0000-0000-0000000bb002','9a179a17-0000-0000-0000-000000000001',
   '9a179a17-0000-0000-0000-00000000a001','9a179a17-0000-0000-0000-0000000b1002','booked');
select expect_true('a booking after the cutoff joins a committed class',
  (select count(*) > 1 from bookings where occurrence_id='9a179a17-0000-0000-0000-00000000a001'));
select expect_num('...and does not change the snapshot or the pay',
  (select booked_at_cutoff from class_occurrences where id='9a179a17-0000-0000-0000-00000000a001')::bigint, 1);
select expect_text('a booking cannot revive a class that is not running',
  (book_class('9a179a17-0000-0000-0000-00000000a002',
     '9a179a17-0000-0000-0000-0000000b1003', 'staff', null, null)).failure_reason,
  'class_cancelled');

-- =============================================================================
-- 5. IDEMPOTENT
-- =============================================================================
select set_config('t.n1', (select count(*)::text from notifications where template_key='commitment_digest'), false);
select set_config('t.p1', (select count(*)::text from instructor_pay_records), false);
select sweep_commitments() is not null as again;
select expect_num('a second run sends no second notification',
  (select count(*) from notifications where template_key='commitment_digest')::bigint,
  current_setting('t.n1')::bigint);
select expect_num('...and writes no second pay record',
  (select count(*) from instructor_pay_records)::bigint, current_setting('t.p1')::bigint);
select expect_text('...and does not change a decided status',
  (select status::text from class_occurrences where id='9a179a17-0000-0000-0000-00000000a002'), 'cancelled');

-- =============================================================================
-- 6. TWO STUDIOS, DIFFERENT TIERS, CUTOFFS AND RATES, IN ONE RUN
-- =============================================================================
-- Prague: core minimum 1, cutoff 12h, holding 50%, base 800.
-- Manila: core minimum 3, cutoff 2h,  holding 25%, base 500, flex OFF.
-- A class 4 hours out is past Prague's cutoff and not past Manila's.
insert into class_occurrences (id, studio_id, location_id, class_type_id, name, room_id,
                               instructor_id, capacity, starts_at, ends_at)
values
 ('9a179a17-0000-0000-0000-00000000b001','9a179a17-0000-0000-0000-000000000002',
  '9a179a17-0000-0000-0000-00000000000d','9a179a17-0000-0000-0000-00000000cc03','Manila not yet due',
  '9a179a17-0000-0000-0000-00000000ee03','9a179a17-0000-0000-0000-00000000d102',8,
  now() + interval '4 hours', now() + interval '4 hours 50 min'),
 ('9a179a17-0000-0000-0000-00000000b002','9a179a17-0000-0000-0000-000000000002',
  '9a179a17-0000-0000-0000-00000000000d','9a179a17-0000-0000-0000-00000000cc03','Manila due, two booked',
  '9a179a17-0000-0000-0000-00000000ee03','9a179a17-0000-0000-0000-00000000d102',8,
  now() + interval '1 hour', now() + interval '1 hour 50 min');
insert into bookings (id, studio_id, occurrence_id, member_id, status) values
  ('9a179a17-0000-0000-0000-0000000bb003','9a179a17-0000-0000-0000-000000000002',
   '9a179a17-0000-0000-0000-00000000b002','9a179a17-0000-0000-0000-0000000b2001','booked');

select sweep_commitments() is not null as swept;
select expect_true('a class inside its own studio''s cutoff is left alone',
  (select committed_at is null and status = 'scheduled'
     from class_occurrences where id='9a179a17-0000-0000-0000-00000000b001'));
select expect_text('...while the other studio''s higher minimum fails a class the first would have run',
  (select status::text from class_occurrences where id='9a179a17-0000-0000-0000-00000000b002'), 'cancelled');
select expect_num('...paying ITS holding rate, 25% of 500, not the other studio''s',
  (select amount_cents from instructor_pay_records
    where occurrence_id='9a179a17-0000-0000-0000-00000000b002')::bigint, 12500);

-- =============================================================================
-- 7. THE FLEX CUTOFF IS A WALL-CLOCK TIME, AND SURVIVES A DST TRANSITION
-- =============================================================================
-- Europe/Prague springs forward on 2027-03-28. A class on the 29th has its flex
-- deadline at 20:00 on the 28th — the evening the clocks changed. 20:00 stays
-- 20:00; an interval subtracted from the class would land at 19:00.
insert into class_occurrences (id, studio_id, location_id, class_type_id, name, room_id,
                               instructor_id, capacity, starts_at, ends_at, guarantee_tier)
values ('9a179a17-0000-0000-0000-00000000c001','9a179a17-0000-0000-0000-000000000001',
        '9a179a17-0000-0000-0000-00000000000c','9a179a17-0000-0000-0000-00000000cc01','After the clocks change',
        '9a179a17-0000-0000-0000-00000000ee01','9a179a17-0000-0000-0000-00000000d101',6,
        ('2027-03-29 07:00' at time zone 'Europe/Prague'),
        ('2027-03-29 07:50' at time zone 'Europe/Prague'), 'flex');

select set_config('request.jwt.claim.sub','9a179a17-0000-0000-0000-0000000000a1',false);
set role authenticated;
select expect_text('the flex cutoff is 20:00 the evening before, across the clock change',
  (select to_char(cutoff_at at time zone 'Europe/Prague', 'YYYY-MM-DD HH24:MI')
     from occurrence_guarantee('9a179a17-0000-0000-0000-00000000c001')), '2027-03-28 20:00');
select expect_text('...and it is the wall-clock shape, not the rolling one',
  (select cutoff_shape from occurrence_guarantee('9a179a17-0000-0000-0000-00000000c001')), 'previous_day_at');
select expect_text('while core measures backwards from the class itself',
  (select cutoff_shape from occurrence_guarantee('9a179a17-0000-0000-0000-00000000a001')), 'hours_before');
reset role;

-- =============================================================================
-- 8. A STANDALONE FLEX SLOT IS FLAGGED, AND STANDBY IS PAID FOR IT
-- =============================================================================
-- Anchored on the studio's OWN date at explicit local times. Relative offsets
-- from now() put a class either side of a day boundary depending on the hour the
-- suite is run, and adjacency is a question about a studio-local DAY.
--
-- The cutoff shape here is deliberately the rolling one, so these are due
-- without depending on what time it is. Section 7 tests the wall-clock shape on
-- its own, where it is the only thing being measured.
update studio_settings set flex_deadline_mode = 'hours_before', flex_deadline_hours = 72
 where studio_id = '9a179a17-0000-0000-0000-000000000001';

insert into class_occurrences (id, studio_id, location_id, class_type_id, name, room_id,
                               instructor_id, capacity, starts_at, ends_at, guarantee_tier)
values
 ('9a179a17-0000-0000-0000-00000000c101','9a179a17-0000-0000-0000-000000000001',
  '9a179a17-0000-0000-0000-00000000000c','9a179a17-0000-0000-0000-00000000cc01','Lonely flex',
  '9a179a17-0000-0000-0000-00000000ee01','9a179a17-0000-0000-0000-00000000d101',6,
  ((studio_today('9a179a17-0000-0000-0000-000000000001') + 2) + time '07:00') at time zone 'Europe/Prague',
  ((studio_today('9a179a17-0000-0000-0000-000000000001') + 2) + time '07:50') at time zone 'Europe/Prague', 'flex'),
 ('9a179a17-0000-0000-0000-00000000c102','9a179a17-0000-0000-0000-000000000001',
  '9a179a17-0000-0000-0000-00000000000c','9a179a17-0000-0000-0000-00000000cc01','Flex with a neighbour',
  '9a179a17-0000-0000-0000-00000000ee01','9a179a17-0000-0000-0000-00000000d101',6,
  ((studio_today('9a179a17-0000-0000-0000-000000000001') + 2) + time '12:00') at time zone 'Europe/Prague',
  ((studio_today('9a179a17-0000-0000-0000-000000000001') + 2) + time '12:50') at time zone 'Europe/Prague', 'flex'),
 -- The neighbour has a booking, so it commits and STAYS scheduled. A neighbour
 -- that the same sweep cancels would make adjacency depend on evaluation order.
 ('9a179a17-0000-0000-0000-00000000c103','9a179a17-0000-0000-0000-000000000001',
  '9a179a17-0000-0000-0000-00000000000c','9a179a17-0000-0000-0000-00000000cc01','The neighbour',
  '9a179a17-0000-0000-0000-00000000ee02','9a179a17-0000-0000-0000-00000000d101',5,
  ((studio_today('9a179a17-0000-0000-0000-000000000001') + 2) + time '13:00') at time zone 'Europe/Prague',
  ((studio_today('9a179a17-0000-0000-0000-000000000001') + 2) + time '13:50') at time zone 'Europe/Prague', 'core');
insert into bookings (id, studio_id, occurrence_id, member_id, status) values
  ('9a179a17-0000-0000-0000-0000000bb004','9a179a17-0000-0000-0000-000000000001',
   '9a179a17-0000-0000-0000-00000000c103','9a179a17-0000-0000-0000-0000000b1003','booked');

select set_config('request.jwt.claim.sub','9a179a17-0000-0000-0000-0000000000a1',false);
set role authenticated;
select expect_true('a slot on its own is not adjacent to anything',
  not occurrence_is_adjacent('9a179a17-0000-0000-0000-00000000c101'));
select expect_true('...and one an hour from another class of the same coach is',
  occurrence_is_adjacent('9a179a17-0000-0000-0000-00000000c102'));
reset role;

select expect_true('both flex slots are past their cutoff and waiting',
  (select count(*) = 2 from commitment_pending('9a179a17-0000-0000-0000-000000000001')
    where past_due and occ_id in ('9a179a17-0000-0000-0000-00000000c101',
                                  '9a179a17-0000-0000-0000-00000000c102')));
select sweep_commitments() is not null as swept;
select expect_num('a standalone flex slot that did not run is paid standby',
  (select amount_cents from instructor_pay_records
    where occurrence_id='9a179a17-0000-0000-0000-00000000c101')::bigint, 15000);
select expect_num('...and one beside another class is not',
  (select amount_cents from instructor_pay_records
    where occurrence_id='9a179a17-0000-0000-0000-00000000c102')::bigint, 0);
-- The neighbour is CORE on a 12-hour cutoff and sits two days out, so the same
-- sweep that decided both flex slots correctly leaves it alone. Every class
-- reaches its own cutoff on its own terms, which is the whole reason the two
-- shapes are not collapsed into one.
select expect_true('the core neighbour is not due yet and is left waiting',
  (select status = 'scheduled' and committed_at is null
     from class_occurrences where id='9a179a17-0000-0000-0000-00000000c103'));
select expect_num('...and has no pay record, because nothing has been decided',
  (select count(*) from instructor_pay_records
    where occurrence_id='9a179a17-0000-0000-0000-00000000c103')::bigint, 0);

update studio_settings set flex_deadline_mode = 'previous_day_at'
 where studio_id = '9a179a17-0000-0000-0000-000000000001';

-- =============================================================================
-- 9. FULL HOUSE KEYS OFF THE CLASS'S OWN CAPACITY
-- =============================================================================
insert into class_occurrences (id, studio_id, location_id, class_type_id, name, room_id,
                               instructor_id, capacity, starts_at, ends_at,
                               booked_at_cutoff, committed_at)
values
 ('9a179a17-0000-0000-0000-00000000e006','9a179a17-0000-0000-0000-000000000001',
  '9a179a17-0000-0000-0000-00000000000c','9a179a17-0000-0000-0000-00000000cc01','Six of six',
  '9a179a17-0000-0000-0000-00000000ee01','9a179a17-0000-0000-0000-00000000d101',6,
  now() + interval '80 hours', now() + interval '80 hours 50 min', 6, now()),
 ('9a179a17-0000-0000-0000-00000000e005','9a179a17-0000-0000-0000-000000000001',
  '9a179a17-0000-0000-0000-00000000000c','9a179a17-0000-0000-0000-00000000cc01','Five of five',
  '9a179a17-0000-0000-0000-00000000ee02','9a179a17-0000-0000-0000-00000000d101',5,
  now() + interval '81 hours', now() + interval '81 hours 50 min', 5, now());
select expect_num('a capacity-6 room reaches a full house at 6: 800+300+200',
  (select amount_cents from instructor_pay_records
    where occurrence_id='9a179a17-0000-0000-0000-00000000e006')::bigint, 130000);
select expect_num('...and a capacity-5 room reaches one at 5: 800+225+200',
  (select amount_cents from instructor_pay_records
    where occurrence_id='9a179a17-0000-0000-0000-00000000e005')::bigint, 122500);

-- =============================================================================
-- 10. PRIVATE, DUO AND TRIO REPLACE THE LADDER, AND FOLLOW THE PRODUCT
-- =============================================================================
insert into class_occurrences (id, studio_id, location_id, class_type_id, name, room_id,
                               instructor_id, capacity, starts_at, ends_at,
                               booked_at_cutoff, committed_at)
values ('9a179a17-0000-0000-0000-00000000e101','9a179a17-0000-0000-0000-000000000001',
        '9a179a17-0000-0000-0000-00000000000c','9a179a17-0000-0000-0000-00000000cc02','A private',
        '9a179a17-0000-0000-0000-00000000ee01','9a179a17-0000-0000-0000-00000000d101',1,
        now() + interval '82 hours', now() + interval '82 hours 50 min', 1, now());
select expect_num('a private pays its flat rate, not base plus a ladder',
  (select amount_cents from instructor_pay_records
    where occurrence_id='9a179a17-0000-0000-0000-00000000e101')::bigint, 150000);
-- A GROUP CLASS WITH TWO PEOPLE IS AN UNDERFILLED GROUP CLASS, NOT A DUO.
insert into class_occurrences (id, studio_id, location_id, class_type_id, name, room_id,
                               instructor_id, capacity, starts_at, ends_at,
                               booked_at_cutoff, committed_at)
values ('9a179a17-0000-0000-0000-00000000e102','9a179a17-0000-0000-0000-000000000001',
        '9a179a17-0000-0000-0000-00000000000c','9a179a17-0000-0000-0000-00000000cc01','Group of two',
        '9a179a17-0000-0000-0000-00000000ee01','9a179a17-0000-0000-0000-00000000d101',6,
        now() + interval '83 hours', now() + interval '83 hours 50 min', 2, now());
select expect_num('two people in a group class is not a duo rate',
  (select amount_cents from instructor_pay_records
    where occurrence_id='9a179a17-0000-0000-0000-00000000e102')::bigint, 80000);

-- =============================================================================
-- 11. WHAT A CANCELLATION PAYS DEPENDS ON WHY
-- =============================================================================
insert into class_occurrences (id, studio_id, location_id, class_type_id, name, room_id,
                               instructor_id, capacity, starts_at, ends_at)
values
 ('9a179a17-0000-0000-0000-00000000f001','9a179a17-0000-0000-0000-000000000001',
  '9a179a17-0000-0000-0000-00000000000c','9a179a17-0000-0000-0000-00000000cc01','Brownout',
  '9a179a17-0000-0000-0000-00000000ee01','9a179a17-0000-0000-0000-00000000d101',6,
  now() + interval '90 hours', now() + interval '90 hours 50 min'),
 ('9a179a17-0000-0000-0000-00000000f002','9a179a17-0000-0000-0000-000000000001',
  '9a179a17-0000-0000-0000-00000000000c','9a179a17-0000-0000-0000-00000000cc01','Typhoon',
  '9a179a17-0000-0000-0000-00000000ee01','9a179a17-0000-0000-0000-00000000d101',6,
  now() + interval '91 hours', now() + interval '91 hours 50 min');
select set_config('request.jwt.claim.sub','9a179a17-0000-0000-0000-0000000000a1',false);
set role authenticated;
select cancel_occurrence('9a179a17-0000-0000-0000-00000000f001','Power cut','studio_fault') is not null as a;
select cancel_occurrence('9a179a17-0000-0000-0000-00000000f002','Typhoon','force_majeure') is not null as b;
reset role;
select expect_num('studio_fault pays base',
  (select amount_cents from instructor_pay_records
    where occurrence_id='9a179a17-0000-0000-0000-00000000f001')::bigint, 80000);
select expect_num('force_majeure pays nothing',
  (select amount_cents from instructor_pay_records
    where occurrence_id='9a179a17-0000-0000-0000-00000000f002')::bigint, 0);

-- =============================================================================
-- 12. A RATE CHANGE DOES NOT ALTER AN EXISTING RECORD
-- =============================================================================
select set_config('t.paid_before',
  (select amount_cents::text from instructor_pay_records
    where occurrence_id='9a179a17-0000-0000-0000-00000000e006'), false);
select set_config('request.jwt.claim.sub','9a179a17-0000-0000-0000-0000000000a1',false);
set role authenticated;
select set_instructor_rate('9a179a17-0000-0000-0000-00000000d101', current_date + 1,
  200000, 20000, 1, 50000, 300000, 400000, 500000, 'senior', 'a big rise');
select expect_raises('a rate version cannot be edited',
  $$update instructor_rate_versions set base_rate_cents = 1
     where instructor_id = '9a179a17-0000-0000-0000-00000000d101'$$, 'PT409');
select expect_raises('...nor deleted',
  $$delete from instructor_rate_versions
     where instructor_id = '9a179a17-0000-0000-0000-00000000d101'$$, 'PT409');
select expect_raises('...nor written twice for one date',
  $$select set_instructor_rate('9a179a17-0000-0000-0000-00000000d101', current_date + 1, 1)$$, 'PT409');
reset role;
select expect_num('a rate rise leaves an existing record exactly as it was',
  (select amount_cents from instructor_pay_records
    where occurrence_id='9a179a17-0000-0000-0000-00000000e006')::bigint,
  current_setting('t.paid_before')::bigint);
select expect_true('...and the record still points at the version it was computed with',
  (select rv.effective_from = current_date - 60
     from instructor_pay_records r
     join instructor_rate_versions rv on rv.id = r.rate_version_id
    where r.occurrence_id='9a179a17-0000-0000-0000-00000000e006'));

-- =============================================================================
-- 13. A CLOSED PERIOD IS IMMUTABLE
-- =============================================================================
select set_config('t.period',
  (select period_id::text from instructor_pay_records
    where occurrence_id='9a179a17-0000-0000-0000-00000000e006'), false);
select set_config('request.jwt.claim.sub','9a179a17-0000-0000-0000-0000000000a1',false);
set role authenticated;
select expect_true('closing a period reports what was in it',
  ((close_pay_period(current_setting('t.period')::uuid)) ->> 'ok')::boolean);
select expect_raises('a closed period cannot take a new record',
  format($$insert into instructor_pay_records
     (studio_id, instructor_id, period_id, type, amount_cents, currency)
     values ('9a179a17-0000-0000-0000-000000000001','9a179a17-0000-0000-0000-00000000d101',
             '%s','adjustment', 100, 'CZK')$$, current_setting('t.period')), 'PT409');
select expect_raises('...nor have one edited',
  format($$update instructor_pay_records set amount_cents = 1 where period_id = '%s'$$,
         current_setting('t.period')), 'PT409');
select expect_raises('...nor be closed twice',
  format($$select close_pay_period('%s')$$, current_setting('t.period')), 'PT409');
reset role;

-- =============================================================================
-- 14. FORCE-COMMIT WORKS AND IS AUDITED
-- =============================================================================
select set_config('request.jwt.claim.sub','9a179a17-0000-0000-0000-0000000000a1',false);
set role authenticated;
select expect_raises('force-commit needs a reason',
  $$select force_commit_occurrence('9a179a17-0000-0000-0000-00000000a002', '  ')$$, 'PT422');
select expect_true('force-commit revives a class that was not running',
  ((force_commit_occurrence('9a179a17-0000-0000-0000-00000000a002',
      'Regular booked by phone')) ->> 'ok')::boolean);
reset role;
select expect_text('...and it is scheduled again',
  (select status::text from class_occurrences where id='9a179a17-0000-0000-0000-00000000a002'), 'scheduled');
select expect_true('...and committed',
  (select committed_at is not null from class_occurrences where id='9a179a17-0000-0000-0000-00000000a002'));
select expect_true('...and audited with actor, reason and time',
  (select actor_user_id = '9a179a17-0000-0000-0000-0000000000a1'
      and after ->> 'reason' = 'Regular booked by phone'
      and after ->> 'at' is not null
     from audit_logs where action='occurrence.force_committed'
      and entity_id='9a179a17-0000-0000-0000-00000000a002'));

-- =============================================================================
-- 15. THE CONVERSION BONUS
-- =============================================================================
update studio_settings set conversion_bonus_enabled = true, conversion_bonus_cents = 50000,
                           conversion_window_days = 30
 where studio_id = '9a179a17-0000-0000-0000-000000000001';
insert into membership_plans (id, studio_id, name, type, price_cents, currency, status, counts_for_conversion) values
  ('9a179a17-0000-0000-0000-00000000aa01','9a179a17-0000-0000-0000-000000000001','Intro trial','drop_in',10000,'CZK','active', false),
  ('9a179a17-0000-0000-0000-00000000aa02','9a179a17-0000-0000-0000-000000000001','Ten pack','class_pack',500000,'CZK','active', true);

-- Mara's FIRST EVER class was taught by Cara. A later class by somebody else
-- must not steal the attribution.
insert into instructors (id, studio_id, display_name) values
  ('9a179a17-0000-0000-0000-00000000d103','9a179a17-0000-0000-0000-000000000001','Later Coach');
insert into class_occurrences (id, studio_id, location_id, class_type_id, name, room_id,
                               instructor_id, capacity, starts_at, ends_at, status)
values
 ('9a179a17-0000-0000-0000-000000001f01','9a179a17-0000-0000-0000-000000000001',
  '9a179a17-0000-0000-0000-00000000000c','9a179a17-0000-0000-0000-00000000cc01','Her first ever',
  '9a179a17-0000-0000-0000-00000000ee01','9a179a17-0000-0000-0000-00000000d101',6,
  now() - interval '10 days', now() - interval '10 days' + interval '50 min', 'completed'),
 ('9a179a17-0000-0000-0000-000000001f02','9a179a17-0000-0000-0000-000000000001',
  '9a179a17-0000-0000-0000-00000000000c','9a179a17-0000-0000-0000-00000000cc01','Her most recent',
  '9a179a17-0000-0000-0000-00000000ee01','9a179a17-0000-0000-0000-00000000d103',6,
  now() - interval '1 day', now() - interval '1 day' + interval '50 min', 'completed');
update studio_settings set checkin_window_enforced = false
 where studio_id = '9a179a17-0000-0000-0000-000000000001';
-- check_ins_booked_or_imported: a visit is either an import or has both a
-- booking and an occurrence. These have both.
insert into bookings (id, studio_id, occurrence_id, member_id, status) values
  ('9a179a17-0000-0000-0000-0000000cf001','9a179a17-0000-0000-0000-000000000001',
   '9a179a17-0000-0000-0000-000000001f01','9a179a17-0000-0000-0000-0000000b1001','attended'),
  ('9a179a17-0000-0000-0000-0000000cf002','9a179a17-0000-0000-0000-000000000001',
   '9a179a17-0000-0000-0000-000000001f02','9a179a17-0000-0000-0000-0000000b1001','attended');
insert into check_ins (studio_id, member_id, occurrence_id, booking_id, method, checked_in_at) values
  ('9a179a17-0000-0000-0000-000000000001','9a179a17-0000-0000-0000-0000000b1001',
   '9a179a17-0000-0000-0000-000000001f01','9a179a17-0000-0000-0000-0000000cf001','qr', now() - interval '10 days'),
  ('9a179a17-0000-0000-0000-000000000001','9a179a17-0000-0000-0000-0000000b1001',
   '9a179a17-0000-0000-0000-000000001f02','9a179a17-0000-0000-0000-0000000cf002','qr', now() - interval '1 day');
update studio_settings set checkin_window_enforced = true
 where studio_id = '9a179a17-0000-0000-0000-000000000001';

select expect_text('attribution is the first ever class, not the most recent',
  (select instructor_id::text from member_first_class('9a179a17-0000-0000-0000-0000000b1001')),
  '9a179a17-0000-0000-0000-00000000d101');

-- A TRIAL DOES NOT CONVERT.
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on)
values ('9a179a17-0000-0000-0000-00000000ab01','9a179a17-0000-0000-0000-000000000001',
        '9a179a17-0000-0000-0000-0000000b1001','9a179a17-0000-0000-0000-00000000aa01',
        'active', 10000, 'CZK', current_date);
select expect_num('a trial plan earns nobody a bonus',
  (select count(*) from instructor_pay_records
    where type='conversion' and source_id='9a179a17-0000-0000-0000-0000000b1001')::bigint, 0);

-- A QUALIFYING PACK INSIDE THE WINDOW DOES.
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on)
values ('9a179a17-0000-0000-0000-00000000ab02','9a179a17-0000-0000-0000-000000000001',
        '9a179a17-0000-0000-0000-0000000b1001','9a179a17-0000-0000-0000-00000000aa02',
        'active', 500000, 'CZK', current_date);
select expect_num('a qualifying pack within the window pays the bonus once',
  (select count(*) from instructor_pay_records
    where type='conversion' and source_id='9a179a17-0000-0000-0000-0000000b1001')::bigint, 1);
select expect_text('...to the instructor of her FIRST class',
  (select instructor_id::text from instructor_pay_records
    where type='conversion' and source_id='9a179a17-0000-0000-0000-0000000b1001'),
  '9a179a17-0000-0000-0000-00000000d101');
select expect_num('...for the configured amount',
  (select amount_cents from instructor_pay_records
    where type='conversion' and source_id='9a179a17-0000-0000-0000-0000000b1001')::bigint, 50000);

-- ONE PER MEMBER, EVER.
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on)
values ('9a179a17-0000-0000-0000-00000000ab03','9a179a17-0000-0000-0000-000000000001',
        '9a179a17-0000-0000-0000-0000000b1001','9a179a17-0000-0000-0000-00000000aa02',
        'active', 500000, 'CZK', current_date);
select expect_num('a second qualifying purchase is not a second bonus',
  (select count(*) from instructor_pay_records
    where type='conversion' and source_id='9a179a17-0000-0000-0000-0000000b1001')::bigint, 1);

-- OUTSIDE THE WINDOW DOES NOT.
insert into class_occurrences (id, studio_id, location_id, class_type_id, name, room_id,
                               instructor_id, capacity, starts_at, ends_at, status)
values ('9a179a17-0000-0000-0000-000000001f03','9a179a17-0000-0000-0000-000000000001',
        '9a179a17-0000-0000-0000-00000000000c','9a179a17-0000-0000-0000-00000000cc01','Long ago',
        '9a179a17-0000-0000-0000-00000000ee01','9a179a17-0000-0000-0000-00000000d101',6,
        now() - interval '200 days', now() - interval '200 days' + interval '50 min', 'completed');
update studio_settings set checkin_window_enforced = false where studio_id='9a179a17-0000-0000-0000-000000000001';
insert into bookings (id, studio_id, occurrence_id, member_id, status) values
  ('9a179a17-0000-0000-0000-0000000cf003','9a179a17-0000-0000-0000-000000000001',
   '9a179a17-0000-0000-0000-000000001f03','9a179a17-0000-0000-0000-0000000b1002','attended');
insert into check_ins (studio_id, member_id, occurrence_id, booking_id, method, checked_in_at) values
  ('9a179a17-0000-0000-0000-000000000001','9a179a17-0000-0000-0000-0000000b1002',
   '9a179a17-0000-0000-0000-000000001f03','9a179a17-0000-0000-0000-0000000cf003','qr', now() - interval '200 days');
update studio_settings set checkin_window_enforced = true where studio_id='9a179a17-0000-0000-0000-000000000001';
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on)
values ('9a179a17-0000-0000-0000-00000000ab04','9a179a17-0000-0000-0000-000000000001',
        '9a179a17-0000-0000-0000-0000000b1002','9a179a17-0000-0000-0000-00000000aa02',
        'active', 500000, 'CZK', current_date);
select expect_num('a purchase 200 days after the first class is outside the window',
  (select count(*) from instructor_pay_records
    where type='conversion' and source_id='9a179a17-0000-0000-0000-0000000b1002')::bigint, 0);

-- =============================================================================
-- 16. A REFUND CLAWS BACK INTO THE NEXT OPEN PERIOD
-- =============================================================================
select set_config('t.bonus_period',
  (select period_id::text from instructor_pay_records
    where type='conversion' and source_id='9a179a17-0000-0000-0000-0000000b1001'), false);
select set_config('request.jwt.claim.sub','9a179a17-0000-0000-0000-0000000000a1',false);
set role authenticated;
select close_pay_period(current_setting('t.bonus_period')::uuid) is not null as closed;
select expect_true('the bonus was paid in a period that is now closed',
  (select status = 'closed' from pay_periods where id = current_setting('t.bonus_period')::uuid));
select expect_true('clawing it back lands somewhere else',
  ((claw_back_conversion_bonus('9a179a17-0000-0000-0000-0000000b1001','refunded')) ->> 'clawed_back')::boolean);
reset role;
select expect_num('...as a negative adjustment',
  (select amount_cents from instructor_pay_records
    where type='adjustment' and source_id='9a179a17-0000-0000-0000-0000000b1001')::bigint, -50000);
select expect_true('...in an OPEN period, never by editing the closed one',
  (select p.status = 'open' and p.id <> current_setting('t.bonus_period')::uuid
     from instructor_pay_records r join pay_periods p on p.id = r.period_id
    where r.type='adjustment' and r.source_id='9a179a17-0000-0000-0000-0000000b1001'));
select expect_true('...naming the record it reverses',
  (select basis ->> 'reverses' is not null from instructor_pay_records
    where type='adjustment' and source_id='9a179a17-0000-0000-0000-0000000b1001'));
select expect_num('...and clawing back twice does not double it',
  (select count(*) from instructor_pay_records
    where type='adjustment' and source_id='9a179a17-0000-0000-0000-0000000b1001')::bigint, 1);

-- =============================================================================
-- 17. NOTHING ABOUT PAY IS REACHABLE BY A MEMBER (migration 086)
-- =============================================================================
-- Eight SECURITY DEFINER functions from 080-083 shipped with no check inside
-- them. The grant surface was right and the guards were missing, which is the
-- half of the question that only asking a real session can answer.
--
-- The direct reads returning 0 are what make each refusal below a real guard
-- rather than RLS quietly doing the work — the same proof migration 056 used.
insert into auth.users (id) values ('9a179a17-0000-0000-0000-0000000000a6');
insert into profiles (id, email, full_name) values
  ('9a179a17-0000-0000-0000-0000000000a6','gp-outsider@example.com','Otto Outsider');
insert into members (id, studio_id, first_name, last_name, email, status, user_id) values
  ('9a179a17-0000-0000-0000-0000000b2002','9a179a17-0000-0000-0000-000000000002',
   'Otto','Outsider','gp-outsider@example.com','active','9a179a17-0000-0000-0000-0000000000a6');

select set_config('request.jwt.claim.sub','9a179a17-0000-0000-0000-0000000000a6',false);
set role authenticated;

select expect_num('a member sees no rate versions at all',
  (select count(*) from instructor_rate_versions)::bigint, 0);
select expect_num('...no pay records',
  (select count(*) from instructor_pay_records)::bigint, 0);
select expect_num('...and no pay periods',
  (select count(*) from pay_periods)::bigint, 0);

select expect_raises('a member cannot read an instructor''s rate',
  $$select instructor_rate_at('9a179a17-0000-0000-0000-00000000d101', current_date)$$, 'PT403');
select expect_raises('...nor price another studio''s class',
  $$select compute_class_pay('9a179a17-0000-0000-0000-00000000e006')$$, 'PT403');
select expect_raises('...nor learn who taught a member first',
  $$select * from member_first_class('9a179a17-0000-0000-0000-0000000b1001')$$, 'PT403');
select expect_raises('...nor read a tier and cutoff',
  $$select * from occurrence_guarantee('9a179a17-0000-0000-0000-00000000a001')$$, 'PT403');
select expect_raises('...nor whether somebody''s slot stands alone',
  $$select occurrence_is_adjacent('9a179a17-0000-0000-0000-00000000c102')$$, 'PT403');
select expect_raises('...nor award a bonus',
  $$select award_conversion_bonus('9a179a17-0000-0000-0000-00000000ab02')$$, 'PT403');
select expect_raises('...nor ask whether a member ever converted',
  $$select claw_back_conversion_bonus('9a179a17-0000-0000-0000-0000000b1001','x')$$, 'PT403');
-- The two that WROTE are not merely guarded, they are ungranted: no client role
-- may call them at all, which is a stronger statement than a check.
select expect_raises('...and cannot create a pay period, having no grant to try',
  $$select ensure_pay_period('9a179a17-0000-0000-0000-000000000001', current_date)$$, '42501');
select expect_raises('...nor reach the next open one',
  $$select next_open_pay_period('9a179a17-0000-0000-0000-000000000001')$$, '42501');

-- =============================================================================
-- 18. AN INSTRUCTOR READS THEIR OWN, AND NOBODY ELSE'S
-- =============================================================================
-- Captured as postgres FIRST. Asking the instructor to look up the other
-- studio's period gives null and the guard never fires — a refusal for the
-- wrong reason looks exactly like the right one.
reset role;
select set_config('t.other_period',
  (select id::text from pay_periods where studio_id='9a179a17-0000-0000-0000-000000000002' limit 1), false);
set role authenticated;
select set_config('request.jwt.claim.sub','9a179a17-0000-0000-0000-0000000000a3',false);
select expect_true('an instructor reads their own rate',
  (select (instructor_rate_at('9a179a17-0000-0000-0000-00000000d101', current_date)).base_rate_cents > 0));
select expect_raises('...and not the other studio''s instructor''s',
  $$select instructor_rate_at('9a179a17-0000-0000-0000-00000000d102', current_date)$$, 'PT403');
select expect_true('...reads their own pay records',
  (select count(*) > 0 from instructor_pay_records
    where instructor_id = '9a179a17-0000-0000-0000-00000000d101'));
select expect_num('...and sees none of anybody else''s',
  (select count(*) from instructor_pay_records
    where instructor_id <> '9a179a17-0000-0000-0000-00000000d101')::bigint, 0);
select expect_true('...reads their own statement',
  ((pay_statement('9a179a17-0000-0000-0000-00000000d101',
     (select period_id from instructor_pay_records
       where instructor_id='9a179a17-0000-0000-0000-00000000d101' limit 1))) ->> 'ok')::boolean);
select expect_raises('...and is refused somebody else''s',
  format($$select pay_statement('9a179a17-0000-0000-0000-00000000d102', '%s')$$,
         current_setting('t.other_period')), 'PT403');
select expect_raises('...and cannot set a rate, their own included',
  $$select set_instructor_rate('9a179a17-0000-0000-0000-00000000d101', current_date + 200, 999)$$, 'PT403');
select expect_raises('...nor close a period',
  $$select close_pay_period((select period_id from instructor_pay_records
      where instructor_id='9a179a17-0000-0000-0000-00000000d101' limit 1))$$, 'PT403');
select expect_true('...but does read the tier and cutoff of a class in their own studio',
  (select tier is not null from occurrence_guarantee('9a179a17-0000-0000-0000-00000000a001')));

-- =============================================================================
-- 19. THE WRITER ITSELF (migration 088)
-- =============================================================================
-- set_series_guarantee() raised on every call from migration 081 until 088:
-- 081 renamed flex_confirmed_at to committed_at and re-issued four functions,
-- missing the one 080 had just created against the old name. Nothing caught it
-- because `guarantee_tier` had no control anywhere, so its only writer was never
-- called — and this suite set tiers by inserting rows with the column already
-- populated, which exercises the read path and not the write.
select set_config('request.jwt.claim.sub','9a179a17-0000-0000-0000-0000000000a1',false);
set role authenticated;

insert into class_series (id, studio_id, location_id, class_type_id, name, room_id,
                          capacity, duration_minutes, rrule, starts_on, ends_on, time_of_day)
values ('9a179a17-0000-0000-0000-00000000f1a1','9a179a17-0000-0000-0000-000000000001',
        '9a179a17-0000-0000-0000-00000000000c','9a179a17-0000-0000-0000-00000000cc01',
        'TIER ME','9a179a17-0000-0000-0000-00000000ee01',6,50,
        'FREQ=WEEKLY;BYDAY=MO', current_date + 20, current_date + 60, '15:00');

select expect_text('a series starts on the core tier',
  (select guarantee_tier::text from class_series where id='9a179a17-0000-0000-0000-00000000f1a1'), 'core');
select expect_true('setting it to flex answers ok',
  ((set_series_guarantee('9a179a17-0000-0000-0000-00000000f1a1','flex',4)) ->> 'ok')::boolean);
select expect_text('...and the series is flex',
  (select guarantee_tier::text from class_series where id='9a179a17-0000-0000-0000-00000000f1a1'), 'flex');
select expect_true('...with the boolean kept in step, because that is what Decision 21 readers use',
  (select flex from class_series where id='9a179a17-0000-0000-0000-00000000f1a1'));
select expect_num('...and the minimum recorded',
  (select minimum_bookings from class_series where id='9a179a17-0000-0000-0000-00000000f1a1')::bigint, 4);

-- IT REACHES THE CLASSES ALREADY ON THE CALENDAR. A studio that changes a tier
-- and finds nothing different for sixty days has been given a setting that does
-- nothing, which is the whole reason this has its own writer.
select expect_true('the classes already made are moved onto the new tier',
  (select count(*) > 0 from class_occurrences
    where series_id='9a179a17-0000-0000-0000-00000000f1a1' and guarantee_tier = 'flex'));
select expect_num('...and none is left on the old one',
  (select count(*) from class_occurrences
    where series_id='9a179a17-0000-0000-0000-00000000f1a1'
      and starts_at > now() and status='scheduled' and guarantee_tier <> 'flex'), 0);

select expect_true('and back to always',
  ((set_series_guarantee('9a179a17-0000-0000-0000-00000000f1a1','always')) ->> 'ok')::boolean);
select expect_text('...which clears the flex boolean too',
  (select guarantee_tier::text || ':' || flex::text
     from class_series where id='9a179a17-0000-0000-0000-00000000f1a1'), 'always:false');
select set_config('request.jwt.claim.sub','9a179a17-0000-0000-0000-0000000000a6',false);
select expect_raises('a member cannot set a tier',
  $$select set_series_guarantee('9a179a17-0000-0000-0000-00000000f1a1','core',1)$$, 'PT403');
select set_config('request.jwt.claim.sub','9a179a17-0000-0000-0000-0000000000a1',false);

reset role;
select set_config('request.jwt.claim.sub', null, false);
select 'guarantee and pay suite finished' as done;
