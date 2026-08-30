-- =============================================================================
-- STUDIIOR — BOOKING CONCURRENCY TEST
--
-- 50 members hit a 10-seat class at the same instant. The only thing standing
-- between that and an overbooked class is the FOR UPDATE in book_class().
--
-- Concurrency here is real, not simulated. Fifty independent psql processes
-- are launched, each queues on a shared advisory lock that this session holds
-- exclusively, and none of them proceeds until every one of the fifty is
-- confirmed waiting. Releasing the lock fires all fifty into book_class() at
-- once. A sequential loop in one session would pass against a completely
-- broken function and prove nothing.
--
-- dblink would be tidier but is unusable here: supabase local authenticates
-- with trust, and dblink refuses non-superuser connections that did not
-- actually authenticate by password.
--
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -f test/booking_concurrency_test.sql
--
-- Local stack only — it inserts fixtures and spawns 50 connections. Never run
-- it against production.
-- =============================================================================

\set ON_ERROR_STOP on
set client_min_messages = notice;

-- --- Assertion helper -------------------------------------------------------

create or replace function expect(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual = want then
    raise notice 'PASS  %  (got %)', label, actual;
  else
    raise exception 'FAIL  %  expected %, got %', label, want, actual;
  end if;
end $$;

-- --- Fixtures ---------------------------------------------------------------
-- Studio C, its own UUID space so this file can run alongside rls_test.sql.

insert into studios (id, name, slug, timezone, currency) values
  ('cccccccc-0000-0000-0000-000000000001','Concurrency Studio','conc','Europe/Prague','CZK');

insert into studio_settings (studio_id, waitlist_enabled, require_waiver) values
  ('cccccccc-0000-0000-0000-000000000001', true, true);

insert into locations (id, studio_id, name) values
  ('cccccccc-0000-0000-0000-00000000000c','cccccccc-0000-0000-0000-000000000001','Main');

insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('cccccccc-0000-0000-0000-0000000000c1','cccccccc-0000-0000-0000-000000000001','Reformer',50,10);

-- Ten seats, two days out: inside the 30-day booking window, clear of the
-- 0-minute booking cutoff and the 60-minute waitlist cutoff.
insert into class_occurrences
  (id, studio_id, location_id, class_type_id, name, capacity, starts_at, ends_at)
values
  ('cccccccc-0000-0000-0000-0000000000f1',
   'cccccccc-0000-0000-0000-000000000001',
   'cccccccc-0000-0000-0000-00000000000c',
   'cccccccc-0000-0000-0000-0000000000c1',
   'Reformer 07:00', 10,
   now() + interval '2 days', now() + interval '2 days 50 minutes');

-- An unrestricted 5-class pack, so every one of the 50 resolves to
-- payment_source 'class_pack' and a booked member must consume exactly one
-- credit (Business Rules §2.2, Decision 1).
insert into membership_plans
  (id, studio_id, name, type, price_cents, currency, credits, validity_days)
values
  ('cccccccc-0000-0000-0000-0000000000b1','cccccccc-0000-0000-0000-000000000001',
   '5-Class Pack','class_pack',500000,'CZK',5,90);

insert into members (id, studio_id, first_name, last_name, email, waiver_signed_at)
select ('cccccccc-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
       'cccccccc-0000-0000-0000-000000000001',
       'Member', i::text, 'conc' || i || '@test', now()
  from generate_series(1, 50) i;

insert into memberships
  (id, studio_id, member_id, plan_id, status, price_cents, currency,
   starts_on, expires_on, credits_remaining)
select ('cccccccc-0000-0000-1111-' || lpad(i::text, 12, '0'))::uuid,
       'cccccccc-0000-0000-0000-000000000001',
       ('cccccccc-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
       'cccccccc-0000-0000-0000-0000000000b1',
       'active', 500000, 'CZK',
       current_date, current_date + 90, 5
  from generate_series(1, 50) i;

-- The purchase that granted those credits. §6: the balance is derived from the
-- ledger, so the ledger has to contain the grant for balance_after to mean
-- anything.
insert into credit_ledger
  (studio_id, member_id, membership_id, delta, reason, balance_after, expires_at)
select 'cccccccc-0000-0000-0000-000000000001',
       ('cccccccc-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
       ('cccccccc-0000-0000-1111-' || lpad(i::text, 12, '0'))::uuid,
       5, 'purchase', 5, (current_date + 91)::timestamp at time zone 'Europe/Prague'
  from generate_series(1, 50) i;

-- =============================================================================
-- THE STAMPEDE
-- =============================================================================

-- The starting gun. Every worker below queues on a shared advisory lock that
-- this session holds exclusively, so no worker enters book_class() until all
-- fifty are confirmed queued.
select pg_advisory_lock(919191);

\! for i in $(seq 1 50); do psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -q -X -v ON_ERROR_STOP=1 -c "select pg_advisory_lock_shared(919191)" -c "select book_class('cccccccc-0000-0000-0000-0000000000f1'::uuid, ('cccccccc-0000-0000-0000-' || lpad($i::text, 12, '0'))::uuid, 'member'::booking_source)" >> "${TMPDIR:-/tmp}/studiior_booking_concurrency.log" 2>&1 & done

-- Wait until all fifty backends are blocked on the advisory lock.
do $$
declare waiting int; tries int := 0;
begin
  loop
    select count(*) into waiting
      from pg_locks
     where locktype = 'advisory' and objid = 919191 and not granted;
    exit when waiting >= 50;
    tries := tries + 1;
    if tries > 600 then
      raise exception 'FAIL  only % of 50 workers reached the starting line', waiting;
    end if;
    perform pg_sleep(0.1);
  end loop;
  raise notice '--- 50 workers queued on the occurrence, releasing ---';
end $$;

-- FIRE.
select pg_advisory_unlock(919191);

-- Collect: every worker either books or waitlists, so all fifty land a row.
do $$
declare landed int; tries int := 0;
begin
  loop
    select count(*) into landed from bookings
     where occurrence_id = 'cccccccc-0000-0000-0000-0000000000f1';
    exit when landed >= 50;
    tries := tries + 1;
    if tries > 600 then
      raise exception
        'FAIL  only % of 50 calls completed; see $TMPDIR/studiior_booking_concurrency.log',
        landed;
    end if;
    perform pg_sleep(0.1);
  end loop;
  raise notice '--- 50 concurrent book_class() calls completed ---';
end $$;

-- =============================================================================
-- ASSERTIONS
-- =============================================================================

-- 1. Capacity held. This is the whole test.
select expect('exactly 10 booked',
  (select count(*) from bookings
    where occurrence_id = 'cccccccc-0000-0000-0000-0000000000f1'
      and status = 'booked'), 10);

select expect('exactly 40 waitlisted',
  (select count(*) from bookings
    where occurrence_id = 'cccccccc-0000-0000-0000-0000000000f1'
      and status = 'waitlisted'), 40);

select expect('all 50 attempts produced a row',
  (select count(*) from bookings
    where occurrence_id = 'cccccccc-0000-0000-0000-0000000000f1'), 50);

select expect('no member booked twice',
  (select count(*) from (
     select member_id from bookings
      where occurrence_id = 'cccccccc-0000-0000-0000-0000000000f1'
      group by member_id having count(*) > 1) d), 0);

-- 2. Waitlist positions are contiguous 1..40. A gap or a duplicate means two
--    sessions read max(waitlist_position) before either wrote.
select expect('waitlist positions distinct',
  (select count(distinct waitlist_position) from bookings
    where occurrence_id = 'cccccccc-0000-0000-0000-0000000000f1'
      and status = 'waitlisted'), 40);

select expect('waitlist starts at 1',
  (select min(waitlist_position) from bookings
    where occurrence_id = 'cccccccc-0000-0000-0000-0000000000f1'
      and status = 'waitlisted'), 1);

select expect('waitlist ends at 40',
  (select max(waitlist_position) from bookings
    where occurrence_id = 'cccccccc-0000-0000-0000-0000000000f1'
      and status = 'waitlisted'), 40);

select expect('waitlist positions have no gaps',
  (select count(*) from generate_series(1, 40) g
    where not exists (
      select 1 from bookings
       where occurrence_id = 'cccccccc-0000-0000-0000-0000000000f1'
         and status = 'waitlisted' and waitlist_position = g)), 0);

-- 3. The denormalised counters match reality.
select expect('booked_count = 10',
  (select booked_count from class_occurrences
    where id = 'cccccccc-0000-0000-0000-0000000000f1'), 10);

select expect('booked_count never exceeded capacity',
  (select count(*) from class_occurrences
    where id = 'cccccccc-0000-0000-0000-0000000000f1'
      and booked_count > capacity), 0);

select expect('waitlist_count = 40',
  (select waitlist_count from class_occurrences
    where id = 'cccccccc-0000-0000-0000-0000000000f1'), 40);

-- 4. Credits: one ledger row per booked member, none for the waitlist (§4.1).
select expect('10 booking ledger rows',
  (select count(*) from credit_ledger
    where studio_id = 'cccccccc-0000-0000-0000-000000000001'
      and reason = 'booking'), 10);

select expect('every booked member has exactly one booking ledger row',
  (select count(*) from bookings b
    where b.occurrence_id = 'cccccccc-0000-0000-0000-0000000000f1'
      and b.status = 'booked'
      and (select count(*) from credit_ledger cl
            where cl.member_id = b.member_id and cl.reason = 'booking') = 1), 10);

select expect('no ledger row for any waitlisted member',
  (select count(*) from credit_ledger cl
    join bookings b on b.member_id = cl.member_id
   where b.occurrence_id = 'cccccccc-0000-0000-0000-0000000000f1'
     and b.status = 'waitlisted'
     and cl.reason = 'booking'), 0);

select expect('every booking ledger row is linked to its booking',
  (select count(*) from credit_ledger cl
    join bookings b on b.id = cl.booking_id
   where cl.studio_id = 'cccccccc-0000-0000-0000-000000000001'
     and cl.reason = 'booking' and b.status = 'booked'), 10);

select expect('booking ledger rows carry balance_after = 4',
  (select count(*) from credit_ledger
    where studio_id = 'cccccccc-0000-0000-0000-000000000001'
      and reason = 'booking' and balance_after = 4), 10);

select expect('booked_count matches the credits actually spent',
  (select count(*) from memberships
    where studio_id = 'cccccccc-0000-0000-0000-000000000001'
      and credits_remaining = 4), 10);

select expect('waitlisted members kept all 5 credits',
  (select count(*) from memberships
    where studio_id = 'cccccccc-0000-0000-0000-000000000001'
      and credits_remaining = 5), 40);

-- 5. Resolution landed where §2.2 says it should.
select expect('all 10 paid by class pack',
  (select count(*) from bookings
    where occurrence_id = 'cccccccc-0000-0000-0000-0000000000f1'
      and status = 'booked' and payment_source = 'class_pack'), 10);

select expect('waitlisted rows carry no payment source',
  (select count(*) from bookings
    where occurrence_id = 'cccccccc-0000-0000-0000-0000000000f1'
      and status = 'waitlisted' and payment_source is null), 40);

select 'ALL BOOKING CONCURRENCY TESTS PASSED' as result;
