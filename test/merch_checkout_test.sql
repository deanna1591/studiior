-- =============================================================================
-- Decision 63b — in-app merchandise purchase through the existing Xendit checkout.
-- UUID space: 63b0.  Token for A = 'goodtoken', for B = 'btoken'.
-- =============================================================================
\set A  '''63b06300-0000-0000-0000-000000000001'''
\set B  '''63b06300-0000-0000-0000-000000000002'''
\set PX '''63b06300-0000-0000-0000-0000000000a1'''
\set PY '''63b06300-0000-0000-0000-0000000000a2'''
\set PU '''63b06300-0000-0000-0000-0000000000a3'''
\set PZ '''63b06300-0000-0000-0000-0000000000a4'''
\set M1 '''63b06300-0000-0000-0000-00000000c001'''
\set M2 '''63b06300-0000-0000-0000-00000000c002'''

create or replace function expect_true(label text, actual boolean) returns void language plpgsql as $$
begin if coalesce(actual,false) then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_num(label text, actual bigint, want bigint) returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (%)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_text(label text, actual text, want text) returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (%)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if; end $$;
create or replace function expect_raises(label text, sql text, code text) returns void language plpgsql as $$
begin execute sql; raise exception 'FAIL  %  expected %, nothing raised', label, code;
exception when others then
  if sqlstate = code then raise notice 'PASS  %  (%)', label, code;
  else raise exception 'FAIL  %  expected %, got % (%)', label, code, sqlstate, sqlerrm; end if; end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('63b06300-0000-0000-0000-0000000000a1'),  -- owner A
  ('63b06300-0000-0000-0000-00000000c001'),  -- member A m1
  ('63b06300-0000-0000-0000-00000000c002'),  -- member A m2
  ('63b06300-0000-0000-0000-0000000000b1');  -- owner B
insert into profiles (id, email) values
  ('63b06300-0000-0000-0000-0000000000a1','63b0-oa@example.com'),
  ('63b06300-0000-0000-0000-00000000c001','63b0-m1@example.com'),
  ('63b06300-0000-0000-0000-00000000c002','63b0-m2@example.com'),
  ('63b06300-0000-0000-0000-0000000000b1','63b0-ob@example.com');

insert into studios (id, name, slug, timezone, currency, status) values
  (:A,'Checkout A','checkout-a','Asia/Manila','PHP','active'),
  (:B,'Checkout B','checkout-b','Asia/Manila','PHP','active');
insert into studio_settings (studio_id) values (:A), (:B);
insert into studio_staff (id, studio_id, user_id, email, role, status) values
  ('63b06300-0000-0000-0000-000000aa00a1',:A,'63b06300-0000-0000-0000-0000000000a1','63b0-oa@example.com','owner','active'),
  ('63b06300-0000-0000-0000-000000aa00b1',:B,'63b06300-0000-0000-0000-0000000000b1','63b0-ob@example.com','owner','active');
insert into members (id, studio_id, first_name, last_name, email, status, user_id) values
  (:M1,:A,'Ria','One','63b0-m1@example.com','active','63b06300-0000-0000-0000-00000000c001'),
  (:M2,:A,'Bea','Two','63b0-m2@example.com','active','63b06300-0000-0000-0000-00000000c002');

-- Products on A: PX tracked stock 1 (the "last unit"), PY tracked stock 5,
-- PU untracked, PZ tracked stock 1 (RED-proof teeth).
insert into products (id, studio_id, name, price_cents, currency, track_stock, stock, status, sort_order) values
  (:PX,:A,'Grip socks',15000,'PHP', true, 1, 'active', 1),
  (:PY,:A,'Towel',      8000,'PHP', true, 5, 'active', 2),
  (:PU,:A,'Water',      3000,'PHP', false, 0, 'active', 3),
  (:PZ,:A,'Cap',        9000,'PHP', true, 1, 'active', 4);

-- uuids as GUCs so do-blocks (which cannot read psql :vars) can reach them.
select set_config('t.a',  :A, false);
select set_config('t.b',  :B, false);
select set_config('t.px', :PX, false);
select set_config('t.py', :PY, false);
select set_config('t.pz', :PZ, false);

-- Connected Xendit providers (token verified against callback_token_sha256).
insert into studio_payment_providers
  (studio_id, provider, secret_key_ciphertext, callback_token_ciphertext, callback_token_sha256,
   key_last4, test_mode, connected_by) values
  (:A,'xendit','v1.opaque','v1.opaque', encode(digest('goodtoken','sha256'),'hex'),'tok0', true,'63b06300-0000-0000-0000-0000000000a1'),
  (:B,'xendit','v1.opaque','v1.opaque', encode(digest('btoken','sha256'),'hex'),   'tokb', true,'63b06300-0000-0000-0000-0000000000b1');

