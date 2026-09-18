-- =============================================================================
-- 161  Decision 33 Part A: the .ics builder, the attachment on booking emails,
--      and the instructor per-booking opt-in.
-- =============================================================================
-- A web app cannot write to a phone's calendar silently. Part A is the one-tap
-- half: an .ics VEVENT rides on the booking confirmation (Gmail/Apple Mail turn
-- it into "Add to calendar"), on class_moved (same UID, higher SEQUENCE, so the
-- event updates in place), on class_cancelled (METHOD:CANCEL, so it leaves the
-- calendar), and on the instructor's assignment email. One builder in SQL, used
-- by the email pipeline here and by the Add-to-calendar buttons below — the feed
-- (Part B) reuses the same builder.
--
-- SEQUENCE has two sources, both moving with what the event shows. A member
-- event (UID = booking id) uses epoch(bookings.updated_at). An instructor event
-- (UID = occurrence id) shows the HEADCOUNT, so it uses
-- epoch(class_occurrences.updated_at) — and a booking write touches it, because
-- book_class/cancel_booking do `update class_occurrences set booked_count = …`,
-- which fires the class_occurrences_updated → set_updated_at() trigger.
--
-- The instructor per-booking email is OPT-IN, off by default: Reform at 21+
-- classes/week × 6 beds is 100+ "one person booked" emails a week. The calendar
-- is the per-booking channel; email is not.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. The instructor per-booking opt-in (their first notification preference)
-- -----------------------------------------------------------------------------
alter table instructors
  add column if not exists email_each_booking boolean not null default false;

comment on column instructors.email_each_booking is
  'Decision 33: email this instructor once per booking on their classes. Off by '
  'default (Reform would be 100+/week); the calendar feed''s live headcount is '
  'the per-booking channel. Only reaches an instructor with a login.';

