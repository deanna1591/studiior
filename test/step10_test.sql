-- =============================================================================
-- Step 10 (migration 364): Decision 35 (a) staff mark attended, 21 (d) tier
-- changes from a date, 19 the filler keeps a coach's hours together, 106 (a)
-- the weekly core budget, and the series end-date fix (note under 42b).
-- UUID space 10ad, checked free. Run after `supabase db reset`.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_eq(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual,'null'); end if;
end $$;
create or replace function expect_err(label text, sql text, code text)
returns void language plpgsql as $$
begin
  execute sql;
  raise exception 'FAIL  %  expected error %, got none', label, code;
exception when others then
  if sqlstate = code then raise notice 'PASS  %  (raised %)', label, code;
  else raise exception 'FAIL  %  expected %, got % %', label, code, sqlstate, sqlerrm; end if;
end $$;

-- --- logins ----------------------------------------------------------------
insert into auth.users (id) values
  ('10ad0000-0000-0000-0000-0000000000a1'),   -- owner
  ('10ad0000-0000-0000-0000-0000000000f1'),   -- front desk
  ('10ad0000-0000-0000-0000-0000000000e1');   -- coach (instructor login)
insert into profiles (id, email, full_name) values
  ('10ad0000-0000-0000-0000-0000000000a1','10ad-owner@example.com','Olive Owner'),
  ('10ad0000-0000-0000-0000-0000000000f1','10ad-desk@example.com','Dee Desk'),
  ('10ad0000-0000-0000-0000-0000000000e1','10ad-coach@example.com','Cora Coach');

insert into studios (id, name, slug, timezone, currency, status) values
  ('10ad0000-0000-0000-0000-0000000000a0','Step Ten','10ad-s','UTC','PHP','active');
insert into studio_settings (studio_id, guarantees_enabled, flex_enabled, flex_min_bookings, core_min_bookings,
                             suspension_enabled, finalise_attendance, finalise_days_after, checkin_window_enforced)
values ('10ad0000-0000-0000-0000-0000000000a0', true, true, 2, 1, true, true, 1, false);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('10ad0000-0000-0000-0000-0000000005a1','10ad0000-0000-0000-0000-0000000000a0','10ad0000-0000-0000-0000-0000000000a1','10ad-owner@example.com','owner'),
  ('10ad0000-0000-0000-0000-0000000005f1','10ad0000-0000-0000-0000-0000000000a0','10ad0000-0000-0000-0000-0000000000f1','10ad-desk@example.com','front_desk'),
  ('10ad0000-0000-0000-0000-0000000005e1','10ad0000-0000-0000-0000-0000000000a0','10ad0000-0000-0000-0000-0000000000e1','10ad-coach@example.com','instructor');

