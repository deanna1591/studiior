-- =============================================================================
-- Decision 77 amendment (3 Nov 2026) — the closure notice shows what is on when
-- the studio is back, one digest per instructor instead of one email per class,
-- and both are rendered for the owner to see before anything is sent.
-- =============================================================================
-- (1) studio_closure_notice gains {upcoming_classes}/{upcoming_classes_text}:
--     the first eight scheduled, published, bookable classes on or after the
--     resume date, core first, as a card list; empty → a plain book link.
-- (2) close_studio with the all-member notice ON no longer emails the instructor
--     per class — each assigned instructor with a login gets ONE
--     instructor_closure_notice digest (dedupe closure:{closure}:{instructor}).
--     A new p_send_emails flag (default true); false cancels and sends nothing.
-- (3) closure_preview renders BOTH emails with real data for a sample member and
--     the most-affected instructor, plus the member/instructor counts. Manager-up,
--     no writes, not anon. closure_instructor_test is the instructor "send me a
--     test"; closure_notice_test (re-issued) carries the upcoming block too.
--
-- The new tokens are ALWAYS supplied by close_studio / closure_preview /
-- closure_notice_test, so render_email never sees them residual — render_email is
-- untouched. Both templates ride the per-email switch (queue_notification and
-- queue_shift_notice both honour studio_template_enabled). No new anon RPC —
-- THIRTEEN stays THIRTEEN.
--
-- creates:   closure_upcoming_block(uuid, date), closure_preview(uuid, date, date, date, text, text, text), closure_instructor_test(uuid, text, text, date, date, date)
-- re-issues: close_studio(uuid, date, date, text, time, time, boolean, boolean, boolean, text, text, text, text, date, boolean), closure_notice_test(uuid, text, text, text, date)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The instructor digest template, and the member template's new tail.
-- ---------------------------------------------------------------------------
insert into notification_templates (key, subject, text_body, html_body, note) values
  ('instructor_closure_notice',
   'Your classes {from} to {to} are cancelled ({studio_name})',
   E'Hi {first_name},\n\n{notice}\n\nThese classes of yours are cancelled:\n{class_list}\n\nYour classes from {resume_date} are unchanged. Pay for cancelled classes follows the studio''s rules; you''ll see it on your statement in My pay.\n\nCheck my schedule: {schedule_url}\n\n{studio_name}',
   '<p>Hi {first_name},</p><p>{notice}</p><p>These classes of yours are cancelled:</p><ul>{class_list_html}</ul><p>Your classes from {resume_date} are unchanged. Pay for cancelled classes follows the studio&rsquo;s rules; you&rsquo;ll see it on your statement in My pay.</p><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{schedule_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Check my schedule</a></td></tr></table><p>{studio_name}</p>',
   'Decision 77 amendment — one digest per assigned instructor with a login when a multi-day closure is announced with the notice on. Transactional; lists all of their cancelled classes in the window.')
on conflict (key) do nothing;

-- The member notice now ends with the upcoming block (cards + "See the full
-- schedule", or a plain book link when nothing is published past the resume
-- date). The book affordance moves out of the system block into here.
update notification_templates
   set text_body = E'{body}\n\n{system_text}\n\n{upcoming_classes_text}',
       html_body = '{body_html}{system_html}{upcoming_classes}'
 where key = 'studio_closure_notice';

-- ---------------------------------------------------------------------------
-- 2. closure_upcoming_block — the ONE definition of the member email's "what is
--    on when we are back" tail. Internal (service-role; the SECURITY DEFINER
--    callers reach it as the owner). The button carries {accent}/{accent_on};
--    render_email's accent pass fills them, exactly like a static template.
-- ---------------------------------------------------------------------------
create or replace function closure_upcoming_block(p_studio_id uuid, p_resume_date date)
returns table(html text, txt text)
language plpgsql stable security definer set search_path = public as $fn$
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
       and o.status = 'scheduled'
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
end $fn$;

revoke execute on function closure_upcoming_block(uuid, date) from public, anon, authenticated;
grant  execute on function closure_upcoming_block(uuid, date) to service_role;

