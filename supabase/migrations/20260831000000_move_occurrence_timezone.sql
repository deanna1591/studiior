-- =============================================================================
-- 090  move_occurrence() refused an instructor who WAS available, and its
--      Decision 9 warning raised instead of warning.
-- =============================================================================
-- Both found while building create_occurrence(), by copying this function's
-- shape and then testing the copy — which is the argument for sharing a gate
-- rather than writing a second one.
--
-- 1. THE TIMEZONE WAS NULL ON THE ORDINARY PATH.
--
--    `v_tz` was resolved in two places: inside `if v_moved and booked_count > 0`
--    and inside the exclusion handler. Assigning somebody to a class NOBODY HAS
--    BOOKED reaches neither, so at the validity check `v_tz` was still null,
--    `(v_starts at time zone null)::date` was null, and
--    `instructor_valid_on(instructor, null)` is false.
--
--    Proved on the seed: an instructor available 00:00-23:59 every day since a
--    year ago, `instructor_valid_on(instructor, the real date) = true`, and the
--    assignment refused anyway —
--
--      {"ok": false, "reason": "outside_availability_dates",
--       "blocked_by": {"on": null, "who": "Ada Example"}}
--
--    The null `on` is the tell: the message could not name the date because the
--    date was null, which is the same reason the check failed.
--
--    SO: ANY INSTRUCTOR WHO HAS STATED AVAILABILITY COULD NOT BE ASSIGNED to an
--    unbooked class — the drag-and-drop half of Decision 18, refused with a
--    sentence saying they had not agreed to a date they plainly had.
--
--    No test caught it because every scheduling fixture leaves availability
--    empty, and `instructor_available_at()` returns true for somebody who has
--    stated nothing (migration 047, deliberately). The null date only matters
--    once there are rows to compare it against.
--
-- 2. THE WARNING RAISED.
--
--    `v_warnings := v_warnings || 'outside_availability'` on a `text[]` with an
--    untyped literal makes Postgres resolve `anyarray || anyarray` and parse the
--    string as an array: `22P02 malformed array literal`. Unreachable until now
--    only because the refusal above always fired first — fixing (1) exposes it,
--    so both are fixed together. Decision 9 says warn and proceed; it did
--    neither. The same shape as the `text[] || text || text` bug migration 049
--    fixed in brief_summary().
-- =============================================================================

