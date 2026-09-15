-- =============================================================================
-- G — the 5-day roster deadline, and carry-forward on silence.
-- =============================================================================
-- Publishing a month (112) sends each instructor their roster; confirming it
-- (113) is one press. This is what happens when they say NOTHING. After a
-- deadline the studio sets (roster_confirm_days, default 5) from when they were
-- notified, a silent instructor's LAST month is carried into THIS one, so a
-- month is staffed rather than left open because somebody was on holiday and
-- missed a button.
--
-- OFF BY DEFAULT, PER TENANT. `carry_forward_enabled` is false, so a studio
-- that never turns it on sees none of this: the sweep skips it, the preview is
-- empty, and nothing is ever assigned on its behalf.
--
-- THE MATCH IS WEEKDAY + LOCAL CLOCK TIME + CLASS TYPE, never series id. A
-- series can be recreated, split or renamed; what an instructor actually agreed
-- to is "Tuesday 07:00 Reformer", and that is what carries.
--
-- ONLY WHAT WAS ASSIGNED AND CONFIRMED, not merely assigned. The source is last
-- month's classes that were theirs AND that they confirmed the month for AND did
-- not hand back through request_cover. A month that was itself carried on
-- silence is NOT a confirmed baseline — silence carries once from something an
-- instructor actually said yes to, and a silent month does not become the next
-- month's yes.
--
-- WHAT DOES NOT CARRY, AND WHY THE STUDIO IS TOLD: an archived (or deleted)
-- class type; a slot that was moved (the source pattern was a one-off exception,
-- not a standing class); a pattern with no matching open class this month; a
-- slot already staffed by somebody. Each is reported, per instructor.
--
-- WHAT CARRIES WITH A WARNING: a slot now outside the instructor's stated
-- availability. It is STILL carried — the studio decided to lean on last month
-- when nobody answered — but flagged, because the instructor may have changed
-- their hours for a reason. A warning, never a refusal.
--
-- ASSIGNED DIRECTLY, not through move_occurrence(), which hard-blocks a slot
-- outside the availability WINDOW — and carrying with a warning is the whole
-- point here. A guarded UPDATE into an OPEN slot only; a slot already assigned
-- is never overwritten, and the instructor exclusion still refuses a clash.
-- =============================================================================

alter table studio_settings
  add column if not exists carry_forward_enabled boolean not null default false,
  add column if not exists roster_confirm_days   int     not null default 5;
alter table studio_settings
  add constraint roster_confirm_days_sane check (roster_confirm_days between 1 and 31);

-- Stamped when a carry pass has run for an instructor-month, so the sweep does
-- it once. Distinct from confirmed_at: a carried month was NOT confirmed, and
-- must not seed next month's carry.
alter table roster_confirmations
  add column if not exists carried_at timestamptz;

-- -----------------------------------------------------------------------------
-- The plan for ONE instructor into ONE month: what would carry (with a warning
-- flag), and the report of what would not and why. Read-only, deterministic —
-- the preview and the apply both read it, so they cannot disagree.
--
-- Internal: closed to every client role. The guarded readers below reach it as
-- their definer (postgres), so a manager calling the preview runs this with the
-- definer's rights and needs no grant of their own (059's shape).
-- -----------------------------------------------------------------------------
create or replace function roster_carry_plan(p_studio_id uuid, p_instructor_id uuid, p_month date)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_tz text; v_this date; v_src date;
  v_src_from timestamptz; v_src_to timestamptz; v_this_from timestamptz; v_this_to timestamptz;
  v_confirmed boolean; v_carry jsonb; v_report jsonb;
