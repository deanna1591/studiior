-- =============================================================================
-- The guarantee contract — migration 138. UUID space 9c07.
-- =============================================================================
-- A: a flat slot-holding fee wins over the percentage where set, and the
--    percentage is the fallback where it is not.
-- C: the core early latch stamps and NOTIFIES at the first booking, once, and
--    does NOT touch committed_at / booked_at_cutoff (the snapshot path); a
--    guarantees-off studio gets neither.
-- B: a member cancelling a COMMITTED class queues the reassurance with the
--    unchanged pay, and does not for a non-committed class or a studio release.
-- D: set_series_flex reports how many of the flexed occurrences are standalone.
-- Everything per tenant. Run after `supabase db reset`.
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
begin if actual then raise notice 'PASS  %', label; else raise exception 'FAIL  %  expected true', label; end if; end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('9c079c07-0000-0000-0000-0000000000a1'),   -- owner (all studios)
  ('9c079c07-0000-0000-0000-0000000000d1');   -- instructor login
insert into profiles (id, email) select id, id::text||'@example.com' from auth.users where id::text like '9c079c07%';

-- A: flat holding fee.  B: pct fallback.  C: guarantees OFF.  (Manila, PHP.)
insert into studios (id, name, slug, timezone, currency, status) values
  ('9c079c07-0000-0000-0000-000000000001','GC A','9c07-a','Asia/Manila','PHP','active'),
  ('9c079c07-0000-0000-0000-000000000002','GC B','9c07-b','Asia/Manila','PHP','active'),
  ('9c079c07-0000-0000-0000-000000000003','GC C','9c07-c','Asia/Manila','PHP','active');
insert into studio_settings (studio_id, guarantees_enabled, flex_enabled, core_min_bookings, core_cutoff_hours, core_unmet_pay_pct, core_unmet_pay_cents) values
  ('9c079c07-0000-0000-0000-000000000001', true, true,  1, 12, 50, 40000),   -- flat 400
  ('9c079c07-0000-0000-0000-000000000002', true, false, 1, 12, 50, null),    -- pct 50%
  ('9c079c07-0000-0000-0000-000000000003', false, false, 1, 12, 50, null);   -- guarantees OFF
insert into locations (id, studio_id, name, is_primary) values
  ('9c079c07-0000-0000-0000-00000000000a','9c079c07-0000-0000-0000-000000000001','Main',true),
  ('9c079c07-0000-0000-0000-00000000000b','9c079c07-0000-0000-0000-000000000002','Main',true),
  ('9c079c07-0000-0000-0000-00000000000c','9c079c07-0000-0000-0000-000000000003','Main',true);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('9c079c07-0000-0000-0000-0000000aa001','9c079c07-0000-0000-0000-000000000001','9c079c07-0000-0000-0000-0000000000a1','9c07-owa@example.com','owner'),
  ('9c079c07-0000-0000-0000-0000000aa0d1','9c079c07-0000-0000-0000-000000000001','9c079c07-0000-0000-0000-0000000000d1','9c07-ia@example.com','instructor'),
  ('9c079c07-0000-0000-0000-0000000aa003','9c079c07-0000-0000-0000-000000000003','9c079c07-0000-0000-0000-0000000000a1','9c07-owc@example.com','owner'),
  ('9c079c07-0000-0000-0000-0000000aa0d3','9c079c07-0000-0000-0000-000000000003','9c079c07-0000-0000-0000-0000000000d1','9c07-ic@example.com','instructor');
insert into instructors (id, studio_id, staff_id, display_name, status) values
  ('9c079c07-0000-0000-0000-0000000d0001','9c079c07-0000-0000-0000-000000000001','9c079c07-0000-0000-0000-0000000aa0d1','Ada A','active'),
  ('9c079c07-0000-0000-0000-0000000d0002','9c079c07-0000-0000-0000-000000000002',null,'Ben B','active'),
  ('9c079c07-0000-0000-0000-0000000d0003','9c079c07-0000-0000-0000-000000000003','9c079c07-0000-0000-0000-0000000aa0d3','Cid C','active');
