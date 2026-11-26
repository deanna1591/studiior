-- Step 13: 116 (d), 80 (f), 103 (l), 97 (b), 119 (a), 120 (a), 120 (b). UUID space 13d0.
-- (95 (c)'s labels are asserted in flex_rescue_test.)
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
-- A member begins a plan checkout; returns the purchase id or the error.
create or replace function t_begin(p_user uuid, p_plan uuid, p_code text) returns text language plpgsql as $$
declare v text;
begin
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  set local role authenticated;
  select purchase_id::text into v from xendit_begin_purchase('13d00000-0000-0000-0000-000000000001', p_plan, p_code);
  reset role;
  return v;
exception when others then return 'ERR:' || sqlerrm;
end $$;
-- A member begins a shop checkout; returns "purchase/amount" or the error.
create or replace function t_shop(p_user uuid, p_product uuid, p_qty int, p_code text) returns text language plpgsql as $$
declare v text;
begin
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  set local role authenticated;
  select purchase_id::text || '/' || amount_cents into v
    from xendit_begin_product_purchase('13d00000-0000-0000-0000-000000000001', p_product, p_qty, p_code);
  reset role;
  return v;
exception when others then return 'ERR:' || sqlerrm;
end $$;
create or replace function t_state(p_code text) returns text language sql stable as $$
  select r ->> 'state' from discount_codes c
   cross join lateral jsonb_array_elements(discount_code_rows(c.batch_id)) r
   where c.code = p_code and r ->> 'code' = p_code limit 1 $$;

-- ---- Fixtures ------------------------------------------------------------------
insert into auth.users (id, email, email_confirmed_at) values
  ('13d00000-0000-0000-0000-0000000000a1','owner13@example.com', now()),
  ('13d00000-0000-0000-0000-0000000000a2','desk13@example.com', now()),
  ('13d00000-0000-0000-0000-0000000000e1','pia13@example.org', now()),
  ('13d00000-0000-0000-0000-0000000000e2','ros13@example.org', now()),
  ('13d00000-0000-0000-0000-0000000000e3','tess13@example.org', now()),
  ('13d00000-0000-0000-0000-0000000000e4','uma13@example.org', now()),
  ('13d00000-0000-0000-0000-0000000000e5','vic13@example.org', now());
insert into profiles (id, email) select id, email from auth.users where id::text like '13d00000%';

insert into studios (id, name, slug, timezone, currency, country, status) values
  ('13d00000-0000-0000-0000-000000000001','Thirteen Studio','thirteen','Asia/Manila','PHP','PH','active');
insert into studio_settings (studio_id, require_waiver, open_time, close_time,
                             private_sessions_enabled, private_lead_time_hours, private_buffer_minutes,
                             free_first_class_enabled, free_first_reservation_fee_cents, free_first_reservation_from)
values ('13d00000-0000-0000-0000-000000000001', false, '07:00', '21:00', true, 12, 10,
        true, 50000, t_today() - 30);
insert into locations (id, studio_id, name, is_primary) values
  ('13d00000-0000-0000-0000-00000000000a','13d00000-0000-0000-0000-000000000001','Main',true);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('13d00000-0000-0000-0000-0000000005a1','13d00000-0000-0000-0000-000000000001','13d00000-0000-0000-0000-0000000000a1','owner13@example.com','owner'),
  ('13d00000-0000-0000-0000-0000000005a2','13d00000-0000-0000-0000-000000000001','13d00000-0000-0000-0000-0000000000a2','desk13@example.com','front_desk');
insert into studio_payment_providers
  (studio_id, provider, secret_key_ciphertext, callback_token_ciphertext, callback_token_sha256,
   key_last4, test_mode, connected_by) values
  ('13d00000-0000-0000-0000-000000000001','xendit','v1.x','v1.y', encode(digest('tok13','sha256'),'hex'),
   'tok0', true, '13d00000-0000-0000-0000-0000000000a1');

insert into instructors (id, studio_id, display_name, status, teaches_privates) values
  ('13d00000-0000-0000-0000-0000000001c1','13d00000-0000-0000-0000-000000000001','Ines Coach','active',true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('13d00000-0000-0000-0000-00000000b001','13d00000-0000-0000-0000-000000000001','13d00000-0000-0000-0000-00000000000a','Studio',8),
  ('13d00000-0000-0000-0000-00000000b002','13d00000-0000-0000-0000-000000000001','13d00000-0000-0000-0000-00000000000a','Back',8);
insert into private_session_types (id, studio_id, name, price_cents, people, duration_min, coach_pay_cents, sort) values
  ('13d00000-0000-0000-0000-0000000007a1','13d00000-0000-0000-0000-000000000001','Private 1:1',200000,1,50,100000,1),
  ('13d00000-0000-0000-0000-0000000007a2','13d00000-0000-0000-0000-000000000001','Duo',300000,2,50,120000,2);

insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, validity_days, visibility, status,
                              private_pack, private_session_type_id, restrictions) values
  ('13d00000-0000-0000-0000-0000000cc001','13d00000-0000-0000-0000-000000000001','Drop-in','drop_in',15000,'PHP',1,30,'public','active', false, null, '{}'),
  ('13d00000-0000-0000-0000-0000000cc002','13d00000-0000-0000-0000-000000000001','Duo x2','class_pack',550000,'PHP',2,30,'public','active', true,
   '13d00000-0000-0000-0000-0000000007a2', '{"class_type_ids":["private-only"]}'),
  ('13d00000-0000-0000-0000-0000000cc003','13d00000-0000-0000-0000-000000000001','Single Duo','class_pack',300000,'PHP',1,30,'public','active', true,
   '13d00000-0000-0000-0000-0000000007a2', '{"class_type_ids":["private-only"]}'),
  -- left without a type: the trigger gives it the one-person type
  ('13d00000-0000-0000-0000-0000000cc004','13d00000-0000-0000-0000-000000000001','Solo x5','class_pack',900000,'PHP',5,60,'public','active', true,
   null, '{"class_type_ids":["private-only"]}');

insert into members (id, studio_id, user_id, first_name, last_name, email, status, marketing_opt_in) values
  ('13d00000-0000-0000-0000-00000000dd01','13d00000-0000-0000-0000-000000000001','13d00000-0000-0000-0000-0000000000e1','Pia','One','pia13@example.org','active', true),
  ('13d00000-0000-0000-0000-00000000dd02','13d00000-0000-0000-0000-000000000001','13d00000-0000-0000-0000-0000000000e2','Ros','Two','ros13@example.org','lead', true),
  ('13d00000-0000-0000-0000-00000000dd03','13d00000-0000-0000-0000-000000000001','13d00000-0000-0000-0000-0000000000e3','Tess','Three','tess13@example.org','active', true),
  ('13d00000-0000-0000-0000-00000000dd04','13d00000-0000-0000-0000-000000000001','13d00000-0000-0000-0000-0000000000e4','Uma','Four','uma13@example.org','active', true),
  ('13d00000-0000-0000-0000-00000000dd05','13d00000-0000-0000-0000-000000000001','13d00000-0000-0000-0000-0000000000e5','Vic','Five','vic13@example.org','active', true);

insert into products (id, studio_id, name, price_cents, currency, track_stock, stock, status) values
  ('13d00000-0000-0000-0000-0000000fa001','13d00000-0000-0000-0000-000000000001','Grip socks',30000,'PHP',true,5,'active'),
  ('13d00000-0000-0000-0000-0000000fa002','13d00000-0000-0000-0000-000000000001','Mat',90000,'PHP',false,0,'active'),
  ('13d00000-0000-0000-0000-0000000fa003','13d00000-0000-0000-0000-000000000001','Cap',40000,'PHP',true,0,'active');

-- =============================================================================
-- 1. 116 (d): a private pack is for one session type.
-- =============================================================================
select expect_text('a pack left without a type takes the one-person type',
  (select private_session_type_id::text from membership_plans where id = '13d00000-0000-0000-0000-0000000cc004'),
  '13d00000-0000-0000-0000-0000000007a1');
do $$ begin
  insert into membership_plans (studio_id, name, type, price_cents, currency, credits, visibility, status, private_pack, private_session_type_id)
  values ('13d00000-0000-0000-0000-000000000001','Not a pack','class_pack',1000,'PHP',1,'public','active', false,
          '13d00000-0000-0000-0000-0000000007a2');
  raise notice 'PASS  a plan that is not a private pack carries no session type (%)',
    (select coalesce(private_session_type_id::text, 'null') from membership_plans where name = 'Not a pack');
end $$;
-- Pia holds the Duo pack (2 credits).
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, credits_remaining, starts_on, expires_on)
values ('13d00000-0000-0000-0000-00000000ee01','13d00000-0000-0000-0000-000000000001','13d00000-0000-0000-0000-00000000dd01',
        '13d00000-0000-0000-0000-0000000cc002','active',550000,'PHP',2, t_today(), t_today() + 30);
