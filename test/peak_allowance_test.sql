-- =============================================================================
-- Peak windows and the peak allowance — Decision 24, migrations 104/105/106
-- =============================================================================
-- UUID space 9eac, checked free. Run after `supabase db reset`.
--
-- THREE STUDIOS AGAIN, and again the middle one is the assertion that matters:
--
--   ONE   Manila. Peak on, windows drawn, Unlimited Monthly held to them.
--   TWO   Prague. Peak OFF, and windows drawn ANYWAY, so the switch is the only
--         thing standing between it and the feature.
--   THREE nothing configured at all.
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

create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then
    raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else
    raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null');
  end if;
end $$;

create or replace function expect_null_state(label text, actual jsonb)
returns void language plpgsql as $$
begin
  if actual is null then raise notice 'PASS  %  (got null)', label;
  else raise exception 'FAIL  %  expected null, got %', label, actual::text; end if;
end $$;

create or replace function expect_null(label text, actual text)
returns void language plpgsql as $$
begin
  if actual is null then raise notice 'PASS  %  (got null)', label;
  else raise exception 'FAIL  %  expected null, got %', label, actual; end if;
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

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('9eac9eac-0000-0000-0000-0000000000a1'),   -- owner of ONE and TWO and THREE
  ('9eac9eac-0000-0000-0000-0000000000a2'),   -- front desk, ONE
  ('9eac9eac-0000-0000-0000-0000000000a4'),   -- instructor, ONE
  ('9eac9eac-0000-0000-0000-0000000000a5'),   -- owner of an unrelated studio
  ('9eac9eac-0000-0000-0000-0000000000b1');   -- a member of ONE
insert into profiles (id, email) values
  ('9eac9eac-0000-0000-0000-0000000000a1','9eac-owner@example.com'),
  ('9eac9eac-0000-0000-0000-0000000000a2','9eac-desk@example.com'),
  ('9eac9eac-0000-0000-0000-0000000000a4','9eac-coach@example.com'),
  ('9eac9eac-0000-0000-0000-0000000000a5','9eac-stranger@example.com'),
  ('9eac9eac-0000-0000-0000-0000000000b1','9eac-m1@example.com');

-- Manila has no DST; Prague does. Both are needed and for different assertions.
insert into studios (id, name, slug, timezone, currency, status) values
  ('9eac9eac-0000-0000-0000-000000000001','Peak Manila','peak-mnl','Asia/Manila','PHP','active'),
  ('9eac9eac-0000-0000-0000-000000000002','Peak Prague','peak-prg','Europe/Prague','CZK','active'),
  ('9eac9eac-0000-0000-0000-000000000003','Plain Peak','peak-plain','Europe/Prague','CZK','active'),
  ('9eac9eac-0000-0000-0000-000000000009','Not Yours','peak-notyours','Europe/Prague','CZK','active');

insert into studio_settings (studio_id, peak_allowance_enabled) values
  ('9eac9eac-0000-0000-0000-000000000001', true),
  ('9eac9eac-0000-0000-0000-000000000002', false),
  ('9eac9eac-0000-0000-0000-000000000003', false),
  ('9eac9eac-0000-0000-0000-000000000009', false);

insert into locations (id, studio_id, name, is_primary) values
  ('9eac9eac-0000-0000-0000-00000000000c','9eac9eac-0000-0000-0000-000000000001','Main',true),
  ('9eac9eac-0000-0000-0000-00000000000d','9eac9eac-0000-0000-0000-000000000002','Main',true),
  ('9eac9eac-0000-0000-0000-00000000000e','9eac9eac-0000-0000-0000-000000000003','Main',true);
insert into studio_staff (studio_id, user_id, email, role) values
  ('9eac9eac-0000-0000-0000-000000000001','9eac9eac-0000-0000-0000-0000000000a1','9eac-owner@example.com','owner'),
  ('9eac9eac-0000-0000-0000-000000000001','9eac9eac-0000-0000-0000-0000000000a2','9eac-desk@example.com','front_desk'),
  ('9eac9eac-0000-0000-0000-000000000001','9eac9eac-0000-0000-0000-0000000000a4','9eac-coach@example.com','instructor'),
  ('9eac9eac-0000-0000-0000-000000000002','9eac9eac-0000-0000-0000-0000000000a1','9eac-owner2@example.com','owner'),
  ('9eac9eac-0000-0000-0000-000000000003','9eac9eac-0000-0000-0000-0000000000a1','9eac-owner3@example.com','owner'),
  ('9eac9eac-0000-0000-0000-000000000009','9eac9eac-0000-0000-0000-0000000000a5','9eac-stranger@example.com','owner');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('9eac9eac-0000-0000-0000-00000000ee01','9eac9eac-0000-0000-0000-000000000001',
   '9eac9eac-0000-0000-0000-00000000000c','Studio A',10),
  ('9eac9eac-0000-0000-0000-00000000ee02','9eac9eac-0000-0000-0000-000000000002',
   '9eac9eac-0000-0000-0000-00000000000d','Studio A',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('9eac9eac-0000-0000-0000-00000000cc01','9eac9eac-0000-0000-0000-000000000001','Reformer',50,10),
  ('9eac9eac-0000-0000-0000-00000000cc02','9eac9eac-0000-0000-0000-000000000002','Reformer',50,10),
  ('9eac9eac-0000-0000-0000-00000000cc03','9eac9eac-0000-0000-0000-000000000003','Reformer',50,10);
insert into members (id, studio_id, user_id, first_name, last_name, email, joined_on, status, waiver_signed_at) values
  ('9eac9eac-0000-0000-0000-00000000dd01','9eac9eac-0000-0000-0000-000000000001',
   '9eac9eac-0000-0000-0000-0000000000b1','Ana','Reyes','9eac-m1@example.com', current_date - 30,'active', now());

-- Reform Collective's own two windows, every day of the week.
insert into peak_windows (studio_id, day_of_week, starts_at, ends_at)
select '9eac9eac-0000-0000-0000-000000000001', d, time '07:00', time '09:00'
  from generate_series(0, 6) d;
insert into peak_windows (studio_id, day_of_week, starts_at, ends_at)
select '9eac9eac-0000-0000-0000-000000000001', d, time '17:00', time '19:00'
  from generate_series(0, 6) d;

-- Studio TWO draws the SAME windows with the switch off.
insert into peak_windows (studio_id, day_of_week, starts_at, ends_at)
select '9eac9eac-0000-0000-0000-000000000002', d, time '17:00', time '19:00'
  from generate_series(0, 6) d;

-- =============================================================================
-- 1. THE BOUNDARY. A class is peak if its SCHEDULED START is inside a window.
--
-- Half-open, and both ends are asserted: 16:55 is off-peak against a 17:00
-- window, and a 19:00 class is off-peak against one that ends at 19:00. The
-- studio is protecting the hours, not the classes that brush them.
-- =============================================================================
-- Built from a DATE, then converted. `generate_series` over dates yields
-- timestamptz, and `(d + time) at time zone tz` on one converts the wrong way —
-- the trap that once put a fixture's classes at 23:00.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               capacity, starts_at, ends_at, status)
select ('9eac9eac-0000-0000-0000-00000000f0' || lpad(n::text, 2, '0'))::uuid,
       '9eac9eac-0000-0000-0000-000000000001',
       '9eac9eac-0000-0000-0000-00000000000c','9eac9eac-0000-0000-0000-00000000cc01',
       null, 'Reformer', 10,
       ((current_date + 7)::date + t) at time zone 'Asia/Manila',
       ((current_date + 7)::date + t + interval '50 minutes') at time zone 'Asia/Manila',
       'scheduled'
  from (values (1, time '06:59'), (2, time '07:00'), (3, time '08:30'),
               (4, time '09:00'), (5, time '16:55'), (6, time '17:00'),
               (7, time '18:59'), (8, time '19:00'), (9, time '12:00')) v(n, t);

select expect_false('06:59 is off-peak against a 07:00 window',
  occurrence_is_peak('9eac9eac-0000-0000-0000-00000000f001'));
select expect_true('07:00 is peak — the window starts closed',
  occurrence_is_peak('9eac9eac-0000-0000-0000-00000000f002'));
select expect_true('08:30 is peak',
  occurrence_is_peak('9eac9eac-0000-0000-0000-00000000f003'));
select expect_false('09:00 is off-peak — the window ends open',
  occurrence_is_peak('9eac9eac-0000-0000-0000-00000000f004'));
select expect_false('16:55 against a 17:00 window is off-peak',
  occurrence_is_peak('9eac9eac-0000-0000-0000-00000000f005'));
select expect_true('17:00 exactly is peak',
  occurrence_is_peak('9eac9eac-0000-0000-0000-00000000f006'));
select expect_true('18:59 is peak',
  occurrence_is_peak('9eac9eac-0000-0000-0000-00000000f007'));
select expect_false('19:00 is off-peak — a class starting as the window ends is not in it',
  occurrence_is_peak('9eac9eac-0000-0000-0000-00000000f008'));
select expect_false('midday is off-peak, with a window either side of it',
  occurrence_is_peak('9eac9eac-0000-0000-0000-00000000f009'));

-- =============================================================================
-- 2. THE STUDIO'S OWN CLOCK, ACROSS A CLOCK CHANGE
--
-- 17:00 Prague is 17:00 Prague on both sides of the October change, and the two
-- classes are stored an hour apart in UTC. A window held as an offset rather
-- than a wall time would have moved the evening rush off the evening for half
-- the year.
-- =============================================================================
insert into peak_windows (studio_id, day_of_week, starts_at, ends_at)
select '9eac9eac-0000-0000-0000-000000000003', d, time '17:00', time '19:00'
  from generate_series(0, 6) d;

insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               capacity, starts_at, ends_at, status)
values
  ('9eac9eac-0000-0000-0000-00000000f101','9eac9eac-0000-0000-0000-000000000003',
   '9eac9eac-0000-0000-0000-00000000000e','9eac9eac-0000-0000-0000-00000000cc03', null, 'Summer side', 10,
   (date '2026-10-20' + time '17:00') at time zone 'Europe/Prague',
   (date '2026-10-20' + time '17:50') at time zone 'Europe/Prague','scheduled'),
  ('9eac9eac-0000-0000-0000-00000000f102','9eac9eac-0000-0000-0000-000000000003',
   '9eac9eac-0000-0000-0000-00000000000e','9eac9eac-0000-0000-0000-00000000cc03', null, 'Winter side', 10,
   (date '2026-11-03' + time '17:00') at time zone 'Europe/Prague',
   (date '2026-11-03' + time '17:50') at time zone 'Europe/Prague','scheduled'),
  -- Same day, one minute past the end of the window.
  ('9eac9eac-0000-0000-0000-00000000f103','9eac9eac-0000-0000-0000-000000000003',
   '9eac9eac-0000-0000-0000-00000000000e','9eac9eac-0000-0000-0000-00000000cc03', null, 'Just after', 10,
   (date '2026-11-03' + time '19:01') at time zone 'Europe/Prague',
   (date '2026-11-03' + time '19:51') at time zone 'Europe/Prague','scheduled');

