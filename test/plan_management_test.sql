-- =============================================================================
-- STUDIIOR — MEMBERSHIP PLAN MANAGEMENT TEST
--
-- Permissions §9: "Create / edit plans" is Owner and Manager. Front desk may
-- VIEW plans (they sell them) but not write. Instructors get nothing at all.
-- Enforced by policy, not by hiding menu items.
--
-- Plus the two editing rules that cost money if they are wrong:
--   * a plan with members on it cannot be deleted
--   * editing a plan's price does not change what existing members pay,
--     because memberships.price_cents is snapshotted at purchase (§7.1)
--
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -f test/plan_management_test.sql
--
-- Local stack only — it inserts fixtures.
-- =============================================================================

\set ON_ERROR_STOP on
set client_min_messages = notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then
    raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else
    raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null');
  end if;
end $$;

-- "Refused" means nothing happened, which is not the same as an error.
--
-- RLS blocks an INSERT with a WITH CHECK violation, which raises. But it blocks
-- an UPDATE or DELETE by making the row invisible, so the statement succeeds
-- and touches zero rows. A test that only catches exceptions would call that
-- "allowed" and pass while the policy is doing its job — and an application
-- that only checks for an error would tell the user their edit saved when it
-- did not. So a write counts as allowed only if it actually changed something.
create or replace function expect_write(label text, sql text, want_ok boolean)
returns void language plpgsql as $$
declare got_ok boolean; n int;
begin
  begin
    execute sql;
    get diagnostics n = row_count;
    got_ok := n > 0;
  exception when others then
    got_ok := false;
  end;
  if got_ok = want_ok then
    raise notice 'PASS  %  (%)', label, case when got_ok then 'allowed' else 'refused' end;
  else
    raise exception 'FAIL  %  expected %, got %', label,
      case when want_ok then 'allowed' else 'refused' end,
      case when got_ok then 'allowed' else 'refused' end;
  end if;
end $$;

create or replace function login(uid text) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', uid, false);
end $$;

-- --- Fixtures: studio P, its own UUID space -------------------------------

insert into auth.users (id) values
  ('77777777-0000-0000-0000-0000000000a1'),   -- owner
  ('77777777-0000-0000-0000-0000000000a2'),   -- manager
  ('77777777-0000-0000-0000-0000000000a3'),   -- front desk
  ('77777777-0000-0000-0000-0000000000a4'),   -- instructor
  ('77777777-0000-0000-0000-0000000000a5');   -- member

insert into profiles (id, email) values
  ('77777777-0000-0000-0000-0000000000a1','ownerP@example.com'),
  ('77777777-0000-0000-0000-0000000000a2','managerP@example.com'),
  ('77777777-0000-0000-0000-0000000000a3','deskP@example.com'),
  ('77777777-0000-0000-0000-0000000000a4','instrP@example.com'),
  ('77777777-0000-0000-0000-0000000000a5','memberP@example.com');

insert into studios (id, name, slug, timezone, currency) values
  ('77777777-0000-0000-0000-000000000001','Plan Studio','plan-test','Europe/Prague','CZK');
insert into studio_settings (studio_id) values ('77777777-0000-0000-0000-000000000001');

insert into studio_staff (id, studio_id, user_id, email, role) values
  ('77777777-0000-0000-0000-0000000000f1','77777777-0000-0000-0000-000000000001','77777777-0000-0000-0000-0000000000a1','ownerP@example.com','owner'),
  ('77777777-0000-0000-0000-0000000000f2','77777777-0000-0000-0000-000000000001','77777777-0000-0000-0000-0000000000a2','managerP@example.com','manager'),
  ('77777777-0000-0000-0000-0000000000f3','77777777-0000-0000-0000-000000000001','77777777-0000-0000-0000-0000000000a3','deskP@example.com','front_desk'),
  ('77777777-0000-0000-0000-0000000000f4','77777777-0000-0000-0000-000000000001','77777777-0000-0000-0000-0000000000a4','instrP@example.com','instructor');

insert into instructors (id, studio_id, staff_id, display_name) values
  ('77777777-0000-0000-0000-0000000000e1','77777777-0000-0000-0000-000000000001','77777777-0000-0000-0000-0000000000f4','Instructor P');

