-- =============================================================================
-- Seat caps on a plan — Decision 24 part one, migration 102
-- =============================================================================
-- UUID space 5ea7, checked free. Run after `supabase db reset`.
--
-- THREE STUDIOS, and the second is the one that matters:
--
--   ONE   seat caps ON, with a capped plan.        The feature working.
--   TWO   seat caps OFF, with a capped plan ANYWAY. The switch is the only
--         thing standing between it and enforcement — which is the assertion
--         the flex suite originally lacked, where "a studio with flex off has
--         nothing pending" passed against a studio that had no flex rows at
--         all and would have passed with the gate deleted.
--   THREE everything off, nothing configured. The whole feature invisible.
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
-- asserted as well as the code.
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
  ('5ea75ea7-0000-0000-0000-0000000000a1'),   -- owner, all three studios
  ('5ea75ea7-0000-0000-0000-0000000000a2'),   -- front desk, studio ONE
  ('5ea75ea7-0000-0000-0000-0000000000a3'),   -- front desk, studio TWO
  ('5ea75ea7-0000-0000-0000-0000000000a4'),   -- instructor, studio ONE
  ('5ea75ea7-0000-0000-0000-0000000000a5'),   -- owner of an UNRELATED studio
  ('5ea75ea7-0000-0000-0000-0000000000b1'),
  ('5ea75ea7-0000-0000-0000-0000000000b2'),
  ('5ea75ea7-0000-0000-0000-0000000000b3'),
  ('5ea75ea7-0000-0000-0000-0000000000b4'),
  ('5ea75ea7-0000-0000-0000-0000000000b5');
insert into profiles (id, email) values
  ('5ea75ea7-0000-0000-0000-0000000000a1','5ea7-owner@example.com'),
  ('5ea75ea7-0000-0000-0000-0000000000a2','5ea7-desk1@example.com'),
  ('5ea75ea7-0000-0000-0000-0000000000a3','5ea7-desk2@example.com'),
  ('5ea75ea7-0000-0000-0000-0000000000a4','5ea7-coach@example.com'),
  ('5ea75ea7-0000-0000-0000-0000000000a5','5ea7-stranger@example.com'),
  ('5ea75ea7-0000-0000-0000-0000000000b1','5ea7-m1@example.com'),
  ('5ea75ea7-0000-0000-0000-0000000000b2','5ea7-m2@example.com'),
  ('5ea75ea7-0000-0000-0000-0000000000b3','5ea7-m3@example.com'),
  ('5ea75ea7-0000-0000-0000-0000000000b4','5ea7-m4@example.com'),
  ('5ea75ea7-0000-0000-0000-0000000000b5','5ea7-m5@example.com');

insert into studios (id, name, slug, timezone, currency, status) values
  ('5ea75ea7-0000-0000-0000-000000000001','Reform Seats','reform-seats','Asia/Manila','PHP','active'),
  ('5ea75ea7-0000-0000-0000-000000000002','Switch Off Pilates','switch-off','Asia/Manila','PHP','active'),
  ('5ea75ea7-0000-0000-0000-000000000003','Plain Studio','plain-studio','Europe/Prague','CZK','active'),
  ('5ea75ea7-0000-0000-0000-000000000009','Somebody Else','somebody-else','Europe/Prague','CZK','active');

-- ONE has the switch on. TWO does NOT, and carries a cap anyway.
insert into studio_settings (studio_id, seat_caps_enabled) values
  ('5ea75ea7-0000-0000-0000-000000000001', true),
  ('5ea75ea7-0000-0000-0000-000000000002', false),
  ('5ea75ea7-0000-0000-0000-000000000003', false),
  ('5ea75ea7-0000-0000-0000-000000000009', false);

insert into locations (id, studio_id, name, is_primary) values
  ('5ea75ea7-0000-0000-0000-00000000000c','5ea75ea7-0000-0000-0000-000000000001','Main',true),
  ('5ea75ea7-0000-0000-0000-00000000000d','5ea75ea7-0000-0000-0000-000000000002','Main',true),
  ('5ea75ea7-0000-0000-0000-00000000000e','5ea75ea7-0000-0000-0000-000000000003','Main',true);

