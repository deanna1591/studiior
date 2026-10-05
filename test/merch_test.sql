-- =============================================================================
-- Decision 63a — merchandise: inventory, desk sales, member listing.
-- UUID space: 6300
-- =============================================================================
\set A '''63006300-0000-0000-0000-000000000001'''
\set B '''63006300-0000-0000-0000-000000000002'''
\set P1 '''63006300-0000-0000-0000-0000000000a1'''
\set P2 '''63006300-0000-0000-0000-0000000000a2'''
\set P3 '''63006300-0000-0000-0000-0000000000a3'''
\set PB '''63006300-0000-0000-0000-0000000000b1'''

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
  ('63006300-0000-0000-0000-0000000000a1'),  -- owner A
  ('63006300-0000-0000-0000-0000000000f1'),  -- front desk A
  ('63006300-0000-0000-0000-0000000000e1'),  -- instructor A
  ('63006300-0000-0000-0000-0000000000c1'),  -- member A
  ('63006300-0000-0000-0000-0000000000b1');  -- owner B
insert into profiles (id, email) values
  ('63006300-0000-0000-0000-0000000000a1','6300-oa@example.com'),
  ('63006300-0000-0000-0000-0000000000f1','6300-fa@example.com'),
  ('63006300-0000-0000-0000-0000000000e1','6300-ia@example.com'),
  ('63006300-0000-0000-0000-0000000000c1','6300-ma@example.com'),
  ('63006300-0000-0000-0000-0000000000b1','6300-ob@example.com');

insert into studios (id, name, slug, timezone, currency, status) values
  (:A,'Merch A','merch-a','Europe/Prague','CZK','active'),
  (:B,'Merch B','merch-b','Europe/Prague','CZK','active');
insert into studio_settings (studio_id) values (:A), (:B);
insert into studio_staff (id, studio_id, user_id, email, role, status) values
  ('63006300-0000-0000-0000-000000aa00a1',:A,'63006300-0000-0000-0000-0000000000a1','6300-oa@example.com','owner','active'),
  ('63006300-0000-0000-0000-000000aa00f1',:A,'63006300-0000-0000-0000-0000000000f1','6300-fa@example.com','front_desk','active'),
  ('63006300-0000-0000-0000-000000aa00e1',:A,'63006300-0000-0000-0000-0000000000e1','6300-ia@example.com','instructor','active'),
  ('63006300-0000-0000-0000-000000aa00b1',:B,'63006300-0000-0000-0000-0000000000b1','6300-ob@example.com','owner','active');
insert into members (id, studio_id, first_name, last_name, email, status, user_id) values
  ('63006300-0000-0000-0000-00000000c001',:A,'Mia','Member','6300-ma@example.com','active','63006300-0000-0000-0000-0000000000c1');

-- Products on A: tracked (stock 5, low threshold 2), untracked, archived. One on B.
insert into products (id, studio_id, name, price_cents, currency, track_stock, stock, low_stock_threshold, status, sort_order) values
  (:P1,:A,'Grip socks — S',15000,'CZK', true, 5, 2, 'active', 1),
  (:P2,:A,'Water bottle', 8000,'CZK', false, 0, null, 'active', 2),
  (:P3,:A,'Old towel',   5000,'CZK', true, 3, null, 'archived', 3),
  (:PB,:B,'B socks',     9000,'CZK', true, 5, null, 'active', 1);

-- =============================================================================
-- (1) RLS: desk-up reads products; instructor/member do NOT (table). Member
--     reads via member_shop (active only).
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','63006300-0000-0000-0000-0000000000e1',false);
select expect_num('an instructor cannot read products via the table',
  (select count(*) from products where studio_id=:A)::bigint, 0);
select set_config('request.jwt.claim.sub','',false); reset role;
set role authenticated; select set_config('request.jwt.claim.sub','63006300-0000-0000-0000-0000000000c1',false);
select expect_num('a member cannot read products via the table',
  (select count(*) from products where studio_id=:A)::bigint, 0);
select expect_num('member_shop returns the 2 active products (not the archived one)',
  jsonb_array_length(member_shop(:A)), 2);
