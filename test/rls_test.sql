-- =============================================================================
-- STUDIIOR — RLS ISOLATION TEST SUITE
--
-- The gate. Nothing gets built on top of the schema until this passes.
-- Runs against the database directly, as each role, with RLS active.
-- Application-layer checks are irrelevant here and would mask a hole.
-- =============================================================================

\set ON_ERROR_STOP on
set client_min_messages = notice;

-- A non-superuser role, because superusers bypass RLS entirely and would
-- make every one of these tests pass for the wrong reason.

-- --- Fixtures (as superuser, RLS bypassed) ----------------------------------
--
-- Slugs are deliberately fixture-flavoured. studios.slug is unique and
-- supabase/seed.sql owns 'reform' for tenant one, which is present on every
-- db reset before this file runs.

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000000a1'),   -- owner A
  ('00000000-0000-0000-0000-0000000000a2'),   -- instructor A
  ('00000000-0000-0000-0000-0000000000a3'),   -- front desk A
  ('00000000-0000-0000-0000-0000000000a4'),   -- member A
  ('00000000-0000-0000-0000-0000000000b1'),   -- owner B
  ('00000000-0000-0000-0000-0000000000b4');   -- member B

insert into profiles (id, email) values
  ('00000000-0000-0000-0000-0000000000a1','ownerA@test'),
  ('00000000-0000-0000-0000-0000000000a2','instrA@test'),
  ('00000000-0000-0000-0000-0000000000a3','deskA@test'),
  ('00000000-0000-0000-0000-0000000000a4','memberA@test'),
  ('00000000-0000-0000-0000-0000000000b1','ownerB@test'),
  ('00000000-0000-0000-0000-0000000000b4','memberB@test');

insert into studios (id, name, slug, timezone, currency, stripe_account_id) values
  ('aaaaaaaa-0000-0000-0000-000000000001','RLS Fixture A','rls-fixture-a','Europe/Prague','CZK','acct_A'),
  ('bbbbbbbb-0000-0000-0000-000000000001','RLS Fixture B','rls-fixture-b','Europe/Prague','CZK','acct_B');

insert into studio_settings (studio_id) values
  ('aaaaaaaa-0000-0000-0000-000000000001'),
  ('bbbbbbbb-0000-0000-0000-000000000001');

insert into locations (id, studio_id, name) values
  ('aaaaaaaa-0000-0000-0000-00000000000c','aaaaaaaa-0000-0000-0000-000000000001','Main'),
  ('bbbbbbbb-0000-0000-0000-00000000000c','bbbbbbbb-0000-0000-0000-000000000001','Main');

insert into studio_staff (id, studio_id, user_id, email, role) values
  ('aaaaaaaa-0000-0000-0000-0000000000f1','aaaaaaaa-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000000a1','ownerA@test','owner'),
  ('aaaaaaaa-0000-0000-0000-0000000000f2','aaaaaaaa-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000000a2','instrA@test','instructor'),
  ('aaaaaaaa-0000-0000-0000-0000000000f3','aaaaaaaa-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000000a3','deskA@test','front_desk'),
  ('bbbbbbbb-0000-0000-0000-0000000000f1','bbbbbbbb-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000000b1','ownerB@test','owner');

insert into instructors (id, studio_id, staff_id, display_name) values
  ('aaaaaaaa-0000-0000-0000-0000000000e1','aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-0000000000f2','Sophia'),
  ('bbbbbbbb-0000-0000-0000-0000000000e1','bbbbbbbb-0000-0000-0000-000000000001',null,'Rival Instructor');

insert into members (id, studio_id, user_id, first_name, last_name, email) values
  ('aaaaaaaa-0000-0000-0000-0000000000d1','aaaaaaaa-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000000a4','Emma','W','emma@test'),
  ('aaaaaaaa-0000-0000-0000-0000000000d2','aaaaaaaa-0000-0000-0000-000000000001',null,'Other','Member','other@test'),
  ('bbbbbbbb-0000-0000-0000-0000000000d1','bbbbbbbb-0000-0000-0000-000000000001','00000000-0000-0000-0000-0000000000b4','Rival','Member','rival@test');

insert into membership_plans (id, studio_id, name, type, price_cents, currency) values
  ('aaaaaaaa-0000-0000-0000-00000000ba01','aaaaaaaa-0000-0000-0000-000000000001','Unlimited','recurring',280000,'CZK'),
  ('bbbbbbbb-0000-0000-0000-00000000ba01','bbbbbbbb-0000-0000-0000-000000000001','Unlimited','recurring',300000,'CZK');

insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on) values
  ('aaaaaaaa-0000-0000-0000-00000000cd01','aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-0000000000d1','aaaaaaaa-0000-0000-0000-00000000ba01','active',280000,'CZK',current_date);

insert into payments (studio_id, member_id, amount_cents, currency, status) values
  ('aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-0000000000d1',280000,'CZK','succeeded');

insert into member_notes (studio_id, member_id, body, managers_only) values
  ('aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-0000000000d1','Left shoulder, avoid overhead', false),
  ('aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-0000000000d1','Disputed a charge in March', true);

-- --- Assertion helper -------------------------------------------------------

