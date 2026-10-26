-- Decision 82 STEP 1 (cause 5) — fewer serial round trips before a page draws.
-- re-issues: my_instructor(), instructor_week(uuid, date, date)
--
-- my_instructor now carries uses_payroll + unread, so instructorScreen() is ONE
-- wave (it was my_instructor then a second wave for [studio_uses_payroll,
-- instructor_notifications]). instructor_week now returns next_teaching_week so
-- /instructor/schedule's default landing is one wave, and checkin_count per class
-- for Decision 82 STEP 2(b) "{checked_in} of {booked} checked in".
--
-- Both return jsonb; these are additive create-or-replace re-issues, so the ACL
-- and the anon surface are untouched. No behaviour change — the new fields are
-- exactly what the two dropped calls returned, computed inline.

-- --- my_instructor: + uses_payroll (guarantees OR flex, the studio_uses_payroll
--     formula) + unread (the instructor's unread email notifications) ---------
create or replace function my_instructor()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r record;
begin
  select i.id as instructor_id, i.display_name, i.avatar_url, i.bio,
         s.id as studio_id, s.name as studio_name, s.slug, s.timezone, s.currency,
         s.accent_color, s.theme_preset, s.logo_url, ss.email, ss.role,
         coalesce(st.week_starts_on, 1) as week_starts_on,
         coalesce(st.time_format, '24h') as time_format,
         -- Decision 82: folded in from the instructorScreen() second wave. Same
         -- formula studio_uses_payroll() uses (guarantees OR flex), read off the
         -- left-joined settings so a studio paying in its own books shows no Pay.
         (coalesce(st.guarantees_enabled, false) or coalesce(st.flex_enabled, false)) as uses_payroll,
         -- The unread count the bell shows. ss.user_id is this login (it is the
         -- join key), which is instructor_user_id(i.id) for a login instructor —
         -- the same scoping instructor_notifications uses.
         (select count(*) from notifications n
           where n.user_id = ss.user_id and n.studio_id = s.id
             and n.channel = 'email' and n.status <> 'failed' and n.read_at is null) as unread
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

-- --- instructor_week (3-arg): + next_teaching_week + checkin_count -----------
-- Re-issued VERBATIM from 20260832190000 with two additions: next_teaching_week
-- (top level, so /instructor/schedule can land the current week in one wave and
-- jump only when it is empty) and checkin_count per class (Decision 82 STEP 2b).
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
           -- Decision 82 STEP 2(b): how many members are checked in, shown once
           -- check-in has opened. booked_count is already above.
           (select count(*) from check_ins ci where ci.occurrence_id = o.id)::int as checkin_count,
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
    -- Decision 82 STEP 1: the first week from this one onward holding a class,
    -- so /instructor/schedule needs no separate instructor_next_teaching_week
    -- wave — it lands the current week and only queries again when it is empty.
    -- Inlined (not a call to the guarded instructor_next_teaching_week) so this
    -- adds no subject-identity guard inside instructor_week: studio_week_start of
    -- the earliest future published scheduled class for this instructor.
    'next_teaching_week', (
      select case when min((o.starts_at at time zone v_tz)::date) is null then null
                  else studio_week_start(v_studio, min((o.starts_at at time zone v_tz)::date)) end
        from class_occurrences o
       where o.instructor_id = p_instructor_id and o.status = 'scheduled'
         and (o.starts_at at time zone v_tz)::date >= studio_week_start(v_studio, (now() at time zone v_tz)::date)
         and month_published(v_studio, o.starts_at)),
    'state', case when jsonb_array_length(v_rows) = 0 then 'empty' else 'ok' end,
    'empty_hint', 'Classes you''re down to teach appear here as soon as the studio schedules them; open classes you can take are under Open classes.');
end $function$;