create or replace function move_occurrence(p_occurrence_id uuid, p_starts_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_ends_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_instructor_id uuid DEFAULT NULL::uuid, p_room_id uuid DEFAULT NULL::uuid, p_confirm boolean DEFAULT false, p_clear_instructor boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  occ        class_occurrences%rowtype;
  v_starts   timestamptz;
  v_ends     timestamptz;
  v_instr    uuid;
  v_room     uuid;
  v_staffing staffing_state;
  v_warnings text[] := '{}';
  v_set      studio_settings%rowtype;
  v_tz       text;
  v_clash    class_occurrences%rowtype;
  v_significant boolean := false;
  v_undo     boolean := false;
  v_conflict text;
  v_moved    boolean;
begin
  select * into occ from class_occurrences where id = p_occurrence_id for update;
  if not found then
    raise exception 'no such class' using errcode = 'PT404';
  end if;
  if not is_manager_up(occ.studio_id) then
    raise exception 'only owners and managers change the timetable'
      using errcode = 'PT403';
  end if;
  if studio_is_locked(occ.studio_id) then
    raise exception 'this studio''s Studiior subscription is not active'
      using errcode = 'PT402',
            hint = 'Reactivate it from Billing. Nothing has been deleted.';
  end if;
  if occ.status <> 'scheduled' then
    raise exception 'a % class cannot be moved', occ.status using errcode = 'PT409';
  end if;

  -- ONCE, HERE, BEFORE ANYTHING USES IT. It used to be resolved only inside the
  -- "members are booked" branch and inside the clash handler, so on the ordinary
  -- path — assigning somebody to a class nobody has booked — it was still null
  -- when the validity window was checked below. See migration 090's header.
  select s.timezone into v_tz from studios s where s.id = occ.studio_id;

  v_starts := coalesce(p_starts_at, occ.starts_at);
  v_ends   := coalesce(p_ends_at,   occ.ends_at);
  v_room   := coalesce(p_room_id,   occ.room_id);
  -- p_clear_instructor because a null p_instructor_id has to be able to mean
  -- "leave it alone" as well as "make this an open shift", and one nullable
  -- parameter cannot say both.
  v_instr  := case when p_clear_instructor then null
                   else coalesce(p_instructor_id, occ.instructor_id) end;

  if v_ends <= v_starts then
    raise exception 'a class cannot end before it starts' using errcode = 'PT400';
  end if;

  v_staffing := case when v_instr is null then
                       (case when occ.staffing = 'pending_approval'
                             then 'pending_approval' else 'open' end)
                     else 'assigned' end::staffing_state;

  -- Members are the reason to stop and ask.
  if occ.booked_count > 0 and not p_confirm
     and (v_starts <> occ.starts_at or v_ends <> occ.ends_at
          or v_instr is distinct from occ.instructor_id) then
    return jsonb_build_object(
      'ok', false,
      'requires_confirmation', true,
      'booked_count', occ.booked_count,
      'reason', 'members_booked');
  end if;

  begin
    update class_occurrences
       set starts_at = v_starts, ends_at = v_ends,
           instructor_id = v_instr, room_id = v_room,
           staffing = v_staffing, updated_at = now()
     where id = p_occurrence_id;
  exception when exclusion_violation then
    -- Which of the two, in words a person can act on.
    get stacked diagnostics v_conflict = constraint_name;

    -- "Conflict detected" tells somebody holding a mouse nothing. Find the
    -- class that is actually in the way so the screen can name it and offer to
    -- open it.
    select * into v_clash from class_occurrences o
     where o.id <> p_occurrence_id
       and o.status <> 'cancelled'
       and tstzrange(o.starts_at, o.ends_at) && tstzrange(v_starts, v_ends)
       and ((v_conflict = 'occ_room_no_overlap'       and o.room_id = v_room)
         or (v_conflict = 'occ_instructor_no_overlap' and o.instructor_id = v_instr))
     limit 1;

    select s.timezone into v_tz from studios s where s.id = occ.studio_id;

    return jsonb_build_object(
      'ok', false,
      'requires_confirmation', false,
      'reason', case when v_conflict = 'occ_room_no_overlap'
                     then 'room_busy' else 'instructor_busy' end,
      'conflict', v_conflict,
      'blocked_by', case when v_clash.id is null then null else jsonb_build_object(
        'occurrence_id', v_clash.id,
        'name', v_clash.name,
        'starts_at', v_clash.starts_at,
        'at', to_char(v_clash.starts_at at time zone v_tz, 'HH24:MI'),
        'who', (select i.display_name from instructors i where i.id = v_clash.instructor_id),
        'room', (select rm.name from rooms rm where rm.id = v_clash.room_id)) end);
  end;

  v_moved := v_starts <> occ.starts_at or v_ends <> occ.ends_at;

  -- Everybody who is booked in, told. This is the reason the confirmation step
  -- exists: by the time we are here the caller has said yes to sending it.
  if v_moved and occ.booked_count > 0 then
    select * into v_set from studio_settings where studio_id = occ.studio_id;
    select s.timezone into v_tz from studios s where s.id = occ.studio_id;

    -- Significant: further than the studio's threshold, or landing on a
    -- different day in their own timezone. A class pushed fifteen minutes is a
    -- delay; a class pushed to the evening is a different arrangement.
    v_significant :=
      abs(extract(epoch from v_starts - occ.starts_at)) >
        coalesce(v_set.significant_move_hours, 2) * 3600
      or (v_starts at time zone v_tz)::date <> (occ.starts_at at time zone v_tz)::date;

    -- The undo window. A class that has just been moved and is now going back
    -- where it came from is somebody correcting a mis-drag, and the members
    -- should not hear about either leg of it. The first email has not gone out
    -- yet — the worker runs every minute — so it is withdrawn rather than
    -- apologised for.
    v_undo := exists (
      select 1 from audit_logs al
       where al.entity_id = occ.id
         and al.action = 'occurrence.moved'
         and al.created_at > now() - interval '60 seconds'
         and (al.before ->> 'starts_at')::timestamptz = v_starts);

    -- Any unsent notice about this class is now stale whatever happens next:
    -- it describes a move that has been superseded.
    delete from notifications
     where template_key = 'class_moved'
       and status = 'scheduled'
       and dedupe_key like 'class_moved:' || occ.id || ':%';

    if not v_undo then
      perform queue_class_moved(occ.id, occ.starts_at);

      if v_significant then
        -- Decision 2's reasoning, applied to a move: they agreed to a time and
        -- the time changed. They may cancel without it counting against them,
        -- right up to the class.
        update bookings
           set free_cancel_until = v_ends
         where occurrence_id = occ.id and status = 'booked';
      end if;
    end if;
  end if;

  -- TWO LEVELS, and only one of them is a warning.
  --
  -- The VALIDITY WINDOW is a hard refusal: an instructor whose stated pattern
  -- runs only through November has not agreed to be anywhere in December, and
  -- assigning them produces a class nobody turns up to teach. Decision 9's
  -- "warns, never blocks" is about a human overriding somebody's stated HOURS,
  -- which they can do knowing why — it was never about putting a person outside
  -- the dates they agreed to at all.
  if v_instr is not null
     and not instructor_valid_on(v_instr, (v_starts at time zone v_tz)::date) then
    return jsonb_build_object(
      'ok', false, 'requires_confirmation', false,
      'reason', 'outside_availability_dates',
      'blocked_by', jsonb_build_object(
        'who', (select display_name from instructors where id = v_instr),
        'on', to_char(v_starts at time zone v_tz, 'FMDay FMDD FMMonth YYYY')));
  end if;

  -- The day and time INSIDE that window stays a warning, per Decision 9.
  if v_instr is not null and not instructor_available_at(v_instr, v_starts, v_ends) then
    v_warnings := array_append(v_warnings, 'outside_availability');
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (occ.studio_id, auth.uid(), 'occurrence.moved', 'class_occurrences', occ.id,
          jsonb_build_object('starts_at', occ.starts_at, 'ends_at', occ.ends_at,
                             'instructor_id', occ.instructor_id, 'room_id', occ.room_id),
          jsonb_build_object('starts_at', v_starts, 'ends_at', v_ends,
                             'instructor_id', v_instr, 'room_id', v_room));

  return jsonb_build_object(
    'ok', true,
    'moved', v_moved,
    'staffing', v_staffing,
    'significant', v_significant,
    'undo', v_undo,
    'booked_count', occ.booked_count,
    'warnings', to_jsonb(v_warnings));
end $function$;

revoke execute on function move_occurrence(uuid, timestamptz, timestamptz, uuid, uuid, boolean, boolean)
  from public, anon, authenticated;
grant execute on function move_occurrence(uuid, timestamptz, timestamptz, uuid, uuid, boolean, boolean)
  to authenticated;
