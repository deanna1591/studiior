-- =============================================================================
-- 174  Decision 33 amendment — the emailed calendar was broken.
--   1. Empty attachment: Postgres base64-wraps at 76 chars; Resend delivered
--      0 bytes. Emit single-line base64.
--   2. No Gmail card: METHOD:PUBLISH with no ORGANIZER/ATTENDEE. Emailed
--      calendars become invitations (METHOD:REQUEST/CANCEL, ORGANIZER = studio
--      contact email, ATTENDEE = the recipient). Download routes + the webcal
--      feed stay METHOD:PUBLISH (they are files a person adds, not invitations).
--   3. Dates carried no year — {when}/{old_when}/{grace_ends} gain YYYY.
-- No new anon surface — stays EXACTLY ELEVEN.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. ics_vevent gains optional ORGANIZER/ATTENDEE (drop+recreate, 9 → 11 args).
--    concat_ws skips NULLs, so a null organizer/attendee omits the line — the
--    route/feed callers pass neither and stay exactly as they were (PUBLISH,
--    no ATTENDEE). The two lines are raw + folded, never ics_escape'd: RFC
--    params use ';' and ',', which the escaper would corrupt.
-- -----------------------------------------------------------------------------
drop function if exists ics_vevent(text,bigint,timestamptz,timestamptz,text,text,text,text,boolean);

create function ics_vevent(
  p_uid text, p_seq bigint, p_start timestamptz, p_end timestamptz,
  p_summary text, p_location text, p_description text, p_url text, p_cancelled boolean,
  p_organizer text default null, p_attendee text default null
) returns text
language sql stable as $$
  select concat_ws(E'\r\n',
    'BEGIN:VEVENT',
    ics_prop('UID', p_uid),
    'SEQUENCE:' || greatest(coalesce(p_seq, 0), 0),
    'DTSTAMP:' || ics_dt(now()),
    'DTSTART:' || ics_dt(p_start),
    'DTEND:'   || ics_dt(p_end),
    case when nullif(p_organizer, '') is not null
         then ics_fold('ORGANIZER:mailto:' || p_organizer) end,
    case when nullif(p_attendee, '')  is not null
         then ics_fold('ATTENDEE;RSVP=TRUE;PARTSTAT=NEEDS-ACTION:mailto:' || p_attendee) end,
    ics_prop('SUMMARY', p_summary),
    case when nullif(p_location, '')    is not null then ics_prop('LOCATION', p_location) end,
    case when nullif(p_description, '') is not null then ics_prop('DESCRIPTION', p_description) end,
    case when nullif(p_url, '')         is not null then ics_prop('URL', p_url) end,
    'STATUS:' || case when p_cancelled then 'CANCELLED' else 'CONFIRMED' end,
    'END:VEVENT')
$$;
revoke execute on function ics_vevent(text,bigint,timestamptz,timestamptz,text,text,text,text,boolean,text,text) from public, anon;
grant  execute on function ics_vevent(text,bigint,timestamptz,timestamptz,text,text,text,text,boolean,text,text) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 2. The assemblers gain optional attendee/organizer emails (drop+recreate).
--    Default null → the route/feed callers, which pass the old arity, get a
--    PUBLISH-shaped VEVENT with no ATTENDEE. notification_ics passes both.
-- -----------------------------------------------------------------------------
drop function if exists ics_member_vevent(uuid, uuid, boolean);

create function ics_member_vevent(
  p_occurrence_id uuid, p_member_id uuid, p_cancelled boolean,
  p_attendee_email text default null, p_organizer_email text default null
) returns text
language plpgsql stable security definer set search_path = public as $$
declare o class_occurrences%rowtype; s studios%rowtype;
        v_booking uuid; v_upd timestamptz; v_first text; v_link text; v_desc text;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then return null; end if;
  select id, updated_at into v_booking, v_upd from bookings
   where occurrence_id = p_occurrence_id and member_id = p_member_id
   order by created_at desc limit 1;
  if v_booking is null then return null; end if;

  v_upd := greatest(v_upd, o.updated_at);

  select * into s from studios where id = o.studio_id;
  select split_part(display_name, ' ', 1) into v_first
    from instructors where id = o.instructor_id;
  v_link := 'https://' || s.slug || '.'
            || coalesce(notification_setting('member_app_domain'), 'studiior.app')
            || '/class/' || o.id;
  v_desc := concat_ws(E'\n',
    case when v_first is not null then 'With ' || v_first end,
    'Manage this booking: ' || v_link);

  return ics_vevent(v_booking::text, extract(epoch from v_upd)::bigint,
    o.starts_at, o.ends_at, o.name, ics_studio_location(o.studio_id),
    v_desc, v_link, p_cancelled, p_organizer_email, p_attendee_email);
end $$;
revoke execute on function ics_member_vevent(uuid, uuid, boolean, text, text) from public, anon, authenticated;
grant  execute on function ics_member_vevent(uuid, uuid, boolean, text, text) to service_role;

drop function if exists ics_instructor_vevent(uuid, boolean);

create function ics_instructor_vevent(
  p_occurrence_id uuid, p_cancelled boolean,
  p_attendee_email text default null, p_organizer_email text default null
) returns text
language plpgsql stable security definer set search_path = public as $$
declare o class_occurrences%rowtype; v_desc text;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then return null; end if;
  v_desc := o.booked_count || ' booked'
            || case when o.capacity is not null then ' of ' || o.capacity else '' end;
  return ics_vevent(o.id::text, extract(epoch from o.updated_at)::bigint,
    o.starts_at, o.ends_at, o.name, ics_studio_location(o.studio_id),
    v_desc, null, p_cancelled, p_organizer_email, p_attendee_email);
end $$;
revoke execute on function ics_instructor_vevent(uuid, boolean, text, text) from public, anon, authenticated;
grant  execute on function ics_instructor_vevent(uuid, boolean, text, text) to service_role;

