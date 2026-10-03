-- =============================================================================
-- Decision 46 — "no stated availability means not available" (per-studio switch),
-- standing patterns need an end date under it, and a published month locks an
-- instructor's availability.
-- =============================================================================
-- re-issues: instructor_available_at_run(uuid, timestamptz, timestamptz),
--            set_instructor_availability_rows(uuid, jsonb, date, date),
--            submit_availability(uuid, date, jsonb, boolean)
--
-- The switch defaults OFF, so today's behaviour is byte-for-byte unchanged and
-- the all_off canary stays green. When ON: the automatic assigners never place
-- an instructor who has told the studio nothing; a standing pattern must carry
-- an end date; an instructor cannot change a published month's availability.
-- Decision 9 is untouched — manual assignment outside availability stays
-- permitted with a warning (the Assign panel, create_occurrence, move_occurrence
-- still call the function but warn-not-block, and the manual path is not gated
-- here). The step-4 standing-pattern predicate already bounds on effective_from/
-- effective_to, so nothing there changes. No new anon surface — still thirteen.
-- =============================================================================

alter table studio_settings
  add column if not exists assign_requires_availability boolean not null default false;

-- --- instructor_available_at_run: skip the "no rows → available" step when ON.
-- Re-issued from 20260831940000 (newest), the ONLY change being step 3 gated on
-- the studio switch. The guarded wrapper instructor_available_at() delegates to
-- this and is unchanged, so every caller (the engine, the Fill tool, cover,
-- warnings) gets the new behaviour without being re-issued.
create or replace function instructor_available_at_run(
  p_instructor_id uuid, p_starts_at timestamptz, p_ends_at timestamptz
) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_tz text; v_date date; v_dow int; v_from time; v_to time;
        v_sub uuid; v_strict boolean;
begin
  if p_instructor_id is null then
    return true;
  end if;

  select i.studio_id, s.timezone into v_studio, v_tz
    from instructors i join studios s on s.id = i.studio_id
   where i.id = p_instructor_id;
  if v_studio is null then
    return false;
  end if;

  v_date := (p_starts_at at time zone v_tz)::date;
  v_dow  := extract(dow from (p_starts_at at time zone v_tz))::int;
  v_from := (p_starts_at at time zone v_tz)::time;
  v_to   := (p_ends_at   at time zone v_tz)::time;

  -- 1. An explicit exception for that date wins over everything.
  if exists (select 1 from instructor_availability a
              where a.instructor_id = p_instructor_id and a.exception_date = v_date) then
    return exists (
      select 1 from instructor_availability a
       where a.instructor_id = p_instructor_id
         and a.exception_date = v_date
         and a.is_available
         and (a.starts_at_time is null or a.starts_at_time <= v_from)
         and (a.ends_at_time   is null or a.ends_at_time   >= v_to));
  end if;

  -- 2. An APPROVED submission whose month covers this date answers for it alone.
  select s.id into v_sub
    from availability_submissions s
   where s.instructor_id = p_instructor_id
     and s.status = 'approved'
     and v_date between s.period_start
                    and (s.period_start + interval '1 month' - interval '1 day')::date
   order by s.period_start desc
   limit 1;

  if v_sub is not null then
    return exists (
      select 1 from instructor_availability a
       where a.submission_id = v_sub
         and a.day_of_week = v_dow
         and a.approval_status = 'approved'
         and a.is_available
         and (a.starts_at_time is null or a.starts_at_time <= v_from)
         and (a.ends_at_time   is null or a.ends_at_time   >= v_to));
  end if;

  -- 3. No stated availability is not the same as being unavailable — UNLESS the
  --    studio has turned on "no availability means not available" (Decision 46),
  --    in which case an instructor with nothing on file falls through to step 4
  --    (the standing pattern) and, having none, is not available.
  select coalesce(ss.assign_requires_availability, false) into v_strict
    from studio_settings ss where ss.studio_id = v_studio;
  if not v_strict then
    if not exists (select 1 from instructor_availability a
                    where a.instructor_id = p_instructor_id
                      and a.day_of_week is not null
                      and a.approval_status = 'approved') then
      return true;
    end if;
  end if;

  -- 4. The standing weekly pattern (already bounded on effective_from/to).
  return exists (
    select 1 from instructor_availability a
     where a.instructor_id = p_instructor_id
       and a.day_of_week = v_dow
       and a.approval_status = 'approved'
       and a.is_available
       and (a.effective_from is null or a.effective_from <= v_date)
       and (a.effective_to   is null or a.effective_to   >= v_date)
       and (a.starts_at_time is null or a.starts_at_time <= v_from)
       and (a.ends_at_time   is null or a.ends_at_time   >= v_to));
end $$;

