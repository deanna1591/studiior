-- =============================================================================
-- Decision 85 — Studio Guide (85a). The two per-person flags and their writer.
-- UUID space: 8502
--
-- instructor_guide_mark('intro') sets guide_seen_at; 'reset' clears it; any
-- other value records a dismissed hint (merged, not replaced). my_instructor
-- carries both. A caller who is not an instructor is refused PT403. Anon
-- surface stays EXACTLY THIRTEEN. RED first (functions/columns absent), GREEN.
-- =============================================================================
\set S '''85020000-0000-0000-0000-000000000001'''

create or replace function expect_true(label text, actual boolean) returns void language plpgsql as $$
begin if coalesce(actual,false) then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_null(label text, actual anyelement) returns void language plpgsql as $$
begin if actual is null then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected null, got %', label, actual::text; end if; end $$;
create or replace function expect_num(label text, actual bigint, want bigint) returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (%)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_raises(label text, sql text, code text) returns void language plpgsql as $$
begin execute sql; raise exception 'FAIL  %  expected %, nothing raised', label, code;
exception when others then
  if sqlstate = code then raise notice 'PASS  %  (%)', label, code;
  else raise exception 'FAIL  %  expected %, got % (%)', label, code, sqlstate, sqlerrm; end if; end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('85020000-0000-0000-0000-0000000000a1'),  -- owner
  ('85020000-0000-0000-0000-0000000000c1'),  -- the instructor's login
  ('85020000-0000-0000-0000-0000000000d2');  -- a member's login (not an instructor)
insert into profiles (id, email) values
  ('85020000-0000-0000-0000-0000000000a1','8502-o@example.com'),
  ('85020000-0000-0000-0000-0000000000c1','8502-i@example.com'),
  ('85020000-0000-0000-0000-0000000000d2','8502-m@example.com');

insert into studios (id, name, slug, timezone, currency, status) values
  (:S,'Guide Studio','guide-s','Europe/Prague','CZK','active');
insert into studio_settings (studio_id) values (:S);
insert into locations (id, studio_id, name, is_primary) values
  ('85020000-0000-0000-0000-00000000000a',:S,'Main',true);

insert into studio_staff (id, studio_id, user_id, email, role, status) values
  ('85020000-0000-0000-0000-0000000055a1',:S,'85020000-0000-0000-0000-0000000000a1','8502-o@example.com','owner','active'),
  ('85020000-0000-0000-0000-0000000055c1',:S,'85020000-0000-0000-0000-0000000000c1','8502-i@example.com','instructor','active');
insert into instructors (id, studio_id, staff_id, display_name, status) values
  ('85020000-0000-0000-0000-00000000d001',:S,'85020000-0000-0000-0000-0000000055c1','Ima Instructor','active');

-- A member row for the non-instructor login (so it is a real member session).
insert into members (id, studio_id, user_id, first_name, last_name, email, status) values
  ('85020000-0000-0000-0000-00000000610d',:S,'85020000-0000-0000-0000-0000000000d2','Mem','One','8502-m@example.com','active');

-- --- Starting state: both flags blank ---------------------------------------
set role authenticated; select set_config('request.jwt.claim.sub','85020000-0000-0000-0000-0000000000c1',false);
select expect_null('a fresh instructor has not seen the intro',
  (my_instructor() ->> 'guide_seen_at')::timestamptz);
select expect_num('a fresh instructor has dismissed no hints',
  (select count(*) from jsonb_object_keys(coalesce((my_instructor() -> 'hints_seen'), '{}'::jsonb))), 0);

-- --- 'intro' marks the intro seen; 'reset' un-marks it -----------------------
select instructor_guide_mark('intro');
select expect_true('mark intro sets guide_seen_at',
  (my_instructor() ->> 'guide_seen_at') is not null);
select instructor_guide_mark('reset');
select expect_null('reset clears guide_seen_at',
  (my_instructor() ->> 'guide_seen_at')::timestamptz);

-- --- any other value records a dismissed hint, merged not replaced ----------
select instructor_guide_mark('roster');
select expect_true('mark roster sets hints_seen.roster',
  coalesce((my_instructor() -> 'hints_seen' ->> 'roster')::boolean, false));
select expect_null('a hint does not touch guide_seen_at',
  (my_instructor() ->> 'guide_seen_at')::timestamptz);
select instructor_guide_mark('pay');
select expect_true('a second hint keeps the first (merged)',
  coalesce((my_instructor() -> 'hints_seen' ->> 'roster')::boolean, false)
  and coalesce((my_instructor() -> 'hints_seen' ->> 'pay')::boolean, false));
select set_config('request.jwt.claim.sub','',false); reset role;

-- --- a member-role caller (not an instructor) is refused --------------------
set role authenticated; select set_config('request.jwt.claim.sub','85020000-0000-0000-0000-0000000000d2',false);
select expect_raises('a member cannot mark the instructor guide → PT403',
  $$ select instructor_guide_mark('intro') $$, 'PT403');
select set_config('request.jwt.claim.sub','',false); reset role;

-- --- the writes landed on the right instructor row --------------------------
select expect_true('guide_seen_at was cleared on the instructor row',
  (select guide_seen_at is null from instructors where id = '85020000-0000-0000-0000-00000000d001'));
select expect_true('hints_seen holds roster and pay on the instructor row',
  (select coalesce(hints_seen ->> 'roster','') = 'true' and coalesce(hints_seen ->> 'pay','') = 'true'
     from instructors where id = '85020000-0000-0000-0000-00000000d001'));

-- --- anon surface EXACTLY THIRTEEN ------------------------------------------
select expect_num('anon surface is exactly thirteen',
  (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not like 'expect_%' and p.proname not in ('login','sig','psig')), 13);

select 'guide_test: all assertions passed' as done;
