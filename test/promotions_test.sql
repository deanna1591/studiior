-- =============================================================================
-- Step 12 (migration 367): Decision 117 promotions. The sale price, the
-- rounding, the timing table, the three charging paths (online, desk, instructor
-- desk), refunds, sales, the emails, the guards.
-- UUID space b117, checked free. Run after `supabase db reset`.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_eq(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if coalesce(actual, false) then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_err(label text, sql text, code text)
returns void language plpgsql as $$
begin
  execute sql;
  raise exception 'FAIL  %  expected error %, got none', label, code;
exception when others then
  if sqlstate = code then raise notice 'PASS  %  (raised %)', label, code;
  else raise exception 'FAIL  %  expected %, got % %', label, code, sqlstate, sqlerrm; end if;
end $$;

-- --- studio, logins, plans ---------------------------------------------------
insert into auth.users (id) values
  ('b1170000-0000-0000-0000-0000000000a1'),   -- owner
  ('b1170000-0000-0000-0000-0000000000f1'),   -- front desk
  ('b1170000-0000-0000-0000-0000000000c1'),   -- member M1
  ('b1170000-0000-0000-0000-0000000000c2'),   -- member M2
  ('b1170000-0000-0000-0000-0000000000e1');   -- a stranger
insert into profiles (id, email, full_name) values
  ('b1170000-0000-0000-0000-0000000000a1','b117-owner@example.com','Olive Owner'),
  ('b1170000-0000-0000-0000-0000000000f1','b117-desk@example.com','Dee Desk'),
  ('b1170000-0000-0000-0000-0000000000c1','b117-m1@example.com','Mia One'),
  ('b1170000-0000-0000-0000-0000000000c2','b117-m2@example.com','Max Two'),
  ('b1170000-0000-0000-0000-0000000000e1','b117-x@example.com','Xan Stranger');
insert into studios (id, name, slug, timezone, currency, status) values
  ('b1170000-0000-0000-0000-0000000000a0','Sale Studio','b117-s','Asia/Manila','PHP','active');
insert into studio_settings (studio_id, time_format) values ('b1170000-0000-0000-0000-0000000000a0','12h');
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('b1170000-0000-0000-0000-0000000005a1','b1170000-0000-0000-0000-0000000000a0','b1170000-0000-0000-0000-0000000000a1','b117-owner@example.com','owner'),
  ('b1170000-0000-0000-0000-0000000005f1','b1170000-0000-0000-0000-0000000000a0','b1170000-0000-0000-0000-0000000000f1','b117-desk@example.com','front_desk');
insert into members (id, studio_id, user_id, first_name, last_name, email, status, waiver_signed_at) values
  ('b1170000-0000-0000-0000-0000000d0001','b1170000-0000-0000-0000-0000000000a0','b1170000-0000-0000-0000-0000000000c1','Mia','One','b117-m1@example.com','active', now()),
  ('b1170000-0000-0000-0000-0000000d0002','b1170000-0000-0000-0000-0000000000a0','b1170000-0000-0000-0000-0000000000c2','Max','Two','b117-m2@example.com','active', now());
insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, validity_days, visibility, status) values
  ('b1170000-0000-0000-0000-0000000cc001','b1170000-0000-0000-0000-0000000000a0','5-Class Pack','class_pack',140000,'PHP',5,30,'public','active'),
  ('b1170000-0000-0000-0000-0000000cc003','b1170000-0000-0000-0000-0000000000a0','Odd Pack','class_pack',99950,'PHP',3,30,'public','active');
insert into membership_plans (id, studio_id, name, type, price_cents, currency, billing_interval, visibility, status) values
  ('b1170000-0000-0000-0000-0000000cc002','b1170000-0000-0000-0000-0000000000a0','Unlimited','recurring',250000,'PHP','month','public','active');
insert into studio_payment_providers
  (studio_id, provider, secret_key_ciphertext, callback_token_ciphertext, callback_token_sha256,
   key_last4, test_mode, connected_by) values
  ('b1170000-0000-0000-0000-0000000000a0','xendit','v1.opaque-secret','v1.opaque-token',
   encode(digest('t','sha256'),'hex'), 'tok0', true, 'b1170000-0000-0000-0000-0000000000a1');

