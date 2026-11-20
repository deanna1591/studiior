-- creates: member_coaches(uuid), availability_submission_dates(uuid), availability_submission_rows(uuid), availability_change_lines(jsonb, jsonb), staff_edit_availability_submission(uuid, jsonb)
-- re-issues: public_schedule(text, integer), instructor_available_at_run(uuid, timestamptz, timestamptz), submit_availability(uuid, date, jsonb, boolean), set_availability_exception(uuid, date, jsonb, text), clear_availability_exception(uuid, date), instructor_availability_week(uuid), instructor_time_off(), availability_submission_week(uuid, date)
--
-- Step 9c, 20 Nov 2026.
--
-- Decision 116(c) coaches on the private slot list: member_coaches is the
-- member-only reader for the coach profile sheet (name, photo, bio,
-- certifications; active coaches only). public_schedule (re-issued byte-faithfully
-- from 20260833580000, uppercase CREATE) carries private_enabled and private_url
-- for the embed's "Book a private session" link. The private slot reader already
-- carries the coach ids per start (116(b)); unchanged.
--
-- Decision 18(c) staff can edit a submission: staff_edit_availability_submission
-- (manager-up) replaces only that submission's rows (weekday and date rows, never
-- a pattern row), keeps the status, audits availability.submission_edited with
-- before and after, emails the instructor availability_edited_by_studio with one
-- line per change, and returns how many of their assigned classes in the month
-- the new hours no longer cover. Allowed after the cut-off.
--
-- Decision 18(d) dates with their own hours: a date row is an instructor_availability
-- row with exception_date set. With submission_id set it belongs to that month's
-- submission; with submission_id null it is standalone (time off, or a date set
-- outside a submission). instructor_available_at_run: a standalone dated row wins
-- over everything; inside the APPROVED month the date row wins over the weekday
-- rows; a not-yet-approved submission's date rows do not count, like its weekday
-- rows. submit_availability accepts {date, ranges} / {date, unavailable}.
-- set/clear_availability_exception, instructor_availability_week and
-- instructor_time_off now read and write standalone dated rows only, so a
-- submission's date rows never surface as time off and are never deleted by it.
-- instructor_block_dates is unchanged. Every flag read is coalesced.
-- No new anon RPC: anon stays EXACTLY FOURTEEN (asserted at the end).

-- ========================================================================
-- Decision 116(c): member_coaches
-- ========================================================================
create or replace function member_coaches(p_studio_id uuid)
returns table(id uuid, first_name text, display_name text, avatar_url text,
              bio text, certifications jsonb)
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from members m
                  where m.studio_id = p_studio_id and m.user_id = auth.uid()
                    and m.deleted_at is null) then
    raise exception 'you are not a member of that studio' using errcode = 'PT403';
  end if;
  return query
  select i.id, split_part(i.display_name, ' ', 1), i.display_name, i.avatar_url,
         nullif(btrim(coalesce(i.bio, '')), ''),
         coalesce(i.certifications, '[]'::jsonb)
    from instructors i
   where i.studio_id = p_studio_id and i.status = 'active'
   order by i.display_name;
end $$;
revoke execute on function member_coaches(uuid) from public, anon;
grant  execute on function member_coaches(uuid) to authenticated, service_role;

-- ========================================================================
-- Decision 18(c)/(d): a submission's rows in one canonical shape
--   {day, from, to} | {date, from, to} | {date, unavailable: true}
-- ========================================================================
create or replace function availability_submission_rows(p_submission_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(r order by k1, k2, k3), '[]'::jsonb) from (
    select case
             when a.day_of_week is not null then
               jsonb_build_object('day', a.day_of_week,
                 'from', to_char(a.starts_at_time, 'HH24:MI'), 'to', to_char(a.ends_at_time, 'HH24:MI'))
             when not a.is_available then
               jsonb_build_object('date', a.exception_date, 'unavailable', true)
             else
               jsonb_build_object('date', a.exception_date,
                 'from', to_char(a.starts_at_time, 'HH24:MI'), 'to', to_char(a.ends_at_time, 'HH24:MI'))
           end as r,
           case when a.day_of_week is not null then 0 else 1 end as k1,
           coalesce(((a.day_of_week + 6) % 7)::text, a.exception_date::text) as k2,
           coalesce(a.starts_at_time, '00:00'::time) as k3
      from instructor_availability a
     where a.submission_id = p_submission_id) z;
$$;
revoke execute on function availability_submission_rows(uuid) from public, anon, authenticated;
grant  execute on function availability_submission_rows(uuid) to service_role;

create or replace function availability_submission_dates(p_submission_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'date', d, 'unavailable', off, 'ranges', ranges) order by d), '[]'::jsonb)
    from (
      select a.exception_date as d,
             bool_or(not a.is_available) as off,
             coalesce(jsonb_agg(jsonb_build_object('from', to_char(a.starts_at_time,'HH24:MI'),
                                                   'to',   to_char(a.ends_at_time,'HH24:MI'))
                                order by a.starts_at_time)
                        filter (where a.is_available and a.starts_at_time is not null), '[]'::jsonb) as ranges
        from instructor_availability a
       where a.submission_id = p_submission_id and a.exception_date is not null
       group by a.exception_date) z;
