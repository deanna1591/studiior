-- Decision 88 (c): My purchases, and a BIR service invoice.
-- creates: assign_invoice_no_run(uuid), assign_invoice_no(uuid), tg_assign_invoice_no(), studio_invoice_details(uuid)
-- re-issues: member_wallet(uuid)
--
-- A Philippine studio that fills Settings → Studio → Invoice details issues a
-- BIR Service Invoice instead of the plain receipt. Invoice numbers are per
-- studio, sequential, assigned the moment a payment succeeds (online or desk),
-- and stored on the payment. The number is assigned by ONE trigger on payments
-- (status → succeeded), because a payment succeeds from more places than anybody
-- will remember — the Xendit success path, record_manual_payment, the two
-- instructor-desk paths — exactly the status-transition trigger the codebase
-- uses for tg_record_class_pay / tg_desk_pay_block. The trigger calls the
-- service-only _run twin; the guarded assign_invoice_no(payment) wrapper lets
-- the member's own invoice route number a pre-existing (pre-trigger) payment on
-- first download, idempotently. No new anon RPC — anon stays THIRTEEN.

-- ---------------------------------------------------------------- schema
alter table studio_settings
  add column if not exists invoice_registered_name text,
  add column if not exists invoice_proprietor       text,
  add column if not exists invoice_tin              text,
  add column if not exists invoice_address          text,
  add column if not exists invoice_email            text,
  add column if not exists invoice_landline         text,
  add column if not exists invoice_mobile           text,
  add column if not exists invoice_atp_no           text,
  add column if not exists invoice_atp_date         text,
  add column if not exists invoice_series           text,
  add column if not exists invoice_vat_rate         numeric(5,2) not null default 12,
  add column if not exists invoice_next_no          bigint not null default 1;

alter table studio_settings
  add constraint invoice_vat_rate_ck check (invoice_vat_rate >= 0 and invoice_vat_rate <= 100) not valid;

alter table payments
  add column if not exists invoice_no  text,
  add column if not exists received_by text;

-- One invoice number per studio (nulls — unnumbered payments — are unconstrained).
create unique index if not exists payments_studio_invoice_no_uq
  on payments (studio_id, invoice_no) where invoice_no is not null;

