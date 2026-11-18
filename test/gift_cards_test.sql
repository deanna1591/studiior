-- =============================================================================
-- Decision 110 — gift cards, and Decision 103(f) full-credit checkout.
-- UUID space: 91f7.  Xendit token for GA = 'gifttoken'.
--
-- Covers: gift_card_begin as ANON (validation, rate limit, pending rows,
-- ciphertext-only return); issue via the webhook (code mint, sale payment, the
-- two emails); redeem into gift credit (buyer email, audit, guards); the 103(f)
-- full-credit purchase (source-credit payment, revenue EXCLUDES it, the sale
-- counts); gift-first consume order; void guards; the fail branch; anon FOURTEEN.
-- =============================================================================
\set GA '''91f70000-0000-0000-0000-0000000000a1'''
\set GB '''91f70000-0000-0000-0000-0000000000b1'''
\set OA '''91f70000-0000-0000-0000-00000000a0a1'''
\set IA '''91f70000-0000-0000-0000-00000000a0a2'''
\set MR '''91f70000-0000-0000-0000-00000000c0c1'''
\set MF '''91f70000-0000-0000-0000-00000000c0c2'''
\set PP '''91f70000-0000-0000-0000-0000000000f1'''

create or replace function expect_true(label text, actual boolean) returns void language plpgsql as $$
begin if coalesce(actual,false) then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_false(label text, actual boolean) returns void language plpgsql as $$
begin if not coalesce(actual,false) then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected false, got %', label, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_num(label text, actual bigint, want bigint) returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (%)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_text(label text, actual text, want text) returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (%)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if; end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  (:OA), (:IA), (:MR), (:MF), ('91f70000-0000-0000-0000-0000000000b2');
insert into profiles (id, email) values
  (:OA,'91f7-oa@example.com'), (:IA,'91f7-ia@example.com'),
  (:MR,'91f7-mr@example.com'), (:MF,'91f7-mf@example.com'),
  ('91f70000-0000-0000-0000-0000000000b2','91f7-ob@example.com');

insert into studios (id, name, slug, timezone, currency, status) values
  (:GA,'Gift A','gift-a','Asia/Manila','PHP','active'),
  (:GB,'Gift B','gift-b','Asia/Manila','PHP','active');
-- GA: gift on, min PHP 500, presets. GB: gift off.
insert into studio_settings (studio_id, gift_enabled, gift_min_cents, gift_presets) values
  (:GA, true, 50000, array[100000,250000,500000]),
  (:GB, false, 50000, array[100000,250000,500000]);
insert into studio_staff (id, studio_id, user_id, email, role, status) values
  ('91f70000-0000-0000-0000-0000000a0a01',:GA,:OA,'91f7-oa@example.com','owner','active'),
  ('91f70000-0000-0000-0000-0000000a0a02',:GA,:IA,'91f7-ia@example.com','instructor','active'),
  ('91f70000-0000-0000-0000-0000000b0b01',:GB,'91f70000-0000-0000-0000-0000000000b2','91f7-ob@example.com','owner','active');
insert into members (id, studio_id, first_name, last_name, email, status, user_id) values
  (:MR,:GA,'Rhea','Recipient','91f7-mr@example.com','active',:MR),
  (:MF,:GA,'Fifi','Firsto','91f7-mf@example.com','active',:MF);
-- A pack plan for the full-credit purchase.
insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, visibility, status) values
  (:PP,:GA,'Ten Pack','class_pack',140000,'PHP',10,'public','active');

insert into studio_payment_providers
  (studio_id, provider, secret_key_ciphertext, callback_token_ciphertext, callback_token_sha256,
   key_last4, test_mode, connected_by) values
  (:GA,'xendit','v1.giftsecret','v1.opaque', encode(digest('gifttoken','sha256'),'hex'),'tokg', true,:OA),
  (:GB,'xendit','v1.opaque','v1.opaque', encode(digest('btoken','sha256'),'hex'),'tokb', true,'91f70000-0000-0000-0000-0000000000b2');

