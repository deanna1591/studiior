-- =============================================================================
-- 065  The commitment measures instructors; it does not schedule them
-- =============================================================================
-- Decision 18 gave `instructor_commitments` two jobs and only one of them was
-- ever right. It is a HIRING EXPECTATION and a PERFORMANCE MEASURE — nine to
-- twelve classes a week over a three-month term, agreed when somebody is taken
-- on and reviewed against what they actually taught. It is not a scheduling
-- input, and it must never reach booking, assignment eligibility or anything a
-- member sees.
--
-- 061 ranked candidates by DEFICIT AGAINST THE WEEKLY TARGET, which is a true
-- number with a false meaning. A studio running 35 classes a week across six
-- instructors cannot give anyone twelve, so "furthest below their target" would
-- have appeared on every line of every run summary, describing a gap the studio
-- has no way to close and the engine no business trying to. Worse, the studio
-- that then hires a seventh instructor sees the engine start starving everyone
-- toward a number that was never a schedule.
--
-- Distribution is by FEWEST CLASSES ASSIGNED THAT WEEK, full stop. That is what
-- the no-commitment fallback already did, so this deletes a branch rather than
-- adding one: `commitment_fallback` and `no_commitment_for` go with it, because
-- with no other behaviour to fall back FROM there is nothing to report. Every
-- assigned line now reads "3 classes that week, fewest of the candidates".
--
-- The table stays and the terms go on being recorded. `commitment_shortfall`
-- stays in the Morning Brief: an instructor persistently under what they agreed
-- to is a conversation worth surfacing in week three rather than month three.
-- It is a management signal, and `commitment_report()` below is the rest of
-- that job — per instructor, over the commitment's own period, against the
-- agreed minimum.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- The engine stops reading the agreement
-- -----------------------------------------------------------------------------
-- Rebuilt from 061's FILE. Everything except the candidate ranking, the reason
-- line and the two fallback fields is 061's text unchanged.
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
    v_picked := null; v_picked_name := null;

    select i.id, i.display_name, x.this_week
      into cand
      from instructors i
      join lateral (
        -- The whole ranking input: how many classes this person already has
        -- that week. NOT measured against their commitment — that agreement is
        -- how the studio reviews them, not how the studio staffs a Tuesday.
        select (select count(*)::int from class_occurrences w
                 where w.instructor_id = i.id
                   and w.status <> 'cancelled'
                   and date_trunc('week', (w.starts_at at time zone v_tz)::date)::date = v_week
               ) as this_week
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
     -- Deterministic, so a re-run is stable: fewest classes, then the id. The
     -- id is arbitrary and that is the point — it is STABLE.
     order by x.this_week asc, i.id asc
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

    v_picked := cand.id; v_picked_name := cand.display_name;

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
      -- The working: why this person and not the other one. One sentence now,
      -- because there is one rule.
      'why', format('%s classes that week, fewest of the candidates', cand.this_week));
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
    'detail', v_log);
end $$;

-- -----------------------------------------------------------------------------
-- The availability window stops being defaulted from the agreement
-- -----------------------------------------------------------------------------
-- 061 filled a blank effective_from/effective_to from the live commitment, so
-- the terms would not "drift apart" from the pattern. But the validity window
-- is a HARD gate — the engine, the cover board's candidate list and
-- move_occurrence() all refuse outside it — so defaulting it from the agreement
-- made the agreement decide who can be scheduled, by a back door. A commitment
-- reaching its end date silently made somebody unschedulable, which is the
-- exact coupling this migration exists to cut.
--
-- Blank now means blank: a pattern with no dates is open-ended, which is what
-- an instructor with no stated end has agreed to. Both screens that call this
-- already send explicit dates when a studio types them.
create or replace function set_instructor_availability_rows(
  p_instructor_id  uuid,
  p_days           jsonb,
  p_effective_from date default null,
  p_effective_to   date default null
) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_studio uuid;
  v_from   date := p_effective_from;
  v_to     date := p_effective_to;
  d        jsonb;
  r        jsonb;
  v_day    int;
  n        int := 0;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then
    raise exception 'no such instructor' using errcode = 'PT404';
  end if;
  -- Checked here as well as in the policies, because this function is
  -- SECURITY DEFINER and the policies are not what stops it.
  if not is_manager_up(v_studio)
     and p_instructor_id is distinct from auth_instructor_id(v_studio) then
    raise exception 'only the studio or the instructor may set their availability'
      using errcode = 'PT403';
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

