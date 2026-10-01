-- =============================================================================
-- Decision 47 + Decision 42a amendment (a): staff cancel a class (or the rest
-- of its weekday this month) from the Schedule, and the assign scopes are
-- same-weekday.
--
-- re-issues: assign_occurrences_for_period_run(uuid, uuid, text, date, boolean), schedule_range(uuid, date, date)
-- creates: cancel_occurrences_for_period_run(uuid, text, cancellation_cause, text), cancel_occurrences_for_period(uuid, text, cancellation_cause, text)
--
-- (a) assign_occurrences_for_period_run re-issued from its 20260831980000 body
--     with ONE change: the 'month' and 'until' scopes add a same-weekday filter,
--     because a series may run on several weekdays with a different instructor
--     per day (Nikko on Mondays, Joseph on Thursdays). Clicking a Thursday and
--     choosing "this month" must reach only the remaining Thursdays, never the
--     Mondays. Byte-for-byte the 980000 version otherwise.
--
-- (47) cancel_occurrences_for_period resolves the target set exactly as the
--     assign worker does (same series, same studio-local weekday, same month,
--     this one forward), skips already-cancelled/completed (status='scheduled'
--     filter), and calls the EXISTING cancel_occurrence per target inside a
--     savepoint — so Business Rules §3.2 (credit back, fee waived,
--     class_cancelled email, calendar cancel) and the by-cause instructor pay
--     (Decision 22) apply unchanged. The series row is never touched.
-- =============================================================================

-- The instructor-facing cancellation notice (Decision 47). A staff-recipient
-- template, so it goes out regardless of member preferences (queue_shift_notice
-- inserts recipient_type='staff'). on-conflict so a re-apply is a no-op.
insert into notification_templates (key, subject, text_body, html_body, note) values
('instructor_class_cancelled',
 '{class_name} on {when} was cancelled',
 E'Hi {first_name},\n\n{class_name} on {when} has been cancelled by the studio. You are not expected to teach it.\n\nIf you have questions, reply to this email.',
 E'<p>Hi {first_name},</p><p>{class_name} on {when} has been cancelled by the studio. You are not expected to teach it.</p><p>If you have questions, reply to this email.</p>',
 'To the assigned instructor when staff cancel their class from the Schedule (Decision 47).')
on conflict (key) do nothing;

