-- =============================================================================
-- Decision 86 — every dashboard card opens the list it counted.
-- =============================================================================
-- UUID space 86d5, checked free. Run after `supabase db reset`.
--
-- One studio DA (Prague): an ended class today (attendance), an upcoming class
-- today (the five seat kinds), an old class (occupancy ordering), payments today
-- (the per-payment list total == the revenue card), members shaped so the active
-- card's three numbers are exact, a free-first cohort (one converted, one not,
-- one host-brought), and one active challenge (the id in the href). Guards: the
-- list readers are desk-up (front desk reaches them, an instructor and a plain
-- member do not); dashboard_kpis stays manager-up.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'BAD  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual then raise notice 'PASS  %', label;
  else raise exception 'BAD  %  expected true, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_txt(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (%)', label, coalesce(actual,'null');
  else raise exception 'BAD  %  expected "%", got "%"', label, want, coalesce(actual,'null'); end if;
end $$;
create or replace function expect_raises(label text, stmt text, want_sqlstate text)
returns void language plpgsql as $$
begin
  execute stmt; raise exception 'BAD  %  expected % but nothing was raised', label, want_sqlstate;
exception when others then
  if sqlstate = want_sqlstate then raise notice 'PASS  %  (got %)', label, sqlstate;
  elsif sqlstate = 'P0001' and sqlerrm like 'BAD%' then raise;
  else raise exception 'BAD  %  expected %, got % (%)', label, want_sqlstate, sqlstate, sqlerrm; end if;
end $$;

-- card lookup: value / href / sub for a key, out of dashboard_kpis' cards array
create or replace function kard(k jsonb, p_key text, p_field text)
returns text language sql immutable as $$
  select c ->> p_field from jsonb_array_elements(k -> 'cards') c where c ->> 'key' = p_key
$$;

-- --- Fixtures ---------------------------------------------------------------
insert into studios (id, name, slug, timezone, currency, status) values
  ('86d586d5-0000-0000-0000-0000000000a1','Dash A','86d5-da','Europe/Prague','CZK','active');
insert into studio_settings (studio_id, require_waiver, free_first_class_enabled, guest_passes_enabled, time_format)
  values ('86d586d5-0000-0000-0000-0000000000a1', false, true, true, '24h');
