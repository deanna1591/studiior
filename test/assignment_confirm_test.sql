-- =============================================================================
-- Decision 38 — instructors confirm the classes the studio assigns them.
-- Plus Decision 37 amendment (c) — series_availability_warning.
-- UUID space: ac38
-- =============================================================================
\set S1 '''ac38ac38-0000-0000-0000-000000000001'''
\set S2 '''ac38ac38-0000-0000-0000-000000000002'''

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want::text,'null'), coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if coalesce(actual,false) then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if;
end $$;
create or replace function expect_raises(label text, sql text, code text)
returns void language plpgsql as $$
begin
  execute sql;
  raise exception 'FAIL  %  expected % , nothing raised', label, code;
exception when others then
  if sqlstate = code then raise notice 'PASS  %  (got %)', label, code;
  else raise exception 'FAIL  %  expected %, got % (%)', label, code, sqlstate, sqlerrm; end if;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('ac38ac38-0000-0000-0000-0000000000a1'),   -- owner S1
  ('ac38ac38-0000-0000-0000-000000000d11'),   -- instructor D1 login
  ('ac38ac38-0000-0000-0000-000000000d22'),   -- instructor D2 login
  ('ac38ac38-0000-0000-0000-0000000000b1');   -- owner S2
insert into profiles (id, email) values
  ('ac38ac38-0000-0000-0000-0000000000a1','ac38-owner1@example.com'),
  ('ac38ac38-0000-0000-0000-000000000d11','ac38-d1@example.com'),
  ('ac38ac38-0000-0000-0000-000000000d22','ac38-d2@example.com'),
  ('ac38ac38-0000-0000-0000-0000000000b1','ac38-owner2@example.com');

insert into studios (id, name, slug, timezone, currency, status) values
  ('ac38ac38-0000-0000-0000-000000000001','Confirm On','confirm-on','Europe/Prague','CZK','active'),
  ('ac38ac38-0000-0000-0000-000000000002','Confirm Off','confirm-off','Europe/Prague','CZK','active');
-- S1: the setting ON. S2: OFF. Neither uses publication (month_published => true).
insert into studio_settings (studio_id, assignment_confirmations, publication_enabled) values
  ('ac38ac38-0000-0000-0000-000000000001', true,  false),
  ('ac38ac38-0000-0000-0000-000000000002', false, false);
