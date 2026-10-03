-- =============================================================================
-- Decision 49 — membership actions, member_plan_overview, sales_history/totals.
-- =============================================================================
-- UUID space 5a1e, checked free. Run after `supabase db reset`.
--
-- SA (Prague) carries members in every plan_state and purchases across a month;
-- SB exists only to prove another studio's data never appears. The five actions
-- are manager-up (the owner runs the happy paths; front desk is refused), the
-- readers are desk-up (overview) / manager-up (sales), and a frozen membership
-- refuses booking with its own reason.
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

-- --- Fixtures: two studios, an owner and a front desk for SA -----------------
insert into studios (id, name, slug, timezone, currency, status) values
  ('5a1e5a1e-0000-0000-0000-0000000000a1','Sales A','5a1e-sa','Europe/Prague','CZK','active'),
  ('5a1e5a1e-0000-0000-0000-0000000000b1','Sales B','5a1e-sb','Europe/Prague','CZK','active');
insert into studio_settings (studio_id, require_waiver, booking_window_days) values
  ('5a1e5a1e-0000-0000-0000-0000000000a1', false, 400),
  ('5a1e5a1e-0000-0000-0000-0000000000b1', false, 400);
insert into locations (id, studio_id, name, is_primary) values
  ('5a1e5a1e-0000-0000-0000-0000000000aa','5a1e5a1e-0000-0000-0000-0000000000a1','Main',true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('5a1e5a1e-0000-0000-0000-00000000aa01','5a1e5a1e-0000-0000-0000-0000000000a1','5a1e5a1e-0000-0000-0000-0000000000aa','RA',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('5a1e5a1e-0000-0000-0000-0000000c7a01','5a1e5a1e-0000-0000-0000-0000000000a1','Reformer',50,10);
insert into instructors (id, studio_id, display_name) values
  ('5a1e5a1e-0000-0000-0000-000000001d01','5a1e5a1e-0000-0000-0000-0000000000a1','Ira One');

-- Staff logins: an owner (manager-up) and a front desk.
insert into auth.users (id) values
  ('5a1e5a1e-0000-0000-0000-0000000000f1'),  -- owner
  ('5a1e5a1e-0000-0000-0000-0000000000f2');  -- front desk
insert into profiles (id, email) values
  ('5a1e5a1e-0000-0000-0000-0000000000f1','5a1e-owner@example.com'),
  ('5a1e5a1e-0000-0000-0000-0000000000f2','5a1e-desk@example.com');
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('5a1e5a1e-0000-0000-0000-00000005f001','5a1e5a1e-0000-0000-0000-0000000000a1','5a1e5a1e-0000-0000-0000-0000000000f1','5a1e-owner@example.com','owner'),
  ('5a1e5a1e-0000-0000-0000-00000005f002','5a1e5a1e-0000-0000-0000-0000000000a1','5a1e5a1e-0000-0000-0000-0000000000f2','5a1e-desk@example.com','front_desk');

-- Plans: recurring (freeze allowed, 30 days), pack (no freeze, 10 credits), drop-in.
insert into membership_plans (id, studio_id, name, type, price_cents, currency,
                              credits, credits_per_period, validity_days, freeze_allowed, max_freeze_days,
                              billing_interval) values
  ('5a1e5a1e-0000-0000-0000-00000000a1a1','5a1e5a1e-0000-0000-0000-0000000000a1','Unlimited','recurring',300000,'CZK',null,null,null,true,30,'month'),
  ('5a1e5a1e-0000-0000-0000-00000000a1a2','5a1e5a1e-0000-0000-0000-0000000000a1','10-Pack','class_pack',150000,'CZK',10,null,60,false,null,null),
  ('5a1e5a1e-0000-0000-0000-00000000a1a3','5a1e5a1e-0000-0000-0000-0000000000a1','Drop-in','drop_in',10000,'CZK',1,null,30,false,null,null),
  ('5a1e5a1e-0000-0000-0000-00000000a1b1','5a1e5a1e-0000-0000-0000-0000000000b1','SB Plan','recurring',200000,'CZK',null,null,null,true,30,'month');

-- Members in SA: one per plan_state, plus a frozen one and an unpaid one.
-- M_ON on_plan, M_EXP expiring, M_XP expired, M_MIX expired-pack-then-active,
-- M_FREE free_only, M_NONE none, M_FRZ to freeze, M_UNP unpaid purchase.
insert into members (id, studio_id, email, first_name, last_name, status) values
  ('5a1e5a1e-0000-0000-0000-0000000e0001','5a1e5a1e-0000-0000-0000-0000000000a1','on@example.com','On','Plan','active'),
  ('5a1e5a1e-0000-0000-0000-0000000e0002','5a1e5a1e-0000-0000-0000-0000000000a1','exp@example.com','Ex','Piring','active'),
  ('5a1e5a1e-0000-0000-0000-0000000e0003','5a1e5a1e-0000-0000-0000-0000000000a1','xp@example.com','Ex','Pired','active'),
  ('5a1e5a1e-0000-0000-0000-0000000e0004','5a1e5a1e-0000-0000-0000-0000000000a1','mix@example.com','Mi','Xed','active'),
  ('5a1e5a1e-0000-0000-0000-0000000e0005','5a1e5a1e-0000-0000-0000-0000000000a1','free@example.com','Fre','Only','lead'),
  ('5a1e5a1e-0000-0000-0000-0000000e0006','5a1e5a1e-0000-0000-0000-0000000000a1','none@example.com','No','Plan','lead'),
  ('5a1e5a1e-0000-0000-0000-0000000e0007','5a1e5a1e-0000-0000-0000-0000000000a1','frz@example.com','Fro','Zen','active'),
  ('5a1e5a1e-0000-0000-0000-0000000e0008','5a1e5a1e-0000-0000-0000-0000000000a1','unp@example.com','Un','Paid','active'),
  ('5a1e5a1e-0000-0000-0000-0000000e00b1','5a1e5a1e-0000-0000-0000-0000000000b1','sb@example.com','Es','Bee','active');

-- A class occurrence in SA, a few days out, staffed (for the frozen-booking test).
insert into class_occurrences
  (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, booked_count,
   starts_at, ends_at, status)
values
  ('5a1e5a1e-0000-0000-0000-00000000cc01','5a1e5a1e-0000-0000-0000-0000000000a1','5a1e5a1e-0000-0000-0000-0000000000aa',
   '5a1e5a1e-0000-0000-0000-0000000c7a01','5a1e5a1e-0000-0000-0000-00000000aa01','5a1e5a1e-0000-0000-0000-000000001d01',
   'Reformer',10,0,
   ((current_date + 5) + time '07:00') at time zone 'Europe/Prague',
   ((current_date + 5) + time '07:50') at time zone 'Europe/Prague','scheduled');

-- Memberships + their originating payments, all dated THIS studio-local month so
-- the month totals are exactly these purchases (no stray drop-in payments).
do $$
declare
  sa  uuid := '5a1e5a1e-0000-0000-0000-0000000000a1';
  tz  text := 'Europe/Prague';
  td  date := (now() at time zone 'Europe/Prague')::date;
  m0  date := date_trunc('month', (now() at time zone 'Europe/Prague'))::date;
  buy timestamptz := (m0 + 2 + time '10:00') at time zone 'Europe/Prague';
begin
  -- M_ON: active recurring, paid.
  insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on, created_at)
  values ('5a1e5a1e-0000-0000-0000-00000000ad01', sa,'5a1e5a1e-0000-0000-0000-0000000e0001','5a1e5a1e-0000-0000-0000-00000000a1a1','active',300000,'CZK',m0, buy);
  insert into payments (studio_id, member_id, membership_id, amount_cents, currency, status, provider, method, paid_at)
  values (sa,'5a1e5a1e-0000-0000-0000-0000000e0001','5a1e5a1e-0000-0000-0000-00000000ad01',300000,'CZK','succeeded','manual','cash', buy);

  -- M_EXP: active pack, expires in 10 days, 5 credits, paid.
  insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on, expires_on, credits_remaining, created_at)
  values ('5a1e5a1e-0000-0000-0000-00000000ad02', sa,'5a1e5a1e-0000-0000-0000-0000000e0002','5a1e5a1e-0000-0000-0000-00000000a1a2','active',150000,'CZK',m0, td+10, 5, buy);
  insert into payments (studio_id, member_id, membership_id, amount_cents, currency, status, provider, method, paid_at)
  values (sa,'5a1e5a1e-0000-0000-0000-0000000e0002','5a1e5a1e-0000-0000-0000-00000000ad02',150000,'CZK','succeeded','manual','gcash', buy);

  -- M_XP: an expired pack, paid.
  insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on, expires_on, credits_remaining, created_at)
  values ('5a1e5a1e-0000-0000-0000-00000000ad03', sa,'5a1e5a1e-0000-0000-0000-0000000e0003','5a1e5a1e-0000-0000-0000-00000000a1a2','expired',150000,'CZK',m0, td-3, 0, buy);
  insert into payments (studio_id, member_id, membership_id, amount_cents, currency, status, provider, method, paid_at)
  values (sa,'5a1e5a1e-0000-0000-0000-0000000e0003','5a1e5a1e-0000-0000-0000-00000000ad03',150000,'CZK','succeeded','manual','cash', buy);

  -- M_MIX: an expired pack AND an active recurring -> on_plan.
  insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on, expires_on, credits_remaining, created_at)
  values ('5a1e5a1e-0000-0000-0000-00000000ad04', sa,'5a1e5a1e-0000-0000-0000-0000000e0004','5a1e5a1e-0000-0000-0000-00000000a1a2','expired',150000,'CZK',m0, td-3, 0, buy),
         ('5a1e5a1e-0000-0000-0000-00000000ad05', sa,'5a1e5a1e-0000-0000-0000-0000000e0004','5a1e5a1e-0000-0000-0000-00000000a1a1','active',300000,'CZK',m0, null, null, buy);
  insert into payments (studio_id, member_id, membership_id, amount_cents, currency, status, provider, method, paid_at)
  values (sa,'5a1e5a1e-0000-0000-0000-0000000e0004','5a1e5a1e-0000-0000-0000-00000000ad05',300000,'CZK','succeeded','manual','cash', buy);

  -- M_FREE: a guest_passes (free-first, host-null) row, never paid.
  insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email, occurrence_id, status)
  values (sa, null, '5a1e5a1e-0000-0000-0000-0000000e0005','free@example.com','5a1e5a1e-0000-0000-0000-00000000cc01','attended');

  -- M_FRZ: active recurring (to be frozen), paid.
  insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on, expires_on, created_at)
  values ('5a1e5a1e-0000-0000-0000-00000000ad07', sa,'5a1e5a1e-0000-0000-0000-0000000e0007','5a1e5a1e-0000-0000-0000-00000000a1a1','active',300000,'CZK',m0, td+40, buy);
  insert into payments (studio_id, member_id, membership_id, amount_cents, currency, status, provider, method, paid_at)
  values (sa,'5a1e5a1e-0000-0000-0000-0000000e0007','5a1e5a1e-0000-0000-0000-00000000ad07',300000,'CZK','succeeded','manual','cash', buy);

  -- M_UNP: a pack purchase marked but NOT paid (pending payment row), for mark-paid.
  insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on, expires_on, credits_remaining, created_at)
  values ('5a1e5a1e-0000-0000-0000-00000000ad08', sa,'5a1e5a1e-0000-0000-0000-0000000e0008','5a1e5a1e-0000-0000-0000-00000000a1a2','active',150000,'CZK',m0, td+60, 10, buy);

  -- SB: a membership + payment, same month, to prove isolation.
  insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on, created_at)
  values ('5a1e5a1e-0000-0000-0000-00000000adb1','5a1e5a1e-0000-0000-0000-0000000000b1','5a1e5a1e-0000-0000-0000-0000000e00b1','5a1e5a1e-0000-0000-0000-00000000a1b1','active',200000,'CZK',m0, buy);
  insert into payments (studio_id, member_id, membership_id, amount_cents, currency, status, provider, method, paid_at)
  values ('5a1e5a1e-0000-0000-0000-0000000000b1','5a1e5a1e-0000-0000-0000-0000000e00b1','5a1e5a1e-0000-0000-0000-00000000adb1',200000,'CZK','succeeded','manual','cash', buy);