$$;
revoke execute on function availability_submission_dates(uuid) from public, anon, authenticated;
grant  execute on function availability_submission_dates(uuid) to service_role;

-- One line per changed day or date: "Tue 09:00 to 20:00 is now 10:00 to 20:00",
-- "Wed 09:00 to 12:00 added", "Thu 09:00 to 20:00 removed",
-- "Mon 14 Dec 08:00 to 15:00 added", "Fri 18 Dec not available added".
-- Weekdays Monday first, then dates in order. Mirrored in lib/availability-edit.mjs.
create or replace function availability_change_lines(p_before jsonb, p_after jsonb)
returns text[] language sql immutable set search_path = public as $$
  with rows as (
    select 'b' as side, e from jsonb_array_elements(coalesce(p_before, '[]'::jsonb)) e
    union all
    select 'a', e from jsonb_array_elements(coalesce(p_after, '[]'::jsonb)) e
  ), keyed as (
    select side,
           case when e ? 'day' then 'd' || (e ->> 'day') else 't' || (e ->> 'date') end as k,
           case when e ? 'day' then '0' || (((e ->> 'day')::int + 6) % 7)::text
                else '1' || (e ->> 'date') end as sortk,
           case when e ? 'day'
                then (array['Sun','Mon','Tue','Wed','Thu','Fri','Sat'])[(e ->> 'day')::int + 1]
                else to_char((e ->> 'date')::date, 'FMDy FMDD Mon') end as label,
           coalesce((e ->> 'unavailable')::boolean, false) as off,
           case when coalesce((e ->> 'unavailable')::boolean, false) then null
                else to_char((e ->> 'from')::time, 'HH24:MI') || ' to ' || to_char((e ->> 'to')::time, 'HH24:MI') end as rng
      from rows
  ), g as (
    select side, k, min(sortk) as sortk, min(label) as label,
           case when bool_or(off) then 'not available'
                else string_agg(rng, ', ' order by rng) end as txt
      from keyed group by side, k
  )
  select coalesce(array_agg(line order by sortk), '{}') from (
    select coalesce(a.sortk, b.sortk) as sortk,
           case when b.k is null then a.label || ' ' || a.txt || ' added'
                when a.k is null then b.label || ' ' || b.txt || ' removed'
                else a.label || ' ' || b.txt || ' is now ' || a.txt end as line
      from (select * from g where side = 'a') a
      full join (select * from g where side = 'b') b on a.k = b.k
     where a.k is null or b.k is null or a.txt <> b.txt) z;
$$;
revoke execute on function availability_change_lines(jsonb, jsonb) from public, anon;
grant  execute on function availability_change_lines(jsonb, jsonb) to authenticated, service_role;

