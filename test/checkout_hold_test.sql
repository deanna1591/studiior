-- =============================================================================
-- STUDIIOR — DECISION 88 (d) and (e): checkout offers every option, and no seat
-- without payment.
--
-- (d) A private pack never pays for a group class: checkout_hold_class refuses
--     it before any seat is held, and apply_plan_to_unpaid never settles a group
--     seat with one.
-- (e) The online checkout seat is a 30-minute payment hold (pending_payment,
--     hold_reason 'checkout'): not counted for the flex minimum, the chips or
--     coach pay heads; confirmed when the payment succeeds; released when the
--     checkout fails (from the anonymous webhook path) or expires (the sweep),
--     with nothing owed, no late cancel, no infraction and no desk-pay strike;
--     one unpaid online hold per member.
--
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/checkout_hold_test.sql
--
-- Space: 88e0. Local only — inserts fixtures. Never run against production.
-- =============================================================================

\set ON_ERROR_STOP on
set client_min_messages = notice;

create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then
    raise notice 'PASS  %  (got %)', label, coalesce(actual, 'null');
  else
    raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null');
  end if;
end $$;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then
    raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else
    raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null');
  end if;
end $$;

create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if coalesce(actual, false) then
    raise notice 'PASS  %', label;
  else
    raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null');
  end if;
end $$;

