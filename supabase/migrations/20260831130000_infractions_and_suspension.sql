-- =============================================================================
-- 108 — Decision 24's third switch: infractions and the suspension ladder.
--
-- Independent of the other two. A studio may cap places, limit peak hours, and
-- never suspend anybody; `suspension_enabled` defaults false and nothing below
-- is reachable until it is on.
--
-- -----------------------------------------------------------------------------
-- A SUSPENSION IS DERIVED, NEVER STORED, AND THAT IS THE WHOLE DESIGN.
--
-- The brief names one edge as the most likely to be got wrong: marking a member
-- present after a no-show has to void the infraction AND RECALCULATE any
-- suspension it triggered. Every version of that sentence that stores a
-- suspension needs a recalculation step, and a recalculation step that is
-- forgotten in one of the four places an infraction can be voided is a member
-- locked out for a fortnight over a class they attended.
--
-- So nothing stores it. `member_suspension()` reads the live set of ACTIVE
-- infractions inside the rolling window and computes the answer every time.
-- Voiding an infraction does not recalculate anything; it removes a row from a
-- set, and the next read of that set is already right. This is the same reason
-- `ENDED IS DERIVED` on a series and the action centre has no `tasks` table: a
-- stored flag that needs a clock to stay true is a flag that will be wrong.
--
-- -----------------------------------------------------------------------------
-- NOTHING IN THIS PRODUCT HAS EVER WRITTEN A NO-SHOW.
--
-- `booking_status` has carried `no_show` since migration 001 and `member_health`,
-- `dashboard_kpis`, the roster and the pay ladder all READ it — but the only
-- writers anywhere are `generate_demo_data()` and the seed. A class runs, and
-- whoever did not come is still `booked` for ever.
--
-- So half of "infractions are late cancels AND no-shows" would have been a
-- branch that could never fire — this project's most repeated bug, in the one
-- place where it decides whether a real member is locked out. `sweep_no_shows()`
-- gives it a writer, and is GATED ON THIS FEATURE'S OWN SWITCH: a studio that
-- has not turned suspension on gets no no-show marking and behaves exactly as it
-- does today. That gate is deliberate and it is a trade — it means the health
-- score and the dashboard see no-shows only at studios using suspension — and it
-- is the narrower change. Marking every studio's absentees is a decision about
-- member records, not about Decision 24, and it is not this migration's to make.
-- =============================================================================

alter table studio_settings
  add column if not exists suspension_enabled     boolean not null default false,
  -- Rolling, and a window rather than "this month": a member with two in late
  -- January and one in early February has three in a row, and a calendar
  -- boundary would forgive that.
  add column if not exists suspension_window_days int not null default 30,
  add column if not exists suspension_warn_at     int not null default 2,
  add column if not exists suspension_at          int not null default 3,
  add column if not exists suspension_days        int not null default 14,
  add column if not exists suspension_repeat_days int not null default 30;

comment on column studio_settings.suspension_enabled is
  'Decision 24: whether repeated late cancellations and no-shows suspend advance booking. Off by default.';
comment on column studio_settings.suspension_warn_at is
  'The nth infraction inside the window that warns. Below the suspension threshold, deliberately.';
comment on column studio_settings.suspension_at is
  'The nth infraction inside the window that suspends advance booking.';

alter table studio_settings
  drop constraint if exists suspension_ladder_sane;
alter table studio_settings
  add constraint suspension_ladder_sane check (
    suspension_window_days between 1 and 365
    and suspension_warn_at >= 1
    and suspension_at > suspension_warn_at
    and suspension_days between 1 and 365
    and suspension_repeat_days between 1 and 365
  );

-- -----------------------------------------------------------------------------
-- THE INFRACTION ITSELF.
--
-- One row per booking, keyed on it, so the same late cancellation cannot be
-- counted twice however many times a status is rewritten.
--
-- VOIDED, NEVER DELETED. The excuse RATE is the signal that a cap is set too
-- tight or that a studio is quietly not enforcing its own rule, and deleting the
-- rows makes that number impossible to compute. A voided row keeps who excused
-- it, when, and why.
-- -----------------------------------------------------------------------------
create table if not exists member_infractions (
  id             uuid primary key default gen_random_uuid(),
  studio_id      uuid not null references studios(id) on delete cascade,
  member_id      uuid not null references members(id) on delete cascade,
  booking_id     uuid not null references bookings(id) on delete cascade,
  occurrence_id  uuid references class_occurrences(id) on delete set null,
  kind           text not null check (kind in ('late_cancel', 'no_show')),
  -- The class's own start, not when the row was written: a sweep that runs at
  -- 03:00 must not date last night's absence to this morning, and the rolling
  -- window is measured against this.
  occurred_at    timestamptz not null,
  status         text not null default 'active' check (status in ('active', 'voided')),
  voided_at      timestamptz,
  voided_by      uuid,
  voided_reason  text,
  created_at     timestamptz not null default now(),
  is_demo        boolean not null default false,
  constraint infraction_voided_has_a_reason check (
    status = 'active' or (voided_at is not null and voided_reason is not null))
);

