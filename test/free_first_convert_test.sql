-- =============================================================================
-- Decision 30 amendment (c) — "Make this their free class" from the roster.
-- UUID space c0f2. Run after `supabase db reset`.
--
-- One studio (free-first on, confirm_at = 3 so book_first_free WOULD make a quiet
-- seat provisional — proving the conversion forces it confirmed regardless).
-- (a) an unpaid eligible drop-in with the nine's shape (host-null pass + a
--     cancelled comp + the drop-in) converts: comp, non-provisional, confirmed,
--     the pass re-pointed, exactly one free_booking_confirmed, zero booking_confirmed.
-- (b) the same member, after conversion, calling book_first_free elsewhere → already_had_free.
-- (c) a paid drop-in → 'booking is paid'.
-- (d) a class closed to first-timers → 'class is not open to first-timers'.
-- (e) an instructor role → PT403, booking unchanged.
-- (f) free_first_eligibility with and without p_exclude_booking on a member holding
--     only an unpaid drop-in → not_first vs ok.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'EXPECTATION  %  wanted %, got %', label, want, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'EXPECTATION  %  wanted %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if;
end $$;

-- --- Fixtures ---------------------------------------------------------------
insert into studios (id, name, slug, timezone, currency, status) values
  ('c0f20000-0000-0000-0000-000000000001','Convert Studio','convert-c0f2','Europe/Prague','CZK','active');
insert into studio_settings (studio_id, guarantees_enabled, flex_enabled,
   free_first_class_enabled, free_first_core_only, free_first_confirm_at,
   free_first_peak_allowed, booking_window_days, booking_cutoff_minutes,
   cancellation_cutoff_minutes, core_cutoff_hours, core_min_bookings, flex_min_bookings)
 values ('c0f20000-0000-0000-0000-000000000001', true, true,
   true, false, 3, true, 90, 0, 720, 12, 1, 2);
