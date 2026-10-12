-- Decision 76 (76a) — group packages (Barkada): the plan kind, the purchase,
-- booking a group atomically, cancel/swap, the expiry sweep, statement lines.
--
-- creates: book_group(uuid, uuid, text[]), cancel_group(uuid),
--   swap_group_guest(uuid, text, text), expire_group_purchases()
-- re-issues: activate_purchase(uuid, uuid, uuid, integer, character, text, text, boolean),
--   record_manual_payment(uuid, uuid, text, integer, text, uuid, uuid, character, text, text, timestamp with time zone, text),
--   xendit_begin_purchase(uuid, uuid), xendit_activate_success_internal(uuid, text),
--   member_activity(uuid, date, date)
--
-- A studio sells a GROUP plan (type 'group', group_size seats, one class for
-- the whole group). The host pays through the EXISTING plan rail (desk or
-- Xendit); activation creates a group_purchases row INSTEAD of a membership and
-- credits, and the payment is tagged by a new nullable payments.group_purchase_id
-- (the Decision 63b merch pattern). book_group books all group_size seats in ONE
-- transaction under the occurrence `for update` lock — all or none, the pattern
-- book_class/book_guest already serialise on. A group seat is payment_source
-- 'group' (no credit, no peak); a non-member guest becomes a lead with the
-- existing guest invite + the Decision 35 waiver-at-the-door gate, and NO
-- guest_passes row, so the group never touches the free-first once-ever key.
--
-- No new anon RPC — anon stays EXACTLY THIRTEEN (asserted at the end). Decision
-- 18 untouched. The 'group' enum values are added in 20260832470000 (the trap).

-- =============================================================================
-- 1. Schema
-- =============================================================================
alter table membership_plans
  add column if not exists group_size int,
  add column if not exists group_book_within_days int not null default 30;

alter table membership_plans drop constraint if exists membership_plans_group_shape;
alter table membership_plans add constraint membership_plans_group_shape check (
  (type = 'group') = (group_size is not null)
  and (group_size is null or group_size >= 2)
  and group_book_within_days between 1 and 365
);

