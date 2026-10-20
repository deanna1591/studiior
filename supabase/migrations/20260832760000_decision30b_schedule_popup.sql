-- =============================================================================
-- Decision 30 amendment (b) follow-up, 20 Oct 2026 — "Open to first-timers"
-- moves to the Schedule calendar's class popup.
-- =============================================================================
-- The owner opens a class to first-timers while looking at the week, not on the
-- day — so the control moves from the roster page into the Schedule popup, and a
-- calendar block that is open to first-timers BY OVERRIDE shows a small "Trials"
-- marker. For the marker, the per-block state has to be in the week read rather
-- than fetched per popup, so schedule_range carries the effective free-first
-- state per occurrence — reusing the ONE source, effective_free_first(occ),
-- gated on the studio switch so a studio with the feature off pays nothing and
-- the column is null. Adding an output column is a RETURNS TABLE change, so this
-- is a DROP + recreate (rebuilt verbatim from 20260832020000 with the one column
-- added); the ACL is re-asserted. App-only otherwise. No new anon RPC.
-- =============================================================================
-- re-issues: schedule_range(uuid, date, date)

drop function if exists schedule_range(uuid, date, date);

CREATE OR REPLACE FUNCTION public.schedule_range(p_studio_id uuid, p_from date, p_to date)
 RETURNS TABLE(occ_id uuid, occ_name text, starts_at timestamp with time zone, ends_at timestamp with time zone, local_date date, local_start text, local_end text, start_minutes integer, end_minutes integer, occ_instructor_id uuid, room_name text, occ_capacity integer, occ_booked integer, occ_waitlist integer, occ_staffing text, occ_status text, occ_flex boolean, occ_confirmed boolean, occ_tier text, occ_standalone boolean, occ_series_tier text, occ_minimum integer, occ_cancellation_cause text, occ_assignment_requested boolean, occ_assignment_confirmed boolean, occ_free_first jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_tz text; v_ff boolean;
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
  if p_to - p_from > 62 then
    raise exception 'ask for at most 62 days at a time' using errcode = 'PT422';
  end if;

  -- Decision 30 amendment (b) follow-up: only compute the per-class free-first
  -- state when the studio uses the feature — otherwise it is null and the popup
  -- card and the "Trials" marker are hidden.
  select free_first_class_enabled into v_ff from studio_settings where studio_id = p_studio_id;

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
         (g.tier = 'flex' and not occurrence_is_adjacent_run(o.id)),
         coalesce(
           o.guarantee_tier,
           case when o.flex then 'flex'::guarantee_tier end,
           ser.guarantee_tier,
           case when ser.flex then 'flex'::guarantee_tier end,
           'core'::guarantee_tier)::text,
         g.minimum,
         o.cancellation_cause::text,
         o.assignment_requested_at is not null,
         o.assignment_confirmed_at is not null,
         case when coalesce(v_ff, false) then effective_free_first(o.id) else null end
    from class_occurrences o
    cross join lateral occurrence_guarantee_run(o.id) g
    left join class_series ser on ser.id = o.series_id
    left join rooms r on r.id = o.room_id
   where o.studio_id = p_studio_id
     and (o.status <> 'cancelled'
          or o.cancellation_cause in ('unmet_minimum','no_instructor','studio_fault','force_majeure'))
     and (o.starts_at at time zone v_tz)::date between p_from and p_to
   order by o.starts_at;
end $function$;

revoke execute on function schedule_range(uuid, date, date) from public, anon;
grant  execute on function schedule_range(uuid, date, date) to authenticated, service_role;
