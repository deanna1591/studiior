-- =============================================================================
-- 068  The horizon is days, it is 60, and it is somewhere a studio can see it
-- =============================================================================
-- `occurrence_horizon_months` has been a studio setting since migration 057 and
-- **no screen has ever read or written it**. The same shape as
-- `instructor_availability` before Decision 18 and `class_series` before 064: a
-- column with a default and no way to reach it. Its default of 12 months is why
-- Reform Collective is carrying **1,421 open classes through September 2027
-- that nobody has agreed to teach and any member can book**.
--
-- Twelve months was never the right default for a boutique studio. The current
-- month plus one ahead is how they actually plan, and it is the horizon the
-- monthly availability cycle in migration 066 collects for. Sixty days, in
-- DAYS: "two months" from the 31st is a question with three answers, and a
-- horizon is a rolling window rather than a calendar boundary.
--
-- WHAT SHORTENING IT USED TO DO: nothing. Proved before writing any of this —
-- set to 2 months, ran the nightly job, and the furthest class was still
-- 2027-09-09 with 680 still scheduled. `generate_occurrences()` only ever
-- inserts. So the setting could only ever grow the calendar.
--
-- DELETED, NOT CANCELLED, and the reason is stronger than it first looks. A
-- cancelled row keeps its `series_slot_at`, and the unique index on
-- (series_id, series_slot_at) is what makes regeneration idempotent — so a
-- studio that shortens the horizon and later lengthens it again would find the
-- generator SKIPPING every cancelled slot and the calendar permanently holed.
-- Proved: cancel one slot, restore the horizon, regenerate — `created: 0`, and
-- the slot still holds one cancelled row.
--
--   (A cancelled class does NOT hold its room, incidentally: both exclusion
--   constraints are partial on `status <> 'cancelled'`. The case for deleting
--   is the slot index, not the room.)
--
-- WHAT IS NEVER DELETED. Only what the generator itself made and nobody has
-- since touched:
--
--   * a class with a BOOKING or a check-in on it — the whole edit is refused
--     and names them, confirmed or not
--   * a class somebody has moved (`is_exception`) — §5's rule everywhere else
--     in this codebase, and no reason for it to stop here
--   * a class a human assigned an instructor to (`assigned_by`) — 061's rule
--     that a person choosing a person is a decision the machinery does not undo
--   * a ONE-OFF class with no series: creating a class eight months out is a
--     deliberate act, and a horizon that swept those away would be deleting
--     what somebody typed
-- =============================================================================

alter table studio_settings
  add column if not exists occurrence_horizon_days int not null default 60;
alter table studio_settings drop constraint if exists studio_settings_horizon_days_check;
alter table studio_settings add constraint studio_settings_horizon_days_check
  check (occurrence_horizon_days between 7 and 730);

comment on column studio_settings.occurrence_horizon_days is
  'How far ahead the nightly job materialises a series, in days. 60 = this '
  'month and the next, which is how a boutique studio plans and what the '
  'monthly availability cycle collects for. Changed through '
  'set_occurrence_horizon(), which also removes what falls outside it.';

-- Existing studios come to 60 as well. There is exactly one real studio and its
-- twelve-month tail is the reason this migration exists; leaving the others on
-- a default they never chose would be keeping the bug for everybody but Reform.
update studio_settings set occurrence_horizon_days = 60;

-- The months column had two readers, both rebuilt below, and no writer anywhere
-- in the product. Two horizon columns where one is dead is how the next person
-- reads the wrong one.
alter table studio_settings drop column if exists occurrence_horizon_months;

-- -----------------------------------------------------------------------------
-- The generator, in days
-- -----------------------------------------------------------------------------
-- Rebuilt from 064's FILE, which is the newest that defines it. The only change
-- is the horizon: days rather than months, and the parameter with it.
drop function if exists generate_occurrences(uuid, int, date);