create table if not exists group_purchases (
  id             uuid primary key default gen_random_uuid(),
  studio_id      uuid not null references studios on delete cascade,
  host_member_id uuid not null references members on delete cascade,
  plan_id        uuid not null references membership_plans,
  group_size     int  not null check (group_size >= 2),
  status         text not null default 'unbooked'
                   check (status in ('unbooked','booked','cancelled','expired')),
  occurrence_id  uuid references class_occurrences on delete set null,
  expires_on     date not null,
  booked_at      timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index if not exists group_purchases_studio_status on group_purchases (studio_id, status);
create index if not exists group_purchases_host on group_purchases (host_member_id);
drop trigger if exists group_purchases_updated on group_purchases;
create trigger group_purchases_updated before update on group_purchases
  for each row execute function set_updated_at();

create table if not exists group_bookings (
  id                uuid primary key default gen_random_uuid(),
  studio_id         uuid not null references studios on delete cascade,
  group_purchase_id uuid not null references group_purchases on delete cascade,
  booking_id        uuid not null references bookings on delete cascade,
  member_id         uuid not null references members on delete cascade,
  is_host           boolean not null default false,
  created_at        timestamptz not null default now()
);
create index if not exists group_bookings_purchase on group_bookings (group_purchase_id);
create index if not exists group_bookings_booking on group_bookings (booking_id);

-- The payment tag (Decision 63b merch pattern): a group payment has
-- membership_id null and group_purchase_id set.
alter table payments
  add column if not exists group_purchase_id uuid references group_purchases on delete set null;

-- RLS: staff of the studio read all; a member reads a purchase they host or a
-- seat they hold. Writes are the SECURITY DEFINER functions only (no client
-- write policy) — the functions run as owner and the grant is service_role.
alter table group_purchases enable row level security;
alter table group_bookings  enable row level security;

drop policy if exists group_purchases_staff on group_purchases;
create policy group_purchases_staff on group_purchases for select using (is_desk_up(studio_id));
drop policy if exists group_purchases_self on group_purchases;
create policy group_purchases_self on group_purchases for select
  using (exists (select 1 from members m where m.id = host_member_id and m.user_id = auth.uid()));

drop policy if exists group_bookings_staff on group_bookings;
create policy group_bookings_staff on group_bookings for select using (is_desk_up(studio_id));
drop policy if exists group_bookings_self on group_bookings;
create policy group_bookings_self on group_bookings for select
  using (exists (select 1 from members m where m.id = member_id and m.user_id = auth.uid()));

grant select on group_purchases, group_bookings to authenticated;
grant select, insert, update, delete on group_purchases, group_bookings to service_role;

-- =============================================================================
-- 2. activate_purchase — a group branch (create the purchase, no membership).
--    Byte-for-byte 20260832260000 + the group branch and v_group decl.
-- =============================================================================
create or replace function activate_purchase(
  p_studio_id uuid, p_member_id uuid, p_plan_id uuid, p_price_cents int,
  p_currency char(3), p_stripe_customer text default null,
  p_stripe_subscription text default null,
  p_enforce_seat_cap boolean default true)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  plan membership_plans%rowtype; v_ms uuid; v_bal int;
  v_today date; v_start timestamptz; v_end timestamptz;
  v_taken int;
  -- Decision 12 amendment: pack-shaped plans and their finite bundle size.
  v_is_pack boolean; v_credits int; v_validity int;
  v_group uuid;  -- Decision 76: a group purchase (no membership)
begin
  -- Locked. See above.
  select * into plan from membership_plans
   where id = p_plan_id and studio_id = p_studio_id
   for update;
  if not found then
    raise exception 'no such plan for this studio' using errcode = 'PT404';
  end if;
  if not exists (select 1 from members where id = p_member_id and studio_id = p_studio_id) then
    raise exception 'that member does not belong to this studio' using errcode = 'PT403';
  end if;

  -- Decision 76: a GROUP plan has NO membership and NO credits. Create the
  -- group purchase and return its id — the caller tags the payment with
  -- group_purchase_id (not membership_id). Placed before the seat-cap and
  -- membership path (a group is not a held membership, so neither applies).
  if plan.type = 'group' then
    insert into group_purchases (studio_id, host_member_id, plan_id, group_size, expires_on, status)
    values (p_studio_id, p_member_id, plan.id, plan.group_size,
            studio_today(p_studio_id) + coalesce(plan.group_book_within_days, 30), 'unbooked')
    returning id into v_group;
    return v_group;
  end if;

  -- Decision 62: an intro offer is bought once per person. If the plan being
  -- activated is a trial and this member has EVER held a membership on any trial
  -- plan of this studio (any status), refuse before anything is written. Keyed
  -- on plan.type = 'trial', so a Decision 61 complimentary grant on a non-trial
  -- plan is never caught.
  if plan.type = 'trial' and exists (
    select 1 from memberships ms
      join membership_plans mp on mp.id = ms.plan_id
     where ms.member_id = p_member_id
       and ms.studio_id = p_studio_id
       and mp.type = 'trial'
  ) then
    raise exception 'The intro offer is for first-timers — you''ve had yours. Choose a pack or membership instead.'
      using errcode = 'PT409';
  end if;

  -- Decision 24: the seat cap, under the lock, before anything is written.
  if coalesce(p_enforce_seat_cap, true)
     and plan.max_active_members is not null
     and coalesce((select ss.seat_caps_enabled from studio_settings ss
                    where ss.studio_id = p_studio_id), false)
  then
    v_taken := plan_seats_taken(plan.id);
    if v_taken >= plan.max_active_members then
      raise exception '% is full: % of % places are taken.',
                      plan.name, v_taken, plan.max_active_members
        using errcode = 'PT409',
              hint = 'Somebody has to leave this plan, or its limit has to go up, '
                     'before another place can be sold.';
    end if;
  end if;

  v_today := studio_today(p_studio_id);
  v_start := now();
  -- Null for a pack, a drop-in and a trial, which is what makes the columns
  -- mean something: a period present is a thing that renews.
  v_end   := plan_period_end(plan.id, v_start);

  -- Decision 12 amendment: resolve the pack bundle. A drop-in is exactly one
  -- class; a trial is plan.credits (default 1); a class pack is plan.credits.
  -- Recurring plans are not packs (their allowance is credits_per_period).
  v_is_pack := plan.type in ('class_pack', 'drop_in', 'trial');
  v_credits := case plan.type
                 when 'class_pack' then plan.credits
                 when 'drop_in'    then 1
                 when 'trial'      then coalesce(plan.credits, 1)
                 else null end;
  -- class_pack keeps its existing validity (NULL = no expiry); drop_in / trial
  -- default to 30 days so a paid class cannot sit unusable or forever.
  v_validity := case plan.type
                  when 'class_pack' then plan.validity_days
                  when 'drop_in'    then coalesce(plan.validity_days, 30)
                  when 'trial'      then coalesce(plan.validity_days, 30)
                  else null end;

  insert into memberships (
    studio_id, member_id, plan_id, status, price_cents, currency, starts_on,
    current_period_start, current_period_end, renews_on, credits_reset_at,
    credits_remaining, expires_on, auto_renew,
    stripe_customer_id, stripe_subscription_id
  ) values (
    p_studio_id, p_member_id, plan.id,
    (case when plan.type = 'trial' then 'trialing' else 'active' end)::membership_status,
    -- §7.1: the price agreed at purchase, snapshotted. Never re-read from the
    -- plan afterwards, so editing a plan cannot reprice anybody already on it.
    coalesce(p_price_cents, plan.price_cents),
    coalesce(nullif(p_currency, ''), plan.currency),
    v_today,
    v_start, v_end,
    -- renews_on is the period end as one of the STUDIO's dates.
    (v_end at time zone (select s.timezone from studios s where s.id = p_studio_id))::date,
    -- Decision 3: no rollover. The allowance resets at the period boundary
    -- rather than accumulating, and only where there is an allowance at all —
    -- Decision 12 makes a null credits_per_period mean unlimited.
    case when plan.type = 'recurring' and plan.credits_per_period is not null
         then v_end end,
    -- credits_remaining: a recurring plan's per-period allowance (null =
    -- unlimited, Decision 12); a pack-shaped plan its finite bundle.
    case when plan.type = 'recurring' then plan.credits_per_period
         else v_credits end,
    -- expires_on: pack-shaped plans only (a recurring plan renews, it does not
    -- expire). class_pack with no validity -> NULL (no expiry, unchanged).
    case when v_is_pack and v_validity is not null then v_today + v_validity end,
    plan.type = 'recurring',
    p_stripe_customer, nullif(p_stripe_subscription, '')
  ) returning id into v_ms;

  -- §6: a pack's classes arrive as ledger rows. credits_remaining above is a
  -- cache of this, written in the same transaction and never independently.
  -- Decision 12 amendment: drop_in and trial grant through the ledger too.
  if v_is_pack and coalesce(v_credits, 0) > 0 then
    select coalesce(sum(delta), 0) into v_bal
      from credit_ledger where studio_id = p_studio_id and member_id = p_member_id;
    insert into credit_ledger (studio_id, member_id, membership_id, delta, reason,
                               balance_after, expires_at, actor_user_id)
    values (p_studio_id, p_member_id, v_ms, v_credits, 'purchase',
            v_bal + v_credits,
            case when v_validity is not null
                 then (v_today + v_validity + 1)::timestamptz end,
            auth.uid());
  end if;

  insert into membership_events (studio_id, membership_id, type, to_status, actor_user_id)
  values (p_studio_id, v_ms, 'created',
          (case when plan.type = 'trial' then 'trialing' else 'active' end)::membership_status,
          auth.uid());

  return v_ms;
end $$;
revoke execute on function activate_purchase(uuid, uuid, uuid, integer, character, text, text, boolean)
  from public, anon, authenticated;
grant  execute on function activate_purchase(uuid, uuid, uuid, integer, character, text, text, boolean)
  to service_role;


