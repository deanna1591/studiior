-- Decision 58 — the instructor app opens on the next week they teach, asks for
-- nothing when confirmations are off, and lets an instructor ask a NAMED
-- colleague for cover (who confirms from their end).
--
-- re-issues: instructor_assignment_requests(uuid), series_confirmation_summary(uuid),
--            sweep_week_confirmations(), instructor_week(uuid,date,date),
--            instructor_week(uuid,date), accept_cover(uuid),
--            sweep_cover_escalations(), instructor_open_classes(uuid),
--            cover_available_to(uuid), approve_cover_request(uuid,text,uuid),
--            request_cover(uuid,text,uuid)
-- creates:   instructor_next_teaching_week(uuid,date), instructor_colleagues(uuid),
--            decline_directed_cover(uuid)
--
-- Decision 18 is UNTOUCHED: an instructor never releases themselves, and a cover
-- becomes final only by staff approval or the studio's cover_auto_accept switch.
-- A directed ask is a new WAY to reach one of those two, never a third path.
-- Anon surface stays EXACTLY THIRTEEN.

-- =============================================================================
-- Schema: the named colleague, and the "they agreed, awaiting approval" status.
-- cover_requests.status is TEXT with a CHECK, not an enum, so a new value is a
-- CHECK widening (no separate enum migration).
-- =============================================================================
alter table cover_requests
  add column if not exists asked_instructor_id uuid references instructors(id) on delete set null;

alter table cover_requests drop constraint if exists cover_requests_status_check;
alter table cover_requests add constraint cover_requests_status_check
  check (status = any (array['pending','accepted_pending','approved','declined','withdrawn']));

-- Two templates. Staff mail when a directed colleague agrees but the studio
-- approves cover itself; and the requester's note when the named colleague can't
-- (or doesn't answer) and it opens to everyone.
insert into notification_templates (key, subject, text_body, html_body, note) values
('cover_needs_approval',
 'A cover is agreed — approve it',
 E'Hi,\n\n{taker_name} has agreed to cover {requester_name}''s {class_name} on {when}.\n\nApprove it in Shifts → Cover: {cover_url}\n\n{studio_name}',
 '<p>Hi,</p><p><strong>{taker_name}</strong> has agreed to cover {requester_name}&rsquo;s <strong>{class_name}</strong> on {when}.</p><p><a href="{cover_url}">Approve it in Shifts &rarr; Cover</a></p><p>{studio_name}</p>',
 'Decision 58. A directed cover the colleague confirmed, at a studio that approves cover itself. Staff approve with one tap.'),
('cover_colleague_declined',
 '{colleague_name} can''t cover {class_name}',
 E'Hi {instructor_name},\n\n{colleague_name} isn''t able to cover your {class_name} on {when}, so it is now open to everyone. You are still down to teach it until someone covers it.\n\n{studio_name}',
 '<p>Hi {instructor_name},</p><p>{colleague_name} isn&rsquo;t able to cover your <strong>{class_name}</strong> on {when}, so it is now open to everyone. You are still down to teach it until someone covers it.</p><p>{studio_name}</p>',
 'Decision 58. The person you asked in particular said no (or did not answer in time); the request opened to everyone.')
on conflict (key) do nothing;

-- =============================================================================
-- (2) Confirmations off = nothing to confirm.
-- =============================================================================

-- instructor_assignment_requests — return NO rows when assignment_confirmations
-- is off (including requests stamped while it was on). Re-issued from 20260831770000.
create or replace function instructor_assignment_requests(p_instructor_id uuid)
returns table(occurrence_id uuid, name text, local_date date, local_start text,
              local_end text, room_name text, series_id uuid, series_name text)
language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_tz text;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(v_studio), false)
     and p_instructor_id is distinct from auth_instructor_id(v_studio)
     and not is_service_context() then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;
  -- Decision 58: the switch silences the whole confirmation surface. Nothing is
  -- deleted; turning it back on resumes exactly where it left off.
  if not coalesce((select assignment_confirmations from studio_settings where studio_id = v_studio), false) then
    return;
  end if;
  select timezone into v_tz from studios where id = v_studio;
  return query
  select o.id, o.name, (o.starts_at at time zone v_tz)::date,
         to_char(o.starts_at at time zone v_tz, 'HH24:MI'),
         to_char(o.ends_at   at time zone v_tz, 'HH24:MI'),
         r.name, o.series_id, ser.name
    from class_occurrences o
    left join rooms r on r.id = o.room_id
    left join class_series ser on ser.id = o.series_id
   where o.instructor_id = p_instructor_id and o.status = 'scheduled'
     and o.starts_at > now()
     and o.assignment_requested_at is not null and o.assignment_confirmed_at is null
     and month_published(v_studio, o.starts_at)
   order by o.starts_at;
end $$;

-- series_confirmation_summary — null when the switch is off (staff series page
-- shows no "N of M confirmed"). Re-issued from its NEWEST body (20260831780000,
-- which carries by_studio/by_instructor) with ONE added gate.
create or replace function series_confirmation_summary(p_series_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_total int; v_conf int; v_by_studio int; v_by_instr int;
begin
  select studio_id into v_studio from class_series where id = p_series_id;
  if v_studio is null then raise exception 'no such series' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(v_studio), false) and not is_service_context() then
    raise exception 'only owners and managers see the timetable' using errcode = 'PT403';
  end if;
  if not coalesce((select assignment_confirmations from studio_settings where studio_id = v_studio), false) then
    return null;
  end if;
  select count(*),
         count(*) filter (where assignment_confirmed_at is not null),
         count(*) filter (where assignment_confirmed_at is not null and assignment_confirmed_by is not null),
         count(*) filter (where assignment_confirmed_at is not null and assignment_confirmed_by is null)
    into v_total, v_conf, v_by_studio, v_by_instr
    from class_occurrences
   where series_id = p_series_id and status = 'scheduled' and starts_at > now()
     and assignment_requested_at is not null;
  if coalesce(v_total, 0) = 0 then return null; end if;
  return jsonb_build_object('confirmed', v_conf, 'total', v_total,
                            'by_studio', v_by_studio, 'by_instructor', v_by_instr);