insert into locations (id, studio_id, name, is_primary) values
  ('86d586d5-0000-0000-0000-0000000000aa','86d586d5-0000-0000-0000-0000000000a1','Main',true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('86d586d5-0000-0000-0000-00000000aa01','86d586d5-0000-0000-0000-0000000000a1','86d586d5-0000-0000-0000-0000000000aa','RA',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('86d586d5-0000-0000-0000-0000000c7a01','86d586d5-0000-0000-0000-0000000000a1','Reformer',50,10);
insert into instructors (id, studio_id, display_name, status) values
  ('86d586d5-0000-0000-0000-0000000149a1','86d586d5-0000-0000-0000-0000000000a1','Ada Teacher','active');

-- Logins: owner (manager-up), front desk (desk-up), instructor (not desk-up).
insert into auth.users (id) values
  ('86d586d5-0000-0000-0000-0000000000f1'),
  ('86d586d5-0000-0000-0000-0000000000f2'),
  ('86d586d5-0000-0000-0000-0000000000f3'),
  ('86d586d5-0000-0000-0000-0000000000f4');
insert into profiles (id, email, full_name) values
  ('86d586d5-0000-0000-0000-0000000000f1','86d5-owner@example.com','Olive Owner'),
  ('86d586d5-0000-0000-0000-0000000000f2','86d5-desk@example.com','Dot Desk'),
  ('86d586d5-0000-0000-0000-0000000000f3','86d5-instr@example.com','Ivy Instructor'),
  ('86d586d5-0000-0000-0000-0000000000f4','86d5-member@example.com','Mal Member');
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('86d586d5-0000-0000-0000-00000005f001','86d586d5-0000-0000-0000-0000000000a1','86d586d5-0000-0000-0000-0000000000f1','86d5-owner@example.com','owner'),
  ('86d586d5-0000-0000-0000-00000005f002','86d586d5-0000-0000-0000-0000000000a1','86d586d5-0000-0000-0000-0000000000f2','86d5-desk@example.com','front_desk'),
  ('86d586d5-0000-0000-0000-00000005f003','86d586d5-0000-0000-0000-0000000000a1','86d586d5-0000-0000-0000-0000000000f3','86d5-instr@example.com','instructor');

-- joined_on: this month for MB only; last month otherwise. last_visit_at within
-- 30d for MB and MC only.
insert into members (id, studio_id, email, first_name, last_name, status, joined_on, last_visit_at, user_id) values
  ('86d586d5-0000-0000-0000-00000000a001','86d586d5-0000-0000-0000-0000000000a1','ma@example.com','Mia','Plan','active',    date_trunc('month', current_date)::date - 5, now() - interval '40 days', null),
  ('86d586d5-0000-0000-0000-00000000a002','86d586d5-0000-0000-0000-0000000000a1','mb@example.com','Bea','Both','active',    date_trunc('month', current_date)::date + 2, now() - interval '5 days',  null),
  ('86d586d5-0000-0000-0000-00000000a003','86d586d5-0000-0000-0000-0000000000a1','mc@example.com','Cal','Expired','active', date_trunc('month', current_date)::date - 40, now() - interval '2 days', null),
  ('86d586d5-0000-0000-0000-00000000a004','86d586d5-0000-0000-0000-0000000000a1','mf@example.com','Fay','Free','active',    date_trunc('month', current_date)::date - 20, null, null),
  ('86d586d5-0000-0000-0000-00000000a005','86d586d5-0000-0000-0000-0000000000a1','mp@example.com','Pat','Paid','active',    date_trunc('month', current_date)::date - 20, null, null),
  ('86d586d5-0000-0000-0000-00000000a006','86d586d5-0000-0000-0000-0000000000a1','mu@example.com','Uma','Unpaid','active',  date_trunc('month', current_date)::date - 20, null, null),
  ('86d586d5-0000-0000-0000-00000000a007','86d586d5-0000-0000-0000-0000000000a1','mx@example.com','Xan','Comp','active',    date_trunc('month', current_date)::date - 20, null, null),
  ('86d586d5-0000-0000-0000-00000000a008','86d586d5-0000-0000-0000-0000000000a1','mg@example.com','Gus','Converted','active',date_trunc('month', current_date)::date - 20, null, null),
  ('86d586d5-0000-0000-0000-00000000a009','86d586d5-0000-0000-0000-0000000000a1','mh@example.com','Hal','Hosted','active',  date_trunc('month', current_date)::date - 20, null, null),
  ('86d586d5-0000-0000-0000-00000000a011','86d586d5-0000-0000-0000-0000000000a1','me1@example.com','Em','One','active',     date_trunc('month', current_date)::date - 20, null, null),
  ('86d586d5-0000-0000-0000-00000000a012','86d586d5-0000-0000-0000-0000000000a1','me2@example.com','Em','Two','active',     date_trunc('month', current_date)::date - 20, null, null),
  ('86d586d5-0000-0000-0000-00000000a013','86d586d5-0000-0000-0000-0000000000a1','me3@example.com','Em','Three','active',   date_trunc('month', current_date)::date - 20, null, null),
  ('86d586d5-0000-0000-0000-00000000a010','86d586d5-0000-0000-0000-0000000000a1','mlogin@example.com','Mal','Member','active',date_trunc('month', current_date)::date - 20, null, '86d586d5-0000-0000-0000-0000000000f4');

-- Plans: a recurring "Unlimited" (MA, MB -> can book) and a class_pack "Intro
-- Pack" (MC, MG -> expired/paid).
insert into membership_plans (id, studio_id, name, type, price_cents, currency, status, billing_interval, credits_per_period, credits) values
  ('86d586d5-0000-0000-0000-00000000db01','86d586d5-0000-0000-0000-0000000000a1','Unlimited','recurring',10000,'CZK','active','month', null, null),
  ('86d586d5-0000-0000-0000-00000000db02','86d586d5-0000-0000-0000-0000000000a1','Intro Pack','class_pack',4000,'CZK','active', null, null, 5);
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on, expires_on, credits_remaining) values
  ('86d586d5-0000-0000-0000-00000000d511','86d586d5-0000-0000-0000-0000000000a1','86d586d5-0000-0000-0000-00000000a001','86d586d5-0000-0000-0000-00000000db01','active',10000,'CZK',current_date - 10, null, null),
  ('86d586d5-0000-0000-0000-00000000d512','86d586d5-0000-0000-0000-0000000000a1','86d586d5-0000-0000-0000-00000000a002','86d586d5-0000-0000-0000-00000000db01','active',10000,'CZK',current_date - 10, null, null),
  ('86d586d5-0000-0000-0000-00000000d513','86d586d5-0000-0000-0000-0000000000a1','86d586d5-0000-0000-0000-00000000a003','86d586d5-0000-0000-0000-00000000db02','expired',4000,'CZK',current_date - 100, current_date - 10, 0),
  ('86d586d5-0000-0000-0000-00000000d518','86d586d5-0000-0000-0000-0000000000a1','86d586d5-0000-0000-0000-00000000a008','86d586d5-0000-0000-0000-00000000db02','expired',4000,'CZK',current_date - 100, current_date - 10, 0);

-- Occurrences: ENDED today, UPCOMING today, OLD (10 days ago, occupancy).
insert into class_occurrences
  (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, booked_count, starts_at, ends_at, status)
values
  ('86d586d5-0000-0000-0000-0000000cc001','86d586d5-0000-0000-0000-0000000000a1','86d586d5-0000-0000-0000-0000000000aa','86d586d5-0000-0000-0000-0000000c7a01','86d586d5-0000-0000-0000-00000000aa01','86d586d5-0000-0000-0000-0000000149a1','Ended',10,3, now() - interval '3 hours', now() - interval '2 hours','scheduled'),
  ('86d586d5-0000-0000-0000-0000000cc002','86d586d5-0000-0000-0000-0000000000a1','86d586d5-0000-0000-0000-0000000000aa','86d586d5-0000-0000-0000-0000000c7a01','86d586d5-0000-0000-0000-00000000aa01','86d586d5-0000-0000-0000-0000000149a1','Upcoming',10,5, now() + interval '2 hours', now() + interval '3 hours','scheduled'),
  ('86d586d5-0000-0000-0000-0000000cc003','86d586d5-0000-0000-0000-0000000000a1','86d586d5-0000-0000-0000-0000000000aa','86d586d5-0000-0000-0000-0000000c7a01','86d586d5-0000-0000-0000-00000000aa01','86d586d5-0000-0000-0000-0000000149a1','Old',10,1, now() - interval '10 days', now() - interval '10 days' + interval '50 min','scheduled');

-- Ended-class bookings: attended / no_show / booked. booked_at in the PAST, so
-- "bookings made today" is 0 — the card counts seats in classes, not made-today.
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source, booked_at) values
  ('86d586d5-0000-0000-0000-00000000b011','86d586d5-0000-0000-0000-0000000000a1','86d586d5-0000-0000-0000-0000000cc001','86d586d5-0000-0000-0000-00000000a011','attended','membership', now() - interval '1 day'),
  ('86d586d5-0000-0000-0000-00000000b012','86d586d5-0000-0000-0000-0000000000a1','86d586d5-0000-0000-0000-0000000cc001','86d586d5-0000-0000-0000-00000000a012','no_show','membership', now() - interval '1 day'),
  ('86d586d5-0000-0000-0000-00000000b013','86d586d5-0000-0000-0000-0000000000a1','86d586d5-0000-0000-0000-0000000cc001','86d586d5-0000-0000-0000-00000000a013','booked','membership', now() - interval '1 day');
