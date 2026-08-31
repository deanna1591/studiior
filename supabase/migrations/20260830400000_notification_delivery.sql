-- =============================================================================
-- MIGRATION 030 — notification delivery, email only
--
-- notifications, notification_preferences and push_subscriptions have existed
-- since migration 001 and nothing has ever sent one. This sends them.
--
-- Shape, and why:
--
--   QUEUEING decides who gets what and whether they asked for it. Preferences
--   are checked HERE, not in the worker: a row that should never be sent
--   should never be written, or every future worker has to remember the rule
--   and the queue quietly fills with things nobody may send.
--
--   THE WORKER is dumb on purpose. It claims due rows, renders, hands them to
--   a transport, and records what came back. It asks no questions about who
--   or why.
--
--   THE TRANSPORT is one function behind a config row. Resend today; SMTP or
--   anyone else is a second function and a changed row, not a rewrite.
--
-- Sending is asynchronous because pg_net is: net.http_post() returns a request
-- id and the response lands in net._http_response later. So delivery is two
-- passes — claim-and-post, then reconcile — and a notification is only 'sent'
-- once the provider has actually said so. Marking it sent at post time would
-- be recording a hope.
-- =============================================================================

-- 'sending' is the claim. Without it two workers a minute apart both see the
-- same 'scheduled' row and both post it — dedupe_key stops a duplicate ROW,
-- it does nothing about sending one row twice.
alter type notif_status add value if not exists 'sending' before 'sent';
COMMIT;

alter table notifications
  add column net_request_id      bigint,
  add column provider_message_id text,
  add column attempts            int not null default 0,
  add column claimed_at          timestamptz;

create index on notifications (status, scheduled_for)
  where status in ('scheduled', 'sending');

-- The preference table covers bookings, reminders, waitlist and marketing. It
-- has no column for a milestone email or a credit-expiry email, and none at
-- all for the three that are not opt-outable.
alter table notification_preferences
  add column milestone_email     boolean not null default true,
  add column credit_expiry_email boolean not null default true;

comment on table notification_preferences is
  'What a member has asked to receive. Deliberately has no column for a '
  'cancelled class, a substituted instructor or a failed payment: those are '
  'not marketing and there is no version of "I opted out" that makes it right '
  'to let somebody turn up to a class that is not running.';

-- -----------------------------------------------------------------------------
-- Transport configuration
--
-- The API key is never in this repo and never in a migration. It is read from
-- Vault, falling back to a database setting, both of which are set out of band
-- at deploy time. A missing key is a normal, expected state — a fresh local
-- stack has none — and it must not take the cron down, so the worker records
-- it against the row as a failure with a readable reason and moves on.
-- -----------------------------------------------------------------------------
create table notification_config (
  key   text primary key,
  value text not null,
  note  text
);
alter table notification_config enable row level security;
create policy notif_config_platform on notification_config
  for all using (is_platform_admin()) with check (is_platform_admin());
grant select, insert, update, delete on notification_config to authenticated;
grant all on notification_config to service_role;

insert into notification_config (key, value, note) values
  ('transport',      'resend',                'Which send_via_* function delivers. Swap this, not the worker.'),
  ('from_domain',    'studiior.app',          'Envelope domain. The from NAME is the studio; only the domain is ours, because it is the one that is verified with the provider.'),
  ('batch_size',     '50',                    'Rows one worker pass will claim.'),
  ('max_attempts',   '3',                     'After this many failures a row stops being retried and stays failed with its last error.');

create function notification_setting(p_key text) returns text
language sql stable security definer set search_path = public as $$
  select value from notification_config where key = p_key
$$;

/**
 * The provider key, from Vault or a database setting. Null when neither is
 * configured — which the caller must handle rather than assume.
 */
create function notification_api_key() returns text
language plpgsql stable security definer set search_path = public, vault as $$
declare v text;
begin
  begin
    select decrypted_secret into v from vault.decrypted_secrets
     where name = 'RESEND_API_KEY' limit 1;
  exception when others then
    v := null;
  end;
  return coalesce(nullif(v, ''), nullif(current_setting('app.resend_api_key', true), ''));
end $$;

revoke execute on function notification_setting(text) from public;
revoke execute on function notification_api_key() from public;
grant execute on function notification_setting(text) to service_role;
grant execute on function notification_api_key() to service_role;