end $$;

-- sweep_week_confirmations — skip a studio whose assignment_confirmations is off
-- (the setting that says "nothing to confirm" silences the weekly cycle too).
-- Re-issued from 20260831930000 with ONE added gate.
create or replace function sweep_week_confirmations()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  s record; r record;
  v_tz text; v_today date; v_dow int; v_week date; v_n int;
  n_ask int := 0; n_remind int := 0; n_escalate int := 0; v_studios int := 0;
  v_sum jsonb;
begin
  if not is_service_context() then
    raise exception 'the confirmation sweep is a background job' using errcode = 'PT403';
  end if;

  for s in
    select st.id, st.name, st.timezone,
           coalesce(cfg.week_confirm_enabled, true)        as enabled,
           coalesce(cfg.assignment_confirmations, false)   as confirmations_on,
           coalesce(cfg.week_confirm_ask_dow, 4)           as ask_dow,
           coalesce(cfg.week_confirm_remind_dow, 6)        as remind_dow,
           coalesce(cfg.week_confirm_escalate_dow, 0)      as esc_dow,
           coalesce(cfg.week_confirm_escalate_days, 3)     as esc_days
      from studios st
      left join studio_settings cfg on cfg.studio_id = st.id
     where st.status = 'active'
     order by st.id
  loop
    v_studios := v_studios + 1;
    -- Decision 58: confirmations off → the sweep sends nothing for this studio.
    if not s.enabled or not s.confirmations_on then continue; end if;

    v_tz    := s.timezone;
    v_today := (now() at time zone v_tz)::date;
    v_dow   := extract(dow from v_today)::int;

    -- ---- ask, for the week AHEAD ------------------------------------------
    if v_dow = s.ask_dow then
      v_week := studio_week_start(s.id, v_today) + 7;
      for r in
        select i.id, i.display_name, instructor_user_id(i.id) as user_id, count(*)::int as n
          from instructors i
          join class_occurrences o on o.instructor_id = i.id and o.status = 'scheduled'
         where i.studio_id = s.id and i.status = 'active'
           and instructor_user_id(i.id) is not null
           and (o.starts_at at time zone v_tz)::date between v_week and v_week + 6
           and month_published(s.id, o.starts_at)
         group by i.id, i.display_name
      loop
        if queue_shift_notice(s.id, r.user_id, 'week_confirm_ask',
             jsonb_build_object('instructor_name', r.display_name, 'studio_name', s.name,
                                'count', r.n, 'week', to_char(v_week, 'FMDD FMMonth'),
                                'href', instructor_portal_url(s.id, '/instructor/schedule')),
             'week_ask:' || r.id || ':' || v_week) is not null
        then n_ask := n_ask + 1; end if;
      end loop;
    end if;

    -- ---- remind, once, and only if something is unanswered -----------------
    if v_dow = s.remind_dow then
      v_week := studio_week_start(s.id, v_today) + 7;
      for r in
        select i.id, i.display_name, instructor_user_id(i.id) as user_id,
               (instructor_week(i.id, v_week) ->> 'unanswered')::int as n
          from instructors i
         where i.studio_id = s.id and i.status = 'active'
           and instructor_user_id(i.id) is not null
      loop
        if r.n > 0 and queue_shift_notice(s.id, r.user_id, 'week_confirm_reminder',
             jsonb_build_object('instructor_name', r.display_name, 'studio_name', s.name,
                                'count', r.n, 'week', to_char(v_week, 'FMDD FMMonth'),
                                'href', instructor_portal_url(s.id, '/instructor/schedule')),
             'week_remind:' || r.id || ':' || v_week) is not null
        then n_remind := n_remind + 1; end if;
      end loop;
    end if;

    -- ---- escalate, to the studio, about the next few days only -------------
    if v_dow = s.esc_dow then
      v_sum := unconfirmed_summary(s.id, studio_week_start(s.id, v_today) + 7, s.esc_days);
      if coalesce((v_sum ->> 'classes')::int, 0) = 0 then
        v_sum := unconfirmed_summary(s.id, studio_week_start(s.id, v_today), s.esc_days);
      end if;
      if coalesce((v_sum ->> 'classes')::int, 0) > 0 then
        v_n := queue_shift_notice_to_staff(s.id, 'week_unconfirmed',
          jsonb_build_object(
            'line', v_sum ->> 'line',
            'days', s.esc_days,
            'detail', coalesce((
              select string_agg(format('%s — %s class(es), next %s',
                                       d ->> 'name', d ->> 'classes',
                                       to_char((d ->> 'next')::timestamptz at time zone v_tz,
                                               'FMDay HH24:MI')), E'\n')
                from jsonb_array_elements(v_sum -> 'detail') d), '')),
          'week_escalate:' || s.id || ':' || v_today);
        if v_n > 0 then n_escalate := n_escalate + 1; end if;
      end if;
    end if;
  end loop;

  return jsonb_build_object('studios', v_studios, 'asked', n_ask,
                            'reminded', n_remind, 'escalated', n_escalate);
end $$;

