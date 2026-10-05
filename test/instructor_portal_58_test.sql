-- =============================================================================
-- Decision 58 — next teaching week, confirmations-off silence, and directed
-- cover from a named colleague. UUID space 58c0.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_true(label text, actual boolean) returns void language plpgsql as $$
begin if actual then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_false(label text, actual boolean) returns void language plpgsql as $$
begin if actual is not null and not actual then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected false, got %', label, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_num(label text, actual bigint, want bigint) returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (%)', label, actual;
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_text(label text, actual text, want text) returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (%)', label, actual;
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if; end $$;
create or replace function expect_raises(label text, code text, stmt text) returns void language plpgsql as $$
begin
  begin execute stmt; raise exception 'FAIL  %  expected % but nothing raised', label, code;
  exception
    when others then
      if SQLSTATE = code then raise notice 'PASS  %  (%)', label, code;
      else raise exception 'FAIL  %  expected %, got % (%)', label, code, SQLSTATE, SQLERRM; end if;
  end;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('58c0c058-0000-0000-0000-0000000000a1'),  -- owner
  ('58c0c058-0000-0000-0000-0000000000d1'),  -- I1 requester
  ('58c0c058-0000-0000-0000-0000000000d2'),  -- I2 colleague/taker
  ('58c0c058-0000-0000-0000-0000000000d3');  -- I3 another
insert into profiles (id, email) values
  ('58c0c058-0000-0000-0000-0000000000a1','58c0-o@example.com'),
  ('58c0c058-0000-0000-0000-0000000000d1','58c0-1@example.com'),
  ('58c0c058-0000-0000-0000-0000000000d2','58c0-2@example.com'),
  ('58c0c058-0000-0000-0000-0000000000d3','58c0-3@example.com');
insert into studios (id, name, slug, timezone, currency, status) values
  ('58c0c058-0000-0000-0000-000000000001','Portal 58','portal58','Europe/Prague','CZK','active');
