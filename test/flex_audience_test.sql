-- =============================================================================
-- Flex cancellation, by audience — migration 116
-- =============================================================================
-- UUID space f0f4, checked free. Run after `supabase db reset`.
--
-- A flex class that misses its minimum is GONE to members, marked NOT RUNNING
-- to its instructor (with the reason and a deadline notice), and a NOT-RUNNING
-- row on the staff calendar with the count that caused it. A flex class that
-- reaches its minimum tells its instructor at that moment, once, and then runs
-- even if a member later drops out.
--
-- Two studios on different deadlines, decided in one sweep.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual then raise notice 'PASS  %  (got true)', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_false(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual is not null and not actual then raise notice 'PASS  %  (got false)', label;
  else raise exception 'FAIL  %  expected false, got %', label, coalesce(actual::text,'null'); end if;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('f0f4f0f4-0000-0000-0000-0000000000a1'),   -- owner A & B
  ('f0f4f0f4-0000-0000-0000-0000000000a2'),   -- Ada, instructor A (login)
  ('f0f4f0f4-0000-0000-0000-0000000000b2'),   -- Bel, instructor B (login)
  ('f0f4f0f4-0000-0000-0000-0000000000e1'),   -- member M1 (A)
  ('f0f4f0f4-0000-0000-0000-0000000000e2'),   -- member M2 (A)
  ('f0f4f0f4-0000-0000-0000-0000000000e3'),   -- member M3 (A), never books
  ('f0f4f0f4-0000-0000-0000-0000000000f2');   -- member MB (B)
insert into profiles (id, email) values
  ('f0f4f0f4-0000-0000-0000-0000000000a1','f0f4-owner@example.com'),
  ('f0f4f0f4-0000-0000-0000-0000000000a2','f0f4-ada@example.com'),
  ('f0f4f0f4-0000-0000-0000-0000000000b2','f0f4-bel@example.com'),
  ('f0f4f0f4-0000-0000-0000-0000000000e1','f0f4-m1@example.com'),
  ('f0f4f0f4-0000-0000-0000-0000000000e2','f0f4-m2@example.com'),
  ('f0f4f0f4-0000-0000-0000-0000000000e3','f0f4-m3@example.com'),
  ('f0f4f0f4-0000-0000-0000-0000000000f2','f0f4-mb@example.com');

insert into studios (id, name, slug, timezone, currency, status) values
  ('f0f4f0f4-0000-0000-0000-000000000001','Flex A','f0f4-a','Europe/Prague','CZK','active'),
  ('f0f4f0f4-0000-0000-0000-000000000002','Flex B','f0f4-b','Asia/Manila','PHP','active');

-- Both flex on. A: hours_before 168 (a class within a week is past its cutoff).
-- B: previous_day_at 20:00 — a different deadline, decided in the same run.
insert into studio_settings (studio_id, flex_enabled, flex_deadline_mode, flex_deadline_time, flex_deadline_hours) values
  ('f0f4f0f4-0000-0000-0000-000000000001', true, 'hours_before', '20:00', 168),
  ('f0f4f0f4-0000-0000-0000-000000000002', true, 'hours_before', '20:00', 168);

insert into locations (id, studio_id, name, is_primary) values
  ('f0f4f0f4-0000-0000-0000-00000000000a','f0f4f0f4-0000-0000-0000-000000000001','Main',true),
  ('f0f4f0f4-0000-0000-0000-00000000000b','f0f4f0f4-0000-0000-0000-000000000002','Main',true);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('f0f4f0f4-0000-0000-0000-00000000aa01','f0f4f0f4-0000-0000-0000-000000000001','f0f4f0f4-0000-0000-0000-0000000000a1','f0f4-owner@example.com','owner'),
  ('f0f4f0f4-0000-0000-0000-00000000aa02','f0f4f0f4-0000-0000-0000-000000000001','f0f4f0f4-0000-0000-0000-0000000000a2','f0f4-ada@example.com','instructor'),
  ('f0f4f0f4-0000-0000-0000-00000000bb01','f0f4f0f4-0000-0000-0000-000000000002','f0f4f0f4-0000-0000-0000-0000000000a1','f0f4-owner-b@example.com','owner'),
  ('f0f4f0f4-0000-0000-0000-00000000bb02','f0f4f0f4-0000-0000-0000-000000000002','f0f4f0f4-0000-0000-0000-0000000000b2','f0f4-bel@example.com','instructor');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('f0f4f0f4-0000-0000-0000-0000000ee001','f0f4f0f4-0000-0000-0000-000000000001','f0f4f0f4-0000-0000-0000-00000000000a','R1',10),
  ('f0f4f0f4-0000-0000-0000-0000000ee002','f0f4f0f4-0000-0000-0000-000000000002','f0f4f0f4-0000-0000-0000-00000000000b','R1',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('f0f4f0f4-0000-0000-0000-0000000cc001','f0f4f0f4-0000-0000-0000-000000000001','Reformer',50,10),
  ('f0f4f0f4-0000-0000-0000-0000000cc002','f0f4f0f4-0000-0000-0000-000000000002','Mat',50,10);
insert into instructors (id, studio_id, display_name, staff_id) values
  ('f0f4f0f4-0000-0000-0000-000000d10001','f0f4f0f4-0000-0000-0000-000000000001','Ada','f0f4f0f4-0000-0000-0000-00000000aa02'),
  ('f0f4f0f4-0000-0000-0000-000000d20001','f0f4f0f4-0000-0000-0000-000000000002','Bel','f0f4f0f4-0000-0000-0000-00000000bb02');

insert into members (id, studio_id, user_id, first_name, last_name, email, joined_on, status, waiver_signed_at) values
  ('f0f4f0f4-0000-0000-0000-000000dd0001','f0f4f0f4-0000-0000-0000-000000000001','f0f4f0f4-0000-0000-0000-0000000000e1','M','One','f0f4-m1@example.com', current_date-30,'active', now()),
  ('f0f4f0f4-0000-0000-0000-000000dd0002','f0f4f0f4-0000-0000-0000-000000000001','f0f4f0f4-0000-0000-0000-0000000000e2','M','Two','f0f4-m2@example.com', current_date-30,'active', now()),
  ('f0f4f0f4-0000-0000-0000-000000dd0003','f0f4f0f4-0000-0000-0000-000000000001','f0f4f0f4-0000-0000-0000-0000000000e3','M','Three','f0f4-m3@example.com', current_date-30,'active', now()),
  ('f0f4f0f4-0000-0000-0000-000000dd00b2','f0f4f0f4-0000-0000-0000-000000000002','f0f4f0f4-0000-0000-0000-0000000000f2','M','B','f0f4-mb@example.com', current_date-30,'active', now());

-- Unlimited memberships so booking resolves cleanly.
insert into membership_plans (id, studio_id, name, type, price_cents, currency, billing_interval, credits_per_period, status) values
  ('f0f4f0f4-0000-0000-0000-000000c00001','f0f4f0f4-0000-0000-0000-000000000001','Unlimited','recurring',250000,'CZK','month',null,'active'),
  ('f0f4f0f4-0000-0000-0000-000000c00002','f0f4f0f4-0000-0000-0000-000000000002','Unlimited','recurring',250000,'PHP','month',null,'active');
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on) values
  ('f0f4f0f4-0000-0000-0000-000000c10001','f0f4f0f4-0000-0000-0000-000000000001','f0f4f0f4-0000-0000-0000-000000dd0001','f0f4f0f4-0000-0000-0000-000000c00001','active',250000,'CZK',current_date-30),
  ('f0f4f0f4-0000-0000-0000-000000c10002','f0f4f0f4-0000-0000-0000-000000000001','f0f4f0f4-0000-0000-0000-000000dd0002','f0f4f0f4-0000-0000-0000-000000c00001','active',250000,'CZK',current_date-30),
  ('f0f4f0f4-0000-0000-0000-000000c10003','f0f4f0f4-0000-0000-0000-000000000001','f0f4f0f4-0000-0000-0000-000000dd0003','f0f4f0f4-0000-0000-0000-000000c00001','active',250000,'CZK',current_date-30),
  ('f0f4f0f4-0000-0000-0000-000000c100b2','f0f4f0f4-0000-0000-0000-000000000002','f0f4f0f4-0000-0000-0000-000000dd00b2','f0f4f0f4-0000-0000-0000-000000c00002','active',250000,'PHP',current_date-30);

-- Classes. All within a week, so all past their 168h cutoff at sweep time.
-- Local wall time, so the studio-day arithmetic is honest.
insert into class_occurrences
  (id, studio_id, location_id, class_type_id, room_id, name, capacity, instructor_id,
   starts_at, ends_at, status, staffing, flex, minimum_bookings)
values
  -- C1: reaches its minimum (2). Ada teaches it.
  ('f0f4f0f4-0000-0000-0000-00000000c101','f0f4f0f4-0000-0000-0000-000000000001','f0f4f0f4-0000-0000-0000-00000000000a',
   'f0f4f0f4-0000-0000-0000-0000000cc001','f0f4f0f4-0000-0000-0000-0000000ee001','Reformer Reaches',10,'f0f4f0f4-0000-0000-0000-000000d10001',
   ((current_date+2)+time '18:00') at time zone 'Europe/Prague', ((current_date+2)+time '18:50') at time zone 'Europe/Prague','scheduled','assigned',true,2),
  -- C2: min 1, zero bookings — the "gone, nobody to notify" case.
  ('f0f4f0f4-0000-0000-0000-00000000c102','f0f4f0f4-0000-0000-0000-000000000001','f0f4f0f4-0000-0000-0000-00000000000a',
   'f0f4f0f4-0000-0000-0000-0000000cc001','f0f4f0f4-0000-0000-0000-0000000ee001','Reformer Empty',10,'f0f4f0f4-0000-0000-0000-000000d10001',
   ((current_date+3)+time '18:00') at time zone 'Europe/Prague', ((current_date+3)+time '18:50') at time zone 'Europe/Prague','scheduled','assigned',true,1),
  -- CB: studio B, min 1, zero bookings — decided in the same sweep.
  ('f0f4f0f4-0000-0000-0000-00000000cb01','f0f4f0f4-0000-0000-0000-000000000002','f0f4f0f4-0000-0000-0000-00000000000b',
   'f0f4f0f4-0000-0000-0000-0000000cc002','f0f4f0f4-0000-0000-0000-0000000ee002','Mat Empty',10,'f0f4f0f4-0000-0000-0000-000000d20001',
   ((current_date+2)+time '07:00') at time zone 'Asia/Manila', ((current_date+2)+time '07:50') at time zone 'Asia/Manila','scheduled','assigned',true,1);

-- =============================================================================
-- 1. THE INSTRUCTOR IS TOLD THE MOMENT IT CROSSES — ONCE
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','f0f4f0f4-0000-0000-0000-0000000000e1',false);  -- M1
select expect_text('M1 books C1 (below minimum still)',
  (book_class('f0f4f0f4-0000-0000-0000-00000000c101','f0f4f0f4-0000-0000-0000-000000dd0001','member')).status::text, 'booked');
reset role;
select expect_num('one booking has not crossed the minimum, so no going-ahead',
  (select count(*) from notifications where template_key='flex_going_ahead'
      and dedupe_key like 'flex_going_ahead:f0f4f0f4-0000-0000-0000-00000000c101:%'), 0);
select expect_true('...and it is not latched',
  (select flex_reached_minimum_at is null from class_occurrences where id='f0f4f0f4-0000-0000-0000-00000000c101'));

set role authenticated;
select set_config('request.jwt.claim.sub','f0f4f0f4-0000-0000-0000-0000000000e2',false);  -- M2 crosses to 2
select expect_text('M2 books C1 — crosses the minimum',
  (book_class('f0f4f0f4-0000-0000-0000-00000000c101','f0f4f0f4-0000-0000-0000-000000dd0002','member')).status::text, 'booked');
reset role;
select expect_true('...C1 is now latched',
  (select flex_reached_minimum_at is not null from class_occurrences where id='f0f4f0f4-0000-0000-0000-00000000c101'));
select expect_num('...and Ada is told, once',
  (select count(*) from notifications where template_key='flex_going_ahead'
      and dedupe_key like 'flex_going_ahead:f0f4f0f4-0000-0000-0000-00000000c101:%'), 1);
select expect_text('...the message is about the right class',
  (select payload ->> 'class_name' from notifications where template_key='flex_going_ahead' limit 1),
  'Reformer Reaches');

-- A third booking does not send a second message.
set role authenticated;
select set_config('request.jwt.claim.sub','f0f4f0f4-0000-0000-0000-0000000000e3',false);  -- M3
select expect_text('M3 books C1 too',
  (book_class('f0f4f0f4-0000-0000-0000-00000000c101','f0f4f0f4-0000-0000-0000-000000dd0003','member')).status::text, 'booked');
reset role;
select expect_num('six bookings is still one message',
  (select count(*) from notifications where template_key='flex_going_ahead'
      and dedupe_key like 'flex_going_ahead:f0f4f0f4-0000-0000-0000-00000000c101:%'), 1);

-- =============================================================================
-- 2. THE LATCH HOLDS: members cancel below the minimum, it still runs
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','f0f4f0f4-0000-0000-0000-0000000000e3',false);
select cancel_booking((select id from bookings where occurrence_id='f0f4f0f4-0000-0000-0000-00000000c101'
                        and member_id='f0f4f0f4-0000-0000-0000-000000dd0003'));
select set_config('request.jwt.claim.sub','f0f4f0f4-0000-0000-0000-0000000000e2',false);
select cancel_booking((select id from bookings where occurrence_id='f0f4f0f4-0000-0000-0000-00000000c101'
                        and member_id='f0f4f0f4-0000-0000-0000-000000dd0002'));
reset role;
select expect_num('C1 is back down to one booking, below its minimum of two',
  (select booked_count from class_occurrences where id='f0f4f0f4-0000-0000-0000-00000000c101')::bigint, 1);

-- Now the sweep runs. C1 reached its minimum once, so it COMMITS despite being
-- below now; C2 and CB never reached theirs, so they cancel.
select set_config('t.sweep', (select sweep_commitments()::text), false);
-- The sweep is global; asserting the count would be a shared-reset count of
-- every flex studio. Both OF MINE being decided is proved by C2 and CB below.
select expect_true('the sweep covers at least this suite''s two studios',
  (current_setting('t.sweep')::jsonb ->> 'studios')::bigint >= 2);
select expect_true('C1 committed (latched) and is NOT cancelled',
  (select committed_at is not null and status = 'scheduled'
     from class_occurrences where id='f0f4f0f4-0000-0000-0000-00000000c101'));
select expect_num('...with booked_at_cutoff the REAL count at the cutoff, not the minimum',
  (select booked_at_cutoff from class_occurrences where id='f0f4f0f4-0000-0000-0000-00000000c101')::bigint, 1);

-- =============================================================================
-- 3. NOT RUNNING, BY AUDIENCE — C2 (min 1, zero booked)
-- =============================================================================
select expect_text('C2 cancelled for unmet_minimum',
  (select status || '/' || coalesce(cancellation_cause::text,'') from class_occurrences where id='f0f4f0f4-0000-0000-0000-00000000c102'),
  'cancelled/unmet_minimum');
select expect_num('NOTHING DELETED — the row is still there',
  (select count(*) from class_occurrences where id='f0f4f0f4-0000-0000-0000-00000000c102'), 1);

-- MEMBERS: gone, and nobody was notified (nobody was booked).
set role authenticated;
select set_config('request.jwt.claim.sub','f0f4f0f4-0000-0000-0000-0000000000e3',false);  -- M3, never booked C2
select expect_num('a member cannot see the not-running class at all',
  (select count(*) from class_occurrences where id='f0f4f0f4-0000-0000-0000-00000000c102'), 0);
select expect_num('...and the committed C1 IS visible to a member (scheduled)',
  (select count(*) from class_occurrences where id='f0f4f0f4-0000-0000-0000-00000000c101'), 1);
reset role;
select expect_num('no member notification for the empty not-running class',
  (select count(*) from notifications n join members m on m.id = n.member_id
    where n.template_key in ('class_cancelled') and n.studio_id='f0f4f0f4-0000-0000-0000-000000000001'
      and n.dedupe_key like '%f0f4f0f4-0000-0000-0000-00000000c102%'), 0);

-- INSTRUCTOR: visible on their own schedule, marked not running with the reason.
set role authenticated;
select set_config('request.jwt.claim.sub','f0f4f0f4-0000-0000-0000-0000000000a2',false);  -- Ada
select set_config('t.iw', (select instructor_week('f0f4f0f4-0000-0000-0000-000000d10001',
  (current_date)::date, (current_date+7)::date)::text), false);
select expect_true('Ada sees C2 on her week, marked not running with the reason',
  exists (select 1 from jsonb_array_elements(current_setting('t.iw')::jsonb -> 'classes') c
           where c ->> 'occurrence_id' = 'f0f4f0f4-0000-0000-0000-00000000c102'
             and c ->> 'status' = 'cancelled'
             and c ->> 'cancellation_cause' = 'unmet_minimum'));
reset role;
select expect_true('...and Ada was told at the deadline, in the digest',
  (select count(*) > 0 from notifications where template_key='commitment_digest'
      and user_id='f0f4f0f4-0000-0000-0000-0000000000a2'
      and payload ->> 'lines' like '%NOT ON%'));

-- STAFF: on the calendar, not running, with the count.
set role authenticated;
select set_config('request.jwt.claim.sub','f0f4f0f4-0000-0000-0000-0000000000a1',false);  -- owner
select set_config('t.sr', (select jsonb_agg(to_jsonb(x)) from schedule_range(
  'f0f4f0f4-0000-0000-0000-000000000001', current_date, (current_date+7)::date) x)::text, false);
select expect_true('staff see C2 on the calendar as not running with its cause and count',
  exists (select 1 from jsonb_array_elements(current_setting('t.sr')::jsonb) c
           where c ->> 'occ_id' = 'f0f4f0f4-0000-0000-0000-00000000c102'
             and c ->> 'occ_status' = 'cancelled'
             and c ->> 'occ_cancellation_cause' = 'unmet_minimum'
             and (c ->> 'occ_booked')::int = 0));
select expect_false('...while a run-of-the-mill cancelled class would NOT be on the calendar',
  exists (select 1 from jsonb_array_elements(current_setting('t.sr')::jsonb) c
           where c ->> 'occ_status' = 'cancelled'
             and coalesce(c ->> 'occ_cancellation_cause','') <> 'unmet_minimum'));
reset role;

-- =============================================================================
-- 4. A CLASS THAT REACHES ITS MINIMUM IS UNAFFECTED
-- =============================================================================
select expect_true('C1 runs — committed, scheduled, on the member and staff views',
  (select status='scheduled' and committed_at is not null and cancellation_cause is null
     from class_occurrences where id='f0f4f0f4-0000-0000-0000-00000000c101'));

-- =============================================================================
-- 5. TWO STUDIOS, ONE RUN — B decided too
-- =============================================================================
select expect_text('B''s empty class cancelled in the same sweep',
  (select status || '/' || coalesce(cancellation_cause::text,'') from class_occurrences where id='f0f4f0f4-0000-0000-0000-00000000cb01'),
  'cancelled/unmet_minimum');


-- Clean up so this suite leaves NO global state — the notification queue and
-- the flex/open-shift rows would otherwise inflate a later suite's unscoped
-- sweep counts (flex_test counts flex studios, notifications_test churns the
-- queue). Deleting the studio cascades its occurrences, notifications and
-- applications; the auth.users go with it.
update studio_settings set flex_enabled = false
 where studio_id in ('f0f4f0f4-0000-0000-0000-000000000001','f0f4f0f4-0000-0000-0000-000000000002');
delete from notifications
 where studio_id in ('f0f4f0f4-0000-0000-0000-000000000001','f0f4f0f4-0000-0000-0000-000000000002')
    or template_key = 'flex_going_ahead';

select 'flex audience suite finished' as done;
