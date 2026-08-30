-- =============================================================================
-- MIGRATION 005 — correct the record on the anon surface
--
-- Comment-only. No schema change, no grant change, no behaviour change.
-- Migration 006 makes the grant change this note describes.
--
-- Migration 001 §16 ends with:
--
--     `anon` gets nothing: there is no pre-login surface in V1.
--
-- Both halves need correcting.
--
-- "There is no pre-login surface" stopped being true in migration 004. The
-- member PWA at {slug}.studiior.app resolves its slug to a studio before
-- anyone signs in, which is a pre-login surface by definition. A reader who
-- believes §16 may "simplify" that grant away, or reach for the service role
-- key on the assumption that no anon-callable path can exist — and the second
-- would put a key that bypasses every policy into an unauthenticated request
-- path.
--
-- "anon gets nothing" was never quite true either, and not for the reason you
-- would guess. §16 withheld the table grants, and that part worked: anon holds
-- no select, insert, update or delete on any table or view in this schema, so
-- it cannot read or write a single row. What §16 did not account for is that
-- PostgreSQL grants EXECUTE on a new function to PUBLIC by default. Every
-- function here was therefore anon-callable from the moment it was created,
-- including the RLS helpers auth_staff_studios(), auth_member_studios(),
-- auth_role_in(), auth_instructor_id(), is_owner(), is_manager_up() and
-- is_desk_up().
--
-- Nothing leaked: those are security definer, keyed off auth.uid(), and
-- auth.uid() is null for anon, so they return null or nothing. book_class()
-- revoked PUBLIC explicitly, as did studio_by_slug(). But "callable by anyone
-- unless someone remembered to revoke" is not the posture §16 claims, and it
-- is one refactor away from mattering. Migration 006 closes it.
--
-- 001 has run against a database, so it is history and is not edited (see
-- CLAUDE.md, "An applied migration is immutable"). The correction goes on the
-- schema itself, so it lives in the database rather than in a file somebody
-- has to know to read:
--
--     select obj_description('public'::regnamespace, 'pg_namespace');
-- =============================================================================

comment on schema public is
  'Studiior application schema. '
  'authenticated and service_role hold table privileges, scoped row-by-row by '
  'RLS. anon holds usage on this schema and execute on studio_by_slug(text) — '
  'the single pre-login surface, behind {slug}.studiior.app — and no select, '
  'insert, update or delete on any table or view. This supersedes migration '
  '001 §16, which predates that function and says there is no pre-login '
  'surface in V1; there is exactly one. '
  'Note that PostgreSQL grants EXECUTE to PUBLIC by default, so a new function '
  'is anon-callable unless it revokes that explicitly — see migration 006. '
  'Anything that appears to need the service role key in a request path is a '
  'missing policy, not a reason to use the key.';
