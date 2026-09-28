-- =============================================================================
-- Xendit adapter — Decision 40 Part A, migrations 20260831800000 / 20260831810000
-- =============================================================================
-- UUID space e40d, checked free (51 assertions). Run after `supabase db reset`.
--
-- Covers: a member cannot read the provider row (owner-only RLS); the anon
-- surface is EXACTLY twelve, naming xendit_webhook; begin_purchase snapshots the
-- amount from the plan and refuses a recurring plan / a non-member; a callback
-- with a WRONG token raises PT401 and stores NO event; a SUCCEEDED callback
-- activates the plan (credits + expiry, exactly as a manual payment) and writes
-- the xendit payments row; a REPLAY is a duplicate with no second activation; an
-- AMOUNT MISMATCH is refused and logged with no activation; a failure notifies
-- the member; an unknown reference is ignored and stores nothing; the owner-
-- triggered apply activates and refuses a non-manager; the reconcile sweep
-- expires a stale pending, leaves a fresh one, and refuses a signed-in user; and
-- member_bootstrap.xendit_enabled is true while has_payment_provider stays false.
-- Teeth on every guard.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual then raise notice 'PASS  %  (got true)', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('e40de40d-0000-0000-0000-0000000000a1'),  -- owner
  ('e40de40d-0000-0000-0000-000000000e01'),  -- member (with login)
  ('e40de40d-0000-0000-0000-000000000e02');  -- another member (non-member of provider actions? same studio)
insert into profiles (id, email)
  select id, id::text||'@example.com' from auth.users where id::text like 'e40de40d%';

insert into studios (id, name, slug, timezone, currency, status) values
  ('e40de40d-0000-0000-0000-000000000001','Xen A','e40d-s','Asia/Manila','PHP','active');
insert into studio_settings (studio_id) values ('e40de40d-0000-0000-0000-000000000001');
insert into locations (id, studio_id, name, is_primary) values
  ('e40de40d-0000-0000-0000-00000000000a','e40de40d-0000-0000-0000-000000000001','Main',true);
insert into studio_staff (studio_id, user_id, email, role) values
  ('e40de40d-0000-0000-0000-000000000001','e40de40d-0000-0000-0000-0000000000a1','e40d-ow@example.com','owner');
insert into members (id, studio_id, user_id, first_name, last_name, email, status) values
  ('e40de40d-0000-0000-0000-00000000dd01','e40de40d-0000-0000-0000-000000000001',
   'e40de40d-0000-0000-0000-000000000e01','Mem','One','mem1@example.com','active');

-- A one-time pack (buyable) at ₱1,400 = 140000 centavos, a recurring plan (not
-- buyable online — Part A is one-time only), both public + active.
insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, validity_days, visibility, status) values
  ('e40de40d-0000-0000-0000-0000000cc001','e40de40d-0000-0000-0000-000000000001','5-Class Pack','class_pack',140000,'PHP',10,30,'public','active');
insert into membership_plans (id, studio_id, name, type, price_cents, currency, billing_interval, visibility, status) values
  ('e40de40d-0000-0000-0000-0000000cc002','e40de40d-0000-0000-0000-000000000001','Unlimited','recurring',250000,'PHP','month','public','active');

-- The connected Xendit provider. secret/callback ciphertext are opaque here
-- (the SQL never decrypts them — encryption is TS-side, unit-tested separately);
-- the webhook verifies the callback token against callback_token_sha256, so that
-- is the only cryptographic value the SQL depends on. Token is 'goodtoken'.
insert into studio_payment_providers
  (studio_id, provider, secret_key_ciphertext, callback_token_ciphertext, callback_token_sha256,
   key_last4, test_mode, connected_by) values
  ('e40de40d-0000-0000-0000-000000000001','xendit','v1.opaque-secret','v1.opaque-token',
   encode(digest('goodtoken','sha256'),'hex'), 'tok0', true, 'e40de40d-0000-0000-0000-0000000000a1');