-- assignment_confirmations ON to start; auto-accept OFF; escalation 4h.
insert into studio_settings (studio_id, assignment_confirmations, cover_auto_accept_enabled, cover_escalation_hours, week_confirm_enabled)
values ('58c0c058-0000-0000-0000-000000000001', true, false, 4, true);
insert into locations (id, studio_id, name, is_primary) values
  ('58c0c058-0000-0000-0000-00000000000a','58c0c058-0000-0000-0000-000000000001','Main',true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('58c0c058-0000-0000-0000-0000000ee0a1','58c0c058-0000-0000-0000-000000000001','58c0c058-0000-0000-0000-00000000000a','R',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('58c0c058-0000-0000-0000-0000000cc0a1','58c0c058-0000-0000-0000-000000000001','Reformer',50,10);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('58c0c058-0000-0000-0000-000000aa00a1','58c0c058-0000-0000-0000-000000000001','58c0c058-0000-0000-0000-0000000000a1','58c0-o@example.com','owner'),
  ('58c0c058-0000-0000-0000-000000aa00d1','58c0c058-0000-0000-0000-000000000001','58c0c058-0000-0000-0000-0000000000d1','58c0-1@example.com','instructor'),
  ('58c0c058-0000-0000-0000-000000aa00d2','58c0c058-0000-0000-0000-000000000001','58c0c058-0000-0000-0000-0000000000d2','58c0-2@example.com','instructor'),
  ('58c0c058-0000-0000-0000-000000aa00d3','58c0c058-0000-0000-0000-000000000001','58c0c058-0000-0000-0000-0000000000d3','58c0-3@example.com','instructor');
insert into instructors (id, studio_id, display_name, staff_id) values
  ('58c0c058-0000-0000-0000-0000000d00d1','58c0c058-0000-0000-0000-000000000001','Ivy One','58c0c058-0000-0000-0000-000000aa00d1'),
  ('58c0c058-0000-0000-0000-0000000d00d2','58c0c058-0000-0000-0000-000000000001','Bo Two','58c0c058-0000-0000-0000-000000aa00d2'),
  ('58c0c058-0000-0000-0000-0000000d00d3','58c0c058-0000-0000-0000-000000000001','Cy Three','58c0c058-0000-0000-0000-000000aa00d3');
insert into instructor_class_types (studio_id, instructor_id, class_type_id)
select '58c0c058-0000-0000-0000-000000000001', i, '58c0c058-0000-0000-0000-0000000cc0a1'
  from (values ('58c0c058-0000-0000-0000-0000000d00d1'::uuid),
               ('58c0c058-0000-0000-0000-0000000d00d2'::uuid),
               ('58c0c058-0000-0000-0000-0000000d00d3'::uuid)) x(i);
insert into instructor_availability (instructor_id, studio_id, day_of_week, starts_at_time, ends_at_time, approval_status)
select i, '58c0c058-0000-0000-0000-000000000001', d, '00:00','23:59','approved'
  from (values ('58c0c058-0000-0000-0000-0000000d00d1'::uuid),
               ('58c0c058-0000-0000-0000-0000000d00d2'::uuid),
               ('58c0c058-0000-0000-0000-0000000d00d3'::uuid)) x(i),
       generate_series(0,6) d;

-- =============================================================================
-- (2) Confirmations off = nothing to confirm (the requests reader).
-- =============================================================================
-- Two assigned classes for I1, next week, with Decision-38 asks stamped.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, booked_count, starts_at, ends_at, status, assignment_requested_at)
values
  ('58c0c058-0000-0000-0000-00000000a001','58c0c058-0000-0000-0000-000000000001','58c0c058-0000-0000-0000-00000000000a','58c0c058-0000-0000-0000-0000000cc0a1','58c0c058-0000-0000-0000-0000000ee0a1','58c0c058-0000-0000-0000-0000000d00d1','Reformer',10,0, now()+interval '8 days', now()+interval '8 days'+interval '50 min','scheduled', now()),
  ('58c0c058-0000-0000-0000-00000000a002','58c0c058-0000-0000-0000-000000000001','58c0c058-0000-0000-0000-00000000000a','58c0c058-0000-0000-0000-0000000cc0a1','58c0c058-0000-0000-0000-0000000ee0a1','58c0c058-0000-0000-0000-0000000d00d1','Reformer',10,0, now()+interval '9 days', now()+interval '9 days'+interval '50 min','scheduled', now());

-- Switch ON → the reader returns both. (instructor_week's 3-arg overload is
-- guarded to the instructor/manager only — no service bypass — so it is read as
-- I1.)
select expect_num('requests reader: switch on → rows',
  (select count(*) from instructor_assignment_requests('58c0c058-0000-0000-0000-0000000d00d1'))::bigint, 2);
set role authenticated;
select set_config('request.jwt.claim.sub','58c0c058-0000-0000-0000-0000000000d1',false);  -- I1
select expect_true('instructor_week.confirmations_on mirrors the switch (on)',
  (instructor_week('58c0c058-0000-0000-0000-0000000d00d1', (now() at time zone 'Europe/Prague')::date, (now() at time zone 'Europe/Prague')::date + 20) ->> 'confirmations_on')::boolean);
reset role;

-- Switch OFF → no rows (nothing deleted), confirmations_on false.
update studio_settings set assignment_confirmations = false where studio_id='58c0c058-0000-0000-0000-000000000001';
select expect_num('requests reader: switch off → no rows (nothing deleted)',
  (select count(*) from instructor_assignment_requests('58c0c058-0000-0000-0000-0000000d00d1'))::bigint, 0);
set role authenticated;
select set_config('request.jwt.claim.sub','58c0c058-0000-0000-0000-0000000000d1',false);  -- I1
select expect_false('instructor_week.confirmations_on mirrors the switch (off)',
  (instructor_week('58c0c058-0000-0000-0000-0000000d00d1', (now() at time zone 'Europe/Prague')::date, (now() at time zone 'Europe/Prague')::date + 20) ->> 'confirmations_on')::boolean);
reset role;
-- The underlying asks are UNTOUCHED on the occurrences (resume where it left off).
select expect_num('the assignment asks still sit on the occurrences, not deleted',
  (select count(*) from class_occurrences where studio_id='58c0c058-0000-0000-0000-000000000001'
     and assignment_requested_at is not null and assignment_confirmed_at is null)::bigint, 2);

-- Switch back ON → rows again.
update studio_settings set assignment_confirmations = true where studio_id='58c0c058-0000-0000-0000-000000000001';
select expect_num('requests reader: switch back on → rows again (resumes)',
  (select count(*) from instructor_assignment_requests('58c0c058-0000-0000-0000-0000000d00d1'))::bigint, 2);

-- Teeth (prove RED for the switch-off reader): remove the gate → rows appear
-- while the switch is off.
update studio_settings set assignment_confirmations = false where studio_id='58c0c058-0000-0000-0000-000000000001';
create or replace function instructor_assignment_requests(p_instructor_id uuid)
returns table(occurrence_id uuid, name text, local_date date, local_start text,
              local_end text, room_name text, series_id uuid, series_name text)
language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_tz text;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  select timezone into v_tz from studios where id = v_studio;
  return query
  select o.id, o.name, (o.starts_at at time zone v_tz)::date,
         to_char(o.starts_at at time zone v_tz, 'HH24:MI'),
         to_char(o.ends_at   at time zone v_tz, 'HH24:MI'),
         r.name, o.series_id, ser.name
    from class_occurrences o
    left join rooms r on r.id = o.room_id
    left join class_series ser on ser.id = o.series_id
   where o.instructor_id = p_instructor_id and o.status = 'scheduled'
     and o.starts_at > now()
     and o.assignment_requested_at is not null and o.assignment_confirmed_at is null
     and month_published(v_studio, o.starts_at)
   order by o.starts_at;
end $$;
select expect_num('TEETH: without the gate, rows appear while the switch is off',
  (select count(*) from instructor_assignment_requests('58c0c058-0000-0000-0000-0000000d00d1'))::bigint, 2);
-- Restore the real (gated) definition for the rest of the suite.
create or replace function instructor_assignment_requests(p_instructor_id uuid)
returns table(occurrence_id uuid, name text, local_date date, local_start text,
              local_end text, room_name text, series_id uuid, series_name text)
language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_tz text;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(v_studio), false)
     and p_instructor_id is distinct from auth_instructor_id(v_studio)
     and not is_service_context() then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;
  if not coalesce((select assignment_confirmations from studio_settings where studio_id = v_studio), false) then
    return;
  end if;
  select timezone into v_tz from studios where id = v_studio;
  return query
  select o.id, o.name, (o.starts_at at time zone v_tz)::date,
         to_char(o.starts_at at time zone v_tz, 'HH24:MI'),
         to_char(o.ends_at   at time zone v_tz, 'HH24:MI'),
         r.name, o.series_id, ser.name
    from class_occurrences o
    left join rooms r on r.id = o.room_id
    left join class_series ser on ser.id = o.series_id
   where o.instructor_id = p_instructor_id and o.status = 'scheduled'
     and o.starts_at > now()
     and o.assignment_requested_at is not null and o.assignment_confirmed_at is null
     and month_published(v_studio, o.starts_at)
   order by o.starts_at;
