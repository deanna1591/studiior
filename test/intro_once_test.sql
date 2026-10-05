-- =============================================================================
-- Decision 62 — an intro offer (a `trial` plan) is bought once per person.
-- UUID space: 1a62
--
-- The first trial purchase succeeds (3 credits, 14-day expiry, status trialing,
-- one +3 ledger row); a second trial is refused PT409 with the exact sentence,
-- via activate_purchase, via xendit_begin_purchase (no checkout row created) and
-- via record_manual_payment. An expired/cancelled first trial still blocks, as
-- does a SECOND trial PLAN of the same studio. A different studio's trial is not
-- blocked (cross-tenant). Packs are unaffected. member_bootstrap.trial_used is
-- true for a member who has had a trial and false otherwise.
-- =============================================================================
\set A '''1a621a62-0000-0000-0000-000000000001'''
\set B '''1a621a62-0000-0000-0000-000000000002'''
\set T   '''1a621a62-0000-0000-0000-000000000101'''
\set T2  '''1a621a62-0000-0000-0000-000000000102'''
\set PACK '''1a621a62-0000-0000-0000-000000000103'''
\set TB  '''1a621a62-0000-0000-0000-000000000201'''

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
create or replace function expect_false(label text, actual boolean)
returns void language plpgsql as $$
begin
  if not coalesce(actual,false) then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected false, got %', label, coalesce(actual::text,'null'); end if;
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
  ('1a621a62-0000-0000-0000-0000000000a1'),   -- owner A (manager-up / desk-up)
  ('1a621a62-0000-0000-0000-0000000000e1'),   -- M_xen login
  ('1a621a62-0000-0000-0000-0000000000e2');   -- M_boot login
insert into profiles (id, email) values
  ('1a621a62-0000-0000-0000-0000000000a1','1a62-owa@example.com'),
  ('1a621a62-0000-0000-0000-0000000000e1','1a62-xen@example.com'),
  ('1a621a62-0000-0000-0000-0000000000e2','1a62-boot@example.com');

insert into studios (id, name, slug, timezone, currency, status, contact_email) values
  (:A,'Intro A','intro-a','Europe/Prague','CZK','active','hi@intro-a.example.com'),
  (:B,'Intro B','intro-b','Europe/Prague','CZK','active',null);
insert into studio_settings (studio_id) values (:A), (:B);
insert into locations (id, studio_id, name, is_primary) values
  ('1a621a62-0000-0000-0000-00000000000a',:A,'Main',true),
  ('1a621a62-0000-0000-0000-00000000000b',:B,'Main',true);

insert into studio_staff (id, studio_id, user_id, email, role) values
  ('1a621a62-0000-0000-0000-000000aa00a1',:A,'1a621a62-0000-0000-0000-0000000000a1','1a62-owa@example.com','owner');

-- An Xendit provider on A, so xendit_begin_purchase gets past its provider gate
-- (the SQL never decrypts the ciphertext — only the sha256 matters here).
insert into studio_payment_providers
  (studio_id, provider, secret_key_ciphertext, callback_token_ciphertext, callback_token_sha256,
   key_last4, test_mode, connected_by) values
  (:A,'xendit','v1.opaque','v1.opaque', encode(digest('tok','sha256'),'hex'),
   'tok0', true, '1a621a62-0000-0000-0000-0000000000a1');

-- Plans: two trials and a pack on A; a trial on B (cross-tenant). All public so
-- the member app / buy page could sell them; the once-per-person rule is the DB.
insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, validity_days, visibility, status) values
  (:T,   :A,'Intro Offer',  'trial',     200000,'CZK', 3, 14, 'public','active'),
  (:T2,  :A,'Intro Offer 2','trial',     150000,'CZK', 2, 10, 'public','active'),
  (:PACK,:A,'10-Class Pack','class_pack',550000,'CZK',10,180, 'public','active'),
  (:TB,  :B,'B Intro',      'trial',     100000,'CZK', 1, 14, 'public','active');

-- Members. M_act drives the activate_purchase path (no login needed — service).
-- M_xen / M_boot have logins for xendit_begin_purchase and member_bootstrap.
insert into members (id, studio_id, first_name, last_name, email, status, user_id) values
  ('1a621a62-0000-0000-0000-00000000a001',:A,'Al','Act',  '1a62-act@example.com', 'active', null),
  ('1a621a62-0000-0000-0000-00000000e001',:A,'Xen','User','1a62-xenm@example.com','active','1a621a62-0000-0000-0000-0000000000e1'),
  ('1a621a62-0000-0000-0000-00000000e002',:A,'Boo','Fresh','1a62-bootm@example.com','active','1a621a62-0000-0000-0000-0000000000e2'),
  ('1a621a62-0000-0000-0000-00000000d001',:A,'Man','Used','1a62-manu@example.com','active', null),
  ('1a621a62-0000-0000-0000-00000000d002',:A,'Meg','Fresh','1a62-manf@example.com','active', null),
  ('1a621a62-0000-0000-0000-00000000b001',:B,'Bee','Bof', '1a62-bee@example.com', 'active', null);