-- -----------------------------------------------------------------------------
-- Templates
--
-- Plain text and HTML, branded with the studio's accent and logo from
-- migration 029. The from-name is the studio: a member who gets an email from
-- "Studiior" about a class at Reform Collective has been sent something by a
-- company they have never heard of.
-- -----------------------------------------------------------------------------
create table notification_templates (
  key        text primary key,
  subject    text not null,
  text_body  text not null,
  html_body  text not null,
  note       text
);
alter table notification_templates enable row level security;
create policy notif_templates_read on notification_templates for select using (true);
create policy notif_templates_platform on notification_templates
  for all using (is_platform_admin()) with check (is_platform_admin());
grant select on notification_templates to authenticated;
grant all on notification_templates to service_role;

insert into notification_templates (key, subject, text_body, html_body, note) values
('booking_confirmed', 'You''re booked in — {class_name}',
 E'Hi {first_name},\n\nYou''re booked into {class_name} on {when}.\n\n{where_line}\n\nIf you can''t make it, cancel in the app and the place goes to someone on the list.\n\n{studio_name}',
 E'<p>Hi {first_name},</p><p>You''re booked into <strong>{class_name}</strong> on {when}.</p><p>{where_line}</p><p>If you can''t make it, cancel in the app and the place goes to someone on the list.</p>',
 'Immediate. §12.'),

('class_reminder', '{class_name} {when_short}',
 E'Hi {first_name},\n\n{class_name} is {when_short}, at {when_time}.\n\n{where_line}\n\nSee you there.\n\n{studio_name}',
 E'<p>Hi {first_name},</p><p><strong>{class_name}</strong> is {when_short}, at {when_time}.</p><p>{where_line}</p><p>See you there.</p>',
 'reminder_hours_before, default 12. §12.'),

('waitlist_offer', 'A place has opened — {class_name}',
 E'Hi {first_name},\n\nA place has opened in {class_name} on {when}.\n\nIt''s held for you until {expires_at}. Open the app to take it.\n\n{studio_name}',
 E'<p>Hi {first_name},</p><p>A place has opened in <strong>{class_name}</strong> on {when}.</p><p>It''s held for you until {expires_at}. Open the app to take it.</p>',
 'Immediate on promotion. §12, §4.2.'),

('class_cancelled', '{class_name} on {when} is cancelled',
 E'Hi {first_name},\n\nWe''ve had to cancel {class_name} on {when}. Sorry.\n\nYour credit is back on your account — nothing has been used.\n\n{studio_name}',
 E'<p>Hi {first_name},</p><p>We''ve had to cancel <strong>{class_name}</strong> on {when}. Sorry.</p><p>Your credit is back on your account — nothing has been used.</p>',
 'Immediate. §3.2. Not opt-outable.'),

('instructor_substituted', 'A change to {class_name} on {when}',
 E'Hi {first_name},\n\n{new_instructor} will be teaching {class_name} on {when} instead of {old_instructor}.\n\nEverything else is the same.\n\n{studio_name}',
 E'<p>Hi {first_name},</p><p>{new_instructor} will be teaching <strong>{class_name}</strong> on {when} instead of {old_instructor}.</p><p>Everything else is the same.</p>',
 'Immediate. §3.3. Not opt-outable.'),

('payment_failed', 'Your payment didn''t go through',
 E'Hi {first_name},\n\nYour last payment didn''t go through, so your membership is on hold until it''s sorted. Nothing is lost and nothing has been cancelled.\n\nPop into the studio or reply to this and we''ll sort it.\n\n{studio_name}',
 E'<p>Hi {first_name},</p><p>Your last payment didn''t go through, so your membership is on hold until it''s sorted. Nothing is lost and nothing has been cancelled.</p><p>Pop into the studio or reply to this and we''ll sort it.</p>',
 'Day 0, 3 and 6 of grace. §12, Decision 4. Not opt-outable.'),

('credit_expiry', '{credits} classes expiring on {expires_on}',
 E'Hi {first_name},\n\nYou have {credits} classes left and they run out on {expires_on}.\n\nThat''s a week from now, so there''s still time to use them.\n\n{studio_name}',
 E'<p>Hi {first_name},</p><p>You have <strong>{credits}</strong> classes left and they run out on {expires_on}.</p><p>That''s a week from now, so there''s still time to use them.</p>',
 '7 days before. §12.'),

