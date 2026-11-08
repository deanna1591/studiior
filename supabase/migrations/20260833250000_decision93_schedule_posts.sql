-- ============================================================================
-- Decision 93 slice 2: Schedule posts.
--
-- A studio makes a social post of its timetable, drawn by our renderer in the
-- studio's brand kit. Slice 2 is the data + the post screen only (no Claude
-- editing — slice 3 — and no Meta posting — part b).
--
-- creates: schedule_post_data(uuid, date, date, boolean)
--
-- Schema: a private bucket `post-images` (png, 5 MB, path {studio}/{yyyy-mm}/{file},
-- desk-up upload+read) for the PNGs part (b) will post; two studio_settings
-- columns `post_footer_line` (default 'Book on the app') + `post_hashtags`
-- (registered, so audit-settings-ui sees their write path). One desk-up read RPC
-- returns the visible scheduled classes in a range grouped by day, with the time
-- via fmt_clock, class name, instructor first name and tier, plus the studio name,
-- logo, time zone and the two settings — all in one call. None anon; anon stays
-- THIRTEEN (asserted at apply). Hidden and cancelled classes never appear.
-- ============================================================================

-- --- Settings ---------------------------------------------------------------
alter table studio_settings
  add column if not exists post_footer_line text not null default 'Book on the app',
  add column if not exists post_hashtags    text;

-- --- Private bucket for the exported PNGs (part b will post them) ------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('post-images', 'post-images', false, 5242880, array['image/png'])
on conflict (id) do nothing;

-- Desk-up of the path's studio may upload and read (the {studio}/{yyyy-mm}/{file}
-- shape — foldername[1] is the studio). No service-role key anywhere; the staff
-- session writes under its own RLS, exactly like Decision 89's message-attachments.
drop policy if exists post_images_write  on storage.objects;
drop policy if exists post_images_read   on storage.objects;
drop policy if exists post_images_update on storage.objects;
drop policy if exists post_images_delete on storage.objects;

create policy post_images_write on storage.objects for insert to authenticated
  with check (bucket_id = 'post-images'
    and coalesce(is_desk_up(((storage.foldername(name))[1])::uuid), false));
create policy post_images_read on storage.objects for select to authenticated
  using (bucket_id = 'post-images'
    and coalesce(is_desk_up(((storage.foldername(name))[1])::uuid), false));
create policy post_images_update on storage.objects for update to authenticated
  using (bucket_id = 'post-images'
    and coalesce(is_desk_up(((storage.foldername(name))[1])::uuid), false));
create policy post_images_delete on storage.objects for delete to authenticated
  using (bucket_id = 'post-images'
    and coalesce(is_desk_up(((storage.foldername(name))[1])::uuid), false));

-- --- The one read RPC -------------------------------------------------------
-- Desk-up (front desk makes posts too). Returns the timetable the way a post
-- shows it: scheduled + not hidden, grouped by the studio-local day, each class
-- carrying the clock (in the studio's format), name, instructor first name and
-- tier. `p_core_only` keeps only core-tier classes. Cross-studio / instructor /
-- anon are refused — this is a studio's own marketing data.
create or replace function public.schedule_post_data(
  p_studio_id uuid, p_from date, p_to date, p_core_only boolean default false
) returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_tz text; v_name text; v_logo text;
  v_fmt text; v_footer text; v_hash text; v_flexmin int;
  v_days jsonb;
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
             'core'::guarantee_tier)::text as tier
      from class_occurrences o
      left join class_series ser on ser.id = o.series_id
      left join class_types  ct  on ct.id  = o.class_type_id
      left join instructors  i   on i.id   = o.instructor_id
     where o.studio_id = p_studio_id
       and o.status = 'scheduled'
       and not o.hidden_from_members
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
               'time',  fmt_clock(starts_at, v_tz, v_fmt),
               'name',  cname,
               'coach', coach,
               'tier',  tier
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
    'days',        v_days
  );
end $function$;

revoke execute on function schedule_post_data(uuid, date, date, boolean) from public, anon;
grant  execute on function schedule_post_data(uuid, date, date, boolean) to authenticated, service_role;

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