insert into locations (id, studio_id, name, is_primary) values
  ('c0f20000-0000-0000-0000-0000000000c1','c0f20000-0000-0000-0000-000000000001','Main',true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('c0f20000-0000-0000-0000-0000000000e1','c0f20000-0000-0000-0000-000000000001',
   'c0f20000-0000-0000-0000-0000000000c1','Studio A',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('c0f20000-0000-0000-0000-0000000000a1','c0f20000-0000-0000-0000-000000000001','Core Class',50,10);

-- Staff: an owner login and an instructor login.
insert into auth.users (id, email) values
  ('c0f20000-0000-0000-0000-00000000aa01','c0f2-owner@example.com'),
  ('c0f20000-0000-0000-0000-00000000aa02','c0f2-instr@example.com');
insert into profiles (id, email, full_name) values
  ('c0f20000-0000-0000-0000-00000000aa01','c0f2-owner@example.com','Owner C0f2'),
  ('c0f20000-0000-0000-0000-00000000aa02','c0f2-instr@example.com','Instr C0f2');
insert into studio_staff (studio_id, user_id, email, role) values
  ('c0f20000-0000-0000-0000-000000000001','c0f20000-0000-0000-0000-00000000aa01','c0f2-owner@example.com','owner'),
  ('c0f20000-0000-0000-0000-000000000001','c0f20000-0000-0000-0000-00000000aa02','c0f2-instr@example.com','instructor');

-- Members A, C, D, E, F (all leads, waiver signed so the pass confirms). The hex
-- suffix letters a/c/d/e/f are the member ids; uids share the letter.
insert into auth.users (id, email) values
  ('c0f20000-0000-0000-0000-00000000bb0a','membera@c0f2.test'),
  ('c0f20000-0000-0000-0000-00000000bb0c','memberc@c0f2.test'),
  ('c0f20000-0000-0000-0000-00000000bb0d','memberd@c0f2.test'),
  ('c0f20000-0000-0000-0000-00000000bb0e','membere@c0f2.test'),
  ('c0f20000-0000-0000-0000-00000000bb0f','memberf@c0f2.test');
insert into profiles (id, email, full_name) values
  ('c0f20000-0000-0000-0000-00000000bb0a','membera@c0f2.test','Member A'),
  ('c0f20000-0000-0000-0000-00000000bb0c','memberc@c0f2.test','Member C'),
  ('c0f20000-0000-0000-0000-00000000bb0d','memberd@c0f2.test','Member D'),
  ('c0f20000-0000-0000-0000-00000000bb0e','membere@c0f2.test','Member E'),
  ('c0f20000-0000-0000-0000-00000000bb0f','memberf@c0f2.test','Member F');
insert into members (id, studio_id, user_id, first_name, last_name, email, joined_on, status, waiver_signed_at) values
  ('c0f20000-0000-0000-0000-00000000cc0a','c0f20000-0000-0000-0000-000000000001','c0f20000-0000-0000-0000-00000000bb0a','Member','A','membera@c0f2.test',current_date,'lead',now()),
  ('c0f20000-0000-0000-0000-00000000cc0c','c0f20000-0000-0000-0000-000000000001','c0f20000-0000-0000-0000-00000000bb0c','Member','C','memberc@c0f2.test',current_date,'lead',now()),
  ('c0f20000-0000-0000-0000-00000000cc0d','c0f20000-0000-0000-0000-000000000001','c0f20000-0000-0000-0000-00000000bb0d','Member','D','memberd@c0f2.test',current_date,'lead',now()),
  ('c0f20000-0000-0000-0000-00000000cc0e','c0f20000-0000-0000-0000-000000000001','c0f20000-0000-0000-0000-00000000bb0e','Member','E','membere@c0f2.test',current_date,'lead',now()),
  ('c0f20000-0000-0000-0000-00000000cc0f','c0f20000-0000-0000-0000-000000000001','c0f20000-0000-0000-0000-00000000bb0f','Member','F','memberf@c0f2.test',current_date,'lead',now());

-- Occurrences: all core, no series (so effective_free_first is open by rules),
-- future, scheduled. occD is overridden closed to first-timers.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id,
   name, starts_at, ends_at, capacity, status, booked_count, free_first_override) values
  ('c0f20000-0000-0000-0000-0000000d0001','c0f20000-0000-0000-0000-000000000001','c0f20000-0000-0000-0000-0000000000c1','c0f20000-0000-0000-0000-0000000000a1','c0f20000-0000-0000-0000-0000000000e1','Core A', now()+interval '20 days', now()+interval '20 days 50 min', 10, 'scheduled', 1, null),
  ('c0f20000-0000-0000-0000-0000000d0002','c0f20000-0000-0000-0000-000000000001','c0f20000-0000-0000-0000-0000000000c1','c0f20000-0000-0000-0000-0000000000a1','c0f20000-0000-0000-0000-0000000000e1','Core B', now()+interval '21 days', now()+interval '21 days 50 min', 10, 'scheduled', 0, null),
  ('c0f20000-0000-0000-0000-0000000d0003','c0f20000-0000-0000-0000-000000000001','c0f20000-0000-0000-0000-0000000000c1','c0f20000-0000-0000-0000-0000000000a1','c0f20000-0000-0000-0000-0000000000e1','Core C', now()+interval '22 days', now()+interval '22 days 50 min', 10, 'scheduled', 1, null),
  ('c0f20000-0000-0000-0000-0000000d0004','c0f20000-0000-0000-0000-000000000001','c0f20000-0000-0000-0000-0000000000c1','c0f20000-0000-0000-0000-0000000000a1','c0f20000-0000-0000-0000-0000000000e1','Core D', now()+interval '23 days', now()+interval '23 days 50 min', 10, 'scheduled', 1, 'closed'),
  ('c0f20000-0000-0000-0000-0000000d0005','c0f20000-0000-0000-0000-000000000001','c0f20000-0000-0000-0000-0000000000c1','c0f20000-0000-0000-0000-0000000000a1','c0f20000-0000-0000-0000-0000000000e1','Core E', now()+interval '24 days', now()+interval '24 days 50 min', 10, 'scheduled', 1, null),
  ('c0f20000-0000-0000-0000-0000000d0006','c0f20000-0000-0000-0000-000000000001','c0f20000-0000-0000-0000-0000000000c1','c0f20000-0000-0000-0000-0000000000a1','c0f20000-0000-0000-0000-0000000000e1','Core F', now()+interval '25 days', now()+interval '25 days 50 min', 10, 'scheduled', 1, null);

-- Bookings. A: the nine's shape — a cancelled comp + a live unpaid drop-in, plus a
-- host-null guest_passes row. C: paid drop-in. D: drop-in on a closed class.
-- E: drop-in (instructor-refused). F: drop-in, NO pass (test f).
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source) values
  ('c0f20000-0000-0000-0000-0000000f000a','c0f20000-0000-0000-0000-000000000001','c0f20000-0000-0000-0000-0000000d0001','c0f20000-0000-0000-0000-00000000cc0a','cancelled','member','comp'),
  ('c0f20000-0000-0000-0000-0000000f0001','c0f20000-0000-0000-0000-000000000001','c0f20000-0000-0000-0000-0000000d0001','c0f20000-0000-0000-0000-00000000cc0a','booked','member','drop_in'),
  ('c0f20000-0000-0000-0000-0000000f0003','c0f20000-0000-0000-0000-000000000001','c0f20000-0000-0000-0000-0000000d0003','c0f20000-0000-0000-0000-00000000cc0c','booked','member','drop_in'),
  ('c0f20000-0000-0000-0000-0000000f0004','c0f20000-0000-0000-0000-000000000001','c0f20000-0000-0000-0000-0000000d0004','c0f20000-0000-0000-0000-00000000cc0d','booked','member','drop_in'),
  ('c0f20000-0000-0000-0000-0000000f0005','c0f20000-0000-0000-0000-000000000001','c0f20000-0000-0000-0000-0000000d0005','c0f20000-0000-0000-0000-00000000cc0e','booked','member','drop_in'),
  ('c0f20000-0000-0000-0000-0000000f0006','c0f20000-0000-0000-0000-000000000001','c0f20000-0000-0000-0000-0000000d0006','c0f20000-0000-0000-0000-00000000cc0f','booked','member','drop_in');

