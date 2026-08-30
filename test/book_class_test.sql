-- =============================================================================
-- STUDIIOR — book_class() BEHAVIOUR SUITE
--
-- Covers authorisation, the §2.1 eligibility gate reason codes, §2.2 payment
-- source resolution, §2.3 override visibility, and §2.4 comp bookings.
-- Concurrency is a separate file; this one is about what the function decides,
-- not how it behaves under load.
--
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -f test/book_class_test.sql
--
-- Local stack only — it inserts fixtures. Never run it against production.
-- =============================================================================

\set ON_ERROR_STOP on
set client_min_messages = notice;

create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then
    raise notice 'PASS  %  (got %)', label, coalesce(actual, 'null');
  else
    raise exception 'FAIL  %  expected %, got %',
      label, coalesce(want, 'null'), coalesce(actual, 'null');
  end if;
end $$;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then
    raise notice 'PASS  %  (got %)', label, coalesce(actual::text, 'null');
  else
    raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null');
  end if;
end $$;

create or replace function login(uid text) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', uid, false);
end $$;

-- --- Fixtures ---------------------------------------------------------------
-- Studio F, its own UUID space so this runs alongside the other two suites.

insert into auth.users (id) values
  ('ffffffff-0000-0000-0000-00000000a001'),   -- front desk
  ('ffffffff-0000-0000-0000-00000000a002'),   -- member "self"
  ('ffffffff-0000-0000-0000-00000000a003');   -- member "other"

insert into profiles (id, email) values
  ('ffffffff-0000-0000-0000-00000000a001','deskF@test'),
  ('ffffffff-0000-0000-0000-00000000a002','selfF@test'),
  ('ffffffff-0000-0000-0000-00000000a003','otherF@test');

insert into studios (id, name, slug, timezone, currency) values
  ('ffffffff-0000-0000-0000-000000000001','Gate Studio','gate','Europe/Prague','CZK');

insert into studio_settings (studio_id) values ('ffffffff-0000-0000-0000-000000000001');

insert into locations (id, studio_id, name) values
  ('ffffffff-0000-0000-0000-00000000000c','ffffffff-0000-0000-0000-000000000001','Main');

insert into studio_staff (id, studio_id, user_id, email, role) values
  ('ffffffff-0000-0000-0000-0000000000f3','ffffffff-0000-0000-0000-000000000001',
   'ffffffff-0000-0000-0000-00000000a001','deskF@test','front_desk');

insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('ffffffff-0000-0000-0000-0000000000c1','ffffffff-0000-0000-0000-000000000001','Reformer',50,5),
  ('ffffffff-0000-0000-0000-0000000000c2','ffffffff-0000-0000-0000-000000000001','Barre',50,5);

insert into class_occurrences
  (id, studio_id, location_id, class_type_id, name, capacity, starts_at, ends_at)