-- ===========================================================================
-- 3. record_manual_payment — the desk path tags a group payment.
-- ===========================================================================
create or replace function public.record_manual_payment(p_studio_id uuid, p_member_id uuid, p_kind text, p_amount_cents integer, p_method text, p_plan_id uuid DEFAULT NULL::uuid, p_booking_id uuid DEFAULT NULL::uuid, p_currency character DEFAULT NULL::bpchar, p_method_note text DEFAULT NULL::text, p_reference text DEFAULT NULL::text, p_paid_at timestamp with time zone DEFAULT now(), p_description text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_currency char(3);
  v_ms       uuid;
  v_payment  uuid;
  v_confirmed boolean := false;
  v_plan_name text;
  v_renewing uuid;
  v_renewal  jsonb;
  v_is_group boolean := false;
  v_group_purchase uuid;  -- Decision 76
begin
  if not is_desk_up(p_studio_id) then
    raise exception 'only staff can record a payment' using errcode = 'PT403';
  end if;
  -- Lockout (migration 044). The studio's own subscription to Studiior has
  -- lapsed past its grace period. Reads stay open everywhere so nothing looks
  -- lost; this is one of the four places where DOING something stops.
  if studio_is_locked(p_studio_id) then
    raise exception 'this studio''s Studiior subscription is not active'
      using errcode = 'PT402',
            hint = 'Reactivate it from Billing. Nothing has been deleted.';
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
    -- RENEW OR SELL, and the difference is whether they are already on this
    -- plan. A studio taking cash has no webhook to roll a period forward, so
    -- the desk taking next month's money IS the renewal — and creating a
    -- second membership for it would leave the member holding two, with two
    -- periods and two allowances, which is what "it just made another one"
    -- looks like three months later.
    --
    -- A payment for a DIFFERENT plan is a plan change and still creates a new
    -- membership, as it always did. A pack is never a renewal: it has no
    -- period, and buying a second one is buying a second one.
    select ms.id into v_renewing
      from memberships ms
      join membership_plans pl on pl.id = ms.plan_id
     where ms.studio_id = p_studio_id and ms.member_id = p_member_id
       and ms.plan_id = p_plan_id
       and pl.type = 'recurring'
       and ms.status in ('active', 'past_due')
     order by ms.current_period_end desc nulls last
     limit 1;

    if v_renewing is not null then
      v_ms := v_renewing;
      v_renewal := advance_membership_period(v_renewing);
    else
      -- The same function the Stripe webhook calls. Not a copy of it.
      v_ms := activate_purchase(p_studio_id, p_member_id, p_plan_id,
                                p_amount_cents, v_currency);
    end if;
    select name, type = 'group' into v_plan_name, v_is_group
      from membership_plans where id = p_plan_id;
    -- Decision 76: a group plan's activate_purchase returned a group_purchase
    -- id, not a membership. Tag the payment with it; membership_id stays null.
    if v_is_group then v_group_purchase := v_ms; v_ms := null; end if;

  elsif p_kind = 'dropin' then
    if p_booking_id is null then
      raise exception 'which booking?' using errcode = 'PT400';
    end if;
    v_confirmed := confirm_dropin_payment(p_studio_id, p_booking_id);
  end if;

  insert into payments (
    studio_id, member_id, membership_id, group_purchase_id, booking_id, amount_cents, currency,
    status, provider, method, method_note, reference, description,
    paid_at, recorded_by
  ) values (
    p_studio_id, p_member_id, v_ms, v_group_purchase, p_booking_id, p_amount_cents, v_currency,
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
    'group_purchase_id', v_group_purchase,
    'booking_confirmed', v_confirmed,
    -- Present only when this renewed something, so the desk is told on the
    -- spot what the money bought — and told when it is still not enough.
    'renewed', v_renewal
  );
end $function$;


-- ===========================================================================
-- 4. xendit_begin_purchase — admit the group plan online.
-- ===========================================================================
create or replace function xendit_begin_purchase(p_studio_id uuid, p_plan_id uuid)
returns table(purchase_id uuid, amount_cents int, currency char(3))
language plpgsql security definer set search_path = public as $$
declare v_member uuid; mp membership_plans%rowtype; v_id uuid; v_renew uuid;
begin
  select id into v_member from members where studio_id = p_studio_id and user_id = auth.uid();
  if v_member is null then
    raise exception 'you are not a member of that studio' using errcode = 'PT403';
  end if;
  if not exists (select 1 from studio_payment_providers where studio_id = p_studio_id and provider = 'xendit') then
    raise exception 'this studio is not set up to take online payments' using errcode = 'PT409';
  end if;

  select * into mp from membership_plans
   where id = p_plan_id and studio_id = p_studio_id and visibility = 'public' and status = 'active';
  if mp.id is null then
    raise exception 'that plan is not on sale' using errcode = 'PT404';
  end if;
  -- Decision 66: a recurring plan is bought online as one period (no subscription
  -- yet — that is Decision 67). Decision 62 admits `trial`.
  -- Decision 76: a GROUP plan is a one-time purchase bought online (the host
  -- pays; activation creates a group_purchase, not a membership).
  if mp.type not in ('class_pack', 'drop_in', 'trial', 'recurring', 'group') then
    raise exception 'that plan is not a one-time purchase' using errcode = 'PT422';
  end if;

  -- Decision 62: an intro offer is bought once per person.
  if mp.type = 'trial' and exists (
    select 1 from memberships ms
      join membership_plans mp2 on mp2.id = ms.plan_id
     where ms.member_id = v_member
       and ms.studio_id = p_studio_id
       and mp2.type = 'trial'
  ) then
    raise exception 'The intro offer is for first-timers — you''ve had yours. Choose a pack or membership instead.'
      using errcode = 'PT409';
  end if;

  -- Decision 66: if the member already holds a live/past-due membership on this
  -- recurring plan, this checkout RENEWS it — decided at begin so the webhook,
  -- belt and reconcile all extend rather than create. (The same renew-vs-sell
  -- rule record_manual_payment uses for the desk.)
  if mp.type = 'recurring' then
    select ms.id into v_renew
      from memberships ms
     where ms.studio_id = p_studio_id and ms.member_id = v_member
       and ms.plan_id = p_plan_id and ms.status in ('active', 'past_due')
     order by ms.current_period_end desc nulls last
     limit 1;
  end if;

  -- Decision 24: a capped plan that is full refuses a NEW place, the same count
  -- (plan_seats_taken, under seat_caps_enabled) the desk uses in
  -- activate_purchase. A RENEWAL (v_renew set) extends an existing place and is
  -- never re-checked — the existing holder is already counted. plan_seats_taken
  -- is service-role only; this SECURITY DEFINER function owns the privilege, so
  -- the internal call is the activate_purchase pattern.
  if v_renew is null
     and mp.max_active_members is not null
     and coalesce((select ss.seat_caps_enabled from studio_settings ss
                    where ss.studio_id = p_studio_id), false)
     and plan_seats_taken(mp.id) >= mp.max_active_members
  then
    raise exception '% is full.', mp.name using errcode = 'PT409';
  end if;

  insert into xendit_purchases (studio_id, member_id, plan_id, amount_cents, currency, renews_membership_id)
  values (p_studio_id, v_member, p_plan_id, mp.price_cents, mp.currency, v_renew)
  returning id into v_id;

  return query select v_id, mp.price_cents, mp.currency;
end $$;
revoke execute on function xendit_begin_purchase(uuid, uuid) from public, anon;
grant  execute on function xendit_begin_purchase(uuid, uuid) to authenticated, service_role;


-- ===========================================================================
-- 5. xendit_activate_success_internal — the online path tags a group payment.
-- ===========================================================================
create or replace function xendit_activate_success_internal(p_purchase_id uuid, p_payment_id text)
returns text
language plpgsql security definer set search_path = public as $$
declare p xendit_purchases%rowtype; v_ms uuid; v_prior text;
        v_group uuid; v_is_group boolean;  -- Decision 76
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
    -- Decision 76: a GROUP plan has no membership. activate_purchase creates
    -- the group_purchase; the payment is tagged with group_purchase_id. A
    -- group is never a renewal and never settles an unpaid drop-in.
    select type = 'group' into v_is_group from membership_plans where id = p.plan_id;
    if v_is_group then
      v_group := activate_purchase(p.studio_id, p.member_id, p.plan_id, p.amount_cents, p.currency, null, null, false);
      insert into payments (studio_id, member_id, group_purchase_id, amount_cents, currency,
                            status, provider, reference, description, paid_at)
      select p.studio_id, p.member_id, v_group, p.amount_cents, p.currency, 'succeeded', 'xendit',
             nullif(p_payment_id, ''), mp.name, now()
        from membership_plans mp where mp.id = p.plan_id;
    else
    -- A plan purchase. Decision 66: when this purchase names a membership that
    -- is still active/past-due, EXTEND it one period from its old end; if that
    -- membership has drifted (cancelled/expired/frozen) or there is none, fall
    -- back to a fresh purchase. advance_membership_period_run is the UNGUARDED
    -- twin — the anon webhook is not desk/service at runtime.
    if p.renews_membership_id is not null and exists (
         select 1 from memberships where id = p.renews_membership_id
            and status in ('active', 'past_due') and not membership_frozen_now(id)) then
      v_ms := p.renews_membership_id;
      perform advance_membership_period_run(p.renews_membership_id);
    else
      v_ms := activate_purchase(p.studio_id, p.member_id, p.plan_id, p.amount_cents, p.currency,
                                null, null, false);
      -- Decision 66: an online recurring purchase is ONE period — no saved card,
      -- no auto-charge. activate_purchase sets auto_renew = (type='recurring');
      -- the online path renews by hand, so turn it off (harmless for a pack,
      -- which is already false). The extend branch above leaves it untouched.
      update memberships set auto_renew = false where id = v_ms;
    end if;

    -- Decision 73b (extension): ANY plan bought online settles the buyer's
    -- OLDEST unpaid app-booked drop-in — the new membership is applied to that
    -- booking (a credit consumed unless it is an unlimited membership) so it no
    -- longer counts toward the 73a unpaid-booking cap. The helper no-ops unless
    -- v_ms has a usable credit (or is unlimited) AND covers the held class, so a
    -- non-covering plan, or one with nothing usable, passes through untouched.
    -- Idempotent: a replay returns 'already_succeeded' above before reaching here.
    perform apply_plan_to_unpaid(p.studio_id, p.member_id, v_ms);

    insert into payments (studio_id, member_id, membership_id, amount_cents, currency,
                          status, provider, reference, description, paid_at)
    select p.studio_id, p.member_id, v_ms, p.amount_cents, p.currency, 'succeeded', 'xendit',
           nullif(p_payment_id, ''), mp.name, now()
      from membership_plans mp where mp.id = p.plan_id;
    end if;
  end if;

  -- Expired is not final (see 20260831820000).
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


-- ===========================================================================
-- 5b. member_activity — group statement lines (Booked by {host}; host names).
-- ===========================================================================
create or replace function member_activity(p_member_id uuid, p_from date, p_to date)
returns table (
  at timestamptz, kind text, title text, detail text,
  credit_delta int, balance_after int, amount_cents int, currency text,
  occurrence_id uuid, booking_id uuid, membership_id uuid)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare v_studio uuid; v_is_staff boolean; v_owns boolean;
begin
  select studio_id into v_studio from members where id = p_member_id;
  if v_studio is null then raise exception 'no such member' using errcode = 'PT404'; end if;
  v_owns := exists (select 1 from members m where m.id = p_member_id and m.user_id = auth.uid());
  v_is_staff := coalesce(is_desk_up(v_studio), false) or is_service_context();
  if not (v_owns or v_is_staff) then
    raise exception 'that is not your statement' using errcode = 'PT403';
  end if;

  return query
  with led as (
    select cl.id, cl.delta, cl.reason::text as reason, cl.booking_id, cl.membership_id,
           cl.created_at,
           (sum(cl.delta) over (order by cl.created_at, cl.id))::int as bal
      from credit_ledger cl
     where cl.member_id = p_member_id
  ),
  -- A purchase payment claims the Nth 'purchase' ledger row of its membership;
  -- a refunded payment claims the Nth negative 'manual' row of its membership.
  -- Rank joins, so each ledger id is claimed at most once; a grant with no
  -- payment (e.g. a complimentary membership) stays unclaimed and surfaces as its
  -- own "Credits added" line.
  purch_led as (
    select id, membership_id, row_number() over (partition by membership_id order by created_at, id) rn
      from led where reason = 'purchase' and membership_id is not null),
  purch_pay as (
    select p.id as payment_id, p.membership_id,
           row_number() over (partition by p.membership_id order by coalesce(p.paid_at, p.created_at), p.id) rn
      from payments p
     where p.member_id = p_member_id and p.membership_id is not null
       and p.status in ('succeeded', 'partially_refunded')),
  pay_grant as (
    select pp.payment_id, pl.id as ledger_id
      from purch_pay pp join purch_led pl on pl.membership_id = pp.membership_id and pl.rn = pp.rn),
  forfeit_led as (
    select id, membership_id, row_number() over (partition by membership_id order by created_at, id) rn
      from led where reason = 'manual' and delta < 0 and membership_id is not null),
  refund_pay as (
    select p.id as payment_id, p.membership_id,
           row_number() over (partition by p.membership_id order by coalesce(p.refunded_at, p.updated_at), p.id) rn
      from payments p
     where p.member_id = p_member_id and p.membership_id is not null
       and (p.refunded_at is not null or p.status in ('refunded', 'partially_refunded'))),
  pay_forfeit as (
    select rp.payment_id, fl.id as ledger_id
      from refund_pay rp join forfeit_led fl on fl.membership_id = rp.membership_id and fl.rn = rp.rn),
  ev as (
    -- joined (staff only)
    select m.joined_on::timestamptz as at, 'joined' as kind, 'Joined the studio' as title,
           nullif('Came via ' || coalesce(m.source, ''), 'Came via ') as detail,
           null::uuid as ledger_id, null::int as amount_cents, null::text as currency,
           null::uuid as occurrence_id, null::uuid as booking_id, null::uuid as membership_id
      from members m where m.id = p_member_id and v_is_staff and m.joined_on is not null
    union all
    -- booked / waitlisted / free first
    select b.booked_at,
           case when b.status = 'waitlisted' then 'waitlisted'
                when b.payment_source = 'comp'
                     and exists (select 1 from guest_passes gp where gp.guest_booking_id = b.id and gp.host_member_id is null)
                     then 'free_first'
                else 'booked' end,
           case when b.status = 'waitlisted' then 'Joined the waitlist for ' || coalesce(o.name, 'a class')
                when b.payment_source = 'comp'
                     and exists (select 1 from guest_passes gp where gp.guest_booking_id = b.id and gp.host_member_id is null)
                     then 'Booked a free first class — ' || coalesce(o.name, 'a class')
                when b.payment_source = 'group' then
                     (select case when gb.is_host
                                  then 'Group booking — ' || coalesce(o.name, 'a class') || ' · ' || mp.name
                                  else 'Booked by ' || hm.first_name || ' · ' || mp.name end
                        from group_bookings gb
                        join group_purchases gpu on gpu.id = gb.group_purchase_id
                        join membership_plans mp on mp.id = gpu.plan_id
                        join members hm on hm.id = gpu.host_member_id
                       where gb.booking_id = b.id)
                else 'Booked ' || coalesce(o.name, 'a class') end,
           case when b.payment_source = 'group' then
                  (select case when gb.is_host then (
                            select string_agg(coalesce(nullif(m2.first_name,''), m2.email), ', ')
                              from group_bookings gb2 join members m2 on m2.id = gb2.member_id
                             where gb2.group_purchase_id = gb.group_purchase_id and not gb2.is_host)
                          end
                     from group_bookings gb where gb.booking_id = b.id)
                when exists (select 1 from waitlist_offers wo where wo.booking_id = b.id and wo.outcome = 'accepted')
                then 'From the waitlist' end,
           b.credit_entry_id, null, null, b.occurrence_id, b.id, b.membership_id
      from bookings b left join class_occurrences o on o.id = b.occurrence_id
     where b.member_id = p_member_id
       and b.status in ('booked','attended','no_show','cancelled','late_cancelled','waitlisted','pending_payment')
    union all
    -- cancelled (carries the cancellation_refund, or 0 "class used")
    select b.cancelled_at,
           case when b.release_reason = 'studio_released' then 'studio_cancelled'
                when b.status = 'late_cancelled' or b.is_late_cancel then 'late_cancelled'
                else 'cancelled' end,
           case when b.release_reason = 'studio_released' then 'Studio cancelled ' || coalesce(o.name, 'a class')
                when b.status = 'late_cancelled' or b.is_late_cancel then 'Cancelled late — ' || coalesce(o.name, 'a class')
                else 'Cancelled ' || coalesce(o.name, 'a class') end,
           case when b.release_reason = 'studio_released' then 'Credit returned'
                when (b.status = 'late_cancelled' or b.is_late_cancel)
                     and not exists (select 1 from led cl where cl.booking_id = b.id and cl.reason = 'cancellation_refund')
                then 'Class used' end,
           (select cl.id from led cl where cl.booking_id = b.id and cl.reason = 'cancellation_refund' order by cl.created_at, cl.id limit 1),
           null, null, b.occurrence_id, b.id, b.membership_id
      from bookings b left join class_occurrences o on o.id = b.occurrence_id
     where b.member_id = p_member_id and b.status in ('cancelled','late_cancelled')
    union all
    -- checked in / attended
    select ci.checked_in_at, 'attended',
           case when o.id is null then 'Attended a class (imported)' else 'Attended ' || o.name end,
           null, null::uuid, null, null, ci.occurrence_id, ci.booking_id, null
      from check_ins ci left join class_occurrences o on o.id = ci.occurrence_id
     where ci.member_id = p_member_id
    union all
    -- no-show
    select coalesce(b.no_show_at, o.ends_at, b.updated_at), 'no_show',
           'Did not attend ' || coalesce(o.name, 'a class'), null,
           null::uuid, null, null, b.occurrence_id, b.id, b.membership_id
      from bookings b left join class_occurrences o on o.id = b.occurrence_id
     where b.member_id = p_member_id and b.status = 'no_show'
    union all
    -- purchase / refund / failed payment (carries the matched grant/forfeit)
    select coalesce(p.paid_at, p.created_at),
           case when p.refunded_at is not null or p.status in ('refunded','partially_refunded') then 'refund'
                when p.status = 'failed' then 'payment_failed'
                else 'purchase' end,
           case when p.refunded_at is not null or p.status in ('refunded','partially_refunded') then 'Refund — ' || coalesce(p.description, 'a payment')
                when p.status = 'failed' then 'Payment failed — ' || coalesce(p.description, 'a payment')
                else 'Bought ' || coalesce(p.description, 'a plan') end,
           null,
           case when p.refunded_at is not null or p.status in ('refunded','partially_refunded')
                then (select ledger_id from pay_forfeit pf where pf.payment_id = p.id)
                when p.status = 'failed' then null
                else (select ledger_id from pay_grant pg where pg.payment_id = p.id) end,
           case when p.refunded_at is not null then coalesce(p.refunded_cents, p.amount_cents) else p.amount_cents end,
           p.currency, null::uuid, p.booking_id, p.membership_id
      from payments p where p.member_id = p_member_id
    union all
    -- rescheduled / instructor changed, for occurrences the member holds a live booking on
    select oe.at,
           case when oe.kind = 'moved' then 'rescheduled' else 'instructor_changed' end,
           case when oe.kind = 'moved' then 'Class rescheduled — ' || coalesce(o.name, 'a class')
                else 'Instructor changed — ' || coalesce(o.name, 'a class') end,
           null, null::uuid, null, null, oe.occurrence_id, null, null
      from occurrence_events oe left join class_occurrences o on o.id = oe.occurrence_id
     where oe.kind in ('moved','instructor_changed')
       and exists (select 1 from bookings b where b.occurrence_id = oe.occurrence_id
                    and b.member_id = p_member_id and b.status <> 'cancelled')
    union all
    -- message_sent (staff only)
    select coalesce(msg.sent_at, msg.updated_at), 'message_sent', 'Message sent', msg.subject,
           null::uuid, null, null, null, null, null
      from messages msg
     where msg.member_id = p_member_id and v_is_staff and msg.status in ('queued','sent')
  ),
  claimed as (select distinct ledger_id from ev where ledger_id is not null),
  -- ledger rows no event claims: complimentary grants, manual adjustments,
  -- lockout, merch. Shown as their own credit lines.
  adj as (
    select l.created_at as at,
           case when l.reason = 'booking' then 'credit_used'
                when l.delta >= 0 then 'credits_added' else 'credit_adjustment' end as kind,
           case when l.reason = 'booking' then 'Class credit used'
                when l.reason = 'cancellation_refund' then 'Credit returned'
                when l.delta >= 0 then 'Credits added' else 'Credit adjustment' end as title,
           null::text as detail, l.id as ledger_id, null::int as amount_cents, null::text as currency,
           null::uuid as occurrence_id, l.booking_id, l.membership_id
      from led l where l.id not in (select ledger_id from claimed where ledger_id is not null)
  ),
  all_rows as (
    select * from ev
    union all
    select * from adj
  )
  select
    x.at, x.kind, x.title, x.detail,
    coalesce(l.delta, 0) as credit_delta,
    coalesce(l.bal,
             (select l2.bal from led l2 where l2.created_at <= x.at order by l2.created_at desc, l2.id desc limit 1),
             0) as balance_after,
    x.amount_cents, x.currency, x.occurrence_id, x.booking_id, x.membership_id
  from all_rows x
  left join led l on l.id = x.ledger_id
  where x.at is not null and x.at::date between p_from and p_to
  order by x.at desc, x.kind;
end $$;
revoke execute on function member_activity(uuid, date, date) from public, anon;
grant  execute on function member_activity(uuid, date, date) to authenticated, service_role;

-- =============================================================================
-- 6. book_group — the host (or staff) books all group_size seats atomically.
-- =============================================================================
create function book_group(p_group_purchase_id uuid, p_occurrence_id uuid, p_emails text[])
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  gp       group_purchases%rowtype;
  v_occ    class_occurrences%rowtype;
  v_studio studios%rowtype;
  v_host   members%rowtype;
  v_plan   membership_plans%rowtype;
  v_actor  uuid := auth.uid();
  v_is_staff boolean;
  v_free int; v_restrict jsonb;
  v_emails text[]; v_e text; v_norm text; v_seen text[] := '{}';
  v_mem members%rowtype; v_mid uuid; v_bk uuid;
  v_mids uuid[] := '{}'; v_new_flags boolean[] := '{}'; i int;
  v_token text; v_url text; v_names text[] := '{}';
begin
  select * into gp from group_purchases where id = p_group_purchase_id for update;
  if gp.id is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;

  select * into v_host from members where id = gp.host_member_id;
  v_is_staff := coalesce(is_desk_up(gp.studio_id), false);
  if not (coalesce(v_host.user_id = v_actor, false) or v_is_staff) then
    return jsonb_build_object('ok', false, 'reason', 'not_authorised');
  end if;

  if gp.status <> 'unbooked' then
    return jsonb_build_object('ok', false, 'reason', 'already_' || gp.status);
  end if;
  if studio_today(gp.studio_id) > gp.expires_on then
    return jsonb_build_object('ok', false, 'reason', 'window_closed');
  end if;

  select * into v_occ from class_occurrences where id = p_occurrence_id for update;
  if v_occ.id is null or v_occ.studio_id <> gp.studio_id then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  if v_occ.status <> 'scheduled' or v_occ.starts_at <= now() then
    return jsonb_build_object('ok', false, 'reason', 'not_bookable');
  end if;
  if not month_published(gp.studio_id, v_occ.starts_at) then
    return jsonb_build_object('ok', false, 'reason', 'month_not_published');
  end if;
  -- Decision 48: an unstaffed hidden class is closed to NEW bookings.
  if studio_hides_unstaffed(gp.studio_id) and v_occ.staffing <> 'assigned' then
    return jsonb_build_object('ok', false, 'reason', 'not_staffed_yet');
  end if;

  select * into v_plan from membership_plans where id = gp.plan_id;
  -- Optional class-type restriction — the exact book_class jsonb test (§2.1.9).
  v_restrict := v_plan.restrictions -> 'class_type_ids';
  if v_restrict is not null and jsonb_typeof(v_restrict) = 'array'
     and jsonb_array_length(v_restrict) > 0
     and not (v_occ.class_type_id is not null
              and jsonb_exists(v_restrict, v_occ.class_type_id::text)) then
    return jsonb_build_object('ok', false, 'reason', 'class_type_not_allowed');
  end if;

  -- Exactly group_size - 1 guest emails (the host is seat one).
  v_emails := coalesce(p_emails, '{}');
  if coalesce(array_length(v_emails, 1), 0) is distinct from (gp.group_size - 1) then
    return jsonb_build_object('ok', false, 'reason', 'wrong_email_count',
                              'expected', gp.group_size - 1);
  end if;

  -- Capacity for the WHOLE group, under the lock (held waitlist seats excluded).
  -- Checked once here; all inserts then run in this one transaction, so the
  -- group is all booked or (on any raise / short seats) none.
  v_free := v_occ.capacity - occurrence_seats_taken(p_occurrence_id)
                           - occurrence_seats_held(p_occurrence_id);
  if v_free < gp.group_size then
    return jsonb_build_object('ok', false, 'reason', 'class_full',
                              'free', v_free, 'need', gp.group_size);
  end if;

  select * into v_studio from studios where id = gp.studio_id;

  -- PASS ONE — validate and resolve EVERY seat with NO writes, so any refusal
  -- (a plpgsql `return` does NOT roll back) leaves nothing behind. The host is
  -- seat one; refuse if they already hold a live seat on this class.
  if exists (select 1 from bookings where occurrence_id = p_occurrence_id
              and member_id = v_host.id
              and status in ('booked','waitlisted','attended','no_show','pending_payment')) then
    return jsonb_build_object('ok', false, 'reason', 'host_already_booked');
  end if;

  foreach v_e in array v_emails loop
    v_norm := lower(btrim(v_e));
    if v_norm = '' then return jsonb_build_object('ok', false, 'reason', 'blank_email'); end if;
    if v_norm = lower(btrim(coalesce(v_host.email, ''))) then
      return jsonb_build_object('ok', false, 'reason', 'email_is_host', 'email', v_e);
    end if;
    if v_norm = any (v_seen) then
      return jsonb_build_object('ok', false, 'reason', 'duplicate_email', 'email', v_e);
    end if;
    v_seen := v_seen || v_norm;

    select * into v_mem from members where studio_id = gp.studio_id and lower(email) = v_norm;
    if found then
      -- An existing member already booked on THIS class is refused, by name.
      if exists (select 1 from bookings where occurrence_id = p_occurrence_id
                  and member_id = v_mem.id
                  and status in ('booked','waitlisted','attended','no_show','pending_payment')) then
        return jsonb_build_object('ok', false, 'reason', 'already_booked', 'email', v_e);
      end if;
      v_mids := v_mids || v_mem.id; v_new_flags := v_new_flags || false;
      v_names := v_names || coalesce(nullif(v_mem.first_name, ''), btrim(v_e));
    else
      v_mids := v_mids || null::uuid; v_new_flags := v_new_flags || true;
      v_names := v_names || btrim(v_e);
    end if;
  end loop;

  -- PASS TWO — everything validated, now write (all in this one transaction).
  -- SEAT ONE: the host.
  insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source)
  values (gp.studio_id, p_occurrence_id, v_host.id, 'booked',
          (case when v_is_staff then 'front_desk' else 'member' end)::booking_source, 'group')
  returning id into v_bk;
  insert into group_bookings (studio_id, group_purchase_id, booking_id, member_id, is_host)
  values (gp.studio_id, gp.id, v_bk, v_host.id, true);

  for i in 1 .. coalesce(array_length(v_emails, 1), 0) loop
    v_e := v_emails[i];
    if v_new_flags[i] then
      -- A non-member becomes a lead. No guest_passes row — the group seat never
      -- touches the free-first once-ever key, so the guest keeps their free
      -- first class and guest pass.
      insert into members (studio_id, first_name, last_name, email, status, source)
      values (gp.studio_id, 'Guest', '—', btrim(v_e), 'lead', 'group')
      returning id into v_mid;
    else
      v_mid := v_mids[i];
    end if;

    insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source)
    values (gp.studio_id, p_occurrence_id, v_mid, 'booked',
            (case when v_is_staff then 'front_desk' else 'member' end)::booking_source, 'group')
    returning id into v_bk;
    insert into group_bookings (studio_id, group_purchase_id, booking_id, member_id, is_host)
    values (gp.studio_id, gp.id, v_bk, v_mid, false);

    -- The existing guest invite (claim + waiver) for a new lead.
    if v_new_flags[i] then
      v_token := encode(gen_random_bytes(24), 'hex');
      insert into member_invites (studio_id, member_id, email, token_hash, expires_at, created_by)
      values (gp.studio_id, v_mid, btrim(v_e),
              encode(digest(v_token, 'sha256'), 'hex'), now() + interval '14 days', v_actor);
      v_url := 'https://' || v_studio.slug || '.'
               || coalesce(notification_setting('member_app_domain'), 'studiior.app')
               || '/claim/' || v_token;
      perform queue_notification(gp.studio_id, v_mid, 'guest_invite',
        jsonb_build_object('claim_url', v_url, 'host_name', v_host.first_name,
                           'class_name', v_occ.name),
        'guest_invite:group:' || gp.id || ':' || v_mid);
    end if;
  end loop;

  update class_occurrences set booked_count = booked_count + gp.group_size
   where id = p_occurrence_id;
  update group_purchases set status = 'booked', occurrence_id = p_occurrence_id, booked_at = now()
   where id = gp.id;

  -- A group seat may complete a flex/free-first confirm total (Decision 30).
  perform confirm_provisional_seats_run(p_occurrence_id);

  return jsonb_build_object('ok', true, 'group_purchase_id', gp.id,
    'occurrence_id', p_occurrence_id, 'seats', gp.group_size, 'guests', to_jsonb(v_names));
