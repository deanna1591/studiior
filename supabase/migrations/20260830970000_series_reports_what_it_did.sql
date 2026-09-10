-- =============================================================================
-- 087  update_series() reported its PREDICTION as its RESULT.
-- =============================================================================
-- REFORMER FLOW on Reform Collective was retimed 19:00 -> 18:00. The series row
-- says 18:00; nineteen occurrences from 2026-11-09 are still at 19:00 and none
-- are at 18:00. The studio was told the edit worked.
--
-- DIAGNOSED AGAINST HOSTED BEFORE CHANGING ANYTHING:
--
--   the function is not broken. Run against that very series today, in a
--   transaction that was rolled back, update_series() returned
--   {"moved": 19, "conflicts": []} and moved all nineteen to 18:00.
--   generation is not broken. Every series on hosted that has NEVER been
--   edited matches its occurrences exactly; the one mismatch is the one
--   series whose updated_at is later than its created_at.
--   move_occurrence() never ran on those nineteen — it writes an audit row
--   and there is not one for any of them.
--   all nineteen are in the apply loop's scope today, match the rule, and
--   would move.
--
-- WHAT THAT LEAVES, and it is the fault worth fixing whatever caused that one
-- edit: `v_moves` is incremented ONLY in the preview loop. The apply loop never
-- touches it, and the function returned it as `moved`. So an apply that moved
-- nothing still answered "moved: 19" with an empty conflicts array, and the
-- screen — which renders exactly what it is given, and renders refusals
-- correctly — said the edit had worked. THE COUNTS WERE A PREDICTION WEARING
-- THE NAME OF A RESULT.
--
-- I could not reconstruct which call left that series in this state. The
-- evidence at the moment of the edit is one transaction that wrote class_series,
-- the nineteen occurrences, and an `occurrences.assigned` audit row — and no
-- single function does all three. **update_series() wrote no audit row at all**,
-- which is exactly why this dead-ends, and is the second thing fixed here.
-- =============================================================================