select expect_true('(the two 17:00 Prague classes really are an hour apart in UTC)',
  (select count(distinct extract(hour from starts_at at time zone 'UTC')) = 2
     from class_occurrences
    where id in ('9eac9eac-0000-0000-0000-00000000f101','9eac9eac-0000-0000-0000-00000000f102')));
select expect_true('17:00 before the clock change is peak',
  occurrence_is_peak('9eac9eac-0000-0000-0000-00000000f101'));
select expect_true('...and 17:00 after it is peak too, from the same window row',
  occurrence_is_peak('9eac9eac-0000-0000-0000-00000000f102'));
select expect_false('...while 19:01 that evening is not',
  occurrence_is_peak('9eac9eac-0000-0000-0000-00000000f103'));

-- =============================================================================
-- 3. A WINDOW IS PER DAY OF WEEK
-- =============================================================================
delete from peak_windows
 where studio_id = '9eac9eac-0000-0000-0000-000000000001'
   and day_of_week = extract(dow from ((current_date + 7)::date))::int
   and starts_at = time '17:00';
select expect_false('removing that day''s evening window makes its 17:00 class off-peak',
  occurrence_is_peak('9eac9eac-0000-0000-0000-00000000f006'));
select expect_true('...while the morning window on the same day still stands',
  occurrence_is_peak('9eac9eac-0000-0000-0000-00000000f002'));
insert into peak_windows (studio_id, day_of_week, starts_at, ends_at)
values ('9eac9eac-0000-0000-0000-000000000001',
        extract(dow from ((current_date + 7)::date))::int, time '17:00', time '19:00');
select expect_true('...and putting it back makes it peak again',
  occurrence_is_peak('9eac9eac-0000-0000-0000-00000000f006'));

-- =============================================================================
-- 4. THE SWITCH IS THE ONLY THING STOPPING STUDIO TWO
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000a1',false);
select expect_num('a studio with the switch off shows NO windows, though it has drawn seven',
  (select count(*) from studio_peak_windows('9eac9eac-0000-0000-0000-000000000002')), 0);
reset role;
select expect_num('(its seven rows really are there)',
  (select count(*) from peak_windows where studio_id = '9eac9eac-0000-0000-0000-000000000002'), 7);

set role authenticated;
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000a1',false);
select expect_num('the studio with the switch on shows all fourteen',
  (select count(*) from studio_peak_windows('9eac9eac-0000-0000-0000-000000000001')), 14);
select expect_num('...and the third studio, which has configured nothing, shows none',
  (select count(*) from studio_peak_windows('9eac9eac-0000-0000-0000-000000000003')), 0);
reset role;

select expect_num('every other studio in the database has the switch off',
  (select count(*) from studio_settings
    where peak_allowance_enabled
      and studio_id <> '9eac9eac-0000-0000-0000-000000000001'), 0);
select expect_num('...and no plan anywhere carries an allowance by default',
  (select count(*) from membership_plans where peak_allowance is not null), 0);

-- =============================================================================
-- 5. THE COUNT IS MEASURED, NOT ASSUMED
--
-- A window that catches the whole timetable is an allowance that stops everybody
-- booking anything, and a grid cannot show that. The number is what can.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000a2',false);  -- front desk
select expect_num('the evening window on that day catches its two evening classes',
  (select upcoming from studio_peak_windows('9eac9eac-0000-0000-0000-000000000001')
    where day_of_week = extract(dow from ((current_date + 7)::date))::int
      and starts_at = time '17:00'), 2);
select expect_num('...the morning window catches its two morning ones',
  (select upcoming from studio_peak_windows('9eac9eac-0000-0000-0000-000000000001')
    where day_of_week = extract(dow from ((current_date + 7)::date))::int
      and starts_at = time '07:00'), 2);
select expect_num('...and a window on a day with nothing on it catches nothing',
  (select coalesce(sum(upcoming), 0) from studio_peak_windows('9eac9eac-0000-0000-0000-000000000001')
    where day_of_week <> extract(dow from ((current_date + 7)::date))::int), 0);
reset role;

-- =============================================================================
-- 6. WHO MAY ASK
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000a4',false);  -- instructor
select expect_num('an instructor may see when peak is — the roster has to say why',
  (select count(*) from studio_peak_windows('9eac9eac-0000-0000-0000-000000000001')), 14);
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000b1',false);  -- member
select expect_num('a member may too, because a badged slot in the app is this table',
  (select count(*) from studio_peak_windows('9eac9eac-0000-0000-0000-000000000001')), 14);
select expect_raises('...but cannot ask whether somebody else''s class is peak',
  $$ select occurrence_is_peak('9eac9eac-0000-0000-0000-00000000f002') $$, '42501');
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000a5',false);  -- stranger
select expect_raises('another studio''s owner is refused by name',
  $$ select * from studio_peak_windows('9eac9eac-0000-0000-0000-000000000001') $$, 'PT403');
