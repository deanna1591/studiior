-- =============================================================================
-- Migration 043: "I'll pay at the desk"
-- =============================================================================
-- Decision 16 makes an online provider optional, which means it is also
-- optional for the MEMBER even at a studio that has one. Somebody who does not
-- want to put a card into a phone at 6am should be able to say so and turn up
-- with cash, exactly as they would at a studio with no provider at all.
--
-- It confirms the held seat and leaves a PENDING payment row, which is what the
-- front desk sees when the member walks in: money owed against a class, ready
-- to be recorded by whatever method actually changes hands.
--
-- Yes, this confirms a booking nobody has paid for. That is precisely what
-- happens today at every studio without a provider, and Decision 16 says the
-- reconciliation is the studio's business rather than ours to police.
-- =============================================================================

create or replace function choose_pay_at_desk(p_booking_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype; m members%rowtype; v_price int; v_currency char(3); v_pay uuid;
begin
  select * into b from bookings where id = p_booking_id;
  if not found then
    raise exception 'no such booking' using errcode = 'PT404';
  end if;
  select * into m from members where id = b.member_id;

  -- The member themselves, or staff doing it for them at the counter.
  if not (m.user_id = auth.uid() or is_desk_up(b.studio_id)) then
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
end $$;

revoke execute on function choose_pay_at_desk(uuid) from public, anon, authenticated;
grant execute on function choose_pay_at_desk(uuid) to authenticated;

comment on function choose_pay_at_desk(uuid) is
  'Confirms a held drop-in seat and leaves a pending payment for the front desk '
  'to settle however the member actually pays. Decision 16.';
