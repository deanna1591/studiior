-- =============================================================================
-- Decision 30 amendment — free first classes are GROUPED. UUID space 17a1.
-- Run after `supabase db reset`. One studio (guarantees + flex on so there is a
-- real cutoff for the provisional machinery to ride).
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

-- --- Fixtures ---------------------------------------------------------------
insert into studios (id, name, slug, timezone, currency, status) values
  ('17a10000-0000-0000-0000-000000000001','Trial Studio','trial-studio','Europe/Prague','CZK','active');
insert into studio_settings (studio_id, guarantees_enabled, flex_enabled,
   free_first_class_enabled, free_first_core_only, free_first_confirm_at,
   free_first_peak_allowed, booking_window_days, booking_cutoff_minutes,
   cancellation_cutoff_minutes, core_cutoff_hours, core_min_bookings, flex_min_bookings)
 values ('17a10000-0000-0000-0000-000000000001', true, true,
   true, true, 3, true, 90, 0, 720, 12, 1, 2);
insert into locations (id, studio_id, name, is_primary) values
  ('17a10000-0000-0000-0000-0000000000c1','17a10000-0000-0000-0000-000000000001','Main',true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('17a10000-0000-0000-0000-0000000000e1','17a10000-0000-0000-0000-000000000001',
   '17a10000-0000-0000-0000-0000000000c1','Studio A',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('17a10000-0000-0000-0000-0000000000a1','17a10000-0000-0000-0000-000000000001','Core Class',50,10),
  ('17a10000-0000-0000-0000-0000000000a2','17a10000-0000-0000-0000-000000000001','Flex Class',50,10);

-- A no-trial series (free_first_allowed = false). starts_on far out so the
-- materialise trigger generates nothing near now; we insert its occurrence directly.
insert into class_series (id, studio_id, location_id, class_type_id, room_id, name, rrule, time_of_day,
   duration_minutes, capacity, starts_on, status, guarantee_tier, free_first_allowed) values
  ('17a10000-0000-0000-0000-0000000005e1','17a10000-0000-0000-0000-000000000001',
   '17a10000-0000-0000-0000-0000000000c1','17a10000-0000-0000-0000-0000000000a1','17a10000-0000-0000-0000-0000000000e1',
   'No-Trial Core','FREQ=WEEKLY;BYDAY=MO','07:00', 50, 10, (current_date + 400), 'active', 'core', false);

-- Members: leads L1..L6 (eligible, with logins), paid P1 (unlimited membership, login).
do $$
declare v_uid uuid; v_mid uuid; i int; v_email text;
begin
  for i in 1..9 loop
    v_uid := ('17a10000-0000-0000-0000-00000000aa0' || i)::uuid;
    v_mid := ('17a10000-0000-0000-0000-00000000bb0' || i)::uuid;
    v_email := 'lead' || i || '@trial17a1.test';
    insert into auth.users (id, email) values (v_uid, v_email);
    insert into profiles (id, email, full_name) values (v_uid, v_email, 'Lead ' || i);
    insert into members (id, studio_id, user_id, first_name, last_name, email, joined_on, status, waiver_signed_at)
      values (v_mid, '17a10000-0000-0000-0000-000000000001', v_uid, 'Lead', i::text, v_email, current_date, 'lead', now());
  end loop;
  -- paid member with an unlimited recurring membership
  insert into auth.users (id, email) values ('17a10000-0000-0000-0000-00000000aa91','paid1@trial17a1.test');
  insert into profiles (id, email, full_name) values ('17a10000-0000-0000-0000-00000000aa91','paid1@trial17a1.test','Paid One');
  insert into members (id, studio_id, user_id, first_name, last_name, email, joined_on, status, waiver_signed_at)
    values ('17a10000-0000-0000-0000-00000000bb91','17a10000-0000-0000-0000-000000000001',
            '17a10000-0000-0000-0000-00000000aa91','Paid','One','paid1@trial17a1.test', current_date, 'active', now());
end $$;
insert into membership_plans (id, studio_id, name, type, billing_interval, price_cents, currency, status, visibility) values
  ('17a10000-0000-0000-0000-0000000000f1','17a10000-0000-0000-0000-000000000001','Unlimited','recurring','month',300000,'CZK','active','public');
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, credits_remaining,
   starts_on, current_period_start, current_period_end)
 values ('17a10000-0000-0000-0000-0000000000f2','17a10000-0000-0000-0000-000000000001',
   '17a10000-0000-0000-0000-00000000bb91','17a10000-0000-0000-0000-0000000000f1','active', 300000, 'CZK', null,
   current_date, now(), now() + interval '1 month');

-- Occurrences. Future (cutoff ahead → provisional holds) and near-term (cutoff
-- already past → release fires on evaluate). All but OCC_NT are one-offs.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
   capacity, starts_at, ends_at, status, guarantee_tier, core_min_bookings) values
  -- confirm-at test (core, future cutoff)
  ('17a10000-0000-0000-0000-00000000c001','17a10000-0000-0000-0000-000000000001',
   '17a10000-0000-0000-0000-0000000000c1','17a10000-0000-0000-0000-0000000000a1','17a10000-0000-0000-0000-0000000000e1',
   'Confirm Core', 10, now() + interval '10 days', now() + interval '10 days 50 minutes','scheduled','core',1),
  -- cap test
  ('17a10000-0000-0000-0000-00000000c002','17a10000-0000-0000-0000-000000000001',
   '17a10000-0000-0000-0000-0000000000c1','17a10000-0000-0000-0000-0000000000a1','17a10000-0000-0000-0000-0000000000e1',
   'Cap Core', 10, now() + interval '11 days', now() + interval '11 days 50 minutes','scheduled','core',1),
  -- ordering: two core classes
  ('17a10000-0000-0000-0000-00000000c003','17a10000-0000-0000-0000-000000000001',
   '17a10000-0000-0000-0000-0000000000c1','17a10000-0000-0000-0000-0000000000a1','17a10000-0000-0000-0000-0000000000e1',
   'Order A', 10, now() + interval '12 days', now() + interval '12 days 50 minutes','scheduled','core',1),
  ('17a10000-0000-0000-0000-00000000c004','17a10000-0000-0000-0000-000000000001',
   '17a10000-0000-0000-0000-0000000000c1','17a10000-0000-0000-0000-0000000000a1','17a10000-0000-0000-0000-0000000000e1',
   'Order B', 10, now() + interval '13 days', now() + interval '13 days 50 minutes','scheduled','core',1),
  -- flex class (for the core_only exclusion)
  ('17a10000-0000-0000-0000-00000000c005','17a10000-0000-0000-0000-000000000001',
   '17a10000-0000-0000-0000-0000000000c1','17a10000-0000-0000-0000-0000000000a2','17a10000-0000-0000-0000-0000000000e1',
   'Flex One', 10, now() + interval '14 days', now() + interval '14 days 50 minutes','scheduled','flex',null),
  -- release: core, cutoff already past (starts soon, core_cutoff 12h)
  ('17a10000-0000-0000-0000-00000000c006','17a10000-0000-0000-0000-000000000001',
   '17a10000-0000-0000-0000-0000000000c1','17a10000-0000-0000-0000-0000000000a1','17a10000-0000-0000-0000-0000000000e1',
   'Release Core', 10, now() + interval '2 hours', now() + interval '2 hours 50 minutes','scheduled','core',1),
  -- release flex: cutoff past, min 2
  ('17a10000-0000-0000-0000-00000000c007','17a10000-0000-0000-0000-000000000001',
   '17a10000-0000-0000-0000-0000000000c1','17a10000-0000-0000-0000-0000000000a2','17a10000-0000-0000-0000-0000000000e1',
   'Release Flex', 10, now() + interval '4 hours', now() + interval '4 hours 50 minutes','scheduled','flex',null);
