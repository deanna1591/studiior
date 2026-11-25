-- creates: plan_is_intro_offer(uuid), plan_guest_email_payload(uuid), plan_purchase_activate_run(uuid, uuid), plan_buy_begin(uuid, uuid, text, text, text), plan_guest_intro_ok(uuid, uuid), claim_waiting_plans_run(uuid, uuid, text), claim_waiting_plans(uuid), record_guest_intro_refund(uuid, text), my_guest_plans(uuid), guest_purchases_unclaimed(uuid), resend_plan_claim(uuid), sweep_plan_claim_reminders(), refund_payment_run(uuid, int, text, text, text), studio_by_slug(text, boolean)
-- re-issues: guard_member_self_update(), xendit_activate_success_internal(uuid, text, text), refund_payment(uuid, int, text, text, text), sales_history(uuid, date, date, uuid, text), daily_money_check(uuid)
--
-- Decision 118: buy a plan before you have an account.
--
-- WHERE THE PURCHASE LIVES. On xendit_purchases, not a separate holds table:
-- the purchase row already carries the plan, the price fixed at begin (list,
-- promotion, discount) and the Xendit references, so a guest purchase is one
-- row with the buyer's name, email and phone added, and every reader that
-- already knows a purchase needs no new join. member_id stays null until the
-- plan is claimed; guest_status says where it stands:
--   held           paid, waiting for an account with that email
--   claimed        attached to a member (validity from the claim day)
--   refund_pending an intro offer the claimer was not eligible for; the
--                  server refunds it through Xendit
--   refunded       refunded before it was claimed (the waiting plan is gone)
--
-- THE PUBLIC SURFACE. plan_buy_begin is the fifteenth anon function, built
-- like gift_card_begin: validates the plan, fixes the price from
-- plan_price_now_run, rate-limits per studio and per email, writes only a
-- pending purchase, and returns what the server needs to open the Xendit
-- checkout (the encrypted key is decrypted only in the server runtime; the
-- browser receives the checkout link). studio_by_slug, already public, gains
-- p_with_plans so /buy can list the plans; it is dropped and recreated, so the
-- count of anon functions is exactly fifteen, plus the resend_webhook_inbox
-- insert-only table.
--
-- ACTIVATION. The webhook's plan branch is moved, verbatim, into
-- plan_purchase_activate_run so the webhook and the claim activate a paid
-- plan the same way. A guest purchase is held, unless an account with that
-- email exists and the plan is not an intro offer, in which case it attaches
-- at once. An intro offer is always decided at claim, signed in, under the
-- same rules as checkout start (once ever, and the intro window when the
-- studio makes the offer exclusive).
--
-- REFUNDS. refund_payment is split into refund_payment_run (no caller check,
-- service only) and the manager-only wrapper. A refund before claim cancels
-- the waiting plan. The intro offer refund at claim is made by the server
-- (Xendit) and recorded through record_guest_intro_refund, which checks the
-- caller is the verified buyer.

-- ---- Columns -----------------------------------------------------------------
alter table xendit_purchases
  add column if not exists buyer_email text,
  add column if not exists buyer_name text,
  add column if not exists buyer_phone text,
  add column if not exists guest_status text,
  add column if not exists guest_payment_id uuid references payments(id),
  add column if not exists claimed_at timestamptz,
  add column if not exists claimed_member_id uuid references members(id);

alter table xendit_purchases drop constraint if exists xendit_purchases_guest_status_check;
alter table xendit_purchases add constraint xendit_purchases_guest_status_check
  check (guest_status is null or guest_status in ('held', 'claimed', 'refund_pending', 'refunded'));

create index if not exists xendit_purchases_guest_waiting
  on xendit_purchases (studio_id, lower(buyer_email))
  where guest_status in ('held', 'refund_pending');

-- ---- plan_is_intro_offer -----------------------------------------------------
-- An intro offer is a trial plan or the studio's chosen intro offer plan.
create or replace function plan_is_intro_offer(p_plan_id uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select mp.type = 'trial'
                       or mp.id = (select ss.intro_offer_plan_id from studio_settings ss
                                    where ss.studio_id = mp.studio_id)
                     from membership_plans mp where mp.id = p_plan_id), false)
$$;
revoke execute on function plan_is_intro_offer(uuid) from public, anon, authenticated;
grant  execute on function plan_is_intro_offer(uuid) to service_role;

-- ---- plan_guest_email_payload --------------------------------------------------
-- The one payload for plan_waiting_claim, plan_claim_reminder and
-- plan_in_account, so the three emails always say the same thing.
create or replace function plan_guest_email_payload(p_purchase_id uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'to_email', xp.buyer_email,
    'first_name', coalesce(nullif(split_part(btrim(coalesce(xp.buyer_name, '')), ' ', 1), ''), 'there'),
    'plan_name', mp.name,
    'amount', fmt_money(xp.amount_cents, xp.currency),
    'studio_name', s.name,
    'claim_url', member_portal_url(xp.studio_id, '/signup'),
    'login_url', member_portal_url(xp.studio_id, '/login'),
    'account_url', member_portal_url(xp.studio_id, '/account/plan'))
    from xendit_purchases xp
    join membership_plans mp on mp.id = xp.plan_id
    join studios s on s.id = xp.studio_id
   where xp.id = p_purchase_id
$$;
revoke execute on function plan_guest_email_payload(uuid) from public, anon, authenticated;
grant  execute on function plan_guest_email_payload(uuid) to service_role;

-- ---- guard_member_self_update: re-issued (20260833520000:337), + plan_claim
create or replace function guard_member_self_update()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  owned constant text[] := array[
    'preferred_name', 'phone', 'avatar_url', 'emergency_contact',
    'address', 'date_of_birth', 'marketing_opt_in', 'updated_at'
  ];
  waiver_cols constant text[] := array['waiver_signed_at', 'updated_at'];
  health_cols constant text[] := array['health_band', 'health_reason',
                                       'health_signals', 'health_computed_at', 'updated_at'];
  desk_pay_cols constant text[] := array['desk_pay_blocked_at', 'desk_pay_blocked_reason', 'updated_at'];
  -- Decision 114: the member turns marketing back on under Account -> Emails.
  marketing_cols constant text[] := array['marketing_opt_in', 'marketing_unsubscribed_at', 'updated_at'];
  -- Decision 118: claiming a paid plan makes a lead active (Decision 15). NARROW.
  claim_cols constant text[] := array['status', 'updated_at'];
  -- Decision 69 / 97: the exact set the scrub (and a merge) sets. NARROW.
  delete_cols constant text[] := array[
    'first_name', 'last_name', 'email', 'phone', 'date_of_birth', 'avatar_url',
    'address', 'emergency_contact', 'preferred_name', 'source', 'status',
    'marketing_opt_in', 'marketing_unsubscribed_at',
    'health_band', 'health_reason', 'health_signals', 'health_computed_at',
    'deleted_at', 'merged_into', 'merged_at', 'user_id', 'updated_at'
  ];
begin
  if is_service_context() then
    return new;
  end if;
  if coalesce(current_setting('studiior.waiver_signing', true), '') = '1' then
    if (to_jsonb(new) - waiver_cols) <> (to_jsonb(old) - waiver_cols) then
      raise exception 'waiver signing may set only the signature timestamp'
        using errcode = 'PT403';
    end if;
    return new;
  end if;
  if coalesce(current_setting('studiior.checkin_health', true), '') = '1' then
    if (to_jsonb(new) - health_cols) <> (to_jsonb(old) - health_cols) then
      raise exception 'the check-in health cascade may set only the health columns'
        using errcode = 'PT403';
    end if;
    return new;
  end if;
  if coalesce(current_setting('studiior.account_deleting', true), '') = '1' then
    if (to_jsonb(new) - delete_cols) <> (to_jsonb(old) - delete_cols) then
      raise exception 'account deletion may set only the scrub columns'
        using errcode = 'PT403';
    end if;
    return new;
  end if;
  if coalesce(current_setting('studiior.desk_pay_system', true), '') = '1' then
    if (to_jsonb(new) - desk_pay_cols) <> (to_jsonb(old) - desk_pay_cols) then
      raise exception 'the desk-pay block may set only the desk-pay columns'
        using errcode = 'PT403';
    end if;
    return new;
  end if;
  if coalesce(current_setting('studiior.marketing_consent', true), '') = '1' then
    if (to_jsonb(new) - marketing_cols) <> (to_jsonb(old) - marketing_cols) then
      raise exception 'a marketing consent change may set only the marketing columns'
        using errcode = 'PT403';
    end if;
    return new;
  end if;
  if coalesce(current_setting('studiior.plan_claim', true), '') = '1' then
    if (to_jsonb(new) - claim_cols) <> (to_jsonb(old) - claim_cols) then
      raise exception 'claiming a plan may set only the member status'
        using errcode = 'PT403';
    end if;
    return new;
  end if;
  if is_desk_up(new.studio_id) then
    return new;
  end if;
  if old.user_id is null then
    return new;
  end if;
  if auth.uid() is null or old.user_id is distinct from auth.uid() then
    return new;
  end if;
  if (to_jsonb(new) - owned) <> (to_jsonb(old) - owned) then
    raise exception 'a member may change their own contact details, not their membership'
      using errcode = 'PT403',
            hint = 'Editable by the member: ' || array_to_string(owned, ', ')
                   || '. Everything else is the studio''s to set.';
  end if;
  return new;
end $function$;

