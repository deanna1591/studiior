-- =============================================================================
-- 072  Where the classes actually are
-- =============================================================================
-- The calendar opens on the studio's today and offers Today / Back / Next. That
-- is fine for a studio whose timetable starts this week, and useless for Reform
-- Collective, whose data begins on 1 November while its today is 10 September:
-- fifty-two presses of Next, or nothing.
--
-- Reproduced exactly — the studio's own conditions, Manila, classes only in
-- November — and the screen is right about the day it is showing. It has no
-- classes. What it could not do was say where any were, or let anybody go
-- there. An empty calendar that cannot point at the timetable it is a view of
-- is indistinguishable from a broken one, which is what it was taken for.
-- =============================================================================

create or replace function next_class_day(p_studio_id uuid, p_from date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_tz text; v_from date; v_next date; v_prev date; v_n int;
begin
  if not coalesce(is_manager_up(p_studio_id), false) and not is_service_context() then
    raise exception 'the timetable is the owner''s and managers'' to see'
      using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  if v_tz is null then
    raise exception 'no such studio' using errcode = 'PT404';
  end if;
  v_from := coalesce(p_from, (now() at time zone v_tz)::date);

  -- Forward first: a studio looking at an empty day almost always wants the
  -- next one that is not, not the last one that was.
  select min((o.starts_at at time zone v_tz)::date) into v_next
    from class_occurrences o
   where o.studio_id = p_studio_id and o.status <> 'cancelled'
     and (o.starts_at at time zone v_tz)::date > v_from;

  select max((o.starts_at at time zone v_tz)::date) into v_prev
    from class_occurrences o
   where o.studio_id = p_studio_id and o.status <> 'cancelled'
     and (o.starts_at at time zone v_tz)::date < v_from;

  select count(*) into v_n from class_occurrences o
   where o.studio_id = p_studio_id and o.status <> 'cancelled'
     and (o.starts_at at time zone v_tz)::date = coalesce(v_next, v_prev);

  return jsonb_build_object(
    'from', v_from,
    'next', v_next,
    'previous', v_prev,
    'classes_that_day', coalesce(v_n, 0),
    -- Whether the studio has a timetable at all, which is a different sentence
    -- from "nothing on Thursday".
    'has_any', (v_next is not null or v_prev is not null));
end $$;

revoke execute on function next_class_day(uuid, date) from public, anon, authenticated;
grant  execute on function next_class_day(uuid, date) to authenticated;
