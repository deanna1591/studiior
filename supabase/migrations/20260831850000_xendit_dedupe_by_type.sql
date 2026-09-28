-- Migration 180 — Decision 40 amendment 3: the event dedupe key includes the
-- event TYPE, not just the payment id.
--
-- A payment.failure and a later payment.succeeded for the SAME payment_id are
-- two distinct events, not a replay of one — keying idempotency on the payment
-- id alone would swallow the success as a "duplicate" of the failure and never
-- activate. The event_id is now `<event_type>:<payment_id-or-id-or-hash>`.
--
-- create or replace (ACL held, anon stays EXACTLY TWELVE). Everything else is
-- migration 179's sample-safe body, unchanged.

create or replace function xendit_webhook(p_event jsonb, p_token text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  d jsonb := p_event -> 'data';
  v_ref text := d ->> 'reference_id';
  v_event text := p_event ->> 'event';
  v_status text := upper(coalesce(d ->> 'status', ''));
  v_payment_id text := d ->> 'payment_id';
  v_amount numeric := nullif(d ->> 'amount', '')::numeric;
  v_currency text := upper(nullif(d ->> 'currency', ''));
  v_studio uuid;
  v_event_id text; n int; v_success boolean; v_failure boolean;
  p xendit_purchases%rowtype;
  c_uuid constant text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
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

  -- Idempotency key = event TYPE + payment id (or event id, or a payload hash).
  -- The type is part of the key so payment.failure and payment.succeeded for the
  -- same payment id are two events, not a duplicate.
  v_event_id := coalesce(nullif(v_event, ''), 'event') || ':'
             || coalesce(nullif(v_payment_id, ''), nullif(p_event ->> 'id', ''),
                         encode(digest(p_event::text, 'sha256'), 'hex'));
  insert into xendit_events (studio_id, event_id, event_type, payload)
  values (v_studio, v_event_id, v_event, p_event)
  on conflict (event_id) do nothing;
  get diagnostics n = row_count;
  if n = 0 then return jsonb_build_object('result', 'duplicate'); end if;

  if v_ref is null or v_ref !~ c_uuid then
    update xendit_events set processed_at = now(), error = 'bad_reference' where event_id = v_event_id;
    return jsonb_build_object('result', 'ignored', 'reason', 'bad_reference');
  end if;
  select * into p from xendit_purchases where id = v_ref::uuid;
  if p.id is null then
    update xendit_events set processed_at = now(), error = 'unknown_reference' where event_id = v_event_id;
    return jsonb_build_object('result', 'ignored', 'reason', 'unknown_reference');
  end if;
  if p.studio_id <> v_studio then
    update xendit_events set processed_at = now(), error = 'cross_tenant' where event_id = v_event_id;
    return jsonb_build_object('result', 'ignored', 'reason', 'cross_tenant');
  end if;
  update xendit_events set purchase_id = p.id where event_id = v_event_id;

  v_success := v_status = 'SUCCEEDED' or v_event in ('payment.succeeded', 'payment.capture');
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
