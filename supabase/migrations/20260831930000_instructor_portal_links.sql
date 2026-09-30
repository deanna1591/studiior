-- Decision 45 (Part B) — instructor notification links point at the tenant portal.
--
-- The availability-due email rendered `http:///instructors/<id>/availability`
-- (no host, a staff path); week-confirmation mail linked to the staff app's
-- /my/week; the cover offer carried a bare domain; and shift-declined mail sent
-- an instructor to the staff /shifts. Every one of those reaches an INSTRUCTOR,
-- whose app is {slug}.studiior.app/instructor. instructor_portal_url() is the
-- one helper that builds that absolute URL, so an instructor link cannot drift
-- into a staff path again. Links to a STAFF recipient (applications, a
-- manager's shifts, /shifts/cover, billing) are unchanged, as are member links.
--
-- Each sender below is re-issued VERBATIM from its newest definition with only
-- the instructor link expression swapped (create or replace keeps the ACL).

create or replace function instructor_portal_url(p_studio_id uuid, p_path text)
returns text language sql stable security definer set search_path = public as $$
  select 'https://' || s.slug || '.'
         || coalesce(nullif(notification_setting('member_app_domain'), ''), 'studiior.app')
         || p_path
    from studios s where s.id = p_studio_id
$$;
revoke execute on function instructor_portal_url(uuid, text) from public, anon, authenticated;
grant  execute on function instructor_portal_url(uuid, text) to service_role;

-- availability_due: /instructors/<id>/availability (bare staff) -> portal
create or replace function queue_availability_reminders(p_studio_id uuid)
returns int language plpgsql security definer set search_path = public as $$
declare
  v_cycle jsonb; v_tz text; v_today date; v_due date; v_period date;
  v_studio_name text; r record; n int := 0; v_wording text;
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
  v_wording := case when v_today = v_due then 'today' else 'on ' || to_char(v_due, 'FMDD FMMonth') end;

  for r in
    select i.id, i.display_name, instructor_user_id(i.id) as user_id
      from instructors i
     where i.studio_id = p_studio_id and i.status = 'active'
       -- An instructor with no login has no address anywhere in the schema, so
       -- there is nobody to remind. They show on the staff list instead.
       and instructor_user_id(i.id) is not null
       and not exists (select 1 from availability_submissions s
                        where s.instructor_id = i.id and s.period_start = v_period
                          and s.status in ('submitted','approved'))
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

-- week_confirm_ask + week_confirm_reminder: staff /my/week -> portal /instructor/schedule
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
    if not s.enabled then continue; end if;

    v_tz    := s.timezone;
    v_today := (now() at time zone v_tz)::date;
    v_dow   := extract(dow from v_today)::int;

    -- ---- ask, for the week AHEAD ------------------------------------------
    if v_dow = s.ask_dow then
      v_week := studio_week_start(s.id, v_today) + 7;
      for r in
        -- instructors.staff_id is a studio_staff id, not an auth user id.
        select i.id, i.display_name, instructor_user_id(i.id) as user_id, count(*)::int as n
          from instructors i
          join class_occurrences o on o.instructor_id = i.id and o.status = 'scheduled'
         where i.studio_id = s.id and i.status = 'active'
           and instructor_user_id(i.id) is not null
           and (o.starts_at at time zone v_tz)::date between v_week and v_week + 6
           -- Decision 25: do not ask anybody to confirm a week the studio has
           -- not published yet.
           and month_published(s.id, o.starts_at)
         group by i.id, i.display_name
      loop
        if queue_shift_notice(s.id, r.user_id, 'week_confirm_ask',
             jsonb_build_object('instructor_name', r.display_name, 'studio_name', s.name,
                                'count', r.n, 'week', to_char(v_week, 'FMDD FMMonth'),
                                -- A full URL. 067 wrote a path here, which in an email is
                                -- a link to nowhere; fixed while this is re-issued.
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
                                -- A full URL. 067 wrote a path here, which in an email is
                                -- a link to nowhere; fixed while this is re-issued.
                                'href', instructor_portal_url(s.id, '/instructor/schedule')),
             -- One reminder for that week, ever. A second is nagging, and the
             -- escalation is the next step rather than a louder repeat.
             'week_remind:' || r.id || ':' || v_week) is not null
        then n_remind := n_remind + 1; end if;
      end loop;
    end if;

    -- ---- escalate, to the studio, about the next few days only -------------
    if v_dow = s.esc_dow then
      v_sum := unconfirmed_summary(s.id, studio_week_start(s.id, v_today) + 7, s.esc_days);
      -- The window straddles the week boundary on a Sunday, so ask about the
      -- week that is starting as well as the one just ending.
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
          -- Per studio per day, so the same Sunday cannot send twice.
          'week_unconfirmed:' || s.id || ':' || v_today);
        n_escalate := n_escalate + coalesce(v_n, 0);
      end if;
    end if;
  end loop;

  return jsonb_build_object('studios', v_studios, 'asked', n_ask,
                            'reminded', n_remind, 'escalated', n_escalate);
end $$;

-- cover_available: bare domain -> portal /instructor/shifts
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
           and instructor_available_at(i.id, o.starts_at, o.ends_at)
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

-- shift_declined (auto-declined on approve): staff /shifts -> portal /instructor/shifts
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
  v_when  := to_char(occ.starts_at at time zone v_tz, 'FMDay FMDD FMMonth YYYY, HH24:MI');
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
end $function$;

-- shift_declined (on decline): staff /shifts -> portal /instructor/shifts
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
  v_when := to_char(occ.starts_at at time zone v_tz, 'FMDay FMDD FMMonth YYYY, HH24:MI');

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
end $function$;

-- The copy: an instructor reads these on a phone, so "your instructor app".
update notification_templates set
  text_body = E'Hi {instructor_name},\n\n{studio_name} needs your availability for {period} by {due_on}.\n\nOpen your instructor app and fill in the month: {href}\n\nThank you,\n{studio_name}'
where key = 'availability_due';

update notification_templates set
  text_body = E'Hi {instructor_name},\n\n{studio_name} has asked for a change to your {period} availability:\n\n{note}\n\nOpen your instructor app to update it.\n\nThank you,\n{studio_name}',
  html_body = '<p>Hi {instructor_name},</p><p>{studio_name} has asked for a change to your <strong>{period}</strong> availability:</p><blockquote>{note}</blockquote><p>Open your instructor app to update it.</p><p>Thank you,<br>{studio_name}</p>'
where key = 'availability_changes_requested';

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

