-- creates: checkout_hold_class(uuid), set_occurrence_day_tier_run(uuid, text), set_occurrence_day_tier(uuid, text, boolean), tg_public_schedule_bust(), plan_sold_count_run(uuid), plan_sold_out_run(uuid), plan_sold_states(uuid), tg_xendit_purchase_sold_out()
-- re-issues: book_class(uuid, uuid, booking_source, text, payment_source, uuid), choose_pay_at_desk(uuid), member_bootstrap(text), apply_payment_refund(uuid), queue_occurrence_cancelled(uuid, cancellation_cause), template_sample_context(uuid, text, text), dashboard_health(uuid), retention_board(uuid), growth_insights(uuid, date), record_manual_payment_run(uuid, uuid, text, integer, text, uuid, uuid, bpchar, text, text, timestamptz, text, text), studio_by_slug(text, boolean)
--
-- Step 14b (28 Nov 2026).
--   103 (p) desk_pay_mode 'staff_only': members never leave a seat confirmed
--           and unpaid. book_class refuses the member's own unpaid drop-in
--           ('pay_online'), choose_pay_at_desk refuses the member themselves,
--           member_bootstrap says desk_pay_available false. The online checkout
--           hold goes through checkout_hold_class, which books exactly as before.
--           Staff paths are unchanged.
--   21 (h)  set_occurrence_day_tier gains p_confirm_cancel: a switch to flex
--           after the flex cut-off and under the minimum is refused
--           ('confirm_cancel') unless confirmed, and then cancels at once.
--   22 (g)  public_schedule_cache is cleared for the studio on every change to
--           a class, a series' tier, or the studio's tier switches.
--   111 (b) payment_refunded only when money moves; class_cancelled states
--           what came back ({returned_line}).
--   97 (c)  test accounts are left out of member health, the retention board
--           and the growth nudge list.
--   24 (a)  membership_plans.max_sold: every sale ever (refunded and
--           complimentary excluded) plus pending checkouts; sold out refuses
--           every purchase path.
-- Anon stays EXACTLY FIFTEEN (asserted at the bottom).

alter table studio_settings drop constraint if exists studio_settings_desk_pay_mode_chk;
alter table studio_settings add constraint studio_settings_desk_pay_mode_chk
  check (desk_pay_mode in ('earned', 'first_visit_only', 'staff_only'));

alter table membership_plans add column if not exists max_sold int;
alter table membership_plans drop constraint if exists membership_plans_max_sold_chk;
alter table membership_plans add constraint membership_plans_max_sold_chk
  check (max_sold is null or max_sold > 0);
comment on column membership_plans.max_sold is
  'Decision 24 (a): the most of this plan ever sold (refunded and complimentary excluded, pending checkouts included). Null = no cap.';

-- ---- 24 (a): plans capped by the number ever sold ---------------------------
create or replace function plan_sold_count_run(p_plan_id uuid)
returns int language sql stable security definer set search_path = public as $$
  select (
    (select count(*) from memberships ms
      where ms.plan_id = p_plan_id
        and not coalesce(ms.complimentary, false)
        and not exists (select 1 from payments p
                         where p.membership_id = ms.id and p.status = 'refunded'))
  + (select count(*) from xendit_purchases x
      where x.plan_id = p_plan_id and x.renews_membership_id is null
        and (x.status = 'pending'
             or (x.status = 'succeeded' and x.guest_status = 'held')))
  )::int;
$$;
revoke execute on function plan_sold_count_run(uuid) from public, anon, authenticated;
grant  execute on function plan_sold_count_run(uuid) to service_role;

create or replace function plan_sold_out_run(p_plan_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select mp.max_sold is not null and plan_sold_count_run(mp.id) >= mp.max_sold
                     from membership_plans mp where mp.id = p_plan_id), false);
$$;
revoke execute on function plan_sold_out_run(uuid) from public, anon, authenticated;
grant  execute on function plan_sold_out_run(uuid) to service_role;

-- Staff (desk-up or an instructor of the studio) see the counts; a member sees
-- only whether each capped plan is sold out.
create or replace function plan_sold_states(p_studio_id uuid)
returns table(plan_id uuid, max_sold int, sold int, sold_out boolean)
language plpgsql stable security definer set search_path = public as $$
declare v_staff boolean;
begin
  v_staff := coalesce(is_desk_up(p_studio_id), false) or is_service_context()
          or exists (select 1 from studio_staff ss where ss.studio_id = p_studio_id
                       and ss.user_id = auth.uid() and ss.status = 'active');
  if not v_staff and not exists (select 1 from members m where m.studio_id = p_studio_id
                                    and m.user_id = auth.uid() and m.deleted_at is null) then
    raise exception 'you are not part of that studio' using errcode = 'PT403';
  end if;
  return query
  select mp.id, mp.max_sold,
         case when v_staff then plan_sold_count_run(mp.id) else null end,
         plan_sold_out_run(mp.id)
    from membership_plans mp
   where mp.studio_id = p_studio_id and mp.max_sold is not null;
end $$;
revoke execute on function plan_sold_states(uuid) from public, anon;
grant  execute on function plan_sold_states(uuid) to authenticated, service_role;

-- Every online path (xendit_begin_purchase, plan_buy_begin, a code checkout, a
-- credit-covered checkout) writes a xendit_purchases row for a new place; the
-- row is the hold, so the check is at its insert. A renewal is not a new sale.
create or replace function tg_xendit_purchase_sold_out()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.plan_id is not null and new.renews_membership_id is null
     and plan_sold_out_run(new.plan_id) then
    raise exception 'This plan is sold out.' using errcode = 'PT410';
  end if;
  return new;
end $$;
revoke execute on function tg_xendit_purchase_sold_out() from public, anon, authenticated;
drop trigger if exists xendit_purchases_sold_out on xendit_purchases;
create trigger xendit_purchases_sold_out before insert on xendit_purchases
  for each row execute function tg_xendit_purchase_sold_out();

-- Founding Unlimited at Reform: 20 places ever (1 sold on 28 Nov).
update membership_plans set max_sold = 20
 where id = '37c87f52-73be-40fb-9f94-d39360342b34'
   and studio_id = (select id from studios where slug = 'reformcollective');

