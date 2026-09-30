-- Decision 45 follow-up — the cover-request PT403, and the guarded-caller sweep
-- widened to see it.
--
-- request_cover's auto-accept OFFER loop calls instructor_available_at for each
-- OTHER instructor. instructor_available_at is guarded on the caller's subject
-- identity (is_manager_up OR auth_instructor_id = the instructor OR service), so
-- when the caller is the instructor asking for cover (not a manager, not
-- service), the guard raises PT403 on the first foreign candidate and the whole
-- request fails. Decision 18 makes "ask for cover" an instructor's ONLY exit
-- from a class, so this path must never fail on the caller's role.
--
-- Fix, exactly the amendment-9 shape: instructor_available_at gains an unguarded
-- _run twin, becomes a thin guarded wrapper, and request_cover's loop calls the
-- twin. The guard still protects a direct client read; internal callers use the
-- twin.

-- The unguarded twin: instructor_available_at minus the caller-ownership guard.
-- SECURITY DEFINER, service-role only, like every other _run twin. A non-existent
-- instructor resolves to "not available" here (the wrapper raises PT403 for a
-- client; internal callers pass real ids).
create or replace function instructor_available_at_run(
  p_instructor_id uuid, p_starts_at timestamptz, p_ends_at timestamptz
) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_tz text; v_date date; v_dow int; v_from time; v_to time;
        v_sub uuid;
begin
  if p_instructor_id is null then
    return true;
  end if;

  select i.studio_id, s.timezone into v_studio, v_tz
    from instructors i join studios s on s.id = i.studio_id
   where i.id = p_instructor_id;
  if v_studio is null then
    return false;
  end if;

  -- Availability is stated in studio-local wall-clock terms, so the comparison
  -- has to happen there. Comparing UTC against a local time would make an
  -- instructor unavailable for half the year in Prague.
  v_date := (p_starts_at at time zone v_tz)::date;
  v_dow  := extract(dow from (p_starts_at at time zone v_tz))::int;
  v_from := (p_starts_at at time zone v_tz)::time;
  v_to   := (p_ends_at   at time zone v_tz)::time;

  -- 1. An explicit exception for that date wins over everything.
  if exists (select 1 from instructor_availability a
              where a.instructor_id = p_instructor_id and a.exception_date = v_date) then
    return exists (
      select 1 from instructor_availability a
       where a.instructor_id = p_instructor_id
         and a.exception_date = v_date
         and a.is_available
         and (a.starts_at_time is null or a.starts_at_time <= v_from)
         and (a.ends_at_time   is null or a.ends_at_time   >= v_to));
  end if;

  -- 2. An APPROVED submission whose month covers this date answers for it alone.
  select s.id into v_sub
    from availability_submissions s
   where s.instructor_id = p_instructor_id
     and s.status = 'approved'
     and v_date between s.period_start
                    and (s.period_start + interval '1 month' - interval '1 day')::date
   order by s.period_start desc
   limit 1;

  if v_sub is not null then
    return exists (
      select 1 from instructor_availability a
       where a.submission_id = v_sub
         and a.day_of_week = v_dow
         and a.approval_status = 'approved'
         and a.is_available
         and (a.starts_at_time is null or a.starts_at_time <= v_from)
         and (a.ends_at_time   is null or a.ends_at_time   >= v_to));
  end if;

  -- 3. No stated availability is not the same as being unavailable.
  if not exists (select 1 from instructor_availability a
                  where a.instructor_id = p_instructor_id
                    and a.day_of_week is not null
                    and a.approval_status = 'approved') then
    return true;
  end if;

  -- 4. The standing weekly pattern.
  return exists (
    select 1 from instructor_availability a
     where a.instructor_id = p_instructor_id
       and a.day_of_week = v_dow
       and a.approval_status = 'approved'
       and a.is_available
       and (a.effective_from is null or a.effective_from <= v_date)
       and (a.effective_to   is null or a.effective_to   >= v_date)
       and (a.starts_at_time is null or a.starts_at_time <= v_from)
       and (a.ends_at_time   is null or a.ends_at_time   >= v_to));
end $$;
revoke execute on function instructor_available_at_run(uuid, timestamptz, timestamptz) from public, anon, authenticated;
grant  execute on function instructor_available_at_run(uuid, timestamptz, timestamptz) to service_role;

-- The guarded wrapper: the caller-ownership guard, then delegate to the twin.
-- create or replace keeps its ACL (anon=false, authenticated=true, service_role).
create or replace function instructor_available_at(
  p_instructor_id uuid, p_starts_at timestamptz, p_ends_at timestamptz
) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid;
begin
  if p_instructor_id is null then
    return true;
  end if;
  select i.studio_id into v_studio from instructors i where i.id = p_instructor_id;
  if v_studio is null then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;
  if not is_manager_up(v_studio)
     and p_instructor_id is distinct from auth_instructor_id(v_studio)
     and not is_service_context() then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;
  return instructor_available_at_run(p_instructor_id, p_starts_at, p_ends_at);
end $$;

-- request_cover, re-issued from its newest definition (930000) with the offer
-- loop calling the unguarded twin. Everything else byte-for-byte.

