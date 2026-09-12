-- =============================================================================
-- Challenges — migrations 117–121, MEMBERS ONLY
-- =============================================================================
-- UUID space c8a1, checked free. Run after `supabase db reset`.
--
-- Business Rules §9, every clause the brief named: progress counts from the
-- challenge start for a late joiner; one event per booking; a late cancel and a
-- no-show count for nothing; a corrected no-show counts and re-evaluates; a
-- streak break resets to the current run; a comp booking counts; progress
-- recomputes identically from events; the leaderboard is invisible when off (and
-- a member still sees their OWN row); joining after the deadline is refused; a
-- studio with no challenges sees nothing anywhere; two studios in one sweep.
--
-- Plus the RLS teeth: a member cannot write their own progress or join past the
-- deadline by posting a row directly — the hole cp_member_self left open since
-- migration 001.
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
insert into auth.users (id) values
  ('c8a1c8a1-0000-0000-0000-0000000000a1'),   -- owner (A, B, C)
  ('c8a1c8a1-0000-0000-0000-0000000000e1'),   -- MEM1 (A) main
  ('c8a1c8a1-0000-0000-0000-0000000000e2'),   -- MEM2 (A) leaderboard co-participant
  ('c8a1c8a1-0000-0000-0000-0000000000e3'),   -- MEM3 (A) deadline + teeth
  ('c8a1c8a1-0000-0000-0000-0000000000e4'),   -- MEM_S (A) streak
  ('c8a1c8a1-0000-0000-0000-0000000000c1');   -- MEM_C (C) no-challenge studio
insert into profiles (id, email) values
  ('c8a1c8a1-0000-0000-0000-0000000000a1','c8a1-owner@example.com'),
  ('c8a1c8a1-0000-0000-0000-0000000000e1','c8a1-m1@example.com'),
  ('c8a1c8a1-0000-0000-0000-0000000000e2','c8a1-m2@example.com'),
  ('c8a1c8a1-0000-0000-0000-0000000000e3','c8a1-m3@example.com'),
  ('c8a1c8a1-0000-0000-0000-0000000000e4','c8a1-ms@example.com'),
  ('c8a1c8a1-0000-0000-0000-0000000000c1','c8a1-mc@example.com');

insert into studios (id, name, slug, timezone, currency, status) values
  ('c8a1c8a1-0000-0000-0000-000000000001','Ch A','c8a1-a','Europe/Prague','CZK','active'),
  ('c8a1c8a1-0000-0000-0000-000000000002','Ch B','c8a1-b','Asia/Manila','PHP','active'),
  ('c8a1c8a1-0000-0000-0000-000000000003','Ch C','c8a1-c','Europe/Prague','CZK','active');
insert into studio_settings (studio_id) values
  ('c8a1c8a1-0000-0000-0000-000000000001'),
  ('c8a1c8a1-0000-0000-0000-000000000002'),
  ('c8a1c8a1-0000-0000-0000-000000000003');
insert into locations (id, studio_id, name, is_primary) values
  ('c8a1c8a1-0000-0000-0000-00000000000a','c8a1c8a1-0000-0000-0000-000000000001','Main',true),
  ('c8a1c8a1-0000-0000-0000-00000000000b','c8a1c8a1-0000-0000-0000-000000000002','Main',true),
  ('c8a1c8a1-0000-0000-0000-00000000000c','c8a1c8a1-0000-0000-0000-000000000003','Main',true);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('c8a1c8a1-0000-0000-0000-00000000aa01','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-0000000000a1','c8a1-owner@example.com','owner'),
  ('c8a1c8a1-0000-0000-0000-00000000bb01','c8a1c8a1-0000-0000-0000-000000000002','c8a1c8a1-0000-0000-0000-0000000000a1','c8a1-owner-b@example.com','owner'),
  ('c8a1c8a1-0000-0000-0000-00000000cc01','c8a1c8a1-0000-0000-0000-000000000003','c8a1c8a1-0000-0000-0000-0000000000a1','c8a1-owner-c@example.com','owner');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('c8a1c8a1-0000-0000-0000-0000000ee001','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-00000000000a','R1',20),
  ('c8a1c8a1-0000-0000-0000-0000000ee003','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-00000000000a','R2',20),
  ('c8a1c8a1-0000-0000-0000-0000000ee002','c8a1c8a1-0000-0000-0000-000000000002','c8a1c8a1-0000-0000-0000-00000000000b','R1',20);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('c8a1c8a1-0000-0000-0000-0000000cc001','c8a1c8a1-0000-0000-0000-000000000001','Reformer',50,20),
  ('c8a1c8a1-0000-0000-0000-0000000cc002','c8a1c8a1-0000-0000-0000-000000000002','Reformer',50,20);

