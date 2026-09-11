-- =============================================================================
-- 106 — Decision 24: the peak allowance itself.
--
-- Migration 104 said when peak is and which plans are held to it, and changed
-- nothing. This is the half that decides who gets in.
--
-- -----------------------------------------------------------------------------
-- THERE IS NO MIGRATION 105, AND THAT IS A FINDING RATHER THAN AN OMISSION.
--
-- The plan said `booking_release_reason` would need new values — flex-not-
-- running and staff-excused — carried alone, because a new enum value cannot be
-- used in the transaction that adds it. Neither is needed:
--
--   FLEX-NOT-RUNNING is already `studio_released`. `cancel_occurrence()` sets
--   the `studiior.releasing` flag, so a class cancelled for missing its minimum
--   stamps exactly that — and it SHOULD, because `release_reason` is what the
--   studio owes the MEMBER and a class cancelled for want of one booking owes
--   the member identically to one cancelled by a brownout. What differs is what
--   the studio owes the INSTRUCTOR, and that is `cancellation_cause` on the
--   occurrence, which already carries `unmet_minimum`. Two typed facts, never
--   derived from each other — and this is the case they were separated for.
--
--   STAFF-EXCUSED is not a reason a booking was RELEASED. A late cancellation
--   that staff later excuse was still released because the member cancelled
--   late; that is the honest value and it stays. The excuse is a separate
--   event, and it belongs on the ledger row that reverses the consequence, not
--   on the booking that records the act. It arrives with the infractions
--   migration, which is the thing that has a writer for it.
--
-- The three existing values are exactly sufficient: `member_cancelled` and
-- `studio_released` restore, `late_cancelled` does not.
--
-- -----------------------------------------------------------------------------
-- A TIMELY CANCELLATION GIVES THE SLOT BACK. The seam's comment said otherwise
-- and the seam's comment was written before this was designed.
--
-- `tg_stamp_booking_release()` has carried "WHEN PEAK ALLOWANCE ARRIVES, IT GOES
-- HERE, for 'studio_released' only" since migration 079. Restoring on studio
-- release only would mean a member who books a peak class and cancels it three
-- days out has still burned the slot — the allowance would be two peak
-- BOOKINGS a week rather than two peak CLASSES, and members would learn not to
-- book until the last minute, which is the exact opposite of what a studio
-- wants from a schedule.
--
-- THE ALLOWANCE MIRRORS THE CREDIT, and that is the argument. A credit comes
-- back on a timely cancellation and is taken on a late one, per
-- `late_cancel_consumes_credit`. The whole reason the allowance exists is that
-- an unlimited plan has no credit to take — so it has to behave like the thing
-- it stands in for, or the same act costs two different members two different
-- amounts. `cancellation_cutoff_minutes` decides which side a cancellation
-- falls on, and there is still exactly one such deadline.
--
-- The comment in that trigger is corrected below rather than left to mislead
-- the next reader.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- LEDGER-SHAPED, LIKE CREDITS, AND FOR THE SAME REASON.
--
-- A decrement cannot be re-run. Every sweep, every retry and every trigger in
-- this codebase has to be safe to fire twice, so restoration is a REVERSING ROW
-- keyed on the booking rather than a number going back up: the unique index on
-- (booking_id, reason) means a second attempt inserts nothing and the balance
-- is unchanged. `credit_ledger` has had exactly this shape since migration 001.
--
-- CLASS CREDITS AND PEAK ALLOWANCE ARE INDEPENDENT. A plan that has one cannot
-- have the other (104's CHECK), so no booking ever writes to both ledgers, and
-- nothing has to decide which of the two a cancellation should refund.
--
-- `period_start` and `period_end` are STORED rather than recomputed. The period
-- a row belongs to is decided once, when the row is written, by the one
-- function that knows the studio's week start — so a studio that later changes
-- `week_starts_on` cannot silently re-file last month's bookings into different
-- weeks and change a balance that was already spent against.
-- -----------------------------------------------------------------------------
create table if not exists peak_allowance_ledger (
  id             uuid primary key default gen_random_uuid(),
  studio_id      uuid not null references studios(id) on delete cascade,
  member_id      uuid not null references members(id) on delete cascade,
  membership_id  uuid not null references memberships(id) on delete cascade,
  booking_id     uuid not null references bookings(id) on delete cascade,
  delta          int  not null check (delta in (-1, 1)),
  -- Only the three that have a writer. A value with no writer is a column with
  -- a schema and nothing filling it, which is this project's most repeated bug;
  -- 'staff_excused' and 'marked_present' arrive with the migration that writes
  -- them.
  reason         text not null check (reason in ('booked', 'member_cancelled', 'studio_released')),
  period_start   date not null,
  period_end     date not null,
  actor_user_id  uuid,
  created_at     timestamptz not null default now(),
  is_demo        boolean not null default false
);

-- The idempotency. A consume and each kind of restore are one row each per
-- booking, so any writer may fire twice and the second does nothing.
create unique index if not exists peak_allowance_ledger_once
  on peak_allowance_ledger (booking_id, reason);
create index if not exists peak_allowance_ledger_period
  on peak_allowance_ledger (membership_id, period_start);

alter table peak_allowance_ledger enable row level security;

-- A member reads their own, which is what the "2 of 2 peak classes left" line
-- in the app is. Staff read their studio's. Nobody writes it by hand: every row
-- comes from the trigger below.
drop policy if exists peak_ledger_self_read on peak_allowance_ledger;
create policy peak_ledger_self_read on peak_allowance_ledger
  -- The same shape as credit_ledger's own `credit_self`, which is the policy
  -- this table is modelled on throughout.
  for select using (member_id in (select id from members where user_id = auth.uid()));

drop policy if exists peak_ledger_staff_read on peak_allowance_ledger;
create policy peak_ledger_staff_read on peak_allowance_ledger
  for select using (is_desk_up(studio_id));

grant select on peak_allowance_ledger to authenticated;
grant all on peak_allowance_ledger to service_role;

-- -----------------------------------------------------------------------------
-- HOW MUCH IS LEFT. One definition, and the gate, the trigger and the member's
-- own screen all ask it.
--
-- Returns NULL — not zero, not a shape full of nulls — when this plan has no
-- allowance or the studio does not use peak hours. Null is "this does not apply
-- to you", which is what a screen needs in order to draw nothing at all, and
-- what the booking gate needs in order to skip the rule in one test.
--
-- THE PERIOD IS KEYED ON THE CLASS'S OWN DATE, never on today. A member booking
-- next Tuesday's peak class is spending next week's allowance; keying on today
-- would mean booking a fortnight of classes on a Monday exhausted one week and
-- left the others untouched.
--
-- A WEEK IS A FIXED WEEK from the studio's `week_starts_on`, never a rolling
-- 168 hours. `studio_week_start()` has resolved that since migration 067 and is
-- the only thing here that knows which day a week begins on.
-- -----------------------------------------------------------------------------
create or replace function peak_allowance_state(p_membership_id uuid, p_for_date date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  ms memberships%rowtype;
  pl membership_plans%rowtype;
  v_start date; v_end date; v_sum int;
begin
  select * into ms from memberships where id = p_membership_id;
  if not found then
    raise exception 'no such membership' using errcode = 'PT404';
  end if;

  -- Guarded, because this is SECURITY DEFINER and takes an id that returns
  -- tenant data (migration 056). The member themselves, staff of that studio,
  -- or the backend.
  if not (
       exists (select 1 from members m
                where m.id = ms.member_id and m.user_id = auth.uid())
    or coalesce(is_desk_up(ms.studio_id), false)
    or is_service_context()
  ) then
    raise exception 'that membership is not yours' using errcode = 'PT403';
  end if;

  select * into pl from membership_plans where id = ms.plan_id;
  if pl.peak_allowance is null then
    return null;
  end if;
  if not coalesce((select ss.peak_allowance_enabled from studio_settings ss
                    where ss.studio_id = ms.studio_id), false) then
    return null;
  end if;

  if pl.peak_allowance_period = 'month' then
    v_start := date_trunc('month', p_for_date)::date;
    v_end   := (date_trunc('month', p_for_date) + interval '1 month - 1 day')::date;
  else
    v_start := studio_week_start(ms.studio_id, p_for_date);
    v_end   := v_start + 6;
  end if;

  -- Consumption is -1 and restoration is +1, so the sum IS the movement and
  -- remaining is the allowance plus it. Nothing is stored as a balance.
  select coalesce(sum(delta), 0) into v_sum
    from peak_allowance_ledger
   where membership_id = p_membership_id
     and period_start  = v_start;

  return jsonb_build_object(
    'allowance',    pl.peak_allowance,
    'period',       pl.peak_allowance_period,
    'period_start', v_start,
    'period_end',   v_end,
    'used',         -v_sum,
    -- Floored for display; the gate tests <= 0, so an override that took
    -- somebody past their allowance still refuses the next one.
    'remaining',    greatest(pl.peak_allowance + v_sum, 0),
    'over',         pl.peak_allowance + v_sum < 0);
end $$;

-- -----------------------------------------------------------------------------
-- THE ACCOUNTING, AS A TRIGGER, because a booking's status is changed from more
-- places than anybody will remember.
--
-- `book_class()` inserts one, `respond_to_offer()` promotes one by inserting a
-- new one, a Stripe confirmation moves one from `pending_payment`, the desk
-- marks attendance, the drop-in sweep cancels one, `cancel_occurrence()`
-- cancels every seat in the room, and a hand-written UPDATE does whatever it
-- likes. The seam that already catches all of those is the pair of triggers on
-- `bookings`, and this joins them.
--
-- AFTER, not BEFORE. `tg_stamp_booking_release()` is BEFORE UPDATE OF status
-- because it MODIFIES the row it is stamping; this one writes to another table,
-- and a BEFORE trigger that does that has written it even if a later BEFORE
-- trigger returns null and cancels the update. The two existing consequence
-- triggers on this table — notifications and the timeline — are both AFTER for
-- the same reason.
--
-- CONSUMED WHEN THE SEAT BECOMES REAL, never when it is held or queued.
-- `pending_payment` is deliberately not counted, exactly as it is deliberately
-- not counted toward the daily and forward limits: three abandoned checkouts
-- must not exhaust a week's peak allowance on classes nobody paid for. Nor is
-- `waitlisted` — a queue position is not a seat.
-- -----------------------------------------------------------------------------
create or replace function tg_peak_allowance()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_tz    text;
  v_state jsonb;
  v_local date;
begin
  -- Only a booking a MEMBERSHIP is paying for can consume an allowance. A
  -- drop-in and a pack cannot carry one at all.
  if new.membership_id is null then
    return null;
  end if;

  -- --- consume -------------------------------------------------------------
  if new.status = 'booked'
     and (tg_op = 'INSERT' or old.status is distinct from 'booked')
  then
    if not occurrence_is_peak(new.occurrence_id) then
      return null;
    end if;

    select s.timezone into v_tz
      from class_occurrences o join studios s on s.id = o.studio_id
     where o.id = new.occurrence_id;
    select (o.starts_at at time zone v_tz)::date into v_local
      from class_occurrences o where o.id = new.occurrence_id;

    v_state := peak_allowance_state(new.membership_id, v_local);
    if v_state is null then
      return null;
    end if;

    insert into peak_allowance_ledger (
      studio_id, member_id, membership_id, booking_id, delta, reason,
      period_start, period_end, actor_user_id, is_demo)
    values (
      new.studio_id, new.member_id, new.membership_id, new.id, -1, 'booked',
      (v_state ->> 'period_start')::date, (v_state ->> 'period_end')::date,
      auth.uid(), coalesce(new.is_demo, false))
    on conflict (booking_id, reason) do nothing;

    return null;
  end if;

  -- --- restore -------------------------------------------------------------
  -- `cancelled` and NOT `late_cancelled`, which is a status of its own: a late
  -- cancellation keeps the slot spent, which is the entire penalty this feature
  -- exists to impose. `release_reason` is stamped by the BEFORE trigger, so by
  -- the time this runs it is decided.
  if tg_op = 'UPDATE'
     and new.status = 'cancelled'
     and old.status is distinct from new.status
     and new.release_reason in ('member_cancelled', 'studio_released')
  then
    -- Only if something was actually consumed for this booking. A waitlisted
    -- row being cancelled — which is what `respond_to_offer()` does to make way
    -- for the real booking — never consumed anything, and a +1 there would
    -- hand out an allowance nobody spent.
    insert into peak_allowance_ledger (
      studio_id, member_id, membership_id, booking_id, delta, reason,
      period_start, period_end, actor_user_id, is_demo)
    select l.studio_id, l.member_id, l.membership_id, l.booking_id, 1,
           new.release_reason::text, l.period_start, l.period_end,
           auth.uid(), l.is_demo
      from peak_allowance_ledger l
     where l.booking_id = new.id and l.reason = 'booked'
    on conflict (booking_id, reason) do nothing;
  end if;

  return null;
end $$;

drop trigger if exists bookings_peak_allowance on bookings;
create trigger bookings_peak_allowance
  after insert or update of status on bookings
  for each row execute function tg_peak_allowance();

-- -----------------------------------------------------------------------------
-- The seam's own comment, corrected. It said the allowance went here and that it
-- went here for 'studio_released' only; neither turned out to be true, and a
-- comment that points the next reader at the wrong file is worse than none.
-- Replaced with `create or replace`, so the trigger's ACL is untouched.
-- -----------------------------------------------------------------------------
create or replace function tg_stamp_booking_release()
returns trigger
language plpgsql set search_path = public as $$
begin
  if new.status in ('cancelled', 'late_cancelled')
     and old.status is distinct from new.status
     and new.release_reason is null then
    new.release_reason := case
      when coalesce(current_setting('studiior.releasing', true), '') = '1'
        then 'studio_released'::booking_release_reason
      when coalesce(new.is_late_cancel, false)
        then 'late_cancelled'::booking_release_reason
      else 'member_cancelled'::booking_release_reason
    end;

    -- This decides WHY a booking was released and nothing else, which is what
    -- the original note here meant by "nothing else in the codebase should
    -- learn how to decide what the studio owes".
    --
    -- The CONSEQUENCE lives in tg_peak_allowance(), an AFTER trigger on this
    -- same table that reads the value stamped above. It could not live here:
    -- this is a BEFORE trigger, and a BEFORE trigger that writes to another
    -- table has written it even when a later one cancels the update.
    --
    -- And it is NOT "for studio_released only", as this note used to say. A
    -- TIMELY member cancellation restores the allowance too, because the
    -- allowance stands in for the class credit that an unlimited plan does not
    -- have, and a credit comes back on a timely cancellation. `late_cancelled`
    -- is the one that keeps the slot spent.
  end if;
  return new;
end $$;
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
  v_peak         jsonb;             -- Decision 24: the paying plan's peak allowance, or null
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
end $function$;

revoke execute on function peak_allowance_state(uuid, date) from public, anon;
grant  execute on function peak_allowance_state(uuid, date) to authenticated, service_role;
revoke execute on function tg_peak_allowance() from public, anon, authenticated;

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure::text as sig,
           has_function_privilege('anon', p.oid, 'execute') as anon,
           has_function_privilege('authenticated', p.oid, 'execute') as authed
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('peak_allowance_state', 'tg_peak_allowance')
  loop
    if r.anon then raise exception 'migration 106: % is reachable by anon', r.sig; end if;
    if r.authed and r.sig not like 'peak_allowance_state(%' then
      raise exception 'migration 106: % is reachable by authenticated', r.sig;
    end if;
  end loop;
end $$;
