-- =============================================================================
-- Decision 30 amendment (b) — per-class "Open to first-timers" override.
-- =============================================================================
-- UUID space 30b0, checked free. Run after `supabase db reset`.
--
--   * core_only excludes a flex class (list + book_first_free flex_not_allowed);
--   * override 'open' includes it and makes it bookable; the free seat is
--     PROVISIONAL (confirm_at set) and released by the provisional machinery;
--   * override 'closed' on a core class excludes it (free_first_closed_here);
--   * the seat cap still refuses on an 'open' class (free_seats_full);
--   * front desk can set the override, an instructor cannot (PT403);
--   * a past / cancelled class is refused as a reason;
--   * clearing (null) restores the studio rules.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_eq(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual,'null'); end if;
end $$;

-- in the member's eligible list?
create or replace function in_list(p_studio uuid, p_member uuid, p_occ uuid) returns boolean
language sql stable as $$
  select exists (select 1 from free_first_eligible_classes_run(p_studio, p_member, 0) where occurrence_id = p_occ); $$;

-- book_first_free as a member session: 'OK:prov' | 'OK' | <reason> | 'ERR:<code>'
create or replace function bff(p_uid text, p_occ uuid) returns text language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claim.sub', p_uid, true); set local role authenticated;
  begin
    r := book_first_free(p_occ); reset role;
    if coalesce((r->>'ok')::boolean,false) then
      return case when coalesce((r->>'provisional')::boolean,false) then 'OK:prov' else 'OK' end;
    end if;
    return coalesce(r->>'reason','?');
  exception when others then reset role; return 'ERR:'||sqlstate; end;
end $$;

-- set_free_first_override as a session: 'OK' | <reason> | 'ERR:<code>'
create or replace function sfo(p_uid text, p_occ uuid, p_val text) returns text language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claim.sub', p_uid, true); set local role authenticated;
  begin
    r := set_free_first_override(p_occ, p_val); reset role;
    if coalesce((r->>'ok')::boolean,false) then return 'OK'; end if;
    return coalesce(r->>'reason','?');
  exception when others then reset role; return 'ERR:'||sqlstate; end;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('30b00000-0000-0000-0000-0000000000fd'),  -- front desk
  ('30b00000-0000-0000-0000-0000000000e5'),  -- instructor (placeholder, fixed below)
  ('30b00000-0000-0000-0000-00000000b001'),
  ('30b00000-0000-0000-0000-00000000b002'),
  ('30b00000-0000-0000-0000-00000000b003'),
  ('30b00000-0000-0000-0000-00000000b004');
insert into profiles (id, email) select id, id::text||'@example.com' from auth.users where id::text like '30b0%';

insert into studios (id, name, slug, timezone, currency, status) values
  ('30b00000-0000-0000-0000-000000000001','Override Studio','ff-override','Europe/Prague','CZK','active');
insert into studio_settings (studio_id, guarantees_enabled, flex_enabled,
   free_first_class_enabled, free_first_core_only, free_first_confirm_at, free_first_seats_per_class,
   free_first_peak_allowed, booking_window_days, booking_cutoff_minutes,
   cancellation_cutoff_minutes, core_cutoff_hours, core_min_bookings, flex_min_bookings, checkin_window_enforced)
 values ('30b00000-0000-0000-0000-000000000001', true, true,
   true, true, 3, 1, true, 90, 0, 720, 12, 1, 2, false);

insert into studio_staff (id, studio_id, user_id, email, role, status) values
  ('30b00000-0000-0000-0000-00000005500f','30b00000-0000-0000-0000-000000000001','30b00000-0000-0000-0000-0000000000fd','ff-fd@example.com','front_desk','active'),
  ('30b00000-0000-0000-0000-00000005500e','30b00000-0000-0000-0000-000000000001','30b00000-0000-0000-0000-0000000000e5','ff-ins@example.com','instructor','active');
insert into instructors (id, studio_id, staff_id, display_name, status) values
  ('30b00000-0000-0000-0000-0000000a0001','30b00000-0000-0000-0000-000000000001','30b00000-0000-0000-0000-00000005500e','Coach','active');

