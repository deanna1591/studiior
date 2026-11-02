-- =============================================================================
-- Decision 88 slice A — member_covers_occurrence. Migration 20260833140000.
-- =============================================================================
-- UUID space c088 (hex), checked free. Run after `supabase db reset`.
--
-- The one read the checkout build adds: does this member's plan cover the class?
-- A faithful mirror of book_class §2.2's membership resolution — a plan with
-- credits (or unlimited recurring), active/not-frozen/not-expired, including
-- this class type. The class page routes Book on the four "uncovered" cases to
-- /checkout; a covered class still books inline.
--
-- RED proof: on the pre-88 schema member_covers_occurrence does not exist, so
-- every `cov(...)` call errors with 42883 rather than returning true/false.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to warning;

create or replace function login(uid text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', uid, true); set local role authenticated; end $$;
create or replace function expect_text(label text, actual text, want text) returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'BAD  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if; end $$;
create or replace function expect_num(label text, actual bigint, want bigint) returns void language plpgsql as $$
begin if actual = want then raise notice 'PASS  %  (got %)', label, actual; else raise exception 'BAD  %  expected %, got %', label, want, actual; end if; end $$;
-- Runs member_covers_occurrence AS the given member session, capturing a refusal
-- as its SQLSTATE so a PT403 is asserted rather than aborting the suite.
create or replace function cov(uid text, occ uuid) returns jsonb language plpgsql as $$
declare r boolean; begin
  perform set_config('request.jwt.claim.sub', uid, true); set local role authenticated;
  begin r := member_covers_occurrence(occ); reset role; return jsonb_build_object('v', r);
  exception when others then reset role; return jsonb_build_object('err', sqlstate); end;
end $$;

reset role;

-- ---- Studio, room, two class types ------------------------------------------
insert into studios (id, name, slug, timezone, currency, status) values
  ('c0880000-0000-0000-0000-0000000000a0','Checkout SA','c088-sa','UTC','PHP','active');
insert into studio_settings (studio_id, require_waiver) values
  ('c0880000-0000-0000-0000-0000000000a0', false);
insert into locations (id, studio_id, name) values
  ('c0880000-0000-0000-0000-00000000a0a0','c0880000-0000-0000-0000-0000000000a0','Main');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('c0880000-0000-0000-0000-00000000aa01','c0880000-0000-0000-0000-0000000000a0','c0880000-0000-0000-0000-00000000a0a0','Studio',20);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('c0880000-0000-0000-0000-00000000c0a1','c0880000-0000-0000-0000-0000000000a0','Reformer',50,20),
  ('c0880000-0000-0000-0000-00000000c0a2','c0880000-0000-0000-0000-0000000000a0','Mat',50,20);

-- The class under checkout — class type Reformer (c0a1).
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, starts_at, ends_at, capacity, status, staffing, name) values
  ('c0880000-0000-0000-0000-0000000000c1','c0880000-0000-0000-0000-0000000000a0','c0880000-0000-0000-0000-00000000a0a0','c0880000-0000-0000-0000-00000000c0a1','c0880000-0000-0000-0000-00000000aa01',null, now()+interval '3 day', now()+interval '3 day'+interval '50 min', 20,'scheduled','open','Reformer Flow');

-- ---- Plans: a pack, an unlimited recurring, and a pack restricted to Mat -----
insert into membership_plans (id, studio_id, name, type, visibility, status, price_cents, currency, credits, credits_per_period, validity_days, billing_interval, restrictions) values
  ('c0880000-0000-0000-0000-00000000f001','c0880000-0000-0000-0000-0000000000a0','5 Pack','class_pack','public','active',100000,'PHP',5,null,90,null,'{}'::jsonb),
  ('c0880000-0000-0000-0000-00000000f002','c0880000-0000-0000-0000-0000000000a0','Unlimited','recurring','public','active',300000,'PHP',null,null,null,'month','{}'::jsonb),
  ('c0880000-0000-0000-0000-00000000f003','c0880000-0000-0000-0000-0000000000a0','Mat Pack','class_pack','public','active',80000,'PHP',5,null,90,null,
    jsonb_build_object('class_type_ids', jsonb_build_array('c0880000-0000-0000-0000-00000000c0a2')));

-- ---- Logins + profiles ------------------------------------------------------
insert into auth.users (id) values
  ('c0880000-0000-0000-0000-000000001001'),('c0880000-0000-0000-0000-000000001002'),
  ('c0880000-0000-0000-0000-000000001003'),('c0880000-0000-0000-0000-000000001004'),
  ('c0880000-0000-0000-0000-000000001005'),('c0880000-0000-0000-0000-000000001006'),
  ('c0880000-0000-0000-0000-000000009999');
insert into profiles (id, email, full_name) values
  ('c0880000-0000-0000-0000-000000001001','cov@a.co','Cov'),('c0880000-0000-0000-0000-000000001002','unl@a.co','Unl'),
  ('c0880000-0000-0000-0000-000000001003','unc@a.co','Unc'),('c0880000-0000-0000-0000-000000001004','exp@a.co','Exp'),
  ('c0880000-0000-0000-0000-000000001005','res@a.co','Res'),('c0880000-0000-0000-0000-000000001006','frz@a.co','Frz'),
  ('c0880000-0000-0000-0000-000000009999','stranger@a.co','Stranger');