-- -----------------------------------------------------------------------------
-- 3. notification_ics: emailed calendars are invitations. Resolve the
--    recipient's email (member row / staff row) and the studio organizer, and
--    set METHOD:REQUEST (add/update) or METHOD:CANCEL. month_roster stays a
--    PUBLISH multi-event roster (informational, no single ATTENDEE).
--    Re-issued from Part B (162).
-- -----------------------------------------------------------------------------
create or replace function notification_ics(p_notification_id uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare n notifications%rowtype; v_occ uuid; v_ve text; v_method text;
        v_instr uuid; v_month text; v_events text; v_org text; v_att text;
begin
  select * into n from notifications where id = p_notification_id;
  if not found then return null; end if;

  if n.template_key = 'month_roster' then
    v_instr := nullif(n.payload ->> 'instructor_id', '')::uuid;
    v_month := nullif(n.payload ->> 'month_ym', '');
    if v_instr is null or v_month is null then return null; end if;
    v_events := instructor_month_vevents(n.studio_id, v_instr, to_date(v_month || '-01', 'YYYY-MM-DD'));
    if nullif(v_events, '') is null then return null; end if;
    return ics_calendar('PUBLISH', v_events);
  end if;

  v_occ := nullif(n.payload ->> 'occurrence_id', '')::uuid;
  if v_occ is null then return null; end if;

  -- ORGANIZER: the studio's contact email, else notifications@{from_domain}.
  select coalesce(nullif(s.contact_email, ''),
                  'notifications@' || notification_setting('from_domain'))
    into v_org from studios s where id = n.studio_id;

  if n.template_key in ('booking_confirmed', 'class_moved', 'class_cancelled') then
    select email into v_att from members where id = n.member_id;
    v_ve := ics_member_vevent(v_occ, n.member_id,
              (n.template_key = 'class_cancelled'), v_att, v_org);
    v_method := case when n.template_key = 'class_cancelled' then 'CANCEL' else 'REQUEST' end;
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
revoke execute on function notification_ics(uuid) from public, anon, authenticated;
grant  execute on function notification_ics(uuid) to service_role;

-- -----------------------------------------------------------------------------
-- 4. send_via_resend: single-line base64 (the empty-attachment fix), and derive
--    content_type method= from the calendar's own METHOD line (REQUEST as well
--    as CANCEL and PUBLISH). create or replace — signature and ACL unchanged.
-- -----------------------------------------------------------------------------
create or replace function send_via_resend(
  p_to text, p_from_name text, p_reply_to text,
  p_subject text, p_text text, p_html text,
  p_ics text default null
) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_key text; v_from text; v_body jsonb; v_method text;
begin
  v_key := notification_api_key();
  if v_key is null then
    raise exception 'RESEND_API_KEY is not configured'
      using errcode = 'PT503',
            hint = 'Set it in Vault as RESEND_API_KEY, or as app.resend_api_key '
                   'on the database. It is deliberately not in the repo.';
  end if;

  v_from := replace(p_from_name, '"', '') || ' <notifications@'
            || notification_setting('from_domain') || '>';

  v_body := jsonb_build_object('from', v_from, 'to', jsonb_build_array(p_to),
                               'subject', p_subject, 'text', p_text, 'html', p_html);
  if p_reply_to is not null then
    v_body := v_body || jsonb_build_object('reply_to', p_reply_to);
  end if;

  -- The .ics rides as a base64 attachment. Postgres base64-encodes with a
  -- newline every 76 chars (RFC 2045); Resend delivered that as 0 bytes, so
  -- strip the newlines to a single line. content_type method= mirrors the
  -- calendar's own METHOD line (REQUEST / CANCEL / PUBLISH), which drives the client.
  if nullif(p_ics, '') is not null then
    v_method := coalesce(substring(p_ics from 'METHOD:([A-Z]+)'), 'PUBLISH');
    v_body := v_body || jsonb_build_object('attachments', jsonb_build_array(
      jsonb_build_object(
        'filename', 'studiior.ics',
        'content', translate(encode(convert_to(p_ics, 'UTF8'), 'base64'), E'\n', ''),
        'content_type', 'text/calendar; charset=utf-8; method=' || v_method)));
  end if;

  return net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_key,
                                  'Content-Type', 'application/json'),
    body := v_body,
    timeout_milliseconds := 8000);
end $$;

revoke execute on function send_via_resend(text,text,text,text,text,text,text)
  from public, anon, authenticated;
grant  execute on function send_via_resend(text,text,text,text,text,text,text)
  to service_role;

do $$
begin
  if has_function_privilege('anon',
       'send_via_resend(text,text,text,text,text,text,text)'::regprocedure, 'execute')
     or has_function_privilege('authenticated',
       'send_via_resend(text,text,text,text,text,text,text)'::regprocedure, 'execute')
  then
    raise exception 'send_via_resend is reachable by a client role';
  end if;
end $$;

-- =============================================================================
-- 5. The year on the human date — {when}/{old_when}/{grace_ends} gain YYYY.
--    Each function below is its CURRENT definition re-issued verbatim with only
--    the to_char format literal changed ('FMDay FMDD FMMonth[, HH24:MI]' ->
--    '... YYYY[, ...]'). Named families only: the booking emails, the
--    cover/substitution family, the shift/assignment family, the platform grace
--    warning. class_reminder ("tomorrow") and the weekday-only brief text are
--    left alone; create_occurrence/move_occurrence already carried the year.
-- =============================================================================
-- BEGIN generated year re-issues
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
begin
  select * into b from bookings where id = p_booking_id;
  if not found or b.status <> 'booked' then return 0; end if;

  select * into o  from class_occurrences where id = b.occurrence_id;
  select * into m  from members            where id = b.member_id;
  select * into s  from studios            where id = b.studio_id;
  select * into st from studio_settings    where studio_id = b.studio_id;

  v_when  := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY, HH24:MI');
  v_where := coalesce((select ', in ' || r.name from rooms r where r.id = o.room_id), '');
  v_manage := 'https://' || s.slug || '.'
              || coalesce(notification_setting('member_app_domain'), 'studiior.app')
              || '/class/' || o.id;

  -- Decision 30: this booking is the free first class iff it is comp AND the
  -- shared ledger holds a host-null pass for it. One extra line, same template.
  v_is_free := b.payment_source = 'comp'
    and exists (select 1 from guest_passes gp
                 where gp.guest_booking_id = b.id and gp.host_member_id is null);
  v_ff_txt  := case when v_is_free then E'\n\nThis one''s on us — your first class is free.' else '' end;
  v_ff_html := case when v_is_free then '<p>This one''s on us — your first class is free.</p>' else '' end;

  if queue_notification(b.studio_id, b.member_id, 'booking_confirmed',
        jsonb_build_object('class_name', o.name, 'when', v_when, 'where_line', v_where,
                           'manage_link', v_manage,
                           'free_first_line', v_ff_txt, 'free_first_html', v_ff_html,
                           'booking_id', b.id, 'occurrence_id', o.id),
        'booking_confirmed:' || b.id) is not null then n := n + 1; end if;

  v_remind := o.starts_at - make_interval(hours => coalesce(st.reminder_hours_before, 12));
  if v_remind > now() then
    if queue_notification(b.studio_id, b.member_id, 'class_reminder',
          jsonb_build_object('class_name', o.name,
                             'when_short', 'tomorrow',
                             'when_time', to_char(o.starts_at at time zone s.timezone, 'HH24:MI'),
                             'where_line', v_where),
          'class_reminder:' || b.id, v_remind) is not null then n := n + 1; end if;
  end if;

  -- (The instructor per-booking email is gone — Decision 33 amendment: it is
  -- now the coalesced per-class alert, tg_instructor_booking_alert, gated on
  -- studio_settings.instructor_booking_alerts, not this per-booking path.)

  return n;
