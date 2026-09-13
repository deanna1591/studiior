-- =============================================================================
-- Waitlist seat hold — Business Rules §4.2, migration 126
-- =============================================================================
-- UUID space 4d17, checked free. Run after `supabase db reset`.
--
-- A pending offer HOLDS the seat: a general booker cannot take it, but the
-- offered member can accept it, and the hold ends the instant the offer does —
-- expired, declined, or voided at the cutoff all reopen the seat. Front desk
-- overrides the hold deliberately (§14), recorded as held_seat. booked_count
-- and the reconcile still agree, because the hold is derived, never cached.
-- Two studios, so the hold is proven per-studio in one run.
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

-- --- Fixtures ----------------------------------------------------------------
-- Logins: owner (desk, studio A + B), a front desk (A), and the members who
-- book as themselves (the offered acceptor and the general bookers).
insert into auth.users (id) values
  ('4d174d17-0000-0000-0000-0000000000a1'),  -- owner
  ('4d174d17-0000-0000-0000-0000000000a2'),  -- front desk (A)
  ('4d174d17-0000-0000-0000-0000000000c2'),  -- M2 acceptor
  ('4d174d17-0000-0000-0000-0000000000b0'),  -- GB  (blocked)
  ('4d174d17-0000-0000-0000-0000000000b2'),  -- GB2 (books after expiry)
  ('4d174d17-0000-0000-0000-0000000000b3'),  -- GB3 (books after decline)
  ('4d174d17-0000-0000-0000-0000000000b4'),  -- GB4 (books after void)
  ('4d174d17-0000-0000-0000-0000000000bb');  -- GBb (studio B, blocked)
insert into profiles (id, email)
  select id, id::text||'@example.com' from auth.users where id::text like '4d174d17%';

insert into studios (id, name, slug, timezone, currency, status) values
  ('4d174d17-0000-0000-0000-000000000001','Hold A','4d17-a','Europe/Prague','CZK','active'),
  ('4d174d17-0000-0000-0000-000000000002','Hold B','4d17-b','Asia/Manila','PHP','active');
insert into studio_settings (studio_id, waitlist_enabled, waitlist_cutoff_minutes, waitlist_offer_window_minutes) values
  ('4d174d17-0000-0000-0000-000000000001', true, 60, 120),
  ('4d174d17-0000-0000-0000-000000000002', true, 30, 120);
insert into locations (id, studio_id, name, is_primary) values
  ('4d174d17-0000-0000-0000-00000000000a','4d174d17-0000-0000-0000-000000000001','Main',true),
  ('4d174d17-0000-0000-0000-00000000000b','4d174d17-0000-0000-0000-000000000002','Main',true);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('4d174d17-0000-0000-0000-0000000aa001','4d174d17-0000-0000-0000-000000000001','4d174d17-0000-0000-0000-0000000000a1','4d17-owa@example.com','owner'),
  ('4d174d17-0000-0000-0000-0000000aa002','4d174d17-0000-0000-0000-000000000001','4d174d17-0000-0000-0000-0000000000a2','4d17-fda@example.com','front_desk'),
  ('4d174d17-0000-0000-0000-0000000aa003','4d174d17-0000-0000-0000-000000000002','4d174d17-0000-0000-0000-0000000000a1','4d17-owb@example.com','owner');
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('4d174d17-0000-0000-0000-0000000cc001','4d174d17-0000-0000-0000-000000000001','Reformer',50,1),
  ('4d174d17-0000-0000-0000-0000000cc002','4d174d17-0000-0000-0000-000000000002','Reformer',50,1);
-- One room per occurrence (capacity 1), so no overlap constraint fires.
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('4d174d17-0000-0000-0000-0000000ee001','4d174d17-0000-0000-0000-000000000001','4d174d17-0000-0000-0000-00000000000a','R1',1),
  ('4d174d17-0000-0000-0000-0000000ee002','4d174d17-0000-0000-0000-000000000001','4d174d17-0000-0000-0000-00000000000a','R2',1),
  ('4d174d17-0000-0000-0000-0000000ee003','4d174d17-0000-0000-0000-000000000001','4d174d17-0000-0000-0000-00000000000a','R3',1),
  ('4d174d17-0000-0000-0000-0000000ee004','4d174d17-0000-0000-0000-000000000001','4d174d17-0000-0000-0000-00000000000a','R4',1),
  ('4d174d17-0000-0000-0000-0000000ee005','4d174d17-0000-0000-0000-000000000001','4d174d17-0000-0000-0000-00000000000a','R5',1),
  ('4d174d17-0000-0000-0000-0000000ee006','4d174d17-0000-0000-0000-000000000002','4d174d17-0000-0000-0000-00000000000b','R1',1);

