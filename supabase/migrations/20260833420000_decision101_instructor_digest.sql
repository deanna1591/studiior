-- Decision 101 — instructor daily digest, and 80a polish on the instructor templates.
-- creates: instructor_digest_block(uuid, uuid, date)
-- re-issues: render_email(uuid, text, text, text, text, text, jsonb, text),
--   template_sample_context(uuid, text, text), evaluate_commitment(uuid),
--   tg_core_reached_minimum(), tg_flex_reached_minimum(),
--   force_commit_occurrence(uuid, text), sweep_commitments()
--
-- (a) THE DIGEST. sweep_commitments already sent one per-instructor digest per
--     pass (commitment_digest). Decision 101 re-keys it to ONE instructor_daily_
--     digest per instructor per class-start DATE, with two tables — "Going ahead"
--     and "Cancelled, not enough bookings" — built by instructor_digest_block
--     from the full picture for that (instructor, date), deduped on
--     instructor_digest:{instructor}:{date}, scheduled for the day's last cut-off.
--     It REPLACES two per-class instructor sends: core_committed (dropped from
--     tg_core_reached_minimum and force_commit_occurrence) and the
--     instructor_class_cancelled queued by evaluate_commitment for the
--     not-enough-bookings cause. instructor_class_cancelled still fires per class
--     for the OTHER causes (studio reason, instructor reason, beyond anyone's
--     control) from cancel_occurrences_for_period_run and close_studio — both of
--     which already carry occurrence_id, so the template re-dress below gives
--     those the time with no change to their senders. Members keep their own
--     per-booking emails. On the per-email switch (Decision 78e), on by default.
--     flex_going_ahead (the flex-tier twin of core_committed, the early-latch
--     "going ahead" email) is removed from tg_flex_reached_minimum for the same
--     reason — the digest is the one going-ahead channel for a flex studio too.
-- (b) POLISH. render_email resolves {class_when} ("Class on Day at time" + the
--     room only when the studio has more than one room) from occurrence_id, and
--     {schedule_link} (the instructor's own schedule) for a staff recipient, both
--     strip-exempt. Each editable instructor template's platform default is
--     re-dressed with an 80a card and a "See my schedule" accent button and reads
--     the class with its time. Reform's own overrides are Deanna's to rewrite
--     from drafts, so this writes platform defaults only. No em dashes.
-- No new anon RPC — THIRTEEN stays (asserted at the end).

-- -----------------------------------------------------------------------------
-- instructor_digest_block — the two tables for one instructor's one day. Service
-- only (sweep_commitments calls it). Returns the payload pieces the digest
-- template splices: n_running, n_cancelled, day, and each table as HTML and as
-- aligned text, or the one-line fallback when a table is empty.
-- -----------------------------------------------------------------------------
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
      || '<tr><td colspan="3" style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;color:#14170E;padding:0 0 6px 0">Going ahead</td></tr>'
      || '<tr><th ' || th || '>Time</th><th ' || th || '>Class</th><th ' || th || '>Booked</th></tr>'
      || v_run_rows || '</table>';
    v_go_text := 'Going ahead' || E'\n' || v_run_text;
  else
    v_go_html := '<p style="margin:12px 0">No classes going ahead.</p>';
    v_go_text := 'No classes going ahead.';
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

CREATE OR REPLACE FUNCTION public.render_email(p_studio_id uuid, p_template_key text, p_recipient_type text, p_subject text, p_text text, p_html text, p_payload jsonb, p_first_name text DEFAULT NULL::text)
 RETURNS TABLE(subject text, text_body text, html_body text, stripped text[])
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s studios%rowtype;
  v_is_staff boolean; v_sub text; v_txt text; v_html text; k text; rule text; v_on text;
  v_addr text; v_link text; v_contact text; v_contact_html text; v_ig text;
  v_always boolean; v_foot_txt text; v_foot_html text;
  v_logo text; v_fmt text; v_occ_id uuid; v_class_line text; v_class_when text;
  v_tok text; v_stripped text[] := '{}';
begin
  select * into s from studios where id = p_studio_id;
  select coalesce(time_format, '24h') into v_fmt from studio_settings where studio_id = p_studio_id;
  v_fmt := coalesce(v_fmt, '24h');
  v_is_staff := p_recipient_type = 'staff';
  v_sub := p_subject; v_txt := p_text; v_html := p_html;


  for k in select jsonb_object_keys(p_payload) loop
    v_sub  := replace(v_sub,  '{' || k || '}', coalesce(p_payload ->> k, ''));
    v_txt  := replace(v_txt,  '{' || k || '}', coalesce(p_payload ->> k, ''));
    v_html := replace(v_html, '{' || k || '}', coalesce(p_payload ->> k, ''));
  end loop;
  for k in select unnest(array['first_name','studio_name']) loop
    v_sub  := replace(v_sub,  '{' || k || '}',
                      case k when 'first_name'
                             then coalesce(p_first_name, 'there')
                             else s.name end);
    v_txt  := replace(v_txt,  '{' || k || '}',
                      case k when 'first_name'
                             then coalesce(p_first_name, 'there')
                             else s.name end);
    v_html := replace(v_html, '{' || k || '}',
                      case k when 'first_name'
                             then coalesce(p_first_name, 'there')
                             else s.name end);
  end loop;

  -- Decision 80a fix: the class card's ONE detail line, built from the occurrence
  -- so every class email reads the same — Day · time · room · with {instructor},
  -- times via fmt_clock in the studio format, missing parts dropped cleanly.
  v_occ_id := nullif(p_payload ->> 'occurrence_id', '')::uuid;
  if v_occ_id is not null then
    select concat_ws(' · ',
             nullif(to_char(o.starts_at at time zone s.timezone, 'FMDy FMDD FMMon'), ''),
             fmt_clock(o.starts_at, s.timezone, v_fmt),
             nullif(rm.name, ''),
             nullif('with ' || split_part(coalesce(i.display_name, ''), ' ', 1), 'with '))
      into v_class_line
      from class_occurrences o
      left join rooms rm on rm.id = o.room_id
      left join instructors i on i.id = o.instructor_id
     where o.id = v_occ_id;
  end if;
  v_sub  := replace(v_sub,  '{class_line}', coalesce(v_class_line, ''));
  v_txt  := replace(v_txt,  '{class_line}', coalesce(v_class_line, ''));
  v_html := replace(v_html, '{class_line}', coalesce(v_class_line, ''));

  -- Decision 101: {class_when} — the instructor-facing class line, "Class on Day
  -- at time" plus the room ONLY when the studio has more than one. Resolved from
  -- occurrence_id, so every instructor template that carries it reads the same,
  -- and the room rule lives in one place. Known-optional (strip-exempt below).
  if v_occ_id is not null then
    select coalesce(o.name, ct.name, 'your class') || ' on '
           || to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth')
           || ' at ' || fmt_clock(o.starts_at, s.timezone, v_fmt)
           || case when (select count(*) from rooms where studio_id = s.id and status = 'active') > 1
                     and nullif(rm.name, '') is not null then ' in ' || rm.name else '' end
      into v_class_when
      from class_occurrences o
      left join class_types ct on ct.id = o.class_type_id
      left join rooms rm on rm.id = o.room_id
     where o.id = v_occ_id;
  end if;
  v_sub  := replace(v_sub,  '{class_when}', coalesce(v_class_when, ''));
  v_txt  := replace(v_txt,  '{class_when}', coalesce(v_class_when, ''));
  v_html := replace(v_html, '{class_when}', coalesce(v_class_when, ''));

  -- Decision 101: {schedule_link} — the instructor's own schedule. Filled for a
  -- staff recipient when the payload did not already supply it (the digest and a
  -- test send supply their own). Known-optional (strip-exempt below).
  if v_is_staff then
    v_sub  := replace(v_sub,  '{schedule_link}', instructor_portal_url(s.id, '/instructor/schedule'));
    v_txt  := replace(v_txt,  '{schedule_link}', instructor_portal_url(s.id, '/instructor/schedule'));
    v_html := replace(v_html, '{schedule_link}', instructor_portal_url(s.id, '/instructor/schedule'));
  end if;

  -- Accent (80a): a static template button carries {accent}/{accent_on}.
  rule := coalesce(s.accent_color, '#78716C');
  v_on := email_on_accent(rule);
  v_html := replace(replace(v_html, '{accent_on}', v_on), '{accent}', rule);
  v_txt  := replace(replace(v_txt,  '{accent_on}', v_on), '{accent}', rule);

  -- STRIP any residual {token}: a known-optional one silently, anything else to
  -- empty AND recorded in `stripped` (deliver_notification logs it). No token
  -- ever reaches a member.
  for v_tok in
    select distinct (regexp_matches(coalesce(v_sub,'') || E'\n' || coalesce(v_txt,'') || E'\n' || coalesce(v_html,''),
                                    '\{([a-z_][a-z0-9_]*)\}', 'g'))[1]
  loop
    if not (v_tok = any (array['where_line','free_first_line','free_first_html',
                               'next_three_line','next_three_html','system_text','system_html','class_line',
                               'class_when','schedule_link'])) then
      v_stripped := array_append(v_stripped, v_tok);
    end if;
    v_sub  := replace(v_sub,  '{' || v_tok || '}', '');
    v_txt  := replace(v_txt,  '{' || v_tok || '}', '');
    v_html := replace(v_html, '{' || v_tok || '}', '');
  end loop;

  select nullif(concat_ws(', ',
           nullif(l.address ->> 'line1', ''), nullif(l.address ->> 'line2', ''),
           nullif(l.address ->> 'city', ''), nullif(l.address ->> 'postal_code', ''),
           nullif(l.address ->> 'country', '')), '')
    into v_addr
    from locations l
   where l.studio_id = s.id and l.status = 'active'
   order by l.is_primary desc, l.created_at limit 1;

  if v_is_staff then
    v_link := coalesce(nullif(notification_setting('staff_app_origin'), ''),
                       'https://app.studiior.com') || '/billing';
  else
  v_link := 'https://' || s.slug || '.'
            || coalesce(notification_setting('member_app_domain'), 'studiior.app') || '/settings';
  end if;

  v_ig := nullif(s.instagram_handle, '');
  v_contact := nullif(concat_ws(' · ', s.contact_email, s.contact_phone,
                 case when v_ig is not null then '@' || v_ig else null end), '');
  v_contact_html := nullif(concat_ws(' · ', s.contact_email, s.contact_phone,
                 case when v_ig is not null
                      then '<a href="https://instagram.com/' || v_ig || '" style="color:#78716C">@' || v_ig || '</a>'
                      else null end), '');

  v_always := p_template_key in ('class_cancelled', 'instructor_substituted',
                                 'guest_invite', 'guest_host_cancelled',
                                 'guest_waiver_reminder', 'guest_waiver_host_nudge',
                                 'member_invite', 'payment_failed', 'staff_message',
                                 'platform_billing_warning', 'class_moved',
                                 'shift_application_received', 'shift_approved',
                                 'shift_declined', 'shift_withdrawn');

  v_foot_txt := concat_ws(E'\n',
    v_contact, v_addr,
    case when v_is_staff then 'Your billing: ' || v_link
         when p_template_key in ('member_invite', 'instructor_invite', 'guest_invite', 'guest_waiver_reminder')
         then 'You are getting this because ' || s.name || ' set up your account.'
         when v_always
         then 'We always send this one — it''s about your booking or your membership. '
              || 'Choose which other emails you get: ' || v_link
         else 'Choose which emails you get: ' || v_link end);

  v_foot_html := concat_ws('<br>',
    v_contact_html, v_addr,
    case when v_is_staff then '<a href="' || v_link || '" style="color:#78716C">Your billing</a>'
         when p_template_key in ('member_invite', 'instructor_invite', 'guest_invite', 'guest_waiver_reminder')
         then 'You are getting this because ' || s.name || ' set up your account.'
         when v_always
         then 'We always send this one — it''s about your booking or your membership. '
              || '<a href="' || v_link || '" style="color:#78716C">Choose which other emails you get</a>'
         else '<a href="' || v_link || '" style="color:#78716C">Choose which emails you get</a>' end);

  v_logo := case when s.logo_url is not null
    then '<img src="' || s.logo_url || '" alt="' || replace(s.name, '"', '')
         || '" width="40" height="40" style="display:block;border:0;border-radius:6px" />'
    else '<div style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;'
         || 'font-weight:600;font-size:18px;color:#14170E">' || s.name || '</div>' end;

  -- The FLUID frame. The content table ("sd-card") is width 100% / max-width 600px
  -- so it reflows on a phone; the <style> media query shrinks the padding and body
  -- text under 480px and caps images; the MSO ghost table stays 600 for Outlook.
  return query select v_sub, v_txt || E'\n\n--\n' || v_foot_txt,
    '<style>'
      || '.sd-body img{max-width:100%;height:auto}'
      || '@media only screen and (max-width:480px){'
      || '.sd-card{width:100%!important;border-radius:0!important}'
      || '.sd-pad{padding-left:16px!important;padding-right:16px!important}'
      || '.sd-body{font-size:14px!important;line-height:22px!important}'
      || '}'
      || '</style>'
      || '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" '
      || 'style="background:#F5F5F4;margin:0;padding:0;width:100%"><tr>'
      || '<td align="center" style="padding:24px 12px">'
      || '<!--[if mso]><table role="presentation" width="600" cellspacing="0" cellpadding="0" border="0"><tr><td><![endif]-->'
      || '<table role="presentation" width="100%" class="sd-card" cellspacing="0" cellpadding="0" border="0" '
      || 'style="width:100%;max-width:600px;background:#FFFFFF;border-radius:12px">'
      || '<tr><td class="sd-pad" style="padding:28px 28px 0 28px">'
      || v_logo
      || '<div style="height:3px;width:44px;background:' || rule || ';margin:16px 0 4px"></div>'
      || '</td></tr>'
      || '<tr><td class="sd-pad sd-body" style="padding:12px 28px 8px 28px;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;'
      || 'font-size:15px;line-height:22px;color:#14170E">'
      || v_html
      || '</td></tr>'
      || '<tr><td class="sd-pad" style="padding:16px 28px 28px 28px">'
      || '<div style="border-top:1px solid #E7E5E4;padding-top:14px;'
      || 'font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;'
      || 'font-size:13px;line-height:18px;color:#78716C">' || v_foot_html || '</div>'
      || '</td></tr></table>'
      || '<!--[if mso]></td></tr></table><![endif]-->'
      || '</td></tr></table>',
    v_stripped;
end $function$

;

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
begin
  select * into s from studios where id = p_studio_id;
  select * into st from studio_settings where studio_id = p_studio_id;
  v_tz := s.timezone; v_fmt := coalesce(st.time_format, '24h');

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
  -- Decision 89: the Messages templates' tokens, so a test send / preview fills.
  || jsonb_build_object(
    'staff_first_name', p_first_name,
    'member_name', coalesce(nullif(p_first_name, ''), 'A member'),
    'message', 'Hi, could I move my Saturday class to Sunday?',
    'message_html', 'Hi, could I move my Saturday class to Sunday?',
    'messages_url', member_portal_url(p_studio_id, '/messages'),
    'reply_url', coalesce(nullif(notification_setting('staff_app_origin'), ''), 'https://app.studiior.com') || '/messages')
  || jsonb_build_object(
    -- Decision 92: the rebook email's two extra tokens.
    'old_class_name', coalesce(o.cname, 'a class'),
    'bookings_url', member_portal_url(p_studio_id, '/'))
  || jsonb_build_object(
    -- Decision 95: the flex-rescue tokens.
    'class_name', coalesce(o.cname, 'a class'),
    'day', to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMonth'),
    'n_more', 2,
    'cutoff_time', coalesce(v_when, 'the cut-off'),
    'class_list_core', '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:12px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-size:16px;font-weight:600;color:#14170E">' || coalesce(o.cname, 'a class') || '</div><div style="font-size:14px;color:#57534E;margin-top:4px">' || coalesce(v_when, 'soon') || '</div><div style="font-size:13px;color:#78716C;margin-top:2px">3 in already · 4 spots left</div><table role="presentation" style="margin-top:12px"><tr><td style="border-radius:6px;background:{accent}"><a href="#" style="display:inline-block;padding:10px 20px;color:{accent_on};text-decoration:none;font-weight:600;border-radius:6px">Move me to this class</a></td></tr></table></td></tr></table>',
    'class_list_core_text', '- ' || coalesce(o.cname, 'a class') || ' · ' || coalesce(v_when, 'soon') || ' (3 in already, 4 spots left)')
  -- Decision 101: instructor_daily_digest sample — two small tables so the
  -- Templates preview and a test send render a real-looking digest.
  || jsonb_build_object(
    'n_running', 2, 'n_cancelled', 1,
    'pay_line', 'You''re paid on who''s checked in.',
    'going_ahead', '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:12px 0;border-collapse:collapse"><tr><td colspan="3" style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;color:#14170E;padding:0 0 6px 0">Going ahead</td></tr><tr><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Time</th><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Class</th><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Booked</th></tr><tr><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">' || fmt_clock(((now() at time zone v_tz)::date + time '07:00') at time zone v_tz, v_tz, v_fmt) || '</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">Reformer Flow</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">4 of 6</td></tr><tr><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">' || fmt_clock(((now() at time zone v_tz)::date + time '18:00') at time zone v_tz, v_tz, v_fmt) || '</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">Barre</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">5 of 8</td></tr></table>',
    'going_ahead_text', 'Going ahead' || E'\n  ' || fmt_clock(((now() at time zone v_tz)::date + time '07:00') at time zone v_tz, v_tz, v_fmt) || '  Reformer Flow  4 of 6' || E'\n  ' || fmt_clock(((now() at time zone v_tz)::date + time '18:00') at time zone v_tz, v_tz, v_fmt) || '  Barre  5 of 8',
    'cancelled', '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:12px 0;border-collapse:collapse"><tr><td colspan="3" style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;color:#14170E;padding:0 0 6px 0">Cancelled, not enough bookings</td></tr><tr><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Time</th><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Class</th><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Booked</th></tr><tr><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">' || fmt_clock(((now() at time zone v_tz)::date + time '09:00') at time zone v_tz, v_tz, v_fmt) || '</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">Mat Pilates</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">1 of 3 needed</td></tr></table>',
    'cancelled_text', 'Cancelled, not enough bookings' || E'\n  ' || fmt_clock(((now() at time zone v_tz)::date + time '09:00') at time zone v_tz, v_tz, v_fmt) || '  Mat Pilates  1 of 3 needed');
end $function$

;

CREATE OR REPLACE FUNCTION public.evaluate_commitment(p_occurrence_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o class_occurrences%rowtype; g record; v_booked int; s studios%rowtype; r record; v_iu uuid;
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
     and status in ('booked','attended','no_show','pending_payment')
     -- Decision 81b: an UNPAID drop-in (the pay_first predicate) holds its
     -- seat but is not counted here, so it never keeps a class alive and
     -- never adds to the pay headcount until it is paid.
     and not (coalesce(bookings.payment_source = 'drop_in', false)
              and not exists (select 1 from payments pmt
                               where pmt.booking_id = bookings.id
                                 and pmt.status in ('succeeded','partially_refunded')));

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
                  -- Decision 81b: do not tell an unpaid drop-in the flex class
                  -- is confirmed on the strength of their own unpaid seat.
                  and not (coalesce(bookings.payment_source = 'drop_in', false)
                           and not exists (select 1 from payments pmt
                                            where pmt.booking_id = bookings.id
                                              and pmt.status in ('succeeded','partially_refunded')))
      loop
        perform queue_notification(o.studio_id, r.member_id, 'flex_booking_confirmed',
          jsonb_build_object('class_name', o.name,
            'day',  to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth'),
            'time', fmt_clock(o.starts_at, s.timezone,
                     coalesce((select time_format from studio_settings where studio_id = o.studio_id), '24h')),
            -- Decision 21 amendment (20 Oct 2026): plain words read {when} and
            -- {studio_name} — "See you {when} at {studio}".
            'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth') || ' at '
                    || fmt_clock(o.starts_at, s.timezone,
                         coalesce((select time_format from studio_settings where studio_id = o.studio_id), '24h')),
            'studio_name', s.name,
            'manage_link', member_portal_url(o.studio_id, '/class/' || p_occurrence_id),
            'book_url', member_portal_url(o.studio_id, '/book'),
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

  -- Decision 101: the assigned instructor is told via the daily digest at the
  -- cut-off, not a per-class email. (A queue_shift_notice of
  -- instructor_class_cancelled stood here for the not-enough-bookings cause;
  -- removed — sweep_commitments' instructor_daily_digest covers it. The member
  -- flex_booking_not_confirmed, queued inside cancel_occurrence above, stays.)

  return jsonb_build_object('ok', true, 'decision', 'not_running',
    'tier', g.tier, 'booked_at_cutoff', v_booked, 'minimum', g.minimum);
end $function$

;

CREATE OR REPLACE FUNCTION public.tg_core_reached_minimum()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare g record;
begin
  -- Cheap exits: only a scheduled, uncommitted, not-yet-latched class with an
  -- instructor to tell is a candidate. (No flex check: a class is core or flex,
  -- and the tier gate below decides.)
  if new.status <> 'scheduled'
     or new.committed_at is not null
     or new.core_reached_minimum_at is not null
     or new.instructor_id is null then
    return new;
  end if;

  select * into g from occurrence_guarantee_run(new.id) g;
  -- Only a class that BEHAVES as core (guarantees switch on) has a minimum to
  -- reach; occurrence_guarantee demotes a core class at a guarantees-off studio
  -- to 'always', correctly ignored here.
  if g.tier is distinct from 'core' or g.minimum is null or new.booked_count < g.minimum then
    return new;
  end if;

  -- The latch is stamped (other code reads core_reached_minimum_at); Decision 101
  -- removes the per-class core_committed email to the instructor — they learn a
  -- class is going ahead from sweep_commitments' instructor_daily_digest at the
  -- cut-off, not at the first booking.
  update class_occurrences set core_reached_minimum_at = now()
   where id = new.id and core_reached_minimum_at is null;

  return new;
end $function$

;

CREATE OR REPLACE FUNCTION public.tg_flex_reached_minimum()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare g record; v_paid int;
begin
  -- Cheap exits first: only a flex, scheduled, uncommitted, not-yet-latched
  -- class with somebody to tell is a candidate.
  if not coalesce(new.flex, false)
     or new.status <> 'scheduled'
     or new.committed_at is not null
     or new.flex_reached_minimum_at is not null
     or new.instructor_id is null then
    return new;
  end if;

  select * into g from occurrence_guarantee_run(new.id) g;
  -- Decision 81b: the latch (Decision 21) is set by PAID seats only, so an
  -- unpaid drop-in (the pay_first predicate) does not make a flex class go
  -- ahead or email the instructor. booked_count still counts the held seat
  -- for capacity; only this decision excludes it.
  select count(*)::int into v_paid from bookings
   where occurrence_id = new.id
     and status in ('booked','attended','no_show','pending_payment')
     and not (coalesce(bookings.payment_source = 'drop_in', false)
              and not exists (select 1 from payments pmt
                               where pmt.booking_id = bookings.id
                                 and pmt.status in ('succeeded','partially_refunded')));
  -- Only a class that BEHAVES as flex (studio switch on) has a minimum to
  -- reach; occurrence_guarantee demotes a flex class at a flex-off studio to
  -- 'always', which is correctly ignored here.
  if g.tier is distinct from 'flex' or g.minimum is null or v_paid < g.minimum then
    return new;
  end if;

  -- The latch is stamped (the commit sweep and other code read it); Decision 101
  -- removes the per-class flex_going_ahead email — flex_going_ahead was the
  -- flex-tier twin of core_committed, and the instructor now learns a class is
  -- going ahead from sweep_commitments' instructor_daily_digest at the cut-off,
  -- not at the first booking that crosses the minimum.
  update class_occurrences set flex_reached_minimum_at = now()
   where id = new.id and flex_reached_minimum_at is null;

  return new;
end $function$

;

CREATE OR REPLACE FUNCTION public.force_commit_occurrence(p_occurrence_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o class_occurrences%rowtype; v_booked int;
begin
  select * into o from class_occurrences where id = p_occurrence_id for update;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(o.studio_id), false) then
    raise exception 'only owners and managers force a class to run' using errcode = 'PT403';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'say why — a forced commitment with no reason is one nobody can explain'
      using errcode = 'PT422';
  end if;
  if o.committed_at is not null then
    raise exception '"%" is already committed', o.name using errcode = 'PT409';
  end if;

  select count(*)::int into v_booked from bookings
   where occurrence_id = p_occurrence_id
     and status in ('booked','attended','no_show','pending_payment');

  -- Reviving a class that was cancelled brings back its slot and its room, so
  -- it goes back to 'scheduled' explicitly rather than only gaining a latch.
  update class_occurrences
     set status = 'scheduled', committed_at = now(), booked_at_cutoff = v_booked,
         cancelled_at = null, cancellation_cause = null, cancellation_pays = null,
         updated_at = now()
   where id = p_occurrence_id;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (o.studio_id, auth.uid(), 'occurrence.force_committed', 'class_occurrences',
          p_occurrence_id,
          jsonb_build_object('status', o.status, 'cause', o.cancellation_cause,
                             'booked_at_cutoff', o.booked_at_cutoff),
          jsonb_build_object('reason', btrim(p_reason), 'booked_at_cutoff', v_booked,
                             'at', now()));

  -- Decision 101: core_committed no longer emails the instructor. A force-commit
  -- sets committed_at, so the class shows as "going ahead" in the instructor's
  -- daily digest if the cut-off sweep decides any of their classes that day; the
  -- manager did this deliberately and the instructor also sees it in their app.
  -- (The Decision 72(b) queue_shift_notice of core_committed stood here.)

  return jsonb_build_object('ok', true, 'occurrence_id', p_occurrence_id,
    'booked_at_cutoff', v_booked, 'reason', btrim(p_reason));
end $function$

;

CREATE OR REPLACE FUNCTION public.sweep_commitments()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  st record; r record; d record; v_job uuid; v_tz text;
  n_comm int := 0; n_not int := 0; n_studios int := 0; n_told int := 0; n_start int := 0;
  v_res jsonb; v_key text; v_block jsonb; v_payload jsonb;
  v_maxcut timestamptz; v_sched timestamptz;
begin
  if not is_service_context() then
    raise exception 'the commitment sweep is a background job' using errcode = 'PT403';
  end if;

  for st in
    select s.id, s.name, s.timezone
      from studios s
      join studio_settings cfg on cfg.studio_id = s.id
     where s.status = 'active'
       and (coalesce(cfg.guarantees_enabled, false) or coalesce(cfg.flex_enabled, false))
     order by s.id
  loop
    n_studios := n_studios + 1;
    v_tz := st.timezone;

    -- job_runs RECORDS the pass and counts attempts. It does not gate it: core's
    -- cutoff is a rolling offset, so there is a decision point at every hour of
    -- the day, and a once-a-day claim would answer only the first of them. The
    -- idempotency is each occurrence's own state.
    insert into job_runs (job_key, run_for, status)
    values ('commitments:' || st.id, (now() at time zone v_tz)::date, 'running')
    on conflict (job_key, run_for) do update
       set attempts = job_runs.attempts + 1, started_at = now(), status = 'running'
    returning id into v_job;

    -- What this pass decided, per instructor and per the class's STUDIO-LOCAL
    -- START DATE — so the digest is one email per instructor per day (Decision
    -- 101), not one per pass. occ_date is the day the digest is "for".
    create temporary table if not exists _decided (
      instructor_id uuid, user_id uuid, occ_id uuid, occ_date date, decision text
    ) on commit drop;
    delete from _decided;

    for r in select * from commitment_pending(st.id) where past_due loop
      v_res := evaluate_commitment(r.occ_id);
      if v_res ? 'decision' then
        if v_res ->> 'decision' = 'committed' then n_comm := n_comm + 1;
        else n_not := n_not + 1; end if;
        insert into _decided values (
          r.instructor_id, instructor_user_id(r.instructor_id), r.occ_id,
          (select (o.starts_at at time zone v_tz)::date
             from class_occurrences o where o.id = r.occ_id),
          v_res ->> 'decision');
      end if;
    end loop;

    -- Decision 101: ONE instructor_daily_digest per instructor with a login per
    -- class-start date that had a class decided this pass. The payload is rebuilt
    -- from the full picture for that (instructor, date) — committed classes and
    -- unmet-minimum cancellations — so later passes that decide another class on
    -- the same day refresh a still-pending digest rather than sending a second.
    -- DEDUPED ON (instructor, date). Scheduled for the LATEST cut-off among the
    -- instructor's classes that day, so it delivers once, complete, after the
    -- last class is decided (the evening-before shape lands in one pass; the
    -- rolling-core shape fills in across passes and delivers at the last cutoff).
    for d in
      select distinct instructor_id, user_id, occ_date
        from _decided _d
       where user_id is not null and occ_date is not null
    loop
      v_block := instructor_digest_block(st.id, d.instructor_id, d.occ_date);

      select max(g.cutoff_at) into v_maxcut
        from class_occurrences o
        cross join lateral occurrence_guarantee_run(o.id) g
       where o.studio_id = st.id and o.instructor_id = d.instructor_id
         and (o.starts_at at time zone v_tz)::date = d.occ_date
         and o.status in ('scheduled','cancelled')
         and g.cutoff_at is not null;
      v_sched := greatest(now(), coalesce(v_maxcut, now()));

      v_payload := v_block || jsonb_build_object(
        'instructor_name', coalesce((select display_name from instructors i where i.id = d.instructor_id), 'there'),
        'studio_name', st.name,
        -- The pay line already used today ("you're paid on who's checked in").
        'pay_line', 'You''re paid on who''s checked in.',
        'schedule_link', instructor_portal_url(st.id, '/instructor/schedule'));

      v_key := 'instructor_digest:' || d.instructor_id || ':' || d.occ_date;
      if studio_template_enabled(st.id, 'instructor_daily_digest') then
        insert into notifications (studio_id, recipient_type, user_id, template_key,
                                   channel, payload, dedupe_key, scheduled_for, status)
        values (st.id, 'staff', d.user_id, 'instructor_daily_digest', 'email',
                v_payload, v_key, v_sched, 'scheduled')
        on conflict (dedupe_key) do update
           set payload = excluded.payload, scheduled_for = excluded.scheduled_for
         where notifications.status = 'scheduled';
        n_told := n_told + 1;
      end if;
    end loop;

    -- DECISION 32: true up committed classes that have started. A late booker
    -- after the pay cutoff adds a body the commit snapshot never saw; the
    -- greater-of pays for them. Stamped once (booked_at_start null is the gate),
    -- so a re-run is a no-op. `always` classes match too and cost nothing — their
    -- cutoff count already IS the start count, so the delta is zero.
    for r in
      select o.id
        from class_occurrences o
       where o.studio_id = st.id
         and o.status = 'scheduled'
         and o.committed_at is not null
         and o.booked_at_start is null
         and o.starts_at <= now()
    loop
      perform snapshot_start_headcount(r.id);
      n_start := n_start + 1;
    end loop;

    update job_runs set status = 'done', finished_at = now(), error = null where id = v_job;
  end loop;

  return jsonb_build_object('studios', n_studios, 'committed', n_comm,
                            'not_running', n_not, 'instructors_told', n_told,
                            'start_snapshots', n_start);
end $function$

;

-- -----------------------------------------------------------------------------
-- The new digest template, and the 80a re-dress of the instructor templates.
-- Platform defaults only. Buttons use {accent}/{accent_on} (filled by
-- render_email). No em dashes. month_roster, month_roster_plain and
-- instructor_closure_notice already carry their own action link and class list,
-- so they are left for Deanna's overrides.
-- -----------------------------------------------------------------------------

insert into notification_templates (key, subject, text_body, html_body, note) values
('instructor_daily_digest',
 'Your classes for {day}: {n_running} going ahead, {n_cancelled} cancelled',
 E'Hi {first_name},\n\nHere''s how {day} looks.\n\n{going_ahead_text}\n\n{cancelled_text}\n\n{pay_line}\n\nSee my schedule: {schedule_link}\n\n{studio_name}',
 '<p>Hi {first_name},</p>
<p>Here&#39;s how {day} looks.</p>
{going_ahead}
{cancelled}
<p>{pay_line}</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{schedule_link}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">See my schedule</a></td></tr></table>
<p>{studio_name}</p>',
 'Decision 101. One per instructor per class-start date at the day''s cut-off: a Going ahead table and a Cancelled, not enough bookings table. Replaces the per-class core_committed and the unmet-minimum instructor_class_cancelled sends. On the per-email switch.')
on conflict (key) do update
  set subject = excluded.subject, text_body = excluded.text_body,
      html_body = excluded.html_body, note = excluded.note;

-- instructor_assigned — occurrence_id present, so {class_when} carries the time.
update notification_templates set
 text_body = E'Hi {first_name},\n\nYou''ve been put down to teach:\n\n{class_when}\n\n{booked_line}\n\nIf you can''t make it, ask the studio for cover as early as you can. You stay on the class until they find someone.\n\nSee my schedule: {schedule_link}\n\n{studio_name}',
 html_body = '<p>Hi {first_name},</p>
<p>You&#39;ve been put down to teach:</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{class_when}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">{booked_line}</div></td></tr></table>
<p>If you can&#39;t make it, ask the studio for cover as early as you can. You stay on the class until they find someone.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{schedule_link}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">See my schedule</a></td></tr></table>
<p>{studio_name}</p>'
where key = 'instructor_assigned';

-- instructor_class_cancelled — occurrence_id present; now reads the time via
-- {class_when}. Still fires per class for the non-bookings causes.
update notification_templates set
 text_body = E'Hi {first_name},\n\nThis class is cancelled:\n\n{class_when}\n\nReason: {reason}. You''re not expected to teach it.\n\nSee my schedule: {schedule_link}\n\n{studio_name}',
 html_body = '<p>Hi {first_name},</p>
<p>This class is cancelled:</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{class_when}</div></td></tr></table>
<p>Reason: {reason}. You&#39;re not expected to teach it.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{schedule_link}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">See my schedule</a></td></tr></table>
<p>{studio_name}</p>'
where key = 'instructor_class_cancelled';

-- booking_cancelled_committed — no occurrence_id; {when} already carries the time.
update notification_templates set
 subject = 'A member cancelled {class_name}, but it still runs',
 text_body = E'Hi {first_name},\n\nA member cancelled your {class_name} on {when}, but it still runs. Your pay is unchanged at {amount}.\n\nNothing to do.\n\nSee my schedule: {schedule_link}\n\n{studio_name}',
 html_body = '<p>Hi {first_name},</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{class_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">{when}</div></td></tr></table>
<p>A member cancelled, but it still runs. Your pay is unchanged at {amount}. Nothing to do.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{schedule_link}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">See my schedule</a></td></tr></table>
<p>{studio_name}</p>'
where key = 'booking_cancelled_committed';

-- cover_available — keeps its own Take-this-class action ({href}); the card
-- carries the class and its time.
update notification_templates set
 text_body = E'Hi {instructor_name},\n\n{studio_name} needs cover for {class_name} on {when}. It is soon, so whoever takes it first gets it.\n\n{booked_line}\n\nTake it: {href}',
 html_body = '<p>Hi {instructor_name},</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{class_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">{when}</div></td></tr></table>
<p>{studio_name} needs cover. It is soon, so whoever takes it first gets it. {booked_line}</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{href}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Take this class</a></td></tr></table>'
where key = 'cover_available';

-- instructor_class_ended_unmarked — no occurrence_id; {when} carries the time.
update notification_templates set
 subject = '{class_name} just finished: {count} not checked in',
 text_body = E'Hi {first_name},\n\n{class_name} ({when}) just finished and {count} of {booked} aren''t checked in. Mark them before midnight studio time or they count as no-shows. You''re paid on who''s checked in.\n\nSee my schedule: {schedule_link}\n\n{studio_name}',
 html_body = '<p>Hi {first_name},</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{class_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">{when}</div></td></tr></table>
<p>{count} of {booked} aren&#39;t checked in. Mark them before midnight studio time or they count as no-shows. You&#39;re paid on who&#39;s checked in.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{schedule_link}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">See my schedule</a></td></tr></table>
<p>{studio_name}</p>'
where key = 'instructor_class_ended_unmarked';

-- instructor_week_ahead — a list; gains the button and loses an em dash.
update notification_templates set
 subject = 'Your classes this week at {studio_name}',
 text_body = E'Hi {first_name},\n\nYour classes this week:\n\n{class_list}\n\nSee my schedule: {schedule_link}\n\nRemember to check everyone in. You''re paid on who''s checked in.\n\n{studio_name}',
 html_body = '<p>Hi {first_name},</p>
<p>Your classes this week:</p>
<p style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;white-space:pre-line">{class_list}</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{schedule_link}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">See my schedule</a></td></tr></table>
<p>Remember to check everyone in. You&#39;re paid on who&#39;s checked in.</p>
<p>{studio_name}</p>'
where key = 'instructor_week_ahead';

-- instructor_tomorrow — a list; gains the button.
update notification_templates set
 text_body = E'Hi {first_name},\n\nTomorrow:\n\n{class_list}\n\nSee my schedule: {schedule_link}\n\n{studio_name}',
 html_body = '<p>Hi {first_name},</p>
<p>Tomorrow:</p>
<p style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;white-space:pre-line">{class_list}</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{schedule_link}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">See my schedule</a></td></tr></table>
<p>{studio_name}</p>'
where key = 'instructor_tomorrow';

-- availability_due — no class; keeps its own Open-my-availability action ({href}).
update notification_templates set
 html_body = '<p>Hi {instructor_name},</p>
<p>{studio_name} needs your availability for {period} by {due_on}.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{href}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Open my availability</a></td></tr></table>
<p>Thank you,<br>{studio_name}</p>'
where key = 'availability_due';

-- ACLs re-asserted (create-or-replace preserves them; re-assert to be sure).
revoke execute on function render_email(uuid, text, text, text, text, text, jsonb, text) from public, anon, authenticated;
grant  execute on function render_email(uuid, text, text, text, text, text, jsonb, text) to service_role;
revoke execute on function template_sample_context(uuid, text, text) from public, anon, authenticated;
grant  execute on function template_sample_context(uuid, text, text) to service_role;
revoke execute on function evaluate_commitment(uuid) from public, anon, authenticated;
grant  execute on function evaluate_commitment(uuid) to authenticated, service_role;
revoke execute on function tg_core_reached_minimum() from public, anon, authenticated;
revoke execute on function tg_flex_reached_minimum() from public, anon, authenticated;
revoke execute on function force_commit_occurrence(uuid, text) from public, anon;
grant  execute on function force_commit_occurrence(uuid, text) to authenticated, service_role;
revoke execute on function sweep_commitments() from public, anon, authenticated;
grant  execute on function sweep_commitments() to service_role;

-- No new anon surface.
do $$ declare n int; begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % (want 13)', n; end if;
end $$;
