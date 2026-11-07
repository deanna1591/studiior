-- Decision 92: Rebook a member from the roster.
-- creates: rebook_member(uuid, uuid)
-- re-issues: template_sample_context(uuid, text, text)
--
-- Staff move a member's booking from one class to another from the roster. The
-- seat moves IN PLACE (update occurrence_id) so its type travels unchanged —
-- free first, desk-unpaid, paid drop-in (its payments row is booking-keyed),
-- comp, plan credit, guest. Because every member-email / peak / infraction /
-- guest-sync trigger on bookings fires on UPDATE OF status, moving only
-- occurrence_id fires NONE of them: no confirmation, no cancellation, no peak
-- consumption, no strike. The vacated seat releases the normal way
-- (offer_waitlist_seat). A booking_rebooked email is queued via
-- queue_notification (the per-email switch and member preference apply). Reuses
-- move_booking_here's in-place-move shape without its instructor guard, its
-- today check or its check-in. Not anon; anon stays THIRTEEN.

-- ---------------------------------------------------------------- template
insert into notification_templates (key, subject, text_body, html_body, note) values (
 'booking_rebooked',
 'Rebooked: {class_name}, {when} ({studio_name})',
 E'Hi {first_name},\n\nWe''ve moved your booking. You''re now in {class_name} on {when} with {instructor_first_name}. Your credit (or free class) moved with it, nothing to do.\n\nCan''t make it? {manage_link}\n\nSee you in class,\n{studio_name}',
 '<p>Hi {first_name},</p>'
 '<p>We''ve moved your booking. You''re now in <strong>{class_name}</strong> on {when} with {instructor_first_name}. Your credit (or free class) moved with it, nothing to do.</p>'
 '<p>Can''t make it? <a href="{manage_link}">Manage this booking</a>.</p>'
 '<p><a href="{bookings_url}" style="display:inline-block;background:{accent};color:{accent_on};text-decoration:none;padding:12px 22px;border-radius:10px;font-weight:600">See my bookings</a></p>'
 '<p>See you in class,<br>{studio_name}</p>',
 'Decision 92. Sent when staff move a member''s booking to another class. Tokens: '
 'first_name, class_name, when, instructor_first_name, old_class_name, old_when, '
 'manage_link, bookings_url, studio_name.')
on conflict (key) do update
  set subject = excluded.subject, text_body = excluded.text_body,
      html_body = excluded.html_body, note = excluded.note;