end $$;

-- =============================================================================
-- A. member_plan_overview — plan_state for the five cases (run as front desk).
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','5a1e5a1e-0000-0000-0000-0000000000f2',false);

select expect_txt('plan_state: active recurring -> on_plan',
  (select plan_state from member_plan_overview('5a1e5a1e-0000-0000-0000-0000000000a1') where id='5a1e5a1e-0000-0000-0000-0000000e0001'), 'on_plan');
select expect_txt('plan_state: pack expiring in 10 days -> expiring',
  (select plan_state from member_plan_overview('5a1e5a1e-0000-0000-0000-0000000000a1') where id='5a1e5a1e-0000-0000-0000-0000000e0002'), 'expiring');
select expect_txt('plan_state: expired pack, nothing usable -> expired',
  (select plan_state from member_plan_overview('5a1e5a1e-0000-0000-0000-0000000000a1') where id='5a1e5a1e-0000-0000-0000-0000000e0003'), 'expired');
select expect_txt('plan_state: expired pack THEN active recurring -> on_plan',
  (select plan_state from member_plan_overview('5a1e5a1e-0000-0000-0000-0000000000a1') where id='5a1e5a1e-0000-0000-0000-0000000e0004'), 'on_plan');
select expect_txt('plan_state: free class only -> free_only',
  (select plan_state from member_plan_overview('5a1e5a1e-0000-0000-0000-0000000000a1') where id='5a1e5a1e-0000-0000-0000-0000000e0005'), 'free_only');
