-- Decision 118: buy a plan before you have an account. UUID space 118a.
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
-- Buy as anon, return the purchase id. Captures the SQLSTATE on a refusal.
create or replace function t_buy(p_studio uuid, p_plan uuid, p_email text, p_phone text default '09171234567')
returns text language plpgsql as $$
declare v text;
begin
  set local role anon;
  select purchase_id::text into v from plan_buy_begin(p_studio, p_plan, 'Gia Guest', p_email, p_phone);
  reset role;
  return v;
exception when others then
  return 'ERR:' || sqlstate;
end $$;
-- Pay it through the anon webhook (amount in major units).
create or replace function t_pay(p_purchase text, p_ref text)
returns text language plpgsql as $$
declare v jsonb; v_amt numeric;
begin
  select amount_cents / 100.0 into v_amt from xendit_purchases where id = p_purchase::uuid;
  set local role anon;
  v := xendit_webhook(jsonb_build_object('event','payment.succeeded',
         'data', jsonb_build_object('reference_id', p_purchase, 'payment_id', p_ref, 'status','SUCCEEDED',
           'amount', v_amt, 'currency','PHP')), 'goodtoken118');
  reset role;
  return v ->> 'result';
end $$;
-- Claim as a signed-in user.
create or replace function t_claim(p_user uuid, p_studio uuid)
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  set local role authenticated;
  v := claim_waiting_plans(p_studio);
  reset role;
  return v;
end $$;
create or replace function t_today() returns date language sql stable as $$
  select (now() at time zone 'Asia/Manila')::date; $$;

-- ---- Fixtures ------------------------------------------------------------------
insert into auth.users (id, email, email_confirmed_at) values
  ('118a0000-0000-0000-0000-0000000000a1', 'owner118@example.com', now()),
  ('118a0000-0000-0000-0000-0000000000e1', 'exist118@example.com', now()),
  ('118a0000-0000-0000-0000-0000000000e2', 'guest118@example.com', now()),
  ('118a0000-0000-0000-0000-0000000000e3', 'unver118@example.com', null),
  ('118a0000-0000-0000-0000-0000000000e4', 'trial118@example.com', now()),
  ('118a0000-0000-0000-0000-0000000000e5', 'month118@example.com', now()),
  ('118a0000-0000-0000-0000-0000000000e6', 'intro118@example.com', now()),
  ('118a0000-0000-0000-0000-0000000000e7', 'twin118@example.com', now());
insert into profiles (id, email) select id, email from auth.users where id::text like '118a0000%';

insert into studios (id, name, slug, timezone, currency, country, status) values
  ('118a0000-0000-0000-0000-000000000001','Buy Studio','b118-s','Asia/Manila','PHP','PH','active'),
  ('118a0000-0000-0000-0000-000000000002','Busy Studio','b118-t','Asia/Manila','PHP','PH','active');
insert into studio_settings (studio_id) values
  ('118a0000-0000-0000-0000-000000000001'), ('118a0000-0000-0000-0000-000000000002');
insert into locations (id, studio_id, name, is_primary) values
  ('118a0000-0000-0000-0000-00000000000a','118a0000-0000-0000-0000-000000000001','Main',true);
insert into studio_staff (studio_id, user_id, email, role) values
  ('118a0000-0000-0000-0000-000000000001','118a0000-0000-0000-0000-0000000000a1','owner118@example.com','owner');

insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, validity_days, billing_interval, visibility, status) values
  ('118a0000-0000-0000-0000-0000000cc001','118a0000-0000-0000-0000-000000000001','5-Class Pack','class_pack',140000,'PHP',5,30,null,'public','active'),
  ('118a0000-0000-0000-0000-0000000cc002','118a0000-0000-0000-0000-000000000001','Monthly','recurring',250000,'PHP',null,null,'month','public','active'),
  ('118a0000-0000-0000-0000-0000000cc003','118a0000-0000-0000-0000-000000000001','Intro Offer','trial',99900,'PHP',3,14,null,'public','active'),
  ('118a0000-0000-0000-0000-0000000cc004','118a0000-0000-0000-0000-000000000001','Staff Plan','class_pack',10000,'PHP',1,30,null,'staff_only','active'),
  ('118a0000-0000-0000-0000-0000000cc009','118a0000-0000-0000-0000-000000000002','Busy Pack','class_pack',100000,'PHP',5,30,null,'public','active');
