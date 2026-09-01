-- =============================================================================
-- Migration 045: what a locked studio cannot do
-- =============================================================================
-- Middleware redirects both apps to the billing screen, but a permission that
-- exists only in the app is not a permission — a staff token could still call
-- book_class() directly. These four are the SECURITY DEFINER entry points where
-- something actually happens, and they are gated in the database.
--
-- WHAT IS DELIBERATELY NOT GATED:
--
--   * cancel_booking(). A studio that cannot cancel a class leaves members
--     standing at a locked door on a Tuesday morning, and those members did
--     nothing wrong. Cancelling is the one action that gets MORE important when
--     a studio is in trouble, not less.
--   * Every read. Rosters, member records, history, the schedule — all of it
--     stays visible, so a lockout never looks like data loss and paying puts
--     everything back exactly where it was.
--   * respond_to_offer() and the notification worker, for the same reason as
--     cancellation: they are how members find out what is happening.
--
-- All four replaced from their LIVE definitions.
-- =============================================================================

create or replace function public.book_class(p_occurrence_id uuid, p_member_id uuid, p_source booking_source, p_override_reason text DEFAULT NULL::text, p_payment_source payment_source DEFAULT NULL::payment_source)
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
  v_pay          payment_source;
  v_membership   uuid;
  v_consume      boolean := false;

  v_booking_id   uuid;
  v_ledger_id    uuid;
  v_balance      int;
  v_position     int;
  v_full         boolean;
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

  v_is_desk := coalesce(is_desk_up(v_occ.studio_id), false);
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
  if v_occ.starts_at <= now() then
    return (null, null, null, null, 'class_in_past')::book_class_result;
  end if;

  -- Plan-level overrides for rules 2 and 7 come from the member's highest
  -- priority usable plan (§2.1.2 "plan-level override wins over studio
  -- default"). Read before the gate; the paying source is resolved in §3.
  select mp.booking_window_days, mp.max_bookings_per_day
    into v_window_days, v_max_per_day
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

  v_window_days := coalesce(v_window_days, v_set.booking_window_days);
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
  if not v_override then
    if v_occ.starts_at < now() + make_interval(mins => v_set.booking_cutoff_minutes) then
      return (null, null, null, null, 'past_booking_cutoff')::book_class_result;
    end if;
  elsif v_occ.starts_at < now() + make_interval(mins => v_set.booking_cutoff_minutes) then
    v_bypassed := v_bypassed || 'booking_cutoff'::text;
  end if;

  -- 2.1.4 Waiver. Not overridable.
  if v_set.require_waiver and v_member.waiver_signed_at is null then
    return (null, null, null, null, 'waiver_not_signed')::book_class_result;
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
               when mp.type in ('recurring','trial')
                    and mp.credits_per_period is null
                    and ms.credits_remaining is null              then 1
               when mp.type in ('recurring','trial')
                    and coalesce(ms.credits_remaining, 0) > 0     then 2
               when mp.type = 'class_pack'
                    and coalesce(ms.credits_remaining, 0) > 0     then 3
               else 99
             end as priority
        from memberships ms
        join membership_plans mp on mp.id = ms.plan_id
       where ms.member_id = p_member_id
         and ms.studio_id = v_occ.studio_id
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
      v_pay := 'drop_in';
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

  -- Decision 15's second half, after §2.2 has resolved who pays. A lead has
  -- bought nothing, so it should always be drop-in by this point; if it is
  -- not, staff have attached a plan to somebody they never activated, and
  -- spending its credits is not what `lead` is meant to allow.
  if v_member.status = 'lead' and v_pay <> 'drop_in' then
    return (null, null, null, null, 'member_not_active')::book_class_result;
  end if;

  -- ===========================================================================
  -- 4. Capacity — §2.1.10, §4.1, §5. booked_count was read under the lock.
  -- ===========================================================================

  v_full := v_occ.booked_count >= v_occ.capacity;

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
    -- §2.3 / §5: a staff override for a walk-in books over capacity. This is
    -- displayed as over-capacity, not corrected.
    v_bypassed := v_bypassed || 'capacity'::text;
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

  -- The caller needs to know it is holding rather than booked, because that is
  -- what decides whether the member is sent to Checkout next.
  return (v_booking_id, v_status, v_pay, null, null)
         ::book_class_result;
end $function$

;

create or replace function public.resolve_checkin_code(p_code text)
 RETURNS TABLE(member_id uuid, first_name text, last_name text, email text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_bucket bigint; v_code text := upper(btrim(p_code));
begin
  v_bucket := floor(extract(epoch from now()) / 30)::bigint;
  return query
    select m.id, m.first_name, m.last_name, m.email
      from members m
     where is_desk_up(m.studio_id)
       -- A locked studio cannot check anybody in. Expressed as a predicate
       -- rather than a raise because this function takes a code, not a studio:
       -- it does not know which tenant it is about until it has matched one.
       and not studio_is_locked(m.studio_id)
       and (checkin_code_for(m.id, v_bucket)     = v_code
         or checkin_code_for(m.id, v_bucket - 1) = v_code)
     limit 1;
end $function$

;

create or replace function public.import_commit(p_import_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  imp     imports%rowtype;
  r       record;
  created int := 0;
  mid     uuid;
  touched uuid[] := '{}';
begin
  select * into imp from imports where id = p_import_id for update;
  if not found then
    raise exception 'no such import' using errcode = 'PT404';
  end if;
  if not is_manager_up(imp.studio_id) then
    raise exception 'only owners and managers may import' using errcode = 'PT403';
  end if;
  -- Lockout (migration 044). The studio's own subscription to Studiior has
  -- lapsed past its grace period. Reads stay open everywhere so nothing looks
  -- lost; this is one of the four places where DOING something stops.
  if studio_is_locked(imp.studio_id) then
    raise exception 'this studio''s Studiior subscription is not active'
      using errcode = 'PT402',
            hint = 'Reactivate it from Billing. Nothing has been deleted.';
  end if;

  if imp.status <> 'dry_run_complete' then
    raise exception 'run the dry run first — this import is %', imp.status
      using errcode = 'PT409',
            hint = 'Nothing is committed until the owner has seen what will happen.';
  end if;

  for r in select * from import_rows
            where import_id = p_import_id and status = 'ok' order by row_number
  loop
    if imp.type = 'members' then
      insert into members (studio_id, first_name, last_name, email, phone,
                           joined_on, status, waiver_signed_at)
      values (imp.studio_id,
              coalesce(nullif(r.normalized ->> 'first_name', ''), '—'),
              coalesce(nullif(r.normalized ->> 'last_name', ''), '—'),
              lower(r.normalized ->> 'email'),
              nullif(r.normalized ->> 'phone', ''),
              coalesce((r.normalized ->> 'joined_on')::date, current_date),
              coalesce(import_member_status(r.normalized ->> 'status'), 'active'),
              (r.normalized ->> 'waiver_signed_at')::timestamptz)
      returning id into mid;

      update import_rows set entity_table = 'members', entity_id = mid,
                             status = 'committed'
       where id = r.id;

    elsif imp.type = 'memberships' then
      insert into memberships (studio_id, member_id, plan_id, status, price_cents,
                               currency, starts_on, expires_on, credits_remaining)
      select imp.studio_id, m.id, p.id,
             coalesce(import_membership_status(r.normalized ->> 'status'), 'active'),
             -- §7.1: the price is snapshotted at purchase. An import carries
             -- what they actually paid when it is in the file, and falls back
             -- to today's plan price only when it is not.
             coalesce((r.normalized ->> 'price_cents')::int, p.price_cents),
             p.currency,
             coalesce((r.normalized ->> 'starts_on')::date, current_date),
             (r.normalized ->> 'expires_on')::date,
             coalesce((r.normalized ->> 'credits_remaining')::int,
                      p.credits, p.credits_per_period)
        from members m, membership_plans p
       where m.studio_id = imp.studio_id
         and lower(m.email) = lower(r.normalized ->> 'email')
         and p.studio_id = imp.studio_id
         and lower(p.name) = lower(r.normalized ->> 'plan')
      returning id into mid;

      update import_rows set entity_table = 'memberships', entity_id = mid,
                             status = 'committed'
       where id = r.id;

    else  -- attendance
      -- No occurrence and no booking: the class this visit belonged to is not
      -- in the export and inventing one would put thousands of classes that
      -- never ran into the calendar. import_id carries the provenance and
      -- exempts the row from the §8 check-in window, which is about people
      -- arriving, not about recording that they did.
      insert into check_ins (studio_id, booking_id, member_id, occurrence_id,
                             checked_in_at, method, import_id)
      select imp.studio_id, null, m.id, null,
             (r.normalized ->> 'attended_at')::timestamptz, 'staff', p_import_id
        from members m
       where m.studio_id = imp.studio_id
         and lower(m.email) = lower(r.normalized ->> 'email')
      returning id, member_id into mid, mid;

      select m.id into mid from members m
       where m.studio_id = imp.studio_id
         and lower(m.email) = lower(r.normalized ->> 'email');
      touched := touched || mid;

      update import_rows set entity_table = 'check_ins',
                             entity_id = (select ci.id from check_ins ci
                                           where ci.import_id = p_import_id
                                             and ci.member_id = mid
                                           order by ci.created_at desc limit 1),
                             status = 'committed'
       where id = r.id;
    end if;

    created := created + 1;
  end loop;

  update imports set status = 'complete' where id = p_import_id;

  -- Imported attendance changes what every visit-derived number means.
  if imp.type = 'attendance' and array_length(touched, 1) is not null then
    perform recompute_member_stats(imp.studio_id, touched);
    perform refresh_studio_health(imp.studio_id);
  end if;

  return jsonb_build_object('created', created, 'type', imp.type);
end $function$

;

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
end $function$

;
