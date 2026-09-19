-- =============================================================================
-- Decision 33 Part B — the subscribable calendar feed (migration 162).
-- UUID space `feed`, checked free.
-- =============================================================================
-- The eleventh pre-login surface. A member's token returns THEIR future booked
-- classes; an instructor's token their assigned classes; another person's token
-- sees none of mine; a revoked token is refused; a draft month is absent; and a
-- new booking raises the instructor event's SEQUENCE so a subscribed calendar
-- re-syncs the headcount. Plus the month-roster attachment deferred from Part A.
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
create or replace function expect_false(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual is false then raise notice 'PASS  %  (got false)', label;
  else raise exception 'FAIL  %  expected false, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function login(uid text) returns void
language plpgsql as $$ begin perform set_config('request.jwt.claim.sub', uid, false); end $$;
-- Count VEVENTs in a feed.
create or replace function ve_count(p text) returns bigint
language sql as $$ select coalesce((length(coalesce(p,'')) - length(replace(coalesce(p,''),'BEGIN:VEVENT','')))
                                   / length('BEGIN:VEVENT'), 0)::bigint $$;
-- The SEQUENCE of the VEVENT whose UID is p_uid, within a multi-event feed.
create or replace function seq_of(p_feed text, p_uid text) returns bigint
language sql as $$
  select (substring(
    substring(p_feed from 'UID:' || p_uid || '.*?END:VEVENT') from 'SEQUENCE:([0-9]+)'))::bigint
$$;

-- --- Fixtures ---------------------------------------------------------------
insert into auth.users (id) values
  ('feedfeed-0000-0000-0000-0000000000a1'),   -- S1 owner
  ('feedfeed-0000-0000-0000-0000000000c1'),   -- S1 instructor login
  ('feedfeed-0000-0000-0000-0000000000b1'),   -- S1 member A
  ('feedfeed-0000-0000-0000-0000000000b2'),   -- S1 member B
  ('feedfeed-0000-0000-0000-0000000000a2'),   -- S2 owner
  ('feedfeed-0000-0000-0000-0000000000c2'),   -- S2 instructor login
  ('feedfeed-0000-0000-0000-0000000000b3');   -- S2 member C
insert into profiles (id, email) values
  ('feedfeed-0000-0000-0000-0000000000a1','feed-o1@example.com'),
  ('feedfeed-0000-0000-0000-0000000000c1','feed-c1@example.com'),
  ('feedfeed-0000-0000-0000-0000000000b1','feed-a@example.com'),
  ('feedfeed-0000-0000-0000-0000000000b2','feed-b@example.com'),
  ('feedfeed-0000-0000-0000-0000000000a2','feed-o2@example.com'),
  ('feedfeed-0000-0000-0000-0000000000c2','feed-c2@example.com'),
  ('feedfeed-0000-0000-0000-0000000000b3','feed-c@example.com');

-- S1: publication OFF (everything published). S2: publication ON (for the draft).
insert into studios (id, name, slug, timezone, currency, status) values
  ('feedfeed-0000-0000-0000-000000000001','Feed One','feed1','Europe/Prague','CZK','active'),
  ('feedfeed-0000-0000-0000-000000000002','Feed Two','feed2','Europe/Prague','CZK','active');
insert into studio_settings (studio_id) values ('feedfeed-0000-0000-0000-000000000001');
insert into studio_settings (studio_id, publication_enabled) values ('feedfeed-0000-0000-0000-000000000002', true);

insert into locations (id, studio_id, name, timezone, is_primary, status, address) values
  ('feedfeed-0000-0000-0000-0000000000f1','feedfeed-0000-0000-0000-000000000001','Main','Europe/Prague',true,'active',
   jsonb_build_object('line1','Reformer Row 1','city','Prague','country','CZ')),
  ('feedfeed-0000-0000-0000-0000000000f2','feedfeed-0000-0000-0000-000000000002','Main','Europe/Prague',true,'active',
   jsonb_build_object('line1','Reformer Row 2','city','Prague','country','CZ'));
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('feedfeed-0000-0000-0000-0000000000e1','feedfeed-0000-0000-0000-000000000001','feedfeed-0000-0000-0000-0000000000f1','A',8),
  ('feedfeed-0000-0000-0000-0000000000e2','feedfeed-0000-0000-0000-000000000002','feedfeed-0000-0000-0000-0000000000f2','A',8);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('feedfeed-0000-0000-0000-0000000000c9','feedfeed-0000-0000-0000-000000000001','Reformer Flow',50,8),
  ('feedfeed-0000-0000-0000-00000000000a','feedfeed-0000-0000-0000-000000000002','Mat Pilates',50,8);

insert into studio_staff (id, studio_id, user_id, role, status, email) values
  ('feedfeed-0000-0000-0000-000000005501','feedfeed-0000-0000-0000-000000000001','feedfeed-0000-0000-0000-0000000000a1','owner','active','feed-o1@example.com'),
  ('feedfeed-0000-0000-0000-000000005502','feedfeed-0000-0000-0000-000000000001','feedfeed-0000-0000-0000-0000000000c1','instructor','active','feed-c1@example.com'),
  ('feedfeed-0000-0000-0000-000000005503','feedfeed-0000-0000-0000-000000000002','feedfeed-0000-0000-0000-0000000000a2','owner','active','feed-o2@example.com'),
  ('feedfeed-0000-0000-0000-000000005504','feedfeed-0000-0000-0000-000000000002','feedfeed-0000-0000-0000-0000000000c2','instructor','active','feed-c2@example.com');
insert into instructors (id, studio_id, staff_id, display_name) values
  ('feedfeed-0000-0000-0000-0000000000d1','feedfeed-0000-0000-0000-000000000001','feedfeed-0000-0000-0000-000000005502','Cy Coach'),
  ('feedfeed-0000-0000-0000-0000000000d2','feedfeed-0000-0000-0000-000000000002','feedfeed-0000-0000-0000-000000005504','Di Coach');

insert into members (id, studio_id, user_id, first_name, last_name, email, status) values
  ('feedfeed-0000-0000-0000-0000000000b1','feedfeed-0000-0000-0000-000000000001','feedfeed-0000-0000-0000-0000000000b1','Ana','A','feed-a@example.com','active'),
  ('feedfeed-0000-0000-0000-0000000000b2','feedfeed-0000-0000-0000-000000000001','feedfeed-0000-0000-0000-0000000000b2','Ben','B','feed-b@example.com','active'),
  ('feedfeed-0000-0000-0000-0000000000b3','feedfeed-0000-0000-0000-000000000002','feedfeed-0000-0000-0000-0000000000b3','Cara','C','feed-c@example.com','active');

-- S1 future classes, both taught by I1: X1 (Ana booked), X2 (Ben booked).
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id,
                               name, capacity, starts_at, ends_at) values
  ('feedfeed-0000-0000-0000-00000000a001','feedfeed-0000-0000-0000-000000000001','feedfeed-0000-0000-0000-0000000000f1',
   'feedfeed-0000-0000-0000-0000000000c9','feedfeed-0000-0000-0000-0000000000e1','feedfeed-0000-0000-0000-0000000000d1',
   'Reformer Flow',8, now() + interval '3 days', now() + interval '3 days' + interval '50 min'),
  ('feedfeed-0000-0000-0000-00000000a002','feedfeed-0000-0000-0000-000000000001','feedfeed-0000-0000-0000-0000000000f1',
   'feedfeed-0000-0000-0000-0000000000c9','feedfeed-0000-0000-0000-0000000000e1','feedfeed-0000-0000-0000-0000000000d1',
   'Reformer Flow',8, now() + interval '5 days', now() + interval '5 days' + interval '50 min');