select set_config('t.ga', :GA, false);
select set_config('t.gb', :GB, false);
select set_config('t.pp', :PP, false);

\echo '=== 1. schema ==='
select expect_true('studio_settings.gift_enabled on GA', (select gift_enabled from studio_settings where studio_id=:GA));
select expect_num('gift_cards has code + amount_cents', (select count(*) from information_schema.columns where table_name='gift_cards' and column_name in ('code','amount_cents','delivery_date'))::bigint, 3);
select expect_num('payments.source exists', (select count(*) from information_schema.columns where table_name='payments' and column_name='source')::bigint, 1);
select expect_num('xendit_purchases.gift_card_id exists', (select count(*) from information_schema.columns where table_name='xendit_purchases' and column_name='gift_card_id')::bigint, 1);

\echo '=== 2. gift_card_begin as ANON — validation ==='
set role anon;
do $$ declare c text; begin
  -- gift off (GB) -> PT404
  begin perform gift_card_begin(current_setting('t.gb')::uuid, 100000,'B','b@x.com','R','r@x.com',null,null);
    c:='no_raise'; exception when others then c:=sqlstate; end; perform set_config('t.v_off', c, false);
  -- below min -> PT422
  begin perform gift_card_begin(current_setting('t.ga')::uuid, 10000,'B','b@x.com','R','r@x.com',null,null);
    c:='no_raise'; exception when others then c:=sqlstate; end; perform set_config('t.v_min', c, false);
  -- bad email -> PT422
  begin perform gift_card_begin(current_setting('t.ga')::uuid, 100000,'B','nope','R','r@x.com',null,null);
    c:='no_raise'; exception when others then c:=sqlstate; end; perform set_config('t.v_email', c, false);
  -- message too long -> PT422
  begin perform gift_card_begin(current_setting('t.ga')::uuid, 100000,'B','b@x.com','R','r@x.com', repeat('x',201), null);
    c:='no_raise'; exception when others then c:=sqlstate; end; perform set_config('t.v_msg', c, false);
  -- delivery far future -> PT422
  begin perform gift_card_begin(current_setting('t.ga')::uuid, 100000,'B','b@x.com','R','r@x.com', null, (now() + interval '120 days')::date);
    c:='no_raise'; exception when others then c:=sqlstate; end; perform set_config('t.v_dd', c, false);
end $$;
reset role;
select expect_text('gift off -> PT404', current_setting('t.v_off'), 'PT404');
select expect_text('below min -> PT422', current_setting('t.v_min'), 'PT422');
select expect_text('bad email -> PT422', current_setting('t.v_email'), 'PT422');
select expect_text('message > 200 -> PT422', current_setting('t.v_msg'), 'PT422');
select expect_text('delivery > 90 days -> PT422', current_setting('t.v_dd'), 'PT422');

\echo '=== 3. a valid begin writes pending rows and returns the ciphertext ==='
set role anon;
select set_config('t.gpid', (select purchase_id::text from gift_card_begin(
  current_setting('t.ga')::uuid, 250000, 'Donor Deb','donor@example.com',
  'Rhea Recipient','91f7-mr@example.com', 'Enjoy a class on me', null)), false);
reset role;
select set_config('t.gcid', (select gift_card_id::text from xendit_purchases where id=current_setting('t.gpid')::uuid), false);
select expect_text('the card is pending with no code yet', (select status from gift_cards where id=current_setting('t.gcid')::uuid), 'pending');
select expect_true('the card has no code while pending', (select code is null from gift_cards where id=current_setting('t.gcid')::uuid));
select expect_true('the purchase targets the gift card, member null', (select gift_card_id is not null and plan_id is null and member_id is null from xendit_purchases where id=current_setting('t.gpid')::uuid));
select expect_num('the purchase amount is the gift amount', (select amount_cents from xendit_purchases where id=current_setting('t.gpid')::uuid)::bigint, 250000);
set role anon; select set_config('t.ctv', (select secret_key_ciphertext from gift_card_begin(current_setting('t.ga')::uuid, 100000,'D3','d3@example.com','R3','r3@example.com',null,null)), false); reset role;
select expect_text('the returned ciphertext is the studio secret', current_setting('t.ctv'), 'v1.giftsecret');