-- Upcoming-class bookings: the five seat kinds.
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source, provisional, booked_at) values
  ('86d586d5-0000-0000-0000-00000000b0a1','86d586d5-0000-0000-0000-0000000000a1','86d586d5-0000-0000-0000-0000000cc002','86d586d5-0000-0000-0000-00000000a001','booked','membership',false, now() - interval '1 day'),
  ('86d586d5-0000-0000-0000-00000000b0f1','86d586d5-0000-0000-0000-0000000000a1','86d586d5-0000-0000-0000-0000000cc002','86d586d5-0000-0000-0000-00000000a004','booked','comp',     true,  now() - interval '1 day'),
  ('86d586d5-0000-0000-0000-00000000b0d1','86d586d5-0000-0000-0000-0000000000a1','86d586d5-0000-0000-0000-0000000cc002','86d586d5-0000-0000-0000-00000000a005','booked','drop_in',  false, now() - interval '1 day'),
  ('86d586d5-0000-0000-0000-00000000b0e1','86d586d5-0000-0000-0000-0000000000a1','86d586d5-0000-0000-0000-0000000cc002','86d586d5-0000-0000-0000-00000000a006','booked','drop_in',  false, now() - interval '1 day'),
  ('86d586d5-0000-0000-0000-00000000b0c1','86d586d5-0000-0000-0000-0000000000a1','86d586d5-0000-0000-0000-0000000cc002','86d586d5-0000-0000-0000-00000000a007','booked','comp',     false, now() - interval '1 day');