select expect_text('a Duo credit is refused for a 1:1 session',
  private_book_run('13d00000-0000-0000-0000-00000000dd01','13d00000-0000-0000-0000-0000000007a1',
    '13d00000-0000-0000-0000-0000000001c1', t_at(3, '10:00'), '[]'::jsonb, 'pack') ->> 'reason', 'no_pack_credit');
select expect_num('the Duo pack is untouched', (select credits_remaining from memberships where id = '13d00000-0000-0000-0000-00000000ee01'), 2);
select set_config('t.pv1', private_book_run('13d00000-0000-0000-0000-00000000dd01','13d00000-0000-0000-0000-0000000007a2',
    '13d00000-0000-0000-0000-0000000001c1', t_at(3, '12:00'),
    '[{"name":"Quin Friend","email":"quin13@example.org"}]'::jsonb, 'pack') ->> 'occurrence_id', false);
select expect_num('a Duo credit books a Duo', (select credits_remaining from memberships where id = '13d00000-0000-0000-0000-00000000ee01'), 1);
select expect_text('the seat is on the Duo pack',
  (select membership_id::text from bookings where occurrence_id = current_setting('t.pv1')::uuid and member_id = '13d00000-0000-0000-0000-00000000dd01'),
  '13d00000-0000-0000-0000-00000000ee01');
