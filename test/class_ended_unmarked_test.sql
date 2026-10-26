-- =============================================================================
-- Decision 82 STEP 2(c) — instructor_class_ended_unmarked: one email ~5 min
-- after a class ends, once per class, login instructors only, for studios that
-- finalise attendance, when booked members are not yet checked in.
-- =============================================================================
-- UUID space e820, checked free. Run after `supabase db reset`.
--
--   * fires for an ended (>=5 min, <=3 h) class with unmarked bookings at a
--     finalise-ON studio whose instructor has a login — ONCE, count/booked right;
--   * NOT for a class ended < 5 min ago, > 3 h ago, fully checked in, whose
--     instructor has no login, or at a finalise-OFF studio;
--   * a second run queues nothing more (dedupe);
--   * the sweep refuses a signed-in caller (42501 — service-role only).
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_eq(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual,'null'); end if;
end $$;

create or replace function run_as_auth() returns text language plpgsql as $$
begin
  set local role authenticated;
  begin perform sweep_class_ended_unmarked(); reset role; return 'OK';
  exception when others then reset role; return 'ERR:'||sqlstate; end;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('e820e820-0000-0000-0000-0000000000a1'),   -- IA login (SA)
  ('e820e820-0000-0000-0000-0000000000b1');   -- IB login (SB)
insert into profiles (id, email) select id, id::text||'@example.com' from auth.users where id::text like 'e820%';

insert into studios (id, name, slug, timezone, currency, status) values
  ('e820e820-0000-0000-0000-000000000001','SA','e820-a','Asia/Manila','PHP','active'),
  ('e820e820-0000-0000-0000-000000000002','SB','e820-b','Asia/Manila','PHP','active');