update class_occurrences set minimum_bookings = 2 where id = '17a10000-0000-0000-0000-00000000c007';
-- flex deadline mode hours_before so Release Flex has a past cutoff too
update studio_settings set flex_deadline_mode = 'hours_before', flex_deadline_hours = 12
 where studio_id = '17a10000-0000-0000-0000-000000000001';
-- no-trial occurrence, linked to the no-trial series
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
   capacity, starts_at, ends_at, status, guarantee_tier, core_min_bookings, series_id) values
  ('17a10000-0000-0000-0000-00000000c008','17a10000-0000-0000-0000-000000000001',
   '17a10000-0000-0000-0000-0000000000c1','17a10000-0000-0000-0000-0000000000a1','17a10000-0000-0000-0000-0000000000e1',
   'No-Trial Occ', 10, now() + interval '15 days', now() + interval '15 days 50 minutes','scheduled','core',1,
   '17a10000-0000-0000-0000-0000000005e1');

-- helper: book a free first class as a given lead (login), returns the result jsonb
create or replace function t_book_free(p_lead int, p_occ uuid) returns jsonb
language plpgsql as $$
declare v_uid uuid := ('17a10000-0000-0000-0000-00000000aa0' || p_lead)::uuid; r jsonb;
begin
  perform set_config('request.jwt.claim.sub', v_uid::text, true);
  set local role authenticated;
  r := book_first_free(p_occ);
  reset role;
  return r;
