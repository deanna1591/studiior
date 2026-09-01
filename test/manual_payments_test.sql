-- =============================================================================
-- Manual payments — Decision 16, migrations 040/041/042
-- =============================================================================
-- UUID space cafe, checked free. Run after `supabase db reset`.
--
-- Studio ONE has no payment provider at all. That is the point: everything
-- below has to work for a studio in a country Stripe does not serve.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then
    raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else
    raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null');
  end if;
end $$;

create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then
    raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else
    raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null');
  end if;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('cafecafe-0000-0000-0000-0000000000a1'),   -- owner
  ('cafecafe-0000-0000-0000-0000000000a2'),   -- front desk
  ('cafecafe-0000-0000-0000-0000000000b1'),   -- member, cash studio
  ('cafecafe-0000-0000-0000-0000000000b2');   -- member, stripe studio
insert into profiles (id, email) values
  ('cafecafe-0000-0000-0000-0000000000a1','cafe-owner@example.com'),
  ('cafecafe-0000-0000-0000-0000000000a2','cafe-desk@example.com'),
  ('cafecafe-0000-0000-0000-0000000000b1','cafe-mem@example.com'),
  ('cafecafe-0000-0000-0000-0000000000b2','cafe-mem2@example.com');

-- A studio with NO provider, and one with Stripe, so the two paths can be
-- compared on the same plan.
insert into studios (id, name, slug, timezone, currency, status, stripe_account_id) values
  ('cafecafe-0000-0000-0000-000000000001','Cash Only Pilates','cash-only','Asia/Manila','PHP', 'active', null),
  ('cafecafe-0000-0000-0000-000000000002','Card Studio','card-studio','Asia/Manila','PHP','active','acct_test_cafe');
insert into studio_settings (studio_id) values
  ('cafecafe-0000-0000-0000-000000000001'), ('cafecafe-0000-0000-0000-000000000002');
insert into locations (id, studio_id, name, is_primary) values
  ('cafecafe-0000-0000-0000-00000000000c','cafecafe-0000-0000-0000-000000000001','Main',true),
  ('cafecafe-0000-0000-0000-00000000000d','cafecafe-0000-0000-0000-000000000002','Main',true);
insert into studio_staff (studio_id, user_id, email, role) values
  ('cafecafe-0000-0000-0000-000000000001','cafecafe-0000-0000-0000-0000000000a1','cafe-owner@example.com','owner'),
  ('cafecafe-0000-0000-0000-000000000001','cafecafe-0000-0000-0000-0000000000a2','cafe-desk@example.com','front_desk'),
  ('cafecafe-0000-0000-0000-000000000002','cafecafe-0000-0000-0000-0000000000a1','cafe-owner2@example.com','owner');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('cafecafe-0000-0000-0000-00000000ee01','cafecafe-0000-0000-0000-000000000001',
   'cafecafe-0000-0000-0000-00000000000c','Studio A',10),
  ('cafecafe-0000-0000-0000-00000000ee02','cafecafe-0000-0000-0000-000000000002',
   'cafecafe-0000-0000-0000-00000000000d','Studio A',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('cafecafe-0000-0000-0000-00000000cc01','cafecafe-0000-0000-0000-000000000001','Reformer',50,10),
  ('cafecafe-0000-0000-0000-00000000cc02','cafecafe-0000-0000-0000-000000000002','Reformer',50,10);

insert into members (id, studio_id, user_id, first_name, last_name, email, joined_on, status, waiver_signed_at) values
  ('cafecafe-0000-0000-0000-00000000dd01','cafecafe-0000-0000-0000-000000000001',
   'cafecafe-0000-0000-0000-0000000000b1','Maria','Cruz','maria@example.com', current_date - 10, 'active', now()),
  ('cafecafe-0000-0000-0000-00000000dd02','cafecafe-0000-0000-0000-000000000002',
   'cafecafe-0000-0000-0000-0000000000b2','Jose','Reyes','jose@example.com', current_date - 10, 'active', now());

-- The same plan shape at both studios, so "identically" is a real comparison.
insert into membership_plans (id, studio_id, name, type, price_cents, currency,
                              billing_interval, credits_per_period, status) values
  ('cafecafe-0000-0000-0000-0000000000c1','cafecafe-0000-0000-0000-000000000001',
   'Unlimited Monthly','recurring', 250000, 'PHP', 'month', null, 'active'),
  ('cafecafe-0000-0000-0000-0000000000c2','cafecafe-0000-0000-0000-000000000002',
   'Unlimited Monthly','recurring', 250000, 'PHP', 'month', null, 'active');
insert into membership_plans (id, studio_id, name, type, price_cents, currency,
                              credits, validity_days, status) values
  ('cafecafe-0000-0000-0000-0000000000c3','cafecafe-0000-0000-0000-000000000001',
   '10-Class Pack','class_pack', 900000, 'PHP', 10, 90, 'active');
insert into membership_plans (id, studio_id, name, type, price_cents, currency, status) values
  ('cafecafe-0000-0000-0000-0000000000c4','cafecafe-0000-0000-0000-000000000001',
   'Drop-in','drop_in', 50000, 'PHP', 'active');

insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               capacity, starts_at, ends_at, status) values
  ('cafecafe-0000-0000-0000-00000000f001','cafecafe-0000-0000-0000-000000000001',
   'cafecafe-0000-0000-0000-00000000000c','cafecafe-0000-0000-0000-00000000cc01',
   'cafecafe-0000-0000-0000-00000000ee01','Reformer', 10,
   now() + interval '3 days', now() + interval '3 days 50 minutes', 'scheduled');