create or replace function assign_occurrences_for_period_run(
  p_occurrence_id uuid, p_instructor_id uuid default null, p_scope text default 'one',
  p_until date default null, p_confirmed boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o class_occurrences%rowtype; v_tz text; v_series uuid;
  v_month_start date; v_from_date date; v_dow double precision;
  rec record; v_res jsonb; v_assigned int := 0; v_skipped jsonb := '[]'::jsonb;
  v_warn_avail boolean := false; v_when text; v_reason text; v_name text;
  v_old uuid; v_other uuid; v_dedupe text; v_affected uuid[] := '{}';
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if p_scope not in ('one','month','until') then
    raise exception 'scope must be one, month or until' using errcode = 'PT422';
  end if;
  if p_scope = 'until' and p_until is null then
    raise exception 'until needs a date' using errcode = 'PT422';
  end if;
  select timezone into v_tz from studios where id = o.studio_id;
  v_series     := o.series_id;
  v_from_date  := (o.starts_at at time zone v_tz)::date;
  v_month_start := date_trunc('month', o.starts_at at time zone v_tz)::date;
  -- 42a amendment (a): the scope is the clicked class's studio-local weekday.
  v_dow := extract(dow from o.starts_at at time zone v_tz);
  v_name := coalesce((select display_name from instructors where id = p_instructor_id), 'the instructor');

  for rec in
    select t.id, t.starts_at, t.ends_at, t.instructor_id
      from class_occurrences t
     where t.status = 'scheduled'
       and (
            (p_scope = 'one' and t.id = o.id)
         or (p_scope <> 'one' and v_series is null and t.id = o.id)
         or (p_scope = 'month' and v_series is not null and t.series_id = v_series
              and (t.starts_at at time zone v_tz)::date >= v_from_date
              and date_trunc('month', t.starts_at at time zone v_tz)::date = v_month_start
              and extract(dow from t.starts_at at time zone v_tz) = v_dow)
         or (p_scope = 'until' and v_series is not null and t.series_id = v_series
              and (t.starts_at at time zone v_tz)::date >= v_from_date
              and (t.starts_at at time zone v_tz)::date <= p_until
              and extract(dow from t.starts_at at time zone v_tz) = v_dow)
       )
     order by t.starts_at
  loop
    v_when := to_char(rec.starts_at at time zone v_tz, 'FMDy FMDD FMMon HH24:MI');
    v_old := rec.instructor_id;
    begin
      if p_instructor_id is null then
        if rec.instructor_id is null then
          v_assigned := v_assigned + 1;
        else
          v_res := move_occurrence(p_occurrence_id => rec.id, p_confirm => true,
                                   p_clear_instructor => true);
          if coalesce((v_res ->> 'ok')::boolean, false) then
            v_assigned := v_assigned + 1;
            if not (v_old = any(v_affected)) then v_affected := v_affected || v_old; end if;
          else
            v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
              'occurrence_id', rec.id, 'when', v_when,
              'reason', coalesce(v_res ->> 'reason', 'could not unassign')));
          end if;
        end if;
      elsif rec.instructor_id = p_instructor_id then
        if p_confirmed then perform mark_assignment_confirmed(rec.id); end if;
        v_assigned := v_assigned + 1;
      else
        v_res := reassign_occurrence(rec.id, p_instructor_id);
        if coalesce((v_res ->> 'ok')::boolean, false) then
          v_assigned := v_assigned + 1;
          if p_confirmed then perform mark_assignment_confirmed(rec.id); end if;
        else
          v_reason := case
            when v_res ->> 'reason' = 'instructor_busy'
              then v_name || ' already teaches '
                   || coalesce(v_res -> 'blocked_by' ->> 'name', 'another class') || ' at that time'
            when v_res ->> 'reason' = 'room_busy' then 'the room is taken at that time'
            when v_res ->> 'reason' = 'outside_availability_dates'
              then v_name || ' is not available on that date'
            else coalesce(v_res ->> 'reason', 'could not assign') end;
          v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
            'occurrence_id', rec.id, 'when', v_when, 'reason', v_reason));
        end if;
      end if;
    exception when exclusion_violation then
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
        'occurrence_id', rec.id, 'when', v_when,
        'reason', v_name || ' already teaches another class at that time'));
    end;

    if p_instructor_id is not null
       and not instructor_available_at_run(p_instructor_id, rec.starts_at, rec.ends_at) then
      v_warn_avail := true;
    end if;
  end loop;

  if p_instructor_id is null then
    foreach v_old in array v_affected loop
      select id into v_other from class_occurrences
        where instructor_id = v_old and status = 'scheduled' and starts_at > now()
          and assignment_requested_at is not null and assignment_confirmed_at is null
        limit 1;
      if v_other is not null then
        perform queue_assignment_request(v_other);
      else
        v_dedupe := 'assignment_confirm:' || v_old || ':' || (now() at time zone v_tz)::date;
        delete from notifications where dedupe_key = v_dedupe and status = 'scheduled';
      end if;
    end loop;
  end if;

  return jsonb_build_object(
    'ok', true, 'assigned', v_assigned, 'skipped', v_skipped,
    'warnings', case when v_warn_avail then jsonb_build_array('outside_availability')
                     else '[]'::jsonb end,
    'instructor', case when p_instructor_id is null then null else v_name end);
end $$;
revoke execute on function assign_occurrences_for_period_run(uuid, uuid, text, date, boolean)
  from public, anon, authenticated;
grant  execute on function assign_occurrences_for_period_run(uuid, uuid, text, date, boolean)
  to service_role;

