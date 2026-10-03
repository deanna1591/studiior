-- =============================================================================
-- Decision 54 — instructor portal polish + install tightening + D55 follow-ups
-- =============================================================================
-- creates:   instructor_open_classes(uuid), fmt_clock_s(timestamptz, uuid)
-- re-issues: my_instructor(), instructor_week(uuid, date, date),
--            my_month_roster(uuid, date), instructor_roster(uuid),
--            cover_available_to(uuid), assign_instructors(uuid, date, date, boolean, boolean),
--            request_cover(uuid, text), approve_cover_request(uuid, text, uuid),
--            decline_cover_request(uuid, text), accept_cover(uuid),
--            sweep_cover_escalations(), reassign_occurrence(uuid, uuid),
--            apply_for_shift(uuid, text, boolean), approve_shift_application(uuid),
--            decline_shift_application(uuid, text), open_shift(uuid, text),
--            queue_instructor_assigned(uuid), queue_waitlist_offer(uuid),
--            queue_waitlist_missed(uuid), queue_assignment_request(uuid),
--            queue_instructor_booking_alert(uuid, integer, integer), notify_open_shifts(),
--            guarantee_report(uuid, date, date), pay_statement(uuid, uuid),
--            instructor_pay_summary(uuid)
-- =============================================================================
-- (1) The instructor ctx learns week_starts_on + time_format (my_instructor), so
--     My schedule can page by WEEK and the portal can format the few times it
--     builds client-side (Open-classes end time).
-- (2) Every instructor-facing class row carries a core/flex tag; a flex class
--     shows WHEN it is decided — `flex_deadline_short` from flex_deadline_for_run
--     + fmt_clock. Added to instructor_week, my_month_roster, instructor_roster,
--     cover_available_to, and the new instructor_open_classes. Members and
--     public_schedule never gain a tier field (Decision 21).
-- (4) assign_instructors gains p_confirmed (default false): true stamps
--     assignment_confirmed_by and cancels the Decision 38 ask, exactly as the
--     Schedule Assign panel (assign_occurrences_for_period) does.
-- (7) The deferred time-format readers are routed through fmt_clock here:
--     instructor_roster.local_time, cover_available_to.time,
--     instructor_open_classes — no member/instructor HH24:MI left in these.
-- No new anon surface. The instructor readers stay authenticated/self-guarded;
-- assign_instructors stays manager/service only; instructor_open_classes is
-- self-or-manager guarded like the other instructor readers.
-- =============================================================================

-- --- my_instructor: carry week_starts_on + time_format ----------------------
create or replace function my_instructor()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r record;
begin
  select i.id as instructor_id, i.display_name, i.avatar_url, i.bio,
         s.id as studio_id, s.name as studio_name, s.slug, s.timezone, s.currency,
         s.accent_color, s.theme_preset, s.logo_url, ss.email, ss.role,
         coalesce(st.week_starts_on, 1) as week_starts_on,
         coalesce(st.time_format, '24h') as time_format
    into r
    from studio_staff ss
    join instructors i on i.staff_id = ss.id
    join studios s on s.id = ss.studio_id
    left join studio_settings st on st.studio_id = s.id
   where ss.user_id = auth.uid() and ss.status = 'active' and i.status = 'active'
   order by ss.created_at limit 1;
  if r.instructor_id is null then return null; end if;
  return to_jsonb(r);
end $$;

-- --- instructor_week: add flex_deadline_short (the tag's "decided by ...") ---
-- Re-issued VERBATIM from 20260832130000 (the live (uuid,date,date) body), with
-- ONE field added — flex_deadline_short — and the empty_hint reworded to "Open
-- classes". Every other field is unchanged.
CREATE OR REPLACE FUNCTION public.instructor_week(p_instructor_id uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_studio uuid; v_tz text; v_rows jsonb; v_opens int; v_closes int; v_enforced boolean; v_fmt text;
begin
  select i.studio_id into v_studio from instructors i where i.id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  if not (is_this_instructor(p_instructor_id) or is_manager_up(v_studio)) then
    raise exception 'that is somebody else''s week' using errcode = 'PT403';
  end if;
  select s.timezone into v_tz from studios s where s.id = v_studio;
  select coalesce(checkin_opens_minutes_before, 60), coalesce(checkin_closes_minutes_after, 30),
         coalesce(checkin_window_enforced, true), coalesce(time_format, '24h')
    into v_opens, v_closes, v_enforced, v_fmt from studio_settings where studio_id = v_studio;
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
           -- Decision 54: the flex tag's "decided by {deadline}" — null unless an
           -- undecided flex class. Deadline through flex_deadline_for_run (the
           -- instant the sweep acts on) formatted with the studio's clock.
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
                    where c.occurrence_id = o.id and c.status = 'pending') as cover_requested
      from class_occurrences o
      left join rooms r on r.id = o.room_id
     where o.studio_id = v_studio and o.instructor_id = p_instructor_id
       and (o.starts_at at time zone v_tz)::date between p_from and p_to
       and month_published(v_studio, o.starts_at)) x;

  return jsonb_build_object(
    'from', p_from, 'to', p_to, 'timezone', v_tz, 'classes', v_rows,
    'state', case when jsonb_array_length(v_rows) = 0 then 'empty' else 'ok' end,
    'empty_hint', 'Classes you''re down to teach appear here as soon as the studio schedules them; open classes you can take are under Open classes.');
end $function$;

-- --- my_month_roster: add tier + flex_deadline_short ------------------------
-- Re-issued VERBATIM from 20260832130000 with two fields added to the inner
-- select (tier, flex_deadline_short). Nothing else changes.
CREATE OR REPLACE FUNCTION public.my_month_roster(p_instructor_id uuid, p_month date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_studio uuid; v_tz text; v_month date; v_from timestamptz; v_to timestamptz;
  rc roster_confirmations%rowtype; v_rows jsonb; v_added int; v_fmt text;
begin
  select i.studio_id, s.timezone into v_studio, v_tz
    from instructors i join studios s on s.id = i.studio_id where i.id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  select coalesce(time_format, '24h') into v_fmt from studio_settings where studio_id = v_studio;
  v_fmt := coalesce(v_fmt, '24h');
  if not (coalesce(is_this_instructor(p_instructor_id), false) or coalesce(is_manager_up(v_studio), false)) then
    raise exception 'that is somebody else''s month' using errcode = 'PT403';
  end if;

  v_month := date_trunc('month', p_month)::date;
  v_from  := (v_month::timestamp) at time zone v_tz;
  v_to    := ((v_month + interval '1 month')::timestamp) at time zone v_tz;

  select * into rc from roster_confirmations
   where studio_id = v_studio and instructor_id = p_instructor_id and month = v_month;

  if not month_published(v_studio, v_from) then
    return jsonb_build_object(
      'month', v_month, 'label', to_char(v_month, 'FMMonth YYYY'),
      'state', 'draft', 'classes', '[]'::jsonb, 'count', 0,
      'notified_at', null, 'confirmed_at', null, 'added_since', 0,
      'empty_hint', 'The studio has not published ' || to_char(v_month, 'FMMonth') || ' yet. Your classes appear here, and you get an email, as soon as it does.');
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.starts_at), '[]'::jsonb),
         coalesce(count(*) filter (where x.added_after_roster), 0)::int
    into v_rows, v_added
    from (
      select o.id as occurrence_id, o.name, o.starts_at,
             (o.starts_at at time zone v_tz)::date as local_date,
             fmt_clock(o.starts_at, v_tz, v_fmt) as local_start,
             fmt_clock(o.ends_at, v_tz, v_fmt) as local_end,
             r.name as room_name, o.capacity, o.booked_count,
             o.status::text as status,
             (select g.tier::text from occurrence_guarantee_run(o.id) g) as tier,
             (select case when d.deadline_at is null then null
                          else fmt_clock(d.deadline_at, v_tz, v_fmt)
                               || ' ' || to_char(d.deadline_at at time zone v_tz, 'FMDy') end
                from flex_deadline_for_run(o.id) d) as flex_deadline_short,
             (select c.status::text from cover_requests c
               where c.occurrence_id = o.id and c.status in ('pending','approved')
               order by c.requested_at desc limit 1) as cover_status,
             rc.notified_at is not null and o.created_at > rc.notified_at as added_after_roster
        from class_occurrences o
        left join rooms r on r.id = o.room_id
       where o.studio_id = v_studio and o.instructor_id = p_instructor_id
         and o.status = 'scheduled'
         and o.starts_at >= v_from and o.starts_at < v_to) x;

  return jsonb_build_object(
    'month', v_month, 'label', to_char(v_month, 'FMMonth YYYY'),
    'state', case when jsonb_array_length(v_rows) = 0 then 'empty'
                  when rc.confirmed_at is not null then 'confirmed'
                  else 'unconfirmed' end,
    'classes', v_rows, 'count', jsonb_array_length(v_rows),
    'notified_at', rc.notified_at, 'confirmed_at', rc.confirmed_at,
    'added_since', v_added,
    'empty_hint', 'Nothing of yours in ' || to_char(v_month, 'FMMonth') || '. Classes you are given after publication appear here and you are emailed about each one.');