end $$;
revoke execute on function book_group(uuid, uuid, text[]) from public, anon;
grant  execute on function book_group(uuid, uuid, text[]) to authenticated, service_role;

-- =============================================================================
-- 7. cancel_group — the host (or staff) cancels the whole group.
--    EARLY → the purchase returns to unbooked (rebookable in its window);
--    LATE  → the seats are cancelled PLAIN (no late stamp on the guests) and the
--    purchase is forfeited (status cancelled, no refund).
-- =============================================================================
create function cancel_group(p_group_purchase_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare gp group_purchases%rowtype; occ class_occurrences%rowtype; st studio_settings%rowtype;
        v_host members%rowtype; v_late boolean; r record; n int := 0;
begin
  select * into gp from group_purchases where id = p_group_purchase_id for update;
  if gp.id is null then raise exception 'no such group' using errcode = 'PT404'; end if;
  select * into v_host from members where id = gp.host_member_id;
  if not (coalesce(v_host.user_id = auth.uid(), false)
          or coalesce(is_desk_up(gp.studio_id), false)
          or is_service_context()) then
    raise exception 'that is not your group' using errcode = 'PT403';
  end if;
  if gp.status <> 'booked' then
    raise exception 'this group is %', gp.status using errcode = 'PT409';
  end if;

  select * into occ from class_occurrences where id = gp.occurrence_id for update;
  select * into st  from studio_settings where studio_id = gp.studio_id;
  v_late := occ.id is not null
            and now() > occ.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0));

  -- Each live group seat is cancelled as PLAIN 'cancelled' (not late_cancelled,
  -- so the guests carry no infraction). tg_stamp_booking_release stamps
  -- member_cancelled; a group seat has no credit, so nothing is refunded.
  for r in
    select b.id as booking_id from group_bookings gb
      join bookings b on b.id = gb.booking_id
     where gb.group_purchase_id = gp.id
       and b.status in ('booked','attended','no_show','pending_payment')
  loop
    update bookings set status = 'cancelled', cancelled_at = now(),
           cancelled_by = auth.uid(), is_late_cancel = false
     where id = r.booking_id;
    update class_occurrences set booked_count = greatest(0, booked_count - 1) where id = occ.id;
    n := n + 1;
  end loop;

  -- Freed seats offer to the waitlist front (one offer; the sweep cascades).
  if occ.id is not null then perform offer_waitlist_seat(occ.id); end if;

  if v_late then
    update group_purchases set status = 'cancelled' where id = gp.id;
  else
    update group_purchases set status = 'unbooked', occurrence_id = null, booked_at = null
     where id = gp.id;
  end if;

  return jsonb_build_object('ok', true, 'late', coalesce(v_late, false), 'cancelled', n,
    'group_status', case when v_late then 'cancelled' else 'unbooked' end);
