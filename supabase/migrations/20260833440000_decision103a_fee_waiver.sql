-- Decision 103 amendment (a): waive the reservation fee for a member, show the
-- credit on checkout, and the email fixes.
--
-- A manager waives the fee for one member: while on, their free class books
-- straight away (app routes to the ordinary free book), any open free_reservation
-- _due is withdrawn (booking stays, no email), and nothing is charged. Switching
-- off restores the normal rule for NEW bookings only — the member's existing free
-- bookings are grandfathered (a booking-level flag) so they are never re-asked.
--
-- Email fixes: instructor_closure_notice renders each class as a card; template_
-- sample_context carries the closure tokens; the instructor digest heading reads
-- "Running"; free_booking_confirmed's text gets a space before the reservation line.
--
-- creates: staff_set_reservation_fee_waiver(uuid, boolean, text), closure_card_html(text, text)
-- re-issues: reserve_free_first(uuid), member_reservation_dues(uuid), sweep_free_reservation_dues(timestamptz), member_bootstrap(text), member_plan_overview(uuid), template_sample_context(uuid, text, text), close_studio(uuid, date, date, text, time without time zone, time without time zone, boolean, boolean, boolean, text, text, text, text, date, boolean), closure_preview(uuid, date, date, date, text, text, text), closure_instructor_test(uuid, text, text, date, date, date), instructor_digest_block(uuid, uuid, date)

-- ===========================================================================
-- 1. Schema. The member-level waiver + a booking-level grandfather flag.
-- ===========================================================================
alter table members
  add column if not exists reservation_fee_waived_at   timestamptz,
  add column if not exists reservation_fee_waived_by    uuid references auth.users(id),
  add column if not exists reservation_fee_waived_note  text;

alter table bookings
  add column if not exists reservation_fee_waived boolean not null default false;