('milestone', '{milestone_name}',
 E'Hi {first_name},\n\n{milestone_body}\n\n{studio_name}',
 E'<p>Hi {first_name},</p><p>{milestone_body}</p>',
 'Immediate on check-in. §12, §8.'),

('staff_message', '{subject}',
 E'{body}',
 E'{body_html}',
 'A message written by a person at the studio — migration 022. The subject and body are theirs, not a template.');

-- -----------------------------------------------------------------------------
-- Queueing
--
-- The preference check lives here. A row a member has opted out of is never
-- written, so it cannot later be sent by a worker that forgot to ask — and
-- the queue is a list of things that may be sent, not a list of candidates.
--
-- Three events are deliberately not opt-outable: a cancelled class, a
-- substituted instructor and a failed payment. There is no reading of "I
-- turned off emails" that makes it right to let somebody turn up to a class
-- that is not running.
-- -----------------------------------------------------------------------------
create function notification_wanted(p_member_id uuid, p_template text)
returns boolean
language plpgsql stable security definer set search_path = public as $$
declare p notification_preferences%rowtype;
begin
  if p_template in ('class_cancelled', 'instructor_substituted',
                    'payment_failed', 'staff_message') then
    return true;
  end if;

  select * into p from notification_preferences where member_id = p_member_id;
  -- No row means defaults, and every default is on. A member who has never
  -- touched their settings has not opted out of anything.
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
end $$;

/**
 * Put one notification on the queue.
 *
 * Returns the row, or null when the member has opted out or the same
 * dedupe_key is already queued. Both are ordinary outcomes, not errors: a
 * caller firing on every check-in should not have to catch an exception to
 * find out that this member has already been told.
 */
create function queue_notification(
  p_studio_id    uuid,
  p_member_id    uuid,
  p_template_key text,
  p_payload      jsonb,
  p_dedupe_key   text,
  p_scheduled_for timestamptz default now()
) returns uuid
-- Returns the id, not the row. `composite IS NOT NULL` in plpgsql is true only
-- when EVERY field is non-null, and a freshly queued notification has a null
-- sent_at — so `queue_notification(...) is not null` read as false on success
-- and every caller's counter came back zero while the rows were being written
-- perfectly well. A uuid has no such trap.
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not notification_wanted(p_member_id, p_template_key) then
    return null;
  end if;

  insert into notifications (studio_id, recipient_type, member_id, template_key,
                             channel, payload, dedupe_key, scheduled_for, status)
  values (p_studio_id, 'member', p_member_id, p_template_key,
          'email', coalesce(p_payload, '{}'::jsonb), p_dedupe_key,
          p_scheduled_for, 'scheduled')
  on conflict (dedupe_key) do nothing
  returning id into v_id;

  return v_id;  -- null when the dedupe key was already there
end $$;

revoke execute on function notification_wanted(uuid, text) from public;
revoke execute on function queue_notification(uuid, uuid, text, jsonb, text, timestamptz) from public;
grant execute on function notification_wanted(uuid, text) to authenticated, service_role;
grant execute on function queue_notification(uuid, uuid, text, jsonb, text, timestamptz)
  to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- The events, from §12's table
--
-- Each builds a deterministic dedupe key, so the same fact queued twice is one
-- row however many times a trigger or a retry fires.
-- -----------------------------------------------------------------------------
create function queue_booking_notifications(p_booking_id uuid) returns int
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
  v_where := coalesce((select 'In ' || r.name || '.' from rooms r where r.id = o.room_id), '');

  if queue_notification(b.studio_id, b.member_id, 'booking_confirmed',
        jsonb_build_object('class_name', o.name, 'when', v_when, 'where_line', v_where),
        'booking_confirmed:' || b.id) is not null then n := n + 1; end if;

  -- §12: the reminder is scheduled, not sent. A class more than
  -- reminder_hours_before away gets a row dated for then; one closer than that
  -- gets nothing, because a reminder that arrives after the class is worse
  -- than none.
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