create unique index if not exists member_infractions_one_per_booking
  on member_infractions (booking_id);
create index if not exists member_infractions_member_window
  on member_infractions (member_id, occurred_at) where status = 'active';

alter table member_infractions enable row level security;

drop policy if exists infractions_self_read on member_infractions;
create policy infractions_self_read on member_infractions
  for select using (member_id in (select id from members where user_id = auth.uid()));
drop policy if exists infractions_desk_read on member_infractions;
create policy infractions_desk_read on member_infractions
  for select using (is_desk_up(studio_id));

-- No client writes it by hand: every row comes from the trigger, and every void
-- goes through excuse_infraction() so the audit row cannot be skipped.
grant select on member_infractions to authenticated;
grant all on member_infractions to service_role;

-- -----------------------------------------------------------------------------
-- Recorded by a trigger, beside the other two consequence triggers on
-- `bookings`, and for the same reason: a booking's status is changed from more
-- places than anybody will remember.
--
-- A LATE CANCELLATION AND A NO-SHOW ARE ONE THING WITH TWO NAMES. Both are the
-- member failing to release a seat in time; they differ only in whether they
-- told you. They are counted together and shown apart.
--
-- Gated on the studio's switch AT WRITE TIME, so a studio that has never turned
-- suspension on accumulates no rows at all rather than a hidden history that
-- would suspend half its members the day somebody flips it.
-- -----------------------------------------------------------------------------
create or replace function tg_record_infraction()
returns trigger
language plpgsql security definer set search_path = public as $$
declare v_starts timestamptz;
begin
  if new.status not in ('late_cancelled', 'no_show')
     or old.status is not distinct from new.status then
    return null;
  end if;
  if not coalesce((select ss.suspension_enabled from studio_settings ss
                    where ss.studio_id = new.studio_id), false) then
    return null;
  end if;

  select o.starts_at into v_starts
    from class_occurrences o where o.id = new.occurrence_id;

  insert into member_infractions (
    studio_id, member_id, booking_id, occurrence_id, kind, occurred_at, is_demo)
  values (
    new.studio_id, new.member_id, new.id, new.occurrence_id,
    case when new.status = 'late_cancelled' then 'late_cancel' else 'no_show' end,
    coalesce(v_starts, now()), coalesce(new.is_demo, false))
  on conflict (booking_id) do nothing;

  return null;
end $$;

drop trigger if exists bookings_record_infraction on bookings;
create trigger bookings_record_infraction
  after update of status on bookings
  for each row execute function tg_record_infraction();

