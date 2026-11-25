-- Decision 103(g)/(h) + Decision 111 refunds + Decision 26(e) holds. Space d111.
-- Covers: the timing table (paid + covered, on-time/late/no-show), the covered
-- marker and the readers that must treat it as paid, the stale-hold clear, the
-- studio and Xendit refund paths, the spent-credit refusal, role guards, the
-- roster hold + release, the daily-check belt, anon FIFTEEN + the inbox table.

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'BAD  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'BAD  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if; end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin if actual then raise notice 'PASS  %  (got true)', label;
  else raise exception 'BAD  %  expected true, got %', label, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_false(label text, actual boolean)
returns void language plpgsql as $$
begin if not coalesce(actual, true) then raise notice 'PASS  %  (got false)', label;
  else raise exception 'BAD  %  expected false, got %', label, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_raise(label text, want_sqlstate text, stmt text)
returns void language plpgsql as $$
begin begin execute stmt; raise exception 'BAD  %  expected %, no raise', label, want_sqlstate;
  exception when others then
    if sqlstate = want_sqlstate then raise notice 'PASS  %  (got %)', label, sqlstate;
    else raise exception 'BAD  %  expected %, got %', label, want_sqlstate, sqlstate; end if; end; end $$;

-- helper: act as a given auth user
create or replace function d111_as(p_user uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub',p_user::text,'role','authenticated')::text, true); end $$;

do $fix$
declare
  s uuid := 'd1110000-0000-0000-0000-000000000001';
  loc uuid := 'd1110000-0000-0000-0000-0000000000b1';
  ct uuid := 'd1110000-0000-0000-0000-0000000000c7';
  o_far uuid := 'd1110000-0000-0000-0000-00000000000f';  -- >12h out (on-time cancels)
  o_near uuid := 'd1110000-0000-0000-0000-00000000000e'; -- <12h out (late cancels)
  mgr uuid := 'd1110000-0000-0000-0000-0000000000e1'; mgru uuid := 'd1110000-0000-0000-0000-0000000000e2';
  fd uuid := 'd1110000-0000-0000-0000-0000000000e3'; fdu uuid := 'd1110000-0000-0000-0000-0000000000e4';
  insu uuid := 'd1110000-0000-0000-0000-0000000000e5'; insuu uuid := 'd1110000-0000-0000-0000-0000000000e6';
  tok text := 'd111-token';
begin
  insert into studios (id, slug, name, timezone, currency, country) values (s,'d111-studio','D111','Asia/Manila','PHP','PH');
  insert into studio_settings (studio_id, free_first_class_enabled, free_first_reservation_fee_cents,
         free_first_reservation_from, cancellation_cutoff_minutes, dropin_payment_window_minutes)
    values (s, true, 50000, current_date - 30, 720, 15);
  insert into locations (id, studio_id, name, timezone) values (loc, s, 'Main', 'Asia/Manila');
  insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values (ct, s, 'Reformer', 50, 20);
  insert into class_occurrences (id, studio_id, location_id, class_type_id, name, starts_at, ends_at, capacity, status) values
    (o_far,  s, loc, ct, 'Reformer', now()+interval '3 days', now()+interval '3 days'+interval '50 min', 20, 'scheduled'),
    (o_near, s, loc, ct, 'Reformer', now()+interval '2 hours', now()+interval '2 hours'+interval '50 min', 20, 'scheduled');
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at) values
    (mgru,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','d111-mgr@example.com', crypt('x',gen_salt('bf')), now(), now(), now()),
    (fdu, '00000000-0000-0000-0000-000000000000','authenticated','authenticated','d111-fd@example.com',  crypt('x',gen_salt('bf')), now(), now(), now()),
    (insuu,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','d111-ins@example.com', crypt('x',gen_salt('bf')), now(), now(), now());
  insert into profiles (id, email, full_name) values (mgru,'d111-mgr@example.com','Mgr'),(fdu,'d111-fd@example.com','FD'),(insuu,'d111-ins@example.com','Ins');
  insert into studio_staff (id, studio_id, user_id, role, status, email) values
    (mgr, s, mgru, 'manager','active','d111-mgr@example.com'),
    (fd,  s, fdu,  'front_desk','active','d111-fd@example.com'),
    (insu,s, insuu,'instructor','active','d111-ins@example.com');
  insert into studio_payment_providers (studio_id, provider, secret_key_ciphertext, callback_token_ciphertext, callback_token_sha256, test_mode)
    values (s, 'xendit', 'v1.x', 'v1.y', encode(digest(tok,'sha256'),'hex'), true);
end $fix$;

-- a member maker: user + profile + member + optional reservation credit
create or replace function d111_member(p_tag text, p_credit int default 0) returns uuid language plpgsql as $$
declare s uuid := 'd1110000-0000-0000-0000-000000000001'; u uuid := gen_random_uuid(); m uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
    values (u,'00000000-0000-0000-0000-000000000000','authenticated','authenticated', p_tag||'@d111.example.com', crypt('x',gen_salt('bf')), now(), now(), now());
  insert into profiles (id, email, full_name) values (u, p_tag||'@d111.example.com', p_tag);
  insert into members (id, studio_id, user_id, first_name, last_name, email, status) values (m, s, u, p_tag, 'Member', p_tag||'@d111.example.com', 'lead');
  if p_credit > 0 then insert into member_credits (studio_id, member_id, amount_cents, currency, reason) values (s, m, p_credit, 'PHP', 'reservation_credit'); end if;
  return m;
end $$;

-- a PAID reservation seat (comp booking + guest_pass + succeeded reservation_fee payment)
create or replace function d111_paid_seat(p_member uuid, p_occ uuid, p_ref text default null) returns uuid language plpgsql as $$
declare s uuid := 'd1110000-0000-0000-0000-000000000001'; bk uuid := gen_random_uuid(); em text;
begin
  select email into em from members where id = p_member;
  insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at)
    values (bk, s, p_occ, p_member, 'booked','member','comp', now());
  insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email, occurrence_id, guest_booking_id, status)
    values (s, null, p_member, em, p_occ, bk, 'confirmed');
  insert into payments (studio_id, member_id, booking_id, kind, amount_cents, currency, status, provider, reference, paid_at)
    values (s, p_member, bk, 'reservation_fee', 50000, 'PHP', 'succeeded', 'xendit', coalesce(p_ref,'py-'||left(bk::text,8)), now());
  return bk;