update studio_settings set intro_offer_plan_id = '118a0000-0000-0000-0000-0000000cc003'
 where studio_id = '118a0000-0000-0000-0000-000000000001';

insert into plan_promotions (studio_id, name, pct, starts_on, ends_on, plan_ids) values
  ('118a0000-0000-0000-0000-000000000001','Holiday Sale',25, t_today() - 1, t_today() + 10,
   array['118a0000-0000-0000-0000-0000000cc001']::uuid[]);

insert into studio_payment_providers
  (studio_id, provider, secret_key_ciphertext, callback_token_ciphertext, callback_token_sha256,
   key_last4, test_mode, connected_by) values
  ('118a0000-0000-0000-0000-000000000001','xendit','v1.opaque-secret','v1.opaque-token',
   encode(digest('goodtoken118','sha256'),'hex'), 'tok0', true, '118a0000-0000-0000-0000-0000000000a1'),
  ('118a0000-0000-0000-0000-000000000002','xendit','v1.opaque-secret','v1.opaque-token',
   encode(digest('goodtoken118b','sha256'),'hex'), 'tok1', true, '118a0000-0000-0000-0000-0000000000a1');

-- Members who already have accounts.
insert into members (id, studio_id, user_id, first_name, last_name, email, status) values
  ('118a0000-0000-0000-0000-00000000dd01','118a0000-0000-0000-0000-000000000001','118a0000-0000-0000-0000-0000000000e1','Eve','Exists','exist118@example.com','active'),
  ('118a0000-0000-0000-0000-00000000dd04','118a0000-0000-0000-0000-000000000001','118a0000-0000-0000-0000-0000000000e4','Tia','Trialled','trial118@example.com','active');
-- Tia has had the intro offer.
insert into memberships (studio_id, member_id, plan_id, status, price_cents, currency, starts_on)
values ('118a0000-0000-0000-0000-000000000001','118a0000-0000-0000-0000-00000000dd04',
        '118a0000-0000-0000-0000-0000000cc003','expired',99900,'PHP', t_today() - 60);

-- =============================================================================
-- 1. The public buy page reads the plans through studio_by_slug.
-- =============================================================================
set role anon;
select set_config('t.buy', (select buy::text from studio_by_slug('b118-s', true)), false);
select set_config('t.nobuy', coalesce((select buy::text from studio_by_slug('b118-s')), 'null'), false);
reset role;
select expect_text('studio_by_slug without plans carries no buy block', current_setting('t.nobuy'), 'null');
select expect_text('the buy block says the studio takes online payments',
  current_setting('t.buy')::jsonb ->> 'online', 'true');
select expect_num('three public plans are listed (the staff-only one is not)',
  jsonb_array_length(current_setting('t.buy')::jsonb -> 'plans'), 3);
select expect_text('the pack shows its sale price (25% off ₱1,400 = ₱1,050)',
  (select p -> 'price' ->> 'price_cents' from jsonb_array_elements(current_setting('t.buy')::jsonb -> 'plans') p
    where p ->> 'name' = '5-Class Pack'), '105000');

-- =============================================================================
-- 2. A guest buys the pack: pending purchase only, sale price, phone normalised.
-- =============================================================================
select set_config('t.p1', t_buy('118a0000-0000-0000-0000-000000000001','118a0000-0000-0000-0000-0000000cc001','Guest118@Example.com'), false);
select expect_true('anon can begin a purchase', current_setting('t.p1') !~ '^ERR');
select expect_text('the purchase is pending with no member, at the sale price, email lowered, phone normalised',
  (select status || '/' || coalesce(member_id::text,'none') || '/' || amount_cents || '/' || list_price_cents
          || '/' || buyer_email || '/' || buyer_phone
     from xendit_purchases where id = current_setting('t.p1')::uuid),
  'pending/none/105000/140000/guest118@example.com/+639171234567');
select expect_text('a staff-only plan is not on sale',
  t_buy('118a0000-0000-0000-0000-000000000001','118a0000-0000-0000-0000-0000000cc004','x118@example.com'), 'ERR:PT404');