end $function$;

CREATE OR REPLACE FUNCTION public.queue_class_moved(p_occurrence_id uuid, p_old_starts_at timestamp with time zone)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  occ class_occurrences%rowtype; r record; v_tz text;
  v_when text; v_old text; v_where text; n int := 0;
begin
  select * into occ from class_occurrences where id = p_occurrence_id;
  select s.timezone into v_tz from studios s where s.id = occ.studio_id;

  v_when  := to_char(occ.starts_at   at time zone v_tz, 'FMDay FMDD FMMonth YYYY, HH24:MI');
  v_old   := to_char(p_old_starts_at at time zone v_tz, 'FMDay FMDD FMMonth YYYY, HH24:MI');
  v_where := coalesce((select ', in ' || rm.name from rooms rm where rm.id = occ.room_id), '');

  for r in
    select b.member_id from bookings b
     where b.occurrence_id = occ.id and b.status = 'booked'
  loop
    if queue_notification(occ.studio_id, r.member_id, 'class_moved',
         jsonb_build_object('class_name', occ.name, 'when', v_when,
                            'old_when', v_old, 'where_line', v_where,
                            'occurrence_id', occ.id),
         'class_moved:' || occ.id || ':' || r.member_id || ':'
           || to_char(occ.starts_at, 'YYYYMMDDHH24MI')) is not null then
      n := n + 1;
    end if;
  end loop;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION public.queue_occurrence_cancelled(p_occurrence_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o class_occurrences%rowtype; s studios%rowtype; r record; n int := 0; v_when text;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  select * into s from studios where id = o.studio_id;
  v_when := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY');

  for r in select b.member_id from bookings b
            where b.occurrence_id = p_occurrence_id
              and b.status in ('booked','waitlisted')
  loop
    if queue_notification(o.studio_id, r.member_id, 'class_cancelled',
          jsonb_build_object('class_name', o.name, 'when', v_when,
                             'occurrence_id', p_occurrence_id),
          'class_cancelled:' || p_occurrence_id || ':' || r.member_id) is not null
    then n := n + 1; end if;
  end loop;

  update notifications set status = 'cancelled'
   where status = 'scheduled'
     and dedupe_key like 'class_reminder:%'
     and payload ->> 'class_name' = o.name
     and member_id in (select member_id from bookings where occurrence_id = p_occurrence_id);

  return n;
end $function$;

CREATE OR REPLACE FUNCTION public.request_cover(p_occurrence_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o class_occurrences%rowtype; s studios%rowtype; st studio_settings%rowtype;
  v_instr uuid; v_req cover_requests%rowtype; v_hours numeric; v_urgent boolean;
  v_name text; n int; d record; v_offered int := 0;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  select * into s  from studios        where id = o.studio_id;
  select * into st from studio_settings where studio_id = o.studio_id;

  v_instr := auth_instructor_id(o.studio_id);
  if v_instr is null or v_instr is distinct from o.instructor_id then
    if not is_manager_up(o.studio_id) then
      raise exception 'only the instructor teaching this class may ask for cover'
        using errcode = 'PT403';
    end if;
    v_instr := o.instructor_id;
  end if;
  if v_instr is null then
    raise exception 'this class has nobody teaching it, so there is nothing to cover'
      using errcode = 'PT422';
  end if;
  if o.status <> 'scheduled' then
    raise exception 'this class is not running' using errcode = 'PT422';
  end if;
  if o.starts_at <= now() then
    raise exception 'this class has already started' using errcode = 'PT422';
  end if;

  insert into cover_requests (studio_id, occurrence_id, instructor_id, reason)
  values (o.studio_id, o.id, v_instr, nullif(btrim(p_reason), ''))
  on conflict (occurrence_id, instructor_id) where status = 'pending' do nothing
  returning * into v_req;

  if v_req.id is null then
    select * into v_req from cover_requests
     where occurrence_id = o.id and instructor_id = v_instr and status = 'pending';
    return jsonb_build_object('ok', true, 'already_open', true, 'request_id', v_req.id);
  end if;

  -- (c) If this class was CLAIMED (an approved shift application), record the
  -- handing-back on that application so reliability counts it. A no-op at an
  -- assigned-model studio, where there is no application.
  update shift_applications
     set withdrawn_at = now(),
         withdrawal_notice_hours = greatest(0, round(extract(epoch from o.starts_at - now()) / 3600))::int
   where occurrence_id = o.id and instructor_id = v_instr
     and status = 'approved' and withdrawn_at is null;

  select display_name into v_name from instructors where id = v_instr;
  v_hours  := extract(epoch from o.starts_at - now()) / 3600;
  v_urgent := v_hours <= coalesce(st.cover_escalation_hours, 4);

  n := queue_shift_notice_to_staff(
    o.studio_id,
    case when v_urgent then 'cover_urgent' else 'cover_requested' end,
    jsonb_build_object(
      'instructor_name', v_name, 'class_name', o.name,
      'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY, HH24:MI'),
      'hours_line', case when v_hours < 1 then round(v_hours * 60) || ' minutes'
                         else round(v_hours) || ' hour' || case when round(v_hours) = 1 then '' else 's' end end,
      'reason_line', case when nullif(btrim(coalesce(p_reason,'')), '') is null then ''
                          else 'They said: ' || btrim(p_reason) || E'\n\n' end,
      'booked_line', case when o.booked_count > 0
        then format('%s member%s booked.', o.booked_count, case when o.booked_count = 1 then ' is' else 's are' end)
        else 'Nobody has booked yet.' end,
      'cover_url', '/shifts/cover'),
    'cover_req:' || v_req.id || case when v_urgent then ':urgent' else '' end);

  if v_urgent then
    update cover_requests set escalated_at = now() where id = v_req.id;

    -- (a) Auto-accept is on and the class is inside the window: offer it to
    -- qualified, valid, available instructors with a login (not the requester,
    -- not anyone already teaching then). First to accept gets it — no cap check,
    -- an urgent cover is not hoarding a month.
    if coalesce(st.cover_auto_accept_enabled, false) then
      for d in
        select i.id, instructor_user_id(i.id) as user_id
          from instructors i
         where i.studio_id = o.studio_id and i.status = 'active' and i.id <> v_instr
           and instructor_qualified(i.id, o.class_type_id)
           and instructor_valid_on(i.id, (o.starts_at at time zone s.timezone)::date)
           and instructor_available_at(i.id, o.starts_at, o.ends_at)
           and not exists (
             select 1 from class_occurrences h
              where h.id <> o.id and h.instructor_id = i.id and h.status = 'scheduled'
                and tstzrange(h.starts_at, h.ends_at) && tstzrange(o.starts_at, o.ends_at))
      loop
        if d.user_id is not null and queue_shift_notice(o.studio_id, d.user_id, 'cover_available',
             jsonb_build_object('instructor_name', (select display_name from instructors where id = d.id),
               'studio_name', s.name, 'class_name', o.name,
               'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY, HH24:MI'),
               'booked_line', case when o.booked_count > 0
                 then format('%s member%s booked.', o.booked_count, case when o.booked_count = 1 then ' is' else 's are' end)
                 else 'Nobody has booked yet.' end,
               'href', coalesce(nullif(notification_setting('member_app_domain'), ''), 'studiior.app')),
             'cover_available:' || v_req.id || ':' || d.id) is not null
        then v_offered := v_offered + 1; end if;
      end loop;
    end if;
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (o.studio_id, auth.uid(), 'cover.requested', 'cover_requests', v_req.id,
          jsonb_build_object('occurrence_id', o.id, 'instructor_id', v_instr,
                             'urgent', v_urgent, 'notified', n, 'auto_offered', v_offered));

  return jsonb_build_object('ok', true, 'request_id', v_req.id, 'urgent', v_urgent,
                            'notified_staff', n, 'auto_offered', v_offered,
                            'still_assigned_to', v_instr);
