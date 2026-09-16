-- =============================================================================
-- 143 — an instructor invite reached Resend with "to": [null] and 422'd. Six
-- instructors have been blocked for a week; the portal has had no users.
-- =============================================================================
-- invite_instructor() queues through queue_notification(), whose recipient is a
-- MEMBER — it inserts recipient_type='member', member_id = the second argument.
-- The invite passes null there (an invitee has no member row and no login), so
-- render_notification's member lookup and its staff branch both resolve to null
-- and to_email came out null. The address the invite was actually SENT TO is in
-- the payload as `to_email` — the only address that exists at that point — and
-- the renderer never read it. Three fixes, all forward (these are on hosted):
--
--   A. render_notification: the payload's to_email WINS over the member/staff
--      chain, so an invite (or anything addressed by hand) reaches its recipient.
--   B. render_notification: instructor_invite joins the no-settings-link footer.
--      An invitee has no account, so "Choose which emails you get" -> the member
--      app /settings was the wrong building; it gets "your studio set this up".
--   C. deliver_notification / queue_notification: a null recipient is refused
--      with a reason BEFORE Resend, not discovered as a 422 at the API.
-- =============================================================================

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
  v_sub text; v_txt text; v_html text; k text; rule text;
  v_addr text; v_link text; v_contact text;
  v_always boolean; v_foot_txt text; v_foot_html text;
begin
  select * into n from notifications where id = p_notification_id;
  select * into t from notification_templates where key = n.template_key;
  select * into m from members where id = n.member_id;

  -- A notification can be addressed to a person at the studio rather than to a
  -- member — platform billing is the first of those, and it has to reach the
  -- owner rather than somebody who books classes. The renderer had only ever
  -- looked in `members`, so this branch is what a staff-addressed row needs to
  -- render at all rather than as an email to nobody.
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

  v_sub  := t.subject;
  v_txt  := t.text_body;
  v_html := t.html_body;

  for k in select jsonb_object_keys(n.payload) loop
    v_sub  := replace(v_sub,  '{' || k || '}', coalesce(n.payload ->> k, ''));
    v_txt  := replace(v_txt,  '{' || k || '}', coalesce(n.payload ->> k, ''));
    v_html := replace(v_html, '{' || k || '}', coalesce(n.payload ->> k, ''));
  end loop;
  for k in select unnest(array['first_name','studio_name']) loop
    -- falls through to the same replace below, with m.first_name null-safe
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

  -- locations.address is jsonb with no fixed shape (data model line 101), so
  -- assigning it straight into a text variable put a raw JSON object in the
  -- footer of a real email: {"city": "Prague", "line1": ...}. Assembled by key,
  -- skipping whatever a given studio has not filled in.
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

  -- A member's email-settings screen means nothing to a studio owner being
  -- told their subscription lapsed, so a staff email points at their billing
  -- screen instead. Offering the member link would be a control that does
  -- nothing for the person reading it.
  if v_is_staff then
    v_link := coalesce(nullif(notification_setting('staff_app_origin'), ''),
                       'https://app.studiior.com') || '/billing';
  else
  v_link := 'https://' || s.slug || '.'
            || coalesce(notification_setting('member_app_domain'), 'studiior.app')
            || '/settings';
  end if;

  v_contact := nullif(concat_ws(' · ', s.contact_email, s.contact_phone), '');

  -- §12: three events have no opt-out, and staff_message is a person writing to
  -- one member. Saying "always sends" is what stops the footer being a lie.
  v_always := n.template_key in ('class_cancelled', 'instructor_substituted',
                                 'guest_invite', 'guest_host_cancelled',
                                 'guest_waiver_reminder', 'guest_waiver_host_nudge',
                                 -- An invite cannot be turned off, and the
                                 -- person reading it has no settings screen
                                 -- to reach yet — offering them one would be
                                 -- a control that does nothing.
                                 'member_invite',
                                 'payment_failed', 'staff_message',
                                 'platform_billing_warning', 'class_moved',
                                 'shift_application_received', 'shift_approved',
                                 'shift_declined', 'shift_withdrawn');

  v_foot_txt := concat_ws(E'\n',
    v_contact,
    v_addr,
    case when v_is_staff then 'Your billing: ' || v_link
         -- An invite gets NO settings link: the person reading it has no
         -- account, so the screen it points at would refuse them. A control
         -- that does nothing is worse than no control.
         when n.template_key in ('member_invite', 'instructor_invite', 'guest_invite', 'guest_waiver_reminder')
         then 'You are getting this because ' || s.name || ' set up your account.'
         when v_always
         then 'We always send this one — it''s about your booking or your membership. '
              || 'Choose which other emails you get: ' || v_link
         else 'Choose which emails you get: ' || v_link end);

  v_foot_html := concat_ws('<br>',
    v_contact,
    v_addr,
    case when v_is_staff
         then '<a href="' || v_link || '" style="color:#57534E">Your billing</a>'
         when n.template_key in ('member_invite', 'instructor_invite', 'guest_invite', 'guest_waiver_reminder')
         then 'You are getting this because ' || s.name || ' set up your account.'
         when v_always
         then 'We always send this one — it''s about your booking or your membership. '
              || '<a href="' || v_link || '" style="color:#57534E">Choose which other emails you get</a>'
         else '<a href="' || v_link || '" style="color:#57534E">Choose which emails you get</a>' end);

  return query select
    -- A. The address the notification was SENT TO wins. For an invite (member
    -- or instructor) or any hand-addressed row this is the only address that
    -- exists — the member/staff chain is null when there is no login yet.
    coalesce(nullif(n.payload ->> 'to_email', ''), v_staff_email, m.email),
    s.name,              -- the from-name is the studio, never Studiior
    s.contact_email,     -- null means no reply-to header, not a fake one
    v_sub,
    v_txt || E'\n\n--\n' || v_foot_txt,
    '<div style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;'
      || 'font-size:15px;line-height:22px;color:#14170E;max-width:520px;margin:0 auto;padding:24px">'
      || case when s.logo_url is not null
              then '<img src="' || s.logo_url || '" alt="' || s.name
                   || '" width="40" height="40" style="border-radius:6px;display:block;margin-bottom:16px">'
              else '<div style="font-weight:600;font-size:17px;margin-bottom:16px">' || s.name || '</div>'
         end
      || '<div style="height:3px;width:44px;background:' || rule || ';margin-bottom:20px"></div>'
      || v_html
      || '<p style="color:#78716C;font-size:13px;line-height:18px;margin-top:28px;'
      || 'border-top:1px solid #E7E5E4;padding-top:14px">' || v_foot_html || '</p></div>';
