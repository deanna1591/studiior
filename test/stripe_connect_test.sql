-- =============================================================================
-- Stripe Connect — migrations 036, 037, 038
-- =============================================================================
-- UUID space 5757, checked free. Run after `supabase db reset`.
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

-- A correctly signed Stripe delivery, so the tests exercise the real gate
-- rather than a bypass. Any test that wants to be refused signs it wrongly.
create or replace function sig(body text, secret text default 'whsec_test')
returns text language sql as $$
  select 't=' || extract(epoch from now())::bigint || ',v1=' ||
         encode(extensions.hmac(extract(epoch from now())::bigint || '.' || body,
                                secret, 'sha256'), 'hex')
$$;

select set_config('app.stripe_webhook_secret', 'whsec_test', false);

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values ('57575757-0000-0000-0000-0000000000a1');
insert into profiles (id, email) values ('57575757-0000-0000-0000-0000000000a1','sc-owner@example.com');

insert into studios (id, name, slug, timezone, currency, status, stripe_account_id) values
  ('57575757-0000-0000-0000-000000000001','Stripe A','stripe-a','Europe/Prague','CZK','active','acct_test_5757a'),
  ('57575757-0000-0000-0000-000000000002','Stripe B','stripe-b','Europe/Prague','CZK','active','acct_test_5757b');
insert into studio_settings (studio_id, payment_grace_days, dropin_payment_window_minutes) values
  ('57575757-0000-0000-0000-000000000001', 7, 15),
  ('57575757-0000-0000-0000-000000000002', 7, 15);
insert into locations (id, studio_id, name, is_primary) values
  ('57575757-0000-0000-0000-00000000000c','57575757-0000-0000-0000-000000000001','Main',true);
insert into studio_staff (studio_id, user_id, email, role) values
  ('57575757-0000-0000-0000-000000000001','57575757-0000-0000-0000-0000000000a1','sc-owner@example.com','owner');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('57575757-0000-0000-0000-00000000ee01','57575757-0000-0000-0000-000000000001',
   '57575757-0000-0000-0000-00000000000c','Studio A',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('57575757-0000-0000-0000-00000000cc01','57575757-0000-0000-0000-000000000001','Reformer',50,10);

insert into auth.users (id) values ('57575757-0000-0000-0000-0000000000b1');
insert into profiles (id, email) values ('57575757-0000-0000-0000-0000000000b1','sc-mem@example.com');
insert into members (id, studio_id, user_id, first_name, last_name, email, joined_on, status, waiver_signed_at) values
  ('57575757-0000-0000-0000-00000000dd01','57575757-0000-0000-0000-000000000001',
   '57575757-0000-0000-0000-0000000000b1','Paula','Payer','paula@example.com',
   current_date - 30, 'active', now());

insert into membership_plans (id, studio_id, name, type, price_cents, currency,
                              billing_interval, credits_per_period, status)
values ('57575757-0000-0000-0000-0000000000c1','57575757-0000-0000-0000-000000000001',
        'Unlimited Monthly','recurring', 8900, 'CZK', 'month', null, 'active');

insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               instructor_id, capacity, starts_at, ends_at, status)
values ('57575757-0000-0000-0000-00000000f001','57575757-0000-0000-0000-000000000001',
        '57575757-0000-0000-0000-00000000000c','57575757-0000-0000-0000-00000000cc01',
        '57575757-0000-0000-0000-00000000ee01','Reformer Flow', null, 10,
        now() + interval '3 days', now() + interval '3 days 50 minutes', 'scheduled'),
       ('57575757-0000-0000-0000-00000000f002','57575757-0000-0000-0000-000000000001',
        '57575757-0000-0000-0000-00000000000c','57575757-0000-0000-0000-00000000cc01',
        '57575757-0000-0000-0000-00000000ee01','Reformer Flow', null, 10,
        now() + interval '4 days', now() + interval '4 days 50 minutes', 'scheduled');

