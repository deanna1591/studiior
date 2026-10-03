-- =============================================================================
-- Decision 50 — Email campaigns: write to a filtered, consented group of members.
-- =============================================================================
-- creates:   campaign_audience(uuid, jsonb), send_campaign(uuid, timestamptz),
--            send_campaign_test(uuid), campaign_status(uuid), cancel_campaign(uuid),
--            unsubscribe_marketing(uuid), notification_envelope_domain(text),
--            member_portal_url(uuid, text)
-- re-issues: notification_wanted(uuid, text), deliver_notification(uuid),
--            send_via_resend(text, text, text, text, text, text, text, text)
--
-- A manager-up Campaigns screen sends ONE email to an audience chosen with the
-- Members-page filters, consent-gated on marketing_opt_in and delivered by the
-- existing worker — a campaign is one more sender into the queue, not a second
-- mail system. The one-tap unsubscribe is the thirteenth anon surface. Marketing
-- mail can later move to its own verified domain with one config row, no code.
-- =============================================================================

-- --- Schema: the consent token/stamp, and the two campaign tables ------------
-- marketing_opt_in already exists (member-editable, in guard_member_self_update's
-- owned allowlist). The token and the unsubscribe stamp are NOT in that allowlist,
-- so a logged-in member cannot forge them; the anon unsubscribe writes them as a
-- definer with auth.uid() null, which the guard permits.
alter table members
  add column if not exists marketing_unsubscribed_at timestamptz,
  add column if not exists marketing_token uuid not null default gen_random_uuid();
create unique index if not exists members_marketing_token on members(marketing_token);

create table if not exists campaigns (
  id              uuid primary key default gen_random_uuid(),
  studio_id       uuid not null references studios on delete cascade,
  subject         text not null default '',
  body            text not null default '',
  audience        jsonb not null default '{}',
  status          text not null default 'draft'
                    check (status in ('draft','scheduled','sending','sent','cancelled')),
  scheduled_for   timestamptz,
  sent_at         timestamptz,
  recipient_count int not null default 0,
  created_by      uuid references profiles on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists campaigns_studio on campaigns(studio_id, created_at desc);

create table if not exists campaign_recipients (
  campaign_id     uuid not null references campaigns on delete cascade,
  member_id       uuid not null references members on delete cascade,
  notification_id uuid references notifications on delete set null,
  primary key (campaign_id, member_id)
);

alter table campaigns enable row level security;
alter table campaign_recipients enable row level security;
create policy campaigns_manager on campaigns for all
  using (coalesce(is_manager_up(studio_id), false))
  with check (coalesce(is_manager_up(studio_id), false));
create policy campaign_recipients_manager on campaign_recipients for all
  using (coalesce(is_manager_up((select c.studio_id from campaigns c where c.id = campaign_id)), false))
  with check (coalesce(is_manager_up((select c.studio_id from campaigns c where c.id = campaign_id)), false));
grant select, insert, update, delete on campaigns to authenticated, service_role;
grant select, insert, update, delete on campaign_recipients to authenticated, service_role;

-- --- Config: marketing's envelope domain defaults to the transactional one ---
insert into notification_config (key, value, note)
select 'marketing_from_domain',
       (select value from notification_config where key = 'from_domain'),
       'Envelope domain for campaign mail only. Verify mail.studiior.app in Resend and change this row to move marketing off the transactional domain.'
on conflict (key) do nothing;

-- --- Template: the campaign body + the consent/unsubscribe footer ------------
insert into notification_templates (key, subject, text_body, html_body, note) values
('campaign', '{subject}',
 E'{body}\n\n—\nYou''re receiving this because you said yes to news from {studio_name}.\nUnsubscribe: {unsubscribe_url}',
 E'{body_html}<p style="color:#78716C;font-size:13px;line-height:18px;margin-top:24px">You''re receiving this because you said yes to news from {studio_name}. <a href="{unsubscribe_url}" style="color:#57534E">Unsubscribe</a></p>',
 'Decision 50. A campaign email: body/body_html plus the consent footer with the one-tap unsubscribe link.')
on conflict (key) do nothing;

-- --- The envelope-domain resolver: marketing_from_domain for 'campaign' only -
-- One source of the decision, so send_via_resend just uses the domain it is
-- handed and the suite can assert the choice without posting anything.
create or replace function notification_envelope_domain(p_template text)
returns text language sql stable security definer set search_path = public as $$
  select case when p_template = 'campaign'
    then coalesce(nullif(notification_setting('marketing_from_domain'), ''), notification_setting('from_domain'))
    else notification_setting('from_domain') end;
$$;
revoke execute on function notification_envelope_domain(text) from public, anon, authenticated;
grant  execute on function notification_envelope_domain(text) to service_role;

-- --- send_via_resend gains p_from_domain (8th). Drop+recreate (adding a default
--     param is an overload, the 028 footgun), re-asserting the service-only ACL.
--     Body byte-copied from 20260831790000 with only the domain line changed.
drop function if exists send_via_resend(text, text, text, text, text, text, text);
create function send_via_resend(
  p_to text, p_from_name text, p_reply_to text,
  p_subject text, p_text text, p_html text,
  p_ics text default null, p_from_domain text default null
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

  -- Campaign mail may ride its own verified domain; everything else, and a null
  -- domain, uses the transactional from_domain exactly as before.
  v_from := replace(p_from_name, '"', '') || ' <notifications@'
            || coalesce(nullif(p_from_domain, ''), notification_setting('from_domain')) || '>';

  v_body := jsonb_build_object('from', v_from, 'to', jsonb_build_array(p_to),
                               'subject', p_subject, 'text', p_text, 'html', p_html);
  if p_reply_to is not null then
    v_body := v_body || jsonb_build_object('reply_to', p_reply_to);
  end if;

  if nullif(p_ics, '') is not null then
    v_method := coalesce(substring(p_ics from 'METHOD:([A-Z]+)'), 'PUBLISH');
    v_body := v_body || jsonb_build_object('attachments', jsonb_build_array(
      jsonb_build_object(
        'filename', 'studiior.ics',
        'content', translate(encode(convert_to(p_ics, 'UTF8'), 'base64'), E'\n', ''),
        'content_type', 'text/calendar; charset=utf-8; method=' || v_method)));
  end if;

  return net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_key,
                                  'Content-Type', 'application/json'),
    body := v_body,
    timeout_milliseconds := 8000);
