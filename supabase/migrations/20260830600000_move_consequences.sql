-- =============================================================================
-- Migration 050: what a move costs, and what a studio owes the member
-- =============================================================================
-- Three things, all consequences of the calendar existing.
--
-- 1. THE INSTRUCTOR CONSTRAINT BECOMES DEFERRABLE.
--
--    The substitution carve-out asked for turns out to be unnecessary:
--    substitute_for is historical and instructor_id IS the effective teaching
--    instructor, so a class being subbed already stops counting against the
--    original. Subbing Bo in is refused only when Bo genuinely cannot be in two
--    places, which is right.
--
--    What IS blocked is a SWAP: exchanging two instructors between two
--    simultaneous classes has a perfectly valid end state and is refused
--    statement by statement on the way there. DEFERRABLE INITIALLY IMMEDIATE
--    fixes that without weakening anything — the database still refuses to
--    COMMIT a state where one person teaches two classes at once. It only
--    tolerates that state transiently inside one transaction that asked for it.
--
--    The room constraint is left immediate, as instructed. Note that room swaps
--    have exactly the same friction and that deferring would not weaken them
--    either; that is a decision to take separately.
--
-- 2. A SIGNIFICANT MOVE OWES THE MEMBER A FREE CANCELLATION.
--
--    Decision 2's reasoning: someone who agreed to Tuesday 7am and now has
--    Tuesday 6pm has had the thing they agreed to changed, not delayed. This
--    also finally implements studio_settings.sub_late_free_cancel, which has
--    been declared since migration 001 and read by nothing.
--
-- 3. AN UNSTAFFED CLASS HAS A DEADLINE.
--    A class members can book that nobody has agreed to teach is a promise the
--    studio may not keep. The threshold is theirs to set.
-- =============================================================================

alter table class_occurrences drop constraint if exists occ_instructor_no_overlap;
alter table class_occurrences add constraint occ_instructor_no_overlap
  exclude using gist (
    instructor_id extensions.gist_uuid_ops with =,
    tstzrange(starts_at, ends_at) with &&
  ) where (instructor_id is not null and status <> 'cancelled')
  deferrable initially immediate;

alter table studio_settings
  add column if not exists significant_move_hours int not null default 2,
  add column if not exists unstaffed_deadline_hours int not null default 48;

alter table studio_settings drop constraint if exists studio_settings_move_ranges;
alter table studio_settings add constraint studio_settings_move_ranges check (
  significant_move_hours between 0 and 72
  and unstaffed_deadline_hours between 1 and 336
);

comment on column studio_settings.significant_move_hours is
  'A move further than this, or onto a different day in studio time, is '
  '"significant" and gives every booked member a penalty-free cancellation. '
  'Zero means any move at all counts.';
comment on column studio_settings.unstaffed_deadline_hours is
  'How long before a class starts it must have an instructor. Past this with '
  'nobody assigned, the Morning Brief raises it.';

-- A per-booking grant, because the reason is per booking: this member's class
-- moved. Honoured by cancel_booking() below, which is the only thing that
-- decides whether a cancellation costs a credit.
alter table bookings
  add column if not exists free_cancel_until timestamptz;

comment on column bookings.free_cancel_until is
  'Until when this member may cancel without it counting as late, whatever the '
  'studio''s cutoff. Set when their class is moved significantly, and by '
  'Decision 2''s substitution rule. Never set by the member.';