-- ---- plan_purchase_activate_run -------------------------------------------
create or replace function plan_purchase_activate_run(p_purchase_id uuid, p_member_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare p xendit_purchases%rowtype; v_ms uuid; v_group uuid; v_is_group boolean;
begin
  select * into p from xendit_purchases where id = p_purchase_id;
  if p.id is null or p.plan_id is null then raise exception 'no such plan purchase' using errcode = 'PT404'; end if;
  p.member_id := p_member_id;
  -- Moved verbatim from xendit_activate_success_internal's plan branch
  -- (20260833680000) so the webhook and the Decision 118 claim activate a paid
  -- plan the same way. The payment row stays with each caller.
  select type = 'group' into v_is_group from membership_plans where id = p.plan_id;
  if v_is_group then
    v_group := activate_purchase(p.studio_id, p.member_id, p.plan_id, p.amount_cents, p.currency, null, null, false);
  else
    if p.renews_membership_id is not null and exists (
         select 1 from memberships where id = p.renews_membership_id
            and status in ('active', 'past_due') and not membership_frozen_now(id)) then
      v_ms := p.renews_membership_id;
      perform advance_membership_period_run(p.renews_membership_id);
    else
      v_ms := activate_purchase(p.studio_id, p.member_id, p.plan_id, p.amount_cents, p.currency,
                                null, null, false);
      update memberships set auto_renew = false where id = v_ms;
      -- Decision 117(a): a recurring membership bought on sale keeps the list
      -- price as its rate; the discount belongs to this period's payment.
      if p.promotion_id is not null and p.list_price_cents is not null then
        update memberships ms set price_cents = p.list_price_cents
          from membership_plans pl
         where ms.id = v_ms and pl.id = ms.plan_id and pl.type = 'recurring';
      end if;
    end if;

    perform apply_plan_to_unpaid(p.studio_id, p.member_id, v_ms);
  end if;
  return jsonb_build_object('membership_id', v_ms, 'group_purchase_id', v_group);
end $$;
revoke execute on function plan_purchase_activate_run(uuid, uuid) from public, anon, authenticated;
grant  execute on function plan_purchase_activate_run(uuid, uuid) to service_role;

-- ---- plan_buy_begin: the fifteenth anon function ------------------------------
-- Built like gift_card_begin. Validates the plan, fixes the price now, rate
-- limits, writes ONLY a pending purchase, and hands the server what it needs to
-- open the Xendit checkout. It never returns member data.
create or replace function plan_buy_begin(
  p_studio_id uuid, p_plan_id uuid,
  p_buyer_name text default null, p_buyer_email text default null, p_buyer_phone text default null
) returns table(purchase_id uuid, amount_cents int, currency char(3),
                secret_key_ciphertext text, test_mode boolean, apple_pay_verified boolean, plan_name text)
language plpgsql security definer set search_path = public as $$
declare mp membership_plans%rowtype; ss studio_settings%rowtype; v_country text;
        v_email text; v_name text; v_phone text; v_pr jsonb; v_price int; v_promo uuid;
        v_list int; v_disc int; v_id uuid;
begin
  if not exists (select 1 from studios where id = p_studio_id and status = 'active') then
    raise exception 'no such studio' using errcode = 'PT404';
  end if;
  if not exists (select 1 from studio_payment_providers where studio_id = p_studio_id and provider = 'xendit') then
    raise exception 'this studio is not set up to take online payments' using errcode = 'PT409';
  end if;
  select * into mp from membership_plans where id = p_plan_id and studio_id = p_studio_id;
  if mp.id is null or mp.status <> 'active' or mp.visibility <> 'public'
     or mp.type not in ('class_pack', 'drop_in', 'trial', 'recurring', 'group') then
    raise exception 'that plan is not on sale' using errcode = 'PT404';
  end if;
  select * into ss from studio_settings where studio_id = p_studio_id;
  if mp.max_active_members is not null and coalesce(ss.seat_caps_enabled, false)
     and plan_seats_taken(mp.id) >= mp.max_active_members then
    raise exception '% is full.', mp.name using errcode = 'PT409';
  end if;

  v_name := nullif(btrim(coalesce(p_buyer_name, '')), '');
  v_email := lower(nullif(btrim(coalesce(p_buyer_email, '')), ''));
  if v_name is null or length(v_name) > 120 then
    raise exception 'a name is needed' using errcode = 'PT422';
  end if;
  if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 254 then
    raise exception 'an email address is needed' using errcode = 'PT422';
  end if;
  select country into v_country from studios where id = p_studio_id;
  v_phone := normalise_phone(p_buyer_phone, v_country);
  if nullif(btrim(coalesce(v_phone, '')), '') is null
     or (v_country = 'PH' and v_phone !~ '^\+639[0-9]{9}$')
     or (coalesce(v_country,'') <> 'PH'
         and length(regexp_replace(coalesce(v_phone,''), '[^0-9]', '', 'g')) not between 7 and 15) then
    raise exception 'that does not look like a mobile number' using errcode = 'PT422';
  end if;

  if (select count(*) from xendit_purchases xp where xp.studio_id = p_studio_id
        and xp.buyer_email is not null and xp.created_at > now() - interval '1 minute') >= 10 then
    raise exception 'too many right now, try again in a minute' using errcode = 'PT429';
  end if;
  if (select count(*) from xendit_purchases xp where xp.studio_id = p_studio_id
        and lower(xp.buyer_email) = v_email and xp.created_at > now() - interval '1 minute') >= 3 then
    raise exception 'too many right now, try again in a minute' using errcode = 'PT429';
  end if;

  -- Decision 117: the price is fixed now, from the promotion in force.
  v_pr := plan_price_now_run(p_plan_id, now());
  v_price := (v_pr ->> 'price_cents')::int;
  v_promo := nullif(v_pr ->> 'promotion_id', '')::uuid;
  v_list  := case when v_promo is not null then (v_pr ->> 'list_cents')::int end;
  v_disc  := case when v_promo is not null then (v_pr ->> 'discount_cents')::int end;

  insert into xendit_purchases (studio_id, member_id, plan_id, amount_cents, currency,
                                list_price_cents, promotion_id, discount_cents,
                                buyer_email, buyer_name, buyer_phone)
  values (p_studio_id, null, p_plan_id, v_price, mp.currency, v_list, v_promo, v_disc,
          v_email, v_name, v_phone)
  returning id into v_id;

  return query
    select v_id, v_price, mp.currency, spp.secret_key_ciphertext, spp.test_mode,
           coalesce(ss.gift_apple_pay_verified, false), mp.name
      from studio_payment_providers spp
     where spp.studio_id = p_studio_id and spp.provider = 'xendit';
end $$;
revoke execute on function plan_buy_begin(uuid, uuid, text, text, text) from public;
grant  execute on function plan_buy_begin(uuid, uuid, text, text, text) to anon, authenticated, service_role;

-- ---- plan_guest_intro_ok -------------------------------------------------------
-- The checkout-start rules for an intro offer, applied at claim: once ever (a
-- trial plan), and the intro window when the studio makes the offer exclusive.
create or replace function plan_guest_intro_ok(p_plan_id uuid, p_member_id uuid)
returns boolean
language plpgsql security definer set search_path = public as $$
declare mp membership_plans%rowtype; ss studio_settings%rowtype;
begin
  select * into mp from membership_plans where id = p_plan_id;
  if mp.id is null then return false; end if;
  select * into ss from studio_settings where studio_id = mp.studio_id;
  if mp.type = 'trial' and exists (
       select 1 from memberships ms join membership_plans mp2 on mp2.id = ms.plan_id
        where ms.member_id = p_member_id and ms.studio_id = mp.studio_id and mp2.type = 'trial') then
    return false;
  end if;
  if p_plan_id = ss.intro_offer_plan_id and coalesce(ss.intro_offer_exclusive, false)
     and not coalesce((intro_window(p_member_id) ->> 'active')::boolean, false) then
    return false;
  end if;
  return true;
end $$;
revoke execute on function plan_guest_intro_ok(uuid, uuid) from public, anon, authenticated;
grant  execute on function plan_guest_intro_ok(uuid, uuid) to service_role;

-- ---- claim_waiting_plans_run ---------------------------------------------------
-- Attach every plan waiting under this email to this member. Validity starts
-- today (activate_purchase dates from the studio's today). An intro offer the
-- member is not eligible for is not attached; it is marked refund_pending and
-- returned so the server refunds it through Xendit. The buyer's phone fills an
-- empty phone, which runs the free-first same-person check (members_phone_recheck).
create or replace function claim_waiting_plans_run(p_member_id uuid, p_studio_id uuid, p_email text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare xp xendit_purchases%rowtype; v_claimed jsonb := '[]'::jsonb; v_refunds jsonb := '[]'::jsonb;
        v_act jsonb; v_ms uuid; v_group uuid; v_phone text; v_name text;
begin
  if p_email is null then return jsonb_build_object('claimed', v_claimed, 'refunds', v_refunds); end if;
  for xp in
    select * from xendit_purchases
     where studio_id = p_studio_id and guest_status = 'held' and lower(buyer_email) = lower(p_email)
     order by completed_at nulls last, created_at
     for update
  loop
    select name into v_name from membership_plans where id = xp.plan_id;
    if exists (select 1 from payment_refunds pr where pr.payment_id = xp.guest_payment_id) then
      continue;
    end if;
    if plan_guest_intro_ok(xp.plan_id, p_member_id) then
      -- Decision 15 makes a lead active when a membership is created; the
      -- member is the caller here, so the guard needs the narrow claim flag.
      perform set_config('studiior.plan_claim', '1', true);
      v_act := plan_purchase_activate_run(xp.id, p_member_id);
      perform set_config('studiior.plan_claim', '', true);
      v_ms := nullif(v_act ->> 'membership_id', '')::uuid;
      v_group := nullif(v_act ->> 'group_purchase_id', '')::uuid;
      update payments set member_id = p_member_id, membership_id = v_ms, group_purchase_id = v_group
       where id = xp.guest_payment_id;
      update xendit_purchases
         set member_id = p_member_id, guest_status = 'claimed', claimed_at = now(),
             claimed_member_id = p_member_id, updated_at = now()
       where id = xp.id;
      insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
      values (p_studio_id, auth.uid(), 'plan.guest_claimed', 'xendit_purchases', xp.id,
              jsonb_build_object('member_id', p_member_id, 'plan_id', xp.plan_id,
                                 'membership_id', v_ms, 'group_purchase_id', v_group));
      v_claimed := v_claimed || jsonb_build_object('purchase_id', xp.id, 'plan_name', v_name);
    else
      update xendit_purchases set guest_status = 'refund_pending', claimed_member_id = p_member_id,
             updated_at = now()
       where id = xp.id;
      insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
      values (p_studio_id, auth.uid(), 'plan.guest_intro_refused', 'xendit_purchases', xp.id,
              jsonb_build_object('member_id', p_member_id, 'plan_id', xp.plan_id));
    end if;
    v_phone := coalesce(v_phone, xp.buyer_phone);
  end loop;

  -- Every intro offer still waiting for its refund for this buyer (this claim's,
  -- and one whose earlier refund did not go through).
  select coalesce(jsonb_agg(jsonb_build_object(
           'purchase_id', x.id, 'payment_id', x.guest_payment_id,
           'xendit_payment_id', x.xendit_payment_id, 'amount_cents', x.amount_cents,
           'currency', x.currency, 'plan_name', mp.name) order by x.created_at), '[]'::jsonb)
    into v_refunds
    from xendit_purchases x join membership_plans mp on mp.id = x.plan_id
   where x.studio_id = p_studio_id and x.guest_status = 'refund_pending'
     and lower(x.buyer_email) = lower(p_email);

  if v_phone is not null then
    update members set phone = v_phone
     where id = p_member_id and nullif(btrim(coalesce(phone, '')), '') is null;
  end if;

  return jsonb_build_object('claimed', v_claimed, 'refunds', v_refunds);
end $$;
revoke execute on function claim_waiting_plans_run(uuid, uuid, text) from public, anon, authenticated;
grant  execute on function claim_waiting_plans_run(uuid, uuid, text) to service_role;

-- ---- claim_waiting_plans: the signed-in wrapper ---------------------------------
-- Claim requires a VERIFIED email. When an intro offer needs refunding, the
-- result carries the studio's encrypted Xendit key for the server (decrypted
-- only in the server runtime, as at checkout).
create or replace function claim_waiting_plans(p_studio_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_member uuid; v_email text; v_conf timestamptz; v jsonb; v_key text;
begin
  select id into v_member from members
   where studio_id = p_studio_id and user_id = auth.uid() and deleted_at is null;
  if v_member is null then
    raise exception 'you are not a member of that studio' using errcode = 'PT403';
  end if;
  select email, email_confirmed_at into v_email, v_conf from auth.users where id = auth.uid();
  if v_conf is null then
    return jsonb_build_object('ok', false, 'reason', 'email_not_verified',
                              'claimed', '[]'::jsonb, 'refunds', '[]'::jsonb);
  end if;
  v := claim_waiting_plans_run(v_member, p_studio_id, v_email);
  if jsonb_array_length(v -> 'refunds') > 0 then
    select spp.secret_key_ciphertext into v_key
      from studio_payment_providers spp where spp.studio_id = p_studio_id and spp.provider = 'xendit';
  end if;
  return v || jsonb_build_object('ok', true, 'secret_key_ciphertext', v_key);
end $$;
revoke execute on function claim_waiting_plans(uuid) from public, anon;
grant  execute on function claim_waiting_plans(uuid) to authenticated, service_role;

-- ---- record_guest_intro_refund ---------------------------------------------------
-- After the server has made the Xendit refund for an intro offer the claimer
-- was not eligible for, record it (pending; the refund webhook settles it) and
-- tell the buyer. Only the verified buyer may record their own.
create or replace function record_guest_intro_refund(p_purchase_id uuid, p_reference text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare xp xendit_purchases%rowtype; v_member uuid; v_email text; v_conf timestamptz; v_r jsonb;
        v_first text;
begin
  select * into xp from xendit_purchases where id = p_purchase_id for update;
  if xp.id is null then raise exception 'no such purchase' using errcode = 'PT404'; end if;
  select email, email_confirmed_at into v_email, v_conf from auth.users where id = auth.uid();
  select id, first_name into v_member, v_first from members
   where studio_id = xp.studio_id and user_id = auth.uid() and deleted_at is null;
  if v_member is null or v_conf is null or lower(coalesce(v_email, '')) <> lower(coalesce(xp.buyer_email, '')) then
    raise exception 'that is not your purchase' using errcode = 'PT403';
  end if;
  if xp.guest_status <> 'refund_pending' then
    raise exception 'that purchase is not waiting for a refund' using errcode = 'PT409';
  end if;
  v_r := refund_payment_run(xp.guest_payment_id, null,
           'Intro offer: the buyer has had theirs', 'xendit', p_reference);
  perform queue_notification(xp.studio_id, v_member, 'intro_offer_refunded',
    plan_guest_email_payload(xp.id) || jsonb_build_object('first_name', coalesce(v_first, 'there'),
      'plans_url', member_portal_url(xp.studio_id, '/account/plan')),
    'intro_offer_refunded:' || xp.id::text);
  return v_r;
end $$;
revoke execute on function record_guest_intro_refund(uuid, text) from public, anon;
grant  execute on function record_guest_intro_refund(uuid, text) to authenticated, service_role;

-- ---- my_guest_plans: what Home shows -------------------------------------------
-- waiting: paid under this member's verified email, not yet in the account.
-- ready: claimed by this member in the last day ("Your {plan} is ready").
create or replace function my_guest_plans(p_studio_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_member uuid; v_email text; v_conf timestamptz;
begin
  select id into v_member from members
   where studio_id = p_studio_id and user_id = auth.uid() and deleted_at is null;
  if v_member is null then
    raise exception 'you are not a member of that studio' using errcode = 'PT403';
  end if;
  select email, email_confirmed_at into v_email, v_conf from auth.users where id = auth.uid();
  return jsonb_build_object(
    'waiting', case when v_conf is null then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object('purchase_id', xp.id, 'plan_name', mp.name) order by xp.created_at)
        from xendit_purchases xp join membership_plans mp on mp.id = xp.plan_id
       where xp.studio_id = p_studio_id and xp.guest_status in ('held', 'refund_pending')
         and lower(xp.buyer_email) = lower(v_email)), '[]'::jsonb) end,
    'ready', coalesce((
      select jsonb_agg(jsonb_build_object('purchase_id', xp.id, 'plan_name', mp.name) order by xp.claimed_at)
        from xendit_purchases xp join membership_plans mp on mp.id = xp.plan_id
       where xp.studio_id = p_studio_id and xp.claimed_member_id = v_member
         and xp.guest_status = 'claimed' and xp.claimed_at > now() - interval '1 day'), '[]'::jsonb));
end $$;
revoke execute on function my_guest_plans(uuid) from public, anon;
grant  execute on function my_guest_plans(uuid) to authenticated, service_role;

-- ---- guest_purchases_unclaimed: the staff list ------------------------------------
create or replace function guest_purchases_unclaimed(p_studio_id uuid)
returns table(purchase_id uuid, payment_id uuid, buyer_name text, buyer_email text, buyer_phone text,
              plan_name text, amount_cents int, currency char(3), paid_at timestamptz,
              days_waiting int, status text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not (coalesce(is_manager_up(p_studio_id), false) or is_service_context()) then
    raise exception 'this list is for owners and managers' using errcode = 'PT403';
  end if;
  return query
    select xp.id, xp.guest_payment_id, xp.buyer_name, xp.buyer_email, xp.buyer_phone,
           mp.name, xp.amount_cents, xp.currency, coalesce(xp.completed_at, xp.created_at),
           (extract(epoch from now() - coalesce(xp.completed_at, xp.created_at)) / 86400)::int,
           xp.guest_status
      from xendit_purchases xp join membership_plans mp on mp.id = xp.plan_id
     where xp.studio_id = p_studio_id and xp.guest_status in ('held', 'refund_pending')
     order by coalesce(xp.completed_at, xp.created_at);
end $$;
revoke execute on function guest_purchases_unclaimed(uuid) from public, anon;
grant  execute on function guest_purchases_unclaimed(uuid) to authenticated, service_role;

-- ---- resend_plan_claim ---------------------------------------------------------------
create or replace function resend_plan_claim(p_purchase_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare xp xendit_purchases%rowtype;
begin
  select * into xp from xendit_purchases where id = p_purchase_id;
  if xp.id is null then raise exception 'no such purchase' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(xp.studio_id), false) then
    raise exception 'resending is the owner''s or a manager''s to do' using errcode = 'PT403';
  end if;
  if coalesce(xp.guest_status, '') <> 'held' then
    raise exception 'that plan is not waiting for an account' using errcode = 'PT409';
  end if;
  perform queue_notification(xp.studio_id, null, 'plan_claim_reminder', plan_guest_email_payload(xp.id),
    'plan_claim_resend:' || xp.id::text || ':' || floor(extract(epoch from clock_timestamp()) * 1000)::bigint::text);
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (xp.studio_id, auth.uid(), 'plan.guest_claim_resent', 'xendit_purchases', xp.id,
          jsonb_build_object('to_email', xp.buyer_email));
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function resend_plan_claim(uuid) from public, anon;
grant  execute on function resend_plan_claim(uuid) to authenticated, service_role;

-- ---- sweep_plan_claim_reminders: 2 days and 7 days -------------------------------------
create or replace function sweep_plan_claim_reminders()
returns int
language plpgsql security definer set search_path = public as $$
declare xp record; n int := 0; v_id uuid;
begin
  if not is_service_context() then
    raise exception 'the reminder sweep runs as the service' using errcode = 'PT403';
  end if;
  for xp in
    select x.id, x.studio_id, x.completed_at from xendit_purchases x
     where x.guest_status = 'held' and x.completed_at <= now() - interval '2 days'
  loop
    v_id := queue_notification(xp.studio_id, null, 'plan_claim_reminder', plan_guest_email_payload(xp.id),
              'plan_claim_reminder:2:' || xp.id::text);
    if v_id is not null then n := n + 1; end if;
    if xp.completed_at <= now() - interval '7 days' then
      v_id := queue_notification(xp.studio_id, null, 'plan_claim_reminder', plan_guest_email_payload(xp.id),
                'plan_claim_reminder:7:' || xp.id::text);
      if v_id is not null then n := n + 1; end if;
    end if;
  end loop;
  return n;
end $$;
revoke execute on function sweep_plan_claim_reminders() from public, anon, authenticated;
grant  execute on function sweep_plan_claim_reminders() to service_role;

select cron.schedule('studiior-plan-claim-reminders', '17 * * * *', 'select sweep_plan_claim_reminders()')
 where not exists (select 1 from cron.job where jobname = 'studiior-plan-claim-reminders');

-- ---- xendit_activate_success_internal: re-issued (20260833680000:714) -----
create or replace function xendit_activate_success_internal(p_purchase_id uuid, p_payment_id text, p_source text default 'xendit')
returns text
language plpgsql security definer set search_path = public as $$
declare p xendit_purchases%rowtype; v_ms uuid; v_prior text;
        v_group uuid; v_is_group boolean;
        o product_orders%rowtype; prod products%rowtype;
        v_b bookings%rowtype; v_occ class_occurrences%rowtype; v_free int; v_pay_id uuid;
        gc gift_cards%rowtype; v_code text; v_prov payment_provider; v_src text; v_ref text; v_send timestamptz;
        v_held boolean := false; v_guest uuid; v_attached boolean := false; v_act jsonb;
begin
  select * into p from xendit_purchases where id = p_purchase_id for update;
  if p.id is null then return 'unknown_purchase'; end if;
  if p.status = 'succeeded' then return 'already_succeeded'; end if;
  v_prior := p.status;

  -- A full-credit (Decision 103(f)) completion: the payment row is source credit,
  -- provider manual, no processor reference.
  v_prov := case when p_source = 'credit' then 'manual'::payment_provider else 'xendit'::payment_provider end;
  v_src  := nullif(p_source, 'xendit');
  v_ref  := case when p_source = 'credit' then null else nullif(p_payment_id, '') end;

  if p.booking_id is not null then
    insert into payments (studio_id, member_id, booking_id, kind, amount_cents, currency,
                          status, provider, source, reference, description, paid_at)
    values (p.studio_id, p.member_id, p.booking_id, 'reservation_fee', p.amount_cents, p.currency,
            'succeeded', v_prov, v_src, v_ref, 'Reservation fee', now())
    returning id into v_pay_id;
    select * into v_b from bookings where id = p.booking_id;
    if v_b.status in ('booked', 'pending_payment') then
      perform book_first_free_run(p.booking_id);
    else
      select * into v_occ from class_occurrences where id = v_b.occurrence_id;
      v_free := coalesce(v_occ.capacity, 0) - occurrence_seats_taken(v_occ.id)
                - occurrence_seats_held(v_occ.id);
      if v_occ.id is not null and v_occ.status = 'scheduled'
         and v_occ.starts_at > now() and v_free >= 1 then
        perform restore_reservation_booking(p.booking_id);
      else
        insert into member_credits (studio_id, member_id, amount_cents, currency, reason,
                                    payment_id, booking_id)
        values (p.studio_id, p.member_id, p.amount_cents, p.currency, 'reservation_lost_seat',
                v_pay_id, p.booking_id);
        perform queue_notification(p.studio_id, p.member_id, 'free_reservation_lost_seat',
          jsonb_build_object('fee', fmt_money(p.amount_cents, p.currency),
            'class_name', coalesce(v_occ.name, 'a class'),
            'plans_url', member_portal_url(p.studio_id, '/account/plan')),
          'free_reservation_lost_seat:' || p.booking_id::text);
      end if;
    end if;

  elsif p.gift_card_id is not null then
    -- Decision 110: issue the gift card. Mint the code, record the sale (a real
    -- payment, so it counts in revenue once; linked by gift_card_id). Email the
    -- buyer at once; schedule the recipient for the delivery date (now when none).
    select * into gc from gift_cards where id = p.gift_card_id for update;
    v_code := gift_code(p.studio_id);
    -- Decision 110(a): the composited card image (amount + code over the studio's
    -- card) is served by the member host's next/og route; its path is stored on
    -- the card at issue and carried on gift_card_sent.
    update gift_cards set status = 'active', code = v_code, issued_at = now(),
           card_image_path = '/giftcard/' || gc.id::text || '/' || v_code || '/' || gc.amount_cents::text
     where id = gc.id and status in ('pending', 'active');

    insert into payments (studio_id, member_id, gift_card_id, kind, amount_cents, currency,
                          status, provider, source, reference, description, paid_at)
    values (p.studio_id, p.member_id, gc.id, 'gift_card', p.amount_cents, p.currency,
            'succeeded', v_prov, v_src, v_ref, 'Gift card', now());

    perform queue_notification(p.studio_id, gc.buyer_member_id, 'gift_card_receipt',
      jsonb_build_object('to_email', gc.buyer_email, 'buyer_name', coalesce(gc.buyer_name, 'there'),
        'recipient_name', coalesce(gc.recipient_name, 'your friend'),
        'code', v_code, 'amount', fmt_money(p.amount_cents, p.currency),
        'studio_name', (select name from studios where id = p.studio_id)),
      'gift_card_receipt:' || gc.id::text);

    v_send := case
      when gc.delivery_date is null then now()
      else greatest(now(),
        ((gc.delivery_date::text || ' 08:00')::timestamp
          at time zone (select timezone from studios where id = p.studio_id))) end;
    perform queue_notification(p.studio_id, gc.redeemed_by_member_id, 'gift_card_sent',
      jsonb_build_object('to_email', gc.recipient_email,
        'recipient_name', coalesce(gc.recipient_name, 'there'),
        'buyer_name', coalesce(gc.buyer_name, 'A friend'),
        'code', v_code, 'amount', fmt_money(p.amount_cents, p.currency),
        'message', coalesce(gc.message, ''),
        'message_html', case when coalesce(btrim(gc.message), '') = '' then ''
          else '<p style="font-style:italic;color:#57534e">&ldquo;' || replace(replace(replace(gc.message, '&', '&amp;'), '<', '&lt;'), '>', '&gt;') || '&rdquo;</p>' end,
        'card_image_url', member_portal_url(p.studio_id,
          '/giftcard/' || gc.id::text || '/' || v_code || '/' || gc.amount_cents::text),
        'redeem_url', member_portal_url(p.studio_id, '/account/redeem'),
        'studio_name', (select name from studios where id = p.studio_id)),
      'gift_card_sent:' || gc.id::text, v_send);

  elsif p.private_occurrence_id is not null then
    -- Decision 116: a full-paid private. Record the 'private' payment against the
    -- booker's seat (so Sales buckets it by the occurrence), then confirm the
    -- session at once (commit, flip seats, tell everyone, write the flat pay line).
    insert into payments (studio_id, member_id, booking_id, kind, amount_cents, currency,
                          status, provider, source, reference, description, paid_at)
    select p.studio_id, p.member_id, (select b.id from bookings b
             where b.occurrence_id = p.private_occurrence_id and b.payment_source = 'private'
             order by b.created_at limit 1),
           'private', p.amount_cents, p.currency, 'succeeded', v_prov, v_src, v_ref,
           'Private session', now()
    returning id into v_pay_id;
    select * into v_occ from class_occurrences where id = p.private_occurrence_id;
    if v_occ.status = 'scheduled' and v_occ.starts_at > now() then
      perform private_confirm_run(p.private_occurrence_id);
    else
      -- a late success on a private already released (expired session): the
      -- money is never lost, it lands as account credit (the 103(e) rule).
      insert into member_credits (studio_id, member_id, amount_cents, currency, reason, payment_id)
      values (p.studio_id, p.member_id, p.amount_cents, p.currency, 'private_refund', v_pay_id);
    end if;

  elsif p.product_order_id is not null then
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
                          status, provider, source, reference, description, paid_at)
    values (p.studio_id, p.member_id, o.id, p.amount_cents, p.currency, 'succeeded', v_prov,
            v_src, v_ref, prod.name || ' ×' || o.quantity, now());

    perform queue_notification(
      p.studio_id, p.member_id, 'product_order_paid',
      jsonb_build_object('product', prod.name, 'quantity', o.quantity),
      'product_order_paid:' || o.id::text);

  else
    -- Decision 118: a plan bought by somebody without an account. An existing
    -- account with that email (a login, in this studio) gets the plan at once,
    -- unless it is an intro offer, whose eligibility is decided at claim, signed
    -- in. Everyone else's plan is held under the email until they claim it.
    if p.member_id is null and p.buyer_email is not null then
      -- The login's own email must match and be verified (claim requires a
      -- verified email; an unverified sign-up never receives a paid plan).
      select m.id into v_guest from members m
        join auth.users u on u.id = m.user_id
       where m.studio_id = p.studio_id and m.deleted_at is null
         and u.email_confirmed_at is not null
         and lower(u.email) = lower(p.buyer_email)
       order by m.created_at limit 1;
      if v_guest is not null and not plan_is_intro_offer(p.plan_id) then
        p.member_id := v_guest;
        update xendit_purchases
           set member_id = v_guest, guest_status = 'claimed', claimed_at = now(), claimed_member_id = v_guest
         where id = p.id;
        -- The buyer's phone fills an empty phone, which runs the free-first
        -- same-person check (members_phone_recheck), as at claim.
        update members set phone = p.buyer_phone
         where id = v_guest and nullif(btrim(coalesce(phone, '')), '') is null;
        v_attached := true;
      else
        insert into payments (studio_id, member_id, amount_cents, currency,
                              status, provider, source, reference, description, paid_at,
                              list_price_cents, promotion_id, discount_cents)
        select p.studio_id, null, p.amount_cents, p.currency, 'succeeded', v_prov,
               v_src, v_ref, mp.name, now(), p.list_price_cents, p.promotion_id, p.discount_cents
          from membership_plans mp where mp.id = p.plan_id
        returning id into v_pay_id;
        update xendit_purchases set guest_status = 'held', guest_payment_id = v_pay_id where id = p.id;
        perform queue_notification(p.studio_id, null, 'plan_waiting_claim',
          plan_guest_email_payload(p.id), 'plan_waiting_claim:' || p.id::text);
        v_held := true;
      end if;
    end if;

    if not v_held then
      v_act := plan_purchase_activate_run(p.id, p.member_id);
      v_group := nullif(v_act ->> 'group_purchase_id', '')::uuid;
      v_ms := nullif(v_act ->> 'membership_id', '')::uuid;
      if v_group is not null then
        insert into payments (studio_id, member_id, group_purchase_id, amount_cents, currency,
                              status, provider, source, reference, description, paid_at,
                              list_price_cents, promotion_id, discount_cents)
        select p.studio_id, p.member_id, v_group, p.amount_cents, p.currency, 'succeeded', v_prov,
               v_src, v_ref, mp.name, now(), p.list_price_cents, p.promotion_id, p.discount_cents
          from membership_plans mp where mp.id = p.plan_id;
      else
        insert into payments (studio_id, member_id, membership_id, amount_cents, currency,
                              status, provider, source, reference, description, paid_at,
                              list_price_cents, promotion_id, discount_cents)
        select p.studio_id, p.member_id, v_ms, p.amount_cents, p.currency, 'succeeded', v_prov,
               v_src, v_ref, mp.name, now(), p.list_price_cents, p.promotion_id, p.discount_cents
          from membership_plans mp where mp.id = p.plan_id;
      end if;
      if v_attached then
        perform queue_notification(p.studio_id, p.member_id, 'plan_in_account',
          plan_guest_email_payload(p.id), 'plan_in_account:' || p.id::text);
      end if;
    end if;
  end if;

  -- ONE consume: a plan/product (and reservation, when not via reserve_free_first)
  -- purchase consumes any reservation/gift credit applied at begin. A gift sale
  -- never carries credit_applied, so this is a no-op there.
  if p.credit_applied_cents > 0 then
    perform consume_reservation_credit(p.studio_id, p.member_id, p.credit_applied_cents);
  end if;

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
revoke execute on function xendit_activate_success_internal(uuid, text, text) from public, anon, authenticated;
grant  execute on function xendit_activate_success_internal(uuid, text, text) to service_role;

-- ---- refund_payment_run + refund_payment wrapper (20260833580000:2232) ----
create or replace function refund_payment_run(
  p_payment_id uuid, p_amount_cents int default null, p_reason text default null,
  p_method text default null, p_reference text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pay payments%rowtype; v_amount int; v_remaining int; v_id uuid; v_ccy char(3);
begin
  select * into pay from payments where id = p_payment_id for update;
  if not found then raise exception 'no such payment' using errcode = 'PT404'; end if;
  if pay.status not in ('succeeded', 'partially_refunded') then
    raise exception 'a % payment cannot be refunded', pay.status using errcode = 'PT409';
  end if;

  -- Decision 111: a reservation fee whose credit has been spent cannot be refunded.
  if pay.kind = 'reservation_fee'
     and exists (select 1 from member_credits mc
                  where mc.payment_id = pay.id and mc.voided_at is null and mc.used_cents > 0) then
    raise exception 'this fee was used as credit, so it cannot be refunded'
      using errcode = 'PT409';
  end if;

  -- Decision 110(a): a gift card that has been redeemed cannot be refunded (its
  -- value is already on somebody's account as gift credit).
  if pay.gift_card_id is not null
     and exists (select 1 from gift_cards gc where gc.id = pay.gift_card_id and gc.status = 'redeemed') then
    raise exception 'this gift card has been redeemed, so it cannot be refunded'
      using errcode = 'PT409';
  end if;

  v_remaining := pay.amount_cents - coalesce(pay.refunded_cents, 0);
  v_amount := coalesce(p_amount_cents, v_remaining);
  if v_amount <= 0 or v_amount > v_remaining then
    raise exception 'that is more than is left to refund' using errcode = 'PT400';
  end if;
  v_ccy := pay.currency;

  -- Decision 118: a refund before the plan is claimed cancels the waiting plan.
  update xendit_purchases set guest_status = 'refunded', updated_at = now()
   where guest_payment_id = pay.id and guest_status in ('held', 'refund_pending');

  if coalesce(p_method, '') = 'xendit' then
    -- The server action has already called POST /v3/refunds; p_reference is the
    -- rfd- id. Record pending; the webhook settles it.
    insert into payment_refunds (studio_id, payment_id, member_id, amount_cents, currency,
                                 reason, method, reference, status, xendit_refund_id, refunded_by)
    values (pay.studio_id, pay.id, pay.member_id, v_amount, v_ccy,
            p_reason, 'xendit', p_reference, 'pending', p_reference, auth.uid())
    returning id into v_id;
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (pay.studio_id, auth.uid(), 'payment.refunded', 'payments', pay.id,
            jsonb_build_object('refund_id', v_id, 'amount_cents', v_amount, 'method', 'xendit',
                               'reason', p_reason, 'reference', p_reference, 'status', 'pending'));
    return jsonb_build_object('ok', true, 'refund_id', v_id, 'status', 'pending', 'amount_cents', v_amount);
  else
    -- Studio-recorded: method required and valid, reference required.
    if coalesce(p_method, '') not in ('cash','bank_transfer','card_terminal','gcash','other') then
      raise exception 'unknown refund method' using errcode = 'PT400';
    end if;
    if coalesce(btrim(p_reference), '') = '' then
      raise exception 'a refund reference is required' using errcode = 'PT400';
    end if;
    insert into payment_refunds (studio_id, payment_id, member_id, amount_cents, currency,
                                 reason, method, reference, status, settled_at, refunded_by)
    values (pay.studio_id, pay.id, pay.member_id, v_amount, v_ccy,
            p_reason, p_method, p_reference, 'succeeded', now(), auth.uid())
    returning id into v_id;
    perform apply_payment_refund(v_id);
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (pay.studio_id, auth.uid(), 'payment.refunded', 'payments', pay.id,
            jsonb_build_object('refund_id', v_id, 'amount_cents', v_amount, 'method', p_method,
                               'reason', p_reason, 'reference', p_reference, 'status', 'succeeded'));
    return jsonb_build_object('ok', true, 'refund_id', v_id, 'status', 'succeeded', 'amount_cents', v_amount);
  end if;
end $$;
revoke execute on function refund_payment_run(uuid, int, text, text, text) from public, anon, authenticated;
grant  execute on function refund_payment_run(uuid, int, text, text, text) to service_role;

create or replace function refund_payment(
  p_payment_id uuid, p_amount_cents int default null, p_reason text default null,
  p_method text default null, p_reference text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_studio uuid;
begin
  select studio_id into v_studio from payments where id = p_payment_id;
  if v_studio is null then raise exception 'no such payment' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(v_studio), false) then
    raise exception 'refunds are the owner''s or a manager''s to make' using errcode = 'PT403';
  end if;
  return refund_payment_run(p_payment_id, p_amount_cents, p_reason, p_method, p_reference);
end $$;
revoke execute on function refund_payment(uuid, int, text, text, text) from public, anon;
grant  execute on function refund_payment(uuid, int, text, text, text) to authenticated, service_role;

-- ---- studio_by_slug: re-issued (20260833580000:2610), + p_with_plans, buy --
drop function if exists studio_by_slug(text);
create function studio_by_slug(p_slug text, p_with_plans boolean default false)
 returns table(id uuid, name text, slug text, timezone text, currency text, logo_url text,
   theme_preset theme_preset, accent_color text, login_image_url text,
   login_image_focus_x smallint, login_image_focus_y smallint,
   free_first_class_enabled boolean, login_tagline text, install_welcome text, time_format text,
   android_package text, android_sha256_fingerprints text, ios_team_id text, ios_bundle_id text,
   gift_enabled boolean, gift_presets int[], gift_min_cents int, gift_card_image_url text,
   buy jsonb)
 language sql stable security definer set search_path to 'public' as $function$
  select s.id, s.name, s.slug, s.timezone, s.currency,
         s.logo_url, s.theme_preset, s.accent_color, s.login_image_url,
         s.login_image_focus_x, s.login_image_focus_y,
         coalesce(ss.free_first_class_enabled, false),
         s.login_tagline, s.install_welcome,
         coalesce(ss.time_format, '24h'),
         s.android_package, s.android_sha256_fingerprints, s.ios_team_id, s.ios_bundle_id,
         coalesce(ss.gift_enabled, false),
         coalesce(ss.gift_presets, array[100000, 250000, 500000]),
         coalesce(ss.gift_min_cents, 50000),
         ss.gift_card_image_path,
         -- Decision 118: the plans anybody may buy, with today's price
         -- (plan_price_now_run, so a running promotion shows). Only when asked.
         case when p_with_plans then jsonb_build_object(
           'online', exists (select 1 from studio_payment_providers spp
                              where spp.studio_id = s.id and spp.provider = 'xendit'),
           'plans', coalesce((
             select jsonb_agg(jsonb_build_object(
                      'id', mp.id, 'name', mp.name, 'description', mp.description, 'type', mp.type,
                      'credits', mp.credits, 'validity_days', mp.validity_days,
                      'credits_per_period', mp.credits_per_period, 'billing_interval', mp.billing_interval,
                      'featured', mp.featured, 'badge', mp.badge, 'group_size', mp.group_size,
                      'private_pack', coalesce(mp.private_pack, false),
                      'full', coalesce(ss.seat_caps_enabled, false) and mp.max_active_members is not null
                              and plan_seats_taken(mp.id) >= mp.max_active_members,
                      'price', plan_price_now_run(mp.id, now()))
                    order by mp.featured desc, mp.sort_order, mp.name)
               from membership_plans mp
              where mp.studio_id = s.id and mp.status = 'active' and mp.visibility = 'public'
                and mp.type in ('class_pack', 'drop_in', 'trial', 'recurring', 'group')), '[]'::jsonb))
         end
    from studios s
    left join studio_settings ss on ss.studio_id = s.id
   where s.slug = p_slug and s.status = 'active'
$function$;
revoke execute on function studio_by_slug(text, boolean) from public;
grant  execute on function studio_by_slug(text, boolean) to anon, authenticated, service_role;

-- ---- sales_history: re-issued (20260833670000:806), + the waiting arm -----
create or replace function sales_history(
  p_studio_id uuid, p_from date, p_to date,
  p_plan_id uuid default null, p_status text default null
) returns table (
  membership_id uuid, member_id uuid, member_name text,
  plan_id uuid, plan_name text, plan_type text,
  amount_cents int, currency char(3), payment_source text,
  bought_on timestamptz, starts_on date, expires_on date, sale_status text,
  is_renewal boolean,
  discount_cents int, discount_pct int
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
           p.discount_cents, p.promotion_id,
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
          end) as sale_status,
         (select count(*) from payments p2
           where p2.membership_id = ms.id
             and p2.status in ('succeeded', 'partially_refunded')) > 1 as is_renewal,
         pay.discount_cents,
         (select pp.pct from plan_promotions pp where pp.id = pay.promotion_id) as discount_pct
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
               then 'refunded' else 'active' end) as sale_status,
         false as is_renewal, null::int, null::int
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

  union all

  select null::uuid, p.member_id,
         coalesce(m.first_name || ' ' || m.last_name, 'Walk-in') as member_name,
         null::uuid, ('Reservation · ' || coalesce(o.name, 'a class')) as plan_name,
         'reservation_fee' as plan_type,
         p.amount_cents, p.currency,
         (case when p.provider = 'xendit' then 'Card (Xendit)'
               when p.provider = 'stripe' then 'Card (Stripe)'
               when p.method = 'gcash' then 'GCash'
               when p.method = 'card_terminal' then 'Card (terminal)'
               when p.method = 'cash' then 'Cash'
               else 'Recorded' end) as payment_source,
         coalesce(p.paid_at, p.created_at) as bought_on,
         null::date, null::date,
         (case when p.status in ('refunded','partially_refunded') or coalesce(p.refunded_cents,0) > 0
               then 'refunded' else 'active' end) as sale_status,
         false as is_renewal, null::int, null::int
    from payments p
    left join bookings b on b.id = p.booking_id
    left join class_occurrences o on o.id = b.occurrence_id
    left join members m on m.id = p.member_id
   where p.studio_id = p_studio_id and p.kind = 'reservation_fee'
     and coalesce(p.method, '') <> 'reservation_credit'
     and p.status in ('succeeded','partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1
     and p_plan_id is null
     and (p_status is null or p_status = (case
            when p.status in ('refunded','partially_refunded') or coalesce(p.refunded_cents,0) > 0
            then 'refunded' else 'active' end))

  union all

  -- Decision 110: a gift card SALE (real cash; counted once, here). plan_type
  -- 'gift'; no membership, never a renewal. The redemption is NOT a sale.
  select null::uuid, p.member_id,
         coalesce(gc.buyer_name, 'Gift purchase') as member_name,
         null::uuid, ('Gift card · ' || coalesce(gc.recipient_name, gc.recipient_email, 'a friend')) as plan_name,
         'gift' as plan_type,
         p.amount_cents, p.currency,
         (case when p.provider = 'xendit' then 'Card (Xendit)'
               when p.provider = 'stripe' then 'Card (Stripe)'
               else 'Recorded' end) as payment_source,
         coalesce(p.paid_at, p.created_at) as bought_on,
         null::date, null::date,
         (case when p.status in ('refunded','partially_refunded') or coalesce(p.refunded_cents,0) > 0
               then 'refunded' else 'active' end) as sale_status,
         false as is_renewal, null::int, null::int
    from payments p
    join gift_cards gc on gc.id = p.gift_card_id
   where p.studio_id = p_studio_id and p.gift_card_id is not null
     and coalesce(p.source, '') <> 'credit'
     and p.status in ('succeeded','partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1
     and p_plan_id is null
     and (p_status is null or p_status = (case
            when p.status in ('refunded','partially_refunded') or coalesce(p.refunded_cents,0) > 0
            then 'refunded' else 'active' end))

  union all

  -- Decision 116: a private session sale (the booker's 'private' payment, cash
  -- or card; a source-credit rebook is not a sale). plan_type 'private'.
  select null::uuid, p.member_id,
         coalesce(m.first_name || ' ' || m.last_name, 'Walk-in') as member_name,
         null::uuid, ('Private · ' || coalesce(pst.name, 'session')) as plan_name,
         'private' as plan_type,
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
         (o.starts_at at time zone v_tz)::date, null::date,
         (case when p.status in ('refunded','partially_refunded') or coalesce(p.refunded_cents,0) > 0
               then 'refunded' else 'active' end) as sale_status,
         false as is_renewal, null::int, null::int
    from payments p
    join bookings b on b.id = p.booking_id
    join class_occurrences o on o.id = b.occurrence_id
    left join private_session_types pst on pst.id = o.private_type_id
    left join members m on m.id = p.member_id
   where p.studio_id = p_studio_id and p.kind = 'private'
     and coalesce(p.source, '') <> 'credit'
     and p.status in ('succeeded','partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1
     and p_plan_id is null
     and (p_status is null or p_status = (case
            when p.status in ('refunded','partially_refunded') or coalesce(p.refunded_cents,0) > 0
            then 'refunded' else 'active' end))

  union all

  -- Decision 118: a plan bought without an account and not yet claimed. Shown
  -- the day it was paid, marked waiting for account; once claimed the payment
  -- carries the membership and the first arm shows it instead.
  select null::uuid, null::uuid,
         coalesce(xp.buyer_name, xp.buyer_email) as member_name,
         mp.id, mp.name, mp.type::text,
         p.amount_cents, p.currency,
         'Card (Xendit)'::text as payment_source,
         coalesce(p.paid_at, p.created_at) as bought_on,
         null::date, null::date,
         (case when p.status in ('refunded','partially_refunded') or coalesce(p.refunded_cents,0) > 0
               then 'refunded' else 'waiting_account' end) as sale_status,
         false as is_renewal, p.discount_cents,
         (select pp.pct from plan_promotions pp where pp.id = p.promotion_id) as discount_pct
    from xendit_purchases xp
    join payments p on p.id = xp.guest_payment_id
    join membership_plans mp on mp.id = xp.plan_id
   where xp.studio_id = p_studio_id and xp.claimed_at is null
     and p.membership_id is null and p.group_purchase_id is null
     and p.status in ('succeeded','partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1
     and (p_plan_id is null or mp.id = p_plan_id)
     and (p_status is null or p_status = (case
            when p.status in ('refunded','partially_refunded') or coalesce(p.refunded_cents,0) > 0
            then 'refunded' else 'waiting_account' end))

  order by bought_on desc;
end $$;
revoke execute on function sales_history(uuid, date, date, uuid, text) from public, anon;
grant  execute on function sales_history(uuid, date, date, uuid, text) to authenticated, service_role;

-- ---- daily_money_check: re-issued (20260833700000), + items 17 and 18 -----
create or replace function daily_money_check(p_studio_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_tz text; v_items jsonb := '[]'::jsonb; v_html text := ''; v_text text := '';
  r record; v_n int; v_line text;
begin
  if not is_service_context() then
    raise exception 'the daily check runs as the backend' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;

  for r in
    -- 1. reservation fee paid, no seat, no credit
    select mname(b.member_id) || ': paid a reservation fee for ' || cname(b.occurrence_id)
           || ' but has no seat and no credit' as line
      from payments p
      join bookings b on b.id = p.booking_id
     where p.studio_id = p_studio_id and p.kind = 'reservation_fee'
       and p.status in ('succeeded','partially_refunded')
       and b.status in ('cancelled','late_cancelled')
       and not exists (select 1 from member_credits mc
                        where mc.booking_id = b.id and mc.reason = 'reservation_credit' and mc.voided_at is null)
    union all
    -- 2. a hold older than its window
    select mname(b.member_id) || ': the hold on ' || cname(b.occurrence_id)
           || ' expired ' || ago(b.hold_until) || ' and is still open'
      from bookings b
     where b.studio_id = p_studio_id and b.hold_until is not null and b.hold_until < now()
       and b.status in ('booked','pending_payment')
    union all
    -- 3. a succeeded payment attached to nothing
    select mname(p.member_id) || ': a succeeded payment of ' || money_txt(p.amount_cents, p.currency)
           || ' is attached to nothing'
      from payments p
     where p.studio_id = p_studio_id and p.status = 'succeeded'
       and p.membership_id is null and p.booking_id is null
       and p.product_order_id is null and p.group_purchase_id is null
       -- Decision 108 (b): a member-less payment (a gift card) is attached to its card.
       and p.member_id is not null
    union all
    -- 4. a member with an active plan still marked lead
    select mname(m.id) || ': has an active plan but is still marked lead'
      from members m
     where m.studio_id = p_studio_id and m.status = 'lead' and m.deleted_at is null
       and exists (select 1 from memberships ms where ms.member_id = m.id and ms.status = 'active')
    union all
    -- 5. a live booking in a cancelled or ended class
    select mname(b.member_id) || ': booked in ' || cname(b.occurrence_id)
           || case when o.status = 'cancelled' then ' which was cancelled' else ' which has already ended' end
      from bookings b join class_occurrences o on o.id = b.occurrence_id
     where b.studio_id = p_studio_id and b.status in ('booked','pending_payment')
       and (o.status = 'cancelled' or (o.status = 'scheduled' and o.ends_at < now()))
    union all
    -- 6. a member double-booked in one class
    select mname(x.member_id) || ': booked twice in ' || cname(x.occurrence_id)
      from (select member_id, occurrence_id from bookings
             where studio_id = p_studio_id and status in ('booked','attended','pending_payment')
             group by member_id, occurrence_id having count(*) > 1) x
    union all
    -- 7. a notification unsent for more than an hour
    select (select count(*) from notifications n
             where n.studio_id = p_studio_id and n.status = 'scheduled'
               and n.scheduled_for < now() - interval '1 hour')::text
           || ' emails have been waiting over an hour to send'
     where exists (select 1 from notifications n
                    where n.studio_id = p_studio_id and n.status = 'scheduled'
                      and n.scheduled_for < now() - interval '1 hour')
    union all
    -- 8. an attended booking with no signed waiver
    select mname(b.member_id) || ': attended ' || cname(b.occurrence_id) || ' without signing the waiver'
      from bookings b join members m on m.id = b.member_id
     where b.studio_id = p_studio_id and b.status = 'attended'
       and coalesce((select require_waiver from studio_settings where studio_id = p_studio_id), false)
       and exists (select 1 from waiver_versions wv where wv.studio_id = p_studio_id)
       and m.waiver_signed_at is null
    union all
    -- 9. emails that failed in the last day, with the reason
    select count(*)::text || ' emails failed: ' || coalesce(nullif(btrim(fx.reason), ''), 'no reason given')
      from (select coalesce(split_part(error, ':', 1), 'unknown') as reason
              from notifications
             where studio_id = p_studio_id and status = 'failed'
               and coalesce(failed_at, created_at) > now() - interval '1 day') fx
     group by fx.reason
    union all
    -- 10. Decision 103(h): a credit-covered booking the owing shape would dun
    -- (the covered marker is missing). The belt against a covered booking being
    -- reported as due; member_reservation_dues excludes covered bookings.
    select mname(b.member_id) || ': covered booking ' || cname(b.occurrence_id)
           || ' is reported as owing the fee'
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
      join studio_settings st on st.studio_id = b.studio_id
     where b.studio_id = p_studio_id
       and not coalesce(b.reservation_credit_covered, false)
       and exists (select 1 from audit_logs a where a.action = 'reservation.credit_used'
                    and a.entity_table = 'bookings' and a.entity_id = b.id)
       and b.status = 'booked' and b.payment_source = 'comp'
       and coalesce(st.free_first_reservation_fee_cents, 0) > 0
       and st.free_first_reservation_from is not null
       and o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)) > now()
       and not exists (select 1 from payments p where p.booking_id = b.id
                        and p.kind = 'reservation_fee' and p.status in ('succeeded','partially_refunded'))
    union all
    -- 11. Decision 108 (a): a flex class before its cut-off carrying a
    -- reached-minimum mark with fewer paid seats than its minimum.
    select cname(o.id) || ' is marked as reached its minimum with '
           || pc.paid || ' paid of ' || o.minimum_bookings
      from class_occurrences o
      cross join lateral (select count(*)::int as paid from bookings b
             where b.occurrence_id = o.id
               and b.status in ('booked','attended','no_show','pending_payment')
               and not (coalesce(b.payment_source = 'drop_in', false)
                        and not exists (select 1 from payments pmt where pmt.booking_id = b.id
                                         and pmt.status in ('succeeded','partially_refunded')))) pc
     where o.studio_id = p_studio_id and o.status = 'scheduled'
       and coalesce(o.flex, false) and o.committed_at is null
       and (o.flex_reached_minimum_at is not null or o.core_reached_minimum_at is not null)
       and o.minimum_bookings is not null and pc.paid < o.minimum_bookings
       and now() < coalesce((select g.cutoff_at from occurrence_guarantee_run(o.id) g), o.starts_at)
    union all
    -- 12. Decision 108 (a) and (c): a pay line whose amount does not match its
    -- own recorded basis, read at the tier the class had when it was decided.
    -- Settled lines (corrected, voided, restored) are skipped.
    select coalesce((select display_name from instructors where id = ipr.instructor_id), 'An instructor')
           || ': the pay line for ' || coalesce(cname(ipr.occurrence_id), 'a class') || ' is '
           || money_txt(ipr.amount_cents, ipr.currency) || ' but its basis gives '
           || money_txt((rv ->> 'basis_expected')::int, ipr.currency)
      from instructor_pay_records ipr
      cross join lateral pay_line_review_run(ipr.id) rv
     where ipr.studio_id = p_studio_id and ipr.type = 'class'
       and not (rv ->> 'settled')::boolean
       and (rv ->> 'basis_expected') is not null
       and (rv ->> 'basis_expected')::int <> ipr.amount_cents
    union all
    -- 12b. Decision 108 (b) and (c): a pay line on a decided class whose amount
    -- differs from 75 (l). Settled lines are skipped, and a class whose tier
    -- changed since it was decided is left to item 12's basis check.
    select coalesce((select display_name from instructors where id = ipr.instructor_id), 'An instructor')
           || ': the pay line for ' || coalesce(cname(ipr.occurrence_id), 'a class') || ' is '
           || money_txt(ipr.amount_cents, ipr.currency)
           || case when x.expected = 0 and o.status = 'cancelled'
                   then ' but the class did not run and pays nothing'
                   else ' but the rules give ' || money_txt(x.expected, ipr.currency) end
      from instructor_pay_records ipr
      join pay_periods pp on pp.id = ipr.period_id and pp.status = 'open'
      join class_occurrences o on o.id = ipr.occurrence_id
      cross join lateral pay_line_review_run(ipr.id) rv
      cross join lateral (select (compute_class_pay_run(o.id) ->> 'amount_cents')::int as expected) x
     where ipr.studio_id = p_studio_id and ipr.type = 'class'
       and (o.status = 'cancelled' or o.attendance_finalised_at is not null)
       and not (rv ->> 'settled')::boolean
       and (rv ->> 'decision_tier') is not distinct from (rv ->> 'today_tier')
       and x.expected is not null and x.expected <> ipr.amount_cents
    union all
    -- 13. Decision 103 (j): a free first class seat past its deadline that was
    -- kept because its due email was never sent.
    select mname(b.member_id) || ': ' || cname(b.occurrence_id)
           || ' was kept because the pay-to-keep email never reached them'
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
      join studio_settings st on st.studio_id = b.studio_id
      join members mb on mb.id = b.member_id
     where b.studio_id = p_studio_id and b.status = 'booked' and b.payment_source = 'comp'
       and o.starts_at > now() - interval '1 day'
       and not coalesce(b.reservation_credit_covered, false)
       and mb.reservation_fee_waived_at is null and not coalesce(b.reservation_fee_waived, false)
       and coalesce(st.free_first_reservation_fee_cents, 0) > 0
       and st.free_first_reservation_from is not null
       and o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)) <= now()
       and exists (select 1 from guest_passes gp where gp.guest_booking_id = b.id and gp.host_member_id is null)
       and not exists (select 1 from payments p where p.booking_id = b.id
                        and p.kind = 'reservation_fee' and p.status in ('succeeded','partially_refunded'))
       and exists (select 1 from notifications n
                    where n.dedupe_key = 'free_reservation_due:' || b.id
                       or n.dedupe_key like 'free_reservation_due:' || b.id || ':%')
       and not free_due_sent(b.id, o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)))
    union all
    -- 14. Decision 108 (b): a class that ran with no pay line.
    select coalesce(cname(o.id), 'A class') || ' ran with no pay line'
      from class_occurrences o
      join studio_settings st on st.studio_id = o.studio_id
     where o.studio_id = p_studio_id and o.status = 'scheduled' and o.instructor_id is not null
       and (coalesce(st.guarantees_enabled, false) or coalesce(st.flex_enabled, false))
       and o.ends_at < now() - interval '1 hour' and o.starts_at > now() - interval '14 days'
       and not exists (select 1 from instructor_pay_records ipr2 where ipr2.occurrence_id = o.id)
    union all
    -- 15. Decision 108 (b): an always-runs class past its start never committed.
    select coalesce(cname(o.id), 'An always-runs class') || ' started and was never committed'
      from class_occurrences o
      cross join lateral occurrence_guarantee_run(o.id) g
     where o.studio_id = p_studio_id and o.status = 'scheduled' and g.tier = 'always'
       and o.committed_at is null
       and o.starts_at < now() - interval '30 minutes' and o.starts_at > now() - interval '14 days'
    union all
    -- 16. Decision 108 (b): a pay line held for more than 3 days.
    select coalesce((select display_name from instructors where id = ipr.instructor_id), 'An instructor')
           || ': the pay line for ' || coalesce(cname(ipr.occurrence_id), 'a class') || ' has been held for '
           || extract(day from now() - ipr.created_at)::int || ' days'
      from instructor_pay_records ipr
      join pay_periods pp on pp.id = ipr.period_id and pp.status = 'open'
     where ipr.studio_id = p_studio_id and ipr.confirmed_at is null
       and ipr.created_at < now() - interval '3 days'
    union all
    -- 17. Decision 118: a plan bought without an account, not claimed in 30 days.
    select coalesce(xp.buyer_name, xp.buyer_email, 'A buyer') || ': '
           || coalesce((select name from membership_plans where id = xp.plan_id), 'a plan')
           || ' bought, not yet claimed for 30 days'
      from xendit_purchases xp
     where xp.studio_id = p_studio_id and xp.guest_status = 'held'
       and xp.completed_at < now() - interval '30 days'
    union all
    -- 18. Decision 118: an intro offer refund at claim that did not go through.
    select coalesce(xp.buyer_name, xp.buyer_email, 'A buyer') || ': the refund for '
           || coalesce((select name from membership_plans where id = xp.plan_id), 'a plan')
           || ' did not go through. Refund it from Bought, not yet claimed'
      from xendit_purchases xp
     where xp.studio_id = p_studio_id and xp.guest_status = 'refund_pending'
       and xp.updated_at < now() - interval '1 hour'
  loop
    -- Decision 108 (b): one null line must never wipe the list.
    v_line := coalesce(r.line, 'An item with a missing name');
    v_items := v_items || to_jsonb(v_line);
    v_html  := v_html  || '<li>' || replace(replace(v_line, '&', '&amp;'), '<', '&lt;') || '</li>';
    v_text  := v_text  || '- ' || v_line || E'\n';
  end loop;

  v_n := jsonb_array_length(v_items);
  return jsonb_build_object(
    'n', v_n,
    'all_clear', v_n = 0,
    'items', v_items,
    'items_html', case when v_n = 0 then '<p>All clear.</p>' else '<ul>' || v_html || '</ul>' end,
    'items_text', case when v_n = 0 then 'All clear.' else v_text end,
    'count_label', case when v_n = 0 then 'all clear'
                        else v_n::text || ' item' || case when v_n = 1 then '' else 's' end end);
end $function$;
revoke execute on function daily_money_check(uuid) from public, anon, authenticated;
grant  execute on function daily_money_check(uuid) to service_role;

-- ---- The emails: platform defaults + Reform overrides (RPC voice) ----------

insert into notification_templates (key, subject, text_body, html_body, note) values
('plan_waiting_claim', 'Your {plan_name} is paid. Set up your account', E'Hi {first_name},\n\nThank you for buying {plan_name} ({amount}) at {studio_name}. It is waiting for you.\n\nSet up your account with this email address and it is added straight away. Your plan starts on the day you set up, so you lose no days.\n\nSet up my account: {claim_url}\n\nAlready have an account? Sign in with this email address: {login_url}\n\n{studio_name}', '<p>Hi {first_name},</p><p>Thank you for buying {plan_name} ({amount}) at {studio_name}. It is waiting for you.</p><p>Set up your account with this email address and it is added straight away. Your plan starts on the day you set up, so you lose no days.</p><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{claim_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''''Segoe UI'''',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Set up my account</a></td></tr></table><p>Already have an account? Sign in with this email address: {login_url}</p><p>{studio_name}</p>', 'Decision 118: a plan bought without an account is waiting.'),
('plan_claim_reminder', 'Your {plan_name} is still waiting for you', E'Hi {first_name},\n\nYour {plan_name} from {studio_name} is paid and waiting. Set up your account with this email address to start booking. Your plan starts on the day you set up.\n\nSet up my account: {claim_url}\n\n{studio_name}', '<p>Hi {first_name},</p><p>Your {plan_name} from {studio_name} is paid and waiting. Set up your account with this email address to start booking. Your plan starts on the day you set up.</p><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{claim_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''''Segoe UI'''',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Set up my account</a></td></tr></table><p>{studio_name}</p>', 'Decision 118: reminder at 2 and 7 days, and the staff resend.'),
('intro_offer_refunded', 'We have refunded your {plan_name}', E'Hi {first_name},\n\nThe intro offer is for first-timers and you have had yours. We have refunded your payment.\n\nThe {amount} goes back to the card or GCash you paid with.\n\nSee the plans: {plans_url}\n\n{studio_name}', '<p>Hi {first_name},</p><p>The intro offer is for first-timers and you have had yours. We have refunded your payment.</p><p>The {amount} goes back to the card or GCash you paid with.</p><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{plans_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''''Segoe UI'''',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">See the plans</a></td></tr></table><p>{studio_name}</p>', 'Decision 118: an intro offer bought without an account, refunded at claim.'),
('plan_in_account', 'Your {plan_name} is in your account', E'Hi {first_name},\n\nThank you for buying {plan_name} ({amount}). It is in your account, so you can book straight away.\n\nSee my plan: {account_url}\n\n{studio_name}', '<p>Hi {first_name},</p><p>Thank you for buying {plan_name} ({amount}). It is in your account, so you can book straight away.</p><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{account_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''''Segoe UI'''',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">See my plan</a></td></tr></table><p>{studio_name}</p>', 'Decision 118: bought without signing in by somebody who already has an account.')
on conflict (key) do nothing;

insert into notification_templates_overrides (studio_id, key, subject, body, body_html)
select s.id, 'plan_waiting_claim', 'Your {plan_name} is paid. Set up your account',
 E'Hi {first_name}!\n\nThank you for buying {plan_name} ({amount}). It is paid and waiting for you.\n\nSet up your account with this email address and we add it straight away. Your plan starts on the day you set up, so you lose no days.\n\n[Set up my account]({claim_url}){button}\n\nAlready have an account? Sign in with this email address: {login_url}\n\nSee you at the reformer!🎀\n\nRPC Studio',
 '<p>Hi {first_name}!</p><p>Thank you for buying {plan_name} ({amount}). It is paid and waiting for you.</p><p>Set up your account with this email address and we add it straight away. Your plan starts on the day you set up, so you lose no days.</p><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{claim_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''''Segoe UI'''',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Set up my account</a></td></tr></table><p>Already have an account? Sign in with this email address: {login_url}</p><p>See you at the reformer!🎀</p><p>RPC Studio</p>'
  from studios s where s.slug = 'reformcollective'
on conflict (studio_id, key) do nothing;

insert into notification_templates_overrides (studio_id, key, subject, body, body_html)
select s.id, 'plan_claim_reminder', 'Your {plan_name} is still waiting for you',
 E'Hi {first_name}!\n\nYour {plan_name} is paid and waiting for you. Set up your account with this email address to start booking. Your plan starts on the day you set up, so you lose no days.\n\n[Set up my account]({claim_url}){button}\n\nSee you at the reformer!🎀\n\nRPC Studio',
 '<p>Hi {first_name}!</p><p>Your {plan_name} is paid and waiting for you. Set up your account with this email address to start booking. Your plan starts on the day you set up, so you lose no days.</p><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{claim_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''''Segoe UI'''',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Set up my account</a></td></tr></table><p>See you at the reformer!🎀</p><p>RPC Studio</p>'
  from studios s where s.slug = 'reformcollective'
on conflict (studio_id, key) do nothing;

insert into notification_templates_overrides (studio_id, key, subject, body, body_html)
select s.id, 'intro_offer_refunded', 'We have refunded your {plan_name}',
 E'Hi {first_name}!\n\nThe intro offer is for first-timers and you have had yours. We have refunded your payment.\n\nThe {amount} goes back to the card or GCash you paid with. Have a look at our other plans.\n\n[See the plans]({plans_url}){button}\n\nSee you at the reformer!🎀\n\nRPC Studio',
 '<p>Hi {first_name}!</p><p>The intro offer is for first-timers and you have had yours. We have refunded your payment.</p><p>The {amount} goes back to the card or GCash you paid with. Have a look at our other plans.</p><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{plans_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''''Segoe UI'''',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">See the plans</a></td></tr></table><p>See you at the reformer!🎀</p><p>RPC Studio</p>'
  from studios s where s.slug = 'reformcollective'
on conflict (studio_id, key) do nothing;

insert into notification_templates_overrides (studio_id, key, subject, body, body_html)
select s.id, 'plan_in_account', 'Your {plan_name} is in your account',
 E'Hi {first_name}!\n\nThank you for buying {plan_name} ({amount}). It is in your account, so you can book straight away.\n\n[See my plan]({account_url}){button}\n\nSee you at the reformer!🎀\n\nRPC Studio',
 '<p>Hi {first_name}!</p><p>Thank you for buying {plan_name} ({amount}). It is in your account, so you can book straight away.</p><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{account_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''''Segoe UI'''',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">See my plan</a></td></tr></table><p>See you at the reformer!🎀</p><p>RPC Studio</p>'
  from studios s where s.slug = 'reformcollective'
on conflict (studio_id, key) do nothing;


-- ---- The anon surface: EXACTLY FIFTEEN functions (plus the insert-only
-- resend_webhook_inbox table). xendit_purchases stays closed to anon.
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'expect\_%' and p.proname not in ('call_jsonb');
  if n <> 15 then raise exception 'anon surface is %, expected 15', n; end if;
  if not has_function_privilege('anon', 'plan_buy_begin(uuid, uuid, text, text, text)', 'execute') then
    raise exception 'plan_buy_begin is not anon';
  end if;
  -- Hosted grants anon a table-level SELECT on every table by default; RLS is
  -- the boundary (xpur_member_self needs a member login, xpur_staff_read a
  -- manager), so assert RLS, not the grant.
  if not (select relrowsecurity from pg_class where oid = 'public.xendit_purchases'::regclass) then
    raise exception 'xendit_purchases has no row level security';
  end if;
end $$;