-- SA finalises attendance (the email's "or they count as no-shows" is true); SB
-- does not (the gate). Window enforcement off so the fixture can insert a check_in.
insert into studio_settings (studio_id, finalise_attendance, checkin_window_enforced) values
  ('e820e820-0000-0000-0000-000000000001', true,  false),
  ('e820e820-0000-0000-0000-000000000002', false, false);

insert into studio_staff (id, studio_id, user_id, email, role, status) values
  ('e820e820-0000-0000-0000-0000000005a1','e820e820-0000-0000-0000-000000000001','e820e820-0000-0000-0000-0000000000a1','e820-ia@example.com','instructor','active'),
  ('e820e820-0000-0000-0000-0000000005b1','e820e820-0000-0000-0000-000000000002','e820e820-0000-0000-0000-0000000000b1','e820-ib@example.com','instructor','active');

insert into instructors (id, studio_id, staff_id, display_name, status) values
  ('e820e820-0000-0000-0000-000000000a01','e820e820-0000-0000-0000-000000000001','e820e820-0000-0000-0000-0000000005a1','Ivy A','active'),   -- login
  ('e820e820-0000-0000-0000-000000000a02','e820e820-0000-0000-0000-000000000001', null,                                    'No Login','active'), -- no login
  ('e820e820-0000-0000-0000-000000000b01','e820e820-0000-0000-0000-000000000002','e820e820-0000-0000-0000-0000000005b1','Ivy B','active');   -- login, SB

insert into locations (id, studio_id, name, is_primary) values
  ('e820e820-0000-0000-0000-00000000100c','e820e820-0000-0000-0000-000000000001','A', true),
  ('e820e820-0000-0000-0000-00000000200c','e820e820-0000-0000-0000-000000000002','B', true);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('e820e820-0000-0000-0000-0000000cc001','e820e820-0000-0000-0000-000000000001','Mat',50,10),
  ('e820e820-0000-0000-0000-0000000cc002','e820e820-0000-0000-0000-000000000002','Mat',50,10);

insert into members (id, studio_id, first_name, last_name, email, waiver_signed_at) values
  ('e820e820-0000-0000-0000-0000000d0001','e820e820-0000-0000-0000-000000000001','M','One','e820-1@example.com',now()),
  ('e820e820-0000-0000-0000-0000000d0002','e820e820-0000-0000-0000-000000000001','M','Two','e820-2@example.com',now()),
  ('e820e820-0000-0000-0000-0000000d0003','e820e820-0000-0000-0000-000000000001','M','Three','e820-3@example.com',now()),
  ('e820e820-0000-0000-0000-0000000d0004','e820e820-0000-0000-0000-000000000001','M','Four','e820-4@example.com',now()),
  ('e820e820-0000-0000-0000-0000000d0005','e820e820-0000-0000-0000-000000000001','M','Five','e820-5@example.com',now()),
  ('e820e820-0000-0000-0000-0000000d0006','e820e820-0000-0000-0000-000000000001','M','Six','e820-6@example.com',now()),
  ('e820e820-0000-0000-0000-0000000d00b1','e820e820-0000-0000-0000-000000000002','M','Bee','e820-b1@example.com',now());

-- Occurrences. OA_ended: ended 10 min ago, IA (login), 2 booked unmarked.
insert into class_occurrences (id, studio_id, location_id, class_type_id, instructor_id, name,
                               starts_at, ends_at, capacity, booked_count, status) values
  ('e820e820-0000-0000-0000-0000000f0001','e820e820-0000-0000-0000-000000000001','e820e820-0000-0000-0000-00000000100c','e820e820-0000-0000-0000-0000000cc001','e820e820-0000-0000-0000-000000000a01','OA_ended',
     now()-interval '70 min', now()-interval '10 min', 10, 2, 'scheduled'),
  -- staggered so IA's classes never overlap (occ_instructor_no_overlap).
  ('e820e820-0000-0000-0000-0000000f0002','e820e820-0000-0000-0000-000000000001','e820e820-0000-0000-0000-00000000100c','e820e820-0000-0000-0000-0000000cc001','e820e820-0000-0000-0000-000000000a01','OA_allin',
     now()-interval '170 min', now()-interval '110 min', 10, 1, 'scheduled'),
  ('e820e820-0000-0000-0000-0000000f0003','e820e820-0000-0000-0000-000000000001','e820e820-0000-0000-0000-00000000100c','e820e820-0000-0000-0000-0000000cc001','e820e820-0000-0000-0000-000000000a01','OA_toosoon',
     now()-interval '9 min', now()-interval '2 min', 10, 1, 'scheduled'),
  ('e820e820-0000-0000-0000-0000000f0004','e820e820-0000-0000-0000-000000000001','e820e820-0000-0000-0000-00000000100c','e820e820-0000-0000-0000-0000000cc001','e820e820-0000-0000-0000-000000000a01','OA_old',
     now()-interval '5 h', now()-interval '4 h', 10, 1, 'scheduled'),
  ('e820e820-0000-0000-0000-0000000f0005','e820e820-0000-0000-0000-000000000001','e820e820-0000-0000-0000-00000000100c','e820e820-0000-0000-0000-0000000cc001','e820e820-0000-0000-0000-000000000a02','OA_nolo',
     now()-interval '70 min', now()-interval '10 min', 10, 1, 'scheduled'),
  ('e820e820-0000-0000-0000-0000000f00b1','e820e820-0000-0000-0000-000000000002','e820e820-0000-0000-0000-00000000200c','e820e820-0000-0000-0000-0000000cc002','e820e820-0000-0000-0000-000000000b01','OB_ended',
     now()-interval '70 min', now()-interval '10 min', 10, 1, 'scheduled');

insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at) values
  ('e820e820-0000-0000-0000-0000000b0001','e820e820-0000-0000-0000-000000000001','e820e820-0000-0000-0000-0000000f0001','e820e820-0000-0000-0000-0000000d0001','booked','member','drop_in', now()-interval '2 days'),
  ('e820e820-0000-0000-0000-0000000b0002','e820e820-0000-0000-0000-000000000001','e820e820-0000-0000-0000-0000000f0001','e820e820-0000-0000-0000-0000000d0002','booked','member','drop_in', now()-interval '2 days'),
  ('e820e820-0000-0000-0000-0000000b0003','e820e820-0000-0000-0000-000000000001','e820e820-0000-0000-0000-0000000f0002','e820e820-0000-0000-0000-0000000d0003','booked','member','drop_in', now()-interval '2 days'),  -- OA_allin (checked in below)
  ('e820e820-0000-0000-0000-0000000b0004','e820e820-0000-0000-0000-000000000001','e820e820-0000-0000-0000-0000000f0003','e820e820-0000-0000-0000-0000000d0004','booked','member','drop_in', now()-interval '2 days'),  -- OA_toosoon
  ('e820e820-0000-0000-0000-0000000b0005','e820e820-0000-0000-0000-000000000001','e820e820-0000-0000-0000-0000000f0004','e820e820-0000-0000-0000-0000000d0005','booked','member','drop_in', now()-interval '2 days'),  -- OA_old
  ('e820e820-0000-0000-0000-0000000b0006','e820e820-0000-0000-0000-000000000001','e820e820-0000-0000-0000-0000000f0005','e820e820-0000-0000-0000-0000000d0006','booked','member','drop_in', now()-interval '2 days'),  -- OA_nolo
  ('e820e820-0000-0000-0000-0000000b00b1','e820e820-0000-0000-0000-000000000002','e820e820-0000-0000-0000-0000000f00b1','e820e820-0000-0000-0000-0000000d00b1','booked','member','drop_in', now()-interval '2 days'); -- OB_ended

