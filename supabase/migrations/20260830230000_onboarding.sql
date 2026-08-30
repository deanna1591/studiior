-- =============================================================================
-- MIGRATION 012 — onboarding: platform admin, studio invites, setup progress
--
-- Product Bible flow: Create Studio -> Create Account -> Verify Email ->
-- Setup Wizard -> Dashboard. Invite-only; there is no public signup.
--
-- The platform operator creates a studio shell and an invite. The owner opens
-- the link, sets a password, and that single act creates their account, makes
-- them Owner, and takes the studio out of provisioning — in one transaction or
-- not at all.
--
-- On "Verify Email": the invite token is emailed to the address the account is
-- created for, so opening the link already proves control of that inbox. That
-- is the verification step; there is no second round trip. email_confirmed_at
-- is set at acceptance for exactly that reason.
-- =============================================================================

-- =============================================================================
-- 1. Platform admins
--
-- The brief offered "a hardcoded allowlist of emails in env, or a superadmin
-- flag". It has to be the flag: provisioning a studio is an INSERT into
-- studios, which no RLS policy allows, so it runs through a SECURITY DEFINER
-- function — and that function has to be able to check who is calling it. An
-- env var is invisible to Postgres, so the check would live only in the route,
-- and "a permission that exists only in React is not a permission" (CLAUDE.md).
--
-- One table, one column that matters. No RLS policies at all: nothing reads it
-- directly, only the security definer helper below.
-- =============================================================================

create table platform_admins (
  user_id    uuid primary key references auth.users on delete cascade,
  email      text not null,
  note       text,
  created_at timestamptz not null default now()
);

alter table platform_admins enable row level security;
-- Deliberately no policies: RLS denies by default once enabled, so this table
-- is unreadable and unwritable through the API. Rows are added by whoever
-- administers the database, and read only by is_platform_admin().

grant select on platform_admins to service_role;

comment on table platform_admins is
  'Who may provision studios. Add a row by hand against the database; there is '
  'deliberately no screen for it. Ten studios in V1 — this does not need to '
  'scale, it needs to be checkable in SQL.';

create function is_platform_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from platform_admins where user_id = auth.uid())
$$;

revoke execute on function is_platform_admin() from public, anon;
grant execute on function is_platform_admin() to authenticated, service_role;

-- =============================================================================
-- 2. A studio is 'provisioning' until its first Owner accepts
-- =============================================================================

alter table studios
  add constraint studios_status_known
  check (status in ('provisioning','active','archived'));

comment on column studios.status is
  'provisioning until the first Owner accepts their invite, then active. '
  'archived retires it. studio_by_slug() only returns active studios, so a '
  'half-provisioned studio has no member-facing surface.';

-- =============================================================================
-- 3. Invites
--
-- pgcrypto lives in the `extensions` schema on both local and hosted, and
-- these functions pin search_path = public (migration 011), so every pgcrypto
-- call below is schema-qualified rather than widening the path.
--
-- Tokens are never stored. The plaintext exists once, in the return value of
-- provision_studio(), long enough to be put in a link. What is stored is a
-- SHA-256 of it: deterministic so the token can be looked up, and 256 bits of
-- gen_random_bytes means there is nothing to brute force.
-- =============================================================================

create table studio_invites (
  id          uuid primary key default gen_random_uuid(),
  studio_id   uuid not null references studios on delete cascade,
  email       text not null,
  token_hash  text not null unique,
  expires_at  timestamptz not null,
  accepted_at timestamptz,
  accepted_by uuid references auth.users on delete set null,
  created_by  uuid references auth.users on delete set null,
  created_at  timestamptz not null default now()
);
create index on studio_invites (studio_id);
create index on studio_invites (expires_at) where accepted_at is null;

alter table studio_invites enable row level security;

-- Only the platform operator sees invites. The invitee never reads this table —
-- they arrive with a token and go through the functions below.
create policy invites_platform_admin on studio_invites for select
  using (is_platform_admin());

grant select on studio_invites to authenticated, service_role;

-- The operator provisions a studio they are not staff of, so without this they
-- could create one and immediately lose sight of it: every other studios policy
-- keys off membership.
create policy studios_platform_admin_read on studios for select
  using (is_platform_admin());

comment on table studio_invites is
  'Single-use owner invites. token_hash is sha256(token); the plaintext is '
  'returned by provision_studio() once and never stored.';

