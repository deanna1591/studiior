-- =============================================================================
-- Step 12 (migration 367): Decision 36 (a) staff return what a late cancel took.
-- Credit case, free class case, the drop-in cases, strike and infraction
-- voiding, the three refusals, the reservation fee untouched.
-- UUID space 36a0, checked free. Run after `supabase db reset`.
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

insert into auth.users (id) values
  ('36a00000-0000-0000-0000-0000000000a1'),   -- owner
  ('36a00000-0000-0000-0000-0000000000f1'),   -- front desk
  ('36a00000-0000-0000-0000-0000000000b1');   -- instructor
insert into profiles (id, email, full_name) values
  ('36a00000-0000-0000-0000-0000000000a1','36a0-owner@example.com','Olive Owner'),
  ('36a00000-0000-0000-0000-0000000000f1','36a0-desk@example.com','Dee Desk'),
  ('36a00000-0000-0000-0000-0000000000b1','36a0-coach@example.com','Cora Coach');
insert into studios (id, name, slug, timezone, currency, status) values
  ('36a00000-0000-0000-0000-0000000000a0','Return Studio','36a0-s','Asia/Manila','PHP','active');
insert into studio_settings (studio_id, free_first_class_enabled, cancellation_cutoff_minutes, time_format)
values ('36a00000-0000-0000-0000-0000000000a0', true, 720, '24h');
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('36a00000-0000-0000-0000-0000000005a1','36a00000-0000-0000-0000-0000000000a0','36a00000-0000-0000-0000-0000000000a1','36a0-owner@example.com','owner'),
  ('36a00000-0000-0000-0000-0000000005f1','36a00000-0000-0000-0000-0000000000a0','36a00000-0000-0000-0000-0000000000f1','36a0-desk@example.com','front_desk'),
  ('36a00000-0000-0000-0000-0000000005b1','36a00000-0000-0000-0000-0000000000a0','36a00000-0000-0000-0000-0000000000b1','36a0-coach@example.com','instructor');
insert into locations (id, studio_id, name, is_primary) values
  ('36a00000-0000-0000-0000-00000000010c','36a00000-0000-0000-0000-0000000000a0','Main', true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('36a00000-0000-0000-0000-000000000101','36a00000-0000-0000-0000-0000000000a0','36a00000-0000-0000-0000-00000000010c','Room',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('36a00000-0000-0000-0000-0000000ce001','36a00000-0000-0000-0000-0000000000a0','Reformer',50,10);
insert into class_occurrences (id, studio_id, name, location_id, class_type_id, room_id, starts_at, ends_at, capacity, status) values
  ('36a00000-0000-0000-0000-0000000ac001','36a00000-0000-0000-0000-0000000000a0','Reformer Flow','36a00000-0000-0000-0000-00000000010c',
   '36a00000-0000-0000-0000-0000000ce001','36a00000-0000-0000-0000-000000000101',
   date_trunc('day', now() at time zone 'Asia/Manila') at time zone 'Asia/Manila' + interval '2 days 10 hours',
   date_trunc('day', now() at time zone 'Asia/Manila') at time zone 'Asia/Manila' + interval '2 days 10 hours 50 minutes', 10, 'scheduled');

insert into members (id, studio_id, first_name, last_name, email, status, waiver_signed_at) values
  ('36a00000-0000-0000-0000-0000000d0001','36a00000-0000-0000-0000-0000000000a0','Pia','Pack','36a0-pack@example.com','active', now()),
  ('36a00000-0000-0000-0000-0000000d0002','36a00000-0000-0000-0000-0000000000a0','Fay','Free','36a0-free@example.com','lead', now()),
  ('36a00000-0000-0000-0000-0000000d0003','36a00000-0000-0000-0000-0000000000a0','Dan','Paid','36a0-paid@example.com','active', now()),
  ('36a00000-0000-0000-0000-0000000d0004','36a00000-0000-0000-0000-0000000000a0','Uma','Unpaid','36a0-unpaid@example.com','active', now()),
  ('36a00000-0000-0000-0000-0000000d0005','36a00000-0000-0000-0000-0000000000a0','Ena','Ended','36a0-ended@example.com','active', now()),
  ('36a00000-0000-0000-0000-0000000d0006','36a00000-0000-0000-0000-0000000000a0','Bea','Booked','36a0-booked@example.com','active', now());

insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, validity_days, visibility, status) values
  ('36a00000-0000-0000-0000-0000000cc001','36a00000-0000-0000-0000-0000000000a0','Intro Offer','class_pack',179900,'PHP',3,14,'public','active');
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on, credits_remaining, expires_on) values
  ('36a00000-0000-0000-0000-00000000aa01','36a00000-0000-0000-0000-0000000000a0','36a00000-0000-0000-0000-0000000d0001','36a00000-0000-0000-0000-0000000cc001','active',179900,'PHP', current_date, 1, current_date + 14),
  ('36a00000-0000-0000-0000-00000000aa05','36a00000-0000-0000-0000-0000000000a0','36a00000-0000-0000-0000-0000000d0005','36a00000-0000-0000-0000-0000000cc001','cancelled',179900,'PHP', current_date, 0, current_date + 14);
