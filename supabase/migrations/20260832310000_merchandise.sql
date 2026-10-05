-- Decision 63a — merchandise: inventory, desk sales, member listing.
--
-- creates: record_product_sale(uuid, uuid, integer, uuid, text, text, text),
--   adjust_stock(uuid, integer, text, text), mark_order_collected(uuid),
--   product_low_stock(uuid), member_shop(uuid), member_orders()
-- re-issues: dashboard_source_label(text), dashboard_revenue(uuid, date, date),
--   sales_history(uuid, date, date, uuid, text),
--   sales_totals(uuid, date, date, uuid, text),
--   record_refund(uuid, integer, text, boolean)
--
-- A studio sells things that are not classes. A merchandise payment is an
-- ordinary `payments` row tagged by a nullable `product_order_id` FK — a payment
-- points at what it paid for, exactly as membership_id/booking_id do — so the
-- revenue readers reach the 'merch' category the same way they reach the others.
-- Desk sales only in 63a; the in-app Xendit purchase is 63b. Inert by default:
-- no products → no Shop anywhere. No new anon surface (no new anon RPC).

-- =============================================================================
-- Schema.
-- =============================================================================
create table products (
  id                  uuid primary key default gen_random_uuid(),
  studio_id           uuid not null references studios on delete cascade,
  name                text not null,
  description         text,
  photo_url           text,
  price_cents         int not null check (price_cents >= 0),
  currency            char(3) not null,
  track_stock         boolean not null default true,
  stock               int not null default 0,
  low_stock_threshold int,                       -- null = no low-stock alert
  status              text not null default 'active' check (status in ('active','archived')),
  sort_order          int not null default 0,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index on products (studio_id, status, sort_order);
create trigger products_updated before update on products
  for each row execute function set_updated_at();

create table product_orders (
  id               uuid primary key default gen_random_uuid(),
  studio_id        uuid not null references studios on delete cascade,
  product_id       uuid not null references products on delete restrict,
  member_id        uuid references members on delete set null,
  quantity         int not null check (quantity > 0),
  unit_price_cents int not null,
  currency         char(3) not null,
  status           text not null default 'pending'
                     check (status in ('pending','reserved','paid','collected','cancelled','refunded')),
  channel          text not null check (channel in ('desk','app')),
  created_by       uuid references profiles on delete set null,
  collected_at     timestamptz,
  collected_by     uuid references profiles on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index on product_orders (studio_id, status, created_at desc);
create index on product_orders (member_id, created_at desc);
create trigger product_orders_updated before update on product_orders
  for each row execute function set_updated_at();

-- The stock ledger. Every stock change is a row here; products.stock is the
-- running cache, written only in the same transaction as a movement.
create table stock_movements (
  id         uuid primary key default gen_random_uuid(),
  studio_id  uuid not null references studios on delete cascade,
  product_id uuid not null references products on delete cascade,
  delta      int not null,
  reason     text not null
               check (reason in ('sale','restock','adjust','refund_restock','reserve','release')),
  order_id   uuid references product_orders on delete set null,
  note       text,
  created_by uuid references profiles on delete set null,
  created_at timestamptz not null default now()
);
create index on stock_movements (studio_id, product_id, created_at desc);

-- A payment points at what it paid for, like membership_id / booking_id.
alter table payments add column product_order_id uuid references product_orders on delete set null;

-- =============================================================================
-- RLS. Products: desk-up read, manager-up write. Orders: desk-up within studio
-- (members read their own via member_orders, a definer reader). Movements:
-- desk-up read; written only by the definer functions below.
-- =============================================================================
alter table products        enable row level security;
alter table product_orders  enable row level security;
alter table stock_movements enable row level security;

grant select, insert, update, delete on products       to authenticated;
grant select, insert, update, delete on product_orders to authenticated;
grant select on stock_movements to authenticated;

create policy products_desk_read on products for select
  using (is_desk_up(studio_id));
create policy products_manager_insert on products for insert
  with check (is_manager_up(studio_id));
create policy products_manager_update on products for update
  using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));
