-- =============================================================================
-- Decision 67(b) payee notice + Decision 77 closure clock-format fix (3 Nov 2026)
-- =============================================================================
-- (1) studio_settings.payee_notice_name: when a studio's online payments settle
--     to an account under a different legal name, the member checkout names it
--     before they leave for Xendit (app-side; this is just the column).
-- (2) The closure emails' cancelled class lines now read "Mon 9 Nov, 7:00 AM"
--     (day without a leading zero, a comma, the time via fmt_clock in the studio
--     clock) instead of "Mon 09 Nov 07:00". The three context functions are
--     re-issued from their newest (migration 20260833170000) definitions with
--     only that format changed; the {upcoming_classes} cards already use
--     fmt_clock + no leading zero, so closure_upcoming_block is unchanged.
--
-- No new function signatures, no new anon RPC — anon stays EXACTLY THIRTEEN.
--
-- re-issues: member_bootstrap(text), close_studio(uuid, date, date, text, time, time, boolean, boolean, boolean, text, text, text, text, date, boolean), closure_preview(uuid, date, date, date, text, text, text), closure_instructor_test(uuid, text, text, date, date, date)
-- =============================================================================

alter table studio_settings add column if not exists payee_notice_name text;

-- ---------------------------------------------------------------------------
-- member_bootstrap carries payee_notice_name — the checkout is a member page,
-- and a member cannot read studio_settings directly. Drop+recreate for the
-- RETURNS TABLE column; ACL re-asserted authenticated-only (not anon).
-- ---------------------------------------------------------------------------
drop function if exists member_bootstrap(text);
create function public.member_bootstrap(p_slug text)
 returns table(member_id uuid, studio_id uuid, first_name text, last_name text, preferred_name text, avatar_path text, status member_status, current_streak integer, lifetime_visits integer, studio_name text, studio_timezone text, logo_url text, theme_preset theme_preset, accent_color text, checkin_opens_minutes_before integer, checkin_closes_minutes_after integer, cancellation_cutoff_minutes integer, booking_cutoff_minutes integer, waitlist_enabled boolean, billing_status platform_status, billing_locked boolean, open_offers integer, guest_passes_enabled boolean, has_payment_provider boolean, booking_window_days integer, how_to_buy text, studio_contact_email text, xendit_enabled boolean, time_format text, trial_used boolean, messages_enabled boolean, has_unread_studio_message boolean, desk_pay_available boolean, payee_notice_name text)
 language sql
 stable security definer
 set search_path to 'public'
as $function$
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
    coalesce(st.time_format, '24h'),
    exists (select 1 from memberships ms
              join membership_plans mp on mp.id = ms.plan_id
             where ms.member_id = m.id and mp.type = 'trial'),
    coalesce(st.messages_enabled, false),
    coalesce(st.messages_enabled, false) and exists (
      select 1 from message_threads mt
        join thread_messages msg on msg.thread_id = mt.id
       where mt.member_id = m.id and msg.sender_kind = 'staff'
         and msg.created_at > coalesce(mt.last_member_read_at, 'epoch'::timestamptz)),
    not (
      (coalesce(st.desk_pay_mode, 'earned') = 'earned' and m.desk_pay_blocked_at is not null)
      or (coalesce(st.desk_pay_mode, 'earned') = 'first_visit_only'
          and exists (select 1 from bookings bdp
                       where bdp.member_id = m.id and bdp.studio_id = m.studio_id
                         and bdp.payment_source = 'drop_in' and bdp.status <> 'cancelled'))
    ),
    st.payee_notice_name
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