-- a check-in for the attended ended booking (seat_kind/checked_in)
insert into check_ins (studio_id, member_id, occurrence_id, booking_id, method, checked_in_at) values
  ('86d586d5-0000-0000-0000-0000000000a1','86d586d5-0000-0000-0000-00000000a011','86d586d5-0000-0000-0000-0000000cc001','86d586d5-0000-0000-0000-00000000b011','self', now() - interval '2 hours 30 min');

-- Guest passes: MF free-first (not converted, booking UB), MG free-first
-- (converted via the expired membership), MH host-brought (host = MA).
insert into guest_passes (id, studio_id, host_member_id, guest_member_id, guest_email, occurrence_id, guest_booking_id, status, created_at) values
  ('86d586d5-0000-0000-0000-00000000da01','86d586d5-0000-0000-0000-0000000000a1', null, '86d586d5-0000-0000-0000-00000000a004','mf@example.com','86d586d5-0000-0000-0000-0000000cc002','86d586d5-0000-0000-0000-00000000b0f1','confirmed', now() - interval '1 day'),
  ('86d586d5-0000-0000-0000-00000000da02','86d586d5-0000-0000-0000-0000000000a1', null, '86d586d5-0000-0000-0000-00000000a008','mg@example.com','86d586d5-0000-0000-0000-0000000cc002', null,'attended', now() - interval '30 days'),
  ('86d586d5-0000-0000-0000-00000000da03','86d586d5-0000-0000-0000-0000000000a1','86d586d5-0000-0000-0000-00000000a001','86d586d5-0000-0000-0000-00000000a009','mh@example.com','86d586d5-0000-0000-0000-0000000cc002', null,'attended', now() - interval '2 days');

-- Product + order (one payment names a product).
insert into products (id, studio_id, name, price_cents, currency, track_stock, stock, status) values
  ('86d586d5-0000-0000-0000-00000000cd01','86d586d5-0000-0000-0000-0000000000a1','Grip socks',500,'CZK',true,20,'active');
insert into product_orders (id, studio_id, product_id, member_id, quantity, unit_price_cents, currency, status, channel) values
  ('86d586d5-0000-0000-0000-00000000ce01','86d586d5-0000-0000-0000-0000000000a1','86d586d5-0000-0000-0000-00000000cd01','86d586d5-0000-0000-0000-00000000a005',1,500,'CZK','collected','desk');

