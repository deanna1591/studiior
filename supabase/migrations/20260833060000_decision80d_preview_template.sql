-- Decision 80 amendment (80d) — one preview, the real frame, mobile and desktop.
-- creates: render_email(uuid, text, text, text, text, text, jsonb, text), template_sample_context(uuid, text, text), preview_template(uuid, text, text, text)
-- re-issues: render_notification(uuid), send_template_test(uuid, text)
--
-- The composer's hand-built React frame could disagree with what members receive.
-- render_email is the ONE substitution + strip + frame + footer core, lifted from
-- render_notification so a body rendered either way is byte-identical; preview_template
-- renders a draft through it with the studio's sample context and writes NO notification
-- row (so a live preview never queues mail); not anon — THIRTEEN stays.


-- render_email — Decision 80d: the ONE substitution + strip + frame + footer core.
-- Lifted verbatim from render_notification (20260832890000) so a body it renders
-- is byte-identical; render_notification now wraps the recipient/from/reply-to
-- around this, and preview_template calls it with a draft body + sample context.
create or replace function render_email(
  p_studio_id     uuid,
  p_template_key  text,
  p_recipient_type text,
  p_subject       text,
  p_text          text,
  p_html          text,
  p_payload       jsonb,
  p_first_name    text default null
) returns table(subject text, text_body text, html_body text, stripped text[])
language plpgsql stable security definer set search_path = public as $function$
declare
  s studios%rowtype;
  v_is_staff boolean; v_sub text; v_txt text; v_html text; k text; rule text; v_on text;
  v_addr text; v_link text; v_contact text; v_contact_html text; v_ig text;
  v_always boolean; v_foot_txt text; v_foot_html text;
  v_logo text; v_fmt text; v_occ_id uuid; v_class_line text;
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
                               'next_three_line','next_three_html','system_text','system_html','class_line'])) then
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

  return query select v_sub, v_txt || E'\n\n--\n' || v_foot_txt,
    '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" '
      || 'style="background:#F5F5F4;margin:0;padding:0;width:100%"><tr>'
      || '<td align="center" style="padding:24px 12px">'
      || '<!--[if mso]><table role="presentation" width="600" cellspacing="0" cellpadding="0" border="0"><tr><td><![endif]-->'
      || '<table role="presentation" width="600" cellspacing="0" cellpadding="0" border="0" '
      || 'style="width:600px;max-width:600px;background:#FFFFFF;border-radius:12px">'
      || '<tr><td style="padding:28px 28px 0 28px">'
      || v_logo
      || '<div style="height:3px;width:44px;background:' || rule || ';margin:16px 0 4px"></div>'
      || '</td></tr>'
      || '<tr><td style="padding:12px 28px 8px 28px;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;'
      || 'font-size:15px;line-height:22px;color:#14170E">'
      || v_html
      || '</td></tr>'
      || '<tr><td style="padding:16px 28px 28px 28px">'
      || '<div style="border-top:1px solid #E7E5E4;padding-top:14px;'
      || 'font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;'
      || 'font-size:13px;line-height:18px;color:#78716C">' || v_foot_html || '</div>'
      || '</td></tr></table>'
      || '<!--[if mso]></td></tr></table><![endif]-->'
      || '</td></tr></table>',
    v_stripped;
end $function$;
revoke execute on function render_email(uuid, text, text, text, text, text, jsonb, text) from public, anon, authenticated;
grant  execute on function render_email(uuid, text, text, text, text, text, jsonb, text) to service_role;


-- template_sample_context — Decision 80d: the ONE complete sample payload (lifted
-- from send_template_test). Both send_template_test and preview_template call it
-- so the test send and the live preview carry the same filled tokens.
create or replace function template_sample_context(p_studio_id uuid, p_to_email text, p_first_name text)
returns jsonb language plpgsql stable security definer set search_path = public as $function$
declare
  s studios%rowtype; st studio_settings%rowtype; v_tz text; v_fmt text;
  v_plan membership_plans%rowtype; o record; v_when text; v_offer_ends text;