end $$;
revoke execute on function cancel_group(uuid) from public, anon;
grant  execute on function cancel_group(uuid) to authenticated, service_role;

-- =============================================================================
-- 8. swap_group_guest — the host (or staff) replaces a guest email before the
--    cut-off. Cancel that seat, book the replacement, in one transaction.
-- =============================================================================
create function swap_group_guest(p_group_purchase_id uuid, p_old_email text, p_new_email text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare gp group_purchases%rowtype; occ class_occurrences%rowtype; st studio_settings%rowtype;
        v_host members%rowtype; v_studio studios%rowtype; v_old record;
        v_oldn text; v_newn text; v_mem members%rowtype; v_mid uuid; v_bk uuid;
        v_new boolean; v_token text; v_url text;
begin
  select * into gp from group_purchases where id = p_group_purchase_id for update;
  if gp.id is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  select * into v_host from members where id = gp.host_member_id;
  if not (coalesce(v_host.user_id = auth.uid(), false) or coalesce(is_desk_up(gp.studio_id), false)) then
    return jsonb_build_object('ok', false, 'reason', 'not_authorised');
  end if;
  if gp.status <> 'booked' then return jsonb_build_object('ok', false, 'reason', 'not_booked'); end if;

  select * into occ from class_occurrences where id = gp.occurrence_id for update;
  select * into st  from studio_settings where studio_id = gp.studio_id;
  if occ.id is null
     or now() > occ.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)) then
    return jsonb_build_object('ok', false, 'reason', 'too_late');
  end if;

  v_oldn := lower(btrim(p_old_email)); v_newn := lower(btrim(p_new_email));
  if v_newn = '' then return jsonb_build_object('ok', false, 'reason', 'blank_email'); end if;

  -- The seat being swapped out: a NON-host group seat whose member matches.
  select gb.id as gb_id, gb.booking_id, gb.member_id into v_old
    from group_bookings gb join members m on m.id = gb.member_id
   where gb.group_purchase_id = gp.id and not gb.is_host and lower(m.email) = v_oldn;
  if v_old.gb_id is null then
    return jsonb_build_object('ok', false, 'reason', 'guest_not_found', 'email', p_old_email);
  end if;

  if v_newn = lower(btrim(coalesce(v_host.email, ''))) then
    return jsonb_build_object('ok', false, 'reason', 'email_is_host');
  end if;
  if exists (select 1 from group_bookings gb join members m on m.id = gb.member_id
              where gb.group_purchase_id = gp.id and gb.id <> v_old.gb_id and lower(m.email) = v_newn) then
    return jsonb_build_object('ok', false, 'reason', 'duplicate_email');
  end if;

  select * into v_mem from members where studio_id = gp.studio_id and lower(email) = v_newn;
  if found then
    if exists (select 1 from bookings where occurrence_id = gp.occurrence_id and member_id = v_mem.id
                and status in ('booked','waitlisted','attended','no_show','pending_payment')) then
      return jsonb_build_object('ok', false, 'reason', 'already_booked', 'email', p_new_email);
    end if;
    v_mid := v_mem.id; v_new := false;
  else
    insert into members (studio_id, first_name, last_name, email, status, source)
    values (gp.studio_id, 'Guest', '—', btrim(p_new_email), 'lead', 'group') returning id into v_mid;
    v_new := true;
  end if;

  -- Out with the old seat (plain cancel), in with the new — net booked_count 0.
  update bookings set status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid(),
         is_late_cancel = false where id = v_old.booking_id;
  delete from group_bookings where id = v_old.gb_id;
  update class_occurrences set booked_count = greatest(0, booked_count - 1) where id = occ.id;

  insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source)
  values (gp.studio_id, gp.occurrence_id, v_mid, 'booked', 'member', 'group') returning id into v_bk;
  insert into group_bookings (studio_id, group_purchase_id, booking_id, member_id, is_host)
  values (gp.studio_id, gp.id, v_bk, v_mid, false);
  update class_occurrences set booked_count = booked_count + 1 where id = occ.id;

  if v_new then
    select * into v_studio from studios where id = gp.studio_id;
    v_token := encode(gen_random_bytes(24), 'hex');
    insert into member_invites (studio_id, member_id, email, token_hash, expires_at, created_by)
    values (gp.studio_id, v_mid, btrim(p_new_email),
            encode(digest(v_token, 'sha256'), 'hex'), now() + interval '14 days', auth.uid());
    v_url := 'https://' || v_studio.slug || '.'
             || coalesce(notification_setting('member_app_domain'), 'studiior.app')
             || '/claim/' || v_token;
    perform queue_notification(gp.studio_id, v_mid, 'guest_invite',
      jsonb_build_object('claim_url', v_url, 'host_name', v_host.first_name, 'class_name', occ.name),
      'guest_invite:group:' || gp.id || ':' || v_mid);
  end if;

  return jsonb_build_object('ok', true, 'swapped_out', p_old_email, 'swapped_in', p_new_email);
end $$;
revoke execute on function swap_group_guest(uuid, text, text) from public, anon;
grant  execute on function swap_group_guest(uuid, text, text) to authenticated, service_role;

-- =============================================================================
-- 9. expire_group_purchases — unbooked groups expire at the window end (daily).
-- =============================================================================
create function expire_group_purchases()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not is_service_context() then
    raise exception 'this is a scheduled job' using errcode = 'PT403';
  end if;
  update group_purchases gp set status = 'expired', updated_at = now()
   where gp.status = 'unbooked' and studio_today(gp.studio_id) > gp.expires_on;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function expire_group_purchases() from public, anon, authenticated;
grant  execute on function expire_group_purchases() to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin perform cron.unschedule('studiior-group-expiry'); exception when others then null; end;
    perform cron.schedule('studiior-group-expiry', '35 3 * * *',
      $c$select expire_group_purchases()$c$);
  end if;
end $$;

-- =============================================================================
-- Anon surface stays EXACTLY THIRTEEN (every new function is authenticated or
-- service-role; the group tables are RLS-guarded, not RPCs).
-- =============================================================================
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % functions, expected exactly 13', n; end if;
end $$;