select expect_text('a bad phone is refused',
  t_buy('118a0000-0000-0000-0000-000000000001','118a0000-0000-0000-0000-0000000cc001','y118@example.com','12'), 'ERR:PT422');

-- Paid: held under the email, a waiting email, Sales shows it the day it was paid.
select expect_text('the webhook processes the guest payment',
  t_pay(current_setting('t.p1'), 'py-118-1'), 'processed');
select expect_text('the plan is held, waiting for an account',
  (select guest_status || '/' || status from xendit_purchases where id = current_setting('t.p1')::uuid), 'held/succeeded');
select expect_text('a payment is recorded, with no member yet',
  (select coalesce(p.member_id::text,'none') || '/' || p.amount_cents || '/' || p.status
     from payments p join xendit_purchases xp on xp.guest_payment_id = p.id
    where xp.id = current_setting('t.p1')::uuid), 'none/105000/succeeded');
select expect_num('no membership exists yet',
  (select count(*) from memberships where plan_id = '118a0000-0000-0000-0000-0000000cc001'), 0);
select expect_num('the waiting email went to the buyer',
  (select count(*) from notifications where template_key = 'plan_waiting_claim'
      and payload ->> 'to_email' = 'guest118@example.com'), 1);
select expect_num('...and renders with nothing stripped',
  (select coalesce(array_length(stripped, 1), 0) from notifications n
     cross join lateral render_notification(n.id) r
    where n.template_key = 'plan_waiting_claim' and n.payload ->> 'to_email' = 'guest118@example.com'), 0);
select set_config('request.jwt.claim.sub','118a0000-0000-0000-0000-0000000000a1',false);
set role authenticated;
select set_config('t.sales', (select sale_status || '/' || member_name || '/' || plan_name
   from sales_history('118a0000-0000-0000-0000-000000000001', t_today(), t_today())
  where sale_status = 'waiting_account' limit 1), false);
select set_config('t.unclaimed', (select count(*)::text from guest_purchases_unclaimed('118a0000-0000-0000-0000-000000000001')), false);
reset role;
select expect_text('Sales shows it the day it was paid, waiting for account',
  current_setting('t.sales'), 'waiting_account/Gia Guest/5-Class Pack');
select expect_text('the staff list shows it as bought, not yet claimed', current_setting('t.unclaimed'), '1');
select set_config('request.jwt.claim.sub','118a0000-0000-0000-0000-0000000000e1',false);
do $$ begin
  set local role authenticated;
  perform guest_purchases_unclaimed('118a0000-0000-0000-0000-000000000001');
  perform set_config('t.member_list', 'no_raise', false);
exception when others then perform set_config('t.member_list', sqlstate, false); end $$;
select expect_text('a member cannot read the staff list', current_setting('t.member_list'), 'PT403');

-- =============================================================================
-- 3. An existing account with that email gets the plan at once.
-- =============================================================================
select set_config('t.p2', t_buy('118a0000-0000-0000-0000-000000000001','118a0000-0000-0000-0000-0000000cc001','exist118@example.com'), false);
select t_pay(current_setting('t.p2'), 'py-118-2');
select expect_text('the purchase attached to the account at once',
  (select guest_status || '/' || member_id::text from xendit_purchases where id = current_setting('t.p2')::uuid),
  'claimed/118a0000-0000-0000-0000-00000000dd01');
select expect_num('the existing member holds the pack', (select count(*) from memberships
   where member_id = '118a0000-0000-0000-0000-00000000dd01' and plan_id = '118a0000-0000-0000-0000-0000000cc001'), 1);
select expect_num('"It is in your account" was sent', (select count(*) from notifications
   where template_key = 'plan_in_account' and member_id = '118a0000-0000-0000-0000-00000000dd01'), 1);

-- =============================================================================
-- 4. Claim requires a verified email.
-- =============================================================================
insert into members (id, studio_id, user_id, first_name, last_name, email, status) values
  ('118a0000-0000-0000-0000-00000000dd03','118a0000-0000-0000-0000-000000000001','118a0000-0000-0000-0000-0000000000e3','Una','Verified','unver118@example.com','lead');