insert into members (id, studio_id, user_id, first_name, last_name, email, waiver_signed_at) values
  ('77777777-0000-0000-0000-0000000000d1','77777777-0000-0000-0000-000000000001','77777777-0000-0000-0000-0000000000a5','Mona','Planholder','mona.planholder@example.com', now());

insert into membership_plans
  (id, studio_id, name, type, price_cents, currency, billing_interval, credits_per_period)
values
  ('77777777-0000-0000-0000-00000000ba01','77777777-0000-0000-0000-000000000001',
   'Unlimited Monthly','recurring',280000,'CZK','month',null),
  ('77777777-0000-0000-0000-00000000ba02','77777777-0000-0000-0000-000000000001',
   'Unsold Plan','recurring',150000,'CZK','month',4);

-- Mona bought the first plan at 2800.00 CZK. That number is now hers.
insert into memberships
  (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on)
values
  ('77777777-0000-0000-1111-000000000001','77777777-0000-0000-0000-000000000001',
   '77777777-0000-0000-0000-0000000000d1','77777777-0000-0000-0000-00000000ba01',
   'active', 280000, 'CZK', current_date);

set role authenticated;

-- =============================================================================
-- 1. Who may write a plan — Permissions §9
-- =============================================================================

select login('77777777-0000-0000-0000-0000000000a1');   -- owner
select expect_write('owner can create a plan',
  $$insert into membership_plans (studio_id, name, type, price_cents, currency)
    values ('77777777-0000-0000-0000-000000000001','Owner Made','class_pack',50000,'CZK')$$, true);
select expect_write('owner can edit a plan',
  $$update membership_plans set description = 'edited by owner'
     where id = '77777777-0000-0000-0000-00000000ba02'$$, true);

select login('77777777-0000-0000-0000-0000000000a2');   -- manager
select expect_write('manager can create a plan',
  $$insert into membership_plans (studio_id, name, type, price_cents, currency)
    values ('77777777-0000-0000-0000-000000000001','Manager Made','class_pack',50000,'CZK')$$, true);
select expect_write('manager can edit a plan',
  $$update membership_plans set description = 'edited by manager'
     where id = '77777777-0000-0000-0000-00000000ba02'$$, true);
select expect_write('manager can archive a plan',
  $$update membership_plans set status = 'archived'
     where id = '77777777-0000-0000-0000-00000000ba02'$$, true);
select expect_write('manager can delete a plan nobody bought',
  $$delete from membership_plans where name = 'Manager Made'$$, true);

-- Front desk sells plans, so §9 lets them VIEW. Writing is Owner and Manager.
select login('77777777-0000-0000-0000-0000000000a3');   -- front desk
select expect_num('front desk CAN see plans (§9, they sell them)',
  (select count(*) from membership_plans), 3);
select expect_write('front desk CANNOT create a plan',
  $$insert into membership_plans (studio_id, name, type, price_cents, currency)
    values ('77777777-0000-0000-0000-000000000001','Desk Made','class_pack',50000,'CZK')$$, false);
select expect_write('front desk CANNOT edit a plan',
  $$update membership_plans set price_cents = 1
     where id = '77777777-0000-0000-0000-00000000ba01'$$, false);
select expect_write('front desk CANNOT delete a plan',
  $$delete from membership_plans where id = '77777777-0000-0000-0000-00000000ba02'$$, false);
select expect_num('front desk sees no plan templates',
  (select count(*) from plan_templates), 0);

-- Instructors get nothing. Not a hidden nav item — the rows are not there.
select login('77777777-0000-0000-0000-0000000000a4');   -- instructor
select expect_num('instructor sees NO plans at all',
  (select count(*) from membership_plans), 0);
select expect_write('instructor CANNOT create a plan',
  $$insert into membership_plans (studio_id, name, type, price_cents, currency)
    values ('77777777-0000-0000-0000-000000000001','Instr Made','class_pack',50000,'CZK')$$, false);
select expect_write('instructor CANNOT edit a plan',
  $$update membership_plans set price_cents = 1
     where id = '77777777-0000-0000-0000-00000000ba01'$$, false);
select expect_num('instructor sees no plan templates',
  (select count(*) from plan_templates), 0);

