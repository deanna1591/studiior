-- =============================================================================
-- 076  Converging hosted with the files. Again.
-- =============================================================================
-- `scripts/check-hosted-drift.sh` was rewritten to fail loudly instead of
-- reporting every function as diverged, and its first honest run against hosted
-- found this:
--
--   DIFFERENT   generate_occurrences, schedule_range
--   MISSING     flex_pending, flex_report, sweep_flex_decisions
--
-- `supabase migration list` says every migration through 20260830850000 is
-- applied and none is local-only. Both statements are true at once, which is
-- the whole point of the tool: the list records THAT a version ran, never
-- WHICH. Migration 075 reached hosted at an intermediate state and the later
-- edits to its file — the ones that added the pending list, the report, the
-- sweep, and the rebuilds of the generator and the calendar reader — were never
-- replayed, because a hosted database does not replay a migration it has
-- already recorded.
--
-- THIRD TIME. Migrations 062 and 070 before this. The file was being appended
-- to with `cat >>` across several steps while it was applied in between, which
-- is editing an applied migration however it is spelled. The rule has not
-- changed: fix forward, never edit in place — and if a migration is long enough
-- to want building up in pieces, build it in a scratch file and move it into
-- `supabase/migrations/` once.
--
-- Everything below is re-issued from 20260830850000, the file that defines it,
-- and is written to land whichever state a given database is in.
-- =============================================================================

create or replace function flex_pending(p_studio_id uuid)
returns table (
  occ_id      uuid,
  occ_name    text,
  starts_at   timestamptz,
  local_when  text,
  booked      int,
  minimum     int,
  short_by    int,
  due_at      timestamptz,
  past_due    boolean
) language plpgsql stable security definer set search_path = public as $$
declare v_tz text; s studio_settings%rowtype;
begin
  if not coalesce(is_manager_up(p_studio_id), false) and not is_service_context() then
    raise exception 'only owners and managers see this' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  if v_tz is null then
    raise exception 'no such studio' using errcode = 'PT404';
  end if;
  select * into s from studio_settings where studio_id = p_studio_id;
  if not coalesce(s.flex_enabled, false) then
    return;  -- flex off: nothing is pending, ever
  end if;

  return query
  select o.id, o.name, o.starts_at,
         to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMon, HH24:MI'),
         b.n, coalesce(o.minimum_bookings, 1),
         greatest(0, coalesce(o.minimum_bookings, 1) - b.n),
         d.due, now() >= d.due
    from class_occurrences o
    cross join lateral (
      select count(*)::int as n from bookings bk
       where bk.occurrence_id = o.id
         and bk.status in ('booked','attended','no_show','pending_payment')
    ) b
    cross join lateral (
      select case
        when s.flex_deadline_mode = 'hours_before'
          then o.starts_at - make_interval(hours => s.flex_deadline_hours)
        -- The night before, at the studio's own clock time. Computed by taking
        -- the class's LOCAL date, stepping back a day and pinning the time, then
        -- interpreting that back in the zone — never by subtracting an interval,
        -- which drifts an hour across a clock change.
        else ((((o.starts_at at time zone v_tz)::date - 1) + s.flex_deadline_time)
              at time zone v_tz)
      end as due
    ) d
   where o.studio_id = p_studio_id
     and o.flex
     and o.flex_confirmed_at is null
     and o.status = 'scheduled'
     and o.starts_at > now()
   order by o.starts_at;
end $$;;

create or replace function sweep_flex_decisions()
returns jsonb language plpgsql security definer set search_path = public as $$
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
        perform cancel_occurrence(r.occ_id, 'Did not reach its minimum by the deadline');
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
end $$;;

