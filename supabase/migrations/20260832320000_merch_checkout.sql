-- Decision 63b — in-app merchandise purchase through the existing Xendit checkout.
--
-- creates: xendit_begin_product_purchase(uuid, uuid, integer)
-- re-issues: xendit_activate_success_internal(uuid, text),
--   xendit_fail_purchase_internal(uuid, text, text)
--
-- A member buys a product through the SAME Xendit checkout a plan rides
-- (Decision 40). The branch between "a plan was bought" and "a product was
-- bought" sits INSIDE the two internals the whole pipeline funnels through —
-- xendit_activate_success_internal (success) and xendit_fail_purchase_internal
-- (failure/expiry) — so the webhook, the owner "check pending", the return-check
-- belt and the reconcile sweep all branch correctly with no change of their own.
--
-- Stock is RESERVED when the checkout starts (a reserved product_orders row,
-- products.stock decremented, a 'reserve' movement) so a second member cannot
-- buy the last unit while the first is paying; the reservation is RELEASED (a
-- 'release' movement, stock back) if the checkout fails, is cancelled, or
-- expires. On payment the order becomes 'paid', a 'release' + 'sale' pair
-- records the sold unit (net stock unchanged — it was already decremented at
-- reserve), a payments row is tagged with the order, and the member is emailed.
--
-- A merch purchase rides the existing anon xendit_webhook — NO new anon surface;
-- anon stays EXACTLY THIRTEEN (asserted at the end). Decision 18 untouched.

-- =============================================================================
-- 1. Schema. plan_id becomes nullable; a purchase targets a plan XOR a product.
-- =============================================================================
alter table xendit_purchases alter column plan_id drop not null;
alter table xendit_purchases
  add column product_order_id uuid references product_orders on delete set null;
alter table xendit_purchases
  add constraint xendit_purchase_one_target
  check ((plan_id is not null) <> (product_order_id is not null));

-- =============================================================================
-- 2. product_order_paid — the member's "ready to collect" email. A data row;
--    render_notification reads the body, an unlisted template defaults to send.
-- =============================================================================
insert into notification_templates (key, subject, text_body, html_body, note) values
  ('product_order_paid',
   'Your order is ready to collect',
   E'Hi {first_name},\n\nYour payment for {product} ×{quantity} at {studio_name} went through. Pick it up at the front desk whenever suits you.\n\n— {studio_name}',
   '<p>Hi {first_name},</p><p>Your payment for <strong>{product} ×{quantity}</strong> at {studio_name} went through. Pick it up at the front desk whenever suits you.</p><p>— {studio_name}</p>',
   'Decision 63b: an in-app merchandise purchase was paid; collect at the studio.')
on conflict (key) do nothing;

-- =============================================================================
-- 3. xendit_begin_product_purchase — the member app's "Buy" for a product.
--    Member-guarded; reserves stock; snapshots the unit price; mirrors
--    xendit_begin_purchase's return shape so the TS buy action is the same.
-- =============================================================================
create function xendit_begin_product_purchase(p_studio_id uuid, p_product_id uuid, p_quantity int)
returns table(purchase_id uuid, amount_cents int, currency char(3))
language plpgsql security definer set search_path = public as $$
declare v_member uuid; prod products%rowtype; v_order uuid; v_id uuid; v_amount int;
begin
  select id into v_member from members where studio_id = p_studio_id and user_id = auth.uid();
  if v_member is null then
    raise exception 'you are not a member of that studio' using errcode = 'PT403';
  end if;
  if not exists (select 1 from studio_payment_providers where studio_id = p_studio_id and provider = 'xendit') then
    raise exception 'this studio is not set up to take online payments' using errcode = 'PT409';
  end if;

  -- Lock the product so two concurrent begins cannot both pass the stock check.
  select * into prod from products
   where id = p_product_id and studio_id = p_studio_id for update;
  if prod.id is null then
    raise exception 'that product is not on sale' using errcode = 'PT404';
  end if;
  if prod.status <> 'active' then
    raise exception 'That product is no longer on sale.' using errcode = 'PT409';
  end if;
  if p_quantity is null or p_quantity < 1 then
    raise exception 'how many?' using errcode = 'PT400';
  end if;
  -- Stock is reserved below, so the check is against what is actually left
  -- (reservations have already decremented prod.stock).
  if prod.track_stock and prod.stock < p_quantity then
    raise exception 'Only % left.', prod.stock using errcode = 'PT409';
  end if;

  v_amount := prod.price_cents * p_quantity;

  -- Reserve: a pending order + a stock hold. The order is 'reserved' (not
  -- 'pending') so the desk can tell a held checkout from a paid one.
  insert into product_orders (studio_id, product_id, member_id, quantity, unit_price_cents,
                              currency, status, channel, created_by)
  values (p_studio_id, p_product_id, v_member, p_quantity, prod.price_cents,
          prod.currency, 'reserved', 'app', auth.uid())
  returning id into v_order;

  if prod.track_stock then
    update products set stock = stock - p_quantity where id = p_product_id;
    insert into stock_movements (studio_id, product_id, delta, reason, order_id, created_by)
    values (p_studio_id, p_product_id, -p_quantity, 'reserve', v_order, auth.uid());
  end if;

  insert into xendit_purchases (studio_id, member_id, product_order_id, amount_cents, currency)
  values (p_studio_id, v_member, v_order, v_amount, prod.currency)
  returning id into v_id;

  return query select v_id, v_amount, prod.currency;
end $$;