-- =============================================================================
-- 4. Setup progress
--
-- Only what cannot be derived lives here.
--
-- The brief asked for "which checklist items are done". Storing that would mean
-- a dashboard that lies: mark rooms done, delete every room, and the checklist
-- still says done. Every item on the list except Stripe is answerable from the
-- data itself, so studio_setup_state() below derives them and this column
-- carries the two things that genuinely have no other home — which items the
-- owner dismissed, and the Stripe stub, which has nothing to derive from yet.
--
--   {"dismissed": {"connect_stripe": "2026-..."},
--    "done":      {"connect_stripe": "2026-..."}}
-- =============================================================================

alter table studio_settings
  add column setup_progress        jsonb not null default '{}'::jsonb,
  add column onboarding_completed_at timestamptz;

comment on column studio_settings.setup_progress is
  'Dismissals and non-derivable checklist state only. Everything else is '
  'derived live by studio_setup_state() so the dashboard cannot go stale.';
comment on column studio_settings.onboarding_completed_at is
  'Set when the setup wizard finishes. Null means the wizard still blocks.';

-- =============================================================================
-- 5. provision_studio — platform admin only
-- =============================================================================

create type provision_result as (
  studio_id      uuid,
  invite_token   text,
  expires_at     timestamptz,
  failure_reason text
);

create function provision_studio(
  p_name        text,
  p_slug        text,
  p_timezone    text,
  p_currency    char(3),
  p_country     char(2),
  p_owner_email text,
  p_valid_days  int default 14
) returns provision_result
language plpgsql security definer set search_path = public as $$
declare
  v_studio uuid;
  v_token  text;
  v_slug   text := lower(btrim(p_slug));
  v_email  text := lower(btrim(p_owner_email));
begin
  if not is_platform_admin() then
    return (null, null, null, 'not_platform_admin')::provision_result;
  end if;

  if v_slug !~ '^[a-z0-9](?:[a-z0-9-]{1,38}[a-z0-9])$' then
    return (null, null, null, 'invalid_slug')::provision_result;
  end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    return (null, null, null, 'invalid_email')::provision_result;
  end if;
  if exists (select 1 from studios where slug = v_slug) then
    return (null, null, null, 'slug_taken')::provision_result;
  end if;

  insert into studios (name, slug, timezone, currency, country, status)
  values (btrim(p_name), v_slug, p_timezone, upper(p_currency), upper(p_country), 'provisioning')
  returning id into v_studio;

  insert into studio_settings (studio_id) values (v_studio);

  -- One location, because a studio with none cannot have a class and the
  -- wizard does not ask for one. Renameable like anything else.
  insert into locations (studio_id, name, timezone, is_primary)
  values (v_studio, btrim(p_name), p_timezone, true);

  v_token := encode(extensions.gen_random_bytes(32), 'hex');

  insert into studio_invites (studio_id, email, token_hash, expires_at, created_by)
  values (v_studio, v_email,
          encode(extensions.digest(v_token, 'sha256'), 'hex'),
          now() + make_interval(days => greatest(p_valid_days, 1)),
          auth.uid());

  return (v_studio, v_token, now() + make_interval(days => greatest(p_valid_days, 1)), null)::provision_result;
end $$;

revoke execute on function provision_studio(text,text,text,char,char,text,int) from public, anon;
grant execute on function provision_studio(text,text,text,char,char,text,int)
  to authenticated, service_role;

-- =============================================================================
-- 6. The invite surfaces — anon, because the invitee has no account yet
--
-- These are the second and third things anon may execute, after
-- studio_by_slug(). Both are gated by a 256-bit token: without one they return
-- nothing and do nothing.
-- =============================================================================

create type invite_preview as (
  studio_name text,
  email       text,
  expires_at  timestamptz,
  state       text          -- valid | expired | used | invalid
);

create function studio_invite_preview(p_token text) returns invite_preview
language plpgsql stable security definer set search_path = public as $$
declare v record;
begin
  select i.email, i.expires_at, i.accepted_at, s.name
    into v
    from studio_invites i join studios s on s.id = i.studio_id
   where i.token_hash = encode(extensions.digest(coalesce(p_token,''), 'sha256'), 'hex');

  if not found then
    return (null, null, null, 'invalid')::invite_preview;
  end if;
  if v.accepted_at is not null then
    return (v.name, v.email, v.expires_at, 'used')::invite_preview;
  end if;
  if v.expires_at < now() then
    return (v.name, v.email, v.expires_at, 'expired')::invite_preview;
  end if;
  return (v.name, v.email, v.expires_at, 'valid')::invite_preview;