-- -----------------------------------------------------------------------------
-- WHERE A MEMBER STANDS. Computed, every time, from the rows that are live now.
--
-- Null when the studio does not use suspension, so a screen draws nothing at
-- all rather than "0 infractions" against every member in a studio that has
-- never heard of the feature.
--
-- THE LADDER: inside the window, the nth infraction warns and the mth suspends
-- advance booking. Each one past the mth suspends again from its OWN date, so a
-- member who keeps going does not serve one sentence for all of it.
-- -----------------------------------------------------------------------------
create or replace function member_suspension(p_member_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_studio uuid;
  st       studio_settings%rowtype;
  v_until  timestamptz;
  v_count  int;
  r        record;
  i        int := 0;
begin
  select studio_id into v_studio from members where id = p_member_id;
  if v_studio is null then
    raise exception 'no such member' using errcode = 'PT404';
  end if;
  if not (
       exists (select 1 from members m where m.id = p_member_id and m.user_id = auth.uid())
    or coalesce(is_desk_up(v_studio), false)
    or is_service_context()
  ) then
    raise exception 'that member is not yours' using errcode = 'PT403';
  end if;

  select * into st from studio_settings where studio_id = v_studio;
  if not coalesce(st.suspension_enabled, false) then
    return null;
  end if;

  for r in
    select occurred_at from member_infractions
     where member_id = p_member_id and status = 'active'
       and occurred_at > now() - make_interval(days => st.suspension_window_days)
     order by occurred_at
  loop
    i := i + 1;
    if i = st.suspension_at then
      v_until := greatest(coalesce(v_until, r.occurred_at),
                          r.occurred_at + make_interval(days => st.suspension_days));
    elsif i > st.suspension_at then
      v_until := greatest(coalesce(v_until, r.occurred_at),
                          r.occurred_at + make_interval(days => st.suspension_repeat_days));
    end if;
  end loop;
  v_count := i;

  return jsonb_build_object(
    'count',        v_count,
    'window_days',  st.suspension_window_days,
    'warn_at',      st.suspension_warn_at,
    'suspend_at',   st.suspension_at,
    'warned',       v_count >= st.suspension_warn_at and v_count < st.suspension_at,
    'suspended',    v_until is not null and v_until > now(),
    'until',        case when v_until > now() then v_until end,
    -- How many more before something happens. Null once it has.
    'until_warning', case when v_count < st.suspension_warn_at
                          then st.suspension_warn_at - v_count end,
    'until_suspension', case when v_count < st.suspension_at
                             then st.suspension_at - v_count end);
end $$;

-- -----------------------------------------------------------------------------
-- The ledger learns one more reason, now that something writes it.
-- 'marked_present' is deliberately still absent — see mark_present() below.
-- -----------------------------------------------------------------------------
alter table peak_allowance_ledger
  drop constraint if exists peak_allowance_ledger_reason_check;
alter table peak_allowance_ledger
  add constraint peak_allowance_ledger_reason_check
    check (reason in ('booked', 'member_cancelled', 'studio_released', 'staff_excused'));

-- -----------------------------------------------------------------------------
-- EXCUSING ONE. Front desk and up — §9 puts the desk at the counter hearing the
-- reason, and a rule only a manager can bend is one the desk works around by
-- not enforcing it.
--
-- Three things happen and they are one transaction: the infraction is VOIDED
-- (never deleted, so the excuse rate stays countable), the peak allowance is
-- given back if that booking spent one, and an audit row records who did it and
-- why. The suspension needs no recalculation because nothing stores it.
--
-- A LATE CANCELLATION EXCUSED BECOMES A TIMELY ONE, which is what excusing
-- means: the slot comes back. A no-show excused does the same — they told the
-- studio afterwards and the studio accepted it.
-- -----------------------------------------------------------------------------
create or replace function excuse_infraction(p_infraction_id uuid, p_reason text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  inf member_infractions%rowtype;
  v_restored boolean := false;
begin
  select * into inf from member_infractions where id = p_infraction_id;
  if not found then
    raise exception 'no such infraction' using errcode = 'PT404';
  end if;
  if not coalesce(is_desk_up(inf.studio_id), false) then
    raise exception 'only staff can excuse an infraction' using errcode = 'PT403';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    -- "Excused" with no note is a refusal to say why, and the excuse rate is
    -- only worth measuring if each one can be read.
    raise exception 'say why it is being excused' using errcode = 'PT400';
  end if;
  if inf.status = 'voided' then
    raise exception 'that one has already been excused' using errcode = 'PT409';
  end if;

  update member_infractions
     set status = 'voided', voided_at = now(),
         voided_by = auth.uid(), voided_reason = btrim(p_reason)
   where id = p_infraction_id;

  -- The allowance, if that booking ever spent one. Keyed on the booking and
  -- idempotent, like every other row in this ledger.
  insert into peak_allowance_ledger (
    studio_id, member_id, membership_id, booking_id, delta, reason,
    period_start, period_end, actor_user_id, is_demo)
  select l.studio_id, l.member_id, l.membership_id, l.booking_id, 1, 'staff_excused',
         l.period_start, l.period_end, auth.uid(), l.is_demo
    from peak_allowance_ledger l
   where l.booking_id = inf.booking_id and l.reason = 'booked'
     and not exists (select 1 from peak_allowance_ledger x
                      where x.booking_id = inf.booking_id and x.delta = 1)
  on conflict (booking_id, reason) do nothing;
  get diagnostics v_restored = row_count;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id,
                          before, after)
  values (inf.studio_id, auth.uid(), 'infraction.excused', 'member_infractions',
          p_infraction_id,
          jsonb_build_object('status', 'active', 'kind', inf.kind,
                             'member_id', inf.member_id, 'occurred_at', inf.occurred_at),
          jsonb_build_object('status', 'voided', 'reason', btrim(p_reason),
                             'allowance_restored', v_restored));

  return jsonb_build_object('ok', true, 'allowance_restored', v_restored,
                            'suspension', member_suspension(inf.member_id));
end $$;

-- -----------------------------------------------------------------------------
-- MARKING SOMEBODY PRESENT AFTER A NO-SHOW.
--
-- The brief calls this the edge most likely to be got wrong, and says it
-- restores the allowance, voids the infraction and recalculates the suspension.
-- Two of those three are right and the first is not, once the allowance is
-- consumed at BOOKING rather than at attendance:
--
--   THE ALLOWANCE STAYS SPENT, BECAUSE THEY ATTENDED. They booked a peak class
--   and they were in the room. Giving the slot back would hand a free peak
--   class to everybody the desk corrected, and would mean a member is better
--   off being marked absent and put right than being checked in properly.
--
-- The infraction is voided — there was no infraction, the record was wrong —
-- and the suspension needs no recalculation because nothing stores it.
-- -----------------------------------------------------------------------------
create or replace function mark_present(p_booking_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype; v_voided int := 0;
begin
  select * into b from bookings where id = p_booking_id;
  if not found then
    raise exception 'no such booking' using errcode = 'PT404';
  end if;
  if not coalesce(is_desk_up(b.studio_id), false) then
    raise exception 'only staff can correct attendance' using errcode = 'PT403';
  end if;
  if b.status <> 'no_show' then
    raise exception 'that booking is not marked as a no-show' using errcode = 'PT409';
  end if;

  update bookings set status = 'attended' where id = p_booking_id;

  update member_infractions
     set status = 'voided', voided_at = now(), voided_by = auth.uid(),
         voided_reason = 'Marked present — they were here'
   where booking_id = p_booking_id and status = 'active';
  get diagnostics v_voided = row_count;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id,
                          before, after)
  values (b.studio_id, auth.uid(), 'booking.marked_present', 'bookings', p_booking_id,
          jsonb_build_object('status', 'no_show'),
          jsonb_build_object('status', 'attended', 'infractions_voided', v_voided));

  return jsonb_build_object('ok', true, 'infractions_voided', v_voided,
                            'suspension', member_suspension(b.member_id));
end $$;

-- -----------------------------------------------------------------------------
-- WHAT MAKES A NO-SHOW EXIST AT ALL.
--
-- A class that has finished, a booking still sitting at 'booked', and nobody
-- checked in: that is somebody who did not come. Swept rather than clicked,
-- because a studio will not remember to mark absentees and a feature that
-- depends on them remembering is one that quietly stops working.
--
-- GATED ON THE SWITCH, per the header. A studio with suspension off gets none of
-- this and its bookings stay exactly as they are today.
--
-- Only classes that have actually ENDED, and only back as far as the rolling
-- window, so turning the feature on does not reach into a year of history and
-- suspend half the studio on day one.
-- -----------------------------------------------------------------------------
create or replace function sweep_no_shows()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_marked int := 0;
begin
  if not is_service_context() then
    raise exception 'the no-show sweep is a background job' using errcode = 'PT403';
  end if;

  with due as (
    select b.id
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
      join studio_settings ss  on ss.studio_id = b.studio_id
     where b.status = 'booked'
       and ss.suspension_enabled
       and o.status = 'scheduled'
       and o.ends_at < now() - interval '1 hour'
       and o.ends_at > now() - make_interval(days => ss.suspension_window_days)
       and not exists (select 1 from check_ins c where c.booking_id = b.id)
  )
  update bookings set status = 'no_show'
   where id in (select id from due);
  get diagnostics v_marked = row_count;

  -- Records the pass and counts attempts; it does not gate it. The idempotency
  -- is each booking's own status — a row already marked `no_show` is not
  -- selected again — which is what makes a nightly run safe to repeat.
  insert into job_runs (job_key, run_for, status, finished_at)
  values ('no_shows', current_date, 'done', now())
  on conflict (job_key, run_for) do update
     set attempts = job_runs.attempts + 1, started_at = now(),
         status = 'done', finished_at = now();

  return jsonb_build_object('marked', v_marked);
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
  v_susp         jsonb;             -- Decision 24: where this member stands on the ladder
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

-- The sweep runs after the studio day is well over anywhere. Hourly rather than
-- daily for the reason the flex sweep is: studios span timezones, and a class
-- that ended an hour ago in Manila ended an hour ago whatever the server's date
-- happens to be.
select cron.schedule('studiior-no-shows', '25 * * * *',
                     $$ select sweep_no_shows(); $$);

revoke execute on function tg_record_infraction() from public, anon, authenticated;
revoke execute on function sweep_no_shows() from public, anon, authenticated;
grant  execute on function sweep_no_shows() to service_role;
revoke execute on function member_suspension(uuid) from public, anon;
grant  execute on function member_suspension(uuid) to authenticated, service_role;
revoke execute on function excuse_infraction(uuid, text) from public, anon;
grant  execute on function excuse_infraction(uuid, text) to authenticated, service_role;
revoke execute on function mark_present(uuid) from public, anon;
grant  execute on function mark_present(uuid) to authenticated, service_role;

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure::text as sig,
           has_function_privilege('anon', p.oid, 'execute') as anon,
           has_function_privilege('authenticated', p.oid, 'execute') as authed
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('tg_record_infraction', 'sweep_no_shows', 'member_suspension',
                         'excuse_infraction', 'mark_present')
  loop
    if r.anon then raise exception 'migration 108: % is reachable by anon', r.sig; end if;
    if r.authed and r.sig ~ '^(tg_record_infraction|sweep_no_shows)\(' then
      raise exception 'migration 108: % is reachable by authenticated', r.sig;
    end if;
  end loop;
end $$;