-- OA_allin's one member is checked in -> no unmarked booking there.
insert into check_ins (studio_id, booking_id, member_id, occurrence_id, method, checked_in_at) values
  ('e820e820-0000-0000-0000-000000000001','e820e820-0000-0000-0000-0000000b0003','e820e820-0000-0000-0000-0000000d0003','e820e820-0000-0000-0000-0000000f0002','instructor', now()-interval '15 min');

-- --- run the sweep (superuser => is_service_context) -------------------------
select sweep_class_ended_unmarked();

-- the dedupe keys per occurrence
\set ends 'class_ended_unmarked:e820e820-0000-0000-0000-0000000f0001'
\set allin 'class_ended_unmarked:e820e820-0000-0000-0000-0000000f0002'
\set soon 'class_ended_unmarked:e820e820-0000-0000-0000-0000000f0003'
\set old 'class_ended_unmarked:e820e820-0000-0000-0000-0000000f0004'
\set nolo 'class_ended_unmarked:e820e820-0000-0000-0000-0000000f0005'
\set ob 'class_ended_unmarked:e820e820-0000-0000-0000-0000000f00b1'

select expect_eq('exactly ONE instructor_class_ended_unmarked queued',
  (select count(*)::text from notifications where template_key='instructor_class_ended_unmarked'), '1');
select expect_eq('it is for OA_ended',
  (select count(*)::text from notifications where dedupe_key=:'ends'), '1');
select expect_eq('OA_ended notice is addressed to IA''s login',
  (select user_id::text from notifications where dedupe_key=:'ends'), 'e820e820-0000-0000-0000-0000000000a1');
select expect_eq('count = 2 unmarked',
  (select payload->>'count' from notifications where dedupe_key=:'ends'), '2');
select expect_eq('booked = 2',
  (select payload->>'booked' from notifications where dedupe_key=:'ends'), '2');

select expect_eq('OA_allin (all checked in) -> none', (select count(*)::text from notifications where dedupe_key=:'allin'), '0');
select expect_eq('OA_toosoon (ended < 5 min) -> none', (select count(*)::text from notifications where dedupe_key=:'soon'), '0');
select expect_eq('OA_old (ended > 3 h) -> none', (select count(*)::text from notifications where dedupe_key=:'old'), '0');
select expect_eq('OA_nolo (no-login instructor) -> none', (select count(*)::text from notifications where dedupe_key=:'nolo'), '0');
select expect_eq('OB_ended (finalise OFF studio) -> none', (select count(*)::text from notifications where dedupe_key=:'ob'), '0');

-- --- a second run queues nothing more (dedupe) -------------------------------
select sweep_class_ended_unmarked();
select expect_eq('a second run adds no second notice',
  (select count(*)::text from notifications where template_key='instructor_class_ended_unmarked'), '1');

-- --- the sweep is a background job (service-role only) ------------------------
select expect_eq('a signed-in caller cannot run the sweep (grant is the boundary)',
  run_as_auth(), 'ERR:42501');

do $$ begin raise notice 'class_ended_unmarked_test: all assertions passed'; end $$;
