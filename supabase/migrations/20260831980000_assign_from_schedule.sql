-- =============================================================================
-- Decisions 43 + 42a — auto-assigner off by default, assign/unassign from the
-- Schedule for a period, and clear a month's assignments from Publish.
-- =============================================================================
-- Decision 43: automatic instructor assignment is a per-tenant switch,
--   studio_settings.auto_assign_open_classes, OFF by default. When off, the
--   engine never fires on its own — materialising a series leaves every
--   occurrence unassigned/open (Decision 17), and no availability change
--   assigns later. The MANUAL assign_instructors ("fill a month") is untouched.
--
-- Decision 42a: assignments are made per class or per period from the Schedule,
--   not on the series template. assign_occurrences_for_period resolves the
--   target set and writes each occurrence through the EXISTING single-occurrence
--   path (reassign_occurrence / move_occurrence(p_clear_instructor)), so
--   Decision 38's confirmation request, the double-booking exclusion constraints
--   and the audit all apply unchanged. A clash is skipped and listed, never
--   silently reassigned. clear_month_assignments clears a whole month from the
--   Publish page (refused only when the month is published AND members booked).
--
-- re-issues: tg_assign_after_series(), set_instructor_availability(uuid, jsonb, date, date),
--   submit_availability(uuid, date, jsonb, boolean), approve_availability_submission(uuid)
-- creates: auto_assign_enabled(uuid),
--   assign_occurrences_for_period_run(uuid, uuid, text, date, boolean),
--   assign_occurrences_for_period(uuid, uuid, text, date, boolean),
--   clear_month_assignments(uuid, date, boolean)
-- =============================================================================

-- ---- Decision 43: the switch ------------------------------------------------
alter table studio_settings
  add column if not exists auto_assign_open_classes boolean not null default false;

-- The one predicate every AUTOMATIC engine entry gates on. Defaults false, so a
-- studio that never turns it on never auto-assigns. Shaped like claiming_enabled.
create or replace function auto_assign_enabled(p_studio_id uuid) returns boolean
language sql stable set search_path = public as $$
  select coalesce((select auto_assign_open_classes from studio_settings where studio_id = p_studio_id), false)
$$;
revoke execute on function auto_assign_enabled(uuid) from public, anon;
grant  execute on function auto_assign_enabled(uuid) to authenticated, service_role;

-- Re-issued from 20260830710000 (newest) with the Decision 43 gate at the top.
-- When off, materialising a series (or editing one) never runs the engine, so
-- occurrences are created unassigned/open. Manual assign_instructors is untouched.
create or replace function tg_assign_after_series() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not auto_assign_enabled(new.studio_id) then return null; end if;
  if new.instructor_id is null and new.status = 'active' then
    perform assign_instructors_run(new.studio_id);
  end if;
  return null;
end $$;
revoke execute on function tg_assign_after_series() from public, anon, authenticated;