create policy products_manager_delete on products for delete
  using (is_manager_up(studio_id));

create policy orders_desk_all on product_orders for all
  using (is_desk_up(studio_id)) with check (is_desk_up(studio_id));

create policy movements_desk_read on stock_movements for select
  using (is_desk_up(studio_id));

-- =============================================================================
-- record_product_sale — desk sale: one order (collected), stock down, a payments
-- row, a sale movement. Desk-up.
-- =============================================================================
create function record_product_sale(
  p_studio_id uuid, p_product_id uuid, p_quantity int,
  p_member_id uuid default null, p_method text default 'cash',
  p_method_note text default null, p_reference text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare prod products%rowtype; v_order uuid; v_payment uuid; v_amount int;
begin
  if not is_desk_up(p_studio_id) then
    raise exception 'only staff can record a sale' using errcode = 'PT403';
  end if;
  if studio_is_locked(p_studio_id) then
    raise exception 'this studio''s Studiior subscription is not active'
      using errcode = 'PT402', hint = 'Reactivate it from Billing. Nothing has been deleted.';
  end if;
  select * into prod from products where id = p_product_id and studio_id = p_studio_id for update;
  if not found then raise exception 'no such product' using errcode = 'PT404'; end if;
  if prod.status <> 'active' then
    raise exception 'That product is archived.' using errcode = 'PT409';
  end if;
  if p_quantity is null or p_quantity < 1 then
    raise exception 'how many?' using errcode = 'PT400';
  end if;
  if prod.track_stock and prod.stock < p_quantity then
    raise exception 'Only % left.', prod.stock using errcode = 'PT409';
  end if;
  if p_member_id is not null and not exists (
       select 1 from members where id = p_member_id and studio_id = p_studio_id) then
    raise exception 'that member does not belong to this studio' using errcode = 'PT403';
  end if;

  v_amount := prod.price_cents * p_quantity;

  insert into product_orders (studio_id, product_id, member_id, quantity, unit_price_cents,
                              currency, status, channel, created_by, collected_at, collected_by)
  values (p_studio_id, p_product_id, p_member_id, p_quantity, prod.price_cents,
          prod.currency, 'collected', 'desk', auth.uid(), now(), auth.uid())
  returning id into v_order;

  -- Stock down (tracked only), with a ledger row.
  if prod.track_stock then
    update products set stock = stock - p_quantity where id = p_product_id;
    insert into stock_movements (studio_id, product_id, delta, reason, order_id, created_by)
    values (p_studio_id, p_product_id, -p_quantity, 'sale', v_order, auth.uid());
  end if;

  -- The money: an ordinary payments row, provider 'manual' + the method, tagged
  -- with the order it paid for.
  insert into payments (studio_id, member_id, product_order_id, amount_cents, currency,
                        status, description, provider, method, method_note, reference,
                        recorded_by, paid_at)
  values (p_studio_id, p_member_id, v_order, v_amount, prod.currency, 'succeeded',
          prod.name || ' ×' || p_quantity, 'manual', p_method,
          nullif(btrim(coalesce(p_method_note,'')), ''), nullif(btrim(coalesce(p_reference,'')), ''),
          auth.uid(), now())
  returning id into v_payment;

  return jsonb_build_object('ok', true, 'order_id', v_order, 'payment_id', v_payment,
                            'amount_cents', v_amount);
end $$;
revoke execute on function record_product_sale(uuid, uuid, integer, uuid, text, text, text) from public, anon;
grant  execute on function record_product_sale(uuid, uuid, integer, uuid, text, text, text) to authenticated, service_role;

-- =============================================================================
-- adjust_stock — restock / adjust, manager-up (it edits inventory).
-- =============================================================================
create function adjust_stock(p_product_id uuid, p_delta int, p_reason text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare prod products%rowtype;
begin
  select * into prod from products where id = p_product_id for update;
  if not found then raise exception 'no such product' using errcode = 'PT404'; end if;
  if not is_manager_up(prod.studio_id) then
    raise exception 'only an owner or a manager can adjust stock' using errcode = 'PT403';
  end if;
  if p_reason not in ('restock','adjust') then
    raise exception 'unknown stock reason' using errcode = 'PT400';
  end if;
  if not prod.track_stock then
    raise exception 'This product does not track stock.' using errcode = 'PT409';
  end if;
  if coalesce(p_delta,0) = 0 then
    raise exception 'nothing to change' using errcode = 'PT400';
  end if;
  if prod.stock + p_delta < 0 then
    raise exception 'That would take stock below zero.' using errcode = 'PT409';
  end if;
  update products set stock = stock + p_delta where id = p_product_id;
  insert into stock_movements (studio_id, product_id, delta, reason, note, created_by)
  values (prod.studio_id, p_product_id, p_delta, p_reason, nullif(btrim(coalesce(p_note,'')), ''), auth.uid());
  return jsonb_build_object('ok', true, 'stock', prod.stock + p_delta);
end $$;
revoke execute on function adjust_stock(uuid, integer, text, text) from public, anon;
grant  execute on function adjust_stock(uuid, integer, text, text) to authenticated, service_role;

-- =============================================================================
-- mark_order_collected — a paid (in-app) order handed over. Desk-up.
-- =============================================================================
create function mark_order_collected(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o product_orders%rowtype;
begin
  select * into o from product_orders where id = p_order_id for update;
  if not found then raise exception 'no such order' using errcode = 'PT404'; end if;
  if not is_desk_up(o.studio_id) then
    raise exception 'only staff can mark an order collected' using errcode = 'PT403';
  end if;
  if o.status <> 'paid' then
    raise exception 'That order is not ready to collect.' using errcode = 'PT409';
  end if;
  update product_orders set status = 'collected', collected_at = now(), collected_by = auth.uid()
   where id = p_order_id;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function mark_order_collected(uuid) from public, anon;
grant  execute on function mark_order_collected(uuid) to authenticated, service_role;

-- =============================================================================
-- product_low_stock — the dashboard line. Desk-up.
-- =============================================================================
create function product_low_stock(p_studio_id uuid)
returns table (product_id uuid, name text, stock int, threshold int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (is_desk_up(p_studio_id) or is_service_context()) then
    raise exception 'that is another studio''s stock' using errcode = 'PT403';
  end if;
  return query
    select p.id, p.name, p.stock, p.low_stock_threshold
      from products p
     where p.studio_id = p_studio_id and p.status = 'active'
       and p.track_stock and p.low_stock_threshold is not null
       and p.stock <= p.low_stock_threshold
     order by p.stock, p.name;
end $$;
revoke execute on function product_low_stock(uuid) from public, anon;
grant  execute on function product_low_stock(uuid) to authenticated, service_role;

-- =============================================================================
-- member_shop — active products for the member app. Member (or staff/service).
-- =============================================================================
create function member_shop(p_studio_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not (is_desk_up(p_studio_id) or is_service_context()
          or exists (select 1 from members m where m.studio_id = p_studio_id and m.user_id = auth.uid())) then
    raise exception 'that is another studio''s shop' using errcode = 'PT403';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', p.id, 'name', p.name, 'description', p.description,
             'photo_url', p.photo_url, 'price_cents', p.price_cents, 'currency', p.currency,
             -- stock_left is null when the product does not track stock (never
             -- blocks); sold_out is true only for a tracked product at zero.
             'stock_left', case when p.track_stock then p.stock else null end,
             'sold_out', case when p.track_stock then p.stock <= 0 else false end)
             order by p.sort_order, p.name)
      from products p
     where p.studio_id = p_studio_id and p.status = 'active'
  ), '[]'::jsonb);
end $$;
revoke execute on function member_shop(uuid) from public, anon;
grant  execute on function member_shop(uuid) to authenticated, service_role;

-- =============================================================================
-- member_orders — the caller's own product orders. Self-scoped by auth.uid().
-- =============================================================================
create function member_orders()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', po.id, 'product_name', pr.name, 'quantity', po.quantity,
             'amount_cents', po.unit_price_cents * po.quantity, 'currency', po.currency,
             'status', po.status, 'created_at', po.created_at, 'collected_at', po.collected_at)
             order by po.created_at desc)
      from product_orders po
      join products pr on pr.id = po.product_id
      join members m on m.id = po.member_id
     where m.user_id = auth.uid()
       and po.status in ('paid','collected','refunded')
  ), '[]'::jsonb);
