-- =============================================================================
-- STUDIIOR — THE BOOK LIST READS THE MEMBER'S STATE (Decision 68 amendment)
--
--   The regression: self_check_in flips a booking to status='attended', and the
--   Book list's bookings read used to be status in ('booked','waitlisted') — so
--   a member who checked in at the door dropped out of the per-occurrence map
--   and the row fell back to "Book". This proves, as the member's OWN session
--   (RLS), that the Book-list reads now return a booked AND an attended booking
--   and the member's own check-in — the data the four-state button needs.
--
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/book_list_test.sql
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

-- --- Fixtures: b008 ---------------------------------------------------------

insert into auth.users (id) values
  ('b0080000-0000-0000-0000-0000000000a1'),   -- the member
  ('b0080000-0000-0000-0000-0000000000a2');   -- a second, unrelated member
insert into profiles (id, email) values
  ('b0080000-0000-0000-0000-0000000000a1','bl-one@example.com'),
  ('b0080000-0000-0000-0000-0000000000a2','bl-two@example.com');

insert into studios (id, name, slug, timezone, currency, status) values
  ('b0080000-0000-0000-0000-000000000001','Book List Studio','book-list','Europe/Prague','CZK','active');
insert into studio_settings (studio_id) values ('b0080000-0000-0000-0000-000000000001');
insert into locations (id, studio_id, name, latitude, longitude, self_checkin_requires_location) values
  ('b0080000-0000-0000-0000-00000000000c','b0080000-0000-0000-0000-000000000001','Main',50.08,14.42,true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('b0080000-0000-0000-0000-00000000ee01','b0080000-0000-0000-0000-000000000001',
   'b0080000-0000-0000-0000-00000000000c','Studio A',8);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('b0080000-0000-0000-0000-00000000cc01','b0080000-0000-0000-0000-000000000001','Reformer',50,8);

-- Two occurrences: O1 tomorrow (booked, before the window → Reserved); O2 soon,
-- the member checked in (attended → Checked in).
insert into class_occurrences
  (id, studio_id, class_type_id, location_id, room_id, name, starts_at, ends_at, capacity, booked_count, status)
values
  ('b0080000-0000-0000-0000-0000000cc001','b0080000-0000-0000-0000-000000000001',
   'b0080000-0000-0000-0000-00000000cc01','b0080000-0000-0000-0000-00000000000c',
   'b0080000-0000-0000-0000-00000000ee01','Reformer',
   now() + interval '1 day', now() + interval '1 day' + interval '50 min', 8, 1, 'scheduled'),
  ('b0080000-0000-0000-0000-0000000cc002','b0080000-0000-0000-0000-000000000001',
   'b0080000-0000-0000-0000-00000000cc01','b0080000-0000-0000-0000-00000000000c',
   'b0080000-0000-0000-0000-00000000ee01','Reformer',
   now() + interval '20 min', now() + interval '70 min', 8, 1, 'scheduled');

insert into members (id, studio_id, user_id, first_name, last_name, email, status) values
  ('b0080000-0000-0000-0000-00000000aa01','b0080000-0000-0000-0000-000000000001',
   'b0080000-0000-0000-0000-0000000000a1','Mem','One','bl-one@example.com','active'),
  ('b0080000-0000-0000-0000-00000000aa02','b0080000-0000-0000-0000-000000000001',
   'b0080000-0000-0000-0000-0000000000a2','Mem','Two','bl-two@example.com','active');

-- O1: booked, not checked in. O2: booked then checked in (self_check_in writes
-- status='attended' + a check_ins row) — reproduced directly.
insert into bookings (id, studio_id, occurrence_id, member_id, status, booked_at) values
  ('b0080000-0000-0000-0000-0000000bb001','b0080000-0000-0000-0000-000000000001',
   'b0080000-0000-0000-0000-0000000cc001','b0080000-0000-0000-0000-00000000aa01','booked', now()),
  ('b0080000-0000-0000-0000-0000000bb002','b0080000-0000-0000-0000-000000000001',
   'b0080000-0000-0000-0000-0000000cc002','b0080000-0000-0000-0000-00000000aa01','attended', now());
insert into check_ins (id, studio_id, booking_id, member_id, occurrence_id, checked_in_at, method) values
  ('b0080000-0000-0000-0000-0000000d1001','b0080000-0000-0000-0000-000000000001',
   'b0080000-0000-0000-0000-0000000bb002','b0080000-0000-0000-0000-00000000aa01',
   'b0080000-0000-0000-0000-0000000cc002', now(), 'self');

-- === As the member's own session (RLS) ======================================
set role authenticated;
select set_config('request.jwt.claim.sub','b0080000-0000-0000-0000-0000000000a1',false);

do $$
declare
  n_both  bigint;
  n_old   bigint;
  n_att   bigint;
  n_ci    bigint;
  s1      text;
  s2      text;
begin
  -- The Book-list bookings read (Decision 68: booked / waitlisted / ATTENDED).
  select count(*) into n_both
    from bookings
    where member_id = 'b0080000-0000-0000-0000-00000000aa01'
      and status in ('booked','waitlisted','attended');
  perform expect_num('book list query returns both the booked and the attended booking', n_both, 2);

  -- Teeth: the OLD two-status query misses the attended one — the exact bug.
  select count(*) into n_old
    from bookings
    where member_id = 'b0080000-0000-0000-0000-00000000aa01'
      and status in ('booked','waitlisted');
  perform expect_num('the OLD (booked,waitlisted) query misses the checked-in booking', n_old, 1);

  -- The attended booking is the one on O2.
  select status into s2 from bookings
    where member_id = 'b0080000-0000-0000-0000-00000000aa01'
      and occurrence_id = 'b0080000-0000-0000-0000-0000000cc002';
  perform expect_text('O2 (checked-in) booking status is attended', s2, 'attended');
  select status into s1 from bookings
    where member_id = 'b0080000-0000-0000-0000-00000000aa01'
      and occurrence_id = 'b0080000-0000-0000-0000-0000000cc001';
  perform expect_text('O1 (upcoming) booking status is booked', s1, 'booked');

  -- The self check_ins read (checkins_self_read RLS) returns the checked-in
  -- occurrence, so the Book list's checkedInSet contains it → "Checked in".
  select count(*) into n_ci
    from check_ins
    where member_id = 'b0080000-0000-0000-0000-00000000aa01'
      and occurrence_id = 'b0080000-0000-0000-0000-0000000cc002';
  perform expect_num('member reads own check-in for the checked-in class', n_ci, 1);
end $$;

reset role;

-- === A different member sees none of it (RLS boundary) =======================
set role authenticated;
select set_config('request.jwt.claim.sub','b0080000-0000-0000-0000-0000000000a2',false);

do $$
declare n bigint; nc bigint;
begin
  select count(*) into n from bookings
    where member_id = 'b0080000-0000-0000-0000-00000000aa01';
  perform expect_num('another member cannot read these bookings', n, 0);
  select count(*) into nc from check_ins
    where member_id = 'b0080000-0000-0000-0000-00000000aa01';
  perform expect_num('another member cannot read these check-ins', nc, 0);
end $$;

reset role;

\echo 'book_list_test: all assertions passed'
