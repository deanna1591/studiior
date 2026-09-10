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

create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual then raise notice 'PASS  %  (got true)', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if;
end $$;

create or replace function expect_null(label text, actual text)
returns void language plpgsql as $$
begin
  if actual is null then raise notice 'PASS  %  (got null)', label;
  else raise exception 'FAIL  %  expected null, got %', label, actual; end if;
end $$;

create or replace function expect_raises(label text, stmt text, want_sqlstate text)
returns void language plpgsql as $$
begin
  execute stmt; raise exception 'FAIL  %  expected % but nothing was raised', label, want_sqlstate;
exception when others then
  if sqlstate = want_sqlstate then raise notice 'PASS  %  (got %)', label, sqlstate;
  elsif sqlstate = 'P0001' and sqlerrm like 'FAIL%' then raise;
  else raise exception 'FAIL  %  expected %, got % (%)', label, want_sqlstate, sqlstate, sqlerrm; end if;
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
-- FROM THE STUDIO'S DAY, NOT THE SERVER'S. This studio is in Manila and the
-- server is on UTC, so for sixteen hours out of every twenty-four
-- `current_date` here is YESTERDAY in the studio — and a pack sold at nine in
-- the morning expired ninety days from the day before, one day short of what
-- the member paid for. It read as correct because the assertion was written
-- against the same wrong clock the function used. Migration 095.
select expect_text('...and it expires when the plan says, counted from the studio''s own day',
  (select (expires_on = studio_today('cafecafe-0000-0000-0000-000000000001') + 90)::text
     from memberships
    where id = (current_setting('t.pack')::jsonb ->> 'membership_id')::uuid), 'true');
