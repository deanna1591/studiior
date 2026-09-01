-- =============================================================================
-- Migration 040: Decision 16 — payments are recorded, not necessarily processed
-- =============================================================================
-- Migration 038 built payments Stripe-first: a membership was sold by a
-- Checkout session and a studio with no connected account could not take money
-- through the product at all. That is the wrong foundation. Studiior is a
-- booking platform; a studio takes money however it already takes money, and an
-- online card provider is an optional adapter on top.
--
-- The design partners span countries where coverage varies and Stripe does not
-- support the Philippines at all, so a Stripe-shaped product would exclude
-- studios whose only problem is booking — which is the problem we solve.
--
-- ONE PATH, NOT TWO. The thing that makes a manual payment "activate a
-- membership identically to a Stripe one" is not that two functions were
-- written to match: it is that both call activate_purchase() and
-- confirm_dropin_payment(), which are the only code that grants anything. A
-- second implementation would agree on the day it was written and drift after.
--
-- THE TRADEOFF, RECORDED. A manual payment is the studio's own bookkeeping.
-- They reconcile it; a membership can be marked paid when no money moved; and
-- nothing here tries to stop that. What the row owes them is who recorded it,
-- when, by what method and against what reference — enough to reconcile, not
-- enough to police.
-- =============================================================================

create type payment_provider as enum ('manual', 'stripe');

alter table payments
  add column if not exists provider payment_provider not null default 'manual',
  add column if not exists method text,
  add column if not exists method_note text,
  add column if not exists reference text,
  add column if not exists recorded_by uuid references profiles on delete set null;

-- Existing rows: anything carrying a Stripe id came from Stripe. Everything
-- else predates this and is demo or seed data, which is manual by definition.
update payments
   set provider = 'stripe'
 where stripe_payment_intent_id is not null
    or stripe_invoice_id is not null
    or stripe_charge_id is not null;

alter table payments drop constraint if exists payments_method_known;
alter table payments add constraint payments_method_known check (
  method is null
  or method in ('cash','bank_transfer','card_terminal','gcash','other')
);

comment on column payments.provider is
  'Who moved the money. ''manual'' is the foundation — cash, transfer, a '
  'terminal on the counter — and ''stripe'' is the optional online adapter. '
  'Revenue reporting separates them so a studio can reconcile.';
comment on column payments.method is
  'How a manual payment was taken. Free-text detail goes in method_note; the '
  'list exists so reporting can group, not to constrain how a studio works.';
comment on column payments.reference is
  'The studio''s own reference — a transfer number, a receipt, a terminal slip. '
  'Whatever they will look for when reconciling.';

