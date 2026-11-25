-- Decision 119: a checkout that expires gets one rescue email. UUID space 1190.
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

-- A fixed clock: the sweep and backfill take p_now, so the cutover (25 Nov
-- 2026, studio local) and the one hour / three day windows are deterministic.
create or replace function t_now() returns timestamptz language sql immutable as $$
  select '2026-11-28 12:00:00+08'::timestamptz $$;
-- A failed checkout that ended at p_ended.
create or replace function t_xp(p_id text, p_member text, p_plan text, p_ended timestamptz,
                                p_booking text default null, p_gift text default null,
                                p_order text default null, p_email text default null,
                                p_name text default null, p_amount int default 140000,
                                p_status text default 'failed')
returns void language sql as $$
  insert into xendit_purchases (id, studio_id, member_id, plan_id, booking_id, gift_card_id, product_order_id,
                                amount_cents, currency, status, failure_reason, buyer_email, buyer_name,
                                created_at, updated_at)
  values (p_id::uuid, '11900000-0000-0000-0000-000000000001', p_member::uuid, p_plan::uuid, p_booking::uuid,
          p_gift::uuid, p_order::uuid, p_amount, 'PHP', p_status, 'payment_session.expired',
          p_email, p_name, p_ended - interval '30 minutes', p_ended);
$$;
create or replace function t_note(p_purchase text) returns notifications language sql stable as $$
  select n.* from checkout_rescues cr join notifications n on n.id = cr.notification_id
   where cr.purchase_id = p_purchase::uuid $$;
create or replace function t_out(p_purchase text) returns text language sql stable as $$
  select coalesce((select outcome || coalesce(':' || reason, '') from checkout_rescues
                    where purchase_id = p_purchase::uuid), 'none') $$;

-- ---- Fixtures ------------------------------------------------------------------
insert into auth.users (id, email, email_confirmed_at) values
  ('11900000-0000-0000-0000-0000000000a1', 'owner119@example.com', now());
insert into profiles (id, email) select id, email from auth.users where id::text like '11900000%';

insert into studios (id, name, slug, timezone, currency, country, status, contact_email) values
  ('11900000-0000-0000-0000-000000000001','Rescue Studio','r119-s','Asia/Manila','PHP','PH','active','hello@rescue119.example.com');
insert into studio_settings (studio_id, free_first_class_enabled, messages_enabled, time_format)
values ('11900000-0000-0000-0000-000000000001', true, true, '12h');
insert into locations (id, studio_id, name, is_primary) values
  ('11900000-0000-0000-0000-00000000000a','11900000-0000-0000-0000-000000000001','Main',true);
insert into studio_staff (studio_id, user_id, email, role) values
  ('11900000-0000-0000-0000-000000000001','11900000-0000-0000-0000-0000000000a1','owner119@example.com','owner');

insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, validity_days, visibility, status) values
  ('11900000-0000-0000-0000-0000000cc001','11900000-0000-0000-0000-000000000001','10-Class Pack','class_pack',140000,'PHP',10,60,'public','active'),
  ('11900000-0000-0000-0000-0000000cc002','11900000-0000-0000-0000-000000000001','5-Class Pack','class_pack',80000,'PHP',5,30,'public','active');