-- ---- Decision 47: cancel a class / the rest of its weekday this month -------
create or replace function cancel_occurrences_for_period_run(
  p_occurrence_id uuid, p_scope text default 'one',
  p_cause cancellation_cause default 'no_instructor', p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o class_occurrences%rowtype; v_tz text; v_series uuid;
  v_month_start date; v_from_date date; v_dow double precision;
  rec record; v_res jsonb; v_cancelled int := 0; v_skipped jsonb := '[]'::jsonb;
  v_members int := 0; v_when text; v_targets uuid[] := '{}'; tid uuid;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if p_scope not in ('one','month') then
    raise exception 'scope must be one or month' using errcode = 'PT422';
  end if;
  -- Staff may only choose these three. unmet_minimum is the flex sweep's own
  -- cause (Decision 21); closure is Decision 44's. Neither is reachable here.
  if p_cause not in ('no_instructor','studio_fault','force_majeure') then
    raise exception 'cause must be no_instructor, studio_fault or force_majeure'
      using errcode = 'PT422';
  end if;
  -- no_instructor is for the class nobody can teach. On a class that HAS one,
  -- the studio means something else (studio_fault / force_majeure).
  if p_cause = 'no_instructor' and o.instructor_id is not null then
    raise exception 'This class has an instructor — choose a different reason.'
      using errcode = 'PT422';
  end if;

  select timezone into v_tz from studios where id = o.studio_id;
  v_series      := o.series_id;
  v_from_date   := (o.starts_at at time zone v_tz)::date;
  v_month_start := date_trunc('month', o.starts_at at time zone v_tz)::date;
  v_dow         := extract(dow from o.starts_at at time zone v_tz);

  -- Pass 1: resolve the target set (same series, same weekday, same month, this
  -- one forward), applying the per-occurrence no_instructor skip.
  for rec in
    select t.id, t.starts_at, t.instructor_id
      from class_occurrences t
     where t.status = 'scheduled'
       and (
            (p_scope = 'one' and t.id = o.id)
         or (p_scope = 'month' and v_series is null and t.id = o.id)
         or (p_scope = 'month' and v_series is not null and t.series_id = v_series
              and (t.starts_at at time zone v_tz)::date >= v_from_date
              and date_trunc('month', t.starts_at at time zone v_tz)::date = v_month_start
              and extract(dow from t.starts_at at time zone v_tz) = v_dow)
       )
     order by t.starts_at
  loop
    v_when := to_char(rec.starts_at at time zone v_tz, 'FMDy FMDD FMMon HH24:MI');
    if p_cause = 'no_instructor' and rec.instructor_id is not null then
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
        'occurrence_id', rec.id, 'when', v_when, 'reason', 'has an instructor'));
    else
      v_targets := v_targets || rec.id;
    end if;
  end loop;

  -- The members who will be told: distinct across the target set, counted
  -- before cancelling (cancel_booking changes their status).
  select count(distinct b.member_id) into v_members
    from bookings b
   where b.occurrence_id = any(v_targets)
     and b.status in ('booked','waitlisted','pending_payment');

  -- Pass 2: cancel each through the existing §3.2 path, one savepoint apiece so
  -- a single failure never aborts the batch. cancel_occurrence tells the booked
  -- members; the ASSIGNED instructor (Decision 47: "the instructor, if any, is
  -- told") is told here — queue_shift_notice returns null for a no-login
  -- instructor, so it never implies a message that was not sent.
  declare o2 class_occurrences%rowtype; v_iu uuid;
  begin
    foreach tid in array v_targets loop
      select * into o2 from class_occurrences where id = tid;
      v_when := to_char(o2.starts_at at time zone v_tz, 'FMDy FMDD FMMon HH24:MI');
      begin
        v_res := cancel_occurrence(tid, p_reason, p_cause);
        if coalesce((v_res ->> 'ok')::boolean, false)
           and not coalesce((v_res ->> 'already_cancelled')::boolean, false) then
          v_cancelled := v_cancelled + 1;
          if o2.instructor_id is not null then
            v_iu := instructor_user_id(o2.instructor_id);
            if v_iu is not null then
              perform queue_shift_notice(o2.studio_id, v_iu, 'instructor_class_cancelled',
                jsonb_build_object('class_name', o2.name,
                  'when', to_char(o2.starts_at at time zone v_tz, 'FMDay FMDD FMMonth YYYY'),
                  'occurrence_id', tid),
                'instructor_class_cancelled:' || tid);
            end if;
          end if;
        else
          v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
            'occurrence_id', tid, 'when', v_when,
            'reason', coalesce(v_res ->> 'reason', 'already cancelled')));
        end if;
      exception when others then
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
          'occurrence_id', tid, 'when', v_when, 'reason', sqlerrm));
      end;
    end loop;
  end;

  -- One batch-level audit row (cancel_occurrence writes its own per occurrence).
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (o.studio_id, auth.uid(), 'occurrences.cancelled_period', 'class_occurrences',
          p_occurrence_id, jsonb_build_object('scope', p_scope, 'cause', p_cause,
            'reason', p_reason, 'cancelled', v_cancelled,
            'members_affected', v_members, 'skipped', v_skipped));

  return jsonb_build_object('ok', true, 'cancelled', v_cancelled,
    'skipped', v_skipped, 'members_affected', v_members);
end $$;
revoke execute on function cancel_occurrences_for_period_run(uuid, text, cancellation_cause, text)
  from public, anon, authenticated;