insert into studio_staff (studio_id, user_id, email, role) values
  ('5ea75ea7-0000-0000-0000-000000000001','5ea75ea7-0000-0000-0000-0000000000a1','5ea7-owner@example.com','owner'),
  ('5ea75ea7-0000-0000-0000-000000000001','5ea75ea7-0000-0000-0000-0000000000a2','5ea7-desk1@example.com','front_desk'),
  ('5ea75ea7-0000-0000-0000-000000000001','5ea75ea7-0000-0000-0000-0000000000a4','5ea7-coach@example.com','instructor'),
  ('5ea75ea7-0000-0000-0000-000000000002','5ea75ea7-0000-0000-0000-0000000000a1','5ea7-owner2@example.com','owner'),
  ('5ea75ea7-0000-0000-0000-000000000002','5ea75ea7-0000-0000-0000-0000000000a3','5ea7-desk2@example.com','front_desk'),
  ('5ea75ea7-0000-0000-0000-000000000003','5ea75ea7-0000-0000-0000-0000000000a1','5ea7-owner3@example.com','owner'),
  ('5ea75ea7-0000-0000-0000-000000000009','5ea75ea7-0000-0000-0000-0000000000a5','5ea7-stranger@example.com','owner');

insert into members (id, studio_id, user_id, first_name, last_name, email, joined_on, status, waiver_signed_at) values
  ('5ea75ea7-0000-0000-0000-00000000dd01','5ea75ea7-0000-0000-0000-000000000001',
   '5ea75ea7-0000-0000-0000-0000000000b1','Ana','Santos','5ea7-m1@example.com', current_date - 30,'active', now()),
  ('5ea75ea7-0000-0000-0000-00000000dd02','5ea75ea7-0000-0000-0000-000000000001',
   '5ea75ea7-0000-0000-0000-0000000000b2','Bea','Lim','5ea7-m2@example.com', current_date - 30,'active', now()),
  ('5ea75ea7-0000-0000-0000-00000000dd03','5ea75ea7-0000-0000-0000-000000000001',
   '5ea75ea7-0000-0000-0000-0000000000b3','Cara','Tan','5ea7-m3@example.com', current_date - 30,'active', now()),
  ('5ea75ea7-0000-0000-0000-00000000dd04','5ea75ea7-0000-0000-0000-000000000001',
   '5ea75ea7-0000-0000-0000-0000000000b4','Dina','Cruz','5ea7-m4@example.com', current_date - 30,'active', now()),
  ('5ea75ea7-0000-0000-0000-00000000dd05','5ea75ea7-0000-0000-0000-000000000001',
   '5ea75ea7-0000-0000-0000-0000000000b5','Elsa','Reyes','5ea7-m5@example.com', current_date - 30,'active', now()),
  ('5ea75ea7-0000-0000-0000-00000000dd21','5ea75ea7-0000-0000-0000-000000000002',
   null,'Fina','Diaz','5ea7-m21@example.com', current_date - 30,'active', now()),
  ('5ea75ea7-0000-0000-0000-00000000dd22','5ea75ea7-0000-0000-0000-000000000002',
   null,'Gia','Reyes','5ea7-m22@example.com', current_date - 30,'active', now()),
  ('5ea75ea7-0000-0000-0000-00000000dd23','5ea75ea7-0000-0000-0000-000000000002',
   null,'Hana','Ong','5ea7-m23@example.com', current_date - 30,'active', now()),
  ('5ea75ea7-0000-0000-0000-00000000dd31','5ea75ea7-0000-0000-0000-000000000003',
   null,'Iva','Novak','5ea7-m31@example.com', current_date - 30,'active', now());