values
  -- o1..o6 are ordinary, roomy, two days out
  ('ffffffff-0000-0000-0000-0000000000e1','ffffffff-0000-0000-0000-000000000001','ffffffff-0000-0000-0000-00000000000c','ffffffff-0000-0000-0000-0000000000c1','Open A',5,now()+interval '2 days',now()+interval '2 days 50 min'),
  ('ffffffff-0000-0000-0000-0000000000e2','ffffffff-0000-0000-0000-000000000001','ffffffff-0000-0000-0000-00000000000c','ffffffff-0000-0000-0000-0000000000c1','Open B',5,now()+interval '3 days',now()+interval '3 days 50 min'),
  ('ffffffff-0000-0000-0000-0000000000e3','ffffffff-0000-0000-0000-000000000001','ffffffff-0000-0000-0000-00000000000c','ffffffff-0000-0000-0000-0000000000c1','Open C',5,now()+interval '4 days',now()+interval '4 days 50 min'),
  ('ffffffff-0000-0000-0000-0000000000e4','ffffffff-0000-0000-0000-000000000001','ffffffff-0000-0000-0000-00000000000c','ffffffff-0000-0000-0000-0000000000c1','Open D',5,now()+interval '5 days',now()+interval '5 days 50 min'),
  ('ffffffff-0000-0000-0000-0000000000e5','ffffffff-0000-0000-0000-000000000001','ffffffff-0000-0000-0000-00000000000c','ffffffff-0000-0000-0000-0000000000c1','Open E',5,now()+interval '6 days',now()+interval '6 days 50 min'),
  ('ffffffff-0000-0000-0000-0000000000e6','ffffffff-0000-0000-0000-000000000001','ffffffff-0000-0000-0000-00000000000c','ffffffff-0000-0000-0000-0000000000c1','Open F',5,now()+interval '7 days',now()+interval '7 days 50 min'),
  -- edge cases
  ('ffffffff-0000-0000-0000-0000000000e7','ffffffff-0000-0000-0000-000000000001','ffffffff-0000-0000-0000-00000000000c','ffffffff-0000-0000-0000-0000000000c1','Past',5,now()-interval '2 days',now()-interval '2 days'+interval '50 min'),
  ('ffffffff-0000-0000-0000-0000000000e8','ffffffff-0000-0000-0000-000000000001','ffffffff-0000-0000-0000-00000000000c','ffffffff-0000-0000-0000-0000000000c1','Cancelled',5,now()+interval '2 days',now()+interval '2 days 50 min'),
  ('ffffffff-0000-0000-0000-0000000000e9','ffffffff-0000-0000-0000-000000000001','ffffffff-0000-0000-0000-00000000000c','ffffffff-0000-0000-0000-0000000000c1','Far out',5,now()+interval '90 days',now()+interval '90 days 50 min'),
  ('ffffffff-0000-0000-0000-0000000000ea','ffffffff-0000-0000-0000-000000000001','ffffffff-0000-0000-0000-00000000000c','ffffffff-0000-0000-0000-0000000000c2','Barre only',5,now()+interval '3 days',now()+interval '3 days 50 min'),
  ('ffffffff-0000-0000-0000-0000000000eb','ffffffff-0000-0000-0000-000000000001','ffffffff-0000-0000-0000-00000000000c','ffffffff-0000-0000-0000-0000000000c1','One seat',1,now()+interval '4 days',now()+interval '4 days 50 min'),
  ('ffffffff-0000-0000-0000-0000000000ec','ffffffff-0000-0000-0000-000000000001','ffffffff-0000-0000-0000-00000000000c','ffffffff-0000-0000-0000-0000000000c1','Imminent',1,now()+interval '30 minutes',now()+interval '80 minutes');

update class_occurrences set status = 'cancelled'
 where id = 'ffffffff-0000-0000-0000-0000000000e8';

insert into members (id, studio_id, user_id, first_name, last_name, email, waiver_signed_at) values
  ('ffffffff-0000-0000-0000-0000000000d1','ffffffff-0000-0000-0000-000000000001','ffffffff-0000-0000-0000-00000000a002','Self','Member','self@t',now()),
  ('ffffffff-0000-0000-0000-0000000000d2','ffffffff-0000-0000-0000-000000000001','ffffffff-0000-0000-0000-00000000a003','Other','Member','other@t',now()),
  ('ffffffff-0000-0000-0000-0000000000d3','ffffffff-0000-0000-0000-000000000001',null,'No','Plan','noplan@t',now()),
  ('ffffffff-0000-0000-0000-0000000000d4','ffffffff-0000-0000-0000-000000000001',null,'Un','Limited','unl@t',now()),
  ('ffffffff-0000-0000-0000-0000000000d5','ffffffff-0000-0000-0000-000000000001',null,'Ltd','Period','ltd@t',now()),
  ('ffffffff-0000-0000-0000-0000000000d6','ffffffff-0000-0000-0000-000000000001',null,'Two','Packs','packs@t',now()),
  ('ffffffff-0000-0000-0000-0000000000d7','ffffffff-0000-0000-0000-000000000001',null,'No','Waiver','nw@t',null),
  ('ffffffff-0000-0000-0000-0000000000d8','ffffffff-0000-0000-0000-000000000001',null,'Restricted','Plan','rp@t',now()),
  ('ffffffff-0000-0000-0000-0000000000d9','ffffffff-0000-0000-0000-000000000001',null,'Comp','Guest','comp@t',now());

insert into members (id, studio_id, first_name, last_name, email, waiver_signed_at, status) values
  ('ffffffff-0000-0000-0000-0000000000da','ffffffff-0000-0000-0000-000000000001','In','Active','ia@t',now(),'inactive');

insert into membership_plans
  (id, studio_id, name, type, price_cents, currency, credits, credits_per_period, restrictions)