-- ---------------------------------------------------------------- sample context
CREATE OR REPLACE FUNCTION public.template_sample_context(p_studio_id uuid, p_to_email text, p_first_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s studios%rowtype; st studio_settings%rowtype; v_tz text; v_fmt text;
  v_plan membership_plans%rowtype; o record; v_when text; v_offer_ends text;
  v_n3 text; v_n3line text; v_n3html text; v_links text;
  v_clist text; v_roster text; v_roster_html text; v_li text;
begin
  select * into s from studios where id = p_studio_id;
  select * into st from studio_settings where studio_id = p_studio_id;
  v_tz := s.timezone; v_fmt := coalesce(st.time_format, '24h');

  select o2.id, coalesce(ct.name, o2.name, 'a class') as cname, o2.starts_at,
         rm.name as room, split_part(coalesce(i.display_name, ''), ' ', 1) as instr
    into o
    from class_occurrences o2
    left join class_types ct on ct.id = o2.class_type_id
    left join rooms rm on rm.id = o2.room_id
    left join instructors i on i.id = o2.instructor_id
   where o2.studio_id = p_studio_id and o2.status = 'scheduled' and o2.starts_at > now()
   order by o2.starts_at limit 1;

  if st.intro_offer_plan_id is not null then
    select * into v_plan from membership_plans where id = st.intro_offer_plan_id;
  end if;
  if v_plan.id is null then
    select * into v_plan from membership_plans
     where studio_id = p_studio_id and status = 'active' order by sort_order limit 1;
  end if;

  v_when := case when o.starts_at is not null
    then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD Mon') || ' at ' || fmt_clock(o.starts_at, v_tz, v_fmt)
    else '' end;
  v_offer_ends := to_char((now() + interval '14 days') at time zone v_tz, 'FMDD Mon YYYY');

  with s3(nm, ts) as (
    values
      ('Reformer Flow', ((((now() at time zone v_tz)::date + 1) + time '07:00') at time zone v_tz)),
      ('Barre',         ((((now() at time zone v_tz)::date + 2) + time '18:00') at time zone v_tz)),
      ('Mat Pilates',   ((((now() at time zone v_tz)::date + 3) + time '09:00') at time zone v_tz))
  )
  select
    string_agg(to_char(ts at time zone v_tz, 'FMDy ') || fmt_clock(ts, v_tz, v_fmt) || ' ' || nm, '; ' order by ts),
    string_agg('<a href="' || member_portal_url(p_studio_id, '/book') || '">'
               || to_char(ts at time zone v_tz, 'FMDy ') || fmt_clock(ts, v_tz, v_fmt) || ' ' || nm || '</a>', ', ' order by ts),
    string_agg(to_char(ts at time zone v_tz, 'FMDay FMDD FMMon, ') || fmt_clock(ts, v_tz, v_fmt) || ' ' || nm, E'\n' order by ts),
    string_agg('<li>' || to_char(ts at time zone v_tz, 'FMDay FMDD FMMon, ') || fmt_clock(ts, v_tz, v_fmt) || ' ' || nm || '</li>', '' order by ts)
    into v_n3, v_links, v_roster, v_li
    from s3;
  v_clist := v_roster;
  v_roster_html := '<ul style="margin:0;padding-left:20px">' || v_li || '</ul>';
  v_n3line := ' Here are the next ones with space: ' || v_n3 || '.';
  v_n3html := '<p>Here are the next ones with space: ' || v_links || '.</p>';

  return jsonb_build_object(
    'to_email', p_to_email,
    'first_name', p_first_name,
    'studio_name', s.name,
    'class_name', coalesce(o.cname, 'a class'),
    'occurrence_id', o.id,
    'when', v_when,
    'where_line', case when nullif(o.room, '') is not null then ', in ' || o.room else '' end,
    'when_short', 'tomorrow',
    'when_time', case when o.starts_at is not null then fmt_clock(o.starts_at, v_tz, v_fmt) else '' end,
    'day', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMonth') else 'Monday 9 November' end,
    'time', case when o.starts_at is not null then fmt_clock(o.starts_at, v_tz, v_fmt) else '' end,
    'deadline_short', case when o.starts_at is not null then fmt_clock(o.starts_at - interval '12 hours', v_tz, v_fmt) || ' ' || to_char((o.starts_at - interval '12 hours') at time zone v_tz, 'FMDy') else 'the evening before' end,
    'cancel_deadline', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD Mon') else 'the day before' end,
    'manage_link', member_portal_url(p_studio_id, '/class/' || coalesce(o.id::text, '')),
    'book_url', member_portal_url(p_studio_id, '/book'),
    'schedule_url', member_portal_url(p_studio_id, '/book'),
    'offer_plan_name', coalesce(v_plan.name, 'a membership'),
    'offer_detail', coalesce(plan_card_detail(v_plan.id), ''),
    'offer_price', case when v_plan.id is not null then fmt_money(v_plan.price_cents, v_plan.currency) else '' end,
    'offer_ends', v_offer_ends,
    'buy_url', case when v_plan.id is not null then member_portal_url(p_studio_id, '/buy/' || v_plan.id::text) else member_portal_url(p_studio_id, '/account/plan') end,
    'plan_name', coalesce(v_plan.name, 'your plan'),
    'credits', '3', 'credits_left', '3',
    'expires_on', v_offer_ends, 'ends_on', v_offer_ends,
    'renew_url', case when v_plan.id is not null then member_portal_url(p_studio_id, '/buy/' || v_plan.id::text) else member_portal_url(p_studio_id, '/account/plan') end,
    'last_class', coalesce(o.cname, 'your class'),
    'last_class_date', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDD Mon') else '' end,
    'instructor_first', coalesce(nullif(o.instr, ''), 'your instructor'),
    'instructor_first_name', coalesce(nullif(o.instr, ''), 'your instructor'),
    'days_since', '10',
    'product', 'Grip socks', 'quantity', '1')
  || jsonb_build_object(
    'instructor_name', p_first_name,
    'href', instructor_portal_url(p_studio_id, '/instructor/schedule'),
    'schedule_link', instructor_portal_url(p_studio_id, '/instructor/schedule'),
    'booked_line', '3 booked',
    'count', '3',
    'plural', 's',
    'month', to_char(now() at time zone v_tz, 'FMMonth'),
    'period', 'this period',
    'due_on', to_char((now() + interval '3 days') at time zone v_tz, 'FMDay FMDD Mon'),
    'due_wording', 'soon',
    'hours', '12',
    'amount', fmt_money(90000, s.currency),
    'old_when', case when o.starts_at is not null
                     then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMonth YYYY, ') || fmt_clock(o.starts_at, v_tz, v_fmt)
                     else 'Monday 9 November, 07:00' end,
    'cancelled_count', '1',
    'booked', '4',
    'capacity', '8',
    'reason', 'cancelled by the studio',
    'claim_url', member_portal_url(p_studio_id, '/class/' || coalesce(o.id::text, '')))
  || jsonb_build_object(
    'next_three', v_n3,
    'next_three_line', v_n3line,
    'next_three_html', v_n3html,
    'class_list', v_clist,
    'roster', v_roster,
    'roster_html', v_roster_html)
  -- Decision 89: the Messages templates' tokens, so a test send / preview fills.
  || jsonb_build_object(
    'staff_first_name', p_first_name,
    'member_name', coalesce(nullif(p_first_name, ''), 'A member'),
    'message', 'Hi, could I move my Saturday class to Sunday?',
    'message_html', 'Hi, could I move my Saturday class to Sunday?',
    'messages_url', member_portal_url(p_studio_id, '/messages'),
    'reply_url', coalesce(nullif(notification_setting('staff_app_origin'), ''), 'https://app.studiior.com') || '/messages')
  || jsonb_build_object(
    -- Decision 92: the rebook email's two extra tokens.
    'old_class_name', coalesce(o.cname, 'a class'),
    'bookings_url', member_portal_url(p_studio_id, '/'));
end $function$;
revoke execute on function template_sample_context(uuid, text, text) from public, anon, authenticated;
grant  execute on function template_sample_context(uuid, text, text) to service_role;

-- ---------------------------------------------------------------- rebook_member
create or replace function rebook_member(p_booking uuid, p_target uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_b bookings%rowtype; v_src class_occurrences%rowtype; v_tgt class_occurrences%rowtype;
  v_studio studios%rowtype; v_st studio_settings%rowtype; v_mem members%rowtype;
  v_tz text; v_fmt text; v_free int; v_covered boolean;
  v_when text; v_old_when text; v_instr text; v_src_name text; v_tgt_name text; v_manage text;
begin
  -- target + lock
  select * into v_tgt from class_occurrences where id = p_target for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no_such_class'); end if;

  -- staff of the target's studio (owner / manager / front desk). An instructor
  -- is not desk-up, so they are refused here — they keep the same-day
  -- "Move them here" on their own class (Decision 81a).
  if not coalesce(is_desk_up(v_tgt.studio_id), false) then
    raise exception 'only staff can rebook a member' using errcode = 'PT403';
  end if;

  select * into v_b from bookings where id = p_booking;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no_such_booking'); end if;
  if v_b.status not in ('booked','attended','pending_payment') then
    return jsonb_build_object('ok', false, 'reason', 'booking_not_live'); end if;
  if v_b.studio_id <> v_tgt.studio_id then
    return jsonb_build_object('ok', false, 'reason', 'different_studio'); end if;
  if v_b.occurrence_id = p_target then
    return jsonb_build_object('ok', false, 'reason', 'already_in_class'); end if;

  select * into v_src    from class_occurrences where id = v_b.occurrence_id;
  select * into v_studio from studios where id = v_tgt.studio_id;
  select * into v_st     from studio_settings where studio_id = v_tgt.studio_id;
  v_tz := v_studio.timezone; v_fmt := coalesce(v_st.time_format, '24h');

  -- the new class must be a real, scheduled, future class (staff skip the
  -- booking cut-off and the peak allowance, but never a past/cancelled class)
  if v_tgt.status <> 'scheduled' then
    return jsonb_build_object('ok', false, 'reason', 'class_not_scheduled'); end if;
  if v_tgt.starts_at <= now() then
    return jsonb_build_object('ok', false, 'reason', 'class_in_past'); end if;

  if exists (select 1 from bookings where occurrence_id = p_target and member_id = v_b.member_id
              and status in ('booked','attended','pending_payment','waitlisted')) then
    return jsonb_build_object('ok', false, 'reason', 'already_in_class'); end if;

  v_free := v_tgt.capacity - occurrence_seats_taken(p_target) - occurrence_seats_held(p_target);
  if v_free < 1 then return jsonb_build_object('ok', false, 'reason', 'class_full'); end if;

  -- a plan (membership) seat must cover the new class type (§2.1.9); a comp /
  -- free-first / drop-in / guest seat is not tied to a restricted plan.
  if v_b.membership_id is not null then
    select exists (
      select 1 from memberships ms join membership_plans mp on mp.id = ms.plan_id
       where ms.id = v_b.membership_id
         and ( (mp.restrictions -> 'class_type_ids') is null
            or jsonb_typeof(mp.restrictions -> 'class_type_ids') <> 'array'
            or jsonb_array_length(mp.restrictions -> 'class_type_ids') = 0
            or (v_tgt.class_type_id is not null
                and jsonb_exists(mp.restrictions -> 'class_type_ids', v_tgt.class_type_id::text)) )
    ) into v_covered;
    if not coalesce(v_covered, false) then
      return jsonb_build_object('ok', false, 'reason', 'plan_not_covering'); end if;
  end if;

  -- MOVE IN PLACE. status is unchanged, so no booking trigger fires (no
  -- confirmation, no cancellation, no peak, no strike). The suppress flag is
  -- set defensively in case an occurrence_id trigger is ever added.
  perform set_config('studiior.suppress_booking_email', '1', true);
  update bookings set occurrence_id = p_target, updated_at = now() where id = p_booking;
  update guest_passes set occurrence_id = p_target where guest_booking_id = p_booking;
  update class_occurrences set booked_count = greatest(booked_count - 1, 0) where id = v_src.id;
  update class_occurrences set booked_count = booked_count + 1 where id = p_target;
  perform set_config('studiior.suppress_booking_email', '0', true);

  -- free-first provisional rules re-evaluated in the new class (idempotent)
  perform confirm_provisional_seats_run(p_target);
  -- the vacated seat releases the normal way: promote the waitlist, no strike
  perform offer_waitlist_seat(v_src.id);

  -- tokens
  select * into v_mem from members where id = v_b.member_id;
  v_src_name := coalesce(v_src.name, (select name from class_types where id = v_src.class_type_id), 'a class');
  v_tgt_name := coalesce(v_tgt.name, (select name from class_types where id = v_tgt.class_type_id), 'a class');
  v_when     := to_char(v_tgt.starts_at at time zone v_tz, 'FMDay FMDD FMMonth YYYY, ') || fmt_clock(v_tgt.starts_at, v_tz, v_fmt);
  v_old_when := to_char(v_src.starts_at at time zone v_tz, 'FMDay FMDD FMMonth YYYY, ') || fmt_clock(v_src.starts_at, v_tz, v_fmt);
  v_instr    := coalesce(split_part((select display_name from instructors where id = v_tgt.instructor_id), ' ', 1), '');
  v_manage   := member_portal_url(v_tgt.studio_id, '/class/' || p_target::text);

  perform queue_notification(v_tgt.studio_id, v_b.member_id, 'booking_rebooked',
    jsonb_build_object(
      'first_name', coalesce(nullif(v_mem.preferred_name, ''), v_mem.first_name),
      'class_name', v_tgt_name, 'when', v_when, 'instructor_first_name', v_instr,
      'old_class_name', v_src_name, 'old_when', v_old_when,
      'manage_link', v_manage, 'bookings_url', member_portal_url(v_tgt.studio_id, '/'),
      'studio_name', v_studio.name, 'occurrence_id', p_target),
    'booking_rebooked:' || p_booking::text || ':' || p_target::text);

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (v_tgt.studio_id, auth.uid(), 'booking.rebooked', 'bookings', p_booking,
          jsonb_build_object('from_occurrence', v_src.id, 'from_class', v_src_name, 'from_when', v_old_when),
          jsonb_build_object('to_occurrence', p_target, 'to_class', v_tgt_name, 'to_when', v_when, 'member_id', v_b.member_id));

  return jsonb_build_object('ok', true, 'booking_id', p_booking, 'member_id', v_b.member_id,
    'class_name', v_tgt_name, 'when', v_when);
end $$;
revoke execute on function rebook_member(uuid, uuid) from public, anon;
grant  execute on function rebook_member(uuid, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------- anon stays THIRTEEN
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % (expected 13 — Decision 92 adds no anon function)', n; end if;
end $$;