insert into locations (id, studio_id, name, is_primary) values
  ('10ad0000-0000-0000-0000-00000000010c','10ad0000-0000-0000-0000-0000000000a0','Main', true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('10ad0000-0000-0000-0000-0000000001a1','10ad0000-0000-0000-0000-0000000000a0','10ad0000-0000-0000-0000-00000000010c','Room A',10),
  ('10ad0000-0000-0000-0000-0000000001a2','10ad0000-0000-0000-0000-0000000000a0','10ad0000-0000-0000-0000-00000000010c','Room B',10),
  ('10ad0000-0000-0000-0000-0000000001a3','10ad0000-0000-0000-0000-0000000000a0','10ad0000-0000-0000-0000-00000000010c','Room C',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity, session_kind) values
  ('10ad0000-0000-0000-0000-0000000cc001','10ad0000-0000-0000-0000-0000000000a0','Reformer',50,10,'group');
insert into instructors (id, studio_id, display_name, status, staff_id, core_classes_per_week) values
  ('10ad0000-0000-0000-0000-0000000a00c1','10ad0000-0000-0000-0000-0000000000a0','Cora Coach','active','10ad0000-0000-0000-0000-0000000005e1', 1),
  ('10ad0000-0000-0000-0000-0000000a00d2','10ad0000-0000-0000-0000-0000000000a0','Dan Other','active', null, 3),
  ('10ad0000-0000-0000-0000-0000000a00e3','10ad0000-0000-0000-0000-0000000000a0','Eve Third','active', null, 3);
insert into instructor_class_types (studio_id, instructor_id, class_type_id)
select '10ad0000-0000-0000-0000-0000000000a0', i, '10ad0000-0000-0000-0000-0000000cc001'::uuid
  from unnest(array['10ad0000-0000-0000-0000-0000000a00c1','10ad0000-0000-0000-0000-0000000a00d2','10ad0000-0000-0000-0000-0000000a00e3']::uuid[]) i;
insert into instructor_rate_versions (studio_id, instructor_id, effective_from, currency,
         base_rate_cents, per_head_rate_cents, per_head_threshold, full_house_bonus_cents, private_rate_cents) values
  ('10ad0000-0000-0000-0000-0000000000a0','10ad0000-0000-0000-0000-0000000a00c1', current_date - 60, 'PHP', 90000, 7500, 2, 0, 50000);

insert into members (id, studio_id, first_name, last_name, email, status, waiver_signed_at)
select ('10ad0000-0000-0000-0000-0000000d00'||lpad(n::text,2,'0'))::uuid, '10ad0000-0000-0000-0000-0000000000a0',
       'M', 'N'||n, '10ad-'||n||'@example.com', 'active', now()
  from generate_series(1,12) n;

-- =============================================================================
-- 1. Decision 35 (a): mark attended
-- =============================================================================
-- C1: the coach's class, started 30 minutes ago. C2: another coach's class,
-- started. C3: tomorrow. C4: the coach's, two days ago, committed + finalised.
insert into class_occurrences (id, studio_id, location_id, class_type_id, instructor_id, room_id, name,
         starts_at, ends_at, capacity, booked_count, status, committed_at, booked_at_cutoff) values
  ('10ad0000-0000-0000-0000-00000000c001','10ad0000-0000-0000-0000-0000000000a0','10ad0000-0000-0000-0000-00000000010c','10ad0000-0000-0000-0000-0000000cc001',
   '10ad0000-0000-0000-0000-0000000a00c1','10ad0000-0000-0000-0000-0000000001a1','C1', now()-interval '30 min', now()+interval '20 min', 10, 0, 'scheduled', null, null),
  ('10ad0000-0000-0000-0000-00000000c002','10ad0000-0000-0000-0000-0000000000a0','10ad0000-0000-0000-0000-00000000010c','10ad0000-0000-0000-0000-0000000cc001',
   '10ad0000-0000-0000-0000-0000000a00d2','10ad0000-0000-0000-0000-0000000001a2','C2', now()-interval '30 min', now()+interval '20 min', 10, 0, 'scheduled', null, null),
  ('10ad0000-0000-0000-0000-00000000c003','10ad0000-0000-0000-0000-0000000000a0','10ad0000-0000-0000-0000-00000000010c','10ad0000-0000-0000-0000-0000000cc001',
   '10ad0000-0000-0000-0000-0000000a00c1','10ad0000-0000-0000-0000-0000000001a1','C3', now()+interval '1 day', now()+interval '1 day 50 min', 10, 0, 'scheduled', null, null),
  ('10ad0000-0000-0000-0000-00000000c004','10ad0000-0000-0000-0000-0000000000a0','10ad0000-0000-0000-0000-00000000010c','10ad0000-0000-0000-0000-0000000cc001',
   '10ad0000-0000-0000-0000-0000000a00c1','10ad0000-0000-0000-0000-0000000001a1','C4', now()-interval '2 days', now()-interval '2 days'+interval '50 min', 10, 4, 'scheduled', now()-interval '3 days', 4);

insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at) values
  ('10ad0000-0000-0000-0000-0000000b0101','10ad0000-0000-0000-0000-0000000000a0','10ad0000-0000-0000-0000-00000000c001','10ad0000-0000-0000-0000-0000000d0001','booked','member','drop_in', now()-interval '1 day'),
  ('10ad0000-0000-0000-0000-0000000b0102','10ad0000-0000-0000-0000-0000000000a0','10ad0000-0000-0000-0000-00000000c001','10ad0000-0000-0000-0000-0000000d0002','booked','member','drop_in', now()-interval '1 day'),
  ('10ad0000-0000-0000-0000-0000000b0107','10ad0000-0000-0000-0000-0000000000a0','10ad0000-0000-0000-0000-00000000c001','10ad0000-0000-0000-0000-0000000d0007','booked','member','drop_in', now()-interval '1 day'),
  ('10ad0000-0000-0000-0000-0000000b0203','10ad0000-0000-0000-0000-0000000000a0','10ad0000-0000-0000-0000-00000000c002','10ad0000-0000-0000-0000-0000000d0003','booked','member','drop_in', now()-interval '1 day'),
  ('10ad0000-0000-0000-0000-0000000b0301','10ad0000-0000-0000-0000-0000000000a0','10ad0000-0000-0000-0000-00000000c003','10ad0000-0000-0000-0000-0000000d0001','booked','member','drop_in', now()-interval '1 day'),
  ('10ad0000-0000-0000-0000-0000000b0404','10ad0000-0000-0000-0000-0000000000a0','10ad0000-0000-0000-0000-00000000c004','10ad0000-0000-0000-0000-0000000d0004','booked','member','drop_in', now()-interval '3 days'),
  ('10ad0000-0000-0000-0000-0000000b0405','10ad0000-0000-0000-0000-0000000000a0','10ad0000-0000-0000-0000-00000000c004','10ad0000-0000-0000-0000-0000000d0005','booked','member','comp',    now()-interval '3 days'),
  ('10ad0000-0000-0000-0000-0000000b0406','10ad0000-0000-0000-0000-0000000000a0','10ad0000-0000-0000-0000-00000000c004','10ad0000-0000-0000-0000-0000000d0006','booked','member','drop_in', now()-interval '3 days'),
  ('10ad0000-0000-0000-0000-0000000b0408','10ad0000-0000-0000-0000-0000000000a0','10ad0000-0000-0000-0000-00000000c004','10ad0000-0000-0000-0000-0000000d0008','attended','member','drop_in', now()-interval '3 days');