end $$;
revoke execute on function send_via_resend(text,text,text,text,text,text,text,text)
  from public, anon, authenticated;
grant  execute on function send_via_resend(text,text,text,text,text,text,text,text)
  to service_role;

-- --- notification_wanted: 'campaign' is consent-only, read LIVE ---------------
-- Re-issued from 20260832150000 with the campaign branch added at the top, so a
-- member who unsubscribes between schedule and send is skipped at send time too.
create or replace function notification_wanted(p_member_id uuid, p_template text)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare p notification_preferences%rowtype; v_ok boolean;
begin
  -- Decision 50: a campaign goes only to a member whose consent still stands.
  if p_template = 'campaign' then
    select (marketing_opt_in and marketing_unsubscribed_at is null) into v_ok
      from members where id = p_member_id;
    return coalesce(v_ok, false);
  end if;

  if p_template in ('class_cancelled', 'instructor_substituted',
                    'payment_failed', 'staff_message', 'class_moved',
                    'member_invite', 'guest_invite', 'guest_host_cancelled',
                    'guest_waiver_reminder', 'guest_waiver_host_nudge',
                    'flex_booking_confirmed', 'flex_booking_not_confirmed',
                    'free_booking_confirmed', 'free_booking_not_confirmed',
                    'membership_ended', 'membership_frozen') then
    return true;
  end if;

  select * into p from notification_preferences where member_id = p_member_id;
  if not found then
    return true;
  end if;

  return case p_template
    when 'booking_confirmed' then p.booking_email
    when 'flex_booking_pending' then p.booking_email
    when 'free_booking_pending' then p.booking_email
    when 'class_reminder'    then p.reminder_email
    when 'waitlist_offer'    then p.waitlist_email
    when 'waitlist_missed'   then p.waitlist_email
    when 'credit_expiry'     then p.credit_expiry_email
    when 'milestone'         then p.milestone_email
    when 'challenge_started' then p.challenge_email
    when 'challenge_ending'  then p.challenge_email
    when 'challenge_completed' then p.challenge_email
    else true
  end;
end $$;