-- Studio ONE: a capped plan, an uncapped pack beside it, and a hidden capped
-- plan so "a member sees what plans_member_read would have shown them" is a
-- real comparison rather than a tautology.
insert into membership_plans (id, studio_id, name, type, price_cents, currency,
                              billing_interval, credits_per_period, status, visibility,
                              max_active_members, show_remaining_below) values
  ('5ea75ea7-0000-0000-0000-0000000000c1','5ea75ea7-0000-0000-0000-000000000001',
   'Unlimited Monthly','recurring', 1200000, 'PHP', 'month', null, 'active', 'public', 3, 2),
  ('5ea75ea7-0000-0000-0000-0000000000c3','5ea75ea7-0000-0000-0000-000000000001',
   'Founder Rate','recurring', 900000, 'PHP', 'month', null, 'active', 'hidden', 1, null);
insert into membership_plans (id, studio_id, name, type, price_cents, currency,
                              credits, validity_days, status) values
  ('5ea75ea7-0000-0000-0000-0000000000c2','5ea75ea7-0000-0000-0000-000000000001',
   '10-Class Pack','class_pack', 900000, 'PHP', 10, 90, 'active');

-- Studio TWO: THE SAME CAP, and the switch off.
insert into membership_plans (id, studio_id, name, type, price_cents, currency,
                              billing_interval, credits_per_period, status,
                              max_active_members) values
  ('5ea75ea7-0000-0000-0000-0000000000d1','5ea75ea7-0000-0000-0000-000000000002',
   'Unlimited Monthly','recurring', 1200000, 'PHP', 'month', null, 'active', 1);

-- Studio THREE: nothing at all.
insert into membership_plans (id, studio_id, name, type, price_cents, currency,
                              billing_interval, credits_per_period, status) values
  ('5ea75ea7-0000-0000-0000-0000000000e1','5ea75ea7-0000-0000-0000-000000000003',
   'Monthly','recurring', 250000, 'CZK', 'month', null, 'active');

-- =============================================================================
-- 1. THE SWITCH IS THE ONLY THING STOPPING STUDIO TWO
--
-- Its plan carries max_active_members = 1. With seat_caps_enabled false it is
-- an inert number: three members go onto a plan capped at one, and no screen
-- can see that a cap exists.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','5ea75ea7-0000-0000-0000-0000000000a3',false);  -- desk, TWO

select record_manual_payment('5ea75ea7-0000-0000-0000-000000000002',
  '5ea75ea7-0000-0000-0000-00000000dd21','plan', 1200000,'cash',
  p_plan_id => '5ea75ea7-0000-0000-0000-0000000000d1');
select record_manual_payment('5ea75ea7-0000-0000-0000-000000000002',
  '5ea75ea7-0000-0000-0000-00000000dd22','plan', 1200000,'cash',
  p_plan_id => '5ea75ea7-0000-0000-0000-0000000000d1');
select record_manual_payment('5ea75ea7-0000-0000-0000-000000000002',
  '5ea75ea7-0000-0000-0000-00000000dd23','plan', 1200000,'cash',
  p_plan_id => '5ea75ea7-0000-0000-0000-0000000000d1');

select expect_num('a studio with the switch off sells past a cap of 1',
  (select count(*) from memberships where plan_id = '5ea75ea7-0000-0000-0000-0000000000d1'), 3);
select expect_num('...and plan_seats() shows it NOTHING — no rows, not zeroes',
  (select count(*) from plan_seats('5ea75ea7-0000-0000-0000-000000000002')), 0);
reset role;

-- =============================================================================
-- 2. THE THIRD STUDIO: the whole feature invisible
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','5ea75ea7-0000-0000-0000-0000000000a1',false);  -- owner
select expect_num('a studio that has configured nothing sees no seat rows',
  (select count(*) from plan_seats('5ea75ea7-0000-0000-0000-000000000003')), 0);
select expect_num('...and no plan of its own carries a cap to begin with',
  (select count(*) from membership_plans
    where studio_id = '5ea75ea7-0000-0000-0000-000000000003'
      and max_active_members is not null), 0);
reset role;
select expect_num('...every existing plan in the database is uncapped by default',
  (select count(*) from membership_plans
    where max_active_members is not null
      and studio_id not in ('5ea75ea7-0000-0000-0000-000000000001',
                            '5ea75ea7-0000-0000-0000-000000000002')), 0);
