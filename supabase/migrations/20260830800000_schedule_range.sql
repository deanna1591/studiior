-- =============================================================================
-- 070  The calendar asks for a range of the STUDIO's days, and gets them
-- =============================================================================
-- The staff calendar rendered an empty grid for every day. Diagnosed before
-- changing anything, against a fixture that reproduces the reported data — a
-- Manila studio with classes on Wednesday 18 November:
--
--   1. THE FETCH WINDOW WAS FIXED AND THE NAVIGATION WAS NOT. The page selected
--      `now() - 7 days` to `now() + 28 days` on the SERVER at render time,
--      while moving between days was client-side state. So every date outside
--      that 35-day window drew an empty grid and nothing ever refetched.
--      Measured: the query returned **0 rows** while 2 existed for that day.
--
--   2. EVERY INSTANT WAS RENDERED IN THE BROWSER'S ZONE. A 07:00 Manila class
--      is stored `2026-11-17 23:00+00`, which a Prague browser draws at 00:00
--      on the SEVENTEENTH — the previous day, and outside the working hours the
--      grid was showing. Right instant, wrong day, invisible either way.
--
--   3. THE VISIBLE HOURS WERE HARDCODED 06:00-22:00 of the browser's day.
--
-- This migration fixes the half that belongs in the database: a reader that
-- takes a range of the studio's OWN dates and returns what falls inside them,
-- with the local date and time already resolved. The day boundary is a
-- timezone question and Postgres is the only participant that has never been
-- confused about it — doing it in the page means doing it again in the next
-- caller, slightly differently.
-- =============================================================================

create or replace function schedule_range(
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
  occ_status     text
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
         o.staffing::text, o.status::text
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
end $$;

revoke execute on function schedule_range(uuid, date, date) from public, anon, authenticated;
grant  execute on function schedule_range(uuid, date, date) to authenticated;

-- The studio's own today, which is where a calendar opens. `now()::date` on the
-- server is a different day from the studio's for most of the world's hours.
create or replace function studio_today(p_studio_id uuid)
returns date language sql stable security definer set search_path = public as $$
  select (now() at time zone s.timezone)::date from studios s where s.id = p_studio_id
$$;
revoke execute on function studio_today(uuid) from public, anon, authenticated;
grant  execute on function studio_today(uuid) to authenticated, service_role;
