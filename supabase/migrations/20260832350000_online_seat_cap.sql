-- =============================================================================
-- 235 — Decision 24 / 57 / 66 follow-up: a full plan refuses a NEW place online.
--
-- A plan may cap how many members hold it (Decision 24, migration 102). The
-- desk is refused a sale into a full plan by activate_purchase() under a plan
-- row lock. The ONLINE path had no such gate: Decision 40 calls
-- activate_purchase(..., p_enforce_seat_cap => false) at the webhook (the money
-- is already captured, so a refusal there would leave a paid member with no
-- membership), and xendit_begin_purchase — the moment BEFORE checkout, where a
-- refusal is free — did not check the cap at all. So a member could buy into a
-- full capped plan online (Reform's "Founding Unlimited", 20 places).
--
-- THE GATE MOVES TO BEGIN. xendit_begin_purchase refuses a NEW place into a
-- full capped plan with PT409 "{Plan} is full.", counting the same four live
-- statuses the desk counts (plan_seats_taken, under seat_caps_enabled). The
-- webhook's cap BYPASS IS KEPT: a checkout that began while a place was free
-- still activates even if someone else took the last place meanwhile — the
-- studio goes one over, and every staff screen already says so (plan_seats
-- is_over). THE RACE IS ACCEPTED: a few members starting checkout against the
-- last place can all complete; begin is the narrowing, not a lock, and holding
-- a place for an in-flight checkout is a reservation flow this is not.
--
-- A RENEWAL IS NEVER A NEW PLACE. When this checkout renews a recurring
-- membership the member already holds (v_renew set — the renew-vs-sell split
-- Decision 66 decides at begin), the existing holder is already one of the
-- counted places, so the cap is NOT re-checked — exactly as the desk renewal
-- path (advance_membership_period) does not re-check it. v_renew is only ever
-- set for recurring + a live/past-due holding, so a pack/drop-in/trial and a
-- recurring NEW purchase all take the check.
--
-- SQL is one re-issue (create or replace, signature and ACL unchanged, anon
-- stays THIRTEEN). The two member buy surfaces (/buy/{plan}, /account/plan) hide
-- the Buy when full in the app, reading the existing member-callable plan_seats.
-- =============================================================================

-- re-issues: xendit_begin_purchase(uuid, uuid)

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
  if mp.type not in ('class_pack', 'drop_in', 'trial', 'recurring') then
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