-- ---- Members ----------------------------------------------------------------
insert into members (id, studio_id, user_id, first_name, last_name, email, status, joined_on) values
  ('c0880000-0000-0000-0000-00000000dd01','c0880000-0000-0000-0000-0000000000a0','c0880000-0000-0000-0000-000000001001','Cov','Ered','cov@a.co','active', now()),
  ('c0880000-0000-0000-0000-00000000dd02','c0880000-0000-0000-0000-0000000000a0','c0880000-0000-0000-0000-000000001002','Un','Limited','unl@a.co','active', now()),
  ('c0880000-0000-0000-0000-00000000dd03','c0880000-0000-0000-0000-0000000000a0','c0880000-0000-0000-0000-000000001003','Un','Covered','unc@a.co','active', now()),
  ('c0880000-0000-0000-0000-00000000dd04','c0880000-0000-0000-0000-0000000000a0','c0880000-0000-0000-0000-000000001004','Ex','Pired','exp@a.co','active', now()),
  ('c0880000-0000-0000-0000-00000000dd05','c0880000-0000-0000-0000-0000000000a0','c0880000-0000-0000-0000-000000001005','Re','Stricted','res@a.co','active', now()),
  ('c0880000-0000-0000-0000-00000000dd06','c0880000-0000-0000-0000-0000000000a0','c0880000-0000-0000-0000-000000001006','Fr','Ozen','frz@a.co','active', now());
-- Stranger: a login with NO member row at this studio.

-- ---- Memberships ------------------------------------------------------------
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on, expires_on, credits_remaining) values
  -- pack with credits → covered
  ('c0880000-0000-0000-0000-00000000f101','c0880000-0000-0000-0000-0000000000a0','c0880000-0000-0000-0000-00000000dd01','c0880000-0000-0000-0000-00000000f001','active',100000,'PHP', now()::date, (now()+interval '60 day')::date, 5),
  -- unlimited recurring (credits_remaining null) → covered
  ('c0880000-0000-0000-0000-00000000f102','c0880000-0000-0000-0000-0000000000a0','c0880000-0000-0000-0000-00000000dd02','c0880000-0000-0000-0000-00000000f002','active',300000,'PHP', now()::date, null, null),
  -- expired pack (expires_on yesterday) → not covered
  ('c0880000-0000-0000-0000-00000000f104','c0880000-0000-0000-0000-0000000000a0','c0880000-0000-0000-0000-00000000dd04','c0880000-0000-0000-0000-00000000f001','active',100000,'PHP', (now()-interval '90 day')::date, (now()-interval '1 day')::date, 5),
  -- pack restricted to Mat, booking a Reformer class → not covered
  ('c0880000-0000-0000-0000-00000000f105','c0880000-0000-0000-0000-0000000000a0','c0880000-0000-0000-0000-00000000dd05','c0880000-0000-0000-0000-00000000f003','active',80000,'PHP', now()::date, (now()+interval '60 day')::date, 5);
-- frozen-now pack → not covered
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on, expires_on, credits_remaining, freeze_start, freeze_end) values
  ('c0880000-0000-0000-0000-00000000f106','c0880000-0000-0000-0000-0000000000a0','c0880000-0000-0000-0000-00000000dd06','c0880000-0000-0000-0000-00000000f001','frozen',100000,'PHP', now()::date, (now()+interval '60 day')::date, 5, (now()-interval '2 day')::date, (now()+interval '5 day')::date);

-- =============================================================================
-- Assertions
-- =============================================================================
\set OCC '''c0880000-0000-0000-0000-0000000000c1'''

select expect_text('pack with credits covers the class',
  cov('c0880000-0000-0000-0000-000000001001', :OCC)->>'v', 'true');
select expect_text('unlimited recurring covers the class',
  cov('c0880000-0000-0000-0000-000000001002', :OCC)->>'v', 'true');
select expect_text('no membership is not covered',
  cov('c0880000-0000-0000-0000-000000001003', :OCC)->>'v', 'false');
select expect_text('expired membership is not covered',
  cov('c0880000-0000-0000-0000-000000001004', :OCC)->>'v', 'false');
select expect_text('a plan restricted to another class type does not cover it',
  cov('c0880000-0000-0000-0000-000000001005', :OCC)->>'v', 'false');
select expect_text('a frozen membership does not cover it',
  cov('c0880000-0000-0000-0000-000000001006', :OCC)->>'v', 'false');
select expect_text('a stranger (no member at this studio) is refused PT403',
  cov('c0880000-0000-0000-0000-000000009999', :OCC)->>'err', 'PT403');

-- Anon surface EXACTLY THIRTEEN (the suite helpers excluded by name).
select expect_num('anon surface is thirteen',
  (select count(*) from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
     where ns.nspname='public' and has_function_privilege('anon', p.oid, 'execute')
       and p.proname not in ('login','expect_text','expect_num','cov')), 13);

drop function login(text); drop function expect_text(text,text,text);
drop function expect_num(text,bigint,bigint); drop function cov(text,uuid);

select 'checkout_coverage_test OK' as result;