-- Members see public plans only, and never templates.
select login('77777777-0000-0000-0000-0000000000a5');   -- member
select expect_write('member CANNOT create a plan',
  $$insert into membership_plans (studio_id, name, type, price_cents, currency)
    values ('77777777-0000-0000-0000-000000000001','Member Made','class_pack',50000,'CZK')$$, false);
select expect_num('member sees no plan templates',
  (select count(*) from plan_templates), 0);

-- =============================================================================
-- 2. Templates — Owner and Manager only, system ones are read-only
-- =============================================================================

select login('77777777-0000-0000-0000-0000000000a2');   -- manager
select expect_num('manager sees the 6 system templates',
  (select count(*) from plan_templates where studio_id is null), 6);
select expect_num('system templates carry no price',
  (select count(*) from plan_templates where studio_id is null and price_cents is not null), 0);
select expect_write('manager CANNOT edit a system template',
  $$update plan_templates set name = 'hijacked' where studio_id is null$$, false);
select expect_num('and it is unchanged',
  (select count(*) from plan_templates where name = 'hijacked'), 0);
select expect_write('manager can save a template for their own studio',
  $$insert into plan_templates (studio_id, name, type)
    values ('77777777-0000-0000-0000-000000000001','Our House Pack','class_pack')$$, true);

-- =============================================================================
-- 3. A plan with members on it cannot be deleted
-- =============================================================================

select login('77777777-0000-0000-0000-0000000000a1');   -- owner
select expect_write('owner CANNOT delete a plan with an active membership',
  $$delete from membership_plans where id = '77777777-0000-0000-0000-00000000ba01'$$, false);
select expect_num('the plan is still there',
  (select count(*) from membership_plans where id = '77777777-0000-0000-0000-00000000ba01'), 1);
select expect_num('and so is the membership',
  (select count(*) from memberships where plan_id = '77777777-0000-0000-0000-00000000ba01'), 1);

select expect_write('archiving it instead is allowed',
  $$update membership_plans set status = 'archived'
     where id = '77777777-0000-0000-0000-00000000ba01'$$, true);
select expect_num('the membership survives archiving',
  (select count(*) from memberships
    where plan_id = '77777777-0000-0000-0000-00000000ba01' and status = 'active'), 1);

-- =============================================================================
-- 4. Editing a price does not reprice anybody — §7.1
-- =============================================================================

select expect_num('Mona bought at 280000',
  (select price_cents from memberships where id = '77777777-0000-0000-1111-000000000001'), 280000);

select expect_write('owner raises the plan price to 350000',
  $$update membership_plans set price_cents = 350000
     where id = '77777777-0000-0000-0000-00000000ba01'$$, true);

select expect_num('the plan now reads 350000',
  (select price_cents from membership_plans where id = '77777777-0000-0000-0000-00000000ba01'), 350000);
select expect_num('Mona still pays 280000',
  (select price_cents from memberships where id = '77777777-0000-0000-1111-000000000001'), 280000);

select expect_write('owner drops the plan price to 99000',
  $$update membership_plans set price_cents = 99000
     where id = '77777777-0000-0000-0000-00000000ba01'$$, true);
select expect_num('Mona is still on 280000, not silently discounted either',
  (select price_cents from memberships where id = '77777777-0000-0000-1111-000000000001'), 280000);

select expect_num('no membership anywhere drifted from its plan snapshot',
  (select count(*) from memberships ms
    where ms.studio_id = '77777777-0000-0000-0000-000000000001'
      and ms.price_cents <> 280000), 0);

-- =============================================================================
-- 5. Type-appropriate fields — migration 009
--
-- These used to be enforced only by the form and the server action that strips
-- them, which meant an import or a psql session could write a pack that bills
-- monthly. They are constraints now, so they hold for every writer.
-- =============================================================================

select expect_write('a pack CANNOT carry a billing interval',
  $$insert into membership_plans (studio_id, name, type, price_cents, currency, billing_interval, credits)
    values ('77777777-0000-0000-0000-000000000001','Billing Pack','class_pack',50000,'CZK','month',10)$$, false);

select expect_write('a recurring plan MUST carry a billing interval',
  $$insert into membership_plans (studio_id, name, type, price_cents, currency)
    values ('77777777-0000-0000-0000-000000000001','No Interval','recurring',50000,'CZK')$$, false);