insert into bookings (id, studio_id, occurrence_id, member_id, status) values
  ('feedfeed-0000-0000-0000-00000000bb01','feedfeed-0000-0000-0000-000000000001','feedfeed-0000-0000-0000-00000000a001','feedfeed-0000-0000-0000-0000000000b1','booked'),
  ('feedfeed-0000-0000-0000-00000000bb02','feedfeed-0000-0000-0000-000000000001','feedfeed-0000-0000-0000-00000000a002','feedfeed-0000-0000-0000-0000000000b2','booked');
update class_occurrences set booked_count = 1 where id in
  ('feedfeed-0000-0000-0000-00000000a001','feedfeed-0000-0000-0000-00000000a002');

-- S2 class in NEXT month (a draft while publication is on), Cara booked.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id,
                               name, capacity, starts_at, ends_at) values
  ('feedfeed-0000-0000-0000-00000000a003','feedfeed-0000-0000-0000-000000000002','feedfeed-0000-0000-0000-0000000000f2',
   'feedfeed-0000-0000-0000-00000000000a','feedfeed-0000-0000-0000-0000000000e2','feedfeed-0000-0000-0000-0000000000d2',
   'Mat Pilates',8,
   ((date_trunc('month', now() at time zone 'Europe/Prague') + interval '1 month')::date + time '10:00') at time zone 'Europe/Prague',
   ((date_trunc('month', now() at time zone 'Europe/Prague') + interval '1 month')::date + time '10:50') at time zone 'Europe/Prague');