select expect_num('...and every existing studio has the switch off',
  (select count(*) from studio_settings
    where seat_caps_enabled
      and studio_id <> '5ea75ea7-0000-0000-0000-000000000001'), 0);

-- =============================================================================
-- 3. THE CAP HOLDS, and the refusal says what is wrong
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','5ea75ea7-0000-0000-0000-0000000000a2',false);  -- desk, ONE

select expect_num('before anybody buys, three places are free',
  (select remaining from plan_seats('5ea75ea7-0000-0000-0000-000000000001')
    where plan_id = '5ea75ea7-0000-0000-0000-0000000000c1'), 3);
select expect_false('...and "places left" is not shown while there are plenty',
  (select show_remaining from plan_seats('5ea75ea7-0000-0000-0000-000000000001')
    where plan_id = '5ea75ea7-0000-0000-0000-0000000000c1'));

select record_manual_payment('5ea75ea7-0000-0000-0000-000000000001',
  '5ea75ea7-0000-0000-0000-00000000dd01','plan', 1200000,'cash',
  p_plan_id => '5ea75ea7-0000-0000-0000-0000000000c1');

select expect_num('one sold, two left',
  (select remaining from plan_seats('5ea75ea7-0000-0000-0000-000000000001')
    where plan_id = '5ea75ea7-0000-0000-0000-0000000000c1'), 2);
select expect_true('...and now it is worth saying so',
  (select show_remaining from plan_seats('5ea75ea7-0000-0000-0000-000000000001')
    where plan_id = '5ea75ea7-0000-0000-0000-0000000000c1'));

select record_manual_payment('5ea75ea7-0000-0000-0000-000000000001',
  '5ea75ea7-0000-0000-0000-00000000dd02','plan', 1200000,'cash',
  p_plan_id => '5ea75ea7-0000-0000-0000-0000000000c1');
select record_manual_payment('5ea75ea7-0000-0000-0000-000000000001',
  '5ea75ea7-0000-0000-0000-00000000dd03','plan', 1200000,'cash',
  p_plan_id => '5ea75ea7-0000-0000-0000-0000000000c1');

select expect_true('three sold, the plan is full',
  (select is_full from plan_seats('5ea75ea7-0000-0000-0000-000000000001')
    where plan_id = '5ea75ea7-0000-0000-0000-0000000000c1'));
select expect_false('...and full is not over',
  (select is_over from plan_seats('5ea75ea7-0000-0000-0000-000000000001')
    where plan_id = '5ea75ea7-0000-0000-0000-0000000000c1'));
select expect_false('...a full plan says FULL, never "0 places left"',
  (select show_remaining from plan_seats('5ea75ea7-0000-0000-0000-000000000001')
    where plan_id = '5ea75ea7-0000-0000-0000-0000000000c1'));

select expect_raises_saying('the fourth sale is refused, naming the plan and the count',
  $$select record_manual_payment('5ea75ea7-0000-0000-0000-000000000001',
      '5ea75ea7-0000-0000-0000-00000000dd04','plan', 1200000,'cash',
      p_plan_id => '5ea75ea7-0000-0000-0000-0000000000c1')$$,
  'PT409', '%Unlimited Monthly is full: 3 of 3%');

select expect_num('...and nothing was written by the refusal',
  (select count(*) from memberships
    where member_id = '5ea75ea7-0000-0000-0000-00000000dd04'), 0);
select expect_num('...not a payment either',
  (select count(*) from payments
    where member_id = '5ea75ea7-0000-0000-0000-00000000dd04'), 0);

-- The uncapped pack beside it is untouched by any of this.
select record_manual_payment('5ea75ea7-0000-0000-0000-000000000001',
  '5ea75ea7-0000-0000-0000-00000000dd04','plan', 900000,'cash',
  p_plan_id => '5ea75ea7-0000-0000-0000-0000000000c2');
select expect_num('a plan with no cap of its own still sells at a capped studio',
  (select count(*) from memberships
    where member_id = '5ea75ea7-0000-0000-0000-00000000dd04'
      and plan_id = '5ea75ea7-0000-0000-0000-0000000000c2'), 1);