end $$;
update studio_settings set assignment_confirmations = true where studio_id='58c0c058-0000-0000-0000-000000000001';

-- sweep_week_confirmations sends nothing with assignment_confirmations off.
-- Make today the ask day for this studio, and give I2 a class next week.
-- Wednesday of NEXT week (studio_week_start+9), so it is always inside the
-- sweep's [+7, +13] "week ahead" window whatever today's weekday is.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, booked_count, starts_at, ends_at, status)
values ('58c0c058-0000-0000-0000-00000000a0c2','58c0c058-0000-0000-0000-000000000001','58c0c058-0000-0000-0000-00000000000a','58c0c058-0000-0000-0000-0000000cc0a1','58c0c058-0000-0000-0000-0000000ee0a1','58c0c058-0000-0000-0000-0000000d00d2','Reformer',10,0,
        (studio_week_start('58c0c058-0000-0000-0000-000000000001', (now() at time zone 'Europe/Prague')::date) + 9 || ' 10:00')::timestamp at time zone 'Europe/Prague',
        (studio_week_start('58c0c058-0000-0000-0000-000000000001', (now() at time zone 'Europe/Prague')::date) + 9 || ' 10:50')::timestamp at time zone 'Europe/Prague','scheduled');
update studio_settings
   set week_confirm_ask_dow = extract(dow from (now() at time zone 'Europe/Prague')::date)::int,
       assignment_confirmations = false
 where studio_id='58c0c058-0000-0000-0000-000000000001';
