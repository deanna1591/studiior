-- Decision 78c — the instructor FYI: a per-class notes reader, and a heads-up
-- line in the week-ahead email. No tasks ever go to instructors.
--
-- creates:    instructor_roster_notes(uuid)
-- re-issues:  sweep_instructor_class_reminders(timestamptz)

-- instructor_roster_notes — for each booked member of a class: first-timer, the
-- intro window end (when still open), drifting (an open drifting_fyi task), and
-- the class type they attend most. The caller is the class's own instructor or a
-- manager (or a background job). The intro window is computed inline rather than
-- via intro_window(), whose subject guard would refuse an instructor reading
-- about a member (the 056 pattern) — and it needs no _run twin this way.
create function instructor_roster_notes(p_occurrence_id uuid)
returns table (member_id uuid, member_name text, first_timer boolean,
               intro_window_ends timestamptz, drifting boolean, usual_class text)
language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_instr uuid; v_start timestamptz; v_days int;
begin
  select o.studio_id, o.instructor_id, o.starts_at into v_studio, v_instr, v_start
    from class_occurrences o where o.id = p_occurrence_id;
  if v_studio is null then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not (coalesce(is_manager_up(v_studio), false)
          or coalesce(auth_instructor_id(v_studio) = v_instr, false)
          or is_service_context()) then
    raise exception 'that is not your class to read' using errcode = 'PT403';
  end if;
  select coalesce(intro_offer_days, 14) into v_days from studio_settings where studio_id = v_studio;
  v_days := coalesce(v_days, 14);

  return query
  select m.id,
         coalesce(nullif(m.first_name, ''), m.email),
         not exists (select 1 from check_ins ci where ci.member_id = m.id and ci.checked_in_at < v_start),
         iw.ends,
         exists (select 1 from member_tasks mt where mt.member_id = m.id and mt.kind = 'drifting_fyi' and mt.status = 'open'),
         (select ct.name from check_ins ci
            join class_occurrences o2 on o2.id = ci.occurrence_id
            join class_types ct on ct.id = o2.class_type_id
           where ci.member_id = m.id group by ct.name order by count(*) desc, ct.name limit 1)
    from bookings b
    join members m on m.id = b.member_id
    left join lateral (
      select (f.fend + make_interval(days => v_days)) as ends
        from (
          select coalesce((select min(checked_in_at) from check_ins c3
                            where c3.member_id = m.id and c3.occurrence_id = fb.occurrence_id),
                          fo.ends_at) as fend
            from bookings fb join class_occurrences fo on fo.id = fb.occurrence_id
           where fb.member_id = m.id and fb.payment_source = 'comp'
             and not exists (select 1 from guest_passes gp where gp.guest_booking_id = fb.id and gp.host_member_id is not null)
           order by fb.booked_at limit 1) f
       where not exists (select 1 from memberships ms where ms.member_id = m.id)
         and now() < (f.fend + make_interval(days => v_days))
    ) iw on true
   where b.occurrence_id = p_occurrence_id and b.status in ('booked', 'attended')
   order by 2;
