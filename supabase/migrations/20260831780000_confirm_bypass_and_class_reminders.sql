-- =============================================================================
-- Decision 38 amendment — the "already confirmed" bypass (paper-first studios).
-- Decision 39 — instructor class reminders (the week ahead + the evening before).
--
-- Decision 18 UNCHANGED: no instructor releases a class themselves. Nothing here
-- adds a release path. No new enum values. Anon surface stays EXACTLY ELEVEN.
-- =============================================================================

-- ---- Schema -----------------------------------------------------------------
alter table class_occurrences
  add column if not exists assignment_confirmed_by uuid;
comment on column class_occurrences.assignment_confirmed_by is
  'Decision 38 amendment. The staff user who marked this assigned class confirmed '
  'on the instructor''s behalf (paper-first). NULL when the instructor confirmed '
  'it themselves in the app.';

alter table studio_settings
  add column if not exists instructor_class_reminders boolean not null default false;

-- The two Decision-38 columns already joined the demo-promote ignore list in 770;
-- assignment_confirmed_by must too, or marking a demo class confirmed clears its
-- is_demo. Re-issued from 063/770.
drop trigger if exists occurrences_promote_demo on class_occurrences;
create trigger occurrences_promote_demo before update on class_occurrences for each row
  execute function tg_promote_edited_demo_row(
    'updated_at,booked_count,waitlist_count,series_slot_at,staffing,is_exception,assigned_by,'
    'assignment_requested_at,assignment_confirmed_at,assignment_confirmed_by');

-- ---- Reassignment clears the studio-confirmed stamp too ----------------------
-- Re-issued from 770 (newest): the reset now also clears assignment_confirmed_by.
create or replace function tg_stamp_assignment_request() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_on boolean;
begin
  if tg_op = 'UPDATE' and new.instructor_id is not distinct from old.instructor_id then
    return new;
  end if;
  -- The arrangement changed: a prior confirmation no longer holds.
  new.assignment_confirmed_at := null;
  new.assignment_confirmed_by := null;
  new.assignment_requested_at := null;
  if new.instructor_id is not null then
    select assignment_confirmations into v_on from studio_settings where studio_id = new.studio_id;
    if coalesce(v_on, false) and instructor_user_id(new.instructor_id) is not null then
      new.assignment_requested_at := now();
    end if;
  end if;
  return new;
end $$;
revoke execute on function tg_stamp_assignment_request() from public, anon, authenticated;

-- ---- The digest cancels itself when nothing is left to confirm ---------------
-- Re-issued from 770 (newest): on an empty pending list, DELETE the scheduled
-- digest rather than leaving a stale "please confirm" for classes since confirmed
-- (which is what the bypass and "Mark all confirmed" produce).
create or replace function queue_assignment_request(p_occurrence_id uuid) returns void
language plpgsql security definer set search_path = public as $$
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
          || to_char(min(o2.starts_at at time zone s.timezone), 'HH24:MI') || ' ' || o2.name
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
                to_char(o2.starts_at at time zone s.timezone, 'HH24:MI')
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
end $$;
revoke execute on function queue_assignment_request(uuid) from public, anon, authenticated;
grant  execute on function queue_assignment_request(uuid) to service_role;

-- ---- The "already confirmed" writers ----------------------------------------
-- One shape for both: stamp requested (if not already) + confirmed = now() +
-- confirmed_by = the staff user, for future scheduled login-instructor occurrences
-- not yet confirmed, then re-run the digest (which cancels the now-empty one).
create or replace function mark_series_confirmed(p_series_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_studio uuid; v_on boolean; v_n int; rec record;
begin
  select studio_id into v_studio from class_series where id = p_series_id;
  if v_studio is null then raise exception 'no such series' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(v_studio), false) then
    raise exception 'only owners and managers change the timetable' using errcode = 'PT403';
  end if;
  select assignment_confirmations into v_on from studio_settings where studio_id = v_studio;
  if not coalesce(v_on, false) then
    return jsonb_build_object('ok', false, 'reason', 'off', 'confirmed', 0);
  end if;
  with upd as (
    update class_occurrences o
       set assignment_requested_at = coalesce(o.assignment_requested_at, now()),
           assignment_confirmed_at = now(),
           assignment_confirmed_by = auth.uid()
     where o.series_id = p_series_id and o.status = 'scheduled' and o.starts_at > now()
       and o.instructor_id is not null and instructor_user_id(o.instructor_id) is not null
       and o.assignment_confirmed_at is null
    returning o.id)
  select count(*) into v_n from upd;
  for rec in
    select distinct on (o.instructor_id) o.id
      from class_occurrences o
     where o.series_id = p_series_id and o.status = 'scheduled' and o.starts_at > now()
       and o.instructor_id is not null
     order by o.instructor_id, o.starts_at
  loop
    perform queue_assignment_request(rec.id);
  end loop;
  return jsonb_build_object('ok', true, 'confirmed', v_n);
end $$;
revoke execute on function mark_series_confirmed(uuid) from public, anon;
grant  execute on function mark_series_confirmed(uuid) to authenticated, service_role;