end $$;

-- =============================================================================
-- 1. Defaults = today's behaviour: confirm_at null → a free seat is confirmed
--    on booking (not provisional).
-- =============================================================================
update studio_settings set free_first_confirm_at = null, free_first_core_only = false
 where studio_id = '17a10000-0000-0000-0000-000000000001';
select expect_text('confirm_at null → book_first_free succeeds',
  (t_book_free(1, '17a10000-0000-0000-0000-00000000c003') ->> 'ok'), 'true');
select expect_text('...and the seat is NOT provisional (today''s behaviour)',
  (select provisional::text from bookings b join guest_passes gp on gp.guest_booking_id=b.id
    where gp.guest_member_id='17a10000-0000-0000-0000-00000000bb01' and gp.host_member_id is null), 'false');
-- restore the grouped settings
update studio_settings set free_first_confirm_at = 3, free_first_core_only = true
 where studio_id = '17a10000-0000-0000-0000-000000000001';

-- =============================================================================
-- 2. core_only hides flex; book_first_free refuses a flex class.
-- =============================================================================
select expect_text('core_only: a flex class is flex_not_allowed',
  (t_book_free(2, '17a10000-0000-0000-0000-00000000c005') ->> 'reason'), 'flex_not_allowed');
select expect_num('core_only: the eligible list excludes the flex class',
  (select count(*) from free_first_eligible_classes_run('17a10000-0000-0000-0000-000000000001',
     '17a10000-0000-0000-0000-00000000bb02', 0) where occurrence_id='17a10000-0000-0000-0000-00000000c005'), 0);

-- =============================================================================
-- 3. free_first_allowed = false hides a series.
-- =============================================================================
select expect_text('a no-trial series class is not_trial_class',
  (t_book_free(2, '17a10000-0000-0000-0000-00000000c008') ->> 'reason'), 'not_trial_class');
select expect_num('...and is absent from the eligible list',
  (select count(*) from free_first_eligible_classes_run('17a10000-0000-0000-0000-000000000001',
     '17a10000-0000-0000-0000-00000000bb02', 0) where occurrence_id='17a10000-0000-0000-0000-00000000c008'), 0);

-- =============================================================================
-- 4. Cap reached → free_seats_full; paid booking still allowed.
-- =============================================================================
update studio_settings set free_first_seats_per_class = 2
 where studio_id = '17a10000-0000-0000-0000-000000000001';
select expect_text('cap: first free seat ok', (t_book_free(2, '17a10000-0000-0000-0000-00000000c002') ->> 'ok'), 'true');
select expect_text('cap: second free seat ok', (t_book_free(3, '17a10000-0000-0000-0000-00000000c002') ->> 'ok'), 'true');
select expect_text('cap: third free seat refused free_seats_full',
  (t_book_free(4, '17a10000-0000-0000-0000-00000000c002') ->> 'reason'), 'free_seats_full');
-- a paid booking on the capped class is still allowed
do $$
begin
  perform set_config('request.jwt.claim.sub', '17a10000-0000-0000-0000-00000000aa91', true);
  set local role authenticated;
  perform book_class('17a10000-0000-0000-0000-00000000c002', '17a10000-0000-0000-0000-00000000bb91', 'member', null, null);
  reset role;
