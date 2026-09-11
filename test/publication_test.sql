-- =============================================================================
-- Month publication — Decision 25, migration 112
-- =============================================================================
-- UUID space 9b15, checked free. Run after `supabase db reset`.
--
-- THREE STUDIOS:
--
--   A  Prague, publication ON, turned on mid-life with a member already booked
--      into a future month. The feature working, and the switch-on doing what
--      "a month members have booked into cannot be withdrawn" requires.
--   B  Manila, publication ON. Exists so that publishing two studios' months in
--      ONE run tells each instructor about their own studio and nothing else.
--   C  Prague, publication OFF, with a timetable shaped exactly like A's and no
--      publication rows anywhere. The switch is the only thing standing between
--      it and the draft state — which is the assertion Decision 24's seat-cap
--      suite exists for, and the one the flex suite originally lacked.
--
-- Every date is the STUDIO's month: "next month" is computed from the studio's
-- own clock, not the server's, or this suite would fail for the hours a night
-- when Manila is already tomorrow.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then
    raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else
    raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null');
  end if;
end $$;

create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then
    raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else
    raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null');
  end if;
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

create or replace function expect_raises(label text, stmt text, want_sqlstate text)
returns void language plpgsql as $$
begin
  execute stmt; raise exception 'FAIL  %  expected % but nothing was raised', label, want_sqlstate;
exception when others then
  if sqlstate = want_sqlstate then raise notice 'PASS  %  (got %)', label, sqlstate;
  elsif sqlstate = 'P0001' and sqlerrm like 'FAIL%' then raise;
  else raise exception 'FAIL  %  expected %, got % (%)', label, want_sqlstate, sqlstate, sqlerrm; end if;
end $$;

-- A refusal is only useful if it says what is wrong, so the message is
-- asserted as well as the code. This matters below: confirming a draft month
-- raises PT409, and so does confirming a month with nothing in it — an
-- assertion on the code alone passed with the publication check deleted.
create or replace function expect_raises_saying(label text, stmt text,
                                                want_sqlstate text, want_like text)
returns void language plpgsql as $$
begin
  execute stmt; raise exception 'FAIL  %  expected % but nothing was raised', label, want_sqlstate;
exception when others then
  if sqlstate = 'P0001' and sqlerrm like 'FAIL%' then raise; end if;
  if sqlstate <> want_sqlstate then
    raise exception 'FAIL  %  expected %, got % (%)', label, want_sqlstate, sqlstate, sqlerrm;
  end if;
  if sqlerrm not like want_like then
    raise exception 'FAIL  %  message did not match %: got "%"', label, want_like, sqlerrm;
  end if;
  raise notice 'PASS  %  (% — "%")', label, sqlstate, sqlerrm;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('9b159b15-0000-0000-0000-0000000000a1'),   -- owner of A, B and C
  ('9b159b15-0000-0000-0000-0000000000a2'),   -- A: instructor Ana (login)
  ('9b159b15-0000-0000-0000-0000000000a3'),   -- A: instructor Bo  (login)
  ('9b159b15-0000-0000-0000-0000000000a4'),   -- A: front desk
  ('9b159b15-0000-0000-0000-0000000000b2'),   -- B: instructor Bel (login)
  ('9b159b15-0000-0000-0000-0000000000c2'),   -- C: instructor Cy  (login)
  ('9b159b15-0000-0000-0000-0000000000e1'),   -- A: member Mia
  ('9b159b15-0000-0000-0000-0000000000e3');   -- C: member Cleo
insert into profiles (id, email) values
  ('9b159b15-0000-0000-0000-0000000000a1','9b15-owner@example.com'),
  ('9b159b15-0000-0000-0000-0000000000a2','9b15-ana@example.com'),
  ('9b159b15-0000-0000-0000-0000000000a3','9b15-bo@example.com'),
  ('9b159b15-0000-0000-0000-0000000000a4','9b15-desk@example.com'),
  ('9b159b15-0000-0000-0000-0000000000b2','9b15-bel@example.com'),
  ('9b159b15-0000-0000-0000-0000000000c2','9b15-cy@example.com'),
  ('9b159b15-0000-0000-0000-0000000000e1','9b15-mia@example.com'),
  ('9b159b15-0000-0000-0000-0000000000e3','9b15-cleo@example.com');

insert into studios (id, name, slug, timezone, currency, status) values
  ('9b159b15-0000-0000-0000-000000000001','Publish A','publish-a','Europe/Prague','CZK','active'),
  ('9b159b15-0000-0000-0000-000000000002','Publish B','publish-b','Asia/Manila','PHP','active'),
  ('9b159b15-0000-0000-0000-000000000003','Never Publishes','never-publishes','Europe/Prague','CZK','active');

-- A starts with the switch OFF and turns it on below, so set_publication_enabled()
-- is exercised. B is on from the start. C is off and stays off. A's booking
-- window is 45 days so that "day 5 of next month" is always inside it and
-- "day 28" always outside, whatever today's date is.
insert into studio_settings (studio_id, publication_enabled, booking_window_days) values
  ('9b159b15-0000-0000-0000-000000000001', false, 45),
  ('9b159b15-0000-0000-0000-000000000002', true,  45),
  ('9b159b15-0000-0000-0000-000000000003', false, 45);

insert into locations (id, studio_id, name, is_primary) values
  ('9b159b15-0000-0000-0000-00000000000a','9b159b15-0000-0000-0000-000000000001','Main',true),
  ('9b159b15-0000-0000-0000-00000000000b','9b159b15-0000-0000-0000-000000000002','Main',true),
  ('9b159b15-0000-0000-0000-00000000000c','9b159b15-0000-0000-0000-000000000003','Main',true);

insert into studio_staff (id, studio_id, user_id, email, role) values
  ('9b159b15-0000-0000-0000-00000000aa01','9b159b15-0000-0000-0000-000000000001','9b159b15-0000-0000-0000-0000000000a1','9b15-owner@example.com','owner'),
  ('9b159b15-0000-0000-0000-00000000aa02','9b159b15-0000-0000-0000-000000000001','9b159b15-0000-0000-0000-0000000000a2','9b15-ana@example.com','instructor'),
  ('9b159b15-0000-0000-0000-00000000aa03','9b159b15-0000-0000-0000-000000000001','9b159b15-0000-0000-0000-0000000000a3','9b15-bo@example.com','instructor'),
  ('9b159b15-0000-0000-0000-00000000aa04','9b159b15-0000-0000-0000-000000000001','9b159b15-0000-0000-0000-0000000000a4','9b15-desk@example.com','front_desk'),
  ('9b159b15-0000-0000-0000-00000000bb01','9b159b15-0000-0000-0000-000000000002','9b159b15-0000-0000-0000-0000000000a1','9b15-owner-b@example.com','owner'),
  ('9b159b15-0000-0000-0000-00000000bb02','9b159b15-0000-0000-0000-000000000002','9b159b15-0000-0000-0000-0000000000b2','9b15-bel@example.com','instructor'),
  ('9b159b15-0000-0000-0000-00000000cc01','9b159b15-0000-0000-0000-000000000003','9b159b15-0000-0000-0000-0000000000a1','9b15-owner-c@example.com','owner'),
  ('9b159b15-0000-0000-0000-00000000cc02','9b159b15-0000-0000-0000-000000000003','9b159b15-0000-0000-0000-0000000000c2','9b15-cy@example.com','instructor');

