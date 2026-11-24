-- =============================================================================
-- Step 13a — Decision 75 (l) pay timing table, 31 (a), 21 (f), 35 (b), 108 (b).
-- =============================================================================
-- UUID space 13a0, checked free. Run after `supabase db reset`.
--
-- One test per row of 75 (l) (rate card: ₱900 base, ₱75 per head above 2, a
-- ₱1,400 full-house TOTAL, ₱400 core holding fee, capacity 6), plus the 21 (f)
-- latch, staff_mark_no_show, and daily_money_check with a member-less payment.
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

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('13a00000-0000-0000-0000-0000000000a1'),   -- owner
  ('13a00000-0000-0000-0000-0000000000f1'),   -- front desk
  ('13a00000-0000-0000-0000-0000000000e1'),   -- coach Cora (login)
  ('13a00000-0000-0000-0000-0000000000e2'),   -- coach Ivy (login, another coach)
  ('13a00000-0000-0000-0000-0000000000b1');   -- a member login
insert into profiles (id, email, full_name) values
  ('13a00000-0000-0000-0000-0000000000a1','13a0-owner@example.com','Olive Owner'),
  ('13a00000-0000-0000-0000-0000000000f1','13a0-desk@example.com','Dee Desk'),
  ('13a00000-0000-0000-0000-0000000000e1','13a0-coach@example.com','Cora Coach'),
  ('13a00000-0000-0000-0000-0000000000e2','13a0-ivy@example.com','Ivy Other'),
  ('13a00000-0000-0000-0000-0000000000b1','13a0-member@example.com','Mia Member');

insert into studios (id, name, slug, timezone, currency, status) values
  ('13a00000-0000-0000-0000-0000000000a0','Timing','13a0-s','UTC','PHP','active');
insert into studio_settings (studio_id, guarantees_enabled, flex_enabled, flex_min_bookings, core_min_bookings,
       core_unmet_pay_cents, finalise_attendance, finalise_days_after, checkin_window_enforced,
       pay_period_mode, pay_period_second_day, conversion_bonus_enabled, conversion_bonus_cents, conversion_window_days)
values ('13a00000-0000-0000-0000-0000000000a0', true, true, 2, 1, 40000, true, 1, false,
        'semimonthly', 16, true, 50000, 30);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('13a00000-0000-0000-0000-0000000005a1','13a00000-0000-0000-0000-0000000000a0','13a00000-0000-0000-0000-0000000000a1','13a0-owner@example.com','owner'),
  ('13a00000-0000-0000-0000-0000000005f1','13a00000-0000-0000-0000-0000000000a0','13a00000-0000-0000-0000-0000000000f1','13a0-desk@example.com','front_desk'),
  ('13a00000-0000-0000-0000-0000000005e1','13a00000-0000-0000-0000-0000000000a0','13a00000-0000-0000-0000-0000000000e1','13a0-coach@example.com','instructor'),
  ('13a00000-0000-0000-0000-0000000005e2','13a00000-0000-0000-0000-0000000000a0','13a00000-0000-0000-0000-0000000000e2','13a0-ivy@example.com','instructor');
insert into locations (id, studio_id, name, is_primary) values
  ('13a00000-0000-0000-0000-00000000010c','13a00000-0000-0000-0000-0000000000a0','Main', true);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity, session_kind) values
  ('13a00000-0000-0000-0000-0000000cc001','13a00000-0000-0000-0000-0000000000a0','Reformer',50,6,'group');
insert into instructors (id, studio_id, display_name, status, staff_id) values
  ('13a00000-0000-0000-0000-0000000a00c1','13a00000-0000-0000-0000-0000000000a0','Cora Coach','active','13a00000-0000-0000-0000-0000000005e1'),
  ('13a00000-0000-0000-0000-0000000a00c2','13a00000-0000-0000-0000-0000000000a0','Ivy Other','active','13a00000-0000-0000-0000-0000000005e2');