-- =============================================================================
-- 1. A studio with no provider can sell a membership
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','cafecafe-0000-0000-0000-0000000000a2',false);  -- front desk

select set_config('t.sale',
  (select record_manual_payment(
     'cafecafe-0000-0000-0000-000000000001',
     'cafecafe-0000-0000-0000-00000000dd01',
     'plan', 250000, 'cash',
     p_plan_id => 'cafecafe-0000-0000-0000-0000000000c1',
     p_reference => 'receipt 0042')::text), false);

select expect_text('front desk can sell a membership for cash',
  (select status::text from memberships
    where member_id = 'cafecafe-0000-0000-0000-00000000dd01'), 'active');
select expect_num('...at the price on the day',
  (select price_cents from memberships
    where member_id = 'cafecafe-0000-0000-0000-00000000dd01'), 250000);
select expect_text('...recorded as a manual payment, not a provider one',
  (select provider::text from payments where member_id = 'cafecafe-0000-0000-0000-00000000dd01'), 'manual');
select expect_text('...with the method and reference the studio will reconcile against',
  (select method || ' / ' || reference from payments
    where member_id = 'cafecafe-0000-0000-0000-00000000dd01'), 'cash / receipt 0042');
select expect_text('...and who recorded it',
  (select recorded_by::text from payments where member_id = 'cafecafe-0000-0000-0000-00000000dd01'),
  'cafecafe-0000-0000-0000-0000000000a2');
reset role;
-- Read outside the front desk session on purpose: membership_events_read is
-- is_manager_up(), so front desk cannot see the audit trail they just caused.
-- That is correct — and asserting it from inside their session would have
-- measured the policy rather than the write.
select expect_num('...audited like any other membership',
  (select count(*) from membership_events where studio_id = 'cafecafe-0000-0000-0000-000000000001'
     and type = 'created'), 1);

-- =============================================================================
-- 2. A pack, and a drop-in, at the same provider-less studio
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','cafecafe-0000-0000-0000-0000000000a2',false);

select set_config('t.pack',
  (select record_manual_payment(
     'cafecafe-0000-0000-0000-000000000001','cafecafe-0000-0000-0000-00000000dd01',
     'plan', 900000, 'bank_transfer',
     p_plan_id => 'cafecafe-0000-0000-0000-0000000000c3',
     p_reference => 'BPI 88123')::text), false);

select expect_num('a pack bought by bank transfer grants its classes',
  (select credits_remaining from memberships
    where id = (current_setting('t.pack')::jsonb ->> 'membership_id')::uuid), 10);
select expect_num('...through the ledger, which is where the balance lives',
  (select coalesce(sum(delta),0) from credit_ledger
    where member_id = 'cafecafe-0000-0000-0000-00000000dd01' and reason = 'purchase'), 10);
select expect_text('...and it expires when the plan says',
  (select (expires_on = current_date + 90)::text from memberships
    where id = (current_setting('t.pack')::jsonb ->> 'membership_id')::uuid), 'true');
reset role;

-- A drop-in at a studio with no provider: booked outright, then paid at the desk.
set role authenticated;
select set_config('request.jwt.claim.sub','cafecafe-0000-0000-0000-0000000000b1',false);
select set_config('t.booking',
  (select (book_class('cafecafe-0000-0000-0000-00000000f001',
                      'cafecafe-0000-0000-0000-00000000dd01','member',null,null)).booking_id::text), false);
reset role;

-- She has a pack, so this one is covered by it rather than being a drop-in.
-- Take the pack away and book again to reach the drop-in path.
update memberships set status = 'cancelled'
 where member_id = 'cafecafe-0000-0000-0000-00000000dd01';
