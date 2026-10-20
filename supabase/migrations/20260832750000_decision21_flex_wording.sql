-- =============================================================================
-- Decision 21 amendment, 20 Oct 2026 — plain words for flex confirmation.
-- =============================================================================
-- WORDING ONLY. Members read "Waiting for confirmation" as "the studio hasn't
-- approved me yet" and message the owner. Every member-facing flex state now
-- says what happens and when, in plain words, and never mentions the minimum
-- where a member is choosing a class.
--
-- The three member templates are re-issued (subject/body) to the plain wording.
-- The three senders are re-issued ONLY to add the placeholders the new wording
-- reads — each rebuilt verbatim from its newest definition with the flex payload
-- jsonb the one thing changed, so the confirmation MECHANICS are byte-for-byte
-- unchanged (dedupe keys, gating, the .ics, who is told and when):
--   * queue_booking_notifications: + deadline_short on flex_booking_pending
--     (the short "Sun 8:00 PM" the new subject/body read, via fmt_clock).
--   * evaluate_commitment:         + when + studio_name on flex_booking_confirmed.
--   * queue_occurrence_cancelled:  + day on flex_booking_not_confirmed.
-- A per-studio template override (78c) still wins in render_notification —
-- untouched. Instructor-facing templates unchanged. No setting. No new anon RPC.
-- =============================================================================
-- re-issues: queue_booking_notifications(uuid), evaluate_commitment(uuid), queue_occurrence_cancelled(uuid, cancellation_cause)

-- =============================================================================
-- 1. The three member templates — plain wording.
-- =============================================================================
insert into notification_templates (key, subject, text_body, html_body, note) values
('flex_booking_pending',
 'You''re booked for {class_name} — we''ll confirm by {deadline_short}',
 E'You''re booked for {class_name}, {when}. We''ll email you by {deadline_short} to confirm this class is going ahead. Nothing else to do.',
 '<p>You''re booked for <strong>{class_name}</strong>, {when}.</p><p>We''ll email you by {deadline_short} to confirm this class is going ahead. Nothing else to do.</p>',
 'Decision 21 amendment (20 Oct 2026). Plain words — confirmation, not approval. Replaces booking_confirmed for a flex class not yet decided; same dedupe key, same .ics.'),
('flex_booking_confirmed',
 'Confirmed — {class_name}, {when}',
 E'Your class is going ahead. See you {when} at {studio_name}.',
 '<p>Your class is going ahead. See you {when} at <strong>{studio_name}</strong>.</p>',
 'Decision 21 amendment (20 Oct 2026). Sent when the flex sweep commits the class.'),
('flex_booking_not_confirmed',
 '{class_name} on {day} isn''t running — your credit is back',
 E'Your booking for {class_name} on {when} wasn''t confirmed this time. Your credit is back on your account and ready to use, so you can book another class straight away.{next_three_line}',
 '<p>Your booking for <strong>{class_name}</strong> on {when} wasn''t confirmed this time.</p><p>Your credit is back on your account and ready to use, so you can book another class straight away.</p>{next_three_html}',
 'Decision 21 amendment (20 Oct 2026). Replaces class_cancelled for cancellation_cause = unmet_minimum only; same CANCEL .ics.')
on conflict (key) do update
  set subject = excluded.subject, text_body = excluded.text_body,
      html_body = excluded.html_body, note = excluded.note;

-- =============================================================================
-- 2. queue_booking_notifications — rebuilt from 20260832130000 (Decision 55),
--    the ONLY change a + deadline_short key on the flex_booking_pending payload.
-- =============================================================================
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
  v_deadline timestamptz;  -- Decision 21 amendment
  v_cutoff timestamptz;    -- Decision 30 amendment
  v_fmt text;              -- Decision 55
