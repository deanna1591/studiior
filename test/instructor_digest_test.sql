-- =============================================================================
-- Decision 101 — the instructor daily digest, and the per-class sends it
-- replaces (migration 20260833420000). UUID space d101, checked free. Run after
-- `supabase db reset`.
-- =============================================================================
--   1. Three flex classes for one coach, all on one day, decided at the cut-off
--      (two reach their minimum, one does not) -> EXACTLY ONE instructor_daily_
--      digest with a Going ahead table (2) and a Cancelled table (1), and ZERO
--      per-class core_committed / instructor_class_cancelled / flex_going_ahead
--      to the instructor.
--   2. A studio-reason cancel still sends the per-class instructor_class_cancelled,
--      and it now reads the class WITH its time ({class_when}).
--   3. A second sweep sends no second digest (deduped on instructor + date).
--   4. A coach with nothing decided gets nothing.
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
create or replace function expect_contains(label text, hay text, needle text)
returns void language plpgsql as $$
begin
  if hay is not null and position(needle in hay) > 0 then raise notice 'PASS  %  (found %)', label, needle;
  else raise exception 'FAIL  %  expected to find % in [%]', label, needle, left(coalesce(hay,'null'), 400); end if;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('d101d101-0000-0000-0000-0000000000a1'),   -- owner
  ('d101d101-0000-0000-0000-0000000000b1'),   -- instructor I1 login (decides classes)
  ('d101d101-0000-0000-0000-0000000000b2');   -- instructor I2 login (nothing decided)
insert into profiles (id, email, full_name) values
  ('d101d101-0000-0000-0000-0000000000a1','d101-owner@example.com','Owner One'),
  ('d101d101-0000-0000-0000-0000000000b1','d101-ada@example.com','Ada Example'),
  ('d101d101-0000-0000-0000-0000000000b2','d101-bo@example.com','Bo Example');

insert into studios (id, name, slug, timezone, currency, status) values
  ('d101d101-0000-0000-0000-000000000001','Digest Studio','d101-s','Europe/Prague','CZK','active');
insert into studio_settings (studio_id, flex_enabled, flex_deadline_mode, flex_deadline_time, flex_deadline_hours) values
  ('d101d101-0000-0000-0000-000000000001', true, 'hours_before', '20:00', 168);

insert into locations (id, studio_id, name, is_primary) values
  ('d101d101-0000-0000-0000-0000000000a0','d101d101-0000-0000-0000-000000000001','Main', true);
insert into studio_staff (id, studio_id, user_id, email, role, status) values
  ('d101d101-0000-0000-0000-00000000aa01','d101d101-0000-0000-0000-000000000001','d101d101-0000-0000-0000-0000000000a1','d101-owner@example.com','owner','active'),
  ('d101d101-0000-0000-0000-00000000aa02','d101d101-0000-0000-0000-000000000001','d101d101-0000-0000-0000-0000000000b1','d101-ada@example.com','instructor','active'),
  ('d101d101-0000-0000-0000-00000000aa03','d101d101-0000-0000-0000-000000000001','d101d101-0000-0000-0000-0000000000b2','d101-bo@example.com','instructor','active');