insert into members (id, studio_id, user_id, first_name, last_name, email, joined_on, waiver_signed_at) values
  ('c8a1c8a1-0000-0000-0000-0000000dd001','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-0000000000e1','Mia','Alpha','c8a1-m1@example.com', current_date - 60, now()),
  ('c8a1c8a1-0000-0000-0000-0000000dd002','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-0000000000e2','Noa','Beta','c8a1-m2@example.com', current_date - 60, now()),
  ('c8a1c8a1-0000-0000-0000-0000000dd003','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-0000000000e3','Ola','Gamma','c8a1-m3@example.com', current_date - 60, now()),
  ('c8a1c8a1-0000-0000-0000-0000000dd004','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-0000000000e4','Sam','Streak','c8a1-ms@example.com', current_date - 60, now()),
  ('c8a1c8a1-0000-0000-0000-0000000dd0c1','c8a1c8a1-0000-0000-0000-000000000003','c8a1c8a1-0000-0000-0000-0000000000c1','Cy','Cee','c8a1-mc@example.com', current_date - 60, now());

-- --- Challenges --------------------------------------------------------------
-- CH_COUNT: class_count, goal 5, open to join, board OFF. Window covers the
-- attendances below and excludes one that predates the start.
insert into challenges (id, studio_id, title, audience, type, goal_value, class_type_ids,
                        starts_on, ends_on, join_deadline, status, leaderboard_enabled) values
  ('c8a1c8a1-0000-0000-0000-00000000c001','c8a1c8a1-0000-0000-0000-000000000001',
   '5 classes', 'member','class_count',5,'[]'::jsonb,
   current_date - 14, current_date + 30, current_date + 5, 'active', false),
-- CH_STREAK: streak, goal 3 weeks.
  ('c8a1c8a1-0000-0000-0000-00000000c002','c8a1c8a1-0000-0000-0000-000000000001',
   'Weekly streak','member','streak',3,'[]'::jsonb,
   current_date - 42, current_date + 30, current_date + 5, 'active', false),
-- CH_DEADLINE: join deadline already passed.
  ('c8a1c8a1-0000-0000-0000-00000000c003','c8a1c8a1-0000-0000-0000-000000000001',
   'Closed to join','member','class_count',2,'[]'::jsonb,
   current_date - 20, current_date + 10, current_date - 10, 'active', false),
-- CH_SCHED: scheduled, starts today — the sweep should activate it.
  ('c8a1c8a1-0000-0000-0000-00000000c004','c8a1c8a1-0000-0000-0000-000000000001',
   'Opens today','member','class_count',3,'[]'::jsonb,
   current_date, current_date + 20, current_date + 10, 'scheduled', false),
-- CH_ENDING: active, ends in 2 days — ending-soon after the sweep.
  ('c8a1c8a1-0000-0000-0000-00000000c005','c8a1c8a1-0000-0000-0000-000000000001',
   'Ends soon','member','class_count',3,'[]'::jsonb,
   current_date - 10, current_date + 2, current_date + 1, 'active', false),
-- CH_B (studio B): active, ended yesterday — the sweep should end it.
  ('c8a1c8a1-0000-0000-0000-00000000c00b','c8a1c8a1-0000-0000-0000-000000000002',
   'Studio B','member','class_count',3,'[]'::jsonb,
   current_date - 10, current_date - 1, current_date - 5, 'active', false);

