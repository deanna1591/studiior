-- Decision 26 (b): resend a guest's claim+waiver invite from the staff member page.
-- creates: resend_guest_invite(uuid)
--
-- The one staff RPC that re-sends the GUEST invite template. invite_member sends
-- the plain `member_invite` ("the studio set you up"), which a guest should not
-- get — a guest needs the `guest_invite` ("{host} booked you a free class, set a
-- password and sign the waiver"). book_guest mints+sends it inline when the host
-- books; this re-sends it: a fresh token, the old one revoked, the same payload
-- (host name, class name, claim link). Desk-up, audited, not anon.

create or replace function resend_guest_invite(p_member_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $$
declare
  v_member members%rowtype;
  v_pass   guest_passes%rowtype;
  v_host   members%rowtype;
  v_occ    class_occurrences%rowtype;
  v_studio studios%rowtype;
  v_token  text;
  v_exp    timestamptz;
  v_url    text;
begin
  select * into v_member from members where id = p_member_id;
  if not found then
    raise exception 'no such member' using errcode = 'PT404';
  end if;
  if not is_desk_up(v_member.studio_id) then
    raise exception 'only owners, managers and front desk may resend an invite'
      using errcode = 'PT403', hint = 'Permissions §5.';
  end if;
  if v_member.user_id is not null then
    raise exception '% already has an account', v_member.first_name using errcode = 'PT409';
  end if;

  -- The guest pass that brought them in. host_member_id not null, so a host-null
  -- free-first self-signup (Decision 30/158) — nobody brought them — is refused.
  select * into v_pass from guest_passes
    where guest_member_id = p_member_id and host_member_id is not null
    order by created_at desc limit 1;
  if not found then
    raise exception '% was not brought in as a guest', v_member.first_name
      using errcode = 'PT400';
  end if;

  select * into v_host from members where id = v_pass.host_member_id;
  select * into v_studio from studios where id = v_member.studio_id;
  if v_pass.occurrence_id is not null then
    select * into v_occ from class_occurrences where id = v_pass.occurrence_id;
  end if;

  -- Fresh token; supersede the outstanding one (the newest link is the one that
  -- works), exactly as create_member_invite does.
  v_token := encode(gen_random_bytes(24), 'hex');
  v_exp   := now() + interval '14 days';
  delete from member_invites where member_id = p_member_id and accepted_at is null;
  insert into member_invites (studio_id, member_id, email, token_hash, expires_at, created_by)
  values (v_member.studio_id, v_member.id, v_member.email,
          encode(digest(v_token, 'sha256'), 'hex'), v_exp, auth.uid());

  v_url := 'https://' || v_studio.slug || '.'
           || coalesce(notification_setting('member_app_domain'), 'studiior.app')
           || '/claim/' || v_token;

  -- The same guest_invite email book_guest sends; a fresh dedupe key so a manual
  -- resend always goes out.
  perform queue_notification(v_member.studio_id, p_member_id, 'guest_invite',
    jsonb_build_object('claim_url', v_url,
                       'host_name', coalesce(v_host.first_name, 'a member'),
                       'class_name', coalesce(v_occ.name, 'your class')),
    'guest_invite_resend:' || p_member_id || ':' || gen_random_uuid());

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (v_member.studio_id, auth.uid(), 'guest_invite.resent', 'members', p_member_id,
          jsonb_build_object('expires_at', v_exp, 'guest_pass', v_pass.id));

  return jsonb_build_object('ok', true, 'email', v_member.email, 'expires_at', v_exp);
end $$;

revoke execute on function resend_guest_invite(uuid) from public, anon;
grant execute on function resend_guest_invite(uuid) to authenticated, service_role;

-- No new anon surface — EXACTLY THIRTEEN (asserted at apply).
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is %, expected 13', n; end if;
end $$;