\echo '=== 4. rate limit: 3 begins per email per minute, the 4th refused ==='
set role anon;
do $$ declare c text; begin
  -- same email 'rl@example.com': three begins already? none yet; do 3 then a 4th.
  perform gift_card_begin(current_setting('t.ga')::uuid,100000,'A','rl@example.com','R','r@example.com',null,null);
  perform gift_card_begin(current_setting('t.ga')::uuid,100000,'A','rl@example.com','R','r@example.com',null,null);
  perform gift_card_begin(current_setting('t.ga')::uuid,100000,'A','rl@example.com','R','r@example.com',null,null);
  begin perform gift_card_begin(current_setting('t.ga')::uuid,100000,'A','rl@example.com','R','r@example.com',null,null);
    c:='no_raise'; exception when others then c:=sqlstate; end; perform set_config('t.rl', c, false);
end $$;
reset role;
select expect_text('the 4th begin for one email in a minute -> PT429', current_setting('t.rl'), 'PT429');

\echo '=== 5. issue via the webhook: code minted, sale recorded, two emails ==='
select set_config('t.ev_g', jsonb_build_object(
  'event','payment_session.completed',
  'data', jsonb_build_object('reference_id', current_setting('t.gpid'), 'payment_session_id','ps-91f7-g',
     'payment_id','py-91f7-g','status','COMPLETED','amount',2500,'currency','PHP',
     'metadata', jsonb_build_object('purchase_id', current_setting('t.gpid'))))::text, false);
select set_config('t.r_g', (xendit_webhook(current_setting('t.ev_g')::jsonb, 'gifttoken'))->>'result', false);
select expect_text('the gift callback is processed', current_setting('t.r_g'), 'processed');
select expect_text('the card is now active', (select status from gift_cards where id=current_setting('t.gcid')::uuid), 'active');
select expect_true('the code is {STUDIO}-XXXX-XXXX with no 0/O/1/I',
  (select code ~ '^GIFT-[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{4}-[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{4}$' from gift_cards where id=current_setting('t.gcid')::uuid));
select expect_num('a gift SALE payment exists (gift_card_id set, source null)',
  (select count(*) from payments where gift_card_id=current_setting('t.gcid')::uuid and coalesce(source,'')<>'credit' and status='succeeded' and provider='xendit')::bigint, 1);
select expect_num('the receipt is queued to the buyer', (select count(*) from notifications where template_key='gift_card_receipt' and payload->>'to_email'='donor@example.com')::bigint, 1);
select expect_num('the recipient card is queued', (select count(*) from notifications where template_key='gift_card_sent' and payload->>'to_email'='91f7-mr@example.com')::bigint, 1);
-- Replay -> duplicate.
select expect_text('a replay is a duplicate', (xendit_webhook(current_setting('t.ev_g')::jsonb, 'gifttoken'))->>'result', 'duplicate');
select set_config('t.code', (select code from gift_cards where id=current_setting('t.gcid')::uuid), false);

\echo '=== 6. redeem: a member of GA turns the code into gift credit ==='
-- a non-member (a stranger session) is refused.
set role authenticated; select set_config('request.jwt.claim.sub','91f70000-0000-0000-0000-0000000000b2',false);
do $$ declare c text; begin
  begin perform gift_card_redeem(current_setting('t.code')); c:='no_raise';
  exception when others then c:=sqlstate; end; perform set_config('t.red_x', c, false);
end $$;
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('a non-member of the card studio -> PT403', current_setting('t.red_x'), 'PT403');