-- ---------------------------------------------------------------------------
-- The closure context functions, re-issued with the "Mon 9 Nov, 7:00 AM" format.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.close_studio(p_studio_id uuid, p_starts_on date, p_ends_on date, p_reason text, p_starts_at_time time without time zone DEFAULT NULL::time without time zone, p_ends_at_time time without time zone DEFAULT NULL::time without time zone, p_confirm boolean DEFAULT false, p_pays_instructors boolean DEFAULT false, p_notice boolean DEFAULT false, p_subject text DEFAULT NULL::text, p_message text DEFAULT NULL::text, p_message_html text DEFAULT NULL::text, p_message_text text DEFAULT NULL::text, p_resumes_on date DEFAULT NULL::date, p_send_emails boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
                  || to_char(o.starts_at at time zone v_tz, 'FMDy FMDD FMMon') || ', '
                  || fmt_clock(o.starts_at, v_tz, v_fmt), E'\n' order by o.starts_at)
           from bookings b join class_occurrences o on o.id = b.occurrence_id
          where b.member_id = m.id and o.id = any(v_occ_ids)
            and b.status in ('cancelled', 'late_cancelled')) as list_txt,
        (select string_agg('<li>' || o.name || ' · '
                  || to_char(o.starts_at at time zone v_tz, 'FMDy FMDD FMMon') || ', '
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
                       || to_char(o2.starts_at at time zone v_tz, 'FMDy FMDD FMMon') || ', '
                       || fmt_clock(o2.starts_at, v_tz, v_fmt), E'\n' order by o2.starts_at)
                from class_occurrences o2
               where o2.id = any(v_occ_ids) and o2.instructor_id = o.instructor_id) as list_txt,
             (select string_agg('<li>' || o2.name || ' · '
                       || to_char(o2.starts_at at time zone v_tz, 'FMDy FMDD FMMon') || ', '
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

CREATE OR REPLACE FUNCTION public.closure_preview(p_studio_id uuid, p_starts_on date, p_ends_on date, p_resumes_on date, p_subject text, p_body_html text, p_body_text text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    (select string_agg(o.name || ' · ' || to_char(o.starts_at at time zone v_tz, 'FMDy FMDD FMMon') || ', '
              || fmt_clock(o.starts_at, v_tz, v_fmt), E'\n' order by o.starts_at)
       from bookings b join class_occurrences o on o.id = b.occurrence_id
      where b.member_id = m.id and o.id = any(coalesce(v_occ_ids, '{}'))
        and b.status in ('booked', 'attended', 'waitlisted', 'pending_payment')) as list_txt,
    (select string_agg('<li>' || o.name || ' · ' || to_char(o.starts_at at time zone v_tz, 'FMDy FMDD FMMon') || ', '
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
    (select string_agg(o2.name || ' · ' || to_char(o2.starts_at at time zone v_tz, 'FMDy FMDD FMMon') || ', '
              || fmt_clock(o2.starts_at, v_tz, v_fmt), E'\n' order by o2.starts_at)
       from class_occurrences o2 where o2.id = any(coalesce(v_occ_ids, '{}')) and o2.instructor_id = o.instructor_id) as list_txt,
    (select string_agg('<li>' || o2.name || ' · ' || to_char(o2.starts_at at time zone v_tz, 'FMDy FMDD FMMon') || ', '
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
end $function$;

revoke execute on function closure_preview(uuid, date, date, date, text, text, text) from public, anon;
grant  execute on function closure_preview(uuid, date, date, date, text, text, text) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.closure_instructor_test(p_studio_id uuid, p_subject text, p_body_text text, p_starts_on date, p_ends_on date, p_resumes_on date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    (select string_agg(o2.name || ' · ' || to_char(o2.starts_at at time zone v_tz, 'FMDy FMDD FMMon') || ', '
              || fmt_clock(o2.starts_at, v_tz, v_fmt), E'\n' order by o2.starts_at)
       from class_occurrences o2 where o2.id = any(coalesce(v_occ_ids, '{}')) and o2.instructor_id = o.instructor_id) as list_txt,
    (select string_agg('<li>' || o2.name || ' · ' || to_char(o2.starts_at at time zone v_tz, 'FMDy FMDD FMMon') || ', '
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
end $function$;

revoke execute on function closure_instructor_test(uuid, text, text, date, date, date) from public, anon;
grant  execute on function closure_instructor_test(uuid, text, text, date, date, date) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- The anon surface stays EXACTLY THIRTEEN.
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