-- --- MEM1 attendances in CH_COUNT window (inserted attended → NO trigger) -----
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               starts_at, ends_at, capacity, status) values
  ('c8a1c8a1-0000-0000-0000-0000000a0001','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-00000000000a','c8a1c8a1-0000-0000-0000-0000000cc001','c8a1c8a1-0000-0000-0000-0000000ee001','o1', now()-interval '10 days', now()-interval '10 days'+interval '50 min',20,'completed'),
  ('c8a1c8a1-0000-0000-0000-0000000a0002','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-00000000000a','c8a1c8a1-0000-0000-0000-0000000cc001','c8a1c8a1-0000-0000-0000-0000000ee001','o2', now()-interval '9 days',  now()-interval '9 days'+interval '50 min',20,'completed'),
  ('c8a1c8a1-0000-0000-0000-0000000a0003','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-00000000000a','c8a1c8a1-0000-0000-0000-0000000cc001','c8a1c8a1-0000-0000-0000-0000000ee001','o3comp', now()-interval '8 days',  now()-interval '8 days'+interval '50 min',20,'completed'),
  ('c8a1c8a1-0000-0000-0000-0000000a0004','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-00000000000a','c8a1c8a1-0000-0000-0000-0000000cc001','c8a1c8a1-0000-0000-0000-0000000ee001','o4', now()-interval '7 days',  now()-interval '7 days'+interval '50 min',20,'completed'),
  ('c8a1c8a1-0000-0000-0000-0000000a00c1','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-00000000000a','c8a1c8a1-0000-0000-0000-0000000cc001','c8a1c8a1-0000-0000-0000-0000000ee001','olc', now()-interval '6 days',  now()-interval '6 days'+interval '50 min',20,'completed'),
  ('c8a1c8a1-0000-0000-0000-0000000a00c2','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-00000000000a','c8a1c8a1-0000-0000-0000-0000000cc001','c8a1c8a1-0000-0000-0000-0000000ee001','ons', now()-interval '5 days',  now()-interval '5 days'+interval '50 min',20,'completed'),
  ('c8a1c8a1-0000-0000-0000-0000000a00c3','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-00000000000a','c8a1c8a1-0000-0000-0000-0000000cc001','c8a1c8a1-0000-0000-0000-0000000ee001','outside', now()-interval '20 days', now()-interval '20 days'+interval '50 min',20,'completed'),
  ('c8a1c8a1-0000-0000-0000-0000000a0005','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-00000000000a','c8a1c8a1-0000-0000-0000-0000000cc001','c8a1c8a1-0000-0000-0000-0000000ee001','o5trigger', now()-interval '1 days',  now()-interval '1 days'+interval '50 min',20,'completed');

insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source, booked_at) values
  ('c8a1c8a1-0000-0000-0000-0000000b0001','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-0000000a0001','c8a1c8a1-0000-0000-0000-0000000dd001','attended','class_pack', now()-interval '11 days'),
  ('c8a1c8a1-0000-0000-0000-0000000b0002','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-0000000a0002','c8a1c8a1-0000-0000-0000-0000000dd001','attended','class_pack', now()-interval '10 days'),
  ('c8a1c8a1-0000-0000-0000-0000000b0003','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-0000000a0003','c8a1c8a1-0000-0000-0000-0000000dd001','attended','comp',       now()-interval '9 days'),
  ('c8a1c8a1-0000-0000-0000-0000000b0004','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-0000000a0004','c8a1c8a1-0000-0000-0000-0000000dd001','attended','class_pack', now()-interval '8 days'),
  ('c8a1c8a1-0000-0000-0000-0000000b00c1','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-0000000a00c1','c8a1c8a1-0000-0000-0000-0000000dd001','late_cancelled','class_pack', now()-interval '7 days'),
  ('c8a1c8a1-0000-0000-0000-0000000b00c2','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-0000000a00c2','c8a1c8a1-0000-0000-0000-0000000dd001','no_show','class_pack', now()-interval '6 days'),
  ('c8a1c8a1-0000-0000-0000-0000000b00c3','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-0000000a00c3','c8a1c8a1-0000-0000-0000-0000000dd001','attended','class_pack', now()-interval '21 days'),
  ('c8a1c8a1-0000-0000-0000-0000000b0005','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-0000000a0005','c8a1c8a1-0000-0000-0000-0000000dd001','booked','class_pack', now()-interval '2 days');