create or replace function expect(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual = want then
    raise notice 'PASS  %  (got %)', label, actual;
  else
    raise exception 'FAIL  %  expected %, got %', label, want, actual;
  end if;
end $$;

create or replace function login(uid text) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', uid, false);
end $$;

-- =============================================================================
-- TESTS
-- =============================================================================

set role authenticated;

-- 1. Cross-tenant reads --------------------------------------------------
select login('00000000-0000-0000-0000-0000000000a1');   -- Owner A
select expect('owner A sees only own studio',        (select count(*) from studios), 1);
select expect('owner A sees only own members',       (select count(*) from members), 2);
select expect('owner A cannot see rival memberships',(select count(*) from memberships where studio_id='bbbbbbbb-0000-0000-0000-000000000001'), 0);
select expect('owner A sees own payments',           (select count(*) from payments), 1);

select login('00000000-0000-0000-0000-0000000000b1');   -- Owner B
select expect('owner B sees only own studio',        (select count(*) from studios), 1);
select expect('owner B sees zero members of A',      (select count(*) from members where studio_id='aaaaaaaa-0000-0000-0000-000000000001'), 0);
select expect('owner B sees zero payments of A',     (select count(*) from payments), 0);
select expect('owner B sees zero notes of A',        (select count(*) from member_notes), 0);

-- 2. Member isolation ----------------------------------------------------
select login('00000000-0000-0000-0000-0000000000a4');   -- Member A
select expect('member A sees only own record',       (select count(*) from members), 1);
select expect('member A sees own membership',        (select count(*) from memberships), 1);
select expect('member A sees own payment',           (select count(*) from payments), 1);
select expect('member A sees no staff notes',        (select count(*) from member_notes), 0);
select expect('member A sees no ai insights',        (select count(*) from ai_insights), 0);
select expect('member A sees no audit log',          (select count(*) from audit_logs), 0);

select login('00000000-0000-0000-0000-0000000000b4');   -- Member B
select expect('member B sees zero of studio A',      (select count(*) from members where studio_id='aaaaaaaa-0000-0000-0000-000000000001'), 0);

-- 3. Instructor cannot see money ----------------------------------------
select login('00000000-0000-0000-0000-0000000000a2');   -- Instructor A
select expect('instructor sees studio members',      (select count(*) from members), 2);
select expect('instructor sees NO payments',         (select count(*) from payments), 0);
select expect('instructor sees NO memberships',      (select count(*) from memberships), 0);
select expect('instructor sees NO plans',            (select count(*) from membership_plans), 0);
select expect('instructor sees NO credit ledger',    (select count(*) from credit_ledger), 0);
select expect('instructor sees NO ai insights',      (select count(*) from ai_insights), 0);
select expect('instructor sees NO audit log',        (select count(*) from audit_logs), 0);
select expect('instructor sees unrestricted note',   (select count(*) from member_notes), 1);

-- 4. Front desk boundaries ----------------------------------------------
select login('00000000-0000-0000-0000-0000000000a3');   -- Front Desk A
select expect('desk sees members',                   (select count(*) from members), 2);
select expect('desk sees payments',                  (select count(*) from payments), 1);
select expect('desk sees NO managers_only note',     (select count(*) from member_notes), 1);
select expect('desk sees NO audit log',              (select count(*) from audit_logs), 0);
select expect('desk sees NO ai insights',            (select count(*) from ai_insights), 0);

-- 5. Instructor availability is self-scoped ------------------------------
reset role;
insert into instructor_availability (studio_id, instructor_id, day_of_week, starts_at_time, ends_at_time)
values ('aaaaaaaa-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-0000000000e1',2,'07:00','12:00');
set role authenticated;

select login('00000000-0000-0000-0000-0000000000a2');
select expect('instructor sees own availability',    (select count(*) from instructor_availability), 1);
select login('00000000-0000-0000-0000-0000000000a3');
select expect('front desk sees NO availability',     (select count(*) from instructor_availability), 0);
select login('00000000-0000-0000-0000-0000000000a1');
select expect('owner sees availability',             (select count(*) from instructor_availability), 1);

-- 6. Write attempts across the tenant boundary ---------------------------
select login('00000000-0000-0000-0000-0000000000b1');   -- Owner B writing into A
do $$
begin
  begin
    insert into members (studio_id, first_name, last_name, email)
    values ('aaaaaaaa-0000-0000-0000-000000000001','Injected','Row','inject@test');
    raise exception 'FAIL  owner B was able to insert a member into studio A';
  exception when insufficient_privilege or check_violation then
    raise notice 'PASS  owner B blocked from inserting into studio A';
  end;
end $$;

select login('00000000-0000-0000-0000-0000000000a4');   -- Member A escalating
do $$
begin
  begin
    update members set first_name = 'Hacked'
    where id = 'aaaaaaaa-0000-0000-0000-0000000000d2';
    if found then
      raise exception 'FAIL  member A edited another member';
    end if;
    raise notice 'PASS  member A cannot edit another member';
  exception when insufficient_privilege then
    raise notice 'PASS  member A blocked from editing another member';
  end;
end $$;

-- 7. Last-owner guard (Decision 8) ---------------------------------------
reset role;
do $$
begin
  begin
    delete from studio_staff where id = 'bbbbbbbb-0000-0000-0000-0000000000f1';
    raise exception 'FAIL  last owner of studio B was deleted';
  exception when check_violation then
    raise notice 'PASS  last owner cannot be removed';
  end;
end $$;

-- 8. Restricted views ----------------------------------------------------
set role authenticated;
select login('00000000-0000-0000-0000-0000000000a2');
do $$
declare cols int;
begin
  select count(*) into cols from information_schema.columns
   where table_name = 'member_quick_view' and column_name in
   ('email','phone','address','emergency_contact');
  if cols > 0 then
    raise exception 'FAIL  member_quick_view exposes % contact column(s)', cols;
  end if;
  raise notice 'PASS  member_quick_view exposes no contact fields';
end $$;

do $$
declare cols int;
begin
  select count(*) into cols from information_schema.columns
   where table_name = 'studio_public' and column_name = 'stripe_account_id';
  if cols > 0 then
    raise exception 'FAIL  studio_public exposes stripe_account_id';
  end if;
  raise notice 'PASS  studio_public hides stripe_account_id';
end $$;

reset role;
select 'ALL RLS TESTS PASSED' as result;
