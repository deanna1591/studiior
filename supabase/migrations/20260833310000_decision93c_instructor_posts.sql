-- ============================================================================
-- Decision 93 part (c): instructor posts and Share.
--
-- Instructors make and share posts of their OWN classes from the instructor app.
-- The post DATA and the BRAND KIT already have readers, but those are desk-up
-- guarded, so an instructor cannot call them. Rather than duplicate their bodies
-- we extract the shared work into unguarded `_run` twins (service-role only, the
-- internal-caller convention) and give each guarded reader a thin wrapper:
--
--   schedule_post_data(studio, from, to, core_only, instructor)  -- desk-up wrapper
--     -> schedule_post_data_run(...)                             -- the body
--   brand_kit_defaults(studio)                                   -- desk-up wrapper
--     -> brand_kit_defaults_run(studio)                          -- the body
--
-- Then the instructor readers resolve the caller from auth (never a parameter)
-- and call the `_run`s:
--
--   instructor_schedule_post_data(from, to, core_only)
--     -> the caller's own instructor + studio -> schedule_post_data_run(...)
--   instructor_brand_kit()
--     -> the caller's studio kit spec + footer/hashtags/post_style (read-only)
--
-- Both instructor readers are authenticated-only and refuse a caller who is not
-- an active instructor of the studio. A `post-images` insert policy lets an
-- instructor upload the Download copy into their own studio's folder.
--
-- creates: brand_kit_defaults_run(uuid), schedule_post_data_run(uuid, date, date, boolean, uuid), instructor_schedule_post_data(date, date, boolean), instructor_brand_kit()
-- re-issues: brand_kit_defaults(uuid), brand_kit_current(uuid), schedule_post_data(uuid, date, date, boolean, uuid)
--
-- No new anon surface — anon stays EXACTLY THIRTEEN (asserted at apply).
-- ============================================================================

