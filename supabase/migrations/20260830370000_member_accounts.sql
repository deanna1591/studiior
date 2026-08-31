-- =============================================================================
-- MIGRATION 027 — member accounts: invite, and verified self-signup
--
-- Two ways in, one place they land.
--
--   INVITE       the studio sends a link to a member it already has. Hashed,
--                single-use, expiring — the studio_invites pattern, because
--                that one is already right.
--   SELF SIGNUP  a walk-in signs up on the studio's subdomain. Matching them
--                to an existing member row happens ONLY after the email is
--                verified.
--
-- That second rule is the whole security of this migration. Members are unique
-- on (studio_id, lower(email)), so an email address is enough to name someone
-- — and if an unverified signup linked automatically, anyone who knew a
-- member's address could take their account and read their attendance and
-- their payment history. The gate is enforced here, in the function, reading
-- auth.users.email_confirmed_at, and not in the screen that calls it.
--
-- Also here: two corrections the account work forced.
--
--   Permissions line 267 said a person who is a member of two studios "has two
--   accounts, and no policy anywhere joins them". auth.users has a global
--   unique index on email, so one email is one account; and
--   auth_member_studios() returns a set, so it is exactly such a policy. The
--   doc is corrected; the code below assumes one login and many memberships.
--
--   Decision 15: a `lead` may book, drop-in only. §2.1 rule 5 refuses anyone
--   who is not `active`, which turns away the walk-in who has just signed up
--   on their phone and wants tomorrow's 7am — the best new member a studio
--   gets.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Invites
-- -----------------------------------------------------------------------------
create table member_invites (
  id          uuid primary key default gen_random_uuid(),
  studio_id   uuid not null references studios on delete cascade,
  member_id   uuid not null references members on delete cascade,
  email       text not null,
  token_hash  text not null unique,
  expires_at  timestamptz not null,
  accepted_at timestamptz,
  accepted_by uuid references profiles on delete set null,
  created_by  uuid references profiles on delete set null,
  created_at  timestamptz not null default now()
);
create index on member_invites (studio_id, member_id);
-- One live invite per member: re-inviting supersedes rather than accumulating,
-- so a member with five stale links in their inbox cannot use the oldest.
create unique index member_invites_one_live
  on member_invites (member_id) where accepted_at is null;

alter table member_invites enable row level security;

-- Permissions §5: creating a member is Owner, Manager and Front Desk, and
-- inviting one to the app is the same act by another name. Never instructors.
create policy member_invites_desk on member_invites
  for all using (is_desk_up(studio_id)) with check (is_desk_up(studio_id));

grant select, insert, update, delete on member_invites to authenticated;
grant all on member_invites to service_role;

/**
 * Mint an invite. Returns the raw token exactly once — only its hash is
 * stored, so a leaked database does not hand anybody an account.
 */
create function create_member_invite(p_member_id uuid, p_days int default 14)
returns table (token text, email text, expires_at timestamptz)
language plpgsql security definer set search_path = public, extensions as $$
declare
  m       members%rowtype;
  v_token text;
  v_exp   timestamptz;
begin
  select * into m from members where id = p_member_id;
  if not found then
    raise exception 'no such member' using errcode = 'PT404';
  end if;
  if not is_desk_up(m.studio_id) then
    raise exception 'only owners, managers and front desk may invite a member'
      using errcode = 'PT403', hint = 'Permissions §5.';
  end if;
  if m.user_id is not null then
    raise exception '% already has an account', m.first_name using errcode = 'PT409';
  end if;

  v_token := encode(gen_random_bytes(24), 'hex');
  v_exp   := now() + make_interval(days => greatest(1, p_days));

  -- Supersede any outstanding invite rather than colliding with the partial
  -- unique index: the newest link is the one that should work.
  delete from member_invites where member_id = p_member_id and accepted_at is null;

  insert into member_invites (studio_id, member_id, email, token_hash, expires_at, created_by)
  values (m.studio_id, m.id, m.email,
          encode(digest(v_token, 'sha256'), 'hex'), v_exp, auth.uid());

  return query select v_token, m.email, v_exp;
end $$;

/** What an invite link may show before anybody is signed in. */
create function member_invite_preview(p_token text)
returns table (studio_name text, studio_slug text, first_name text, email text, valid boolean)
language sql stable security definer set search_path = public, extensions as $$
  select s.name, s.slug, m.first_name, i.email,
         (i.accepted_at is null and i.expires_at > now())
    from member_invites i
    join members m on m.id = i.member_id
    join studios s on s.id = i.studio_id
   where i.token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex')
$$;

-- -----------------------------------------------------------------------------
-- 2. The one landing place
--
-- Both paths end here: an auth user, a profile and members.user_id, in one
-- transaction or none of it. Same shape as accept_studio_invite().
-- -----------------------------------------------------------------------------
create type member_claim as (
  user_id        uuid,
  member_id      uuid,
  studio_slug    text,
  email          text,
  failure_reason text
);

create function claim_member_account(
  p_token     text,
  p_password  text,
  p_full_name text default null
) returns member_claim
language plpgsql security definer set search_path = public, extensions as $$
declare
  inv    member_invites%rowtype;
  m      members%rowtype;
  s      studios%rowtype;
  v_user uuid := gen_random_uuid();