-- -----------------------------------------------------------------------------
-- 2. The .ics builder — pure text helpers (RFC 5545)
-- -----------------------------------------------------------------------------
-- Escape the four value-special characters. Colon is NOT escaped: it is only
-- special in the name:value separator, never inside a value.
create or replace function ics_escape(p text) returns text
language sql immutable as $$
  select replace(replace(replace(replace(coalesce(p, ''),
    '\', '\\'), E'\n', '\n'), ';', '\;'), ',', '\,')
$$;

-- Line folding: no content line over 75 octets. Our content is ASCII (class
-- names, URLs, addresses), so folding every 73 characters with CRLF + a space
-- is within the rule and every parser accepts it.
create or replace function ics_fold(p text) returns text
language sql immutable as $$
  select case when length(p) <= 75 then p
              else regexp_replace(p, '(.{73})', E'\\1\r\n ', 'g') end
$$;

create or replace function ics_prop(p_name text, p_value text) returns text
language sql immutable as $$
  select ics_fold(p_name || ':' || ics_escape(p_value))
$$;

-- A calendar instant is UTC with a Z. A fixed single event needs no VTIMEZONE
-- block: the instant is exact and the phone renders it in the viewer's zone.
create or replace function ics_dt(p_ts timestamptz) returns text
language sql immutable as $$
  select to_char(p_ts at time zone 'UTC', 'YYYYMMDD"T"HH24MISS"Z"')
$$;

-- One VEVENT block. STABLE, not immutable — DTSTAMP is now().
create or replace function ics_vevent(
  p_uid text, p_seq bigint, p_start timestamptz, p_end timestamptz,
  p_summary text, p_location text, p_description text, p_url text, p_cancelled boolean
) returns text
language sql stable as $$
  select concat_ws(E'\r\n',
    'BEGIN:VEVENT',
    ics_prop('UID', p_uid),
    'SEQUENCE:' || greatest(coalesce(p_seq, 0), 0),
    'DTSTAMP:' || ics_dt(now()),
    'DTSTART:' || ics_dt(p_start),
    'DTEND:'   || ics_dt(p_end),
    ics_prop('SUMMARY', p_summary),
    case when nullif(p_location, '')    is not null then ics_prop('LOCATION', p_location) end,
    case when nullif(p_description, '') is not null then ics_prop('DESCRIPTION', p_description) end,
    case when nullif(p_url, '')         is not null then ics_prop('URL', p_url) end,
    'STATUS:' || case when p_cancelled then 'CANCELLED' else 'CONFIRMED' end,
    'END:VEVENT')
$$;

-- The VCALENDAR wrapper. METHOD is PUBLISH (add/update) or CANCEL (remove).
create or replace function ics_calendar(p_method text, p_vevents text) returns text
language sql immutable as $$
  select concat_ws(E'\r\n',
    'BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Studiior//Calendar//EN',
    'CALSCALE:GREGORIAN', 'METHOD:' || p_method,
    p_vevents, 'END:VCALENDAR') || E'\r\n'
$$;

-- -----------------------------------------------------------------------------
-- 3. Event assemblers — internal, cross-tenant, service-role only
-- -----------------------------------------------------------------------------
-- The studio's postal address, assembled by key (locations.address is shapeless
-- jsonb), the same way render_notification builds its footer.
create or replace function ics_studio_location(p_studio_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select nullif(concat_ws(', ',
           nullif(l.address ->> 'line1', ''), nullif(l.address ->> 'line2', ''),
           nullif(l.address ->> 'city', ''),  nullif(l.address ->> 'postal_code', ''),
           nullif(l.address ->> 'country', '')), '')
    from locations l
   where l.studio_id = p_studio_id and l.status = 'active'
   order by l.is_primary desc, l.created_at limit 1
$$;

-- A member's VEVENT for one class: UID = their booking id, SEQUENCE from the
-- booking's updated_at, a link back to the class. Null when they have no
-- booking for it (nothing to add).
create or replace function ics_member_vevent(
  p_occurrence_id uuid, p_member_id uuid, p_cancelled boolean
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

  -- SEQUENCE is the greater of the booking's and the occurrence's updated_at.
  -- The UID is the booking, but the event SHOWS the class time — a move touches
  -- the occurrence, not the booking, so keying SEQUENCE on the booking alone
  -- would leave class_moved at the same number and the calendar would ignore
  -- the update. Both a re-book and a move now raise it.
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
    v_desc, v_link, p_cancelled);
end $$;

-- An instructor's VEVENT for one class: UID = occurrence id, SEQUENCE from the
-- occurrence's updated_at (which a booking bumps), the headcount in the body.
create or replace function ics_instructor_vevent(
  p_occurrence_id uuid, p_cancelled boolean
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
    v_desc, null, p_cancelled);
end $$;

-- What deliver_notification attaches: the right VCALENDAR for a calendar-bearing
-- template, from the occurrence_id the queue function put in the payload. Null
-- for every other template (no attachment).
create or replace function notification_ics(p_notification_id uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare n notifications%rowtype; v_occ uuid; v_ve text; v_method text;
begin
  select * into n from notifications where id = p_notification_id;
  if not found then return null; end if;
  v_occ := nullif(n.payload ->> 'occurrence_id', '')::uuid;
  if v_occ is null then return null; end if;

  if n.template_key in ('booking_confirmed', 'class_moved') then
    v_ve := ics_member_vevent(v_occ, n.member_id, false); v_method := 'PUBLISH';
  elsif n.template_key = 'class_cancelled' then
    v_ve := ics_member_vevent(v_occ, n.member_id, true);  v_method := 'CANCEL';
  elsif n.template_key in ('instructor_assigned', 'booking_for_instructor') then
    v_ve := ics_instructor_vevent(v_occ, false);          v_method := 'PUBLISH';
  else
    return null;
  end if;

  if v_ve is null then return null; end if;
  return ics_calendar(v_method, v_ve);
end $$;

revoke execute on function ics_escape(text)                    from public, anon;
revoke execute on function ics_fold(text)                      from public, anon;
revoke execute on function ics_prop(text, text)                from public, anon;
revoke execute on function ics_dt(timestamptz)                 from public, anon;
revoke execute on function ics_vevent(text,bigint,timestamptz,timestamptz,text,text,text,text,boolean) from public, anon;
revoke execute on function ics_calendar(text, text)            from public, anon;
grant  execute on function ics_escape(text)                    to authenticated, service_role;
grant  execute on function ics_fold(text)                      to authenticated, service_role;
grant  execute on function ics_prop(text, text)                to authenticated, service_role;
grant  execute on function ics_dt(timestamptz)                 to authenticated, service_role;
grant  execute on function ics_vevent(text,bigint,timestamptz,timestamptz,text,text,text,text,boolean) to authenticated, service_role;
grant  execute on function ics_calendar(text, text)            to authenticated, service_role;

revoke execute on function ics_studio_location(uuid)           from public, anon, authenticated;
revoke execute on function ics_member_vevent(uuid, uuid, boolean)   from public, anon, authenticated;
revoke execute on function ics_instructor_vevent(uuid, boolean)     from public, anon, authenticated;
revoke execute on function notification_ics(uuid)              from public, anon, authenticated;
grant  execute on function ics_studio_location(uuid)           to service_role;
grant  execute on function ics_member_vevent(uuid, uuid, boolean)   to service_role;
grant  execute on function ics_instructor_vevent(uuid, boolean)     to service_role;
grant  execute on function notification_ics(uuid)              to service_role;

-- -----------------------------------------------------------------------------
-- 4. send_via_resend gains the attachment: 6 → 7 args, drop-and-recreate.
-- -----------------------------------------------------------------------------
-- The only live caller is deliver_notification (migration 143, 6 args) and the
-- notifications suite (6 args). The 7th arg has a DEFAULT, so both resolve to
-- this one function — no overload, no ambiguity. Rebuilt from 143's body.
drop function if exists send_via_resend(text, text, text, text, text, text);

create function send_via_resend(
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

  -- The .ics rides as a base64 attachment. Gmail and Apple Mail read the VEVENT
  -- and offer one-tap add; the content-type method mirrors the calendar's own
  -- METHOD line, which is what actually drives the client.
  if nullif(p_ics, '') is not null then
    v_method := case when p_ics ~ 'METHOD:CANCEL' then 'CANCEL' else 'PUBLISH' end;
    v_body := v_body || jsonb_build_object('attachments', jsonb_build_array(
      jsonb_build_object(
        'filename', 'studiior.ics',
        'content', encode(convert_to(p_ics, 'UTF8'), 'base64'),
        'content_type', 'text/calendar; charset=utf-8; method=' || v_method)));
  end if;

  return net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_key,
                                  'Content-Type', 'application/json'),
    body := v_body,
    timeout_milliseconds := 8000);
end $$;

-- A drop discards the ACL; re-assert it and prove no client role can reach it.
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

-- -----------------------------------------------------------------------------
-- 5. deliver_notification builds the .ics and passes it. Re-issued from 143.
-- -----------------------------------------------------------------------------
create or replace function deliver_notification(p_notification_id uuid) returns bigint
language plpgsql security definer set search_path = public as $$
declare r record; v_transport text; v_ics text;
begin
  select * into r from render_notification(p_notification_id);

  if nullif(r.to_email, '') is null then
    raise exception 'notification % has no recipient address', p_notification_id
      using errcode = 'PT422',
            hint = 'Queued with no member, no staff user and no payload to_email. '
                   'Refused here rather than posting a null recipient to the provider.';
  end if;

  v_ics := notification_ics(p_notification_id);  -- null for non-calendar templates

  v_transport := notification_setting('transport');
  if v_transport = 'resend' then
    return send_via_resend(r.to_email, r.from_name, r.reply_to,
                           r.subject, r.text_body, r.html_body, v_ics);
  end if;
  raise exception 'unknown transport %', v_transport using errcode = 'PT501';
end $$;

-- -----------------------------------------------------------------------------
-- 6. booking_confirmed gains a Manage-this-booking link (login required — no
--    tokenised one-click cancel, which would be a pre-login write).
-- -----------------------------------------------------------------------------
update notification_templates set
  text_body = E'Hi {first_name},\n\nYou''re booked into {class_name} on {when}{where_line}.\n\nManage this booking: {manage_link}\n\nIf you can''t make it, cancel in the app and the place goes to someone on the list.\n\n{studio_name}',
  html_body = E'<p>Hi {first_name},</p><p>You''re booked into <strong>{class_name}</strong> on {when}{where_line}.</p><p><a href="{manage_link}">Manage this booking</a></p><p>If you can''t make it, cancel in the app and the place goes to someone on the list.</p>'
where key = 'booking_confirmed';

-- The instructor's per-booking email (opt-in). first_name resolves to the
-- instructor via render_notification's staff branch.
insert into notification_templates (key, subject, text_body, html_body) values
('booking_for_instructor', '{member_name} booked into {class_name}',
 E'Hi {first_name},\n\n{member_name} just booked into {class_name} on {when}.\n\nThe attached .ics adds it to your calendar. Subscribe to your calendar feed and the headcount stays up to date on its own.\n\n{studio_name}',
 E'<p>Hi {first_name},</p><p><strong>{member_name}</strong> just booked into <strong>{class_name}</strong> on {when}.</p><p>The attached .ics adds it to your calendar.</p>')
on conflict (key) do nothing;

-- -----------------------------------------------------------------------------
-- 7. queue_booking_notifications: payload carries booking_id, occurrence_id and
--    the manage link; and the class's instructor gets one email IF opted in.
--    Re-issued from migration 034.
-- -----------------------------------------------------------------------------
create or replace function queue_booking_notifications(p_booking_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare
  b bookings%rowtype; o class_occurrences%rowtype; m members%rowtype;
  st studio_settings%rowtype; s studios%rowtype;
  v_when text; v_where text; n int := 0; v_remind timestamptz;
  v_manage text; v_each boolean; v_instr_user uuid;
begin
  select * into b from bookings where id = p_booking_id;
  if not found or b.status <> 'booked' then return 0; end if;

  select * into o  from class_occurrences where id = b.occurrence_id;
  select * into m  from members            where id = b.member_id;
  select * into s  from studios            where id = b.studio_id;
  select * into st from studio_settings    where studio_id = b.studio_id;

  v_when  := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth, HH24:MI');
  v_where := coalesce((select ', in ' || r.name from rooms r where r.id = o.room_id), '');
  v_manage := 'https://' || s.slug || '.'
              || coalesce(notification_setting('member_app_domain'), 'studiior.app')
              || '/class/' || o.id;

  if queue_notification(b.studio_id, b.member_id, 'booking_confirmed',
        jsonb_build_object('class_name', o.name, 'when', v_when, 'where_line', v_where,
                           'manage_link', v_manage,
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

  -- Decision 33: the class's instructor gets one email per booking ONLY if they
  -- turned it on and can be reached. Off by default; keyed on the booking so it
  -- fires once. The .ics is the instructor VEVENT (headcount in the body).
  if o.instructor_id is not null then
    select i.email_each_booking, instructor_user_id(o.instructor_id)
      into v_each, v_instr_user
      from instructors i where i.id = o.instructor_id;
    if coalesce(v_each, false) and v_instr_user is not null then
      if queue_shift_notice(b.studio_id, v_instr_user, 'booking_for_instructor',
            jsonb_build_object('class_name', o.name, 'when', v_when,
                               'member_name', m.first_name, 'occurrence_id', o.id),
            'booking_for_instructor:' || b.id) is not null then n := n + 1; end if;
    end if;
  end if;

  return n;
end $$;

-- -----------------------------------------------------------------------------
-- 8. queue_class_moved: payload += occurrence_id. Re-issued from migration 048.
-- -----------------------------------------------------------------------------
create or replace function queue_class_moved(p_occurrence_id uuid, p_old_starts_at timestamptz)
returns int
language plpgsql security definer set search_path = public as $$
declare
  occ class_occurrences%rowtype; r record; v_tz text;
  v_when text; v_old text; v_where text; n int := 0;
begin
  select * into occ from class_occurrences where id = p_occurrence_id;
  select s.timezone into v_tz from studios s where s.id = occ.studio_id;

  v_when  := to_char(occ.starts_at   at time zone v_tz, 'FMDay FMDD FMMonth, HH24:MI');
  v_old   := to_char(p_old_starts_at at time zone v_tz, 'FMDay FMDD FMMonth, HH24:MI');
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
end $$;
revoke execute on function queue_class_moved(uuid, timestamptz) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 9. queue_occurrence_cancelled: payload += occurrence_id. Re-issued from 030.
-- -----------------------------------------------------------------------------
create or replace function queue_occurrence_cancelled(p_occurrence_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare o class_occurrences%rowtype; s studios%rowtype; r record; n int := 0; v_when text;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  select * into s from studios where id = o.studio_id;
  v_when := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth');

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
end $$;
-- Internal (a notifications suite asserts it is closed to clients); create-or-
-- replace kept the ACL, this re-states it.
revoke execute on function queue_occurrence_cancelled(uuid) from public, anon, authenticated;
grant  execute on function queue_occurrence_cancelled(uuid) to service_role;

-- -----------------------------------------------------------------------------
-- 10. queue_instructor_assigned: payload += occurrence_id. Re-issued from 117.
-- -----------------------------------------------------------------------------
create or replace function queue_instructor_assigned(p_occurrence_id uuid)
returns uuid
language plpgsql security definer set search_path = public as $$
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
      'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth, HH24:MI'),
      'where_line', case when v_room is null then '' else ' in ' || v_room end,
      'booked_line', case when o.booked_count > 0
        then format('%s member%s booked in so far.', o.booked_count,
                    case when o.booked_count = 1 then ' is' else 's are' end)
        else 'Nobody has booked yet.' end,
      'occurrence_id', o.id),
    'instructor_assigned:' || o.id || ':' || o.instructor_id || ':' || extract(epoch from o.starts_at)::bigint);
end $$;
-- Internal: called by the engine, cover approval and create/move (all SECURITY
-- DEFINER), never by a client. Closed to anon AND authenticated (a suite asserts
-- it) — create-or-replace kept the ACL, this just re-states it.
revoke execute on function queue_instructor_assigned(uuid) from public, anon, authenticated;
grant  execute on function queue_instructor_assigned(uuid) to service_role;

-- -----------------------------------------------------------------------------
-- 11. Add-to-calendar buttons — guarded client entry points to the builder.
-- -----------------------------------------------------------------------------
-- A member's own booked class. Requires a booking (nothing to add otherwise).
create or replace function member_class_ics(p_occurrence_id uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare o class_occurrences%rowtype; v_member uuid; v_ve text;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  select id into v_member from members
   where studio_id = o.studio_id and user_id = auth.uid();
  if v_member is null then
    raise exception 'you are not a member of that studio' using errcode = 'PT403';
  end if;
  v_ve := ics_member_vevent(p_occurrence_id, v_member, false);
  if v_ve is null then
    raise exception 'you have no booking for that class' using errcode = 'PT404';
  end if;
  return ics_calendar('PUBLISH', v_ve);
end $$;

-- An instructor's own class (or a manager's, for support). Headcount in the body.
create or replace function instructor_class_ics(p_occurrence_id uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare o class_occurrences%rowtype; v_ve text;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not (coalesce(is_manager_up(o.studio_id), false)
          or auth_instructor_id(o.studio_id) = o.instructor_id) then
    raise exception 'that is not your class' using errcode = 'PT403';
  end if;
  v_ve := ics_instructor_vevent(p_occurrence_id, false);
  return ics_calendar('PUBLISH', v_ve);
end $$;

-- An instructor's whole month, as one .ics — scheduled + published only
-- (Decision 25). The multi-event builder the feed (Part B) reuses.
create or replace function instructor_month_ics(p_studio_id uuid, p_month text) returns text
language plpgsql stable security definer set search_path = public as $$
declare v_instr uuid; v_tz text; v_from date; v_to date; v_events text;
begin
  v_instr := auth_instructor_id(p_studio_id);
  if v_instr is null and not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'that is not your schedule' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  v_from := to_date(p_month || '-01', 'YYYY-MM-DD');
  v_to   := (v_from + interval '1 month')::date;

  select string_agg(ics_instructor_vevent(o.id, false), E'\r\n' order by o.starts_at)
    into v_events
    from class_occurrences o
   where o.studio_id = p_studio_id
     and o.instructor_id = coalesce(v_instr, o.instructor_id)
     and o.status = 'scheduled'
     and (o.starts_at at time zone v_tz)::date >= v_from
     and (o.starts_at at time zone v_tz)::date < v_to
     and month_published(o.studio_id, o.starts_at);

  return ics_calendar('PUBLISH', coalesce(v_events, ''));
end $$;

revoke execute on function member_class_ics(uuid)               from public, anon;
revoke execute on function instructor_class_ics(uuid)           from public, anon;
revoke execute on function instructor_month_ics(uuid, text)     from public, anon;
grant  execute on function member_class_ics(uuid)               to authenticated;
grant  execute on function instructor_class_ics(uuid)           to authenticated;
grant  execute on function instructor_month_ics(uuid, text)     to authenticated;

-- -----------------------------------------------------------------------------
-- 12. The instructor toggles their own per-booking email (RLS on instructors is
--     manager-write, so an instructor cannot set it directly).
-- -----------------------------------------------------------------------------
create or replace function set_email_each_booking(p_studio_id uuid, p_on boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_instr uuid;
begin
  v_instr := auth_instructor_id(p_studio_id);
  if v_instr is null then
    raise exception 'that is not your setting' using errcode = 'PT403';
  end if;
  update instructors set email_each_booking = coalesce(p_on, false) where id = v_instr;
  return jsonb_build_object('ok', true, 'email_each_booking', coalesce(p_on, false));
end $$;
revoke execute on function set_email_each_booking(uuid, boolean) from public, anon;
grant  execute on function set_email_each_booking(uuid, boolean) to authenticated;
