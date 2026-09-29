-- Migration 185 — Decision 40 amendment 8: confirm on return (the belt).
--
-- Three GCash test payments completed at Xendit and NO webhook reached us
-- (Xendit-side delivery). The member sits on /purchase/{id} polling our DB. This
-- adds a BELT: while the purchase is still pending, the poll page (running as the
-- member) GETs the session from Xendit directly and, if COMPLETED, activates it
-- through the SAME internal path the owner's "Check pending payments" uses
-- (xendit_activate_success_internal) — guarded so a member can only confirm their
-- OWN pending purchase, rate-limited to once every 5s per purchase, and audited
-- ('xendit.return_check') so we can see how often webhooks were late. Webhooks
-- remain the primary path when they arrive; this is the belt.
--
-- Two member-guarded functions bracket the network GET the server action makes:
--   xendit_return_check_claim(purchase)  -> ownership + rate-limit + stamp,
--       returns {check, session_id, studio_id} (or the terminal status).
--   xendit_return_check_apply(purchase, session_status, payment_id) -> applies
--       COMPLETED via xendit_activate_success_internal (+ the audit row) or marks
--       EXPIRED/CANCELED — mirroring xendit_apply_session but member-guarded.
-- Both are new, authenticated-granted, member-guarded inside; anon stays TWELVE.

alter table xendit_purchases add column if not exists last_return_check_at timestamptz;

-- Claim a return-check slot: verify the caller owns this PENDING purchase and it
-- is not throttled, stamp the check time, and hand back the session id + studio
-- so the action can GET the session and decrypt the studio key. A terminal
-- purchase (or one with no session yet) comes back with check=false and its
-- status, so the poll page just shows it. p_now is a seam for the throttle test.
create or replace function xendit_return_check_claim(p_purchase_id uuid, p_now timestamptz default now())
returns jsonb
language plpgsql security definer set search_path = public as $$
declare p xendit_purchases%rowtype;
begin
  select * into p from xendit_purchases where id = p_purchase_id for update;
  if p.id is null then raise exception 'no such purchase' using errcode = 'PT404'; end if;
  if not exists (select 1 from members m where m.id = p.member_id and m.user_id = auth.uid()) then
    raise exception 'that purchase is not yours' using errcode = 'PT403';
  end if;
  -- Terminal already: nothing to ask Xendit.
  if p.status <> 'pending' then
    return jsonb_build_object('status', p.status, 'check', false);
  end if;
  -- No session attached yet: nothing to GET.
  if nullif(p.payment_session_id, '') is null then
    return jsonb_build_object('status', 'pending', 'check', false, 'reason', 'no_session');
  end if;
  -- Rate limit: at most once per 5 seconds per purchase.
  if p.last_return_check_at is not null and p_now - p.last_return_check_at < interval '5 seconds' then
    return jsonb_build_object('status', 'pending', 'check', false, 'throttled', true);
  end if;
  update xendit_purchases set last_return_check_at = p_now where id = p_purchase_id;
  return jsonb_build_object('status', 'pending', 'check', true,
    'session_id', p.payment_session_id, 'studio_id', p.studio_id);
end $$;
revoke execute on function xendit_return_check_claim(uuid, timestamptz) from public, anon;
grant  execute on function xendit_return_check_claim(uuid, timestamptz) to authenticated, service_role;

-- Apply the session status the action read from Xendit, for the member's OWN
-- purchase. COMPLETED activates through the same internal as the webhook and the
-- owner reconcile (idempotent) and writes the 'xendit.return_check' audit row;
-- EXPIRED/CANCELED marks the purchase. An already-succeeded purchase is a no-op
-- (returns before activating, so no second membership and no second audit row).
create or replace function xendit_return_check_apply(p_purchase_id uuid, p_session_status text, p_payment_id text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare p xendit_purchases%rowtype; v_st text := upper(coalesce(p_session_status, ''));
begin
  select * into p from xendit_purchases where id = p_purchase_id for update;
  if p.id is null then raise exception 'no such purchase' using errcode = 'PT404'; end if;
  if not exists (select 1 from members m where m.id = p.member_id and m.user_id = auth.uid()) then
    raise exception 'that purchase is not yours' using errcode = 'PT403';
  end if;
  if p.status = 'succeeded' then
    return jsonb_build_object('status', 'processed', 'outcome', 'succeeded');
  end if;

  if v_st = 'COMPLETED' then
    perform xendit_activate_success_internal(p.id, p_payment_id);
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (p.studio_id, auth.uid(), 'xendit.return_check', 'xendit_purchases', p.id,
            jsonb_build_object('payment_id', nullif(p_payment_id, ''), 'source', 'return_check'));
    return jsonb_build_object('status', 'processed', 'outcome', 'succeeded');
  elsif v_st in ('EXPIRED', 'CANCELED', 'CANCELLED') then
    perform xendit_fail_purchase_internal(p.id,
      case when v_st = 'EXPIRED' then 'expired' else 'cancelled' end, v_st);
    return jsonb_build_object('status', 'processed', 'outcome',
      case when v_st = 'EXPIRED' then 'expired' else 'cancelled' end);
  end if;
  return jsonb_build_object('status', 'ignored', 'reason', 'still_active');
end $$;
revoke execute on function xendit_return_check_apply(uuid, text, text) from public, anon;
grant  execute on function xendit_return_check_apply(uuid, text, text) to authenticated, service_role;

do $$
declare v_n int;
begin
  select count(*) into v_n from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
   where nsp.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if v_n <> 12 then raise exception 'anon surface is % functions, expected 12', v_n; end if;
end $$;
