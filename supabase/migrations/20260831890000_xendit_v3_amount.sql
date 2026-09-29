-- Migration 184 — Decision 40 amendment 7: read the v3 "Payment Status" shape.
--
-- Xendit's V3 "Payment Status" webhook (api_version v3, event payment.capture,
-- status SUCCEEDED) carries the amount in data.request_amount (and
-- data.captures[].capture_amount) — NOT data.amount — and the payment reference
-- in data.payment_id (no data.id). The webhook read the amount only from
-- data.amount, so for a v3 capture v_amount was null and the amount validation
-- was SILENTLY SKIPPED (an amount_mismatch v3 event would have activated). Two
-- reads widen:
--   * amount    := coalesce(data.amount, data.request_amount, captures[0].capture_amount)
--   * payment ref := coalesce(data.payment_id, data.id)
-- Everything else is byte-for-byte migration 182: token-first, resolve via
-- xendit_resolve_purchase, cross-tenant guard, status-driven success/failure,
-- dedupe on event TYPE + payment ref. A payment_request.expiry (status EXPIRED)
-- for an already-succeeded purchase is still a no-op — xendit_fail_purchase_internal
-- returns early on status 'succeeded'.
-- create or replace (ACL held, anon stays EXACTLY TWELVE).

create or replace function xendit_webhook(p_event jsonb, p_token text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  d jsonb := p_event -> 'data';
  v_event text := p_event ->> 'event';
  v_status text := upper(coalesce(d ->> 'status', ''));
  -- v3 "Payment Status" carries data.payment_id and NO data.id; the older shape
  -- carried the payment id in data.id. Take either.
  v_payment_id text := coalesce(nullif(d ->> 'payment_id', ''), nullif(d ->> 'id', ''));
  -- v3 payment.capture has the amount in request_amount (and captures[].capture_amount),
  -- not amount. Reading only data.amount would skip the amount check on a v3 capture.
  v_amount numeric := coalesce(
    nullif(d ->> 'amount', ''),
    nullif(d ->> 'request_amount', ''),
    nullif(d -> 'captures' -> 0 ->> 'capture_amount', '')
  )::numeric;
  v_currency text := upper(nullif(d ->> 'currency', ''));
  v_studio uuid;
  v_event_id text; n int; v_success boolean; v_failure boolean;
  v_pid uuid; p xendit_purchases%rowtype;
begin
  if p_token is null then
    raise exception 'bad Xendit callback token' using errcode = 'PT401';
  end if;
  select studio_id into v_studio from studio_payment_providers
   where provider = 'xendit'
     and callback_token_sha256 = encode(digest(p_token, 'sha256'), 'hex')
   limit 1;
  if v_studio is null then
    raise exception 'bad Xendit callback token' using errcode = 'PT401';
  end if;

  -- Idempotency key = event TYPE + (payment id | payment_session_id | event id |
  -- payload hash). v3 capture has data.payment_id; payment_session.completed has
  -- no data.id, so the session id is the stable fallback.
  v_event_id := coalesce(nullif(v_event, ''), 'event') || ':'
             || coalesce(nullif(v_payment_id, ''), nullif(d ->> 'payment_session_id', ''),
                         nullif(p_event ->> 'id', ''), encode(digest(p_event::text, 'sha256'), 'hex'));
  insert into xendit_events (studio_id, event_id, event_type, payload)
  values (v_studio, v_event_id, v_event, p_event)
  on conflict (event_id) do nothing;
  get diagnostics n = row_count;
  if n = 0 then return jsonb_build_object('result', 'duplicate'); end if;

  v_pid := xendit_resolve_purchase(d);
  if v_pid is null then
    update xendit_events set processed_at = now(), error = 'bad_reference' where event_id = v_event_id;
    return jsonb_build_object('result', 'ignored', 'reason', 'bad_reference');
  end if;
  select * into p from xendit_purchases where id = v_pid;
  if p.studio_id <> v_studio then
    update xendit_events set processed_at = now(), error = 'cross_tenant' where event_id = v_event_id;
    return jsonb_build_object('result', 'ignored', 'reason', 'cross_tenant');
  end if;
  update xendit_events set purchase_id = p.id where event_id = v_event_id;

  -- Success is decided by STATUS (SUCCEEDED for a payment, COMPLETED for a
  -- session) or the payment event names. Status-driven, so payment_session.completed
  -- or payment.capture with a non-success status is caught by the failure branch.
  v_success := v_status in ('SUCCEEDED', 'COMPLETED') or v_event in ('payment.succeeded', 'payment.capture');
  v_failure := v_event = 'payment.failure' or v_status in ('FAILED', 'FAILURE', 'VOIDED', 'EXPIRED', 'CANCELED', 'CANCELLED');

  if v_success then
    if v_amount is not null and round(v_amount * 100) <> p.amount_cents then
      update xendit_events set error = 'amount_mismatch', processed_at = now() where event_id = v_event_id;
      return jsonb_build_object('result', 'refused', 'reason', 'amount_mismatch');
    end if;
    if v_currency is not null and v_currency <> upper(p.currency) then
      update xendit_events set error = 'currency_mismatch', processed_at = now() where event_id = v_event_id;
      return jsonb_build_object('result', 'refused', 'reason', 'currency_mismatch');
    end if;
    perform xendit_activate_success_internal(p.id, v_payment_id);
    update xendit_events set processed_at = now() where event_id = v_event_id;
    return jsonb_build_object('result', 'processed', 'outcome', 'succeeded');

  elsif v_failure then
    perform xendit_fail_purchase_internal(p.id, 'failed', coalesce(d ->> 'failure_code', v_event));
    update xendit_events set processed_at = now() where event_id = v_event_id;
    return jsonb_build_object('result', 'processed', 'outcome', 'failed');
  end if;

  update xendit_events set processed_at = now() where event_id = v_event_id;
  return jsonb_build_object('result', 'ignored', 'reason', 'non_terminal');
end $$;

revoke execute on function xendit_webhook(jsonb, text) from public;
grant  execute on function xendit_webhook(jsonb, text) to anon, authenticated, service_role;

do $$
declare v_n int;
begin
  select count(*) into v_n from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
   where nsp.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if v_n <> 12 then raise exception 'anon surface is % functions, expected 12', v_n; end if;
end $$;