-- --- deliver_notification: campaign domain + the send-time consent skip -------
-- Re-issued from 20260831660000 (the newest, with the .ics attachment). Two
-- additions: a 'campaign' row to a member who has since unsubscribed is
-- cancelled, not posted (neither sent nor failed); and campaign mail uses the
-- marketing envelope domain. A member_id-null campaign row is a staff test and
-- is never consent-skipped.
create or replace function deliver_notification(p_notification_id uuid) returns bigint
language plpgsql security definer set search_path = public as $$
declare r record; v_transport text; v_ics text; n notifications%rowtype;
begin
  select * into n from notifications where id = p_notification_id;

  if n.template_key = 'campaign' and n.member_id is not null
     and not notification_wanted(n.member_id, 'campaign') then
    update notifications set status = 'cancelled' where id = p_notification_id;
    return null;
  end if;

  select * into r from render_notification(p_notification_id);

  if nullif(r.to_email, '') is null then
    raise exception 'notification % has no recipient address', p_notification_id
      using errcode = 'PT422',
            hint = 'Queued with no member, no staff user and no payload to_email. '
                   'Refused here rather than posting a null recipient to the provider.';
  end if;

  v_ics := notification_ics(p_notification_id);

  v_transport := notification_setting('transport');
  if v_transport = 'resend' then
    return send_via_resend(r.to_email, r.from_name, r.reply_to,
                           r.subject, r.text_body, r.html_body, v_ics,
                           notification_envelope_domain(n.template_key));
  end if;
  raise exception 'unknown transport %', v_transport using errcode = 'PT501';
end $$;

-- --- campaign_audience: the Members filters AND the consent gate --------------
-- Reuses member_plan_overview (Decision 49) for plan_state AND health_band —
-- the same function the Members page reads, so a filter can never disagree with
-- the list. ALWAYS AND'd with consent / not-unsubscribed / not-archived / email.
create or replace function campaign_audience(p_studio_id uuid, p_filter jsonb)
returns table (member_id uuid, first_name text, last_name text, email text)
language plpgsql stable security definer set search_path = public as $$
declare
  v_plan   text := nullif(p_filter ->> 'plan_state', '');
  v_health text := nullif(p_filter ->> 'health', '');
  v_joined int  := nullif(p_filter ->> 'joined_days', '')::int;
  v_tz text; v_today date;
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'campaigns are for owners and managers' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  v_today := (now() at time zone v_tz)::date;

  return query
  select o.id, o.first_name, o.last_name, o.email
    from member_plan_overview(p_studio_id) o
    join members m on m.id = o.id
   where m.marketing_opt_in = true
     and m.marketing_unsubscribed_at is null
     and m.archived_at is null
     and nullif(m.email, '') is not null
     and (v_plan   is null or o.plan_state = v_plan)
     and (v_health is null or o.health_band = v_health)
     and (v_joined is null or m.joined_on >= v_today - v_joined);
end $$;

-- --- send_campaign_test: ONE row to the caller's own staff email --------------
create or replace function send_campaign_test(p_campaign_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c campaigns%rowtype; s studios%rowtype; v_email text; v_html text;
begin
  select * into c from campaigns where id = p_campaign_id;
  if not found then raise exception 'no such campaign' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(c.studio_id), false) then
    raise exception 'campaigns are for owners and managers' using errcode = 'PT403';
  end if;
  select * into s from studios where id = c.studio_id;
  select pr.email into v_email
    from studio_staff ss join profiles pr on pr.id = ss.user_id
   where ss.user_id = auth.uid() and ss.studio_id = c.studio_id limit 1;
  if nullif(v_email, '') is null then
    raise exception 'no staff email to send the test to' using errcode = 'PT404';
  end if;
  v_html := '<p>' || replace(replace(c.body, '&', '&amp;'), E'\n\n', '</p><p>') || '</p>';

  -- Hand-addressed (payload to_email wins in render_notification); member_id null
  -- so deliver_notification never consent-skips it. Not through queue_notification
  -- (which would consent-gate a null member). Unique dedupe per press.
  insert into notifications
    (studio_id, recipient_type, member_id, template_key, channel, payload, dedupe_key, scheduled_for, status)
  values
    (c.studio_id, 'member', null, 'campaign', 'email',
     jsonb_build_object('to_email', v_email, 'subject', '[Test] ' || c.subject,
       'body', c.body, 'body_html', v_html, 'studio_name', s.name,
       'unsubscribe_url', member_portal_url(c.studio_id, '/unsubscribe/preview')),
     'campaign_test:' || c.id || ':' || gen_random_uuid(), now(), 'scheduled');

  return jsonb_build_object('ok', true, 'sentence', 'Sent a test to ' || v_email || '.');