insert into locations (id, studio_id, name, is_primary) values
  ('30b00000-0000-0000-0000-00000000010c','30b00000-0000-0000-0000-000000000001','Main',true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('30b00000-0000-0000-0000-0000000000e1','30b00000-0000-0000-0000-000000000001','30b00000-0000-0000-0000-00000000010c','A',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('30b00000-0000-0000-0000-0000000000c1','30b00000-0000-0000-0000-000000000001','Mat',50,10);

-- eligible leads with logins
insert into members (id, studio_id, user_id, first_name, last_name, email, status, waiver_signed_at) values
  ('30b00000-0000-0000-0000-00000000d001','30b00000-0000-0000-0000-000000000001','30b00000-0000-0000-0000-00000000b001','L','One','ff1@example.com','lead',now()),
  ('30b00000-0000-0000-0000-00000000d002','30b00000-0000-0000-0000-000000000001','30b00000-0000-0000-0000-00000000b002','L','Two','ff2@example.com','lead',now()),
  ('30b00000-0000-0000-0000-00000000d003','30b00000-0000-0000-0000-000000000001','30b00000-0000-0000-0000-00000000b003','L','Three','ff3@example.com','lead',now()),
  ('30b00000-0000-0000-0000-00000000d004','30b00000-0000-0000-0000-000000000001','30b00000-0000-0000-0000-00000000b004','L','Four','ff4@example.com','lead',now());

-- Occurrences: FLEX (guarantee_tier flex), CORE, CAP (flex, for the cap test),
-- PAST, CANCELLED. Published month: Reform-style; month_published is true when
-- publication is off (default), so these are visible.
insert into class_occurrences (id, studio_id, location_id, class_type_id, instructor_id, name,
         starts_at, ends_at, capacity, booked_count, status, guarantee_tier) values
  ('30b00000-0000-0000-0000-0000000f1e00','30b00000-0000-0000-0000-000000000001','30b00000-0000-0000-0000-00000000010c','30b00000-0000-0000-0000-0000000000c1','30b00000-0000-0000-0000-0000000a0001','Flex Slot',
     now()+interval '5 days', now()+interval '5 days 50 min', 10, 0, 'scheduled', 'flex'),
  ('30b00000-0000-0000-0000-0000000c0e00','30b00000-0000-0000-0000-000000000001','30b00000-0000-0000-0000-00000000010c','30b00000-0000-0000-0000-0000000000c1','30b00000-0000-0000-0000-0000000a0001','Core Slot',
     now()+interval '5 days 2 h', now()+interval '5 days 170 min', 10, 0, 'scheduled', 'core'),
  ('30b00000-0000-0000-0000-0000000ca900','30b00000-0000-0000-0000-000000000001','30b00000-0000-0000-0000-00000000010c','30b00000-0000-0000-0000-0000000000c1','30b00000-0000-0000-0000-0000000a0001','Cap Slot',
     now()+interval '5 days 4 h', now()+interval '5 days 290 min', 10, 1, 'scheduled', 'flex'),
  ('30b00000-0000-0000-0000-0000000a5700','30b00000-0000-0000-0000-000000000001','30b00000-0000-0000-0000-00000000010c','30b00000-0000-0000-0000-0000000000c1','30b00000-0000-0000-0000-0000000a0001','Past Slot',
     now()-interval '1 day', now()-interval '1 day' + interval '50 min', 10, 0, 'scheduled', 'core'),
  ('30b00000-0000-0000-0000-0000000ca7c0','30b00000-0000-0000-0000-000000000001','30b00000-0000-0000-0000-00000000010c','30b00000-0000-0000-0000-0000000000c1','30b00000-0000-0000-0000-0000000a0001','Cancelled Slot',
     now()+interval '5 days 6 h', now()+interval '5 days 410 min', 10, 0, 'cancelled', 'core');

-- Fill CAP's one free seat with a comp booking by L4 (so the cap is already hit).
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at, provisional) values
  ('30b00000-0000-0000-0000-0000000bca04','30b00000-0000-0000-0000-000000000001','30b00000-0000-0000-0000-0000000ca900','30b00000-0000-0000-0000-00000000d004','booked','member','comp', now(), true);
insert into guest_passes (id, studio_id, guest_email, guest_booking_id, host_member_id, guest_member_id, occurrence_id, status) values
  ('30b00000-0000-0000-0000-0000000dca04','30b00000-0000-0000-0000-000000000001','ff4@example.com','30b00000-0000-0000-0000-0000000bca04', null, '30b00000-0000-0000-0000-00000000d004','30b00000-0000-0000-0000-0000000ca900','confirmed');

-- --- (1) core_only excludes the flex class --------------------------------
select expect_eq('flex class is NOT in the eligible list under core_only',
  in_list('30b00000-0000-0000-0000-000000000001','30b00000-0000-0000-0000-00000000d001','30b00000-0000-0000-0000-0000000f1e00')::text, 'false');
select expect_eq('book_first_free on the flex class is flex_not_allowed',
  bff('30b00000-0000-0000-0000-00000000b001','30b00000-0000-0000-0000-0000000f1e00'), 'flex_not_allowed');

-- --- (2) front desk opens it; instructor cannot ---------------------------
select expect_eq('an instructor cannot set the override (PT403)',
  sfo('30b00000-0000-0000-0000-0000000000e5','30b00000-0000-0000-0000-0000000f1e00','open'), 'ERR:PT403');
select expect_eq('front desk sets override open',
  sfo('30b00000-0000-0000-0000-0000000000fd','30b00000-0000-0000-0000-0000000f1e00','open'), 'OK');
select expect_eq('effective_free_first reports open via override',
  (effective_free_first('30b00000-0000-0000-0000-0000000f1e00') ->> 'effective_open'), 'true');
select expect_eq('why = override',
  (effective_free_first('30b00000-0000-0000-0000-0000000f1e00') ->> 'why'), 'override');

-- --- (3) now included + bookable, the free seat PROVISIONAL (confirm_at 3) --
select expect_eq('the opened flex class is now in the eligible list',
  in_list('30b00000-0000-0000-0000-000000000001','30b00000-0000-0000-0000-00000000d001','30b00000-0000-0000-0000-0000000f1e00')::text, 'true');
select expect_eq('book_first_free on the opened flex class succeeds, provisional',
  bff('30b00000-0000-0000-0000-00000000b001','30b00000-0000-0000-0000-0000000f1e00'), 'OK:prov');
select expect_eq('the booking is provisional',
  (select provisional::text from bookings where occurrence_id='30b00000-0000-0000-0000-0000000f1e00' and member_id='30b00000-0000-0000-0000-00000000d001'), 'true');

-- the provisional seat is released by the amendment (a) machinery
select release_provisional_seats_run('30b00000-0000-0000-0000-0000000f1e00');
select expect_eq('the provisional seat is released (trial_not_confirmed)',
  (select status::text||'/'||release_reason::text from bookings where occurrence_id='30b00000-0000-0000-0000-0000000f1e00' and member_id='30b00000-0000-0000-0000-00000000d001'), 'cancelled/trial_not_confirmed');
select expect_eq('the once-ever guest_passes row is gone (free class kept)',
  (select count(*)::text from guest_passes gp join bookings b on b.id=gp.guest_booking_id where b.occurrence_id='30b00000-0000-0000-0000-0000000f1e00' and b.member_id='30b00000-0000-0000-0000-00000000d001'), '0');

-- --- (4) override closed on a core class ----------------------------------
select expect_eq('front desk closes the core class',
  sfo('30b00000-0000-0000-0000-0000000000fd','30b00000-0000-0000-0000-0000000c0e00','closed'), 'OK');
select expect_eq('the closed core class is NOT in the eligible list',
  in_list('30b00000-0000-0000-0000-000000000001','30b00000-0000-0000-0000-00000000d002','30b00000-0000-0000-0000-0000000c0e00')::text, 'false');
select expect_eq('book_first_free on the closed class is free_first_closed_here',
  bff('30b00000-0000-0000-0000-00000000b002','30b00000-0000-0000-0000-0000000c0e00'), 'free_first_closed_here');
select expect_eq('effective_free_first reports closed',
  (effective_free_first('30b00000-0000-0000-0000-0000000c0e00') ->> 'effective_open'), 'false');

-- --- (5) seat cap still refuses on an OPEN class --------------------------
select expect_eq('front desk opens the cap (flex) class',
  sfo('30b00000-0000-0000-0000-0000000000fd','30b00000-0000-0000-0000-0000000ca900','open'), 'OK');
select expect_eq('the cap still refuses a free booking on an open class',
  bff('30b00000-0000-0000-0000-00000000b003','30b00000-0000-0000-0000-0000000ca900'), 'free_seats_full');

-- --- (6) past / cancelled refused as reasons ------------------------------
select expect_eq('setting the override on a past class is refused',
  sfo('30b00000-0000-0000-0000-0000000000fd','30b00000-0000-0000-0000-0000000a5700','open'), 'past_class');
select expect_eq('setting the override on a cancelled class is refused',
  sfo('30b00000-0000-0000-0000-0000000000fd','30b00000-0000-0000-0000-0000000ca7c0','open'), 'cancelled');

-- --- (7) clearing restores the rules --------------------------------------
-- re-open a fresh flex occurrence is overkill; clear the cap class's override:
-- a flex class with no override under core_only is rules-closed again.
select expect_eq('front desk clears the override (follow studio rules)',
  sfo('30b00000-0000-0000-0000-0000000000fd','30b00000-0000-0000-0000-0000000ca900', null), 'OK');
select expect_eq('cleared flex class is rules-closed again',
  (effective_free_first('30b00000-0000-0000-0000-0000000ca900') ->> 'effective_open'), 'false');
select expect_eq('and book_first_free is flex_not_allowed again',
  bff('30b00000-0000-0000-0000-00000000b003','30b00000-0000-0000-0000-0000000ca900'), 'flex_not_allowed');

select 'free_first_override_test OK' as result;
