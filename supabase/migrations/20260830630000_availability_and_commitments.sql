-- =============================================================================
-- Migration 053: Decision 18, part one — the availability editor and the
--                commitment it is entered against
-- =============================================================================
-- `instructor_availability` has carried day_of_week, times, effective_from,
-- effective_to and exception_date since migration 001, and
-- instructor_available_at() has read all of them since 047. The schema was
-- never the gap. NOTHING IN THE PRODUCT COULD WRITE A ROW OF IT — so every
-- availability warning the scheduler has ever produced was computed against an
-- empty table and told the truth by accident.
--
-- Two things here:
--   1. set_instructor_availability() — a whole week, replaced in one call
--   2. instructor_commitments — the agreement the pattern is entered against
-- =============================================================================

-- -----------------------------------------------------------------------------
-- The commitment
-- -----------------------------------------------------------------------------
-- Decision 10 keeps compensation out of V1 and this does not cross that line:
-- there is no rate here and nothing that resolves to money owed. It records
-- what was agreed about TIME, so the studio can see it being kept.
create table if not exists instructor_commitments (
  id             uuid primary key default gen_random_uuid(),
  studio_id      uuid not null references studios on delete cascade,
  instructor_id  uuid not null references instructors on delete cascade,
  starts_on      date not null,
  -- Nullable: an open-ended arrangement is a real one. The three-month minimum
  -- is a floor the studio applies, not a shape the table can enforce.
  ends_on        date,
  min_per_week   int  not null default 0 check (min_per_week  >= 0),
  target_per_week int not null default 0 check (target_per_week >= 0),
  shift_preference text not null default 'both'
                   check (shift_preference in ('morning','evening','both')),
  status         text not null default 'active'
                 check (status in ('active','ended','cancelled')),
  note           text,
  created_by     uuid references profiles on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  check (ends_on is null or ends_on >= starts_on),
  check (target_per_week = 0 or target_per_week >= min_per_week)
);
create index if not exists instructor_commitments_live
  on instructor_commitments (studio_id, instructor_id) where status = 'active';

drop trigger if exists instructor_commitments_updated on instructor_commitments;
create trigger instructor_commitments_updated before update on instructor_commitments
  for each row execute function set_updated_at();

alter table instructor_commitments enable row level security;
grant select, insert, update, delete on instructor_commitments to authenticated;
grant all on instructor_commitments to service_role;

-- Manager-up writes. An instructor READS their own — it is an agreement they
-- are party to, and one they cannot see is not one they can be held to — but
-- does not write it, because a commitment you can lower yourself is not a
-- commitment. This is the one place Decision 9's "instructors edit their own"
-- deliberately does NOT extend.
create policy commitments_manager_all on instructor_commitments for all
  using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));
create policy commitments_self_read on instructor_commitments for select
  using (instructor_id = auth_instructor_id(studio_id));

comment on table instructor_commitments is
  'Decision 18. What was agreed about time: a start, an end, a weekly minimum '
  'and target, and when they prefer to teach. Not compensation — Decision 10.';

-- Only one live commitment per instructor. Two overlapping agreements make
-- "are they under their minimum" unanswerable, which is the only question the
-- table exists to answer.
create unique index if not exists instructor_commitments_one_live
  on instructor_commitments (instructor_id) where status = 'active';

-- -----------------------------------------------------------------------------
-- The week, written as one replacement
-- -----------------------------------------------------------------------------
-- p_days is [{ "day": 0-6, "ranges": [{"from":"09:00","to":"12:00"}, ...] }, ...]
-- A day present with an empty `ranges` is Unavailable and is stated as such; a
-- day ABSENT from the payload is left alone. That distinction is the difference
-- between "Sunday is a day off" and "I only edited the weekdays".
--
-- REPLACED WHOLE, INSIDE ONE TRANSACTION. Editing a weekly pattern range by
-- range means a half-applied week is reachable, and a half-applied week
-- silently changes who instructor_available_at() says can teach — the studio's
-- next assignment warning would be computed against a pattern that never
-- existed. Copy-a-day-to-other-days is therefore a client-side operation on the
-- form and what arrives here is always a complete week.
create or replace function set_instructor_availability(
  p_instructor_id  uuid,
  p_days           jsonb,
  p_effective_from date default null,
  p_effective_to   date default null
) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_studio uuid;
  v_from   date;
  v_to     date;
  d        jsonb;
  r        jsonb;
  v_day    int;
  n        int := 0;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then
    raise exception 'no such instructor' using errcode = 'PT404';
  end if;

  -- Decision 9, unchanged: manager-up, or the instructor themselves. Checked
  -- here as well as in the policies, because this function is SECURITY DEFINER
  -- and the policies are not what stops it.
  if not is_manager_up(v_studio)
     and p_instructor_id is distinct from auth_instructor_id(v_studio) then
    raise exception 'only the studio or the instructor may set their availability'
      using errcode = 'PT403';
  end if;

  -- Defaulted from the live commitment, so the pattern and the agreement cannot
  -- drift apart. An explicit argument still wins — a studio amending mid-term
  -- is a real thing and this is not the place to argue with them.
  select coalesce(p_effective_from, c.starts_on),
         coalesce(p_effective_to,   c.ends_on)
    into v_from, v_to
    from instructor_commitments c
   where c.instructor_id = p_instructor_id and c.status = 'active';
  if not found then
    v_from := p_effective_from;
    v_to   := p_effective_to;
  end if;

  if v_to is not null and v_from is not null and v_to < v_from then
    raise exception 'the pattern ends before it starts' using errcode = 'PT422';
  end if;

  -- Only the weekly pattern. Dated exceptions live in the same table and are a
  -- different act — an exception is a Tuesday in September, and re-entering the
  -- week must not silently forget one.
  delete from instructor_availability
   where instructor_id = p_instructor_id
     and day_of_week is not null
     and day_of_week in (
       select (x ->> 'day')::int from jsonb_array_elements(p_days) x);

  for d in select * from jsonb_array_elements(p_days) loop
    v_day := (d ->> 'day')::int;
    if v_day is null or v_day < 0 or v_day > 6 then
      raise exception 'day_of_week must be 0-6, got %', d ->> 'day'
        using errcode = 'PT422';
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
  return n;