-- M_A's host-null once-ever ledger row, pointing at the cancelled comp booking.
insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email,
    occurrence_id, guest_booking_id, status, waiver_signed_at) values
  ('c0f20000-0000-0000-0000-000000000001', null, 'c0f20000-0000-0000-0000-00000000cc0a',
   'membera@c0f2.test','c0f20000-0000-0000-0000-0000000d0001',
   'c0f20000-0000-0000-0000-0000000f000a','confirmed', now());

-- M_C's drop-in is PAID (a succeeded payment).
insert into payments (studio_id, member_id, booking_id, amount_cents, currency, status) values
  ('c0f20000-0000-0000-0000-000000000001','c0f20000-0000-0000-0000-00000000cc0c',
   'c0f20000-0000-0000-0000-0000000f0003', 50000, 'CZK', 'succeeded');

-- Clear notifications the fixture's direct booking inserts queued (the drop-ins
-- fired the AFTER-INSERT trigger → booking_confirmed), so (a) counts only what the
-- CONVERSION produces.
delete from notifications where studio_id = 'c0f20000-0000-0000-0000-000000000001';

create temp table _r(k text primary key, v jsonb);

-- =============================================================================
-- (f) eligibility with and without p_exclude_booking — a member (F) holding only
-- an unpaid drop-in and NO pass. Run as superuser (service context) so the
-- helper's guard passes.
-- =============================================================================
select expect_text('(f) 2-arg, drop-in counts → not_first',
  (free_first_eligibility('c0f20000-0000-0000-0000-000000000001','c0f20000-0000-0000-0000-00000000cc0f'))->>'reason',
  'not_first');
select expect_text('(f) 3-arg, drop-in excluded → ok',
  (free_first_eligibility('c0f20000-0000-0000-0000-000000000001','c0f20000-0000-0000-0000-00000000cc0f','c0f20000-0000-0000-0000-0000000f0006'))->>'ok',
  'true');
-- And the nine's shape (A, host-null pass): 2-arg already_had_free, 3-arg ok.
select expect_text('(f) A 2-arg → already_had_free',
  (free_first_eligibility('c0f20000-0000-0000-0000-000000000001','c0f20000-0000-0000-0000-00000000cc0a'))->>'reason',
  'already_had_free');
select expect_text('(f) A 3-arg, drop-in excluded → ok',
  (free_first_eligibility('c0f20000-0000-0000-0000-000000000001','c0f20000-0000-0000-0000-00000000cc0a','c0f20000-0000-0000-0000-0000000f0001'))->>'ok',
  'true');

