-- Decision 58 amendment — the cover picker shows every instructor, and a
-- directed cover ask is a full flow (its own email + the requester told).
--
-- re-issues: instructor_colleagues(uuid), request_cover(uuid, text, uuid),
--   accept_cover(uuid), decline_directed_cover(uuid), sweep_cover_escalations()
--
-- (1) instructor_colleagues returns EVERY active instructor of the studio with a
--     has_login boolean, so the picker can show a no-login colleague greyed.
-- (2) A directed ask sends its OWN email `cover_asked` (class/day/time/room/
--     booked/reason/requester/href) rather than the generic "whoever takes it
--     first" `cover_available`. A no-login colleague is refused PT400 by name.
-- (3) The requester is told when the colleague confirms (`cover_asked_confirmed`,
--     the right sentence for auto-accept-final vs awaits-approval) and when the
--     colleague can't / the escalation opens it (`cover_asked_declined`).
--
-- Decision 18 untouched: nothing new makes a cover final — only staff approval
-- (cover_needs_approval) or cover_auto_accept_enabled. Anon stays THIRTEEN.
-- Dates carry the year via to_char; times via fmt_clock_s (Decision 33/55).

-- =============================================================================
-- (0) Templates.
-- =============================================================================
insert into notification_templates (key, subject, text_body, html_body, note) values
('cover_asked',
 '{requester_name} is asking you to cover {class_name} on {day}',
 E'Hi {name},\n\n{requester_name} can''t make {class_name} on {day} at {time}{room_phrase} ({booked_phrase}) and is asking you to cover. {reason_line}Confirm in your instructor app: {href}\n\nIf you can''t, tap Can''t there and it opens to everyone.',
 '<p>Hi {name},</p><p>{requester_name} can&rsquo;t make <strong>{class_name}</strong> on {day} at {time}{room_phrase} ({booked_phrase}) and is asking you to cover. {reason_line}<a href="{href}">Confirm in your instructor app</a>.</p><p>If you can&rsquo;t, tap Can&rsquo;t there and it opens to everyone.</p>',
 'Decision 58 amendment. A cover request directed at a named colleague — the full class details and a Confirm link, not the generic whoever-takes-it-first email.'),
('cover_asked_confirmed',
 'Cover for {class_name} on {day}',
 E'Hi {instructor_name},\n\n{message}\n\n{studio_name}',
 '<p>Hi {instructor_name},</p><p>{message}</p><p>{studio_name}</p>',
 'Decision 58 amendment. To the requester when the colleague they asked confirms — "is covering … you''re off it" (auto-accept final) or "agreed … the studio will confirm" (awaits approval).'),
('cover_asked_declined',
 '{colleague_name} can''t cover {class_name}',
 E'Hi {instructor_name},\n\n{colleague_name} can''t cover {class_name} on {day} — it''s now open to everyone. You''re still down to teach it until someone covers it.\n\n{studio_name}',
 '<p>Hi {instructor_name},</p><p>{colleague_name} can&rsquo;t cover <strong>{class_name}</strong> on {day} — it&rsquo;s now open to everyone. You&rsquo;re still down to teach it until someone covers it.</p><p>{studio_name}</p>',
 'Decision 58 amendment. To the requester when the colleague taps Can''t or the escalation opens the directed ask to everyone.')
on conflict (key) do nothing;

-- =============================================================================
-- (1) instructor_colleagues — EVERY active instructor + has_login. A returns-
--     table column change, so drop + recreate; ACL re-asserted.
-- =============================================================================
drop function if exists instructor_colleagues(uuid);
create function instructor_colleagues(p_instructor_id uuid)
returns table(instructor_id uuid, display_name text, has_login boolean)
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
  -- Every active instructor of the studio, not only those with a login. The
  -- picker greys a no-login colleague (they cannot be chosen — the request would
  -- reach nobody); request_cover refuses one by name as a belt.
  return query
    select i.id, i.display_name, instructor_user_id(i.id) is not null
      from instructors i
     where i.studio_id = v_studio and i.status = 'active' and i.id <> p_instructor_id
     order by i.display_name;
end $$;
revoke execute on function instructor_colleagues(uuid) from public, anon;
grant  execute on function instructor_colleagues(uuid) to authenticated, service_role;