select expect_txt('plan_state: nothing -> none',
  (select plan_state from member_plan_overview('5a1e5a1e-0000-0000-0000-0000000000a1') where id='5a1e5a1e-0000-0000-0000-0000000e0006'), 'none');
select expect_true('free_only: had_free_class true, has_ever_paid false',
  (select had_free_class and not has_ever_paid from member_plan_overview('5a1e5a1e-0000-0000-0000-0000000000a1') where id='5a1e5a1e-0000-0000-0000-0000000e0005'));
select expect_true('on_plan shows the current plan name + credits/expiry',
  (select current_plan_name = '10-Pack' and expires_on is not null from member_plan_overview('5a1e5a1e-0000-0000-0000-0000000000a1') where id='5a1e5a1e-0000-0000-0000-0000000e0002'));
select expect_num('overview: no SB member appears',
  (select count(*) from member_plan_overview('5a1e5a1e-0000-0000-0000-0000000000a1') where id='5a1e5a1e-0000-0000-0000-0000000e00b1')::bigint, 0);
-- front desk may read the overview; it carries NO amounts (no amount column).
select expect_true('front desk can read member_plan_overview',
  (select count(*) > 0 from member_plan_overview('5a1e5a1e-0000-0000-0000-0000000000a1')));

-- front desk is refused Sales.
select expect_raises('front desk PT403 on sales_history',
  $$ select * from sales_history('5a1e5a1e-0000-0000-0000-0000000000a1',
       date_trunc('month', (now() at time zone 'Europe/Prague'))::date,
       (date_trunc('month', (now() at time zone 'Europe/Prague')) + interval '1 month - 1 day')::date) $$, 'PT403');
