-- =============================================================================
-- Decision 70 — Studio team access: invite Managers and Front desk, widen Manager.
--
-- creates: invite_staff(text, staff_role, text), set_staff_role(uuid, staff_role),
--          remove_staff(uuid), studio_team(uuid), guard_studios_payment_cols()
-- re-issues: instructor_invite_preview(text), claim_instructor_account(text, text, text)
--
-- (a) invite_staff / set_staff_role / remove_staff — authenticated, SECURITY
--     DEFINER, reusing the instructor-invite mechanism (studio_invites token,
--     same expiry, queue_notification claim link). The claim reuses the
--     instructor claim pair, GENERALISED to roles instructor/manager/front_desk
--     (instructor_id nullable) — so NO new anon surface: anon stays THIRTEEN.
-- (b) Manager widened: the studios UPDATE policy becomes owner-or-manager, with
--     a column guard keeping the payment column (stripe_account_id) owner-only.
--     studio_settings (settings_manager_write) and locations (locations_manager_
--     write) are ALREADY manager-up, so they are unchanged.
-- =============================================================================

-- The name an invited person is shown by before they claim (studio_staff has no
-- name of its own; profiles.full_name arrives at claim). invite_instructor does
-- not set it (it uses the instructor's display_name); invite_staff does.
alter table studio_invites add column if not exists invited_name text;

-- -----------------------------------------------------------------------------
-- (a) invite_staff — owner invites manager/front_desk; manager invites front_desk.
-- -----------------------------------------------------------------------------
create or replace function invite_staff(p_email text, p_role staff_role, p_name text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_email text; v_name text; v_studio uuid; v_caller staff_role;
  s studios%rowtype; v_staff uuid; v_token text; v_id uuid; v_days int := 14;
begin
  -- Role rules: only a manager or front desk may be invited here. An instructor
  -- is invited through invite_instructor (it also creates the teaching record);
  -- an owner is made by promoting an existing member of the team.
  if p_role = 'instructor' then
    raise exception 'invite an instructor from the Instructors page' using errcode = 'PT422';
  end if;
  if p_role not in ('manager', 'front_desk') then
    raise exception 'you can invite a manager or front desk' using errcode = 'PT422';
  end if;

  -- The caller's own studio and role (this product gives a login one staff
  -- studio; staffScreen resolves the same one).
  select ss.studio_id, ss.role into v_studio, v_caller
    from studio_staff ss
   where ss.user_id = auth.uid() and ss.status = 'active' and ss.role in ('owner', 'manager')
   limit 1;
  if v_studio is null then
    raise exception 'only an owner or a manager can invite staff' using errcode = 'PT403';
  end if;
  if v_caller = 'manager' and p_role <> 'front_desk' then
    raise exception 'a manager can invite front desk only' using errcode = 'PT403';
  end if;

  v_email := lower(nullif(btrim(p_email), ''));
  if v_email is null then
    raise exception 'give an email address to send the invite to' using errcode = 'PT422';
  end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'that does not look like an email address' using errcode = 'PT422';
  end if;
  v_name := nullif(btrim(coalesce(p_name, '')), '');

  select * into s from studios where id = v_studio;

  -- Already on the team (active)? Nothing to invite.
  if exists (
    select 1 from studio_staff ss
     where ss.studio_id = v_studio and lower(ss.email) = v_email and ss.status = 'active'
  ) then
    raise exception 'that person is already on your team' using errcode = 'PT409';
  end if;

  -- Reuse a removed/invited row for this email (the studio_staff email index is
  -- not partial, so an INSERT would conflict), else insert. Decision 64's shape.
  select ss.id into v_staff from studio_staff ss
   where ss.studio_id = v_studio and lower(ss.email) = v_email and ss.status in ('invited', 'removed')
   limit 1;
  if v_staff is not null then
    update studio_staff
       set user_id = null, role = p_role, status = 'invited', invited_at = now(), removed_at = null
     where id = v_staff;
  else
    insert into studio_staff (studio_id, user_id, email, role, status, invited_at)
    values (v_studio, null, v_email, p_role, 'invited', now())
    returning id into v_staff;
  end if;

  -- A resend supersedes (the old link dies) — keyed on the token, as Decision 73
  -- /073 learned the hard way.
  delete from studio_invites
   where studio_id = v_studio and lower(email) = v_email and accepted_at is null;

  v_token := encode(gen_random_bytes(24), 'hex');
  insert into studio_invites (studio_id, email, token_hash, expires_at, created_by, role, instructor_id, invited_name)
  values (v_studio, v_email, encode(digest(v_token, 'sha256'), 'hex'),
          now() + make_interval(days => v_days), auth.uid(), p_role, null, v_name)
  returning id into v_id;

  perform queue_notification(
    v_studio, null, 'staff_invite',
    jsonb_build_object(
      'to_email', v_email,
      'first_name', coalesce(split_part(v_name, ' ', 1), 'there'),
      'studio_name', s.name,
      'role_label', case p_role when 'manager' then 'a manager' else 'front desk' end,
      'days', v_days,
      'claim_url', 'https://app.studiior.com/join/' || v_token),
    'staff_invite:' || v_token);

  return jsonb_build_object('staff_id', v_staff, 'invite_id', v_id, 'email', v_email,
    'expires_at', now() + make_interval(days => v_days));
end $$;
revoke execute on function invite_staff(text, staff_role, text) from public, anon;
grant  execute on function invite_staff(text, staff_role, text) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- set_staff_role — owner only; never leave zero active owners; never 'instructor'.
-- -----------------------------------------------------------------------------
create or replace function set_staff_role(p_staff_id uuid, p_role staff_role)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare r studio_staff%rowtype; v_owners int;
begin
  select * into r from studio_staff where id = p_staff_id;
  if not found then raise exception 'no such staff member' using errcode = 'PT404'; end if;
  if not coalesce(is_owner(r.studio_id), false) then
    raise exception 'only an owner can change a role' using errcode = 'PT403';
  end if;
  if p_role = 'instructor' then
    raise exception 'manage instructor roles from the Instructors page' using errcode = 'PT422';
  end if;
  if p_role not in ('owner', 'manager', 'front_desk') then
    raise exception 'pick owner, manager or front desk' using errcode = 'PT422';
  end if;

  -- The last active owner can never be demoted.
  if r.role = 'owner' and p_role <> 'owner' then
    select count(*) into v_owners from studio_staff
     where studio_id = r.studio_id and role = 'owner' and status = 'active';
    if v_owners <= 1 then
      raise exception 'this is your only owner — add another owner before changing this one'
        using errcode = 'PT409';
    end if;
  end if;

  update studio_staff set role = p_role, updated_at = now() where id = p_staff_id;
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (r.studio_id, auth.uid(), 'staff.role_changed', 'studio_staff', p_staff_id,
          jsonb_build_object('role', r.role), jsonb_build_object('role', p_role));
  return jsonb_build_object('ok', true, 'role', p_role);
end $$;
revoke execute on function set_staff_role(uuid, staff_role) from public, anon;
grant  execute on function set_staff_role(uuid, staff_role) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- remove_staff — owner for any; manager for front_desk only; never the last
-- owner; revokes the login (user_id null) like remove_instructor_login, and
-- refuses an instructor row so an instructor record is never touched here.
-- -----------------------------------------------------------------------------
create or replace function remove_staff(p_staff_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare r studio_staff%rowtype; v_caller staff_role; v_owners int;
begin
  select * into r from studio_staff where id = p_staff_id;
  if not found then raise exception 'no such staff member' using errcode = 'PT404'; end if;
  if r.status = 'removed' then
    raise exception 'that person is already off the team' using errcode = 'PT409';
  end if;
  if r.role = 'instructor' then
    raise exception 'remove an instructor''s login from the Instructors page' using errcode = 'PT409';
  end if;

  v_caller := auth_role_in(r.studio_id);
  if v_caller = 'owner' then
    null;  -- owner removes any (subject to the last-owner guard)
  elsif v_caller = 'manager' and r.role = 'front_desk' then
    null;  -- a manager removes front desk only
  else
    raise exception 'you cannot remove that person' using errcode = 'PT403';
  end if;

  if r.role = 'owner' then
    select count(*) into v_owners from studio_staff
     where studio_id = r.studio_id and role = 'owner' and status = 'active';
    if v_owners <= 1 then
      raise exception 'this is your only owner — add another owner before removing this one'
        using errcode = 'PT409';
    end if;
  end if;

  update studio_staff
     set status = 'removed', removed_at = now(), user_id = null, updated_at = now()
   where id = p_staff_id;
  delete from studio_invites
   where studio_id = r.studio_id and lower(email) = lower(r.email) and accepted_at is null;
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (r.studio_id, auth.uid(), 'staff.removed', 'studio_staff', p_staff_id,
          jsonb_build_object('role', r.role, 'email', r.email));
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function remove_staff(uuid) from public, anon;
grant  execute on function remove_staff(uuid) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- studio_team — the Team table (manager-up). Name from profiles (after claim) or
-- the invited_name (before), last sign-in from auth.users. Removed rows hidden.
-- -----------------------------------------------------------------------------
create or replace function studio_team(p_studio_id uuid)
returns table (staff_id uuid, email text, name text, role staff_role, status text,
               last_sign_in_at timestamptz, is_self boolean)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not is_manager_up(p_studio_id) then
    raise exception 'only an owner or a manager can see the team' using errcode = 'PT403';
  end if;
  return query
    select ss.id, ss.email,
           coalesce(p.full_name, inv.invited_name) as name,
           ss.role, ss.status, u.last_sign_in_at,
           coalesce(ss.user_id = auth.uid(), false) as is_self
      from studio_staff ss
      left join profiles p on p.id = ss.user_id
      left join auth.users u on u.id = ss.user_id
      left join lateral (
        select si.invited_name from studio_invites si
         where si.studio_id = ss.studio_id and lower(si.email) = lower(ss.email)
           and si.accepted_at is null
         order by si.created_at desc limit 1) inv on true
     where ss.studio_id = p_studio_id and ss.status <> 'removed'
     order by case ss.role when 'owner' then 0 when 'manager' then 1
                           when 'front_desk' then 2 else 3 end, ss.email;
end $$;
revoke execute on function studio_team(uuid) from public, anon;
grant  execute on function studio_team(uuid) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- The claim pair, GENERALISED (re-issued from migration 097 bodies): accept
-- instructor / manager / front_desk invites. The instructor branch is unchanged;
-- a staff invite (instructor_id null) links the studio_staff row by email. These
-- stay the SAME two anon functions — no new anon surface.
-- -----------------------------------------------------------------------------
create or replace function instructor_invite_preview(p_token text)
returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare inv studio_invites%rowtype; i instructors%rowtype; s studios%rowtype;
begin
  select * into inv from studio_invites
   where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex')
     and role in ('instructor', 'manager', 'front_desk');
  if not found then return jsonb_build_object('state', 'invalid'); end if;
  if inv.accepted_at is not null then return jsonb_build_object('state', 'used'); end if;
  if inv.expires_at <= now() then return jsonb_build_object('state', 'expired'); end if;

  select * into s from studios where id = inv.studio_id;
  if inv.instructor_id is not null then
    select * into i from instructors where id = inv.instructor_id;
    return jsonb_build_object(
      'state', 'ok', 'role', inv.role,
      'first_name', split_part(i.display_name, ' ', 1),
      'studio_name', s.name, 'studio_slug', s.slug,
      'accent_color', s.accent_color, 'theme_preset', s.theme_preset,
      'logo_url', s.logo_url, 'email', inv.email);
  end if;
  -- Decision 70: a manager / front-desk invite has no instructor record.
  return jsonb_build_object(
    'state', 'ok', 'role', inv.role,
    'first_name', split_part(coalesce(inv.invited_name, ''), ' ', 1),
    'studio_name', s.name, 'studio_slug', s.slug,
    'accent_color', s.accent_color, 'theme_preset', s.theme_preset,
    'logo_url', s.logo_url, 'email', inv.email);
end $$;

create or replace function claim_instructor_account(
  p_token text, p_password text, p_full_name text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  inv studio_invites%rowtype; i instructors%rowtype; s studios%rowtype;
  v_user uuid; v_staff uuid; v_name text; v_instructor uuid;
begin
  select * into inv from studio_invites
   where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex')
     and role in ('instructor', 'manager', 'front_desk');
  if not found then return jsonb_build_object('state', 'invalid'); end if;
  if inv.accepted_at is not null then return jsonb_build_object('state', 'used'); end if;
  if inv.expires_at <= now() then return jsonb_build_object('state', 'expired'); end if;
  if length(coalesce(p_password, '')) < 8 then
    return jsonb_build_object('state', 'password_too_short');
  end if;

  select * into s from studios where id = inv.studio_id;

  if inv.instructor_id is not null then
    -- INSTRUCTOR PATH — unchanged from migration 097.
    select * into i from instructors where id = inv.instructor_id;
    if i.staff_id is not null and exists (
         select 1 from studio_staff ss where ss.id = i.staff_id and ss.user_id is not null) then
      return jsonb_build_object('state', 'already_claimed');
    end if;
    v_staff := i.staff_id;
    v_instructor := i.id;
    v_name := coalesce(nullif(btrim(p_full_name), ''), i.display_name);
  else
    -- STAFF PATH (Decision 70) — link the invited manager/front_desk row.
    select ss.id into v_staff from studio_staff ss
     where ss.studio_id = inv.studio_id and lower(ss.email) = lower(inv.email)
       and ss.status = 'invited' and ss.role in ('manager', 'front_desk')
     limit 1;
    if v_staff is null then return jsonb_build_object('state', 'invalid'); end if;
    v_instructor := null;
    v_name := coalesce(nullif(btrim(p_full_name), ''), inv.invited_name, inv.email);
  end if;

  -- One email is one account, project-wide (auth.users has a global unique index
  -- on it) — link an existing login rather than minting a second.
  select id into v_user from auth.users where lower(email) = lower(inv.email);
  if v_user is null then
    v_user := gen_random_uuid();
    insert into auth.users (
      id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
      created_at, updated_at, confirmation_token, recovery_token, email_change,
      email_change_token_new, email_change_token_current, phone_change,
      phone_change_token, reauthentication_token
    ) values (
      v_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
      inv.email, crypt(p_password, gen_salt('bf')), now(), now(), now(),
      '', '', '', '', '', '', '', '');
    insert into profiles (id, email, full_name) values (v_user, inv.email, v_name);
  else
    insert into profiles (id, email, full_name) values (v_user, inv.email, v_name)
    on conflict (id) do nothing;
  end if;

  update studio_staff set user_id = v_user, status = 'active', joined_at = now() where id = v_staff;
  update studio_invites set accepted_at = now(), accepted_by = v_user where id = inv.id;

  return jsonb_build_object(
    'state', 'ok', 'user_id', v_user, 'instructor_id', v_instructor,
    'studio_slug', s.slug, 'role', inv.role, 'display_name', v_name);
end $$;

-- -----------------------------------------------------------------------------
-- staff_invite email (always-send, no settings link — the reader has no account
-- yet). The claim link is on the staff host, where a manager/front desk signs in.
-- -----------------------------------------------------------------------------
insert into notification_templates (key, subject, text_body, html_body, note) values
('staff_invite', 'Your {studio_name} team account',
 E'Hi {first_name},\n\n{studio_name} has invited you to join the team as {role_label}.\n\nOpen this link to choose a password:\n{claim_url}\n\nThe link works once and expires in {days} days.\n\n{studio_name}',
 E'<p>Hi {first_name},</p><p><strong>{studio_name}</strong> has invited you to join the team as {role_label}.</p><p><a href="{claim_url}">Choose a password</a></p><p>The link works once and expires in {days} days.</p>',
 'Decision 70. Sent by invite_staff(). Like instructor_invite it gets no email-settings link: the reader has no account yet.')
on conflict (key) do nothing;

-- -----------------------------------------------------------------------------
-- (b) Widen the studios UPDATE policy to owner-or-manager, with the payment
-- column (stripe_account_id) kept owner-only by a column guard. Xendit lives in
-- studio_payment_providers (its own owner-only RLS), so no studios column there.
-- studio_settings and locations are already is_manager_up — unchanged.
-- -----------------------------------------------------------------------------
create or replace function guard_studios_payment_cols()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.stripe_account_id is distinct from old.stripe_account_id
     and not (coalesce(is_owner(new.id), false) or is_service_context()) then
    raise exception 'only an owner can connect or disconnect card payments' using errcode = 'PT403';
  end if;
  return new;
end $$;
-- A trigger function is reached by nobody as an RPC.
revoke execute on function guard_studios_payment_cols() from public, anon, authenticated;

drop trigger if exists guard_studios_payment_cols on studios;
create trigger guard_studios_payment_cols before update on studios
  for each row execute function guard_studios_payment_cols();

drop policy if exists studios_owner_write on studios;
drop policy if exists studios_owner_brand on studios;
create policy studios_staff_write on studios for update
  using (auth_role_in(id) in ('owner'::staff_role, 'manager'::staff_role))
  with check (auth_role_in(id) in ('owner'::staff_role, 'manager'::staff_role));

-- -----------------------------------------------------------------------------
-- Anon surface is unchanged — EXACTLY THIRTEEN. The new functions are
-- authenticated/service only; the generalised claim pair kept its anon grant.
-- -----------------------------------------------------------------------------
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % functions, expected exactly 13', n; end if;
end $$;