-- =============================================================================
-- 1. The gate: nothing is read before the signature is checked
-- =============================================================================
do $$
begin
  perform stripe_webhook('{"id":"evt_forged","type":"invoice.paid","account":"acct_test_5757a"}',
                         't=1,v1=deadbeef');
  raise exception 'FAIL  a forged signature was accepted';
exception when sqlstate 'PT401' then
  raise notice 'PASS  a forged signature is refused';
end $$;

do $$
declare body text := '{"id":"evt_wrongsecret","type":"invoice.paid","account":"acct_test_5757a"}';
begin
  perform stripe_webhook(body, sig(body, 'whsec_someone_elses'));
  raise exception 'FAIL  a signature from the wrong secret was accepted';
exception when sqlstate 'PT401' then
  raise notice 'PASS  a signature from the wrong secret is refused';
end $$;

select expect_num('nothing was recorded for either refusal',
  (select count(*) from stripe_events where id in ('evt_forged','evt_wrongsecret')), 0);

-- =============================================================================
-- 2. The tenant comes from `account`, never from metadata
-- =============================================================================
select set_config('t.unknown',
  '{"id":"evt_unknown","type":"checkout.session.completed","livemode":false,'
  '"account":"acct_test_NOBODY","data":{"object":{"id":"cs_1","metadata":'
  '{"kind":"dropin","studio_id":"57575757-0000-0000-0000-000000000001"}}}}', false);

select expect_text('an event for an unknown account is rejected, not guessed at',
  (select stripe_webhook(current_setting('t.unknown'), sig(current_setting('t.unknown'))) ->> 'status'),
  'unknown_account');
select expect_num('...and it is recorded rather than dropped',
  (select count(*) from stripe_events where id = 'evt_unknown' and studio_id is null), 1);
select expect_num('...and its metadata did NOT attach it to the studio it named',
  (select count(*) from stripe_events
    where id = 'evt_unknown' and studio_id = '57575757-0000-0000-0000-000000000001'), 0);

-- Metadata naming a different studio than the account resolved to.
select set_config('t.mismatch',
  '{"id":"evt_mismatch","type":"checkout.session.completed","livemode":false,'
  '"account":"acct_test_5757a","data":{"object":{"id":"cs_2","metadata":'
  '{"kind":"dropin","studio_id":"57575757-0000-0000-0000-000000000002"}}}}', false);
select expect_text('metadata that disagrees with the account is refused',
  (select stripe_webhook(current_setting('t.mismatch'), sig(current_setting('t.mismatch'))) ->> 'status'),
  'tenant_mismatch');

-- =============================================================================
-- 3. A purchase, and the price snapshot that must survive the studio editing it
-- =============================================================================
select set_config('t.buy',
  '{"id":"evt_buy","type":"checkout.session.completed","livemode":false,'
  '"account":"acct_test_5757a","data":{"object":{"id":"cs_buy","currency":"czk",'
  '"amount_total":8900,"customer":"cus_1","subscription":"sub_1","metadata":'
  '{"kind":"plan","studio_id":"57575757-0000-0000-0000-000000000001",'
  '"member_id":"57575757-0000-0000-0000-00000000dd01",'
  '"plan_id":"57575757-0000-0000-0000-0000000000c1","price_cents":"8900"}}}}', false);

select expect_text('a completed checkout creates the membership',
  (select stripe_webhook(current_setting('t.buy'), sig(current_setting('t.buy'))) ->> 'result'),
  'membership_created');
select expect_num('...at the price the member agreed to',
  (select price_cents from memberships where member_id = '57575757-0000-0000-0000-00000000dd01'), 8900);
select expect_num('...and it is audited in membership_events',
  (select count(*) from membership_events where type = 'created'
    and studio_id = '57575757-0000-0000-0000-000000000001'), 1);

