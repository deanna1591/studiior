-- ============================================================================
-- Decision 93 amendment (10 Nov 2026): titles, spots left, coach photo.
--
-- The DB half of the amendment is one field: schedule_post_data returns
-- spots_left per class (capacity minus live seats, never below 0), so the
-- "Show spots left" tick box can append "{n} spots left" / "Full" to each line.
-- Live seats are occurrence_seats_taken(o.id) — the one definition of a taken
-- seat (a cancelled or waitlisted seat does not count). The number is the count
-- at the moment the post is made.
--
-- The titles and coach-photo background are a RENDERER change (components +
-- lib/schedule-post.mjs); the DB side is only this field.
--
-- re-issues: schedule_post_data(uuid, date, date, boolean, uuid)
--   (byte-for-byte from 20260833270000 with spots_left added in three places;
--    same signature, so the caller is unchanged.)
--
-- No new anon surface — anon stays EXACTLY THIRTEEN (asserted at apply).
-- ============================================================================

create or replace function public.schedule_post_data(
  p_studio_id uuid, p_from date, p_to date,
  p_core_only boolean default false, p_instructor_id uuid default null
) returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_tz text; v_name text; v_logo text;
  v_fmt text; v_footer text; v_hash text; v_flexmin int;
  v_days jsonb;
  v_coach_first text; v_coach_photo text;
begin
  if not coalesce(is_desk_up(p_studio_id), false) and not is_service_context() then
    raise exception 'the timetable posts are the studio''s to make' using errcode = 'PT403';
  end if;
  select timezone, name, logo_url into v_tz, v_name, v_logo
    from studios where id = p_studio_id;
  if v_tz is null then
    raise exception 'no such studio' using errcode = 'PT404';
  end if;
  if p_to < p_from then
    raise exception 'that range ends before it starts' using errcode = 'PT400';
  end if;
  if p_to - p_from > 62 then
    raise exception 'ask for at most 62 days at a time' using errcode = 'PT422';
  end if;

  -- The coach, when one is chosen. Cross-studio is refused — a studio may only
  -- post its own instructors.
  if p_instructor_id is not null then
    select nullif(split_part(coalesce(display_name, ''), ' ', 1), ''), avatar_url
      into v_coach_first, v_coach_photo
      from instructors where id = p_instructor_id and studio_id = p_studio_id;
    if not found then
      raise exception 'that instructor is not in this studio' using errcode = 'PT403';
    end if;
  end if;

  select coalesce(time_format, '24h'),
         coalesce(post_footer_line, 'Book on the app'),
         post_hashtags,
         coalesce(flex_min_bookings, 1)
    into v_fmt, v_footer, v_hash, v_flexmin
    from studio_settings where studio_id = p_studio_id;
  v_fmt    := coalesce(v_fmt, '24h');
  v_footer := coalesce(v_footer, 'Book on the app');
  v_flexmin := coalesce(v_flexmin, 1);

  with occ as (
    select o.id, o.starts_at,
           (o.starts_at at time zone v_tz)::date as d,
           coalesce(nullif(o.name, ''), ct.name, 'Class') as cname,
           nullif(split_part(coalesce(i.display_name, ''), ' ', 1), '') as coach,
           coalesce(
             o.guarantee_tier,
             case when o.flex then 'flex'::guarantee_tier end,
             ser.guarantee_tier,
             case when ser.flex then 'flex'::guarantee_tier end,
             'core'::guarantee_tier)::text as tier,
           greatest(coalesce(o.capacity, 0) - occurrence_seats_taken(o.id), 0) as spots_left
      from class_occurrences o
      left join class_series ser on ser.id = o.series_id
      left join class_types  ct  on ct.id  = o.class_type_id
      left join instructors  i   on i.id   = o.instructor_id
     where o.studio_id = p_studio_id
       and o.status = 'scheduled'
       and not o.hidden_from_members
       and (p_instructor_id is null or o.instructor_id = p_instructor_id)
       and (o.starts_at at time zone v_tz)::date between p_from and p_to
  ),
  filtered as (
    select * from occ where (not p_core_only) or tier = 'core'
  ),
  byday as (
    select d,
           count(*)::int as n,
           jsonb_agg(
             jsonb_build_object(
               'time',       fmt_clock(starts_at, v_tz, v_fmt),
               'name',       cname,
               'coach',      coach,
               'tier',       tier,
               'spots_left', spots_left
             ) order by starts_at, cname
           ) as classes
      from filtered
     group by d
  )
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'date',    to_char(d, 'YYYY-MM-DD'),
             'label',   to_char(d, 'FMDay FMDD Mon'),
             'count',   n,
             'classes', classes
           ) order by d), '[]'::jsonb)
    into v_days
    from byday;

  return jsonb_build_object(
    'studio_name', v_name,
    'logo_url',    v_logo,
    'time_zone',   v_tz,
    'time_format', v_fmt,
    'footer_line', v_footer,
    'hashtags',    v_hash,
    'flex_min',    v_flexmin,
    'coach_id',    p_instructor_id,
    'coach_first', v_coach_first,
    'coach_photo', v_coach_photo,
    'days',        v_days
  );
end $function$;

revoke execute on function schedule_post_data(uuid, date, date, boolean, uuid) from public, anon;
grant  execute on function schedule_post_data(uuid, date, date, boolean, uuid) to authenticated, service_role;

-- --- Anon stays EXACTLY THIRTEEN --------------------------------------------
do $$
declare n int;
begin
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then
    raise exception 'anon surface is % (want 13)', n;
  end if;
end $$;
