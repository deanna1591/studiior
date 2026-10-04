-- Decision 59 — the monthly schedule email states the classes and the cover
-- rule, asks for confirmation only when confirmations are on, and can be re-sent.
--
-- re-issues: publish_month(uuid,date), my_month_roster(uuid,date), notification_ics(uuid)
-- creates:   month_roster_lines(uuid,date), resend_month_roster(uuid,date)
--
-- Decision 18 untouched: nothing here changes how a cover becomes final; the
-- email just names the rule. Anon stays EXACTLY THIRTEEN.

-- =============================================================================
-- Templates. Two versions, chosen by assignment_confirmations. month_roster is
-- re-issued (do update) with the cover sentence + {hours}; month_roster_plain is
-- the off version. Both carry {roster}/{roster_html} and {hours}.
-- =============================================================================
insert into notification_templates (key, subject, text_body, html_body, note) values
('month_roster',
 'Your {month} classes at {studio_name} — please confirm',
 E'Hi {instructor_name},\n\n{studio_name} has published {month}. You are down for {count} class{plural}:\n\n{roster}\n\nIf you can''t make a class, ask for cover in your instructor app at least {hours} hours before it starts — you can ask a colleague directly and they confirm from their phone.\n\nConfirm the month in one go, or flag any you cannot do and the studio will arrange cover: {href}\n\nThank you,\n{studio_name}',
 '<p>Hi {instructor_name},</p><p>{studio_name} has published <strong>{month}</strong>. You are down for {count} class{plural}:</p><ul>{roster_html}</ul><p>If you can&rsquo;t make a class, ask for cover in your instructor app at least {hours} hours before it starts — you can ask a colleague directly and they confirm from their phone.</p><p><a href="{href}">Confirm the month</a>, or flag any you cannot do and the studio will arrange cover.</p><p>Thank you,<br>{studio_name}</p>',
 'Decision 25 + 59. Confirmations ON: the roster plus the cover sentence ({hours} = cover_escalation_hours).')
on conflict (key) do update
   set subject = excluded.subject, text_body = excluded.text_body,
       html_body = excluded.html_body, note = excluded.note;

insert into notification_templates (key, subject, text_body, html_body, note) values
('month_roster_plain',
 'Your {month} schedule at {studio_name}',
 E'Hi {instructor_name},\n\nHere is your {month} schedule at {studio_name} — {count} class{plural}:\n\n{roster}\n\nIf you can''t make a class, ask for cover in your instructor app at least {hours} hours before it starts — you can ask a colleague directly and they confirm from their phone.\n\nOpen your schedule: {href}\n\n{studio_name}',
 '<p>Hi {instructor_name},</p><p>Here is your {month} schedule at {studio_name} — {count} class{plural}:</p><ul>{roster_html}</ul><p>If you can&rsquo;t make a class, ask for cover in your instructor app at least {hours} hours before it starts — you can ask a colleague directly and they confirm from their phone.</p><p><a href="{href}">Open your schedule</a></p><p>{studio_name}</p>',
 'Decision 59. Confirmations OFF: the schedule and the cover rule, no "please confirm".')
on conflict (key) do update
   set subject = excluded.subject, text_body = excluded.text_body,
       html_body = excluded.html_body, note = excluded.note;