select set_config('t.today', ((now() at time zone 'Asia/Manila')::date)::text, false);

-- =============================================================================
-- 1. The rounding: half up to the whole unit.
-- =============================================================================
select expect_eq('1.1 140000 at 15% off is 119000', promo_sale_cents(140000, 15)::text, '119000');
select expect_eq('1.2 99950 at 20% off rounds 79960 up to 80000', promo_sale_cents(99950, 20)::text, '80000');
select expect_eq('1.3 1000 at 15% off (8.50) rounds half up to 900', promo_sale_cents(1000, 15)::text, '900');
select expect_eq('1.4 999 at 15% off (8.49) rounds down to 800', promo_sale_cents(999, 15)::text, '800');

-- =============================================================================
-- 2. Saving: guards and refusals.
-- =============================================================================
reset role; set role authenticated; select set_config('request.jwt.claim.sub','b1170000-0000-0000-0000-0000000000f1',false);
select expect_err('2.1 front desk cannot create a promotion',
  $$select promotion_save('b1170000-0000-0000-0000-0000000000a0', null, 'X', 10, current_date + 1, current_date + 2, array['b1170000-0000-0000-0000-0000000cc001'::uuid])$$, 'PT403');
select expect_true('2.2 front desk reads the sale price (sell sheet)',
  (plan_price_now('b1170000-0000-0000-0000-0000000cc001') ->> 'price_cents') = '140000');
reset role; set role authenticated; select set_config('request.jwt.claim.sub','b1170000-0000-0000-0000-0000000000e1',false);
select expect_err('2.3 a stranger cannot read the studio prices',
  $$select plan_prices_now('b1170000-0000-0000-0000-0000000000a0')$$, 'PT403');

reset role; set role authenticated; select set_config('request.jwt.claim.sub','b1170000-0000-0000-0000-0000000000a1',false);
select expect_eq('2.4 a recurring plan is refused plan_recurring',
  promotion_save('b1170000-0000-0000-0000-0000000000a0', null, 'Holiday Sale', 20,
    current_setting('t.today')::date, current_setting('t.today')::date + 5,
    array['b1170000-0000-0000-0000-0000000cc002'::uuid]) ->> 'reason', 'plan_recurring');
select expect_eq('2.5 percent out of range',
  promotion_save('b1170000-0000-0000-0000-0000000000a0', null, 'Big', 95,
    current_setting('t.today')::date, current_setting('t.today')::date + 5,
    array['b1170000-0000-0000-0000-0000000cc001'::uuid]) ->> 'reason', 'pct_range');
select expect_eq('2.6 no plans ticked',
  promotion_save('b1170000-0000-0000-0000-0000000000a0', null, 'None', 10,
    current_setting('t.today')::date, current_setting('t.today')::date + 5, '{}'::uuid[]) ->> 'reason', 'no_plans');

select set_config('t.p1', (promotion_save('b1170000-0000-0000-0000-0000000000a0', null, 'Holiday Sale', 15,
    current_setting('t.today')::date, current_setting('t.today')::date + 5,
    array['b1170000-0000-0000-0000-0000000cc001'::uuid, 'b1170000-0000-0000-0000-0000000cc003'::uuid]) ->> 'id'), false);
select expect_true('2.7 the promotion is saved', current_setting('t.p1') <> '');
select expect_eq('2.8 an overlapping promotion on the same plan is refused with the sentence',
  promotion_save('b1170000-0000-0000-0000-0000000000a0', null, 'Flash', 10,
    current_setting('t.today')::date + 3, current_setting('t.today')::date + 9,
    array['b1170000-0000-0000-0000-0000000cc001'::uuid]) ->> 'message',
  '5-Class Pack already has Holiday Sale from ' || to_char(current_setting('t.today')::date, 'FMDy FMDD FMMon')
    || ' to ' || to_char(current_setting('t.today')::date + 5, 'FMDy FMDD FMMon') || '.');