grant  execute on function cancel_occurrences_for_period_run(uuid, text, cancellation_cause, text)
  to service_role;

create or replace function cancel_occurrences_for_period(
  p_occurrence_id uuid, p_scope text default 'one',
  p_cause cancellation_cause default 'no_instructor', p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_studio uuid;
begin
  select studio_id into v_studio from class_occurrences where id = p_occurrence_id;
  if v_studio is null then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(v_studio), false) then
    raise exception 'only owners and managers cancel a class' using errcode = 'PT403';
  end if;
  return cancel_occurrences_for_period_run(p_occurrence_id, p_scope, p_cause, p_reason);
end $$;
revoke execute on function cancel_occurrences_for_period(uuid, text, cancellation_cause, text)
  from public, anon;
grant  execute on function cancel_occurrences_for_period(uuid, text, cancellation_cause, text)
  to authenticated, service_role;

-- schedule_range re-issued (Decision 47): a staff cancellation stays VISIBLE on
-- the Schedule. Migration 116 kept only unmet_minimum cancellations; this keeps
-- the three staff-chosen causes too, so a cancelled class shows as cancelled
-- rather than vanishing. Byte-for-byte the 920000 body with one WHERE line
-- widened. create-or-replace keeps the ACL (signature unchanged).
CREATE OR REPLACE FUNCTION public.schedule_range(p_studio_id uuid, p_from date, p_to date)
 RETURNS TABLE(occ_id uuid, occ_name text, starts_at timestamp with time zone, ends_at timestamp with time zone, local_date date, local_start text, local_end text, start_minutes integer, end_minutes integer, occ_instructor_id uuid, room_name text, occ_capacity integer, occ_booked integer, occ_waitlist integer, occ_staffing text, occ_status text, occ_flex boolean, occ_confirmed boolean, occ_tier text, occ_standalone boolean, occ_series_tier text, occ_minimum integer, occ_cancellation_cause text, occ_assignment_requested boolean, occ_assignment_confirmed boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_tz text;
begin
  if not coalesce(is_manager_up(p_studio_id), false) and not is_service_context() then
    raise exception 'the timetable is the owner''s and managers'' to see'
      using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  if v_tz is null then
    raise exception 'no such studio' using errcode = 'PT404';
  end if;
  if p_to < p_from then
    raise exception 'that range ends before it starts' using errcode = 'PT400';
  end if;
  if p_to - p_from > 62 then
    raise exception 'ask for at most 62 days at a time' using errcode = 'PT422';
  end if;

  return query
  select o.id, o.name, o.starts_at, o.ends_at,
         (o.starts_at at time zone v_tz)::date,
         to_char(o.starts_at at time zone v_tz, 'HH24:MI'),
         to_char(o.ends_at   at time zone v_tz, 'HH24:MI'),
         (extract(hour from o.starts_at at time zone v_tz) * 60
          + extract(minute from o.starts_at at time zone v_tz))::int,
         (extract(hour from o.ends_at at time zone v_tz) * 60
          + extract(minute from o.ends_at at time zone v_tz))::int,
         o.instructor_id, r.name, o.capacity, o.booked_count, o.waitlist_count,
         o.staffing::text, o.status::text,
         o.flex, o.committed_at is not null,
         g.tier::text,
         (g.tier = 'flex' and not occurrence_is_adjacent_run(o.id)),
         coalesce(
           o.guarantee_tier,
           case when o.flex then 'flex'::guarantee_tier end,
           ser.guarantee_tier,
           case when ser.flex then 'flex'::guarantee_tier end,
           'core'::guarantee_tier)::text,
         g.minimum,
         o.cancellation_cause::text,
         o.assignment_requested_at is not null,
         o.assignment_confirmed_at is not null
    from class_occurrences o
    cross join lateral occurrence_guarantee_run(o.id) g
    left join class_series ser on ser.id = o.series_id
    left join rooms r on r.id = o.room_id
   where o.studio_id = p_studio_id
     and (o.status <> 'cancelled'
          or o.cancellation_cause in ('unmet_minimum','no_instructor','studio_fault','force_majeure'))
     and (o.starts_at at time zone v_tz)::date between p_from and p_to
   order by o.starts_at;
end $function$;

-- The anon surface is unchanged — exactly TWELVE pre-login functions. Assert it
-- here so a stray grant on any of these cannot slip through.
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 12 then
    raise exception 'anon surface is % functions, expected exactly 12', n;
  end if;
end $$;
