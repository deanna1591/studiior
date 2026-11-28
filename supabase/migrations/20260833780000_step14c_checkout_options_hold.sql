-- creates: checkout_hold_class(uuid, uuid), checkout_link_hold(uuid, uuid)
-- re-issues: book_class(uuid, uuid, booking_source, text, payment_source, uuid), cancel_booking(uuid), apply_plan_to_unpaid(uuid, uuid, uuid), xendit_fail_purchase_internal(uuid, text, text), sweep_unpaid_dropins(), member_pending_bookings(uuid)
--
-- Step 14c (28 Nov 2026).
--   88 (d) Checkout offers every option that books this class. Private packs
--          never pay for a group class: checkout_hold_class refuses a private
--          pack before any seat is held ('private_pack_not_for_class'), and
--          apply_plan_to_unpaid never settles a group seat with one.
--   88 (e) No seat without payment. The online checkout seat is a 30-minute
--          payment hold (pending_payment, hold_reason 'checkout'):
--          - book_class holds it as pending_payment under the checkout flag;
--          - checkout_hold_class sets hold_until, re-arms a hold on the same
--            class, releases this member's own ended holds, and refuses a
--            second open hold ('hold_open');
--          - checkout_link_hold ties the Xendit purchase to the held seat
--            (xendit_purchases.hold_booking_id);
--          - success: apply_plan_to_unpaid settles the held seat first and
--            confirms it (status booked, hold cleared);
--          - expiry or failure: xendit_fail_purchase_internal releases it
--            (unless a newer checkout for it is still open), and the 2-minute
--            sweep releases any hold past hold_until and expires its purchase;
--          - cancel_booking honours a narrow 'studiior.hold_release' flag that
--            can only cancel a pending_payment seat, so the release works from
--            the anonymous webhook (it also makes the 103 (e) reservation
--            release work there);
--          - member_pending_bookings reports the hold as 'checkout_hold' with
--            its hold_until.
--          The hold already takes no part in the flex minimum, the chips or the
--          pay heads (unpaid drop-ins are excluded by 81b), and a released
--          pending_payment seat is a plain cancel: no late cancel, no strike.
-- Anon stays EXACTLY FIFTEEN (asserted at the bottom).

alter table xendit_purchases add column if not exists hold_booking_id uuid
  references bookings(id) on delete set null;
create index if not exists xendit_purchases_hold_booking_idx
  on xendit_purchases (hold_booking_id) where hold_booking_id is not null;

-- ---- book_class (from 20260833770000) -------------------------------------
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
     and (exists (
       select 1 from studios s
        where s.id = v_occ.studio_id and s.stripe_account_id is not null
     )
     -- Decision 88 (e): the online checkout seat is a payment hold, never a
     -- confirmed unpaid seat. checkout_hold_class sets this flag.
     or coalesce(current_setting('studiior.checkout_hold', true), '') = '1')
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

-- ---- cancel_booking (from 20260831350000) --------------------------------
CREATE OR REPLACE FUNCTION public.cancel_booking(p_booking_id uuid)
 RETURNS cancel_result
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  b        bookings%rowtype;
  occ      class_occurrences%rowtype;
  st       studio_settings%rowtype;
  v_member members%rowtype;
  v_late   boolean;
  v_entry  credit_ledger%rowtype;
  v_bal    int;
  v_res    cancel_result;
  v_mins   int;
  v_window int;
  v_next   bookings%rowtype;