select t_as('13d00000-0000-0000-0000-0000000000e1');
select expect_text('my_private_credits shows the Duo credit',
  (select type_name || ':' || credits from my_private_credits('13d00000-0000-0000-0000-000000000001')), 'Duo:1');
select expect_text('a move keeps the session on the same pack',
  private_move(current_setting('t.pv1')::uuid, t_at(4, '12:00')) ->> 'ok', 'true');
select t_reset();
select expect_num('after the move the pack still has 1', (select credits_remaining from memberships where id = '13d00000-0000-0000-0000-00000000ee01'), 1);
select t_as('13d00000-0000-0000-0000-0000000000e1');
select private_cancel(current_setting('t.pv1')::uuid);
select t_reset();
select expect_num('an on-time cancel returns the credit to the Duo pack', (select credits_remaining from memberships where id = '13d00000-0000-0000-0000-00000000ee01'), 2);
select set_config('t.pv2', private_book_run('13d00000-0000-0000-0000-00000000dd01','13d00000-0000-0000-0000-0000000007a2',
    '13d00000-0000-0000-0000-0000000001c1', t_at(5, '12:00'),
    '[{"name":"Quin Friend","email":"quin13@example.org"}]'::jsonb, 'pack') ->> 'occurrence_id', false);
select t_as('13d00000-0000-0000-0000-0000000000a1');
select private_studio_cancel(current_setting('t.pv2')::uuid, 'Coach is ill');
select t_reset();
select expect_num('a studio cancel returns the credit to the Duo pack', (select credits_remaining from memberships where id = '13d00000-0000-0000-0000-00000000ee01'), 2);

-- A single-session Duo plan, bought by a member, by a guest, and with a code.
select set_config('t.sd1', t_begin('13d00000-0000-0000-0000-0000000000e4','13d00000-0000-0000-0000-0000000cc003', null), false);
select xendit_activate_success_internal(current_setting('t.sd1')::uuid, 'py-13-sd1', 'xendit');
select expect_text('a member buys a single Duo: one Duo credit',
  (select p.name || ':' || m.credits_remaining from memberships m join membership_plans p on p.id = m.plan_id
    where m.member_id = '13d00000-0000-0000-0000-00000000dd04' and p.id = '13d00000-0000-0000-0000-0000000cc003'), 'Single Duo:1');
set role anon;
select set_config('t.sd2', (select purchase_id::text from plan_buy_begin('13d00000-0000-0000-0000-000000000001',
  '13d00000-0000-0000-0000-0000000cc003','Gail Guest','gail13@example.org','09171234567')), false);
reset role;
select xendit_activate_success_internal(current_setting('t.sd2')::uuid, 'py-13-sd2', 'xendit');
select expect_text('a guest buys a single Duo: held for claim',
  (select guest_status from xendit_purchases where id = current_setting('t.sd2')::uuid), 'held');

-- =============================================================================
-- 2. 120 (a): codes up to 100%. Batch codes at 100% on the Drop-in, the single
--    Duo and private sessions; a shared 100% code with one use.
-- =============================================================================
select t_as('13d00000-0000-0000-0000-0000000000a1');
select expect_text('a code of 101% is refused',
  discount_code_create_batch('13d00000-0000-0000-0000-000000000001','Too much',101,1,t_today(),t_today()+5,
    array['13d00000-0000-0000-0000-0000000cc001']::uuid[]) ->> 'message', 'The percent off is a whole number from 1 to 100.');
select set_config('t.b100', discount_code_create_batch('13d00000-0000-0000-0000-000000000001','Free',100,8,
  t_today() - 1, t_today() + 10, array['13d00000-0000-0000-0000-0000000cc001','13d00000-0000-0000-0000-0000000cc003']::uuid[], true) ->> 'batch_id', false);