insert into bookings (id, studio_id, occurrence_id, member_id, status) values
  ('feedfeed-0000-0000-0000-00000000bb03','feedfeed-0000-0000-0000-000000000002','feedfeed-0000-0000-0000-00000000a003','feedfeed-0000-0000-0000-0000000000b3','booked');
update class_occurrences set booked_count = 1 where id = 'feedfeed-0000-0000-0000-00000000a003';

-- =============================================================================
-- 1. A MEMBER'S FEED = THEIR OWN FUTURE BOOKED CLASS, AND NO OTHER MEMBER'S
-- =============================================================================
set role authenticated;
select login('feedfeed-0000-0000-0000-0000000000b1');   -- Ana
select set_config('t.ta', mint_calendar_feed('feedfeed-0000-0000-0000-000000000001','member'), false);
select login('feedfeed-0000-0000-0000-0000000000b2');   -- Ben
select set_config('t.tb', mint_calendar_feed('feedfeed-0000-0000-0000-000000000001','member'), false);
reset role;
select login('');

select expect_true('two distinct tokens were minted',
  current_setting('t.ta') <> current_setting('t.tb') and length(current_setting('t.ta')) = 48);

set role anon;
select expect_true('Ana''s feed is a well-formed VCALENDAR, METHOD PUBLISH',
  calendar_feed(current_setting('t.ta')) ~ 'BEGIN:VCALENDAR'
    and calendar_feed(current_setting('t.ta')) ~ 'METHOD:PUBLISH');
select expect_num('Ana''s feed has exactly her one booking',
  ve_count(calendar_feed(current_setting('t.ta'))), 1);
select expect_true('...its UID is Ana''s booking',
  calendar_feed(current_setting('t.ta')) ~ 'UID:feedfeed-0000-0000-0000-00000000bb01');
select expect_false('Ana''s feed does NOT contain Ben''s booking',
  calendar_feed(current_setting('t.ta')) ~ 'feedfeed-0000-0000-0000-00000000bb02');
select expect_true('Ben''s feed contains Ben''s booking and not Ana''s',
  calendar_feed(current_setting('t.tb')) ~ 'UID:feedfeed-0000-0000-0000-00000000bb02'
    and calendar_feed(current_setting('t.tb')) !~ 'feedfeed-0000-0000-0000-00000000bb01');
reset role;

-- =============================================================================
-- 2. AN INSTRUCTOR'S FEED = THEIR ASSIGNED CLASSES, UID = OCCURRENCE, NO BOOKINGS
-- =============================================================================
set role authenticated;
select login('feedfeed-0000-0000-0000-0000000000c1');   -- instructor I1
select set_config('t.ti', mint_calendar_feed('feedfeed-0000-0000-0000-000000000001','instructor'), false);
reset role;
select login('');