begin
  select * into s from studios where id = p_studio_id;
  select * into st from studio_settings where studio_id = p_studio_id;
  v_tz := s.timezone; v_fmt := coalesce(st.time_format, '24h');

  -- The next scheduled class (for the class card). Null-safe when none.
  select o2.id, coalesce(ct.name, o2.name, 'a class') as cname, o2.starts_at,
         rm.name as room, split_part(coalesce(i.display_name, ''), ' ', 1) as instr
    into o
    from class_occurrences o2
    left join class_types ct on ct.id = o2.class_type_id
    left join rooms rm on rm.id = o2.room_id
    left join instructors i on i.id = o2.instructor_id
   where o2.studio_id = p_studio_id and o2.status = 'scheduled' and o2.starts_at > now()
   order by o2.starts_at limit 1;

  -- The offer plan: the intro offer when set, else the first active plan.
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

  -- A COMPLETE context — every token any member-facing template uses.
  return jsonb_build_object(
    'to_email', p_to_email,
    'first_name', p_first_name,
    'studio_name', s.name,
    -- class
    'class_name', coalesce(o.cname, 'a class'),
    'occurrence_id', o.id,
    'when', v_when,
    'where_line', case when nullif(o.room, '') is not null then ', in ' || o.room else '' end,
    'when_short', 'tomorrow',
    'when_time', case when o.starts_at is not null then fmt_clock(o.starts_at, v_tz, v_fmt) else '' end,
    'day', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDay') else 'Monday' end,
    'time', case when o.starts_at is not null then fmt_clock(o.starts_at, v_tz, v_fmt) else '' end,
    'deadline_short', case when o.starts_at is not null then fmt_clock(o.starts_at - interval '12 hours', v_tz, v_fmt) || ' ' || to_char((o.starts_at - interval '12 hours') at time zone v_tz, 'FMDy') else 'the evening before' end,
    'cancel_deadline', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD Mon') else 'the day before' end,
    'manage_link', member_portal_url(p_studio_id, '/class/' || coalesce(o.id::text, '')),
    'book_url', member_portal_url(p_studio_id, '/book'),
    'schedule_url', member_portal_url(p_studio_id, '/book'),
    -- plan / offer
    'offer_plan_name', coalesce(v_plan.name, 'a membership'),
    'offer_detail', coalesce(plan_card_detail(v_plan.id), ''),
    'offer_price', case when v_plan.id is not null then fmt_money(v_plan.price_cents, v_plan.currency) else '' end,
    'offer_ends', v_offer_ends,
    'buy_url', case when v_plan.id is not null then member_portal_url(p_studio_id, '/buy/' || v_plan.id::text) else member_portal_url(p_studio_id, '/account/plan') end,
    'plan_name', coalesce(v_plan.name, 'your plan'),
    'credits', '3', 'credits_left', '3',
    'expires_on', v_offer_ends, 'ends_on', v_offer_ends,
    'renew_url', case when v_plan.id is not null then member_portal_url(p_studio_id, '/buy/' || v_plan.id::text) else member_portal_url(p_studio_id, '/account/plan') end,
    -- retention / misc
    'last_class', coalesce(o.cname, 'your class'),
    'last_class_date', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDD Mon') else '' end,
    'instructor_first', coalesce(nullif(o.instr, ''), 'your instructor'),
    'instructor_first_name', coalesce(nullif(o.instr, ''), 'your instructor'),
    'days_since', '10',
    'product', 'Grip socks', 'quantity', '1');
end $function$;
revoke execute on function template_sample_context(uuid, text, text) from public, anon, authenticated;
grant  execute on function template_sample_context(uuid, text, text) to service_role;


-- render_notification — re-issued (from 20260832890000) to resolve the body from
-- the override-or-template and delegate the substitution + frame to render_email,
-- then wrap the recipient/from/reply-to around it. Output byte-identical
-- (email_frame_test + notifications_test prove it); ACL (service-role) kept.
create or replace function render_notification(p_notification_id uuid)
returns table(to_email text, from_name text, reply_to text, subject text, text_body text, html_body text, stripped text[])
language plpgsql stable security definer set search_path = public as $function$
declare
  n notifications%rowtype; t notification_templates%rowtype;
  m members%rowtype; s studios%rowtype;
  v_staff_email text; v_staff_name text; v_is_staff boolean;
  v_sub text; v_txt text; v_html text; v_first text;
  v_ov_key text; v_ov_subject text; v_ov_body text; v_ov_html text;
  v_rsub text; v_rtxt text; v_rhtml text; v_rstrip text[];