insert into members (id, studio_id, user_id, first_name, last_name, email, status, email_status) values
  ('11900000-0000-0000-0000-00000000dd00','11900000-0000-0000-0000-000000000001','11900000-0000-0000-0000-0000000000a1','Olive','Owner','owner119@example.com','active','valid'),
  ('11900000-0000-0000-0000-00000000dd01','11900000-0000-0000-0000-000000000001',null,'Mia','One','mia119@example.com','lead','valid'),
  ('11900000-0000-0000-0000-00000000dd02','11900000-0000-0000-0000-000000000001',null,'Pat','Paid','pat119@example.com','lead','valid'),
  ('11900000-0000-0000-0000-00000000dd03','11900000-0000-0000-0000-000000000001',null,'Ivy','Invalid','ivy119@example.com','lead','invalid'),
  ('11900000-0000-0000-0000-00000000dd04','11900000-0000-0000-0000-000000000001',null,'Sam','Shop','sam119@example.com','lead','valid'),
  ('11900000-0000-0000-0000-00000000dd05','11900000-0000-0000-0000-000000000001',null,'Lea','Open','lea119@example.com','lead','valid'),
  ('11900000-0000-0000-0000-00000000dd06','11900000-0000-0000-0000-000000000001',null,'Fay','Full','fay119@example.com','lead','valid'),
  ('11900000-0000-0000-0000-00000000dd07','11900000-0000-0000-0000-000000000001',null,'Pia','Past','pia119@example.com','lead','valid'),
  ('11900000-0000-0000-0000-00000000dd08','11900000-0000-0000-0000-000000000001',null,'Ola','Old','ola119@example.com','lead','valid'),
  ('11900000-0000-0000-0000-00000000dd09','11900000-0000-0000-0000-000000000001',null,'Bea','Backfill','bea119@example.com','lead','valid'),
  ('11900000-0000-0000-0000-00000000dd10','11900000-0000-0000-0000-000000000001',null,'Roy','Late','roy119@example.com','lead','valid'),
  ('11900000-0000-0000-0000-00000000dd11','11900000-0000-0000-0000-000000000001',null,'Tom','Twice','tom119@example.com','lead','valid'),
  ('11900000-0000-0000-0000-00000000dd12','11900000-0000-0000-0000-000000000001',null,'Ana','Again','ana119@example.com','lead','valid');

-- Pat paid for a plan after the failed checkout.
insert into memberships (studio_id, member_id, plan_id, status, price_cents, currency, starts_on, created_at)
values ('11900000-0000-0000-0000-000000000001','11900000-0000-0000-0000-00000000dd02',
        '11900000-0000-0000-0000-0000000cc002','active',80000,'PHP', '2026-11-28', t_now() - interval '90 minutes');

-- Shop.
insert into products (id, studio_id, name, price_cents, currency, track_stock, stock, status, sort_order) values
  ('11900000-0000-0000-0000-0000000ab001','11900000-0000-0000-0000-000000000001','Grip Socks',13000,'PHP',false,0,'active',1);
insert into product_orders (id, studio_id, product_id, member_id, quantity, unit_price_cents, currency, status, channel) values
  ('11900000-0000-0000-0000-0000000ac001','11900000-0000-0000-0000-000000000001','11900000-0000-0000-0000-0000000ab001',
   '11900000-0000-0000-0000-00000000dd04',1,13000,'PHP','cancelled','app');

-- Gift card (a guest buyer).
insert into gift_cards (id, studio_id, status, amount_cents, currency, buyer_name, buyer_email, recipient_name, recipient_email)
values ('11900000-0000-0000-0000-0000000ad001','11900000-0000-0000-0000-000000000001','pending',250000,'PHP',
        'Gina Giver','gina119@example.com','Rosa','rosa119@example.com');

-- Classes for the reservation fee: open (seats), full (capacity 1 taken), past.
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('11900000-0000-0000-0000-0000000cf001','11900000-0000-0000-0000-000000000001','Reformer Flow',50,6);
insert into rooms (id, studio_id, location_id, name, capacity)
  select ('11900000-0000-0000-0000-00000000b00'||g)::uuid,'11900000-0000-0000-0000-000000000001',
         '11900000-0000-0000-0000-00000000000a','R'||g, 6 from generate_series(1,4) g;
insert into class_occurrences (id, studio_id, class_type_id, room_id, location_id, name, starts_at, ends_at,
                               capacity, status, staffing) values
  ('11900000-0000-0000-0000-00000000c001','11900000-0000-0000-0000-000000000001','11900000-0000-0000-0000-0000000cf001',
   '11900000-0000-0000-0000-00000000b001','11900000-0000-0000-0000-00000000000a','REFORMER FLOW',
   t_now() + interval '2 days', t_now() + interval '2 days 50 minutes', 6, 'scheduled', 'open'),
  ('11900000-0000-0000-0000-00000000c002','11900000-0000-0000-0000-000000000001','11900000-0000-0000-0000-0000000cf001',
   '11900000-0000-0000-0000-00000000b002','11900000-0000-0000-0000-00000000000a','REFORMER SCULPT',
   t_now() + interval '2 days', t_now() + interval '2 days 50 minutes', 1, 'scheduled', 'open'),
  ('11900000-0000-0000-0000-00000000c003','11900000-0000-0000-0000-000000000001','11900000-0000-0000-0000-0000000cf001',
   '11900000-0000-0000-0000-00000000b003','11900000-0000-0000-0000-00000000000a','REFORMER BURN',
   t_now() - interval '1 hour', t_now() - interval '10 minutes', 6, 'scheduled', 'open');