reset role;

-- =============================================================================
-- B. sales_history / sales_totals (owner), equality with dashboard_revenue.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','5a1e5a1e-0000-0000-0000-0000000000f1',false);

-- Five SA purchases (M_ON, M_EXP, M_XP, M_MIX, M_FRZ, M_UNP) land in the month;
-- M_MIX has two memberships so six purchases total, M_UNP unpaid.
select expect_num('sales_history: SA purchases this month',
  (select count(*) from sales_history('5a1e5a1e-0000-0000-0000-0000000000a1',
     date_trunc('month', (now() at time zone 'Europe/Prague'))::date,
     (date_trunc('month', (now() at time zone 'Europe/Prague')) + interval '1 month - 1 day')::date))::bigint, 7);
select expect_num('sales_history: no SB purchase appears',
  (select count(*) from sales_history('5a1e5a1e-0000-0000-0000-0000000000a1',
     date_trunc('month', (now() at time zone 'Europe/Prague'))::date,
     (date_trunc('month', (now() at time zone 'Europe/Prague')) + interval '1 month - 1 day')::date)
     where membership_id = '5a1e5a1e-0000-0000-0000-00000000adb1')::bigint, 0);
select expect_txt('sales status: the unpaid purchase reads unpaid',
  (select sale_status from sales_history('5a1e5a1e-0000-0000-0000-0000000000a1',
     date_trunc('month', (now() at time zone 'Europe/Prague'))::date,
     (date_trunc('month', (now() at time zone 'Europe/Prague')) + interval '1 month - 1 day')::date)
     where membership_id = '5a1e5a1e-0000-0000-0000-00000000ad08'), 'unpaid');