begin
  select * into n from notifications where id = p_notification_id;
  select * into t from notification_templates where key = n.template_key;
  select o.key, o.subject, o.body, o.body_html
    into v_ov_key, v_ov_subject, v_ov_body, v_ov_html
    from notification_templates_overrides o
   where o.studio_id = n.studio_id and o.key = n.template_key;
  select * into m from members where id = n.member_id;

  v_is_staff := n.recipient_type = 'staff';
  if v_is_staff then
    select coalesce(ss.email, pr.email), coalesce(pr.full_name, ss.email)
      into v_staff_email, v_staff_name
      from studio_staff ss
      left join profiles pr on pr.id = ss.user_id
     where ss.user_id = n.user_id and ss.studio_id = n.studio_id
     limit 1;
  end if;
  select * into s from studios where id = n.studio_id;
  if t.key is null then
    raise exception 'no template %', n.template_key using errcode = 'PT404';
  end if;

  if v_ov_key is not null then
    v_sub := v_ov_subject; v_txt := v_ov_body; v_html := v_ov_html;
  else
    v_sub := t.subject; v_txt := t.text_body; v_html := t.html_body;
  end if;

  v_first := coalesce(m.first_name, split_part(coalesce(v_staff_name, ''), ' ', 1), 'there');

  select re.subject, re.text_body, re.html_body, re.stripped
    into v_rsub, v_rtxt, v_rhtml, v_rstrip
    from render_email(n.studio_id, n.template_key, n.recipient_type, v_sub, v_txt, v_html, n.payload, v_first) re;

  return query select
    coalesce(nullif(n.payload ->> 'to_email', ''), v_staff_email, m.email),
    s.name, s.contact_email, v_rsub, v_rtxt, v_rhtml, v_rstrip;
end $function$;
revoke execute on function render_notification(uuid) from public, anon, authenticated;
grant  execute on function render_notification(uuid) to service_role;


-- send_template_test — re-issued to source its sample context from the one helper.
create or replace function send_template_test(p_studio_id uuid, p_key text)
returns jsonb language plpgsql security definer set search_path = public as $function$
declare v_email text; v_fname text; v_payload jsonb; v_notif uuid; v_stripped text[];
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'only owners and managers can send a test' using errcode = 'PT403';
  end if;
  select ss.email, split_part(coalesce(pr.full_name, ss.email), ' ', 1)
    into v_email, v_fname
    from studio_staff ss left join profiles pr on pr.id = ss.user_id
   where ss.studio_id = p_studio_id and ss.user_id = auth.uid() and ss.status = 'active';
  if coalesce(v_email, '') = '' then
    raise exception 'no email on file for your account' using errcode = 'PT422';
  end if;

  v_payload := template_sample_context(p_studio_id, v_email, coalesce(nullif(v_fname, ''), 'there'));

  insert into notifications (studio_id, recipient_type, member_id, template_key, channel,
                             payload, dedupe_key, scheduled_for, status)
  values (p_studio_id, 'member', null, p_key, 'email',
          v_payload, 'tpl_test:' || p_key || ':' || extract(epoch from clock_timestamp())::bigint,
          now(), 'scheduled')
  returning id into v_notif;

  select stripped into v_stripped from render_notification(v_notif);
  if v_stripped is not null and array_length(v_stripped, 1) > 0 then
    delete from notifications where id = v_notif;
    raise exception 'This test needs data we could not fill: %',
      array_to_string(v_stripped, ', ') using errcode = 'PT422';
  end if;

  return jsonb_build_object('ok', true, 'to_email', v_email);
end;
$function$;
revoke execute on function send_template_test(uuid, text) from public, anon;
grant  execute on function send_template_test(uuid, text) to authenticated, service_role;


-- preview_template — Decision 80d: render a draft (subject + already-rendered
-- HTML body) inside the REAL frame with the studio's sample context, WITHOUT
-- writing a notification row. Manager-up; not anon. Returns {subject, html, stripped}.
create or replace function preview_template(p_studio_id uuid, p_key text, p_subject text, p_body text)
returns jsonb language plpgsql stable security definer set search_path = public as $function$
declare v_email text; v_fname text; v_ctx jsonb; r record;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'only owners and managers can preview a template' using errcode = 'PT403';
  end if;
  select ss.email, split_part(coalesce(pr.full_name, ss.email), ' ', 1)
    into v_email, v_fname
    from studio_staff ss left join profiles pr on pr.id = ss.user_id
   where ss.studio_id = p_studio_id and ss.user_id = auth.uid() and ss.status = 'active';
  v_ctx := template_sample_context(p_studio_id,
             coalesce(nullif(v_email, ''), 'preview@studiior.app'),
             coalesce(nullif(v_fname, ''), 'there'));
  select * into r from render_email(p_studio_id, p_key, 'member', p_subject, '', p_body, v_ctx,
                                     coalesce(nullif(v_fname, ''), 'there'));
  return jsonb_build_object('subject', r.subject, 'html', r.html_body, 'stripped', coalesce(r.stripped, '{}'::text[]));
end $function$;
revoke execute on function preview_template(uuid, text, text, text) from public, anon;
grant  execute on function preview_template(uuid, text, text, text) to authenticated, service_role;


-- The anon surface is unchanged: exactly THIRTEEN.
do $$ declare n int; begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % not 13', n; end if;
end $$;