-- --- MEM_S streak occurrences (weeks -6..0 with a gap at -2) ------------------
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               starts_at, ends_at, capacity, status) values
  ('c8a1c8a1-0000-0000-0000-0000000f0001','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-00000000000a','c8a1c8a1-0000-0000-0000-0000000cc001','c8a1c8a1-0000-0000-0000-0000000ee003','w1', now()-interval '35 days', now()-interval '35 days'+interval '50 min',20,'completed'),
  ('c8a1c8a1-0000-0000-0000-0000000f0002','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-00000000000a','c8a1c8a1-0000-0000-0000-0000000cc001','c8a1c8a1-0000-0000-0000-0000000ee003','w2', now()-interval '28 days', now()-interval '28 days'+interval '50 min',20,'completed'),
  ('c8a1c8a1-0000-0000-0000-0000000f0003','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-00000000000a','c8a1c8a1-0000-0000-0000-0000000cc001','c8a1c8a1-0000-0000-0000-0000000ee003','w3', now()-interval '21 days', now()-interval '21 days'+interval '50 min',20,'completed'),
  ('c8a1c8a1-0000-0000-0000-0000000f0005','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-00000000000a','c8a1c8a1-0000-0000-0000-0000000cc001','c8a1c8a1-0000-0000-0000-0000000ee003','w5', now()-interval '7 days',  now()-interval '7 days'+interval '50 min',20,'completed'),
  ('c8a1c8a1-0000-0000-0000-0000000f0006','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-00000000000a','c8a1c8a1-0000-0000-0000-0000000cc001','c8a1c8a1-0000-0000-0000-0000000ee003','w6', now()-interval '2 hours',  now()-interval '2 hours'+interval '50 min',20,'completed');
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source, booked_at) values
  ('c8a1c8a1-0000-0000-0000-0000000bf001','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-0000000f0001','c8a1c8a1-0000-0000-0000-0000000dd004','attended','class_pack', now()-interval '36 days'),
  ('c8a1c8a1-0000-0000-0000-0000000bf002','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-0000000f0002','c8a1c8a1-0000-0000-0000-0000000dd004','attended','class_pack', now()-interval '29 days'),
  ('c8a1c8a1-0000-0000-0000-0000000bf003','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-0000000f0003','c8a1c8a1-0000-0000-0000-0000000dd004','attended','class_pack', now()-interval '22 days'),
  ('c8a1c8a1-0000-0000-0000-0000000bf005','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-0000000f0005','c8a1c8a1-0000-0000-0000-0000000dd004','attended','class_pack', now()-interval '8 days'),
  ('c8a1c8a1-0000-0000-0000-0000000bf006','c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-0000000f0006','c8a1c8a1-0000-0000-0000-0000000dd004','attended','class_pack', now()-interval '3 hours');

-- =============================================================================
-- 1. LATE JOINER: progress counts from the challenge start (§9.2). MEM1 joins
--    having already attended four qualifying classes (one comp), one late
--    cancel, one no-show and one class before the challenge began. Only the
--    four attended-in-window count.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','c8a1c8a1-0000-0000-0000-0000000000e1',false);
select join_challenge('c8a1c8a1-0000-0000-0000-00000000c001');
select set_config('request.jwt.claim.sub','',false); reset role;

select expect_num('late joiner starts at four',
  (select progress from challenge_participants
    where challenge_id='c8a1c8a1-0000-0000-0000-00000000c001'
      and member_id='c8a1c8a1-0000-0000-0000-0000000dd001'), 4);
select expect_num('comp booking produced an event',
  (select count(*) from challenge_progress_events
    where challenge_id='c8a1c8a1-0000-0000-0000-00000000c001'
      and booking_id='c8a1c8a1-0000-0000-0000-0000000b0003'), 1);