-- =============================================================================
-- (2) request_cover — directed branch queues `cover_asked`; a no-login colleague
--     is refused by name. Re-issued from 20260832190000; everything else
--     byte-for-byte. Signature unchanged, so create-or-replace keeps the ACL.
-- =============================================================================
create or replace function request_cover(p_occurrence_id uuid, p_reason text default null, p_ask_instructor_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o class_occurrences%rowtype; s studios%rowtype; st studio_settings%rowtype;
  v_instr uuid; v_req cover_requests%rowtype; v_hours numeric; v_urgent boolean;
  v_name text; v_asked_name text; n int; d record; v_offered int := 0; v_room text;
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
  -- studio (the picker shows all of them), AND one who has a login — otherwise
  -- the request would reach nobody. The two are told apart so the login case can
  -- name the person and point at inviting them.
  if p_ask_instructor_id is not null then
    if not exists (select 1 from instructors i
                    where i.id = p_ask_instructor_id and i.studio_id = o.studio_id
                      and i.status = 'active' and i.id <> v_instr) then
      raise exception 'that is not a colleague who can be asked to cover' using errcode = 'PT400';
    end if;
    if instructor_user_id(p_ask_instructor_id) is null then
      raise exception '% doesn''t have an app login yet — ask the studio to invite them.',
        coalesce((select display_name from instructors where id = p_ask_instructor_id), 'That instructor')
        using errcode = 'PT400';
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
  select r.name into v_room from rooms r where r.id = o.room_id;
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
    -- DIRECTED: email the named colleague alone with the full class details and a
    -- Confirm link (cover_asked — never the generic cover_available); the sweep
    -- opens it to everyone later if they don't answer, so escalated_at is null.
    select display_name into v_asked_name from instructors where id = p_ask_instructor_id;
    if queue_shift_notice(o.studio_id, instructor_user_id(p_ask_instructor_id), 'cover_asked',
         jsonb_build_object(
           'name', v_asked_name, 'requester_name', v_name, 'class_name', o.name,
           'day', to_char(o.starts_at at time zone s.timezone, 'FMDy FMDD FMMon'),
           'time', fmt_clock_s(o.starts_at, o.studio_id),
           'room_phrase', case when v_room is not null then ' in ' || v_room else '' end,
           'booked_phrase', case when o.booked_count > 0 then format('%s booked', o.booked_count) else 'nobody booked yet' end,
           'reason_line', case when nullif(btrim(coalesce(p_reason,'')), '') is null then ''
                               else btrim(p_reason) || '. ' end,
           'href', instructor_portal_url(o.studio_id, '/instructor/shifts')),
         'cover_asked:' || v_req.id || ':' || p_ask_instructor_id) is not null
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

-- =============================================================================
-- (3) accept_cover — the directed branches now tell the REQUESTER via
--     cover_asked_confirmed (the right sentence for final vs awaits-approval).
--     Re-issued from 20260832190000; the everyone path is byte-for-byte.
-- =============================================================================
create or replace function accept_cover(p_occurrence_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o class_occurrences%rowtype; s studios%rowtype; st studio_settings%rowtype; req cover_requests%rowtype;
  v_taker uuid; v_hours numeric; v_old text; v_new text; v_subs int := 0;
  v_cut timestamptz; v_user uuid; v_asked_name text; v_when text; v_day text;
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
  v_day  := to_char(o.starts_at at time zone s.timezone, 'FMDy FMDD FMMon');

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
      -- Decision 58 amendment: tell the requester it is covered and they are off.
      v_user := instructor_user_id(req.instructor_id);
      if v_user is not null then
        perform queue_shift_notice(o.studio_id, v_user, 'cover_asked_confirmed',
          jsonb_build_object('instructor_name', coalesce(v_old, 'there'), 'studio_name', s.name,
            'class_name', o.name, 'day', v_day,
            'message', coalesce(v_new, 'Someone') || ' is covering ' || o.name || ' on ' || v_day || ' — you''re off it.'),
          'cover_asked_confirmed:' || req.id);
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
      -- Decision 58 amendment: tell the requester the colleague agreed; it awaits
      -- the studio's approval (nothing is final yet — Decision 18).
      v_user := instructor_user_id(req.instructor_id);
      if v_user is not null then
        perform queue_shift_notice(o.studio_id, v_user, 'cover_asked_confirmed',
          jsonb_build_object('instructor_name', coalesce(v_old, 'there'), 'studio_name', s.name,
            'class_name', o.name, 'day', v_day,
            'message', coalesce(v_new, 'Someone') || ' agreed to cover ' || o.name || ' on ' || v_day || '; the studio will confirm.'),
          'cover_asked_confirmed:' || req.id);
      end if;
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

-- =============================================================================
-- (4) decline_directed_cover — the colleague's "Can't" tells the requester via
--     cover_asked_declined. Re-issued from 20260832190000.
-- =============================================================================
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
    perform queue_shift_notice(req.studio_id, v_user, 'cover_asked_declined',
      jsonb_build_object(
        'instructor_name', (select display_name from instructors where id = req.instructor_id),
        'colleague_name', (select display_name from instructors where id = v_asked),
        'class_name', o.name,
        'day', to_char(o.starts_at at time zone s.timezone, 'FMDy FMDD FMMon'),
        'studio_name', s.name),
      'cover_asked_declined:' || req.id);
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (req.studio_id, auth.uid(), 'cover.directed_declined', 'cover_requests', req.id,
          jsonb_build_object('by', v_asked));
  return jsonb_build_object('ok', true, 'opened', true);
end $$;
revoke execute on function decline_directed_cover(uuid) from public, anon;
grant  execute on function decline_directed_cover(uuid) to authenticated, service_role;

-- =============================================================================
-- (5) sweep_cover_escalations — the directed-timeout pass tells the requester via
--     cover_asked_declined. Re-issued from 20260832190000; the staff-urgent pass
--     is byte-for-byte.
-- =============================================================================
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
  -- everyone, and the requester is told (cover_asked_declined — same "now open to
  -- everyone" sentence as a Can't). Idempotent — once opened, asked_instructor_id
  -- is null and the row no longer matches.
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
      perform queue_shift_notice(r.studio_id, instructor_user_id(r.instructor_id), 'cover_asked_declined',
        jsonb_build_object(
          'instructor_name', (select display_name from instructors where id = r.instructor_id),
          'colleague_name', (select display_name from instructors where id = r.asked_instructor_id),
          'class_name', r.name,
          'day', to_char(r.starts_at at time zone r.timezone, 'FMDy FMDD FMMon'),
          'studio_name', (select name from studios where id = r.studio_id)),
        'cover_asked_declined:' || r.id);
    end if;
    n := n + 1;
  end loop;

  return n;
end $$;

-- The anon surface is unchanged — exactly THIRTEEN pre-login functions.
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % functions, expected exactly 13', n; end if;
end $$;