-- An old card with the ₱200 bonus-on-top (the 25 Nov shape), then a new card
-- with no total given: the carry-forward trigger must NOT invent one here, so
-- the 13a card is written with the total explicitly.
insert into instructor_rate_versions (studio_id, instructor_id, effective_from, currency,
         base_rate_cents, per_head_rate_cents, per_head_threshold, full_house_bonus_cents,
         private_rate_cents, duo_rate_cents, trio_rate_cents, full_house_total_cents) values
  ('13a00000-0000-0000-0000-0000000000a0','13a00000-0000-0000-0000-0000000a00c1', current_date - 90, 'PHP', 90000, 7500, 2, 0, 100000, 140000, 160000, 140000),
  ('13a00000-0000-0000-0000-0000000000a0','13a00000-0000-0000-0000-0000000a00c2', current_date - 90, 'PHP', 90000, 7500, 2, 0, 100000, 140000, 160000, 140000);

insert into members (id, studio_id, first_name, last_name, email, status, waiver_signed_at, user_id)
select ('13a00000-0000-0000-0000-0000000d00'||lpad(n::text,2,'0'))::uuid, '13a00000-0000-0000-0000-0000000000a0',
       'M'||n, 'N', '13a0-'||n||'@example.com', 'active', now(),
       case when n = 1 then '13a00000-0000-0000-0000-0000000000b1'::uuid end
  from generate_series(1,12) n;

-- Occurrence builder: k staggers the start so no coach or room overlaps.
create or replace function t_occ(p_k int, p_start timestamptz, p_tier text, p_status text,
                                 p_committed boolean, p_cutoff int, p_cause text default null,
                                 p_coach uuid default '13a00000-0000-0000-0000-0000000a00c1')
returns uuid language plpgsql as $$
declare v_id uuid := ('13a00000-0000-0000-0000-00000000c'||lpad(p_k::text,3,'0'))::uuid;
begin
  insert into class_occurrences (id, studio_id, location_id, class_type_id, instructor_id, name,
         starts_at, ends_at, capacity, booked_count, status, committed_at, booked_at_cutoff,
         guarantee_tier, flex, minimum_bookings, cancellation_cause, cancelled_at)
  values (v_id, '13a00000-0000-0000-0000-0000000000a0', '13a00000-0000-0000-0000-00000000010c',
          '13a00000-0000-0000-0000-0000000cc001', p_coach, 'T'||p_k,
          p_start, p_start + interval '50 min', 6, coalesce(p_cutoff, 0),
          p_status::occurrence_status, case when p_committed then p_start - interval '12 hours' end, p_cutoff,
          p_tier::guarantee_tier, p_tier = 'flex', case when p_tier = 'flex' then 2 end,
          p_cause::cancellation_cause, case when p_status = 'cancelled' then p_start - interval '12 hours' end);
  return v_id;
end $$;
create or replace function t_seat(p_occ uuid, p_member int, p_status text, p_source text default 'membership',
                                  p_provisional boolean default false)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source, booked_at, provisional)
  values ('13a00000-0000-0000-0000-0000000000a0', p_occ,
          ('13a00000-0000-0000-0000-0000000d00'||lpad(p_member::text,2,'0'))::uuid,
          p_status::booking_status, 'member', p_source::payment_source, now() - interval '4 days', p_provisional)
  returning id into v_id;
  return v_id;
end $$;
create or replace function t_pay(p_occ uuid) returns text language sql stable as $$
  select (compute_class_pay_run(p_occ) ->> 'amount_cents'); $$;
create or replace function rec_amt(p_occ uuid) returns text language sql stable as $$
  select amount_cents::text from instructor_pay_records where occurrence_id = p_occ and type = 'class'; $$;
-- past classes: k hours apart, three days ago
create or replace function t_past(p_k int) returns timestamptz language sql stable as $$
  select date_trunc('hour', now()) - interval '3 days' - make_interval(hours => p_k); $$;

-- --- 75 (l) rows --------------------------------------------------------------
-- Did not run.
select t_occ(1, t_past(1), 'core', 'cancelled', false, 0, 'unmet_minimum');
select expect_eq('core with nobody booked at the cut-off pays the ₱400 holding fee',
  t_pay('13a00000-0000-0000-0000-00000000c001'), '40000');
select t_occ(2, t_past(2), 'flex', 'cancelled', false, 1, 'unmet_minimum');
select expect_eq('flex under its minimum at the flex cut-off pays ₱0',
  t_pay('13a00000-0000-0000-0000-00000000c002'), '0');

-- 1 to 5 heads (all checked in) on a committed core class.
do $$
declare k int; n int; o uuid;
begin
  for n in 1..5 loop
    k := 2 + n;
    o := t_occ(k, t_past(k), 'core', 'scheduled', true, n);
    for i in 1..n loop perform t_seat(o, i, 'attended'); end loop;
  end loop;