end $$;
revoke execute on function member_orders() from public, anon;
grant  execute on function member_orders() to authenticated, service_role;

-- =============================================================================
-- product-photos bucket — Decision 60's pattern (public read, manager-up write
-- of the path's studio). Files at {studio_id}/{product_id}/{timestamp}.{ext}.
-- A storage bucket is not an RPC, so the anon RPC surface stays THIRTEEN.
-- =============================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-photos', 'product-photos', true, 5242880,
        array['image/png','image/jpeg','image/webp'])
on conflict (id) do nothing;

drop policy if exists "product photos are publicly readable" on storage.objects;
create policy "product photos are publicly readable"
  on storage.objects for select using (bucket_id = 'product-photos');

drop policy if exists "managers write product photos" on storage.objects;
create policy "managers write product photos"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'product-photos'
              and is_manager_up((storage.foldername(name))[1]::uuid));

drop policy if exists "managers replace product photos" on storage.objects;
create policy "managers replace product photos"
  on storage.objects for update to authenticated
  using (bucket_id = 'product-photos'
         and is_manager_up((storage.foldername(name))[1]::uuid));

drop policy if exists "managers delete product photos" on storage.objects;
create policy "managers delete product photos"
  on storage.objects for delete to authenticated
  using (bucket_id = 'product-photos'
         and is_manager_up((storage.foldername(name))[1]::uuid));

