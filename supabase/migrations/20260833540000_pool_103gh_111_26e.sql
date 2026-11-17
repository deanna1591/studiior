-- ===========================================================================
-- Decision 103(g)/(h) hotfix + Decision 111 refunds + Decision 26(e) holds.
-- creates: return_reservation_credit(uuid), queue_reservation_returned_email(uuid), release_hold(uuid),
--          apply_payment_refund(uuid), refund_payment(uuid, int, text, text, text),
--          settle_payment_refund(text, text, text), sales_refunds(uuid, date, date),
--          xendit_refund_context(uuid)
-- re-issues: tg_reservation_credit(), book_first_free_run(uuid),
--          reserve_free_first(uuid), member_reservation_dues(uuid),
--          sweep_free_reservation_dues(timestamptz), member_reservation_fees(uuid),
--          sales_totals(uuid, date, date, uuid, text), xendit_webhook(jsonb, text),
--          daily_money_check(uuid)
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- New pieces: the covered marker, payment_refunds, templates, backfills,
-- return_reservation_credit, tg_reservation_credit, release_hold.
-- Honest narrowing: member_activity and member_pending_bookings are NOT
-- re-issued. The behaviour lives in the triggers and readers; the existing
-- member_activity arms already render a returned reservation credit as
-- "Fee credited back" and a reservation refund as "Refund - Reservation fee",
-- so re-issuing a 410-line money-path reader byte-for-byte would add
-- transcription risk for cosmetic Journey wording only.
-- ---------------------------------------------------------------------------

-- ---- 1. the covered marker (Decision 103(h)) -------------------------------
alter table bookings
  add column if not exists reservation_credit_covered boolean not null default false;

-- ---- 2. payment_refunds (Decision 111) -------------------------------------
create table if not exists payment_refunds (
  id             uuid primary key default gen_random_uuid(),
  studio_id      uuid not null references studios on delete cascade,
  payment_id     uuid not null references payments on delete cascade,
  member_id      uuid references members on delete set null,
  amount_cents   int  not null check (amount_cents > 0),
  currency       char(3) not null,
  reason         text,
  method         text not null check (method in ('xendit','cash','bank_transfer','card_terminal','gcash','other')),
  reference      text,
  status         text not null default 'pending' check (status in ('pending','succeeded','failed')),
  xendit_refund_id text,
  failure_code   text,
  note           text,
  refunded_by    uuid references auth.users(id),
  created_at     timestamptz not null default now(),
  settled_at     timestamptz,
  is_demo        boolean not null default false
);
create index if not exists payment_refunds_payment_idx on payment_refunds (payment_id);
create index if not exists payment_refunds_studio_idx  on payment_refunds (studio_id, created_at desc);
alter table payment_refunds enable row level security;
drop policy if exists payment_refunds_manager_read on payment_refunds;
create policy payment_refunds_manager_read on payment_refunds
  for select to authenticated using (coalesce(is_manager_up(studio_id), false));
grant select on payment_refunds to authenticated, service_role;
grant insert, update on payment_refunds to service_role;

-- ---- 3. templates (platform defaults, on-conflict-do-nothing) ---------------
-- free_reservation_returned (Decision 103(g)): the credit-returned email.
insert into notification_templates (key, subject, text_body, html_body) values
('free_reservation_returned',
 'Your {fee} is back on your account',
 E'Hi {first_name},\n\nYour {fee} is back on your account. Book your free class and it covers the reservation.\n\n{book_url}\n\n{studio_name}',
 '<p>Hi {first_name},</p><p>Your {fee} is back on your account. Book your free class and it covers the reservation.</p><p><a href="{book_url}">Book a class</a></p><p>{studio_name}</p>')
on conflict (key) do nothing;

-- payment_refunded (Decision 111): the refund email.
insert into notification_templates (key, subject, text_body, html_body) values
('payment_refunded',
 'Your {amount} refund is on its way',
 E'Hi {first_name},\n\nYour {amount} refund is on its way back to you by {method}. Card and GCash refunds can take a few days to show. Reference: {reference}\n\n{studio_name}',
 '<p>Hi {first_name},</p><p>Your {amount} refund is on its way back to you by {method}. Card and GCash refunds can take a few days to show. Reference: {reference}</p><p>{studio_name}</p>')
on conflict (key) do nothing;

-- hold_released_by_studio (Decision 26(e)): the member notice when staff release.
insert into notification_templates (key, subject, text_body, html_body) values
('hold_released_by_studio',
 'Your hold on {class_name} was released',
 E'Hi {first_name},\n\nYour hold on {class_name} was released by the studio.\n\n{studio_name}',
 '<p>Hi {first_name},</p><p>Your hold on {class_name} was released by the studio.</p><p>{studio_name}</p>')
on conflict (key) do nothing;

-- Reform overrides (RPC Studio voice), stored in notification_templates_overrides.
-- body is the composer markup (the five lines); body_html is its rendered form.
do $reform$
declare v_studio uuid;
begin
  select id into v_studio from studios where slug = 'reformcollective';
  if v_studio is null then return; end if;

  insert into notification_templates_overrides (studio_id, key, subject, body, body_html, updated_by)
  values (v_studio, 'free_reservation_returned', 'Your {fee} is back on your account',
    E'Hi {first_name},\n\nYour {fee} is back on your account. Book your free class and it covers the reservation.\n\n[Book a class]({book_url})\n\nSee you at the reformer!🎀\n\nRPC Studio',
    '<p>Hi {first_name},</p><p>Your {fee} is back on your account. Book your free class and it covers the reservation.</p><p><a href="{book_url}">Book a class</a></p><p>See you at the reformer!🎀</p><p>RPC Studio</p>',
    null)
  on conflict (studio_id, key) do nothing;

  insert into notification_templates_overrides (studio_id, key, subject, body, body_html, updated_by)
  values (v_studio, 'payment_refunded', 'Your {amount} refund is on its way',
    E'Hi {first_name},\n\nYour {amount} refund is on its way back to you by {method}. Card and GCash refunds can take a few days to show. Reference: {reference}\n\nSee you at the reformer!🎀\n\nRPC Studio',
    '<p>Hi {first_name},</p><p>Your {amount} refund is on its way back to you by {method}. Card and GCash refunds can take a few days to show. Reference: {reference}</p><p>See you at the reformer!🎀</p><p>RPC Studio</p>',
    null)
  on conflict (studio_id, key) do nothing;
end $reform$;

-- ---- 4. backfills ----------------------------------------------------------
-- 4a. the covered marker from the reservation.credit_used audit rows.
update bookings b
   set reservation_credit_covered = true
 where not b.reservation_credit_covered
   and exists (select 1 from audit_logs a
                where a.action = 'reservation.credit_used'
                  and a.entity_table = 'bookings' and a.entity_id = b.id);

-- 4b. clear the stale hold fields on confirmed (paid) reservation seats. A
-- booked comp seat carrying hold_until is a paid/confirmed reservation whose
-- hold outlived its 30-minute window (book_first_free_run did not clear it); it
-- is not a live hold. A pending_payment hold keeps its hold_until.
update bookings
   set hold_until = null, hold_reason = null
 where status = 'booked' and hold_reason = 'reservation' and hold_until is not null;

