-- 147: public_schedule(slug) — the TENTH pre-login surface.
--
-- A studio embeds its own timetable on its marketing site (Webflow); a visitor
-- sees this week's real classes and clicks through to the member app to book.
-- The existing nine anon surfaces are each deliberate and this is the tenth, so
-- it is held to the same rules: it exposes ONLY what a stranger may see.
--
-- What it returns: branding (accent, theme, logo — the same fields
-- studio_by_slug feeds the member app), and for each class the date, time,
-- duration, class name and description, class-type colour, room, spaces left or
-- full, and a book_url into the member app. What it must NEVER return: any
-- member, any booking, any name of who is in a class; an instructor's full name,
-- bio or contact — first name and photo ONLY.
--
-- The guards, spelled out because this is anon:
--   * PUBLISHED months only (Decision 25). month_published() is true for a
--     studio that does not use publication and for any past month, and false for
--     an unpublished future month — which is not bookable and must not be seen.
--   * status = 'scheduled' only, which excludes a cancelled class AND a
--     not-running flex one (cancelled + unmet_minimum), exactly as the member app.
--   * spaces_left is derived from capacity and booked_count and nothing else,
--     clamped so an over-booked class reads 0, never negative or a real count of
--     who is in it.
--   * an unknown or inactive slug returns {found:false} and writes no cache —
--     it reveals nothing and cannot be used to seed junk.
--
-- CACHE IT (the brief): this is the only endpoint an unauthenticated stranger
-- can hit repeatedly, so it is a read-through cache. A hit within the TTL is one
-- indexed read of the cache row, not the joins below. The cache is written by
-- this SECURITY DEFINER function alone; anon cannot touch the table.

create table if not exists public_schedule_cache (
  slug        text        not null,
  days        int         not null,
  payload     jsonb       not null,
  computed_at timestamptz not null default now(),
  primary key (slug, days)
);
alter table public_schedule_cache enable row level security;
-- No policies, and the grants revoked: only the definer (the table owner) reaches
-- it. A cache of public data, but there is no reason for a client to read or
-- write it directly, and "closed by default" is the rule.
revoke all on public_schedule_cache from public, anon, authenticated;

create or replace function public_schedule(p_slug text, p_days int default 7)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_studio  studios%rowtype;
  v_tz      text;
  v_days    int;
  v_from    timestamptz;
  v_to      timestamptz;
  v_cached  jsonb;
  v_payload jsonb;
  v_classes jsonb;
begin
  -- Bounded: an anon caller cannot ask for an unbounded window.
  v_days := least(greatest(coalesce(p_days, 7), 1), 14);

  select * into v_studio from studios where slug = lower(p_slug) and status = 'active';
  if not found then
    -- Not a public studio. A well-formed empty shape (the embed renders nothing
    -- rather than erroring), and NO cache row for a slug that does not exist.
    return jsonb_build_object('found', false);
  end if;
  v_tz := v_studio.timezone;

  -- Read-through cache, keyed on the resolved slug + window.
  select payload into v_cached
    from public_schedule_cache
   where slug = v_studio.slug and days = v_days
     and computed_at > now() - interval '5 minutes';
  if v_cached is not null then
    return v_cached;
  end if;

  -- The window: from the start of the studio's LOCAL today, v_days ahead. Wall
  -- arithmetic then converted, so it holds across a clock change (the project's
  -- rule — never add an interval to an instant).
  v_from := (date_trunc('day', now() at time zone v_tz)) at time zone v_tz;
  v_to   := (date_trunc('day', now() at time zone v_tz) + make_interval(days => v_days)) at time zone v_tz;

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
      -- FIRST NAME and photo only. No full name, no bio, no contact detail.
      case when o.instructor_id is null then null
           else split_part(i.display_name, ' ', 1) end              as instructor_first_name,
      i.avatar_url                                                   as instructor_avatar_url,
      r.name                                                         as room,
      o.capacity,
      greatest(o.capacity - o.booked_count, 0)                       as spaces_left,
      (o.booked_count >= o.capacity)                                 as full,
      -- The member app's own booking page for THIS class, so the visitor lands
      -- exactly where they expected. studiior.app is the product's own domain,
      -- not tenant data.
      'https://' || v_studio.slug || '.studiior.app/class/' || o.id  as book_url
    from class_occurrences o
    join class_types ct on ct.id = o.class_type_id
    left join instructors i on i.id = o.instructor_id
    left join rooms r on r.id = o.room_id
    where o.studio_id = v_studio.id
      and o.status = 'scheduled'                       -- excludes cancelled + not-running
      and o.starts_at >= v_from and o.starts_at < v_to
      and month_published(v_studio.id, o.starts_at)    -- Decision 25
  ) c;

  v_payload := jsonb_build_object(
    'found', true,
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
  'for the next N days (1-14, default 7) by slug, with branding, for a public '
  'timetable embed. Published months only (Decision 25); no member data; '
  'instructor first name and photo only; spaces derived from capacity and '
  'booked_count. Read-through cached (5 min).';

-- Anon, deliberately — the tenth pre-login surface. Also authenticated (a member
-- browsing) and service_role. Never PUBLIC.
revoke all on function public_schedule(text, int) from public;
grant execute on function public_schedule(text, int) to anon, authenticated, service_role;
