-- =============================================================================
-- Decision 70 — Studio team access. UUID space 7ea0, checked free.
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/team_access_test.sql
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages = notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  (expected true)', label; end if;
end $$;
-- Run a statement as a given member and assert it raises the given SQLSTATE.
create or replace function expect_raise(label text, uid uuid, sql text, want_sqlstate text)
returns void language plpgsql as $$
declare got text;
begin
  perform set_config('request.jwt.claim.sub', uid::text, true);
  execute 'set local role authenticated';
  begin
    execute sql;
    got := 'NO RAISE';
  exception when others then got := sqlstate;
  end;
  execute 'set local role postgres';
  if got = want_sqlstate then raise notice 'PASS  %  (% )', label, got;
  else raise exception 'FAIL  %  expected %, got %', label, want_sqlstate, got; end if;
end $$;

-- --- Fixtures ---------------------------------------------------------------
insert into auth.users (id) values
  ('7ea00000-0000-0000-0000-0000000000a1'),   -- SA owner
  ('7ea00000-0000-0000-0000-0000000000a2'),   -- SA manager
  ('7ea00000-0000-0000-0000-0000000000a3'),   -- SA front desk
  ('7ea00000-0000-0000-0000-0000000000a4'),   -- SA instructor (login)
  ('7ea00000-0000-0000-0000-0000000000b1');   -- SB sole owner
insert into profiles (id, email) values
  ('7ea00000-0000-0000-0000-0000000000a1','sa-owner@example.com'),
  ('7ea00000-0000-0000-0000-0000000000a2','sa-mgr@example.com'),
  ('7ea00000-0000-0000-0000-0000000000a3','sa-fd@example.com'),
  ('7ea00000-0000-0000-0000-0000000000a4','sa-inst@example.com'),
  ('7ea00000-0000-0000-0000-0000000000b1','sb-owner@example.com');

insert into studios (id, name, slug, timezone, currency, status) values
  ('7ea00000-0000-0000-0000-00000000a000','Team Studio A','team-a','Europe/Prague','CZK','active'),
  ('7ea00000-0000-0000-0000-00000000b000','Team Studio B','team-b','Europe/Prague','CZK','active');
insert into studio_settings (studio_id) values
  ('7ea00000-0000-0000-0000-00000000a000'),('7ea00000-0000-0000-0000-00000000b000');

insert into studio_staff (id, studio_id, user_id, email, role, status) values
  ('7ea00000-0000-0000-0000-00000000a0a1','7ea00000-0000-0000-0000-00000000a000','7ea00000-0000-0000-0000-0000000000a1','sa-owner@example.com','owner','active'),
  ('7ea00000-0000-0000-0000-00000000a0a2','7ea00000-0000-0000-0000-00000000a000','7ea00000-0000-0000-0000-0000000000a2','sa-mgr@example.com','manager','active'),
  ('7ea00000-0000-0000-0000-00000000a0a3','7ea00000-0000-0000-0000-00000000a000','7ea00000-0000-0000-0000-0000000000a3','sa-fd@example.com','front_desk','active'),
  ('7ea00000-0000-0000-0000-00000000a0a4','7ea00000-0000-0000-0000-00000000a000','7ea00000-0000-0000-0000-0000000000a4','sa-inst@example.com','instructor','active'),
  ('7ea00000-0000-0000-0000-00000000b0b1','7ea00000-0000-0000-0000-00000000b000','7ea00000-0000-0000-0000-0000000000b1','sb-owner@example.com','owner','active');

-- ===========================================================================
-- invite_staff
-- ===========================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','7ea00000-0000-0000-0000-0000000000a1',false);  -- owner
select (invite_staff('newmgr@example.com','manager','New Manager') ->> 'staff_id') is not null as ok \gset
select expect_true('owner invites a manager', :'ok'::boolean);
select (invite_staff('newfd@example.com','front_desk','New FD') ->> 'staff_id') is not null as ok2 \gset
select expect_true('owner invites front desk', :'ok2'::boolean);
reset role;

