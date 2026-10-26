-- =============================================================================
-- Decision 14 (c) — the health clock starts when the studio does.
-- =============================================================================
-- UUID space 14c0, checked free. Run after `supabase db reset`.
--
--   (a) member joined 30 days ago, studio NOT open  -> insufficient_history
--   (b) studio opened 20 days ago, member joined 30 days ago, 0 visits
--                                                   -> first_month_stalled
--   (c) convert_keep_sweep is a no-op for an unopened studio (0 notifications,
--       0 tasks), even with every sequence switch ON
--   (d) member joined 5 days ago, studio opened 10 days ago -> new
--   + studio_opened_on: NULL for an unopened studio, the first attended date else
--
-- RED on the old member_health/convert_keep_sweep (drifting + a task created);
-- GREEN with migration 20260832920000.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_eq(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual,'null'); end if;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into studios (id, name, slug, timezone, currency, status) values
  ('14c014c0-0000-0000-0000-000000000001','SA unopened','14c0-a','Asia/Manila','PHP','active'),
  ('14c014c0-0000-0000-0000-000000000002','SB opened 20d','14c0-b','Asia/Manila','PHP','active'),
  ('14c014c0-0000-0000-0000-000000000003','SC opened 10d','14c0-c','Asia/Manila','PHP','active');
-- SA: every sequence ON (to prove the sweep still does nothing when unopened).
insert into studio_settings (studio_id, convert_sequence_enabled, keep_sequence_enabled, retention_tasks_enabled) values
  ('14c014c0-0000-0000-0000-000000000001', true, true, true);
insert into studio_settings (studio_id) values
  ('14c014c0-0000-0000-0000-000000000002'),
  ('14c014c0-0000-0000-0000-000000000003');

insert into locations (id, studio_id, name, is_primary) values
  ('14c014c0-0000-0000-0000-00000000100c','14c014c0-0000-0000-0000-000000000001','A', true),
  ('14c014c0-0000-0000-0000-00000000200c','14c014c0-0000-0000-0000-000000000002','B', true),
  ('14c014c0-0000-0000-0000-00000000300c','14c014c0-0000-0000-0000-000000000003','C', true);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('14c014c0-0000-0000-0000-0000000cc001','14c014c0-0000-0000-0000-000000000001','Mat',50,10),
  ('14c014c0-0000-0000-0000-0000000cc002','14c014c0-0000-0000-0000-000000000002','Mat',50,10),
  ('14c014c0-0000-0000-0000-0000000cc003','14c014c0-0000-0000-0000-000000000003','Mat',50,10);

-- Members. joined_on drives the OLD clock; the fix moves it to the studio open.
insert into members (id, studio_id, first_name, last_name, email, joined_on, status) values
  ('14c014c0-0000-0000-0000-0000000d00a1','14c014c0-0000-0000-0000-000000000001','Ma','Unopened','14c0-ma@example.com', current_date - 30, 'lead'),  -- (a)+(c)
  ('14c014c0-0000-0000-0000-0000000d00b0','14c014c0-0000-0000-0000-000000000002','Bo','Opener','14c0-bo@example.com',   current_date - 40, 'active'),-- opens SB
  ('14c014c0-0000-0000-0000-0000000d00b1','14c014c0-0000-0000-0000-000000000002','Mb','Stalled','14c0-mb@example.com',  current_date - 30, 'lead'),  -- (b)
  ('14c014c0-0000-0000-0000-0000000d00c0','14c014c0-0000-0000-0000-000000000003','Co','Opener','14c0-co@example.com',   current_date - 20, 'active'),-- opens SC
  ('14c014c0-0000-0000-0000-0000000d00c1','14c014c0-0000-0000-0000-000000000003','Mc','New','14c0-mc@example.com',      current_date - 5,  'lead');   -- (d)

-- Occurrences. SA: a past scheduled class with NO attendance (so NOT opened).
-- SB: an occurrence 20 days ago with an ATTENDED booking (opens the studio 20d ago).
-- SC: an occurrence 10 days ago, attended (opens 10d ago).
insert into class_occurrences (id, studio_id, location_id, class_type_id, name, starts_at, ends_at, capacity, booked_count, status) values
  ('14c014c0-0000-0000-0000-0000000f00a1','14c014c0-0000-0000-0000-000000000001','14c014c0-0000-0000-0000-00000000100c','14c014c0-0000-0000-0000-0000000cc001','SA class',
     now()-interval '5 days', now()-interval '5 days'+interval '50 min', 10, 0, 'scheduled'),
  ('14c014c0-0000-0000-0000-0000000f00b1','14c014c0-0000-0000-0000-000000000002','14c014c0-0000-0000-0000-00000000200c','14c014c0-0000-0000-0000-0000000cc002','SB class',
     now()-interval '20 days', now()-interval '20 days'+interval '50 min', 10, 1, 'scheduled'),
  ('14c014c0-0000-0000-0000-0000000f00c1','14c014c0-0000-0000-0000-000000000003','14c014c0-0000-0000-0000-00000000300c','14c014c0-0000-0000-0000-0000000cc003','SC class',
     now()-interval '10 days', now()-interval '10 days'+interval '50 min', 10, 1, 'scheduled');

