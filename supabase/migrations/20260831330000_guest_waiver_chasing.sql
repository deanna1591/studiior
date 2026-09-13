-- Decision 26, part two — chasing the guest waiver, and the paper fallback.
--
-- An unsigned guest turned away at the door with nobody having chased them is
-- the worst first impression of a business they were considering joining. So:
--   1. remind the GUEST a few hours before, if still unsigned;
--   2. tell the HOST — the friend who invited them is who can make it happen;
--   3. let front desk record a waiver signed ON PAPER at the door (through
--      record_document), which confirms the pass exactly as signing in the app.

-- Two templates. Placeholders single-brace, html_body NOT NULL, substituted by
-- render_notification. The reminder goes to the guest (who may not have claimed
-- yet, so no settings link — added to that footer branch below); the nudge goes
-- to the host, an ordinary member.
insert into notification_templates (key, subject, text_body, html_body, note) values
('guest_waiver_reminder', 'One step before your class at {studio_name} — sign the waiver',
 E'Hi,\n\nYour free class at {studio_name} — {class_name} on {when} — is coming up. Please sign the waiver in the app so the front desk can check you in. It only takes a moment.\n\n{claim_url}\n\nSee you there,\n{studio_name}',
 E'<p>Hi,</p><p>Your free class at {studio_name} — <strong>{class_name}</strong> on {when} — is coming up. Please sign the waiver in the app so the front desk can check you in.</p><p><a href="{claim_url}">Sign the waiver</a></p>',
 'Decision 26. Sent to a guest whose waiver is still unsigned a few hours before the class.'),
('guest_waiver_host_nudge', 'Your guest hasn''t signed the waiver yet — {class_name}',
 E'Hi {first_name},\n\nThe guest you invited to {class_name} on {when} hasn''t signed the waiver yet, so the front desk won''t be able to check them in. A quick nudge from you is the surest way to sort it — ask them to open the email we sent and sign in the app.\n\n{studio_name}',
 E'<p>Hi {first_name},</p><p>The guest you invited to <strong>{class_name}</strong> on {when} hasn''t signed the waiver yet, so the front desk won''t be able to check them in. A quick nudge from you is the surest way to sort it.</p>',
 'Decision 26. Sent to the HOST when their guest''s waiver is still unsigned before the class.');

-- Both are always-send: a guest has no preferences row, and the host nudge is
-- about a booking in flight.
create or replace function notification_wanted(p_member_id uuid, p_template text)
returns boolean
language plpgsql stable security definer set search_path = public as $$
declare p notification_preferences%rowtype;
begin
  if p_template in ('class_cancelled', 'instructor_substituted',
                    'payment_failed', 'staff_message', 'class_moved',
                    'member_invite', 'guest_invite', 'guest_host_cancelled',
                    'guest_waiver_reminder', 'guest_waiver_host_nudge') then
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
    when 'waitlist_missed'   then p.waitlist_email
    when 'credit_expiry'     then p.credit_expiry_email
    when 'milestone'         then p.milestone_email
    when 'challenge_joined'      then p.challenge_email
    when 'challenge_milestone'   then p.challenge_email
    when 'challenge_completed'   then p.challenge_email
    when 'challenge_ending_soon' then p.challenge_email
    when 'challenge_opening'     then p.challenge_email
    else true
  end;
end $$;

-- render_notification re-issued (create-or-replace keeps the ACL): the two new
-- templates join the always-send list, and the guest reminder takes the
-- footerless-invite treatment (an unclaimed guest has no settings screen).
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
         when n.template_key in ('member_invite', 'guest_invite', 'guest_waiver_reminder')
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
         when n.template_key in ('member_invite', 'guest_invite', 'guest_waiver_reminder')
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

