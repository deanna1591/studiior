-- Decision 80a — the email frame that looks like the studio.
--
-- creates: email_on_accent(text)
-- re-issues: render_notification(uuid)
--
-- Authorised by Deanna, 21 Oct 2026 — DDL + a column, no data writes.
--
-- Three things: (1) studios.instagram_handle, a new Branding field stored without
-- the @; (2) email_on_accent(hex), the readable text colour on an accent fill (the
-- SQL twin of lib/email-body.mjs onAccent, used for a button's label); (3)
-- render_notification re-issued (from 20260832650000) so the frame is a 600px
-- table — logo on white + accent rule, a body cell, a footer with the studio name,
-- address, contact, @instagram when set and the manage-emails link — and so a
-- body carrying {accent}/{accent_on} (the static system-template buttons) is
-- filled with this studio's accent. The body HTML it wraps is unchanged in kind.

alter table studios add column if not exists instagram_handle text;

-- The readable text colour on an accent fill. YIQ brightness (the well-known
-- approximation), threshold 150 — a pale accent (lime) gets dark ink, a dark one
-- gets white. Matches lib/email-body.mjs onAccent exactly, so a button rendered
-- by Next (composer) and one filled by SQL (a static template) pair the same.
create or replace function email_on_accent(p_hex text) returns text
language sql immutable as $$
  with h as (select replace(coalesce(p_hex, ''), '#', '') as x)
  select case
    when (select x from h) !~ '^[0-9A-Fa-f]{6}$' then '#FFFFFF'
    when ( ('x' || substr((select x from h), 1, 2))::bit(8)::int * 299
         + ('x' || substr((select x from h), 3, 2))::bit(8)::int * 587
         + ('x' || substr((select x from h), 5, 2))::bit(8)::int * 114 ) / 1000 >= 150
      then '#14170E' else '#FFFFFF' end;
$$;
revoke execute on function email_on_accent(text) from public, anon;
grant  execute on function email_on_accent(text) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.render_notification(p_notification_id uuid)
 RETURNS TABLE(to_email text, from_name text, reply_to text, subject text, text_body text, html_body text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  n notifications%rowtype; t notification_templates%rowtype;
  m members%rowtype; s studios%rowtype;
  v_staff_email text; v_staff_name text; v_is_staff boolean;
  v_sub text; v_txt text; v_html text; k text; rule text; v_on text;
  v_addr text; v_link text; v_contact text; v_contact_html text; v_ig text;
  v_always boolean; v_foot_txt text; v_foot_html text;
  v_ov_key text; v_ov_subject text; v_ov_body text; v_ov_html text;
  v_logo text;
begin
  select * into n from notifications where id = p_notification_id;
  select * into t from notification_templates where key = n.template_key;
  -- Decision 78c: a per-studio override wins over the default template.
  select o.key, o.subject, o.body, o.body_html
    into v_ov_key, v_ov_subject, v_ov_body, v_ov_html
    from notification_templates_overrides o
   where o.studio_id = n.studio_id and o.key = n.template_key;
  select * into m from members where id = n.member_id;

  -- A notification can be addressed to a person at the studio rather than to a
  -- member — platform billing is the first of those.
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

  for k in select jsonb_object_keys(n.payload) loop
    v_sub  := replace(v_sub,  '{' || k || '}', coalesce(n.payload ->> k, ''));
    v_txt  := replace(v_txt,  '{' || k || '}', coalesce(n.payload ->> k, ''));
    v_html := replace(v_html, '{' || k || '}', coalesce(n.payload ->> k, ''));
  end loop;
  for k in select unnest(array['first_name','studio_name']) loop
    v_sub  := replace(v_sub,  '{' || k || '}',
                      case k when 'first_name'
                             then coalesce(m.first_name, split_part(coalesce(v_staff_name,''), ' ', 1), 'there')
                             else s.name end);
    v_txt  := replace(v_txt,  '{' || k || '}',
                      case k when 'first_name'
                             then coalesce(m.first_name, split_part(coalesce(v_staff_name,''), ' ', 1), 'there')
                             else s.name end);
    v_html := replace(v_html, '{' || k || '}',
                      case k when 'first_name'
                             then coalesce(m.first_name, split_part(coalesce(v_staff_name,''), ' ', 1), 'there')
                             else s.name end);
  end loop;

  -- Neutral, not Studiior's lime. A studio that has not picked an accent gets
  -- grey in its own mail rather than another company's brand colour.
  rule := coalesce(s.accent_color, '#78716C');
  v_on := email_on_accent(rule);
  -- Decision 80a: a static system-template button carries {accent}/{accent_on};
  -- a composer body bakes its own hex. Fill the tokens now that the body html is
  -- inlined (the payload loop above has already run, so these land in both the
  -- template HTML and any passthrough {body_html}). Harmless where absent.
  v_html := replace(replace(v_html, '{accent_on}', v_on), '{accent}', rule);
  v_txt  := replace(replace(v_txt,  '{accent_on}', v_on), '{accent}', rule);

  -- locations.address is jsonb with no fixed shape; assembled by key.
  select nullif(concat_ws(', ',
           nullif(l.address ->> 'line1', ''),
           nullif(l.address ->> 'line2', ''),
           nullif(l.address ->> 'city', ''),
           nullif(l.address ->> 'postal_code', ''),
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
            || coalesce(notification_setting('member_app_domain'), 'studiior.app')
            || '/settings';
  end if;

  -- Decision 80a: the Instagram handle (stored without @) joins the contact line.
  v_ig := nullif(s.instagram_handle, '');
  v_contact := nullif(concat_ws(' · ', s.contact_email, s.contact_phone,
                 case when v_ig is not null then '@' || v_ig else null end), '');
  v_contact_html := nullif(concat_ws(' · ', s.contact_email, s.contact_phone,
                 case when v_ig is not null
                      then '<a href="https://instagram.com/' || v_ig
                           || '" style="color:#78716C">@' || v_ig || '</a>'
                      else null end), '');

  -- §12: three events have no opt-out, and staff_message is a person writing to
  -- one member. Saying "always sends" is what stops the footer being a lie.
  v_always := n.template_key in ('class_cancelled', 'instructor_substituted',
                                 'guest_invite', 'guest_host_cancelled',
                                 'guest_waiver_reminder', 'guest_waiver_host_nudge',
                                 'member_invite',
                                 'payment_failed', 'staff_message',
                                 'platform_billing_warning', 'class_moved',
                                 'shift_application_received', 'shift_approved',
                                 'shift_declined', 'shift_withdrawn');

  v_foot_txt := concat_ws(E'\n',
    v_contact,
    v_addr,
    case when v_is_staff then 'Your billing: ' || v_link
         when n.template_key in ('member_invite', 'instructor_invite', 'guest_invite', 'guest_waiver_reminder')
         then 'You are getting this because ' || s.name || ' set up your account.'
         when v_always
         then 'We always send this one — it''s about your booking or your membership. '
              || 'Choose which other emails you get: ' || v_link
         else 'Choose which emails you get: ' || v_link end);

  v_foot_html := concat_ws('<br>',
    v_contact_html,
    v_addr,
    case when v_is_staff
         then '<a href="' || v_link || '" style="color:#78716C">Your billing</a>'
         when n.template_key in ('member_invite', 'instructor_invite', 'guest_invite', 'guest_waiver_reminder')
         then 'You are getting this because ' || s.name || ' set up your account.'
         when v_always
         then 'We always send this one — it''s about your booking or your membership. '
              || '<a href="' || v_link || '" style="color:#78716C">Choose which other emails you get</a>'
         else '<a href="' || v_link || '" style="color:#78716C">Choose which emails you get</a>' end);

  -- The header mark: the logo on white, or the studio name when there is none.
  v_logo := case when s.logo_url is not null
    then '<img src="' || s.logo_url || '" alt="' || replace(s.name, '"', '')
         || '" width="40" height="40" style="display:block;border:0;border-radius:6px" />'
    else '<div style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;'
         || 'font-weight:600;font-size:18px;color:#14170E">' || s.name || '</div>' end;

  return query select
    coalesce(nullif(n.payload ->> 'to_email', ''), v_staff_email, m.email),
    s.name,              -- the from-name is the studio, never Studiior
    s.contact_email,     -- null means no reply-to header, not a fake one
    v_sub,
    v_txt || E'\n\n--\n' || v_foot_txt,
    -- Decision 80a frame: a 600px single-column table on a light page, MSO-safe.
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
      || '</td></tr></table>';
end $function$;