select set_config('t.p3', t_buy('118a0000-0000-0000-0000-000000000001','118a0000-0000-0000-0000-0000000cc001','unver118@example.com'), false);
select t_pay(current_setting('t.p3'), 'py-118-3');
select expect_text('an unverified email cannot claim',
  t_claim('118a0000-0000-0000-0000-0000000000e3','118a0000-0000-0000-0000-000000000001') ->> 'reason', 'email_not_verified');
select expect_text('...and the plan stays held',
  (select guest_status from xendit_purchases where id = current_setting('t.p3')::uuid), 'held');

-- =============================================================================
-- 5. Claim on a verified email, days later: validity starts on the claim day.
-- =============================================================================
update xendit_purchases set completed_at = now() - interval '5 days' where id = current_setting('t.p1')::uuid;
insert into members (id, studio_id, user_id, first_name, last_name, email, status) values
  ('118a0000-0000-0000-0000-00000000dd02','118a0000-0000-0000-0000-000000000001','118a0000-0000-0000-0000-0000000000e2','Gia','Guest','guest118@example.com','lead');
select set_config('t.c1', t_claim('118a0000-0000-0000-0000-0000000000e2','118a0000-0000-0000-0000-000000000001')::text, false);
select expect_text('the claim returns the plan', current_setting('t.c1')::jsonb -> 'claimed' -> 0 ->> 'plan_name', '5-Class Pack');
select expect_text('validity starts on the claim day, not the payment day',
  (select starts_on::text || '/' || expires_on::text || '/' || credits_remaining from memberships
    where member_id = '118a0000-0000-0000-0000-00000000dd02' and plan_id = '118a0000-0000-0000-0000-0000000cc001'),
  t_today()::text || '/' || (t_today() + 30)::text || '/5');
select expect_text('the payment now belongs to the member and the membership',
  (select (p.member_id = '118a0000-0000-0000-0000-00000000dd02')::text || '/' || (p.membership_id is not null)::text
     from payments p join xendit_purchases xp on xp.guest_payment_id = p.id where xp.id = current_setting('t.p1')::uuid),
  'true/true');
select expect_text('the purchase is claimed by the member',
  (select guest_status || '/' || claimed_member_id::text from xendit_purchases where id = current_setting('t.p1')::uuid),
  'claimed/118a0000-0000-0000-0000-00000000dd02');
select expect_text('the buyer phone filled the empty phone',
  (select phone from members where id = '118a0000-0000-0000-0000-00000000dd02'), '+639171234567');
select set_config('request.jwt.claim.sub','118a0000-0000-0000-0000-0000000000e2',false);
set role authenticated;
select set_config('t.ready', (my_guest_plans('118a0000-0000-0000-0000-000000000001'))::text, false);
reset role;
select expect_text('Home shows "Your 5-Class Pack is ready"',
  current_setting('t.ready')::jsonb -> 'ready' -> 0 ->> 'plan_name', '5-Class Pack');
select expect_num('a second claim attaches nothing more',
  jsonb_array_length(t_claim('118a0000-0000-0000-0000-0000000000e2','118a0000-0000-0000-0000-000000000001') -> 'claimed'), 0);

-- =============================================================================
-- 6. A one-month membership's month starts on the claim day.
-- =============================================================================
select set_config('t.p5', t_buy('118a0000-0000-0000-0000-000000000001','118a0000-0000-0000-0000-0000000cc002','month118@example.com'), false);
select t_pay(current_setting('t.p5'), 'py-118-5');
update xendit_purchases set completed_at = now() - interval '9 days' where id = current_setting('t.p5')::uuid;
insert into members (id, studio_id, user_id, first_name, last_name, email, status) values
  ('118a0000-0000-0000-0000-00000000dd05','118a0000-0000-0000-0000-000000000001','118a0000-0000-0000-0000-0000000000e5','Mo','Month','month118@example.com','lead');
select t_claim('118a0000-0000-0000-0000-0000000000e5','118a0000-0000-0000-0000-000000000001');
select expect_text('the month starts on the claim day and runs a month, not renewing by itself',
  (select (current_period_start at time zone 'Asia/Manila')::date::text || '/'
          || (current_period_end at time zone 'Asia/Manila')::date::text || '/' || auto_renew
     from memberships where member_id = '118a0000-0000-0000-0000-00000000dd05'),
  t_today()::text || '/' || (t_today() + interval '1 month')::date::text || '/false');

