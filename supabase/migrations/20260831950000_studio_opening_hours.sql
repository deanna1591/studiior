-- Decision 44 — studio opening hours.
--
-- A studio may set one opening window (open_time, close_time, studio-local).
-- Optional and unset by default: with no hours set, nothing changes anywhere
-- (the all_off canary proves it). A class is INSIDE hours when its START falls
-- within [open_time, close_time] — the end may run past close (Reform's last
-- class is 22:00-22:50 with a 22:00 close). Outside hours is a WARNING at
-- creation and on a drag, never a block.

alter table studio_settings
  add column if not exists open_time  time,
  add column if not exists close_time time;

-- Both null (not set) or both set with open before close. A studio closes when
-- the last class ENDS, so the window is on the START time; open < close is the
-- only ordering that makes a window.
alter table studio_settings
  drop constraint if exists studio_settings_opening_hours_ck;
alter table studio_settings
  add constraint studio_settings_opening_hours_ck check (
    (open_time is null and close_time is null)
    or (open_time is not null and close_time is not null and open_time < close_time));

-- The one predicate both create paths and the drag ask. Internal (service-role
-- only, no caller guard — it reads only the studio's OWN settings and answers a
-- boolean about a time). False when the studio has set no hours.
create or replace function occurrence_outside_hours(p_studio_id uuid, p_starts_at timestamptz)
returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v_tz text; v_open time; v_close time; v_start time;
begin
  select s.timezone, ss.open_time, ss.close_time
    into v_tz, v_open, v_close
    from studios s
    left join studio_settings ss on ss.studio_id = s.id
   where s.id = p_studio_id;
  if v_open is null or v_close is null then
    return false;
  end if;
  -- Studio-local wall time of the start; inside is [open, close] inclusive.
  v_start := (p_starts_at at time zone v_tz)::time;
  return v_start < v_open or v_start > v_close;
end $$;
revoke execute on function occurrence_outside_hours(uuid, timestamptz) from public, anon, authenticated;
grant  execute on function occurrence_outside_hours(uuid, timestamptz) to service_role;

-- create_occurrence, re-issued from its newest definition (490000) with the
-- outside_hours warning. Same 9-arg signature, so create-or-replace keeps the ACL.

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

  -- Decision 44: a class whose START time falls outside the studio's opening
  -- hours is a WARNING, never a block — the same posture as the availability
  -- warning above (Decision 37 amendment (c)). occurrence_outside_hours is false
  -- when the studio has set no hours, so a studio that set none sees nothing.
  if occurrence_outside_hours(p_studio_id, p_starts_at) then
    v_warnings := array_append(v_warnings, 'outside_hours');
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

-- move_occurrence, re-issued from its newest definition (170000) with the
-- outside_hours warning on a drag/retime. create-or-replace keeps the ACL.
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

  -- TWO LEVELS, and only one of them is a warning.
  --
  -- THIS CHECK USED TO SIT AFTER THE UPDATE. It returned ok:false with the row
  -- already reassigned, so a refusal for outside_availability_dates was a
  -- refusal in words only: proved on the seed before migration 112 moved it —
  -- instructor 41's window ended yesterday, move_occurrence() answered
  -- {"ok": false, "reason": "outside_availability_dates"}, and the class was
  -- 41's afterwards. A refusal has to come before anything is written.
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

  -- The day and time INSIDE that window stays a warning, per Decision 9.
  if v_instr is not null and not instructor_available_at(v_instr, v_starts, v_ends) then
    v_warnings := array_append(v_warnings, 'outside_availability');
  end if;

  -- Decision 44: outside the studio's opening hours is a warning here too,
  -- since a drag surfaces the availability warning; false when hours are unset.
  if occurrence_outside_hours(occ.studio_id, v_starts) then
    v_warnings := array_append(v_warnings, 'outside_hours');
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (occ.studio_id, auth.uid(), 'occurrence.moved', 'class_occurrences', occ.id,
          jsonb_build_object('starts_at', occ.starts_at, 'ends_at', occ.ends_at,
                             'instructor_id', occ.instructor_id, 'room_id', occ.room_id),
          jsonb_build_object('starts_at', v_starts, 'ends_at', v_ends,
                             'instructor_id', v_instr, 'room_id', v_room));

  -- Decision 25: a class in a PUBLISHED month whose instructor or time has
  -- changed is a roster that no longer matches what its instructor was sent, so
  -- they are told. Gated on the studio's switch so a studio that never publishes
  -- keeps working exactly as today — a drag-assign has never emailed anybody.
  -- queue_instructor_assigned() reads the row as it now is, refuses a draft
  -- month, and keys on instructor AND start time, so the same person moved to a
  -- new time hears about the new time and nobody hears twice about one change.
  if v_instr is not null
     and (v_moved or v_instr is distinct from occ.instructor_id)
     and publication_enabled(occ.studio_id) then
    perform queue_instructor_assigned(occ.id);
  end if;

  return jsonb_build_object(
    'ok', true,
    'moved', v_moved,
    'staffing', v_staffing,
    'significant', v_significant,
    'undo', v_undo,
    'booked_count', occ.booked_count,
    'warnings', to_jsonb(v_warnings));
end $function$;

-- 9e. commitment_pending() — a draft month is not decided. From 20260830910000.
create or replace function commitment_pending(p_studio_id uuid)
returns table (occ_id uuid, occ_name text, starts_at timestamptz, local_when text,
               tier guarantee_tier, booked int, minimum int, short_by int,
               due_at timestamptz, cutoff_shape text, past_due boolean,
               instructor_id uuid, is_adjacent boolean)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_tz text; s studio_settings%rowtype;
begin
  if not coalesce(is_manager_up(p_studio_id), false) and not is_service_context() then
    raise exception 'only owners and managers see this' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  if v_tz is null then raise exception 'no such studio' using errcode = 'PT404'; end if;
  select * into s from studio_settings where studio_id = p_studio_id;
  -- Either switch puts classes in scope; occurrence_guarantee() decides which
  -- tiers those are. Neither means nothing is ever pending, which is what
  -- "sees no change" means.
  if not coalesce(s.guarantees_enabled, false)
     and not coalesce(s.flex_enabled, false) then
    return;
  end if;

  return query
  select o.id, o.name, o.starts_at,
         to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMon, HH24:MI'),
         g.tier, b.n, g.minimum, greatest(0, g.minimum - b.n),
         g.cutoff_at, g.cutoff_shape, now() >= g.cutoff_at,
         o.instructor_id, occurrence_is_adjacent(o.id)
    from class_occurrences o
    cross join lateral occurrence_guarantee(o.id) g
    cross join lateral (
      select count(*)::int as n from bookings bk
       where bk.occurrence_id = o.id
         and bk.status in ('booked','attended','no_show','pending_payment')
    ) b
   where o.studio_id = p_studio_id
     and o.status = 'scheduled'
     and o.committed_at is null
     and o.starts_at > now()
     -- 'always' is included: it commits at its start time. Only a class with no
     -- cutoff at all — a studio with both switches off — is out of scope.
     and g.cutoff_at is not null
     -- Decision 25: a draft month is not decided. Nobody can book a class in
     -- it, so a flex class evaluated there would be cancelled for want of the
     -- bookings it was never allowed to take.
     and occurrence_published(o.id)
   order by o.starts_at;
end $$;

-- anon surface stays EXACTLY TWELVE — occurrence_outside_hours is service-role only.
do $$
declare v_n int;
begin
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and has_function_privilege('anon', p.oid, 'execute');
  if v_n <> 12 then
    raise exception 'anon surface is %, expected exactly twelve', v_n;
  end if;
end $$;