-- The opening attendance (an attended booking is enough; no check_in needed).
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at) values
  ('14c014c0-0000-0000-0000-0000000bb0b1','14c014c0-0000-0000-0000-000000000002','14c014c0-0000-0000-0000-0000000f00b1','14c014c0-0000-0000-0000-0000000d00b0','attended','member','drop_in', now()-interval '21 days'),
  ('14c014c0-0000-0000-0000-0000000bb0c1','14c014c0-0000-0000-0000-000000000003','14c014c0-0000-0000-0000-0000000f00c1','14c014c0-0000-0000-0000-0000000d00c0','attended','member','drop_in', now()-interval '11 days');

-- --- studio_opened_on --------------------------------------------------------
select expect_eq('studio_opened_on: unopened studio is NULL',
  (select studio_opened_on('14c014c0-0000-0000-0000-000000000001')::text), null);
select expect_eq('studio_opened_on: SB is the attended occurrence date (20 days ago)',
  (select studio_opened_on('14c014c0-0000-0000-0000-000000000002')::text),
  ((now()-interval '20 days') at time zone 'Asia/Manila')::date::text);

-- A studio that onboarded by IMPORTING history has opened — an imported check-in
-- (occurrence_id null, import_id set) is the studio running in its prior system.
insert into imports (id, studio_id, type, filename, status) values
  ('14c014c0-0000-0000-0000-0000000149c0','14c014c0-0000-0000-0000-000000000001','attendance','history.csv','complete');
insert into check_ins (studio_id, member_id, import_id, method, checked_in_at) values
  ('14c014c0-0000-0000-0000-000000000001','14c014c0-0000-0000-0000-0000000d00a1','14c014c0-0000-0000-0000-0000000149c0','import', now()-interval '45 days');
select expect_eq('studio_opened_on: imported history opens the studio (45 days ago)',
  (select studio_opened_on('14c014c0-0000-0000-0000-000000000001')::text),
  ((now()-interval '45 days') at time zone 'Asia/Manila')::date::text);
select expect_eq('an imported-history studio is NOT insufficient_history (the clock ran in the old system)',
  ((member_health('14c014c0-0000-0000-0000-0000000d00a1') ->> 'band') <> 'insufficient_history')::text, 'true');
-- Clear it again so the (a)/(c) unopened-studio assertions below still hold.
delete from check_ins where import_id='14c014c0-0000-0000-0000-0000000149c0';
delete from imports where id='14c014c0-0000-0000-0000-0000000149c0';

-- --- (a) unopened studio -> insufficient_history -----------------------------
select expect_eq('(a) joined 30d ago, studio not open -> insufficient_history',
  (member_health('14c014c0-0000-0000-0000-0000000d00a1') ->> 'band'), 'insufficient_history');

-- --- (b) opened 20d ago, joined 30d ago, 0 visits -> first_month_stalled -----
select expect_eq('(b) first_month_stalled signal fires from the window start',
  ((member_health('14c014c0-0000-0000-0000-0000000d00b1') -> 'signals') @> '["first_month_stalled"]')::text, 'true');
select expect_eq('(b) and the band is drifting (one non-severe signal)',
  (member_health('14c014c0-0000-0000-0000-0000000d00b1') ->> 'band'), 'drifting');

-- --- (d) joined 5d ago, opened 10d ago -> new --------------------------------
select expect_eq('(d) joined 5d ago (window = joined) -> new',
  (member_health('14c014c0-0000-0000-0000-0000000d00c1') ->> 'band'), 'new');

-- --- (c) the sweep is a no-op for an unopened studio -------------------------
select convert_keep_sweep('14c014c0-0000-0000-0000-000000000001', now());
select expect_eq('(c) unopened studio: 0 notifications queued by the sweep',
  (select count(*)::text from notifications where studio_id='14c014c0-0000-0000-0000-000000000001'), '0');
select expect_eq('(c) unopened studio: 0 member_tasks created',
  (select count(*)::text from member_tasks where studio_id='14c014c0-0000-0000-0000-000000000001'), '0');

do $$ begin raise notice 'health_clock_test: all assertions passed'; end $$;