end $function$;

CREATE OR REPLACE FUNCTION public.approve_cover_request(p_request_id uuid, p_mode text, p_instructor_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  req cover_requests%rowtype; o class_occurrences%rowtype; s studios%rowtype;
  st studio_settings%rowtype; v_move jsonb; v_old text; v_new text;
  v_cut timestamptz; v_late boolean; v_subs int := 0; v_user uuid;
  v_told boolean := false;
begin
  select * into req from cover_requests where id = p_request_id;
  if not found then
    raise exception 'no such cover request' using errcode = 'PT404';
  end if;
  if not is_manager_up(req.studio_id) then
    raise exception 'only owners and managers may answer a cover request'
      using errcode = 'PT403';
  end if;
  if req.status <> 'pending' then
    raise exception 'this request has already been answered' using errcode = 'PT409';
  end if;
  if p_mode not in ('assign', 'open') then
    raise exception 'mode must be assign or open' using errcode = 'PT422';
  end if;
  if p_mode = 'assign' and p_instructor_id is null then
    raise exception 'assigning cover needs somebody to assign it to'
      using errcode = 'PT422';
  end if;
  if p_mode = 'assign' and p_instructor_id = req.instructor_id then
    raise exception 'that is the instructor who asked to be taken off it'
      using errcode = 'PT422';
  end if;

  select * into o  from class_occurrences where id = req.occurrence_id;
  select * into s  from studios           where id = req.studio_id;
  select * into st from studio_settings   where studio_id = req.studio_id;
  select display_name into v_old from instructors where id = req.instructor_id;

  -- move_occurrence() is the only thing that moves a class, and that includes
  -- changing who teaches it: the exclusion constraints, the availability
  -- warning and the audit entry are all already there. p_confirm is true
  -- because the caller has just been shown the booked count on the approval
  -- screen — this is the confirmation.
  v_move := move_occurrence(
    p_occurrence_id   => req.occurrence_id,
    p_instructor_id   => case when p_mode = 'assign' then p_instructor_id else null end,
    p_confirm         => true,
    p_clear_instructor=> (p_mode = 'open'));

  if not (v_move ->> 'ok')::boolean then
    -- The replacement is busy. Refused rather than forced: two classes for one
    -- person at one time is the thing the constraint exists to prevent, and a
    -- cover request is not a reason to make an exception.
    return v_move;
  end if;

  -- Decision 17's open shift is a choice, so the engine must not undo it.
  if p_mode = 'open' then
    perform stamp_open_shift(req.occurrence_id);
  end if;

  update cover_requests
     set status = 'approved',
         resolution = case when p_mode = 'assign' then 'assigned' else 'opened' end,
         covered_by = case when p_mode = 'assign' then p_instructor_id end,
         decided_by = auth.uid(), decided_at = now()
   where id = req.id;

  -- Decision 2, finally called. queue_substitution() has existed since
  -- migration 030 with nothing invoking it, so until now changing a class's
  -- instructor told the booked members nothing whatsoever.
  -- Read outside the booked_count branch: the name is needed for the reply and
  -- for the message to the instructor who asked, both of which happen whether
  -- or not anybody is booked in.
  if p_mode = 'assign' then
    select display_name into v_new from instructors where id = p_instructor_id;
  end if;

  if p_mode = 'assign' and o.booked_count > 0 then
    v_subs := queue_substitution(req.occurrence_id, v_old, v_new);

    -- "Announced after the cancellation cutoff has already passed." Three days'
    -- notice is normal policy; ninety minutes is not, because by then the
    -- member can no longer decide about it.
    v_cut  := o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0));
    v_late := now() > v_cut;
    if v_late and coalesce(st.sub_late_free_cancel, true) then
      update bookings
         set free_cancel_until = o.starts_at
       where occurrence_id = req.occurrence_id and status = 'booked';
    end if;
  end if;

  -- The person who asked, told they are off it.
  v_user := instructor_user_id(req.instructor_id);
  if v_user is not null then
    perform queue_shift_notice(req.studio_id, v_user, 'cover_approved',
      jsonb_build_object(
        'class_name', o.name,
        'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY, HH24:MI'),
        'cover_line', case when p_mode = 'assign'
          then coalesce(v_new, 'Someone else') || ' is taking it.'
          else 'It has been opened up for another instructor to pick up.' end),
      'cover_approved:' || req.id);
  end if;

  -- And the replacement, told they have a class — IF WE CAN REACH THEM. An
  -- instructor is a teaching record and `instructors` carries no email of its
  -- own, so one with staff_id null has no address anywhere in the schema. That
  -- is the common case, not an edge: two of the three seeded instructors have
  -- no login. Reported back rather than swallowed, so the screen can say "tell
  -- them yourself" instead of implying an email went out.
  if p_mode = 'assign' then
    v_told := queue_instructor_assigned(req.occurrence_id) is not null;
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (req.studio_id, auth.uid(), 'cover.approved', 'cover_requests', req.id,
          jsonb_build_object('instructor_id', req.instructor_id),
          jsonb_build_object('mode', p_mode, 'covered_by', p_instructor_id,
                             'members_told', v_subs, 'free_cancel', v_late));

  return jsonb_build_object('ok', true, 'mode', p_mode,
                            'members_told', v_subs,
                            'free_cancellation_granted', coalesce(v_late, false),
                            'cover_notified', v_told,
                            'cover_name', v_new,
                            'move', v_move);
end $function$;

