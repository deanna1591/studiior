-- Decision 99 — Instructors block off dates.
-- An instructor marks themselves unavailable for a date or a range from their
-- app (My schedule -> Time off). It writes one unavailable exception per day
-- through the existing exception mechanism (set_availability_exception), with
-- the reason as the note. A date with an assigned scheduled class is allowed,
-- not refused: the studio gets one instructor_time_off email listing those
-- classes with a roster link to each, and the sheet warned before saving. A
-- class within the studio's swap cut-off (cover_escalation_hours) is too close
-- to block and must go through cover instead. Past dates are refused.
--
-- creates: instructor_time_off_classes(date, date), instructor_block_dates(date, date, text),
--   instructor_unblock_dates(date, date), instructor_time_off()
-- re-issues: (none)

-- ===========================================================================
-- Template: instructor_time_off (to the studio owner login, via queue_shift_notice).
-- ===========================================================================
insert into notification_templates (key, subject, text_body, html_body, note) values (
 'instructor_time_off',
 '{instructor_name} is off {range}',
 E'Hi {first_name},\n\n{instructor_name} has blocked off {range}{reason_line}.\n\nThese classes of theirs fall in those dates and will need cover:\n{class_list}\n\nOpen each roster to arrange cover.\n\n{studio_name}',
 '<p>Hi {first_name},</p>'
 '<p><strong>{instructor_name}</strong> has blocked off {range}{reason_html}.</p>'
 '<p>These classes of theirs fall in those dates and will need cover:</p><ul>{class_list_html}</ul>'
 '<p>Open each roster to arrange cover.</p>'
 '<p>{studio_name}</p>',
 'Decision 99. Sent to the studio owner when an instructor blocks dates that '
 'contain classes they are assigned to teach. Tokens: first_name, instructor_name, '
 'range, reason_line, reason_html, class_list, class_list_html, studio_name.')
on conflict (key) do update
  set subject = excluded.subject, text_body = excluded.text_body,
      html_body = excluded.html_body, note = excluded.note;

-- ===========================================================================
-- instructor_time_off_classes — the caller's OWN assigned, scheduled, future
-- classes in a date range. The Time off sheet counts these for its warning
-- line; instructor_block_dates builds the email list from the same predicate.
-- ===========================================================================
create or replace function instructor_time_off_classes(p_from date, p_to date)
returns table(occurrence_id uuid, class_name text, when_label text)
language plpgsql security definer set search_path = public as $$
declare v_studio uuid; v_instr uuid; v_tz text; v_fmt text;
begin
  select i.id, i.studio_id into v_instr, v_studio
    from instructors i join studio_staff s on s.id = i.staff_id
   where s.user_id = auth.uid() and s.status = 'active' limit 1;
  if v_instr is null then
    raise exception 'only an instructor can read this' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = v_studio;
  select coalesce(time_format, '24h') into v_fmt from studio_settings where studio_id = v_studio;
  v_fmt := coalesce(v_fmt, '24h');
  return query
    select o.id,
           coalesce((select name from class_types where id = o.class_type_id), o.name, 'a class'),
           to_char(o.starts_at at time zone v_tz, 'FMDy FMDD FMMon ') || fmt_clock(o.starts_at, v_tz, v_fmt)
      from class_occurrences o
     where o.instructor_id = v_instr and o.status = 'scheduled'
       and o.starts_at > now()
       and (o.starts_at at time zone v_tz)::date between p_from and p_to
     order by o.starts_at;
end $$;

