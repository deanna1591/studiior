-- =============================================================================
-- Decision 55 — per-tenant 12-hour time format. A studio chooses 24h (13:00) or
-- 12h (1:00 PM); one formatter honours it everywhere a person reads a clock
-- time. Default '24h' keeps today's behaviour product-wide (the all_off canary
-- is unchanged). Dates and day names are never touched; the .ics DTSTART stays
-- the machine UTC format — only human text is reformatted.
--
-- creates:   fmt_clock(timestamptz, text, text)
-- re-issues: studio_by_slug(text), member_bootstrap(text), staff_bootstrap(),
--            public_schedule(text, integer), queue_booking_notifications(uuid),
--            confirm_provisional_seats_run(uuid), release_provisional_seats_run(uuid),
--            queue_occurrence_cancelled(uuid, cancellation_cause),
--            evaluate_commitment(uuid), sweep_instructor_class_reminders(timestamptz),
--            instructor_week(uuid, date, date), my_month_roster(uuid, date)
-- =============================================================================

alter table studio_settings
  add column if not exists time_format text not null default '24h';
alter table studio_settings drop constraint if exists studio_settings_time_format_ck;
alter table studio_settings add constraint studio_settings_time_format_ck
  check (time_format in ('24h', '12h'));
comment on column studio_settings.time_format is
  'Decision 55: how clock times are shown to members/instructors/staff — 24h (13:00) or 12h (1:00 PM). Default 24h.';

-- ---- the one SQL formatter --------------------------------------------------
-- 12h: FMHH12 strips the leading zero (1:00, not 01:00), MI keeps it (9:05),
-- AM gives AM/PM; midnight is 12:00 AM, noon 12:00 PM. 24h is HH24:MI. STABLE
-- (at time zone with a text zone is stable, not immutable). Reads no tables, so
-- a plain SQL helper; the studio's format is passed in, never looked up here.
create or replace function fmt_clock(p_ts timestamptz, p_tz text, p_format text default '24h')
returns text language sql stable set search_path = public as $$
  select case when p_format = '12h'
              then to_char(p_ts at time zone p_tz, 'FMHH12:MI AM')
              else to_char(p_ts at time zone p_tz, 'HH24:MI')
         end
$$;
revoke execute on function fmt_clock(timestamptz, text, text) from public, anon;
grant  execute on function fmt_clock(timestamptz, text, text) to authenticated, service_role;

-- ---- studio_by_slug (pre-login: login + install pages) ----------------------
drop function if exists studio_by_slug(text);
create function studio_by_slug(p_slug text)
 returns table(id uuid, name text, slug text, timezone text, currency text, logo_url text,
   theme_preset theme_preset, accent_color text, login_image_url text,
   login_image_focus_x smallint, login_image_focus_y smallint,
   free_first_class_enabled boolean, login_tagline text, install_welcome text, time_format text)
 language sql stable security definer set search_path to 'public' as $function$
  select s.id, s.name, s.slug, s.timezone, s.currency,
         s.logo_url, s.theme_preset, s.accent_color, s.login_image_url,
         s.login_image_focus_x, s.login_image_focus_y,
         coalesce(ss.free_first_class_enabled, false),
         s.login_tagline, s.install_welcome,
         coalesce(ss.time_format, '24h')
    from studios s
    left join studio_settings ss on ss.studio_id = s.id
   where s.slug = p_slug and s.status = 'active'
$function$;
revoke execute on function studio_by_slug(text) from public;
grant  execute on function studio_by_slug(text) to anon, authenticated, service_role;

-- ---- member_bootstrap -------------------------------------------------------
drop function if exists member_bootstrap(text);
create function member_bootstrap(p_slug text)
 returns table(member_id uuid, studio_id uuid, first_name text, last_name text, preferred_name text,
   avatar_path text, status member_status, current_streak integer, lifetime_visits integer,
   studio_name text, studio_timezone text, logo_url text, theme_preset theme_preset, accent_color text,
   checkin_opens_minutes_before integer, checkin_closes_minutes_after integer,
   cancellation_cutoff_minutes integer, booking_cutoff_minutes integer, waitlist_enabled boolean,
   billing_status platform_status, billing_locked boolean, open_offers integer,
   guest_passes_enabled boolean, has_payment_provider boolean, booking_window_days integer,
   how_to_buy text, studio_contact_email text, xendit_enabled boolean, time_format text)
 language sql stable security definer set search_path to 'public' as $function$
  select
    m.id, m.studio_id, m.first_name, m.last_name, m.preferred_name, m.avatar_url,
    m.status, coalesce(m.current_streak, 0), coalesce(m.lifetime_visits, 0),
    s.name, s.timezone, s.logo_url, s.theme_preset, s.accent_color,
    coalesce(st.checkin_opens_minutes_before, 60),
    coalesce(st.checkin_closes_minutes_after, 30),
    coalesce(st.cancellation_cutoff_minutes, 720),
    coalesce(st.booking_cutoff_minutes, 0),
    coalesce(st.waitlist_enabled, true),
    ps.status,
    coalesce(ps.status = 'locked', false),
    (select count(*)::int from waitlist_offers wo
       join bookings b on b.id = wo.booking_id
      where b.member_id = m.id
        and wo.responded_at is null
        and wo.expires_at > now()),
    coalesce(st.guest_passes_enabled, false),
    (s.stripe_account_id is not null),
    member_booking_window_days(m.id),
    st.how_to_buy,
    s.contact_email,
    exists (select 1 from studio_payment_providers spp
             where spp.studio_id = m.studio_id and spp.provider = 'xendit'),
    coalesce(st.time_format, '24h')
  from members m
  join studios s on s.id = m.studio_id
  left join studio_settings st on st.studio_id = m.studio_id
  left join platform_subscriptions ps on ps.studio_id = m.studio_id
  where m.user_id = auth.uid()
    and s.slug = p_slug
  limit 1