-- =============================================================================
-- 7. The intro offer: decided at claim. Somebody who has had theirs is refunded.
-- =============================================================================
select set_config('t.p6', t_buy('118a0000-0000-0000-0000-000000000001','118a0000-0000-0000-0000-0000000cc003','trial118@example.com'), false);
select t_pay(current_setting('t.p6'), 'py-118-6');
select expect_text('an intro offer is held even for an existing account (decided at claim)',
  (select guest_status from xendit_purchases where id = current_setting('t.p6')::uuid), 'held');
select set_config('t.c6', t_claim('118a0000-0000-0000-0000-0000000000e4','118a0000-0000-0000-0000-000000000001')::text, false);
select expect_num('the intro offer is not attached to somebody who has had theirs',
  (select count(*) from memberships where member_id = '118a0000-0000-0000-0000-00000000dd04'
      and plan_id = '118a0000-0000-0000-0000-0000000cc003' and status <> 'expired'), 0);
select expect_text('it waits for its refund, and the claim hands the server what it needs',
  (select guest_status from xendit_purchases where id = current_setting('t.p6')::uuid) || '/'
   || (current_setting('t.c6')::jsonb -> 'refunds' -> 0 ->> 'xendit_payment_id') || '/'
   || (current_setting('t.c6')::jsonb ->> 'secret_key_ciphertext'),
  'refund_pending/py-118-6/v1.opaque-secret');
-- The server made the Xendit refund; record it as the buyer.
select set_config('request.jwt.claim.sub','118a0000-0000-0000-0000-0000000000e4',false);
set role authenticated;
select record_guest_intro_refund(current_setting('t.p6')::uuid, 'rfd-118-6');
reset role;
select expect_text('the refund is recorded in full and the waiting plan is gone',
  (select pr.status || '/' || pr.amount_cents || '/' || xp.guest_status
     from payment_refunds pr join xendit_purchases xp on xp.guest_payment_id = pr.payment_id
    where xp.id = current_setting('t.p6')::uuid), 'pending/99900/refunded');
select expect_num('"We have refunded your payment" was sent',
  (select count(*) from notifications where template_key = 'intro_offer_refunded'
      and member_id = '118a0000-0000-0000-0000-00000000dd04'), 1);
select set_config('request.jwt.claim.sub','118a0000-0000-0000-0000-0000000000e1',false);
do $$ begin
  set local role authenticated;
  perform record_guest_intro_refund(current_setting('t.p6')::uuid, 'rfd-x');
  perform set_config('t.other_ref', 'no_raise', false);
exception when others then perform set_config('t.other_ref', sqlstate, false); end $$;
select expect_text('somebody else cannot record the refund', current_setting('t.other_ref'), 'PT403');
-- A first-timer gets their intro offer.
select set_config('t.p7', t_buy('118a0000-0000-0000-0000-000000000001','118a0000-0000-0000-0000-0000000cc003','intro118@example.com'), false);
select t_pay(current_setting('t.p7'), 'py-118-7');
insert into members (id, studio_id, user_id, first_name, last_name, email, status) values
  ('118a0000-0000-0000-0000-00000000dd06','118a0000-0000-0000-0000-000000000001','118a0000-0000-0000-0000-0000000000e6','Ina','Intro','intro118@example.com','lead');
select t_claim('118a0000-0000-0000-0000-0000000000e6','118a0000-0000-0000-0000-000000000001');
select expect_num('a first-timer''s intro offer is attached at claim',
  (select count(*) from memberships where member_id = '118a0000-0000-0000-0000-00000000dd06'
      and plan_id = '118a0000-0000-0000-0000-0000000cc003'), 1);

-- =============================================================================
-- 8. A refund before claim cancels the waiting plan.
-- =============================================================================
select set_config('request.jwt.claim.sub','118a0000-0000-0000-0000-0000000000a1',false);
set role authenticated;
select refund_payment((select guest_payment_id from xendit_purchases where id = current_setting('t.p3')::uuid),
                      null, 'Changed their mind', 'cash', 'desk-118');
reset role;
select expect_text('a refund before claim cancels the hold',
  (select guest_status from xendit_purchases where id = current_setting('t.p3')::uuid), 'refunded');
