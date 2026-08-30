-- =============================================================================
-- MIGRATION 004 — public studio lookup by slug
--
-- The member PWA lives at {slug}.studiior.app. Resolving that slug to a studio
-- happens BEFORE anyone signs in: the login page has to know whose studio it
-- is, and an unknown slug has to 404.
--
-- Migration 001 §16 says "anon gets nothing: there is no pre-login surface in
-- V1". That note is now out of date — the member subdomain IS a pre-login
-- surface. The fix belongs in SQL, not in the application: reaching for the
-- service role key to read a studio name would put a key that bypasses every
-- policy into an unauthenticated request path.
--
-- So the surface stays as narrow as it can be: one function, fixed columns,
-- active studios only. anon gets execute on this and nothing else. In
-- particular it never returns stripe_account_id, which is owner-only
-- (Permissions §14) and is why studio_public exists at all.
-- =============================================================================

create function studio_by_slug(p_slug text)
returns table (
  id          uuid,
  name        text,
  slug        text,
  timezone    text,
  currency    char(3),
  logo_url    text,
  brand_color text
)
language sql
stable
security definer
set search_path = public
as $$
  select s.id, s.name, s.slug, s.timezone, s.currency, s.logo_url, s.brand_color
    from studios s
   where s.slug = lower(p_slug)
     and s.status = 'active'
     and s.archived_at is null
$$;

comment on function studio_by_slug(text) is
  'Public branding lookup for {slug}.studiior.app, callable before sign-in. '
  'Fixed safe columns only — never stripe_account_id. The only anon-reachable '
  'surface in the schema.';

-- anon needs schema usage to call anything at all here. It is granted execute
-- on this one function and nothing else; the blanket grants in migration 001
-- §16 deliberately skipped anon and still do.
grant usage on schema public to anon;
revoke all on function studio_by_slug(text) from public;
grant execute on function studio_by_slug(text) to anon, authenticated, service_role;