$function$;
revoke execute on function member_bootstrap(text) from public, anon;
grant  execute on function member_bootstrap(text) to authenticated, service_role;

-- ---- staff_bootstrap --------------------------------------------------------
drop function if exists staff_bootstrap();
create function staff_bootstrap()
 returns table(staff_id uuid, user_id uuid, email text, role staff_role, studio_id uuid,
   studio_name text, studio_timezone text, studio_currency character, studio_status text,
   location_name text, onboarding_complete boolean, is_platform_admin boolean,
   billing_status platform_status, billing_locked boolean, billing_days_left integer,
   studio_week_starts_on integer, publication_enabled boolean, time_format text)
 language sql stable security definer set search_path to 'public' as $function$
  select
    ss.id, ss.user_id, ss.email, ss.role, ss.studio_id,
    s.name, s.timezone, s.currency, s.status,
    (select l.name from locations l
      where l.studio_id = ss.studio_id and l.is_primary
      order by l.created_at limit 1),
    st.onboarding_completed_at is not null,
    is_platform_admin(),
    ps.status,
    coalesce(ps.status = 'locked', false),
    greatest(0, extract(day from
      coalesce(ps.grace_ends_at, ps.trial_ends_at) - now())::int),
    coalesce(st.week_starts_on, 1),
    coalesce(st.publication_enabled, false),
    coalesce(st.time_format, '24h')
  from studio_staff ss
  join studios s on s.id = ss.studio_id
  left join studio_settings st on st.studio_id = ss.studio_id
  left join platform_subscriptions ps on ps.studio_id = ss.studio_id
  where ss.user_id = auth.uid()
    and ss.status = 'active'
  order by ss.created_at
  limit 1
$function$;
revoke execute on function staff_bootstrap() from public, anon;
grant  execute on function staff_bootstrap() to authenticated, service_role;

-- ---- public_schedule ----
CREATE OR REPLACE FUNCTION public.public_schedule(p_slug text, p_days integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  v_fmt text;
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
  -- Decision 55: the studio's time format, pre-applied to the embed's `time`.
  select coalesce(time_format, '24h') into v_fmt
    from studio_settings where studio_id = v_studio.id;
  v_fmt := coalesce(v_fmt, '24h');
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
        -- Canonical 24h "HH:MM", zoneless and parseable: the embed builds its
        -- daybar and derives end times from this, and renders the clock itself
        -- honouring studio.time_format (Decision 55 — public_schedule exposes
        -- the setting, the embed applies it).
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
      'app_origin',   'https://' || v_studio.slug || '.studiior.app',
      'time_format',  v_fmt
    ),
    'classes', v_classes
  );

  insert into public_schedule_cache (slug, days, payload, computed_at)
  values (v_studio.slug, v_days, v_payload, now())
  on conflict (slug, days) do update
    set payload = excluded.payload, computed_at = excluded.computed_at;

  return v_payload;
end $function$

;