do $$
begin
  perform expect_num('the manager invite made an invited studio_staff row',
    (select count(*) from studio_staff where studio_id='7ea00000-0000-0000-0000-00000000a000'
       and lower(email)='newmgr@example.com' and role='manager' and status='invited'), 1);
  perform expect_num('the invite row is role manager, no instructor, with the name',
    (select count(*) from studio_invites where studio_id='7ea00000-0000-0000-0000-00000000a000'
       and lower(email)='newmgr@example.com' and role='manager' and instructor_id is null
       and invited_name='New Manager' and accepted_at is null), 1);
end $$;

-- owner cannot invite an instructor or an owner here
select expect_raise('owner inviting instructor refused (use instructors page)',
  '7ea00000-0000-0000-0000-0000000000a1',
  $$ select invite_staff('x@example.com','instructor','X') $$, 'PT422');
select expect_raise('owner inviting owner refused',
  '7ea00000-0000-0000-0000-0000000000a1',
  $$ select invite_staff('x@example.com','owner','X') $$, 'PT422');

-- manager invites front desk (ok) but not manager/owner; front desk + instructor refused
set role authenticated;
select set_config('request.jwt.claim.sub','7ea00000-0000-0000-0000-0000000000a2',false);  -- manager
select (invite_staff('mgr-fd@example.com','front_desk','Mgr FD') ->> 'staff_id') is not null as ok3 \gset
select expect_true('manager invites front desk', :'ok3'::boolean);
reset role;
select expect_raise('manager inviting a manager refused',
  '7ea00000-0000-0000-0000-0000000000a2',
  $$ select invite_staff('y@example.com','manager','Y') $$, 'PT403');
select expect_raise('front desk inviting anyone refused',
  '7ea00000-0000-0000-0000-0000000000a3',
  $$ select invite_staff('z@example.com','front_desk','Z') $$, 'PT403');
select expect_raise('instructor inviting anyone refused',
  '7ea00000-0000-0000-0000-0000000000a4',
  $$ select invite_staff('w@example.com','front_desk','W') $$, 'PT403');
-- already on the team
select expect_raise('inviting an already-active person refused',
  '7ea00000-0000-0000-0000-0000000000a1',
  $$ select invite_staff('sa-fd@example.com','front_desk','Dup') $$, 'PT409');

-- ===========================================================================
-- studios writes — manager can edit the studio but not the payment column
-- ===========================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','7ea00000-0000-0000-0000-0000000000a2',false);  -- manager
with u as (update studios set name='A renamed', accent_color='#123456'
           where id='7ea00000-0000-0000-0000-00000000a000' returning 1)
select expect_num('manager updates studio name + branding', (select count(*) from u), 1);
reset role;
select expect_raise('manager cannot change the Stripe account (payment column)',
  '7ea00000-0000-0000-0000-0000000000a2',
  $$ update studios set stripe_account_id='acct_hack' where id='7ea00000-0000-0000-0000-00000000a000' $$, 'PT403');

set role authenticated;
select set_config('request.jwt.claim.sub','7ea00000-0000-0000-0000-0000000000a1',false);  -- owner
with u as (update studios set stripe_account_id='acct_ok'
           where id='7ea00000-0000-0000-0000-00000000a000' returning 1)
select expect_num('owner can set the Stripe account', (select count(*) from u), 1);
reset role;

-- ===========================================================================
-- set_staff_role / remove_staff
-- ===========================================================================
-- owner promotes the manager to owner
set role authenticated;
select set_config('request.jwt.claim.sub','7ea00000-0000-0000-0000-0000000000a1',false);
select (set_staff_role('7ea00000-0000-0000-0000-00000000a0a2','owner') ->> 'ok')::boolean as okp \gset
select expect_true('owner promotes a manager to owner', :'okp'::boolean);
reset role;
do $$ begin
  perform expect_num('the promoted row is now owner',
    (select count(*) from studio_staff where id='7ea00000-0000-0000-0000-00000000a0a2' and role='owner'), 1);
