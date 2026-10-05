-- Decision 62 — an intro offer (a `trial` plan) is bought once per person.
--
-- re-issues: activate_purchase(uuid, uuid, uuid, integer, character, text, text, boolean),
--   xendit_begin_purchase(uuid, uuid),
--   member_bootstrap(text)
--
-- A trial plan — the studio's intro offer — can be bought ONCE per member, ever,
-- by any route (website link, member app, Xendit checkout, staff manual sale).
-- The check is in the database: a member who has ever held a membership on ANY
-- trial plan of the studio (any status — active, expired, cancelled, refunded)
-- is refused PT409 with the exact sentence below. A trial is also admitted as a
-- one-time plan for Decision 40/57 (xendit_begin_purchase accepted only
-- class_pack/drop_in before), so /buy/{trial} can sell it.
--
--   * activate_purchase is the single grant point (manual sale, Xendit activation,
--     the member app) — the belt refusal there catches every route. It fires only
--     when the plan being activated is itself a trial, so a Decision 61
--     complimentary grant (on a non-trial comp plan) is never touched.
--   * xendit_begin_purchase refuses EARLY with the same sentence, so no checkout
--     session is created for a member who has already had their intro offer.
--   * member_bootstrap exposes trial_used for the member-app UI (drop+recreate,
--     a returns-table column change; ACL re-asserted authenticated-only).
--
-- Byte-for-byte the newest bodies otherwise. No new anon surface — still THIRTEEN.

-- =============================================================================
-- 1. activate_purchase — the belt. Refuse a second trial before any write.
--    Byte-for-byte 20260832070000 with the intro-once refusal added after the
--    member-belongs check and before the seat cap (before any membership/credit
--    write). create-or-replace keeps the service-role-only ACL (re-asserted).
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

-- =============================================================================
-- 2. xendit_begin_purchase — admit `trial` as a one-time plan, and refuse early
--    with the intro-once sentence so no checkout session is created. Byte-for-
--    byte 20260831810000 with those two changes; create-or-replace keeps ACL.
-- =============================================================================
create or replace function xendit_begin_purchase(p_studio_id uuid, p_plan_id uuid)
returns table(purchase_id uuid, amount_cents int, currency char(3))
language plpgsql security definer set search_path = public as $$
declare v_member uuid; mp membership_plans%rowtype; v_id uuid;
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
  -- Part A is one-time only. A recurring plan is a subscription (auto-charge is
  -- Part B) and must not be bought as a one-off here. Decision 62 admits `trial`
  -- as a one-time plan so the intro offer is buyable from its website link.
  if mp.type not in ('class_pack', 'drop_in', 'trial') then
    raise exception 'that plan is not a one-time purchase' using errcode = 'PT422';
  end if;

  -- Decision 62: an intro offer is bought once per person. Refuse BEFORE a
  -- xendit_purchases row (a checkout session) is created, so a member who has
  -- already had their trial never reaches Xendit.
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

  insert into xendit_purchases (studio_id, member_id, plan_id, amount_cents, currency)
  values (p_studio_id, v_member, p_plan_id, mp.price_cents, mp.currency)
  returning id into v_id;

  return query select v_id, mp.price_cents, mp.currency;
end $$;

revoke execute on function xendit_begin_purchase(uuid, uuid) from public, anon;
grant  execute on function xendit_begin_purchase(uuid, uuid) to authenticated, service_role;

-- =============================================================================
-- 3. member_bootstrap — expose trial_used for the member-app UI. A returns-table
--    column change, so drop + recreate; ACL re-asserted authenticated-only (the
--    hosted default re-grants anon on a drop, so this is load-bearing). Byte-for-
--    byte 20260832130000 with the one new output column.
-- =============================================================================
drop function if exists member_bootstrap(text);
create function member_bootstrap(p_slug text)
 returns table(member_id uuid, studio_id uuid, first_name text, last_name text, preferred_name text,
   avatar_path text, status member_status, current_streak integer, lifetime_visits integer,
   studio_name text, studio_timezone text, logo_url text, theme_preset theme_preset, accent_color text,
   checkin_opens_minutes_before integer, checkin_closes_minutes_after integer,
   cancellation_cutoff_minutes integer, booking_cutoff_minutes integer, waitlist_enabled boolean,
   billing_status platform_status, billing_locked boolean, open_offers integer,
   guest_passes_enabled boolean, has_payment_provider boolean, booking_window_days integer,
   how_to_buy text, studio_contact_email text, xendit_enabled boolean, time_format text,
   trial_used boolean)
 language sql stable security definer set search_path to 'public' as $function$
  select
    m.id, m.studio_id, m.first_name, m.last_name, m.preferred_name, m.avatar_url,
    m.status, coalesce(m.current_streak, 0), coalesce(m.lifetime_visits, 0),
    s.name, s.timezone, s.logo_url, s.theme_preset, s.accent_color,
    coalesce(st.checkin_opens_minutes_before, 60),
    coalesce(st.checkin_closes_minutes_after, 30),
    coalesce(st.cancellation_cutoff_minutes, 720),
    coalesce(st.booking_cutoff_minutes, 0),
    coalesce(st.waitlist_enabled, true),
    ps.status,
    coalesce(ps.status = 'locked', false),
    (select count(*)::int from waitlist_offers wo
       join bookings b on b.id = wo.booking_id
      where b.member_id = m.id
        and wo.responded_at is null
        and wo.expires_at > now()),
    coalesce(st.guest_passes_enabled, false),
    (s.stripe_account_id is not null),
    member_booking_window_days(m.id),
    st.how_to_buy,
    s.contact_email,
    exists (select 1 from studio_payment_providers spp
             where spp.studio_id = m.studio_id and spp.provider = 'xendit'),
    coalesce(st.time_format, '24h'),
    -- Decision 62: whether this member has ever held a membership on any trial
    -- plan of the studio (any status). Drives the intro-once UI.
    exists (select 1 from memberships ms
              join membership_plans mp on mp.id = ms.plan_id
             where ms.member_id = m.id and mp.type = 'trial')
  from members m
  join studios s on s.id = m.studio_id
  left join studio_settings st on st.studio_id = m.studio_id
  left join platform_subscriptions ps on ps.studio_id = m.studio_id
  where m.user_id = auth.uid()
    and s.slug = p_slug
  limit 1
$function$;
revoke execute on function member_bootstrap(text) from public, anon;
grant  execute on function member_bootstrap(text) to authenticated, service_role;

-- The anon surface is unchanged — exactly THIRTEEN pre-login functions.
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % functions, expected exactly 13', n; end if;
end $$;
