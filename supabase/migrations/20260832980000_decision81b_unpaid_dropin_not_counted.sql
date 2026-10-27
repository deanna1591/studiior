-- Decision 81b — an online unpaid drop-in is held, not counted, until it is paid.
-- re-issues: evaluate_commitment(uuid), snapshot_start_headcount(uuid), tg_flex_reached_minimum()
--
-- Decision 81 (a), amended 2026-10-27: an unpaid drop-in is status 'booked' and
-- holds its seat, but the pay_first predicate (payment_source='drop_in' with no
-- succeeded/partially_refunded payment) excludes it from the commitment snapshot
-- and the start-of-class snapshot. booked_at_cutoff, booked_at_start, keep-alive
-- and the pay headcount all ride those two counts, so one exclusion in each is
-- the whole change: an unpaid drop-in never keeps a class alive and never adds
-- to the instructor's pay until a desk payment (81a), a manual payment, or a
-- plan applied to the booking (73b) makes it count from that moment. The seat is
-- kept until class time; an unpaid no-show owes nothing (Decision 73 unchanged).
-- No change to book_class (the seat stays 'booked'), no new column, no touch to
-- the provisional runs (Decision 30) or sweep_unpaid_dropins. Both functions are
-- otherwise byte-for-byte their newest definitions; create-or-replace keeps ACLs
-- (evaluate_commitment authed/service, snapshot_start_headcount service-only).

-- ===========================================================================
-- 1. evaluate_commitment — re-issued from 20260832750000. The committed count
--    and the flex_booking_confirmed loop exclude unpaid drop-ins.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.evaluate_commitment(p_occurrence_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o class_occurrences%rowtype; g record; v_booked int; s studios%rowtype; r record;
begin
  select * into o from class_occurrences where id = p_occurrence_id for update;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(o.studio_id), false) and not is_service_context() then
    raise exception 'only owners, managers and the sweep decide a class' using errcode = 'PT403';
  end if;

  if o.committed_at is not null then
    return jsonb_build_object('ok', true, 'already', 'committed',
                              'booked_at_cutoff', o.booked_at_cutoff);
  end if;
  if o.status <> 'scheduled' then
    return jsonb_build_object('ok', true, 'already', o.status::text,
                              'cause', o.cancellation_cause);
  end if;

  select * into g from occurrence_guarantee_run(p_occurrence_id);
  if g.cutoff_at is null then
    return jsonb_build_object('ok', true, 'skipped', 'guarantees are off for this class');
  end if;
  if now() < g.cutoff_at then
    return jsonb_build_object('ok', true, 'skipped', 'not due', 'due_at', g.cutoff_at);
  end if;

  -- Decision 30 amendment: we are AT the class's cutoff. A free seat that never
  -- reached its confirm-at total is released NOW, before the headcount is
  -- counted — the member keeps their free class and is told, and the class is
  -- evaluated on who actually remains (so a core 1-paid + 1-released-trial runs,
  -- and a flex min-2 with 1 paid + 1 released trial does not).
  perform release_provisional_seats_run(p_occurrence_id);

  select count(*)::int into v_booked from bookings
   where occurrence_id = p_occurrence_id
     and status in ('booked','attended','no_show','pending_payment')
     -- Decision 81b: an UNPAID drop-in (the pay_first predicate) holds its
     -- seat but is not counted here, so it never keeps a class alive and
     -- never adds to the pay headcount until it is paid.
     and not (coalesce(bookings.payment_source = 'drop_in', false)
              and not exists (select 1 from payments pmt
                               where pmt.booking_id = bookings.id
                                 and pmt.status in ('succeeded','partially_refunded')));

  if v_booked >= g.minimum
     or (o.flex and o.flex_reached_minimum_at is not null) then
    update class_occurrences
       set committed_at = now(), booked_at_cutoff = v_booked, updated_at = now()
     where id = p_occurrence_id;

    -- Decision 21 amendment: a member who booked a FLEX class was shown "waiting
    -- for confirmation" — tell them it is confirmed. Only flex; a core class was
    -- never pending to a member. Dedupe per member per occurrence.
    if g.tier = 'flex' then
      select * into s from studios where id = o.studio_id;
      for r in select member_id from bookings
                where occurrence_id = p_occurrence_id
                  and status in ('booked','attended','no_show','pending_payment')
                  -- Decision 81b: do not tell an unpaid drop-in the flex class
                  -- is confirmed on the strength of their own unpaid seat.
                  and not (coalesce(bookings.payment_source = 'drop_in', false)
                           and not exists (select 1 from payments pmt
                                            where pmt.booking_id = bookings.id
                                              and pmt.status in ('succeeded','partially_refunded')))
      loop
        perform queue_notification(o.studio_id, r.member_id, 'flex_booking_confirmed',
          jsonb_build_object('class_name', o.name,
            'day',  to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth'),
            'time', fmt_clock(o.starts_at, s.timezone,
                     coalesce((select time_format from studio_settings where studio_id = o.studio_id), '24h')),
            -- Decision 21 amendment (20 Oct 2026): plain words read {when} and
            -- {studio_name} — "See you {when} at {studio}".
            'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth') || ' at '
                    || fmt_clock(o.starts_at, s.timezone,
                         coalesce((select time_format from studio_settings where studio_id = o.studio_id), '24h')),
            'studio_name', s.name,
            'occurrence_id', p_occurrence_id),
          'flex_member_confirmed:' || p_occurrence_id || ':' || r.member_id);
      end loop;
    end if;

    return jsonb_build_object('ok', true, 'decision', 'committed',
      'tier', g.tier, 'booked_at_cutoff', v_booked, 'minimum', g.minimum,
      'latched', (v_booked < g.minimum));
  end if;

  update class_occurrences set booked_at_cutoff = v_booked where id = p_occurrence_id;
  perform cancel_occurrence(p_occurrence_id,
            'Did not reach its minimum by the cutoff', 'unmet_minimum');

  return jsonb_build_object('ok', true, 'decision', 'not_running',
    'tier', g.tier, 'booked_at_cutoff', v_booked, 'minimum', g.minimum);