-- =============================================================================
-- 1. Owner-only RLS on the provider row.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','e40de40d-0000-0000-0000-000000000e01',false);
select set_config('t.member_reads', (select count(*) from studio_payment_providers
   where studio_id='e40de40d-0000-0000-0000-000000000001')::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;

set role authenticated; select set_config('request.jwt.claim.sub','e40de40d-0000-0000-0000-0000000000a1',false);
select set_config('t.owner_reads', (select count(*) from studio_payment_providers
   where studio_id='e40de40d-0000-0000-0000-000000000001')::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;

select expect_num('member cannot read the provider secrets', current_setting('t.member_reads')::bigint, 0);
select expect_num('owner reads its own provider row', current_setting('t.owner_reads')::bigint, 1);

-- =============================================================================
-- 2. Anon surface is EXACTLY twelve, and xendit_webhook is one of them.
-- =============================================================================
select expect_num('anon surface is exactly twelve',
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not like 'expect\_%'), 12);
select expect_true('xendit_webhook is anon-executable',
  has_function_privilege('anon', 'xendit_webhook(jsonb, text)'::regprocedure, 'execute'));

-- =============================================================================
-- 3. begin_purchase snapshots the amount from the plan; refuses recurring / non-member.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','e40de40d-0000-0000-0000-000000000e01',false);
select set_config('t.pid1', (select purchase_id::text from xendit_begin_purchase(
  'e40de40d-0000-0000-0000-000000000001','e40de40d-0000-0000-0000-0000000cc001')), false);
select set_config('t.amt1', (select amount_cents::text from xendit_purchases where id=current_setting('t.pid1')::uuid), false);

do $$ begin
  begin perform xendit_begin_purchase('e40de40d-0000-0000-0000-000000000001','e40de40d-0000-0000-0000-0000000cc002');
    perform set_config('t.recurring','no_raise',false);
  exception when others then perform set_config('t.recurring', sqlstate, false); end;
end $$;
select set_config('request.jwt.claim.sub','',false); reset role;

-- A non-member (no members row here for e02) is refused.
set role authenticated; select set_config('request.jwt.claim.sub','e40de40d-0000-0000-0000-000000000e02',false);
do $$ begin
  begin perform xendit_begin_purchase('e40de40d-0000-0000-0000-000000000001','e40de40d-0000-0000-0000-0000000cc001');
    perform set_config('t.nonmember','no_raise',false);
  exception when others then perform set_config('t.nonmember', sqlstate, false); end;
  begin perform xendit_checkout_context('e40de40d-0000-0000-0000-000000000001');
    perform set_config('t.cc_nonmember','no_raise',false);
  exception when others then perform set_config('t.cc_nonmember', sqlstate, false); end;
end $$;
select set_config('request.jwt.claim.sub','',false); reset role;

select expect_num('begin_purchase snapshots the plan amount (₱1,400 = 140000)', current_setting('t.amt1')::bigint, 140000);
select expect_text('a recurring plan is refused (PT422)', current_setting('t.recurring'), 'PT422');
select expect_text('a non-member is refused begin_purchase (PT403)', current_setting('t.nonmember'), 'PT403');
select expect_text('a non-member is refused checkout_context (PT403)', current_setting('t.cc_nonmember'), 'PT403');

-- =============================================================================
-- 4. A WRONG callback token raises PT401 and stores NO event.
-- =============================================================================
select set_config('t.ev_ok', jsonb_build_object(
  'event','payment.succeeded',
  'data', jsonb_build_object('reference_id', current_setting('t.pid1'),
     'payment_id','py-e40d-1','status','SUCCEEDED','amount',1400,'currency','PHP'))::text, false);

do $$ begin
  begin perform xendit_webhook(current_setting('t.ev_ok')::jsonb, 'WRONGTOKEN');
    perform set_config('t.badtok','no_raise',false);
  exception when others then perform set_config('t.badtok', sqlstate, false); end;
end $$;
select expect_text('a wrong callback token raises PT401', current_setting('t.badtok'), 'PT401');
select expect_num('a wrong token stores NO event', (select count(*) from xendit_events), 0);

-- =============================================================================
-- 5. A SUCCEEDED callback activates the plan, exactly as a manual payment would.
-- =============================================================================
select set_config('t.r_ok', (xendit_webhook(current_setting('t.ev_ok')::jsonb, 'goodtoken'))->>'result', false);

select expect_text('a good-token success is processed', current_setting('t.r_ok'), 'processed');
select expect_text('the purchase is marked succeeded', (select status from xendit_purchases where id=current_setting('t.pid1')::uuid), 'succeeded');
select expect_text('the xendit payment id is stored', (select xendit_payment_id from xendit_purchases where id=current_setting('t.pid1')::uuid), 'py-e40d-1');
select expect_num('one membership was granted on the pack',
  (select count(*) from memberships where member_id='e40de40d-0000-0000-0000-00000000dd01' and plan_id='e40de40d-0000-0000-0000-0000000cc001'), 1);
select expect_num('the pack credits were granted (10)',
  (select credits_remaining from memberships where member_id='e40de40d-0000-0000-0000-00000000dd01' and plan_id='e40de40d-0000-0000-0000-0000000cc001'), 10);
select expect_true('the pack has an expiry, as a manual pack would',
  (select expires_on is not null from memberships where member_id='e40de40d-0000-0000-0000-00000000dd01' and plan_id='e40de40d-0000-0000-0000-0000000cc001'));
select expect_num('a xendit payments row was written', (select count(*) from payments
   where member_id='e40de40d-0000-0000-0000-00000000dd01' and provider='xendit'), 1);
select expect_text('the payments row references the xendit payment id',
  (select reference from payments where member_id='e40de40d-0000-0000-0000-00000000dd01' and provider='xendit'), 'py-e40d-1');
select expect_num('the payments amount matches the plan (140000)',
  (select amount_cents from payments where member_id='e40de40d-0000-0000-0000-00000000dd01' and provider='xendit'), 140000);

-- =============================================================================
-- 6. A REPLAY of the same event is a duplicate — no second activation.
-- =============================================================================
select set_config('t.r_dup', (xendit_webhook(current_setting('t.ev_ok')::jsonb, 'goodtoken'))->>'result', false);
select expect_text('a replayed event is a duplicate', current_setting('t.r_dup'), 'duplicate');
select expect_num('no second membership from the replay',
  (select count(*) from memberships where member_id='e40de40d-0000-0000-0000-00000000dd01'), 1);
select expect_num('no second payments row from the replay',
  (select count(*) from payments where member_id='e40de40d-0000-0000-0000-00000000dd01' and provider='xendit'), 1);

-- =============================================================================
-- 7. An AMOUNT MISMATCH is refused and logged; no activation.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','e40de40d-0000-0000-0000-000000000e01',false);
select set_config('t.pid2', (select purchase_id::text from xendit_begin_purchase(
  'e40de40d-0000-0000-0000-000000000001','e40de40d-0000-0000-0000-0000000cc001')), false);
select set_config('request.jwt.claim.sub','',false); reset role;

select set_config('t.ev_bad', jsonb_build_object(
  'event','payment.succeeded',
  'data', jsonb_build_object('reference_id', current_setting('t.pid2'),
     'payment_id','py-e40d-2','status','SUCCEEDED','amount',9999,'currency','PHP'))::text, false);
select set_config('t.r_bad', (xendit_webhook(current_setting('t.ev_bad')::jsonb, 'goodtoken'))->>'reason', false);

select expect_text('an amount mismatch is refused', current_setting('t.r_bad'), 'amount_mismatch');
select expect_text('the mismatch is logged on the event',
  (select error from xendit_events where payload->'data'->>'payment_id'='py-e40d-2'), 'amount_mismatch');
select expect_text('the mismatched purchase is still pending (not activated)',
  (select status from xendit_purchases where id=current_setting('t.pid2')::uuid), 'pending');
select expect_num('still only one membership (mismatch did not activate)',
  (select count(*) from memberships where member_id='e40de40d-0000-0000-0000-00000000dd01'), 1);

-- =============================================================================
-- 8. A failure callback marks the purchase failed and notifies the member.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','e40de40d-0000-0000-0000-000000000e01',false);
select set_config('t.pid3', (select purchase_id::text from xendit_begin_purchase(
  'e40de40d-0000-0000-0000-000000000001','e40de40d-0000-0000-0000-0000000cc001')), false);
select set_config('request.jwt.claim.sub','',false); reset role;

select set_config('t.ev_fail', jsonb_build_object(
  'event','payment.failure',
  'data', jsonb_build_object('reference_id', current_setting('t.pid3'),
     'payment_id','py-e40d-3','status','FAILED','failure_code','CARD_DECLINED'))::text, false);
select set_config('t.r_fail', (xendit_webhook(current_setting('t.ev_fail')::jsonb, 'goodtoken'))->>'outcome', false);

select expect_text('a failure callback is processed as failed', current_setting('t.r_fail'), 'failed');
select expect_text('the purchase is marked failed', (select status from xendit_purchases where id=current_setting('t.pid3')::uuid), 'failed');
select expect_true('the member was notified of the failure',
  (select count(*) > 0 from notifications where member_id='e40de40d-0000-0000-0000-00000000dd01' and template_key='xendit_purchase_failed'));

-- =============================================================================
-- 9. An unknown reference (valid UUID, no purchase) is ignored — and STORED
--    (Decision 40 amendment 2: after the token is verified, every event is
--    recorded, even an ignored one), activating nothing.
-- =============================================================================
select set_config('t.ev_unk', jsonb_build_object(
  'event','payment.succeeded',
  'data', jsonb_build_object('reference_id','e40de40d-0000-0000-0000-0000deadbeef',
     'payment_id','py-unknown','status','SUCCEEDED'))::text, false);
select set_config('t.events_before', (select count(*) from xendit_events)::text, false);
select set_config('t.r_unk', (xendit_webhook(current_setting('t.ev_unk')::jsonb, 'goodtoken'))->>'reason', false);
select expect_text('an unknown reference is ignored', current_setting('t.r_unk'), 'unknown_reference');
select expect_num('...and the event IS stored (token was valid), marked ignored',
  (select count(*) from xendit_events), current_setting('t.events_before')::bigint + 1);
select expect_text('...the stored event carries the reason', (select error from xendit_events where payload->'data'->>'payment_id'='py-unknown'), 'unknown_reference');

-- =============================================================================
-- 10. Owner-triggered apply: COMPLETED activates; a non-manager is refused.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','e40de40d-0000-0000-0000-000000000e01',false);
select set_config('t.pid4', (select purchase_id::text from xendit_begin_purchase(
  'e40de40d-0000-0000-0000-000000000001','e40de40d-0000-0000-0000-0000000cc001')), false);
-- the member (non-manager) cannot apply
do $$ begin
  begin perform xendit_apply_session(current_setting('t.pid4')::uuid,'COMPLETED','py-e40d-4');
    perform set_config('t.apply_member','no_raise',false);
  exception when others then perform set_config('t.apply_member', sqlstate, false); end;
end $$;
select set_config('request.jwt.claim.sub','',false); reset role;

-- the owner (manager-up) applies COMPLETED
set role authenticated; select set_config('request.jwt.claim.sub','e40de40d-0000-0000-0000-0000000000a1',false);
select set_config('t.apply_ok', (xendit_apply_session(current_setting('t.pid4')::uuid,'COMPLETED','py-e40d-4'))->>'outcome', false);
select set_config('request.jwt.claim.sub','',false); reset role;

select expect_text('a non-manager cannot apply a session (PT403)', current_setting('t.apply_member'), 'PT403');
select expect_text('the owner applies COMPLETED → succeeded', current_setting('t.apply_ok'), 'succeeded');
select expect_text('the applied purchase is succeeded', (select status from xendit_purchases where id=current_setting('t.pid4')::uuid), 'succeeded');
select expect_num('two memberships now (pid1 + pid4)',
  (select count(*) from memberships where member_id='e40de40d-0000-0000-0000-00000000dd01'), 2);

-- =============================================================================
-- 11. The reconcile sweep: expires a stale pending, leaves a fresh one, and
--     refuses a signed-in user.
-- =============================================================================
-- A stale pending (created 3h ago) and a fresh pending (pid2 is still pending).
insert into xendit_purchases (id, studio_id, member_id, plan_id, amount_cents, currency, status, created_at) values
  ('e40de40d-0000-0000-0000-0000000a5701','e40de40d-0000-0000-0000-000000000001',
   'e40de40d-0000-0000-0000-00000000dd01','e40de40d-0000-0000-0000-0000000cc001',140000,'PHP','pending', now() - interval '3 hours');

select set_config('t.sweep', (xendit_reconcile_sweep(now()))->>'expired', false);
select expect_true('the sweep expired at least the stale pending', current_setting('t.sweep')::int >= 1);
select expect_text('the stale pending is expired', (select status from xendit_purchases where id='e40de40d-0000-0000-0000-0000000a5701'), 'expired');
select expect_text('a fresh pending (pid2) is left alone', (select status from xendit_purchases where id=current_setting('t.pid2')::uuid), 'pending');

-- a signed-in user cannot run the sweep
set role authenticated; select set_config('request.jwt.claim.sub','e40de40d-0000-0000-0000-000000000e01',false);
do $$ begin
  begin perform xendit_reconcile_sweep(now());
    perform set_config('t.sweep_user','no_raise',false);
  exception when others then perform set_config('t.sweep_user', sqlstate, false); end;
end $$;
select set_config('request.jwt.claim.sub','',false); reset role;
-- 42501 (no EXECUTE grant), the stronger boundary: the sweep is service_role
-- only, so a client is refused before the is_service_context() body guard runs.
select expect_text('a signed-in user cannot run the reconcile sweep (42501)', current_setting('t.sweep_user'), '42501');

-- =============================================================================
-- 12. member_bootstrap: xendit_enabled true, has_payment_provider stays false.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','e40de40d-0000-0000-0000-000000000e01',false);
select set_config('t.xen',  (select xendit_enabled::text from member_bootstrap('e40d-s')), false);
select set_config('t.hpp',  (select has_payment_provider::text from member_bootstrap('e40d-s')), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_true('member_bootstrap.xendit_enabled is true', current_setting('t.xen')::boolean);
select expect_true('has_payment_provider stays Stripe-specific (false here)', current_setting('t.hpp')::boolean is false);

-- =============================================================================
-- 13. Decision 40 amendment: expired is not final. A succeeded callback still
--     activates a purchase the local sweep marked expired, and the override is
--     recorded in audit_logs. A replay after that is still a duplicate.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','e40de40d-0000-0000-0000-000000000e01',false);
select set_config('t.pid5', (select purchase_id::text from xendit_begin_purchase(
  'e40de40d-0000-0000-0000-000000000001','e40de40d-0000-0000-0000-0000000cc001')), false);
select set_config('request.jwt.claim.sub','',false); reset role;
-- the local reconcile sweep marked it expired before the (late) callback arrives
update xendit_purchases set status='expired', completed_at=now() where id=current_setting('t.pid5')::uuid;

select set_config('t.ev_exp', jsonb_build_object(
  'event','payment.succeeded',
  'data', jsonb_build_object('reference_id', current_setting('t.pid5'),
     'payment_id','py-e40d-5','status','SUCCEEDED','amount',1400,'currency','PHP'))::text, false);
select set_config('t.r_exp', (xendit_webhook(current_setting('t.ev_exp')::jsonb, 'goodtoken'))->>'outcome', false);

select expect_text('a succeeded callback activates an EXPIRED purchase', current_setting('t.r_exp'), 'succeeded');
select expect_text('the expired purchase is now succeeded', (select status from xendit_purchases where id=current_setting('t.pid5')::uuid), 'succeeded');
select expect_num('the expiry override is recorded in audit_logs',
  (select count(*) from audit_logs where action='xendit.expiry_overridden' and entity_id=current_setting('t.pid5')::uuid), 1);
select set_config('t.r_exp2', (xendit_webhook(current_setting('t.ev_exp')::jsonb, 'goodtoken'))->>'result', false);
select expect_text('a replay after the override is still a duplicate', current_setting('t.r_exp2'), 'duplicate');

-- =============================================================================
-- 14. Decision 40 amendment 2: the callback never 500s on Xendit's "Test and
--     save" sample (non-UUID reference), and a cross-tenant reference is ignored.
-- =============================================================================
-- Studio B with a pending purchase (inserted directly — we only need a purchase
-- owned by a DIFFERENT studio than studio A's token).
insert into studios (id, name, slug, timezone, currency, status) values
  ('e40de40d-0000-0000-0000-000000000002','Xen B','e40d-sb','Asia/Manila','PHP','active');
insert into studio_settings (studio_id) values ('e40de40d-0000-0000-0000-000000000002');
insert into members (id, studio_id, first_name, last_name, email, status) values
  ('e40de40d-0000-0000-0000-00000000dd02','e40de40d-0000-0000-0000-000000000002','Bee','Two','mem2@example.com','active');
insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, validity_days, visibility, status) values
  ('e40de40d-0000-0000-0000-0000000cc0b2','e40de40d-0000-0000-0000-000000000002','B Pack','class_pack',140000,'PHP',10,30,'public','active');
insert into xendit_purchases (id, studio_id, member_id, plan_id, amount_cents, currency) values
  ('e40de40d-0000-0000-0000-0000000b2001','e40de40d-0000-0000-0000-000000000002','e40de40d-0000-0000-0000-00000000dd02','e40de40d-0000-0000-0000-0000000cc0b2',140000,'PHP');

-- (a) The EXACT hosted sample: non-UUID reference, IDR, sample_business_id, with
--     a VALID token. Must NOT raise (a 500 makes Xendit refuse the URL); ignored,
--     the event is stored, nothing activated.
select set_config('t.sample', '{"event":"payment.succeeded","business_id":"sample_business_id","data":{"reference_id":"a5151a05-e84d-4cef-bb17-1ref3e7fb3a","status":"SUCCEEDED","currency":"IDR"}}', false);
select set_config('t.memb_before', (select count(*) from memberships)::text, false);
select set_config('t.r_sample', (xendit_webhook(current_setting('t.sample')::jsonb, 'goodtoken'))->>'result', false);
select expect_text('the Xendit sample payload (non-UUID reference) is ignored, not a 500', current_setting('t.r_sample'), 'ignored');
select expect_num('...the sample event is stored (bad_reference)',
  (select count(*) from xendit_events where event_type='payment.succeeded' and error='bad_reference'), 1);
select expect_num('...and nothing was activated', (select count(*) from memberships), current_setting('t.memb_before')::bigint);

-- (b) Cross-tenant teeth: studio A's token + a VALID reference to studio B's
--     purchase -> ignored, B's purchase NOT activated.
select set_config('t.ev_xt', jsonb_build_object(
  'event','payment.succeeded',
  'data', jsonb_build_object('reference_id','e40de40d-0000-0000-0000-0000000b2001',
     'payment_id','py-crosstenant','status','SUCCEEDED','amount',1400,'currency','PHP'))::text, false);
select set_config('t.r_xt', (xendit_webhook(current_setting('t.ev_xt')::jsonb, 'goodtoken'))->>'reason', false);
select expect_text('a reference to ANOTHER studio''s purchase (this studio''s token) is cross_tenant', current_setting('t.r_xt'), 'cross_tenant');
select expect_text('...and studio B''s purchase is NOT activated (still pending)',
  (select status from xendit_purchases where id='e40de40d-0000-0000-0000-0000000b2001'), 'pending');
select expect_num('...no membership for studio B''s member',
  (select count(*) from memberships where member_id='e40de40d-0000-0000-0000-00000000dd02'), 0);

-- =============================================================================
-- 15. Decision 40 amendment 3: the event dedupe key includes the event TYPE, so
--     a payment.failure then a payment.succeeded for the SAME payment id are two
--     events, not a duplicate.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','e40de40d-0000-0000-0000-000000000e01',false);
select set_config('t.pid6', (select purchase_id::text from xendit_begin_purchase(
  'e40de40d-0000-0000-0000-000000000001','e40de40d-0000-0000-0000-0000000cc001')), false);
select set_config('request.jwt.claim.sub','',false); reset role;

select set_config('t.ev_f', jsonb_build_object('event','payment.failure',
  'data', jsonb_build_object('reference_id', current_setting('t.pid6'),
     'payment_id','py-dedupe','status','FAILED'))::text, false);
select set_config('t.ev_s', jsonb_build_object('event','payment.succeeded',
  'data', jsonb_build_object('reference_id', current_setting('t.pid6'),
     'payment_id','py-dedupe','status','SUCCEEDED','amount',1400,'currency','PHP'))::text, false);
select set_config('t.r_f', (xendit_webhook(current_setting('t.ev_f')::jsonb, 'goodtoken'))->>'outcome', false);
select set_config('t.r_s', (xendit_webhook(current_setting('t.ev_s')::jsonb, 'goodtoken'))->>'result', false);

select expect_text('the failure event is processed', current_setting('t.r_f'), 'failed');
select expect_text('a succeeded with the SAME payment id is NOT a duplicate (type is in the key)', current_setting('t.r_s'), 'processed');
select expect_num('...both are stored as distinct events',
  (select count(*) from xendit_events where payload->'data'->>'payment_id'='py-dedupe'), 2);

-- --- Teeth-of-teeth note ------------------------------------------------------
-- Reverting the token check in xendit_webhook fails "a wrong callback token
-- raises PT401"; removing the amount guard fails the mismatch assertions;
-- removing the manager-up guard on xendit_apply_session fails "a non-manager
-- cannot apply"; the sweep's service_role-only grant (belt: is_service_context)
-- is what refuses a signed-in user (42501).

select 'xendit_test: all assertions passed' as result;