create function queue_occurrence_cancelled(p_occurrence_id uuid) returns int
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
          jsonb_build_object('class_name', o.name, 'when', v_when),
          'class_cancelled:' || p_occurrence_id || ':' || r.member_id) is not null
    then n := n + 1; end if;
  end loop;

  -- Cancelling the class also cancels anything still queued about it: a
  -- reminder for a class that is not running is the worst email a studio
  -- sends.
  update notifications set status = 'cancelled'
   where status = 'scheduled'
     and dedupe_key like 'class_reminder:%'
     and payload ->> 'class_name' = o.name
     and member_id in (select member_id from bookings where occurrence_id = p_occurrence_id);

  return n;
end $$;

create function queue_substitution(p_occurrence_id uuid, p_old text, p_new text) returns int
language plpgsql security definer set search_path = public as $$
declare o class_occurrences%rowtype; s studios%rowtype; r record; n int := 0; v_when text;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  select * into s from studios where id = o.studio_id;
  v_when := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth');

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
end $$;

create function queue_waitlist_offer(p_offer_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare
  ofr waitlist_offers%rowtype; b bookings%rowtype;
  o class_occurrences%rowtype; s studios%rowtype;
begin
  select * into ofr from waitlist_offers where id = p_offer_id;
  if not found then return 0; end if;
  select * into b from bookings          where id = ofr.booking_id;
  select * into o from class_occurrences where id = ofr.occurrence_id;
  select * into s from studios           where id = ofr.studio_id;

  return case when queue_notification(ofr.studio_id, b.member_id, 'waitlist_offer',
      jsonb_build_object('class_name', o.name,
                         'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth, HH24:MI'),
                         'expires_at', to_char(ofr.expires_at at time zone s.timezone, 'HH24:MI')),
      'waitlist_offer:' || p_offer_id) is not null then 1 else 0 end;
end $$;

/** Day 0, 3 and 6 of the grace period — §12, Decision 4. */
create function queue_payment_failed(p_membership_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare ms memberships%rowtype; n int := 0; d int;
begin
  select * into ms from memberships where id = p_membership_id;
  if not found then return 0; end if;

  foreach d in array array[0, 3, 6] loop
    if queue_notification(ms.studio_id, ms.member_id, 'payment_failed',
          jsonb_build_object('day', d),
          'payment_failed:' || p_membership_id || ':' || d,
          now() + make_interval(days => d)) is not null
    then n := n + 1; end if;
  end loop;
  return n;
end $$;

/** Seven days before credits run out — §12. Run daily. */
create function queue_credit_expiries(p_studio_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; v_tz text;
begin
  if not is_manager_up(p_studio_id) and not is_platform_admin()
     and not is_service_context() then
    raise exception 'not permitted' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;

  for r in
    select ms.member_id, ms.id, ms.credits_remaining, ms.expires_on
      from memberships ms
     where ms.studio_id = p_studio_id
       and ms.status = 'active'
       and ms.credits_remaining > 0
       and ms.expires_on = ((now() at time zone v_tz)::date + 7)
  loop
    if queue_notification(p_studio_id, r.member_id, 'credit_expiry',
          jsonb_build_object('credits', r.credits_remaining,
                             'expires_on', to_char(r.expires_on, 'FMDD FMMonth')),
          'credit_expiry:' || r.id || ':' || r.expires_on) is not null
    then n := n + 1; end if;
  end loop;
  return n;
end $$;

create function queue_milestone(p_member_id uuid, p_name text, p_body text) returns int
language plpgsql security definer set search_path = public as $$
declare m members%rowtype;
begin
  select * into m from members where id = p_member_id;
  return case when queue_notification(m.studio_id, p_member_id, 'milestone',
      jsonb_build_object('milestone_name', p_name, 'milestone_body', p_body),
      'milestone:' || p_member_id || ':' || p_name) is not null then 1 else 0 end;
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'queue_booking_notifications(uuid)', 'queue_occurrence_cancelled(uuid)',
    'queue_substitution(uuid,text,text)', 'queue_waitlist_offer(uuid)',
    'queue_payment_failed(uuid)', 'queue_credit_expiries(uuid)',
    'queue_milestone(uuid,text,text)']
  loop
    execute format('revoke execute on function %s from public', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- Rendering
-- -----------------------------------------------------------------------------
create function render_notification(p_notification_id uuid)
returns table (to_email text, from_name text, subject text, text_body text, html_body text)
language plpgsql stable security definer set search_path = public as $$
declare
  n notifications%rowtype; t notification_templates%rowtype;
  m members%rowtype; s studios%rowtype;
  v_sub text; v_txt text; v_html text; k text; ramp text;
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

  -- Payload first, then the two every template may use.
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

  -- The accent is used raw here for a rule and a heading, never for body text:
  -- email clients cannot be relied on to render a derived ramp faithfully, and
  -- a colour that fails contrast in somebody's inbox is not worth the flourish.
  ramp := coalesce(s.accent_color, '#BEF738');

  return query select
    m.email,
    s.name,      -- the from-name is the studio, never Studiior
    v_sub,
    -- The templates already sign off with the studio name; appending it here
    -- as well gave every email two of them.
    v_txt,
    '<div style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;'
      || 'font-size:15px;line-height:22px;color:#14170E;max-width:520px;margin:0 auto;padding:24px">'
      || case when s.logo_url is not null
              then '<img src="' || s.logo_url || '" alt="' || s.name
                   || '" width="40" height="40" style="border-radius:6px;display:block;margin-bottom:16px">'
              else '<div style="font-weight:600;font-size:17px;margin-bottom:16px">' || s.name || '</div>'
         end
      || '<div style="height:3px;width:44px;background:' || ramp || ';margin-bottom:20px"></div>'
      || v_html
      || '<p style="color:#78716C;font-size:13px;line-height:18px;margin-top:28px;'
      || 'border-top:1px solid #E7E5E4;padding-top:14px">' || s.name || '</p></div>';
end $$;

-- -----------------------------------------------------------------------------
-- The transport, behind one call
--
-- send_via_resend is one function. SMTP is a second one and a changed config
-- row; nothing above this line knows which is in use.
-- -----------------------------------------------------------------------------
create function send_via_resend(
  p_to text, p_from_name text, p_subject text, p_text text, p_html text
) returns bigint
language plpgsql security definer set search_path = public, net as $$
declare v_key text; v_from text;
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

  return net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_key,
                                  'Content-Type', 'application/json'),
    body := jsonb_build_object('from', v_from, 'to', jsonb_build_array(p_to),
                               'subject', p_subject, 'text', p_text, 'html', p_html),
    timeout_milliseconds := 8000);
