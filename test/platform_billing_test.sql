-- =============================================================================
-- Platform billing — Studiior charging the studio. Migrations 044/045/046.
-- =============================================================================
-- UUID space b111, checked free. Run after `supabase db reset`.
--
-- The lifecycle is driven through sweep_platform_billing() rather than by
-- setting statuses by hand, so what is tested is the transition the cron will
-- actually make.
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

create or replace function psig(body text, secret text default 'whsec_platform')
returns text language sql as $$
  select 't=' || extract(epoch from now())::bigint || ',v1=' ||
         encode(extensions.hmac(extract(epoch from now())::bigint || '.' || body,
                                secret, 'sha256'), 'hex')
$$;
select set_config('app.stripe_platform_webhook_secret','whsec_platform',false);
select set_config('app.stripe_webhook_secret','whsec_connect',false);

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('b111b111-0000-0000-0000-0000000000a1'),
  ('b111b111-0000-0000-0000-0000000000a2'),
  ('b111b111-0000-0000-0000-0000000000b1');
insert into profiles (id, email, full_name) values
  ('b111b111-0000-0000-0000-0000000000a1','bill-owner@example.com','Bea Owner'),
  ('b111b111-0000-0000-0000-0000000000a2','bill-desk@example.com','Des Kay'),
  ('b111b111-0000-0000-0000-0000000000b1','bill-mem@example.com','Mem Ber');

insert into studios (id, name, slug, timezone, currency, status) values
  ('b111b111-0000-0000-0000-000000000001','Billing Studio','billing-test','Europe/Prague','CZK','active');
insert into studio_settings (studio_id) values ('b111b111-0000-0000-0000-000000000001');
insert into locations (id, studio_id, name, is_primary) values
  ('b111b111-0000-0000-0000-00000000000c','b111b111-0000-0000-0000-000000000001','Main',true);
insert into studio_staff (studio_id, user_id, email, role) values
  ('b111b111-0000-0000-0000-000000000001','b111b111-0000-0000-0000-0000000000a1','bill-owner@example.com','owner'),
  ('b111b111-0000-0000-0000-000000000001','b111b111-0000-0000-0000-0000000000a2','bill-desk@example.com','front_desk');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('b111b111-0000-0000-0000-00000000ee01','b111b111-0000-0000-0000-000000000001',
   'b111b111-0000-0000-0000-00000000000c','Studio A',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('b111b111-0000-0000-0000-00000000cc01','b111b111-0000-0000-0000-000000000001','Reformer',50,10);
insert into members (id, studio_id, user_id, first_name, last_name, email, joined_on, status, waiver_signed_at) values
  ('b111b111-0000-0000-0000-00000000dd01','b111b111-0000-0000-0000-000000000001',
   'b111b111-0000-0000-0000-0000000000b1','Mem','Ber','memb@example.com', current_date - 30, 'active', now());
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               capacity, starts_at, ends_at, status) values
  ('b111b111-0000-0000-0000-00000000f001','b111b111-0000-0000-0000-000000000001',
   'b111b111-0000-0000-0000-00000000000c','b111b111-0000-0000-0000-00000000cc01',
   'b111b111-0000-0000-0000-00000000ee01','Reformer', 10,
   now() + interval '2 days', now() + interval '2 days 50 minutes', 'scheduled'),
  ('b111b111-0000-0000-0000-00000000f002','b111b111-0000-0000-0000-000000000001',
   'b111b111-0000-0000-0000-00000000000c','b111b111-0000-0000-0000-00000000cc01',
   'b111b111-0000-0000-0000-00000000ee01','Reformer', 10,
   now() + interval '3 days', now() + interval '3 days 50 minutes', 'scheduled');
insert into membership_plans (id, studio_id, name, type, price_cents, currency, status) values
  ('b111b111-0000-0000-0000-0000000000c1','b111b111-0000-0000-0000-000000000001',
   'Drop-in','drop_in', 30000, 'CZK', 'active');

-- =============================================================================
-- 1. A studio starts on a trial, stamped by the trigger, with no card
-- =============================================================================
select expect_text('a new studio starts on trial',
  (select status::text from platform_subscriptions
    where studio_id = 'b111b111-0000-0000-0000-000000000001'), 'trialing');
select expect_num('...for thirty days',
  (select extract(day from trial_ends_at - now())::int from platform_subscriptions
    where studio_id = 'b111b111-0000-0000-0000-000000000001'), 29);
select expect_text('...with no card, and not locked',
  (select studio_is_locked('b111b111-0000-0000-0000-000000000001')::text), 'false');
select expect_num('...at seventy-nine dollars whatever the studio charges its own members',
  (select price_cents from platform_subscriptions
    where studio_id = 'b111b111-0000-0000-0000-000000000001'), 7900);