reset role;
set role anon;
select expect_raises('anon reaches neither',
  $$ select * from studio_peak_windows('9eac9eac-0000-0000-0000-000000000001') $$, '42501');
reset role;

-- Only a manager draws them. An INSERT refused by RLS RAISES — it is UPDATE and
-- DELETE that go quiet, by making the row invisible rather than erroring — so
-- this is asserted as a raise and the row count is checked afterwards anyway.
set role authenticated;
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000a2',false);  -- front desk
select expect_raises('front desk cannot draw a peak window',
  $$ insert into peak_windows (studio_id, day_of_week, starts_at, ends_at)
     values ('9eac9eac-0000-0000-0000-000000000001', 1, time '05:00', time '06:00') $$, '42501');
reset role;
select expect_num('...and nothing was written',
  (select count(*) from peak_windows
    where studio_id = '9eac9eac-0000-0000-0000-000000000001' and starts_at = time '05:00'), 0);

-- An instructor cannot either, and nor can a member — both can READ.
set role authenticated;
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000b1',false);  -- member
select expect_raises('a member certainly cannot',
  $$ insert into peak_windows (studio_id, day_of_week, starts_at, ends_at)
     values ('9eac9eac-0000-0000-0000-000000000001', 1, time '05:00', time '06:00') $$, '42501');
reset role;

-- =============================================================================
-- 7. A WINDOW THAT COULD ONLY BE A MISTAKE IS REFUSED
-- =============================================================================
select expect_raises('a window that ends before it starts is refused',
  $$ insert into peak_windows (studio_id, day_of_week, starts_at, ends_at)
     values ('9eac9eac-0000-0000-0000-000000000001', 2, time '19:00', time '17:00') $$, '23514');
select expect_raises('...and one that ends when it starts',
  $$ insert into peak_windows (studio_id, day_of_week, starts_at, ends_at)
     values ('9eac9eac-0000-0000-0000-000000000001', 2, time '17:00', time '17:00') $$, '23514');
select expect_raises('an exact duplicate is a double-clicked form, not a decision',
  $$ insert into peak_windows (studio_id, day_of_week, starts_at, ends_at)
     values ('9eac9eac-0000-0000-0000-000000000001', 2, time '17:00', time '19:00') $$, '23505');
select expect_raises('a day of week outside 0-6 is refused',
  $$ insert into peak_windows (studio_id, day_of_week, starts_at, ends_at)
     values ('9eac9eac-0000-0000-0000-000000000001', 7, time '17:00', time '19:00') $$, '23514');

-- =============================================================================
-- 8. A PLAN WITH CREDITS DOES NOT GET A SECOND PENALTY
--
-- The user's rule, made a CHECK rather than a convention: a pack, a drop-in and
-- an 8-a-month plan already pay for a wasted class with the credit, which is
-- worth real money. Only an unlimited recurring plan has no such penalty, and it
-- is the only kind that may carry an allowance.
-- =============================================================================
insert into membership_plans (id, studio_id, name, type, price_cents, currency,
                              billing_interval, credits_per_period, status,
                              peak_allowance, peak_allowance_period) values
  ('9eac9eac-0000-0000-0000-0000000000c1','9eac9eac-0000-0000-0000-000000000001',
   'Unlimited Monthly','recurring', 1200000, 'PHP', 'month', null, 'active', 2, 'week');
select expect_num('an unlimited recurring plan may carry an allowance',
  (select peak_allowance from membership_plans
    where id = '9eac9eac-0000-0000-0000-0000000000c1'), 2);

insert into membership_plans (id, studio_id, name, type, price_cents, currency,
                              billing_interval, credits_per_period, status) values
  ('9eac9eac-0000-0000-0000-0000000000c2','9eac9eac-0000-0000-0000-000000000001',
   '8 a Month','recurring', 800000, 'PHP', 'month', 8, 'active');
insert into membership_plans (id, studio_id, name, type, price_cents, currency,
                              credits, validity_days, status) values
  ('9eac9eac-0000-0000-0000-0000000000c3','9eac9eac-0000-0000-0000-000000000001',
   '10-Class Pack','class_pack', 900000, 'PHP', 10, 90, 'active');
insert into membership_plans (id, studio_id, name, type, price_cents, currency, status) values
  ('9eac9eac-0000-0000-0000-0000000000c4','9eac9eac-0000-0000-0000-000000000001',
   'Drop-in','drop_in', 50000, 'PHP', 'active');

select expect_raises('an 8-a-month plan cannot — the credit is already the penalty',
  $$ update membership_plans set peak_allowance = 2
      where id = '9eac9eac-0000-0000-0000-0000000000c2' $$, '23514');
select expect_raises('nor can a class pack',
  $$ update membership_plans set peak_allowance = 2
      where id = '9eac9eac-0000-0000-0000-0000000000c3' $$, '23514');
select expect_raises('nor a drop-in',
  $$ update membership_plans set peak_allowance = 2
      where id = '9eac9eac-0000-0000-0000-0000000000c4' $$, '23514');
select expect_raises('and an unlimited plan cannot gain credits while it has an allowance',
  $$ update membership_plans set credits_per_period = 8
      where id = '9eac9eac-0000-0000-0000-0000000000c1' $$, '23514');

select expect_raises('a negative allowance is refused',
  $$ update membership_plans set peak_allowance = -1
      where id = '9eac9eac-0000-0000-0000-0000000000c1' $$, '23514');
update membership_plans set peak_allowance = 0
 where id = '9eac9eac-0000-0000-0000-0000000000c1';
select expect_num('...but zero is allowed, and is a different sentence from "no limit"',
  (select peak_allowance from membership_plans
    where id = '9eac9eac-0000-0000-0000-0000000000c1'), 0);
update membership_plans set peak_allowance = 2
 where id = '9eac9eac-0000-0000-0000-0000000000c1';

select expect_raises('a period the code does not understand cannot be stored',
  $$ update membership_plans set peak_allowance_period = 'fortnight'
      where id = '9eac9eac-0000-0000-0000-0000000000c1' $$, '23514');

-- =============================================================================
-- 9. THE ALLOWANCE — migration 106
-- =============================================================================
-- A member on Unlimited Monthly (2 peak classes a week), and a week's worth of
-- peak and off-peak classes to spend it on. Built from DATES, converted once.
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents,
                         currency, starts_on, current_period_start, current_period_end)
values ('9eac9eac-0000-0000-0000-00000000aa01','9eac9eac-0000-0000-0000-000000000001',
        '9eac9eac-0000-0000-0000-00000000dd01','9eac9eac-0000-0000-0000-0000000000c1',
        'active', 1200000, 'PHP', current_date - 10,
        now() - interval '10 days', now() + interval '20 days');

-- Four peak classes and one off-peak, all inside ONE studio-local week, so the
-- fixed-week period is what is being measured rather than a rolling window.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               capacity, starts_at, ends_at, status)
select ('9eac9eac-0000-0000-0000-00000000e0' || lpad(n::text, 2, '0'))::uuid,
       '9eac9eac-0000-0000-0000-000000000001',
       '9eac9eac-0000-0000-0000-00000000000c','9eac9eac-0000-0000-0000-00000000cc01',
       null, 'Reformer', 10,
       (d + t) at time zone 'Asia/Manila',
       (d + t + interval '50 minutes') at time zone 'Asia/Manila',
       'scheduled'
  from (values
     -- the studio's own week, starting from its week start, so all five share a period
     (1, studio_week_start('9eac9eac-0000-0000-0000-000000000001',
            (now() at time zone 'Asia/Manila')::date + 7) + 0, time '07:00'),
     (2, studio_week_start('9eac9eac-0000-0000-0000-000000000001',
            (now() at time zone 'Asia/Manila')::date + 7) + 1, time '07:00'),
     (3, studio_week_start('9eac9eac-0000-0000-0000-000000000001',
            (now() at time zone 'Asia/Manila')::date + 7) + 2, time '17:00'),
     (4, studio_week_start('9eac9eac-0000-0000-0000-000000000001',
            (now() at time zone 'Asia/Manila')::date + 7) + 3, time '18:00'),
     (5, studio_week_start('9eac9eac-0000-0000-0000-000000000001',
            (now() at time zone 'Asia/Manila')::date + 7) + 4, time '12:00')
   ) v(n, d, t);

