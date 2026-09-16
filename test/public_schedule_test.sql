-- =============================================================================
-- public_schedule(slug) — the tenth pre-login surface (migration 147)
-- =============================================================================
-- UUID space ec40, checked free. Run after `supabase db reset`.
--
-- The endpoint a studio embeds on its marketing site. It is ANON, so the whole
-- test is about what a stranger may and may not see:
--   * published months only (Decision 25) — an unpublished month is absent;
--   * no member data — a booked member's name is nowhere in the payload;
--   * a cancelled or not-running class is absent, like the member app;
--   * instructor FIRST NAME and photo only — no surname, no bio, no contact;
--   * spaces derived from capacity and booked_count, clamped;
--   * two studios return their own schedules;
--   * it is anon-reachable AND the anon surface is now exactly TEN, no more.
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
  if actual then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_false(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual is not null and not actual then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected false, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if;
end $$;

-- --- Fixtures ----------------------------------------------------------------
-- Two Prague studios. A does not use publication (everything published); B does.
insert into studios (id, name, slug, timezone, currency, status, accent_color, theme_preset, logo_url) values
  ('ec40ec40-0000-0000-0000-0000000000a1','Alpha Studio','ec40-alpha','Europe/Prague','CZK','active','#123456','warm','alpha/logo.png'),
  ('ec40ec40-0000-0000-0000-0000000000b1','Bravo Studio','ec40-bravo','Europe/Prague','CZK','active','#ABCDEF','calm',null);
insert into studio_settings (studio_id) values
  ('ec40ec40-0000-0000-0000-0000000000a1'),
  ('ec40ec40-0000-0000-0000-0000000000b1');
-- B uses publication; its months are drafts until published.
update studio_settings set publication_enabled = true where studio_id = 'ec40ec40-0000-0000-0000-0000000000b1';

insert into locations (id, studio_id, name, is_primary) values
  ('ec40ec40-0000-0000-0000-00000000000a','ec40ec40-0000-0000-0000-0000000000a1','Main',true),
  ('ec40ec40-0000-0000-0000-00000000000b','ec40ec40-0000-0000-0000-0000000000b1','Main',true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('ec40ec40-0000-0000-0000-000000ee00a1','ec40ec40-0000-0000-0000-0000000000a1','ec40ec40-0000-0000-0000-00000000000a','Studio A Room',10),
  ('ec40ec40-0000-0000-0000-000000ee00b1','ec40ec40-0000-0000-0000-0000000000b1','ec40ec40-0000-0000-0000-00000000000b','Studio B Room',10);
insert into class_types (id, studio_id, name, description, color, duration_minutes, default_capacity) values
  ('ec40ec40-0000-0000-0000-0000cccc00a1','ec40ec40-0000-0000-0000-0000000000a1','Alpha Flow','Alpha class description.','#2F4F4F',50,10),
  ('ec40ec40-0000-0000-0000-0000cccc00b1','ec40ec40-0000-0000-0000-0000000000b1','Bravo Barre','Bravo class description.','#B85C38',45,10);
-- Instructor: FIRST name must survive, surname and bio must NOT appear anywhere.
insert into instructors (id, studio_id, display_name, bio) values
  ('ec40ec40-0000-0000-0000-0000dddd00a1','ec40ec40-0000-0000-0000-0000000000a1','Xavier SURNAMELEAK','BIOLEAK should never be public.'),
  ('ec40ec40-0000-0000-0000-0000dddd00b1','ec40ec40-0000-0000-0000-0000000000b1','Yolanda Bravoson',null);

-- A member of studio A with a DISTINCTIVE name, booked into a returned class,
-- so "no member data" is a real test rather than a vacuous one.
insert into members (id, studio_id, first_name, last_name, email, joined_on, status) values
  ('ec40ec40-0000-0000-0000-00000aaaa0a1'::uuid,'ec40ec40-0000-0000-0000-0000000000a1','MEMBERLEAK','Nope','ec40-m1@example.com', current_date-10,'active');

-- Occurrences in the window (2 days out, at fixed local hours). All Prague.
-- A1: normal, one seat taken (spaces 9). A2: cancelled. A3: not-running flex.
-- A4: full. B1: in the current local month, publication ON but unpublished.
insert into class_occurrences
  (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, booked_count,
   starts_at, ends_at, status, cancellation_cause)
values
  ('ec40ec40-0000-0000-0000-00000cccc0a1','ec40ec40-0000-0000-0000-0000000000a1','ec40ec40-0000-0000-0000-00000000000a',
   'ec40ec40-0000-0000-0000-0000cccc00a1','ec40ec40-0000-0000-0000-000000ee00a1','ec40ec40-0000-0000-0000-0000dddd00a1',
   'Alpha Flow',10,1,
   ((current_date+2)+time '07:00') at time zone 'Europe/Prague', ((current_date+2)+time '07:50') at time zone 'Europe/Prague','scheduled',null),
  ('ec40ec40-0000-0000-0000-00000cccc0a2','ec40ec40-0000-0000-0000-0000000000a1','ec40ec40-0000-0000-0000-00000000000a',
   'ec40ec40-0000-0000-0000-0000cccc00a1','ec40ec40-0000-0000-0000-000000ee00a1','ec40ec40-0000-0000-0000-0000dddd00a1',
   'Alpha Flow',10,0,
   ((current_date+2)+time '09:00') at time zone 'Europe/Prague', ((current_date+2)+time '09:50') at time zone 'Europe/Prague','cancelled',null),
  ('ec40ec40-0000-0000-0000-00000cccc0a3','ec40ec40-0000-0000-0000-0000000000a1','ec40ec40-0000-0000-0000-00000000000a',
   'ec40ec40-0000-0000-0000-0000cccc00a1','ec40ec40-0000-0000-0000-000000ee00a1','ec40ec40-0000-0000-0000-0000dddd00a1',
   'Alpha Flow',10,0,
   ((current_date+2)+time '11:00') at time zone 'Europe/Prague', ((current_date+2)+time '11:50') at time zone 'Europe/Prague','cancelled','unmet_minimum'),
  ('ec40ec40-0000-0000-0000-00000cccc0a4','ec40ec40-0000-0000-0000-0000000000a1','ec40ec40-0000-0000-0000-00000000000a',
   'ec40ec40-0000-0000-0000-0000cccc00a1','ec40ec40-0000-0000-0000-000000ee00a1','ec40ec40-0000-0000-0000-0000dddd00a1',
   'Alpha Flow',10,10,
   ((current_date+3)+time '07:00') at time zone 'Europe/Prague', ((current_date+3)+time '07:50') at time zone 'Europe/Prague','scheduled',null),
  ('ec40ec40-0000-0000-0000-00000cccc0b1','ec40ec40-0000-0000-0000-0000000000b1','ec40ec40-0000-0000-0000-00000000000b',
   'ec40ec40-0000-0000-0000-0000cccc00b1','ec40ec40-0000-0000-0000-000000ee00b1','ec40ec40-0000-0000-0000-0000dddd00b1',
   'Bravo Barre',10,2,
   ((current_date+2)+time '18:00') at time zone 'Europe/Prague', ((current_date+2)+time '18:45') at time zone 'Europe/Prague','scheduled',null);

-- The member's booking into A1 (direct, so no book_class side effects).
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source, booked_at) values
  ('ec40ec40-0000-0000-0000-0000bbbb00a1','ec40ec40-0000-0000-0000-0000000000a1','ec40ec40-0000-0000-0000-00000cccc0a1',
   'ec40ec40-0000-0000-0000-00000aaaa0a1'::uuid,'booked','drop_in', now());

-- Charlie: a studio whose timetable starts 30 days out (opening / sparse), with
-- the one class UNASSIGNED — proves the look-ahead (upcoming) AND that a null
-- instructor is omitted, never advertised. Delta: no classes at all (empty).
insert into studios (id, name, slug, timezone, currency, status) values
  ('ec40ec40-0000-0000-0000-0000000000c1','Charlie Studio','ec40-charlie','Europe/Prague','CZK','active'),
  ('ec40ec40-0000-0000-0000-0000000000d1','Delta Studio','ec40-delta','Europe/Prague','CZK','active');
insert into studio_settings (studio_id) values
  ('ec40ec40-0000-0000-0000-0000000000c1'), ('ec40ec40-0000-0000-0000-0000000000d1');
insert into locations (id, studio_id, name, is_primary) values
  ('ec40ec40-0000-0000-0000-00000000000c','ec40ec40-0000-0000-0000-0000000000c1','Main',true);
insert into class_types (id, studio_id, name, description, color, duration_minutes, default_capacity) values
  ('ec40ec40-0000-0000-0000-0000cccc00c1','ec40ec40-0000-0000-0000-0000000000c1','Charlie Flow','Later.','#654321',50,10);
insert into class_occurrences
  (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, booked_count, starts_at, ends_at, status)
values
  ('ec40ec40-0000-0000-0000-00000cccc0c1','ec40ec40-0000-0000-0000-0000000000c1','ec40ec40-0000-0000-0000-00000000000c',
   'ec40ec40-0000-0000-0000-0000cccc00c1', null, null, 'Charlie Flow', 10, 0,
   ((current_date+30)+time '09:00') at time zone 'Europe/Prague', ((current_date+30)+time '09:50') at time zone 'Europe/Prague','scheduled');

-- =============================================================================
-- 1. THE ENDPOINT IS ANON-REACHABLE, and returns Alpha's own schedule
-- =============================================================================
set role anon;
select set_config('request.jwt.claim.sub', null, true);

select set_config('t.a', public_schedule('ec40-alpha', 7)::text, false);
select expect_true('anon can read the public schedule',
  (current_setting('t.a')::jsonb ->> 'found')::boolean);
-- A1 and A4 are the only visible ones: A2 (cancelled), A3 (not-running) absent.
select expect_num('Alpha returns its two visible classes (cancelled + not-running absent)',
  jsonb_array_length(current_setting('t.a')::jsonb -> 'classes'), 2);

-- The cancelled and not-running ids must not be anywhere in the payload.
select expect_false('the cancelled class is absent',
  current_setting('t.a') like '%ec40ec40-0000-0000-0000-00000cccc0a2%');
select expect_false('the not-running flex class is absent',
  current_setting('t.a') like '%ec40ec40-0000-0000-0000-00000cccc0a3%');

-- =============================================================================
-- 2. NO MEMBER DATA, and spaces derived from capacity - booked_count
-- =============================================================================
select expect_false('the booked member name is NOT in the payload',
  current_setting('t.a') like '%MEMBERLEAK%');
-- A1: capacity 10, one booked -> 9 spaces, not full.
select set_config('t.a1', (
  select c::text from jsonb_array_elements(current_setting('t.a')::jsonb -> 'classes') c
   where c ->> 'id' = 'ec40ec40-0000-0000-0000-00000cccc0a1'), false);
select expect_num('A1 spaces_left = capacity - booked_count',
  (current_setting('t.a1')::jsonb ->> 'spaces_left')::bigint, 9);
select expect_false('A1 is not full', (current_setting('t.a1')::jsonb ->> 'full')::boolean);

-- A4: full house -> full true, spaces clamped to 0. A "full 7am" still shows.
select set_config('t.a4', (
  select c::text from jsonb_array_elements(current_setting('t.a')::jsonb -> 'classes') c
   where c ->> 'id' = 'ec40ec40-0000-0000-0000-00000cccc0a4'), false);
select expect_true('A4 (full house) still appears', current_setting('t.a4') is not null);
select expect_true('A4 reads full', (current_setting('t.a4')::jsonb ->> 'full')::boolean);
select expect_num('A4 spaces clamped to 0', (current_setting('t.a4')::jsonb ->> 'spaces_left')::bigint, 0);

-- =============================================================================
-- 3. INSTRUCTOR: first name and photo only — no surname, no bio, no contact
-- =============================================================================
select expect_text('instructor first name only',
  current_setting('t.a1')::jsonb ->> 'instructor_first_name', 'Xavier');
select expect_false('the surname never appears', current_setting('t.a') like '%SURNAMELEAK%');
select expect_false('the bio never appears', current_setting('t.a') like '%BIOLEAK%');

-- =============================================================================
-- 4. PUBLISHED MONTHS ONLY — Bravo's unpublished month is absent, then present
-- =============================================================================
select set_config('t.b', public_schedule('ec40-bravo', 7)::text, false);
select expect_num('Bravo (publication on, month unpublished) returns nothing',
  jsonb_array_length(current_setting('t.b')::jsonb -> 'classes'), 0);
-- ...and SAYS it is unpublished, not merely empty — this is the case a studio
-- pasting the embed before publishing must be able to read.
select expect_text('...with state=unpublished',
  current_setting('t.b')::jsonb ->> 'state', 'unpublished');

reset role;
-- Publish Bravo's month (the class's own local month), the way the studio would.
insert into schedule_publications (studio_id, month, published_at, auto)
values ('ec40ec40-0000-0000-0000-0000000000b1',
        date_trunc('month', ((current_date+2)::timestamp) )::date, now(), false);