insert into instructors (id, studio_id, staff_id, display_name, status) values
  ('d101d101-0000-0000-0000-0000000011a1','d101d101-0000-0000-0000-000000000001','d101d101-0000-0000-0000-00000000aa02','Ada Example','active'),
  ('d101d101-0000-0000-0000-0000000011a2','d101d101-0000-0000-0000-000000000001','d101d101-0000-0000-0000-00000000aa03','Bo Example','active');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('d101d101-0000-0000-0000-0000000000e1','d101d101-0000-0000-0000-000000000001','d101d101-0000-0000-0000-0000000000a0','Studio A',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('d101d101-0000-0000-0000-000000cc0001','d101d101-0000-0000-0000-000000000001','Reformer Flow',50,10),
  ('d101d101-0000-0000-0000-000000cc0002','d101d101-0000-0000-0000-000000000001','Barre',50,10),
  ('d101d101-0000-0000-0000-000000cc0003','d101d101-0000-0000-0000-000000000001','Mat Pilates',50,10);
insert into members (id, studio_id, first_name, last_name, email, status) values
  ('d101d101-0000-0000-0000-000000550001','d101d101-0000-0000-0000-000000000001','Mia','One','d101-m1@example.com','active'),
  ('d101d101-0000-0000-0000-000000550002','d101d101-0000-0000-0000-000000000001','Max','Two','d101-m2@example.com','active'),
  ('d101d101-0000-0000-0000-000000550003','d101d101-0000-0000-0000-000000000001','Noa','Three','d101-m3@example.com','active');

-- I1's three flex classes, all on current_date+2 (date D). flex_deadline_hours
-- 168 puts every cut-off well in the past, so the sweep decides them now.
--   A: Reformer Flow 07:00, min 2, 2 booked -> GOING AHEAD (4 of... cap 6).
--   B: Barre 18:00, min 2, 2 booked -> GOING AHEAD.
--   C: Mat Pilates 09:00, min 3, 1 booked -> CANCELLED (1 of 3 needed).
insert into class_occurrences
  (id, studio_id, location_id, class_type_id, room_id, name, capacity, instructor_id,
   starts_at, ends_at, status, staffing, flex, guarantee_tier, minimum_bookings)
values
  ('d101d101-0000-0000-0000-00000000c0a1','d101d101-0000-0000-0000-000000000001','d101d101-0000-0000-0000-0000000000a0',
   'd101d101-0000-0000-0000-000000cc0001','d101d101-0000-0000-0000-0000000000e1','Reformer Flow',6,'d101d101-0000-0000-0000-0000000011a1',
   ((current_date+2)+time '07:00') at time zone 'Europe/Prague', ((current_date+2)+time '07:50') at time zone 'Europe/Prague','scheduled','assigned',true,'flex',2),
  ('d101d101-0000-0000-0000-00000000c0b1','d101d101-0000-0000-0000-000000000001','d101d101-0000-0000-0000-0000000000a0',
   'd101d101-0000-0000-0000-000000cc0002','d101d101-0000-0000-0000-0000000000e1','Barre',8,'d101d101-0000-0000-0000-0000000011a1',
   ((current_date+2)+time '18:00') at time zone 'Europe/Prague', ((current_date+2)+time '18:50') at time zone 'Europe/Prague','scheduled','assigned',true,'flex',2),
  ('d101d101-0000-0000-0000-00000000c0c1','d101d101-0000-0000-0000-000000000001','d101d101-0000-0000-0000-0000000000a0',
   'd101d101-0000-0000-0000-000000cc0003','d101d101-0000-0000-0000-0000000000e1','Mat Pilates',8,'d101d101-0000-0000-0000-0000000011a1',
   ((current_date+2)+time '09:00') at time zone 'Europe/Prague', ((current_date+2)+time '09:50') at time zone 'Europe/Prague','scheduled','assigned',true,'flex',3),
  -- E: a FUTURE class (current_date+10) for a studio-reason cancel in scenario 2.
  -- Not past its cut-off, so the sweep never touches it.
  ('d101d101-0000-0000-0000-00000000c0e1','d101d101-0000-0000-0000-000000000001','d101d101-0000-0000-0000-0000000000a0',
   'd101d101-0000-0000-0000-000000cc0001','d101d101-0000-0000-0000-0000000000e1','Reformer Flow',10,'d101d101-0000-0000-0000-0000000011a1',
   ((current_date+10)+time '14:00') at time zone 'Europe/Prague', ((current_date+10)+time '14:50') at time zone 'Europe/Prague','scheduled','assigned',false,'core',1);

insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source, booked_at) values
  -- A: 2 booked -> reaches min 2
  ('d101d101-0000-0000-0000-0000000b00a1','d101d101-0000-0000-0000-000000000001','d101d101-0000-0000-0000-00000000c0a1','d101d101-0000-0000-0000-000000550001','booked','comp', now()),
  ('d101d101-0000-0000-0000-0000000b00a2','d101d101-0000-0000-0000-000000000001','d101d101-0000-0000-0000-00000000c0a1','d101d101-0000-0000-0000-000000550002','booked','comp', now()),
  -- B: 2 booked -> reaches min 2
  ('d101d101-0000-0000-0000-0000000b00b1','d101d101-0000-0000-0000-000000000001','d101d101-0000-0000-0000-00000000c0b1','d101d101-0000-0000-0000-000000550001','booked','comp', now()),
  ('d101d101-0000-0000-0000-0000000b00b2','d101d101-0000-0000-0000-000000000001','d101d101-0000-0000-0000-00000000c0b1','d101d101-0000-0000-0000-000000550003','booked','comp', now()),
  -- C: 1 booked -> below min 3
  ('d101d101-0000-0000-0000-0000000b00c1','d101d101-0000-0000-0000-000000000001','d101d101-0000-0000-0000-00000000c0c1','d101d101-0000-0000-0000-000000550001','booked','comp', now());