select set_config('t.sh', discount_code_create_shared('13d00000-0000-0000-0000-000000000001','FREEONE','Free once',100,
  t_today() - 1, t_today() + 10, array['13d00000-0000-0000-0000-0000000cc001']::uuid[], 1) ->> 'batch_id', false);
-- 120 (b): shop codes. 100% and 20% on the socks and the cap; nothing on the mat.
select set_config('t.bs100', discount_code_create_batch('13d00000-0000-0000-0000-000000000001','Free socks',100,3,
  t_today() - 1, t_today() + 10, '{}'::uuid[], false,
  array['13d00000-0000-0000-0000-0000000fa001','13d00000-0000-0000-0000-0000000fa003']::uuid[]) ->> 'batch_id', false);
select set_config('t.bs20', discount_code_create_batch('13d00000-0000-0000-0000-000000000001','Socks 20',20,3,
  t_today() - 1, t_today() + 10, '{}'::uuid[], false,
  array['13d00000-0000-0000-0000-0000000fa001']::uuid[]) ->> 'batch_id', false);
select t_reset();
do $$ declare i int := 0; r record; begin
  for r in select code from discount_codes where batch_id = current_setting('t.b100')::uuid order by code loop
    i := i + 1; perform set_config('t.f' || i, r.code, false); end loop;
  i := 0;
  for r in select code from discount_codes where batch_id = current_setting('t.bs100')::uuid order by code loop
    i := i + 1; perform set_config('t.s' || i, r.code, false); end loop;
  i := 0;
  for r in select code from discount_codes where batch_id = current_setting('t.bs20')::uuid order by code loop
    i := i + 1; perform set_config('t.q' || i, r.code, false); end loop;
end $$;

-- (1) Member checkout: completes at 0 with no Xendit session.
select set_config('t.m1', t_begin('13d00000-0000-0000-0000-0000000000e3','13d00000-0000-0000-0000-0000000cc001', current_setting('t.f1')), false);
select expect_text('member checkout at 100%: completed at 0',
  (select status || '/' || amount_cents from xendit_purchases where id = current_setting('t.m1')::uuid), 'succeeded/0');
select expect_text('...a 0 payment carrying the code and the amount taken off',
  (select p.amount_cents || '/' || p.discount_code || '/' || p.discount_cents from payments p
     join discount_code_uses u on u.payment_id = p.id where u.purchase_id = current_setting('t.m1')::uuid),
  '0/' || current_setting('t.f1') || '/15000');
select expect_text('...the code is used at once', t_state(current_setting('t.f1')), 'used');
select expect_true('...the membership is active',
  exists (select 1 from memberships where member_id = '13d00000-0000-0000-0000-00000000dd03'
            and plan_id = '13d00000-0000-0000-0000-0000000cc001' and status = 'active'));
-- (2) Guest /buy at 0: held for claim, no payment step.
set role anon;
select set_config('t.g0', (select purchase_id::text || '/' || amount_cents from plan_buy_begin('13d00000-0000-0000-0000-000000000001',
  '13d00000-0000-0000-0000-0000000cc003','Hal Guest','hal13@example.org','09171234568', current_setting('t.f2'))), false);
reset role;
select expect_text('guest /buy at 100%: completed at 0 and held for claim',
  (select status || '/' || amount_cents || '/' || guest_status from xendit_purchases where id = split_part(current_setting('t.g0'), '/', 1)::uuid),
  'succeeded/0/held');
select expect_text('...the code is used', t_state(current_setting('t.f2')), 'used');
-- (3) Private session pay step at 0.
select set_config('t.pv0', private_book_run('13d00000-0000-0000-0000-00000000dd05','13d00000-0000-0000-0000-0000000007a1',
  '13d00000-0000-0000-0000-0000000001c1', t_at(6, '10:00'), '[]'::jsonb, 'xendit', null, null, current_setting('t.f3'))::text, false);
select expect_text('private session at 100%: confirmed with no checkout',
  current_setting('t.pv0')::jsonb ->> 'confirmed', 'true');
select expect_text('...a 0 private payment with the code',
  (select p.amount_cents || '/' || p.discount_code from payments p join bookings b on b.id = p.booking_id
    where b.occurrence_id = (current_setting('t.pv0')::jsonb ->> 'occurrence_id')::uuid and p.kind = 'private'),
  '0/' || current_setting('t.f3'));
select expect_text('...the code is used', t_state(current_setting('t.f3')), 'used');
-- (4) Record a payment at the desk.
select t_as('13d00000-0000-0000-0000-0000000000a2');
select set_config('t.d0', record_manual_payment('13d00000-0000-0000-0000-000000000001','13d00000-0000-0000-0000-00000000dd04',
  'plan', 15000, 'cash', '13d00000-0000-0000-0000-0000000cc001', p_code => current_setting('t.f4')) ->> 'payment_id', false);