set role authenticated; select set_config('request.jwt.claim.sub',:MR,false);
select set_config('t.red_ok', (gift_card_redeem(lower(current_setting('t.code'))))->>'ok', false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('redeem ok (code is case/hyphen tolerant)', current_setting('t.red_ok'), 'true');
select expect_text('the card is redeemed', (select status from gift_cards where id=current_setting('t.gcid')::uuid), 'redeemed');
select expect_num('a gift_credit of the full amount is on MR', (select amount_cents from member_credits where member_id=:MR and reason='gift_credit')::bigint, 250000);
select expect_num('the buyer is told it was claimed', (select count(*) from notifications where template_key='gift_card_redeemed' and payload->>'to_email'='donor@example.com')::bigint, 1);
select expect_num('an audit row records the redemption', (select count(*) from audit_logs where action='gift_card.redeemed' and entity_id=current_setting('t.gcid')::uuid)::bigint, 1);

-- a re-redeem is refused as already_redeemed.
set role authenticated; select set_config('request.jwt.claim.sub',:MR,false);
select set_config('t.red2', (gift_card_redeem(current_setting('t.code')))->>'reason', false);
select set_config('t.red_unknown', (gift_card_redeem('GIFT-ZZZZ-ZZZZ'))->>'reason', false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('a second redeem -> already_redeemed', current_setting('t.red2'), 'already_redeemed');
select expect_text('an unknown code -> not_found', current_setting('t.red_unknown'), 'not_found');

\echo '=== 7. Decision 103(f): a purchase fully covered by gift credit — no Xendit ==='
set role authenticated; select set_config('request.jwt.claim.sub',:MR,false);
select set_config('t.due', (select amount_cents::text from xendit_begin_purchase(:GA,:PP)), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_num('the due returned to the app is 0 (credit covers it)', current_setting('t.due')::bigint, 0);
select expect_num('MR now holds an active membership', (select count(*) from memberships where member_id=:MR and status in ('active','trialing'))::bigint, 1);
select expect_num('a source-credit membership payment exists (provider manual, amount full price)',
  (select count(*) from payments where member_id=:MR and source='credit' and provider='manual' and membership_id is not null and amount_cents=140000)::bigint, 1);
select expect_num('gift credit was consumed by the full amount (250000 - 140000 left)',
  reservation_credit_available(:GA,:MR)::bigint, 110000);

\echo '=== 8. the source-credit payment is EXCLUDED from revenue; the sale counts ==='
-- studio_revenue_between over a wide window: the gift SALE (250000) counts, the
-- credit payment (140000) does not.
select expect_num('studio_revenue_between excludes source credit, keeps the gift sale',
  studio_revenue_between(:GA, now() - interval '2 days', now() + interval '2 days')::bigint, 250000);
-- sales_totals: gift_sold 1/250000, gift_redeemed 1/140000.
set role authenticated; select set_config('request.jwt.claim.sub',:OA,false);
select set_config('t.st', (sales_totals(:GA, (now() at time zone 'Asia/Manila')::date - 2,
                                              (now() at time zone 'Asia/Manila')::date + 2))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_num('sales_totals gift_sold count', (current_setting('t.st')::jsonb->'gift_sold'->>'count')::bigint, 1);
select expect_num('sales_totals gift_sold total', (current_setting('t.st')::jsonb->'gift_sold'->>'total_cents')::bigint, 250000);
select expect_num('sales_totals gift_redeemed count', (current_setting('t.st')::jsonb->'gift_redeemed'->>'count')::bigint, 1);
select expect_num('sales_totals gift_redeemed total', (current_setting('t.st')::jsonb->'gift_redeemed'->>'total_cents')::bigint, 140000);

\echo '=== 9. gift credit is consumed before reservation credit ==='
-- MF has reservation credit 30000 (older) and gift credit 30000 (newer). Consuming
-- 30000 must drain the GIFT row and leave reservation untouched (gift-first).
insert into member_credits (studio_id, member_id, amount_cents, currency, reason, created_at) values
  (:GA,:MF,30000,'PHP','reservation_credit', now() - interval '2 hours'),
  (:GA,:MF,30000,'PHP','gift_credit',        now() - interval '1 hour');
select consume_reservation_credit(:GA,:MF,30000);
select expect_num('the gift credit row is fully used first',
  (select used_cents from member_credits where member_id=:MF and reason='gift_credit')::bigint, 30000);
select expect_num('the reservation credit row is untouched',
  (select used_cents from member_credits where member_id=:MF and reason='reservation_credit')::bigint, 0);

\echo '=== 10. void guards, and the payment-failure branch ==='
-- a fresh active card to void.
set role anon;
select set_config('t.gpid2', (select purchase_id::text from gift_card_begin(
  current_setting('t.ga')::uuid, 100000,'D4','d4@example.com','R4','r4@example.com',null,null)), false);
reset role;
select set_config('t.gcid2', (select gift_card_id::text from xendit_purchases where id=current_setting('t.gpid2')::uuid), false);
select set_config('t.ev_g2', jsonb_build_object('event','payment_session.completed','data',
  jsonb_build_object('reference_id', current_setting('t.gpid2'),'payment_session_id','ps2','payment_id','py2',
    'status','COMPLETED','amount',1000,'currency','PHP',
    'metadata', jsonb_build_object('purchase_id', current_setting('t.gpid2'))))::text, false);
select xendit_webhook(current_setting('t.ev_g2')::jsonb, 'gifttoken');

-- instructor cannot void (manager-up).
set role authenticated; select set_config('request.jwt.claim.sub',:IA,false);
do $$ declare c text; begin
  begin perform gift_card_void(current_setting('t.gcid2')::uuid, 'test'); c:='no_raise';
  exception when others then c:=sqlstate; end; perform set_config('t.void_i', c, false);
  -- empty reason (as manager) still refused below; here capture instructor refusal.
end $$;
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('an instructor cannot void -> PT403', current_setting('t.void_i'), 'PT403');

set role authenticated; select set_config('request.jwt.claim.sub',:OA,false);
do $$ declare c text; begin
  begin perform gift_card_void(current_setting('t.gcid2')::uuid, ''); c:='no_raise';
  exception when others then c:=sqlstate; end; perform set_config('t.void_blank', c, false);
end $$;
select set_config('t.void_ok', (gift_card_void(current_setting('t.gcid2')::uuid, 'refunded at desk'))->>'ok', false);
do $$ declare c text; begin
  begin perform gift_card_void(current_setting('t.gcid')::uuid, 'already claimed'); c:='no_raise';
  exception when others then c:=sqlstate; end; perform set_config('t.void_redeemed', c, false);
end $$;
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('an empty reason -> PT400', current_setting('t.void_blank'), 'PT400');
select expect_text('manager voids an active card', current_setting('t.void_ok'), 'true');
select expect_text('voiding a redeemed card -> PT409', current_setting('t.void_redeemed'), 'PT409');

-- fail branch: a fresh pending gift purchase, FAILED callback -> card void.
set role anon;
select set_config('t.gpid3', (select purchase_id::text from gift_card_begin(
  current_setting('t.ga')::uuid, 100000,'D5','d5@example.com','R5','r5@example.com',null,null)), false);
reset role;
select set_config('t.gcid3', (select gift_card_id::text from xendit_purchases where id=current_setting('t.gpid3')::uuid), false);
select xendit_webhook(jsonb_build_object('event','payment.failure','data',
  jsonb_build_object('reference_id', current_setting('t.gpid3'),'payment_id','py3','status','FAILED',
    'metadata', jsonb_build_object('purchase_id', current_setting('t.gpid3')))), 'gifttoken');
select expect_text('a failed gift purchase voids the pending card',
  (select status from gift_cards where id=current_setting('t.gcid3')::uuid), 'void');

\echo '=== 11. anon surface is EXACTLY FOURTEEN, naming gift_card_begin ==='
select expect_true('gift_card_begin is anon',
  has_function_privilege('anon','gift_card_begin(uuid,int,text,text,text,text,text,date)','execute'));
select expect_false('gift_card_redeem is NOT anon',
  has_function_privilege('anon','gift_card_redeem(text)','execute'));
select expect_false('gift_card_void is NOT anon',
  has_function_privilege('anon','gift_card_void(uuid,text)','execute'));
select expect_num('anon surface is exactly fourteen (suite helpers excluded)',
  (select count(*) from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
    where ns.nspname='public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not like 'expect%')::bigint, 14);

\echo 'gift_cards_test PASS'