end $function$;

-- --- instructor_roster: fmt_clock local_time + tier + flex_deadline_short ---
-- Re-issued VERBATIM from 20260831170000 with v_fmt read, local_time through
-- fmt_clock (Decision 55 follow-up, item 7), and the tag fields added.
CREATE OR REPLACE FUNCTION public.instructor_roster(p_occurrence_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare occ class_occurrences%rowtype; v_tz text; v_rows jsonb; v_fmt text;
begin
  select * into occ from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not (is_desk_up(occ.studio_id)
          or (occ.instructor_id is not null and is_this_instructor(occ.instructor_id)
              and occurrence_published(occ.id))) then
    raise exception 'that is not your class' using errcode = 'PT403';
  end if;
  select s.timezone into v_tz from studios s where s.id = occ.studio_id;
  select coalesce(time_format, '24h') into v_fmt from studio_settings where studio_id = occ.studio_id;
  v_fmt := coalesce(v_fmt, '24h');

  select coalesce(jsonb_agg(to_jsonb(x) order by x.first_timer desc, x.name), '[]'::jsonb)
    into v_rows from (
    select b.id as booking_id, m.id as member_id,
           coalesce(nullif(m.preferred_name, ''), m.first_name) || ' ' || m.last_name as name,
           m.avatar_url, b.status::text as booking_status,
           ci.id is not null as checked_in,
           not exists (select 1 from check_ins c2
                        where c2.member_id = m.id and c2.studio_id = occ.studio_id
                          and c2.checked_in_at < occ.starts_at) as first_timer,
           (m.date_of_birth is not null
            and to_char(m.date_of_birth, 'MM-DD')
                = to_char((occ.starts_at at time zone v_tz)::date, 'MM-DD')) as birthday,
           (select coalesce(jsonb_agg(jsonb_build_object(
                     'category', n.category, 'body', n.body) order by n.created_at desc), '[]'::jsonb)
              from member_notes n
             where n.member_id = m.id and n.studio_id = occ.studio_id
               and n.pinned and not n.managers_only) as pinned_notes
      from bookings b
      join members m on m.id = b.member_id
      left join check_ins ci on ci.booking_id = b.id
     where b.occurrence_id = p_occurrence_id
       and b.status in ('booked', 'attended', 'no_show')) x;

  return jsonb_build_object(
    'occurrence_id', occ.id, 'name', occ.name,
    'starts_at', occ.starts_at, 'capacity', occ.capacity,
    'booked', occ.booked_count, 'status', occ.status,
    'local_time', fmt_clock(occ.starts_at, v_tz, v_fmt),
    'local_date', (occ.starts_at at time zone v_tz)::date,
    -- Decision 54: the core/flex tag on the roster header.
    'tier', (select g.tier::text from occurrence_guarantee_run(occ.id) g),
    'flex_deadline_short', (select case when d.deadline_at is null then null
                                        else fmt_clock(d.deadline_at, v_tz, v_fmt)
                                             || ' ' || to_char(d.deadline_at at time zone v_tz, 'FMDy') end
                              from flex_deadline_for_run(occ.id) d),
    'members', v_rows,
    'can_check_in', true,
    'withheld', 'Contact details and any documents on file are not shown here — '
                || '§14 keeps those with the office.');
end $function$;

-- --- cover_available_to: fmt_clock time + tier + flex_deadline_short --------
-- Re-issued VERBATIM from 20260831610000 with v_fmt read, time through fmt_clock
-- (item 7), and the tag fields added to each class.
CREATE OR REPLACE FUNCTION public.cover_available_to(p_instructor_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$;

-- --- instructor_open_classes: the Open-classes reader -----------------------
-- Decision 54: the assigned-model "Open classes" tab (Decision 17). Returns the
-- studio's open scheduled classes with a formatted when-label (item 7, the
-- instructor Open-classes clock) and the core/flex tag. Self-or-manager guarded
-- like the other instructor readers; the time + tag need the service-role
-- occurrence_guarantee_run / flex_deadline_for_run, reached here inside a
-- SECURITY DEFINER owned by postgres.
create or replace function instructor_open_classes(p_instructor_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_tz text; v_fmt text; v_res jsonb;
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

  return jsonb_build_object('classes', v_res);
end $$;

revoke execute on function instructor_open_classes(uuid) from public, anon;
grant  execute on function instructor_open_classes(uuid) to authenticated, service_role;

-- --- assign_instructors: p_confirmed (Decision 54 item 4) -------------------
-- Adding a parameter is an overload, not a replace (028's trap) — so the 4-arg
-- form is DROPPED and recreated 5-arg, and the ACL re-asserted. p_confirmed true
-- stamps assignment_confirmed_by and cancels the Decision 38 ask for each class
-- the engine assigned, exactly as the Schedule Assign panel does.
drop function if exists assign_instructors(uuid, date, date, boolean);
create or replace function assign_instructors(
  p_studio_id uuid,
  p_from date default null,
  p_to date default null,
  p_dry_run boolean default false,
  p_confirmed boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_result jsonb; rec jsonb;
begin
  if not is_manager_up(p_studio_id) and not is_service_context() then
    raise exception 'only owners, managers or the scheduler may assign instructors'
      using errcode = 'PT403';
  end if;
  v_result := assign_instructors_run(p_studio_id, p_from, p_to, p_dry_run);

  -- Decision 54: "already confirmed with the instructors" — skip the Decision 38
  -- ask for each class the engine just assigned. mark_assignment_confirmed is a
  -- no-op when assignment_confirmations is off or the instructor has no login,
  -- so this is inert where it does not apply.
  if p_confirmed and not p_dry_run then
    for rec in select * from jsonb_array_elements(coalesce(v_result -> 'detail', '[]'::jsonb))
    loop
      if rec ->> 'outcome' = 'assigned' then
        perform mark_assignment_confirmed((rec ->> 'occurrence_id')::uuid);
      end if;
    end loop;
  end if;

  return v_result;
end $$;

revoke execute on function assign_instructors(uuid, date, date, boolean, boolean) from public, anon;
grant  execute on function assign_instructors(uuid, date, date, boolean, boolean) to authenticated, service_role;

-- --- fmt_clock_s: the studio-resolving clock helper (item 7) ----------------
-- The email senders and report readers below render a time against a studio.
-- fmt_clock_s looks up that studio's timezone AND time_format and returns the
-- clock string, so each sender's change is a one-call swap rather than a new
-- local v_fmt var threaded through every branch. Immutable-ish read; service
-- and authenticated may call it (it leaks nothing a staff/instructor reader
-- would not already see — just a formatted time).
create or replace function fmt_clock_s(p_ts timestamptz, p_studio uuid)
returns text
language sql stable security definer set search_path = public as $$
  select fmt_clock(p_ts,
                   (select timezone from studios where id = p_studio),
                   coalesce((select time_format from studio_settings where studio_id = p_studio), '24h'));
$$;
revoke execute on function fmt_clock_s(timestamptz, uuid) from public, anon;
grant  execute on function fmt_clock_s(timestamptz, uuid) to authenticated, service_role;

-- =============================================================================
-- Item 7 — the deferred email senders + report labels, re-issued VERBATIM from
-- their newest definitions with every human-facing HH24:MI swapped to
-- fmt_clock_s. Appended below.
-- =============================================================================

-- --- request_cover (item 7: HH24:MI -> fmt_clock_s) ---
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
end $function$

;

-- --- approve_cover_request (item 7: HH24:MI -> fmt_clock_s) ---
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
        'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY, ') || fmt_clock_s(o.starts_at, req.studio_id),
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

-- --- decline_cover_request (item 7: HH24:MI -> fmt_clock_s) ---
CREATE OR REPLACE FUNCTION public.decline_cover_request(p_request_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare req cover_requests%rowtype; o class_occurrences%rowtype;
        s studios%rowtype; v_user uuid;
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

  select * into o from class_occurrences where id = req.occurrence_id;
  select * into s from studios where id = req.studio_id;

  update cover_requests
     set status = 'declined', decided_by = auth.uid(), decided_at = now(),
         decision_note = nullif(btrim(p_reason), '')
   where id = req.id;

  -- The class was never touched, so there is nothing to undo. That is the whole
  -- reason a request does not release the class the moment it is made.
  v_user := instructor_user_id(req.instructor_id);
  if v_user is not null then
    perform queue_shift_notice(req.studio_id, v_user, 'cover_declined',
      jsonb_build_object(
        'class_name', o.name,
        'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY, ') || fmt_clock_s(o.starts_at, req.studio_id),
        'reason_line', case when nullif(btrim(coalesce(p_reason,'')), '') is null then ''
                            else 'They said: ' || btrim(p_reason) || E'\n\n' end),
      'cover_declined:' || req.id);
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (req.studio_id, auth.uid(), 'cover.declined', 'cover_requests', req.id,
          jsonb_build_object('reason', p_reason));
  return jsonb_build_object('ok', true, 'still_assigned_to', req.instructor_id);
end $function$

;

-- --- accept_cover (item 7: HH24:MI -> fmt_clock_s) ---
CREATE OR REPLACE FUNCTION public.accept_cover(p_occurrence_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o class_occurrences%rowtype; s studios%rowtype; st studio_settings%rowtype; req cover_requests%rowtype;
  v_taker uuid; v_move jsonb; v_hours numeric; v_old text; v_new text; v_subs int := 0;
  v_cut timestamptz; v_user uuid;
begin
  select * into o from class_occurrences where id = p_occurrence_id for update;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  select * into st from studio_settings where studio_id = o.studio_id;
  if not coalesce(st.cover_auto_accept_enabled, false) then
    raise exception 'this studio approves cover itself' using errcode = 'PT409';
  end if;

  v_taker := auth_instructor_id(o.studio_id);
  if v_taker is null then
    raise exception 'only an instructor at this studio can take a cover' using errcode = 'PT403';
  end if;

  select * into req from cover_requests
   where occurrence_id = o.id and status = 'pending' order by created_at limit 1;
  if not found then raise exception 'no cover is open on that class' using errcode = 'PT409'; end if;
  if req.instructor_id = v_taker then
    raise exception 'that is your own class' using errcode = 'PT409';
  end if;
  if o.status <> 'scheduled' or o.starts_at <= now() then
    raise exception 'that class is not open to take' using errcode = 'PT422';
  end if;

  select * into s from studios where id = o.studio_id;
  v_hours := extract(epoch from o.starts_at - now()) / 3600;
  if v_hours > coalesce(st.cover_escalation_hours, 4) then
    raise exception 'that class is not close enough to take without the studio — it needs approving'
      using errcode = 'PT409';
  end if;
  -- The checks auto-accept keeps (the human is what it skips): qualified, inside
  -- the validity window, available, and not already teaching then. The cap is
  -- deliberately NOT checked — an urgent cover is not hoarding a month.
  -- move_occurrence is manager-up, and the caller here is the instructor taking
  -- the cover, so the assignment is a direct guarded write: the exclusion
  -- constraint (occ_instructor_no_overlap) is the hard clash gate, and validity
  -- is checked explicitly. No time changes, so no booked-member move email —
  -- the substitution notice below is what they get.
  if not instructor_qualified(v_taker, o.class_type_id) then
    raise exception 'you are not down to teach this class' using errcode = 'PT403';
  end if;
  if not instructor_valid_on(v_taker, (o.starts_at at time zone (select timezone from studios where id = o.studio_id))::date) then
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

  -- The instructor who asked — it is covered, the message they were waiting for.
  v_user := instructor_user_id(req.instructor_id);
  if v_user is not null then
    perform queue_shift_notice(o.studio_id, v_user, 'cover_approved',
      jsonb_build_object('class_name', o.name,
        'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY, ') || fmt_clock_s(o.starts_at, o.studio_id),
        'cover_line', coalesce(v_new, 'Someone else') || ' is taking it.'),
      'cover_approved:' || req.id);
  end if;
  -- Staff, told who took it (no approval was needed).
  perform queue_shift_notice_to_staff(o.studio_id, 'cover_auto_covered',
    jsonb_build_object('taker_name', coalesce(v_new, 'An instructor'),
      'requester_name', coalesce(v_old, 'an instructor'), 'class_name', o.name,
      'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY, ') || fmt_clock_s(o.starts_at, o.studio_id)),
    'cover_auto:' || req.id);

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (o.studio_id, auth.uid(), 'cover.auto_covered', 'cover_requests', req.id,
          jsonb_build_object('covered_by', v_taker, 'members_told', v_subs));

  return jsonb_build_object('ok', true, 'covered_by', coalesce(v_new, 'you'), 'members_told', v_subs);
end $function$

;

-- --- sweep_cover_escalations (item 7: HH24:MI -> fmt_clock_s) ---
CREATE OR REPLACE FUNCTION public.sweep_cover_escalations()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  return n;
end $function$

;

-- --- reassign_occurrence (item 7: HH24:MI -> fmt_clock_s) ---
CREATE OR REPLACE FUNCTION public.reassign_occurrence(p_occurrence_id uuid, p_instructor_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o class_occurrences%rowtype; s studios%rowtype;
  v_old uuid; v_old_name text; v_new_name text; v_user uuid; v_when text;
  v_move jsonb; v_told boolean := false; v_reachable_removal boolean := false;
begin
  select * into o from class_occurrences where id = p_occurrence_id for update;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(o.studio_id), false) then
    raise exception 'only owners and managers change the timetable' using errcode = 'PT403';
  end if;
  if p_instructor_id is null then
    raise exception 'pick who is teaching it' using errcode = 'PT422';
  end if;
  v_old := o.instructor_id;

  -- The one gate. move_occurrence refuses outside the validity window, refuses a
  -- room or double-booking clash, warns on availability, and — because the new
  -- instructor differs from the old — notifies the one swapped IN. p_confirm is
  -- true because reassigning changes no time, so no member is emailed and there
  -- is no booked-members question to answer.
  v_move := move_occurrence(p_occurrence_id => p_occurrence_id,
                            p_instructor_id => p_instructor_id, p_confirm => true);
  if not coalesce((v_move ->> 'ok')::boolean, false) then
    return v_move;   -- the refusal, with blocked_by, passed straight back
  end if;

  -- Tell the instructor taken off — same queue_ pattern, publication-gated like
  -- the assigned notice. Skipped for a no-op (same person) or an empty slot, and
  -- for a draft month (nobody was told they had the class, so nobody is told it
  -- moved).
  if v_old is not null and v_old is distinct from p_instructor_id
     and month_published(o.studio_id, o.starts_at) then
    select * into s from studios where id = o.studio_id;
    select display_name into v_old_name from instructors where id = v_old;
    select display_name into v_new_name from instructors where id = p_instructor_id;
    v_when := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY, ') || fmt_clock_s(o.starts_at, o.studio_id);
    v_user := instructor_user_id(v_old);
    v_reachable_removal := true;
    if v_user is not null then
      v_told := queue_shift_notice(o.studio_id, v_user, 'class_reassigned_off',
        jsonb_build_object(
          'instructor_name', coalesce(v_old_name, 'there'),
          'studio_name', s.name, 'class_name', o.name, 'when', v_when,
          'new_instructor', coalesce(v_new_name, 'someone else')),
        'reassigned_off:' || o.id || ':' || v_old || ':' || extract(epoch from o.starts_at)::bigint
      ) is not null;
    end if;
  end if;

  return jsonb_build_object(
    'ok', true, 'occurrence_id', p_occurrence_id,
    'new_instructor', coalesce((select display_name from instructors where id = p_instructor_id), 'them'),
    'removed_instructor', v_old_name,
    'removed_notified', v_told,
    -- true only when there WAS someone to tell (published, real old instructor)
    -- but they have no login — the screen says "tell them yourself".
    'removed_uncontactable', (v_reachable_removal and v_user is null));
end $function$

;

-- --- apply_for_shift (item 7: HH24:MI -> fmt_clock_s) ---
CREATE OR REPLACE FUNCTION public.apply_for_shift(p_occurrence_id uuid, p_note text DEFAULT NULL::text, p_over_cap_ack boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  occ class_occurrences%rowtype;
  v_instructor uuid;
  v_app uuid;
  v_available boolean;
  v_when text; v_tz text;
  v_tier text; v_cap int; v_core int; v_over boolean := false;
  v_load jsonb;
begin
  select * into occ from class_occurrences where id = p_occurrence_id for update;
  if not found then
    raise exception 'no such class' using errcode = 'PT404';
  end if;

  v_instructor := auth_instructor_id(occ.studio_id);
  if v_instructor is null then
    raise exception 'only an instructor at this studio can apply for a shift'
      using errcode = 'PT403';
  end if;
  if studio_is_locked(occ.studio_id) then
    raise exception 'this studio''s Studiior subscription is not active'
      using errcode = 'PT402';
  end if;
  if occ.staffing = 'assigned' then
    raise exception 'that class already has an instructor' using errcode = 'PT409';
  end if;
  if occ.status <> 'scheduled' then
    raise exception 'that class is %', occ.status using errcode = 'PT409';
  end if;
  if occ.starts_at < now() then
    raise exception 'that class has already happened' using errcode = 'PT409';
  end if;

  select s.timezone into v_tz from studios s where s.id = occ.studio_id;

  -- CLAIMING gates — only when this studio uses claiming. Cover-shift applies at
  -- an assigned-model studio are untouched.
  if claiming_enabled(occ.studio_id) then
    -- Publishing is the reveal: an unpublished month is not claimable.
    if not month_published(occ.studio_id, occ.starts_at) then
      raise exception 'that class is not published yet' using errcode = 'PT409';
    end if;
    -- HARD: you cannot claim in a month you gave no availability for, nor outside
    -- your validity dates (Decision 18). Availability HOURS stay a soft warning.
    if not instructor_can_claim_month(v_instructor, (date_trunc('month', occ.starts_at at time zone v_tz))::date)
       or not instructor_valid_on(v_instructor, (occ.starts_at at time zone v_tz)::date) then
      return jsonb_build_object('ok', false, 'reason', 'outside_validity');
    end if;
    -- CORE cap: soft. Refuse the self-claim past it with the numbers, and offer
    -- "ask anyway" (p_over_cap_ack) which records the over-cap flag for staff.
    v_tier := occurrence_claim_tier(occ.id);
    if v_tier = 'core' then
      v_cap  := instructor_core_cap(v_instructor);
      v_load := instructor_week_claim_load(v_instructor, occ.starts_at);
      v_core := (v_load ->> 'core')::int;
      if v_core >= v_cap and not p_over_cap_ack then
        return jsonb_build_object('ok', false, 'reason', 'over_cap',
                                  'tier', 'core', 'current', v_core, 'cap', v_cap);
      end if;
      v_over := v_core >= v_cap;   -- true only when they asked anyway
    end if;
  end if;

  insert into shift_applications (studio_id, occurrence_id, instructor_id, note, over_cap)
  values (occ.studio_id, occ.id, v_instructor, p_note, v_over)
  on conflict (occurrence_id, instructor_id) where status = 'pending'
  do nothing
  returning id into v_app;

  if v_app is null then
    raise exception 'you have already applied for that shift' using errcode = 'PT409';
  end if;

  update class_occurrences set staffing = 'pending_approval', updated_at = now()
   where id = occ.id and staffing = 'open';

  v_available := instructor_available_at(v_instructor, occ.starts_at, occ.ends_at);
  v_when := to_char(occ.starts_at at time zone v_tz, 'FMDay FMDD FMMonth YYYY, ') || fmt_clock_s(occ.starts_at, occ.studio_id);

  perform queue_shift_notice_to_staff(occ.studio_id, 'shift_application_received',
    jsonb_build_object(
      'class_name', occ.name,
      'when', v_when,
      'instructor_name', (select display_name from instructors where id = v_instructor),
      'availability_note', case when v_available then ''
        else 'This is outside the availability they have given us. ' end,
      'applications_url', coalesce(nullif(notification_setting('staff_app_origin'), ''),
                                   'https://app.studiior.com') || '/shifts/applications'),
    'shift_applied:' || v_app);

  return jsonb_build_object('ok', true, 'application_id', v_app,
                            'outside_availability', not v_available,
                            'tier', v_tier, 'over_cap', v_over,
                            'standing', case when claiming_enabled(occ.studio_id)
                              then jsonb_build_object('core', coalesce((instructor_week_claim_load(v_instructor, occ.starts_at) ->> 'core')::int, 0),
                                                      'cap', instructor_core_cap(v_instructor),
                                                      'flex', coalesce((instructor_week_claim_load(v_instructor, occ.starts_at) ->> 'flex')::int, 0))
                              else null end);
end $function$

;

-- --- approve_shift_application (item 7: HH24:MI -> fmt_clock_s) ---
CREATE OR REPLACE FUNCTION public.approve_shift_application(p_application_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  app  shift_applications%rowtype;
  occ  class_occurrences%rowtype;
  r    record;
  v_tz text; v_when text; v_where text;
  n_declined int := 0;
  v_res jsonb;
begin
  select * into app from shift_applications where id = p_application_id for update;
  if not found then
    raise exception 'no such application' using errcode = 'PT404';
  end if;
  if not is_manager_up(app.studio_id) then
    raise exception 'approving a shift is the owner''s or a manager''s to do'
      using errcode = 'PT403';
  end if;
  if app.status <> 'pending' then
    raise exception 'that application is already %', app.status using errcode = 'PT409';
  end if;

  select * into occ from class_occurrences where id = app.occurrence_id for update;

  v_res := move_occurrence(occ.id, null, null, app.instructor_id, null, true);
  if not (v_res ->> 'ok')::boolean then
    raise exception 'cannot assign them: %', v_res ->> 'reason'
      using errcode = 'PT409',
            hint = 'They are teaching something else at that time.';
  end if;

  update shift_applications
     set status = 'approved', approved_at = now(), decided_by = auth.uid(), decided_at = now()
   where id = p_application_id;

  select s.timezone into v_tz from studios s where s.id = occ.studio_id;
  v_when  := to_char(occ.starts_at at time zone v_tz, 'FMDay FMDD FMMonth YYYY, ') || fmt_clock_s(occ.starts_at, occ.studio_id);
  v_where := coalesce((select ', in ' || rm.name from rooms rm where rm.id = occ.room_id), '');

  perform queue_shift_notice(
    occ.studio_id,
    instructor_user_id(app.instructor_id),
    'shift_approved',
    jsonb_build_object('class_name', occ.name, 'when', v_when, 'where_line', v_where),
    'shift_approved:' || app.id);

  for r in
    select sa.*, instructor_user_id(sa.instructor_id) as staff_user
      from shift_applications sa
     where sa.occurrence_id = occ.id and sa.status = 'pending' and sa.id <> app.id
    for update
  loop
    update shift_applications
       set status = 'declined', decided_by = auth.uid(), decided_at = now()
     where id = r.id;
    perform queue_shift_notice(occ.studio_id, r.staff_user, 'shift_declined',
      jsonb_build_object('class_name', occ.name, 'when', v_when,
        'shifts_url', instructor_portal_url(occ.studio_id, '/instructor/shifts')),
      'shift_declined:' || r.id);
    n_declined := n_declined + 1;
  end loop;

  return jsonb_build_object('approved', app.id, 'auto_declined', n_declined,
                            'warnings', v_res -> 'warnings');
end $function$

;

-- --- decline_shift_application (item 7: HH24:MI -> fmt_clock_s) ---
CREATE OR REPLACE FUNCTION public.decline_shift_application(p_application_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare app shift_applications%rowtype; occ class_occurrences%rowtype; v_tz text; v_when text;
begin
  select * into app from shift_applications where id = p_application_id for update;
  if not found then
    raise exception 'no such application' using errcode = 'PT404';
  end if;
  if not is_manager_up(app.studio_id) then
    raise exception 'declining a shift is the owner''s or a manager''s to do'
      using errcode = 'PT403';
  end if;
  if app.status <> 'pending' then
    raise exception 'that application is already %', app.status using errcode = 'PT409';
  end if;

  update shift_applications
     set status = 'declined', decided_by = auth.uid(), decided_at = now()
   where id = p_application_id;

  select * into occ from class_occurrences where id = app.occurrence_id;
  select s.timezone into v_tz from studios s where s.id = occ.studio_id;
  v_when := to_char(occ.starts_at at time zone v_tz, 'FMDay FMDD FMMonth YYYY, ') || fmt_clock_s(occ.starts_at, occ.studio_id);

  perform queue_shift_notice(occ.studio_id,
    instructor_user_id(app.instructor_id),
    'shift_declined',
    jsonb_build_object('class_name', occ.name, 'when', v_when,
      'shifts_url', instructor_portal_url(occ.studio_id, '/instructor/shifts')),
    'shift_declined:' || app.id);

  -- Back to open if that was the last one waiting.
  update class_occurrences set staffing = 'open', updated_at = now()
   where id = occ.id and staffing = 'pending_approval'
     and not exists (select 1 from shift_applications sa
                      where sa.occurrence_id = occ.id and sa.status = 'pending');

  return jsonb_build_object('declined', app.id);
end $function$

;

-- --- open_shift (item 7: HH24:MI -> fmt_clock_s) ---
CREATE OR REPLACE FUNCTION public.open_shift(p_occurrence_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o class_occurrences%rowtype; s studios%rowtype;
  v_old_instr uuid; v_old_name text; v_user uuid; v_when text; v_told boolean := false;
  v_move jsonb;
begin
  select * into o from class_occurrences where id = p_occurrence_id for update;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(o.studio_id), false) then
    raise exception 'only owners and managers open a shift' using errcode = 'PT403';
  end if;
  if o.status <> 'scheduled' then
    raise exception 'a % class cannot be opened', o.status using errcode = 'PT409';
  end if;
  if o.instructor_id is null then
    raise exception 'that class already has nobody on it' using errcode = 'PT409';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'say why — the instructor being taken off gets this, and the studio''s record keeps it'
      using errcode = 'PT422';
  end if;

  v_old_instr := o.instructor_id;
  select display_name into v_old_name from instructors where id = v_old_instr;
  select * into s from studios where id = o.studio_id;
  v_when := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY, ') || fmt_clock_s(o.starts_at, o.studio_id);

  -- Clear through move_occurrence(): p_confirm true because opening a class is
  -- not moving anybody's booking — the members keep their seats and the class
  -- stays bookable — and p_clear_instructor makes staffing 'open'. This also
  -- stamps assigned_by via stamp_open_shift below, so "fill a month" leaves it
  -- alone.
  v_move := move_occurrence(p_occurrence_id => p_occurrence_id, p_confirm => true,
                            p_clear_instructor => true);
  if not coalesce((v_move ->> 'ok')::boolean, false) then
    return v_move;
  end if;
  perform stamp_open_shift(p_occurrence_id);

  -- The instructor removed is told. queue_shift_notice returns null for
  -- somebody with no login (the ordinary case), which is reported rather than
  -- passed off as a message that was sent.
  v_user := instructor_user_id(v_old_instr);
  if v_user is not null then
    v_told := queue_shift_notice(o.studio_id, v_user, 'shift_taken_off',
      jsonb_build_object(
        'instructor_name', coalesce(v_old_name, 'there'),
        'studio_name', s.name,
        'class_name', o.name,
        'when', v_when,
        'reason', btrim(p_reason)),
      -- Keyed on the class and the instructor and the time: taken off the same
      -- class twice at different times is two notices, the same one is one.
      'shift_taken_off:' || o.id || ':' || v_old_instr || ':' || extract(epoch from o.starts_at)::bigint
    ) is not null;
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (o.studio_id, auth.uid(), 'occurrence.opened', 'class_occurrences', p_occurrence_id,
          jsonb_build_object('instructor_id', v_old_instr, 'instructor_name', v_old_name),
          jsonb_build_object('reason', btrim(p_reason), 'booked_count', o.booked_count,
                             'removed_notified', v_told, 'at', now()));

  return jsonb_build_object(
    'ok', true, 'occurrence_id', p_occurrence_id,
    'removed_instructor', v_old_name,
    'removed_notified', v_told,
    -- Named so the caller can tell "taken off but has no login to hear it" from
    -- "told" — the screen says "tell them yourself" in that case.
    'removed_uncontactable', (v_user is null),
    'booked_count', o.booked_count);
end $function$

;

-- --- queue_instructor_assigned (item 7: HH24:MI -> fmt_clock_s) ---
CREATE OR REPLACE FUNCTION public.queue_instructor_assigned(p_occurrence_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o class_occurrences%rowtype; s studios%rowtype; v_user uuid; v_room text;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found or o.instructor_id is null then return null; end if;
  if not occurrence_published(o.id) then return null; end if;
  select * into s from studios where id = o.studio_id;
  v_user := instructor_user_id(o.instructor_id);
  if v_user is null then return null; end if;
  select name into v_room from rooms where id = o.room_id;

  return queue_shift_notice(
    o.studio_id, v_user, 'instructor_assigned',
    jsonb_build_object(
      'class_name', o.name,
      'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY, ') || fmt_clock_s(o.starts_at, o.studio_id),
      'where_line', case when v_room is null then '' else ' in ' || v_room end,
      'booked_line', case when o.booked_count > 0
        then format('%s member%s booked in so far.', o.booked_count,
                    case when o.booked_count = 1 then ' is' else 's are' end)
        else 'Nobody has booked yet.' end,
      'occurrence_id', o.id),
    'instructor_assigned:' || o.id || ':' || o.instructor_id || ':' || extract(epoch from o.starts_at)::bigint);
end $function$

;

-- --- queue_waitlist_offer (item 7: HH24:MI -> fmt_clock_s) ---
CREATE OR REPLACE FUNCTION public.queue_waitlist_offer(p_offer_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  ofr waitlist_offers%rowtype; b bookings%rowtype;
  o class_occurrences%rowtype; s studios%rowtype;
begin
  select * into ofr from waitlist_offers where id = p_offer_id;
  if not found then return 0; end if;
  select * into b from bookings          where id = ofr.booking_id;
  select * into o from class_occurrences where id = ofr.occurrence_id;
  select * into s from studios           where id = ofr.studio_id;

  return case when queue_notification(ofr.studio_id, b.member_id, 'waitlist_offer',
      jsonb_build_object('class_name', o.name,
                         'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth, ') || fmt_clock_s(o.starts_at, ofr.studio_id),
                         'expires_at', fmt_clock_s(ofr.expires_at, ofr.studio_id)),
      'waitlist_offer:' || p_offer_id) is not null then 1 else 0 end;
end $function$

;

-- --- queue_waitlist_missed (item 7: HH24:MI -> fmt_clock_s) ---
CREATE OR REPLACE FUNCTION public.queue_waitlist_missed(p_booking_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare b bookings%rowtype; o class_occurrences%rowtype; s studios%rowtype; v_when text;
begin
  select * into b from bookings where id = p_booking_id;
  select * into o from class_occurrences where id = b.occurrence_id;
  select * into s from studios where id = b.studio_id;
  v_when := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth, ') || fmt_clock_s(o.starts_at, b.studio_id);
  return case when queue_notification(b.studio_id, b.member_id, 'waitlist_missed',
      jsonb_build_object('class_name', o.name, 'when', v_when),
      'waitlist_missed:' || p_booking_id) is not null then 1 else 0 end;
end $function$

;

-- --- queue_assignment_request (item 7: HH24:MI -> fmt_clock_s) ---
CREATE OR REPLACE FUNCTION public.queue_assignment_request(p_occurrence_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o class_occurrences%rowtype; s studios%rowtype; st studio_settings%rowtype;
  v_user uuid; v_day date; v_dedupe text; v_sched timestamptz;
  v_body text; v_link text; v_fname text; v_n int;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found or o.instructor_id is null then return; end if;
  select * into st from studio_settings where studio_id = o.studio_id;
  if not coalesce(st.assignment_confirmations, false) then return; end if;
  if not month_published(o.studio_id, o.starts_at) then return; end if;
  v_user := instructor_user_id(o.instructor_id);
  if v_user is null then return; end if;
  select * into s from studios where id = o.studio_id;

  v_day    := (now() at time zone s.timezone)::date;
  v_dedupe := 'assignment_confirm:' || o.instructor_id || ':' || v_day;
  v_sched  := (date_trunc('day', (now() at time zone s.timezone)) + interval '1 day') at time zone s.timezone;
  v_fname  := split_part(coalesce((select display_name from instructors where id = o.instructor_id), ''), ' ', 1);
  v_link   := 'https://' || s.slug || '.'
              || coalesce(notification_setting('member_app_domain'), 'studiior.app')
              || '/instructor/schedule';

  select string_agg(line, E'\n' order by first_at), sum(cnt)::int
    into v_body, v_n
    from (
      select
        'Every ' || to_char(min(o2.starts_at at time zone s.timezone), 'FMDy') || ' '
          || fmt_clock_s(min(o2.starts_at), o.studio_id) || ' ' || o2.name
          || ' — ' || count(*) || ' ' || case when count(*) = 1 then 'class' else 'classes' end
          || ', ' || to_char(min(o2.starts_at at time zone s.timezone), 'FMDD FMMon')
          || ' to ' || to_char(max(o2.starts_at at time zone s.timezone), 'FMDD FMMon') as line,
        count(*) as cnt, min(o2.starts_at) as first_at
        from class_occurrences o2
       where o2.instructor_id = o.instructor_id and o2.status = 'scheduled'
         and o2.starts_at > now()
         and o2.assignment_requested_at is not null and o2.assignment_confirmed_at is null
         and month_published(o2.studio_id, o2.starts_at)
       group by coalesce(o2.series_id::text, o2.id::text), o2.name,
                extract(dow from o2.starts_at at time zone s.timezone),
                fmt_clock_s(o2.starts_at, o.studio_id)
    ) q;
  if coalesce(v_n, 0) = 0 then
    delete from notifications where dedupe_key = v_dedupe and status = 'scheduled';
    return;
  end if;

  insert into notifications (studio_id, recipient_type, user_id, template_key, channel,
                             payload, dedupe_key, scheduled_for, status)
  values (o.studio_id, 'staff', v_user, 'assignment_confirmation_request', 'email',
          jsonb_build_object('first_name', v_fname, 'class_list', v_body, 'count', v_n,
                             'schedule_link', v_link, 'studio_name', s.name),
          v_dedupe, v_sched, 'scheduled')
  on conflict (dedupe_key) do update
    set payload = excluded.payload
    where notifications.status = 'scheduled';
end $function$

;

-- --- queue_instructor_booking_alert (item 7: HH24:MI -> fmt_clock_s) ---
CREATE OR REPLACE FUNCTION public.queue_instructor_booking_alert(p_occurrence_id uuid, p_gained integer, p_lost integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o class_occurrences%rowtype; s studios%rowtype; st studio_settings%rowtype;
  v_user uuid; v_bucket bigint; v_dedupe text; v_sched timestamptz;
  v_head int; v_spaces int; v_when text; v_roster text; v_sl text;
  v_nb int; v_nc int; v_change text;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found or o.instructor_id is null then return; end if;      -- unassigned => nothing
  select * into st from studio_settings where studio_id = o.studio_id;
  if not coalesce(st.instructor_booking_alerts, false) then return; end if;   -- switch off
  if not month_published(o.studio_id, o.starts_at) then return; end if;       -- Decision 25
  v_user := instructor_user_id(o.instructor_id);
  if v_user is null then return; end if;                            -- no login, nowhere to send

  select * into s from studios where id = o.studio_id;
  v_bucket := floor(extract(epoch from now()) / 900)::bigint;       -- 15-minute window
  v_dedupe := 'instr_booking_alert:' || o.id || ':' || v_bucket;
  v_sched  := to_timestamp((v_bucket + 1) * 900);                   -- send at window end
  v_head   := occurrence_seats_taken(o.id);                         -- current, includes this change
  v_spaces := greatest(coalesce(o.capacity, 0) - v_head, 0);
  v_when   := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth, ') || fmt_clock_s(o.starts_at, o.studio_id);
  v_roster := 'https://' || s.slug || '.'
              || coalesce(notification_setting('member_app_domain'), 'studiior.app')
              || '/instructor/roster/' || o.id;
  v_sl := case when v_spaces > 0
               then ', ' || v_spaces || ' space' || case when v_spaces = 1 then '' else 's' end || ' left'
               else ' (full)' end;

  -- Accumulate over the window: the prior deltas in the pending notice (0 if none).
  select coalesce((payload ->> 'n_booked')::int, 0), coalesce((payload ->> 'n_cancelled')::int, 0)
    into v_nb, v_nc
    from notifications where dedupe_key = v_dedupe and status = 'scheduled';
  v_nb := coalesce(v_nb, 0) + coalesce(p_gained, 0);
  v_nc := coalesce(v_nc, 0) + coalesce(p_lost, 0);
  v_change := change_line_text(v_nb, v_nc);

  insert into notifications (studio_id, recipient_type, user_id, template_key, channel,
                             payload, dedupe_key, scheduled_for, status)
  values (o.studio_id, 'staff', v_user, 'instructor_booking_alert', 'email',
          jsonb_build_object('class_name', o.name, 'when', v_when, 'headcount', v_head,
                             'spaces_line', v_sl, 'change_line', v_change, 'roster_link', v_roster,
                             'occurrence_id', o.id, 'n_booked', v_nb, 'n_cancelled', v_nc),
          v_dedupe, v_sched, 'scheduled')
  on conflict (dedupe_key) do update
    set payload = excluded.payload
    where notifications.status = 'scheduled';
end $function$

;

-- --- notify_open_shifts (item 7: HH24:MI -> fmt_clock_s) ---
CREATE OR REPLACE FUNCTION public.notify_open_shifts()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  st record; d record; v_tz text;
  n_studios int := 0; n_told int := 0; n_shifts int := 0;
  v_uncontactable jsonb := '[]'::jsonb;
begin
  if not is_service_context() then
    raise exception 'the open-shift alert is a background job' using errcode = 'PT403';
  end if;

  for st in
    select s.id, s.name, s.timezone from studios s where s.status = 'active' order by s.id
  loop
    v_tz := st.timezone;
    create temporary table if not exists _os (occ_id uuid, occ_name text, class_type_id uuid,
                                              starts_at timestamptz, ends_at timestamptz, local_when text, booked int)
      on commit drop;
    delete from _os;
    insert into _os
    select o.id, o.name, o.class_type_id, o.starts_at, o.ends_at,
           to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMon, ') || fmt_clock_s(o.starts_at, st.id), o.booked_count
      from class_occurrences o
     where o.studio_id = st.id
       and o.status = 'scheduled'
       and o.staffing = 'open'
       and o.starts_at > now()
       and o.shift_opened_at is not null
       and o.shift_alert_sent_at is null
       and month_published(o.studio_id, o.starts_at);   -- 149: never email a draft month

    if not exists (select 1 from _os) then continue; end if;
    n_shifts := n_shifts + (select count(*) from _os);

    for d in
      select i.id as instructor_id, i.display_name,
             instructor_user_id(i.id) as user_id,
             string_agg(
               case when av.ok
                 then '  ' || _os.local_when || ' — ' || _os.occ_name
                      || case when _os.booked > 0 then ' (' || _os.booked || ' booked)' else '' end
                 else '  ' || _os.local_when || ' — ' || _os.occ_name
                      || ' — outside the hours you gave us'
               end,
               E'\n' order by av.ok desc, _os.starts_at) as lines,
             count(*) as n,
             md5(string_agg(_os.occ_id::text, ',' order by _os.occ_id)) as fingerprint
        from instructors i
        join _os on instructor_qualified(i.id, _os.class_type_id)
        cross join lateral (
          select instructor_valid_on(i.id, (_os.starts_at at time zone v_tz)::date)
                 and instructor_available_at(i.id, _os.starts_at, _os.ends_at) as ok
        ) av
       where i.studio_id = st.id and i.status = 'active'
       group by i.id, i.display_name
    loop
      if d.user_id is null then
        v_uncontactable := v_uncontactable || jsonb_build_object(
          'studio_id', st.id, 'name', d.display_name);
        continue;
      end if;
      if queue_shift_notice(st.id, d.user_id, 'open_shifts_available',
           jsonb_build_object('instructor_name', d.display_name, 'studio_name', st.name,
             'count', d.n, 'plural', case when d.n = 1 then '' else 'es' end, 'lines', d.lines,
             'href', coalesce(nullif(notification_setting('member_app_origin'), ''),
                              'https://' || (select slug from studios where id = st.id) || '.studiior.app')
                     || '/instructor/shifts'),
           'open_shifts:' || d.instructor_id || ':' || d.fingerprint) is not null
      then
        n_told := n_told + 1;
      end if;
    end loop;
    update class_occurrences set shift_alert_sent_at = now()
     where studio_id = st.id and staffing = 'open' and shift_alert_sent_at is null
       and starts_at > now() and month_published(studio_id, starts_at);
    n_studios := n_studios + 1;
  end loop;

  return jsonb_build_object('studios', n_studios, 'shifts', n_shifts,
                            'told', n_told, 'uncontactable', v_uncontactable);
end $function$

;

-- --- guarantee_report (item 7: HH24:MI -> fmt_clock_s) ---
CREATE OR REPLACE FUNCTION public.guarantee_report(p_studio_id uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_tz text; v_by_slot jsonb; v_by_tier jsonb; v_totals jsonb;
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers see the numbers' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;

  with o as (
    select occ.*, (occ.starts_at at time zone v_tz)::date as local_date,
           to_char(occ.starts_at at time zone v_tz, 'Dy ') || fmt_clock_s(occ.starts_at, p_studio_id) as slot,
           coalesce(occ.guarantee_tier,
                    case when occ.flex then 'flex'::guarantee_tier end,
                    'core'::guarantee_tier) as tier,
           (occ.status = 'cancelled' and occ.cancellation_cause = 'unmet_minimum') as not_running,
           coalesce(occ.booked_at_cutoff, occ.booked_count, 0) as heads
      from class_occurrences occ
     where occ.studio_id = p_studio_id
       and (occ.starts_at at time zone v_tz)::date between p_from and p_to
  ),
  pay as (
    select r.occurrence_id, r.amount_cents from instructor_pay_records r
     where r.studio_id = p_studio_id and r.type = 'class'
  ),
  rev as (
    -- Revenue attributed to a class: what was actually taken for a booking on
    -- it. A membership booking has no payment of its own, so this understates
    -- for subscription studios and the report says so rather than inventing an
    -- apportionment nobody agreed to.
    select b.occurrence_id, coalesce(sum(p.amount_cents), 0) as cents
      from bookings b
      join payments p on p.booking_id = b.id and p.status = 'succeeded'
     where b.studio_id = p_studio_id
     group by b.occurrence_id
  )
  select
    jsonb_agg(jsonb_build_object(
      'slot', slot, 'classes', n, 'not_running', n_not,
      'not_running_pct', round(100.0 * n_not / nullif(n, 0), 1),
      'avg_fill_pct', round(avg_fill, 1),
      'cost_cents', cost, 'revenue_cents', revenue)
      order by (1.0 * n_not / nullif(n, 0)) desc nulls last, slot)
    into v_by_slot
  from (
    select o.slot, count(*) as n,
           count(*) filter (where o.not_running) as n_not,
           avg(100.0 * o.heads / nullif(o.capacity, 0)) as avg_fill,
           coalesce(sum(pay.amount_cents), 0) as cost,
           coalesce(sum(rev.cents), 0) as revenue
      from o left join pay on pay.occurrence_id = o.id
             left join rev on rev.occurrence_id = o.id
     group by o.slot) s;

  select jsonb_agg(jsonb_build_object(
      'tier', tier, 'classes', n, 'not_running', n_not,
      'not_running_pct', round(100.0 * n_not / nullif(n, 0), 1))
      order by tier)
    into v_by_tier
  from (select o.tier, count(*) as n, count(*) filter (where o.not_running) as n_not
          from o group by o.tier) t;

  select jsonb_build_object(
      'classes', count(*),
      'not_running', count(*) filter (where o.not_running),
      'not_running_pct', round(100.0 * count(*) filter (where o.not_running) / nullif(count(*), 0), 1),
      'cost_cents', coalesce(sum(pay.amount_cents), 0),
      'revenue_cents', coalesce(sum(rev.cents), 0),
      'cost_share_of_revenue_pct',
        round(100.0 * coalesce(sum(pay.amount_cents), 0)
              / nullif(coalesce(sum(rev.cents), 0), 0), 1))
    into v_totals
  from o left join pay on pay.occurrence_id = o.id
         left join rev on rev.occurrence_id = o.id;

  return jsonb_build_object('ok', true, 'from', p_from, 'to', p_to,
    'totals', v_totals,
    'by_slot', coalesce(v_by_slot, '[]'::jsonb),
    'by_tier', coalesce(v_by_tier, '[]'::jsonb),
    'revenue_note', 'Revenue counts payments recorded against a booking. A class '
                    'filled by memberships shows no revenue of its own, so cost '
                    'share is only meaningful where classes are paid for singly.');
end $function$

;

-- --- pay_statement (item 7: HH24:MI -> fmt_clock_s) ---
CREATE OR REPLACE FUNCTION public.pay_statement(p_instructor_id uuid, p_period_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  p pay_periods%rowtype; v_studio uuid; v_tz text; v_name text; v_cur char(3);
  v_lines jsonb; v_sub jsonb; v_total bigint; v_self boolean; v_conf bigint; v_held bigint;
  v_settle_dow int; v_settle_offset int;
begin
  select * into p from pay_periods where id = p_period_id;
  if not found then raise exception 'no such period' using errcode = 'PT404'; end if;
  v_studio := p.studio_id;

  select exists (select 1 from instructors i join studio_staff ss on ss.id = i.staff_id
                  where i.id = p_instructor_id and ss.user_id = auth.uid())
    into v_self;
  if not coalesce(is_manager_up(v_studio), false) and not coalesce(v_self, false) then
    raise exception 'that is not your statement' using errcode = 'PT403';
  end if;

  select timezone, currency into v_tz, v_cur from studios where id = v_studio;
  select pay_settle_dow, pay_settle_offset_days into v_settle_dow, v_settle_offset
    from studio_settings where studio_id = v_studio;
  select display_name into v_name from instructors where id = p_instructor_id;

  select jsonb_agg(l order by l ->> 'sort'), coalesce(sum(amt), 0)
    into v_lines, v_total
  from (
    select
      jsonb_build_object(
        'sort', coalesce(to_char(o.starts_at at time zone v_tz, 'YYYY-MM-DD HH24:MI'),
                         to_char(r.created_at at time zone v_tz, 'YYYY-MM-DD HH24:MI')),
        'type', r.type,
        'date', coalesce(to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMon'),
                         to_char(r.created_at at time zone v_tz, 'FMDay FMDD FMMon')),
        'time', fmt_clock_s(o.starts_at, v_studio),
        'name', case r.type
                  when 'class' then o.name
                  when 'conversion' then 'Conversion — ' || coalesce(r.basis ->> 'member_name', 'a member')
                                          || ' (' || coalesce(r.basis ->> 'plan_name', 'a plan') || ')'
                  else coalesce(r.note, 'Adjustment') end,
        'status', case
                    when r.type <> 'class' then null
                    when o.status <> 'cancelled' then 'ran'
                    when o.cancellation_cause = 'unmet_minimum' then 'did not run'
                    else 'cancelled — ' || o.cancellation_cause::text end,
        'headcount', case when r.type = 'class' then o.booked_at_cutoff end,
        -- DECISION 32: say so when a late booker after the cutoff raised the pay.
        'headcount_note', case
            when (r.basis ->> 'booked_at_start') is not null
             and (r.basis ->> 'booked_at_start')::int
                 > coalesce((r.basis ->> 'booked_at_cutoff')::int, 0)
            then coalesce(r.basis ->> 'booked_at_cutoff', '0') || ' at cutoff, '
                 || (r.basis ->> 'booked_at_start') || ' at start'
            when r.type = 'adjustment' and (r.basis ->> 'true_up_of') is not null
            then coalesce(r.basis ->> 'booked_at_cutoff', '0') || ' at cutoff, '
                 || coalesce(r.basis ->> 'booked_at_start', '0') || ' at start'
            else null end,
        'capacity',  case when r.type = 'class' then o.capacity end,
        'amount_cents', r.amount_cents,
        'confirmed', r.confirmed_at is not null,
        'payable', r.type <> 'class' or r.confirmed_at is not null,
        'basis', r.basis) as l,
      r.amount_cents as amt
      from instructor_pay_records r
      left join class_occurrences o on o.id = r.occurrence_id
     where r.instructor_id = p_instructor_id and r.period_id = p_period_id
  ) x;

  select coalesce(sum(amount_cents) filter (where type <> 'class' or confirmed_at is not null), 0),
         coalesce(sum(amount_cents) filter (where type = 'class' and confirmed_at is null), 0)
    into v_conf, v_held
    from instructor_pay_records where instructor_id = p_instructor_id and period_id = p_period_id;

  select jsonb_object_agg(t, s) into v_sub from (
    select type::text as t, sum(amount_cents) as s
      from instructor_pay_records
     where instructor_id = p_instructor_id and period_id = p_period_id
     group by type) y;

  return jsonb_build_object('ok', true,
    'instructor_id', p_instructor_id, 'instructor_name', v_name,
    'period_id', p.id, 'starts_on', p.starts_on, 'ends_on', p.ends_on,
    'status', p.status, 'currency', v_cur,
    'settle_on', pay_settle_on(p.ends_on, v_settle_dow, v_settle_offset),
    'lines', coalesce(v_lines, '[]'::jsonb),
    'subtotals', coalesce(v_sub, '{}'::jsonb),
    'total_cents', v_total,
    'confirmed_cents', v_conf, 'held_cents', v_held);
end $function$

;

-- --- instructor_pay_summary (item 7: HH24:MI -> fmt_clock_s) ---
CREATE OR REPLACE FUNCTION public.instructor_pay_summary(p_instructor_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_studio uuid; v_tz text; v_cur char(3); v_period pay_periods%rowtype; v_rows jsonb;
        v_settle_dow int; v_settle_offset int;
begin
  select i.studio_id into v_studio from instructors i where i.id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  if not (is_this_instructor(p_instructor_id) or is_manager_up(v_studio)) then
    raise exception 'that is somebody else''s pay' using errcode = 'PT403';
  end if;
  select s.timezone, s.currency into v_tz, v_cur from studios s where s.id = v_studio;
  select pay_settle_dow, pay_settle_offset_days into v_settle_dow, v_settle_offset
    from studio_settings where studio_id = v_studio;

  select * into v_period from pay_periods
   where studio_id = v_studio and status = 'open'
   order by starts_on limit 1;

  if v_period.id is null then
    return jsonb_build_object('state', 'no_period', 'currency', v_cur,
      'empty_hint', 'Your studio has not opened a pay period yet. Once it does, every class you teach lands here with what it paid.');
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.starts_at desc), '[]'::jsonb)
    into v_rows from (
    select pr.id, pr.occurrence_id, o.name, o.starts_at,
           to_char(o.starts_at at time zone v_tz, 'DD Mon ') || fmt_clock_s(o.starts_at, v_studio) as local_when,
           pr.amount_cents,
           coalesce((pr.basis ->> 'base_cents')::int, 0) as base_cents,
           coalesce((pr.basis ->> 'per_head_cents')::int, 0) as per_head_cents,
           coalesce((pr.basis ->> 'full_house_bonus_cents')::int, 0) as bonus_cents,
           coalesce((pr.basis ->> 'booked_at_cutoff')::int, 0) as head_count,
           pr.type::text as kind,
           o.status::text as occurrence_status,
           o.cancellation_cause::text as cancellation_cause,
           o.status = 'cancelled' as did_not_run,
           pr.confirmed_at is not null as confirmed,
           (pr.type = 'class' and pr.confirmed_at is null) as held
      from instructor_pay_records pr
      left join class_occurrences o on o.id = pr.occurrence_id
     where pr.instructor_id = p_instructor_id and pr.period_id = v_period.id) x;

  return jsonb_build_object(
    'state', case when jsonb_array_length(v_rows) = 0 then 'empty' else 'ok' end,
    'currency', v_cur,
    'period', jsonb_build_object('id', v_period.id, 'starts_on', v_period.starts_on,
                                 'ends_on', v_period.ends_on, 'status', v_period.status,
                                 'settle_on', pay_settle_on(v_period.ends_on, v_settle_dow, v_settle_offset)),
    'total_cents', (select coalesce(sum((r ->> 'amount_cents')::bigint), 0)
                      from jsonb_array_elements(v_rows) r),
    'classes_paid', (select count(*) from jsonb_array_elements(v_rows) r
                      where (r ->> 'did_not_run')::boolean is not true),
    'not_running_paid', (select count(*) from jsonb_array_elements(v_rows) r
                          where (r ->> 'did_not_run')::boolean),
    'held_cents', (select coalesce(sum((r ->> 'amount_cents')::bigint), 0)
                     from jsonb_array_elements(v_rows) r where (r ->> 'held')::boolean),
    'records', v_rows,
    'empty_hint', 'Nothing in this period yet. A class pays once it is done, so today''s classes appear tonight.',
    'read_only', 'These are the studio''s figures. If something looks wrong, tell them — nothing here can be edited from this screen.');
end $function$

;


-- anon surface unchanged — nothing here is anon.
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.prokind = 'f'
     and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'expect_%';
  if n <> 12 then raise exception 'anon surface drifted: expected 12, got %', n; end if;
end $$;