-- The anonymous webhook path, without a webhook: a SECURITY DEFINER wrapper
-- callable by anon, so xendit_fail_purchase_internal runs exactly as it does
-- under xendit_webhook (role anon, no service context).
create or replace function s88_fail_as_webhook(p_purchase uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform xendit_fail_purchase_internal(p_purchase, 'expired', 'payment_session.expired');
end $$;
grant execute on function s88_fail_as_webhook(uuid) to anon;

-- ---- Fixtures ---------------------------------------------------------------
insert into studios (id, name, slug, timezone, currency) values
  ('88e00000-0000-0000-0000-000000000001','Hold Studio','hold88e','Asia/Manila','PHP');
insert into studio_settings (studio_id, require_waiver, booking_cutoff_minutes, flex_enabled,
                             flex_min_bookings, max_unpaid_bookings, desk_pay_mode)
  values ('88e00000-0000-0000-0000-000000000001', false, 0, true, 2, 1, 'earned');
insert into locations (id, studio_id, name) values
  ('88e00000-0000-0000-0000-00000000000c','88e00000-0000-0000-0000-000000000001','Main');
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('88e00000-0000-0000-0000-0000000000c1','88e00000-0000-0000-0000-000000000001','Reformer',50,6);
insert into class_occurrences (id, studio_id, location_id, class_type_id, name, capacity, starts_at, ends_at, flex, minimum_bookings)
select ('88e00000-0000-0000-0000-0000000000f'||n)::uuid, '88e00000-0000-0000-0000-000000000001',
       '88e00000-0000-0000-0000-00000000000c','88e00000-0000-0000-0000-0000000000c1',
       'Group '||n, 6, now()+interval '3 days'+(n||' hours')::interval,
       now()+interval '3 days'+(n||' hours 50 min')::interval, true, 2
  from generate_series(1,6) n;

insert into private_session_types (id, studio_id, name, price_cents, people, duration_min, coach_pay_cents)
  values ('88e00000-0000-0000-0000-0000000000a1','88e00000-0000-0000-0000-000000000001','1:1',220000,1,50,80000);
insert into membership_plans (id, studio_id, name, type, price_cents, currency, validity_days, credits,
                              visibility, status, private_pack, private_session_type_id) values
  ('88e00000-0000-0000-0000-0000000000d1','88e00000-0000-0000-0000-000000000001','Single Drop-in','drop_in',105000,'PHP',30,null,'public','active',false,null),
  ('88e00000-0000-0000-0000-0000000000d2','88e00000-0000-0000-0000-000000000001','5-Session Private Pack','class_pack',1050000,'PHP',30,5,'public','active',true,'88e00000-0000-0000-0000-0000000000a1');

insert into auth.users (id) values
  ('88e00000-0000-0000-0000-0000000000a5'),('88e00000-0000-0000-0000-0000000000a6');
insert into profiles (id, email) values
  ('88e00000-0000-0000-0000-0000000000a5','s88-one@example.com'),
  ('88e00000-0000-0000-0000-0000000000a6','s88-two@example.com');
insert into members (id, studio_id, first_name, last_name, email, status, user_id) values
  ('88e00000-0000-0000-0000-0000000000b1','88e00000-0000-0000-0000-000000000001','One','Holder','s88-one@example.com','active','88e00000-0000-0000-0000-0000000000a5'),
  ('88e00000-0000-0000-0000-0000000000b2','88e00000-0000-0000-0000-000000000001','Two','Payer','s88-two@example.com','active','88e00000-0000-0000-0000-0000000000a6');

-- ---- 1. 88 (d): a private pack never pays for a group class ----------------
set role authenticated; select set_config('request.jwt.claim.sub','88e00000-0000-0000-0000-0000000000a5',false);
select set_config('t.pp', checkout_hold_class('88e00000-0000-0000-0000-0000000000f1',
                                              '88e00000-0000-0000-0000-0000000000d2') ->> 'failure_reason', false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('88 (d): a private pack at a group-class checkout is refused',
  current_setting('t.pp'), 'private_pack_not_for_class');
select expect_num('88 (d): the refusal holds no seat',
  (select count(*) from bookings where member_id='88e00000-0000-0000-0000-0000000000b1'), 0);

-- apply_plan_to_unpaid never settles a group seat with a private pack (even
-- when one is somehow bought with a seat held).
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, hold_until, hold_reason)
  values ('88e00000-0000-0000-0000-00000000bb01','88e00000-0000-0000-0000-000000000001','88e00000-0000-0000-0000-0000000000f6',
          '88e00000-0000-0000-0000-0000000000b2','pending_payment','member','drop_in', now()+interval '20 minutes','checkout');
update class_occurrences set booked_count = booked_count + 1 where id='88e00000-0000-0000-0000-0000000000f6';
insert into xendit_purchases (id, studio_id, member_id, plan_id, amount_cents, currency, hold_booking_id) values
  ('88e00000-0000-0000-0000-0000000e0001','88e00000-0000-0000-0000-000000000001','88e00000-0000-0000-0000-0000000000b2',
   '88e00000-0000-0000-0000-0000000000d2',1050000,'PHP','88e00000-0000-0000-0000-00000000bb01');
select expect_text('88 (d): the private pack purchase still activates (money taken)',
  xendit_activate_success_internal('88e00000-0000-0000-0000-0000000e0001','py_pp'), 'activated');
select expect_text('88 (d): the private pack does NOT settle the group seat',
  (select status::text||'/'||payment_source::text from bookings where id='88e00000-0000-0000-0000-00000000bb01'),
  'pending_payment/drop_in');
select expect_num('88 (d): the private pack keeps all 5 sessions',
  (select credits_remaining from memberships where member_id='88e00000-0000-0000-0000-0000000000b2'
     and plan_id='88e00000-0000-0000-0000-0000000000d2'), 5);
-- tidy: release that seat so member Two can be used below
select set_config('studiior.hold_release','1',true);
select cancel_booking('88e00000-0000-0000-0000-00000000bb01');

-- ---- 2. 88 (e): the checkout seat is a 30-minute payment hold --------------
set role authenticated; select set_config('request.jwt.claim.sub','88e00000-0000-0000-0000-0000000000a5',false);
select set_config('t.h1', checkout_hold_class('88e00000-0000-0000-0000-0000000000f1',
                                              '88e00000-0000-0000-0000-0000000000d1')::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('88 (e): the hold is taken (no refusal)',
  (current_setting('t.h1')::jsonb ->> 'failure_reason'), null);
select expect_text('88 (e): the seat is pending_payment, held for checkout, a drop-in',
  (select status::text||'/'||hold_reason||'/'||payment_source::text from bookings
    where member_id='88e00000-0000-0000-0000-0000000000b1' and occurrence_id='88e00000-0000-0000-0000-0000000000f1'),
  'pending_payment/checkout/drop_in');
select expect_true('88 (e): the hold lasts 30 minutes (hold_until 29 to 31 minutes ahead)',
  (select hold_until between now()+interval '29 minutes' and now()+interval '31 minutes' from bookings
    where member_id='88e00000-0000-0000-0000-0000000000b1' and occurrence_id='88e00000-0000-0000-0000-0000000000f1'));
select expect_true('88 (e): the returned hold_until is the stored one',
  (select (current_setting('t.h1')::jsonb ->> 'hold_until')::timestamptz = hold_until from bookings
    where member_id='88e00000-0000-0000-0000-0000000000b1' and occurrence_id='88e00000-0000-0000-0000-0000000000f1'));
select expect_num('88 (e): the hold takes a place for capacity',
  (select booked_count from class_occurrences where id='88e00000-0000-0000-0000-0000000000f1'), 1);
select expect_num('88 (e): the hold does not count toward the flex minimum (paid count)',
  occurrence_paid_count_run('88e00000-0000-0000-0000-0000000000f1'), 0);
select expect_num('88 (e): the hold does not count on the flex chip',
  (occurrence_flex_state_run('88e00000-0000-0000-0000-0000000000f1') ->> 'paid_count')::int, 0);
select expect_num('88 (e): the hold does not count toward coach pay heads',
  class_seats_used_run('88e00000-0000-0000-0000-0000000000f1'), 0);
select expect_num('88 (e): no booking confirmation is sent for a hold',
  (select count(*) from notifications where member_id='88e00000-0000-0000-0000-0000000000b1'
     and template_key in ('booking_confirmed','flex_booking_pending')), 0);

-- member_pending_bookings reports it as a checkout hold with its end
set role authenticated; select set_config('request.jwt.claim.sub','88e00000-0000-0000-0000-0000000000a5',false);
select set_config('t.mp', (select status||'|'||(hold_until is not null)::text from member_pending_bookings('88e00000-0000-0000-0000-000000000001')
                            where occurrence_id='88e00000-0000-0000-0000-0000000000f1'), false);
-- one unpaid online seat at a time
select set_config('t.h2', checkout_hold_class('88e00000-0000-0000-0000-0000000000f2',
                                              '88e00000-0000-0000-0000-0000000000d1') ->> 'failure_reason', false);
-- a new checkout for the SAME class re-arms the same hold
select set_config('t.h3', checkout_hold_class('88e00000-0000-0000-0000-0000000000f1',
                                              '88e00000-0000-0000-0000-0000000000d1')::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('88 (e): member_pending_bookings reports checkout_hold with its end',
  current_setting('t.mp'), 'checkout_hold|true');
select expect_text('88 (e): a second hold on another class is refused',
  current_setting('t.h2'), 'hold_open');
select expect_num('88 (e): the refusal holds no second seat',
  (select count(*) from bookings where member_id='88e00000-0000-0000-0000-0000000000b1'
     and status = 'pending_payment'), 1);
select expect_true('88 (e): a new checkout for the same class re-arms the same hold',
  (select (current_setting('t.h3')::jsonb ->> 'booking_id')::uuid = id from bookings
    where member_id='88e00000-0000-0000-0000-0000000000b1' and occurrence_id='88e00000-0000-0000-0000-0000000000f1'));

-- ---- 3. Failure from the webhook releases the seat; nothing owed, no strike -
insert into xendit_purchases (id, studio_id, member_id, plan_id, amount_cents, currency) values
  ('88e00000-0000-0000-0000-0000000e1001','88e00000-0000-0000-0000-000000000001','88e00000-0000-0000-0000-0000000000b1',
   '88e00000-0000-0000-0000-0000000000d1',105000,'PHP');
set role authenticated; select set_config('request.jwt.claim.sub','88e00000-0000-0000-0000-0000000000a5',false);
select set_config('t.lk', checkout_link_hold('88e00000-0000-0000-0000-0000000e1001',
  (select id from bookings where member_id='88e00000-0000-0000-0000-0000000000b1'
     and occurrence_id='88e00000-0000-0000-0000-0000000000f1'))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('88 (e): the checkout is tied to the held seat', current_setting('t.lk'), 'true');

-- a member cannot tie someone else's checkout to their own seat
set role authenticated; select set_config('request.jwt.claim.sub','88e00000-0000-0000-0000-0000000000a6',false);
do $$ begin
  perform checkout_link_hold('88e00000-0000-0000-0000-0000000e1001', gen_random_uuid());
  raise exception 'FAIL  checkout_link_hold allowed another member';
exception when sqlstate 'PT403' then raise notice 'PASS  checkout_link_hold refuses another member (PT403)';
end $$;
select set_config('request.jwt.claim.sub','',false); reset role;

set role anon;
select s88_fail_as_webhook('88e00000-0000-0000-0000-0000000e1001');
reset role;
select expect_text('88 (e): a failed checkout releases the seat as a plain cancel',
  (select status::text||'/'||coalesce(is_late_cancel,false)::text from bookings
    where member_id='88e00000-0000-0000-0000-0000000000b1' and occurrence_id='88e00000-0000-0000-0000-0000000000f1'),
  'cancelled/false');
select expect_num('88 (e): the place is back',
  (select booked_count from class_occurrences where id='88e00000-0000-0000-0000-0000000000f1'), 0);
select expect_num('88 (e): nothing is owed (no payment row)',
  (select count(*) from payments where member_id='88e00000-0000-0000-0000-0000000000b1'), 0);
select expect_num('88 (e): no infraction is recorded',
  (select count(*) from member_infractions where member_id='88e00000-0000-0000-0000-0000000000b1'), 0);
select expect_true('88 (e): no desk-pay strike',
  (select desk_pay_blocked_at is null from members where id='88e00000-0000-0000-0000-0000000000b1'));
select expect_text('88 (e): the purchase is marked expired',
  (select status from xendit_purchases where id='88e00000-0000-0000-0000-0000000e1001'), 'expired');

-- ---- 4. Expiry: the sweep releases a hold past its end, and its checkout ----
set role authenticated; select set_config('request.jwt.claim.sub','88e00000-0000-0000-0000-0000000000a5',false);
select set_config('t.h4', coalesce(checkout_hold_class('88e00000-0000-0000-0000-0000000000f2',
                                              '88e00000-0000-0000-0000-0000000000d1') ->> 'failure_reason', 'none'), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('88 (e): after the release a new hold is allowed', current_setting('t.h4'), 'none');
insert into xendit_purchases (id, studio_id, member_id, plan_id, amount_cents, currency, hold_booking_id) values
  ('88e00000-0000-0000-0000-0000000e2001','88e00000-0000-0000-0000-000000000001','88e00000-0000-0000-0000-0000000000b1',
   '88e00000-0000-0000-0000-0000000000d1',105000,'PHP',
   (select id from bookings where member_id='88e00000-0000-0000-0000-0000000000b1'
      and occurrence_id='88e00000-0000-0000-0000-0000000000f2' and status='pending_payment'));
update bookings set hold_until = now() - interval '1 minute'
 where member_id='88e00000-0000-0000-0000-0000000000b1' and occurrence_id='88e00000-0000-0000-0000-0000000000f2'
   and status='pending_payment';
select sweep_unpaid_dropins();
select expect_text('88 (e): the sweep releases an ended hold as a plain cancel',
  (select status::text||'/'||coalesce(is_late_cancel,false)::text from bookings
    where member_id='88e00000-0000-0000-0000-0000000000b1' and occurrence_id='88e00000-0000-0000-0000-0000000000f2'),
  'cancelled/false');
select expect_text('88 (e): its checkout is expired (hold_released), so the 119 rescue sees it',
  (select status||'/'||failure_reason from xendit_purchases where id='88e00000-0000-0000-0000-0000000e2001'),
  'expired/hold_released');
select expect_num('88 (e): still no infraction', (select count(*) from member_infractions
  where member_id='88e00000-0000-0000-0000-0000000000b1'), 0);
select expect_true('88 (e): still no desk-pay strike',
  (select desk_pay_blocked_at is null from members where id='88e00000-0000-0000-0000-0000000000b1'));

-- ---- 5. Success confirms the held seat ---------------------------------------
set role authenticated; select set_config('request.jwt.claim.sub','88e00000-0000-0000-0000-0000000000a5',false);
select set_config('t.h5', checkout_hold_class('88e00000-0000-0000-0000-0000000000f3',
                                              '88e00000-0000-0000-0000-0000000000d1') ->> 'booking_id', false);
select set_config('request.jwt.claim.sub','',false); reset role;
insert into xendit_purchases (id, studio_id, member_id, plan_id, amount_cents, currency, hold_booking_id) values
  ('88e00000-0000-0000-0000-0000000e3001','88e00000-0000-0000-0000-000000000001','88e00000-0000-0000-0000-0000000000b1',
   '88e00000-0000-0000-0000-0000000000d1',105000,'PHP', current_setting('t.h5')::uuid);
select expect_text('88 (e): the payment activates',
  xendit_activate_success_internal('88e00000-0000-0000-0000-0000000e3001','py_ok'), 'activated');
select expect_text('88 (e): the held seat is confirmed and paid by the plan',
  (select status::text||'/'||payment_source::text||'/'||(hold_until is null)::text||'/'||(hold_reason is null)::text
     from bookings where id = current_setting('t.h5')::uuid),
  'booked/class_pack/true/true');
select expect_num('88 (e): the paid seat now counts toward the flex minimum',
  occurrence_paid_count_run('88e00000-0000-0000-0000-0000000000f3'), 1);
select expect_num('88 (e): and toward coach pay heads',
  class_seats_used_run('88e00000-0000-0000-0000-0000000000f3'), 1);
select expect_num('88 (e): the place is still one (no double count)',
  (select booked_count from class_occurrences where id='88e00000-0000-0000-0000-0000000000f3'), 1);
select expect_num('88 (e): the confirmation is sent once the seat is paid',
  (select count(*) from notifications where member_id='88e00000-0000-0000-0000-0000000000b1'
     and template_key in ('booking_confirmed','flex_booking_pending')
     and payload ->> 'occurrence_id' = '88e00000-0000-0000-0000-0000000000f3'), 1);
-- a later failure of that (now succeeded) purchase changes nothing
select s88_fail_as_webhook('88e00000-0000-0000-0000-0000000e3001');
select expect_text('88 (e): a stray failure after success leaves the seat booked',
  (select status::text from bookings where id = current_setting('t.h5')::uuid), 'booked');

-- ---- 6. Staff bookings are unchanged -----------------------------------------
select expect_text('88 (e): a desk booking of an unpaid drop-in is still booked outright',
  (select (book_class('88e00000-0000-0000-0000-0000000000f4','88e00000-0000-0000-0000-0000000000b2','front_desk')).status::text),
  'booked');

-- ---- 7. The public surface ---------------------------------------------------
select expect_num('anon surface is exactly fifteen',
  (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not like 'expect\_%' and p.proname not like 's88\_%'), 15);
select expect_true('the Step 14c functions are not anon',
  not has_function_privilege('anon', 'checkout_hold_class(uuid,uuid)', 'execute')
  and not has_function_privilege('anon', 'checkout_link_hold(uuid,uuid)', 'execute'));

do $$ begin raise notice 'checkout_hold_test: all assertions passed'; end $$;