end $$;
select expect_eq('1 head pays ₱900',   t_pay('13a00000-0000-0000-0000-00000000c003'), '90000');
select expect_eq('2 heads pay ₱900',   t_pay('13a00000-0000-0000-0000-00000000c004'), '90000');
select expect_eq('3 heads pay ₱975',   t_pay('13a00000-0000-0000-0000-00000000c005'), '97500');
select expect_eq('4 heads pay ₱1,050', t_pay('13a00000-0000-0000-0000-00000000c006'), '105000');
select expect_eq('5 heads pay ₱1,125', t_pay('13a00000-0000-0000-0000-00000000c007'), '112500');

-- Full house: 5 at the cut-off + 1 walk-in = 6 = ₱1,400 TOTAL (not 900+300+bonus).
do $$
declare o uuid := t_occ(8, t_past(8), 'core', 'scheduled', true, 5);
begin
  for i in 1..6 loop perform t_seat(o, i, 'attended'); end loop;
end $$;
select expect_eq('full house of 6 (5 at the cut-off + 1 walk-in) pays a ₱1,400 total',
  t_pay('13a00000-0000-0000-0000-00000000c008'), '140000');
select expect_eq('the basis records the full house and its total',
  (compute_class_pay_run('13a00000-0000-0000-0000-00000000c008') -> 'basis' ->> 'full_house_total_cents'), '140000');

-- Late cancel and no-show keep pay.
do $$
declare o uuid := t_occ(9, t_past(9), 'core', 'scheduled', true, 3);
begin
  perform t_seat(o, 1, 'attended'); perform t_seat(o, 2, 'no_show'); perform t_seat(o, 3, 'late_cancelled');
end $$;
select expect_eq('a late cancel and a no-show keep their heads (3 heads ₱975)',
  t_pay('13a00000-0000-0000-0000-00000000c009'), '97500');

-- A post-cut-off joiner adds a head.
do $$
declare o uuid := t_occ(10, t_past(10), 'core', 'scheduled', true, 2);
begin
  perform t_seat(o, 1, 'attended'); perform t_seat(o, 2, 'attended'); perform t_seat(o, 3, 'attended');
end $$;
select expect_eq('a joiner after the cut-off adds a head (2 at cut-off, 3 used: ₱975)',
  t_pay('13a00000-0000-0000-0000-00000000c010'), '97500');

-- A system-released hold and a released provisional free seat do not.
do $$
declare o uuid := t_occ(11, t_past(11), 'core', 'scheduled', true, 2);
begin
  perform t_seat(o, 1, 'attended'); perform t_seat(o, 2, 'attended');
  perform t_seat(o, 3, 'cancelled', 'comp', true);      -- provisional free seat, released
  perform t_seat(o, 4, 'pending_payment', 'comp');       -- an unpaid hold
end $$;
select expect_eq('a released provisional seat and an unpaid hold add no heads (₱900)',
  t_pay('13a00000-0000-0000-0000-00000000c011'), '90000');

-- Core confirmed, then everyone late-cancels: keeps the cut-off pay.
do $$
declare o uuid := t_occ(12, t_past(12), 'core', 'scheduled', true, 3);
begin
  perform t_seat(o, 1, 'late_cancelled'); perform t_seat(o, 2, 'late_cancelled'); perform t_seat(o, 3, 'late_cancelled');
end $$;
select expect_eq('core confirmed then everyone late-cancels keeps the cut-off pay (₱975)',
  t_pay('13a00000-0000-0000-0000-00000000c012'), '97500');

-- Studio cancellation: core ₱900, flex ₱0. Force majeure ₱0.
select t_occ(13, t_past(13), 'core', 'cancelled', false, 2, 'studio_fault');
select expect_eq('a studio cancellation pays core its ₱900 base',
  t_pay('13a00000-0000-0000-0000-00000000c013'), '90000');
select t_occ(14, t_past(14), 'flex', 'cancelled', false, 2, 'studio_fault');
select expect_eq('a studio cancellation pays flex ₱0',
  t_pay('13a00000-0000-0000-0000-00000000c014'), '0');