begin
  select timezone into v_tz from studios where id = p_studio_id;
  if v_tz is null then return jsonb_build_object('source_confirmed', false, 'carry','[]'::jsonb, 'report','[]'::jsonb); end if;
  v_this := date_trunc('month', p_month)::date;
  v_src  := (v_this - interval '1 month')::date;
  v_src_from  := (v_src::timestamp)  at time zone v_tz;
  v_src_to    := ((v_src  + interval '1 month')::timestamp) at time zone v_tz;
  v_this_from := (v_this::timestamp) at time zone v_tz;
  v_this_to   := ((v_this + interval '1 month')::timestamp) at time zone v_tz;

  -- Only carry from a month the instructor actually confirmed.
  select exists (select 1 from roster_confirmations rc
                  where rc.studio_id = p_studio_id and rc.instructor_id = p_instructor_id
                    and rc.month = v_src and rc.confirmed_at is not null)
    into v_confirmed;
  if not v_confirmed then
    return jsonb_build_object('source_confirmed', false, 'carry','[]'::jsonb, 'report','[]'::jsonb);
  end if;

  -- Distinct standing patterns from last month: (weekday, local time, class
  -- type) of the instructor's confirmed, non-handed-back classes. all_moved is
  -- true when every source class for that key was a moved one-off (is_exception)
  -- — no standing slot to carry.
  with src as (
    select o.class_type_id,
           extract(dow from (o.starts_at at time zone v_tz))::int as dow,
           (o.starts_at at time zone v_tz)::time as tod,
           bool_and(o.is_exception) as all_moved
      from class_occurrences o
     where o.studio_id = p_studio_id and o.instructor_id = p_instructor_id
       and o.starts_at >= v_src_from and o.starts_at < v_src_to
       and not exists (select 1 from cover_requests cr
                        where cr.occurrence_id = o.id and cr.instructor_id = p_instructor_id
                          and cr.status in ('pending','approved'))
     group by o.class_type_id,
              extract(dow from (o.starts_at at time zone v_tz))::int,
              (o.starts_at at time zone v_tz)::time
  ),
  resolved as (
    select s.*, ct.status as ct_status, coalesce(ct.name, 'a class') as ct_name,
           to_char((date '2024-01-07' + s.dow), 'FMDay') as dow_name,
           to_char(s.tod, 'HH24:MI') as tod_txt
      from src s left join class_types ct on ct.id = s.class_type_id
  ),
  cand as (
    select r.*,
      -- Open, scheduled, non-exception classes this month at the same key: the
      -- slots we can carry into.
      (select jsonb_agg(jsonb_build_object('id', o.id, 'starts_at', o.starts_at, 'ends_at', o.ends_at))
         from class_occurrences o
        where o.studio_id = p_studio_id and o.class_type_id = r.class_type_id
          and o.starts_at >= v_this_from and o.starts_at < v_this_to
          and extract(dow from (o.starts_at at time zone v_tz))::int = r.dow
          and (o.starts_at at time zone v_tz)::time = r.tod
          and o.status = 'scheduled' and o.instructor_id is null and not o.is_exception
      ) as open_targets,
      -- Is there ANY class at that key this month — to tell "already staffed"
      -- from "no match".
      exists (select 1 from class_occurrences o
               where o.studio_id = p_studio_id and o.class_type_id = r.class_type_id
                 and o.starts_at >= v_this_from and o.starts_at < v_this_to
                 and extract(dow from (o.starts_at at time zone v_tz))::int = r.dow
                 and (o.starts_at at time zone v_tz)::time = r.tod
                 and o.status = 'scheduled') as any_exact
      from resolved r
  )
  -- What carries: every open target of a live pattern, with a warn flag when the
  -- slot is now outside the instructor's stated hours.
  select coalesce(jsonb_agg(jsonb_build_object(
           'id',   (t ->> 'id')::uuid,
           'warn', not instructor_available_at(p_instructor_id, (t ->> 'starts_at')::timestamptz, (t ->> 'ends_at')::timestamptz)
         )), '[]'::jsonb)
    into v_carry
    from cand c cross join lateral jsonb_array_elements(coalesce(c.open_targets, '[]'::jsonb)) t
   where c.ct_status = 'active' and not c.all_moved and c.open_targets is not null;

  -- The report the studio reads: everything not carried, plus a warning line for
  -- each carried-but-outside-availability slot.
  with cand as (
    select r.*,
      (select jsonb_agg(jsonb_build_object('id', o.id, 'starts_at', o.starts_at, 'ends_at', o.ends_at))
         from class_occurrences o
        where o.studio_id = p_studio_id and o.class_type_id = r.class_type_id
          and o.starts_at >= v_this_from and o.starts_at < v_this_to
          and extract(dow from (o.starts_at at time zone v_tz))::int = r.dow
          and (o.starts_at at time zone v_tz)::time = r.tod
          and o.status = 'scheduled' and o.instructor_id is null and not o.is_exception) as open_targets,
      exists (select 1 from class_occurrences o
               where o.studio_id = p_studio_id and o.class_type_id = r.class_type_id
                 and o.starts_at >= v_this_from and o.starts_at < v_this_to
                 and extract(dow from (o.starts_at at time zone v_tz))::int = r.dow
                 and (o.starts_at at time zone v_tz)::time = r.tod
                 and o.status = 'scheduled') as any_exact
      from (
        select s.*, ct.status as ct_status, coalesce(ct.name, 'a class') as ct_name,
               to_char((date '2024-01-07' + s.dow), 'FMDay') as dow_name,
               to_char(s.tod, 'HH24:MI') as tod_txt
          from (
            select o.class_type_id,
                   extract(dow from (o.starts_at at time zone v_tz))::int as dow,
                   (o.starts_at at time zone v_tz)::time as tod,
                   bool_and(o.is_exception) as all_moved
              from class_occurrences o
             where o.studio_id = p_studio_id and o.instructor_id = p_instructor_id
               and o.starts_at >= v_src_from and o.starts_at < v_src_to
               and not exists (select 1 from cover_requests cr
                                where cr.occurrence_id = o.id and cr.instructor_id = p_instructor_id
                                  and cr.status in ('pending','approved'))
             group by o.class_type_id,
                      extract(dow from (o.starts_at at time zone v_tz))::int,
                      (o.starts_at at time zone v_tz)::time
          ) s left join class_types ct on ct.id = s.class_type_id
      ) r
  )
  select coalesce(jsonb_agg(row_obj order by row_obj ->> 'label'), '[]'::jsonb) into v_report from (
    select jsonb_build_object(
             'label', dow_name || ' ' || tod_txt || ' · ' || ct_name,
             'carried', false,
             'reason', case
               when ct_status is null      then 'class type no longer exists'
               when ct_status = 'archived' then 'class type archived'
               when all_moved              then 'moved — the source class was a one-off, not a standing slot'
               when open_targets is null and any_exact then 'already staffed this month'
               else 'no matching class this month' end) as row_obj
      from cand
     where ct_status is distinct from 'active' or all_moved or open_targets is null
    union all
    select jsonb_build_object(
             'label', c.dow_name || ' ' || c.tod_txt || ' · ' || c.ct_name,
             'carried', true,
             'reason', 'carried, but now outside the instructor''s stated availability') as row_obj
      from cand c cross join lateral jsonb_array_elements(coalesce(c.open_targets, '[]'::jsonb)) t
     where c.ct_status = 'active' and not c.all_moved and c.open_targets is not null
       and not instructor_available_at(p_instructor_id, (t ->> 'starts_at')::timestamptz, (t ->> 'ends_at')::timestamptz)
  ) z;

  return jsonb_build_object('source_confirmed', true,
    'carry', coalesce(v_carry, '[]'::jsonb), 'report', coalesce(v_report, '[]'::jsonb));