end $$;

-- --- send_campaign: recompute the audience, queue one row each ----------------
create or replace function send_campaign(p_campaign_id uuid, p_when timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c campaigns%rowtype; s studios%rowtype; v_tz text; v_fmt text;
  v_html text; r record; v_nid uuid; v_n int := 0; v_date text;
begin
  select * into c from campaigns where id = p_campaign_id for update;
  if not found then raise exception 'no such campaign' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(c.studio_id), false) then
    raise exception 'campaigns are for owners and managers' using errcode = 'PT403';
  end if;
  if c.status not in ('draft', 'scheduled') then
    raise exception 'This campaign has already been sent.' using errcode = 'PT409';
  end if;
  if nullif(btrim(c.subject), '') is null or nullif(btrim(c.body), '') is null then
    raise exception 'A campaign needs a subject and a message.' using errcode = 'PT400';
  end if;

  select * into s from studios where id = c.studio_id;
  v_tz  := s.timezone;
  v_fmt := coalesce((select time_format from studio_settings where studio_id = c.studio_id), '24h');
  v_html := '<p>' || replace(replace(c.body, '&', '&amp;'), E'\n\n', '</p><p>') || '</p>';

  for r in select * from campaign_audience(c.studio_id, c.audience) loop
    v_nid := queue_notification(c.studio_id, r.member_id, 'campaign',
      jsonb_build_object('subject', c.subject, 'body', c.body, 'body_html', v_html,
        'studio_name', s.name,
        'unsubscribe_url', member_portal_url(c.studio_id,
          '/unsubscribe/' || (select marketing_token from members where id = r.member_id))),
      'campaign:' || c.id || ':' || r.member_id, p_when);
    if v_nid is not null then
      insert into campaign_recipients (campaign_id, member_id, notification_id)
        values (c.id, r.member_id, v_nid)
        on conflict (campaign_id, member_id) do update set notification_id = excluded.notification_id;
      v_n := v_n + 1;
    end if;
  end loop;

  if v_n = 0 then
    raise exception 'Nobody in this audience has opted in to news.' using errcode = 'PT409';
  end if;

  update campaigns set
    status = case when p_when > now() then 'scheduled' else 'sending' end,
    scheduled_for = p_when, recipient_count = v_n, updated_at = now()
  where id = c.id;

  v_date := to_char(p_when at time zone v_tz, 'FMDD FMMonth YYYY') || ' ' || fmt_clock(p_when, v_tz, v_fmt);
  return jsonb_build_object('ok', true, 'count', v_n,
    'sentence', case when p_when > now()
      then 'Scheduled for ' || v_date || ' to ' || v_n || ' member' || case when v_n = 1 then '' else 's' end || '.'
      else 'Sending to ' || v_n || ' member' || case when v_n = 1 then '' else 's' end || '.' end);
end $$;

-- --- campaign_status: counts from the linked rows, flips sending -> sent ------
create or replace function campaign_status(p_campaign_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c campaigns%rowtype; v_sent int; v_failed int; v_pending int;
begin
  select * into c from campaigns where id = p_campaign_id;
  if not found then raise exception 'no such campaign' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(c.studio_id), false) then
    raise exception 'campaigns are for owners and managers' using errcode = 'PT403';
  end if;

  select count(*) filter (where n.status in ('sent', 'delivered')),
         count(*) filter (where n.status = 'failed'),
         count(*) filter (where n.status in ('scheduled', 'sending'))
    into v_sent, v_failed, v_pending
    from campaign_recipients cr
    left join notifications n on n.id = cr.notification_id
   where cr.campaign_id = p_campaign_id;

  if c.status = 'sending' and coalesce(v_pending, 0) = 0 then
    update campaigns set status = 'sent', sent_at = coalesce(sent_at, now()), updated_at = now()
     where id = c.id;
    c.status := 'sent';
  end if;

  return jsonb_build_object('status', c.status, 'recipient_count', c.recipient_count,
    'sent', coalesce(v_sent, 0), 'failed', coalesce(v_failed, 0), 'pending', coalesce(v_pending, 0),
    'scheduled_for', c.scheduled_for, 'sent_at', c.sent_at);
