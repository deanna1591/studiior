-- =============================================================================
-- Decision 33 amendment — the coalesced instructor booking alert (migration 167).
-- UUID space a1e7, checked free. Run after `supabase db reset`.
-- =============================================================================
-- Per-tenant switch, no instructor opt-out. One notice per class per 15-min
-- window (deduped on class+bucket), the assigned instructor only, never for an
-- unassigned class or a draft month, nothing when off. Teeth: remove the dedupe
-- and six bookings make six notices.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin if actual then raise notice 'PASS  %  (got true)', label;
else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if; end $$;
-- The pending alert for a class in the current window.
create or replace function alert_for(occ uuid) returns notifications
language sql as $$ select * from notifications
  where template_key='instructor_booking_alert' and payload->>'occurrence_id'=occ::text
  order by created_at desc limit 1 $$;

-- --- Fixtures ---------------------------------------------------------------
insert into auth.users (id) values
  ('a1e7a1e7-0000-0000-0000-0000000000c1'),   -- instructor login (studio A)
  ('a1e7a1e7-0000-0000-0000-0000000000c3');   -- instructor login (studio C, draft)
insert into profiles (id, email) select id, id::text||'@example.com' from auth.users where id::text like 'a1e7a1e7%';

insert into studios (id, name, slug, timezone, currency, status) values
  ('a1e7a1e7-0000-0000-0000-000000000001','Alert A','a1e7-a','Europe/Prague','CZK','active'),
  ('a1e7a1e7-0000-0000-0000-000000000003','Draft C','a1e7-c','Europe/Prague','CZK','active');
-- A: alerts ON, publication off (everything published). C: alerts ON, publication ON.
insert into studio_settings (studio_id, instructor_booking_alerts, publication_enabled, require_waiver) values
  ('a1e7a1e7-0000-0000-0000-000000000001', true, false, false),
  ('a1e7a1e7-0000-0000-0000-000000000003', true, true,  false);
