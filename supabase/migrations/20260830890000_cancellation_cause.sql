-- =============================================================================
-- 079  Why a class was cancelled, and why a booking was released — as data.
-- =============================================================================
-- Groundwork for Decision 22. Both halves of a studio-side cancellation have to
-- become typed facts BEFORE anything computes money from them, because the
-- alternative is every future consumer re-deriving "was this the studio's
-- fault" from a free-text reason or a timestamp, and the third derivation
-- disagreeing with the first two.
--
-- WHAT WAS ACTUALLY THERE: `class_occurrences.cancellation_reason` has existed
-- since migration 001 and NOTHING HAS EVER WRITTEN IT. `cancel_occurrence()`
-- takes p_reason and puts it in the audit payload only — checked: 61 cancelled
-- occurrences, 0 with a stored reason. The same shape as instructor_availability,
-- class_series and class_types.color before them.
--
-- TWO FACTS, NOT ONE, because they answer different questions:
--
--   class_occurrences.cancellation_cause   what the STUDIO owes the INSTRUCTOR
--   bookings.release_reason                what the STUDIO owes the MEMBER
--
-- They always travel together and they are never derived from each other. A
-- class that did not reach its minimum and a class cancelled by a brownout owe
-- the member exactly the same thing and the instructor completely different
-- things.
-- =============================================================================

create type cancellation_cause as enum (
  'unmet_minimum',   -- did not reach its guarantee by the cutoff (Decision 21/22)
  'studio_fault',    -- brownout, equipment, staffing error. The studio's own doing.
  'force_majeure',   -- typhoon, government suspension. Nobody's doing.
  'closure'          -- a planned studio closure (migration 074)
);

create type booking_release_reason as enum (
  'member_cancelled',
  'late_cancelled',
  'studio_released'  -- the member did not choose this and owes nothing for it
);

alter table class_occurrences
  add column if not exists cancellation_cause cancellation_cause;

alter table bookings
  add column if not exists release_reason booking_release_reason;

comment on column class_occurrences.cancellation_cause is
  'Why the class is not running. Pay depends on it, so it lives in the data '
  'rather than in somebody''s memory. Null on a scheduled class.';
comment on column bookings.release_reason is
  'Why the seat came free. THE SEAM FOR PEAK ALLOWANCE: when allowance arrives, '
  'restoration is added inside release_booking_entitlements() and history is '
  'repaired by backfilling on release_reason = ''studio_released''.';

-- -----------------------------------------------------------------------------
-- The seam peak allowance will need
-- -----------------------------------------------------------------------------
-- Credits and infractions are ALREADY correct on this path: cancel_occurrence()
-- sets free_cancel_until, and cancel_booking() then returns the credit and never
-- marks a late cancellation. Peak allowance is the third entitlement and does
-- not exist yet.
--
-- A TRIGGER, not a call site. A booking is released from cancel_booking(), from
-- the drop-in sweep, from cancel_occurrence()'s loop and from any hand-written
-- UPDATE, and a stamp that depends on each caller remembering is one the next
-- caller will miss — migration 031's lesson, and the reason notifications are
-- wired this way too.
--
-- It is IDEMPOTENT BY CONSTRUCTION: it stamps only when the reason is still
-- null. Allowance is consumed at BOOKING time, so its restoration must be a
-- reversing record keyed on the booking rather than a decrement a re-run would
-- apply twice. Establishing that property before anything depends on it is the
-- whole point of doing this now.
--
-- A studio release and a Decision 2 free cancellation BOTH carry a live
-- free_cancel_until, so the timestamp cannot tell them apart: one is the studio
-- cancelling the class, the other is the member choosing to leave a class the
-- studio moved. The difference is which PATH is running, so it is a
-- transaction-local flag — the same mechanism as studiior.archiving and
-- studiior.series_editing.
create or replace function tg_stamp_booking_release()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  if new.status in ('cancelled', 'late_cancelled')
     and old.status is distinct from new.status
     and new.release_reason is null then
    new.release_reason := case
      when coalesce(current_setting('studiior.releasing', true), '') = '1'
        then 'studio_released'::booking_release_reason
      when coalesce(new.is_late_cancel, false)
        then 'late_cancelled'::booking_release_reason
      else 'member_cancelled'::booking_release_reason
    end;

    -- WHEN PEAK ALLOWANCE ARRIVES, IT GOES HERE, for 'studio_released' only,
    -- and history is repaired by backfilling on that same value. Nothing else
    -- in the codebase should learn how to decide what the studio owes.
  end if;
  return new;