select expect_txt('sales status: the expiring pack reads expiring',
  (select sale_status from sales_history('5a1e5a1e-0000-0000-0000-0000000000a1',
     date_trunc('month', (now() at time zone 'Europe/Prague'))::date,
     (date_trunc('month', (now() at time zone 'Europe/Prague')) + interval '1 month - 1 day')::date)
     where membership_id = '5a1e5a1e-0000-0000-0000-00000000ad02'), 'expiring');

-- The unfiltered month total equals the dashboard's revenue for the month.
select expect_num('sales_totals gross == dashboard total_cents (all revenue is purchases)',
  (select (sales_totals('5a1e5a1e-0000-0000-0000-0000000000a1',
     date_trunc('month', (now() at time zone 'Europe/Prague'))::date,
     (date_trunc('month', (now() at time zone 'Europe/Prague')) + interval '1 month - 1 day')::date) ->> 'gross_cents')::bigint),
  (select (dashboard_revenue('5a1e5a1e-0000-0000-0000-0000000000a1',
     date_trunc('month', (now() at time zone 'Europe/Prague'))::date,
     (date_trunc('month', (now() at time zone 'Europe/Prague')) + interval '1 month - 1 day')::date) ->> 'total_cents')::bigint));
-- gross across the five paid purchases: 300000+150000+150000+300000+300000 = 1,200,000.
select expect_num('sales_totals gross == sum of paid SA purchases',
  (select (sales_totals('5a1e5a1e-0000-0000-0000-0000000000a1',
     date_trunc('month', (now() at time zone 'Europe/Prague'))::date,
     (date_trunc('month', (now() at time zone 'Europe/Prague')) + interval '1 month - 1 day')::date) ->> 'gross_cents')::bigint), 1200000);
-- plan filter: only the recurring plan's purchases (M_ON, M_MIX, M_FRZ = 3).
select expect_num('sales_history: filter by recurring plan',
  (select count(*) from sales_history('5a1e5a1e-0000-0000-0000-0000000000a1',
     date_trunc('month', (now() at time zone 'Europe/Prague'))::date,
     (date_trunc('month', (now() at time zone 'Europe/Prague')) + interval '1 month - 1 day')::date,
     '5a1e5a1e-0000-0000-0000-00000000a1a1'))::bigint, 3);