insert into locations (id, studio_id, name, is_primary) values
  ('a1e7a1e7-0000-0000-0000-00000000000a','a1e7a1e7-0000-0000-0000-000000000001','Main',true),
  ('a1e7a1e7-0000-0000-0000-00000000000c','a1e7a1e7-0000-0000-0000-000000000003','Main',true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('a1e7a1e7-0000-0000-0000-0000000000e1','a1e7a1e7-0000-0000-0000-000000000001','a1e7a1e7-0000-0000-0000-00000000000a','R1',10),
  ('a1e7a1e7-0000-0000-0000-0000000000e3','a1e7a1e7-0000-0000-0000-000000000003','a1e7a1e7-0000-0000-0000-00000000000c','R1',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('a1e7a1e7-0000-0000-0000-0000000000d9','a1e7a1e7-0000-0000-0000-000000000001','Reformer',50,10),
  ('a1e7a1e7-0000-0000-0000-0000000000da','a1e7a1e7-0000-0000-0000-000000000003','Reformer',50,10);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('a1e7a1e7-0000-0000-0000-000000005501','a1e7a1e7-0000-0000-0000-000000000001','a1e7a1e7-0000-0000-0000-0000000000c1','c1@example.com','instructor'),
  ('a1e7a1e7-0000-0000-0000-000000005503','a1e7a1e7-0000-0000-0000-000000000003','a1e7a1e7-0000-0000-0000-0000000000c3','c3@example.com','instructor');
insert into instructors (id, studio_id, staff_id, display_name) values
  ('a1e7a1e7-0000-0000-0000-0000000000f1','a1e7a1e7-0000-0000-0000-000000000001','a1e7a1e7-0000-0000-0000-000000005501','Cy Coach'),
  ('a1e7a1e7-0000-0000-0000-0000000000f3','a1e7a1e7-0000-0000-0000-000000000003','a1e7a1e7-0000-0000-0000-000000005503','Di Coach');
-- Members to book (six for A, plus a couple more).
insert into members (id, studio_id, first_name, last_name, email, status, joined_on, source)
select ('a1e7a1e7-0000-0000-0000-0000000b' || lpad(g::text,4,'0'))::uuid, 'a1e7a1e7-0000-0000-0000-000000000001',
       'M'||g, 'A', 'ma'||g||'@example.com', 'active', current_date, 'walk_in'
from generate_series(1,13) g;
insert into members (id, studio_id, first_name, last_name, email, status, joined_on, source) values
  ('a1e7a1e7-0000-0000-0000-0000000c0001','a1e7a1e7-0000-0000-0000-000000000003','Cara','C','cc@example.com','active',current_date,'walk_in');

-- Classes: X1 assigned+published (studio A); Y1 UNASSIGNED (studio A); Z1 a
-- DRAFT-month class at studio C (assigned, publication on, month not published).
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, starts_at, ends_at, capacity, booked_count, status, staffing) values
  ('a1e7a1e7-0000-0000-0000-0000000a0001','a1e7a1e7-0000-0000-0000-000000000001','a1e7a1e7-0000-0000-0000-00000000000a','a1e7a1e7-0000-0000-0000-0000000000d9','a1e7a1e7-0000-0000-0000-0000000000e1','a1e7a1e7-0000-0000-0000-0000000000f1','Reformer', now()+interval '3 days', now()+interval '3 days'+interval '50 min', 10, 0, 'scheduled','assigned'),
  ('a1e7a1e7-0000-0000-0000-0000000a0002','a1e7a1e7-0000-0000-0000-000000000001','a1e7a1e7-0000-0000-0000-00000000000a','a1e7a1e7-0000-0000-0000-0000000000d9','a1e7a1e7-0000-0000-0000-0000000000e1',null,'Reformer', now()+interval '4 days', now()+interval '4 days'+interval '50 min', 10, 0, 'scheduled','open'),
  ('a1e7a1e7-0000-0000-0000-0000000a0003','a1e7a1e7-0000-0000-0000-000000000003','a1e7a1e7-0000-0000-0000-00000000000c','a1e7a1e7-0000-0000-0000-0000000000da','a1e7a1e7-0000-0000-0000-0000000000e3','a1e7a1e7-0000-0000-0000-0000000000f3','Reformer',
   ((date_trunc('month', now() at time zone 'Europe/Prague') + interval '1 month')::date + time '10:00') at time zone 'Europe/Prague',
   ((date_trunc('month', now() at time zone 'Europe/Prague') + interval '1 month')::date + time '10:50') at time zone 'Europe/Prague', 10, 0, 'scheduled','assigned');

-- =============================================================================
-- 1. Six bookings within the window => ONE notice, headcount 6, "+6 booked",
--    to the assigned instructor's login and nobody else.
-- =============================================================================
insert into bookings (studio_id, occurrence_id, member_id, status)
select 'a1e7a1e7-0000-0000-0000-000000000001','a1e7a1e7-0000-0000-0000-0000000a0001',
       ('a1e7a1e7-0000-0000-0000-0000000b' || lpad(g::text,4,'0'))::uuid,'booked' from generate_series(1,6) g;

select expect_num('six bookings in the window => exactly one notice',
  (select count(*) from notifications where template_key='instructor_booking_alert'
    and payload->>'occurrence_id'='a1e7a1e7-0000-0000-0000-0000000a0001'), 1);
select expect_num('...with the running headcount 6',
  ((select alert_for('a1e7a1e7-0000-0000-0000-0000000a0001')).payload->>'headcount')::bigint, 6);
select expect_true('...the change line is +6 booked',
  ((select alert_for('a1e7a1e7-0000-0000-0000-0000000a0001')).payload->>'change_line') = '+6 booked');
select expect_true('...it is scheduled to the assigned instructor''s login',
  (select alert_for('a1e7a1e7-0000-0000-0000-0000000a0001')).user_id = 'a1e7a1e7-0000-0000-0000-0000000000c1'
   and (select alert_for('a1e7a1e7-0000-0000-0000-0000000a0001')).status = 'scheduled');
select expect_true('...it carries the class, when and roster link',
  ((select alert_for('a1e7a1e7-0000-0000-0000-0000000a0001')).payload->>'roster_link') like '%/instructor/roster/a1e7a1e7-0000-0000-0000-0000000a0001');

-- =============================================================================
-- 2. A cancellation AFTER the window => a second notice showing the change.
--    Simulate the first window's notice already sent and rolled off (rename its
--    dedupe, mark sent), so the next change opens a fresh notice.
-- =============================================================================
update notifications set status='sent', dedupe_key = dedupe_key || ':past'
 where template_key='instructor_booking_alert' and payload->>'occurrence_id'='a1e7a1e7-0000-0000-0000-0000000a0001';
update bookings set status='cancelled'
 where occurrence_id='a1e7a1e7-0000-0000-0000-0000000a0001'
   and member_id='a1e7a1e7-0000-0000-0000-0000000b0001';

select expect_num('a cancellation after the window makes a second (scheduled) notice',
  (select count(*) from notifications where template_key='instructor_booking_alert'
     and payload->>'occurrence_id'='a1e7a1e7-0000-0000-0000-0000000a0001' and status='scheduled'), 1);
