-- The null-guard ownership bug, swept and closed everywhere it remained.
--
-- `if not ( m.user_id = auth.uid() or is_desk_up(...) ) then raise` looks like an
-- ownership check and is NOT one when m.user_id is NULL — every unclaimed guest,
-- lead and imported member. `null = auth.uid()` is NULL, `NULL or false` is NULL
-- (the helpers return false, never null, since migration 020), and `if NULL then
-- raise` is SKIPPED — so any signed-in user could act on such a member's booking
-- at any studio. This is migration 020's lesson (helpers), migration 035's
-- (members_self_update) and migration 129's (sign_waiver), a fourth time.
--
-- Found by sweeping every SECURITY DEFINER function for `if not (...)` guards
-- comparing a nullable column to auth.uid() with a bare `=`. Three remained:
-- cancel_booking, respond_to_offer, choose_pay_at_desk. join_challenge was the
-- one already written the safe way — `exists(select 1 ... where user_id =
-- auth.uid())` returns false, not null, so its raise fires. THE RULE, now in
-- CLAUDE.md: a guard comparing a nullable column to auth.uid() wraps it in
-- exists() or coalesce(..., false); never a bare equality inside `if not (...)`.
--
-- The fix is coalesce(m.user_id = auth.uid(), false) — no behaviour change for a
-- legitimate caller (the member matches, or desk/service does), the hole closes
-- for the null case.

CREATE OR REPLACE FUNCTION public.cancel_booking(p_booking_id uuid)
 RETURNS cancel_result
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  b        bookings%rowtype;
  occ      class_occurrences%rowtype;
  st       studio_settings%rowtype;
  v_member members%rowtype;
  v_late   boolean;
  v_entry  credit_ledger%rowtype;
  v_bal    int;
  v_res    cancel_result;
  v_mins   int;
  v_window int;
  v_next   bookings%rowtype;
begin
  select * into b from bookings where id = p_booking_id;
  if not found then
    raise exception 'no such booking' using errcode = 'PT404';
  end if;

  select * into v_member from members where id = b.member_id for update;

  -- The member themselves, desk-up staff acting for them, or the backend.
  --
  -- The backend case is sweep_unpaid_dropins(), which runs from pg_cron with no
  -- JWT. It comes through here rather than cancelling rows itself so that a
  -- swept seat goes down exactly the same path as any other cancellation —
  -- booked_count decremented, and §4.2 offering the seat to the front of the
  -- waitlist. A freed seat nobody is offered is worse than a held one.
  --
  -- is_service_context() asks Postgres whether the effective role is one it
  -- marks superuser or bypassrls, so it is true for cron and can never be true
  -- for a signed-in member however they arrive (migration 024).
  if not (coalesce(v_member.user_id = auth.uid(), false)
          or is_desk_up(b.studio_id)
          or is_service_context()) then
    raise exception 'that is not your booking' using errcode = 'PT403';
  end if;

  if b.status not in ('booked', 'waitlisted', 'pending_payment') then
    raise exception 'this booking is already %', b.status using errcode = 'PT409';
  end if;

  select * into occ from class_occurrences where id = b.occurrence_id for update;
  select * into st  from studio_settings where studio_id = b.studio_id;

  -- Leaving a waitlist is free and unconditional — §4.1.
  if b.status = 'waitlisted' then
    update bookings set status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid()
     where id = p_booking_id;
    update class_occurrences
       set waitlist_count = greatest(0, waitlist_count - 1)
     where id = occ.id;
    v_res := ('cancelled'::booking_status, false, null, false);
    return v_res;
  end if;

  -- A seat that was only ever held is never a LATE cancellation. Without this
  -- a member who opened Checkout inside the cancellation cutoff and closed the
  -- tab would have the sweep record a late_cancelled against them — a black
  -- mark, and on some studios a fee, for a class they never paid for.
  -- free_cancel_until overrides the cutoff. It is set when the studio moved
  -- the class significantly (migration 050) — the member agreed to a time and
  -- the studio changed it, so charging them for cancelling would be charging
  -- them for the studio's decision.
  v_late := b.status <> 'pending_payment'
            and now() > occ.starts_at - make_interval(mins => st.cancellation_cutoff_minutes)
            and not (b.free_cancel_until is not null and now() <= b.free_cancel_until);

  -- Cast explicitly: a CASE over two string literals is text, and assigning
  -- text to a booking_status column fails at runtime rather than at create
  -- time, so the function looked fine until something cancelled anything.
  update bookings
     set status = (case when v_late then 'late_cancelled' else 'cancelled' end)::booking_status,
         cancelled_at = now(), cancelled_by = auth.uid(),
         is_late_cancel = v_late
   where id = p_booking_id;

  update class_occurrences
     set booked_count = greatest(0, booked_count - 1)
   where id = occ.id;

  v_res.status := (case when v_late then 'late_cancelled' else 'cancelled' end)::booking_status;
  v_res.credit_returned := false;
  v_res.offer_made := false;

  -- Credit, if one was taken.
  if b.credit_entry_id is not null then
    select * into v_entry from credit_ledger where id = b.credit_entry_id;

    if v_late and coalesce(st.late_cancel_consumes_credit, true) then
      v_res.reason := 'Cancelled inside the notice period, so the class is used.';
    elsif v_entry.expires_at is not null and v_entry.expires_at < now() then
      -- §3.1: a credit cannot be resurrected past its expiry.
      v_res.reason := 'That class pack has expired, so the credit could not go back on.';
    else
      select coalesce(sum(delta), 0) into v_bal
        from credit_ledger
       where studio_id = b.studio_id and member_id = b.member_id;

      insert into credit_ledger (studio_id, member_id, membership_id, delta, reason,
                                 booking_id, balance_after, expires_at, actor_user_id)
      values (b.studio_id, b.member_id, v_entry.membership_id, 1, 'cancellation_refund',
              p_booking_id, v_bal + 1, v_entry.expires_at, auth.uid());

      if v_entry.membership_id is not null then
        update memberships set credits_remaining = coalesce(credits_remaining, 0) + 1
         where id = v_entry.membership_id;
      end if;
      v_res.credit_returned := true;
    end if;
  end if;

  -- §4.2: a freed seat offers itself to the front of the waitlist. §4.3 clamps
  -- the window, and refuses to make an offer nobody could realistically take.
  if coalesce(st.waitlist_enabled, true) then
    select * into v_next from bookings
     where occurrence_id = occ.id and status = 'waitlisted'
     order by waitlist_position
     limit 1;

    if found then
      v_mins   := floor(extract(epoch from occ.starts_at - now()) / 60)::int;
      v_window := least(coalesce(st.waitlist_offer_window_minutes, 120),
                        v_mins - coalesce(st.waitlist_cutoff_minutes, 60));
      if v_window >= 15 then
        insert into waitlist_offers (studio_id, booking_id, occurrence_id, expires_at)
        values (occ.studio_id, v_next.id, occ.id,
                now() + make_interval(mins => v_window));
        v_res.offer_made := true;
      end if;
    end if;
  end if;

  return v_res;