-- ===========================================================================
-- instructor_block_dates — the caller blocks a date or range for themselves.
-- One unavailable exception per day (reuses set_availability_exception, whose
-- own guard passes because this passes the caller's OWN instructor id). Past
-- dates refused; a class within the swap cut-off refused (ask for cover); a
-- date with an assigned class allowed and the studio told once.
-- ===========================================================================
create or replace function instructor_block_dates(p_from date, p_to date, p_reason text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_studio uuid; v_instr uuid; v_tz text; v_fmt text; v_hours int; v_today date;
  d date; v_days int := 0; v_name text; v_owner uuid; v_owner_first text;
  v_list_txt text; v_list_html text; v_count int := 0; v_range text;
  v_reason_line text := ''; v_reason_html text := ''; v_reason text;
  v_too record; v_s studios%rowtype; v_origin text;
begin
  select i.id, i.studio_id, coalesce(nullif(btrim(i.display_name), ''), 'The instructor')
    into v_instr, v_studio, v_name
    from instructors i join studio_staff s on s.id = i.staff_id
   where s.user_id = auth.uid() and s.status = 'active' limit 1;
  if v_instr is null then
    raise exception 'only an instructor can block their own dates' using errcode = 'PT403';
  end if;
  select * into v_s from studios where id = v_studio;
  v_tz := v_s.timezone;
  select coalesce(time_format, '24h'), coalesce(cover_escalation_hours, 4)
    into v_fmt, v_hours from studio_settings where studio_id = v_studio;
  v_fmt := coalesce(v_fmt, '24h'); v_hours := coalesce(v_hours, 4);
  v_today := (now() at time zone v_tz)::date;
  v_reason := nullif(btrim(coalesce(p_reason, '')), '');
  v_origin := coalesce(nullif(notification_setting('staff_app_origin'), ''), 'https://app.studiior.com');

  if p_to < p_from then
    raise exception 'The end date is before the start date.' using errcode = 'PT422';
  end if;
  if p_from < v_today then
    raise exception 'Those dates are in the past.' using errcode = 'PT409';
  end if;

  -- The swap cut-off: a class too close to start cannot be blocked; the
  -- instructor asks for cover on it instead (Decision 18).
  select o.id,
         coalesce((select name from class_types where id = o.class_type_id), o.name, 'a class') as nm,
         to_char(o.starts_at at time zone v_tz, 'FMDy FMDD FMMon ') || fmt_clock(o.starts_at, v_tz, v_fmt) as whenl
    into v_too
    from class_occurrences o
   where o.instructor_id = v_instr and o.status = 'scheduled'
     and (o.starts_at at time zone v_tz)::date between p_from and p_to
     and o.starts_at < now() + make_interval(hours => v_hours)
   order by o.starts_at limit 1;
  if v_too.id is not null then
    raise exception '% on % starts too soon to block. Ask for cover on it instead.',
      v_too.nm, v_too.whenl using errcode = 'PT409';
  end if;

  -- One unavailable exception per day.
  d := p_from;
  while d <= p_to loop
    perform set_availability_exception(v_instr, d, '[]'::jsonb, v_reason);
    v_days := v_days + 1;
    d := d + 1;
  end loop;

  -- The classes those dates contain, for the count and the studio email.
  select count(*)::int,
         string_agg(nm || ' · ' || whenl, E'\n' order by st),
         string_agg('<li><a href="' || v_origin || '/roster/' || oid::text || '">'
                    || nm || ' · ' || whenl || '</a></li>', '' order by st)
    into v_count, v_list_txt, v_list_html
  from (
    select o.id as oid, o.starts_at as st,
           coalesce((select name from class_types where id = o.class_type_id), o.name, 'a class') as nm,
           to_char(o.starts_at at time zone v_tz, 'FMDy FMDD FMMon ') || fmt_clock(o.starts_at, v_tz, v_fmt) as whenl
      from class_occurrences o
     where o.instructor_id = v_instr and o.status = 'scheduled'
       and o.starts_at > now()
       and (o.starts_at at time zone v_tz)::date between p_from and p_to
  ) q;

  if p_from = p_to then
    v_range := to_char(p_from, 'FMDy FMDD FMMon');
  else
    v_range := to_char(p_from, 'FMDy FMDD FMMon') || ' to ' || to_char(p_to, 'FMDy FMDD FMMon');
  end if;
  if v_reason is not null then
    v_reason_line := ' (' || v_reason || ')';
    v_reason_html := ' (' || replace(replace(replace(v_reason, '&', '&amp;'), '<', '&lt;'), '>', '&gt;') || ')';
  end if;

  -- Tell the studio once, to the owner login (where studio-facing mail goes).
  if coalesce(v_count, 0) > 0 then
    select ss.user_id into v_owner from studio_staff ss
     where ss.studio_id = v_studio and ss.role = 'owner' and ss.status = 'active'
     order by ss.created_at limit 1;
    v_owner_first := coalesce(
      nullif(split_part((select full_name from profiles where id = v_owner), ' ', 1), ''), 'there');
    if v_owner is not null then
      perform queue_shift_notice(v_studio, v_owner, 'instructor_time_off',
        jsonb_build_object(
          'first_name', v_owner_first, 'instructor_name', v_name, 'range', v_range,
          'reason_line', v_reason_line, 'reason_html', v_reason_html,
          'class_list', v_list_txt, 'class_list_html', v_list_html, 'studio_name', v_s.name),
        'instr_time_off:' || v_instr::text || ':' || p_from::text || ':' || p_to::text
          || ':' || extract(epoch from clock_timestamp())::bigint::text);
    end if;
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (v_studio, auth.uid(), 'instructor.time_off_set', 'instructors', v_instr,
            jsonb_build_object('from', p_from, 'to', p_to, 'reason', v_reason,
                               'days', v_days, 'class_count', coalesce(v_count, 0)));

  return jsonb_build_object('ok', true, 'days', v_days, 'class_count', coalesce(v_count, 0), 'range', v_range);
end $$;

-- ===========================================================================
-- instructor_unblock_dates — clear the caller's own time off over a range.
-- Past days cannot be removed: only today onward is cleared.
-- ===========================================================================
create or replace function instructor_unblock_dates(p_from date, p_to date)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_studio uuid; v_instr uuid; v_tz text; v_today date; d date; v_from date; v_days int := 0;
begin
  select i.id, i.studio_id into v_instr, v_studio
    from instructors i join studio_staff s on s.id = i.staff_id
   where s.user_id = auth.uid() and s.status = 'active' limit 1;
  if v_instr is null then
    raise exception 'only an instructor can clear their own dates' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = v_studio;
  v_today := (now() at time zone v_tz)::date;
  v_from := greatest(p_from, v_today);
  d := v_from;
  while d <= p_to loop
    perform clear_availability_exception(v_instr, d);
    v_days := v_days + 1;
    d := d + 1;
  end loop;
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (v_studio, auth.uid(), 'instructor.time_off_cleared', 'instructors', v_instr,
            jsonb_build_object('from', v_from, 'to', p_to, 'days', v_days));
  return jsonb_build_object('ok', true, 'days', v_days);
end $$;

-- ===========================================================================
-- instructor_time_off — the caller's own time off, as ranges (consecutive
-- full-day-off exceptions with equal reason collapsed), for the My schedule
-- list. is_past marks a range already behind today (Remove is hidden for it).
-- ===========================================================================
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

-- ===========================================================================
-- ACLs: authenticated + service_role, never anon. The anon surface is THIRTEEN.
-- ===========================================================================
revoke execute on function instructor_time_off_classes(date, date) from public, anon;
grant  execute on function instructor_time_off_classes(date, date) to authenticated, service_role;
revoke execute on function instructor_block_dates(date, date, text) from public, anon;
grant  execute on function instructor_block_dates(date, date, text) to authenticated, service_role;
revoke execute on function instructor_unblock_dates(date, date) from public, anon;
grant  execute on function instructor_unblock_dates(date, date) to authenticated, service_role;
revoke execute on function instructor_time_off() from public, anon;
grant  execute on function instructor_time_off() to authenticated, service_role;

do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % not 13', n; end if;
end $$;
