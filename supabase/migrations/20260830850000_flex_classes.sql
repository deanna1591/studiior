-- =============================================================================
-- 075  Decision 21 — flex classes
-- =============================================================================
-- A class is GUARANTEED (runs regardless of headcount — every class today) or
-- FLEX: runs only if it reaches a minimum by a deadline, and otherwise cancels.
-- Optional per studio, OFF by default, and invisible to members.
--
-- PER SERIES, and neither alternative could express what Reform Collective
-- actually runs: Phase 2 has a 07:00 flex slot beside an 08:00 core one on the
-- same days, and SCULPT appears in both. Per class type cannot say it; per time
-- band cannot say it either. The series is the thing that knows.
--
-- MEMBERS SEE NOTHING. No "unconfirmed", no "needs one more". Telling somebody
-- a class might not run is telling them not to bother booking it, which is the
-- opposite of what a class one short needs. Nothing in this migration adds a
-- column to anything the member app reads, and `flex` is on
-- `class_occurrences`, which the member app selects by name.
--
-- A MINIMUM IS AN INTEGER, NOT A BOOLEAN. A studio with twelve reformers may
-- want three; Reform Collective wants one, and one booking runs as a
-- semi-private at no extra charge.
--
-- ONCE CONFIRMED IT RUNS. `flex_confirmed_at` is a latch: a cancellation after
-- the deadline drops the headcount below the minimum and changes nothing,
-- because the coach has already been told to come in.
-- =============================================================================

alter table studio_settings
  add column if not exists flex_enabled boolean not null default false,
  -- 'previous_day_at' — a fixed local time the night before, which is what
  -- Reform Collective runs (20:00). 'hours_before' — a rolling window, for a
  -- studio whose classes are spread across the day.
  add column if not exists flex_deadline_mode text not null default 'previous_day_at',
  add column if not exists flex_deadline_time time not null default '20:00',
  add column if not exists flex_deadline_hours int not null default 12;

alter table studio_settings drop constraint if exists studio_settings_flex_mode_check;
alter table studio_settings add constraint studio_settings_flex_mode_check
  check (flex_deadline_mode in ('previous_day_at', 'hours_before')
         and flex_deadline_hours between 1 and 168);

comment on column studio_settings.flex_enabled is
  'Decision 21. Off by default: a studio that never turns it on sees no change '
  'anywhere, and no member sees anything either way.';

alter table class_series
  add column if not exists flex boolean not null default false,
  add column if not exists minimum_bookings int;
alter table class_series drop constraint if exists class_series_minimum_check;
alter table class_series add constraint class_series_minimum_check
  check (minimum_bookings is null or minimum_bookings >= 1);

alter table class_occurrences
  add column if not exists flex boolean not null default false,
  add column if not exists minimum_bookings int,
  -- Null is pending. Set is "this runs, whatever happens next."
  add column if not exists flex_confirmed_at timestamptz;
alter table class_occurrences drop constraint if exists class_occurrences_minimum_check;
alter table class_occurrences add constraint class_occurrences_minimum_check
  check (minimum_bookings is null or minimum_bookings >= 1);

comment on column class_occurrences.flex is
  'Inherited from the series at generation. Staff may set it false on ONE '
  'occurrence — "this one runs whatever happens" is a real decision on a quiet '
  'week — and the sweep then leaves it alone.';

create index if not exists class_occurrences_flex_pending_idx
  on class_occurrences (studio_id, starts_at)
  where flex and flex_confirmed_at is null and status = 'scheduled';