select expect_num('...and it appears in no seat listing, because it has no seats',
  (select count(*) from plan_seats('5ea75ea7-0000-0000-0000-000000000001')
    where plan_id = '5ea75ea7-0000-0000-0000-0000000000c2'), 0);
reset role;

-- =============================================================================
-- 4. FROZEN KEEPS THE SEAT AND THE RATE
--
-- This is what freezing is for. A member who pauses for January and comes back
-- to find her place sold and the price raised has been given a cancellation
-- with extra steps.
-- =============================================================================
update memberships set status = 'frozen',
       freeze_start = studio_today('5ea75ea7-0000-0000-0000-000000000001'),
       freeze_end   = studio_today('5ea75ea7-0000-0000-0000-000000000001') + 30
 where member_id = '5ea75ea7-0000-0000-0000-00000000dd03'
   and plan_id = '5ea75ea7-0000-0000-0000-0000000000c1';

select expect_num('a frozen member still holds her place',
  (select taken from plan_seats('5ea75ea7-0000-0000-0000-000000000001')
    where plan_id = '5ea75ea7-0000-0000-0000-0000000000c1'), 3);

set role authenticated;
select set_config('request.jwt.claim.sub','5ea75ea7-0000-0000-0000-0000000000a2',false);
select expect_raises('...so the plan is still full and still refuses',
  $$select record_manual_payment('5ea75ea7-0000-0000-0000-000000000001',
      '5ea75ea7-0000-0000-0000-00000000dd05','plan', 1200000,'cash',
      p_plan_id => '5ea75ea7-0000-0000-0000-0000000000c1')$$, 'PT409');
reset role;

-- The rate. Raised as POSTGRES, and the rise is asserted before anything is
-- concluded from it: plans_manager_write is manager-up, and a refused UPDATE
-- in a front-desk session changes nothing and raises nothing — which is how a
-- hollow assertion of exactly this shape got into the due-list suite.
update membership_plans set price_cents = 1500000
 where id = '5ea75ea7-0000-0000-0000-0000000000c1';
select expect_num('(the studio really did raise the price)',
  (select price_cents from membership_plans
    where id = '5ea75ea7-0000-0000-0000-0000000000c1'), 1500000);
select expect_num('a frozen member keeps the rate she agreed to',
  (select price_cents from memberships
    where member_id = '5ea75ea7-0000-0000-0000-00000000dd03'
      and plan_id = '5ea75ea7-0000-0000-0000-0000000000c1'), 1200000);

-- =============================================================================
-- 5. PAST DUE KEEPS THE SEAT
--
-- A member who owes money has not left. Selling her place the day a card fails
-- is not what §7.3's grace period means.
-- =============================================================================
update memberships set status = 'past_due'
 where member_id = '5ea75ea7-0000-0000-0000-00000000dd02'
   and plan_id = '5ea75ea7-0000-0000-0000-0000000000c1';
select expect_num('a member in arrears still holds her place',
  (select taken from plan_seats('5ea75ea7-0000-0000-0000-000000000001')
    where plan_id = '5ea75ea7-0000-0000-0000-0000000000c1'), 3);

-- =============================================================================
-- 6. CANCELLING FREES THE PLACE, AND THE RATE LEAVES WITH HER
-- =============================================================================
update memberships set status = 'cancelled'
 where member_id = '5ea75ea7-0000-0000-0000-00000000dd01'
   and plan_id = '5ea75ea7-0000-0000-0000-0000000000c1';

select expect_num('cancelling frees the place',
  (select taken from plan_seats('5ea75ea7-0000-0000-0000-000000000001')
    where plan_id = '5ea75ea7-0000-0000-0000-0000000000c1'), 2);
select expect_false('...so the plan is not full any more',
  (select is_full from plan_seats('5ea75ea7-0000-0000-0000-000000000001')
    where plan_id = '5ea75ea7-0000-0000-0000-0000000000c1'));

set role authenticated;
select set_config('request.jwt.claim.sub','5ea75ea7-0000-0000-0000-0000000000a2',false);
select record_manual_payment('5ea75ea7-0000-0000-0000-000000000001',
  '5ea75ea7-0000-0000-0000-00000000dd05','plan', 1500000,'cash',
  p_plan_id => '5ea75ea7-0000-0000-0000-0000000000c1');