select t_occ(15, t_past(15), 'core', 'cancelled', true, 5, 'studio_fault');
select expect_eq('a committed core class the studio cancels still pays ₱900 (not the ran amount)',
  t_pay('13a00000-0000-0000-0000-00000000c015'), '90000');
select t_occ(16, t_past(16), 'core', 'cancelled', false, 3, 'force_majeure');
select expect_eq('typhoon or government suspension pays ₱0',
  t_pay('13a00000-0000-0000-0000-00000000c016'), '0');

-- Instructor no-show: the line stays held (not payable) until released.
select expect_eq('a class that ran with no instructor check-in is written held',
  (select (confirmed_at is null)::text from instructor_pay_records
    where occurrence_id = '13a00000-0000-0000-0000-00000000c003' and type = 'class'), 'true');

-- Privates: the session type's rate.
insert into private_session_types (id, studio_id, name, people, duration_min, price_cents, coach_pay_cents, active)
values ('13a00000-0000-0000-0000-0000000ff002','13a00000-0000-0000-0000-0000000000a0','Duo',2,50,300000,140000,true);
insert into class_occurrences (id, studio_id, location_id, class_type_id, instructor_id, name,
       starts_at, ends_at, capacity, status, is_private, private_type_id, hidden_from_members, committed_at)
values ('13a00000-0000-0000-0000-00000000c017','13a00000-0000-0000-0000-0000000000a0','13a00000-0000-0000-0000-00000000010c',
        '13a00000-0000-0000-0000-0000000cc001','13a00000-0000-0000-0000-0000000a00c2','Duo',
        t_past(17), t_past(17) + interval '50 min', 2, 'scheduled', true,
        '13a00000-0000-0000-0000-0000000ff002', true, t_past(17) - interval '1 day');
select expect_eq('a duo pays its session type rate (₱1,400)', t_pay('13a00000-0000-0000-0000-00000000c017'), '140000');

-- --- 21 (f)(4): always-runs is committed at its start -------------------------
do $$
declare o1 uuid; o2 uuid;
begin
  o1 := t_occ(20, now() - interval '20 min', 'always', 'scheduled', false, null,
              null, '13a00000-0000-0000-0000-0000000a00c2');
  perform t_seat(o1, 1, 'booked'); perform t_seat(o1, 2, 'booked');
  update class_occurrences set booked_count = 2 where id = o1;
  o2 := t_occ(21, now() - interval '3 hours', 'always', 'scheduled', false, null,
              null, '13a00000-0000-0000-0000-0000000a00c2');
end $$;
select expect_eq('the pending selector includes an always-runs class after its start',
  (select count(*)::text from commitment_pending('13a00000-0000-0000-0000-0000000000a0')
    where occ_id in ('13a00000-0000-0000-0000-00000000c020','13a00000-0000-0000-0000-00000000c021') and past_due), '2');
select evaluate_commitment('13a00000-0000-0000-0000-00000000c020');
select evaluate_commitment('13a00000-0000-0000-0000-00000000c021');
select expect_eq('an always-runs class with people gets a pay line (₱900)',
  rec_amt('13a00000-0000-0000-0000-00000000c020'), '90000');
select expect_eq('an always-runs class with nobody pays the ₱400 holding fee',
  rec_amt('13a00000-0000-0000-0000-00000000c021'), '40000');

-- --- 21 (f)(1): the latch follows live paid seats before the cut-off ----------
do $$
declare o uuid := t_occ(30, date_trunc('hour', now()) + interval '4 days', 'flex', 'scheduled', false, null);
begin
  perform t_seat(o, 1, 'booked'); perform t_seat(o, 2, 'booked');
  update class_occurrences set booked_count = 2 where id = o;
end $$;
select expect_eq('a flex class reaching its minimum latches',
  (select (flex_reached_minimum_at is not null)::text from class_occurrences where id = '13a00000-0000-0000-0000-00000000c030'), 'true');
update bookings set status = 'cancelled', cancelled_at = now()
 where occurrence_id = '13a00000-0000-0000-0000-00000000c030'
   and member_id = '13a00000-0000-0000-0000-0000000d0002';
update class_occurrences set booked_count = 1 where id = '13a00000-0000-0000-0000-00000000c030';
select expect_eq('the latch clears the moment paid seats drop below the minimum',
  (select (flex_reached_minimum_at is null)::text from class_occurrences where id = '13a00000-0000-0000-0000-00000000c030'), 'true');