-- Payments: three TODAY (sum 12000), one yesterday, one failed today (excluded).
insert into payments (id, studio_id, member_id, membership_id, booking_id, product_order_id, amount_cents, currency, status, provider, method, recorded_by, paid_at, created_at) values
  ('86d586d5-0000-0000-0000-00000000fa01','86d586d5-0000-0000-0000-0000000000a1','86d586d5-0000-0000-0000-00000000a001','86d586d5-0000-0000-0000-00000000d511',null,null,10000,'CZK','succeeded','manual','gcash','86d586d5-0000-0000-0000-0000000000f1', now(), now()),
  ('86d586d5-0000-0000-0000-00000000fa02','86d586d5-0000-0000-0000-0000000000a1','86d586d5-0000-0000-0000-00000000a005',null,'86d586d5-0000-0000-0000-00000000b0d1',null,1500,'CZK','succeeded','manual','cash','86d586d5-0000-0000-0000-0000000000f1', now(), now()),
  ('86d586d5-0000-0000-0000-00000000fa03','86d586d5-0000-0000-0000-0000000000a1','86d586d5-0000-0000-0000-00000000a005',null,null,'86d586d5-0000-0000-0000-00000000ce01',500,'CZK','succeeded','manual','cash','86d586d5-0000-0000-0000-0000000000f1', now(), now()),
  ('86d586d5-0000-0000-0000-00000000fa04','86d586d5-0000-0000-0000-0000000000a1','86d586d5-0000-0000-0000-00000000a001','86d586d5-0000-0000-0000-00000000d511',null,null,9999,'CZK','succeeded','manual','cash','86d586d5-0000-0000-0000-0000000000f1', now() - interval '1 day', now() - interval '1 day'),
  ('86d586d5-0000-0000-0000-00000000fa05','86d586d5-0000-0000-0000-0000000000a1','86d586d5-0000-0000-0000-00000000a001',null,null,null,7777,'CZK','failed','manual','cash','86d586d5-0000-0000-0000-0000000000f1', null, now());

-- An active member challenge with one participant (the id must ride the href).
insert into challenges (id, studio_id, title, audience, type, goal_value, starts_on, ends_on, join_deadline, status) values
  ('86d586d5-0000-0000-0000-00000000cb01','86d586d5-0000-0000-0000-0000000000a1','March Streak','member','class_count',8, current_date - 5, current_date + 20, current_date - 1, 'active');
insert into challenge_participants (studio_id, challenge_id, audience, member_id, goal_value, progress) values
  ('86d586d5-0000-0000-0000-0000000000a1','86d586d5-0000-0000-0000-00000000cb01','member','86d586d5-0000-0000-0000-00000000a002',8,3);

-- Mark bands so members_at_risk and at-risk href are exercised.
update members set health_band = 'at_risk'
 where id = '86d586d5-0000-0000-0000-00000000a003';
update members set health_band = 'healthy'
 where studio_id = '86d586d5-0000-0000-0000-0000000000a1' and health_band is null;

\echo ''
\echo '=== 1. dashboard_kpis — the eight card definitions and hrefs ==='
set role authenticated;
select set_config('request.jwt.claim.sub','86d586d5-0000-0000-0000-0000000000f1',false);
select set_config('d86.k', dashboard_kpis('86d586d5-0000-0000-0000-0000000000a1')::text, false);
reset role;

-- Revenue: the card value is the sum of today's payments.
select expect_num('revenue card = today''s payments (10000+1500+500)',
  (kard(current_setting('d86.k')::jsonb,'revenue_today','value'))::bigint, 12000);
select expect_num('revenue card == studio_revenue_between',
  (kard(current_setting('d86.k')::jsonb,'revenue_today','value'))::bigint,
  studio_revenue_between('86d586d5-0000-0000-0000-0000000000a1',
    (select day_start from studio_day_bounds('86d586d5-0000-0000-0000-0000000000a1', studio_today('86d586d5-0000-0000-0000-0000000000a1'))),
    (select day_end   from studio_day_bounds('86d586d5-0000-0000-0000-0000000000a1', studio_today('86d586d5-0000-0000-0000-0000000000a1')))));
select expect_txt('revenue card opens the per-payment list for today',
  kard(current_setting('d86.k')::jsonb,'revenue_today','href'), '/dashboard/revenue/today');