set role anon;
select expect_num('instructor feed has both assigned classes',
  ve_count(calendar_feed(current_setting('t.ti'))), 2);
select expect_true('instructor events are keyed by occurrence id, not booking',
  calendar_feed(current_setting('t.ti')) ~ 'UID:feedfeed-0000-0000-0000-00000000a001'
    and calendar_feed(current_setting('t.ti')) ~ 'UID:feedfeed-0000-0000-0000-00000000a002');
select expect_false('no member booking id leaks into the instructor feed',
  calendar_feed(current_setting('t.ti')) ~ 'feedfeed-0000-0000-0000-00000000bb0');
reset role;

-- =============================================================================
-- 3. A NEW BOOKING RAISES THE INSTRUCTOR EVENT'S SEQUENCE (re-sync the headcount)
-- =============================================================================
set role anon;
select set_config('t.seq0', seq_of(calendar_feed(current_setting('t.ti')), 'feedfeed-0000-0000-0000-00000000a001')::text, false);
reset role;

-- A booking bumps the occurrence's updated_at (book_class does the same
-- booked_count UPDATE, which fires set_updated_at). pg_sleep so the epoch moves.
select pg_sleep(1);
insert into auth.users (id) values ('feedfeed-0000-0000-0000-0000000000b9');
insert into profiles (id, email) values ('feedfeed-0000-0000-0000-0000000000b9','feed-b9@example.com');
insert into members (id, studio_id, user_id, first_name, last_name, email, status) values
  ('feedfeed-0000-0000-0000-0000000000b9','feedfeed-0000-0000-0000-000000000001','feedfeed-0000-0000-0000-0000000000b9','Ned','N','feed-b9@example.com','active');
insert into bookings (id, studio_id, occurrence_id, member_id, status) values
  ('feedfeed-0000-0000-0000-00000000bb09','feedfeed-0000-0000-0000-000000000001','feedfeed-0000-0000-0000-00000000a001','feedfeed-0000-0000-0000-0000000000b9','booked');
update class_occurrences set booked_count = 2 where id = 'feedfeed-0000-0000-0000-00000000a001';
-- The cache would otherwise serve the pre-booking feed; clear it (a real
-- subscriber crosses the 5-minute TTL).
truncate calendar_feed_cache;

set role anon;
select expect_true('a new booking raised the instructor event''s SEQUENCE in the feed',
  seq_of(calendar_feed(current_setting('t.ti')), 'feedfeed-0000-0000-0000-00000000a001')
    > current_setting('t.seq0')::bigint);
select expect_true('...and the headcount in the body is now 2',
  calendar_feed(current_setting('t.ti')) ~ '2 booked');
reset role;

-- =============================================================================
-- 4. A REVOKED TOKEN IS REFUSED
-- =============================================================================
set role authenticated;
select login('feedfeed-0000-0000-0000-0000000000b1');   -- Ana
select revoke_calendar_feed('feedfeed-0000-0000-0000-000000000001','member');
reset role;
select login('');
truncate calendar_feed_cache;

set role anon;
select expect_true('a revoked token returns null (the route 404s)',
  calendar_feed(current_setting('t.ta')) is null);
select expect_true('an unknown token returns null',
  calendar_feed('deadbeef' || repeat('0', 40)) is null);
reset role;

-- Ana can re-mint: a fresh, different, working token.
set role authenticated;
select login('feedfeed-0000-0000-0000-0000000000b1');
select set_config('t.ta2', mint_calendar_feed('feedfeed-0000-0000-0000-000000000001','member'), false);
reset role;
select login('');
select expect_true('the re-minted token differs from the revoked one',
  current_setting('t.ta2') <> current_setting('t.ta'));
set role anon;
select expect_num('the re-minted token works',
  ve_count(calendar_feed(current_setting('t.ta2'))), 1);