-- Members. user_id set only where the member acts as themselves; waiver signed
-- so §2.1.4 never intervenes.
insert into members (id, studio_id, user_id, first_name, last_name, email, waiver_signed_at) values
  ('4d174d17-0000-0000-0000-0000000d0001','4d174d17-0000-0000-0000-000000000001',null,'M','One','4d17-m1@example.com',now()),
  ('4d174d17-0000-0000-0000-0000000d0002','4d174d17-0000-0000-0000-000000000001','4d174d17-0000-0000-0000-0000000000c2','M','Two','4d17-m2@example.com',now()),
  ('4d174d17-0000-0000-0000-0000000d00b0','4d174d17-0000-0000-0000-000000000001','4d174d17-0000-0000-0000-0000000000b0','G','Booker','4d17-gb@example.com',now()),
  ('4d174d17-0000-0000-0000-0000000d0003','4d174d17-0000-0000-0000-000000000001',null,'M','Three','4d17-m3@example.com',now()),
  ('4d174d17-0000-0000-0000-0000000d0004','4d174d17-0000-0000-0000-000000000001',null,'M','Four','4d17-m4@example.com',now()),
  ('4d174d17-0000-0000-0000-0000000d00b2','4d174d17-0000-0000-0000-000000000001','4d174d17-0000-0000-0000-0000000000b2','G','Two','4d17-gb2@example.com',now()),
  ('4d174d17-0000-0000-0000-0000000d0005','4d174d17-0000-0000-0000-000000000001',null,'M','Five','4d17-m5@example.com',now()),
  ('4d174d17-0000-0000-0000-0000000d0006','4d174d17-0000-0000-0000-000000000001',null,'M','Six','4d17-m6@example.com',now()),
  ('4d174d17-0000-0000-0000-0000000d00b3','4d174d17-0000-0000-0000-000000000001','4d174d17-0000-0000-0000-0000000000b3','G','Three','4d17-gb3@example.com',now()),
  ('4d174d17-0000-0000-0000-0000000d0007','4d174d17-0000-0000-0000-000000000001',null,'M','Seven','4d17-m7@example.com',now()),
  ('4d174d17-0000-0000-0000-0000000d00b4','4d174d17-0000-0000-0000-000000000001','4d174d17-0000-0000-0000-0000000000b4','G','Four','4d17-gb4@example.com',now()),
  ('4d174d17-0000-0000-0000-0000000d0008','4d174d17-0000-0000-0000-000000000001',null,'M','Eight','4d17-m8@example.com',now()),
  ('4d174d17-0000-0000-0000-0000000d0009','4d174d17-0000-0000-0000-000000000001',null,'M','Nine','4d17-m9@example.com',now()),
  ('4d174d17-0000-0000-0000-0000000d000e','4d174d17-0000-0000-0000-000000000001',null,'M','Walk','4d17-mw@example.com',now()),
  ('4d174d17-0000-0000-0000-0000000d00c1','4d174d17-0000-0000-0000-000000000002',null,'B','One','4d17-mb1@example.com',now()),
  ('4d174d17-0000-0000-0000-0000000d00c2','4d174d17-0000-0000-0000-000000000002',null,'B','Two','4d17-mb2@example.com',now()),
  ('4d174d17-0000-0000-0000-0000000d00cb','4d174d17-0000-0000-0000-000000000002','4d174d17-0000-0000-0000-0000000000bb','B','Booker','4d17-gbb@example.com',now());