-- Bookings: SEATS IN TODAY'S CLASSES = ended 3 + upcoming 5 = 8, not made-today (0).
select expect_num('bookings card = seats in today''s classes (3 + 5)',
  (kard(current_setting('d86.k')::jsonb,'bookings_today','value'))::bigint, 8);
select expect_txt('bookings card opens Today''s classes',
  kard(current_setting('d86.k')::jsonb,'bookings_today','href'), '/dashboard/classes');

-- Attendance: ended class only, 1 of 3 came = 33; opens the ended list.
select expect_num('attendance = 1 of 3 on the ended class',
  (kard(current_setting('d86.k')::jsonb,'attendance_today','value'))::bigint, 33);
select expect_txt('attendance opens the ended Today''s classes',
  kard(current_setting('d86.k')::jsonb,'attendance_today','href'), '/dashboard/classes?ended=1');

-- Active: can book now = MA + MB = 2; sub = 2 came in the last 30 days; links.
select expect_num('active = can book now (2)',
  (kard(current_setting('d86.k')::jsonb,'active_members','value'))::bigint, 2);
select expect_txt('active sub names the last-30-days count',
  kard(current_setting('d86.k')::jsonb,'active_members','sub'), '2 came in the last 30 days');
select expect_txt('active card opens the can-book list',
  kard(current_setting('d86.k')::jsonb,'active_members','href'), '/members?filter=can_book');
select expect_txt('active link 1 opens attended-30d',
  ((kard(current_setting('d86.k')::jsonb,'active_members','links'))::jsonb -> 0 ->> 'href'),
  '/members?filter=attended_30d');
select expect_txt('active link 2 opens joined-this-month',
  ((kard(current_setting('d86.k')::jsonb,'active_members','links'))::jsonb -> 1 ->> 'href'),
  '/members?filter=joined_month');
select expect_txt('active link 2 names the joined-this-month count (1)',
  ((kard(current_setting('d86.k')::jsonb,'active_members','links'))::jsonb -> 1 ->> 'label'),
  '1 joined this month');

-- At risk: opens the retention board at-risk section.
select expect_num('members at risk = 1',
  (kard(current_setting('d86.k')::jsonb,'members_at_risk','value'))::bigint, 1);
select expect_txt('at-risk card opens the retention board at-risk section',
  kard(current_setting('d86.k')::jsonb,'members_at_risk','href'), '/retention#at_risk');

-- Occupancy: opens the per-class list.
select expect_txt('occupancy card opens the classes list',
  kard(current_setting('d86.k')::jsonb,'avg_occupancy','href'), '/dashboard/occupancy');

\echo ''
\echo '=== 2. dashboard_payments_on — one row per payment, total == the card ==='
set role authenticated;
select set_config('request.jwt.claim.sub','86d586d5-0000-0000-0000-0000000000f1',false);
select expect_num('three payments today (yesterday and failed excluded)',
  (select count(*) from dashboard_payments_on('86d586d5-0000-0000-0000-0000000000a1', studio_today('86d586d5-0000-0000-0000-0000000000a1'))), 3);
select expect_num('the list total is the same 12000 the card shows',
  (select coalesce(sum(amount_cents),0)::bigint from dashboard_payments_on('86d586d5-0000-0000-0000-0000000000a1', studio_today('86d586d5-0000-0000-0000-0000000000a1'))), 12000);
select expect_txt('the membership payment names its plan and method and who recorded it',
  (select item || ' / ' || method || ' / ' || coalesce(recorded_by,'null')
     from dashboard_payments_on('86d586d5-0000-0000-0000-0000000000a1', studio_today('86d586d5-0000-0000-0000-0000000000a1'))
    where amount_cents = 10000), 'Unlimited / GCash / Olive Owner');
select expect_txt('the product payment names the product',
  (select item from dashboard_payments_on('86d586d5-0000-0000-0000-0000000000a1', studio_today('86d586d5-0000-0000-0000-0000000000a1')) where amount_cents = 500), 'Grip socks');
select expect_txt('the drop-in payment reads Drop-in',
  (select item from dashboard_payments_on('86d586d5-0000-0000-0000-0000000000a1', studio_today('86d586d5-0000-0000-0000-0000000000a1')) where amount_cents = 1500), 'Drop-in');