select expect_eq('2.9 a running promotion cannot be edited',
  promotion_save('b1170000-0000-0000-0000-0000000000a0', current_setting('t.p1')::uuid, 'Holiday Sale', 30,
    current_setting('t.today')::date, current_setting('t.today')::date + 5,
    array['b1170000-0000-0000-0000-0000000cc001'::uuid]) ->> 'reason', 'started');
select expect_eq('2.10 a running promotion cannot be archived',
  promotion_archive(current_setting('t.p1')::uuid) ->> 'reason', 'running');
select expect_true('2.11 promotions_list says Running',
  (select e ->> 'status' from jsonb_array_elements(promotions_list('b1170000-0000-0000-0000-0000000000a0')) e
    where e ->> 'id' = current_setting('t.p1')) = 'running');
reset role;
select expect_eq('2.12 creating it wrote one audit row', (select count(*)::text from audit_logs
  where action = 'promotion.created' and entity_id = current_setting('t.p1')::uuid), '1');

-- =============================================================================
-- 3. The price now.
-- =============================================================================
select expect_eq('3.1 the pack is 1190 on sale', plan_price_now_run('b1170000-0000-0000-0000-0000000cc001') ->> 'price_cents', '119000');
select expect_eq('3.2 discount 21000', plan_price_now_run('b1170000-0000-0000-0000-0000000cc001') ->> 'discount_cents', '21000');
select expect_eq('3.3 the recurring plan is list price', plan_price_now_run('b1170000-0000-0000-0000-0000000cc002') ->> 'price_cents', '250000');
select expect_eq('3.4 the odd pack rounds to 85000 (84957.5 up)', plan_price_now_run('b1170000-0000-0000-0000-0000000cc003') ->> 'price_cents', '85000');
select expect_eq('3.5 plan_prices_now covers every live plan', jsonb_array_length(plan_prices_now('b1170000-0000-0000-0000-0000000000a0'))::text, '3');
select expect_eq('3.6 the end label', plan_price_now_run('b1170000-0000-0000-0000-0000000cc001') ->> 'ends_label',
  to_char(current_setting('t.today')::date + 5, 'FMDy FMDD FMMon'));
select expect_eq('3.7 a scheduled promotion is not in force yet',
  plan_price_now_run('b1170000-0000-0000-0000-0000000cc001', now() - interval '3 days') ->> 'price_cents', '140000');

-- =============================================================================
-- 4. Online: begin during the sale, the promotion ends, then it is paid.
-- =============================================================================
reset role; set role authenticated; select set_config('request.jwt.claim.sub','b1170000-0000-0000-0000-0000000000c1',false);
select set_config('t.x1', (select purchase_id::text from xendit_begin_purchase('b1170000-0000-0000-0000-0000000000a0','b1170000-0000-0000-0000-0000000cc001')), false);
reset role;
select expect_eq('4.1 the checkout charges the sale price', (select amount_cents::text from xendit_purchases where id = current_setting('t.x1')::uuid), '119000');
select expect_eq('4.2 the checkout carries list, promotion and discount',
  (select list_price_cents || '/' || (promotion_id = current_setting('t.p1')::uuid) || '/' || discount_cents
     from xendit_purchases where id = current_setting('t.x1')::uuid), '140000/true/21000');
-- abandoned checkout, started during the sale (pending, never paid)
reset role; set role authenticated; select set_config('request.jwt.claim.sub','b1170000-0000-0000-0000-0000000000c2',false);
select set_config('t.x2', (select purchase_id::text from xendit_begin_purchase('b1170000-0000-0000-0000-0000000000a0','b1170000-0000-0000-0000-0000000cc001')), false);

-- The list price is edited while the promotion runs: the percent applies to the
-- new price from the next checkout; pending checkouts keep theirs.
reset role;
update membership_plans set price_cents = 160000 where id = 'b1170000-0000-0000-0000-0000000cc001';
select expect_eq('4.3 the next checkout is 15% off the new list price',
  plan_price_now_run('b1170000-0000-0000-0000-0000000cc001') ->> 'price_cents', '136000');
select expect_eq('4.4 the pending checkout keeps its price', (select amount_cents::text from xendit_purchases where id = current_setting('t.x1')::uuid), '119000');