insert into locations (id, studio_id, name, is_primary) values
  ('ac38ac38-0000-0000-0000-00000000000a','ac38ac38-0000-0000-0000-000000000001','Main',true),
  ('ac38ac38-0000-0000-0000-00000000000b','ac38ac38-0000-0000-0000-000000000002','Main',true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('ac38ac38-0000-0000-0000-0000000ee0a1','ac38ac38-0000-0000-0000-000000000001','ac38ac38-0000-0000-0000-00000000000a','R',10),
  ('ac38ac38-0000-0000-0000-0000000ee0b1','ac38ac38-0000-0000-0000-000000000002','ac38ac38-0000-0000-0000-00000000000b','R',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('ac38ac38-0000-0000-0000-0000000cc0a1','ac38ac38-0000-0000-0000-000000000001','Reformer Flow',50,10),
  ('ac38ac38-0000-0000-0000-0000000cc0b1','ac38ac38-0000-0000-0000-000000000002','Reformer Flow',50,10);

insert into studio_staff (id, studio_id, user_id, email, role) values
  ('ac38ac38-0000-0000-0000-000000aa00a1','ac38ac38-0000-0000-0000-000000000001','ac38ac38-0000-0000-0000-0000000000a1','ac38-owner1@example.com','owner'),
  ('ac38ac38-0000-0000-0000-000000aa00d1','ac38ac38-0000-0000-0000-000000000001','ac38ac38-0000-0000-0000-000000000d11','ac38-d1@example.com','instructor'),
  ('ac38ac38-0000-0000-0000-000000aa00d2','ac38ac38-0000-0000-0000-000000000001','ac38ac38-0000-0000-0000-000000000d22','ac38-d2@example.com','instructor'),
  ('ac38ac38-0000-0000-0000-000000aa00b1','ac38ac38-0000-0000-0000-000000000002','ac38ac38-0000-0000-0000-0000000000b1','ac38-owner2@example.com','owner');
-- D1, D2: login instructors on S1. DN: no login (staff_id null). DA: no login,
-- for the amendment-(c) warning. DE: login instructor on S2 (the OFF studio).
insert into instructors (id, studio_id, display_name, staff_id) values
  ('ac38ac38-0000-0000-0000-0000000d00d1','ac38ac38-0000-0000-0000-000000000001','Rhon Vince','ac38ac38-0000-0000-0000-000000aa00d1'),
  ('ac38ac38-0000-0000-0000-0000000d00d2','ac38ac38-0000-0000-0000-000000000001','Bea Second','ac38ac38-0000-0000-0000-000000aa00d2'),
  ('ac38ac38-0000-0000-0000-0000000d00c0','ac38ac38-0000-0000-0000-000000000001','Cai NoLogin', null),
  ('ac38ac38-0000-0000-0000-0000000d00da','ac38ac38-0000-0000-0000-000000000001','Ada Availability', null),
  ('ac38ac38-0000-0000-0000-0000000d00de','ac38ac38-0000-0000-0000-000000000002','Ed Offstudio', null);
insert into instructor_class_types (studio_id, instructor_id, class_type_id) values
  ('ac38ac38-0000-0000-0000-000000000001','ac38ac38-0000-0000-0000-0000000d00d1','ac38ac38-0000-0000-0000-0000000cc0a1'),
  ('ac38ac38-0000-0000-0000-000000000001','ac38ac38-0000-0000-0000-0000000d00d2','ac38ac38-0000-0000-0000-0000000cc0a1');

-- A helper: how many future scheduled occurrences of a series.
create or replace function ac38_future(p_series uuid) returns bigint language sql stable as $$
  select count(*) from class_occurrences where series_id = p_series and status='scheduled' and starts_at > now();
$$;

-- =============================================================================
-- 1. ON + login instructor: a series assigned to D1 records a request on every
--    materialised occurrence, and queues exactly ONE coalesced email.
-- =============================================================================
insert into class_series (id, studio_id, location_id, class_type_id, name, room_id, instructor_id,
   capacity, duration_minutes, rrule, starts_on, time_of_day)
values ('ac38ac38-0000-0000-0000-00000000f001','ac38ac38-0000-0000-0000-000000000001',
        'ac38ac38-0000-0000-0000-00000000000a','ac38ac38-0000-0000-0000-0000000cc0a1','Reformer Flow',
        'ac38ac38-0000-0000-0000-0000000ee0a1','ac38ac38-0000-0000-0000-0000000d00d1',
        10,50,'FREQ=WEEKLY;BYDAY=MO,TH', current_date + 1, '07:00');

select expect_true('every materialised future occurrence is REQUESTED',
  (select count(*) = ac38_future('ac38ac38-0000-0000-0000-00000000f001')
     from class_occurrences where series_id='ac38ac38-0000-0000-0000-00000000f001'
       and status='scheduled' and starts_at > now() and assignment_requested_at is not null)
  and ac38_future('ac38ac38-0000-0000-0000-00000000f001') > 0);
select expect_true('...and none is confirmed yet',
  (select count(*) = 0 from class_occurrences
     where series_id='ac38ac38-0000-0000-0000-00000000f001' and assignment_confirmed_at is not null));
select expect_num('exactly ONE coalesced email is queued for D1',
  (select count(*) from notifications
     where template_key='assignment_confirmation_request'
       and user_id='ac38ac38-0000-0000-0000-000000000d11')::bigint, 1);
select expect_true('...the digest lists the series and a count',
  (select payload ->> 'class_list' like '%Reformer Flow%' and (payload ->> 'count')::int > 0
     from notifications where template_key='assignment_confirmation_request'
       and user_id='ac38ac38-0000-0000-0000-000000000d11' limit 1));

-- =============================================================================
-- 2. ON + instructor WITHOUT login: no request, no notification.
-- =============================================================================
insert into class_series (id, studio_id, location_id, class_type_id, name, room_id, instructor_id,
   capacity, duration_minutes, rrule, starts_on, time_of_day)
values ('ac38ac38-0000-0000-0000-00000000f00c','ac38ac38-0000-0000-0000-000000000001',
        'ac38ac38-0000-0000-0000-00000000000a','ac38ac38-0000-0000-0000-0000000cc0a1','No Login Class',
        'ac38ac38-0000-0000-0000-0000000ee0a1','ac38ac38-0000-0000-0000-0000000d00c0',
        10,50,'FREQ=WEEKLY;BYDAY=FR', current_date + 1, '09:00');
select expect_num('an instructor with no login is never asked',
  (select count(*) from class_occurrences
     where series_id='ac38ac38-0000-0000-0000-00000000f00c' and assignment_requested_at is not null)::bigint, 0);

-- =============================================================================
-- 3. The setting OFF (studio S2): no request, no notification.
-- =============================================================================
insert into instructor_class_types (studio_id, instructor_id, class_type_id) values
  ('ac38ac38-0000-0000-0000-000000000002','ac38ac38-0000-0000-0000-0000000d00de','ac38ac38-0000-0000-0000-0000000cc0b1');
insert into class_series (id, studio_id, location_id, class_type_id, name, room_id, instructor_id,
   capacity, duration_minutes, rrule, starts_on, time_of_day)
values ('ac38ac38-0000-0000-0000-00000000f0ff','ac38ac38-0000-0000-0000-000000000002',
        'ac38ac38-0000-0000-0000-00000000000b','ac38ac38-0000-0000-0000-0000000cc0b1','Off Class',
        'ac38ac38-0000-0000-0000-0000000ee0b1','ac38ac38-0000-0000-0000-0000000d00de',
        10,50,'FREQ=WEEKLY;BYDAY=TU', current_date + 1, '08:00');
select expect_num('the switch off records no request',
  (select count(*) from class_occurrences
     where series_id='ac38ac38-0000-0000-0000-00000000f0ff' and assignment_requested_at is not null)::bigint, 0);
select expect_num('the switch off queues no email',
  (select count(*) from notifications where studio_id = :S2
     and template_key='assignment_confirmation_request')::bigint, 0);

-- =============================================================================
-- 4. Confirm — the wrong instructor is refused; the right one sets it.
-- =============================================================================
select set_config('t.occ', (select id::text from class_occurrences
  where series_id='ac38ac38-0000-0000-0000-00000000f001' and status='scheduled' and starts_at > now()
  order by starts_at limit 1), false);

set role authenticated;
select set_config('request.jwt.claim.sub','ac38ac38-0000-0000-0000-000000000d22',false);   -- D2
select expect_raises('the WRONG instructor cannot confirm',
  'select confirm_assignment('''|| current_setting('t.occ') ||'''::uuid)', 'PT403');

select set_config('request.jwt.claim.sub','ac38ac38-0000-0000-0000-000000000d11',false);   -- D1
select expect_true('the assigned instructor confirms',
  (select (confirm_assignment(current_setting('t.occ')::uuid) ->> 'ok')::boolean));
reset role; select set_config('request.jwt.claim.sub', null, false);
select expect_true('...and the stamp is set',
  (select assignment_confirmed_at is not null from class_occurrences where id = current_setting('t.occ')::uuid));

-- The instructor's own reader lists the still-unconfirmed ones (not the confirmed).
set role authenticated; select set_config('request.jwt.claim.sub','ac38ac38-0000-0000-0000-000000000d11',false);
select expect_true('the confirmed class is gone from Needs-confirmation',
  not exists (select 1 from instructor_assignment_requests('ac38ac38-0000-0000-0000-0000000d00d1')
                where occurrence_id = current_setting('t.occ')::uuid));
select expect_true('...but the rest remain',
  (select count(*) > 0 from instructor_assignment_requests('ac38ac38-0000-0000-0000-0000000d00d1')));
reset role; select set_config('request.jwt.claim.sub', null, false);

-- =============================================================================
-- 5. Can't make it — Decision 18 UNCHANGED. withdraw_from_shift raises a cover
--    request; the class STAYS assigned to the instructor and the confirmation
--    state is untouched (requested-and-unconfirmed until covered or confirmed).
-- =============================================================================
select set_config('t.dec', (select id::text from class_occurrences
  where series_id='ac38ac38-0000-0000-0000-00000000f001' and status='scheduled' and starts_at > now()
    and assignment_confirmed_at is null order by starts_at limit 1), false);
set role authenticated; select set_config('request.jwt.claim.sub','ac38ac38-0000-0000-0000-000000000d11',false);
select expect_true('the assigned instructor "can''t make it" — a cover request is raised',
  (select (withdraw_from_shift(current_setting('t.dec')::uuid) ->> 'cover_requested')::boolean));
reset role; select set_config('request.jwt.claim.sub', null, false);
select expect_true('the class STAYS assigned to the same instructor, staffing unchanged',
  (select instructor_id = 'ac38ac38-0000-0000-0000-0000000d00d1' and staffing = 'assigned'
     from class_occurrences where id = current_setting('t.dec')::uuid));
select expect_true('...and its request/confirm stamps are UNTOUCHED (still requested, unconfirmed)',
  (select assignment_requested_at is not null and assignment_confirmed_at is null
     from class_occurrences where id = current_setting('t.dec')::uuid));
select expect_num('a cover request exists for it',
  (select count(*) from cover_requests where occurrence_id = current_setting('t.dec')::uuid)::bigint, 1);
select expect_true('the owner/managers get the existing cover notification',
  (select count(*) > 0 from notifications where studio_id = :S1
     and template_key in ('cover_requested','cover_urgent')));

-- =============================================================================
-- 6. Reassign clears and re-requests. Assign, confirm, reassign to D2.
-- =============================================================================
select set_config('t.re', (select id::text from class_occurrences
  where series_id='ac38ac38-0000-0000-0000-00000000f001' and status='scheduled' and starts_at > now()
    and instructor_id='ac38ac38-0000-0000-0000-0000000d00d1'
    and id <> current_setting('t.dec')::uuid order by starts_at limit 1), false);
set role authenticated; select set_config('request.jwt.claim.sub','ac38ac38-0000-0000-0000-000000000d11',false);
select confirm_assignment(current_setting('t.re')::uuid);   -- D1 confirms it
reset role; select set_config('request.jwt.claim.sub', null, false);
select expect_true('the class is confirmed for D1 before the reassign',
  (select assignment_confirmed_at is not null and instructor_id='ac38ac38-0000-0000-0000-0000000d00d1'
     from class_occurrences where id = current_setting('t.re')::uuid));

set role authenticated; select set_config('request.jwt.claim.sub','ac38ac38-0000-0000-0000-0000000000a1',false);  -- owner
select reassign_occurrence(current_setting('t.re')::uuid, 'ac38ac38-0000-0000-0000-0000000d00d2');
reset role; select set_config('request.jwt.claim.sub', null, false);
select expect_true('reassign moves the class to D2, clears the confirm, re-requests',
  (select instructor_id='ac38ac38-0000-0000-0000-0000000d00d2'
      and assignment_confirmed_at is null and assignment_requested_at is not null
     from class_occurrences where id = current_setting('t.re')::uuid));

-- =============================================================================
-- 7. Pre-existing assignments (before the setting turned on) are untouched, and
--    the series "Ask to confirm" requests exactly the future unconfirmed ones.
-- =============================================================================
-- Turn OFF, build a series assigned to D1 (so no request is stamped), turn ON.
update studio_settings set assignment_confirmations = false where studio_id = :S1;
insert into class_series (id, studio_id, location_id, class_type_id, name, room_id, instructor_id,
   capacity, duration_minutes, rrule, starts_on, time_of_day)
values ('ac38ac38-0000-0000-0000-00000000f0c1','ac38ac38-0000-0000-0000-000000000001',
        'ac38ac38-0000-0000-0000-00000000000a','ac38ac38-0000-0000-0000-0000000cc0a1','Pre-existing',
        'ac38ac38-0000-0000-0000-0000000ee0a1','ac38ac38-0000-0000-0000-0000000d00d1',
        10,50,'FREQ=WEEKLY;BYDAY=WE', current_date + 1, '18:00');
-- A PAST occurrence of the same series (assigned while off) — never to be asked.
insert into class_occurrences (id, studio_id, location_id, series_id, class_type_id, room_id, instructor_id,
   name, starts_at, ends_at, capacity, booked_count, status)
values ('ac38ac38-0000-0000-0000-00000000cc07','ac38ac38-0000-0000-0000-000000000001','ac38ac38-0000-0000-0000-00000000000a',
        'ac38ac38-0000-0000-0000-00000000f0c1','ac38ac38-0000-0000-0000-0000000cc0a1','ac38ac38-0000-0000-0000-0000000ee0a1',
        'ac38ac38-0000-0000-0000-0000000d00d1','Pre-existing',
        now() - interval '7 days', now() - interval '7 days' + interval '50 min', 10, 0, 'scheduled');
update studio_settings set assignment_confirmations = true where studio_id = :S1;

select expect_num('pre-existing assignments carry NO request when the switch flips on',
  (select count(*) from class_occurrences
     where series_id='ac38ac38-0000-0000-0000-00000000f0c1' and assignment_requested_at is not null)::bigint, 0);

set role authenticated; select set_config('request.jwt.claim.sub','ac38ac38-0000-0000-0000-0000000000a1',false);  -- owner
select set_config('t.ask', (select (request_series_confirmations('ac38ac38-0000-0000-0000-00000000f0c1') ->> 'requested')), false);
reset role; select set_config('request.jwt.claim.sub', null, false);
select expect_num('"Ask to confirm" requests exactly the FUTURE occurrences',
  current_setting('t.ask')::bigint, ac38_future('ac38ac38-0000-0000-0000-00000000f0c1'));
select expect_true('...and the past occurrence is never asked',
  (select assignment_requested_at is null from class_occurrences where id='ac38ac38-0000-0000-0000-00000000cc07'));
select expect_num('...and it queues one digest for D1',
  (select count(*) from notifications where user_id='ac38ac38-0000-0000-0000-000000000d11'
     and template_key='assignment_confirmation_request'
     and payload ->> 'class_list' like '%Pre-existing%')::bigint, 1);

-- The owner series summary reads "N of M confirmed".
select expect_true('the series summary counts confirmed of requested',
  (select (series_confirmation_summary('ac38ac38-0000-0000-0000-00000000f0c1') ->> 'total')::int
            = ac38_future('ac38ac38-0000-0000-0000-00000000f0c1')));

-- =============================================================================
-- 8. Decision 37 amendment (c): the availability warning.
-- =============================================================================
-- DA states availability bounded to THIS month only, then a series assigned to
-- DA materialises into NEXT month — every occurrence is outside her dates.
insert into instructor_availability (studio_id, instructor_id, day_of_week, starts_at_time, ends_at_time,
   effective_from, effective_to, is_available)
select 'ac38ac38-0000-0000-0000-000000000001','ac38ac38-0000-0000-0000-0000000d00da', d, '06:00','22:00',
       date_trunc('month', current_date)::date,
       (date_trunc('month', current_date) + interval '1 month' - interval '1 day')::date, true
  from generate_series(0,6) d;
insert into class_series (id, studio_id, location_id, class_type_id, name, room_id, instructor_id,
   capacity, duration_minutes, rrule, starts_on, time_of_day)
values ('ac38ac38-0000-0000-0000-00000000f0a5','ac38ac38-0000-0000-0000-000000000001',
        'ac38ac38-0000-0000-0000-00000000000a','ac38ac38-0000-0000-0000-0000000cc0a1','Next Month',
        'ac38ac38-0000-0000-0000-0000000ee0a1','ac38ac38-0000-0000-0000-0000000d00da',
        10,50,'FREQ=WEEKLY;BYDAY=MO,TH',
        (date_trunc('month', current_date) + interval '1 month')::date, '11:00');
select expect_true('a next-month series for an instructor bounded to this month warns',
  (select (series_availability_warning('ac38ac38-0000-0000-0000-00000000f0a5') ->> 'count')::int
            = ac38_future('ac38ac38-0000-0000-0000-00000000f0a5'))
  and ac38_future('ac38ac38-0000-0000-0000-00000000f0a5') > 0);
select expect_text('...and names the instructor',
  (series_availability_warning('ac38ac38-0000-0000-0000-00000000f0a5') ->> 'instructor_name'), 'Ada Availability');
-- D1 has NO availability rows, so valid_on is true everywhere -> no warning.
select expect_true('an instructor with no stated dates warns not at all',
  series_availability_warning('ac38ac38-0000-0000-0000-00000000f001') is null);

-- =============================================================================
-- 9. The "already confirmed" bypass (Decision 38 amendment). A dedicated login
--    instructor D3, so "no request notification queued" is a clean 0.
-- =============================================================================
insert into auth.users (id) values ('ac38ac38-0000-0000-0000-000000000d33');
insert into profiles (id, email) values ('ac38ac38-0000-0000-0000-000000000d33','ac38-d3@example.com');
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('ac38ac38-0000-0000-0000-000000aa00d3','ac38ac38-0000-0000-0000-000000000001','ac38ac38-0000-0000-0000-000000000d33','ac38-d3@example.com','instructor');
insert into instructors (id, studio_id, display_name, staff_id) values
  ('ac38ac38-0000-0000-0000-0000000d00d3','ac38ac38-0000-0000-0000-000000000001','Cam Third','ac38ac38-0000-0000-0000-000000aa00d3');
-- A dedicated room for the bypass fixtures, so the one-offs (06:00) and the
-- "Mark All" series (12:00) never collide with each other or with S1's series.
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('ac38ac38-0000-0000-0000-0000000ee0a2','ac38ac38-0000-0000-0000-000000000001','ac38ac38-0000-0000-0000-00000000000a','R2',10);

-- TICKED: a lone one-off is requested + queued on insert; the bypass then stamps
-- confirmed + confirmed_by (by the studio) and the now-empty digest is cancelled.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id,
   name, starts_at, ends_at, capacity, booked_count, status)
values ('ac38ac38-0000-0000-0000-00000000c701','ac38ac38-0000-0000-0000-000000000001','ac38ac38-0000-0000-0000-00000000000a',
        'ac38ac38-0000-0000-0000-0000000cc0a1','ac38ac38-0000-0000-0000-0000000ee0a2','ac38ac38-0000-0000-0000-0000000d00d3',
        'Bypass One-off', (current_date + 3 + time '06:00') at time zone 'Europe/Prague',
        (current_date + 3 + time '06:50') at time zone 'Europe/Prague', 10, 0, 'scheduled');
select expect_true('a login-instructor one-off is REQUESTED on insert',
  (select assignment_requested_at is not null and assignment_confirmed_at is null
     from class_occurrences where id='ac38ac38-0000-0000-0000-00000000c701'));
select expect_num('...and a digest is queued for D3',
  (select count(*) from notifications where user_id='ac38ac38-0000-0000-0000-000000000d33'
     and template_key='assignment_confirmation_request' and status='scheduled')::bigint, 1);

set role authenticated; select set_config('request.jwt.claim.sub','ac38ac38-0000-0000-0000-0000000000a1',false);  -- owner
select expect_true('the bypass marks the class confirmed',
  (select (mark_assignment_confirmed('ac38ac38-0000-0000-0000-00000000c701') ->> 'ok')::boolean));
reset role; select set_config('request.jwt.claim.sub', null, false);
select expect_true('...confirmed_at set AND confirmed_by = the staff user (confirmed by the studio)',
  (select assignment_confirmed_at is not null
      and assignment_confirmed_by = 'ac38ac38-0000-0000-0000-0000000000a1'
     from class_occurrences where id='ac38ac38-0000-0000-0000-00000000c701'));
select expect_num('...and the now-empty digest for D3 is cancelled (no request queued)',
  (select count(*) from notifications where user_id='ac38ac38-0000-0000-0000-000000000d33'
     and template_key='assignment_confirmation_request' and status='scheduled')::bigint, 0);

-- =============================================================================
-- 10. UNTICKED: the plain create path leaves the request + digest in place.
-- =============================================================================
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id,
   name, starts_at, ends_at, capacity, booked_count, status)
values ('ac38ac38-0000-0000-0000-00000000c702','ac38ac38-0000-0000-0000-000000000001','ac38ac38-0000-0000-0000-00000000000a',
        'ac38ac38-0000-0000-0000-0000000cc0a1','ac38ac38-0000-0000-0000-0000000ee0a2','ac38ac38-0000-0000-0000-0000000d00d3',
        'Unticked One-off', (current_date + 4 + time '06:00') at time zone 'Europe/Prague',
        (current_date + 4 + time '06:50') at time zone 'Europe/Prague', 10, 0, 'scheduled');
select expect_true('an unticked one-off stays REQUESTED and unconfirmed',
  (select assignment_requested_at is not null and assignment_confirmed_at is null
     from class_occurrences where id='ac38ac38-0000-0000-0000-00000000c702'));
select expect_num('...and a request digest IS queued for D3',
  (select count(*) from notifications where user_id='ac38ac38-0000-0000-0000-000000000d33'
     and template_key='assignment_confirmation_request' and status='scheduled')::bigint, 1);

-- =============================================================================
-- 11. Setting OFF: the bypass writer stamps nothing and reports 'off'; and with
--     the switch off the insert itself records no request. (The UI also hides the
--     tick when the setting is off — the SQL guarantee is the two below.)
-- =============================================================================
update studio_settings set assignment_confirmations = false where studio_id = :S1;
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id,
   name, starts_at, ends_at, capacity, booked_count, status)
values ('ac38ac38-0000-0000-0000-00000000c703','ac38ac38-0000-0000-0000-000000000001','ac38ac38-0000-0000-0000-00000000000a',
        'ac38ac38-0000-0000-0000-0000000cc0a1','ac38ac38-0000-0000-0000-0000000ee0a2','ac38ac38-0000-0000-0000-0000000d00d3',
        'Off One-off', (current_date + 5 + time '06:00') at time zone 'Europe/Prague',
        (current_date + 5 + time '06:50') at time zone 'Europe/Prague', 10, 0, 'scheduled');
select expect_true('the switch off records no request on insert',
  (select assignment_requested_at is null from class_occurrences where id='ac38ac38-0000-0000-0000-00000000c703'));
set role authenticated; select set_config('request.jwt.claim.sub','ac38ac38-0000-0000-0000-0000000000a1',false);  -- owner
select expect_text('the bypass reports off when the setting is off',
  (mark_assignment_confirmed('ac38ac38-0000-0000-0000-00000000c703') ->> 'reason'), 'off');
reset role; select set_config('request.jwt.claim.sub', null, false);
select expect_true('...and stamps nothing',
  (select assignment_confirmed_at is null and assignment_confirmed_by is null
     from class_occurrences where id='ac38ac38-0000-0000-0000-00000000c703'));
update studio_settings set assignment_confirmations = true where studio_id = :S1;

-- =============================================================================
-- 12. "Mark all confirmed" stamps only the FUTURE UNCONFIRMED occurrences of the
--     series, and the summary splits studio- vs instructor-confirmed.
-- =============================================================================
insert into class_series (id, studio_id, location_id, class_type_id, name, room_id, instructor_id,
   capacity, duration_minutes, rrule, starts_on, time_of_day)
values ('ac38ac38-0000-0000-0000-00000000f0a9','ac38ac38-0000-0000-0000-000000000001',
        'ac38ac38-0000-0000-0000-00000000000a','ac38ac38-0000-0000-0000-0000000cc0a1','Mark All',
        'ac38ac38-0000-0000-0000-0000000ee0a2','ac38ac38-0000-0000-0000-0000000d00d3',
        10,50,'FREQ=WEEKLY;BYDAY=MO,TH', current_date + 1, '12:00');
-- A PAST occurrence of the same series: it is requested (the trigger is
-- time-agnostic) but "Mark all confirmed" must never touch it.
insert into class_occurrences (id, studio_id, location_id, series_id, class_type_id, room_id, instructor_id,
   name, starts_at, ends_at, capacity, booked_count, status)
values ('ac38ac38-0000-0000-0000-00000000cc09','ac38ac38-0000-0000-0000-000000000001','ac38ac38-0000-0000-0000-00000000000a',
        'ac38ac38-0000-0000-0000-00000000f0a9','ac38ac38-0000-0000-0000-0000000cc0a1','ac38ac38-0000-0000-0000-0000000ee0a2',
        'ac38ac38-0000-0000-0000-0000000d00d3','Mark All',
        now() - interval '7 days', now() - interval '7 days' + interval '50 min', 10, 0, 'scheduled');

-- The instructor confirms ONE future occurrence themselves (confirmed_by stays null).
select set_config('t.one', (select id::text from class_occurrences
  where series_id='ac38ac38-0000-0000-0000-00000000f0a9' and status='scheduled' and starts_at > now()
  order by starts_at limit 1), false);
set role authenticated; select set_config('request.jwt.claim.sub','ac38ac38-0000-0000-0000-000000000d33',false);  -- D3
select confirm_assignment(current_setting('t.one')::uuid);
reset role; select set_config('request.jwt.claim.sub', null, false);

set role authenticated; select set_config('request.jwt.claim.sub','ac38ac38-0000-0000-0000-0000000000a1',false);  -- owner
select set_config('t.markn', (select (mark_series_confirmed('ac38ac38-0000-0000-0000-00000000f0a9') ->> 'confirmed')), false);
reset role; select set_config('request.jwt.claim.sub', null, false);
select expect_num('Mark all confirmed stamps only the FUTURE UNCONFIRMED occurrences',
  current_setting('t.markn')::bigint, ac38_future('ac38ac38-0000-0000-0000-00000000f0a9') - 1);
select expect_true('every FUTURE occurrence is now confirmed',
  (select count(*) = ac38_future('ac38ac38-0000-0000-0000-00000000f0a9') from class_occurrences
     where series_id='ac38ac38-0000-0000-0000-00000000f0a9' and status='scheduled' and starts_at > now()
       and assignment_confirmed_at is not null));
select expect_true('...and the PAST occurrence is left unconfirmed',
  (select assignment_confirmed_at is null from class_occurrences where id='ac38ac38-0000-0000-0000-00000000cc09'));
select expect_num('summary total = the future requested count',
  (series_confirmation_summary('ac38ac38-0000-0000-0000-00000000f0a9') ->> 'total')::int::bigint,
  ac38_future('ac38ac38-0000-0000-0000-00000000f0a9'));
select expect_num('summary by_instructor = 1 (the instructor-confirmed one)',
  (series_confirmation_summary('ac38ac38-0000-0000-0000-00000000f0a9') ->> 'by_instructor')::int::bigint, 1);
select expect_num('summary by_studio = the rest (marked by the studio)',
  (series_confirmation_summary('ac38ac38-0000-0000-0000-00000000f0a9') ->> 'by_studio')::int::bigint,
  ac38_future('ac38ac38-0000-0000-0000-00000000f0a9') - 1);

-- =============================================================================
-- 13. Teeth on the bypass guards: a non-manager is refused, and removing the
--     is_manager_up guard lets a non-manager stamp.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','ac38ac38-0000-0000-0000-000000000d22',false);  -- D2 instructor
select expect_raises('a non-manager cannot Mark all confirmed',
  'select mark_series_confirmed(''ac38ac38-0000-0000-0000-00000000f0a9''::uuid)', 'PT403');
select expect_raises('a non-manager cannot bypass a single class',
  'select mark_assignment_confirmed(''ac38ac38-0000-0000-0000-00000000c702''::uuid)', 'PT403');
reset role; select set_config('request.jwt.claim.sub', null, false);

create or replace function mark_assignment_confirmed(p_occurrence_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o class_occurrences%rowtype; v_on boolean;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  -- TEETH: manager guard removed.
  select assignment_confirmations into v_on from studio_settings where studio_id = o.studio_id;
  if not coalesce(v_on, false) then return jsonb_build_object('ok', false, 'reason', 'off'); end if;
  update class_occurrences
     set assignment_requested_at = coalesce(assignment_requested_at, now()),
         assignment_confirmed_at = now(), assignment_confirmed_by = auth.uid()
   where id = p_occurrence_id and assignment_confirmed_at is null;
  return jsonb_build_object('ok', true, 'confirmed', 1);
end $$;
set role authenticated; select set_config('request.jwt.claim.sub','ac38ac38-0000-0000-0000-000000000d22',false);  -- D2 (not a manager)
select expect_true('TEETH: with the manager guard gone, a non-manager CAN bypass',
  (select (mark_assignment_confirmed('ac38ac38-0000-0000-0000-00000000c702') ->> 'ok')::boolean));
reset role; select set_config('request.jwt.claim.sub', null, false);

-- =============================================================================
-- 14. Teeth on the confirm guard.
-- =============================================================================
create or replace function confirm_assignment(p_occurrence_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o class_occurrences%rowtype;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  -- TEETH: guard removed.
  update class_occurrences set assignment_confirmed_at = now()
   where id = p_occurrence_id
     and assignment_requested_at is not null and assignment_confirmed_at is null;
  return jsonb_build_object('ok', true, 'occurrence_id', p_occurrence_id);
end $$;
select set_config('t.teeth', (select id::text from class_occurrences
  where series_id='ac38ac38-0000-0000-0000-00000000f001' and status='scheduled' and starts_at > now()
    and assignment_confirmed_at is null and instructor_id='ac38ac38-0000-0000-0000-0000000d00d1'
  order by starts_at limit 1), false);
set role authenticated; select set_config('request.jwt.claim.sub','ac38ac38-0000-0000-0000-000000000d22',false);  -- D2 (wrong)
select expect_true('TEETH: with the guard gone, the wrong instructor CAN confirm',
  (select (confirm_assignment(current_setting('t.teeth')::uuid) ->> 'ok')::boolean));
reset role; select set_config('request.jwt.claim.sub', null, false);

select 'assignment_confirm suite finished' as done;
