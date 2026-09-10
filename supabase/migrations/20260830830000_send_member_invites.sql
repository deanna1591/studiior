-- =============================================================================
-- 073  The invite actually gets sent
-- =============================================================================
-- `member_invites` and `claim_member_account()` have existed since migration
-- 027 and nothing has ever emailed one: `create_member_invite()` returns a raw
-- token to whoever called it and the screen printed the link for an operator to
-- paste into their own mail client. That works for one member and collapses at
-- thirty, which is exactly when a studio has just finished an import.
--
-- THE COPY IS THE POINT AND IT HAS TO BE TRUE. There is no app to download.
-- The member app is a PWA at {slug}.studiior.app, so the email links there and
-- explains adding it to the home screen — which is the thing that makes it
-- behave like an app. "Download our app" over a link to a website is a promise
-- the next screen breaks. WHICH home-screen instructions to give depends on iOS
-- versus Android and an email cannot know; the claim page does that.
--
-- FROM THE STUDIO, NOT FROM US. Same as every member-facing email since
-- migration 034: the studio's name, its accent (or neutral grey, never
-- Studiior's lime), its contact details in the footer.
--
-- THE TOKEN IN THE PAYLOAD, stated rather than left to be noticed. Only its
-- hash is stored on `member_invites`; the raw token has to reach the email, so
-- it sits in `notifications.payload` until sent. Who can read that: manager-up
-- of the same studio, who can mint an invite for that member anyway, and the
-- member themselves — who has no account yet, and whose token is dead by the
-- time they do. It expires in fourteen days and a resend supersedes it.
--
-- render_notification() and notification_wanted() are rebuilt from
-- 20260830580000, the newest FILE that defines either, with `member_invite`
-- added to the two always-send lists.
-- =============================================================================

insert into notification_templates (key, subject, text_body, html_body, note) values
('member_invite',
 'Your {studio_name} account is ready',
 E'Hi {first_name},\n\n{studio_name} has set up your account. Open this link to choose a password:\n\n{claim_url}\n\nIt works in your phone''s browser — there is nothing to download. Once you are in, add it to your home screen and it opens like an app: book classes, see your history and show your check-in code at the door.\n\nThe link expires on {expires_on}.\n\nSee you soon,\n{studio_name}',
 '<p>Hi {first_name},</p><p><strong>{studio_name}</strong> has set up your account.</p><p><a href="{claim_url}">Choose a password and get started</a></p><p>It works in your phone&rsquo;s browser &mdash; there is nothing to download. Once you are in, add it to your home screen and it opens like an app: book classes, see your history and show your check-in code at the door.</p><p>The link expires on {expires_on}.</p><p>See you soon,<br>{studio_name}</p>',
 'Migration 073. NO "download our app" — the member app is a PWA and the email '
 'says so. Which home-screen steps to show depends on iOS vs Android, which an '
 'email cannot detect; /claim/[token] does that.')
on conflict (key) do update
  set subject = excluded.subject, text_body = excluded.text_body,
      html_body = excluded.html_body, note = excluded.note;

create or replace function public.render_notification(p_notification_id uuid)
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
         when n.template_key = 'member_invite'
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
         when n.template_key = 'member_invite'
         then 'You are getting this because ' || s.name || ' set up your account.'
         when v_always
         then 'We always send this one — it''s about your booking or your membership. '
              || '<a href="' || v_link || '" style="color:#57534E">Choose which other emails you get</a>'
         else '<a href="' || v_link || '" style="color:#57534E">Choose which emails you get</a>' end);

  return query select
    coalesce(v_staff_email, m.email),
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
-- Telling the studio and the instructor
--
-- Staff-addressed rows go in directly with recipient_type = 'staff', which
-- migration 046 taught render_notification() to resolve. queue_notification()
-- is member-only and checks member preferences, neither of which applies here.
-- -----------------------------------------------------------------------------
/**
 * The login behind an instructor, if they have one.
 *
 * instructors.staff_id references studio_staff(id) — NOT a user id. Passing it
 * straight to a notification addresses a user that does not exist, which is
 * exactly the bug this function exists to stop being written three times.
 */
