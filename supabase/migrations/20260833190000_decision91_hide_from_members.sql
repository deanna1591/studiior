-- =============================================================================
-- Decision 91 — hide a class from members (per class, not a setting).
-- =============================================================================
-- Staff take a single class off the member side without cancelling it.
-- class_occurrences.hidden_from_members (default false). When true the class is
-- gone from every member-facing surface — the Book tab (occ_member_read RLS),
-- the public embed, member_next_class_day, {upcoming_classes} (closure_upcoming_
-- block), {next_three} (queue_occurrence_cancelled), the free-first picker, and
-- the convert_book_first "has bookable classes" check — and book_class /
-- book_first_free refuse it with 'class_hidden' UNLESS the member already holds a
-- non-cancelled booking (so cancel/rebook and waitlist promotion still work). A
-- member already booked keeps seeing it (occ_member_own_read, untouched) and in
-- their reminders. Instructors and staff are UNCHANGED: the class stays on the
-- staff Schedule (schedule_range carries occ_hidden for a "Hidden" chip, no
-- filter), the roster, and instructor pay; no email is sent. next_class_day is
-- STAFF-ONLY (manager-up; staff Schedule + dashboard), so it is NOT filtered —
-- the canonical decision says staff see no change. Audited. Anon stays THIRTEEN.
--
-- creates:   set_occurrence_visibility(uuid, boolean)
-- re-issues: schedule_range(uuid, date, date), book_class(uuid, uuid, booking_source, text, payment_source), book_first_free(uuid), public_schedule(text, integer), member_next_class_day(uuid, date), closure_upcoming_block(uuid, date), free_first_eligible_classes_run(uuid, uuid, integer), convert_keep_sweep(uuid, timestamp with time zone), queue_occurrence_cancelled(uuid, cancellation_cause)
-- =============================================================================

alter table class_occurrences add column if not exists hidden_from_members boolean not null default false;

-- hidden_from_members is a config toggle, not a human edit — it must not promote
-- a demo occurrence to real (mirrors assignment_confirmed_by, migration 770/318).
drop trigger if exists occurrences_promote_demo on class_occurrences;
create trigger occurrences_promote_demo before update on class_occurrences for each row
  execute function tg_promote_edited_demo_row('updated_at,booked_count,waitlist_count,series_slot_at,staffing,is_exception,assigned_by,assignment_requested_at,assignment_confirmed_at,hidden_from_members');

-- ---------------------------------------------------------------------------
-- set_occurrence_visibility — manager-up, audited, no email. visible=false hides.
-- ---------------------------------------------------------------------------
create or replace function set_occurrence_visibility(p_occurrence_id uuid, p_visible boolean)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare o class_occurrences%rowtype;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no_such_class'); end if;
  if not coalesce(is_manager_up(o.studio_id), false) then
    raise exception 'only owners and managers hide a class from members' using errcode = 'PT403';
  end if;
  update class_occurrences set hidden_from_members = not coalesce(p_visible, true), updated_at = now()
   where id = p_occurrence_id;
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (o.studio_id, auth.uid(), 'occurrence.visibility_set', 'class_occurrences', p_occurrence_id,
          jsonb_build_object('hidden_from_members', not coalesce(p_visible, true)));
  return jsonb_build_object('ok', true, 'hidden_from_members', not coalesce(p_visible, true));
end $fn$;
revoke execute on function set_occurrence_visibility(uuid, boolean) from public, anon;
grant  execute on function set_occurrence_visibility(uuid, boolean) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- MEMBERS: the Book tab / class page / Home read class_occurrences directly, so
-- the RLS is the boundary. The booked-member exception is occ_member_own_read
-- (025, OR'd, untouched): a member keeps seeing a class they booked even hidden.
-- ---------------------------------------------------------------------------
drop policy occ_member_read on class_occurrences;
create policy occ_member_read on class_occurrences for select
  using (studio_id in (select auth_member_studios())
         and status = 'scheduled'
         and month_published(studio_id, starts_at)
         and (staffing = 'assigned' or not studio_hides_unstaffed(studio_id))
         and not hidden_from_members);

-- ---------------------------------------------------------------------------
-- schedule_range (STAFF): carries occ_hidden for the "Hidden" chip; staff see all.
-- ---------------------------------------------------------------------------
drop function if exists schedule_range(uuid, date, date);
create function public.schedule_range(p_studio_id uuid, p_from date, p_to date)
 RETURNS TABLE(occ_id uuid, occ_name text, starts_at timestamp with time zone, ends_at timestamp with time zone, local_date date, local_start text, local_end text, start_minutes integer, end_minutes integer, occ_instructor_id uuid, room_name text, occ_capacity integer, occ_booked integer, occ_waitlist integer, occ_staffing text, occ_status text, occ_flex boolean, occ_confirmed boolean, occ_tier text, occ_standalone boolean, occ_series_tier text, occ_minimum integer, occ_cancellation_cause text, occ_assignment_requested boolean, occ_assignment_confirmed boolean, occ_free_first jsonb, occ_hidden boolean)
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
         case when coalesce(v_ff, false) then effective_free_first(o.id) else null end,
         o.hidden_from_members
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

-- ---------------------------------------------------------------------------
-- Member-facing readers: exclude hidden occurrences (re-issued from newest).
-- ---------------------------------------------------------------------------
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
     where o.studio_id = v_studio.id and o.status = 'scheduled' and not o.hidden_from_members
       and o.starts_at >= v_from and o.starts_at < v_to
       and month_published(v_studio.id, o.starts_at)
       and (o.staffing = 'assigned' or not studio_hides_unstaffed(v_studio.id))
  ) then
    v_state := 'in_window';
  else
    select min(o.starts_at) into v_next_pub
      from class_occurrences o
     where o.studio_id = v_studio.id and o.status = 'scheduled' and not o.hidden_from_members
       and o.starts_at >= v_to
       and month_published(v_studio.id, o.starts_at)
       and (o.staffing = 'assigned' or not studio_hides_unstaffed(v_studio.id));
    if v_next_pub is not null then
      v_state    := 'upcoming';
      v_next_from := to_char(v_next_pub at time zone v_tz, 'YYYY-MM-DD');
    else
      select min(o.starts_at) into v_next_any
        from class_occurrences o
       where o.studio_id = v_studio.id and o.status = 'scheduled' and not o.hidden_from_members
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
        and o.status = 'scheduled' and not o.hidden_from_members
        and o.starts_at >= v_from
        and (v_state = 'upcoming' or o.starts_at < v_to)
        and month_published(v_studio.id, o.starts_at)
        and (o.staffing = 'assigned' or not studio_hides_unstaffed(v_studio.id))
      order by o.starts_at
      -- The cap bounds the unbounded-ahead 'upcoming' fallback only. 'in_window'
      -- is already bounded by booking_window_days, so it returns everything.
      limit case when v_state = 'upcoming' then v_limit else null end
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
end $function$;