-- End now, while M1's checkout is pending.
reset role; set role authenticated; select set_config('request.jwt.claim.sub','b1170000-0000-0000-0000-0000000000a1',false);
select expect_true('4.5 End now', (promotion_end_now(current_setting('t.p1')::uuid) ->> 'ok')::boolean);
select expect_eq('4.6 End now again is refused', promotion_end_now(current_setting('t.p1')::uuid) ->> 'reason', 'not_running');
reset role;
select expect_eq('4.7 End now is audited', (select count(*)::text from audit_logs
  where action = 'promotion.ended' and entity_id = current_setting('t.p1')::uuid), '1');
select expect_eq('4.8 after the end the plan is list price', plan_price_now_run('b1170000-0000-0000-0000-0000000cc001') ->> 'price_cents', '160000');

-- The callback after the end: the sale price is kept.
select xendit_activate_success_internal(current_setting('t.x1')::uuid, 'py-b117-1');
select expect_eq('4.9 the payment is the sale price with the promotion recorded',
  (select amount_cents || '/' || list_price_cents || '/' || discount_cents || '/' || (promotion_id = current_setting('t.p1')::uuid)
     from payments where reference = 'py-b117-1'), '119000/140000/21000/true');
select expect_eq('4.10 the plan is unchanged: 5 credits', (select credits_remaining::text from memberships
  where member_id = 'b1170000-0000-0000-0000-0000000d0001' and plan_id = 'b1170000-0000-0000-0000-0000000cc001'), '5');

-- Abandoned and restarted after the end: list price.
reset role; set role authenticated; select set_config('request.jwt.claim.sub','b1170000-0000-0000-0000-0000000000c2',false);
select set_config('t.x3', (select purchase_id::text from xendit_begin_purchase('b1170000-0000-0000-0000-0000000000a0','b1170000-0000-0000-0000-0000000cc001')), false);
reset role;
select expect_eq('4.11 restarted after the end: list price, no promotion',
  (select amount_cents || '/' || coalesce(promotion_id::text, 'none') from xendit_purchases where id = current_setting('t.x3')::uuid),
  '160000/none');
select expect_eq('4.12 the abandoned one kept its sale price', (select amount_cents::text from xendit_purchases where id = current_setting('t.x2')::uuid), '119000');

-- Refund of a discounted purchase: the amount paid, never the list price.
reset role; set role authenticated; select set_config('request.jwt.claim.sub','b1170000-0000-0000-0000-0000000000a1',false);
select expect_err('4.13 refunding more than was paid is refused',
  $$select record_refund((select id from payments where reference = 'py-b117-1'), 140000, 'too much', false)$$, 'PT400');
select record_refund((select id from payments where reference = 'py-b117-1'), 119000, 'changed mind', false);
reset role;
select expect_eq('4.14 the full refund is the amount paid', (select refunded_cents::text from payments where reference = 'py-b117-1'), '119000');

-- =============================================================================
-- 5. A new promotion; the desk.
-- =============================================================================
reset role; set role authenticated; select set_config('request.jwt.claim.sub','b1170000-0000-0000-0000-0000000000a1',false);
select set_config('t.p2', (promotion_save('b1170000-0000-0000-0000-0000000000a0', null, 'Flash', 25,
    current_setting('t.today')::date, current_setting('t.today')::date + 2,
    array['b1170000-0000-0000-0000-0000000cc001'::uuid]) ->> 'id'), false);
select expect_true('5.1 a new promotion after End now does not overlap', current_setting('t.p2') <> '');
reset role; set role authenticated; select set_config('request.jwt.claim.sub','b1170000-0000-0000-0000-0000000000f1',false);
select set_config('t.d1', (record_manual_payment('b1170000-0000-0000-0000-0000000000a0','b1170000-0000-0000-0000-0000000d0002',
  'plan', 120000, 'cash', 'b1170000-0000-0000-0000-0000000cc001') ->> 'payment_id'), false);
select set_config('t.d2', (record_manual_payment('b1170000-0000-0000-0000-0000000000a0','b1170000-0000-0000-0000-0000000d0002',
  'plan', 100000, 'cash', 'b1170000-0000-0000-0000-0000000cc001') ->> 'payment_id'), false);
