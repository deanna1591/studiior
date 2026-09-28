-- Migration 177 — Decision 40 Part A amendment: expired is not final.
--
-- The local reconcile sweep marks a purchase 'expired' after a generous window,
-- but the member may actually have paid — a local timeout cannot be the last
-- word. Activation ALREADY honours this: xendit_activate_success_internal skips
-- only an already-'succeeded' purchase, so both xendit_webhook (a later
-- payment.succeeded) and xendit_apply_session (the owner's "check with Xendit"
-- reporting COMPLETED) activate an 'expired' purchase, amount/currency checks
-- unchanged. What was missing was a TRACE. This re-issues the ONE activation
-- point (create or replace, ACL held — service-role only, anon stays TWELVE) to
-- write an audit_logs row 'xendit.expiry_overridden' whenever the purchase it
-- activates was 'expired', so a paid-after-timeout activation is auditable.
-- (newest-definition.sh confirms 20260831810000 is the current definition.)

create or replace function xendit_activate_success_internal(p_purchase_id uuid, p_payment_id text)
returns text
language plpgsql security definer set search_path = public as $$
declare p xendit_purchases%rowtype; v_ms uuid; v_prior text;
begin
  select * into p from xendit_purchases where id = p_purchase_id for update;
  if p.id is null then return 'unknown_purchase'; end if;
  if p.status = 'succeeded' then return 'already_succeeded'; end if;
  v_prior := p.status;

  v_ms := activate_purchase(p.studio_id, p.member_id, p.plan_id, p.amount_cents, p.currency,
                            null, null, false);

  insert into payments (studio_id, member_id, membership_id, amount_cents, currency,
                        status, provider, reference, description, paid_at)
  select p.studio_id, p.member_id, v_ms, p.amount_cents, p.currency, 'succeeded', 'xendit',
         nullif(p_payment_id, ''), mp.name, now()
    from membership_plans mp where mp.id = p.plan_id;

  -- Expired is not final: if the local sweep had already marked this purchase
  -- expired and a real payment then arrived, record that the expiry was
  -- overridden so the paid-after-timeout activation is traceable.
  if v_prior = 'expired' then
    insert into audit_logs (studio_id, action, entity_table, entity_id, after)
    values (p.studio_id, 'xendit.expiry_overridden', 'xendit_purchases', p.id,
            jsonb_build_object('prior_status', v_prior,
                               'payment_id', nullif(p_payment_id, ''),
                               'note', 'paid after local expiry'));
  end if;

  update xendit_purchases
     set status = 'succeeded', xendit_payment_id = nullif(p_payment_id, ''),
         completed_at = now(), failure_reason = null, updated_at = now()
   where id = p_purchase_id;

  return case when v_prior = 'expired' then 'activated_after_expiry' else 'activated' end;
end $$;

revoke execute on function xendit_activate_success_internal(uuid, text) from public, anon, authenticated;
grant  execute on function xendit_activate_success_internal(uuid, text) to service_role;
