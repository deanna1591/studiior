-- =============================================================================
-- Decision 55 — per-tenant clock format (24h / 12h). Migration 20260832130000.
-- =============================================================================
-- UUID space 71fe, checked free. Run after `supabase db reset`.
--
-- What this proves:
--   1. fmt_clock() — the ONE SQL formatter — renders 24h "13:00" and 12h
--      "1:00 PM", with the edges that are easiest to get wrong: midnight
--      ("00:00" / "12:00 AM") and noon ("12:00 PM"), and "9:05 AM".
--   2. public_schedule EXPOSES the setting (studio.time_format) and keeps its
--      `time` canonical HH:MM both ways — the embed applies the face itself.
--   3. a booking-confirmation email RENDERS the studio's chosen clock (12h here,
--      24h at a default studio) — the senders route through fmt_clock.
--   4. the default is '24h', so a studio that never touches it is unchanged
--      (the all_off invariant, asserted here too).
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if;
end $$;

-- --- 1. fmt_clock edges, both formats ---------------------------------------
-- An instant at a known UTC wall time, read in UTC so the clock is exact.
select expect_text('24h one o''clock',   fmt_clock('2026-01-01 13:00+00','UTC','24h'), '13:00');
select expect_text('24h midnight',       fmt_clock('2026-01-01 00:00+00','UTC','24h'), '00:00');
select expect_text('24h noon',           fmt_clock('2026-01-01 12:00+00','UTC','24h'), '12:00');
select expect_text('24h nine oh five',   fmt_clock('2026-01-01 09:05+00','UTC','24h'), '09:05');
select expect_text('12h one o''clock',   fmt_clock('2026-01-01 13:00+00','UTC','12h'), '1:00 PM');
select expect_text('12h midnight',       fmt_clock('2026-01-01 00:00+00','UTC','12h'), '12:00 AM');
select expect_text('12h noon',           fmt_clock('2026-01-01 12:00+00','UTC','12h'), '12:00 PM');
select expect_text('12h nine oh five',   fmt_clock('2026-01-01 09:05+00','UTC','12h'), '9:05 AM');
select expect_text('default is 24h',     fmt_clock('2026-01-01 13:00+00','UTC'),       '13:00');
-- The studio zone decides the clock, not the server: 23:00 UTC is 07:00 Manila.
select expect_text('studio zone decides', fmt_clock('2026-01-01 23:00+00','Asia/Manila','24h'), '07:00');

-- --- Fixtures: one Prague studio, 12h -----------------------------------------
insert into studios (id, name, slug, timezone, currency, status) values
  ('71fe71fe-0000-0000-0000-0000000000a1','Clock Studio','71fe-clock','Europe/Prague','CZK','active');
insert into studio_settings (studio_id, time_format) values
  ('71fe71fe-0000-0000-0000-0000000000a1','12h');