insert into rooms (id, studio_id, location_id, name, capacity) values
  ('9b159b15-0000-0000-0000-00000000ee01','9b159b15-0000-0000-0000-000000000001','9b159b15-0000-0000-0000-00000000000a','Studio 1',10),
  ('9b159b15-0000-0000-0000-00000000ee02','9b159b15-0000-0000-0000-000000000002','9b159b15-0000-0000-0000-00000000000b','Studio 1',10),
  ('9b159b15-0000-0000-0000-00000000ee03','9b159b15-0000-0000-0000-000000000003','9b159b15-0000-0000-0000-00000000000c','Studio 1',10);

insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('9b159b15-0000-0000-0000-00000000cc01','9b159b15-0000-0000-0000-000000000001','Reformer',50,10),
  ('9b159b15-0000-0000-0000-00000000cc02','9b159b15-0000-0000-0000-000000000002','Manila Mat',50,10),
  ('9b159b15-0000-0000-0000-00000000cc03','9b159b15-0000-0000-0000-000000000003','Reformer',50,10);

-- Ana and Bo can sign in; Cai has no login at all — the ordinary case, and the
-- one "published" must not silently claim to have told.
insert into instructors (id, studio_id, display_name, staff_id) values
  ('9b159b15-0000-0000-0000-00000000d101','9b159b15-0000-0000-0000-000000000001','Ana','9b159b15-0000-0000-0000-00000000aa02'),
  ('9b159b15-0000-0000-0000-00000000d102','9b159b15-0000-0000-0000-000000000001','Bo', '9b159b15-0000-0000-0000-00000000aa03'),
  ('9b159b15-0000-0000-0000-00000000d103','9b159b15-0000-0000-0000-000000000001','Cai', null),
  ('9b159b15-0000-0000-0000-00000000d201','9b159b15-0000-0000-0000-000000000002','Bel','9b159b15-0000-0000-0000-00000000bb02'),
  ('9b159b15-0000-0000-0000-00000000d301','9b159b15-0000-0000-0000-000000000003','Cy', '9b159b15-0000-0000-0000-00000000cc02');

insert into instructor_class_types (studio_id, instructor_id, class_type_id) values
  ('9b159b15-0000-0000-0000-000000000001','9b159b15-0000-0000-0000-00000000d101','9b159b15-0000-0000-0000-00000000cc01'),
  ('9b159b15-0000-0000-0000-000000000001','9b159b15-0000-0000-0000-00000000d102','9b159b15-0000-0000-0000-00000000cc01'),
  ('9b159b15-0000-0000-0000-000000000003','9b159b15-0000-0000-0000-00000000d301','9b159b15-0000-0000-0000-00000000cc03');

insert into members (id, studio_id, user_id, first_name, last_name, email, joined_on, status, waiver_signed_at) values
  ('9b159b15-0000-0000-0000-00000000f001','9b159b15-0000-0000-0000-000000000001',
   '9b159b15-0000-0000-0000-0000000000e1','Mia','Vesela','9b15-mia@example.com', current_date - 60,'active', now()),
  ('9b159b15-0000-0000-0000-00000000f003','9b159b15-0000-0000-0000-000000000003',
   '9b159b15-0000-0000-0000-0000000000e3','Cleo','Novak','9b15-cleo@example.com', current_date - 60,'active', now());

-- Unlimited memberships so booking resolves to a membership and nothing else
-- is in the way.
insert into membership_plans (id, studio_id, name, type, price_cents, currency,
                              billing_interval, credits_per_period, status) values
  ('9b159b15-0000-0000-0000-00000000c001','9b159b15-0000-0000-0000-000000000001',
   'Unlimited','recurring', 250000, 'CZK', 'month', null, 'active'),
  ('9b159b15-0000-0000-0000-00000000c003','9b159b15-0000-0000-0000-000000000003',
   'Unlimited','recurring', 250000, 'CZK', 'month', null, 'active');
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on) values
  ('9b159b15-0000-0000-0000-00000000c101','9b159b15-0000-0000-0000-000000000001',
   '9b159b15-0000-0000-0000-00000000f001','9b159b15-0000-0000-0000-00000000c001','active',250000,'CZK', current_date - 60),
  ('9b159b15-0000-0000-0000-00000000c103','9b159b15-0000-0000-0000-000000000003',
   '9b159b15-0000-0000-0000-00000000f003','9b159b15-0000-0000-0000-00000000c003','active',250000,'CZK', current_date - 60);

-- THE STUDIO'S MONTHS. m0 = this month, m1 = next, m2 = the one after, each
-- from the studio's own clock.
select set_config('t.a_m0', (date_trunc('month', now() at time zone 'Europe/Prague'))::date::text, false);
select set_config('t.a_m1', (date_trunc('month', now() at time zone 'Europe/Prague') + interval '1 month')::date::text, false);
select set_config('t.a_m2', (date_trunc('month', now() at time zone 'Europe/Prague') + interval '2 month')::date::text, false);
select set_config('t.b_m2', (date_trunc('month', now() at time zone 'Asia/Manila')  + interval '2 month')::date::text, false);
select set_config('t.c_m1', current_setting('t.a_m1'), false);

-- A class at studio-local wall time, for the fixtures below.
create or replace function t_at(p_tz text, p_day date, p_time time) returns timestamptz
language sql immutable as $$ select (p_day + p_time) at time zone p_tz $$;

-- Studio A, NEXT month: Ana 3 (one week), Bo 2, Cai 1, one open shift. The
-- three of Ana's sit inside one studio week so instructor_week() can count them.
select set_config('t.a_week', (studio_week_start('9b159b15-0000-0000-0000-000000000001',
  current_setting('t.a_m1')::date + 10))::text, false);
insert into class_occurrences
  (id, studio_id, location_id, class_type_id, room_id, name, capacity, instructor_id, starts_at, ends_at, status)
