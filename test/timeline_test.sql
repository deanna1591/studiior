-- =============================================================================
-- STUDIIOR — MEMBER JOURNEY TIMELINE (migration 021)
--
-- The timeline is derived, so the guarantees are about derivation: it says the
-- same thing as its sources, rebuilding twice leaves one copy rather than two,
-- and nobody outside the studio can make it run.
--
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -f test/timeline_test.sql
-- =============================================================================

\set ON_ERROR_STOP on
set client_min_messages = notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then
    raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else
    raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null');
  end if;
end $$;

create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then
    raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else
    raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null');
  end if;
end $$;

-- --- Fixtures --------------------------------------------------------------
-- Disjoint from every other suite: 4444 here, 5555 importer, 6666 health,
-- 8888 onboarding, 1111 seed.

insert into auth.users (id) values
  ('44444444-0000-0000-0000-0000000000a1'),   -- owner of the studio under test
  ('44444444-0000-0000-0000-0000000000a2'),   -- front desk, same studio
  ('44444444-0000-0000-0000-0000000000a3');   -- owner of a different studio
insert into profiles (id, email) values
  ('44444444-0000-0000-0000-0000000000a1','tl-owner@example.com'),
  ('44444444-0000-0000-0000-0000000000a2','tl-desk@example.com'),
  ('44444444-0000-0000-0000-0000000000a3','tl-stranger@example.com');

insert into studios (id, name, slug, timezone, currency, status) values
  ('44444444-0000-0000-0000-000000000001','Timeline Studio','timeline-test','Europe/Prague','CZK','active'),
  ('44444444-0000-0000-0000-000000000002','Elsewhere','timeline-other','Europe/Prague','CZK','active');
insert into studio_settings (studio_id) values
  ('44444444-0000-0000-0000-000000000001'),
  ('44444444-0000-0000-0000-000000000002');
insert into locations (id, studio_id, name) values
  ('44444444-0000-0000-0000-00000000000c','44444444-0000-0000-0000-000000000001','Main');
insert into studio_staff (studio_id, user_id, email, role) values
  ('44444444-0000-0000-0000-000000000001','44444444-0000-0000-0000-0000000000a1','tl-owner@example.com','owner'),
  ('44444444-0000-0000-0000-000000000001','44444444-0000-0000-0000-0000000000a2','tl-desk@example.com','front_desk'),
  ('44444444-0000-0000-0000-000000000002','44444444-0000-0000-0000-0000000000a3','tl-stranger@example.com','owner');

insert into rooms (id, studio_id, location_id, name, capacity) values
  ('44444444-0000-0000-0000-00000000ee01','44444444-0000-0000-0000-000000000001',
   '44444444-0000-0000-0000-00000000000c','Studio A',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('44444444-0000-0000-0000-00000000cc01','44444444-0000-0000-0000-000000000001','Reformer',50,10);
insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, validity_days) values
  ('44444444-0000-0000-0000-00000000aa01','44444444-0000-0000-0000-000000000001',
   '5-Class Pack','class_pack',250000,'CZK',5,90);

insert into members (id, studio_id, first_name, last_name, email, joined_on, source) values
  ('44444444-0000-0000-0000-00000000dd01','44444444-0000-0000-0000-000000000001',
   'Tilda','Timeline','tilda@example.com', current_date - 200, 'referral');

insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name, starts_at, ends_at, capacity, status)
values
  ('44444444-0000-0000-0000-00000000bb01','44444444-0000-0000-0000-000000000001',
   '44444444-0000-0000-0000-00000000000c',
   '44444444-0000-0000-0000-00000000cc01','44444444-0000-0000-0000-00000000ee01',
   'Reformer Flow', now() - interval '10 days', now() - interval '10 days' + interval '50 min', 10, 'completed'),
  ('44444444-0000-0000-0000-00000000bb02','44444444-0000-0000-0000-000000000001',
   '44444444-0000-0000-0000-00000000000c',
   '44444444-0000-0000-0000-00000000cc01','44444444-0000-0000-0000-00000000ee01',
   'Reformer Flow', now() - interval '3 days', now() - interval '3 days' + interval '50 min', 10, 'completed');

-- Two bookings: one attended with a check-in, one cancelled. The cancelled one
-- is the reason `booked` is not emitted — it is already a story on its own.
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source, booked_at)
values
  ('44444444-0000-0000-0000-00000000fb01','44444444-0000-0000-0000-000000000001',
   '44444444-0000-0000-0000-00000000bb01','44444444-0000-0000-0000-00000000dd01',
   'attended','class_pack', now() - interval '12 days'),
  ('44444444-0000-0000-0000-00000000fb02','44444444-0000-0000-0000-000000000001',
   '44444444-0000-0000-0000-00000000bb02','44444444-0000-0000-0000-00000000dd01',
   'late_cancelled','class_pack', now() - interval '5 days');
update bookings set cancelled_at = now() - interval '3 days', is_late_cancel = true
 where id = '44444444-0000-0000-0000-00000000fb02';

insert into check_ins (studio_id, booking_id, member_id, occurrence_id, checked_in_at, method)
values ('44444444-0000-0000-0000-000000000001','44444444-0000-0000-0000-00000000fb01',
        '44444444-0000-0000-0000-00000000dd01','44444444-0000-0000-0000-00000000bb01',
        now() - interval '10 days', 'staff');

insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on, credits_remaining)
values ('44444444-0000-0000-0000-00000000fa01','44444444-0000-0000-0000-000000000001',
        '44444444-0000-0000-0000-00000000dd01','44444444-0000-0000-0000-00000000aa01',
        'active', 250000, 'CZK', current_date - 30, 4);

