-- =============================================================================
-- Waitlist sweep — Business Rules §4.2 (cascade) and §4.4 (cutoff), migration 125
-- =============================================================================
-- UUID space 7a17, checked free. Run after `supabase db reset`.
--
-- An expired offer closes and cascades to the next; a declined offer cascades;
-- the last person declining opens the seat to general booking; at the cutoff
-- every remaining entry is closed and notified once; no offer under 15 minutes;
-- a re-run is a no-op; two studios on different cutoffs in one run.
--
-- Capacity 1 with no booked filler: occurrence_seats_taken is 0 < 1, so a free
-- seat exists and the sweep's promote branch has something to offer — which is
-- exactly the state a cancellation leaves.
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

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values ('7a177a17-0000-0000-0000-0000000000a1');
insert into profiles (id, email) values ('7a177a17-0000-0000-0000-0000000000a1','7a17-owner@example.com');

insert into studios (id, name, slug, timezone, currency, status) values
  ('7a177a17-0000-0000-0000-000000000001','Wait A','7a17-a','Europe/Prague','CZK','active'),
  ('7a177a17-0000-0000-0000-000000000002','Wait B','7a17-b','Asia/Manila','PHP','active');
-- A: cutoff 60 (default). B: cutoff 30. Both waitlist on, window 120.
insert into studio_settings (studio_id, waitlist_cutoff_minutes) values
  ('7a177a17-0000-0000-0000-000000000001', 60),
  ('7a177a17-0000-0000-0000-000000000002', 30);
insert into locations (id, studio_id, name, is_primary) values
  ('7a177a17-0000-0000-0000-00000000000a','7a177a17-0000-0000-0000-000000000001','Main',true),
  ('7a177a17-0000-0000-0000-00000000000b','7a177a17-0000-0000-0000-000000000002','Main',true);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('7a177a17-0000-0000-0000-0000000aa001','7a177a17-0000-0000-0000-000000000001','7a177a17-0000-0000-0000-0000000000a1','7a17-owner@example.com','owner'),
  ('7a177a17-0000-0000-0000-0000000aa002','7a177a17-0000-0000-0000-000000000002','7a177a17-0000-0000-0000-0000000000a1','7a17-owner-b@example.com','owner');
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('7a177a17-0000-0000-0000-0000000cc001','7a177a17-0000-0000-0000-000000000001','Reformer',50,1),
  ('7a177a17-0000-0000-0000-0000000cc002','7a177a17-0000-0000-0000-000000000002','Reformer',50,1);
-- One room per occurrence, so the exclusion constraint never fires on overlap.
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('7a177a17-0000-0000-0000-0000000ee001','7a177a17-0000-0000-0000-000000000001','7a177a17-0000-0000-0000-00000000000a','R1',1),
  ('7a177a17-0000-0000-0000-0000000ee002','7a177a17-0000-0000-0000-000000000001','7a177a17-0000-0000-0000-00000000000a','R2',1),
  ('7a177a17-0000-0000-0000-0000000ee003','7a177a17-0000-0000-0000-000000000001','7a177a17-0000-0000-0000-00000000000a','R3',1),
  ('7a177a17-0000-0000-0000-0000000ee004','7a177a17-0000-0000-0000-000000000001','7a177a17-0000-0000-0000-00000000000a','R4',1),
  ('7a177a17-0000-0000-0000-0000000ee005','7a177a17-0000-0000-0000-000000000001','7a177a17-0000-0000-0000-00000000000a','R5',1),
  ('7a177a17-0000-0000-0000-0000000ee006','7a177a17-0000-0000-0000-000000000001','7a177a17-0000-0000-0000-00000000000a','R6',1),
  ('7a177a17-0000-0000-0000-0000000ee007','7a177a17-0000-0000-0000-000000000002','7a177a17-0000-0000-0000-00000000000b','R1',1);