CREATE OR REPLACE FUNCTION public.decline_cover_request(p_request_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare req cover_requests%rowtype; o class_occurrences%rowtype;
        s studios%rowtype; v_user uuid;
begin
  select * into req from cover_requests where id = p_request_id;
  if not found then
    raise exception 'no such cover request' using errcode = 'PT404';
  end if;
  if not is_manager_up(req.studio_id) then
    raise exception 'only owners and managers may answer a cover request'
      using errcode = 'PT403';
  end if;
  if req.status <> 'pending' then
    raise exception 'this request has already been answered' using errcode = 'PT409';
  end if;

  select * into o from class_occurrences where id = req.occurrence_id;
  select * into s from studios where id = req.studio_id;

  update cover_requests
     set status = 'declined', decided_by = auth.uid(), decided_at = now(),
         decision_note = nullif(btrim(p_reason), '')
   where id = req.id;

  -- The class was never touched, so there is nothing to undo. That is the whole
  -- reason a request does not release the class the moment it is made.
  v_user := instructor_user_id(req.instructor_id);
  if v_user is not null then
    perform queue_shift_notice(req.studio_id, v_user, 'cover_declined',
      jsonb_build_object(
        'class_name', o.name,
        'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY, HH24:MI'),
        'reason_line', case when nullif(btrim(coalesce(p_reason,'')), '') is null then ''
                            else 'They said: ' || btrim(p_reason) || E'\n\n' end),
      'cover_declined:' || req.id);
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (req.studio_id, auth.uid(), 'cover.declined', 'cover_requests', req.id,
          jsonb_build_object('reason', p_reason));
  return jsonb_build_object('ok', true, 'still_assigned_to', req.instructor_id);
end $function$;

CREATE OR REPLACE FUNCTION public.accept_cover(p_occurrence_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o class_occurrences%rowtype; s studios%rowtype; st studio_settings%rowtype; req cover_requests%rowtype;
  v_taker uuid; v_move jsonb; v_hours numeric; v_old text; v_new text; v_subs int := 0;
  v_cut timestamptz; v_user uuid;
begin
  select * into o from class_occurrences where id = p_occurrence_id for update;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  select * into st from studio_settings where studio_id = o.studio_id;
  if not coalesce(st.cover_auto_accept_enabled, false) then
    raise exception 'this studio approves cover itself' using errcode = 'PT409';
  end if;

  v_taker := auth_instructor_id(o.studio_id);
  if v_taker is null then
    raise exception 'only an instructor at this studio can take a cover' using errcode = 'PT403';
  end if;

  select * into req from cover_requests
   where occurrence_id = o.id and status = 'pending' order by created_at limit 1;
  if not found then raise exception 'no cover is open on that class' using errcode = 'PT409'; end if;
  if req.instructor_id = v_taker then
    raise exception 'that is your own class' using errcode = 'PT409';
  end if;
  if o.status <> 'scheduled' or o.starts_at <= now() then
    raise exception 'that class is not open to take' using errcode = 'PT422';
  end if;

  select * into s from studios where id = o.studio_id;
  v_hours := extract(epoch from o.starts_at - now()) / 3600;
  if v_hours > coalesce(st.cover_escalation_hours, 4) then
    raise exception 'that class is not close enough to take without the studio — it needs approving'
      using errcode = 'PT409';
  end if;
  -- The checks auto-accept keeps (the human is what it skips): qualified, inside
  -- the validity window, available, and not already teaching then. The cap is
  -- deliberately NOT checked — an urgent cover is not hoarding a month.
  -- move_occurrence is manager-up, and the caller here is the instructor taking
  -- the cover, so the assignment is a direct guarded write: the exclusion
  -- constraint (occ_instructor_no_overlap) is the hard clash gate, and validity
  -- is checked explicitly. No time changes, so no booked-member move email —
  -- the substitution notice below is what they get.
  if not instructor_qualified(v_taker, o.class_type_id) then
    raise exception 'you are not down to teach this class' using errcode = 'PT403';
  end if;
  if not instructor_valid_on(v_taker, (o.starts_at at time zone (select timezone from studios where id = o.studio_id))::date) then
    raise exception 'that class is outside the dates you have agreed to work' using errcode = 'PT409';
  end if;
  if not instructor_available_at(v_taker, o.starts_at, o.ends_at) then
    raise exception 'that is outside the hours you gave us' using errcode = 'PT409';
  end if;

  begin
    update class_occurrences
       set instructor_id = v_taker, assigned_by = auth.uid(), updated_at = now()
     where id = o.id;
  exception when exclusion_violation then
    return jsonb_build_object('ok', false, 'reason', 'instructor_busy');
  end;

  update cover_requests
     set status = 'approved', resolution = 'assigned', covered_by = v_taker,
         decided_by = null, decided_at = now()
   where id = req.id;

  select display_name into v_old from instructors where id = req.instructor_id;
  select display_name into v_new from instructors where id = v_taker;

  if o.booked_count > 0 then
    v_subs := queue_substitution(o.id, v_old, v_new);
    v_cut := o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0));
    if now() > v_cut and coalesce(st.sub_late_free_cancel, true) then
      update bookings set free_cancel_until = o.starts_at
       where occurrence_id = o.id and status = 'booked';
    end if;
  end if;

  -- The instructor who asked — it is covered, the message they were waiting for.
  v_user := instructor_user_id(req.instructor_id);
  if v_user is not null then
    perform queue_shift_notice(o.studio_id, v_user, 'cover_approved',
      jsonb_build_object('class_name', o.name,
        'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY, HH24:MI'),
        'cover_line', coalesce(v_new, 'Someone else') || ' is taking it.'),
      'cover_approved:' || req.id);
  end if;
  -- Staff, told who took it (no approval was needed).
  perform queue_shift_notice_to_staff(o.studio_id, 'cover_auto_covered',
    jsonb_build_object('taker_name', coalesce(v_new, 'An instructor'),
      'requester_name', coalesce(v_old, 'an instructor'), 'class_name', o.name,
      'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY, HH24:MI')),
    'cover_auto:' || req.id);

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (o.studio_id, auth.uid(), 'cover.auto_covered', 'cover_requests', req.id,
          jsonb_build_object('covered_by', v_taker, 'members_told', v_subs));

  return jsonb_build_object('ok', true, 'covered_by', coalesce(v_new, 'you'), 'members_told', v_subs);
end $function$;

