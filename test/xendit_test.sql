-- =============================================================================
-- Xendit adapter — Decision 40 Part A, migrations 20260831800000 / 20260831810000
-- =============================================================================
-- UUID space e40d, checked free (119 assertions). Run after `supabase db reset`.
--
-- Covers: a member cannot read the provider row (owner-only RLS); the anon
-- surface is EXACTLY thirteen, still naming xendit_webhook; begin_purchase snapshots the
-- amount from the plan, admits a recurring plan (one period, Decision 66) and
-- refuses a non-member; a callback
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
-- 2. Anon surface is EXACTLY thirteen, and xendit_webhook is one of them.
-- =============================================================================
select expect_num('anon surface is exactly thirteen',
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not like 'expect\_%'), 13);
select expect_true('xendit_webhook is anon-executable',
  has_function_privilege('anon', 'xendit_webhook(jsonb, text)'::regprocedure, 'execute'));

-- =============================================================================
-- 3. begin_purchase snapshots the amount from the plan; admits recurring (one
--    period, Decision 66); refuses a non-member.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','e40de40d-0000-0000-0000-000000000e01',false);
select set_config('t.pid1', (select purchase_id::text from xendit_begin_purchase(
  'e40de40d-0000-0000-0000-000000000001','e40de40d-0000-0000-0000-0000000cc001')), false);
select set_config('t.amt1', (select amount_cents::text from xendit_purchases where id=current_setting('t.pid1')::uuid), false);

-- Decision 66: a recurring plan is now admitted (bought one period at a time);
-- it begins a purchase at the plan's price, no renews_membership_id (this
-- member holds no membership on it yet).
select set_config('t.pidrec', (select purchase_id::text from xendit_begin_purchase(
  'e40de40d-0000-0000-0000-000000000001','e40de40d-0000-0000-0000-0000000cc002')), false);
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
-- Decision 66: a recurring plan is admitted as one period at the plan price,
-- with no renews_membership_id for a member who holds none yet.
select expect_num('a recurring plan begins at its price (one period, Decision 66)',
  (select amount_cents from xendit_purchases where id=current_setting('t.pidrec')::uuid)::bigint, 250000);
select expect_text('the recurring begin stamps no renews_membership_id',
  coalesce((select renews_membership_id::text from xendit_purchases where id=current_setting('t.pidrec')::uuid),'null'), 'null');
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
-- 9. A reference that resolves to no purchase (valid UUID, none of the three
--    resolution paths match) is ignored as bad_reference — and STORED (after the
--    token is verified every event is recorded, even an ignored one).
-- =============================================================================
select set_config('t.ev_unk', jsonb_build_object(
  'event','payment.succeeded',
  'data', jsonb_build_object('reference_id','e40de40d-0000-0000-0000-0000deadbeef',
     'payment_id','py-unknown','status','SUCCEEDED'))::text, false);
select set_config('t.events_before', (select count(*) from xendit_events)::text, false);
select set_config('t.r_unk', (xendit_webhook(current_setting('t.ev_unk')::jsonb, 'goodtoken'))->>'reason', false);
select expect_text('a reference that resolves to no purchase is ignored (bad_reference)', current_setting('t.r_unk'), 'bad_reference');
select expect_num('...and the event IS stored (token was valid), marked ignored',
  (select count(*) from xendit_events), current_setting('t.events_before')::bigint + 1);
select expect_text('...the stored event carries the reason', (select error from xendit_events where payload->'data'->>'payment_id'='py-unknown'), 'bad_reference');

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
  (select count(*) from xendit_events where error='bad_reference' and payload->>'business_id'='sample_business_id'), 1);
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