values
  -- Ana, three in one week
  ('9b159b15-0000-0000-0000-00000000a101','9b159b15-0000-0000-0000-000000000001','9b159b15-0000-0000-0000-00000000000a',
   '9b159b15-0000-0000-0000-00000000cc01','9b159b15-0000-0000-0000-00000000ee01','Reformer',10,'9b159b15-0000-0000-0000-00000000d101',
   t_at('Europe/Prague', current_setting('t.a_week')::date + 1, '07:00'), t_at('Europe/Prague', current_setting('t.a_week')::date + 1, '07:50'), 'scheduled'),
  ('9b159b15-0000-0000-0000-00000000a102','9b159b15-0000-0000-0000-000000000001','9b159b15-0000-0000-0000-00000000000a',
   '9b159b15-0000-0000-0000-00000000cc01','9b159b15-0000-0000-0000-00000000ee01','Reformer',10,'9b159b15-0000-0000-0000-00000000d101',
   t_at('Europe/Prague', current_setting('t.a_week')::date + 2, '07:00'), t_at('Europe/Prague', current_setting('t.a_week')::date + 2, '07:50'), 'scheduled'),
  ('9b159b15-0000-0000-0000-00000000a103','9b159b15-0000-0000-0000-000000000001','9b159b15-0000-0000-0000-00000000000a',
   '9b159b15-0000-0000-0000-00000000cc01','9b159b15-0000-0000-0000-00000000ee01','Reformer',10,'9b159b15-0000-0000-0000-00000000d101',
   t_at('Europe/Prague', current_setting('t.a_week')::date + 3, '07:00'), t_at('Europe/Prague', current_setting('t.a_week')::date + 3, '07:50'), 'scheduled'),
  -- Bo: the NEAR class (day 5, inside a 45-day window) and the FAR one (day 28, outside it)
  ('9b159b15-0000-0000-0000-00000000a104','9b159b15-0000-0000-0000-000000000001','9b159b15-0000-0000-0000-00000000000a',
   '9b159b15-0000-0000-0000-00000000cc01','9b159b15-0000-0000-0000-00000000ee01','Reformer Near',10,'9b159b15-0000-0000-0000-00000000d102',
   t_at('Europe/Prague', current_setting('t.a_m1')::date + 4, '18:00'), t_at('Europe/Prague', current_setting('t.a_m1')::date + 4, '18:50'), 'scheduled'),
  ('9b159b15-0000-0000-0000-00000000a105','9b159b15-0000-0000-0000-000000000001','9b159b15-0000-0000-0000-00000000000a',
   '9b159b15-0000-0000-0000-00000000cc01','9b159b15-0000-0000-0000-00000000ee01','Reformer Far',10,'9b159b15-0000-0000-0000-00000000d102',
   t_at('Europe/Prague', current_setting('t.a_m1')::date + 27, '18:00'), t_at('Europe/Prague', current_setting('t.a_m1')::date + 27, '18:50'), 'scheduled'),
  -- Cai, no login
  ('9b159b15-0000-0000-0000-00000000a106','9b159b15-0000-0000-0000-000000000001','9b159b15-0000-0000-0000-00000000000a',
   '9b159b15-0000-0000-0000-00000000cc01','9b159b15-0000-0000-0000-00000000ee01','Reformer',10,'9b159b15-0000-0000-0000-00000000d103',
   t_at('Europe/Prague', current_setting('t.a_m1')::date + 8, '12:00'), t_at('Europe/Prague', current_setting('t.a_m1')::date + 8, '12:50'), 'scheduled'),
  -- an open shift, for the engine
  ('9b159b15-0000-0000-0000-00000000a107','9b159b15-0000-0000-0000-000000000001','9b159b15-0000-0000-0000-00000000000a',
   '9b159b15-0000-0000-0000-00000000cc01','9b159b15-0000-0000-0000-00000000ee01','Reformer Open',10,null,
   t_at('Europe/Prague', current_setting('t.a_m1')::date + 9, '12:00'), t_at('Europe/Prague', current_setting('t.a_m1')::date + 9, '12:50'), 'scheduled'),
  -- Studio A, the month AFTER next: one class Mia is about to book into
  ('9b159b15-0000-0000-0000-00000000a201','9b159b15-0000-0000-0000-000000000001','9b159b15-0000-0000-0000-00000000000a',
   '9b159b15-0000-0000-0000-00000000cc01','9b159b15-0000-0000-0000-00000000ee01','Reformer Later',10,'9b159b15-0000-0000-0000-00000000d101',
   t_at('Europe/Prague', current_setting('t.a_m2')::date + 2, '09:00'), t_at('Europe/Prague', current_setting('t.a_m2')::date + 2, '09:50'), 'scheduled'),
  -- Studio B, the month after next: Bel
  ('9b159b15-0000-0000-0000-00000000b201','9b159b15-0000-0000-0000-000000000002','9b159b15-0000-0000-0000-00000000000b',
   '9b159b15-0000-0000-0000-00000000cc02','9b159b15-0000-0000-0000-00000000ee02','Manila Mat',10,'9b159b15-0000-0000-0000-00000000d201',
   t_at('Asia/Manila', current_setting('t.b_m2')::date + 2, '07:00'), t_at('Asia/Manila', current_setting('t.b_m2')::date + 2, '07:50'), 'scheduled'),
  -- Studio C, next month: the same shape as A and the switch OFF
  ('9b159b15-0000-0000-0000-00000000c301','9b159b15-0000-0000-0000-000000000003','9b159b15-0000-0000-0000-00000000000c',
   '9b159b15-0000-0000-0000-00000000cc03','9b159b15-0000-0000-0000-00000000ee03','Reformer',10,'9b159b15-0000-0000-0000-00000000d301',
   t_at('Europe/Prague', current_setting('t.c_m1')::date + 4, '18:00'), t_at('Europe/Prague', current_setting('t.c_m1')::date + 4, '18:50'), 'scheduled'),
  ('9b159b15-0000-0000-0000-00000000c302','9b159b15-0000-0000-0000-000000000003','9b159b15-0000-0000-0000-00000000000c',
   '9b159b15-0000-0000-0000-00000000cc03','9b159b15-0000-0000-0000-00000000ee03','Reformer Open',10,null,
   t_at('Europe/Prague', current_setting('t.c_m1')::date + 9, '12:00'), t_at('Europe/Prague', current_setting('t.c_m1')::date + 9, '12:50'), 'scheduled');

-- Mia is booked into the month after next BEFORE the switch goes on. That is
-- the promise a switch-on must not withdraw.
set role authenticated;
select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000e1',false);
select set_config('request.jwt.claims', null, false);
-- 45-day window: day 2 of the month after next may be outside it, so the desk
-- books her with an override — the booking is what matters, not the path.
reset role;
select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000a4',false);
set role authenticated;
select expect_text('the desk books Mia into the month after next (override, window may be closed)',
  (book_class('9b159b15-0000-0000-0000-00000000a201','9b159b15-0000-0000-0000-00000000f001','staff',
              'pre-switch fixture')).status::text, 'booked');
reset role;

-- =============================================================================
-- 1. THE SWITCH, AND WHAT TURNING IT ON MAY NOT HIDE
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000a2',false);  -- Ana
select expect_raises('an instructor cannot turn publication on',
  $$ select set_publication_enabled('9b159b15-0000-0000-0000-000000000001', true) $$, 'PT403');

select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000a1',false);  -- owner
select set_config('t.on', (select set_publication_enabled('9b159b15-0000-0000-0000-000000000001', true)::text), false);
select expect_true('the owner turns it on', (current_setting('t.on')::jsonb ->> 'enabled')::boolean);
select expect_num('...and two months are published on the way: this one, and the one Mia is booked into',
  jsonb_array_length(current_setting('t.on')::jsonb -> 'auto_published'), 2);