-- Reform's ladder: base 900, +75/head above two, full-house bonus at capacity.
insert into instructor_rate_versions (studio_id, instructor_id, effective_from, currency, base_rate_cents, per_head_rate_cents, per_head_threshold, full_house_bonus_cents) values
  ('9c079c07-0000-0000-0000-000000000001','9c079c07-0000-0000-0000-0000000d0001', current_date-30,'PHP',90000,7500,2,20000),
  ('9c079c07-0000-0000-0000-000000000002','9c079c07-0000-0000-0000-0000000d0002', current_date-30,'PHP',90000,7500,2,20000),
  ('9c079c07-0000-0000-0000-000000000003','9c079c07-0000-0000-0000-0000000d0003', current_date-30,'PHP',90000,7500,2,20000);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('9c079c07-0000-0000-0000-0000000cc001','9c079c07-0000-0000-0000-000000000001','Reformer',50,6),
  ('9c079c07-0000-0000-0000-0000000cc002','9c079c07-0000-0000-0000-000000000002','Reformer',50,6),
  ('9c079c07-0000-0000-0000-0000000cc003','9c079c07-0000-0000-0000-000000000003','Reformer',50,6);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('9c079c07-0000-0000-0000-0000000ee001','9c079c07-0000-0000-0000-000000000001','9c079c07-0000-0000-0000-00000000000a','R1',6),
  ('9c079c07-0000-0000-0000-0000000ee002','9c079c07-0000-0000-0000-000000000002','9c079c07-0000-0000-0000-00000000000b','R1',6),
  ('9c079c07-0000-0000-0000-0000000ee003','9c079c07-0000-0000-0000-000000000003','9c079c07-0000-0000-0000-00000000000c','R1',6);

-- =============================================================================
-- A. FLAT slot-holding fee wins; percentage is the fallback.
-- =============================================================================
-- A not-running core class on studio A (flat 400) and studio B (pct 50%).
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name,
       starts_at, ends_at, capacity, booked_count, booked_at_cutoff, status, cancellation_cause, cancelled_at) values
  ('9c079c07-0000-0000-0000-00000000af01','9c079c07-0000-0000-0000-000000000001','9c079c07-0000-0000-0000-00000000000a','9c079c07-0000-0000-0000-0000000cc001','9c079c07-0000-0000-0000-0000000ee001','9c079c07-0000-0000-0000-0000000d0001','A not-run', now()-interval '2 h', now()-interval '70 min',6,0,0,'cancelled','unmet_minimum', now()),
  ('9c079c07-0000-0000-0000-00000000bf01','9c079c07-0000-0000-0000-000000000002','9c079c07-0000-0000-0000-00000000000b','9c079c07-0000-0000-0000-0000000cc002','9c079c07-0000-0000-0000-0000000ee002','9c079c07-0000-0000-0000-0000000d0002','B not-run', now()-interval '2 h', now()-interval '70 min',6,0,0,'cancelled','unmet_minimum', now());

select expect_num('flat slot-holding fee: studio A pays its flat 400, not 50% of base (450)',
  (compute_class_pay_run('9c079c07-0000-0000-0000-00000000af01') ->> 'amount_cents')::bigint, 40000);
select expect_true('the basis records the flat model',
  (compute_class_pay_run('9c079c07-0000-0000-0000-00000000af01') -> 'basis' ->> 'holding_model') = 'flat');
select expect_num('percentage fallback: studio B (no flat) pays 50% of base = 450',
  (compute_class_pay_run('9c079c07-0000-0000-0000-00000000bf01') ->> 'amount_cents')::bigint, 45000);
-- Teeth: clear A's flat and it falls back to the percentage (450), proving flat is what won.
update studio_settings set core_unmet_pay_cents = null where studio_id='9c079c07-0000-0000-0000-000000000001';
select expect_num('teeth: with the flat cleared, A falls back to 50% of base = 450',
  (compute_class_pay_run('9c079c07-0000-0000-0000-00000000af01') ->> 'amount_cents')::bigint, 45000);
update studio_settings set core_unmet_pay_cents = 40000 where studio_id='9c079c07-0000-0000-0000-000000000001';

-- =============================================================================
-- C. Core early latch: stamp + notify at the first booking, once,
--    notification-only (committed_at / booked_at_cutoff untouched).
-- =============================================================================
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name,
       starts_at, ends_at, capacity, booked_count, status) values
  ('9c079c07-0000-0000-0000-00000000ac01','9c079c07-0000-0000-0000-000000000001','9c079c07-0000-0000-0000-00000000000a','9c079c07-0000-0000-0000-0000000cc001','9c079c07-0000-0000-0000-0000000ee001','9c079c07-0000-0000-0000-0000000d0001','A future core', now()+interval '2 days', now()+interval '2 days'+interval '50 min',6,0,'scheduled'),
  ('9c079c07-0000-0000-0000-00000000cc01','9c079c07-0000-0000-0000-000000000003','9c079c07-0000-0000-0000-00000000000c','9c079c07-0000-0000-0000-0000000cc003','9c079c07-0000-0000-0000-0000000ee003','9c079c07-0000-0000-0000-0000000d0003','C future core', now()+interval '2 days', now()+interval '2 days'+interval '50 min',6,0,'scheduled');

