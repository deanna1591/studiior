-- Migration 181 — Decision 40 amendment 4: resolve the purchase robustly.
--
-- Bug (real hosted purchase): Xendit APPENDS a suffix to the session's
-- reference_id on the PAYMENT object (payload data.reference_id was
-- "<our-uuid>_INzvmwJ…"), so the UUID-regex check filed the callback as
-- bad_reference and ignored it — the pack never activated and the member sat on
-- "Confirming your payment…".
--
-- Fix: resolve the purchase in order — (1) data.metadata.purchase_id (stamped on
-- session creation), (2) data.payment_session_id matched to the session id we
-- stored on the purchase, (3) reference_id with any "_suffix" stripped and
-- validated as a UUID. Only if all three fail is it bad_reference. Token-first
-- order and the cross-tenant check are kept; amount/currency checks unchanged.
--
-- Also: xendit_reprocess_ignored(studio) re-runs the resolution on STORED
-- ignored events, so a callback filed before this fix can be recovered without a
-- fake callback (manager-up). All create-or-replace / new; anon stays TWELVE.

-- The one resolver, shared by the webhook and the reprocess path.
create function xendit_resolve_purchase(p_data jsonb) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare
  c_uuid constant text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
  v_pid text; v_sess text; v_base text; v_id uuid;
begin
  -- (1) our own purchase id, stamped into the session metadata.
  v_pid := nullif(p_data -> 'metadata' ->> 'purchase_id', '');
  if v_pid ~ c_uuid then
    select id into v_id from xendit_purchases where id = v_pid::uuid;
    if v_id is not null then return v_id; end if;
  end if;
  -- (2) the Xendit session id we stored on the purchase.
  v_sess := nullif(p_data ->> 'payment_session_id', '');
  if v_sess is not null then
    select id into v_id from xendit_purchases where payment_session_id = v_sess;
    if v_id is not null then return v_id; end if;
  end if;
  -- (3) reference_id with any "_suffix" stripped, validated as a UUID (Xendit
  -- appends a suffix to the payment object's reference_id).
  v_base := split_part(coalesce(p_data ->> 'reference_id', ''), '_', 1);
  if v_base ~ c_uuid then
    select id into v_id from xendit_purchases where id = v_base::uuid;
    if v_id is not null then return v_id; end if;
  end if;
  return null;
end $$;
revoke execute on function xendit_resolve_purchase(jsonb) from public, anon, authenticated;
grant  execute on function xendit_resolve_purchase(jsonb) to service_role;

-- xendit_webhook: same as 180 but resolves the purchase via xendit_resolve_purchase.
create or replace function xendit_webhook(p_event jsonb, p_token text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  d jsonb := p_event -> 'data';
  v_event text := p_event ->> 'event';
  v_status text := upper(coalesce(d ->> 'status', ''));
  v_payment_id text := d ->> 'payment_id';
  v_amount numeric := nullif(d ->> 'amount', '')::numeric;
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

  v_event_id := coalesce(nullif(v_event, ''), 'event') || ':'
             || coalesce(nullif(v_payment_id, ''), nullif(p_event ->> 'id', ''),
                         encode(digest(p_event::text, 'sha256'), 'hex'));
  insert into xendit_events (studio_id, event_id, event_type, payload)
  values (v_studio, v_event_id, v_event, p_event)
  on conflict (event_id) do nothing;
  get diagnostics n = row_count;
  if n = 0 then return jsonb_build_object('result', 'duplicate'); end if;

  -- Resolve the purchase (metadata.purchase_id / session id / stripped reference).
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

-- Recover a callback filed before this fix: re-run the resolution on the
-- studio's STORED ignored events and activate any that now resolve to a pending
-- success. Manager-up; idempotent (a succeeded purchase is skipped).
create function xendit_reprocess_ignored(p_studio_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; v_id uuid; p xendit_purchases%rowtype; n int := 0; v_success boolean;
begin
  if not is_manager_up(p_studio_id) then
    raise exception 'that is not your studio' using errcode = 'PT403';
  end if;
  for r in
    select id, payload from xendit_events
     where studio_id = p_studio_id
       and error in ('bad_reference', 'unknown_reference')
       and purchase_id is null
  loop
    v_id := xendit_resolve_purchase(r.payload -> 'data');
    if v_id is null then continue; end if;
    select * into p from xendit_purchases where id = v_id and studio_id = p_studio_id;
    if p.id is null then continue; end if;
    v_success := upper(coalesce(r.payload -> 'data' ->> 'status', '')) = 'SUCCEEDED'
              or (r.payload ->> 'event') in ('payment.succeeded', 'payment.capture');
    if v_success and p.status <> 'succeeded' then
      perform xendit_activate_success_internal(p.id, r.payload -> 'data' ->> 'payment_id');
      update xendit_events set purchase_id = p.id, error = null, processed_at = now() where id = r.id;
      n := n + 1;
    end if;
  end loop;
  return jsonb_build_object('reprocessed', n);
end $$;
revoke execute on function xendit_reprocess_ignored(uuid) from public, anon;
grant  execute on function xendit_reprocess_ignored(uuid) to authenticated, service_role;

do $$
declare v_n int;
begin
  select count(*) into v_n from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
   where nsp.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if v_n <> 12 then raise exception 'anon surface is % functions, expected 12', v_n; end if;
end $$;
