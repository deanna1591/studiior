-- =============================================================================
-- Decision 93 slice 1 — the brand kit. UUID space 93b0, checked free.
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/brand_kit_test.sql
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
create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual,'null'); end if;
end $$;
-- Run a statement as a given user and assert it raises the given SQLSTATE.
create or replace function expect_raise(label text, uid uuid, sql text, want_sqlstate text)
returns void language plpgsql as $$
declare got text;
begin
  perform set_config('request.jwt.claim.sub', uid::text, true);
  execute 'set local role authenticated';
  begin execute sql; got := 'NO RAISE';
  exception when others then got := sqlstate; end;
  execute 'set local role postgres';
  if got = want_sqlstate then raise notice 'PASS  %  (%)', label, got;
  else raise exception 'FAIL  %  expected %, got %', label, want_sqlstate, got; end if;
end $$;
-- Run a SELECT returning jsonb as a given user.
create or replace function call_jsonb(uid uuid, sql text) returns jsonb
language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claim.sub', uid::text, true);
  execute 'set local role authenticated';
  execute sql into r;
  execute 'set local role postgres';
  return r;
end $$;

-- --- Fixtures ---------------------------------------------------------------
insert into auth.users (id) values
  ('93b00000-0000-0000-0000-0000000000a1'),   -- SA owner
  ('93b00000-0000-0000-0000-0000000000a2'),   -- SA manager
  ('93b00000-0000-0000-0000-0000000000a3'),   -- SA front desk
  ('93b00000-0000-0000-0000-0000000000a4'),   -- SA instructor (login)
  ('93b00000-0000-0000-0000-0000000000b1');   -- SB owner
insert into profiles (id, email) values
  ('93b00000-0000-0000-0000-0000000000a1','bk-owner@example.com'),
  ('93b00000-0000-0000-0000-0000000000a2','bk-mgr@example.com'),
  ('93b00000-0000-0000-0000-0000000000a3','bk-fd@example.com'),
  ('93b00000-0000-0000-0000-0000000000a4','bk-inst@example.com'),
  ('93b00000-0000-0000-0000-0000000000b1','bk-sb@example.com');
insert into studios (id, name, slug, timezone, currency, status, accent_color, theme_preset) values
  ('93b00000-0000-0000-0000-00000000a000','Brand Studio A','brand-a','Europe/Prague','CZK','active','#B85C38','warm'),
  ('93b00000-0000-0000-0000-00000000b000','Brand Studio B','brand-b','Europe/Prague','CZK','active','#1A2B4C','bold');
insert into studio_settings (studio_id) values
  ('93b00000-0000-0000-0000-00000000a000'),('93b00000-0000-0000-0000-00000000b000');
insert into studio_staff (id, studio_id, user_id, email, role, status) values
  ('93b00000-0000-0000-0000-00000000a0a1','93b00000-0000-0000-0000-00000000a000','93b00000-0000-0000-0000-0000000000a1','bk-owner@example.com','owner','active'),
  ('93b00000-0000-0000-0000-00000000a0a2','93b00000-0000-0000-0000-00000000a000','93b00000-0000-0000-0000-0000000000a2','bk-mgr@example.com','manager','active'),
  ('93b00000-0000-0000-0000-00000000a0a3','93b00000-0000-0000-0000-00000000a000','93b00000-0000-0000-0000-0000000000a3','bk-fd@example.com','front_desk','active'),
  ('93b00000-0000-0000-0000-00000000a0a4','93b00000-0000-0000-0000-00000000a000','93b00000-0000-0000-0000-0000000000a4','bk-inst@example.com','instructor','active'),
  ('93b00000-0000-0000-0000-00000000b0b1','93b00000-0000-0000-0000-00000000b000','93b00000-0000-0000-0000-0000000000b1','bk-sb@example.com','owner','active');