update auth.users set email_confirmed_at = now() where id = '118a0000-0000-0000-0000-0000000000e3';
select expect_num('...so claiming later attaches nothing',
  jsonb_array_length(t_claim('118a0000-0000-0000-0000-0000000000e3','118a0000-0000-0000-0000-000000000001') -> 'claimed'), 0);

-- =============================================================================
-- 9. The free-first same-person check fires on the phone save at claim.
-- =============================================================================
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('118a0000-0000-0000-0000-0000000ab001','118a0000-0000-0000-0000-000000000001','Reformer', 50, 6);
insert into class_occurrences (id, studio_id, location_id, class_type_id, name, starts_at, ends_at, capacity, status) values
  ('118a0000-0000-0000-0000-00000000c001','118a0000-0000-0000-0000-000000000001','118a0000-0000-0000-0000-00000000000a',
   '118a0000-0000-0000-0000-0000000ab001','Reformer', now() - interval '3 days', now() - interval '3 days' + interval '50 min', 6, 'scheduled'),
  ('118a0000-0000-0000-0000-00000000c002','118a0000-0000-0000-0000-000000000001','118a0000-0000-0000-0000-00000000000a',
   '118a0000-0000-0000-0000-0000000ab001','Reformer', now() + interval '3 days', now() + interval '3 days' + interval '50 min', 6, 'scheduled');
-- Yan already took a free class, and owns the phone the buyer types.
insert into members (id, studio_id, first_name, last_name, email, phone, status) values
  ('118a0000-0000-0000-0000-00000000dd08','118a0000-0000-0000-0000-000000000001','Yan','Before','yan118@example.com','+639175550000','active');
insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source)
values ('118a0000-0000-0000-0000-000000000001','118a0000-0000-0000-0000-00000000c001','118a0000-0000-0000-0000-00000000dd08','attended','member','comp');
select set_config('t.p9', t_buy('118a0000-0000-0000-0000-000000000001','118a0000-0000-0000-0000-0000000cc001','twin118@example.com','09175550000'), false);
select t_pay(current_setting('t.p9'), 'py-118-9');
-- Tess signs up after paying; staff had booked her free first class.
insert into members (id, studio_id, user_id, first_name, last_name, email, status) values
  ('118a0000-0000-0000-0000-00000000dd07','118a0000-0000-0000-0000-000000000001','118a0000-0000-0000-0000-0000000000e7','Tess','Twin','twin118@example.com','lead');
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source)
values ('118a0000-0000-0000-0000-0000000b0007','118a0000-0000-0000-0000-000000000001','118a0000-0000-0000-0000-00000000c002','118a0000-0000-0000-0000-00000000dd07','booked','member','comp');
insert into guest_passes (studio_id, guest_member_id, guest_email, occurrence_id, guest_booking_id, host_member_id)
values ('118a0000-0000-0000-0000-000000000001','118a0000-0000-0000-0000-00000000dd07','twin118@example.com',
        '118a0000-0000-0000-0000-00000000c002','118a0000-0000-0000-0000-0000000b0007', null);
select t_claim('118a0000-0000-0000-0000-0000000000e7','118a0000-0000-0000-0000-000000000001');
select expect_text('the phone saved at claim runs the same-person check: the free seat is held for payment',
  (select status || '/' || hold_reason from bookings where id = '118a0000-0000-0000-0000-0000000b0007'),
  'pending_payment/free_class_duplicate');

-- =============================================================================
-- 10. Reminders at 2 and 7 days; the staff resend; the daily check at 30 days.
-- =============================================================================
select set_config('t.p10', t_buy('118a0000-0000-0000-0000-000000000001','118a0000-0000-0000-0000-0000000cc001','late118@example.com'), false);
select t_pay(current_setting('t.p10'), 'py-118-10');
update xendit_purchases set completed_at = now() - interval '3 days' where id = current_setting('t.p10')::uuid;
select sweep_plan_claim_reminders();
select expect_num('a 3-day-old waiting plan gets the 2-day reminder',
  (select count(*) from notifications where template_key = 'plan_claim_reminder'
      and dedupe_key = 'plan_claim_reminder:2:' || current_setting('t.p10')), 1);
