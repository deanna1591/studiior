-- Decision 21 amendment — the member who has booked a flex class is told when
-- it will be confirmed, and told the outcome. Never why (no minimums, no counts,
-- no "not enough people"); the language is always about THEIR booking.
--
-- creates: flex_deadline_for_run(uuid), flex_deadline_for(uuid), member_pending_bookings(uuid)
-- re-issues: notification_wanted(uuid, text), notification_ics(uuid),
--            queue_booking_notifications(uuid), evaluate_commitment(uuid),
--            queue_occurrence_cancelled(uuid, cancellation_cause),
--            cancel_occurrence(uuid, text, cancellation_cause)

-- =============================================================================
-- 1. The deadline as a value members can be shown — the exact time the sweep
--    acts on (occurrence_guarantee_run's cutoff), so the promise is the act.
-- =============================================================================
-- The unguarded twin: the cutoff and its mode for a FLEX class that is still
-- undecided; (null, 'none') otherwise (core/always, decided, cancelled, or flex
-- demoted to always because the studio's flex switch is off).
create or replace function flex_deadline_for_run(p_occurrence_id uuid)
returns table(deadline_at timestamptz, mode text)
language plpgsql stable security definer set search_path = public as $$
declare o class_occurrences%rowtype; g record;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found or not coalesce(o.flex, false)
     or o.committed_at is not null or o.status <> 'scheduled' then
    return query select null::timestamptz, 'none'::text;
    return;
  end if;
  select * into g from occurrence_guarantee_run(p_occurrence_id);
  if g.tier <> 'flex' or g.cutoff_at is null then
    return query select null::timestamptz, 'none'::text;
    return;
  end if;
  return query select g.cutoff_at, g.cutoff_shape;
end $$;
revoke execute on function flex_deadline_for_run(uuid) from public, anon, authenticated;
grant  execute on function flex_deadline_for_run(uuid) to service_role;

-- The member-guarded wrapper: the caller holds a booking on the occurrence, or
-- it is a bookable class (scheduled + published) at their studio; else PT403.
-- coalesce-null-safe, like every member ownership guard.
create or replace function flex_deadline_for(p_occurrence_id uuid)
returns table(deadline_at timestamptz, mode text)
language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_member uuid;
begin
  select studio_id into v_studio from class_occurrences where id = p_occurrence_id;
  if v_studio is null then raise exception 'no such class' using errcode = 'PT404'; end if;
  select id into v_member from members where user_id = auth.uid() and studio_id = v_studio;
  if not is_manager_up(v_studio) and not is_service_context()
     and not coalesce(
       exists (select 1 from bookings b
                where b.occurrence_id = p_occurrence_id and b.member_id = v_member), false)
     and not (v_member is not null and exists (
       select 1 from class_occurrences o
        where o.id = p_occurrence_id and o.status = 'scheduled' and occurrence_published(o.id)))
  then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;
  return query select * from flex_deadline_for_run(p_occurrence_id);
end $$;
revoke execute on function flex_deadline_for(uuid) from public, anon;
grant  execute on function flex_deadline_for(uuid) to authenticated, service_role;

-- The caller's own bookings that are still pending confirmation, with the
-- deadline. Presence in this set IS booking_pending; nothing else is exposed —
-- no flex flag, no minimum, no counts. Drives Home and My bookings in one read.
create or replace function member_pending_bookings(p_studio_id uuid)
returns table(occurrence_id uuid, pending_until timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare v_member uuid;
begin
  select id into v_member from members where user_id = auth.uid() and studio_id = p_studio_id;
  if v_member is null then
    raise exception 'not a member of that studio' using errcode = 'PT403';
  end if;
  return query
  select o.id, d.deadline_at
    from bookings b
    join class_occurrences o on o.id = b.occurrence_id
    cross join lateral flex_deadline_for_run(o.id) d
   where b.member_id = v_member
     and b.status in ('booked', 'pending_payment')
     and coalesce(o.flex, false) and o.committed_at is null and o.status = 'scheduled'
     and d.deadline_at is not null;
end $$;
revoke execute on function member_pending_bookings(uuid) from public, anon;
grant  execute on function member_pending_bookings(uuid) to authenticated, service_role;

-- =============================================================================
-- 2. Templates (member). Year in dates per Decision 33 amendment.
-- =============================================================================
insert into notification_templates (key, subject, text_body, html_body, note) values
('flex_booking_pending',
 'You''re booked — {class_name}',
 E'You''re booked for {class_name}, {when}. You''ll receive a confirmation of your booking by {deadline_long}. Nothing else to do for now.',
 '<p>You''re booked for <strong>{class_name}</strong>, {when}.</p><p>You''ll receive a confirmation of your booking by {deadline_long}. Nothing else to do for now.</p>',
 'Decision 21 amendment. Replaces booking_confirmed for a flex class not yet decided; same dedupe key, same .ics.'),
('flex_booking_confirmed',
 '{class_name} on {day} is confirmed',
 E'{class_name} on {day} is confirmed — see you at {time}.',
 '<p><strong>{class_name}</strong> on {day} is confirmed — see you at {time}.</p>',
 'Decision 21 amendment. Sent when the flex sweep commits the class.'),
('flex_booking_not_confirmed',
 '{class_name}, {day_short} {time} — booking not confirmed',
 E'Your booking for {class_name} on {when} wasn''t confirmed this time. Your credit is back on your account and ready to use, so you can book another class straight away.{next_three_line}',
 '<p>Your booking for <strong>{class_name}</strong> on {when} wasn''t confirmed this time.</p><p>Your credit is back on your account and ready to use, so you can book another class straight away.</p>{next_three_html}',
 'Decision 21 amendment. Replaces class_cancelled for cancellation_cause = unmet_minimum only; same CANCEL .ics.')
on conflict (key) do nothing;

-- =============================================================================
-- 3. Preferences: the pending receipt follows booking_email (like
--    booking_confirmed); the outcome-either-way pair is always sent.
-- =============================================================================
create or replace function notification_wanted(p_member_id uuid, p_template text)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare p notification_preferences%rowtype;
begin
  if p_template in ('class_cancelled', 'instructor_substituted',
                    'payment_failed', 'staff_message', 'class_moved',
                    'member_invite', 'guest_invite', 'guest_host_cancelled',
                    'guest_waiver_reminder', 'guest_waiver_host_nudge',
                    -- Decision 21 amendment: the outcome of a flex booking is
                    -- told either way, like a cancellation.
                    'flex_booking_confirmed', 'flex_booking_not_confirmed') then
    return true;
  end if;

  select * into p from notification_preferences where member_id = p_member_id;
  if not found then
    return true;
  end if;

  return case p_template
    when 'booking_confirmed' then p.booking_email
    -- The pending receipt is the booking confirmation for a flex class, so it
    -- follows the same switch.
    when 'flex_booking_pending' then p.booking_email
    when 'class_reminder'    then p.reminder_email
    when 'waitlist_offer'    then p.waitlist_email
    when 'waitlist_missed'   then p.waitlist_email
    when 'credit_expiry'     then p.credit_expiry_email
    when 'milestone'         then p.milestone_email
    when 'challenge_joined'      then p.challenge_email
    when 'challenge_milestone'   then p.challenge_email
    when 'challenge_completed'   then p.challenge_email
    when 'challenge_ending_soon' then p.challenge_email
    when 'challenge_opening'     then p.challenge_email
    else true
  end;
end $$;

-- =============================================================================
-- 4. The .ics: the pending receipt carries the booking (REQUEST), and
--    not-confirmed carries the cancellation (CANCEL), exactly as class_cancelled.
-- =============================================================================
create or replace function notification_ics(p_notification_id uuid)
returns text language plpgsql stable security definer set search_path = public as $$
declare n notifications%rowtype; v_occ uuid; v_ve text; v_method text;
        v_instr uuid; v_month text; v_events text; v_org text; v_att text;
begin
  select * into n from notifications where id = p_notification_id;
  if not found then return null; end if;

  if n.template_key = 'month_roster' then
    v_instr := nullif(n.payload ->> 'instructor_id', '')::uuid;
    v_month := nullif(n.payload ->> 'month_ym', '');
    if v_instr is null or v_month is null then return null; end if;
    v_events := instructor_month_vevents(n.studio_id, v_instr, to_date(v_month || '-01', 'YYYY-MM-DD'));
    if nullif(v_events, '') is null then return null; end if;
    return ics_calendar('PUBLISH', v_events);
  end if;

  v_occ := nullif(n.payload ->> 'occurrence_id', '')::uuid;
  if v_occ is null then return null; end if;

  select coalesce(nullif(s.contact_email, ''),
                  'notifications@' || notification_setting('from_domain'))
    into v_org from studios s where id = n.studio_id;

  if n.template_key in ('booking_confirmed', 'class_moved', 'class_cancelled',
                        'flex_booking_pending', 'flex_booking_not_confirmed') then
    select email into v_att from members where id = n.member_id;
    v_ve := ics_member_vevent(v_occ, n.member_id,
              (n.template_key in ('class_cancelled', 'flex_booking_not_confirmed')), v_att, v_org);
    v_method := case when n.template_key in ('class_cancelled', 'flex_booking_not_confirmed')
                     then 'CANCEL' else 'REQUEST' end;
  elsif n.template_key in ('instructor_assigned', 'booking_for_instructor') then
    select email into v_att from studio_staff
      where user_id = n.user_id and studio_id = n.studio_id limit 1;
    v_ve := ics_instructor_vevent(v_occ, false, v_att, v_org);
    v_method := 'REQUEST';
  else
    return null;
  end if;

  if v_ve is null then return null; end if;
  return ics_calendar(v_method, v_ve);
end $$;

-- =============================================================================
-- 5. The booking receipt branches to the pending body for a flex-undecided
--    class — same dedupe key, so a member gets ONE, not two.
-- =============================================================================
create or replace function queue_booking_notifications(p_booking_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare
  b bookings%rowtype; o class_occurrences%rowtype; m members%rowtype;
  st studio_settings%rowtype; s studios%rowtype;
  v_when text; v_where text; n int := 0; v_remind timestamptz;
  v_manage text;
  v_is_free boolean; v_ff_txt text; v_ff_html text;
  v_deadline timestamptz;  -- Decision 21 amendment
begin
  select * into b from bookings where id = p_booking_id;
  if not found or b.status <> 'booked' then return 0; end if;

  select * into o  from class_occurrences where id = b.occurrence_id;
  select * into m  from members            where id = b.member_id;
  select * into s  from studios            where id = b.studio_id;
  select * into st from studio_settings    where studio_id = b.studio_id;

  v_when  := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY, HH24:MI');
  v_where := coalesce((select ', in ' || r.name from rooms r where r.id = o.room_id), '');
  v_manage := 'https://' || s.slug || '.'
              || coalesce(notification_setting('member_app_domain'), 'studiior.app')
              || '/class/' || o.id;

  v_is_free := b.payment_source = 'comp'
    and exists (select 1 from guest_passes gp
                 where gp.guest_booking_id = b.id and gp.host_member_id is null);
  v_ff_txt  := case when v_is_free then E'\n\nThis one''s on us — your first class is free.' else '' end;
  v_ff_html := case when v_is_free then '<p>This one''s on us — your first class is free.</p>' else '' end;

  -- Decision 21 amendment: a flex class not yet decided sends the "waiting for
  -- confirmation" receipt instead of booking_confirmed — same dedupe key.
  select deadline_at into v_deadline from flex_deadline_for_run(o.id);
  if v_deadline is not null then
    if queue_notification(b.studio_id, b.member_id, 'flex_booking_pending',
          jsonb_build_object('class_name', o.name, 'when', v_when,
            'deadline_long', to_char(v_deadline at time zone s.timezone,
                                     'HH24:MI "on" FMDay FMDD FMMonth YYYY'),
            'booking_id', b.id, 'occurrence_id', o.id),
          'booking_confirmed:' || b.id) is not null then n := n + 1; end if;
  else
    if queue_notification(b.studio_id, b.member_id, 'booking_confirmed',
          jsonb_build_object('class_name', o.name, 'when', v_when, 'where_line', v_where,
                             'manage_link', v_manage,
                             'free_first_line', v_ff_txt, 'free_first_html', v_ff_html,
                             'booking_id', b.id, 'occurrence_id', o.id),
          'booking_confirmed:' || b.id) is not null then n := n + 1; end if;
  end if;

  v_remind := o.starts_at - make_interval(hours => coalesce(st.reminder_hours_before, 12));
  if v_remind > now() then
    if queue_notification(b.studio_id, b.member_id, 'class_reminder',
          jsonb_build_object('class_name', o.name,
                             'when_short', 'tomorrow',
                             'when_time', to_char(o.starts_at at time zone s.timezone, 'HH24:MI'),
                             'where_line', v_where),
          'class_reminder:' || b.id, v_remind) is not null then n := n + 1; end if;
  end if;

  return n;
end $$;

-- =============================================================================
-- 6. On commit of a FLEX class, tell every booked member it is confirmed.
-- =============================================================================
create or replace function evaluate_commitment(p_occurrence_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o class_occurrences%rowtype; g record; v_booked int; s studios%rowtype; r record;
begin
  select * into o from class_occurrences where id = p_occurrence_id for update;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(o.studio_id), false) and not is_service_context() then
    raise exception 'only owners, managers and the sweep decide a class' using errcode = 'PT403';
  end if;

  if o.committed_at is not null then
    return jsonb_build_object('ok', true, 'already', 'committed',
                              'booked_at_cutoff', o.booked_at_cutoff);
  end if;
  if o.status <> 'scheduled' then
    return jsonb_build_object('ok', true, 'already', o.status::text,
                              'cause', o.cancellation_cause);
  end if;

  select * into g from occurrence_guarantee_run(p_occurrence_id);
  if g.cutoff_at is null then
    return jsonb_build_object('ok', true, 'skipped', 'guarantees are off for this class');
  end if;
  if now() < g.cutoff_at then
    return jsonb_build_object('ok', true, 'skipped', 'not due', 'due_at', g.cutoff_at);
  end if;

  select count(*)::int into v_booked from bookings
   where occurrence_id = p_occurrence_id
     and status in ('booked','attended','no_show','pending_payment');

  if v_booked >= g.minimum
     or (o.flex and o.flex_reached_minimum_at is not null) then
    update class_occurrences
       set committed_at = now(), booked_at_cutoff = v_booked, updated_at = now()
     where id = p_occurrence_id;

    -- Decision 21 amendment: a member who booked a FLEX class was shown "waiting
    -- for confirmation" — tell them it is confirmed. Only flex; a core class was
    -- never pending to a member. Dedupe per member per occurrence.
    if g.tier = 'flex' then
      select * into s from studios where id = o.studio_id;
      for r in select member_id from bookings
                where occurrence_id = p_occurrence_id
                  and status in ('booked','attended','no_show','pending_payment')
      loop
        perform queue_notification(o.studio_id, r.member_id, 'flex_booking_confirmed',
          jsonb_build_object('class_name', o.name,
            'day',  to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth'),
            'time', to_char(o.starts_at at time zone s.timezone, 'HH24:MI'),
            'occurrence_id', p_occurrence_id),
          'flex_member_confirmed:' || p_occurrence_id || ':' || r.member_id);
      end loop;
    end if;

    return jsonb_build_object('ok', true, 'decision', 'committed',
      'tier', g.tier, 'booked_at_cutoff', v_booked, 'minimum', g.minimum,
      'latched', (v_booked < g.minimum));
  end if;

  update class_occurrences set booked_at_cutoff = v_booked where id = p_occurrence_id;
  perform cancel_occurrence(p_occurrence_id,
            'Did not reach its minimum by the cutoff', 'unmet_minimum');

  return jsonb_build_object('ok', true, 'decision', 'not_running',
    'tier', g.tier, 'booked_at_cutoff', v_booked, 'minimum', g.minimum);
end $$;

-- =============================================================================
-- 7. The member cancellation notice branches on the cause: unmet_minimum sends
--    the member-safe flex_booking_not_confirmed (never "not enough people"),
--    with up to three next classes that have space; every other cause is the
--    unchanged class_cancelled. The cause is passed in, since cancel_occurrence
--    calls this before it stamps the row.
-- =============================================================================
drop function if exists queue_occurrence_cancelled(uuid);
create or replace function queue_occurrence_cancelled(
  p_occurrence_id uuid, p_cause cancellation_cause default null)
returns integer language plpgsql security definer set search_path = public as $$
declare o class_occurrences%rowtype; s studios%rowtype; r record; n int := 0;
        v_when text; v_when_short text; v_base text;
        v_list_txt text; v_list_html text; v_line_txt text; v_line_html text;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  select * into s from studios where id = o.studio_id;
  v_when := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY');
  v_when_short := to_char(o.starts_at at time zone s.timezone, 'FMDy FMDD FMMon HH24:MI');
  v_base := 'https://' || s.slug || '.'
            || coalesce(notification_setting('member_app_domain'), 'studiior.app') || '/class/';

  for r in select b.member_id from bookings b
            where b.occurrence_id = p_occurrence_id
              and b.status in ('booked','waitlisted')
  loop
    if p_cause = 'unmet_minimum' then
      -- Up to three upcoming, scheduled, published classes with a free space.
      select string_agg(x.line, '; ' order by x.starts_at),
             string_agg('<a href="' || v_base || x.id || '">' || x.line || '</a>', ', ' order by x.starts_at)
        into v_list_txt, v_list_html
        from (
          select o2.id, o2.starts_at,
                 to_char(o2.starts_at at time zone s.timezone, 'FMDay HH24:MI') || ' ' || o2.name as line
            from class_occurrences o2
           where o2.studio_id = o.studio_id
             and o2.status = 'scheduled'
             and o2.starts_at > now()
             and o2.id <> p_occurrence_id
             and coalesce(o2.booked_count, 0) < o2.capacity
             and occurrence_published(o2.id)
           order by o2.starts_at
           limit 3) x;
      v_line_txt  := case when v_list_txt  is null then '' else ' Here are the next ones with space: ' || v_list_txt || '.' end;
      v_line_html := case when v_list_html is null then '' else '<p>Here are the next ones with space: ' || v_list_html || '.</p>' end;

      if queue_notification(o.studio_id, r.member_id, 'flex_booking_not_confirmed',
            jsonb_build_object('class_name', o.name, 'when', v_when, 'day_short', v_when_short,
              'time', to_char(o.starts_at at time zone s.timezone, 'HH24:MI'),
              'next_three_line', v_line_txt, 'next_three_html', v_line_html,
              'occurrence_id', p_occurrence_id),
            'class_cancelled:' || p_occurrence_id || ':' || r.member_id) is not null
      then n := n + 1; end if;
    else
      if queue_notification(o.studio_id, r.member_id, 'class_cancelled',
            jsonb_build_object('class_name', o.name, 'when', v_when,
                               'occurrence_id', p_occurrence_id),
            'class_cancelled:' || p_occurrence_id || ':' || r.member_id) is not null
      then n := n + 1; end if;
    end if;
  end loop;

  update notifications set status = 'cancelled'
   where status = 'scheduled'
     and dedupe_key like 'class_reminder:%'
     and payload ->> 'class_name' = o.name
     and member_id in (select member_id from bookings where occurrence_id = p_occurrence_id);

  return n;
end $$;
revoke execute on function queue_occurrence_cancelled(uuid, cancellation_cause) from public, anon, authenticated;
grant  execute on function queue_occurrence_cancelled(uuid, cancellation_cause) to service_role;

-- cancel_occurrence, re-issued to pass the cause through (only that one line
-- changes; the §3.2 credit-back path is untouched).
create or replace function cancel_occurrence(p_occurrence_id uuid, p_reason text default null,
  p_cause cancellation_cause default 'studio_fault')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  occ class_occurrences%rowtype;
  r record;
  n_notified int := 0; n_cancelled int := 0; n_credited int := 0;
  v_res record;
begin
  select * into occ from class_occurrences where id = p_occurrence_id for update;
  if not found then
    raise exception 'no such class' using errcode = 'PT404';
  end if;
  if not coalesce(is_manager_up(occ.studio_id), false) and not is_service_context() then
    raise exception 'only owners and managers cancel a class' using errcode = 'PT403';
  end if;
  if occ.status = 'cancelled' then
    return jsonb_build_object('ok', true, 'already_cancelled', true,
                              'notified', 0, 'bookings_cancelled', 0);
  end if;

  perform set_config('studiior.releasing', '1', true);

  n_notified := coalesce(queue_occurrence_cancelled(p_occurrence_id, p_cause), 0);

  update class_occurrences
     set status = 'cancelled', updated_at = now(),
         cancelled_at = coalesce(cancelled_at, now()),
         cancellation_reason = coalesce(p_reason, cancellation_reason),
         cancellation_cause = p_cause
   where id = p_occurrence_id;

  update bookings set free_cancel_until = now() + interval '1 hour'
   where occurrence_id = p_occurrence_id
     and status in ('booked', 'waitlisted', 'pending_payment');

  for r in
    select id from bookings
     where occurrence_id = p_occurrence_id
       and status in ('booked', 'waitlisted', 'pending_payment')
     order by (status = 'waitlisted') desc, booked_at
  loop
    select * into v_res from cancel_booking(r.id);
    n_cancelled := n_cancelled + 1;
    if coalesce(v_res.credit_returned, false) then n_credited := n_credited + 1; end if;
  end loop;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (occ.studio_id, auth.uid(), 'occurrence.cancelled', 'class_occurrences',
          p_occurrence_id, jsonb_build_object('reason', p_reason, 'cause', p_cause,
                                              'notified', n_notified,
                                              'bookings_cancelled', n_cancelled));

  perform set_config('studiior.releasing', '', true);

  return jsonb_build_object('ok', true, 'cause', p_cause, 'notified', n_notified,
                            'bookings_cancelled', n_cancelled,
                            'credits_returned', n_credited);
end $$;

-- =============================================================================
-- anon surface stays EXACTLY TWELVE.
-- =============================================================================
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