-- --- set_instructor_availability_rows: an end date is required under the switch.
-- Re-issued from 20260831600000 (newest), the ONLY change being the PT400 guard.
create or replace function set_instructor_availability_rows(
  p_instructor_id  uuid,
  p_days           jsonb,
  p_effective_from date default null,
  p_effective_to   date default null
) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_studio uuid; v_tz text;
  v_from   date := p_effective_from;
  v_to     date := p_effective_to;
  d        jsonb; r jsonb; v_day int; n int := 0;
  v_name text; v_user uuid; v_lines text; v_count int; v_fp text;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then
    raise exception 'no such instructor' using errcode = 'PT404';
  end if;
  if not is_manager_up(v_studio)
     and p_instructor_id is distinct from auth_instructor_id(v_studio) then
    raise exception 'only the studio or the instructor may set their availability'
      using errcode = 'PT403';
  end if;
  if v_to is not null and v_from is not null and v_to < v_from then
    raise exception 'the pattern ends before it starts' using errcode = 'PT422';
  end if;

  -- Decision 46: under "no availability means not available", a standing pattern
  -- must carry an end date — the studio checks month by month, so an open-ended
  -- row (which counts as available forever) is the opposite of that.
  if v_to is null
     and coalesce((select ss.assign_requires_availability from studio_settings ss
                    where ss.studio_id = v_studio), false) then
    raise exception 'Give this pattern an end date — the studio checks availability month by month.'
      using errcode = 'PT400';
  end if;

  delete from instructor_availability
   where instructor_id = p_instructor_id
     and day_of_week is not null
     and day_of_week in (
       select (x ->> 'day')::int from jsonb_array_elements(p_days) x);

  for d in select * from jsonb_array_elements(p_days) loop
    v_day := (d ->> 'day')::int;
    if v_day is null or v_day < 0 or v_day > 6 then
      raise exception 'day_of_week must be 0-6, got %', d ->> 'day' using errcode = 'PT422';
    end if;
    for r in select * from jsonb_array_elements(coalesce(d -> 'ranges', '[]'::jsonb)) loop
      if (r ->> 'to')::time <= (r ->> 'from')::time then
        raise exception 'a range must end after it starts (day %, % to %)',
          v_day, r ->> 'from', r ->> 'to' using errcode = 'PT422';
      end if;
      insert into instructor_availability
        (studio_id, instructor_id, day_of_week, starts_at_time, ends_at_time,
         effective_from, effective_to, is_available, created_by)
      values (v_studio, p_instructor_id, v_day,
              (r ->> 'from')::time, (r ->> 'to')::time,
              v_from, v_to, true, auth.uid());
      n := n + 1;
    end loop;
  end loop;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (v_studio, auth.uid(), 'availability.set', 'instructors', p_instructor_id,
          jsonb_build_object('days', p_days, 'effective_from', v_from,
                             'effective_to', v_to, 'ranges_written', n));

  -- B: what the new pattern leaves stranded — future classes the instructor is
  -- STILL assigned to but is no longer available for (studio-local time in the
  -- lines). instructor_available_at reads the new pattern (and honours an
  -- approved month submission, which wins for its days), so a class covered by
  -- an approved submission is not counted.
  select timezone into v_tz from studios where id = v_studio;
  select count(*)::int,
         string_agg('  ' || to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMon, HH24:MI')
                    || ' — ' || o.name, E'\n' order by o.starts_at),
         md5(string_agg(o.id::text, ',' order by o.id))
    into v_count, v_lines, v_fp
    from class_occurrences o
   where o.studio_id = v_studio and o.instructor_id = p_instructor_id
     and o.status = 'scheduled' and o.starts_at > now()
     and not instructor_available_at(p_instructor_id, o.starts_at, o.ends_at);

  if coalesce(v_count, 0) > 0 then
    select display_name into v_name from instructors where id = p_instructor_id;
    v_user := instructor_user_id(p_instructor_id);
    if v_user is not null then
      perform queue_shift_notice(v_studio, v_user, 'availability_narrowed_instructor',
        jsonb_build_object('instructor_name', coalesce(v_name, 'there'),
          'count', v_count, 'plural', case when v_count = 1 then '' else 'es' end,
          'lines', v_lines),
        'avail_narrowed_i:' || p_instructor_id || ':' || v_fp);
    end if;
    perform queue_shift_notice_to_staff(v_studio, 'availability_narrowed_staff',
      jsonb_build_object('instructor_name', coalesce(v_name, 'An instructor'),
        'count', v_count, 'plural', case when v_count = 1 then '' else 'es' end,
        'lines', v_lines),
      'avail_narrowed_s:' || p_instructor_id || ':' || v_fp);
  end if;

  return n;
end $$;