end $$;

-- ===================== Part 1: the timing table =====================
do $t$
declare s uuid := 'd1110000-0000-0000-0000-000000000001';
        o_far uuid := 'd1110000-0000-0000-0000-00000000000f'; o_near uuid := 'd1110000-0000-0000-0000-00000000000e';
        m uuid; bk uuid;
begin
  -- Row 1: paid on time -> booked, fee held.
  m := d111_member('paid-booked'); bk := d111_paid_seat(m, o_far);
  perform expect_text('1 paid seat booked', (select status::text from bookings where id=bk), 'booked');

  -- Row 2: on-time cancel of a PAID booking -> credit returned, email.
  m := d111_member('paid-oncancel'); bk := d111_paid_seat(m, o_far);
  perform cancel_booking(bk);
  perform expect_num('2 credit returned on paid on-time cancel', reservation_credit_available(s, m), 50000);
  perform expect_num('2 returned email queued', (select count(*) from notifications where template_key='free_reservation_returned' and member_id=m), 1);

  -- Row 3: late cancel of a PAID booking -> fee kept (no credit written), email is the kept wording.
  m := d111_member('paid-late'); bk := d111_paid_seat(m, o_near);
  perform cancel_booking(bk);  -- o_near is 2h out, cutoff 12h -> late
  perform expect_text('3 paid late cancel status', (select status::text from bookings where id=bk), 'late_cancelled');
  perform expect_num('3 fee kept (no credit)', reservation_credit_available(s, m), 0);
  perform expect_num('3 no returned email', (select count(*) from notifications where template_key='free_reservation_returned' and member_id=m), 0);

  -- Row 4: credit-covered booking -> booked, never due.
  m := d111_member('cov-booked', 50000);
  perform d111_as((select user_id from members where id=m));
  perform reserve_free_first(o_far);
  bk := (select id from bookings where member_id=m and reservation_credit_covered);
  perform expect_true('4 covered marker set', (select reservation_credit_covered from bookings where id=bk));
  perform expect_text('4 covered booking booked', (select status::text from bookings where id=bk), 'booked');
  perform d111_as((select user_id from members where id=m));
  perform expect_num('4 covered not in dues', (select count(*) from member_reservation_dues(s)), 0);
  reset role;

  -- Row 5: on-time cancel of a covered booking -> credit returned, email.
  perform cancel_booking(bk);
  perform expect_num('5 credit returned on covered on-time cancel', reservation_credit_available(s, m), 50000);
  perform expect_num('5 returned email', (select count(*) from notifications where template_key='free_reservation_returned' and member_id=m), 1);

  -- Row 6: late cancel of a covered booking -> credit kept, no returned email.
  m := d111_member('cov-late', 50000);
  perform d111_as((select user_id from members where id=m));
  perform reserve_free_first(o_near);
  reset role;
  bk := (select id from bookings where member_id=m and reservation_credit_covered);
  perform cancel_booking(bk);  -- late
  perform expect_text('6 covered late cancel status', (select status::text from bookings where id=bk), 'late_cancelled');
  perform expect_num('6 credit kept (avail 0)', reservation_credit_available(s, m), 0);
  perform expect_num('6 no returned email', (select count(*) from notifications where template_key='free_reservation_returned' and member_id=m), 0);

  -- Row 8 (refund) is covered in Part 2. Row 7 (credit used at checkout) is the
  -- existing consume path, exercised by row 4's booking consuming the credit.