delete from bookings where id = current_setting('t.booking')::uuid;
update class_occurrences set booked_count = 0 where id = 'cafecafe-0000-0000-0000-00000000f001';

set role authenticated;
select set_config('request.jwt.claim.sub','cafecafe-0000-0000-0000-0000000000b1',false);
select set_config('t.booking',
  (select (book_class('cafecafe-0000-0000-0000-00000000f001',
                      'cafecafe-0000-0000-0000-00000000dd01','member',null,null)).booking_id::text), false);
reset role;

-- No provider connected, so nothing is held pending a checkout that cannot
-- happen. The seat is booked and the money is settled at the desk.
select expect_text('with no provider a drop-in books outright, not pending payment',
  (select status::text from bookings where id = current_setting('t.booking')::uuid), 'booked');

set role authenticated;
select set_config('request.jwt.claim.sub','cafecafe-0000-0000-0000-0000000000a2',false);
select set_config('t.drop',
  (select record_manual_payment(
     'cafecafe-0000-0000-0000-000000000001','cafecafe-0000-0000-0000-00000000dd01',
     'dropin', 50000, 'gcash',
     p_booking_id => current_setting('t.booking')::uuid,
     p_reference => 'GC 7781')::text), false);
reset role;

select expect_num('the desk records the drop-in against the booking',
  (select count(*) from payments
    where booking_id = current_setting('t.booking')::uuid
      and provider = 'manual' and method = 'gcash' and status = 'succeeded'), 1);
select expect_text('...and the booking it was already holding stays booked',
  (select status::text from bookings where id = current_setting('t.booking')::uuid), 'booked');

-- =============================================================================
-- 3. Identical to Stripe — because it is the same function, not a matching one
-- =============================================================================
select set_config('app.stripe_webhook_secret','whsec_test',false);
create or replace function sig(body text, secret text default 'whsec_test')
returns text language sql as $$
  select 't=' || extract(epoch from now())::bigint || ',v1=' ||
         encode(extensions.hmac(extract(epoch from now())::bigint || '.' || body,
                                secret, 'sha256'), 'hex')
$$;

-- A fresh member for the comparison. Maria's memberships were cancelled above
-- to reach the drop-in path, so comparing hers would compare a cancelled row
-- against an active one and prove nothing.
insert into auth.users (id) values ('cafecafe-0000-0000-0000-0000000000b3');
insert into profiles (id, email) values ('cafecafe-0000-0000-0000-0000000000b3','cafe-mem3@example.com');
insert into members (id, studio_id, user_id, first_name, last_name, email, joined_on, status, waiver_signed_at)
values ('cafecafe-0000-0000-0000-00000000dd03','cafecafe-0000-0000-0000-000000000001',
        'cafecafe-0000-0000-0000-0000000000b3','Ana','Santos','ana@example.com',
        current_date - 10, 'active', now());

set role authenticated;
select set_config('request.jwt.claim.sub','cafecafe-0000-0000-0000-0000000000a2',false);
select record_manual_payment(
  'cafecafe-0000-0000-0000-000000000001','cafecafe-0000-0000-0000-00000000dd03',
  'plan', 250000, 'cash', p_plan_id => 'cafecafe-0000-0000-0000-0000000000c1');
reset role;

select set_config('t.stripe_buy',
  '{"id":"evt_cafe","type":"checkout.session.completed","livemode":false,'
  '"account":"acct_test_cafe","data":{"object":{"id":"cs_cafe","currency":"php",'
  '"amount_total":250000,"customer":"cus_c","subscription":"sub_c","metadata":'
  '{"kind":"plan","studio_id":"cafecafe-0000-0000-0000-000000000002",'
  '"member_id":"cafecafe-0000-0000-0000-00000000dd02",'
  '"plan_id":"cafecafe-0000-0000-0000-0000000000c2","price_cents":"250000"}}}}', false);
select expect_text('the same plan bought through Stripe at the other studio',
  (select stripe_webhook(current_setting('t.stripe_buy'), sig(current_setting('t.stripe_buy'))) ->> 'result'),
  'membership_created');

-- Compare the two memberships field for field, ignoring only the things that
-- MUST differ: their ids, their studio, their member, and Stripe's own handles.
select expect_text('a cash membership and a Stripe membership are the same row',
  (select (
     (to_jsonb(a) - 'id' - 'studio_id' - 'member_id' - 'plan_id' - 'created_at'
       - 'updated_at' - 'stripe_customer_id' - 'stripe_subscription_id')
     =
     (to_jsonb(b) - 'id' - 'studio_id' - 'member_id' - 'plan_id' - 'created_at'
       - 'updated_at' - 'stripe_customer_id' - 'stripe_subscription_id')
   )::text
     from memberships a, memberships b
    where a.member_id = 'cafecafe-0000-0000-0000-00000000dd03'
      and b.member_id = 'cafecafe-0000-0000-0000-00000000dd02'), 'true');

