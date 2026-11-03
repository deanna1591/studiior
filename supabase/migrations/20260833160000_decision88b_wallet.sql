-- Decision 88 slice B (wallet): the member's /payments screen in one read.
-- creates: member_wallet(uuid)
--
-- /payments has four tabs — Unpaid (an online checkout started and never
-- completed), Paid (a succeeded payment), Refunded (a payment with a refund
-- recorded), Pay at the desk (an unpaid desk drop-in still owed). Those are
-- THREE different tables (payments, xendit_purchases, bookings) with the item
-- name resolved across plan / product / class / group, so one member-guarded
-- reader serves the screen in a single call rather than three fragile client
-- joins — and the receipt route reads the same resolved rows. The Paid/Refunded
-- split and the four-tab bucketing are done in TS (lib/wallet.mjs, node-tested)
-- over these flat rows. /purchases reads memberships directly under RLS and
-- needs no RPC. Not anon; anon stays THIRTEEN.

create or replace function member_wallet(p_studio_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $$
declare
  v_member   members%rowtype;
  v_dropin   int;
  v_ccy      text;
  v_payments jsonb;
  v_online   jsonb;
  v_desk     jsonb;
begin
  select * into v_member from members
   where user_id = auth.uid() and studio_id = p_studio_id and deleted_at is null;
  if not found then
    raise exception 'not a member of this studio' using errcode = 'PT403';
  end if;

  select currency into v_ccy from studios where id = p_studio_id;

  -- What an unpaid desk seat still owes: the live public drop-in price
  -- (the same figure member_activity resolves for an unpaid drop-in).
  select price_cents into v_dropin
    from membership_plans
   where studio_id = p_studio_id and type = 'drop_in'
     and visibility = 'public' and status = 'active'
   order by price_cents asc
   limit 1;

  -- Paid and Refunded live here: a succeeded payment, or any payment carrying a
  -- refund. A failed payments row is not a payment the member made, so it is not
  -- shown; the Unpaid tab is the online-checkout list below.
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id,
      'amount_cents', p.amount_cents,
      'currency', p.currency,
      'status', p.status::text,
      'refunded_cents', coalesce(p.refunded_cents, 0),
      'refunded_at', p.refunded_at,
      'provider', p.provider::text,
      'method', p.method,
      'card_brand', p.card_brand,
      'card_last4', p.card_last4,
      'at', coalesce(p.paid_at, p.created_at),
      'item', coalesce(mp.name, prod.name, coalesce(occ.name, ct.name), gpl.name,
                       nullif(p.description, ''), 'Payment')
    ) order by coalesce(p.paid_at, p.created_at) desc), '[]'::jsonb)
  into v_payments
    from payments p
    left join memberships ms       on ms.id   = p.membership_id
    left join membership_plans mp  on mp.id   = ms.plan_id
    left join product_orders po    on po.id   = p.product_order_id
    left join products prod        on prod.id = po.product_id
    left join bookings b           on b.id    = p.booking_id
    left join class_occurrences occ on occ.id = b.occurrence_id
    left join class_types ct       on ct.id   = occ.class_type_id
    left join group_purchases gp   on gp.id   = p.group_purchase_id
    left join membership_plans gpl on gpl.id  = gp.plan_id
   where p.member_id = v_member.id
     and (p.status = 'succeeded' or coalesce(p.refunded_cents, 0) > 0);

  -- Unpaid: an online checkout started and never completed (Xendit session open
  -- or failed). A succeeded purchase became a payment above, so it is excluded.
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', xp.id,
      'amount_cents', xp.amount_cents,
      'currency', xp.currency,
      'status', xp.status,
      'at', xp.created_at,
      'item', coalesce(mp.name, prod.name, 'Payment')
    ) order by xp.created_at desc), '[]'::jsonb)
  into v_online
    from xendit_purchases xp
    left join membership_plans mp on mp.id   = xp.plan_id
    left join product_orders po   on po.id   = xp.product_order_id
    left join products prod       on prod.id = po.product_id
   where xp.member_id = v_member.id
     and xp.status is distinct from 'succeeded';

  -- Pay at the desk: a future drop-in seat held but not yet paid (Decision 73a).
  select coalesce(jsonb_agg(jsonb_build_object(
      'booking_id', b.id,
      'occurrence_id', occ.id,
      'item', coalesce(occ.name, ct.name),
      'starts_at', occ.starts_at,
      'due_cents', v_dropin,
      'currency', v_ccy
    ) order by occ.starts_at asc), '[]'::jsonb)
  into v_desk
    from bookings b
    join class_occurrences occ on occ.id = b.occurrence_id
    left join class_types ct   on ct.id  = occ.class_type_id
   where b.member_id = v_member.id
     and b.payment_source = 'drop_in'
     and b.status in ('booked', 'pending_payment')
     and occ.starts_at > now()
     and not exists (
       select 1 from payments pay
        where pay.booking_id = b.id
          and pay.status in ('succeeded', 'partially_refunded'));

  return jsonb_build_object('payments', v_payments, 'online', v_online, 'desk', v_desk);
end $$;

revoke execute on function member_wallet(uuid) from public, anon;
grant execute on function member_wallet(uuid) to authenticated, service_role;

-- No new anon surface — EXACTLY THIRTEEN (asserted at apply).
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is %, expected 13', n; end if;
end $$;
