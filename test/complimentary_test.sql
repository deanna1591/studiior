-- =============================================================================
-- Decision 61 — complimentary memberships are granted, not sold.
-- UUID space: c061
-- =============================================================================
\set A '''c061c061-0000-0000-0000-000000000001'''
\set B '''c061c061-0000-0000-0000-000000000002'''

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want::text,'null'), coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if coalesce(actual,false) then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if;
end $$;
create or replace function expect_raises(label text, sql text, code text)
returns void language plpgsql as $$
begin
  execute sql;
  raise exception 'FAIL  %  expected %, nothing raised', label, code;
exception when others then
  if sqlstate = code then raise notice 'PASS  %  (got %)', label, code;
  else raise exception 'FAIL  %  expected %, got % (%)', label, code, sqlstate, sqlerrm; end if;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('c061c061-0000-0000-0000-0000000000a1'),   -- owner A (manager-up)
  ('c061c061-0000-0000-0000-0000000000f1'),   -- front desk A
  ('c061c061-0000-0000-0000-0000000000b1');   -- owner B
insert into profiles (id, email) values
  ('c061c061-0000-0000-0000-0000000000a1','c061-owa@example.com'),
  ('c061c061-0000-0000-0000-0000000000f1','c061-fda@example.com'),
  ('c061c061-0000-0000-0000-0000000000b1','c061-owb@example.com');

insert into studios (id, name, slug, timezone, currency, status) values
  (:A,'Comp A','comp-a','Europe/Prague','CZK','active'),
  (:B,'Comp B','comp-b','Europe/Prague','CZK','active');
insert into studio_settings (studio_id, guarantees_enabled, core_min_bookings, core_cutoff_hours) values
  (:A, true, 1, 12), (:B, false, 1, 12);
insert into locations (id, studio_id, name, is_primary) values
  ('c061c061-0000-0000-0000-00000000000a',:A,'Main',true),
  ('c061c061-0000-0000-0000-00000000000b',:B,'Main',true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('c061c061-0000-0000-0000-0000000ee0a1',:A,'c061c061-0000-0000-0000-00000000000a','R',6);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity, session_kind) values
  ('c061c061-0000-0000-0000-0000000cc0a1',:A,'Group',50,6,'group');

insert into studio_staff (id, studio_id, user_id, email, role) values
  ('c061c061-0000-0000-0000-000000aa00a1',:A,'c061c061-0000-0000-0000-0000000000a1','c061-owa@example.com','owner'),
  ('c061c061-0000-0000-0000-000000aa00f1',:A,'c061c061-0000-0000-0000-0000000000f1','c061-fda@example.com','front_desk'),
  ('c061c061-0000-0000-0000-000000aa00b1',:B,'c061c061-0000-0000-0000-0000000000b1','c061-owb@example.com','owner'),
  ('c061c061-0000-0000-0000-000000aa00c1',:A,null,'c061-coach@example.com','instructor');
insert into instructors (id, studio_id, staff_id, display_name) values
  ('c061c061-0000-0000-0000-00000000d1a1',:A,'c061c061-0000-0000-0000-000000aa00c1','Cara Coach');

-- Plans on A: an unlimited recurring, a pack, an archived pack, and an
-- 8-a-period recurring (for the sweep roll). A plan on B (cross-studio).
insert into membership_plans (id, studio_id, name, type, price_cents, currency, billing_interval, credits_per_period, credits, validity_days, visibility, status) values
  ('c061c061-0000-0000-0000-000000000101',:A,'Complimentary — Team','recurring',999900,'CZK','month',null,null,null,'staff_only','active'),
  ('c061c061-0000-0000-0000-000000000102',:A,'10-Class Pack','class_pack',550000,'CZK',null,null,10,180,'public','active'),
  ('c061c061-0000-0000-0000-000000000103',:A,'Old Pack','class_pack',500000,'CZK',null,null,5,90,'public','archived'),
  ('c061c061-0000-0000-0000-000000000104',:A,'8 a Month','recurring',400000,'CZK','month',8,null,null,'public','active'),
  ('c061c061-0000-0000-0000-000000000105',:A,'Comp Nobody','recurring',0,'CZK','month',null,null,null,'staff_only','active'),
  ('c061c061-0000-0000-0000-000000000201',:B,'B Plan','class_pack',300000,'CZK',null,null,5,90,'public','active');

