-- ============================================================================
-- Decision 103(c) — an unpaid reservation hold never looks booked.
-- ============================================================================
-- re-issues: member_pending_bookings(uuid), sweep_unpaid_dropins()
--
-- (1) member_pending_bookings re-issued (DROP + recreate, the RETURNS TABLE
--     grows booking_id/status/hold_until) so the app can tell a reservation
--     HOLD (a pending_payment comp seat, hold_until null) from a booking. A
--     hold reports status 'pending_payment' with its expiry (booked_at + the
--     drop-in payment window) and pending_until NULL, on ANY class, so the Book
--     row, class page and Home show "Payment pending" with Finish paying /
--     Cancel instead of the Decision 21 flex "we'll confirm by" label. The flex
--     and provisional-free arms are byte-faithful from the newest prior reader
--     (20260832120000): a booked flex class keeps its cutoff; a provisional free
--     seat keeps the no-time pending. The prior flex arm's pending_payment rows
--     are now Arm A. No new anon RPC (authenticated, member-guarded).
--
-- (2) sweep_unpaid_dropins re-issued (byte-faithful from 20260833370000) so that
--     when it cancels a hold it also expires the matching pending
--     xendit_purchases row, instead of leaving it for the daily reconcile.
-- ============================================================================

-- --- (1) member_pending_bookings -------------------------------------------
drop function if exists member_pending_bookings(uuid);
create function member_pending_bookings(p_studio_id uuid)
returns table(occurrence_id uuid, booking_id uuid, status text,
              hold_until timestamptz, pending_until timestamptz)
language plpgsql stable security definer set search_path to 'public' as $function$
declare v_member uuid;
begin
  select id into v_member from members where user_id = auth.uid() and studio_id = p_studio_id;
  if v_member is null then
    raise exception 'not a member of that studio' using errcode = 'PT403';
  end if;
  return query
  -- Decision 103(c): a RESERVATION HOLD — a pending_payment comp seat with
  -- hold_until null, created by reserve_free_first when a member starts paying
  -- the reservation fee — is never shown as booked. It reports 'pending_payment'
  -- with the hold expiry (booked_at + the drop-in payment window), on any class,
  -- so the app shows "Payment pending" with the minutes left, Finish paying and
  -- Cancel. The Decision 98 free-class-duplicate holds (hold_until set) have
  -- their own 24h flow and are not reported here.
  select b.occurrence_id, b.id, 'pending_payment'::text,
         coalesce(b.hold_until,
                  b.booked_at + make_interval(mins => coalesce(st.dropin_payment_window_minutes, 15))),
         null::timestamptz
    from bookings b
    join class_occurrences o on o.id = b.occurrence_id
    join studio_settings st  on st.studio_id = b.studio_id
   where b.member_id = v_member
     and b.status = 'pending_payment' and b.payment_source = 'comp'
     and b.hold_until is null
     and o.status = 'scheduled'
  union all
  -- Decision 21 (byte-faithful from the prior reader's flex arm, minus the hold):
  -- a BOOKED flex class not yet committed carries its cutoff. The prior reader's
  -- flex arm also matched pending_payment rows; a hold is now Arm A above, so this
  -- arm is status='booked' only. A provisional free seat on a flex class is
  -- status='booked' and is still returned here with its deadline, exactly as
  -- before; the booked-side output is otherwise unchanged.
  select o.id, b.id, 'booked'::text, null::timestamptz, d.deadline_at
    from bookings b
    join class_occurrences o on o.id = b.occurrence_id
    cross join lateral flex_deadline_for_run(o.id) d
   where b.member_id = v_member
     and b.status = 'booked'
     and coalesce(o.flex, false) and o.committed_at is null and o.status = 'scheduled'
     and d.deadline_at is not null
  union all
  -- Decision 30 (byte-faithful from the prior reader's provisional arm): a
  -- PROVISIONAL free seat is pending too, with NO time shown (pending_until null)
  -- — it confirms the moment the class is on, so a deadline would mislead. On any
  -- class (flex or core); on a flex class it is also returned by the arm above
  -- with its cutoff, exactly as the prior reader did. status='booked', so the
  -- Book list renders it as the bare "Waiting for confirmation" chip.
  select b.occurrence_id, b.id, 'booked'::text, null::timestamptz, null::timestamptz
    from bookings b
    join class_occurrences o on o.id = b.occurrence_id
   where b.member_id = v_member
     and b.status = 'booked' and b.provisional
     and o.status = 'scheduled';
end $function$;
revoke execute on function member_pending_bookings(uuid) from public, anon;
grant  execute on function member_pending_bookings(uuid) to authenticated, service_role;

-- --- (2) sweep_unpaid_dropins ----------------------------------------------
-- Byte-faithful from 20260833370000, plus: expire the matching pending
-- xendit_purchases row when a hold is cancelled, so a stale "money in flight"
-- marker does not wait for the daily reconcile.
create or replace function sweep_unpaid_dropins() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r record;
  n_cancelled int := 0;
  n_offered   int := 0;
  v_res       cancel_result;
begin
  if not is_service_context() then
    raise exception 'the drop-in sweep runs as the backend, not as a user'
      using errcode = 'PT403';
  end if;

  for r in
    select b.id, b.studio_id
      from bookings b
      join studio_settings st on st.studio_id = b.studio_id
     where b.status = 'pending_payment'
       and b.hold_until is null  -- Decision 98: free-class holds have their own 24h sweep
       and b.booked_at < now()
           - make_interval(mins => coalesce(st.dropin_payment_window_minutes, 15))
  loop
    begin
      v_res := cancel_booking(r.id);
      n_cancelled := n_cancelled + 1;
      if v_res.offer_made then
        n_offered := n_offered + 1;
      end if;

      -- The abandoned charge, marked so it stops looking like money in flight.
      update payments
         set status = 'failed',
             failure_code = 'checkout_abandoned',
             failure_message = 'The member did not finish paying inside the window.',
             updated_at = now()
       where booking_id = r.id and status = 'pending';

      -- Decision 103(c): expire the matching pending xendit purchase now, rather
      -- than leaving it for the daily reconcile — its booking is cancelled.
      update xendit_purchases
         set status = 'expired',
             failure_reason = 'hold_released',
             updated_at = now()
       where booking_id = r.id and status = 'pending';
    exception when others then
      -- One studio's bad row must not stop every other studio's sweep, the same
      -- reasoning as a missing API key not taking the notification cron down.
      raise warning 'sweep_unpaid_dropins: booking % failed: %', r.id, sqlerrm;
    end;
  end loop;

  return jsonb_build_object('cancelled', n_cancelled, 'waitlist_offers', n_offered);
end $$;

revoke execute on function sweep_unpaid_dropins() from public, anon, authenticated;
grant execute on function sweep_unpaid_dropins() to service_role;

-- --- Anon stays EXACTLY THIRTEEN (neither function is anon) -----------------
do $mig$ declare n int; begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % (want 13)', n; end if;
end $mig$;