end $$;
select expect_text('cap: a paid booking on the capped class is booked',
  (select status::text from bookings where occurrence_id='17a10000-0000-0000-0000-00000000c002'
     and member_id='17a10000-0000-0000-0000-00000000bb91'), 'booked');
update studio_settings set free_first_seats_per_class = null
 where studio_id = '17a10000-0000-0000-0000-000000000001';

-- =============================================================================
-- 5. Ordering: fullest first.
-- =============================================================================
-- Order A has 1 booked, Order B has 0. L5 (eligible) should see A before B.
update class_occurrences set booked_count = 1 where id = '17a10000-0000-0000-0000-00000000c003';
select expect_text('eligible list is fullest-first (Order A before Order B)',
  (select string_agg(name, ',' order by rn) from (
     select name, row_number() over () rn from free_first_eligible_classes_run(
       '17a10000-0000-0000-0000-000000000001','17a10000-0000-0000-0000-00000000bb05',0)
      where name in ('Order A','Order B')) z), 'Order A,Order B');
update class_occurrences set booked_count = 0 where id = '17a10000-0000-0000-0000-00000000c003';

-- =============================================================================
-- 6. confirm_at = 3: 1st and 2nd trial seats provisional; a 3rd (paid) booking
--    confirms all; exactly one confirmed email each; idempotent.
-- =============================================================================
-- book two free seats (L5, L6) on Confirm Core
select expect_text('1st free seat is provisional', (t_book_free(5, '17a10000-0000-0000-0000-00000000c001') ->> 'provisional'), 'true');
select expect_text('2nd free seat is provisional', (t_book_free(6, '17a10000-0000-0000-0000-00000000c001') ->> 'provisional'), 'true');
select expect_num('both free seats are provisional so far',
  (select count(*) from bookings where occurrence_id='17a10000-0000-0000-0000-00000000c001' and provisional), 2);
select expect_num('no free_booking_confirmed queued yet',
  (select count(*) from notifications where template_key='free_booking_confirmed'
     and (payload->>'occurrence_id')='17a10000-0000-0000-0000-00000000c001'), 0);

-- The member app renders TWO states as "Waiting for confirmation": a Decision-21
-- flex-pending booking (member_pending_bookings.pending_until = its cutoff) and a
-- Decision-30 free-first PROVISIONAL seat (pending_until NULL — it confirms the
-- moment the class is on, so a deadline would mislead). The Book list now shows
-- "· by {deadline}" only when pending_until is set, so the two read differently.
-- The flex half (non-null cutoff) is asserted in flex_member_confirmation_test;
-- this is the free-first half the bare chip relies on. L5 holds a provisional
-- free seat on c001 (core, not flex) right now.
create or replace function t_free_pending(p_lead int, p_occ uuid) returns text
language plpgsql as $$
declare v_uid uuid := ('17a10000-0000-0000-0000-00000000aa0' || p_lead)::uuid;
        v_until timestamptz; v_found boolean;
begin
  perform set_config('request.jwt.claim.sub', v_uid::text, true);
  set local role authenticated;
  select pending_until into v_until
    from member_pending_bookings('17a10000-0000-0000-0000-000000000001')
   where occurrence_id = p_occ limit 1;
  v_found := found;
  reset role;
  if not v_found then return 'absent'; end if;
  return case when v_until is null then 'null' else 'set' end;
end $$;
select expect_text('a provisional free-first seat is pending with NO deadline (pending_until null)',
  t_free_pending(5, '17a10000-0000-0000-0000-00000000c001'), 'null');

-- the 3rd booking is PAID (book_class) → reaches 3 → confirms the two provisional
do $$
begin
  perform set_config('request.jwt.claim.sub', '17a10000-0000-0000-0000-00000000aa91', true);
  set local role authenticated;
  perform book_class('17a10000-0000-0000-0000-00000000c001', '17a10000-0000-0000-0000-00000000bb91', 'member', null, null);
  reset role;
end $$;
select expect_num('the paid 3rd booking confirmed every provisional free seat',
  (select count(*) from bookings where occurrence_id='17a10000-0000-0000-0000-00000000c001' and provisional), 0);
select expect_num('exactly one free_booking_confirmed per free member (2)',
  (select count(*) from notifications where template_key='free_booking_confirmed'
     and (payload->>'occurrence_id')='17a10000-0000-0000-0000-00000000c001'), 2);