-- ---------------------------------------------------------------------------
-- 3. close_studio — DROP the 14-arg and recreate with p_send_emails (adding a
--    trailing default is an overload, not a replace: 028's trap). The notice path
--    now queues ONE instructor digest and the member upcoming block; p_send_emails
--    false cancels silently.
-- ---------------------------------------------------------------------------
drop function if exists close_studio(uuid, date, date, text, time without time zone, time without time zone, boolean, boolean, boolean, text, text, text, text, date);

create function close_studio(
  p_studio_id uuid, p_starts_on date, p_ends_on date, p_reason text,
  p_starts_at_time time without time zone default null,
  p_ends_at_time time without time zone default null,
  p_confirm boolean default false, p_pays_instructors boolean default false,
  p_notice boolean default false, p_subject text default null,
  p_message text default null, p_message_html text default null,
  p_message_text text default null, p_resumes_on date default null,
  p_send_emails boolean default true
) returns jsonb
language plpgsql security definer set search_path to 'public' as $function$
declare
  v_impact jsonb; v_id uuid; r record; v jsonb; s studios%rowtype;
  v_cancelled int := 0; v_notified int := 0; v_notice_sent int := 0; v_instr_sent int := 0;
  v_tz text; v_fmt text; v_occ_ids uuid[];
  rm record; ir record; v_resume text; v_sys_text text; v_sys_html text;
  v_up_html text; v_up_txt text; v_suppress boolean;
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers close the studio' using errcode = 'PT403';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'say why — a closure with no reason is one nobody can explain to a member'
      using errcode = 'PT422';
  end if;
  if (p_starts_at_time is null) <> (p_ends_at_time is null) then
    raise exception 'a partial day needs both a start and an end time' using errcode = 'PT422';
  end if;
  if p_notice and p_ends_on = p_starts_on then
    raise exception 'A one-day closure tells the members who are booked, as usual — the notice to everyone is for a closure spanning more than a day.'
      using errcode = 'PT422';
  end if;
  if p_notice and (nullif(btrim(coalesce(p_subject, '')), '') is null
                   or nullif(btrim(coalesce(p_message, '')), '') is null) then
    raise exception 'The notice needs a subject and a message.' using errcode = 'PT422';
  end if;

  v_impact := closure_impact(p_studio_id, p_starts_on, p_ends_on, p_starts_at_time, p_ends_at_time);
  if not p_confirm then
    return v_impact || jsonb_build_object('ok', false, 'requires_confirmation', true);
  end if;

  select * into s from studios where id = p_studio_id;
  v_tz  := s.timezone;
  v_fmt := coalesce((select time_format from studio_settings where studio_id = p_studio_id), '24h');

  insert into studio_closures (studio_id, starts_on, ends_on, starts_at_time, ends_at_time,
                               reason, created_by, pays_instructors, subject, message, resumes_on)
  values (p_studio_id, p_starts_on, p_ends_on, p_starts_at_time, p_ends_at_time,
          btrim(p_reason), auth.uid(), coalesce(p_pays_instructors, false),
          case when p_notice then p_subject end, case when p_notice then p_message end,
          case when p_notice then p_resumes_on end)
  returning id into v_id;

  select array_agg((d ->> 'occurrence_id')::uuid)
    into v_occ_ids from jsonb_array_elements(v_impact -> 'detail') d;

  -- Suppress the per-class member emails when a notice goes instead, OR when the
  -- studio chose to send nothing ("Close without emails"). Credits, waitlist,
  -- calendar cancel, audit and status all happen exactly as today.
  v_suppress := p_notice or not coalesce(p_send_emails, true);
  if v_suppress then perform set_config('studiior.closure_notice', '1', true); end if;

  for r in select (d ->> 'occurrence_id')::uuid as id
             from jsonb_array_elements(v_impact -> 'detail') d
  loop
    v := cancel_occurrence(r.id, 'Studio closed: ' || btrim(p_reason), 'closure'::cancellation_cause);
    update class_occurrences set cancellation_pays = coalesce(p_pays_instructors, false) where id = r.id;
    v_cancelled := v_cancelled + 1;
    v_notified := v_notified + coalesce((v ->> 'notified')::int, 0);
  end loop;

  if v_suppress then perform set_config('studiior.closure_notice', '', true); end if;

  -- The notice to everyone (Decision 77 + amendment). Members get one email each
  -- with their cancelled list, the resume line and the upcoming classes; each
  -- assigned instructor with a login gets ONE digest of their cancelled classes.
  if p_notice and coalesce(p_send_emails, true) then
    v_resume := 'Classes resume ' || to_char(p_resumes_on, 'FMDay FMDD FMMonth YYYY') || '.';
    select html, txt into v_up_html, v_up_txt from closure_upcoming_block(p_studio_id, p_resumes_on);

    for rm in
      select m.id,
        (select string_agg(o.name || ' · '
                  || to_char(o.starts_at at time zone v_tz, 'FMDy FMDD FMMon ')
                  || fmt_clock(o.starts_at, v_tz, v_fmt), E'\n' order by o.starts_at)
           from bookings b join class_occurrences o on o.id = b.occurrence_id
          where b.member_id = m.id and o.id = any(v_occ_ids)
            and b.status in ('cancelled', 'late_cancelled')) as list_txt,
        (select string_agg('<li>' || o.name || ' · '
                  || to_char(o.starts_at at time zone v_tz, 'FMDy FMDD FMMon ')
                  || fmt_clock(o.starts_at, v_tz, v_fmt) || '</li>', '' order by o.starts_at)
           from bookings b join class_occurrences o on o.id = b.occurrence_id
          where b.member_id = m.id and o.id = any(v_occ_ids)
            and b.status in ('cancelled', 'late_cancelled')) as list_html
      from members m
     where m.studio_id = p_studio_id and m.deleted_at is null and nullif(m.email, '') is not null
    loop
      v_sys_text := case when rm.list_txt is not null
        then E'These classes of yours were cancelled:\n' || rm.list_txt
             || E'\n\nYour credit (or free first class) is back.\n\n'
        else '' end || v_resume;
      v_sys_html := case when rm.list_html is not null
        then '<p>These classes of yours were cancelled:</p><ul>' || rm.list_html
             || '</ul><p>Your credit (or free first class) is back.</p>'
        else '' end || '<p>' || v_resume || '</p>';
      if queue_notification(p_studio_id, rm.id, 'studio_closure_notice',
        jsonb_build_object('subject', p_subject, 'studio_name', s.name,
          'body', coalesce(p_message_text, p_message), 'body_html', coalesce(p_message_html, ''),
          'system_text', v_sys_text, 'system_html', v_sys_html,
          'upcoming_classes', v_up_html, 'upcoming_classes_text', v_up_txt),
        'studio_closure_notice:' || v_id || ':' || rm.id) is not null then
        v_notice_sent := v_notice_sent + 1;
      end if;
    end loop;
    update studio_closures set notice_sent_at = now() where id = v_id;

    for ir in
      select o.instructor_id,
             instructor_user_id(o.instructor_id) as uid,
             (select split_part(coalesce(display_name, ''), ' ', 1)
                from instructors where id = o.instructor_id) as first_name,
             (select string_agg(o2.name || ' · '
                       || to_char(o2.starts_at at time zone v_tz, 'FMDy FMDD FMMon ')
                       || fmt_clock(o2.starts_at, v_tz, v_fmt), E'\n' order by o2.starts_at)
                from class_occurrences o2
               where o2.id = any(v_occ_ids) and o2.instructor_id = o.instructor_id) as list_txt,
             (select string_agg('<li>' || o2.name || ' · '
                       || to_char(o2.starts_at at time zone v_tz, 'FMDy FMDD FMMon ')
                       || fmt_clock(o2.starts_at, v_tz, v_fmt) || '</li>', '' order by o2.starts_at)
                from class_occurrences o2
               where o2.id = any(v_occ_ids) and o2.instructor_id = o.instructor_id) as list_html
        from class_occurrences o
       where o.id = any(v_occ_ids) and o.instructor_id is not null
       group by o.instructor_id
    loop
      if ir.uid is not null and queue_shift_notice(p_studio_id, ir.uid, 'instructor_closure_notice',
          jsonb_build_object('first_name', coalesce(nullif(ir.first_name, ''), 'there'),
            'notice', coalesce(p_message_text, p_message),
            'from', to_char(p_starts_on, 'FMDy FMDD FMMon'),
            'to', to_char(p_ends_on, 'FMDy FMDD FMMon'),
            'resume_date', to_char(p_resumes_on, 'FMDay FMDD FMMonth YYYY'),
            'class_list', ir.list_txt, 'class_list_html', ir.list_html,
            'schedule_url', instructor_portal_url(p_studio_id, '/instructor/schedule')),
          'closure:' || v_id || ':' || ir.instructor_id) is not null then
        v_instr_sent := v_instr_sent + 1;
      end if;
    end loop;
  end if;

  return jsonb_build_object(
    'ok', true, 'closure_id', v_id, 'starts_on', p_starts_on, 'ends_on', p_ends_on,
    'classes_cancelled', v_cancelled, 'members_notified', v_notified,
    'notice', coalesce(p_notice, false), 'notice_sent', v_notice_sent,
    'instructors_notified', v_instr_sent,
    'pays_instructors', coalesce(p_pays_instructors, false));
end $function$;

revoke execute on function close_studio(uuid, date, date, text, time without time zone, time without time zone, boolean, boolean, boolean, text, text, text, text, date, boolean) from public, anon, authenticated;
grant  execute on function close_studio(uuid, date, date, text, time without time zone, time without time zone, boolean, boolean, boolean, text, text, text, text, date, boolean) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. closure_notice_test — the member "send me a test" now carries the upcoming
--    block; the book link leaves the sample system block.
-- ---------------------------------------------------------------------------
create or replace function closure_notice_test(p_studio_id uuid, p_subject text,
  p_body_html text, p_body_text text, p_resumes_on date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s studios%rowtype; v_email text; v_resume text; v_sys_text text; v_sys_html text;
        v_up_html text; v_up_txt text;
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers close the studio' using errcode = 'PT403';
  end if;
  select * into s from studios where id = p_studio_id;
  select pr.email into v_email
    from studio_staff ss join profiles pr on pr.id = ss.user_id
   where ss.user_id = auth.uid() and ss.studio_id = p_studio_id limit 1;
  if nullif(v_email, '') is null then
    raise exception 'no staff email to send the test to' using errcode = 'PT404';
  end if;

  v_resume := case when p_resumes_on is not null
    then 'Classes resume ' || to_char(p_resumes_on, 'FMDay FMDD FMMonth YYYY') || '.' else '' end;
  v_sys_text := v_resume;
  v_sys_html := case when v_resume <> '' then '<p>' || v_resume || '</p>' else '' end;
  select html, txt into v_up_html, v_up_txt from closure_upcoming_block(p_studio_id, p_resumes_on);

  insert into notifications
    (studio_id, recipient_type, member_id, template_key, channel, payload, dedupe_key, scheduled_for, status)
  values
    (p_studio_id, 'member', null, 'studio_closure_notice', 'email',
     jsonb_build_object('to_email', v_email, 'subject', '[Test] ' || p_subject, 'studio_name', s.name,
       'body', p_body_text, 'body_html', p_body_html, 'system_text', v_sys_text, 'system_html', v_sys_html,
       'upcoming_classes', v_up_html, 'upcoming_classes_text', v_up_txt),
     'closure_notice_test:' || p_studio_id || ':' || gen_random_uuid(), now(), 'scheduled');

  return jsonb_build_object('ok', true, 'sentence', 'Sent a test to ' || v_email || '.');
end $$;
revoke execute on function closure_notice_test(uuid, text, text, text, date) from public, anon;
grant  execute on function closure_notice_test(uuid, text, text, text, date) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. closure_instructor_test — the instructor "send me a test", one sample
--    instructor_closure_notice to the caller's own staff email.
-- ---------------------------------------------------------------------------
create or replace function closure_instructor_test(
  p_studio_id uuid, p_subject text, p_body_text text,
  p_starts_on date, p_ends_on date, p_resumes_on date default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare s studios%rowtype; v_uid uuid; v_email text; v_first text; v_tz text; v_fmt text;
        v_impact jsonb; v_occ_ids uuid[]; vi record; v_list_txt text; v_list_html text;
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers close the studio' using errcode = 'PT403';
  end if;
  select * into s from studios where id = p_studio_id; v_tz := s.timezone;
  v_fmt := coalesce((select time_format from studio_settings where studio_id = p_studio_id), '24h');
  select ss.user_id, pr.email, pr.full_name into v_uid, v_email, v_first
    from studio_staff ss join profiles pr on pr.id = ss.user_id
   where ss.user_id = auth.uid() and ss.studio_id = p_studio_id limit 1;
  if nullif(v_email, '') is null then
    raise exception 'no staff email to send the test to' using errcode = 'PT404';
  end if;

  v_impact := closure_impact(p_studio_id, p_starts_on, p_ends_on);
  select array_agg((d ->> 'occurrence_id')::uuid) into v_occ_ids
    from jsonb_array_elements(v_impact -> 'detail') d;

  select
    (select string_agg(o2.name || ' · ' || to_char(o2.starts_at at time zone v_tz, 'FMDy FMDD FMMon ')
              || fmt_clock(o2.starts_at, v_tz, v_fmt), E'\n' order by o2.starts_at)
       from class_occurrences o2 where o2.id = any(coalesce(v_occ_ids, '{}')) and o2.instructor_id = o.instructor_id) as list_txt,
    (select string_agg('<li>' || o2.name || ' · ' || to_char(o2.starts_at at time zone v_tz, 'FMDy FMDD FMMon ')
              || fmt_clock(o2.starts_at, v_tz, v_fmt) || '</li>', '' order by o2.starts_at)
       from class_occurrences o2 where o2.id = any(coalesce(v_occ_ids, '{}')) and o2.instructor_id = o.instructor_id) as list_html
    into vi
    from class_occurrences o
   where o.id = any(coalesce(v_occ_ids, '{}')) and o.instructor_id is not null
     and instructor_user_id(o.instructor_id) is not null
   group by o.instructor_id
   order by count(*) desc
   limit 1;

  v_list_txt  := coalesce(vi.list_txt, 'Reformer Flow · (your cancelled classes)');
  v_list_html := coalesce(vi.list_html, '<li>Reformer Flow · (your cancelled classes)</li>');

  insert into notifications
    (studio_id, recipient_type, user_id, template_key, channel, payload, dedupe_key, scheduled_for, status)
  values
    (p_studio_id, 'staff', v_uid, 'instructor_closure_notice', 'email',
     jsonb_build_object('to_email', v_email,
       'first_name', coalesce(nullif(split_part(coalesce(v_first, ''), ' ', 1), ''), 'there'),
       'studio_name', s.name, 'notice', p_body_text,
       'from', to_char(p_starts_on, 'FMDy FMDD FMMon'), 'to', to_char(p_ends_on, 'FMDy FMDD FMMon'),
       'resume_date', case when p_resumes_on is not null then to_char(p_resumes_on, 'FMDay FMDD FMMonth YYYY') else '' end,
       'class_list', v_list_txt, 'class_list_html', v_list_html,
       'schedule_url', instructor_portal_url(p_studio_id, '/instructor/schedule')),
     'closure_instructor_test:' || p_studio_id || ':' || gen_random_uuid(), now(), 'scheduled');

  return jsonb_build_object('ok', true, 'sentence', 'Sent a test to ' || v_email || '.');
end $$;
revoke execute on function closure_instructor_test(uuid, text, text, date, date, date) from public, anon;
grant  execute on function closure_instructor_test(uuid, text, text, date, date, date) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. closure_preview — render BOTH emails with real data for a sample member and
--    the most-affected instructor, plus the counts. Manager-up, no writes.
-- ---------------------------------------------------------------------------
create or replace function closure_preview(
  p_studio_id uuid, p_starts_on date, p_ends_on date, p_resumes_on date,
  p_subject text, p_body_html text, p_body_text text
) returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare
  s studios%rowtype; v_tz text; v_fmt text;
  v_impact jsonb; v_occ_ids uuid[]; v_members int; v_instructors int;
  v_up_html text; v_up_txt text; v_resume text;
  vm record; v_sys_text text; v_sys_html text; m_sub text; m_html text;
  vi record; i_sub text; i_html text;
  t notification_templates%rowtype; ov_sub text; ov_body text; ov_html text; pay jsonb;
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers close the studio' using errcode = 'PT403';
  end if;
  select * into s from studios where id = p_studio_id; v_tz := s.timezone;
  v_fmt := coalesce((select time_format from studio_settings where studio_id = p_studio_id), '24h');

  v_impact := closure_impact(p_studio_id, p_starts_on, p_ends_on);
  select array_agg((d ->> 'occurrence_id')::uuid) into v_occ_ids
    from jsonb_array_elements(v_impact -> 'detail') d;
  v_members := coalesce((v_impact ->> 'members_total')::int, 0);
  select count(distinct o.instructor_id)::int into v_instructors
    from class_occurrences o
   where o.id = any(coalesce(v_occ_ids, '{}')) and o.instructor_id is not null
     and instructor_user_id(o.instructor_id) is not null;

  v_resume := 'Classes resume ' || to_char(p_resumes_on, 'FMDay FMDD FMMonth YYYY') || '.';
  select html, txt into v_up_html, v_up_txt from closure_upcoming_block(p_studio_id, p_resumes_on);

  -- Sample member: one with a live booking in the window first (so the cancelled
  -- list is real); the list is built from CURRENT bookings — preview runs before
  -- the cancel, so the statuses are still live.
  select m.id, m.first_name,
    (select string_agg(o.name || ' · ' || to_char(o.starts_at at time zone v_tz, 'FMDy FMDD FMMon ')
              || fmt_clock(o.starts_at, v_tz, v_fmt), E'\n' order by o.starts_at)
       from bookings b join class_occurrences o on o.id = b.occurrence_id
      where b.member_id = m.id and o.id = any(coalesce(v_occ_ids, '{}'))
        and b.status in ('booked', 'attended', 'waitlisted', 'pending_payment')) as list_txt,
    (select string_agg('<li>' || o.name || ' · ' || to_char(o.starts_at at time zone v_tz, 'FMDy FMDD FMMon ')
              || fmt_clock(o.starts_at, v_tz, v_fmt) || '</li>', '' order by o.starts_at)
       from bookings b join class_occurrences o on o.id = b.occurrence_id
      where b.member_id = m.id and o.id = any(coalesce(v_occ_ids, '{}'))
        and b.status in ('booked', 'attended', 'waitlisted', 'pending_payment')) as list_html
    into vm
    from members m
   where m.studio_id = p_studio_id and m.deleted_at is null and nullif(m.email, '') is not null
   order by (exists(select 1 from bookings b join class_occurrences o on o.id = b.occurrence_id
                     where b.member_id = m.id and o.id = any(coalesce(v_occ_ids, '{}'))
                       and b.status in ('booked', 'attended', 'waitlisted', 'pending_payment'))) desc,
            m.created_at
   limit 1;

  if vm.id is not null then
    v_sys_text := case when vm.list_txt is not null
      then E'These classes of yours were cancelled:\n' || vm.list_txt || E'\n\nYour credit (or free first class) is back.\n\n'
      else '' end || v_resume;
    v_sys_html := case when vm.list_html is not null
      then '<p>These classes of yours were cancelled:</p><ul>' || vm.list_html || '</ul><p>Your credit (or free first class) is back.</p>'
      else '' end || '<p>' || v_resume || '</p>';
    pay := jsonb_build_object('subject', p_subject, 'studio_name', s.name,
      'body', p_body_text, 'body_html', coalesce(p_body_html, ''),
      'system_text', v_sys_text, 'system_html', v_sys_html,
      'upcoming_classes', v_up_html, 'upcoming_classes_text', v_up_txt);
    select * into t from notification_templates where key = 'studio_closure_notice';
    select o.subject, o.body, o.body_html into ov_sub, ov_body, ov_html
      from notification_templates_overrides o
     where o.studio_id = p_studio_id and o.key = 'studio_closure_notice';
    select re.subject, re.html_body into m_sub, m_html
      from render_email(p_studio_id, 'studio_closure_notice', 'member',
        coalesce(ov_sub, t.subject), coalesce(ov_body, t.text_body), coalesce(ov_html, t.html_body),
        pay, vm.first_name) re;
  end if;

  -- Sample instructor: the login instructor with the most cancelled classes.
  select o.instructor_id,
    (select split_part(coalesce(display_name, ''), ' ', 1) from instructors where id = o.instructor_id) as first_name,
    (select string_agg(o2.name || ' · ' || to_char(o2.starts_at at time zone v_tz, 'FMDy FMDD FMMon ')
              || fmt_clock(o2.starts_at, v_tz, v_fmt), E'\n' order by o2.starts_at)
       from class_occurrences o2 where o2.id = any(coalesce(v_occ_ids, '{}')) and o2.instructor_id = o.instructor_id) as list_txt,
    (select string_agg('<li>' || o2.name || ' · ' || to_char(o2.starts_at at time zone v_tz, 'FMDy FMDD FMMon ')
              || fmt_clock(o2.starts_at, v_tz, v_fmt) || '</li>', '' order by o2.starts_at)
       from class_occurrences o2 where o2.id = any(coalesce(v_occ_ids, '{}')) and o2.instructor_id = o.instructor_id) as list_html
    into vi
    from class_occurrences o
   where o.id = any(coalesce(v_occ_ids, '{}')) and o.instructor_id is not null
     and instructor_user_id(o.instructor_id) is not null
   group by o.instructor_id
   order by count(*) desc
   limit 1;

  if vi.instructor_id is not null then
    pay := jsonb_build_object('first_name', coalesce(nullif(vi.first_name, ''), 'there'),
      'studio_name', s.name, 'notice', p_body_text,
      'from', to_char(p_starts_on, 'FMDy FMDD FMMon'), 'to', to_char(p_ends_on, 'FMDy FMDD FMMon'),
      'resume_date', to_char(p_resumes_on, 'FMDay FMDD FMMonth YYYY'),
      'class_list', vi.list_txt, 'class_list_html', vi.list_html,
      'schedule_url', instructor_portal_url(p_studio_id, '/instructor/schedule'));
    select * into t from notification_templates where key = 'instructor_closure_notice';
    select o.subject, o.body, o.body_html into ov_sub, ov_body, ov_html
      from notification_templates_overrides o
     where o.studio_id = p_studio_id and o.key = 'instructor_closure_notice';
    select re.subject, re.html_body into i_sub, i_html
      from render_email(p_studio_id, 'instructor_closure_notice', 'staff',
        coalesce(ov_sub, t.subject), coalesce(ov_body, t.text_body), coalesce(ov_html, t.html_body),
        pay, vi.first_name) re;
  end if;

  return jsonb_build_object(
    'members', v_members, 'instructors', coalesce(v_instructors, 0),
    'member', case when vm.id is not null then jsonb_build_object('subject', m_sub, 'html', m_html) end,
    'instructor', case when vi.instructor_id is not null then jsonb_build_object('subject', i_sub, 'html', i_html) end);
end $fn$;
revoke execute on function closure_preview(uuid, date, date, date, text, text, text) from public, anon;
grant  execute on function closure_preview(uuid, date, date, date, text, text, text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. The anon surface stays EXACTLY THIRTEEN.
-- ---------------------------------------------------------------------------
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then
    raise exception 'anon surface drifted: expected 13, got %', n;
  end if;
end $$;