-- Re-issued from 20260830710000 (newest) — only the auto-fill is gated.
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
  -- Decision 43: only auto-fill open classes when the studio's switch is on.
  -- Future, open, untouched-by-a-human only (Decision 9, 061's assigned_by gate).
  if auto_assign_enabled(v_studio) then
    perform assign_instructors_run(v_studio);
  end if;
  return v_n;
end $$;

-- Re-issued from 20260830760000 (newest) — only the approved auto-fill is gated.
create or replace function submit_availability(
  p_instructor_id uuid,
  p_period_start  date,
  p_days          jsonb,
  p_submit        boolean default true
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_studio uuid;
  v_tz     text;
  v_today  date;
  v_end    date;
  v_status text;
  v_sub    availability_submissions%rowtype;
  v_is_mgr boolean;
  d jsonb; r jsonb; v_day int; n int := 0;
begin
  select i.studio_id, s.timezone into v_studio, v_tz
    from instructors i join studios s on s.id = i.studio_id
   where i.id = p_instructor_id;
  if v_studio is null then
    raise exception 'no such instructor' using errcode = 'PT404';
  end if;

  v_is_mgr := coalesce(is_manager_up(v_studio), false);
  if not v_is_mgr and p_instructor_id is distinct from auth_instructor_id(v_studio) then
    raise exception 'only the studio or the instructor may submit their availability'
      using errcode = 'PT403';
  end if;

  if p_period_start <> date_trunc('month', p_period_start)::date then
    raise exception 'a submission covers a whole month, so it starts on the 1st'
      using errcode = 'PT422';
  end if;
  v_today := (now() at time zone v_tz)::date;
  if p_period_start < date_trunc('month', v_today)::date then
    raise exception 'that month has already been and gone' using errcode = 'PT422';
  end if;
  v_end := (p_period_start + interval '1 month' - interval '1 day')::date;

  v_status := case
    when v_is_mgr then 'approved'
    when p_submit then 'submitted'
    else 'draft' end;

  insert into availability_submissions
    (studio_id, instructor_id, period_start, status, submitted_at,
     reviewed_by, reviewed_at, created_by, note)
  values (v_studio, p_instructor_id, p_period_start, v_status,
          case when v_status in ('submitted','approved') then now() end,
          case when v_status = 'approved' then auth.uid() end,
          case when v_status = 'approved' then now() end,
          auth.uid(), null)
  on conflict (instructor_id, period_start) do update
    set status = excluded.status,
        submitted_at = excluded.submitted_at,
        reviewed_by = excluded.reviewed_by,
        reviewed_at = excluded.reviewed_at,
        note = null,
        updated_at = now()
  returning * into v_sub;

  if v_sub.id is null then
    raise exception 'that submission is not yours' using errcode = 'PT403';
  end if;
  if v_sub.status = 'approved' and not v_is_mgr then
    raise exception 'that month is already approved — ask the studio to reopen it'
      using errcode = 'PT409';
  end if;

  delete from instructor_availability where submission_id = v_sub.id;

  for d in select * from jsonb_array_elements(p_days) loop
    v_day := (d ->> 'day')::int;
    if v_day is null or v_day < 0 or v_day > 6 then
      raise exception 'day_of_week must be 0-6, got %', d ->> 'day' using errcode = 'PT422';
    end if;
    for r in select * from jsonb_array_elements(coalesce(d -> 'ranges', '[]'::jsonb)) loop
      if (r ->> 'to')::time <= (r ->> 'from')::time then
        raise exception 'a range must end after it starts (day %, % to %)',
          v_day, r ->> 'from', r ->> 'to' using errcode = 'PT422';
      end if;
      insert into instructor_availability
        (studio_id, instructor_id, day_of_week, starts_at_time, ends_at_time,
         effective_from, effective_to, is_available, created_by,
         submission_id, approval_status)
      values (v_studio, p_instructor_id, v_day,
              (r ->> 'from')::time, (r ->> 'to')::time,
              p_period_start, v_end, true, auth.uid(),
              v_sub.id, v_sub.status);
      n := n + 1;
    end loop;
  end loop;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (v_studio, auth.uid(), 'availability.submitted', 'instructors', p_instructor_id,
          jsonb_build_object('period', p_period_start, 'status', v_sub.status,
                             'ranges', n));

  -- Decision 43: only let the engine fill when the studio's switch is on.
  if v_sub.status = 'approved' and auto_assign_enabled(v_studio) then
    perform assign_instructors_run(v_studio);
  end if;

  return jsonb_build_object(
    'submission_id', v_sub.id, 'status', v_sub.status,
    'period_start', p_period_start, 'period_end', v_end,
    'ranges', n,
    'auto_approved', v_is_mgr);
end $$;

-- Re-issued from 20260830760000 (newest) — only the auto-fill is gated.
create or replace function approve_availability_submission(p_submission_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_sub availability_submissions%rowtype; v_name text; v_uid uuid;
begin
  select * into v_sub from availability_submissions where id = p_submission_id for update;
  if not found then
    raise exception 'no such submission' using errcode = 'PT404';
  end if;
  if not coalesce(is_manager_up(v_sub.studio_id), false) then
    raise exception 'only owners and managers approve availability' using errcode = 'PT403';
  end if;
  if v_sub.status = 'draft' then
    raise exception 'that pattern has not been submitted yet' using errcode = 'PT409';
  end if;

  update availability_submissions
     set status = 'approved', reviewed_by = auth.uid(), reviewed_at = now(), note = null
   where id = p_submission_id;
  update instructor_availability
     set approval_status = 'approved', updated_at = now()
   where submission_id = p_submission_id;

  select i.display_name into v_name from instructors i where i.id = v_sub.instructor_id;
  v_uid := instructor_user_id(v_sub.instructor_id);

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (v_sub.studio_id, auth.uid(), 'availability.approved', 'instructors',
          v_sub.instructor_id, jsonb_build_object('period', v_sub.period_start));

  -- Decision 43: only let the engine fill when the studio's switch is on.
  if auto_assign_enabled(v_sub.studio_id) then
    perform assign_instructors_run(v_sub.studio_id);
  end if;

  return jsonb_build_object(
    'ok', true, 'submission_id', p_submission_id, 'period_start', v_sub.period_start,
    'instructor', v_name,
    'notified', queue_shift_notice(v_sub.studio_id, v_uid, 'availability_approved',
      jsonb_build_object('period', to_char(v_sub.period_start, 'FMMonth YYYY'),
                         'instructor_name', v_name),
      'avail_approved:' || p_submission_id) is not null);
end $$;

-- ---- Decision 42a: assign/unassign from the Schedule for a period -----------
-- The worker: resolve the target set, and for each occurrence call the EXISTING
-- single-occurrence path. reassign_occurrence (assign) and
-- move_occurrence(p_clear_instructor) (unassign) both go through move_occurrence,
-- so Decision 38's request-stamping triggers, the GiST exclusion constraints and
-- the audit apply unchanged. A clash is caught and listed, never silently
-- reassigned. NEVER touches class_series.instructor_id.
create or replace function assign_occurrences_for_period_run(
  p_occurrence_id uuid, p_instructor_id uuid default null, p_scope text default 'one',
  p_until date default null, p_confirmed boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o class_occurrences%rowtype; v_tz text; v_series uuid;
  v_month_start date; v_from_date date;
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
              and date_trunc('month', t.starts_at at time zone v_tz)::date = v_month_start)
         or (p_scope = 'until' and v_series is not null and t.series_id = v_series
              and (t.starts_at at time zone v_tz)::date >= v_from_date
              and (t.starts_at at time zone v_tz)::date <= p_until)
       )
     order by t.starts_at
  loop
    v_when := to_char(rec.starts_at at time zone v_tz, 'FMDy FMDD FMMon HH24:MI');
    v_old := rec.instructor_id;
    begin
      if p_instructor_id is null then
        -- UNASSIGN: back to 'open' (Decision 17). The BEFORE trigger clears the
        -- Decision 38 stamps; the digest is resynced after the loop.
        if rec.instructor_id is null then
          v_assigned := v_assigned + 1;   -- already open, nothing to do
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
        -- Already this instructor: a no-op assign (counts), optionally confirmed.
        if p_confirmed then perform mark_assignment_confirmed(rec.id); end if;
        v_assigned := v_assigned + 1;
      else
        -- ASSIGN through the single-occurrence path.
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
      -- Belt: a raw 23P01 never aborts the batch (move_occurrence normally
      -- catches it and returns a refusal, but a direct clash is caught here too).
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
        'occurrence_id', rec.id, 'when', v_when,
        'reason', v_name || ' already teaches another class at that time'));
    end;

    -- Decision 37 amendment (c): an availability mismatch is a WARNING, never a
    -- block. The hours-level warning, aggregated (the unguarded _run twin).
    if p_instructor_id is not null
       and not instructor_available_at_run(p_instructor_id, rec.starts_at, rec.ends_at) then
      v_warn_avail := true;
    end if;
  end loop;

  -- UNASSIGN resync: a withdrawn class must stop appearing in a pending
  -- "please confirm" digest. Recompute each affected instructor's digest, or
  -- delete it outright when nothing of theirs is pending.
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