values
  ('ffffffff-0000-0000-0000-00000000b101','ffffffff-0000-0000-0000-000000000001','Unlimited','recurring',280000,'CZK',null,null,'{}'),
  ('ffffffff-0000-0000-0000-00000000b102','ffffffff-0000-0000-0000-000000000001','8 a month','recurring',180000,'CZK',null,8,'{}'),
  ('ffffffff-0000-0000-0000-00000000b103','ffffffff-0000-0000-0000-000000000001','5-Class Pack','class_pack',500000,'CZK',5,null,'{}'),
  ('ffffffff-0000-0000-0000-00000000b104','ffffffff-0000-0000-0000-000000000001','Reformer only','recurring',180000,'CZK',null,8,'{"class_type_ids":["ffffffff-0000-0000-0000-0000000000c1"]}');

insert into memberships
  (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on,
   credits_remaining, expires_on)
values
  ('ffffffff-0000-0000-1111-000000000004','ffffffff-0000-0000-0000-000000000001','ffffffff-0000-0000-0000-0000000000d4','ffffffff-0000-0000-0000-00000000b101','active',280000,'CZK',current_date,null,null),
  ('ffffffff-0000-0000-1111-000000000005','ffffffff-0000-0000-0000-000000000001','ffffffff-0000-0000-0000-0000000000d5','ffffffff-0000-0000-0000-00000000b102','active',180000,'CZK',current_date,8,null),
  -- two packs for one member: the LATER-expiring one is inserted first, so
  -- "soonest expiry first" cannot pass by accident of insertion order.
  ('ffffffff-0000-0000-1111-00000000060a','ffffffff-0000-0000-0000-000000000001','ffffffff-0000-0000-0000-0000000000d6','ffffffff-0000-0000-0000-00000000b103','active',500000,'CZK',current_date,5,current_date+90),
  ('ffffffff-0000-0000-1111-00000000060b','ffffffff-0000-0000-0000-000000000001','ffffffff-0000-0000-0000-0000000000d6','ffffffff-0000-0000-0000-00000000b103','active',500000,'CZK',current_date,5,current_date+10),
  ('ffffffff-0000-0000-1111-000000000008','ffffffff-0000-0000-0000-000000000001','ffffffff-0000-0000-0000-0000000000d8','ffffffff-0000-0000-0000-00000000b104','active',180000,'CZK',current_date,8,null),
  ('ffffffff-0000-0000-1111-000000000009','ffffffff-0000-0000-0000-000000000001','ffffffff-0000-0000-0000-0000000000d9','ffffffff-0000-0000-0000-00000000b103','active',500000,'CZK',current_date,5,current_date+30);

-- =============================================================================
-- 1. AUTHORISATION — migration 003
--
-- The bug this replaces: migration 002 read a null auth.uid() as "trusted
-- server context". An `authenticated` caller presenting a JWT with no `sub`
-- claim has a null auth.uid() too, so any logged-in user could book, comp and
-- override against any member in the studio.
-- =============================================================================

set role authenticated;

-- The attack, exactly: authenticated role, no sub claim, so auth.uid() is null.
select login('');
select expect_text('sanity: this caller really does have a null auth.uid()',
  (select case when auth.uid() is null then 'null' else 'not null' end), 'null');
select expect_text('sanity: and is really running as authenticated',
  current_setting('role', true), 'authenticated');
select expect_text('authenticated with null auth.uid() is refused',
  (book_class('ffffffff-0000-0000-0000-0000000000e1',
              'ffffffff-0000-0000-0000-0000000000d3','member')).failure_reason,
  'not_authorised');

-- Same attack with the claim never set at all rather than set to empty. Both
-- yield a null auth.uid() but leave the GUC in different states, and the old
-- predicate trusted both.
select set_config('request.jwt.claim.sub', null, false);
select expect_text('authenticated with NO jwt claim at all is refused',
  (book_class('ffffffff-0000-0000-0000-0000000000e1',
              'ffffffff-0000-0000-0000-0000000000d3','member')).failure_reason,
  'not_authorised');
select login('');

select expect_text('null auth.uid() cannot override either',
  (book_class('ffffffff-0000-0000-0000-0000000000e9',
              'ffffffff-0000-0000-0000-0000000000d3','front_desk','forged')).failure_reason,
  'not_authorised');

select expect_text('null auth.uid() cannot comp either',
  (book_class('ffffffff-0000-0000-0000-0000000000e1',
              'ffffffff-0000-0000-0000-0000000000d3','front_desk',null,'comp')).failure_reason,
  'not_authorised');

select expect_num('and it wrote nothing at all',
  (select count(*) from bookings
    where member_id = 'ffffffff-0000-0000-0000-0000000000d3'), 0);