select t_reset();
select expect_text('Record a payment at 100%: a 0 payment with the code',
  (select amount_cents || '/' || discount_code from payments where id = current_setting('t.d0')::uuid), '0/' || current_setting('t.f4'));
-- (5) Sold a plan at desk.
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('13d00000-0000-0000-0000-0000000ab001','13d00000-0000-0000-0000-000000000001','Reformer',50,8);
insert into class_occurrences (id, studio_id, location_id, class_type_id, name, instructor_id, room_id, capacity, starts_at, ends_at) values
  ('13d00000-0000-0000-0000-0000000ac001','13d00000-0000-0000-0000-000000000001','13d00000-0000-0000-0000-00000000000a',
   '13d00000-0000-0000-0000-0000000ab001','Reformer','13d00000-0000-0000-0000-0000000001c1','13d00000-0000-0000-0000-00000000b002',
   8, t_at(0, '20:00'), t_at(0, '20:50'));
insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source) values
  ('13d00000-0000-0000-0000-000000000001','13d00000-0000-0000-0000-0000000ac001','13d00000-0000-0000-0000-00000000dd05','booked','front_desk','drop_in');
select t_as('13d00000-0000-0000-0000-0000000000a2');
select set_config('t.sd', sell_plan_at_desk('13d00000-0000-0000-0000-0000000ac001','13d00000-0000-0000-0000-00000000dd05',
  '13d00000-0000-0000-0000-0000000cc001','cash', null, false, current_setting('t.f5'))::text, false);
select t_reset();
select expect_text('Sold a plan at desk at 100%: a 0 payment with the code',
  (select amount_cents || '/' || discount_code from payments where discount_code = current_setting('t.f5')),
  '0/' || current_setting('t.f5'));
-- The shared 100% code with one use.
select set_config('t.sh1', t_begin('13d00000-0000-0000-0000-0000000000e1','13d00000-0000-0000-0000-0000000cc001','FREEONE'), false);
select expect_text('a shared 100% code completes for the first person',
  (select status from xendit_purchases where id = current_setting('t.sh1')::uuid), 'succeeded');
select expect_text('...and its one use is taken',
  t_begin('13d00000-0000-0000-0000-0000000000e4','13d00000-0000-0000-0000-0000000cc001','FREEONE'),
  'ERR:That code has already been used.');
-- The receipt line and Sales.
select expect_true('every 0 payment carries the code for the receipt line',
  (select bool_and(discount_code is not null) from payments
    where studio_id = '13d00000-0000-0000-0000-000000000001' and amount_cents = 0 and status = 'succeeded'));
select expect_true('Sales counts the codes and the amount taken off',
  (select (s -> 'codes' ->> 'count')::int >= 6 and (s -> 'codes' ->> 'total_cents')::int >= 15000 * 4
     from (select sales_totals('13d00000-0000-0000-0000-000000000001', t_today() - 1, t_today() + 1) s) x));
-- Refunding a 0 purchase cancels it and returns the code.
select refund_payment_run((select payment_id from discount_code_uses where purchase_id = current_setting('t.m1')::uuid),
  null, 'test', null, null);
select expect_text('a 0 purchase refunded: payment refunded',
  (select p.status::text from payments p join discount_code_uses u on u.payment_id = p.id where u.purchase_id = current_setting('t.m1')::uuid), 'refunded');
select expect_text('...the membership cancelled',
  (select status::text from memberships where member_id = '13d00000-0000-0000-0000-00000000dd03'
      and plan_id = '13d00000-0000-0000-0000-0000000cc001' order by created_at desc limit 1), 'cancelled');
select expect_text('...and the code returned', t_state(current_setting('t.f1')), 'unused');

-- =============================================================================
-- 3. 120 (b): codes on shop items.
-- =============================================================================
select set_config('t.sh0', t_shop('13d00000-0000-0000-0000-0000000000e3','13d00000-0000-0000-0000-0000000fa001',1, current_setting('t.s1')), false);
select expect_text('a 100% code on a sock: no checkout, 0 due', split_part(current_setting('t.sh0'), '/', 2), '0');
select expect_text('...the order is paid, to collect',
  (select po.status from xendit_purchases xp join product_orders po on po.id = xp.product_order_id
    where xp.id = split_part(current_setting('t.sh0'), '/', 1)::uuid), 'paid');
select expect_num('...stock goes down by one', (select stock from products where id = '13d00000-0000-0000-0000-0000000fa001'), 4);
select expect_text('...a 0 payment with the code line',
  (select p.amount_cents || '/' || p.discount_code || '/' || p.discount_cents from payments p
     join xendit_purchases xp on xp.product_order_id = p.product_order_id
    where xp.id = split_part(current_setting('t.sh0'), '/', 1)::uuid), '0/' || current_setting('t.s1') || '/30000');
