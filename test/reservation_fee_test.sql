-- =============================================================================
-- Decision 103 — reservation fee for the free class (migration 20260833430000)
-- =============================================================================
-- UUID space d103, checked free. Run after `supabase db reset`.
--
-- Covers: fee off -> reserve refused (unchanged path); fee on -> a pending_payment
-- hold then the comp free seat after the webhook, with the confirmation email ONLY
-- after payment and carrying the reservation sentence; an abandoned hold freed by
-- the existing sweep_unpaid_dropins with no charge and the member still eligible;
-- attended -> a reservation credit; no-show / late cancel -> kept (no credit);
-- on-time cancel -> credit; the credit applied at the next checkout (capped) and
-- not twice; a refund voids the unused credit; the fee is an invoiceable payment;
-- the existing-booking dues flow (ask once, release past the cut-off, stays
-- eligible, past-cut-off left alone). Guards + anon THIRTEEN.
-- =============================================================================
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

-- A helper: complete a held reservation as the backend would (webhook success).
create or replace function d103_complete(p_booking uuid) returns void language plpgsql as $$
declare v_pur uuid;
begin
  select id into v_pur from xendit_purchases where booking_id = p_booking order by created_at desc limit 1;
  perform xendit_activate_success_internal(v_pur, 'py-' || left(p_booking::text, 8));
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('d1030000-0000-0000-0000-0000000000a1'),  -- owner
  ('d1030000-0000-0000-0000-0000000000e0'),
  ('d1030000-0000-0000-0000-0000000000e1'),
  ('d1030000-0000-0000-0000-0000000000e2'),
  ('d1030000-0000-0000-0000-0000000000e3'),
  ('d1030000-0000-0000-0000-0000000000e4'),
  ('d1030000-0000-0000-0000-0000000000e5'),
  ('d1030000-0000-0000-0000-0000000000e6'),
  ('d1030000-0000-0000-0000-0000000000e7'),
  ('d1030000-0000-0000-0000-0000000000e8');
insert into profiles (id, email)
  select id, id::text||'@example.com' from auth.users where id::text like 'd1030000%';

insert into studios (id, name, slug, timezone, currency, status) values
  ('d1030000-0000-0000-0000-000000000001','Resv A','d103-s','Asia/Manila','PHP','active');
insert into studio_settings (studio_id, free_first_class_enabled, require_waiver,
                             cancellation_cutoff_minutes, dropin_payment_window_minutes) values
  ('d1030000-0000-0000-0000-000000000001', true, false, 720, 15);
insert into locations (id, studio_id, name, is_primary) values
  ('d1030000-0000-0000-0000-00000000000a','d1030000-0000-0000-0000-000000000001','Main',true);
insert into studio_staff (studio_id, user_id, email, role) values
  ('d1030000-0000-0000-0000-000000000001','d1030000-0000-0000-0000-0000000000a1','d103-ow@example.com','owner');

insert into members (id, studio_id, user_id, first_name, last_name, email, status) values
  ('d1030000-0000-0000-0000-0000000000f0','d1030000-0000-0000-0000-000000000001','d1030000-0000-0000-0000-0000000000e0','Mem','Zero','rz0@example.com','lead'),
  ('d1030000-0000-0000-0000-0000000000f1','d1030000-0000-0000-0000-000000000001','d1030000-0000-0000-0000-0000000000e1','Mem','One','rz1@example.com','lead'),
  ('d1030000-0000-0000-0000-0000000000f2','d1030000-0000-0000-0000-000000000001','d1030000-0000-0000-0000-0000000000e2','Mem','Two','rz2@example.com','lead'),
  ('d1030000-0000-0000-0000-0000000000f3','d1030000-0000-0000-0000-000000000001','d1030000-0000-0000-0000-0000000000e3','Mem','Three','rz3@example.com','lead'),
  ('d1030000-0000-0000-0000-0000000000f4','d1030000-0000-0000-0000-000000000001','d1030000-0000-0000-0000-0000000000e4','Mem','Four','rz4@example.com','lead'),
  ('d1030000-0000-0000-0000-0000000000f5','d1030000-0000-0000-0000-000000000001','d1030000-0000-0000-0000-0000000000e5','Mem','Five','rz5@example.com','lead'),
  ('d1030000-0000-0000-0000-0000000000f6','d1030000-0000-0000-0000-000000000001','d1030000-0000-0000-0000-0000000000e6','Mem','Six','rz6@example.com','lead'),
  ('d1030000-0000-0000-0000-0000000000f7','d1030000-0000-0000-0000-000000000001','d1030000-0000-0000-0000-0000000000e7','Mem','Seven','rz7@example.com','lead'),
  ('d1030000-0000-0000-0000-0000000000f8','d1030000-0000-0000-0000-000000000001','d1030000-0000-0000-0000-0000000000e8','Mem','Eight','rz8@example.com','lead');