select expect_true('...this month because it has already started',
  exists (select 1 from jsonb_array_elements(current_setting('t.on')::jsonb -> 'auto_published') x
           where (x ->> 'month')::date = current_setting('t.a_m0')::date
             and x ->> 'why' = 'it has already started'));
select expect_true('...the other because members have already booked into it',
  exists (select 1 from jsonb_array_elements(current_setting('t.on')::jsonb -> 'auto_published') x
           where (x ->> 'month')::date = current_setting('t.a_m2')::date
             and x ->> 'why' = 'members have already booked into it'));
select expect_num('...and NEXT month, with nobody booked, stays a draft',
  (select count(*) from schedule_publications
    where studio_id='9b159b15-0000-0000-0000-000000000001' and month = current_setting('t.a_m1')::date), 0);
select expect_num('auto-publishing emailed nobody',
  (select count(*) from notifications where studio_id='9b159b15-0000-0000-0000-000000000001'
      and template_key = 'month_roster'), 0);
select expect_true('...and the rows say they were automatic',
  (select bool_and(auto) from schedule_publications where studio_id='9b159b15-0000-0000-0000-000000000001'));

-- =============================================================================
-- 2. A DRAFT MONTH IS INVISIBLE AND UNBOOKABLE TO MEMBERS
-- =============================================================================
select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000e1',false);  -- Mia
select expect_num('Mia sees no class in the draft month',
  (select count(*) from class_occurrences
    where studio_id='9b159b15-0000-0000-0000-000000000001'
      and starts_at >= t_at('Europe/Prague', current_setting('t.a_m1')::date, '00:00')
      and starts_at <  t_at('Europe/Prague', current_setting('t.a_m2')::date, '00:00')), 0);
select expect_num('...and sees the auto-published month she is booked into',
  (select count(*) from class_occurrences
    where id = '9b159b15-0000-0000-0000-00000000a201'), 1);
select expect_text('booking the NEAR draft class — inside her window — is refused for the true reason',
  (book_class('9b159b15-0000-0000-0000-00000000a104','9b159b15-0000-0000-0000-00000000f001','member')).failure_reason,
  'month_not_published');
select expect_text('booking the FAR draft class — outside her window too — is ALSO refused for publication first',
  (book_class('9b159b15-0000-0000-0000-00000000a105','9b159b15-0000-0000-0000-00000000f001','member')).failure_reason,
  'month_not_published');
select expect_num('...and nothing was written',
  (select count(*) from bookings where member_id='9b159b15-0000-0000-0000-00000000f001'
      and occurrence_id in ('9b159b15-0000-0000-0000-00000000a104','9b159b15-0000-0000-0000-00000000a105')), 0);

-- The horizon the member app draws from.
select set_config('t.hz', (select timetable_horizon('9b159b15-0000-0000-0000-000000000001')::text), false);
select expect_true('the horizon says publication is on', (current_setting('t.hz')::jsonb ->> 'enabled')::boolean);
select expect_text('...published through the END OF THIS MONTH, because next month breaks the run even though the one after is out',
  current_setting('t.hz')::jsonb ->> 'published_through',
  ((current_setting('t.a_m1')::date - 1))::text);
select expect_text('...and names next month as the first draft',
  current_setting('t.hz')::jsonb ->> 'next_unpublished', current_setting('t.a_m1'));

-- The desk, with a reason, may pencil somebody into a draft — recorded as such.
select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000a4',false);  -- desk
select set_config('t.ov', (select (book_class('9b159b15-0000-0000-0000-00000000a106','9b159b15-0000-0000-0000-00000000f001','staff',
  'she asked at the counter')).booking_id::text), false);
select expect_true('the desk can book into a draft with a reason', current_setting('t.ov') <> '');
select expect_true('...and the booking records that publication was bypassed',
  (select 'month_not_published' = any(overridden_rules) from bookings where id = current_setting('t.ov')::uuid));
reset role;
delete from bookings where id = current_setting('t.ov')::uuid;
update class_occurrences set booked_count = 0 where id = '9b159b15-0000-0000-0000-00000000a106';

-- =============================================================================
-- 3. BEFORE PUBLICATION, INSTRUCTORS SEE NOTHING
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000a2',false);  -- Ana
select expect_num('Ana cannot read a draft-month class directly',
  (select count(*) from class_occurrences where id in
     ('9b159b15-0000-0000-0000-00000000a101','9b159b15-0000-0000-0000-00000000a102','9b159b15-0000-0000-0000-00000000a103')), 0);
select expect_num('...her portal week in the draft month is empty',
  jsonb_array_length(instructor_week('9b159b15-0000-0000-0000-00000000d101',
    current_setting('t.a_week')::date, current_setting('t.a_week')::date + 6) -> 'classes'), 0);
select expect_num('...the staff-app week (migration 067) agrees',
  (instructor_week('9b159b15-0000-0000-0000-00000000d101', current_setting('t.a_week')::date) ->> 'unanswered')::bigint, 0);
select expect_raises('...and the roster of a draft class is refused BY ID',
  $$ select instructor_roster('9b159b15-0000-0000-0000-00000000a101') $$, 'PT403');
select expect_num('...the open shift in the draft month is not on the board',
  (select count(*) from class_occurrences where id = '9b159b15-0000-0000-0000-00000000a107'), 0);
select expect_num('...while she CAN see her class in the auto-published month',
  (select count(*) from class_occurrences where id = '9b159b15-0000-0000-0000-00000000a201'), 1);
select expect_num('confirming the week confirms nothing in a draft',
  (confirm_week('9b159b15-0000-0000-0000-00000000d101', current_setting('t.a_week')::date) ->> 'confirmed')::bigint, 0);

-- The desk sees the draft — that is who is building it.
select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000a4',false);
select expect_num('front desk reads every class in the draft month',
  (select count(*) from class_occurrences
    where studio_id='9b159b15-0000-0000-0000-000000000001'
      and starts_at >= t_at('Europe/Prague', current_setting('t.a_m1')::date, '00:00')
      and starts_at <  t_at('Europe/Prague', current_setting('t.a_m2')::date, '00:00')), 7);

-- The ENGINE assigns into the draft and tells nobody.
select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000a1',false);  -- owner
select set_config('t.run', (select assign_instructors('9b159b15-0000-0000-0000-000000000001',
  current_setting('t.a_m1')::date + 9, current_setting('t.a_m1')::date + 9)::text), false);
select expect_num('the engine fills the open shift in the draft month',
  (current_setting('t.run')::jsonb ->> 'assigned')::bigint, 1);
reset role;
select expect_num('...and queues NO instructor_assigned notice for it',
  (select count(*) from notifications where template_key = 'instructor_assigned'
      and dedupe_key like 'instructor_assigned:9b159b15-0000-0000-0000-00000000a107:%'), 0);
select expect_num('...nor for the week-confirmation ask, which skips draft months',
  (select count(*) from notifications where studio_id='9b159b15-0000-0000-0000-000000000001'
      and template_key = 'week_confirm_ask'), 0);