-- ---- queue_booking_notifications ----
CREATE OR REPLACE FUNCTION public.queue_booking_notifications(p_booking_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  b bookings%rowtype; o class_occurrences%rowtype; m members%rowtype;
  st studio_settings%rowtype; s studios%rowtype;
  v_when text; v_where text; n int := 0; v_remind timestamptz;
  v_manage text;
  v_is_free boolean; v_ff_txt text; v_ff_html text;
  v_deadline timestamptz;  -- Decision 21 amendment
  v_cutoff timestamptz;    -- Decision 30 amendment
  v_fmt text;              -- Decision 55
begin
  select * into b from bookings where id = p_booking_id;
  if not found or b.status <> 'booked' then return 0; end if;

  select * into o  from class_occurrences where id = b.occurrence_id;
  select * into m  from members            where id = b.member_id;
  select * into s  from studios            where id = b.studio_id;
  select * into st from studio_settings    where studio_id = b.studio_id;
  v_fmt := coalesce(st.time_format, '24h');

  v_when  := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY, ')
             || fmt_clock(o.starts_at, s.timezone, v_fmt);
  v_where := coalesce((select ', in ' || r.name from rooms r where r.id = o.room_id), '');
  v_manage := 'https://' || s.slug || '.'
              || coalesce(notification_setting('member_app_domain'), 'studiior.app')
              || '/class/' || o.id;

  v_is_free := b.payment_source = 'comp'
    and exists (select 1 from guest_passes gp
                 where gp.guest_booking_id = b.id and gp.host_member_id is null);
  v_ff_txt  := case when v_is_free then E'\n\nThis one''s on us — your first class is free.' else '' end;
  v_ff_html := case when v_is_free then '<p>This one''s on us — your first class is free.</p>' else '' end;

  -- Decision 21 amendment: a flex class not yet decided sends the "waiting for
  -- confirmation" receipt instead of booking_confirmed — same dedupe key.
  select deadline_at into v_deadline from flex_deadline_for_run(o.id);

  -- Decision 30 amendment: a PROVISIONAL free seat sends the free "waiting for
  -- confirmation" receipt — checked first, because a free seat on a flex class
  -- is still a free seat. Same dedupe key, so tg_cancel_booking_notifications
  -- withdraws it if the seat is later released. Keyed on the booking's OWN
  -- provisional flag (not the guest_passes row): this trigger fires on INSERT,
  -- before book_first_free writes the guest_pass, so v_is_free is not yet true —
  -- but provisional is set at insert, and only a free-first seat is ever
  -- provisional (guest and paid seats never are).
  if b.payment_source = 'comp' and b.provisional then
    select cutoff_at into v_cutoff from occurrence_guarantee_run(o.id);
    if queue_notification(b.studio_id, b.member_id, 'free_booking_pending',
          jsonb_build_object('class_name', o.name, 'when', v_when,
            'cutoff_long', fmt_clock(v_cutoff, s.timezone, v_fmt) || ' on ' || to_char(v_cutoff at time zone s.timezone, 'FMDay FMDD FMMonth YYYY'),
            'booking_id', b.id, 'occurrence_id', o.id),
          'booking_confirmed:' || b.id) is not null then n := n + 1; end if;
  elsif v_deadline is not null then
    if queue_notification(b.studio_id, b.member_id, 'flex_booking_pending',
          jsonb_build_object('class_name', o.name, 'when', v_when,
            'deadline_long', fmt_clock(v_deadline, s.timezone, v_fmt) || ' on ' || to_char(v_deadline at time zone s.timezone, 'FMDay FMDD FMMonth YYYY'),
            'booking_id', b.id, 'occurrence_id', o.id),
          'booking_confirmed:' || b.id) is not null then n := n + 1; end if;
  else
    if queue_notification(b.studio_id, b.member_id, 'booking_confirmed',
          jsonb_build_object('class_name', o.name, 'when', v_when, 'where_line', v_where,
                             'manage_link', v_manage,
                             'free_first_line', v_ff_txt, 'free_first_html', v_ff_html,
                             'booking_id', b.id, 'occurrence_id', o.id),
          'booking_confirmed:' || b.id) is not null then n := n + 1; end if;
  end if;

  v_remind := o.starts_at - make_interval(hours => coalesce(st.reminder_hours_before, 12));
  if v_remind > now() then
    if queue_notification(b.studio_id, b.member_id, 'class_reminder',
          jsonb_build_object('class_name', o.name,
                             'when_short', 'tomorrow',
                             'when_time', fmt_clock(o.starts_at, s.timezone, v_fmt),
                             'where_line', v_where),
          'class_reminder:' || b.id, v_remind) is not null then n := n + 1; end if;
  end if;

  return n;
end $function$

;

-- ---- confirm_provisional_seats_run ----
CREATE OR REPLACE FUNCTION public.confirm_provisional_seats_run(p_occurrence_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o class_occurrences%rowtype; s studios%rowtype; st studio_settings%rowtype;
        v_head int; n int := 0; r record;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then return 0; end if;
  select * into st from studio_settings where studio_id = o.studio_id;
  if st.free_first_confirm_at is null then return 0; end if;

  -- People in the room, paid or free — the same count evaluate_commitment uses.
  select count(*)::int into v_head from bookings
   where occurrence_id = p_occurrence_id
     and status in ('booked','attended','no_show','pending_payment');
  if v_head < st.free_first_confirm_at then return 0; end if;

  select * into s from studios where id = o.studio_id;
  for r in select id, member_id from bookings
            where occurrence_id = p_occurrence_id and status = 'booked' and provisional
  loop
    update bookings set provisional = false, confirmed_at = now() where id = r.id;
    perform queue_notification(o.studio_id, r.member_id, 'free_booking_confirmed',
      jsonb_build_object('class_name', o.name,
        'day',  to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth'),
        'time', fmt_clock(o.starts_at, s.timezone, coalesce(st.time_format, '24h')),
        'cancel_deadline',
          fmt_clock(o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)),
                    s.timezone, coalesce(st.time_format, '24h'))
          || ' on ' || to_char(
            (o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)))
              at time zone s.timezone, 'FMDay FMDD FMMonth YYYY'),
        'manage_link', 'https://' || s.slug || '.'
          || coalesce(notification_setting('member_app_domain'), 'studiior.app') || '/class/' || o.id,
        'occurrence_id', p_occurrence_id),
      'free_confirmed:' || r.id);
    n := n + 1;
  end loop;
  return n;
end $function$

;