-- §7.1: editing the plan must never reprice anybody already on it.
update membership_plans set price_cents = 12900
 where id = '57575757-0000-0000-0000-0000000000c1';
select expect_num('the studio raises the plan price to 12900',
  (select price_cents from membership_plans where id = '57575757-0000-0000-0000-0000000000c1'), 12900);
select expect_num('...and the existing member still pays 8900',
  (select price_cents from memberships where member_id = '57575757-0000-0000-0000-00000000dd01'), 8900);

-- =============================================================================
-- 4. A replay is a no-op
-- =============================================================================
select expect_text('the same event id a second time is a duplicate',
  (select stripe_webhook(current_setting('t.buy'), sig(current_setting('t.buy'))) ->> 'status'),
  'duplicate');
select expect_num('...and it did not create a second membership',
  (select count(*) from memberships where member_id = '57575757-0000-0000-0000-00000000dd01'), 1);
select expect_num('...nor a second payment row',
  (select count(*) from payments where studio_id = '57575757-0000-0000-0000-000000000001'), 1);

-- =============================================================================
-- 5. §7.3 — a failed payment blocks NEW bookings and leaves existing ones
-- =============================================================================
-- She books before anything goes wrong.
update memberships
   set current_period_end = now() + interval '1 day',
       credits_remaining = null
 where member_id = '57575757-0000-0000-0000-00000000dd01';

set role authenticated;
select set_config('request.jwt.claim.sub','57575757-0000-0000-0000-0000000000b1',false);
select set_config('t.booking',
  (select (book_class('57575757-0000-0000-0000-00000000f001',
                      '57575757-0000-0000-0000-00000000dd01','member',null,null)).booking_id::text), false);
reset role;
select expect_text('she books a class while her membership is good',
  (select status::text from bookings where id = current_setting('t.booking')::uuid), 'booked');

select set_config('t.fail',
  '{"id":"evt_fail","type":"invoice.payment_failed","livemode":false,'
  '"account":"acct_test_5757a","data":{"object":{"id":"in_1","subscription":"sub_1",'
  '"amount_due":8900,"currency":"czk","attempt_count":1}}}', false);
select expect_text('the failed invoice moves her to past_due',
  (select stripe_webhook(current_setting('t.fail'), sig(current_setting('t.fail'))) ->> 'result'),
  'past_due');
select expect_text('...and that is what the row says',
  (select status::text from memberships where member_id = '57575757-0000-0000-0000-00000000dd01'), 'past_due');
-- Three, not one: §7.3 emails on day 0, day 3 and day 6, and
-- queue_payment_failed() schedules all three at once. Asserting 1 here was my
-- mistake, not the function's — the rule is the schedule.
select expect_num('...and migration 031''s notification finally has a caller',
  (select count(*) from notifications
    where member_id = '57575757-0000-0000-0000-00000000dd01' and template_key = 'payment_failed'), 3);
select expect_num('...queued for day 0, 3 and 6 as §7.3 asks',
  (select count(distinct date_trunc('day', scheduled_for)) from notifications
    where member_id = '57575757-0000-0000-0000-00000000dd01' and template_key = 'payment_failed'), 3);

select expect_text('the class she already booked still stands',
  (select status::text from bookings where id = current_setting('t.booking')::uuid), 'booked');

-- Inside grace she can still book: §7.3 blocks only once the grace runs out.
set role authenticated;
select set_config('request.jwt.claim.sub','57575757-0000-0000-0000-0000000000b1',false);
select expect_text('inside the grace period she can still book',
  (select (book_class('57575757-0000-0000-0000-00000000f002',
                      '57575757-0000-0000-0000-00000000dd01','member',null,null)).status::text), 'booked');
reset role;

-- Past the grace period, a new booking is refused.
update memberships set current_period_end = now() - interval '30 days'
 where member_id = '57575757-0000-0000-0000-00000000dd01';
delete from bookings where occurrence_id = '57575757-0000-0000-0000-00000000f002';
update class_occurrences set booked_count = 0 where id = '57575757-0000-0000-0000-00000000f002';