-- The flex sweep must not decide a class nobody was allowed to book.
update studio_settings set flex_enabled = true where studio_id = '9b159b15-0000-0000-0000-000000000001';
update class_occurrences set flex = true, minimum_bookings = 1
 where id in ('9b159b15-0000-0000-0000-00000000a104', '9b159b15-0000-0000-0000-00000000a201');
set role authenticated;
select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000a1',false);
select expect_num('a flex class in the PUBLISHED month is pending a decision',
  (select count(*) from commitment_pending('9b159b15-0000-0000-0000-000000000001')
    where occ_id = '9b159b15-0000-0000-0000-00000000a201'), 1);
select expect_num('...and the one in the DRAFT month is not — nobody could book it',
  (select count(*) from commitment_pending('9b159b15-0000-0000-0000-000000000001')
    where occ_id = '9b159b15-0000-0000-0000-00000000a104'), 0);
reset role;
update class_occurrences set flex = false, minimum_bookings = null
 where id in ('9b159b15-0000-0000-0000-00000000a104', '9b159b15-0000-0000-0000-00000000a201');

-- =============================================================================
-- 4. PUBLISHING
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000a2',false);  -- Ana
select expect_raises('an instructor cannot publish',
  $$ select publish_month('9b159b15-0000-0000-0000-000000000001', current_setting('t.a_m1')::date) $$, 'PT403');
select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000a4',false);  -- desk
select expect_raises('nor can front desk',
  $$ select publish_month('9b159b15-0000-0000-0000-000000000001', current_setting('t.a_m1')::date) $$, 'PT403');

select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000a1',false);  -- owner
select set_config('t.pv', (select publish_month_preview('9b159b15-0000-0000-0000-000000000001',
  current_setting('t.a_m1')::date + 15)::text), false);   -- any day in the month will do
select expect_false('the preview says next month is not published', (current_setting('t.pv')::jsonb ->> 'published')::boolean);
select expect_num('...seven classes', (current_setting('t.pv')::jsonb ->> 'classes')::bigint, 7);
select expect_num('...none still unstaffed, because the engine filled the hole', (current_setting('t.pv')::jsonb ->> 'open_shifts')::bigint, 0);
select expect_num('...three instructors affected', jsonb_array_length(current_setting('t.pv')::jsonb -> 'instructors'), 3);
select expect_num('...and the classes each is down for add up to the seven',
  (select sum((x ->> 'classes')::int)::bigint from jsonb_array_elements(current_setting('t.pv')::jsonb -> 'instructors') x), 7);
select expect_num('...Cai with his one',
  (select (x ->> 'classes')::bigint from jsonb_array_elements(current_setting('t.pv')::jsonb -> 'instructors') x where x ->> 'name' = 'Cai'), 1);
select expect_false('...and Cai marked as somebody no email can reach',
  (select (x ->> 'reachable')::boolean from jsonb_array_elements(current_setting('t.pv')::jsonb -> 'instructors') x where x ->> 'name' = 'Cai'));
select expect_num('previewing wrote nothing',
  (select count(*) from schedule_publications where studio_id='9b159b15-0000-0000-0000-000000000001'
      and month = current_setting('t.a_m1')::date), 0);

-- A month with a hole publishes, with the hole on the record.
reset role;
update class_occurrences set instructor_id = null where id = '9b159b15-0000-0000-0000-00000000a107';
set role authenticated;
select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000a1',false);

select expect_raises('last month cannot be published — it is history whatever anybody presses',
  $$ select publish_month('9b159b15-0000-0000-0000-000000000001', (current_setting('t.a_m0')::date - 1)) $$, 'PT409');

-- TWO STUDIOS, DIFFERENT MONTHS, ONE RUN.
select set_config('t.pub_a', (select publish_month('9b159b15-0000-0000-0000-000000000001', current_setting('t.a_m1')::date)::text), false);
select set_config('t.pub_b', (select publish_month('9b159b15-0000-0000-0000-000000000002', current_setting('t.b_m2')::date)::text), false);

select expect_true('A''s month is published', (current_setting('t.pub_a')::jsonb ->> 'published')::boolean);
select expect_false('...and it was not already', (current_setting('t.pub_a')::jsonb ->> 'already_published')::boolean);
select expect_num('...with the hole recorded', (current_setting('t.pub_a')::jsonb ->> 'open_shifts')::bigint, 1);
select expect_num('...two instructors emailed', (current_setting('t.pub_a')::jsonb ->> 'notified')::bigint, 2);
select expect_text('...and the one with no login NAMED rather than silently skipped',
  current_setting('t.pub_a')::jsonb -> 'unreachable' -> 0 ->> 'name', 'Cai');
select expect_true('B''s month is published in the same run', (current_setting('t.pub_b')::jsonb ->> 'published')::boolean);
select expect_num('...one instructor emailed there', (current_setting('t.pub_b')::jsonb ->> 'notified')::bigint, 1);
reset role;

select expect_num('exactly three roster emails across both studios',
  (select count(*) from notifications where template_key = 'month_roster'
      and studio_id in ('9b159b15-0000-0000-0000-000000000001','9b159b15-0000-0000-0000-000000000002')), 3);
select expect_num('Ana''s lists her three classes',
  (select array_length(string_to_array(payload ->> 'roster', E'\n'), 1) from notifications
    where template_key = 'month_roster' and user_id = '9b159b15-0000-0000-0000-0000000000a2'), 3);
select expect_num('Bo''s lists his two (the open one went back to being open)',
  (select array_length(string_to_array(payload ->> 'roster', E'\n'), 1) from notifications
    where template_key = 'month_roster' and user_id = '9b159b15-0000-0000-0000-0000000000a3'), 2);
select expect_true('...and Ana''s roster names none of Bo''s classes',
  (select payload ->> 'roster' not like '%Reformer Near%' and payload ->> 'roster' not like '%Reformer Far%'
     from notifications where template_key = 'month_roster' and user_id = '9b159b15-0000-0000-0000-0000000000a2'));
select expect_true('Bel''s roster is B''s class and nothing of A''s',
  (select payload ->> 'roster' like '%Manila Mat%' and payload ->> 'roster' not like '%Reformer%'
     from notifications where template_key = 'month_roster' and user_id = '9b159b15-0000-0000-0000-0000000000b2'));
select expect_true('the roster carries the studio''s wall-clock time',
  (select payload ->> 'roster' like '%07:00%' from notifications
    where template_key = 'month_roster' and user_id = '9b159b15-0000-0000-0000-0000000000a2'));
select expect_num('three roster rows for A: Ana and Bo notified, Cai not',
  (select count(*) from roster_confirmations where studio_id='9b159b15-0000-0000-0000-000000000001'
      and month = current_setting('t.a_m1')::date), 3);
select expect_true('...Cai''s row says nobody could tell him',
  (select notified_at is null from roster_confirmations
    where instructor_id='9b159b15-0000-0000-0000-00000000d103' and month = current_setting('t.a_m1')::date));
select expect_num('the publish is audited',
  (select count(*) from audit_logs where studio_id='9b159b15-0000-0000-0000-000000000001' and action = 'month.published'), 1);