-- -----------------------------------------------------------------------------
-- The shared grant. Called by BOTH the manual path and the Stripe webhook.
-- -----------------------------------------------------------------------------
create or replace function activate_purchase(
  p_studio_id uuid, p_member_id uuid, p_plan_id uuid,
  p_price_cents int, p_currency char(3),
  p_stripe_customer text default null, p_stripe_subscription text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare plan membership_plans%rowtype; v_ms uuid; v_bal int;
begin
  select * into plan from membership_plans
   where id = p_plan_id and studio_id = p_studio_id;
  if not found then
    raise exception 'no such plan for this studio' using errcode = 'PT404';
  end if;
  if not exists (select 1 from members where id = p_member_id and studio_id = p_studio_id) then
    raise exception 'that member does not belong to this studio' using errcode = 'PT403';
  end if;

  insert into memberships (
    studio_id, member_id, plan_id, status, price_cents, currency, starts_on,
    credits_remaining, expires_on, auto_renew, stripe_customer_id, stripe_subscription_id
  ) values (
    p_studio_id, p_member_id, plan.id,
    (case when plan.type = 'trial' then 'trialing' else 'active' end)::membership_status,
    -- §7.1: the price agreed at purchase, snapshotted. Never re-read from the
    -- plan afterwards, so editing a plan cannot reprice anybody already on it.
    coalesce(p_price_cents, plan.price_cents),
    coalesce(nullif(p_currency, ''), plan.currency),
    current_date,
    case when plan.type = 'class_pack' then plan.credits else plan.credits_per_period end,
    case when plan.type = 'class_pack' and plan.validity_days is not null
         then current_date + plan.validity_days end,
    plan.type = 'recurring',
    p_stripe_customer, nullif(p_stripe_subscription, '')
  ) returning id into v_ms;

  -- §6: a pack's classes arrive as ledger rows. credits_remaining above is a
  -- cache of this, written in the same transaction and never independently.
  if plan.type = 'class_pack' and coalesce(plan.credits, 0) > 0 then
    select coalesce(sum(delta), 0) into v_bal
      from credit_ledger where studio_id = p_studio_id and member_id = p_member_id;
    insert into credit_ledger (studio_id, member_id, membership_id, delta, reason,
                               balance_after, expires_at, actor_user_id)
    values (p_studio_id, p_member_id, v_ms, plan.credits, 'purchase',
            v_bal + plan.credits,
            case when plan.validity_days is not null
                 then (current_date + plan.validity_days + 1)::timestamptz end,
            auth.uid());
  end if;

  insert into membership_events (studio_id, membership_id, type, to_status, actor_user_id)
  values (p_studio_id, v_ms, 'created',
          (case when plan.type = 'trial' then 'trialing' else 'active' end)::membership_status,
          auth.uid());

  return v_ms;
end $$;

/** The other half: a held drop-in seat becomes a real booking. */
create or replace function confirm_dropin_payment(p_studio_id uuid, p_booking_id uuid)
returns boolean
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update bookings set status = 'booked'
   where id = p_booking_id and studio_id = p_studio_id and status = 'pending_payment';
  get diagnostics n = row_count;
  -- Zero means the sweep already took the seat back, or it was never held —
  -- a walk-in paying at the desk for a booking that was made outright. Not an
  -- error either way; the money is recorded regardless.
  return n = 1;
end $$;

revoke execute on function activate_purchase(uuid,uuid,uuid,int,char,text,text)
  from public, anon, authenticated;
revoke execute on function confirm_dropin_payment(uuid,uuid) from public, anon, authenticated;

alter table payments
  add column if not exists refunded_cents int not null default 0,
  add column if not exists refunded_at timestamptz,
  add column if not exists refund_reason text;

alter table payments drop constraint if exists payments_refund_within_amount;
alter table payments add constraint payments_refund_within_amount
  check (refunded_cents >= 0 and refunded_cents <= amount_cents);

-- -----------------------------------------------------------------------------
-- Recording money that arrived some other way
--
-- Front desk and above. Permissions §9 reads Front Desk "Payments" as TAKING
-- payment — selling a membership, a pack, a drop-in. Refunds are further down
-- and deliberately not here.
-- -----------------------------------------------------------------------------
create or replace function record_manual_payment(
  p_studio_id   uuid,
  p_member_id   uuid,
  p_kind        text,                       -- 'plan' | 'dropin' | 'other'
  p_amount_cents int,
  p_method      text,
  p_plan_id     uuid default null,
  p_booking_id  uuid default null,
  p_currency    char(3) default null,
  p_method_note text default null,
  p_reference   text default null,
  p_paid_at     timestamptz default now(),
  p_description text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_currency char(3);
  v_ms       uuid;
  v_payment  uuid;
  v_confirmed boolean := false;
  v_plan_name text;
begin
  if not is_desk_up(p_studio_id) then
    raise exception 'only staff can record a payment' using errcode = 'PT403';
  end if;
  if p_amount_cents is null or p_amount_cents < 0 then
    raise exception 'an amount is needed' using errcode = 'PT400';
  end if;
  if not exists (select 1 from members where id = p_member_id and studio_id = p_studio_id) then
    raise exception 'that member does not belong to this studio' using errcode = 'PT403';
  end if;

  select coalesce(p_currency, s.currency) into v_currency
    from studios s where s.id = p_studio_id;

  if p_kind = 'plan' then
    if p_plan_id is null then
      raise exception 'which plan?' using errcode = 'PT400';
    end if;
    -- The same function the Stripe webhook calls. Not a copy of it.
    v_ms := activate_purchase(p_studio_id, p_member_id, p_plan_id,
                              p_amount_cents, v_currency);
    select name into v_plan_name from membership_plans where id = p_plan_id;

  elsif p_kind = 'dropin' then
    if p_booking_id is null then
      raise exception 'which booking?' using errcode = 'PT400';
    end if;
    v_confirmed := confirm_dropin_payment(p_studio_id, p_booking_id);
  end if;

  insert into payments (
    studio_id, member_id, membership_id, booking_id, amount_cents, currency,
    status, provider, method, method_note, reference, description,
    paid_at, recorded_by
  ) values (
    p_studio_id, p_member_id, v_ms, p_booking_id, p_amount_cents, v_currency,
    'succeeded', 'manual', p_method, p_method_note, p_reference,
    coalesce(p_description,
             case p_kind when 'plan' then v_plan_name
                         when 'dropin' then 'Drop-in class'
                         else 'Payment' end),
    coalesce(p_paid_at, now()), auth.uid()
  ) returning id into v_payment;

  -- If a held seat was waiting on this, it is a real booking now and the
  -- confirmation goes out — the same trigger, on the same status change, as
  -- when Stripe confirms one.
  return jsonb_build_object(
    'payment_id', v_payment,
    'membership_id', v_ms,
    'booking_confirmed', v_confirmed
  );
end $$;

/**
 * A refund, against either provider.
 *
 * Owner and Manager only. Permissions §9: refunds sit with them rather than
 * front desk because money leaving the studio should need a second pair of
 * hands. This records the refund; for a Stripe payment the money itself is
 * moved in the Stripe dashboard, which is where the studio's own reconciliation
 * already lives.
 *
 * A FULL refund of a pack takes back the classes that have not been used. It
 * does not claw back classes already attended — you cannot un-attend a Tuesday
 * — so the ledger removes what remains and no more. A partial refund does not
 * touch credits at all: what a half-refunded pack is worth is a judgement the
 * studio makes, not one this function should guess.
 */
create or replace function record_refund(
  p_payment_id uuid, p_amount_cents int default null, p_reason text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  pay      payments%rowtype;
  plan     membership_plans%rowtype;
  ms       memberships%rowtype;
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

      -- What is left of THIS pack, and never more than the member actually has.
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

  return jsonb_build_object('payment_id', p_payment_id, 'refunded_cents', v_total,
                            'full', v_full, 'credits_removed', v_take);
end $$;

revoke execute on function record_manual_payment(uuid,uuid,text,int,text,uuid,uuid,char,text,text,timestamptz,text)
  from public, anon, authenticated;
grant execute on function record_manual_payment(uuid,uuid,text,int,text,uuid,uuid,char,text,text,timestamptz,text)
  to authenticated;
revoke execute on function record_refund(uuid,int,text) from public, anon, authenticated;
grant execute on function record_refund(uuid,int,text) to authenticated;
