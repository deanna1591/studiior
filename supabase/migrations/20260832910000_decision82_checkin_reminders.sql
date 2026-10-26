-- Decision 82 STEP 2 — instructor check-in reminders. Pay is on who's checked
-- in, so the instructor is nudged to mark everyone.
-- creates: sweep_class_ended_unmarked()
-- re-issues: instructor_roster(uuid)
--
-- (a) a `live` flag on instructor_roster for the "check everyone in" banner;
-- (b) checkin_count on instructor_week (migration 20260832900000) for the
--     "{checked_in} of {booked} checked in" line;
-- (c) instructor_class_ended_unmarked — one email ~5 min after a class ends,
--     once per class, login instructors only, for studios that finalise
--     attendance (so "or they count as no-shows at midnight" is true); the
--     existing midnight instructor_unmarked_bookings stays. Editable.
-- (d) a standing check-in line in the week-ahead email.

-- --- (c) the template -------------------------------------------------------
insert into notification_templates (key, subject, text_body, html_body, note) values
('instructor_class_ended_unmarked',
 '{class_name} just finished — {count} not checked in',
 E'Hi {first_name},\n\n{class_name} ({when}) just finished and {count} of {booked} aren''t checked in. Mark them before midnight studio time or they count as no-shows — you''re paid on who''s checked in.\n\n{studio_name}',
 E'<p>Hi {first_name},</p><p>{class_name} ({when}) just finished and {count} of {booked} aren''t checked in. Mark them before midnight studio time or they count as no-shows — you''re paid on who''s checked in.</p><p>{studio_name}</p>',
 'Decision 82. Queued ~5 min after a class ends, once per occurrence, for studios that finalise attendance, when booked members are not yet checked in. Login instructors only.')
on conflict (key) do nothing;

-- --- (d) the week-ahead email gains one standing check-in line --------------
update notification_templates
   set text_body = E'Hi {first_name},\n\nYour classes this week:\n\n{class_list}\n\nAdd them to your calendar: {schedule_link}\n\nRemember to check everyone in — you''re paid on who''s checked in.\n\n{studio_name}',
       html_body = E'<p>Hi {first_name},</p><p>Your classes this week:</p><p style="white-space:pre-line">{class_list}</p><p><a href="{schedule_link}">Add them to your calendar</a></p><p>Remember to check everyone in — you''re paid on who''s checked in.</p><p>{studio_name}</p>'
 where key = 'instructor_week_ahead';

-- --- (a) instructor_roster: + `live` ----------------------------------------
-- Re-issued VERBATIM from 20260832140000 with the check-in window read and a
-- `live` flag added. `can_check_in` stays true (staff can always check in from
-- the roster); `live` is the window the "check everyone in" banner shows in:
-- from checkin_opens_minutes_before before the start to checkin_closes_minutes_after
-- after the end (default 30), while the class is still scheduled.
CREATE OR REPLACE FUNCTION public.instructor_roster(p_occurrence_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare occ class_occurrences%rowtype; v_tz text; v_rows jsonb; v_fmt text;
        v_opens int; v_closes int; v_enforced boolean; v_live boolean;
begin
  select * into occ from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not (is_desk_up(occ.studio_id)
          or (occ.instructor_id is not null and is_this_instructor(occ.instructor_id)
              and occurrence_published(occ.id))) then
    raise exception 'that is not your class' using errcode = 'PT403';
  end if;
  select s.timezone into v_tz from studios s where s.id = occ.studio_id;
  select coalesce(time_format, '24h'),
         coalesce(checkin_opens_minutes_before, 60), coalesce(checkin_closes_minutes_after, 30),
         coalesce(checkin_window_enforced, true)
    into v_fmt, v_opens, v_closes, v_enforced from studio_settings where studio_id = occ.studio_id;
  v_fmt := coalesce(v_fmt, '24h');
  v_live := occ.status = 'scheduled'
            and (not coalesce(v_enforced, true)
                 or (now() >= occ.starts_at - make_interval(mins => coalesce(v_opens, 60))
                     and now() <= occ.ends_at + make_interval(mins => coalesce(v_closes, 30))));

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
    'tier', (select g.tier::text from occurrence_guarantee_run(occ.id) g),
    'flex_deadline_short', (select case when d.deadline_at is null then null
                                        else fmt_clock(d.deadline_at, v_tz, v_fmt)
                                             || ' ' || to_char(d.deadline_at at time zone v_tz, 'FMDy') end
                              from flex_deadline_for_run(occ.id) d),
    'members', v_rows,
    'can_check_in', true,
    -- Decision 82: the window the "check everyone in" banner shows in.
    'live', v_live,
    'withheld', 'Contact details and any documents on file are not shown here — '
                || '§14 keeps those with the office.');
