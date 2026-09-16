-- =============================================================================
-- 144 — a one-off class can carry a guarantee tier, like a series.
-- =============================================================================
-- create_occurrence() (089, the shared create gate) always made a class core:
-- it never took a tier, so a Saturday workshop or a cover class could not be
-- set to run regardless (always) or only if booked (flex). The series form has
-- had the control since 138; the one-off form and the calendar's click-to-create
-- had the gap.
--
-- p_tier + p_min_bookings, set the same way set_series_guarantee() sets them:
-- flex => flex=true + minimum_bookings; core => core_min_bookings; always => a
-- class that runs whatever the numbers are. The UI only shows the control when
-- guarantees or flex is on, so a studio that turned nothing on sends nothing and
-- gets core, exactly as before.
--
-- THE STANDALONE-FLEX WARNING. A one-off flex class usually has no core class of
-- the same instructor beside it — precisely the standalone case
-- occurrence_is_adjacent_run() flags and the instructor agreement pays standby
-- for. So a flex one-off that lands standalone comes back with a `standalone_flex`
-- warning, the one-off analog of set_series_guarantee's standalone_count. A
-- warning, never a refusal — adjacency is dynamic, and a later class beside it
-- clears it.
-- =============================================================================

-- Two new params with defaults do NOT replace the 7-arg signature, they add an
-- overload — and a 7-arg call then matches both and fails as ambiguous (028's
-- trap). Drop the old signature first; a drop discards the ACL, re-asserted at
-- the bottom.
drop function if exists create_occurrence(uuid, uuid, timestamptz, timestamptz, uuid, uuid, int);