create or replace function mark_assignment_confirmed(p_occurrence_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o class_occurrences%rowtype; v_on boolean;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(o.studio_id), false) then
    raise exception 'only owners and managers change the timetable' using errcode = 'PT403';
  end if;
  select assignment_confirmations into v_on from studio_settings where studio_id = o.studio_id;
  if not coalesce(v_on, false) then return jsonb_build_object('ok', false, 'reason', 'off', 'confirmed', 0); end if;
  if o.instructor_id is null or instructor_user_id(o.instructor_id) is null then
    return jsonb_build_object('ok', true, 'confirmed', 0);   -- no login: nothing to ask, nothing to bypass
  end if;
  update class_occurrences
     set assignment_requested_at = coalesce(assignment_requested_at, now()),
         assignment_confirmed_at = now(),
         assignment_confirmed_by = auth.uid()
   where id = p_occurrence_id and assignment_confirmed_at is null;
  perform queue_assignment_request(p_occurrence_id);
  return jsonb_build_object('ok', true, 'confirmed', 1);
end $$;
revoke execute on function mark_assignment_confirmed(uuid) from public, anon;
grant  execute on function mark_assignment_confirmed(uuid) to authenticated, service_role;

-- ---- Series summary now splits studio- vs instructor-confirmed ---------------
create or replace function series_confirmation_summary(p_series_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_total int; v_conf int; v_by_studio int; v_by_instr int;
begin
  select studio_id into v_studio from class_series where id = p_series_id;
  if v_studio is null then raise exception 'no such series' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(v_studio), false) and not is_service_context() then
    raise exception 'only owners and managers see the timetable' using errcode = 'PT403';
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
revoke execute on function series_confirmation_summary(uuid) from public, anon;
grant  execute on function series_confirmation_summary(uuid) to authenticated, service_role;

-- =============================================================================
-- Decision 39 — instructor class reminders.
-- =============================================================================
insert into notification_templates (key, subject, text_body, html_body, note) values
('instructor_week_ahead',
 'Your classes this week — {studio_name}',
 E'Hi {first_name},\n\nYour classes this week:\n\n{class_list}\n\nAdd them to your calendar: {schedule_link}\n\n{studio_name}',
 E'<p>Hi {first_name},</p><p>Your classes this week:</p><p style="white-space:pre-line">{class_list}</p><p><a href="{schedule_link}">Add them to your calendar</a></p><p>{studio_name}</p>',
 'Decision 39. Weekly digest, Sunday 18:00 studio time, login instructors, '
 'published months, scheduled occurrences. Skipped when the week is empty.'),
('instructor_tomorrow',
 'Tomorrow at {studio_name}',
 E'Hi {first_name},\n\nTomorrow:\n\n{class_list}\n\nAdd to your calendar: {schedule_link}\n\n{studio_name}',
 E'<p>Hi {first_name},</p><p>Tomorrow:</p><p style="white-space:pre-line">{class_list}</p><p><a href="{schedule_link}">Add to your calendar</a></p><p>{studio_name}</p>',
 'Decision 39. Evening-before reminder, 19:00 studio time. Skipped when none.')
on conflict (key) do nothing;

-- The sweep. Fires each instructor once past the local threshold; the dedupe key
-- (per instructor per digest per date) makes a re-run a no-op. Published months,
-- scheduled occurrences, login instructors only. One audit_logs row per studio.
-- p_now defaults to now() (cron calls it argless); it exists so the fixed Sunday
-- 18:00 / evening 19:00 gate can be exercised at a chosen instant in tests, with
-- the dow/hour logic run exactly as it is against the wall clock.
create or replace function sweep_instructor_class_reminders(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s record; i record;
  v_tz text; v_local timestamp; v_today date; v_dow int; v_hour int;
  v_from date; v_to date; v_dedupe text; v_body text; v_link text; v_fname text;
  v_ins int; n_week int := 0; n_eve int := 0; v_studios int := 0;
begin
  if not is_service_context() then
    raise exception 'the reminder sweep is a background job' using errcode = 'PT403';
  end if;

  for s in
    select st.id, st.name, st.slug, st.timezone,
           coalesce(cfg.instructor_class_reminders, false) as enabled
      from studios st
      left join studio_settings cfg on cfg.studio_id = st.id
     where st.status = 'active'
     order by st.id
  loop
    v_studios := v_studios + 1;
    if not s.enabled then continue; end if;

    v_tz    := s.timezone;
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
                 || to_char(o.starts_at at time zone v_tz, 'HH24:MI') || ' ' || o.name
                 || coalesce(' · ' || r.name, '')
                 || ' · ' || coalesce(o.booked_count, 0) || '/' || o.capacity,
                 E'\n' order by o.starts_at)
          into v_body
          from class_occurrences o left join rooms r on r.id = o.room_id
         where o.instructor_id = i.instructor_id and o.status = 'scheduled'
           and (o.starts_at at time zone v_tz)::date between v_from and v_to
           and month_published(o.studio_id, o.starts_at);
        if nullif(v_body, '') is null then continue; end if;
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
                 to_char(o.starts_at at time zone v_tz, 'HH24:MI') || ' ' || o.name
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
end $$;
revoke execute on function sweep_instructor_class_reminders(timestamptz) from public, anon, authenticated;
grant  execute on function sweep_instructor_class_reminders(timestamptz) to service_role;

select cron.schedule('studiior-instructor-reminders', '*/15 * * * *',
  $job$select sweep_instructor_class_reminders()$job$);

-- ---- Anon surface unchanged --------------------------------------------------
do $$
declare v_n int;
begin
  select count(*) into v_n from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
   where nsp.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if v_n <> 11 then raise exception 'anon surface is % functions, expected 11', v_n; end if;
end $$;