select expect_eq('the member chip reads "Needs 1 more" again (not running)',
  (occurrence_flex_state_run('13a00000-0000-0000-0000-00000000c030') ->> 'reached_minimum'), 'false');

-- --- 21 (f)(2): at the cut-off a stale latch does not commit ------------------
do $$
declare o uuid := t_occ(31, date_trunc('hour', now()) + interval '90 min', 'flex', 'scheduled', false, null);
begin
  perform t_seat(o, 1, 'booked');
  update class_occurrences set booked_count = 1, flex_reached_minimum_at = now() - interval '2 days' where id = o;
end $$;
select evaluate_commitment('13a00000-0000-0000-0000-00000000c031');
select expect_eq('at the cut-off the live paid count decides, not a stale latch (not running)',
  (select status::text || '/' || coalesce(cancellation_cause::text, '-') from class_occurrences
    where id = '13a00000-0000-0000-0000-00000000c031'), 'cancelled/unmet_minimum');

-- --- 21 (f)(3): a confirmed flex class that loses every booking ---------------
do $$
declare o uuid := t_occ(32, date_trunc('hour', now()) + interval '5 days', 'flex', 'scheduled', true, 2);
begin
  perform t_seat(o, 1, 'booked'); perform t_seat(o, 2, 'booked');
  update class_occurrences set booked_count = 2 where id = o;
end $$;
select expect_eq('the confirmed flex class has its ₱900 line',
  rec_amt('13a00000-0000-0000-0000-00000000c032'), '90000');
select cancel_booking(id) from bookings where occurrence_id = '13a00000-0000-0000-0000-00000000c032' and member_id = '13a00000-0000-0000-0000-0000000d0001';
select expect_eq('one live booking left: the class still runs',
  (select status::text from class_occurrences where id = '13a00000-0000-0000-0000-00000000c032'), 'scheduled');
select cancel_booking(id) from bookings where occurrence_id = '13a00000-0000-0000-0000-00000000c032' and member_id = '13a00000-0000-0000-0000-0000000d0002';
select expect_eq('every booking gone: cancelled at once, unmet minimum',
  (select status::text || '/' || cancellation_cause::text || '/' || (committed_at is null)::text
     from class_occurrences where id = '13a00000-0000-0000-0000-00000000c032'), 'cancelled/unmet_minimum/true');
select expect_eq('its pay line becomes ₱0', rec_amt('13a00000-0000-0000-0000-00000000c032'), '0');
select expect_eq('the coach is told once (one cancellation notice)',
  (select count(*)::text from notifications where dedupe_key = 'instructor_class_cancelled:13a00000-0000-0000-0000-00000000c032'), '1');
select expect_eq('it is audited occurrence.flex_emptied',
  (select count(*)::text from audit_logs where action = 'occurrence.flex_emptied'
     and entity_id = '13a00000-0000-0000-0000-00000000c032'), '1');

-- --- 31 (a): a conversion bonus lands in the month-end period -----------------
do $$
declare o uuid := t_occ(40, t_past(40), 'core', 'scheduled', true, 1); b uuid; v_plan uuid := gen_random_uuid();
begin
  b := t_seat(o, 9, 'attended');
  insert into check_ins (studio_id, booking_id, member_id, occurrence_id, method, checked_in_at)
  values ('13a00000-0000-0000-0000-0000000000a0', b, '13a00000-0000-0000-0000-0000000d0009', o, 'staff', t_past(40));
  insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, validity_days, counts_for_conversion, visibility, status)
  values (v_plan, '13a00000-0000-0000-0000-0000000000a0', 'Pack', 'class_pack', 500000, 'PHP', 10, 60, true, 'public', 'active');
  insert into memberships (studio_id, member_id, plan_id, status, starts_on, price_cents, currency, credits_remaining, created_at)
  values ('13a00000-0000-0000-0000-0000000000a0', '13a00000-0000-0000-0000-0000000d0009', v_plan, 'active',
          current_date, 500000, 'PHP', 10, date_trunc('month', now()) + interval '2 days');
end $$;
select expect_eq('a bonus earned early in the month is placed in that month''s 16-to-month-end period',
  (select to_char(p.starts_on, 'DD') || '/' || (p.ends_on = (date_trunc('month', now()) + interval '1 month - 1 day')::date)::text
     from instructor_pay_records r join pay_periods p on p.id = r.period_id
    where r.type = 'conversion' and r.source_id = '13a00000-0000-0000-0000-0000000d0009'), '16/true');