-- The unpublished result was cached (5 min TTL) — real behaviour, so bust it to
-- see the publish immediately, as a studio would after the window elapses.
delete from public_schedule_cache where slug = 'ec40-bravo';

set role anon;
select set_config('t.b2', public_schedule('ec40-bravo', 7)::text, false);
select expect_num('once the month is published, Bravo returns its class',
  jsonb_array_length(current_setting('t.b2')::jsonb -> 'classes'), 1);
select expect_text('...and state is in_window', current_setting('t.b2')::jsonb ->> 'state', 'in_window');

-- =============================================================================
-- 5. TWO STUDIOS RETURN DIFFERENT SCHEDULES
-- =============================================================================
select expect_text('Alpha names itself',
  current_setting('t.a')::jsonb -> 'studio' ->> 'name', 'Alpha Studio');
select expect_text('Bravo names itself',
  current_setting('t.b2')::jsonb -> 'studio' ->> 'name', 'Bravo Studio');
select expect_false('Bravo does not carry any of Alpha''s classes',
  current_setting('t.b2') like '%Alpha Flow%');
select expect_true('Bravo carries its own class', current_setting('t.b2') like '%Bravo Barre%');
-- The branding the embed reads is each studio's own.
select expect_text('Alpha accent', current_setting('t.a')::jsonb -> 'studio' ->> 'accent_color', '#123456');
select expect_text('Bravo accent', current_setting('t.b2')::jsonb -> 'studio' ->> 'accent_color', '#ABCDEF');

