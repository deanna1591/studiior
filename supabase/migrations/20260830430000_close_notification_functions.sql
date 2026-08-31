-- =============================================================================
-- Migration 033: the notification functions were open to every signed-in user
-- =============================================================================
-- Found while verifying migration 032 against hosted. On the live project:
--
--   set role authenticated;
--   select notification_api_key();   -->  re_...    the Resend key, in full
--
-- Any account that can sign in to any studio — including a walk-in who
-- self-signed-up on a subdomain thirty seconds ago — could read the sending
-- credential, and then:
--
--   send_via_resend(to, from_name, subject, text, html)  -- arbitrary mail,
--                                                        -- from our domain
--   render_notification(id)   -- any studio's rendered email: member name,
--                             -- address, class, in cleartext, cross-tenant
--   deliver_notification(id)  -- send any of them, now
--   queue_notification(...)   -- write into any studio's queue
--
-- None of these check anything. They were never meant to be reachable: they are
-- the inside of the worker, entered from a trigger or from pg_cron, and every
-- one of them is SECURITY DEFINER — so the caller does not need the privilege,
-- the owner does.
--
-- WHY MIGRATION 030 DID NOT CATCH IT. It ends with, in good faith:
--
--   revoke execute on function send_via_resend(...) from public;
--
-- which is precisely the mistake CLAUDE.md already records against `anon` and
-- migration 006: **revoking from PUBLIC is not the same as revoking from a
-- named role.** The hosted platform's default privileges name `authenticated`
-- explicitly, so every function `postgres` creates in `public` is born with an
-- `authenticated=X` grant that a revoke from PUBLIC does not touch. Migration
-- 011 fixed the default for `anon` and nobody thought to ask the same question
-- about `authenticated` — it is the app's own role, so it reads as harmless.
--
-- It is not harmless for a function with no guard in it. `anon` is the role we
-- remember to fear; `authenticated` is every member of every studio.
--
-- The advisor query in CLAUDE.md missed this because it only ever asked about
-- `anon`. It has been widened to ask about both.
--
-- SEPARATELY, and from the same blind spot: migration 031's three trigger
-- functions came out **anon**-executable on hosted, breaking migration 011's
-- "nobody calls a trigger function directly" rule and putting five extra names
-- into the advisor query's output. PostgreSQL does not check EXECUTE when a
-- trigger fires, so closing them costs nothing and they are closed here too.
--
-- Revoking by OID rather than by transcribed signature: `queue_notification`
-- alone has six parameters, and a signature typed out by hand that does not
-- match is not an error — it is a `revoke` that silently matches nothing.
-- =============================================================================

do $$
declare
  f record;
  n_closed int := 0;
  internals text[] := array[
    -- config and secrets
    'notification_setting', 'notification_api_key',
    -- queueing: reached from triggers and from the worker, never from a client
    'notification_wanted', 'queue_notification',
    'queue_booking_notifications', 'queue_waitlist_offer',
    'queue_occurrence_cancelled', 'queue_substitution',
    'queue_payment_failed', 'queue_milestone',
    'queue_credit_expiries', 'queue_all_credit_expiries',
    -- rendering and transport
    'render_notification', 'send_via_resend', 'deliver_notification',
    -- the two cron entry points: guarded by is_service_context(), but an
    -- authenticated caller has no business reaching even the guard
    'send_due_notifications', 'reconcile_notification_sends',
    -- trigger functions, per migration 011
    'tg_queue_booking_notifications', 'tg_queue_waitlist_offer',
    'tg_cancel_booking_notifications'
  ];
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace nsp on nsp.oid = p.pronamespace
     where nsp.nspname = 'public'
       and p.proname = any (internals)
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
    n_closed := n_closed + 1;
  end loop;

  if n_closed = 0 then
    raise exception 'migration 033 matched no functions — the names have drifted';
  end if;
  raise notice 'migration 033: closed % notification functions to anon and authenticated', n_closed;
end $$;

-- The worker's two entry points stay reachable by the backend role only. There
-- is no service-role client in this codebase and there should never be one;
-- this is here so that a future out-of-band runner does not need a new grant
-- written under pressure.
grant execute on function send_due_notifications()        to service_role;
grant execute on function reconcile_notification_sends()  to service_role;

comment on function notification_api_key() is
  'Returns the Resend key from Vault or a database setting. Executable by the '
  'owner only: it is called from inside send_via_resend(), which is SECURITY '
  'DEFINER, so no client role needs execute on it. It was granted to '
  'authenticated by a hosted default privilege until migration 033.';