end $$;
revoke execute on function roster_carry_plan(uuid, uuid, date) from public, anon, authenticated;
grant  execute on function roster_carry_plan(uuid, uuid, date) to service_role;

-- -----------------------------------------------------------------------------
-- Which instructors are eligible to be carried into a month: notified, silent,
-- past the studio's deadline, and not yet carried. Internal.
-- -----------------------------------------------------------------------------
create or replace function roster_carry_due(p_studio_id uuid, p_month date)
returns setof uuid
language sql
stable
security definer
set search_path to 'public'
as $$
  select rc.instructor_id
    from roster_confirmations rc
    join studio_settings ss on ss.studio_id = rc.studio_id
   where rc.studio_id = p_studio_id
     and rc.month = date_trunc('month', p_month)::date
     and coalesce(ss.carry_forward_enabled, false)
     and rc.notified_at is not null
     and rc.confirmed_at is null
     and rc.carried_at is null
     and now() >= rc.notified_at + (coalesce(ss.roster_confirm_days, 5) || ' days')::interval;
$$;
revoke execute on function roster_carry_due(uuid, date) from public, anon, authenticated;
grant  execute on function roster_carry_due(uuid, date) to service_role;

-- -----------------------------------------------------------------------------
-- The preview: for a month, every silent-past-deadline instructor with what
-- would carry and what would not. Read-only. Manager-up (or service).
-- -----------------------------------------------------------------------------
create or replace function roster_carry_preview(p_studio_id uuid, p_month date)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_rows jsonb; v_enabled boolean;
begin
  if not (coalesce(is_manager_up(p_studio_id), false) or is_service_context()) then
    raise exception 'only owners and managers see the carry-forward plan' using errcode = 'PT403';
  end if;
  select coalesce(carry_forward_enabled, false) into v_enabled from studio_settings where studio_id = p_studio_id;
  if not coalesce(v_enabled, false) then
    return jsonb_build_object('enabled', false, 'month', date_trunc('month', p_month)::date, 'instructors', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'instructor_id', i.id, 'instructor_name', i.display_name,
           'carry_count', jsonb_array_length(plan -> 'carry'),
           'report', plan -> 'report') order by i.display_name), '[]'::jsonb)
    into v_rows
    from roster_carry_due(p_studio_id, p_month) d
    join instructors i on i.id = d
    cross join lateral roster_carry_plan(p_studio_id, d, p_month) plan
   where (plan ->> 'source_confirmed')::boolean;

  return jsonb_build_object('enabled', true,
    'month', date_trunc('month', p_month)::date, 'instructors', coalesce(v_rows, '[]'::jsonb));
