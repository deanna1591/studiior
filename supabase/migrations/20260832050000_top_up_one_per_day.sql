-- =============================================================================
-- Decision 42a amendment (c), part (2): the nightly top-up treats a moved class
-- as moved, not missing — one occurrence per series per studio-local day.
--
-- re-issues: generate_occurrences(uuid, integer, date)
--
-- On hosted, two Reform series carried a second occurrence at a different clock
-- time on the same weekday (a Wed 07:00 series with 18:00 copies; a Sat 17:00
-- series with 09:00 copies). The materialise guard keyed on the unique index
-- (series_id, series_slot_at): a moved/off-slot occurrence keeps its OWN
-- series_slot_at (e.g. 18:00), so when the top-up computed the series' canonical
-- slot for that day (07:00) it found no row at that precise slot and created a
-- SECOND occurrence. Now, before materialising a day, the generator skips it if
-- the series already has a SCHEDULED occurrence on that studio-local day at ANY
-- time — so a class dragged from 07:00 to 18:00 leaves one Wednesday class and
-- the next nightly run adds nothing. A single series has one time_of_day and one
-- BYDAY, so it never legitimately runs twice on one day; the guard can only ever
-- skip a duplicate, never a wanted class. The existing unique_violation handling
-- still covers the same-slot case (migration 068's cancelled-slot rule: a
-- cancelled occurrence keeps its series_slot_at and is not refilled).
--
-- Byte-for-byte the 20260830860000 body with ONE addition: the per-day guard
-- before the INSERT. create-or-replace keeps the ACL.
-- =============================================================================

create or replace function generate_occurrences(
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
  v_closed   int := 0;
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
      -- Decision 42a amendment (c): one occurrence per series per studio-local
      -- DAY. If this series already has a scheduled class on this day — at any
      -- time, e.g. one dragged from 07:00 to 18:00 — the day is filled, so the
      -- top-up adds nothing rather than re-creating the canonical slot beside
      -- the moved class. (The same-slot/cancelled cases stay with the unique
      -- index below; this catches the off-slot case the index misses.)
      if exists (
        select 1 from class_occurrences t
         where t.series_id = ser.id
           and t.status = 'scheduled'
           and (t.starts_at at time zone v_tz)::date = d
      ) then
        v_skipped := v_skipped + 1;
        d := d + 1;
        continue;
      end if;

      -- Local wall clock, then interpreted in the zone. NOT starts_at plus an
      -- interval: that drifts an hour across a DST boundary and a 07:00 class
      -- stops being a 07:00 class.
      v_start := (d + ser.time_of_day) at time zone v_tz;

      -- Migration 074: the studio is shut. Skipped rather than made and then
      -- cancelled — materialising a fortnight of Christmas classes so they can
      -- be cancelled again is a fortnight of emails nobody needed, and a
      -- calendar that shows them until the job that removes them runs.
      if studio_closed_at(ser.studio_id, v_start,
                          v_start + make_interval(mins => ser.duration_minutes)) then
        v_closed := v_closed + 1;
        d := d + 1;
        continue;
      end if;

      begin
        insert into class_occurrences
          (studio_id, location_id, series_id, class_type_id, name, description,
           instructor_id, room_id, capacity, starts_at, ends_at,
           status, staffing, series_slot_at,
           -- Decision 21: inherited from the series, so an occurrence knows on
           -- its own whether it has to earn its place.
           flex, minimum_bookings)
        values (ser.studio_id, ser.location_id, ser.id, ser.class_type_id,
                ser.name, ser.description, ser.instructor_id, ser.room_id,
                ser.capacity, v_start,
                v_start + make_interval(mins => ser.duration_minutes),
                'scheduled',
                (case when ser.instructor_id is null then 'open' else 'assigned' end)::staffing_state,
                v_start,
                ser.flex, ser.minimum_bookings);
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
    'closed',    v_closed,
    'conflicts', v_conf,
    'horizon_to', v_to);
end $$;