-- --- submit_availability: a published month is locked to the instructor. ------
-- Re-issued from 20260831980000 (newest), the ONLY change being the PT409 lock
-- added before the upsert. Manager path unchanged.
create or replace function submit_availability(
  p_instructor_id uuid,
  p_period_start  date,
  p_days          jsonb,
  p_submit        boolean default true
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_studio uuid;
  v_tz     text;
  v_today  date;
  v_end    date;
  v_status text;
  v_sub    availability_submissions%rowtype;
  v_is_mgr boolean;
  d jsonb; r jsonb; v_day int; n int := 0;
begin
  select i.studio_id, s.timezone into v_studio, v_tz
    from instructors i join studios s on s.id = i.studio_id
   where i.id = p_instructor_id;
  if v_studio is null then
    raise exception 'no such instructor' using errcode = 'PT404';
  end if;

  v_is_mgr := coalesce(is_manager_up(v_studio), false);
  if not v_is_mgr and p_instructor_id is distinct from auth_instructor_id(v_studio) then
    raise exception 'only the studio or the instructor may submit their availability'
      using errcode = 'PT403';
  end if;

  if p_period_start <> date_trunc('month', p_period_start)::date then
    raise exception 'a submission covers a whole month, so it starts on the 1st'
      using errcode = 'PT422';
  end if;
  v_today := (now() at time zone v_tz)::date;
  if p_period_start < date_trunc('month', v_today)::date then
    raise exception 'that month has already been and gone' using errcode = 'PT422';
  end if;

  -- Decision 46: once this month's schedule is published the studio is
  -- scheduling around what was submitted, so the instructor cannot change it;
  -- staff still can (the manager path). Gated on publication_enabled because
  -- month_published() answers true for every month when publication is off.
  if not v_is_mgr and publication_enabled(v_studio)
     and month_published(v_studio, (p_period_start + 15)::timestamp at time zone v_tz) then
    raise exception 'This month''s schedule is already published — ask the studio if something has changed.'
      using errcode = 'PT409';
  end if;

  v_end := (p_period_start + interval '1 month' - interval '1 day')::date;

  v_status := case
    when v_is_mgr then 'approved'
    when p_submit then 'submitted'
    else 'draft' end;

  insert into availability_submissions
    (studio_id, instructor_id, period_start, status, submitted_at,
     reviewed_by, reviewed_at, created_by, note)
  values (v_studio, p_instructor_id, p_period_start, v_status,
          case when v_status in ('submitted','approved') then now() end,
          case when v_status = 'approved' then auth.uid() end,
          case when v_status = 'approved' then now() end,
          auth.uid(), null)
  on conflict (instructor_id, period_start) do update
    set status = excluded.status,
        submitted_at = excluded.submitted_at,
        reviewed_by = excluded.reviewed_by,
        reviewed_at = excluded.reviewed_at,
        note = null,
        updated_at = now()
  returning * into v_sub;

  if v_sub.id is null then
    raise exception 'that submission is not yours' using errcode = 'PT403';
  end if;
  if v_sub.status = 'approved' and not v_is_mgr then
    raise exception 'that month is already approved — ask the studio to reopen it'
      using errcode = 'PT409';
  end if;

  delete from instructor_availability where submission_id = v_sub.id;

  for d in select * from jsonb_array_elements(p_days) loop
    v_day := (d ->> 'day')::int;
    if v_day is null or v_day < 0 or v_day > 6 then
      raise exception 'day_of_week must be 0-6, got %', d ->> 'day' using errcode = 'PT422';
    end if;
    for r in select * from jsonb_array_elements(coalesce(d -> 'ranges', '[]'::jsonb)) loop
      if (r ->> 'to')::time <= (r ->> 'from')::time then
        raise exception 'a range must end after it starts (day %, % to %)',
          v_day, r ->> 'from', r ->> 'to' using errcode = 'PT422';
      end if;
      insert into instructor_availability
        (studio_id, instructor_id, day_of_week, starts_at_time, ends_at_time,
         effective_from, effective_to, is_available, created_by,
         submission_id, approval_status)
      values (v_studio, p_instructor_id, v_day,
              (r ->> 'from')::time, (r ->> 'to')::time,
              p_period_start, v_end, true, auth.uid(),
              v_sub.id, v_sub.status);
      n := n + 1;
    end loop;
  end loop;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (v_studio, auth.uid(), 'availability.submitted', 'instructors', p_instructor_id,
          jsonb_build_object('period', p_period_start, 'status', v_sub.status,
                             'ranges', n));

  -- Decision 43: only let the engine fill when the studio's switch is on.
  if v_sub.status = 'approved' and auto_assign_enabled(v_studio) then
    perform assign_instructors_run(v_studio);
  end if;

  return jsonb_build_object(
    'submission_id', v_sub.id, 'status', v_sub.status,
    'period_start', p_period_start, 'period_end', v_end,
    'ranges', n,
    'auto_approved', v_is_mgr);
end $$;