select expect_text('...the code is used', t_state(current_setting('t.s1')), 'used');
select set_config('t.sh2', t_shop('13d00000-0000-0000-0000-0000000000e4','13d00000-0000-0000-0000-0000000fa001',1, current_setting('t.q1')), false);
select expect_text('a 20% code on a sock: 240.00 due', split_part(current_setting('t.sh2'), '/', 2), '24000');
select xendit_activate_success_internal(split_part(current_setting('t.sh2'), '/', 1)::uuid, 'py-13-sock', 'xendit');
select expect_text('...the paid order records the code',
  (select p.amount_cents || '/' || p.discount_code || '/' || p.discount_cents from payments p
     join xendit_purchases xp on xp.product_order_id = p.product_order_id
    where xp.id = split_part(current_setting('t.sh2'), '/', 1)::uuid), '24000/' || current_setting('t.q1') || '/6000');
select expect_text('a code not ticked for the item is refused',
  t_shop('13d00000-0000-0000-0000-0000000000e4','13d00000-0000-0000-0000-0000000fa002',1, current_setting('t.q2')),
  'ERR:That code doesn''t apply to this item.');
select expect_text('a sold-out item is refused even with a code',
  t_shop('13d00000-0000-0000-0000-0000000000e4','13d00000-0000-0000-0000-0000000fa003',1, current_setting('t.s2')),
  'ERR:Only 0 left.');
select t_as('13d00000-0000-0000-0000-0000000000a2');
select set_config('t.ss', record_product_sale('13d00000-0000-0000-0000-000000000001','13d00000-0000-0000-0000-0000000fa001',1,
  '13d00000-0000-0000-0000-00000000dd05','cash', null, null, current_setting('t.q3')) ->> 'payment_id', false);
select t_reset();
select expect_text('a staff shop sale takes the code',
  (select amount_cents || '/' || discount_code from payments where id = current_setting('t.ss')::uuid), '24000/' || current_setting('t.q3'));
select expect_text('...the code is used', t_state(current_setting('t.q3')), 'used');
select t_as('13d00000-0000-0000-0000-0000000000a1');
select record_refund((select p.id from payments p join xendit_purchases xp on xp.product_order_id = p.product_order_id
                       where xp.id = split_part(current_setting('t.sh0'), '/', 1)::uuid), null, 'test', true);
select t_reset();
select expect_num('refunding the 0 sock order restocks it', (select stock from products where id = '13d00000-0000-0000-0000-0000000fa001'), 3);
select expect_text('...and returns the code', t_state(current_setting('t.s1')), 'unused');

-- =============================================================================
-- 4. 80 (f): the text part reads as prose; paired tokens.
-- =============================================================================
insert into notification_templates_overrides (studio_id, key, subject, body, body_html)
values ('13d00000-0000-0000-0000-000000000001','checkout_rescue_plan','Hi',
        E'Hi {first_name},\n\n::: card\nname: {item_name}\ndetail: Ready when you are\n:::\n\n[Finish]({retry_url}){button}',
        '<p>card</p>');
select expect_true('a card email''s text part has no ":::"',
  (select text_body !~ ':::' and text_body ~ 'Finish: https://x' and text_body ~ 'Ready when you are'
     from render_email('13d00000-0000-0000-0000-000000000001','checkout_rescue_plan','member','Hi',
       E'Hi {first_name},\n\n::: card\nname: {item_name}\ndetail: Ready when you are\n:::\n\n[Finish]({retry_url}){button}',
       '<p>card</p>', '{"item_name":"Pack","retry_url":"https://x"}'::jsonb, 'Pia')));
update notification_templates_overrides set body_text = 'Saved text {item_name}'
 where studio_id = '13d00000-0000-0000-0000-000000000001' and key = 'checkout_rescue_plan';
select expect_true('the saved plain-text rendering is used for the text part',
  (select text_body ~ '^Saved text Pack'
     from render_email('13d00000-0000-0000-0000-000000000001','checkout_rescue_plan','member','Hi',
       E'Hi {first_name},\n\n::: card\nname: {item_name}\ndetail: Ready when you are\n:::\n\n[Finish]({retry_url}){button}',
       '<p>card</p>', '{"item_name":"Pack","retry_url":"https://x"}'::jsonb, 'Pia')));
select expect_true('paired tokens: each part takes its own half',
  (select html_body ~ '<b>HTML half</b>' and text_body ~ 'TEXT half' and text_body !~ '<b>'
     from render_email('13d00000-0000-0000-0000-000000000001','booking_confirmed','member','S',
       'Text: {extra_html}', '<p>{extra_line}</p>',
       '{"extra_line":"TEXT half","extra_html":"<b>HTML half</b>"}'::jsonb, 'Pia')));