set role authenticated;
select set_config('request.jwt.claim.sub','57575757-0000-0000-0000-0000000000b1',false);
select expect_text('past the grace period a NEW booking is refused',
  (select (book_class('57575757-0000-0000-0000-00000000f002',
                      '57575757-0000-0000-0000-00000000dd01','member',null,null)).payment_source::text),
  'drop_in');
reset role;
select expect_text('and the class she booked earlier is still hers',
  (select status::text from bookings where id = current_setting('t.booking')::uuid), 'booked');

-- =============================================================================
-- 6. A drop-in holds its seat while the member pays
-- =============================================================================
insert into auth.users (id) values ('57575757-0000-0000-0000-0000000000b2');
insert into profiles (id, email) values ('57575757-0000-0000-0000-0000000000b2','sc-drop@example.com');
insert into members (id, studio_id, user_id, first_name, last_name, email, joined_on, status, waiver_signed_at)
values ('57575757-0000-0000-0000-00000000dd02','57575757-0000-0000-0000-000000000001',
        '57575757-0000-0000-0000-0000000000b2','Dana','Dropin','dana@example.com',
        current_date - 5, 'active', now());

insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               capacity, starts_at, ends_at, status)
values ('57575757-0000-0000-0000-00000000f003','57575757-0000-0000-0000-000000000001',
        '57575757-0000-0000-0000-00000000000c','57575757-0000-0000-0000-00000000cc01',
        '57575757-0000-0000-0000-00000000ee01','Reformer Flow', 1,
        now() + interval '5 days', now() + interval '5 days 50 minutes', 'scheduled'),
       ('57575757-0000-0000-0000-00000000f004','57575757-0000-0000-0000-000000000001',
        '57575757-0000-0000-0000-00000000000c','57575757-0000-0000-0000-00000000cc01',
        '57575757-0000-0000-0000-00000000ee01','Reformer Flow', 5,
        now() + interval '5 days 2 hours', now() + interval '5 days 3 hours', 'scheduled'),
       -- A separate class for the payment test: f004 is spent by the
       -- daily-limit assertion above, which books it for real.
       ('57575757-0000-0000-0000-00000000f005','57575757-0000-0000-0000-000000000001',
        '57575757-0000-0000-0000-00000000000c','57575757-0000-0000-0000-00000000cc01',
        '57575757-0000-0000-0000-00000000ee01','Reformer Flow', 5,
        now() + interval '6 days', now() + interval '6 days 50 minutes', 'scheduled');

update studio_settings set max_bookings_per_day = 1
 where studio_id = '57575757-0000-0000-0000-000000000001';

set role authenticated;
select set_config('request.jwt.claim.sub','57575757-0000-0000-0000-0000000000b2',false);
select set_config('t.hold',
  (select (book_class('57575757-0000-0000-0000-00000000f003',
                      '57575757-0000-0000-0000-00000000dd02','member',null,null)).booking_id::text), false);
reset role;

select expect_text('a member drop-in at a connected studio holds rather than books',
  (select status::text from bookings where id = current_setting('t.hold')::uuid), 'pending_payment');
select expect_num('...and the seat is held so nobody takes it mid-checkout',
  (select booked_count from class_occurrences where id = '57575757-0000-0000-0000-00000000f003'), 1);

-- The daily limit is 1. A held seat must not have spent it.
set role authenticated;
select set_config('request.jwt.claim.sub','57575757-0000-0000-0000-0000000000b2',false);
select expect_text('a held seat does not use up the daily limit',
  (select coalesce((book_class('57575757-0000-0000-0000-00000000f004',
                      '57575757-0000-0000-0000-00000000dd02','member',null,null)).failure_reason,
                   'not refused')), 'not refused');
reset role;