-- Occurrences: capacity 1. H/E/D/FD start +180 (well outside cutoff), V starts
-- +40 (inside A's 60-minute cutoff), B's HB +180.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               starts_at, ends_at, capacity, booked_count, waitlist_count, status) values
  ('4d174d17-0000-0000-0000-00000000cc01','4d174d17-0000-0000-0000-000000000001','4d174d17-0000-0000-0000-00000000000a','4d174d17-0000-0000-0000-0000000cc001','4d174d17-0000-0000-0000-0000000ee001','Hold',    now()+interval '180 min', now()+interval '230 min',1,1,1,'scheduled'),
  ('4d174d17-0000-0000-0000-00000000cc02','4d174d17-0000-0000-0000-000000000001','4d174d17-0000-0000-0000-00000000000a','4d174d17-0000-0000-0000-0000000cc001','4d174d17-0000-0000-0000-0000000ee002','Expire',  now()+interval '180 min', now()+interval '230 min',1,1,1,'scheduled'),
  ('4d174d17-0000-0000-0000-00000000cc03','4d174d17-0000-0000-0000-000000000001','4d174d17-0000-0000-0000-00000000000a','4d174d17-0000-0000-0000-0000000cc001','4d174d17-0000-0000-0000-0000000ee003','Decline', now()+interval '180 min', now()+interval '230 min',1,1,1,'scheduled'),
  ('4d174d17-0000-0000-0000-00000000cc04','4d174d17-0000-0000-0000-000000000001','4d174d17-0000-0000-0000-00000000000a','4d174d17-0000-0000-0000-0000000cc001','4d174d17-0000-0000-0000-0000000ee004','Void',    now()+interval '40 min',  now()+interval '90 min', 1,0,1,'scheduled'),
  ('4d174d17-0000-0000-0000-00000000cc05','4d174d17-0000-0000-0000-000000000001','4d174d17-0000-0000-0000-00000000000a','4d174d17-0000-0000-0000-0000000cc001','4d174d17-0000-0000-0000-0000000ee005','Desk',    now()+interval '180 min', now()+interval '230 min',1,1,1,'scheduled'),
  ('4d174d17-0000-0000-0000-00000000cc06','4d174d17-0000-0000-0000-000000000002','4d174d17-0000-0000-0000-00000000000b','4d174d17-0000-0000-0000-0000000cc002','4d174d17-0000-0000-0000-0000000ee006','HoldB',   now()+interval '180 min', now()+interval '230 min',1,1,1,'scheduled');

-- Booked + waitlisted starting states. The booked member is cancelled through
-- cancel_booking below to create the offer the real way (with the §4.3 clamp).
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, waitlist_position, booked_at) values
  ('4d174d17-0000-0000-0000-00000000a001','4d174d17-0000-0000-0000-000000000001','4d174d17-0000-0000-0000-00000000cc01','4d174d17-0000-0000-0000-0000000d0001','booked','member','drop_in',null, now()-interval '1 h'),
  ('4d174d17-0000-0000-0000-00000000a002','4d174d17-0000-0000-0000-000000000001','4d174d17-0000-0000-0000-00000000cc01','4d174d17-0000-0000-0000-0000000d0002','waitlisted','member',null,1, now()-interval '30 min'),
  ('4d174d17-0000-0000-0000-00000000a003','4d174d17-0000-0000-0000-000000000001','4d174d17-0000-0000-0000-00000000cc02','4d174d17-0000-0000-0000-0000000d0003','booked','member','drop_in',null, now()-interval '1 h'),
  ('4d174d17-0000-0000-0000-00000000a004','4d174d17-0000-0000-0000-000000000001','4d174d17-0000-0000-0000-00000000cc02','4d174d17-0000-0000-0000-0000000d0004','waitlisted','member',null,1, now()-interval '30 min'),
  ('4d174d17-0000-0000-0000-00000000a005','4d174d17-0000-0000-0000-000000000001','4d174d17-0000-0000-0000-00000000cc03','4d174d17-0000-0000-0000-0000000d0005','booked','member','drop_in',null, now()-interval '1 h'),
  ('4d174d17-0000-0000-0000-00000000a006','4d174d17-0000-0000-0000-000000000001','4d174d17-0000-0000-0000-00000000cc03','4d174d17-0000-0000-0000-0000000d0006','waitlisted','member',null,1, now()-interval '30 min'),
  ('4d174d17-0000-0000-0000-00000000a008','4d174d17-0000-0000-0000-000000000001','4d174d17-0000-0000-0000-00000000cc05','4d174d17-0000-0000-0000-0000000d0008','booked','member','drop_in',null, now()-interval '1 h'),
  ('4d174d17-0000-0000-0000-00000000a009','4d174d17-0000-0000-0000-000000000001','4d174d17-0000-0000-0000-00000000cc05','4d174d17-0000-0000-0000-0000000d0009','waitlisted','member',null,1, now()-interval '30 min'),
  ('4d174d17-0000-0000-0000-00000000a0c1','4d174d17-0000-0000-0000-000000000002','4d174d17-0000-0000-0000-00000000cc06','4d174d17-0000-0000-0000-0000000d00c1','booked','member','drop_in',null, now()-interval '1 h'),
  ('4d174d17-0000-0000-0000-00000000a0c2','4d174d17-0000-0000-0000-000000000002','4d174d17-0000-0000-0000-00000000cc06','4d174d17-0000-0000-0000-0000000d00c2','waitlisted','member',null,1, now()-interval '30 min');

