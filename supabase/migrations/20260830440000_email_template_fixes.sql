-- =============================================================================
-- Migration 034: four things wrong with a real delivered booking confirmation
-- =============================================================================
-- Read off an email that actually arrived, not off the template source.
--
-- 1. NO REPLY-TO. The envelope is `Reform Collective <notifications@studiior.app>`
--    and nothing else, so a member who replies "can I bring a friend?" is
--    writing to a mailbox nobody owns. Fixed by carrying a reply-to through the
--    transport — see the gap note below for what it needs to be non-null.
--
-- 2. "In Reformer Studio." STRANDED. `where_line` was built as a complete
--    sentence and rendered in its own paragraph, so the room got the same
--    visual weight as the booking itself. It is now a fragment folded into the
--    sentence above it: "You're booked into Barre on Tuesday 02 September,
--    07:00, in Reformer Studio."
--
-- 3. THE FOOTER REPEATED THE STUDIO NAME, which is already in the header, with
--    a horizontal rule and nothing else between them. Replaced with the studio's
--    contact details and a link to the member's email settings.
--
--    Transactional mail is exempt from unsubscribe requirements and three of
--    these templates cannot be turned off at all (§12: a cancelled class, a
--    substituted instructor, a failed payment). That is an argument for saying
--    so honestly in the footer, not for having no link: a member who cannot find
--    one marks the message as spam instead, and complaints land against a
--    sending domain that every studio shares. One studio's annoyed member
--    degrades delivery for all ten design partners.
--
--    So the footer says which kind of email this is. Opt-outable ones link to
--    the settings screen; the three that always send say that they always send,
--    and link to the same screen for everything else.
--
-- 4. THE ACCENT RULE RENDERED LIME — `coalesce(s.accent_color, '#BEF738')`.
--    #BEF738 is Studiior's brand, not the studio's, and CLAUDE.md is explicit
--    that the member app is themed and our own colour is for the staff app.
--    A studio that has not chosen an accent was being given ours in mail sent
--    over its own name. It now falls back to a neutral grey.
--
--    It falls back to grey rather than to the theme preset's accent on purpose:
--    the preset ramp lives in lib/theme.ts and only there, because two
--    implementations of one contrast walk drift apart. SQL does not get a
--    second copy of it.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Somewhere for a reply to go
--
-- GAP, recorded rather than papered over: until this migration a studio had
-- nowhere to put a contact address at all — `studios` carries a name, a slug, a
-- timezone and branding, and `locations` carries a postal address and no way to
-- reach anyone. Both columns are nullable and every existing studio starts null,
-- so reply-to is inert until somebody fills it in. Two things still outstanding:
-- the onboarding wizard does not ask for it, and there is no general studio
-- settings screen (it is edited from /branding, which is the only Owner-only
-- screen governing what members see). Neither belongs in a migration about
-- email templates.
-- -----------------------------------------------------------------------------
alter table studios
  add column if not exists contact_email text,
  add column if not exists contact_phone text;

alter table studios drop constraint if exists studios_contact_email_shape;
alter table studios add constraint studios_contact_email_shape check (
  contact_email is null or contact_email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
);

comment on column studios.contact_email is
  'Where a member''s reply goes. Set as reply-to on every email we send on the '
  'studio''s behalf, and shown in the footer. Null means no reply-to header at '
  'all, which is honest — better than pointing replies at an unread mailbox.';
comment on column studios.contact_phone is
  'Shown in the email footer beside the address. Free text: phone formats are '
  'not worth validating and a refused save here helps nobody.';

-- The member app's origin, so SQL can build the settings link. The TypeScript
-- side reads NEXT_PUBLIC_MEMBER_DOMAIN; this is the same value for the half of
-- the system that has no access to the environment.
insert into notification_config (key, value, note) values
  ('member_app_domain', 'studiior.app',
   'Member PWA base domain. The settings link in an email footer is '
   'https://{slug}.{this}/settings. Mirrors NEXT_PUBLIC_MEMBER_DOMAIN.')
on conflict (key) do nothing;

-- -----------------------------------------------------------------------------
-- 2. The room folded into the sentence
-- -----------------------------------------------------------------------------
update notification_templates set
  text_body = E'Hi {first_name},\n\nYou''re booked into {class_name} on {when}{where_line}.\n\nIf you can''t make it, cancel in the app and the place goes to someone on the list.\n\n{studio_name}',
  html_body = E'<p>Hi {first_name},</p><p>You''re booked into <strong>{class_name}</strong> on {when}{where_line}.</p><p>If you can''t make it, cancel in the app and the place goes to someone on the list.</p>'
where key = 'booking_confirmed';

update notification_templates set
  text_body = E'Hi {first_name},\n\n{class_name} is {when_short}, at {when_time}{where_line}.\n\nSee you there.\n\n{studio_name}',
  html_body = E'<p>Hi {first_name},</p><p><strong>{class_name}</strong> is {when_short}, at {when_time}{where_line}.</p><p>See you there.</p>'
where key = 'class_reminder';