select expect_num('somebody else takes the freed place',
  (select taken from plan_seats('5ea75ea7-0000-0000-0000-000000000001')
    where plan_id = '5ea75ea7-0000-0000-0000-0000000000c1'), 3);

-- And the member who left does NOT come back on her old terms: the plan is
-- full again, and §7.1 snapshots the price at purchase, so there is nothing
-- left of the rate she had.
select expect_raises('...and the member who cancelled cannot simply come back',
  $$select record_manual_payment('5ea75ea7-0000-0000-0000-000000000001',
      '5ea75ea7-0000-0000-0000-00000000dd01','plan', 1500000,'cash',
      p_plan_id => '5ea75ea7-0000-0000-0000-0000000000c1')$$, 'PT409');
select expect_num('...her cancelled row keeps the old price and grants nothing',
  (select price_cents from memberships
    where member_id = '5ea75ea7-0000-0000-0000-00000000dd01'
      and plan_id = '5ea75ea7-0000-0000-0000-0000000000c1'), 1200000);
select expect_num('...while the member who took her place pays today''s price',
  (select price_cents from memberships
    where member_id = '5ea75ea7-0000-0000-0000-00000000dd05'
      and plan_id = '5ea75ea7-0000-0000-0000-0000000000c1'), 1500000);

-- =============================================================================
-- 7. A RENEWAL IS NOT A SECOND PLACE
--
-- The plan is full. Decision 23 makes the desk taking next month's cash a
-- renewal of the membership that exists, so it must not be stopped by a cap
-- the renewing member is already inside.
-- =============================================================================
select expect_true('(the plan is full before the renewal)',
  (select is_full from plan_seats('5ea75ea7-0000-0000-0000-000000000001')
    where plan_id = '5ea75ea7-0000-0000-0000-0000000000c1'));
select set_config('t.before',
  (select current_period_end::text from memberships
    where member_id = '5ea75ea7-0000-0000-0000-00000000dd05'
      and plan_id = '5ea75ea7-0000-0000-0000-0000000000c1'), false);

select record_manual_payment('5ea75ea7-0000-0000-0000-000000000001',
  '5ea75ea7-0000-0000-0000-00000000dd05','plan', 1500000,'cash',
  p_plan_id => '5ea75ea7-0000-0000-0000-0000000000c1');

select expect_num('a member already on a full plan can still pay for next month',
  (select count(*) from memberships
    where member_id = '5ea75ea7-0000-0000-0000-00000000dd05'
      and plan_id = '5ea75ea7-0000-0000-0000-0000000000c1'), 1);
select expect_true('...and the period moved rather than a second place being taken',
  (select current_period_end > current_setting('t.before')::timestamptz
     from memberships
    where member_id = '5ea75ea7-0000-0000-0000-00000000dd05'
      and plan_id = '5ea75ea7-0000-0000-0000-0000000000c1'));
select expect_num('...the count is unchanged',
  (select taken from plan_seats('5ea75ea7-0000-0000-0000-000000000001')
    where plan_id = '5ea75ea7-0000-0000-0000-0000000000c1'), 3);
reset role;

-- =============================================================================
-- 8. MONEY THAT HAS ALREADY MOVED IS HONOURED
--
-- A Stripe checkout that completes against a plan which filled up while the
-- member was typing their card is not refused. Raising here would return a
-- non-2xx, be retried for days, and leave somebody who has paid holding no
-- membership at all. The studio goes one over and every screen says so.
-- =============================================================================
select expect_text('a completed checkout creates the membership anyway',
  stripe_handle_checkout_completed('5ea75ea7-0000-0000-0000-000000000001', jsonb_build_object(
    'metadata', jsonb_build_object(
      'kind','plan',
      'member_id','5ea75ea7-0000-0000-0000-00000000dd04',
      'plan_id','5ea75ea7-0000-0000-0000-0000000000c1',
      'price_cents','1500000'),
    'amount_total', 1500000,
    'currency','php',
    'payment_intent','pi_5ea7_test',
    'customer','cus_5ea7_test')),
  'membership_created');

