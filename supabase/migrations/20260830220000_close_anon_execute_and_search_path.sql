-- =============================================================================
-- MIGRATION 011 — close the anon RPC surface properly, and pin search_path
--
-- WHY MIGRATION 006 DID NOT DO THIS
--
-- 006 revoked EXECUTE from PUBLIC and flipped the schema default for PUBLIC.
-- Locally that was enough and every check passed. On the hosted project it
-- changed nothing that mattered, because the grant there does not come from
-- PUBLIC at all.
--
-- The hosted platform ships default privileges that name anon explicitly:
--
--   hosted   pg_default_acl (postgres, functions):
--     {postgres=X/postgres, anon=X/postgres, authenticated=X/postgres,
--      service_role=X/postgres}
--
--   local    pg_default_acl (postgres, functions):
--     {postgres=X/postgres, authenticated=X/postgres, service_role=X/postgres}
--
-- So on hosted, every function created by postgres in this schema receives an
-- explicit `anon=X` grant the instant it is created. Revoking from PUBLIC does
-- not touch it: PUBLIC and anon are different grantees, and only one of them
-- was ever addressed. The proof is in the ACLs the hosted project reports now —
-- `auth_role_in -> {postgres=X/postgres, anon=X/postgres, ...}` with no PUBLIC
-- entry at all. 006's revoke worked; it just removed something that was not
-- what was granting access.
--
-- Two consequences worth writing down:
--
--   * `supabase db reset` cannot reproduce this class of bug. The two
--     environments have different default ACLs, so a function is anon-callable
--     on hosted and closed locally, and every local test agrees with the wrong
--     answer. Grants are the one thing that has to be checked against the
--     hosted project.
--
--   * Naming PUBLIC is not the same as closing a function. Say `anon`.
--
-- =============================================================================
-- 1. Nobody calls a trigger function directly
--
-- PostgreSQL does not check EXECUTE when a trigger fires — the privilege is
-- irrelevant to the thing these exist for, and only useful to somebody poking
-- at /rest/v1/rpc. Closed to everyone, including authenticated and
-- service_role.
-- =============================================================================

revoke execute on function set_updated_at()          from public, anon, authenticated, service_role;
revoke execute on function guard_last_owner()        from public, anon, authenticated, service_role;
revoke execute on function enforce_checkin_window()  from public, anon, authenticated, service_role;
revoke execute on function guard_plan_delete()       from public, anon, authenticated, service_role;

-- =============================================================================
-- 2. The auth/RLS helpers and book_class: authenticated yes, anon no
--
-- RLS policy expressions are evaluated as the querying user, so authenticated
-- must keep EXECUTE on the helpers or every policy that calls one stops
-- working. anon has no session, so these can only ever return null or nothing
-- for it — but "safe because it resolves to nobody" is not a grant policy.
-- =============================================================================

revoke execute on function auth_staff_studios()      from public, anon;
revoke execute on function auth_member_studios()     from public, anon;
revoke execute on function auth_role_in(uuid)        from public, anon;
revoke execute on function auth_instructor_id(uuid)  from public, anon;
revoke execute on function is_owner(uuid)            from public, anon;
revoke execute on function is_manager_up(uuid)       from public, anon;
revoke execute on function is_desk_up(uuid)          from public, anon;

revoke execute on function book_class(uuid, uuid, booking_source, text, payment_source)
  from public, anon;

-- Re-stated rather than assumed: these must survive the revokes above.
grant execute on function auth_staff_studios()       to authenticated, service_role;
grant execute on function auth_member_studios()      to authenticated, service_role;
grant execute on function auth_role_in(uuid)         to authenticated, service_role;
grant execute on function auth_instructor_id(uuid)   to authenticated, service_role;
grant execute on function is_owner(uuid)             to authenticated, service_role;
grant execute on function is_manager_up(uuid)        to authenticated, service_role;
grant execute on function is_desk_up(uuid)           to authenticated, service_role;
grant execute on function book_class(uuid, uuid, booking_source, text, payment_source)
  to authenticated, service_role;

-- =============================================================================
-- 3. studio_by_slug stays open — it is the one genuine exception
--
-- The member PWA at {slug}.studiior.app must resolve its slug to a studio
-- before anyone signs in (migration 004, and the correction in 005). Fixed safe
-- columns, active studios only, never stripe_account_id.
-- =============================================================================

grant execute on function studio_by_slug(text) to anon, authenticated, service_role;

-- =============================================================================
-- 4. Stop the next function being born anon-callable
--
-- This is the part that actually prevents a repeat. Without it, migration 012
-- adds a function and the hosted default ACL grants anon EXECUTE on it before
-- anybody thinks to revoke.
--
-- Run as postgres, so it edits the `postgres` default-privilege entry — the one
-- that governs functions our migrations create. It is a no-op locally, where
-- anon was never in that entry, which is exactly why this has to be verified
-- against hosted.
--
-- The parallel supabase_admin entry is out of reach and stays as it is: it
-- governs objects supabase_admin creates, which are the platform's, not ours.
-- =============================================================================

alter default privileges in schema public revoke execute on functions from anon;

-- =============================================================================
-- 5. Pin search_path on the five that predate the convention
--
-- A function without a fixed search_path resolves unqualified names against
-- whatever the caller has set. On a SECURITY DEFINER function that is a way to
-- run attacker-chosen code as the owner; on the others it is still a way to get
-- the wrong table. ALTER FUNCTION rather than CREATE OR REPLACE, so no body is
-- restated and no behaviour moves.
-- =============================================================================

alter function set_updated_at()       set search_path = public;
alter function guard_last_owner()     set search_path = public;
alter function is_owner(uuid)         set search_path = public;
alter function is_manager_up(uuid)    set search_path = public;
alter function is_desk_up(uuid)       set search_path = public;

comment on schema public is
  'Studiior application schema. '
  'authenticated and service_role hold table privileges, scoped row-by-row by '
  'RLS. anon holds usage on this schema and execute on studio_by_slug(text) — '
  'the single pre-login surface, behind {slug}.studiior.app — and nothing '
  'else: no table, no view, no other function. Migration 011 closed the rest. '
  'Note the hosted platform default-grants EXECUTE on new functions to anon '
  'even though local does not, so a new function is anon-callable on hosted '
  'until revoked, and local tests will not tell you. Say who may execute, '
  'every time, and check it against the hosted project. '
  'Anything that appears to need the service role key in a request path is a '
  'missing policy, not a reason to use the key.';