-- A buyable pack (for the credit-at-next-checkout test) + a drop-in plan.
insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, validity_days, visibility, status) values
  ('d1030000-0000-0000-0000-0000000cc001','d1030000-0000-0000-0000-000000000001','10-Class Pack','class_pack',140000,'PHP',10,30,'public','active'),
  ('d1030000-0000-0000-0000-0000000cc002','d1030000-0000-0000-0000-000000000001','Single Drop-in','drop_in',50000,'PHP',1,30,'public','active');

-- The connected Xendit provider (token 'goodtoken').
insert into studio_payment_providers
  (studio_id, provider, secret_key_ciphertext, callback_token_ciphertext, callback_token_sha256,
   key_last4, test_mode, connected_by) values
  ('d1030000-0000-0000-0000-000000000001','xendit','v1.x','v1.y',
   encode(digest('goodtoken','sha256'),'hex'), 'tok0', true, 'd1030000-0000-0000-0000-0000000000a1');

-- A rooms + a class type, and nine future scheduled occurrences (one per member).
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('d1030000-0000-0000-0000-00000000b001','d1030000-0000-0000-0000-000000000001','d1030000-0000-0000-0000-00000000000a','Studio',20),
  ('d1030000-0000-0000-0000-00000000b002','d1030000-0000-0000-0000-000000000001','d1030000-0000-0000-0000-00000000000a','Studio 2',20),
  ('d1030000-0000-0000-0000-00000000b003','d1030000-0000-0000-0000-000000000001','d1030000-0000-0000-0000-00000000000a','Studio 3',20);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('d1030000-0000-0000-0000-0000000cf001','d1030000-0000-0000-0000-000000000001','Reformer',50,20);

insert into class_occurrences (id, studio_id, class_type_id, room_id, location_id, name, starts_at, ends_at,
                               capacity, status, staffing)
select ('d1030000-0000-0000-0000-00000000c00' || n)::uuid,
       'd1030000-0000-0000-0000-000000000001','d1030000-0000-0000-0000-0000000cf001',
       'd1030000-0000-0000-0000-00000000b001','d1030000-0000-0000-0000-00000000000a','Reformer Flow',
       now() + make_interval(days => 3, hours => n), now() + make_interval(days => 3, hours => n, mins => 50),
       20, 'scheduled', 'assigned'
  from generate_series(1,9) n;
-- The two dues-flow occurrences move to near-now; keep them in their own rooms
-- so the time move cannot collide on occ_room_no_overlap.
update class_occurrences set room_id = 'd1030000-0000-0000-0000-00000000b002' where id = 'd1030000-0000-0000-0000-00000000c008';
update class_occurrences set room_id = 'd1030000-0000-0000-0000-00000000b003' where id = 'd1030000-0000-0000-0000-00000000c009';

-- =============================================================================
-- 1. Fee OFF -> reserve_free_first is refused (the direct book_first_free path is
--    unchanged). Set fee to 0, test, then turn it on at 15000.
-- =============================================================================
update studio_settings set free_first_reservation_fee_cents = 0
 where studio_id = 'd1030000-0000-0000-0000-000000000001';
