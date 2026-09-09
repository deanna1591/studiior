-- =============================================================================
-- Migration 061: automatic instructor assignment
-- =============================================================================
-- The studio defines the weekly slots (class_series, materialised by 057). What
-- was missing was filling a series that has NO instructor, per occurrence.
--
-- TWO LEVELS OF AVAILABILITY, and they are not the same rule:
--
--   The VALIDITY WINDOW (instructor_availability.effective_from / effective_to)
--   is a HARD GATE EVERYWHERE. Someone who submitted a pattern valid only for
--   November is not a candidate for December — not for the engine, not on the
--   cover board, not in the calendar's picker. They have not agreed to be there
--   and offering them invites a human to pick somebody who never said yes.
--
--   The DAY AND TIME within that window still warns rather than blocks for a
--   HUMAN (Decision 9: a hard block gets worked around by not using the
--   feature). For the ENGINE it blocks: a person assigning outside somebody's
--   stated hours knows why they are doing it, and an engine doing the same
--   produces a class nobody turns up to teach. An open shift is honest.
--
-- Verified before building rather than assumed: instructor_available_at()
-- already honours effective_from/effective_to and dated exceptions — a
-- November-only instructor answers false for 10 December, false for 10 October,
-- and false for an excepted 11 November.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- The human mark
-- -----------------------------------------------------------------------------
-- is_exception cannot carry this. It is set by tg_mark_moved_as_exception on a
-- starts_at/ends_at change, so it means "this class moved" — reusing it would
-- make dragging a class in the calendar freeze its instructor while CHANGING
-- the instructor did not, which is exactly backwards.
alter table class_occurrences
  add column if not exists assigned_by uuid references profiles on delete set null;
comment on column class_occurrences.assigned_by is
  'The person who chose this instructor. Null means the engine did it and may '
  'do it again; not-null is sticky and the engine will not touch it.';

-- Set by a trigger rather than at each call site, so a direct PostgREST update,
-- move_occurrence(), approve_cover_request() and approve_shift_application()
-- are all covered without any of them remembering. The engine exempts itself
-- with a transaction-local flag, the same shape as guard_archive_path().
create or replace function tg_mark_manual_assignment() returns trigger
language plpgsql set search_path = public as $$
begin
  -- Only when a human chooses a PERSON. Clearing an instructor is a vacancy,
  -- and a vacancy is the thing the engine exists to fill — marking it would
  -- mean that after archiving somebody, "fill November" silently skipped every
  -- class they had been on. Found by the suite: six reopened classes came back
  -- with assigned_by set and the engine filled one of them.
  --
  -- The one deliberate clearing is "publish this as an open shift", and
  -- approve_cover_request() stamps that itself — staff asking instructors to
  -- apply is a decision the engine must not undo.
  if new.instructor_id is not null
     and new.instructor_id is distinct from old.instructor_id
     and coalesce(current_setting('studiior.assigning', true), '') <> '1' then
    new.assigned_by := coalesce(auth.uid(), new.assigned_by);
  end if;
  return new;
end $$;

drop trigger if exists class_occurrences_mark_assignment on class_occurrences;
create trigger class_occurrences_mark_assignment
  before update of instructor_id on class_occurrences
  for each row execute function tg_mark_manual_assignment();

-- -----------------------------------------------------------------------------
-- Is this instructor's pattern in force on this date at all?
-- -----------------------------------------------------------------------------
-- Separate from instructor_available_at(), which asks about one slot. This asks
-- the prior question — should they be OFFERED for this date — and is the gate
-- the calendar and the cover board use.
--
-- An instructor with no weekly pattern at all is NOT gated: they have never
-- opened the screen, which is not the same as having said no, and gating them
-- would quietly empty the cover board on the day this ships.
create or replace function instructor_valid_on(p_instructor_id uuid, p_on date)
returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when p_instructor_id is null then false
    when not exists (select 1 from instructor_availability a
                      where a.instructor_id = p_instructor_id and a.day_of_week is not null)
      then true
    else exists (select 1 from instructor_availability a
                  where a.instructor_id = p_instructor_id
                    and a.day_of_week is not null
                    and (a.effective_from is null or a.effective_from <= p_on)
                    and (a.effective_to   is null or a.effective_to   >= p_on))
  end
$$;