select expect_text('...and the payments differ only in who moved the money',
  (select string_agg(distinct provider::text, ',' order by provider::text) from payments
    where studio_id in ('cafecafe-0000-0000-0000-000000000001','cafecafe-0000-0000-0000-000000000002')),
  'manual,stripe');

-- =============================================================================
-- 4. Refunds — both providers, and only in the right hands
-- =============================================================================
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               capacity, starts_at, ends_at, status) values
  ('cafecafe-0000-0000-0000-00000000f002','cafecafe-0000-0000-0000-000000000001',
   'cafecafe-0000-0000-0000-00000000000c','cafecafe-0000-0000-0000-00000000cc01',
   'cafecafe-0000-0000-0000-00000000ee01','Reformer', 10,
   now() + interval '5 days', now() + interval '5 days 50 minutes', 'scheduled'),
  ('cafecafe-0000-0000-0000-00000000f003','cafecafe-0000-0000-0000-000000000001',
   'cafecafe-0000-0000-0000-00000000000c','cafecafe-0000-0000-0000-00000000cc01',
   'cafecafe-0000-0000-0000-00000000ee01','Reformer', 10,
   now() + interval '6 days', now() + interval '6 days 50 minutes', 'scheduled');

-- Ana swaps her unlimited plan for a 10-class pack and uses two of them.
update memberships set status = 'cancelled' where member_id = 'cafecafe-0000-0000-0000-00000000dd03';
set role authenticated;
select set_config('request.jwt.claim.sub','cafecafe-0000-0000-0000-0000000000a2',false);
select set_config('t.anapack',
  (select record_manual_payment(
     'cafecafe-0000-0000-0000-000000000001','cafecafe-0000-0000-0000-00000000dd03',
     'plan', 900000, 'cash', p_plan_id => 'cafecafe-0000-0000-0000-0000000000c3')::text), false);
reset role;

set role authenticated;
select set_config('request.jwt.claim.sub','cafecafe-0000-0000-0000-0000000000b3',false);
select (book_class('cafecafe-0000-0000-0000-00000000f002',
                   'cafecafe-0000-0000-0000-00000000dd03','member',null,null)).status;
select (book_class('cafecafe-0000-0000-0000-00000000f003',
                   'cafecafe-0000-0000-0000-00000000dd03','member',null,null)).status;
reset role;

select expect_num('she has used two of her ten classes',
  (select credits_remaining from memberships
    where id = (current_setting('t.anapack')::jsonb ->> 'membership_id')::uuid), 8);

-- Front desk sells, but does not refund: §9 puts money leaving the studio with
-- a second pair of hands.
set role authenticated;
select set_config('request.jwt.claim.sub','cafecafe-0000-0000-0000-0000000000a2',false);
do $$
begin
  perform record_refund((select (current_setting('t.anapack')::jsonb ->> 'payment_id')::uuid));
  raise exception 'FAIL  front desk refunded a payment';
exception when sqlstate 'PT403' then
  raise notice 'PASS  front desk can take money but not give it back';
end $$;
reset role;

-- The owner can, and the credits she has not used come off — but not the two
-- she has, because you cannot un-attend a class.
set role authenticated;
select set_config('request.jwt.claim.sub','cafecafe-0000-0000-0000-0000000000a1',false);
select set_config('t.refund',
  (select record_refund((current_setting('t.anapack')::jsonb ->> 'payment_id')::uuid,
                        null, 'changed her mind')::text), false);
reset role;

select expect_num('a full refund takes back the eight she had left',
  ((current_setting('t.refund')::jsonb ->> 'credits_removed')::int), 8);
select expect_num('...leaving her pack empty rather than negative',
  (select credits_remaining from memberships
    where id = (current_setting('t.anapack')::jsonb ->> 'membership_id')::uuid), 0);
select expect_num('...through the ledger, which still adds up',
  (select coalesce(sum(delta),0) from credit_ledger
    where member_id = 'cafecafe-0000-0000-0000-00000000dd03'), 0);
select expect_text('...the payment reads refunded',
  (select status::text from payments
    where id = (current_setting('t.anapack')::jsonb ->> 'payment_id')::uuid), 'refunded');
select expect_text('...and the membership is closed with the reason',
  (select cancellation_reason from memberships
    where id = (current_setting('t.anapack')::jsonb ->> 'membership_id')::uuid), 'changed her mind');
