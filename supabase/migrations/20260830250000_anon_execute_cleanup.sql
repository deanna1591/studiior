-- =============================================================================
-- MIGRATION 014 — anon executes three functions in public, and nothing else
--
-- After 013 the advisor still listed 191 anon-executable functions in public.
-- Three are ours and deliberate; 188 are btree_gist index-support internals.
--
-- WHAT DOES NOT WORK, AND WHY IT IS WORTH WRITING DOWN
--
-- The obvious fix — `revoke execute on all functions in schema public from
-- anon` — cannot touch those 188. They are owned by supabase_admin and their
-- grants were made by supabase_admin:
--
--   gbt_int4_compress acl:
--     {=X/supabase_admin, supabase_admin=X/supabase_admin,
--      postgres=X/supabase_admin, anon=X/supabase_admin, ...}
--
-- Migrations run as postgres, which is not a member of supabase_admin, and a
-- REVOKE only removes grants the revoking role made. Running it against one of
-- these functions on the hosted project succeeded with no error and left the
-- ACL byte-identical. A migration built on that revoke alone would look like it
-- worked and change nothing — the same shape of mistake as migration 006
-- revoking PUBLIC when the grant was to anon.
--
-- WHAT DOES WORK
--
-- Move the extension out of public. PostgREST exposes public, so an extension
-- living there is an API surface; Supabase's own guidance is that extensions
-- belong in `extensions`. btree_gist is installed but entirely unused today —
-- no GiST index, no exclusion constraint anywhere in the schema — so this is
-- free now and would not be later, once something depends on its operators.
--
-- The move is attempted rather than assumed: if the platform declines it, the
-- migration says so and carries on, because the revoke below is worth doing on
-- its own.
-- =============================================================================

do $$
begin
  if exists (
    select 1 from pg_extension e join pg_namespace n on n.oid = e.extnamespace
     where e.extname = 'btree_gist' and n.nspname = 'public'
  ) then
    alter extension btree_gist set schema extensions;
    raise notice 'migration 014: moved btree_gist out of public into extensions';
  else
    raise notice 'migration 014: btree_gist is not in public, nothing to move';
  end if;
exception when others then
  -- Owned by supabase_admin; postgres may not be allowed to move it.
  raise notice
    'migration 014: could not move btree_gist (% / %). Its support functions '
    'stay anon-executable in public. They take internal-typed arguments so '
    'PostgREST cannot expose them, but the advisor will keep counting them.',
    sqlerrm, sqlstate;
end $$;

-- =============================================================================
-- Everything anon can execute in public, closed — then the three re-opened.
--
-- This is belt and braces over the individual revokes in 011, 012 and 013: it
-- catches anything those enumerated lists missed, and anything a future
-- migration creates before someone remembers to revoke. Only anon is touched;
-- authenticated and service_role keep what RLS policies and the app need.
-- =============================================================================

revoke execute on all functions in schema public from anon;

-- The three pre-login surfaces, and the reason each one exists.
--   studio_by_slug          {slug}.studiior.app has to name the studio before
--                           anyone signs in (migration 004)
--   studio_invite_preview   an invite link must be able to say "expired" or
--                           "already used" rather than failing on submit (012)
--   accept_studio_invite    the invitee has no account yet; the 256-bit token
--                           in the link is the credential (012)
grant execute on function studio_by_slug(text)                     to anon;
grant execute on function studio_invite_preview(text)              to anon;
grant execute on function accept_studio_invite(text, text, text)   to anon;