select set_config('request.jwt.claim.sub','',false); reset role;
set role authenticated; select set_config('request.jwt.claim.sub','63006300-0000-0000-0000-0000000000f1',false);
select expect_num('front desk CAN read products via the table',
  (select count(*) from products where studio_id=:A)::bigint, 3);
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- (2) Desk sale (front desk) — stock down, a payments row, order collected, a
--     sale movement.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','63006300-0000-0000-0000-0000000000f1',false);
select set_config('t.sale', record_product_sale(:A,:P1,2,'63006300-0000-0000-0000-00000000c001','cash')::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('front desk sale → ok', (current_setting('t.sale')::jsonb ->> 'ok'), 'true');
select expect_num('...stock 5 → 3', (select stock from products where id=:P1)::bigint, 3);
select expect_num('...one payments row, succeeded, 30000, tagged with the order',
  (select count(*) from payments where product_order_id=(current_setting('t.sale')::jsonb ->> 'order_id')::uuid
     and status='succeeded' and amount_cents=30000 and provider='manual')::bigint, 1);
select expect_text('...the order is collected, channel desk',
  (select status || ':' || channel from product_orders where id=(current_setting('t.sale')::jsonb ->> 'order_id')::uuid),
  'collected:desk');
select expect_num('...one sale movement, delta -2',
  (select count(*) from stock_movements where order_id=(current_setting('t.sale')::jsonb ->> 'order_id')::uuid
     and reason='sale' and delta=-2)::bigint, 1);

-- =============================================================================
-- (3) Money readers see Merchandise (while the sale is still succeeded).
-- =============================================================================
select expect_num('dashboard_revenue: Merchandise = 30000',
  (select (src ->> 'cents')::bigint from jsonb_array_elements(dashboard_revenue(:A, current_date, current_date) -> 'by_source') src
    where src ->> 'source' = 'merch'), 30000);
select expect_text('...labelled Merchandise',
  (select (src ->> 'label') from jsonb_array_elements(dashboard_revenue(:A, current_date, current_date) -> 'by_source') src
    where src ->> 'source' = 'merch'), 'Merchandise');
select expect_num('...memberships_sold unchanged (0)',
  (dashboard_revenue(:A, current_date, current_date) -> 'counts' ->> 'memberships_sold')::bigint, 0);
select expect_text('sales_history carries the product name + plan_type merch',
  (select plan_name || '|' || plan_type from sales_history(:A, current_date, current_date) where plan_type='merch' limit 1),
  'Grip socks — S ×2|merch');
select expect_num('sales_totals gross includes the merch sale (30000)',
  (sales_totals(:A, current_date, current_date) ->> 'gross_cents')::bigint, 30000);

-- =============================================================================
-- (4) Refusals.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','63006300-0000-0000-0000-0000000000f1',false);
select expect_raises('quantity over stock → PT409 "Only N left."',
  $$ select record_product_sale('63006300-0000-0000-0000-000000000001','63006300-0000-0000-0000-0000000000a1',10) $$, 'PT409');
select expect_raises('an archived product → PT409',
  $$ select record_product_sale('63006300-0000-0000-0000-000000000001','63006300-0000-0000-0000-0000000000a3',1) $$, 'PT409');
-- Untracked stock never blocks — a huge quantity sells.
select set_config('t.u', record_product_sale(:A,:P2,100,null,'gcash')::text, false);
select expect_text('untracked: a huge quantity still sells',
  (current_setting('t.u')::jsonb ->> 'ok'), 'true');
select expect_num('...and writes NO stock movement',
  (select count(*) from stock_movements where order_id=(current_setting('t.u')::jsonb ->> 'order_id')::uuid)::bigint, 0);
select set_config('request.jwt.claim.sub','',false); reset role;
-- An instructor cannot sell.
set role authenticated; select set_config('request.jwt.claim.sub','63006300-0000-0000-0000-0000000000e1',false);
select expect_raises('an instructor cannot record a sale → PT403',
  $$ select record_product_sale('63006300-0000-0000-0000-000000000001','63006300-0000-0000-0000-0000000000a1',1) $$, 'PT403');
select set_config('request.jwt.claim.sub','',false); reset role;
-- Cross-studio: A's owner cannot sell/adjust/collect B's product.
set role authenticated; select set_config('request.jwt.claim.sub','63006300-0000-0000-0000-0000000000a1',false);
select expect_raises('cross-studio sale → PT403',
  $$ select record_product_sale('63006300-0000-0000-0000-000000000002','63006300-0000-0000-0000-0000000000b1',1) $$, 'PT403');
select expect_raises('cross-studio adjust → PT403',
  $$ select adjust_stock('63006300-0000-0000-0000-0000000000b1', 1, 'restock') $$, 'PT403');
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- (5) adjust_stock — manager restock; front desk refused.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','63006300-0000-0000-0000-0000000000f1',false);
select expect_raises('front desk cannot adjust stock → PT403',
  $$ select adjust_stock('63006300-0000-0000-0000-0000000000a1', 5, 'restock') $$, 'PT403');
select set_config('request.jwt.claim.sub','',false); reset role;
set role authenticated; select set_config('request.jwt.claim.sub','63006300-0000-0000-0000-0000000000a1',false);
select expect_num('manager restock +5 → stock 3 → 8',
  (adjust_stock(:P1, 5, 'restock', 'new box') ->> 'stock')::bigint, 8);
select expect_num('...a restock movement exists',
  (select count(*) from stock_movements where product_id=:P1 and reason='restock' and delta=5)::bigint, 1);
select expect_raises('adjust below zero → PT409',
  $$ select adjust_stock('63006300-0000-0000-0000-0000000000a1', -100, 'adjust') $$, 'PT409');
select expect_raises('adjust an untracked product → PT409',
  $$ select adjust_stock('63006300-0000-0000-0000-0000000000a2', 1, 'restock') $$, 'PT409');
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- (6) mark_order_collected — a paid (app) order.
-- =============================================================================
reset role;
insert into product_orders (id, studio_id, product_id, member_id, quantity, unit_price_cents, currency, status, channel)
values ('63006300-0000-0000-0000-00000000d001',:A,:P1,'63006300-0000-0000-0000-00000000c001',1,15000,'CZK','paid','app');
set role authenticated; select set_config('request.jwt.claim.sub','63006300-0000-0000-0000-0000000000f1',false);
select expect_text('mark_order_collected → ok',
  (mark_order_collected('63006300-0000-0000-0000-00000000d001') ->> 'ok'), 'true');
select expect_text('...the order is collected',
  (select status from product_orders where id='63006300-0000-0000-0000-00000000d001'), 'collected');
select expect_raises('collecting it again → PT409',
  $$ select mark_order_collected('63006300-0000-0000-0000-00000000d001') $$, 'PT409');
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- (7) product_low_stock — threshold line.
-- =============================================================================
-- Bring P1 to the threshold: sell down from 8 to 2.
set role authenticated; select set_config('request.jwt.claim.sub','63006300-0000-0000-0000-0000000000f1',false);
select record_product_sale(:A,:P1,6,null,'cash');
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_num('product_low_stock lists P1 at 2 (<= threshold 2)',
  (select count(*) from product_low_stock(:A) where product_id=:P1 and stock=2)::bigint, 1);

-- =============================================================================
-- (8) record_refund on a merch payment with restock → stock back + movement.
-- =============================================================================
-- Refund the first P1 ×2 sale (30000) with restock. P1 stock 2 → 4.
reset role;
set role authenticated; select set_config('request.jwt.claim.sub','63006300-0000-0000-0000-0000000000a1',false);
select set_config('t.refund',
  record_refund((select id from payments where product_order_id=(current_setting('t.sale')::jsonb ->> 'order_id')::uuid),
                null, 'returned', true)::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('merch refund with restock → full',
  (current_setting('t.refund')::jsonb ->> 'full'), 'true');
select expect_num('...stock back +2 (2 → 4)', (select stock from products where id=:P1)::bigint, 4);
select expect_num('...a refund_restock movement +2',
  (select count(*) from stock_movements where product_id=:P1 and reason='refund_restock' and delta=2)::bigint, 1);
select expect_text('...the order is refunded',
  (select status from product_orders where id=(current_setting('t.sale')::jsonb ->> 'order_id')::uuid), 'refunded');

-- --- cleanup -----------------------------------------------------------------
drop function expect_true(text, boolean);
drop function expect_num(text, bigint, bigint);
drop function expect_text(text, text, text);
drop function expect_raises(text, text, text);
select 'merch_test: all assertions passed' as result;