-- instructor_week (3-arg) — add top-level confirmations_on so the UI hides every
-- confirm control from ONE flag (not derived in TS). Re-issued VERBATIM from
-- 20260832140000 with v_conf read and one field added.
CREATE OR REPLACE FUNCTION public.instructor_week(p_instructor_id uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_studio uuid; v_tz text; v_rows jsonb; v_opens int; v_closes int; v_enforced boolean; v_fmt text; v_conf boolean;
begin
  select i.studio_id into v_studio from instructors i where i.id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  if not (is_this_instructor(p_instructor_id) or is_manager_up(v_studio)) then
    raise exception 'that is somebody else''s week' using errcode = 'PT403';
  end if;
  select s.timezone into v_tz from studios s where s.id = v_studio;
  select coalesce(checkin_opens_minutes_before, 60), coalesce(checkin_closes_minutes_after, 30),
         coalesce(checkin_window_enforced, true), coalesce(time_format, '24h'),
         coalesce(assignment_confirmations, false)
    into v_opens, v_closes, v_enforced, v_fmt, v_conf from studio_settings where studio_id = v_studio;
  v_fmt := coalesce(v_fmt, '24h');

  select coalesce(jsonb_agg(to_jsonb(x) order by x.starts_at), '[]'::jsonb)
    into v_rows from (
    select o.id as occurrence_id, o.name, o.starts_at, o.ends_at,
           (o.starts_at at time zone v_tz)::date as local_date,
           fmt_clock(o.starts_at, v_tz, v_fmt) as local_start,
           fmt_clock(o.ends_at,   v_tz, v_fmt) as local_end,
           r.name as room_name, o.capacity, o.booked_count, o.waitlist_count,
           o.status::text as status, o.cancellation_reason,
           o.cancellation_cause::text as cancellation_cause,
           o.flex, o.minimum_bookings, o.committed_at is not null as committed,
           (select g.tier::text from occurrence_guarantee_run(o.id) g) as tier,
           (select case when d.deadline_at is null then null
                        else fmt_clock(d.deadline_at, v_tz, v_fmt)
                             || ' ' || to_char(d.deadline_at at time zone v_tz, 'FMDy') end
              from flex_deadline_for_run(o.id) d) as flex_deadline_short,
           o.instructor_confirmed_at is not null as confirmed,
           o.instructor_checked_in_at is not null as checked_in,
           (not coalesce(v_enforced, true)
            or (now() >= o.starts_at - make_interval(mins => coalesce(v_opens,60))
                and now() <= o.ends_at + make_interval(mins => coalesce(v_closes,30)))) as checkin_open,
           exists (select 1 from cover_requests c
                    where c.occurrence_id = o.id and c.status in ('pending','accepted_pending')) as cover_requested
      from class_occurrences o
      left join rooms r on r.id = o.room_id
     where o.studio_id = v_studio and o.instructor_id = p_instructor_id
       and (o.starts_at at time zone v_tz)::date between p_from and p_to
       and month_published(v_studio, o.starts_at)) x;

  return jsonb_build_object(
    'from', p_from, 'to', p_to, 'timezone', v_tz, 'classes', v_rows,
    'confirmations_on', v_conf,
    'state', case when jsonb_array_length(v_rows) = 0 then 'empty' else 'ok' end,
    'empty_hint', 'Classes you''re down to teach appear here as soon as the studio schedules them; open classes you can take are under Open classes.');
end $function$;

-- instructor_week (2-arg overload) — same confirmations_on field. Re-issued
-- VERBATIM from 20260832130000 with v_conf read and one field added.
CREATE OR REPLACE FUNCTION public.instructor_week(p_instructor_id uuid, p_week_start date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_studio uuid; v_tz text; v_week date; v_fmt text; v_conf boolean;
begin
  select i.studio_id, s.timezone into v_studio, v_tz
    from instructors i join studios s on s.id = i.studio_id where i.id = p_instructor_id;
  if v_studio is null then
    raise exception 'no such instructor' using errcode = 'PT404';
  end if;
  if not coalesce(is_manager_up(v_studio), false)
     and p_instructor_id is distinct from auth_instructor_id(v_studio)
     and not is_service_context() then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;
  select coalesce(time_format, '24h'), coalesce(assignment_confirmations, false)
    into v_fmt, v_conf from studio_settings where studio_id = v_studio;
  v_fmt := coalesce(v_fmt, '24h');

  v_week := coalesce(p_week_start,
                     studio_week_start(v_studio, (now() at time zone v_tz)::date));

  return jsonb_build_object(
    'instructor_id', p_instructor_id,
    'week_start', v_week,
    'week_end', v_week + 6,
    'confirmations_on', v_conf,
    'classes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'occurrence_id', o.id,
               'name', o.name,
               'starts_at', o.starts_at,
               'local', to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMon, ') || fmt_clock(o.starts_at, v_tz, v_fmt),
               'booked', o.booked_count,
               'confirmed', o.instructor_confirmed_at is not null,
               'cover_status', cr.status)
             order by o.starts_at)
        from class_occurrences o
        left join lateral (
          select status from cover_requests c
           where c.occurrence_id = o.id and c.status in ('pending','approved')
           order by c.requested_at desc limit 1) cr on true
       where o.instructor_id = p_instructor_id
         and o.status = 'scheduled'
         and (o.starts_at at time zone v_tz)::date between v_week and v_week + 6
         and month_published(v_studio, o.starts_at)
    ), '[]'::jsonb),
    'unanswered', (
      select count(*) from class_occurrences o
       where o.instructor_id = p_instructor_id
         and o.status = 'scheduled'
         and o.instructor_confirmed_at is null
         and (o.starts_at at time zone v_tz)::date between v_week and v_week + 6
         and month_published(v_studio, o.starts_at)
         and not exists (select 1 from cover_requests c
                          where c.occurrence_id = o.id and c.status in ('pending','approved'))));
end $function$;

-- =============================================================================
-- (1) Next teaching week.
-- =============================================================================
-- The studio-local week start (per week_starts_on) of the first week, from THIS
-- week onward, that holds a scheduled & published class for the instructor; null
-- when there are none. Instructor-guarded like instructor_week.
create or replace function instructor_next_teaching_week(p_instructor_id uuid, p_today date default null)
returns date language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_tz text; v_today date; v_this_week date; v_first date;
begin
  select i.studio_id, s.timezone into v_studio, v_tz
    from instructors i join studios s on s.id = i.studio_id where i.id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(v_studio), false)
     and p_instructor_id is distinct from auth_instructor_id(v_studio)
     and not is_service_context() then
    raise exception 'that is somebody else''s schedule' using errcode = 'PT403';
  end if;
  v_today := coalesce(p_today, (now() at time zone v_tz)::date);
  v_this_week := studio_week_start(v_studio, v_today);
  select min((o.starts_at at time zone v_tz)::date) into v_first
    from class_occurrences o
   where o.instructor_id = p_instructor_id and o.status = 'scheduled'
     and (o.starts_at at time zone v_tz)::date >= v_this_week
     and month_published(v_studio, o.starts_at);
  if v_first is null then return null; end if;
  return studio_week_start(v_studio, v_first);