set role authenticated; select set_config('request.jwt.claim.sub','d1030000-0000-0000-0000-0000000000e0',false);
select set_config('t.off', (reserve_free_first('d1030000-0000-0000-0000-00000000c001') ->> 'reason'), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('fee off: reserve_free_first refused no_reservation_fee',
  current_setting('t.off'), 'no_reservation_fee');
-- The direct free booking still works with the fee off.
set role authenticated; select set_config('request.jwt.claim.sub','d1030000-0000-0000-0000-0000000000e0',false);
select set_config('t.direct', (book_first_free('d1030000-0000-0000-0000-00000000c001') ->> 'ok'), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('fee off: book_first_free still books directly', current_setting('t.direct'), 'true');

update studio_settings set free_first_reservation_fee_cents = 15000
 where studio_id = 'd1030000-0000-0000-0000-000000000001';

-- =============================================================================
-- 2. Fee ON -> reserve holds a pending_payment comp seat, NO guest_pass, NO email.
--    Then the webhook completes it: booked + comp, a guest_pass, a reservation_fee
--    payment, and exactly one free_booking_confirmed carrying the reservation line.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','d1030000-0000-0000-0000-0000000000e1',false);
select set_config('t.res', reserve_free_first('d1030000-0000-0000-0000-00000000c002')::text, false);
select set_config('t.bk', (current_setting('t.res')::jsonb ->> 'booking_id'), false);
-- xendit_begin_reservation as the member.
select set_config('t.pur', (select purchase_id::text from xendit_begin_reservation(
   'd1030000-0000-0000-0000-000000000001', (current_setting('t.bk'))::uuid)), false);
select set_config('request.jwt.claim.sub','',false); reset role;

select expect_text('reserve: held booking is pending_payment',
  (select status::text from bookings where id = current_setting('t.bk')::uuid), 'pending_payment');
select expect_text('reserve: held booking is comp',
  (select payment_source::text from bookings where id = current_setting('t.bk')::uuid), 'comp');
select expect_num('reserve: no guest_pass yet', (select count(*) from guest_passes
   where guest_booking_id = current_setting('t.bk')::uuid), 0);
select expect_num('reserve: no confirmation email before payment', (select count(*) from notifications
   where member_id = 'd1030000-0000-0000-0000-0000000000f1'
     and template_key in ('booking_confirmed','free_booking_confirmed','free_booking_pending')), 0);
select expect_num('reserve: no payment before webhook', (select count(*) from payments
   where booking_id = current_setting('t.bk')::uuid), 0);
select expect_num('reserve: the purchase carries the booking + the fee', (select count(*) from xendit_purchases
   where id = current_setting('t.pur')::uuid and booking_id = current_setting('t.bk')::uuid and amount_cents = 15000), 1);

-- The webhook: complete.
select d103_complete(current_setting('t.bk')::uuid);
select expect_text('webhook: booking is now booked', (select status::text from bookings where id = current_setting('t.bk')::uuid), 'booked');
select expect_text('webhook: booking is comp', (select payment_source::text from bookings where id = current_setting('t.bk')::uuid), 'comp');
select expect_num('webhook: once-ever host-null guest_pass written', (select count(*) from guest_passes
   where guest_booking_id = current_setting('t.bk')::uuid and host_member_id is null), 1);
select expect_num('webhook: a succeeded reservation_fee payment of 15000', (select count(*) from payments
   where booking_id = current_setting('t.bk')::uuid and kind = 'reservation_fee'
     and status = 'succeeded' and amount_cents = 15000), 1);
select expect_num('webhook: exactly one free_booking_confirmed, after payment', (select count(*) from notifications
   where member_id = 'd1030000-0000-0000-0000-0000000000f1' and template_key = 'free_booking_confirmed'), 1);
select expect_true('webhook: the confirmation carries the reservation sentence',
  (select (payload ->> 'reservation_html') like '%reservation fee comes off your next purchase%'
     from notifications where member_id = 'd1030000-0000-0000-0000-0000000000f1'
      and template_key = 'free_booking_confirmed' limit 1));

-- =============================================================================
-- 3. Abandon -> the existing sweep_unpaid_dropins frees the seat, no charge, the
--    member stays free-first eligible.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','d1030000-0000-0000-0000-0000000000e5',false);
select set_config('t.bk5', (reserve_free_first('d1030000-0000-0000-0000-00000000c005') ->> 'booking_id'), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select set_config('t.cnt_before', (select booked_count::text from class_occurrences where id='d1030000-0000-0000-0000-00000000c005'), false);
-- Backdate the hold past the drop-in window and sweep.
update bookings set booked_at = now() - interval '1 hour' where id = current_setting('t.bk5')::uuid;
select sweep_unpaid_dropins();
select expect_text('abandon: the held seat is cancelled',
  (select status::text from bookings where id = current_setting('t.bk5')::uuid), 'cancelled');
select expect_num('abandon: no payment was taken', (select count(*) from payments
   where booking_id = current_setting('t.bk5')::uuid and status = 'succeeded'), 0);
select expect_num('abandon: no guest_pass -> free class not consumed', (select count(*) from guest_passes
   where guest_booking_id = current_setting('t.bk5')::uuid), 0);
set role authenticated; select set_config('request.jwt.claim.sub','d1030000-0000-0000-0000-0000000000e5',false);
select set_config('t.elig5', (free_first_eligibility('d1030000-0000-0000-0000-000000000001','d1030000-0000-0000-0000-0000000000f5') ->> 'ok'), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('abandon: the member is still free-first eligible', current_setting('t.elig5'), 'true');

-- =============================================================================
-- 4. Attended -> a reservation credit of the fee amount.
-- =============================================================================
-- M1 (completed in step 2). Mark attended.
update bookings set status = 'attended' where id = current_setting('t.bk')::uuid;
select expect_num('attended: one reservation credit written', (select count(*) from member_credits
   where member_id = 'd1030000-0000-0000-0000-0000000000f1' and reason = 'reservation_credit'), 1);
select expect_num('attended: the credit is the fee amount, unused', (select amount_cents - used_cents
   from member_credits where member_id = 'd1030000-0000-0000-0000-0000000000f1' and reason = 'reservation_credit'), 15000);

-- =============================================================================
-- 5. No-show -> kept (no credit). M2.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','d1030000-0000-0000-0000-0000000000e2',false);
select set_config('t.bk2', (reserve_free_first('d1030000-0000-0000-0000-00000000c003') ->> 'booking_id'), false);
select set_config('t.j2', (select purchase_id::text from xendit_begin_reservation('d1030000-0000-0000-0000-000000000001', (current_setting('t.bk2'))::uuid)), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select d103_complete(current_setting('t.bk2')::uuid);
update bookings set status = 'no_show' where id = current_setting('t.bk2')::uuid;
select expect_num('no-show: the fee is kept, NO credit', (select count(*) from member_credits
   where member_id = 'd1030000-0000-0000-0000-0000000000f2' and reason = 'reservation_credit'), 0);

-- =============================================================================
-- 6. Late cancel -> kept. M3.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','d1030000-0000-0000-0000-0000000000e3',false);
select set_config('t.bk3', (reserve_free_first('d1030000-0000-0000-0000-00000000c004') ->> 'booking_id'), false);
select set_config('t.j3', (select purchase_id::text from xendit_begin_reservation('d1030000-0000-0000-0000-000000000001', (current_setting('t.bk3'))::uuid)), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select d103_complete(current_setting('t.bk3')::uuid);
update bookings set status = 'late_cancelled', cancelled_at = now() where id = current_setting('t.bk3')::uuid;
select expect_num('late cancel: the fee is kept, NO credit', (select count(*) from member_credits
   where member_id = 'd1030000-0000-0000-0000-0000000000f3' and reason = 'reservation_credit'), 0);

-- =============================================================================
-- 7. On-time cancel -> credit. M4.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','d1030000-0000-0000-0000-0000000000e4',false);
select set_config('t.bk4', (reserve_free_first('d1030000-0000-0000-0000-00000000c006') ->> 'booking_id'), false);
select set_config('t.j4', (select purchase_id::text from xendit_begin_reservation('d1030000-0000-0000-0000-000000000001', (current_setting('t.bk4'))::uuid)), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select d103_complete(current_setting('t.bk4')::uuid);
update bookings set status = 'cancelled', cancelled_at = now() where id = current_setting('t.bk4')::uuid;
select expect_num('on-time cancel: a reservation credit is written', (select count(*) from member_credits
   where member_id = 'd1030000-0000-0000-0000-0000000000f4' and reason = 'reservation_credit'), 1);

-- =============================================================================
-- 8. The credit applies at the next checkout (capped at a positive due), and not
--    twice. M1 holds a 15000 credit (step 4).
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','d1030000-0000-0000-0000-0000000000e1',false);
select set_config('t.buy', (select row_to_json(x)::text from
   (select amount_cents, credit_applied_cents from xendit_begin_purchase(
      'd1030000-0000-0000-0000-000000000001','d1030000-0000-0000-0000-0000000cc001')) x), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_num('credit: applied 15000 of the pack price',
  (current_setting('t.buy')::jsonb ->> 'credit_applied_cents')::bigint, 15000);
select expect_num('credit: the online due is the pack price minus the credit',
  (current_setting('t.buy')::jsonb ->> 'amount_cents')::bigint, 125000);
-- Activate the pack purchase -> the credit is consumed.
select set_config('t.pbuy', (select id::text from xendit_purchases
   where member_id = 'd1030000-0000-0000-0000-0000000000f1' and plan_id = 'd1030000-0000-0000-0000-0000000cc001'
   order by created_at desc limit 1), false);
select xendit_activate_success_internal(current_setting('t.pbuy')::uuid, 'pay-pack-1');
select expect_num('credit: fully consumed on activation', (select coalesce(sum(amount_cents - used_cents),0)
   from member_credits where member_id = 'd1030000-0000-0000-0000-0000000000f1' and voided_at is null), 0);
-- A SECOND checkout sees no credit.
set role authenticated; select set_config('request.jwt.claim.sub','d1030000-0000-0000-0000-0000000000e1',false);
select set_config('t.buy2', (select credit_applied_cents::text from xendit_begin_purchase(
   'd1030000-0000-0000-0000-000000000001','d1030000-0000-0000-0000-0000000cc002')), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_num('credit: not applied twice (second checkout gets 0)', current_setting('t.buy2')::bigint, 0);

-- =============================================================================
-- 9. A refund of the reservation fee voids the UNUSED credit. M6.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','d1030000-0000-0000-0000-0000000000e6',false);
select set_config('t.bk6', (reserve_free_first('d1030000-0000-0000-0000-00000000c007') ->> 'booking_id'), false);
select set_config('t.j6', (select purchase_id::text from xendit_begin_reservation('d1030000-0000-0000-0000-000000000001', (current_setting('t.bk6'))::uuid)), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select d103_complete(current_setting('t.bk6')::uuid);
update bookings set status = 'attended' where id = current_setting('t.bk6')::uuid;  -- credit written
select expect_num('refund: the member has an unused reservation credit', (select coalesce(sum(amount_cents-used_cents),0)
   from member_credits where member_id = 'd1030000-0000-0000-0000-0000000000f6' and voided_at is null), 15000);
-- The fee is an invoiceable succeeded payment.
select expect_true('invoice: the reservation fee got an invoice number',
  (select invoice_no is not null from payments where booking_id = current_setting('t.bk6')::uuid
     and kind = 'reservation_fee'));
-- Refund it as the owner (manager-up).
select set_config('t.payid', (select id::text from payments where booking_id = current_setting('t.bk6')::uuid and kind='reservation_fee'), false);
set role authenticated; select set_config('request.jwt.claim.sub','d1030000-0000-0000-0000-0000000000a1',false);
select record_refund(current_setting('t.payid')::uuid, null, 'test refund', false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_num('refund: the unused credit is voided', (select coalesce(sum(amount_cents-used_cents),0)
   from member_credits where member_id = 'd1030000-0000-0000-0000-0000000000f6' and voided_at is null), 0);

-- =============================================================================
-- 10. Existing-booking dues flow. M7: a free booking made before the fee (no
--     reservation payment). Set from_date -> the sweep asks once; past the cut-off
--     it releases and the member stays eligible. M8: cut-off already past -> left.
-- =============================================================================
-- M7's free booking (direct, no fee) on c08 (3+8h out).
set role authenticated; select set_config('request.jwt.claim.sub','d1030000-0000-0000-0000-0000000000e7',false);
select set_config('t.bk7', (book_first_free('d1030000-0000-0000-0000-00000000c008') ->> 'booking_id'), false);
select set_config('request.jwt.claim.sub','',false); reset role;
-- M8's free booking on c09, which we will move so its cut-off is already past.
set role authenticated; select set_config('request.jwt.claim.sub','d1030000-0000-0000-0000-0000000000e8',false);
select set_config('t.bk8', (book_first_free('d1030000-0000-0000-0000-00000000c009') ->> 'booking_id'), false);
select set_config('request.jwt.claim.sub','',false); reset role;
-- c09 starts in 30 minutes: with a 720-minute cut-off, its cut-off is already past.
update class_occurrences set starts_at = now() + interval '30 minutes',
       ends_at = now() + interval '80 minutes' where id = 'd1030000-0000-0000-0000-00000000c009';

update studio_settings set free_first_reservation_from = (now() at time zone 'Asia/Manila')::date
 where studio_id = 'd1030000-0000-0000-0000-000000000001';

-- First sweep pass.
select sweep_free_reservation_dues(now());
select expect_num('dues: M7 (cut-off ahead) is asked once', (select count(*) from notifications
   where member_id = 'd1030000-0000-0000-0000-0000000000f7' and template_key = 'free_reservation_due'), 1);
select expect_num('dues: M8 (cut-off already past) is NOT asked', (select count(*) from notifications
   where member_id = 'd1030000-0000-0000-0000-0000000000f8' and template_key = 'free_reservation_due'), 0);
select expect_true('dues: the due email carries the fee and a deadline',
  (select (payload ->> 'fee') is not null and (payload ->> 'deadline') is not null
     from notifications where member_id = 'd1030000-0000-0000-0000-0000000000f7'
      and template_key = 'free_reservation_due' limit 1));
-- A second pass does not ask again.
select sweep_free_reservation_dues(now());
select expect_num('dues: a second pass does not re-ask', (select count(*) from notifications
   where member_id = 'd1030000-0000-0000-0000-0000000000f7' and template_key = 'free_reservation_due'), 1);
select expect_num('dues: M8 past the cut-off is left as it is (still booked)', (select count(*) from bookings
   where id = current_setting('t.bk8')::uuid and status = 'booked'), 1);

-- Now move M7's class so its cut-off has passed and it was not paid -> release.
update class_occurrences set starts_at = now() + interval '20 minutes',
       ends_at = now() + interval '70 minutes' where id = 'd1030000-0000-0000-0000-00000000c008';
select sweep_free_reservation_dues(now());
select expect_text('dues: M7 past the cut-off, unpaid, is released (cancelled on-time)',
  (select status::text from bookings where id = current_setting('t.bk7')::uuid), 'cancelled');
select expect_num('dues: M7 gets a release email', (select count(*) from notifications
   where member_id = 'd1030000-0000-0000-0000-0000000000f7' and template_key = 'free_reservation_released'), 1);
set role authenticated; select set_config('request.jwt.claim.sub','d1030000-0000-0000-0000-0000000000e7',false);
select set_config('t.elig7', (free_first_eligibility('d1030000-0000-0000-0000-000000000001','d1030000-0000-0000-0000-0000000000f7') ->> 'ok'), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('dues: the released member stays free-first eligible', current_setting('t.elig7'), 'true');

-- =============================================================================
-- 11. Guards.
-- =============================================================================
-- xendit_begin_reservation refuses a booking that is not a held reservation.
set role authenticated; select set_config('request.jwt.claim.sub','d1030000-0000-0000-0000-0000000000e1',false);
do $$
begin
  begin
    perform xendit_begin_reservation('d1030000-0000-0000-0000-000000000001', current_setting('t.bk')::uuid);
    raise exception 'FAIL  begin_reservation on a non-held booking should refuse';
  exception when sqlstate 'PT409' then raise notice 'PASS  begin_reservation refuses a non-held booking (PT409)';
  end;
end $$;
select set_config('request.jwt.claim.sub','',false); reset role;

-- The sweep refuses a signed-in user.
set role authenticated; select set_config('request.jwt.claim.sub','d1030000-0000-0000-0000-0000000000e1',false);
do $$
begin
  begin
    perform sweep_free_reservation_dues(now());
    raise exception 'FAIL  the dues sweep should refuse a user';
  exception when sqlstate '42501' then raise notice 'PASS  the dues sweep refuses a signed-in user (grant is the boundary)';
  end;
end $$;
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- 12. Anon surface EXACTLY THIRTEEN.
-- =============================================================================
select expect_num('anon surface is exactly thirteen',
  (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not like 'expect_%' and p.proname not in ('login','sig','psig','d103_complete')), 13);

select 'reservation_fee_test: all assertions passed' as result;