select expect_text('...in USD, not the studio''s CZK',
  (select currency from platform_subscriptions
    where studio_id = 'b111b111-0000-0000-0000-000000000001'), 'USD');

-- =============================================================================
-- 2. In grace, everything still works
-- =============================================================================
-- The trial lapses. The sweep starts the fourteen days rather than locking.
update platform_subscriptions set trial_ends_at = now() - interval '1 day'
 where studio_id = 'b111b111-0000-0000-0000-000000000001';
select set_config('t.sweep1', (select sweep_platform_billing()::text), false);

select expect_text('a lapsed trial goes past_due, not straight to locked',
  (select status::text from platform_subscriptions
    where studio_id = 'b111b111-0000-0000-0000-000000000001'), 'past_due');
select expect_text('...and is still not locked',
  (select studio_is_locked('b111b111-0000-0000-0000-000000000001')::text), 'false');
select expect_num('...with a fortnight to sort it out',
  (select extract(day from grace_ends_at - now())::int from platform_subscriptions
    where studio_id = 'b111b111-0000-0000-0000-000000000001'), 12);

-- The whole point of grace: the studio keeps running.
set role authenticated;
select set_config('request.jwt.claim.sub','b111b111-0000-0000-0000-0000000000b1',false);
select set_config('t.booking',
  (select (book_class('b111b111-0000-0000-0000-00000000f001',
                      'b111b111-0000-0000-0000-00000000dd01','member',null,null)).booking_id::text), false);
reset role;
select expect_text('a member can still book during grace',
  (select status::text from bookings where id = current_setting('t.booking')::uuid), 'booked');

set role authenticated;
select set_config('request.jwt.claim.sub','b111b111-0000-0000-0000-0000000000a2',false);
select expect_text('front desk can still record a payment during grace',
  (select (record_manual_payment('b111b111-0000-0000-0000-000000000001',
             'b111b111-0000-0000-0000-00000000dd01','other', 30000, 'cash') ->> 'payment_id')
          is not null)::text, 'true');
reset role;

-- =============================================================================
-- 3. The warnings are loud, because lockout stops classes running
-- =============================================================================
-- Day 1 of grace.
update platform_subscriptions set grace_ends_at = now() + interval '13 days'
 where studio_id = 'b111b111-0000-0000-0000-000000000001';
select sweep_platform_billing();
select expect_num('the owner is emailed on day one of grace',
  (select count(*) from notifications
    where studio_id = 'b111b111-0000-0000-0000-000000000001'
      and template_key = 'platform_billing_warning'), 1);
select expect_text('...addressed to the owner, not to a member',
  (select recipient_type || ':' || (user_id = 'b111b111-0000-0000-0000-0000000000a1')::text
     from notifications where template_key = 'platform_billing_warning' limit 1), 'staff:true');

-- Running the sweep again the same day must not email them twice.
select sweep_platform_billing();
select expect_num('...and a second sweep the same day does not email again',
  (select count(*) from notifications
    where studio_id = 'b111b111-0000-0000-0000-000000000001'
      and template_key = 'platform_billing_warning'), 1);

-- Day 12 and day 14 are separate warnings.
update platform_subscriptions set grace_ends_at = now() + interval '2 days'
 where studio_id = 'b111b111-0000-0000-0000-000000000001';
select sweep_platform_billing();
update platform_subscriptions set grace_ends_at = now() + interval '1 hour'
 where studio_id = 'b111b111-0000-0000-0000-000000000001';
select sweep_platform_billing();
select expect_num('days 1, 12 and 14 are three separate warnings',
  (select count(*) from notifications
    where studio_id = 'b111b111-0000-0000-0000-000000000001'
      and template_key = 'platform_billing_warning'), 3);

-- And it renders as an email to a person, not to a member who does not exist.
select expect_text('a staff-addressed warning renders to the owner''s address',
  (select to_email from render_notification(
     (select id from notifications where template_key = 'platform_billing_warning'
       order by created_at limit 1))), 'bill-owner@example.com');
select expect_text('...and offers billing, not a member''s email settings',
  (select (text_body like '%/billing%' and text_body not like '%/settings%')::text
     from render_notification(
       (select id from notifications where template_key = 'platform_billing_warning'
         order by created_at limit 1))), 'true');

-- =============================================================================
-- 4. Lockout — and what survives it
-- =============================================================================
-- Row counts BEFORE, so "nothing was lost" is a measurement rather than a hope.
select set_config('t.before',
  (select jsonb_build_object(
     'members',  (select count(*) from members  where studio_id = 'b111b111-0000-0000-0000-000000000001'),
     'bookings', (select count(*) from bookings where studio_id = 'b111b111-0000-0000-0000-000000000001'),
     'classes',  (select count(*) from class_occurrences where studio_id = 'b111b111-0000-0000-0000-000000000001'),
     'payments', (select count(*) from payments where studio_id = 'b111b111-0000-0000-0000-000000000001'))::text), false);

