-- Decision 120: discount codes. UUID space 1200.
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

create or replace function t_at(p_days int, p_time time) returns timestamptz language sql stable as $$
  select (((now() at time zone 'Asia/Manila')::date + p_days) + p_time) at time zone 'Asia/Manila' $$;
create or replace function t_today() returns date language sql stable as $$
  select (now() at time zone 'Asia/Manila')::date $$;
-- Run as a signed-in user.
create or replace function t_as(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_user::text, false);
  perform set_config('role', 'authenticated', false);
end $$;
create or replace function t_reset() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', false);
  perform set_config('request.jwt.claim.sub', '', false);
end $$;
-- A member begins a plan checkout with a code; returns the purchase id or the error.
create or replace function t_begin(p_user uuid, p_plan uuid, p_code text) returns text language plpgsql as $$
declare v text;
begin
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  set local role authenticated;
  select purchase_id::text into v from xendit_begin_purchase('12000000-0000-0000-0000-000000000001', p_plan, p_code);
  reset role;
  return v;
exception when others then
  return 'ERR:' || sqlerrm;
end $$;
-- The code state of one batch code.
create or replace function t_state(p_code text) returns text language sql stable as $$
  select r ->> 'state' from discount_codes c
   cross join lateral jsonb_array_elements(discount_code_rows(c.batch_id)) r
   where c.code = p_code and r ->> 'code' = p_code limit 1 $$;
create or replace function t_check(p_code text, p_plan uuid, p_member uuid default null, p_email text default null)
returns text language sql as $$
  select coalesce(r ->> 'reason', 'ok') from (select discount_code_check_run('12000000-0000-0000-0000-000000000001',
    p_code, p_plan, false, p_member, p_email, 100000, now()) r) x $$;

-- ---- Fixtures ------------------------------------------------------------------
insert into auth.users (id, email, email_confirmed_at) values
  ('12000000-0000-0000-0000-0000000000a1','owner120@example.com', now()),
  ('12000000-0000-0000-0000-0000000000a2','desk120@example.com', now()),
  ('12000000-0000-0000-0000-0000000000e1','ana120@example.com', now()),
  ('12000000-0000-0000-0000-0000000000e2','ben120@example.com', now()),
  ('12000000-0000-0000-0000-0000000000e3','cai120@example.com', now()),
  ('12000000-0000-0000-0000-0000000000e4','dia120@example.com', now());
insert into profiles (id, email) select id, email from auth.users where id::text like '12000000%';

insert into studios (id, name, slug, timezone, currency, country, status) values
  ('12000000-0000-0000-0000-000000000001','Code Studio','code120','Asia/Manila','PHP','PH','active');
insert into studio_settings (studio_id, require_waiver, open_time, close_time,
                             private_sessions_enabled, private_lead_time_hours, private_buffer_minutes)
values ('12000000-0000-0000-0000-000000000001', false, '07:00', '21:00', true, 12, 10);
insert into locations (id, studio_id, name, is_primary) values
  ('12000000-0000-0000-0000-00000000000a','12000000-0000-0000-0000-000000000001','Main',true);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('12000000-0000-0000-0000-0000000005a1','12000000-0000-0000-0000-000000000001','12000000-0000-0000-0000-0000000000a1','owner120@example.com','owner'),
  ('12000000-0000-0000-0000-0000000005a2','12000000-0000-0000-0000-000000000001','12000000-0000-0000-0000-0000000000a2','desk120@example.com','front_desk');
insert into studio_payment_providers
  (studio_id, provider, secret_key_ciphertext, callback_token_ciphertext, callback_token_sha256,
   key_last4, test_mode, connected_by) values
  ('12000000-0000-0000-0000-000000000001','xendit','v1.x','v1.y', encode(digest('tok120','sha256'),'hex'),
   'tok0', true, '12000000-0000-0000-0000-0000000000a1');

insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, validity_days, visibility, status) values
  ('12000000-0000-0000-0000-0000000cc001','12000000-0000-0000-0000-000000000001','10-Class Pack','class_pack',100000,'PHP',10,60,'public','active'),
  ('12000000-0000-0000-0000-0000000cc002','12000000-0000-0000-0000-000000000001','5-Class Pack','class_pack',60000,'PHP',5,30,'public','active'),
  ('12000000-0000-0000-0000-0000000cc003','12000000-0000-0000-0000-000000000001','Drop-in','drop_in',15000,'PHP',1,30,'public','active');

insert into members (id, studio_id, user_id, first_name, last_name, email, status) values
  ('12000000-0000-0000-0000-00000000dd01','12000000-0000-0000-0000-000000000001','12000000-0000-0000-0000-0000000000e1','Ana','One','ana120@example.com','active'),
  ('12000000-0000-0000-0000-00000000dd02','12000000-0000-0000-0000-000000000001','12000000-0000-0000-0000-0000000000e2','Ben','Two','ben120@example.com','active'),
  ('12000000-0000-0000-0000-00000000dd03','12000000-0000-0000-0000-000000000001','12000000-0000-0000-0000-0000000000e3','Cai','Three','cai120@example.com','active'),
  ('12000000-0000-0000-0000-00000000dd04','12000000-0000-0000-0000-000000000001','12000000-0000-0000-0000-0000000000e4','Dia','Four','dia120@example.com','active');