end $$;
revoke execute on function instructor_next_teaching_week(uuid, date) from public, anon;
grant  execute on function instructor_next_teaching_week(uuid, date) to authenticated, service_role;

-- =============================================================================
-- (3) Cover from a named colleague.
-- =============================================================================
-- The picker: other active instructors of the same studio who have a login.
create or replace function instructor_colleagues(p_instructor_id uuid)
returns table(instructor_id uuid, display_name text)
language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(v_studio), false)
     and p_instructor_id is distinct from auth_instructor_id(v_studio)
     and not is_service_context() then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;
  return query
    select i.id, i.display_name
      from instructors i
     where i.studio_id = v_studio and i.status = 'active' and i.id <> p_instructor_id
       and instructor_user_id(i.id) is not null
     order by i.display_name;
end $$;
revoke execute on function instructor_colleagues(uuid) from public, anon;
grant  execute on function instructor_colleagues(uuid) to authenticated, service_role;

-- request_cover gains p_ask_instructor_id. Signature change → DROP + recreate,
-- ACL re-asserted. Re-issued from 20260832140000 (its newest body) with the
-- directed branch added; everything else byte-for-byte.
drop function if exists request_cover(uuid, text);
create or replace function request_cover(p_occurrence_id uuid, p_reason text default null, p_ask_instructor_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o class_occurrences%rowtype; s studios%rowtype; st studio_settings%rowtype;
  v_instr uuid; v_req cover_requests%rowtype; v_hours numeric; v_urgent boolean;
  v_name text; v_asked_name text; n int; d record; v_offered int := 0;
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

  -- Decision 58: a named colleague must be another active instructor of this
  -- studio who has a login (otherwise there is nobody to reach).
  if p_ask_instructor_id is not null then
    if not exists (select 1 from instructors i
                    where i.id = p_ask_instructor_id and i.studio_id = o.studio_id
                      and i.status = 'active' and i.id <> v_instr
                      and instructor_user_id(i.id) is not null) then
      raise exception 'that is not a colleague who can be asked to cover' using errcode = 'PT400';
    end if;
  end if;

  insert into cover_requests (studio_id, occurrence_id, instructor_id, reason, asked_instructor_id)
  values (o.studio_id, o.id, v_instr, nullif(btrim(p_reason), ''), p_ask_instructor_id)
  on conflict (occurrence_id, instructor_id) where status = 'pending' do nothing
  returning * into v_req;

  if v_req.id is null then
    select * into v_req from cover_requests
     where occurrence_id = o.id and instructor_id = v_instr and status = 'pending';
    return jsonb_build_object('ok', true, 'already_open', true, 'request_id', v_req.id);
  end if;

  update shift_applications
     set withdrawn_at = now(),
         withdrawal_notice_hours = greatest(0, round(extract(epoch from o.starts_at - now()) / 3600))::int
   where occurrence_id = o.id and instructor_id = v_instr
     and status = 'approved' and withdrawn_at is null;

  select display_name into v_name from instructors where id = v_instr;
  v_hours  := extract(epoch from o.starts_at - now()) / 3600;
  v_urgent := v_hours <= coalesce(st.cover_escalation_hours, 4);

  -- Staff always get the notice — Shifts → Cover shows every pending request,
  -- directed or not.
  n := queue_shift_notice_to_staff(
    o.studio_id,
    case when v_urgent then 'cover_urgent' else 'cover_requested' end,
    jsonb_build_object(
      'instructor_name', v_name, 'class_name', o.name,
      'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY, ') || fmt_clock_s(o.starts_at, o.studio_id),
      'hours_line', case when v_hours < 1 then round(v_hours * 60) || ' minutes'
                         else round(v_hours) || ' hour' || case when round(v_hours) = 1 then '' else 's' end end,
      'reason_line', case when nullif(btrim(coalesce(p_reason,'')), '') is null then ''
                          else 'They said: ' || btrim(p_reason) || E'\n\n' end,
      'booked_line', case when o.booked_count > 0
        then format('%s member%s booked.', o.booked_count, case when o.booked_count = 1 then ' is' else 's are' end)
        else 'Nobody has booked yet.' end,
      'cover_url', '/shifts/cover'),
    'cover_req:' || v_req.id || case when v_urgent then ':urgent' else '' end);

  if p_ask_instructor_id is not null then
    -- DIRECTED: email the named colleague alone (no everyone broadcast); the
    -- sweep opens it to everyone later if they don't answer, so escalated_at is
    -- left null.
    select display_name into v_asked_name from instructors where id = p_ask_instructor_id;
    if queue_shift_notice(o.studio_id, instructor_user_id(p_ask_instructor_id), 'cover_available',
         jsonb_build_object('instructor_name', v_asked_name, 'studio_name', s.name, 'class_name', o.name,
           'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY, ') || fmt_clock_s(o.starts_at, o.studio_id),
           'booked_line', case when o.booked_count > 0
             then format('%s member%s booked.', o.booked_count, case when o.booked_count = 1 then ' is' else 's are' end)
             else 'Nobody has booked yet.' end,
           'href', instructor_portal_url(o.studio_id, '/instructor/shifts')),
         'cover_available:' || v_req.id || ':' || p_ask_instructor_id) is not null
    then v_offered := 1; end if;

    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (o.studio_id, auth.uid(), 'cover.requested', 'cover_requests', v_req.id,
            jsonb_build_object('occurrence_id', o.id, 'instructor_id', v_instr,
                               'directed_to', p_ask_instructor_id, 'urgent', v_urgent, 'notified', n));
    return jsonb_build_object('ok', true, 'request_id', v_req.id, 'directed', true,
                              'asked', p_ask_instructor_id, 'urgent', v_urgent,
                              'notified_staff', n, 'still_assigned_to', v_instr);
  end if;

  if v_urgent then
    update cover_requests set escalated_at = now() where id = v_req.id;
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
               'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY, ') || fmt_clock_s(o.starts_at, o.studio_id),
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
end $$;
revoke execute on function request_cover(uuid, text, uuid) from public, anon;
grant  execute on function request_cover(uuid, text, uuid) to authenticated, service_role;

