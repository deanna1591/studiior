-- =============================================================================
-- Decision 66 — recurring plans online, one period at a time.
-- UUID space: 5e66.  Xendit token = 'goodtoken'.
-- =============================================================================
\set S  '''5e665e66-0000-0000-0000-000000000001'''
\set PR '''5e665e66-0000-0000-0000-0000000000a1'''
\set M1 '''5e665e66-0000-0000-0000-00000000c001'''
\set M2 '''5e665e66-0000-0000-0000-00000000c002'''

create or replace function expect_true(label text, actual boolean) returns void language plpgsql as $$
begin if coalesce(actual,false) then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_num(label text, actual bigint, want bigint) returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (%)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_text(label text, actual text, want text) returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (%)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if; end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('5e665e66-0000-0000-0000-00000000c001'),
  ('5e665e66-0000-0000-0000-00000000c002');
insert into profiles (id, email) values
  ('5e665e66-0000-0000-0000-00000000c001','5e66-m1@example.com'),
  ('5e665e66-0000-0000-0000-00000000c002','5e66-m2@example.com');
insert into studios (id, name, slug, timezone, currency, status)
  values (:S,'Period Studio','period-studio','Europe/Prague','CZK','active');
insert into studio_settings (studio_id) values (:S);
insert into members (id, studio_id, first_name, last_name, email, status, user_id) values
  (:M1,:S,'Ria','One','5e66-m1@example.com','active','5e665e66-0000-0000-0000-00000000c001'),
  (:M2,:S,'Bea','Two','5e66-m2@example.com','active','5e665e66-0000-0000-0000-00000000c002');

-- A recurring plan: monthly, 30 classes a period, CZK 5,000.
insert into membership_plans (id, studio_id, name, type, price_cents, currency, visibility, status,
                              billing_interval, billing_interval_count, credits_per_period)
  values (:PR,:S,'Unlimited Monthly','recurring',500000,'CZK','public','active','month',1,30);

insert into studio_payment_providers
  (studio_id, provider, secret_key_ciphertext, callback_token_ciphertext, callback_token_sha256,
   key_last4, test_mode, connected_by) values
  (:S,'xendit','v1.opaque','v1.opaque', encode(digest('goodtoken','sha256'),'hex'),'tok0', true,'5e665e66-0000-0000-0000-00000000c001');

select set_config('t.s', :S, false);
select set_config('t.pr', :PR, false);

-- helper: a COMPLETED callback for a purchase (major units = cents/100)
create or replace function sp_complete(p_pid text, p_payment text) returns text language plpgsql as $$
begin
  return (xendit_webhook(jsonb_build_object(
    'event','payment_session.completed',
    'data', jsonb_build_object('reference_id', p_pid, 'payment_session_id','ps-'||p_payment,
       'payment_id', p_payment, 'status','COMPLETED', 'amount', 5000, 'currency','CZK',
       'metadata', jsonb_build_object('purchase_id', p_pid))), 'goodtoken'))->>'result';
end $$;

-- =============================================================================
-- (1) A recurring plan is bought as ONE period: one membership, auto_renew
--     false, no subscription fields, one payment.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','5e665e66-0000-0000-0000-00000000c001',false);
select set_config('t.pid1', (select purchase_id::text from xendit_begin_purchase(:S,:PR)), false);
select set_config('request.jwt.claim.sub','',false); reset role;

select expect_text('a first recurring buy stamps no renews_membership_id',
  coalesce((select renews_membership_id::text from xendit_purchases where id=current_setting('t.pid1')::uuid),'null'), 'null');
select expect_text('the COMPLETED callback is processed', sp_complete(current_setting('t.pid1'),'py-5e66-1'), 'processed');

select set_config('t.ms', (select id::text from memberships where member_id=:M1 and plan_id=:PR), false);
select expect_num('exactly one membership for the member on this plan',
  (select count(*) from memberships where member_id=:M1 and plan_id=:PR)::bigint, 1);