-- Members on A, plus one on B.
insert into members (id, studio_id, first_name, last_name, email, status, waiver_signed_at) values
  ('c061c061-0000-0000-0000-00000000a001',:A,'Pam','Pack','c061-pack@example.com','active',now()),
  ('c061c061-0000-0000-0000-00000000a002',:A,'Uma','Unlim','c061-unlim@example.com','active',now()),
  ('c061c061-0000-0000-0000-00000000a003',:A,'Ed','Ends','c061-ends@example.com','active',now()),
  ('c061c061-0000-0000-0000-00000000a004',:A,'Rae','Roll','c061-roll@example.com','active',now()),
  ('c061c061-0000-0000-0000-00000000a005',:A,'Cole','Comp','c061-comp@example.com','active',now()),
  ('c061c061-0000-0000-0000-00000000a006',:A,'Peta','Paid','c061-paid@example.com','active',now()),
  ('c061c061-0000-0000-0000-00000000a007',:A,'Rev','Revenue','c061-rev@example.com','active',now()),
  ('c061c061-0000-0000-0000-00000000b001',:B,'Bo','Bee','c061-bee@example.com','active',now());

-- An instructor rate so compute_class_pay_run returns pay.
select set_config('request.jwt.claim.sub','c061c061-0000-0000-0000-0000000000a1',false);
set role authenticated;
select set_instructor_rate('c061c061-0000-0000-0000-00000000d1a1', current_date - 60,
  80000, 7500, 2, 20000, 150000, 200000, 250000, 'senior');
reset role;

-- Two identical future occurrences for the booking/pay comparison.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name, capacity, starts_at, ends_at, instructor_id, status) values
  ('c061c061-0000-0000-0000-00000000cc01',:A,'c061c061-0000-0000-0000-00000000000a','c061c061-0000-0000-0000-0000000cc0a1','c061c061-0000-0000-0000-0000000ee0a1','Group',6, now()+interval '2 days', now()+interval '2 days'+interval '50 min','c061c061-0000-0000-0000-00000000d1a1','scheduled'),
  ('c061c061-0000-0000-0000-00000000cc02',:A,'c061c061-0000-0000-0000-00000000000a','c061c061-0000-0000-0000-0000000cc0a1','c061c061-0000-0000-0000-0000000ee0a1','Group',6, now()+interval '3 days', now()+interval '3 days'+interval '50 min','c061c061-0000-0000-0000-00000000d1a1','scheduled');

-- =============================================================================
-- 1. The grant — pack and unlimited
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','c061c061-0000-0000-0000-0000000000a1',false);

-- Pack: credits 10, no end date, active, complimentary, NO payment, audited.
select set_config('t.pack', (grant_complimentary_membership(
   'c061c061-0000-0000-0000-00000000a001','c061c061-0000-0000-0000-000000000102', null, 'owner') ->> 'message'), false);
select expect_text('pack grant sentence',
  current_setting('t.pack'), 'Granted 10-Class Pack to Pam Pack with no end date.');
reset role;
select expect_true('pack membership is active + complimentary + 10 credits',
  exists(select 1 from memberships where member_id='c061c061-0000-0000-0000-00000000a001'
         and plan_id='c061c061-0000-0000-0000-000000000102'
         and status='active' and complimentary and credits_remaining=10
         and complimentary_reason='owner'));
select expect_num('pack comp wrote NO payments row',
  (select count(*) from payments p join memberships m on m.id=p.membership_id
    where m.member_id='c061c061-0000-0000-0000-00000000a001' and m.complimentary), 0);