select expect_num('sweep_week_confirmations: switch off → asked=0',
  (sweep_week_confirmations() ->> 'asked')::bigint, 0);
select expect_num('...and no week_confirm_ask row exists for this studio',
  (select count(*) from notifications where template_key='week_confirm_ask'
     and studio_id='58c0c058-0000-0000-0000-000000000001')::bigint, 0);
-- Teeth: switch on → the sweep asks (proves the gate, not the day).
update studio_settings set assignment_confirmations = true where studio_id='58c0c058-0000-0000-0000-000000000001';
select sweep_week_confirmations();
select expect_true('TEETH: switch on → sweep queues at least one week_confirm_ask',
  (select count(*) > 0 from notifications where template_key='week_confirm_ask'
     and studio_id='58c0c058-0000-0000-0000-000000000001'));

-- =============================================================================
-- (1) Next teaching week.
-- =============================================================================
-- I1 has an assigned class THIS week → this week.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, booked_count, starts_at, ends_at, status)
values ('58c0c058-0000-0000-0000-00000000b001','58c0c058-0000-0000-0000-000000000001','58c0c058-0000-0000-0000-00000000000a','58c0c058-0000-0000-0000-0000000cc0a1','58c0c058-0000-0000-0000-0000000ee0a1','58c0c058-0000-0000-0000-0000000d00d1','Reformer',10,0,
        (studio_week_start('58c0c058-0000-0000-0000-000000000001', (now() at time zone 'Europe/Prague')::date) + 2 || ' 10:00')::timestamp at time zone 'Europe/Prague',
        (studio_week_start('58c0c058-0000-0000-0000-000000000001', (now() at time zone 'Europe/Prague')::date) + 2 || ' 10:50')::timestamp at time zone 'Europe/Prague','scheduled');
select expect_text('next teaching week: a class THIS week → this week',
  instructor_next_teaching_week('58c0c058-0000-0000-0000-0000000d00d1')::text,
  studio_week_start('58c0c058-0000-0000-0000-000000000001', (now() at time zone 'Europe/Prague')::date)::text);

-- I3 has nothing until ~6 weeks out → that week's start.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, booked_count, starts_at, ends_at, status)
values ('58c0c058-0000-0000-0000-00000000b003','58c0c058-0000-0000-0000-000000000001','58c0c058-0000-0000-0000-00000000000a','58c0c058-0000-0000-0000-0000000cc0a1','58c0c058-0000-0000-0000-0000000ee0a1','58c0c058-0000-0000-0000-0000000d00d3','Reformer',10,0, now()+interval '42 days', now()+interval '42 days'+interval '50 min','scheduled');
select expect_text('next teaching week: none until week 6 → that week''s start',
  instructor_next_teaching_week('58c0c058-0000-0000-0000-0000000d00d3')::text,
  studio_week_start('58c0c058-0000-0000-0000-000000000001', (now() at time zone 'Europe/Prague')::date + 42)::text);

-- I2 currently has one class next week (a0c2), so it is not "no classes".
-- A truly empty instructor → null. Use a fourth instructor with no classes.
insert into auth.users (id) values ('58c0c058-0000-0000-0000-0000000000d4');
insert into profiles (id, email) values ('58c0c058-0000-0000-0000-0000000000d4','58c0-4@example.com');
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('58c0c058-0000-0000-0000-000000aa00d4','58c0c058-0000-0000-0000-000000000001','58c0c058-0000-0000-0000-0000000000d4','58c0-4@example.com','instructor');
insert into instructors (id, studio_id, display_name, staff_id) values
  ('58c0c058-0000-0000-0000-0000000d00d4','58c0c058-0000-0000-0000-000000000001','Di Four','58c0c058-0000-0000-0000-000000aa00d4');
select expect_true('next teaching week: no classes → null',
  instructor_next_teaching_week('58c0c058-0000-0000-0000-0000000d00d4') is null);