-- A real member may book themselves, and only themselves.
select login('ffffffff-0000-0000-0000-00000000a002');
select expect_text('member books themselves',
  (book_class('ffffffff-0000-0000-0000-0000000000e1',
              'ffffffff-0000-0000-0000-0000000000d1','member')).status::text,
  'booked');

select expect_text('member cannot book another member',
  (book_class('ffffffff-0000-0000-0000-0000000000e1',
              'ffffffff-0000-0000-0000-0000000000d2','member')).failure_reason,
  'not_authorised');

select expect_text('member cannot claim a staff source',
  (book_class('ffffffff-0000-0000-0000-0000000000e2',
              'ffffffff-0000-0000-0000-0000000000d1','front_desk')).failure_reason,
  'not_authorised');

select expect_text('member cannot comp themselves',
  (book_class('ffffffff-0000-0000-0000-0000000000e2',
              'ffffffff-0000-0000-0000-0000000000d1','member',null,'comp')).failure_reason,
  'not_authorised');

select expect_text('member cannot override their own booking window',
  (book_class('ffffffff-0000-0000-0000-0000000000e9',
              'ffffffff-0000-0000-0000-0000000000d1','member','I really want in')).failure_reason,
  'outside_booking_window');

-- The other half of the predicate: rejecting null auth.uid() must not lock out
-- the legitimate backend caller. service_role has no JWT subject either, and
-- has to keep working for jobs, imports and webhooks.
reset role;
set role service_role;
select login('');
select expect_text('service_role with null auth.uid() is still trusted',
  (book_class('ffffffff-0000-0000-0000-0000000000e6',
              'ffffffff-0000-0000-0000-0000000000d3','import')).status::text,
  'booked');
reset role;
set role authenticated;

-- Front desk may act for any member in their studio.
select login('ffffffff-0000-0000-0000-00000000a001');
select expect_text('front desk books on behalf of a member',
  (book_class('ffffffff-0000-0000-0000-0000000000e1',
              'ffffffff-0000-0000-0000-0000000000d2','front_desk')).status::text,
  'booked');

reset role;
select login('');

-- =============================================================================
-- 2. ELIGIBILITY GATE — §2.1, evaluated as a trusted server caller
-- =============================================================================

select expect_text('unknown occurrence',
  (book_class('00000000-0000-0000-0000-0000000000ff',
              'ffffffff-0000-0000-0000-0000000000d3','member')).failure_reason,
  'not_found');

select expect_text('unknown member',
  (book_class('ffffffff-0000-0000-0000-0000000000e1',
              '00000000-0000-0000-0000-0000000000ff','member')).failure_reason,
  'member_not_found');

select expect_text('2.1.1 cancelled class',
  (book_class('ffffffff-0000-0000-0000-0000000000e8',
              'ffffffff-0000-0000-0000-0000000000d3','member')).failure_reason,
  'class_cancelled');

select expect_text('2.1.1 class in the past',
  (book_class('ffffffff-0000-0000-0000-0000000000e7',
              'ffffffff-0000-0000-0000-0000000000d3','member')).failure_reason,
  'class_in_past');

select expect_text('2.1.2 outside the booking window',
  (book_class('ffffffff-0000-0000-0000-0000000000e9',
              'ffffffff-0000-0000-0000-0000000000d3','member')).failure_reason,
  'outside_booking_window');

select expect_text('2.1.4 waiver not signed',
  (book_class('ffffffff-0000-0000-0000-0000000000e1',
              'ffffffff-0000-0000-0000-0000000000d7','member')).failure_reason,
  'waiver_not_signed');

select expect_text('2.1.5 member not active',
  (book_class('ffffffff-0000-0000-0000-0000000000e1',
              'ffffffff-0000-0000-0000-0000000000da','member')).failure_reason,
  'member_not_active');

select expect_text('2.1.6 duplicate booking',
  (book_class('ffffffff-0000-0000-0000-0000000000e1',
              'ffffffff-0000-0000-0000-0000000000d1','member')).failure_reason,
  'already_booked');

select expect_text('2.1.9 plan does not cover this class type',
  (book_class('ffffffff-0000-0000-0000-0000000000ea',
              'ffffffff-0000-0000-0000-0000000000d8','member')).failure_reason,
  'class_type_not_in_plan');

-- 2.1.10 capacity: fill the one-seat class, then the next member waitlists.
select expect_text('one-seat class takes its member',
  (book_class('ffffffff-0000-0000-0000-0000000000eb',
              'ffffffff-0000-0000-0000-0000000000d3','member')).status::text,
  'booked');