-- where_line becomes a fragment: ', in Reformer Studio' or nothing at all. The
-- sentence supplies its own full stop, so a class with no room still reads.
create or replace function queue_booking_notifications(p_booking_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare
  b bookings%rowtype; o class_occurrences%rowtype; m members%rowtype;
  st studio_settings%rowtype; s studios%rowtype;
  v_when text; v_where text; n int := 0; v_remind timestamptz;
begin
  select * into b from bookings where id = p_booking_id;
  if not found or b.status <> 'booked' then return 0; end if;

  select * into o  from class_occurrences where id = b.occurrence_id;
  select * into m  from members            where id = b.member_id;
  select * into s  from studios            where id = b.studio_id;
  select * into st from studio_settings    where studio_id = b.studio_id;

  v_when  := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth, HH24:MI');
  v_where := coalesce((select ', in ' || r.name from rooms r where r.id = o.room_id), '');

  if queue_notification(b.studio_id, b.member_id, 'booking_confirmed',
        jsonb_build_object('class_name', o.name, 'when', v_when, 'where_line', v_where),
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

  return n;
end $$;

-- -----------------------------------------------------------------------------
-- 3 and 4. Render: reply-to, a useful footer, a neutral accent fallback
--
-- Dropped rather than replaced because the return type gains a column, and
-- `create or replace` cannot change one. Dropping loses the ACL, so the revokes
-- from migration 033 are re-applied at the bottom of this file — on hosted a
-- newly created function is born with an `authenticated=X` grant from a default
-- privilege, so a drop-and-recreate silently re-opens anything 033 closed.
-- -----------------------------------------------------------------------------
drop function if exists render_notification(uuid);

create function render_notification(p_notification_id uuid)
returns table (to_email text, from_name text, reply_to text,
               subject text, text_body text, html_body text)
language plpgsql stable security definer set search_path = public as $$
declare
  n notifications%rowtype; t notification_templates%rowtype;
  m members%rowtype; s studios%rowtype;
  v_sub text; v_txt text; v_html text; k text; rule text;
  v_addr text; v_link text; v_contact text;
  v_always boolean; v_foot_txt text; v_foot_html text;
begin
  select * into n from notifications where id = p_notification_id;
  select * into t from notification_templates where key = n.template_key;
  select * into m from members where id = n.member_id;
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
    v_sub  := replace(v_sub,  '{' || k || '}',
                      case k when 'first_name' then m.first_name else s.name end);
    v_txt  := replace(v_txt,  '{' || k || '}',
                      case k when 'first_name' then m.first_name else s.name end);
    v_html := replace(v_html, '{' || k || '}',
                      case k when 'first_name' then m.first_name else s.name end);
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

  v_link := 'https://' || s.slug || '.'
            || coalesce(notification_setting('member_app_domain'), 'studiior.app')
            || '/settings';

  v_contact := nullif(concat_ws(' · ', s.contact_email, s.contact_phone), '');

  -- §12: three events have no opt-out, and staff_message is a person writing to
  -- one member. Saying "always sends" is what stops the footer being a lie.
  v_always := n.template_key in ('class_cancelled', 'instructor_substituted',
                                 'payment_failed', 'staff_message');

  v_foot_txt := concat_ws(E'\n',
    v_contact,
    v_addr,
    case when v_always
         then 'We always send this one — it''s about your booking or your membership. '
              || 'Choose which other emails you get: ' || v_link
         else 'Choose which emails you get: ' || v_link end);

  v_foot_html := concat_ws('<br>',
    v_contact,
    v_addr,
    case when v_always
         then 'We always send this one — it''s about your booking or your membership. '
              || '<a href="' || v_link || '" style="color:#57534E">Choose which other emails you get</a>'
         else '<a href="' || v_link || '" style="color:#57534E">Choose which emails you get</a>' end);

  return query select
    m.email,
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
end $$;

-- -----------------------------------------------------------------------------
-- Transport: reply-to on the wire
--
-- Dropped and recreated rather than given a defaulted sixth parameter: a
-- default would leave the five-argument version in place beside it and every
-- existing five-argument call becomes ambiguous. Migration 028 learned this on
-- book_class() and it is the same mistake either way.
-- -----------------------------------------------------------------------------
drop function if exists send_via_resend(text, text, text, text, text);

create function send_via_resend(
  p_to text, p_from_name text, p_reply_to text,
  p_subject text, p_text text, p_html text
) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_key text; v_from text; v_body jsonb;
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
  -- Omitted entirely when the studio has no contact address. A reply-to
  -- pointing at our own unread notifications@ mailbox would be worse than none:
  -- it looks like somewhere to write.
  if p_reply_to is not null then
    v_body := v_body || jsonb_build_object('reply_to', p_reply_to);
  end if;

  return net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_key,
                                  'Content-Type', 'application/json'),
    body := v_body,
    timeout_milliseconds := 8000);
end $$;

create or replace function deliver_notification(p_notification_id uuid) returns bigint
language plpgsql security definer set search_path = public as $$
declare r record; v_transport text;
begin
  select * into r from render_notification(p_notification_id);
  v_transport := notification_setting('transport');

  if v_transport = 'resend' then
    return send_via_resend(r.to_email, r.from_name, r.reply_to,
                           r.subject, r.text_body, r.html_body);
  end if;
  raise exception 'unknown transport %', v_transport using errcode = 'PT501';
end $$;

-- -----------------------------------------------------------------------------
-- Re-close what the drops re-opened. See migration 033.
-- -----------------------------------------------------------------------------
revoke execute on function render_notification(uuid)
  from public, anon, authenticated;
revoke execute on function send_via_resend(text, text, text, text, text, text)
  from public, anon, authenticated;
revoke execute on function deliver_notification(uuid)
  from public, anon, authenticated;

do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
   where nsp.nspname = 'public'
     and p.proname in ('render_notification','send_via_resend','deliver_notification')
     and (has_function_privilege('authenticated', p.oid, 'execute')
          or has_function_privilege('anon', p.oid, 'execute'));
  if n > 0 then
    raise exception 'migration 034 left % recreated function(s) open to a client role', n;
  end if;
end $$;