-- Private sessions.
insert into instructors (id, studio_id, display_name, status, teaches_privates) values
  ('12000000-0000-0000-0000-0000000001c1','12000000-0000-0000-0000-000000000001','Ines Coach','active',true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('12000000-0000-0000-0000-00000000b001','12000000-0000-0000-0000-000000000001','12000000-0000-0000-0000-00000000000a','Studio',8);
insert into private_session_types (id, studio_id, name, price_cents, people, duration_min, coach_pay_cents, sort) values
  ('12000000-0000-0000-0000-0000000007a1','12000000-0000-0000-0000-000000000001','Private 1:1',200000,1,50,100000,1);

-- =============================================================================
-- 1. Creating codes.
-- =============================================================================
select t_as('12000000-0000-0000-0000-0000000000a2');
do $$ begin
  perform discount_code_create_batch('12000000-0000-0000-0000-000000000001','Nope',10,3,current_date,current_date+10,
    array['12000000-0000-0000-0000-0000000cc001']::uuid[]);
  raise exception 'FAIL  front desk created codes';
exception when sqlstate 'PT403' then raise notice 'PASS  front desk cannot create codes';
end $$;
select t_as('12000000-0000-0000-0000-0000000000a1');
select set_config('t.b1', discount_code_create_batch('12000000-0000-0000-0000-000000000001','Friends 20',20,25,
  t_today() - 1, t_today() + 10, array['12000000-0000-0000-0000-0000000cc001','12000000-0000-0000-0000-0000000cc002']::uuid[], true) ->> 'batch_id', false);
select set_config('t.sh', discount_code_create_shared('12000000-0000-0000-0000-000000000001','xmas10','Christmas',10,
  t_today() - 1, t_today() + 10, array['12000000-0000-0000-0000-0000000cc001']::uuid[], 2) ->> 'batch_id', false);
select expect_text('a shared code that is taken is refused',
  discount_code_create_shared('12000000-0000-0000-0000-000000000001','XMAS10','Again',10,
    t_today(), t_today() + 10, array['12000000-0000-0000-0000-0000000cc001']::uuid[], 2) ->> 'message',
  'That code is already in use. Choose another.');
select t_reset();

select expect_num('a batch of 25 makes 25 codes', (select count(*) from discount_codes where batch_id = current_setting('t.b1')::uuid), 25);
select expect_num('all 25 are different', (select count(distinct code) from discount_codes where batch_id = current_setting('t.b1')::uuid), 25);
select expect_true('codes read {STUDIO}-XXXX-XXXX with no look-alike letters',
  (select bool_and(code ~ '^CODE120-[ABCDEFGHJKMNPQRSTUVWXYZ2-9]{4}-[ABCDEFGHJKMNPQRSTUVWXYZ2-9]{4}$')
     from discount_codes where batch_id = current_setting('t.b1')::uuid));
select expect_num('one audit row per batch created',
  (select count(*) from audit_logs where action = 'discount_code.batch_created'
      and studio_id = '12000000-0000-0000-0000-000000000001'), 2);

select set_config('t.c1', (select code from discount_codes where batch_id = current_setting('t.b1')::uuid order by code limit 1 offset 0), false);
select set_config('t.c2', (select code from discount_codes where batch_id = current_setting('t.b1')::uuid order by code limit 1 offset 1), false);
select set_config('t.c3', (select code from discount_codes where batch_id = current_setting('t.b1')::uuid order by code limit 1 offset 2), false);
select set_config('t.c4', (select code from discount_codes where batch_id = current_setting('t.b1')::uuid order by code limit 1 offset 3), false);
select set_config('t.c5', (select code from discount_codes where batch_id = current_setting('t.b1')::uuid order by code limit 1 offset 4), false);
select set_config('t.c6', (select code from discount_codes where batch_id = current_setting('t.b1')::uuid order by code limit 1 offset 5), false);
select set_config('t.c7', (select code from discount_codes where batch_id = current_setting('t.b1')::uuid order by code limit 1 offset 6), false);

-- =============================================================================
-- 2. The checks.
-- =============================================================================
select expect_text('an unknown code is not valid', t_check('NOPE-1234', '12000000-0000-0000-0000-0000000cc001'), 'invalid');
select expect_text('a code is not case sensitive and ignores spaces',
  t_check(' ' || lower(current_setting('t.c1')) || ' ', '12000000-0000-0000-0000-0000000cc001'), 'ok');
select expect_text('a plan the code does not cover is refused', t_check(current_setting('t.c1'), '12000000-0000-0000-0000-0000000cc003'), 'not_this_plan');
select expect_text('never on a shop item, gift card or reservation fee (no plan, not private)',
  t_check(current_setting('t.c1'), null), 'not_this_plan');
select expect_true('the gift card and reservation fee begins take no code',
  (select bool_and(pg_get_function_identity_arguments(oid) not like '%p_code%') from pg_proc
    where proname in ('gift_card_begin','xendit_begin_reservation','reserve_free_first')));
select expect_true('the shop begin takes a code (Decision 120 b)',
  (select bool_and(pg_get_function_identity_arguments(oid) like '%p_code%') from pg_proc
    where proname = 'xendit_begin_product_purchase'));
update discount_code_batches set starts_on = t_today() + 2 where id = current_setting('t.b1')::uuid;
select expect_text('before it starts it is not valid', t_check(current_setting('t.c1'), '12000000-0000-0000-0000-0000000cc001'), 'invalid');
update discount_code_batches set starts_on = t_today() - 10, ends_on = t_today() - 1 where id = current_setting('t.b1')::uuid;
select expect_text('after it ends it has expired', t_check(current_setting('t.c1'), '12000000-0000-0000-0000-0000000cc001'), 'expired');
update discount_code_batches set starts_on = t_today() - 1, ends_on = t_today() + 10 where id = current_setting('t.b1')::uuid;
select expect_text('the expired sentence',
  (select discount_code_check_run('12000000-0000-0000-0000-000000000001', 'NOPE', null, false, null, null, 1, now()) ->> 'message'),
  'That code isn''t valid.');

-- =============================================================================
-- 3. A single-use code: held, then used once.
-- =============================================================================
select set_config('t.p1', t_begin('12000000-0000-0000-0000-0000000000e1','12000000-0000-0000-0000-0000000cc001', current_setting('t.c1')), false);
select expect_true('a member begins a checkout with a code', current_setting('t.p1') !~ '^ERR');
select expect_text('the checkout is at the code price (20% off ₱1,000) with the code held',
  (select amount_cents || '/' || list_price_cents || '/' || discount_cents || '/' || coalesce(promotion_id::text, 'none') || '/' || u.status
     from xendit_purchases xp join discount_code_uses u on u.id = xp.discount_code_use_id
    where xp.id = current_setting('t.p1')::uuid), '80000/100000/20000/none/held');
select expect_text('while held, another checkout is told to wait',
  t_begin('12000000-0000-0000-0000-0000000000e2','12000000-0000-0000-0000-0000000cc001', current_setting('t.c1')),
  'ERR:This code is being used in another checkout. Try again in 30 minutes.');
-- It expires: the hold is released and the code is free again.
update xendit_purchases set status = 'expired' where id = current_setting('t.p1')::uuid;
select expect_text('an expired checkout releases the code',
  (select status from discount_code_uses where purchase_id = current_setting('t.p1')::uuid), 'released');
select expect_text('released, it can be used', t_check(current_setting('t.c1'), '12000000-0000-0000-0000-0000000cc001'), 'ok');
-- Ben uses it and pays.
select set_config('t.p2', t_begin('12000000-0000-0000-0000-0000000000e2','12000000-0000-0000-0000-0000000cc001', current_setting('t.c1')), false);
select xendit_activate_success_internal(current_setting('t.p2')::uuid, 'py-120-2', 'xendit');
select expect_text('the payment succeeds: the code is used, the payment records it',
  (select u.status || '/' || p.discount_code || '/' || p.amount_cents || '/' || p.discount_cents
     from discount_code_uses u join payments p on p.id = u.payment_id
    where u.purchase_id = current_setting('t.p2')::uuid), 'redeemed/' || current_setting('t.c1') || '/80000/20000');
select expect_text('once used, the code is refused for anyone',
  t_begin('12000000-0000-0000-0000-0000000000e3','12000000-0000-0000-0000-0000000cc001', current_setting('t.c1')),
  'ERR:That code has already been used.');
select expect_text('the staff list shows it used, by Ben', t_state(current_setting('t.c1')), 'used');
select expect_num('a code.redeemed audit row', (select count(*) from audit_logs where action = 'discount_code.redeemed'
  and studio_id = '12000000-0000-0000-0000-000000000001'), 1);

-- =============================================================================
-- 4. A shared code: max uses, and once per person (member and guest email).
-- =============================================================================
-- Ana at the desk.
select t_as('12000000-0000-0000-0000-0000000000a2');
select set_config('t.d1', record_manual_payment('12000000-0000-0000-0000-000000000001','12000000-0000-0000-0000-00000000dd01',
  'plan', 100000, 'cash', '12000000-0000-0000-0000-0000000cc001', p_code => 'xmas10') ->> 'payment_id', false);
select t_reset();
select expect_text('Record a payment with a code charges the code price and records it',
  (select amount_cents || '/' || discount_code || '/' || discount_cents from payments where id = current_setting('t.d1')::uuid),
  '90000/XMAS10/10000');
select expect_text('Ana cannot use the shared code twice',
  t_begin('12000000-0000-0000-0000-0000000000e1','12000000-0000-0000-0000-0000000cc001','XMAS10'),
  'ERR:You''ve already used this code.');
-- A guest buys on /buy with it.
set role anon;
select set_config('t.g1', (select purchase_id::text from plan_buy_begin('12000000-0000-0000-0000-000000000001',
  '12000000-0000-0000-0000-0000000cc001','Gia Guest','gia120@example.com','09171234567','XMAS10')), false);
select set_config('t.gp', (select code_applied::text || '/' || amount_cents || '/' || coalesce(code_message, '-')
  from plan_buy_begin('12000000-0000-0000-0000-000000000001','12000000-0000-0000-0000-0000000cc001',
       null,'gia120@example.com',null,'XMAS10', true)), false);
reset role;
select expect_text('the guest checkout is at the code price', (select amount_cents::text from xendit_purchases where id = current_setting('t.g1')::uuid), '90000');
select expect_text('a guest preview while their own checkout is pending says to wait',
  current_setting('t.gp'), 'false/100000/This code is being used in another checkout. Try again in 30 minutes.');
select xendit_activate_success_internal(current_setting('t.g1')::uuid, 'py-120-g1', 'xendit');
select expect_text('the guest use is redeemed (held payment, Decision 118)',
  (select u.status || '/' || u.buyer_email from discount_code_uses u where u.purchase_id = current_setting('t.g1')::uuid),
  'redeemed/gia120@example.com');
set role anon;
select set_config('t.gp2', (select coalesce(code_message, '-') from plan_buy_begin('12000000-0000-0000-0000-000000000001',
  '12000000-0000-0000-0000-0000000cc001', null, 'gia120@example.com', null, 'XMAS10', true)), false);
reset role;
select expect_text('the same guest email cannot use it again', current_setting('t.gp2'), 'You''ve already used this code.');
select expect_text('with both uses taken, the next person is refused',
  t_begin('12000000-0000-0000-0000-0000000000e3','12000000-0000-0000-0000-0000000cc001','XMAS10'),
  'ERR:That code has already been used.');

-- =============================================================================
-- 5. No stacking: the lower of the sale and the code price.
-- =============================================================================
insert into plan_promotions (studio_id, name, pct, starts_on, ends_on, plan_ids) values
  ('12000000-0000-0000-0000-000000000001','Holiday Sale',25, t_today() - 1, t_today() + 5,
   array['12000000-0000-0000-0000-0000000cc001']::uuid[]);
-- 20% code vs 25% sale: the sale wins, the code is not held or recorded.
select set_config('t.p3', t_begin('12000000-0000-0000-0000-0000000000e3','12000000-0000-0000-0000-0000000cc001', current_setting('t.c2')), false);
select expect_text('the sale is lower: sale price, the promotion recorded, no code',
  (select amount_cents || '/' || (promotion_id is not null)::text || '/' || coalesce(discount_code_use_id::text, 'none')
     from xendit_purchases where id = current_setting('t.p3')::uuid), '75000/true/none');
select expect_text('and the code is still unused', t_state(current_setting('t.c2')), 'unused');
-- A 40% shared code beats the sale.
select t_as('12000000-0000-0000-0000-0000000000a1');
select discount_code_create_shared('12000000-0000-0000-0000-000000000001','BIG40','Big',40,
  t_today() - 1, t_today() + 10, array['12000000-0000-0000-0000-0000000cc001']::uuid[], 5);
select t_reset();
select set_config('t.p4', t_begin('12000000-0000-0000-0000-0000000000e4','12000000-0000-0000-0000-0000000cc001','BIG40'), false);
select expect_text('the code is lower: code price, only the code recorded',
  (select amount_cents || '/' || coalesce(promotion_id::text, 'none') || '/' || (discount_code_use_id is not null)::text
     from xendit_purchases where id = current_setting('t.p4')::uuid), '60000/none/true');
delete from plan_promotions where studio_id = '12000000-0000-0000-0000-000000000001';

-- =============================================================================
-- 6. Refunds return the code, through every refund path, only while valid.
-- =============================================================================
-- (a) refund_payment_run, studio-recorded.
select set_config('t.p5', t_begin('12000000-0000-0000-0000-0000000000e3','12000000-0000-0000-0000-0000000cc001', current_setting('t.c3')), false);
select xendit_activate_success_internal(current_setting('t.p5')::uuid, 'py-120-5', 'xendit');
select refund_payment_run((select payment_id from discount_code_uses where purchase_id = current_setting('t.p5')::uuid),
                          null, 'changed mind', 'cash', 'R-1');
select expect_text('refund_payment_run returns the code', t_state(current_setting('t.c3')), 'unused');
select expect_text('returned, it can be used again', t_check(current_setting('t.c3'), '12000000-0000-0000-0000-0000000cc001'), 'ok');
-- (b) a Xendit refund settled later through apply_payment_refund.
select set_config('t.p6', t_begin('12000000-0000-0000-0000-0000000000e4','12000000-0000-0000-0000-0000000cc002', current_setting('t.c4')), false);
select xendit_activate_success_internal(current_setting('t.p6')::uuid, 'py-120-6', 'xendit');
select set_config('t.rf', refund_payment_run((select payment_id from discount_code_uses where purchase_id = current_setting('t.p6')::uuid),
                          null, 'refund', 'xendit', 'rfd-120') ->> 'refund_id', false);
select expect_text('a pending Xendit refund does not return the code yet', t_state(current_setting('t.c4')), 'used');
update payment_refunds set status = 'succeeded', settled_at = now() where id = current_setting('t.rf')::uuid;
select apply_payment_refund(current_setting('t.rf')::uuid);
select expect_text('apply_payment_refund returns the code', t_state(current_setting('t.c4')), 'unused');
-- (c) record_refund.
select set_config('t.p7', t_begin('12000000-0000-0000-0000-0000000000e1','12000000-0000-0000-0000-0000000cc001', current_setting('t.c5')), false);
select xendit_activate_success_internal(current_setting('t.p7')::uuid, 'py-120-7', 'xendit');
select t_as('12000000-0000-0000-0000-0000000000a1');
select record_refund((select payment_id from discount_code_uses where purchase_id = current_setting('t.p7')::uuid),
                     80000, 'refund', false);
select t_reset();
select expect_text('record_refund returns the code', t_state(current_setting('t.c5')), 'unused');
select expect_num('three code.returned audit rows', (select count(*) from audit_logs where action = 'discount_code.returned'
  and studio_id = '12000000-0000-0000-0000-000000000001'), 3);
-- A partial refund keeps it used.
select set_config('t.p8', t_begin('12000000-0000-0000-0000-0000000000e2','12000000-0000-0000-0000-0000000cc002', current_setting('t.c6')), false);
select xendit_activate_success_internal(current_setting('t.p8')::uuid, 'py-120-8', 'xendit');
select refund_payment_run((select payment_id from discount_code_uses where purchase_id = current_setting('t.p8')::uuid),
                          1000, 'partial', 'cash', 'R-2');
select expect_text('a partial refund keeps the code used', t_state(current_setting('t.c6')), 'used');
-- After the code ends, a refund does not return it. (The shared XMAS10 desk sale.)
update discount_code_batches set starts_on = t_today() - 20, ends_on = t_today() - 1 where id = current_setting('t.sh')::uuid;
select refund_payment_run(current_setting('t.d1')::uuid, null, 'late', 'cash', 'R-3');
select expect_text('a refund after the code ended does not return it',
  (select status from discount_code_uses where payment_id = current_setting('t.d1')::uuid), 'redeemed');

-- =============================================================================
-- 7. The instructor desk sale and a private session take a code too.
-- =============================================================================
select expect_true('sell_plan_at_desk accepts a code',
  (select pg_get_function_identity_arguments('sell_plan_at_desk'::regproc) like '%p_code%'));
select set_config('t.pv', private_book_run('12000000-0000-0000-0000-00000000dd03','12000000-0000-0000-0000-0000000007a1',
  '12000000-0000-0000-0000-0000000001c1', t_at(3, '10:00'), '[]'::jsonb, 'xendit', null, null, 'nope')::text, false);
select expect_text('a bad code on a private session is refused before anything is written',
  current_setting('t.pv')::jsonb ->> 'message', 'That code isn''t valid.');
select set_config('t.pv2', private_book_run('12000000-0000-0000-0000-00000000dd03','12000000-0000-0000-0000-0000000007a1',
  '12000000-0000-0000-0000-0000000001c1', t_at(3, '10:00'), '[]'::jsonb, 'xendit', null, null, current_setting('t.c7'))::text, false);
select expect_text('a private session at the code price (20% off ₱2,000), the code held',
  (select (current_setting('t.pv2')::jsonb ->> 'amount_cents') || '/' || u.status || '/' || coalesce(u.private_occurrence_id::text <> '', false)::text
     from xendit_purchases xp join discount_code_uses u on u.id = xp.discount_code_use_id
    where xp.id = (current_setting('t.pv2')::jsonb ->> 'purchase_id')::uuid), '160000/held/true');
select xendit_activate_success_internal((current_setting('t.pv2')::jsonb ->> 'purchase_id')::uuid, 'py-120-pv', 'xendit');
select expect_text('the private session payment records the code',
  (select p.discount_code || '/' || p.discount_cents from payments p
     join discount_code_uses u on u.payment_id = p.id
    where u.purchase_id = (current_setting('t.pv2')::jsonb ->> 'purchase_id')::uuid), current_setting('t.c7') || '/40000');

-- =============================================================================
-- 8. Sales, the staff list, cancelling, rate limits, access.
-- =============================================================================
select set_config('t.st', sales_totals('12000000-0000-0000-0000-000000000001', t_today() - 1, t_today() + 1)::text, false);
select expect_true('Sales carries a Discount codes line',
  (current_setting('t.st')::jsonb -> 'codes' ->> 'count')::int >= 4);
select t_as('12000000-0000-0000-0000-0000000000a1');
select expect_text('cancelling a used code is refused',
  discount_code_cancel((select id from discount_codes where code = current_setting('t.c1'))) ->> 'message',
  'That code has been used, so it can''t be cancelled.');
select expect_text('cancelling an unused code works',
  discount_code_cancel((select id from discount_codes where batch_id = current_setting('t.b1')::uuid order by code offset 20 limit 1)) ->> 'ok', 'true');
select expect_true('the batch list shows the batch and the shared code',
  jsonb_array_length(discount_code_batches_list('12000000-0000-0000-0000-000000000001')) = 3);
select t_reset();
select expect_true('the list shows Unused, Used and Cancelled codes',
  (select count(distinct r ->> 'state') = 3 from jsonb_array_elements(discount_code_rows(current_setting('t.b1')::uuid)) r));
select expect_text('a cancelled code is not valid',
  t_check((select code from discount_codes where batch_id = current_setting('t.b1')::uuid and cancelled_at is not null), '12000000-0000-0000-0000-0000000cc001'),
  'invalid');
do $$ declare i int; v text; begin
  for i in 1..10 loop v := t_check('GUESS-' || i, '12000000-0000-0000-0000-0000000cc001', '12000000-0000-0000-0000-00000000dd04'); end loop;
  v := t_check('GUESS-X', '12000000-0000-0000-0000-0000000cc001', '12000000-0000-0000-0000-00000000dd04');
  if v = 'rate_limited' then raise notice 'PASS  the 11th check in ten minutes by one member is rate limited';
  else raise exception 'FAIL  rate limit, got %', v; end if;
end $$;
select t_as('12000000-0000-0000-0000-0000000000e1');
select expect_num('a member reads no codes', (select count(*) from discount_codes), 0);
do $$ begin
  perform discount_code_rows(current_setting('t.b1')::uuid);
  raise exception 'FAIL  a member read the code list';
exception when sqlstate 'PT403' then raise notice 'PASS  a member cannot read the code list';
end $$;
select t_reset();
set role anon;
do $$ declare n int; begin
  select count(*) into n from discount_codes;
  raise exception 'FAIL  anon read % codes', n;
exception when insufficient_privilege then raise notice 'PASS  anon cannot read codes';
end $$;
reset role;
select expect_num('anon functions: exactly fifteen',
  (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not like 'expect\_%' and p.proname not like 't\_%' and p.proname not in ('call_jsonb')), 15);

\echo discount_codes_test PASS