-- =============================================================================
-- dashboard_source_label — add Merchandise.
-- =============================================================================
create or replace function dashboard_source_label(p_src text) returns text
language sql immutable as $$
  select case p_src
    when 'membership' then 'Memberships'
    when 'pack'       then 'Class packs'
    when 'drop_in'    then 'Drop-ins'
    when 'private'    then 'Private sessions'
    when 'trial'      then 'Trials'
    when 'merch'      then 'Merchandise'
    else 'Other' end
$$;

-- =============================================================================
-- dashboard_revenue — by_source gains a 'merch' branch (checked FIRST, since a
-- payment with a product_order_id paid for merchandise and nothing else).
-- Re-issued from 20260832240000 with that one CASE line added.
-- =============================================================================
create or replace function dashboard_revenue(
  p_studio_id uuid, p_from date, p_to date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tz text; v_currency char(3); v_today date;
  v_f0 timestamptz; v_t1 timestamptz;
  v_span int; v_pf0 timestamptz; v_pt1 timestamptz;
  v_total bigint; v_prior bigint; v_refunds bigint; v_ever bigint;
  v_series jsonb; v_sources jsonb; v_counts jsonb;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'revenue is for owners and managers' using errcode = 'PT403';
  end if;
  select s.timezone, s.currency into v_tz, v_currency from studios s where s.id = p_studio_id;
  if v_tz is null then raise exception 'no such studio' using errcode = 'PT404'; end if;
  if p_to < p_from then
    raise exception 'the range ends before it starts' using errcode = 'PT422';
  end if;

  v_today := studio_today(p_studio_id);
  select day_start into v_f0 from studio_day_bounds(p_studio_id, p_from);
  select day_start into v_t1 from studio_day_bounds(p_studio_id, p_to + 1);
  v_span := (p_to - p_from) + 1;
  select day_start into v_pf0 from studio_day_bounds(p_studio_id, p_from - v_span);
  select day_start into v_pt1 from studio_day_bounds(p_studio_id, p_from);

  v_total := studio_revenue_between(p_studio_id, v_f0, v_t1);
  v_prior := studio_revenue_between(p_studio_id, v_pf0, v_pt1);
  select coalesce(sum(p.amount_cents),0)::bigint into v_ever from payments p
   where p.studio_id = p_studio_id and p.status in ('succeeded','partially_refunded');

  select coalesce(sum(r.amount_cents),0)::bigint into v_refunds
    from refunds r join payments p on p.id = r.payment_id
   where p.studio_id = p_studio_id
     and r.created_at >= v_f0 and r.created_at < v_t1;

  select coalesce(jsonb_agg(jsonb_build_object('date', d.day, 'cents', coalesce(x.cents,0))
                            order by d.day), '[]'::jsonb)
    into v_series
    from generate_series(p_from, p_to, interval '1 day') g(day_ts)
    cross join lateral (select g.day_ts::date as day) d
    left join lateral (
      select coalesce(sum(p.amount_cents),0)::bigint as cents
        from payments p
       where p.studio_id = p_studio_id and p.status in ('succeeded','partially_refunded')
         and (coalesce(p.paid_at, p.created_at) at time zone v_tz)::date = d.day
    ) x on true;

  with classified as (
    select p.amount_cents,
           case
             when p.product_order_id is not null then 'merch'
             when ct.session_kind in ('private','duo','trio') then 'private'
             when pl.type = 'recurring'  then 'membership'
             when pl.type = 'class_pack' then 'pack'
             when pl.type = 'trial'      then 'trial'
             when b.payment_source = 'drop_in' then 'drop_in'
             when pl.type = 'drop_in'    then 'drop_in'
             else 'other'
           end as src
      from payments p
      left join memberships ms on ms.id = p.membership_id
      left join membership_plans pl on pl.id = ms.plan_id
      left join bookings b on b.id = p.booking_id
      left join class_occurrences o on o.id = b.occurrence_id
      left join class_types ct on ct.id = o.class_type_id
     where p.studio_id = p_studio_id and p.status in ('succeeded','partially_refunded')
       and coalesce(p.paid_at, p.created_at) >= v_f0
       and coalesce(p.paid_at, p.created_at) <  v_t1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'source', src, 'label', dashboard_source_label(src), 'cents', cents,
           'pct', case when v_total = 0 then 0 else round(100.0 * cents / v_total) end)
           order by cents desc), '[]'::jsonb)
    into v_sources
    from (select src, sum(amount_cents)::bigint as cents from classified group by src) s;

  select jsonb_build_object(
      'bookings', (select count(*) from bookings b
                    where b.studio_id = p_studio_id and b.status <> 'waitlisted'
                      and b.booked_at >= v_f0 and b.booked_at < v_t1),
      'memberships_sold', (select count(*) from memberships ms
                    where ms.studio_id = p_studio_id
                      and ms.created_at >= v_f0 and ms.created_at < v_t1
                      and not coalesce(ms.complimentary, false)),
      'refunds_cents', v_refunds)
    into v_counts;

  return jsonb_build_object(
    'from', p_from, 'to', p_to, 'days', v_span, 'currency', v_currency,
    'state', case when v_ever = 0 then 'empty' else 'ok' end,
    'total_cents', v_total,
    'trend', dashboard_trend(v_total, v_prior, 'the ' || v_span || ' days before'),
    'series', v_series, 'by_source', v_sources, 'counts', v_counts,
    'empty_hint', 'Every payment you take shows up here — by day, and split by what it was for. Record a payment at the desk or connect Stripe and this starts filling.');