-- -----------------------------------------------------------------------------
-- The engine
-- -----------------------------------------------------------------------------
-- The run itself, unguarded, callable by nobody. Decision 9 lets an INSTRUCTOR
-- write their own availability, and that edit should still fill the classes it
-- makes fillable — so the wrapper below carries the manager-up guard and the
-- internal is what set_instructor_availability() calls. Same split as the
-- timeline's rebuild: one derivation, two entry points with different guards.
create or replace function assign_instructors_run(
  p_studio_id uuid,
  p_from date default null,
  p_to date default null,
  p_dry_run boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tz text;
  o record;
  cand record;
  v_from date; v_to date;
  v_local date;
  v_week date;
  v_picked uuid;
  v_picked_name text;
  v_deficit int;
  v_fallback boolean := false;
  v_fallback_names text[] := '{}';
  n_assigned int := 0;
  n_open int := 0;
  v_log jsonb := '[]'::jsonb;
begin
  select timezone into v_tz from studios where id = p_studio_id;
  if v_tz is null then
    raise exception 'no such studio' using errcode = 'PT404';
  end if;

  v_from := coalesce(p_from, (now() at time zone v_tz)::date);
  v_to   := coalesce(p_to, (v_from + interval '3 months')::date);

  -- The engine's own writes must not look like a human's.
  perform set_config('studiior.assigning', '1', true);

  for o in
    select c.id, c.class_type_id, c.starts_at, c.ends_at, c.name, c.booked_count
      from class_occurrences c
     where c.studio_id = p_studio_id
       and c.status = 'scheduled'
       and c.staffing = 'open'
       -- OVERRIDE ALWAYS WINS. A class a person has touched is never revisited.
       and c.assigned_by is null
       and (c.starts_at at time zone v_tz)::date between v_from and v_to
     order by c.starts_at, c.id
  loop
    v_local := (o.starts_at at time zone v_tz)::date;
    v_week  := date_trunc('week', v_local)::date;
    v_picked := null; v_picked_name := null; v_deficit := null;

    select i.id, i.display_name, x.deficit, x.this_week, x.has_commitment
      into cand
      from instructors i
      join lateral (
        select
          -- Deficit against the weekly TARGET. With no commitment the target is
          -- 0, so the expression becomes -this_week and "largest deficit"
          -- degrades exactly to "fewest classes that week" — the stated
          -- fallback, and reported rather than left to be inferred.
          coalesce(cm.target_per_week, 0) - (
            select count(*) from class_occurrences w
             where w.instructor_id = i.id
               and w.status <> 'cancelled'
               and date_trunc('week', (w.starts_at at time zone v_tz)::date)::date = v_week
          )::int as deficit,
          (select count(*)::int from class_occurrences w
            where w.instructor_id = i.id
              and w.status <> 'cancelled'
              and date_trunc('week', (w.starts_at at time zone v_tz)::date)::date = v_week
          ) as this_week,
          (cm.id is not null) as has_commitment
        from (select 1) _
        left join instructor_commitments cm
               on cm.instructor_id = i.id and cm.status = 'active'
              and cm.starts_on <= v_local
              and (cm.ends_on is null or cm.ends_on >= v_local)
      ) x on true
     where i.studio_id = p_studio_id
       and i.status = 'active'
       -- (a) qualified. An empty mapping means nothing, not everything.
       and instructor_qualified(i.id, o.class_type_id)
       -- (b) inside their validity window AND free at that time. Both hard for
       --     the engine; the window is hard for humans too.
       and instructor_valid_on(i.id, v_local)
       and instructor_available_at(i.id, o.starts_at, o.ends_at)
       -- (c) not already teaching. Rows assigned earlier in this same run are
       --     already visible here, so two occurrences cannot take one person.
       and not exists (
         select 1 from class_occurrences b
          where b.instructor_id = i.id
            and b.status <> 'cancelled'
            and tstzrange(b.starts_at, b.ends_at) && tstzrange(o.starts_at, o.ends_at))
     -- Deterministic, so a re-run is stable: deficit, then fewest classes, then
     -- the id. The id is arbitrary and that is the point — it is STABLE.
     order by x.deficit desc, x.this_week asc, i.id asc
     limit 1;

    if cand.id is null then
      n_open := n_open + 1;
      v_log := v_log || jsonb_build_object(
        'occurrence_id', o.id, 'class', o.name,
        'when', to_char(o.starts_at at time zone v_tz, 'YYYY-MM-DD HH24:MI'),
        'outcome', 'left_open',
        'why', case
          when not exists (select 1 from instructor_class_types t
                            where t.studio_id = p_studio_id and t.class_type_id = o.class_type_id)
            then 'nobody is down to teach this class type'
          when not exists (select 1 from instructors i
                            where i.studio_id = p_studio_id and i.status = 'active'
                              and instructor_qualified(i.id, o.class_type_id)
                              and instructor_valid_on(i.id, v_local))
            then 'everybody qualified is outside their availability dates for this day'
          when not exists (select 1 from instructors i
                            where i.studio_id = p_studio_id and i.status = 'active'
                              and instructor_qualified(i.id, o.class_type_id)
                              and instructor_valid_on(i.id, v_local)
                              and instructor_available_at(i.id, o.starts_at, o.ends_at))
            then 'nobody qualified has said they are free at this time'
          else 'everybody qualified and free is already teaching then' end,
        'booked', o.booked_count);
      continue;
    end if;

    v_picked := cand.id; v_picked_name := cand.display_name; v_deficit := cand.deficit;
    if not cand.has_commitment then
      v_fallback := true;
      if not (cand.display_name = any (v_fallback_names)) then
        v_fallback_names := v_fallback_names || cand.display_name;
      end if;
    end if;

    if not p_dry_run then
      update class_occurrences
         set instructor_id = v_picked, staffing = 'assigned', updated_at = now()
       where id = o.id;
      perform queue_instructor_assigned(o.id);
    end if;
    n_assigned := n_assigned + 1;

    v_log := v_log || jsonb_build_object(
      'occurrence_id', o.id, 'class', o.name,
      'when', to_char(o.starts_at at time zone v_tz, 'YYYY-MM-DD HH24:MI'),
      'outcome', 'assigned',
      'instructor', v_picked_name,
      -- The working: why this person and not the other one.
      'why', case when cand.has_commitment
                  then format('%s of %s classes that week, furthest below their target',
                              cand.this_week, cand.this_week + cand.deficit)
                  else format('%s classes that week, fewest of the candidates — no commitment on file',
                              cand.this_week) end,
      'deficit', v_deficit);
  end loop;

  if not p_dry_run then
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (p_studio_id, auth.uid(), 'occurrences.assigned', 'studios', p_studio_id,
            jsonb_build_object('from', v_from, 'to', v_to,
                               'assigned', n_assigned, 'left_open', n_open));
  end if;

  return jsonb_build_object(
    'ok', true, 'dry_run', p_dry_run,
    'from', v_from, 'to', v_to,
    'assigned', n_assigned, 'left_open', n_open,
    -- Said out loud rather than silently degrading: without commitments the
    -- engine is balancing by "fewest classes this week", not toward a target.
    'commitment_fallback', v_fallback,
    'no_commitment_for', to_jsonb(v_fallback_names),
    'detail', v_log);
end $$;

create or replace function assign_instructors(
  p_studio_id uuid,
  p_from date default null,
  p_to date default null,
  p_dry_run boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_manager_up(p_studio_id) and not is_service_context() then
    raise exception 'only owners, managers or the scheduler may assign instructors'
      using errcode = 'PT403';
  end if;
  return assign_instructors_run(p_studio_id, p_from, p_to, p_dry_run);
end $$;

revoke execute on function assign_instructors_run(uuid, date, date, boolean) from public, anon, authenticated;
revoke execute on function assign_instructors(uuid, date, date, boolean) from public, anon, authenticated;
revoke execute on function instructor_valid_on(uuid, date)               from public, anon, authenticated;
revoke execute on function tg_mark_manual_assignment()                   from public, anon, authenticated;
grant execute on function assign_instructors(uuid, date, date, boolean) to authenticated, service_role;
grant execute on function instructor_valid_on(uuid, date)               to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- When it runs
-- -----------------------------------------------------------------------------
-- On series create/edit, so a studio adding an unstaffed Tuesday sees it filled
-- rather than waiting; and on an availability change, for FUTURE UNASSIGNED
-- occurrences only. Never retroactive: Decision 9 is explicit that editing
-- availability must not unassign anyone from a class they already agreed to.
create or replace function tg_assign_after_series() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.instructor_id is null and new.status = 'active' then
    perform assign_instructors_run(new.studio_id);
  end if;
  return null;
end $$;

drop trigger if exists class_series_assign on class_series;
create trigger class_series_assign
  after insert or update of rrule, time_of_day, starts_on, ends_on, status,
                            instructor_id, class_type_id
  on class_series
  for each row execute function tg_assign_after_series();

-- NOT a trigger on instructor_availability. A statement-level trigger cannot
-- read NEW at all, and a row-level one would run the engine fourteen times for
-- one week edit. The week is written by exactly one function, so that function
-- runs the engine once — which is also the only place that knows the whole edit
-- is finished rather than half applied.
--
-- FIXED FORWARD, not by editing migration 053: that migration is on hosted and
-- an applied migration is history. The row writer is lifted out of 053's LIVE
-- definition under a new name, and set_instructor_availability() becomes a
-- wrapper with the same signature, so every existing caller is untouched.
create or replace function set_instructor_availability_rows(
  p_instructor_id  uuid,
  p_days           jsonb,
  p_effective_from date default null,
  p_effective_to   date default null
) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_studio uuid;
  v_from   date;
  v_to     date;
  d        jsonb;
  r        jsonb;
  v_day    int;
  n        int := 0;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then
    raise exception 'no such instructor' using errcode = 'PT404';
  end if;

  -- Decision 9, unchanged: manager-up, or the instructor themselves. Checked
  -- here as well as in the policies, because this function is SECURITY DEFINER
  -- and the policies are not what stops it.
  if not is_manager_up(v_studio)
     and p_instructor_id is distinct from auth_instructor_id(v_studio) then
    raise exception 'only the studio or the instructor may set their availability'
      using errcode = 'PT403';
  end if;

  -- Defaulted from the live commitment, so the pattern and the agreement cannot
  -- drift apart. An explicit argument still wins — a studio amending mid-term
  -- is a real thing and this is not the place to argue with them.
  select coalesce(p_effective_from, c.starts_on),
         coalesce(p_effective_to,   c.ends_on)
    into v_from, v_to
    from instructor_commitments c
   where c.instructor_id = p_instructor_id and c.status = 'active';
  if not found then
    v_from := p_effective_from;
    v_to   := p_effective_to;
  end if;

  if v_to is not null and v_from is not null and v_to < v_from then
    raise exception 'the pattern ends before it starts' using errcode = 'PT422';
  end if;

  -- Only the weekly pattern. Dated exceptions live in the same table and are a
  -- different act — an exception is a Tuesday in September, and re-entering the
  -- week must not silently forget one.
  delete from instructor_availability
   where instructor_id = p_instructor_id
     and day_of_week is not null
     and day_of_week in (
       select (x ->> 'day')::int from jsonb_array_elements(p_days) x);

  for d in select * from jsonb_array_elements(p_days) loop
    v_day := (d ->> 'day')::int;
    if v_day is null or v_day < 0 or v_day > 6 then
      raise exception 'day_of_week must be 0-6, got %', d ->> 'day'
        using errcode = 'PT422';
    end if;

    for r in select * from jsonb_array_elements(coalesce(d -> 'ranges', '[]'::jsonb)) loop
      if (r ->> 'to')::time <= (r ->> 'from')::time then
        raise exception 'a range must end after it starts (day %, % to %)',
          v_day, r ->> 'from', r ->> 'to' using errcode = 'PT422';
      end if;
      insert into instructor_availability
        (studio_id, instructor_id, day_of_week, starts_at_time, ends_at_time,
         effective_from, effective_to, is_available, created_by)
      values (v_studio, p_instructor_id, v_day,
              (r ->> 'from')::time, (r ->> 'to')::time,
              v_from, v_to, true, auth.uid());
      n := n + 1;
    end loop;
  end loop;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (v_studio, auth.uid(), 'availability.set', 'instructors', p_instructor_id,
          jsonb_build_object('days', p_days, 'effective_from', v_from,
                             'effective_to', v_to, 'ranges_written', n));
  return n;
end $$;


create or replace function set_instructor_availability(
  p_instructor_id  uuid,
  p_days           jsonb,
  p_effective_from date default null,
  p_effective_to   date default null
) returns int
language plpgsql security definer set search_path = public as $$
declare v_n int; v_studio uuid;
begin
  v_n := set_instructor_availability_rows(p_instructor_id, p_days, p_effective_from, p_effective_to);
  select studio_id into v_studio from instructors where id = p_instructor_id;
  -- Future, open, untouched-by-a-human only. Decision 9 is explicit that
  -- editing availability must never unassign anyone from a class they have
  -- already agreed to teach, and assign_instructors() only ever looks at
  -- staffing = 'open' with a null assigned_by — so it cannot.
  perform assign_instructors_run(v_studio);
  return v_n;
end $$;

revoke execute on function set_instructor_availability_rows(uuid, jsonb, date, date)
  from public, anon, authenticated;

revoke execute on function tg_assign_after_series() from public, anon, authenticated;
revoke execute on function set_instructor_availability(uuid, jsonb, date, date)
  from public, anon, authenticated;
grant execute on function set_instructor_availability(uuid, jsonb, date, date)
  to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- The one clearing that IS a decision
-- -----------------------------------------------------------------------------
-- Opening a class for instructors to apply for is Decision 17's whole point,
-- and an engine that fills it ten seconds later has undone the studio's choice.
-- Stamped after the move, since the trigger deliberately ignores a clearing.
create or replace function stamp_open_shift(p_occurrence_id uuid) returns void
language sql security definer set search_path = public as $$
  update class_occurrences set assigned_by = coalesce(auth.uid(), assigned_by)
   where id = p_occurrence_id and instructor_id is null;
$$;
revoke execute on function stamp_open_shift(uuid) from public, anon, authenticated;

-- approve_cover_request() gains the stamp on its 'open' branch. Fixed forward
-- from the LIVE definition rather than by editing migration 054, which is on
-- hosted.
CREATE OR REPLACE FUNCTION public.approve_cover_request(p_request_id uuid, p_mode text, p_instructor_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  req cover_requests%rowtype; o class_occurrences%rowtype; s studios%rowtype;
  st studio_settings%rowtype; v_move jsonb; v_old text; v_new text;
  v_cut timestamptz; v_late boolean; v_subs int := 0; v_user uuid;
  v_told boolean := false;
begin
  select * into req from cover_requests where id = p_request_id;
  if not found then
    raise exception 'no such cover request' using errcode = 'PT404';
  end if;
  if not is_manager_up(req.studio_id) then
    raise exception 'only owners and managers may answer a cover request'
      using errcode = 'PT403';
  end if;
  if req.status <> 'pending' then
    raise exception 'this request has already been answered' using errcode = 'PT409';
  end if;
  if p_mode not in ('assign', 'open') then
    raise exception 'mode must be assign or open' using errcode = 'PT422';
  end if;
  if p_mode = 'assign' and p_instructor_id is null then
    raise exception 'assigning cover needs somebody to assign it to'
      using errcode = 'PT422';
  end if;
  if p_mode = 'assign' and p_instructor_id = req.instructor_id then
    raise exception 'that is the instructor who asked to be taken off it'
      using errcode = 'PT422';
  end if;

  select * into o  from class_occurrences where id = req.occurrence_id;
  select * into s  from studios           where id = req.studio_id;
  select * into st from studio_settings   where studio_id = req.studio_id;
  select display_name into v_old from instructors where id = req.instructor_id;

  -- move_occurrence() is the only thing that moves a class, and that includes
  -- changing who teaches it: the exclusion constraints, the availability
  -- warning and the audit entry are all already there. p_confirm is true
  -- because the caller has just been shown the booked count on the approval
  -- screen — this is the confirmation.
  v_move := move_occurrence(
    p_occurrence_id   => req.occurrence_id,
    p_instructor_id   => case when p_mode = 'assign' then p_instructor_id else null end,
    p_confirm         => true,
    p_clear_instructor=> (p_mode = 'open'));

  if not (v_move ->> 'ok')::boolean then
    -- The replacement is busy. Refused rather than forced: two classes for one
    -- person at one time is the thing the constraint exists to prevent, and a
    -- cover request is not a reason to make an exception.
    return v_move;
  end if;

  -- Decision 17's open shift is a choice, so the engine must not undo it.
  if p_mode = 'open' then
    perform stamp_open_shift(req.occurrence_id);
  end if;

  update cover_requests
     set status = 'approved',
         resolution = case when p_mode = 'assign' then 'assigned' else 'opened' end,
         covered_by = case when p_mode = 'assign' then p_instructor_id end,
         decided_by = auth.uid(), decided_at = now()
   where id = req.id;

  -- Decision 2, finally called. queue_substitution() has existed since
  -- migration 030 with nothing invoking it, so until now changing a class's
  -- instructor told the booked members nothing whatsoever.
  -- Read outside the booked_count branch: the name is needed for the reply and
  -- for the message to the instructor who asked, both of which happen whether
  -- or not anybody is booked in.
  if p_mode = 'assign' then
    select display_name into v_new from instructors where id = p_instructor_id;
  end if;

  if p_mode = 'assign' and o.booked_count > 0 then
    v_subs := queue_substitution(req.occurrence_id, v_old, v_new);

    -- "Announced after the cancellation cutoff has already passed." Three days'
    -- notice is normal policy; ninety minutes is not, because by then the
    -- member can no longer decide about it.
    v_cut  := o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0));
    v_late := now() > v_cut;
    if v_late and coalesce(st.sub_late_free_cancel, true) then
      update bookings
         set free_cancel_until = o.starts_at
       where occurrence_id = req.occurrence_id and status = 'booked';
    end if;
  end if;

  -- The person who asked, told they are off it.
  v_user := instructor_user_id(req.instructor_id);
  if v_user is not null then
    perform queue_shift_notice(req.studio_id, v_user, 'cover_approved',
      jsonb_build_object(
        'class_name', o.name,
        'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth, HH24:MI'),
        'cover_line', case when p_mode = 'assign'
          then coalesce(v_new, 'Someone else') || ' is taking it.'
          else 'It has been opened up for another instructor to pick up.' end),
      'cover_approved:' || req.id);
  end if;

  -- And the replacement, told they have a class — IF WE CAN REACH THEM. An
  -- instructor is a teaching record and `instructors` carries no email of its
  -- own, so one with staff_id null has no address anywhere in the schema. That
  -- is the common case, not an edge: two of the three seeded instructors have
  -- no login. Reported back rather than swallowed, so the screen can say "tell
  -- them yourself" instead of implying an email went out.
  if p_mode = 'assign' then
    v_told := queue_instructor_assigned(req.occurrence_id) is not null;
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (req.studio_id, auth.uid(), 'cover.approved', 'cover_requests', req.id,
          jsonb_build_object('instructor_id', req.instructor_id),
          jsonb_build_object('mode', p_mode, 'covered_by', p_instructor_id,
                             'members_told', v_subs, 'free_cancel', v_late));

  return jsonb_build_object('ok', true, 'mode', p_mode,
                            'members_told', v_subs,
                            'free_cancellation_granted', coalesce(v_late, false),
                            'cover_notified', v_told,
                            'cover_name', v_new,
                            'move', v_move);