begin
  select * into inv from member_invites
   where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex');
  if not found then
    return (null, null, null, null, 'invalid_token')::member_claim;
  end if;
  if inv.accepted_at is not null then
    return (null, null, null, null, 'token_used')::member_claim;
  end if;
  if inv.expires_at <= now() then
    return (null, null, null, null, 'token_expired')::member_claim;
  end if;
  if length(coalesce(p_password, '')) < 8 then
    return (null, null, null, null, 'password_too_short')::member_claim;
  end if;

  select * into m from members where id = inv.member_id;
  select * into s from studios  where id = inv.studio_id;

  if m.user_id is not null then
    return (null, null, null, null, 'already_claimed')::member_claim;
  end if;

  -- One email is one account, project-wide: auth.users carries a global unique
  -- index on it. If this person already has a login — because they are a
  -- member of another studio — the invite links the existing account to this
  -- member row rather than trying to mint a second one that Postgres would
  -- refuse anyway.
  select id into v_user from auth.users where lower(email) = lower(inv.email);

  if v_user is null then
    v_user := gen_random_uuid();
    insert into auth.users (
      id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
      created_at, updated_at,
      confirmation_token, recovery_token, email_change, email_change_token_new,
      email_change_token_current, phone_change, phone_change_token,
      reauthentication_token
    ) values (
      v_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
      inv.email, crypt(p_password, gen_salt('bf')), now(),
      now(), now(), '', '', '', '', '', '', '', ''
    );
    insert into profiles (id, email, full_name)
    values (v_user, inv.email,
            coalesce(nullif(btrim(p_full_name), ''), m.first_name || ' ' || m.last_name));
  else
    insert into profiles (id, email, full_name)
    values (v_user, inv.email, m.first_name || ' ' || m.last_name)
    on conflict (id) do nothing;
  end if;

  update members set user_id = v_user where id = m.id;
  update member_invites set accepted_at = now(), accepted_by = v_user where id = inv.id;

  return (v_user, m.id, s.slug, inv.email, null)::member_claim;
end $$;

-- -----------------------------------------------------------------------------
-- 3. Self signup — the match happens only after verification
--
-- Supabase creates the auth user and sends the confirmation. This is called
-- afterwards, by the signed-in person, and refuses to do anything until
-- auth.users.email_confirmed_at is set. It reads that column itself: a screen
-- that promised to check first would be a promise, and this is the only thing
-- standing between an address somebody knows and somebody else's history.
-- -----------------------------------------------------------------------------
create function claim_member_by_email(p_studio_id uuid) returns member_claim
language plpgsql security definer set search_path = public as $$
declare
  u_email    text;
  u_confirmed timestamptz;
  m          members%rowtype;
  s          studios%rowtype;
  v_new      uuid;
begin
  if auth.uid() is null then
    return (null, null, null, null, 'not_signed_in')::member_claim;
  end if;

  select email, email_confirmed_at into u_email, u_confirmed
    from auth.users where id = auth.uid();
  if u_email is null then
    return (null, null, null, null, 'not_signed_in')::member_claim;
  end if;

  -- The gate.
  if u_confirmed is null then
    return (null, null, null, null, 'email_not_verified')::member_claim;
  end if;

  select * into s from studios where id = p_studio_id and status = 'active';
  if not found then
    return (null, null, null, null, 'no_such_studio')::member_claim;
  end if;

  -- Already linked in this studio? Idempotent, so a refresh is harmless.
  select * into m from members
   where studio_id = p_studio_id and user_id = auth.uid();
  if found then
    return (auth.uid(), m.id, s.slug, u_email, null)::member_claim;
  end if;

  select * into m from members
   where studio_id = p_studio_id and lower(email) = lower(u_email);

  if found then
    if m.user_id is not null then
      -- Somebody else already holds this member record.
      return (null, null, null, null, 'already_claimed')::member_claim;
    end if;
    update members set user_id = auth.uid() where id = m.id;
    return (auth.uid(), m.id, s.slug, u_email, null)::member_claim;
  end if;

  -- No match: a genuinely new person. Decision 15 lets them book a drop-in
  -- straight away rather than waiting for staff to notice they exist.
  insert into members (studio_id, user_id, first_name, last_name, email,
                       status, joined_on, source)
  values (p_studio_id, auth.uid(),
          coalesce(nullif(split_part((select coalesce(full_name, '') from profiles where id = auth.uid()), ' ', 1), ''), 'New'),
          coalesce(nullif(substring((select coalesce(full_name, '') from profiles where id = auth.uid()) from position(' ' in (select coalesce(full_name, ' ') from profiles where id = auth.uid())) + 1), ''), 'member'),
          u_email, 'lead', current_date, 'self_signup')
  returning id into v_new;

  return (auth.uid(), v_new, s.slug, u_email, null)::member_claim;
end $$;

revoke execute on function create_member_invite(uuid, int) from public;
revoke execute on function member_invite_preview(text) from public;
revoke execute on function claim_member_account(text, text, text) from public;
revoke execute on function claim_member_by_email(uuid) from public;
grant execute on function create_member_invite(uuid, int) to authenticated, service_role;
grant execute on function member_invite_preview(text) to anon, authenticated, service_role;
grant execute on function claim_member_account(text, text, text) to anon, authenticated, service_role;
grant execute on function claim_member_by_email(uuid) to authenticated, service_role;

-- A member may set their own user_id exactly once, and only to themselves —
-- claim_member_by_email() is SECURITY DEFINER so it does not need this, but
-- the policy documents that nothing else may reassign a member to an account.
create policy members_self_claim on members
  for update using (user_id is null and studio_id in (select auth_member_studios()))
  with check (user_id = auth.uid());

comment on function claim_member_by_email(uuid) is
  'Links a verified signed-in account to a member row in one studio, or '
  'creates a lead. Refuses until auth.users.email_confirmed_at is set: an '
  'email address is enough to name a member, so an unverified match would '
  'hand their attendance and payment history to anyone who knew it.';