reset role;

\echo ''
\echo '=== 3. dashboard_today_classes — classes in time order, seat kinds ==='
set role authenticated;
select set_config('request.jwt.claim.sub','86d586d5-0000-0000-0000-0000000000f1',false);
select set_config('d86.c', dashboard_today_classes('86d586d5-0000-0000-0000-0000000000a1', studio_today('86d586d5-0000-0000-0000-0000000000a1'))::text, false);
reset role;

select expect_num('two classes today (ended + upcoming), old one excluded',
  jsonb_array_length(current_setting('d86.c')::jsonb)::bigint, 2);
select expect_true('the ended class is in time order first and flagged ended',
  ((current_setting('d86.c')::jsonb -> 0 ->> 'name') = 'Ended'
   and (current_setting('d86.c')::jsonb -> 0 ->> 'ended')::boolean));
select expect_true('the upcoming class is not ended',
  not ((current_setting('d86.c')::jsonb -> 1 ->> 'ended')::boolean));
-- the five seat kinds on the upcoming class
select expect_txt('free-first seat',
  (select m ->> 'seat_kind' from jsonb_array_elements(current_setting('d86.c')::jsonb -> 1 -> 'members') m where m ->> 'name' = 'Fay Free'), 'free_first');
select expect_txt('paid drop-in seat',
  (select m ->> 'seat_kind' from jsonb_array_elements(current_setting('d86.c')::jsonb -> 1 -> 'members') m where m ->> 'name' = 'Pat Paid'), 'drop_in_paid');
select expect_txt('unpaid drop-in seat',
  (select m ->> 'seat_kind' from jsonb_array_elements(current_setting('d86.c')::jsonb -> 1 -> 'members') m where m ->> 'name' = 'Uma Unpaid'), 'drop_in_unpaid');
select expect_txt('complimentary seat',
  (select m ->> 'seat_kind' from jsonb_array_elements(current_setting('d86.c')::jsonb -> 1 -> 'members') m where m ->> 'name' = 'Xan Comp'), 'complimentary');
select expect_txt('plan seat',
  (select m ->> 'seat_kind' from jsonb_array_elements(current_setting('d86.c')::jsonb -> 1 -> 'members') m where m ->> 'name' = 'Mia Plan'), 'plan');
-- ended class: checked-in attended / no_show state
select expect_true('the attended member is checked in',
  (select (m ->> 'checked_in')::boolean from jsonb_array_elements(current_setting('d86.c')::jsonb -> 0 -> 'members') m where m ->> 'name' = 'Em One'));
select expect_txt('the no-show state is carried',
  (select m ->> 'state' from jsonb_array_elements(current_setting('d86.c')::jsonb -> 0 -> 'members') m where m ->> 'name' = 'Em Two'), 'no_show');

\echo ''
\echo '=== 4. dashboard_occupancy_30d — emptiest first ==='
set role authenticated;
select set_config('request.jwt.claim.sub','86d586d5-0000-0000-0000-0000000000f1',false);
select expect_txt('the emptiest ran-class is first (Old, 10%)',
  (select name from dashboard_occupancy_30d('86d586d5-0000-0000-0000-0000000000a1') limit 1), 'Old');
select expect_num('its occupancy is 10%',
  (select pct from dashboard_occupancy_30d('86d586d5-0000-0000-0000-0000000000a1') limit 1)::bigint, 10);
select expect_num('the upcoming class has not run, so it is excluded',
  (select count(*) from dashboard_occupancy_30d('86d586d5-0000-0000-0000-0000000000a1') where name = 'Upcoming'), 0);
reset role;

\echo ''
\echo '=== 5. dashboard_free_first_members — took a free class, converted or not ==='
set role authenticated;
select set_config('request.jwt.claim.sub','86d586d5-0000-0000-0000-0000000000f1',false);
select set_config('d86.f', dashboard_free_first_members('86d586d5-0000-0000-0000-0000000000a1')::text, false);
reset role;