end $$;

-- a non-owner cannot change roles
select expect_raise('a manager/front desk cannot change roles',
  '7ea00000-0000-0000-0000-0000000000a3',
  $$ select set_staff_role('7ea00000-0000-0000-0000-00000000a0a3','manager') $$, 'PT403');
-- role instructor refused
select expect_raise('setting role to instructor refused',
  '7ea00000-0000-0000-0000-0000000000a1',
  $$ select set_staff_role('7ea00000-0000-0000-0000-00000000a0a3','instructor') $$, 'PT422');

-- SB has a single owner: cannot be demoted or removed
select expect_raise('the last owner cannot be demoted',
  '7ea00000-0000-0000-0000-0000000000b1',
  $$ select set_staff_role('7ea00000-0000-0000-0000-00000000b0b1','manager') $$, 'PT409');
select expect_raise('the last owner cannot be removed',
  '7ea00000-0000-0000-0000-0000000000b1',
  $$ select remove_staff('7ea00000-0000-0000-0000-00000000b0b1') $$, 'PT409');

-- remove: owner removes front desk; a manager may remove front desk only; an
-- instructor row is refused (managed on the Instructors page).
set role authenticated;
select set_config('request.jwt.claim.sub','7ea00000-0000-0000-0000-0000000000a1',false);
select (remove_staff('7ea00000-0000-0000-0000-00000000a0a3') ->> 'ok')::boolean as okr \gset
select expect_true('owner removes front desk', :'okr'::boolean);
reset role;
do $$ begin
  perform expect_num('removed front desk is status removed, login revoked',
    (select count(*) from studio_staff where id='7ea00000-0000-0000-0000-00000000a0a3'
       and status='removed' and user_id is null), 1);
end $$;
select expect_raise('remove_staff refuses an instructor row',
  '7ea00000-0000-0000-0000-0000000000a1',
  $$ select remove_staff('7ea00000-0000-0000-0000-00000000a0a4') $$, 'PT409');

-- ===========================================================================
-- studio_team reader — manager-up; front desk refused
-- ===========================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','7ea00000-0000-0000-0000-0000000000a1',false);
select count(*) >= 3 as teamok from studio_team('7ea00000-0000-0000-0000-00000000a000') \gset
select expect_true('owner reads the team', :'teamok'::boolean);
reset role;

-- ===========================================================================
-- anon refused on all three write RPCs, and the surface is EXACTLY THIRTEEN
-- ===========================================================================
do $$
declare got text;
begin
  set local role anon;
  begin perform invite_staff('a@example.com','manager','A'); got := 'NO RAISE';
  exception when others then got := sqlstate; end;
  set local role postgres;
  perform expect_true('anon cannot call invite_staff', got <> 'NO RAISE');
end $$;
do $$
declare got text;
begin
  set local role anon;
  begin perform set_staff_role('7ea00000-0000-0000-0000-00000000a0a2','manager'); got := 'NO RAISE';
  exception when others then got := sqlstate; end;
  set local role postgres;
  perform expect_true('anon cannot call set_staff_role', got <> 'NO RAISE');
end $$;
do $$
declare got text;
begin
  set local role anon;
  begin perform remove_staff('7ea00000-0000-0000-0000-00000000a0a2'); got := 'NO RAISE';
  exception when others then got := sqlstate; end;
  set local role postgres;
  perform expect_true('anon cannot call remove_staff', got <> 'NO RAISE');
end $$;

do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname='public' and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'expect%';
  perform expect_num('anon surface is exactly thirteen', n::bigint, 13);
end $$;

\echo 'team_access_test: all assertions passed'