select expect_num('pack comp audited complimentary_granted',
  (select count(*) from membership_events me join memberships m on m.id=me.membership_id
    where m.member_id='c061c061-0000-0000-0000-00000000a001' and me.type='complimentary_granted'), 1);

-- Unlimited recurring: credits null (unlimited, Decision 12).
set role authenticated;
select set_config('request.jwt.claim.sub','c061c061-0000-0000-0000-0000000000a1',false);
select grant_complimentary_membership('c061c061-0000-0000-0000-00000000a002','c061c061-0000-0000-0000-000000000101', null, 'studio manager');
reset role;
select expect_true('unlimited comp has null credits_remaining (unlimited)',
  exists(select 1 from memberships where member_id='c061c061-0000-0000-0000-00000000a002'
         and complimentary and credits_remaining is null and status='active'));

-- With an end date: sentence + expires_on set.
set role authenticated;
select set_config('request.jwt.claim.sub','c061c061-0000-0000-0000-0000000000a1',false);
select set_config('t.ends', (grant_complimentary_membership(
   'c061c061-0000-0000-0000-00000000a003','c061c061-0000-0000-0000-000000000102',
   (current_date + 30), 'ambassador') ->> 'message'), false);
reset role;
select expect_text('ends-on grant sentence names the date',
  current_setting('t.ends'),
  'Granted 10-Class Pack to Ed Ends until ' || to_char(current_date + 30, 'FMDD Mon YYYY') || '.');
select expect_true('ends-on comp stored expires_on',
  exists(select 1 from memberships where member_id='c061c061-0000-0000-0000-00000000a003'
         and complimentary and expires_on = current_date + 30));

-- =============================================================================
-- 2. The refusals
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','c061c061-0000-0000-0000-0000000000a1',false);
select expect_raises('archived plan refused PT409',
  $$select grant_complimentary_membership('c061c061-0000-0000-0000-00000000a007','c061c061-0000-0000-0000-000000000103', null, 'owner')$$, 'PT409');
select expect_raises('blank reason refused PT400',
  $$select grant_complimentary_membership('c061c061-0000-0000-0000-00000000a007','c061c061-0000-0000-0000-000000000102', null, '   ')$$, 'PT400');
select expect_raises('past end date refused PT400',
  $$select grant_complimentary_membership('c061c061-0000-0000-0000-00000000a007','c061c061-0000-0000-0000-000000000102', (current_date - 1), 'owner')$$, 'PT400');
select expect_raises('already on that plan refused PT409',
  $$select grant_complimentary_membership('c061c061-0000-0000-0000-00000000a001','c061c061-0000-0000-0000-000000000102', null, 'owner')$$, 'PT409');
reset role;
-- Front desk cannot grant.
set role authenticated;
select set_config('request.jwt.claim.sub','c061c061-0000-0000-0000-0000000000f1',false);
select expect_raises('front desk refused PT403',
  $$select grant_complimentary_membership('c061c061-0000-0000-0000-00000000a007','c061c061-0000-0000-0000-000000000102', null, 'owner')$$, 'PT403');
reset role;
-- A's owner cannot grant to B's member (cross-studio).
set role authenticated;
select set_config('request.jwt.claim.sub','c061c061-0000-0000-0000-0000000000a1',false);
select expect_raises('cross-studio refused PT403',
  $$select grant_complimentary_membership('c061c061-0000-0000-0000-00000000b001','c061c061-0000-0000-0000-000000000201', null, 'owner')$$, 'PT403');
reset role;

-- =============================================================================
-- 3. Money readers are unchanged by a comp grant
-- =============================================================================
-- Capture before, grant a comp to a fresh member, capture after — equal.
select set_config('t.rev0',   (dashboard_revenue(:A, current_date - 90, current_date) ->> 'total_cents'), false);
select set_config('t.sold0',  ((dashboard_revenue(:A, current_date - 90, current_date) -> 'counts' ->> 'memberships_sold')), false);
select set_config('t.scount0',((sales_totals(:A, current_date - 90, current_date) ->> 'count')), false);
select set_config('t.sgross0',((sales_totals(:A, current_date - 90, current_date) ->> 'gross_cents')), false);
select set_config('t.shist0', (select count(*)::text from sales_history(:A, current_date - 90, current_date)), false);

