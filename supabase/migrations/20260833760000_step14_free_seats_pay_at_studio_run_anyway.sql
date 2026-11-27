-- creates: free_seat_fee_settled_run(uuid), tg_free_seat_settled(), tg_reservation_fee_settles(), withdraw_free_fee_notices_run(uuid), set_free_fee_choice(uuid, text, text), record_reservation_paid_at_studio(uuid, text, text), run_anyway_targets_run(uuid), run_anyway_preview(uuid), run_cancelled_class_anyway(uuid)
-- re-issues: release_provisional_seats_run(uuid), sweep_free_reservation_dues(timestamptz), member_reservation_dues(uuid), write_reservation_credit(uuid), tg_reservation_credit(), apply_free_fee_choice(uuid, text, text), book_first_free(uuid, uuid, text, text), convert_booking_to_free_first(uuid, text, text), staff_book_member(uuid, uuid, jsonb, text), free_seat_reservation_state_run(uuid), flex_pending_free_seats(uuid), daily_money_check(uuid)
--
-- Step 14 (28 Nov 2026).
--   103 (m) A free first class whose reservation fee is settled (paid, covered
--           by credit, waived for the member or the booking, or pays at the
--           studio) is confirmed on booking and never released by the
--           free_first_confirm_at rule. The paid counts (occurrence_paid_count_run,
--           the latch, evaluate_commitment) already count a comp seat; what
--           released Kai's four seats on 27 Nov was release_provisional_seats_run,
--           and what kept them out of pay was the provisional flag
--           (class_seats_used_run). So a settled seat is never provisional:
--           a BEFORE trigger on bookings and an AFTER trigger on a reservation
--           fee payment clear it, and the release skips settled seats.
--   103 (n) Pays at the studio: bookings.reservation_pay_at_studio, a staff
--           choice (set_free_fee_choice, and 'studio' in apply_free_fee_choice),
--           no due/nudge/last call/release, and Paid at studio
--           (record_reservation_paid_at_studio) records the fee.
--   103 (o) Check-in returns the credit for a credit-covered seat.
--   21 (g)  Run a cancelled class anyway (run_anyway_preview,
--           run_cancelled_class_anyway).
--   108 (d) Two daily check items.
-- Anon stays EXACTLY FIFTEEN (asserted at the bottom).

alter table bookings add column if not exists reservation_pay_at_studio boolean not null default false;
alter table bookings add column if not exists reservation_pay_at_studio_at timestamptz;

-- The one definition of "this free first seat's fee is settled" (103 (m)).
create or replace function free_seat_fee_settled_run(p_booking_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select b.payment_source = 'comp' and (
             coalesce(b.reservation_credit_covered, false)
          or coalesce(b.reservation_fee_waived, false)
          or coalesce(b.reservation_pay_at_studio, false)
          or m.reservation_fee_waived_at is not null
          or exists (select 1 from payments p where p.booking_id = b.id and p.kind = 'reservation_fee'
                      and p.status in ('succeeded','partially_refunded')))
      from bookings b join members m on m.id = b.member_id
     where b.id = p_booking_id), false);
$$;
revoke execute on function free_seat_fee_settled_run(uuid) from public, anon, authenticated;
grant  execute on function free_seat_fee_settled_run(uuid) to service_role;

-- A settled free first seat is never provisional, whichever path settles it.
create or replace function tg_free_seat_settled()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(new.provisional, false) and new.payment_source = 'comp' and new.status = 'booked'
     and (coalesce(new.reservation_credit_covered, false)
          or coalesce(new.reservation_fee_waived, false)
          or coalesce(new.reservation_pay_at_studio, false)
          or exists (select 1 from members m where m.id = new.member_id and m.reservation_fee_waived_at is not null)
          or (tg_op = 'UPDATE' and exists (select 1 from payments p where p.booking_id = new.id
                and p.kind = 'reservation_fee' and p.status in ('succeeded','partially_refunded')))) then
    new.provisional := false;
    new.confirmed_at := coalesce(new.confirmed_at, now());
  end if;
  return new;
end $$;
revoke execute on function tg_free_seat_settled() from public, anon, authenticated;
drop trigger if exists bookings_free_seat_settled on bookings;
create trigger bookings_free_seat_settled before insert or update on bookings
  for each row execute function tg_free_seat_settled();

create or replace function tg_reservation_fee_settles()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.kind = 'reservation_fee' and new.booking_id is not null
     and new.status in ('succeeded','partially_refunded') then
    update bookings set provisional = false, confirmed_at = coalesce(confirmed_at, now())
     where id = new.booking_id and provisional and status = 'booked';
  end if;
  return new;
end $$;
revoke execute on function tg_reservation_fee_settles() from public, anon, authenticated;
drop trigger if exists payments_reservation_fee_settles on payments;
create trigger payments_reservation_fee_settles after insert or update of status on payments
  for each row execute function tg_reservation_fee_settles();

-- Withdraw a seat's unsent due, nudge, last call and release notices.
create or replace function withdraw_free_fee_notices_run(p_booking_id uuid)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  delete from notifications
   where status = 'scheduled'
     and (dedupe_key in ('free_reservation_due:' || p_booking_id, 'free_reservation_nudge:' || p_booking_id,
                         'free_reservation_last_call:' || p_booking_id, 'free_reservation_released:' || p_booking_id)
          or dedupe_key like 'free_reservation_due:' || p_booking_id || ':%');
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function withdraw_free_fee_notices_run(uuid) from public, anon, authenticated;
grant  execute on function withdraw_free_fee_notices_run(uuid) to service_role;