-- The released holds (cancelled comp bookings), and somebody else in the full class.
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source) values
  ('11900000-0000-0000-0000-0000000be001','11900000-0000-0000-0000-000000000001','11900000-0000-0000-0000-00000000c001','11900000-0000-0000-0000-00000000dd05','cancelled','comp'),
  ('11900000-0000-0000-0000-0000000be002','11900000-0000-0000-0000-000000000001','11900000-0000-0000-0000-00000000c002','11900000-0000-0000-0000-00000000dd06','cancelled','comp'),
  ('11900000-0000-0000-0000-0000000be003','11900000-0000-0000-0000-000000000001','11900000-0000-0000-0000-00000000c003','11900000-0000-0000-0000-00000000dd07','cancelled','comp'),
  ('11900000-0000-0000-0000-0000000be004','11900000-0000-0000-0000-000000000001','11900000-0000-0000-0000-00000000c001','11900000-0000-0000-0000-00000000dd08','cancelled','comp'),
  ('11900000-0000-0000-0000-0000000be009','11900000-0000-0000-0000-000000000001','11900000-0000-0000-0000-00000000c002','11900000-0000-0000-0000-00000000dd01','booked','drop_in');
update class_occurrences set booked_count = 1 where id = '11900000-0000-0000-0000-00000000c002';
-- Seats on the open class: 2 taken, so 4 left.
insert into bookings (studio_id, occurrence_id, member_id, status, payment_source) values
  ('11900000-0000-0000-0000-000000000001','11900000-0000-0000-0000-00000000c001','11900000-0000-0000-0000-00000000dd02','booked','drop_in'),
  ('11900000-0000-0000-0000-000000000001','11900000-0000-0000-0000-00000000c001','11900000-0000-0000-0000-00000000dd04','booked','drop_in');

-- ---- The checkouts (ended 2 hours before t_now unless stated) -------------------
select t_xp('11900000-0000-0000-0000-00000000f001','11900000-0000-0000-0000-00000000dd01','11900000-0000-0000-0000-0000000cc001', t_now() - interval '2 hours');           -- Mia, plan: sent
select t_xp('11900000-0000-0000-0000-00000000f002','11900000-0000-0000-0000-00000000dd01','11900000-0000-0000-0000-0000000cc001', t_now() - interval '3 hours');           -- Mia again, older: sent_recently
select t_xp('11900000-0000-0000-0000-00000000f003','11900000-0000-0000-0000-00000000dd02','11900000-0000-0000-0000-0000000cc001', t_now() - interval '2 hours');           -- Pat: paid_since
select t_xp('11900000-0000-0000-0000-00000000f004','11900000-0000-0000-0000-00000000dd03','11900000-0000-0000-0000-0000000cc001', t_now() - interval '2 hours');           -- Ivy: invalid_email
select t_xp('11900000-0000-0000-0000-00000000f005','11900000-0000-0000-0000-00000000dd00','11900000-0000-0000-0000-0000000cc001', t_now() - interval '2 hours');           -- the owner
select t_xp('11900000-0000-0000-0000-00000000f006', null,'11900000-0000-0000-0000-0000000cc002', t_now() - interval '2 hours',
            p_email => 'guest119@example.com', p_name => 'Gus Guest');                                                                                            -- guest plan: sent