select expect_num('late cancel counted for nothing',
  (select count(*) from challenge_progress_events
    where booking_id='c8a1c8a1-0000-0000-0000-0000000b00c1'), 0);
select expect_num('no-show counted for nothing (yet)',
  (select count(*) from challenge_progress_events
    where booking_id='c8a1c8a1-0000-0000-0000-0000000b00c2'), 0);
select expect_num('class before the start counted for nothing',
  (select count(*) from challenge_progress_events
    where booking_id='c8a1c8a1-0000-0000-0000-0000000b00c3'), 0);

-- =============================================================================
-- 2. CORRECTED NO-SHOW counts and re-evaluates (§9.1, §3.4). The trigger fires
--    on the status change and completion lands (4 → 5, goal 5).
-- =============================================================================
update bookings set status='attended' where id='c8a1c8a1-0000-0000-0000-0000000b00c2';
select expect_num('corrected no-show now counts (5)',
  (select progress from challenge_participants
    where challenge_id='c8a1c8a1-0000-0000-0000-00000000c001'
      and member_id='c8a1c8a1-0000-0000-0000-0000000dd001'), 5);
select expect_true('reaching the goal set completed_at',
  (select completed_at is not null from challenge_participants
    where challenge_id='c8a1c8a1-0000-0000-0000-00000000c001'
      and member_id='c8a1c8a1-0000-0000-0000-0000000dd001'));

-- =============================================================================
-- 3. ONE EVENT PER BOOKING. The trigger fires on a real check-in (booked →
--    attended); the event is single, and a re-fire or a hand-written duplicate
--    is refused by the unique index.
-- =============================================================================
update bookings set status='attended' where id='c8a1c8a1-0000-0000-0000-0000000b0005';
select expect_num('check-in adds exactly one event for its booking',
  (select count(*) from challenge_progress_events
    where booking_id='c8a1c8a1-0000-0000-0000-0000000b0005'), 1);
select expect_num('progress accrued to six',
  (select progress from challenge_participants
    where challenge_id='c8a1c8a1-0000-0000-0000-00000000c001'
      and member_id='c8a1c8a1-0000-0000-0000-0000000dd001'), 6);
do $$ begin
  begin
    insert into challenge_progress_events (studio_id, challenge_id, member_id, booking_id, occurrence_id, delta, occurred_at)
    values ('c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-00000000c001',
            'c8a1c8a1-0000-0000-0000-0000000dd001','c8a1c8a1-0000-0000-0000-0000000b0005',
            'c8a1c8a1-0000-0000-0000-0000000a0005',1, now());
    raise exception 'FAIL  duplicate event was allowed';
  exception when unique_violation then raise notice 'PASS  duplicate event refused by unique index';
  end;
end $$;

-- A mistaken check-in undone removes the event and re-adds it when redone.
update bookings set status='no_show' where id='c8a1c8a1-0000-0000-0000-0000000b0005';
select expect_num('undoing a check-in removes its event (back to 5)',
  (select progress from challenge_participants
    where challenge_id='c8a1c8a1-0000-0000-0000-00000000c001'
      and member_id='c8a1c8a1-0000-0000-0000-0000000dd001'), 5);
update bookings set status='attended' where id='c8a1c8a1-0000-0000-0000-0000000b0005';
select expect_num('redoing it re-adds the event (back to 6)',
  (select progress from challenge_participants
    where challenge_id='c8a1c8a1-0000-0000-0000-00000000c001'
      and member_id='c8a1c8a1-0000-0000-0000-0000000dd001'), 6);

-- =============================================================================
-- 4. RECOMPUTE IS DETERMINISTIC (§9.4). Wipe the cached progress and rebuild
--    purely from events — the answer is identical.
-- =============================================================================
update challenge_participants set progress = 999, completed_at = null
 where challenge_id='c8a1c8a1-0000-0000-0000-00000000c001'
   and member_id='c8a1c8a1-0000-0000-0000-0000000dd001';
