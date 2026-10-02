-- =============================================================================
-- Decision 42a amendment (a), fix-forward: the period scope is same series +
-- same studio-local WEEKDAY + same studio-local TIME-OF-DAY + same month, this
-- one forward. Migration 197 added the weekday filter but not time-of-day, so a
-- single series carrying two occurrences on the same weekday at different clock
-- times (hosted: one REFORMER BURN series at Sat 09:00 AND 17:00; one at Wed
-- 07:00 AND 18:00) had BOTH times swept by "this month". Clicking the 09:00 must
-- reach only the 09:00 classes of that series. Adding time-of-day strictly
-- NARROWS the set: a healthy series has one time per weekday, so a legitimate
-- same-slot sibling (identical weekday AND time) is never excluded; only the
-- anomalous extra-time occurrence is.
--
-- re-issues: assign_occurrences_for_period_run(uuid, uuid, text, date, boolean), cancel_occurrences_for_period_run(uuid, text, cancellation_cause, text)
--
-- Byte-for-byte the 20260832020000 bodies with ONE addition each: a v_tod
-- (studio-local minutes-of-day of the clicked occurrence) and a matching
-- predicate on the month/until branches. create-or-replace keeps the ACL; the
-- revokes/grants below re-assert it for belt-and-braces. The public wrappers
-- (assign_occurrences_for_period, cancel_occurrences_for_period) are unchanged.
-- =============================================================================

create or replace function assign_occurrences_for_period_run(
  p_occurrence_id uuid, p_instructor_id uuid default null, p_scope text default 'one',
  p_until date default null, p_confirmed boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o class_occurrences%rowtype; v_tz text; v_series uuid;
  v_month_start date; v_from_date date; v_dow double precision; v_tod int;
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
  -- 42a amendment (a): the scope is the clicked class's studio-local weekday AND
  -- time-of-day, because a series may carry several occurrences on one weekday at
  -- different clock times. Clicking the 09:00 reaches only the 09:00 classes.
  v_dow := extract(dow from o.starts_at at time zone v_tz);
  v_tod := (extract(hour from o.starts_at at time zone v_tz) * 60
            + extract(minute from o.starts_at at time zone v_tz))::int;
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
              and extract(dow from t.starts_at at time zone v_tz) = v_dow
              and (extract(hour from t.starts_at at time zone v_tz) * 60
                   + extract(minute from t.starts_at at time zone v_tz))::int = v_tod)
         or (p_scope = 'until' and v_series is not null and t.series_id = v_series
              and (t.starts_at at time zone v_tz)::date >= v_from_date
              and (t.starts_at at time zone v_tz)::date <= p_until
              and extract(dow from t.starts_at at time zone v_tz) = v_dow
              and (extract(hour from t.starts_at at time zone v_tz) * 60
                   + extract(minute from t.starts_at at time zone v_tz))::int = v_tod)
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

-- ---- Decision 47 cancel: same series + weekday + TIME-OF-DAY + month ---------
create or replace function cancel_occurrences_for_period_run(
  p_occurrence_id uuid, p_scope text default 'one',
  p_cause cancellation_cause default 'no_instructor', p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o class_occurrences%rowtype; v_tz text; v_series uuid;
  v_month_start date; v_from_date date; v_dow double precision; v_tod int;
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
  v_tod         := (extract(hour from o.starts_at at time zone v_tz) * 60
                    + extract(minute from o.starts_at at time zone v_tz))::int;

  -- Pass 1: resolve the target set (same series, same weekday, same time-of-day,
  -- same month, this one forward), applying the per-occurrence no_instructor skip.
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
              and extract(dow from t.starts_at at time zone v_tz) = v_dow
              and (extract(hour from t.starts_at at time zone v_tz) * 60
                   + extract(minute from t.starts_at at time zone v_tz))::int = v_tod)
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

-- The anon surface is unchanged — exactly TWELVE pre-login functions.
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 12 then
    raise exception 'anon surface is % functions, expected exactly 12', n;
  end if;
end $$;