end $function$

;

-- -----------------------------------------------------------------------------
-- C1. deliver_notification refuses a null recipient BEFORE the provider does.
-- The worker (send_due_notifications) catches a per-row raise and marks the row
-- failed with the reason — the same way it handles a missing API key — so this
-- fails the one row with a readable cause instead of posting "to": [null].
-- Re-issued from migration 030 with that guard added.
-- -----------------------------------------------------------------------------
create or replace function deliver_notification(p_notification_id uuid) returns bigint
language plpgsql security definer set search_path = public as $$
declare r record; v_transport text;
begin
  select * into r from render_notification(p_notification_id);

  if nullif(r.to_email, '') is null then
    raise exception 'notification % has no recipient address', p_notification_id
      using errcode = 'PT422',
            hint = 'Queued with no member, no staff user and no payload to_email. '
                   'Refused here rather than posting a null recipient to the provider.';
  end if;

  v_transport := notification_setting('transport');
  if v_transport = 'resend' then
    return send_via_resend(r.to_email, r.from_name, r.reply_to,
                           r.subject, r.text_body, r.html_body);
  end if;
  raise exception 'unknown transport %', v_transport using errcode = 'PT501';
end $$;

-- -----------------------------------------------------------------------------
-- C2. queue_notification refuses an unaddressable row at queue time. A member
-- notification needs a member_id, OR an explicit payload to_email for a
-- hand-addressed row (an invite to somebody with no login yet). Neither means
-- there is no recipient and the row must not be written. Re-issued from
-- migration 030 with that guard added; create-or-replace keeps the ACL.
-- -----------------------------------------------------------------------------
create or replace function queue_notification(
  p_studio_id    uuid,
  p_member_id    uuid,
  p_template_key text,
  p_payload      jsonb,
  p_dedupe_key   text,
  p_scheduled_for timestamptz default now()
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not notification_wanted(p_member_id, p_template_key) then
    return null;
  end if;

  if p_member_id is null and nullif(p_payload ->> 'to_email', '') is null then
    raise exception 'queue_notification: no recipient for % — no member and no payload to_email',
      p_template_key
      using errcode = 'PT422',
            hint = 'A member notification needs a member_id; a hand-addressed one '
                   '(an invite) must carry to_email in the payload.';
  end if;

  insert into notifications (studio_id, recipient_type, member_id, template_key,
                             channel, payload, dedupe_key, scheduled_for, status)
  values (p_studio_id, 'member', p_member_id, p_template_key,
          'email', coalesce(p_payload, '{}'::jsonb), p_dedupe_key,
          p_scheduled_for, 'scheduled')
  on conflict (dedupe_key) do nothing
  returning id into v_id;

  return v_id;
end $$;