-- REPUBLISHING IS A NO-OP, NOT A SECOND ROUND OF EMAILS.
set role authenticated;
select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000a1',false);
select set_config('t.again', (select publish_month('9b159b15-0000-0000-0000-000000000001', current_setting('t.a_m1')::date)::text), false);
select expect_true('publishing again says it already was', (current_setting('t.again')::jsonb ->> 'already_published')::boolean);
select expect_num('...and sent nobody anything', (current_setting('t.again')::jsonb ->> 'notified')::bigint, 0);
reset role;
select expect_num('...still three roster emails',
  (select count(*) from notifications where template_key = 'month_roster'
      and studio_id in ('9b159b15-0000-0000-0000-000000000001','9b159b15-0000-0000-0000-000000000002')), 3);
select expect_num('...and still one publication row', (select count(*) from schedule_publications
    where studio_id='9b159b15-0000-0000-0000-000000000001' and month = current_setting('t.a_m1')::date), 1);

-- =============================================================================
-- 5. AFTER PUBLICATION: VISIBLE, BOOKABLE, AND THE WINDOW MEANS WHAT IT DID
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000e1',false);  -- Mia
select expect_num('Mia now sees the month',
  (select count(*) from class_occurrences
    where studio_id='9b159b15-0000-0000-0000-000000000001'
      and starts_at >= t_at('Europe/Prague', current_setting('t.a_m1')::date, '00:00')
      and starts_at <  t_at('Europe/Prague', current_setting('t.a_m2')::date, '00:00')), 7);
select expect_text('the NEAR class books',
  (book_class('9b159b15-0000-0000-0000-00000000a104','9b159b15-0000-0000-0000-00000000f001','member')).status::text, 'booked');
select expect_text('the FAR class is refused by the WINDOW now, which is the true reason left',
  (book_class('9b159b15-0000-0000-0000-00000000a105','9b159b15-0000-0000-0000-00000000f001','member')).failure_reason,
  'outside_booking_window');
select expect_text('...and the horizon now runs to the end of the month after next',
  timetable_horizon('9b159b15-0000-0000-0000-000000000001') ->> 'published_through',
  ((current_setting('t.a_m2')::date + interval '1 month' - interval '1 day')::date)::text);

select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000a2',false);  -- Ana
select expect_num('Ana''s week is on her schedule',
  jsonb_array_length(instructor_week('9b159b15-0000-0000-0000-00000000d101',
    current_setting('t.a_week')::date, current_setting('t.a_week')::date + 6) -> 'classes'), 3);
select expect_true('...and the roster of one of them opens',
  instructor_roster('9b159b15-0000-0000-0000-00000000a101') is not null);
select expect_num('...and the open shift is on the board',
  (select count(*) from class_occurrences where id = '9b159b15-0000-0000-0000-00000000a107'), 1);

-- =============================================================================
-- 6. A CLASS ADDED AFTER PUBLICATION IS BOOKABLE AND ITS INSTRUCTOR IS TOLD
-- =============================================================================
select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000a1',false);  -- owner
select set_config('t.new', (select create_occurrence(
  '9b159b15-0000-0000-0000-000000000001', '9b159b15-0000-0000-0000-00000000cc01',
  t_at('Europe/Prague', current_setting('t.a_m1')::date + 5, '10:00'),
  t_at('Europe/Prague', current_setting('t.a_m1')::date + 5, '10:50'),
  '9b159b15-0000-0000-0000-00000000d102', '9b159b15-0000-0000-0000-00000000ee01', null)::text), false);
select expect_true('a class is added to the published month', (current_setting('t.new')::jsonb ->> 'ok')::boolean);
reset role;
select expect_num('...and Bo is told about it, on its own',
  (select count(*) from notifications where template_key = 'instructor_assigned'
      and dedupe_key like 'instructor_assigned:' || (current_setting('t.new')::jsonb ->> 'occurrence_id') || ':%'), 1);
set role authenticated;
select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000e1',false);  -- Mia
select expect_text('...and Mia books it at once',
  (book_class((current_setting('t.new')::jsonb ->> 'occurrence_id')::uuid,'9b159b15-0000-0000-0000-00000000f001','member')).status::text, 'booked');

-- The engine, run again for the hole that is left, tells the person it picks.
select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000a1',false);
select set_config('t.run2', (select assign_instructors('9b159b15-0000-0000-0000-000000000001',
  current_setting('t.a_m1')::date + 9, current_setting('t.a_m1')::date + 9)::text), false);
select expect_num('the engine fills the hole in the now-published month', (current_setting('t.run2')::jsonb ->> 'assigned')::bigint, 1);
reset role;
select expect_num('...and THIS time the instructor is told',
  (select count(*) from notifications where template_key = 'instructor_assigned'
      and dedupe_key like 'instructor_assigned:9b159b15-0000-0000-0000-00000000a107:%'), 1);

-- Reassigning by drag tells the new person. And the refusal that used to write:
-- Bo's stated dates end before the class, so moving it to him is refused — and
-- the class must still be Ana's afterwards.
set role authenticated;
select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000a1',false);
select set_config('t.mv', (select move_occurrence('9b159b15-0000-0000-0000-00000000a102',
  p_instructor_id => '9b159b15-0000-0000-0000-00000000d102')::text), false);
select expect_true('a class in the published month is reassigned to Bo', (current_setting('t.mv')::jsonb ->> 'ok')::boolean);
reset role;
select expect_num('...and Bo hears about it',
  (select count(*) from notifications where template_key = 'instructor_assigned'
      and dedupe_key like 'instructor_assigned:9b159b15-0000-0000-0000-00000000a102:9b159b15-0000-0000-0000-00000000d102:%'), 1);

insert into instructor_availability (instructor_id, studio_id, day_of_week, starts_at_time, ends_at_time, effective_from, effective_to)
select '9b159b15-0000-0000-0000-00000000d102', '9b159b15-0000-0000-0000-000000000001', d, '06:00', '22:00',
       current_date - 365, current_setting('t.a_m1')::date - 1
  from generate_series(0, 6) d;
set role authenticated;
select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000a1',false);
select expect_text('moving Ana''s class to Bo is refused — his dates end before it',
  move_occurrence('9b159b15-0000-0000-0000-00000000a103', p_instructor_id => '9b159b15-0000-0000-0000-00000000d102') ->> 'reason',
  'outside_availability_dates');
reset role;
select expect_text('...AND THE CLASS IS STILL ANA''S. It was not, before migration 112 moved the check ahead of the write',
  (select instructor_id::text from class_occurrences where id = '9b159b15-0000-0000-0000-00000000a103'),
  '9b159b15-0000-0000-0000-00000000d101');
delete from instructor_availability where instructor_id = '9b159b15-0000-0000-0000-00000000d102';

-- =============================================================================
-- 7. NOTHING CAN TAKE A MONTH BACK
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000a1',false);
select expect_raises('the owner cannot delete a publication row',
  $$ delete from schedule_publications where studio_id='9b159b15-0000-0000-0000-000000000001' $$, '42501');