select t_xp('11900000-0000-0000-0000-00000000f007', null, null, t_now() - interval '2 hours', p_gift => '11900000-0000-0000-0000-0000000ad001', p_amount => 250000);  -- gift: sent
select t_xp('11900000-0000-0000-0000-00000000f008','11900000-0000-0000-0000-00000000dd04', null, t_now() - interval '2 hours', p_order => '11900000-0000-0000-0000-0000000ac001', p_amount => 13000); -- shop: sent
select t_xp('11900000-0000-0000-0000-00000000f009','11900000-0000-0000-0000-00000000dd05', null, t_now() - interval '2 hours', p_booking => '11900000-0000-0000-0000-0000000be001', p_amount => 50000, p_status => 'expired'); -- reservation open
select t_xp('11900000-0000-0000-0000-00000000f010','11900000-0000-0000-0000-00000000dd06', null, t_now() - interval '2 hours', p_booking => '11900000-0000-0000-0000-0000000be002', p_amount => 50000, p_status => 'expired'); -- reservation full
select t_xp('11900000-0000-0000-0000-00000000f011','11900000-0000-0000-0000-00000000dd07', null, t_now() - interval '2 hours', p_booking => '11900000-0000-0000-0000-0000000be003', p_amount => 50000, p_status => 'expired'); -- reservation past
select t_xp('11900000-0000-0000-0000-00000000f012','11900000-0000-0000-0000-00000000dd08', null, '2026-11-24 22:00:00+08', p_booking => '11900000-0000-0000-0000-0000000be004', p_amount => 50000, p_status => 'expired'); -- reservation before 25 Nov
select t_xp('11900000-0000-0000-0000-00000000f013','11900000-0000-0000-0000-00000000dd10','11900000-0000-0000-0000-0000000cc001', t_now() - interval '30 minutes');      -- too soon
select t_xp('11900000-0000-0000-0000-00000000f014','11900000-0000-0000-0000-00000000dd09','11900000-0000-0000-0000-0000000cc002', '2026-11-15 18:00:00+08');             -- backfill: sent
select t_xp('11900000-0000-0000-0000-00000000f015','11900000-0000-0000-0000-00000000dd09','11900000-0000-0000-0000-0000000cc001', '2026-11-05 18:00:00+08');             -- before 9 Nov: never
select t_xp('11900000-0000-0000-0000-00000000f016','11900000-0000-0000-0000-00000000dd11','11900000-0000-0000-0000-0000000cc001', t_now() - interval '2 hours', p_status => 'succeeded'); -- paid: never

-- =============================================================================
-- 1. The sweep.
-- =============================================================================
select set_config('t.sweep', sweep_checkout_rescue(t_now())::text, false);
select expect_text('the sweep sends seven (member plan, guest plan, gift, shop, three reservations)',
  current_setting('t.sweep')::jsonb ->> 'sent', '7');

select expect_text('plan checkout → sent', t_out('11900000-0000-0000-0000-00000000f001'), 'sent');
select expect_text('a second attempt at the same plan by the same person → one email only',
  t_out('11900000-0000-0000-0000-00000000f002'), 'skipped:sent_recently');
select expect_text('paid since → skipped', t_out('11900000-0000-0000-0000-00000000f003'), 'skipped:paid_since');
select expect_text('invalid email → skipped', t_out('11900000-0000-0000-0000-00000000f004'), 'skipped:invalid_email');
select expect_text('the owner''s own account → skipped', t_out('11900000-0000-0000-0000-00000000f005'), 'skipped:owner');
select expect_text('not one hour after it ended → not looked at yet', t_out('11900000-0000-0000-0000-00000000f013'), 'none');
select expect_text('a paid checkout is never rescued', t_out('11900000-0000-0000-0000-00000000f016'), 'none');
select expect_text('a reservation fee checkout before 25 Nov is outside the sweep window',
  t_out('11900000-0000-0000-0000-00000000f012'), 'none');
select expect_text('asked directly, a reservation fee checkout before 25 Nov → skipped',
  checkout_rescue_run('11900000-0000-0000-0000-00000000f012', t_now(), false), 'reservation_before_cutover');
select expect_num('a reservation fee checkout before 25 Nov queues no email',
  (select count(*) from notifications where dedupe_key = 'checkout_rescue:11900000-0000-0000-0000-00000000f012'), 0);
select expect_text('the backfill-window plan is outside the sweep''s three days',
  t_out('11900000-0000-0000-0000-00000000f014'), 'none');