-- =============================================================================
-- (1) begin RESERVES stock. m1 buys the last unit of PX (stock 1 → 0): a
--     'reserved' order, a 'reserve' movement, a purchase with product_order_id
--     set and plan_id NULL.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','63b06300-0000-0000-0000-00000000c001',false);
select set_config('t.pid_x', (select purchase_id::text from xendit_begin_product_purchase(:A,:PX,1)), false);
select set_config('request.jwt.claim.sub','',false); reset role;

select set_config('t.ord_x', (select product_order_id::text from xendit_purchases where id=current_setting('t.pid_x')::uuid), false);
select expect_num('PX stock is decremented to 0 at reserve', (select stock from products where id=:PX)::bigint, 0);
select expect_text('the order is reserved', (select status from product_orders where id=current_setting('t.ord_x')::uuid), 'reserved');
select expect_text('the order channel is app', (select channel from product_orders where id=current_setting('t.ord_x')::uuid), 'app');
select expect_num('a reserve movement of -1 exists', (select count(*) from stock_movements where order_id=current_setting('t.ord_x')::uuid and reason='reserve' and delta=-1)::bigint, 1);
select expect_true('the purchase targets the product, not a plan',
  (select product_order_id is not null and plan_id is null from xendit_purchases where id=current_setting('t.pid_x')::uuid));
select expect_num('the purchase amount is price × 1', (select amount_cents from xendit_purchases where id=current_setting('t.pid_x')::uuid)::bigint, 15000);

-- A second member cannot buy the last unit while m1 holds it (stock is 0).
set role authenticated; select set_config('request.jwt.claim.sub','63b06300-0000-0000-0000-00000000c002',false);
do $$ begin
  begin perform xendit_begin_product_purchase(current_setting('t.a')::uuid, current_setting('t.px')::uuid, 1);
    perform set_config('t.m2x','no_raise',false);
  exception when others then perform set_config('t.m2x', sqlstate, false); end;
end $$;
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('a second member cannot over-buy the reserved unit (PT409)', current_setting('t.m2x'), 'PT409');

-- =============================================================================
-- (2) RED proof for the reservation: if begin had NOT decremented stock, the
--     second member would also reserve the last unit. m1 reserves PZ (stock
--     1 → 0); we put the unit back (simulating "no reservation happened"); m2
--     then reserves it too — two reservations on one unit. The decrement IS the
--     thing that stops the double-buy.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','63b06300-0000-0000-0000-00000000c001',false);
select set_config('t.pz1', (select purchase_id::text from xendit_begin_product_purchase(:A,:PZ,1)), false);
select set_config('request.jwt.claim.sub','',false); reset role;
-- undo ONLY the decrement, as if begin did not reserve:
update products set stock = 1 where id = :PZ;
set role authenticated; select set_config('request.jwt.claim.sub','63b06300-0000-0000-0000-00000000c002',false);
do $$ begin
  begin perform xendit_begin_product_purchase(current_setting('t.a')::uuid, current_setting('t.pz')::uuid, 1);
    perform set_config('t.pz2','no_raise',false);
  exception when others then perform set_config('t.pz2', sqlstate, false); end;
end $$;
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('RED: without the stock decrement, the 2nd member also buys the last unit', current_setting('t.pz2'), 'no_raise');
select expect_num('RED: two reservations then exist on the one PZ unit',
  (select count(*) from product_orders where product_id=:PZ and status='reserved')::bigint, 2);

-- =============================================================================
-- (3) A COMPLETED callback pays the order: payments row tagged with the order
--     (no membership), a 'sale' movement, stock unchanged (release + sale net 0),
--     the product_order_paid email, and NO membership/credit — a product never
--     calls activate_purchase.
-- =============================================================================
select set_config('t.ev_x', jsonb_build_object(
  'event','payment_session.completed',
  'data', jsonb_build_object('reference_id', current_setting('t.pid_x'), 'payment_session_id','ps-63b0-x',
     'payment_id','py-63b0-x','status','COMPLETED','amount',150,'currency','PHP',
     'metadata', jsonb_build_object('purchase_id', current_setting('t.pid_x'))))::text, false);
select set_config('t.r_x', (xendit_webhook(current_setting('t.ev_x')::jsonb, 'goodtoken'))->>'result', false);

select expect_text('the product callback is processed', current_setting('t.r_x'), 'processed');
select expect_text('the order is now paid', (select status from product_orders where id=current_setting('t.ord_x')::uuid), 'paid');
select expect_text('the purchase is succeeded', (select status from xendit_purchases where id=current_setting('t.pid_x')::uuid), 'succeeded');
select expect_num('a payments row is tagged with the order', (select count(*) from payments where product_order_id=current_setting('t.ord_x')::uuid and provider='xendit' and status='succeeded')::bigint, 1);
select expect_true('the payment carries the Xendit payment id and no membership',
  (select reference='py-63b0-x' and membership_id is null and amount_cents=15000 from payments where product_order_id=current_setting('t.ord_x')::uuid));