CREATE OR REPLACE FUNCTION public.sweep_cover_escalations()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; n int := 0; v_hours numeric;
begin
  if not is_service_context() and not is_platform_admin() then
    raise exception 'only the scheduler may sweep cover requests' using errcode = 'PT403';
  end if;

  for r in
    select cr.id, cr.studio_id, cr.occurrence_id, cr.instructor_id,
           o.name, o.starts_at, o.booked_count, s.timezone,
           i.display_name,
           coalesce(st.cover_escalation_hours, 4) as window_hours
      from cover_requests cr
      join class_occurrences o on o.id = cr.occurrence_id
      join studios s           on s.id = cr.studio_id
      join instructors i       on i.id = cr.instructor_id
      left join studio_settings st on st.studio_id = cr.studio_id
     where cr.status = 'pending'
       and cr.escalated_at is null
       and o.status = 'scheduled'
       and o.starts_at > now()
       and o.starts_at <= now() + make_interval(hours => coalesce(st.cover_escalation_hours, 4))
  loop
    v_hours := extract(epoch from r.starts_at - now()) / 3600;
    perform queue_shift_notice_to_staff(r.studio_id, 'cover_urgent',
      jsonb_build_object(
        'instructor_name', r.display_name,
        'class_name', r.name,
        'when', to_char(r.starts_at at time zone r.timezone, 'FMDay FMDD FMMonth YYYY, HH24:MI'),
        'hours_line', case when v_hours < 1
                           then round(v_hours * 60) || ' minutes'
                           else round(v_hours) || ' hour' ||
                                case when round(v_hours) = 1 then '' else 's' end end,
        'booked_line', case when r.booked_count > 0
          then format('%s member%s booked.', r.booked_count,
                      case when r.booked_count = 1 then ' is' else 's are' end)
          else 'Nobody has booked yet.' end,
        'cover_url', '/shifts/cover'),
      'cover_req:' || r.id || ':urgent');
    update cover_requests set escalated_at = now() where id = r.id;
    n := n + 1;
  end loop;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION public.queue_substitution(p_occurrence_id uuid, p_old text, p_new text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o class_occurrences%rowtype; s studios%rowtype; r record; n int := 0; v_when text;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  select * into s from studios where id = o.studio_id;
  v_when := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY');

  for r in select b.member_id from bookings b
            where b.occurrence_id = p_occurrence_id and b.status = 'booked'
  loop
    if queue_notification(o.studio_id, r.member_id, 'instructor_substituted',
          jsonb_build_object('class_name', o.name, 'when', v_when,
                             'old_instructor', p_old, 'new_instructor', p_new),
          'substitution:' || p_occurrence_id || ':' || r.member_id) is not null
    then n := n + 1; end if;
  end loop;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION public.reassign_occurrence(p_occurrence_id uuid, p_instructor_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o class_occurrences%rowtype; s studios%rowtype;
  v_old uuid; v_old_name text; v_new_name text; v_user uuid; v_when text;
  v_move jsonb; v_told boolean := false; v_reachable_removal boolean := false;
begin
  select * into o from class_occurrences where id = p_occurrence_id for update;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(o.studio_id), false) then
    raise exception 'only owners and managers change the timetable' using errcode = 'PT403';
  end if;
  if p_instructor_id is null then
    raise exception 'pick who is teaching it' using errcode = 'PT422';
  end if;
  v_old := o.instructor_id;

  -- The one gate. move_occurrence refuses outside the validity window, refuses a
  -- room or double-booking clash, warns on availability, and — because the new
  -- instructor differs from the old — notifies the one swapped IN. p_confirm is
  -- true because reassigning changes no time, so no member is emailed and there
  -- is no booked-members question to answer.
  v_move := move_occurrence(p_occurrence_id => p_occurrence_id,
                            p_instructor_id => p_instructor_id, p_confirm => true);
  if not coalesce((v_move ->> 'ok')::boolean, false) then
    return v_move;   -- the refusal, with blocked_by, passed straight back
  end if;

  -- Tell the instructor taken off — same queue_ pattern, publication-gated like
  -- the assigned notice. Skipped for a no-op (same person) or an empty slot, and
  -- for a draft month (nobody was told they had the class, so nobody is told it
  -- moved).
  if v_old is not null and v_old is distinct from p_instructor_id
     and month_published(o.studio_id, o.starts_at) then
    select * into s from studios where id = o.studio_id;
    select display_name into v_old_name from instructors where id = v_old;
    select display_name into v_new_name from instructors where id = p_instructor_id;
    v_when := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY, HH24:MI');
    v_user := instructor_user_id(v_old);
    v_reachable_removal := true;
    if v_user is not null then
      v_told := queue_shift_notice(o.studio_id, v_user, 'class_reassigned_off',
        jsonb_build_object(
          'instructor_name', coalesce(v_old_name, 'there'),
          'studio_name', s.name, 'class_name', o.name, 'when', v_when,
          'new_instructor', coalesce(v_new_name, 'someone else')),
        'reassigned_off:' || o.id || ':' || v_old || ':' || extract(epoch from o.starts_at)::bigint
      ) is not null;
    end if;
  end if;

  return jsonb_build_object(
    'ok', true, 'occurrence_id', p_occurrence_id,
    'new_instructor', coalesce((select display_name from instructors where id = p_instructor_id), 'them'),
    'removed_instructor', v_old_name,
    'removed_notified', v_told,
    -- true only when there WAS someone to tell (published, real old instructor)
    -- but they have no login — the screen says "tell them yourself".
    'removed_uncontactable', (v_reachable_removal and v_user is null));
end $function$;

CREATE OR REPLACE FUNCTION public.apply_for_shift(p_occurrence_id uuid, p_note text DEFAULT NULL::text, p_over_cap_ack boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  occ class_occurrences%rowtype;
  v_instructor uuid;
  v_app uuid;
  v_available boolean;
  v_when text; v_tz text;
  v_tier text; v_cap int; v_core int; v_over boolean := false;
  v_load jsonb;
begin
  select * into occ from class_occurrences where id = p_occurrence_id for update;
  if not found then
    raise exception 'no such class' using errcode = 'PT404';
  end if;

  v_instructor := auth_instructor_id(occ.studio_id);
  if v_instructor is null then
    raise exception 'only an instructor at this studio can apply for a shift'
      using errcode = 'PT403';
  end if;
  if studio_is_locked(occ.studio_id) then
    raise exception 'this studio''s Studiior subscription is not active'
      using errcode = 'PT402';
  end if;
  if occ.staffing = 'assigned' then
    raise exception 'that class already has an instructor' using errcode = 'PT409';
  end if;
  if occ.status <> 'scheduled' then
    raise exception 'that class is %', occ.status using errcode = 'PT409';
  end if;
  if occ.starts_at < now() then
    raise exception 'that class has already happened' using errcode = 'PT409';
  end if;

  select s.timezone into v_tz from studios s where s.id = occ.studio_id;

  -- CLAIMING gates — only when this studio uses claiming. Cover-shift applies at
  -- an assigned-model studio are untouched.
  if claiming_enabled(occ.studio_id) then
    -- Publishing is the reveal: an unpublished month is not claimable.
    if not month_published(occ.studio_id, occ.starts_at) then
      raise exception 'that class is not published yet' using errcode = 'PT409';
    end if;
    -- HARD: you cannot claim in a month you gave no availability for, nor outside
    -- your validity dates (Decision 18). Availability HOURS stay a soft warning.
    if not instructor_can_claim_month(v_instructor, (date_trunc('month', occ.starts_at at time zone v_tz))::date)
       or not instructor_valid_on(v_instructor, (occ.starts_at at time zone v_tz)::date) then
      return jsonb_build_object('ok', false, 'reason', 'outside_validity');
    end if;
    -- CORE cap: soft. Refuse the self-claim past it with the numbers, and offer
    -- "ask anyway" (p_over_cap_ack) which records the over-cap flag for staff.
    v_tier := occurrence_claim_tier(occ.id);
    if v_tier = 'core' then
      v_cap  := instructor_core_cap(v_instructor);
      v_load := instructor_week_claim_load(v_instructor, occ.starts_at);
      v_core := (v_load ->> 'core')::int;
      if v_core >= v_cap and not p_over_cap_ack then
        return jsonb_build_object('ok', false, 'reason', 'over_cap',
                                  'tier', 'core', 'current', v_core, 'cap', v_cap);
      end if;
      v_over := v_core >= v_cap;   -- true only when they asked anyway
    end if;
  end if;

  insert into shift_applications (studio_id, occurrence_id, instructor_id, note, over_cap)
  values (occ.studio_id, occ.id, v_instructor, p_note, v_over)
  on conflict (occurrence_id, instructor_id) where status = 'pending'
  do nothing
  returning id into v_app;

  if v_app is null then
    raise exception 'you have already applied for that shift' using errcode = 'PT409';
  end if;

  update class_occurrences set staffing = 'pending_approval', updated_at = now()
   where id = occ.id and staffing = 'open';

  v_available := instructor_available_at(v_instructor, occ.starts_at, occ.ends_at);
  v_when := to_char(occ.starts_at at time zone v_tz, 'FMDay FMDD FMMonth YYYY, HH24:MI');

  perform queue_shift_notice_to_staff(occ.studio_id, 'shift_application_received',
    jsonb_build_object(
      'class_name', occ.name,
      'when', v_when,
      'instructor_name', (select display_name from instructors where id = v_instructor),
      'availability_note', case when v_available then ''
        else 'This is outside the availability they have given us. ' end,
      'applications_url', coalesce(nullif(notification_setting('staff_app_origin'), ''),
                                   'https://app.studiior.com') || '/shifts/applications'),
    'shift_applied:' || v_app);

  return jsonb_build_object('ok', true, 'application_id', v_app,
                            'outside_availability', not v_available,
                            'tier', v_tier, 'over_cap', v_over,
                            'standing', case when claiming_enabled(occ.studio_id)
                              then jsonb_build_object('core', coalesce((instructor_week_claim_load(v_instructor, occ.starts_at) ->> 'core')::int, 0),
                                                      'cap', instructor_core_cap(v_instructor),
                                                      'flex', coalesce((instructor_week_claim_load(v_instructor, occ.starts_at) ->> 'flex')::int, 0))
                              else null end);
end $function$;

CREATE OR REPLACE FUNCTION public.approve_shift_application(p_application_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  app  shift_applications%rowtype;
  occ  class_occurrences%rowtype;
  r    record;
  v_tz text; v_when text; v_where text;
  n_declined int := 0;
  v_res jsonb;
begin
  select * into app from shift_applications where id = p_application_id for update;
  if not found then
    raise exception 'no such application' using errcode = 'PT404';
  end if;
  if not is_manager_up(app.studio_id) then
    raise exception 'approving a shift is the owner''s or a manager''s to do'
      using errcode = 'PT403';
  end if;
  if app.status <> 'pending' then
    raise exception 'that application is already %', app.status using errcode = 'PT409';
  end if;

  select * into occ from class_occurrences where id = app.occurrence_id for update;

  v_res := move_occurrence(occ.id, null, null, app.instructor_id, null, true);
  if not (v_res ->> 'ok')::boolean then
    raise exception 'cannot assign them: %', v_res ->> 'reason'
      using errcode = 'PT409',
            hint = 'They are teaching something else at that time.';
  end if;

  update shift_applications
     set status = 'approved', approved_at = now(), decided_by = auth.uid(), decided_at = now()
   where id = p_application_id;

  select s.timezone into v_tz from studios s where s.id = occ.studio_id;
  v_when  := to_char(occ.starts_at at time zone v_tz, 'FMDay FMDD FMMonth YYYY, HH24:MI');
  v_where := coalesce((select ', in ' || rm.name from rooms rm where rm.id = occ.room_id), '');

  perform queue_shift_notice(
    occ.studio_id,
    instructor_user_id(app.instructor_id),
    'shift_approved',
    jsonb_build_object('class_name', occ.name, 'when', v_when, 'where_line', v_where),
    'shift_approved:' || app.id);

  for r in
    select sa.*, instructor_user_id(sa.instructor_id) as staff_user
      from shift_applications sa
     where sa.occurrence_id = occ.id and sa.status = 'pending' and sa.id <> app.id
    for update
  loop
    update shift_applications
       set status = 'declined', decided_by = auth.uid(), decided_at = now()
     where id = r.id;
    perform queue_shift_notice(occ.studio_id, r.staff_user, 'shift_declined',
      jsonb_build_object('class_name', occ.name, 'when', v_when,
        'shifts_url', coalesce(nullif(notification_setting('staff_app_origin'), ''),
                               'https://app.studiior.com') || '/shifts'),
      'shift_declined:' || r.id);
    n_declined := n_declined + 1;
  end loop;

  return jsonb_build_object('approved', app.id, 'auto_declined', n_declined,
                            'warnings', v_res -> 'warnings');
end $function$;

CREATE OR REPLACE FUNCTION public.decline_shift_application(p_application_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare app shift_applications%rowtype; occ class_occurrences%rowtype; v_tz text; v_when text;
begin
  select * into app from shift_applications where id = p_application_id for update;
  if not found then
    raise exception 'no such application' using errcode = 'PT404';
  end if;
  if not is_manager_up(app.studio_id) then
    raise exception 'declining a shift is the owner''s or a manager''s to do'
      using errcode = 'PT403';
  end if;
  if app.status <> 'pending' then
    raise exception 'that application is already %', app.status using errcode = 'PT409';
  end if;

  update shift_applications
     set status = 'declined', decided_by = auth.uid(), decided_at = now()
   where id = p_application_id;

  select * into occ from class_occurrences where id = app.occurrence_id;
  select s.timezone into v_tz from studios s where s.id = occ.studio_id;
  v_when := to_char(occ.starts_at at time zone v_tz, 'FMDay FMDD FMMonth YYYY, HH24:MI');

  perform queue_shift_notice(occ.studio_id,
    instructor_user_id(app.instructor_id),
    'shift_declined',
    jsonb_build_object('class_name', occ.name, 'when', v_when,
      'shifts_url', coalesce(nullif(notification_setting('staff_app_origin'), ''),
                             'https://app.studiior.com') || '/shifts'),
    'shift_declined:' || app.id);

  -- Back to open if that was the last one waiting.
  update class_occurrences set staffing = 'open', updated_at = now()
   where id = occ.id and staffing = 'pending_approval'
     and not exists (select 1 from shift_applications sa
                      where sa.occurrence_id = occ.id and sa.status = 'pending');

  return jsonb_build_object('declined', app.id);
end $function$;

CREATE OR REPLACE FUNCTION public.open_shift(p_occurrence_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o class_occurrences%rowtype; s studios%rowtype;
  v_old_instr uuid; v_old_name text; v_user uuid; v_when text; v_told boolean := false;
  v_move jsonb;
begin
  select * into o from class_occurrences where id = p_occurrence_id for update;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(o.studio_id), false) then
    raise exception 'only owners and managers open a shift' using errcode = 'PT403';
  end if;
  if o.status <> 'scheduled' then
    raise exception 'a % class cannot be opened', o.status using errcode = 'PT409';
  end if;
  if o.instructor_id is null then
    raise exception 'that class already has nobody on it' using errcode = 'PT409';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'say why — the instructor being taken off gets this, and the studio''s record keeps it'
      using errcode = 'PT422';
  end if;

  v_old_instr := o.instructor_id;
  select display_name into v_old_name from instructors where id = v_old_instr;
  select * into s from studios where id = o.studio_id;
  v_when := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY, HH24:MI');

  -- Clear through move_occurrence(): p_confirm true because opening a class is
  -- not moving anybody's booking — the members keep their seats and the class
  -- stays bookable — and p_clear_instructor makes staffing 'open'. This also
  -- stamps assigned_by via stamp_open_shift below, so "fill a month" leaves it
  -- alone.
  v_move := move_occurrence(p_occurrence_id => p_occurrence_id, p_confirm => true,
                            p_clear_instructor => true);
  if not coalesce((v_move ->> 'ok')::boolean, false) then
    return v_move;
  end if;
  perform stamp_open_shift(p_occurrence_id);

  -- The instructor removed is told. queue_shift_notice returns null for
  -- somebody with no login (the ordinary case), which is reported rather than
  -- passed off as a message that was sent.
  v_user := instructor_user_id(v_old_instr);
  if v_user is not null then
    v_told := queue_shift_notice(o.studio_id, v_user, 'shift_taken_off',
      jsonb_build_object(
        'instructor_name', coalesce(v_old_name, 'there'),
        'studio_name', s.name,
        'class_name', o.name,
        'when', v_when,
        'reason', btrim(p_reason)),
      -- Keyed on the class and the instructor and the time: taken off the same
      -- class twice at different times is two notices, the same one is one.
      'shift_taken_off:' || o.id || ':' || v_old_instr || ':' || extract(epoch from o.starts_at)::bigint
    ) is not null;
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (o.studio_id, auth.uid(), 'occurrence.opened', 'class_occurrences', p_occurrence_id,
          jsonb_build_object('instructor_id', v_old_instr, 'instructor_name', v_old_name),
          jsonb_build_object('reason', btrim(p_reason), 'booked_count', o.booked_count,
                             'removed_notified', v_told, 'at', now()));

  return jsonb_build_object(
    'ok', true, 'occurrence_id', p_occurrence_id,
    'removed_instructor', v_old_name,
    'removed_notified', v_told,
    -- Named so the caller can tell "taken off but has no login to hear it" from
    -- "told" — the screen says "tell them yourself" in that case.
    'removed_uncontactable', (v_user is null),
    'booked_count', o.booked_count);
end $function$;

CREATE OR REPLACE FUNCTION public.queue_instructor_assigned(p_occurrence_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o class_occurrences%rowtype; s studios%rowtype; v_user uuid; v_room text;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found or o.instructor_id is null then return null; end if;
  if not occurrence_published(o.id) then return null; end if;
  select * into s from studios where id = o.studio_id;
  v_user := instructor_user_id(o.instructor_id);
  if v_user is null then return null; end if;
  select name into v_room from rooms where id = o.room_id;

  return queue_shift_notice(
    o.studio_id, v_user, 'instructor_assigned',
    jsonb_build_object(
      'class_name', o.name,
      'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY, HH24:MI'),
      'where_line', case when v_room is null then '' else ' in ' || v_room end,
      'booked_line', case when o.booked_count > 0
        then format('%s member%s booked in so far.', o.booked_count,
                    case when o.booked_count = 1 then ' is' else 's are' end)
        else 'Nobody has booked yet.' end,
      'occurrence_id', o.id),
    'instructor_assigned:' || o.id || ':' || o.instructor_id || ':' || extract(epoch from o.starts_at)::bigint);
end $function$;

CREATE OR REPLACE FUNCTION public.queue_platform_warning(p_studio_id uuid, p_day integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  sub platform_subscriptions%rowtype;
  s   studios%rowtype;
  v_owner uuid; v_id uuid; v_headline text;
begin
  select * into sub from platform_subscriptions where studio_id = p_studio_id;
  select * into s   from studios where id = p_studio_id;
  if not found or sub.grace_ends_at is null then
    return null;
  end if;

  -- The owner. Not every staff member: this is the studio's bank relationship
  -- and a front desk being emailed about a declined card is neither useful to
  -- them nor the owner's choice.
  select ss.user_id into v_owner from studio_staff ss
   where ss.studio_id = p_studio_id and ss.role = 'owner' and ss.status = 'active'
   order by ss.created_at limit 1;
  if v_owner is null then
    return null;
  end if;

  v_headline := case
    when p_day >= 14 then 'This is the last day before ' || s.name || ' is locked.'
    when p_day >= 12 then 'Two days left before ' || s.name || ' is locked.'
    when p_day >= 7  then 'A week left to reactivate ' || s.name || '.'
    else 'We could not take payment for your Studiior subscription.'
  end;

  insert into notifications (studio_id, recipient_type, user_id, template_key,
                             channel, payload, dedupe_key, scheduled_for, status)
  values (p_studio_id, 'staff', v_owner, 'platform_billing_warning', 'email',
          jsonb_build_object(
            'headline', v_headline,
            'grace_ends', to_char(sub.grace_ends_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY'),
            'billing_url', coalesce(nullif(notification_setting('staff_app_origin'), ''),
                                    'https://app.studiior.com') || '/billing'),
          -- One per studio per grace period per day, so a sweep that runs twice
          -- cannot email the owner twice about the same day.
          'platform_warning:' || p_studio_id || ':'
            || to_char(sub.grace_ends_at, 'YYYYMMDD') || ':' || p_day,
          now(), 'scheduled')
  on conflict (dedupe_key) do nothing
  returning id into v_id;

  return v_id;
end $function$;
-- END generated year re-issues

-- -----------------------------------------------------------------------------
-- 6. Anon surface unchanged — EXACTLY ELEVEN.
-- -----------------------------------------------------------------------------
do $$
declare v_n int;
begin
  select count(*) into v_n from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
   where nsp.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if v_n <> 11 then raise exception 'anon surface is % functions, expected 11', v_n; end if;
end $$;