set role authenticated;
select set_config('request.jwt.claim.sub','c061c061-0000-0000-0000-0000000000a1',false);
select grant_complimentary_membership('c061c061-0000-0000-0000-00000000a007','c061c061-0000-0000-0000-000000000102', null, 'ambassador');
reset role;

select expect_text('dashboard revenue total unchanged by a comp',
  (dashboard_revenue(:A, current_date - 90, current_date) ->> 'total_cents'), current_setting('t.rev0'));
select expect_text('memberships_sold unchanged by a comp',
  (dashboard_revenue(:A, current_date - 90, current_date) -> 'counts' ->> 'memberships_sold'), current_setting('t.sold0'));
select expect_text('sales_totals count unchanged by a comp',
  (sales_totals(:A, current_date - 90, current_date) ->> 'count'), current_setting('t.scount0'));
select expect_text('sales_totals gross unchanged by a comp',
  (sales_totals(:A, current_date - 90, current_date) ->> 'gross_cents'), current_setting('t.sgross0'));
select expect_num('sales_history count unchanged by a comp',
  (select count(*) from sales_history(:A, current_date - 90, current_date)), current_setting('t.shist0')::bigint);

-- =============================================================================
-- 4. member_plan_overview flags the comp
-- =============================================================================
select expect_true('member_plan_overview: comp member on_plan + complimentary',
  exists(select 1 from member_plan_overview(:A) o
          where o.id='c061c061-0000-0000-0000-00000000a001'
            and o.plan_state='on_plan' and o.complimentary));
select expect_true('member_plan_overview: a non-comp member is complimentary=false',
  exists(select 1 from member_plan_overview(:A) o
          where o.id='c061c061-0000-0000-0000-00000000a006' and not o.complimentary));

-- =============================================================================
-- 4b. A member can READ their own comp plan, even when it is staff-only
--     (Decision 61 follow-up / migration 225). The app shows the plan name.
-- =============================================================================
reset role;
insert into auth.users (id) values ('c061c061-0000-0000-0000-0000000000c5');
insert into profiles (id, email) values ('c061c061-0000-0000-0000-0000000000c5','c061-login@example.com');
insert into members (id, studio_id, user_id, first_name, last_name, email, status, waiver_signed_at) values
  ('c061c061-0000-0000-0000-00000000a008',:A,'c061c061-0000-0000-0000-0000000000c5','Lena','Login','c061-login@example.com','active',now());
-- Owner grants the staff-only unlimited comp to the logged-in member.
set role authenticated;
select set_config('request.jwt.claim.sub','c061c061-0000-0000-0000-0000000000a1',false);
select grant_complimentary_membership('c061c061-0000-0000-0000-00000000a008','c061c061-0000-0000-0000-000000000101', null, 'owner');
reset role;
-- As that MEMBER, the staff-only plan they are on is readable (name + type).
set role authenticated;
select set_config('request.jwt.claim.sub','c061c061-0000-0000-0000-0000000000c5',false);
select expect_true('a member can read the name/type of their own staff-only comp plan',
  exists(select 1 from membership_plans where id='c061c061-0000-0000-0000-000000000101'
         and name='Complimentary — Team' and type='recurring'));
select expect_num('...and still cannot read a staff-only plan they are NOT on',
  (select count(*) from membership_plans where id='c061c061-0000-0000-0000-000000000105'), 0);
reset role;

-- =============================================================================
-- 5. The sweep rolls a comp recurring, never past_due
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','c061c061-0000-0000-0000-0000000000a1',false);
select grant_complimentary_membership('c061c061-0000-0000-0000-00000000a004','c061c061-0000-0000-0000-000000000104', null, 'owner');
reset role;
-- Simulate the period having ended.
update memberships set current_period_end = now() - interval '1 hour'
 where member_id='c061c061-0000-0000-0000-00000000a004';