-- =============================================================================
-- (3) Directed cover.
-- =============================================================================
-- Amendment: a no-login instructor exists, and the picker shows EVERY active
-- instructor with has_login. I5 has no staff_id → no login.
insert into instructors (id, studio_id, display_name, staff_id) values
  ('58c0c058-0000-0000-0000-0000000d00d5','58c0c058-0000-0000-0000-000000000001','No Login Nina', null);
select expect_num('picker: all active instructors (I2,I3,I4,I5), not only those with a login',
  (select count(*) from instructor_colleagues('58c0c058-0000-0000-0000-0000000d00d1'))::bigint, 4);
select expect_false('picker: the no-login colleague is has_login=false',
  (select has_login from instructor_colleagues('58c0c058-0000-0000-0000-0000000d00d1')
    where instructor_id='58c0c058-0000-0000-0000-0000000d00d5'));
select expect_true('picker: a login colleague is has_login=true',
  (select has_login from instructor_colleagues('58c0c058-0000-0000-0000-0000000d00d1')
    where instructor_id='58c0c058-0000-0000-0000-0000000d00d2'));

-- A future class assigned to I1, 10 DAYS out (lead time proves close-enough is
-- bypassed for a directed accept). I1 asks I2 in particular.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, booked_count, starts_at, ends_at, status)
values ('58c0c058-0000-0000-0000-00000000c001','58c0c058-0000-0000-0000-000000000001','58c0c058-0000-0000-0000-00000000000a','58c0c058-0000-0000-0000-0000000cc0a1','58c0c058-0000-0000-0000-0000000ee0a1','58c0c058-0000-0000-0000-0000000d00d1','Reformer',10,2, now()+interval '10 days', now()+interval '10 days'+interval '50 min','scheduled');

-- Amendment: asking a no-login colleague is refused PT400 by name (before any
-- cover_requests row). c001 stays clean for the real ask below.
set role authenticated;
select set_config('request.jwt.claim.sub','58c0c058-0000-0000-0000-0000000000d1',false);  -- I1
select expect_raises('ask a no-login colleague → PT400', 'PT400',
  $$ select request_cover('58c0c058-0000-0000-0000-00000000c001', null, '58c0c058-0000-0000-0000-0000000d00d5') $$);
reset role;
do $$ declare m text; begin
  set role authenticated; perform set_config('request.jwt.claim.sub','58c0c058-0000-0000-0000-0000000000d1',false);
  begin perform request_cover('58c0c058-0000-0000-0000-00000000c001', null, '58c0c058-0000-0000-0000-0000000d00d5');
  exception when others then m := sqlerrm; end;
  reset role; perform set_config('t.nologin_msg', coalesce(m,'(none)'), false);
end $$;
select expect_text('...the PT400 names the colleague and points at inviting them',
  current_setting('t.nologin_msg'),
  'No Login Nina doesn''t have an app login yet — ask the studio to invite them.');
select expect_num('...no cover request was created by the refused ask',
  (select count(*) from cover_requests where occurrence_id='58c0c058-0000-0000-0000-00000000c001')::bigint, 0);

set role authenticated;
select set_config('request.jwt.claim.sub','58c0c058-0000-0000-0000-0000000000d1',false);  -- I1
select expect_true('I1 asks I2 in particular → directed',
  (request_cover('58c0c058-0000-0000-0000-00000000c001','swap please','58c0c058-0000-0000-0000-0000000d00d2')::jsonb ->> 'directed')::boolean);
reset role;
select expect_text('...the request records the asked colleague',
  (select asked_instructor_id::text from cover_requests where occurrence_id='58c0c058-0000-0000-0000-00000000c001'),
  '58c0c058-0000-0000-0000-0000000d00d2');
-- RED-provable: the directed ask queues the dedicated cover_asked, NOT the
-- generic cover_available. Reverting the template switch makes this fail (1→0).
select expect_num('...exactly ONE cover_asked to I2 (not the generic cover_available)',
  (select count(*) from notifications where template_key='cover_asked'
     and user_id='58c0c058-0000-0000-0000-0000000000d2')::bigint, 1);
select expect_num('...and ZERO generic cover_available to I2',
  (select count(*) from notifications where template_key='cover_available'
     and user_id='58c0c058-0000-0000-0000-0000000000d2')::bigint, 0);