select expect_true('(four of the five fixtures really are peak, one is not)',
  (select count(*) filter (where occurrence_is_peak(id)) = 4
      and count(*) filter (where not occurrence_is_peak(id)) = 1
     from class_occurrences
    where id::text like '9eac9eac-0000-0000-0000-00000000e0%'));

select expect_num('a fresh week has the whole allowance',
  (peak_allowance_state('9eac9eac-0000-0000-0000-00000000aa01',
     (now() at time zone 'Asia/Manila')::date + 7) ->> 'remaining')::bigint, 2);

-- --- booking spends it -------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000b1',false);
select set_config('t.b1', (select (book_class('9eac9eac-0000-0000-0000-00000000e001',
  '9eac9eac-0000-0000-0000-00000000dd01','member')).booking_id::text), false);
select expect_num('one peak class booked leaves one',
  (peak_allowance_state('9eac9eac-0000-0000-0000-00000000aa01',
     (now() at time zone 'Asia/Manila')::date + 7) ->> 'remaining')::bigint, 1);
select expect_num('...and the ledger has exactly one row for it',
  (select count(*) from peak_allowance_ledger
    where booking_id = current_setting('t.b1')::uuid), 1);

-- The OFF-PEAK class costs nothing, which is the point of the whole feature.
select book_class('9eac9eac-0000-0000-0000-00000000e005',
  '9eac9eac-0000-0000-0000-00000000dd01','member');
select expect_num('an off-peak class spends no allowance',
  (peak_allowance_state('9eac9eac-0000-0000-0000-00000000aa01',
     (now() at time zone 'Asia/Manila')::date + 7) ->> 'remaining')::bigint, 1);

select book_class('9eac9eac-0000-0000-0000-00000000e002',
  '9eac9eac-0000-0000-0000-00000000dd01','member');
select expect_num('the second peak class takes the last one',
  (peak_allowance_state('9eac9eac-0000-0000-0000-00000000aa01',
     (now() at time zone 'Asia/Manila')::date + 7) ->> 'remaining')::bigint, 0);

select expect_text('...and the third is refused by name',
  (select (book_class('9eac9eac-0000-0000-0000-00000000e003',
     '9eac9eac-0000-0000-0000-00000000dd01','member')).failure_reason),
  'peak_allowance_exhausted');
select expect_num('...with nothing written for it',
  (select count(*) from bookings
    where occurrence_id = '9eac9eac-0000-0000-0000-00000000e003'
      and member_id = '9eac9eac-0000-0000-0000-00000000dd01'), 0);
reset role;

-- --- a timely cancellation gives it back -------------------------------------
-- The allowance stands in for the class credit an unlimited plan does not have,
-- and a credit comes back on a timely cancellation. The seam's own comment said
-- "for studio_released only"; this is the assertion that it was wrong.
set role authenticated;
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000b1',false);
select cancel_booking(current_setting('t.b1')::uuid);
reset role;
select expect_text('(the cancellation really was timely, not late)',
  (select release_reason::text from bookings where id = current_setting('t.b1')::uuid),
  'member_cancelled');
select expect_num('a timely cancellation restores the slot',
  (peak_allowance_state('9eac9eac-0000-0000-0000-00000000aa01',
     (now() at time zone 'Asia/Manila')::date + 7) ->> 'remaining')::bigint, 1);
select expect_num('...as a reversing row, never as a decrement',
  (select count(*) from peak_allowance_ledger
    where booking_id = current_setting('t.b1')::uuid), 2);
select expect_num('...and the two rows cancel out',
  (select sum(delta) from peak_allowance_ledger
    where booking_id = current_setting('t.b1')::uuid), 0);

-- TWO GUARDS STAND BEHIND THIS, and the first version of this block claimed to
-- test one of them and tested neither. Re-cancelling an already-cancelled
-- booking writes nothing because the status did not change AND because the
-- unique index would refuse the row anyway — removing either one on its own
-- leaves this passing, which was checked. So it asserts the OUTCOME, which is
-- the thing that must hold however many mechanisms hold it:
update bookings set status = 'cancelled' where id = current_setting('t.b1')::uuid;
select expect_num('re-cancelling an already-cancelled booking writes nothing',
  (select count(*) from peak_allowance_ledger
    where booking_id = current_setting('t.b1')::uuid), 2);

-- ...and the unique index is what makes a re-run safe whatever fires it, which
-- the statement above never exercises because it never reaches the insert. So
-- the index is asserted directly, against the row that is already there.
select expect_raises('the ledger refuses a second row for the same booking and reason',
  $$ insert into peak_allowance_ledger
       (studio_id, member_id, membership_id, booking_id, delta, reason,
        period_start, period_end)
     select studio_id, member_id, membership_id, booking_id, delta, reason,
            period_start, period_end
       from peak_allowance_ledger
      where booking_id = current_setting('t.b1')::uuid and reason = 'booked' $$,
  '23505');

-- --- a LATE cancellation does not --------------------------------------------
-- The class is inside the cancellation cutoff, so this is the penalty landing.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               capacity, starts_at, ends_at, status)
values ('9eac9eac-0000-0000-0000-00000000e011','9eac9eac-0000-0000-0000-000000000001',
        '9eac9eac-0000-0000-0000-00000000000c','9eac9eac-0000-0000-0000-00000000cc01',
        null, 'Soon', 10,
        (studio_week_start('9eac9eac-0000-0000-0000-000000000001',
           (now() at time zone 'Asia/Manila')::date + 7) + 5 + time '17:00')
          at time zone 'Asia/Manila',
        (studio_week_start('9eac9eac-0000-0000-0000-000000000001',
           (now() at time zone 'Asia/Manila')::date + 7) + 5 + time '17:50')
          at time zone 'Asia/Manila',
        'scheduled');
set role authenticated;
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000b1',false);
select set_config('t.b2', (select (book_class('9eac9eac-0000-0000-0000-00000000e011',
  '9eac9eac-0000-0000-0000-00000000dd01','member')).booking_id::text), false);
reset role;
select expect_num('(booking it spends the restored slot again)',
  (peak_allowance_state('9eac9eac-0000-0000-0000-00000000aa01',
     (now() at time zone 'Asia/Manila')::date + 7) ->> 'remaining')::bigint, 0);

-- Drag the class inside the cutoff so the cancellation is genuinely late,
-- rather than asserting against a clock that happens to agree.
update class_occurrences set starts_at = now() + interval '30 minutes',
                             ends_at   = now() + interval '80 minutes'
 where id = '9eac9eac-0000-0000-0000-00000000e011';
set role authenticated;
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000b1',false);
select cancel_booking(current_setting('t.b2')::uuid);
reset role;
select expect_text('(the cancellation really was late)',
  (select release_reason::text from bookings where id = current_setting('t.b2')::uuid),
  'late_cancelled');
select expect_num('a LATE cancellation keeps the slot spent — that is the penalty',
  (select sum(delta) from peak_allowance_ledger
    where booking_id = current_setting('t.b2')::uuid), -1);

-- --- the studio cancelling gives it back -------------------------------------
-- Moved into a week of its OWN, and to a time that is still PEAK. `now() + 3
-- days` would have landed it at whatever hour it happens to be — quietly
-- off-peak — and in the week that is already exhausted, so the booking would
-- have been refused and the assertion would have been about nothing.
update class_occurrences
   set starts_at = ((now() at time zone 'Asia/Manila')::date + 17 + time '17:00')
                     at time zone 'Asia/Manila',
       ends_at   = ((now() at time zone 'Asia/Manila')::date + 17 + time '17:50')
                     at time zone 'Asia/Manila'
 where id = '9eac9eac-0000-0000-0000-00000000e003';
