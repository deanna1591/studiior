-- =============================================================================
-- 064  Editing a recurring class, and a COUNT that means what it says
-- =============================================================================
-- `class_series` has had a schema since migration 001 and no form since. The
-- table only has rows because the demo generator writes them — the same shape
-- as `instructor_availability` before Decision 18, `timeline_events` before
-- 059 and `member_goals.current_value` before that.
--
-- Building the form meant asking what an edit currently DOES, and the answer
-- is worse than "nothing". Proved against a real series before writing a line
-- of this file:
--
--   insert  FREQ=WEEKLY;BYDAY=TU at 07:00   ->  52 occurrences, all 07:00
--   update  time_of_day = 08:00             -> 104 occurrences, 07:00 AND 08:00
--   update  capacity    = 20                -> 104 occurrences, all still 8
--
-- 057's trigger only ever GENERATES. So moving a class doubles the studio's
-- timetable for a year, and changing its capacity does nothing at all to the
-- classes already on the calendar. Data model §5 records "this and future /
-- entire series editing is still not built"; what it does not record is that
-- the absence is not inert. A form that "just writes the row correctly" would
-- hand every studio a duplicated year through a button.
--
-- THE SECOND BUG. COUNT was implemented as "stop after N inserts this run",
-- and the run starts at today rather than at the series' own beginning. So the
-- nightly job tops the series back up to N every night and a COUNT=4 series
-- runs forever. Proved: 4 occurrences, then 8 after one later run, climbing.
-- COUNT is now resolved ONCE, to the date of the Nth recurrence, and from then
-- on it is an end date like any other. A rule that ends cannot depend on how
-- often the cron happened to run.
--
-- WHAT AN EDIT MAY DO, stated rather than discovered:
--
--   * The past is never rewritten. A class forty people attended at 07:00 was
--     at 07:00, and no edit to a series makes that untrue. So §5's "entire
--     series" is deliberately NOT offered: the honest modes are "this class
--     only" — which is `move_occurrence()` on the calendar, and already built —
--     and "from a date forward", which is this.
--   * An occurrence somebody has already moved is left alone. That is what
--     `is_exception` has meant since 057 and the studio has already decided
--     about that row.
--   * A retimed class MOVES rather than being re-created beside itself, and it
--     moves through `move_occurrence()` — the one function that moves a class,
--     which owes Decision 2's free cancellation and the `class_moved` email.
--     One path, not two that match.
--   * A class the new rule no longer produces is CANCELLED, and only when
--     nobody has booked it. With members on it the whole edit is refused and
--     names them: §5's rule that the system never silently picks who loses a
--     spot is about capacity, and dropping their Tuesday entirely is the same
--     act with a bigger blast radius. `queue_occurrence_cancelled()` has
--     existed unused since migration 030 and this is still not its caller —
--     the classes it cancels have nobody to write to.
--   * Capacity may not fall below what is booked (§5), and the refusal names
--     the classes in the way rather than reporting a number.
--
-- Two-step, like `archive_record()` and `purge_demo_data()`: the first call
-- says what it will do and changes nothing.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Where a rule stops
-- -----------------------------------------------------------------------------
-- UNTIL and COUNT are two spellings of one fact, and only one of them can be
-- read off the rule directly. Folding COUNT into a date here means every
-- caller — the generator, the editor, the preview — asks one question and gets
-- one answer, instead of each re-deriving "have we made enough yet" from
-- whatever rows happen to exist when it runs.
create or replace function rrule_last_date(p_rrule text, p_starts_on date)
returns date language plpgsql immutable set search_path = public as $$
declare
  v_days     int[] := rrule_weekdays(p_rrule);   -- raises PT422 on anything else
  v_interval int   := coalesce(nullif(rrule_part(p_rrule, 'INTERVAL'), '')::int, 1);
  v_until    date  := nullif(left(coalesce(rrule_part(p_rrule, 'UNTIL'), ''), 8), '')::date;
  v_count    int   := nullif(rrule_part(p_rrule, 'COUNT'), '')::int;
  v_anchor   date  := p_starts_on - extract(dow from p_starts_on)::int;
  d          date;
  n          int := 0;
begin
  if v_interval < 1 then
    raise exception 'INTERVAL must be at least 1' using errcode = 'PT422';
  end if;
  if v_count is null then
    return v_until;
  end if;
  if v_count < 1 then
    raise exception 'COUNT must be at least 1' using errcode = 'PT422';
  end if;

  -- Bounded: a weekly rule with N occurrences cannot need more than N
  -- interval-weeks plus one to reach them, however few days BYDAY names.
  d := p_starts_on;
  while d <= p_starts_on + ((v_count + 1) * v_interval * 7) loop
    if extract(dow from d)::int = any (v_days)
       and (v_interval = 1
            or ((d - extract(dow from d)::int - v_anchor) / 7) % v_interval = 0) then
      n := n + 1;
      if n >= v_count then
        return case when v_until is null then d else least(d, v_until) end;
      end if;
    end if;
    d := d + 1;
  end loop;
  return v_until;
