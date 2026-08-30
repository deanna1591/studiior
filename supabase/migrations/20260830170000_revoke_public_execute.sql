-- =============================================================================
-- MIGRATION 006 — stop granting EXECUTE to PUBLIC by default
--
-- PostgreSQL grants EXECUTE on a new function to PUBLIC. Migration 001 §16
-- granted execute to authenticated and service_role and withheld it from anon,
-- but withholding does nothing when PUBLIC already has it: every function in
-- this schema has been anon-callable since it was created. book_class() and
-- studio_by_slug() revoke PUBLIC by hand; nothing else did.
--
-- Nothing leaked. The RLS helpers are security definer and keyed off
-- auth.uid(), which is null for anon, so they return null or the empty set.
-- But "safe because anon happens to resolve to nobody" is a weaker guarantee
-- than "anon cannot call it", and the difference shows up the first time one
-- of these takes an argument that means something without a session.
--
-- So: revoke PUBLIC on the auth and RLS helpers, then re-grant explicitly to
-- the roles that need them. RLS policy expressions are evaluated as the
-- querying user, so authenticated must keep EXECUTE or every policy that calls
-- these stops working — which is exactly what test/rls_test.sql checks.
--
-- Trigger functions are left alone: PostgreSQL does not check EXECUTE on a
-- trigger function when the trigger fires, and revoking there buys nothing.
--
-- The default is fixed for future functions too, so the next migration does
-- not have to remember.
-- =============================================================================

revoke execute on function auth_staff_studios()          from public;
revoke execute on function auth_member_studios()         from public;
revoke execute on function auth_role_in(uuid)            from public;
revoke execute on function auth_instructor_id(uuid)      from public;
revoke execute on function is_owner(uuid)                from public;
revoke execute on function is_manager_up(uuid)           from public;
revoke execute on function is_desk_up(uuid)              from public;

grant execute on function auth_staff_studios()           to authenticated, service_role;
grant execute on function auth_member_studios()          to authenticated, service_role;
grant execute on function auth_role_in(uuid)             to authenticated, service_role;
grant execute on function auth_instructor_id(uuid)       to authenticated, service_role;
grant execute on function is_owner(uuid)                 to authenticated, service_role;
grant execute on function is_manager_up(uuid)            to authenticated, service_role;
grant execute on function is_desk_up(uuid)               to authenticated, service_role;

-- Future functions default to nobody, then get granted deliberately. Without
-- this, the next function added to this schema is anon-callable again and the
-- note in migration 005 goes stale a second time.
alter default privileges in schema public revoke execute on functions from public;