select expect_text('next member waitlists',
  (book_class('ffffffff-0000-0000-0000-0000000000eb',
              'ffffffff-0000-0000-0000-0000000000d4','member')).status::text,
  'waitlisted');

-- §4.4 no waitlist inside waitlist_cutoff_minutes, and §2.1.10 with waitlist off.
select expect_text('imminent class takes its member',
  (book_class('ffffffff-0000-0000-0000-0000000000ec',
              'ffffffff-0000-0000-0000-0000000000d3','member')).status::text,
  'booked');
select expect_text('4.4 waitlist closed inside the cutoff',
  (book_class('ffffffff-0000-0000-0000-0000000000ec',
              'ffffffff-0000-0000-0000-0000000000d4','member')).failure_reason,
  'waitlist_closed');

update studio_settings set waitlist_enabled = false
 where studio_id = 'ffffffff-0000-0000-0000-000000000001';
select expect_text('2.1.10 full with waitlist disabled',
  (book_class('ffffffff-0000-0000-0000-0000000000ec',
              'ffffffff-0000-0000-0000-0000000000d5','member')).failure_reason,
  'class_full');
update studio_settings set waitlist_enabled = true
 where studio_id = 'ffffffff-0000-0000-0000-000000000001';

-- =============================================================================
-- 3. PAYMENT SOURCE RESOLUTION — §2.2, Decision 1
-- =============================================================================

select expect_text('no plan falls through to drop-in',
  (book_class('ffffffff-0000-0000-0000-0000000000e2',
              'ffffffff-0000-0000-0000-0000000000d3','member')).payment_source::text,
  'drop_in');

select expect_text('priority 1: unlimited membership',
  (book_class('ffffffff-0000-0000-0000-0000000000e2',
              'ffffffff-0000-0000-0000-0000000000d4','member')).payment_source::text,
  'membership');
select expect_num('unlimited consumes nothing',
  (select count(*) from credit_ledger
    where member_id = 'ffffffff-0000-0000-0000-0000000000d4' and reason = 'booking'), 0);

select expect_text('priority 2: limited period allowance',
  (book_class('ffffffff-0000-0000-0000-0000000000e2',
              'ffffffff-0000-0000-0000-0000000000d5','member')).payment_source::text,
  'membership');
select expect_num('limited allowance drops 8 -> 7',
  (select credits_remaining from memberships
    where id = 'ffffffff-0000-0000-1111-000000000005'), 7);

select expect_text('priority 3: class pack',
  (book_class('ffffffff-0000-0000-0000-0000000000e2',
              'ffffffff-0000-0000-0000-0000000000d6','member')).payment_source::text,
  'class_pack');
select expect_num('Decision 1: the SOONEST-expiring pack is drained',
  (select credits_remaining from memberships
    where id = 'ffffffff-0000-0000-1111-00000000060b'), 4);
select expect_num('the later-expiring pack is untouched',
  (select credits_remaining from memberships
    where id = 'ffffffff-0000-0000-1111-00000000060a'), 5);

select expect_num('every consumed credit wrote one ledger row',
  (select count(*) from credit_ledger
    where studio_id = 'ffffffff-0000-0000-0000-000000000001' and reason = 'booking'), 2);
select expect_num('ledger rows are linked back to their booking',
  (select count(*) from credit_ledger cl join bookings b on b.id = cl.booking_id
    where cl.studio_id = 'ffffffff-0000-0000-0000-000000000001'
      and cl.reason = 'booking'), 2);

-- =============================================================================
-- 4. OVERRIDES ARE VISIBLE ON THE BOOKING RECORD — §2.3, migration 003
-- =============================================================================

select expect_text('override books outside the window',
  (book_class('ffffffff-0000-0000-0000-0000000000e9',
              'ffffffff-0000-0000-0000-0000000000d3','front_desk',
              'Founder guest, owner approved')).status::text,
  'booked');

select expect_text('the reason is on the booking row, not just the audit log',
  (select override_reason from bookings
    where occurrence_id = 'ffffffff-0000-0000-0000-0000000000e9'
      and member_id = 'ffffffff-0000-0000-0000-0000000000d3'),
  'Founder guest, owner approved');

select expect_text('and it names the rule it bypassed',
  (select array_to_string(overridden_rules, ',') from bookings
    where occurrence_id = 'ffffffff-0000-0000-0000-0000000000e9'
      and member_id = 'ffffffff-0000-0000-0000-0000000000d3'),
  'booking_window');