-- =============================================================================
-- 5. 103 (l): a staff free-first booking uses the member's credit.
-- =============================================================================
insert into class_occurrences (id, studio_id, location_id, class_type_id, name, instructor_id, room_id, capacity, starts_at, ends_at) values
  ('13d00000-0000-0000-0000-0000000ac002','13d00000-0000-0000-0000-000000000001','13d00000-0000-0000-0000-00000000000a',
   '13d00000-0000-0000-0000-0000000ab001','Reformer','13d00000-0000-0000-0000-0000000001c1','13d00000-0000-0000-0000-00000000b002',
   8, t_at(7, '09:00'), t_at(7, '09:50'));
insert into member_credits (studio_id, member_id, amount_cents, currency, reason)
values ('13d00000-0000-0000-0000-000000000001','13d00000-0000-0000-0000-00000000dd02', 50000, 'PHP', 'reservation_credit');
select t_as('13d00000-0000-0000-0000-0000000000a2');
select expect_text('the sheet says the credit covers it',
  reservation_fee_terms('13d00000-0000-0000-0000-0000000ac002','13d00000-0000-0000-0000-00000000dd02') ->> 'credit_covers', 'true');
select set_config('t.ff', book_first_free('13d00000-0000-0000-0000-0000000ac002','13d00000-0000-0000-0000-00000000dd02')::text, false);
select t_reset();
select expect_text('a staff free-first booking with credit needs no fee choice',
  current_setting('t.ff')::jsonb ->> 'ok', 'true');
select expect_text('...it is confirmed and credit-covered',
  (select status::text || '/' || reservation_credit_covered from bookings where id = (current_setting('t.ff')::jsonb ->> 'booking_id')::uuid),
  'booked/true');
select expect_text('...the chip reads covered',
  free_seat_reservation_state_run((current_setting('t.ff')::jsonb ->> 'booking_id')::uuid) ->> 'state', 'covered');
select expect_num('...no due email', (select count(*) from notifications
  where member_id = '13d00000-0000-0000-0000-00000000dd02' and template_key = 'free_reservation_due'), 0);
select expect_num('...the credit is spent', reservation_credit_available('13d00000-0000-0000-0000-000000000001','13d00000-0000-0000-0000-00000000dd02'), 0);

-- =============================================================================
-- 6. 97 (b): test accounts.
-- =============================================================================
select t_as('13d00000-0000-0000-0000-0000000000a2');
do $$ begin
  perform set_member_test_account('13d00000-0000-0000-0000-00000000dd05', true);
  raise exception 'FAIL  front desk marked a test account';
exception when sqlstate 'PT403' then raise notice 'PASS  front desk cannot mark a test account';
end $$;
select t_as('13d00000-0000-0000-0000-0000000000a1');
select set_member_test_account('13d00000-0000-0000-0000-00000000dd05', true);
select expect_num('Vic is out of the campaign audience',
  (select count(*) from campaign_audience('13d00000-0000-0000-0000-000000000001', '{}'::jsonb)
    where member_id = '13d00000-0000-0000-0000-00000000dd05'), 0);
select expect_true('...while others are in',
  (select count(*) > 0 from campaign_audience('13d00000-0000-0000-0000-000000000001', '{}'::jsonb)));
select expect_num('dashboard active members leave out the test account',
  (select (c ->> 'value')::int from jsonb_array_elements(dashboard_kpis('13d00000-0000-0000-0000-000000000001') -> 'cards') c
    where c ->> 'key' = 'active_members'),
  (select count(*) from member_plan_overview('13d00000-0000-0000-0000-000000000001') o join members m on m.id = o.id
    where o.plan_state in ('on_plan','expiring') and not m.is_test_account));
select t_reset();
select expect_num('one audit row', (select count(*) from audit_logs where action = 'member.test_account_set'
  and entity_id = '13d00000-0000-0000-0000-00000000dd05'), 1);
select expect_true('no campaign, convert or rescue email for a test account',
  not notification_wanted('13d00000-0000-0000-0000-00000000dd05', 'campaign')
  and not notification_wanted('13d00000-0000-0000-0000-00000000dd05', 'convert_after_class')
  and not notification_wanted('13d00000-0000-0000-0000-00000000dd05', 'checkout_rescue_plan'));
select expect_true('...but its booking confirmation still sends',
  notification_wanted('13d00000-0000-0000-0000-00000000dd05', 'booking_confirmed'));
insert into member_tasks (studio_id, member_id, kind) values
  ('13d00000-0000-0000-0000-000000000001','13d00000-0000-0000-0000-00000000dd05','at_risk');
