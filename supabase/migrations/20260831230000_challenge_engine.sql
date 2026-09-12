-- Challenges, part 2: the progress engine — §9, members only.
--
-- Everything here is deterministic and recomputable from
-- challenge_progress_events (§9.4). Progress is never written by a member; it is
-- computed by these SECURITY DEFINER functions and by the check-in trigger, all
-- of which own the RLS the narrowed cp_member_self no longer lets a member walk
-- around.

-- -----------------------------------------------------------------------------
-- One predicate for "does this attendance count toward this challenge".
-- §9.1: the occurrence starts within the challenge's date range (studio-local,
-- because a challenge's dates are wall-calendar dates) and, if the challenge
-- filters by class type, the occurrence's type is in the set. An empty filter
-- means any class — which is what a class_count challenge wants.
-- -----------------------------------------------------------------------------
create function challenge_qualifies(p_challenge_id uuid, p_occurrence_id uuid)
returns boolean
language plpgsql stable security definer set search_path = public as $$
declare c challenges%rowtype; o class_occurrences%rowtype; v_tz text;
begin
  select * into c from challenges where id = p_challenge_id;
  select * into o from class_occurrences where id = p_occurrence_id;
  if c.id is null or o.id is null then return false; end if;
  select timezone into v_tz from studios where id = c.studio_id;

  if o.starts_at < (c.starts_on::timestamp at time zone v_tz)
     or o.starts_at >= ((c.ends_on + 1)::timestamp at time zone v_tz) then
    return false;
  end if;

  if jsonb_array_length(c.class_type_ids) > 0
     and o.class_type_id::text not in (
       select jsonb_array_elements_text(c.class_type_ids)) then
    return false;
  end if;

  return true;
end $$;