select expect_true('...it shows 1 cancelled and headcount 5',
  ((select alert_for('a1e7a1e7-0000-0000-0000-0000000a0001')).payload->>'change_line') = '1 cancelled'
   and ((select alert_for('a1e7a1e7-0000-0000-0000-0000000a0001')).payload->>'headcount') = '5');

-- =============================================================================
-- 3. Unassigned class => no notice.
-- =============================================================================
insert into bookings (studio_id, occurrence_id, member_id, status) values
  ('a1e7a1e7-0000-0000-0000-000000000001','a1e7a1e7-0000-0000-0000-0000000a0002','a1e7a1e7-0000-0000-0000-0000000b0007','booked');
select expect_num('an unassigned class queues no instructor alert',
  (select count(*) from notifications where template_key='instructor_booking_alert'
     and payload->>'occurrence_id'='a1e7a1e7-0000-0000-0000-0000000a0002'), 0);

-- =============================================================================
-- 4. Draft month (Decision 25) => no notice.
-- =============================================================================
insert into bookings (studio_id, occurrence_id, member_id, status) values
  ('a1e7a1e7-0000-0000-0000-000000000003','a1e7a1e7-0000-0000-0000-0000000a0003','a1e7a1e7-0000-0000-0000-0000000c0001','booked');
select expect_num('a class in a draft month queues no instructor alert',
  (select count(*) from notifications where template_key='instructor_booking_alert'
     and payload->>'occurrence_id'='a1e7a1e7-0000-0000-0000-0000000a0003'), 0);

-- =============================================================================
-- 5. Switch OFF => no new notice.
-- =============================================================================
update studio_settings set instructor_booking_alerts=false where studio_id='a1e7a1e7-0000-0000-0000-000000000001';
insert into bookings (studio_id, occurrence_id, member_id, status) values
  ('a1e7a1e7-0000-0000-0000-000000000001','a1e7a1e7-0000-0000-0000-0000000a0001','a1e7a1e7-0000-0000-0000-0000000b0008','booked');
select expect_num('with the switch off, a booking queues nothing new (still just the two)',
  (select count(*) from notifications where template_key='instructor_booking_alert'
     and payload->>'occurrence_id'='a1e7a1e7-0000-0000-0000-0000000a0001'), 2);
update studio_settings set instructor_booking_alerts=true where studio_id='a1e7a1e7-0000-0000-0000-000000000001';

-- Another studio's instructor never receives studio A's alerts.
select expect_num('no alert is ever addressed to another instructor''s login',
  (select count(*) from notifications where template_key='instructor_booking_alert'
     and user_id = 'a1e7a1e7-0000-0000-0000-0000000000c3'), 0);

-- =============================================================================
-- 6. TEETH: remove the dedupe (a unique key per call) and six bookings make six
--    notices — proving the coalescing is what makes it one.
-- =============================================================================
create or replace function queue_instructor_booking_alert(p_occurrence_id uuid, p_gained int, p_lost int)
returns void language plpgsql security definer set search_path = public as $$
declare o class_occurrences%rowtype; v_user uuid;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if o.instructor_id is null then return; end if;
  if not coalesce((select instructor_booking_alerts from studio_settings where studio_id=o.studio_id),false) then return; end if;
  if not month_published(o.studio_id, o.starts_at) then return; end if;
  v_user := instructor_user_id(o.instructor_id);
  if v_user is null then return; end if;
  insert into notifications (studio_id, recipient_type, user_id, template_key, channel, payload, dedupe_key, scheduled_for, status)
  values (o.studio_id,'staff',v_user,'instructor_booking_alert','email',
          jsonb_build_object('occurrence_id',o.id),
          'instr_booking_alert:'||o.id||':'||gen_random_uuid(), now(), 'scheduled');
end $$;
delete from notifications where template_key='instructor_booking_alert';
-- Fresh members 9..13 (no existing booking) so one-live-per-member does not block them.
insert into bookings (studio_id, occurrence_id, member_id, status)
select 'a1e7a1e7-0000-0000-0000-000000000001','a1e7a1e7-0000-0000-0000-0000000a0001',
       ('a1e7a1e7-0000-0000-0000-0000000b' || lpad(g::text,4,'0'))::uuid,'booked' from generate_series(9,13) g;
select expect_num('teeth: without the dedupe, five bookings make five notices',
  (select count(*) from notifications where template_key='instructor_booking_alert'), 5);

select 'ALL INSTRUCTOR-ALERT TESTS PASSED' as done;