create or replace function record_manual_payment_run(
  p_studio_id uuid, p_member_id uuid, p_kind text, p_amount_cents integer, p_method text,
  p_plan_id uuid default null, p_booking_id uuid default null, p_currency char default null,
  p_method_note text default null, p_reference text default null,
  p_paid_at timestamptz default now(), p_description text default null,
  p_code text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_currency char(3);
  v_ms       uuid;
  v_payment  uuid;
  v_confirmed boolean := false;
  v_plan_name text;
  v_renewing uuid;
  v_renewal  jsonb;
  v_is_group boolean := false;
  v_group_purchase uuid;
  v_pr jsonb; v_list int; v_promo uuid; v_disc int;
  v_code jsonb; v_use uuid; v_amount int := p_amount_cents; v_email text;
begin
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

  -- Decision 120: a code at the desk, checked before anything is written. A
  -- valid code sets the amount to the code price (or the sale price if lower).
  if nullif(btrim(coalesce(p_code, '')), '') is not null then
    if p_kind <> 'plan' or p_plan_id is null then
      raise exception 'That code doesn''t apply to this plan.' using errcode = 'PT460';
    end if;
    select email into v_email from members where id = p_member_id;
    v_code := discount_code_price_run(p_plan_id, p_code, p_member_id, v_email, now());
    if not coalesce((v_code ->> 'code_ok')::boolean, false) then
      raise exception '%', v_code ->> 'code_message' using errcode = 'PT460';
    end if;
    v_amount := (v_code ->> 'price_cents')::int;
  end if;

  if p_kind = 'plan' then
    if p_plan_id is null then
      raise exception 'which plan?' using errcode = 'PT400';
    end if;
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
      -- The UNGUARDED twin: record_manual_payment_run is also reached from the
      -- instructor desk (sell_plan_at_desk), where the caller is not desk/service
      -- and advance_membership_period's own guard would refuse. The desk/scope
      -- boundary is enforced by the caller (is_desk_up wrapper / instructor_scope).
      v_renewal := advance_membership_period_run(v_renewing);
    else
      -- Decision 24 (a): a new sale of a sold-out plan is refused.
      if plan_sold_out_run(p_plan_id) then
        raise exception 'This plan is sold out.' using errcode = 'PT410';
      end if;
      v_ms := activate_purchase(p_studio_id, p_member_id, p_plan_id,
                                v_amount, v_currency);
    end if;
    select name, type = 'group' into v_plan_name, v_is_group
      from membership_plans where id = p_plan_id;
    if v_is_group then v_group_purchase := v_ms; v_ms := null; end if;

  elsif p_kind = 'dropin' then
    if p_booking_id is null then
      raise exception 'which booking?' using errcode = 'PT400';
    end if;
    v_confirmed := confirm_dropin_payment(p_studio_id, p_booking_id);
  end if;

  -- Decision 117: the promotion is recorded only when the amount IS the sale
  -- price; any other typed amount is a manual price, recorded as typed.
  if coalesce((v_code ->> 'code_applied')::boolean, false) then
    v_list := (v_code ->> 'list_cents')::int;
    v_disc := (v_code ->> 'discount_cents')::int;
    v_use := discount_code_hold_run(p_studio_id, (v_code ->> 'code_id')::uuid, (v_code ->> 'batch_id')::uuid,
               p_member_id, v_email, p_plan_id, null, v_list, v_disc);
    if v_ms is not null and v_renewing is null then
      update memberships ms set price_cents = v_list
        from membership_plans pl
       where ms.id = v_ms and pl.id = ms.plan_id and pl.type = 'recurring';
    end if;
  elsif p_kind = 'plan' and p_plan_id is not null then
    v_pr := plan_price_now_run(p_plan_id, now());
    if nullif(v_pr ->> 'promotion_id', '') is not null
       and v_amount = (v_pr ->> 'price_cents')::int then
      v_promo := (v_pr ->> 'promotion_id')::uuid;
      v_list  := (v_pr ->> 'list_cents')::int;
      v_disc  := (v_pr ->> 'discount_cents')::int;
      -- Decision 117(a): a new recurring membership sold on sale keeps the
      -- list price as its rate (a renewal never changes the rate).
      if v_ms is not null and v_renewing is null then
        update memberships ms set price_cents = v_list
          from membership_plans pl
         where ms.id = v_ms and pl.id = ms.plan_id and pl.type = 'recurring';
      end if;
    end if;
  end if;

  insert into payments (
    studio_id, member_id, membership_id, group_purchase_id, booking_id, amount_cents, currency,
    status, provider, method, method_note, reference, description,
    paid_at, recorded_by, list_price_cents, promotion_id, discount_cents, discount_code_use_id
  ) values (
    p_studio_id, p_member_id, v_ms, v_group_purchase, p_booking_id, v_amount, v_currency,
    'succeeded', 'manual', p_method, p_method_note, p_reference,
    coalesce(p_description,
             case p_kind when 'plan' then v_plan_name
                         when 'dropin' then 'Drop-in class'
                         else 'Payment' end),
    coalesce(p_paid_at, now()), auth.uid(), v_list, v_promo, v_disc, v_use
  ) returning id into v_payment;

  return jsonb_build_object(
    'payment_id', v_payment,
    'membership_id', v_ms,
    'group_purchase_id', v_group_purchase,
    'booking_confirmed', v_confirmed,
    'renewed', v_renewal
  );
end $$;

create or replace function studio_by_slug(p_slug text, p_with_plans boolean default false)
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
           -- Decision 119: the studio contact for a guest's "Message the studio".
           'contact_email', s.contact_email,
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
                      'sold_out', plan_sold_out_run(mp.id),
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

CREATE OR REPLACE FUNCTION public.book_class(p_occurrence_id uuid, p_member_id uuid, p_source booking_source, p_override_reason text DEFAULT NULL::text, p_payment_source payment_source DEFAULT NULL::payment_source, p_membership_id uuid DEFAULT NULL::uuid)
 RETURNS book_class_result
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_result       book_class_result;
  v_occ          class_occurrences%rowtype;
  v_member       members%rowtype;
  v_set          studio_settings%rowtype;
  v_tz           text;

  v_actor        uuid := auth.uid();
  v_caller_role  text;
  v_trusted      boolean;
  v_is_desk      boolean;
  v_is_self      boolean;
  v_override     boolean := false;
  v_bypassed     text[] := '{}';
  v_comp         boolean := false;
  -- 'booked' unless the member is paying for a drop-in themselves, in which
  -- case the seat is held as 'pending_payment' until Stripe says otherwise.
  v_status       booking_status := 'booked';

  v_window_days  int;
  v_max_per_day  int;
  v_day_count    int;
  v_future_count int;
  v_today        date;

  v_cand         record;
  v_covers       boolean;
  v_restricted   boolean := false;   -- a live plan was blocked purely on class type
  v_peak         jsonb;             -- Decision 24: the paying plan's peak allowance, or null
  v_susp         jsonb;             -- Decision 24: where this member stands on the ladder
  v_pay          payment_source;
  v_membership   uuid;
  v_consume      boolean := false;

  v_booking_id   uuid;
  v_ledger_id    uuid;
  v_balance      int;
  v_position     int;
  v_full         boolean;
  v_phys_full    boolean;   -- capacity reached by REAL seats
  v_held         int;       -- §4.2: seats a live waitlist offer is holding for someone else
begin
  -- ===========================================================================
  -- 0. Locate and authorise. Nothing is written before this passes.
  -- ===========================================================================

  select * into v_occ from class_occurrences where id = p_occurrence_id;
  if not found then
    return (null, null, null, null, 'not_found')::book_class_result;
  end if;

  -- Lockout (migration 044). The studio's own subscription to Studiior has
  -- lapsed past its grace period. Reads stay open everywhere so nothing looks
  -- lost; this is one of the four places where DOING something stops.
  if studio_is_locked(v_occ.studio_id) then
    raise exception 'this studio''s Studiior subscription is not active'
      using errcode = 'PT402',
            hint = 'Reactivate it from Billing. Nothing has been deleted.';
  end if;

  select * into v_member from members where id = p_member_id;
  if not found then
    return (null, null, null, null, 'member_not_found')::book_class_result;
  end if;
  if v_member.studio_id <> v_occ.studio_id then
    return (null, null, null, null, 'member_wrong_studio')::book_class_result;
  end if;

  select * into v_set from studio_settings where studio_id = v_occ.studio_id;
  select timezone into v_tz from studios where id = v_occ.studio_id;

  -- --- Trust is a property of the ROLE, never of a missing auth.uid() -------
  --
  -- A null auth.uid() proves nothing: an `authenticated` caller whose JWT
  -- carries no `sub` claim has one too, and migration 002 handed that caller
  -- full booking rights over every member in the studio.
  --
  -- current_user is useless here — inside a security definer function it is
  -- always the function owner, not the caller. The caller's effective role is
  -- the `role` GUC, which is what PostgREST sets per request and what SET ROLE
  -- sets in a direct session; it is NOT changed by security definer entry.
  -- 'none' means no SET ROLE happened at all, i.e. a direct login session.
  --
  -- rolbypassrls is the honest test of "already privileged above RLS":
  -- service_role, postgres and supabase_admin have it, and gain nothing from
  -- this function that they could not do by writing the tables directly.
  -- authenticated, anon and authenticator do not have it.
  v_caller_role := coalesce(nullif(current_setting('role', true), 'none'),
                            session_user);
  v_trusted := exists (
    select 1 from pg_roles
     where rolname = v_caller_role
       and (rolsuper or rolbypassrls)
  );

  v_is_desk := coalesce(is_desk_up(v_occ.studio_id), false)
               or coalesce(current_setting('studiior.late_add', true) = '1', false);
  v_is_self := v_actor is not null
               and v_member.user_id is not null
               and v_member.user_id = v_actor;

  if not (v_trusted or v_is_desk or v_is_self) then
    return (null, null, null, null, 'not_authorised')::book_class_result;
  end if;
  -- A member may only book as themselves, and never on a staff source.
  if not (v_trusted or v_is_desk) and p_source <> 'member' then
    return (null, null, null, null, 'not_authorised')::book_class_result;
  end if;

  -- --- §2.4 comp -----------------------------------------------------------
  -- payment_source is otherwise resolved, never chosen (§2.2). 'comp' is the
  -- single exception the business rules allow, and it is staff-only.
  if p_payment_source is not null then
    if p_payment_source <> 'comp' then
      return (null, null, null, null, 'unsupported_payment_source')
             ::book_class_result;
    end if;
    if not (v_trusted or v_is_desk) then
      return (null, null, null, null, 'not_authorised')::book_class_result;
    end if;
    v_comp := true;
  end if;

  -- Business Rules §2.3: overrides are front desk and above only, and always
  -- carry a reason. Rules 1 (past/cancelled), 4 (waiver) and 6 (duplicate)
  -- stay unoverridable below.
  v_override := p_override_reason is not null
                and btrim(p_override_reason) <> ''
                and (v_trusted or v_is_desk);

  -- ===========================================================================
  -- 1. THE LOCK. Data Model §6 — before anything reads booked_count.
  -- ===========================================================================

  select * into v_occ
    from class_occurrences
   where id = p_occurrence_id
     for update;

  -- Then the member row, which serialises this member's own concurrent
  -- bookings so credits_remaining and credit_ledger.balance_after stay
  -- consistent. Lock order is always occurrence -> member; the nightly expiry
  -- job and the Stripe webhook handlers must take the member lock the same way.
  select * into v_member from members where id = p_member_id for update;

  v_today := (now() at time zone v_tz)::date;

  -- ===========================================================================
  -- 2. Eligibility gate — Business Rules §2.1, in order. First failure wins.
  -- ===========================================================================

  -- 2.1.1 Occurrence is scheduled, not cancelled, not in the past. Not overridable.
  if v_occ.status = 'cancelled' then
    return (null, null, null, null, 'class_cancelled')::book_class_result;
  end if;
  if v_occ.status = 'completed' then
    return (null, null, null, null, 'class_completed')::book_class_result;
  end if;
  -- Decision 100 amendment (b): a roster late add (the studiior.late_add
  -- flag, set by staff_book_member after it authorises desk-up or the
  -- class's own instructor) books into a class that has started, until it
  -- ends; after the end it is class_ended. A member (no flag) keeps the
  -- starts_at guard.
  if current_setting('studiior.late_add', true) = '1' then
    if v_occ.ends_at <= now() then
      return (null, null, null, null, 'class_ended')::book_class_result;
    end if;
  elsif v_occ.starts_at <= now() then
    return (null, null, null, null, 'class_in_past')::book_class_result;
  end if;

  -- 2.1.1b Decision 25: the class is on a PUBLISHED month. Placed with the
  -- occurrence checks and BEFORE the booking window, deliberately: an
  -- unpublished class is invisible to members under occ_member_read, so a
  -- member can only reach here with an id they cannot see, and the refusal
  -- names the reason the class is invisible rather than a rule about how far
  -- ahead their plan lets them book. That keeps the two gates composed the
  -- same way on this side as on the screen: "not published" is about the
  -- class, "outside the window" is about the member, and outside_booking_window
  -- goes on meaning exactly what it has since migration 002 — a class on the
  -- timetable that this member may not book YET. month_published() is true for
  -- every studio with the switch off, so nothing changes for them.
  -- Overridable with a reason, like the window: the desk pencilling somebody
  -- into a draft is a deliberate act and is recorded as one.
  if not month_published(v_occ.studio_id, v_occ.starts_at) then
    if v_override then
      v_bypassed := v_bypassed || 'month_not_published'::text;
    else
      return (null, null, null, null, 'month_not_published')::book_class_result;
    end if;
  end if;

  -- 2.1.1c Decision 48: a studio may keep an unstaffed class off the member side
  -- until an instructor is on it. The staffing arm of occurrence_member_visible
  -- (the published/scheduled arms are the checks just above): with the switch on
  -- and the class not assigned, it is closed to NEW bookings. A member who
  -- ALREADY holds a non-cancelled booking is unaffected — they keep their seat
  -- and the class stays visible to them (occ_member_own_read). Hard refusal: a
  -- class nobody is teaching is not something even the desk books into.
  if studio_hides_unstaffed(v_occ.studio_id)
     and v_occ.staffing <> 'assigned'
     and not exists (select 1 from bookings b
                      where b.occurrence_id = p_occurrence_id and b.member_id = p_member_id
                        and b.status <> 'cancelled') then
    return (null, null, null, null, 'not_staffed_yet')::book_class_result;
  end if;

  -- 2.1.1d Decision 91: a class HIDDEN from members (set_occurrence_visibility) is
  -- closed to NEW bookings — including by link and from the desk — unless the
  -- member ALREADY holds a non-cancelled booking on it, so cancel-and-rebook and
  -- waitlist promotion still work for them. Mirrors not_staffed_yet above.
  if v_occ.hidden_from_members
     and not exists (select 1 from bookings b
                      where b.occurrence_id = p_occurrence_id and b.member_id = p_member_id
                        and b.status <> 'cancelled') then
    return (null, null, null, null, 'class_hidden')::book_class_result;
  end if;

  -- Plan-level overrides for rules 2 and 7 come from the member's highest
  -- priority usable plan (§2.1.2 "plan-level override wins over studio
  -- default"). Read before the gate; the paying source is resolved in §3.
  -- The WINDOW is resolved through member_booking_window_days() — the single
  -- definition of §2.1.2 the member app reads too, so the "Opens for booking"
  -- screen and this rule can never disagree (Decision 36). The daily cap keeps
  -- its own read of the SAME row (identical selection) so behaviour is unchanged.
  v_window_days := member_booking_window_days(p_member_id);
  select mp.max_bookings_per_day
    into v_max_per_day
    from memberships ms
    join membership_plans mp on mp.id = ms.plan_id
   where ms.member_id  = p_member_id
     and ms.studio_id  = v_occ.studio_id
     and ms.status in ('active','trialing')
     and (ms.expires_on is null or ms.expires_on >= v_today)
     and (mp.booking_window_days is not null or mp.max_bookings_per_day is not null)
   order by case mp.type when 'recurring' then 1 when 'trial' then 2 else 3 end,
            ms.expires_on asc nulls last
   limit 1;

  v_max_per_day := coalesce(v_max_per_day, v_set.max_bookings_per_day);

  -- 2.1.2 Booking window.
  if not v_override then
    if v_occ.starts_at > now() + make_interval(days => v_window_days) then
      return (null, null, null, null, 'outside_booking_window')::book_class_result;
    end if;
  elsif v_occ.starts_at > now() + make_interval(days => v_window_days) then
    v_bypassed := v_bypassed || 'booking_window'::text;
  end if;

  -- 2.1.3 Booking cutoff. Default 0 — booking allowed right up to start.
  if current_setting('studiior.late_add', true) = '1' then
    null;  -- a late add is inside the cutoff by definition; the flag bypasses it
  elsif not v_override then
    if v_occ.starts_at < now() + make_interval(mins => v_set.booking_cutoff_minutes) then
      return (null, null, null, null, 'past_booking_cutoff')::book_class_result;
    end if;
  elsif v_occ.starts_at < now() + make_interval(mins => v_set.booking_cutoff_minutes) then
    v_bypassed := v_bypassed || 'booking_cutoff'::text;
  end if;

  -- 2.1.3b Decision 30 belt: a self-serve LEAD owed a free first class must
  -- spend it on the free path (book_first_free), not a paid drop-in. Gated on
  -- status = 'lead' — Decision 15's self-signup with no plan; an active member
  -- (including one bringing a guest through book_guest, which books their own
  -- seat here) is never a lead and books normally. Fires only when they book
  -- themselves (not desk/override) and are still eligible, and before the waiver
  -- gate, so a fresh unsigned lead is routed to the free path (which gates the
  -- waiver at check-in) rather than told to sign. The switch off makes
  -- free_first_eligibility return ok=false, so nothing here fires.
  if v_is_self and not (v_is_desk or v_trusted or v_override)
     and v_member.status = 'lead'
     and (free_first_eligibility(v_occ.studio_id, v_member.id) ->> 'ok')::boolean then
    return (null, null, null, null, 'use_free_first')::book_class_result;
  end if;

  -- 2.1.3c Decision 73: while this member's free first class is still
  -- PROVISIONAL (Decision 30 grouped — booked but awaiting its cutoff), they may
  -- not make any other app booking OR join a waitlist. A pending free class is
  -- undecided, and stacking bookings on top of it is what this prevents. Self
  -- only (a desk or service booking is never affected); never the free-first
  -- booking itself (that goes through book_first_free, not here); and a
  -- studio-offered waitlist PROMOTION is exempt (respond_to_offer sets
  -- studiior.waitlist_promoting). Tied to a host-null guest_passes row, so it is
  -- precisely a free-first seat and inert for every member not holding one.
  if v_is_self and not (v_is_desk or v_trusted)
     and current_setting('studiior.waitlist_promoting', true) is distinct from '1'
     and exists (
       select 1 from bookings b
         join guest_passes gp on gp.guest_booking_id = b.id and gp.host_member_id is null
        where b.member_id = p_member_id and b.studio_id = v_occ.studio_id
          and b.payment_source = 'comp' and b.provisional and b.status = 'booked')
  then
    return (null, null, null, null, 'free_first_pending')::book_class_result;
  end if;

  -- 2.1.4 Waiver. Not overridable. Decision 34: a signature is tied to a waiver
  -- version, and a NEW version marked requires_resign turns an older signature
  -- stale — a member who signed only an earlier required version is treated as
  -- unsigned. A studio with no version yet is unaffected (the current-version
  -- subquery finds nothing), so existing bare-timestamp signatures stand.
  if v_set.require_waiver then
    if v_member.waiver_signed_at is null then
      -- Part B: require_waiver is on but the studio has published NO version, so
      -- there is nothing to sign in the app. A distinct reason, so the member is
      -- pointed at the studio rather than told to "please sign" a screen with
      -- nothing on it. The desk paper path can still sign them.
      if not exists (select 1 from waiver_versions where studio_id = v_occ.studio_id) then
        return (null, null, null, null, 'waiver_unavailable')::book_class_result;
      end if;
      return (null, null, null, null, 'waiver_not_signed')::book_class_result;
    end if;
    if exists (
      select 1 from waiver_versions wv
       where wv.studio_id = v_occ.studio_id
         and wv.requires_resign
         and wv.created_at = (select max(created_at) from waiver_versions
                               where studio_id = v_occ.studio_id)
         and not exists (select 1 from waiver_signatures ws
                          where ws.member_id = v_member.id and ws.version_id = wv.id))
    then
      return (null, null, null, null, 'waiver_not_signed')::book_class_result;
    end if;
  end if;

  -- 2.1.5 Member status — Decision 15. A `lead` passes here, and is held to
  -- drop-in by the guard after §2.2 resolution below.
  if not book_class_status_ok(v_member.status) then
    return (null, null, null, null, 'member_not_active')::book_class_result;
  end if;

  -- 2.1.6 No existing live booking for this occurrence. Not overridable.
  -- Mirrors the bookings_one_live_per_member partial unique index.
  if exists (
    select 1 from bookings
     where occurrence_id = p_occurrence_id
       and member_id     = p_member_id
       and status in ('booked','waitlisted','attended','no_show','pending_payment')
  ) then
    -- 'pending_payment' is in this list, and deliberately NOT in the daily or
    -- forward limit counts below: a member may not start two checkouts for the
    -- same class, but three abandoned checkouts must not exhaust the limits on
    -- classes they never paid for.
    return (null, null, null, null, 'already_booked')::book_class_result;
  end if;

  -- 2.1.7 Daily limit, counted in studio-local days.
  if v_max_per_day is not null then
    select count(*) into v_day_count
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
     where b.member_id = p_member_id
       and b.studio_id = v_occ.studio_id
       and b.status in ('booked','waitlisted','attended','no_show')
       and (o.starts_at at time zone v_tz)::date
         = (v_occ.starts_at at time zone v_tz)::date;

    if v_day_count >= v_max_per_day then
      if v_override then
        v_bypassed := v_bypassed || 'daily_limit'::text;
      else
        return (null, null, null, null, 'daily_limit_reached')::book_class_result;
      end if;
    end if;
  end if;

  -- 2.1.8 Forward limit on live future bookings.
  if v_set.max_future_bookings is not null then
    select count(*) into v_future_count
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
     where b.member_id = p_member_id
       and b.studio_id = v_occ.studio_id
       and b.status in ('booked','waitlisted')
       and o.starts_at > now();

    if v_future_count >= v_set.max_future_bookings then
      if v_override then
        v_bypassed := v_bypassed || 'future_limit'::text;
      else
        return (null, null, null, null, 'future_limit_reached')::book_class_result;
      end if;
    end if;
  end if;

  -- ===========================================================================
  -- 3. Payment source resolution — Business Rules §2.2, Decision 1.
  --    unlimited membership -> limited membership allowance -> pack credits
  --    soonest expiry first -> drop-in. The member never chooses.
  --    Consumed at booking time, not at attendance (§2.2, §6).
  -- ===========================================================================

  if v_comp then
    -- §2.4: nothing consumed, nothing charged. The booking is an ordinary
    -- 'booked' row, so check-in, challenges and milestones count it exactly
    -- like any other attendance. Rule 2.1.9 is vacuous — no membership is
    -- paying, so no membership's class-type restriction applies.
    v_pay     := 'comp';
    v_consume := false;
  else
    for v_cand in
      select ms.id,
             ms.credits_remaining,
             mp.restrictions,
             case
               -- credits_per_period null on a recurring plan == unlimited
               -- (Data Model §7).
               when mp.type = 'recurring'
                    and mp.credits_per_period is null
                    and ms.credits_remaining is null              then 1
               when mp.type = 'recurring'
                    and coalesce(ms.credits_remaining, 0) > 0     then 2
               when mp.type in ('class_pack','drop_in','trial')
                    and coalesce(ms.credits_remaining, 0) > 0     then 3
               else 99
             end as priority
        from memberships ms
        join membership_plans mp on mp.id = ms.plan_id
       where ms.member_id = p_member_id
         -- Decision 100: when staff pin a specific plan, consider only it.
         and (p_membership_id is null or ms.id = p_membership_id)
         and ms.studio_id = v_occ.studio_id
         -- Decision 116: a private pack is spent only at the private booking
         -- step, never on a group class (a holder of only a private pack books
         -- a group class as a drop-in, exactly as before).
         and not coalesce(mp.private_pack, false)
         -- §7.3 / Decision 4: past_due blocks NEW bookings only once the
         -- studio's grace period has run out.
         and (
               ms.status in ('active','trialing')
            or (ms.status = 'past_due'
                and now() < coalesce(ms.current_period_end, now())
                            + make_interval(days => v_set.payment_grace_days))
         )
         -- §7.4: a frozen membership cannot book.
         and not (ms.freeze_start is not null and ms.freeze_end is not null
                  and v_today between ms.freeze_start and ms.freeze_end)
         -- §6: a credit cannot be spent past its expiry.
         and (ms.expires_on is null or ms.expires_on >= v_today)
       order by priority,
                ms.expires_on asc nulls last,   -- soonest expiry first
                ms.created_at asc
    loop
      exit when v_cand.priority = 99;

      -- §2.1.9 plan restrictions: an empty or absent class_type_ids covers
      -- everything.
      v_covers := (v_cand.restrictions -> 'class_type_ids') is null
               or jsonb_typeof(v_cand.restrictions -> 'class_type_ids') <> 'array'
               or jsonb_array_length(v_cand.restrictions -> 'class_type_ids') = 0
               or (v_occ.class_type_id is not null
                   and jsonb_exists(v_cand.restrictions -> 'class_type_ids',
                                    v_occ.class_type_id::text));

      if not v_covers then
        v_restricted := true;   -- remembered for the §2.1.9 failure below
        continue;
      end if;

      v_pay        := case when v_cand.priority in (1, 2)
                           then 'membership'::payment_source
                           else 'class_pack'::payment_source end;
      v_membership := v_cand.id;
      v_consume    := v_cand.priority in (2, 3);
      exit;
    end loop;

    if v_pay is null then
      -- Decision 100: staff pinned a plan that did not resolve or does not cover
      -- this class. Refuse with plan_not_covering rather than falling to drop-in.
      if p_membership_id is not null then
        return (null, null, null, null, 'plan_not_covering')::book_class_result;
      end if;
      -- §2.1.9: the member holds a live plan and it does not cover this class
      -- type. That is a specific refusal, not a silent fall-through to drop-in.
      if v_restricted then
        if v_override then
          v_bypassed := v_bypassed || 'plan_restriction'::text;
        else
          return (null, null, null, null, 'class_type_not_in_plan')::book_class_result;
        end if;
      end if;
      -- §2.2 priority 4: nothing covers it, so the class is a drop-in. The
      -- charge itself is a payments row raised by the caller against the
      -- returned booking; no credit is consumed here.
      -- Decision 49: the plan they would book on is frozen. Rather than
      -- silently charge a drop-in, refuse with its own reason (the member app
      -- says "paused until {date}"). A usable non-frozen pack was already
      -- resolved above, so this only fires when a frozen membership is the
      -- only plan they have.
      if exists (
        select 1 from memberships ms2
         where ms2.member_id = p_member_id and ms2.studio_id = v_occ.studio_id
           and ms2.freeze_start is not null and ms2.freeze_end is not null
           and v_today between ms2.freeze_start and ms2.freeze_end
      ) then
        return (null, null, null, null, 'membership_frozen')::book_class_result;
      end if;
      v_pay := 'drop_in';

      -- Decision 73 (c): pay at the desk is EARNED. This booking resolved to an
      -- unpaid desk drop-in; refuse it (desk_pay_blocked) when the member has
      -- lost the privilege. 'earned' mode: once they have a no-show or late
      -- cancel on a desk booking (members.desk_pay_blocked_at set). 'first_visit
      -- _only' mode: once they have ever held a desk booking that was not
      -- cancelled in time. The app then shows "pay online to book". Self only; a
      -- desk/staff booking and a studio-offered waitlist promotion are never
      -- blocked, and the instructor desk RPCs do not reach book_class at all.
      if v_is_self and not (v_is_desk or v_trusted)
         and current_setting('studiior.waitlist_promoting', true) is distinct from '1'
         and (
           (coalesce(v_set.desk_pay_mode, 'earned') = 'earned'
              and exists (select 1 from members dm
                           where dm.id = p_member_id and dm.desk_pay_blocked_at is not null))
           or
           (coalesce(v_set.desk_pay_mode, 'earned') = 'first_visit_only'
              and exists (select 1 from bookings db
                           where db.member_id = p_member_id and db.studio_id = v_occ.studio_id
                             and db.payment_source = 'drop_in' and db.status <> 'cancelled'))
         )
      then
        return (null, null, null, null, 'desk_pay_blocked')::book_class_result;
      end if;

      -- Decision 73: a studio may cap how many UNPAID app bookings a member
      -- holds (max_unpaid_bookings; null = no limit = today's behaviour). This
      -- booking has resolved to an unpaid drop-in; if the member already holds
      -- that many unpaid drop-ins, refuse with pay_first — the app then offers
      -- Pay now / Pay at the desk. Self only: a desk booking (money at the
      -- counter) and a studio-offered waitlist promotion are never capped. A
      -- booking counts while it is a live drop-in with no settling payment row;
      -- a desk or Pay-now payment clears it (73b flips payment_source off
      -- drop_in), so a paid booking no longer counts.
      if v_set.max_unpaid_bookings is not null
         and v_is_self and not (v_is_desk or v_trusted)
         and current_setting('studiior.waitlist_promoting', true) is distinct from '1'
         and (
           select count(*) from bookings b
            where b.member_id = p_member_id and b.studio_id = v_occ.studio_id
              and b.payment_source = 'drop_in'
              and b.status in ('booked', 'pending_payment')
              and not exists (select 1 from payments p
                               where p.booking_id = b.id
                                 and p.status in ('succeeded', 'partially_refunded'))
         ) >= v_set.max_unpaid_bookings
      then
        return (null, null, null, null, 'pay_first')::book_class_result;
      end if;
    end if;
  end if;

  -- The seat is held while the member pays for it.
  --
  -- Only when the MEMBER is booking their own drop-in and the studio has a
  -- connected Stripe account. A staff booking at the desk is money changing
  -- hands in the room, and a studio with no Stripe connected has no checkout to
  -- send anyone to — both of those still book outright, exactly as before, which
  -- is also why every existing fixture in the suite is unaffected.
  if v_pay = 'drop_in' and p_source = 'member'
     and exists (
       select 1 from studios s
        where s.id = v_occ.studio_id and s.stripe_account_id is not null
     )
  then
    v_status := 'pending_payment';
  end if;

  -- Decision 103 (p): under 'staff_only' a member never leaves a seat confirmed
  -- and unpaid. Self only; staff, the desk, a studio-offered waitlist promotion
  -- and the online checkout hold (checkout_hold_class) are unchanged.
  if v_pay = 'drop_in' and v_status = 'booked'
     and v_is_self and not (v_is_desk or v_trusted)
     and coalesce(v_set.desk_pay_mode, 'earned') = 'staff_only'
     and current_setting('studiior.waitlist_promoting', true) is distinct from '1'
     and current_setting('studiior.checkout_hold', true) is distinct from '1'
  then
    return (null, null, null, null, 'pay_online')::book_class_result;
  end if;

  -- Decision 15's second half, after §2.2 has resolved who pays. A lead has
  -- bought nothing, so it should always be drop-in by this point; if it is
  -- not, staff have attached a plan to somebody they never activated, and
  -- spending its credits is not what `lead` is meant to allow.
  if v_member.status = 'lead' and v_pay <> 'drop_in' then
    return (null, null, null, null, 'member_not_active')::book_class_result;
  end if;

  -- ===========================================================================
  -- 2.1.9 SUSPENSION — Decision 24.
  --
  -- In the §2.1 gate and not beside the peak rule, because it has nothing to do
  -- with which plan pays: a suspended member is suspended whatever they were
  -- going to book it with, including a drop-in they would have paid cash for.
  --
  -- IT RESTRICTS ADVANCE BOOKING ONLY. Same-day still works, on whatever seats
  -- are left — the penalty is losing the ability to hold a place ahead of
  -- everyone else, not being shut out of the studio. A suspension that stopped
  -- somebody walking in would cost the studio the sale as well as the member the
  -- class, and it would be a harsher thing than any studio described wanting.
  --
  -- The allowance still applies on top: a suspension does not hand out free peak
  -- slots, and a member with nothing left is refused by the rule below whether
  -- or not they are suspended.
  --
  -- Overridable, like the other capacity-shaped rules. A studio that wants to
  -- let somebody in anyway has heard the reason at the counter.
  -- ===========================================================================
  v_susp := member_suspension(p_member_id);
  if v_susp is not null and (v_susp ->> 'suspended')::boolean
     and (v_occ.starts_at at time zone v_tz)::date > v_today
  then
    if v_override then
      v_bypassed := v_bypassed || 'suspended'::text;
    else
      return (null, null, null, null, 'suspended')::book_class_result;
    end if;
  end if;

  -- ===========================================================================
  -- 3b. THE PEAK ALLOWANCE — Decision 24.
  --
  -- AFTER §2.2, and that placement is the whole correctness argument: the plan
  -- that PAYS is the plan held to its allowance. Resolving it up in the §2.1
  -- gate would mean a second plan-priority query beside the one rules 2 and 7
  -- use, and the two would pick the same plan right up until they did not —
  -- a member holding both an unlimited plan and a pack would have the pack's
  -- booking measured against the unlimited plan's allowance.
  --
  -- Only a membership can consume one. A drop-in and a pack cannot carry an
  -- allowance at all (migration 104's CHECK), so `v_pay = 'membership'` is not
  -- an optimisation, it is the rule.
  --
  -- peak_allowance_state() answers null for a plan with no allowance AND for a
  -- studio with the switch off, so a studio that has never heard of this
  -- feature takes one null check and nothing else.
  --
  -- WAITLISTING NEEDS NO SPECIAL CASE. This refuses before §4, so a member with
  -- nothing left cannot join the queue for a peak class either — which is the
  -- honest answer, rather than letting them wait for an offer they could not
  -- accept. And nothing is CONSUMED here: the ledger row is written by the
  -- trigger when a seat actually becomes real, so a waitlisted row costs
  -- nothing and a promotion costs one. `respond_to_offer()` cancels the
  -- waitlist row and calls this function again, so a promotion is measured
  -- against the allowance as it stands at that moment, not at join time.
  -- ===========================================================================
  if v_pay = 'membership' and v_membership is not null
     and occurrence_is_peak(p_occurrence_id)
  then
    v_peak := peak_allowance_state(v_membership,
                                   (v_occ.starts_at at time zone v_tz)::date);
    if v_peak is not null and (v_peak ->> 'remaining')::int <= 0 then
      if v_override then
        v_bypassed := v_bypassed || 'peak_allowance'::text;
      else
        return (null, null, null, null, 'peak_allowance_exhausted')::book_class_result;
      end if;
    end if;
  end if;

  -- ===========================================================================
  -- 4. Capacity — §2.1.10, §4.1, §5. booked_count was read under the lock.
  -- ===========================================================================

  -- §4.2: a pending waitlist offer HOLDS its seat — the offered member was
  -- formally offered it, and general booking must not take it from under them.
  -- Derived from live offers at gate time rather than cached: booked_count goes
  -- on counting real seats only, so the nightly reconcile stays a no-op, and the
  -- hold ends the instant the offer does (expired-but-unswept offers hold
  -- nothing — occurrence_seats_held gates on expires_at > now()). The offered
  -- member's own offer is excluded, or accepting through respond_to_offer would
  -- be refused for the very seat they were offered.
  v_held      := occurrence_seats_held(p_occurrence_id, p_member_id);
  v_phys_full := v_occ.booked_count >= v_occ.capacity;
  v_full      := (v_occ.booked_count + v_held) >= v_occ.capacity;

  if v_full and not v_override then
    if not v_set.waitlist_enabled then
      return (null, null, null, null, 'class_full')::book_class_result;
    end if;

    -- §4.4: no promotions inside waitlist_cutoff_minutes, so joining there is
    -- an offer that can never be made.
    if v_occ.starts_at < now() + make_interval(mins => v_set.waitlist_cutoff_minutes) then
      return (null, null, null, null, 'waitlist_closed')::book_class_result;
    end if;

    -- §4.1: strictly FIFO, no priority tiers in V1, and NO credit consumed on
    -- joining. The paying source is re-resolved when the offer is accepted
    -- (§4.2.4), so it is deliberately left null on the row — including for a
    -- comp, whose comp intent must be supplied again at promotion.
    select coalesce(max(waitlist_position), 0) + 1
      into v_position
      from bookings
     where occurrence_id = p_occurrence_id
       and status = 'waitlisted';

    insert into bookings (
      studio_id, occurrence_id, member_id, status, source,
      payment_source, membership_id, waitlist_position
    ) values (
      v_occ.studio_id, p_occurrence_id, p_member_id, 'waitlisted', p_source,
      null, null, v_position
    ) returning id into v_booking_id;

    update class_occurrences
       set waitlist_count = waitlist_count + 1
     where id = p_occurrence_id;

    return (v_booking_id, 'waitlisted'::booking_status, null, v_position, null)
           ::book_class_result;
  end if;

  if v_full then
    -- §2.3 / §5 / §14: a staff override reaches here. Two shapes, told apart for
    -- the audit: physically full is a walk-in booked OVER capacity; held-only is
    -- the desk deliberately taking a seat reserved for a waitlisted member (the
    -- offer stands and will fail on acceptance — a deliberate act, §14). The hold
    -- is never applied to an override, so front desk can always seat someone.
    if v_phys_full then
      v_bypassed := v_bypassed || 'capacity'::text;
    else
      v_bypassed := v_bypassed || 'held_seat'::text;
    end if;
  end if;

  -- ===========================================================================
  -- 5. Write. Booking, ledger and booked_count, one transaction.
  -- ===========================================================================

  insert into bookings (
    studio_id, occurrence_id, member_id, status, source,
    payment_source, membership_id, override_reason, overridden_rules
  ) values (
    v_occ.studio_id, p_occurrence_id, p_member_id, v_status, p_source,
    v_pay, case when v_pay in ('membership','class_pack') then v_membership end,
    -- §2.3: a reason that bypassed nothing was not an override, so it is not
    -- recorded as one.
    case when array_length(v_bypassed, 1) is not null then p_override_reason end,
    case when array_length(v_bypassed, 1) is not null then v_bypassed end
  ) returning id into v_booking_id;

  if v_consume then
    -- §6: the balance is derived from the ledger, never edited in place, and
    -- every row carries balance_after so any point in history is
    -- reconstructable without replaying. balance_after is the member's total
    -- credit balance across every source; the member row lock above makes the
    -- read-then-write safe.
    select coalesce(sum(delta), 0) into v_balance
      from credit_ledger
     where studio_id = v_occ.studio_id
       and member_id = p_member_id;

    insert into credit_ledger (
      studio_id, member_id, membership_id, delta, reason,
      booking_id, balance_after, expires_at, actor_user_id
    )
    select v_occ.studio_id, p_member_id, v_membership, -1, 'booking',
           v_booking_id, v_balance - 1,
           case when ms.expires_on is not null
                then (ms.expires_on + 1)::timestamp at time zone v_tz end,
           v_actor
      from memberships ms
     where ms.id = v_membership
    returning id into v_ledger_id;

    -- credits_remaining is a cache. Written in the same transaction as the
    -- ledger row, never independently of it.
    update memberships
       set credits_remaining = credits_remaining - 1
     where id = v_membership;

    update bookings set credit_entry_id = v_ledger_id where id = v_booking_id;
  end if;

  update class_occurrences
     set booked_count = booked_count + 1
   where id = p_occurrence_id;

  -- §2.3 / §13: every override that actually bypassed a rule is audited with
  -- actor and reason. The booking row carries the same reason (above) so it is
  -- visible without a join to audit_logs.
  if v_override and array_length(v_bypassed, 1) is not null then
    insert into audit_logs (
      studio_id, actor_user_id, action, entity_table, entity_id, after
    ) values (
      v_occ.studio_id, v_actor, 'booking.override', 'bookings', v_booking_id,
      jsonb_build_object(
        'reason',        p_override_reason,
        'rules_bypassed', to_jsonb(v_bypassed),
        'occurrence_id', p_occurrence_id,
        'member_id',     p_member_id,
        'over_capacity', v_occ.booked_count + 1 > v_occ.capacity
      )
    );
  end if;

  -- Decision 30 amendment: a seat that counts toward the headcount may have just
  -- completed a free class's confirm-at total, confirming its provisional free
  -- seats at once. A no-op when the class has none or is still short.
  if v_status in ('booked', 'pending_payment') then
    perform confirm_provisional_seats_run(p_occurrence_id);
  end if;

  -- The caller needs to know it is holding rather than booked, because that is
  -- what decides whether the member is sent to Checkout next.
  return (v_booking_id, v_status, v_pay, null, null)
         ::book_class_result;
end $function$;

CREATE OR REPLACE FUNCTION public.choose_pay_at_desk(p_booking_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare b bookings%rowtype; m members%rowtype; v_price int; v_currency char(3); v_pay uuid;
begin
  select * into b from bookings where id = p_booking_id;
  if not found then
    raise exception 'no such booking' using errcode = 'PT404';
  end if;
  select * into m from members where id = b.member_id;

  -- The member themselves, or staff doing it for them at the counter.
  if not (coalesce(m.user_id = auth.uid(), false) or is_desk_up(b.studio_id)) then
    raise exception 'that is not your booking' using errcode = 'PT403';
  end if;
  if b.status <> 'pending_payment' then
    raise exception 'that booking is not waiting on a payment' using errcode = 'PT409';
  end if;
  -- Decision 103 (p): under 'staff_only' only front desk and up choose this.
  if not coalesce(is_desk_up(b.studio_id), false)
     and coalesce((select desk_pay_mode from studio_settings where studio_id = b.studio_id), 'earned') = 'staff_only' then
    raise exception 'Pay online to book this class.' using errcode = 'PT409';
  end if;

  perform confirm_dropin_payment(b.studio_id, b.id);

  select mp.price_cents, mp.currency into v_price, v_currency
    from membership_plans mp
   where mp.studio_id = b.studio_id and mp.type = 'drop_in' and mp.status = 'active'
   order by mp.sort_order limit 1;

  -- Pending, not succeeded: nothing has been paid. This row is the reason the
  -- desk knows to ask, and record_manual_payment() settles it when they do.
  insert into payments (studio_id, member_id, booking_id, amount_cents, currency,
                        status, provider, description)
  values (b.studio_id, b.member_id, b.id,
          coalesce(v_price, 0), coalesce(v_currency, (select currency from studios where id = b.studio_id)),
          'pending', 'manual', 'Drop-in class — to pay at the studio')
  returning id into v_pay;

  return jsonb_build_object('booking_id', b.id, 'payment_id', v_pay, 'status', 'booked');
end $function$;

CREATE OR REPLACE FUNCTION public.member_bootstrap(p_slug text)
 RETURNS TABLE(member_id uuid, studio_id uuid, first_name text, last_name text, preferred_name text, avatar_path text, status member_status, current_streak integer, lifetime_visits integer, studio_name text, studio_timezone text, logo_url text, theme_preset theme_preset, accent_color text, checkin_opens_minutes_before integer, checkin_closes_minutes_after integer, cancellation_cutoff_minutes integer, booking_cutoff_minutes integer, waitlist_enabled boolean, billing_status platform_status, billing_locked boolean, open_offers integer, guest_passes_enabled boolean, has_payment_provider boolean, booking_window_days integer, how_to_buy text, studio_contact_email text, xendit_enabled boolean, time_format text, trial_used boolean, messages_enabled boolean, has_unread_studio_message boolean, desk_pay_available boolean, payee_notice_name text, has_phone boolean, country text, free_first_reservation_fee_cents integer, currency text, fee_waived boolean, reservation_credit_cents integer, free_first_core_only boolean, guarantees_enabled boolean, can_invite_guest boolean, gift_credit_cents integer, private_sessions_enabled boolean, gift_enabled boolean, private_pack_credits integer, private_lead_time_hours integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    exists (select 1 from memberships ms
              join membership_plans mp on mp.id = ms.plan_id
             where ms.member_id = m.id and mp.type = 'trial'),
    coalesce(st.messages_enabled, false),
    coalesce(st.messages_enabled, false) and exists (
      select 1 from message_threads mt
        join thread_messages msg on msg.thread_id = mt.id
       where mt.member_id = m.id and msg.sender_kind = 'staff'
         and msg.created_at > coalesce(mt.last_member_read_at, 'epoch'::timestamptz)),
    not (
      coalesce(st.desk_pay_mode, 'earned') = 'staff_only'
      or (coalesce(st.desk_pay_mode, 'earned') = 'earned' and m.desk_pay_blocked_at is not null)
      or (coalesce(st.desk_pay_mode, 'earned') = 'first_visit_only'
          and exists (select 1 from bookings bdp
                       where bdp.member_id = m.id and bdp.studio_id = m.studio_id
                         and bdp.payment_source = 'drop_in' and bdp.status <> 'cancelled'))
    ),
    st.payee_notice_name,
    (nullif(btrim(coalesce(m.phone, '')), '') is not null),
    s.country,
    coalesce(st.free_first_reservation_fee_cents, 0),
    s.currency,
    (m.reservation_fee_waived_at is not null),
    coalesce((select sum(mc.amount_cents - mc.used_cents)::int from member_credits mc
               where mc.studio_id = m.studio_id and mc.member_id = m.id and mc.voided_at is null), 0),
    coalesce(st.free_first_core_only, false),
    -- Decision 22 amendment: the member Book and class readers tint a core
    -- class only when the studio runs guarantees.
    coalesce(st.guarantees_enabled, false),
    -- Decision 26(c): the member may invite a guest when the studio does not
    -- gate invites, or when they hold a usable plan.
    ((not coalesce(st.guest_invites_members_only, false))
      or exists (select 1 from memberships ms2
                  where ms2.member_id = m.id and ms2.status in ('active', 'trialing')
                    and (ms2.credits_remaining is null or ms2.credits_remaining > 0))),
    -- Decision 110(a): the Account Credits card names gift credit apart from the
    -- reservation and refund credit (reservation_credit_cents stays the TOTAL the
    -- checkout applies).
    coalesce((select sum(mc.amount_cents - mc.used_cents)::int from member_credits mc
               where mc.studio_id = m.studio_id and mc.member_id = m.id and mc.voided_at is null
                 and mc.reason = 'gift_credit'), 0),
    -- Decision 116: the Book tab offers Private sessions when the studio does.
    coalesce(st.private_sessions_enabled, false)
      and exists (select 1 from private_session_types pst where pst.studio_id = m.studio_id and pst.active),
    coalesce(st.gift_enabled, false),
    coalesce((select sum(ms3.credits_remaining)::int from memberships ms3
               join membership_plans mp3 on mp3.id = ms3.plan_id
              where ms3.member_id = m.id and mp3.private_pack
                and ms3.status in ('active', 'trialing') and coalesce(ms3.credits_remaining, 0) > 0
                and (ms3.expires_on is null or ms3.expires_on >= (now() at time zone s.timezone)::date)), 0),
    coalesce(st.private_lead_time_hours, 24)
  from members m
  join studios s on s.id = m.studio_id
  left join studio_settings st on st.studio_id = m.studio_id
  left join platform_subscriptions ps on ps.studio_id = m.studio_id
  where m.user_id = auth.uid()
    and s.slug = p_slug
  limit 1
$function$;

-- The online checkout hold (Decision 88): the seat is held by book_class exactly
-- as before, under a flag that 103 (p)'s staff_only refusal steps aside for.
create or replace function checkout_hold_class(p_occurrence_id uuid)
returns book_class_result language plpgsql security definer set search_path = public as $$
declare v_member uuid; v_studio uuid; r book_class_result;
begin
  select studio_id into v_studio from class_occurrences where id = p_occurrence_id;
  if v_studio is null then raise exception 'no such class' using errcode = 'PT404'; end if;
  select id into v_member from members
   where studio_id = v_studio and user_id = auth.uid() and deleted_at is null;
  if v_member is null then
    raise exception 'you are not a member of that studio' using errcode = 'PT403';
  end if;
  perform set_config('studiior.checkout_hold', '1', true);
  r := book_class(p_occurrence_id, v_member, 'member'::booking_source);
  perform set_config('studiior.checkout_hold', '', true);
  return r;
end $$;
revoke execute on function checkout_hold_class(uuid) from public, anon;
grant  execute on function checkout_hold_class(uuid) to authenticated, service_role;

drop function if exists set_occurrence_day_tier(uuid, text);

create or replace function set_occurrence_day_tier_run(p_occurrence_id uuid, p_tier text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o class_occurrences%rowtype; st studio_settings%rowtype; s studios%rowtype;
        v_dir text; v_min int; v_cut timestamptz; v_tz text; v_fmt text; r record; v_restore boolean;
begin
  if p_tier not in ('core','flex') then
    raise exception 'tier must be core or flex' using errcode = 'PT422';
  end if;
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(o.studio_id), false) then
    raise exception 'only owners and managers change the timetable' using errcode = 'PT403';
  end if;
  if o.status <> 'scheduled' or o.committed_at is not null or now() >= o.starts_at then
    raise exception 'decided at the cut-off' using errcode = 'PT409';
  end if;
  select * into st from studio_settings where studio_id = o.studio_id;
  select * into s  from studios where id = o.studio_id;
  v_tz := s.timezone; v_fmt := coalesce(st.time_format, '24h');

  -- A flip back to the saved original direction restores the saved values.
  v_restore := o.day_tier_saved is not null and p_tier = (o.day_tier_saved ->> 'dir');
  if v_restore then
    update class_occurrences
       set flex = (o.day_tier_saved ->> 'flex')::boolean,
           minimum_bookings = nullif(o.day_tier_saved ->> 'minimum_bookings','')::int,
           guarantee_tier = nullif(o.day_tier_saved ->> 'guarantee_tier','')::guarantee_tier,
           day_tier_saved = null, updated_at = now()
     where id = p_occurrence_id;

    -- Decision 21 (e): switching to flex clears stale reached-minimum marks on an
    -- uncommitted class (the guard above refuses a committed one) and re-latches
    -- only if paid seats already meet the new minimum (paid = the 81b predicate).
    if p_tier = 'flex' then
      update class_occurrences
         set flex_reached_minimum_at = null, core_reached_minimum_at = null
       where id = p_occurrence_id;
      select minimum_bookings into v_min from class_occurrences where id = p_occurrence_id;
      if v_min is not null and (select count(*) from bookings b
           where b.occurrence_id = p_occurrence_id
             and b.status in ('booked','attended','no_show','pending_payment')
             and not (coalesce(b.payment_source = 'drop_in', false)
                      and not exists (select 1 from payments pmt
                                       where pmt.booking_id = b.id
                                         and pmt.status in ('succeeded','partially_refunded')))) >= v_min then
        update class_occurrences set flex_reached_minimum_at = now() where id = p_occurrence_id;
      end if;
    end if;
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (o.studio_id, auth.uid(), 'occurrence.day_tier_restored', 'class_occurrences', p_occurrence_id,
            jsonb_build_object('to', p_tier));
    return jsonb_build_object('ok', true, 'occurrence_id', p_occurrence_id, 'tier', p_tier, 'restored', true);
  end if;

  -- Otherwise apply the override, saving the original once.
  select case when g.tier = 'flex' then 'flex' else 'core' end into v_dir
    from occurrence_guarantee_run(p_occurrence_id) g;
  if o.day_tier_saved is null then
    update class_occurrences
       set day_tier_saved = jsonb_build_object('dir', v_dir, 'flex', o.flex,
             'minimum_bookings', o.minimum_bookings, 'guarantee_tier', o.guarantee_tier)
     where id = p_occurrence_id;
  end if;

  if p_tier = 'flex' then
    v_min := coalesce(st.flex_min_bookings, 2);
    update class_occurrences
       set flex = true, minimum_bookings = v_min, guarantee_tier = null, updated_at = now()
     where id = p_occurrence_id;

    -- Decision 21 (e): switching to flex clears stale reached-minimum marks on an
    -- uncommitted class (the guard above refuses a committed one) and re-latches
    -- only if paid seats already meet the new minimum (paid = the 81b predicate).
    if p_tier = 'flex' then
      update class_occurrences
         set flex_reached_minimum_at = null, core_reached_minimum_at = null
       where id = p_occurrence_id;
      select minimum_bookings into v_min from class_occurrences where id = p_occurrence_id;
      if v_min is not null and (select count(*) from bookings b
           where b.occurrence_id = p_occurrence_id
             and b.status in ('booked','attended','no_show','pending_payment')
             and not (coalesce(b.payment_source = 'drop_in', false)
                      and not exists (select 1 from payments pmt
                                       where pmt.booking_id = b.id
                                         and pmt.status in ('succeeded','partially_refunded')))) >= v_min then
        update class_occurrences set flex_reached_minimum_at = now() where id = p_occurrence_id;
      end if;
    end if;
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (o.studio_id, auth.uid(), 'occurrence.day_tier_flex', 'class_occurrences', p_occurrence_id,
            jsonb_build_object('minimum_bookings', v_min));
    -- Tell members already booked that it now runs only if it reaches the minimum.
    select cutoff_at into v_cut from occurrence_guarantee_run(p_occurrence_id);
    for r in select b.member_id from bookings b
               where b.occurrence_id = p_occurrence_id and b.status in ('booked','pending_payment') loop
      perform queue_notification(o.studio_id, r.member_id, 'day_tier_flex',
        jsonb_build_object('class_name', coalesce(o.name, (select name from class_types where id = o.class_type_id)),
          'when', to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMonth') || ' at ' || fmt_clock(o.starts_at, v_tz, v_fmt),
          'min', v_min::text,
          'cutoff', case when v_cut is not null then fmt_clock(v_cut, v_tz, v_fmt) || ' on ' || to_char(v_cut at time zone v_tz, 'FMDay FMDD FMMonth') else 'the cut-off' end,
          'manage_link', member_portal_url(o.studio_id, '/class/' || o.id),
          'book_url', member_portal_url(o.studio_id, '/book')),
        'day_flex:' || p_occurrence_id::text || ':' || r.member_id::text);
    end loop;
  else
    -- Core today on a flex class: runs regardless of bookings (the always path).
    update class_occurrences
       set guarantee_tier = 'always'::guarantee_tier, updated_at = now()
     where id = p_occurrence_id;
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (o.studio_id, auth.uid(), 'occurrence.day_tier_core', 'class_occurrences', p_occurrence_id,
            jsonb_build_object('runs_regardless', true));
  end if;
  return jsonb_build_object('ok', true, 'occurrence_id', p_occurrence_id, 'tier', p_tier, 'restored', false);
end $$;
revoke execute on function set_occurrence_day_tier_run(uuid, text) from public, anon, authenticated;
grant  execute on function set_occurrence_day_tier_run(uuid, text) to service_role;

-- Decision 21 (h): a switch to flex after the flex cut-off and under the
-- minimum cancels the class, so it is refused unless confirmed.
create or replace function set_occurrence_day_tier(p_occurrence_id uuid, p_tier text,
                                                   p_confirm_cancel boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o class_occurrences%rowtype; v jsonb; v_cut timestamptz; v_paid int; v_min int;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(o.studio_id), false) then
    raise exception 'only owners and managers change the timetable' using errcode = 'PT403';
  end if;
  if p_tier is distinct from 'flex' then
    return set_occurrence_day_tier_run(p_occurrence_id, p_tier);
  end if;
  begin
    v := set_occurrence_day_tier_run(p_occurrence_id, p_tier);
    select g.cutoff_at into v_cut from occurrence_guarantee_run(p_occurrence_id) g;
    select minimum_bookings into v_min from class_occurrences where id = p_occurrence_id;
    v_paid := coalesce(occurrence_paid_count_run(p_occurrence_id), 0);
    if v_cut is not null and now() >= v_cut and v_paid < coalesce(v_min, 0) then
      if not coalesce(p_confirm_cancel, false) then
        raise exception 'confirm_cancel' using errcode = 'PTW21';
      end if;
      -- Confirmed: the cut-off has passed, so the class is decided now. The
      -- booked members get the not-running email, not the flex-today one too.
      delete from notifications
       where dedupe_key like 'day_flex:' || p_occurrence_id::text || ':%'
         and status = 'scheduled' and created_at = now();
      perform evaluate_commitment(p_occurrence_id);
      v := v || jsonb_build_object('cancelled',
             (select status = 'cancelled' from class_occurrences where id = p_occurrence_id));
    end if;
  exception when sqlstate 'PTW21' then
    return jsonb_build_object('ok', false, 'reason', 'confirm_cancel',
                              'booked', v_paid, 'min', v_min, 'occurrence_id', p_occurrence_id);
  end;
  return v;
end $$;
revoke execute on function set_occurrence_day_tier(uuid, text, boolean) from public, anon;
grant  execute on function set_occurrence_day_tier(uuid, text, boolean) to authenticated, service_role;

-- ---- 22 (g): the public schedule cache is cleared on every change -----------
create or replace function tg_public_schedule_bust()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_studio uuid;
begin
  if tg_op = 'DELETE' then v_studio := old.studio_id; else v_studio := new.studio_id; end if;
  delete from public_schedule_cache c
   using studios s where s.id = v_studio and c.slug = s.slug;
  return null;
end $$;
revoke execute on function tg_public_schedule_bust() from public, anon, authenticated;

drop trigger if exists class_occurrences_public_schedule_bust on class_occurrences;
create trigger class_occurrences_public_schedule_bust
  after insert or delete or update of status, starts_at, ends_at, instructor_id, room_id,
    capacity, hidden_from_members, guarantee_tier, flex, minimum_bookings, name, class_type_id,
    cancellation_cause, committed_at, flex_reached_minimum_at
  on class_occurrences for each row execute function tg_public_schedule_bust();

drop trigger if exists class_series_public_schedule_bust on class_series;
create trigger class_series_public_schedule_bust
  after update of guarantee_tier, flex, minimum_bookings, status
  on class_series for each row execute function tg_public_schedule_bust();

drop trigger if exists studio_settings_public_schedule_bust on studio_settings;
create trigger studio_settings_public_schedule_bust
  after update of guarantees_enabled, flex_enabled, hide_unstaffed_from_members,
    public_instructor_name, time_format, booking_window_days
  on studio_settings for each row execute function tg_public_schedule_bust();

create or replace function apply_payment_refund(p_refund_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare rf payment_refunds%rowtype; pay payments%rowtype; ms memberships%rowtype;
        plan membership_plans%rowtype; v_total int; v_full boolean; v_bal int; v_take int := 0;
begin
  select * into rf from payment_refunds where id = p_refund_id for update;
  if not found then return; end if;
  select * into pay from payments where id = rf.payment_id for update;
  if not found then return; end if;

  v_total := coalesce(pay.refunded_cents, 0) + rf.amount_cents;
  v_full  := v_total >= pay.amount_cents;
  update payments
     set refunded_cents = v_total, refunded_at = now(),
         refund_reason = coalesce(rf.reason, refund_reason),
         status = (case when v_full then 'refunded' else 'partially_refunded' end)::payment_status,
         updated_at = now()
   where id = pay.id;

  -- Decision 103: refunding a reservation fee removes the UNUSED remainder of its
  -- credit (used stays used). refund_payment already refused a spent credit.
  if pay.kind = 'reservation_fee' then
    update member_credits set used_cents = amount_cents, voided_at = now()
     where payment_id = pay.id and voided_at is null;
  end if;

  -- Decision 110(a): refunding a gift card sale voids the card (refund_payment
  -- has already refused one that was redeemed). Nobody is emailed about the void.
  if pay.gift_card_id is not null then
    update gift_cards set status = 'void', voided_at = now(), voided_by = rf.refunded_by,
           void_reason = coalesce(rf.reason, 'refunded')
     where id = pay.gift_card_id and status in ('pending', 'active');
  end if;

  -- A full refund of a membership payment cancels the membership and claws back
  -- unused pack credits (mirrors record_refund).
  if v_full and pay.membership_id is not null then
    select * into ms from memberships where id = pay.membership_id;
    select * into plan from membership_plans where id = ms.plan_id;
    if plan.type = 'class_pack' then
      select coalesce(sum(delta), 0) into v_bal from credit_ledger
       where studio_id = pay.studio_id and member_id = pay.member_id;
      v_take := least(coalesce(ms.credits_remaining, 0), greatest(v_bal, 0));
      if v_take > 0 then
        insert into credit_ledger (studio_id, member_id, membership_id, delta, reason, balance_after, actor_user_id)
        values (pay.studio_id, pay.member_id, ms.id, -v_take, 'manual', v_bal - v_take, rf.refunded_by);
        update memberships set credits_remaining = coalesce(credits_remaining, 0) - v_take where id = ms.id;
      end if;
    end if;
    update memberships set status = 'cancelled', cancelled_at = now(),
           cancellation_reason = coalesce(rf.reason, 'refunded')
     where id = ms.id and status <> 'cancelled';
  end if;

  -- Decision 110(a): a gift sale has no member (the buyer may have no account),
  -- so its refund email is addressed to the buyer's email; nobody else is told.
  if pay.member_id is null and (pay.gift_card_id is null
     or (select coalesce(btrim(buyer_email), '') from gift_cards where id = pay.gift_card_id) = '') then
    return;
  end if;
  -- Decision 111 (b): payment_refunded only when money moves.
  if coalesce(rf.amount_cents, 0) <= 0 then return; end if;
  perform queue_notification(pay.studio_id, pay.member_id, 'payment_refunded',
    (case when pay.member_id is null
          then jsonb_build_object('to_email', (select buyer_email from gift_cards where id = pay.gift_card_id))
          else '{}'::jsonb end) ||
    jsonb_build_object(
      'amount', fmt_money(rf.amount_cents, rf.currency),
      'method', case rf.method
                  when 'xendit' then 'card or GCash'
                  when 'card_terminal' then 'card'
                  when 'bank_transfer' then 'bank transfer'
                  when 'gcash' then 'GCash'
                  when 'cash' then 'cash' else 'the studio' end,
      'reference', coalesce(rf.xendit_refund_id, rf.reference, 'n/a')),
    'payment_refunded:' || rf.id);
end $$;

CREATE OR REPLACE FUNCTION public.queue_occurrence_cancelled(p_occurrence_id uuid, p_cause cancellation_cause DEFAULT NULL::cancellation_cause)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o class_occurrences%rowtype; s studios%rowtype; r record; n int := 0;
        v_when text; v_when_short text; v_base text; v_fmt text;
        v_list_txt text; v_list_html text; v_line_txt text; v_line_html text;
        v_notice boolean := coalesce(current_setting('studiior.closure_notice', true), '') = '1';
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  select * into s from studios where id = o.studio_id;
  select coalesce(time_format, '24h') into v_fmt from studio_settings where studio_id = o.studio_id;
  v_fmt := coalesce(v_fmt, '24h');
  v_when := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY');
  v_when_short := to_char(o.starts_at at time zone s.timezone, 'FMDy FMDD FMMon ')
                 || fmt_clock(o.starts_at, s.timezone, v_fmt);
  v_base := 'https://' || s.slug || '.'
            || coalesce(notification_setting('member_app_domain'), 'studiior.app') || '/class/';

  -- Decision 77: under the closure-notice flag, the member gets ONE
  -- studio_closure_notice instead of a per-class class_cancelled — skip these.
  if not v_notice then
  for r in select b.member_id,
                  -- Decision 111 (b): say what came back.
                  case when b.credit_entry_id is not null then 'Your class credit is back on your account.'
                       when b.payment_source = 'comp' and exists (
                              select 1 from guest_passes gp where gp.guest_booking_id = b.id
                                 and gp.host_member_id is null) then 'Your free first class is still yours.'
                       when b.payment_source = 'membership' then 'Nothing has been used from your membership.'
                       when b.payment_source = 'drop_in' and not exists (
                              select 1 from payments p where p.booking_id = b.id
                                 and p.status in ('succeeded','partially_refunded')) then 'Nothing was charged.'
                       when b.payment_source = 'drop_in' then 'The studio will be in touch about your payment.'
                       else 'Nothing has been used.' end as returned_line
             from bookings b
            where b.occurrence_id = p_occurrence_id
              and b.status in ('booked','waitlisted')
  loop
    if p_cause = 'unmet_minimum' then
      -- Up to three upcoming, scheduled, published classes with a free space.
      select string_agg(x.line, '; ' order by x.starts_at),
             string_agg('<a href="' || v_base || x.id || '">' || x.line || '</a>', ', ' order by x.starts_at)
        into v_list_txt, v_list_html
        from (
          select o2.id, o2.starts_at,
                 to_char(o2.starts_at at time zone s.timezone, 'FMDay ') || fmt_clock(o2.starts_at, s.timezone, v_fmt) || ' ' || o2.name as line
            from class_occurrences o2
           where o2.studio_id = o.studio_id
             and o2.status = 'scheduled' and not o2.hidden_from_members
             and o2.starts_at > now()
             and o2.id <> p_occurrence_id
             and coalesce(o2.booked_count, 0) < o2.capacity
             and occurrence_published(o2.id)
           order by o2.starts_at
           limit 3) x;
      v_line_txt  := case when v_list_txt  is null then '' else ' Here are the next ones with space: ' || v_list_txt || '.' end;
      v_line_html := case when v_list_html is null then '' else '<p>Here are the next ones with space: ' || v_list_html || '.</p>' end;

      if queue_notification(o.studio_id, r.member_id, 'flex_booking_not_confirmed',
            jsonb_build_object('class_name', o.name, 'when', v_when, 'day_short', v_when_short,
              'time', fmt_clock(o.starts_at, s.timezone, v_fmt),
              -- Decision 21 amendment (20 Oct 2026): the plain subject reads {day}.
              'day', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth'),
              'next_three_line', v_line_txt, 'next_three_html', v_line_html,
              'manage_link', member_portal_url(o.studio_id, '/class/' || p_occurrence_id),
              'book_url', member_portal_url(o.studio_id, '/book'),
              'occurrence_id', p_occurrence_id),
            'class_cancelled:' || p_occurrence_id || ':' || r.member_id) is not null
      then n := n + 1; end if;
    else
      if queue_notification(o.studio_id, r.member_id, 'class_cancelled',
            jsonb_build_object('class_name', o.name, 'when', v_when,
                               'returned_line', r.returned_line,
                               'manage_link', member_portal_url(o.studio_id, '/class/' || p_occurrence_id),
                               'book_url', member_portal_url(o.studio_id, '/book'),
                               'occurrence_id', p_occurrence_id),
            'class_cancelled:' || p_occurrence_id || ':' || r.member_id) is not null
      then n := n + 1; end if;
    end if;
  end loop;
  end if;

  update notifications set status = 'cancelled'
   where status = 'scheduled'
     and dedupe_key like 'class_reminder:%'
     and payload ->> 'class_name' = o.name
     and member_id in (select member_id from bookings where occurrence_id = p_occurrence_id);

  return n;
end $function$;

update notification_templates
   set text_body = replace(text_body, 'Your credit is back on your account — nothing has been used.', '{returned_line}'),
       html_body = replace(html_body, 'Your credit is back on your account — nothing has been used.', '{returned_line}')
 where key = 'class_cancelled';
do $$ begin
  if not exists (select 1 from notification_templates where key = 'class_cancelled'
                  and text_body like '%{returned_line}%' and html_body like '%{returned_line}%') then
    raise exception 'class_cancelled template not updated';
  end if;
end $$;

CREATE OR REPLACE FUNCTION public.template_sample_context(p_studio_id uuid, p_to_email text, p_first_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s studios%rowtype; st studio_settings%rowtype; v_tz text; v_fmt text;
  v_plan membership_plans%rowtype; o record; v_when text; v_offer_ends text;
  v_n3 text; v_n3line text; v_n3html text; v_links text;
  v_clist text; v_roster text; v_roster_html text; v_li text;
  v_fee text;
begin
  select * into s from studios where id = p_studio_id;
  select * into st from studio_settings where studio_id = p_studio_id;
  v_tz := s.timezone; v_fmt := coalesce(st.time_format, '24h');
  v_fee := fmt_money(coalesce(nullif(st.free_first_reservation_fee_cents, 0), 15000), s.currency);

  select o2.id, coalesce(ct.name, o2.name, 'a class') as cname, o2.starts_at,
         rm.name as room, split_part(coalesce(i.display_name, ''), ' ', 1) as instr
    into o
    from class_occurrences o2
    left join class_types ct on ct.id = o2.class_type_id
    left join rooms rm on rm.id = o2.room_id
    left join instructors i on i.id = o2.instructor_id
   where o2.studio_id = p_studio_id and o2.status = 'scheduled' and o2.starts_at > now()
   order by o2.starts_at limit 1;

  if st.intro_offer_plan_id is not null then
    select * into v_plan from membership_plans where id = st.intro_offer_plan_id;
  end if;
  if v_plan.id is null then
    select * into v_plan from membership_plans
     where studio_id = p_studio_id and status = 'active' order by sort_order limit 1;
  end if;

  v_when := case when o.starts_at is not null
    then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD Mon') || ' at ' || fmt_clock(o.starts_at, v_tz, v_fmt)
    else '' end;
  v_offer_ends := to_char((now() + interval '14 days') at time zone v_tz, 'FMDD Mon YYYY');

  with s3(nm, ts) as (
    values
      ('Reformer Flow', ((((now() at time zone v_tz)::date + 1) + time '07:00') at time zone v_tz)),
      ('Barre',         ((((now() at time zone v_tz)::date + 2) + time '18:00') at time zone v_tz)),
      ('Mat Pilates',   ((((now() at time zone v_tz)::date + 3) + time '09:00') at time zone v_tz))
  )
  select
    string_agg(to_char(ts at time zone v_tz, 'FMDy ') || fmt_clock(ts, v_tz, v_fmt) || ' ' || nm, '; ' order by ts),
    string_agg('<a href="' || member_portal_url(p_studio_id, '/book') || '">'
               || to_char(ts at time zone v_tz, 'FMDy ') || fmt_clock(ts, v_tz, v_fmt) || ' ' || nm || '</a>', ', ' order by ts),
    string_agg(to_char(ts at time zone v_tz, 'FMDay FMDD FMMon, ') || fmt_clock(ts, v_tz, v_fmt) || ' ' || nm, E'\n' order by ts),
    string_agg('<li>' || to_char(ts at time zone v_tz, 'FMDay FMDD FMMon, ') || fmt_clock(ts, v_tz, v_fmt) || ' ' || nm || '</li>', '' order by ts)
    into v_n3, v_links, v_roster, v_li
    from s3;
  v_clist := v_roster;
  v_roster_html := '<ul style="margin:0;padding-left:20px">' || v_li || '</ul>';
  v_n3line := ' Here are the next ones with space: ' || v_n3 || '.';
  v_n3html := '<p>Here are the next ones with space: ' || v_links || '.</p>';

  return jsonb_build_object(
    'to_email', p_to_email,
    'first_name', p_first_name,
    'studio_name', s.name,
    'class_name', coalesce(o.cname, 'a class'),
    'occurrence_id', o.id,
    'when', v_when,
    'where_line', case when nullif(o.room, '') is not null then ', in ' || o.room else '' end,
    'when_short', 'tomorrow',
    'when_time', case when o.starts_at is not null then fmt_clock(o.starts_at, v_tz, v_fmt) else '' end,
    'day', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMonth') else 'Monday 9 November' end,
    'time', case when o.starts_at is not null then fmt_clock(o.starts_at, v_tz, v_fmt) else '' end,
    'deadline_short', case when o.starts_at is not null then fmt_clock(o.starts_at - interval '12 hours', v_tz, v_fmt) || ' ' || to_char((o.starts_at - interval '12 hours') at time zone v_tz, 'FMDy') else 'the evening before' end,
    'cancel_deadline', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD Mon') else 'the day before' end,
    'manage_link', member_portal_url(p_studio_id, '/class/' || coalesce(o.id::text, '')),
    'book_url', member_portal_url(p_studio_id, '/book'),
    'schedule_url', member_portal_url(p_studio_id, '/book'),
    'offer_plan_name', coalesce(v_plan.name, 'a membership'),
    'offer_detail', coalesce(plan_card_detail(v_plan.id), ''),
    'offer_price', case when v_plan.id is not null then fmt_money(v_plan.price_cents, v_plan.currency) else '' end,
    'offer_ends', v_offer_ends, 'offer_plan_id', v_plan.id,
    'buy_url', case when v_plan.id is not null then member_portal_url(p_studio_id, '/buy/' || v_plan.id::text) else member_portal_url(p_studio_id, '/account/plan') end,
    'plan_name', coalesce(v_plan.name, 'your plan'),
    'credits', '3', 'credits_left', '3',
    'expires_on', v_offer_ends, 'ends_on', v_offer_ends,
    'renew_url', case when v_plan.id is not null then member_portal_url(p_studio_id, '/buy/' || v_plan.id::text) else member_portal_url(p_studio_id, '/account/plan') end,
    'last_class', coalesce(o.cname, 'your class'),
    'last_class_date', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDD Mon') else '' end,
    'instructor_first', coalesce(nullif(o.instr, ''), 'your instructor'),
    'instructor_first_name', coalesce(nullif(o.instr, ''), 'your instructor'),
    'days_since', '10',
    'product', 'Grip socks', 'quantity', '1')
  || jsonb_build_object(
    'instructor_name', p_first_name,
    'href', instructor_portal_url(p_studio_id, '/instructor/schedule'),
    'schedule_link', instructor_portal_url(p_studio_id, '/instructor/schedule'),
    'booked_line', '3 booked',
    'count', '3',
    'plural', 's',
    'month', to_char(now() at time zone v_tz, 'FMMonth'),
    'period', 'this period',
    'due_on', to_char((now() + interval '3 days') at time zone v_tz, 'FMDay FMDD Mon'),
    'due_wording', 'soon',
    'hours', '12',
    'amount', fmt_money(90000, s.currency),
    'old_when', case when o.starts_at is not null
                     then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMonth YYYY, ') || fmt_clock(o.starts_at, v_tz, v_fmt)
                     else 'Monday 9 November, 07:00' end,
    'cancelled_count', '1',
    'booked', '4',
    'capacity', '8',
    'reason', 'cancelled by the studio',
    'claim_url', member_portal_url(p_studio_id, '/class/' || coalesce(o.id::text, '')))
  || jsonb_build_object(
    'next_three', v_n3,
    'next_three_line', v_n3line,
    'next_three_html', v_n3html,
    'class_list', v_clist,
    'roster', v_roster,
    'roster_html', v_roster_html)
  || jsonb_build_object(
    'staff_first_name', p_first_name,
    'member_name', coalesce(nullif(p_first_name, ''), 'A member'),
    'message', 'Hi, could I move my Saturday class to Sunday?',
    'message_html', 'Hi, could I move my Saturday class to Sunday?',
    'messages_url', member_portal_url(p_studio_id, '/messages'),
    'reply_url', coalesce(nullif(notification_setting('staff_app_origin'), ''), 'https://app.studiior.com') || '/messages')
  || jsonb_build_object(
    'old_class_name', coalesce(o.cname, 'a class'),
    'bookings_url', member_portal_url(p_studio_id, '/'))
  || jsonb_build_object(
    'class_name', coalesce(o.cname, 'a class'),
    'day', to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMonth'),
    'n_more', 2,
    'cutoff_time', coalesce(v_when, 'the cut-off'),
    'class_list_core', '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:12px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-size:16px;font-weight:600;color:#14170E">' || coalesce(o.cname, 'a class') || '</div><div style="font-size:14px;color:#57534E;margin-top:4px">' || coalesce(v_when, 'soon') || '</div><div style="font-size:13px;color:#78716C;margin-top:2px">3 in already · 4 spots left</div><table role="presentation" style="margin-top:12px"><tr><td style="border-radius:6px;background:{accent}"><a href="#" style="display:inline-block;padding:10px 20px;color:{accent_on};text-decoration:none;font-weight:600;border-radius:6px">Move me to this class</a></td></tr></table></td></tr></table>',
    'class_list_core_text', '- ' || coalesce(o.cname, 'a class') || ' · ' || coalesce(v_when, 'soon') || ' (3 in already, 4 spots left)')
  || jsonb_build_object(
    'n_running', 2, 'n_cancelled', 1,
    'pay_line', 'You''re paid on who''s checked in.',
    'going_ahead', '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:12px 0;border-collapse:collapse"><tr><td colspan="3" style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;color:#14170E;padding:0 0 6px 0">Running</td></tr><tr><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Time</th><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Class</th><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Booked</th></tr><tr><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">' || fmt_clock(((now() at time zone v_tz)::date + time '07:00') at time zone v_tz, v_tz, v_fmt) || '</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">Reformer Flow</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">4 of 6</td></tr><tr><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">' || fmt_clock(((now() at time zone v_tz)::date + time '18:00') at time zone v_tz, v_tz, v_fmt) || '</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">Barre</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">5 of 8</td></tr></table>',
    'going_ahead_text', 'Running' || E'\n  ' || fmt_clock(((now() at time zone v_tz)::date + time '07:00') at time zone v_tz, v_tz, v_fmt) || '  Reformer Flow  4 of 6' || E'\n  ' || fmt_clock(((now() at time zone v_tz)::date + time '18:00') at time zone v_tz, v_tz, v_fmt) || '  Barre  5 of 8',
    'cancelled', '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:12px 0;border-collapse:collapse"><tr><td colspan="3" style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;color:#14170E;padding:0 0 6px 0">Cancelled, not enough bookings</td></tr><tr><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Time</th><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Class</th><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Booked</th></tr><tr><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">' || fmt_clock(((now() at time zone v_tz)::date + time '09:00') at time zone v_tz, v_tz, v_fmt) || '</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">Mat Pilates</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">1 of 3 needed</td></tr></table>',
    'cancelled_text', 'Cancelled, not enough bookings' || E'\n  ' || fmt_clock(((now() at time zone v_tz)::date + time '09:00') at time zone v_tz, v_tz, v_fmt) || '  Mat Pilates  1 of 3 needed')
  -- Decision 103: reservation tokens.
  || jsonb_build_object(
    'fee', v_fee,
    'from_date', to_char(now() at time zone v_tz, 'FMDD Mon'),
    'deadline', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD Mon') else 'the day before' end,
    'plans_url', member_portal_url(p_studio_id, '/account/plan'),
    'pay_url', member_portal_url(p_studio_id, '/class/' || coalesce(o.id::text, '')),
    'cancel_url', member_portal_url(p_studio_id, '/class/' || coalesce(o.id::text, '')),
    'reservation_line', '',
    'reservation_html', '')
  -- Decision 103a: closure sample tokens so the Templates preview fills them.
  || jsonb_build_object(
    'from', to_char(now() at time zone v_tz, 'FMDy FMDD FMMon'),
    'to', to_char((now() + interval '2 days') at time zone v_tz, 'FMDy FMDD FMMon'),
    'resume_date', to_char((now() + interval '7 days') at time zone v_tz, 'FMDay FMDD FMMonth YYYY'),
    'notice', 'We are closed for renovations.',
    'class_list_html', closure_card_html('Reformer Flow', v_clist),
    'schedule_url', instructor_portal_url(p_studio_id, '/instructor/schedule'))
  -- Housekeeping: refund + credited-back tokens so those previews render clean.
  || jsonb_build_object(
    'method', 'GCash', 'reference', 'rfd-sample-0001',
    'plan_link', member_portal_url(p_studio_id, '/account/plan'), 'button', '')
  -- Step 11: the roster table rows and a two-paragraph sample message.
  || jsonb_build_object(
    'roster_rows', jsonb_build_array(
      jsonb_build_object('day', 'Mon 7 Dec', 'time', fmt_clock(timestamptz '2026-12-07 07:00+00', 'UTC', v_fmt), 'class', 'Reformer Flow'),
      jsonb_build_object('day', 'Wed 9 Dec', 'time', fmt_clock(timestamptz '2026-12-09 18:00+00', 'UTC', v_fmt), 'class', 'Reformer Sculpt')),
    'message', E'Hi! Just a reminder about tomorrow.\n\nBring grip socks and water.\nSee you there!',
    'message_html', 'Hi! Just a reminder about tomorrow.<br><br>Bring grip socks and water.<br>See you there!')
  -- Decision 111 (b): what came back, for the class_cancelled preview.
  || jsonb_build_object('returned_line', 'Your class credit is back on your account.');
end $function$;

create or replace function dashboard_health(p_studio_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_bands jsonb; v_total int; v_banded int; v_computed timestamptz;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'member health is for owners and managers' using errcode = 'PT403';
  end if;

  select count(*), count(*) filter (where health_band is not null), max(health_computed_at)
    into v_total, v_banded, v_computed
    from members where studio_id = p_studio_id and status <> 'archived'
     and not coalesce(is_test_account, false);  -- Decision 97 (c)

  select jsonb_agg(jsonb_build_object(
           'band', b.band, 'count', coalesce(c.n, 0),
           'href', '/members?band=' || b.band) order by b.ord)
    into v_bands
    from (values ('healthy',1),('new',2),('drifting',3),('at_risk',4),
                 ('insufficient_history',5)) b(band, ord)
    left join (
      select health_band, count(*)::int n from members
       where studio_id = p_studio_id and status <> 'archived' and health_band is not null
         and not coalesce(is_test_account, false)  -- Decision 97 (c)
       group by 1) c on c.health_band = b.band;

  return jsonb_build_object(
    'state', case when v_total = 0 then 'empty'
                  when v_banded = 0 then 'not_computed' else 'ok' end,
    'bands', v_bands, 'total', v_total, 'banded', v_banded,
    'not_computed', v_total - v_banded,
    'computed_at', v_computed,
    'empty_hint', 'Every member gets a band and a reason in plain words — who is settled, who is slipping, and why. Add or import members and it starts working overnight.',
    'not_computed_hint', 'Nobody has a band yet. Bands are worked out overnight from each member''s own attendance rhythm, so this fills in after the first pass.');
end $$;

CREATE OR REPLACE FUNCTION public.retention_board(p_studio_id uuid)
 RETURNS TABLE(section text, member_id uuid, member_name text, phone text, class_at timestamp with time zone, days_since integer, instructor_name text, offer_ends timestamp with time zone, window_active boolean, plan_name text, expires_on date, task_id uuid, task_status text, suggested_message text, reason text, contacted_at timestamp with time zone, last_contact_at timestamp with time zone, last_contact_method text, outcome text, outcome_days integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_tz text; v_today date;
begin
  if not (coalesce(is_manager_up(p_studio_id), false)
          or (coalesce(is_desk_up(p_studio_id), false)
              and coalesce((select retention_tasks_to from studio_settings
                             where studio_id = p_studio_id), 'owner_manager') = 'front_desk')
          or is_service_context()) then
    raise exception 'that is another studio''s retention board' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  v_today := (now() at time zone v_tz)::date;

  return query
  -- Unconverted free classes (78a).
  with free_members as (
    select distinct on (b.member_id)
           b.member_id, b.occurrence_id, o.starts_at, o.instructor_id
      from bookings b join class_occurrences o on o.id = b.occurrence_id
     where b.studio_id = p_studio_id and b.payment_source = 'comp'
       and not exists (select 1 from guest_passes gp
                        where gp.guest_booking_id = b.id and gp.host_member_id is not null)
     order by b.member_id, b.booked_at
  ),
  board (section, member_id, member_name, phone, class_at, days_since,
         instructor_name, offer_ends, window_active, plan_name, expires_on,
         task_id, task_status, suggested_message, reason, contacted_at) as (
  select 'unconverted'::text, m.id,
         coalesce(nullif(m.first_name, ''), m.email), m.phone,
         fm.starts_at, greatest(0, (v_today - fm.starts_at::date))::int,
         split_part(coalesce(i.display_name, ''), ' ', 1),
         (intro_window(m.id) ->> 'ends_at')::timestamptz,
         coalesce((intro_window(m.id) ->> 'active')::boolean, false),
         null::text, null::date,
         t.id, t.status, t.suggested_message,
         null::text, t.contacted_at
    from free_members fm
    join members m on m.id = fm.member_id and m.deleted_at is null
    left join instructors i on i.id = fm.instructor_id
    left join lateral (
      select mt.id, mt.status, mt.suggested_message, mt.contacted_at
        from member_tasks mt
       where mt.member_id = m.id and mt.kind = 'unconverted_day7' and mt.status <> 'dismissed'
       order by mt.created_at desc limit 1) t on true
   where not exists (select 1 from memberships ms where ms.member_id = m.id)

  union all
  -- Drifting (health band) — read-only; shows the last soft email sent.
  select 'drifting'::text, m.id,
         coalesce(nullif(m.first_name, ''), m.email), m.phone,
         null::timestamptz, 0, mi.name, null::timestamptz, null::boolean,
         null::text, null::date,
         null::uuid, null::text, null::text,
         m.health_reason,
         (select max(nx.created_at) from notifications nx
           where nx.member_id = m.id and nx.template_key = 'keep_drifting')
    from members m
    left join lateral (
      select split_part(i.display_name, ' ', 1) as name
        from check_ins ci
        join class_occurrences o3 on o3.id = ci.occurrence_id
        join instructors i on i.id = o3.instructor_id
       where ci.member_id = m.id
       group by i.display_name order by count(*) desc, i.display_name limit 1) mi on true
   where m.studio_id = p_studio_id and m.deleted_at is null and m.health_band = 'drifting'

  union all
  -- At risk (health band) — carries the open at_risk task, if any.
  select 'at_risk'::text, m.id,
         coalesce(nullif(m.first_name, ''), m.email), m.phone,
         null::timestamptz, 0, mi.name, null::timestamptz, null::boolean,
         null::text, null::date,
         t.id, t.status, t.suggested_message,
         m.health_reason, t.contacted_at
    from members m
    left join lateral (
      select split_part(i.display_name, ' ', 1) as name
        from check_ins ci
        join class_occurrences o3 on o3.id = ci.occurrence_id
        join instructors i on i.id = o3.instructor_id
       where ci.member_id = m.id
       group by i.display_name order by count(*) desc, i.display_name limit 1) mi on true
    left join lateral (
      select mt.id, mt.status, mt.suggested_message, mt.contacted_at
        from member_tasks mt
       where mt.member_id = m.id and mt.kind = 'at_risk' and mt.status <> 'dismissed'
       order by mt.created_at desc limit 1) t on true
   where m.studio_id = p_studio_id and m.deleted_at is null and m.health_band = 'at_risk'

  union all
  -- Expiring this week.
  select 'expiring'::text, m.id, coalesce(nullif(m.first_name, ''), m.email), m.phone,
         null::timestamptz, 0, null::text, null::timestamptz, null::boolean,
         pl.name, mend.d, null::uuid, null::text, null::text, null::text, null::timestamptz
    from memberships ms
    join membership_plans pl on pl.id = ms.plan_id
    join members m on m.id = ms.member_id and m.deleted_at is null
    cross join lateral (select coalesce(ms.expires_on, (ms.current_period_end at time zone v_tz)::date) as d) mend
   where ms.studio_id = p_studio_id
     and ms.status in ('active', 'past_due')
     and not (coalesce(ms.auto_renew, false) or ms.stripe_subscription_id is not null)
     and mend.d between v_today and v_today + 7
     and not exists (select 1 from memberships ms2
                      where ms2.member_id = ms.member_id and ms2.id <> ms.id and ms2.status = 'active'
                        and coalesce(ms2.expires_on, (ms2.current_period_end at time zone v_tz)::date, 'infinity'::date) > mend.d)

  union all
  -- Lapsed this month.
  select 'lapsed'::text, m.id, coalesce(nullif(m.first_name, ''), m.email), m.phone,
         null::timestamptz, greatest(0, v_today - mend.d)::int, null::text, null::timestamptz, null::boolean,
         pl.name, mend.d, null::uuid, null::text, null::text, null::text, null::timestamptz
    from memberships ms
    join membership_plans pl on pl.id = ms.plan_id
    join members m on m.id = ms.member_id and m.deleted_at is null
    cross join lateral (select coalesce(ms.expires_on, (ms.current_period_end at time zone v_tz)::date) as d) mend
   where ms.studio_id = p_studio_id
     and mend.d between v_today - 30 and v_today - 1
     and not exists (select 1 from memberships ms2
                      where ms2.member_id = ms.member_id and ms2.status = 'active'
                        and coalesce(ms2.expires_on, 'infinity'::date) > v_today)
     and not exists (select 1 from memberships ms3
                      where ms3.member_id = ms.member_id
                        and coalesce(ms3.starts_on, '-infinity'::date) > mend.d)
  )
  select b.section, b.member_id, b.member_name, b.phone, b.class_at, b.days_since,
         b.instructor_name, b.offer_ends, b.window_active, b.plan_name, b.expires_on,
         b.task_id, b.task_status, b.suggested_message, b.reason, b.contacted_at,
         lc.contacted_at, lc.method, lc.outcome, lc.outcome_days
    from board b
    left join lateral (select mc.contacted_at, mc.method, mc.outcome, mc.outcome_days
                         from member_contacts mc
                        where mc.member_id = b.member_id
                        order by mc.contacted_at desc limit 1) lc on true
   -- A snoozed member (an open task due in the future) drops off until due.
   where not exists (select 1 from member_tasks mt
                      where mt.member_id = b.member_id and mt.status = 'open'
                        and mt.due_at is not null and mt.due_at > now())
     -- Decision 97 (c): test accounts are not on the board.
     and not exists (select 1 from members tm where tm.id = b.member_id
                      and coalesce(tm.is_test_account, false))
   order by b.section, b.days_since desc, b.member_name;
end $function$;

CREATE OR REPLACE FUNCTION public.growth_insights(p_studio_id uuid, p_week date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_tz text; v_flexmin int;
  v_coaches jsonb; v_wanted jsonb; v_nudge jsonb;
  v_n_core int; v_n_flex int; v_n_make_core int; v_n_make_flex int;
  v_n_wanted int; v_n_collecting int; v_n_nudge int; v_n_coaches int;
  v_summary_text text; v_figures jsonb; v_allowed jsonb;
begin
  if not is_service_context() then
    raise exception 'growth insights are produced by the backend, not by a user'
      using errcode = 'PT403';
  end if;
  select s.timezone into v_tz from studios s where s.id = p_studio_id;
  if v_tz is null then raise exception 'no such studio' using errcode = 'PT404'; end if;
  select coalesce(flex_min_bookings, 2) into v_flexmin from studio_settings where studio_id = p_studio_id;
  v_flexmin := coalesce(v_flexmin, 2);

  -- One class-tracker-safe run per transaction (the temp table pattern: drop at
  -- the top rather than relying on ON COMMIT, so a second call in one txn works).
  if to_regclass('pg_temp._gi_slots') is not null then drop table _gi_slots; end if;

  create temp table _gi_slots on commit drop as
  with
  coming as (
    select distinct on (o.series_id)
           o.series_id, o.id as occ_id, o.instructor_id, o.capacity,
           extract(isodow from o.starts_at at time zone v_tz)::int as dow,
           to_char(o.starts_at at time zone v_tz, 'HH24:MI') as slot_time,
           coalesce(o.name, ct.name) as class_name,
           (case when g.tier in ('core','always') then 'core' else 'flex' end) as cur_tier,
           -- Decision 106(a): how many classes this series holds in the week, the
           -- unit the weekly core budget counts in.
           (select count(*)::int from class_occurrences w
             where w.series_id = o.series_id and w.status = 'scheduled'
               and (w.starts_at at time zone v_tz)::date >= p_week
               and (w.starts_at at time zone v_tz)::date <  p_week + 7) as occ_in_week
      from class_occurrences o
      left join class_types ct on ct.id = o.class_type_id
      cross join lateral occurrence_guarantee_run(o.id) g
     where o.studio_id = p_studio_id and o.series_id is not null and o.instructor_id is not null
       and o.status = 'scheduled'
       and (o.starts_at at time zone v_tz)::date >= p_week
       and (o.starts_at at time zone v_tz)::date <  p_week + 7
     order by o.series_id, o.starts_at
  ),
  pastocc as (
    select x.*
      from (
        select o.series_id, o.id as occ_id, o.capacity,
               row_number() over (partition by o.series_id order by o.starts_at desc) as rn,
               (select count(*) from bookings b where b.occurrence_id = o.id and b.status in ('booked','attended','no_show')) as booked,
               (select count(*) from bookings b where b.occurrence_id = o.id and b.status = 'attended') as attended,
               (select count(*) from bookings b where b.occurrence_id = o.id and b.status = 'waitlisted') as waitlist,
               (select count(*) from bookings b where b.occurrence_id = o.id and b.status = 'no_show') as no_show,
               (select count(*) from bookings b where b.occurrence_id = o.id and b.status = 'late_cancelled') as late_cancel
          from class_occurrences o
         where o.studio_id = p_studio_id and o.series_id is not null
           and o.status <> 'cancelled'
           and o.starts_at < now() and o.starts_at >= now() - interval '56 days'
           and o.series_id in (select series_id from coming)
      ) x
     where x.rn <= 8
  ),
  occscore as (
    select series_id, rn, booked, capacity, attended, waitlist, no_show, late_cancel,
           ( 0.6  * least(booked::numeric / nullif(capacity,0), 1)
           + 0.25 * (case when booked > 0 then least(attended::numeric / booked, 1) else 0 end)
           + 0.15 * least(waitlist::numeric / greatest(capacity,1), 0.5)
           - 0.2  * ((no_show + late_cancel)::numeric / greatest(capacity,1)) ) as s,
           (case when rn <= 4 then 2 else 1 end) as wt,
           (booked >= v_flexmin) as met,
           (waitlist > 0 or booked >= capacity) as demand
      from pastocc
  ),
  slotagg as (
    select series_id,
           count(*)::int as n_weeks,
           (sum(wt * s) / nullif(sum(wt),0))::numeric as score,
           ((count(*) filter (where rn <= 4 and met) >= 3) and count(*) >= 4) as qualifies,
           bool_or(demand) as wanted,
           round(avg(booked))::int as avg_booked,
           max(capacity)::int as capacity,
           sum(booked)::int as sum_booked,
           sum(attended)::int as sum_attended,
           sum(waitlist)::int as sum_waitlist,
           sum(no_show)::int as sum_no_show,
           sum(late_cancel)::int as sum_late_cancel,
           -- The plain-language streaks behind the Schedule suggestion line.
           (coalesce(min(rn) filter (where not met), count(*) + 1) - 1)::int as met_streak,
           (coalesce(min(rn) filter (where booked > 0), count(*) + 1) - 1)::int as empty_streak,
           (count(*) filter (where rn <= 4 and met))::int as met4,
           (max(booked) filter (where rn = 1))::int as last_booked
      from occscore group by series_id
  ),
  joined as (
    select c.series_id, c.occ_id, c.instructor_id, c.dow, c.slot_time, c.class_name, c.cur_tier, c.occ_in_week,
           coalesce(a.met_streak, 0) as met_streak, coalesce(a.empty_streak, 0) as empty_streak,
           coalesce(a.met4, 0) as met4, coalesce(a.last_booked, 0) as last_booked,
           exists (select 1 from growth_dismissals gd
                    where gd.series_id = c.series_id and gd.dow = c.dow
                      and gd.expires_on > (now() at time zone v_tz)::date) as dismissed,
           coalesce(a.n_weeks, 0) as n_weeks, a.score,
           coalesce(a.qualifies, false) as qualifies,
           coalesce(a.wanted, false) as wanted,
           coalesce(a.avg_booked, 0) as avg_booked,
           coalesce(a.capacity, c.capacity) as capacity,
           coalesce(a.sum_booked, 0) as sum_booked,
           coalesce(a.sum_attended, 0) as sum_attended,
           coalesce(a.sum_waitlist, 0) as sum_waitlist,
           coalesce(a.sum_no_show, 0) as sum_no_show,
           coalesce(a.sum_late_cancel, 0) as sum_late_cancel,
           coalesce(i.core_classes_per_week, 1) as budget
      from coming c
      left join slotagg a on a.series_id = c.series_id
      join instructors i on i.id = c.instructor_id
  ),
  proposed as (
    -- Decision 106(a): the budget INFORMS, it does not block. Every qualifying
    -- slot is proposed core; a slot that would take the coach past their weekly
    -- budget is flagged over_budget with the count it would reach.
    select j.*,
           (case when j.n_weeks < 4 then null
                 when j.qualifies then 'core' else 'flex' end) as proposed_tier,
           sum(case when j.cur_tier = 'core' then j.occ_in_week else 0 end)
             over (partition by j.instructor_id) as core_now
      from joined j
  ),
  ranked as (
    select p.*,
           (p.proposed_tier = 'core' and p.cur_tier <> 'core' and not p.dismissed) as adds_core,
           p.core_now + sum(case when p.proposed_tier = 'core' and p.cur_tier <> 'core' and not p.dismissed
                                 then p.occ_in_week else 0 end)
             over (partition by p.instructor_id
                   order by p.score desc nulls last, p.dow, p.slot_time, p.series_id
                   rows between unbounded preceding and current row) as would_hold
      from proposed p
  )
  select r.series_id, r.occ_id, r.instructor_id, r.dow, r.slot_time, r.class_name, r.cur_tier,
         r.n_weeks, r.score, r.qualifies, r.wanted, r.avg_booked, r.capacity,
         r.sum_booked, r.sum_attended, r.sum_waitlist, r.sum_no_show, r.sum_late_cancel,
         r.budget, r.occ_in_week, r.core_now, r.met_streak, r.empty_streak, r.met4, r.last_booked,
         r.dismissed, r.proposed_tier,
         (case when r.adds_core then r.would_hold::int end) as would_hold,
         (r.adds_core and r.would_hold > r.budget) as over_budget,
         (case
            when r.proposed_tier = 'core' and r.cur_tier <> 'core' then
              case when r.met_streak >= 2
                   then 'Reached ' || least(r.last_booked, v_flexmin) || ' of ' || v_flexmin || ' '
                        || growth_number_word(r.met_streak) || ' weeks running. Make it core?'
                   else 'Reached the minimum in ' || growth_number_word(r.met4)
                        || ' of the last four weeks. Make it core?' end
            when r.proposed_tier = 'flex' and r.cur_tier = 'core' then
              case when r.empty_streak >= 2
                   then 'Empty ' || growth_number_word(r.empty_streak) || ' weeks running. Make it flex?'
                   else 'Reached the minimum in ' || growth_number_word(r.met4)
                        || ' of the last four weeks. Make it flex?' end
          end) as line
    from ranked r;

  -- coaches -> days -> slots
  select jsonb_agg(coach order by coach ->> 'name') into v_coaches
  from (
    select jsonb_build_object(
             'instructor_id', s.instructor_id,
             'name', split_part(i.display_name, ' ', 1),
             'budget', max(s.budget),
             'core_now', max(s.core_now),
             'raise_to', case when max(s.would_hold) filter (where s.over_budget) is not null
                              then least(max(s.would_hold) filter (where s.over_budget), 21) else null end,
             'days', (
               select jsonb_agg(day_obj order by (day_obj->>'dow')::int)
               from (
                 select jsonb_build_object(
                          'dow', d.dow,
                          'day_name', (array['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'])[d.dow],
                          'slots', jsonb_agg(
                            jsonb_build_object(
                              'series_id', d.series_id, 'occurrence_id', d.occ_id,
                              'class_name', d.class_name, 'time', d.slot_time,
                              'weeks', d.n_weeks,
                              'collecting', (d.n_weeks < 4),
                              'collecting_label', case when d.n_weeks < 4 then 'Collecting data, ' || d.n_weeks || ' of 4 weeks' else null end,
                              'score', round(coalesce(d.score, 0), 3),
                              'avg_booked', d.avg_booked, 'capacity', d.capacity,
                              'attended_rate', case when d.sum_booked > 0 then round(d.sum_attended::numeric / d.sum_booked, 2) else null end,
                              'waitlist', d.sum_waitlist, 'no_shows', d.sum_no_show, 'late_cancels', d.sum_late_cancel,
                              'qualifies', d.qualifies, 'wanted', d.wanted,
                              'current_tier', d.cur_tier, 'proposed_tier', d.proposed_tier,
                              'dow', d.dow, 'occ_in_week', d.occ_in_week,
                              'would_hold', d.would_hold, 'over_budget', coalesce(d.over_budget, false),
                              'dismissed', d.dismissed, 'line', d.line,
                              'action', case when d.proposed_tier is null then null
                                             when d.proposed_tier = d.cur_tier then null
                                             when d.dismissed then null
                                             else 'make_' || d.proposed_tier end
                            ) order by d.score desc nulls last, d.slot_time)
                        ) as day_obj
                 from _gi_slots d
                 where d.instructor_id = s.instructor_id
                 group by d.dow
               ) days
             )
           ) as coach
    from _gi_slots s
    join instructors i on i.id = s.instructor_id
    group by s.instructor_id, i.display_name
  ) coaches;

  -- Wanted slots: ran full or took a waitlist. "Add a class here".
  select jsonb_agg(w order by (w->>'day_name'), (w->>'time')) into v_wanted
  from (
    select distinct on (s.series_id)
           jsonb_build_object(
             'series_id', s.series_id, 'occurrence_id', s.occ_id,
             'class_name', s.class_name,
             'instructor_name', split_part(i.display_name, ' ', 1),
             'time', s.slot_time,
             'day_name', (array['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'])[s.dow],
             'reason', case when s.sum_waitlist > 0 then 'had a waitlist' else 'ran full' end
           ) as w
      from _gi_slots s join instructors i on i.id = s.instructor_id
     where s.wanted
     order by s.series_id
  ) wanted;

  -- Members to nudge: booked often (>= 4 attended) but not in the last 21 days.
  select jsonb_agg(n order by (n->>'last_visit') nulls first) into v_nudge
  from (
    select jsonb_build_object(
             'member_id', m.id,
             'name', btrim(m.first_name || ' ' || coalesce(m.last_name, '')),
             'phone', m.phone, 'email', m.email,
             'last_visit', (select max((ci.checked_in_at at time zone v_tz)::date)
                              from check_ins ci where ci.member_id = m.id)
           ) as n
      from members m
     where m.studio_id = p_studio_id and m.status = 'active' and m.deleted_at is null
       and not coalesce(m.is_test_account, false)  -- Decision 97 (c)
       and (select count(*) from bookings b where b.member_id = m.id and b.status = 'attended') >= 4
       and not exists (
         select 1 from bookings b join class_occurrences o on o.id = b.occurrence_id
          where b.member_id = m.id and o.starts_at >= now() - interval '21 days'
            and b.status in ('booked','attended'))
     limit 10
  ) nudge;

  v_coaches := coalesce(v_coaches, '[]'::jsonb);
  v_wanted  := coalesce(v_wanted, '[]'::jsonb);
  v_nudge   := coalesce(v_nudge, '[]'::jsonb);

  -- Deterministic summary numbers (the only figures the optional Claude summary
  -- may name, Decision 92).
  select count(*) filter (where proposed_tier = 'core'),
         count(*) filter (where proposed_tier = 'flex'),
         count(*) filter (where proposed_tier = 'core' and proposed_tier is distinct from cur_tier and not dismissed),
         count(*) filter (where proposed_tier = 'flex' and proposed_tier is distinct from cur_tier and not dismissed),
         count(*) filter (where wanted),
         count(*) filter (where n_weeks < 4),
         count(distinct instructor_id)
    into v_n_core, v_n_flex, v_n_make_core, v_n_make_flex, v_n_wanted, v_n_collecting, v_n_coaches
    from _gi_slots;
  v_n_nudge := jsonb_array_length(v_nudge);

  v_summary_text :=
    'This week ' || v_n_core || ' class slots earn core and ' || v_n_flex
    || ' stay flex across ' || v_n_coaches || ' instructors.'
    || case when v_n_make_core + v_n_make_flex > 0
            then ' ' || (v_n_make_core + v_n_make_flex) || ' are a change from today.' else '' end
    || case when v_n_wanted > 0 then ' ' || v_n_wanted || ' slots are in demand.' else '' end
    || case when v_n_collecting > 0 then ' ' || v_n_collecting || ' are still collecting data.' else '' end;

  v_figures := jsonb_build_object(
    'proposed_core', jsonb_build_object('what','class slots recommended for core this week','text', v_n_core::text, 'n', v_n_core),
    'proposed_flex', jsonb_build_object('what','class slots staying flex','text', v_n_flex::text, 'n', v_n_flex),
    'changes',       jsonb_build_object('what','slots that would change from today','text',(v_n_make_core+v_n_make_flex)::text,'n',v_n_make_core+v_n_make_flex),
    'wanted',        jsonb_build_object('what','slots members want more of','text', v_n_wanted::text, 'n', v_n_wanted),
    'collecting',    jsonb_build_object('what','slots still collecting data','text', v_n_collecting::text, 'n', v_n_collecting),
    'coaches',       jsonb_build_object('what','instructors looked at','text', v_n_coaches::text, 'n', v_n_coaches),
    'nudge',         jsonb_build_object('what','members to nudge','text', v_n_nudge::text, 'n', v_n_nudge));

  v_allowed := to_jsonb(array[v_n_core::text, v_n_flex::text, (v_n_make_core+v_n_make_flex)::text,
                              v_n_wanted::text, v_n_collecting::text, v_n_coaches::text, v_n_nudge::text]);

  return jsonb_build_object(
    'week', p_week, 'flex_min', v_flexmin,
    'coaches', v_coaches, 'wanted', v_wanted, 'nudge', v_nudge,
    'summary', jsonb_build_object('text', v_summary_text, 'figures', v_figures, 'allowed', v_allowed));
end $function$;

-- ---- The public surface is unchanged: exactly fifteen anon functions --------
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'expect\_%' and p.proname not in ('call_jsonb');
  if n <> 15 then raise exception 'anon surface is %, expected 15', n; end if;
end $$;
