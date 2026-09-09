-- =============================================================================
-- Migration 056: three SECURITY DEFINER reads that had no guard in them
-- =============================================================================
-- Found by running the advisor query over what 053 added and then asking the
-- second question the rule in CLAUDE.md exists for: not "is it reachable by
-- anon" but "is it reachable by AUTHENTICATED, and is there anything inside it
-- standing in the way".
--
-- There was not. PROVED, signed in as an ordinary Reform Collective MEMBER —
-- not staff, not an instructor, no relationship to the other studio at all:
--
--   select * from instructor_availability where instructor_id = <other tenant>
--     -> 0 rows.  RLS works.
--   select instructor_availability_week(<other tenant's instructor>)
--     -> their entire weekly pattern, every range, both effective dates.
--   select instructor_weekly_load(<same>)
--     -> four weeks of how many classes they taught.
--
-- The direct read returning 0 is what makes the diagnosis certain: the leak is
-- the SECURITY DEFINER wrapper stepping over the policy that was doing its job.
-- Exactly the shape of migration 033, and 047's instructor_available_at() has
-- carried the same fault since the day it was written — it leaks one boolean
-- rather than a whole pattern, which is smaller and not different.
--
-- The guard is the one the WRITE path already uses: manager-up of that
-- instructor's studio, or the instructor themselves. Every existing caller
-- already satisfies it — move_occurrence and approve_shift_application are
-- manager-up, apply_for_shift asks about the caller's own availability, the
-- shifts screen asks about its own instructor and the cover board is
-- manager-up — so nothing has to change to keep working.
-- =============================================================================

create or replace function instructor_availability_week(p_instructor_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then
    -- Not "no such instructor". A caller who may not read this must not be able
    -- to use the error to find out whether an id exists.
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;
  if not is_manager_up(v_studio)
     and p_instructor_id is distinct from auth_instructor_id(v_studio)
     and not is_service_context() then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;

  return (select jsonb_build_object(
    'days', (
      select coalesce(jsonb_agg(jsonb_build_object('day', dow, 'ranges', ranges) order by dow), '[]'::jsonb)
        from (
          select a.day_of_week as dow,
                 jsonb_agg(jsonb_build_object(
                   'from', to_char(a.starts_at_time, 'HH24:MI'),
                   'to',   to_char(a.ends_at_time,   'HH24:MI'))
                   order by a.starts_at_time) as ranges
            from instructor_availability a
           where a.instructor_id = p_instructor_id
             and a.day_of_week is not null and a.is_available
           group by a.day_of_week
        ) g),
    'effective_from', (select min(effective_from) from instructor_availability
                        where instructor_id = p_instructor_id and day_of_week is not null),
    'effective_to',   (select max(effective_to) from instructor_availability
                        where instructor_id = p_instructor_id and day_of_week is not null),
    'exceptions', (
      select coalesce(jsonb_agg(e order by e ->> 'date'), '[]'::jsonb) from (
        select jsonb_build_object(
                 'date', a.exception_date,
                 'available', bool_or(a.is_available),
                 'note', min(a.note),
                 'ranges', coalesce(jsonb_agg(jsonb_build_object(
                     'from', to_char(a.starts_at_time, 'HH24:MI'),
                     'to',   to_char(a.ends_at_time,   'HH24:MI'))
                     order by a.starts_at_time)
                     filter (where a.starts_at_time is not null), '[]'::jsonb)) as e
          from instructor_availability a
         where a.instructor_id = p_instructor_id and a.exception_date is not null
         group by a.exception_date
      ) x)
  ));
end $$;

create or replace function instructor_weekly_load(p_instructor_id uuid, p_weeks int default 4)
returns table (week_start date, classes int)
language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_tz text;
begin
  select i.studio_id, s.timezone into v_studio, v_tz
    from instructors i join studios s on s.id = i.studio_id
   where i.id = p_instructor_id;
  if v_studio is null then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;
  if not is_manager_up(v_studio)
     and p_instructor_id is distinct from auth_instructor_id(v_studio)
     and not is_service_context() then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;

  return query
    with wk as (
      select generate_series(
        date_trunc('week', (now() at time zone v_tz)::date - make_interval(weeks => p_weeks))::date,
        date_trunc('week', (now() at time zone v_tz)::date)::date - interval '7 days',
        interval '7 days')::date as ws
    )
    select wk.ws,
           (select count(*)::int from class_occurrences o
             where o.instructor_id = p_instructor_id
               and o.status <> 'cancelled'
               and (o.starts_at at time zone v_tz)::date between wk.ws and wk.ws + 6)
      from wk order by wk.ws;
end $$;

-- 047's, which has carried the same fault since it was written. Replaced from
-- its LIVE definition with only the guard added.
create or replace function instructor_available_at(
  p_instructor_id uuid, p_starts_at timestamptz, p_ends_at timestamptz
) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  v_studio uuid; v_tz text; v_date date; v_dow int; v_from time; v_to time;
begin
  if p_instructor_id is null then
    return true;
  end if;

  select i.studio_id, s.timezone into v_studio, v_tz
    from instructors i join studios s on s.id = i.studio_id
   where i.id = p_instructor_id;
  if v_studio is null then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;
  -- Every caller already satisfies this: move_occurrence and
  -- approve_shift_application guard manager-up before they get here,
  -- apply_for_shift asks about the caller's own availability, and both screens
  -- that call it directly are manager-up or asking about themselves.
  if not is_manager_up(v_studio)
     and p_instructor_id is distinct from auth_instructor_id(v_studio)
     and not is_service_context() then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;

  -- Availability is stated in studio-local wall-clock terms, so the comparison
  -- has to happen there. Comparing UTC against a local time would make an
  -- instructor unavailable for half the year in Prague.
  v_date := (p_starts_at at time zone v_tz)::date;
  v_dow  := extract(dow from (p_starts_at at time zone v_tz))::int;
  v_from := (p_starts_at at time zone v_tz)::time;
  v_to   := (p_ends_at   at time zone v_tz)::time;

  -- An explicit exception for that date wins over the weekly pattern, whichever
  -- way it points: a stated day off beats "Tuesdays are fine".
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

  -- No stated availability at all is not the same as being unavailable. An
  -- instructor who has never opened the screen should not be flagged for every
  -- class they teach.
  if not exists (select 1 from instructor_availability a
                  where a.instructor_id = p_instructor_id and a.day_of_week is not null) then
    return true;
  end if;

  return exists (
    select 1 from instructor_availability a
     where a.instructor_id = p_instructor_id
       and a.day_of_week = v_dow
       and a.is_available
       and (a.effective_from is null or a.effective_from <= v_date)
       and (a.effective_to   is null or a.effective_to   >= v_date)
       and (a.starts_at_time is null or a.starts_at_time <= v_from)
       and (a.ends_at_time   is null or a.ends_at_time   >= v_to));
end $$;

-- create-or-replace keeps the ACL, but these were replaced rather than dropped
-- and the rule is to say who may execute every time.
revoke execute on function instructor_availability_week(uuid) from public, anon;
revoke execute on function instructor_weekly_load(uuid, int) from public, anon;
revoke execute on function instructor_available_at(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function instructor_availability_week(uuid) to authenticated, service_role;
grant execute on function instructor_weekly_load(uuid, int) to authenticated, service_role;
grant execute on function instructor_available_at(uuid, timestamptz, timestamptz) to authenticated, service_role;