CREATE OR REPLACE FUNCTION public.member_next_class_day(p_studio_id uuid, p_from date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_tz text; v_from date; v_next date; v_n int;
begin
  if not exists (select 1 from members where studio_id = p_studio_id and user_id = auth.uid()) then
    raise exception 'not a member here' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  v_from := coalesce(p_from, (now() at time zone v_tz)::date);

  select min((o.starts_at at time zone v_tz)::date) into v_next
    from class_occurrences o
   where o.studio_id = p_studio_id and o.status = 'scheduled' and not o.hidden_from_members
     and (o.starts_at at time zone v_tz)::date > v_from
     and month_published(o.studio_id, o.starts_at)
     and (o.staffing = 'assigned' or not studio_hides_unstaffed(o.studio_id));
  if v_next is null then return null; end if;

  select count(*) into v_n from class_occurrences o
   where o.studio_id = p_studio_id and o.status = 'scheduled' and not o.hidden_from_members
     and (o.starts_at at time zone v_tz)::date = v_next
     and month_published(o.studio_id, o.starts_at)
     and (o.staffing = 'assigned' or not studio_hides_unstaffed(o.studio_id));

  return jsonb_build_object('date', v_next, 'count', v_n);
end $function$;

CREATE OR REPLACE FUNCTION public.closure_upcoming_block(p_studio_id uuid, p_resume_date date)
 RETURNS TABLE(html text, txt text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s studios%rowtype; v_fmt text; v_book text;
  v_cards_html text := ''; v_cards_txt text := ''; r record; v_detail text; v_n int := 0;
begin
  select * into s from studios where id = p_studio_id;
  v_fmt := coalesce((select time_format from studio_settings where studio_id = p_studio_id), '24h');
  v_book := member_portal_url(p_studio_id, '/book?d=' || coalesce(p_resume_date::text, ''));

  for r in
    select coalesce(nullif(o.name, ''), ct.name) as name,
           o.starts_at,
           split_part(coalesce(i.display_name, ''), ' ', 1) as first,
           (coalesce(o.guarantee_tier,
                     case when o.flex then 'flex'::guarantee_tier end,
                     cs.guarantee_tier,
                     case when cs.flex then 'flex'::guarantee_tier end,
                     'core') = 'core') as is_core
      from class_occurrences o
      join class_types ct on ct.id = o.class_type_id
      left join class_series cs on cs.id = o.series_id
      left join instructors i on i.id = o.instructor_id
     where o.studio_id = p_studio_id
       and o.status = 'scheduled' and not o.hidden_from_members
       and p_resume_date is not null
       and (o.starts_at at time zone s.timezone)::date >= p_resume_date
       and o.booked_count < o.capacity
       and occurrence_published(o.id)
     order by is_core desc, o.starts_at
     limit 8
  loop
    v_n := v_n + 1;
    v_detail := concat_ws(' · ',
      to_char(r.starts_at at time zone s.timezone, 'FMDy FMDD FMMon'),
      fmt_clock(r.starts_at, s.timezone, v_fmt),
      nullif('with ' || r.first, 'with '));
    v_cards_html := v_cards_html
      || '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0">'
      || '<tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px">'
      || '<div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">' || r.name || '</div>'
      || '<div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">' || v_detail || '</div>'
      || '</td></tr></table>';
    v_cards_txt := v_cards_txt || '- ' || r.name || ' · ' || v_detail || E'\n';
  end loop;

  if v_n = 0 then
    html := '<p><a href="' || v_book || '">Book your week</a></p>';
    txt  := 'Book your week: ' || v_book;
  else
    html := '<p>Here is some of what is on when we are back:</p>' || v_cards_html
      || '<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0">'
      || '<tr><td align="center" style="border-radius:6px;background:{accent}">'
      || '<a href="' || v_book || '" style="display:inline-block;padding:11px 24px;'
      || 'font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;'
      || 'font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">'
      || 'See the full schedule</a></td></tr></table>';
    txt := E'Here is some of what is on when we are back:\n' || v_cards_txt || E'\nSee the full schedule: ' || v_book;
  end if;
  return next;
end $function$;

CREATE OR REPLACE FUNCTION public.free_first_eligible_classes_run(p_studio_id uuid, p_member_id uuid, p_min_headcount integer DEFAULT 0)
 RETURNS TABLE(occurrence_id uuid, name text, starts_at timestamp with time zone, duration_min integer, room_name text, instructor_first text, headcount integer, capacity integer, free_bookable boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare st studio_settings%rowtype; v_elig jsonb;
begin
  select * into st from studio_settings where studio_id = p_studio_id;
  v_elig := free_first_eligibility(p_studio_id, p_member_id);
  if not coalesce((v_elig ->> 'ok')::boolean, false) then return; end if;

  return query
  select o.id, o.name, o.starts_at,
         coalesce(ct.duration_minutes, 0),
         (select r.name from rooms r where r.id = o.room_id),
         (select split_part(i.display_name, ' ', 1) from instructors i where i.id = o.instructor_id),
         coalesce(o.booked_count, 0), o.capacity,
         ( o.capacity - occurrence_seats_taken(o.id) - occurrence_seats_held(o.id) >= 1
           and (st.free_first_seats_per_class is null
                or (select count(*) from bookings b
                     where b.occurrence_id = o.id and b.status = 'booked'
                       and b.payment_source = 'comp'
                       and exists (select 1 from guest_passes gp
                                    where gp.guest_booking_id = b.id and gp.host_member_id is null))
                    < st.free_first_seats_per_class) )
    from class_occurrences o
    left join class_series ser on ser.id = o.series_id
    left join class_types  ct  on ct.id  = o.class_type_id
   where o.studio_id = p_studio_id
     and o.status = 'scheduled' and not o.hidden_from_members
     and o.starts_at > now()
     and o.starts_at <= now() + make_interval(days => coalesce(st.booking_window_days, 30))
     and o.starts_at >= now() + make_interval(mins => coalesce(st.booking_cutoff_minutes, 0))
     -- Decision 48 (and scheduled + published) for THIS member.
     and occurrence_member_visible_run(o.id, p_member_id)
     -- Decision 30 amendment (b): a per-class override. 'closed' → never;
     -- 'open' → skip core_only and the series switch (seat cap and peak still
     -- apply below); null → the studio rules.
     and o.free_first_override is distinct from 'closed'
     and (o.free_first_override = 'open' or (
            -- core_only: the CONFIGURED tier (the studio's intent), not demoted.
            (not coalesce(st.free_first_core_only, false)
             or coalesce(o.guarantee_tier, case when o.flex then 'flex'::guarantee_tier end,
                         ser.guarantee_tier, case when ser.flex then 'flex'::guarantee_tier end,
                         'core'::guarantee_tier) = 'core')
            -- the series toggle (a one-off has no series and is allowed)
            and (o.series_id is null or coalesce(ser.free_first_allowed, true))
          ))
     -- peak, if the studio keeps free classes out of its peak hours
     and not (not coalesce(st.free_first_peak_allowed, true) and occurrence_is_peak(o.id))
     and coalesce(o.booked_count, 0) >= p_min_headcount
   order by coalesce(o.booked_count, 0) desc, o.starts_at;
end $function$;

CREATE OR REPLACE FUNCTION public.convert_keep_sweep(p_studio_id uuid, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  st studio_settings%rowtype;
  s  studios%rowtype;
  v_offer membership_plans%rowtype;
  v_tz text; v_fmt text; v_now_date date;
  v_plans text; v_book text; v_buy text;
  v_offer_name text; v_offer_price text; v_offer_detail text;
  r record;
  v_iw jsonb; v_ends timestamptz; v_end_date date;
  v_attended boolean; v_noshow boolean; v_notpurch boolean;
  v_class_date date; v_when text; v_offer_ends text;
  v_payload jsonb; v_sched timestamptz;
  km record; v_newer boolean; v_has_active boolean; v_mend date; v_auto boolean;
  v_kbuy text; v_kpayload jsonb;
  v_atrisk_tpl text; v_unconv_tpl text;
  n int := 0;
begin
  if not is_service_context() then
    raise exception 'this is a scheduled job, not a user action' using errcode = 'PT403';
  end if;

  select * into st from studio_settings where studio_id = p_studio_id;
  if not found or not (coalesce(st.convert_sequence_enabled, false)
                       or coalesce(st.keep_sequence_enabled, false)
                       or coalesce(st.retention_tasks_enabled, false)) then
    return jsonb_build_object('queued', 0);
  end if;
  select * into s from studios where id = p_studio_id;
  v_tz  := s.timezone;
  v_fmt := coalesce(st.time_format, '24h');
  v_now_date := (p_now at time zone v_tz)::date;

  v_plans := member_portal_url(p_studio_id, '/account/plan');
  v_book  := member_portal_url(p_studio_id, '/book');
  if st.intro_offer_plan_id is not null then
    select * into v_offer from membership_plans where id = st.intro_offer_plan_id;
  end if;
  if v_offer.id is not null then
    v_buy        := member_portal_url(p_studio_id, '/buy/' || v_offer.id::text);
    v_offer_name := v_offer.name;
    v_offer_price  := fmt_money(v_offer.price_cents, v_offer.currency);
    v_offer_detail := plan_card_detail(v_offer.id);
  else
    v_buy        := v_plans;
    v_offer_name := 'a membership';
    v_offer_price := ''; v_offer_detail := '';
  end if;

  if coalesce(st.retention_tasks_enabled, false) or coalesce(st.keep_sequence_enabled, false) then
    insert into job_runs (job_key, run_for, status)
    values ('health_refresh:' || p_studio_id::text, v_now_date, 'done')
    on conflict (job_key, run_for) do nothing;
    if found then perform refresh_studio_health(p_studio_id); end if;
  end if;

  -- Decision 78 (d): the signed-up-but-never-booked nudge. A member who joined,
  -- has never held a booking, and is still free-first eligible gets one email at
  -- day 1 and again at day 7 if nothing is booked. It asks for a booking rather
  -- than following a class, so it runs BEFORE the opening skip below and sends
  -- even before the studio has opened, as long as there are published bookable
  -- classes to pick from. Capped per studio per night, oldest sign-ups first; the
  -- WHERE excludes anyone already sent this step, so the cap counts new emails and
  -- the newest never starve behind an already-emailed older cohort.
  if coalesce(st.convert_sequence_enabled, false)
     and exists (select 1 from class_occurrences o
                  where o.studio_id = p_studio_id and o.status = 'scheduled' and not o.hidden_from_members
                    and o.starts_at > p_now and month_published(p_studio_id, o.starts_at)) then
    v_sched := quiet_hours_shift((v_now_date + time '10:00') at time zone v_tz, v_tz);
    for r in
      select m.id as member_id,
             coalesce(nullif(m.first_name, ''), 'there') as first_name,
             case when m.joined_on <= v_now_date - 7 then 7 else 1 end as step
        from members m
       where m.studio_id = p_studio_id
         and m.deleted_at is null
         and m.joined_on is not null
         and m.joined_on <= v_now_date - 1
         and not exists (select 1 from bookings b where b.member_id = m.id)
         and coalesce((free_first_eligibility_run(p_studio_id, m.id, null) ->> 'ok')::boolean, false)
         and not exists (select 1 from notifications nx
                          where nx.dedupe_key = 'convert_book_first:'
                            || (case when m.joined_on <= v_now_date - 7 then '7' else '1' end)
                            || ':' || m.id::text)
       order by m.joined_on asc, m.id
       limit greatest(coalesce(st.convert_book_first_daily_cap, 30), 0)
    loop
      v_payload := jsonb_build_object(
        'first_name', r.first_name, 'studio_name', s.name,
        'book_url', v_book, 'plans_url', v_plans);
      if queue_notification(p_studio_id, r.member_id, 'convert_book_first', v_payload,
            'convert_book_first:' || r.step::text || ':' || r.member_id::text, v_sched) is not null then n := n + 1; end if;
    end loop;
  end if;

  -- Decision 14(c): a studio that has not opened yet (no attended/checked-in
  -- class, or its first is still ahead) gets no convert/keep/retention action —
  -- nobody can have drifted before a class has run. The health refresh above
  -- still runs; member_health now returns insufficient_history for its members.
  if studio_opened_on(p_studio_id) is null
     or studio_opened_on(p_studio_id) > v_now_date then
    return jsonb_build_object('queued', n, 'skipped', 'not_opened');
  end if;

  select coalesce(ov.body, df.text_body) into v_unconv_tpl
    from notification_templates df
    left join notification_templates_overrides ov on ov.studio_id = p_studio_id and ov.key = 'task_unconverted_message'
   where df.key = 'task_unconverted_message';
  select coalesce(ov.body, df.text_body) into v_atrisk_tpl
    from notification_templates df
    left join notification_templates_overrides ov on ov.studio_id = p_studio_id and ov.key = 'task_at_risk_message'
   where df.key = 'task_at_risk_message';

  if coalesce(st.convert_sequence_enabled, false) then
  for r in
    select b.id as booking_id, b.member_id, b.status as bstatus,
           o.id as occ_id, o.starts_at, o.ends_at,
           coalesce(ct.name, 'your class') as class_name,
           split_part(coalesce(i.display_name, ''), ' ', 1) as instr_first,
           coalesce(nullif(m.first_name, ''), 'there') as first_name
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
      left join class_types ct on ct.id = o.class_type_id
      left join instructors i on i.id = o.instructor_id
      join members m on m.id = b.member_id
     where b.studio_id = p_studio_id
       and b.payment_source = 'comp'
       and m.deleted_at is null
       and not exists (select 1 from guest_passes gp
                        where gp.guest_booking_id = b.id and gp.host_member_id is not null)
  loop
    v_notpurch := not exists (select 1 from memberships ms where ms.member_id = r.member_id);
    v_attended := r.bstatus = 'attended'
                  or exists (select 1 from check_ins ci where ci.booking_id = r.booking_id);
    v_noshow   := r.bstatus = 'no_show';
    v_class_date := (r.starts_at at time zone v_tz)::date;
    v_iw   := intro_window(r.member_id, p_now);
    v_ends := nullif(v_iw ->> 'ends_at', '')::timestamptz;
    v_end_date := (v_ends at time zone v_tz)::date;
    v_when := to_char(r.starts_at at time zone v_tz, 'FMDay FMDD Mon') || ' at ' || fmt_clock(r.starts_at, v_tz, v_fmt);
    v_offer_ends := case when v_ends is not null then to_char(v_ends at time zone v_tz, 'FMDD Mon YYYY') else '' end;

    v_payload := jsonb_build_object(
      'first_name', r.first_name, 'studio_name', s.name,
      'class_name', r.class_name, 'when', v_when, 'occurrence_id', r.occ_id,
      'instructor_first_name', coalesce(nullif(r.instr_first, ''), 'your instructor'),
      'offer_plan_name', v_offer_name, 'offer_price', v_offer_price, 'offer_detail', v_offer_detail,
      'offer_ends', v_offer_ends, 'buy_url', v_buy,
      'plans_url', v_plans, 'book_url', v_book);

    if r.bstatus = 'booked' and v_class_date = v_now_date + 1 then
      v_sched := quiet_hours_shift((v_now_date + time '18:00') at time zone v_tz, v_tz);
      if queue_notification(p_studio_id, r.member_id, 'convert_before_class', v_payload,
            'convert_before_class:' || r.booking_id::text, v_sched) is not null then n := n + 1; end if;
    end if;

    if v_noshow and v_notpurch and v_now_date = v_class_date + 1 then
      v_sched := quiet_hours_shift((v_now_date + time '10:00') at time zone v_tz, v_tz);
      if queue_notification(p_studio_id, r.member_id, 'convert_missed_you', v_payload,
            'convert_missed_you:' || r.booking_id::text, v_sched) is not null then n := n + 1; end if;
    end if;

    if v_attended and v_notpurch then
      if p_now >= r.ends_at + interval '2 hours' and p_now < r.ends_at + interval '26 hours' then
        v_sched := quiet_hours_shift(r.ends_at + interval '2 hours', v_tz);
        if queue_notification(p_studio_id, r.member_id, 'convert_after_class', v_payload,
              'convert_after_class:' || r.booking_id::text, v_sched) is not null then n := n + 1; end if;
      end if;
      if v_now_date = v_class_date + 3 then
        v_sched := quiet_hours_shift((v_now_date + time '10:00') at time zone v_tz, v_tz);
        if queue_notification(p_studio_id, r.member_id, 'convert_day3', v_payload,
              'convert_day3:' || r.booking_id::text, v_sched) is not null then n := n + 1; end if;
      end if;
      if v_now_date = v_class_date + 7 then
        v_sched := quiet_hours_shift((v_now_date + time '10:00') at time zone v_tz, v_tz);
        if queue_notification(p_studio_id, r.member_id, 'convert_day7', v_payload,
              'convert_day7:' || r.booking_id::text, v_sched) is not null then n := n + 1; end if;
        insert into member_tasks (studio_id, member_id, kind, reason, suggested_message, assigned_role)
        values (p_studio_id, r.member_id, 'unconverted_day7',
                'Free class ' || (v_now_date - v_class_date) || ' days ago, not yet booked again',
                replace(replace(replace(v_unconv_tpl, '{first_name}', r.first_name), '{studio_name}', s.name), '{offer_plan_name}', v_offer_name),
                st.retention_tasks_to)
        on conflict (member_id, kind) where status = 'open' do nothing;
      end if;
      if v_offer.id is not null and v_ends is not null and v_now_date = v_end_date then
        v_sched := quiet_hours_shift((v_now_date + time '10:00') at time zone v_tz, v_tz);
        if queue_notification(p_studio_id, r.member_id, 'convert_last_day', v_payload,
              'convert_last_day:' || r.booking_id::text || ':' || v_end_date::text, v_sched) is not null then n := n + 1; end if;
      end if;
    end if;
  end loop;
  end if;

  if coalesce(st.keep_sequence_enabled, false) then
    v_sched := quiet_hours_shift((v_now_date + time '10:00') at time zone v_tz, v_tz);
    for km in
      select ms.id as mid, ms.member_id, ms.plan_id, ms.status, ms.starts_on,
             ms.expires_on, ms.current_period_end, ms.credits_remaining,
             ms.auto_renew, ms.stripe_subscription_id,
             pl.name as plan_name, pl.type as plan_type, pl.status as plan_status,
             coalesce(nullif(m.first_name, ''), 'there') as first_name
        from memberships ms
        join membership_plans pl on pl.id = ms.plan_id
        join members m on m.id = ms.member_id
       where ms.studio_id = p_studio_id and m.deleted_at is null
    loop
      v_mend := coalesce(km.expires_on, (km.current_period_end at time zone v_tz)::date);
      v_auto := coalesce(km.auto_renew, false) or km.stripe_subscription_id is not null;
      v_newer := exists (select 1 from memberships ms2
                          where ms2.member_id = km.member_id and ms2.id <> km.mid
                            and ms2.status = 'active'
                            and coalesce(ms2.starts_on, '-infinity'::date) >= coalesce(km.starts_on, '-infinity'::date));
      v_has_active := exists (select 1 from memberships ms2
                               where ms2.member_id = km.member_id and ms2.status = 'active'
                                 and coalesce(ms2.expires_on, 'infinity'::date) > v_now_date);
      v_kbuy := case when coalesce(km.plan_status, 'active') <> 'archived'
                     then member_portal_url(p_studio_id, '/buy/' || km.plan_id::text)
                     else v_plans end;
      v_kpayload := jsonb_build_object(
        'first_name', km.first_name, 'studio_name', s.name,
        'plan_name', km.plan_name,
        'expires_on', case when v_mend is not null then to_char(v_mend, 'FMDD Mon YYYY') else '' end,
        'credits_left', coalesce(km.credits_remaining, 0),
        'buy_url', v_kbuy, 'book_url', v_book, 'schedule_url', v_book);

      if km.plan_type = 'recurring' and not v_auto and km.status in ('active', 'past_due')
         and not v_newer and v_mend is not null then
        if v_now_date = v_mend - 7 and queue_notification(p_studio_id, km.member_id, 'keep_renew_7',
              v_kpayload, 'keep_renew_7:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
        if v_now_date = v_mend - 1 and queue_notification(p_studio_id, km.member_id, 'keep_renew_1',
              v_kpayload, 'keep_renew_1:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
        if v_now_date = v_mend and queue_notification(p_studio_id, km.member_id, 'keep_renew_0',
              v_kpayload, 'keep_renew_0:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
        if v_now_date = v_mend + 3 and not v_has_active
           and queue_notification(p_studio_id, km.member_id, 'keep_lapsed_3',
              v_kpayload, 'keep_lapsed_3:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
      end if;

      if km.credits_remaining > 0 and km.expires_on is not null
         and km.status = 'active' and not v_newer then
        if v_now_date = km.expires_on - 7 and queue_notification(p_studio_id, km.member_id, 'keep_credits_7',
              v_kpayload, 'keep_credits_7:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
        if v_now_date = km.expires_on - 2 and queue_notification(p_studio_id, km.member_id, 'keep_credits_2',
              v_kpayload, 'keep_credits_2:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
      end if;

      if v_mend is not null and not v_has_active
         and not exists (select 1 from memberships ms3
                          where ms3.member_id = km.member_id
                            and coalesce(ms3.starts_on, '-infinity'::date) > v_mend) then
        if v_now_date = v_mend + 30 and queue_notification(p_studio_id, km.member_id, 'keep_winback_30',
              v_kpayload, 'keep_winback_30:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
        if v_now_date = v_mend + 60 and queue_notification(p_studio_id, km.member_id, 'keep_winback_60',
              v_kpayload, 'keep_winback_60:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
      end if;
    end loop;
  end if;

  if coalesce(st.retention_tasks_enabled, false) then
    update member_tasks mt
       set status = 'dismissed', closed_at = now(), close_note = 'recovered'
     where mt.studio_id = p_studio_id and mt.status = 'open'
       and mt.kind in ('at_risk', 'drifting_fyi')
       and ( coalesce((select m.health_band from members m where m.id = mt.member_id), 'new') in ('healthy', 'new')
          or exists (select 1 from check_ins ci where ci.member_id = mt.member_id and ci.checked_in_at > mt.created_at) );

    for km in
      select m.id as member_id, m.health_band as hb, m.health_reason as hr,
             coalesce(nullif(m.first_name, ''), 'there') as first_name
        from members m
       where m.studio_id = p_studio_id and m.status <> 'archived'
         and m.health_band in ('at_risk', 'drifting')
    loop
      if km.hb = 'at_risk' then
        insert into member_tasks (studio_id, member_id, kind, reason, suggested_message, assigned_role)
        values (p_studio_id, km.member_id, 'at_risk', km.hr,
                replace(replace(v_atrisk_tpl, '{first_name}', km.first_name), '{studio_name}', s.name),
                st.retention_tasks_to)
        on conflict (member_id, kind) where status = 'open' do nothing;
      elsif km.hb = 'drifting' then
        if not exists (select 1 from notifications nx where nx.member_id = km.member_id
                        and nx.template_key = 'keep_drifting' and nx.created_at > p_now - interval '30 days') then
          v_sched := quiet_hours_shift((v_now_date + time '10:00') at time zone v_tz, v_tz);
          if queue_notification(p_studio_id, km.member_id, 'keep_drifting',
                jsonb_build_object('first_name', km.first_name, 'studio_name', s.name, 'schedule_url', v_book, 'book_url', v_book),
                'keep_drifting:' || km.member_id::text || ':' || v_now_date::text, v_sched) is not null then n := n + 1; end if;
        end if;
        insert into member_tasks (studio_id, member_id, kind, reason, suggested_message, assigned_role)
        values (p_studio_id, km.member_id, 'drifting_fyi', km.hr, null, st.retention_tasks_to)
        on conflict (member_id, kind) where status = 'open' do nothing;
      end if;
    end loop;
  end if;

  return jsonb_build_object('queued', n);
end $function$;

CREATE OR REPLACE FUNCTION public.queue_occurrence_cancelled(p_occurrence_id uuid, p_cause cancellation_cause DEFAULT NULL::cancellation_cause)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o class_occurrences%rowtype; s studios%rowtype; r record; n int := 0;
        v_when text; v_when_short text; v_base text; v_fmt text;
        v_list_txt text; v_list_html text; v_line_txt text; v_line_html text;
        v_notice boolean := coalesce(current_setting('studiior.closure_notice', true), '') = '1';
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

  -- Decision 77: under the closure-notice flag, the member gets ONE
  -- studio_closure_notice instead of a per-class class_cancelled — skip these.
  if not v_notice then
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
             and o2.status = 'scheduled' and not o2.hidden_from_members
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
              -- Decision 21 amendment (20 Oct 2026): the plain subject reads {day}.
              'day', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth'),
              'next_three_line', v_line_txt, 'next_three_html', v_line_html,
              'manage_link', member_portal_url(o.studio_id, '/class/' || p_occurrence_id),
              'book_url', member_portal_url(o.studio_id, '/book'),
              'occurrence_id', p_occurrence_id),
            'class_cancelled:' || p_occurrence_id || ':' || r.member_id) is not null
      then n := n + 1; end if;
    else
      if queue_notification(o.studio_id, r.member_id, 'class_cancelled',
            jsonb_build_object('class_name', o.name, 'when', v_when,
                               'manage_link', member_portal_url(o.studio_id, '/class/' || p_occurrence_id),
                               'book_url', member_portal_url(o.studio_id, '/book'),
                               'occurrence_id', p_occurrence_id),
            'class_cancelled:' || p_occurrence_id || ':' || r.member_id) is not null
      then n := n + 1; end if;
    end if;
  end loop;
  end if;

  update notifications set status = 'cancelled'
   where status = 'scheduled'
     and dedupe_key like 'class_reminder:%'
     and payload ->> 'class_name' = o.name
     and member_id in (select member_id from bookings where occurrence_id = p_occurrence_id);

  return n;
end $function$;

-- ---------------------------------------------------------------------------
-- book_class / book_first_free: refuse a hidden class with 'class_hidden'.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.book_class(p_occurrence_id uuid, p_member_id uuid, p_source booking_source, p_override_reason text DEFAULT NULL::text, p_payment_source payment_source DEFAULT NULL::payment_source)
 RETURNS book_class_result
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_result       book_class_result;
  v_occ          class_occurrences%rowtype;
  v_member       members%rowtype;
  v_set          studio_settings%rowtype;
  v_tz           text;

  v_actor        uuid := auth.uid();
  v_caller_role  text;
  v_trusted      boolean;
  v_is_desk      boolean;
  v_is_self      boolean;
  v_override     boolean := false;
  v_bypassed     text[] := '{}';
  v_comp         boolean := false;
  -- 'booked' unless the member is paying for a drop-in themselves, in which
  -- case the seat is held as 'pending_payment' until Stripe says otherwise.
  v_status       booking_status := 'booked';

  v_window_days  int;
  v_max_per_day  int;
  v_day_count    int;
  v_future_count int;
  v_today        date;

  v_cand         record;
  v_covers       boolean;
  v_restricted   boolean := false;   -- a live plan was blocked purely on class type
  v_peak         jsonb;             -- Decision 24: the paying plan's peak allowance, or null
  v_susp         jsonb;             -- Decision 24: where this member stands on the ladder
  v_pay          payment_source;
  v_membership   uuid;
  v_consume      boolean := false;

  v_booking_id   uuid;
  v_ledger_id    uuid;
  v_balance      int;
  v_position     int;
  v_full         boolean;
  v_phys_full    boolean;   -- capacity reached by REAL seats
  v_held         int;       -- §4.2: seats a live waitlist offer is holding for someone else
begin
  -- ===========================================================================
  -- 0. Locate and authorise. Nothing is written before this passes.
  -- ===========================================================================

  select * into v_occ from class_occurrences where id = p_occurrence_id;
  if not found then
    return (null, null, null, null, 'not_found')::book_class_result;
  end if;

  -- Lockout (migration 044). The studio's own subscription to Studiior has
  -- lapsed past its grace period. Reads stay open everywhere so nothing looks
  -- lost; this is one of the four places where DOING something stops.
  if studio_is_locked(v_occ.studio_id) then
    raise exception 'this studio''s Studiior subscription is not active'
      using errcode = 'PT402',
            hint = 'Reactivate it from Billing. Nothing has been deleted.';
  end if;

  select * into v_member from members where id = p_member_id;
  if not found then
    return (null, null, null, null, 'member_not_found')::book_class_result;
  end if;
  if v_member.studio_id <> v_occ.studio_id then
    return (null, null, null, null, 'member_wrong_studio')::book_class_result;
  end if;

  select * into v_set from studio_settings where studio_id = v_occ.studio_id;
  select timezone into v_tz from studios where id = v_occ.studio_id;

  -- --- Trust is a property of the ROLE, never of a missing auth.uid() -------
  --
  -- A null auth.uid() proves nothing: an `authenticated` caller whose JWT
  -- carries no `sub` claim has one too, and migration 002 handed that caller
  -- full booking rights over every member in the studio.
  --
  -- current_user is useless here — inside a security definer function it is
  -- always the function owner, not the caller. The caller's effective role is
  -- the `role` GUC, which is what PostgREST sets per request and what SET ROLE
  -- sets in a direct session; it is NOT changed by security definer entry.
  -- 'none' means no SET ROLE happened at all, i.e. a direct login session.
  --
  -- rolbypassrls is the honest test of "already privileged above RLS":
  -- service_role, postgres and supabase_admin have it, and gain nothing from
  -- this function that they could not do by writing the tables directly.
  -- authenticated, anon and authenticator do not have it.
  v_caller_role := coalesce(nullif(current_setting('role', true), 'none'),
                            session_user);
  v_trusted := exists (
    select 1 from pg_roles
     where rolname = v_caller_role
       and (rolsuper or rolbypassrls)
  );

  v_is_desk := coalesce(is_desk_up(v_occ.studio_id), false);
  v_is_self := v_actor is not null
               and v_member.user_id is not null
               and v_member.user_id = v_actor;

  if not (v_trusted or v_is_desk or v_is_self) then
    return (null, null, null, null, 'not_authorised')::book_class_result;
  end if;
  -- A member may only book as themselves, and never on a staff source.
  if not (v_trusted or v_is_desk) and p_source <> 'member' then
    return (null, null, null, null, 'not_authorised')::book_class_result;
  end if;

  -- --- §2.4 comp -----------------------------------------------------------
  -- payment_source is otherwise resolved, never chosen (§2.2). 'comp' is the
  -- single exception the business rules allow, and it is staff-only.
  if p_payment_source is not null then
    if p_payment_source <> 'comp' then
      return (null, null, null, null, 'unsupported_payment_source')
             ::book_class_result;
    end if;
    if not (v_trusted or v_is_desk) then
      return (null, null, null, null, 'not_authorised')::book_class_result;
    end if;
    v_comp := true;
  end if;

  -- Business Rules §2.3: overrides are front desk and above only, and always
  -- carry a reason. Rules 1 (past/cancelled), 4 (waiver) and 6 (duplicate)
  -- stay unoverridable below.
  v_override := p_override_reason is not null
                and btrim(p_override_reason) <> ''
                and (v_trusted or v_is_desk);

  -- ===========================================================================
  -- 1. THE LOCK. Data Model §6 — before anything reads booked_count.
  -- ===========================================================================

  select * into v_occ
    from class_occurrences
   where id = p_occurrence_id
     for update;

  -- Then the member row, which serialises this member's own concurrent
  -- bookings so credits_remaining and credit_ledger.balance_after stay
  -- consistent. Lock order is always occurrence -> member; the nightly expiry
  -- job and the Stripe webhook handlers must take the member lock the same way.
  select * into v_member from members where id = p_member_id for update;

  v_today := (now() at time zone v_tz)::date;

  -- ===========================================================================
  -- 2. Eligibility gate — Business Rules §2.1, in order. First failure wins.
  -- ===========================================================================

  -- 2.1.1 Occurrence is scheduled, not cancelled, not in the past. Not overridable.
  if v_occ.status = 'cancelled' then
    return (null, null, null, null, 'class_cancelled')::book_class_result;
  end if;
  if v_occ.status = 'completed' then
    return (null, null, null, null, 'class_completed')::book_class_result;
  end if;
  if v_occ.starts_at <= now() then
    return (null, null, null, null, 'class_in_past')::book_class_result;
  end if;

  -- 2.1.1b Decision 25: the class is on a PUBLISHED month. Placed with the
  -- occurrence checks and BEFORE the booking window, deliberately: an
  -- unpublished class is invisible to members under occ_member_read, so a
  -- member can only reach here with an id they cannot see, and the refusal
  -- names the reason the class is invisible rather than a rule about how far
  -- ahead their plan lets them book. That keeps the two gates composed the
  -- same way on this side as on the screen: "not published" is about the
  -- class, "outside the window" is about the member, and outside_booking_window
  -- goes on meaning exactly what it has since migration 002 — a class on the
  -- timetable that this member may not book YET. month_published() is true for
  -- every studio with the switch off, so nothing changes for them.
  -- Overridable with a reason, like the window: the desk pencilling somebody
  -- into a draft is a deliberate act and is recorded as one.
  if not month_published(v_occ.studio_id, v_occ.starts_at) then
    if v_override then
      v_bypassed := v_bypassed || 'month_not_published'::text;
    else
      return (null, null, null, null, 'month_not_published')::book_class_result;
    end if;
  end if;

  -- 2.1.1c Decision 48: a studio may keep an unstaffed class off the member side
  -- until an instructor is on it. The staffing arm of occurrence_member_visible
  -- (the published/scheduled arms are the checks just above): with the switch on
  -- and the class not assigned, it is closed to NEW bookings. A member who
  -- ALREADY holds a non-cancelled booking is unaffected — they keep their seat
  -- and the class stays visible to them (occ_member_own_read). Hard refusal: a
  -- class nobody is teaching is not something even the desk books into.
  if studio_hides_unstaffed(v_occ.studio_id)
     and v_occ.staffing <> 'assigned'
     and not exists (select 1 from bookings b
                      where b.occurrence_id = p_occurrence_id and b.member_id = p_member_id
                        and b.status <> 'cancelled') then
    return (null, null, null, null, 'not_staffed_yet')::book_class_result;
  end if;

  -- 2.1.1d Decision 91: a class HIDDEN from members (set_occurrence_visibility) is
  -- closed to NEW bookings — including by link and from the desk — unless the
  -- member ALREADY holds a non-cancelled booking on it, so cancel-and-rebook and
  -- waitlist promotion still work for them. Mirrors not_staffed_yet above.
  if v_occ.hidden_from_members
     and not exists (select 1 from bookings b
                      where b.occurrence_id = p_occurrence_id and b.member_id = p_member_id
                        and b.status <> 'cancelled') then
    return (null, null, null, null, 'class_hidden')::book_class_result;
  end if;

  -- Plan-level overrides for rules 2 and 7 come from the member's highest
  -- priority usable plan (§2.1.2 "plan-level override wins over studio
  -- default"). Read before the gate; the paying source is resolved in §3.
  -- The WINDOW is resolved through member_booking_window_days() — the single
  -- definition of §2.1.2 the member app reads too, so the "Opens for booking"
  -- screen and this rule can never disagree (Decision 36). The daily cap keeps
  -- its own read of the SAME row (identical selection) so behaviour is unchanged.
  v_window_days := member_booking_window_days(p_member_id);
  select mp.max_bookings_per_day
    into v_max_per_day
    from memberships ms
    join membership_plans mp on mp.id = ms.plan_id
   where ms.member_id  = p_member_id
     and ms.studio_id  = v_occ.studio_id
     and ms.status in ('active','trialing')
     and (ms.expires_on is null or ms.expires_on >= v_today)
     and (mp.booking_window_days is not null or mp.max_bookings_per_day is not null)
   order by case mp.type when 'recurring' then 1 when 'trial' then 2 else 3 end,
            ms.expires_on asc nulls last
   limit 1;

  v_max_per_day := coalesce(v_max_per_day, v_set.max_bookings_per_day);

  -- 2.1.2 Booking window.
  if not v_override then
    if v_occ.starts_at > now() + make_interval(days => v_window_days) then
      return (null, null, null, null, 'outside_booking_window')::book_class_result;
    end if;
  elsif v_occ.starts_at > now() + make_interval(days => v_window_days) then
    v_bypassed := v_bypassed || 'booking_window'::text;
  end if;

  -- 2.1.3 Booking cutoff. Default 0 — booking allowed right up to start.
  if not v_override then
    if v_occ.starts_at < now() + make_interval(mins => v_set.booking_cutoff_minutes) then
      return (null, null, null, null, 'past_booking_cutoff')::book_class_result;
    end if;
  elsif v_occ.starts_at < now() + make_interval(mins => v_set.booking_cutoff_minutes) then
    v_bypassed := v_bypassed || 'booking_cutoff'::text;
  end if;

  -- 2.1.3b Decision 30 belt: a self-serve LEAD owed a free first class must
  -- spend it on the free path (book_first_free), not a paid drop-in. Gated on
  -- status = 'lead' — Decision 15's self-signup with no plan; an active member
  -- (including one bringing a guest through book_guest, which books their own
  -- seat here) is never a lead and books normally. Fires only when they book
  -- themselves (not desk/override) and are still eligible, and before the waiver
  -- gate, so a fresh unsigned lead is routed to the free path (which gates the
  -- waiver at check-in) rather than told to sign. The switch off makes
  -- free_first_eligibility return ok=false, so nothing here fires.
  if v_is_self and not (v_is_desk or v_trusted or v_override)
     and v_member.status = 'lead'
     and (free_first_eligibility(v_occ.studio_id, v_member.id) ->> 'ok')::boolean then
    return (null, null, null, null, 'use_free_first')::book_class_result;
  end if;

  -- 2.1.3c Decision 73: while this member's free first class is still
  -- PROVISIONAL (Decision 30 grouped — booked but awaiting its cutoff), they may
  -- not make any other app booking OR join a waitlist. A pending free class is
  -- undecided, and stacking bookings on top of it is what this prevents. Self
  -- only (a desk or service booking is never affected); never the free-first
  -- booking itself (that goes through book_first_free, not here); and a
  -- studio-offered waitlist PROMOTION is exempt (respond_to_offer sets
  -- studiior.waitlist_promoting). Tied to a host-null guest_passes row, so it is
  -- precisely a free-first seat and inert for every member not holding one.
  if v_is_self and not (v_is_desk or v_trusted)
     and current_setting('studiior.waitlist_promoting', true) is distinct from '1'
     and exists (
       select 1 from bookings b
         join guest_passes gp on gp.guest_booking_id = b.id and gp.host_member_id is null
        where b.member_id = p_member_id and b.studio_id = v_occ.studio_id
          and b.payment_source = 'comp' and b.provisional and b.status = 'booked')
  then
    return (null, null, null, null, 'free_first_pending')::book_class_result;
  end if;

  -- 2.1.4 Waiver. Not overridable. Decision 34: a signature is tied to a waiver
  -- version, and a NEW version marked requires_resign turns an older signature
  -- stale — a member who signed only an earlier required version is treated as
  -- unsigned. A studio with no version yet is unaffected (the current-version
  -- subquery finds nothing), so existing bare-timestamp signatures stand.
  if v_set.require_waiver then
    if v_member.waiver_signed_at is null then
      -- Part B: require_waiver is on but the studio has published NO version, so
      -- there is nothing to sign in the app. A distinct reason, so the member is
      -- pointed at the studio rather than told to "please sign" a screen with
      -- nothing on it. The desk paper path can still sign them.
      if not exists (select 1 from waiver_versions where studio_id = v_occ.studio_id) then
        return (null, null, null, null, 'waiver_unavailable')::book_class_result;
      end if;
      return (null, null, null, null, 'waiver_not_signed')::book_class_result;
    end if;
    if exists (
      select 1 from waiver_versions wv
       where wv.studio_id = v_occ.studio_id
         and wv.requires_resign
         and wv.created_at = (select max(created_at) from waiver_versions
                               where studio_id = v_occ.studio_id)
         and not exists (select 1 from waiver_signatures ws
                          where ws.member_id = v_member.id and ws.version_id = wv.id))
    then
      return (null, null, null, null, 'waiver_not_signed')::book_class_result;
    end if;
  end if;

  -- 2.1.5 Member status — Decision 15. A `lead` passes here, and is held to
  -- drop-in by the guard after §2.2 resolution below.
  if not book_class_status_ok(v_member.status) then
    return (null, null, null, null, 'member_not_active')::book_class_result;
  end if;

  -- 2.1.6 No existing live booking for this occurrence. Not overridable.
  -- Mirrors the bookings_one_live_per_member partial unique index.
  if exists (
    select 1 from bookings
     where occurrence_id = p_occurrence_id
       and member_id     = p_member_id
       and status in ('booked','waitlisted','attended','no_show','pending_payment')
  ) then
    -- 'pending_payment' is in this list, and deliberately NOT in the daily or
    -- forward limit counts below: a member may not start two checkouts for the
    -- same class, but three abandoned checkouts must not exhaust the limits on
    -- classes they never paid for.
    return (null, null, null, null, 'already_booked')::book_class_result;
  end if;

  -- 2.1.7 Daily limit, counted in studio-local days.
  if v_max_per_day is not null then
    select count(*) into v_day_count
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
     where b.member_id = p_member_id
       and b.studio_id = v_occ.studio_id
       and b.status in ('booked','waitlisted','attended','no_show')
       and (o.starts_at at time zone v_tz)::date
         = (v_occ.starts_at at time zone v_tz)::date;

    if v_day_count >= v_max_per_day then
      if v_override then
        v_bypassed := v_bypassed || 'daily_limit'::text;
      else
        return (null, null, null, null, 'daily_limit_reached')::book_class_result;
      end if;
    end if;
  end if;

  -- 2.1.8 Forward limit on live future bookings.
  if v_set.max_future_bookings is not null then
    select count(*) into v_future_count
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
     where b.member_id = p_member_id
       and b.studio_id = v_occ.studio_id
       and b.status in ('booked','waitlisted')
       and o.starts_at > now();

    if v_future_count >= v_set.max_future_bookings then
      if v_override then
        v_bypassed := v_bypassed || 'future_limit'::text;
      else
        return (null, null, null, null, 'future_limit_reached')::book_class_result;
      end if;
    end if;
  end if;

  -- ===========================================================================
  -- 3. Payment source resolution — Business Rules §2.2, Decision 1.
  --    unlimited membership -> limited membership allowance -> pack credits
  --    soonest expiry first -> drop-in. The member never chooses.
  --    Consumed at booking time, not at attendance (§2.2, §6).
  -- ===========================================================================

  if v_comp then
    -- §2.4: nothing consumed, nothing charged. The booking is an ordinary
    -- 'booked' row, so check-in, challenges and milestones count it exactly
    -- like any other attendance. Rule 2.1.9 is vacuous — no membership is
    -- paying, so no membership's class-type restriction applies.
    v_pay     := 'comp';
    v_consume := false;
  else
    for v_cand in
      select ms.id,
             ms.credits_remaining,
             mp.restrictions,
             case
               -- credits_per_period null on a recurring plan == unlimited
               -- (Data Model §7).
               when mp.type = 'recurring'
                    and mp.credits_per_period is null
                    and ms.credits_remaining is null              then 1
               when mp.type = 'recurring'
                    and coalesce(ms.credits_remaining, 0) > 0     then 2
               when mp.type in ('class_pack','drop_in','trial')
                    and coalesce(ms.credits_remaining, 0) > 0     then 3
               else 99
             end as priority
        from memberships ms
        join membership_plans mp on mp.id = ms.plan_id
       where ms.member_id = p_member_id
         and ms.studio_id = v_occ.studio_id
         -- §7.3 / Decision 4: past_due blocks NEW bookings only once the
         -- studio's grace period has run out.
         and (
               ms.status in ('active','trialing')
            or (ms.status = 'past_due'
                and now() < coalesce(ms.current_period_end, now())
                            + make_interval(days => v_set.payment_grace_days))
         )
         -- §7.4: a frozen membership cannot book.
         and not (ms.freeze_start is not null and ms.freeze_end is not null
                  and v_today between ms.freeze_start and ms.freeze_end)
         -- §6: a credit cannot be spent past its expiry.
         and (ms.expires_on is null or ms.expires_on >= v_today)
       order by priority,
                ms.expires_on asc nulls last,   -- soonest expiry first
                ms.created_at asc
    loop
      exit when v_cand.priority = 99;

      -- §2.1.9 plan restrictions: an empty or absent class_type_ids covers
      -- everything.
      v_covers := (v_cand.restrictions -> 'class_type_ids') is null
               or jsonb_typeof(v_cand.restrictions -> 'class_type_ids') <> 'array'
               or jsonb_array_length(v_cand.restrictions -> 'class_type_ids') = 0
               or (v_occ.class_type_id is not null
                   and jsonb_exists(v_cand.restrictions -> 'class_type_ids',
                                    v_occ.class_type_id::text));

      if not v_covers then
        v_restricted := true;   -- remembered for the §2.1.9 failure below
        continue;
      end if;

      v_pay        := case when v_cand.priority in (1, 2)
                           then 'membership'::payment_source
                           else 'class_pack'::payment_source end;
      v_membership := v_cand.id;
      v_consume    := v_cand.priority in (2, 3);
      exit;
    end loop;

    if v_pay is null then
      -- §2.1.9: the member holds a live plan and it does not cover this class
      -- type. That is a specific refusal, not a silent fall-through to drop-in.
      if v_restricted then
        if v_override then
          v_bypassed := v_bypassed || 'plan_restriction'::text;
        else
          return (null, null, null, null, 'class_type_not_in_plan')::book_class_result;
        end if;
      end if;
      -- §2.2 priority 4: nothing covers it, so the class is a drop-in. The
      -- charge itself is a payments row raised by the caller against the
      -- returned booking; no credit is consumed here.
      -- Decision 49: the plan they would book on is frozen. Rather than
      -- silently charge a drop-in, refuse with its own reason (the member app
      -- says "paused until {date}"). A usable non-frozen pack was already
      -- resolved above, so this only fires when a frozen membership is the
      -- only plan they have.
      if exists (
        select 1 from memberships ms2
         where ms2.member_id = p_member_id and ms2.studio_id = v_occ.studio_id
           and ms2.freeze_start is not null and ms2.freeze_end is not null
           and v_today between ms2.freeze_start and ms2.freeze_end
      ) then
        return (null, null, null, null, 'membership_frozen')::book_class_result;
      end if;
      v_pay := 'drop_in';

      -- Decision 73 (c): pay at the desk is EARNED. This booking resolved to an
      -- unpaid desk drop-in; refuse it (desk_pay_blocked) when the member has
      -- lost the privilege. 'earned' mode: once they have a no-show or late
      -- cancel on a desk booking (members.desk_pay_blocked_at set). 'first_visit
      -- _only' mode: once they have ever held a desk booking that was not
      -- cancelled in time. The app then shows "pay online to book". Self only; a
      -- desk/staff booking and a studio-offered waitlist promotion are never
      -- blocked, and the instructor desk RPCs do not reach book_class at all.
      if v_is_self and not (v_is_desk or v_trusted)
         and current_setting('studiior.waitlist_promoting', true) is distinct from '1'
         and (
           (coalesce(v_set.desk_pay_mode, 'earned') = 'earned'
              and exists (select 1 from members dm
                           where dm.id = p_member_id and dm.desk_pay_blocked_at is not null))
           or
           (coalesce(v_set.desk_pay_mode, 'earned') = 'first_visit_only'
              and exists (select 1 from bookings db
                           where db.member_id = p_member_id and db.studio_id = v_occ.studio_id
                             and db.payment_source = 'drop_in' and db.status <> 'cancelled'))
         )
      then
        return (null, null, null, null, 'desk_pay_blocked')::book_class_result;
      end if;

      -- Decision 73: a studio may cap how many UNPAID app bookings a member
      -- holds (max_unpaid_bookings; null = no limit = today's behaviour). This
      -- booking has resolved to an unpaid drop-in; if the member already holds
      -- that many unpaid drop-ins, refuse with pay_first — the app then offers
      -- Pay now / Pay at the desk. Self only: a desk booking (money at the
      -- counter) and a studio-offered waitlist promotion are never capped. A
      -- booking counts while it is a live drop-in with no settling payment row;
      -- a desk or Pay-now payment clears it (73b flips payment_source off
      -- drop_in), so a paid booking no longer counts.
      if v_set.max_unpaid_bookings is not null
         and v_is_self and not (v_is_desk or v_trusted)
         and current_setting('studiior.waitlist_promoting', true) is distinct from '1'
         and (
           select count(*) from bookings b
            where b.member_id = p_member_id and b.studio_id = v_occ.studio_id
              and b.payment_source = 'drop_in'
              and b.status in ('booked', 'pending_payment')
              and not exists (select 1 from payments p
                               where p.booking_id = b.id
                                 and p.status in ('succeeded', 'partially_refunded'))
         ) >= v_set.max_unpaid_bookings
      then
        return (null, null, null, null, 'pay_first')::book_class_result;
      end if;
    end if;
  end if;

  -- The seat is held while the member pays for it.
  --
  -- Only when the MEMBER is booking their own drop-in and the studio has a
  -- connected Stripe account. A staff booking at the desk is money changing
  -- hands in the room, and a studio with no Stripe connected has no checkout to
  -- send anyone to — both of those still book outright, exactly as before, which
  -- is also why every existing fixture in the suite is unaffected.
  if v_pay = 'drop_in' and p_source = 'member'
     and exists (
       select 1 from studios s
        where s.id = v_occ.studio_id and s.stripe_account_id is not null
     )
  then
    v_status := 'pending_payment';
  end if;

  -- Decision 15's second half, after §2.2 has resolved who pays. A lead has
  -- bought nothing, so it should always be drop-in by this point; if it is
  -- not, staff have attached a plan to somebody they never activated, and
  -- spending its credits is not what `lead` is meant to allow.
  if v_member.status = 'lead' and v_pay <> 'drop_in' then
    return (null, null, null, null, 'member_not_active')::book_class_result;
  end if;

  -- ===========================================================================
  -- 2.1.9 SUSPENSION — Decision 24.
  --
  -- In the §2.1 gate and not beside the peak rule, because it has nothing to do
  -- with which plan pays: a suspended member is suspended whatever they were
  -- going to book it with, including a drop-in they would have paid cash for.
  --
  -- IT RESTRICTS ADVANCE BOOKING ONLY. Same-day still works, on whatever seats
  -- are left — the penalty is losing the ability to hold a place ahead of
  -- everyone else, not being shut out of the studio. A suspension that stopped
  -- somebody walking in would cost the studio the sale as well as the member the
  -- class, and it would be a harsher thing than any studio described wanting.
  --
  -- The allowance still applies on top: a suspension does not hand out free peak
  -- slots, and a member with nothing left is refused by the rule below whether
  -- or not they are suspended.
  --
  -- Overridable, like the other capacity-shaped rules. A studio that wants to
  -- let somebody in anyway has heard the reason at the counter.
  -- ===========================================================================
  v_susp := member_suspension(p_member_id);
  if v_susp is not null and (v_susp ->> 'suspended')::boolean
     and (v_occ.starts_at at time zone v_tz)::date > v_today
  then
    if v_override then
      v_bypassed := v_bypassed || 'suspended'::text;
    else
      return (null, null, null, null, 'suspended')::book_class_result;
    end if;
  end if;

  -- ===========================================================================
  -- 3b. THE PEAK ALLOWANCE — Decision 24.
  --
  -- AFTER §2.2, and that placement is the whole correctness argument: the plan
  -- that PAYS is the plan held to its allowance. Resolving it up in the §2.1
  -- gate would mean a second plan-priority query beside the one rules 2 and 7
  -- use, and the two would pick the same plan right up until they did not —
  -- a member holding both an unlimited plan and a pack would have the pack's
  -- booking measured against the unlimited plan's allowance.
  --
  -- Only a membership can consume one. A drop-in and a pack cannot carry an
  -- allowance at all (migration 104's CHECK), so `v_pay = 'membership'` is not
  -- an optimisation, it is the rule.
  --
  -- peak_allowance_state() answers null for a plan with no allowance AND for a
  -- studio with the switch off, so a studio that has never heard of this
  -- feature takes one null check and nothing else.
  --
  -- WAITLISTING NEEDS NO SPECIAL CASE. This refuses before §4, so a member with
  -- nothing left cannot join the queue for a peak class either — which is the
  -- honest answer, rather than letting them wait for an offer they could not
  -- accept. And nothing is CONSUMED here: the ledger row is written by the
  -- trigger when a seat actually becomes real, so a waitlisted row costs
  -- nothing and a promotion costs one. `respond_to_offer()` cancels the
  -- waitlist row and calls this function again, so a promotion is measured
  -- against the allowance as it stands at that moment, not at join time.
  -- ===========================================================================
  if v_pay = 'membership' and v_membership is not null
     and occurrence_is_peak(p_occurrence_id)
  then
    v_peak := peak_allowance_state(v_membership,
                                   (v_occ.starts_at at time zone v_tz)::date);
    if v_peak is not null and (v_peak ->> 'remaining')::int <= 0 then
      if v_override then
        v_bypassed := v_bypassed || 'peak_allowance'::text;
      else
        return (null, null, null, null, 'peak_allowance_exhausted')::book_class_result;
      end if;
    end if;
  end if;

  -- ===========================================================================
  -- 4. Capacity — §2.1.10, §4.1, §5. booked_count was read under the lock.
  -- ===========================================================================

  -- §4.2: a pending waitlist offer HOLDS its seat — the offered member was
  -- formally offered it, and general booking must not take it from under them.
  -- Derived from live offers at gate time rather than cached: booked_count goes
  -- on counting real seats only, so the nightly reconcile stays a no-op, and the
  -- hold ends the instant the offer does (expired-but-unswept offers hold
  -- nothing — occurrence_seats_held gates on expires_at > now()). The offered
  -- member's own offer is excluded, or accepting through respond_to_offer would
  -- be refused for the very seat they were offered.
  v_held      := occurrence_seats_held(p_occurrence_id, p_member_id);
  v_phys_full := v_occ.booked_count >= v_occ.capacity;
  v_full      := (v_occ.booked_count + v_held) >= v_occ.capacity;

  if v_full and not v_override then
    if not v_set.waitlist_enabled then
      return (null, null, null, null, 'class_full')::book_class_result;
    end if;

    -- §4.4: no promotions inside waitlist_cutoff_minutes, so joining there is
    -- an offer that can never be made.
    if v_occ.starts_at < now() + make_interval(mins => v_set.waitlist_cutoff_minutes) then
      return (null, null, null, null, 'waitlist_closed')::book_class_result;
    end if;

    -- §4.1: strictly FIFO, no priority tiers in V1, and NO credit consumed on
    -- joining. The paying source is re-resolved when the offer is accepted
    -- (§4.2.4), so it is deliberately left null on the row — including for a
    -- comp, whose comp intent must be supplied again at promotion.
    select coalesce(max(waitlist_position), 0) + 1
      into v_position
      from bookings
     where occurrence_id = p_occurrence_id
       and status = 'waitlisted';

    insert into bookings (
      studio_id, occurrence_id, member_id, status, source,
      payment_source, membership_id, waitlist_position
    ) values (
      v_occ.studio_id, p_occurrence_id, p_member_id, 'waitlisted', p_source,
      null, null, v_position
    ) returning id into v_booking_id;

    update class_occurrences
       set waitlist_count = waitlist_count + 1
     where id = p_occurrence_id;

    return (v_booking_id, 'waitlisted'::booking_status, null, v_position, null)
           ::book_class_result;
  end if;

  if v_full then
    -- §2.3 / §5 / §14: a staff override reaches here. Two shapes, told apart for
    -- the audit: physically full is a walk-in booked OVER capacity; held-only is
    -- the desk deliberately taking a seat reserved for a waitlisted member (the
    -- offer stands and will fail on acceptance — a deliberate act, §14). The hold
    -- is never applied to an override, so front desk can always seat someone.
    if v_phys_full then
      v_bypassed := v_bypassed || 'capacity'::text;
    else
      v_bypassed := v_bypassed || 'held_seat'::text;
    end if;
  end if;

  -- ===========================================================================
  -- 5. Write. Booking, ledger and booked_count, one transaction.
  -- ===========================================================================

  insert into bookings (
    studio_id, occurrence_id, member_id, status, source,
    payment_source, membership_id, override_reason, overridden_rules
  ) values (
    v_occ.studio_id, p_occurrence_id, p_member_id, v_status, p_source,
    v_pay, case when v_pay in ('membership','class_pack') then v_membership end,
    -- §2.3: a reason that bypassed nothing was not an override, so it is not
    -- recorded as one.
    case when array_length(v_bypassed, 1) is not null then p_override_reason end,
    case when array_length(v_bypassed, 1) is not null then v_bypassed end
  ) returning id into v_booking_id;

  if v_consume then
    -- §6: the balance is derived from the ledger, never edited in place, and
    -- every row carries balance_after so any point in history is
    -- reconstructable without replaying. balance_after is the member's total
    -- credit balance across every source; the member row lock above makes the
    -- read-then-write safe.
    select coalesce(sum(delta), 0) into v_balance
      from credit_ledger
     where studio_id = v_occ.studio_id
       and member_id = p_member_id;

    insert into credit_ledger (
      studio_id, member_id, membership_id, delta, reason,
      booking_id, balance_after, expires_at, actor_user_id
    )
    select v_occ.studio_id, p_member_id, v_membership, -1, 'booking',
           v_booking_id, v_balance - 1,
           case when ms.expires_on is not null
                then (ms.expires_on + 1)::timestamp at time zone v_tz end,
           v_actor
      from memberships ms
     where ms.id = v_membership
    returning id into v_ledger_id;

    -- credits_remaining is a cache. Written in the same transaction as the
    -- ledger row, never independently of it.
    update memberships
       set credits_remaining = credits_remaining - 1
     where id = v_membership;

    update bookings set credit_entry_id = v_ledger_id where id = v_booking_id;
  end if;

  update class_occurrences
     set booked_count = booked_count + 1
   where id = p_occurrence_id;

  -- §2.3 / §13: every override that actually bypassed a rule is audited with
  -- actor and reason. The booking row carries the same reason (above) so it is
  -- visible without a join to audit_logs.
  if v_override and array_length(v_bypassed, 1) is not null then
    insert into audit_logs (
      studio_id, actor_user_id, action, entity_table, entity_id, after
    ) values (
      v_occ.studio_id, v_actor, 'booking.override', 'bookings', v_booking_id,
      jsonb_build_object(
        'reason',        p_override_reason,
        'rules_bypassed', to_jsonb(v_bypassed),
        'occurrence_id', p_occurrence_id,
        'member_id',     p_member_id,
        'over_capacity', v_occ.booked_count + 1 > v_occ.capacity
      )
    );
  end if;

  -- Decision 30 amendment: a seat that counts toward the headcount may have just
  -- completed a free class's confirm-at total, confirming its provisional free
  -- seats at once. A no-op when the class has none or is still short.
  if v_status in ('booked', 'pending_payment') then
    perform confirm_provisional_seats_run(p_occurrence_id);
  end if;

  -- The caller needs to know it is holding rather than booked, because that is
  -- what decides whether the member is sent to Checkout next.
  return (v_booking_id, v_status, v_pay, null, null)
         ::book_class_result;
end $function$;

CREATE OR REPLACE FUNCTION public.book_first_free(p_occurrence_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_occ    class_occurrences%rowtype;
  v_member members%rowtype;
  v_set    studio_settings%rowtype;
  v_ser    class_series%rowtype;
  v_cfg_tier guarantee_tier;
  v_tz     text;
  v_elig   jsonb;
  v_free   int;
  v_head   int;
  v_cut    timestamptz;
  v_prov   boolean;
  v_booking uuid;
  v_pass    uuid;
begin
  select * into v_occ from class_occurrences where id = p_occurrence_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;

  select * into v_member from members
   where studio_id = v_occ.studio_id and user_id = auth.uid();
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_authorised'); end if;

  v_elig := free_first_eligibility(v_occ.studio_id, v_member.id);
  if not (v_elig ->> 'ok')::boolean then return v_elig; end if;

  select * into v_set from studio_settings where studio_id = v_occ.studio_id;
  select timezone into v_tz from studios where id = v_occ.studio_id;

  if v_occ.status <> 'scheduled' then return jsonb_build_object('ok', false, 'reason', 'class_not_bookable'); end if;
  if v_occ.starts_at <= now() then return jsonb_build_object('ok', false, 'reason', 'class_in_past'); end if;
  if not month_published(v_occ.studio_id, v_occ.starts_at) then
    return jsonb_build_object('ok', false, 'reason', 'month_not_published');
  end if;
  if studio_hides_unstaffed(v_occ.studio_id) and v_occ.staffing <> 'assigned' then
    return jsonb_build_object('ok', false, 'reason', 'not_staffed_yet');
  end if;
  if v_occ.hidden_from_members then
    return jsonb_build_object('ok', false, 'reason', 'class_hidden');
  end if;
  if v_occ.starts_at > now() + make_interval(days => coalesce(v_set.booking_window_days, 30)) then
    return jsonb_build_object('ok', false, 'reason', 'outside_booking_window');
  end if;
  if v_occ.starts_at < now() + make_interval(mins => coalesce(v_set.booking_cutoff_minutes, 0)) then
    return jsonb_build_object('ok', false, 'reason', 'past_booking_cutoff');
  end if;

  -- Decision 30 amendment (b): a per-class override. 'closed' = never, whatever
  -- the rules say; 'open' skips core_only and the series switch below (seat cap
  -- and peak still apply).
  if v_occ.free_first_override = 'closed' then
    return jsonb_build_object('ok', false, 'reason', 'free_first_closed_here');
  end if;

  if not coalesce(v_set.free_first_peak_allowed, true) and occurrence_is_peak(p_occurrence_id) then
    return jsonb_build_object('ok', false, 'reason', 'peak_not_allowed');
  end if;

  if v_occ.series_id is not null then
    select * into v_ser from class_series where id = v_occ.series_id;
  end if;
  v_cfg_tier := coalesce(v_occ.guarantee_tier,
                         case when v_occ.flex then 'flex'::guarantee_tier end,
                         v_ser.guarantee_tier,
                         case when v_ser.flex then 'flex'::guarantee_tier end,
                         'core'::guarantee_tier);
  if coalesce(v_set.free_first_core_only, false) and v_cfg_tier <> 'core'
     and v_occ.free_first_override is distinct from 'open' then
    return jsonb_build_object('ok', false, 'reason', 'flex_not_allowed');
  end if;
  if v_occ.series_id is not null
     and not coalesce(v_ser.free_first_allowed, true)
     and v_occ.free_first_override is distinct from 'open' then
    return jsonb_build_object('ok', false, 'reason', 'not_trial_class');
  end if;
  if v_set.free_first_seats_per_class is not null
     and (select count(*) from bookings b
           where b.occurrence_id = p_occurrence_id and b.status = 'booked'
             and b.payment_source = 'comp'
             and exists (select 1 from guest_passes gp
                          where gp.guest_booking_id = b.id and gp.host_member_id is null))
         >= v_set.free_first_seats_per_class then
    return jsonb_build_object('ok', false, 'reason', 'free_seats_full');
  end if;

  v_free := v_occ.capacity - occurrence_seats_taken(p_occurrence_id)
                           - occurrence_seats_held(p_occurrence_id);
  if v_free < 1 then return jsonb_build_object('ok', false, 'reason', 'class_full'); end if;

  v_head := occurrence_seats_taken(p_occurrence_id) + 1;
  select cutoff_at into v_cut from occurrence_guarantee_run(p_occurrence_id);
  v_prov := v_set.free_first_confirm_at is not null
            and v_cut is not null
            and v_head < v_set.free_first_confirm_at;

  -- Mark this seat a free first class for the AFTER-INSERT notification trigger,
  -- which fires before the guest_passes row below is written.
  perform set_config('studiior.free_first', '1', true);

  insert into bookings (studio_id, occurrence_id, member_id, status, source,
                        payment_source, provisional, confirmed_at)
  values (v_occ.studio_id, p_occurrence_id, v_member.id, 'booked', 'member', 'comp',
          v_prov, case when v_prov then null else now() end)
  returning id into v_booking;
  update class_occurrences set booked_count = booked_count + 1 where id = p_occurrence_id;

  -- The shared once-ever ledger row. Decision 78: a no-show member's rebook
  -- REUSES this row (upsert on the once-ever index) rather than inserting a
  -- second — the index and its hard guarantee are untouched; the member's comp
  -- no_show bookings are what count the attempts.
  insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email,
                            occurrence_id, guest_booking_id, status, waiver_signed_at)
  values (v_occ.studio_id, null, v_member.id, lower(btrim(v_member.email)),
          p_occurrence_id, v_booking,
          case when v_member.waiver_signed_at is not null then 'confirmed' else 'invited' end,
          v_member.waiver_signed_at)
  on conflict (studio_id, normalize_email_key(guest_email)) do update
    set host_member_id   = excluded.host_member_id,
        guest_member_id  = excluded.guest_member_id,
        occurrence_id    = excluded.occurrence_id,
        guest_booking_id = excluded.guest_booking_id,
        status           = excluded.status,
        waiver_signed_at = excluded.waiver_signed_at
  returning id into v_pass;

  perform confirm_provisional_seats_run(p_occurrence_id);

  return jsonb_build_object('ok', true, 'booking_id', v_booking,
    'guest_pass_id', v_pass, 'provisional', v_prov);
end $function$;

-- ---------------------------------------------------------------------------
-- The anon surface stays EXACTLY THIRTEEN (public_schedule kept its anon grant).
-- ---------------------------------------------------------------------------
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface drifted: expected 13, got %', n; end if;
end $$;
