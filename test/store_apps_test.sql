-- =============================================================================
-- STUDIIOR — STORE APP IDENTIFIERS (Decision 52a, migration 238)
--
--   Per-tenant app-store columns on studios, owner-editable via the studios
--   RLS; shape CHECKs; anon surface unchanged (studio_by_slug re-issued, still
--   one of the thirteen).
--
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/store_apps_test.sql
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

-- --- Fixtures: 570a ---------------------------------------------------------
insert into auth.users (id) values
  ('570a0000-0000-0000-0000-0000000000a1'),   -- owner
  ('570a0000-0000-0000-0000-0000000000a2'),   -- member (not staff)
  ('570a0000-0000-0000-0000-0000000000a3');   -- instructor
insert into profiles (id, email) values
  ('570a0000-0000-0000-0000-0000000000a1','sa-owner@example.com'),
  ('570a0000-0000-0000-0000-0000000000a2','sa-member@example.com'),
  ('570a0000-0000-0000-0000-0000000000a3','sa-inst@example.com');

insert into studios (id, name, slug, timezone, currency, status) values
  ('570a0000-0000-0000-0000-000000000001','Store Studio','store-test','Europe/Prague','CZK','active');
insert into studio_settings (studio_id) values ('570a0000-0000-0000-0000-000000000001');
insert into studio_staff (studio_id, user_id, email, role) values
  ('570a0000-0000-0000-0000-000000000001','570a0000-0000-0000-0000-0000000000a1','sa-owner@example.com','owner'),
  ('570a0000-0000-0000-0000-000000000001','570a0000-0000-0000-0000-0000000000a3','sa-inst@example.com','instructor');
insert into members (id, studio_id, user_id, first_name, last_name, email, status) values
  ('570a0000-0000-0000-0000-00000000aa02','570a0000-0000-0000-0000-000000000001','570a0000-0000-0000-0000-0000000000a2','Mem','Two','sa-member@example.com','active');

-- The columns exist.
do $$
begin
  perform expect_num('the four store columns exist on studios',
    (select count(*) from information_schema.columns
      where table_name='studios'
        and column_name in ('android_package','android_sha256_fingerprints','ios_team_id','ios_bundle_id')), 4);
end $$;

-- === OWNER writes all four (studios RLS) =====================================
set role authenticated;
select set_config('request.jwt.claim.sub','570a0000-0000-0000-0000-0000000000a1',false);
with u as (
  update studios set
    android_package = 'app.studiior.reformcollective',
    android_sha256_fingerprints = 'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99',
    ios_team_id = 'ABCDE12345',
    ios_bundle_id = 'app.studiior.reformcollective'
  where id = '570a0000-0000-0000-0000-000000000001'
  returning 1)
select expect_num('owner writes all four store fields', (select count(*) from u), 1);
reset role;

do $$
begin
  perform expect_true('the four values are stored',
    (select android_package='app.studiior.reformcollective' and ios_team_id='ABCDE12345'
       from studios where id='570a0000-0000-0000-0000-000000000001'));
end $$;

-- === A MEMBER cannot write them (RLS) ========================================
set role authenticated;
select set_config('request.jwt.claim.sub','570a0000-0000-0000-0000-0000000000a2',false);
with u as (
  update studios set android_package = 'app.evil.hack'
  where id = '570a0000-0000-0000-0000-000000000001' returning 1)
select expect_num('a member cannot write store fields', (select count(*) from u), 0);
reset role;

-- === An INSTRUCTOR cannot write them (owner-only RLS) ========================
set role authenticated;
select set_config('request.jwt.claim.sub','570a0000-0000-0000-0000-0000000000a3',false);
with u as (
  update studios set ios_team_id = 'ZZZZZ99999'
  where id = '570a0000-0000-0000-0000-000000000001' returning 1)
select expect_num('an instructor cannot write store fields', (select count(*) from u), 0);
reset role;

do $$
begin
  perform expect_true('neither member nor instructor changed anything',
    (select android_package='app.studiior.reformcollective' and ios_team_id='ABCDE12345'
       from studios where id='570a0000-0000-0000-0000-000000000001'));
end $$;

-- === CHECK constraints reject bad values =====================================
set role authenticated;
select set_config('request.jwt.claim.sub','570a0000-0000-0000-0000-0000000000a1',false);  -- owner
do $$
declare ok boolean := false;
begin
  begin
    update studios set ios_team_id = 'too-short' where id='570a0000-0000-0000-0000-000000000001';
  exception when check_violation then ok := true; end;
  perform expect_true('CHECK rejects a bad Team ID', ok);

  ok := false;
  begin
    update studios set android_sha256_fingerprints = 'not-a-fingerprint' where id='570a0000-0000-0000-0000-000000000001';
  exception when check_violation then ok := true; end;
  perform expect_true('CHECK rejects a bad fingerprint', ok);

  ok := false;
  begin
    update studios set android_package = 'nodot' where id='570a0000-0000-0000-0000-000000000001';
  exception when check_violation then ok := true; end;
  perform expect_true('CHECK rejects a non-reverse-DNS package', ok);
end $$;
reset role;

-- === Anon surface is still EXACTLY THIRTEEN ==================================
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'expect\_%';
  perform expect_num('anon surface is exactly thirteen', n::bigint, 13);
  perform expect_true('studio_by_slug is still anon',
    has_function_privilege('anon','studio_by_slug(text)','execute'));
end $$;

\echo 'store_apps_test: all assertions passed'