-- ========================================================================
-- Decision 18(c): staff edit a submission in place
-- ========================================================================
create or replace function staff_edit_availability_submission(p_submission_id uuid, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_sub availability_submissions%rowtype; v_tz text; v_end date;
  v_before jsonb; v_after jsonb; v_lines text[]; e jsonb; v_date date; v_day int;
  v_count int := 0; v_name text; v_studio_name text; v_uid uuid; v_notified boolean := false;
begin
  select * into v_sub from availability_submissions where id = p_submission_id for update;
  if not found then
    raise exception 'no such submission' using errcode = 'PT404';
  end if;
  if not coalesce(is_manager_up(v_sub.studio_id), false) then
    raise exception 'only owners and managers edit availability' using errcode = 'PT403';
  end if;
  if jsonb_typeof(coalesce(p_rows, 'null'::jsonb)) <> 'array' then
    raise exception 'rows must be a list' using errcode = 'PT422';
  end if;
  select timezone into v_tz from studios where id = v_sub.studio_id;
  v_end := (v_sub.period_start + interval '1 month' - interval '1 day')::date;
  v_before := availability_submission_rows(p_submission_id);

  -- Validate everything before writing anything.
  for e in select * from jsonb_array_elements(p_rows) loop
    if e ? 'day' then
      v_day := (e ->> 'day')::int;
      if v_day is null or v_day < 0 or v_day > 6 then
        raise exception 'a day must be 0-6' using errcode = 'PT422';
      end if;
    elsif e ? 'date' then
      v_date := (e ->> 'date')::date;
      if v_date < v_sub.period_start or v_date > v_end then
        raise exception 'a date must fall inside the month' using errcode = 'PT422';
      end if;
    else
      raise exception 'each line needs a day or a date' using errcode = 'PT422';
    end if;
    if not coalesce((e ->> 'unavailable')::boolean, false) then
      if (e ->> 'from') is null or (e ->> 'to') is null
         or (e ->> 'to')::time <= (e ->> 'from')::time then
        raise exception 'a time must end after it starts' using errcode = 'PT422';
      end if;
    elsif e ? 'day' then
      raise exception 'a weekday is removed, not marked unavailable' using errcode = 'PT422';
    end if;
  end loop;

  -- Only this submission's rows: never a pattern row, never another month.
  delete from instructor_availability where submission_id = p_submission_id;
  for e in select * from jsonb_array_elements(p_rows) loop
    if e ? 'day' then
      insert into instructor_availability
        (studio_id, instructor_id, day_of_week, starts_at_time, ends_at_time,
         effective_from, effective_to, is_available, created_by, submission_id, approval_status)
      values (v_sub.studio_id, v_sub.instructor_id, (e ->> 'day')::int,
              (e ->> 'from')::time, (e ->> 'to')::time, v_sub.period_start, v_end, true,
              auth.uid(), p_submission_id, v_sub.status);
    elsif coalesce((e ->> 'unavailable')::boolean, false) then
      insert into instructor_availability
        (studio_id, instructor_id, exception_date, is_available, created_by, submission_id, approval_status)
      values (v_sub.studio_id, v_sub.instructor_id, (e ->> 'date')::date, false,
              auth.uid(), p_submission_id, v_sub.status);
    else
      insert into instructor_availability
        (studio_id, instructor_id, exception_date, starts_at_time, ends_at_time,
         is_available, created_by, submission_id, approval_status)
      values (v_sub.studio_id, v_sub.instructor_id, (e ->> 'date')::date,
              (e ->> 'from')::time, (e ->> 'to')::time, true,
              auth.uid(), p_submission_id, v_sub.status);
    end if;
  end loop;
  update availability_submissions set updated_at = now() where id = p_submission_id;

  v_after := availability_submission_rows(p_submission_id);
  v_lines := availability_change_lines(v_before, v_after);

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (v_sub.studio_id, auth.uid(), 'availability.submission_edited', 'availability_submissions',
          p_submission_id,
          jsonb_build_object('rows', v_before),
          jsonb_build_object('rows', v_after, 'changes', to_jsonb(v_lines), 'status', v_sub.status));

  -- The coach's assigned classes in this month the new rows no longer cover:
  -- a date row decides its date, else the weekday rows decide.
  select count(*)::int into v_count
    from class_occurrences o
   where o.instructor_id = v_sub.instructor_id and o.status = 'scheduled'
     and o.starts_at > now()
     and (o.starts_at at time zone v_tz)::date between v_sub.period_start and v_end
     and not (
       case when exists (select 1 from instructor_availability a
                          where a.submission_id = p_submission_id
                            and a.exception_date = (o.starts_at at time zone v_tz)::date)
            then exists (select 1 from instructor_availability a
                          where a.submission_id = p_submission_id
                            and a.exception_date = (o.starts_at at time zone v_tz)::date
                            and a.is_available
                            and a.starts_at_time <= (o.starts_at at time zone v_tz)::time
                            and a.ends_at_time   >= (o.ends_at   at time zone v_tz)::time)
            else exists (select 1 from instructor_availability a
                          where a.submission_id = p_submission_id
                            and a.day_of_week = extract(dow from (o.starts_at at time zone v_tz))::int
                            and a.is_available
                            and a.starts_at_time <= (o.starts_at at time zone v_tz)::time
                            and a.ends_at_time   >= (o.ends_at   at time zone v_tz)::time)
       end);

  select i.display_name into v_name from instructors i where i.id = v_sub.instructor_id;
  select s.name into v_studio_name from studios s where s.id = v_sub.studio_id;
  if coalesce(array_length(v_lines, 1), 0) > 0 then
    v_uid := instructor_user_id(v_sub.instructor_id);
    v_notified := queue_shift_notice(v_sub.studio_id, v_uid, 'availability_edited_by_studio',
      jsonb_build_object(
        'first_name', split_part(coalesce(v_name, ''), ' ', 1),
        'instructor_name', v_name,
        'studio_name', v_studio_name,
        'month', to_char(v_sub.period_start, 'FMMonth YYYY'),
        'change_lines', array_to_string(v_lines, E'\n'),
        'change_html', (select string_agg('<li>' || replace(replace(l, '&', '&amp;'), '<', '&lt;') || '</li>', '')
                          from unnest(v_lines) l),
        'availability_url', instructor_portal_url(v_sub.studio_id, '/instructor/availability')),
      'avail_edited:' || p_submission_id || ':' || (extract(epoch from clock_timestamp()) * 1000000)::bigint)
      is not null;
  end if;

  return jsonb_build_object('ok', true, 'submission_id', p_submission_id, 'status', v_sub.status,
    'changes', to_jsonb(v_lines), 'outside_count', v_count, 'notified', v_notified,
    'first_name', split_part(coalesce(v_name, ''), ' ', 1));
end $$;
revoke execute on function staff_edit_availability_submission(uuid, jsonb) from public, anon;
grant  execute on function staff_edit_availability_submission(uuid, jsonb) to authenticated, service_role;

-- ========================================================================
-- Template: availability_edited_by_studio (platform default + Reform override)
-- ========================================================================
insert into notification_templates (key, subject, text_body, html_body, note) values
('availability_edited_by_studio', '{studio_name} adjusted your {month} availability',
 E'Hi {first_name},\n\n{studio_name} adjusted your {month} availability:\n\n{change_lines}\n\nReply to this email if this is not what we agreed.\n\nSee my availability: {availability_url}\n\n{studio_name}',
 '<p>Hi {first_name},</p>
<p>{studio_name} adjusted your <strong>{month}</strong> availability:</p>
<ul>{change_html}</ul>
<p>Reply to this email if this is not what we agreed.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{availability_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">See my availability</a></td></tr></table>
<p>{studio_name}</p>',
 'Decision 18(c): staff edited an instructor''s month of availability.')
on conflict (key) do update set subject = excluded.subject, text_body = excluded.text_body,
  html_body = excluded.html_body, note = excluded.note;

insert into notification_templates_overrides (studio_id, key, subject, body, body_html, updated_at)
select s.id, 'availability_edited_by_studio', 'We adjusted your {month} availability',
 E'Hi Coach {first_name},\n\nWe adjusted your {month} availability:\n\n{change_lines}\n\nReply to this email if this is not what we agreed.\n\nSee my availability: {availability_url}\n\nThank you!\nRPC Studio',
 '<p>Hi Coach {first_name},</p>
<p>We adjusted your <strong>{month}</strong> availability:</p>
<ul>{change_html}</ul>
<p>Reply to this email if this is not what we agreed.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{availability_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">See my availability</a></td></tr></table>
<p>Thank you!<br>RPC Studio</p>', now()
  from studios s where s.slug in ('reform', 'reformcollective')
on conflict (studio_id, key) do update set subject = excluded.subject, body = excluded.body,
  body_html = excluded.body_html, updated_at = now();

-- ========================================================================
-- Re-issued from their newest definitions (see the header)
-- ========================================================================
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
  v_guar boolean;         -- 22c: does the studio run guarantees (drives the embed tint)
  v_gift boolean;
  v_priv boolean;         -- 116(c): the embed links to the private sessions page         -- 110(a): the embed links to the gift page when gift cards are on
begin
  select * into v_studio from studios where slug = lower(p_slug) and status = 'active';
  if not found then
    return jsonb_build_object('found', false);
  end if;
  v_tz := v_studio.timezone;

  select coalesce(booking_window_days, 30) into v_window
    from studio_settings where studio_id = v_studio.id;
  v_window := coalesce(v_window, 30);
  select coalesce(public_instructor_name, 'first') into v_name_mode
    from studio_settings where studio_id = v_studio.id;
  v_name_mode := coalesce(v_name_mode, 'first');
  select coalesce(time_format, '24h') into v_fmt
    from studio_settings where studio_id = v_studio.id;
  v_fmt := coalesce(v_fmt, '24h');
  select coalesce(guarantees_enabled, false) into v_guar
    from studio_settings where studio_id = v_studio.id;
  v_guar := coalesce(v_guar, false);
  select coalesce(gift_enabled, false) into v_gift
    from studio_settings where studio_id = v_studio.id;
  v_gift := coalesce(v_gift, false);
  select coalesce(private_sessions_enabled, false) into v_priv
    from studio_settings where studio_id = v_studio.id;
  v_priv := coalesce(v_priv, false);
  v_days := least(greatest(coalesce(p_days, v_window), 1), v_window);

  select payload into v_cached
    from public_schedule_cache
   where slug = v_studio.slug and days = v_days
     and computed_at > now() - interval '5 minutes';
  if v_cached is not null then
    return v_cached;
  end if;

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
        to_char(o.starts_at at time zone v_tz, 'HH24:MI')              as time,
        o.starts_at,
        ct.duration_minutes,
        ct.name                                                        as class_name,
        ct.description,
        ct.color,
        -- Decision 22(c): the effective tier, resolved the same way the member
        -- Book tab and occurrence_guarantee_run do (occurrence first, then the
        -- series, then core). The embed draws core and always with the tint and
        -- the "Always runs" chip; flex is plain.
        case when not v_guar then null
          else case
            when o.guarantee_tier is not null then o.guarantee_tier::text
            when o.flex then 'flex'
            when cs.guarantee_tier is not null then cs.guarantee_tier::text
            when cs.flex then 'flex'
            else 'core'
          end
        end                                                            as tier,
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
      left join class_series cs on cs.id = o.series_id
      left join instructors i on i.id = o.instructor_id
      left join rooms r on r.id = o.room_id
      where o.studio_id = v_studio.id
        and o.status = 'scheduled' and not o.hidden_from_members
        and o.starts_at >= v_from
        and (v_state = 'upcoming' or o.starts_at < v_to)
        and month_published(v_studio.id, o.starts_at)
        and (o.staffing = 'assigned' or not studio_hides_unstaffed(v_studio.id))
      order by o.starts_at
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
      'name',               v_studio.name,
      'slug',               v_studio.slug,
      'timezone',           v_tz,
      'accent_color',       v_studio.accent_color,
      'theme_preset',       v_studio.theme_preset,
      'logo_url',           v_studio.logo_url,
      'app_origin',         'https://' || v_studio.slug || '.studiior.app',
      'time_format',        v_fmt,
      'guarantees_enabled', v_guar,
      'gift_enabled',       v_gift,
      'gift_url',           case when v_gift then 'https://' || v_studio.slug || '.studiior.app/gift' end,
      'private_enabled',    v_priv,
      'private_url',        case when v_priv then 'https://' || v_studio.slug || '.studiior.app/book/private' end
    ),
    'classes', v_classes
  );

  insert into public_schedule_cache (slug, days, payload, computed_at)
  values (v_studio.slug, v_days, v_payload, now())
  on conflict (slug, days) do update
    set payload = excluded.payload, computed_at = excluded.computed_at;

  return v_payload;
end $function$;


CREATE OR REPLACE FUNCTION public.instructor_available_at_run(p_instructor_id uuid, p_starts_at timestamp with time zone, p_ends_at timestamp with time zone)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_studio uuid; v_tz text; v_date date; v_dow int; v_from time; v_to time;
        v_sub uuid; v_strict boolean;
begin
  if p_instructor_id is null then
    return true;
  end if;

  select i.studio_id, s.timezone into v_studio, v_tz
    from instructors i join studios s on s.id = i.studio_id
   where i.id = p_instructor_id;
  if v_studio is null then
    return false;
  end if;

  v_date := (p_starts_at at time zone v_tz)::date;
  v_dow  := extract(dow from (p_starts_at at time zone v_tz))::int;
  v_from := (p_starts_at at time zone v_tz)::time;
  v_to   := (p_ends_at   at time zone v_tz)::time;

  -- 1. A STANDALONE dated row (time off, or a date set outside a submission)
  --    wins over everything (Decision 18(d)).
  if exists (select 1 from instructor_availability a
              where a.instructor_id = p_instructor_id and a.exception_date = v_date
                and a.submission_id is null) then
    return exists (
      select 1 from instructor_availability a
       where a.instructor_id = p_instructor_id
         and a.exception_date = v_date
         and a.submission_id is null
         and a.is_available
         and (a.starts_at_time is null or a.starts_at_time <= v_from)
         and (a.ends_at_time   is null or a.ends_at_time   >= v_to));
  end if;

  -- 2. An APPROVED submission whose month covers this date answers for it alone.
  select s.id into v_sub
    from availability_submissions s
   where s.instructor_id = p_instructor_id
     and s.status = 'approved'
     and v_date between s.period_start
                    and (s.period_start + interval '1 month' - interval '1 day')::date
   order by s.period_start desc
   limit 1;

  if v_sub is not null then
    -- 18(d): inside the approved month, a date row wins over the weekday rows.
    if exists (select 1 from instructor_availability a
                where a.submission_id = v_sub and a.exception_date = v_date
                  and a.approval_status = 'approved') then
      return exists (
        select 1 from instructor_availability a
         where a.submission_id = v_sub
           and a.exception_date = v_date
           and a.approval_status = 'approved'
           and a.is_available
           and (a.starts_at_time is null or a.starts_at_time <= v_from)
           and (a.ends_at_time   is null or a.ends_at_time   >= v_to));
    end if;
    return exists (
      select 1 from instructor_availability a
       where a.submission_id = v_sub
         and a.day_of_week = v_dow
         and a.approval_status = 'approved'
         and a.is_available
         and (a.starts_at_time is null or a.starts_at_time <= v_from)
         and (a.ends_at_time   is null or a.ends_at_time   >= v_to));
  end if;

  -- 3. No stated availability is not the same as being unavailable — UNLESS the
  --    studio has turned on "no availability means not available" (Decision 46),
  --    in which case an instructor with nothing on file falls through to step 4
  --    (the standing pattern) and, having none, is not available.
  select coalesce(ss.assign_requires_availability, false) into v_strict
    from studio_settings ss where ss.studio_id = v_studio;
  if not v_strict then
    if not exists (select 1 from instructor_availability a
                    where a.instructor_id = p_instructor_id
                      and a.day_of_week is not null
                      and a.submission_id is null
                      and a.approval_status = 'approved') then
      return true;
    end if;
  end if;

  -- 4. The standing weekly pattern (already bounded on effective_from/to).
  return exists (
    select 1 from instructor_availability a
     where a.instructor_id = p_instructor_id
       and a.day_of_week = v_dow
       and a.submission_id is null
       and a.approval_status = 'approved'
       and a.is_available
       and (a.effective_from is null or a.effective_from <= v_date)
       and (a.effective_to   is null or a.effective_to   >= v_date)
       and (a.starts_at_time is null or a.starts_at_time <= v_from)
       and (a.ends_at_time   is null or a.ends_at_time   >= v_to));
end $function$;


create or replace function submit_availability(
  p_instructor_id uuid,
  p_period_start  date,
  p_days          jsonb,
  p_submit        boolean default true
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_studio uuid;
  v_tz     text;
  v_today  date;
  v_end    date;
  v_status text;
  v_sub    availability_submissions%rowtype;
  v_is_mgr boolean;
  d jsonb; r jsonb; v_day int; n int := 0; v_date date;
begin
  select i.studio_id, s.timezone into v_studio, v_tz
    from instructors i join studios s on s.id = i.studio_id
   where i.id = p_instructor_id;
  if v_studio is null then
    raise exception 'no such instructor' using errcode = 'PT404';
  end if;

  v_is_mgr := coalesce(is_manager_up(v_studio), false);
  if not v_is_mgr and p_instructor_id is distinct from auth_instructor_id(v_studio) then
    raise exception 'only the studio or the instructor may submit their availability'
      using errcode = 'PT403';
  end if;

  if p_period_start <> date_trunc('month', p_period_start)::date then
    raise exception 'a submission covers a whole month, so it starts on the 1st'
      using errcode = 'PT422';
  end if;
  v_today := (now() at time zone v_tz)::date;
  if p_period_start < date_trunc('month', v_today)::date then
    raise exception 'that month has already been and gone' using errcode = 'PT422';
  end if;

  -- Decision 46: once this month's schedule is published the studio is
  -- scheduling around what was submitted, so the instructor cannot change it;
  -- staff still can (the manager path). Gated on publication_enabled because
  -- month_published() answers true for every month when publication is off.
  if not v_is_mgr and publication_enabled(v_studio)
     and month_published(v_studio, (p_period_start + 15)::timestamp at time zone v_tz) then
    raise exception 'This month''s schedule is already published — ask the studio if something has changed.'
      using errcode = 'PT409';
  end if;

  v_end := (p_period_start + interval '1 month' - interval '1 day')::date;

  v_status := case
    when v_is_mgr then 'approved'
    when p_submit then 'submitted'
    else 'draft' end;

  insert into availability_submissions
    (studio_id, instructor_id, period_start, status, submitted_at,
     reviewed_by, reviewed_at, created_by, note)
  values (v_studio, p_instructor_id, p_period_start, v_status,
          case when v_status in ('submitted','approved') then now() end,
          case when v_status = 'approved' then auth.uid() end,
          case when v_status = 'approved' then now() end,
          auth.uid(), null)
  on conflict (instructor_id, period_start) do update
    set status = excluded.status,
        submitted_at = excluded.submitted_at,
        reviewed_by = excluded.reviewed_by,
        reviewed_at = excluded.reviewed_at,
        note = null,
        updated_at = now()
  returning * into v_sub;

  if v_sub.id is null then
    raise exception 'that submission is not yours' using errcode = 'PT403';
  end if;
  if v_sub.status = 'approved' and not v_is_mgr then
    raise exception 'that month is already approved — ask the studio to reopen it'
      using errcode = 'PT409';
  end if;

  delete from instructor_availability where submission_id = v_sub.id;

  for d in select * from jsonb_array_elements(p_days) loop
    -- Decision 18(d): a specific date carries its own hours, or is marked off.
    if d ? 'date' then
      v_date := (d ->> 'date')::date;
      if v_date < p_period_start or v_date > v_end then
        raise exception 'a date must fall inside the month, got %', v_date using errcode = 'PT422';
      end if;
      if coalesce((d ->> 'unavailable')::boolean, false) then
        insert into instructor_availability
          (studio_id, instructor_id, exception_date, is_available, created_by,
           submission_id, approval_status)
        values (v_studio, p_instructor_id, v_date, false, auth.uid(), v_sub.id, v_sub.status);
        n := n + 1;
      else
        for r in select * from jsonb_array_elements(coalesce(d -> 'ranges', '[]'::jsonb)) loop
          if (r ->> 'to')::time <= (r ->> 'from')::time then
            raise exception 'a range must end after it starts (%, % to %)',
              v_date, r ->> 'from', r ->> 'to' using errcode = 'PT422';
          end if;
          insert into instructor_availability
            (studio_id, instructor_id, exception_date, starts_at_time, ends_at_time,
             is_available, created_by, submission_id, approval_status)
          values (v_studio, p_instructor_id, v_date, (r ->> 'from')::time, (r ->> 'to')::time,
                  true, auth.uid(), v_sub.id, v_sub.status);
          n := n + 1;
        end loop;
      end if;
      continue;
    end if;
    v_day := (d ->> 'day')::int;
    if v_day is null or v_day < 0 or v_day > 6 then
      raise exception 'day_of_week must be 0-6, got %', d ->> 'day' using errcode = 'PT422';
    end if;
    for r in select * from jsonb_array_elements(coalesce(d -> 'ranges', '[]'::jsonb)) loop
      if (r ->> 'to')::time <= (r ->> 'from')::time then
        raise exception 'a range must end after it starts (day %, % to %)',
          v_day, r ->> 'from', r ->> 'to' using errcode = 'PT422';
      end if;
      insert into instructor_availability
        (studio_id, instructor_id, day_of_week, starts_at_time, ends_at_time,
         effective_from, effective_to, is_available, created_by,
         submission_id, approval_status)
      values (v_studio, p_instructor_id, v_day,
              (r ->> 'from')::time, (r ->> 'to')::time,
              p_period_start, v_end, true, auth.uid(),
              v_sub.id, v_sub.status);
      n := n + 1;
    end loop;
  end loop;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (v_studio, auth.uid(), 'availability.submitted', 'instructors', p_instructor_id,
          jsonb_build_object('period', p_period_start, 'status', v_sub.status,
                             'ranges', n));

  -- Decision 43: only let the engine fill when the studio's switch is on.
  if v_sub.status = 'approved' and auto_assign_enabled(v_studio) then
    perform assign_instructors_run(v_studio);
  end if;

  return jsonb_build_object(
    'submission_id', v_sub.id, 'status', v_sub.status,
    'period_start', p_period_start, 'period_end', v_end,
    'ranges', n,
    'auto_approved', v_is_mgr);
end $$;


create or replace function set_availability_exception(
  p_instructor_id uuid,
  p_date          date,
  p_ranges        jsonb default '[]'::jsonb,
  p_note          text default null
) returns int
language plpgsql security definer set search_path = public as $$
declare v_studio uuid; r jsonb; n int := 0;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then
    raise exception 'no such instructor' using errcode = 'PT404';
  end if;
  if not is_manager_up(v_studio)
     and p_instructor_id is distinct from auth_instructor_id(v_studio) then
    raise exception 'only the studio or the instructor may set their availability'
      using errcode = 'PT403';
  end if;

  delete from instructor_availability
   where instructor_id = p_instructor_id and exception_date = p_date
     and submission_id is null;

  if jsonb_array_length(coalesce(p_ranges, '[]'::jsonb)) = 0 then
    -- Unavailable all day, stated positively. instructor_available_at() looks
    -- for ANY exception row on the date first, so a row saying "no" is what
    -- makes the day off beat the weekly pattern — an absent row would simply
    -- fall through to "Tuesdays are fine".
    insert into instructor_availability
      (studio_id, instructor_id, exception_date, is_available, note, created_by)
    values (v_studio, p_instructor_id, p_date, false, p_note, auth.uid());
    n := 1;
  else
    for r in select * from jsonb_array_elements(p_ranges) loop
      if (r ->> 'to')::time <= (r ->> 'from')::time then
        raise exception 'a range must end after it starts' using errcode = 'PT422';
      end if;
      insert into instructor_availability
        (studio_id, instructor_id, exception_date, starts_at_time, ends_at_time,
         is_available, note, created_by)
      values (v_studio, p_instructor_id, p_date,
              (r ->> 'from')::time, (r ->> 'to')::time, true, p_note, auth.uid());
      n := n + 1;
    end loop;
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (v_studio, auth.uid(), 'availability.exception', 'instructors', p_instructor_id,
          jsonb_build_object('date', p_date, 'ranges', p_ranges));
  return n;
end $$;


create or replace function clear_availability_exception(
  p_instructor_id uuid, p_date date
) returns int
language plpgsql security definer set search_path = public as $$
declare v_studio uuid; n int;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then
    raise exception 'no such instructor' using errcode = 'PT404';
  end if;
  if not is_manager_up(v_studio)
     and p_instructor_id is distinct from auth_instructor_id(v_studio) then
    raise exception 'only the studio or the instructor may set their availability'
      using errcode = 'PT403';
  end if;
  delete from instructor_availability
   where instructor_id = p_instructor_id and exception_date = p_date
     and submission_id is null;
  get diagnostics n = row_count;
  return n;
end $$;


CREATE OR REPLACE FUNCTION public.instructor_availability_week(p_instructor_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_studio uuid;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then
    -- Not "no such instructor". A caller who may not read this must not be able
    -- to use the error to find out whether an id exists.
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;
  if not is_manager_up(v_studio)
     and p_instructor_id is distinct from auth_instructor_id(v_studio)
     and not is_service_context() then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;

  return (select jsonb_build_object(
    'days', (
      select coalesce(jsonb_agg(jsonb_build_object('day', dow, 'ranges', ranges) order by dow), '[]'::jsonb)
        from (
          select a.day_of_week as dow,
                 jsonb_agg(jsonb_build_object(
                   'from', to_char(a.starts_at_time, 'HH24:MI'),
                   'to',   to_char(a.ends_at_time,   'HH24:MI'))
                   order by a.starts_at_time) as ranges
            from instructor_availability a
           where a.instructor_id = p_instructor_id
             and a.day_of_week is not null and a.is_available
             and a.submission_id is null
           group by a.day_of_week
        ) g),
    'effective_from', (select min(effective_from) from instructor_availability
                        where instructor_id = p_instructor_id and day_of_week is not null
                          and submission_id is null),
    'effective_to',   (select max(effective_to) from instructor_availability
                        where instructor_id = p_instructor_id and day_of_week is not null
                          and submission_id is null),
    'exceptions', (
      select coalesce(jsonb_agg(e order by e ->> 'date'), '[]'::jsonb) from (
        select jsonb_build_object(
                 'date', a.exception_date,
                 'available', bool_or(a.is_available),
                 'note', min(a.note),
                 'ranges', coalesce(jsonb_agg(jsonb_build_object(
                     'from', to_char(a.starts_at_time, 'HH24:MI'),
                     'to',   to_char(a.ends_at_time,   'HH24:MI'))
                     order by a.starts_at_time)
                     filter (where a.starts_at_time is not null), '[]'::jsonb)) as e
          from instructor_availability a
         where a.instructor_id = p_instructor_id and a.exception_date is not null
           and a.submission_id is null
         group by a.exception_date
      ) x)
  ));
end $function$;


create or replace function instructor_time_off()
returns table(from_date date, to_date date, reason text, is_past boolean, class_count int)
language plpgsql security definer set search_path = public as $$
declare v_studio uuid; v_instr uuid; v_tz text; v_today date;
begin
  select i.id, i.studio_id into v_instr, v_studio
    from instructors i join studio_staff s on s.id = i.staff_id
   where s.user_id = auth.uid() and s.status = 'active' limit 1;
  if v_instr is null then
    raise exception 'only an instructor can read this' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = v_studio;
  v_today := (now() at time zone v_tz)::date;
  return query
  with ex as (
    select exception_date as d, coalesce(note, '') as note
      from instructor_availability
     where instructor_id = v_instr and exception_date is not null
       and submission_id is null
       and coalesce(is_available, true) = false
  ),
  g as (
    select d, note, d - (row_number() over (partition by note order by d))::int as grp
      from ex
  )
  select min(g.d), max(g.d), nullif(min(g.note), ''),
         (max(g.d) < v_today),
         (select count(*)::int from class_occurrences o
            where o.instructor_id = v_instr and o.status = 'scheduled'
              and (o.starts_at at time zone v_tz)::date between min(g.d) and max(g.d))
    from g
   group by g.note, g.grp
   order by 1;
end $$;


create or replace function availability_submission_week(
  p_instructor_id uuid, p_period_start date
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_sub availability_submissions%rowtype; v_end date;
        v_pattern_days jsonb; v_ends_on date; v_open boolean;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then
    raise exception 'no such instructor' using errcode = 'PT404';
  end if;
  if not coalesce(is_manager_up(v_studio), false)
     and p_instructor_id is distinct from auth_instructor_id(v_studio) then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;

  select * into v_sub from availability_submissions
   where instructor_id = p_instructor_id and period_start = p_period_start;

  -- A real submission exists (any status) — return it exactly as before.
  if v_sub.id is not null then
    return jsonb_build_object(
      'submission_id', v_sub.id,
      'status', coalesce(v_sub.status, 'none'),
      'source', 'submission',
      'note', v_sub.note,
      'submitted_at', v_sub.submitted_at,
      'reviewed_at', v_sub.reviewed_at,
      'period_start', p_period_start,
      'period_end', (p_period_start + interval '1 month' - interval '1 day')::date,
      'pattern_ends_on', null,
      'days', coalesce((
        select jsonb_agg(jsonb_build_object('day', day_of_week, 'ranges', ranges)
                         order by day_of_week)
          from (
            select a.day_of_week,
                   jsonb_agg(jsonb_build_object('from', to_char(a.starts_at_time,'HH24:MI'),
                                                'to',   to_char(a.ends_at_time,'HH24:MI'))
                             order by a.starts_at_time) as ranges
              from instructor_availability a
             where a.submission_id = v_sub.id and a.day_of_week is not null
             group by a.day_of_week) z
      ), '[]'::jsonb),
      -- Decision 18(d): the month's specific dates, own hours or off.
      'dates', availability_submission_dates(v_sub.id));
  end if;

  -- No submission: a covering standing pattern? Return its weekly ranges + end.
  v_end := (p_period_start + interval '1 month' - interval '1 day')::date;
  select coalesce(jsonb_agg(jsonb_build_object('day', day_of_week, 'ranges', ranges)
                            order by day_of_week), '[]'::jsonb),
         bool_or(ends_to is null),
         max(ends_to)
    into v_pattern_days, v_open, v_ends_on
    from (
      select a.day_of_week,
             jsonb_agg(jsonb_build_object('from', to_char(a.starts_at_time,'HH24:MI'),
                                          'to',   to_char(a.ends_at_time,'HH24:MI'))
                       order by a.starts_at_time) as ranges,
             min(a.effective_to) filter (where a.effective_to is not null) as ends_to,
             bool_or(a.effective_to is null) as any_open
        from instructor_availability a
       where a.instructor_id = p_instructor_id
         and a.submission_id is null and a.day_of_week is not null
         and a.approval_status = 'approved' and a.is_available = true
         and (a.effective_from is null or a.effective_from <= v_end)
         and (a.effective_to is null or a.effective_to >= p_period_start)
       group by a.day_of_week) z;

  if jsonb_array_length(v_pattern_days) > 0 then
    return jsonb_build_object(
      'submission_id', null, 'status', 'none', 'source', 'pattern',
      'note', null, 'submitted_at', null, 'reviewed_at', null,
      'period_start', p_period_start,
      'period_end', v_end,
      -- Open-ended wins (no end date); else the latest end across the pattern.
      'pattern_ends_on', case when v_open then null else v_ends_on end,
      'days', v_pattern_days);
  end if;

  -- Nothing on file.
  return jsonb_build_object(
    'submission_id', null, 'status', 'none', 'source', 'none',
    'note', null, 'submitted_at', null, 'reviewed_at', null,
    'period_start', p_period_start,
    'period_end', v_end,
    'pattern_ends_on', null,
    'days', '[]'::jsonb);
end $$;

revoke execute on function public_schedule(text, integer) from public;
grant  execute on function public_schedule(text, integer) to anon, authenticated, service_role;
delete from public_schedule_cache;
revoke execute on function instructor_available_at_run(uuid, timestamptz, timestamptz) from public, anon, authenticated;
grant  execute on function instructor_available_at_run(uuid, timestamptz, timestamptz) to service_role;
revoke execute on function availability_submission_week(uuid, date) from public, anon;
grant  execute on function availability_submission_week(uuid, date) to authenticated, service_role;

do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'expect_%';
  if n <> 14 then
    raise exception 'anon surface is % functions, expected exactly fourteen', n;
  end if;
end $$;