-- Clear any member/booking notifications so the staff-side assertions are clean.
delete from notifications where studio_id = 'd101d101-0000-0000-0000-000000000001' and recipient_type <> 'staff';

-- =============================================================================
-- SCENARIO 1 — the sweep decides the day, one digest, two tables, no per-class.
-- =============================================================================
select sweep_commitments();

select expect_num('A committed (reached min 2)', (select count(*) from class_occurrences where id = 'd101d101-0000-0000-0000-00000000c0a1' and committed_at is not null), 1);
select expect_num('B committed (reached min 2)', (select count(*) from class_occurrences where id = 'd101d101-0000-0000-0000-00000000c0b1' and committed_at is not null), 1);
select expect_num('C cancelled unmet_minimum', (select count(*) from class_occurrences where id = 'd101d101-0000-0000-0000-00000000c0c1' and status = 'cancelled' and cancellation_cause = 'unmet_minimum'), 1);

select expect_num('exactly ONE daily digest for Ada',
  (select count(*) from notifications where recipient_type = 'staff' and user_id = 'd101d101-0000-0000-0000-0000000000b1' and template_key = 'instructor_daily_digest'), 1);
select expect_num('dedupe key is instructor + date',
  (select count(*) from notifications where template_key = 'instructor_daily_digest' and dedupe_key = 'instructor_digest:d101d101-0000-0000-0000-0000000011a1:' || (current_date+2)::text), 1);
select expect_num('ZERO per-class instructor sends (core_committed / instructor_class_cancelled / flex_going_ahead)',
  (select count(*) from notifications where recipient_type = 'staff' and template_key in ('core_committed','instructor_class_cancelled','flex_going_ahead')), 0);

-- The digest payload: counts + both tables with the right rows.
select expect_num('digest n_running = 2',
  (select (payload ->> 'n_running')::int from notifications where template_key = 'instructor_daily_digest' and user_id = 'd101d101-0000-0000-0000-0000000000b1'), 2);
select expect_num('digest n_cancelled = 1',
  (select (payload ->> 'n_cancelled')::int from notifications where template_key = 'instructor_daily_digest' and user_id = 'd101d101-0000-0000-0000-0000000000b1'), 1);
