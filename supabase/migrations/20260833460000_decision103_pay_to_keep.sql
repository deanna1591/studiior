-- Decision 103 hotfix — the pay-to-keep path for an EXISTING free booking.
--
-- A member who already holds a free first class (a booked comp booking) is sent
-- a free_reservation_due notice ("Pay the fee to keep your spot") when the
-- studio turns the reservation fee on from a date. Tapping it opened the reserve
-- checkout, which ran reserve_free_first -> free_first_eligibility against the
-- member's OWN existing comp booking and refused "already_had_free". The fee
-- path for an existing booking must not run eligibility at all: it is their free
-- class, already booked.
--
-- The fix: the app routes an existing comp booking straight to
-- xendit_begin_reservation (no reserve_free_first, no eligibility); this
-- migration widens xendit_begin_reservation to accept a BOOKED free-first comp
-- booking (a host-null guest_pass, not already fee-paid) as well as the
-- pending_payment hold a new first-timer creates. The webhook already completes
-- it without a second booking: book_first_free_run returns {ok, already:true}
-- for a booking that is already booked+comp, so it writes no new seat and no
-- new guest_pass; xendit_activate_success_internal writes the reservation_fee
-- payment first, which is what makes the booking "reserved" and clears the due.
--
-- re-issues: xendit_begin_reservation(uuid, uuid)

create or replace function xendit_begin_reservation(p_studio_id uuid, p_booking_id uuid)
returns table(purchase_id uuid, amount_cents int, currency char(3))
language plpgsql security definer set search_path = public as $$
declare v_member uuid; b bookings%rowtype; v_fee int; v_ccy char(3); v_id uuid;
begin
  select id into v_member from members where studio_id = p_studio_id and user_id = auth.uid();
  if v_member is null then
    raise exception 'you are not a member of that studio' using errcode = 'PT403';
  end if;
  if not exists (select 1 from studio_payment_providers where studio_id = p_studio_id and provider = 'xendit') then
    raise exception 'this studio is not set up to take online payments' using errcode = 'PT409';
  end if;

  select * into b from bookings where id = p_booking_id;
  if b.id is null or b.member_id <> v_member or b.studio_id <> p_studio_id
     or b.payment_source <> 'comp' then
    raise exception 'that is not a held reservation' using errcode = 'PT409';
  end if;

  -- Already reserved (the fee is paid): nothing to begin.
  if exists (select 1 from payments p
              where p.booking_id = b.id and p.kind = 'reservation_fee'
                and p.status in ('succeeded', 'partially_refunded')) then
    raise exception 'this booking is already reserved' using errcode = 'PT409';
  end if;

  -- Accept either a NEW hold (pending_payment, from reserve_free_first) or an
  -- EXISTING free first class (a booked comp booking carrying the once-ever
  -- host-null guest pass). Both are the member's own free seat; neither needs an
  -- eligibility check, which is for a brand-new first-timer.
  if not (
    b.status = 'pending_payment'
    or (b.status = 'booked'
        and exists (select 1 from guest_passes gp
                     where gp.guest_booking_id = b.id and gp.host_member_id is null))
  ) then
    raise exception 'that is not a held reservation' using errcode = 'PT409';
  end if;

  select ss.free_first_reservation_fee_cents into v_fee from studio_settings ss where ss.studio_id = p_studio_id;
  if coalesce(v_fee, 0) <= 0 then
    raise exception 'this studio has no reservation fee' using errcode = 'PT409';
  end if;
  select st.currency into v_ccy from studios st where st.id = p_studio_id;

  insert into xendit_purchases (studio_id, member_id, booking_id, amount_cents, currency)
  values (p_studio_id, v_member, p_booking_id, v_fee, v_ccy)
  returning id into v_id;

  return query select v_id, v_fee, v_ccy;
end $$;
revoke execute on function xendit_begin_reservation(uuid, uuid) from public, anon;
grant  execute on function xendit_begin_reservation(uuid, uuid) to authenticated, service_role;

-- --- Anon stays EXACTLY THIRTEEN --------------------------------------------
do $$ declare n int; begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % (want 13)', n; end if;
end $$;