-- The Void occurrence: a waitlisted member with a pending offer, inside cutoff,
-- so the sweep's cutoff branch voids the offer. booked_count 0 (a seat is free).
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, waitlist_position, booked_at) values
  ('4d174d17-0000-0000-0000-00000000a007','4d174d17-0000-0000-0000-000000000001','4d174d17-0000-0000-0000-00000000cc04','4d174d17-0000-0000-0000-0000000d0007','waitlisted','member',null,1, now()-interval '30 min');
insert into waitlist_offers (id, studio_id, booking_id, occurrence_id, expires_at) values
  ('4d174d17-0000-0000-0000-00000000f007','4d174d17-0000-0000-0000-000000000001','4d174d17-0000-0000-0000-00000000a007','4d174d17-0000-0000-0000-00000000cc04', now()+interval '100 min');

-- =============================================================================
-- Create the offers the real way: the booked member is cancelled by the owner
-- (desk), which frees the seat and offers it to the front waiter.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','4d174d17-0000-0000-0000-0000000000a1',false);
select cancel_booking('4d174d17-0000-0000-0000-00000000a001');  -- Hold:   offer -> M2
select cancel_booking('4d174d17-0000-0000-0000-00000000a003');  -- Expire: offer -> M4
select cancel_booking('4d174d17-0000-0000-0000-00000000a005');  -- Decline:offer -> M6
select cancel_booking('4d174d17-0000-0000-0000-00000000a008');  -- Desk:   offer -> M9
select cancel_booking('4d174d17-0000-0000-0000-00000000a0c1');  -- HoldB:  offer -> Mb2
select set_config('request.jwt.claim.sub','',false); reset role;

-- Sanity: each occurrence has one pending offer holding its freed seat.
select expect_num('Hold has a pending offer', (select count(*) from waitlist_offers where occurrence_id='4d174d17-0000-0000-0000-00000000cc01' and outcome is null), 1);
select expect_num('one seat held on Hold', occurrence_seats_held('4d174d17-0000-0000-0000-00000000cc01'), 1);
select expect_num('Hold booked_count freed to 0', (select booked_count from class_occurrences where id='4d174d17-0000-0000-0000-00000000cc01'), 0);

