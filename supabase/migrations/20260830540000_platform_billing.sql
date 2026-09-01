-- =============================================================================
-- Migration 044: platform billing — Studiior charging the studio
-- =============================================================================
-- Entirely separate from Connect. Connect is the studio's members paying the
-- studio on the studio's own account; this is the studio paying us on OURS.
-- Nothing here touches stripe_account_id, and nothing in migration 038 touches
-- this table.
--
-- $79/month USD for every studio whatever currency they price their own classes
-- in, and whatever way they take money from their members. A studio running
-- entirely on cash under Decision 16 still pays us by card: we are not chasing
-- bank transfers from ten studios, and pretending otherwise would mean building
-- a dunning process for our own invoices. That is said here and on the billing
-- screen rather than left for somebody to discover.
--
-- NOT `memberships`. That table is member-to-studio: it carries a member_id, a
-- plan_id, credits and a freeze window, none of which mean anything for a
-- studio's subscription to us. Reusing it would have made every query that
-- means "who is a member here" wrong.
-- =============================================================================

create type platform_status as enum
  ('trialing', 'active', 'past_due', 'locked', 'cancelled');

create table platform_subscriptions (
  id                     uuid primary key default gen_random_uuid(),
  studio_id              uuid not null unique references studios on delete cascade,
  status                 platform_status not null default 'trialing',

  -- Thirty days, no card. A studio should be able to put its whole week in and
  -- watch members book before it decides we are worth paying for.
  trial_ends_at          timestamptz not null,
  -- Set when a payment fails or a trial lapses; fourteen days later, lockout.
  grace_ends_at          timestamptz,
  locked_at              timestamptz,

  price_cents            int not null default 7900,
  currency               char(3) not null default 'USD',

  stripe_customer_id     text,
  stripe_subscription_id text,
  current_period_end     timestamptz,
  cancelled_at           timestamptz,

  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);
create index on platform_subscriptions (status);
create index on platform_subscriptions (trial_ends_at) where status = 'trialing';
create index on platform_subscriptions (grace_ends_at) where status = 'past_due';

alter table platform_subscriptions enable row level security;
grant select on platform_subscriptions to authenticated;
grant all on platform_subscriptions to service_role;

-- The studio's own owner and managers can see what they owe and when. Front
-- desk cannot: it is the studio's bank relationship, like Connect (§9).
create policy platform_subs_studio_read on platform_subscriptions
  for select using (is_manager_up(studio_id) or is_platform_admin());
-- Only the platform admin writes by hand; everything else is the webhook and
-- the sweep, both of which run as the owner of their SECURITY DEFINER function.
create policy platform_subs_admin_write on platform_subscriptions
  for all using (is_platform_admin()) with check (is_platform_admin());

comment on table platform_subscriptions is
  'What a studio pays Studiior. Separate from memberships, which is a member '
  'paying a studio, and separate from Connect, which never touches our balance.';

-- -----------------------------------------------------------------------------
-- Every existing studio gets a trial starting now
--
-- Not backdated from created_at: the seeded studio has been running for
-- eighteen months in its own data, so a trial measured from then would already
-- have lapsed and a `db reset` would hand every developer a locked app. A
-- migration should not lock anybody out on the day it runs.
-- -----------------------------------------------------------------------------
insert into platform_subscriptions (studio_id, status, trial_ends_at)
select s.id, 'trialing', now() + interval '30 days'
  from studios s
 where not exists (select 1 from platform_subscriptions p where p.studio_id = s.id);