reset role;

-- =============================================================================
-- 1. activate_purchase (service): the first trial grants a real pack.
-- =============================================================================
select activate_purchase(:A, '1a621a62-0000-0000-0000-00000000a001', :T, 200000, 'CZK') as _;

select expect_num('first trial: one trialing membership',
  (select count(*) from memberships where member_id='1a621a62-0000-0000-0000-00000000a001'
     and plan_id=:T and status='trialing'), 1);
select expect_num('first trial: 3 credits',
  (select credits_remaining from memberships where member_id='1a621a62-0000-0000-0000-00000000a001' and plan_id=:T), 3);
select expect_true('first trial: expires_on = today + 14',
  (select expires_on = studio_today(:A) + 14 from memberships
     where member_id='1a621a62-0000-0000-0000-00000000a001' and plan_id=:T));
select expect_num('first trial: one +3 purchase ledger row',
  (select count(*) from credit_ledger where member_id='1a621a62-0000-0000-0000-00000000a001'
     and reason='purchase' and delta=3), 1);

-- A second trial on the SAME plan — PT409, the exact sentence.
select expect_raises('activate: second trial (same plan) refused PT409',
  $$ select activate_purchase('1a621a62-0000-0000-0000-000000000001','1a621a62-0000-0000-0000-00000000a001','1a621a62-0000-0000-0000-000000000101',200000,'CZK') $$,
  'PT409');

-- The message text, captured directly.
do $$
declare msg text;
begin
  begin
    perform activate_purchase('1a621a62-0000-0000-0000-000000000001','1a621a62-0000-0000-0000-00000000a001',
                              '1a621a62-0000-0000-0000-000000000101',200000,'CZK');
  exception when others then msg := sqlerrm;
  end;
  perform set_config('t.msg', coalesce(msg,'(none)'), false);
end $$;
select expect_text('activate: the exact first-timers sentence',
  current_setting('t.msg'),
  'The intro offer is for first-timers — you''ve had yours. Choose a pack or membership instead.');

-- A SECOND trial PLAN of the same studio is also blocked.
select expect_raises('activate: a second trial PLAN of the studio refused PT409',
  $$ select activate_purchase('1a621a62-0000-0000-0000-000000000001','1a621a62-0000-0000-0000-00000000a001','1a621a62-0000-0000-0000-000000000102',150000,'CZK') $$,
  'PT409');

-- An EXPIRED / CANCELLED first trial still blocks (any status).
update memberships set status='cancelled'
  where member_id='1a621a62-0000-0000-0000-00000000a001' and plan_id=:T;
select expect_raises('activate: a cancelled first trial still blocks',
  $$ select activate_purchase('1a621a62-0000-0000-0000-000000000001','1a621a62-0000-0000-0000-00000000a001','1a621a62-0000-0000-0000-000000000101',200000,'CZK') $$,
  'PT409');
update memberships set status='expired'
  where member_id='1a621a62-0000-0000-0000-00000000a001' and plan_id=:T;
select expect_raises('activate: an expired first trial still blocks',
  $$ select activate_purchase('1a621a62-0000-0000-0000-000000000001','1a621a62-0000-0000-0000-00000000a001','1a621a62-0000-0000-0000-000000000102',150000,'CZK') $$,
  'PT409');

-- Packs are unaffected: the trial-used member can still buy a pack.
select activate_purchase(:A, '1a621a62-0000-0000-0000-00000000a001', :PACK, 550000, 'CZK') as _;
select expect_num('packs unaffected: pack membership activates for a trial-used member',
  (select count(*) from memberships where member_id='1a621a62-0000-0000-0000-00000000a001'
     and plan_id=:PACK and status='active'), 1);

-- Cross-tenant: B's member buys B's trial — not blocked by A's trials.
select activate_purchase(:B, '1a621a62-0000-0000-0000-00000000b001', :TB, 100000, 'CZK') as _;
select expect_num('cross-tenant: B member buys B trial — not blocked',
  (select count(*) from memberships where member_id='1a621a62-0000-0000-0000-00000000b001'
     and plan_id=:TB and status='trialing'), 1);

