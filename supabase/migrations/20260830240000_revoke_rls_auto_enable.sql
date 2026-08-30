-- =============================================================================
-- MIGRATION 013 — close rls_auto_enable(), the one migration 011 could not see
--
-- Supabase installs public.rls_auto_enable() on hosted projects: a SECURITY
-- DEFINER function owned by postgres, backing the `ensure_rls` event trigger on
-- ddl_command_end, which turns RLS on for every table as it is created. Its ACL
-- on hosted reads
--
--   {=X/postgres, postgres=X/postgres, anon=X/postgres,
--    authenticated=X/postgres, service_role=X/postgres}
--
-- — the bare `=X` being PUBLIC. So it is callable by anon, and by everyone else.
--
-- Migration 011 missed it for a reason worth recording: it does not exist
-- locally. 011 enumerated the functions this project creates, checked them
-- against a local `db reset`, and had nothing to enumerate here. This is the
-- same lesson 011 already wrote into CLAUDE.md, arriving a second time from a
-- different direction — local is not a mirror of hosted, and grants in
-- particular have to be read from the hosted project.
--
-- Same treatment as the trigger functions in 011: an event trigger function is
-- fired by the system, never called, so EXECUTE buys nothing except a way to
-- reach it over /rest/v1/rpc. Revoked from everyone; postgres keeps its owner
-- rights, which is what the event trigger actually runs on.
--
-- Guarded, because it genuinely is absent locally and an unguarded REVOKE on a
-- missing function aborts the migration — which would break `supabase db reset`
-- for everyone while fixing nothing.
-- =============================================================================

do $$
declare
  fn record;
  n  int := 0;
begin
  for fn in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace nsp on nsp.oid = p.pronamespace
     where nsp.nspname = 'public'
       and p.proname   = 'rls_auto_enable'
  loop
    -- Signature taken from the catalogue rather than assumed, so this holds if
    -- the platform ever ships a different argument list.
    execute format(
      'revoke execute on function %s from public, anon, authenticated, service_role',
      fn.sig);
    n := n + 1;
    raise notice 'migration 013: revoked execute on %', fn.sig;
  end loop;

  if n = 0 then
    raise notice
      'migration 013: public.rls_auto_enable() is not present (expected on a '
      'local stack) — nothing to revoke';
  end if;
end $$;