select expect_text('...the two classes she already attended are untouched',
  (select count(*)::text from bookings
    where member_id = 'cafecafe-0000-0000-0000-00000000dd03' and status = 'booked'), '2');

-- A partial refund is a judgement about money, not about classes.
set role authenticated;
select set_config('request.jwt.claim.sub','cafecafe-0000-0000-0000-0000000000a1',false);
select set_config('t.partial',
  (select record_refund(
     (select id from payments where member_id = 'cafecafe-0000-0000-0000-00000000dd01'
        and provider = 'manual' and method = 'cash' limit 1),
     100000, 'goodwill')::text), false);
reset role;
select expect_text('a partial refund says so',
  (select status::text from payments where member_id = 'cafecafe-0000-0000-0000-00000000dd01'
     and method = 'cash' limit 1), 'partially_refunded');
select expect_num('...and records how much has gone back',
  (select refunded_cents from payments where member_id = 'cafecafe-0000-0000-0000-00000000dd01'
     and method = 'cash' limit 1), 100000);

-- The same function refunds a Stripe payment: one refund path, two providers.
set role authenticated;
select set_config('request.jwt.claim.sub','cafecafe-0000-0000-0000-0000000000a1',false);
select expect_text('the same function refunds a Stripe payment',
  (select (record_refund((select id from payments
                           where studio_id = 'cafecafe-0000-0000-0000-000000000002'
                             and provider = 'stripe' limit 1)) ->> 'full')), 'true');
reset role;

-- =============================================================================
-- 5. The checklist stops nagging about a provider this studio will never use
-- =============================================================================
select expect_text('connect_stripe is optional, not outstanding',
  (select (studio_setup_state('cafecafe-0000-0000-0000-000000000001')
             -> 'connect_stripe' ->> 'optional')), 'true');

-- =============================================================================
-- 6. "I'll pay at the studio" — the member's half of Decision 16
-- =============================================================================
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               capacity, starts_at, ends_at, status) values
  ('cafecafe-0000-0000-0000-00000000f004','cafecafe-0000-0000-0000-000000000002',
   'cafecafe-0000-0000-0000-00000000000d','cafecafe-0000-0000-0000-00000000cc02',
   'cafecafe-0000-0000-0000-00000000ee02','Reformer', 10,
   now() + interval '4 days', now() + interval '4 days 50 minutes', 'scheduled');
insert into membership_plans (id, studio_id, name, type, price_cents, currency, status) values
  ('cafecafe-0000-0000-0000-0000000000c5','cafecafe-0000-0000-0000-000000000002',
   'Drop-in','drop_in', 50000, 'PHP', 'active');

-- Jose's Stripe membership was refunded above, so he resolves to drop_in — and
-- his studio HAS a provider, so the seat is held rather than booked.
set role authenticated;
select set_config('request.jwt.claim.sub','cafecafe-0000-0000-0000-0000000000b2',false);
select set_config('t.held',
  (select (book_class('cafecafe-0000-0000-0000-00000000f004',
                      'cafecafe-0000-0000-0000-00000000dd02','member',null,null)).booking_id::text), false);
select expect_text('at a studio WITH a provider the seat is held',
  (select status::text from bookings where id = current_setting('t.held')::uuid), 'pending_payment');

-- He would rather pay at the counter.
select set_config('t.desk', (select choose_pay_at_desk(current_setting('t.held')::uuid)::text), false);
reset role;

select expect_text('choosing the desk confirms the seat',
  (select status::text from bookings where id = current_setting('t.held')::uuid), 'booked');
select expect_text('...and leaves money owed, not money taken',
  (select status::text from payments where id = (current_setting('t.desk')::jsonb ->> 'payment_id')::uuid),
  'pending');
select expect_text('...recorded as manual, because that is how it will arrive',
  (select provider::text from payments where id = (current_setting('t.desk')::jsonb ->> 'payment_id')::uuid),
  'manual');

-- And the desk settles it when he turns up.
set role authenticated;
select set_config('request.jwt.claim.sub','cafecafe-0000-0000-0000-0000000000a1',false);
select record_manual_payment(
  'cafecafe-0000-0000-0000-000000000002','cafecafe-0000-0000-0000-00000000dd02',
  'dropin', 50000, 'cash', p_booking_id => current_setting('t.held')::uuid);
reset role;
select expect_num('the desk settles it and the class is paid for',
  (select count(*) from payments where booking_id = current_setting('t.held')::uuid
     and status = 'succeeded' and provider = 'manual'), 1);

select 'ALL MANUAL PAYMENT TESTS PASSED' as result;