-- First booking lands (book_class maintains booked_count; the trigger fires on it).
update class_occurrences set booked_count = 1 where id='9c079c07-0000-0000-0000-00000000ac01';
select expect_true('the core class latched at the first booking',
  (select core_reached_minimum_at is not null from class_occurrences where id='9c079c07-0000-0000-0000-00000000ac01'));
select expect_true('NOTIFICATION ONLY: committed_at and booked_at_cutoff are still null',
  (select committed_at is null and booked_at_cutoff is null from class_occurrences where id='9c079c07-0000-0000-0000-00000000ac01'));
select expect_num('the instructor is told once, on the right channel',
  (select count(*) from notifications where template_key='core_committed' and user_id='9c079c07-0000-0000-0000-0000000000d1'), 1);

-- A second booking must not re-stamp or re-notify.
update class_occurrences set booked_count = 2 where id='9c079c07-0000-0000-0000-00000000ac01';
select expect_num('a second booking sends no second commitment notice',
  (select count(*) from notifications where template_key='core_committed' and user_id='9c079c07-0000-0000-0000-0000000000d1'), 1);

-- A guarantees-OFF studio latches nothing and tells no-one.
update class_occurrences set booked_count = 1 where id='9c079c07-0000-0000-0000-00000000cc01';
select expect_true('guarantees off: no latch',
  (select core_reached_minimum_at is null from class_occurrences where id='9c079c07-0000-0000-0000-00000000cc01'));
select expect_num('guarantees off: no commitment notice',
  (select count(*) from notifications where template_key='core_committed' and studio_id='9c079c07-0000-0000-0000-000000000003'), 0);

-- =============================================================================
-- B. Post-commitment reassurance: a member cancels a COMMITTED class.
-- =============================================================================
-- A committed core class, snapshot 3 -> pay 900 + 75 = 975.
insert into members (id, studio_id, email, first_name, last_name, status) values
  ('9c079c07-0000-0000-0000-0000000111a1','9c079c07-0000-0000-0000-000000000001','m1@9c07.example.com','Mem','Ber','active');
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name,
       starts_at, ends_at, capacity, booked_count, booked_at_cutoff, committed_at, status) values
  ('9c079c07-0000-0000-0000-00000000ab01','9c079c07-0000-0000-0000-000000000001','9c079c07-0000-0000-0000-00000000000a','9c079c07-0000-0000-0000-0000000cc001','9c079c07-0000-0000-0000-0000000ee001','9c079c07-0000-0000-0000-0000000d0001','A committed', now()+interval '3 h', now()+interval '3 h'+interval '50 min',6,3,3, now(),'scheduled');
insert into bookings (id, studio_id, occurrence_id, member_id, status, booked_at) values
  ('9c079c07-0000-0000-0000-0000000b0001','9c079c07-0000-0000-0000-000000000001','9c079c07-0000-0000-0000-00000000ab01','9c079c07-0000-0000-0000-0000000111a1','booked', now());

update bookings set status = 'cancelled' where id='9c079c07-0000-0000-0000-0000000b0001';
select expect_num('a member cancelling a committed class reassures the instructor, once',
  (select count(*) from notifications where template_key='booking_cancelled_committed' and user_id='9c079c07-0000-0000-0000-0000000000d1'), 1);
select expect_true('the reassurance states the unchanged pay (975 PHP)',
  (select (payload ->> 'amount') = '975 PHP' from notifications
    where template_key='booking_cancelled_committed' and user_id='9c079c07-0000-0000-0000-0000000000d1' limit 1));

-- A NON-committed class: cancelling a booked seat reassures nobody.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name,
       starts_at, ends_at, capacity, booked_count, status) values
  ('9c079c07-0000-0000-0000-00000000a0d1','9c079c07-0000-0000-0000-000000000001','9c079c07-0000-0000-0000-00000000000a','9c079c07-0000-0000-0000-0000000cc001','9c079c07-0000-0000-0000-0000000ee001','9c079c07-0000-0000-0000-0000000d0001','A uncommitted', now()+interval '4 h', now()+interval '4 h'+interval '50 min',6,1,'scheduled');