-- -----------------------------------------------------------------------------
-- What the commitment IS for
-- -----------------------------------------------------------------------------
-- Actual classes per week against the agreed minimum, per instructor, over the
-- commitment's own period — not a trailing window, because the agreement has a
-- term and the review is against the term.
--
-- Counted through `instructor_weekly_load()`, the same function
-- `commitment_shortfall` uses, so the brief and the report cannot disagree
-- about what a week contained. Complete weeks only: the current week is a
-- number going up, and putting it in a performance measure makes every
-- instructor look short every Monday.
create or replace function commitment_report(p_studio_id uuid)
returns table (
  instructor_id   uuid,
  instructor_name text,
  starts_on       date,
  ends_on         date,
  min_per_week    int,
  target_per_week int,
  weeks_measured  int,
  weeks_under     int,
  weeks_at_or_over int,
  average_per_week numeric,
  recent_average  numeric,
  earlier_average numeric,
  trend           text,
  standing        text
) language plpgsql stable security definer set search_path = public as $$
declare v_tz text;
begin
  if not is_manager_up(p_studio_id) then
    raise exception 'only owners and managers see how instructors are tracking'
      using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  if v_tz is null then
    raise exception 'no such studio' using errcode = 'PT404';
  end if;

  return query
  with terms as (
    select c.instructor_id as iid, i.display_name as iname,
           c.starts_on as son, c.ends_on as eon,
           c.min_per_week as mpw, c.target_per_week as tpw,
           -- Complete weeks between the term's start and the earlier of its end
           -- and last Sunday.
           greatest(0, (
             (least(coalesce(c.ends_on, 'infinity'::date),
                    date_trunc('week', (now() at time zone v_tz)::date)::date - 1)
              - date_trunc('week', c.starts_on)::date + 1) / 7
           )::int) as wks
      from instructor_commitments c
      join instructors i on i.id = c.instructor_id
     where c.studio_id = p_studio_id
       and c.status = 'active'
       and i.status = 'active'
  ),
  loads as (
    select t.*, l.week_start, l.classes
      from terms t
      left join lateral (
        select * from instructor_weekly_load(t.iid, greatest(t.wks, 1))
      ) l on l.week_start >= date_trunc('week', t.son)::date
         and (t.eon is null or l.week_start <= t.eon)
  ),
  agg as (
    select iid, iname, son, eon, mpw, tpw,
           count(week_start)::int as measured,
           count(*) filter (where classes < mpw)::int as under,
           count(*) filter (where classes >= mpw)::int as over,
           round(avg(classes)::numeric, 1) as avg_all,
           round(avg(classes) filter (
             where week_start > coalesce(
               (select max(week_start) from loads l2 where l2.iid = loads.iid) - 28, week_start))
             ::numeric, 1) as avg_recent,
           round(avg(classes) filter (
             where week_start <= coalesce(
               (select max(week_start) from loads l2 where l2.iid = loads.iid) - 28, week_start))
             ::numeric, 1) as avg_earlier
      from loads
     group by iid, iname, son, eon, mpw, tpw
  )
  select a.iid, a.iname, a.son, a.eon, a.mpw, a.tpw,
         a.measured, a.under, a.over,
         a.avg_all, a.avg_recent, a.avg_earlier,
         case when a.avg_recent is null or a.avg_earlier is null then 'not enough history'
              when a.avg_recent > a.avg_earlier then 'up'
              when a.avg_recent < a.avg_earlier then 'down'
              else 'flat' end,
         -- Against the MINIMUM, which is what was agreed. The target is
         -- recorded and reported and is deliberately not a pass mark: a studio
         -- with fewer classes than instructors cannot hand anybody their target
         -- and should not be told its whole roster is failing.
         case when a.measured = 0 then 'too early'
              when a.avg_all >= a.mpw then 'meeting the minimum'
              when a.under = a.measured then 'under every week'
              else 'under on some weeks' end
    from agg a
   order by a.avg_all nulls last, a.iname;
end $$;

revoke execute on function assign_instructors_run(uuid, date, date, boolean)
                                                  from public, anon, authenticated;
revoke execute on function set_instructor_availability_rows(uuid, jsonb, date, date)
                                                  from public, anon, authenticated;
revoke execute on function commitment_report(uuid) from public, anon, authenticated;
-- Manager-up, guarded inside. The grant is not the guard.
grant execute on function commitment_report(uuid) to authenticated;

comment on table instructor_commitments is
  'The hiring expectation: classes per week over an agreed term. A PERFORMANCE '
  'MEASURE and a reporting input — read by commitment_report() and by the '
  'commitment_shortfall insight. Never a scheduling input: it must not affect '
  'booking, assignment eligibility, availability windows, or anything a member '
  'sees. See Decision 18.';