insert into credit_ledger (id, studio_id, member_id, membership_id, delta, reason, balance_after, expires_at) values
  ('36a00000-0000-0000-0000-00000000c101','36a00000-0000-0000-0000-0000000000a0','36a00000-0000-0000-0000-0000000d0001','36a00000-0000-0000-0000-00000000aa01', 3, 'purchase', 3, now() + interval '14 days'),
  ('36a00000-0000-0000-0000-00000000c102','36a00000-0000-0000-0000-0000000000a0','36a00000-0000-0000-0000-0000000d0001','36a00000-0000-0000-0000-00000000aa01',-1, 'booking', 2, now() + interval '14 days'),
  ('36a00000-0000-0000-0000-00000000c105','36a00000-0000-0000-0000-0000000000a0','36a00000-0000-0000-0000-0000000d0005','36a00000-0000-0000-0000-00000000aa05',-1, 'booking', 0, now() + interval '14 days');

-- The late-cancelled bookings (as cancel_booking leaves them).
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source, membership_id, credit_entry_id, cancelled_at, is_late_cancel) values
  ('36a00000-0000-0000-0000-0000000bb001','36a00000-0000-0000-0000-0000000000a0','36a00000-0000-0000-0000-0000000ac001','36a00000-0000-0000-0000-0000000d0001','late_cancelled','class_pack','36a00000-0000-0000-0000-00000000aa01','36a00000-0000-0000-0000-00000000c102', now(), true),
  ('36a00000-0000-0000-0000-0000000bb002','36a00000-0000-0000-0000-0000000000a0','36a00000-0000-0000-0000-0000000ac001','36a00000-0000-0000-0000-0000000d0002','late_cancelled','comp', null, null, now(), true),
  ('36a00000-0000-0000-0000-0000000bb003','36a00000-0000-0000-0000-0000000000a0','36a00000-0000-0000-0000-0000000ac001','36a00000-0000-0000-0000-0000000d0003','late_cancelled','drop_in', null, null, now(), true),
  ('36a00000-0000-0000-0000-0000000bb004','36a00000-0000-0000-0000-0000000000a0','36a00000-0000-0000-0000-0000000ac001','36a00000-0000-0000-0000-0000000d0004','late_cancelled','drop_in', null, null, now(), true),
  ('36a00000-0000-0000-0000-0000000bb005','36a00000-0000-0000-0000-0000000000a0','36a00000-0000-0000-0000-0000000ac001','36a00000-0000-0000-0000-0000000d0005','late_cancelled','class_pack','36a00000-0000-0000-0000-00000000aa05','36a00000-0000-0000-0000-00000000c105', now(), true),
  ('36a00000-0000-0000-0000-0000000bb006','36a00000-0000-0000-0000-0000000000a0','36a00000-0000-0000-0000-0000000ac001','36a00000-0000-0000-0000-0000000d0006','booked','class_pack', null, null, null, false);
insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email, occurrence_id, guest_booking_id, status) values
  ('36a00000-0000-0000-0000-0000000000a0', null, '36a00000-0000-0000-0000-0000000d0002','36a0-free@example.com',
   '36a00000-0000-0000-0000-0000000ac001','36a00000-0000-0000-0000-0000000bb002','cancelled');
insert into payments (id, studio_id, member_id, booking_id, amount_cents, currency, status, provider, method, paid_at) values
  ('36a00000-0000-0000-0000-0000000fa003','36a00000-0000-0000-0000-0000000000a0','36a00000-0000-0000-0000-0000000d0003','36a00000-0000-0000-0000-0000000bb003',105000,'PHP','succeeded','manual','cash', now());
-- A reservation fee and a reservation credit for Fay, which this action never touches.
insert into payments (id, studio_id, member_id, booking_id, kind, amount_cents, currency, status, provider, paid_at) values
  ('36a00000-0000-0000-0000-0000000fa002','36a00000-0000-0000-0000-0000000000a0','36a00000-0000-0000-0000-0000000d0002','36a00000-0000-0000-0000-0000000bb002','reservation_fee',50000,'PHP','succeeded','manual', now());
