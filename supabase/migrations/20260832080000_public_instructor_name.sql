-- =============================================================================
-- Decision 51 (instructor-name rule): the WEBSITE schedule names an instructor
-- by first name only (default) or full name, per tenant.
--
-- re-issues: public_schedule(text, integer)
--
-- studio_settings.public_instructor_name ('first' | 'full', default 'first')
-- governs the public_schedule embed only — the member app and staff screens are
-- unchanged. public_schedule fills instructor_first_name with the first word
-- ('first', today's behaviour) or the full display_name ('full'); the column
-- name is kept for embed compatibility. Default 'first', so every existing
-- studio and the all_off canary are unchanged. create-or-replace keeps
-- public_schedule's anon grant (one of the twelve).
-- =============================================================================

alter table studio_settings
  add column if not exists public_instructor_name text not null default 'first';
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'studio_settings_public_instructor_name_check') then
    alter table studio_settings
      add constraint studio_settings_public_instructor_name_check
      check (public_instructor_name in ('first','full'));
  end if;
end $$;
comment on column studio_settings.public_instructor_name is
  'Decision 51: how the website schedule (public_schedule embed) names an '
  'instructor — ''first'' (first name only, default) or ''full'' (full display_name). '
  'The member app and staff screens are unaffected.';

create or replace function public_schedule(p_slug text, p_days int default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_studio   studios%rowtype;
  v_tz       text;
  v_window   int;
  v_days     int;
  v_from     timestamptz;
  v_to       timestamptz;
  v_cached   jsonb;
  v_payload  jsonb;
  v_classes  jsonb;
  v_state    text;
  v_next_pub timestamptz;
  v_next_any timestamptz;
  v_next_from text;
  v_limit    int := 40;   -- the fallback's "next N classes" cap (bounded for anon)
  v_name_mode text;
begin
  select * into v_studio from studios where slug = lower(p_slug) and status = 'active';
  if not found then
    return jsonb_build_object('found', false);
  end if;
  v_tz := v_studio.timezone;

  -- The window is the studio's booking window (default 30 if unset). p_days may
  -- ask for fewer but never more.
  select coalesce(booking_window_days, 30) into v_window
    from studio_settings where studio_id = v_studio.id;
  v_window := coalesce(v_window, 30);
  select coalesce(public_instructor_name, 'first') into v_name_mode
    from studio_settings where studio_id = v_studio.id;
  v_name_mode := coalesce(v_name_mode, 'first');
  v_days := least(greatest(coalesce(p_days, v_window), 1), v_window);

  select payload into v_cached
    from public_schedule_cache
   where slug = v_studio.slug and days = v_days
     and computed_at > now() - interval '5 minutes';
  if v_cached is not null then
    return v_cached;
  end if;

  -- The primary window: from the start of the studio's LOCAL today, v_days ahead.
  v_from := (date_trunc('day', now() at time zone v_tz)) at time zone v_tz;
  v_to   := (date_trunc('day', now() at time zone v_tz) + make_interval(days => v_days)) at time zone v_tz;

  if exists (
    select 1 from class_occurrences o
     where o.studio_id = v_studio.id and o.status = 'scheduled'
       and o.starts_at >= v_from and o.starts_at < v_to
       and month_published(v_studio.id, o.starts_at)
       and (o.staffing = 'assigned' or not studio_hides_unstaffed(v_studio.id))
  ) then
    v_state := 'in_window';
  else
    select min(o.starts_at) into v_next_pub
      from class_occurrences o
     where o.studio_id = v_studio.id and o.status = 'scheduled'
       and o.starts_at >= v_to
       and month_published(v_studio.id, o.starts_at)
       and (o.staffing = 'assigned' or not studio_hides_unstaffed(v_studio.id));
    if v_next_pub is not null then
      v_state    := 'upcoming';
      v_next_from := to_char(v_next_pub at time zone v_tz, 'YYYY-MM-DD');
    else
      select min(o.starts_at) into v_next_any
        from class_occurrences o
       where o.studio_id = v_studio.id and o.status = 'scheduled'
         and o.starts_at >= v_from;
      if v_next_any is not null then
        v_state    := 'unpublished';
        v_next_from := to_char(v_next_any at time zone v_tz, 'YYYY-MM-DD');
      else
        v_state := 'empty';
      end if;
    end if;
  end if;

  if v_state in ('in_window', 'upcoming') then
    select coalesce(jsonb_agg(c order by c.starts_at), '[]'::jsonb) into v_classes
    from (
      select
        o.id,
        to_char(o.starts_at at time zone v_tz, 'YYYY-MM-DD')            as date,
        to_char(o.starts_at at time zone v_tz, 'HH24:MI')              as time,
        o.starts_at,
        ct.duration_minutes,
        ct.name                                                        as class_name,
        ct.description,
        ct.color,
        case when o.instructor_id is null then null
             when v_name_mode = 'full' then i.display_name
             else split_part(i.display_name, ' ', 1) end              as instructor_first_name,
        i.avatar_url                                                   as instructor_avatar_url,
        r.name                                                         as room,
        o.capacity,
        greatest(o.capacity - o.booked_count, 0)                       as spaces_left,
        (o.booked_count >= o.capacity)                                 as full,
        'https://' || v_studio.slug || '.studiior.app/class/' || o.id  as book_url
      from class_occurrences o
      join class_types ct on ct.id = o.class_type_id
      left join instructors i on i.id = o.instructor_id
      left join rooms r on r.id = o.room_id
      where o.studio_id = v_studio.id
        and o.status = 'scheduled'
        and o.starts_at >= v_from
        and (v_state = 'upcoming' or o.starts_at < v_to)
        and month_published(v_studio.id, o.starts_at)
        and (o.staffing = 'assigned' or not studio_hides_unstaffed(v_studio.id))
      order by o.starts_at
      limit v_limit
    ) c;
  else
    v_classes := '[]'::jsonb;
  end if;

  v_payload := jsonb_build_object(
    'found', true,
    'state', v_state,
    'next_from', v_next_from,
    'window_days', v_days,
    'generated_at', now(),
    'studio', jsonb_build_object(
      'name',         v_studio.name,
      'slug',         v_studio.slug,
      'timezone',     v_tz,
      'accent_color', v_studio.accent_color,
      'theme_preset', v_studio.theme_preset,
      'logo_url',     v_studio.logo_url,
      'app_origin',   'https://' || v_studio.slug || '.studiior.app'
    ),
    'classes', v_classes
  );

  insert into public_schedule_cache (slug, days, payload, computed_at)
  values (v_studio.slug, v_days, v_payload, now())
  on conflict (slug, days) do update
    set payload = excluded.payload, computed_at = excluded.computed_at;

  return v_payload;
end $$;


-- The anon surface is unchanged — exactly TWELVE pre-login functions.
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 12 then raise exception 'anon surface is % functions, expected exactly 12', n; end if;
end $$;