insert into locations (id, studio_id, name, is_primary) values
  ('71fe71fe-0000-0000-0000-00000000000a','71fe71fe-0000-0000-0000-0000000000a1','Main',true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('71fe71fe-0000-0000-0000-000000ee00a1','71fe71fe-0000-0000-0000-0000000000a1','71fe71fe-0000-0000-0000-00000000000a','Room',10);
insert into class_types (id, studio_id, name, description, color, duration_minutes, default_capacity) values
  ('71fe71fe-0000-0000-0000-0000cccc00a1','71fe71fe-0000-0000-0000-0000000000a1','Clock Flow','Desc.','#2F4F4F',50,10);
insert into instructors (id, studio_id, display_name) values
  ('71fe71fe-0000-0000-0000-0000dddd00a1','71fe71fe-0000-0000-0000-0000000000a1','Ada Example');
insert into members (id, studio_id, first_name, last_name, email, joined_on, status) values
  ('71fe71fe-0000-0000-0000-00000aaaa0a1','71fe71fe-0000-0000-0000-0000000000a1','Mia','Member','71fe-m1@example.com',current_date-10,'active');
-- A scheduled, staffed class at 13:00 Prague, two days out (inside the window).
insert into class_occurrences
  (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, booked_count,
   starts_at, ends_at, status)
values
  ('71fe71fe-0000-0000-0000-00000ccc00a1','71fe71fe-0000-0000-0000-0000000000a1','71fe71fe-0000-0000-0000-00000000000a',
   '71fe71fe-0000-0000-0000-0000cccc00a1','71fe71fe-0000-0000-0000-000000ee00a1',
   '71fe71fe-0000-0000-0000-0000dddd00a1','Clock Flow',10,0,
   ((current_date+2)+time '13:00') at time zone 'Europe/Prague',
   ((current_date+2)+time '13:50') at time zone 'Europe/Prague','scheduled');

-- --- 2. public_schedule exposes the setting; time stays canonical HH:MM -------
select expect_text('public_schedule exposes time_format (12h)',
  (public_schedule('71fe-clock', 60) -> 'studio' ->> 'time_format'), '12h');
select expect_true('public_schedule time is canonical HH:MM, not a meridiem',
  (public_schedule('71fe-clock', 60) -> 'classes' -> 0 ->> 'time') ~ '^[0-9]{2}:[0-9]{2}$');
select expect_text('...and it is the 13:00 class',
  (public_schedule('71fe-clock', 60) -> 'classes' -> 0 ->> 'time'), '13:00');

-- flip to 24h and the exposed setting follows (time unchanged, still canonical)
update studio_settings set time_format='24h' where studio_id='71fe71fe-0000-0000-0000-0000000000a1';
delete from public_schedule_cache where slug='71fe-clock';
select expect_text('public_schedule exposes time_format (24h)',
  (public_schedule('71fe-clock', 60) -> 'studio' ->> 'time_format'), '24h');
update studio_settings set time_format='12h' where studio_id='71fe71fe-0000-0000-0000-0000000000a1';

-- --- 3. a booking confirmation renders the studio's clock ---------------------
-- Inserting a booked row fires tg_queue_booking_notifications -> the sender,
-- which builds `when` through fmt_clock. Studio is 12h, so it carries a meridiem.
insert into bookings (studio_id, occurrence_id, member_id, status) values
  ('71fe71fe-0000-0000-0000-0000000000a1','71fe71fe-0000-0000-0000-00000ccc00a1',
   '71fe71fe-0000-0000-0000-00000aaaa0a1','booked');
select expect_true('booking_confirmed renders a 12h clock (1:00 PM)',
  (select payload->>'when' from notifications
     where template_key='booking_confirmed'
       and payload->>'class_name'='Clock Flow'
     order by created_at desc limit 1) like '%1:00 PM%');

-- 24h studio renders the same class as 13:00 (second member, after a flip).
update studio_settings set time_format='24h' where studio_id='71fe71fe-0000-0000-0000-0000000000a1';
insert into members (id, studio_id, first_name, last_name, email, joined_on, status) values
  ('71fe71fe-0000-0000-0000-00000aaaa0a2','71fe71fe-0000-0000-0000-0000000000a1','Nia','Member','71fe-m2@example.com',current_date-10,'active');
insert into bookings (studio_id, occurrence_id, member_id, status) values
  ('71fe71fe-0000-0000-0000-0000000000a1','71fe71fe-0000-0000-0000-00000ccc00a1',
   '71fe71fe-0000-0000-0000-00000aaaa0a2','booked');
select expect_true('booking_confirmed renders a 24h clock (13:00)',
  (select payload->>'when' from notifications
     where template_key='booking_confirmed'
       and payload->>'class_name'='Clock Flow'
       and member_id='71fe71fe-0000-0000-0000-00000aaaa0a2'
     order by created_at desc limit 1) like '%13:00%');

-- --- 4. the default is 24h (all_off invariant) --------------------------------
insert into studios (id, name, slug, timezone, currency, status) values
  ('71fe71fe-0000-0000-0000-0000000000b1','Default Studio','71fe-default','Europe/Prague','CZK','active');
insert into studio_settings (studio_id) values ('71fe71fe-0000-0000-0000-0000000000b1');
select expect_text('a studio that never touches it defaults to 24h',
  (select time_format from studio_settings where studio_id='71fe71fe-0000-0000-0000-0000000000b1'), '24h');

select 'time_format_test: all assertions passed' as result;
