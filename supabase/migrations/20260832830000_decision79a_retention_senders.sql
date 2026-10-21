-- Decision 79a — the retention page's RPCs: the snapshot, the per-member email
-- context, the two senders, a manual contact log, and snooze.
--
-- creates: retention_can_act(uuid), retention_email_context(uuid, text),
--          member_snapshot(uuid), retention_task_kind(text),
--          send_retention_email(uuid, text, text, text, text),
--          send_retention_email_bulk(uuid[], text, text, text, text),
--          send_retention_test(uuid, text, text, text),
--          record_contact(uuid, text, text), snooze_task(uuid, uuid, text, int)
-- Authorised by Deanna, 21 Oct 2026.

-- One place that answers "may this caller work this studio's retention": a
-- manager, or front desk when the studio routes retention to them.
create or replace function retention_can_act(p_studio_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(is_manager_up(p_studio_id), false)
      or (coalesce(is_desk_up(p_studio_id), false)
          and coalesce((select retention_tasks_to from studio_settings
                         where studio_id = p_studio_id), 'owner_manager') = 'front_desk')
      or is_service_context();
$$;
revoke execute on function retention_can_act(uuid) from public, anon;
grant  execute on function retention_can_act(uuid) to authenticated, service_role;

-- retention_email_context — the placeholder jsonb for one member, used by the
-- composer pre-fill and by both senders. Mirrors the convert sweep's context.
create or replace function retention_email_context(p_member_id uuid, p_situation text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  s studios%rowtype; st studio_settings%rowtype; m members%rowtype;
  v_studio uuid; v_tz text; v_today date;
  v_last_class text; v_last_date date; v_instr text;
  v_days int; v_plan text; v_expires date;
  v_offer membership_plans%rowtype; v_offer_name text; v_buy text; v_book text;
begin
  select studio_id into v_studio from members where id = p_member_id;
  if v_studio is null then raise exception 'no such member' using errcode = 'PT404'; end if;
  if not retention_can_act(v_studio) then
    raise exception 'that is not your member' using errcode = 'PT403';
  end if;
  select * into s from studios where id = v_studio;
  select * into st from studio_settings where studio_id = v_studio;
  select * into m from members where id = p_member_id;
  v_tz := s.timezone;
  v_today := (now() at time zone v_tz)::date;

  -- The member's most recent class (attended if we have a check-in, else booked).
  select coalesce(ct.name, o.name, 'your class'),
         (o.starts_at at time zone v_tz)::date,
         split_part(coalesce(i.display_name, ''), ' ', 1)
    into v_last_class, v_last_date, v_instr
    from check_ins ci
    join class_occurrences o on o.id = ci.occurrence_id
    left join class_types ct on ct.id = o.class_type_id
    left join instructors i on i.id = o.instructor_id
   where ci.member_id = p_member_id
   order by ci.checked_in_at desc limit 1;
  if v_last_class is null then
    select coalesce(ct.name, o.name, 'your class'),
           (o.starts_at at time zone v_tz)::date,
           split_part(coalesce(i.display_name, ''), ' ', 1)
      into v_last_class, v_last_date, v_instr
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
      left join class_types ct on ct.id = o.class_type_id
      left join instructors i on i.id = o.instructor_id
     where b.member_id = p_member_id
     order by o.starts_at desc limit 1;
  end if;

  v_days := greatest(0, v_today - coalesce(m.last_visit_at::date, m.first_visit_at::date, v_last_date, v_today));

  -- The member's most relevant plan (active first, then latest-ending).
  select mp.name, coalesce(ms.expires_on, (ms.current_period_end at time zone v_tz)::date)
    into v_plan, v_expires
    from memberships ms join membership_plans mp on mp.id = ms.plan_id
   where ms.member_id = p_member_id
   order by (ms.status = 'active') desc,
            coalesce(ms.expires_on, (ms.current_period_end at time zone v_tz)::date, '-infinity'::date) desc
   limit 1;

  v_book := member_portal_url(v_studio, '/book');
  if st.intro_offer_plan_id is not null then
    select * into v_offer from membership_plans where id = st.intro_offer_plan_id;
  end if;
  if v_offer.id is not null then
    v_buy := member_portal_url(v_studio, '/buy/' || v_offer.id::text);
    v_offer_name := v_offer.name;
  else
    v_buy := member_portal_url(v_studio, '/account/plan');
    v_offer_name := 'a membership';
  end if;

  return jsonb_build_object(
    'first_name', coalesce(nullif(m.first_name, ''), 'there'),
    'last_class', v_last_class,
    'last_class_date', case when v_last_date is not null then to_char(v_last_date, 'FMDD Mon') else '' end,
    'instructor_first', coalesce(nullif(v_instr, ''), 'your instructor'),
    'days_since', v_days::text,
    'plan_name', coalesce(v_plan, 'your plan'),
    'expires_on', case when v_expires is not null then to_char(v_expires, 'FMDay FMDD Mon') else '' end,
    'offer_plan_name', v_offer_name,
    'buy_url', v_buy,
    'book_url', v_book,
    'studio_name', s.name);
end $$;
revoke execute on function retention_email_context(uuid, text) from public, anon;
grant  execute on function retention_email_context(uuid, text) to authenticated, service_role;

-- member_snapshot — everything the side panel shows, in one read.
create or replace function member_snapshot(p_member_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_tz text; po record; m members%rowtype; v_out jsonb;
  v_visits30 int; v_usual_class text; v_usual_instr text;
  v_task jsonb; v_contact jsonb; v_journey jsonb;
begin
  select studio_id into v_studio from members where id = p_member_id;
  if v_studio is null then raise exception 'no such member' using errcode = 'PT404'; end if;
  if not retention_can_act(v_studio) then
    raise exception 'that is not your member' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = v_studio;
  select * into m from members where id = p_member_id;
  select * into po from member_plan_overview(v_studio) o where o.id = p_member_id;

  select count(*)::int into v_visits30 from check_ins ci
   where ci.member_id = p_member_id
     and (ci.checked_in_at at time zone v_tz)::date >= (now() at time zone v_tz)::date - 30;

  select ct.name into v_usual_class
    from check_ins ci join class_occurrences o on o.id = ci.occurrence_id
    join class_types ct on ct.id = o.class_type_id
   where ci.member_id = p_member_id
   group by ct.name order by count(*) desc, ct.name limit 1;
  select split_part(i.display_name, ' ', 1) into v_usual_instr
    from check_ins ci join class_occurrences o on o.id = ci.occurrence_id
    join instructors i on i.id = o.instructor_id
   where ci.member_id = p_member_id
   group by i.display_name order by count(*) desc, i.display_name limit 1;

  select jsonb_build_object('id', t.id, 'kind', t.kind, 'reason', t.reason,
                            'status', t.status, 'due_at', t.due_at)
    into v_task
    from member_tasks t
   where t.member_id = p_member_id and t.status = 'open'
   order by t.created_at desc limit 1;

  select jsonb_build_object('at', mc.contacted_at, 'method', mc.method,
            'by', (select full_name from profiles where id = mc.staff_id),
            'situation', mc.situation, 'subject', mc.subject,
            'outcome', mc.outcome, 'outcome_days', mc.outcome_days)
    into v_contact
    from member_contacts mc
   where mc.member_id = p_member_id
   order by mc.contacted_at desc limit 1;

  select jsonb_agg(jsonb_build_object('at', j.at, 'kind', j.kind, 'title', j.title, 'detail', j.detail))
    into v_journey
    from (select * from member_activity(p_member_id, '2000-01-01', '2100-01-01')
          order by at desc limit 5) j;

  v_out := jsonb_build_object(
    'member_id', p_member_id,
    'first_name', m.first_name, 'last_name', m.last_name,
    'email', m.email, 'phone', m.phone,
    'plan_state', po.plan_state, 'free_stage', po.free_stage,
    'current_plan_name', po.current_plan_name, 'plan_type', po.plan_type,
    'membership_status', po.membership_status, 'expires_on', po.expires_on,
    'credits_remaining', po.credits_remaining, 'complimentary', po.complimentary,
    'health_band', m.health_band, 'health_reason', m.health_reason,
    'last_visit_at', m.last_visit_at, 'visits_30d', coalesce(v_visits30, 0),
    'usual_class', v_usual_class, 'usual_instructor', v_usual_instr,
    'task', v_task, 'last_contact', v_contact,
    'journey', coalesce(v_journey, '[]'::jsonb));
  return v_out;
end $$;
revoke execute on function member_snapshot(uuid) from public, anon;
grant  execute on function member_snapshot(uuid) to authenticated, service_role;

-- The task kind a situation owns, or null for the task-less sections.
create or replace function retention_task_kind(p_situation text) returns text
language sql immutable as $$
  select case p_situation
           when 'unconverted' then 'unconverted_day7'
           when 'at_risk' then 'at_risk'
           when 'drifting' then 'drifting_fyi'
           else null end;
$$;
revoke execute on function retention_task_kind(text) from public, anon, authenticated;
grant  execute on function retention_task_kind(text) to service_role;

-- send_retention_email — queue one email, log the contact, link the task.
create or replace function send_retention_email(
  p_member_id uuid, p_situation text, p_subject text, p_body_html text, p_body_text text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_studio uuid; v_tz text; s studios%rowtype; v_email text;
  v_ctx jsonb; v_nid uuid; v_cid uuid; v_kind text; v_dedupe text;
begin
  select studio_id into v_studio from members where id = p_member_id;
  if v_studio is null then raise exception 'no such member' using errcode = 'PT404'; end if;
  if not retention_can_act(v_studio) then
    raise exception 'that is not your member' using errcode = 'PT403';
  end if;
  if nullif(btrim(coalesce(p_subject, '')), '') is null
     or nullif(btrim(coalesce(p_body_text, '')), '') is null then
    raise exception 'An email needs a subject and a message.' using errcode = 'PT400';
  end if;
  select * into s from studios where id = v_studio;
  v_tz := s.timezone;
  select nullif(email, '') into v_email from members where id = p_member_id;
  if v_email is null then return jsonb_build_object('ok', false, 'reason', 'no_email'); end if;
  if not notification_wanted(p_member_id, 'retention') then
    return jsonb_build_object('ok', false, 'reason', 'muted');
  end if;

  v_ctx := retention_email_context(p_member_id, p_situation);
  v_dedupe := 'retention:' || p_member_id::text || ':' || p_situation || ':'
              || to_char(now() at time zone v_tz, 'YYYY-MM-DD');
  v_nid := queue_notification(v_studio, p_member_id, 'retention',
    v_ctx || jsonb_build_object('subject', p_subject, 'body', p_body_text,
                                'body_html', p_body_html, 'studio_name', s.name),
    v_dedupe);
  if v_nid is null then
    return jsonb_build_object('ok', false, 'reason', 'duplicate');
  end if;

  insert into member_contacts (studio_id, member_id, situation, method, subject, staff_id)
    values (v_studio, p_member_id, p_situation, 'email', p_subject, auth.uid())
    returning id into v_cid;

  v_kind := retention_task_kind(p_situation);
  if v_kind is not null then
    update member_tasks set status = 'contacted', contacted_at = now(),
           contacted_by = auth.uid(), contact_id = v_cid
     where member_id = p_member_id and kind = v_kind and status = 'open';
  end if;

  return jsonb_build_object('ok', true, 'notification_id', v_nid, 'contact_id', v_cid);
end $$;
revoke execute on function send_retention_email(uuid, text, text, text, text) from public, anon;
grant  execute on function send_retention_email(uuid, text, text, text, text) to authenticated, service_role;

-- send_retention_email_bulk — one email per member, each rendered with that
-- member's own context (the body carries {placeholders}); capped at 50.
create or replace function send_retention_email_bulk(
  p_member_ids uuid[], p_situation text, p_subject text, p_body_html text, p_body_text text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_res jsonb; v_sent int := 0; v_skipped jsonb := '[]'::jsonb;
begin
  if array_length(p_member_ids, 1) is null then
    return jsonb_build_object('sent', 0, 'skipped', '[]'::jsonb);
  end if;
  if array_length(p_member_ids, 1) > 50 then
    raise exception 'Email at most 50 members at a time.' using errcode = 'PT400';
  end if;
  foreach v_id in array p_member_ids loop
    if exists (select 1 from members where id = v_id and deleted_at is not null) then
      v_skipped := v_skipped || jsonb_build_object('member', v_id, 'reason', 'deleted');
      continue;
    end if;
    v_res := send_retention_email(v_id, p_situation, p_subject, p_body_html, p_body_text);
    if coalesce((v_res ->> 'ok')::boolean, false) then
      v_sent := v_sent + 1;
    else
      v_skipped := v_skipped || jsonb_build_object('member', v_id, 'reason', v_res ->> 'reason');
    end if;
  end loop;
  return jsonb_build_object('sent', v_sent, 'skipped', v_skipped);
end $$;
revoke execute on function send_retention_email_bulk(uuid[], text, text, text, text) from public, anon;
grant  execute on function send_retention_email_bulk(uuid[], text, text, text, text) to authenticated, service_role;

-- send_retention_test — the composer's current content to the caller's own
-- staff email, so "Send me a test" shows exactly what a member would receive.
create or replace function send_retention_test(
  p_studio_id uuid, p_subject text, p_body_html text, p_body_text text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_email text; s studios%rowtype;
begin
  if not retention_can_act(p_studio_id) then
    raise exception 'that is not your studio' using errcode = 'PT403';
  end if;
  select ss.email into v_email from studio_staff ss
   where ss.studio_id = p_studio_id and ss.user_id = auth.uid() and ss.status = 'active';
  if coalesce(v_email, '') = '' then
    raise exception 'no email on file for your account' using errcode = 'PT422';
  end if;
  select * into s from studios where id = p_studio_id;
  -- member_id null + to_email in the payload addresses the staff member directly;
  -- a sample first_name renders any placeholder the owner left in.
  perform queue_notification(p_studio_id, null, 'retention',
    jsonb_build_object('to_email', v_email, 'subject', '[Test] ' || p_subject,
      'body', p_body_text, 'body_html', p_body_html,
      'first_name', 'there', 'studio_name', s.name,
      'last_class', 'Reformer Flow', 'last_class_date', '09 Nov',
      'instructor_first', 'Ada', 'days_since', '12',
      'plan_name', 'Unlimited Monthly', 'expires_on', 'Sun 24 Nov',
      'offer_plan_name', 'Intro Pack',
      'buy_url', member_portal_url(p_studio_id, '/account/plan'),
      'book_url', member_portal_url(p_studio_id, '/book')),
    'retention_test:' || p_studio_id::text || ':' || extract(epoch from clock_timestamp())::bigint::text);
  return jsonb_build_object('ok', true, 'to', v_email);
end $$;
revoke execute on function send_retention_test(uuid, text, text, text) from public, anon;
grant  execute on function send_retention_test(uuid, text, text, text) to authenticated, service_role;

-- record_contact — a Viber / call / in-person contact, logged like an email but
-- with no subject and nothing queued.
create or replace function record_contact(p_member_id uuid, p_situation text, p_method text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_studio uuid; v_cid uuid; v_kind text;
begin
  select studio_id into v_studio from members where id = p_member_id;
  if v_studio is null then raise exception 'no such member' using errcode = 'PT404'; end if;
  if not retention_can_act(v_studio) then
    raise exception 'that is not your member' using errcode = 'PT403';
  end if;
  if p_method not in ('viber', 'call', 'in_person') then
    raise exception 'A logged contact is Viber, a call, or in person.' using errcode = 'PT400';
  end if;
  insert into member_contacts (studio_id, member_id, situation, method, staff_id)
    values (v_studio, p_member_id, p_situation, p_method, auth.uid())
    returning id into v_cid;
  v_kind := retention_task_kind(p_situation);
  if v_kind is not null then
    update member_tasks set status = 'contacted', contacted_at = now(),
           contacted_by = auth.uid(), contact_id = v_cid
     where member_id = p_member_id and kind = v_kind and status = 'open';
  end if;
  return jsonb_build_object('ok', true, 'contact_id', v_cid);
end $$;
revoke execute on function record_contact(uuid, text, text) from public, anon;
grant  execute on function record_contact(uuid, text, text) to authenticated, service_role;

-- snooze_task — push an open task's due date, or, for a task-less section, create
-- a lightweight 'follow_up' task that holds the member off the board until due.
create or replace function snooze_task(
  p_task_id uuid, p_member_id uuid, p_situation text, p_days int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_studio uuid; v_role text; v_tid uuid; v_due timestamptz;
begin
  select studio_id into v_studio from members where id = p_member_id;
  if v_studio is null then raise exception 'no such member' using errcode = 'PT404'; end if;
  if not retention_can_act(v_studio) then
    raise exception 'that is not your member' using errcode = 'PT403';
  end if;
  if coalesce(p_days, 0) <= 0 then
    raise exception 'Snooze by at least a day.' using errcode = 'PT400';
  end if;
  v_due := now() + make_interval(days => p_days);

  if p_task_id is not null then
    update member_tasks set due_at = v_due
     where id = p_task_id and member_id = p_member_id and status = 'open'
     returning id into v_tid;
    if v_tid is not null then
      return jsonb_build_object('ok', true, 'task_id', v_tid);
    end if;
  end if;

  select coalesce(retention_tasks_to, 'owner_manager') into v_role
    from studio_settings where studio_id = v_studio;
  insert into member_tasks (studio_id, member_id, kind, reason, assigned_role, status, due_at)
    values (v_studio, p_member_id, 'follow_up',
            'Snoozed' || coalesce(' from ' || nullif(p_situation, ''), ''),
            coalesce(v_role, 'owner_manager'), 'open', v_due)
    on conflict (member_id, kind) where status = 'open'
      do update set due_at = excluded.due_at, reason = excluded.reason
    returning id into v_tid;
  return jsonb_build_object('ok', true, 'task_id', v_tid);
end $$;
revoke execute on function snooze_task(uuid, uuid, text, int) from public, anon;
grant  execute on function snooze_task(uuid, uuid, text, int) to authenticated, service_role;