CREATE OR REPLACE FUNCTION public.release_provisional_seats_run(p_occurrence_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o class_occurrences%rowtype; s studios%rowtype; r record; n int := 0;
        v_when text; v_when_short text; v_list text; v_fmt text;
        v_notice boolean := coalesce(current_setting('studiior.closure_notice', true), '') = '1';
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then return 0; end if;
  select * into s from studios where id = o.studio_id;
  select coalesce(time_format, '24h') into v_fmt from studio_settings where studio_id = o.studio_id;
  v_fmt := coalesce(v_fmt, '24h');
  v_when       := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY');
  v_when_short := to_char(o.starts_at at time zone s.timezone, 'FMDy FMDD FMMon ')
                 || fmt_clock(o.starts_at, s.timezone, v_fmt);

  -- Decision 103 (m): a free first class whose reservation fee is settled is
  -- confirmed, never released by the confirm-at rule. It stays and counts.
  update bookings b set provisional = false, confirmed_at = coalesce(b.confirmed_at, now())
   where b.occurrence_id = p_occurrence_id and b.status = 'booked' and b.provisional
     and free_seat_fee_settled_run(b.id);

  for r in select b.id, b.member_id from bookings b
            where b.occurrence_id = p_occurrence_id and b.status = 'booked' and b.provisional
              and not free_seat_fee_settled_run(b.id)
  loop
    -- Release, directly: the explicit release_reason means the BEFORE stamp
    -- trigger leaves it, is_late_cancel false means no infraction, and a comp
    -- seat has no credit to return.
    update bookings
       set status = 'cancelled', release_reason = 'trial_not_confirmed',
           cancelled_at = now(), cancelled_by = null, is_late_cancel = false
     where id = r.id;
    update class_occurrences set booked_count = greatest(0, booked_count - 1)
     where id = p_occurrence_id;
    -- The once-ever row goes, so the person is eligible again and keeps their
    -- free class. Removed, not left 'cancelled' — free_first_eligibility's
    -- already_had_free check does not look at status.
    delete from guest_passes where guest_booking_id = r.id;

    -- Decision 77: under the closure-notice flag the member gets ONE
    -- studio_closure_notice instead of this per-class email — skip it here.
    if not v_notice then
    -- Now eligible again, so the "next ones" are computed with this person's own
    -- gates: fullest first, with someone already in; fall back to any eligible.
    select string_agg(z.line, '; ' order by z.ord)
      into v_list
      from (
        select to_char(c.starts_at at time zone s.timezone, 'FMDay ') || fmt_clock(c.starts_at, s.timezone, v_fmt) || ' ' || c.name as line,
               row_number() over (order by c.headcount desc, c.starts_at) as ord
          from free_first_eligible_classes_run(o.studio_id, r.member_id, 1) c
         where c.occurrence_id <> p_occurrence_id and c.free_bookable
         limit 3) z;
    if v_list is null then
      select string_agg(z.line, '; ' order by z.ord)
        into v_list
        from (
          select to_char(c.starts_at at time zone s.timezone, 'FMDay ') || fmt_clock(c.starts_at, s.timezone, v_fmt) || ' ' || c.name as line,
                 row_number() over (order by c.headcount desc, c.starts_at) as ord
            from free_first_eligible_classes_run(o.studio_id, r.member_id, 0) c
           where c.occurrence_id <> p_occurrence_id and c.free_bookable
           limit 3) z;
    end if;

    perform queue_notification(o.studio_id, r.member_id, 'free_booking_not_confirmed',
      jsonb_build_object('class_name', o.name, 'when', v_when, 'day_short', v_when_short,
        'time', fmt_clock(o.starts_at, s.timezone, v_fmt),
        'next_three', coalesce(v_list, 'see the full schedule'),
        'manage_link', member_portal_url(o.studio_id, '/class/' || p_occurrence_id),
        'book_url', member_portal_url(o.studio_id, '/book'),
        'occurrence_id', p_occurrence_id),
      'free_not_confirmed:' || r.id);
    n := n + 1;
    end if;
  end loop;
  return n;
end $function$;
revoke execute on function release_provisional_seats_run(uuid) from public, anon, authenticated;
grant  execute on function release_provisional_seats_run(uuid) to service_role;

create or replace function sweep_free_reservation_dues(p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record; v_asked int := 0; v_released int := 0; v_kept int := 0; v_nudged int := 0; v_last int := 0;
        v_tz text; v_s studios%rowtype; v_payload jsonb;
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
       and not coalesce(b.reservation_pay_at_studio, false)  -- Decision 103 (n)
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

    v_payload := jsonb_build_object(
              'class_name', r.cname, 'day', v_day,
              'time', fmt_clock(r.starts_at, v_tz, v_fmt),
              'fee', fmt_money(r.free_first_reservation_fee_cents,
                               (select currency from studios where id = r.studio_id)),
              'from_date', to_char(r.free_first_reservation_from, 'FMDD Mon'),
              'deadline', fmt_clock(v_deadline, v_tz, v_fmt) || ' on '
                          || to_char(v_deadline at time zone v_tz, 'FMDay FMDD FMMonth'),
              'pay_url', member_portal_url(r.studio_id, '/class/' || r.occ_id),
              'cancel_url', member_portal_url(r.studio_id, '/class/' || r.occ_id),
              'occurrence_id', r.occ_id);

    if p_now < v_deadline then
      -- Ask once. The cut-off (deadline) has not passed.
      if queue_notification(r.studio_id, r.member_id, 'free_reservation_due', v_payload,
            'free_reservation_due:' || r.booking_id) is not null then
        v_asked := v_asked + 1;
      end if;
      -- Decision 103 (j): the nudge 24 hours before the class and the last call
      -- 3 hours before the deadline, once each per booking.
      if p_now >= r.starts_at - interval '24 hours' then
        if queue_notification(r.studio_id, r.member_id, 'free_reservation_nudge', v_payload,
              'free_reservation_nudge:' || r.booking_id) is not null then
          v_nudged := v_nudged + 1;
        end if;
      end if;
      if p_now >= v_deadline - interval '3 hours' then
        if queue_notification(r.studio_id, r.member_id, 'free_reservation_last_call', v_payload,
              'free_reservation_last_call:' || r.booking_id) is not null then
          v_last := v_last + 1;
        end if;
      end if;
    else
      -- Decision 103 (j): release ONLY when a due email for this booking (the
      -- original or a resend) was actually SENT, and sent before the deadline.
      -- A due that failed or never went out keeps the seat; the daily check
      -- lists it.
      if free_due_sent(r.booking_id, v_deadline) then
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
      elsif exists (select 1 from notifications n
                     where n.dedupe_key = 'free_reservation_due:' || r.booking_id
                        or n.dedupe_key like 'free_reservation_due:' || r.booking_id || ':%') then
        v_kept := v_kept + 1;
      end if;
    end if;
  end loop;

  return jsonb_build_object('asked', v_asked, 'released', v_released, 'kept_unsent', v_kept,
                            'nudged', v_nudged, 'last_call', v_last);
end $$;
revoke execute on function sweep_free_reservation_dues(timestamptz) from public, anon, authenticated;
grant  execute on function sweep_free_reservation_dues(timestamptz) to service_role;

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
     and not coalesce(b.reservation_pay_at_studio, false)  -- Decision 103 (n)
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

CREATE OR REPLACE FUNCTION public.write_reservation_credit(p_booking_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare b bookings%rowtype; pay payments%rowtype; v_offer membership_plans%rowtype;
        v_amt int; v_ccy char(3); v_pid uuid;
begin
  select * into b from bookings where id = p_booking_id;
  if not found then return; end if;
  if exists (select 1 from member_credits
              where booking_id = p_booking_id and reason = 'reservation_credit') then
    return;
  end if;
  select * into pay from payments
   where booking_id = p_booking_id and kind = 'reservation_fee'
     and status in ('succeeded', 'partially_refunded')
   order by created_at limit 1;
  if found then
    v_amt := pay.amount_cents - coalesce(pay.refunded_cents, 0); v_ccy := pay.currency; v_pid := pay.id;
  elsif coalesce(b.reservation_credit_covered, false) and b.status = 'attended' then
    -- Decision 103 (o): a seat held by reservation credit, checked in, gets the
    -- credit back exactly as a paid fee does. The fee is the one the cover used.
    v_amt := coalesce(
      (select (a.after ->> 'fee_cents')::int from audit_logs a
        where a.action = 'reservation.credit_used' and a.entity_table = 'bookings'
          and a.entity_id = p_booking_id order by a.created_at desc limit 1),
      (select free_first_reservation_fee_cents from studio_settings where studio_id = b.studio_id));
    select currency into v_ccy from studios where id = b.studio_id;
    v_pid := null;
    if coalesce(v_amt, 0) <= 0 then return; end if;
  else
    return;
  end if;
  insert into member_credits (studio_id, member_id, amount_cents, currency, reason,
                              payment_id, booking_id)
  values (b.studio_id, b.member_id, v_amt, v_ccy, 'reservation_credit', v_pid, p_booking_id);

  -- Decision 103 amendment (b): a CHECK-IN (attended) writes one credit-back
  -- email. An on-time cancel also writes the credit (Decision 103) but gets no
  -- "thanks for coming" email, so this is gated on the booking being attended.
  if b.status = 'attended' then
    -- Step 13: the studio's intro offer, for an offer button ({offer_plan_name},
    -- {offer_price} resolved at send time from offer_plan_id, {buy_url}).
    select mp.* into v_offer from studio_settings st join membership_plans mp on mp.id = st.intro_offer_plan_id
     where st.studio_id = b.studio_id and mp.status = 'active';
    perform queue_notification(b.studio_id, b.member_id, 'free_reservation_credited',
      jsonb_build_object(
        'fee', fmt_money(v_amt, v_ccy),
        'class_name', coalesce((select coalesce(o.name, ct.name, 'your class')
                                  from class_occurrences o
                                  left join class_types ct on ct.id = o.class_type_id
                                 where o.id = b.occurrence_id), 'your class'),
        'plans_url', member_portal_url(b.studio_id, '/account/plan'),
        'offer_plan_id', v_offer.id,
        'offer_plan_name', coalesce(v_offer.name, 'a class pack'),
        'buy_url', case when v_offer.id is not null
                        then member_portal_url(b.studio_id, '/buy/' || v_offer.id::text)
                        else member_portal_url(b.studio_id, '/account/plan') end),
      'free_reservation_credited:' || p_booking_id);
  end if;
end $function$;
revoke execute on function write_reservation_credit(uuid) from public, anon, authenticated;
grant  execute on function write_reservation_credit(uuid) to service_role;

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
    elsif new.status = 'attended' and coalesce(new.reservation_credit_covered, false) then
      -- Decision 103 (o): a credit-covered seat checked in gets the credit back.
      perform write_reservation_credit(new.id);
    elsif new.status = 'cancelled' and coalesce(new.reservation_credit_covered, false) then
      perform return_reservation_credit(new.id);
    end if;
  end if;
  return new;
end $$;
revoke execute on function tg_reservation_credit() from public, anon, authenticated;
grant  execute on function tg_reservation_credit() to service_role;

create or replace function apply_free_fee_choice(p_booking_id uuid, p_choice text, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype; o class_occurrences%rowtype; st studio_settings%rowtype;
        s studios%rowtype; v_dead timestamptz; v_fmt text; v_dl text; v_late boolean;
begin
  select * into b from bookings where id = p_booking_id;
  select * into o from class_occurrences where id = b.occurrence_id;
  select * into st from studio_settings where studio_id = b.studio_id;
  select * into s from studios where id = b.studio_id;
  v_fmt := coalesce(st.time_format, '24h');
  v_late := coalesce(current_setting('studiior.late_add', true), '') = '1';
  -- Decision 103 (l): the member's unused reservation credit covers the fee. The
  -- seat is confirmed and credit-covered: no due row, no nudge, no last call.
  if p_choice = 'credit' then
    if reservation_credit_available(b.studio_id, b.member_id) >= coalesce(st.free_first_reservation_fee_cents, 0)
       and coalesce(st.free_first_reservation_fee_cents, 0) > 0 then
      update bookings set reservation_credit_covered = true, updated_at = now() where id = p_booking_id;
      perform consume_reservation_credit(b.studio_id, b.member_id, st.free_first_reservation_fee_cents);
      insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
      values (b.studio_id, auth.uid(), 'reservation.credit_used', 'bookings', p_booking_id,
              jsonb_build_object('fee_cents', st.free_first_reservation_fee_cents, 'by_staff', true,
                                 'occurrence_id', o.id, 'member_id', b.member_id));
      return;
    end if;
    p_choice := 'due';
  end if;
  -- Decision 103 (n): pays at the studio. Confirmed and settled at once; no due,
  -- nudge, last call or release; the desk or coach records it with Paid at studio.
  if p_choice = 'studio' then
    update bookings set reservation_pay_at_studio = true, reservation_pay_at_studio_at = now(),
           updated_at = now() where id = p_booking_id;
    perform withdraw_free_fee_notices_run(p_booking_id);
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (b.studio_id, auth.uid(), 'reservation.pay_at_studio', 'bookings', p_booking_id,
            jsonb_build_object('note', nullif(btrim(coalesce(p_note, '')), ''),
                               'fee_cents', st.free_first_reservation_fee_cents,
                               'occurrence_id', o.id, 'member_id', b.member_id));
    return;
  end if;
  if p_choice = 'waive' then
    update bookings set reservation_fee_waived = true, updated_at = now() where id = p_booking_id;
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (b.studio_id, auth.uid(), 'booking.reservation_fee_waived', 'bookings', p_booking_id,
            jsonb_build_object('note', nullif(btrim(coalesce(p_note, '')), ''),
                               'occurrence_id', o.id, 'member_id', b.member_id));
  elsif p_choice = 'due' then
    if v_late then
      v_dl := 'the end of today';
    else
      v_dead := o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0));
      v_dl := case when v_dead <= now() then 'class time'
                   else fmt_clock(v_dead, s.timezone, v_fmt) || ' on '
                        || to_char(v_dead at time zone s.timezone, 'FMDay FMDD FMMonth') end;
    end if;
    perform queue_notification(b.studio_id, b.member_id, 'free_reservation_due',
      jsonb_build_object(
        'class_name', coalesce(o.name, (select name from class_types where id = o.class_type_id)),
        'day', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth'),
        'time', fmt_clock(o.starts_at, s.timezone, v_fmt),
        'fee', fmt_money(st.free_first_reservation_fee_cents, s.currency),
        'from_date', to_char(coalesce(st.free_first_reservation_from, now()::date), 'FMDD Mon'),
        'deadline', v_dl,
        'pay_url', member_portal_url(b.studio_id, '/class/' || o.id),
        'cancel_url', member_portal_url(b.studio_id, '/class/' || o.id)),
      'free_reservation_due:' || p_booking_id);
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (b.studio_id, auth.uid(), 'booking.reservation_fee_asked', 'bookings', p_booking_id,
            jsonb_build_object('deadline', v_dl, 'occurrence_id', o.id, 'member_id', b.member_id));
  end if;
end $$;
revoke execute on function apply_free_fee_choice(uuid, text, text) from public, anon, authenticated;
grant  execute on function apply_free_fee_choice(uuid, text, text) to service_role;

CREATE OR REPLACE FUNCTION public.book_first_free(p_occurrence_id uuid, p_member_id uuid DEFAULT NULL::uuid, p_fee_choice text DEFAULT NULL::text, p_fee_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_occ    class_occurrences%rowtype;
  v_member members%rowtype;
  v_set    studio_settings%rowtype;
  v_ser    class_series%rowtype;
  v_cfg_tier guarantee_tier;
  v_tz     text;
  v_elig   jsonb;
  v_free   int;
  v_head   int;
  v_cut    timestamptz;
  v_prov   boolean;
  v_booking uuid;
  v_pass    uuid;
  v_fee_req boolean := false;
  v_covers  boolean := false;
begin
  select * into v_occ from class_occurrences where id = p_occurrence_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;

  -- Decision 100: staff may book a member's free first class (desk-up). Self when
  -- p_member_id is null, which is how the member's own call resolves.
  if p_member_id is not null then
    if not (coalesce(is_desk_up(v_occ.studio_id), false) or is_service_context()
            or coalesce(current_setting('studiior.late_add', true) = '1', false)) then
      return jsonb_build_object('ok', false, 'reason', 'not_authorised');
    end if;
    select * into v_member from members
     where id = p_member_id and studio_id = v_occ.studio_id and deleted_at is null;
  else
    select * into v_member from members
     where studio_id = v_occ.studio_id and user_id = auth.uid();
  end if;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_authorised'); end if;

  -- Decision 100 amendment (b): a late add by the class's own instructor is not
  -- desk-up, so use the unguarded eligibility twin under the flag (the picker
  -- already offered free first after its own check).
  if current_setting('studiior.late_add', true) = '1' then
    v_elig := free_first_eligibility_run(v_occ.studio_id, v_member.id, null);
  else
    v_elig := free_first_eligibility(v_occ.studio_id, v_member.id);
  end if;
  if not (v_elig ->> 'ok')::boolean then return v_elig; end if;

  select * into v_set from studio_settings where studio_id = v_occ.studio_id;
  select timezone into v_tz from studios where id = v_occ.studio_id;

  if v_occ.status <> 'scheduled' then return jsonb_build_object('ok', false, 'reason', 'class_not_bookable'); end if;
  if current_setting('studiior.late_add', true) = '1' then
    if v_occ.ends_at <= now() then return jsonb_build_object('ok', false, 'reason', 'class_ended'); end if;
  elsif v_occ.starts_at <= now() then return jsonb_build_object('ok', false, 'reason', 'class_in_past'); end if;
  if not month_published(v_occ.studio_id, v_occ.starts_at) then
    return jsonb_build_object('ok', false, 'reason', 'month_not_published');
  end if;
  if studio_hides_unstaffed(v_occ.studio_id) and v_occ.staffing <> 'assigned' then
    return jsonb_build_object('ok', false, 'reason', 'not_staffed_yet');
  end if;
  if v_occ.hidden_from_members then
    return jsonb_build_object('ok', false, 'reason', 'class_hidden');
  end if;
  if v_occ.starts_at > now() + make_interval(days => coalesce(v_set.booking_window_days, 30)) then
    return jsonb_build_object('ok', false, 'reason', 'outside_booking_window');
  end if;
  if current_setting('studiior.late_add', true) = '1' then
    null;  -- a late add is inside the cutoff by definition; the flag bypasses it
  elsif v_occ.starts_at < now() + make_interval(mins => coalesce(v_set.booking_cutoff_minutes, 0)) then
    return jsonb_build_object('ok', false, 'reason', 'past_booking_cutoff');
  end if;

  -- Decision 30 amendment (b): a per-class override. 'closed' = never, whatever
  -- the rules say; 'open' skips core_only and the series switch below (seat cap
  -- and peak still apply).
  if v_occ.free_first_override = 'closed' then
    return jsonb_build_object('ok', false, 'reason', 'free_first_closed_here');
  end if;

  if not coalesce(v_set.free_first_peak_allowed, true) and occurrence_is_peak(p_occurrence_id) then
    return jsonb_build_object('ok', false, 'reason', 'peak_not_allowed');
  end if;

  if v_occ.series_id is not null then
    select * into v_ser from class_series where id = v_occ.series_id;
  end if;
  v_cfg_tier := coalesce(v_occ.guarantee_tier,
                         case when v_occ.flex then 'flex'::guarantee_tier end,
                         v_ser.guarantee_tier,
                         case when v_ser.flex then 'flex'::guarantee_tier end,
                         'core'::guarantee_tier);
  if coalesce(v_set.free_first_core_only, false) and v_cfg_tier <> 'core'
     and v_occ.free_first_override is distinct from 'open'
     and coalesce(current_setting('studiior.free_on_flex', true), '') is distinct from '1' then
    return jsonb_build_object('ok', false, 'reason', 'flex_not_allowed');
  end if;
  if v_occ.series_id is not null
     and not coalesce(v_ser.free_first_allowed, true)
     and v_occ.free_first_override is distinct from 'open' then
    return jsonb_build_object('ok', false, 'reason', 'not_trial_class');
  end if;
  if v_set.free_first_seats_per_class is not null
     and (select count(*) from bookings b
           where b.occurrence_id = p_occurrence_id and b.status = 'booked'
             and b.payment_source = 'comp'
             and exists (select 1 from guest_passes gp
                          where gp.guest_booking_id = b.id and gp.host_member_id is null))
         >= v_set.free_first_seats_per_class then
    return jsonb_build_object('ok', false, 'reason', 'free_seats_full');
  end if;

  v_free := v_occ.capacity - occurrence_seats_taken(p_occurrence_id)
                           - occurrence_seats_held(p_occurrence_id);
  if v_free < 1 then return jsonb_build_object('ok', false, 'reason', 'class_full'); end if;

  v_head := occurrence_seats_taken(p_occurrence_id) + 1;
  select cutoff_at into v_cut from occurrence_guarantee_run(p_occurrence_id);
  v_prov := v_set.free_first_confirm_at is not null
            and v_cut is not null
            and v_head < v_set.free_first_confirm_at;

  -- Decision 103 (k): a studio call (p_member_id set) must choose due or waive
  -- while the studio's fee is above zero, the class is on or after the
  -- applies-from date and the member is not waived. A member's own call is
  -- unchanged (the app's reserve path takes the fee).
  if p_member_id is not null then
    -- A late add (Decision 100 b) asks whenever a fee is set, whatever the
    -- applies-from date, as it always has.
    v_fee_req := coalesce(v_set.free_first_reservation_fee_cents, 0) > 0
                 and v_member.reservation_fee_waived_at is null
                 and (coalesce(current_setting('studiior.late_add', true) = '1', false)
                      or (v_set.free_first_reservation_from is not null
                          and (v_occ.starts_at at time zone v_tz)::date >= v_set.free_first_reservation_from));
    -- Decision 103 (l): credit that covers the fee is used; no choice is asked.
    v_covers := v_fee_req and reservation_credit_available(v_occ.studio_id, v_member.id)
                              >= coalesce(v_set.free_first_reservation_fee_cents, 0);
    if v_fee_req and not v_covers and coalesce(p_fee_choice, '') not in ('due', 'waive', 'studio') then
      return jsonb_build_object('ok', false, 'reason', 'fee_choice_required');
    end if;
  end if;

  -- Mark this seat a free first class for the AFTER-INSERT notification trigger,
  -- which fires before the guest_passes row below is written.
  perform set_config('studiior.free_first', '1', true);

  insert into bookings (studio_id, occurrence_id, member_id, status, source,
                        payment_source, provisional, confirmed_at)
  values (v_occ.studio_id, p_occurrence_id, v_member.id, 'booked', 'member', 'comp',
          v_prov, case when v_prov then null else now() end)
  returning id into v_booking;
  update class_occurrences set booked_count = booked_count + 1 where id = p_occurrence_id;

  -- The shared once-ever ledger row. Decision 78: a no-show member's rebook
  -- REUSES this row (upsert on the once-ever index) rather than inserting a
  -- second — the index and its hard guarantee are untouched; the member's comp
  -- no_show bookings are what count the attempts.
  insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email,
                            occurrence_id, guest_booking_id, status, waiver_signed_at)
  values (v_occ.studio_id, null, v_member.id, lower(btrim(v_member.email)),
          p_occurrence_id, v_booking,
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

  perform confirm_provisional_seats_run(p_occurrence_id);

  if v_fee_req then
    perform apply_free_fee_choice(v_booking, case when v_covers then 'credit' else p_fee_choice end, p_fee_note);
  end if;

  return jsonb_build_object('ok', true, 'booking_id', v_booking,
    'guest_pass_id', v_pass, 'provisional', v_prov, 'credit_covered', v_covers);
end $function$;

create or replace function convert_booking_to_free_first(p_booking_id uuid, p_fee_choice text default null, p_fee_note text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_b    bookings%rowtype;
  v_occ  class_occurrences%rowtype;
  v_m    members%rowtype;
  v_s    studios%rowtype;
  v_st   studio_settings%rowtype;
  v_elig jsonb;
  v_fmt  text;
  v_manage text;
  v_cancel_deadline text;
  v_pass uuid;
  v_fee_req boolean := false;
  v_covers  boolean := false;
begin
  select * into v_b from bookings where id = p_booking_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;

  -- Owner/manager of the booking's studio, or a background job.
  if not (coalesce(is_manager_up(v_b.studio_id), false) or is_service_context()) then
    raise exception 'only owners and managers do this' using errcode = 'PT403';
  end if;

  if v_b.status in ('cancelled','late_cancelled') then
    return jsonb_build_object('ok', false, 'reason', 'booking is cancelled');
  end if;
  if v_b.payment_source <> 'drop_in' then
    return jsonb_build_object('ok', false, 'reason', 'not a drop-in booking');
  end if;
  if exists (select 1 from payments p
              where p.booking_id = p_booking_id and p.status in ('succeeded','partially_refunded')) then
    return jsonb_build_object('ok', false, 'reason', 'booking is paid');
  end if;

  -- Free-first eligibility judged as if this booking did not exist (answer 1): the
  -- drop-in being converted is excluded from the qualifying-booking counts. Any
  -- other reason (already_had_free via a real free class / membership / guest pass,
  -- already_member, missed, not_first via another paid class, not_enabled) refuses
  -- with the helper's own wording.
  --
  -- Decision 30 (d, continued): a late cancel uses the free class, BUT staff may
  -- still grant another by hand — so a 'late_cancel' refusal is OVERRIDDEN here
  -- (this convert IS that by-hand grant). It re-points the once-ever pass at the
  -- new seat, which is the one allowed reuse after a late cancel.
  v_elig := free_first_eligibility(v_b.studio_id, v_b.member_id, p_booking_id);
  if not (v_elig ->> 'ok')::boolean and (v_elig ->> 'reason') not in ('late_cancel', 'duplicate') then
    return v_elig;
  end if;

  -- The class must be open to first-timers (Decision 30 amendment b).
  if not coalesce((effective_free_first(v_b.occurrence_id) ->> 'effective_open')::boolean, false) then
    return jsonb_build_object('ok', false, 'reason', 'class is not open to first-timers');
  end if;

  select * into v_occ from class_occurrences where id = v_b.occurrence_id for update;
  select * into v_m from members where id = v_b.member_id;
  select * into v_s from studios where id = v_b.studio_id;
  select * into v_st from studio_settings where studio_id = v_b.studio_id;
  v_fmt := coalesce(v_st.time_format, '24h');

  -- Decision 103 (k): the studio chooses due or waive while a fee applies.
  v_fee_req := coalesce(v_st.free_first_reservation_fee_cents, 0) > 0
               and v_st.free_first_reservation_from is not null
               and (v_occ.starts_at at time zone v_s.timezone)::date >= v_st.free_first_reservation_from
               and v_m.reservation_fee_waived_at is null;
  -- Decision 103 (l): credit that covers the fee is used; no choice is asked.
  v_covers := v_fee_req and reservation_credit_available(v_b.studio_id, v_b.member_id)
                            >= coalesce(v_st.free_first_reservation_fee_cents, 0);
  if v_fee_req and not v_covers and coalesce(p_fee_choice, '') not in ('due', 'waive', 'studio') then
    return jsonb_build_object('ok', false, 'reason', 'fee_choice_required');
  end if;

  -- Mark the seat a free first class (harmless on an UPDATE, consistent with
  -- book_first_free). The seat is CONFIRMED and non-provisional whatever
  -- free_first_confirm_at is, so release_provisional_seats_run never touches it.
  perform set_config('studiior.free_first', '1', true);

  update bookings
     set payment_source = 'comp',
         provisional    = false,
         confirmed_at    = now(),
         status          = 'booked',
         updated_at      = now()
   where id = p_booking_id;
  -- booked_count is unchanged: a booked drop-in already occupies the seat; only the
  -- payment source changes.

  -- The shared once-ever ledger row, written/reused exactly as book_first_free's
  -- upsert on the once-ever index (the nine already have a host-null row — it is
  -- re-pointed at this booking; a late-cancel member's row is likewise re-pointed,
  -- which is the by-hand reuse this amendment allows).
  insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email,
                            occurrence_id, guest_booking_id, status, waiver_signed_at)
  values (v_b.studio_id, null, v_m.id, lower(btrim(v_m.email)),
          v_b.occurrence_id, p_booking_id,
          case when v_m.waiver_signed_at is not null then 'confirmed' else 'invited' end,
          v_m.waiver_signed_at)
  on conflict (studio_id, normalize_email_key(guest_email)) do update
    set host_member_id   = excluded.host_member_id,
        guest_member_id  = excluded.guest_member_id,
        occurrence_id    = excluded.occurrence_id,
        guest_booking_id = excluded.guest_booking_id,
        status           = excluded.status,
        waiver_signed_at = excluded.waiver_signed_at
  returning id into v_pass;

  v_manage := 'https://' || v_s.slug || '.'
              || coalesce(notification_setting('member_app_domain'), 'studiior.app')
              || '/class/' || v_occ.id;
  v_cancel_deadline :=
    fmt_clock(v_occ.starts_at - make_interval(mins => coalesce(v_st.cancellation_cutoff_minutes, 0)), v_s.timezone, v_fmt)
    || ' on ' || to_char(
      (v_occ.starts_at - make_interval(mins => coalesce(v_st.cancellation_cutoff_minutes, 0)))
        at time zone v_s.timezone, 'FMDay FMDD FMMonth YYYY');

  perform queue_notification(v_b.studio_id, v_b.member_id, 'free_booking_confirmed',
    jsonb_build_object('class_name', v_occ.name,
      'day',  to_char(v_occ.starts_at at time zone v_s.timezone, 'FMDay FMDD FMMonth'),
      'time', fmt_clock(v_occ.starts_at, v_s.timezone, v_fmt),
      'cancel_deadline', v_cancel_deadline,
      'manage_link', v_manage,
      'occurrence_id', v_occ.id),
    'free_booking_confirmed:' || p_booking_id);

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (v_b.studio_id, auth.uid(), 'booking.converted_to_free_first', 'bookings', p_booking_id,
          jsonb_build_object('occurrence_id', v_occ.id, 'member_id', v_b.member_id));

  if v_fee_req then
    perform apply_free_fee_choice(p_booking_id, case when v_covers then 'credit' else p_fee_choice end, p_fee_note);
  end if;

  return jsonb_build_object('ok', true, 'booking_id', p_booking_id, 'guest_pass_id', v_pass);
end $$;

CREATE OR REPLACE FUNCTION public.staff_book_member(p_member_id uuid, p_occurrence_id uuid, p_source jsonb, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_occ    class_occurrences%rowtype;
  v_set    studio_settings%rowtype;
  v_member members%rowtype;
  v_mgr    boolean;
  v_kind   text;
  v_res    book_class_result;
  v_booking uuid;
  v_conv   jsonb;
  v_pay    jsonb;
  v_staff_first text;
  v_cap    int;
  v_unpaid int;
  v_label  text;
  v_late   boolean;
  v_method text;
  v_tz     text;
  v_fmt    text;
  v_fee    int;
  v_waive  boolean;
  v_deadline timestamptz;
  v_choice text;
  v_fnote  text;
begin
  select * into v_occ from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  -- Decision 100 amendment (b): desk-up adds any member; the class's own
  -- instructor may add a member to THAT class only.
  if not (coalesce(is_desk_up(v_occ.studio_id), false) or is_service_context()
          or coalesce(is_this_instructor(v_occ.instructor_id), false)) then
    raise exception 'only the desk and up, or the class instructor, book for a member' using errcode = 'PT403';
  end if;
  select * into v_member from members where id = p_member_id and studio_id = v_occ.studio_id and deleted_at is null;
  if not found then raise exception 'no such member' using errcode = 'PT404'; end if;
  select * into v_set from studio_settings where studio_id = v_occ.studio_id;
  v_mgr := coalesce(is_manager_up(v_occ.studio_id), false) or is_service_context();
  v_staff_first := coalesce(
    nullif(split_part((select full_name from profiles where id = auth.uid()), ' ', 1), ''),
    'the studio');
  v_kind := p_source ->> 'kind';
  v_label := p_source ->> 'kind';

  -- Decision 100 amendment (b): a late add books into a class that has
  -- started; after it ends the roster offers no add.
  select timezone into v_tz from studios where id = v_occ.studio_id;
  v_fmt  := v_set.time_format;
  v_late := now() >= v_occ.starts_at;
  if v_late and now() >= v_occ.ends_at then
    return jsonb_build_object('ok', false, 'reason', 'class_ended', 'member_first', v_member.first_name);
  end if;
  v_method := case when coalesce(is_this_instructor(v_occ.instructor_id), false)
                     and not coalesce(is_desk_up(v_occ.studio_id), false)
                   then 'instructor' else 'staff' end;
  if v_late then perform set_config('studiior.late_add', '1', true); end if;

  -- Decision 103 (k): the fee choice for a free first class, read from the
  -- sheet ('due' or 'waive', and a note). A late add keeps Decision 100 (b):
  -- staff default waive, the class's instructor is always due.
  v_choice := nullif(p_source ->> 'fee_choice', '');
  v_fnote  := nullif(btrim(coalesce(p_source ->> 'fee_note', '')), '');
  if v_late and v_choice is null then
    v_choice := case when coalesce((p_source ->> 'waive_fee')::boolean, true) then 'waive' else 'due' end;
  end if;
  if v_method = 'instructor' and v_choice is not null then v_choice := 'due'; end if;
  -- Refuse before any write (the override path books a drop-in first).
  if v_kind in ('free_first','free_first_override')
     and coalesce(v_set.free_first_reservation_fee_cents, 0) > 0
     and v_set.free_first_reservation_from is not null
     and (v_occ.starts_at at time zone v_tz)::date >= v_set.free_first_reservation_from
     and v_member.reservation_fee_waived_at is null
     and coalesce(v_choice, '') not in ('due', 'waive', 'studio') then
    return jsonb_build_object('ok', false, 'reason', 'fee_choice_required', 'member_first', v_member.first_name);
  end if;

  if v_kind in ('free_first_override','complimentary') and not v_mgr then
    raise exception 'only owners and managers do this' using errcode = 'PT403';
  end if;

  if v_kind = 'plan' then
    v_res := book_class(p_occurrence_id, p_member_id, 'front_desk', null, null,
                        (p_source ->> 'membership_id')::uuid);
    v_label := 'a plan';

  elsif v_kind = 'free_first' then
    -- Decision 30(e): a manager may allow this one free class on a flex class.
    if coalesce((p_source ->> 'allow_free_on_flex')::boolean, false) then
      if not v_mgr then
        raise exception 'only owners and managers do this' using errcode = 'PT403';
      end if;
      perform set_config('studiior.free_on_flex', '1', true);
    end if;
    v_conv := book_first_free(p_occurrence_id, p_member_id, v_choice, v_fnote);
    if not (v_conv ->> 'ok')::boolean then
      return jsonb_build_object('ok', false, 'reason', v_conv ->> 'reason', 'member_first', v_member.first_name);
    end if;
    v_booking := (v_conv ->> 'booking_id')::uuid;
    if coalesce((p_source ->> 'allow_free_on_flex')::boolean, false) then
      insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
      values (v_occ.studio_id, auth.uid(), 'booking.free_on_flex', 'bookings', v_booking,
              jsonb_build_object('occurrence_id', v_occ.id));
    end if;
    v_label := 'a free first class';

  elsif v_kind = 'free_first_override' then
    -- Book a drop-in, then convert it (overrides the eligibility refusal).
    v_res := book_class(p_occurrence_id, p_member_id, 'front_desk', null, null, null);
    if v_res.failure_reason is not null then
      return jsonb_build_object('ok', false, 'reason', v_res.failure_reason, 'member_first', v_member.first_name);
    end if;
    if v_res.payment_source is distinct from 'drop_in' then
      return jsonb_build_object('ok', false, 'reason', 'plan_not_covering', 'member_first', v_member.first_name);
    end if;
    v_booking := v_res.booking_id;
    v_conv := convert_booking_to_free_first(v_booking, v_choice, v_fnote);
    if not (v_conv ->> 'ok')::boolean then
      return jsonb_build_object('ok', false, 'reason', v_conv ->> 'reason', 'member_first', v_member.first_name);
    end if;
    v_label := 'a free first class (override)';

  elsif v_kind = 'drop_in_paid' then
    v_res := book_class(p_occurrence_id, p_member_id, 'front_desk', null, null, null);
    if v_res.failure_reason is not null then
      return jsonb_build_object('ok', false, 'reason', v_res.failure_reason, 'member_first', v_member.first_name);
    end if;
    v_booking := v_res.booking_id;
    v_pay := record_desk_dropin_paid(v_booking, coalesce(p_source ->> 'method','cash'),
               (p_source ->> 'amount_cents')::int, nullif(p_source ->> 'reference',''));
    if not coalesce((v_pay ->> 'ok')::boolean, true) then
      return jsonb_build_object('ok', false, 'reason', v_pay ->> 'reason', 'member_first', v_member.first_name);
    end if;
    v_label := 'a drop-in, paid at the studio';

  elsif v_kind = 'drop_in_later' then
    -- Enforce the unpaid cap here, because a desk booking bypasses book_class's.
    v_cap := v_set.max_unpaid_bookings;
    select count(*) into v_unpaid from bookings b
     where b.member_id = p_member_id and b.studio_id = v_occ.studio_id
       and b.payment_source = 'drop_in' and b.status in ('booked','pending_payment')
       and not exists (select 1 from payments p where p.booking_id = b.id
                         and p.status in ('succeeded','partially_refunded'));
    if v_cap is not null and v_unpaid >= v_cap then
      return jsonb_build_object('ok', false, 'reason', 'pay_first', 'member_first', v_member.first_name);
    end if;
    v_res := book_class(p_occurrence_id, p_member_id, 'front_desk', null, null, null);
    if v_res.failure_reason is not null then
      return jsonb_build_object('ok', false, 'reason', v_res.failure_reason, 'member_first', v_member.first_name);
    end if;
    v_booking := v_res.booking_id;
    v_label := 'a drop-in, pay later';

  elsif v_kind = 'complimentary' then
    v_res := book_class(p_occurrence_id, p_member_id, 'front_desk',
                        coalesce(nullif(btrim(coalesce(p_note,'')), ''), 'staff_comp'), 'comp', null);
    if v_res.failure_reason is not null then
      return jsonb_build_object('ok', false, 'reason', v_res.failure_reason, 'member_first', v_member.first_name);
    end if;
    v_booking := v_res.booking_id;
    v_label := 'a complimentary seat';

  else
    raise exception 'unknown booking source' using errcode = 'PT400';
  end if;

  -- The plan / drop-in / comp paths return through v_res; carry its refusal.
  if v_kind in ('plan') and v_res.failure_reason is not null then
    return jsonb_build_object('ok', false, 'reason', v_res.failure_reason, 'member_first', v_member.first_name);
  end if;
  if v_kind = 'plan' then v_booking := v_res.booking_id; end if;

  -- Decision 100 amendment (b): a late add is marked attended at once. The
  -- reservation fee choice is applied inside book_first_free /
  -- convert_booking_to_free_first (Decision 103 (k)).
  if v_late and v_booking is not null then
    perform record_check_in(v_booking, v_method);
  end if;

  -- The attribution: one audit row (booking.late_add for a late add, else
  -- booking.booked_by_staff, read back by member_activity's Journey arm).
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (v_occ.studio_id, auth.uid(),
            case when v_late then 'booking.late_add' else 'booking.booked_by_staff' end,
            'members', p_member_id,
            jsonb_build_object('staff_first', v_staff_first, 'source', v_label,
                               'occurrence_id', p_occurrence_id, 'booking_id', v_booking,
                               'late', coalesce(v_late, false), 'method', v_method,
                               'note', nullif(btrim(coalesce(p_note,'')), '')));

  return jsonb_build_object('ok', true, 'booking_id', v_booking, 'source', v_label,
                            'late', coalesce(v_late, false), 'member_first', v_member.first_name);
end $function$;

create or replace function free_seat_reservation_state_run(p_booking_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare b bookings%rowtype; o class_occurrences%rowtype; st studio_settings%rowtype;
        s studios%rowtype; m members%rowtype; v_dead timestamptz; v_amt int; v_state text;
begin
  select * into b from bookings where id = p_booking_id;
  if not found or b.payment_source is distinct from 'comp' then
    return jsonb_build_object('state', null);
  end if;
  if not exists (select 1 from guest_passes gp
                  where gp.guest_booking_id = b.id and gp.host_member_id is null) then
    return jsonb_build_object('state', null);
  end if;
  select * into o from class_occurrences where id = b.occurrence_id;
  select * into st from studio_settings where studio_id = b.studio_id;
  select * into s from studios where id = b.studio_id;
  select * into m from members where id = b.member_id;
  if coalesce(st.free_first_reservation_fee_cents, 0) <= 0
     or st.free_first_reservation_from is null
     or (o.starts_at at time zone s.timezone)::date < st.free_first_reservation_from then
    return jsonb_build_object('state', null);
  end if;
  v_dead := o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0));
  select p.amount_cents into v_amt from payments p
   where p.booking_id = b.id and p.kind = 'reservation_fee'
     and p.status in ('succeeded','partially_refunded')
   order by p.created_at desc limit 1;
  v_state := case
    when v_amt is not null then 'paid'
    when coalesce(b.reservation_credit_covered, false) then 'covered'
    when coalesce(b.reservation_pay_at_studio, false) then 'at_studio'  -- Decision 103 (n)
    when m.reservation_fee_waived_at is not null or coalesce(b.reservation_fee_waived, false) then 'waived'
    when free_due_sent(b.id) then 'due'
    else 'not_asked' end;
  return jsonb_build_object(
    'state', v_state,
    'booking_id', b.id,
    'fee_cents', coalesce(v_amt, st.free_first_reservation_fee_cents),
    'currency', s.currency,
    'deadline_at', v_dead,
    'deadline_label', fmt_clock(v_dead, s.timezone, coalesce(st.time_format, '24h'))
                      || ' ' || to_char(v_dead at time zone s.timezone, 'FMDy FMDD FMMon'));
end $$;
revoke execute on function free_seat_reservation_state_run(uuid) from public, anon, authenticated;
grant  execute on function free_seat_reservation_state_run(uuid) to service_role;

create or replace function flex_pending_free_seats(p_studio_id uuid)
returns table(occurrence_id uuid, n int, paid int, due int, waived int)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not (coalesce(is_desk_up(p_studio_id), false) or is_service_context()) then
    raise exception 'only staff read this' using errcode = 'PT403';
  end if;
  return query
  select x.occ, count(*)::int,
         count(*) filter (where x.st in ('paid','covered','at_studio'))::int,
         count(*) filter (where x.st in ('due','not_asked'))::int,
         count(*) filter (where x.st = 'waived')::int
    from (select o.id as occ, free_seat_reservation_state_run(b.id) ->> 'state' as st
            from class_occurrences o
            join bookings b on b.occurrence_id = o.id
           where o.studio_id = p_studio_id and o.status = 'scheduled'
             and o.starts_at > now() and coalesce(o.flex, false)
             and o.committed_at is null
             and b.payment_source = 'comp'
             and b.status not in ('cancelled','late_cancelled','waitlisted')) x
   where x.st is not null
   group by x.occ;
end $$;
revoke execute on function flex_pending_free_seats(uuid) from public, anon;
grant  execute on function flex_pending_free_seats(uuid) to authenticated, service_role;

create or replace function daily_money_check(p_studio_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_tz text; v_items jsonb := '[]'::jsonb; v_html text := ''; v_text text := '';
  r record; v_n int; v_line text;
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
       -- Decision 108 (b): a member-less payment (a gift card) is attached to its card.
       and p.member_id is not null
    union all
    -- 4. a member with an active plan still marked lead
    select mname(m.id) || ': has an active plan but is still marked lead'
      from members m
     where m.studio_id = p_studio_id and m.status = 'lead' and m.deleted_at is null and not m.is_test_account
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
       and m.waiver_signed_at is null and not m.is_test_account
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
    union all
    -- 11. Decision 108 (a): a flex class before its cut-off carrying a
    -- reached-minimum mark with fewer paid seats than its minimum.
    select cname(o.id) || ' is marked as reached its minimum with '
           || pc.paid || ' paid of ' || o.minimum_bookings
      from class_occurrences o
      cross join lateral (select count(*)::int as paid from bookings b
             where b.occurrence_id = o.id
               and b.status in ('booked','attended','no_show','pending_payment')
               and not (coalesce(b.payment_source = 'drop_in', false)
                        and not exists (select 1 from payments pmt where pmt.booking_id = b.id
                                         and pmt.status in ('succeeded','partially_refunded')))) pc
     where o.studio_id = p_studio_id and o.status = 'scheduled'
       and coalesce(o.flex, false) and o.committed_at is null
       and (o.flex_reached_minimum_at is not null or o.core_reached_minimum_at is not null)
       and o.minimum_bookings is not null and pc.paid < o.minimum_bookings
       and now() < coalesce((select g.cutoff_at from occurrence_guarantee_run(o.id) g), o.starts_at)
    union all
    -- 12. Decision 108 (a) and (c): a pay line whose amount does not match its
    -- own recorded basis, read at the tier the class had when it was decided.
    -- Settled lines (corrected, voided, restored) are skipped.
    select coalesce((select display_name from instructors where id = ipr.instructor_id), 'An instructor')
           || ': the pay line for ' || coalesce(cname(ipr.occurrence_id), 'a class') || ' is '
           || money_txt(ipr.amount_cents, ipr.currency) || ' but its basis gives '
           || money_txt((rv ->> 'basis_expected')::int, ipr.currency)
      from instructor_pay_records ipr
      cross join lateral pay_line_review_run(ipr.id) rv
     where ipr.studio_id = p_studio_id and ipr.type = 'class'
       and not (rv ->> 'settled')::boolean
       and (rv ->> 'basis_expected') is not null
       and (rv ->> 'basis_expected')::int <> ipr.amount_cents
    union all
    -- 12b. Decision 108 (b) and (c): a pay line on a decided class whose amount
    -- differs from 75 (l). Settled lines are skipped, and a class whose tier
    -- changed since it was decided is left to item 12's basis check.
    select coalesce((select display_name from instructors where id = ipr.instructor_id), 'An instructor')
           || ': the pay line for ' || coalesce(cname(ipr.occurrence_id), 'a class') || ' is '
           || money_txt(ipr.amount_cents, ipr.currency)
           || case when x.expected = 0 and o.status = 'cancelled'
                   then ' but the class did not run and pays nothing'
                   else ' but the rules give ' || money_txt(x.expected, ipr.currency) end
      from instructor_pay_records ipr
      join pay_periods pp on pp.id = ipr.period_id and pp.status = 'open'
      join class_occurrences o on o.id = ipr.occurrence_id
      cross join lateral pay_line_review_run(ipr.id) rv
      cross join lateral (select (compute_class_pay_run(o.id) ->> 'amount_cents')::int as expected) x
     where ipr.studio_id = p_studio_id and ipr.type = 'class'
       and (o.status = 'cancelled' or o.attendance_finalised_at is not null)
       and not (rv ->> 'settled')::boolean
       and (rv ->> 'decision_tier') is not distinct from (rv ->> 'today_tier')
       and x.expected is not null and x.expected <> ipr.amount_cents
    union all
    -- 13. Decision 103 (j): a free first class seat past its deadline that was
    -- kept because its due email was never sent.
    select mname(b.member_id) || ': ' || cname(b.occurrence_id)
           || ' was kept because the pay-to-keep email never reached them'
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
      join studio_settings st on st.studio_id = b.studio_id
      join members mb on mb.id = b.member_id
     where b.studio_id = p_studio_id and b.status = 'booked' and b.payment_source = 'comp'
       and o.starts_at > now() - interval '1 day'
       and not coalesce(b.reservation_credit_covered, false)
       and mb.reservation_fee_waived_at is null and not coalesce(b.reservation_fee_waived, false)
       and not mb.is_test_account
       and coalesce(st.free_first_reservation_fee_cents, 0) > 0
       and st.free_first_reservation_from is not null
       and o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)) <= now()
       and exists (select 1 from guest_passes gp where gp.guest_booking_id = b.id and gp.host_member_id is null)
       and not exists (select 1 from payments p where p.booking_id = b.id
                        and p.kind = 'reservation_fee' and p.status in ('succeeded','partially_refunded'))
       and exists (select 1 from notifications n
                    where n.dedupe_key = 'free_reservation_due:' || b.id
                       or n.dedupe_key like 'free_reservation_due:' || b.id || ':%')
       and not free_due_sent(b.id, o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)))
    union all
    -- 14. Decision 108 (b): a class that ran with no pay line.
    select coalesce(cname(o.id), 'A class') || ' ran with no pay line'
      from class_occurrences o
      join studio_settings st on st.studio_id = o.studio_id
     where o.studio_id = p_studio_id and o.status = 'scheduled' and o.instructor_id is not null
       and (coalesce(st.guarantees_enabled, false) or coalesce(st.flex_enabled, false))
       and o.ends_at < now() - interval '1 hour' and o.starts_at > now() - interval '14 days'
       and not exists (select 1 from instructor_pay_records ipr2 where ipr2.occurrence_id = o.id)
    union all
    -- 15. Decision 108 (b): an always-runs class past its start never committed.
    select coalesce(cname(o.id), 'An always-runs class') || ' started and was never committed'
      from class_occurrences o
      cross join lateral occurrence_guarantee_run(o.id) g
     where o.studio_id = p_studio_id and o.status = 'scheduled' and g.tier = 'always'
       and o.committed_at is null
       and o.starts_at < now() - interval '30 minutes' and o.starts_at > now() - interval '14 days'
    union all
    -- 16. Decision 108 (b): a pay line held for more than 3 days.
    select coalesce((select display_name from instructors where id = ipr.instructor_id), 'An instructor')
           || ': the pay line for ' || coalesce(cname(ipr.occurrence_id), 'a class') || ' has been held for '
           || extract(day from now() - ipr.created_at)::int || ' days'
      from instructor_pay_records ipr
      join pay_periods pp on pp.id = ipr.period_id and pp.status = 'open'
     where ipr.studio_id = p_studio_id and ipr.confirmed_at is null
       and ipr.created_at < now() - interval '3 days'
    union all
    -- 17. Decision 118: a plan bought without an account, not claimed in 30 days.
    select coalesce(xp.buyer_name, xp.buyer_email, 'A buyer') || ': '
           || coalesce((select name from membership_plans where id = xp.plan_id), 'a plan')
           || ' bought, not yet claimed for 30 days'
      from xendit_purchases xp
     where xp.studio_id = p_studio_id and xp.guest_status = 'held'
       and xp.completed_at < now() - interval '30 days'
    union all
    -- 18. Decision 118: an intro offer refund at claim that did not go through.
    select coalesce(xp.buyer_name, xp.buyer_email, 'A buyer') || ': the refund for '
           || coalesce((select name from membership_plans where id = xp.plan_id), 'a plan')
           || ' did not go through. Refund it from Bought, not yet claimed'
      from xendit_purchases xp
     where xp.studio_id = p_studio_id and xp.guest_status = 'refund_pending'
       and xp.updated_at < now() - interval '1 hour'
    union all
    -- 19. Decision 108 (d): a flex class cancelled at the cut-off while it held
    -- first-timers whose fee was settled (103 (m)). Run it anyway brings it back.
    select 'Flex class cancelled at the cut-off with first-timers whose fee was settled: '
           || cname(o.id)
      from class_occurrences o
     where o.studio_id = p_studio_id and o.status = 'cancelled'
       and o.cancellation_cause = 'unmet_minimum'
       and o.cancelled_at > now() - interval '2 days'
       and exists (select 1 from bookings b
                    where b.occurrence_id = o.id and b.status = 'cancelled'
                      and b.payment_source = 'comp'
                      and b.release_reason in ('trial_not_confirmed','studio_released')
                      and (coalesce(b.reservation_credit_covered, false)
                              or coalesce(b.reservation_fee_waived, false)
                              or coalesce(b.reservation_pay_at_studio, false)
                              or exists (select 1 from members m2 where m2.id = b.member_id and m2.reservation_fee_waived_at is not null)
                              or exists (select 1 from payments p2 where p2.booking_id = b.id and p2.kind = 'reservation_fee'
                                          and p2.status in ('succeeded','partially_refunded'))))
    union all
    -- 20. Decision 103 (n): the fee was to be paid at the studio and is not recorded.
    select 'Reservation fee to collect at the studio: ' || mname(b.member_id) || ', ' || cname(b.occurrence_id)
      from bookings b
     where b.studio_id = p_studio_id and coalesce(b.reservation_pay_at_studio, false)
       and b.status in ('attended','no_show')
       and not exists (select 1 from payments p where p.booking_id = b.id and p.kind = 'reservation_fee'
                        and p.status in ('succeeded','partially_refunded'))
  loop
    -- Decision 108 (b): one null line must never wipe the list.
    v_line := coalesce(r.line, 'An item with a missing name');
    v_items := v_items || to_jsonb(v_line);
    v_html  := v_html  || '<li>' || replace(replace(v_line, '&', '&amp;'), '<', '&lt;') || '</li>';
    v_text  := v_text  || '- ' || v_line || E'\n';
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
revoke execute on function daily_money_check(uuid) from public, anon, authenticated;
grant  execute on function daily_money_check(uuid) to service_role;

-- ---- 103 (n): the staff choice on a seat already booked (the roster row) ----
create or replace function set_free_fee_choice(p_booking_id uuid, p_choice text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype; v_state text;
begin
  select * into b from bookings where id = p_booking_id;
  if not found then raise exception 'no such booking' using errcode = 'PT404'; end if;
  if not coalesce(is_desk_up(b.studio_id), false) then
    raise exception 'only the studio sets how the fee is paid' using errcode = 'PT403';
  end if;
  if p_choice not in ('studio', 'waive') then
    return jsonb_build_object('ok', false, 'reason', 'unknown_choice');
  end if;
  if b.status <> 'booked' then
    return jsonb_build_object('ok', false, 'reason', 'not_booked');
  end if;
  v_state := free_seat_reservation_state_run(p_booking_id) ->> 'state';
  if v_state is null or v_state not in ('due', 'not_asked') then
    return jsonb_build_object('ok', false, 'reason', 'not_due', 'state', v_state);
  end if;
  perform apply_free_fee_choice(p_booking_id, p_choice, p_note);
  perform withdraw_free_fee_notices_run(p_booking_id);
  return jsonb_build_object('ok', true, 'state', free_seat_reservation_state_run(p_booking_id) ->> 'state');
end $$;
revoke execute on function set_free_fee_choice(uuid, text, text) from public, anon;
grant  execute on function set_free_fee_choice(uuid, text, text) to authenticated, service_role;

-- ---- 103 (n): Paid at studio ---------------------------------------------------
create or replace function record_reservation_paid_at_studio(p_booking_id uuid, p_method text, p_reference text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype; o class_occurrences%rowtype; st studio_settings%rowtype;
        s studios%rowtype; v_pid uuid;
begin
  select * into b from bookings where id = p_booking_id;
  if not found then raise exception 'no such booking' using errcode = 'PT404'; end if;
  select * into o from class_occurrences where id = b.occurrence_id;
  if not (coalesce(is_desk_up(b.studio_id), false) or is_service_context()
          or coalesce(is_this_instructor(o.instructor_id), false)) then
    raise exception 'that is not your class' using errcode = 'PT403';
  end if;
  if not coalesce(b.reservation_pay_at_studio, false) then
    return jsonb_build_object('ok', false, 'reason', 'not_pay_at_studio');
  end if;
  if exists (select 1 from payments p where p.booking_id = b.id and p.kind = 'reservation_fee'
              and p.status in ('succeeded','partially_refunded')) then
    return jsonb_build_object('ok', false, 'reason', 'already_paid');
  end if;
  if coalesce(p_method, '') not in ('cash','gcash','card_terminal','bank_transfer','other') then
    return jsonb_build_object('ok', false, 'reason', 'unknown_method');
  end if;
  select * into st from studio_settings where studio_id = b.studio_id;
  select * into s from studios where id = b.studio_id;
  if coalesce(st.free_first_reservation_fee_cents, 0) <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_fee');
  end if;
  insert into payments (studio_id, member_id, booking_id, kind, amount_cents, currency, status,
                        provider, method, reference, recorded_by, description, paid_at)
  values (b.studio_id, b.member_id, b.id, 'reservation_fee', st.free_first_reservation_fee_cents,
          s.currency, 'succeeded', 'manual', p_method, nullif(btrim(coalesce(p_reference, '')), ''),
          auth.uid(), 'Reservation fee', now())
  returning id into v_pid;
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (b.studio_id, auth.uid(), 'reservation.paid_at_studio', 'bookings', b.id,
          jsonb_build_object('payment_id', v_pid, 'amount_cents', st.free_first_reservation_fee_cents,
                             'method', p_method, 'occurrence_id', o.id, 'member_id', b.member_id));
  -- Already checked in: the paid fee comes back as studio credit now, as a check-in would.
  if b.status = 'attended' then perform write_reservation_credit(b.id); end if;
  return jsonb_build_object('ok', true, 'payment_id', v_pid);
end $$;
revoke execute on function record_reservation_paid_at_studio(uuid, text, text) from public, anon;
grant  execute on function record_reservation_paid_at_studio(uuid, text, text) to authenticated, service_role;

-- ---- 21 (g): Run a cancelled class anyway ----------------------------------------
-- The bookings that cancellation released or cancelled: same transaction as the
-- class's own cancelled_at, a studio release or a released free seat.
create or replace function run_anyway_targets_run(p_occurrence_id uuid)
returns setof bookings language sql stable security definer set search_path = public as $$
  select b.* from bookings b join class_occurrences o on o.id = b.occurrence_id
   where b.occurrence_id = p_occurrence_id and b.status = 'cancelled'
     and b.release_reason in ('studio_released', 'trial_not_confirmed')
     and o.cancelled_at is not null
     and b.cancelled_at between o.cancelled_at - interval '10 minutes' and o.cancelled_at + interval '1 minute';
$$;
revoke execute on function run_anyway_targets_run(uuid) from public, anon, authenticated;
grant  execute on function run_anyway_targets_run(uuid) to service_role;

create or replace function run_anyway_preview(p_occurrence_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare o class_occurrences%rowtype; v_reason text;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(o.studio_id), false) then
    raise exception 'only owners and managers run a cancelled class' using errcode = 'PT403';
  end if;
  v_reason := case
    when o.status <> 'cancelled' then 'not_cancelled'
    when o.cancellation_cause is distinct from 'unmet_minimum' then 'not_offered'
    when o.starts_at <= now() then 'started'
    else null end;
  return jsonb_build_object(
    'offered', v_reason is null,
    'reason', v_reason,
    'members', coalesce((select jsonb_agg(jsonb_build_object(
        'booking_id', t.id, 'name', mname(t.member_id),
        'waitlisted', t.waitlist_position is not null) order by t.booked_at)
      from run_anyway_targets_run(p_occurrence_id) t), '[]'::jsonb));
end $$;
revoke execute on function run_anyway_preview(uuid) from public, anon;
grant  execute on function run_anyway_preview(uuid) to authenticated, service_role;

create or replace function run_cancelled_class_anyway(p_occurrence_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o class_occurrences%rowtype; s studios%rowtype; st studio_settings%rowtype;
        r record; v_entry credit_ledger%rowtype; v_bal int; v_new uuid; v_fmt text;
        v_restored uuid[] := '{}'; v_booked int := 0; v_spent text[] := '{}';
        v_names text[] := '{}'; v_when text; v_coach text; v_iu uuid; v_digest uuid;
        v_free boolean; v_now timestamptz := now(); v_date date;
begin
  select * into o from class_occurrences where id = p_occurrence_id for update;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(o.studio_id), false) then
    raise exception 'only owners and managers run a cancelled class' using errcode = 'PT403';
  end if;
  if o.status <> 'cancelled' then
    return jsonb_build_object('ok', false, 'reason', 'not_cancelled');
  end if;
  if o.cancellation_cause is distinct from 'unmet_minimum' then
    return jsonb_build_object('ok', false, 'reason', 'not_offered');
  end if;
  if o.starts_at <= now() then
    return jsonb_build_object('ok', false, 'reason', 'started');
  end if;
  select * into s from studios where id = o.studio_id;
  select * into st from studio_settings where studio_id = o.studio_id;
  v_fmt := coalesce(st.time_format, '24h');
  v_date := (o.starts_at at time zone s.timezone)::date;

  begin
    perform set_config('studiior.suppress_booking_email', '1', true);

    -- The not-running pay line goes; the commit below writes the real one (75 (l)).
    delete from instructor_pay_records ipr
     where ipr.occurrence_id = p_occurrence_id and ipr.type = 'class'
       and exists (select 1 from pay_periods pp where pp.id = ipr.period_id and pp.status = 'open');

    for r in select * from run_anyway_targets_run(p_occurrence_id) order by booked_at loop
      v_free := r.payment_source = 'comp' and (
           r.release_reason = 'trial_not_confirmed'
        or coalesce(r.reservation_credit_covered, false) or coalesce(r.reservation_fee_waived, false)
        or coalesce(r.reservation_pay_at_studio, false)
        or exists (select 1 from payments p where p.booking_id = r.id and p.kind = 'reservation_fee')
        or exists (select 1 from notifications n where n.dedupe_key = 'booking_confirmed:' || r.id
                    and n.template_key like 'free_booking%'));

      update bookings
         set status = (case when r.waitlist_position is not null then 'waitlisted' else 'booked' end)::booking_status,
             provisional = false, confirmed_at = coalesce(confirmed_at, v_now),
             cancelled_at = null, cancelled_by = null, release_reason = null,
             is_late_cancel = false, free_cancel_until = null, updated_at = v_now
       where id = r.id;

      -- The plan credit the cancellation returned is spent again.
      select * into v_entry from credit_ledger
       where booking_id = r.id and reason = 'cancellation_refund'
         and created_at >= o.cancelled_at - interval '10 minutes'
       order by created_at desc limit 1;
      if found then
        select coalesce(sum(delta), 0) into v_bal from credit_ledger
         where studio_id = r.studio_id and member_id = r.member_id;
        insert into credit_ledger (studio_id, member_id, membership_id, delta, reason,
                                   booking_id, balance_after, expires_at, actor_user_id)
        values (r.studio_id, r.member_id, v_entry.membership_id, -1, 'booking',
                r.id, v_bal - 1, v_entry.expires_at, auth.uid())
        returning id into v_new;
        update bookings set credit_entry_id = v_new where id = r.id;
        if v_entry.membership_id is not null then
          update memberships set credits_remaining = credits_remaining - 1
           where id = v_entry.membership_id and credits_remaining is not null;
        end if;
      end if;

      -- The peak slot the release gave back is spent again.
      delete from peak_allowance_ledger where booking_id = r.id and reason = 'studio_released';

      -- The free first class comes back with the seat.
      if v_free then
        insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email,
                                  occurrence_id, guest_booking_id, status, waiver_signed_at)
        select o.studio_id, null, m.id, lower(btrim(m.email)), o.id, r.id,
               case when m.waiver_signed_at is not null then 'confirmed' else 'invited' end,
               m.waiver_signed_at
          from members m where m.id = r.member_id
        on conflict do nothing;
      end if;

      -- The reservation credit the cancellation returned: the fee or the cover
      -- holds the seat again. An unused credit goes; a spent one is reported.
      delete from member_credits
       where booking_id = r.id and reason = 'reservation_credit' and voided_at is null and used_cents = 0;
      if exists (select 1 from member_credits where booking_id = r.id and reason = 'reservation_credit'
                  and voided_at is null and used_cents > 0) then
        v_spent := v_spent || mname(r.member_id);
      end if;

      v_restored := v_restored || r.id;
      if r.waitlist_position is null then
        v_booked := v_booked + 1;
        v_names := v_names || mname(r.member_id);
      end if;
    end loop;

    update class_occurrences
       set status = 'scheduled', cancellation_cause = null, cancellation_reason = null,
           cancelled_at = null, hidden_from_members = false, guarantee_tier = 'always',
           booked_count = occurrence_seats_taken(p_occurrence_id),
           waitlist_count = (select count(*) from bookings where occurrence_id = p_occurrence_id and status = 'waitlisted'),
           booked_at_cutoff = v_booked,
           flex_reached_minimum_at = coalesce(flex_reached_minimum_at, v_now),
           committed_at = v_now, updated_at = v_now
     where id = p_occurrence_id;
  exception when exclusion_violation then
    return jsonb_build_object('ok', false, 'reason', 'slot_taken');
  end;

  -- Nothing else this transaction queued goes out (booking alerts, receipts).
  delete from notifications where created_at = v_now and status = 'scheduled'
     and template_key not in ('class_restored', 'class_restored_coach');

  v_when := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth') || ' at '
            || fmt_clock(o.starts_at, s.timezone, v_fmt);
  v_coach := coalesce(split_part((select display_name from instructors where id = o.instructor_id), ' ', 1), 'your coach');

  for r in select b.id, b.member_id from bookings b
            where b.id = any(v_restored) and b.status = 'booked' loop
    perform queue_notification(o.studio_id, r.member_id, 'class_restored',
      jsonb_build_object('class_name', o.name, 'when', v_when, 'instructor_first_name', v_coach,
        'manage_link', member_portal_url(o.studio_id, '/class/' || p_occurrence_id),
        'occurrence_id', p_occurrence_id),
      'class_restored:' || r.id || ':' || extract(epoch from v_now)::bigint);
  end loop;

  v_iu := instructor_user_id(o.instructor_id);
  if v_iu is not null then
    perform queue_shift_notice(o.studio_id, v_iu, 'class_restored_coach',
      jsonb_build_object('class_name', o.name, 'when', v_when, 'coach_first', v_coach,
        'n_booked', v_booked,
        'names', coalesce(array_to_string(v_names, ', '), ''),
        'occurrence_id', p_occurrence_id),
      'class_restored_coach:' || p_occurrence_id || ':' || extract(epoch from v_now)::bigint);
    -- The coach's still-unsent digest for that day is rebuilt from the true picture.
    select id into v_digest from notifications
     where dedupe_key = 'instructor_digest:' || o.instructor_id || ':' || v_date and status = 'scheduled';
    if v_digest is not null then
      update notifications set payload = payload || instructor_digest_block(o.studio_id, o.instructor_id, v_date)
       where id = v_digest;
    end if;
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (o.studio_id, auth.uid(), 'occurrence.restored', 'class_occurrences', p_occurrence_id,
          jsonb_build_object('status', 'cancelled', 'cause', 'unmet_minimum'),
          jsonb_build_object('status', 'scheduled', 'guarantee_tier', 'always', 'restored', cardinality(v_restored),
                             'booked', v_booked, 'credit_spent', to_jsonb(v_spent)));

  return jsonb_build_object('ok', true, 'restored', cardinality(v_restored), 'booked', v_booked,
                            'names', to_jsonb(v_names), 'credit_spent', to_jsonb(v_spent));
end $$;
revoke execute on function run_cancelled_class_anyway(uuid) from public, anon;
grant  execute on function run_cancelled_class_anyway(uuid) to authenticated, service_role;

-- ---- 21 (g): the two emails -------------------------------------------------
insert into notification_templates (key, subject, text_body, html_body, note) values
('class_restored', 'You''re still on for {class_name}, {first_name}', 'Hi {first_name},

Sorry for the mix-up. Your {class_name} on {when} with Coach {instructor_first_name} is on, and your spot is confirmed.

See you there.

{studio_name}', '<p>Hi {first_name},</p>
<p>Sorry for the mix-up. Your {class_name} on {when} with Coach {instructor_first_name} is on, and your spot is confirmed.</p>
<p>See you there.</p>
<p>{studio_name}</p>',
 'Decision 21 (g): a class cancelled at its cut-off was run anyway'),
('class_restored_coach', '{class_name} on {when} is back on', 'Hi {coach_first},

{class_name} on {when} is back on, with {n_booked} booked: {names}.

{studio_name}', '<p>Hi {coach_first},</p>
<p>{class_name} on {when} is back on, with {n_booked} booked: {names}.</p>
<p>{studio_name}</p>',
 'Decision 21 (g): tells the coach a cancelled class was run anyway')
on conflict (key) do nothing;

insert into notification_templates_overrides (studio_id, key, subject, body, body_html, body_text)
select s.id, 'class_restored', 'You''re still on for {class_name}, {first_name}', 'Hi {first_name},

Sorry for the mix-up. Your {class_name} on {when} with Coach {instructor_first_name} is on, and your spot is confirmed.

See you at the reformer!🎀

RPC Studio', '<p>Hi {first_name},</p>
<p>Sorry for the mix-up. Your {class_name} on {when} with Coach {instructor_first_name} is on, and your spot is confirmed.</p>
<p>See you at the reformer!🎀</p>
<p>RPC Studio</p>', 'Hi {first_name},

Sorry for the mix-up. Your {class_name} on {when} with Coach {instructor_first_name} is on, and your spot is confirmed.

See you at the reformer!🎀

RPC Studio'
  from studios s where s.slug = 'reformcollective'
on conflict (studio_id, key) do nothing;

-- ---- 103 (m): settled seats already on the books are confirmed ---------------
update bookings b set provisional = false, confirmed_at = coalesce(b.confirmed_at, now())
 where b.status = 'booked' and b.provisional and free_seat_fee_settled_run(b.id);

-- ---- Anon stays EXACTLY FIFTEEN ---------------------------------------------
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'expect\_%' and p.proname not in ('call_jsonb');
  if n <> 15 then raise exception 'anon surface is %, expected 15', n; end if;
end $$;