select expect_write('a recurring plan CANNOT carry validity_days',
  $$insert into membership_plans (studio_id, name, type, price_cents, currency, billing_interval, validity_days)
    values ('77777777-0000-0000-0000-000000000001','Expiring Sub','recurring',50000,'CZK','month',90)$$, false);

select expect_write('a pack CANNOT carry a per-period allowance',
  $$insert into membership_plans (studio_id, name, type, price_cents, currency, credits, credits_per_period)
    values ('77777777-0000-0000-0000-000000000001','Allowance Pack','class_pack',50000,'CZK',10,8)$$, false);

select expect_write('a pack CANNOT carry commitment terms',
  $$insert into membership_plans (studio_id, name, type, price_cents, currency, credits, commitment_months)
    values ('77777777-0000-0000-0000-000000000001','Committed Pack','class_pack',50000,'CZK',10,6)$$, false);

select expect_write('a well-formed pack is fine',
  $$insert into membership_plans (studio_id, name, type, price_cents, currency, credits, validity_days)
    values ('77777777-0000-0000-0000-000000000001','Proper Pack','class_pack',50000,'CZK',10,180)$$, true);

select expect_write('a well-formed recurring plan is fine',
  $$insert into membership_plans (studio_id, name, type, price_cents, currency, billing_interval, credits_per_period)
    values ('77777777-0000-0000-0000-000000000001','Proper Sub','recurring',150000,'CZK','month',8)$$, true);

-- The form strips these too, so what the screen hides the database now refuses.
select expect_num('no plan anywhere is mis-shaped for its type',
  (select count(*) from membership_plans
    where ((type = 'recurring') <> (billing_interval is not null))
       or (type = 'recurring' and validity_days is not null)
       or (type <> 'recurring' and credits_per_period is not null)), 0);

-- =============================================================================
-- 6. One active plan per name per studio — migration 009
-- =============================================================================

select expect_write('a second active plan cannot reuse a name',
  $$insert into membership_plans (studio_id, name, type, price_cents, currency, credits, validity_days)
    values ('77777777-0000-0000-0000-000000000001','Proper Pack','class_pack',99000,'CZK',5,90)$$, false);

select expect_write('nor a different case of the same name',
  $$insert into membership_plans (studio_id, name, type, price_cents, currency, credits, validity_days)
    values ('77777777-0000-0000-0000-000000000001','proper pack','class_pack',99000,'CZK',5,90)$$, false);

select expect_write('renaming an existing plan onto a taken name is refused too',
  $$update membership_plans set name = 'Proper Pack'
     where studio_id = '77777777-0000-0000-0000-000000000001' and name = 'Proper Sub'$$, false);

-- Archived plans keep their names, and the name frees up for a new plan.
select expect_write('archiving the plan frees the name',
  $$update membership_plans set status = 'archived'
     where studio_id = '77777777-0000-0000-0000-000000000001' and name = 'Proper Pack'$$, true);

select expect_write('and a new active plan may now take it',
  $$insert into membership_plans (studio_id, name, type, price_cents, currency, credits, validity_days)
    values ('77777777-0000-0000-0000-000000000001','Proper Pack','class_pack',99000,'CZK',5,90)$$, true);

select expect_num('both exist — the archived one kept its name',
  (select count(*) from membership_plans
    where studio_id = '77777777-0000-0000-0000-000000000001' and lower(name) = 'proper pack'), 2);

select expect_num('exactly one of them is active',
  (select count(*) from membership_plans
    where studio_id = '77777777-0000-0000-0000-000000000001'
      and lower(name) = 'proper pack' and status = 'active'), 1);

-- Another studio is unaffected: the index is scoped per studio. Checked with
-- RLS out of the way, because as this owner the write would be refused by
-- plans_manager_write first and prove nothing about the index.
reset role;
select expect_write('a different studio may use the same plan name',
  $$insert into membership_plans (studio_id, name, type, price_cents, currency, credits, validity_days)
    values ('11111111-0000-0000-0000-000000000001','Proper Pack','class_pack',99000,'CZK',5,90)$$, true);
select expect_num('the name now exists once in each studio',
  (select count(distinct studio_id) from membership_plans
    where lower(name) = 'proper pack' and status = 'active'), 2);

select 'ALL PLAN MANAGEMENT TESTS PASSED' as result;
