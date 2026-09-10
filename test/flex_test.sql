-- NOTE (Decision 22, migration 081): sweep_flex_decisions() became
-- sweep_commitments() and flex_confirmed_at became committed_at. This suite
-- asserts Decision 21's behaviour and every assertion below is UNCHANGED —
-- flex still evaluates at its own wall-clock cutoff, still confirms silently,
-- and still cancels through §3.2. Only the names moved.
-- =============================================================================
-- Decision 21 — flex classes
-- Migration 075. UUID space f1e0, checked free.
-- =============================================================================
-- TWO STUDIOS ON DIFFERENT DEADLINES, in one run. Studio A decides at a fixed
-- local time the night before (Reform Collective's shape). Studio B decides a
-- fixed number of hours ahead. A fixture where both used one mode would leave
-- the other reachable only by reading the code.
--
-- And a THIRD studio with flex switched off, which is the assertion that says
-- this feature is invisible to everybody who has not asked for it.
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
create or replace function expect_raises(label text, stmt text, want_sqlstate text)
returns void language plpgsql as $$
begin
  execute stmt;
  raise exception 'FAIL  %  expected % but nothing was raised', label, want_sqlstate;
exception when others then
  if sqlstate = want_sqlstate then raise notice 'PASS  %  (got %)', label, sqlstate;
  elsif sqlstate = 'P0001' and sqlerrm like 'FAIL%' then raise;
  else raise exception 'FAIL  %  expected %, got % (%)', label, want_sqlstate, sqlstate, sqlerrm;
  end if;
end $$;

-- --- Fixtures: three studios ------------------------------------------------
insert into auth.users (id) values
  ('f1e0f1e0-0000-0000-0000-0000000000a1'),
  ('f1e0f1e0-0000-0000-0000-0000000000a2'),
  ('f1e0f1e0-0000-0000-0000-0000000000a3'),
  -- Coach A has a LOGIN; Coach B deliberately does not. An instructor with no
  -- account has no address anywhere in the schema, which is the ordinary case,
  -- and the sweep has to report that rather than imply an email it never sent.
  ('f1e0f1e0-0000-0000-0000-0000000000a4');
insert into profiles (id, email, full_name) values
  ('f1e0f1e0-0000-0000-0000-0000000000a1','flex-a@example.com','Ola A'),
  ('f1e0f1e0-0000-0000-0000-0000000000a2','flex-b@example.com','Ola B'),
  ('f1e0f1e0-0000-0000-0000-0000000000a3','flex-c@example.com','Ola C'),
  ('f1e0f1e0-0000-0000-0000-0000000000a4','flex-coach@example.com','Coach A');
insert into studios (id, name, slug, timezone, currency, status) values
  ('f1e0f1e0-0000-0000-0000-000000000001','Flex Night Before','flex-a','Europe/Prague','CZK','active'),
  ('f1e0f1e0-0000-0000-0000-000000000002','Flex Hours Before','flex-b','Asia/Manila','PHP','active'),
  ('f1e0f1e0-0000-0000-0000-000000000003','No Flex Here','flex-c','Europe/Prague','CZK','active');

-- A decides at 20:00 the night before; B twelve hours ahead; C has flex OFF.
insert into studio_settings (studio_id, flex_enabled, flex_deadline_mode, flex_deadline_time, flex_deadline_hours) values
  ('f1e0f1e0-0000-0000-0000-000000000001', true,  'previous_day_at', '20:00', 12),
  ('f1e0f1e0-0000-0000-0000-000000000002', true,  'hours_before',    '20:00', 12);
insert into studio_settings (studio_id) values ('f1e0f1e0-0000-0000-0000-000000000003');

insert into locations (id, studio_id, name, is_primary) values
  ('f1e0f1e0-0000-0000-0000-00000000000a','f1e0f1e0-0000-0000-0000-000000000001','Main',true),
  ('f1e0f1e0-0000-0000-0000-00000000000b','f1e0f1e0-0000-0000-0000-000000000002','Main',true),
  ('f1e0f1e0-0000-0000-0000-00000000000c','f1e0f1e0-0000-0000-0000-000000000003','Main',true);
insert into studio_staff (studio_id, user_id, email, role) values
  ('f1e0f1e0-0000-0000-0000-000000000001','f1e0f1e0-0000-0000-0000-0000000000a1','flex-a@example.com','owner'),
  ('f1e0f1e0-0000-0000-0000-000000000002','f1e0f1e0-0000-0000-0000-0000000000a2','flex-b@example.com','owner'),
  ('f1e0f1e0-0000-0000-0000-000000000003','f1e0f1e0-0000-0000-0000-0000000000a3','flex-c@example.com','owner');
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('f1e0f1e0-0000-0000-0000-00000000aa04','f1e0f1e0-0000-0000-0000-000000000001',
   'f1e0f1e0-0000-0000-0000-0000000000a4','flex-coach@example.com','instructor');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('f1e0f1e0-0000-0000-0000-0000000000e1','f1e0f1e0-0000-0000-0000-000000000001','f1e0f1e0-0000-0000-0000-00000000000a','Room A',12),
  ('f1e0f1e0-0000-0000-0000-0000000000e2','f1e0f1e0-0000-0000-0000-000000000002','f1e0f1e0-0000-0000-0000-00000000000b','Room B',12),
  ('f1e0f1e0-0000-0000-0000-0000000000e3','f1e0f1e0-0000-0000-0000-000000000003','f1e0f1e0-0000-0000-0000-00000000000c','Room C',12);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('f1e0f1e0-0000-0000-0000-0000000000c1','f1e0f1e0-0000-0000-0000-000000000001','SCULPT',50,12),
  ('f1e0f1e0-0000-0000-0000-0000000000c2','f1e0f1e0-0000-0000-0000-000000000002','SCULPT',50,12),
  ('f1e0f1e0-0000-0000-0000-0000000000c3','f1e0f1e0-0000-0000-0000-000000000003','SCULPT',50,12);
insert into instructors (id, studio_id, staff_id, display_name) values
  ('f1e0f1e0-0000-0000-0000-0000000000d1','f1e0f1e0-0000-0000-0000-000000000001',
   'f1e0f1e0-0000-0000-0000-00000000aa04','Coach A');
insert into instructors (id, studio_id, display_name) values
  ('f1e0f1e0-0000-0000-0000-0000000000d2','f1e0f1e0-0000-0000-0000-000000000002','Coach B'),
  ('f1e0f1e0-0000-0000-0000-0000000000d3','f1e0f1e0-0000-0000-0000-000000000003','Coach C');
insert into members (id, studio_id, first_name, last_name, email, status) values
  ('f1e0f1e0-0000-0000-0000-0000000000b1','f1e0f1e0-0000-0000-0000-000000000001','Mara','One','flex-m1@example.com','active'),
  ('f1e0f1e0-0000-0000-0000-0000000000b2','f1e0f1e0-0000-0000-0000-000000000001','Mira','Two','flex-m2@example.com','active'),
  ('f1e0f1e0-0000-0000-0000-0000000000b3','f1e0f1e0-0000-0000-0000-000000000002','Bea','Three','flex-m3@example.com','active');

-- =============================================================================
-- 1. THE STUDIO THAT NEVER TURNED IT ON SEES NO CHANGE
-- =============================================================================
select expect_true('flex is off by default',
  not (select flex_enabled from studio_settings
        where studio_id = 'f1e0f1e0-0000-0000-0000-000000000003'));
select expect_true('a series is guaranteed by default',
  not (select coalesce(bool_or(flex), false) from class_series));

-- Studio C is given a series that IS marked flex at the row level. Its studio
-- switch is off, and that switch is the only thing standing between it and the
-- sweep — without this the assertion passed because C simply had no flex rows,
-- which proved nothing about the switch.
insert into class_series
  (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity,
   duration_minutes, rrule, starts_on, time_of_day, flex, minimum_bookings)
values ('f1e0f1e0-0000-0000-0000-00000000f003','f1e0f1e0-0000-0000-0000-000000000003',
        'f1e0f1e0-0000-0000-0000-00000000000c','f1e0f1e0-0000-0000-0000-0000000000c3',
        'f1e0f1e0-0000-0000-0000-0000000000e3','f1e0f1e0-0000-0000-0000-0000000000d3',
        'C SCULPT', 12, 50, 'FREQ=WEEKLY;BYDAY=SU,MO,TU,WE,TH,FR,SA',
        current_date, '07:00', true, 5);

set role authenticated;
select set_config('request.jwt.claim.sub','f1e0f1e0-0000-0000-0000-0000000000a3',false);
select expect_true('...even though its classes carry the flag',
  (select count(*) from class_occurrences
    where series_id = 'f1e0f1e0-0000-0000-0000-00000000f003' and flex) > 0);
select expect_num('a studio with flex off has nothing pending, ever',
  (select count(*) from flex_pending('f1e0f1e0-0000-0000-0000-000000000003'))::bigint, 0);

-- =============================================================================
-- 2. Flex is inherited from the series, and reaches classes already made
-- =============================================================================
reset role;
select set_config('request.jwt.claim.sub', null, false);
insert into class_series
  (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity,
   duration_minutes, rrule, starts_on, time_of_day)
values ('f1e0f1e0-0000-0000-0000-00000000f001','f1e0f1e0-0000-0000-0000-000000000001',
        'f1e0f1e0-0000-0000-0000-00000000000a','f1e0f1e0-0000-0000-0000-0000000000c1',
        'f1e0f1e0-0000-0000-0000-0000000000e1','f1e0f1e0-0000-0000-0000-0000000000d1',
        'SCULPT 07:00', 12, 50, 'FREQ=WEEKLY;BYDAY=SU,MO,TU,WE,TH,FR,SA', current_date, '07:00');

set role authenticated;
select set_config('request.jwt.claim.sub','f1e0f1e0-0000-0000-0000-0000000000a1',false);
select expect_num('the series generated guaranteed classes',
  (select count(*) from class_occurrences
    where series_id = 'f1e0f1e0-0000-0000-0000-00000000f001' and flex)::bigint, 0);

select set_config('t.sf', (select set_series_flex('f1e0f1e0-0000-0000-0000-00000000f001', true, 2)::text), false);
select expect_true('turning a series flex reaches the classes it has already made',
  (current_setting('t.sf')::jsonb ->> 'occurrences_updated')::int > 0);
select expect_num('...and the minimum comes with it',
  (select count(*) from class_occurrences
    where series_id = 'f1e0f1e0-0000-0000-0000-00000000f001'
      and flex and minimum_bookings = 2 and starts_at > now())::bigint,
  (current_setting('t.sf')::jsonb ->> 'occurrences_updated')::bigint);
select expect_raises('a flex series cannot have a minimum of nothing',
  $$select set_series_flex('f1e0f1e0-0000-0000-0000-00000000f001', true, 0)$$, 'PT422');

-- =============================================================================
-- 3. AT THRESHOLD IT CONFIRMS. BELOW IT, IT CANCELS THROUGH §3.2
-- =============================================================================
-- Tomorrow's class, which studio A decides at 20:00 tonight. The deadline is
-- forced past by moving the setting rather than the clock.
select set_config('t.tom', (select id::text from class_occurrences
  where series_id = 'f1e0f1e0-0000-0000-0000-00000000f001'
    and (starts_at at time zone 'Europe/Prague')::date
        = (now() at time zone 'Europe/Prague')::date + 1), false);
select set_config('t.day2', (select id::text from class_occurrences
  where series_id = 'f1e0f1e0-0000-0000-0000-00000000f001'
    and (starts_at at time zone 'Europe/Prague')::date
        = (now() at time zone 'Europe/Prague')::date + 2), false);
select set_config('t.day3', (select id::text from class_occurrences
  where series_id = 'f1e0f1e0-0000-0000-0000-00000000f001'
    and (starts_at at time zone 'Europe/Prague')::date
        = (now() at time zone 'Europe/Prague')::date + 3), false);

-- Two bookings on tomorrow's: it meets the minimum of 2.
reset role;
select set_config('request.jwt.claim.sub', null, false);
insert into bookings (studio_id, occurrence_id, member_id, status) values
  ('f1e0f1e0-0000-0000-0000-000000000001', current_setting('t.tom')::uuid,
   'f1e0f1e0-0000-0000-0000-0000000000b1','booked'),
  ('f1e0f1e0-0000-0000-0000-000000000001', current_setting('t.tom')::uuid,
   'f1e0f1e0-0000-0000-0000-0000000000b2','booked');
-- One booking on the day after: one short.
insert into bookings (studio_id, occurrence_id, member_id, status) values
  ('f1e0f1e0-0000-0000-0000-000000000001', current_setting('t.day2')::uuid,
   'f1e0f1e0-0000-0000-0000-0000000000b1','booked');
update class_occurrences set booked_count = 2 where id = current_setting('t.tom')::uuid;
update class_occurrences set booked_count = 1 where id = current_setting('t.day2')::uuid;

set role authenticated;
select set_config('request.jwt.claim.sub','f1e0f1e0-0000-0000-0000-0000000000a1',false);
select expect_num('the short class is reported short, by how many',
  (select short_by from flex_pending('f1e0f1e0-0000-0000-0000-000000000001')
    where occ_id = current_setting('t.day2')::uuid)::bigint, 1);
select expect_num('...and the one at threshold is not short at all',
  (select short_by from flex_pending('f1e0f1e0-0000-0000-0000-000000000001')
    where occ_id = current_setting('t.tom')::uuid)::bigint, 0);

-- Push every deadline into the past by making it "hours before" with a huge
-- window, which is the same question asked earlier rather than a different one.
reset role;
select set_config('request.jwt.claim.sub', null, false);
update studio_settings set flex_deadline_mode = 'hours_before', flex_deadline_hours = 168
 where studio_id = 'f1e0f1e0-0000-0000-0000-000000000001';

select set_config('t.credits_before', (select count(*)::text from credit_ledger
  where studio_id = 'f1e0f1e0-0000-0000-0000-000000000001' and reason = 'cancellation_refund'), false);
select set_config('t.sweep', (select sweep_commitments()::text), false);

select expect_true('the sweep sees both flex studios and not the third',
  (current_setting('t.sweep')::jsonb ->> 'studios')::int = 2);
select expect_text('a class at its threshold is CONFIRMED',
  (select case when committed_at is not null then 'confirmed' else 'pending' end
     from class_occurrences where id = current_setting('t.tom')::uuid), 'confirmed');
select expect_text('...and nothing about it changed for a member',
  (select status::text from class_occurrences where id = current_setting('t.tom')::uuid), 'scheduled');
select expect_text('a class below its threshold is CANCELLED',
  (select status::text from class_occurrences where id = current_setting('t.day2')::uuid), 'cancelled');
select expect_num('...through the studio path, so the credit went back',
  (select count(*) from credit_ledger
    where studio_id = 'f1e0f1e0-0000-0000-0000-000000000001'
      and reason = 'cancellation_refund')::bigint,
  current_setting('t.credits_before')::bigint + 0);
select expect_num('...and the member booked on it was told',
  (select count(*) from notifications
    where template_key = 'class_cancelled'
      and payload ->> 'class_name' = 'SCULPT 07:00')::bigint, 1);
select expect_num('...and nobody was marked a late cancellation for the studio''s decision',
  (select count(*) from bookings
    where occurrence_id = current_setting('t.day2')::uuid and is_late_cancel)::bigint, 0);

-- ZERO BOOKINGS: cancels, and the only person told is the coach.
select expect_text('a class with nobody booked cancels too',
  (select status::text from class_occurrences where id = current_setting('t.day3')::uuid), 'cancelled');
select expect_num('...telling no members, because there are none',
  (select count(*) from notifications n
    where n.template_key = 'class_cancelled'
      and n.member_id is not null
      and n.dedupe_key like '%' || current_setting('t.day3') || '%')::bigint, 0);
-- CHANGED BY DECISION 22, deliberately, and this assertion now asserts the
-- inverse of what it used to. Decision 21 sent one message per class, so this
-- counted seven. Decision 22 batches per evaluation run: ONE digest per
-- instructor listing everything that was decided, because five pings about five
-- classes is how a studio teaches its instructors to stop reading them.
select expect_num('the coach is told once, not once per class',
  (select count(*) from notifications
    where template_key = 'commitment_digest'
      and studio_id = 'f1e0f1e0-0000-0000-0000-000000000001')::bigint, 1);
select expect_num('...and no per-class ping is sent any more',
  (select count(*) from notifications
    where template_key in ('flex_confirmed','flex_cancelled')
      and studio_id = 'f1e0f1e0-0000-0000-0000-000000000001')::bigint, 0);
select expect_true('...and the one digest names every class it decided',
  (select (payload ->> 'lines') like '%RUNNING%'
      and (payload ->> 'lines') like '%NOT ON%'
     from notifications
    where template_key = 'commitment_digest'
      and studio_id = 'f1e0f1e0-0000-0000-0000-000000000001' limit 1));

-- =============================================================================
-- 4. A SINGLE OCCURRENCE FLIPPED TO GUARANTEED SURVIVES THE SWEEP
-- =============================================================================
-- "This one runs whatever happens" is a real decision on a quiet week.
reset role;
select set_config('request.jwt.claim.sub', null, false);
-- Ten days out, which the 168-hour deadline used above did not reach — so this
-- one is genuinely still pending when it is flipped.
select set_config('t.day5', (select id::text from class_occurrences
  where series_id = 'f1e0f1e0-0000-0000-0000-00000000f001'
    and (starts_at at time zone 'Europe/Prague')::date
        = (now() at time zone 'Europe/Prague')::date + 10), false);
set role authenticated;
select set_config('request.jwt.claim.sub','f1e0f1e0-0000-0000-0000-0000000000a1',false);
select set_occurrence_guaranteed(current_setting('t.day5')::uuid);
select expect_num('a guaranteed occurrence is not pending a decision',
  (select count(*) from flex_pending('f1e0f1e0-0000-0000-0000-000000000001')
    where occ_id = current_setting('t.day5')::uuid)::bigint, 0);

reset role;
select set_config('request.jwt.claim.sub', null, false);
select sweep_commitments();
select expect_text('...and the sweep leaves it alone, with nobody booked on it',
  (select status::text from class_occurrences where id = current_setting('t.day5')::uuid), 'scheduled');
select expect_true('...and it was never confirmed, because it never had to be',
  (select committed_at is null from class_occurrences
    where id = current_setting('t.day5')::uuid));

-- =============================================================================
-- 5. ONCE CONFIRMED IT RUNS — a later cancellation does not un-confirm it
-- =============================================================================
-- The coach has been told to come in. Dropping below the minimum afterwards
-- changes nothing, or the deadline would mean nothing.
select expect_text('tomorrow''s class is confirmed',
  (select case when committed_at is not null then 'yes' else 'no' end
     from class_occurrences where id = current_setting('t.tom')::uuid), 'yes');
select set_config('t.b1', (select id::text from bookings
  where occurrence_id = current_setting('t.tom')::uuid limit 1), false);
select cancel_booking(current_setting('t.b1')::uuid);
select expect_num('a member drops out, putting it below its minimum',
  (select count(*) from bookings
    where occurrence_id = current_setting('t.tom')::uuid
      and status in ('booked','attended','no_show','pending_payment'))::bigint, 1);
select sweep_commitments();
select expect_text('...and the class still runs',
  (select status::text from class_occurrences where id = current_setting('t.tom')::uuid), 'scheduled');
select expect_true('...still confirmed',
  (select committed_at is not null from class_occurrences
    where id = current_setting('t.tom')::uuid));

-- =============================================================================
-- 6. TWO STUDIOS, TWO DEADLINE MODES, ONE RUN
-- =============================================================================
insert into class_series
  (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity,
   duration_minutes, rrule, starts_on, time_of_day, flex, minimum_bookings)
values ('f1e0f1e0-0000-0000-0000-00000000f002','f1e0f1e0-0000-0000-0000-000000000002',
        'f1e0f1e0-0000-0000-0000-00000000000b','f1e0f1e0-0000-0000-0000-0000000000c2',
        'f1e0f1e0-0000-0000-0000-0000000000e2','f1e0f1e0-0000-0000-0000-0000000000d2',
        'MNL SCULPT', 12, 50, 'FREQ=WEEKLY;BYDAY=SU,MO,TU,WE,TH,FR,SA',
        current_date, '07:00', true, 1);

-- B decides twelve hours ahead, so only classes inside that window are due.
set role authenticated;
select set_config('request.jwt.claim.sub','f1e0f1e0-0000-0000-0000-0000000000a2',false);
select expect_num('B has exactly one class past its twelve-hour deadline',
  (select count(*) from flex_pending('f1e0f1e0-0000-0000-0000-000000000002') where past_due)::bigint,
  (select count(*) from class_occurrences o
    where o.series_id = 'f1e0f1e0-0000-0000-0000-00000000f002'
      and o.status = 'scheduled' and o.starts_at > now()
      and o.starts_at <= now() + interval '12 hours')::bigint);
select expect_true('...while classes further out are not yet due',
  (select count(*) from flex_pending('f1e0f1e0-0000-0000-0000-000000000002') where not past_due) > 0);

reset role;
select set_config('request.jwt.claim.sub', null, false);
select set_config('t.sw2', (select sweep_commitments()::text), false);
select expect_num('the sweep decides B''s due class and leaves the rest',
  (select count(*) from class_occurrences
    where series_id = 'f1e0f1e0-0000-0000-0000-00000000f002'
      and status = 'scheduled' and committed_at is null and starts_at > now()
      and starts_at <= now() + interval '12 hours')::bigint, 0);
select expect_true('...and B''s later classes are still pending',
  (select count(*) from class_occurrences
    where series_id = 'f1e0f1e0-0000-0000-0000-00000000f002'
      and status = 'scheduled' and committed_at is null
      and starts_at > now() + interval '12 hours') > 0);
select expect_num('the third studio was never touched',
  (select count(*) from class_occurrences
    where studio_id = 'f1e0f1e0-0000-0000-0000-000000000003' and status = 'cancelled')::bigint, 0);
select expect_num('...and nothing of its was confirmed either, flagged or not',
  (select count(*) from class_occurrences
    where studio_id = 'f1e0f1e0-0000-0000-0000-000000000003'
      and committed_at is not null)::bigint, 0);

-- =============================================================================
-- 7. Guards, and the reporting number a studio actually wants
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','f1e0f1e0-0000-0000-0000-0000000000a2',false);
select expect_raises('another studio''s owner cannot read this one''s pending list',
  $$select * from flex_pending('f1e0f1e0-0000-0000-0000-000000000001')$$, 'PT403');
select expect_raises('...nor flip its classes',
  $$select set_occurrence_guaranteed('f1e0f1e0-0000-0000-0000-00000000f001')$$, 'PT404');
reset role;
select set_config('request.jwt.claim.sub','f1e0f1e0-0000-0000-0000-0000000000a2',false);
set role authenticated;
-- 42501, not PT403: the sweep is granted to service_role alone, so a signed-in
-- session is refused by the ACL before it ever reaches the is_service_context()
-- guard inside. Two locks, and the outer one answers first.
select expect_raises('the sweep is a background job, not something a session runs',
  $$select sweep_commitments()$$, '42501');

select set_config('request.jwt.claim.sub','f1e0f1e0-0000-0000-0000-0000000000a1',false);
select set_config('t.rep', (select flex_report('f1e0f1e0-0000-0000-0000-000000000001',
  (now() at time zone 'Europe/Prague')::date,
  (now() at time zone 'Europe/Prague')::date + 14)::text), false);
select expect_true('the report counts flex classes that ran and that cancelled',
  (current_setting('t.rep')::jsonb -> 'flex' ->> 'ran')::int > 0
  and (current_setting('t.rep')::jsonb -> 'flex' ->> 'cancelled')::int > 0);
select expect_true('...and gives a fill rate for flex and for core, to compare',
  (current_setting('t.rep')::jsonb -> 'flex' ? 'fill_pct')
  and (current_setting('t.rep')::jsonb -> 'core' ? 'fill_pct'));
-- Fill is measured on the classes that RAN: averaging a cancelled class's zero
-- would make flex look emptier than it is and argue against the slots working.
select expect_true('...measured on what ran, so a cancellation does not drag it down',
  (current_setting('t.rep')::jsonb -> 'flex' ->> 'fill_pct')::numeric > 0);

reset role;
select set_config('request.jwt.claim.sub', null, false);
select 'flex suite finished' as done;