end $$;

-- -----------------------------------------------------------------------------
-- Does this rule produce a class on this day
-- -----------------------------------------------------------------------------
-- The generator walks days forward; the editor has to ask about one day it
-- already has an occurrence for. Same question, so one implementation — two
-- would agree the day they were written.
create or replace function series_rule_matches(
  p_rrule text, p_starts_on date, p_ends_on date, p_day date
) returns boolean language plpgsql immutable set search_path = public as $$
declare
  v_days     int[] := rrule_weekdays(p_rrule);
  v_interval int   := coalesce(nullif(rrule_part(p_rrule, 'INTERVAL'), '')::int, 1);
  v_last     date  := rrule_last_date(p_rrule, p_starts_on);
  v_anchor   date  := p_starts_on - extract(dow from p_starts_on)::int;
begin
  if p_day < p_starts_on then return false; end if;
  if p_ends_on is not null and p_day > p_ends_on then return false; end if;
  if v_last    is not null and p_day > v_last   then return false; end if;
  if not (extract(dow from p_day)::int = any (v_days)) then return false; end if;
  return v_interval = 1
      or ((p_day - extract(dow from p_day)::int - v_anchor) / 7) % v_interval = 0;
end $$;

-- -----------------------------------------------------------------------------
-- The generator, with COUNT resolved once
-- -----------------------------------------------------------------------------
-- Rebuilt from 057's FILE, not from this database — twice in one recent
-- session a copy taken with pg_get_functiondef contained an earlier draft of
-- the very migration being written, because the database had already had it
-- applied. The only change from 057 is the end date: v_count and v_made are
-- gone, and `until` now comes from rrule_last_date().
-- The third parameter is new, and it is why this is a DROP rather than a
-- replace: a default argument creates an overload, it does not replace a
-- signature, and every existing one-argument call would then fail as ambiguous
-- — migration 028's trap. A drop discards the ACL, so the grants below are not
-- optional tidying.
drop function if exists generate_occurrences(uuid, int);

create function generate_occurrences(
  p_series_id uuid, p_horizon_months int default null, p_from date default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  ser        class_series%rowtype;
  v_tz       text;
  v_months   int;
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
  -- Platform admin included: generate_demo_data() inserts class_series for a
  -- studio the operator is not staff of, which now fires the materialise
  -- trigger. Without this the demo generator cannot create a timetable at all.
  if not is_manager_up(ser.studio_id)
     and not is_platform_admin()
     and not is_service_context() then
    raise exception 'only owners, managers or the scheduler may materialise a timetable'
      using errcode = 'PT403';
  end if;

  select timezone into v_tz from studios where id = ser.studio_id;
  select coalesce(p_horizon_months, occurrence_horizon_months, 12)
    into v_months from studio_settings where studio_id = ser.studio_id;
  v_months := coalesce(v_months, coalesce(p_horizon_months, 12));

  v_days     := rrule_weekdays(ser.rrule);
  v_interval := coalesce(nullif(rrule_part(ser.rrule, 'INTERVAL'), '')::int, 1);
  -- UNTIL and COUNT, folded to one date. COUNT used to be "stop after N rows
  -- THIS RUN", counted from today, so every nightly run topped the series back
  -- up to N and a rule that was supposed to end never did.
  v_until    := rrule_last_date(ser.rrule, ser.starts_on);

  -- Today IN THE STUDIO'S ZONE. A horizon measured from the server's date is a
  -- different horizon for every studio east of London.
  v_today := (now() at time zone v_tz)::date;

  -- Never backfill the past. An occurrence generated behind today is a class
  -- nobody could book and nobody taught, and it would land in every member's
  -- history as a gap they never had.
  -- p_from is how update_series stops the generator undoing the one thing an
  -- edit promises: that it changes nothing before its effective date. Without
  -- it, retiming a series regenerates TODAY at the new time beside the class
  -- the edit had just deliberately left alone, and the studio has two.
  v_from := greatest(ser.starts_on, v_today, coalesce(p_from, '-infinity'::date));
  v_to   := least(
    (v_today + make_interval(months => v_months))::date,
    coalesce(ser.ends_on,  'infinity'::date),
    coalesce(v_until,      'infinity'::date));

  if ser.status <> 'active' then
    return jsonb_build_object('series_id', ser.id, 'created', 0,
      'skipped', 0, 'conflicts', '[]'::jsonb, 'reason', 'series is ' || ser.status);
  end if;

  -- INTERVAL counts weeks from the series' own first week, not from today, or
  -- a fortnightly class would land on the wrong fortnight depending on when the
  -- job happened to run.
  v_anchor := ser.starts_on - extract(dow from ser.starts_on)::int;

  d := v_from;
  while d <= v_to loop
    if extract(dow from d)::int = any (v_days)
       and (v_interval = 1
            or ((d - extract(dow from d)::int - v_anchor) / 7) % v_interval = 0)
    then
      -- Local wall clock, then interpreted in the zone. NOT starts_at plus an
      -- interval: that drifts an hour across a DST boundary and a 07:00 class
      -- stops being a 07:00 class. Same rule the seed already follows.
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
                -- CAST. An untyped CASE into an enum column fails at runtime,
                -- not at create time — the fourth time this codebase has hit it.
                (case when ser.instructor_id is null then 'open' else 'assigned' end)::staffing_state,
                v_start);
        v_created := v_created + 1;
      exception
        when unique_violation then
          -- Already materialised, or its slot is held by an occurrence that has
          -- been moved away from it. Either way the studio has decided about
          -- this recurrence and the job leaves it alone. THIS is the idempotency.
          v_skipped := v_skipped + 1;
        when exclusion_violation then
          -- A room or an instructor already busy at that instant. Reported per
          -- occurrence rather than aborting: one bad Tuesday must not cost the
          -- studio the other fifty-one weeks of its timetable.
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