end $function$

;

CREATE OR REPLACE FUNCTION public.respond_to_offer(p_offer_id uuid, p_accept boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o   waitlist_offers%rowtype;
  b   bookings%rowtype;
  m   members%rowtype;
  res book_class_result;
begin
  select * into o from waitlist_offers where id = p_offer_id for update;
  if not found then
    raise exception 'no such offer' using errcode = 'PT404';
  end if;
  if o.outcome is not null then
    raise exception 'that offer has already been answered' using errcode = 'PT409';
  end if;
  if o.expires_at < now() then
    update waitlist_offers set outcome = 'expired', responded_at = now() where id = o.id;
    return jsonb_build_object('ok', false, 'reason', 'expired');
  end if;

  select * into b from bookings where id = o.booking_id;
  select * into m from members where id = b.member_id;
  if not (coalesce(m.user_id = auth.uid(), false) or is_desk_up(o.studio_id)) then
    raise exception 'that is not your offer' using errcode = 'PT403';
  end if;

  if not p_accept then
    update waitlist_offers set outcome = 'declined', responded_at = now() where id = o.id;
    update bookings set status = 'cancelled', cancelled_at = now() where id = b.id;
    update class_occurrences set waitlist_count = greatest(0, waitlist_count - 1)
     where id = o.occurrence_id;
    return jsonb_build_object('ok', true, 'accepted', false);
  end if;

  -- Drop the waitlist row first so book_class() sees a clean slate, then run
  -- the real gate: eligibility, payment source, credit, capacity, all of it.
  update bookings set status = 'cancelled', cancelled_at = now() where id = b.id;
  update class_occurrences set waitlist_count = greatest(0, waitlist_count - 1)
   where id = o.occurrence_id;

  res := book_class(o.occurrence_id, b.member_id, 'member');

  if res.failure_reason is not null then
    update waitlist_offers set outcome = 'failed', responded_at = now() where id = o.id;
    return jsonb_build_object('ok', false, 'reason', res.failure_reason);
  end if;

  update waitlist_offers set outcome = 'accepted', responded_at = now() where id = o.id;
  return jsonb_build_object('ok', true, 'accepted', true,
                            'booking_id', res.booking_id, 'status', res.status);
end $function$

;

CREATE OR REPLACE FUNCTION public.choose_pay_at_desk(p_booking_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare b bookings%rowtype; m members%rowtype; v_price int; v_currency char(3); v_pay uuid;
begin
  select * into b from bookings where id = p_booking_id;
  if not found then
    raise exception 'no such booking' using errcode = 'PT404';
  end if;
  select * into m from members where id = b.member_id;

  -- The member themselves, or staff doing it for them at the counter.
  if not (coalesce(m.user_id = auth.uid(), false) or is_desk_up(b.studio_id)) then
    raise exception 'that is not your booking' using errcode = 'PT403';
  end if;
  if b.status <> 'pending_payment' then
    raise exception 'that booking is not waiting on a payment' using errcode = 'PT409';
  end if;

  perform confirm_dropin_payment(b.studio_id, b.id);

  select mp.price_cents, mp.currency into v_price, v_currency
    from membership_plans mp
   where mp.studio_id = b.studio_id and mp.type = 'drop_in' and mp.status = 'active'
   order by mp.sort_order limit 1;

  -- Pending, not succeeded: nothing has been paid. This row is the reason the
  -- desk knows to ask, and record_manual_payment() settles it when they do.
  insert into payments (studio_id, member_id, booking_id, amount_cents, currency,
                        status, provider, description)
  values (b.studio_id, b.member_id, b.id,
          coalesce(v_price, 0), coalesce(v_currency, (select currency from studios where id = b.studio_id)),
          'pending', 'manual', 'Drop-in class — to pay at the studio')
  returning id into v_pay;

  return jsonb_build_object('booking_id', b.id, 'payment_id', v_pay, 'status', 'booked');
end $function$

;