end $$;

drop trigger if exists tg_bookings_stamp_release on bookings;
create trigger tg_bookings_stamp_release
  before update of status on bookings
  for each row execute function tg_stamp_booking_release();

revoke execute on function tg_stamp_booking_release() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- cancel_occurrence(): store the reason, and type the cause
-- -----------------------------------------------------------------------------
-- Rebuilt from the LIVE definition, which is safe here and only here: this
-- database is a clean `db reset` and scripts/check-hosted-drift.sh reported
-- IN STEP at 205 functions each side immediately before this was written, so
-- live, files and hosted are the same text.
--
-- The third argument means DROPPING the two-argument signature first. A default
-- does not replace a signature, it creates an overload, and every existing call
-- then fails as ambiguous — migration 028's trap, and 064's. A drop also
-- discards the ACL, so the grant is re-issued at the bottom.
drop function if exists cancel_occurrence(uuid, text);

create or replace function cancel_occurrence(p_occurrence_id uuid,
                                            p_reason text default null,
                                            p_cause cancellation_cause default 'studio_fault')
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  occ class_occurrences%rowtype;
  r record;
  n_notified int := 0; n_cancelled int := 0; n_credited int := 0;
  v_res record;
begin
  select * into occ from class_occurrences where id = p_occurrence_id for update;
  if not found then
    raise exception 'no such class' using errcode = 'PT404';
  end if;
  if not coalesce(is_manager_up(occ.studio_id), false) and not is_service_context() then
    raise exception 'only owners and managers cancel a class' using errcode = 'PT403';
  end if;
  if occ.status = 'cancelled' then
    return jsonb_build_object('ok', true, 'already_cancelled', true,
                              'notified', 0, 'bookings_cancelled', 0);
  end if;

  -- Every booking released below is released BY THE STUDIO. tg_stamp_booking_release()
  -- reads this; it cannot tell a studio release from a Decision 2 free cancellation
  -- by looking at free_cancel_until, because both carry one.
  perform set_config('studiior.releasing', '1', true);

  n_notified := coalesce(queue_occurrence_cancelled(p_occurrence_id), 0);

  -- cancellation_reason has existed since migration 001 and nothing had ever
  -- written it: 61 cancelled occurrences, 0 with a reason. The cause beside it
  -- is what pay reads, so it is typed rather than free text.
  update class_occurrences
     set status = 'cancelled', updated_at = now(),
         cancelled_at = coalesce(cancelled_at, now()),
         cancellation_reason = coalesce(p_reason, cancellation_reason),
         cancellation_cause = p_cause
   where id = p_occurrence_id;

  -- §3.2: the studio cancelled, so nobody is late. free_cancel_until is the
  -- lever that already means this.
  update bookings set free_cancel_until = now() + interval '1 hour'
   where occurrence_id = p_occurrence_id
     and status in ('booked', 'waitlisted', 'pending_payment');

  for r in
    select id from bookings
     where occurrence_id = p_occurrence_id
       and status in ('booked', 'waitlisted', 'pending_payment')
     -- Waitlisted first: see (3) above.
     order by (status = 'waitlisted') desc, booked_at
  loop
    select * into v_res from cancel_booking(r.id);
    n_cancelled := n_cancelled + 1;
    if coalesce(v_res.credit_returned, false) then n_credited := n_credited + 1; end if;
  end loop;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (occ.studio_id, auth.uid(), 'occurrence.cancelled', 'class_occurrences',
          p_occurrence_id, jsonb_build_object('reason', p_reason, 'cause', p_cause,
                                              'notified', n_notified,
                                              'bookings_cancelled', n_cancelled));

  perform set_config('studiior.releasing', '', true);

  return jsonb_build_object('ok', true, 'cause', p_cause, 'notified', n_notified,
                            'bookings_cancelled', n_cancelled,
                            'credits_returned', n_credited);