insert into members (id, studio_id, first_name, last_name, email) values
  ('7a177a17-0000-0000-0000-0000000dd001','7a177a17-0000-0000-0000-000000000001','W','One','7a17-w1@example.com'),
  ('7a177a17-0000-0000-0000-0000000dd002','7a177a17-0000-0000-0000-000000000001','W','Two','7a17-w2@example.com'),
  ('7a177a17-0000-0000-0000-0000000dd003','7a177a17-0000-0000-0000-000000000001','D','One','7a17-d1@example.com'),
  ('7a177a17-0000-0000-0000-0000000dd004','7a177a17-0000-0000-0000-000000000001','D','Two','7a17-d2@example.com'),
  ('7a177a17-0000-0000-0000-0000000dd005','7a177a17-0000-0000-0000-000000000001','L','One','7a17-l1@example.com'),
  ('7a177a17-0000-0000-0000-0000000dd006','7a177a17-0000-0000-0000-000000000001','C','One','7a17-c1@example.com'),
  ('7a177a17-0000-0000-0000-0000000dd007','7a177a17-0000-0000-0000-000000000001','C','Two','7a17-c2@example.com'),
  ('7a177a17-0000-0000-0000-0000000dd008','7a177a17-0000-0000-0000-000000000001','N','One','7a17-n1@example.com'),
  ('7a177a17-0000-0000-0000-0000000dd009','7a177a17-0000-0000-0000-000000000001','A','Cut','7a17-ac1@example.com'),
  ('7a177a17-0000-0000-0000-0000000dd00a','7a177a17-0000-0000-0000-000000000002','B','One','7a17-b1@example.com');

-- Occurrences (capacity 1, no booked filler → one free seat each). Times chosen
-- to land inside/outside each studio's cutoff.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               starts_at, ends_at, capacity, booked_count, waitlist_count, status) values
  ('7a177a17-0000-0000-0000-00000000c001','7a177a17-0000-0000-0000-000000000001','7a177a17-0000-0000-0000-00000000000a','7a177a17-0000-0000-0000-0000000cc001','7a177a17-0000-0000-0000-0000000ee001','ExpiryCascade', now()+interval '180 min', now()+interval '230 min',1,0,2,'scheduled'),
  ('7a177a17-0000-0000-0000-00000000c002','7a177a17-0000-0000-0000-000000000001','7a177a17-0000-0000-0000-00000000000a','7a177a17-0000-0000-0000-0000000cc001','7a177a17-0000-0000-0000-0000000ee002','DeclineCascade', now()+interval '200 min', now()+interval '250 min',1,0,2,'scheduled'),
  ('7a177a17-0000-0000-0000-00000000c003','7a177a17-0000-0000-0000-000000000001','7a177a17-0000-0000-0000-00000000000a','7a177a17-0000-0000-0000-0000000cc001','7a177a17-0000-0000-0000-0000000ee003','LastDecline', now()+interval '220 min', now()+interval '270 min',1,0,1,'scheduled'),
  ('7a177a17-0000-0000-0000-00000000c004','7a177a17-0000-0000-0000-000000000001','7a177a17-0000-0000-0000-00000000000a','7a177a17-0000-0000-0000-0000000cc001','7a177a17-0000-0000-0000-0000000ee004','InsideCutoff', now()+interval '30 min', now()+interval '80 min',1,0,2,'scheduled'),
  ('7a177a17-0000-0000-0000-00000000c005','7a177a17-0000-0000-0000-000000000001','7a177a17-0000-0000-0000-00000000000a','7a177a17-0000-0000-0000-0000000cc001','7a177a17-0000-0000-0000-0000000ee005','WindowTooShort', now()+interval '70 min', now()+interval '120 min',1,0,1,'scheduled'),
  ('7a177a17-0000-0000-0000-00000000c006','7a177a17-0000-0000-0000-000000000001','7a177a17-0000-0000-0000-00000000000a','7a177a17-0000-0000-0000-0000000cc001','7a177a17-0000-0000-0000-0000000ee006','A50', now()+interval '50 min', now()+interval '100 min',1,0,1,'scheduled'),
  ('7a177a17-0000-0000-0000-00000000c007','7a177a17-0000-0000-0000-000000000002','7a177a17-0000-0000-0000-00000000000b','7a177a17-0000-0000-0000-0000000cc002','7a177a17-0000-0000-0000-0000000ee007','B50', now()+interval '50 min', now()+interval '100 min',1,0,1,'scheduled');