select expect_contains('Running table heading (Decision 103a)', (select payload ->> 'going_ahead' from notifications where template_key = 'instructor_daily_digest' and user_id = 'd101d101-0000-0000-0000-0000000000b1'), 'Running');
select expect_contains('Going ahead lists Reformer Flow', (select payload ->> 'going_ahead' from notifications where template_key = 'instructor_daily_digest' and user_id = 'd101d101-0000-0000-0000-0000000000b1'), 'Reformer Flow');
select expect_contains('Going ahead lists Barre', (select payload ->> 'going_ahead' from notifications where template_key = 'instructor_daily_digest' and user_id = 'd101d101-0000-0000-0000-0000000000b1'), 'Barre');
select expect_contains('Cancelled table heading', (select payload ->> 'cancelled' from notifications where template_key = 'instructor_daily_digest' and user_id = 'd101d101-0000-0000-0000-0000000000b1'), 'Cancelled, not enough bookings');
select expect_contains('Cancelled lists Mat Pilates', (select payload ->> 'cancelled' from notifications where template_key = 'instructor_daily_digest' and user_id = 'd101d101-0000-0000-0000-0000000000b1'), 'Mat Pilates');
select expect_contains('Cancelled shows "1 of 3 needed"', (select payload ->> 'cancelled' from notifications where template_key = 'instructor_daily_digest' and user_id = 'd101d101-0000-0000-0000-0000000000b1'), '1 of 3 needed');
select expect_contains('text going-ahead is aligned', (select payload ->> 'going_ahead_text' from notifications where template_key = 'instructor_daily_digest' and user_id = 'd101d101-0000-0000-0000-0000000000b1'), 'Reformer Flow');

-- The digest renders clean in the frame (no stripped tokens, subject carries the counts).
select expect_num('digest renders with nothing stripped',
  (select array_length(stripped, 1) from render_notification((select id from notifications where template_key = 'instructor_daily_digest' and user_id = 'd101d101-0000-0000-0000-0000000000b1'))), null);
select expect_contains('digest subject names the counts',
  (select subject from render_notification((select id from notifications where template_key = 'instructor_daily_digest' and user_id = 'd101d101-0000-0000-0000-0000000000b1'))), '2 going ahead, 1 cancelled');
select expect_contains('digest html has the See my schedule button to the instructor schedule',
  (select html_body from render_notification((select id from notifications where template_key = 'instructor_daily_digest' and user_id = 'd101d101-0000-0000-0000-0000000000b1'))), '/instructor/schedule');

-- SCENARIO 4 (interleaved): Bo decided nothing -> no digest.
select expect_num('coach with nothing decided gets no digest',
  (select count(*) from notifications where template_key = 'instructor_daily_digest' and user_id = 'd101d101-0000-0000-0000-0000000000b2'), 0);

-- =============================================================================
-- SCENARIO 2 — a studio-reason cancel still sends the per-class email, with time.
-- =============================================================================
select cancel_occurrences_for_period_run('d101d101-0000-0000-0000-00000000c0e1', 'one', 'studio_fault', 'Burst pipe');

select expect_num('studio-reason cancel queued ONE instructor_class_cancelled',
  (select count(*) from notifications where recipient_type = 'staff' and user_id = 'd101d101-0000-0000-0000-0000000000b1' and template_key = 'instructor_class_cancelled'), 1);
select expect_contains('and it now reads the class WITH its time (14:00 via {class_when})',
  (select html_body from render_notification((select id from notifications where template_key = 'instructor_class_cancelled' and user_id = 'd101d101-0000-0000-0000-0000000000b1'))), 'at 14:00');
select expect_num('its render strips nothing',
  (select array_length(stripped, 1) from render_notification((select id from notifications where template_key = 'instructor_class_cancelled' and user_id = 'd101d101-0000-0000-0000-0000000000b1'))), null);

-- =============================================================================
-- SCENARIO 3 — a second sweep sends no second digest (deduped on instructor+date).
-- =============================================================================
select sweep_commitments();
select expect_num('still exactly ONE daily digest after a second sweep',
  (select count(*) from notifications where recipient_type = 'staff' and user_id = 'd101d101-0000-0000-0000-0000000000b1' and template_key = 'instructor_daily_digest'), 1);

-- --- Anon surface EXACTLY THIRTEEN (suite helpers excluded) -------------------
select expect_num('anon surface is exactly thirteen',
  (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not like 'expect\_%'), 13);

\echo 'instructor_digest_test: all assertions passed'