end $function$;

revoke execute on function cancel_occurrence(uuid, text, cancellation_cause)
  from public, anon, authenticated;
grant execute on function cancel_occurrence(uuid, text, cancellation_cause)
  to authenticated, service_role;

-- The new p_pays_instructors argument changes close_studio's signature, so the
-- old one is dropped rather than left as an overload every existing call would
-- resolve ambiguously against.
drop function if exists close_studio(uuid, date, date, text, time, time, boolean);

-- -----------------------------------------------------------------------------
-- A CLOSURE PAYS NOTHING by default, and a studio can say otherwise per closure
-- -----------------------------------------------------------------------------
-- A Christmas closure announced in October is not something anyone should be
-- paid for. A brownout on the day is studio_fault and pays base. Both cancel
-- classes and both used to be the same colourless event.
--
-- The override is STAMPED ON THE OCCURRENCE rather than resolved at pay time,
-- because a closure can be deleted — migration 074 makes reopening delete the
-- closure row while the cancelled classes stay cancelled. A pay run that looked
-- up "which closure covered this date" would find nothing and quietly pay zero
-- for a closure the studio had said it would pay for.
alter table studio_closures
  add column if not exists pays_instructors boolean not null default false;

alter table class_occurrences
  add column if not exists cancellation_pays boolean;

comment on column class_occurrences.cancellation_pays is
  'Override for what a cancellation pays. Null means the cause decides. Set '
  'from studio_closures.pays_instructors when the cause is ''closure'', because '
  'the closure row may not exist by the time pay is computed.';