select expect_true('(it is still a peak class after the move)',
  occurrence_is_peak('9eac9eac-0000-0000-0000-00000000e003'));
select expect_num('(and it sits in a week whose allowance is untouched)',
  (peak_allowance_state('9eac9eac-0000-0000-0000-00000000aa01',
     (now() at time zone 'Asia/Manila')::date + 17) ->> 'remaining')::bigint, 2);

set role authenticated;
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000b1',false);
select set_config('t.b3', (select (book_class('9eac9eac-0000-0000-0000-00000000e003',
  '9eac9eac-0000-0000-0000-00000000dd01','member')).booking_id::text), false);
reset role;
select expect_num('(booking it spends one of that week''s two)',
  (peak_allowance_state('9eac9eac-0000-0000-0000-00000000aa01',
     (now() at time zone 'Asia/Manila')::date + 17) ->> 'remaining')::bigint, 1);

select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000a1',false);
set role authenticated;
select cancel_occurrence('9eac9eac-0000-0000-0000-00000000e003', 'Burst pipe', 'closure');
reset role;
select expect_text('(the studio''s own cancellation is stamped as its own)',
  (select release_reason::text from bookings where id = current_setting('t.b3')::uuid),
  'studio_released');
select expect_num('a class the studio cancels costs the member nothing',
  (select sum(delta) from peak_allowance_ledger
    where booking_id = current_setting('t.b3')::uuid), 0);
select expect_num('...so that week is whole again',
  (peak_allowance_state('9eac9eac-0000-0000-0000-00000000aa01',
     (now() at time zone 'Asia/Manila')::date + 17) ->> 'remaining')::bigint, 2);

-- --- the period is FIXED, and keyed on the CLASS's date ----------------------
-- The same member, the same allowance, the NEXT week: untouched.
select expect_num('next week has its own allowance, whole',
  (peak_allowance_state('9eac9eac-0000-0000-0000-00000000aa01',
     (now() at time zone 'Asia/Manila')::date + 14) ->> 'remaining')::bigint, 2);
select expect_true('...and it is a fixed week from the studio''s week start',
  (select (peak_allowance_state('9eac9eac-0000-0000-0000-00000000aa01',
      (now() at time zone 'Asia/Manila')::date + 7) ->> 'period_start')::date
    = studio_week_start('9eac9eac-0000-0000-0000-000000000001',
        (now() at time zone 'Asia/Manila')::date + 7)));

-- --- a queue position is not a seat -----------------------------------------
-- "Consumed at promotion, never at join." Joining costs nothing, and the
-- promotion costs one because `respond_to_offer()` cancels the waitlist row and
-- calls book_class() again — so a promotion is measured against the allowance
-- as it stands at that moment, not as it stood when they joined the queue.
insert into members (id, studio_id, first_name, last_name, email, joined_on, status, waiver_signed_at)
values ('9eac9eac-0000-0000-0000-00000000dd02','9eac9eac-0000-0000-0000-000000000001',
        'Bea','Cruz','9eac-m2@example.com', current_date - 30,'active', now());
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               capacity, starts_at, ends_at, status, booked_count)
values ('9eac9eac-0000-0000-0000-00000000e021','9eac9eac-0000-0000-0000-000000000001',
        '9eac9eac-0000-0000-0000-00000000000c','9eac9eac-0000-0000-0000-00000000cc01',
        null, 'One seat', 1,
        ((now() at time zone 'Asia/Manila')::date + 24 + time '17:00') at time zone 'Asia/Manila',
        ((now() at time zone 'Asia/Manila')::date + 24 + time '17:50') at time zone 'Asia/Manila',
        'scheduled', 0);
select expect_true('(the one-seat class is peak)',
  occurrence_is_peak('9eac9eac-0000-0000-0000-00000000e021'));

set role authenticated;
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000a2',false);  -- desk
select book_class('9eac9eac-0000-0000-0000-00000000e021',
  '9eac9eac-0000-0000-0000-00000000dd02','staff');
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000b1',false);
select set_config('t.bw', (select (book_class('9eac9eac-0000-0000-0000-00000000e021',
  '9eac9eac-0000-0000-0000-00000000dd01','member')).booking_id::text), false);
reset role;

select expect_text('(the full class puts our member on the waitlist)',
  (select status::text from bookings where id = current_setting('t.bw')::uuid), 'waitlisted');
select expect_num('joining a waitlist for a peak class spends nothing',
  (select count(*) from peak_allowance_ledger
    where booking_id = current_setting('t.bw')::uuid), 0);
select expect_num('...and that week''s allowance is untouched',
  (peak_allowance_state('9eac9eac-0000-0000-0000-00000000aa01',
     (now() at time zone 'Asia/Manila')::date + 24) ->> 'remaining')::bigint, 2);

-- Cancelling the waitlist row writes no REFUND either — there was nothing to
-- refund, and a +1 here would hand out an allowance nobody ever spent. This is
-- exactly what respond_to_offer() does to make way for the real booking.
set role authenticated;
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000b1',false);
select cancel_booking(current_setting('t.bw')::uuid);
reset role;
select expect_num('cancelling a waitlist row refunds nothing, because nothing was spent',
  (select count(*) from peak_allowance_ledger
    where booking_id = current_setting('t.bw')::uuid), 0);
select expect_num('...the week is still whole, not three',
  (peak_allowance_state('9eac9eac-0000-0000-0000-00000000aa01',
     (now() at time zone 'Asia/Manila')::date + 24) ->> 'remaining')::bigint, 2);

-- --- an exhausted member cannot even queue -----------------------------------
-- Refused before capacity, deliberately: letting somebody wait for an offer they
-- could not accept is a worse answer than telling them now.
-- All three in ONE studio week, and inside the default booking window: at +31
-- they were refused as `outside_booking_window` and the assertion below was
-- measuring the wrong rule.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               capacity, starts_at, ends_at, status, booked_count)
select ('9eac9eac-0000-0000-0000-00000000e03' || n::text)::uuid,
       '9eac9eac-0000-0000-0000-000000000001',
       '9eac9eac-0000-0000-0000-00000000000c','9eac9eac-0000-0000-0000-00000000cc01',
       null, 'Peak ' || n, case when n = 3 then 1 else 10 end,
       (studio_week_start('9eac9eac-0000-0000-0000-000000000001',
          (now() at time zone 'Asia/Manila')::date + 25) + (n - 1) + time '17:00')
         at time zone 'Asia/Manila',
       (studio_week_start('9eac9eac-0000-0000-0000-000000000001',
          (now() at time zone 'Asia/Manila')::date + 25) + (n - 1) + time '17:50')
         at time zone 'Asia/Manila',
       'scheduled', 0
  from generate_series(1, 3) n;

select expect_true('(all three are peak, and in one studio week)',
  (select count(*) filter (where occurrence_is_peak(id)) = 3
      and count(distinct studio_week_start('9eac9eac-0000-0000-0000-000000000001',
            (starts_at at time zone 'Asia/Manila')::date)) = 1
     from class_occurrences
    where id in ('9eac9eac-0000-0000-0000-00000000e031',
                 '9eac9eac-0000-0000-0000-00000000e032',
                 '9eac9eac-0000-0000-0000-00000000e033')));

set role authenticated;
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000a2',false);
select book_class('9eac9eac-0000-0000-0000-00000000e033',
  '9eac9eac-0000-0000-0000-00000000dd02','staff');   -- fills the one seat
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000b1',false);
select book_class('9eac9eac-0000-0000-0000-00000000e031','9eac9eac-0000-0000-0000-00000000dd01','member');
select book_class('9eac9eac-0000-0000-0000-00000000e032','9eac9eac-0000-0000-0000-00000000dd01','member');
select expect_text('...so the FULL peak class is refused for the allowance, not the capacity',
  (select (book_class('9eac9eac-0000-0000-0000-00000000e033',
     '9eac9eac-0000-0000-0000-00000000dd01','member')).failure_reason),
  'peak_allowance_exhausted');