-- =============================================================================
-- The shared per-instructor roster build — one definition, through fmt_clock
-- (the old inline HH24:MI did not honour the studio's time_format). Service-role
-- only; reached inside publish_month / resend_month_roster (SECURITY DEFINER).
-- =============================================================================
create or replace function month_roster_lines(p_studio_id uuid, p_month date)
returns table(instructor_id uuid, display_name text, n int, lines text, lines_html text)
language plpgsql stable security definer set search_path = public as $$
declare v_tz text; v_fmt text; v_month date; v_from timestamptz; v_to timestamptz;
begin
  select timezone into v_tz from studios where id = p_studio_id;
  select coalesce(time_format, '24h') into v_fmt from studio_settings where studio_id = p_studio_id;
  v_fmt := coalesce(v_fmt, '24h');
  v_month := date_trunc('month', p_month)::date;
  v_from := (v_month::timestamp) at time zone v_tz;
  v_to   := ((v_month + interval '1 month')::timestamp) at time zone v_tz;
  return query
    select i.id, i.display_name, count(*)::int,
           string_agg(format('%s — %s%s',
                             to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMon, ') || fmt_clock(o.starts_at, v_tz, v_fmt),
                             o.name,
                             case when rm.name is null then '' else ' (' || rm.name || ')' end),
                      E'\n' order by o.starts_at),
           string_agg(format('<li>%s — %s%s</li>',
                             to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMon, ') || fmt_clock(o.starts_at, v_tz, v_fmt),
                             replace(replace(replace(o.name, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'),
                             case when rm.name is null then '' else ' (' ||
                               replace(replace(replace(rm.name, '&', '&amp;'), '<', '&lt;'), '>', '&gt;') || ')' end),
                      '' order by o.starts_at)
      from class_occurrences o
      join instructors i on i.id = o.instructor_id
      left join rooms rm on rm.id = o.room_id
     where o.studio_id = p_studio_id and o.status = 'scheduled'
       and o.starts_at >= v_from and o.starts_at < v_to
     group by i.id, i.display_name
     order by i.display_name;
end $$;
revoke execute on function month_roster_lines(uuid, date) from public, anon, authenticated;
grant  execute on function month_roster_lines(uuid, date) to service_role;

-- =============================================================================
-- publish_month — re-issued from 20260831670000 with: the roster build moved to
-- month_roster_lines; the template + {hours} chosen by assignment_confirmations.
-- Everything else byte-for-byte (the once-per-month dedupe, roster_confirmations,
-- unreachable list, audit, facts return).
-- =============================================================================
create or replace function publish_month(p_studio_id uuid, p_month date)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_facts jsonb; v_month date; v_tz text; v_name text; v_slug text;
  v_from timestamptz; v_to timestamptz;
  r record; v_user uuid; v_conf boolean; v_hours int; v_template text;
  n_notified int := 0; v_unreachable jsonb := '[]'::jsonb;
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers publish the timetable' using errcode = 'PT403';
  end if;
  if not publication_enabled(p_studio_id) then
    raise exception 'publication is not turned on for this studio'
      using errcode = 'PT409',
            hint = 'Turn it on under Settings first. Until then every month is already live.';
  end if;

  v_facts := month_publication_facts(p_studio_id, p_month);
  v_month := (v_facts ->> 'month')::date;

  if (v_facts ->> 'is_past')::boolean then
    raise exception '% has already ended and is on the record whatever anybody presses',
      v_facts ->> 'label' using errcode = 'PT409';
  end if;

  if (v_facts ->> 'published')::boolean then
    return v_facts || jsonb_build_object('ok', true, 'already_published', true,
                                         'notified', 0, 'unreachable', '[]'::jsonb);
  end if;

  select s.timezone, s.name, s.slug into v_tz, v_name, v_slug from studios s where s.id = p_studio_id;
  v_from := (v_month::timestamp) at time zone v_tz;
  v_to   := ((v_month + interval '1 month')::timestamp) at time zone v_tz;

  -- Decision 59: the version, and the cover-rule number.
  select coalesce(assignment_confirmations, false), coalesce(cover_escalation_hours, 4)
    into v_conf, v_hours from studio_settings where studio_id = p_studio_id;
  v_template := case when v_conf then 'month_roster' else 'month_roster_plain' end;

  insert into schedule_publications (studio_id, month, published_by, classes, open_shifts)
  values (p_studio_id, v_month, auth.uid(),
          (v_facts ->> 'classes')::int, (v_facts ->> 'open_shifts')::int);

  -- One roster per instructor with at least one class, their own classes only.
  for r in select * from month_roster_lines(p_studio_id, v_month)
  loop
    v_user := instructor_user_id(r.instructor_id);

    insert into roster_confirmations (studio_id, instructor_id, month, classes_at_notify, notified_at)
    values (p_studio_id, r.instructor_id, v_month, r.n, case when v_user is null then null else now() end)
    on conflict (studio_id, instructor_id, month) do update
       set classes_at_notify = excluded.classes_at_notify,
           notified_at = coalesce(roster_confirmations.notified_at, excluded.notified_at);

    if v_user is null then
      v_unreachable := v_unreachable || jsonb_build_object('instructor_id', r.instructor_id, 'name', r.display_name, 'classes', r.n);
      continue;
    end if;

    if queue_shift_notice(p_studio_id, v_user, v_template,
         jsonb_build_object(
           'instructor_name', r.display_name,
           'studio_name', v_name,
           'month', v_facts ->> 'label',
           'count', r.n,
           'plural', case when r.n = 1 then '' else 'es' end,
           'roster', r.lines,
           'roster_html', r.lines_html,
           'hours', v_hours,
           'instructor_id', r.instructor_id,
           'month_ym', to_char(v_month, 'YYYY-MM'),
           'href', 'https://' || v_slug || '.'
                   || coalesce(notification_setting('member_app_domain'), 'studiior.app')
                   || '/instructor/month?m=' || to_char(v_month, 'YYYY-MM')),
         -- One roster per month at publish, ever. A class added later is told
         -- about on its own; a deliberate re-send uses resend_month_roster.
         'month_roster:' || r.instructor_id || ':' || v_month) is not null
    then
      n_notified := n_notified + 1;
    end if;
  end loop;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (p_studio_id, auth.uid(), 'month.published', 'studios', p_studio_id,
          jsonb_build_object('month', v_month,
                             'classes', (v_facts ->> 'classes')::int,
                             'open_shifts', (v_facts ->> 'open_shifts')::int,
                             'notified', n_notified,
                             'unreachable', v_unreachable));

  return month_publication_facts(p_studio_id, v_month)
         || jsonb_build_object('ok', true, 'already_published', false,
                               'notified', n_notified, 'unreachable', v_unreachable);
end $$;
revoke execute on function publish_month(uuid, date) from public, anon;
grant  execute on function publish_month(uuid, date) to authenticated, service_role;

-- =============================================================================
-- resend_month_roster — the Publish-page "Send this month's schedule" button.
-- Manager-up; published months only; one email per instructor with a login and a
-- class, keyed per send so it is NOT swallowed; names the no-login instructors.
-- =============================================================================
create or replace function resend_month_roster(p_studio_id uuid, p_month date)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_month date; v_tz text; v_name text; v_slug text; v_conf boolean; v_hours int;
  v_template text; r record; v_user uuid; n_sent int := 0;
  v_no_login jsonb := '[]'::jsonb; v_epoch text;
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers send the schedule' using errcode = 'PT403';
  end if;
  select s.timezone, s.name, s.slug into v_tz, v_name, v_slug from studios s where s.id = p_studio_id;
  if v_tz is null then raise exception 'no such studio' using errcode = 'PT404'; end if;
  v_month := date_trunc('month', p_month)::date;
  if not month_published(p_studio_id, (v_month::timestamp) at time zone v_tz) then
    raise exception 'that month is not published yet' using errcode = 'PT409';
  end if;

  select coalesce(assignment_confirmations, false), coalesce(cover_escalation_hours, 4)
    into v_conf, v_hours from studio_settings where studio_id = p_studio_id;
  v_template := case when v_conf then 'month_roster' else 'month_roster_plain' end;
  -- Per-send key at microsecond precision, so the same month can go out again
  -- (the publish-time send stays keyed once-per-month) and two presses never
  -- collide on the dedupe key.
  v_epoch := to_char(clock_timestamp(), 'YYYYMMDDHH24MISSUS');

  for r in select * from month_roster_lines(p_studio_id, v_month)
  loop
    v_user := instructor_user_id(r.instructor_id);
    if v_user is null then
      v_no_login := v_no_login || jsonb_build_object('instructor_id', r.instructor_id, 'name', r.display_name);
      continue;
    end if;
    if queue_shift_notice(p_studio_id, v_user, v_template,
         jsonb_build_object(
           'instructor_name', r.display_name,
           'studio_name', v_name,
           'month', to_char(v_month, 'FMMonth YYYY'),
           'count', r.n,
           'plural', case when r.n = 1 then '' else 'es' end,
           'roster', r.lines,
           'roster_html', r.lines_html,
           'hours', v_hours,
           'instructor_id', r.instructor_id,
           'month_ym', to_char(v_month, 'YYYY-MM'),
           'href', 'https://' || v_slug || '.'
                   || coalesce(notification_setting('member_app_domain'), 'studiior.app')
                   || '/instructor/month?m=' || to_char(v_month, 'YYYY-MM')),
         'month_roster_resend:' || r.instructor_id || ':' || v_month || ':' || v_epoch) is not null
    then n_sent := n_sent + 1; end if;
  end loop;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (p_studio_id, auth.uid(), 'month.roster_resent', 'studios', p_studio_id,
          jsonb_build_object('month', v_month, 'sent', n_sent, 'no_login', v_no_login));

  return jsonb_build_object('ok', true, 'sent', n_sent, 'no_login', v_no_login);
end $$;
revoke execute on function resend_month_roster(uuid, date) from public, anon;
grant  execute on function resend_month_roster(uuid, date) to authenticated, service_role;

-- =============================================================================
-- my_month_roster — add confirmations_on, so the portal hides the "confirm the
-- month" prompt when the switch is off (Decision 59). Re-issued VERBATIM from
-- 20260832140000 with v_conf read and one field added.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.my_month_roster(p_instructor_id uuid, p_month date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_studio uuid; v_tz text; v_month date; v_from timestamptz; v_to timestamptz;
  rc roster_confirmations%rowtype; v_rows jsonb; v_added int; v_fmt text; v_conf boolean;
begin
  select i.studio_id, s.timezone into v_studio, v_tz
    from instructors i join studios s on s.id = i.studio_id where i.id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  select coalesce(time_format, '24h'), coalesce(assignment_confirmations, false)
    into v_fmt, v_conf from studio_settings where studio_id = v_studio;
  v_fmt := coalesce(v_fmt, '24h');
  if not (coalesce(is_this_instructor(p_instructor_id), false) or coalesce(is_manager_up(v_studio), false)) then
    raise exception 'that is somebody else''s month' using errcode = 'PT403';
  end if;

  v_month := date_trunc('month', p_month)::date;
  v_from  := (v_month::timestamp) at time zone v_tz;
  v_to    := ((v_month + interval '1 month')::timestamp) at time zone v_tz;

  select * into rc from roster_confirmations
   where studio_id = v_studio and instructor_id = p_instructor_id and month = v_month;

  if not month_published(v_studio, v_from) then
    return jsonb_build_object(
      'month', v_month, 'label', to_char(v_month, 'FMMonth YYYY'),
      'state', 'draft', 'classes', '[]'::jsonb, 'count', 0,
      'confirmations_on', v_conf,
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
             (select g.tier::text from occurrence_guarantee_run(o.id) g) as tier,
             (select case when d.deadline_at is null then null
                          else fmt_clock(d.deadline_at, v_tz, v_fmt)
                               || ' ' || to_char(d.deadline_at at time zone v_tz, 'FMDy') end
                from flex_deadline_for_run(o.id) d) as flex_deadline_short,
             (select c.status::text from cover_requests c
               where c.occurrence_id = o.id and c.status in ('pending','accepted_pending','approved')
               order by c.requested_at desc limit 1) as cover_status,
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
    'confirmations_on', v_conf,
    'notified_at', rc.notified_at, 'confirmed_at', rc.confirmed_at,
    'added_since', v_added,
    'empty_hint', 'Nothing of yours in ' || to_char(v_month, 'FMMonth') || '. Classes you are given after publication appear here and you are emailed about each one.');
end $function$;

-- =============================================================================
-- notification_ics — attach the whole-month .ics to the plain version too.
-- Re-issued from 20260831970000 with month_roster_plain added to the first branch.
-- =============================================================================
create or replace function notification_ics(p_notification_id uuid)
returns text language plpgsql stable security definer set search_path = public as $$
declare n notifications%rowtype; v_occ uuid; v_ve text; v_method text;
        v_instr uuid; v_month text; v_events text; v_org text; v_att text;
begin
  select * into n from notifications where id = p_notification_id;
  if not found then return null; end if;

  if n.template_key in ('month_roster', 'month_roster_plain') then
    v_instr := nullif(n.payload ->> 'instructor_id', '')::uuid;
    v_month := nullif(n.payload ->> 'month_ym', '');
    if v_instr is null or v_month is null then return null; end if;
    v_events := instructor_month_vevents(n.studio_id, v_instr, to_date(v_month || '-01', 'YYYY-MM-DD'));
    if nullif(v_events, '') is null then return null; end if;
    return ics_calendar('PUBLISH', v_events);
  end if;

  v_occ := nullif(n.payload ->> 'occurrence_id', '')::uuid;
  if v_occ is null then return null; end if;

  select coalesce(nullif(s.contact_email, ''),
                  'notifications@' || notification_setting('from_domain'))
    into v_org from studios s where id = n.studio_id;

  if n.template_key in ('booking_confirmed', 'class_moved', 'class_cancelled',
                        'flex_booking_pending', 'flex_booking_not_confirmed') then
    select email into v_att from members where id = n.member_id;
    v_ve := ics_member_vevent(v_occ, n.member_id,
              (n.template_key in ('class_cancelled', 'flex_booking_not_confirmed')), v_att, v_org);
    v_method := case when n.template_key in ('class_cancelled', 'flex_booking_not_confirmed')
                     then 'CANCEL' else 'REQUEST' end;
  elsif n.template_key in ('instructor_assigned', 'booking_for_instructor') then
    select email into v_att from studio_staff
      where user_id = n.user_id and studio_id = n.studio_id limit 1;
    v_ve := ics_instructor_vevent(v_occ, false, v_att, v_org);
    v_method := 'REQUEST';
  else
    return null;
  end if;

  if v_ve is null then return null; end if;
  return ics_calendar(v_method, v_ve);
end $$;

-- Anon stays EXACTLY THIRTEEN.
do $$
declare v_n int;
begin
  select count(*) into v_n from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
   where nsp.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if v_n <> 13 then
    raise exception 'anon surface is %, expected exactly thirteen', v_n;
  end if;
end $$;