-- -----------------------------------------------------------------------------
-- §9.4 ordering, written to `rank` for the whole challenge at once. Higher
-- progress, then earlier completion, then earlier last progress, then earlier
-- join. Fully deterministic.
-- -----------------------------------------------------------------------------
create function rank_challenge(p_challenge_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  with ordered as (
    select id, row_number() over (
             order by progress desc,
                      completed_at asc nulls last,
                      last_progress_at asc nulls last,
                      joined_at asc
           ) as rn
      from challenge_participants
     where challenge_id = p_challenge_id
  )
  update challenge_participants p
     set rank = o.rn
    from ordered o
   where o.id = p.id and p.rank is distinct from o.rn;
end $$;

-- -----------------------------------------------------------------------------
-- Recompute one participant's progress PURELY from their events (§9.4). This is
-- the function the determinism test wipes progress and re-runs: the answer must
-- be identical whether it accreted event by event or was rebuilt in one call.
--
-- class_count / class_type_count: progress is the number of qualifying events
-- (one per booking, so a count). streak: the length of the CURRENT consecutive
-- run of studio-weeks with at least one attended class (§8, §9.5) — a break
-- resets to the current run, so the member sees "3 weeks", never "you failed".
--
-- completed_at is set deterministically: for a count, the time of the goal-th
-- event; for a streak, the latest event's time once the run reaches the goal.
-- Recomputing therefore reproduces both the number AND the ordering key.
-- -----------------------------------------------------------------------------
create function recompute_participant(p_participant_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  p        challenge_participants%rowtype;
  c        challenges%rowtype;
  v_tz     text;
  v_prog   int := 0;
  v_last   timestamptz;
  v_comp   timestamptz;
  v_wk     date;
  v_prev   date := null;
  v_run    int := 0;
begin
  select * into p from challenge_participants where id = p_participant_id;
  if p.id is null then return; end if;
  select * into c from challenges where id = p.challenge_id;
  select timezone into v_tz from studios where id = p.studio_id;

  select max(occurred_at) into v_last
    from challenge_progress_events
   where challenge_id = p.challenge_id and member_id = p.member_id;

  if c.type = 'streak' then
    -- The trailing consecutive block of attended weeks, most recent first.
    for v_wk in
      select distinct studio_week_start(p.studio_id, (occurred_at at time zone v_tz)::date) wk
        from challenge_progress_events
       where challenge_id = p.challenge_id and member_id = p.member_id
       order by 1 desc
    loop
      if v_prev is null or v_prev - v_wk = 7 then
        v_run := v_run + 1; v_prev := v_wk;
      else
        exit;  -- a gap ends the current run
      end if;
    end loop;
    v_prog := v_run;
    if v_prog >= c.goal_value then v_comp := v_last; end if;
  else
    select count(*) into v_prog
      from challenge_progress_events
     where challenge_id = p.challenge_id and member_id = p.member_id;
    if v_prog >= c.goal_value then
      select occurred_at into v_comp from (
        select occurred_at, row_number() over (order by occurred_at, id) rn
          from challenge_progress_events
         where challenge_id = p.challenge_id and member_id = p.member_id
      ) q where q.rn = c.goal_value;
    end if;
  end if;

  update challenge_participants
     set progress = v_prog,
         last_progress_at = v_last,
         completed_at = v_comp,
         updated_at = now()
   where id = p_participant_id;
end $$;

-- -----------------------------------------------------------------------------
-- Joining — §9.2. Member self, or desk-up staff acting for a walk-in. Refused
-- after the join_deadline (Decision 6). On join, backfill an event for every
-- qualifying attendance SINCE THE CHALLENGE START — a member who joins on day
-- ten with four classes already starts at four.
-- -----------------------------------------------------------------------------
create function join_challenge(p_challenge_id uuid, p_member_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c        challenges%rowtype;
  v_member uuid;
  v_tz     text;
  v_today  date;
  v_pid    uuid;
  v_new    boolean := false;
begin
  select * into c from challenges where id = p_challenge_id;
  if c.id is null then raise exception 'no such challenge' using errcode = 'PT404'; end if;
  if c.audience <> 'member' then
    raise exception 'that is not a member challenge' using errcode = 'PT409';
  end if;

  -- Resolve who is joining, and check the caller is allowed to join them.
  if p_member_id is null then
    select id into v_member from members
     where studio_id = c.studio_id and user_id = auth.uid();
    if v_member is null then
      raise exception 'no membership at this studio' using errcode = 'PT403';
    end if;
  else
    v_member := p_member_id;
    if not (exists (select 1 from members m
                     where m.id = v_member and m.user_id = auth.uid())
            or is_desk_up(c.studio_id)) then
      raise exception 'not yours to join' using errcode = 'PT403';
    end if;
  end if;

  if c.status not in ('scheduled', 'active') then
    raise exception 'this challenge is not open to join' using errcode = 'PT409';
  end if;

  select timezone into v_tz from studios where id = c.studio_id;
  v_today := (now() at time zone v_tz)::date;
  if v_today > c.join_deadline then
    raise exception 'the deadline to join this challenge has passed'
      using errcode = 'PT409';
  end if;

  insert into challenge_participants (studio_id, challenge_id, audience, member_id, goal_value)
  values (c.studio_id, p_challenge_id, 'member', v_member, c.goal_value)
  on conflict (challenge_id, member_id) where member_id is not null do nothing
  returning id into v_pid;

  if v_pid is null then
    -- Already joined: idempotent, no second notification.
    select id into v_pid from challenge_participants
     where challenge_id = p_challenge_id and member_id = v_member;
    perform recompute_participant(v_pid);
    perform rank_challenge(p_challenge_id);
    return jsonb_build_object('participant_id', v_pid, 'already', true);
  end if;
  v_new := true;

  -- §9.2 backfill: every qualifying attended booking since the start counts,
  -- idempotent on the (challenge, member, booking) unique index.
  insert into challenge_progress_events
    (studio_id, challenge_id, member_id, booking_id, occurrence_id, delta, occurred_at)
  select c.studio_id, p_challenge_id, v_member, b.id, b.occurrence_id, 1, o.starts_at
    from bookings b
    join class_occurrences o on o.id = b.occurrence_id
   where b.member_id = v_member
     and b.status = 'attended'
     and challenge_qualifies(p_challenge_id, o.id)
  on conflict do nothing;

  perform recompute_participant(v_pid);
  perform rank_challenge(p_challenge_id);
  perform queue_challenge_joined(v_pid);

  return jsonb_build_object('participant_id', v_pid, 'already', false);
end $$;

-- -----------------------------------------------------------------------------
-- The synchronous §8 hook. A booking becoming `attended` — by a desk check-in
-- OR by a no-show being corrected (mark_present) — records progress in the same
-- transaction, so the member sees their achievement before they leave the
-- building. A booking LOSING `attended` (a mistaken check-in undone, or marked a
-- no-show) removes it. Imports never reach here: they write check_ins with no
-- booking. A comp booking is just a payment source and its attendance counts
-- like any other.
--
-- SECURITY DEFINER because the writer is usually front desk (desk-up, not
-- manager-up), which the challenge RLS does not let write directly — the same
-- shape as tg_record_infraction.
-- -----------------------------------------------------------------------------
create function tg_challenge_progress() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  r          record;
  v_old_prog int; v_old_comp timestamptz;
  v_new_prog int; v_new_comp timestamptz; v_goal int;
  v_half     int;
  v_done     int;
begin
  if new.status = 'attended' and old.status is distinct from 'attended' then
    -- Every member challenge this member has joined that this class counts for.
    for r in
      select cp.id as participant_id, cp.challenge_id
        from challenge_participants cp
        join challenges c on c.id = cp.challenge_id
       where cp.member_id = new.member_id
         and cp.audience = 'member'
         and c.status in ('scheduled', 'active')
         and challenge_qualifies(cp.challenge_id, new.occurrence_id)
    loop
      insert into challenge_progress_events
        (studio_id, challenge_id, member_id, booking_id, occurrence_id, delta, occurred_at)
      select new.studio_id, r.challenge_id, new.member_id, new.id, new.occurrence_id, 1,
             (select starts_at from class_occurrences where id = new.occurrence_id)
      on conflict do nothing;

      select progress, completed_at into v_old_prog, v_old_comp
        from challenge_participants where id = r.participant_id;
      perform recompute_participant(r.participant_id);
      select progress, completed_at, goal_value into v_new_prog, v_new_comp, v_goal
        from challenge_participants where id = r.participant_id;
      perform rank_challenge(r.challenge_id);

      v_half := ceil(v_goal / 2.0);
      if v_new_comp is not null and v_old_comp is null then
        perform queue_challenge_completed(r.participant_id);
        -- §10: completing your 1st, 3rd or 10th challenge is a member milestone.
        select count(*) into v_done from challenge_participants
         where member_id = new.member_id and completed_at is not null;
        if v_done in (1, 3, 10) then
          perform queue_milestone(new.member_id,
            'challenge_' || v_done,
            case v_done when 1 then 'You completed your first challenge.'
                        when 3 then 'Three challenges done.'
                        else 'Ten challenges completed.' end);
        end if;
      elsif v_old_prog < v_half and v_new_prog >= v_half and v_new_comp is null then
        perform queue_challenge_milestone(r.participant_id);
      end if;
    end loop;

  elsif old.status = 'attended' and new.status is distinct from 'attended' then
    -- Undo: drop this booking's events everywhere and recompute what it touched.
    for r in
      select distinct e.challenge_id,
             (select id from challenge_participants
               where challenge_id = e.challenge_id and member_id = new.member_id) as participant_id
        from challenge_progress_events e
       where e.booking_id = new.id and e.member_id = new.member_id
    loop
      delete from challenge_progress_events
       where booking_id = new.id and challenge_id = r.challenge_id and member_id = new.member_id;
      if r.participant_id is not null then
        perform recompute_participant(r.participant_id);
        perform rank_challenge(r.challenge_id);
      end if;
    end loop;
  end if;

  return new;
end $$;

create trigger bookings_challenge_progress
  after update of status on bookings
  for each row execute function tg_challenge_progress();

-- -----------------------------------------------------------------------------
-- Grants: closed by default (this platform births functions executable by anon
-- AND authenticated). The two a client calls — join_challenge and the readers
-- built in part 3 — are guarded inside and granted to authenticated; the rest
-- are internals reached only through them or the trigger.
-- -----------------------------------------------------------------------------
revoke execute on function challenge_qualifies(uuid, uuid)   from public, anon, authenticated;
revoke execute on function rank_challenge(uuid)              from public, anon, authenticated;
revoke execute on function recompute_participant(uuid)       from public, anon, authenticated;
revoke execute on function tg_challenge_progress()           from public, anon, authenticated;
revoke execute on function join_challenge(uuid, uuid)        from public, anon;
grant  execute on function join_challenge(uuid, uuid)        to authenticated, service_role;
grant  execute on function challenge_qualifies(uuid, uuid)   to service_role;
grant  execute on function rank_challenge(uuid)              to service_role;
grant  execute on function recompute_participant(uuid)       to service_role;