-- =============================================================================
-- 6. UNKNOWN SLUG reveals nothing; the CACHE serves a repeat hit
-- =============================================================================
select expect_false('an unknown slug is not found',
  (public_schedule('no-such-studio', 7)::jsonb ->> 'found')::boolean);

-- Two calls in the TTL return the byte-identical payload (generated_at frozen).
select expect_text('a repeat hit is served from cache (same generated_at)',
  public_schedule('ec40-alpha', 7)::jsonb ->> 'generated_at',
  current_setting('t.a')::jsonb ->> 'generated_at');
reset role;

-- =============================================================================
-- 7. THE ANON SURFACE IS NOW EXACTLY TEN — public_schedule and no other new one
-- =============================================================================
-- Exactly ten pre-login surfaces — the nine plus public_schedule, and nothing
-- else. The `expect_%` helpers this suite defines are PUBLIC-executable by
-- Postgres default (harmless in a test DB), so they are excluded; every other
-- anon-executable function is a real surface and must be one of the ten. (The
-- hosted advisor is the true gate — local and hosted ACLs differ — but this
-- catches a stray grant before it ships.)
select expect_num('exactly ten real functions are executable by anon',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not like 'expect\_%')::bigint, 10);
select expect_true('public_schedule is one of them',
  has_function_privilege('anon', 'public_schedule(text,int)'::regprocedure, 'execute'));