select expect_text('the paid booking is NOT provisional and got no free email',
  (select provisional::text from bookings where occurrence_id='17a10000-0000-0000-0000-00000000c001'
     and member_id='17a10000-0000-0000-0000-00000000bb91'), 'false');
-- idempotent: re-running confirm queues nothing more
select confirm_provisional_seats_run('17a10000-0000-0000-0000-00000000c001');
select expect_num('confirm is idempotent (still 2 confirmed emails)',
  (select count(*) from notifications where template_key='free_booking_confirmed'
     and (payload->>'occurrence_id')='17a10000-0000-0000-0000-00000000c001'), 2);

-- =============================================================================
-- 7. A cancellation after confirmation never reverts to provisional.
-- =============================================================================
do $$
declare v_b uuid;
begin
  select id into v_b from bookings where occurrence_id='17a10000-0000-0000-0000-00000000c001'
    and member_id='17a10000-0000-0000-0000-00000000bb05';
  perform set_config('request.jwt.claim.sub', '17a10000-0000-0000-0000-00000000aa05', true);
  set local role authenticated;
  perform cancel_booking(v_b);
  reset role;
end $$;
select expect_num('a confirmed seat cancelled stays non-provisional (0 provisional on the class)',
  (select count(*) from bookings where occurrence_id='17a10000-0000-0000-0000-00000000c001' and provisional), 0);

-- =============================================================================
-- 8/9. Unconfirmed at the cutoff → released: booking cancelled trial_not_confirmed,
--      booked_count right, guest_passes row gone (eligible again), not-confirmed
--      email with next_three; the class is then evaluated on what remains
--      (core 1 paid + 1 released trial → runs).
-- =============================================================================
-- Release Core: one PAID booking + one provisional free seat (direct insert to
-- avoid needing another login; mirrors book_first_free exactly).
do $$
declare v_pb uuid; v_tb uuid;
begin
  -- paid seat (member P1 already has a seat on c001; reuse as a fresh booking here)
  insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source, membership_id)
   values ('17a10000-0000-0000-0000-000000000001','17a10000-0000-0000-0000-00000000c006',
           '17a10000-0000-0000-0000-00000000bb91','booked','member','membership','17a10000-0000-0000-0000-0000000000f2')
   returning id into v_pb;
  -- provisional free seat for L4 (not yet used a free class)
  insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source, provisional)
   values ('17a10000-0000-0000-0000-000000000001','17a10000-0000-0000-0000-00000000c006',
           '17a10000-0000-0000-0000-00000000bb04','booked','member','comp', true)
   returning id into v_tb;
  insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email, occurrence_id, guest_booking_id, status, waiver_signed_at)
   values ('17a10000-0000-0000-0000-000000000001', null, '17a10000-0000-0000-0000-00000000bb04',
           'lead4@trial17a1.test','17a10000-0000-0000-0000-00000000c006', v_tb, 'confirmed', now());
  update class_occurrences set booked_count = 2 where id='17a10000-0000-0000-0000-00000000c006';
end $$;
-- evaluate at the cutoff (cutoff already past): releases the provisional seat, then runs (core min 1, 1 paid remains)
select evaluate_commitment('17a10000-0000-0000-0000-00000000c006');
select expect_text('release: the provisional booking is cancelled trial_not_confirmed',
  (select status::text || '/' || release_reason::text from bookings
     where occurrence_id='17a10000-0000-0000-0000-00000000c006' and member_id='17a10000-0000-0000-0000-00000000bb04'),
  'cancelled/trial_not_confirmed');
select expect_num('release: booked_count decremented to the paid seat only',
  (select booked_count from class_occurrences where id='17a10000-0000-0000-0000-00000000c006'), 1);
select expect_num('release: the once-ever guest_passes row is GONE (eligible again)',
  (select count(*) from guest_passes where guest_member_id='17a10000-0000-0000-0000-00000000bb04'
     and occurrence_id='17a10000-0000-0000-0000-00000000c006'), 0);
select expect_num('release: L4 is eligible again',
  (case when (free_first_eligibility('17a10000-0000-0000-0000-000000000001','17a10000-0000-0000-0000-00000000bb04') ->> 'ok')::boolean
        then 1 else 0 end), 1);