select expect_num('...and no waitlist row was created for them',
  (select count(*) from bookings
    where occurrence_id = '9eac9eac-0000-0000-0000-00000000e033'
      and member_id = '9eac9eac-0000-0000-0000-00000000dd01'), 0);
reset role;

-- --- a plan with no allowance is never checked -------------------------------
update membership_plans set peak_allowance = null
 where id = '9eac9eac-0000-0000-0000-0000000000c1';
select expect_null_state('a plan with no allowance answers null, not zero',
  peak_allowance_state('9eac9eac-0000-0000-0000-00000000aa01',
    (now() at time zone 'Asia/Manila')::date + 7));
update membership_plans set peak_allowance = 2
 where id = '9eac9eac-0000-0000-0000-0000000000c1';

-- --- and a studio with the switch off is never checked either ----------------
update studio_settings set peak_allowance_enabled = false
 where studio_id = '9eac9eac-0000-0000-0000-000000000001';
select expect_null_state('the switch off answers null even with an allowance set',
  peak_allowance_state('9eac9eac-0000-0000-0000-00000000aa01',
    (now() at time zone 'Asia/Manila')::date + 7));
set role authenticated;
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000b1',false);
select expect_null('...and the booking that was refused a moment ago goes through',
  (select (book_class('9eac9eac-0000-0000-0000-00000000e004',
     '9eac9eac-0000-0000-0000-00000000dd01','member')).failure_reason));
reset role;
update studio_settings set peak_allowance_enabled = true
 where studio_id = '9eac9eac-0000-0000-0000-000000000001';

-- --- who may ask -------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000a5',false);
select expect_raises('another studio''s owner cannot read a member''s allowance',
  $$ select peak_allowance_state('9eac9eac-0000-0000-0000-00000000aa01', current_date) $$,
  'PT403');
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000a2',false);
select expect_true('front desk of that studio can — they answer for it at the counter',
  (select peak_allowance_state('9eac9eac-0000-0000-0000-00000000aa01',
     (now() at time zone 'Asia/Manila')::date + 7) is not null));
reset role;
set role anon;
select expect_raises('anon cannot reach it at all',
  $$ select peak_allowance_state('9eac9eac-0000-0000-0000-00000000aa01', current_date) $$,
  '42501');
reset role;

-- =============================================================================
-- 10. INFRACTIONS AND THE SUSPENSION LADDER — migration 108
-- =============================================================================
-- The late cancellation in section 9 happened while suspension was OFF. It is
-- the same act that records an infraction below, so this is the switch being
-- the only thing that stands between a studio and the ladder — asserted before
-- the switch is touched.
select expect_num('a late cancellation at a studio with suspension OFF records nothing',
  (select count(*) from member_infractions
    where studio_id = '9eac9eac-0000-0000-0000-000000000001'), 0);
select expect_null_state('...and the member has no standing to read',
  member_suspension('9eac9eac-0000-0000-0000-00000000dd01'));

update studio_settings
   set suspension_enabled = true, suspension_window_days = 30,
       suspension_warn_at = 2, suspension_at = 3,
       suspension_days = 14, suspension_repeat_days = 30
 where studio_id = '9eac9eac-0000-0000-0000-000000000001';

select expect_num('turning it on does not reach back for history',
  (select count(*) from member_infractions
    where studio_id = '9eac9eac-0000-0000-0000-000000000001'), 0);
select expect_num('...and a member with none is at nought',
  (member_suspension('9eac9eac-0000-0000-0000-00000000dd01') ->> 'count')::bigint, 0);
select expect_false('...and is not suspended',
  (member_suspension('9eac9eac-0000-0000-0000-00000000dd01') ->> 'suspended')::boolean);
select expect_num('...and is told how many before anything happens',
  (member_suspension('9eac9eac-0000-0000-0000-00000000dd01') ->> 'until_warning')::bigint, 2);

-- --- three late cancellations, one at a time ---------------------------------
-- Off-peak classes deliberately, so the ladder is being measured rather than
-- the peak allowance, which the member has already spent this week.
-- SECURITY DEFINER so the fixture INSERT is not refused by RLS while the session
-- is a member's. `book_class()` decides trust from the `role` GUC, which SET ROLE
-- set and which entering a definer function does not change — so the booking
-- inside is still made as an ordinary member, which is the point.
create or replace function t_late_cancel(p_n int, p_days int) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_occ uuid; v_b uuid;
begin
  v_occ := ('9eac9eac-0000-0000-0000-0000000009' || lpad(p_n::text, 2, '0'))::uuid;
  insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                                 capacity, starts_at, ends_at, status)
  values (v_occ, '9eac9eac-0000-0000-0000-000000000001',
          '9eac9eac-0000-0000-0000-00000000000c','9eac9eac-0000-0000-0000-00000000cc01',
          null, 'Midday ' || p_n, 10,
          ((now() at time zone 'Asia/Manila')::date + 2 + time '12:00') at time zone 'Asia/Manila',
          ((now() at time zone 'Asia/Manila')::date + 2 + time '12:50') at time zone 'Asia/Manila',
          'scheduled');
  v_b := (book_class(v_occ, '9eac9eac-0000-0000-0000-00000000dd01', 'member')).booking_id;
  -- Drag it inside the cutoff so the cancellation is genuinely late, and back-date
  -- it so the rolling window has something to order.
  update class_occurrences
     set starts_at = now() - make_interval(days => p_days) + interval '30 minutes',
         ends_at   = now() - make_interval(days => p_days) + interval '80 minutes'
   where id = v_occ;
  perform cancel_booking(v_b);
  return v_b;
end $$;

set role authenticated;
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000b1',false);
select set_config('t.i1', t_late_cancel(1, 20)::text, false);
select expect_num('one late cancellation is one infraction',
  (select count(*) from member_infractions
    where member_id = '9eac9eac-0000-0000-0000-00000000dd01' and status = 'active'), 1);
select expect_false('...and one is not a warning yet',
  (member_suspension('9eac9eac-0000-0000-0000-00000000dd01') ->> 'warned')::boolean);

select set_config('t.i2', t_late_cancel(2, 10)::text, false);
select expect_true('the second warns',
  (member_suspension('9eac9eac-0000-0000-0000-00000000dd01') ->> 'warned')::boolean);
select expect_false('...and still does not suspend',
  (member_suspension('9eac9eac-0000-0000-0000-00000000dd01') ->> 'suspended')::boolean);
select expect_num('...with one to go',
  (member_suspension('9eac9eac-0000-0000-0000-00000000dd01') ->> 'until_suspension')::bigint, 1);

select set_config('t.i3', t_late_cancel(3, 1)::text, false);
select expect_true('the third suspends',
  (member_suspension('9eac9eac-0000-0000-0000-00000000dd01') ->> 'suspended')::boolean);
select expect_false('...and a suspension is not also a warning',
  (member_suspension('9eac9eac-0000-0000-0000-00000000dd01') ->> 'warned')::boolean);
select expect_true('...running from the third one''s own date, not from today',
  (select ((member_suspension('9eac9eac-0000-0000-0000-00000000dd01') ->> 'until')::timestamptz
            - interval '14 days')::date
        = (now() - interval '1 day')::date));
reset role;

-- --- what a suspension actually stops ----------------------------------------
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               capacity, starts_at, ends_at, status)
values
 ('9eac9eac-0000-0000-0000-0000000009a1','9eac9eac-0000-0000-0000-000000000001',
  '9eac9eac-0000-0000-0000-00000000000c','9eac9eac-0000-0000-0000-00000000cc01', null,'Tomorrow',10,
  ((now() at time zone 'Asia/Manila')::date + 1 + time '12:00') at time zone 'Asia/Manila',
  ((now() at time zone 'Asia/Manila')::date + 1 + time '12:50') at time zone 'Asia/Manila','scheduled'),
 ('9eac9eac-0000-0000-0000-0000000009a2','9eac9eac-0000-0000-0000-000000000001',
  '9eac9eac-0000-0000-0000-00000000000c','9eac9eac-0000-0000-0000-00000000cc01', null,'Later today',10,
  (now() + interval '3 hours'), (now() + interval '3 hours 50 minutes'),'scheduled');