create or replace function close_studio(p_studio_id uuid, p_starts_on date, p_ends_on date, p_reason text, p_starts_at_time time without time zone DEFAULT NULL::time without time zone, p_ends_at_time time without time zone DEFAULT NULL::time without time zone, p_confirm boolean DEFAULT false, p_pays_instructors boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_impact jsonb; v_id uuid; r record; v_cancelled int := 0; v_notified int := 0; v jsonb;
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers close the studio' using errcode = 'PT403';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'say why — a closure with no reason is one nobody can explain to a member'
      using errcode = 'PT422';
  end if;
  if (p_starts_at_time is null) <> (p_ends_at_time is null) then
    raise exception 'a partial day needs both a start and an end time' using errcode = 'PT422';
  end if;

  v_impact := closure_impact(p_studio_id, p_starts_on, p_ends_on,
                             p_starts_at_time, p_ends_at_time);

  if not p_confirm then
    return v_impact || jsonb_build_object('ok', false, 'requires_confirmation', true);
  end if;

  insert into studio_closures (studio_id, starts_on, ends_on, starts_at_time,
                               ends_at_time, reason, created_by, pays_instructors)
  values (p_studio_id, p_starts_on, p_ends_on, p_starts_at_time, p_ends_at_time,
          btrim(p_reason), auth.uid(), coalesce(p_pays_instructors, false))
  returning id into v_id;

  -- Everything already on the calendar goes through §3.2's path, one at a time,
  -- so each one's members are told and each one's credits come back.
  for r in select (d ->> 'occurrence_id')::uuid as id
             from jsonb_array_elements(v_impact -> 'detail') d
  loop
    v := cancel_occurrence(r.id, 'Studio closed: ' || btrim(p_reason),
                            'closure'::cancellation_cause);
    -- Stamped now, while the closure is still in hand. Resolving it later by
    -- asking which closure covered the date would find nothing once somebody
    -- reopens the period, because 074 deletes the closure and leaves the
    -- cancelled classes cancelled.
    update class_occurrences set cancellation_pays = coalesce(p_pays_instructors, false)
     where id = r.id;
    v_cancelled := v_cancelled + 1;
    v_notified := v_notified + coalesce((v ->> 'notified')::int, 0);
  end loop;

  return jsonb_build_object(
    'ok', true, 'closure_id', v_id,
    'starts_on', p_starts_on, 'ends_on', p_ends_on,
    'classes_cancelled', v_cancelled, 'members_notified', v_notified,
    'pays_instructors', coalesce(p_pays_instructors, false));
end $function$;

create or replace function sweep_flex_decisions()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  st record; r record; v_job uuid; v_tz text;
  n_conf int := 0; n_canc int := 0; n_studios int := 0; n_told int := 0;
  v_user uuid; v_name text; v_studio_name text;
begin
  if not is_service_context() then
    raise exception 'the flex sweep is a background job' using errcode = 'PT403';
  end if;

  for st in
    select s.id, s.name, s.timezone
      from studios s
      join studio_settings cfg on cfg.studio_id = s.id
     where s.status = 'active' and coalesce(cfg.flex_enabled, false)
     order by s.id
  loop
    n_studios := n_studios + 1;
    v_tz := st.timezone;

    insert into job_runs (job_key, run_for, status)
    values ('flex:' || st.id, (now() at time zone v_tz)::date, 'running')
    on conflict (job_key, run_for) do update
       set attempts = job_runs.attempts + 1, started_at = now(), status = 'running'
    returning id into v_job;

    for r in select * from flex_pending(st.id) where past_due loop
      -- The occurrence's instructor, or nobody: an open shift has none, and a
      -- coach with no login has no address either. Both come out null and the
      -- notice is simply not queued.
      select i.display_name, instructor_user_id(i.id) into v_name, v_user
        from class_occurrences o
        left join instructors i on i.id = o.instructor_id
       where o.id = r.occ_id;
      v_studio_name := st.name;

      if r.booked >= r.minimum then
        -- Confirming is SILENT from the member's side: nothing about the class
        -- changes, because nothing about it was ever different.
        update class_occurrences set flex_confirmed_at = now(), updated_at = now()
         where id = r.occ_id;
        n_conf := n_conf + 1;
        if queue_shift_notice(st.id, v_user, 'flex_confirmed',
             jsonb_build_object('instructor_name', coalesce(v_name, 'there'),
               'studio_name', v_studio_name, 'class_name', r.occ_name,
               'when', r.local_when,
               'booked_line', case when r.booked = 1 then '1 person is booked in.'
                                   else r.booked || ' people are booked in.' end),
             'flex_confirmed:' || r.occ_id) is not null
        then n_told := n_told + 1; end if;
      else
        -- §3.2 exactly: credits back regardless of timing, fees waived, anybody
        -- booked told. At threshold 1 with nobody booked there is nobody to
        -- tell, which is the common case and costs nothing.
        perform cancel_occurrence(r.occ_id, 'Did not reach its minimum by the deadline',
                            'unmet_minimum'::cancellation_cause);
        n_canc := n_canc + 1;
        if queue_shift_notice(st.id, v_user, 'flex_cancelled',
             jsonb_build_object('instructor_name', coalesce(v_name, 'there'),
               'studio_name', v_studio_name, 'class_name', r.occ_name,
               'when', r.local_when,
               'minimum', case when r.minimum = 1 then 'one booking'
                               else r.minimum || ' bookings' end),
             'flex_cancelled:' || r.occ_id) is not null
        then n_told := n_told + 1; end if;
      end if;
    end loop;

    update job_runs set status = 'done', finished_at = now(), error = null where id = v_job;
  end loop;

  return jsonb_build_object('studios', n_studios, 'confirmed', n_conf,
                            'cancelled', n_canc, 'instructors_told', n_told);
end $function$;

revoke execute on function close_studio(uuid, date, date, text, time, time, boolean, boolean)
  from public, anon, authenticated;
grant execute on function close_studio(uuid, date, date, text, time, time, boolean, boolean)
  to authenticated;