create or replace function create_occurrence(
  p_studio_id     uuid,
  p_class_type_id uuid,
  p_starts_at     timestamptz,
  p_ends_at       timestamptz,
  p_instructor_id uuid default null,
  p_room_id       uuid default null,
  p_capacity      int  default null,
  -- 144: the guarantee tier, defaulting to core so every existing caller is
  -- unchanged. A studio with neither switch on never sends anything but core.
  p_tier          guarantee_tier default 'core',
  p_min_bookings  int  default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  ct        class_types%rowtype;
  v_loc     uuid;
  v_room    uuid;
  v_tz      text;
  v_cap     int;
  v_id      uuid;
  v_rooms   int;
  v_clash   class_occurrences%rowtype;
  v_conflict text;
  v_warnings text[] := '{}';
  v_flex_on boolean;
  v_min     int;
  v_core_min int;
begin
  if p_min_bookings is not null and p_min_bookings < 0 then
    raise exception 'a minimum cannot be negative' using errcode = 'PT422';
  end if;
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers change the timetable' using errcode = 'PT403';
  end if;
  if studio_is_locked(p_studio_id) then
    raise exception 'this studio''s Studiior subscription is not active'
      using errcode = 'PT402',
            hint = 'Reactivate it from Billing. Nothing has been deleted.';
  end if;

  select timezone into v_tz from studios where id = p_studio_id;
  select * into ct from class_types
   where id = p_class_type_id and studio_id = p_studio_id and status = 'active';
  if ct.id is null then
    raise exception 'pick a class type that belongs to this studio and is not archived'
      using errcode = 'PT422';
  end if;

  if p_ends_at <= p_starts_at then
    raise exception 'a class cannot end before it starts' using errcode = 'PT400';
  end if;

  select id into v_loc from locations
   where studio_id = p_studio_id and is_primary order by created_at limit 1;
  if v_loc is null then
    raise exception 'this studio has no location to put a class in' using errcode = 'PT422';
  end if;

  -- A CLASS WITH NO ROOM SKIPS THE EXCLUSION CONSTRAINT, which is partial on a
  -- non-null room_id — so "no room" is not a neutral default, it is opting out
  -- of the only thing that stops two classes in one space. One room: use it,
  -- because asking a studio with one room which room is a question with one
  -- answer. Several: refuse until told.
  select count(*) into v_rooms from rooms
   where studio_id = p_studio_id and status = 'active';
  v_room := p_room_id;
  if v_room is null then
    if v_rooms = 1 then
      select id into v_room from rooms where studio_id = p_studio_id and status = 'active';
    elsif v_rooms > 1 then
      return jsonb_build_object('ok', false, 'reason', 'room_required',
        'rooms', (select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'capacity', capacity)
                                   order by name)
                    from rooms where studio_id = p_studio_id and status = 'active'));
    end if;
  end if;
  if v_room is not null
     and not exists (select 1 from rooms
                      where id = v_room and studio_id = p_studio_id and status = 'active') then
    raise exception 'that room does not belong to this studio' using errcode = 'PT422';
  end if;

  if p_instructor_id is not null
     and not exists (select 1 from instructors
                      where id = p_instructor_id and studio_id = p_studio_id and status = 'active') then
    raise exception 'that instructor does not belong to this studio' using errcode = 'PT422';
  end if;

  -- THE VALIDITY WINDOW IS A HARD REFUSAL. Decision 18: an instructor whose
  -- pattern runs only through November has not agreed to be anywhere in
  -- December, and creating a class for them there produces one nobody turns up
  -- to teach. Same gate, same reason string, as move_occurrence().
  if p_instructor_id is not null
     and not instructor_valid_on(p_instructor_id, (p_starts_at at time zone v_tz)::date) then
    return jsonb_build_object(
      'ok', false, 'reason', 'outside_availability_dates',
      'blocked_by', jsonb_build_object(
        'who', (select display_name from instructors where id = p_instructor_id),
        'on', to_char(p_starts_at at time zone v_tz, 'FMDay FMDD FMMonth YYYY')));
  end if;

  -- The day and time INSIDE that window is a WARNING, per Decision 9: a human
  -- assigning outside stated hours knows what they are doing.
  if p_instructor_id is not null
     and not instructor_available_at(p_instructor_id, p_starts_at, p_ends_at) then
    -- array_append, NOT `|| 'literal'`. An untyped literal on the right makes
    -- Postgres resolve `anyarray || anyarray` and try to parse the string as an
    -- array: `22P02 malformed array literal: "outside_availability"`. The same
    -- line in move_occurrence() has been raising since it was written; 090.
    v_warnings := array_append(v_warnings, 'outside_availability');
  end if;

  v_cap := coalesce(p_capacity, ct.default_capacity,
                    (select capacity from rooms where id = v_room), 10);
  if v_cap < 1 then
    raise exception 'a class needs room for at least one person' using errcode = 'PT422';
  end if;

  -- 144: the tier, set the set_series_guarantee() way. A flex minimum falls back
  -- to the studio's flex_min_bookings, a core one to core_min_bookings, so a flex
  -- one-off actually has a threshold to be measured against.
  select coalesce(flex_enabled, false),
         coalesce(p_min_bookings, flex_min_bookings, 1),
         coalesce(p_min_bookings, core_min_bookings, 1)
    into v_flex_on, v_min, v_core_min
    from studio_settings where studio_id = p_studio_id;
  v_flex_on := coalesce(v_flex_on, false);

  begin
    insert into class_occurrences (
      studio_id, location_id, class_type_id, name, instructor_id, room_id,
      capacity, starts_at, ends_at,
      guarantee_tier, flex, minimum_bookings, core_min_bookings)
    values (p_studio_id, v_loc, ct.id, ct.name, p_instructor_id, v_room,
            v_cap, p_starts_at, p_ends_at,
            p_tier, (p_tier = 'flex'),
            case when p_tier = 'flex' then v_min end,
            case when p_tier = 'core' then v_core_min end)
    returning id into v_id;
  exception when exclusion_violation then
    get stacked diagnostics v_conflict = constraint_name;
    -- Named, with the class actually in the way. "Conflict detected" tells
    -- somebody holding a mouse nothing they can act on.
    select * into v_clash from class_occurrences o
     where o.status <> 'cancelled'
       and tstzrange(o.starts_at, o.ends_at) && tstzrange(p_starts_at, p_ends_at)
       and ((v_conflict = 'occ_room_no_overlap'       and o.room_id = v_room)
         or (v_conflict = 'occ_instructor_no_overlap' and o.instructor_id = p_instructor_id))
     limit 1;
    return jsonb_build_object(
      'ok', false,
      'reason', case when v_conflict = 'occ_room_no_overlap'
                     then 'room_busy' else 'instructor_busy' end,
      'blocked_by', case when v_clash.id is null then null else jsonb_build_object(
        'occurrence_id', v_clash.id,
        'name', v_clash.name,
        'at', to_char(v_clash.starts_at at time zone v_tz, 'HH24:MI'),
        'who', (select i.display_name from instructors i where i.id = v_clash.instructor_id),
        'room', (select rm.name from rooms rm where rm.id = v_clash.room_id)) end);
  end;

  -- 144: a flex one-off with nothing of the instructor's beside it is the
  -- standalone case the instructor agreement pays standby for. Reported as a
  -- warning (never a refusal — a later class beside it clears it), the one-off
  -- analog of set_series_guarantee's standalone_count. Only where flex is
  -- actually on, so a flex tier stored inert at a flex-off studio says nothing.
  if p_tier = 'flex' and v_flex_on and not occurrence_is_adjacent_run(v_id) then
    v_warnings := array_append(v_warnings, 'standalone_flex');
  end if;

  -- Decision 25: a class added to an already-published month is bookable at
  -- once (month_published() says so) and its instructor is told, because the
  -- roster they were sent no longer lists everything. Gated on the studio's
  -- switch and not only on the month, so a studio that never publishes keeps
  -- working exactly as today — this path has never told anybody. Inside the
  -- call, queue_instructor_assigned() refuses a draft month and an instructor
  -- with no login.
  if p_instructor_id is not null and publication_enabled(p_studio_id) then
    perform queue_instructor_assigned(v_id);
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (p_studio_id, auth.uid(), 'occurrence.created', 'class_occurrences', v_id,
          jsonb_build_object('starts_at', p_starts_at, 'ends_at', p_ends_at,
                             'instructor_id', p_instructor_id, 'room_id', v_room,
                             'class_type_id', ct.id, 'capacity', v_cap,
                             'tier', p_tier, 'warnings', to_jsonb(v_warnings)));

  return jsonb_build_object(
    'ok', true, 'occurrence_id', v_id,
    -- tg_derive_staffing() decides this from instructor_id; read back rather
    -- than assumed, so "open shift" on the screen is what the row actually says.
    'staffing', (select staffing from class_occurrences where id = v_id),
    'capacity', v_cap, 'room_id', v_room,
    'local_when', to_char(p_starts_at at time zone v_tz, 'FMDay FMDD FMMon, HH24:MI'),
    'warnings', to_jsonb(v_warnings));
end $$;
;

-- The drop discarded the ACL; re-assert it (manager-callable, revoked from anon).
revoke execute on function create_occurrence(uuid, uuid, timestamptz, timestamptz, uuid, uuid, int, guarantee_tier, int)
  from public, anon;
grant  execute on function create_occurrence(uuid, uuid, timestamptz, timestamptz, uuid, uuid, int, guarantee_tier, int)
  to authenticated, service_role;