select expect_num('a sale movement of -1 exists', (select count(*) from stock_movements where order_id=current_setting('t.ord_x')::uuid and reason='sale' and delta=-1)::bigint, 1);
select expect_num('a release movement of +1 exists (reservation undone)', (select count(*) from stock_movements where order_id=current_setting('t.ord_x')::uuid and reason='release' and delta=1)::bigint, 1);
select expect_num('PX stock stays 0 after the sale (release + sale net 0)', (select stock from products where id=:PX)::bigint, 0);
select expect_num('the product_order_paid email is queued', (select count(*) from notifications where template_key='product_order_paid' and member_id=:M1)::bigint, 1);
select expect_num('NO membership was created for the product purchase', (select count(*) from memberships where member_id=:M1)::bigint, 0);
select expect_num('NO credit ledger row was written', (select count(*) from credit_ledger where member_id=:M1)::bigint, 0);

-- Replay → duplicate; nothing changes.
select set_config('t.r_x2', (xendit_webhook(current_setting('t.ev_x')::jsonb, 'goodtoken'))->>'result', false);
select expect_text('a replay is a duplicate', current_setting('t.r_x2'), 'duplicate');
select expect_num('still exactly one payment on the order', (select count(*) from payments where product_order_id=current_setting('t.ord_x')::uuid)::bigint, 1);