-- The cache table is closed to clients.
select expect_false('anon cannot read the cache table directly',
  has_table_privilege('anon', 'public_schedule_cache', 'select'));

-- =============================================================================
-- 8. STATES — in_window / upcoming (look-ahead) / empty, and a null instructor
--    is OMITTED, never "TBC"
-- =============================================================================
set role anon;
select set_config('t.cha', public_schedule('ec40-charlie', 7)::text, false);
select expect_text('Alpha this week -> in_window',
  current_setting('t.a')::jsonb ->> 'state', 'in_window');
select expect_text('Charlie (classes 30 days out) -> upcoming',
  current_setting('t.cha')::jsonb ->> 'state', 'upcoming');
select expect_true('...upcoming carries next_from',
  (current_setting('t.cha')::jsonb ->> 'next_from') is not null);
select expect_num('...and returns the next class rather than nothing',
  jsonb_array_length(current_setting('t.cha')::jsonb -> 'classes'), 1);
-- Charlie's class is unassigned: the instructor line is null (omitted by the
-- embed), never advertised as "TBC" (Decision 17).
select expect_true('an unassigned class exposes a NULL instructor (nothing to advertise)',
  ((current_setting('t.cha')::jsonb -> 'classes') -> 0 ->> 'instructor_first_name') is null);
select expect_true('...and no avatar either',
  ((current_setting('t.cha')::jsonb -> 'classes') -> 0 ->> 'instructor_avatar_url') is null);
select expect_text('Delta (no classes) -> empty',
  public_schedule('ec40-delta', 7)::jsonb ->> 'state', 'empty');
reset role;

select 'public_schedule_test: all assertions passed' as done;