-- -----------------------------------------------------------------------------
-- Swapping two instructors, atomically
-- -----------------------------------------------------------------------------
create or replace function swap_instructors(p_occurrence_a uuid, p_occurrence_b uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare a class_occurrences%rowtype; b class_occurrences%rowtype;
begin
  select * into a from class_occurrences where id = p_occurrence_a for update;
  select * into b from class_occurrences where id = p_occurrence_b for update;
  if a.id is null or b.id is null then
    raise exception 'no such class' using errcode = 'PT404';
  end if;
  if not (is_manager_up(a.studio_id) and is_manager_up(b.studio_id)) then
    raise exception 'only owners and managers change the timetable' using errcode = 'PT403';
  end if;

  -- The whole point of the deferral: for the length of this transaction one
  -- instructor is on both classes, which is nonsense — but it is nonsense that
  -- never reaches COMMIT, and the alternative is that a swap is impossible.
  set constraints occ_instructor_no_overlap deferred;

  update class_occurrences set instructor_id = b.instructor_id, updated_at = now() where id = a.id;
  update class_occurrences set instructor_id = a.instructor_id, updated_at = now() where id = b.id;

  return jsonb_build_object('swapped', true);
end $$;

revoke execute on function swap_instructors(uuid, uuid) from public, anon;
grant execute on function swap_instructors(uuid, uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- move_occurrence: name the obstacle, weigh the move, honour an undo
-- -----------------------------------------------------------------------------
create or replace function public.move_occurrence(p_occurrence_id uuid, p_starts_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_ends_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_instructor_id uuid DEFAULT NULL::uuid, p_room_id uuid DEFAULT NULL::uuid, p_confirm boolean DEFAULT false, p_clear_instructor boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  occ        class_occurrences%rowtype;
  v_starts   timestamptz;
  v_ends     timestamptz;
  v_instr    uuid;
  v_room     uuid;
  v_staffing staffing_state;
  v_warnings text[] := '{}';
  v_set      studio_settings%rowtype;
  v_tz       text;
  v_clash    class_occurrences%rowtype;
  v_significant boolean := false;
  v_undo     boolean := false;
  v_conflict text;
  v_moved    boolean;
begin
  select * into occ from class_occurrences where id = p_occurrence_id for update;
  if not found then
    raise exception 'no such class' using errcode = 'PT404';
  end if;
  if not is_manager_up(occ.studio_id) then
    raise exception 'only owners and managers change the timetable'
      using errcode = 'PT403';
  end if;
  if studio_is_locked(occ.studio_id) then
    raise exception 'this studio''s Studiior subscription is not active'
      using errcode = 'PT402',
            hint = 'Reactivate it from Billing. Nothing has been deleted.';
  end if;
  if occ.status <> 'scheduled' then
    raise exception 'a % class cannot be moved', occ.status using errcode = 'PT409';
  end if;

  v_starts := coalesce(p_starts_at, occ.starts_at);
  v_ends   := coalesce(p_ends_at,   occ.ends_at);
  v_room   := coalesce(p_room_id,   occ.room_id);
  -- p_clear_instructor because a null p_instructor_id has to be able to mean
  -- "leave it alone" as well as "make this an open shift", and one nullable
  -- parameter cannot say both.
  v_instr  := case when p_clear_instructor then null
                   else coalesce(p_instructor_id, occ.instructor_id) end;

  if v_ends <= v_starts then
    raise exception 'a class cannot end before it starts' using errcode = 'PT400';
  end if;

  v_staffing := case when v_instr is null then
                       (case when occ.staffing = 'pending_approval'
                             then 'pending_approval' else 'open' end)
                     else 'assigned' end::staffing_state;

  -- Members are the reason to stop and ask.
  if occ.booked_count > 0 and not p_confirm
     and (v_starts <> occ.starts_at or v_ends <> occ.ends_at
          or v_instr is distinct from occ.instructor_id) then
    return jsonb_build_object(
      'ok', false,
      'requires_confirmation', true,
      'booked_count', occ.booked_count,
      'reason', 'members_booked');
  end if;

  begin
    update class_occurrences
       set starts_at = v_starts, ends_at = v_ends,
           instructor_id = v_instr, room_id = v_room,
           staffing = v_staffing, updated_at = now()
     where id = p_occurrence_id;
  exception when exclusion_violation then
    -- Which of the two, in words a person can act on.
    get stacked diagnostics v_conflict = constraint_name;

    -- "Conflict detected" tells somebody holding a mouse nothing. Find the
    -- class that is actually in the way so the screen can name it and offer to
    -- open it.
    select * into v_clash from class_occurrences o
     where o.id <> p_occurrence_id
       and o.status <> 'cancelled'
       and tstzrange(o.starts_at, o.ends_at) && tstzrange(v_starts, v_ends)
       and ((v_conflict = 'occ_room_no_overlap'       and o.room_id = v_room)
         or (v_conflict = 'occ_instructor_no_overlap' and o.instructor_id = v_instr))
     limit 1;

    select s.timezone into v_tz from studios s where s.id = occ.studio_id;

    return jsonb_build_object(
      'ok', false,
      'requires_confirmation', false,
      'reason', case when v_conflict = 'occ_room_no_overlap'
                     then 'room_busy' else 'instructor_busy' end,
      'conflict', v_conflict,
      'blocked_by', case when v_clash.id is null then null else jsonb_build_object(
        'occurrence_id', v_clash.id,
        'name', v_clash.name,
        'starts_at', v_clash.starts_at,
        'at', to_char(v_clash.starts_at at time zone v_tz, 'HH24:MI'),
        'who', (select i.display_name from instructors i where i.id = v_clash.instructor_id),
        'room', (select rm.name from rooms rm where rm.id = v_clash.room_id)) end);
  end;

  v_moved := v_starts <> occ.starts_at or v_ends <> occ.ends_at;

  -- Everybody who is booked in, told. This is the reason the confirmation step
  -- exists: by the time we are here the caller has said yes to sending it.
  if v_moved and occ.booked_count > 0 then
    select * into v_set from studio_settings where studio_id = occ.studio_id;
    select s.timezone into v_tz from studios s where s.id = occ.studio_id;

    -- Significant: further than the studio's threshold, or landing on a
    -- different day in their own timezone. A class pushed fifteen minutes is a
    -- delay; a class pushed to the evening is a different arrangement.
    v_significant :=
      abs(extract(epoch from v_starts - occ.starts_at)) >
        coalesce(v_set.significant_move_hours, 2) * 3600
      or (v_starts at time zone v_tz)::date <> (occ.starts_at at time zone v_tz)::date;

    -- The undo window. A class that has just been moved and is now going back
    -- where it came from is somebody correcting a mis-drag, and the members
    -- should not hear about either leg of it. The first email has not gone out
    -- yet — the worker runs every minute — so it is withdrawn rather than
    -- apologised for.
    v_undo := exists (
      select 1 from audit_logs al
       where al.entity_id = occ.id
         and al.action = 'occurrence.moved'
         and al.created_at > now() - interval '60 seconds'
         and (al.before ->> 'starts_at')::timestamptz = v_starts);

    -- Any unsent notice about this class is now stale whatever happens next:
    -- it describes a move that has been superseded.
    delete from notifications
     where template_key = 'class_moved'
       and status = 'scheduled'
       and dedupe_key like 'class_moved:' || occ.id || ':%';

    if not v_undo then
      perform queue_class_moved(occ.id, occ.starts_at);

      if v_significant then
        -- Decision 2's reasoning, applied to a move: they agreed to a time and
        -- the time changed. They may cancel without it counting against them,
        -- right up to the class.
        update bookings
           set free_cancel_until = v_ends
         where occurrence_id = occ.id and status = 'booked';
      end if;
    end if;
  end if;

  if v_instr is not null and not instructor_available_at(v_instr, v_starts, v_ends) then
    -- Decision 9: permitted, and said out loud. Never blocked.
    v_warnings := v_warnings || 'outside_availability';
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (occ.studio_id, auth.uid(), 'occurrence.moved', 'class_occurrences', occ.id,
          jsonb_build_object('starts_at', occ.starts_at, 'ends_at', occ.ends_at,
                             'instructor_id', occ.instructor_id, 'room_id', occ.room_id),
          jsonb_build_object('starts_at', v_starts, 'ends_at', v_ends,
                             'instructor_id', v_instr, 'room_id', v_room));

  return jsonb_build_object(
    'ok', true,
    'moved', v_moved,
    'staffing', v_staffing,
    'significant', v_significant,
    'undo', v_undo,
    'booked_count', occ.booked_count,
    'warnings', to_jsonb(v_warnings));
end $function$

;
create or replace function public.cancel_booking(p_booking_id uuid)
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
  if not (v_member.user_id = auth.uid()
          or is_desk_up(b.studio_id)
          or is_service_context()) then
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
end $function$

;

-- -----------------------------------------------------------------------------
-- The brief fires on the studio's staffing deadline, not on a window of days
-- -----------------------------------------------------------------------------
create or replace function public.generate_morning_brief(p_studio_id uuid, p_for_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_tz        text;
  v_cur       text;
  v_date      date;
  v_max       int;
  v_dedupe    int;
  n_kept      int;
  v_summary   text;
  v_ids       uuid[];
  v_brief_id  uuid;
begin
  if not is_manager_up(p_studio_id)
     and not is_platform_admin()
     and not is_service_context() then
    raise exception 'only owners, managers or the scheduler may generate a brief'
      using errcode = 'PT403';
  end if;

  select timezone, currency into v_tz, v_cur from studios where id = p_studio_id;
  if v_tz is null then
    raise exception 'no such studio' using errcode = 'PT404';
  end if;

  v_date   := coalesce(p_for_date, (now() at time zone v_tz)::date);
  v_max    := insight_threshold(p_studio_id, 'max_insights')::int;
  v_dedupe := insight_threshold(p_studio_id, 'dedupe_days')::int;

  -- Dropped first, not merely created. `on commit drop` cleans up at COMMIT,
  -- and the scheduler loops over every due studio inside ONE transaction — so
  -- the second studio hit "relation _cand already exists" and failed, and with
  -- ten design partners nine briefs would fail every morning while the first
  -- one looked fine. Exactly the shape of the generate_demo_data() bug already
  -- in CLAUDE.md, which is why that note says "once per transaction".
  -- Checked rather than DROP IF EXISTS, which emits a NOTICE every time it
  -- finds nothing — ninety-six runs a day of "table _cand does not exist,
  -- skipping" in the cron log is how real messages get missed.
  if to_regclass('pg_temp._cand') is not null then
    drop table _cand;
  end if;
  create temp table _cand (
    type text, severity text, rank int,
    title text, observation text, why_it_matters text, recommended_action text,
    action_type text, action_payload jsonb,
    subject_type text, subject_id uuid,
    estimated_impact_cents int
  ) on commit drop;

  insert into _cand
  select 'retention_risk', 'warning', 2,
         m.first_name || ' ' || m.last_name || ' is drifting',
         m.health_reason,
         'They are still a member and have not decided to leave. The gap is the moment to say something.',
         'Send them a note — the draft is already written.',
         'message_member',
         jsonb_build_object('member_id', m.id,
                            'href', '/members/' || m.id || '/message'),
         'member', m.id,
         coalesce((select ms.price_cents from memberships ms
                    where ms.member_id = m.id
                      and ms.status not in ('cancelled','expired')
                    order by ms.starts_on desc limit 1), 0)
    from members m
   where m.studio_id = p_studio_id
     and m.status = 'active'
     and m.health_band in ('at_risk','drifting')
     and m.health_signals ->> 0 = 'rhythm_deviation';

  insert into _cand
  select 'payment_failed', 'urgent', 1,
         m.first_name || ' ' || m.last_name || ' cannot book',
         'Their membership is past due, so booking is closed to them until it is settled.',
         'This is money already earned and not collected, and they cannot use what they are paying for.',
         'Tell them the card failed and how to fix it.',
         'message_member',
         jsonb_build_object('member_id', m.id,
                            'href', '/members/' || m.id || '/message'),
         'member', m.id,
         ms.price_cents
    from memberships ms
    join members m on m.id = ms.member_id
   where ms.studio_id = p_studio_id
     and ms.status = 'past_due'
     and m.status = 'active';

  insert into _cand
  select 'new_member_stalled', 'warning', 3,
         m.first_name || ' ' || m.last_name || ' has not got going',
         format('Joined %s days ago, %s visit%s, and nothing booked.',
                v_date - m.joined_on, m.lifetime_visits,
                case when m.lifetime_visits = 1 then '' else 's' end),
         'The first month decides whether someone stays. This is the most rescuable member you have.',
         'Ask how they got on and help them pick a class.',
         'message_member',
         jsonb_build_object('member_id', m.id,
                            'href', '/members/' || m.id || '/message'),
         'member', m.id, 0
    from members m
   where m.studio_id = p_studio_id
     and m.status = 'active'
     and v_date - m.joined_on <= insight_threshold(p_studio_id,'stalled_max_days')::int
     and m.lifetime_visits < insight_threshold(p_studio_id,'stalled_max_visits')::int
     and not exists (
       select 1 from bookings b
         join class_occurrences o on o.id = b.occurrence_id
        where b.member_id = m.id
          and b.status in ('booked','waitlisted')
          and o.starts_at between now()
              and now() + make_interval(days => insight_threshold(p_studio_id,'stalled_no_booking_days')::int));

  insert into _cand
  select 'milestone_upcoming', 'info', 5,
         m.first_name || ' ' || m.last_name || ' is one visit from ' || t.target,
         format('%s visits so far. The next one makes %s.', m.lifetime_visits, t.target),
         'Noticing is free and it is the kind of thing people tell their friends about.',
         'Say something when they come in.',
         'celebrate',
         jsonb_build_object('member_id', m.id, 'milestone', t.target,
                            'href', '/members/' || m.id),
         'member', m.id, 0
    from members m
    cross join lateral unnest(milestone_visit_targets()) as t(target)
   where m.studio_id = p_studio_id
     and m.status = 'active'
     and t.target - m.lifetime_visits
         between 1 and insight_threshold(p_studio_id,'milestone_within_visits')::int;

  insert into _cand
  select 'milestone_upcoming', 'info', 5,
         m.first_name || ' ' || m.last_name || ' has an anniversary coming up',
         format('%s years with you on %s.',
                extract(year from age(v_date, m.joined_on))::int + 1,
                to_char(m.joined_on, 'FMDD Month')),
         'A year is worth marking, and nobody else is going to mention it.',
         'Say something when they come in.',
         'celebrate',
         jsonb_build_object('member_id', m.id, 'href', '/members/' || m.id),
         'member', m.id, 0
    from members m
   where m.studio_id = p_studio_id
     and m.status = 'active'
     and m.joined_on < v_date - interval '300 days'
     and ((to_char(m.joined_on, 'MM-DD')::text) in (
            select to_char(v_date + i, 'MM-DD')
              from generate_series(0, insight_threshold(p_studio_id,'milestone_days_ahead')::int) i));

  -- ---- unstaffed_class (Decision 17) ----------------------------------------
  -- §11 lists nine insight types and none of them covers a class with nobody
  -- teaching it. Ranked 1 and 'urgent', above a failed card: a declined card
  -- can be sorted out on Thursday; a 7am class tomorrow with people booked and
  -- no instructor cannot.
  insert into _cand
  select 'unstaffed_class', 'urgent', 1,
         o.name || ' on ' || to_char(o.starts_at at time zone v_tz, 'FMDay') ||
           ' has nobody teaching it',
         case when o.booked_count > 0
              then format('%s member%s booked, and the class is unstaffed.',
                          o.booked_count, case when o.booked_count = 1 then '' else 's' end)
              else 'Published with no instructor, and nobody has picked it up.' end,
         case when o.booked_count > 0
              then 'Members are expecting a class that currently has nobody to run it.'
              else 'It is on the timetable with nobody assigned.' end,
         case when exists (select 1 from shift_applications sa
                            where sa.occurrence_id = o.id and sa.status = 'pending')
              then 'Somebody has applied. Approve them.'
              else 'Assign someone, or leave it open for an instructor to take.' end,
         'open_shift',
         jsonb_build_object('occurrence_id', o.id, 'href', '/schedule?occurrence=' || o.id),
         'occurrence', o.id,
         0
    from class_occurrences o
   where o.studio_id = p_studio_id
     and o.status = 'scheduled'
     and o.staffing <> 'assigned'
     and o.starts_at > now()
     -- The studio's own staffing deadline, in hours, rather than a window of
     -- days invented here. Past it with nobody assigned is precisely the state
     -- the brief exists to surface: a class members can book that nobody has
     -- agreed to teach.
     and o.starts_at < now() + make_interval(hours => coalesce(
           (select st.unstaffed_deadline_hours from studio_settings st
             where st.studio_id = p_studio_id), 48));

  insert into _cand
  select 'class_underfilled', 'info', 4,
         o.name || ' on ' || to_char(o.starts_at at time zone v_tz, 'FMDay') ||
           ' is half empty',
         format('%s of %s booked, against a usual %s%% for this class.',
                o.booked_count, o.capacity, round(h.avg_fill * 100)),
         'A class that normally fills and suddenly does not is worth a look before it runs.',
         'Open the class and see who usually comes.',
         'open_class',
         jsonb_build_object('occurrence_id', o.id, 'href', '/roster/' || o.id),
         'occurrence', o.id,
         (o.capacity - o.booked_count) * coalesce(
           (select price_cents from membership_plans
             where studio_id = p_studio_id and type = 'drop_in' and status = 'active'
             order by price_cents limit 1), 0)
    from class_occurrences o
    join lateral (
      select avg(p.booked_count::numeric / nullif(p.capacity,0)) as avg_fill,
             count(*) as n
        from class_occurrences p
       where p.series_id is not distinct from o.series_id
         and p.studio_id = p_studio_id
         and p.starts_at < now()
         and p.status <> 'cancelled'
    ) h on true
   where o.studio_id = p_studio_id
     and o.status = 'scheduled'
     and o.starts_at between now()
         and now() + make_interval(days => insight_threshold(p_studio_id,'underfilled_window_days')::int)
     and o.capacity > 0
     and o.booked_count::numeric / o.capacity < insight_threshold(p_studio_id,'underfilled_pct')
     and h.n >= insight_threshold(p_studio_id,'underfilled_min_history')::int
     and h.avg_fill > insight_threshold(p_studio_id,'underfilled_series_pct');

  insert into _cand
  select 'class_overfilled', 'info', 4,
         nxt.name || ' has been full for ' ||
           insight_threshold(p_studio_id,'overfilled_weeks')::int || ' weeks',
         format('Averaging %s%% of capacity. People are being turned away.',
                round(w.min_fill * 100)),
         'A class this full is a second class waiting to be scheduled, or a bigger room.',
         'Open it and see the waitlist.',
         'open_class',
         jsonb_build_object('occurrence_id', nxt.id, 'series_id', w.series_id,
                            'href', '/roster/' || nxt.id),
         'occurrence', nxt.id, 0
    from (
      select p.series_id,
             min(wk.fill) as min_fill
        from class_occurrences p
        join lateral (
          select avg(q.booked_count::numeric / nullif(q.capacity,0)) as fill
            from class_occurrences q
           where q.series_id = p.series_id and q.studio_id = p_studio_id
             and q.starts_at >= now() - make_interval(weeks => 1)
             and q.starts_at < now()
        ) wk on true
       where p.studio_id = p_studio_id and p.series_id is not null
       group by p.series_id
    ) w
    join lateral (
      select o.id, o.name from class_occurrences o
       where o.series_id = w.series_id and o.starts_at > now()
         and o.status = 'scheduled'
       order by o.starts_at limit 1
    ) nxt on true
   where w.min_fill >= insight_threshold(p_studio_id,'overfilled_pct');

  if insight_threshold(p_studio_id, 'challenge_enabled') >= 1 then
    insert into _cand
    select 'challenge_opportunity', 'info', 6,
           'Enough members for a challenge',
           format('%s members are coming regularly and none of them is in a challenge.',
                  count(*)),
           'A challenge gives regulars a reason to come more often without discounting anything.',
           'Launch one.',
           'launch_challenge',
           jsonb_build_object('href', '/challenges/new'),
           'studio', p_studio_id, 0
      from members m
     where m.studio_id = p_studio_id and m.status = 'active'
       and m.health_band = 'healthy'
    having count(*) >= insight_threshold(p_studio_id,'challenge_min_members')::int;
  end if;

  delete from _cand c
   where exists (
     select 1 from ai_insights i
      where i.studio_id = p_studio_id
        and i.type = c.type
        and i.subject_id is not distinct from c.subject_id
        and i.status in ('actioned','dismissed')
        and coalesce(i.actioned_at, i.dismissed_at)
            > now() - make_interval(days => v_dedupe));

  delete from _cand a
   using _cand b
   where a.type = b.type
     and a.subject_id is not distinct from b.subject_id
     and a.ctid > b.ctid;

  delete from _cand a
   using _cand b
   where a.subject_id is not distinct from b.subject_id
     and a.subject_id is not null
     and (b.rank < a.rank or (b.rank = a.rank and b.ctid < a.ctid));

  insert into ai_insights
    (studio_id, type, severity, title, observation, why_it_matters,
     recommended_action, action_type, action_payload, subject_type, subject_id,
     estimated_impact_cents, for_date, status)
  select p_studio_id, c.type, c.severity, c.title, c.observation, c.why_it_matters,
         c.recommended_action, c.action_type, c.action_payload, c.subject_type,
         c.subject_id, nullif(c.estimated_impact_cents, 0), v_date, 'new'
    from (
      select * from _cand
       order by rank, estimated_impact_cents desc nulls last, subject_id
       limit v_max
    ) c
  on conflict (studio_id, type, subject_id, for_date) do update
     set title = excluded.title,
         observation = excluded.observation,
         action_payload = excluded.action_payload,
         estimated_impact_cents = excluded.estimated_impact_cents;

  select count(*), array_agg(id order by
           case severity when 'urgent' then 1 when 'warning' then 2 else 3 end,
           estimated_impact_cents desc nulls last)
    into n_kept, v_ids
    from ai_insights
   where studio_id = p_studio_id and for_date = v_date;

  v_summary := brief_summary(p_studio_id, v_date);

  insert into morning_briefs (studio_id, brief_date, summary, metrics, insight_ids)
  values (p_studio_id, v_date, v_summary,
          jsonb_build_object(
            'insight_count', n_kept,
            'candidates_considered', (select count(*) from _cand),
            'money_at_stake_cents', coalesce((
              select sum(estimated_impact_cents) from ai_insights
               where studio_id = p_studio_id and for_date = v_date), 0),
            'currency', v_cur),
          coalesce(v_ids, '{}'))
  on conflict (studio_id, brief_date) do update
     set summary = excluded.summary,
         metrics = excluded.metrics,
         insight_ids = excluded.insight_ids,
         generated_at = now()
  returning id into v_brief_id;

  return jsonb_build_object('brief_id', v_brief_id, 'for_date', v_date,
                            'insights', n_kept, 'summary', v_summary);
end $function$

;