-- =============================================================================
-- 2. xendit_begin_purchase (member session): trial admitted, once per person.
-- =============================================================================
-- M_xen is fresh: the first begin creates a checkout row.
set role authenticated; select set_config('request.jwt.claim.sub','1a621a62-0000-0000-0000-0000000000e1',false);
select purchase_id from xendit_begin_purchase(:A, :T) \gset xbp_
select set_config('request.jwt.claim.sub','',false); reset role;

select expect_num('xendit: first trial begin creates one checkout row',
  (select count(*) from xendit_purchases where member_id='1a621a62-0000-0000-0000-00000000e001' and plan_id=:T), 1);

-- Now make M_xen trial-used (service activate), then begin again must refuse
-- with no new checkout row.
select activate_purchase(:A, '1a621a62-0000-0000-0000-00000000e001', :T, 200000, 'CZK') as _;
select set_config('t.xen_rows_before',
  (select count(*) from xendit_purchases where member_id='1a621a62-0000-0000-0000-00000000e001')::text, false);

set role authenticated; select set_config('request.jwt.claim.sub','1a621a62-0000-0000-0000-0000000000e1',false);
select expect_raises('xendit: a used trial begin refused PT409',
  $$ select xendit_begin_purchase('1a621a62-0000-0000-0000-000000000001','1a621a62-0000-0000-0000-000000000101') $$,
  'PT409');
select expect_raises('xendit: the second trial PLAN also refused PT409',
  $$ select xendit_begin_purchase('1a621a62-0000-0000-0000-000000000001','1a621a62-0000-0000-0000-000000000102') $$,
  'PT409');
select set_config('request.jwt.claim.sub','',false); reset role;

select expect_num('xendit: no checkout row created by the refused begin',
  (select count(*) from xendit_purchases where member_id='1a621a62-0000-0000-0000-00000000e001'),
  current_setting('t.xen_rows_before')::bigint);

-- A pack via xendit still works for the trial-used member (one-time, unaffected).
set role authenticated; select set_config('request.jwt.claim.sub','1a621a62-0000-0000-0000-0000000000e1',false);
select purchase_id from xendit_begin_purchase(:A, :PACK) \gset xpack_
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_num('xendit: a pack begin still works for a trial-used member',
  (select count(*) from xendit_purchases where member_id='1a621a62-0000-0000-0000-00000000e001' and plan_id=:PACK), 1);

-- =============================================================================
-- 3. record_manual_payment (desk session): same belt.
-- =============================================================================
-- M_manu_used already has a trial (service activate), so the manual sale refuses.
select activate_purchase(:A, '1a621a62-0000-0000-0000-00000000d001', :T, 200000, 'CZK') as _;

set role authenticated; select set_config('request.jwt.claim.sub','1a621a62-0000-0000-0000-0000000000a1',false);
select expect_raises('manual sale: a used trial refused PT409',
  $$ select record_manual_payment('1a621a62-0000-0000-0000-000000000001','1a621a62-0000-0000-0000-00000000d001','plan',200000,'cash','1a621a62-0000-0000-0000-000000000101') $$,
  'PT409');
-- A fresh member's manual trial sale succeeds.
select record_manual_payment(:A, '1a621a62-0000-0000-0000-00000000d002','plan',200000,'cash',:T) as _;
select set_config('request.jwt.claim.sub','',false); reset role;

select expect_num('manual sale: a fresh member gets the trial',
  (select count(*) from memberships where member_id='1a621a62-0000-0000-0000-00000000d002'
     and plan_id=:T and status='trialing'), 1);

-- =============================================================================
-- 4. member_bootstrap.trial_used
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','1a621a62-0000-0000-0000-0000000000e1',false);
select expect_true('bootstrap: trial_used true for a member who has had a trial',
  (select trial_used from member_bootstrap('intro-a')));
select set_config('request.jwt.claim.sub','',false); reset role;

set role authenticated; select set_config('request.jwt.claim.sub','1a621a62-0000-0000-0000-0000000000e2',false);
select expect_false('bootstrap: trial_used false for a fresh member',
  (select trial_used from member_bootstrap('intro-a')));
select set_config('request.jwt.claim.sub','',false); reset role;

-- --- cleanup -----------------------------------------------------------------
drop function expect_num(text, bigint, bigint);
drop function expect_true(text, boolean);
drop function expect_false(text, boolean);
drop function expect_text(text, text, text);
drop function expect_raises(text, text, text);