\set SA '93b00000-0000-0000-0000-00000000a000'
\set SB '93b00000-0000-0000-0000-00000000b000'
\set MGR '93b00000-0000-0000-0000-0000000000a2'
\set FD  '93b00000-0000-0000-0000-0000000000a3'
\set INST '93b00000-0000-0000-0000-0000000000a4'

-- A valid learned spec, an invalid one (bad font), a manual spec.
\set GOOD '{"colors":{"background":"#0E0E10","surface":"#1A1A1E","ink":"#F5F5F4","accent":"#D98AA6","secondary":"#9A9A98"},"display_font":"Playfair Display","body_font":"Manrope","layout":"poster","radius":"large","tone":"Editorial and warm.","logo_placement":"top-centre","background_treatment":"soft"}'
\set BAD  '{"colors":{"background":"#0E0E10","surface":"#1A1A1E","ink":"#F5F5F4","accent":"#D98AA6","secondary":"#9A9A98"},"display_font":"Comic Sans","body_font":"Manrope","layout":"poster","radius":"large","tone":"x","logo_placement":"top-centre","background_treatment":"soft"}'
\set MAN  '{"colors":{"background":"#FFFFFF","surface":"#FFFFFF","ink":"#111111","accent":"#2E7D32","secondary":"#666666"},"display_font":"Inter","body_font":"Inter","layout":"grid","radius":"small","tone":"Crisp.","logo_placement":"top-left","background_treatment":"none"}'

-- ===========================================================================
-- 1. Validation
select expect_true('brand_kit_valid accepts a good spec', brand_kit_valid(:'GOOD'::jsonb));
select expect_true('brand_kit_valid rejects a bad font',  not brand_kit_valid(:'BAD'::jsonb));
-- amendment: watermark_opacity optional, 0..0.4
select expect_true('brand_kit_valid accepts watermark_opacity 0.3',
  brand_kit_valid((:'GOOD'::jsonb) || '{"watermark_opacity":0.3}'::jsonb));
select expect_true('brand_kit_valid rejects watermark_opacity 0.5',
  not brand_kit_valid((:'GOOD'::jsonb) || '{"watermark_opacity":0.5}'::jsonb));
select expect_true('brand_kit_valid rejects a non-numeric watermark_opacity',
  not brand_kit_valid((:'GOOD'::jsonb) || '{"watermark_opacity":"0.2"}'::jsonb));