create function generate_occurrences(
  p_series_id uuid, p_horizon_days int default null, p_from date default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  ser        class_series%rowtype;
  v_tz       text;
  v_days_out int;
  v_days     int[];
  v_interval int;
  v_until    date;
  v_today    date;
  v_from     date;
  v_to       date;
  v_anchor   date;
  d          date;
  v_start    timestamptz;
  v_created  int := 0;
  v_skipped  int := 0;
  v_conf     jsonb := '[]'::jsonb;
begin
  select * into ser from class_series where id = p_series_id;
  if not found then
    raise exception 'no such series' using errcode = 'PT404';
  end if;
  if not is_manager_up(ser.studio_id)
     and not is_platform_admin()
     and not is_service_context() then
    raise exception 'only owners, managers or the scheduler may materialise a timetable'
      using errcode = 'PT403';
  end if;

  select timezone into v_tz from studios where id = ser.studio_id;
  select coalesce(p_horizon_days, occurrence_horizon_days, 60)
    into v_days_out from studio_settings where studio_id = ser.studio_id;
  v_days_out := coalesce(v_days_out, coalesce(p_horizon_days, 60));

  v_days     := rrule_weekdays(ser.rrule);
  v_interval := coalesce(nullif(rrule_part(ser.rrule, 'INTERVAL'), '')::int, 1);
  v_until    := rrule_last_date(ser.rrule, ser.starts_on);

  -- Today IN THE STUDIO'S ZONE. A horizon measured from the server's date is a
  -- different horizon for every studio east of London.
  v_today := (now() at time zone v_tz)::date;

  -- Never backfill the past. p_from is how update_series() stops the generator
  -- undoing the one thing an edit promises: that it changes nothing before its
  -- effective date.
  v_from := greatest(ser.starts_on, v_today, coalesce(p_from, '-infinity'::date));
  v_to   := least(
    v_today + v_days_out,
    coalesce(ser.ends_on,  'infinity'::date),
    coalesce(v_until,      'infinity'::date));

  if ser.status <> 'active' then
    return jsonb_build_object('series_id', ser.id, 'created', 0,
      'skipped', 0, 'conflicts', '[]'::jsonb, 'reason', 'series is ' || ser.status);
  end if;

  v_anchor := ser.starts_on - extract(dow from ser.starts_on)::int;

  d := v_from;
  while d <= v_to loop
    if extract(dow from d)::int = any (v_days)
       and (v_interval = 1
            or ((d - extract(dow from d)::int - v_anchor) / 7) % v_interval = 0)
    then
      -- Local wall clock, then interpreted in the zone. NOT starts_at plus an
      -- interval: that drifts an hour across a DST boundary and a 07:00 class
      -- stops being a 07:00 class.
      v_start := (d + ser.time_of_day) at time zone v_tz;

      begin
        insert into class_occurrences
          (studio_id, location_id, series_id, class_type_id, name, description,
           instructor_id, room_id, capacity, starts_at, ends_at,
           status, staffing, series_slot_at)
        values (ser.studio_id, ser.location_id, ser.id, ser.class_type_id,
                ser.name, ser.description, ser.instructor_id, ser.room_id,
                ser.capacity, v_start,
                v_start + make_interval(mins => ser.duration_minutes),
                'scheduled',
                (case when ser.instructor_id is null then 'open' else 'assigned' end)::staffing_state,
                v_start);
        v_created := v_created + 1;
      exception
        when unique_violation then
          v_skipped := v_skipped + 1;
        when exclusion_violation then
          v_conf := v_conf || jsonb_build_object(
            'starts_at', v_start,
            'local', to_char(v_start at time zone v_tz, 'YYYY-MM-DD HH24:MI'),
            'reason', case when sqlerrm like '%occ_room_no_overlap%'
                           then 'room_busy' else 'instructor_busy' end);
      end;
    end if;
    d := d + 1;
  end loop;

  return jsonb_build_object(
    'series_id', ser.id,
    'created',   v_created,
    'skipped',   v_skipped,
    'conflicts', v_conf,
    'horizon_to', v_to);
end $$;

-- The drop threw the ACL away, so 057's revoke and its grant both come back.
revoke execute on function generate_occurrences(uuid, int, date) from public, anon, authenticated;
grant  execute on function generate_occurrences(uuid, int, date) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- update_series, which reads the horizon too
-- -----------------------------------------------------------------------------
-- Lifted from 064's file with only the horizon lines changed. Everything else
-- is 064's text: rebuilding it from this database would be rebuilding it from
-- something already carrying a draft of the migration being written.
create or replace function update_series(
  p_series_id        uuid,
  p_name             text,
  p_class_type_id    uuid,
  p_room_id          uuid,
  p_instructor_id    uuid,
  p_capacity         int,
  p_duration_minutes int,
  p_rrule            text,
  p_starts_on        date,
  p_ends_on          date,
  p_time_of_day      time,
  p_description      text,
  p_effective_from   date default null,
  p_confirm          boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
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

  return jsonb_build_object(
    'ok', true,
    'effective_from', v_from,
    'moved', v_moves, 'cancelled', v_cancels, 'restored', v_restores,
    'added', coalesce((v_gen ->> 'created')::int, 0),
    'unchanged', v_same, 'left_as_edited', v_exc,
    'members_emailed', v_emails,
    'conflicts', v_conf || coalesce(v_gen -> 'conflicts', '[]'::jsonb));
end $$;

-- -----------------------------------------------------------------------------
-- Changing it, and clearing up after it
-- -----------------------------------------------------------------------------
-- Two-step, the same shape as archive_record() and purge_demo_data(): the first
-- call says what it will remove and changes nothing. Setting the horizon and
-- trimming to it are ONE action deliberately — a setting that shortens and
-- leaves 1,421 classes standing is the bug this migration exists to fix, and
-- splitting them would recreate it with an extra button.
create or replace function set_occurrence_horizon(
  p_studio_id uuid, p_days int, p_confirm boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tz     text;
  v_today  date;
  v_cut    date;
  v_now    int;
  v_del    int;
  v_gen    jsonb;
  v_blocked jsonb;
  v_edited  jsonb;
  v_manual  jsonb;
  v_far    date;
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers change how far ahead the timetable runs'
      using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  if v_tz is null then
    raise exception 'no such studio' using errcode = 'PT404';
  end if;
  if p_days is null or p_days < 7 or p_days > 730 then
    raise exception 'the horizon has to be between 7 and 730 days' using errcode = 'PT422';
  end if;

  v_today := (now() at time zone v_tz)::date;
  v_cut   := v_today + p_days;

  select count(*) into v_now from class_occurrences
   where studio_id = p_studio_id and status = 'scheduled'
     and (starts_at at time zone v_tz)::date > v_today;
  select max((starts_at at time zone v_tz)::date) into v_far from class_occurrences
   where studio_id = p_studio_id and status = 'scheduled';

  -- Everything the generator made, beyond the new edge, that nobody has touched.
  with beyond as (
    select o.id, o.name, o.starts_at, o.is_exception, o.assigned_by,
           to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMon YYYY, HH24:MI') as local,
           -- Counted from the BOOKINGS, not from o.booked_count. The cache is
           -- maintained by book_class() and an import or a hand-written row can
           -- leave it behind — and a refusal that says "0 booked" beside a class
           -- it is refusing to delete because somebody is booked is worse than
           -- no number at all.
           (select count(*) from bookings b
             where b.occurrence_id = o.id
               and b.status in ('booked','waitlisted','pending_payment')) as live_booked,
           exists (select 1 from bookings b
                    where b.occurrence_id = o.id
                      and b.status in ('booked','waitlisted','pending_payment')) as has_booking,
           exists (select 1 from check_ins c where c.occurrence_id = o.id) as has_checkin
      from class_occurrences o
     where o.studio_id = p_studio_id
       and o.status = 'scheduled'
       -- Series-generated only. A one-off class somebody typed for eight months
       -- out is a deliberate act, not something a horizon may sweep away.
       and o.series_id is not null
       and (o.starts_at at time zone v_tz)::date > v_cut
  )
  select
    coalesce((select jsonb_agg(jsonb_build_object(
               'occurrence_id', id, 'name', name, 'local', local, 'booked', live_booked)
             order by starts_at)
        from beyond where has_booking or has_checkin), '[]'::jsonb),
    coalesce((select count(*) from beyond
               where not (has_booking or has_checkin) and is_exception), 0),
    coalesce((select count(*) from beyond
               where not (has_booking or has_checkin) and not is_exception
                 and assigned_by is not null), 0),
    coalesce((select count(*) from beyond
               where not (has_booking or has_checkin) and not is_exception
                 and assigned_by is null), 0)
    into v_blocked, v_edited, v_manual, v_del;

  -- A class somebody is booked on must not vanish because a setting moved.
  -- Refused whether or not the studio confirmed: this is not a warning.
  if jsonb_array_length(v_blocked) > 0 then
    return jsonb_build_object(
      'ok', false, 'reason', 'members_booked_beyond_horizon',
      'days', p_days, 'cutoff', v_cut, 'blocked', v_blocked,
      'hint', 'Cancel those classes on the calendar first, so the members are told.');
  end if;

  if not p_confirm then
    return jsonb_build_object(
      'ok', false, 'requires_confirmation', true,
      'days', p_days, 'cutoff', v_cut,
      'scheduled_now', v_now, 'furthest_now', v_far,
      'will_delete', v_del,
      'kept_edited', v_edited, 'kept_manual', v_manual);
  end if;

  update studio_settings set occurrence_horizon_days = p_days, updated_at = now()
   where studio_id = p_studio_id;

  -- DELETED, not cancelled: a cancelled row keeps its series_slot_at, and the
  -- unique index on (series_id, series_slot_at) would then make the hole
  -- permanent if the studio ever lengthened the horizon again.
  delete from class_occurrences o
   where o.studio_id = p_studio_id
     and o.status = 'scheduled'
     and o.series_id is not null
     and not o.is_exception
     and o.assigned_by is null
     and (o.starts_at at time zone v_tz)::date > v_cut
     and not exists (select 1 from bookings b
                      where b.occurrence_id = o.id
                        and b.status in ('booked','waitlisted','pending_payment'))
     and not exists (select 1 from check_ins c where c.occurrence_id = o.id);

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (p_studio_id, auth.uid(), 'horizon.set', 'studios', p_studio_id,
          jsonb_build_object('days', p_days, 'cutoff', v_cut, 'deleted', v_del));

  -- Lengthening it is the other direction, and the generator is what fills it.
  v_gen := generate_all_occurrences_for(p_studio_id);

  return jsonb_build_object(
    'ok', true, 'days', p_days, 'cutoff', v_cut,
    'deleted', v_del, 'kept_edited', v_edited, 'kept_manual', v_manual,
    'created', coalesce((v_gen ->> 'created')::int, 0),
    'furthest_now', (select max((starts_at at time zone v_tz)::date)
                       from class_occurrences
                      where studio_id = p_studio_id and status = 'scheduled'));
end $$;

-- One studio's series, materialised. `generate_all_occurrences()` claims a
-- job_runs row per studio per day, which is right for a cron and wrong for a
-- studio pressing a button — the second press of the day would silently do
-- nothing.
create or replace function generate_all_occurrences_for(p_studio_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; v_series int := 0; v jsonb;
begin
  if not coalesce(is_manager_up(p_studio_id), false) and not is_service_context() then
    raise exception 'only owners and managers materialise a timetable' using errcode = 'PT403';
  end if;
  for r in select id from class_series
            where studio_id = p_studio_id and status = 'active' order by id
  loop
    v := generate_occurrences(r.id);
    n := n + coalesce((v ->> 'created')::int, 0);
    v_series := v_series + 1;
  end loop;
  return jsonb_build_object('series', v_series, 'created', n);
end $$;

revoke execute on function set_occurrence_horizon(uuid, int, boolean) from public, anon, authenticated;
grant  execute on function set_occurrence_horizon(uuid, int, boolean) to authenticated;
revoke execute on function generate_all_occurrences_for(uuid) from public, anon, authenticated;
grant  execute on function generate_all_occurrences_for(uuid) to authenticated, service_role;
