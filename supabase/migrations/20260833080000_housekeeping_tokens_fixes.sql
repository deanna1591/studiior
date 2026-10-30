-- Housekeeping — tokens, test sends, small fixes.
-- re-issues: template_sample_context(uuid,text,text), queue_booking_notifications(uuid),
--   confirm_provisional_seats_run(uuid), release_provisional_seats_run(uuid),
--   queue_occurrence_cancelled(uuid,cancellation_cause), evaluate_commitment(uuid),
--   queue_class_moved(uuid,timestamptz), queue_waitlist_offer(uuid), queue_waitlist_missed(uuid),
--   tg_notify_committed_cancel(), cancel_occurrences_for_period_run(uuid,text,cancellation_cause,text),
--   close_studio(uuid,date,date,text,time,time,boolean,boolean,boolean,text,text,text,text,date),
--   tg_challenge_progress()
--
-- 1. template_sample_context gains every instructor-side token with a sample
--    value (so send_template_test and preview_template work on instructor
--    templates) and the sample {day} becomes the full "Monday 9 November" form.
-- 2. Booking emails carry {manage_link} (the member's booking) and {book_url}
--    (the Book tab) in every payload: booking_confirmed, free_booking_pending/
--    confirmed/not_confirmed, flex_booking_pending/confirmed/not_confirmed,
--    class_reminder, class_cancelled, class_moved.
-- 3. waitlist_offer/waitlist_missed carry {first_name} and {claim_url}.
-- 4. booking_cancelled_committed carries {cancelled_count}, {booked}, {capacity}.
-- 5. instructor_class_cancelled carries {reason}; the flex cut-off cancellation
--    now notifies the assigned instructor with the third reason.
-- 6. milestone {milestone_name} becomes words; 10 and 50 attended-class milestones.
-- 7. convert_missed_you default template loses its em dashes.
-- Each sender is the newest definition (pg_get_functiondef) with only the keys
-- added; ACLs re-asserted. No new anon surface — THIRTEEN stays.


CREATE OR REPLACE FUNCTION public.template_sample_context(p_studio_id uuid, p_to_email text, p_first_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s studios%rowtype; st studio_settings%rowtype; v_tz text; v_fmt text;
  v_plan membership_plans%rowtype; o record; v_when text; v_offer_ends text;
begin
  select * into s from studios where id = p_studio_id;
  select * into st from studio_settings where studio_id = p_studio_id;
  v_tz := s.timezone; v_fmt := coalesce(st.time_format, '24h');

  -- The next scheduled class (for the class card). Null-safe when none.
  select o2.id, coalesce(ct.name, o2.name, 'a class') as cname, o2.starts_at,
         rm.name as room, split_part(coalesce(i.display_name, ''), ' ', 1) as instr
    into o
    from class_occurrences o2
    left join class_types ct on ct.id = o2.class_type_id
    left join rooms rm on rm.id = o2.room_id
    left join instructors i on i.id = o2.instructor_id
   where o2.studio_id = p_studio_id and o2.status = 'scheduled' and o2.starts_at > now()
   order by o2.starts_at limit 1;

  -- The offer plan: the intro offer when set, else the first active plan.
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

  -- A COMPLETE context — every token any member-facing template uses.
  return jsonb_build_object(
    'to_email', p_to_email,
    'first_name', p_first_name,
    'studio_name', s.name,
    -- class
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
    -- plan / offer
    'offer_plan_name', coalesce(v_plan.name, 'a membership'),
    'offer_detail', coalesce(plan_card_detail(v_plan.id), ''),
    'offer_price', case when v_plan.id is not null then fmt_money(v_plan.price_cents, v_plan.currency) else '' end,
    'offer_ends', v_offer_ends,
    'buy_url', case when v_plan.id is not null then member_portal_url(p_studio_id, '/buy/' || v_plan.id::text) else member_portal_url(p_studio_id, '/account/plan') end,
    'plan_name', coalesce(v_plan.name, 'your plan'),
    'credits', '3', 'credits_left', '3',
    'expires_on', v_offer_ends, 'ends_on', v_offer_ends,
    'renew_url', case when v_plan.id is not null then member_portal_url(p_studio_id, '/buy/' || v_plan.id::text) else member_portal_url(p_studio_id, '/account/plan') end,
    -- retention / misc
    'last_class', coalesce(o.cname, 'your class'),
    'last_class_date', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDD Mon') else '' end,
    'instructor_first', coalesce(nullif(o.instr, ''), 'your instructor'),
    'instructor_first_name', coalesce(nullif(o.instr, ''), 'your instructor'),
    'days_since', '10',
    'product', 'Grip socks', 'quantity', '1')
  -- Housekeeping (task 1): every instructor-side token with a sample value, so
  -- send_template_test and preview_template work on instructor templates too.
  -- A second jsonb_build_object (|| merged) keeps each call under the 100-argument
  -- limit now that the context carries both member and instructor tokens.
  || jsonb_build_object(
    'instructor_name', p_first_name,
    'href', instructor_portal_url(p_studio_id, '/instructor/schedule'),
    'schedule_link', instructor_portal_url(p_studio_id, '/instructor/schedule'),
    'booked_line', '3 booked',
    'class_list', coalesce(
        case when o.starts_at is not null
             then to_char(o.starts_at at time zone v_tz, 'FMDy FMDD FMMon ') || fmt_clock(o.starts_at, v_tz, v_fmt) || ' ' || o.cname
             else null end, 'your classes this week'),
    'roster', 'your roster',
    'roster_html', 'your roster',
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
    'claim_url', member_portal_url(p_studio_id, '/class/' || coalesce(o.id::text, '')));
end $function$;

revoke execute on function template_sample_context(uuid, text, text) from public, anon, authenticated;
grant  execute on function template_sample_context(uuid, text, text) to service_role;

CREATE OR REPLACE FUNCTION public.queue_booking_notifications(p_booking_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  b bookings%rowtype; o class_occurrences%rowtype; m members%rowtype;
  st studio_settings%rowtype; s studios%rowtype;
  v_when text; v_where text; n int := 0; v_remind timestamptz;
  v_manage text;
  v_is_free boolean; v_ff_txt text; v_ff_html text;
  v_deadline timestamptz;
  v_cutoff timestamptz;
  v_fmt text;
  v_cancel_deadline text;
begin
  select * into b from bookings where id = p_booking_id;
  if not found or b.status <> 'booked' then return 0; end if;

  -- Decision 81a: a walk-in added by an instructor gets ONE combined
  -- walk_in_welcome (new member) or the normal booking email (existing member),
  -- queued by add_walk_in itself; this per-insert email is suppressed for it.
  if current_setting('studiior.suppress_booking_email', true) = '1' then return 0; end if;

  select * into o  from class_occurrences where id = b.occurrence_id;
  select * into m  from members            where id = b.member_id;
  select * into s  from studios            where id = b.studio_id;
  select * into st from studio_settings    where studio_id = b.studio_id;
  v_fmt := coalesce(st.time_format, '24h');

  v_when  := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY, ')
             || fmt_clock(o.starts_at, s.timezone, v_fmt);
  v_where := coalesce((select ', in ' || r.name from rooms r where r.id = o.room_id), '');
  v_manage := 'https://' || s.slug || '.'
              || coalesce(notification_setting('member_app_domain'), 'studiior.app')
              || '/class/' || o.id;

  v_is_free := current_setting('studiior.free_first', true) = '1'
    or (b.payment_source = 'comp'
        and exists (select 1 from guest_passes gp
                     where gp.guest_booking_id = b.id and gp.host_member_id is null));
  v_ff_txt  := case when v_is_free then E'\n\nThis one''s on us — your first class is free.' else '' end;
  v_ff_html := case when v_is_free then '<p>This one''s on us — your first class is free.</p>' else '' end;

  select deadline_at into v_deadline from flex_deadline_for_run(o.id);

  if b.payment_source = 'comp' and b.provisional then
    select cutoff_at into v_cutoff from occurrence_guarantee_run(o.id);
    if queue_notification(b.studio_id, b.member_id, 'free_booking_pending',
          jsonb_build_object('class_name', o.name, 'when', v_when,
            'cutoff_long', fmt_clock(v_cutoff, s.timezone, v_fmt) || ' on ' || to_char(v_cutoff at time zone s.timezone, 'FMDay FMDD FMMonth YYYY'),
            'manage_link', v_manage, 'book_url', member_portal_url(b.studio_id, '/book'),
            'booking_id', b.id, 'occurrence_id', o.id),
          'booking_confirmed:' || b.id) is not null then n := n + 1; end if;
  elsif v_is_free then
    v_cancel_deadline :=
      fmt_clock(o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)), s.timezone, v_fmt)
      || ' on ' || to_char(
        (o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)))
          at time zone s.timezone, 'FMDay FMDD FMMonth YYYY');
    if queue_notification(b.studio_id, b.member_id, 'free_booking_confirmed',
          jsonb_build_object('class_name', o.name,
            'day',  to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth'),
            'time', fmt_clock(o.starts_at, s.timezone, v_fmt),
            'cancel_deadline', v_cancel_deadline,
            'manage_link', v_manage,
            'book_url', member_portal_url(b.studio_id, '/book'),
            'occurrence_id', o.id),
          'booking_confirmed:' || b.id) is not null then n := n + 1; end if;
  elsif v_deadline is not null then
    if queue_notification(b.studio_id, b.member_id, 'flex_booking_pending',
          jsonb_build_object('class_name', o.name, 'when', v_when,
            'deadline_short', to_char(v_deadline at time zone s.timezone, 'FMDy ')
                              || fmt_clock(v_deadline, s.timezone, v_fmt),
            'deadline_long', fmt_clock(v_deadline, s.timezone, v_fmt) || ' on ' || to_char(v_deadline at time zone s.timezone, 'FMDay FMDD FMMonth YYYY'),
            'manage_link', v_manage, 'book_url', member_portal_url(b.studio_id, '/book'),
            'booking_id', b.id, 'occurrence_id', o.id),
          'booking_confirmed:' || b.id) is not null then n := n + 1; end if;
  else
    if queue_notification(b.studio_id, b.member_id, 'booking_confirmed',
          jsonb_build_object('class_name', o.name, 'when', v_when, 'where_line', v_where,
                             'manage_link', v_manage,
                             'book_url', member_portal_url(b.studio_id, '/book'),
                             'free_first_line', v_ff_txt, 'free_first_html', v_ff_html,
                             'booking_id', b.id, 'occurrence_id', o.id),
          'booking_confirmed:' || b.id) is not null then n := n + 1; end if;
  end if;

  v_remind := o.starts_at - make_interval(hours => coalesce(st.reminder_hours_before, 12));
  if v_remind > now() then
    if queue_notification(b.studio_id, b.member_id, 'class_reminder',
          jsonb_build_object('class_name', o.name,
                             'when_short', 'tomorrow',
                             'when_time', fmt_clock(o.starts_at, s.timezone, v_fmt),
                             'manage_link', v_manage, 'book_url', member_portal_url(b.studio_id, '/book'),
                             'where_line', v_where),
          'class_reminder:' || b.id, v_remind) is not null then n := n + 1; end if;
  end if;

  return n;