-- ---- release_provisional_seats_run ----
CREATE OR REPLACE FUNCTION public.release_provisional_seats_run(p_occurrence_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o class_occurrences%rowtype; s studios%rowtype; r record; n int := 0;
        v_when text; v_when_short text; v_list text; v_fmt text;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then return 0; end if;
  select * into s from studios where id = o.studio_id;
  select coalesce(time_format, '24h') into v_fmt from studio_settings where studio_id = o.studio_id;
  v_fmt := coalesce(v_fmt, '24h');
  v_when       := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY');
  v_when_short := to_char(o.starts_at at time zone s.timezone, 'FMDy FMDD FMMon ')
                 || fmt_clock(o.starts_at, s.timezone, v_fmt);

  for r in select b.id, b.member_id from bookings b
            where b.occurrence_id = p_occurrence_id and b.status = 'booked' and b.provisional
  loop
    -- Release, directly: the explicit release_reason means the BEFORE stamp
    -- trigger leaves it, is_late_cancel false means no infraction, and a comp
    -- seat has no credit to return.
    update bookings
       set status = 'cancelled', release_reason = 'trial_not_confirmed',
           cancelled_at = now(), cancelled_by = null, is_late_cancel = false
     where id = r.id;
    update class_occurrences set booked_count = greatest(0, booked_count - 1)
     where id = p_occurrence_id;
    -- The once-ever row goes, so the person is eligible again and keeps their
    -- free class. Removed, not left 'cancelled' — free_first_eligibility's
    -- already_had_free check does not look at status.
    delete from guest_passes where guest_booking_id = r.id;

    -- Now eligible again, so the "next ones" are computed with this person's own
    -- gates: fullest first, with someone already in; fall back to any eligible.
    select string_agg(z.line, '; ' order by z.ord)
      into v_list
      from (
        select to_char(c.starts_at at time zone s.timezone, 'FMDay ') || fmt_clock(c.starts_at, s.timezone, v_fmt) || ' ' || c.name as line,
               row_number() over (order by c.headcount desc, c.starts_at) as ord
          from free_first_eligible_classes_run(o.studio_id, r.member_id, 1) c
         where c.occurrence_id <> p_occurrence_id and c.free_bookable
         limit 3) z;
    if v_list is null then
      select string_agg(z.line, '; ' order by z.ord)
        into v_list
        from (
          select to_char(c.starts_at at time zone s.timezone, 'FMDay ') || fmt_clock(c.starts_at, s.timezone, v_fmt) || ' ' || c.name as line,
                 row_number() over (order by c.headcount desc, c.starts_at) as ord
            from free_first_eligible_classes_run(o.studio_id, r.member_id, 0) c
           where c.occurrence_id <> p_occurrence_id and c.free_bookable
           limit 3) z;
    end if;

    perform queue_notification(o.studio_id, r.member_id, 'free_booking_not_confirmed',
      jsonb_build_object('class_name', o.name, 'when', v_when, 'day_short', v_when_short,
        'time', fmt_clock(o.starts_at, s.timezone, v_fmt),
        'next_three', coalesce(v_list, 'see the full schedule'),
        'occurrence_id', p_occurrence_id),
      'free_not_confirmed:' || r.id);
    n := n + 1;
  end loop;
  return n;
end $function$

;

-- ---- queue_occurrence_cancelled ----
CREATE OR REPLACE FUNCTION public.queue_occurrence_cancelled(p_occurrence_id uuid, p_cause cancellation_cause DEFAULT NULL::cancellation_cause)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o class_occurrences%rowtype; s studios%rowtype; r record; n int := 0;
        v_when text; v_when_short text; v_base text; v_fmt text;
        v_list_txt text; v_list_html text; v_line_txt text; v_line_html text;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  select * into s from studios where id = o.studio_id;
  select coalesce(time_format, '24h') into v_fmt from studio_settings where studio_id = o.studio_id;
  v_fmt := coalesce(v_fmt, '24h');
  v_when := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY');
  v_when_short := to_char(o.starts_at at time zone s.timezone, 'FMDy FMDD FMMon ')
                 || fmt_clock(o.starts_at, s.timezone, v_fmt);
  v_base := 'https://' || s.slug || '.'
            || coalesce(notification_setting('member_app_domain'), 'studiior.app') || '/class/';

  for r in select b.member_id from bookings b
            where b.occurrence_id = p_occurrence_id
              and b.status in ('booked','waitlisted')
  loop
    if p_cause = 'unmet_minimum' then
      -- Up to three upcoming, scheduled, published classes with a free space.
      select string_agg(x.line, '; ' order by x.starts_at),
             string_agg('<a href="' || v_base || x.id || '">' || x.line || '</a>', ', ' order by x.starts_at)
        into v_list_txt, v_list_html
        from (
          select o2.id, o2.starts_at,
                 to_char(o2.starts_at at time zone s.timezone, 'FMDay ') || fmt_clock(o2.starts_at, s.timezone, v_fmt) || ' ' || o2.name as line
            from class_occurrences o2
           where o2.studio_id = o.studio_id
             and o2.status = 'scheduled'
             and o2.starts_at > now()
             and o2.id <> p_occurrence_id
             and coalesce(o2.booked_count, 0) < o2.capacity
             and occurrence_published(o2.id)
           order by o2.starts_at
           limit 3) x;
      v_line_txt  := case when v_list_txt  is null then '' else ' Here are the next ones with space: ' || v_list_txt || '.' end;
      v_line_html := case when v_list_html is null then '' else '<p>Here are the next ones with space: ' || v_list_html || '.</p>' end;

      if queue_notification(o.studio_id, r.member_id, 'flex_booking_not_confirmed',
            jsonb_build_object('class_name', o.name, 'when', v_when, 'day_short', v_when_short,
              'time', fmt_clock(o.starts_at, s.timezone, v_fmt),
              'next_three_line', v_line_txt, 'next_three_html', v_line_html,
              'occurrence_id', p_occurrence_id),
            'class_cancelled:' || p_occurrence_id || ':' || r.member_id) is not null
      then n := n + 1; end if;
    else
      if queue_notification(o.studio_id, r.member_id, 'class_cancelled',
            jsonb_build_object('class_name', o.name, 'when', v_when,
                               'occurrence_id', p_occurrence_id),
            'class_cancelled:' || p_occurrence_id || ':' || r.member_id) is not null
      then n := n + 1; end if;
    end if;
  end loop;

  update notifications set status = 'cancelled'
   where status = 'scheduled'
     and dedupe_key like 'class_reminder:%'
     and payload ->> 'class_name' = o.name
     and member_id in (select member_id from bookings where occurrence_id = p_occurrence_id);

  return n;
end $function$

;

-- ---- evaluate_commitment ----
CREATE OR REPLACE FUNCTION public.evaluate_commitment(p_occurrence_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o class_occurrences%rowtype; g record; v_booked int; s studios%rowtype; r record;
begin
  select * into o from class_occurrences where id = p_occurrence_id for update;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(o.studio_id), false) and not is_service_context() then
    raise exception 'only owners, managers and the sweep decide a class' using errcode = 'PT403';
  end if;

  if o.committed_at is not null then
    return jsonb_build_object('ok', true, 'already', 'committed',
                              'booked_at_cutoff', o.booked_at_cutoff);
  end if;
  if o.status <> 'scheduled' then
    return jsonb_build_object('ok', true, 'already', o.status::text,
                              'cause', o.cancellation_cause);
  end if;

  select * into g from occurrence_guarantee_run(p_occurrence_id);
  if g.cutoff_at is null then
    return jsonb_build_object('ok', true, 'skipped', 'guarantees are off for this class');
  end if;
  if now() < g.cutoff_at then
    return jsonb_build_object('ok', true, 'skipped', 'not due', 'due_at', g.cutoff_at);
  end if;

  -- Decision 30 amendment: we are AT the class's cutoff. A free seat that never
  -- reached its confirm-at total is released NOW, before the headcount is
  -- counted — the member keeps their free class and is told, and the class is
  -- evaluated on who actually remains (so a core 1-paid + 1-released-trial runs,
  -- and a flex min-2 with 1 paid + 1 released trial does not).
  perform release_provisional_seats_run(p_occurrence_id);

  select count(*)::int into v_booked from bookings
   where occurrence_id = p_occurrence_id
     and status in ('booked','attended','no_show','pending_payment');

  if v_booked >= g.minimum
     or (o.flex and o.flex_reached_minimum_at is not null) then
    update class_occurrences
       set committed_at = now(), booked_at_cutoff = v_booked, updated_at = now()
     where id = p_occurrence_id;

    -- Decision 21 amendment: a member who booked a FLEX class was shown "waiting
    -- for confirmation" — tell them it is confirmed. Only flex; a core class was
    -- never pending to a member. Dedupe per member per occurrence.
    if g.tier = 'flex' then
      select * into s from studios where id = o.studio_id;
      for r in select member_id from bookings
                where occurrence_id = p_occurrence_id
                  and status in ('booked','attended','no_show','pending_payment')
      loop
        perform queue_notification(o.studio_id, r.member_id, 'flex_booking_confirmed',
          jsonb_build_object('class_name', o.name,
            'day',  to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth'),
            'time', fmt_clock(o.starts_at, s.timezone,
                     coalesce((select time_format from studio_settings where studio_id = o.studio_id), '24h')),
            'occurrence_id', p_occurrence_id),
          'flex_member_confirmed:' || p_occurrence_id || ':' || r.member_id);
      end loop;
    end if;

    return jsonb_build_object('ok', true, 'decision', 'committed',
      'tier', g.tier, 'booked_at_cutoff', v_booked, 'minimum', g.minimum,
      'latched', (v_booked < g.minimum));
  end if;

  update class_occurrences set booked_at_cutoff = v_booked where id = p_occurrence_id;
  perform cancel_occurrence(p_occurrence_id,
            'Did not reach its minimum by the cutoff', 'unmet_minimum');

  return jsonb_build_object('ok', true, 'decision', 'not_running',
    'tier', g.tier, 'booked_at_cutoff', v_booked, 'minimum', g.minimum);
end $function$

;

-- ---- sweep_instructor_class_reminders ----
CREATE OR REPLACE FUNCTION public.sweep_instructor_class_reminders(p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s record; i record;
  v_tz text; v_local timestamp; v_today date; v_dow int; v_hour int;
  v_from date; v_to date; v_dedupe text; v_body text; v_link text; v_fname text;
  v_ins int; n_week int := 0; n_eve int := 0; v_studios int := 0; v_fmt text;
begin
  if not is_service_context() then
    raise exception 'the reminder sweep is a background job' using errcode = 'PT403';
  end if;

  for s in
    select st.id, st.name, st.slug, st.timezone,
           coalesce(cfg.instructor_class_reminders, false) as enabled,
           coalesce(cfg.time_format, '24h') as time_format
      from studios st
      left join studio_settings cfg on cfg.studio_id = st.id
     where st.status = 'active'
     order by st.id
  loop
    v_studios := v_studios + 1;
    if not s.enabled then continue; end if;

    v_tz    := s.timezone;
    v_fmt   := s.time_format;
    v_local := p_now at time zone v_tz;
    v_today := v_local::date;
    v_dow   := extract(dow from v_local)::int;   -- 0 = Sunday
    v_hour  := extract(hour from v_local)::int;
    v_link  := 'https://' || s.slug || '.'
               || coalesce(notification_setting('member_app_domain'), 'studiior.app')
               || '/instructor/schedule';

    -- WEEKLY digest: Sunday, once past 18:00 local. The week is Monday..Sunday
    -- starting tomorrow. Dedupe on that Monday, so it sends once.
    if v_dow = 0 and v_hour >= 18 then
      v_from := v_today + 1;   -- Monday
      v_to   := v_today + 7;   -- Sunday
      for i in
        select distinct o.instructor_id
          from class_occurrences o
         where o.studio_id = s.id and o.status = 'scheduled' and o.instructor_id is not null
           and (o.starts_at at time zone v_tz)::date between v_from and v_to
           and month_published(o.studio_id, o.starts_at)
           and instructor_user_id(o.instructor_id) is not null
      loop
        select string_agg(
                 to_char(o.starts_at at time zone v_tz, 'FMDy FMDD FMMon') || '  '
                 || fmt_clock(o.starts_at, v_tz, v_fmt) || ' ' || o.name
                 || coalesce(' · ' || r.name, '')
                 || ' · ' || coalesce(o.booked_count, 0) || '/' || o.capacity,
                 E'\n' order by o.starts_at)
          into v_body
          from class_occurrences o left join rooms r on r.id = o.room_id
         where o.instructor_id = i.instructor_id and o.status = 'scheduled'
           and (o.starts_at at time zone v_tz)::date between v_from and v_to
           and month_published(o.studio_id, o.starts_at);
        if nullif(v_body, '') is null then continue; end if;
        v_fname  := split_part(coalesce((select display_name from instructors where id = i.instructor_id), ''), ' ', 1);
        v_dedupe := 'instr_week_ahead:' || i.instructor_id || ':' || v_from;
        insert into notifications (studio_id, recipient_type, user_id, template_key, channel,
                                   payload, dedupe_key, scheduled_for, status)
        values (s.id, 'staff', instructor_user_id(i.instructor_id), 'instructor_week_ahead', 'email',
                jsonb_build_object('first_name', v_fname, 'class_list', v_body,
                                   'schedule_link', v_link, 'studio_name', s.name),
                v_dedupe, now(), 'scheduled')
        on conflict (dedupe_key) do nothing;
        get diagnostics v_ins = row_count;
        n_week := n_week + v_ins;
      end loop;
    end if;

    -- EVENING-BEFORE: once past 19:00 local, tomorrow's classes. Dedupe on tomorrow.
    if v_hour >= 19 then
      v_from := v_today + 1;
      for i in
        select distinct o.instructor_id
          from class_occurrences o
         where o.studio_id = s.id and o.status = 'scheduled' and o.instructor_id is not null
           and (o.starts_at at time zone v_tz)::date = v_from
           and month_published(o.studio_id, o.starts_at)
           and instructor_user_id(o.instructor_id) is not null
      loop
        select string_agg(
                 fmt_clock(o.starts_at, v_tz, v_fmt) || ' ' || o.name
                 || coalesce(' · ' || r.name, '')
                 || ' · ' || coalesce(o.booked_count, 0) || '/' || o.capacity,
                 E'\n' order by o.starts_at)
          into v_body
          from class_occurrences o left join rooms r on r.id = o.room_id
         where o.instructor_id = i.instructor_id and o.status = 'scheduled'
           and (o.starts_at at time zone v_tz)::date = v_from
           and month_published(o.studio_id, o.starts_at);
        if nullif(v_body, '') is null then continue; end if;
        v_fname  := split_part(coalesce((select display_name from instructors where id = i.instructor_id), ''), ' ', 1);
        v_dedupe := 'instr_tomorrow:' || i.instructor_id || ':' || v_from;
        insert into notifications (studio_id, recipient_type, user_id, template_key, channel,
                                   payload, dedupe_key, scheduled_for, status)
        values (s.id, 'staff', instructor_user_id(i.instructor_id), 'instructor_tomorrow', 'email',
                jsonb_build_object('first_name', v_fname, 'class_list', v_body,
                                   'schedule_link', v_link, 'studio_name', s.name),
                v_dedupe, now(), 'scheduled')
        on conflict (dedupe_key) do nothing;
        get diagnostics v_ins = row_count;
        n_eve := n_eve + v_ins;
      end loop;
    end if;

    insert into audit_logs (studio_id, action, entity_table, after)
    values (s.id, 'instructor_reminders.swept', 'studios',
            jsonb_build_object('week', n_week, 'evening', n_eve, 'at', now()));
  end loop;

  return jsonb_build_object('studios', v_studios, 'week', n_week, 'evening', n_eve);
end $function$

;

-- ---- instructor_week ----
-- Re-issued VERBATIM from 20260831920000 (the live (uuid,date,date) body — the
-- instructor "My schedule" reader), changing ONLY local_start/local_end to
-- fmt_clock(). Every other field — room_name, capacity, booked/waitlist, tier,
-- confirmed, checked_in, checkin_open, cover_requested — is unchanged, so the
-- portal screen that reads them is untouched.
CREATE OR REPLACE FUNCTION public.instructor_week(p_instructor_id uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_studio uuid; v_tz text; v_rows jsonb; v_opens int; v_closes int; v_enforced boolean; v_fmt text;
begin
  select i.studio_id into v_studio from instructors i where i.id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  if not (is_this_instructor(p_instructor_id) or is_manager_up(v_studio)) then
    raise exception 'that is somebody else''s week' using errcode = 'PT403';
  end if;
  select s.timezone into v_tz from studios s where s.id = v_studio;
  select coalesce(checkin_opens_minutes_before, 60), coalesce(checkin_closes_minutes_after, 30),
         coalesce(checkin_window_enforced, true), coalesce(time_format, '24h')
    into v_opens, v_closes, v_enforced, v_fmt from studio_settings where studio_id = v_studio;
  v_fmt := coalesce(v_fmt, '24h');

  select coalesce(jsonb_agg(to_jsonb(x) order by x.starts_at), '[]'::jsonb)
    into v_rows from (
    select o.id as occurrence_id, o.name, o.starts_at, o.ends_at,
           (o.starts_at at time zone v_tz)::date as local_date,
           fmt_clock(o.starts_at, v_tz, v_fmt) as local_start,
           fmt_clock(o.ends_at,   v_tz, v_fmt) as local_end,
           r.name as room_name, o.capacity, o.booked_count, o.waitlist_count,
           o.status::text as status, o.cancellation_reason,
           o.cancellation_cause::text as cancellation_cause,
           o.flex, o.minimum_bookings, o.committed_at is not null as committed,
           -- occurrence_guarantee_run() RETURNS TABLE, not jsonb. It is readable
           -- by any staff of the studio, an instructor included, so this is a
           -- call-shape fix and not a permission one.
           (select g.tier::text from occurrence_guarantee_run(o.id) g) as tier,
           -- Confirmed for the week (migration 067) is a fact about the class,
           -- not about the instructor, so it travels with the row.
           o.instructor_confirmed_at is not null as confirmed,
           -- Decision 28: the instructor's own pay check-in (not the roster
           -- confirm above). Whether they have tapped, and whether the window
           -- is open right now so the tap is offered.
           o.instructor_checked_in_at is not null as checked_in,
           (not coalesce(v_enforced, true)
            or (now() >= o.starts_at - make_interval(mins => coalesce(v_opens,60))
                and now() <= o.ends_at + make_interval(mins => coalesce(v_closes,30)))) as checkin_open,
           exists (select 1 from cover_requests c
                    where c.occurrence_id = o.id and c.status = 'pending') as cover_requested
      from class_occurrences o
      left join rooms r on r.id = o.room_id
     where o.studio_id = v_studio and o.instructor_id = p_instructor_id
       and (o.starts_at at time zone v_tz)::date between p_from and p_to
       -- Decision 25: a draft month is not on their schedule.
       and month_published(v_studio, o.starts_at)) x;

  return jsonb_build_object(
    'from', p_from, 'to', p_to, 'timezone', v_tz, 'classes', v_rows,
    'state', case when jsonb_array_length(v_rows) = 0 then 'empty' else 'ok' end,
    'empty_hint', 'Nothing on this week. Classes you are down to teach appear here as soon as the studio schedules them, and open shifts you can apply for are under Shifts.');
end $function$

;

-- ---- instructor_week (2-arg overload) ----
-- The staff "My week" screen (/staff/my/week) calls this (uuid,date) overload,
-- which renders a single 'local' label per class. Re-issued verbatim from its
-- live body, changing ONLY the clock portion to fmt_clock() so the staff view
-- honours the studio's time format too (Decision 55 — "staff app").
CREATE OR REPLACE FUNCTION public.instructor_week(p_instructor_id uuid, p_week_start date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_studio uuid; v_tz text; v_week date; v_fmt text;
begin
  select i.studio_id, s.timezone into v_studio, v_tz
    from instructors i join studios s on s.id = i.studio_id where i.id = p_instructor_id;
  if v_studio is null then
    raise exception 'no such instructor' using errcode = 'PT404';
  end if;
  if not coalesce(is_manager_up(v_studio), false)
     and p_instructor_id is distinct from auth_instructor_id(v_studio)
     and not is_service_context() then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;
  select coalesce(time_format, '24h') into v_fmt from studio_settings where studio_id = v_studio;
  v_fmt := coalesce(v_fmt, '24h');

  v_week := coalesce(p_week_start,
                     studio_week_start(v_studio, (now() at time zone v_tz)::date));

  return jsonb_build_object(
    'instructor_id', p_instructor_id,
    'week_start', v_week,
    'week_end', v_week + 6,
    'classes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'occurrence_id', o.id,
               'name', o.name,
               'starts_at', o.starts_at,
               'local', to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMon, ') || fmt_clock(o.starts_at, v_tz, v_fmt),
               'booked', o.booked_count,
               'confirmed', o.instructor_confirmed_at is not null,
               'cover_status', cr.status)
             order by o.starts_at)
        from class_occurrences o
        left join lateral (
          select status from cover_requests c
           where c.occurrence_id = o.id and c.status in ('pending','approved')
           order by c.requested_at desc limit 1) cr on true
       where o.instructor_id = p_instructor_id
         and o.status = 'scheduled'
         and (o.starts_at at time zone v_tz)::date between v_week and v_week + 6
         and month_published(v_studio, o.starts_at)
    ), '[]'::jsonb),
    'unanswered', (
      select count(*) from class_occurrences o
       where o.instructor_id = p_instructor_id
         and o.status = 'scheduled'
         and o.instructor_confirmed_at is null
         and (o.starts_at at time zone v_tz)::date between v_week and v_week + 6
         and month_published(v_studio, o.starts_at)
         and not exists (select 1 from cover_requests c
                          where c.occurrence_id = o.id and c.status in ('pending','approved'))));