-- --- 35 (b): Mark no-show -----------------------------------------------------
do $$
declare o uuid := t_occ(50, now() - interval '30 min', 'core', 'scheduled', true, 4);
begin
  perform t_seat(o, 1, 'booked'); perform t_seat(o, 2, 'booked', 'drop_in');
  perform t_seat(o, 3, 'attended'); perform t_seat(o, 4, 'booked');
  insert into check_ins (studio_id, booking_id, member_id, occurrence_id, method, checked_in_at)
  select studio_id, id, member_id, occurrence_id, 'staff', now() - interval '25 min' from bookings
   where occurrence_id = o and member_id = '13a00000-0000-0000-0000-0000000d0003';
  perform t_occ(51, now() + interval '3 hours', 'core', 'scheduled', true, 1);
  perform t_seat('13a00000-0000-0000-0000-00000000c051', 5, 'booked');
end $$;
create or replace function t_bk(p_occ int, p_member int) returns uuid language sql stable as $$
  select id from bookings where occurrence_id = ('13a00000-0000-0000-0000-00000000c'||lpad(p_occ::text,3,'0'))::uuid
     and member_id = ('13a00000-0000-0000-0000-0000000d00'||lpad(p_member::text,2,'0'))::uuid; $$;
create table t_ids as select t_bk(50,1) b1, t_bk(50,2) b2, t_bk(50,3) b3, t_bk(50,4) b4, t_bk(51,5) b5;
grant select on t_ids to authenticated;

select set_config('t.n1', (select count(*)::text from notifications where member_id = '13a00000-0000-0000-0000-0000000d0001'), false);
-- a member and another coach are refused.
reset role; set role authenticated; select set_config('request.jwt.claim.sub','13a00000-0000-0000-0000-0000000000b1',false);
select expect_err('a member cannot mark a no-show', 'select staff_mark_no_show((select b1 from t_ids))', 'PT403');
reset role; set role authenticated; select set_config('request.jwt.claim.sub','13a00000-0000-0000-0000-0000000000e2',false);
select expect_err('another coach cannot mark a no-show on Cora''s class', 'select staff_mark_no_show((select b1 from t_ids))', 'PT403');

-- the coach marks it; refusals.
reset role; set role authenticated; select set_config('request.jwt.claim.sub','13a00000-0000-0000-0000-0000000000e1',false);
select staff_mark_no_show((select b1 from t_ids));
select expect_err('a class not started yet is refused', 'select staff_mark_no_show((select b5 from t_ids))', 'PT409');
select expect_err('a checked-in member is refused', 'select staff_mark_no_show((select b3 from t_ids))', 'PT409');
select expect_err('an existing no-show is refused', 'select staff_mark_no_show((select b1 from t_ids))', 'PT409');
reset role;
select expect_eq('the coach''s mark sets no_show with the coach as no_show_by',
  (select status::text || '/' || (no_show_by = '13a00000-0000-0000-0000-0000000000e1')::text from bookings where id = (select b1 from t_ids)),
  'no_show/true');
select expect_eq('audited booking.marked_no_show with the coach''s first name',
  (select after ->> 'staff_first' from audit_logs where action = 'booking.marked_no_show' and entity_id = (select b1 from t_ids)), 'Cora');
select expect_eq('the Journey shows "Marked no-show by Cora" to staff',
  (select title from member_activity('13a00000-0000-0000-0000-0000000d0001', current_date - 30, current_date + 1)
    where kind = 'marked_no_show'), 'Marked no-show by Cora');
select expect_eq('no email goes to the member',
  (select count(*)::text from notifications where member_id = '13a00000-0000-0000-0000-0000000d0001'),
  current_setting('t.n1'));

-- the desk marks the unpaid drop-in: the 73 (c) strike lands as the sweep's would.
reset role; set role authenticated; select set_config('request.jwt.claim.sub','13a00000-0000-0000-0000-0000000000f1',false);
select staff_mark_no_show((select b2 from t_ids));
reset role;
select expect_eq('a no-show on an unpaid desk drop-in sets the desk-pay strike, as the sweep does',
  (select desk_pay_blocked_reason from members where id = '13a00000-0000-0000-0000-0000000d0002'), 'no_show');
