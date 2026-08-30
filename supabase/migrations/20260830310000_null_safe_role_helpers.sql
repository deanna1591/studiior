-- =============================================================================
-- MIGRATION 020 — is_manager_up() and is_desk_up() must not return null
--
-- auth_role_in(target) returns the caller's role in that studio, or NULL when
-- they are not active staff of it. That is correct and useful. But
--
--   is_manager_up(t) := auth_role_in(t) in ('owner','manager')
--
-- is NULL for a stranger, not false, because NULL in (...) is NULL. In an RLS
-- policy that is harmless — USING and WITH CHECK both admit a row only when the
-- expression is true, so NULL denies, which is what we want and why 001's
-- policies have been correct all along.
--
-- In plpgsql it is the opposite. Every guard in the codebase is written
--
--   if not is_manager_up(x) then raise ... end if;
--
-- and `if not NULL` is NULL, which is not true, so the branch is skipped and
-- the function carries on. The guard reads like a check and behaves like a
-- comment. The callers are all SECURITY DEFINER, so they have already left RLS
-- behind: import_commit() and import_rollback() would have written to another
-- studio's rows for any authenticated caller who knew an import id. Found by
-- pointing a front desk login at an import belonging to a studio it has no
-- staff row in at all, and watching the dry run succeed.
--
-- Fixed here rather than at the eleven call sites because the call sites are
-- the natural way to write it and the next one will be written the same way.
-- Two of them are in migration 012, which is applied on hosted and cannot be
-- edited; this reaches those too.
--
-- Both functions keep their signature, so the ~110 policies that reference them
-- are unaffected — a stranger got NULL before and gets false now, and both deny.
-- =============================================================================

create or replace function is_manager_up(target uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(auth_role_in(target) in ('owner', 'manager'), false)
$$;

create or replace function is_desk_up(target uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(
    auth_role_in(target) in ('owner', 'manager', 'front_desk'), false)
$$;

comment on function is_manager_up(uuid) is
  'True when the caller is an active owner or manager of this studio. Never '
  'null: a plpgsql guard written "if not is_manager_up(x)" is a no-op against '
  'a null, and every guard in this codebase is written that way. See migration '
  '020.';
comment on function is_desk_up(uuid) is
  'True when the caller is an active owner, manager or front desk of this '
  'studio. Never null, for the reason in migration 020.';