end $$;

create function deliver_notification(p_notification_id uuid) returns bigint
language plpgsql security definer set search_path = public as $$
declare r record; v_transport text;
begin
  select * into r from render_notification(p_notification_id);
  v_transport := notification_setting('transport');

  if v_transport = 'resend' then
    return send_via_resend(r.to_email, r.from_name, r.subject, r.text_body, r.html_body);
  end if;
  raise exception 'no transport called %', v_transport using errcode = 'PT501';
end $$;

-- -----------------------------------------------------------------------------
-- The worker
--
-- Claims with FOR UPDATE SKIP LOCKED and flips to 'sending' in the same
-- statement, so two overlapping runs cannot both take the same row. dedupe_key
-- stops a duplicate ROW; this is what stops one row being sent twice.
--
-- A missing API key marks the row failed with the reason and returns. It does
-- not raise, because a raise here kills the cron job and a studio with an
-- unconfigured key would lose every notification, not just this one.
-- -----------------------------------------------------------------------------
create function send_due_notifications() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r record; v_req bigint; n_posted int := 0; n_failed int := 0; n_bridged int := 0;
  v_batch int; v_max int;
begin
  if not is_service_context() then
    raise exception 'the notification worker runs as the backend, not as a user'
      using errcode = 'PT403';
  end if;

  v_batch := coalesce(notification_setting('batch_size')::int, 50);
  v_max   := coalesce(notification_setting('max_attempts')::int, 3);

  -- Messages written by staff (migration 022) join the same queue rather than
  -- getting their own sender. send_message() moves a draft to 'queued' and
  -- stops; this is the thing that was always going to pick it up.
  for r in select * from messages where status = 'queued' loop
    if queue_notification(r.studio_id, r.member_id, 'staff_message',
         jsonb_build_object('subject', r.subject,
                            'body', r.body,
                            'body_html', '<p>' || replace(
                                replace(r.body, '&', '&amp;'), E'\n\n', '</p><p>') || '</p>'),
         'message:' || r.id) is not null
    then n_bridged := n_bridged + 1; end if;
    update messages set status = 'sent', sent_at = now() where id = r.id;
  end loop;

  for r in
    update notifications
       set status = 'sending', claimed_at = now(), attempts = attempts + 1
     where id in (
       select id from notifications
        where status = 'scheduled'
          and scheduled_for <= now()
          and attempts < v_max
        order by scheduled_for
        limit v_batch
        for update skip locked
     )
    returning *
  loop
    begin
      v_req := deliver_notification(r.id);
      update notifications set net_request_id = v_req where id = r.id;
      n_posted := n_posted + 1;
    exception when others then
      -- Including the missing-key case. The row keeps its error and its
      -- attempt count; the cron survives.
      update notifications
         set status = 'failed', failed_at = now(), error = sqlerrm
       where id = r.id;
      n_failed := n_failed + 1;
    end;
  end loop;

  return jsonb_build_object('posted', n_posted, 'failed', n_failed,
                            'messages_bridged', n_bridged);