create or replace function update_series(p_series_id uuid, p_name text, p_class_type_id uuid, p_room_id uuid, p_instructor_id uuid, p_capacity integer, p_duration_minutes integer, p_rrule text, p_starts_on date, p_ends_on date, p_time_of_day time without time zone, p_description text, p_effective_from date DEFAULT NULL::date, p_confirm boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  ser         class_series%rowtype;
  v_tz        text;
  v_today     date;
  v_from      date;
  v_to        date;
  v_days_out  int;
  v_slot_day  date;
  v_new_start timestamptz;
  v_new_end   timestamptz;
  r           record;
  v_move      jsonb;
  v_moves     int := 0;
  -- What the APPLY loop actually did, as opposed to what the preview predicted.
  v_did_move    int := 0;
  v_did_cancel  int := 0;
  v_did_restore int := 0;
  v_drift       int := 0;
  v_cancels   int := 0;
  v_restores  int := 0;
  v_same      int := 0;
  v_adds      int := 0;
  v_exc       int := 0;
  v_emails    int := 0;
  v_blocked   jsonb := '[]'::jsonb;
  v_overcap   jsonb := '[]'::jsonb;
  v_conf      jsonb := '[]'::jsonb;
  v_clear_i   boolean;
  v_push_i    boolean;
  d           date;
  v_gen       jsonb;
begin
  select * into ser from class_series where id = p_series_id for update;
  if not found then
    raise exception 'no such series' using errcode = 'PT404';
  end if;
  if not is_manager_up(ser.studio_id) then
    raise exception 'only owners and managers change the timetable'
      using errcode = 'PT403';
  end if;
  if studio_is_locked(ser.studio_id) then
    raise exception 'this studio''s Studiior subscription is not active'
      using errcode = 'PT402',
            hint = 'Reactivate it from Billing. Nothing has been deleted.';
  end if;

  if coalesce(btrim(p_name), '') = '' then
    raise exception 'a series needs a name' using errcode = 'PT400';
  end if;
  if p_capacity < 1 then
    raise exception 'capacity must be at least 1' using errcode = 'PT400';
  end if;
  if p_duration_minutes < 1 then
    raise exception 'a class must last at least a minute' using errcode = 'PT400';
  end if;
  if p_ends_on is not null and p_ends_on < p_starts_on then
    raise exception 'a series cannot end before it starts' using errcode = 'PT400';
  end if;
  -- Raises PT422 on FREQ=MONTHLY, a missing BYDAY, an unrecognised day or a
  -- COUNT/INTERVAL below one. Better here, where somebody is holding a mouse,
  -- than inside the trigger at 03:10 the next morning.
  perform rrule_last_date(p_rrule, p_starts_on);

  select timezone into v_tz from studios where id = ser.studio_id;
  v_today := (now() at time zone v_tz)::date;
  -- The past is not editable. Default tomorrow rather than today so an edit made
  -- at 18:00 cannot retime this morning's 07:00 class, which has already run.
  v_from := greatest(coalesce(p_effective_from, v_today + 1), v_today);

  -- Migration 068: days, not months, and 60 rather than 12.
  select coalesce(occurrence_horizon_days, 60) into v_days_out
    from studio_settings where studio_id = ser.studio_id;
  v_days_out := coalesce(v_days_out, 60);
  v_to := least(
    v_today + v_days_out,
    coalesce(p_ends_on, 'infinity'::date),
    coalesce(rrule_last_date(p_rrule, p_starts_on), 'infinity'::date));

  -- ---------------------------------------------------------------------------
  -- What the edit would do to what already exists
  -- ---------------------------------------------------------------------------
  -- Cancelled rows are in scope, and that is not tidiness. Dropping Monday
  -- cancels fifty-two classes and the row goes on holding its slot, so putting
  -- Monday back would generate nothing and the studio's Monday would stay empty
  -- for a year with no error anywhere. Only ones nobody was booked on come
  -- back: a class a member was TOLD was cancelled is not something an edit to a
  -- rule may quietly reinstate.
  for r in
    select o.id, o.starts_at, o.ends_at, o.series_slot_at, o.booked_count,
           o.instructor_id, o.room_id, o.assigned_by, o.name, o.status,
           (o.series_slot_at at time zone v_tz)::date as slot_day
      from class_occurrences o
     where o.series_id = p_series_id
       and o.status in ('scheduled','cancelled')
       and o.series_slot_at is not null
       and (o.series_slot_at at time zone v_tz)::date >= v_from
     order by o.series_slot_at
  loop
    -- §5: an occurrence somebody has already moved is theirs. It keeps its own
    -- time and is not counted against the edit either way.
    if exists (select 1 from class_occurrences x
                where x.id = r.id and x.is_exception) then
      v_exc := v_exc + 1;
      continue;
    end if;

    v_slot_day := r.slot_day;

    if series_rule_matches(p_rrule, p_starts_on, p_ends_on, v_slot_day) then
      if r.status = 'cancelled' then
        if r.booked_count = 0 then v_restores := v_restores + 1; end if;
        continue;
      end if;

      -- §5 again, and the reason capacity is checked before anything moves: the
      -- system never silently picks who loses their spot.
      if p_capacity < r.booked_count then
        v_overcap := v_overcap || jsonb_build_object(
          'occurrence_id', r.id,
          'local', to_char(r.starts_at at time zone v_tz, 'FMDay FMDD FMMon, HH24:MI'),
          'booked', r.booked_count);
      end if;

      v_new_start := (v_slot_day + p_time_of_day) at time zone v_tz;
      v_new_end   := v_new_start + make_interval(mins => p_duration_minutes);
      if v_new_start <> r.starts_at or v_new_end <> r.ends_at
         or p_room_id is distinct from r.room_id then
        v_moves  := v_moves + 1;
        v_emails := v_emails + case when v_new_start <> r.starts_at
                                    then r.booked_count else 0 end;
      else
        v_same := v_same + 1;
      end if;
    else
      -- The new rule does not produce this day any more.
      if r.status = 'cancelled' then
        continue;                       -- already gone; nothing to do or report
      elsif r.booked_count > 0 then
        v_blocked := v_blocked || jsonb_build_object(
          'occurrence_id', r.id,
          'local', to_char(r.starts_at at time zone v_tz, 'FMDay FMDD FMMon, HH24:MI'),
          'booked', r.booked_count);
      else
        v_cancels := v_cancels + 1;
      end if;
    end if;
  end loop;

  -- Recurrences the new rule adds that nothing holds yet.
  d := greatest(v_from, p_starts_on);
  while d <= v_to loop
    if series_rule_matches(p_rrule, p_starts_on, p_ends_on, d)
       and not exists (
         select 1 from class_occurrences o
          where o.series_id = p_series_id
            and (o.series_slot_at at time zone v_tz)::date = d) then
      v_adds := v_adds + 1;
    end if;
    d := d + 1;
  end loop;

  -- ---------------------------------------------------------------------------
  -- Refusals that hold whether or not the studio confirmed
  -- ---------------------------------------------------------------------------
  if jsonb_array_length(v_blocked) > 0 then
    return jsonb_build_object(
      'ok', false, 'reason', 'members_booked_on_dropped_classes',
      'blocked', v_blocked, 'effective_from', v_from);
  end if;
  if jsonb_array_length(v_overcap) > 0 then
    return jsonb_build_object(
      'ok', false, 'reason', 'capacity_below_booked',
      'over_capacity', v_overcap, 'capacity', p_capacity,
      'effective_from', v_from);
  end if;

  if not p_confirm then
    return jsonb_build_object(
      'ok', false, 'requires_confirmation', true,
      'effective_from', v_from,
      'will_move', v_moves, 'will_cancel', v_cancels, 'will_add', v_adds,
      'will_restore', v_restores,
      'unchanged', v_same, 'left_as_edited', v_exc,
      'members_emailed', v_emails,
      'horizon_to', v_to);
  end if;

  -- ---------------------------------------------------------------------------
  -- Apply
  -- ---------------------------------------------------------------------------
  perform set_config('studiior.series_editing', 'on', true);

  update class_series
     set name = btrim(p_name), class_type_id = p_class_type_id,
         room_id = p_room_id, instructor_id = p_instructor_id,
         capacity = p_capacity, duration_minutes = p_duration_minutes,
         rrule = p_rrule, starts_on = p_starts_on, ends_on = p_ends_on,
         time_of_day = p_time_of_day, description = nullif(btrim(coalesce(p_description,'')), ''),
         updated_at = now()
   where id = p_series_id;

  -- The series' instructor is the DEFAULT for the classes it makes, not an
  -- override of decisions already taken about them. It is pushed only when it
  -- actually changed, and never onto an occurrence a human assigned — 061's
  -- rule that `assigned_by` marks a person choosing a person.
  v_push_i  := p_instructor_id is distinct from ser.instructor_id;
  v_clear_i := v_push_i and p_instructor_id is null;

  for r in
    select o.id, o.starts_at, o.ends_at, o.booked_count, o.room_id,
           o.assigned_by, o.is_exception, o.status,
           (o.series_slot_at at time zone v_tz)::date as slot_day
      from class_occurrences o
     where o.series_id = p_series_id
       and o.status in ('scheduled','cancelled')
       and o.series_slot_at is not null
       and not o.is_exception
       and (o.series_slot_at at time zone v_tz)::date >= v_from
     order by o.series_slot_at
  loop
    if series_rule_matches(p_rrule, p_starts_on, p_ends_on, r.slot_day) then
      v_new_start := (r.slot_day + p_time_of_day) at time zone v_tz;
      v_new_end   := v_new_start + make_interval(mins => p_duration_minutes);

      -- Bringing a cancelled slot back. Not through move_occurrence(), which
      -- refuses a cancelled class outright and would have nobody to email
      -- anyway; the room and instructor exclusions only start applying again at
      -- the moment status leaves 'cancelled', so this is the one place they can
      -- bite on a row that is merely being restored.
      if r.status = 'cancelled' then
        if r.booked_count = 0 then
          begin
            update class_occurrences
               set status = 'scheduled', starts_at = v_new_start, ends_at = v_new_end,
                   series_slot_at = v_new_start, room_id = p_room_id,
                   updated_at = now()
             where id = r.id;
            v_did_restore := v_did_restore + 1;
          exception when exclusion_violation then
            v_conf := v_conf || jsonb_build_object(
              'occurrence_id', r.id,
              'local', to_char(v_new_start at time zone v_tz, 'YYYY-MM-DD HH24:MI'),
              'reason', case when sqlerrm like '%occ_room_no_overlap%'
                             then 'room_busy' else 'instructor_busy' end);
          end;
        end if;
        continue;
      end if;

      if v_new_start <> r.starts_at or v_new_end <> r.ends_at
         or p_room_id is distinct from r.room_id
         or (v_push_i and r.assigned_by is null) then
        -- Through move_occurrence(), which is the only thing that moves a
        -- class: it owes Decision 2's free cancellation on a significant move
        -- and the class_moved email, and a second implementation of that here
        -- would agree with it exactly once.
        v_move := move_occurrence(
          r.id, v_new_start, v_new_end,
          case when v_push_i and r.assigned_by is null then p_instructor_id end,
          p_room_id, true,
          v_clear_i and r.assigned_by is null);
        if coalesce((v_move ->> 'ok')::boolean, false) then
          -- The row keeps holding the recurrence it now materialises. Without
          -- this the nightly job sees the new slot standing empty and fills it,
          -- and the studio has two classes where it made one.
          update class_occurrences
             set series_slot_at = v_new_start
           where id = r.id;
          v_did_move := v_did_move + 1;
        else
          v_conf := v_conf || jsonb_build_object(
            'occurrence_id', r.id,
            'local', to_char(v_new_start at time zone v_tz, 'YYYY-MM-DD HH24:MI'),
            'reason', coalesce(v_move ->> 'reason', 'refused'),
            'detail', v_move -> 'clash_with');
        end if;
      end if;
    elsif r.status = 'scheduled' then
      -- Nobody is booked: checked above, and the check is what makes this safe.
      update class_occurrences
         set status = 'cancelled', updated_at = now()
       where id = r.id;
      v_did_cancel := v_did_cancel + 1;
    end if;
  end loop;

  -- Fields that are not timing, on everything the edit reaches — including the
  -- occurrences that did not move. Editing capacity used to change the series
  -- and leave every materialised class on the old number, which is the half of
  -- this bug that looks like nothing happening.
  update class_occurrences o
     set name = btrim(p_name), class_type_id = p_class_type_id,
         description = nullif(btrim(coalesce(p_description,'')), ''),
         capacity = p_capacity, updated_at = now()
   where o.series_id = p_series_id
     and o.status = 'scheduled'
     and not o.is_exception
     and o.series_slot_at is not null
     and (o.series_slot_at at time zone v_tz)::date >= v_from;
  -- 'scheduled' only, and after the loop above, so a slot restored in this same
  -- edit picks up the new name and capacity too.

  perform set_config('studiior.series_editing', 'off', true);

  -- Now, and only now, materialise what the new rule adds.
  v_gen := generate_occurrences(p_series_id, null, v_from);

  -- THE POST-CONDITION. Everything above reports what each step believed it was
  -- doing; this asks the calendar. A studio that edits a series and sees it
  -- unchanged has no way to tell that from success, and until now neither did
  -- this function — it returned the PREVIEW's counters whatever the apply loop
  -- managed, so an edit that moved nothing still answered "19 moved".
  select count(*) into v_drift
    from class_occurrences o
   where o.series_id = p_series_id
     and o.status = 'scheduled'
     and not o.is_exception
     and o.series_slot_at is not null
     and (o.series_slot_at at time zone v_tz)::date >= v_from
     and o.starts_at <> (((o.series_slot_at at time zone v_tz)::date + p_time_of_day)
                         at time zone v_tz);

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (ser.studio_id, auth.uid(), 'series.updated', 'class_series', p_series_id,
          jsonb_build_object('time_of_day', ser.time_of_day, 'rrule', ser.rrule,
                             'starts_on', ser.starts_on, 'ends_on', ser.ends_on,
                             'capacity', ser.capacity, 'room_id', ser.room_id,
                             'instructor_id', ser.instructor_id),
          jsonb_build_object('time_of_day', p_time_of_day, 'rrule', p_rrule,
                             'starts_on', p_starts_on, 'ends_on', p_ends_on,
                             'capacity', p_capacity, 'room_id', p_room_id,
                             'instructor_id', p_instructor_id,
                             'effective_from', v_from,
                             'predicted', jsonb_build_object('move', v_moves, 'cancel', v_cancels,
                                            'restore', v_restores),
                             'applied', jsonb_build_object('move', v_did_move, 'cancel', v_did_cancel,
                                            'restore', v_did_restore),
                             'still_out_of_step', v_drift));

  return jsonb_build_object(
    'ok', true,
    'effective_from', v_from,
    -- WHAT HAPPENED, not what was predicted.
    'moved', v_did_move, 'cancelled', v_did_cancel, 'restored', v_did_restore,
    'added', coalesce((v_gen ->> 'created')::int, 0),
    'predicted', jsonb_build_object('moved', v_moves, 'cancelled', v_cancels,
                                    'restored', v_restores),
    'still_out_of_step', v_drift,
    'unchanged', v_same, 'left_as_edited', v_exc,
    'members_emailed', v_emails,
    'conflicts', v_conf || coalesce(v_gen -> 'conflicts', '[]'::jsonb));
end $function$;

-- -----------------------------------------------------------------------------
-- Asking the calendar rather than the counters
-- -----------------------------------------------------------------------------
-- The post-condition, available to any screen: which of a series' own classes
-- are not where its rule says they should be. Nothing derived from what a
-- function believed it did.
create or replace function series_calendar_drift(p_series_id uuid)
returns table (occurrence_id uuid, local_when text, should_be text, reason text)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare ser class_series%rowtype; v_tz text;
begin
  select * into ser from class_series where id = p_series_id;
  if ser.id is null then raise exception 'no such series' using errcode = 'PT404'; end if;
  if ser.studio_id not in (select auth_staff_studios()) and not is_service_context() then
    raise exception 'that is not your studio''s timetable' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = ser.studio_id;

  return query
  select o.id,
         to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMon, HH24:MI'),
         to_char((((o.series_slot_at at time zone v_tz)::date + ser.time_of_day) at time zone v_tz)
                 at time zone v_tz, 'FMDay FMDD FMMon, HH24:MI'),
         case when o.is_exception then 'moved on the calendar, left alone deliberately'
              else 'does not match the series' end
    from class_occurrences o
   where o.series_id = p_series_id
     and o.status = 'scheduled'
     and o.series_slot_at is not null
     and not o.is_exception
     and o.starts_at > now()
     and o.starts_at <> (((o.series_slot_at at time zone v_tz)::date + ser.time_of_day)
                         at time zone v_tz)
   order by o.starts_at;
end $$;

revoke execute on function series_calendar_drift(uuid) from public, anon, authenticated;
grant  execute on function series_calendar_drift(uuid) to authenticated, service_role;