select expect_text('...and starts_on is the studio''s day too',
  (select (starts_on = studio_today('cafecafe-0000-0000-0000-000000000001'))::text
     from memberships
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
-- MUST differ: their ids, their studio, their member, Stripe's own handles,
-- and the period INSTANTS — which are two separate transactions' now() and
-- differ by the milliseconds between them, exactly as created_at does. The
-- period is asserted below on its own terms instead of being dropped.
select expect_text('a cash membership and a Stripe membership are the same row',
  (select (
     (to_jsonb(a) - 'id' - 'studio_id' - 'member_id' - 'plan_id' - 'created_at'
       - 'updated_at' - 'stripe_customer_id' - 'stripe_subscription_id'
       - 'current_period_start' - 'current_period_end')
     =
     (to_jsonb(b) - 'id' - 'studio_id' - 'member_id' - 'plan_id' - 'created_at'
       - 'updated_at' - 'stripe_customer_id' - 'stripe_subscription_id'
       - 'current_period_start' - 'current_period_end')
   )::text
     from memberships a, memberships b
    where a.member_id = 'cafecafe-0000-0000-0000-00000000dd03'
      and b.member_id = 'cafecafe-0000-0000-0000-00000000dd02'), 'true');

-- THE TEETH THIS COMPARISON DID NOT HAVE. It passed for months while BOTH
-- sides wrote a null period: the Stripe half is driven by a
-- checkout.session.completed, whose object carries no current_period_*, and
-- the cash half wrote none at all. Two implementations agreeing proves nothing
-- when neither does the thing.
select expect_text('...and they both actually have a period, rather than agreeing on nothing',
  (select (a.current_period_end is not null and b.current_period_end is not null)::text
     from memberships a, memberships b
    where a.member_id = 'cafecafe-0000-0000-0000-00000000dd03'
      and b.member_id = 'cafecafe-0000-0000-0000-00000000dd02'), 'true');
select expect_text('...ending on the same day, whichever way the money arrived',
  (select ((a.current_period_end at time zone 'Asia/Manila')::date
         = (b.current_period_end at time zone 'Asia/Manila')::date)::text
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


-- =============================================================================
-- Migration 095 — a recurring membership has a PERIOD, and a cash studio can
-- see who owes it money
-- =============================================================================
-- activate_purchase() wrote status, price and credits and left the period
-- null. A recurring membership with no period is one nothing can bill, renew
-- or expire — and book_class()'s past-due allowance,
--   now() < coalesce(ms.current_period_end, now()) + grace,
-- collapses to `now() < now() + grace`, which is true for ever.
-- =============================================================================

-- A second studio's plan on a DIFFERENT interval, so the two are decided in
-- one run and nothing can pass by assuming a month.
insert into membership_plans (id, studio_id, name, type, price_cents, currency,
                              billing_interval, billing_interval_count, credits_per_period, status)
values ('cafecafe-0000-0000-0000-0000000000c9','cafecafe-0000-0000-0000-000000000002',
        'Quarterly Unlimited','recurring', 660000, 'PHP', 'quarter', 1, null, 'active'),
       ('cafecafe-0000-0000-0000-0000000000c8','cafecafe-0000-0000-0000-000000000001',
        'Weekly Pass','recurring', 40000, 'PHP', 'week', 2, 4, 'active');

insert into members (id, studio_id, first_name, last_name, email, joined_on, status, created_at) values
  ('cafecafe-0000-0000-0000-00000000df01','cafecafe-0000-0000-0000-000000000001','Perpetua','Monthly','perpetua@example.com', current_date - 40,'active', now()),
  ('cafecafe-0000-0000-0000-00000000df02','cafecafe-0000-0000-0000-000000000001','Fionn','Frozen','fionn@example.com', current_date - 40,'active', now()),
  ('cafecafe-0000-0000-0000-00000000df03','cafecafe-0000-0000-0000-000000000001','Wanda','Weekly','wanda@example.com', current_date - 40,'active', now()),
  ('cafecafe-0000-0000-0000-00000000df04','cafecafe-0000-0000-0000-000000000002','Quinn','Quarterly','quinn@example.com', current_date - 40,'active', now()),
  ('cafecafe-0000-0000-0000-00000000df05','cafecafe-0000-0000-0000-000000000001','Paddy','Paidup','paddy@example.com', current_date - 40,'active', now());

\echo ''
\echo '--- activation writes a period from the PLAN''S OWN interval ---'
set role authenticated;
select set_config('request.jwt.claim.sub','cafecafe-0000-0000-0000-0000000000a2',false);
select set_config('t.m1', (record_manual_payment(
  'cafecafe-0000-0000-0000-000000000001','cafecafe-0000-0000-0000-00000000df01',
  'plan', 250000, 'cash', p_plan_id => 'cafecafe-0000-0000-0000-0000000000c1')
  ->> 'membership_id'), false);
select set_config('t.mw', (record_manual_payment(
  'cafecafe-0000-0000-0000-000000000001','cafecafe-0000-0000-0000-00000000df03',
  'plan', 40000, 'cash', p_plan_id => 'cafecafe-0000-0000-0000-0000000000c8')
  ->> 'membership_id'), false);
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub','cafecafe-0000-0000-0000-0000000000a1',false);
select set_config('t.mq', (record_manual_payment(
  'cafecafe-0000-0000-0000-000000000002','cafecafe-0000-0000-0000-00000000df04',
  'plan', 660000, 'cash', p_plan_id => 'cafecafe-0000-0000-0000-0000000000c9')
  ->> 'membership_id'), false);
reset role;

select expect_true('a cash recurring membership has a period at all',
  (select current_period_start is not null and current_period_end is not null
     and renews_on is not null from memberships where id = current_setting('t.m1')::uuid));

-- The interval is the plan's, not a constant. A month, a fortnight and a
-- quarter, all decided in this one run.
select expect_num('a monthly plan ends one month out',
  (select ((current_period_end at time zone 'Asia/Manila')::date
           - (current_period_start at time zone 'Asia/Manila')::date)::bigint
     from memberships where id = current_setting('t.m1')::uuid),
  (select ((current_date + interval '1 month')::date - current_date)::bigint));
select expect_num('a two-week plan ends a fortnight out, not a month',
  (select ((current_period_end at time zone 'Asia/Manila')::date
           - (current_period_start at time zone 'Asia/Manila')::date)::bigint
     from memberships where id = current_setting('t.mw')::uuid), 14);
select expect_num('and the other studio''s quarterly plan runs three months',
  (select ((current_period_end at time zone 'Asia/Manila')::date
           - (current_period_start at time zone 'Asia/Manila')::date)::bigint
     from memberships where id = current_setting('t.mq')::uuid),
  (select ((current_date + interval '3 months')::date - current_date)::bigint));

select expect_true('renews_on is the period end as one of the studio''s own dates',
  (select renews_on = (current_period_end at time zone 'Asia/Manila')::date
     from memberships where id = current_setting('t.m1')::uuid));
-- Decision 12: a null credits_per_period is unlimited, so there is nothing to
-- reset and no reset date to invent.
select expect_null('an unlimited plan has no credit reset date',
  (select credits_reset_at::text from memberships where id = current_setting('t.mq')::uuid));
select expect_true('an allowance plan resets at the period boundary',
  (select credits_reset_at = current_period_end
     from memberships where id = current_setting('t.mw')::uuid));

-- A PACK STILL HAS NO PERIOD. Giving one a renewal date would invent a
-- renewal for something that does not renew.
set role authenticated;
select set_config('request.jwt.claim.sub','cafecafe-0000-0000-0000-0000000000a2',false);
select set_config('t.mp', (record_manual_payment(
  'cafecafe-0000-0000-0000-000000000001','cafecafe-0000-0000-0000-00000000df05',
  'plan', 900000, 'cash', p_plan_id => 'cafecafe-0000-0000-0000-0000000000c3')
  ->> 'membership_id'), false);
reset role;
select expect_null('a class pack still has no period end',
  (select current_period_end::text from memberships where id = current_setting('t.mp')::uuid));
select expect_null('and no renewal date',
  (select renews_on::text from memberships where id = current_setting('t.mp')::uuid));

\echo ''
\echo '--- a second payment ADVANCES the period, it does not sell a second membership ---'
select set_config('t.end1',
  (select current_period_end::text from memberships where id = current_setting('t.m1')::uuid), false);
set role authenticated;
select set_config('request.jwt.claim.sub','cafecafe-0000-0000-0000-0000000000a2',false);
select set_config('t.ren', record_manual_payment(
  'cafecafe-0000-0000-0000-000000000001','cafecafe-0000-0000-0000-00000000df01',
  'plan', 250000, 'cash', p_plan_id => 'cafecafe-0000-0000-0000-0000000000c1')::text, false);
reset role;

select expect_num('the member still holds exactly one membership on that plan',
  (select count(*) from memberships
    where member_id = 'cafecafe-0000-0000-0000-00000000df01'
      and plan_id = 'cafecafe-0000-0000-0000-0000000000c1'), 1);
select expect_text('and the payment renewed that one',
  (current_setting('t.ren')::jsonb ->> 'membership_id'), current_setting('t.m1'));
-- THE PERIOD ADVANCES FROM THE OLD END, NEVER FROM TODAY: the billing day a
-- member agreed to is the one they keep, whether they pay early or late.
-- As instants, not as text: jsonb renders a timestamptz in ISO-8601 and
-- ::text does not, so the same moment compares unequal as a string.
select expect_true('the new period starts where the old one ended',
  (current_setting('t.ren')::jsonb -> 'renewed' ->> 'period_start')::timestamptz
    = current_setting('t.end1')::timestamptz);
select expect_num('and it is one more interval, not two',
  (select ((current_period_end at time zone 'Asia/Manila')::date
           - (current_period_start at time zone 'Asia/Manila')::date)::bigint
     from memberships where id = current_setting('t.m1')::uuid),
  (select ((current_date + interval '2 months')::date
           - (current_date + interval '1 month')::date)::bigint));
select expect_text('the desk is told it is paid up',
  (current_setting('t.ren')::jsonb -> 'renewed' ->> 'still_owing'), 'false');
select expect_num('and the renewal is on the record',
  (select count(*) from membership_events
    where membership_id = current_setting('t.m1')::uuid and type = 'renewed'), 1);
-- Two payments, two rows, one membership. A studio reconciling the till needs
-- both; a member needs one membership.
select expect_num('both payments are recorded against it',
  (select count(*) from payments where membership_id = current_setting('t.m1')::uuid), 2);

-- A payment for a DIFFERENT plan is a plan change and still sells a membership.
set role authenticated;
select set_config('request.jwt.claim.sub','cafecafe-0000-0000-0000-0000000000a2',false);
select record_manual_payment(
  'cafecafe-0000-0000-0000-000000000001','cafecafe-0000-0000-0000-00000000df01',
  'plan', 40000, 'cash', p_plan_id => 'cafecafe-0000-0000-0000-0000000000c8');
reset role;
select expect_num('a different plan is a change, and makes its own membership',
  (select count(*) from memberships where member_id = 'cafecafe-0000-0000-0000-00000000df01'), 2);

\echo ''
\echo '--- a lapsed period becomes past_due, and §7.3 takes it from there ---'
-- Fionn is frozen and overdue; Wanda has simply lapsed; Quinn is on Stripe.
update memberships set current_period_end = now() - interval '4 days',
       renews_on = (now() - interval '4 days')::date
 where id = current_setting('t.mw')::uuid;
set role authenticated;
select set_config('request.jwt.claim.sub','cafecafe-0000-0000-0000-0000000000a2',false);
select set_config('t.mf', (record_manual_payment(
  'cafecafe-0000-0000-0000-000000000001','cafecafe-0000-0000-0000-00000000df02',
  'plan', 250000, 'cash', p_plan_id => 'cafecafe-0000-0000-0000-0000000000c1')
  ->> 'membership_id'), false);
reset role;
update memberships set current_period_end = now() - interval '6 days',
       renews_on = (now() - interval '6 days')::date,
       freeze_start = current_date - 3, freeze_end = current_date + 25
 where id = current_setting('t.mf')::uuid;
update memberships set current_period_end = now() - interval '8 days',
       renews_on = (now() - interval '8 days')::date,
       stripe_subscription_id = 'sub_quarterly'
 where id = current_setting('t.mq')::uuid;

select expect_num('the sweep marks the lapsed one and only it',
  (sweep_membership_periods() ->> 'marked_past_due')::bigint, 1);
select expect_text('the lapsed membership is past due',
  (select status::text from memberships where id = current_setting('t.mw')::uuid), 'past_due');
-- §7.4: a frozen membership is paused, not in arrears. Its period end means
-- nothing while the freeze runs.
select expect_text('a frozen membership is left alone',
  (select status::text from memberships where id = current_setting('t.mf')::uuid), 'active');
-- Stripe rolls its own period through customer.subscription.updated; sweeping
-- those here would mark a member past due for the minutes between a successful
-- renewal and its webhook arriving.
select expect_text('and a subscription-backed one is left to its webhook',
  (select status::text from memberships where id = current_setting('t.mq')::uuid), 'active');
select expect_num('the lapse is on the record',
  (select count(*) from membership_events
    where membership_id = current_setting('t.mw')::uuid and type = 'period_lapsed'), 1);

\echo ''
\echo '--- WHO OWES THE STUDIO MONEY ---'
set role authenticated;
select set_config('request.jwt.claim.sub','cafecafe-0000-0000-0000-0000000000a2',false);
select set_config('t.due', memberships_due('cafecafe-0000-0000-0000-000000000001', 7)::text, false);

select expect_text('the studio has people who owe it',
  current_setting('t.due')::jsonb ->> 'state', 'ok');
select expect_num('the lapsed member is on the list',
  (select count(*) from jsonb_array_elements(current_setting('t.due')::jsonb -> 'rows') r
    where (r ->> 'member_name') = 'Wanda Weekly'), 1);
select expect_num('the frozen one is not',
  (select count(*) from jsonb_array_elements(current_setting('t.due')::jsonb -> 'rows') r
    where (r ->> 'member_name') = 'Fionn Frozen'), 0);
select expect_num('nor is anybody who is paid up two months ahead',
  (select count(*) from jsonb_array_elements(current_setting('t.due')::jsonb -> 'rows') r
    where (r ->> 'member_name') = 'Perpetua Monthly'), 0);
select expect_num('nor a class pack, which does not renew',
  (select count(*) from jsonb_array_elements(current_setting('t.due')::jsonb -> 'rows') r
    where (r ->> 'plan_name') = '10-Class Pack'), 0);
select expect_num('every row on the list is overdue or due inside the window',
  (select count(*) from jsonb_array_elements(current_setting('t.due')::jsonb -> 'rows') r
    where (r ->> 'due_on')::date > current_date + 7), 0);
select expect_num('it says how many days overdue, from the studio''s own date',
  (select (r ->> 'days_overdue')::bigint from jsonb_array_elements(current_setting('t.due')::jsonb -> 'rows') r
    where (r ->> 'member_name') = 'Wanda Weekly'), 4);
-- §7.1: the price is the membership's snapshot, never the plan's. A chase list
-- quoting a plan's new price would undo at the counter the one rule that stops
-- an edit repricing everybody.
-- AS POSTGRES, NOT AS THE DESK. plans_manager_write is manager-up, and a
-- refused UPDATE does not raise — it changes nothing. Run as the front-desk
-- session this update silently did nothing, the plan price stayed at 40000,
-- and the assertion below passed against BOTH the right answer and the wrong
-- one. Caught by reverting the fix and watching the test not notice.
reset role;
update membership_plans set price_cents = 999999 where id = 'cafecafe-0000-0000-0000-0000000000c8';
select expect_num('the plan price really did move, or the next assertion proves nothing',
  (select price_cents::bigint from membership_plans
    where id = 'cafecafe-0000-0000-0000-0000000000c8'), 999999);
set role authenticated;
select set_config('request.jwt.claim.sub','cafecafe-0000-0000-0000-0000000000a2',false);
select expect_num('what they owe is the price they agreed, not the plan''s price today',
  (select (r ->> 'owed_cents')::bigint from jsonb_array_elements(
     memberships_due('cafecafe-0000-0000-0000-000000000001', 7) -> 'rows') r
    where (r ->> 'member_name') = 'Wanda Weekly'), 40000);
select expect_true('and every row carries a way to take the money from it',
  (select bool_and((r ->> 'record_href') like '/members/%/payment?plan=%')
     from jsonb_array_elements(current_setting('t.due')::jsonb -> 'rows') r));
reset role;

-- The other studio in the same run: its own list, and none of studio one's.
set role authenticated;
select set_config('request.jwt.claim.sub','cafecafe-0000-0000-0000-0000000000a1',false);
select expect_num('the other studio sees none of the first studio''s debtors',
  (select count(*) from jsonb_array_elements(
     memberships_due('cafecafe-0000-0000-0000-000000000002', 7) -> 'rows') r
    where (r ->> 'member_name') in ('Wanda Weekly','Fionn Frozen','Perpetua Monthly')), 0);
reset role;

-- A payment so late that one interval forward is STILL in the past leaves the
-- membership owing, and says so. Rolling to today instead would forgive the
-- arrears and drift the billing day in the same stroke.
update memberships set current_period_end = now() - interval '10 weeks',
       current_period_start = now() - interval '12 weeks', status = 'past_due'
 where id = current_setting('t.mw')::uuid;
set role authenticated;
select set_config('request.jwt.claim.sub','cafecafe-0000-0000-0000-0000000000a2',false);
select set_config('t.late', record_manual_payment(
  'cafecafe-0000-0000-0000-000000000001','cafecafe-0000-0000-0000-00000000df03',
  'plan', 40000, 'cash', p_plan_id => 'cafecafe-0000-0000-0000-0000000000c8')::text, false);
reset role;
select expect_text('a payment against months of arrears says it is still owing',
  (current_setting('t.late')::jsonb -> 'renewed' ->> 'still_owing'), 'true');
select expect_text('and the membership stays past due rather than looking settled',
  (select status::text from memberships where id = current_setting('t.mw')::uuid), 'past_due');
select expect_true('and they are still on the list',
  (select count(*) > 0 from jsonb_array_elements(
     (select memberships_due('cafecafe-0000-0000-0000-000000000001', 7) from studios limit 1) -> 'rows') r
    where (r ->> 'member_name') = 'Wanda Weekly'));

\echo ''
\echo '--- who may see it ---'
-- A member is every signed-in person as far as the authenticated role knows.
set role authenticated;
select set_config('request.jwt.claim.sub','cafecafe-0000-0000-0000-0000000000d9',false);
select expect_raises('a stranger cannot see who owes the studio money',
  $$ select memberships_due('cafecafe-0000-0000-0000-000000000001', 7) $$, 'PT403');
select expect_raises('nor renew somebody''s membership',
  $$ select advance_membership_period(current_setting('t.m1')::uuid) $$, 'PT403');
reset role;
set role anon;
select expect_raises('and anon reaches neither',
  $$ select memberships_due('cafecafe-0000-0000-0000-000000000001', 7) $$, '42501');
reset role;

-- Only a recurring membership has a period to advance. A pack renewed by
-- accident would silently gain a renewal date and start appearing on a chase
-- list for money nobody owes.
set role authenticated;
select set_config('request.jwt.claim.sub','cafecafe-0000-0000-0000-0000000000a2',false);
select expect_raises('a class pack cannot be renewed as though it had a period',
  $$ select advance_membership_period(current_setting('t.mp')::uuid) $$, 'PT422');
select expect_raises('nor can a frozen membership be renewed by taking cash',
  $$ select advance_membership_period(current_setting('t.mf')::uuid) $$, 'PT409');
reset role;

select 'ALL MANUAL PAYMENT TESTS PASSED' as result;