insert into member_credits (studio_id, member_id, amount_cents, currency, reason)
values ('36a00000-0000-0000-0000-0000000000a0','36a00000-0000-0000-0000-0000000d0002', 50000, 'PHP', 'reservation_credit');
insert into member_infractions (studio_id, member_id, booking_id, occurrence_id, kind, occurred_at) values
  ('36a00000-0000-0000-0000-0000000000a0','36a00000-0000-0000-0000-0000000d0001','36a00000-0000-0000-0000-0000000bb001','36a00000-0000-0000-0000-0000000ac001','late_cancel', now()),
  ('36a00000-0000-0000-0000-0000000000a0','36a00000-0000-0000-0000-0000000d0004','36a00000-0000-0000-0000-0000000bb004','36a00000-0000-0000-0000-0000000ac001','late_cancel', now());
update members set desk_pay_blocked_at = now(), desk_pay_blocked_reason = 'late_cancel'
 where id = '36a00000-0000-0000-0000-0000000d0004';

select set_config('t.fee_rows', (select count(*) || '/' || sum(amount_cents) from payments
  where member_id = '36a00000-0000-0000-0000-0000000d0002' and kind = 'reservation_fee'), false);
select set_config('t.credit_rows', (select count(*) || '/' || sum(amount_cents) || '/' || sum(coalesce(used_cents, 0))
  from member_credits where member_id = '36a00000-0000-0000-0000-0000000d0002'), false);

-- =============================================================================
-- 1. Guards and the seat kinds.
-- =============================================================================
reset role; set role authenticated; select set_config('request.jwt.claim.sub','36a00000-0000-0000-0000-0000000000b1',false);
select expect_err('1.1 an instructor cannot return a credit',
  $$select return_booking_credit('36a00000-0000-0000-0000-0000000bb001', null)$$, 'PT403');
reset role; set role authenticated; select set_config('request.jwt.claim.sub','36a00000-0000-0000-0000-0000000000f1',false);
select expect_eq('1.2 the reader names every seat kind',
  (select string_agg(seat_kind, ',' order by booking_id) from late_cancel_returns('36a00000-0000-0000-0000-0000000000a0',
     array['36a00000-0000-0000-0000-0000000bb001','36a00000-0000-0000-0000-0000000bb002','36a00000-0000-0000-0000-0000000bb003',
           '36a00000-0000-0000-0000-0000000bb004','36a00000-0000-0000-0000-0000000bb005']::uuid[])),
  'credit,free_first,paid_drop_in,unpaid_drop_in,credit');
select expect_eq('1.3 a live booking: not_late_cancelled',
  return_booking_credit('36a00000-0000-0000-0000-0000000bb006', null) ->> 'reason', 'not_late_cancelled');
select expect_eq('1.4 a paid drop-in: nothing to return, the sentence',
  return_booking_credit('36a00000-0000-0000-0000-0000000bb003', null) ->> 'message',
  'Nothing to return: this seat was paid as a drop-in. Refunds are under Payments.');
select expect_eq('1.5 an ended plan: plan_ended',
  return_booking_credit('36a00000-0000-0000-0000-0000000bb005', null) ->> 'reason', 'plan_ended');
reset role;
select expect_eq('1.6 the refusals changed nothing (no refund rows)', (select count(*)::text from credit_ledger
  where reason = 'cancellation_refund' and studio_id = '36a00000-0000-0000-0000-0000000000a0'), '0');