-- A positive control FIRST, while the studio is only in grace. Asserting that a
-- lookup returns zero rows proves nothing unless the same lookup returns one
-- when it should — otherwise a mistyped code would pass the lockout test.
select set_config('t.code_ok',
  (select checkin_code_for('b111b111-0000-0000-0000-00000000dd01',
                           floor(extract(epoch from now()) / 30)::bigint)), false);
set role authenticated;
select set_config('request.jwt.claim.sub','b111b111-0000-0000-0000-0000000000a2',false);
select expect_num('front desk CAN resolve a check-in code while only in grace',
  (select count(*) from resolve_checkin_code(current_setting('t.code_ok'))), 1);
reset role;

update platform_subscriptions set grace_ends_at = now() - interval '1 minute'
 where studio_id = 'b111b111-0000-0000-0000-000000000001';
select sweep_platform_billing();

select expect_text('past the grace period the studio locks',
  (select status::text from platform_subscriptions
    where studio_id = 'b111b111-0000-0000-0000-000000000001'), 'locked');
select expect_text('...and the gate says so',
  (select studio_is_locked('b111b111-0000-0000-0000-000000000001')::text), 'true');

-- The member app stops booking.
set role authenticated;
select set_config('request.jwt.claim.sub','b111b111-0000-0000-0000-0000000000b1',false);
do $$
begin
  perform book_class('b111b111-0000-0000-0000-00000000f002',
                     'b111b111-0000-0000-0000-00000000dd01','member',null,null);
  raise exception 'FAIL  a locked studio took a booking';
exception when sqlstate 'PT402' then
  raise notice 'PASS  the member app cannot book at a locked studio';
end $$;
reset role;

-- The staff app stops checking in and taking money.
-- The code is computed as the backend (checkin_code_for is not a client
-- surface), then offered to the desk exactly as a member's phone would.
select set_config('t.code',
  (select checkin_code_for('b111b111-0000-0000-0000-00000000dd01',
                           floor(extract(epoch from now()) / 30)::bigint)), false);
set role authenticated;
select set_config('request.jwt.claim.sub','b111b111-0000-0000-0000-0000000000a2',false);
select expect_num('front desk cannot resolve a check-in code at a locked studio',
  (select count(*) from resolve_checkin_code(current_setting('t.code'))), 0);
do $$
begin
  perform record_manual_payment('b111b111-0000-0000-0000-000000000001',
            'b111b111-0000-0000-0000-00000000dd01','other', 1000, 'cash');
  raise exception 'FAIL  a locked studio recorded a payment';
exception when sqlstate 'PT402' then
  raise notice 'PASS  a locked studio cannot record payments';
end $$;
reset role;

-- But cancellation still works. A studio that cannot cancel a class leaves
-- members at a locked door, and those members did nothing wrong.
set role authenticated;
select set_config('request.jwt.claim.sub','b111b111-0000-0000-0000-0000000000b1',false);
select expect_text('a member can still cancel while the studio is locked',
  (select (cancel_booking(current_setting('t.booking')::uuid)).status::text), 'cancelled');
reset role;

-- And every read still works, so nothing looks deleted.
select expect_num('the classes are all still there',
  (select count(*) from class_occurrences where studio_id = 'b111b111-0000-0000-0000-000000000001'),
  (current_setting('t.before')::jsonb ->> 'classes')::bigint);
select expect_num('...and the members',
  (select count(*) from members where studio_id = 'b111b111-0000-0000-0000-000000000001'),
  (current_setting('t.before')::jsonb ->> 'members')::bigint);
select expect_num('...and the payments',
  (select count(*) from payments where studio_id = 'b111b111-0000-0000-0000-000000000001'),
  (current_setting('t.before')::jsonb ->> 'payments')::bigint);

-- =============================================================================
-- 5. Paying reinstates everything
-- =============================================================================
select set_config('t.paid',
  '{"id":"evt_plat_paid","type":"invoice.paid","livemode":false,"data":{"object":'
  '{"id":"in_p1","customer":"cus_plat","subscription":"sub_plat",'
  '"metadata":{"studio_id":"b111b111-0000-0000-0000-000000000001"},'
  '"lines":{"data":[{"period":{"start":1,"end":2}}]}}}}', false);
select expect_text('paying reactivates the studio',
  (select stripe_platform_webhook(current_setting('t.paid'), psig(current_setting('t.paid'))) ->> 'result'),
  'active');
