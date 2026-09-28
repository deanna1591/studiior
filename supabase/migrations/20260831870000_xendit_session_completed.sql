-- Migration 182 — Decision 40 amendment 5: the real checkout callback is
-- "payment_session.completed" with status COMPLETED.
--
-- The actual Xendit webhook for a PAY checkout is event "payment_session.completed"
-- (data.status "COMPLETED", data.amount 8500, data.reference_id = our purchase
-- uuid with NO suffix, data.payment_id "py-…", data.payment_session_id "ps-…",
-- data.metadata = {kind, plan_id, member_id, studio_id}, and NO data.id). The
-- webhook's success test only accepted status SUCCEEDED / event payment.succeeded,
-- so a COMPLETED session fell through to `non_terminal` and was ignored — the
-- pack never activated.
--
-- Fix: treat status COMPLETED as success (status-driven, so a
-- payment_session.completed carrying an EXPIRED/CANCELED status still falls to
-- the failure branch). And add payment_session_id to the idempotency key, since
-- there is no data.id here. A later payment.succeeded for the same purchase is a
-- distinct event (event type is in the key) but cannot double-activate — the
-- purchase is already `succeeded`, so xendit_activate_success_internal is a no-op.
-- create or replace (ACL held, anon stays EXACTLY TWELVE).

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

  -- Idempotency key = event TYPE + (payment id | payment_session_id | event id |
  -- payload hash). payment_session.completed has no data.id, so the session id is
  -- the stable fallback.
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
  -- with a non-success status is caught by the failure branch below.
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

-- The stored-event reprocess recognises COMPLETED the same way.
create or replace function xendit_reprocess_ignored(p_studio_id uuid) returns jsonb
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
    v_success := upper(coalesce(r.payload -> 'data' ->> 'status', '')) in ('SUCCEEDED', 'COMPLETED')
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