select expect_num('...and none to I3 (not broadcast)',
  (select count(*) from notifications where template_key in ('cover_asked','cover_available')
     and user_id='58c0c058-0000-0000-0000-0000000000d3')::bigint, 0);
-- The cover_asked payload carries the class fields and the portal href.
select expect_text('...cover_asked names the class and the requester',
  (select payload ->> 'class_name' || '|' || (payload ->> 'requester_name')
     from notifications where template_key='cover_asked' and user_id='58c0c058-0000-0000-0000-0000000000d2'),
  'Reformer|Ivy One');
select expect_text('...and carries the 2-booked phrase and the reason',
  (select (payload ->> 'booked_phrase') || '|' || (payload ->> 'reason_line')
     from notifications where template_key='cover_asked' and user_id='58c0c058-0000-0000-0000-0000000000d2'),
  '2 booked|swap please. ');
select expect_true('...and the href is the instructor portal /instructor/shifts link',
  (select (payload ->> 'href') like 'https://%/instructor/shifts'
     from notifications where template_key='cover_asked' and user_id='58c0c058-0000-0000-0000-0000000000d2'));

-- The directed ask shows in I2's Open classes directed_covers, with asked_by_name.
select expect_num('I2 sees the directed ask in Open classes',
  jsonb_array_length(instructor_open_classes('58c0c058-0000-0000-0000-0000000d00d2') -> 'directed_covers'), 1);
select expect_text('...named by the requester',
  (instructor_open_classes('58c0c058-0000-0000-0000-0000000d00d2') -> 'directed_covers' -> 0 ->> 'asked_by_name'),
  'Ivy One');
select expect_num('...and I3 does NOT see a cover directed to someone else',
  jsonb_array_length(instructor_open_classes('58c0c058-0000-0000-0000-0000000d00d3') -> 'directed_covers'), 0);

-- A non-asked instructor cannot accept while directed.
set role authenticated;
select set_config('request.jwt.claim.sub','58c0c058-0000-0000-0000-0000000000d3',false);  -- I3
select expect_raises('non-asked accept → PT403 "asked first"', 'PT403',
  $$ select accept_cover('58c0c058-0000-0000-0000-00000000c001') $$);
reset role;

-- Asked accept + auto-accept ON → final at once (close-enough bypassed at 10 days).
update studio_settings set cover_auto_accept_enabled = true where studio_id='58c0c058-0000-0000-0000-000000000001';
set role authenticated;
select set_config('request.jwt.claim.sub','58c0c058-0000-0000-0000-0000000000d2',false);  -- I2
select expect_true('asked + auto-accept on → final (10 days out, close-enough bypassed)',
  (accept_cover('58c0c058-0000-0000-0000-00000000c001')::jsonb ->> 'final')::boolean);
reset role;
select expect_text('...the class is now I2''s',
  (select instructor_id::text from class_occurrences where id='58c0c058-0000-0000-0000-00000000c001'),
  '58c0c058-0000-0000-0000-0000000d00d2');
select expect_text('...the request is approved, covered by I2',
  (select status || ':' || covered_by::text from cover_requests where occurrence_id='58c0c058-0000-0000-0000-00000000c001'),
  'approved:58c0c058-0000-0000-0000-0000000d00d2');
select expect_num('...the requester I1 got cover_asked_confirmed (auto-accept final)',
  (select count(*) from notifications where template_key='cover_asked_confirmed'
     and user_id='58c0c058-0000-0000-0000-0000000000d1')::bigint, 1);
select expect_true('...the message reads "{Bo Two} is covering {Reformer} … you''re off it"',
  (select (payload ->> 'message') like 'Bo Two is covering Reformer on %— you''re off it.'
     from notifications where template_key='cover_asked_confirmed' and user_id='58c0c058-0000-0000-0000-0000000000d1'));
select expect_num('...and it is audited as auto_covered',
  (select count(*) from audit_logs where action='cover.auto_covered'
     and entity_id=(select id from cover_requests where occurrence_id='58c0c058-0000-0000-0000-00000000c001'))::bigint, 1);