select expect_text('...it is no longer locked',
  (select studio_is_locked('b111b111-0000-0000-0000-000000000001')::text), 'false');
select expect_text('...and the lock and grace are cleared, not merely ignored',
  (select (grace_ends_at is null and locked_at is null)::text from platform_subscriptions
    where studio_id = 'b111b111-0000-0000-0000-000000000001'), 'true');

set role authenticated;
select set_config('request.jwt.claim.sub','b111b111-0000-0000-0000-0000000000b1',false);
select expect_text('...and booking works again immediately',
  (select (book_class('b111b111-0000-0000-0000-00000000f002',
                      'b111b111-0000-0000-0000-00000000dd01','member',null,null)).status::text), 'booked');
reset role;

select expect_num('nothing was lost through the whole lockout',
  (select count(*) from class_occurrences where studio_id = 'b111b111-0000-0000-0000-000000000001'),
  (current_setting('t.before')::jsonb ->> 'classes')::bigint);

-- =============================================================================
-- 6. The two endpoints do not take each other's events
-- =============================================================================
select expect_text('a replayed platform event is a no-op',
  (select stripe_platform_webhook(current_setting('t.paid'), psig(current_setting('t.paid'))) ->> 'status'),
  'duplicate');

-- A Connect event delivered to the platform endpoint.
select set_config('t.connect',
  '{"id":"evt_connect_here","type":"invoice.paid","livemode":false,'
  '"account":"acct_somebody","data":{"object":{"id":"in_c"}}}', false);
select expect_text('a Connect event at the platform endpoint is refused',
  (select stripe_platform_webhook(current_setting('t.connect'), psig(current_setting('t.connect'))) ->> 'status'),
  'not_a_platform_event');
select expect_text('...and it did not touch our own subscription table',
  (select status::text from platform_subscriptions
    where studio_id = 'b111b111-0000-0000-0000-000000000001'), 'active');

-- And a platform event delivered to the Connect endpoint.
select set_config('t.plat2',
  '{"id":"evt_plat_at_connect","type":"invoice.paid","livemode":false,'
  '"data":{"object":{"id":"in_p2"}}}', false);
select expect_text('a platform event at the Connect endpoint is refused',
  (select stripe_webhook(current_setting('t.plat2'),
     (select 't=' || extract(epoch from now())::bigint || ',v1=' ||
             encode(extensions.hmac(extract(epoch from now())::bigint || '.' ||
                    current_setting('t.plat2'), 'whsec_connect', 'sha256'), 'hex'))) ->> 'status'),
  'not_a_connect_event');

-- The platform endpoint uses its OWN secret.
do $$
begin
  perform stripe_platform_webhook(current_setting('t.paid'),
    (select 't=' || extract(epoch from now())::bigint || ',v1=' ||
            encode(extensions.hmac(extract(epoch from now())::bigint || '.' ||
                   current_setting('t.paid'), 'whsec_connect', 'sha256'), 'hex')));
  raise exception 'FAIL  the platform endpoint accepted the Connect secret';
exception when sqlstate 'PT401' then
  raise notice 'PASS  the Connect secret does not open the platform endpoint';
end $$;

-- =============================================================================
-- 7. extend_trial is the platform admin's, and nobody else's
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','b111b111-0000-0000-0000-0000000000a1',false);
do $$
begin
  perform extend_trial('b111b111-0000-0000-0000-000000000001', 14);
  raise exception 'FAIL  a studio owner extended their own trial';
exception when sqlstate 'PT403' then
  raise notice 'PASS  a studio owner cannot extend their own trial';
end $$;
reset role;

insert into platform_admins (user_id, email) values
  ('b111b111-0000-0000-0000-0000000000a1','bill-owner@example.com')
on conflict do nothing;
set role authenticated;
select set_config('request.jwt.claim.sub','b111b111-0000-0000-0000-0000000000a1',false);
select expect_text('a platform admin can extend it',
  (select (extend_trial('b111b111-0000-0000-0000-000000000001', 14) > now() + interval '13 days')::text),
  'true');
reset role;

-- Extending a locked studio lets them back in: an operator doing this in a
-- support conversation means "give them more time", not "more time, still locked".
update platform_subscriptions set status = 'locked', locked_at = now()
 where studio_id = 'b111b111-0000-0000-0000-000000000001';
set role authenticated;
select set_config('request.jwt.claim.sub','b111b111-0000-0000-0000-0000000000a1',false);
select extend_trial('b111b111-0000-0000-0000-000000000001', 7);
reset role;
select expect_text('extending a locked studio unlocks it',
  (select studio_is_locked('b111b111-0000-0000-0000-000000000001')::text), 'false');

select 'ALL PLATFORM BILLING TESTS PASSED' as result;
