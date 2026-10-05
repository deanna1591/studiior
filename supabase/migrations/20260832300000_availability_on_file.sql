-- Decision 46 amendment — the instructor app shows the availability the studio
-- entered (a standing weekly pattern), and does not nag for a covered month.
--
-- creates: instructor_month_covered(uuid, date)
-- re-issues: availability_submission_week(uuid, date), queue_availability_reminders(uuid)
--
-- A month's availability "on file" is EITHER the approved submission for that
-- month OR a standing weekly pattern (entered by the studio) whose dates cover
-- it — the precedence availabilityLine already uses on the Instructors list.
--
--  * instructor_month_covered is the ONE SQL definition of that state
--    ('submitted'|'approved'|'changes_requested'|'pattern'|'none'), read by the
--    reminder sweep, the Home reader and the page.
--  * availability_submission_week returns the pattern's ranges + source='pattern'
--    (+ pattern_ends_on) when no submission exists, so the page shows them.
--  * queue_availability_reminders skips an instructor whose month is covered
--    (instructor_month_covered <> 'none') or whose month is published.
--
-- sweep_availability_reminders is a thin per-studio delegator (it only loops
-- studios with availability_reminders_enabled and calls queue_...); the "due"
-- logic lives entirely in queue_availability_reminders, so only that is re-issued.
-- Decision 18 untouched. Anon stays THIRTEEN.

-- =============================================================================
-- (1) instructor_month_covered — submission wins (its status), else a covering
--     standing pattern ('pattern'), else 'none'. Mirrors availabilityLine.
-- =============================================================================
create function instructor_month_covered(p_instructor_id uuid, p_period_start date)
returns text language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_status text; v_end date;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(v_studio), false)
     and p_instructor_id is distinct from auth_instructor_id(v_studio)
     and not is_service_context() then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;

  -- A real submission for the month wins (draft is treated as no submission,
  -- exactly as availabilityLine does — it falls through to the pattern).
  select status into v_status from availability_submissions
   where instructor_id = p_instructor_id and period_start = p_period_start;
  if v_status in ('submitted','approved','changes_requested') then
    return v_status;
  end if;

  -- Else a standing weekly pattern covering the month (the standingCoverage
  -- shape: submission_id null, a day_of_week, approved, available, dates overlap).
  v_end := (p_period_start + interval '1 month' - interval '1 day')::date;
  if exists (
    select 1 from instructor_availability a
     where a.instructor_id = p_instructor_id
       and a.submission_id is null and a.day_of_week is not null
       and a.approval_status = 'approved' and a.is_available = true
       and (a.effective_from is null or a.effective_from <= v_end)
       and (a.effective_to is null or a.effective_to >= p_period_start)
  ) then
    return 'pattern';
  end if;

  return 'none';
end $$;
revoke execute on function instructor_month_covered(uuid, date) from public, anon;
grant  execute on function instructor_month_covered(uuid, date) to authenticated, service_role;

