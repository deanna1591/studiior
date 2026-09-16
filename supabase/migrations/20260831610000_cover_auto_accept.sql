-- 156: auto-accept cover (a), and claim-then-drop counts (c).
--
-- (a) A cover request three weeks out can wait for approval; one for tomorrow
--     morning cannot. Per tenant (cover_auto_accept_enabled, off by default),
--     a cover request whose class is INSIDE cover_escalation_hours (Decision
--     18's existing window — reused, not a second setting) is offered to
--     qualified instructors, and the first eligible to take it is assigned
--     WITHOUT a staff approval round. Staff are told who took it; the instructor
--     who asked is told it is covered. Auto-accept skips the HUMAN, not the
--     CHECKS: qualified, inside their validity window, not already teaching,
--     available — all still enforced (move_occurrence hard-gates validity and
--     the clash). THE CORE CAP IS EXEMPT: the cap stops someone hoarding a
--     month, and an urgent cover is the opposite situation. And "no self-release"
--     stands — the class is only theirs to lose once someone else has taken it.
--
-- (c) Claiming then dropping is what "applied for 14, withdrew from 3" exists to
--     show, and it matters more when people pick their own classes. request_cover
--     now stamps the requester's own APPROVED shift application as withdrawn, so
--     instructor_reliability counts it — the claim (an approved application) and
--     the handing-back are both on the record.

alter table studio_settings
  add column if not exists cover_auto_accept_enabled boolean not null default false;
comment on column studio_settings.cover_auto_accept_enabled is
  'Per tenant, off by default. On: a cover request inside cover_escalation_hours '
  'is filled by the first qualified instructor to take it, no staff approval — '
  'staff notified. Beyond the window, staff approve as usual.';

insert into notification_templates (key, subject, text_body, html_body, note) values
('cover_available',
 'A class needs cover you can pick up now',
 E'Hi {instructor_name},\n\n{studio_name} needs cover for {class_name} on {when} — it is soon, so whoever takes it first gets it, no waiting on the studio.\n\n{booked_line}\n\nTake it here: {href}',
 '<p>Hi {instructor_name},</p><p>{studio_name} needs cover for <strong>{class_name}</strong> on {when} — it is soon, so whoever takes it first gets it, no waiting on the studio.</p><p>{booked_line}</p><p><a href="{href}">Take it</a></p>',
 'Migration 156. To qualified instructors when an urgent cover request can be '
 'auto-accepted (cover_auto_accept_enabled + inside cover_escalation_hours).'),
('cover_auto_covered',
 '{taker_name} is covering {class_name}',
 E'{taker_name} has taken {class_name} on {when} — the cover {requester_name} asked for. Nothing for you to approve; it is done.',
 '<p><strong>{taker_name}</strong> has taken <strong>{class_name}</strong> on {when} — the cover {requester_name} asked for. Nothing for you to approve; it is done.</p>',
 'Migration 156. To staff when a cover request was auto-accepted.')
on conflict (key) do nothing;

-- ---- request_cover — re-issued for (c) and the (a) offer --------------------
create or replace function request_cover(p_occurrence_id uuid, p_reason text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
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
      'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth, HH24:MI'),
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
               'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth, HH24:MI'),
               'booked_line', case when o.booked_count > 0
                 then format('%s member%s booked.', o.booked_count, case when o.booked_count = 1 then ' is' else 's are' end)
                 else 'Nobody has booked yet.' end,
               'href', coalesce(nullif(notification_setting('member_app_domain'), ''), 'studiior.app')),
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
revoke execute on function request_cover(uuid, text) from public, anon;
grant execute on function request_cover(uuid, text) to authenticated, service_role;

-- ---- accept_cover — an instructor takes an urgent, auto-acceptable cover -----
create or replace function accept_cover(p_occurrence_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
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
        'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth, HH24:MI'),
        'cover_line', coalesce(v_new, 'Someone else') || ' is taking it.'),
      'cover_approved:' || req.id);
  end if;
  -- Staff, told who took it (no approval was needed).
  perform queue_shift_notice_to_staff(o.studio_id, 'cover_auto_covered',
    jsonb_build_object('taker_name', coalesce(v_new, 'An instructor'),
      'requester_name', coalesce(v_old, 'an instructor'), 'class_name', o.name,
      'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth, HH24:MI')),
    'cover_auto:' || req.id);

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (o.studio_id, auth.uid(), 'cover.auto_covered', 'cover_requests', req.id,
          jsonb_build_object('covered_by', v_taker, 'members_told', v_subs));

  return jsonb_build_object('ok', true, 'covered_by', coalesce(v_new, 'you'), 'members_told', v_subs);
end $$;
revoke execute on function accept_cover(uuid) from public, anon;
grant execute on function accept_cover(uuid) to authenticated, service_role;

-- ---- cover_available_to — the portal's "cover needed now" list ---------------
create or replace function cover_available_to(p_instructor_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_tz text; v_res jsonb;
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

  select coalesce(jsonb_agg(x order by x.starts_at), '[]'::jsonb) into v_res
  from (
    select o.id, o.starts_at,
           to_char(o.starts_at at time zone v_tz, 'YYYY-MM-DD') as date,
           to_char(o.starts_at at time zone v_tz, 'HH24:MI') as time,
           o.name as class_name, ct.duration_minutes, r.name as room, o.booked_count as booked, o.capacity
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
end $$;
revoke execute on function cover_available_to(uuid) from public, anon;
grant execute on function cover_available_to(uuid) to authenticated, service_role;

do $$
begin
  if has_function_privilege('anon', 'accept_cover(uuid)', 'execute')
     or has_function_privilege('anon', 'cover_available_to(uuid)', 'execute') then
    raise exception 'migration 156: a cover function is anon-callable';
  end if;
end $$;