end $function$
;

-- -----------------------------------------------------------------------------
-- The window gates what a human is OFFERED too
-- -----------------------------------------------------------------------------
-- Fixed forward from the LIVE definition; migration 047/050's files are on
-- hosted and an applied migration is history.
CREATE OR REPLACE FUNCTION public.move_occurrence(p_occurrence_id uuid, p_starts_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_ends_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_instructor_id uuid DEFAULT NULL::uuid, p_room_id uuid DEFAULT NULL::uuid, p_confirm boolean DEFAULT false, p_clear_instructor boolean DEFAULT false)
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

  -- TWO LEVELS, and only one of them is a warning.
  --
  -- The VALIDITY WINDOW is a hard refusal: an instructor whose stated pattern
  -- runs only through November has not agreed to be anywhere in December, and
  -- assigning them produces a class nobody turns up to teach. Decision 9's
  -- "warns, never blocks" is about a human overriding somebody's stated HOURS,
  -- which they can do knowing why — it was never about putting a person outside
  -- the dates they agreed to at all.
  if v_instr is not null
     and not instructor_valid_on(v_instr, (v_starts at time zone v_tz)::date) then
    return jsonb_build_object(
      'ok', false, 'requires_confirmation', false,
      'reason', 'outside_availability_dates',
      'blocked_by', jsonb_build_object(
        'who', (select display_name from instructors where id = v_instr),
        'on', to_char(v_starts at time zone v_tz, 'FMDay FMDD FMMonth YYYY')));
  end if;

  -- The day and time INSIDE that window stays a warning, per Decision 9.
  if v_instr is not null and not instructor_available_at(v_instr, v_starts, v_ends) then
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
