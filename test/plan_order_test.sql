-- =============================================================================
-- STUDIIOR — DECISION 74: PLAN DISPLAY ORDER AND FEATURED PLANS
--
-- sort_order is a clean 1..n per studio (a new plan appends at the end via the
-- BEFORE INSERT trigger), reorder_plans sets a given order in one atomic write
-- (owner/manager only, refuses another studio's id), the partial unique index
-- keeps live plans distinct, the badge CHECK holds at 24 chars, and the ordered
-- reader lists featured first then by sort_order.
--
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/plan_order_test.sql
--
-- Space: 0d74. Local only — inserts fixtures. Never run against production.
-- =============================================================================

\set ON_ERROR_STOP on
set client_min_messages = notice;

create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if;
end $$;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if;
end $$;

-- ---- Fixtures ---------------------------------------------------------------
insert into studios (id, name, slug, timezone, currency) values
  ('0d740000-0000-0000-0000-0000000000a1','Order Studio','order0d74','Europe/Prague','CZK'),
  ('0d740000-0000-0000-0000-0000000000a2','Other Studio','other0d74','Europe/Prague','CZK');
insert into studio_settings (studio_id) values
  ('0d740000-0000-0000-0000-0000000000a1'), ('0d740000-0000-0000-0000-0000000000a2');

-- Staff logins on SA: an owner (manager-up), a front desk, an instructor.
insert into auth.users (id) values
  ('0d740000-0000-0000-0000-0000000000f1'),
  ('0d740000-0000-0000-0000-0000000000f2'),
  ('0d740000-0000-0000-0000-0000000000f3');
insert into profiles (id, email) values
  ('0d740000-0000-0000-0000-0000000000f1','0d74-owner@t'),
  ('0d740000-0000-0000-0000-0000000000f2','0d74-desk@t'),
  ('0d740000-0000-0000-0000-0000000000f3','0d74-instr@t');
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('0d740000-0000-0000-0000-00000005f001','0d740000-0000-0000-0000-0000000000a1','0d740000-0000-0000-0000-0000000000f1','0d74-owner@t','owner'),
  ('0d740000-0000-0000-0000-00000005f002','0d740000-0000-0000-0000-0000000000a1','0d740000-0000-0000-0000-0000000000f2','0d74-desk@t','front_desk'),
  ('0d740000-0000-0000-0000-00000005f003','0d740000-0000-0000-0000-0000000000a1','0d740000-0000-0000-0000-0000000000f3','0d74-instr@t','instructor');

-- Four live plans on SA, inserted in order (no sort_order given -> trigger
-- appends). A plan on SB for the cross-studio refusal.
insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits) values
  ('0d740000-0000-0000-0000-00000000c1a1','0d740000-0000-0000-0000-0000000000a1','Pack One','class_pack',10000,'CZK',10),
  ('0d740000-0000-0000-0000-00000000c1a2','0d740000-0000-0000-0000-0000000000a1','Pack Two','class_pack',20000,'CZK',10),
  ('0d740000-0000-0000-0000-00000000c1a3','0d740000-0000-0000-0000-0000000000a1','Pack Three','class_pack',30000,'CZK',10),
  ('0d740000-0000-0000-0000-00000000c1a4','0d740000-0000-0000-0000-0000000000a1','Pack Four','class_pack',40000,'CZK',10);
insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits) values
  ('0d740000-0000-0000-0000-0000000000b1','0d740000-0000-0000-0000-0000000000a2','SB Pack','class_pack',10000,'CZK',10);

-- ---- 1. A new plan appends at the end: sort_order is 1..n by insert order ----
select expect_num('74: p1 appended at 1', (select sort_order from membership_plans where id='0d740000-0000-0000-0000-00000000c1a1'), 1);
select expect_num('74: p2 appended at 2', (select sort_order from membership_plans where id='0d740000-0000-0000-0000-00000000c1a2'), 2);
select expect_num('74: p3 appended at 3', (select sort_order from membership_plans where id='0d740000-0000-0000-0000-00000000c1a3'), 3);
select expect_num('74: p4 appended at 4', (select sort_order from membership_plans where id='0d740000-0000-0000-0000-00000000c1a4'), 4);
select expect_num('74: SA live plans form a clean 1..n (4 distinct)',
  (select count(distinct sort_order) from membership_plans where studio_id='0d740000-0000-0000-0000-0000000000a1' and status<>'archived'), 4);

-- ---- 2. reorder_plans sets the given order (as the owner) --------------------
set role authenticated;
select set_config('request.jwt.claim.sub','0d740000-0000-0000-0000-0000000000f1',false);
select reorder_plans('0d740000-0000-0000-0000-0000000000a1',
  array['0d740000-0000-0000-0000-00000000c1a3','0d740000-0000-0000-0000-00000000c1a1',
        '0d740000-0000-0000-0000-00000000c1a4','0d740000-0000-0000-0000-00000000c1a2']::uuid[]);
reset role;
select expect_num('74 reorder: p3 -> 1', (select sort_order from membership_plans where id='0d740000-0000-0000-0000-00000000c1a3'), 1);
select expect_num('74 reorder: p1 -> 2', (select sort_order from membership_plans where id='0d740000-0000-0000-0000-00000000c1a1'), 2);
select expect_num('74 reorder: p4 -> 3', (select sort_order from membership_plans where id='0d740000-0000-0000-0000-00000000c1a4'), 3);
select expect_num('74 reorder: p2 -> 4', (select sort_order from membership_plans where id='0d740000-0000-0000-0000-00000000c1a2'), 4);