-- Waitlisted bookings (payment_source null — §4.1, no credit on joining).
insert into bookings (id, studio_id, occurrence_id, member_id, status, waitlist_position, booked_at) values
  ('7a177a17-0000-0000-0000-00000000b001','7a177a17-0000-0000-0000-000000000001','7a177a17-0000-0000-0000-00000000c001','7a177a17-0000-0000-0000-0000000dd001','waitlisted',1, now()-interval '2 h'),
  ('7a177a17-0000-0000-0000-00000000b002','7a177a17-0000-0000-0000-000000000001','7a177a17-0000-0000-0000-00000000c001','7a177a17-0000-0000-0000-0000000dd002','waitlisted',2, now()-interval '1 h'),
  ('7a177a17-0000-0000-0000-00000000b003','7a177a17-0000-0000-0000-000000000001','7a177a17-0000-0000-0000-00000000c002','7a177a17-0000-0000-0000-0000000dd003','waitlisted',1, now()-interval '2 h'),
  ('7a177a17-0000-0000-0000-00000000b004','7a177a17-0000-0000-0000-000000000001','7a177a17-0000-0000-0000-00000000c002','7a177a17-0000-0000-0000-0000000dd004','waitlisted',2, now()-interval '1 h'),
  ('7a177a17-0000-0000-0000-00000000b005','7a177a17-0000-0000-0000-000000000001','7a177a17-0000-0000-0000-00000000c003','7a177a17-0000-0000-0000-0000000dd005','waitlisted',1, now()-interval '2 h'),
  ('7a177a17-0000-0000-0000-00000000b006','7a177a17-0000-0000-0000-000000000001','7a177a17-0000-0000-0000-00000000c004','7a177a17-0000-0000-0000-0000000dd006','waitlisted',1, now()-interval '2 h'),
  ('7a177a17-0000-0000-0000-00000000b007','7a177a17-0000-0000-0000-000000000001','7a177a17-0000-0000-0000-00000000c004','7a177a17-0000-0000-0000-0000000dd007','waitlisted',2, now()-interval '1 h'),
  ('7a177a17-0000-0000-0000-00000000b008','7a177a17-0000-0000-0000-000000000001','7a177a17-0000-0000-0000-00000000c005','7a177a17-0000-0000-0000-0000000dd008','waitlisted',1, now()-interval '2 h'),
  ('7a177a17-0000-0000-0000-00000000b009','7a177a17-0000-0000-0000-000000000001','7a177a17-0000-0000-0000-00000000c006','7a177a17-0000-0000-0000-0000000dd009','waitlisted',1, now()-interval '2 h'),
  ('7a177a17-0000-0000-0000-00000000b00a','7a177a17-0000-0000-0000-000000000002','7a177a17-0000-0000-0000-00000000c007','7a177a17-0000-0000-0000-0000000dd00a','waitlisted',1, now()-interval '2 h');

-- Pre-existing offers, as cancel_booking would have made them.
insert into waitlist_offers (id, studio_id, booking_id, occurrence_id, expires_at) values
  ('7a177a17-0000-0000-0000-00000000f001','7a177a17-0000-0000-0000-000000000001','7a177a17-0000-0000-0000-00000000b001','7a177a17-0000-0000-0000-00000000c001', now()-interval '1 min'),   -- W1: EXPIRED
  ('7a177a17-0000-0000-0000-00000000f002','7a177a17-0000-0000-0000-000000000001','7a177a17-0000-0000-0000-00000000b003','7a177a17-0000-0000-0000-00000000c002', now()+interval '100 min'), -- D1: pending
  ('7a177a17-0000-0000-0000-00000000f003','7a177a17-0000-0000-0000-000000000001','7a177a17-0000-0000-0000-00000000b005','7a177a17-0000-0000-0000-00000000c003', now()+interval '100 min'); -- L1: pending

-- Decline D1 and L1 as the owner (desk-up), before the sweep.
set role authenticated; select set_config('request.jwt.claim.sub','7a177a17-0000-0000-0000-0000000000a1',false);
select respond_to_offer('7a177a17-0000-0000-0000-00000000f002', false);   -- D1 declines
select respond_to_offer('7a177a17-0000-0000-0000-00000000f003', false);   -- L1 declines (last)
select set_config('request.jwt.claim.sub','',false); reset role;

-- ============================ SWEEP #1 =======================================
select sweep_waitlist();

-- 1. EXPIRY cascades. W1's offer expired, W1 left the front, W2 was offered.
select expect_text('W1 offer is expired',
  (select outcome from waitlist_offers where id='7a177a17-0000-0000-0000-00000000f001'), 'expired');