-- But it IS a live booking for its own class: no two checkouts for one seat.
set role authenticated;
select set_config('request.jwt.claim.sub','57575757-0000-0000-0000-0000000000b2',false);
select expect_text('...but a second checkout for the same class is refused',
  (select (book_class('57575757-0000-0000-0000-00000000f003',
                      '57575757-0000-0000-0000-00000000dd02','member',null,null)).failure_reason), 'already_booked');
reset role;

-- No confirmation email for a class nobody has paid for. The trigger fires on
-- status = 'booked' only, so this falls out rather than being special-cased.
select expect_num('a held seat sends no booking confirmation',
  (select count(*) from notifications
    where member_id = '57575757-0000-0000-0000-00000000dd02' and template_key = 'booking_confirmed'), 0);

-- Somebody waits behind the held seat.
set role authenticated;
select set_config('request.jwt.claim.sub','57575757-0000-0000-0000-0000000000b1',false);
select expect_text('another member joins the waitlist behind it',
  (select (book_class('57575757-0000-0000-0000-00000000f003',
                      '57575757-0000-0000-0000-00000000dd01','member',null,null)).status::text), 'waitlisted');
reset role;

-- The window runs out.
update bookings set booked_at = now() - interval '45 minutes'
 where id = current_setting('t.hold')::uuid;
select set_config('t.sweep', (select sweep_unpaid_dropins()::text), false);

select expect_text('the sweep cancels the abandoned hold',
  (select status::text from bookings where id = current_setting('t.hold')::uuid), 'cancelled');
select expect_num('...frees the seat',
  (select booked_count from class_occurrences where id = '57575757-0000-0000-0000-00000000f003'), 0);
-- The whole reason the sweep goes through cancel_booking() rather than doing
-- the update itself: a freed seat nobody is offered is worse than a held one.
select expect_num('...and offers it to the person waiting behind it',
  (select count(*) from waitlist_offers where occurrence_id = '57575757-0000-0000-0000-00000000f003'), 1);

-- A seat that was only ever held is not a late cancellation against the member.
select expect_num('an abandoned hold is never recorded as a late cancel',
  (select count(*) from bookings where id = current_setting('t.hold')::uuid
     and status = 'late_cancelled'), 0);

-- And when payment DOES land, the hold becomes a real booking and only then
-- does the member hear about it.
set role authenticated;
select set_config('request.jwt.claim.sub','57575757-0000-0000-0000-0000000000b2',false);
select set_config('t.hold2',
  (select (book_class('57575757-0000-0000-0000-00000000f005',
                      '57575757-0000-0000-0000-00000000dd02','member',null,null)).booking_id::text), false);
reset role;
select set_config('t.paid',
  '{"id":"evt_dropin","type":"checkout.session.completed","livemode":false,'
  '"account":"acct_test_5757a","data":{"object":{"id":"cs_drop","currency":"czk",'
  '"amount_total":2500,"payment_intent":"pi_1","metadata":{"kind":"dropin",'
  '"studio_id":"57575757-0000-0000-0000-000000000001",'
  '"member_id":"57575757-0000-0000-0000-00000000dd02",'
  '"booking_id":"' || current_setting('t.hold2') || '"}}}}', false);

select expect_text('paying turns the hold into a booking',
  (select stripe_webhook(current_setting('t.paid'), sig(current_setting('t.paid'))) ->> 'result'), 'dropin_paid');
select expect_text('...the booking is confirmed',
  (select status::text from bookings where id = current_setting('t.hold2')::uuid), 'booked');
select expect_num('...the confirmation goes out only now that it is true',
  (select count(*) from notifications
    where member_id = '57575757-0000-0000-0000-00000000dd02' and template_key = 'booking_confirmed'), 1);
select expect_num('...and the money is recorded against the booking',
  (select count(*) from payments where booking_id = current_setting('t.hold2')::uuid
     and status = 'succeeded'), 1);

select 'ALL STRIPE CONNECT TESTS PASSED' as result;