end $t$;

-- ===================== covered marker: readers + hold clear =====================
do $r$
declare s uuid := 'd1110000-0000-0000-0000-000000000001'; o_far uuid := 'd1110000-0000-0000-0000-00000000000f';
        m uuid; bk uuid;
begin
  m := d111_member('cov-reader', 50000);
  perform d111_as((select user_id from members where id=m));
  perform reserve_free_first(o_far);
  reset role;
  bk := (select id from bookings where member_id=m and reservation_credit_covered);
  -- hold cleared on confirm (book_first_free_run)
  perform expect_true('hold cleared on covered confirm', (select hold_until is null and hold_reason is null from bookings where id=bk));
  -- member_reservation_fees shows the covered booking as "covering"
  perform expect_num('covered shows in reservation fees', (select count(*) from member_reservation_fees(m) where state='covering'), 1);
end $r$;

-- ===================== Part 2: Decision 111 refunds =====================
do $ref$
declare s uuid := 'd1110000-0000-0000-0000-000000000001'; o_far uuid := 'd1110000-0000-0000-0000-00000000000f';
        mgru uuid := 'd1110000-0000-0000-0000-0000000000e2'; fdu uuid := 'd1110000-0000-0000-0000-0000000000e4';
        insuu uuid := 'd1110000-0000-0000-0000-0000000000e6'; tok text := 'd111-token';
        m uuid; bk uuid; pid uuid; rf jsonb; wv jsonb;