-- -----------------------------------------------------------------------------
-- The two questions the rest of the codebase asks
-- -----------------------------------------------------------------------------
create or replace function studio_is_locked(p_studio_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  -- coalesce(..., false): a studio with no row at all is not locked. A boolean
  -- authorisation helper that can return null is the hole migration 020 closed,
  -- and this one is read inside `if not ... then raise` guards.
  select coalesce(
    (select status = 'locked' from platform_subscriptions where studio_id = p_studio_id),
    false)
$$;

/**
 * Everything the billing screen and the middleware need, in one read.
 *
 * A function rather than a policy on the table because the member app has to
 * know a studio is locked in order to say so, and members cannot read
 * platform_subscriptions — nor should they see what their studio pays us.
 */
create or replace function studio_billing_state(p_studio_id uuid)
returns table (
  status platform_status, trial_ends_at timestamptz, grace_ends_at timestamptz,
  locked boolean, days_left int, has_card boolean
)
language sql stable security definer set search_path = public as $$
  select p.status, p.trial_ends_at, p.grace_ends_at,
         p.status = 'locked',
         greatest(0, extract(day from
           coalesce(p.grace_ends_at, p.trial_ends_at) - now())::int),
         p.stripe_subscription_id is not null
    from platform_subscriptions p
   where p.studio_id = p_studio_id
$$;

/**
 * Give a studio more time. Platform admin only.
 *
 * Deliberately additive to whatever they have now rather than a new absolute
 * date: an operator extending a trial during a support conversation is thinking
 * "give them another fortnight", not "make it the 14th".
 */
create or replace function extend_trial(p_studio_id uuid, p_days int)
returns timestamptz
language plpgsql security definer set search_path = public as $$
declare v_new timestamptz;
begin
  if not is_platform_admin() then
    raise exception 'only a platform admin can extend a trial' using errcode = 'PT403';
  end if;
  if p_days is null or p_days <= 0 or p_days > 365 then
    raise exception 'extend by between 1 and 365 days' using errcode = 'PT400';
  end if;

  update platform_subscriptions
     set trial_ends_at = greatest(trial_ends_at, now()) + make_interval(days => p_days),
         grace_ends_at = null,
         locked_at     = null,
         -- Extending a trial un-locks: an operator doing this in a support
         -- conversation means "let them back in", and leaving them locked while
         -- telling them they have another fortnight would be absurd.
         status        = case when status in ('locked', 'past_due') then 'trialing' else status end,
         updated_at    = now()
   where studio_id = p_studio_id
  returning trial_ends_at into v_new;

  if v_new is null then
    raise exception 'no such studio' using errcode = 'PT404';
  end if;
  return v_new;
end $$;

revoke execute on function studio_is_locked(uuid) from public, anon;
grant execute on function studio_is_locked(uuid) to authenticated;
revoke execute on function studio_billing_state(uuid) from public, anon;
grant execute on function studio_billing_state(uuid) to authenticated;
revoke execute on function extend_trial(uuid, int) from public, anon, authenticated;
grant execute on function extend_trial(uuid, int) to authenticated;

-- -----------------------------------------------------------------------------
-- Every studio gets a subscription row the moment it exists
--
-- A trigger and not just a line in provision_studio(), because provision_studio
-- is not the only thing that creates a studio: supabase/seed.sql inserts tenant
-- one directly, and a provision-only stamp would leave the studio every
-- developer works against with no billing row at all — then every lockout check
-- would read "not locked" for the one studio anybody ever tests with, and the
-- whole feature would look like it worked. That is exactly the blind spot
-- CLAUDE.md records: ask what state the seed cannot produce.
-- -----------------------------------------------------------------------------
create or replace function tg_start_platform_trial() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into platform_subscriptions (studio_id, status, trial_ends_at)
  values (new.id, 'trialing', now() + interval '30 days')
  on conflict (studio_id) do nothing;
  return new;
end $$;

drop trigger if exists studios_start_platform_trial on studios;
create trigger studios_start_platform_trial
  after insert on studios
  for each row execute function tg_start_platform_trial();

revoke execute on function tg_start_platform_trial() from public, anon, authenticated;
create or replace function public.provision_studio(p_name text, p_slug text, p_timezone text, p_currency character, p_country character, p_owner_email text, p_valid_days integer DEFAULT 14)
 RETURNS provision_result
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_studio uuid;
  v_token  text;
  v_slug   text := lower(btrim(p_slug));
  v_email  text := lower(btrim(p_owner_email));
  v_cur    text := upper(btrim(p_currency));
  v_ctry   text := upper(btrim(p_country));
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

  -- Checked before anything is written, so a typo costs nothing.
  if not exists (select 1 from pg_timezone_names where name = btrim(p_timezone)) then
    return (null, null, null, 'invalid_timezone')::provision_result;
  end if;
  if v_cur !~ '^[A-Z]{3}$' then
    return (null, null, null, 'invalid_currency')::provision_result;
  end if;
  if v_ctry !~ '^[A-Z]{2}$' then
    return (null, null, null, 'invalid_country')::provision_result;
  end if;

  if exists (select 1 from studios where slug = v_slug) then
    return (null, null, null, 'slug_taken')::provision_result;
  end if;

  insert into studios (name, slug, timezone, currency, country, status)
  values (btrim(p_name), v_slug, btrim(p_timezone), v_cur, v_ctry, 'provisioning')
  returning id into v_studio;

  insert into studio_settings (studio_id) values (v_studio);

  -- Thirty days, no card required. The trigger below already guarantees a row
  -- exists for any studio however it was created; this states the operator-
  -- facing intent explicitly, and is where a future "founding partner gets
  -- ninety days" would be expressed.
  update platform_subscriptions
     set trial_ends_at = now() + interval '30 days'
   where studio_id = v_studio;

  insert into locations (studio_id, name, timezone, is_primary)
  values (v_studio, btrim(p_name), btrim(p_timezone), true);

  v_token := encode(extensions.gen_random_bytes(32), 'hex');

  insert into studio_invites (studio_id, email, token_hash, expires_at, created_by)
  values (v_studio, v_email,
          encode(extensions.digest(v_token, 'sha256'), 'hex'),
          now() + make_interval(days => greatest(p_valid_days, 1)),
          auth.uid());

  return (v_studio, v_token, now() + make_interval(days => greatest(p_valid_days, 1)), null)::provision_result;
end $function$

;
