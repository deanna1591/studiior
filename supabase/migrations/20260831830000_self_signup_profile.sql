-- Migration 178 — Decision 41 amendment 2: a self-signup has no profiles row.
--
-- Bug on hosted: a fresh self-signup at reformcollective.studiior.app failed at
-- claim_member_by_email with `members_user_id_fkey`. members.user_id references
-- profiles, and NOTHING creates a profiles row for a self-signup — the invite
-- path (claim_member_account) inserts the profile, claim_member_by_email never
-- did, and there is no trigger on auth.users. So the member insert/link (both
-- set user_id = auth.uid()) violated the FK.
--
-- Fix: claim_member_by_email creates the profile from auth.users first
-- (full_name from raw_user_meta_data, which signUp sets), on conflict do
-- nothing, then links/inserts the member exactly as before — taking first/last
-- from that profile as it does today. The email_confirmed_at gate is unchanged,
-- so an unverified user still gets email_not_verified and no profile is created.
-- create or replace, so the ACL (authenticated, service_role — NOT anon) holds;
-- re-asserted below. Not a new surface; anon stays EXACTLY TWELVE.

create or replace function claim_member_by_email(p_studio_id uuid) returns member_claim
language plpgsql security definer set search_path = public as $$
declare
  u_email     text;
  u_confirmed timestamptz;
  u_fullname  text;
  m           members%rowtype;
  s           studios%rowtype;
  v_new       uuid;
begin
  if auth.uid() is null then
    return (null, null, null, null, 'not_signed_in')::member_claim;
  end if;

  select email, email_confirmed_at, coalesce(raw_user_meta_data ->> 'full_name', '')
    into u_email, u_confirmed, u_fullname
    from auth.users where id = auth.uid();
  if u_email is null then
    return (null, null, null, null, 'not_signed_in')::member_claim;
  end if;

  -- The gate. Unchanged: an unverified email cannot attach (and no profile is
  -- created for one, because we return here first).
  if u_confirmed is null then
    return (null, null, null, null, 'email_not_verified')::member_claim;
  end if;

  select * into s from studios where id = p_studio_id and status = 'active';
  if not found then
    return (null, null, null, null, 'no_such_studio')::member_claim;
  end if;

  -- The profile a self-signup never had. members.user_id references profiles, so
  -- this must exist before any link/insert below. Idempotent; the invite path
  -- (claim_member_account) already inserts its own, and a re-claim is harmless.
  insert into profiles (id, email, full_name)
  values (auth.uid(), u_email, u_fullname)
  on conflict (id) do nothing;

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
  -- straight away rather than waiting for staff to notice they exist. First and
  -- last name come from the profile just created, as they did before.
  insert into members (studio_id, user_id, first_name, last_name, email,
                       status, joined_on, source)
  values (p_studio_id, auth.uid(),
          coalesce(nullif(split_part((select coalesce(full_name, '') from profiles where id = auth.uid()), ' ', 1), ''), 'New'),
          coalesce(nullif(substring((select coalesce(full_name, '') from profiles where id = auth.uid()) from position(' ' in (select coalesce(full_name, ' ') from profiles where id = auth.uid())) + 1), ''), 'member'),
          u_email, 'lead', current_date, 'self_signup')
  returning id into v_new;

  return (auth.uid(), v_new, s.slug, u_email, null)::member_claim;
end $$;

revoke execute on function claim_member_by_email(uuid) from public, anon;
grant  execute on function claim_member_by_email(uuid) to authenticated, service_role;