-- accept_cover — directed accept, plus today's everyone path. Re-issued from
-- 20260832140000.
create or replace function accept_cover(p_occurrence_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o class_occurrences%rowtype; s studios%rowtype; st studio_settings%rowtype; req cover_requests%rowtype;
  v_taker uuid; v_hours numeric; v_old text; v_new text; v_subs int := 0;
  v_cut timestamptz; v_user uuid; v_asked_name text; v_when text;
begin
  select * into o from class_occurrences where id = p_occurrence_id for update;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  select * into st from studio_settings where studio_id = o.studio_id;
  select * into s  from studios where id = o.studio_id;
  v_taker := auth_instructor_id(o.studio_id);
  if v_taker is null then
    raise exception 'only an instructor at this studio can take a cover' using errcode = 'PT403';
  end if;
  v_when := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY, ') || fmt_clock_s(o.starts_at, o.studio_id);

  -- A request DIRECTED to the caller takes precedence.
  select * into req from cover_requests
   where occurrence_id = o.id and status = 'pending' and asked_instructor_id = v_taker
   order by created_at limit 1;

  if found then
    if o.status <> 'scheduled' or o.starts_at <= now() then
      raise exception 'that class is not open to take' using errcode = 'PT422';
    end if;
    select display_name into v_old from instructors where id = req.instructor_id;
    select display_name into v_new from instructors where id = v_taker;

    if coalesce(st.cover_auto_accept_enabled, false) then
      -- FINAL now. The two agreed and the studio chose the switch, so the
      -- close-enough rule and the qualified/valid/available gates do NOT apply
      -- to a directed accept; the exclusion constraint stays the hard gate.
      begin
        update class_occurrences
           set instructor_id = v_taker, assigned_by = auth.uid(), updated_at = now()
         where id = o.id;
      exception when exclusion_violation then
        return jsonb_build_object('ok', false, 'reason', 'instructor_busy');
      end;
      update cover_requests
         set status = 'approved', resolution = 'assigned', covered_by = v_taker,
             decided_by = null, decided_at = now()
       where id = req.id;
      if o.booked_count > 0 then
        v_subs := queue_substitution(o.id, v_old, v_new);
        v_cut := o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0));
        if now() > v_cut and coalesce(st.sub_late_free_cancel, true) then
          update bookings set free_cancel_until = o.starts_at
           where occurrence_id = o.id and status = 'booked';
        end if;
      end if;
      v_user := instructor_user_id(req.instructor_id);
      if v_user is not null then
        perform queue_shift_notice(o.studio_id, v_user, 'cover_approved',
          jsonb_build_object('class_name', o.name, 'when', v_when,
            'cover_line', coalesce(v_new, 'Someone else') || ' is taking it.'),
          'cover_approved:' || req.id);
      end if;
      perform queue_shift_notice_to_staff(o.studio_id, 'cover_auto_covered',
        jsonb_build_object('taker_name', coalesce(v_new, 'An instructor'),
          'requester_name', coalesce(v_old, 'an instructor'), 'class_name', o.name, 'when', v_when),
        'cover_auto:' || req.id);
      insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
      values (o.studio_id, auth.uid(), 'cover.auto_covered', 'cover_requests', req.id,
              jsonb_build_object('covered_by', v_taker, 'members_told', v_subs, 'directed', true));
      return jsonb_build_object('ok', true, 'final', true, 'covered_by', coalesce(v_new, 'you'), 'members_told', v_subs);
    else
      -- Auto-accept OFF: record the agreement; staff approve (Decision 18).
      update cover_requests set status = 'accepted_pending', covered_by = v_taker where id = req.id;
      perform queue_shift_notice_to_staff(o.studio_id, 'cover_needs_approval',
        jsonb_build_object('taker_name', coalesce(v_new, 'An instructor'),
          'requester_name', coalesce(v_old, 'an instructor'), 'class_name', o.name,
          'when', v_when, 'studio_name', s.name, 'cover_url', '/shifts/cover'),
        'cover_pending:' || req.id);
      insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
      values (o.studio_id, auth.uid(), 'cover.accepted_pending', 'cover_requests', req.id,
              jsonb_build_object('covered_by', v_taker, 'directed', true));
      return jsonb_build_object('ok', true, 'final', false, 'pending', true, 'covered_by', coalesce(v_new, 'you'));
    end if;
  end if;

  -- Not directed to the caller. A request still directed to SOMEONE ELSE is not
  -- theirs to take while it is directed.
  if exists (select 1 from cover_requests
              where occurrence_id = o.id and status = 'pending' and asked_instructor_id is not null) then
    select i.display_name into v_asked_name
      from cover_requests c join instructors i on i.id = c.asked_instructor_id
     where c.occurrence_id = o.id and c.status = 'pending' and c.asked_instructor_id is not null
     limit 1;
    raise exception '% was asked first — it opens to everyone if they can''t.',
      coalesce(v_asked_name, 'Someone') using errcode = 'PT403';
  end if;

  -- EVERYONE path — today's rule unchanged (auto-accept + close-enough).
  if not coalesce(st.cover_auto_accept_enabled, false) then
    raise exception 'this studio approves cover itself' using errcode = 'PT409';
  end if;
  select * into req from cover_requests
   where occurrence_id = o.id and status = 'pending' and asked_instructor_id is null
   order by created_at limit 1;
  if not found then raise exception 'no cover is open on that class' using errcode = 'PT409'; end if;
  if req.instructor_id = v_taker then raise exception 'that is your own class' using errcode = 'PT409'; end if;
  if o.status <> 'scheduled' or o.starts_at <= now() then
    raise exception 'that class is not open to take' using errcode = 'PT422';
  end if;
  v_hours := extract(epoch from o.starts_at - now()) / 3600;
  if v_hours > coalesce(st.cover_escalation_hours, 4) then
    raise exception 'that class is not close enough to take without the studio — it needs approving'
      using errcode = 'PT409';
  end if;
  if not instructor_qualified(v_taker, o.class_type_id) then
    raise exception 'you are not down to teach this class' using errcode = 'PT403';
  end if;
  if not instructor_valid_on(v_taker, (o.starts_at at time zone s.timezone)::date) then
    raise exception 'that class is outside the dates you have agreed to work' using errcode = 'PT409';
  end if;
  if not instructor_available_at(v_taker, o.starts_at, o.ends_at) then
    raise exception 'that is outside the hours you gave us' using errcode = 'PT409';
  end if;

  begin
    update class_occurrences
       set instructor_id = v_taker, assigned_by = auth.uid(), updated_at = now()
     where id = o.id;
  exception when exclusion_violation then
    return jsonb_build_object('ok', false, 'reason', 'instructor_busy');
  end;

  update cover_requests
     set status = 'approved', resolution = 'assigned', covered_by = v_taker,
         decided_by = null, decided_at = now()
   where id = req.id;

  select display_name into v_old from instructors where id = req.instructor_id;
  select display_name into v_new from instructors where id = v_taker;

  if o.booked_count > 0 then
    v_subs := queue_substitution(o.id, v_old, v_new);
    v_cut := o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0));
    if now() > v_cut and coalesce(st.sub_late_free_cancel, true) then
      update bookings set free_cancel_until = o.starts_at
       where occurrence_id = o.id and status = 'booked';
    end if;
  end if;

  v_user := instructor_user_id(req.instructor_id);
  if v_user is not null then
    perform queue_shift_notice(o.studio_id, v_user, 'cover_approved',
      jsonb_build_object('class_name', o.name, 'when', v_when,
        'cover_line', coalesce(v_new, 'Someone else') || ' is taking it.'),
      'cover_approved:' || req.id);
  end if;
  perform queue_shift_notice_to_staff(o.studio_id, 'cover_auto_covered',
    jsonb_build_object('taker_name', coalesce(v_new, 'An instructor'),
      'requester_name', coalesce(v_old, 'an instructor'), 'class_name', o.name, 'when', v_when),
    'cover_auto:' || req.id);

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (o.studio_id, auth.uid(), 'cover.auto_covered', 'cover_requests', req.id,
          jsonb_build_object('covered_by', v_taker, 'members_told', v_subs));

  return jsonb_build_object('ok', true, 'final', true, 'covered_by', coalesce(v_new, 'you'), 'members_told', v_subs);