select expect_text('W1 booking is cancelled',
  (select status::text from bookings where id='7a177a17-0000-0000-0000-00000000b001'), 'cancelled');
select expect_num('W2 now has a pending offer',
  (select count(*) from waitlist_offers
    where occurrence_id='7a177a17-0000-0000-0000-00000000c001'
      and booking_id='7a177a17-0000-0000-0000-00000000b002' and outcome is null), 1);

-- 2. DECLINE cascades. D1 declined, D2 was offered.
select expect_text('D1 offer is declined',
  (select outcome from waitlist_offers where id='7a177a17-0000-0000-0000-00000000f002'), 'declined');
select expect_num('D2 now has a pending offer',
  (select count(*) from waitlist_offers
    where occurrence_id='7a177a17-0000-0000-0000-00000000c002'
      and booking_id='7a177a17-0000-0000-0000-00000000b004' and outcome is null), 1);

-- 3. LAST person declining opens the seat to general booking — no cascade,
--    seat free.
select expect_num('no pending offer on the last-decline class',
  (select count(*) from waitlist_offers
    where occurrence_id='7a177a17-0000-0000-0000-00000000c003' and outcome is null), 0);
select expect_true('its seat is open (seats_taken < capacity)',
  (select occurrence_seats_taken('7a177a17-0000-0000-0000-00000000c003')
        < (select capacity from class_occurrences where id='7a177a17-0000-0000-0000-00000000c003')));

-- 4. CUTOFF closes every remaining entry, notified once. O_CUT (C1,C2) inside
--    A's 60, O_ACUT (AC1) inside A's 60 → 3 "missed" notices for studio A.
select expect_text('C1 is cancelled at the cutoff',
  (select status::text from bookings where id='7a177a17-0000-0000-0000-00000000b006'), 'cancelled');
select expect_text('C2 is cancelled at the cutoff',
  (select status::text from bookings where id='7a177a17-0000-0000-0000-00000000b007'), 'cancelled');
select expect_num('three "didn''t get in" notices for studio A',
  (select count(*) from notifications
    where studio_id='7a177a17-0000-0000-0000-000000000001' and template_key='waitlist_missed'), 3);

-- 5. NO OFFER under 15 minutes. O_WIN is +70, outside A's 60 cutoff, but the
--    window is only 10 minutes — the seat opens instead.
select expect_num('no offer made when the window is under 15 minutes',
  (select count(*) from waitlist_offers
    where occurrence_id='7a177a17-0000-0000-0000-00000000c005' and outcome is null), 0);
select expect_text('and that member is still waiting (not closed — outside the cutoff)',
  (select status::text from bookings where id='7a177a17-0000-0000-0000-00000000b008'), 'waitlisted');

-- 6. TWO STUDIOS, DIFFERENT CUTOFFS, ONE RUN. Both classes start in 45 minutes:
--    studio A (cutoff 60) closes it, studio B (cutoff 30) offers it.
select expect_text('studio A''s 45-min class was closed at its cutoff',
  (select status::text from bookings where id='7a177a17-0000-0000-0000-00000000b009'), 'cancelled');
select expect_num('studio B''s 45-min class was offered (its cutoff is 30)',
  (select count(*) from waitlist_offers
    where occurrence_id='7a177a17-0000-0000-0000-00000000c007'
      and booking_id='7a177a17-0000-0000-0000-00000000b00a' and outcome is null), 1);

-- ============================ SWEEP #2 (idempotent) ==========================
select sweep_waitlist();
select expect_num('a re-run sends no further "missed" notices',
  (select count(*) from notifications
    where studio_id='7a177a17-0000-0000-0000-000000000001' and template_key='waitlist_missed'), 3);
select expect_num('a re-run makes no further offers (W2 still the only pending on O_EXP)',
  (select count(*) from waitlist_offers
    where occurrence_id='7a177a17-0000-0000-0000-00000000c001' and outcome is null), 1);
select expect_num('a re-run does not re-offer studio B',
  (select count(*) from waitlist_offers
    where occurrence_id='7a177a17-0000-0000-0000-00000000c007' and outcome is null), 1);

-- --- Teardown ----------------------------------------------------------------
delete from notifications where studio_id in
  ('7a177a17-0000-0000-0000-000000000001','7a177a17-0000-0000-0000-000000000002');

do $$ begin raise notice 'waitlist_sweep_test: all assertions passed'; end $$;