reset role;

-- =============================================================================
-- C. The actions — owner happy paths, guard, refusals, audit.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','5a1e5a1e-0000-0000-0000-0000000000f1',false);

-- End: M_ON (recurring, no credits). Sentence "Ended."; audit + email.
select expect_true('end_membership: sentence starts "Ended."',
  (end_membership('5a1e5a1e-0000-0000-0000-00000000ad01', false, 'moving away') ->> 'sentence') like 'Ended.%');
select expect_txt('end: membership is cancelled',
  (select status::text from memberships where id='5a1e5a1e-0000-0000-0000-00000000ad01'), 'cancelled');
select expect_num('end: a cancelled membership_event was written',
  (select count(*) from membership_events where membership_id='5a1e5a1e-0000-0000-0000-00000000ad01' and type='cancelled')::bigint, 1);
select expect_num('end: the member was emailed membership_ended',
  (select count(*) from notifications where member_id='5a1e5a1e-0000-0000-0000-0000000e0001' and template_key='membership_ended')::bigint, 1);
select expect_raises('end: already-ended membership -> PT409',
  $$ select end_membership('5a1e5a1e-0000-0000-0000-00000000ad01', false, 'again') $$, 'PT409');

-- Freeze: M_FRZ (recurring, freeze_allowed). Pack (M_EXP) cannot freeze.
select expect_true('freeze_membership: sentence',
  (freeze_membership('5a1e5a1e-0000-0000-0000-00000000ad07', ((now() at time zone 'Europe/Prague')::date + 10)) ->> 'sentence') like 'Paused until%');
select expect_txt('freeze: membership is frozen',
  (select status::text from memberships where id='5a1e5a1e-0000-0000-0000-00000000ad07'), 'frozen');
select expect_num('freeze: the member was emailed membership_frozen',
  (select count(*) from notifications where member_id='5a1e5a1e-0000-0000-0000-0000000e0007' and template_key='membership_frozen')::bigint, 1);
select expect_raises('freeze: a plan that cannot be paused -> PT422',
  $$ select freeze_membership('5a1e5a1e-0000-0000-0000-00000000ad02', ((now() at time zone 'Europe/Prague')::date + 10)) $$, 'PT422');

-- Booking is refused while frozen, with the membership_frozen reason.
select expect_txt('book_class while frozen -> membership_frozen',
  (book_class('5a1e5a1e-0000-0000-0000-00000000cc01','5a1e5a1e-0000-0000-0000-0000000e0007','member')).failure_reason, 'membership_frozen');

-- Unfreeze: status active, expiry pushed by the paused days.
select expect_true('unfreeze_membership: sentence',
  (unfreeze_membership('5a1e5a1e-0000-0000-0000-00000000ad07') ->> 'sentence') like 'Unpaused.%');
select expect_txt('unfreeze: membership is active again',
  (select status::text from memberships where id='5a1e5a1e-0000-0000-0000-00000000ad07'), 'active');
select expect_raises('unfreeze: a membership that is not paused -> PT409',
  $$ select unfreeze_membership('5a1e5a1e-0000-0000-0000-00000000ad07') $$, 'PT409');

-- Extend: reason required; expiry moved.
select expect_raises('extend: no reason -> PT400',
  $$ select extend_membership('5a1e5a1e-0000-0000-0000-00000000ad02', ((now() at time zone 'Europe/Prague')::date + 90), '') $$, 'PT400');
select expect_true('extend_membership: sentence',
  (extend_membership('5a1e5a1e-0000-0000-0000-00000000ad02', ((now() at time zone 'Europe/Prague')::date + 90), 'goodwill') ->> 'sentence') like 'Expiry moved to%');