select expect_eq('the seat stays a head under 75 (l) (4 at the cut-off still pays ₱1,050)',
  t_pay('13a00000-0000-0000-0000-00000000c050'), '105000');

-- Mark attended reverses a mistaken no-show.
reset role; set role authenticated; select set_config('request.jwt.claim.sub','13a00000-0000-0000-0000-0000000000f1',false);
select staff_mark_attended((select b2 from t_ids));
reset role;
select expect_eq('Mark attended reverses it and clears the strike',
  (select b.status::text || '/' || coalesce(m.desk_pay_blocked_reason, 'clear') from bookings b join members m on m.id = b.member_id
    where b.id = (select b2 from t_ids)), 'attended/clear');

-- after finalisation: desk refused, manager needs a reason.
update class_occurrences set attendance_finalised_at = now() where id = '13a00000-0000-0000-0000-00000000c050';
reset role; set role authenticated; select set_config('request.jwt.claim.sub','13a00000-0000-0000-0000-0000000000f1',false);
select expect_err('after finalisation front desk is refused', 'select staff_mark_no_show((select b4 from t_ids))', 'PT403');
reset role; set role authenticated; select set_config('request.jwt.claim.sub','13a00000-0000-0000-0000-0000000000a1',false);
select expect_err('after finalisation a manager must give a reason', 'select staff_mark_no_show((select b4 from t_ids))', 'PT400');
select staff_mark_no_show((select b4 from t_ids), 'Phoned to say she was not coming');
reset role;
select expect_eq('a manager with a reason marks it after finalisation',
  (select status::text from bookings where id = (select b4 from t_ids)), 'no_show');

-- the sweep uses the same body: no_show_by stays null for the sweep.
do $$
declare o uuid := t_occ(52, t_past(52), 'core', 'scheduled', true, 1);
begin
  perform t_seat(o, 6, 'booked', 'drop_in');
end $$;
select finalise_attendance_sweep();
select expect_eq('the finalisation sweep marks the same no-show (no_show_by null) and the same strike',
  (select b.status::text || '/' || (b.no_show_by is null)::text || '/' || coalesce(m.desk_pay_blocked_reason, 'clear')
     from bookings b join members m on m.id = b.member_id
    where b.occurrence_id = '13a00000-0000-0000-0000-00000000c052'), 'no_show/true/no_show');

-- --- 108 (b): the daily check ---------------------------------------------------
insert into payments (studio_id, member_id, amount_cents, currency, status, provider, paid_at)
values ('13a00000-0000-0000-0000-0000000000a0', null, 100000, 'PHP', 'succeeded', 'manual', now());
select expect_eq('a member-less payment (a gift card) does not wipe the list: items still come back',
  ((daily_money_check('13a00000-0000-0000-0000-0000000000a0') ->> 'n')::int > 0)::text, 'true');
select expect_eq('and it is not listed as attached to nothing',
  (select count(*)::text from jsonb_array_elements_text(daily_money_check('13a00000-0000-0000-0000-0000000000a0') -> 'items') i
    where i like '%attached to nothing%'), '0');
select t_occ(60, t_past(60), 'core', 'scheduled', false, 1);
select expect_eq('a class that ran with no pay line is listed',
  (select count(*)::text from jsonb_array_elements_text(daily_money_check('13a00000-0000-0000-0000-0000000000a0') -> 'items') i
    where i like 'T60%ran with no pay line%'), '1');
update pay_periods set status = 'open' where studio_id = '13a00000-0000-0000-0000-0000000000a0';
update instructor_pay_records set created_at = now() - interval '5 days'
 where occurrence_id = '13a00000-0000-0000-0000-00000000c003';
select expect_eq('a pay line held more than 3 days is listed',
  (select count(*)::text from jsonb_array_elements_text(daily_money_check('13a00000-0000-0000-0000-0000000000a0') -> 'items') i
    where i like '%held for%'), '1');
update class_occurrences set attendance_finalised_at = now() where id = '13a00000-0000-0000-0000-00000000c010';
-- the sweep above already trued it up; set a stale amount to see the watchdog.
update instructor_pay_records set amount_cents = 90000 where occurrence_id = '13a00000-0000-0000-0000-00000000c010' and type = 'class';
select expect_eq('a finalised line that differs from 75 (l) is listed (2 at the cut-off, 3 used)',
  (select count(*)::text from jsonb_array_elements_text(daily_money_check('13a00000-0000-0000-0000-0000000000a0') -> 'items') i
    where i like '%T10%but the rules give%'), '1');