end $function$;

revoke execute on function queue_booking_notifications(uuid) from public, anon, authenticated;
grant  execute on function queue_booking_notifications(uuid) to service_role;

CREATE OR REPLACE FUNCTION public.confirm_provisional_seats_run(p_occurrence_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o class_occurrences%rowtype; s studios%rowtype; st studio_settings%rowtype;
        v_head int; n int := 0; r record;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then return 0; end if;
  select * into st from studio_settings where studio_id = o.studio_id;
  if st.free_first_confirm_at is null then return 0; end if;

  -- People in the room, paid or free — the same count evaluate_commitment uses.
  select count(*)::int into v_head from bookings
   where occurrence_id = p_occurrence_id
     and status in ('booked','attended','no_show','pending_payment');
  if v_head < st.free_first_confirm_at then return 0; end if;

  select * into s from studios where id = o.studio_id;
  for r in select id, member_id from bookings
            where occurrence_id = p_occurrence_id and status = 'booked' and provisional
  loop
    update bookings set provisional = false, confirmed_at = now() where id = r.id;
    perform queue_notification(o.studio_id, r.member_id, 'free_booking_confirmed',
      jsonb_build_object('class_name', o.name,
        'day',  to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth'),
        'time', fmt_clock(o.starts_at, s.timezone, coalesce(st.time_format, '24h')),
        'cancel_deadline',
          fmt_clock(o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)),
                    s.timezone, coalesce(st.time_format, '24h'))
          || ' on ' || to_char(
            (o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)))
              at time zone s.timezone, 'FMDay FMDD FMMonth YYYY'),
        'manage_link', 'https://' || s.slug || '.'
          || coalesce(notification_setting('member_app_domain'), 'studiior.app') || '/class/' || o.id,
        'book_url', member_portal_url(o.studio_id, '/book'),
        'occurrence_id', p_occurrence_id),
      'free_confirmed:' || r.id);
    n := n + 1;
  end loop;
  return n;