-- ---------------------------------------------------------------- numbering
-- Service-only twin: the number logic, no caller guard. Locks the payment row
-- (same-payment concurrent calls serialize, so no number is ever burned) and
-- then the studio_settings counter row (different payments succeeding at once
-- get consecutive numbers, no gaps). received_by (who took a desk payment) is
-- derived once from recorded_by; an online payment has no recorder, so it stays
-- null and prints blank on the invoice.
create or replace function assign_invoice_no_run(p_payment_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $$
declare
  v_studio   uuid;
  v_status   text;
  v_refunded int;
  v_existing text;
  v_rec      uuid;
  v_recby    text;
  v_n        bigint;
  v_no       text;
begin
  select p.studio_id, p.status::text, coalesce(p.refunded_cents, 0), p.invoice_no, p.recorded_by, p.received_by
    into v_studio, v_status, v_refunded, v_existing, v_rec, v_recby
    from payments p where p.id = p_payment_id
    for update;
  if v_studio is null then return null; end if;              -- no such payment

  if v_recby is null and v_rec is not null then
    update payments
       set received_by = (select full_name from profiles where id = v_rec)
     where id = p_payment_id and received_by is null;
  end if;

  if v_existing is not null then return v_existing; end if;  -- idempotent
  -- a completed sale is numbered (and a refund of one keeps its number, so a
  -- payment that moved money qualifies even after it goes partially_refunded)
  if v_status <> 'succeeded' and v_refunded = 0 then return null; end if;

  update studio_settings
     set invoice_next_no = invoice_next_no + 1
   where studio_id = v_studio
   returning invoice_next_no - 1 into v_n;
  if v_n is null then return null; end if;                   -- no settings row

  v_no := 'No. ' || lpad(v_n::text, 7, '0');
  update payments set invoice_no = v_no where id = p_payment_id and invoice_no is null;
  select invoice_no into v_no from payments where id = p_payment_id;  -- a concurrent winner, if any
  return v_no;
end $$;

revoke execute on function assign_invoice_no_run(uuid) from public, anon, authenticated;
grant execute on function assign_invoice_no_run(uuid) to service_role;

-- Guarded wrapper: the member numbering their own succeeded payment on first
-- invoice download, or a desk staff / a job. The number is the studio's to
-- assign, so it is readable-and-assignable by the payment's own member, by
-- desk-up staff of its studio, or in service context — never another member.
create or replace function assign_invoice_no(p_payment_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $$
declare v_studio uuid; v_member uuid;
begin
  select p.studio_id, p.member_id into v_studio, v_member
    from payments p where p.id = p_payment_id;
  if v_studio is null then return null; end if;
  if not (
       is_service_context()
    or coalesce(is_desk_up(v_studio), false)
    or exists (select 1 from members m where m.id = v_member and m.user_id = auth.uid())
  ) then
    raise exception 'that is not your payment' using errcode = 'PT403';
  end if;
  return assign_invoice_no_run(p_payment_id);
end $$;

revoke execute on function assign_invoice_no(uuid) from public, anon;
grant execute on function assign_invoice_no(uuid) to authenticated, service_role;

-- The one place a succeeded payment is numbered, from every success path.
create or replace function tg_assign_invoice_no()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $$
begin
  if new.status = 'succeeded' and not coalesce(new.is_demo, false) then
    perform assign_invoice_no_run(new.id);
  end if;
  return null;
end $$;

revoke execute on function tg_assign_invoice_no() from public, anon, authenticated;

drop trigger if exists payments_assign_invoice_no on payments;
create trigger payments_assign_invoice_no
  after insert or update of status on payments
  for each row execute function tg_assign_invoice_no();

-- ---------------------------------------------------------------- invoice details
-- A member cannot read studio_settings under RLS (member_bootstrap exists for
-- exactly this), so the invoice route reads the studio's invoice identity
-- through this definer. The details are printed on every invoice the studio
-- issues (its business identity), so exposing them to that studio's own members
-- is correct; a stranger gets nothing.
create or replace function studio_invoice_details(p_studio_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $$
begin
  if not (
       is_service_context()
    or coalesce(is_desk_up(p_studio_id), false)
    or exists (select 1 from members m where m.studio_id = p_studio_id and m.user_id = auth.uid())
  ) then
    raise exception 'not your studio' using errcode = 'PT403';
  end if;
  return (
    select jsonb_build_object(
      'invoice_registered_name', invoice_registered_name,
      'invoice_proprietor', invoice_proprietor,
      'invoice_tin', invoice_tin,
      'invoice_address', invoice_address,
      'invoice_email', invoice_email,
      'invoice_landline', invoice_landline,
      'invoice_mobile', invoice_mobile,
      'invoice_atp_no', invoice_atp_no,
      'invoice_atp_date', invoice_atp_date,
      'invoice_series', invoice_series,
      'invoice_vat_rate', invoice_vat_rate)
    from studio_settings where studio_id = p_studio_id
  );
end $$;

revoke execute on function studio_invoice_details(uuid) from public, anon;
grant execute on function studio_invoice_details(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------- member_wallet
-- Re-issued from 20260833160000 (slice B) byte-for-byte, with invoice_no and
-- received_by added to each paid/refunded row so /purchases and the invoice
-- route read them in the one call.
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

  select price_cents into v_dropin
    from membership_plans
   where studio_id = p_studio_id and type = 'drop_in'
     and visibility = 'public' and status = 'active'
   order by price_cents asc
   limit 1;

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
      'invoice_no', p.invoice_no,
      'received_by', p.received_by,
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