-- =============================================================================
-- 2. The credit case (Yssa's shape).
-- =============================================================================
reset role; set role authenticated; select set_config('request.jwt.claim.sub','36a00000-0000-0000-0000-0000000000f1',false);
select expect_eq('2.1 the credit goes back', return_booking_credit('36a00000-0000-0000-0000-0000000bb001', 'Booked by mistake') ->> 'kind', 'credit');
reset role;
select expect_eq('2.2 a +1 cancellation_refund with the original expiry',
  (select delta || '/' || (expires_at = (select expires_at from credit_ledger where id = '36a00000-0000-0000-0000-00000000c102'))
     from credit_ledger where booking_id = '36a00000-0000-0000-0000-0000000bb001' and reason = 'cancellation_refund'), '1/true');
select expect_eq('2.3 the pack has 2 credits again', (select credits_remaining::text from memberships where id = '36a00000-0000-0000-0000-00000000aa01'), '2');
select expect_eq('2.4 the booking stays late_cancelled', (select status::text from bookings where id = '36a00000-0000-0000-0000-0000000bb001'), 'late_cancelled');
select expect_eq('2.5 the infraction is voided', (select status from member_infractions where booking_id = '36a00000-0000-0000-0000-0000000bb001'), 'voided');
select expect_eq('2.6 one audit row with the note and the balances',
  (select (after ->> 'note') || '/' || (before ->> 'balance') || '/' || (after ->> 'balance') from audit_logs
    where action = 'booking.credit_returned_by_studio' and entity_id = '36a00000-0000-0000-0000-0000000bb001'), 'Booked by mistake/2/3');
select expect_eq('2.7 one email queued', (select count(*)::text from notifications
  where template_key = 'credit_returned_by_studio' and member_id = '36a00000-0000-0000-0000-0000000d0001'), '1');
select expect_true('2.8 the Journey row: "Credit returned by Dee: Booked by mistake"',
  exists (select 1 from member_activity('36a00000-0000-0000-0000-0000000d0001', current_date - 30, current_date + 30)
           where kind = 'credit_returned' and title = 'Credit returned by Dee: Booked by mistake'));
reset role; set role authenticated; select set_config('request.jwt.claim.sub','36a00000-0000-0000-0000-0000000000a1',false);
select expect_eq('2.9 a second return: already returned, the sentence',
  return_booking_credit('36a00000-0000-0000-0000-0000000bb001', null) ->> 'message',
  'Already returned on ' || to_char(now() at time zone 'Asia/Manila', 'FMDD Mon YYYY') || ' by Dee.');

-- =============================================================================
-- 3. The free class case.
-- =============================================================================
reset role;
select expect_eq('3.1 before: the late cancel used the free class',
  free_first_eligibility_run('36a00000-0000-0000-0000-0000000000a0', '36a00000-0000-0000-0000-0000000d0002') ->> 'reason', 'late_cancel');
reset role; set role authenticated; select set_config('request.jwt.claim.sub','36a00000-0000-0000-0000-0000000000f1',false);
select expect_eq('3.2 the free class goes back', return_booking_credit('36a00000-0000-0000-0000-0000000bb002', null) ->> 'kind', 'free_first');
reset role;
select expect_eq('3.3 after: eligible again',
  free_first_eligibility_run('36a00000-0000-0000-0000-0000000000a0', '36a00000-0000-0000-0000-0000000d0002') ->> 'ok', 'true');
select expect_eq('3.4 member_has_had_free agrees', member_has_had_free('36a00000-0000-0000-0000-0000000000a0', '36a00000-0000-0000-0000-0000000d0002')::text, 'false');
select expect_eq('3.5 the marker row carries no credit', (select delta::text from credit_ledger
  where booking_id = '36a00000-0000-0000-0000-0000000bb002' and reason = 'cancellation_refund'), '0');
select expect_eq('3.6 the reservation fee payment is untouched', (select count(*) || '/' || sum(amount_cents) from payments
  where member_id = '36a00000-0000-0000-0000-0000000d0002' and kind = 'reservation_fee'), current_setting('t.fee_rows'));
select expect_eq('3.7 the reservation credit is untouched', (select count(*) || '/' || sum(amount_cents) || '/' || sum(coalesce(used_cents, 0))
  from member_credits where member_id = '36a00000-0000-0000-0000-0000000d0002'), current_setting('t.credit_rows'));

-- =============================================================================
-- 4. The unpaid drop-in: infraction and desk-pay strike cleared, no credit.
-- =============================================================================
reset role; set role authenticated; select set_config('request.jwt.claim.sub','36a00000-0000-0000-0000-0000000000f1',false);
select expect_eq('4.1 cleared', return_booking_credit('36a00000-0000-0000-0000-0000000bb004', 'Traffic') ->> 'desk_pay_restored', 'true');
reset role;
select expect_eq('4.2 the strike is gone', (select coalesce(desk_pay_blocked_reason, 'none') from members where id = '36a00000-0000-0000-0000-0000000d0004'), 'none');
select expect_eq('4.3 the infraction is voided', (select status from member_infractions where booking_id = '36a00000-0000-0000-0000-0000000bb004'), 'voided');
select expect_eq('4.4 no money moved', (select count(*)::text from payments where member_id = '36a00000-0000-0000-0000-0000000d0004'), '0');

-- =============================================================================
-- 5. The email renders clean; anon stays fourteen.
-- =============================================================================
select expect_eq('5.1 the email renders with nothing stripped',
  (select coalesce(array_length(r.stripped, 1), 0)::text from notifications n
     cross join lateral render_notification(n.id) r
    where n.template_key = 'credit_returned_by_studio' and n.member_id = '36a00000-0000-0000-0000-0000000d0001'), '0');
select expect_true('5.2 the email says what came back',
  (select position('The class credit is back on your Intro Offer.' in r.text_body) > 0 from notifications n
     cross join lateral render_notification(n.id) r
    where n.template_key = 'credit_returned_by_studio' and n.member_id = '36a00000-0000-0000-0000-0000000d0001'));
reset role; set role anon;
select expect_err('5.3 anon cannot call it', $$select return_booking_credit('36a00000-0000-0000-0000-0000000bb001', null)$$, '42501');
reset role;
select expect_eq('5.4 anon surface EXACTLY FOURTEEN', (select count(*)::text from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.proname not like 'expect\_%' and p.proname not in ('call_jsonb')
     and has_function_privilege('anon', p.oid, 'execute')), '14');

do $$ begin raise notice 'return_credit_test: all assertions passed'; end $$;