-- --- 108 (c): settled lines and the tier at decision time ----------------------
-- Five not-run classes, each with a crafted pay line in the open period. Every
-- one would be flagged on its own amount; the audit or the decision tier is the
-- only thing that should keep T71 to T74 off the list.
do $$
declare k int; o uuid; v_period uuid; v_line uuid;
begin
  select period_id into v_period from instructor_pay_records
   where occurrence_id = '13a00000-0000-0000-0000-00000000c003' and type = 'class';
  for k in 71..75 loop
    -- T74 is flex today (its series changed); the rest are core today.
    o := t_occ(k, t_past(k), case when k = 74 then 'flex' else 'core' end, 'cancelled', false, 0, 'unmet_minimum');
    delete from instructor_pay_records where occurrence_id = o and type = 'class';
    insert into instructor_pay_records (studio_id, instructor_id, period_id, type, occurrence_id, amount_cents, currency, basis, confirmed_at, confirm_method)
    values ('13a00000-0000-0000-0000-0000000000a0', '13a00000-0000-0000-0000-0000000a00c1', v_period, 'class', o,
            case k when 74 then 40000 when 75 then 90000 else 0 end, 'PHP',
            jsonb_build_object('kind','group','outcome','not_running','tier','core','base_cents',90000,
                               'holding_model','flat','holding_flat_cents',40000,'holding_pct',0),
            now(), 'auto')
    returning id into v_line;
    if k in (71,72,73) then
      insert into audit_logs (studio_id, action, entity_table, entity_id, before, after)
      values ('13a00000-0000-0000-0000-0000000000a0',
              case k when 71 then 'pay.line_corrected' when 72 then 'pay.line_voided' else 'pay.line_restored' end,
              'instructor_pay_records', v_line, '{}'::jsonb, '{}'::jsonb);
    end if;
  end loop;
end $$;
create temp table t_dmc as
  select i from jsonb_array_elements_text(daily_money_check('13a00000-0000-0000-0000-0000000000a0') -> 'items') i;
select expect_eq('108 (c): a corrected line is not flagged',  (select count(*)::text from t_dmc where i like '%T71 %'), '0');
select expect_eq('108 (c): a voided line is not flagged',     (select count(*)::text from t_dmc where i like '%T72 %'), '0');
select expect_eq('108 (c): a restored line is not flagged',   (select count(*)::text from t_dmc where i like '%T73 %'), '0');
select expect_eq('108 (c): core at decision, flex today, paid ₱400 is not flagged',
  (select count(*)::text from t_dmc where i like '%T74 %'), '0');
select expect_eq('108 (c): the helper reads T74 at its decision tier (core) while today it is flex',
  (select (r ->> 'decision_tier') || '/' || (r ->> 'today_tier') || '/' || (r ->> 'basis_expected')
     from instructor_pay_records ipr cross join lateral pay_line_review_run(ipr.id) r
    where ipr.occurrence_id = '13a00000-0000-0000-0000-00000000c074'), 'core/flex/40000');
select expect_eq('108 (c): a genuinely wrong line (₱900 on a core class nobody booked) is still flagged by its basis',
  (select count(*)::text from t_dmc where i like '%T75 %but its basis gives%'), '1');
select expect_eq('108 (c): and by the 75 (l) rules',
  (select count(*)::text from t_dmc where i like '%T75 %but the rules give%'), '1');
select expect_eq('108 (c): without the audit, T71''s twin would have been flagged (T75 is flagged, so the audit is what clears T71)',
  (select count(*)::text from t_dmc where i like '%T75 %'), '2');
drop table t_dmc;

-- --- the anon surface ------------------------------------------------------------
select expect_eq('anon surface stays EXACTLY FOURTEEN',
  (select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not in ('expect_eq','expect_err','t_occ','t_seat','t_pay','rec_amt','t_past','t_bk')), '14');
select expect_eq('staff_mark_no_show is not anon',
  has_function_privilege('anon', 'staff_mark_no_show(uuid, text)', 'execute')::text, 'false');

drop table t_ids;
\echo 'pay_timing_test PASS'