begin
  -- a paid, attended reservation (credit written, unused) to refund
  m := d111_member('refund-studio'); bk := d111_paid_seat(m, o_far, 'py-studio-1');
  pid := (select id from payments where booking_id=bk);
  perform write_reservation_credit(bk);

  perform d111_as(mgru);
  -- studio refund requires a reference
  perform expect_raise('studio refund no ref -> PT400', 'PT400',
    format('select refund_payment(%L, null, %L, %L, null)', pid, 'x', 'gcash'));
  -- partial studio refund
  rf := refund_payment(pid, 20000, 'x', 'gcash', 'RF-STU-1');
  perform expect_text('studio refund status succeeded', rf->>'status', 'succeeded');
  reset role;
  perform expect_num('partial refunded_cents', (select refunded_cents from payments where id=pid), 20000);
  perform expect_text('partial status partially_refunded', (select status::text from payments where id=pid), 'partially_refunded');
  perform expect_num('payment_refunded email', (select count(*) from notifications where template_key='payment_refunded' and member_id=m), 1);
  perform expect_num('payment.refunded audit', (select count(*) from audit_logs where action='payment.refunded' and entity_id=pid), 1);
  perform expect_num('sales_refunds lists it', (select count(*) from sales_refunds(s, current_date-1, current_date+1)), 1);
  -- full refund the rest removes the unused credit
  perform d111_as(mgru);
  rf := refund_payment(pid, null, 'x', 'gcash', 'RF-STU-2');
  reset role;
  perform expect_text('full refund status refunded', (select status::text from payments where id=pid), 'refunded');
  perform expect_true('credit voided on full refund', (select voided_at is not null from member_credits where payment_id=pid));

  -- Xendit refund path: pending then settled by the webhook
  m := d111_member('refund-xen'); bk := d111_paid_seat(m, o_far, 'py-xen-1');
  pid := (select id from payments where booking_id=bk);
  perform write_reservation_credit(bk);
  perform d111_as(mgru);
  rf := refund_payment(pid, null, 'x', 'xendit', 'rfd-xen-1');
  reset role;
  perform expect_text('xendit refund pending', rf->>'status', 'pending');
  perform expect_num('xendit pre-settle not applied', (select refunded_cents from payments where id=pid), 0);
  perform expect_text('refund row pending', (select status from payment_refunds where xendit_refund_id='rfd-xen-1'), 'pending');
  wv := xendit_webhook(jsonb_build_object('event','refund.succeeded','api_version','v3',
          'data', jsonb_build_object('refund_id','rfd-xen-1','payment_id','py-xen-1','status','SUCCEEDED','amount',500,'currency','PHP')), tok);
  perform expect_text('webhook processed refund', wv->>'result', 'processed');
  perform expect_text('refund row succeeded', (select status from payment_refunds where xendit_refund_id='rfd-xen-1'), 'succeeded');
  perform expect_num('xendit settled applied', (select refunded_cents from payments where id=pid), 50000);
  perform expect_num('xendit refund email', (select count(*) from notifications where template_key='payment_refunded' and member_id=m), 1);

  -- Xendit refund REJECTED (refund.failed) leaves the payment untouched
  m := d111_member('refund-fail'); bk := d111_paid_seat(m, o_far, 'py-fail-1');
  pid := (select id from payments where booking_id=bk);
  perform d111_as(mgru);
  rf := refund_payment(pid, null, 'x', 'xendit', 'rfd-fail-1');
  reset role;
  wv := xendit_webhook(jsonb_build_object('event','refund.failed','api_version','v3',
          'data', jsonb_build_object('refund_id','rfd-fail-1','payment_id','py-fail-1','status','FAILED','failure_code','INSUFFICIENT_BALANCE')), tok);
  perform expect_text('refund failed row', (select status from payment_refunds where xendit_refund_id='rfd-fail-1'), 'failed');
  perform expect_num('failed refund leaves payment untouched', (select refunded_cents from payments where id=pid), 0);

  -- spent-credit refusal
  m := d111_member('refund-spent'); bk := d111_paid_seat(m, o_far, 'py-spent-1');
  pid := (select id from payments where booking_id=bk);
  insert into member_credits (studio_id, member_id, amount_cents, used_cents, currency, reason, payment_id, booking_id)
    values (s, m, 50000, 50000, 'PHP', 'reservation_credit', pid, bk);
  perform d111_as(mgru);
  perform expect_raise('spent credit refund -> PT409', 'PT409',
    format('select refund_payment(%L, null, %L, %L, %L)', pid, 'x', 'gcash', 'R'));
  -- front desk + instructor cannot refund
  m := d111_member('refund-role'); bk := d111_paid_seat(m, o_far, 'py-role-1');
  pid := (select id from payments where booking_id=bk);
  perform d111_as(fdu);
  perform expect_raise('front desk refund -> PT403', 'PT403',
    format('select refund_payment(%L, 1000, %L, %L, %L)', pid, 'x', 'gcash', 'R'));
  perform d111_as(insuu);
  perform expect_raise('instructor refund -> PT403', 'PT403',
    format('select refund_payment(%L, 1000, %L, %L, %L)', pid, 'x', 'gcash', 'R'));
  reset role;