end $function$

;

-- ---- my_month_roster ----
CREATE OR REPLACE FUNCTION public.my_month_roster(p_instructor_id uuid, p_month date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_studio uuid; v_tz text; v_month date; v_from timestamptz; v_to timestamptz;
  rc roster_confirmations%rowtype; v_rows jsonb; v_added int; v_fmt text;
begin
  select i.studio_id, s.timezone into v_studio, v_tz
    from instructors i join studios s on s.id = i.studio_id where i.id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  select coalesce(time_format, '24h') into v_fmt from studio_settings where studio_id = v_studio;
  v_fmt := coalesce(v_fmt, '24h');
  if not (coalesce(is_this_instructor(p_instructor_id), false) or coalesce(is_manager_up(v_studio), false)) then
    raise exception 'that is somebody else''s month' using errcode = 'PT403';
  end if;

  v_month := date_trunc('month', p_month)::date;
  v_from  := (v_month::timestamp) at time zone v_tz;
  v_to    := ((v_month + interval '1 month')::timestamp) at time zone v_tz;

  select * into rc from roster_confirmations
   where studio_id = v_studio and instructor_id = p_instructor_id and month = v_month;

  -- A draft month is not theirs to see; the answer is the state, not the list.
  if not month_published(v_studio, v_from) then
    return jsonb_build_object(
      'month', v_month, 'label', to_char(v_month, 'FMMonth YYYY'),
      'state', 'draft', 'classes', '[]'::jsonb, 'count', 0,
      'notified_at', null, 'confirmed_at', null, 'added_since', 0,
      'empty_hint', 'The studio has not published ' || to_char(v_month, 'FMMonth') || ' yet. Your classes appear here, and you get an email, as soon as it does.');
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.starts_at), '[]'::jsonb),
         coalesce(count(*) filter (where x.added_after_roster), 0)::int
    into v_rows, v_added
    from (
      select o.id as occurrence_id, o.name, o.starts_at,
             (o.starts_at at time zone v_tz)::date as local_date,
             fmt_clock(o.starts_at, v_tz, v_fmt) as local_start,
             fmt_clock(o.ends_at, v_tz, v_fmt) as local_end,
             r.name as room_name, o.capacity, o.booked_count,
             o.status::text as status,
             (select c.status::text from cover_requests c
               where c.occurrence_id = o.id and c.status in ('pending','approved')
               order by c.requested_at desc limit 1) as cover_status,
             -- Created after the roster email went, so the email did not list
             -- it. created_at rather than updated_at: a booking touches
             -- updated_at, and every class somebody booked after the email
             -- would otherwise read as new. A class MOVED onto this person is
             -- emailed on its own (112) and is not counted here.
             rc.notified_at is not null and o.created_at > rc.notified_at as added_after_roster
        from class_occurrences o
        left join rooms r on r.id = o.room_id
       where o.studio_id = v_studio and o.instructor_id = p_instructor_id
         and o.status = 'scheduled'
         and o.starts_at >= v_from and o.starts_at < v_to) x;

  return jsonb_build_object(
    'month', v_month, 'label', to_char(v_month, 'FMMonth YYYY'),
    'state', case when jsonb_array_length(v_rows) = 0 then 'empty'
                  when rc.confirmed_at is not null then 'confirmed'
                  else 'unconfirmed' end,
    'classes', v_rows, 'count', jsonb_array_length(v_rows),
    'notified_at', rc.notified_at, 'confirmed_at', rc.confirmed_at,
    'added_since', v_added,
    'empty_hint', 'Nothing of yours in ' || to_char(v_month, 'FMMonth') || '. Classes you are given after publication appear here and you are emailed about each one.');
end $function$

;

-- =============================================================================
-- anon surface unchanged — exactly TWELVE (studio_by_slug/public_schedule kept
-- their anon grant; fmt_clock and the re-issued senders are not anon).
-- =============================================================================
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 12 then raise exception 'anon surface is % functions, expected exactly 12', n; end if;
end $$;