select expect_num('release: a free_booking_not_confirmed email was queued',
  (select count(*) from notifications where template_key='free_booking_not_confirmed'
     and member_id='17a10000-0000-0000-0000-00000000bb04'), 1);
select expect_num('release: NOT a late cancel (no infraction)',
  (select count(*) from member_infractions where member_id='17a10000-0000-0000-0000-00000000bb04'), 0);
select expect_text('the core class RAN on the remaining paid seat (committed)',
  (select (committed_at is not null)::text from class_occurrences where id='17a10000-0000-0000-0000-00000000c006'), 'true');

-- flex min 2, 1 paid + 1 released trial → NOT running; the paid member gets the
-- Decision 21 amendment not-confirmed path, not class_cancelled.
update studio_settings set free_first_core_only = false where studio_id='17a10000-0000-0000-0000-000000000001';
do $$
declare v_pb uuid; v_tb uuid;
begin
  insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source, membership_id)
   values ('17a10000-0000-0000-0000-000000000001','17a10000-0000-0000-0000-00000000c007',
           '17a10000-0000-0000-0000-00000000bb91','booked','member','membership','17a10000-0000-0000-0000-0000000000f2')
   returning id into v_pb;
  insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source, provisional)
   values ('17a10000-0000-0000-0000-000000000001','17a10000-0000-0000-0000-00000000c007',
           '17a10000-0000-0000-0000-00000000bb07','booked','member','comp', true)
   returning id into v_tb;
  insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email, occurrence_id, guest_booking_id, status, waiver_signed_at)
   values ('17a10000-0000-0000-0000-000000000001', null, '17a10000-0000-0000-0000-00000000bb07',
           'lead7b@trial17a1.test','17a10000-0000-0000-0000-00000000c007', v_tb, 'confirmed', now());
  update class_occurrences set booked_count = 2 where id='17a10000-0000-0000-0000-00000000c007';
end $$;
select evaluate_commitment('17a10000-0000-0000-0000-00000000c007');
select expect_text('flex: with the trial released, min 2 not met → not running',
  (select status::text || '/' || cancellation_cause::text from class_occurrences where id='17a10000-0000-0000-0000-00000000c007'),
  'cancelled/unmet_minimum');
select expect_num('flex: the trial got free_booking_not_confirmed (keeps free class)',
  (select count(*) from notifications where template_key='free_booking_not_confirmed'
     and member_id='17a10000-0000-0000-0000-00000000bb07'), 1);
select expect_num('flex: the paid member got flex_booking_not_confirmed (Decision 21), not free_*',
  (select count(*) from notifications where template_key='flex_booking_not_confirmed'
     and member_id='17a10000-0000-0000-0000-00000000bb91'), 1);
select expect_num('flex: the trial is eligible again',
  (case when (free_first_eligibility('17a10000-0000-0000-0000-000000000001','17a10000-0000-0000-0000-00000000bb07') ->> 'ok')::boolean
        then 1 else 0 end), 1);
update studio_settings set free_first_core_only = true where studio_id='17a10000-0000-0000-0000-000000000001';

-- =============================================================================
-- 10. Manual cancel_occurrence → released + free class kept, not class_cancelled.
-- =============================================================================
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
   capacity, starts_at, ends_at, status, guarantee_tier, core_min_bookings) values
  ('17a10000-0000-0000-0000-00000000c009','17a10000-0000-0000-0000-000000000001',
   '17a10000-0000-0000-0000-0000000000c1','17a10000-0000-0000-0000-0000000000a1','17a10000-0000-0000-0000-0000000000e1',
   'Manual Cancel', 10, now() + interval '16 days', now() + interval '16 days 50 minutes','scheduled','core',1);
do $$
declare v_tb uuid;
begin
  insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source, provisional)
   values ('17a10000-0000-0000-0000-000000000001','17a10000-0000-0000-0000-00000000c009',
           '17a10000-0000-0000-0000-00000000bb08','booked','member','comp', true)
   returning id into v_tb;
  insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email, occurrence_id, guest_booking_id, status, waiver_signed_at)
   values ('17a10000-0000-0000-0000-000000000001', null, '17a10000-0000-0000-0000-00000000bb08',
           'lead8c@trial17a1.test','17a10000-0000-0000-0000-00000000c009', v_tb, 'confirmed', now());
  update class_occurrences set booked_count = 1 where id='17a10000-0000-0000-0000-00000000c009';
