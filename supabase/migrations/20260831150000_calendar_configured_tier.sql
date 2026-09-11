-- =============================================================================
-- 110 — the calendar can say what a class IS, not only how it will behave.
--
-- `schedule_range()` has returned `occ_tier` since migration 095, and it is the
-- tier as RESOLVED — `occurrence_guarantee()` demotes a tier whose switch is off
-- to 'always', which is right, because with core evaluation off a core class
-- does run regardless.
--
-- But that demotion is a studio-wide fact, not a per-class one, so a calendar
-- drawn from it marks every core class 'always' and disagrees with the series
-- list beside it — which has no occurrence to resolve through and can only show
-- what the studio configured. Found by putting the mark on all three screens and
-- reading them together: Reform Collective runs guarantees off, and its six core
-- series drew as core in the list and 'always runs' on the calendar.
--
-- So the function returns BOTH. `occ_tier` is unchanged and still what the
-- booking engine will do; `occ_series_tier` is what the studio set. It also
-- returns `occ_minimum`, which `occurrence_guarantee()` has always computed and
-- which was simply never passed on — so a calendar could say a class was flex
-- and not what would make it run.
--
-- A `RETURNS TABLE` cannot gain a column through `create or replace`, so this
-- DROPS first — and a drop discards the ACL, which is re-granted at the bottom
-- and then asserted. Migration 094's shape.
-- =============================================================================

drop function if exists schedule_range(uuid, date, date);

create function schedule_range(p_studio_id uuid, p_from date, p_to date)
 RETURNS TABLE(occ_id uuid, occ_name text, starts_at timestamp with time zone, ends_at timestamp with time zone, local_date date, local_start text, local_end text, start_minutes integer, end_minutes integer, occ_instructor_id uuid, room_name text, occ_capacity integer, occ_booked integer, occ_waitlist integer, occ_staffing text, occ_status text, occ_flex boolean, occ_confirmed boolean, occ_tier text, occ_standalone boolean, occ_series_tier text, occ_minimum integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
         o.flex, o.committed_at is not null,
         g.tier::text,
         -- STANDALONE: a flex slot with nothing else of that instructor's near
         -- it, which is the one that costs them a trip for a class that may not
         -- run. Resolved in this query rather than fetched per block: the
         -- calendar must not gain a round trip per class.
         (g.tier = 'flex' and not occurrence_is_adjacent(o.id)),
         -- THE TIER AS CONFIGURED, beside `occ_tier` which is the tier as it
         -- will BEHAVE. They are different facts and the calendar needs both.
         --
         -- `occurrence_guarantee()` demotes a tier whose switch is off to
         -- 'always' — correctly, because with core evaluation off a core class
         -- genuinely does run regardless. But that demotion is studio-wide and
         -- carries no per-class information, so a calendar drawn from it marks
         -- every core class 'always' and disagrees with the series list beside
         -- it, which can only ever show what the studio set.
         --
         -- This is the same walk MINUS the switch: occurrence column,
         -- occurrence boolean, series column, series boolean, then core. The
         -- boolean is read at both levels for migration 085's reason — a reader
         -- that looked only at the new column would demote every Decision 21
         -- row to core.
         coalesce(
           o.guarantee_tier,
           case when o.flex then 'flex'::guarantee_tier end,
           ser.guarantee_tier,
           case when ser.flex then 'flex'::guarantee_tier end,
           'core'::guarantee_tier)::text,
         -- What a flex class has to reach. Already resolved by the guarantee
         -- function; it was simply never returned, so the calendar could say a
         -- class was flex and not what would make it run.
         g.minimum
    from class_occurrences o
    cross join lateral occurrence_guarantee(o.id) g
    left join class_series ser on ser.id = o.series_id
    left join rooms r on r.id = o.room_id
   where o.studio_id = p_studio_id
     and o.status <> 'cancelled'
     -- THE WHOLE POINT: the range is expressed in the studio's days, and the
     -- comparison happens after converting. Comparing UTC instants against a
     -- date loses the classes either side of local midnight — which for Manila
     -- is every 07:00 class in the timetable.
     and (o.starts_at at time zone v_tz)::date between p_from and p_to
   order by o.starts_at;
end $function$;

revoke execute on function schedule_range(uuid, date, date) from public, anon;
grant  execute on function schedule_range(uuid, date, date) to authenticated, service_role;

do $$
begin
  if has_function_privilege('anon', 'schedule_range(uuid,date,date)'::regprocedure, 'execute') then
    raise exception 'migration 110: schedule_range is reachable by anon';
  end if;
  if not has_function_privilege('authenticated', 'schedule_range(uuid,date,date)'::regprocedure, 'execute') then
    raise exception 'migration 110: the calendar lost the grant it needs';
  end if;
end $$;