-- Plan email.
select expect_text('plan: template, first name, item, button to /buy/{plan}',
  (select template_key || '|' || (payload->>'first_name') || '|' || (payload->>'item_name') || '|' || (payload->>'retry_url')
     from t_note('11900000-0000-0000-0000-00000000f001')),
  'checkout_rescue_plan|Mia|10-Class Pack|https://r119-s.studiior.app/buy/11900000-0000-0000-0000-0000000cc001');
select expect_text('a member''s "Message the studio" goes to /messages',
  (select payload->>'message_url' from t_note('11900000-0000-0000-0000-00000000f001')),
  'https://r119-s.studiior.app/messages');
select expect_text('the reply-to is the studio contact email',
  (select reply_to from render_notification((select id from t_note('11900000-0000-0000-0000-00000000f001')))),
  'hello@rescue119.example.com');
select expect_true('the plan email renders with the retry link and nothing left in braces',
  (select html_body like '%/buy/11900000-0000-0000-0000-0000000cc001%' and html_body not like '%{item_name}%'
          and coalesce(array_length(stripped, 1), 0) = 0
     from render_notification((select id from t_note('11900000-0000-0000-0000-00000000f001')))));

-- Guest buyer (Decision 118).
select expect_text('guest: addressed to the buyer, no member, message link to the buy page contact',
  (select coalesce(member_id::text, 'none') || '|' || (payload->>'to_email') || '|' || (payload->>'first_name') || '|' || (payload->>'message_url')
     from t_note('11900000-0000-0000-0000-00000000f006')),
  'none|guest119@example.com|Gus|https://r119-s.studiior.app/buy#contact');

-- Gift.
select expect_text('gift: template, recipient, /gift with the amount',
  (select template_key || '|' || (payload->>'recipient_name') || '|' || (payload->>'retry_url') || '|' || (payload->>'first_name')
     from t_note('11900000-0000-0000-0000-00000000f007')),
  'checkout_rescue_gift|Rosa|https://r119-s.studiior.app/gift?amount=2500|Gina');

-- Shop.
select expect_text('shop: template, product, link to the product',
  (select template_key || '|' || (payload->>'item_name') || '|' || (payload->>'retry_url')
     from t_note('11900000-0000-0000-0000-00000000f008')),
  'checkout_rescue_shop|Grip Socks|https://r119-s.studiior.app/shop#product-11900000-0000-0000-0000-0000000ab001');

-- Reservation fee: open, full, past.
select expect_text('reservation, open seat: class, day, time, spots, "Hold my spot" to the class page',
  (select (payload->>'class_name') || '|' || (payload->>'time') || '|' || (payload->>'spots_left') || '|'
          || (payload->>'retry_label') || '|' || (payload->>'retry_url')
     from t_note('11900000-0000-0000-0000-00000000f009')),
  'REFORMER FLOW|12:00 PM|4|Hold my spot|https://r119-s.studiior.app/class/11900000-0000-0000-0000-00000000c001');
select expect_text('reservation, open seat: the spots line',
  (select payload->>'spots_line' from t_note('11900000-0000-0000-0000-00000000f009')),
  'There are only 4 spots left in that class. Grab yours before someone else does.');
select expect_text('reservation, full class: free class still waiting, "Book my free class"',
  (select (payload->>'spots_line') || '|' || (payload->>'retry_label') || '|' || (payload->>'retry_url')
     from t_note('11900000-0000-0000-0000-00000000f010')),
  'That class filled up, but your free class is still waiting. Pick another time this week.|Book my free class|https://r119-s.studiior.app/book');
select expect_text('reservation, past class: the same full/past version',
  (select (payload->>'retry_label') from t_note('11900000-0000-0000-0000-00000000f011')), 'Book my free class');
select expect_num('every reservation version carries the credit-back sentence',
  (select count(*) from checkout_rescues cr
     cross join lateral render_notification(cr.notification_id) r
    where cr.kind = 'reservation' and cr.outcome = 'sent'
      and r.text_body like '% a charge for the class. Show up and it comes%back to you as studio credit%'
      and r.text_body like '%₱500%'), 3);