select recompute_participant((select id from challenge_participants
  where challenge_id='c8a1c8a1-0000-0000-0000-00000000c001'
    and member_id='c8a1c8a1-0000-0000-0000-0000000dd001'));
select expect_num('recompute rebuilds the same six from events',
  (select progress from challenge_participants
    where challenge_id='c8a1c8a1-0000-0000-0000-00000000c001'
      and member_id='c8a1c8a1-0000-0000-0000-0000000dd001'), 6);
select expect_true('recompute re-derives completion',
  (select completed_at is not null from challenge_participants
    where challenge_id='c8a1c8a1-0000-0000-0000-00000000c001'
      and member_id='c8a1c8a1-0000-0000-0000-0000000dd001'));

-- =============================================================================
-- 5. STREAK RESETS TO THE CURRENT RUN (§9.5). Attended weeks -6,-5,-4 then a
--    gap then -1,0 → the current run is 2, not 5 and not zero.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','c8a1c8a1-0000-0000-0000-0000000000e4',false);
select join_challenge('c8a1c8a1-0000-0000-0000-00000000c002');
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_num('streak shows the current run of two',
  (select progress from challenge_participants
    where challenge_id='c8a1c8a1-0000-0000-0000-00000000c002'
      and member_id='c8a1c8a1-0000-0000-0000-0000000dd004'), 2);

-- =============================================================================
-- 6. LEADERBOARD invisible when off, and the OWN row always visible. MEM2 also
--    joins CH_COUNT. With the board OFF, a member reading the participant table
--    sees only their own row; with it ON, they see both. Off must still show
--    their own — the case most likely to break.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','c8a1c8a1-0000-0000-0000-0000000000e2',false);
select join_challenge('c8a1c8a1-0000-0000-0000-00000000c001');
select set_config('request.jwt.claim.sub','',false); reset role;

-- Board OFF: MEM1 sees exactly one participant row — their own.
set role authenticated; select set_config('request.jwt.claim.sub','c8a1c8a1-0000-0000-0000-0000000000e1',false);
select expect_num('board off: member sees only one participant row',
  (select count(*) from challenge_participants
    where challenge_id='c8a1c8a1-0000-0000-0000-00000000c001'), 1);
select expect_true('board off: the one row the member sees is THEIR OWN',
  (select bool_and(member_id='c8a1c8a1-0000-0000-0000-0000000dd001')
     from challenge_participants
    where challenge_id='c8a1c8a1-0000-0000-0000-00000000c001'));
select set_config('request.jwt.claim.sub','',false); reset role;

-- Turn the board ON.
update challenges set leaderboard_enabled = true
 where id='c8a1c8a1-0000-0000-0000-00000000c001';
set role authenticated; select set_config('request.jwt.claim.sub','c8a1c8a1-0000-0000-0000-0000000000e1',false);
select expect_num('board on: member sees both participants',
  (select count(*) from challenge_participants
    where challenge_id='c8a1c8a1-0000-0000-0000-00000000c001'), 2);
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- 7. TEETH — the cp_member_self hole. A member cannot post their own progress
--    or join by writing a row directly; both are now SECURITY DEFINER only.
-- =============================================================================
-- A member updating their own progress changes nothing (no member UPDATE policy).
set role authenticated; select set_config('request.jwt.claim.sub','c8a1c8a1-0000-0000-0000-0000000000e1',false);
update challenge_participants set progress = 999
 where challenge_id='c8a1c8a1-0000-0000-0000-00000000c001'
   and member_id='c8a1c8a1-0000-0000-0000-0000000dd001';
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_num('member cannot write their own progress (still 6)',
  (select progress from challenge_participants
    where challenge_id='c8a1c8a1-0000-0000-0000-00000000c001'
      and member_id='c8a1c8a1-0000-0000-0000-0000000dd001'), 6);