create or replace function instructor_user_id(p_instructor_id uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select ss.user_id
    from instructors i
    join studio_staff ss on ss.id = i.staff_id
   where i.id = p_instructor_id and ss.status = 'active'
$$;

create or replace function queue_shift_notice(
  p_studio_id uuid, p_user_id uuid, p_template text, p_payload jsonb, p_dedupe text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if p_user_id is null then
    -- An instructor with no login has no address. instructors carries no email
    -- of its own, and only a signed-in instructor can apply in the first place,
    -- so in practice this is the studio-side path with no owner set.
    return null;
  end if;
  insert into notifications (studio_id, recipient_type, user_id, template_key,
                             channel, payload, dedupe_key, scheduled_for, status)
  values (p_studio_id, 'staff', p_user_id, p_template, 'email',
          p_payload, p_dedupe, now(), 'scheduled')
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  return v_id;
end $$;;

create or replace function notification_wanted(p_member_id uuid, p_template text)
returns boolean
language plpgsql stable security definer set search_path = public as $$
declare p notification_preferences%rowtype;
begin
  if p_template in ('class_cancelled', 'instructor_substituted',
                    'payment_failed', 'staff_message', 'class_moved',
                    -- 073: an invite cannot be turned off and its reader has
                    -- no preferences row yet.
                    'member_invite') then
    return true;
  end if;

  select * into p from notification_preferences where member_id = p_member_id;
  if not found then
    return true;
  end if;

  return case p_template
    when 'booking_confirmed' then p.booking_email
    when 'class_reminder'    then p.reminder_email
    when 'waitlist_offer'    then p.waitlist_email
    when 'credit_expiry'     then p.credit_expiry_email
    when 'milestone'         then p.milestone_email
    else true
  end;
end $$;;

-- -----------------------------------------------------------------------------
-- One invite, created and queued together
-- -----------------------------------------------------------------------------
-- create_member_invite() stays the only thing that mints a token — it already
-- guards Permissions §5, refuses a member who has an account, and supersedes an
-- outstanding invite so a resend invalidates the previous link. This wraps it
-- and posts the email, so there is no path that creates an invite nobody is
-- told about.
create or replace function invite_member(p_member_id uuid, p_days int default 14)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  m        members%rowtype;
  s        studios%rowtype;
  v_token  text; v_email text; v_exp timestamptz;
  v_url    text; v_notif uuid;
begin
  select * into m from members where id = p_member_id;
  if not found then
    raise exception 'no such member' using errcode = 'PT404';
  end if;
  if not coalesce(is_desk_up(m.studio_id), false) then
    raise exception 'only owners, managers and front desk may invite a member'
      using errcode = 'PT403', hint = 'Permissions §5.';
  end if;
  -- An address is the whole delivery mechanism. members.email is NOT NULL but
  -- nothing stops an importer or a hand-typed row writing a blank one, and a
  -- blank address fails somewhere far away from the person who caused it.
  if coalesce(btrim(m.email), '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'no_email',
      'member', m.first_name || ' ' || m.last_name,
      'hint', 'Add an email address to their record and invite them again.');
  end if;
  if m.user_id is not null then
    return jsonb_build_object('ok', false, 'reason', 'already_claimed',
      'member', m.first_name || ' ' || m.last_name);
  end if;

  select * into s from studios where id = m.studio_id;
  select token, email, expires_at into v_token, v_email, v_exp
    from create_member_invite(p_member_id, p_days);

  v_url := 'https://' || s.slug || '.'
           || coalesce(notification_setting('member_app_domain'), 'studiior.app')
           || '/claim/' || v_token;

  v_notif := queue_notification(m.studio_id, m.id, 'member_invite',
    jsonb_build_object('claim_url', v_url,
                       'expires_on', to_char(v_exp at time zone s.timezone, 'FMDD FMMonth')),
    -- Keyed on the TOKEN, so a resend is a new row rather than a silent no-op
    -- on the dedupe index — while pressing the button twice on one invite is.
    'member_invite:' || encode(digest(v_token, 'sha256'), 'hex'));

  return jsonb_build_object(
    'ok', true, 'queued', v_notif is not null,
    'email', v_email, 'expires_at', v_exp,
    -- Returned so the screen can still offer the link by hand. Email is the
    -- path; a studio whose member cannot receive one is not stuck.
    'claim_url', v_url);
end $$;

-- -----------------------------------------------------------------------------
-- Everyone who has no account yet
-- -----------------------------------------------------------------------------
-- The case the hand-copied link could never serve: thirty people at once, the
-- moment after an import. Reports what it skipped and why rather than a count
-- that hides the ones it could not reach.
create or replace function invite_members_bulk(
  p_studio_id uuid, p_member_ids uuid[] default null, p_days int default 14
) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r record; v jsonb;
        n_sent int := 0; v_no_email jsonb := '[]'::jsonb; v_claimed int := 0;
begin
  if not coalesce(is_desk_up(p_studio_id), false) then
    raise exception 'only owners, managers and front desk may invite members'
      using errcode = 'PT403', hint = 'Permissions §5.';
  end if;
  for r in
    select id from members
     where studio_id = p_studio_id
       and status <> 'archived'
       and user_id is null
       and (p_member_ids is null or id = any (p_member_ids))
     order by created_at
  loop
    v := invite_member(r.id, p_days);
    if coalesce((v ->> 'ok')::boolean, false) then
      n_sent := n_sent + 1;
    elsif v ->> 'reason' = 'no_email' then
      v_no_email := v_no_email || jsonb_build_object('member', v ->> 'member');
    else
      v_claimed := v_claimed + 1;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'invited', n_sent,
                            'skipped_no_email', v_no_email,
                            'skipped_already_claimed', v_claimed);
end $$;

-- -----------------------------------------------------------------------------
-- Who has been asked, who has answered, who has never been asked
-- -----------------------------------------------------------------------------
create or replace function member_invite_status(p_studio_id uuid)
returns table (
  m_id        uuid,
  full_name   text,
  m_email     text,
  state       text,
  invited_at  timestamptz,
  expires_at  timestamptz
) language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(is_desk_up(p_studio_id), false) then
    raise exception 'only owners, managers and front desk see this'
      using errcode = 'PT403';
  end if;
  return query
  select m.id, m.first_name || ' ' || m.last_name, m.email,
         case
           when m.user_id is not null then 'claimed'
           when coalesce(btrim(m.email), '') = '' then 'no_email'
           when i.id is null then 'never_invited'
           when i.expires_at < now() then 'expired'
           else 'invited' end,
         i.created_at, i.expires_at
    from members m
    left join member_invites i
           on i.member_id = m.id and i.accepted_at is null
   where m.studio_id = p_studio_id and m.status <> 'archived'
   order by m.first_name, m.last_name;
end $$;

revoke execute on function render_notification(uuid)              from public, anon, authenticated;
revoke execute on function notification_wanted(uuid, text)        from public, anon, authenticated;
revoke execute on function invite_member(uuid, int)               from public, anon, authenticated;
grant  execute on function invite_member(uuid, int)               to authenticated;
revoke execute on function invite_members_bulk(uuid, uuid[], int) from public, anon, authenticated;
grant  execute on function invite_members_bulk(uuid, uuid[], int) to authenticated;
revoke execute on function member_invite_status(uuid)             from public, anon, authenticated;
grant  execute on function member_invite_status(uuid)             to authenticated;