end $$;
revoke execute on function instructor_roster_notes(uuid) from public, anon;
grant  execute on function instructor_roster_notes(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- sweep_instructor_class_reminders re-issued (from 20260832130000) + the
-- week-ahead heads-up line. Evening-before digest unchanged.
CREATE OR REPLACE FUNCTION public.sweep_instructor_class_reminders(p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s record; i record;
  v_tz text; v_local timestamp; v_today date; v_dow int; v_hour int;
  v_from date; v_to date; v_dedupe text; v_body text; v_link text; v_fname text;
  v_ins int; n_week int := 0; n_eve int := 0; v_studios int := 0; v_fmt text;
  v_notes text;
begin
  if not is_service_context() then
    raise exception 'the reminder sweep is a background job' using errcode = 'PT403';
  end if;

  for s in
    select st.id, st.name, st.slug, st.timezone,
           coalesce(cfg.instructor_class_reminders, false) as enabled,
           coalesce(cfg.time_format, '24h') as time_format
      from studios st
      left join studio_settings cfg on cfg.studio_id = st.id
     where st.status = 'active'
     order by st.id
  loop
    v_studios := v_studios + 1;
    if not s.enabled then continue; end if;

    v_tz    := s.timezone;
    v_fmt   := s.time_format;
    v_local := p_now at time zone v_tz;
    v_today := v_local::date;
    v_dow   := extract(dow from v_local)::int;   -- 0 = Sunday
    v_hour  := extract(hour from v_local)::int;
    v_link  := 'https://' || s.slug || '.'
               || coalesce(notification_setting('member_app_domain'), 'studiior.app')
               || '/instructor/schedule';

    -- WEEKLY digest: Sunday, once past 18:00 local. The week is Monday..Sunday
    -- starting tomorrow. Dedupe on that Monday, so it sends once.
    if v_dow = 0 and v_hour >= 18 then
      v_from := v_today + 1;   -- Monday
      v_to   := v_today + 7;   -- Sunday
      for i in
        select distinct o.instructor_id
          from class_occurrences o
         where o.studio_id = s.id and o.status = 'scheduled' and o.instructor_id is not null
           and (o.starts_at at time zone v_tz)::date between v_from and v_to
           and month_published(o.studio_id, o.starts_at)
           and instructor_user_id(o.instructor_id) is not null
      loop
        select string_agg(
                 to_char(o.starts_at at time zone v_tz, 'FMDy FMDD FMMon') || '  '
                 || fmt_clock(o.starts_at, v_tz, v_fmt) || ' ' || o.name
                 || coalesce(' · ' || r.name, '')
                 || ' · ' || coalesce(o.booked_count, 0) || '/' || o.capacity,
                 E'\n' order by o.starts_at)
          into v_body
          from class_occurrences o left join rooms r on r.id = o.room_id
         where o.instructor_id = i.instructor_id and o.status = 'scheduled'
           and (o.starts_at at time zone v_tz)::date between v_from and v_to
           and month_published(o.studio_id, o.starts_at);
        if nullif(v_body, '') is null then continue; end if;
        -- Decision 78c: a heads-up line per flagged member (first-timer or
        -- drifting) in the instructor's week. Never a task to the instructor.
        select string_agg(q.line, E'\n') into v_notes from (
          select distinct bm.id,
                 coalesce(nullif(bm.first_name, ''), 'A member') || ' — ' ||
                   case when not exists (select 1 from check_ins ci where ci.member_id = bm.id and ci.checked_in_at < o2.starts_at)
                        then 'first-timer' else 'hasn''t been in a while' end as line
            from class_occurrences o2
            join bookings b2 on b2.occurrence_id = o2.id and b2.status in ('booked','attended')
            join members bm on bm.id = b2.member_id
           where o2.instructor_id = i.instructor_id and o2.status = 'scheduled'
             and (o2.starts_at at time zone v_tz)::date between v_from and v_to
             and month_published(o2.studio_id, o2.starts_at)
             and ( not exists (select 1 from check_ins ci where ci.member_id = bm.id and ci.checked_in_at < o2.starts_at)
                or exists (select 1 from member_tasks mt where mt.member_id = bm.id and mt.kind = 'drifting_fyi' and mt.status = 'open') )
        ) q;
        if nullif(v_notes, '') is not null then
          v_body := v_body || E'\n\nHeads up this week:\n' || v_notes;
        end if;
        v_fname  := split_part(coalesce((select display_name from instructors where id = i.instructor_id), ''), ' ', 1);
        v_dedupe := 'instr_week_ahead:' || i.instructor_id || ':' || v_from;
        insert into notifications (studio_id, recipient_type, user_id, template_key, channel,
                                   payload, dedupe_key, scheduled_for, status)
        values (s.id, 'staff', instructor_user_id(i.instructor_id), 'instructor_week_ahead', 'email',
                jsonb_build_object('first_name', v_fname, 'class_list', v_body,
                                   'schedule_link', v_link, 'studio_name', s.name),
                v_dedupe, now(), 'scheduled')
        on conflict (dedupe_key) do nothing;
        get diagnostics v_ins = row_count;
        n_week := n_week + v_ins;
      end loop;
    end if;

    -- EVENING-BEFORE: once past 19:00 local, tomorrow's classes. Dedupe on tomorrow.
    if v_hour >= 19 then
      v_from := v_today + 1;
      for i in
        select distinct o.instructor_id
          from class_occurrences o
         where o.studio_id = s.id and o.status = 'scheduled' and o.instructor_id is not null
           and (o.starts_at at time zone v_tz)::date = v_from
           and month_published(o.studio_id, o.starts_at)
           and instructor_user_id(o.instructor_id) is not null
      loop
        select string_agg(
                 fmt_clock(o.starts_at, v_tz, v_fmt) || ' ' || o.name
                 || coalesce(' · ' || r.name, '')
                 || ' · ' || coalesce(o.booked_count, 0) || '/' || o.capacity,
                 E'\n' order by o.starts_at)
          into v_body
          from class_occurrences o left join rooms r on r.id = o.room_id
         where o.instructor_id = i.instructor_id and o.status = 'scheduled'
           and (o.starts_at at time zone v_tz)::date = v_from
           and month_published(o.studio_id, o.starts_at);
        if nullif(v_body, '') is null then continue; end if;
        v_fname  := split_part(coalesce((select display_name from instructors where id = i.instructor_id), ''), ' ', 1);
        v_dedupe := 'instr_tomorrow:' || i.instructor_id || ':' || v_from;
        insert into notifications (studio_id, recipient_type, user_id, template_key, channel,
                                   payload, dedupe_key, scheduled_for, status)
        values (s.id, 'staff', instructor_user_id(i.instructor_id), 'instructor_tomorrow', 'email',
                jsonb_build_object('first_name', v_fname, 'class_list', v_body,
                                   'schedule_link', v_link, 'studio_name', s.name),
                v_dedupe, now(), 'scheduled')
        on conflict (dedupe_key) do nothing;
        get diagnostics v_ins = row_count;
        n_eve := n_eve + v_ins;
      end loop;
    end if;

    insert into audit_logs (studio_id, action, entity_table, after)
    values (s.id, 'instructor_reminders.swept', 'studios',
            jsonb_build_object('week', n_week, 'evening', n_eve, 'at', now()));
  end loop;

  return jsonb_build_object('studios', v_studios, 'week', n_week, 'evening', n_eve);
end $function$

;