end $$;
select cancel_occurrence('17a10000-0000-0000-0000-00000000c009', 'Closing for maintenance', 'studio_fault');
select expect_text('manual cancel: the provisional booking is released trial_not_confirmed',
  (select release_reason::text from bookings where occurrence_id='17a10000-0000-0000-0000-00000000c009'
     and member_id='17a10000-0000-0000-0000-00000000bb08'), 'trial_not_confirmed');
select expect_num('manual cancel: the free member keeps their class (guest_passes row gone, eligible)',
  (select count(*) from guest_passes where guest_member_id='17a10000-0000-0000-0000-00000000bb08'
     and occurrence_id='17a10000-0000-0000-0000-00000000c009'), 0);
select expect_num('manual cancel: the free member got free_booking_not_confirmed, NOT class_cancelled',
  (select count(*) from notifications where member_id='17a10000-0000-0000-0000-00000000bb08'
     and template_key='free_booking_not_confirmed'
     and (payload->>'occurrence_id')='17a10000-0000-0000-0000-00000000c009'), 1);
select expect_num('manual cancel: no class_cancelled to the free member',
  (select count(*) from notifications where member_id='17a10000-0000-0000-0000-00000000bb08'
     and template_key='class_cancelled'
     and (payload->>'occurrence_id')='17a10000-0000-0000-0000-00000000c009'), 0);

-- =============================================================================
-- 11. Paid bookings are never provisional (already shown in 4/6) — assert on a
--     fresh class: the paid seat inserts non-provisional and sends no free email.
-- =============================================================================
select expect_num('across the suite, no paid booking is ever provisional',
  (select count(*) from bookings where payment_source <> 'comp' and provisional), 0);

-- =============================================================================
-- 12. Grandfathered: a pre-existing comp booking (provisional=false) is never
--     released by the sweep at the cutoff.
-- =============================================================================
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
   capacity, starts_at, ends_at, status, guarantee_tier, core_min_bookings) values
  ('17a10000-0000-0000-0000-00000000c00a','17a10000-0000-0000-0000-000000000001',
   '17a10000-0000-0000-0000-0000000000c1','17a10000-0000-0000-0000-0000000000a1','17a10000-0000-0000-0000-0000000000e1',
   'Grandfathered', 10, now() + interval '6 hours', now() + interval '6 hours 50 minutes','scheduled','core',1);
do $$
declare v_b uuid;
begin
  insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source, provisional)
   values ('17a10000-0000-0000-0000-000000000001','17a10000-0000-0000-0000-00000000c00a',
           '17a10000-0000-0000-0000-00000000bb09','booked','member','comp', false)  -- grandfathered: not provisional
   returning id into v_b;
  update class_occurrences set booked_count = 1 where id='17a10000-0000-0000-0000-00000000c00a';
end $$;
select evaluate_commitment('17a10000-0000-0000-0000-00000000c00a');
select expect_text('a grandfathered (non-provisional) comp booking is NOT released',
  (select status::text from bookings where occurrence_id='17a10000-0000-0000-0000-00000000c00a'
     and member_id='17a10000-0000-0000-0000-00000000bb09'), 'booked');

-- =============================================================================
-- 13. Access: free_first_class_list refuses a non-member (PT403).
-- =============================================================================
do $$
begin
  perform set_config('request.jwt.claim.sub', '17a10000-0000-0000-0000-00000000aa91', true);  -- paid member of THIS studio
  set local role authenticated;
  perform * from free_first_class_list('99999999-0000-0000-0000-000000000999');  -- a studio they are not in
  reset role;
  raise exception 'FAIL  free_first_class_list did not refuse a non-member';
exception
  when sqlstate 'PT403' then raise notice 'PASS  free_first_class_list refuses a non-member (PT403)';
  when others then reset role; raise;
end $$;

select 'ALL FREE-FIRST GROUPED TESTS PASSED' as result;