select expect_num('extend: expiry moved out',
  (select (expires_on - (now() at time zone 'Europe/Prague')::date) from memberships where id='5a1e5a1e-0000-0000-0000-00000000ad02')::bigint, 90);

-- Mark paid: M_UNP once; a second time refuses.
select expect_true('mark_membership_paid: sentence',
  (mark_membership_paid('5a1e5a1e-0000-0000-0000-00000000ad08', 150000, 'cash') ->> 'sentence') = 'Marked paid.');
select expect_num('mark paid: a succeeded payment now exists',
  (select count(*) from payments where membership_id='5a1e5a1e-0000-0000-0000-00000000ad08' and status='succeeded')::bigint, 1);
select expect_raises('mark paid twice -> PT409',
  $$ select mark_membership_paid('5a1e5a1e-0000-0000-0000-00000000ad08', 150000, 'cash') $$, 'PT409');

-- Refund: M_MIX's active recurring (ms05) full refund, never Xendit.
select expect_txt('refund_membership: sentence names Xendit, not a push',
  (refund_membership('5a1e5a1e-0000-0000-0000-00000000ad05', null, 'card declined later') ->> 'sentence'),
  'Recorded. Refund the money in Xendit if it was paid there.');
select expect_txt('refund full: the payment is refunded',
  (select status::text from payments where membership_id='5a1e5a1e-0000-0000-0000-00000000ad05'), 'refunded');
select expect_txt('refund full: the membership is cancelled',
  (select status::text from memberships where id='5a1e5a1e-0000-0000-0000-00000000ad05'), 'cancelled');
select expect_raises('refund more than paid -> PT400',
  $$ select refund_membership('5a1e5a1e-0000-0000-0000-00000000ad07', 999999999, 'too much') $$, 'PT400');
select expect_raises('refund a never-paid purchase -> PT409',
  $$ select refund_membership('5a1e5a1e-0000-0000-0000-00000000ad04', null, 'nope') $$, 'PT409');

reset role;

-- =============================================================================
-- D. Guards — front desk is refused every action.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','5a1e5a1e-0000-0000-0000-0000000000f2',false);
select expect_raises('front desk PT403: end_membership',
  $$ select end_membership('5a1e5a1e-0000-0000-0000-00000000ad07', false, 'x') $$, 'PT403');
select expect_raises('front desk PT403: freeze_membership',
  $$ select freeze_membership('5a1e5a1e-0000-0000-0000-00000000ad07', ((now() at time zone 'Europe/Prague')::date + 5)) $$, 'PT403');
select expect_raises('front desk PT403: extend_membership',
  $$ select extend_membership('5a1e5a1e-0000-0000-0000-00000000ad07', ((now() at time zone 'Europe/Prague')::date + 5), 'x') $$, 'PT403');
select expect_raises('front desk PT403: mark_membership_paid',
  $$ select mark_membership_paid('5a1e5a1e-0000-0000-0000-00000000ad07', 1000, 'cash') $$, 'PT403');
select expect_raises('front desk PT403: refund_membership',
  $$ select refund_membership('5a1e5a1e-0000-0000-0000-00000000ad07', null, 'x') $$, 'PT403');
reset role;

-- =============================================================================
-- E. Isolation — SA owner cannot read SB through the readers.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','5a1e5a1e-0000-0000-0000-0000000000f1',false);
select expect_raises('SA owner PT403 on SB sales_history',
  $$ select * from sales_history('5a1e5a1e-0000-0000-0000-0000000000b1',
       date_trunc('month', (now() at time zone 'Europe/Prague'))::date,
       (date_trunc('month', (now() at time zone 'Europe/Prague')) + interval '1 month - 1 day')::date) $$, 'PT403');
select expect_raises('SA owner PT403 on SB member_plan_overview',
  $$ select * from member_plan_overview('5a1e5a1e-0000-0000-0000-0000000000b1') $$, 'PT403');
reset role;

select 'sales_test: all assertions passed' as result;