-- -----------------------------------------------------------------------------
-- Turning it on for a series, and reaching the classes it has already made
-- -----------------------------------------------------------------------------
-- update_series() takes every field as a parameter and adding two more would
-- change its signature, so flex gets its own writer. It matters that this
-- reaches EXISTING occurrences: a studio that flips a series to flex and finds
-- nothing changes for sixty days has been given a setting that does nothing.
-- Only pending, future, still-scheduled ones — a confirmed class has had its
-- coach told, and a past one is history.
create or replace function set_series_flex(
  p_series_id uuid, p_flex boolean, p_minimum_bookings int default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare ser class_series%rowtype; v_min int; n int;
begin
  select * into ser from class_series where id = p_series_id;
  if not found then
    raise exception 'no such series' using errcode = 'PT404';
  end if;
  if not coalesce(is_manager_up(ser.studio_id), false) then
    raise exception 'only owners and managers change the timetable' using errcode = 'PT403';
  end if;
  if p_flex and coalesce(p_minimum_bookings, 0) < 1 then
    raise exception 'a flex class needs a minimum of at least one booking'
      using errcode = 'PT422';
  end if;
  v_min := case when p_flex then p_minimum_bookings else null end;

  update class_series set flex = p_flex, minimum_bookings = v_min, updated_at = now()
   where id = p_series_id;

  with touched as (
    update class_occurrences
       set flex = p_flex, minimum_bookings = v_min, updated_at = now()
     where series_id = p_series_id
       and status = 'scheduled'
       and starts_at > now()
       and flex_confirmed_at is null
    returning 1)
  select count(*) into n from touched;

  return jsonb_build_object('ok', true, 'flex', p_flex,
                            'minimum_bookings', v_min, 'occurrences_updated', n);
end $$;

-- Staff flipping ONE occurrence to guaranteed.
create or replace function set_occurrence_guaranteed(p_occurrence_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o class_occurrences%rowtype;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then
    raise exception 'no such class' using errcode = 'PT404';
  end if;
  if not coalesce(is_manager_up(o.studio_id), false) then
    raise exception 'only owners and managers change the timetable' using errcode = 'PT403';
  end if;
  update class_occurrences
     set flex = false, minimum_bookings = null, updated_at = now()
   where id = p_occurrence_id;
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (o.studio_id, auth.uid(), 'occurrence.guaranteed', 'class_occurrences',
          p_occurrence_id, jsonb_build_object('was_flex', o.flex));
  return jsonb_build_object('ok', true, 'occurrence_id', p_occurrence_id);
end $$;

-- -----------------------------------------------------------------------------
-- The generator carries flex down from the series
-- -----------------------------------------------------------------------------
-- Rebuilt from 20260830840000, the newest FILE that defines it. Two lines.
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
revoke execute on function generate_occurrences(uuid, int, date) from public, anon, authenticated;
grant  execute on function generate_occurrences(uuid, int, date) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- What the coach is told, either way
-- -----------------------------------------------------------------------------
-- The whole point of a deadline is that somebody knows whether to come in.
insert into notification_templates (key, subject, text_body, html_body, note) values
('flex_confirmed',
 '{class_name} on {when} is running',
 E'Hi {instructor_name},\n\n{class_name} on {when} has the numbers and is going ahead. {booked_line}\n\nSee you there,\n{studio_name}',
 '<p>Hi {instructor_name},</p><p><strong>{class_name}</strong> on {when} has the numbers and is going ahead. {booked_line}</p><p>See you there,<br>{studio_name}</p>',
 'Migration 075, Decision 21. Sent to the instructor only — a member never '
 'learns their class was ever in doubt.'),
('flex_cancelled',
 '{class_name} on {when} is not running',
 E'Hi {instructor_name},\n\n{class_name} on {when} did not reach {minimum} by the deadline, so it is off. You do not need to come in for it.\n\n{studio_name}',
 '<p>Hi {instructor_name},</p><p><strong>{class_name}</strong> on {when} did not reach {minimum} by the deadline, so it is off. You do not need to come in for it.</p><p>{studio_name}</p>',
 'Migration 075, Decision 21. The instructor is told so they do not travel in. '
 'Members booked on it get class_cancelled through the §3.2 path instead.')
on conflict (key) do nothing;

-- -----------------------------------------------------------------------------
-- Which flex classes are waiting on a decision right now
-- -----------------------------------------------------------------------------
-- One definition, read by the sweep and by the staff screen — "what is short and
-- by how many" must be the same question in both, or a studio acts on a list
-- the job then disagrees with.
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
end $$;

-- -----------------------------------------------------------------------------
-- The deadline arrives
-- -----------------------------------------------------------------------------
-- IDEMPOTENCY IS THE OCCURRENCE'S OWN STATE, not the job_runs claim. A decided
-- class is either confirmed or cancelled and `flex_pending()` will not return it
-- again, which is what makes running this every fifteen minutes safe — and it
-- has to be safe, because 'hours_before' has a decision point at every hour of
-- the day and a once-a-day claim would answer only the first of them. job_runs
-- records the pass and counts attempts; it is not what stops a second decision.
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
end $$;

do $cron$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron unavailable; flex decisions not scheduled';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'studiior-flex-decisions') then
    perform cron.unschedule('studiior-flex-decisions');
  end if;
  -- Every fifteen minutes, like the brief and for the same reason: the deadline
  -- is a local time and studios span zones, so an hourly job decides some
  -- studios' classes up to fifty-nine minutes late — and a coach finding out at
  -- 20:59 whether to come in tomorrow is the thing this exists to prevent.
  perform cron.schedule('studiior-flex-decisions', '*/15 * * * *',
                        'select sweep_flex_decisions()');
end $cron$;

-- -----------------------------------------------------------------------------
-- Which flex slots have earned core status
-- -----------------------------------------------------------------------------
-- The number a studio actually wants: not "how many cancelled" on its own, but
-- flex fill against core fill. A flex slot filling as well as the core one
-- beside it is a slot that should stop being flex.
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
end $$;

revoke execute on function set_series_flex(uuid, boolean, int)     from public, anon, authenticated;
grant  execute on function set_series_flex(uuid, boolean, int)     to authenticated;
revoke execute on function set_occurrence_guaranteed(uuid)         from public, anon, authenticated;
grant  execute on function set_occurrence_guaranteed(uuid)         to authenticated;
revoke execute on function flex_pending(uuid)                      from public, anon, authenticated;
grant  execute on function flex_pending(uuid)                      to authenticated, service_role;
revoke execute on function flex_report(uuid, date, date)           from public, anon, authenticated;
grant  execute on function flex_report(uuid, date, date)           to authenticated;
revoke execute on function sweep_flex_decisions()                  from public, anon, authenticated;
grant  execute on function sweep_flex_decisions()                  to service_role;

-- -----------------------------------------------------------------------------
-- The calendar can tell a flex class from a guaranteed one
-- -----------------------------------------------------------------------------
-- Rebuilt from 20260830810000, the newest FILE that defines it. Adding two
-- output columns changes the return type, so this is a DROP and a create — and
-- a drop discards the ACL, so the grant comes back with it.
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
revoke execute on function schedule_range(uuid, date, date) from public, anon, authenticated;
grant  execute on function schedule_range(uuid, date, date) to authenticated;