create or replace function assign_occurrences_for_period(
  p_occurrence_id uuid, p_instructor_id uuid default null, p_scope text default 'one',
  p_until date default null, p_confirmed boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_studio uuid;
begin
  select studio_id into v_studio from class_occurrences where id = p_occurrence_id;
  if v_studio is null then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(v_studio), false) then
    raise exception 'only owners and managers change the timetable' using errcode = 'PT403';
  end if;
  return assign_occurrences_for_period_run(p_occurrence_id, p_instructor_id, p_scope, p_until, p_confirmed);
end $$;
revoke execute on function assign_occurrences_for_period(uuid, uuid, text, date, boolean)
  from public, anon;
grant  execute on function assign_occurrences_for_period(uuid, uuid, text, date, boolean)
  to authenticated, service_role;

-- ---- Decision 42a: clear a whole month from the Publish page ----------------
create or replace function clear_month_assignments(
  p_studio_id uuid, p_month date, p_clear_templates boolean default true)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_tz text; v_month_start date; v_month_end date;
  v_published boolean; v_has_bookings boolean;
  v_count int := 0; v_templates int := 0;
  rec record; v_res jsonb; v_old uuid; v_other uuid; v_dedupe text;
  v_affected uuid[] := '{}';
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers change the timetable' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  if v_tz is null then raise exception 'no such studio' using errcode = 'PT404'; end if;
  v_month_start := date_trunc('month', p_month)::date;
  v_month_end   := (v_month_start + interval '1 month' - interval '1 day')::date;

  -- A draft month (publication on, not yet published) is always clearable — no
  -- member can have booked into it. A published month (or a studio not using
  -- publication, where month_published is true by definition) is clearable only
  -- when no member has booked into it; otherwise change assignments class by
  -- class from the Schedule (Decision 25 offers no unpublish).
  v_published := month_published(p_studio_id, ((v_month_start + 14)::date + time '12:00') at time zone v_tz);
  select exists(
    select 1 from bookings b join class_occurrences o on o.id = b.occurrence_id
     where o.studio_id = p_studio_id and o.status = 'scheduled'
       and (o.starts_at at time zone v_tz)::date between v_month_start and v_month_end
       and b.status <> 'cancelled'
  ) into v_has_bookings;
  if v_published and v_has_bookings then
    raise exception 'This month is published and members have booked into it — change assignments class by class from the Schedule instead.'
      using errcode = 'PT409';
  end if;

  for rec in
    select o.id, o.instructor_id from class_occurrences o
     where o.studio_id = p_studio_id and o.status = 'scheduled'
       and o.instructor_id is not null
       and (o.starts_at at time zone v_tz)::date between v_month_start and v_month_end
     order by o.starts_at
  loop
    v_old := rec.instructor_id;
    begin
      v_res := move_occurrence(p_occurrence_id => rec.id, p_confirm => true,
                               p_clear_instructor => true);
      if coalesce((v_res ->> 'ok')::boolean, false) then
        v_count := v_count + 1;
        if not (v_old = any(v_affected)) then v_affected := v_affected || v_old; end if;
      end if;
    exception when others then null;   -- one stubborn class never aborts the clear
    end;
  end loop;

  -- Withdraw the affected instructors' pending digests, as the per-occurrence
  -- unassign does.
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

  -- The template too, if asked: future months start unassigned. Only the series
  -- with occurrences IN this month; existing occurrences in OTHER months are
  -- untouched (we cleared only this month's). At a switch-ON studio nulling the
  -- template re-fires tg_assign_after_series; this is a tool for switch-OFF.
  if p_clear_templates then
    update class_series cs set instructor_id = null
     where cs.studio_id = p_studio_id and cs.instructor_id is not null
       and cs.id in (
         select distinct o.series_id from class_occurrences o
          where o.studio_id = p_studio_id and o.series_id is not null
            and (o.starts_at at time zone v_tz)::date between v_month_start and v_month_end);
    get diagnostics v_templates = row_count;
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (p_studio_id, auth.uid(), 'month.assignments_cleared', 'studios', p_studio_id,
          jsonb_build_object('month', v_month_start, 'cleared', v_count,
                             'templates_cleared', v_templates, 'clear_templates', p_clear_templates));

  return jsonb_build_object('ok', true, 'cleared', v_count, 'templates_cleared', v_templates,
                            'month', to_char(v_month_start, 'FMMonth YYYY'));
end $$;
revoke execute on function clear_month_assignments(uuid, date, boolean) from public, anon;
grant  execute on function clear_month_assignments(uuid, date, boolean) to authenticated, service_role;