-- A member cannot INSERT a participant row directly (no member INSERT policy).
do $$ begin
  set role authenticated; perform set_config('request.jwt.claim.sub','c8a1c8a1-0000-0000-0000-0000000000e3',false);
  begin
    insert into challenge_participants (studio_id, challenge_id, audience, member_id, goal_value)
    values ('c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-00000000c001',
            'member','c8a1c8a1-0000-0000-0000-0000000dd003',5);
    perform set_config('request.jwt.claim.sub','',false); reset role;
    raise exception 'FAIL  member inserted a participant row directly';
  exception when insufficient_privilege or check_violation then
    perform set_config('request.jwt.claim.sub','',false); reset role;
    raise notice 'PASS  member cannot self-insert a participant row';
  end;
end $$;

-- =============================================================================
-- 8. JOINING AFTER THE DEADLINE is refused (Decision 6, §9.2).
-- =============================================================================
do $$ begin
  set role authenticated; perform set_config('request.jwt.claim.sub','c8a1c8a1-0000-0000-0000-0000000000e3',false);
  begin
    perform join_challenge('c8a1c8a1-0000-0000-0000-00000000c003');
    perform set_config('request.jwt.claim.sub','',false); reset role;
    raise exception 'FAIL  joined after the deadline';
  exception when others then
    perform set_config('request.jwt.claim.sub','',false); reset role;
    if sqlstate = 'PT409' then raise notice 'PASS  join after deadline refused (PT409)';
    else raise; end if;
  end;
end $$;

-- =============================================================================
-- 9. A STUDIO WITH NO CHALLENGES sees nothing anywhere (studio C).
-- =============================================================================
select expect_num('no-challenge studio: member sees an empty list',
  jsonb_array_length(member_challenges('c8a1c8a1-0000-0000-0000-000000000003')), 0);
select expect_true('no-challenge studio: no KPI card at all',
  (dashboard_challenge_kpi('c8a1c8a1-0000-0000-0000-000000000003') is null));
select expect_num('no-challenge studio: challenge_participation absent from the dashboard',
  (select count(*) from jsonb_array_elements(dashboard_absent_cards('c8a1c8a1-0000-0000-0000-000000000003')) e
    where e->>'key' = 'challenge_participation'), 0);
-- And the studio that DOES have challenges shows the KPI.
select expect_true('challenge studio: the KPI card is present',
  (dashboard_challenge_kpi('c8a1c8a1-0000-0000-0000-000000000001') is not null));

-- =============================================================================
-- 10. TWO STUDIOS, DIFFERENT CHALLENGES, ONE SWEEP. MEM1 joins CH_ENDING so it
--     has a participant to warn. MEM3 has no attendances, so it is not already complete.
--     B's finished challenge ends, and the ending-soon notice fires once.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','c8a1c8a1-0000-0000-0000-0000000000e3',false);
select join_challenge('c8a1c8a1-0000-0000-0000-00000000c005');
select set_config('request.jwt.claim.sub','',false); reset role;

select sweep_challenges();
select expect_true('sweep activated studio A''s scheduled challenge',
  (select status = 'active' from challenges where id='c8a1c8a1-0000-0000-0000-00000000c004'));
select expect_true('sweep ended studio B''s finished challenge',
  (select status = 'ended' from challenges where id='c8a1c8a1-0000-0000-0000-00000000c00b'));
select expect_num('ending-soon queued once for the participant',
  (select count(*) from notifications
    where template_key='challenge_ending_soon'
      and member_id='c8a1c8a1-0000-0000-0000-0000000dd003'), 1);
select sweep_challenges();
select expect_num('a second sweep sends no second ending-soon',
  (select count(*) from notifications
    where template_key='challenge_ending_soon'
      and member_id='c8a1c8a1-0000-0000-0000-0000000dd003'), 1);

-- =============================================================================
-- Teardown — scoped, self-cleaning. Notifications is a shared worker queue, so
-- this suite clears exactly its own.
-- =============================================================================
delete from notifications where studio_id in (
  'c8a1c8a1-0000-0000-0000-000000000001','c8a1c8a1-0000-0000-0000-000000000002',
  'c8a1c8a1-0000-0000-0000-000000000003');

do $$ begin raise notice 'challenges_test: all assertions passed'; end $$;