end $$;

-- decline_directed_cover — the named colleague's "Can't". Clears the directed
-- ask (opens to everyone), tells the requester. The class is never touched
-- (Decision 18).
create or replace function decline_directed_cover(p_request_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare req cover_requests%rowtype; o class_occurrences%rowtype; s studios%rowtype;
        v_asked uuid; v_user uuid;
begin
  select * into req from cover_requests where id = p_request_id;
  if not found then raise exception 'no such cover request' using errcode = 'PT404'; end if;
  if req.status <> 'pending' or req.asked_instructor_id is null then
    raise exception 'this request is not waiting on you' using errcode = 'PT409';
  end if;
  v_asked := auth_instructor_id(req.studio_id);
  if v_asked is null or v_asked is distinct from req.asked_instructor_id then
    raise exception 'that cover was not directed to you' using errcode = 'PT403';
  end if;

  select * into o from class_occurrences where id = req.occurrence_id;
  select * into s from studios where id = req.studio_id;

  update cover_requests set asked_instructor_id = null where id = req.id;  -- opens to everyone

  v_user := instructor_user_id(req.instructor_id);
  if v_user is not null then
    perform queue_shift_notice(req.studio_id, v_user, 'cover_colleague_declined',
      jsonb_build_object(
        'instructor_name', (select display_name from instructors where id = req.instructor_id),
        'colleague_name', (select display_name from instructors where id = v_asked),
        'class_name', o.name,
        'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY, ') || fmt_clock_s(o.starts_at, req.studio_id),
        'studio_name', s.name),
      'cover_colleague_declined:' || req.id);
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (req.studio_id, auth.uid(), 'cover.directed_declined', 'cover_requests', req.id,
          jsonb_build_object('by', v_asked));
  return jsonb_build_object('ok', true, 'opened', true);
end $$;
revoke execute on function decline_directed_cover(uuid) from public, anon;
grant  execute on function decline_directed_cover(uuid) to authenticated, service_role;