end $function$;

-- ===========================================================================
-- 2. snapshot_start_headcount — re-issued from 20260831650000. The start count
--    excludes unpaid drop-ins the same way, so booked_at_start agrees with
--    booked_at_cutoff and the greatest-of pay basis never counts an unpaid seat.
-- ===========================================================================
create or replace function snapshot_start_headcount(p_occurrence_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  o class_occurrences%rowtype; v_start int; v_rec instructor_pay_records%rowtype;
  c jsonb; v_new int; v_delta int; p pay_periods%rowtype; v_id uuid;
begin
  select * into o from class_occurrences where id = p_occurrence_id for update;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not is_service_context() and not coalesce(is_manager_up(o.studio_id), false) then
    raise exception 'the start snapshot is a background job' using errcode = 'PT403';
  end if;

  -- Idempotent: stamped once.
  if o.booked_at_start is not null then
    return jsonb_build_object('ok', true, 'already', 'snapshotted',
                              'booked_at_start', o.booked_at_start);
  end if;
  if o.starts_at > now() then
    return jsonb_build_object('ok', true, 'skipped', 'not started');
  end if;
  -- Only a committed, still-scheduled class trues up on headcount. A not_running
  -- or otherwise cancelled class is paid by its cancellation rule, not a count.
  if o.committed_at is null or o.status <> 'scheduled' then
    return jsonb_build_object('ok', true, 'skipped', 'not a committed running class');
  end if;

  -- THE SAME statuses evaluate_commitment counts, written the same way, so the
  -- cutoff snapshot and the start snapshot can never disagree about a body.
  select count(*)::int into v_start from bookings
   where occurrence_id = p_occurrence_id
     and status in ('booked','attended','no_show','pending_payment')
     -- Decision 81b: an UNPAID drop-in (the pay_first predicate) holds its
     -- seat but is not counted here, so it never keeps a class alive and
     -- never adds to the pay headcount until it is paid.
     and not (coalesce(bookings.payment_source = 'drop_in', false)
              and not exists (select 1 from payments pmt
                               where pmt.booking_id = bookings.id
                                 and pmt.status in ('succeeded','partially_refunded')));

  update class_occurrences set booked_at_start = v_start, updated_at = now()
   where id = p_occurrence_id;

  -- Nothing to true up unless a class pay record was written at the cutoff
  -- (payroll off, or no rate on file, leaves none — and there is nothing owed).
  select * into v_rec from instructor_pay_records
   where occurrence_id = p_occurrence_id and type = 'class';
  if not found then
    return jsonb_build_object('ok', true, 'booked_at_start', v_start, 'record', 'none');
  end if;

  -- Recompute now that booked_at_start is stamped: greatest(cutoff, start).
  c := compute_class_pay_run(p_occurrence_id);
  if not (c ->> 'ok')::boolean then
    return jsonb_build_object('ok', true, 'booked_at_start', v_start, 'recompute', c);
  end if;
  v_new := (c ->> 'amount_cents')::int;
  v_delta := v_new - v_rec.amount_cents;

  select * into p from pay_periods where id = v_rec.period_id;

  -- greatest() can only raise, never lower; a late cancel picks the cutoff. When
  -- the count moved but the money did not (still below the per-head threshold),
  -- fold the start count into the basis so the statement can show it — but only
  -- while the period is open (a closed one is immutable and already paid).
  if v_delta <= 0 then
    if p.status = 'open' then
      update instructor_pay_records set basis = c -> 'basis' where id = v_rec.id;
    end if;
    return jsonb_build_object('ok', true, 'booked_at_start', v_start,
      'booked_at_cutoff', coalesce(o.booked_at_cutoff, 0), 'delta_cents', 0);
  end if;

  if p.status = 'open' then
    -- Same open period: raise the amount in place and record what it now rests on.
    update instructor_pay_records
       set amount_cents = v_new, basis = c -> 'basis'
     where id = v_rec.id;
    return jsonb_build_object('ok', true, 'booked_at_start', v_start,
      'trued_up', 'in_place', 'delta_cents', v_delta, 'amount_cents', v_new);
  end if;

  -- The period is CLOSED — already paid, and immutable at the trigger. Decision
  -- 22's correction mechanism: the difference is an adjustment in the next open
  -- period, naming the class and why. Idempotent — one true-up adjustment ever.
  if exists (select 1 from instructor_pay_records
              where type = 'adjustment' and basis ->> 'true_up_of' = p_occurrence_id::text) then
    return jsonb_build_object('ok', true, 'booked_at_start', v_start,
      'trued_up', 'already_adjusted');
  end if;
  p := next_open_pay_period(o.studio_id);
  insert into instructor_pay_records (
    studio_id, instructor_id, period_id, type, amount_cents, currency,
    rate_version_id, basis, note, created_by)
  values (o.studio_id, o.instructor_id, p.id, 'adjustment', v_delta, (c ->> 'currency'),
          (c ->> 'rate_version_id')::uuid,
          jsonb_build_object('true_up_of', p_occurrence_id, 'original_period', v_rec.period_id,
            'booked_at_cutoff', coalesce(o.booked_at_cutoff, 0), 'booked_at_start', v_start,
            'reason', 'late bookings after cutoff'),
          o.name || ': late bookings after cutoff', auth.uid())
  returning id into v_id;
  return jsonb_build_object('ok', true, 'booked_at_start', v_start,
    'trued_up', 'adjustment', 'adjustment_id', v_id, 'delta_cents', v_delta);
end $$;

revoke execute on function snapshot_start_headcount(uuid) from public, anon, authenticated;
grant  execute on function snapshot_start_headcount(uuid) to service_role;

-- ===========================================================================
-- 3. tg_flex_reached_minimum — re-issued from 20260831210000. The flex latch
--    (Decision 21) commits a class and tells the instructor the moment it
--    reaches its minimum. Re-issued with create-or-replace (the trigger binding
--    is untouched) so the latch counts PAID seats by the same pay_first
--    exclusion, not booked_count — an unpaid drop-in never latches a flex class.
-- ===========================================================================
create or replace function tg_flex_reached_minimum() returns trigger
language plpgsql security definer set search_path = public as $$
declare g record; s studios%rowtype; v_user uuid; v_name text; v_paid int;
begin
  -- Cheap exits first: only a flex, scheduled, uncommitted, not-yet-latched
  -- class with somebody to tell is a candidate.
  if not coalesce(new.flex, false)
     or new.status <> 'scheduled'
     or new.committed_at is not null
     or new.flex_reached_minimum_at is not null
     or new.instructor_id is null then
    return new;
  end if;

  select * into g from occurrence_guarantee_run(new.id) g;
  -- Decision 81b: the latch (Decision 21) is set by PAID seats only, so an
  -- unpaid drop-in (the pay_first predicate) does not make a flex class go
  -- ahead or email the instructor. booked_count still counts the held seat
  -- for capacity; only this decision excludes it.
  select count(*)::int into v_paid from bookings
   where occurrence_id = new.id
     and status in ('booked','attended','no_show','pending_payment')
     and not (coalesce(bookings.payment_source = 'drop_in', false)
              and not exists (select 1 from payments pmt
                               where pmt.booking_id = bookings.id
                                 and pmt.status in ('succeeded','partially_refunded')));
  -- Only a class that BEHAVES as flex (studio switch on) has a minimum to
  -- reach; occurrence_guarantee demotes a flex class at a flex-off studio to
  -- 'always', which is correctly ignored here.
  if g.tier is distinct from 'flex' or g.minimum is null or v_paid < g.minimum then
    return new;
  end if;

  update class_occurrences set flex_reached_minimum_at = now()
   where id = new.id and flex_reached_minimum_at is null;

  select * into s from studios where id = new.studio_id;
  v_user := instructor_user_id(new.instructor_id);
  if v_user is not null then
    select display_name into v_name from instructors where id = new.instructor_id;
    perform queue_shift_notice(new.studio_id, v_user, 'flex_going_ahead',
      jsonb_build_object(
        'instructor_name', coalesce(v_name, 'there'),
        'studio_name', s.name,
        'class_name', new.name,
        'when', to_char(new.starts_at at time zone s.timezone, 'FMDay FMDD FMMon, HH24:MI'),
        'booked_line', case when new.booked_count = 1 then '1 booked so far.'
                            else new.booked_count || ' booked so far.' end),
      -- Once per class per instructor per start time — a reassignment after a
      -- move is a different person to reassure.
      'flex_going_ahead:' || new.id || ':' || new.instructor_id
        || ':' || extract(epoch from new.starts_at)::bigint);
  end if;

  return new;
end $$;
revoke execute on function tg_flex_reached_minimum()      from public, anon, authenticated;
