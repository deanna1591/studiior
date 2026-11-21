-- Step 11a (21 Nov 2026): the composer button marker `{button}` is our own
-- syntax, not a token. Reform's free_reservation_nudge / _last_call overrides
-- end the pay line with `[Pay {fee} to keep my spot]({pay_url}){button}`, and
-- render_email's strip loop dropped `{button}` (correct) but logged it as an
-- unresolved token, one render warning per send. The plain-text and HTML
-- output are unchanged; `button` joins the known-optional list so the strip is
-- silent.
--
-- re-issues: render_email(uuid, text, text, text, text, text, jsonb, text, text)
--
-- Re-issued byte-for-byte from its true newest definition
-- (20260833650000_step11_reservation_state_fee_choice.sql, line 1098) with ONE
-- change: 'button' appended to the known-optional array in the strip loop.
-- create or replace keeps the ACL (service-role only).

CREATE OR REPLACE FUNCTION public.render_email(p_studio_id uuid, p_template_key text, p_recipient_type text, p_subject text, p_text text, p_html text, p_payload jsonb, p_first_name text DEFAULT NULL::text, p_recipient_role text DEFAULT NULL::text)
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
  v_rows jsonb; v_rt_html text; v_rt_txt text; v_msg text;
begin
  select * into s from studios where id = p_studio_id;
  select coalesce(time_format, '24h') into v_fmt from studio_settings where studio_id = p_studio_id;
  v_fmt := coalesce(v_fmt, '24h');
  v_is_staff := p_recipient_type = 'staff';
  v_sub := p_subject; v_txt := p_text; v_html := p_html;

  -- Decision 89 (b): a studio message keeps its paragraphs. {message_html} is
  -- rebuilt from the plain message (a blank line is a paragraph, a single break
  -- a <br>, Windows line endings normalised); {message} keeps its breaks.
  if p_payload ? 'message' then
    v_msg := regexp_replace(replace(replace(p_payload ->> 'message', E'\r\n', E'\n'), E'\r', E'\n'),
                            E'\n{3,}', E'\n\n', 'g');
    v_html := replace(v_html, '{message_html}', message_paragraphs_html(p_payload ->> 'message'));
    v_txt  := replace(v_txt,  '{message}', v_msg);
  end if;

  -- Decision 80 note: {roster_table}, from the payload's rows or, for the month
  -- roster emails, from the instructor's published classes that month.
  if coalesce(v_html, '') like '%{roster_table}%' or coalesce(v_txt, '') like '%{roster_table}%' then
    if p_payload ? 'roster_rows' then
      v_rows := p_payload -> 'roster_rows';
    elsif p_payload ? 'instructor_id' and p_payload ? 'month_ym' then
      select coalesce(jsonb_agg(jsonb_build_object(
               'day', to_char(o.starts_at at time zone s.timezone, 'FMDy FMDD FMMon'),
               'time', fmt_clock(o.starts_at, s.timezone, v_fmt),
               'class', coalesce(o.name, ct.name, 'Class')) order by o.starts_at), '[]'::jsonb)
        into v_rows
        from class_occurrences o
        left join class_types ct on ct.id = o.class_type_id
       where o.studio_id = p_studio_id
         and o.instructor_id = (p_payload ->> 'instructor_id')::uuid
         and o.status = 'scheduled'
         and to_char(o.starts_at at time zone s.timezone, 'YYYY-MM') = p_payload ->> 'month_ym';
    end if;
    if v_rows is not null then
      select rt.html, rt.txt into v_rt_html, v_rt_txt from roster_table_render(v_rows) rt;
      v_html := replace(v_html, '{roster_table}', v_rt_html);
      v_txt  := replace(v_txt,  '{roster_table}', v_rt_txt);
      v_sub  := replace(v_sub,  '{roster_table}', '');
    end if;
  end if;


  for k in select jsonb_object_keys(p_payload) loop
    v_sub  := replace(v_sub,  '{' || k || '}', coalesce(p_payload ->> k, ''));
    v_txt  := replace(v_txt,  '{' || k || '}', coalesce(p_payload ->> k, ''));
    v_html := replace(v_html, '{' || k || '}', coalesce(p_payload ->> k, ''));
  end loop;
  -- Decision 80 note: {flex_min} and {flex_cutoff} in every email.
  v_sub  := replace(replace(v_sub,  '{flex_min}', coalesce((select flex_min_bookings::text from studio_settings where studio_id = p_studio_id), '2')), '{flex_cutoff}', coalesce(flex_cutoff_words(p_studio_id), ''));
  v_txt  := replace(replace(v_txt,  '{flex_min}', coalesce((select flex_min_bookings::text from studio_settings where studio_id = p_studio_id), '2')), '{flex_cutoff}', coalesce(flex_cutoff_words(p_studio_id), ''));
  v_html := replace(replace(v_html, '{flex_min}', coalesce((select flex_min_bookings::text from studio_settings where studio_id = p_studio_id), '2')), '{flex_cutoff}', coalesce(flex_cutoff_words(p_studio_id), ''));
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
                               'class_when','schedule_link','replaces_line','replaces_html','roster_table',
                               'button'])) then
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
    case when v_is_staff then case when p_recipient_role = 'owner' then 'Your billing: ' || v_link end
         when p_template_key in ('member_invite', 'instructor_invite', 'guest_invite', 'guest_waiver_reminder')
         then 'You are getting this because ' || s.name || ' set up your account.'
         when v_always
         then 'We always send this one. It is about your booking or your membership. '
              || 'Choose which other emails you get: ' || v_link
         else 'Choose which emails you get: ' || v_link end);

  v_foot_html := concat_ws('<br>',
    v_contact_html, v_addr,
    case when v_is_staff then case when p_recipient_role = 'owner' then '<a href="' || v_link || '" style="color:#78716C">Your billing</a>' end
         when p_template_key in ('member_invite', 'instructor_invite', 'guest_invite', 'guest_waiver_reminder')
         then 'You are getting this because ' || s.name || ' set up your account.'
         when v_always
         then 'We always send this one. It is about your booking or your membership. '
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
end $function$;

do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.proname not like 'expect\_%' and p.proname not in ('call_jsonb')
     and has_function_privilege('anon', p.oid, 'execute');
  if n <> 14 then raise exception 'anon surface is %, expected exactly fourteen', n; end if;
  if has_function_privilege('anon', 'public.render_email(uuid,text,text,text,text,text,jsonb,text,text)'::regprocedure, 'execute')
     or has_function_privilege('authenticated', 'public.render_email(uuid,text,text,text,text,text,jsonb,text,text)'::regprocedure, 'execute') then
    raise exception 'render_email must stay service-role only';
  end if;
end $$;