select expect_num('the audit row is still written',
  (select count(*) from audit_logs
    where studio_id = 'ffffffff-0000-0000-0000-000000000001'
      and action = 'booking.override'), 1);

-- §2.3 / §5: a capacity override books over capacity rather than erroring.
select expect_text('capacity override books a walk-in into a full class',
  (book_class('ffffffff-0000-0000-0000-0000000000eb',
              'ffffffff-0000-0000-0000-0000000000d5','front_desk',
              'walk-in, instructor agreed')).status::text,
  'booked');
select expect_text('the capacity bypass is recorded on the booking',
  (select array_to_string(overridden_rules, ',') from bookings
    where occurrence_id = 'ffffffff-0000-0000-0000-0000000000eb'
      and member_id = 'ffffffff-0000-0000-0000-0000000000d5'),
  'capacity');
select expect_num('booked_count is allowed past capacity',
  (select booked_count from class_occurrences
    where id = 'ffffffff-0000-0000-0000-0000000000eb'), 2);

-- A reason that bypassed nothing was not an override, so it is not recorded.
select expect_text('an unused reason books normally',
  (book_class('ffffffff-0000-0000-0000-0000000000e3',
              'ffffffff-0000-0000-0000-0000000000d3','front_desk',
              'reason supplied but nothing to bypass')).status::text,
  'booked');
select expect_text('and leaves override_reason null',
  (select override_reason from bookings
    where occurrence_id = 'ffffffff-0000-0000-0000-0000000000e3'
      and member_id = 'ffffffff-0000-0000-0000-0000000000d3'),
  null);

-- =============================================================================
-- 5. COMP BOOKINGS — §2.4, migration 003
-- =============================================================================

select expect_text('comp books',
  (book_class('ffffffff-0000-0000-0000-0000000000e4',
              'ffffffff-0000-0000-0000-0000000000d9','front_desk',null,'comp')).status::text,
  'booked');
select expect_text('comp is recorded as the payment source',
  (select payment_source::text from bookings
    where occurrence_id = 'ffffffff-0000-0000-0000-0000000000e4'
      and member_id = 'ffffffff-0000-0000-0000-0000000000d9'),
  'comp');

-- The comp member holds a 5-class pack. §2.4: nothing consumed, nothing charged.
select expect_num('comp consumed no credit',
  (select count(*) from credit_ledger
    where member_id = 'ffffffff-0000-0000-0000-0000000000d9'), 0);
select expect_num('comp left the pack untouched',
  (select credits_remaining from memberships
    where id = 'ffffffff-0000-0000-1111-000000000009'), 5);
select expect_num('comp charged nothing',
  (select fee_charged_cents from bookings
    where occurrence_id = 'ffffffff-0000-0000-0000-0000000000e4'
      and member_id = 'ffffffff-0000-0000-0000-0000000000d9'), 0);

-- §2.4: "counts as attendance for challenges and milestones". A comp is an
-- ordinary 'booked' row, so every roster, check-in and attendance query picks
-- it up without special-casing. (The finalisation job that turns booked into
-- attended is not built yet; this asserts the comp is not excluded upstream.)
select expect_num('comp takes a real seat on the roster',
  (select booked_count from class_occurrences
    where id = 'ffffffff-0000-0000-0000-0000000000e4'), 1);
select expect_num('comp is a live booking like any other',
  (select count(*) from bookings
    where occurrence_id = 'ffffffff-0000-0000-0000-0000000000e4'
      and status in ('booked','waitlisted','attended','no_show')), 1);

select expect_text('comp still runs the gate: past class is still refused',
  (book_class('ffffffff-0000-0000-0000-0000000000e7',
              'ffffffff-0000-0000-0000-0000000000d9','front_desk',null,'comp')).failure_reason,
  'class_in_past');

-- §2.2: the member never chooses what pays. comp is the only accepted value.
select expect_text('drop_in cannot be forced',
  (book_class('ffffffff-0000-0000-0000-0000000000e5',
              'ffffffff-0000-0000-0000-0000000000d9','front_desk',null,'drop_in')).failure_reason,
  'unsupported_payment_source');
select expect_text('membership cannot be forced',
  (book_class('ffffffff-0000-0000-0000-0000000000e5',
              'ffffffff-0000-0000-0000-0000000000d9','front_desk',null,'membership')).failure_reason,
  'unsupported_payment_source');

select 'ALL book_class BEHAVIOUR TESTS PASSED' as result;