-- =============================================================================
-- 1. A general booker cannot take the held seat — they are put on the waitlist.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','4d174d17-0000-0000-0000-0000000000b0',false);
select set_config('t.gb', (book_class('4d174d17-0000-0000-0000-00000000cc01','4d174d17-0000-0000-0000-0000000d00b0','member'))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('general booker is waitlisted, not booked (seat held)',
  (current_setting('t.gb')::book_class_result).status::text, 'waitlisted');
select expect_num('the held seat was not taken (booked_count still 0)',
  (select booked_count from class_occurrences where id='4d174d17-0000-0000-0000-00000000cc01'), 0);

-- =============================================================================
-- 3. The offered member CAN accept it — their own offer is excluded from the hold.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','4d174d17-0000-0000-0000-0000000000c2',false);
select set_config('t.m2', (respond_to_offer((select id from waitlist_offers where occurrence_id='4d174d17-0000-0000-0000-00000000cc01' and outcome is null), true))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_true('offered member accepts', (current_setting('t.m2')::jsonb->>'ok')::boolean);
select expect_text('and is booked', current_setting('t.m2')::jsonb->>'status', 'booked');
select expect_num('Hold now physically full', (select booked_count from class_occurrences where id='4d174d17-0000-0000-0000-00000000cc01'), 1);

-- =============================================================================
-- 2a. EXPIRED offer holds nothing — the seat is bookable at once.
-- =============================================================================
update waitlist_offers set expires_at = now()-interval '1 min'
 where occurrence_id='4d174d17-0000-0000-0000-00000000cc02' and outcome is null;
select expect_num('an expired offer holds no seat', occurrence_seats_held('4d174d17-0000-0000-0000-00000000cc02'), 0);
set role authenticated; select set_config('request.jwt.claim.sub','4d174d17-0000-0000-0000-0000000000b2',false);
select set_config('t.gb2', (book_class('4d174d17-0000-0000-0000-00000000cc02','4d174d17-0000-0000-0000-0000000d00b2','member'))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('general booker books the seat once the offer expired',
  (current_setting('t.gb2')::book_class_result).status::text, 'booked');

-- =============================================================================
-- 2b. DECLINED offer (no next waiter) reopens the seat to general booking.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','4d174d17-0000-0000-0000-0000000000a1',false);
select respond_to_offer((select id from waitlist_offers where occurrence_id='4d174d17-0000-0000-0000-00000000cc03' and outcome is null), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_num('a declined offer holds no seat', occurrence_seats_held('4d174d17-0000-0000-0000-00000000cc03'), 0);
set role authenticated; select set_config('request.jwt.claim.sub','4d174d17-0000-0000-0000-0000000000b3',false);
select set_config('t.gb3', (book_class('4d174d17-0000-0000-0000-00000000cc03','4d174d17-0000-0000-0000-0000000d00b3','member'))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('general booker books the seat once the offer was declined',
  (current_setting('t.gb3')::book_class_result).status::text, 'booked');

-- =============================================================================
-- 2c. VOIDED at the cutoff (by the sweep) reopens the seat.
-- =============================================================================
select expect_num('before the sweep the Void seat is held', occurrence_seats_held('4d174d17-0000-0000-0000-00000000cc04'), 1);
select sweep_waitlist();
select expect_num('the cutoff sweep voided the offer', occurrence_seats_held('4d174d17-0000-0000-0000-00000000cc04'), 0);
select expect_text('the offer is closed, not left pending',
  (select outcome from waitlist_offers where occurrence_id='4d174d17-0000-0000-0000-00000000cc04'), 'closed');
set role authenticated; select set_config('request.jwt.claim.sub','4d174d17-0000-0000-0000-0000000000b4',false);
select set_config('t.gb4', (book_class('4d174d17-0000-0000-0000-00000000cc04','4d174d17-0000-0000-0000-0000000d00b4','member'))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('general booker books the seat once it was voided at the cutoff',
  (current_setting('t.gb4')::book_class_result).status::text, 'booked');

-- =============================================================================
-- 5. Front desk overrides the hold — a deliberate act (§14), recorded held_seat.
-- =============================================================================
select expect_num('Desk seat is held before the override', occurrence_seats_held('4d174d17-0000-0000-0000-00000000cc05'), 1);
set role authenticated; select set_config('request.jwt.claim.sub','4d174d17-0000-0000-0000-0000000000a2',false);  -- front desk
select set_config('t.fd', (book_class('4d174d17-0000-0000-0000-00000000cc05','4d174d17-0000-0000-0000-0000000d000e','front_desk','walk-in at the counter'))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('front desk books the walk-in into the held seat',
  (current_setting('t.fd')::book_class_result).status::text, 'booked');
select expect_true('the override is recorded as held_seat, not capacity',
  (select overridden_rules @> array['held_seat'] and not (overridden_rules @> array['capacity'])
     from bookings where id=(current_setting('t.fd')::book_class_result).booking_id));

-- =============================================================================
-- 4. booked_count and the nightly reconcile still agree — the hold is derived.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','4d174d17-0000-0000-0000-0000000000a1',false);
select set_config('t.rec', (reconcile_booked_counts('4d174d17-0000-0000-0000-000000000001', true))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_num('reconcile finds nothing to correct — booked_count never tracked the hold',
  (current_setting('t.rec')::jsonb->>'corrected')::bigint, 0);

-- =============================================================================
-- 6. Two studios: B's hold blocks a B booker, independently of A.
-- =============================================================================
select expect_num('HoldB has a held seat', occurrence_seats_held('4d174d17-0000-0000-0000-00000000cc06'), 1);
set role authenticated; select set_config('request.jwt.claim.sub','4d174d17-0000-0000-0000-0000000000bb',false);
select set_config('t.gbb', (book_class('4d174d17-0000-0000-0000-00000000cc06','4d174d17-0000-0000-0000-0000000d00cb','member'))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('studio B general booker is waitlisted by B''s own hold',
  (current_setting('t.gbb')::book_class_result).status::text, 'waitlisted');

-- The UI question: occurrence_holds returns the held count, scoped to the studio.
set role authenticated; select set_config('request.jwt.claim.sub','4d174d17-0000-0000-0000-0000000000bb',false);
select expect_num('occurrence_holds reports B''s hold to a B member',
  (select held from occurrence_holds('4d174d17-0000-0000-0000-000000000002', now(), now()+interval '365 days')
    where occurrence_id='4d174d17-0000-0000-0000-00000000cc06'), 1);
select set_config('request.jwt.claim.sub','',false); reset role;

do $$ begin raise notice 'waitlist_hold_test: all assertions passed'; end $$;