select sweep_plan_claim_reminders();
select expect_num('...once', (select count(*) from notifications where template_key = 'plan_claim_reminder'
      and dedupe_key like 'plan_claim_reminder:%' || current_setting('t.p10')), 1);
update xendit_purchases set completed_at = now() - interval '8 days' where id = current_setting('t.p10')::uuid;
select sweep_plan_claim_reminders();
select expect_num('at 7 days the second reminder goes', (select count(*) from notifications
   where template_key = 'plan_claim_reminder' and dedupe_key = 'plan_claim_reminder:7:' || current_setting('t.p10')), 1);
select set_config('request.jwt.claim.sub','118a0000-0000-0000-0000-0000000000a1',false);
set role authenticated;
select resend_plan_claim(current_setting('t.p10')::uuid);
reset role;
select expect_num('the staff resend sends one more', (select count(*) from notifications
   where template_key = 'plan_claim_reminder' and dedupe_key like 'plan_claim_resend:' || current_setting('t.p10') || ':%'), 1);
update xendit_purchases set completed_at = now() - interval '31 days' where id = current_setting('t.p10')::uuid;
select expect_num('the daily check lists it after 30 days',
  (select count(*) from jsonb_array_elements_text(daily_money_check('118a0000-0000-0000-0000-000000000001') -> 'items') i
    where i = 'Gia Guest: 5-Class Pack bought, not yet claimed for 30 days'), 1);

-- =============================================================================
-- 11. Rate limits (their own studio, so nothing above counts).
-- =============================================================================
do $$
declare k int; v text; v_err text := 'none';
begin
  for k in 1..3 loop
    v := t_buy('118a0000-0000-0000-0000-000000000002','118a0000-0000-0000-0000-0000000cc009','same118@example.com');
    if v ~ '^ERR' then v_err := v; end if;
  end loop;
  perform set_config('t.three', v_err, false);
  perform set_config('t.fourth', t_buy('118a0000-0000-0000-0000-000000000002','118a0000-0000-0000-0000-0000000cc009','same118@example.com'), false);
  for k in 1..6 loop
    perform t_buy('118a0000-0000-0000-0000-000000000002','118a0000-0000-0000-0000-0000000cc009','other' || k || '118@example.com');
  end loop;
  -- 9 so far in the minute; the tenth is allowed, the eleventh refused.
  perform set_config('t.tenth', t_buy('118a0000-0000-0000-0000-000000000002','118a0000-0000-0000-0000-0000000cc009','ten118@example.com'), false);
  perform set_config('t.eleventh', t_buy('118a0000-0000-0000-0000-000000000002','118a0000-0000-0000-0000-0000000cc009','eleven118@example.com'), false);
end $$;
select expect_text('three purchases a minute from one email are allowed', current_setting('t.three'), 'none');
select expect_text('the fourth from that email is refused', current_setting('t.fourth'), 'ERR:PT429');
select expect_true('the tenth for the studio is allowed', current_setting('t.tenth') !~ '^ERR');
select expect_text('the eleventh for the studio is refused', current_setting('t.eleventh'), 'ERR:PT429');

-- =============================================================================
-- 12. The anon surface is EXACTLY FIFTEEN functions; purchases are not readable.
-- =============================================================================
select expect_num('anon surface is exactly fifteen (suite helpers excluded)',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not like 'expect\_%' and p.proname not like 't\_%'), 15);
select expect_true('plan_buy_begin is the new one',
  has_function_privilege('anon', 'plan_buy_begin(uuid, uuid, text, text, text, text, boolean)', 'execute'));
select expect_true('xendit_purchases keeps row level security (anon reads no rows)',
  (select relrowsecurity from pg_class where oid = 'public.xendit_purchases'::regclass));
do $$ begin
  set local role anon;
  perform set_config('t.anon_rows', (select count(*)::text from xendit_purchases), false);
exception when insufficient_privilege then
  -- locally anon has no table grant at all; hosted grants it and RLS refuses rows.
  perform set_config('t.anon_rows', '0', false);
end $$;
select expect_text('anon reads no purchase rows', current_setting('t.anon_rows'), '0');
select expect_true('claim_waiting_plans is not anon',
  not has_function_privilege('anon', 'claim_waiting_plans(uuid)', 'execute'));

\echo 'buy_without_account_test PASS'