select sweep_membership_periods();
-- RED without the re-issue: the old sweep marks this past_due. The fix excludes
-- comps from past_due and rolls the period instead.
select expect_true('comp recurring is still active after the sweep (not past_due)',
  (select status='active' from memberships where member_id='c061c061-0000-0000-0000-00000000a004'));
select expect_true('comp recurring period rolled forward (period end in the future)',
  (select current_period_end > now() from memberships where member_id='c061c061-0000-0000-0000-00000000a004'));

-- =============================================================================
-- 6. A comp member counts as a head exactly like a paid one (Decision 22)
-- =============================================================================
-- Cole (comp, unlimited) books cc01; Peta (paid, unlimited) books cc02.
set role authenticated;
select set_config('request.jwt.claim.sub','c061c061-0000-0000-0000-0000000000a1',false);
select grant_complimentary_membership('c061c061-0000-0000-0000-00000000a005','c061c061-0000-0000-0000-000000000101', null, 'owner');
reset role;
-- Peta gets a PAID unlimited membership (activate + a payment row), so she is a
-- real paying attendee to compare against.
select activate_purchase(:A,'c061c061-0000-0000-0000-00000000a006','c061c061-0000-0000-0000-000000000101', 999900, 'CZK'::char(3));
insert into payments (studio_id, member_id, membership_id, amount_cents, currency, status, provider, method, paid_at)
  select :A,'c061c061-0000-0000-0000-00000000a006', ms.id, 999900, 'CZK', 'succeeded', 'manual', 'cash', now()
    from memberships ms where ms.member_id='c061c061-0000-0000-0000-00000000a006';

set role authenticated;
select set_config('request.jwt.claim.sub','c061c061-0000-0000-0000-0000000000a1',false);
select book_class('c061c061-0000-0000-0000-00000000cc01','c061c061-0000-0000-0000-00000000a005','staff');
select book_class('c061c061-0000-0000-0000-00000000cc02','c061c061-0000-0000-0000-00000000a006','staff');
reset role;

select expect_num('a comp booking takes a seat (booked_count 1)',
  (select booked_count from class_occurrences where id='c061c061-0000-0000-0000-00000000cc01'), 1);
select expect_num('a paid booking takes a seat (booked_count 1)',
  (select booked_count from class_occurrences where id='c061c061-0000-0000-0000-00000000cc02'), 1);

-- Snapshot the cutoff headcount and compare instructor pay: identical, because a
-- head is a head whether comp or paid (Decision 22).
update class_occurrences set booked_at_cutoff = booked_count
 where id in ('c061c061-0000-0000-0000-00000000cc01','c061c061-0000-0000-0000-00000000cc02');
select expect_text('instructor pay is equal for the comp attendee and the paid attendee',
  (compute_class_pay_run('c061c061-0000-0000-0000-00000000cc01') ->> 'amount_cents'),
  (compute_class_pay_run('c061c061-0000-0000-0000-00000000cc02') ->> 'amount_cents'));
select expect_true('and that pay is a real positive amount',
  ((compute_class_pay_run('c061c061-0000-0000-0000-00000000cc01') ->> 'amount_cents')::int > 0));

-- =============================================================================
-- 7. A comp can never be marked paid or refunded
-- =============================================================================
select set_config('t.compms', (select id::text from memberships
   where member_id='c061c061-0000-0000-0000-00000000a001' and complimentary), false);
set role authenticated;
select set_config('request.jwt.claim.sub','c061c061-0000-0000-0000-0000000000a1',false);
select expect_raises('mark_membership_paid on a comp -> PT409',
  format($$select mark_membership_paid(%L, 100, 'cash')$$, current_setting('t.compms')), 'PT409');
select expect_raises('refund_membership on a comp -> PT409',
  format($$select refund_membership(%L, 100, 'x', false)$$, current_setting('t.compms')), 'PT409');
reset role;

select 'ALL COMPLIMENTARY TESTS PASSED' as result;
