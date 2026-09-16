-- 148: public_schedule learns to look ahead, and to say WHICH empty it is.
--
-- Migration 147 returned a studio's classes for the next N days. But Reform
-- Collective's timetable starts on 9 November — eight weeks out — so the embed on
-- their own site showed a blank box, and "no classes in the window", "the month
-- is not published", "the studio does not exist", "the fetch failed" and "a bad
-- key" all rendered identically. That cost an hour to diagnose.
--
-- Two changes, both in the payload (the embed renders the difference):
--   1. LOOK AHEAD. If nothing falls in the window but published classes exist
--      later, return the NEXT ones that do, with `state='upcoming'` and
--      `next_from`. A studio advertising an opening date wants its site to show
--      what is coming, not nothing.
--      THE WINDOW IS A HYBRID, and the choice is deliberate: the primary window
--      is the next N DAYS (right for a busy studio — it shows the week), and the
--      look-ahead fallback is the next N CLASSES (right for a studio that is
--      opening, has a sparse timetable, or has published a month ahead — it
--      shows real classes wherever they fall rather than a fixed empty span).
--   2. NAME THE STATE. `state` is one of:
--        in_window   — classes in the next N days (as before);
--        upcoming    — none in the window, but published classes start later
--                      (`next_from` = that date), and they are returned;
--        unpublished — scheduled classes exist ahead but their month is not
--                      published (Decision 25), so nothing is public yet
--                      (`next_from` = when they start); the studio must publish;
--        empty       — no scheduled classes ahead at all.
--      `found:false` (unknown/inactive slug) is unchanged. Fetch/HTTP failures
--      and a bad key never reach the function — the embed handles those as
--      "could not load", distinct from every state above.

create or replace function public_schedule(p_slug text, p_days int default 7)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_studio   studios%rowtype;
  v_tz       text;
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
begin
  v_days := least(greatest(coalesce(p_days, 7), 1), 14);

  select * into v_studio from studios where slug = lower(p_slug) and status = 'active';
  if not found then
    return jsonb_build_object('found', false);
  end if;
  v_tz := v_studio.timezone;

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

  -- Is there a published, scheduled class in the primary window? If not, look
  -- ahead: the next published class decides `upcoming`, and if there is none but
  -- an unpublished one exists, that is a publication problem, not an empty studio.
  if exists (
    select 1 from class_occurrences o
     where o.studio_id = v_studio.id and o.status = 'scheduled'
       and o.starts_at >= v_from and o.starts_at < v_to
       and month_published(v_studio.id, o.starts_at)
  ) then
    v_state := 'in_window';
  else
    select min(o.starts_at) into v_next_pub
      from class_occurrences o
     where o.studio_id = v_studio.id and o.status = 'scheduled'
       and o.starts_at >= v_to
       and month_published(v_studio.id, o.starts_at);
    if v_next_pub is not null then
      -- The next N CLASSES, wherever they fall — a days window would still be
      -- empty for a sparse timetable. The selection below drops the upper bound
      -- for `upcoming` and caps at v_limit.
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
        -- in_window is bounded by the N-day window; upcoming drops the upper
        -- bound and takes the next v_limit classes instead.
        and (v_state = 'upcoming' or o.starts_at < v_to)
        and month_published(v_studio.id, o.starts_at)
      order by o.starts_at
      limit v_limit
    ) c;
  else
    v_classes := '[]'::jsonb;
  end if;

  v_payload := jsonb_build_object(
    'found', true,
    'state', v_state,
    'next_from', v_next_from,   -- null unless upcoming/unpublished
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

comment on function public_schedule(text, int) is
  'The tenth pre-login surface. Anon. A studio''s published, scheduled classes '
  'by slug, with branding, for a public timetable embed. `state` is in_window / '
  'upcoming (looks ahead, with next_from) / unpublished / empty; found:false for '
  'an unknown slug. Published months only (Decision 25); no member data; '
  'instructor first name and photo only; spaces from capacity and booked_count. '
  'Read-through cached (5 min).';

-- create-or-replace keeps the ACL (anon + authenticated + service_role); the
-- grant surface is unchanged. Re-asserted for the record.
revoke all on function public_schedule(text, int) from public;
grant execute on function public_schedule(text, int) to anon, authenticated, service_role;
