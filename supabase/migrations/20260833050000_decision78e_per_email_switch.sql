-- Decision 78 amendment (e) — a studio can switch off any one email.
-- creates: studio_template_enabled(uuid, text)
-- re-issues: queue_notification(uuid, uuid, text, jsonb, text, timestamptz), queue_shift_notice(uuid, uuid, text, jsonb, text)
--
-- studio_settings.disabled_templates holds the keys a studio has silenced (a key
-- present = off). ONE predicate, studio_template_enabled, is checked in BOTH queue
-- choke points — queue_notification (member mail) and queue_shift_notice (instructor
-- mail) — so one switch governs every path. Default is nothing disabled (today's
-- behaviour). The switch only ever SUBTRACTS, so the master switch always wins: a
-- sequence whose master is off never reaches this gate (convert_keep_sweep returns
-- early), and there is no "force on" list that could re-enable it. Checked at QUEUE
-- time; a notification already queued still sends. No new anon RPC — THIRTEEN stays.

alter table studio_settings
  add column if not exists disabled_templates text[] not null default '{}'::text[];

create or replace function studio_template_enabled(p_studio_id uuid, p_key text)
returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(
    p_key <> all(coalesce(
      (select disabled_templates from studio_settings where studio_id = p_studio_id),
      '{}'::text[])),
    true);
$$;
revoke execute on function studio_template_enabled(uuid, text) from public, anon, authenticated;
grant  execute on function studio_template_enabled(uuid, text) to service_role;

-- queue_notification — re-issued from 20260831480000 with the one added condition.
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
  if not notification_wanted(p_member_id, p_template_key)
     or not studio_template_enabled(p_studio_id, p_template_key) then
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

-- queue_shift_notice — re-issued from 20260830830000 with the one added condition.
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
  if not studio_template_enabled(p_studio_id, p_template) then
    return null;
  end if;
  insert into notifications (studio_id, recipient_type, user_id, template_key,
                             channel, payload, dedupe_key, scheduled_for, status)
  values (p_studio_id, 'staff', p_user_id, p_template, 'email',
          p_payload, p_dedupe, now(), 'scheduled')
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  return v_id;
end $$;

-- These re-issues keep the ACLs create-or-replace preserved; re-assert to be sure.
revoke execute on function queue_notification(uuid, uuid, text, jsonb, text, timestamptz) from public, anon, authenticated;
grant  execute on function queue_notification(uuid, uuid, text, jsonb, text, timestamptz) to service_role;
revoke execute on function queue_shift_notice(uuid, uuid, text, jsonb, text) from public, anon, authenticated;
grant  execute on function queue_shift_notice(uuid, uuid, text, jsonb, text) to service_role;

-- The anon surface is unchanged: exactly THIRTEEN.
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % not 13', n; end if;
end $$;