CREATE OR REPLACE FUNCTION public.request_cover(p_occurrence_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o class_occurrences%rowtype; s studios%rowtype; st studio_settings%rowtype;
  v_instr uuid; v_req cover_requests%rowtype; v_hours numeric; v_urgent boolean;
  v_name text; n int; d record; v_offered int := 0;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  select * into s  from studios        where id = o.studio_id;
  select * into st from studio_settings where studio_id = o.studio_id;

  v_instr := auth_instructor_id(o.studio_id);
  if v_instr is null or v_instr is distinct from o.instructor_id then
    if not is_manager_up(o.studio_id) then
      raise exception 'only the instructor teaching this class may ask for cover'
        using errcode = 'PT403';
    end if;
    v_instr := o.instructor_id;
  end if;
  if v_instr is null then
    raise exception 'this class has nobody teaching it, so there is nothing to cover'
      using errcode = 'PT422';
  end if;
  if o.status <> 'scheduled' then
    raise exception 'this class is not running' using errcode = 'PT422';
  end if;
  if o.starts_at <= now() then
    raise exception 'this class has already started' using errcode = 'PT422';
  end if;

  insert into cover_requests (studio_id, occurrence_id, instructor_id, reason)
  values (o.studio_id, o.id, v_instr, nullif(btrim(p_reason), ''))
  on conflict (occurrence_id, instructor_id) where status = 'pending' do nothing
  returning * into v_req;

  if v_req.id is null then
    select * into v_req from cover_requests
     where occurrence_id = o.id and instructor_id = v_instr and status = 'pending';
    return jsonb_build_object('ok', true, 'already_open', true, 'request_id', v_req.id);
  end if;

  -- (c) If this class was CLAIMED (an approved shift application), record the
  -- handing-back on that application so reliability counts it. A no-op at an
  -- assigned-model studio, where there is no application.
  update shift_applications
     set withdrawn_at = now(),
         withdrawal_notice_hours = greatest(0, round(extract(epoch from o.starts_at - now()) / 3600))::int
   where occurrence_id = o.id and instructor_id = v_instr
     and status = 'approved' and withdrawn_at is null;

  select display_name into v_name from instructors where id = v_instr;
  v_hours  := extract(epoch from o.starts_at - now()) / 3600;
  v_urgent := v_hours <= coalesce(st.cover_escalation_hours, 4);

  n := queue_shift_notice_to_staff(
    o.studio_id,
    case when v_urgent then 'cover_urgent' else 'cover_requested' end,
    jsonb_build_object(
      'instructor_name', v_name, 'class_name', o.name,
      'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY, HH24:MI'),
      'hours_line', case when v_hours < 1 then round(v_hours * 60) || ' minutes'
                         else round(v_hours) || ' hour' || case when round(v_hours) = 1 then '' else 's' end end,
      'reason_line', case when nullif(btrim(coalesce(p_reason,'')), '') is null then ''
                          else 'They said: ' || btrim(p_reason) || E'\n\n' end,
      'booked_line', case when o.booked_count > 0
        then format('%s member%s booked.', o.booked_count, case when o.booked_count = 1 then ' is' else 's are' end)
        else 'Nobody has booked yet.' end,
      'cover_url', '/shifts/cover'),
    'cover_req:' || v_req.id || case when v_urgent then ':urgent' else '' end);

  if v_urgent then
    update cover_requests set escalated_at = now() where id = v_req.id;

    -- (a) Auto-accept is on and the class is inside the window: offer it to
    -- qualified, valid, available instructors with a login (not the requester,
    -- not anyone already teaching then). First to accept gets it — no cap check,
    -- an urgent cover is not hoarding a month.
    if coalesce(st.cover_auto_accept_enabled, false) then
      for d in
        select i.id, instructor_user_id(i.id) as user_id
          from instructors i
         where i.studio_id = o.studio_id and i.status = 'active' and i.id <> v_instr
           and instructor_qualified(i.id, o.class_type_id)
           and instructor_valid_on(i.id, (o.starts_at at time zone s.timezone)::date)
           and instructor_available_at_run(i.id, o.starts_at, o.ends_at)
           and not exists (
             select 1 from class_occurrences h
              where h.id <> o.id and h.instructor_id = i.id and h.status = 'scheduled'
                and tstzrange(h.starts_at, h.ends_at) && tstzrange(o.starts_at, o.ends_at))
      loop
        if d.user_id is not null and queue_shift_notice(o.studio_id, d.user_id, 'cover_available',
             jsonb_build_object('instructor_name', (select display_name from instructors where id = d.id),
               'studio_name', s.name, 'class_name', o.name,
               'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY, HH24:MI'),
               'booked_line', case when o.booked_count > 0
                 then format('%s member%s booked.', o.booked_count, case when o.booked_count = 1 then ' is' else 's are' end)
                 else 'Nobody has booked yet.' end,
               'href', instructor_portal_url(o.studio_id, '/instructor/shifts')),
             'cover_available:' || v_req.id || ':' || d.id) is not null
        then v_offered := v_offered + 1; end if;
      end loop;
    end if;
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (o.studio_id, auth.uid(), 'cover.requested', 'cover_requests', v_req.id,
          jsonb_build_object('occurrence_id', o.id, 'instructor_id', v_instr,
                             'urgent', v_urgent, 'notified', n, 'auto_offered', v_offered));

  return jsonb_build_object('ok', true, 'request_id', v_req.id, 'urgent', v_urgent,
                            'notified_staff', n, 'auto_offered', v_offered,
                            'still_assigned_to', v_instr);
end $function$;

-- anon surface stays EXACTLY TWELVE — the twin is service-role only.
do $$
declare v_n int;
begin
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and has_function_privilege('anon', p.oid, 'execute');
  if v_n <> 12 then
    raise exception 'anon surface is %, expected exactly twelve', v_n;
  end if;
end $$;