end $$;

/**
 * Second pass: turn the provider's answer into sent or failed.
 *
 * pg_net is asynchronous, so 'sending' means posted and not yet answered.
 * Marking a row sent at post time would record a hope rather than a fact.
 */
create function reconcile_notification_sends() returns jsonb
language plpgsql security definer set search_path = public, net as $$
declare r record; n_sent int := 0; n_failed int := 0; resp record;
begin
  if not is_service_context() then
    raise exception 'the notification worker runs as the backend, not as a user'
      using errcode = 'PT403';
  end if;

  for r in select * from notifications
            where status = 'sending' and net_request_id is not null
  loop
    select * into resp from net._http_response where id = r.net_request_id;
    if not found then
      -- Still in flight, unless it has been too long to be believable.
      if r.claimed_at < now() - interval '10 minutes' then
        update notifications
           set status = 'failed', failed_at = now(),
               error = 'No response from the provider within ten minutes.'
         where id = r.id;
        n_failed := n_failed + 1;
      end if;
      continue;
    end if;

    if resp.status_code between 200 and 299 then
      update notifications
         set status = 'sent', sent_at = now(), error = null,
             provider_message_id = resp.content::jsonb ->> 'id'
       where id = r.id;
      n_sent := n_sent + 1;
    else
      update notifications
         set status = 'failed', failed_at = now(),
             error = coalesce(resp.error_msg,
                              'HTTP ' || coalesce(resp.status_code::text, '?')
                              || ': ' || left(coalesce(resp.content, ''), 300))
       where id = r.id;
      n_failed := n_failed + 1;
    end if;
  end loop;

  return jsonb_build_object('sent', n_sent, 'failed', n_failed);
end $$;

revoke execute on function render_notification(uuid) from public;
revoke execute on function send_via_resend(text,text,text,text,text) from public;
revoke execute on function deliver_notification(uuid) from public;
revoke execute on function send_due_notifications() from public;
revoke execute on function reconcile_notification_sends() from public;
grant execute on function render_notification(uuid) to authenticated, service_role;
grant execute on function send_due_notifications() to service_role;
grant execute on function reconcile_notification_sends() to service_role;

-- -----------------------------------------------------------------------------
-- Every minute
-- -----------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron is not available here; notifications will queue and '
                 'never send. Call send_due_notifications() externally.';
    return;
  end if;
  create extension if not exists pg_cron;

  if exists (select 1 from cron.job where jobname = 'studiior-send-notifications') then
    perform cron.unschedule('studiior-send-notifications');
  end if;
  if exists (select 1 from cron.job where jobname = 'studiior-reconcile-notifications') then
    perform cron.unschedule('studiior-reconcile-notifications');
  end if;

  perform cron.schedule('studiior-send-notifications', '* * * * *',
    $job$select send_due_notifications()$job$);
  perform cron.schedule('studiior-reconcile-notifications', '* * * * *',
    $job$select reconcile_notification_sends()$job$);
end $$;

comment on function send_due_notifications() is
  'Claims due notifications, posts them through the configured transport and '
  'records the request id. Never raises on a bad send: a raise here would take '
  'the cron down and lose every other studio''s notifications too.';