select expect_raises('...nor insert one by hand',
  $$ insert into schedule_publications (studio_id, month) values ('9b159b15-0000-0000-0000-000000000001', current_setting('t.a_m2')::date) $$, '42501');
select expect_raises('...nor write a confirmation row directly',
  $$ update roster_confirmations set confirmed_at = now() where studio_id='9b159b15-0000-0000-0000-000000000001' $$, '42501');
select expect_num('...but can read which months are out',
  (select count(*) from schedule_publications where studio_id='9b159b15-0000-0000-0000-000000000001'), 3);
select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000e1',false);  -- Mia
select expect_num('a member reads none of the publication table',
  (select count(*) from schedule_publications), 0);
reset role;

-- =============================================================================
-- 8. A STUDIO WITH PUBLICATION OFF BEHAVES EXACTLY AS TODAY
-- =============================================================================
-- Studio C has the same shape as A had before publishing and NO publication
-- rows anywhere. Everything below is what A could NOT do in section 2 and 3.
select expect_num('C has no publication rows at all',
  (select count(*) from schedule_publications where studio_id='9b159b15-0000-0000-0000-000000000003'), 0);
set role authenticated;
select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000e3',false);  -- Cleo
select expect_num('Cleo sees next month', (select count(*) from class_occurrences
    where studio_id='9b159b15-0000-0000-0000-000000000003'), 2);
select expect_text('...and books it',
  (book_class('9b159b15-0000-0000-0000-00000000c301','9b159b15-0000-0000-0000-00000000f003','member')).status::text, 'booked');
select expect_false('...and the horizon draws nothing', (timetable_horizon('9b159b15-0000-0000-0000-000000000003') ->> 'enabled')::boolean);
select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000c2',false);  -- Cy
select expect_num('Cy sees his class', (select count(*) from class_occurrences where id='9b159b15-0000-0000-0000-00000000c301'), 1);
select expect_true('...and its roster', instructor_roster('9b159b15-0000-0000-0000-00000000c301') is not null);
select expect_num('...and the open shift', (select count(*) from class_occurrences where id='9b159b15-0000-0000-0000-00000000c302'), 1);
select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000a1',false);  -- owner
select set_config('t.runc', (select assign_instructors('9b159b15-0000-0000-0000-000000000003',
  current_setting('t.c_m1')::date + 9, current_setting('t.c_m1')::date + 9)::text), false);
select expect_num('the engine fills C''s open shift', (current_setting('t.runc')::jsonb ->> 'assigned')::bigint, 1);
select expect_raises('and publishing at C is refused as a thing C does not do',
  $$ select publish_month('9b159b15-0000-0000-0000-000000000003', current_setting('t.c_m1')::date) $$, 'PT409');
reset role;
select expect_num('...and Cy is told, as he always was',
  (select count(*) from notifications where template_key = 'instructor_assigned'
      and dedupe_key like 'instructor_assigned:9b159b15-0000-0000-0000-00000000c302:%'), 1);

-- A hand-made class at C tells nobody, exactly as before this migration: the
-- new notice in create_occurrence() is behind the switch.
set role authenticated;
select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000a1',false);
select set_config('t.newc', (select create_occurrence(
  '9b159b15-0000-0000-0000-000000000003', '9b159b15-0000-0000-0000-00000000cc03',
  t_at('Europe/Prague', current_setting('t.c_m1')::date + 5, '10:00'),
  t_at('Europe/Prague', current_setting('t.c_m1')::date + 5, '10:50'),
  '9b159b15-0000-0000-0000-00000000d301', '9b159b15-0000-0000-0000-00000000ee03', null)::text), false);
reset role;
select expect_num('a class made by hand at C emails nobody — as it never did',
  (select count(*) from notifications where template_key = 'instructor_assigned'
      and dedupe_key like 'instructor_assigned:' || (current_setting('t.newc')::jsonb ->> 'occurrence_id') || ':%'), 0);


-- =============================================================================
-- 9. INSTRUCTORS CONFIRM THE MONTH — migration 113
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000a2',false);  -- Ana
select set_config('t.mine', (select my_month_roster('9b159b15-0000-0000-0000-00000000d101', current_setting('t.a_m1')::date)::text), false);
select expect_text('Ana''s month reads as unconfirmed', current_setting('t.mine')::jsonb ->> 'state', 'unconfirmed');
select expect_num('...with her two remaining classes (one went to Bo by drag)', (current_setting('t.mine')::jsonb ->> 'count')::bigint, 2);
select expect_true('...and says when the roster was sent', (current_setting('t.mine')::jsonb ->> 'notified_at') is not null);
select expect_raises('...and Bo''s month is not hers to read',
  $$ select my_month_roster('9b159b15-0000-0000-0000-00000000d102', current_setting('t.a_m1')::date) $$, 'PT403');
select expect_raises('...nor to confirm',
  $$ select confirm_month_roster('9b159b15-0000-0000-0000-00000000d102', current_setting('t.a_m1')::date) $$, 'PT403');
select expect_text('a DRAFT month reads as draft and lists nothing',
  my_month_roster('9b159b15-0000-0000-0000-00000000d101', current_setting('t.a_m2')::date + 40) ->> 'state', 'draft');
select expect_raises_saying('...and cannot be confirmed — BECAUSE it is a draft, not because it is empty',
  $$ select confirm_month_roster('9b159b15-0000-0000-0000-00000000d101', current_setting('t.a_m2')::date + 40) $$,
  'PT409', '%is not published%');

-- Flagging a class is the cover flow that already exists; confirming the rest
-- is not blocked by it.
select set_config('t.cov', (select request_cover('9b159b15-0000-0000-0000-00000000a101', 'dentist')::text), false);
select set_config('t.conf', (select confirm_month_roster('9b159b15-0000-0000-0000-00000000d101', current_setting('t.a_m1')::date)::text), false);
select expect_true('Ana confirms the month with one class flagged for cover', (current_setting('t.conf')::jsonb ->> 'ok')::boolean);
select expect_num('...and the result says how many she flagged', (current_setting('t.conf')::jsonb ->> 'cover_requested')::bigint, 1);
select expect_text('...and her month now reads confirmed',
  my_month_roster('9b159b15-0000-0000-0000-00000000d101', current_setting('t.a_m1')::date) ->> 'state', 'confirmed');
select expect_num('confirming the month confirmed NO week — the week is the check-in and stays separate',
  (select count(*) from class_occurrences where instructor_id = '9b159b15-0000-0000-0000-00000000d101'
      and instructor_confirmed_at is not null), 0);
select set_config('t.conf2', (select confirm_month_roster('9b159b15-0000-0000-0000-00000000d101', current_setting('t.a_m1')::date)::text), false);
select expect_text('confirming twice keeps the first timestamp',
  current_setting('t.conf2')::jsonb ->> 'confirmed_at', current_setting('t.conf')::jsonb ->> 'confirmed_at');