-- -----------------------------------------------------------------------------
-- Two triggers that have to stand aside while a series is being edited
-- -----------------------------------------------------------------------------
-- Same transaction-local flag idiom as `studiior.assigning`, `studiior.archiving`
-- and `studiior.demo_generating`. Set with the third argument true so it cannot
-- outlive the transaction that set it — a session-scoped flag would leave the
-- next writer on that connection exempt from both triggers.

-- A series edit moves fifty-two classes and NONE of them is an exception: they
-- are the series, moving. Left to itself this trigger marks every one, and the
-- nightly job then refuses to touch any of them ever again — the studio's whole
-- timetable frozen by one edit.
create or replace function tg_mark_moved_as_exception()
returns trigger language plpgsql set search_path = public as $$
begin
  if coalesce(current_setting('studiior.series_editing', true), '') = 'on' then
    return new;
  end if;
  if new.series_id is not null
     and (new.starts_at is distinct from old.starts_at
          or new.ends_at is distinct from old.ends_at) then
    new.is_exception := true;
  end if;
  return new;
end $$;

-- update_series() generates once, at the end, having first moved what already
-- exists. Letting the trigger fire mid-edit generates against a half-applied
-- definition — which is exactly the duplication this migration exists to stop.
create or replace function tg_generate_series_occurrences()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('studiior.series_editing', true), '') = 'on' then
    return null;
  end if;
  if new.status = 'active' then
    perform generate_occurrences(new.id);
  end if;
  return null;
end $$;