reset role;
select expect_eq('5.2 a desk sale at the sale price records the promotion',
  (select amount_cents || '/' || list_price_cents || '/' || discount_cents || '/' || (promotion_id = current_setting('t.p2')::uuid)
     from payments where id = current_setting('t.d1')::uuid), '120000/160000/40000/true');
select expect_eq('5.3 any other typed amount is a manual price, no promotion',
  (select amount_cents || '/' || coalesce(promotion_id::text, 'none') from payments where id = current_setting('t.d2')::uuid),
  '100000/none');

-- The instructor's desk (sell_plan_at_desk): the sale price.
insert into locations (id, studio_id, name, is_primary) values
  ('b1170000-0000-0000-0000-00000000010c','b1170000-0000-0000-0000-0000000000a0','Main', true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('b1170000-0000-0000-0000-000000000101','b1170000-0000-0000-0000-0000000000a0','b1170000-0000-0000-0000-00000000010c','Room',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('b1170000-0000-0000-0000-0000000ce001','b1170000-0000-0000-0000-0000000000a0','Reformer',50,10);
insert into class_occurrences (id, studio_id, name, location_id, class_type_id, room_id, starts_at, ends_at, capacity, status) values
  ('b1170000-0000-0000-0000-0000000ac001','b1170000-0000-0000-0000-0000000000a0','Reformer','b1170000-0000-0000-0000-00000000010c','b1170000-0000-0000-0000-0000000ce001',
   'b1170000-0000-0000-0000-000000000101', now() + interval '1 hour', now() + interval '110 minutes', 10, 'scheduled');
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source) values
  ('b1170000-0000-0000-0000-0000000bb001','b1170000-0000-0000-0000-0000000000a0','b1170000-0000-0000-0000-0000000ac001',
   'b1170000-0000-0000-0000-0000000d0001','booked','drop_in');
select set_config('t.s1', (sell_plan_at_desk('b1170000-0000-0000-0000-0000000ac001','b1170000-0000-0000-0000-0000000d0001',
  'b1170000-0000-0000-0000-0000000cc001','cash', null, false) ->> 'payment_id'), false);
select expect_eq('5.4 the instructor desk charges the sale price and records it',
  (select amount_cents || '/' || (promotion_id = current_setting('t.p2')::uuid) from payments where id = current_setting('t.s1')::uuid),
  '120000/true');

-- ₱20 floor: reservation credit is applied after the discount.
insert into member_credits (studio_id, member_id, amount_cents, currency, reason)
values ('b1170000-0000-0000-0000-0000000000a0','b1170000-0000-0000-0000-0000000d0002', 119500, 'PHP', 'reservation_credit');
reset role; set role authenticated; select set_config('request.jwt.claim.sub','b1170000-0000-0000-0000-0000000000c2',false);
select set_config('t.x4', (select purchase_id::text from xendit_begin_purchase('b1170000-0000-0000-0000-0000000000a0','b1170000-0000-0000-0000-0000000cc001')), false);
reset role;
select expect_eq('5.5 credit comes off the sale price and the Xendit floor holds (due 2000, credit 118000)',
  (select amount_cents || '/' || credit_applied_cents from xendit_purchases where id = current_setting('t.x4')::uuid), '2000/118000');

-- =============================================================================
-- 6. Sales.
-- =============================================================================
select expect_true('6.1 sales_history shows the sale with its percent',
  exists (select 1 from sales_history('b1170000-0000-0000-0000-0000000000a0', current_setting('t.today')::date - 1, current_setting('t.today')::date + 1)
           where discount_pct = 25 and amount_cents = 120000));
select expect_eq('6.2 sales_totals counts discounts given (desk 40000 x2 + online 21000, refunded too)',
  sales_totals('b1170000-0000-0000-0000-0000000000a0', current_setting('t.today')::date - 1, current_setting('t.today')::date + 1) -> 'discounts' ->> 'total_cents',
  (select sum(discount_cents)::text from payments where studio_id = 'b1170000-0000-0000-0000-0000000000a0' and promotion_id is not null
     and status in ('succeeded','partially_refunded')));

-- =============================================================================
-- 7. The emails: {offer_price} and {promo_line} from offer_plan_id.
-- =============================================================================
select set_config('t.r', (select text_body from render_email('b1170000-0000-0000-0000-0000000000a0','convert_week_5','member',
  'S', (select text_body from notification_templates where key = 'convert_week_5'),
  (select html_body from notification_templates where key = 'convert_week_5'),
  jsonb_build_object('offer_plan_id','b1170000-0000-0000-0000-0000000cc001','offer_plan_name','5-Class Pack',
                     'offer_detail','5 classes','offer_price','WRONG','buy_url','https://x'), 'Mia')), false);
select expect_true('7.1 the promo line is in the email while the sale runs',
  position('Flash: 25% off until ' || to_char(current_setting('t.today')::date + 2, 'FMDy FMDD FMMon') in current_setting('t.r')) > 0);
select expect_true('7.2 {offer_price} is the sale price', position(fmt_money(120000, 'PHP') in current_setting('t.r')) > 0
  and position('WRONG' in current_setting('t.r')) = 0);
-- after End now: the line is gone, no blank paragraph left
reset role; set role authenticated; select set_config('request.jwt.claim.sub','b1170000-0000-0000-0000-0000000000a1',false);
select promotion_end_now(current_setting('t.p2')::uuid);
reset role;
select set_config('t.r2', (select text_body || '|||' || html_body from render_email('b1170000-0000-0000-0000-0000000000a0','convert_week_5','member',
  'S', (select text_body from notification_templates where key = 'convert_week_5'),
  (select html_body from notification_templates where key = 'convert_week_5'),
  jsonb_build_object('offer_plan_id','b1170000-0000-0000-0000-0000000cc001','offer_plan_name','5-Class Pack',
                     'offer_detail','5 classes','buy_url','https://x'), 'Mia')), false);
select expect_true('7.3 no promo line and no triple line break once ended',
  position('% off' in current_setting('t.r2')) = 0 and position(E'\n\n\n' in current_setting('t.r2')) = 0);
select expect_true('7.4 no empty paragraph in the html', current_setting('t.r2') !~ '<p[^>]*>\s*</p>');
select expect_true('7.5 {offer_price} is the list price once ended', position(fmt_money(160000, 'PHP') in current_setting('t.r2')) > 0);
select expect_eq('7.6 nothing stripped', (select array_length(stripped, 1)::text from render_email('b1170000-0000-0000-0000-0000000000a0','convert_week_5','member',
  'S', (select text_body from notification_templates where key = 'convert_week_5'),
  (select html_body from notification_templates where key = 'convert_week_5'),
  jsonb_build_object('offer_plan_id','b1170000-0000-0000-0000-0000000cc001','offer_plan_name','5-Class Pack',
                     'offer_detail','5 classes','buy_url','https://x'), 'Mia')), null);
select expect_true('7.7 template_sample_context carries offer_plan_id',
  template_sample_context('b1170000-0000-0000-0000-0000000000a0', 'b117-owner@example.com', 'Olive') ? 'offer_plan_id');

-- =============================================================================
-- 8. Archive, and the surface.
-- =============================================================================
reset role; set role authenticated; select set_config('request.jwt.claim.sub','b1170000-0000-0000-0000-0000000000a1',false);
select expect_true('8.1 an ended promotion is archived', (promotion_archive(current_setting('t.p1')::uuid) ->> 'ok')::boolean);
select expect_eq('8.2 an archived promotion leaves the list',
  (select count(*)::text from jsonb_array_elements(promotions_list('b1170000-0000-0000-0000-0000000000a0')) e
    where e ->> 'id' = current_setting('t.p1')), '0');
reset role; set role anon;
select expect_err('8.3 anon cannot read plan_promotions', $$select count(*) from plan_promotions$$, '42501');
select expect_err('8.4 anon cannot read prices', $$select plan_prices_now('b1170000-0000-0000-0000-0000000000a0')$$, '42501');
reset role;
select expect_eq('8.5 anon surface EXACTLY FOURTEEN', (select count(*)::text from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.proname not like 'expect\_%' and p.proname not in ('call_jsonb')
     and has_function_privilege('anon', p.oid, 'execute')), '14');

do $$ begin raise notice 'promotions_test: all assertions passed'; end $$;