begin
  select * into b from bookings where id = p_booking_id;
  if not found then
    raise exception 'no such booking' using errcode = 'PT404';
  end if;

  select * into v_member from members where id = b.member_id for update;

  -- The member themselves, desk-up staff acting for them, or the backend.
  --
  -- The backend case is sweep_unpaid_dropins(), which runs from pg_cron with no
  -- JWT. It comes through here rather than cancelling rows itself so that a
  -- swept seat goes down exactly the same path as any other cancellation —
  -- booked_count decremented, and §4.2 offering the seat to the front of the
  -- waitlist. A freed seat nobody is offered is worse than a held one.
  --
  -- is_service_context() asks Postgres whether the effective role is one it
  -- marks superuser or bypassrls, so it is true for cron and can never be true
  -- for a signed-in member however they arrive (migration 024).
  if not (coalesce(v_member.user_id = auth.uid(), false)
          or is_desk_up(b.studio_id)
          or is_service_context()
          -- Decision 88 (e): a payment hold released with its checkout (the
          -- Xendit failure path runs from the anonymous webhook). The flag can
          -- only ever cancel a seat nobody has paid for.
          or (b.status = 'pending_payment'
              and coalesce(current_setting('studiior.hold_release', true), '') = '1')) then
    raise exception 'that is not your booking' using errcode = 'PT403';
  end if;

  if b.status not in ('booked', 'waitlisted', 'pending_payment') then
    raise exception 'this booking is already %', b.status using errcode = 'PT409';
  end if;

  select * into occ from class_occurrences where id = b.occurrence_id for update;
  select * into st  from studio_settings where studio_id = b.studio_id;

  -- Leaving a waitlist is free and unconditional — §4.1.
  if b.status = 'waitlisted' then
    update bookings set status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid()
     where id = p_booking_id;
    update class_occurrences
       set waitlist_count = greatest(0, waitlist_count - 1)
     where id = occ.id;
    v_res := ('cancelled'::booking_status, false, null, false);
    return v_res;
  end if;

  -- A seat that was only ever held is never a LATE cancellation. Without this
  -- a member who opened Checkout inside the cancellation cutoff and closed the
  -- tab would have the sweep record a late_cancelled against them — a black
  -- mark, and on some studios a fee, for a class they never paid for.
  -- free_cancel_until overrides the cutoff. It is set when the studio moved
  -- the class significantly (migration 050) — the member agreed to a time and
  -- the studio changed it, so charging them for cancelling would be charging
  -- them for the studio's decision.
  v_late := b.status <> 'pending_payment'
            and now() > occ.starts_at - make_interval(mins => st.cancellation_cutoff_minutes)
            and not (b.free_cancel_until is not null and now() <= b.free_cancel_until);

  -- Cast explicitly: a CASE over two string literals is text, and assigning
  -- text to a booking_status column fails at runtime rather than at create
  -- time, so the function looked fine until something cancelled anything.
  update bookings
     set status = (case when v_late then 'late_cancelled' else 'cancelled' end)::booking_status,
         cancelled_at = now(), cancelled_by = auth.uid(),
         is_late_cancel = v_late
   where id = p_booking_id;

  update class_occurrences
     set booked_count = greatest(0, booked_count - 1)
   where id = occ.id;

  v_res.status := (case when v_late then 'late_cancelled' else 'cancelled' end)::booking_status;
  v_res.credit_returned := false;
  v_res.offer_made := false;

  -- Credit, if one was taken.
  if b.credit_entry_id is not null then
    select * into v_entry from credit_ledger where id = b.credit_entry_id;

    if v_late and coalesce(st.late_cancel_consumes_credit, true) then
      v_res.reason := 'Cancelled inside the notice period, so the class is used.';
    elsif v_entry.expires_at is not null and v_entry.expires_at < now() then
      -- §3.1: a credit cannot be resurrected past its expiry.
      v_res.reason := 'That class pack has expired, so the credit could not go back on.';
    else
      select coalesce(sum(delta), 0) into v_bal
        from credit_ledger
       where studio_id = b.studio_id and member_id = b.member_id;

      insert into credit_ledger (studio_id, member_id, membership_id, delta, reason,
                                 booking_id, balance_after, expires_at, actor_user_id)
      values (b.studio_id, b.member_id, v_entry.membership_id, 1, 'cancellation_refund',
              p_booking_id, v_bal + 1, v_entry.expires_at, auth.uid());

      if v_entry.membership_id is not null then
        update memberships set credits_remaining = coalesce(credits_remaining, 0) + 1
         where id = v_entry.membership_id;
      end if;
      v_res.credit_returned := true;
    end if;
  end if;

  -- §4.2: a freed seat offers itself to the front of the waitlist. §4.3 clamps
  -- the window, and refuses to make an offer nobody could realistically take.
  if coalesce(st.waitlist_enabled, true) then
    select * into v_next from bookings
     where occurrence_id = occ.id and status = 'waitlisted'
     order by waitlist_position
     limit 1;

    if found then
      v_mins   := floor(extract(epoch from occ.starts_at - now()) / 60)::int;
      v_window := least(coalesce(st.waitlist_offer_window_minutes, 120),
                        v_mins - coalesce(st.waitlist_cutoff_minutes, 60));
      if v_window >= 15 then
        insert into waitlist_offers (studio_id, booking_id, occurrence_id, expires_at)
        values (occ.studio_id, v_next.id, occ.id,
                now() + make_interval(mins => v_window));
        v_res.offer_made := true;
      end if;
    end if;
  end if;

  return v_res;