select expect_num('...and the studio is over its cap, honestly counted',
  (select taken from plan_seats('5ea75ea7-0000-0000-0000-000000000001')
    where plan_id = '5ea75ea7-0000-0000-0000-0000000000c1'), 4);
select expect_true('...over, not merely full',
  (select is_over from plan_seats('5ea75ea7-0000-0000-0000-000000000001')
    where plan_id = '5ea75ea7-0000-0000-0000-0000000000c1'));
select expect_num('...with remaining floored at nought rather than going negative',
  (select remaining from plan_seats('5ea75ea7-0000-0000-0000-000000000001')
    where plan_id = '5ea75ea7-0000-0000-0000-0000000000c1'), 0);
select expect_num('...the cap itself is still 3, so a screen can say "4 of 3"',
  (select cap from plan_seats('5ea75ea7-0000-0000-0000-000000000001')
    where plan_id = '5ea75ea7-0000-0000-0000-0000000000c1'), 3);

-- The desk is still refused while over, which is the point of being told.
set role authenticated;
select set_config('request.jwt.claim.sub','5ea75ea7-0000-0000-0000-0000000000a2',false);
select expect_raises_saying('a plan that is OVER still refuses a counter sale',
  $$select record_manual_payment('5ea75ea7-0000-0000-0000-000000000001',
      '5ea75ea7-0000-0000-0000-00000000dd01','plan', 1500000,'cash',
      p_plan_id => '5ea75ea7-0000-0000-0000-0000000000c1')$$,
  'PT409', '%4 of 3%');
reset role;

-- =============================================================================
-- 9. WHO MAY ASK
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','5ea75ea7-0000-0000-0000-0000000000a5',false);  -- other studio's owner
select expect_raises('another studio''s owner is refused by name',
  $$select * from plan_seats('5ea75ea7-0000-0000-0000-000000000001')$$, 'PT403');

select set_config('request.jwt.claim.sub','5ea75ea7-0000-0000-0000-0000000000a4',false);  -- instructor
select expect_raises('an instructor of this very studio is refused',
  $$select * from plan_seats('5ea75ea7-0000-0000-0000-000000000001')$$, 'PT403');

select set_config('request.jwt.claim.sub', null, false);
select expect_raises('a signed-in caller who is nothing to the studio is refused',
  $$select * from plan_seats('5ea75ea7-0000-0000-0000-000000000001')$$, 'PT403');
reset role;

set role anon;
select expect_raises('anon cannot execute it at all',
  $$select * from plan_seats('5ea75ea7-0000-0000-0000-000000000001')$$, '42501');
reset role;

set role authenticated;
select set_config('request.jwt.claim.sub','5ea75ea7-0000-0000-0000-0000000000b1',false);  -- a member
select expect_raises('a member cannot count another plan''s holders directly',
  $$select plan_seats_taken('5ea75ea7-0000-0000-0000-0000000000c1')$$, '42501');
select expect_num('a member sees the public capped plan',
  (select count(*) from plan_seats('5ea75ea7-0000-0000-0000-000000000001')
    where plan_id = '5ea75ea7-0000-0000-0000-0000000000c1'), 1);
select expect_num('...and never the hidden one',
  (select count(*) from plan_seats('5ea75ea7-0000-0000-0000-000000000001')
    where plan_id = '5ea75ea7-0000-0000-0000-0000000000c3'), 0);
reset role;

set role authenticated;
select set_config('request.jwt.claim.sub','5ea75ea7-0000-0000-0000-0000000000a2',false);
select expect_num('front desk sees both, hidden included',
  (select count(*) from plan_seats('5ea75ea7-0000-0000-0000-000000000001')), 2);
reset role;

-- =============================================================================
-- 10. A SETTING THAT COULD ONLY BE A MISTAKE IS REFUSED, NOT STORED
-- =============================================================================
select expect_raises('a "places left" threshold on an uncapped plan is refused',
  $$update membership_plans set show_remaining_below = 2
     where id = '5ea75ea7-0000-0000-0000-0000000000c2'$$, '23514');