-- The studio sees who has and who has not.
select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000a1',false);  -- owner
select set_config('t.st', (select publish_month_preview('9b159b15-0000-0000-0000-000000000001', current_setting('t.a_m1')::date)::text), false);
select expect_true('the studio sees Ana confirmed, with one flagged',
  (select (x ->> 'confirmed_at') is not null and (x ->> 'cover_pending')::int = 1
     from jsonb_array_elements(current_setting('t.st')::jsonb -> 'instructors') x where x ->> 'name' = 'Ana'));
select expect_true('...and Bo sent and not confirmed',
  (select (x ->> 'notified_at') is not null and (x ->> 'confirmed_at') is null
     from jsonb_array_elements(current_setting('t.st')::jsonb -> 'instructors') x where x ->> 'name' = 'Bo'));
select expect_true('...and Cai never sent',
  (select (x ->> 'notified_at') is null
     from jsonb_array_elements(current_setting('t.st')::jsonb -> 'instructors') x where x ->> 'name' = 'Cai'));
-- The studio may record a yes given some other way.
select expect_true('the owner confirms Cai''s month for him',
  (confirm_month_roster('9b159b15-0000-0000-0000-00000000d103', current_setting('t.a_m1')::date) ->> 'ok')::boolean);
reset role;

-- =============================================================================
-- 10. THE BRIEF AND THE ACTION CENTRE
-- =============================================================================
-- Next month is 19-48 days away depending on today, so the studio's window is
-- widened to sixty: the assertion is about the rule, not about the calendar.
insert into insight_config (studio_id, key, value) values
  ('9b159b15-0000-0000-0000-000000000001', 'roster_unconfirmed_days', 60),
  ('9b159b15-0000-0000-0000-000000000001', 'month_unpublished_days', 60);
set role authenticated;
select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000a1',false);
select set_config('t.brief', (select generate_morning_brief('9b159b15-0000-0000-0000-000000000001')::text), false);
reset role;
select expect_num('Bo''s unconfirmed roster is a brief item',
  (select count(*) from ai_insights where studio_id='9b159b15-0000-0000-0000-000000000001'
      and type = 'month_roster_unconfirmed' and subject_id = '9b159b15-0000-0000-0000-00000000d102'), 1);
select expect_num('...Ana, who confirmed, is not', 
  (select count(*) from ai_insights where studio_id='9b159b15-0000-0000-0000-000000000001'
      and type = 'month_roster_unconfirmed' and subject_id = '9b159b15-0000-0000-0000-00000000d101'), 0);
select expect_num('...nor Cai, who was never sent one',
  (select count(*) from ai_insights where studio_id='9b159b15-0000-0000-0000-000000000001'
      and type = 'month_roster_unconfirmed' and subject_id = '9b159b15-0000-0000-0000-00000000d103'), 0);
select expect_true('...and the item opens the month on the publish screen',
  (select action_payload ->> 'href' = '/publish?m=' || to_char(current_setting('t.a_m1')::date, 'YYYY-MM')
     from ai_insights where studio_id='9b159b15-0000-0000-0000-000000000001' and type = 'month_roster_unconfirmed'));
select expect_num('every month with classes is published, so no month_unpublished item',
  (select count(*) from ai_insights where studio_id='9b159b15-0000-0000-0000-000000000001'
      and type = 'month_unpublished'), 0);
select expect_true('the opening sentence names the unconfirmed roster',
  (current_setting('t.brief')::jsonb ->> 'summary') like '%not confirmed next month%');

-- Now an unpublished month about to start: a class in the month after the
-- auto-published one, with nothing published there.
insert into class_occurrences
  (id, studio_id, location_id, class_type_id, room_id, name, capacity, instructor_id, starts_at, ends_at, status)
values
  ('9b159b15-0000-0000-0000-00000000a301','9b159b15-0000-0000-0000-000000000001','9b159b15-0000-0000-0000-00000000000a',
   '9b159b15-0000-0000-0000-00000000cc01','9b159b15-0000-0000-0000-00000000ee01','Reformer Far Off',10,'9b159b15-0000-0000-0000-00000000d101',
   t_at('Europe/Prague', (current_setting('t.a_m2')::date + interval '1 month')::date + 2, '09:00'),
   t_at('Europe/Prague', (current_setting('t.a_m2')::date + interval '1 month')::date + 2, '09:50'), 'scheduled');
update insight_config set value = 120 where studio_id = '9b159b15-0000-0000-0000-000000000001' and key = 'month_unpublished_days';
delete from ai_insights where studio_id = '9b159b15-0000-0000-0000-000000000001';
delete from morning_briefs where studio_id = '9b159b15-0000-0000-0000-000000000001';
set role authenticated;
select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000a1',false);
select set_config('t.brief2', (select generate_morning_brief('9b159b15-0000-0000-0000-000000000001')::text), false);
select set_config('t.tasks', (select dashboard_tasks('9b159b15-0000-0000-0000-000000000001')::text), false);
reset role;
select expect_num('an unpublished month inside the window is a brief item',
  (select count(*) from ai_insights where studio_id='9b159b15-0000-0000-0000-000000000001'
      and type = 'month_unpublished'), 1);
select expect_true('...ranked as urgent',
  (select severity = 'urgent' from ai_insights where studio_id='9b159b15-0000-0000-0000-000000000001' and type = 'month_unpublished'));
select expect_true('...and it LEADS the sentence',
  (current_setting('t.brief2')::jsonb ->> 'summary') like '%is not published%'
  and position('is not published' in (current_setting('t.brief2')::jsonb ->> 'summary'))
      < position('not confirmed' in (current_setting('t.brief2')::jsonb ->> 'summary')));
select expect_true('the action centre carries the unpublished month',
  exists (select 1 from jsonb_array_elements(current_setting('t.tasks')::jsonb -> 'tasks') t
           where t ->> 'key' = 'month_unpublished'));

-- And the studio that never publishes: nothing, whatever its calendar looks
-- like. Its window is widened too, so the SWITCH is the only thing standing
-- between its unpublished next month and a row — without this the month sat
-- outside the fortnight and the assertion passed with the switch check deleted.
insert into insight_config (studio_id, key, value) values
  ('9b159b15-0000-0000-0000-000000000003', 'month_unpublished_days', 120);
set role authenticated;
select set_config('request.jwt.claim.sub','9b159b15-0000-0000-0000-0000000000a1',false);
select set_config('t.briefc', (select generate_morning_brief('9b159b15-0000-0000-0000-000000000003')::text), false);
select set_config('t.tasksc', (select dashboard_tasks('9b159b15-0000-0000-0000-000000000003')::text), false);
reset role;
select expect_num('C gets no publication item in its brief',
  (select count(*) from ai_insights where studio_id='9b159b15-0000-0000-0000-000000000003'
      and type in ('month_unpublished', 'month_roster_unconfirmed')), 0);
select expect_false('...nor in its action centre',
  exists (select 1 from jsonb_array_elements(current_setting('t.tasksc')::jsonb -> 'tasks') t
           where t ->> 'key' in ('month_unpublished', 'rosters_unconfirmed')));

drop function t_at(text, date, time);
select 'publication suite finished' as done;