-- M6 has a second unpaid no-show elsewhere (C2), so their strike must stand.
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at) values
  ('10ad0000-0000-0000-0000-0000000b0206','10ad0000-0000-0000-0000-0000000000a0','10ad0000-0000-0000-0000-00000000c002','10ad0000-0000-0000-0000-0000000d0006','booked','member','drop_in', now()-interval '1 day');
-- M5 paid a reservation fee for their (comp) seat.
insert into payments (studio_id, member_id, booking_id, amount_cents, currency, status, kind, provider)
values ('10ad0000-0000-0000-0000-0000000000a0','10ad0000-0000-0000-0000-0000000d0005','10ad0000-0000-0000-0000-0000000b0405',50000,'PHP','succeeded','reservation_fee','manual');

-- The no-shows, through the real status change (infraction + desk-pay strike).
update bookings set status = 'no_show' where id in ('10ad0000-0000-0000-0000-0000000b0404','10ad0000-0000-0000-0000-0000000b0405','10ad0000-0000-0000-0000-0000000b0406','10ad0000-0000-0000-0000-0000000b0206','10ad0000-0000-0000-0000-0000000b0107');
select expect_eq('fixture: M4 has an active no-show infraction',
  (select count(*)::text from member_infractions where booking_id='10ad0000-0000-0000-0000-0000000b0404' and status='active'), '1');
select expect_eq('fixture: M4 desk pay blocked (no_show)',
  (select desk_pay_blocked_reason from members where id='10ad0000-0000-0000-0000-0000000d0004'), 'no_show');

-- C4 finalised, its pay line trued up first (pay must not move after).
select finalise_pay_true_up('10ad0000-0000-0000-0000-00000000c004');
update class_occurrences set attendance_finalised_at = now() where id = '10ad0000-0000-0000-0000-00000000c004';
create temp table _pay as select amount_cents from instructor_pay_records
 where occurrence_id = '10ad0000-0000-0000-0000-00000000c004' and type = 'class';
grant select on _pay to authenticated;

-- (a) the coach marks a booked member attended after the class has started.
reset role; set role authenticated; select set_config('request.jwt.claim.sub','10ad0000-0000-0000-0000-0000000000e1',false);
select expect_eq('coach marks M1 attended',
  (staff_mark_attended('10ad0000-0000-0000-0000-0000000b0101', null) ->> 'from'), 'booked');
-- (b) refused for a member of another coach's class.
select expect_err('coach refused on another coach''s class',
  $$select staff_mark_attended('10ad0000-0000-0000-0000-0000000b0203', null)$$, 'PT403');
reset role;
select expect_eq('M1 attended', (select status::text from bookings where id='10ad0000-0000-0000-0000-0000000b0101'), 'attended');
select expect_eq('M1 check-in written by the coach (method instructor, at class start)',
  (select method::text || '|' || (checked_in_at = (select starts_at from class_occurrences where id='10ad0000-0000-0000-0000-00000000c001'))::text
     from check_ins where booking_id='10ad0000-0000-0000-0000-0000000b0101'), 'instructor|true');
select expect_eq('audit booking.marked_attended for M1',
  (select count(*)::text from audit_logs where entity_id='10ad0000-0000-0000-0000-0000000b0101' and action='booking.marked_attended'), '1');

-- (c) the desk marks another booked member attended.
reset role; set role authenticated; select set_config('request.jwt.claim.sub','10ad0000-0000-0000-0000-0000000000f1',false);
select staff_mark_attended('10ad0000-0000-0000-0000-0000000b0102', null);
select expect_err('desk refused before the class starts',
  $$select staff_mark_attended('10ad0000-0000-0000-0000-0000000b0301', null)$$, 'PT409');
-- mark_present is the same path (desk, a no-show on an unfinalised class).
select (mark_present('10ad0000-0000-0000-0000-0000000b0107') ->> 'ok');
-- (d) front desk is refused after finalisation.
select expect_err('front desk refused on a finalised day',
  $$select staff_mark_attended('10ad0000-0000-0000-0000-0000000b0404', 'they were here')$$, 'PT403');
reset role;
select expect_eq('M2 attended by the desk (method staff)',
  (select method::text from check_ins where booking_id='10ad0000-0000-0000-0000-0000000b0102'), 'staff');