insert into payments (studio_id, member_id, amount_cents, currency, status, description, paid_at)
values ('44444444-0000-0000-0000-000000000001','44444444-0000-0000-0000-00000000dd01',
        250000,'CZK','succeeded','5-Class Pack', now() - interval '30 days');

-- =============================================================================
-- 1. It derives what the sources say, and nothing else
-- =============================================================================

set role authenticated;
select set_config('request.jwt.claim.sub','44444444-0000-0000-0000-0000000000a1',false);

select expect_num('rebuild writes one event per source fact',
  rebuild_member_timeline('44444444-0000-0000-0000-00000000dd01')::bigint, 5);
reset role;

select expect_num('one joined event',
  (select count(*) from timeline_events where member_id='44444444-0000-0000-0000-00000000dd01' and type='joined'), 1);
select expect_num('one attended, from the check-in rather than the booking',
  (select count(*) from timeline_events where member_id='44444444-0000-0000-0000-00000000dd01' and type='attended'), 1);
select expect_num('one cancelled',
  (select count(*) from timeline_events where member_id='44444444-0000-0000-0000-00000000dd01' and type='cancelled'), 1);
select expect_num('one payment',
  (select count(*) from timeline_events where member_id='44444444-0000-0000-0000-00000000dd01' and type='payment'), 1);
select expect_num('one membership change',
  (select count(*) from timeline_events where member_id='44444444-0000-0000-0000-00000000dd01' and type='membership_changed'), 1);

-- Emitting `booked` as well would tell the attended class twice and the
-- cancelled one twice. Asserted rather than assumed, because it is a choice.
select expect_num('no booked events, deliberately',
  (select count(*) from timeline_events where member_id='44444444-0000-0000-0000-00000000dd01' and type='booked'), 0);

select expect_text('the joined event says where they came from',
  (select description from timeline_events where member_id='44444444-0000-0000-0000-00000000dd01' and type='joined'),
  'Came via referral');
select expect_text('a late cancel says so',
  (select title from timeline_events where member_id='44444444-0000-0000-0000-00000000dd01' and type='cancelled'),
  'Cancelled late');
select expect_text('the attended event carries the class name',
  (select title from timeline_events where member_id='44444444-0000-0000-0000-00000000dd01' and type='attended'),
  'Reformer Flow');
select expect_num('the payment event carries the amount, so the screen need not re-query',
  (select (metadata ->> 'amount_cents')::bigint from timeline_events
    where member_id='44444444-0000-0000-0000-00000000dd01' and type='payment'), 250000);

-- =============================================================================
-- 2. Replayable — the property §4 asks for
-- =============================================================================

set role authenticated;
select set_config('request.jwt.claim.sub','44444444-0000-0000-0000-0000000000a1',false);
select expect_num('rebuilding again gives the same count, not double',
  rebuild_member_timeline('44444444-0000-0000-0000-00000000dd01')::bigint, 5);
reset role;
select expect_num('and there is still exactly one joined event',
  (select count(*) from timeline_events where member_id='44444444-0000-0000-0000-00000000dd01' and type='joined'), 1);

-- A new fact appears in the timeline on the next rebuild, because nothing here
-- is stored independently of its source.
insert into payments (studio_id, member_id, amount_cents, currency, status, description, paid_at)
values ('44444444-0000-0000-0000-000000000001','44444444-0000-0000-0000-00000000dd01',
        65000,'CZK','failed','Drop-in class', now() - interval '1 day');
set role authenticated;
select set_config('request.jwt.claim.sub','44444444-0000-0000-0000-0000000000a1',false);
select expect_num('a new payment appears on the next rebuild',
  rebuild_member_timeline('44444444-0000-0000-0000-00000000dd01')::bigint, 6);
reset role;
select expect_text('and a failed one is not called a payment received',
  (select title from timeline_events
    where member_id='44444444-0000-0000-0000-00000000dd01' and type='payment'
      and (metadata ->> 'status') = 'failed'),
  'Payment failed');

-- =============================================================================
-- 3. §5 — including the caller the guard has never seen
-- =============================================================================

set role authenticated;
select set_config('request.jwt.claim.sub','44444444-0000-0000-0000-0000000000a2',false);  -- front desk
do $$
begin
  perform rebuild_member_timeline('44444444-0000-0000-0000-00000000dd01');
  raise exception 'FAIL  front desk rebuilt a timeline';
exception when sqlstate 'PT403' then
  raise notice 'PASS  front desk cannot rebuild a timeline';
end $$;

-- The one migration 020 exists for: an owner, but of somewhere else entirely,
-- so auth_role_in() has nothing to return for this studio.
select set_config('request.jwt.claim.sub','44444444-0000-0000-0000-0000000000a3',false);
select expect_text('a stranger is not a manager here',
  is_manager_up('44444444-0000-0000-0000-000000000001')::text, 'false');
do $$
begin
  perform rebuild_member_timeline('44444444-0000-0000-0000-00000000dd01');
  raise exception 'FAIL  an outsider rebuilt another studio''s timeline';
exception when sqlstate 'PT403' then
  raise notice 'PASS  an outsider cannot rebuild another studio''s timeline';
end $$;
select expect_num('rebuild_studio_timeline writes nothing for an outsider',
  rebuild_studio_timeline('44444444-0000-0000-0000-000000000001')::bigint, 0);
reset role;

select expect_num('and the timeline is untouched',
  (select count(*) from timeline_events where member_id='44444444-0000-0000-0000-00000000dd01'), 6);

select 'ALL TIMELINE TESTS PASSED' as result;
