-- Decision 100 — Staff book for a member, and edit contact details.
-- Staff book a class for a member through the EXISTING paths (book_class for a
-- plan or drop-in, book_first_free for a free first class, convert_booking_to_
-- free_first for the manager-up override, a comp seat for complimentary), never
-- re-implementing the plan pick. When staff pin a specific plan, book_class
-- gains an optional p_membership_id that considers only it (refused
-- plan_not_covering if it does not cover); the member's own calls leave it null.
-- Staff edit a member's phone with staff_set_member_phone (normalise + write;
-- the Decision 98 recheck is already the members_phone_recheck trigger).
--
-- NOTE: there is no book_class_run twin. book_class is the single function, so
-- p_membership_id is added to book_class itself (drop + recreate for the new
-- arg, the 028 overload rule). book_first_free likewise gains an optional
-- p_member_id so the desk can book a member's free first class.

-- creates: staff_booking_options(uuid, uuid), staff_book_member(uuid, uuid, jsonb, text), staff_set_member_phone(uuid, text)
-- re-issues: book_class(uuid, uuid, booking_source, text, payment_source, uuid), book_first_free(uuid, uuid), member_activity(uuid, date, date)

-- ===========================================================================
-- book_class — re-issued with an optional p_membership_id (Decision 100). Drop
-- the 5-arg first so no overload survives (migration 028's trap).
-- ===========================================================================
drop function if exists public.book_class(uuid, uuid, booking_source, text, payment_source);
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
  if not v_override then
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

revoke execute on function public.book_class(uuid, uuid, booking_source, text, payment_source, uuid) from public, anon;
grant  execute on function public.book_class(uuid, uuid, booking_source, text, payment_source, uuid) to authenticated, service_role;

-- ===========================================================================
-- book_first_free — re-issued with an optional p_member_id (desk-up when set).
-- ===========================================================================
drop function if exists public.book_first_free(uuid);
CREATE OR REPLACE FUNCTION public.book_first_free(p_occurrence_id uuid, p_member_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_occ    class_occurrences%rowtype;
  v_member members%rowtype;
  v_set    studio_settings%rowtype;
  v_ser    class_series%rowtype;
  v_cfg_tier guarantee_tier;
  v_tz     text;
  v_elig   jsonb;
  v_free   int;
  v_head   int;
  v_cut    timestamptz;
  v_prov   boolean;
  v_booking uuid;
  v_pass    uuid;
begin
  select * into v_occ from class_occurrences where id = p_occurrence_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;

  -- Decision 100: staff may book a member's free first class (desk-up). Self when
  -- p_member_id is null, which is how the member's own call resolves.
  if p_member_id is not null then
    if not (coalesce(is_desk_up(v_occ.studio_id), false) or is_service_context()) then
      return jsonb_build_object('ok', false, 'reason', 'not_authorised');
    end if;
    select * into v_member from members
     where id = p_member_id and studio_id = v_occ.studio_id and deleted_at is null;
  else
    select * into v_member from members
     where studio_id = v_occ.studio_id and user_id = auth.uid();
  end if;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_authorised'); end if;

  v_elig := free_first_eligibility(v_occ.studio_id, v_member.id);
  if not (v_elig ->> 'ok')::boolean then return v_elig; end if;

  select * into v_set from studio_settings where studio_id = v_occ.studio_id;
  select timezone into v_tz from studios where id = v_occ.studio_id;

  if v_occ.status <> 'scheduled' then return jsonb_build_object('ok', false, 'reason', 'class_not_bookable'); end if;
  if v_occ.starts_at <= now() then return jsonb_build_object('ok', false, 'reason', 'class_in_past'); end if;
  if not month_published(v_occ.studio_id, v_occ.starts_at) then
    return jsonb_build_object('ok', false, 'reason', 'month_not_published');
  end if;
  if studio_hides_unstaffed(v_occ.studio_id) and v_occ.staffing <> 'assigned' then
    return jsonb_build_object('ok', false, 'reason', 'not_staffed_yet');
  end if;
  if v_occ.hidden_from_members then
    return jsonb_build_object('ok', false, 'reason', 'class_hidden');
  end if;
  if v_occ.starts_at > now() + make_interval(days => coalesce(v_set.booking_window_days, 30)) then
    return jsonb_build_object('ok', false, 'reason', 'outside_booking_window');
  end if;
  if v_occ.starts_at < now() + make_interval(mins => coalesce(v_set.booking_cutoff_minutes, 0)) then
    return jsonb_build_object('ok', false, 'reason', 'past_booking_cutoff');
  end if;

  -- Decision 30 amendment (b): a per-class override. 'closed' = never, whatever
  -- the rules say; 'open' skips core_only and the series switch below (seat cap
  -- and peak still apply).
  if v_occ.free_first_override = 'closed' then
    return jsonb_build_object('ok', false, 'reason', 'free_first_closed_here');
  end if;

  if not coalesce(v_set.free_first_peak_allowed, true) and occurrence_is_peak(p_occurrence_id) then
    return jsonb_build_object('ok', false, 'reason', 'peak_not_allowed');
  end if;

  if v_occ.series_id is not null then
    select * into v_ser from class_series where id = v_occ.series_id;
  end if;
  v_cfg_tier := coalesce(v_occ.guarantee_tier,
                         case when v_occ.flex then 'flex'::guarantee_tier end,
                         v_ser.guarantee_tier,
                         case when v_ser.flex then 'flex'::guarantee_tier end,
                         'core'::guarantee_tier);
  if coalesce(v_set.free_first_core_only, false) and v_cfg_tier <> 'core'
     and v_occ.free_first_override is distinct from 'open' then
    return jsonb_build_object('ok', false, 'reason', 'flex_not_allowed');
  end if;
  if v_occ.series_id is not null
     and not coalesce(v_ser.free_first_allowed, true)
     and v_occ.free_first_override is distinct from 'open' then
    return jsonb_build_object('ok', false, 'reason', 'not_trial_class');
  end if;
  if v_set.free_first_seats_per_class is not null
     and (select count(*) from bookings b
           where b.occurrence_id = p_occurrence_id and b.status = 'booked'
             and b.payment_source = 'comp'
             and exists (select 1 from guest_passes gp
                          where gp.guest_booking_id = b.id and gp.host_member_id is null))
         >= v_set.free_first_seats_per_class then
    return jsonb_build_object('ok', false, 'reason', 'free_seats_full');
  end if;

  v_free := v_occ.capacity - occurrence_seats_taken(p_occurrence_id)
                           - occurrence_seats_held(p_occurrence_id);
  if v_free < 1 then return jsonb_build_object('ok', false, 'reason', 'class_full'); end if;

  v_head := occurrence_seats_taken(p_occurrence_id) + 1;
  select cutoff_at into v_cut from occurrence_guarantee_run(p_occurrence_id);
  v_prov := v_set.free_first_confirm_at is not null
            and v_cut is not null
            and v_head < v_set.free_first_confirm_at;

  -- Mark this seat a free first class for the AFTER-INSERT notification trigger,
  -- which fires before the guest_passes row below is written.
  perform set_config('studiior.free_first', '1', true);

  insert into bookings (studio_id, occurrence_id, member_id, status, source,
                        payment_source, provisional, confirmed_at)
  values (v_occ.studio_id, p_occurrence_id, v_member.id, 'booked', 'member', 'comp',
          v_prov, case when v_prov then null else now() end)
  returning id into v_booking;
  update class_occurrences set booked_count = booked_count + 1 where id = p_occurrence_id;

  -- The shared once-ever ledger row. Decision 78: a no-show member's rebook
  -- REUSES this row (upsert on the once-ever index) rather than inserting a
  -- second — the index and its hard guarantee are untouched; the member's comp
  -- no_show bookings are what count the attempts.
  insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email,
                            occurrence_id, guest_booking_id, status, waiver_signed_at)
  values (v_occ.studio_id, null, v_member.id, lower(btrim(v_member.email)),
          p_occurrence_id, v_booking,
          case when v_member.waiver_signed_at is not null then 'confirmed' else 'invited' end,
          v_member.waiver_signed_at)
  on conflict (studio_id, normalize_email_key(guest_email)) do update
    set host_member_id   = excluded.host_member_id,
        guest_member_id  = excluded.guest_member_id,
        occurrence_id    = excluded.occurrence_id,
        guest_booking_id = excluded.guest_booking_id,
        status           = excluded.status,
        waiver_signed_at = excluded.waiver_signed_at
  returning id into v_pass;

  perform confirm_provisional_seats_run(p_occurrence_id);

  return jsonb_build_object('ok', true, 'booking_id', v_booking,
    'guest_pass_id', v_pass, 'provisional', v_prov);
end $function$;

revoke execute on function public.book_first_free(uuid, uuid) from public, anon;
grant  execute on function public.book_first_free(uuid, uuid) to authenticated, service_role;

-- ===========================================================================
-- member_activity — re-issued with a booked_by_staff Journey arm (Decision 100).
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.member_activity(p_member_id uuid, p_from date, p_to date)
 RETURNS TABLE(at timestamp with time zone, kind text, title text, detail text, credit_delta integer, balance_after integer, amount_cents integer, currency text, occurrence_id uuid, booking_id uuid, membership_id uuid, plan_name text, due_cents integer, is_free_first boolean, occurrence_start timestamp with time zone, instructor_first text, credits_left_after integer, payment_method text, recorded_by_name text, plan_classes integer, plan_valid_to date, unused_credits integer, payment_source text, is_paid boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
           (sum(cl.delta) over (order by cl.created_at, cl.id))::int as bal,
           (sum(cl.delta) over (partition by cl.membership_id order by cl.created_at, cl.id))::int as membership_bal
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
    -- Decision 95: a flex-rescue email was sent (staff only).
    select coalesce(nt.sent_at, nt.scheduled_for, nt.created_at) as at,
           'rescue_email' as kind, 'Rescue email sent' as title,
           case when nt.template_key = 'flex_rescue_2days'
                then 'Flex class still needs numbers'
                else 'Last call to move the booking' end as detail,
           null::uuid as ledger_id, null::int as amount_cents, null::text as currency,
           null::uuid as occurrence_id, null::uuid as booking_id, null::uuid as membership_id
      from notifications nt
     where nt.member_id = p_member_id and v_is_staff
       and nt.template_key in ('flex_rescue_2days','flex_rescue_final','free_rescue_2days','free_rescue_final')
    union all
    -- joined (staff only)
    select m.joined_on::timestamptz as at, 'joined' as kind, 'Joined the studio' as title,
           nullif('Came via ' || coalesce(m.source, ''), 'Came via ') as detail,
           null::uuid as ledger_id, null::int as amount_cents, null::text as currency,
           null::uuid as occurrence_id, null::uuid as booking_id, null::uuid as membership_id
      from members m where m.id = p_member_id and v_is_staff and m.joined_on is not null
    union all
    -- Decision 97: invited a guest (this member is the host). Derived from
    -- the invite snapshot, so it survives the guest's deletion or merge.
    select gp.invited_at as at, 'invited_guest' as kind,
           'Invited ' || coalesce(g.first_name, 'a guest') || ' to ' || coalesce(o.name, ct.name, 'a class') as title,
           null::text as detail,
           null::uuid as ledger_id, null::int as amount_cents, null::text as currency,
           gp.occurrence_id as occurrence_id, null::uuid as booking_id, null::uuid as membership_id
      from guest_passes gp
      join class_occurrences o on o.id = gp.occurrence_id
      left join class_types ct on ct.id = o.class_type_id
      left join members g on g.id = gp.guest_member_id
     where gp.host_member_id = p_member_id and gp.invited_at is not null
    union all
    -- Decision 97: invited by a host (this member is the guest). The host
    -- name is the invite snapshot, surviving the host's deletion or merge.
    select gp.invited_at as at, 'invited_by' as kind,
           'Invited by ' || coalesce(gp.host_name_at_invite, 'a member') as title,
           null::text as detail,
           null::uuid as ledger_id, null::int as amount_cents, null::text as currency,
           gp.occurrence_id as occurrence_id, null::uuid as booking_id, null::uuid as membership_id
      from guest_passes gp
     where gp.guest_member_id = p_member_id and gp.host_member_id is not null and gp.invited_at is not null
    union all
    -- Decision 97 (a): a member merged into this account (staff only). Read from
    -- the member.merged audit row so a past merge shows and the removed email survives.
    select al.created_at as at, 'merged' as kind,
           'Merged ' || coalesce(al.before->>'removed_email', 'an account') || ' into this account' as title,
           null::text as detail,
           null::uuid, null::int, null::text, null::uuid, null::uuid, null::uuid
      from audit_logs al
     where al.action = 'member.merged' and v_is_staff
       and (al.after->>'merged_into')::uuid = p_member_id
    union all
    -- Decision 100: a staff member booked a class for this member (staff only).
    -- Read from the booking.booked_by_staff audit row so the attribution survives.
    select al.created_at as at, 'booked_by_staff' as kind,
           'Booked by ' || coalesce(al.after->>'staff_first', 'the studio')
             || coalesce(' with ' || (al.after->>'source'), '') as title,
           null::text as detail,
           null::uuid, null::int, null::text, null::uuid, null::uuid, null::uuid
      from audit_logs al
     where al.action = 'booking.booked_by_staff' and v_is_staff
       and al.entity_id = p_member_id
    union all
    -- Decision 92 (b): removed from a class by staff. From the audit row, so the
    -- class name and the staff first name survive.
    select al.created_at as at, 'removed_by_studio' as kind,
           'Removed from ' || coalesce(al.after->>'class_name', 'a class')
             || ' by ' || coalesce(al.after->>'staff_first', 'the studio') as title,
           null::text as detail,
           null::uuid, null::int, null::text, null::uuid, al.entity_id, null::uuid
      from audit_logs al
     where al.action = 'booking.removed_by_staff' and v_is_staff
       and (al.before->>'member_id')::uuid = p_member_id

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
       and not exists (select 1 from audit_logs al
                        where al.action = 'booking.removed_by_staff' and al.entity_id = b.id)
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
    union all
    -- contacted (staff only) — a task contacted the old way (no member_contacts
    -- row). A task linked to a contact (contact_id set) shows via the arm below.
    select mt.contacted_at, 'contacted', 'Contacted', mt.reason,
           null::uuid, null, null, null, null, null
      from member_tasks mt
     where mt.member_id = p_member_id and v_is_staff
       and mt.status = 'contacted' and mt.contacted_at is not null
       and mt.contact_id is null
    union all
    -- Decision 79: retention outreach logged in member_contacts (staff only).
    select mc.contacted_at, 'contacted',
           case when mc.method = 'email' then 'Emailed'
                when mc.method = 'viber' then 'Contacted (Viber)'
                when mc.method = 'call'  then 'Called'
                else 'Contacted (in person)' end
             || coalesce(' by ' || nullif(pr.full_name, ''), ''),
           mc.subject,
           null::uuid, null, null, null, null, null
      from member_contacts mc
      left join profiles pr on pr.id = mc.staff_id
     where mc.member_id = p_member_id and v_is_staff
    union all
    -- Decision 83 (a): a plan that ended (expired, or ended by staff) — NOT
    -- a refund, which tells its own story. Claims the end-forfeit ledger row
    -- so it is not also a bare "Credit adjustment"; unused = classes forfeited.
    select coalesce(ms2.cancelled_at, (ms2.expires_on)::timestamptz), 'plan_ended', 'Plan ended', null,
           (select cl.id from led cl
             where cl.membership_id = ms2.id and cl.reason = 'manual' and cl.delta < 0
               and cl.id not in (select ledger_id from pay_forfeit)
             order by cl.created_at desc, cl.id desc limit 1),
           null, null, null::uuid, null, ms2.id
      from memberships ms2
     where ms2.member_id = p_member_id
       and ms2.status in ('cancelled','expired')
       and coalesce(ms2.cancelled_at, (ms2.expires_on)::timestamptz) is not null
       and not exists (select 1 from payments p where p.membership_id = ms2.id
                        and (p.refunded_at is not null or p.status in ('refunded','partially_refunded')))
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
    x.amount_cents, x.currency, x.occurrence_id, x.booking_id, x.membership_id,
    -- Decision 83. plan_name: the plan a booking drew from, a cancellation or a
    -- no-show consumed/returned to, or the ended plan. null on every other kind.
    case when x.kind in ('booked','cancelled','late_cancelled','studio_cancelled','no_show','plan_ended')
         then mp.name end as plan_name,
    -- due_cents: a LIVE unpaid drop-in booking only — the cheapest active public
    -- drop_in plan price, what Pay-now charges (bookings store no per-row price).
    case when x.kind = 'booked' and exists (
           select 1 from bookings b
            where b.id = x.booking_id and b.payment_source = 'drop_in' and b.status = 'booked'
              and not exists (select 1 from payments p
                               where p.booking_id = b.id and p.status in ('succeeded','partially_refunded')))
         then (select dp.price_cents from membership_plans dp
                where dp.studio_id = v_studio and dp.type = 'drop_in'
                  and dp.visibility = 'public' and dp.status = 'active'
                order by dp.price_cents asc, dp.sort_order asc, dp.id limit 1)
         end as due_cents,
    -- is_free_first: true on a free-first comp booking AND on its later cancel /
    -- no-show rows, so the helper can say "Free class used" / "Free class kept".
    (x.booking_id is not null and exists (
       select 1 from bookings b join guest_passes gp on gp.guest_booking_id = b.id
        where b.id = x.booking_id and b.payment_source = 'comp' and gp.host_member_id is null))
      as is_free_first,
    -- Decision 83 (a): the class instant + instructor, for the "{Day} {date},
    -- {time} with {instructor}" line (rowLine renders in the studio timezone).
    occ.starts_at as occurrence_start,
    nullif(split_part(coalesce(inst.display_name, ''), ' ', 1), '') as instructor_first,
    -- credits_left_after: the plan balance after this row. A no-show and a late
    -- cancel that used the credit carry no ledger of their own (the credit was
    -- spent at booking), so read that booking's consume row; a late cancel that
    -- refunded (consumes-off) has a refund ledger row, so coalesce keeps it. null
    -- = no plan credit touched (free first, unlimited, drop-in, money rows).
    case when x.kind in ('no_show','late_cancelled')
         then coalesce(l.membership_bal,
                       (select l2.membership_bal from led l2 join bookings b2 on b2.credit_entry_id = l2.id
                         where b2.id = x.booking_id))
         else l.membership_bal end as credits_left_after,
    -- payment_method / recorded_by_name: the money row's own payment (lateral,
    -- keyed on member + the arm's `at`). recorded_by is null for an online
    -- payment, so recorded_by_name is null unless it was taken at the desk.
    pm.method as payment_method,
    rec.full_name as recorded_by_name,
    case when x.kind = 'purchase' then coalesce(mp.credits, mp.credits_per_period) end as plan_classes,
    case when x.kind = 'purchase' then ms.expires_on end as plan_valid_to,
    case when x.kind = 'plan_ended' then abs(coalesce(l.delta, 0)) end as unused_credits,
    -- Decision 83 (a) follow-up: the booking's own payment_source (comp / drop_in /
    -- class_pack / membership / group), null for a non-booking row; and whether a
    -- booking row has a succeeded or partially_refunded payment, null otherwise.
    -- rowLine reads these to say "Complimentary" vs "Drop-in, paid" vs "due".
    (select b.payment_source::text from bookings b where b.id = x.booking_id) as payment_source,
    case when x.booking_id is not null
         then exists (select 1 from payments p
                       where p.booking_id = x.booking_id and p.status in ('succeeded','partially_refunded'))
         end as is_paid
  from all_rows x
  left join led l on l.id = x.ledger_id
  left join memberships ms on ms.id = x.membership_id
  left join membership_plans mp on mp.id = ms.plan_id
  left join class_occurrences occ on occ.id = x.occurrence_id
  left join instructors inst on inst.id = occ.instructor_id
  left join lateral (
    select p2.method, p2.recorded_by
      from payments p2
     where x.kind in ('purchase','refund','payment_failed')
       and p2.member_id = p_member_id
       and coalesce(p2.paid_at, p2.created_at) = x.at
     order by p2.id limit 1) pm on true
  left join profiles rec on rec.id = pm.recorded_by
  where x.at is not null and x.at::date between p_from and p_to
  order by x.at desc, x.kind;
end $function$;
revoke execute on function member_activity(uuid, date, date) from public, anon;
grant  execute on function member_activity(uuid, date, date) to authenticated, service_role;
revoke execute on function member_activity(uuid, date, date) from public, anon;
grant  execute on function member_activity(uuid, date, date) to authenticated, service_role;

-- ===========================================================================
-- staff_booking_options — the "Pay with" dropdown for a member and a class.
-- Desk-up read. Lists only what applies: each covering plan or pass, free first
-- (or its manager-up override), drop-in paid, drop-in pay-later (when the unpaid
-- cap allows), and complimentary (manager-up). The first covering plan is the
-- preselect. book_class stays authoritative; this only drives the UI.
-- ===========================================================================
create or replace function staff_booking_options(p_member_id uuid, p_occurrence_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_occ    class_occurrences%rowtype;
  v_set    studio_settings%rowtype;
  v_member members%rowtype;
  v_tz     text;
  v_today  date;
  v_mgr    boolean;
  v_opts   jsonb := '[]'::jsonb;
  v_preselect int := 0;
  v_idx    int := 0;
  v_first_plan int := null;
  v_cand   record;
  v_covers boolean;
  v_label  text;
  v_total  int;
  v_dropin int;
  v_unpaid int;
  v_cap    int;
  v_blocked boolean;
  v_elig   jsonb;
begin
  select * into v_occ from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not (coalesce(is_desk_up(v_occ.studio_id), false) or is_service_context()) then
    raise exception 'only the desk and up book for a member' using errcode = 'PT403';
  end if;
  select * into v_member from members where id = p_member_id and studio_id = v_occ.studio_id and deleted_at is null;
  if not found then raise exception 'no such member' using errcode = 'PT404'; end if;
  select * into v_set from studio_settings where studio_id = v_occ.studio_id;
  select timezone into v_tz from studios where id = v_occ.studio_id;
  v_today := (now() at time zone v_tz)::date;
  v_mgr := coalesce(is_manager_up(v_occ.studio_id), false) or is_service_context();

  -- Covering plans and passes, in book_class's own priority order.
  for v_cand in
    select ms.id, ms.credits_remaining, ms.expires_on, mp.name, mp.restrictions,
           mp.type, mp.credits, mp.credits_per_period,
           case
             when mp.type = 'recurring' and mp.credits_per_period is null
                  and ms.credits_remaining is null then 1
             when mp.type = 'recurring' and coalesce(ms.credits_remaining,0) > 0 then 2
             when mp.type in ('class_pack','drop_in','trial') and coalesce(ms.credits_remaining,0) > 0 then 3
             else 99 end as priority
      from memberships ms join membership_plans mp on mp.id = ms.plan_id
     where ms.member_id = p_member_id and ms.studio_id = v_occ.studio_id
       and (ms.status in ('active','trialing')
            or (ms.status = 'past_due'
                and now() < coalesce(ms.current_period_end, now())
                            + make_interval(days => v_set.payment_grace_days)))
       and not (ms.freeze_start is not null and ms.freeze_end is not null
                and v_today between ms.freeze_start and ms.freeze_end)
       and (ms.expires_on is null or ms.expires_on >= v_today)
     order by priority, ms.expires_on asc nulls last, ms.created_at asc
  loop
    continue when v_cand.priority = 99;
    v_covers := (v_cand.restrictions -> 'class_type_ids') is null
             or jsonb_typeof(v_cand.restrictions -> 'class_type_ids') <> 'array'
             or jsonb_array_length(v_cand.restrictions -> 'class_type_ids') = 0
             or (v_occ.class_type_id is not null
                 and jsonb_exists(v_cand.restrictions -> 'class_type_ids', v_occ.class_type_id::text));
    continue when not v_covers;
    if v_cand.priority = 1 then
      v_label := v_cand.name;
    else
      v_total := coalesce(v_cand.credits, v_cand.credits_per_period);
      v_label := v_cand.name || ', ' || coalesce(v_cand.credits_remaining,0)::text
                 || coalesce(' of ' || v_total::text, '') || ' credits'
                 || coalesce(', valid to ' || to_char(v_cand.expires_on, 'FMDD FMMon'), '');
    end if;
    v_opts := v_opts || jsonb_build_object('kind','plan','membership_id',v_cand.id,'label',v_label);
    if v_first_plan is null then v_first_plan := v_idx; end if;
    v_idx := v_idx + 1;
  end loop;

  -- Free first class, or the manager-up override when not eligible.
  -- the unguarded twin: this definer is desk-up itself (checked above).
  v_elig := free_first_eligibility_run(v_occ.studio_id, p_member_id);
  if (v_elig ->> 'ok')::boolean then
    v_opts := v_opts || jsonb_build_object('kind','free_first','label','Free first class');
    v_idx := v_idx + 1;
  elsif v_mgr then
    v_opts := v_opts || jsonb_build_object('kind','free_first_override','label','Free first class (override)');
    v_idx := v_idx + 1;
  end if;

  -- Drop-in, paid at the studio. The price is the cheapest active public drop-in plan.
  select min(price_cents) into v_dropin from membership_plans
   where studio_id = v_occ.studio_id and type = 'drop_in'
     and status = 'active' and visibility = 'public';
  v_opts := v_opts || jsonb_build_object('kind','drop_in_paid',
             'label','Drop-in, paid at the studio','price_cents',v_dropin);
  v_idx := v_idx + 1;

  -- Drop-in, pay later — only when the unpaid cap allows and desk pay is not blocked.
  v_cap := v_set.max_unpaid_bookings;
  v_blocked := exists (select 1 from members dm where dm.id = p_member_id and dm.desk_pay_blocked_at is not null)
               and coalesce(v_set.desk_pay_mode,'earned') = 'earned';
  select count(*) into v_unpaid from bookings b
   where b.member_id = p_member_id and b.studio_id = v_occ.studio_id
     and b.payment_source = 'drop_in' and b.status in ('booked','pending_payment')
     and not exists (select 1 from payments p where p.booking_id = b.id
                       and p.status in ('succeeded','partially_refunded'));
  if not v_blocked and (v_cap is null or v_unpaid < v_cap) then
    v_opts := v_opts || jsonb_build_object('kind','drop_in_later','label','Drop-in, pay later');
    v_idx := v_idx + 1;
  end if;

  -- Complimentary — manager-up.
  if v_mgr then
    v_opts := v_opts || jsonb_build_object('kind','complimentary','label','Complimentary');
    v_idx := v_idx + 1;
  end if;

  v_preselect := coalesce(v_first_plan, 0);

  return jsonb_build_object(
    'member_first', v_member.first_name,
    'class_name', coalesce((select name from class_types where id = v_occ.class_type_id), v_occ.name, 'a class'),
    'starts_at', v_occ.starts_at,
    'options', v_opts,
    'preselect', v_preselect);
end $$;
revoke execute on function staff_booking_options(uuid, uuid) from public, anon;
grant  execute on function staff_booking_options(uuid, uuid) to authenticated, service_role;


-- ===========================================================================
-- staff_book_member — book a class for a member through the existing paths.
-- Desk-up for a plan, free first (when eligible), or a drop-in. Manager-up for
-- the free-first override and complimentary. Never re-implements the plan pick:
-- it calls book_class (pinning the chosen plan), book_first_free,
-- convert_booking_to_free_first, and record_desk_dropin_paid. The refusal is the
-- member-facing reason; the caller shows it with the member's name in front.
-- ===========================================================================
create or replace function staff_book_member(
  p_member_id uuid, p_occurrence_id uuid, p_source jsonb, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_occ    class_occurrences%rowtype;
  v_set    studio_settings%rowtype;
  v_member members%rowtype;
  v_mgr    boolean;
  v_kind   text;
  v_res    book_class_result;
  v_booking uuid;
  v_conv   jsonb;
  v_pay    jsonb;
  v_staff_first text;
  v_cap    int;
  v_unpaid int;
  v_label  text;
begin
  select * into v_occ from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not (coalesce(is_desk_up(v_occ.studio_id), false) or is_service_context()) then
    raise exception 'only the desk and up book for a member' using errcode = 'PT403';
  end if;
  select * into v_member from members where id = p_member_id and studio_id = v_occ.studio_id and deleted_at is null;
  if not found then raise exception 'no such member' using errcode = 'PT404'; end if;
  select * into v_set from studio_settings where studio_id = v_occ.studio_id;
  v_mgr := coalesce(is_manager_up(v_occ.studio_id), false) or is_service_context();
  v_staff_first := coalesce(
    nullif(split_part((select full_name from profiles where id = auth.uid()), ' ', 1), ''),
    'the studio');
  v_kind := p_source ->> 'kind';
  v_label := p_source ->> 'kind';

  if v_kind in ('free_first_override','complimentary') and not v_mgr then
    raise exception 'only owners and managers do this' using errcode = 'PT403';
  end if;

  if v_kind = 'plan' then
    v_res := book_class(p_occurrence_id, p_member_id, 'front_desk', null, null,
                        (p_source ->> 'membership_id')::uuid);
    v_label := 'a plan';

  elsif v_kind = 'free_first' then
    v_conv := book_first_free(p_occurrence_id, p_member_id);
    if not (v_conv ->> 'ok')::boolean then
      return jsonb_build_object('ok', false, 'reason', v_conv ->> 'reason', 'member_first', v_member.first_name);
    end if;
    v_booking := (v_conv ->> 'booking_id')::uuid;
    v_label := 'a free first class';

  elsif v_kind = 'free_first_override' then
    -- Book a drop-in, then convert it (overrides the eligibility refusal).
    v_res := book_class(p_occurrence_id, p_member_id, 'front_desk', null, null, null);
    if v_res.failure_reason is not null then
      return jsonb_build_object('ok', false, 'reason', v_res.failure_reason, 'member_first', v_member.first_name);
    end if;
    if v_res.payment_source is distinct from 'drop_in' then
      return jsonb_build_object('ok', false, 'reason', 'plan_not_covering', 'member_first', v_member.first_name);
    end if;
    v_booking := v_res.booking_id;
    v_conv := convert_booking_to_free_first(v_booking);
    if not (v_conv ->> 'ok')::boolean then
      return jsonb_build_object('ok', false, 'reason', v_conv ->> 'reason', 'member_first', v_member.first_name);
    end if;
    v_label := 'a free first class (override)';

  elsif v_kind = 'drop_in_paid' then
    v_res := book_class(p_occurrence_id, p_member_id, 'front_desk', null, null, null);
    if v_res.failure_reason is not null then
      return jsonb_build_object('ok', false, 'reason', v_res.failure_reason, 'member_first', v_member.first_name);
    end if;
    v_booking := v_res.booking_id;
    v_pay := record_desk_dropin_paid(v_booking, coalesce(p_source ->> 'method','cash'),
               (p_source ->> 'amount_cents')::int, nullif(p_source ->> 'reference',''));
    if not coalesce((v_pay ->> 'ok')::boolean, true) then
      return jsonb_build_object('ok', false, 'reason', v_pay ->> 'reason', 'member_first', v_member.first_name);
    end if;
    v_label := 'a drop-in, paid at the studio';

  elsif v_kind = 'drop_in_later' then
    -- Enforce the unpaid cap here, because a desk booking bypasses book_class's.
    v_cap := v_set.max_unpaid_bookings;
    select count(*) into v_unpaid from bookings b
     where b.member_id = p_member_id and b.studio_id = v_occ.studio_id
       and b.payment_source = 'drop_in' and b.status in ('booked','pending_payment')
       and not exists (select 1 from payments p where p.booking_id = b.id
                         and p.status in ('succeeded','partially_refunded'));
    if v_cap is not null and v_unpaid >= v_cap then
      return jsonb_build_object('ok', false, 'reason', 'pay_first', 'member_first', v_member.first_name);
    end if;
    v_res := book_class(p_occurrence_id, p_member_id, 'front_desk', null, null, null);
    if v_res.failure_reason is not null then
      return jsonb_build_object('ok', false, 'reason', v_res.failure_reason, 'member_first', v_member.first_name);
    end if;
    v_booking := v_res.booking_id;
    v_label := 'a drop-in, pay later';

  elsif v_kind = 'complimentary' then
    v_res := book_class(p_occurrence_id, p_member_id, 'front_desk',
                        coalesce(nullif(btrim(coalesce(p_note,'')), ''), 'staff_comp'), 'comp', null);
    if v_res.failure_reason is not null then
      return jsonb_build_object('ok', false, 'reason', v_res.failure_reason, 'member_first', v_member.first_name);
    end if;
    v_booking := v_res.booking_id;
    v_label := 'a complimentary seat';

  else
    raise exception 'unknown booking source' using errcode = 'PT400';
  end if;

  -- The plan / drop-in / comp paths return through v_res; carry its refusal.
  if v_kind in ('plan') and v_res.failure_reason is not null then
    return jsonb_build_object('ok', false, 'reason', v_res.failure_reason, 'member_first', v_member.first_name);
  end if;
  if v_kind = 'plan' then v_booking := v_res.booking_id; end if;

  -- The attribution: one audit row, read back by member_activity's Journey arm.
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (v_occ.studio_id, auth.uid(), 'booking.booked_by_staff', 'members', p_member_id,
            jsonb_build_object('staff_first', v_staff_first, 'source', v_label,
                               'occurrence_id', p_occurrence_id, 'booking_id', v_booking,
                               'note', nullif(btrim(coalesce(p_note,'')), '')));

  return jsonb_build_object('ok', true, 'booking_id', v_booking, 'source', v_label,
                            'member_first', v_member.first_name);
end $$;
revoke execute on function staff_book_member(uuid, uuid, jsonb, text) from public, anon;
grant  execute on function staff_book_member(uuid, uuid, jsonb, text) to authenticated, service_role;


-- ===========================================================================
-- staff_set_member_phone — desk-up edits a member's phone. Only normalises and
-- writes: the Decision 98 same-person recheck is the members_phone_recheck
-- trigger, which fires on any phone change. The caller validates with
-- lib/phone.mjs first for the member-facing message; this normalises again in
-- SQL (defensive) and refuses an empty result.
-- ===========================================================================
create or replace function staff_set_member_phone(p_member_id uuid, p_phone text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_member members%rowtype;
  v_country text;
  v_norm text;
  v_staff_first text;
begin
  select * into v_member from members where id = p_member_id and deleted_at is null;
  if not found then raise exception 'no such member' using errcode = 'PT404'; end if;
  if not (coalesce(is_desk_up(v_member.studio_id), false) or is_service_context()) then
    raise exception 'only the desk and up edit contact details' using errcode = 'PT403';
  end if;
  select country into v_country from studios where id = v_member.studio_id;
  v_norm := normalise_phone(p_phone, v_country);
  -- Validate like lib/phone.mjs (the member sheet's own rule): a PH mobile is
  -- +639XXXXXXXXX; any other country wants 7 to 15 digits. normalise_phone is a
  -- lenient dedupe key, so the shape is checked here too (the caller validates
  -- first for the member-facing message; this is the backstop).
  if nullif(btrim(coalesce(v_norm, '')), '') is null
     or (v_country = 'PH' and v_norm !~ '^\+639[0-9]{9}$')
     or (coalesce(v_country,'') <> 'PH'
         and length(regexp_replace(coalesce(v_norm,''), '[^0-9]', '', 'g')) not between 7 and 15) then
    raise exception 'that does not look like a mobile number' using errcode = 'PT422';
  end if;
  v_staff_first := coalesce(
    nullif(split_part((select full_name from profiles where id = auth.uid()), ' ', 1), ''), 'the studio');

  update members set phone = v_norm, updated_at = now() where id = p_member_id;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (v_member.studio_id, auth.uid(), 'member.phone_changed', 'members', p_member_id,
            jsonb_build_object('staff_first', v_staff_first, 'phone', v_norm));

  return jsonb_build_object('ok', true, 'phone', v_norm);
end $$;
revoke execute on function staff_set_member_phone(uuid, text) from public, anon;
grant  execute on function staff_set_member_phone(uuid, text) to authenticated, service_role;

-- --- Anon stays EXACTLY THIRTEEN --------------------------------------------
do $$ declare n int; begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % (want 13)', n; end if;
end $$;