-- =============================================================================
-- (2) availability_submission_week — return the pattern's ranges + source when
--     no submission exists. Re-issued from 20260830760000 with the pattern path
--     added; the submission path is byte-for-byte.
-- =============================================================================
create or replace function availability_submission_week(
  p_instructor_id uuid, p_period_start date
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_sub availability_submissions%rowtype; v_end date;
        v_pattern_days jsonb; v_ends_on date; v_open boolean;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then
    raise exception 'no such instructor' using errcode = 'PT404';
  end if;
  if not coalesce(is_manager_up(v_studio), false)
     and p_instructor_id is distinct from auth_instructor_id(v_studio) then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;

  select * into v_sub from availability_submissions
   where instructor_id = p_instructor_id and period_start = p_period_start;

  -- A real submission exists (any status) — return it exactly as before.
  if v_sub.id is not null then
    return jsonb_build_object(
      'submission_id', v_sub.id,
      'status', coalesce(v_sub.status, 'none'),
      'source', 'submission',
      'note', v_sub.note,
      'submitted_at', v_sub.submitted_at,
      'reviewed_at', v_sub.reviewed_at,
      'period_start', p_period_start,
      'period_end', (p_period_start + interval '1 month' - interval '1 day')::date,
      'pattern_ends_on', null,
      'days', coalesce((
        select jsonb_agg(jsonb_build_object('day', day_of_week, 'ranges', ranges)
                         order by day_of_week)
          from (
            select a.day_of_week,
                   jsonb_agg(jsonb_build_object('from', to_char(a.starts_at_time,'HH24:MI'),
                                                'to',   to_char(a.ends_at_time,'HH24:MI'))
                             order by a.starts_at_time) as ranges
              from instructor_availability a
             where a.submission_id = v_sub.id and a.day_of_week is not null
             group by a.day_of_week) z
      ), '[]'::jsonb));
  end if;

  -- No submission: a covering standing pattern? Return its weekly ranges + end.
  v_end := (p_period_start + interval '1 month' - interval '1 day')::date;
  select coalesce(jsonb_agg(jsonb_build_object('day', day_of_week, 'ranges', ranges)
                            order by day_of_week), '[]'::jsonb),
         bool_or(ends_to is null),
         max(ends_to)
    into v_pattern_days, v_open, v_ends_on
    from (
      select a.day_of_week,
             jsonb_agg(jsonb_build_object('from', to_char(a.starts_at_time,'HH24:MI'),
                                          'to',   to_char(a.ends_at_time,'HH24:MI'))
                       order by a.starts_at_time) as ranges,
             min(a.effective_to) filter (where a.effective_to is not null) as ends_to,
             bool_or(a.effective_to is null) as any_open
        from instructor_availability a
       where a.instructor_id = p_instructor_id
         and a.submission_id is null and a.day_of_week is not null
         and a.approval_status = 'approved' and a.is_available = true
         and (a.effective_from is null or a.effective_from <= v_end)
         and (a.effective_to is null or a.effective_to >= p_period_start)
       group by a.day_of_week) z;

  if jsonb_array_length(v_pattern_days) > 0 then
    return jsonb_build_object(
      'submission_id', null, 'status', 'none', 'source', 'pattern',
      'note', null, 'submitted_at', null, 'reviewed_at', null,
      'period_start', p_period_start,
      'period_end', v_end,
      -- Open-ended wins (no end date); else the latest end across the pattern.
      'pattern_ends_on', case when v_open then null else v_ends_on end,
      'days', v_pattern_days);
  end if;

  -- Nothing on file.
  return jsonb_build_object(
    'submission_id', null, 'status', 'none', 'source', 'none',
    'note', null, 'submitted_at', null, 'reviewed_at', null,
    'period_start', p_period_start,
    'period_end', v_end,
    'pattern_ends_on', null,
    'days', '[]'::jsonb);
end $$;

-- =============================================================================
-- (3) queue_availability_reminders — skip an instructor whose month is covered
--     (instructor_month_covered <> 'none') or whose month is published. Re-issued
--     from 20260831930000; everything else byte-for-byte.
-- =============================================================================
create or replace function queue_availability_reminders(p_studio_id uuid)
returns int language plpgsql security definer set search_path = public as $$
declare
  v_cycle jsonb; v_tz text; v_today date; v_due date; v_period date;
  v_studio_name text; r record; n int := 0; v_wording text; v_published boolean;
begin
  select s.timezone, s.name into v_tz, v_studio_name from studios s where s.id = p_studio_id;
  if v_tz is null then return 0; end if;
  v_today := (now() at time zone v_tz)::date;

  v_cycle  := availability_cycle(p_studio_id);
  v_due    := (v_cycle ->> 'due_on')::date;
  v_period := (v_cycle ->> 'period_start')::date;

  -- On the due day, and every day after it while somebody has still not
  -- answered. Not before: a reminder three weeks early teaches people to ignore
  -- the next one.
  if v_today < v_due then
    return 0;
  end if;

  -- Decision 46 amendment: a published month is never asked for. "Published" is
  -- an actual schedule_publications row (NOT month_published(), which is true for
  -- a publication-off studio — those still collect availability normally).
  v_published := exists (select 1 from schedule_publications
                          where studio_id = p_studio_id and month = v_period);
  if v_published then
    return 0;
  end if;

  v_wording := case when v_today = v_due then 'today' else 'on ' || to_char(v_due, 'FMDD FMMonth') end;

  for r in
    select i.id, i.display_name, instructor_user_id(i.id) as user_id
      from instructors i
     where i.studio_id = p_studio_id and i.status = 'active'
       -- An instructor with no login has no address anywhere in the schema, so
       -- there is nobody to remind. They show on the staff list instead.
       and instructor_user_id(i.id) is not null
       -- Decision 46 amendment: skip a month already on file — an approved/
       -- submitted/changes_requested submission OR a covering standing pattern.
       -- instructor_month_covered is the one definition; 'none' means ask.
       and instructor_month_covered(i.id, v_period) = 'none'
  loop
    if queue_shift_notice(p_studio_id, r.user_id, 'availability_due',
         jsonb_build_object(
           'instructor_name', r.display_name,
           'studio_name', v_studio_name,
           'period', to_char(v_period, 'FMMonth YYYY'),
           'due_on', to_char(v_due, 'FMDD FMMonth'),
           'due_wording', v_wording,
           'href', instructor_portal_url(p_studio_id, '/instructor/availability')),
         -- Per person, per month, per DAY: one nudge a day at most, and a
         -- second month's chase is not deduped against the first.
         'avail_due:' || r.id || ':' || v_period || ':' || v_today) is not null
    then n := n + 1; end if;
  end loop;
  return n;
end $$;

-- The anon surface is unchanged — exactly THIRTEEN pre-login functions.
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % functions, expected exactly 13', n; end if;
end $$;