end $function$;

-- --- (c) the sweep ----------------------------------------------------------
create or replace function sweep_class_ended_unmarked()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; v_n int; v_booked int; v_fname text; v_when text; v_count int := 0;
begin
  if not is_service_context() then
    raise exception 'the class-ended reminder is a background job' using errcode = 'PT403';
  end if;

  for r in
    select o.id, o.studio_id, o.name, o.starts_at, o.ends_at, o.instructor_id,
           s.timezone as tz, s.name as studio_name
      from class_occurrences o
      join studios s on s.id = o.studio_id
      join studio_settings ss on ss.studio_id = o.studio_id
     where ss.finalise_attendance
       and o.status = 'scheduled'
       and o.ends_at <= now() - interval '5 minutes'
       and o.ends_at >= now() - interval '3 hours'
       and o.instructor_id is not null
       and instructor_user_id(o.instructor_id) is not null
       and exists (select 1 from bookings b
                    where b.occurrence_id = o.id and b.status = 'booked'
                      and not exists (select 1 from check_ins ci where ci.booking_id = b.id))
  loop
    select count(*) into v_n from bookings b
     where b.occurrence_id = r.id and b.status = 'booked'
       and not exists (select 1 from check_ins ci where ci.booking_id = b.id);
    select count(*) into v_booked from bookings b
     where b.occurrence_id = r.id and b.status in ('booked', 'attended', 'no_show');
    select split_part(coalesce(i.display_name, ''), ' ', 1) into v_fname
      from instructors i where i.id = r.instructor_id;
    v_when := to_char(r.starts_at at time zone r.tz, 'FMDay FMDD FMMon, HH24:MI');

    insert into notifications (studio_id, recipient_type, user_id, template_key, channel,
                               payload, dedupe_key, scheduled_for, status)
    values (r.studio_id, 'staff', instructor_user_id(r.instructor_id), 'instructor_class_ended_unmarked', 'email',
            jsonb_build_object('first_name', coalesce(nullif(v_fname, ''), 'there'),
                               'count', v_n, 'booked', v_booked, 'class_name', r.name,
                               'when', v_when, 'studio_name', r.studio_name),
            'class_ended_unmarked:' || r.id::text, now(), 'scheduled')
    on conflict (dedupe_key) do nothing;
    if found then v_count := v_count + 1; end if;
  end loop;

  insert into job_runs (job_key, run_for, status, finished_at)
  values ('class_ended_unmarked', current_date, 'done', now())
  on conflict (job_key, run_for) do update
     set attempts = job_runs.attempts + 1, started_at = now(), status = 'done', finished_at = now();

  return jsonb_build_object('queued', v_count);
end $$;
revoke execute on function sweep_class_ended_unmarked() from public, anon, authenticated;
grant  execute on function sweep_class_ended_unmarked() to service_role;

do $$ begin
  if exists (select 1 from cron.job where jobname = 'studiior-class-ended-unmarked') then
    perform cron.unschedule('studiior-class-ended-unmarked');
  end if;
  perform cron.schedule('studiior-class-ended-unmarked', '*/15 * * * *',
                        $job$select sweep_class_ended_unmarked()$job$);
end $$;