set role authenticated;
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000b1',false);
select expect_text('a suspended member cannot book ahead',
  (select (book_class('9eac9eac-0000-0000-0000-0000000009a1',
     '9eac9eac-0000-0000-0000-00000000dd01','member')).failure_reason), 'suspended');
select expect_null('...but can still take a seat TODAY — it restricts advance booking, not the studio',
  (select (book_class('9eac9eac-0000-0000-0000-0000000009a2',
     '9eac9eac-0000-0000-0000-00000000dd01','member')).failure_reason));
reset role;

-- Staff can let them in anyway, and it is recorded as an override.
set role authenticated;
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000a2',false);
select expect_null('front desk can override a suspension with a reason',
  (select (book_class('9eac9eac-0000-0000-0000-0000000009a1',
     '9eac9eac-0000-0000-0000-00000000dd01','staff','She rang ahead')).failure_reason));
reset role;
select expect_true('...and the override says what was bypassed',
  (select overridden_rules @> array['suspended']::text[] from bookings
    where occurrence_id = '9eac9eac-0000-0000-0000-0000000009a1'
      and member_id = '9eac9eac-0000-0000-0000-00000000dd01'
      and status <> 'cancelled'));

-- --- excusing one -------------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000a2',false);  -- front desk
select expect_raises('an excuse with no reason is refused',
  $$ select excuse_infraction(
       (select id from member_infractions where booking_id = current_setting('t.i3')::uuid),
       '  ') $$, 'PT400');
select set_config('t.ex',
  (select excuse_infraction(
     (select id from member_infractions where booking_id = current_setting('t.i3')::uuid),
     'Hospital appointment, she rang')::text), false);
select expect_false('excusing the third lifts the suspension at once — nothing had to recalculate',
  (member_suspension('9eac9eac-0000-0000-0000-00000000dd01') ->> 'suspended')::boolean);
select expect_num('...and the count drops',
  (member_suspension('9eac9eac-0000-0000-0000-00000000dd01') ->> 'count')::bigint, 2);
reset role;
select expect_text('...the row is VOIDED, not deleted, so the excuse rate stays countable',
  (select status from member_infractions where booking_id = current_setting('t.i3')::uuid), 'voided');
select expect_text('...carrying who excused it and why',
  (select voided_reason from member_infractions where booking_id = current_setting('t.i3')::uuid),
  'Hospital appointment, she rang');
select expect_num('...and an audit row was written',
  (select count(*) from audit_logs
    where studio_id = '9eac9eac-0000-0000-0000-000000000001'
      and action = 'infraction.excused'), 1);

set role authenticated;
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000a2',false);
select expect_raises('the same one cannot be excused twice',
  $$ select excuse_infraction(
       (select id from member_infractions where booking_id = current_setting('t.i3')::uuid),
       'again') $$, 'PT409');
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000b1',false);
select expect_raises('a member cannot excuse their own',
  $$ select excuse_infraction(
       (select id from member_infractions where booking_id = current_setting('t.i2')::uuid),
       'I would rather not') $$, 'PT403');
reset role;

-- --- marking somebody present -------------------------------------------------
-- The brief says this restores the allowance. It does NOT, and the reason is
-- that the allowance is spent at BOOKING: they booked a peak class and they were
-- in the room, so the slot is correctly gone. What was wrong was the record.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               capacity, starts_at, ends_at, status)
values ('9eac9eac-0000-0000-0000-0000000009b1','9eac9eac-0000-0000-0000-000000000001',
        '9eac9eac-0000-0000-0000-00000000000c','9eac9eac-0000-0000-0000-00000000cc01',
        null, 'Peak, later', 10,
        ((now() at time zone 'Asia/Manila')::date + 40 + time '17:00') at time zone 'Asia/Manila',
        ((now() at time zone 'Asia/Manila')::date + 40 + time '17:50') at time zone 'Asia/Manila',
        'scheduled');
update membership_plans set booking_window_days = 60
 where id = '9eac9eac-0000-0000-0000-0000000000c1';
set role authenticated;
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000b1',false);
select set_config('t.bp', (select (book_class('9eac9eac-0000-0000-0000-0000000009b1',
  '9eac9eac-0000-0000-0000-00000000dd01','member')).booking_id::text), false);
reset role;
select expect_num('(the peak class spent a slot)',
  (select sum(delta) from peak_allowance_ledger
    where booking_id = current_setting('t.bp')::uuid), -1);

update bookings set status = 'no_show' where id = current_setting('t.bp')::uuid;
select expect_num('a no-show records an infraction of its own kind',
  (select count(*) from member_infractions
    where booking_id = current_setting('t.bp')::uuid and kind = 'no_show'), 1);

set role authenticated;
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000a2',false);
select set_config('t.mp', (select mark_present(current_setting('t.bp')::uuid)::text), false);
reset role;
select expect_text('marking them present corrects the booking',
  (select status::text from bookings where id = current_setting('t.bp')::uuid), 'attended');
select expect_text('...voids the infraction',
  (select status from member_infractions where booking_id = current_setting('t.bp')::uuid), 'voided');
select expect_num('...and the peak slot STAYS SPENT, because they attended',
  (select sum(delta) from peak_allowance_ledger
    where booking_id = current_setting('t.bp')::uuid), -1);
select expect_num('...with an audit row for the correction',
  (select count(*) from audit_logs
    where studio_id = '9eac9eac-0000-0000-0000-000000000001'
      and action = 'booking.marked_present'), 1);

-- Excusing a LATE CANCEL does give the slot back, which is what excusing means.
select expect_num('(the second infraction''s booking spent nothing — it was off-peak)',
  (select count(*) from peak_allowance_ledger
    where booking_id = current_setting('t.i2')::uuid), 0);

-- --- the sweep ----------------------------------------------------------------
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               capacity, starts_at, ends_at, status)
values
 ('9eac9eac-0000-0000-0000-0000000009c1','9eac9eac-0000-0000-0000-000000000001',
  '9eac9eac-0000-0000-0000-00000000000c','9eac9eac-0000-0000-0000-00000000cc01', null,'Finished',10,
  now() - interval '3 hours', now() - interval '2 hours','scheduled'),
 ('9eac9eac-0000-0000-0000-0000000009c2','9eac9eac-0000-0000-0000-000000000001',
  '9eac9eac-0000-0000-0000-00000000000c','9eac9eac-0000-0000-0000-00000000cc01', null,'Still running',10,
  now() - interval '20 minutes', now() + interval '30 minutes','scheduled'),
 ('9eac9eac-0000-0000-0000-0000000009c3','9eac9eac-0000-0000-0000-000000000002',
  '9eac9eac-0000-0000-0000-00000000000d','9eac9eac-0000-0000-0000-00000000cc02', null,'Other studio',10,
  now() - interval '3 hours', now() - interval '2 hours','scheduled');
insert into members (id, studio_id, first_name, last_name, email, joined_on, status, waiver_signed_at)
values ('9eac9eac-0000-0000-0000-00000000dd03','9eac9eac-0000-0000-0000-000000000002',
        'Cara','Diaz','9eac-m3@example.com', current_date - 30,'active', now());
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source)
values
 ('9eac9eac-0000-0000-0000-00000000bb01','9eac9eac-0000-0000-0000-000000000001',
  '9eac9eac-0000-0000-0000-0000000009c1','9eac9eac-0000-0000-0000-00000000dd02','booked','member','comp'),
 ('9eac9eac-0000-0000-0000-00000000bb02','9eac9eac-0000-0000-0000-000000000001',
  '9eac9eac-0000-0000-0000-0000000009c2','9eac9eac-0000-0000-0000-00000000dd02','booked','member','comp'),
 ('9eac9eac-0000-0000-0000-00000000bb03','9eac9eac-0000-0000-0000-000000000002',
  '9eac9eac-0000-0000-0000-0000000009c3','9eac9eac-0000-0000-0000-00000000dd03','booked','member','comp');