select expect_true('auto_renew is false (one period, renew by hand)',
  (select not auto_renew from memberships where id=current_setting('t.ms')::uuid));
select expect_text('no Xendit/Stripe subscription id',
  coalesce((select stripe_subscription_id from memberships where id=current_setting('t.ms')::uuid),'null'), 'null');
select expect_true('the period has an end',
  (select current_period_end is not null from memberships where id=current_setting('t.ms')::uuid));
select expect_num('credits are the per-period allowance',
  (select credits_remaining from memberships where id=current_setting('t.ms')::uuid)::bigint, 30);
select expect_text('status is active',
  (select status::text from memberships where id=current_setting('t.ms')::uuid), 'active');
select expect_num('exactly one payment, provider xendit, tagged to the membership',
  (select count(*) from payments where membership_id=current_setting('t.ms')::uuid and provider='xendit' and status='succeeded')::bigint, 1);

select set_config('t.end1', (select current_period_end::text from memberships where id=current_setting('t.ms')::uuid), false);

-- =============================================================================
-- (2) Early renewal EXTENDS the same membership from its OLD end (never a new
--     one, never a gap), resets credits, adds one payment.
-- =============================================================================
-- burn a credit so we can see the reset
update memberships set credits_remaining = 5 where id=current_setting('t.ms')::uuid;

set role authenticated; select set_config('request.jwt.claim.sub','5e665e66-0000-0000-0000-00000000c001',false);
select set_config('t.pid2', (select purchase_id::text from xendit_begin_purchase(:S,:PR)), false);
select set_config('request.jwt.claim.sub','',false); reset role;

select expect_text('a renewal buy stamps renews_membership_id = the live membership',
  (select renews_membership_id::text from xendit_purchases where id=current_setting('t.pid2')::uuid), current_setting('t.ms'));
select expect_text('the renewal callback is processed', sp_complete(current_setting('t.pid2'),'py-5e66-2'), 'processed');

select expect_num('STILL exactly one membership (extended, not a second)',
  (select count(*) from memberships where member_id=:M1 and plan_id=:PR)::bigint, 1);
select expect_true('the new end is the OLD end + one period (plan_period_end from old end)',
  (select current_period_end = plan_period_end(:PR, current_setting('t.end1')::timestamptz)
     from memberships where id=current_setting('t.ms')::uuid));
select expect_num('credits reset to the allowance on renewal',
  (select credits_remaining from memberships where id=current_setting('t.ms')::uuid)::bigint, 30);
select expect_num('two payments now',
  (select count(*) from payments where membership_id=current_setting('t.ms')::uuid and provider='xendit')::bigint, 2);
select expect_text('still active',
  (select status::text from memberships where id=current_setting('t.ms')::uuid), 'active');

-- =============================================================================
-- (3) A PAST-DUE renewal inside grace extends from the OLD (past) end and lands
--     active.
-- =============================================================================
update memberships
   set status = 'past_due',
       current_period_end = now() - interval '1 day'
 where id = current_setting('t.ms')::uuid;
select set_config('t.end3', (select current_period_end::text from memberships where id=current_setting('t.ms')::uuid), false);

set role authenticated; select set_config('request.jwt.claim.sub','5e665e66-0000-0000-0000-00000000c001',false);
select set_config('t.pid3', (select purchase_id::text from xendit_begin_purchase(:S,:PR)), false);
select set_config('request.jwt.claim.sub','',false); reset role;

select expect_text('a past-due membership is still the renew target',
  (select renews_membership_id::text from xendit_purchases where id=current_setting('t.pid3')::uuid), current_setting('t.ms'));
select expect_text('the past-due renewal is processed', sp_complete(current_setting('t.pid3'),'py-5e66-3'), 'processed');
select expect_true('extended from the OLD (yesterday) end, not from today',
  (select current_period_end = plan_period_end(:PR, current_setting('t.end3')::timestamptz)
     from memberships where id=current_setting('t.ms')::uuid));