-- =============================================================================
-- (4) A failure RELEASES the reservation: stock back, order cancelled, a
--     'release' movement, a failure email. Begin on PY (5 → 4), then fail.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','63b06300-0000-0000-0000-00000000c001',false);
select set_config('t.pid_y', (select purchase_id::text from xendit_begin_product_purchase(:A,:PY,2)), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select set_config('t.ord_y', (select product_order_id::text from xendit_purchases where id=current_setting('t.pid_y')::uuid), false);
select expect_num('PY stock is 3 after reserving 2', (select stock from products where id=:PY)::bigint, 3);

select set_config('t.ev_yf', jsonb_build_object(
  'event','payment.failure',
  'data', jsonb_build_object('reference_id', current_setting('t.pid_y'), 'payment_id','py-63b0-yf','status','FAILED',
     'metadata', jsonb_build_object('purchase_id', current_setting('t.pid_y'))))::text, false);
select set_config('t.r_yf', (xendit_webhook(current_setting('t.ev_yf')::jsonb, 'goodtoken'))->>'outcome', false);

select expect_text('the failure is processed', current_setting('t.r_yf'), 'failed');
select expect_text('the order is cancelled', (select status from product_orders where id=current_setting('t.ord_y')::uuid), 'cancelled');
select expect_num('PY stock is back to 5 (reservation released)', (select stock from products where id=:PY)::bigint, 5);
select expect_num('a release movement of +2 exists', (select count(*) from stock_movements where order_id=current_setting('t.ord_y')::uuid and reason='release' and delta=2)::bigint, 1);
select expect_num('a failure email is queued', (select count(*) from notifications where template_key='xendit_purchase_failed' and member_id=:M1)::bigint, 1);

-- =============================================================================
-- (5) The reconcile sweep EXPIRES a stale pending product purchase and releases
--     its stock. Begin on PY (5 → 4), age it, sweep.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','63b06300-0000-0000-0000-00000000c001',false);
select set_config('t.pid_e', (select purchase_id::text from xendit_begin_product_purchase(:A,:PY,1)), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select set_config('t.ord_e', (select product_order_id::text from xendit_purchases where id=current_setting('t.pid_e')::uuid), false);
update xendit_purchases set created_at = now() - interval '3 hours' where id = current_setting('t.pid_e')::uuid;
select expect_num('PY stock is 4 after the reserve', (select stock from products where id=:PY)::bigint, 4);
select set_config('t.r_sweep', (xendit_reconcile_sweep(now()))->>'expired', false);
select expect_true('the sweep expired at least one purchase', current_setting('t.r_sweep')::int >= 1);
select expect_text('the swept purchase is expired', (select status from xendit_purchases where id=current_setting('t.pid_e')::uuid), 'expired');
select expect_text('its order is cancelled', (select status from product_orders where id=current_setting('t.ord_e')::uuid), 'cancelled');
select expect_num('PY stock is back to 5 after the sweep release', (select stock from products where id=:PY)::bigint, 5);

-- =============================================================================
-- (6) The return-check belt applies a product purchase (member calls it on
--     their OWN pending purchase).
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','63b06300-0000-0000-0000-00000000c001',false);
select set_config('t.pid_b', (select purchase_id::text from xendit_begin_product_purchase(:A,:PY,1)), false);
select set_config('t.r_belt', (xendit_return_check_apply(current_setting('t.pid_b')::uuid, 'COMPLETED', 'py-63b0-belt'))->>'outcome', false);
select set_config('request.jwt.claim.sub','',false); reset role;
select set_config('t.ord_b', (select product_order_id::text from xendit_purchases where id=current_setting('t.pid_b')::uuid), false);
select expect_text('the belt applies a product purchase', current_setting('t.r_belt'), 'succeeded');
select expect_text('the belt order is paid', (select status from product_orders where id=current_setting('t.ord_b')::uuid), 'paid');
select expect_num('the belt wrote a payments row', (select count(*) from payments where product_order_id=current_setting('t.ord_b')::uuid)::bigint, 1);

-- =============================================================================
-- (7) The owner "check pending" (reprocess) activates a stored product event
--     whose purchase_id is null.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','63b06300-0000-0000-0000-00000000c001',false);
select set_config('t.pid_r', (select purchase_id::text from xendit_begin_product_purchase(:A,:PY,1)), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select set_config('t.ord_r', (select product_order_id::text from xendit_purchases where id=current_setting('t.pid_r')::uuid), false);
insert into xendit_events (studio_id, event_id, event_type, payload, result, error, purchase_id)
values (:A, 'reproc:'||current_setting('t.pid_r'), 'payment_session.completed',
        jsonb_build_object('event','payment_session.completed','data',
          jsonb_build_object('status','COMPLETED','payment_id','py-63b0-r',
            'metadata', jsonb_build_object('purchase_id', current_setting('t.pid_r')))),
        'failed', 'injected', null);
set role authenticated; select set_config('request.jwt.claim.sub','63b06300-0000-0000-0000-0000000000a1',false);
select set_config('t.r_reproc', (xendit_reprocess_ignored(:A))->>'reprocessed', false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_true('reprocess activated the product purchase', current_setting('t.r_reproc')::int >= 1);
select expect_text('the reprocessed order is paid', (select status from product_orders where id=current_setting('t.ord_r')::uuid), 'paid');

-- =============================================================================
-- (8) Refusals: non-member, short stock, cross-tenant webhook.
-- =============================================================================
-- non-member (owner B signed in) buying on A
set role authenticated; select set_config('request.jwt.claim.sub','63b06300-0000-0000-0000-0000000000b1',false);
do $$ begin
  begin perform xendit_begin_product_purchase(current_setting('t.a')::uuid, current_setting('t.py')::uuid, 1);
    perform set_config('t.nonmember','no_raise',false);
  exception when others then perform set_config('t.nonmember', sqlstate, false); end;
end $$;
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('a non-member is refused begin_product_purchase (PT403)', current_setting('t.nonmember'), 'PT403');

-- short stock: ask for 99 of PY (5 left)
set role authenticated; select set_config('request.jwt.claim.sub','63b06300-0000-0000-0000-00000000c001',false);
do $$ begin
  begin perform xendit_begin_product_purchase(current_setting('t.a')::uuid, current_setting('t.py')::uuid, 99);
    perform set_config('t.short','no_raise',false);
  exception when others then perform set_config('t.short', sqlstate, false); end;
end $$;
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('short stock is refused (PT409)', current_setting('t.short'), 'PT409');

-- cross-tenant: a product purchase on A, event sent with B's token → ignored.
set role authenticated; select set_config('request.jwt.claim.sub','63b06300-0000-0000-0000-00000000c001',false);
select set_config('t.pid_xt', (select purchase_id::text from xendit_begin_product_purchase(:A,:PY,1)), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select set_config('t.ev_xt', jsonb_build_object(
  'event','payment_session.completed',
  'data', jsonb_build_object('status','COMPLETED','payment_id','py-63b0-xt','amount',80,'currency','PHP',
     'metadata', jsonb_build_object('purchase_id', current_setting('t.pid_xt'))))::text, false);
select set_config('t.r_xt', (xendit_webhook(current_setting('t.ev_xt')::jsonb, 'btoken'))->>'reason', false);
select expect_text('a cross-tenant event is ignored', current_setting('t.r_xt'), 'cross_tenant');
select expect_text('the cross-tenant order is NOT paid', (select status from product_orders where id=(select product_order_id from xendit_purchases where id=current_setting('t.pid_xt')::uuid)), 'reserved');

-- =============================================================================
-- Anon surface is EXACTLY THIRTEEN (a merch purchase rides xendit_webhook).
-- =============================================================================
select expect_num('anon surface is exactly thirteen',
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not like 'expect_%')::bigint, 13);

-- --- cleanup -----------------------------------------------------------------
drop function expect_true(text,boolean);
drop function expect_num(text,bigint,bigint);
drop function expect_text(text,text,text);
drop function expect_raises(text,text,text);