select set_config('t.sw', (select sweep_no_shows()::text), false);
select expect_text('a booking on a class that has finished, with no check-in, is a no-show',
  (select status::text from bookings where id = '9eac9eac-0000-0000-0000-00000000bb01'), 'no_show');
select expect_text('...a class still running is left alone',
  (select status::text from bookings where id = '9eac9eac-0000-0000-0000-00000000bb02'), 'booked');
select expect_text('...and a studio with suspension OFF is not swept at all',
  (select status::text from bookings where id = '9eac9eac-0000-0000-0000-00000000bb03'), 'booked');
select expect_num('...the swept one becomes an infraction dated to the CLASS, not to the sweep',
  (select count(*) from member_infractions
    where booking_id = '9eac9eac-0000-0000-0000-00000000bb01'
      and occurred_at < now() - interval '2 hours'), 1);
select expect_num('a second run of the sweep marks nothing more',
  ((select sweep_no_shows() -> 'marked')::text)::bigint, 0);

set role authenticated;
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000a2',false);
-- 42501 and not PT403: the function is revoked from every client role, so there
-- is no grant to try. That is the stronger answer — the same one migration 086
-- gave ensure_pay_period() — and the guard inside it is the second wall rather
-- than the first.
select expect_raises('the sweep is a background job, and staff cannot even reach it',
  $$ select sweep_no_shows() $$, '42501');
reset role;

-- =============================================================================
-- 11. THE REPORT AND THE REMINDER — migration 109
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000a1',false);  -- owner
select expect_num('the report counts every infraction in the window',
  (peak_allowance_report('9eac9eac-0000-0000-0000-000000000001', 90) ->> 'infractions')::bigint, 5);
select expect_num('...including the ones that were excused, because they were KEPT',
  (peak_allowance_report('9eac9eac-0000-0000-0000-000000000001', 90) ->> 'excused')::bigint, 2);
select expect_num('...as a rate, which is the number that says the rule is wrong',
  (peak_allowance_report('9eac9eac-0000-0000-0000-000000000001', 90) ->> 'excused_pct')::bigint, 40);
select expect_null('...and below the threshold it says nothing, rather than filling the space',
  (peak_allowance_report('9eac9eac-0000-0000-0000-000000000001', 90) ->> 'excuse_reading'));
select expect_num('...a no-show is counted apart from a late cancellation',
  (peak_allowance_report('9eac9eac-0000-0000-0000-000000000001', 90) ->> 'no_shows')::bigint, 2);

-- Push it over half, and the report starts saying what that means.
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000a2',false);
select excuse_infraction(
  (select id from member_infractions where booking_id = current_setting('t.i1')::uuid),
  'Car broke down');
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000a1',false);
select expect_num('(three of five excused)',
  (peak_allowance_report('9eac9eac-0000-0000-0000-000000000001', 90) ->> 'excused_pct')::bigint, 60);
select expect_true('past half, the report says the rule is one staff cannot defend',
  (peak_allowance_report('9eac9eac-0000-0000-0000-000000000001', 90) ->> 'excuse_reading')
    like '%cannot defend at the counter%');

select expect_true('exhaustion carries BOTH readings, not just a percentage',
  (peak_allowance_report('9eac9eac-0000-0000-0000-000000000001', 90) ->> 'reading') is not null);

select expect_raises('front desk cannot read the studio''s reporting',
  $$ select peak_allowance_report('9eac9eac-0000-0000-0000-000000000001', 90) $$, 'PT403')
  from (select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000a2',false)) x;
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000a1',false);
select expect_null_state('a studio using neither switch has no report at all',
  peak_allowance_report('9eac9eac-0000-0000-0000-000000000003', 90));
reset role;

-- --- the reminder --------------------------------------------------------------
-- A booking that SPENT a peak slot, sitting just inside the lead-up to its free
-- cancellation window. Nothing else is reminded: a member with nothing to lose
-- must not be told they are about to lose it.
update studio_settings
   set cancellation_cutoff_minutes = 720, peak_cutoff_reminder_minutes = 120
 where studio_id = '9eac9eac-0000-0000-0000-000000000001';
update class_occurrences
   set starts_at = now() + interval '13 hours', ends_at = now() + interval '13 hours 50 minutes'
 where id = '9eac9eac-0000-0000-0000-00000000e021';

insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               capacity, starts_at, ends_at, status)
values ('9eac9eac-0000-0000-0000-0000000009d1','9eac9eac-0000-0000-0000-000000000001',
        '9eac9eac-0000-0000-0000-00000000000c','9eac9eac-0000-0000-0000-00000000cc01',
        null, 'Peak tomorrow', 10,
        now() + interval '13 hours', now() + interval '13 hours 50 minutes', 'scheduled');
-- Peak by the clock it actually starts at, rather than by hope. Replaced rather
-- than widened, because two windows widened to the same hours collide on the
-- unique index that exists to stop a double-clicked form.
delete from peak_windows where studio_id = '9eac9eac-0000-0000-0000-000000000001';
insert into peak_windows (studio_id, day_of_week, starts_at, ends_at)
select '9eac9eac-0000-0000-0000-000000000001', d, time '00:00', time '23:59'
  from generate_series(0, 6) d;

set role authenticated;
select set_config('request.jwt.claim.sub','9eac9eac-0000-0000-0000-0000000000b1',false);
select set_config('t.br', (select (book_class('9eac9eac-0000-0000-0000-0000000009d1',
  '9eac9eac-0000-0000-0000-00000000dd01','member')).booking_id::text), false);
reset role;
select expect_num('(the booking spent a peak slot, so it has something to lose)',
  (select count(*) from peak_allowance_ledger
    where booking_id = current_setting('t.br')::uuid and reason = 'booked'), 1);

select set_config('t.rem', (select sweep_peak_cutoff_reminders()::text), false);
select expect_num('the member holding a peak class is reminded once, before the window shuts',
  (select count(*) from notifications
    where template_key = 'peak_cancel_window'
      and dedupe_key = 'peak_cutoff:' || current_setting('t.br')), 1);
select expect_true('...and the message names the hour the free window closes',
  (select payload ->> 'cutoff_time' ~ '^[0-9]{2}:[0-9]{2}$' from notifications
    where dedupe_key = 'peak_cutoff:' || current_setting('t.br')));
select expect_num('a second sweep sends nothing more',
  (select count(*) from notifications
    where template_key = 'peak_cancel_window'
      and dedupe_key = 'peak_cutoff:' || current_setting('t.br')), 1)
  from (select sweep_peak_cutoff_reminders()) x;

-- Past the cutoff there is nothing useful left to say.
update class_occurrences set starts_at = now() + interval '2 hours',
                             ends_at = now() + interval '2 hours 50 minutes'
 where id = '9eac9eac-0000-0000-0000-0000000009d1';
delete from notifications where dedupe_key = 'peak_cutoff:' || current_setting('t.br');
select sweep_peak_cutoff_reminders();
select expect_num('once the free window has closed, the reminder is not sent',
  (select count(*) from notifications
    where dedupe_key = 'peak_cutoff:' || current_setting('t.br')), 0);

select expect_num('and a studio with peak hours OFF reminds nobody',
  (select count(*) from notifications n join members m on m.id = n.member_id
    where n.template_key = 'peak_cancel_window'
      and m.studio_id <> '9eac9eac-0000-0000-0000-000000000001'), 0);

do $$
begin
  raise notice '--------------------------------------------------------------';
  raise notice 'peak, allowance, infractions and suspension: all assertions passed';
  raise notice '--------------------------------------------------------------';
end $$;