-- Asked accept + auto-accept OFF → accepted_pending, staff told, staff approve finalises.
update studio_settings set cover_auto_accept_enabled = false where studio_id='58c0c058-0000-0000-0000-000000000001';
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, booked_count, starts_at, ends_at, status)
values ('58c0c058-0000-0000-0000-00000000c002','58c0c058-0000-0000-0000-000000000001','58c0c058-0000-0000-0000-00000000000a','58c0c058-0000-0000-0000-0000000cc0a1','58c0c058-0000-0000-0000-0000000ee0a1','58c0c058-0000-0000-0000-0000000d00d1','Reformer',10,0, now()+interval '11 days', now()+interval '11 days'+interval '50 min','scheduled');
set role authenticated;
select set_config('request.jwt.claim.sub','58c0c058-0000-0000-0000-0000000000d1',false);  -- I1
select request_cover('58c0c058-0000-0000-0000-00000000c002', null, '58c0c058-0000-0000-0000-0000000d00d2');
select set_config('request.jwt.claim.sub','58c0c058-0000-0000-0000-0000000000d2',false);  -- I2
select expect_false('asked + auto-accept off → NOT final (accepted_pending)',
  (accept_cover('58c0c058-0000-0000-0000-00000000c002')::jsonb ->> 'final')::boolean);
reset role;
select expect_text('...the request is accepted_pending, covered_by I2',
  (select status || ':' || covered_by::text from cover_requests where occurrence_id='58c0c058-0000-0000-0000-00000000c002'),
  'accepted_pending:58c0c058-0000-0000-0000-0000000d00d2');
select expect_num('...staff were told it needs approval',
  (select count(*) from notifications where template_key='cover_needs_approval'
     and studio_id='58c0c058-0000-0000-0000-000000000001')::bigint, 1);
select expect_true('...and the requester I1 got cover_asked_confirmed "agreed … the studio will confirm"',
  (select (payload ->> 'message') like 'Bo Two agreed to cover Reformer on %; the studio will confirm.'
     from notifications where template_key='cover_asked_confirmed'
       and user_id='58c0c058-0000-0000-0000-0000000000d1'
       and dedupe_key='cover_asked_confirmed:'||(select id from cover_requests where occurrence_id='58c0c058-0000-0000-0000-00000000c002')));
select expect_false('...the class is still I1''s until approved',
  (select instructor_id = '58c0c058-0000-0000-0000-0000000d00d2' from class_occurrences where id='58c0c058-0000-0000-0000-00000000c002'));
-- Owner approves the accepted_pending row.
set role authenticated;
select set_config('request.jwt.claim.sub','58c0c058-0000-0000-0000-0000000000a1',false);  -- owner
select expect_true('owner approves the accepted_pending cover',
  (approve_cover_request((select id from cover_requests where occurrence_id='58c0c058-0000-0000-0000-00000000c002'),
     'assign','58c0c058-0000-0000-0000-0000000d00d2')::jsonb ->> 'ok')::boolean);
reset role;
select expect_text('...the class is now I2''s, request approved',
  (select instructor_id::text from class_occurrences where id='58c0c058-0000-0000-0000-00000000c002'),
  '58c0c058-0000-0000-0000-0000000d00d2');

-- "Can't" → opens to everyone, requester told.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, booked_count, starts_at, ends_at, status)
values ('58c0c058-0000-0000-0000-00000000c003','58c0c058-0000-0000-0000-000000000001','58c0c058-0000-0000-0000-00000000000a','58c0c058-0000-0000-0000-0000000cc0a1','58c0c058-0000-0000-0000-0000000ee0a1','58c0c058-0000-0000-0000-0000000d00d1','Reformer',10,0, now()+interval '12 days', now()+interval '12 days'+interval '50 min','scheduled');
set role authenticated;
select set_config('request.jwt.claim.sub','58c0c058-0000-0000-0000-0000000000d1',false);  -- I1
select request_cover('58c0c058-0000-0000-0000-00000000c003', null, '58c0c058-0000-0000-0000-0000000d00d2');
select set_config('request.jwt.claim.sub','58c0c058-0000-0000-0000-0000000000d2',false);  -- I2
select expect_true('I2 says Can''t → opens to everyone',
  (decline_directed_cover((select id from cover_requests where occurrence_id='58c0c058-0000-0000-0000-00000000c003'))::jsonb ->> 'opened')::boolean);