end $function$;

revoke execute on function confirm_provisional_seats_run(uuid) from public, anon, authenticated;
grant  execute on function confirm_provisional_seats_run(uuid) to service_role;

CREATE OR REPLACE FUNCTION public.release_provisional_seats_run(p_occurrence_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o class_occurrences%rowtype; s studios%rowtype; r record; n int := 0;
        v_when text; v_when_short text; v_list text; v_fmt text;
        v_notice boolean := coalesce(current_setting('studiior.closure_notice', true), '') = '1';
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then return 0; end if;
  select * into s from studios where id = o.studio_id;
  select coalesce(time_format, '24h') into v_fmt from studio_settings where studio_id = o.studio_id;
  v_fmt := coalesce(v_fmt, '24h');
  v_when       := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY');
  v_when_short := to_char(o.starts_at at time zone s.timezone, 'FMDy FMDD FMMon ')
                 || fmt_clock(o.starts_at, s.timezone, v_fmt);

  for r in select b.id, b.member_id from bookings b
            where b.occurrence_id = p_occurrence_id and b.status = 'booked' and b.provisional
  loop
    -- Release, directly: the explicit release_reason means the BEFORE stamp
    -- trigger leaves it, is_late_cancel false means no infraction, and a comp
    -- seat has no credit to return.
    update bookings
       set status = 'cancelled', release_reason = 'trial_not_confirmed',
           cancelled_at = now(), cancelled_by = null, is_late_cancel = false
     where id = r.id;
    update class_occurrences set booked_count = greatest(0, booked_count - 1)
     where id = p_occurrence_id;
    -- The once-ever row goes, so the person is eligible again and keeps their
    -- free class. Removed, not left 'cancelled' — free_first_eligibility's
    -- already_had_free check does not look at status.
    delete from guest_passes where guest_booking_id = r.id;

    -- Decision 77: under the closure-notice flag the member gets ONE
    -- studio_closure_notice instead of this per-class email — skip it here.
    if not v_notice then
    -- Now eligible again, so the "next ones" are computed with this person's own
    -- gates: fullest first, with someone already in; fall back to any eligible.
    select string_agg(z.line, '; ' order by z.ord)
      into v_list
      from (
        select to_char(c.starts_at at time zone s.timezone, 'FMDay ') || fmt_clock(c.starts_at, s.timezone, v_fmt) || ' ' || c.name as line,
               row_number() over (order by c.headcount desc, c.starts_at) as ord
          from free_first_eligible_classes_run(o.studio_id, r.member_id, 1) c
         where c.occurrence_id <> p_occurrence_id and c.free_bookable
         limit 3) z;
    if v_list is null then
      select string_agg(z.line, '; ' order by z.ord)
        into v_list
        from (
          select to_char(c.starts_at at time zone s.timezone, 'FMDay ') || fmt_clock(c.starts_at, s.timezone, v_fmt) || ' ' || c.name as line,
                 row_number() over (order by c.headcount desc, c.starts_at) as ord
            from free_first_eligible_classes_run(o.studio_id, r.member_id, 0) c
           where c.occurrence_id <> p_occurrence_id and c.free_bookable
           limit 3) z;
    end if;

    perform queue_notification(o.studio_id, r.member_id, 'free_booking_not_confirmed',
      jsonb_build_object('class_name', o.name, 'when', v_when, 'day_short', v_when_short,
        'time', fmt_clock(o.starts_at, s.timezone, v_fmt),
        'next_three', coalesce(v_list, 'see the full schedule'),
        'manage_link', member_portal_url(o.studio_id, '/class/' || p_occurrence_id),
        'book_url', member_portal_url(o.studio_id, '/book'),
        'occurrence_id', p_occurrence_id),
      'free_not_confirmed:' || r.id);
    n := n + 1;
    end if;
  end loop;
  return n;
end $function$;

revoke execute on function release_provisional_seats_run(uuid) from public, anon, authenticated;
grant  execute on function release_provisional_seats_run(uuid) to service_role;

CREATE OR REPLACE FUNCTION public.queue_occurrence_cancelled(p_occurrence_id uuid, p_cause cancellation_cause DEFAULT NULL::cancellation_cause)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o class_occurrences%rowtype; s studios%rowtype; r record; n int := 0;
        v_when text; v_when_short text; v_base text; v_fmt text;
        v_list_txt text; v_list_html text; v_line_txt text; v_line_html text;
        v_notice boolean := coalesce(current_setting('studiior.closure_notice', true), '') = '1';
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  select * into s from studios where id = o.studio_id;
  select coalesce(time_format, '24h') into v_fmt from studio_settings where studio_id = o.studio_id;
  v_fmt := coalesce(v_fmt, '24h');
  v_when := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY');
  v_when_short := to_char(o.starts_at at time zone s.timezone, 'FMDy FMDD FMMon ')
                 || fmt_clock(o.starts_at, s.timezone, v_fmt);
  v_base := 'https://' || s.slug || '.'
            || coalesce(notification_setting('member_app_domain'), 'studiior.app') || '/class/';

  -- Decision 77: under the closure-notice flag, the member gets ONE
  -- studio_closure_notice instead of a per-class class_cancelled — skip these.
  if not v_notice then
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
                 to_char(o2.starts_at at time zone s.timezone, 'FMDay ') || fmt_clock(o2.starts_at, s.timezone, v_fmt) || ' ' || o2.name as line
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
              'time', fmt_clock(o.starts_at, s.timezone, v_fmt),
              -- Decision 21 amendment (20 Oct 2026): the plain subject reads {day}.
              'day', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth'),
              'next_three_line', v_line_txt, 'next_three_html', v_line_html,
              'manage_link', member_portal_url(o.studio_id, '/class/' || p_occurrence_id),
              'book_url', member_portal_url(o.studio_id, '/book'),
              'occurrence_id', p_occurrence_id),
            'class_cancelled:' || p_occurrence_id || ':' || r.member_id) is not null
      then n := n + 1; end if;
    else
      if queue_notification(o.studio_id, r.member_id, 'class_cancelled',
            jsonb_build_object('class_name', o.name, 'when', v_when,
                               'manage_link', member_portal_url(o.studio_id, '/class/' || p_occurrence_id),
                               'book_url', member_portal_url(o.studio_id, '/book'),
                               'occurrence_id', p_occurrence_id),
            'class_cancelled:' || p_occurrence_id || ':' || r.member_id) is not null
      then n := n + 1; end if;
    end if;
  end loop;
  end if;

  update notifications set status = 'cancelled'
   where status = 'scheduled'
     and dedupe_key like 'class_reminder:%'
     and payload ->> 'class_name' = o.name
     and member_id in (select member_id from bookings where occurrence_id = p_occurrence_id);

  return n;
