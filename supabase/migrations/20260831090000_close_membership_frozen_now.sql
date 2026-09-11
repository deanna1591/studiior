-- =============================================================================
-- 103 — an unguarded internal from migration 095 loses a grant it never needed.
--
-- Found by running the advisor query against HOSTED after 102 landed, which is
-- the half a local reset cannot answer — and then asking the OTHER half of the
-- question, which is migration 056's rule: the grant surface being right says
-- nothing about whether anything inside the function is standing in the way.
--
-- The grant surface WAS right. `anon` reaches exactly the nine pre-login
-- surfaces, 102's drop-and-recreate of activate_purchase() did not reopen it on
-- hosted, and of the twenty-six SECURITY DEFINER functions that 089–102 leave
-- callable by `authenticated`, twenty-three guard before they do any work.
-- Three do not, and two of those are the instructor token pair — pre-login by
-- nature, where the hashed single-use token IS the credential.
--
-- The third is the finding.
-- -----------------------------------------------------------------------------
-- `membership_frozen_now(uuid)` IS UNGUARDED AND WAS CALLABLE BY EVERY SIGNED-IN
-- USER OF EVERY STUDIO.
--
-- It takes a membership id and returns a boolean about it, stepping over the
-- RLS on `memberships` that would otherwise have refused. A boolean is the same
-- class of leak as a row — migration 086 closed `occurrence_is_adjacent()`, "a
-- boolean about somebody else's day", for exactly this reason, and
-- `claw_back_conversion_bonus()` for answering "no bonus to reverse" to
-- anybody.
--
-- IT LOSES THE GRANT RATHER THAN GAINING A GUARD, which is the stronger answer
-- and the one migration 086 gave `ensure_pay_period()` and
-- `next_open_pay_period()`. Nothing outside the database has ever called it:
-- the only references anywhere are `advance_membership_period()`,
-- `memberships_due()` and `sweep_membership_periods()`, all of which have
-- already checked their caller. Closed to every client role says that, where a
-- guard would only say "somebody might legitimately call this".
--
-- It was granted in migration 095 — mine, one session ago — beside its revoke,
-- in the shape of a public reader, without anything asking for it.
-- -----------------------------------------------------------------------------
revoke execute on function membership_frozen_now(uuid) from public, anon, authenticated;
grant  execute on function membership_frozen_now(uuid) to service_role;

-- -----------------------------------------------------------------------------
-- `advance_membership_period(uuid)` IS LEFT ALONE, and that is a judgement.
--
-- It also has no app caller — `record_manual_payment()` is its only caller
-- anywhere — but unlike the above it IS guarded, desk-up, and
-- `manual_payments_test.sql` exercises it as a client on purpose: a stranger
-- gets PT403, a class pack PT422, a frozen membership PT409. Closing it would
-- delete four real assertions about Decision 23's rules to buy a hardening
-- nobody asked for.
--
-- WORTH RECORDING RATHER THAN ACTING ON: reachable on its own it lets front
-- desk roll a membership forward a month with no payment row, and the payment
-- row is the whole trace the manual path exists to leave. A studio's own front
-- desk can already record a payment of zero, so this is a difference of
-- traceability within one tenant, not a tenant boundary. If that should be
-- closed, the four assertions move to a postgres session in the same change.
-- -----------------------------------------------------------------------------

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure::text as sig,
           has_function_privilege('anon', p.oid, 'execute') as anon,
           has_function_privilege('authenticated', p.oid, 'execute') as authed,
           has_function_privilege('service_role', p.oid, 'execute') as svc
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('membership_frozen_now')
  loop
    if r.anon or r.authed then
      raise exception 'migration 103: % is still reachable by a client role', r.sig;
    end if;
    if not r.svc then
      raise exception 'migration 103: % lost the grant its callers need', r.sig;
    end if;
  end loop;
end $$;