end $$;

revoke execute on function studio_invite_preview(text) from public;
grant execute on function studio_invite_preview(text) to anon, authenticated, service_role;

create type invite_acceptance as (
  user_id        uuid,
  studio_id      uuid,
  studio_slug    text,
  email          text,
  failure_reason text
);

-- Atomic by construction: the account, the owner row and the status flip are
-- one statement each in one transaction. Nothing here can half-happen.
--
-- It writes auth.users directly rather than going through GoTrue, because that
-- is the only way to get the account into the same transaction as the studio
-- rows — and because the alternative, a service-role admin call, would put a
-- key that bypasses every policy into an unauthenticated request path. The
-- price is coupling to GoTrue's table: the token columns below are NOT NULL in
-- its Go model even though the schema allows null, and leaving them null makes
-- every later sign-in fail with "Database error querying schema".
create function accept_studio_invite(
  p_token     text,
  p_password  text,
  p_full_name text
) returns invite_acceptance
language plpgsql security definer set search_path = public as $$
declare
  v_inv    studio_invites%rowtype;
  v_studio studios%rowtype;
  v_user   uuid := gen_random_uuid();
begin
  if length(coalesce(p_password, '')) < 8 then
    return (null, null, null, null, 'password_too_short')::invite_acceptance;
  end if;
  if btrim(coalesce(p_full_name, '')) = '' then
    return (null, null, null, null, 'name_required')::invite_acceptance;
  end if;

  -- Locked, so two people opening the same link at once cannot both win.
  select * into v_inv from studio_invites
   where token_hash = encode(extensions.digest(coalesce(p_token,''), 'sha256'), 'hex')
     for update;

  if not found then
    return (null, null, null, null, 'invalid_token')::invite_acceptance;
  end if;
  if v_inv.accepted_at is not null then
    return (null, null, null, null, 'token_already_used')::invite_acceptance;
  end if;
  if v_inv.expires_at < now() then
    return (null, null, null, null, 'token_expired')::invite_acceptance;
  end if;

  select * into v_studio from studios where id = v_inv.studio_id for update;

  -- Decision 8 keeps the last Owner from being removed; this keeps a second
  -- one from arriving through a stale link.
  if exists (
    select 1 from studio_staff
     where studio_id = v_inv.studio_id and role = 'owner' and status = 'active'
  ) then
    return (null, null, null, null, 'studio_already_has_owner')::invite_acceptance;
  end if;

  if exists (select 1 from auth.users where lower(email) = lower(v_inv.email)) then
    return (null, null, null, null, 'account_exists')::invite_acceptance;
  end if;

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
    created_at, updated_at,
    confirmation_token, recovery_token, email_change, email_change_token_new,
    email_change_token_current, phone_change, phone_change_token,
    reauthentication_token
  ) values (
    v_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
    v_inv.email, extensions.crypt(p_password, extensions.gen_salt('bf')), now(),
    now(), now(),
    '', '', '', '', '', '', '', ''
  );

  insert into profiles (id, email, full_name)
  values (v_user, v_inv.email, btrim(p_full_name));

  insert into studio_staff (studio_id, user_id, email, role, status, joined_at)
  values (v_inv.studio_id, v_user, v_inv.email, 'owner', 'active', now());

  update studios set status = 'active' where id = v_inv.studio_id;

  update studio_invites
     set accepted_at = now(), accepted_by = v_user
   where id = v_inv.id;

  return (v_user, v_studio.id, v_studio.slug, v_inv.email, null)::invite_acceptance;
end $$;

revoke execute on function accept_studio_invite(text,text,text) from public;
grant execute on function accept_studio_invite(text,text,text)
  to anon, authenticated, service_role;

-- =============================================================================
-- 7. The dashboard checklist, derived
-- =============================================================================