end $function$;

revoke execute on function queue_occurrence_cancelled(uuid, cancellation_cause) from public, anon, authenticated;
grant  execute on function queue_occurrence_cancelled(uuid, cancellation_cause) to service_role;

CREATE OR REPLACE FUNCTION public.evaluate_commitment(p_occurrence_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o class_occurrences%rowtype; g record; v_booked int; s studios%rowtype; r record; v_iu uuid;
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

  -- Decision 30 amendment: we are AT the class's cutoff. A free seat that never
  -- reached its confirm-at total is released NOW, before the headcount is
  -- counted — the member keeps their free class and is told, and the class is
  -- evaluated on who actually remains (so a core 1-paid + 1-released-trial runs,
  -- and a flex min-2 with 1 paid + 1 released trial does not).
  perform release_provisional_seats_run(p_occurrence_id);

  select count(*)::int into v_booked from bookings
   where occurrence_id = p_occurrence_id
     and status in ('booked','attended','no_show','pending_payment')
     -- Decision 81b: an UNPAID drop-in (the pay_first predicate) holds its
     -- seat but is not counted here, so it never keeps a class alive and
     -- never adds to the pay headcount until it is paid.
     and not (coalesce(bookings.payment_source = 'drop_in', false)
              and not exists (select 1 from payments pmt
                               where pmt.booking_id = bookings.id
                                 and pmt.status in ('succeeded','partially_refunded')));

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
                  -- Decision 81b: do not tell an unpaid drop-in the flex class
                  -- is confirmed on the strength of their own unpaid seat.
                  and not (coalesce(bookings.payment_source = 'drop_in', false)
                           and not exists (select 1 from payments pmt
                                            where pmt.booking_id = bookings.id
                                              and pmt.status in ('succeeded','partially_refunded')))
      loop
        perform queue_notification(o.studio_id, r.member_id, 'flex_booking_confirmed',
          jsonb_build_object('class_name', o.name,
            'day',  to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth'),
            'time', fmt_clock(o.starts_at, s.timezone,
                     coalesce((select time_format from studio_settings where studio_id = o.studio_id), '24h')),
            -- Decision 21 amendment (20 Oct 2026): plain words read {when} and
            -- {studio_name} — "See you {when} at {studio}".
            'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth') || ' at '
                    || fmt_clock(o.starts_at, s.timezone,
                         coalesce((select time_format from studio_settings where studio_id = o.studio_id), '24h')),
            'studio_name', s.name,
            'manage_link', member_portal_url(o.studio_id, '/class/' || p_occurrence_id),
            'book_url', member_portal_url(o.studio_id, '/book'),
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

  -- Housekeeping (task 5): the assigned instructor is told the cut-off cancelled
  -- their class, with the reason. queue_shift_notice returns null for a no-login
  -- instructor, so it never implies a message that was not sent.
  if o.instructor_id is not null then
    v_iu := instructor_user_id(o.instructor_id);
    if v_iu is not null then
      select * into s from studios where id = o.studio_id;
      perform queue_shift_notice(o.studio_id, v_iu, 'instructor_class_cancelled',
        jsonb_build_object('class_name', o.name,
          'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY'),
          'reason', 'didn''t reach its minimum by the cut-off',
          'occurrence_id', p_occurrence_id),
        'instructor_class_cancelled:' || p_occurrence_id);
    end if;
  end if;

  return jsonb_build_object('ok', true, 'decision', 'not_running',
    'tier', g.tier, 'booked_at_cutoff', v_booked, 'minimum', g.minimum);
end $function$;

revoke execute on function evaluate_commitment(uuid) from public, anon, authenticated;
grant  execute on function evaluate_commitment(uuid) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.queue_class_moved(p_occurrence_id uuid, p_old_starts_at timestamp with time zone)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  occ class_occurrences%rowtype; r record; v_tz text;
  v_when text; v_old text; v_where text; n int := 0;
begin
  select * into occ from class_occurrences where id = p_occurrence_id;
  select s.timezone into v_tz from studios s where s.id = occ.studio_id;

  v_when  := to_char(occ.starts_at   at time zone v_tz, 'FMDay FMDD FMMonth YYYY, HH24:MI');
  v_old   := to_char(p_old_starts_at at time zone v_tz, 'FMDay FMDD FMMonth YYYY, HH24:MI');
  v_where := coalesce((select ', in ' || rm.name from rooms rm where rm.id = occ.room_id), '');

  for r in
    select b.member_id from bookings b
     where b.occurrence_id = occ.id and b.status = 'booked'
  loop
    if queue_notification(occ.studio_id, r.member_id, 'class_moved',
         jsonb_build_object('class_name', occ.name, 'when', v_when,
                            'old_when', v_old, 'where_line', v_where,
                            'manage_link', member_portal_url(occ.studio_id, '/class/' || occ.id),
                            'book_url', member_portal_url(occ.studio_id, '/book'),
                            'occurrence_id', occ.id),
         'class_moved:' || occ.id || ':' || r.member_id || ':'
           || to_char(occ.starts_at, 'YYYYMMDDHH24MI')) is not null then
      n := n + 1;
    end if;
  end loop;
  return n;
end $function$;

revoke execute on function queue_class_moved(uuid, timestamptz) from public, anon, authenticated;
grant  execute on function queue_class_moved(uuid, timestamptz) to service_role;

CREATE OR REPLACE FUNCTION public.queue_waitlist_offer(p_offer_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  ofr waitlist_offers%rowtype; b bookings%rowtype;
  o class_occurrences%rowtype; s studios%rowtype;
begin
  select * into ofr from waitlist_offers where id = p_offer_id;
  if not found then return 0; end if;
  select * into b from bookings          where id = ofr.booking_id;
  select * into o from class_occurrences where id = ofr.occurrence_id;
  select * into s from studios           where id = ofr.studio_id;

  return case when queue_notification(ofr.studio_id, b.member_id, 'waitlist_offer',
      jsonb_build_object('class_name', o.name,
                         'first_name', coalesce((select first_name from members where id = b.member_id), 'there'),
                         'claim_url', member_portal_url(ofr.studio_id, '/class/' || o.id),
                         'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth, ') || fmt_clock_s(o.starts_at, ofr.studio_id),
                         'expires_at', fmt_clock_s(ofr.expires_at, ofr.studio_id)),
      'waitlist_offer:' || p_offer_id) is not null then 1 else 0 end;
end $function$;

revoke execute on function queue_waitlist_offer(uuid) from public, anon, authenticated;
grant  execute on function queue_waitlist_offer(uuid) to service_role;

CREATE OR REPLACE FUNCTION public.queue_waitlist_missed(p_booking_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare b bookings%rowtype; o class_occurrences%rowtype; s studios%rowtype; v_when text;
begin
  select * into b from bookings where id = p_booking_id;
  select * into o from class_occurrences where id = b.occurrence_id;
  select * into s from studios where id = b.studio_id;
  v_when := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth, ') || fmt_clock_s(o.starts_at, b.studio_id);
  return case when queue_notification(b.studio_id, b.member_id, 'waitlist_missed',
      jsonb_build_object('class_name', o.name, 'when', v_when,
                         'first_name', coalesce((select first_name from members where id = b.member_id), 'there'),
                         'claim_url', member_portal_url(b.studio_id, '/class/' || o.id)),
      'waitlist_missed:' || p_booking_id) is not null then 1 else 0 end;
end $function$;

revoke execute on function queue_waitlist_missed(uuid) from public, anon, authenticated;
grant  execute on function queue_waitlist_missed(uuid) to service_role;

CREATE OR REPLACE FUNCTION public.tg_notify_committed_cancel()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o class_occurrences%rowtype; s studios%rowtype; v_user uuid; v_name text;
  v_pay jsonb; v_amount text;
begin
  -- A confirmed member seat cancelling (booked -> cancelled/late). Not the
  -- studio-release path (that cancels the whole class — a different message),
  -- caught both by the releasing flag and by the occurrence no longer being
  -- scheduled below.
  if not (old.status = 'booked' and new.status in ('cancelled','late_cancelled')) then
    return new;
  end if;
  if coalesce(current_setting('studiior.releasing', true), '') = '1' then
    return new;
  end if;

  select * into o from class_occurrences where id = new.occurrence_id;
  -- Only a COMMITTED, still-scheduled class. committed_at is terminal and means
  -- pay is already fixed from the cutoff snapshot, so "unchanged" is true.
  if o.committed_at is null or o.status <> 'scheduled' or o.instructor_id is null then
    return new;
  end if;

  v_user := instructor_user_id(o.instructor_id);
  if v_user is null then return new; end if;

  v_pay := compute_class_pay_run(o.id);
  if not coalesce((v_pay ->> 'ok')::boolean, false) then return new; end if;

  select * into s from studios where id = o.studio_id;
  select display_name into v_name from instructors where id = o.instructor_id;
  v_amount := dashboard_money_text((v_pay ->> 'amount_cents')::bigint, v_pay ->> 'currency');

  perform queue_shift_notice(o.studio_id, v_user, 'booking_cancelled_committed',
    jsonb_build_object(
      'instructor_name', coalesce(v_name, 'there'),
      'studio_name', s.name,
      'class_name', o.name,
      'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMon, HH24:MI'),
      'amount', v_amount,
      'cancelled_count', (select count(*) from bookings bb
                           where bb.occurrence_id = o.id
                             and bb.status in ('cancelled','late_cancelled')
                             and (bb.cancelled_at at time zone s.timezone)::date = (now() at time zone s.timezone)::date),
      'booked', o.booked_count,
      'capacity', o.capacity),
    'booking_cancelled_committed:' || new.id);
  return new;
end $function$;

revoke execute on function tg_notify_committed_cancel() from public, anon, authenticated;
grant  execute on function tg_notify_committed_cancel() to service_role;

CREATE OR REPLACE FUNCTION public.cancel_occurrences_for_period_run(p_occurrence_id uuid, p_scope text DEFAULT 'one'::text, p_cause cancellation_cause DEFAULT 'no_instructor'::cancellation_cause, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o class_occurrences%rowtype; v_tz text; v_series uuid;
  v_month_start date; v_from_date date; v_dow double precision; v_tod int;
  rec record; v_res jsonb; v_cancelled int := 0; v_skipped jsonb := '[]'::jsonb;
  v_members int := 0; v_when text; v_targets uuid[] := '{}'; tid uuid;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if p_scope not in ('one','month') then
    raise exception 'scope must be one or month' using errcode = 'PT422';
  end if;
  -- Staff may only choose these three. unmet_minimum is the flex sweep's own
  -- cause (Decision 21); closure is Decision 44's. Neither is reachable here.
  if p_cause not in ('no_instructor','studio_fault','force_majeure') then
    raise exception 'cause must be no_instructor, studio_fault or force_majeure'
      using errcode = 'PT422';
  end if;
  -- no_instructor is for the class nobody can teach. On a class that HAS one,
  -- the studio means something else (studio_fault / force_majeure).
  if p_cause = 'no_instructor' and o.instructor_id is not null then
    raise exception 'This class has an instructor — choose a different reason.'
      using errcode = 'PT422';
  end if;

  select timezone into v_tz from studios where id = o.studio_id;
  v_series      := o.series_id;
  v_from_date   := (o.starts_at at time zone v_tz)::date;
  v_month_start := date_trunc('month', o.starts_at at time zone v_tz)::date;
  v_dow         := extract(dow from o.starts_at at time zone v_tz);
  v_tod         := (extract(hour from o.starts_at at time zone v_tz) * 60
                    + extract(minute from o.starts_at at time zone v_tz))::int;

  -- Pass 1: resolve the target set (same series, same weekday, same time-of-day,
  -- same month, this one forward), applying the per-occurrence no_instructor skip.
  for rec in
    select t.id, t.starts_at, t.instructor_id
      from class_occurrences t
     where t.status = 'scheduled'
       and (
            (p_scope = 'one' and t.id = o.id)
         or (p_scope = 'month' and v_series is null and t.id = o.id)
         or (p_scope = 'month' and v_series is not null and t.series_id = v_series
              and (t.starts_at at time zone v_tz)::date >= v_from_date
              and date_trunc('month', t.starts_at at time zone v_tz)::date = v_month_start
              and extract(dow from t.starts_at at time zone v_tz) = v_dow
              and (extract(hour from t.starts_at at time zone v_tz) * 60
                   + extract(minute from t.starts_at at time zone v_tz))::int = v_tod)
       )
     order by t.starts_at
  loop
    v_when := to_char(rec.starts_at at time zone v_tz, 'FMDy FMDD FMMon HH24:MI');
    if p_cause = 'no_instructor' and rec.instructor_id is not null then
      v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
        'occurrence_id', rec.id, 'when', v_when, 'reason', 'has an instructor'));
    else
      v_targets := v_targets || rec.id;
    end if;
  end loop;

  -- The members who will be told: distinct across the target set, counted
  -- before cancelling (cancel_booking changes their status).
  select count(distinct b.member_id) into v_members
    from bookings b
   where b.occurrence_id = any(v_targets)
     and b.status in ('booked','waitlisted','pending_payment');

  -- Pass 2: cancel each through the existing §3.2 path, one savepoint apiece so
  -- a single failure never aborts the batch. cancel_occurrence tells the booked
  -- members; the ASSIGNED instructor (Decision 47: "the instructor, if any, is
  -- told") is told here — queue_shift_notice returns null for a no-login
  -- instructor, so it never implies a message that was not sent.
  declare o2 class_occurrences%rowtype; v_iu uuid;
  begin
    foreach tid in array v_targets loop
      select * into o2 from class_occurrences where id = tid;
      v_when := to_char(o2.starts_at at time zone v_tz, 'FMDy FMDD FMMon HH24:MI');
      begin
        v_res := cancel_occurrence(tid, p_reason, p_cause);
        if coalesce((v_res ->> 'ok')::boolean, false)
           and not coalesce((v_res ->> 'already_cancelled')::boolean, false) then
          v_cancelled := v_cancelled + 1;
          if o2.instructor_id is not null then
            v_iu := instructor_user_id(o2.instructor_id);
            if v_iu is not null then
              perform queue_shift_notice(o2.studio_id, v_iu, 'instructor_class_cancelled',
                jsonb_build_object('class_name', o2.name,
                  'when', to_char(o2.starts_at at time zone v_tz, 'FMDay FMDD FMMonth YYYY'),
                  'reason', 'cancelled by the studio',
                  'occurrence_id', tid),
                'instructor_class_cancelled:' || tid);
            end if;
          end if;
        else
          v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
            'occurrence_id', tid, 'when', v_when,
            'reason', coalesce(v_res ->> 'reason', 'already cancelled')));
        end if;
      exception when others then
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
          'occurrence_id', tid, 'when', v_when, 'reason', sqlerrm));
      end;
    end loop;
  end;

  -- One batch-level audit row (cancel_occurrence writes its own per occurrence).
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (o.studio_id, auth.uid(), 'occurrences.cancelled_period', 'class_occurrences',
          p_occurrence_id, jsonb_build_object('scope', p_scope, 'cause', p_cause,
            'reason', p_reason, 'cancelled', v_cancelled,
            'members_affected', v_members, 'skipped', v_skipped));

  return jsonb_build_object('ok', true, 'cancelled', v_cancelled,
    'skipped', v_skipped, 'members_affected', v_members);