create or replace function flex_report(
  p_studio_id uuid, p_from date, p_to date
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_tz text; v jsonb;
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers see reporting' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  if v_tz is null then
    raise exception 'no such studio' using errcode = 'PT404';
  end if;

  with occ as (
    select o.id, o.flex, o.status, o.capacity, o.series_id, o.name,
           (select count(*)::int from bookings b
             where b.occurrence_id = o.id
               and b.status in ('booked','attended','no_show','pending_payment')) as booked
      from class_occurrences o
     where o.studio_id = p_studio_id
       and (o.starts_at at time zone v_tz)::date between p_from and p_to
  )
  select jsonb_build_object(
    'from', p_from, 'to', p_to,
    'flex', jsonb_build_object(
      'total',     count(*) filter (where flex),
      'ran',       count(*) filter (where flex and status <> 'cancelled'),
      'cancelled', count(*) filter (where flex and status = 'cancelled'),
      -- Fill is measured on the classes that RAN. A cancelled class has no fill
      -- rate; averaging its zero in would make flex look emptier than it is and
      -- argue against the very slots that are working.
      'fill_pct',  round(100 * coalesce(
                     sum(booked) filter (where flex and status <> 'cancelled')::numeric
                     / nullif(sum(capacity) filter (where flex and status <> 'cancelled'), 0), 0), 1)),
    'core', jsonb_build_object(
      'total',     count(*) filter (where not flex),
      'cancelled', count(*) filter (where not flex and status = 'cancelled'),
      'fill_pct',  round(100 * coalesce(
                     sum(booked) filter (where not flex and status <> 'cancelled')::numeric
                     / nullif(sum(capacity) filter (where not flex and status <> 'cancelled'), 0), 0), 1)),
    'by_series', coalesce((
      select jsonb_agg(x order by x ->> 'name')
        from (select jsonb_build_object(
                'series_id', series_id, 'name', min(name),
                'ran', count(*) filter (where status <> 'cancelled'),
                'cancelled', count(*) filter (where status = 'cancelled'),
                'fill_pct', round(100 * coalesce(
                   sum(booked) filter (where status <> 'cancelled')::numeric
                   / nullif(sum(capacity) filter (where status <> 'cancelled'), 0), 0), 1)) as x
               from occ where flex and series_id is not null
              group by series_id) z), '[]'::jsonb))
    into v from occ;
  return v;
end $$;;

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
end $$;;

-- schedule_range gained two output columns in 075, so this is a DROP and a
-- create rather than a replace — and a drop discards the ACL.
drop function if exists schedule_range(uuid, date, date);

create function schedule_range(
  p_studio_id uuid, p_from date, p_to date
) returns table (
  -- Prefixed, because an OUT parameter named `id` shadows `class_occurrences.id`
  -- inside the body and every reference to it becomes ambiguous. PostgREST
  -- returns these names to the caller, so the page reads them prefixed too.
  occ_id         uuid,
  occ_name       text,
  starts_at      timestamptz,
  ends_at        timestamptz,
  -- Resolved HERE, so no caller has to know how to ask.
  local_date     date,
  local_start    text,
  local_end      text,
  start_minutes  int,
  end_minutes    int,
  occ_instructor_id uuid,
  room_name      text,
  occ_capacity   int,
  occ_booked     int,
  occ_waitlist   int,
  occ_staffing   text,
  occ_status     text,
  -- Decision 21. The calendar has to show a flex class differently from a
  -- guaranteed one BEFORE the deadline, which is the only window in which the
  -- difference means anything.
  occ_flex       boolean,
  occ_confirmed  boolean
) language plpgsql stable security definer set search_path = public as $$
declare v_tz text;
begin
  if not coalesce(is_manager_up(p_studio_id), false) and not is_service_context() then
    raise exception 'the timetable is the owner''s and managers'' to see'
      using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  if v_tz is null then
    raise exception 'no such studio' using errcode = 'PT404';
  end if;
  if p_to < p_from then
    raise exception 'that range ends before it starts' using errcode = 'PT400';
  end if;
  -- A calendar asks for a day, a week or a month. Anything much larger is a
  -- mistake rather than a request, and it would be paid for in one query.
  if p_to - p_from > 62 then
    raise exception 'ask for at most 62 days at a time' using errcode = 'PT422';
  end if;

  -- The OUT parameters share their names with the columns, so every reference
  -- inside the query is qualified and the table is aliased. Unqualified `id`
  -- resolves to the output column and is ambiguous.
  return query
  select o.id, o.name, o.starts_at, o.ends_at,
         (o.starts_at at time zone v_tz)::date,
         to_char(o.starts_at at time zone v_tz, 'HH24:MI'),
         to_char(o.ends_at   at time zone v_tz, 'HH24:MI'),
         (extract(hour from o.starts_at at time zone v_tz) * 60
          + extract(minute from o.starts_at at time zone v_tz))::int,
         (extract(hour from o.ends_at at time zone v_tz) * 60
          + extract(minute from o.ends_at at time zone v_tz))::int,
         o.instructor_id, r.name, o.capacity, o.booked_count, o.waitlist_count,
         o.staffing::text, o.status::text,
         o.flex, o.flex_confirmed_at is not null
    from class_occurrences o
    left join rooms r on r.id = o.room_id
   where o.studio_id = p_studio_id
     and o.status <> 'cancelled'
     -- THE WHOLE POINT: the range is expressed in the studio's days, and the
     -- comparison happens after converting. Comparing UTC instants against a
     -- date loses the classes either side of local midnight — which for Manila
     -- is every 07:00 class in the timetable.
     and (o.starts_at at time zone v_tz)::date between p_from and p_to
   order by o.starts_at;
end $$;;

revoke execute on function schedule_range(uuid, date, date)      from public, anon, authenticated;
grant  execute on function schedule_range(uuid, date, date)      to authenticated;
revoke execute on function generate_occurrences(uuid, int, date) from public, anon, authenticated;
grant  execute on function generate_occurrences(uuid, int, date) to authenticated, service_role;
revoke execute on function flex_pending(uuid)                    from public, anon, authenticated;
grant  execute on function flex_pending(uuid)                    to authenticated, service_role;
revoke execute on function flex_report(uuid, date, date)         from public, anon, authenticated;
grant  execute on function flex_report(uuid, date, date)         to authenticated;
revoke execute on function sweep_flex_decisions()                from public, anon, authenticated;
grant  execute on function sweep_flex_decisions()                to service_role;