create function studio_setup_state(p_studio_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  with prog as (
    select coalesce(setup_progress, '{}'::jsonb) as p
      from studio_settings where studio_id = p_studio_id
  ),
  facts(key, done) as (
    values
      ('rooms',        exists (select 1 from rooms          where studio_id = p_studio_id and status = 'active')),
      ('class_types',  exists (select 1 from class_types    where studio_id = p_studio_id and status = 'active')),
      ('instructors',  exists (select 1 from instructors    where studio_id = p_studio_id and status = 'active')),
      ('plans',        exists (select 1 from membership_plans where studio_id = p_studio_id and status = 'active')),
      ('schedule',     exists (select 1 from class_occurrences where studio_id = p_studio_id)),
      ('staff',       (select count(*) from studio_staff where studio_id = p_studio_id and status = 'active') > 1),
      -- Nothing to derive until Stripe Connect is wired; it is a stored flag.
      ('connect_stripe', false)
  )
  select jsonb_object_agg(
           f.key,
           jsonb_build_object(
             -- coalesce before ?: on a fresh studio setup_progress is '{}',
             -- so p -> 'done' is NULL and NULL ? key is NULL, not false — the
             -- checklist would render "unknown" rather than "not done".
             'done', case when f.key = 'connect_stripe'
                          then (select coalesce(p -> 'done', '{}'::jsonb) ? 'connect_stripe' from prog)
                          else f.done end,
             'dismissed', (select coalesce(p -> 'dismissed', '{}'::jsonb) ? f.key from prog)
           ))
    from facts f
   where exists (select 1 from studio_staff s
                  where s.studio_id = p_studio_id and s.user_id = auth.uid()
                    and s.status = 'active' and s.role in ('owner','manager'))
      or auth.uid() is null;
$$;

revoke execute on function studio_setup_state(uuid) from public, anon;
grant execute on function studio_setup_state(uuid) to authenticated, service_role;

create function dismiss_setup_item(p_studio_id uuid, p_key text, p_dismissed boolean default true)
returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not is_manager_up(p_studio_id) then
    return false;
  end if;
  -- Merged rather than jsonb_set: with create_missing it still only creates the
  -- LAST level, so on a fresh studio where setup_progress is '{}' the missing
  -- 'dismissed' parent makes jsonb_set return the original untouched — a silent
  -- no-op that reports success.
  update studio_settings
     set setup_progress = coalesce(setup_progress, '{}'::jsonb) ||
           jsonb_build_object('dismissed',
             case when p_dismissed
               then coalesce(setup_progress -> 'dismissed', '{}'::jsonb)
                    || jsonb_build_object(p_key, now())
               else coalesce(setup_progress -> 'dismissed', '{}'::jsonb) - p_key
             end)
   where studio_id = p_studio_id;
  return found;
end $$;

revoke execute on function dismiss_setup_item(uuid, text, boolean) from public, anon;
grant execute on function dismiss_setup_item(uuid, text, boolean) to authenticated, service_role;

-- The Stripe step is a stub: marking it done records intent, nothing is wired.
create function mark_stripe_stub_done(p_studio_id uuid) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not is_manager_up(p_studio_id) then
    return false;
  end if;
  update studio_settings
     set setup_progress = coalesce(setup_progress, '{}'::jsonb) ||
           jsonb_build_object('done',
             coalesce(setup_progress -> 'done', '{}'::jsonb)
             || jsonb_build_object('connect_stripe', now()))
   where studio_id = p_studio_id;
  return found;
end $$;

revoke execute on function mark_stripe_stub_done(uuid) from public, anon;
grant execute on function mark_stripe_stub_done(uuid) to authenticated, service_role;

comment on schema public is
  'Studiior application schema. '
  'authenticated and service_role hold table privileges, scoped row-by-row by '
  'RLS. anon holds usage on this schema and execute on exactly three functions, '
  'each a documented pre-login surface: studio_by_slug(text) behind '
  '{slug}.studiior.app, and studio_invite_preview(text) / '
  'accept_studio_invite(text,text,text) behind an emailed 256-bit invite token. '
  'anon has no select, insert, update or delete on any table or view. '
  'Note the hosted platform default-grants EXECUTE on new functions to anon '
  'even though local does not, so a new function is anon-callable on hosted '
  'until revoked, and local tests will not tell you. Say who may execute, '
  'every time, and check it against the hosted project. '
  'Anything that appears to need the service role key in a request path is a '
  'missing policy, not a reason to use the key.';