-- =============================================================================
-- (c) paid drop-in → refused. (d) closed class → refused. (owner session)
-- =============================================================================
do $$ declare rc jsonb; rd jsonb; begin
  perform set_config('request.jwt.claim.sub','c0f20000-0000-0000-0000-00000000aa01', true);
  set local role authenticated;
  rc := convert_booking_to_free_first('c0f20000-0000-0000-0000-0000000f0003');
  rd := convert_booking_to_free_first('c0f20000-0000-0000-0000-0000000f0004');
  reset role;
  insert into _r values ('c', rc), ('d', rd);
exception when others then reset role; raise; end $$;
select expect_text('(c) paid → refused reason', (select v->>'reason' from _r where k='c'), 'booking is paid');
select expect_text('(d) closed class → refused reason', (select v->>'reason' from _r where k='d'), 'class is not open to first-timers');

-- =============================================================================
-- (e) instructor role → PT403, booking unchanged.
-- =============================================================================
do $$ declare st text; begin
  perform set_config('request.jwt.claim.sub','c0f20000-0000-0000-0000-00000000aa02', true);
  set local role authenticated;
  begin
    perform convert_booking_to_free_first('c0f20000-0000-0000-0000-0000000f0005');
    st := 'NONE';
  exception when others then st := sqlstate; end;
  reset role;
  insert into _r values ('e', jsonb_build_object('sqlstate', st));
exception when others then reset role; raise; end $$;
select expect_text('(e) instructor refused PT403', (select v->>'sqlstate' from _r where k='e'), 'PT403');
select expect_text('(e) booking untouched (still drop_in)',
  (select payment_source::text from bookings where id='c0f20000-0000-0000-0000-0000000f0005'), 'drop_in');

-- =============================================================================
-- (a) the nine's shape converts. (owner session)
-- =============================================================================
do $$ declare ra jsonb; begin
  perform set_config('request.jwt.claim.sub','c0f20000-0000-0000-0000-00000000aa01', true);
  set local role authenticated;
  ra := convert_booking_to_free_first('c0f20000-0000-0000-0000-0000000f0001');
  reset role;
  insert into _r values ('a', ra);
exception when others then reset role; raise; end $$;
select expect_text('(a) ok', (select v->>'ok' from _r where k='a'), 'true');
select expect_text('(a) booking is now comp',
  (select payment_source::text from bookings where id='c0f20000-0000-0000-0000-0000000f0001'), 'comp');
select expect_text('(a) booking is non-provisional',
  (select provisional::text from bookings where id='c0f20000-0000-0000-0000-0000000f0001'), 'false');
select expect_num('(a) confirmed_at set',
  (select count(*) from bookings where id='c0f20000-0000-0000-0000-0000000f0001' and confirmed_at is not null), 1);
select expect_text('(a) still booked',
  (select status::text from bookings where id='c0f20000-0000-0000-0000-0000000f0001'), 'booked');
-- the host-null pass is re-pointed at the converted booking
select expect_num('(a) host-null pass re-pointed to this booking',
  (select count(*) from guest_passes where studio_id='c0f20000-0000-0000-0000-000000000001'
     and host_member_id is null and guest_member_id='c0f20000-0000-0000-0000-00000000cc0a'
     and guest_booking_id='c0f20000-0000-0000-0000-0000000f0001'), 1);
-- exactly one free_booking_confirmed, zero booking_confirmed, queued to M_A
select expect_num('(a) one free_booking_confirmed queued',
  (select count(*) from notifications where member_id='c0f20000-0000-0000-0000-00000000cc0a'
     and template_key='free_booking_confirmed'), 1);
select expect_num('(a) zero booking_confirmed queued',
  (select count(*) from notifications where member_id='c0f20000-0000-0000-0000-00000000cc0a'
     and template_key='booking_confirmed'), 0);

-- =============================================================================
-- (b) the same member, after conversion, calling book_first_free elsewhere →
-- already_had_free (the converted comp seat makes them no longer a first-timer).
-- =============================================================================
do $$ declare rb jsonb; begin
  perform set_config('request.jwt.claim.sub','c0f20000-0000-0000-0000-00000000bb0a', true);
  set local role authenticated;
  rb := book_first_free('c0f20000-0000-0000-0000-0000000d0002');
  reset role;
  insert into _r values ('b', rb);
exception when others then reset role; raise; end $$;
select expect_text('(b) rebook refused already_had_free', (select v->>'reason' from _r where k='b'), 'already_had_free');

select 'free_first_convert_test: all assertions passed' as done;