-- sweep_cover_escalations — keep today's staff-urgent pass; add a pass that
-- OPENS a directed request the colleague has not answered within the studio's
-- cover_escalation_hours. Re-issued from 20260832140000.
create or replace function sweep_cover_escalations()
returns integer language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; v_hours numeric;
begin
  if not is_service_context() and not is_platform_admin() then
    raise exception 'only the scheduler may sweep cover requests' using errcode = 'PT403';
  end if;

  for r in
    select cr.id, cr.studio_id, cr.occurrence_id, cr.instructor_id,
           o.name, o.starts_at, o.booked_count, s.timezone,
           i.display_name,
           coalesce(st.cover_escalation_hours, 4) as window_hours
      from cover_requests cr
      join class_occurrences o on o.id = cr.occurrence_id
      join studios s           on s.id = cr.studio_id
      join instructors i       on i.id = cr.instructor_id
      left join studio_settings st on st.studio_id = cr.studio_id
     where cr.status = 'pending'
       and cr.escalated_at is null
       and o.status = 'scheduled'
       and o.starts_at > now()
       and o.starts_at <= now() + make_interval(hours => coalesce(st.cover_escalation_hours, 4))
  loop
    v_hours := extract(epoch from r.starts_at - now()) / 3600;
    perform queue_shift_notice_to_staff(r.studio_id, 'cover_urgent',
      jsonb_build_object(
        'instructor_name', r.display_name,
        'class_name', r.name,
        'when', to_char(r.starts_at at time zone r.timezone, 'FMDay FMDD FMMonth YYYY, ') || fmt_clock_s(r.starts_at, r.studio_id),
        'hours_line', case when v_hours < 1
                           then round(v_hours * 60) || ' minutes'
                           else round(v_hours) || ' hour' ||
                                case when round(v_hours) = 1 then '' else 's' end end,
        'booked_line', case when r.booked_count > 0
          then format('%s member%s booked.', r.booked_count,
                      case when r.booked_count = 1 then ' is' else 's are' end)
          else 'Nobody has booked yet.' end,
        'cover_url', '/shifts/cover'),
      'cover_req:' || r.id || ':urgent');
    update cover_requests set escalated_at = now() where id = r.id;
    n := n + 1;
  end loop;

  -- Decision 58: a DIRECTED request the colleague has not answered within the
  -- studio's cover_escalation_hours (measured from when it was asked) opens to
  -- everyone, and the requester is told. Idempotent — once opened,
  -- asked_instructor_id is null and the row no longer matches.
  for r in
    select cr.id, cr.studio_id, cr.occurrence_id, cr.instructor_id, cr.asked_instructor_id,
           o.name, o.starts_at, s.timezone
      from cover_requests cr
      join class_occurrences o on o.id = cr.occurrence_id
      join studios s           on s.id = cr.studio_id
      left join studio_settings st on st.studio_id = cr.studio_id
     where cr.status = 'pending'
       and cr.asked_instructor_id is not null
       and o.status = 'scheduled'
       and o.starts_at > now()
       and cr.requested_at <= now() - make_interval(hours => coalesce(st.cover_escalation_hours, 4))
  loop
    update cover_requests set asked_instructor_id = null where id = r.id;
    if instructor_user_id(r.instructor_id) is not null then
      perform queue_shift_notice(r.studio_id, instructor_user_id(r.instructor_id), 'cover_colleague_declined',
        jsonb_build_object(
          'instructor_name', (select display_name from instructors where id = r.instructor_id),
          'colleague_name', (select display_name from instructors where id = r.asked_instructor_id),
          'class_name', r.name,
          'when', to_char(r.starts_at at time zone r.timezone, 'FMDay FMDD FMMonth YYYY, ') || fmt_clock_s(r.starts_at, r.studio_id),
          'studio_name', (select name from studios where id = r.studio_id)),
        'cover_colleague_timeout:' || r.id);
    end if;
    n := n + 1;
  end loop;

  return n;
end $$;