select expect_num('...and no retention task', (select count(*) from member_tasks where member_id = '13d00000-0000-0000-0000-00000000dd05'), 0);
insert into xendit_purchases (id, studio_id, member_id, plan_id, amount_cents, currency, status, created_at, updated_at, completed_at)
values ('13d00000-0000-0000-0000-0000000ff001','13d00000-0000-0000-0000-000000000001','13d00000-0000-0000-0000-00000000dd05',
        '13d00000-0000-0000-0000-0000000cc002',550000,'PHP','expired', now() - interval '3 hours', now() - interval '2 hours', now() - interval '2 hours');
select expect_text('a test account''s expired checkout is skipped for rescue',
  checkout_rescue_run('13d00000-0000-0000-0000-0000000ff001'), 'test_account');

-- =============================================================================
-- 7. 119 (a): a private session rescue; the reservation full/past subject.
-- =============================================================================
select set_config('t.pr', private_book_run('13d00000-0000-0000-0000-00000000dd04','13d00000-0000-0000-0000-0000000007a1',
  '13d00000-0000-0000-0000-0000000001c1', t_at(8, '10:00'), '[]'::jsonb, 'xendit')::text, false);
update xendit_purchases set status = 'expired', completed_at = now() - interval '2 hours'
 where id = (current_setting('t.pr')::jsonb ->> 'purchase_id')::uuid;
select expect_text('an expired private checkout gets a rescue',
  checkout_rescue_run((current_setting('t.pr')::jsonb ->> 'purchase_id')::uuid), 'sent');
select expect_true('...the private template, Finish my booking to that session type',
  (select template_key = 'checkout_rescue_private' and payload ->> 'retry_label' = 'Finish my booking'
          and payload ->> 'retry_url' like '%/book/private?type=13d00000-0000-0000-0000-0000000007a1'
     from notifications where dedupe_key = 'checkout_rescue:' || (current_setting('t.pr')::jsonb ->> 'purchase_id')));
select set_config('t.pr2', private_book_run('13d00000-0000-0000-0000-00000000dd04','13d00000-0000-0000-0000-0000000007a1',
  '13d00000-0000-0000-0000-0000000001c1', t_at(9, '10:00'), '[]'::jsonb, 'xendit')::text, false);
update xendit_purchases set status = 'expired', completed_at = now() - interval '2 hours'
 where id = (current_setting('t.pr2')::jsonb ->> 'purchase_id')::uuid;
select expect_text('...a second one for the same type within 7 days is skipped',
  checkout_rescue_run((current_setting('t.pr2')::jsonb ->> 'purchase_id')::uuid), 'sent_recently');
-- A reservation fee checkout for a class that has passed.
insert into class_occurrences (id, studio_id, location_id, class_type_id, name, instructor_id, room_id, capacity, starts_at, ends_at) values
  ('13d00000-0000-0000-0000-0000000ac003','13d00000-0000-0000-0000-000000000001','13d00000-0000-0000-0000-00000000000a',
   '13d00000-0000-0000-0000-0000000ab001','Reformer','13d00000-0000-0000-0000-0000000001c1','13d00000-0000-0000-0000-00000000b001',
   8, now() - interval '30 minutes', now() + interval '20 minutes');
insert into members (id, studio_id, first_name, last_name, email, status) values
  ('13d00000-0000-0000-0000-00000000dd06','13d00000-0000-0000-0000-000000000001','Wen','Six','wen13@example.org','lead');
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source) values
  ('13d00000-0000-0000-0000-0000000bb001','13d00000-0000-0000-0000-000000000001','13d00000-0000-0000-0000-0000000ac003',
   '13d00000-0000-0000-0000-00000000dd06','cancelled','member','comp');
insert into xendit_purchases (id, studio_id, member_id, booking_id, amount_cents, currency, status, created_at, updated_at, completed_at)
values ('13d00000-0000-0000-0000-0000000ff002','13d00000-0000-0000-0000-000000000001','13d00000-0000-0000-0000-00000000dd06',
        '13d00000-0000-0000-0000-0000000bb001',50000,'PHP','expired', now() - interval '2 hours', now() - interval '90 minutes', now() - interval '90 minutes');
select expect_text('a reservation rescue for a past class sends',
  checkout_rescue_run('13d00000-0000-0000-0000-0000000ff002'), 'sent');
select expect_text('...with the full-or-past subject',
  (select r.subject from notifications n cross join lateral render_notification(n.id) r
    where n.dedupe_key = 'checkout_rescue:13d00000-0000-0000-0000-0000000ff002'),
  'Your free class is still waiting, Wen');

-- =============================================================================
-- 8. The anon surface.
-- =============================================================================
select expect_num('the anon surface is exactly fifteen',
  (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not like 'expect\_%' and p.proname not like 't\_%' and p.proname <> 'call_jsonb'), 15);

select 'step13_test PASS';