begin
  select * into b from bookings where id = p_booking_id;
  if not found or b.status <> 'booked' then return 0; end if;

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

  v_is_free := b.payment_source = 'comp'
    and exists (select 1 from guest_passes gp
                 where gp.guest_booking_id = b.id and gp.host_member_id is null);
  v_ff_txt  := case when v_is_free then E'\n\nThis one''s on us — your first class is free.' else '' end;
  v_ff_html := case when v_is_free then '<p>This one''s on us — your first class is free.</p>' else '' end;

  -- Decision 21 amendment: a flex class not yet decided sends the "waiting for
  -- confirmation" receipt instead of booking_confirmed — same dedupe key.
  select deadline_at into v_deadline from flex_deadline_for_run(o.id);

  -- Decision 30 amendment: a PROVISIONAL free seat sends the free "waiting for
  -- confirmation" receipt — checked first, because a free seat on a flex class
  -- is still a free seat. Same dedupe key, so tg_cancel_booking_notifications
  -- withdraws it if the seat is later released. Keyed on the booking's OWN
  -- provisional flag (not the guest_passes row): this trigger fires on INSERT,
  -- before book_first_free writes the guest_pass, so v_is_free is not yet true —
  -- but provisional is set at insert, and only a free-first seat is ever
  -- provisional (guest and paid seats never are).
  if b.payment_source = 'comp' and b.provisional then
    select cutoff_at into v_cutoff from occurrence_guarantee_run(o.id);
    if queue_notification(b.studio_id, b.member_id, 'free_booking_pending',
          jsonb_build_object('class_name', o.name, 'when', v_when,
            'cutoff_long', fmt_clock(v_cutoff, s.timezone, v_fmt) || ' on ' || to_char(v_cutoff at time zone s.timezone, 'FMDay FMDD FMMonth YYYY'),
            'booking_id', b.id, 'occurrence_id', o.id),
          'booking_confirmed:' || b.id) is not null then n := n + 1; end if;
  elsif v_deadline is not null then
    if queue_notification(b.studio_id, b.member_id, 'flex_booking_pending',
          jsonb_build_object('class_name', o.name, 'when', v_when,
            -- Decision 21 amendment (20 Oct 2026): the short "Sun 8:00 PM" the
            -- plain-words subject/body read. {Day} {time} via fmt_clock.
            'deadline_short', to_char(v_deadline at time zone s.timezone, 'FMDy ')
                              || fmt_clock(v_deadline, s.timezone, v_fmt),
            'deadline_long', fmt_clock(v_deadline, s.timezone, v_fmt) || ' on ' || to_char(v_deadline at time zone s.timezone, 'FMDay FMDD FMMonth YYYY'),
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
                             'when_time', fmt_clock(o.starts_at, s.timezone, v_fmt),
                             'where_line', v_where),
          'class_reminder:' || b.id, v_remind) is not null then n := n + 1; end if;
  end if;

  return n;
end $function$;

-- =============================================================================
-- 3. evaluate_commitment — rebuilt from 20260832130000 (Decision 55), the ONLY
--    change + when + studio_name on the flex_booking_confirmed payload.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.evaluate_commitment(p_occurrence_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  -- Decision 30 amendment: we are AT the class's cutoff. A free seat that never
  -- reached its confirm-at total is released NOW, before the headcount is
  -- counted — the member keeps their free class and is told, and the class is
  -- evaluated on who actually remains (so a core 1-paid + 1-released-trial runs,
  -- and a flex min-2 with 1 paid + 1 released trial does not).
  perform release_provisional_seats_run(p_occurrence_id);

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
            'time', fmt_clock(o.starts_at, s.timezone,
                     coalesce((select time_format from studio_settings where studio_id = o.studio_id), '24h')),
            -- Decision 21 amendment (20 Oct 2026): plain words read {when} and
            -- {studio_name} — "See you {when} at {studio}".
            'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth') || ' at '
                    || fmt_clock(o.starts_at, s.timezone,
                         coalesce((select time_format from studio_settings where studio_id = o.studio_id), '24h')),
            'studio_name', s.name,
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
end $function$;

-- =============================================================================
-- 4. queue_occurrence_cancelled — rebuilt from 20260832500000 (Decision 77),
--    the ONLY change + day on the flex_booking_not_confirmed payload.
-- =============================================================================
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
  end if;

  update notifications set status = 'cancelled'
   where status = 'scheduled'
     and dedupe_key like 'class_reminder:%'
     and payload ->> 'class_name' = o.name
     and member_id in (select member_id from bookings where occurrence_id = p_occurrence_id);

  return n;
end $function$;
