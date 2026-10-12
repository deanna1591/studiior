-- Decision 77a — the shared email composer's two server dependencies.
--
-- re-issues: send_campaign_test(uuid, text, text), send_campaign(uuid, timestamptz, text, text)
--
-- (1) The studio-branding bucket write policies widen from OWNER-only to
--     manager-up: Decision 70 made managers run the studio, and an email photo
--     is day-to-day work. The Branding PAGE stays owner-only (its own gate); the
--     bucket now accepts a manager's upload into their own studio's folder.
-- (2) The campaign body markup is now parsed in ONE place — lib/email-body.mjs,
--     in Next — so send_campaign_test and send_campaign receive the rendered
--     html/text instead of building <p> HTML in SQL. The old paragraph-split is
--     kept only as a fallback when a caller passes nothing, so any existing
--     direct call still renders. No new anon RPC — THIRTEEN stays THIRTEEN.

-- =============================================================================
-- 1. studio-branding write policies → manager-up (was owner-only, 20260830390000)
-- =============================================================================
drop policy if exists "owners write their own studio's branding"   on storage.objects;
drop policy if exists "owners replace their own studio's branding" on storage.objects;
drop policy if exists "owners delete their own studio's branding"  on storage.objects;

create policy "managers write their own studio's branding"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'studio-branding'
    and coalesce(is_manager_up((storage.foldername(name))[1]::uuid), false)
  );
create policy "managers replace their own studio's branding"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'studio-branding'
    and coalesce(is_manager_up((storage.foldername(name))[1]::uuid), false)
  );
create policy "managers delete their own studio's branding"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'studio-branding'
    and coalesce(is_manager_up((storage.foldername(name))[1]::uuid), false)
  );

-- =============================================================================
-- 2. send_campaign_test — take the pre-rendered html/text (signature change).
--    Byte-for-byte 20260832170000 except: the args, and v_html/v_text resolve
--    from p_html/p_text (fallback to the old split when null).
-- =============================================================================
drop function if exists send_campaign_test(uuid);
create function send_campaign_test(p_campaign_id uuid, p_html text default null, p_text text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c campaigns%rowtype; s studios%rowtype; v_email text; v_html text; v_text text;
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
  -- Decision 77: the body is rendered in Next (lib/email-body). The old SQL
  -- split is the fallback for a caller that passes nothing.
  v_html := coalesce(p_html, '<p>' || replace(replace(c.body, '&', '&amp;'), E'\n\n', '</p><p>') || '</p>');
  v_text := coalesce(p_text, c.body);

  insert into notifications
    (studio_id, recipient_type, member_id, template_key, channel, payload, dedupe_key, scheduled_for, status)
  values
    (c.studio_id, 'member', null, 'campaign', 'email',
     jsonb_build_object('to_email', v_email, 'subject', '[Test] ' || c.subject,
       'body', v_text, 'body_html', v_html, 'studio_name', s.name,
       'unsubscribe_url', member_portal_url(c.studio_id, '/unsubscribe/preview')),
     'campaign_test:' || c.id || ':' || gen_random_uuid(), now(), 'scheduled');

  return jsonb_build_object('ok', true, 'sentence', 'Sent a test to ' || v_email || '.');
end $$;
revoke all on function send_campaign_test(uuid, text, text) from public, anon;
grant execute on function send_campaign_test(uuid, text, text) to authenticated, service_role;

-- =============================================================================
-- 3. send_campaign — same, pre-rendered html/text baked into each payload.
-- =============================================================================
drop function if exists send_campaign(uuid, timestamptz);
create function send_campaign(p_campaign_id uuid, p_when timestamptz default now(),
                              p_html text default null, p_text text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c campaigns%rowtype; s studios%rowtype; v_tz text; v_fmt text;
  v_html text; v_text text; r record; v_nid uuid; v_n int := 0; v_date text;
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
  v_html := coalesce(p_html, '<p>' || replace(replace(c.body, '&', '&amp;'), E'\n\n', '</p><p>') || '</p>');
  v_text := coalesce(p_text, c.body);

  for r in select * from campaign_audience(c.studio_id, c.audience) loop
    v_nid := queue_notification(c.studio_id, r.member_id, 'campaign',
      jsonb_build_object('subject', c.subject, 'body', v_text, 'body_html', v_html,
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
revoke all on function send_campaign(uuid, timestamptz, text, text) from public, anon;
grant execute on function send_campaign(uuid, timestamptz, text, text) to authenticated, service_role;

-- =============================================================================
-- Anon surface stays EXACTLY THIRTEEN (the campaign senders are authenticated;
-- the drop+recreate did not reopen them to anon).
-- =============================================================================
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % functions, expected exactly 13', n; end if;
end $$;