end $$;

-- -----------------------------------------------------------------------------
-- One dated exception
-- -----------------------------------------------------------------------------
-- "Sep 16 — unavailable", or "Sep 16 — 1pm to 5pm only". Replaces whatever was
-- said about that date; p_ranges empty means unavailable all day.
create or replace function set_availability_exception(
  p_instructor_id uuid,
  p_date          date,
  p_ranges        jsonb default '[]'::jsonb,
  p_note          text default null
) returns int
language plpgsql security definer set search_path = public as $$
declare v_studio uuid; r jsonb; n int := 0;
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

  delete from instructor_availability
   where instructor_id = p_instructor_id and exception_date = p_date;

  if jsonb_array_length(coalesce(p_ranges, '[]'::jsonb)) = 0 then
    -- Unavailable all day, stated positively. instructor_available_at() looks
    -- for ANY exception row on the date first, so a row saying "no" is what
    -- makes the day off beat the weekly pattern — an absent row would simply
    -- fall through to "Tuesdays are fine".
    insert into instructor_availability
      (studio_id, instructor_id, exception_date, is_available, note, created_by)
    values (v_studio, p_instructor_id, p_date, false, p_note, auth.uid());
    n := 1;
  else
    for r in select * from jsonb_array_elements(p_ranges) loop
      if (r ->> 'to')::time <= (r ->> 'from')::time then
        raise exception 'a range must end after it starts' using errcode = 'PT422';
      end if;
      insert into instructor_availability
        (studio_id, instructor_id, exception_date, starts_at_time, ends_at_time,
         is_available, note, created_by)
      values (v_studio, p_instructor_id, p_date,
              (r ->> 'from')::time, (r ->> 'to')::time, true, p_note, auth.uid());
      n := n + 1;
    end loop;
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (v_studio, auth.uid(), 'availability.exception', 'instructors', p_instructor_id,
          jsonb_build_object('date', p_date, 'ranges', p_ranges));
  return n;
end $$;

create or replace function clear_availability_exception(
  p_instructor_id uuid, p_date date
) returns int
language plpgsql security definer set search_path = public as $$
declare v_studio uuid; n int;
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
  delete from instructor_availability
   where instructor_id = p_instructor_id and exception_date = p_date;
  get diagnostics n = row_count;
  return n;
end $$;

-- -----------------------------------------------------------------------------
-- Reading it back, in the shape the editor draws
-- -----------------------------------------------------------------------------
create or replace function instructor_availability_week(p_instructor_id uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'days', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'day', dow,
               'ranges', ranges) order by dow), '[]'::jsonb)
        from (
          select a.day_of_week as dow,
                 jsonb_agg(jsonb_build_object(
                   'from', to_char(a.starts_at_time, 'HH24:MI'),
                   'to',   to_char(a.ends_at_time,   'HH24:MI'))
                   order by a.starts_at_time) as ranges
            from instructor_availability a
           where a.instructor_id = p_instructor_id
             and a.day_of_week is not null
             and a.is_available
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
         where a.instructor_id = p_instructor_id
           and a.exception_date is not null
         group by a.exception_date
      ) x)
  )
$$;

-- -----------------------------------------------------------------------------
-- Classes taught per week, against the commitment
-- -----------------------------------------------------------------------------
-- Counted from what actually ran: scheduled or completed occurrences where this
-- instructor is the EFFECTIVE teacher. A class they handed over does not count
-- for them, which is the same rule substitute_for already encodes.
create or replace function instructor_weekly_load(
  p_instructor_id uuid, p_weeks int default 4
) returns table (week_start date, classes int)
language sql stable security definer set search_path = public as $$
  with tz as (
    select s.timezone from instructors i
      join studios s on s.id = i.studio_id where i.id = p_instructor_id
  ),
  wk as (
    select generate_series(
      date_trunc('week', (now() at time zone (select timezone from tz))::date
                         - make_interval(weeks => p_weeks))::date,
      date_trunc('week', (now() at time zone (select timezone from tz))::date)::date
        - interval '7 days',
      interval '7 days')::date as ws
  )
  select wk.ws,
         (select count(*)::int from class_occurrences o
           where o.instructor_id = p_instructor_id
             and o.status <> 'cancelled'
             and (o.starts_at at time zone (select timezone from tz))::date
                 between wk.ws and wk.ws + 6)
    from wk order by wk.ws
$$;

revoke execute on function set_instructor_availability(uuid, jsonb, date, date)  from public, anon, authenticated;
revoke execute on function set_availability_exception(uuid, date, jsonb, text)    from public, anon, authenticated;
revoke execute on function clear_availability_exception(uuid, date)               from public, anon, authenticated;
revoke execute on function instructor_availability_week(uuid)                     from public, anon, authenticated;
revoke execute on function instructor_weekly_load(uuid, int)                      from public, anon, authenticated;
grant execute on function set_instructor_availability(uuid, jsonb, date, date) to authenticated, service_role;
grant execute on function set_availability_exception(uuid, date, jsonb, text)  to authenticated, service_role;
grant execute on function clear_availability_exception(uuid, date)             to authenticated, service_role;
grant execute on function instructor_availability_week(uuid)                   to authenticated, service_role;
grant execute on function instructor_weekly_load(uuid, int)                    to authenticated, service_role;