select expect_num('two free-first members (MF, MG), host-brought excluded',
  jsonb_array_length(current_setting('d86.f')::jsonb -> 'members')::bigint, 2);
select expect_true('the converted one shows its plan',
  (select (m ->> 'converted')::boolean and (m ->> 'plan_bought') = 'Intro Pack'
     from jsonb_array_elements(current_setting('d86.f')::jsonb -> 'members') m where m ->> 'name' = 'Gus Converted'));
select expect_true('the unconverted one is not converted',
  (select not (m ->> 'converted')::boolean
     from jsonb_array_elements(current_setting('d86.f')::jsonb -> 'members') m where m ->> 'name' = 'Fay Free'));
select expect_num('one guest was brought by a member',
  (current_setting('d86.f')::jsonb ->> 'brought_by_member')::bigint, 1);

\echo ''
\echo '=== 6. the two appended KPIs carry the right hrefs ==='
set role authenticated;
select set_config('request.jwt.claim.sub','86d586d5-0000-0000-0000-0000000000f1',false);
select expect_txt('challenge card href carries the challenge id',
  dashboard_challenge_kpi('86d586d5-0000-0000-0000-0000000000a1') ->> 'href',
  '/challenges/86d586d5-0000-0000-0000-00000000cb01');
select expect_txt('free-first conversion card opens the free-class list',
  dashboard_free_first_kpi('86d586d5-0000-0000-0000-0000000000a1') ->> 'href',
  '/dashboard/free-classes');
reset role;

\echo ''
\echo '=== 7. guards — list readers are desk-up; dashboard_kpis is manager-up ==='
-- front desk (desk-up) reaches the lists
set role authenticated;
select set_config('request.jwt.claim.sub','86d586d5-0000-0000-0000-0000000000f2',false);
select expect_num('front desk reads the payments list',
  (select count(*) from dashboard_payments_on('86d586d5-0000-0000-0000-0000000000a1', studio_today('86d586d5-0000-0000-0000-0000000000a1'))), 3);
select expect_true('front desk reads today''s classes',
  (jsonb_array_length(dashboard_today_classes('86d586d5-0000-0000-0000-0000000000a1', studio_today('86d586d5-0000-0000-0000-0000000000a1'))) = 2));
-- front desk is NOT manager-up, so dashboard_kpis refuses it
select expect_raises('front desk cannot read dashboard_kpis (manager-up)',
  $$ select dashboard_kpis('86d586d5-0000-0000-0000-0000000000a1') $$, 'PT403');
reset role;
-- an instructor is not desk-up
set role authenticated;
select set_config('request.jwt.claim.sub','86d586d5-0000-0000-0000-0000000000f3',false);
select expect_raises('an instructor cannot read the payments list',
  $$ select * from dashboard_payments_on('86d586d5-0000-0000-0000-0000000000a1', current_date) $$, 'PT403');
select expect_raises('an instructor cannot read today''s classes',
  $$ select dashboard_today_classes('86d586d5-0000-0000-0000-0000000000a1', current_date) $$, 'PT403');
select expect_raises('an instructor cannot read the occupancy list',
  $$ select * from dashboard_occupancy_30d('86d586d5-0000-0000-0000-0000000000a1') $$, 'PT403');
select expect_raises('an instructor cannot read the free-class list',
  $$ select dashboard_free_first_members('86d586d5-0000-0000-0000-0000000000a1') $$, 'PT403');
reset role;
-- a plain member
set role authenticated;
select set_config('request.jwt.claim.sub','86d586d5-0000-0000-0000-0000000000f4',false);
select expect_raises('a member cannot read the payments list',
  $$ select * from dashboard_payments_on('86d586d5-0000-0000-0000-0000000000a1', current_date) $$, 'PT403');
reset role;

\echo ''
\echo '=== 8. anon surface is exactly thirteen ==='
select expect_num('anon surface is thirteen',
  (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not like 'expect_%' and p.proname not in ('login','sig','psig','kard')), 13);

\echo ''
\echo '=== dashboard_cards_test PASSED ==='