-- 2. Defaults (no kit yet) — built from the studio accent + preset
select expect_text('defaults: source is default',
  call_jsonb(:'MGR', 'select brand_kit_current('''|| :'SA' ||''')') ->> 'source', 'default');
select expect_text('defaults: accent is the studio accent',
  call_jsonb(:'MGR', 'select brand_kit_current('''|| :'SA' ||''')') -> 'spec' -> 'colors' ->> 'accent', '#B85C38');
select expect_text('defaults: background is the warm paper',
  call_jsonb(:'MGR', 'select brand_kit_current('''|| :'SA' ||''')') -> 'spec' -> 'colors' ->> 'background', '#FAFAF7');
select expect_true('defaults: the default spec is valid',
  brand_kit_valid(call_jsonb(:'MGR', 'select brand_kit_current('''|| :'SA' ||''')') -> 'spec'));

-- 3. Write guards
select expect_raise('instructor cannot save a kit', :'INST'::uuid,
  'select brand_kit_save('''|| :'SA' ||''','''|| :'GOOD' ||'''::jsonb,''learned'')', 'PT403');
select expect_raise('front desk cannot save a kit', :'FD'::uuid,
  'select brand_kit_save('''|| :'SA' ||''','''|| :'GOOD' ||'''::jsonb,''learned'')', 'PT403');
select expect_raise('a bad spec is refused PT400', :'MGR'::uuid,
  'select brand_kit_save('''|| :'SA' ||''','''|| :'BAD' ||'''::jsonb,''learned'')', 'PT400');

-- 4. Manager saves a learned kit; it becomes current
select expect_true('manager saves a learned kit',
  (call_jsonb(:'MGR', 'select brand_kit_save('''|| :'SA' ||''','''|| :'GOOD' ||'''::jsonb,''learned'')') ->> 'ok')::boolean);
select expect_text('current is now learned',
  call_jsonb(:'MGR', 'select brand_kit_current('''|| :'SA' ||''')') ->> 'source', 'learned');
select expect_text('current carries the learned accent',
  call_jsonb(:'MGR', 'select brand_kit_current('''|| :'SA' ||''')') -> 'spec' -> 'colors' ->> 'accent', '#D98AA6');

-- 5. A second save keeps history, one current per studio
select expect_true('manager saves a manual override',
  (call_jsonb(:'MGR', 'select brand_kit_save('''|| :'SA' ||''','''|| :'MAN' ||'''::jsonb,''manual'')') ->> 'ok')::boolean);
select expect_num('exactly one current kit for SA',
  (select count(*) from studio_brand_kits where studio_id = :'SA' and is_current), 1);
select expect_num('history kept: two rows for SA',
  (select count(*) from studio_brand_kits where studio_id = :'SA'), 2);
select expect_text('current source is now manual',
  call_jsonb(:'MGR', 'select brand_kit_current('''|| :'SA' ||''')') ->> 'source', 'manual');

-- 6. Reads: front desk may read, instructor refused
select expect_text('front desk reads the kit (read-only)',
  call_jsonb(:'FD', 'select brand_kit_current('''|| :'SA' ||''')') ->> 'source', 'manual');
select expect_raise('instructor cannot read the kit', :'INST'::uuid,
  'select brand_kit_current('''|| :'SA' ||''')', 'PT403');

-- 7. Cross-studio refused
select expect_raise('SA manager cannot save SB''s kit', :'MGR'::uuid,
  'select brand_kit_save('''|| :'SB' ||''','''|| :'MAN' ||'''::jsonb,''manual'')', 'PT403');
select expect_raise('SA manager cannot read SB''s kit', :'MGR'::uuid,
  'select brand_kit_current('''|| :'SB' ||''')', 'PT403');
select expect_num('SB has no kit rows', (select count(*) from studio_brand_kits where studio_id = :'SB'), 0);

-- 8. Run limit: ten a month, the eleventh refused
do $$
declare r jsonb; i int;
begin
  for i in 1..10 loop
    r := call_jsonb('93b00000-0000-0000-0000-0000000000a2',
                    'select brand_kit_run_allowed(''93b00000-0000-0000-0000-00000000a000'')');
    if not (r->>'ok')::boolean then raise exception 'run % refused early: %', i, r; end if;
  end loop;
  perform expect_num('tenth run used = 10', (r->>'used')::bigint, 10);
  r := call_jsonb('93b00000-0000-0000-0000-0000000000a2',
                  'select brand_kit_run_allowed(''93b00000-0000-0000-0000-00000000a000'')');
  perform expect_true('eleventh run refused', not (r->>'ok')::boolean);
  perform expect_text('eleventh reason is brand_kit_limit', r->>'reason', 'brand_kit_limit');
end $$;
select expect_raise('instructor cannot run the gate', :'INST'::uuid,
  'select brand_kit_run_allowed('''|| :'SA' ||''')', 'PT403');

-- 9. anon refused, and the surface is EXACTLY THIRTEEN
do $$
declare got text;
begin
  set local role anon;
  begin perform brand_kit_current('93b00000-0000-0000-0000-00000000a000'); got := 'NO RAISE';
  exception when others then got := 'refused'; end;
  set local role postgres;
  perform expect_true('anon cannot read a brand kit', got = 'refused');
end $$;
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname='public' and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'expect%' and p.proname <> 'call_jsonb';
  perform expect_num('anon surface is exactly thirteen', n::bigint, 13);
end $$;

select 'brand_kit_test OK' as result;