select expect_text('status back to active',
  (select status::text from memberships where id=current_setting('t.ms')::uuid), 'active');
select expect_num('still one membership',
  (select count(*) from memberships where member_id=:M1 and plan_id=:PR)::bigint, 1);

-- =============================================================================
-- (4) A renew path with no live/past-due membership is a NORMAL new purchase.
-- =============================================================================
update memberships set status = 'cancelled' where id = current_setting('t.ms')::uuid;

set role authenticated; select set_config('request.jwt.claim.sub','5e665e66-0000-0000-0000-00000000c001',false);
select set_config('t.pid4', (select purchase_id::text from xendit_begin_purchase(:S,:PR)), false);
select set_config('request.jwt.claim.sub','',false); reset role;

select expect_text('no live membership → begin stamps no renews_membership_id',
  coalesce((select renews_membership_id::text from xendit_purchases where id=current_setting('t.pid4')::uuid),'null'), 'null');
select expect_text('processed', sp_complete(current_setting('t.pid4'),'py-5e66-4'), 'processed');
select expect_num('a NEW active membership exists (the cancelled one kept)',
  (select count(*) from memberships where member_id=:M1 and plan_id=:PR and status='active')::bigint, 1);
select expect_num('two membership rows now (one cancelled, one new)',
  (select count(*) from memberships where member_id=:M1 and plan_id=:PR)::bigint, 2);
select expect_true('the new membership is also auto_renew false',
  (select not auto_renew from memberships where member_id=:M1 and plan_id=:PR and status='active'));

-- =============================================================================
-- (5) The 7-day reminder: queued once per period, with the renew link; never
--     twice; not for a far-off, a subscription, or an auto-renew membership.
-- =============================================================================
-- M2: active recurring, auto_renew false, ends in 3 days → reminded.
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency,
                         starts_on, current_period_start, current_period_end, renews_on, auto_renew, credits_remaining)
  values ('5e665e66-0000-0000-0000-0000000000b2', :S, :M2, :PR, 'active', 500000, 'CZK',
          current_date - 27, now() - interval '27 days', now() + interval '3 days',
          (now() + interval '3 days')::date, false, 30);
-- a far-off one (ends in 30 days) — not due
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency,
                         starts_on, current_period_start, current_period_end, renews_on, auto_renew, credits_remaining)
  values ('5e665e66-0000-0000-0000-0000000000b3', :S, :M1, :PR, 'active', 500000, 'CZK',
          current_date, now(), now() + interval '30 days', (now()+interval '30 days')::date, false, 30);

select set_config('t.r1', (sweep_membership_expiring())->>'queued', false);
select expect_num('the reminder is queued for the member ending within 7 days',
  (select count(*) from notifications where template_key='membership_expiring' and member_id=:M2)::bigint, 1);
select expect_true('the reminder carries the renew link to /account/plan',
  (select (payload->>'renew_url') like '%/account/plan' from notifications
     where template_key='membership_expiring' and member_id=:M2 limit 1));
select expect_num('the far-off (30-day) membership is NOT reminded',
  (select count(*) from notifications where template_key='membership_expiring' and member_id=:M1)::bigint, 0);

-- a second sweep adds nothing (dedupe on membership + period-end date)
select set_config('t.r2', (sweep_membership_expiring())->>'queued', false);
select expect_num('a second sweep queues no second reminder',
  (select count(*) from notifications where template_key='membership_expiring' and member_id=:M2)::bigint, 1);

-- =============================================================================
-- (6) Anon surface unchanged — EXACTLY THIRTEEN.
-- =============================================================================
select expect_num('anon surface is exactly thirteen',
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not like 'expect_%' and p.proname not like 'sp_%')::bigint, 13);

-- --- cleanup -----------------------------------------------------------------
drop function sp_complete(text, text);
drop function expect_true(text,boolean);
drop function expect_num(text,bigint,bigint);
drop function expect_text(text,text,text);