-- --- brand_kit_defaults: unguarded body + thin desk-up wrapper ---------------
create or replace function brand_kit_defaults_run(p_studio_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare s studios%rowtype; v_surface text; v_paper text; v_ink text; v_ink2 text;
begin
  select * into s from studios where id = p_studio_id;
  -- theme preset tokens, mirroring lib/theme.ts PRESETS
  case s.theme_preset
    when 'clean' then v_surface := '#FFFFFF'; v_paper := '#FFFFFF'; v_ink := '#0A0A0A'; v_ink2 := '#404040';
    when 'calm'  then v_surface := '#FBFCFB'; v_paper := '#F2F5F2'; v_ink := '#1A211A'; v_ink2 := '#4A554A';
    when 'bold'  then v_surface := '#16181A'; v_paper := '#0E1012'; v_ink := '#F5F5F4'; v_ink2 := '#C4C4C2';
    else              v_surface := '#FFFFFF'; v_paper := '#FAFAF7'; v_ink := '#14170E'; v_ink2 := '#57534E';
  end case;
  return jsonb_build_object(
    'colors', jsonb_build_object(
      'background', v_paper, 'surface', v_surface, 'ink', v_ink,
      'accent', coalesce(nullif(s.accent_color, ''), '#78716C'),
      'secondary', v_ink2),
    'display_font', 'Space Grotesk', 'body_font', 'Space Grotesk',
    'layout', 'list', 'radius', 'small',
    'tone', 'Clean, calm and legible.',
    'logo_placement', 'top-left', 'background_treatment', 'none');
end $$;
revoke execute on function brand_kit_defaults_run(uuid) from public, anon, authenticated;
grant  execute on function brand_kit_defaults_run(uuid) to service_role;

create or replace function brand_kit_defaults(p_studio_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(is_desk_up(p_studio_id), false) and not is_service_context() then
    raise exception 'only staff read the brand kit' using errcode = 'PT403';
  end if;
  return brand_kit_defaults_run(p_studio_id);
end $$;
revoke execute on function brand_kit_defaults(uuid) from public, anon;
grant  execute on function brand_kit_defaults(uuid) to authenticated, service_role;

-- brand_kit_current now reaches the unguarded twin (it is itself desk-up guarded)
create or replace function brand_kit_current(p_studio_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare k studio_brand_kits%rowtype; v_def jsonb; v_today date; v_used int; v_reset date;
begin
  if not coalesce(is_desk_up(p_studio_id), false) and not is_service_context() then
    raise exception 'only staff read the brand kit' using errcode = 'PT403';
  end if;
  v_def := brand_kit_defaults_run(p_studio_id);
  select * into k from studio_brand_kits where studio_id = p_studio_id and is_current;
  select (now() at time zone coalesce(timezone, 'UTC'))::date into v_today from studios where id = p_studio_id;
  select brand_kit_runs_month, brand_kit_runs_reset_on into v_used, v_reset
    from studio_settings where studio_id = p_studio_id;
  if v_reset is null or v_today >= v_reset then v_used := 0; end if;
  return jsonb_build_object(
    'spec',      coalesce(k.spec, v_def),
    'source',    coalesce(k.source, 'default'),
    'defaults',  v_def,
    'runs_used', coalesce(v_used, 0),
    'runs_cap',  10);
end $$;
revoke execute on function brand_kit_current(uuid) from public, anon;
grant  execute on function brand_kit_current(uuid) to authenticated, service_role;

-- --- schedule_post_data: unguarded body + thin desk-up wrapper ---------------
-- The body is byte-for-byte migration 20260833300000 minus the desk-up guard.
create or replace function schedule_post_data_run(
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
revoke execute on function schedule_post_data_run(uuid, date, date, boolean, uuid) from public, anon, authenticated;
grant  execute on function schedule_post_data_run(uuid, date, date, boolean, uuid) to service_role;

create or replace function public.schedule_post_data(
  p_studio_id uuid, p_from date, p_to date,
  p_core_only boolean default false, p_instructor_id uuid default null
) returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
begin
  if not coalesce(is_desk_up(p_studio_id), false) and not is_service_context() then
    raise exception 'the timetable posts are the studio''s to make' using errcode = 'PT403';
  end if;
  return schedule_post_data_run(p_studio_id, p_from, p_to, p_core_only, p_instructor_id);
end $function$;
revoke execute on function schedule_post_data(uuid, date, date, boolean, uuid) from public, anon;
grant  execute on function schedule_post_data(uuid, date, date, boolean, uuid) to authenticated, service_role;

-- --- The instructor readers: the caller's OWN classes and studio kit ---------
-- The caller is resolved from auth, never a parameter. A non-instructor (member,
-- front desk with no instructor row, a stranger) is refused PT403.
create or replace function instructor_schedule_post_data(
  p_from date, p_to date, p_core_only boolean default false
) returns jsonb
 language plpgsql stable security definer set search_path = public
as $$
declare v_inst uuid; v_studio uuid;
begin
  select i.id, i.studio_id into v_inst, v_studio
    from instructors i
    join studio_staff ss on ss.id = i.staff_id
   where ss.user_id = auth.uid() and ss.status = 'active'
   order by i.created_at, i.id
   limit 1;
  if v_inst is null then
    raise exception 'you are not an instructor here' using errcode = 'PT403';
  end if;
  return schedule_post_data_run(v_studio, p_from, p_to, p_core_only, v_inst);
end $$;
revoke execute on function instructor_schedule_post_data(date, date, boolean) from public, anon;
grant  execute on function instructor_schedule_post_data(date, date, boolean) to authenticated, service_role;

create or replace function instructor_brand_kit()
returns jsonb
 language plpgsql stable security definer set search_path = public
as $$
declare v_studio uuid; v_spec jsonb; v_footer text; v_hash text; v_style text;
begin
  select i.studio_id into v_studio
    from instructors i
    join studio_staff ss on ss.id = i.staff_id
   where ss.user_id = auth.uid() and ss.status = 'active'
   order by i.created_at, i.id
   limit 1;
  if v_studio is null then
    raise exception 'you are not an instructor here' using errcode = 'PT403';
  end if;
  select spec into v_spec from studio_brand_kits where studio_id = v_studio and is_current;
  if v_spec is null then v_spec := brand_kit_defaults_run(v_studio); end if;
  select coalesce(post_footer_line, 'Book on the app'), post_hashtags, coalesce(post_style, 'invitation')
    into v_footer, v_hash, v_style
    from studio_settings where studio_id = v_studio;
  return jsonb_build_object(
    'spec',        v_spec,
    'footer_line', coalesce(v_footer, 'Book on the app'),
    'hashtags',    v_hash,
    'post_style',  coalesce(v_style, 'invitation'));
end $$;
revoke execute on function instructor_brand_kit() from public, anon;
grant  execute on function instructor_brand_kit() to authenticated, service_role;

-- --- post-images: an instructor may upload the Download copy into their folder
-- Permissive policies are OR'd with the desk-up post_images_write, so an
-- instructor whose active studio matches the path's first folder can insert.
drop policy if exists post_images_write_instructor on storage.objects;
create policy post_images_write_instructor on storage.objects for insert to authenticated
  with check (
    bucket_id = 'post-images'
    and exists (
      select 1 from instructors i
      join studio_staff ss on ss.id = i.staff_id
      where ss.user_id = auth.uid() and ss.status = 'active'
        and i.studio_id = ((storage.foldername(name))[1])::uuid));

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