-- -----------------------------------------------------------------------------
-- Editing a series
-- -----------------------------------------------------------------------------
-- Two-step. The first call reports and changes nothing; only p_confirm => true
-- acts. Every field the form has is a parameter, and all of them are required:
-- a nullable "leave this alone" parameter cannot also mean "set this to null",
-- which is the lesson `move_occurrence()` learnt the expensive way with
-- p_clear_instructor.
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
  v_months    int;
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

  select coalesce(occurrence_horizon_months, 12) into v_months
    from studio_settings where studio_id = ser.studio_id;
  v_months := coalesce(v_months, 12);
  v_to := least(
    (v_today + make_interval(months => v_months))::date,
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
-- Grants
-- -----------------------------------------------------------------------------
-- Closed by default is the opposite of PostgreSQL's default, and revoking from
-- PUBLIC is not revoking from anon or authenticated on hosted. Name the roles.
revoke execute on function rrule_last_date(text, date)     from public, anon, authenticated;
revoke execute on function series_rule_matches(text, date, date, date)
                                                           from public, anon, authenticated;
-- generate_occurrences was DROPPED above to take its third parameter, so it is
-- born with the hosted default grant again and 057's revoke has to be re-issued
-- along with 057's grant. Repeating the revoke without the grant is how the
-- fill screen and the occurrence suite lose it.
revoke execute on function generate_occurrences(uuid, int, date) from public, anon, authenticated;
grant  execute on function generate_occurrences(uuid, int, date) to authenticated, service_role;
revoke execute on function tg_mark_moved_as_exception()    from public, anon, authenticated;
revoke execute on function tg_generate_series_occurrences() from public, anon, authenticated;
revoke execute on function update_series(uuid, text, uuid, uuid, uuid, int, int,
                                         text, date, date, time, text, date, boolean)
                                                           from public, anon, authenticated;
-- The one thing a manager calls. Its own guard is inside it; the grant is not one.
grant execute on function update_series(uuid, text, uuid, uuid, uuid, int, int,
                                        text, date, date, time, text, date, boolean)
      to authenticated;

-- =============================================================================
-- The checklist learns the three things "fill November" actually needs
-- =============================================================================
-- It tracked rooms, class types, instructors, plans, schedule, team and Stripe.
-- A studio could tick every one of them, open the fill screen and get nothing
-- back, with no way to find out why — the checklist said it was finished.
--
-- The three are not the same weight, and pretending they are would be the
-- "6 of 7 forever" mistake in a new place:
--
--   QUALIFICATIONS is a hard prerequisite. An empty mapping means qualified for
--   NOTHING (migration 060, deliberately), so an unmapped roster makes the
--   engine return an empty month. This one holds the list open.
--
--   AVAILABILITY is not. `instructor_available_at()` returns true for an
--   instructor who has never stated any, on purpose — nobody should be flagged
--   for every class they teach because they have not opened a screen. Without
--   it the engine still fills, it just fills blind, so this is nice-to-have
--   rather than outstanding.
--
--   COMMITMENTS are the weakest of the three and the run SAYS so: with none on
--   file the engine degrades to "fewest classes that week" and reports
--   `commitment_fallback` rather than claiming a target it does not have.
--
-- Each item is ticked when EVERY active instructor has one, not when any does.
-- One unmapped instructor is a person the engine will silently never use, and
-- "at least one row exists" is exactly the kind of tick that goes stale.
create or replace function studio_setup_state(p_studio_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  with prog as (
    select coalesce(setup_progress, '{}'::jsonb) as p
      from studio_settings where studio_id = p_studio_id
  ),
  live as (
    select id from instructors where studio_id = p_studio_id and status = 'active'
  ),
  facts(key, done) as (
    values
      ('rooms',        exists (select 1 from rooms          where studio_id = p_studio_id and status = 'active')),
      ('class_types',  exists (select 1 from class_types    where studio_id = p_studio_id and status = 'active')),
      ('instructors',  exists (select 1 from instructors    where studio_id = p_studio_id and status = 'active')),
      ('plans',        exists (select 1 from membership_plans where studio_id = p_studio_id and status = 'active')),
      ('schedule',     exists (select 1 from class_occurrences where studio_id = p_studio_id)),
      ('staff',       (select count(*) from studio_staff where studio_id = p_studio_id and status = 'active') > 1),
      ('qualifications',
       exists (select 1 from live)
       and not exists (
         select 1 from live l
          where not exists (select 1 from instructor_class_types m
                             where m.instructor_id = l.id))),
      ('availability',
       exists (select 1 from live)
       and not exists (
         select 1 from live l
          where not exists (select 1 from instructor_availability a
                             where a.instructor_id = l.id
                               and a.day_of_week is not null))),
      ('commitments',
       exists (select 1 from live)
       and not exists (
         select 1 from live l
          where not exists (select 1 from instructor_commitments c
                             where c.instructor_id = l.id and c.status = 'active'))),
      -- Nothing to derive until Stripe Connect is wired; it is a stored flag.
      ('connect_stripe',
       (select stripe_account_id is not null from studios where id = p_studio_id))
  )
  select jsonb_object_agg(
           f.key,
           jsonb_build_object(
             -- coalesce before ?: on a fresh studio setup_progress is '{}',
             -- so p -> 'done' is NULL and NULL ? key is NULL, not false — the
             -- checklist would render "unknown" rather than "not done".
             'done', f.done,
             'dismissed', (select coalesce(p -> 'dismissed', '{}'::jsonb) ? f.key from prog),
             -- Optional items are shown as nice-to-have rather than
             -- outstanding. Decision 16 for connect_stripe; availability and
             -- commitments for the reasons above.
             'optional', (select f.key = any (st.setup_optional_items)
                            from studio_settings st where st.studio_id = p_studio_id)
           ))
    from facts f
   where exists (select 1 from studio_staff s
                  where s.studio_id = p_studio_id and s.user_id = auth.uid()
                    and s.status = 'active' and s.role in ('owner','manager'))
      or auth.uid() is null;
$$;

alter table studio_settings
  alter column setup_optional_items
  set default array['connect_stripe','availability','commitments']::text[];

-- Existing studios, or the two new items would hold every current checklist
-- open — the default only reaches studios provisioned after this migration.
update studio_settings
   set setup_optional_items =
         (select array_agg(distinct x)
            from unnest(setup_optional_items || array['availability','commitments']) as x)
 where not (setup_optional_items @> array['availability','commitments']);

revoke execute on function studio_setup_state(uuid) from public, anon;
grant  execute on function studio_setup_state(uuid) to authenticated;
