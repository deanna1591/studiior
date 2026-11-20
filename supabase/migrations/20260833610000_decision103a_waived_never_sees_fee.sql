-- re-issues: xendit_begin_reservation(uuid, uuid)
--
-- Decision 103(a) wiring note, 19 Nov 2026 (found on Roselyn Ko): a member whose
-- fee is waived never starts a reservation payment, and a seat that is already
-- booked starts one only when it has an open reservation due.
--
-- xendit_begin_reservation is re-issued byte-faithfully from its newest body
-- (20260833500000_decision103e_fee_always_lands.sql) with two guards added before
-- any purchase row is written:
--   fee_waived (PT409): members.reservation_fee_waived_at is set, or the booking
--     carries reservation_fee_waived (the grandfather flag);
--   not_due (PT409): the booking is already booked and has no open reservation
--     due. "Open due" is exactly member_reservation_dues' predicate (applies-from
--     date reached, cut-off not passed, not credit-covered), so the Home "Pay"
--     card and this guard can never disagree. A pending_payment hold from
--     reserve_free_first is not "already booked" and is unaffected.
-- The ACL is kept by create or replace and re-asserted. No new anon RPC.

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

  -- Decision 103(a) note, 19 Nov 2026: a waived member (or a grandfathered
  -- booking) never starts a reservation payment.
  if exists (select 1 from members m where m.id = v_member and m.reservation_fee_waived_at is not null)
     or coalesce(b.reservation_fee_waived, false) then
    raise exception 'fee_waived' using errcode = 'PT409',
      detail = 'the reservation fee is waived for this member';
  end if;

  -- A seat that is already booked is paid for only when it has an open
  -- reservation due (member_reservation_dues' predicate).
  if b.status = 'booked' and not exists (
       select 1
         from class_occurrences o
         join studio_settings st on st.studio_id = b.studio_id
         join studios s          on s.id = b.studio_id
        where o.id = b.occurrence_id
          and not coalesce(b.reservation_credit_covered, false)
          and coalesce(st.free_first_reservation_fee_cents, 0) > 0
          and st.free_first_reservation_from is not null
          and (o.starts_at at time zone s.timezone)::date >= st.free_first_reservation_from
          and o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)) > now()) then
    raise exception 'not_due' using errcode = 'PT409',
      detail = 'this booking is already booked and has no reservation due';
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

  -- Decision 103(e): the hold lasts as long as the invoice (30 minutes); the app
  -- sets the Xendit session to expire at the same moment.
  update bookings set hold_until = now() + interval '30 minutes', hold_reason = 'reservation'
   where id = p_booking_id;

  return query select v_id, v_fee, v_ccy;
end $$;
revoke execute on function xendit_begin_reservation(uuid, uuid) from public, anon;
grant  execute on function xendit_begin_reservation(uuid, uuid) to authenticated, service_role;

do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'expect_%';
  if n <> 14 then
    raise exception 'anon surface is % functions, expected exactly fourteen', n;
  end if;
end $$;