end $$;

-- --- cancel_campaign: only a scheduled, not-yet-started one -------------------
create or replace function cancel_campaign(p_campaign_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c campaigns%rowtype;
begin
  select * into c from campaigns where id = p_campaign_id for update;
  if not found then raise exception 'no such campaign' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(c.studio_id), false) then
    raise exception 'campaigns are for owners and managers' using errcode = 'PT403';
  end if;
  if c.status <> 'scheduled' or c.scheduled_for is null or c.scheduled_for <= now() then
    raise exception 'Only a scheduled campaign can be cancelled, and only before it starts sending.'
      using errcode = 'PT409';
  end if;
  update notifications set status = 'cancelled'
   where id in (select notification_id from campaign_recipients where campaign_id = p_campaign_id)
     and status = 'scheduled';
  update campaigns set status = 'cancelled', updated_at = now() where id = c.id;
  return jsonb_build_object('ok', true);
end $$;

-- --- unsubscribe_marketing: the one-tap opt-out — the THIRTEENTH anon surface -
-- Resolves a hashed-in-the-URL token to the member, turns consent off, stamps
-- the time, audits it. Returns the STUDIO name only — never the member's name
-- or email, because it is anon and the token in the URL is the whole credential.
create or replace function unsubscribe_marketing(p_token uuid)
returns table (studio_name text, already boolean)
language plpgsql security definer set search_path = public as $$
declare m members%rowtype; v_studio text; v_already boolean;
begin
  select * into m from members where marketing_token = p_token;
  if not found then
    raise exception 'This link isn''t valid.' using errcode = 'PT404';
  end if;
  v_already := m.marketing_unsubscribed_at is not null or m.marketing_opt_in = false;
  update members
     set marketing_opt_in = false,
         marketing_unsubscribed_at = coalesce(marketing_unsubscribed_at, now())
   where id = m.id;
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (m.studio_id, null, 'member.marketing_unsubscribed', 'members', m.id,
            jsonb_build_object('via', 'email_link'));
  select name into v_studio from studios where id = m.studio_id;
  return query select v_studio, v_already;
end $$;

-- --- A member-host URL helper, mirroring instructor_portal_url. ---------------
-- (Defined after the functions that call it is fine — plpgsql resolves at call
-- time; but placed here below so the dependency reads clearly.)
create or replace function member_portal_url(p_studio_id uuid, p_path text)
returns text language sql stable security definer set search_path = public as $$
  select 'https://' || s.slug || '.'
         || coalesce(nullif(notification_setting('member_app_domain'), ''), 'studiior.app')
         || p_path
    from studios s where s.id = p_studio_id
$$;
revoke execute on function member_portal_url(uuid, text) from public, anon, authenticated;
grant  execute on function member_portal_url(uuid, text) to service_role;

-- =============================================================================
-- Grants. Campaign readers/writers are authenticated (guard inside); the
-- unsubscribe is anon; the envelope resolver and member URL helper are
-- service-only.
-- =============================================================================
revoke all on function campaign_audience(uuid, jsonb) from public, anon;
revoke all on function send_campaign(uuid, timestamptz) from public, anon;
revoke all on function send_campaign_test(uuid) from public, anon;
revoke all on function campaign_status(uuid) from public, anon;
revoke all on function cancel_campaign(uuid) from public, anon;
grant execute on function campaign_audience(uuid, jsonb) to authenticated, service_role;
grant execute on function send_campaign(uuid, timestamptz) to authenticated, service_role;
grant execute on function send_campaign_test(uuid) to authenticated, service_role;
grant execute on function campaign_status(uuid) to authenticated, service_role;
grant execute on function cancel_campaign(uuid) to authenticated, service_role;

revoke all on function unsubscribe_marketing(uuid) from public;
grant execute on function unsubscribe_marketing(uuid) to anon, authenticated, service_role;

-- =============================================================================
-- The anon surface is now EXACTLY THIRTEEN, and unsubscribe_marketing is it.
-- =============================================================================
do $$
declare n int;
begin
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then
    raise exception 'anon surface is % functions, expected exactly 13', n;
  end if;
  if not has_function_privilege('anon', 'unsubscribe_marketing(uuid)'::regprocedure, 'execute') then
    raise exception 'unsubscribe_marketing is not anon-executable';
  end if;
end $$;