end $$;
revoke execute on function roster_carry_preview(uuid, date) from public, anon;
grant  execute on function roster_carry_preview(uuid, date) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- The apply: carry each silent instructor's roster into the month, assigning
-- the open matches directly and marking the row carried. Manager-up (or the
-- sweep, in service context). Idempotent — a carried row is skipped next time,
-- and an already-staffed target is never overwritten.
-- -----------------------------------------------------------------------------
create or replace function carry_forward_roster(p_studio_id uuid, p_month date)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_month date; v_inst uuid; v_plan jsonb; v_target jsonb;
  v_assigned int; v_total_assigned int := 0; v_instructors int := 0; v_clashes int := 0;
begin
  if not (coalesce(is_manager_up(p_studio_id), false) or is_service_context()) then
    raise exception 'only owners and managers carry a roster forward' using errcode = 'PT403';
  end if;
  v_month := date_trunc('month', p_month)::date;

  for v_inst in select * from roster_carry_due(p_studio_id, p_month) loop
    v_plan := roster_carry_plan(p_studio_id, v_inst, v_month);
    v_assigned := 0;

    for v_target in select * from jsonb_array_elements(v_plan -> 'carry') loop
      begin
        -- Direct, guarded UPDATE into an OPEN slot. Not move_occurrence(): that
        -- refuses a slot outside the availability window, and carrying with a
        -- warning is exactly what this does instead. The instructor exclusion
        -- still refuses a genuine double-booking.
        update class_occurrences
           set instructor_id = v_inst, assigned_by = auth.uid()
         where id = (v_target ->> 'id')::uuid
           and instructor_id is null and status = 'scheduled';
        if found then v_assigned := v_assigned + 1; end if;
      exception when exclusion_violation then
        -- They are already teaching then — leave it, it will show as unstaffed
        -- and the studio decides.
        v_clashes := v_clashes + 1;
      end;
    end loop;

    update roster_confirmations set carried_at = now()
     where studio_id = p_studio_id and instructor_id = v_inst and month = v_month;

    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (p_studio_id, auth.uid(), 'roster.carried_forward', 'roster_confirmations', v_inst,
            jsonb_build_object('month', v_month, 'assigned', v_assigned,
                               'report', v_plan -> 'report'));

    v_total_assigned := v_total_assigned + v_assigned;
    v_instructors := v_instructors + 1;
  end loop;

  return jsonb_build_object('ok', true, 'month', v_month,
    'instructors_carried', v_instructors, 'classes_assigned', v_total_assigned, 'clashes', v_clashes);
end $$;
revoke execute on function carry_forward_roster(uuid, date) from public, anon;
grant  execute on function carry_forward_roster(uuid, date) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- The sweep. Across every studio with the switch on, carry each month that has
-- a silent-past-deadline instructor. Service-role only; idempotent.
-- -----------------------------------------------------------------------------
create or replace function sweep_roster_carry()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_pair record; v_studios int := 0; v_assigned int := 0; r jsonb;
begin
  if not is_service_context() then
    raise exception 'service role only' using errcode = 'PT403';
  end if;
  for v_pair in
    select distinct rc.studio_id, rc.month
      from roster_confirmations rc
      join studio_settings ss on ss.studio_id = rc.studio_id
     where coalesce(ss.carry_forward_enabled, false)
       and rc.notified_at is not null and rc.confirmed_at is null and rc.carried_at is null
       and now() >= rc.notified_at + (coalesce(ss.roster_confirm_days, 5) || ' days')::interval
  loop
    r := carry_forward_roster(v_pair.studio_id, v_pair.month);
    v_studios := v_studios + 1;
    v_assigned := v_assigned + coalesce((r ->> 'classes_assigned')::int, 0);
  end loop;
  return jsonb_build_object('ok', true, 'passes', v_studios, 'classes_assigned', v_assigned);
end $$;
revoke execute on function sweep_roster_carry() from public, anon, authenticated;
grant  execute on function sweep_roster_carry() to service_role;

-- Daily is enough — the deadline is measured in days, not minutes.
select cron.schedule('studiior-roster-carry', '20 3 * * *', $job$select sweep_roster_carry()$job$);