end $function$;

revoke execute on function cancel_occurrences_for_period_run(uuid, text, cancellation_cause, text) from public, anon, authenticated;
grant  execute on function cancel_occurrences_for_period_run(uuid, text, cancellation_cause, text) to service_role;

CREATE OR REPLACE FUNCTION public.close_studio(p_studio_id uuid, p_starts_on date, p_ends_on date, p_reason text, p_starts_at_time time without time zone DEFAULT NULL::time without time zone, p_ends_at_time time without time zone DEFAULT NULL::time without time zone, p_confirm boolean DEFAULT false, p_pays_instructors boolean DEFAULT false, p_notice boolean DEFAULT false, p_subject text DEFAULT NULL::text, p_message text DEFAULT NULL::text, p_message_html text DEFAULT NULL::text, p_message_text text DEFAULT NULL::text, p_resumes_on date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_impact jsonb; v_id uuid; r record; v jsonb; s studios%rowtype;
  v_cancelled int := 0; v_notified int := 0; v_notice_sent int := 0;
  v_tz text; v_fmt text; v_occ_ids uuid[]; o2 class_occurrences%rowtype; v_iu uuid;
  rm record; v_book text; v_resume text; v_sys_text text; v_sys_html text;
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers close the studio' using errcode = 'PT403';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'say why — a closure with no reason is one nobody can explain to a member'
      using errcode = 'PT422';
  end if;
  if (p_starts_at_time is null) <> (p_ends_at_time is null) then
    raise exception 'a partial day needs both a start and an end time' using errcode = 'PT422';
  end if;
  -- Decision 77: the all-member notice is for a closure spanning more than a day.
  if p_notice and p_ends_on = p_starts_on then
    raise exception 'A one-day closure tells the members who are booked, as usual — the notice to everyone is for a closure spanning more than a day.'
      using errcode = 'PT422';
  end if;
  if p_notice and (nullif(btrim(coalesce(p_subject, '')), '') is null
                   or nullif(btrim(coalesce(p_message, '')), '') is null) then
    raise exception 'The notice needs a subject and a message.' using errcode = 'PT422';
  end if;

  v_impact := closure_impact(p_studio_id, p_starts_on, p_ends_on, p_starts_at_time, p_ends_at_time);
  if not p_confirm then
    return v_impact || jsonb_build_object('ok', false, 'requires_confirmation', true);
  end if;

  select * into s from studios where id = p_studio_id;
  v_tz  := s.timezone;
  v_fmt := coalesce((select time_format from studio_settings where studio_id = p_studio_id), '24h');

  insert into studio_closures (studio_id, starts_on, ends_on, starts_at_time, ends_at_time,
                               reason, created_by, pays_instructors, subject, message, resumes_on)
  values (p_studio_id, p_starts_on, p_ends_on, p_starts_at_time, p_ends_at_time,
          btrim(p_reason), auth.uid(), coalesce(p_pays_instructors, false),
          case when p_notice then p_subject end, case when p_notice then p_message end,
          case when p_notice then p_resumes_on end)
  returning id into v_id;

  select array_agg((d ->> 'occurrence_id')::uuid)
    into v_occ_ids from jsonb_array_elements(v_impact -> 'detail') d;

  -- Decision 77: with the notice on, the per-class member emails are suppressed
  -- (the flag is read in queue_occurrence_cancelled and release_provisional_
  -- seats_run) — one notice goes out below instead. Credits, waitlist, calendar
  -- cancel, audit and status all happen exactly as today.
  if p_notice then perform set_config('studiior.closure_notice', '1', true); end if;

  for r in select (d ->> 'occurrence_id')::uuid as id
             from jsonb_array_elements(v_impact -> 'detail') d
  loop
    v := cancel_occurrence(r.id, 'Studio closed: ' || btrim(p_reason), 'closure'::cancellation_cause);
    update class_occurrences set cancellation_pays = coalesce(p_pays_instructors, false) where id = r.id;
    v_cancelled := v_cancelled + 1;
    v_notified := v_notified + coalesce((v ->> 'notified')::int, 0);
    -- Decision 77: closures have never emailed instructors; with the notice on,
    -- tell the assigned instructor per class, as the Decision 47 path does.
    if p_notice then
      select * into o2 from class_occurrences where id = r.id;
      if o2.instructor_id is not null then
        v_iu := instructor_user_id(o2.instructor_id);
        if v_iu is not null then
          perform queue_shift_notice(p_studio_id, v_iu, 'instructor_class_cancelled',
            jsonb_build_object('class_name', o2.name,
              'when', to_char(o2.starts_at at time zone v_tz, 'FMDay FMDD FMMonth YYYY'),
              'reason', 'the studio is closed that day',
              'occurrence_id', r.id),
            'instructor_class_cancelled:' || r.id);
        end if;
      end if;
    end if;
  end loop;

  if p_notice then perform set_config('studiior.closure_notice', '', true); end if;

  -- Decision 77: ONE studio_closure_notice per member with an address (booked or
  -- not; deleted members excluded). Transactional — from_domain, consent
  -- ignored (unlisted template → always-send), no unsubscribe footer. Their own
  -- cancelled-class list when they had one, "Classes resume {date}", and a button
  -- to the timetable on that day.
  if p_notice then
    v_book   := member_portal_url(p_studio_id, '/book?d=' || p_resumes_on::text);
    v_resume := 'Classes resume ' || to_char(p_resumes_on, 'FMDay FMDD FMMonth YYYY') || '.';
    for rm in
      select m.id,
        (select string_agg(o.name || ' · '
                  || to_char(o.starts_at at time zone v_tz, 'FMDy FMDD FMMon ')
                  || fmt_clock(o.starts_at, v_tz, v_fmt), E'\n' order by o.starts_at)
           from bookings b join class_occurrences o on o.id = b.occurrence_id
          where b.member_id = m.id and o.id = any(v_occ_ids)
            and b.status in ('cancelled', 'late_cancelled')) as list_txt,
        (select string_agg('<li>' || o.name || ' · '
                  || to_char(o.starts_at at time zone v_tz, 'FMDy FMDD FMMon ')
                  || fmt_clock(o.starts_at, v_tz, v_fmt) || '</li>', '' order by o.starts_at)
           from bookings b join class_occurrences o on o.id = b.occurrence_id
          where b.member_id = m.id and o.id = any(v_occ_ids)
            and b.status in ('cancelled', 'late_cancelled')) as list_html
      from members m
     where m.studio_id = p_studio_id and m.deleted_at is null and nullif(m.email, '') is not null
    loop
      v_sys_text := case when rm.list_txt is not null
        then E'These classes of yours were cancelled:\n' || rm.list_txt
             || E'\n\nYour credit (or free first class) is back.\n\n'
        else '' end || v_resume || E'\n\nBook your week: ' || v_book;
      v_sys_html := case when rm.list_html is not null
        then '<p>These classes of yours were cancelled:</p><ul>' || rm.list_html
             || '</ul><p>Your credit (or free first class) is back.</p>'
        else '' end || '<p>' || v_resume || '</p><p><a href="' || v_book || '">Book your week</a></p>';
      perform queue_notification(p_studio_id, rm.id, 'studio_closure_notice',
        jsonb_build_object('subject', p_subject, 'studio_name', s.name,
          'body', coalesce(p_message_text, p_message), 'body_html', coalesce(p_message_html, ''),
          'system_text', v_sys_text, 'system_html', v_sys_html),
        'studio_closure_notice:' || v_id || ':' || rm.id);
      v_notice_sent := v_notice_sent + 1;
    end loop;
    update studio_closures set notice_sent_at = now() where id = v_id;
  end if;

  return jsonb_build_object(
    'ok', true, 'closure_id', v_id, 'starts_on', p_starts_on, 'ends_on', p_ends_on,
    'classes_cancelled', v_cancelled, 'members_notified', v_notified,
    'notice', coalesce(p_notice, false), 'notice_sent', v_notice_sent,
    'pays_instructors', coalesce(p_pays_instructors, false));
end $function$;

revoke execute on function close_studio(uuid, date, date, text, time without time zone, time without time zone, boolean, boolean, boolean, text, text, text, text, date) from public, anon, authenticated;
grant  execute on function close_studio(uuid, date, date, text, time without time zone, time without time zone, boolean, boolean, boolean, text, text, text, text, date) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.tg_challenge_progress()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r          record;
  v_old_prog int; v_old_comp timestamptz;
  v_new_prog int; v_new_comp timestamptz; v_goal int;
  v_half     int;
  v_done     int;
  v_classes  int;
begin
  if new.status = 'attended' and old.status is distinct from 'attended' then
    -- Housekeeping (task 6, Decision 10): 10 and 50 attended classes are personal
    -- milestones, sent once each (queue_milestone dedupes by member + name).
    select count(*) into v_classes from bookings
     where member_id = new.member_id and studio_id = new.studio_id and status = 'attended';
    if v_classes = 10 then
      perform queue_milestone(new.member_id, '10 classes',
        'Ten classes at {studio_name}. You''re a regular now.');
    elsif v_classes = 50 then
      perform queue_milestone(new.member_id, '50 classes',
        'Fifty classes. That''s dedication.');
    end if;

    -- Every member challenge this member has joined that this class counts for.
    for r in
      select cp.id as participant_id, cp.challenge_id
        from challenge_participants cp
        join challenges c on c.id = cp.challenge_id
       where cp.member_id = new.member_id
         and cp.audience = 'member'
         and c.status in ('scheduled', 'active')
         and challenge_qualifies(cp.challenge_id, new.occurrence_id)
    loop
      insert into challenge_progress_events
        (studio_id, challenge_id, member_id, booking_id, occurrence_id, delta, occurred_at)
      select new.studio_id, r.challenge_id, new.member_id, new.id, new.occurrence_id, 1,
             (select starts_at from class_occurrences where id = new.occurrence_id)
      on conflict do nothing;

      select progress, completed_at into v_old_prog, v_old_comp
        from challenge_participants where id = r.participant_id;
      perform recompute_participant(r.participant_id);
      select progress, completed_at, goal_value into v_new_prog, v_new_comp, v_goal
        from challenge_participants where id = r.participant_id;
      perform rank_challenge(r.challenge_id);

      v_half := ceil(v_goal / 2.0);
      if v_new_comp is not null and v_old_comp is null then
        perform queue_challenge_completed(r.participant_id);
        -- §10: completing your 1st, 3rd or 10th challenge is a member milestone.
        select count(*) into v_done from challenge_participants
         where member_id = new.member_id and completed_at is not null;
        if v_done in (1, 3, 10) then
          perform queue_milestone(new.member_id,
            case v_done when 1 then 'Your first challenge'
                        when 3 then 'Three challenges'
                        else 'Ten challenges' end,
            case v_done when 1 then 'You completed your first challenge.'
                        when 3 then 'Three challenges done.'
                        else 'Ten challenges completed.' end);
        end if;
      elsif v_old_prog < v_half and v_new_prog >= v_half and v_new_comp is null then
        perform queue_challenge_milestone(r.participant_id);
      end if;
    end loop;

  elsif old.status = 'attended' and new.status is distinct from 'attended' then
    -- Undo: drop this booking's events everywhere and recompute what it touched.
    for r in
      select distinct e.challenge_id,
             (select id from challenge_participants
               where challenge_id = e.challenge_id and member_id = new.member_id) as participant_id
        from challenge_progress_events e
       where e.booking_id = new.id and e.member_id = new.member_id
    loop
      delete from challenge_progress_events
       where booking_id = new.id and challenge_id = r.challenge_id and member_id = new.member_id;
      if r.participant_id is not null then
        perform recompute_participant(r.participant_id);
        perform rank_challenge(r.challenge_id);
      end if;
    end loop;
  end if;

  return new;
end $function$;

revoke execute on function tg_challenge_progress() from public, anon, authenticated;
grant  execute on function tg_challenge_progress() to service_role;

-- Task 5: the instructor's cancellation notice reads the reason it was cancelled.
-- The default template only (per-studio overrides in notification_templates_overrides
-- are untouched).
update notification_templates set
  subject = '{class_name} on {when} was cancelled',
  text_body = E'Hi {first_name},\n\n{class_name} on {when} has been cancelled. Reason: {reason}. You are not expected to teach it.\n\nIf you have questions, reply to this email.',
  html_body = '<p>Hi {first_name},</p><p>{class_name} on {when} has been cancelled. Reason: {reason}.</p><p>You are not expected to teach it.</p><p>If you have questions, reply to this email.</p>'
where key = 'instructor_class_cancelled';

-- Task 7: no em dash in the convert_missed_you body (default template only).
update notification_templates set
  text_body = replace(replace(text_body,
                'used ' || chr(8212) || ' but', 'used, but'),
                chr(8212) || ' {studio_name}', '{studio_name}'),
  html_body = replace(replace(replace(html_body,
                'used ' || chr(8212) || ' but', 'used, but'),
                '{offer_plan_name} ' || chr(8212) || ' {offer_price}', '{offer_plan_name} ({offer_price})'),
                chr(8212) || ' {studio_name}', '{studio_name}')
where key = 'convert_missed_you';

do $$
begin
  if exists (select 1 from notification_templates
              where key = 'convert_missed_you'
                and position(chr(8212) in coalesce(text_body,'') || coalesce(html_body,'')) > 0) then
    raise exception 'convert_missed_you still carries an em dash';
  end if;
end $$;

-- The anon surface is unchanged: exactly THIRTEEN.
do $$ declare n int; begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % not 13', n; end if;
end $$;