reset role;

-- =============================================================================
-- 5. A DRAFT MONTH IS ABSENT; PUBLISHING BRINGS IT INTO THE FEED
-- =============================================================================
set role authenticated;
select login('feedfeed-0000-0000-0000-0000000000b3');   -- Cara (S2, publication on)
select set_config('t.tc', mint_calendar_feed('feedfeed-0000-0000-0000-000000000002','member'), false);
reset role;
select login('');

set role anon;
select expect_num('Cara''s draft-month class is NOT in her feed',
  ve_count(calendar_feed(current_setting('t.tc'))), 0);
reset role;

-- The studio publishes next month.
set role authenticated;
select login('feedfeed-0000-0000-0000-0000000000a2');   -- S2 owner
select publish_month('feedfeed-0000-0000-0000-000000000002',
  (date_trunc('month', now() at time zone 'Europe/Prague') + interval '1 month')::date);
reset role;
select login('');
truncate calendar_feed_cache;

set role anon;
select expect_num('once published, the class appears in Cara''s feed',
  ve_count(calendar_feed(current_setting('t.tc'))), 1);
reset role;

-- =============================================================================
-- 6. THE MONTH-ROSTER ATTACHMENT (deferred from Part A)
-- =============================================================================
-- publish_month queued a month_roster notice to instructor I2 (who has a login);
-- notification_ics builds the whole-month multi-event calendar from it.
select expect_true('a month_roster notice was queued to the instructor',
  exists(select 1 from notifications where template_key = 'month_roster'
           and studio_id = 'feedfeed-0000-0000-0000-000000000002'));
select expect_true('its .ics is a multi-event VCALENDAR carrying the month''s class',
  (select notification_ics(id) from notifications
     where template_key = 'month_roster' and studio_id = 'feedfeed-0000-0000-0000-000000000002' limit 1)
    ~ 'BEGIN:VCALENDAR');
select expect_true('...with the occurrence as a VEVENT UID',
  (select notification_ics(id) from notifications
     where template_key = 'month_roster' and studio_id = 'feedfeed-0000-0000-0000-000000000002' limit 1)
    ~ 'UID:feedfeed-0000-0000-0000-00000000a003');

-- =============================================================================
-- 7. THE ANON SURFACE IS EXACTLY ELEVEN, calendar_feed NAMED
-- =============================================================================
-- The expect_% helpers this suite defines are PUBLIC-executable by Postgres
-- default; they are excluded, as public_schedule_test does.
select expect_num('exactly eleven real functions are executable by anon',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not like 'expect\_%' and p.proname not in ('login','ve_count','seq_of'))::bigint, 11);
select expect_true('calendar_feed is one of them',
  has_function_privilege('anon', 'calendar_feed(text)'::regprocedure, 'execute'));
select expect_false('anon cannot read the token table directly',
  has_table_privilege('anon', 'calendar_tokens', 'select'));
select expect_false('anon cannot read the feed cache directly',
  has_table_privilege('anon', 'calendar_feed_cache', 'select'));

-- =============================================================================
-- 8. GUARDS: a member cannot mint an instructor feed, or a feed for a studio
--    they are not in.
-- =============================================================================
set role authenticated;
select login('feedfeed-0000-0000-0000-0000000000b1');   -- Ana, an S1 member
do $$ begin
  perform mint_calendar_feed('feedfeed-0000-0000-0000-000000000001','instructor');
  raise exception 'FAIL a member minted an instructor feed';
exception when sqlstate 'PT403' then raise notice 'PASS  a member cannot mint an instructor feed (PT403)';
end $$;
do $$ begin
  perform mint_calendar_feed('feedfeed-0000-0000-0000-000000000002','member');
  raise exception 'FAIL Ana minted a feed at a studio she is not in';
exception when sqlstate 'PT403' then raise notice 'PASS  no feed for a studio you are not in (PT403)';
end $$;
reset role;
select login('');

select 'calendar_feed_test: all assertions passed' as result;
