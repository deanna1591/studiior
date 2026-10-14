-- Decision 78a — the intro window, and the exclusive-offer purchase gate.
--
-- creates:    intro_window(uuid, timestamptz)
-- re-issues:  xendit_begin_purchase(uuid, uuid)
--
-- intro_window(member) → {active, offer_plan_id, starts_at, ends_at}. The window
-- starts at the member's earliest free class (check-in, else class end if
-- unmarked), runs intro_offer_days, and is active while they are inside it AND
-- have no membership yet. Guarded self/desk/service, like free_first_eligibility;
-- the member calls it for themselves and the sweep (service) for anyone, so no
-- _run twin is needed.
--
-- xendit_begin_purchase (from 20260832480000) gains ONE gate: an exclusive intro
-- offer is refused to a member who is not inside their window. Everything else is
-- byte-for-byte.

create function intro_window(p_member_id uuid, p_now timestamptz default now())
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_member  members%rowtype;
  v_days    int;
  v_offer   uuid;
  v_booked  uuid;
  v_occ     uuid;
  v_ends    timestamptz;
  v_checkin timestamptz;
  v_start   timestamptz;
  v_end     timestamptz;
  v_active  boolean;
begin
  select * into v_member from members where id = p_member_id;
  if not found then raise exception 'no such member' using errcode = 'PT404'; end if;
  if not (coalesce(v_member.user_id = auth.uid(), false)
          or coalesce(is_desk_up(v_member.studio_id), false)
          or is_service_context()) then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;

  select intro_offer_days, intro_offer_plan_id into v_days, v_offer
    from studio_settings where studio_id = v_member.studio_id;
  v_days := coalesce(v_days, 14);

  -- The earliest free class of the member's OWN (a comp booking that is not a
  -- guest seat brought by a host). Once ever: the first one anchors the window.
  select b.id, b.occurrence_id, o.ends_at
    into v_booked, v_occ, v_ends
    from bookings b join class_occurrences o on o.id = b.occurrence_id
   where b.member_id = p_member_id and b.payment_source = 'comp'
     and not exists (select 1 from guest_passes gp
                      where gp.guest_booking_id = b.id and gp.host_member_id is not null)
   order by b.booked_at
   limit 1;

  if v_booked is null then
    return jsonb_build_object('active', false, 'offer_plan_id', v_offer,
                              'starts_at', null, 'ends_at', null);
  end if;

  select min(ci.checked_in_at) into v_checkin
    from check_ins ci
   where ci.member_id = p_member_id and ci.occurrence_id = v_occ;
  v_start := coalesce(v_checkin, v_ends);
  v_end   := v_start + make_interval(days => v_days);

  v_active := v_start is not null
              and p_now >= v_start and p_now < v_end
              and not exists (select 1 from memberships ms where ms.member_id = p_member_id);

  return jsonb_build_object(
    'active', v_active,
    'offer_plan_id', v_offer,
    'starts_at', v_start,
    'ends_at', v_end);
end $$;
revoke execute on function intro_window(uuid, timestamptz) from public, anon;
grant  execute on function intro_window(uuid, timestamptz) to authenticated, service_role;

-- ---------------------------------------------------------------------------
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

  -- Decision 78: an exclusive intro offer is buyable ONLY by a member inside
  -- their intro window. v_member is the caller's own row, so intro_window's
  -- self-guard passes.
  if p_plan_id = (select intro_offer_plan_id from studio_settings where studio_id = p_studio_id)
     and coalesce((select intro_offer_exclusive from studio_settings where studio_id = p_studio_id), false)
     and not coalesce((intro_window(v_member) ->> 'active')::boolean, false) then
    raise exception 'That plan is only available during your intro offer.' using errcode = 'PT409';
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