select expect_eq('mark_present writes booking.marked_attended',
  (select count(*)::text from audit_logs where entity_id='10ad0000-0000-0000-0000-0000000b0107' and action='booking.marked_attended'), '1');
select expect_eq('mark_present: M7 attended', (select status::text from bookings where id='10ad0000-0000-0000-0000-0000000b0107'), 'attended');

-- (e) a manager after finalisation: reason required, then the full reversal.
reset role; set role authenticated; select set_config('request.jwt.claim.sub','10ad0000-0000-0000-0000-0000000000a1',false);
select expect_err('manager needs a reason on a finalised day',
  $$select staff_mark_attended('10ad0000-0000-0000-0000-0000000b0404', '  ')$$, 'PT400');
select staff_mark_attended('10ad0000-0000-0000-0000-0000000b0404', 'Coach forgot to check her in');
select staff_mark_attended('10ad0000-0000-0000-0000-0000000b0405', 'Was in the room');
select staff_mark_attended('10ad0000-0000-0000-0000-0000000b0406', 'Was in the room');
reset role;
select expect_eq('M4 attended', (select status::text from bookings where id='10ad0000-0000-0000-0000-0000000b0404'), 'attended');
select expect_eq('M4 infraction voided',
  (select status from member_infractions where booking_id='10ad0000-0000-0000-0000-0000000b0404'), 'voided');
select expect_eq('M4 desk-pay strike cleared',
  (select (desk_pay_blocked_at is null)::text from members where id='10ad0000-0000-0000-0000-0000000d0004'), 'true');
select expect_eq('M6 strike stands (another unpaid no-show)',
  (select desk_pay_blocked_reason from members where id='10ad0000-0000-0000-0000-0000000d0006'), 'no_show');
select expect_eq('M5 reservation fee returned as credit',
  (select amount_cents::text from member_credits where booking_id='10ad0000-0000-0000-0000-0000000b0405' and reason='reservation_credit'), '50000');
select expect_eq('pay unchanged after the reversal',
  (select (r.amount_cents = p.amount_cents)::text from instructor_pay_records r, _pay p
    where r.occurrence_id='10ad0000-0000-0000-0000-00000000c004' and r.type='class'), 'true');
select expect_eq('audit reason recorded',
  (select after ->> 'reason' from audit_logs where entity_id='10ad0000-0000-0000-0000-0000000b0404' and action='booking.marked_attended'),
  'Coach forgot to check her in');

-- =============================================================================
-- shared fixtures for sections 2-5
-- =============================================================================
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('10ad0000-0000-0000-0000-0000000001a4','10ad0000-0000-0000-0000-0000000000a0','10ad0000-0000-0000-0000-00000000010c','Room D',10),
  ('10ad0000-0000-0000-0000-0000000001a5','10ad0000-0000-0000-0000-0000000000a0','10ad0000-0000-0000-0000-00000000010c','Room E',10);
insert into instructors (id, studio_id, display_name, status, core_classes_per_week) values
  ('10ad0000-0000-0000-0000-0000000a00f4','10ad0000-0000-0000-0000-0000000000a0','Gus Growth','active', 1),
  ('10ad0000-0000-0000-0000-0000000a00f5','10ad0000-0000-0000-0000-0000000000a0','Hal Heavy','active', 3);