-- record_document re-issued: filing a guest's waiver confirms their pass.
CREATE OR REPLACE FUNCTION public.record_document(p_member_id uuid, p_kind text, p_filename text, p_storage_path text, p_mime text DEFAULT NULL::text, p_size integer DEFAULT NULL::integer, p_note text DEFAULT NULL::text, p_signed_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_studio uuid; v_id uuid; v_waiver boolean := false;
begin
  select studio_id into v_studio from members where id = p_member_id;
  if v_studio is null then
    raise exception 'no such member' using errcode = 'PT404';
  end if;
  if not is_desk_up(v_studio) then
    raise exception 'only front desk and above may file a document'
      using errcode = 'PT403';
  end if;
  if p_kind not in ('waiver','medical','id','other') then
    raise exception 'kind must be waiver, medical, id or other' using errcode = 'PT422';
  end if;

  insert into member_documents
    (studio_id, member_id, kind, filename, storage_path, mime_type, size_bytes,
     note, uploaded_by, signed_at)
  values (v_studio, p_member_id, p_kind, p_filename, p_storage_path, p_mime,
          p_size, nullif(btrim(coalesce(p_note,'')), ''), auth.uid(),
          case when p_kind = 'waiver' then coalesce(p_signed_at, now()) end)
  returning id into v_id;

  -- THE POINT OF THE WAIVER CASE. members.waiver_signed_at is §2.1's booking
  -- gate and has been set by hand since migration 001; filing the signed
  -- document is what should set it, so the gate and the paperwork agree.
  -- guard_member_self_update() protects waiver_signed_at from the MEMBER, not
  -- from the desk, and this runs as the desk.
  if p_kind = 'waiver' then
    update members
       set waiver_signed_at = coalesce(p_signed_at, now())
     where id = p_member_id and waiver_signed_at is null;
    v_waiver := found;
    -- Decision 26: a guest signs on PAPER at the door. Filing that waiver
    -- confirms their pass, the same as signing in the app — a studio hands an
    -- unsigned guest a form rather than sending them home, and the product has
    -- to be able to record it.
    update guest_passes
       set status = 'confirmed', waiver_signed_at = coalesce(p_signed_at, now())
     where guest_member_id = p_member_id and status = 'invited';
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (v_studio, auth.uid(), 'document.filed', 'member_documents', v_id,
          jsonb_build_object('kind', p_kind, 'filename', p_filename,
                             'member_id', p_member_id, 'waiver_set', v_waiver));

  return jsonb_build_object('ok', true, 'document_id', v_id, 'waiver_signed', v_waiver);
end $function$

;

-- ---------------------------------------------------------------------------
-- The sweep. A few hours before the class, an unsigned guest is reminded and
-- their host is nudged — each once (dedupe on the pass). Every 15 minutes, so
-- the "few hours before" lands promptly; the lead window is a fixed 4 hours.
-- The guest's link points at /claim/<token> if they have not set up an account
-- (a fresh token, superseding the old — only its hash was ever stored), or at
-- the app home if they have, where the waiver banner is waiting.
-- ---------------------------------------------------------------------------
create function sweep_guest_waivers() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r record; v_guest int := 0; v_host int := 0; v_token text; v_url text; v_when text;
begin
  if not is_service_context() then
    raise exception 'the guest waiver sweep is a background job' using errcode = 'PT403';
  end if;

  for r in
    select gp.id as pass_id, gp.studio_id, gp.guest_member_id, gp.host_member_id,
           gp.occurrence_id, o.name as class_name, o.starts_at,
           gm.user_id as guest_user_id, gm.email as guest_email,
           s.slug, s.timezone
      from guest_passes gp
      join class_occurrences o on o.id = gp.occurrence_id
      join members gm on gm.id = gp.guest_member_id
      join studios s on s.id = gp.studio_id
     where gp.status = 'invited'                       -- unsigned
       and gm.waiver_signed_at is null
       and o.status = 'scheduled'
       and now() >= o.starts_at - interval '4 hours'
       and now() <  o.starts_at
  loop
    v_when := to_char(r.starts_at at time zone r.timezone, 'FMDay FMDD FMMonth, HH24:MI');

    -- The guest's link: claim if no account yet (fresh token), else the app home.
    if r.guest_user_id is null then
      v_token := encode(gen_random_bytes(24), 'hex');
      delete from member_invites where member_id = r.guest_member_id and accepted_at is null;
      insert into member_invites (studio_id, member_id, email, token_hash, expires_at)
      values (r.studio_id, r.guest_member_id, r.guest_email,
              encode(digest(v_token, 'sha256'), 'hex'), now() + interval '14 days');
      v_url := 'https://' || r.slug || '.'
               || coalesce(notification_setting('member_app_domain'), 'studiior.app')
               || '/claim/' || v_token;
    else
      v_url := 'https://' || r.slug || '.'
               || coalesce(notification_setting('member_app_domain'), 'studiior.app') || '/';
    end if;

    if queue_notification(r.studio_id, r.guest_member_id, 'guest_waiver_reminder',
         jsonb_build_object('claim_url', v_url, 'class_name', r.class_name, 'when', v_when),
         'guest_waiver_reminder:' || r.pass_id) is not null then
      v_guest := v_guest + 1;
    end if;

    if queue_notification(r.studio_id, r.host_member_id, 'guest_waiver_host_nudge',
         jsonb_build_object('class_name', r.class_name, 'when', v_when),
         'guest_waiver_host_nudge:' || r.pass_id) is not null then
      v_host := v_host + 1;
    end if;
  end loop;

  insert into job_runs (job_key, run_for, status, finished_at)
  values ('guest_waivers', current_date, 'done', now())
  on conflict (job_key, run_for) do update
     set attempts = job_runs.attempts + 1, started_at = now(),
         status = 'done', finished_at = now();

  return jsonb_build_object('reminded', v_guest, 'nudged', v_host);
end $$;

do $$ begin
  if exists (select 1 from cron.job where jobname = 'studiior-guest-waivers') then
    perform cron.unschedule('studiior-guest-waivers');
  end if;
  perform cron.schedule('studiior-guest-waivers', '*/15 * * * *', $job$select sweep_guest_waivers()$job$);
end $$;

revoke execute on function sweep_guest_waivers() from public, anon, authenticated;
grant  execute on function sweep_guest_waivers() to service_role;