-- ===========================================================================
-- 2. staff_set_reservation_fee_waiver — manager-up. On: set the member flag,
--    grandfather their open free bookings, withdraw any unsent due email. Off:
--    grandfather the open bookings (so switching off never re-asks them), clear
--    the member flag. Audited either way.
-- ===========================================================================
create or replace function staff_set_reservation_fee_waiver(p_member_id uuid, p_on boolean, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_member members%rowtype; v_withdrawn int := 0; v_marked int := 0; v_note text;
begin
  select * into v_member from members where id = p_member_id;
  if not found then raise exception 'no such member' using errcode = 'PT404'; end if;
  if not (coalesce(is_manager_up(v_member.studio_id), false) or is_service_context()) then
    raise exception 'only owners and managers can waive the reservation fee' using errcode = 'PT403';
  end if;
  v_note := nullif(btrim(coalesce(p_note, '')), '');

  -- Grandfather the member's open free-first bookings that have not paid a fee, so
  -- switching the waiver off never re-asks a booking they already hold free.
  update bookings b set reservation_fee_waived = true
   where b.member_id = p_member_id
     and b.payment_source = 'comp'
     and b.status in ('booked', 'pending_payment')
     and not b.reservation_fee_waived
     and exists (select 1 from guest_passes gp
                  where gp.guest_booking_id = b.id and gp.host_member_id is null)
     and not exists (select 1 from payments p
                      where p.booking_id = b.id and p.kind = 'reservation_fee'
                        and p.status in ('succeeded', 'partially_refunded'));
  get diagnostics v_marked = row_count;

  if coalesce(p_on, false) then
    update members
       set reservation_fee_waived_at = now(), reservation_fee_waived_by = auth.uid(),
           reservation_fee_waived_note = v_note, updated_at = now()
     where id = p_member_id;
    -- Withdraw any unsent due email (the booking stays; the notice disappears).
    with del as (
      delete from notifications
       where member_id = p_member_id and template_key = 'free_reservation_due'
         and status = 'scheduled'
       returning 1)
    select count(*) into v_withdrawn from del;
  else
    update members
       set reservation_fee_waived_at = null, reservation_fee_waived_by = null,
           reservation_fee_waived_note = null, updated_at = now()
     where id = p_member_id;
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (v_member.studio_id, auth.uid(),
          case when coalesce(p_on, false) then 'member.reservation_fee_waived'
               else 'member.reservation_fee_waiver_cleared' end,
          'members', p_member_id,
          jsonb_build_object('on', coalesce(p_on, false), 'note', v_note,
                             'withdrawn_dues', v_withdrawn, 'grandfathered', v_marked));
  return jsonb_build_object('ok', true, 'withdrawn_dues', v_withdrawn, 'grandfathered', v_marked);
end $$;
revoke all on function staff_set_reservation_fee_waiver(uuid, boolean, text) from public, anon;
grant execute on function staff_set_reservation_fee_waiver(uuid, boolean, text) to authenticated, service_role;

-- ===========================================================================
-- 9. closure_card_html — one class card (name + when) for the closure notice.
--    Pure; not anon.
-- ===========================================================================
create or replace function closure_card_html(p_name text, p_when text)
returns text language sql immutable as $$
  select '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:8px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:12px 16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">'
      || coalesce(p_name, '')
      || '</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">'
      || coalesce(p_when, '') || '</div></td></tr></table>';
$$;
revoke all on function closure_card_html(text, text) from public, anon;
grant execute on function closure_card_html(text, text) to authenticated, service_role;
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
             (select string_agg(closure_card_html(o2.name,
                       to_char(o2.starts_at at time zone v_tz, 'FMDy FMDD FMMon') || ', '
                       || fmt_clock(o2.starts_at, v_tz, v_fmt)), '' order by o2.starts_at)
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
    (select string_agg(closure_card_html(o2.name, to_char(o2.starts_at at time zone v_tz, 'FMDy FMDD FMMon') || ', '
              || fmt_clock(o2.starts_at, v_tz, v_fmt)), '' order by o2.starts_at)
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
    (select string_agg(closure_card_html(o2.name, to_char(o2.starts_at at time zone v_tz, 'FMDy FMDD FMMon') || ', '
              || fmt_clock(o2.starts_at, v_tz, v_fmt)), '' order by o2.starts_at)
       from class_occurrences o2 where o2.id = any(coalesce(v_occ_ids, '{}')) and o2.instructor_id = o.instructor_id) as list_html
    into vi
    from class_occurrences o
   where o.id = any(coalesce(v_occ_ids, '{}')) and o.instructor_id is not null
     and instructor_user_id(o.instructor_id) is not null
   group by o.instructor_id
   order by count(*) desc
   limit 1;

  v_list_txt  := coalesce(vi.list_txt, 'Reformer Flow · (your cancelled classes)');
  v_list_html := coalesce(vi.list_html, closure_card_html('Reformer Flow', '(your cancelled classes)'));

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
-- 3. reserve_free_first — re-issued (from 20260833430000) with the waiver belt.
create or replace function reserve_free_first(p_occurrence_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare
  v_occ class_occurrences%rowtype; v_member members%rowtype; v_set studio_settings%rowtype;
  v_ser class_series%rowtype; v_cfg_tier guarantee_tier; v_elig jsonb; v_free int; v_booking uuid;
begin
  select * into v_occ from class_occurrences where id = p_occurrence_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;

  select * into v_member from members where studio_id = v_occ.studio_id and user_id = auth.uid();
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_authorised'); end if;

  -- Decision 103a: a waived member never needs the fee path; the app routes them
  -- to the ordinary free book, and this is the belt if reached directly.
  if v_member.reservation_fee_waived_at is not null then
    return jsonb_build_object('ok', false, 'reason', 'fee_waived');
  end if;

  select * into v_set from studio_settings where studio_id = v_occ.studio_id;
  if coalesce(v_set.free_first_reservation_fee_cents, 0) <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_reservation_fee');
  end if;

  v_elig := free_first_eligibility(v_occ.studio_id, v_member.id);
  if not (v_elig ->> 'ok')::boolean then return v_elig; end if;

  if v_occ.status <> 'scheduled' then return jsonb_build_object('ok', false, 'reason', 'class_not_bookable'); end if;
  if v_occ.starts_at <= now() then return jsonb_build_object('ok', false, 'reason', 'class_in_past'); end if;
  if not month_published(v_occ.studio_id, v_occ.starts_at) then
    return jsonb_build_object('ok', false, 'reason', 'month_not_published'); end if;
  if studio_hides_unstaffed(v_occ.studio_id) and v_occ.staffing <> 'assigned' then
    return jsonb_build_object('ok', false, 'reason', 'not_staffed_yet'); end if;
  if v_occ.hidden_from_members then
    return jsonb_build_object('ok', false, 'reason', 'class_hidden'); end if;
  if v_occ.starts_at > now() + make_interval(days => coalesce(v_set.booking_window_days, 30)) then
    return jsonb_build_object('ok', false, 'reason', 'outside_booking_window'); end if;
  if v_occ.starts_at < now() + make_interval(mins => coalesce(v_set.booking_cutoff_minutes, 0)) then
    return jsonb_build_object('ok', false, 'reason', 'past_booking_cutoff'); end if;
  if v_occ.free_first_override = 'closed' then
    return jsonb_build_object('ok', false, 'reason', 'free_first_closed_here'); end if;
  if not coalesce(v_set.free_first_peak_allowed, true) and occurrence_is_peak(p_occurrence_id) then
    return jsonb_build_object('ok', false, 'reason', 'peak_not_allowed'); end if;

  if v_occ.series_id is not null then select * into v_ser from class_series where id = v_occ.series_id; end if;
  v_cfg_tier := coalesce(v_occ.guarantee_tier,
                         case when v_occ.flex then 'flex'::guarantee_tier end,
                         v_ser.guarantee_tier,
                         case when v_ser.flex then 'flex'::guarantee_tier end,
                         'core'::guarantee_tier);
  if coalesce(v_set.free_first_core_only, false) and v_cfg_tier <> 'core'
     and v_occ.free_first_override is distinct from 'open' then
    return jsonb_build_object('ok', false, 'reason', 'flex_not_allowed'); end if;
  if v_occ.series_id is not null and not coalesce(v_ser.free_first_allowed, true)
     and v_occ.free_first_override is distinct from 'open' then
    return jsonb_build_object('ok', false, 'reason', 'not_trial_class'); end if;
  if v_set.free_first_seats_per_class is not null
     and (select count(*) from bookings b
           where b.occurrence_id = p_occurrence_id and b.status = 'booked'
             and b.payment_source = 'comp'
             and exists (select 1 from guest_passes gp
                          where gp.guest_booking_id = b.id and gp.host_member_id is null))
         >= v_set.free_first_seats_per_class then
    return jsonb_build_object('ok', false, 'reason', 'free_seats_full'); end if;

  v_free := v_occ.capacity - occurrence_seats_taken(p_occurrence_id) - occurrence_seats_held(p_occurrence_id);
  if v_free < 1 then return jsonb_build_object('ok', false, 'reason', 'class_full'); end if;

  -- Hold the seat: a comp booking in pending_payment, no guest_passes yet. The
  -- AFTER-INSERT notification trigger sends nothing (status <> 'booked'), and the
  -- existing sweep_unpaid_dropins (status='pending_payment' and hold_until is null)
  -- frees it if the member abandons Xendit.
  insert into bookings (studio_id, occurrence_id, member_id, status, source,
                        payment_source, provisional, confirmed_at, booked_at)
  values (v_occ.studio_id, p_occurrence_id, v_member.id, 'pending_payment', 'member', 'comp',
          false, null, now())
  returning id into v_booking;
  update class_occurrences set booked_count = booked_count + 1 where id = p_occurrence_id;

  return jsonb_build_object('ok', true, 'booking_id', v_booking,
    'fee_cents', v_set.free_first_reservation_fee_cents);
end $$;
revoke execute on function reserve_free_first(uuid) from public, anon;
grant  execute on function reserve_free_first(uuid) to authenticated, service_role;

-- 5. member_reservation_dues — re-issued, excluding a waived member / booking.
create or replace function member_reservation_dues(p_studio_id uuid)
returns table(occurrence_id uuid, booking_id uuid, class_name text, starts_at timestamptz, fee_cents int)
language sql stable security definer set search_path = public as $$
  select o.id, b.id, o.name, o.starts_at, st.free_first_reservation_fee_cents
    from bookings b
    join members m             on m.id = b.member_id
    join class_occurrences o   on o.id = b.occurrence_id
    join studio_settings st    on st.studio_id = b.studio_id
    join studios s             on s.id = b.studio_id
   where m.user_id = auth.uid() and b.studio_id = p_studio_id
     and m.reservation_fee_waived_at is null
     and not b.reservation_fee_waived
     and b.status = 'booked' and b.payment_source = 'comp'
     and coalesce(st.free_first_reservation_fee_cents, 0) > 0
     and st.free_first_reservation_from is not null
     and (o.starts_at at time zone s.timezone)::date >= st.free_first_reservation_from
     and o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)) > now()
     and exists (select 1 from guest_passes gp
                  where gp.guest_booking_id = b.id and gp.host_member_id is null)
     and not exists (select 1 from payments p
                      where p.booking_id = b.id and p.kind = 'reservation_fee'
                        and p.status in ('succeeded','partially_refunded'))
   order by o.starts_at;
$$;
revoke execute on function member_reservation_dues(uuid) from public, anon;
grant  execute on function member_reservation_dues(uuid) to authenticated, service_role;

-- 6. sweep_free_reservation_dues — re-issued, skipping a waived member / booking.
create or replace function sweep_free_reservation_dues(p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record; v_asked int := 0; v_released int := 0; v_tz text; v_s studios%rowtype;
        v_deadline timestamptz; v_day text; v_fmt text; v_res cancel_result;
begin
  if not is_service_context() then
    raise exception 'the reservation-dues sweep runs as the backend, not as a user'
      using errcode = 'PT403';
  end if;

  for r in
    select b.id as booking_id, b.studio_id, b.member_id, o.id as occ_id, o.name as cname,
           o.starts_at, st.cancellation_cutoff_minutes, st.free_first_reservation_fee_cents,
           st.free_first_reservation_from
      from bookings b
      join class_occurrences o   on o.id = b.occurrence_id
      join studio_settings st    on st.studio_id = b.studio_id
      join members mb            on mb.id = b.member_id
     where b.status = 'booked' and b.payment_source = 'comp'
       and mb.reservation_fee_waived_at is null
       and not b.reservation_fee_waived
       and st.free_first_reservation_from is not null
       and coalesce(st.free_first_reservation_fee_cents, 0) > 0
       and exists (select 1 from guest_passes gp
                    where gp.guest_booking_id = b.id and gp.host_member_id is null)
       and not exists (select 1 from payments p
                        where p.booking_id = b.id and p.kind = 'reservation_fee'
                          and p.status in ('succeeded','partially_refunded'))
  loop
    select timezone into v_tz from studios where id = r.studio_id;
    v_fmt := coalesce((select time_format from studio_settings where studio_id = r.studio_id), '24h');
    -- Only classes on/after the applies-from date (studio-local).
    if (r.starts_at at time zone v_tz)::date < r.free_first_reservation_from then
      continue;
    end if;
    v_deadline := r.starts_at - make_interval(mins => coalesce(r.cancellation_cutoff_minutes, 0));
    v_day := to_char(r.starts_at at time zone v_tz, 'FMDay FMDD FMMonth');

    if p_now < v_deadline then
      -- Ask once. The cut-off (deadline) has not passed.
      if queue_notification(r.studio_id, r.member_id, 'free_reservation_due',
            jsonb_build_object(
              'class_name', r.cname, 'day', v_day,
              'time', fmt_clock(r.starts_at, v_tz, v_fmt),
              'fee', fmt_money(r.free_first_reservation_fee_cents,
                               (select currency from studios where id = r.studio_id)),
              'from_date', to_char(r.free_first_reservation_from, 'FMDD Mon'),
              'deadline', fmt_clock(v_deadline, v_tz, v_fmt) || ' on '
                          || to_char(v_deadline at time zone v_tz, 'FMDay FMDD FMMonth'),
              'pay_url', member_portal_url(r.studio_id, '/class/' || r.occ_id),
              'cancel_url', member_portal_url(r.studio_id, '/class/' || r.occ_id)),
            'free_reservation_due:' || r.booking_id) is not null then
        v_asked := v_asked + 1;
      end if;
    else
      -- The cut-off has passed. Release ONLY if we asked (a due email went out)
      -- and it was not paid. Bookings never asked (cut-off already past when the
      -- date was set) are left as they are.
      if exists (select 1 from notifications
                  where dedupe_key = 'free_reservation_due:' || r.booking_id) then
        -- On-time path: set free_cancel_until so cancel_booking does not mark it
        -- a late cancel. The free class stays available (a cancelled comp seat
        -- remains free-first eligible, Decision 30d).
        update bookings set free_cancel_until = p_now + interval '1 hour' where id = r.booking_id;
        v_res := cancel_booking(r.booking_id);
        perform queue_notification(r.studio_id, r.member_id, 'free_reservation_released',
          jsonb_build_object('class_name', r.cname, 'day', v_day,
                             'book_url', member_portal_url(r.studio_id, '/book')),
          'free_reservation_released:' || r.booking_id);
        v_released := v_released + 1;
      end if;
    end if;
  end loop;

  return jsonb_build_object('asked', v_asked, 'released', v_released);
end $$;
revoke execute on function sweep_free_reservation_dues(timestamptz) from public, anon, authenticated;
grant  execute on function sweep_free_reservation_dues(timestamptz) to service_role;

do $$
begin
  if not exists (select 1 from cron.job where jobname = 'studiior-free-reservation-dues') then
    perform cron.schedule('studiior-free-reservation-dues', '*/15 * * * *',
      $c$select sweep_free_reservation_dues()$c$);
  end if;
end $$;

-- 7. member_bootstrap — re-issued (+ fee_waived, reservation_credit_cents).
drop function if exists member_bootstrap(text);
create function public.member_bootstrap(p_slug text)
 returns table(member_id uuid, studio_id uuid, first_name text, last_name text, preferred_name text, avatar_path text, status member_status, current_streak integer, lifetime_visits integer, studio_name text, studio_timezone text, logo_url text, theme_preset theme_preset, accent_color text, checkin_opens_minutes_before integer, checkin_closes_minutes_after integer, cancellation_cutoff_minutes integer, booking_cutoff_minutes integer, waitlist_enabled boolean, billing_status platform_status, billing_locked boolean, open_offers integer, guest_passes_enabled boolean, has_payment_provider boolean, booking_window_days integer, how_to_buy text, studio_contact_email text, xendit_enabled boolean, time_format text, trial_used boolean, messages_enabled boolean, has_unread_studio_message boolean, desk_pay_available boolean, payee_notice_name text, has_phone boolean, country text, free_first_reservation_fee_cents integer, currency text, fee_waived boolean, reservation_credit_cents integer)
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
    st.payee_notice_name,
    (nullif(btrim(coalesce(m.phone, '')), '') is not null),
    s.country,
    coalesce(st.free_first_reservation_fee_cents, 0),
    s.currency,
    (m.reservation_fee_waived_at is not null),
    coalesce((select sum(mc.amount_cents - mc.used_cents)::int from member_credits mc
               where mc.studio_id = m.studio_id and mc.member_id = m.id and mc.voided_at is null), 0)
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

-- 8. member_plan_overview — re-issued (+ reservation_fee_waived).
drop function if exists member_plan_overview(uuid);
create function member_plan_overview(p_studio_id uuid)
returns table (
  id uuid, first_name text, last_name text, email text, status text,
  lifetime_visits int, last_visit_at timestamptz,
  health_band text, health_reason text, user_id uuid,
  membership_id uuid, current_plan_name text, plan_type text,
  membership_status text, expires_on date, credits_remaining int,
  had_free_class boolean, has_ever_paid boolean, plan_state text,
  complimentary boolean, free_stage text, has_unpaid_booking boolean,
  joined_on date, desk_pay_blocked boolean, reservation_credit_cents int,
  reservation_fee_waived boolean
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare v_tz text; v_today date;
  v_cutover constant timestamptz := '2026-11-09 00:00:00+00';
begin
  if not (is_desk_up(p_studio_id) or is_service_context()) then
    raise exception 'that is another studio''s members' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios s where s.id = p_studio_id;
  v_today := (now() at time zone v_tz)::date;

  return query
  with mem as (
    select m.id, m.first_name, m.last_name, m.email, m.status::text as status,
           m.lifetime_visits, m.last_visit_at,
           m.health_band::text as health_band, m.health_reason, m.user_id,
           m.joined_on, m.desk_pay_blocked_at, m.reservation_fee_waived_at
      from members m
     where m.studio_id = p_studio_id and m.status <> 'archived'
       and m.deleted_at is null
  ),
  live as (
    select distinct on (ms.member_id)
           ms.member_id, ms.id as membership_id, ms.status as ms_status,
           ms.expires_on, ms.credits_remaining, mp.name as plan_name, mp.type as plan_type,
           ms.complimentary,
           (ms.status in ('active','trialing','past_due','frozen')
            and (mp.type = 'recurring'
                 or coalesce(ms.credits_remaining,0) > 0)
            and (ms.expires_on is null or ms.expires_on >= v_today)) as usable
      from memberships ms
      join membership_plans mp on mp.id = ms.plan_id
     where ms.studio_id = p_studio_id and ms.status <> 'cancelled'
     order by ms.member_id,
              (ms.status in ('active','trialing','past_due','frozen')) desc,
              ms.expires_on desc nulls first, ms.created_at desc
  ),
  paid as (
    select distinct member_id from payments
     where studio_id = p_studio_id and status in ('succeeded','partially_refunded')
  ),
  freebie as (
    select distinct guest_member_id as member_id from guest_passes
     where studio_id = p_studio_id
  ),
  comp as (
    select b.member_id,
           bool_or(b.status = 'attended') as any_attended,
           bool_or(b.status = 'booked')   as any_booked,
           bool_or(b.status = 'no_show')  as any_no_show,
           bool_or(b.status = 'late_cancelled'
                   and b.cancelled_at >= v_cutover) as any_late_cancel,
           max(o.starts_at) filter (where b.status = 'no_show') as last_no_show_at
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
     where b.studio_id = p_studio_id
       and b.payment_source = 'comp'
       and b.status in ('booked','attended','no_show','late_cancelled')
     group by b.member_id
  ),
  unpaid as (
    select distinct b.member_id
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
     where b.studio_id = p_studio_id
       and b.payment_source = 'drop_in'
       and b.status in ('booked','pending_payment')
       and o.starts_at > now()
       and not exists (select 1 from payments p
                        where p.booking_id = b.id
                          and p.status in ('succeeded','partially_refunded'))
  ),
  rescred as (
    select member_id, sum(amount_cents - used_cents)::int as cents
      from member_credits
     where studio_id = p_studio_id and voided_at is null and amount_cents > used_cents
     group by member_id
  )
  select mem.id, mem.first_name, mem.last_name, mem.email, mem.status,
         mem.lifetime_visits, mem.last_visit_at, mem.health_band, mem.health_reason, mem.user_id,
         live.membership_id, live.plan_name, live.plan_type::text,
         live.ms_status::text, live.expires_on, live.credits_remaining,
         (freebie.member_id is not null) as had_free_class,
         (paid.member_id is not null) as has_ever_paid,
         case
           when coalesce(live.usable, false) then
             case when live.expires_on is not null
                       and live.expires_on <= v_today + 14 then 'expiring' else 'on_plan' end
           when paid.member_id is not null then 'expired'
           when freebie.member_id is not null then 'free_only'
           else 'none'
         end as plan_state,
         coalesce(live.complimentary, false) as complimentary,
         case
           when comp.any_attended then 'taken'
           when comp.any_booked   then 'booked'
           when comp.any_no_show
                and not exists (
                  select 1 from bookings b2
                  join class_occurrences o2 on o2.id = b2.occurrence_id
                  where b2.member_id = mem.id and b2.studio_id = p_studio_id
                    and b2.status not in ('cancelled','late_cancelled')
                    and o2.starts_at > comp.last_no_show_at
                ) then 'missed'
           when comp.any_late_cancel then 'late_cancel'
           else null
         end as free_stage,
         (unpaid.member_id is not null) as has_unpaid_booking,
         mem.joined_on,
         (mem.desk_pay_blocked_at is not null) as desk_pay_blocked,
         coalesce(rescred.cents, 0) as reservation_credit_cents,
         (mem.reservation_fee_waived_at is not null) as reservation_fee_waived
    from mem
    left join live    on live.member_id = mem.id
    left join paid    on paid.member_id = mem.id
    left join freebie on freebie.member_id = mem.id
    left join comp    on comp.member_id = mem.id
    left join unpaid  on unpaid.member_id = mem.id
    left join rescred on rescred.member_id = mem.id;
end $$;
revoke all on function member_plan_overview(uuid) from public, anon;
grant execute on function member_plan_overview(uuid) to authenticated, service_role;

-- 10. template_sample_context — re-issued (+ closure tokens; Running heading).
CREATE OR REPLACE FUNCTION public.template_sample_context(p_studio_id uuid, p_to_email text, p_first_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s studios%rowtype; st studio_settings%rowtype; v_tz text; v_fmt text;
  v_plan membership_plans%rowtype; o record; v_when text; v_offer_ends text;
  v_n3 text; v_n3line text; v_n3html text; v_links text;
  v_clist text; v_roster text; v_roster_html text; v_li text;
  v_fee text;
begin
  select * into s from studios where id = p_studio_id;
  select * into st from studio_settings where studio_id = p_studio_id;
  v_tz := s.timezone; v_fmt := coalesce(st.time_format, '24h');
  v_fee := fmt_money(coalesce(nullif(st.free_first_reservation_fee_cents, 0), 15000), s.currency);

  select o2.id, coalesce(ct.name, o2.name, 'a class') as cname, o2.starts_at,
         rm.name as room, split_part(coalesce(i.display_name, ''), ' ', 1) as instr
    into o
    from class_occurrences o2
    left join class_types ct on ct.id = o2.class_type_id
    left join rooms rm on rm.id = o2.room_id
    left join instructors i on i.id = o2.instructor_id
   where o2.studio_id = p_studio_id and o2.status = 'scheduled' and o2.starts_at > now()
   order by o2.starts_at limit 1;

  if st.intro_offer_plan_id is not null then
    select * into v_plan from membership_plans where id = st.intro_offer_plan_id;
  end if;
  if v_plan.id is null then
    select * into v_plan from membership_plans
     where studio_id = p_studio_id and status = 'active' order by sort_order limit 1;
  end if;

  v_when := case when o.starts_at is not null
    then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD Mon') || ' at ' || fmt_clock(o.starts_at, v_tz, v_fmt)
    else '' end;
  v_offer_ends := to_char((now() + interval '14 days') at time zone v_tz, 'FMDD Mon YYYY');

  with s3(nm, ts) as (
    values
      ('Reformer Flow', ((((now() at time zone v_tz)::date + 1) + time '07:00') at time zone v_tz)),
      ('Barre',         ((((now() at time zone v_tz)::date + 2) + time '18:00') at time zone v_tz)),
      ('Mat Pilates',   ((((now() at time zone v_tz)::date + 3) + time '09:00') at time zone v_tz))
  )
  select
    string_agg(to_char(ts at time zone v_tz, 'FMDy ') || fmt_clock(ts, v_tz, v_fmt) || ' ' || nm, '; ' order by ts),
    string_agg('<a href="' || member_portal_url(p_studio_id, '/book') || '">'
               || to_char(ts at time zone v_tz, 'FMDy ') || fmt_clock(ts, v_tz, v_fmt) || ' ' || nm || '</a>', ', ' order by ts),
    string_agg(to_char(ts at time zone v_tz, 'FMDay FMDD FMMon, ') || fmt_clock(ts, v_tz, v_fmt) || ' ' || nm, E'\n' order by ts),
    string_agg('<li>' || to_char(ts at time zone v_tz, 'FMDay FMDD FMMon, ') || fmt_clock(ts, v_tz, v_fmt) || ' ' || nm || '</li>', '' order by ts)
    into v_n3, v_links, v_roster, v_li
    from s3;
  v_clist := v_roster;
  v_roster_html := '<ul style="margin:0;padding-left:20px">' || v_li || '</ul>';
  v_n3line := ' Here are the next ones with space: ' || v_n3 || '.';
  v_n3html := '<p>Here are the next ones with space: ' || v_links || '.</p>';

  return jsonb_build_object(
    'to_email', p_to_email,
    'first_name', p_first_name,
    'studio_name', s.name,
    'class_name', coalesce(o.cname, 'a class'),
    'occurrence_id', o.id,
    'when', v_when,
    'where_line', case when nullif(o.room, '') is not null then ', in ' || o.room else '' end,
    'when_short', 'tomorrow',
    'when_time', case when o.starts_at is not null then fmt_clock(o.starts_at, v_tz, v_fmt) else '' end,
    'day', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMonth') else 'Monday 9 November' end,
    'time', case when o.starts_at is not null then fmt_clock(o.starts_at, v_tz, v_fmt) else '' end,
    'deadline_short', case when o.starts_at is not null then fmt_clock(o.starts_at - interval '12 hours', v_tz, v_fmt) || ' ' || to_char((o.starts_at - interval '12 hours') at time zone v_tz, 'FMDy') else 'the evening before' end,
    'cancel_deadline', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD Mon') else 'the day before' end,
    'manage_link', member_portal_url(p_studio_id, '/class/' || coalesce(o.id::text, '')),
    'book_url', member_portal_url(p_studio_id, '/book'),
    'schedule_url', member_portal_url(p_studio_id, '/book'),
    'offer_plan_name', coalesce(v_plan.name, 'a membership'),
    'offer_detail', coalesce(plan_card_detail(v_plan.id), ''),
    'offer_price', case when v_plan.id is not null then fmt_money(v_plan.price_cents, v_plan.currency) else '' end,
    'offer_ends', v_offer_ends,
    'buy_url', case when v_plan.id is not null then member_portal_url(p_studio_id, '/buy/' || v_plan.id::text) else member_portal_url(p_studio_id, '/account/plan') end,
    'plan_name', coalesce(v_plan.name, 'your plan'),
    'credits', '3', 'credits_left', '3',
    'expires_on', v_offer_ends, 'ends_on', v_offer_ends,
    'renew_url', case when v_plan.id is not null then member_portal_url(p_studio_id, '/buy/' || v_plan.id::text) else member_portal_url(p_studio_id, '/account/plan') end,
    'last_class', coalesce(o.cname, 'your class'),
    'last_class_date', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDD Mon') else '' end,
    'instructor_first', coalesce(nullif(o.instr, ''), 'your instructor'),
    'instructor_first_name', coalesce(nullif(o.instr, ''), 'your instructor'),
    'days_since', '10',
    'product', 'Grip socks', 'quantity', '1')
  || jsonb_build_object(
    'instructor_name', p_first_name,
    'href', instructor_portal_url(p_studio_id, '/instructor/schedule'),
    'schedule_link', instructor_portal_url(p_studio_id, '/instructor/schedule'),
    'booked_line', '3 booked',
    'count', '3',
    'plural', 's',
    'month', to_char(now() at time zone v_tz, 'FMMonth'),
    'period', 'this period',
    'due_on', to_char((now() + interval '3 days') at time zone v_tz, 'FMDay FMDD Mon'),
    'due_wording', 'soon',
    'hours', '12',
    'amount', fmt_money(90000, s.currency),
    'old_when', case when o.starts_at is not null
                     then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMonth YYYY, ') || fmt_clock(o.starts_at, v_tz, v_fmt)
                     else 'Monday 9 November, 07:00' end,
    'cancelled_count', '1',
    'booked', '4',
    'capacity', '8',
    'reason', 'cancelled by the studio',
    'claim_url', member_portal_url(p_studio_id, '/class/' || coalesce(o.id::text, '')))
  || jsonb_build_object(
    'next_three', v_n3,
    'next_three_line', v_n3line,
    'next_three_html', v_n3html,
    'class_list', v_clist,
    'roster', v_roster,
    'roster_html', v_roster_html)
  || jsonb_build_object(
    'staff_first_name', p_first_name,
    'member_name', coalesce(nullif(p_first_name, ''), 'A member'),
    'message', 'Hi, could I move my Saturday class to Sunday?',
    'message_html', 'Hi, could I move my Saturday class to Sunday?',
    'messages_url', member_portal_url(p_studio_id, '/messages'),
    'reply_url', coalesce(nullif(notification_setting('staff_app_origin'), ''), 'https://app.studiior.com') || '/messages')
  || jsonb_build_object(
    'old_class_name', coalesce(o.cname, 'a class'),
    'bookings_url', member_portal_url(p_studio_id, '/'))
  || jsonb_build_object(
    'class_name', coalesce(o.cname, 'a class'),
    'day', to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMonth'),
    'n_more', 2,
    'cutoff_time', coalesce(v_when, 'the cut-off'),
    'class_list_core', '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:12px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-size:16px;font-weight:600;color:#14170E">' || coalesce(o.cname, 'a class') || '</div><div style="font-size:14px;color:#57534E;margin-top:4px">' || coalesce(v_when, 'soon') || '</div><div style="font-size:13px;color:#78716C;margin-top:2px">3 in already · 4 spots left</div><table role="presentation" style="margin-top:12px"><tr><td style="border-radius:6px;background:{accent}"><a href="#" style="display:inline-block;padding:10px 20px;color:{accent_on};text-decoration:none;font-weight:600;border-radius:6px">Move me to this class</a></td></tr></table></td></tr></table>',
    'class_list_core_text', '- ' || coalesce(o.cname, 'a class') || ' · ' || coalesce(v_when, 'soon') || ' (3 in already, 4 spots left)')
  || jsonb_build_object(
    'n_running', 2, 'n_cancelled', 1,
    'pay_line', 'You''re paid on who''s checked in.',
    'going_ahead', '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:12px 0;border-collapse:collapse"><tr><td colspan="3" style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;color:#14170E;padding:0 0 6px 0">Running</td></tr><tr><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Time</th><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Class</th><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Booked</th></tr><tr><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">' || fmt_clock(((now() at time zone v_tz)::date + time '07:00') at time zone v_tz, v_tz, v_fmt) || '</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">Reformer Flow</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">4 of 6</td></tr><tr><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">' || fmt_clock(((now() at time zone v_tz)::date + time '18:00') at time zone v_tz, v_tz, v_fmt) || '</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">Barre</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">5 of 8</td></tr></table>',
    'going_ahead_text', 'Running' || E'\n  ' || fmt_clock(((now() at time zone v_tz)::date + time '07:00') at time zone v_tz, v_tz, v_fmt) || '  Reformer Flow  4 of 6' || E'\n  ' || fmt_clock(((now() at time zone v_tz)::date + time '18:00') at time zone v_tz, v_tz, v_fmt) || '  Barre  5 of 8',
    'cancelled', '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:12px 0;border-collapse:collapse"><tr><td colspan="3" style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;color:#14170E;padding:0 0 6px 0">Cancelled, not enough bookings</td></tr><tr><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Time</th><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Class</th><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Booked</th></tr><tr><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">' || fmt_clock(((now() at time zone v_tz)::date + time '09:00') at time zone v_tz, v_tz, v_fmt) || '</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">Mat Pilates</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">1 of 3 needed</td></tr></table>',
    'cancelled_text', 'Cancelled, not enough bookings' || E'\n  ' || fmt_clock(((now() at time zone v_tz)::date + time '09:00') at time zone v_tz, v_tz, v_fmt) || '  Mat Pilates  1 of 3 needed')
  -- Decision 103: reservation tokens.
  || jsonb_build_object(
    'fee', v_fee,
    'from_date', to_char(now() at time zone v_tz, 'FMDD Mon'),
    'deadline', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD Mon') else 'the day before' end,
    'pay_url', member_portal_url(p_studio_id, '/class/' || coalesce(o.id::text, '')),
    'cancel_url', member_portal_url(p_studio_id, '/class/' || coalesce(o.id::text, '')),
    'reservation_line', '',
    'reservation_html', '')
  -- Decision 103a: closure sample tokens so the Templates preview fills them.
  || jsonb_build_object(
    'from', to_char(now() at time zone v_tz, 'FMDy FMDD FMMon'),
    'to', to_char((now() + interval '2 days') at time zone v_tz, 'FMDy FMDD FMMon'),
    'resume_date', to_char((now() + interval '7 days') at time zone v_tz, 'FMDay FMDD FMMonth YYYY'),
    'notice', 'We are closed for renovations.',
    'class_list_html', closure_card_html('Reformer Flow', v_clist),
    'schedule_url', instructor_portal_url(p_studio_id, '/instructor/schedule'));
end $function$;
-- 13. instructor_digest_block — re-issued, table heading reads "Running".
create or replace function instructor_digest_block(
  p_studio_id uuid, p_instructor_id uuid, p_date date
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tz text; v_fmt text;
  th text := 'style="text-align:left;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;font-size:12px;font-weight:600;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4"';
  td text := 'style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4"';
  v_run_rows text; v_run_text text; v_can_rows text; v_can_text text;
  v_n_run int; v_n_can int; v_go_html text; v_go_text text; v_ca_html text; v_ca_text text;
begin
  select timezone into v_tz from studios where id = p_studio_id;
  v_fmt := coalesce((select time_format from studio_settings where studio_id = p_studio_id), '24h');

  -- Going ahead: the instructor's committed, still-scheduled classes that day.
  select count(*),
         string_agg('<tr><td ' || td || '>' || fmt_clock(o.starts_at, v_tz, v_fmt)
                    || '</td><td ' || td || '>' || coalesce(o.name, ct.name, 'a class')
                    || '</td><td ' || td || '>' || o.booked_at_cutoff || ' of ' || o.capacity
                    || '</td></tr>', '' order by o.starts_at),
         string_agg('  ' || fmt_clock(o.starts_at, v_tz, v_fmt) || '  '
                    || coalesce(o.name, ct.name, 'a class') || '  '
                    || o.booked_at_cutoff || ' of ' || o.capacity, E'\n' order by o.starts_at)
    into v_n_run, v_run_rows, v_run_text
    from class_occurrences o
    left join class_types ct on ct.id = o.class_type_id
   where o.studio_id = p_studio_id and o.instructor_id = p_instructor_id
     and (o.starts_at at time zone v_tz)::date = p_date
     and o.status = 'scheduled' and o.committed_at is not null;

  -- Cancelled for want of bookings: unmet_minimum cancellations that day. The
  -- minimum comes from the occurrence's own guarantee.
  select count(*),
         string_agg('<tr><td ' || td || '>' || fmt_clock(o.starts_at, v_tz, v_fmt)
                    || '</td><td ' || td || '>' || coalesce(o.name, ct.name, 'a class')
                    || '</td><td ' || td || '>' || o.booked_at_cutoff || ' of '
                    || coalesce(g.minimum, 0) || ' needed'
                    || '</td></tr>', '' order by o.starts_at),
         string_agg('  ' || fmt_clock(o.starts_at, v_tz, v_fmt) || '  '
                    || coalesce(o.name, ct.name, 'a class') || '  '
                    || o.booked_at_cutoff || ' of '
                    || coalesce(g.minimum, 0) || ' needed', E'\n' order by o.starts_at)
    into v_n_can, v_can_rows, v_can_text
    from class_occurrences o
    left join class_types ct on ct.id = o.class_type_id
    cross join lateral occurrence_guarantee_run(o.id) g
   where o.studio_id = p_studio_id and o.instructor_id = p_instructor_id
     and (o.starts_at at time zone v_tz)::date = p_date
     and o.status = 'cancelled' and o.cancellation_cause = 'unmet_minimum';

  v_n_run := coalesce(v_n_run, 0); v_n_can := coalesce(v_n_can, 0);

  if v_n_run > 0 then
    v_go_html := '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:12px 0;border-collapse:collapse">'
      || '<tr><td colspan="3" style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;color:#14170E;padding:0 0 6px 0">Running</td></tr>'
      || '<tr><th ' || th || '>Time</th><th ' || th || '>Class</th><th ' || th || '>Booked</th></tr>'
      || v_run_rows || '</table>';
    v_go_text := 'Running' || E'\n' || v_run_text;
  else
    v_go_html := '<p style="margin:12px 0">Nothing running.</p>';
    v_go_text := 'Nothing running.';
  end if;

  if v_n_can > 0 then
    v_ca_html := '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:12px 0;border-collapse:collapse">'
      || '<tr><td colspan="3" style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;color:#14170E;padding:0 0 6px 0">Cancelled, not enough bookings</td></tr>'
      || '<tr><th ' || th || '>Time</th><th ' || th || '>Class</th><th ' || th || '>Booked</th></tr>'
      || v_can_rows || '</table>';
    v_ca_text := 'Cancelled, not enough bookings' || E'\n' || v_can_text;
  else
    v_ca_html := '<p style="margin:12px 0">Nothing cancelled.</p>';
    v_ca_text := 'Nothing cancelled.';
  end if;

  return jsonb_build_object(
    'n_running', v_n_run, 'n_cancelled', v_n_can,
    'day', to_char(p_date, 'FMDay FMDD FMMonth'),
    'going_ahead', v_go_html, 'going_ahead_text', v_go_text,
    'cancelled', v_ca_html, 'cancelled_text', v_ca_text);
end $$;
revoke execute on function instructor_digest_block(uuid, uuid, date) from public, anon, authenticated;
grant  execute on function instructor_digest_block(uuid, uuid, date) to service_role;
-- ===========================================================================
-- 11. instructor_closure_notice — render each class as a card (no <ul> wrapper;
--     class_list_html is now self-contained card tables). Platform default only;
--     a studio override is untouched.
-- ===========================================================================
update notification_templates
   set html_body = replace(html_body, '<ul>{class_list_html}</ul>', '{class_list_html}')
 where key = 'instructor_closure_notice';

-- ===========================================================================
-- 14. free_booking_confirmed — a space before {reservation_line} in the text body.
-- ===========================================================================
update notification_templates
   set text_body = replace(text_body, 'the free class is used.{reservation_line}',
                                       'the free class is used. {reservation_line}')
 where key = 'free_booking_confirmed';

-- ===========================================================================
-- Anon surface — EXACTLY THIRTEEN (nothing added here is anon).
-- ===========================================================================
do $$
declare n int;
begin
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'expect_%'
     and p.proname not in ('login','sig','psig');
  if n <> 13 then
    raise exception 'anon surface drifted: expected 13, got %', n;
  end if;
end $$;