-- ---- 3. A new plan still appends at the end (now 5) --------------------------
insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits) values
  ('0d740000-0000-0000-0000-00000000c1a5','0d740000-0000-0000-0000-0000000000a1','Pack Five','class_pack',50000,'CZK',10);
select expect_num('74: a new plan appends at 5 after a reorder',
  (select sort_order from membership_plans where id='0d740000-0000-0000-0000-00000000c1a5'), 5);

-- ---- 4. reorder_plans refuses another studio's id (PT400) --------------------
do $$
declare st text;
begin
  set role authenticated;
  perform set_config('request.jwt.claim.sub','0d740000-0000-0000-0000-0000000000f1',false);
  begin
    perform reorder_plans('0d740000-0000-0000-0000-0000000000a1',
      array['0d740000-0000-0000-0000-00000000c1a1','0d740000-0000-0000-0000-00000000c1a2',
            '0d740000-0000-0000-0000-00000000c1a3','0d740000-0000-0000-0000-00000000c1a4',
            '0d740000-0000-0000-0000-0000000000b1']::uuid[]);  -- b1 is SB's
    st := 'NO_RAISE';
  exception when others then st := sqlstate;
  end;
  reset role;
  perform expect_text('74 reorder: a foreign studio id is refused PT400', st, 'PT400');
end $$;

-- ---- 5. reorder_plans refuses front desk and instructor (PT403) --------------
do $$
declare st text;
begin
  set role authenticated;
  perform set_config('request.jwt.claim.sub','0d740000-0000-0000-0000-0000000000f2',false);  -- front desk
  begin
    perform reorder_plans('0d740000-0000-0000-0000-0000000000a1',
      array['0d740000-0000-0000-0000-00000000c1a1','0d740000-0000-0000-0000-00000000c1a2',
            '0d740000-0000-0000-0000-00000000c1a3','0d740000-0000-0000-0000-00000000c1a4',
            '0d740000-0000-0000-0000-00000000c1a5']::uuid[]);
    st := 'NO_RAISE';
  exception when others then st := sqlstate;
  end;
  reset role;
  perform expect_text('74 reorder: front desk is refused PT403', st, 'PT403');
end $$;
do $$
declare st text;
begin
  set role authenticated;
  perform set_config('request.jwt.claim.sub','0d740000-0000-0000-0000-0000000000f3',false);  -- instructor
  begin
    perform reorder_plans('0d740000-0000-0000-0000-0000000000a1',
      array['0d740000-0000-0000-0000-00000000c1a1','0d740000-0000-0000-0000-00000000c1a2',
            '0d740000-0000-0000-0000-00000000c1a3','0d740000-0000-0000-0000-00000000c1a4',
            '0d740000-0000-0000-0000-00000000c1a5']::uuid[]);
    st := 'NO_RAISE';
  exception when others then st := sqlstate;
  end;
  reset role;
  perform expect_text('74 reorder: an instructor is refused PT403', st, 'PT403');
end $$;

-- ---- 6. The ordered reader lists featured first, then by sort_order ----------
-- p4 is at sort_order 3, but featuring it puts it first — the exact order the
-- member catalogue uses (order by featured desc, sort_order asc).
update membership_plans set featured = true, badge = 'Most popular'
 where id = '0d740000-0000-0000-0000-00000000c1a4';
select expect_text('74 order: a featured plan leads despite a higher sort_order',
  (select id::text from membership_plans
     where studio_id='0d740000-0000-0000-0000-0000000000a1' and status='active'
     order by featured desc, sort_order asc limit 1),
  '0d740000-0000-0000-0000-00000000c1a4');
select expect_text('74 order: the non-featured remainder follows by sort_order (p3 next)',
  (select id::text from membership_plans
     where studio_id='0d740000-0000-0000-0000-0000000000a1' and status='active'
     order by featured desc, sort_order asc offset 1 limit 1),
  '0d740000-0000-0000-0000-00000000c1a3');

-- ---- 7. The badge CHECK holds at 24 characters -------------------------------
do $$
declare st text;
begin
  begin
    update membership_plans set badge = repeat('x', 25)
     where id = '0d740000-0000-0000-0000-00000000c1a1';
    st := 'NO_RAISE';
  exception when check_violation then st := 'CHECK';
  end;
  perform expect_text('74 badge: a 25-char badge is refused by the CHECK', st, 'CHECK');
end $$;
with u as (
  update membership_plans set badge = repeat('y', 24)
   where id = '0d740000-0000-0000-0000-00000000c1a1' returning char_length(badge) as len)
select expect_num('74 badge: a 24-char badge is accepted', (select len from u), 24);

-- ---- 8. The partial unique index keeps live plans distinct -------------------
do $$
declare st text;
begin
  begin
    -- p2 is at 4; force p1 onto 4 too -> two live plans share a sort_order.
    update membership_plans set sort_order = 4
     where id = '0d740000-0000-0000-0000-00000000c1a1';
    st := 'NO_RAISE';
  exception when unique_violation then st := 'UNIQUE';
  end;
  perform expect_text('74 unique: two live plans cannot share a sort_order', st, 'UNIQUE');
end $$;

-- ---- 9. Anon surface stays EXACTLY THIRTEEN ----------------------------------
select expect_num('74: anon surface is exactly thirteen',
  (select count(*) from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
     where ns.nspname='public' and has_function_privilege('anon', p.oid, 'execute')
       and p.proname not like 'expect_%' and p.proname not in ('login','sig','psig')), 13);

do $$ begin raise notice 'ALL DECISION 74 ASSERTIONS PASSED'; end $$;