end $function$;

-- ---- apply_plan_to_unpaid (from 20260832440000) --------------------------
create or replace function apply_plan_to_unpaid(
  p_studio_id uuid, p_member_id uuid, p_membership_id uuid
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_tz           text;
  v_type         text;
  v_remaining    int;
  v_expires      date;
  v_restrictions jsonb;
  v_pay          payment_source;
  v_consume      boolean;
  v_booking      uuid;
  v_occurrence   uuid;
  v_class_type   uuid;
  v_starts       timestamptz;
  v_covers       boolean;
  v_peak         jsonb;
  v_balance      int;
  v_ledger       uuid;
  v_private_pack boolean;
  v_occ_private  boolean;
  v_is_hold      boolean;
begin
  -- The just-activated membership. Lock it: credits_remaining is a cache written
  -- in the same transaction as the ledger row. A replay (or a second call) finds
  -- no usable credit / an already-settled booking and returns — idempotent.
  select s.timezone, mp.type, ms.credits_remaining, ms.expires_on, mp.restrictions,
         coalesce(mp.private_pack, false)
    into v_tz, v_type, v_remaining, v_expires, v_restrictions, v_private_pack
    from memberships ms
    join membership_plans mp on mp.id = ms.plan_id
    join studios s on s.id = ms.studio_id
   where ms.id = p_membership_id
   for update of ms;
  if v_type is null then return null; end if;

  -- The paying source and whether it consumes a credit — EXACTLY book_class
  -- §2.2's priority CASE for a single membership:
  --   priority 1  unlimited recurring  -> membership, no consume
  --   priority 2  limited recurring    -> membership, consume
  --   priority 3  pack/drop_in/trial   -> class_pack, consume
  --   else        no usable credit     -> nothing to apply
  if v_type = 'recurring' and v_remaining is null then
    v_pay := 'membership'; v_consume := false;          -- unlimited
  elsif v_type = 'recurring' and coalesce(v_remaining, 0) > 0 then
    v_pay := 'membership'; v_consume := true;           -- limited, has credits
  elsif v_type in ('class_pack', 'drop_in', 'trial') and coalesce(v_remaining, 0) > 0 then
    v_pay := 'class_pack'; v_consume := true;           -- pack credits
  else
    return null;                                        -- nothing usable
  end if;

  -- The OLDEST unpaid drop-in: a booked (not pending_payment — the Stripe hold
  -- settles through its own checkout, untouched here) drop_in seat with no
  -- succeeded/partially-refunded payment. The same unpaid set the 73a cap counts.
  -- Its occurrence's class type and start are read for the coverage check below.
  select b.id, o.id, o.class_type_id, o.starts_at,
         coalesce(o.is_private, false), b.status = 'pending_payment'
    into v_booking, v_occurrence, v_class_type, v_starts, v_occ_private, v_is_hold
    from bookings b
    join class_occurrences o on o.id = b.occurrence_id
   where b.member_id = p_member_id and b.studio_id = p_studio_id
     and b.payment_source = 'drop_in'
     -- Decision 88 (e): the online checkout's held seat is settled first.
     and (b.status = 'booked'
          or (b.status = 'pending_payment' and b.hold_reason = 'checkout'))
     and not exists (select 1 from payments p
                      where p.booking_id = b.id
                        and p.status in ('succeeded', 'partially_refunded'))
   order by (b.status = 'pending_payment') desc, b.created_at asc
   limit 1
   for update of b;
  if v_booking is null then
    return null;  -- no unpaid drop-in; the credit stays on the membership
  end if;

  -- Decision 88 (d): a private pack only books private sessions; it never
  -- settles a group-class seat.
  if v_private_pack and not v_occ_private then
    return null;
  end if;

  -- COVERAGE — book_class's own tests, applied to this one membership against
  -- the held class. (a) class-type restriction: the identical class_type_ids
  -- jsonb test (empty/absent covers everything).
  v_covers := (v_restrictions -> 'class_type_ids') is null
           or jsonb_typeof(v_restrictions -> 'class_type_ids') <> 'array'
           or jsonb_array_length(v_restrictions -> 'class_type_ids') = 0
           or (v_class_type is not null
               and jsonb_exists(v_restrictions -> 'class_type_ids', v_class_type::text));
  if not v_covers then
    return null;  -- the plan does not cover this class type — booking untouched
  end if;

  -- (b) peak — only a membership-priority plan can carry an allowance
  -- (book_class §3b); peak_allowance_state is null for a plan with no allowance
  -- and for a studio with the switch off. Exhausted -> the plan would not have
  -- booked this class, so it does not settle it either.
  if v_pay = 'membership' and occurrence_is_peak(v_occurrence) then
    v_peak := peak_allowance_state(p_membership_id, (v_starts at time zone v_tz)::date);
    if v_peak is not null and (v_peak ->> 'remaining')::int <= 0 then
      return null;  -- peak allowance exhausted — booking untouched
    end if;
  end if;

  -- Consume one credit through the existing ledger path (book_class §6) when the
  -- source consumes: a reversing ledger row carrying balance_after, the cache
  -- decremented in the same transaction, the booking's credit_entry_id set. An
  -- unlimited membership consumes nothing (credit_entry_id stays null).
  if v_consume then
    select coalesce(sum(delta), 0) into v_balance
      from credit_ledger
     where studio_id = p_studio_id and member_id = p_member_id;

    insert into credit_ledger (
      studio_id, member_id, membership_id, delta, reason,
      booking_id, balance_after, expires_at, actor_user_id
    ) values (
      p_studio_id, p_member_id, p_membership_id, -1, 'booking',
      v_booking, v_balance - 1,
      case when v_expires is not null then (v_expires + 1)::timestamp at time zone v_tz end,
      null
    ) returning id into v_ledger;

    update memberships set credits_remaining = credits_remaining - 1
     where id = p_membership_id;
  end if;

  -- Relink the booking to the membership and flip it off drop_in, so it is paid
  -- and no longer counts toward the 73a unpaid-booking cap.
  update bookings
     set payment_source = v_pay, membership_id = p_membership_id,
         credit_entry_id = v_ledger,
         -- Decision 88 (e): a paid hold is now a confirmed seat.
         status = case when v_is_hold then 'booked'::booking_status else status end,
         hold_until = case when v_is_hold then null else hold_until end,
         hold_reason = case when v_is_hold then null else hold_reason end
   where id = v_booking;

  return v_booking;
end $$;

-- ---- xendit_fail_purchase_internal (from 20260833580000) -----------------
create or replace function xendit_fail_purchase_internal(p_purchase_id uuid, p_status text, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare p xendit_purchases%rowtype; o product_orders%rowtype; prod products%rowtype; n int;
begin
  select * into p from xendit_purchases where id = p_purchase_id for update;
  if p.id is null or p.status in ('succeeded') then return; end if;

  update xendit_purchases
     set status = p_status, failure_reason = p_reason, completed_at = now(), updated_at = now()
   where id = p_purchase_id and status = 'pending';

  if p.booking_id is not null then
    -- Decision 103(e): release the held seat at once rather than waiting for the
    -- sweep. No email (the class page tells the member "Your spot wasn't held.").
    if exists (select 1 from bookings b where b.id = p.booking_id and b.status = 'pending_payment') then
      perform set_config('studiior.hold_release', '1', true);
      perform cancel_booking(p.booking_id);
      perform set_config('studiior.hold_release', '', true);
    end if;
    return;
  elsif p.private_occurrence_id is not null then
    -- Decision 116: an unpaid private is released (room and coach freed). No email.
    perform private_release_run(p.private_occurrence_id);
    return;
  elsif p.gift_card_id is not null then
    -- Decision 110: the gift was never issued (payment failed). Void the pending
    -- card so a later card is minted fresh; nobody is emailed.
    update gift_cards set status = 'void', voided_at = now(), void_reason = coalesce(p_reason, 'payment failed')
     where id = p.gift_card_id and status = 'pending';
    return;
  elsif p.product_order_id is not null then
    select * into o from product_orders where id = p.product_order_id for update;
    update product_orders set status = 'cancelled'
     where id = p.product_order_id and status in ('reserved', 'pending');
    get diagnostics n = row_count;
    if n = 1 then
      select * into prod from products where id = o.product_id for update;
      if prod.track_stock then
        update products set stock = stock + o.quantity where id = prod.id;
        insert into stock_movements (studio_id, product_id, delta, reason, order_id)
        values (p.studio_id, prod.id, o.quantity, 'release', o.id);
      end if;
    end if;
    perform queue_notification(
      p.studio_id, p.member_id, 'xendit_purchase_failed',
      jsonb_build_object('plan_name', (select name from products where id = o.product_id)),
      'xendit_failed:' || p_purchase_id::text);
  else
    -- Decision 88 (e): the checkout's held seat goes with its checkout, unless
    -- a newer checkout for the same seat is still open.
    if p.hold_booking_id is not null
       and exists (select 1 from bookings b where b.id = p.hold_booking_id
                     and b.status = 'pending_payment' and b.hold_reason = 'checkout')
       and not exists (select 1 from xendit_purchases x2
                        where x2.hold_booking_id = p.hold_booking_id
                          and x2.id <> p.id and x2.status = 'pending') then
      perform set_config('studiior.hold_release', '1', true);
      perform cancel_booking(p.hold_booking_id);
      perform set_config('studiior.hold_release', '', true);
    end if;
    perform queue_notification(
      p.studio_id, p.member_id, 'xendit_purchase_failed',
      jsonb_build_object('plan_name', (select name from membership_plans where id = p.plan_id)),
      'xendit_failed:' || p_purchase_id::text);
  end if;
end $$;

-- ---- sweep_unpaid_dropins (from 20260833580000) --------------------------
create or replace function sweep_unpaid_dropins() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r record;
  n_cancelled int := 0;
  n_offered   int := 0;
  v_res       cancel_result;
begin
  if not is_service_context() then
    raise exception 'the drop-in sweep runs as the backend, not as a user'
      using errcode = 'PT403';
  end if;

  for r in
    select b.id, b.studio_id
      from bookings b
      join studio_settings st on st.studio_id = b.studio_id
     where b.status = 'pending_payment'
       and coalesce(b.hold_reason, '') <> 'free_class_duplicate'  -- Decision 98 holds have their own 24h sweep
       -- Decision 116: a private's pending seats are released with the whole
       -- occurrence by the Xendit failure/expiry path, never one seat at a time.
       and b.payment_source is distinct from 'private'
       and (
         -- Decision 103(e): a reservation hold lasts until its hold_until (30 min).
         (b.hold_until is not null and now() >= b.hold_until)
         -- an unpaid drop-in (and a legacy reservation hold) at booked_at + window.
         or (b.hold_until is null and b.booked_at < now()
               - make_interval(mins => coalesce(st.dropin_payment_window_minutes, 15)))
       )
  loop
    begin
      v_res := cancel_booking(r.id);
      n_cancelled := n_cancelled + 1;
      if v_res.offer_made then
        n_offered := n_offered + 1;
      end if;

      -- The abandoned charge, marked so it stops looking like money in flight.
      update payments
         set status = 'failed',
             failure_code = 'checkout_abandoned',
             failure_message = 'The member did not finish paying inside the window.',
             updated_at = now()
       where booking_id = r.id and status = 'pending';

      -- Decision 103(c): expire the matching pending xendit purchase now, rather
      -- than leaving it for the daily reconcile — its booking is cancelled.
      update xendit_purchases
         set status = 'expired',
             failure_reason = 'hold_released',
             updated_at = now()
       -- Decision 88 (e): or the online checkout tied to this held seat.
       where (booking_id = r.id or hold_booking_id = r.id) and status = 'pending';
    exception when others then
      -- One studio's bad row must not stop every other studio's sweep, the same
      -- reasoning as a missing API key not taking the notification cron down.
      raise warning 'sweep_unpaid_dropins: booking % failed: %', r.id, sqlerrm;
    end;
  end loop;

  return jsonb_build_object('cancelled', n_cancelled, 'waitlist_offers', n_offered);
end $$;

-- ---- member_pending_bookings (from 20260833500000) -----------------------
create or replace function member_pending_bookings(p_studio_id uuid)
returns table(occurrence_id uuid, booking_id uuid, status text,
              hold_until timestamptz, pending_until timestamptz)
language plpgsql stable security definer set search_path to 'public' as $function$
declare v_member uuid;
begin
  select id into v_member from members where user_id = auth.uid() and studio_id = p_studio_id;
  if v_member is null then
    raise exception 'not a member of that studio' using errcode = 'PT403';
  end if;
  return query
  -- Decision 103(c): a RESERVATION HOLD — a pending_payment comp seat with
  -- hold_until null, created by reserve_free_first when a member starts paying
  -- the reservation fee — is never shown as booked. It reports 'pending_payment'
  -- with the hold expiry (booked_at + the drop-in payment window), on any class,
  -- so the app shows "Payment pending" with the minutes left, Finish paying and
  -- Cancel. The Decision 98 free-class-duplicate holds (hold_until set) have
  -- their own 24h flow and are not reported here.
  select b.occurrence_id, b.id, 'pending_payment'::text,
         coalesce(b.hold_until,
                  b.booked_at + make_interval(mins => coalesce(st.dropin_payment_window_minutes, 15))),
         null::timestamptz
    from bookings b
    join class_occurrences o on o.id = b.occurrence_id
    join studio_settings st  on st.studio_id = b.studio_id
   where b.member_id = v_member
     and b.status = 'pending_payment' and b.payment_source = 'comp'
     and coalesce(b.hold_reason, '') <> 'free_class_duplicate'  -- Decision 103(e): hold_until is now set (30 min)
     and o.status = 'scheduled'
  union all
  -- Decision 88 (e): an ONLINE CHECKOUT HOLD, a pending_payment drop-in held
  -- while the member pays, reports 'checkout_hold' with the time it ends. The
  -- app shows "Holding your spot", "Held until {time}" and Pay now.
  select b.occurrence_id, b.id, 'checkout_hold'::text, b.hold_until, null::timestamptz
    from bookings b
    join class_occurrences o on o.id = b.occurrence_id
   where b.member_id = v_member
     and b.status = 'pending_payment' and b.hold_reason = 'checkout'
     and b.hold_until > now()
     and o.status = 'scheduled'
  union all
  -- Decision 21 (byte-faithful from the prior reader's flex arm, minus the hold):
  -- a BOOKED flex class not yet committed carries its cutoff. The prior reader's
  -- flex arm also matched pending_payment rows; a hold is now Arm A above, so this
  -- arm is status='booked' only. A provisional free seat on a flex class is
  -- status='booked' and is still returned here with its deadline, exactly as
  -- before; the booked-side output is otherwise unchanged.
  select o.id, b.id, 'booked'::text, null::timestamptz, d.deadline_at
    from bookings b
    join class_occurrences o on o.id = b.occurrence_id
    cross join lateral flex_deadline_for_run(o.id) d
   where b.member_id = v_member
     and b.status = 'booked'
     and coalesce(o.flex, false) and o.committed_at is null and o.status = 'scheduled'
     and d.deadline_at is not null
  union all
  -- Decision 30 (byte-faithful from the prior reader's provisional arm): a
  -- PROVISIONAL free seat is pending too, with NO time shown (pending_until null)
  -- — it confirms the moment the class is on, so a deadline would mislead. On any
  -- class (flex or core); on a flex class it is also returned by the arm above
  -- with its cutoff, exactly as the prior reader did. status='booked', so the
  -- Book list renders it as the bare "Waiting for confirmation" chip.
  select b.occurrence_id, b.id, 'booked'::text, null::timestamptz, null::timestamptz
    from bookings b
    join class_occurrences o on o.id = b.occurrence_id
   where b.member_id = v_member
     and b.status = 'booked' and b.provisional
     and o.status = 'scheduled';
end $function$;

-- ---- checkout_hold_class: the 30-minute hold, one at a time ---------------
drop function if exists checkout_hold_class(uuid);

create or replace function checkout_hold_class(p_occurrence_id uuid, p_plan_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_member  uuid;
  v_studio  uuid;
  v_private boolean;
  v_until   timestamptz := now() + interval '30 minutes';
  v_held    uuid;
  r         book_class_result;
  h         record;
begin
  select studio_id, coalesce(is_private, false) into v_studio, v_private
    from class_occurrences where id = p_occurrence_id;
  if v_studio is null then raise exception 'no such class' using errcode = 'PT404'; end if;
  select id into v_member from members
   where studio_id = v_studio and user_id = auth.uid() and deleted_at is null;
  if v_member is null then
    raise exception 'you are not a member of that studio' using errcode = 'PT403';
  end if;

  -- Decision 88 (d): a private pack never pays for a group class.
  if p_plan_id is not null and not v_private and exists (
       select 1 from membership_plans
        where id = p_plan_id and studio_id = v_studio and coalesce(private_pack, false)) then
    return jsonb_build_object('failure_reason', 'private_pack_not_for_class',
                              'booking_id', null, 'hold_until', null);
  end if;

  -- This member's own holds that have already ended are released now rather
  -- than waiting up to two minutes for the sweep.
  for h in select id from bookings
            where member_id = v_member and status = 'pending_payment'
              and hold_reason = 'checkout' and hold_until <= now()
  loop
    perform cancel_booking(h.id);
  end loop;

  -- Decision 88 (e): one unpaid online seat at a time.
  if exists (select 1 from bookings
              where member_id = v_member and status = 'pending_payment'
                and hold_reason = 'checkout' and occurrence_id <> p_occurrence_id) then
    return jsonb_build_object('failure_reason', 'hold_open',
                              'booking_id', null, 'hold_until', null);
  end if;

  -- A hold on this class already: a new checkout re-arms it for 30 minutes.
  select id into v_held from bookings
   where member_id = v_member and occurrence_id = p_occurrence_id
     and status = 'pending_payment' and hold_reason = 'checkout';
  if v_held is not null then
    update bookings set hold_until = v_until where id = v_held;
    return jsonb_build_object('failure_reason', null,
                              'booking_id', v_held, 'hold_until', v_until);
  end if;

  perform set_config('studiior.checkout_hold', '1', true);
  r := book_class(p_occurrence_id, v_member, 'member'::booking_source);
  perform set_config('studiior.checkout_hold', '', true);

  if r.failure_reason is null and r.booking_id is not null and r.status = 'pending_payment' then
    update bookings set hold_until = v_until, hold_reason = 'checkout'
     where id = r.booking_id;
    return jsonb_build_object('failure_reason', null,
                              'booking_id', r.booking_id, 'hold_until', v_until);
  end if;
  return jsonb_build_object('failure_reason', r.failure_reason,
                            'booking_id', r.booking_id, 'hold_until', null);
end $function$;

revoke execute on function checkout_hold_class(uuid, uuid) from public, anon;
grant execute on function checkout_hold_class(uuid, uuid) to authenticated, service_role;

-- ---- checkout_link_hold: tie the Xendit purchase to the held seat ----------
create or replace function checkout_link_hold(p_purchase_id uuid, p_booking_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $function$
declare v_member uuid; n int;
begin
  select x.member_id into v_member
    from xendit_purchases x join members m on m.id = x.member_id
   where x.id = p_purchase_id and m.user_id = auth.uid();
  if v_member is null then
    raise exception 'that is not your checkout' using errcode = 'PT403';
  end if;
  update xendit_purchases x set hold_booking_id = p_booking_id, updated_at = now()
   where x.id = p_purchase_id and x.status = 'pending'
     and exists (select 1 from bookings b
                  where b.id = p_booking_id and b.member_id = v_member
                    and b.status = 'pending_payment' and b.hold_reason = 'checkout');
  get diagnostics n = row_count;
  return n = 1;
end $function$;

revoke execute on function checkout_link_hold(uuid, uuid) from public, anon;
grant execute on function checkout_link_hold(uuid, uuid) to authenticated, service_role;

-- ---- The public surface is unchanged: exactly fifteen anon functions --------
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'expect\_%' and p.proname not in ('call_jsonb');
  if n <> 15 then raise exception 'anon surface is %, expected 15', n; end if;
end $$;