insert into bookings (id, studio_id, occurrence_id, member_id, status, booked_at) values
  ('9c079c07-0000-0000-0000-0000000b0002','9c079c07-0000-0000-0000-000000000001','9c079c07-0000-0000-0000-00000000a0d1','9c079c07-0000-0000-0000-0000000111a1','booked', now());
update bookings set status = 'cancelled' where id='9c079c07-0000-0000-0000-0000000b0002';
select expect_num('a NON-committed class sends no reassurance',
  (select count(*) from notifications where template_key='booking_cancelled_committed'
     and payload ->> 'class_name' = 'A uncommitted'), 0);

-- Teeth: a studio RELEASE (the whole class cancelled) is not a reassurance.
insert into bookings (id, studio_id, occurrence_id, member_id, status, booked_at) values
  ('9c079c07-0000-0000-0000-0000000b0003','9c079c07-0000-0000-0000-000000000001','9c079c07-0000-0000-0000-00000000ab01','9c079c07-0000-0000-0000-0000000111a1','booked', now());
do $$ begin
  -- set local + the update in ONE transaction, or the transaction-local flag is
  -- gone before the trigger reads it (psql autocommits each statement).
  perform set_config('studiior.releasing','1',true);
  update bookings set status = 'cancelled' where id='9c079c07-0000-0000-0000-0000000b0003';
end $$;
select expect_num('a studio release does not masquerade as reassurance',
  (select count(*) from notifications where template_key='booking_cancelled_committed' and user_id='9c079c07-0000-0000-0000-0000000000d1'), 1);

-- =============================================================================
-- D. Standalone-flex warning from set_series_flex.
-- =============================================================================
-- set_series_flex is manager-guarded; act as studio A's owner for this section.
select set_config('request.jwt.claim.sub','9c079c07-0000-0000-0000-0000000000a1', false);
-- A weekly series with nothing of the instructor's beside its classes. The
-- materialise trigger makes its own occurrences, so the assertions test the
-- RELATIONSHIP (all standalone; one neighbour drops the count by one) rather
-- than a fixed number.
insert into class_series (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, rrule, time_of_day, duration_minutes, starts_on, status) values
  ('9c079c07-0000-0000-0000-000000005e01','9c079c07-0000-0000-0000-000000000001','9c079c07-0000-0000-0000-00000000000a','9c079c07-0000-0000-0000-0000000cc001','9c079c07-0000-0000-0000-0000000ee001','9c079c07-0000-0000-0000-0000000d0001','Standalone series',6,'FREQ=WEEKLY;BYDAY=MO','07:00',50, current_date, 'active');

select expect_true('every flexed class is standalone: standalone_count = occurrences_updated, and > 0',
  (select (r ->> 'standalone_count')::int = (r ->> 'occurrences_updated')::int
          and (r ->> 'occurrences_updated')::int > 0
     from (select set_series_flex('9c079c07-0000-0000-0000-000000005e01', true, 1) as r) x));

-- Put a class of the SAME instructor immediately after the earliest occurrence
-- -> exactly one class is now adjacent.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name,
       starts_at, ends_at, capacity, booked_count, status)
select '9c079c07-0000-0000-0000-00000000d0b1','9c079c07-0000-0000-0000-000000000001','9c079c07-0000-0000-0000-00000000000a',
       '9c079c07-0000-0000-0000-0000000cc001','9c079c07-0000-0000-0000-0000000ee001','9c079c07-0000-0000-0000-0000000d0001',
       'Neighbour core', o.ends_at, o.ends_at + interval '50 min', 6, 0, 'scheduled'
  from class_occurrences o where o.series_id='9c079c07-0000-0000-0000-000000005e01' order by o.starts_at limit 1;
select expect_true('one neighbour of the same instructor makes exactly one class adjacent (count drops by one)',
  (select (r ->> 'standalone_count')::int = (r ->> 'occurrences_updated')::int - 1
     from (select set_series_flex('9c079c07-0000-0000-0000-000000005e01', true, 1) as r) x));

-- The tier control uses set_series_guarantee; it reports the same count.
select expect_true('set_series_guarantee(flex) also reports the standalone count',
  (select (r ->> 'standalone_count')::int >= 0 and (r ? 'standalone_count')
     from (select set_series_guarantee('9c079c07-0000-0000-0000-000000005e01', 'flex', 1) as r) x));

do $$ begin raise notice 'guarantee_contract_test: all assertions passed'; end $$;