end $$;

-- =============================================================================
-- sales_history — UNION merchandise rows (plan_type 'merch', the product name).
-- The membership half is byte-for-byte 20260832240000; a plan filter excludes
-- merch (it has no plan). Re-issued from 20260832240000.
-- =============================================================================
create or replace function sales_history(
  p_studio_id uuid, p_from date, p_to date,
  p_plan_id uuid default null, p_status text default null
) returns table (
  membership_id uuid, member_id uuid, member_name text,
  plan_id uuid, plan_name text, plan_type text,
  amount_cents int, currency char(3), payment_source text,
  bought_on timestamptz, starts_on date, expires_on date, sale_status text
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare v_tz text; v_today date; v_f0 timestamptz; v_t1 timestamptz;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'sales are for owners and managers' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios s where s.id = p_studio_id;
  v_today := (now() at time zone v_tz)::date;
  select day_start into v_f0 from studio_day_bounds(p_studio_id, p_from);
  select day_start into v_t1 from studio_day_bounds(p_studio_id, p_to + 1);

  return query
  with pay as (
    select distinct on (p.membership_id)
           p.membership_id, p.amount_cents, p.currency, p.provider, p.method, p.status as pstatus,
           coalesce(p.paid_at, p.created_at) as paid_ts
      from payments p
     where p.studio_id = p_studio_id and p.membership_id is not null
     order by p.membership_id, coalesce(p.paid_at, p.created_at) desc
  )
  select ms.id, ms.member_id,
         (m.first_name || ' ' || m.last_name) as member_name,
         ms.plan_id, mp.name, mp.type::text,
         coalesce(pay.amount_cents, ms.price_cents) as amount_cents,
         ms.currency,
         coalesce(
           case when pay.provider = 'stripe' then 'Card (Stripe)'
                when pay.provider = 'xendit' then 'Card (Xendit)'
                when pay.method = 'gcash' then 'GCash'
                when pay.method = 'bank_transfer' then 'Bank transfer'
                when pay.method = 'card_terminal' then 'Card (terminal)'
                when pay.method = 'cash' then 'Cash'
                when pay.method = 'other' then 'Other'
                when pay.membership_id is not null then 'Recorded'
           end, 'Unpaid') as payment_source,
         coalesce(pay.paid_ts, ms.created_at) as bought_on,
         ms.starts_on, ms.expires_on,
         (case
            when pay.pstatus = 'refunded' then 'refunded'
            when ms.status = 'frozen' then 'frozen'
            when pay.membership_id is null or pay.pstatus = 'pending' then 'unpaid'
            when ms.status in ('cancelled', 'expired') then 'expired'
            when ms.expires_on is not null and ms.expires_on <= v_today + 14 then 'expiring'
            else 'active'
          end) as sale_status
    from memberships ms
    join members m on m.id = ms.member_id
    join membership_plans mp on mp.id = ms.plan_id
    left join pay on pay.membership_id = ms.id
   where ms.studio_id = p_studio_id
     and not coalesce(ms.complimentary, false)
     and coalesce(pay.paid_ts, ms.created_at) >= v_f0
     and coalesce(pay.paid_ts, ms.created_at) <  v_t1
     and (p_plan_id is null or ms.plan_id = p_plan_id)
     and (p_status  is null or p_status = (case
            when pay.pstatus = 'refunded' then 'refunded'
            when ms.status = 'frozen' then 'frozen'
            when pay.membership_id is null or pay.pstatus = 'pending' then 'unpaid'
            when ms.status in ('cancelled', 'expired') then 'expired'
            when ms.expires_on is not null and ms.expires_on <= v_today + 14 then 'expiring'
            else 'active' end))

  union all

  -- Decision 63: merchandise sales. plan_type 'merch', plan_name = the product
  -- (with the quantity); no membership, no plan, so a plan filter excludes them.
  select null::uuid, p.member_id,
         coalesce(m.first_name || ' ' || m.last_name, 'Walk-in') as member_name,
         null::uuid, (pr.name || ' ×' || po.quantity) as plan_name, 'merch' as plan_type,
         p.amount_cents, p.currency,
         (case when p.provider = 'xendit' then 'Card (Xendit)'
               when p.provider = 'stripe' then 'Card (Stripe)'
               when p.method = 'gcash' then 'GCash'
               when p.method = 'bank_transfer' then 'Bank transfer'
               when p.method = 'card_terminal' then 'Card (terminal)'
               when p.method = 'cash' then 'Cash'
               when p.method = 'other' then 'Other'
               else 'Recorded' end) as payment_source,
         coalesce(p.paid_at, p.created_at) as bought_on,
         null::date, null::date,
         (case when p.status in ('refunded','partially_refunded') or coalesce(p.refunded_cents,0) > 0
               then 'refunded' else 'active' end) as sale_status
    from payments p
    join product_orders po on po.id = p.product_order_id
    join products pr on pr.id = po.product_id
    left join members m on m.id = p.member_id
   where p.studio_id = p_studio_id and p.status in ('succeeded','partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1
     and p_plan_id is null
     and (p_status is null or p_status = (case
            when p.status in ('refunded','partially_refunded') or coalesce(p.refunded_cents,0) > 0
            then 'refunded' else 'active' end))

  order by bought_on desc;
end $$;

-- =============================================================================
-- sales_totals — gross/refunded include merch payments (not just membership
-- ones). Re-issued from 20260832150000; LEFT join + the product_order_id arm.
-- =============================================================================
create or replace function sales_totals(
  p_studio_id uuid, p_from date, p_to date,
  p_plan_id uuid default null, p_status text default null
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_currency char(3); v_count int; v_gross bigint; v_refunded bigint; v_studio_total bigint;
  v_f0 timestamptz; v_t1 timestamptz;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'sales are for owners and managers' using errcode = 'PT403';
  end if;
  select currency into v_currency from studios s where s.id = p_studio_id;
  select day_start into v_f0 from studio_day_bounds(p_studio_id, p_from);
  select day_start into v_t1 from studio_day_bounds(p_studio_id, p_to + 1);

  select count(*) into v_count
    from sales_history(p_studio_id, p_from, p_to, p_plan_id, p_status);

  -- Gross/refunded over the filtered set: membership sales (by plan filter) OR
  -- merchandise sales. A plan filter excludes merch (merch has no plan).
  select coalesce(sum(p.amount_cents), 0)::bigint,
         coalesce(sum(p.refunded_cents), 0)::bigint
    into v_gross, v_refunded
    from payments p
    left join memberships ms on ms.id = p.membership_id
   where p.studio_id = p_studio_id
     and p.status in ('succeeded', 'partially_refunded')
     and (p.membership_id is not null or p.product_order_id is not null)
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1
     and (p_plan_id is null or ms.plan_id = p_plan_id);

  v_studio_total := studio_revenue_between(p_studio_id, v_f0, v_t1);

  return jsonb_build_object(
    'count', v_count,
    'gross_cents', v_gross,
    'refunded_cents', v_refunded,
    'net_cents', v_gross - v_refunded,
    'studio_total_cents', v_studio_total,
    'currency', v_currency);
end $$;

-- =============================================================================
-- record_refund — gains a "put it back in stock" option. DROP the 3-arg and
-- recreate 4-arg (a defaulted 4th on top of the 3-arg is the 028 ambiguity
-- trap), so the existing 3-arg callers resolve to the 4-arg with p_restock
-- false. Re-issued from 20260830500000 with the merch restock branch added.
-- =============================================================================
drop function if exists record_refund(uuid, int, text);
create function record_refund(
  p_payment_id uuid, p_amount_cents int default null, p_reason text default null,
  p_restock boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  pay      payments%rowtype;
  plan     membership_plans%rowtype;
  ms       memberships%rowtype;
  o        product_orders%rowtype;
  prod     products%rowtype;
  v_amount int;
  v_total  int;
  v_full   boolean;
  v_bal    int;
  v_take   int := 0;
begin
  select * into pay from payments where id = p_payment_id for update;
  if not found then
    raise exception 'no such payment' using errcode = 'PT404';
  end if;
  if not is_manager_up(pay.studio_id) then
    raise exception 'refunds are the owner''s or a manager''s to make'
      using errcode = 'PT403';
  end if;
  if pay.status not in ('succeeded', 'partially_refunded') then
    raise exception 'a % payment cannot be refunded', pay.status using errcode = 'PT409';
  end if;

  v_amount := coalesce(p_amount_cents, pay.amount_cents - pay.refunded_cents);
  if v_amount <= 0 or v_amount > pay.amount_cents - pay.refunded_cents then
    raise exception 'that is more than is left to refund' using errcode = 'PT400';
  end if;

  v_total := pay.refunded_cents + v_amount;
  v_full  := v_total >= pay.amount_cents;

  update payments
     set refunded_cents = v_total,
         refunded_at = now(),
         refund_reason = coalesce(p_reason, refund_reason),
         status = (case when v_full then 'refunded' else 'partially_refunded' end)::payment_status,
         updated_at = now()
   where id = p_payment_id;

  if v_full and pay.membership_id is not null then
    select * into ms from memberships where id = pay.membership_id;
    select * into plan from membership_plans where id = ms.plan_id;

    if plan.type = 'class_pack' then
      select coalesce(sum(delta), 0) into v_bal
        from credit_ledger
       where studio_id = pay.studio_id and member_id = pay.member_id;

      v_take := least(coalesce(ms.credits_remaining, 0), greatest(v_bal, 0));
      if v_take > 0 then
        insert into credit_ledger (studio_id, member_id, membership_id, delta, reason,
                                   balance_after, actor_user_id)
        values (pay.studio_id, pay.member_id, ms.id, -v_take, 'manual',
                v_bal - v_take, auth.uid());
        update memberships set credits_remaining = coalesce(credits_remaining, 0) - v_take
         where id = ms.id;
      end if;
    end if;

    update memberships
       set status = 'cancelled', cancelled_at = now(),
           cancellation_reason = coalesce(p_reason, 'refunded')
     where id = ms.id and status <> 'cancelled';

    insert into membership_events (studio_id, membership_id, type, from_status,
                                   to_status, actor_user_id, metadata)
    values (pay.studio_id, ms.id, 'cancelled', ms.status, 'cancelled', auth.uid(),
            jsonb_build_object('reason', p_reason, 'payment_id', p_payment_id,
                               'credits_removed', v_take));
  end if;

  -- Decision 63: put merchandise back in stock when asked. The order is marked
  -- refunded; a tracked product gets a refund_restock movement and its count back.
  if p_restock and pay.product_order_id is not null then
    select * into o from product_orders where id = pay.product_order_id;
    if o.id is not null then
      select * into prod from products where id = o.product_id;
      if prod.track_stock then
        update products set stock = stock + o.quantity where id = o.product_id;
        insert into stock_movements (studio_id, product_id, delta, reason, order_id, created_by)
        values (o.studio_id, o.product_id, o.quantity, 'refund_restock', o.id, auth.uid());
      end if;
      update product_orders set status = 'refunded' where id = o.id;
    end if;
  end if;

  return jsonb_build_object('payment_id', p_payment_id, 'refunded_cents', v_total,
                            'full', v_full, 'credits_removed', v_take);
end $$;
revoke execute on function record_refund(uuid, int, text, boolean) from public, anon, authenticated;
grant  execute on function record_refund(uuid, int, text, boolean) to authenticated;

-- The anon surface is unchanged — exactly THIRTEEN pre-login functions.
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % functions, expected exactly 13', n; end if;
end $$;