select expect_raises('a cap of zero is refused — that is archiving, not capping',
  $$update membership_plans set max_active_members = 0
     where id = '5ea75ea7-0000-0000-0000-0000000000c1'$$, '23514');
select expect_raises('"waitlist" is not a thing this build does, so it cannot be stored',
  $$update membership_plans set on_limit_reached = 'waitlist'
     where id = '5ea75ea7-0000-0000-0000-0000000000c1'$$, '23514');
select expect_text('...and the two that ARE built are storable',
  (select on_limit_reached from membership_plans
    where id = '5ea75ea7-0000-0000-0000-0000000000c1'), 'hide');
update membership_plans set on_limit_reached = 'staff_only'
 where id = '5ea75ea7-0000-0000-0000-0000000000c1';
select expect_text('...both of them',
  (select on_limit_reached from plan_seats('5ea75ea7-0000-0000-0000-000000000001')
    where plan_id = '5ea75ea7-0000-0000-0000-0000000000c1'), 'staff_only');

-- =============================================================================
-- 11. TURNING THE SWITCH OFF SUSPENDS THE CAP AND KEEPS THE NUMBERS
-- =============================================================================
update studio_settings set seat_caps_enabled = false
 where studio_id = '5ea75ea7-0000-0000-0000-000000000001';

set role authenticated;
select set_config('request.jwt.claim.sub','5ea75ea7-0000-0000-0000-0000000000a2',false);
select expect_num('with the switch off the screens go blank again',
  (select count(*) from plan_seats('5ea75ea7-0000-0000-0000-000000000001')), 0);
select record_manual_payment('5ea75ea7-0000-0000-0000-000000000001',
  '5ea75ea7-0000-0000-0000-00000000dd01','plan', 1500000,'cash',
  p_plan_id => '5ea75ea7-0000-0000-0000-0000000000c1');
select expect_num('...and the sale that was refused a moment ago goes through',
  (select count(*) from memberships
    where member_id = '5ea75ea7-0000-0000-0000-00000000dd01'
      and plan_id = '5ea75ea7-0000-0000-0000-0000000000c1'
      and status = 'active'), 1);
reset role;

select expect_num('...the cap itself was kept, not wiped',
  (select max_active_members from membership_plans
    where id = '5ea75ea7-0000-0000-0000-0000000000c1'), 3);

update studio_settings set seat_caps_enabled = true
 where studio_id = '5ea75ea7-0000-0000-0000-000000000001';
set role authenticated;
select set_config('request.jwt.claim.sub','5ea75ea7-0000-0000-0000-0000000000a2',false);
select expect_num('switching back on finds the plan well over, and says so',
  (select taken from plan_seats('5ea75ea7-0000-0000-0000-000000000001')
    where plan_id = '5ea75ea7-0000-0000-0000-0000000000c1'), 5);
select expect_true('...over, and no further sale is possible until it is fixed',
  (select is_over from plan_seats('5ea75ea7-0000-0000-0000-000000000001')
    where plan_id = '5ea75ea7-0000-0000-0000-0000000000c1'));
reset role;

-- =============================================================================
-- 12. TWO STUDIOS ON DIFFERENT SETTINGS, ANSWERED IN ONE PASS
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','5ea75ea7-0000-0000-0000-0000000000a1',false);  -- owner of all three
select expect_num('the capped studio has one listing',
  (select count(*) from plan_seats('5ea75ea7-0000-0000-0000-000000000001')), 2);
select expect_num('...its neighbour with the switch off has none, in the same session',
  (select count(*) from plan_seats('5ea75ea7-0000-0000-0000-000000000002')), 0);
select expect_num('...and the third has none either',
  (select count(*) from plan_seats('5ea75ea7-0000-0000-0000-000000000003')), 0);
reset role;

-- =============================================================================
-- Done
-- =============================================================================
do $$
begin
  raise notice '--------------------------------------------------------------';
  raise notice 'seat caps: all assertions passed';
  raise notice '--------------------------------------------------------------';
end $$;