-- =============================================================================
-- 2. Decision 21 (d): tier changes from a date
-- =============================================================================
-- T: daily 07:00 Room B, Dan, core. T2: daily 06:00 Room C, Eve, core.
insert into class_series (id, studio_id, location_id, class_type_id, name, room_id, instructor_id, capacity,
                          duration_minutes, rrule, starts_on, time_of_day, guarantee_tier) values
  ('10ad0000-0000-0000-0000-00000000f001','10ad0000-0000-0000-0000-0000000000a0','10ad0000-0000-0000-0000-00000000010c',
   '10ad0000-0000-0000-0000-0000000cc001','Tier daily','10ad0000-0000-0000-0000-0000000001a2','10ad0000-0000-0000-0000-0000000a00d2',
   10, 50, 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR,SA,SU', current_date + 1, '07:00', 'core'),
  ('10ad0000-0000-0000-0000-00000000f002','10ad0000-0000-0000-0000-0000000000a0','10ad0000-0000-0000-0000-00000000010c',
   '10ad0000-0000-0000-0000-0000000cc001','Tier bulk','10ad0000-0000-0000-0000-0000000001a3','10ad0000-0000-0000-0000-0000000a00e3',
   10, 50, 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR,SA,SU', current_date + 1, '06:00', 'core');
-- a committed class later on, and a per-day pin later on.
update class_occurrences set committed_at = now()
 where series_id = '10ad0000-0000-0000-0000-00000000f001' and starts_at::date = current_date + 12;
update class_occurrences set guarantee_tier = 'core'
 where series_id = '10ad0000-0000-0000-0000-00000000f001' and starts_at::date = current_date + 15;

reset role; set role authenticated; select set_config('request.jwt.claim.sub','10ad0000-0000-0000-0000-0000000000a1',false);
select set_series_guarantee('10ad0000-0000-0000-0000-00000000f001', 'flex', 2, null, current_date + 10);
select bulk_update_series(array['10ad0000-0000-0000-0000-00000000f002']::uuid[], '{"tier":"flex","minimum":2}'::jsonb, false, current_date + 5);
reset role;
select expect_eq('single: every class before the date pinned core',
  (select count(*) filter (where guarantee_tier = 'core' and not flex)::text || '/' || count(*)::text
     from class_occurrences where series_id='10ad0000-0000-0000-0000-00000000f001'
      and starts_at::date < current_date + 10 and status = 'scheduled'), '9/9');
select expect_eq('single: classes from the date are flex',
  (select bool_and(guarantee_tier = 'flex' and flex)::text from class_occurrences
    where series_id='10ad0000-0000-0000-0000-00000000f001' and starts_at::date >= current_date + 10
      and committed_at is null and status = 'scheduled'), 'true');
select expect_eq('single: the later per-day pin is replaced by the new tier',
  (select guarantee_tier::text from class_occurrences
    where series_id='10ad0000-0000-0000-0000-00000000f001' and starts_at::date = current_date + 15), 'flex');
select expect_eq('single: the committed class is untouched',
  (select coalesce(guarantee_tier::text,'null') || '|' || flex::text from class_occurrences
    where series_id='10ad0000-0000-0000-0000-00000000f001' and starts_at::date = current_date + 12), 'null|false');
select expect_eq('single: series reads flex from the date',
  (select guarantee_tier::text || ' from ' || (tier_from - current_date)::text from class_series where id='10ad0000-0000-0000-0000-00000000f001'),
  'flex from 10');
select expect_eq('bulk: earlier classes pinned core',
  (select count(*) filter (where guarantee_tier='core')::text || '/' || count(*)::text from class_occurrences
    where series_id='10ad0000-0000-0000-0000-00000000f002' and starts_at::date < current_date + 5), '4/4');
select expect_eq('bulk: classes from the date are flex',
  (select bool_and(flex)::text from class_occurrences
    where series_id='10ad0000-0000-0000-0000-00000000f002' and starts_at::date >= current_date + 5), 'true');

-- =============================================================================
-- 3. Decision 19: the filler keeps a coach's hours together
-- =============================================================================
-- F1 Room C: A 09:00 (Eve) then B 10:00 open -> Eve, "continues their block",
--   though Cora has fewer classes that week.
-- F2 Room D: one open class, no neighbour -> the fewest-classes rule (Cora).
-- F3 Room E: two open classes back to back -> the second follows the run's own
--   pick for the first (the preview tracks its picks in memory).
insert into class_occurrences (id, studio_id, location_id, class_type_id, instructor_id, room_id, name,
         starts_at, ends_at, capacity, status) values
  ('10ad0000-0000-0000-0000-00000000fa01','10ad0000-0000-0000-0000-0000000000a0','10ad0000-0000-0000-0000-00000000010c','10ad0000-0000-0000-0000-0000000cc001',
   '10ad0000-0000-0000-0000-0000000a00e3','10ad0000-0000-0000-0000-0000000001a3','Fill A', (current_date+20)+time '09:00', (current_date+20)+time '09:50', 10, 'scheduled'),
  ('10ad0000-0000-0000-0000-00000000fa02','10ad0000-0000-0000-0000-0000000000a0','10ad0000-0000-0000-0000-00000000010c','10ad0000-0000-0000-0000-0000000cc001',
   null,'10ad0000-0000-0000-0000-0000000001a3','Fill B', (current_date+20)+time '10:00', (current_date+20)+time '10:50', 10, 'scheduled'),
  ('10ad0000-0000-0000-0000-00000000fa03','10ad0000-0000-0000-0000-0000000000a0','10ad0000-0000-0000-0000-00000000010c','10ad0000-0000-0000-0000-0000000cc001',
   null,'10ad0000-0000-0000-0000-0000000001a4','Fill C', (current_date+21)+time '09:00', (current_date+21)+time '09:50', 10, 'scheduled'),
  ('10ad0000-0000-0000-0000-00000000fa04','10ad0000-0000-0000-0000-0000000000a0','10ad0000-0000-0000-0000-00000000010c','10ad0000-0000-0000-0000-0000000cc001',
   null,'10ad0000-0000-0000-0000-0000000001a5','Fill D1', (current_date+22)+time '10:00', (current_date+22)+time '10:50', 10, 'scheduled'),
  ('10ad0000-0000-0000-0000-00000000fa05','10ad0000-0000-0000-0000-0000000000a0','10ad0000-0000-0000-0000-00000000010c','10ad0000-0000-0000-0000-0000000cc001',
   null,'10ad0000-0000-0000-0000-0000000001a5','Fill D2', (current_date+22)+time '11:00', (current_date+22)+time '11:50', 10, 'scheduled');
create temp table _fill as
  select d from jsonb_array_elements(assign_instructors_run('10ad0000-0000-0000-0000-0000000000a0', current_date+20, current_date+22, true) -> 'detail') d;
select expect_eq('filler: B goes to the coach before it in the room (Eve)',
  (select d ->> 'instructor' from _fill where d ->> 'class' = 'Fill B'), 'Eve Third');
select expect_eq('filler: B reason reads "continues their block"',
  (select d ->> 'why' from _fill where d ->> 'class' = 'Fill B'), 'continues their block');
select expect_eq('filler: no neighbour -> fewest classes that week (Cora)',
  (select (d ->> 'instructor') || '|' || ((d ->> 'why') like '%fewest of the candidates') from _fill where d ->> 'class' = 'Fill C'),
  'Cora Coach|true');
select expect_eq('filler: D2 follows the run''s own pick for D1',
  (select (a.d ->> 'instructor' = b.d ->> 'instructor')::text || '|' || (b.d ->> 'why')
     from _fill a, _fill b where a.d ->> 'class' = 'Fill D1' and b.d ->> 'class' = 'Fill D2'),
  'true|continues their block');
select expect_eq('filler: the dry run wrote nothing',
  (select count(*)::text from class_occurrences where id in ('10ad0000-0000-0000-0000-00000000fa02','10ad0000-0000-0000-0000-00000000fa05') and instructor_id is not null), '0');

-- =============================================================================
-- 4. Series end-date fix: an end-date-only change touches nothing else.
-- =============================================================================
-- E: Wednesdays 07:00 Room D (Reform's REFORMER BURN shape). The second
-- Wednesday is moved to 18:00 by staff (Reform's Wed 25 Nov 18:00 stray).
insert into class_series (id, studio_id, location_id, class_type_id, name, room_id, capacity,
                          duration_minutes, rrule, starts_on, time_of_day) values
  ('10ad0000-0000-0000-0000-00000000e001','10ad0000-0000-0000-0000-0000000000a0','10ad0000-0000-0000-0000-00000000010c',
   '10ad0000-0000-0000-0000-0000000cc001','End date','10ad0000-0000-0000-0000-0000000001a4', 10, 50,
   'FREQ=WEEKLY;BYDAY=WE', current_date + 1, '07:00');
create temp table _wed as
  select id, row_number() over (order by starts_at) as n, starts_at::date as d
    from class_occurrences where series_id = '10ad0000-0000-0000-0000-00000000e001';
grant select on _wed to authenticated;
update class_occurrences set starts_at = starts_at + interval '11 hours', ends_at = ends_at + interval '11 hours'
 where id = (select id from _wed where n = 2);
-- a member on the 6th Wednesday, after the new end: the change is refused.
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at)
values ('10ad0000-0000-0000-0000-0000000be006','10ad0000-0000-0000-0000-0000000000a0',(select id from _wed where n = 6),
        '10ad0000-0000-0000-0000-0000000d0009','booked','member','drop_in', now());
update class_occurrences set booked_count = 1 where id = (select id from _wed where n = 6);

reset role; set role authenticated; select set_config('request.jwt.claim.sub','10ad0000-0000-0000-0000-0000000000a1',false);
create or replace function pg_temp.end_to(p date) returns jsonb language sql as $$
  select update_series(s.id, s.name, s.class_type_id, s.room_id, s.instructor_id, s.capacity, s.duration_minutes,
                       s.rrule, s.starts_on, p, s.time_of_day, s.description, null, true)
    from class_series s where s.id = '10ad0000-0000-0000-0000-00000000e001' $$;
select expect_eq('end date: refused over a booked later class',
  (pg_temp.end_to((select d from _wed where n = 4)) ->> 'reason'), 'members_booked_on_dropped_classes');
reset role;
update bookings set status = 'cancelled' where id = '10ad0000-0000-0000-0000-0000000be006';
update class_occurrences set booked_count = 0 where id = (select id from _wed where n = 6);
reset role; set role authenticated; select set_config('request.jwt.claim.sub','10ad0000-0000-0000-0000-0000000000a1',false);
select expect_eq('end date: an end-date-only change takes the narrow path',
  (pg_temp.end_to((select d from _wed where n = 4)) ->> 'end_date_only'), 'true');
reset role;
select expect_eq('end date: the classes after the end are cancelled',
  (select bool_and(o.status = 'cancelled')::text from class_occurrences o join _wed w on w.id = o.id where w.n > 4), 'true');
select expect_eq('end date: the classes up to the end stand',
  (select count(*)::text from class_occurrences o join _wed w on w.id = o.id where w.n <= 4 and o.status = 'scheduled'), '4');
select expect_eq('end date: the moved class stays where staff put it (18:00)',
  (select to_char(o.starts_at, 'HH24:MI') from class_occurrences o join _wed w on w.id = o.id where w.n = 2), '18:00');
select expect_eq('end date: the series end is set',
  (select (ends_on = (select d from _wed where n = 4))::text from class_series where id = '10ad0000-0000-0000-0000-00000000e001'), 'true');

-- =============================================================================
-- 5. Decision 106 (a): the weekly core budget informs, it does not block.
-- =============================================================================
-- Gus (budget 1): G1 Mon 12:00 core, G2 Tue 12:00 flex -> G2 qualifies and is
-- proposed core though it takes Gus to 2 (over_budget, would_hold 2).
-- Hal (budget 3): H1-H3 Wed 13/14/15 flex -> all three proposed core, none over.
create or replace function pg_temp.mk_series(p_id uuid, p_instr uuid, p_byday text, p_dow int, p_time time, p_tier text)
returns void language plpgsql as $$
declare v_week date := date_trunc('week', current_date)::date + 7; k int; v_occ uuid; m int;
begin
  insert into class_series (id, studio_id, location_id, class_type_id, name, instructor_id, capacity,
                            duration_minutes, rrule, starts_on, time_of_day, guarantee_tier, flex, minimum_bookings)
  values (p_id, '10ad0000-0000-0000-0000-0000000000a0', '10ad0000-0000-0000-0000-00000000010c',
          '10ad0000-0000-0000-0000-0000000cc001', 'Grow '||p_byday||' '||p_time, p_instr, 10, 50,
          'FREQ=WEEKLY;BYDAY='||p_byday, current_date + 1, p_time, p_tier::guarantee_tier, p_tier = 'flex',
          case when p_tier = 'flex' then 2 end);
  for k in 2..5 loop
    v_occ := gen_random_uuid();
    insert into class_occurrences (id, studio_id, location_id, class_type_id, instructor_id, series_id, name,
                                   starts_at, ends_at, capacity, status)
    values (v_occ, '10ad0000-0000-0000-0000-0000000000a0', '10ad0000-0000-0000-0000-00000000010c',
            '10ad0000-0000-0000-0000-0000000cc001', p_instr, p_id, 'Grow',
            (v_week - 7*k + (p_dow - 1)) + p_time, (v_week - 7*k + (p_dow - 1)) + p_time + interval '50 min', 10, 'scheduled');
    for m in 10..12 loop
      insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source, booked_at)
      values ('10ad0000-0000-0000-0000-0000000000a0', v_occ, ('10ad0000-0000-0000-0000-0000000d00'||m)::uuid,
              'attended', 'member', 'drop_in', now() - interval '60 days');
    end loop;
  end loop;
end $$;
select pg_temp.mk_series('10ad0000-0000-0000-0000-00000000a6f1','10ad0000-0000-0000-0000-0000000a00f4','MO',1,'12:00','core');
select pg_temp.mk_series('10ad0000-0000-0000-0000-00000000a6f2','10ad0000-0000-0000-0000-0000000a00f4','TU',2,'12:00','flex');
select pg_temp.mk_series('10ad0000-0000-0000-0000-00000000a6f3','10ad0000-0000-0000-0000-0000000a00f5','WE',3,'13:00','flex');
select pg_temp.mk_series('10ad0000-0000-0000-0000-00000000a6f4','10ad0000-0000-0000-0000-0000000a00f5','WE',3,'14:00','flex');
select pg_temp.mk_series('10ad0000-0000-0000-0000-00000000a6f5','10ad0000-0000-0000-0000-0000000a00f5','WE',3,'15:00','flex');

create temp table _gi as
  select s from jsonb_array_elements(growth_insights('10ad0000-0000-0000-0000-0000000000a0', date_trunc('week', current_date)::date + 7) -> 'coaches') c,
                jsonb_array_elements(c -> 'days') d, jsonb_array_elements(d -> 'slots') s;
select expect_eq('growth: Gus''s Tuesday is still proposed core, flagged over budget',
  (select (s ->> 'action') || '|' || (s ->> 'over_budget') || '|' || (s ->> 'would_hold') from _gi
    where s ->> 'series_id' = '10ad0000-0000-0000-0000-00000000a6f2'), 'make_core|true|2');
select expect_eq('growth: the suggestion line names the streak',
  (select s ->> 'line' from _gi where s ->> 'series_id' = '10ad0000-0000-0000-0000-00000000a6f2'),
  'Reached 2 of 2 four weeks running. Make it core?');
select expect_eq('growth: three cores on one day under a weekly cap of 3, none over',
  (select count(*) filter (where s ->> 'action' = 'make_core')::text || '|' || bool_or((s ->> 'over_budget')::boolean)::text
     from _gi where s ->> 'series_id' in ('10ad0000-0000-0000-0000-00000000a6f3','10ad0000-0000-0000-0000-00000000a6f4','10ad0000-0000-0000-0000-00000000a6f5')),
  '3|false');

-- the Schedule flag, from the stored weekly review.
select sweep_growth_insights('10ad0000-0000-0000-0000-0000000000a0', date_trunc('week', current_date)::date + 7);
reset role; set role authenticated; select set_config('request.jwt.claim.sub','10ad0000-0000-0000-0000-0000000000a1',false);
select expect_eq('schedule_range flags G2 next week',
  (select bool_or(has_growth_suggestion)::text from schedule_range('10ad0000-0000-0000-0000-0000000000a0',
     date_trunc('week', current_date)::date + 7, date_trunc('week', current_date)::date + 13) r
    join class_occurrences o on o.id = r.occ_id where o.series_id = '10ad0000-0000-0000-0000-00000000a6f2'), 'true');
select expect_eq('schedule_range does not flag G1 (already core)',
  (select bool_or(has_growth_suggestion)::text from schedule_range('10ad0000-0000-0000-0000-0000000000a0',
     date_trunc('week', current_date)::date + 7, date_trunc('week', current_date)::date + 13) r
    join class_occurrences o on o.id = r.occ_id where o.series_id = '10ad0000-0000-0000-0000-00000000a6f1'), 'false');

-- dismiss hides H1 for four weeks (flagged first, so the next check has teeth).
select expect_eq('H1 is flagged before the dismissal',
  (select bool_or(has_growth_suggestion)::text from schedule_range('10ad0000-0000-0000-0000-0000000000a0',
     date_trunc('week', current_date)::date + 7, date_trunc('week', current_date)::date + 13) r
    join class_occurrences o on o.id = r.occ_id where o.series_id = '10ad0000-0000-0000-0000-00000000a6f3'), 'true');
select growth_dismiss((select id from class_occurrences where series_id='10ad0000-0000-0000-0000-00000000a6f3'
                        and starts_at::date >= date_trunc('week', current_date)::date + 7 order by starts_at limit 1));
select expect_eq('dismissed H1 is no longer flagged',
  (select bool_or(has_growth_suggestion)::text from schedule_range('10ad0000-0000-0000-0000-0000000000a0',
     date_trunc('week', current_date)::date + 7, date_trunc('week', current_date)::date + 13) r
    join class_occurrences o on o.id = r.occ_id where o.series_id = '10ad0000-0000-0000-0000-00000000a6f3'), 'false');

-- Make core and raise budget: Gus to the core count he now holds this week.
select growth_apply((select id from class_occurrences where series_id='10ad0000-0000-0000-0000-00000000a6f2'
                      and starts_at::date >= date_trunc('week', current_date)::date + 7 order by starts_at limit 1),
                    'core', 'series', true);
reset role;
select expect_eq('dismissal lasts four weeks',
  (select (expires_on - current_date)::text from growth_dismissals where series_id='10ad0000-0000-0000-0000-00000000a6f3'), '28');
select expect_eq('growth_apply raised Gus''s budget to 2',
  (select core_classes_per_week::text from instructors where id='10ad0000-0000-0000-0000-0000000a00f4'), '2');
select expect_eq('budget raise audited',
  (select count(*)::text from audit_logs where entity_id='10ad0000-0000-0000-0000-0000000a00f4' and action='instructor.core_budget_raised'), '1');
reset role; set role authenticated; select set_config('request.jwt.claim.sub','10ad0000-0000-0000-0000-0000000000f1',false);
select expect_err('front desk refused growth_dismiss',
  $$select growth_dismiss((select id from class_occurrences where series_id='10ad0000-0000-0000-0000-00000000a6f4' limit 1))$$, 'PT403');
select expect_eq('front desk cannot read growth_dismissals', (select count(*)::text from growth_dismissals), '0');
reset role;

-- =============================================================================
-- 6. Surface
-- =============================================================================
select expect_eq('anon surface EXACTLY FIFTEEN',
  (select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not in ('expect_eq','expect_err')), '15');
select expect_eq('growth_dismissals closed to anon', has_table_privilege('anon','growth_dismissals','select')::text, 'false');
select expect_eq('staff_mark_attended / growth_dismiss not anon',
  (has_function_privilege('anon','staff_mark_attended(uuid,text)','execute')
   or has_function_privilege('anon','growth_dismiss(uuid)','execute'))::text, 'false');
select expect_eq('core_classes_per_week range is 1 to 21',
  (select pg_get_constraintdef(oid) like '%21%' from pg_constraint where conname = 'instructors_core_classes_per_week_check')::text, 'true');

do $$ begin raise notice 'step10_test: all assertions passed'; end $$;