-- instructor_open_classes — add directed cover asks to THIS instructor as
-- directed_covers (with asked_by_name). The open-shift classes list is
-- unchanged. Re-issued from 20260832140000.
create or replace function instructor_open_classes(p_instructor_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_tz text; v_fmt text; v_res jsonb; v_directed jsonb;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  if not (is_manager_up(v_studio) or is_this_instructor(p_instructor_id) or is_service_context()) then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = v_studio;
  select coalesce(time_format, '24h') into v_fmt from studio_settings where studio_id = v_studio;
  v_fmt := coalesce(v_fmt, '24h');

  select coalesce(jsonb_agg(x order by x.starts_at), '[]'::jsonb) into v_res
  from (
    select o.id as occurrence_id, o.name, o.starts_at,
           (o.starts_at at time zone v_tz)::date as local_date,
           fmt_clock(o.starts_at, v_tz, v_fmt) as local_start,
           to_char(o.starts_at at time zone v_tz, 'FMDy FMDD FMMon')
             || ', ' || fmt_clock(o.starts_at, v_tz, v_fmt) as when_label,
           r.name as room_name, o.booked_count, o.capacity,
           (select g.tier::text from occurrence_guarantee_run(o.id) g) as tier,
           (select case when d.deadline_at is null then null
                        else fmt_clock(d.deadline_at, v_tz, v_fmt)
                             || ' ' || to_char(d.deadline_at at time zone v_tz, 'FMDy') end
              from flex_deadline_for_run(o.id) d) as flex_deadline_short
      from class_occurrences o
      left join rooms r on r.id = o.room_id
     where o.studio_id = v_studio and o.staffing = 'open' and o.status = 'scheduled'
       and o.starts_at > now()
       and month_published(v_studio, o.starts_at)
     order by o.starts_at
     limit 40
  ) x;

  -- Decision 58: cover requests DIRECTED to this instructor — "{Name} asked you
  -- to cover …". Covers directed to someone else are hidden until they open.
  select coalesce(jsonb_agg(x order by x.starts_at), '[]'::jsonb) into v_directed
  from (
    select cr.id as request_id, o.id as occurrence_id, o.name, o.starts_at,
           (o.starts_at at time zone v_tz)::date as local_date,
           fmt_clock(o.starts_at, v_tz, v_fmt) as local_start,
           to_char(o.starts_at at time zone v_tz, 'FMDy FMDD FMMon')
             || ', ' || fmt_clock(o.starts_at, v_tz, v_fmt) as when_label,
           rm.name as room_name, o.booked_count, o.capacity,
           req.display_name as asked_by_name,
           (select g.tier::text from occurrence_guarantee_run(o.id) g) as tier,
           (select case when d.deadline_at is null then null
                        else fmt_clock(d.deadline_at, v_tz, v_fmt)
                             || ' ' || to_char(d.deadline_at at time zone v_tz, 'FMDy') end
              from flex_deadline_for_run(o.id) d) as flex_deadline_short
      from cover_requests cr
      join class_occurrences o on o.id = cr.occurrence_id
      join instructors req on req.id = cr.instructor_id
      left join rooms rm on rm.id = o.room_id
     where cr.studio_id = v_studio and cr.status = 'pending'
       and cr.asked_instructor_id = p_instructor_id
       and o.status = 'scheduled' and o.starts_at > now()
       and month_published(v_studio, o.starts_at)
     order by o.starts_at
  ) x;

  return jsonb_build_object('classes', v_res, 'directed_covers', v_directed);
end $$;

-- cover_available_to — exclude requests DIRECTED to someone (they are not open
-- to everyone until the ask clears). Re-issued from 20260832140000 with one
-- added predicate.
create or replace function cover_available_to(p_instructor_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_tz text; v_res jsonb; v_fmt text;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  if not (is_manager_up(v_studio) or is_this_instructor(p_instructor_id) or is_service_context()) then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;
  if not coalesce((select cover_auto_accept_enabled from studio_settings where studio_id = v_studio), false) then
    return jsonb_build_object('classes', '[]'::jsonb);
  end if;
  select timezone into v_tz from studios where id = v_studio;
  select coalesce(time_format, '24h') into v_fmt from studio_settings where studio_id = v_studio;
  v_fmt := coalesce(v_fmt, '24h');

  select coalesce(jsonb_agg(x order by x.starts_at), '[]'::jsonb) into v_res
  from (
    select o.id, o.starts_at,
           to_char(o.starts_at at time zone v_tz, 'YYYY-MM-DD') as date,
           fmt_clock(o.starts_at, v_tz, v_fmt) as time,
           o.name as class_name, ct.duration_minutes, r.name as room, o.booked_count as booked, o.capacity,
           (select g.tier::text from occurrence_guarantee_run(o.id) g) as tier,
           (select case when d.deadline_at is null then null
                        else fmt_clock(d.deadline_at, v_tz, v_fmt)
                             || ' ' || to_char(d.deadline_at at time zone v_tz, 'FMDy') end
              from flex_deadline_for_run(o.id) d) as flex_deadline_short
      from cover_requests cr
      join class_occurrences o on o.id = cr.occurrence_id
      join class_types ct on ct.id = o.class_type_id
      join studios s on s.id = o.studio_id
      left join studio_settings st on st.studio_id = o.studio_id
      left join rooms r on r.id = o.room_id
     where cr.studio_id = v_studio and cr.status = 'pending'
       and cr.asked_instructor_id is null
       and o.status = 'scheduled' and o.starts_at > now()
       and cr.instructor_id <> p_instructor_id
       and o.starts_at <= now() + make_interval(hours => coalesce(st.cover_escalation_hours, 4))
       and instructor_qualified(p_instructor_id, o.class_type_id)
       and instructor_valid_on(p_instructor_id, (o.starts_at at time zone v_tz)::date)
       and instructor_available_at(p_instructor_id, o.starts_at, o.ends_at)
       and not exists (
         select 1 from class_occurrences h
          where h.id <> o.id and h.instructor_id = p_instructor_id and h.status = 'scheduled'
            and tstzrange(h.starts_at, h.ends_at) && tstzrange(o.starts_at, o.ends_at))
  ) x;

  return jsonb_build_object('classes', v_res);
end $$;

-- approve_cover_request — accept an accepted_pending row (a directed colleague
-- agreed, awaiting approval). Re-issued from 20260832140000 with ONE change: the
-- guard admits 'accepted_pending' as well as 'pending'.
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
  if req.status not in ('pending', 'accepted_pending') then
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

  v_move := move_occurrence(
    p_occurrence_id   => req.occurrence_id,
    p_instructor_id   => case when p_mode = 'assign' then p_instructor_id else null end,
    p_confirm         => true,
    p_clear_instructor=> (p_mode = 'open'));

  if not (v_move ->> 'ok')::boolean then
    return v_move;
  end if;

  if p_mode = 'open' then
    perform stamp_open_shift(req.occurrence_id);
  end if;

  update cover_requests
     set status = 'approved',
         resolution = case when p_mode = 'assign' then 'assigned' else 'opened' end,
         covered_by = case when p_mode = 'assign' then p_instructor_id end,
         decided_by = auth.uid(), decided_at = now()
   where id = req.id;

  if p_mode = 'assign' then
    select display_name into v_new from instructors where id = p_instructor_id;
  end if;

  if p_mode = 'assign' and o.booked_count > 0 then
    v_subs := queue_substitution(req.occurrence_id, v_old, v_new);
    v_cut  := o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0));
    v_late := now() > v_cut;
    if v_late and coalesce(st.sub_late_free_cancel, true) then
      update bookings
         set free_cancel_until = o.starts_at
       where occurrence_id = req.occurrence_id and status = 'booked';
    end if;
  end if;

  v_user := instructor_user_id(req.instructor_id);
  if v_user is not null then
    perform queue_shift_notice(req.studio_id, v_user, 'cover_approved',
      jsonb_build_object(
        'class_name', o.name,
        'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY, ') || fmt_clock_s(o.starts_at, req.studio_id),
        'cover_line', case when p_mode = 'assign'
          then coalesce(v_new, 'Someone else') || ' is taking it.'
          else 'It has been opened up for another instructor to pick up.' end),
      'cover_approved:' || req.id);
  end if;

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
end $function$;

-- Anon surface stays EXACTLY THIRTEEN — every new/dropped function is
-- authenticated/service-role, never anon.
do $$
declare v_n int;
begin
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and has_function_privilege('anon', p.oid, 'execute');
  if v_n <> 13 then
    raise exception 'anon surface is %, expected exactly thirteen', v_n;
  end if;
end $$;