-- =============================================================================
-- 16. Decision 40 amendment 4: resolve the purchase from metadata.purchase_id /
--     the session id / a suffixed reference_id, and reprocess stored ignored
--     events. (Xendit appends a suffix to the payment's reference_id.)
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','e40de40d-0000-0000-0000-000000000e01',false);
select set_config('t.pid7', (select purchase_id::text from xendit_begin_purchase(
  'e40de40d-0000-0000-0000-000000000001','e40de40d-0000-0000-0000-0000000cc001')), false);
select set_config('t.pid8', (select purchase_id::text from xendit_begin_purchase(
  'e40de40d-0000-0000-0000-000000000001','e40de40d-0000-0000-0000-0000000cc001')), false);
select set_config('request.jwt.claim.sub','',false); reset role;

-- (a) a suffixed reference_id "<uuid>_SUFFIX" resolves and activates.
select set_config('t.ev_suf', jsonb_build_object('event','payment.succeeded',
  'data', jsonb_build_object('reference_id', current_setting('t.pid7')||'_INzvmwJabc',
     'payment_id','py-suffix','status','SUCCEEDED','amount',1400,'currency','PHP'))::text, false);
select set_config('t.r_suf', (xendit_webhook(current_setting('t.ev_suf')::jsonb, 'goodtoken'))->>'outcome', false);
select expect_text('a suffixed reference_id (<uuid>_SUFFIX) resolves and activates', current_setting('t.r_suf'), 'succeeded');
select expect_text('...the suffixed purchase is succeeded', (select status from xendit_purchases where id=current_setting('t.pid7')::uuid), 'succeeded');

-- (b) metadata.purchase_id resolves even when reference_id is unusable.
select set_config('t.ev_meta', jsonb_build_object('event','payment.succeeded',
  'data', jsonb_build_object('reference_id','totally-not-a-uuid',
     'metadata', jsonb_build_object('purchase_id', current_setting('t.pid8')),
     'payment_id','py-meta','status','SUCCEEDED','amount',1400,'currency','PHP'))::text, false);
select set_config('t.r_meta', (xendit_webhook(current_setting('t.ev_meta')::jsonb, 'goodtoken'))->>'outcome', false);
select expect_text('metadata.purchase_id resolves even with a bad reference_id', current_setting('t.r_meta'), 'succeeded');
select expect_text('...the metadata purchase is succeeded', (select status from xendit_purchases where id=current_setting('t.pid8')::uuid), 'succeeded');

-- (c) reprocess a STORED ignored event -> activates a pending purchase, idempotent.
set role authenticated; select set_config('request.jwt.claim.sub','e40de40d-0000-0000-0000-000000000e01',false);
select set_config('t.pid9', (select purchase_id::text from xendit_begin_purchase(
  'e40de40d-0000-0000-0000-000000000001','e40de40d-0000-0000-0000-0000000cc001')), false);
select set_config('request.jwt.claim.sub','',false); reset role;
insert into xendit_events (studio_id, event_id, event_type, payload, error) values
  ('e40de40d-0000-0000-0000-000000000001','payment.succeeded:py-stored','payment.succeeded',
   jsonb_build_object('event','payment.succeeded','data', jsonb_build_object(
     'reference_id', current_setting('t.pid9')||'_LATE','payment_id','py-stored',
     'status','SUCCEEDED','amount',1400,'currency','PHP')), 'bad_reference');
set role authenticated; select set_config('request.jwt.claim.sub','e40de40d-0000-0000-0000-0000000000a1',false);
select set_config('t.rep1', (xendit_reprocess_ignored('e40de40d-0000-0000-0000-000000000001'))->>'reprocessed', false);
select set_config('t.rep2', (xendit_reprocess_ignored('e40de40d-0000-0000-0000-000000000001'))->>'reprocessed', false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_true('reprocessing a stored ignored event recovers at least one', current_setting('t.rep1')::int >= 1);
select expect_text('...the recovered purchase is succeeded', (select status from xendit_purchases where id=current_setting('t.pid9')::uuid), 'succeeded');
select expect_num('...a second reprocess is idempotent (nothing left)', current_setting('t.rep2')::bigint, 0);
-- a non-manager cannot reprocess
set role authenticated; select set_config('request.jwt.claim.sub','e40de40d-0000-0000-0000-000000000e01',false);
do $$ begin
  begin perform xendit_reprocess_ignored('e40de40d-0000-0000-0000-000000000001');
    perform set_config('t.rep_m','no_raise',false);
  exception when others then perform set_config('t.rep_m', sqlstate, false); end;
end $$;
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('a non-manager cannot reprocess ignored events (PT403)', current_setting('t.rep_m'), 'PT403');

-- =============================================================================
-- 17. Decision 40 amendment 5: the real checkout callback is
--     payment_session.completed with status COMPLETED (amount 8500 PHP, no
--     data.id, metadata without purchase_id) — it activates; a later
--     payment.succeeded for the same purchase cannot double-activate.
-- =============================================================================
insert into members (id, studio_id, first_name, last_name, email, status) values
  ('e40de40d-0000-0000-0000-00000000dd03','e40de40d-0000-0000-0000-000000000001','Cee','Three','mem3@example.com','active');
-- a pending PHP 8,500 purchase (850000 centavos) with a stored session id, as
-- the buy action would have left it. amount_cents set directly for the 8500 case.
insert into xendit_purchases (id, studio_id, member_id, plan_id, amount_cents, currency, payment_session_id) values
  ('e40de40d-0000-0000-0000-0000000c5c01','e40de40d-0000-0000-0000-000000000001','e40de40d-0000-0000-0000-00000000dd03','e40de40d-0000-0000-0000-0000000cc001',850000,'PHP','ps-testsession');

-- the exact payment_session.completed shape (no data.id, metadata without purchase_id)
select set_config('t.ev_psc', jsonb_build_object(
  'event','payment_session.completed',
  'data', jsonb_build_object(
    'session_type','PAY','status','COMPLETED','amount',8500,'currency','PHP',
    'reference_id','e40de40d-0000-0000-0000-0000000c5c01',
    'payment_id','py-psc','payment_session_id','ps-testsession',
    'metadata', jsonb_build_object('kind','plan','plan_id','e40de40d-0000-0000-0000-0000000cc001',
      'member_id','e40de40d-0000-0000-0000-00000000dd03','studio_id','e40de40d-0000-0000-0000-000000000001')))::text, false);
select set_config('t.r_psc', (xendit_webhook(current_setting('t.ev_psc')::jsonb, 'goodtoken'))->>'outcome', false);

select expect_text('payment_session.completed (COMPLETED) activates the purchase', current_setting('t.r_psc'), 'succeeded');
select expect_text('...the purchase is succeeded', (select status from xendit_purchases where id='e40de40d-0000-0000-0000-0000000c5c01'), 'succeeded');
select expect_num('...one xendit payment row referencing the payment_id', (select count(*) from payments where provider='xendit' and reference='py-psc'), 1);
select expect_num('...the PHP 8,500 amount is recorded (850000 centavos)', (select amount_cents from payments where provider='xendit' and reference='py-psc'), 850000);

-- a later payment.succeeded (Payment Requests row, suffixed reference, same
-- payment id) is a distinct event but cannot double-activate.
select set_config('t.ev_late2', jsonb_build_object('event','payment.succeeded',
  'data', jsonb_build_object('reference_id','e40de40d-0000-0000-0000-0000000c5c01_LATE',
     'payment_id','py-psc','status','SUCCEEDED','amount',8500,'currency','PHP'))::text, false);
select set_config('t.r_late2', (xendit_webhook(current_setting('t.ev_late2')::jsonb, 'goodtoken'))->>'result', false);
select expect_text('a later payment.succeeded is processed (distinct event)', current_setting('t.r_late2'), 'processed');
select expect_num('...but does NOT add a second payment row (no double-activation)', (select count(*) from payments where provider='xendit' and reference='py-psc'), 1);

-- =============================================================================
-- 18. Decision 40 amendment 6: the Xendit customer id is stored per member (a
--     reference_id creates a customer only once) and is RLS-scoped.
-- =============================================================================
-- another studio's stored customer, to prove isolation (studio B from §14, dd02)
insert into member_payment_customers (studio_id, member_id, provider, customer_ref) values
  ('e40de40d-0000-0000-0000-000000000002','e40de40d-0000-0000-0000-00000000dd02','xendit','cust-studioB');

set role authenticated; select set_config('request.jwt.claim.sub','e40de40d-0000-0000-0000-000000000e01',false);
select xendit_set_customer('e40de40d-0000-0000-0000-000000000001','cust-e40d-first');
select set_config('t.cust1', (select customer_ref from member_payment_customers where member_id='e40de40d-0000-0000-0000-00000000dd01' and provider='xendit'), false);
-- a second set upserts (still one row, ref updated)
select xendit_set_customer('e40de40d-0000-0000-0000-000000000001','cust-e40d-second');
select set_config('t.cust2', (select customer_ref from member_payment_customers where member_id='e40de40d-0000-0000-0000-00000000dd01' and provider='xendit'), false);
select set_config('t.own_rows', (select count(*)::text from member_payment_customers where member_id='e40de40d-0000-0000-0000-00000000dd01'), false);
-- the member sees ONLY their own row (not studio B's dd02)
select set_config('t.member_visible', (select count(*)::text from member_payment_customers), false);
select set_config('request.jwt.claim.sub','',false); reset role;

-- desk-up staff of studio A see studio A's row, not studio B's
set role authenticated; select set_config('request.jwt.claim.sub','e40de40d-0000-0000-0000-0000000000a1',false);
select set_config('t.staff_visible', (select count(*)::text from member_payment_customers), false);
-- a non-member cannot store a customer id
do $$ begin
  begin perform xendit_set_customer('e40de40d-0000-0000-0000-000000000001','cust-hax');
    perform set_config('t.set_nonmember','no_raise',false);
  exception when others then perform set_config('t.set_nonmember', sqlstate, false); end;
end $$;
select set_config('request.jwt.claim.sub','',false); reset role;

select expect_text('xendit_set_customer stores the customer id', current_setting('t.cust1'), 'cust-e40d-first');
select expect_text('...a second set upserts the ref', current_setting('t.cust2'), 'cust-e40d-second');
select expect_num('...leaving exactly one row', current_setting('t.own_rows')::bigint, 1);
select expect_num('a member sees ONLY their own customer row (not another studio''s)', current_setting('t.member_visible')::bigint, 1);
select expect_num('desk-up staff see their studio''s row only', current_setting('t.staff_visible')::bigint, 1);
-- the owner a1 is manager-up of studio A only, so is_desk_up(A) true, is_desk_up(B) false — but xendit_set_customer as a NON-member of A is refused
select expect_text('a non-member cannot store a customer id (PT403)', current_setting('t.set_nonmember'), 'PT403');

-- =============================================================================
-- 19. Decision 40 amendment 7: the v3 "Payment Status" shape. event
--     payment.capture, status SUCCEEDED, amount in data.request_amount (and
--     data.captures[].capture_amount, NO data.amount), reference in
--     data.payment_id (NO data.id). And "Payment Request Status" —
--     payment_request.expiry with status EXPIRED — for an already-succeeded
--     purchase changes nothing.
-- =============================================================================
-- four pending PHP 8,500 purchases (850000 centavos), as the buy action leaves them
insert into xendit_purchases (id, studio_id, member_id, plan_id, amount_cents, currency) values
  ('e40de40d-0000-0000-0000-0000000ca301','e40de40d-0000-0000-0000-000000000001','e40de40d-0000-0000-0000-00000000dd03','e40de40d-0000-0000-0000-0000000cc001',850000,'PHP'),
  ('e40de40d-0000-0000-0000-0000000ca302','e40de40d-0000-0000-0000-000000000001','e40de40d-0000-0000-0000-00000000dd03','e40de40d-0000-0000-0000-0000000cc001',850000,'PHP'),
  ('e40de40d-0000-0000-0000-0000000ca303','e40de40d-0000-0000-0000-000000000001','e40de40d-0000-0000-0000-00000000dd03','e40de40d-0000-0000-0000-0000000cc001',850000,'PHP'),
  ('e40de40d-0000-0000-0000-0000000ca304','e40de40d-0000-0000-0000-000000000001','e40de40d-0000-0000-0000-00000000dd03','e40de40d-0000-0000-0000-0000000cc001',850000,'PHP');

-- (a) the EXACT v3 payment.capture SUCCEEDED shape (request_amount, captures,
--     payment_id, no data.amount, no data.id) → activates and validates the amount.
select set_config('t.ev_v3a', jsonb_build_object(
  'api_version','v3','event','payment.capture',
  'data', jsonb_build_object(
    'payment_id','py-v3a','status','SUCCEEDED',
    'request_amount', 8500,
    'captures', jsonb_build_array(jsonb_build_object('capture_amount', 8500)),
    'reference_id','e40de40d-0000-0000-0000-0000000ca301',
    'payment_request_id','pr-v3a','customer_id','cust-v3a','currency','PHP'))::text, false);
select set_config('t.r_v3a', (xendit_webhook(current_setting('t.ev_v3a')::jsonb, 'goodtoken'))->>'outcome', false);
select expect_text('v3 payment.capture SUCCEEDED (request_amount 8500) activates a pending purchase', current_setting('t.r_v3a'), 'succeeded');
select expect_text('...the purchase is succeeded', (select status from xendit_purchases where id='e40de40d-0000-0000-0000-0000000ca301'), 'succeeded');
select expect_num('...the payments row references data.payment_id (py-v3a) at 850000', (select amount_cents from payments where provider='xendit' and reference='py-v3a'), 850000);

-- (b) the amount IS read from request_amount — a wrong request_amount is caught
--     (before the fix v_amount was null and the check was skipped → wrongly activated).
select set_config('t.ev_v3b', jsonb_build_object(
  'api_version','v3','event','payment.capture',
  'data', jsonb_build_object(
    'payment_id','py-v3b','status','SUCCEEDED','request_amount', 9999,
    'reference_id','e40de40d-0000-0000-0000-0000000ca302','currency','PHP'))::text, false);
select set_config('t.r_v3b', (xendit_webhook(current_setting('t.ev_v3b')::jsonb, 'goodtoken'))->>'reason', false);
select expect_text('a v3 request_amount mismatch is refused (amount is read, not skipped)', current_setting('t.r_v3b'), 'amount_mismatch');
select expect_text('...the mismatched purchase is still pending', (select status from xendit_purchases where id='e40de40d-0000-0000-0000-0000000ca302'), 'pending');

-- (c) captures[0].capture_amount is the third amount source (no amount, no request_amount).
select set_config('t.ev_v3c', jsonb_build_object(
  'api_version','v3','event','payment.capture',
  'data', jsonb_build_object(
    'payment_id','py-v3c','status','SUCCEEDED',
    'captures', jsonb_build_array(jsonb_build_object('capture_amount', 8500)),
    'reference_id','e40de40d-0000-0000-0000-0000000ca303','currency','PHP'))::text, false);
select set_config('t.r_v3c', (xendit_webhook(current_setting('t.ev_v3c')::jsonb, 'goodtoken'))->>'outcome', false);
select expect_text('captures[0].capture_amount is the third amount source → activates', current_setting('t.r_v3c'), 'succeeded');

-- (d) the payment reference falls back to data.id when there is no data.payment_id.
select set_config('t.ev_v3d', jsonb_build_object('event','payment.succeeded',
  'data', jsonb_build_object('id','py-legacy','status','SUCCEEDED','amount', 8500,
    'reference_id','e40de40d-0000-0000-0000-0000000ca304','currency','PHP'))::text, false);
select set_config('t.r_v3d', (xendit_webhook(current_setting('t.ev_v3d')::jsonb, 'goodtoken'))->>'outcome', false);
select expect_text('the payment reference falls back to data.id (no payment_id) → activates', current_setting('t.r_v3d'), 'succeeded');
select expect_num('...the payments row references data.id (py-legacy)', (select count(*) from payments where provider='xendit' and reference='py-legacy'), 1);

-- (e) a payment_request.expiry (EXPIRED) for an ALREADY-SUCCEEDED purchase (ca301)
--     changes nothing — fail_internal returns early on a succeeded purchase.
select set_config('t.memb_dd03', (select count(*)::text from memberships where member_id='e40de40d-0000-0000-0000-00000000dd03'), false);
select set_config('t.ev_exp3', jsonb_build_object(
  'api_version','v3','event','payment_request.expiry',
  'data', jsonb_build_object(
    'payment_request_id','pr-v3a','status','EXPIRED','request_amount', 8500,
    'reference_id','e40de40d-0000-0000-0000-0000000ca301','currency','PHP'))::text, false);
select set_config('t.r_exp3', (xendit_webhook(current_setting('t.ev_exp3')::jsonb, 'goodtoken'))->>'outcome', false);
select expect_text('payment_request.expiry on a succeeded purchase is processed', current_setting('t.r_exp3'), 'failed');
select expect_text('...but the purchase stays succeeded (no-op)', (select status from xendit_purchases where id='e40de40d-0000-0000-0000-0000000ca301'), 'succeeded');
select expect_num('...no membership was removed or added', (select count(*) from memberships where member_id='e40de40d-0000-0000-0000-00000000dd03'), current_setting('t.memb_dd03')::bigint);
select expect_num('...the payments row for py-v3a still stands', (select count(*) from payments where provider='xendit' and reference='py-v3a'), 1);

-- =============================================================================
-- 20. Decision 40 amendment 8: confirm on return (the belt). The member's poll
--     page asks Xendit directly and applies COMPLETED through a member-guarded
--     path (xendit_return_check_claim + xendit_return_check_apply). The Xendit
--     GET is mocked here — the tests pass the session status the action would
--     have read straight to _apply.
-- =============================================================================
-- four pending PHP 1,400 purchases for dd01 (own) and one for dd03 (another member)
insert into xendit_purchases (id, studio_id, member_id, plan_id, amount_cents, currency, payment_session_id) values
  ('e40de40d-0000-0000-0000-0000000cb301','e40de40d-0000-0000-0000-000000000001','e40de40d-0000-0000-0000-00000000dd01','e40de40d-0000-0000-0000-0000000cc001',140000,'PHP','ps-ret1'),
  ('e40de40d-0000-0000-0000-0000000cb302','e40de40d-0000-0000-0000-000000000001','e40de40d-0000-0000-0000-00000000dd01','e40de40d-0000-0000-0000-0000000cc001',140000,'PHP','ps-ret3'),
  ('e40de40d-0000-0000-0000-0000000cb303','e40de40d-0000-0000-0000-000000000001','e40de40d-0000-0000-0000-00000000dd01','e40de40d-0000-0000-0000-0000000cc001',140000,'PHP','ps-ret4'),
  ('e40de40d-0000-0000-0000-0000000cb304','e40de40d-0000-0000-0000-000000000001','e40de40d-0000-0000-0000-00000000dd03','e40de40d-0000-0000-0000-0000000cc001',140000,'PHP','ps-ret2');

set role authenticated; select set_config('request.jwt.claim.sub','e40de40d-0000-0000-0000-000000000e01',false);
select set_config('t.memb_pre', (select count(*)::text from memberships where member_id='e40de40d-0000-0000-0000-00000000dd01'), false);

-- (a) own pending purchase, COMPLETED session → activated, pack granted, audit 'return_check'.
select set_config('t.rc_claim', (xendit_return_check_claim('e40de40d-0000-0000-0000-0000000cb301'))->>'check', false);
select set_config('t.rc_apply', (xendit_return_check_apply('e40de40d-0000-0000-0000-0000000cb301','COMPLETED','py-ret1'))->>'outcome', false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('the member claims a return-check on their own pending purchase', current_setting('t.rc_claim'), 'true');
select expect_text('a COMPLETED session activates via the return-check path', current_setting('t.rc_apply'), 'succeeded');
select expect_text('...the purchase is succeeded', (select status from xendit_purchases where id='e40de40d-0000-0000-0000-0000000cb301'), 'succeeded');
select expect_num('...a membership was granted (dd01 +1)', (select count(*) from memberships where member_id='e40de40d-0000-0000-0000-00000000dd01'), current_setting('t.memb_pre')::bigint + 1);
select expect_num('...the payments row references the payment id (py-ret1)', (select count(*) from payments where provider='xendit' and reference='py-ret1'), 1);
select expect_num('...an audit_logs xendit.return_check row was written', (select count(*) from audit_logs where action='xendit.return_check' and entity_id='e40de40d-0000-0000-0000-0000000cb301'), 1);

-- (b) another member's purchase → PT403 from both claim and apply.
set role authenticated; select set_config('request.jwt.claim.sub','e40de40d-0000-0000-0000-000000000e01',false);
do $$ begin
  begin perform xendit_return_check_claim('e40de40d-0000-0000-0000-0000000cb304');
    perform set_config('t.rc_other_claim','no_raise',false);
  exception when others then perform set_config('t.rc_other_claim', sqlstate, false); end;
end $$;
do $$ begin
  begin perform xendit_return_check_apply('e40de40d-0000-0000-0000-0000000cb304','COMPLETED','py-hax');
    perform set_config('t.rc_other_apply','no_raise',false);
  exception when others then perform set_config('t.rc_other_apply', sqlstate, false); end;
end $$;
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('a member cannot claim another member''s purchase (PT403)', current_setting('t.rc_other_claim'), 'PT403');
select expect_text('a member cannot apply another member''s purchase (PT403)', current_setting('t.rc_other_apply'), 'PT403');
select expect_text('...the other member''s purchase is untouched (still pending)', (select status from xendit_purchases where id='e40de40d-0000-0000-0000-0000000cb304'), 'pending');

-- (c) already succeeded → no-op (no second membership, no second payment, no second audit row).
set role authenticated; select set_config('request.jwt.claim.sub','e40de40d-0000-0000-0000-000000000e01',false);
select set_config('t.memb_mid', (select count(*)::text from memberships where member_id='e40de40d-0000-0000-0000-00000000dd01'), false);
select set_config('t.rc_again', (xendit_return_check_apply('e40de40d-0000-0000-0000-0000000cb301','COMPLETED','py-again'))->>'outcome', false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('applying a COMPLETED session to an already-succeeded purchase is a no-op success', current_setting('t.rc_again'), 'succeeded');
select expect_num('...no second membership', (select count(*) from memberships where member_id='e40de40d-0000-0000-0000-00000000dd01'), current_setting('t.memb_mid')::bigint);
select expect_num('...no second payments row (py-again absent)', (select count(*) from payments where provider='xendit' and reference='py-again'), 0);
select expect_num('...no second audit row', (select count(*) from audit_logs where action='xendit.return_check' and entity_id='e40de40d-0000-0000-0000-0000000cb301'), 1);

-- (d) EXPIRED session → the purchase is marked expired.
set role authenticated; select set_config('request.jwt.claim.sub','e40de40d-0000-0000-0000-000000000e01',false);
select set_config('t.rc_exp', (xendit_return_check_apply('e40de40d-0000-0000-0000-0000000cb302','EXPIRED',null))->>'outcome', false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('an EXPIRED session is applied as expired', current_setting('t.rc_exp'), 'expired');
select expect_text('...the purchase is marked expired', (select status from xendit_purchases where id='e40de40d-0000-0000-0000-0000000cb302'), 'expired');

-- (e) rate limit: a second claim within 5s is throttled; a claim 6s later is allowed.
set role authenticated; select set_config('request.jwt.claim.sub','e40de40d-0000-0000-0000-000000000e01',false);
select set_config('t.rc_l1', (xendit_return_check_claim('e40de40d-0000-0000-0000-0000000cb303'))->>'check', false);
select set_config('t.rc_l2', (xendit_return_check_claim('e40de40d-0000-0000-0000-0000000cb303'))->>'throttled', false);
select set_config('t.rc_l3', (xendit_return_check_claim('e40de40d-0000-0000-0000-0000000cb303', now() + interval '6 seconds'))->>'check', false);
-- a terminal purchase comes back check=false with its status
select set_config('t.rc_done', (xendit_return_check_claim('e40de40d-0000-0000-0000-0000000cb301'))->>'status', false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('the first claim is allowed', current_setting('t.rc_l1'), 'true');
select expect_text('a second claim within 5s is throttled', current_setting('t.rc_l2'), 'true');
select expect_text('a claim 6s later is allowed again', current_setting('t.rc_l3'), 'true');
select expect_text('a claim on a terminal purchase reports its status, not a check', current_setting('t.rc_done'), 'succeeded');

-- =============================================================================
-- 21. Decision 40 amendment 9: the return-check records its outcome so a stuck
--     purchase says why (last_return_check_result), and the note is member-guarded.
-- =============================================================================
insert into xendit_purchases (id, studio_id, member_id, plan_id, amount_cents, currency, payment_session_id) values
  ('e40de40d-0000-0000-0000-0000000cb601','e40de40d-0000-0000-0000-000000000001','e40de40d-0000-0000-0000-00000000dd01','e40de40d-0000-0000-0000-0000000cc001',140000,'PHP','ps-res1'),
  ('e40de40d-0000-0000-0000-0000000cb602','e40de40d-0000-0000-0000-000000000001','e40de40d-0000-0000-0000-00000000dd01','e40de40d-0000-0000-0000-0000000cc001',140000,'PHP','ps-res2');

set role authenticated; select set_config('request.jwt.claim.sub','e40de40d-0000-0000-0000-000000000e01',false);
select xendit_return_check_claim('e40de40d-0000-0000-0000-0000000cb601');
select set_config('t.res_claim', (select last_return_check_result from xendit_purchases where id='e40de40d-0000-0000-0000-0000000cb601'), false);
select xendit_return_check_apply('e40de40d-0000-0000-0000-0000000cb601','COMPLETED','py-res1');
select set_config('t.res_apply', (select last_return_check_result from xendit_purchases where id='e40de40d-0000-0000-0000-0000000cb601'), false);
-- the action records a failure reason for its own purchase
select xendit_return_check_note('e40de40d-0000-0000-0000-0000000cb602','get_failed:0');
select set_config('t.res_note', (select last_return_check_result from xendit_purchases where id='e40de40d-0000-0000-0000-0000000cb602'), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('claim stamps last_return_check_result = checking', current_setting('t.res_claim'), 'checking');
select expect_text('apply records the completed outcome', current_setting('t.res_apply'), 'completed');
select expect_text('note records a failure reason', current_setting('t.res_note'), 'get_failed:0');

-- another member cannot note (dd01's purchase, caller e02 who is not that member)
set role authenticated; select set_config('request.jwt.claim.sub','e40de40d-0000-0000-0000-000000000e02',false);
do $$ begin
  begin perform xendit_return_check_note('e40de40d-0000-0000-0000-0000000cb602','hax');
    perform set_config('t.note_other','no_raise',false);
  exception when others then perform set_config('t.note_other', sqlstate, false); end;
end $$;
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('a member cannot note another member''s purchase (PT403)', current_setting('t.note_other'), 'PT403');
select expect_text('...and the note is unchanged', (select last_return_check_result from xendit_purchases where id='e40de40d-0000-0000-0000-0000000cb602'), 'get_failed:0');

-- =============================================================================
-- 22. Decision 40 amendment 9 ROOT CAUSE: activation must NOT raise PT403 when
--     the conversion bonus is on and the caller is NOT service-context (the anon
--     webhook, the member belt). award_conversion_bonus_run must call the
--     UNGUARDED member_first_class_run — reverting it to member_first_class makes
--     this section fail with cv_state = 'PT403' (the exact production 500).
-- =============================================================================
update studio_settings set conversion_bonus_enabled = true, conversion_bonus_cents = 50000,
       conversion_window_days = 30 where studio_id = 'e40de40d-0000-0000-0000-000000000001';
update membership_plans set counts_for_conversion = true where id = 'e40de40d-0000-0000-0000-0000000cc001';
insert into xendit_purchases (id, studio_id, member_id, plan_id, amount_cents, currency, payment_session_id) values
  ('e40de40d-0000-0000-0000-0000000cb701','e40de40d-0000-0000-0000-000000000001','e40de40d-0000-0000-0000-00000000dd01','e40de40d-0000-0000-0000-0000000cc001',140000,'PHP','ps-cv1');

set role anon;
do $$ declare r jsonb; begin
  begin
    r := xendit_webhook(jsonb_build_object('event','payment.succeeded',
      'data', jsonb_build_object('reference_id','e40de40d-0000-0000-0000-0000000cb701',
        'status','SUCCEEDED','amount',1400,'currency','PHP','payment_id','py-cv1')), 'goodtoken');
    perform set_config('t.cv_result', r->>'result', false);
    perform set_config('t.cv_state', 'ok', false);
  exception when others then
    perform set_config('t.cv_state', sqlstate, false);
  end;
end $$;
reset role;
select expect_text('an anon webhook with the conversion bonus ON does NOT raise PT403', current_setting('t.cv_state'), 'ok');
select expect_text('...the callback is processed', current_setting('t.cv_result'), 'processed');
select expect_text('...the purchase is succeeded', (select status from xendit_purchases where id='e40de40d-0000-0000-0000-0000000cb701'), 'succeeded');
select expect_num('...the pack was granted (payments row py-cv1)', (select count(*) from payments where provider='xendit' and reference='py-cv1'), 1);

-- =============================================================================
-- 23. Store the event BEFORE processing (migration 187): a processing FAILURE
--     leaves a stored row with result='failed' + the error, and re-sending the
--     same event reprocesses it (not a duplicate) and flips it to processed. A
--     test-only BEFORE INSERT trigger on payments forces the activation to raise.
-- =============================================================================
create function e40d_boom() returns trigger language plpgsql as $$
begin
  if new.reference = 'py-boom' then raise exception 'boom (forced test failure)' using errcode = 'P0001'; end if;
  return new;
end $$;
create trigger e40d_boom_trg before insert on payments for each row execute function e40d_boom();

insert into xendit_purchases (id, studio_id, member_id, plan_id, amount_cents, currency) values
  ('e40de40d-0000-0000-0000-0000000cb801','e40de40d-0000-0000-0000-000000000001','e40de40d-0000-0000-0000-00000000dd01','e40de40d-0000-0000-0000-0000000cc001',140000,'PHP');
select set_config('t.ev_boom', jsonb_build_object('event','payment.succeeded',
  'data', jsonb_build_object('reference_id','e40de40d-0000-0000-0000-0000000cb801',
    'status','SUCCEEDED','amount',1400,'currency','PHP','payment_id','py-boom'))::text, false);
select set_config('t.boom1', (xendit_webhook(current_setting('t.ev_boom')::jsonb, 'goodtoken'))->>'result', false);
select expect_text('a processing failure returns result=failed (not a raise)', current_setting('t.boom1'), 'failed');
select expect_text('...the event row is STORED with result=failed', (select result from xendit_events where event_id='payment.succeeded:py-boom'), 'failed');
select expect_true('...with the error text captured', (select error is not null and length(error) > 0 from xendit_events where event_id='payment.succeeded:py-boom'));
select expect_text('...the purchase is still pending (activation rolled back)', (select status from xendit_purchases where id='e40de40d-0000-0000-0000-0000000cb801'), 'pending');
select expect_num('...and no payments row was left behind', (select count(*) from payments where reference='py-boom'), 0);

-- clear the forced failure and re-send the SAME event: reprocessed, not duplicate.
drop trigger e40d_boom_trg on payments;
select set_config('t.boom2', (xendit_webhook(current_setting('t.ev_boom')::jsonb, 'goodtoken'))->>'result', false);
select expect_text('re-sending a failed event reprocesses it (not a duplicate)', current_setting('t.boom2'), 'processed');
select expect_text('...the stored row flips to result=processed', (select result from xendit_events where event_id='payment.succeeded:py-boom'), 'processed');
select expect_text('...the purchase is now succeeded', (select status from xendit_purchases where id='e40de40d-0000-0000-0000-0000000cb801'), 'succeeded');
select expect_num('...and the payments row now exists', (select count(*) from payments where reference='py-boom'), 1);
-- a PROCESSED event re-sent again is a duplicate (only 'failed' rows reprocess).
select set_config('t.boom3', (xendit_webhook(current_setting('t.ev_boom')::jsonb, 'goodtoken'))->>'result', false);
select expect_text('a processed event re-sent is a duplicate', current_setting('t.boom3'), 'duplicate');
drop function e40d_boom();

-- --- Teeth-of-teeth note ------------------------------------------------------
-- Reverting the token check in xendit_webhook fails "a wrong callback token
-- raises PT401"; removing the amount guard fails the mismatch assertions;
-- reverting v_amount to read only data.amount fails "a v3 request_amount mismatch
-- is refused" (the check would be skipped and the purchase wrongly activated);
-- removing the manager-up guard on xendit_apply_session fails "a non-manager
-- cannot apply"; the sweep's service_role-only grant (belt: is_service_context)
-- is what refuses a signed-in user (42501). Removing the member-ownership guard
-- on xendit_return_check_claim/_apply fails the PT403 assertions in §20; dropping
-- the early return on 'succeeded' in _apply fails "no second membership".
-- Reverting award_conversion_bonus_run to call the GUARDED member_first_class
-- makes §22 fail with cv_state = 'PT403' — the exact production 500.

select 'xendit_test: all assertions passed' as result;