-- Audit.
select expect_num('one checkout.rescue_sent audit row per email sent',
  (select count(*) from audit_logs where studio_id = '11900000-0000-0000-0000-000000000001'
      and action = 'checkout.rescue_sent'), 7);

-- A second sweep sends nothing more; a later sweep sends the one that was too soon.
select expect_text('a second sweep sends nothing', sweep_checkout_rescue(t_now()) ->> 'sent', '0');
select expect_text('an hour later the too-soon checkout is sent',
  sweep_checkout_rescue(t_now() + interval '1 hour') ->> 'sent', '1');
select expect_num('exactly one email per checkout',
  (select count(*) from notifications where dedupe_key like 'checkout_rescue:11900000%'), 8);

-- Seven days: a new failed checkout for the same plan by Mia, two days later, is skipped.
select t_xp('11900000-0000-0000-0000-00000000f020','11900000-0000-0000-0000-00000000dd01','11900000-0000-0000-0000-0000000cc001', now() - interval '2 hours');
select expect_text('same person, same item, within 7 days → skipped',
  checkout_rescue_run('11900000-0000-0000-0000-00000000f020', now(), false), 'sent_recently');

-- The per-email switch.
update studio_settings set disabled_templates = array['checkout_rescue_plan']
 where studio_id = '11900000-0000-0000-0000-000000000001';
select t_xp('11900000-0000-0000-0000-00000000f021','11900000-0000-0000-0000-00000000dd12','11900000-0000-0000-0000-0000000cc001', now() - interval '2 hours');
select expect_text('the per-email switch off → not sent',
  checkout_rescue_run('11900000-0000-0000-0000-00000000f021', now(), false), 'switched_off');
update studio_settings set disabled_templates = '{}' where studio_id = '11900000-0000-0000-0000-000000000001';

-- =============================================================================
-- 2. The backfill: since 9 Nov, reservation fee checkouts never.
-- =============================================================================
-- A reservation checkout after the cutover but outside the sweep's window.
select t_xp('11900000-0000-0000-0000-00000000f030','11900000-0000-0000-0000-00000000dd08', null, '2026-11-26 10:00:00+08', p_booking => '11900000-0000-0000-0000-0000000be004', p_amount => 50000, p_status => 'expired');
select set_config('t.bf', checkout_rescue_backfill('2026-12-05 12:00:00+08')::text, false);
select expect_text('the backfill sends the 15 Nov plan checkout', t_out('11900000-0000-0000-0000-00000000f014'), 'sent');
select expect_text('the backfill reports it', current_setting('t.bf')::jsonb ->> 'plan:sent', '1');
select expect_text('a checkout before 9 Nov is never touched', t_out('11900000-0000-0000-0000-00000000f015'), 'none');
select expect_text('the backfill never sends a reservation fee rescue', t_out('11900000-0000-0000-0000-00000000f030'), 'none');
select expect_num('the backfill queued no reservation email',
  (select count(*) from notifications where dedupe_key = 'checkout_rescue:11900000-0000-0000-0000-00000000f030'), 0);
select expect_text('the backfill is idempotent', checkout_rescue_backfill('2026-12-05 12:00:00+08')::text, '{}');

-- =============================================================================
-- 3. Access.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub', '11900000-0000-0000-0000-0000000000a1', false);
do $$ begin
  perform sweep_checkout_rescue();
  raise exception 'FAIL  a signed-in user ran the sweep';
exception when insufficient_privilege then raise notice 'PASS  the sweep is not callable by a signed-in user';
end $$;
select expect_true('the owner reads the studio''s rescue log',
  (select count(*) from checkout_rescues where studio_id = '11900000-0000-0000-0000-000000000001') > 0);
reset role;
set role anon;
do $$ declare n int; begin
  select count(*) into n from checkout_rescues;
  if n = 0 then raise notice 'PASS  anon reads no rescue rows';
  else raise exception 'FAIL  anon read % rescue rows', n; end if;
exception when insufficient_privilege then raise notice 'PASS  anon cannot read the rescue log';
end $$;
reset role;
select expect_num('anon functions: exactly fifteen',
  (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not like 'expect\_%' and p.proname not like 't\_%' and p.proname not in ('call_jsonb')), 15);

\echo checkout_rescue_test PASS