reset role;
select expect_true('...the ask is cleared, still pending (open to all)',
  (select asked_instructor_id is null and status='pending' from cover_requests where occurrence_id='58c0c058-0000-0000-0000-00000000c003'));
select expect_num('...the requester got cover_asked_declined',
  (select count(*) from notifications where template_key='cover_asked_declined'
     and dedupe_key='cover_asked_declined:'||(select id from cover_requests where occurrence_id='58c0c058-0000-0000-0000-00000000c003')
     and user_id='58c0c058-0000-0000-0000-0000000000d1')::bigint, 1);

-- Escalation sweep opens an unanswered directed request after the hours.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, booked_count, starts_at, ends_at, status)
values ('58c0c058-0000-0000-0000-00000000c004','58c0c058-0000-0000-0000-000000000001','58c0c058-0000-0000-0000-00000000000a','58c0c058-0000-0000-0000-0000000cc0a1','58c0c058-0000-0000-0000-0000000ee0a1','58c0c058-0000-0000-0000-0000000d00d1','Reformer',10,0, now()+interval '13 days', now()+interval '13 days'+interval '50 min','scheduled');
insert into cover_requests (id, studio_id, occurrence_id, instructor_id, asked_instructor_id, status, requested_at)
values ('58c0c058-0000-0000-0000-00000000cc04','58c0c058-0000-0000-0000-000000000001','58c0c058-0000-0000-0000-00000000c004','58c0c058-0000-0000-0000-0000000d00d1','58c0c058-0000-0000-0000-0000000d00d2','pending', now() - interval '5 hours');
select sweep_cover_escalations();
select expect_true('escalation sweep opens an unanswered directed request past the hours',
  (select asked_instructor_id is null and status='pending' from cover_requests where id='58c0c058-0000-0000-0000-00000000cc04'));
select expect_num('...and the requester got cover_asked_declined',
  (select count(*) from notifications where template_key='cover_asked_declined'
     and dedupe_key='cover_asked_declined:58c0c058-0000-0000-0000-00000000cc04')::bigint, 1);

-- An everyone-cover keeps the close-enough rule (PT409 at 10 days, auto-accept on).
update studio_settings set cover_auto_accept_enabled = true where studio_id='58c0c058-0000-0000-0000-000000000001';
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, booked_count, starts_at, ends_at, status)
values ('58c0c058-0000-0000-0000-00000000c005','58c0c058-0000-0000-0000-000000000001','58c0c058-0000-0000-0000-00000000000a','58c0c058-0000-0000-0000-0000000cc0a1','58c0c058-0000-0000-0000-0000000ee0a1','58c0c058-0000-0000-0000-0000000d00d1','Reformer',10,0, now()+interval '20 days', now()+interval '20 days'+interval '50 min','scheduled');
insert into cover_requests (studio_id, occurrence_id, instructor_id, status)
values ('58c0c058-0000-0000-0000-000000000001','58c0c058-0000-0000-0000-00000000c005','58c0c058-0000-0000-0000-0000000d00d1','pending');
set role authenticated;
select set_config('request.jwt.claim.sub','58c0c058-0000-0000-0000-0000000000d2',false);  -- I2
select expect_raises('everyone-cover 10 days out → PT409 close-enough (unchanged)', 'PT409',
  $$ select accept_cover('58c0c058-0000-0000-0000-00000000c005') $$);
reset role;

-- withdraw_cover_request unchanged: the requester can take their request back.
set role authenticated;
select set_config('request.jwt.claim.sub','58c0c058-0000-0000-0000-0000000000d1',false);  -- I1
select expect_true('requester withdraws their own cover request',
  (withdraw_cover_request('58c0c058-0000-0000-0000-00000000cc04')::jsonb ->> 'ok')::boolean);
reset role;
select expect_text('...it is withdrawn',
  (select status from cover_requests where id='58c0c058-0000-0000-0000-00000000cc04'), 'withdrawn');

select 'instructor_portal_58_test: all assertions passed' as result;