end $ref$;

-- ===================== Part 3: Decision 26(e) holds =====================
do $h$
declare s uuid := 'd1110000-0000-0000-0000-000000000001'; o_far uuid := 'd1110000-0000-0000-0000-00000000000f';
        fdu uuid := 'd1110000-0000-0000-0000-0000000000e4'; insuu uuid := 'd1110000-0000-0000-0000-0000000000e6';
        m uuid; hold uuid;
begin
  -- a payment hold (pending_payment comp seat with hold_until)
  m := d111_member('hold-release');
  hold := gen_random_uuid();
  insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at, hold_until, hold_reason)
    values (hold, s, o_far, m, 'pending_payment','member','comp', now(), now()+interval '20 min', 'reservation');
  -- instructor cannot release
  perform d111_as(insuu);
  perform expect_raise('instructor release -> PT403', 'PT403', format('select release_hold(%L)', hold));
  -- front desk releases
  perform d111_as(fdu);
  perform expect_true('desk release ok', (release_hold(hold) ->> 'ok')::boolean);
  reset role;
  perform expect_text('hold released -> cancelled', (select status::text from bookings where id=hold), 'cancelled');
  perform expect_num('release notice queued', (select count(*) from notifications where template_key='hold_released_by_studio' and member_id=m), 1);
  -- releasing a non-hold (an ordinary booked seat) is refused PT409
  declare m2 uuid := d111_member('not-a-hold'); nb uuid := gen_random_uuid();
  begin
    insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at)
      values (nb, s, o_far, m2, 'booked','member','drop_in', now());
    perform d111_as(fdu);
    perform expect_raise('release a non-hold -> PT409', 'PT409', format('select release_hold(%L)', nb));
    reset role;
  end;
end $h$;

-- ===================== Part 4: daily-check belt + surface =====================
do $d$
declare s uuid := 'd1110000-0000-0000-0000-000000000001'; o_far uuid := 'd1110000-0000-0000-0000-00000000000f';
        m uuid; bk uuid; chk jsonb; v_anon int; v_tbl int;
begin
  -- a credit-covered booking whose marker is missing + owing shape -> belt fires
  m := d111_member('belt'); bk := gen_random_uuid();
  insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at, reservation_credit_covered)
    values (bk, s, o_far, m, 'booked','member','comp', now(), false);
  insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email, occurrence_id, guest_booking_id, status)
    values (s, null, m, 'belt@d111.example.com', o_far, bk, 'confirmed');
  insert into audit_logs (studio_id, action, entity_table, entity_id, after)
    values (s, 'reservation.credit_used', 'bookings', bk, jsonb_build_object('fee_cents', 50000));
  chk := daily_money_check(s);
  perform expect_true('daily check flags covered-due belt',
    exists (select 1 from jsonb_array_elements_text(chk->'items') x where x like '%covered booking%reported as owing%'));

  -- anon surface EXACTLY FIFTEEN, resend_webhook_inbox table anon-insert-yes/select-no
  select count(*) into v_anon from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not like 'expect_%' and p.proname not like 'd111\_%';
  perform expect_num('anon surface is fifteen', v_anon, 15);
  perform expect_true('inbox anon insert', has_table_privilege('anon','public.resend_webhook_inbox','insert'));
  perform expect_false('inbox anon select', has_table_privilege('anon','public.resend_webhook_inbox','select'));
  perform expect_false('payment_refunds anon select', has_table_privilege('anon','public.payment_refunds','select'));
end $d$;

-- cleanup helpers
drop function d111_as(uuid); drop function d111_member(text,int); drop function d111_paid_seat(uuid,uuid,text);
drop function expect_num(text,bigint,bigint); drop function expect_text(text,text,text);
drop function expect_true(text,boolean); drop function expect_false(text,boolean); drop function expect_raise(text,text,text);