-- ---- 5. return_reservation_credit (Decision 103(g)) ------------------------
-- An on-time cancel of a credit-covered booking returns the consumed credit in
-- full, exactly as a paid fee is. Idempotent: gated on no existing return row
-- for this booking. Writes a member_credits row of the fee (so it counts toward
-- reservation_credit_available) and queues free_reservation_returned once.
create or replace function return_reservation_credit(p_booking_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype; v_fee int; v_ccy char(3);
begin
  select * into b from bookings where id = p_booking_id;
  if not found or not coalesce(b.reservation_credit_covered, false) then return; end if;
  -- Already returned?
  if exists (select 1 from member_credits
              where booking_id = p_booking_id and reason = 'reservation_credit'
                and voided_at is null) then
    return;
  end if;
  v_fee := coalesce(
    (select (a.after ->> 'fee_cents')::int from audit_logs a
      where a.action = 'reservation.credit_used' and a.entity_table = 'bookings'
        and a.entity_id = p_booking_id order by a.created_at desc limit 1),
    (select free_first_reservation_fee_cents from studio_settings where studio_id = b.studio_id));
  if coalesce(v_fee, 0) <= 0 then return; end if;
  select currency into v_ccy from studios where id = b.studio_id;

  insert into member_credits (studio_id, member_id, amount_cents, currency, reason, booking_id)
  values (b.studio_id, b.member_id, v_fee, v_ccy, 'reservation_credit', p_booking_id);

  perform queue_notification(b.studio_id, b.member_id, 'free_reservation_returned',
    jsonb_build_object(
      'fee', fmt_money(v_fee, v_ccy),
      'book_url', member_portal_url(b.studio_id, '/book')),
    'free_reservation_returned:' || p_booking_id);
end $$;
revoke execute on function return_reservation_credit(uuid) from public, anon, authenticated;
grant  execute on function return_reservation_credit(uuid) to service_role;

-- queue_reservation_returned_email: the returned-credit email for a PAID
-- reservation fee on an on-time cancel (the covered path has its own in
-- return_reservation_credit). Service only; idempotent per booking.
create or replace function queue_reservation_returned_email(p_booking_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype; pay payments%rowtype;
begin
  select * into b from bookings where id = p_booking_id;
  if not found then return; end if;
  select * into pay from payments where booking_id = p_booking_id and kind = 'reservation_fee'
     and status in ('succeeded','partially_refunded') order by created_at limit 1;
  if not found then return; end if;
  perform queue_notification(b.studio_id, b.member_id, 'free_reservation_returned',
    jsonb_build_object(
      'fee', fmt_money(pay.amount_cents - coalesce(pay.refunded_cents, 0), pay.currency),
      'book_url', member_portal_url(b.studio_id, '/book')),
    'free_reservation_returned:' || p_booking_id);
end $$;
revoke execute on function queue_reservation_returned_email(uuid) from public, anon, authenticated;
grant  execute on function queue_reservation_returned_email(uuid) to service_role;

-- ---- 6. tg_reservation_credit re-issued (Decision 103(g)) -------------------
-- Paid booking: existing behaviour (credit written on attended or on-time cancel
-- when a reservation_fee payment exists). Covered booking: an on-time cancel
-- (status 'cancelled') returns the consumed credit; a late cancel / no-show
-- (status 'late_cancelled' / 'no_show') never fires this trigger, so the credit
-- is kept, exactly as a paid fee is.
create or replace function tg_reservation_credit()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.status is distinct from new.status then
    if new.status = 'attended'
       and exists (select 1 from payments p
                    where p.booking_id = new.id and p.kind = 'reservation_fee'
                      and p.status in ('succeeded', 'partially_refunded')) then
      perform write_reservation_credit(new.id);
    elsif new.status = 'cancelled'
       and exists (select 1 from payments p
                    where p.booking_id = new.id and p.kind = 'reservation_fee'
                      and p.status in ('succeeded', 'partially_refunded')) then
      -- On-time cancel of a PAID reservation: write the credit and email the
      -- member the returned-credit notice (write_reservation_credit emails only
      -- on a check-in, so the returned email is queued here).
      perform write_reservation_credit(new.id);
      perform queue_reservation_returned_email(new.id);
    elsif new.status = 'cancelled' and coalesce(new.reservation_credit_covered, false) then
      perform return_reservation_credit(new.id);
    end if;
  end if;
  return new;
end $$;
revoke execute on function tg_reservation_credit() from public, anon, authenticated;
grant  execute on function tg_reservation_credit() to service_role;
drop trigger if exists tg_reservation_credit on bookings;
create trigger tg_reservation_credit
  after update of status on bookings
  for each row execute function tg_reservation_credit();

-- ---- 7. release_hold (Decision 26(e)) --------------------------------------
-- A desk-up staff frees a payment hold (a pending_payment comp seat) at once and
-- tells the member. Cancels through the existing path (seat freed, no free class
-- used, no infraction). Audited.
create or replace function release_hold(p_booking_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype; v_cls text; v_res cancel_result;
begin
  select * into b from bookings where id = p_booking_id;
  if not found then raise exception 'no such booking' using errcode = 'PT404'; end if;
  if not coalesce(is_desk_up(b.studio_id), false) then
    raise exception 'only the front desk and up release a hold' using errcode = 'PT403';
  end if;
  if not (b.status = 'pending_payment' and b.payment_source = 'comp') then
    raise exception 'that is not a payment hold' using errcode = 'PT409';
  end if;
  select coalesce(o.name, ct.name, 'your class') into v_cls
    from class_occurrences o left join class_types ct on ct.id = o.class_type_id
   where o.id = b.occurrence_id;

  -- free_cancel_until so the cancel is never a late cancel; the seat frees, no
  -- free class is used (a cancelled comp seat stays free-first eligible).
  update bookings set free_cancel_until = now() + interval '1 hour' where id = p_booking_id;
  v_res := cancel_booking(p_booking_id);

  update payments set status = 'failed', failure_code = 'hold_released',
         failure_message = 'The studio released the hold.', updated_at = now()
   where booking_id = p_booking_id and status = 'pending';
  update xendit_purchases set status = 'expired', failure_reason = 'hold_released', updated_at = now()
   where booking_id = p_booking_id and status = 'pending';

  perform queue_notification(b.studio_id, b.member_id, 'hold_released_by_studio',
    jsonb_build_object('class_name', v_cls), 'hold_released_by_studio:' || p_booking_id);

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (b.studio_id, auth.uid(), 'reservation.hold_released_by_staff', 'bookings', p_booking_id,
          jsonb_build_object('class', v_cls));
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function release_hold(uuid) from public, anon;
grant  execute on function release_hold(uuid) to authenticated, service_role;

-- ---- reserve_free_first re-issued (sets the covered marker) ----
create or replace function reserve_free_first(p_occurrence_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare
  v_occ class_occurrences%rowtype; v_member members%rowtype; v_set studio_settings%rowtype;
  v_ser class_series%rowtype; v_cfg_tier guarantee_tier; v_elig jsonb; v_free int; v_booking uuid;
  v_credit int;
begin
  select * into v_occ from class_occurrences where id = p_occurrence_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;

  select * into v_member from members where studio_id = v_occ.studio_id and user_id = auth.uid();
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_authorised'); end if;

  -- Decision 103a: a waived member never needs the fee path; the app routes them
  -- to the ordinary free book, and this is the belt if reached directly.
  if v_member.reservation_fee_waived_at is not null then
    return jsonb_build_object('ok', false, 'reason', 'fee_waived');
  end if;

  select * into v_set from studio_settings where studio_id = v_occ.studio_id;
  if coalesce(v_set.free_first_reservation_fee_cents, 0) <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_reservation_fee');
  end if;

  v_elig := free_first_eligibility(v_occ.studio_id, v_member.id);
  if not (v_elig ->> 'ok')::boolean then return v_elig; end if;

  if v_occ.status <> 'scheduled' then return jsonb_build_object('ok', false, 'reason', 'class_not_bookable'); end if;
  if v_occ.starts_at <= now() then return jsonb_build_object('ok', false, 'reason', 'class_in_past'); end if;
  if not month_published(v_occ.studio_id, v_occ.starts_at) then
    return jsonb_build_object('ok', false, 'reason', 'month_not_published'); end if;
  if studio_hides_unstaffed(v_occ.studio_id) and v_occ.staffing <> 'assigned' then
    return jsonb_build_object('ok', false, 'reason', 'not_staffed_yet'); end if;
  if v_occ.hidden_from_members then
    return jsonb_build_object('ok', false, 'reason', 'class_hidden'); end if;
  if v_occ.starts_at > now() + make_interval(days => coalesce(v_set.booking_window_days, 30)) then
    return jsonb_build_object('ok', false, 'reason', 'outside_booking_window'); end if;
  if v_occ.starts_at < now() + make_interval(mins => coalesce(v_set.booking_cutoff_minutes, 0)) then
    return jsonb_build_object('ok', false, 'reason', 'past_booking_cutoff'); end if;
  if v_occ.free_first_override = 'closed' then
    return jsonb_build_object('ok', false, 'reason', 'free_first_closed_here'); end if;
  if not coalesce(v_set.free_first_peak_allowed, true) and occurrence_is_peak(p_occurrence_id) then
    return jsonb_build_object('ok', false, 'reason', 'peak_not_allowed'); end if;

  if v_occ.series_id is not null then select * into v_ser from class_series where id = v_occ.series_id; end if;
  v_cfg_tier := coalesce(v_occ.guarantee_tier,
                         case when v_occ.flex then 'flex'::guarantee_tier end,
                         v_ser.guarantee_tier,
                         case when v_ser.flex then 'flex'::guarantee_tier end,
                         'core'::guarantee_tier);
  if coalesce(v_set.free_first_core_only, false) and v_cfg_tier <> 'core'
     and v_occ.free_first_override is distinct from 'open' then
    return jsonb_build_object('ok', false, 'reason', 'flex_not_allowed'); end if;
  if v_occ.series_id is not null and not coalesce(v_ser.free_first_allowed, true)
     and v_occ.free_first_override is distinct from 'open' then
    return jsonb_build_object('ok', false, 'reason', 'not_trial_class'); end if;
  if v_set.free_first_seats_per_class is not null
     and (select count(*) from bookings b
           where b.occurrence_id = p_occurrence_id and b.status = 'booked'
             and b.payment_source = 'comp'
             and exists (select 1 from guest_passes gp
                          where gp.guest_booking_id = b.id and gp.host_member_id is null))
         >= v_set.free_first_seats_per_class then
    return jsonb_build_object('ok', false, 'reason', 'free_seats_full'); end if;

  v_free := v_occ.capacity - occurrence_seats_taken(p_occurrence_id) - occurrence_seats_held(p_occurrence_id);
  if v_free < 1 then return jsonb_build_object('ok', false, 'reason', 'class_full'); end if;

  -- Hold the seat: a comp booking in pending_payment, no guest_passes yet. The
  -- AFTER-INSERT notification trigger sends nothing (status <> 'booked'), and the
  -- existing sweep_unpaid_dropins (status='pending_payment' and hold_until is null)
  -- frees it if the member abandons Xendit.
  -- Decision 103(e): reservation credit of at least the fee covers it directly,
  -- with no Xendit page. Book the free class now and consume the credit; the audit
  -- row drives the "Credit used for a reservation" Journey line and the app's
  -- confirmation. This is how a kept credit (on-time cancel, lost seat, refund) is
  -- spent on the next free class.
  v_credit := reservation_credit_available(v_occ.studio_id, v_member.id);
  if v_credit >= v_set.free_first_reservation_fee_cents then
    insert into bookings (studio_id, occurrence_id, member_id, status, source,
                          payment_source, provisional, confirmed_at, booked_at,
                          reservation_credit_covered)
    values (v_occ.studio_id, p_occurrence_id, v_member.id, 'pending_payment', 'member', 'comp',
            false, null, now(), true)
    returning id into v_booking;
    update class_occurrences set booked_count = booked_count + 1 where id = p_occurrence_id;
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (v_occ.studio_id, auth.uid(), 'reservation.credit_used', 'bookings', v_booking,
            jsonb_build_object('fee_cents', v_set.free_first_reservation_fee_cents));
    perform consume_reservation_credit(v_occ.studio_id, v_member.id,
                                       v_set.free_first_reservation_fee_cents);
    perform book_first_free_run(v_booking);
    return jsonb_build_object('ok', true, 'booking_id', v_booking, 'credit_covered', true,
      'fee_cents', v_set.free_first_reservation_fee_cents);
  end if;

  insert into bookings (studio_id, occurrence_id, member_id, status, source,
                        payment_source, provisional, confirmed_at, booked_at)
  values (v_occ.studio_id, p_occurrence_id, v_member.id, 'pending_payment', 'member', 'comp',
          false, null, now())
  returning id into v_booking;
  update class_occurrences set booked_count = booked_count + 1 where id = p_occurrence_id;

  return jsonb_build_object('ok', true, 'booking_id', v_booking,
    'fee_cents', v_set.free_first_reservation_fee_cents);
end $$;
revoke execute on function reserve_free_first(uuid) from public, anon;
grant  execute on function reserve_free_first(uuid) to authenticated, service_role;

-- ---- book_first_free_run re-issued (clears the hold on confirm) ----
create or replace function book_first_free_run(p_booking_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare
  v_b bookings%rowtype; v_occ class_occurrences%rowtype; v_member members%rowtype;
  v_set studio_settings%rowtype; v_head int; v_cut timestamptz; v_prov boolean; v_pass uuid;
begin
  select * into v_b from bookings where id = p_booking_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if v_b.status = 'booked' and v_b.payment_source = 'comp' then
    return jsonb_build_object('ok', true, 'already', true);
  end if;
  if v_b.status <> 'pending_payment' or v_b.payment_source <> 'comp' then
    return jsonb_build_object('ok', false, 'reason', 'not_a_held_reservation');
  end if;

  select * into v_occ from class_occurrences where id = v_b.occurrence_id;
  select * into v_member from members where id = v_b.member_id;
  select * into v_set from studio_settings where studio_id = v_b.studio_id;

  v_head := occurrence_seats_taken(v_occ.id);
  select cutoff_at into v_cut from occurrence_guarantee_run(v_occ.id);
  v_prov := v_set.free_first_confirm_at is not null and v_cut is not null and v_head < v_set.free_first_confirm_at;

  perform set_config('studiior.free_first', '1', true);

  update bookings
     set status = 'booked', provisional = v_prov,
         confirmed_at = case when v_prov then null else now() end,
         hold_until = null, hold_reason = null  -- Decision 103(h): a confirmed reservation seat clears its hold
   where id = p_booking_id;

  insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email,
                            occurrence_id, guest_booking_id, status, waiver_signed_at)
  values (v_b.studio_id, null, v_member.id, lower(btrim(v_member.email)),
          v_occ.id, p_booking_id,
          case when v_member.waiver_signed_at is not null then 'confirmed' else 'invited' end,
          v_member.waiver_signed_at)
  on conflict (studio_id, normalize_email_key(guest_email)) do update
    set host_member_id   = excluded.host_member_id,
        guest_member_id  = excluded.guest_member_id,
        occurrence_id    = excluded.occurrence_id,
        guest_booking_id = excluded.guest_booking_id,
        status           = excluded.status,
        waiver_signed_at = excluded.waiver_signed_at
  returning id into v_pass;

  perform confirm_provisional_seats_run(v_occ.id);
  return jsonb_build_object('ok', true, 'guest_pass_id', v_pass, 'provisional', v_prov);
end $$;
revoke execute on function book_first_free_run(uuid) from public, anon, authenticated;
grant  execute on function book_first_free_run(uuid) to service_role;

-- ---- member_reservation_dues re-issued (exclude covered) ----
create or replace function member_reservation_dues(p_studio_id uuid)
returns table(occurrence_id uuid, booking_id uuid, class_name text, starts_at timestamptz, fee_cents int)
language sql stable security definer set search_path = public as $$
  select o.id, b.id, o.name, o.starts_at, st.free_first_reservation_fee_cents
    from bookings b
    join members m             on m.id = b.member_id
    join class_occurrences o   on o.id = b.occurrence_id
    join studio_settings st    on st.studio_id = b.studio_id
    join studios s             on s.id = b.studio_id
   where m.user_id = auth.uid() and b.studio_id = p_studio_id
     and m.reservation_fee_waived_at is null
     and not b.reservation_fee_waived
     and b.status = 'booked' and b.payment_source = 'comp'
     and not coalesce(b.reservation_credit_covered, false)  -- Decision 103(h): covered bookings are paid
     and coalesce(st.free_first_reservation_fee_cents, 0) > 0
     and st.free_first_reservation_from is not null
     and (o.starts_at at time zone s.timezone)::date >= st.free_first_reservation_from
     and o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)) > now()
     and exists (select 1 from guest_passes gp
                  where gp.guest_booking_id = b.id and gp.host_member_id is null)
     and not exists (select 1 from payments p
                      where p.booking_id = b.id and p.kind = 'reservation_fee'
                        and p.status in ('succeeded','partially_refunded'))
   order by o.starts_at;
$$;
revoke execute on function member_reservation_dues(uuid) from public, anon;
grant  execute on function member_reservation_dues(uuid) to authenticated, service_role;

-- ---- sweep_free_reservation_dues re-issued (exclude covered) ----
create or replace function sweep_free_reservation_dues(p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record; v_asked int := 0; v_released int := 0; v_tz text; v_s studios%rowtype;
        v_deadline timestamptz; v_day text; v_fmt text; v_res cancel_result;
begin
  if not is_service_context() then
    raise exception 'the reservation-dues sweep runs as the backend, not as a user'
      using errcode = 'PT403';
  end if;

  for r in
    select b.id as booking_id, b.studio_id, b.member_id, o.id as occ_id, o.name as cname,
           o.starts_at, st.cancellation_cutoff_minutes, st.free_first_reservation_fee_cents,
           st.free_first_reservation_from
      from bookings b
      join class_occurrences o   on o.id = b.occurrence_id
      join studio_settings st    on st.studio_id = b.studio_id
      join members mb            on mb.id = b.member_id
     where b.status = 'booked' and b.payment_source = 'comp'
       and not coalesce(b.reservation_credit_covered, false)  -- Decision 103(h): covered bookings are paid
       and mb.reservation_fee_waived_at is null
       and not b.reservation_fee_waived
       and st.free_first_reservation_from is not null
       and coalesce(st.free_first_reservation_fee_cents, 0) > 0
       and exists (select 1 from guest_passes gp
                    where gp.guest_booking_id = b.id and gp.host_member_id is null)
       and not exists (select 1 from payments p
                        where p.booking_id = b.id and p.kind = 'reservation_fee'
                          and p.status in ('succeeded','partially_refunded'))
  loop
    select timezone into v_tz from studios where id = r.studio_id;
    v_fmt := coalesce((select time_format from studio_settings where studio_id = r.studio_id), '24h');
    -- Only classes on/after the applies-from date (studio-local).
    if (r.starts_at at time zone v_tz)::date < r.free_first_reservation_from then
      continue;
    end if;
    v_deadline := r.starts_at - make_interval(mins => coalesce(r.cancellation_cutoff_minutes, 0));
    v_day := to_char(r.starts_at at time zone v_tz, 'FMDay FMDD FMMonth');

    if p_now < v_deadline then
      -- Ask once. The cut-off (deadline) has not passed.
      if queue_notification(r.studio_id, r.member_id, 'free_reservation_due',
            jsonb_build_object(
              'class_name', r.cname, 'day', v_day,
              'time', fmt_clock(r.starts_at, v_tz, v_fmt),
              'fee', fmt_money(r.free_first_reservation_fee_cents,
                               (select currency from studios where id = r.studio_id)),
              'from_date', to_char(r.free_first_reservation_from, 'FMDD Mon'),
              'deadline', fmt_clock(v_deadline, v_tz, v_fmt) || ' on '
                          || to_char(v_deadline at time zone v_tz, 'FMDay FMDD FMMonth'),
              'pay_url', member_portal_url(r.studio_id, '/class/' || r.occ_id),
              'cancel_url', member_portal_url(r.studio_id, '/class/' || r.occ_id)),
            'free_reservation_due:' || r.booking_id) is not null then
        v_asked := v_asked + 1;
      end if;
    else
      -- The cut-off has passed. Release ONLY if we asked (a due email went out)
      -- and it was not paid. Bookings never asked (cut-off already past when the
      -- date was set) are left as they are.
      if exists (select 1 from notifications
                  where dedupe_key = 'free_reservation_due:' || r.booking_id) then
        -- On-time path: set free_cancel_until so cancel_booking does not mark it
        -- a late cancel. The free class stays available (a cancelled comp seat
        -- remains free-first eligible, Decision 30d).
        update bookings set free_cancel_until = p_now + interval '1 hour' where id = r.booking_id;
        v_res := cancel_booking(r.booking_id);
        perform queue_notification(r.studio_id, r.member_id, 'free_reservation_released',
          jsonb_build_object('class_name', r.cname, 'day', v_day,
                             'book_url', member_portal_url(r.studio_id, '/book')),
          'free_reservation_released:' || r.booking_id);
        v_released := v_released + 1;
      end if;
    end if;
  end loop;

  return jsonb_build_object('asked', v_asked, 'released', v_released);
end $$;
revoke execute on function sweep_free_reservation_dues(timestamptz) from public, anon, authenticated;
grant  execute on function sweep_free_reservation_dues(timestamptz) to service_role;

-- member_reservation_fees re-issued (Decision 103(h) + 111): a credit-covered
-- reservation now appears as its own row following the credit to the booking it
-- covers now; a refunded fee carries its method and reference. DROP+recreate for
-- the two new output columns.
drop function if exists member_reservation_fees(uuid);
create function member_reservation_fees(p_member_id uuid)
returns table(payment_id uuid, paid_at timestamptz, fee_cents int, currency text,
              class_name text, occurrence_start timestamptz, state text, state_at timestamptz,
              method text, reference text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare v_studio uuid;
begin
  select studio_id into v_studio from members where id = p_member_id;
  if v_studio is null then raise exception 'no such member' using errcode = 'PT404'; end if;
  if not (coalesce(is_desk_up(v_studio), false) or is_service_context()
          or exists (select 1 from members m where m.id = p_member_id and m.user_id = auth.uid())) then
    raise exception 'that is not your statement' using errcode = 'PT403';
  end if;

  return query
  -- Paid fees (a reservation_fee payment).
  select p.id, p.paid_at, p.amount_cents, p.currency::text,
         coalesce(o.name, 'a class') as class_name, o.starts_at,
         case
           when p.refunded_at is not null or p.status = 'refunded'
                or coalesce(p.refunded_cents, 0) >= p.amount_cents then 'refunded'
           when mc.used_cents >= mc.amount_cents then 'used'
           when mc.id is not null then 'credited'
           when b.status in ('no_show', 'late_cancelled') then 'kept'
           else 'held'
         end as state,
         coalesce(mc.created_at, b.cancelled_at, p.refunded_at) as state_at,
         rf.method, coalesce(rf.xendit_refund_id, rf.reference)
    from payments p
    left join bookings b on b.id = p.booking_id
    left join class_occurrences o on o.id = b.occurrence_id
    left join lateral (
      select id, amount_cents, used_cents, created_at
        from member_credits mc2
       where mc2.payment_id = p.id and mc2.voided_at is null
         and mc2.reason in ('reservation_credit', 'reservation_lost_seat')
       order by created_at limit 1) mc on true
    left join lateral (
      select method, reference, xendit_refund_id
        from payment_refunds pr
       where pr.payment_id = p.id and pr.status = 'succeeded'
       order by settled_at desc nulls last, created_at desc limit 1) rf on true
   where p.member_id = p_member_id and p.kind = 'reservation_fee'
     and coalesce(p.method, '') <> 'reservation_credit'

  union all
  -- Decision 103(h): a credit-covered reservation (no payment). State follows the
  -- booking it covers now: covering (booked), used (attended), returned (on-time
  -- cancel, credit back), kept (late cancel / no-show, credit kept).
  select null::uuid, b.booked_at,
         coalesce((a.after ->> 'fee_cents')::int,
                  (select free_first_reservation_fee_cents from studio_settings where studio_id = b.studio_id)),
         (select currency from studios where id = b.studio_id)::text,
         coalesce(o.name, 'a class'), o.starts_at,
         case
           when b.status = 'attended' then 'used'
           when b.status = 'cancelled' then 'returned'
           when b.status in ('no_show', 'late_cancelled') then 'kept'
           else 'covering'
         end,
         coalesce(b.cancelled_at, b.booked_at),
         null::text, null::text
    from bookings b
    left join class_occurrences o on o.id = b.occurrence_id
    left join lateral (
      select after from audit_logs a2
       where a2.action = 'reservation.credit_used' and a2.entity_table = 'bookings'
         and a2.entity_id = b.id order by a2.created_at desc limit 1) a on true
   where b.member_id = p_member_id and coalesce(b.reservation_credit_covered, false)

   order by paid_at desc nulls last;
end $$;
revoke execute on function member_reservation_fees(uuid) from public, anon;
grant  execute on function member_reservation_fees(uuid) to authenticated, service_role;

-- ===========================================================================
-- Decision 111: refunds.
-- ===========================================================================

-- apply_payment_refund: the common application of a succeeded refund. Service
-- only (a definer caller runs as the owner, so refund_payment and the webhook
-- both reach it; a client gets 42501). Updates the payment, voids the UNUSED
-- reservation credit the payment produced, cancels a membership on a full refund,
-- and emails the member. Idempotent on the refund row already being applied.
create or replace function apply_payment_refund(p_refund_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare rf payment_refunds%rowtype; pay payments%rowtype; ms memberships%rowtype;
        plan membership_plans%rowtype; v_total int; v_full boolean; v_bal int; v_take int := 0;
begin
  select * into rf from payment_refunds where id = p_refund_id for update;
  if not found then return; end if;
  select * into pay from payments where id = rf.payment_id for update;
  if not found then return; end if;

  v_total := coalesce(pay.refunded_cents, 0) + rf.amount_cents;
  v_full  := v_total >= pay.amount_cents;
  update payments
     set refunded_cents = v_total, refunded_at = now(),
         refund_reason = coalesce(rf.reason, refund_reason),
         status = (case when v_full then 'refunded' else 'partially_refunded' end)::payment_status,
         updated_at = now()
   where id = pay.id;

  -- Decision 103: refunding a reservation fee removes the UNUSED remainder of its
  -- credit (used stays used). refund_payment already refused a spent credit.
  if pay.kind = 'reservation_fee' then
    update member_credits set used_cents = amount_cents, voided_at = now()
     where payment_id = pay.id and voided_at is null;
  end if;

  -- A full refund of a membership payment cancels the membership and claws back
  -- unused pack credits (mirrors record_refund).
  if v_full and pay.membership_id is not null then
    select * into ms from memberships where id = pay.membership_id;
    select * into plan from membership_plans where id = ms.plan_id;
    if plan.type = 'class_pack' then
      select coalesce(sum(delta), 0) into v_bal from credit_ledger
       where studio_id = pay.studio_id and member_id = pay.member_id;
      v_take := least(coalesce(ms.credits_remaining, 0), greatest(v_bal, 0));
      if v_take > 0 then
        insert into credit_ledger (studio_id, member_id, membership_id, delta, reason, balance_after, actor_user_id)
        values (pay.studio_id, pay.member_id, ms.id, -v_take, 'manual', v_bal - v_take, rf.refunded_by);
        update memberships set credits_remaining = coalesce(credits_remaining, 0) - v_take where id = ms.id;
      end if;
    end if;
    update memberships set status = 'cancelled', cancelled_at = now(),
           cancellation_reason = coalesce(rf.reason, 'refunded')
     where id = ms.id and status <> 'cancelled';
  end if;

  perform queue_notification(pay.studio_id, pay.member_id, 'payment_refunded',
    jsonb_build_object(
      'amount', fmt_money(rf.amount_cents, rf.currency),
      'method', case rf.method
                  when 'xendit' then 'card or GCash'
                  when 'card_terminal' then 'card'
                  when 'bank_transfer' then 'bank transfer'
                  when 'gcash' then 'GCash'
                  when 'cash' then 'cash' else 'the studio' end,
      'reference', coalesce(rf.xendit_refund_id, rf.reference, 'n/a')),
    'payment_refunded:' || rf.id);
end $$;
revoke execute on function apply_payment_refund(uuid) from public, anon, authenticated;
grant  execute on function apply_payment_refund(uuid) to service_role;

-- refund_payment: the manager-up entry point. The Xendit path records a pending
-- refund (the server action has already called POST /v3/refunds and passes the
-- rfd- id as p_reference); the studio path records and applies at once, with the
-- reference required. Both refuse a payment whose reservation credit is spent.
create or replace function refund_payment(
  p_payment_id uuid, p_amount_cents int default null, p_reason text default null,
  p_method text default null, p_reference text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pay payments%rowtype; v_amount int; v_remaining int; v_id uuid; v_ccy char(3);
begin
  select * into pay from payments where id = p_payment_id for update;
  if not found then raise exception 'no such payment' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(pay.studio_id), false) then
    raise exception 'refunds are the owner''s or a manager''s to make' using errcode = 'PT403';
  end if;
  if pay.status not in ('succeeded', 'partially_refunded') then
    raise exception 'a % payment cannot be refunded', pay.status using errcode = 'PT409';
  end if;

  -- Decision 111: a reservation fee whose credit has been spent cannot be refunded.
  if pay.kind = 'reservation_fee'
     and exists (select 1 from member_credits mc
                  where mc.payment_id = pay.id and mc.voided_at is null and mc.used_cents > 0) then
    raise exception 'this fee was used as credit, so it cannot be refunded'
      using errcode = 'PT409';
  end if;

  v_remaining := pay.amount_cents - coalesce(pay.refunded_cents, 0);
  v_amount := coalesce(p_amount_cents, v_remaining);
  if v_amount <= 0 or v_amount > v_remaining then
    raise exception 'that is more than is left to refund' using errcode = 'PT400';
  end if;
  v_ccy := pay.currency;

  if coalesce(p_method, '') = 'xendit' then
    -- The server action has already called POST /v3/refunds; p_reference is the
    -- rfd- id. Record pending; the webhook settles it.
    insert into payment_refunds (studio_id, payment_id, member_id, amount_cents, currency,
                                 reason, method, reference, status, xendit_refund_id, refunded_by)
    values (pay.studio_id, pay.id, pay.member_id, v_amount, v_ccy,
            p_reason, 'xendit', p_reference, 'pending', p_reference, auth.uid())
    returning id into v_id;
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (pay.studio_id, auth.uid(), 'payment.refunded', 'payments', pay.id,
            jsonb_build_object('refund_id', v_id, 'amount_cents', v_amount, 'method', 'xendit',
                               'reason', p_reason, 'reference', p_reference, 'status', 'pending'));
    return jsonb_build_object('ok', true, 'refund_id', v_id, 'status', 'pending', 'amount_cents', v_amount);
  else
    -- Studio-recorded: method required and valid, reference required.
    if coalesce(p_method, '') not in ('cash','bank_transfer','card_terminal','gcash','other') then
      raise exception 'unknown refund method' using errcode = 'PT400';
    end if;
    if coalesce(btrim(p_reference), '') = '' then
      raise exception 'a refund reference is required' using errcode = 'PT400';
    end if;
    insert into payment_refunds (studio_id, payment_id, member_id, amount_cents, currency,
                                 reason, method, reference, status, settled_at, refunded_by)
    values (pay.studio_id, pay.id, pay.member_id, v_amount, v_ccy,
            p_reason, p_method, p_reference, 'succeeded', now(), auth.uid())
    returning id into v_id;
    perform apply_payment_refund(v_id);
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (pay.studio_id, auth.uid(), 'payment.refunded', 'payments', pay.id,
            jsonb_build_object('refund_id', v_id, 'amount_cents', v_amount, 'method', p_method,
                               'reason', p_reason, 'reference', p_reference, 'status', 'succeeded'));
    return jsonb_build_object('ok', true, 'refund_id', v_id, 'status', 'succeeded', 'amount_cents', v_amount);
  end if;
end $$;
revoke execute on function refund_payment(uuid, int, text, text, text) from public, anon;
grant  execute on function refund_payment(uuid, int, text, text, text) to authenticated, service_role;

-- settle_payment_refund: the webhook settles a pending Xendit refund. Service only.
create or replace function settle_payment_refund(p_refund_ref text, p_status text, p_failure_code text default null)
returns void language plpgsql security definer set search_path = public as $$
declare rf payment_refunds%rowtype;
begin
  select * into rf from payment_refunds
   where (xendit_refund_id = p_refund_ref or reference = p_refund_ref)
     and status = 'pending'
   order by created_at desc limit 1;
  if not found then return; end if;

  if upper(p_status) = 'SUCCEEDED' then
    update payment_refunds set status = 'succeeded', settled_at = now() where id = rf.id;
    perform apply_payment_refund(rf.id);
  elsif upper(p_status) = 'FAILED' then
    update payment_refunds set status = 'failed', failure_code = p_failure_code, settled_at = now()
     where id = rf.id;
  end if;
end $$;
revoke execute on function settle_payment_refund(text, text, text) from public, anon, authenticated;
grant  execute on function settle_payment_refund(text, text, text) to service_role;

-- xendit_refund_context (Decision 111): a manager's server action decrypts the
-- studio's secret key here to call POST /v3/refunds. The ciphertext is useless
-- without the env key (the member checkout uses the same posture). Manager-up.
create or replace function xendit_refund_context(p_payment_id uuid)
returns table(secret_key_ciphertext text, payment_ref text, amount_cents int,
              currency char(3), is_xendit boolean, remaining_cents int)
language plpgsql security definer set search_path = public as $$
declare pay payments%rowtype; prov studio_payment_providers%rowtype;
begin
  select * into pay from payments where id = p_payment_id;
  if not found then raise exception 'no such payment' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(pay.studio_id), false) then
    raise exception 'refunds are the owner''s or a manager''s to make' using errcode = 'PT403';
  end if;
  select * into prov from studio_payment_providers where studio_id = pay.studio_id and provider = 'xendit';
  return query select prov.secret_key_ciphertext, pay.reference, pay.amount_cents, pay.currency,
                      (pay.provider = 'xendit' and prov.studio_id is not null),
                      pay.amount_cents - coalesce(pay.refunded_cents, 0);
end $$;
revoke execute on function xendit_refund_context(uuid) from public, anon;
grant  execute on function xendit_refund_context(uuid) to authenticated, service_role;

-- ---- sales_totals re-issued (Refunds line) ----
create or replace function sales_totals(
  p_studio_id uuid, p_from date, p_to date,
  p_plan_id uuid default null, p_status text default null
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_currency char(3); v_count int; v_gross bigint; v_refunded bigint; v_studio_total bigint;
  v_f0 timestamptz; v_t1 timestamptz; v_resv_count int; v_resv_total bigint;
  v_ref_count int; v_ref_total bigint;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'sales are for owners and managers' using errcode = 'PT403';
  end if;
  select currency into v_currency from studios s where s.id = p_studio_id;
  select day_start into v_f0 from studio_day_bounds(p_studio_id, p_from);
  select day_start into v_t1 from studio_day_bounds(p_studio_id, p_to + 1);

  select count(*) into v_count
    from sales_history(p_studio_id, p_from, p_to, p_plan_id, p_status);

  -- Gross/refunded over the filtered set: membership sales (by plan filter) OR
  -- merchandise sales. A plan filter excludes merch (merch has no plan).
  select coalesce(sum(p.amount_cents), 0)::bigint,
         coalesce(sum(p.refunded_cents), 0)::bigint
    into v_gross, v_refunded
    from payments p
    left join memberships ms on ms.id = p.membership_id
   where p.studio_id = p_studio_id
     and p.status in ('succeeded', 'partially_refunded')
     and (p.membership_id is not null or p.product_order_id is not null)
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1
     and (p_plan_id is null or ms.plan_id = p_plan_id);

  v_studio_total := studio_revenue_between(p_studio_id, v_f0, v_t1);

  -- Decision 103(e): reservation fees as their own line (cash received; a
  -- credit-covered reservation writes no payment, so method excludes it).
  select count(*), coalesce(sum(p.amount_cents - coalesce(p.refunded_cents, 0)), 0)::bigint
    into v_resv_count, v_resv_total
    from payments p
   where p.studio_id = p_studio_id and p.kind = 'reservation_fee'
     and coalesce(p.method, '') <> 'reservation_credit'
     and p.status in ('succeeded', 'partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1;

  -- Decision 111: refunds settled in the period, as their own line.
  select count(*), coalesce(sum(pr.amount_cents), 0)::bigint
    into v_ref_count, v_ref_total
    from payment_refunds pr
   where pr.studio_id = p_studio_id and pr.status = 'succeeded'
     and coalesce(pr.settled_at, pr.created_at) >= v_f0
     and coalesce(pr.settled_at, pr.created_at) <  v_t1;

  return jsonb_build_object(
    'refunds', jsonb_build_object('count', v_ref_count, 'total_cents', v_ref_total),
    'reservation_fees', jsonb_build_object('count', v_resv_count, 'total_cents', v_resv_total),
    'count', v_count,
    'gross_cents', v_gross,
    'refunded_cents', v_refunded,
    'net_cents', v_gross - v_refunded,
    'studio_total_cents', v_studio_total,
    'currency', v_currency);
end $$;

-- sales_refunds (Decision 111): the per-refund list for the Sales page's Refunds
-- section, settled in the period. Manager-up.
create or replace function sales_refunds(p_studio_id uuid, p_from date, p_to date)
returns table(refund_id uuid, settled_at timestamptz, member_name text, amount_cents int,
              currency text, method text, reference text, reason text, item text, status text)
language plpgsql stable security definer set search_path = public as $$
declare v_f0 timestamptz; v_t1 timestamptz;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'sales are for owners and managers' using errcode = 'PT403';
  end if;
  select day_start into v_f0 from studio_day_bounds(p_studio_id, p_from);
  select day_start into v_t1 from studio_day_bounds(p_studio_id, p_to + 1);
  return query
  select pr.id, coalesce(pr.settled_at, pr.created_at), mname(pr.member_id), pr.amount_cents,
         pr.currency::text, pr.method, coalesce(pr.xendit_refund_id, pr.reference), pr.reason,
         case
           when p.kind = 'reservation_fee' then 'Reservation fee'
           when mp.name is not null then mp.name
           when prod.name is not null then prod.name
           else coalesce(p.description, 'Payment')
         end,
         pr.status
    from payment_refunds pr
    join payments p on p.id = pr.payment_id
    left join memberships ms on ms.id = p.membership_id
    left join membership_plans mp on mp.id = ms.plan_id
    left join product_orders po on po.id = p.product_order_id
    left join products prod on prod.id = po.product_id
   where pr.studio_id = p_studio_id
     and pr.status in ('succeeded', 'pending')
     and coalesce(pr.settled_at, pr.created_at) >= v_f0
     and coalesce(pr.settled_at, pr.created_at) <  v_t1
   order by coalesce(pr.settled_at, pr.created_at) desc;
end $$;
revoke all on function sales_refunds(uuid, date, date) from public, anon;
grant execute on function sales_refunds(uuid, date, date) to authenticated, service_role;

-- ---- xendit_webhook re-issued (refund settlement branch) ----
create or replace function xendit_webhook(p_event jsonb, p_token text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  d jsonb := p_event -> 'data';
  v_event text := p_event ->> 'event';
  v_status text := upper(coalesce(d ->> 'status', ''));
  v_payment_id text := coalesce(nullif(d ->> 'payment_id', ''), nullif(d ->> 'id', ''));
  v_amount numeric := coalesce(
    nullif(d ->> 'amount', ''),
    nullif(d ->> 'request_amount', ''),
    nullif(d -> 'captures' -> 0 ->> 'capture_amount', '')
  )::numeric;
  v_currency text := upper(nullif(d ->> 'currency', ''));
  v_studio uuid;
  v_event_id text; n int; v_success boolean; v_failure boolean;
  v_pid uuid; p xendit_purchases%rowtype; v_prior text;
begin
  -- Token first: a bad token stores NOTHING (PT401).
  if p_token is null then
    raise exception 'bad Xendit callback token' using errcode = 'PT401';
  end if;
  select studio_id into v_studio from studio_payment_providers
   where provider = 'xendit'
     and callback_token_sha256 = encode(digest(p_token, 'sha256'), 'hex')
   limit 1;
  if v_studio is null then
    raise exception 'bad Xendit callback token' using errcode = 'PT401';
  end if;

  v_event_id := coalesce(nullif(v_event, ''), 'event') || ':'
             || coalesce(nullif(v_payment_id, ''), nullif(d ->> 'payment_session_id', ''),
                         nullif(p_event ->> 'id', ''), encode(digest(p_event::text, 'sha256'), 'hex'));

  -- STORE FIRST — the row exists (outer txn) before any processing, so a raise
  -- below cannot erase it. A retry of a FAILED row is reprocessed, not a dup.
  insert into xendit_events (studio_id, event_id, event_type, payload)
  values (v_studio, v_event_id, v_event, p_event)
  on conflict (event_id) do nothing;
  get diagnostics n = row_count;
  if n = 0 then
    select result into v_prior from xendit_events where event_id = v_event_id;
    if v_prior is distinct from 'failed' then
      return jsonb_build_object('result', 'duplicate');
    end if;
    -- a previously-failed row: fall through and reprocess it.
  end if;

  -- Decision 111: a refund event settles a pending payment_refunds row. It links
  -- by data.refund_id (our stored xendit_refund_id), not to an xendit_purchase.
  if v_event in ('refund.succeeded', 'refund.failed') then
    begin
      perform settle_payment_refund(
        coalesce(nullif(d ->> 'refund_id', ''), nullif(d ->> 'reference_id', '')),
        case when v_event = 'refund.succeeded' then 'SUCCEEDED' else 'FAILED' end,
        d ->> 'failure_code');
      update xendit_events set result = 'processed', error = null, processed_at = now() where event_id = v_event_id;
      return jsonb_build_object('result', 'processed', 'outcome', 'refund');
    exception when others then
      update xendit_events set result = 'failed', error = left(coalesce(SQLERRM, ''), 300), processed_at = now()
       where event_id = v_event_id;
      return jsonb_build_object('result', 'failed', 'error_code', SQLSTATE);
    end;
  end if;

  -- PROCESS in a subtransaction. A raise rolls back ONLY the processing (any
  -- partial activation and the purchase_id stamp); the handler then records the
  -- failure on the stored row and returns without re-raising.
  begin
    v_pid := xendit_resolve_purchase(d);
    if v_pid is null then
      update xendit_events set result = 'ignored', error = 'bad_reference', processed_at = now() where event_id = v_event_id;
      return jsonb_build_object('result', 'ignored', 'reason', 'bad_reference');
    end if;
    select * into p from xendit_purchases where id = v_pid;
    if p.studio_id <> v_studio then
      update xendit_events set result = 'ignored', error = 'cross_tenant', processed_at = now() where event_id = v_event_id;
      return jsonb_build_object('result', 'ignored', 'reason', 'cross_tenant');
    end if;
    update xendit_events set purchase_id = p.id where event_id = v_event_id;

    v_success := v_status in ('SUCCEEDED', 'COMPLETED') or v_event in ('payment.succeeded', 'payment.capture');
    v_failure := v_event = 'payment.failure' or v_status in ('FAILED', 'FAILURE', 'VOIDED', 'EXPIRED', 'CANCELED', 'CANCELLED');

    if v_success then
      if v_amount is not null and round(v_amount * 100) <> p.amount_cents then
        update xendit_events set result = 'refused', error = 'amount_mismatch', processed_at = now() where event_id = v_event_id;
        return jsonb_build_object('result', 'refused', 'reason', 'amount_mismatch');
      end if;
      if v_currency is not null and v_currency <> upper(p.currency) then
        update xendit_events set result = 'refused', error = 'currency_mismatch', processed_at = now() where event_id = v_event_id;
        return jsonb_build_object('result', 'refused', 'reason', 'currency_mismatch');
      end if;
      perform xendit_activate_success_internal(p.id, v_payment_id);
      update xendit_events set result = 'processed', error = null, processed_at = now() where event_id = v_event_id;
      return jsonb_build_object('result', 'processed', 'outcome', 'succeeded');

    elsif v_failure then
      perform xendit_fail_purchase_internal(p.id, 'failed', coalesce(d ->> 'failure_code', v_event));
      update xendit_events set result = 'processed', error = null, processed_at = now() where event_id = v_event_id;
      return jsonb_build_object('result', 'processed', 'outcome', 'failed');
    end if;

    update xendit_events set result = 'ignored', error = 'non_terminal', processed_at = now() where event_id = v_event_id;
    return jsonb_build_object('result', 'ignored', 'reason', 'non_terminal');

  exception when others then
    -- The row was inserted in the OUTER txn, so it survives this rollback; record
    -- WHY it failed and return (never re-raise). The route turns this into a 500
    -- so Xendit retries, and the retry reprocesses the stored 'failed' row.
    update xendit_events set result = 'failed', error = left(coalesce(SQLERRM, ''), 300), processed_at = now()
     where event_id = v_event_id;
    return jsonb_build_object('result', 'failed', 'error_code', SQLSTATE);
  end;
end $$;

revoke execute on function xendit_webhook(jsonb, text) from public;
grant  execute on function xendit_webhook(jsonb, text) to anon, authenticated, service_role;

-- ---- daily_money_check re-issued (covered-due belt) ----
create or replace function daily_money_check(p_studio_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_tz text; v_items jsonb := '[]'::jsonb; v_html text := ''; v_text text := '';
  r record; v_n int;
begin
  if not is_service_context() then
    raise exception 'the daily check runs as the backend' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;

  for r in
    -- 1. reservation fee paid, no seat, no credit
    select mname(b.member_id) || ': paid a reservation fee for ' || cname(b.occurrence_id)
           || ' but has no seat and no credit' as line
      from payments p
      join bookings b on b.id = p.booking_id
     where p.studio_id = p_studio_id and p.kind = 'reservation_fee'
       and p.status in ('succeeded','partially_refunded')
       and b.status in ('cancelled','late_cancelled')
       and not exists (select 1 from member_credits mc
                        where mc.booking_id = b.id and mc.reason = 'reservation_credit' and mc.voided_at is null)
    union all
    -- 2. a hold older than its window
    select mname(b.member_id) || ': the hold on ' || cname(b.occurrence_id)
           || ' expired ' || ago(b.hold_until) || ' and is still open'
      from bookings b
     where b.studio_id = p_studio_id and b.hold_until is not null and b.hold_until < now()
       and b.status in ('booked','pending_payment')
    union all
    -- 3. a succeeded payment attached to nothing
    select mname(p.member_id) || ': a succeeded payment of ' || money_txt(p.amount_cents, p.currency)
           || ' is attached to nothing'
      from payments p
     where p.studio_id = p_studio_id and p.status = 'succeeded'
       and p.membership_id is null and p.booking_id is null
       and p.product_order_id is null and p.group_purchase_id is null
    union all
    -- 4. a member with an active plan still marked lead
    select mname(m.id) || ': has an active plan but is still marked lead'
      from members m
     where m.studio_id = p_studio_id and m.status = 'lead' and m.deleted_at is null
       and exists (select 1 from memberships ms where ms.member_id = m.id and ms.status = 'active')
    union all
    -- 5. a live booking in a cancelled or ended class
    select mname(b.member_id) || ': booked in ' || cname(b.occurrence_id)
           || case when o.status = 'cancelled' then ' which was cancelled' else ' which has already ended' end
      from bookings b join class_occurrences o on o.id = b.occurrence_id
     where b.studio_id = p_studio_id and b.status in ('booked','pending_payment')
       and (o.status = 'cancelled' or (o.status = 'scheduled' and o.ends_at < now()))
    union all
    -- 6. a member double-booked in one class
    select mname(x.member_id) || ': booked twice in ' || cname(x.occurrence_id)
      from (select member_id, occurrence_id from bookings
             where studio_id = p_studio_id and status in ('booked','attended','pending_payment')
             group by member_id, occurrence_id having count(*) > 1) x
    union all
    -- 7. a notification unsent for more than an hour
    select (select count(*) from notifications n
             where n.studio_id = p_studio_id and n.status = 'scheduled'
               and n.scheduled_for < now() - interval '1 hour')::text
           || ' emails have been waiting over an hour to send'
     where exists (select 1 from notifications n
                    where n.studio_id = p_studio_id and n.status = 'scheduled'
                      and n.scheduled_for < now() - interval '1 hour')
    union all
    -- 8. an attended booking with no signed waiver
    select mname(b.member_id) || ': attended ' || cname(b.occurrence_id) || ' without signing the waiver'
      from bookings b join members m on m.id = b.member_id
     where b.studio_id = p_studio_id and b.status = 'attended'
       and coalesce((select require_waiver from studio_settings where studio_id = p_studio_id), false)
       and exists (select 1 from waiver_versions wv where wv.studio_id = p_studio_id)
       and m.waiver_signed_at is null
    union all
    -- 9. emails that failed in the last day, with the reason
    select count(*)::text || ' emails failed: ' || coalesce(nullif(btrim(fx.reason), ''), 'no reason given')
      from (select coalesce(split_part(error, ':', 1), 'unknown') as reason
              from notifications
             where studio_id = p_studio_id and status = 'failed'
               and coalesce(failed_at, created_at) > now() - interval '1 day') fx
     group by fx.reason
    union all
    -- 10. Decision 103(h): a credit-covered booking the owing shape would dun
    -- (the covered marker is missing). The belt against a covered booking being
    -- reported as due; member_reservation_dues excludes covered bookings.
    select mname(b.member_id) || ': covered booking ' || cname(b.occurrence_id)
           || ' is reported as owing the fee'
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
      join studio_settings st on st.studio_id = b.studio_id
     where b.studio_id = p_studio_id
       and not coalesce(b.reservation_credit_covered, false)
       and exists (select 1 from audit_logs a where a.action = 'reservation.credit_used'
                    and a.entity_table = 'bookings' and a.entity_id = b.id)
       and b.status = 'booked' and b.payment_source = 'comp'
       and coalesce(st.free_first_reservation_fee_cents, 0) > 0
       and st.free_first_reservation_from is not null
       and o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)) > now()
       and not exists (select 1 from payments p where p.booking_id = b.id
                        and p.kind = 'reservation_fee' and p.status in ('succeeded','partially_refunded'))
  loop
    v_items := v_items || to_jsonb(r.line);
    v_html  := v_html  || '<li>' || replace(replace(r.line, '&', '&amp;'), '<', '&lt;') || '</li>';
    v_text  := v_text  || '- ' || r.line || E'\n';
  end loop;

  v_n := jsonb_array_length(v_items);
  return jsonb_build_object(
    'n', v_n,
    'all_clear', v_n = 0,
    'items', v_items,
    'items_html', case when v_n = 0 then '<p>All clear.</p>' else '<ul>' || v_html || '</ul>' end,
    'items_text', case when v_n = 0 then 'All clear.' else v_text end,
    'count_label', case when v_n = 0 then 'all clear'
                        else v_n::text || ' item' || case when v_n = 1 then '' else 's' end end);
end $function$;

revoke all on function daily_money_check(uuid) from public, anon, authenticated;
grant execute on function daily_money_check(uuid) to service_role;

-- ---- anon surface stays EXACTLY THIRTEEN ----
do $anon$
declare v_n int;
begin
  select count(*) into v_n from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if v_n <> 13 then
    raise exception 'anon surface must be exactly 13, got %', v_n;
  end if;
end $anon$;