revoke execute on function xendit_begin_product_purchase(uuid, uuid, integer) from public, anon;
grant  execute on function xendit_begin_product_purchase(uuid, uuid, integer) to authenticated, service_role;

-- =============================================================================
-- 4. xendit_activate_success_internal — re-issued from 20260831820000 with the
--    product branch. Byte-identical for a plan; the status guard, expired-
--    override audit and the final status flip are SHARED across both targets.
-- =============================================================================
create or replace function xendit_activate_success_internal(p_purchase_id uuid, p_payment_id text)
returns text
language plpgsql security definer set search_path = public as $$
declare p xendit_purchases%rowtype; v_ms uuid; v_prior text;
        o product_orders%rowtype; prod products%rowtype;
begin
  select * into p from xendit_purchases where id = p_purchase_id for update;
  if p.id is null then return 'unknown_purchase'; end if;
  if p.status = 'succeeded' then return 'already_succeeded'; end if;
  v_prior := p.status;

  if p.product_order_id is not null then
    -- A product purchase: mark the order paid, record the sale (the stock was
    -- decremented at reserve, so release the hold then record the sale — net
    -- zero to products.stock, the ledger balanced), a payments row tagged with
    -- the order (never a membership), and the "ready to collect" email. NEVER
    -- activate_purchase — a product touches no membership, credit or booking.
    select * into o from product_orders where id = p.product_order_id for update;
    select * into prod from products where id = o.product_id for update;

    update product_orders set status = 'paid' where id = o.id and status in ('reserved', 'pending');

    if prod.track_stock then
      update products set stock = stock + o.quantity where id = prod.id;
      insert into stock_movements (studio_id, product_id, delta, reason, order_id)
      values (p.studio_id, prod.id, o.quantity, 'release', o.id);
      update products set stock = stock - o.quantity where id = prod.id;
      insert into stock_movements (studio_id, product_id, delta, reason, order_id)
      values (p.studio_id, prod.id, -o.quantity, 'sale', o.id);
    end if;

    insert into payments (studio_id, member_id, product_order_id, amount_cents, currency,
                          status, provider, reference, description, paid_at)
    values (p.studio_id, p.member_id, o.id, p.amount_cents, p.currency, 'succeeded', 'xendit',
            nullif(p_payment_id, ''), prod.name || ' ×' || o.quantity, now());

    perform queue_notification(
      p.studio_id, p.member_id, 'product_order_paid',
      jsonb_build_object('product', prod.name, 'quantity', o.quantity),
      'product_order_paid:' || o.id::text);

  else
    -- A plan purchase: unchanged from 20260831820000.
    v_ms := activate_purchase(p.studio_id, p.member_id, p.plan_id, p.amount_cents, p.currency,
                              null, null, false);

    insert into payments (studio_id, member_id, membership_id, amount_cents, currency,
                          status, provider, reference, description, paid_at)
    select p.studio_id, p.member_id, v_ms, p.amount_cents, p.currency, 'succeeded', 'xendit',
           nullif(p_payment_id, ''), mp.name, now()
      from membership_plans mp where mp.id = p.plan_id;
  end if;

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

-- =============================================================================
-- 5. xendit_fail_purchase_internal — re-issued from 20260831810000 with the
--    product branch: release the reservation (stock back + a 'release' movement)
--    and cancel the order, idempotently (only if still held). Byte-identical for
--    a plan. The status/pending guards are SHARED.
-- =============================================================================
create or replace function xendit_fail_purchase_internal(p_purchase_id uuid, p_status text, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare p xendit_purchases%rowtype; o product_orders%rowtype; prod products%rowtype; n int;
begin
  select * into p from xendit_purchases where id = p_purchase_id for update;
  if p.id is null or p.status in ('succeeded') then return; end if;

  update xendit_purchases
     set status = p_status, failure_reason = p_reason, completed_at = now(), updated_at = now()
   where id = p_purchase_id and status = 'pending';

  if p.product_order_id is not null then
    -- Release the reservation exactly once (guard on the order still being held),
    -- so a second failure/expiry cannot add the stock back twice.
    select * into o from product_orders where id = p.product_order_id for update;
    update product_orders set status = 'cancelled'
     where id = p.product_order_id and status in ('reserved', 'pending');
    get diagnostics n = row_count;
    if n = 1 then
      select * into prod from products where id = o.product_id for update;
      if prod.track_stock then
        update products set stock = stock + o.quantity where id = prod.id;
        insert into stock_movements (studio_id, product_id, delta, reason, order_id)
        values (p.studio_id, prod.id, o.quantity, 'release', o.id);
      end if;
    end if;
    perform queue_notification(
      p.studio_id, p.member_id, 'xendit_purchase_failed',
      jsonb_build_object('plan_name', (select name from products where id = o.product_id)),
      'xendit_failed:' || p_purchase_id::text);
  else
    perform queue_notification(
      p.studio_id, p.member_id, 'xendit_purchase_failed',
      jsonb_build_object('plan_name', (select name from membership_plans where id = p.plan_id)),
      'xendit_failed:' || p_purchase_id::text);
  end if;
end $$;

revoke execute on function xendit_fail_purchase_internal(uuid, text, text) from public, anon, authenticated;
grant  execute on function xendit_fail_purchase_internal(uuid, text, text) to service_role;

-- =============================================================================
-- Anon surface stays EXACTLY THIRTEEN — a merch purchase rides the existing
-- xendit_webhook; nothing added here is anon.
-- =============================================================================
do $$
declare v_n int;
begin
  select count(*) into v_n from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
   where nsp.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if v_n <> 13 then raise exception 'anon surface is % functions, expected 13', v_n; end if;
end $$;
