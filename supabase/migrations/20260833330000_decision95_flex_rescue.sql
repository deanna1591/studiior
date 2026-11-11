-- =============================================================================
-- Decision 95 — flex rescue: move to a core class before the cut-off (11 Nov 2026)
-- =============================================================================
-- A booking in a flex class still under the studio's flex minimum gets two
-- member emails offering a one-tap move to a core class that is going ahead:
--   flex_rescue_2days  — 2 days before, at the 10:00 studio-local convention
--   flex_rescue_final  — {flex_rescue_hours_before} hours before the flex cut-off
-- Both carry {class_list_core}: the studio's core classes in the next 7 days
-- from the flex class's start, ones with a booking first, as move cards. The
-- move is an in-place occurrence move exactly as rebook_member (Decision 92),
-- through a shared rebook_run twin; move_booking is member-guarded.
--
-- No new anon RPC (the move page is login-gated, move_booking is member-guarded)
-- — anon stays EXACTLY THIRTEEN (asserted at apply).
--
-- creates: core_classes_for_rescue(uuid), flex_rescue_block(uuid), rebook_run(uuid, uuid), move_booking(uuid, uuid), sweep_flex_rescue(timestamptz)
-- re-issues: rebook_member(uuid, uuid), member_activity(uuid, date, date), template_sample_context(uuid, text, text)
-- =============================================================================

-- --- (1) setting ------------------------------------------------------------
alter table studio_settings
  add column if not exists flex_rescue_hours_before int not null default 3;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'studio_settings_flex_rescue_hours_ck') then
    alter table studio_settings
      add constraint studio_settings_flex_rescue_hours_ck
      check (flex_rescue_hours_before between 0 and 72);
  end if;
end $$;

-- --- (2) templates (platform defaults, 80a frame) ---------------------------
insert into notification_templates (key, subject, text_body, html_body, note) values (
 'flex_rescue_2days',
 'Your {class_name} on {day} still needs {n_more} more to run',
 E'Hi {first_name},\n\nYour {class_name} on {day} is a flex class, and it still needs {n_more} more booked to go ahead. Want a class that is already running? Move your spot in one tap:\n\n{class_list_core_text}\n\nYour credit or free class moves with you, nothing else to do.\n\nSee you in class,\n{studio_name}',
 '<p>Hi {first_name},</p>'
 '<p>Your <strong>{class_name}</strong> on {day} is a flex class, and it still needs <strong>{n_more}</strong> more booked to go ahead. Want a class that is already running? Move your spot in one tap:</p>'
 '{class_list_core}'
 '<p>Your credit or free class moves with you, nothing else to do.</p>'
 '<p>See you in class,<br>{studio_name}</p>',
 'Decision 95. Sent 2 days before a flex class that is still under its minimum. '
 'Tokens: first_name, class_name, day, n_more, class_list_core, class_list_core_text, studio_name.')
on conflict (key) do nothing;

insert into notification_templates (key, subject, text_body, html_body, note) values (
 'flex_rescue_final',
 'Last call: move your {class_name} booking before {cutoff_time}',
 E'Hi {first_name},\n\nLast call. Your {class_name} on {day} still needs {n_more} more to run, and the studio decides by {cutoff_time}. Move to a class that is already going ahead in one tap:\n\n{class_list_core_text}\n\nYour credit or free class moves with you, nothing else to do.\n\nSee you in class,\n{studio_name}',
 '<p>Hi {first_name},</p>'
 '<p>Last call. Your <strong>{class_name}</strong> on {day} still needs <strong>{n_more}</strong> more to run, and the studio decides by {cutoff_time}. Move to a class that is already going ahead in one tap:</p>'
 '{class_list_core}'
 '<p>Your credit or free class moves with you, nothing else to do.</p>'
 '<p>See you in class,<br>{studio_name}</p>',
 'Decision 95. Sent {flex_rescue_hours_before} hours before the flex cut-off for a '
 'class still under its minimum. Tokens: first_name, class_name, day, n_more, '
 'cutoff_time, class_list_core, class_list_core_text, studio_name.')
on conflict (key) do nothing;

-- --- (3) core_classes_for_rescue(occurrence) --------------------------------
-- The studio's core classes in the next 7 days from the flex class's start,
-- bookable and visible to members, ones with a booking first then the rest,
-- excluding the source class. Rows for the move page, the email cards and the
-- node-tested ordering. Service/internal (the member path reaches it through
-- move_booking / the move page's own query).
create function core_classes_for_rescue(p_occurrence_id uuid)
returns table(occurrence_id uuid, name text, starts_at timestamptz, day_label text,
              time_label text, coach_first text, n_booked int, spots_left int)
language plpgsql stable security definer set search_path = public as $function$
declare v_src class_occurrences%rowtype; s studios%rowtype; v_fmt text;
begin
  select * into v_src from class_occurrences where id = p_occurrence_id;
  if not found then return; end if;
  select * into s from studios where id = v_src.studio_id;
  v_fmt := coalesce((select time_format from studio_settings where studio_id = v_src.studio_id), '24h');

  return query
  select o.id,
         coalesce(nullif(o.name, ''), ct.name) as name,
         o.starts_at,
         to_char(o.starts_at at time zone s.timezone, 'FMDy FMDD FMMon') as day_label,
         fmt_clock(o.starts_at, s.timezone, v_fmt) as time_label,
         split_part(coalesce(i.display_name, ''), ' ', 1) as coach_first,
         o.booked_count as n_booked,
         (o.capacity - occurrence_seats_taken(o.id) - occurrence_seats_held(o.id)) as spots_left
    from class_occurrences o
    join class_types ct on ct.id = o.class_type_id
    left join class_series cs on cs.id = o.series_id
    left join instructors i on i.id = o.instructor_id
   where o.studio_id = v_src.studio_id
     and o.id <> p_occurrence_id
     and o.status = 'scheduled'
     and not o.hidden_from_members
     and occurrence_published(o.id)
     and o.starts_at > now()
     and o.starts_at >= v_src.starts_at
     and o.starts_at < v_src.starts_at + interval '7 days'
     and (o.capacity - occurrence_seats_taken(o.id) - occurrence_seats_held(o.id)) >= 1
     and (coalesce(o.guarantee_tier,
                   case when o.flex then 'flex'::guarantee_tier end,
                   cs.guarantee_tier,
                   case when cs.flex then 'flex'::guarantee_tier end,
                   'core') = 'core')
   order by (o.booked_count > 0) desc, o.starts_at
   limit 8;
end $function$;
revoke execute on function core_classes_for_rescue(uuid) from public, anon;
grant  execute on function core_classes_for_rescue(uuid) to authenticated, service_role;

-- --- (4) flex_rescue_block(booking) — the email card list -------------------
-- Builds {class_list_core} (html) + text for a booking: the core classes from
-- core_classes_for_rescue as cards, each with a "Move me to this class" button
-- to the login-gated move page (?booking=..&target=..), max 8, then the
-- See-the-full-schedule button. {accent}/{accent_on} are filled by render_email.
create function flex_rescue_block(p_booking_id uuid)
returns table(html text, txt text)
language plpgsql stable security definer set search_path = public as $function$
declare
  v_b bookings%rowtype; v_src class_occurrences%rowtype;
  v_cards_html text := ''; v_cards_txt text := ''; r record; v_n int := 0;
  v_move text; v_book text; v_detail text;
begin
  select * into v_b from bookings where id = p_booking_id;
  if not found then return; end if;
  select * into v_src from class_occurrences where id = v_b.occurrence_id;
  v_book := member_portal_url(v_src.studio_id, '/book');

  for r in select * from core_classes_for_rescue(v_src.id) loop
    v_n := v_n + 1;
    v_move := member_portal_url(v_src.studio_id, '/move?booking=' || p_booking_id::text || '&target=' || r.occurrence_id::text);
    v_detail := concat_ws(' · ', r.day_label, r.time_label, nullif('with ' || r.coach_first, 'with '));
    v_cards_html := v_cards_html
      || '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:12px 0">'
      || '<tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px">'
      || '<div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">' || r.name || '</div>'
      || '<div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">' || v_detail || '</div>'
      || '<div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:13px;line-height:18px;color:#78716C;margin-top:2px">'
      || (case when r.n_booked > 0 then r.n_booked || ' in already · ' else '' end) || r.spots_left || ' spots left</div>'
      || '<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin-top:12px"><tr><td style="border-radius:6px;background:{accent}">'
      || '<a href="' || v_move || '" style="display:inline-block;padding:10px 20px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Move me to this class</a>'
      || '</td></tr></table>'
      || '</td></tr></table>';
    v_cards_txt := v_cards_txt || '- ' || r.name || ' · ' || v_detail
      || ' (' || (case when r.n_booked > 0 then r.n_booked || ' in already, ' else '' end) || r.spots_left || ' spots left): ' || v_move || E'\n';
  end loop;

  if v_n = 0 then
    html := '<p><a href="' || v_book || '">See the full schedule</a></p>';
    txt  := 'See the full schedule: ' || v_book;
  else
    html := v_cards_html
      || '<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}">'
      || '<a href="' || v_book || '" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">See the full schedule</a>'
      || '</td></tr></table>';
    txt := v_cards_txt || E'\nSee the full schedule: ' || v_book;
  end if;
  return next;
end $function$;
revoke execute on function flex_rescue_block(uuid) from public, anon, authenticated;
grant  execute on function flex_rescue_block(uuid) to service_role;

-- --- (5) rebook_run — the shared in-place move body (unguarded internal) -----
-- Exactly rebook_member's body (Decision 92) minus the is_desk_up guard: the
-- desk path and the member path are one implementation. auth.uid() stamps the
-- audit actor either way (staff or member). Service/internal only.
create function rebook_run(p_booking uuid, p_target uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_b bookings%rowtype; v_src class_occurrences%rowtype; v_tgt class_occurrences%rowtype;
  v_studio studios%rowtype; v_st studio_settings%rowtype; v_mem members%rowtype;
  v_tz text; v_fmt text; v_free int; v_covered boolean;
  v_when text; v_old_when text; v_instr text; v_src_name text; v_tgt_name text; v_manage text;
begin
  select * into v_tgt from class_occurrences where id = p_target for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no_such_class'); end if;

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

  if v_tgt.status <> 'scheduled' then
    return jsonb_build_object('ok', false, 'reason', 'class_not_scheduled'); end if;
  if v_tgt.starts_at <= now() then
    return jsonb_build_object('ok', false, 'reason', 'class_in_past'); end if;

  if exists (select 1 from bookings where occurrence_id = p_target and member_id = v_b.member_id
              and status in ('booked','attended','pending_payment','waitlisted')) then
    return jsonb_build_object('ok', false, 'reason', 'already_in_class'); end if;

  v_free := v_tgt.capacity - occurrence_seats_taken(p_target) - occurrence_seats_held(p_target);
  if v_free < 1 then return jsonb_build_object('ok', false, 'reason', 'class_full'); end if;

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

  -- MOVE IN PLACE. status unchanged, so no booking trigger fires.
  perform set_config('studiior.suppress_booking_email', '1', true);
  update bookings set occurrence_id = p_target, updated_at = now() where id = p_booking;
  update guest_passes set occurrence_id = p_target where guest_booking_id = p_booking;
  update class_occurrences set booked_count = greatest(booked_count - 1, 0) where id = v_src.id;
  update class_occurrences set booked_count = booked_count + 1 where id = p_target;
  perform set_config('studiior.suppress_booking_email', '0', true);

  perform confirm_provisional_seats_run(p_target);
  perform offer_waitlist_seat(v_src.id);

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
    'class_name', v_tgt_name, 'when', v_when, 'day',
    to_char(v_tgt.starts_at at time zone v_tz, 'FMDay FMDD FMMonth'),
    'time', fmt_clock(v_tgt.starts_at, v_tz, v_fmt));
end $$;
revoke execute on function rebook_run(uuid, uuid) from public, anon, authenticated;
grant  execute on function rebook_run(uuid, uuid) to service_role;

-- --- (6) rebook_member — desk-up wrapper over rebook_run --------------------
create or replace function rebook_member(p_booking uuid, p_target uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_studio uuid;
begin
  select studio_id into v_studio from class_occurrences where id = p_target;
  if v_studio is null then return jsonb_build_object('ok', false, 'reason', 'no_such_class'); end if;
  -- staff of the target's studio (owner / manager / front desk). An instructor
  -- is not desk-up, so they are refused — they keep the same-day "Move them
  -- here" on their own class (Decision 81a).
  if not coalesce(is_desk_up(v_studio), false) then
    raise exception 'only staff can rebook a member' using errcode = 'PT403';
  end if;
  return rebook_run(p_booking, p_target);
end $$;
revoke execute on function rebook_member(uuid, uuid) from public, anon;
grant  execute on function rebook_member(uuid, uuid) to authenticated, service_role;

-- --- (7) move_booking — the member-guarded rescue move ----------------------
-- The member opens a login-gated page (?booking=X&target=Y). move_booking is
-- member-guarded (auth.uid() owns the booking). Allowed only from an UNCONFIRMED
-- FLEX class (source_confirmed otherwise) to a scheduled, not-hidden class.
create function move_booking(p_booking_id uuid, p_target_occurrence_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_b bookings%rowtype; v_src class_occurrences%rowtype; v_tgt class_occurrences%rowtype; v_owns boolean;
begin
  select * into v_b from bookings where id = p_booking_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no_such_booking'); end if;

  v_owns := exists (select 1 from members m where m.id = v_b.member_id and m.user_id = auth.uid());
  if not (coalesce(v_owns, false) or is_service_context()) then
    raise exception 'that is not your booking' using errcode = 'PT403';
  end if;
  if v_b.status not in ('booked','pending_payment') then
    return jsonb_build_object('ok', false, 'reason', 'booking_not_live'); end if;

  select * into v_src from class_occurrences where id = v_b.occurrence_id;
  -- the source must be a flex class that has NOT reached its minimum yet
  if not (coalesce(v_src.flex, false)
          and v_src.status = 'scheduled'
          and v_src.flex_reached_minimum_at is null
          and v_src.committed_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'source_confirmed'); end if;

  select * into v_tgt from class_occurrences where id = p_target_occurrence_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no_such_class'); end if;
  if coalesce(v_tgt.hidden_from_members, false) then
    return jsonb_build_object('ok', false, 'reason', 'class_hidden'); end if;

  return rebook_run(p_booking_id, p_target_occurrence_id);
end $$;
revoke execute on function move_booking(uuid, uuid) from public, anon;
grant  execute on function move_booking(uuid, uuid) to authenticated, service_role;

-- --- (8) sweep_flex_rescue — nightly 2-day + hourly final --------------------
-- Queues flex_rescue_2days (p_phase '2day') and flex_rescue_final ('final').
-- Dedupe is the queue_notification key, so a member never gets either twice.
-- Service/internal; the cron below calls it for each phase.
create function sweep_flex_rescue(p_now timestamptz default now())
returns jsonb
language plpgsql security definer set search_path = public as $function$
declare
  r record; s studios%rowtype; st studio_settings%rowtype; v_tz text; v_fmt text;
  v_min int; v_booked int; v_n_more int; v_deadline timestamptz; v_send timestamptz;
  v_html text; v_txt text; v_day text; v_cutoff text; v_two int := 0; v_fin int := 0; v_key text;
begin
  for r in
    select b.id as booking_id, b.member_id, o.id as occ_id, o.studio_id, o.starts_at,
           coalesce(nullif(o.name, ''), ct.name) as class_name,
           coalesce(o.minimum_bookings, 0) as min_src
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
      join class_types ct on ct.id = o.class_type_id
     where b.status in ('booked','pending_payment')
       and o.status = 'scheduled'
       and o.flex
       and o.flex_reached_minimum_at is null
       and o.committed_at is null
       and o.starts_at > p_now
       and o.starts_at < p_now + interval '9 days'
  loop
    select * into s from studios where id = r.studio_id;
    select * into st from studio_settings where studio_id = r.studio_id;
    v_tz := s.timezone; v_fmt := coalesce(st.time_format, '24h');
    -- the live minimum for a flex class (its own, else the studio flex default)
    v_min := greatest(coalesce(nullif(r.min_src, 0),
                               coalesce(st.flex_min_bookings, 1)), 1);
    v_booked := occurrence_seats_taken(r.occ_id);
    v_n_more := greatest(v_min - v_booked, 1);
    v_day := to_char(r.starts_at at time zone v_tz, 'FMDay FMDD FMMonth');

    if (p_now at time zone v_tz)::date = (r.starts_at at time zone v_tz)::date - 2 then
      -- 2-day email: send at 10:00 studio-local that day (quiet-shifted)
      v_send := quiet_hours_shift(
        ((r.starts_at at time zone v_tz)::date - 2 + time '10:00') at time zone v_tz, v_tz);
      v_key := 'flex_rescue_2days:' || r.booking_id::text;
      if not exists (select 1 from notifications where dedupe_key = v_key) then
        select html, txt into v_html, v_txt from flex_rescue_block(r.booking_id);
        perform queue_notification(r.studio_id, r.member_id, 'flex_rescue_2days',
          jsonb_build_object('class_name', r.class_name, 'day', v_day, 'n_more', v_n_more,
            'class_list_core', v_html, 'class_list_core_text', v_txt,
            'studio_name', s.name, 'occurrence_id', r.occ_id),
          v_key, greatest(v_send, p_now));
        v_two := v_two + 1;
      end if;
    end if;

    -- final email: {flex_rescue_hours_before} hours before the flex cut-off
    select deadline_at into v_deadline from flex_deadline_for_run(r.occ_id);
    if v_deadline is not null
       and p_now >= v_deadline - make_interval(hours => coalesce(st.flex_rescue_hours_before, 3))
       and p_now < r.starts_at then
      v_cutoff := to_char(v_deadline at time zone v_tz, 'FMDy FMDD FMMon, ') || fmt_clock(v_deadline, v_tz, v_fmt);
      v_key := 'flex_rescue_final:' || r.booking_id::text;
      if not exists (select 1 from notifications where dedupe_key = v_key) then
        select html, txt into v_html, v_txt from flex_rescue_block(r.booking_id);
        perform queue_notification(r.studio_id, r.member_id, 'flex_rescue_final',
          jsonb_build_object('class_name', r.class_name, 'day', v_day, 'n_more', v_n_more,
            'cutoff_time', v_cutoff, 'class_list_core', v_html, 'class_list_core_text', v_txt,
            'studio_name', s.name, 'occurrence_id', r.occ_id),
          v_key, p_now);
        v_fin := v_fin + 1;
      end if;
    end if;
  end loop;
  return jsonb_build_object('two_day', v_two, 'final', v_fin);
end $function$;
revoke execute on function sweep_flex_rescue(timestamptz) from public, anon, authenticated;
grant  execute on function sweep_flex_rescue(timestamptz) to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin perform cron.unschedule('studiior-flex-rescue'); exception when others then null; end;
    perform cron.schedule('studiior-flex-rescue', '0 * * * *', $c$select sweep_flex_rescue()$c$);
  end if;
end $$;

-- --- (9) member_activity — re-issued with the rescue-email Journey arm ----
CREATE OR REPLACE FUNCTION public.member_activity(p_member_id uuid, p_from date, p_to date)
 RETURNS TABLE(at timestamp with time zone, kind text, title text, detail text, credit_delta integer, balance_after integer, amount_cents integer, currency text, occurrence_id uuid, booking_id uuid, membership_id uuid, plan_name text, due_cents integer, is_free_first boolean, occurrence_start timestamp with time zone, instructor_first text, credits_left_after integer, payment_method text, recorded_by_name text, plan_classes integer, plan_valid_to date, unused_credits integer, payment_source text, is_paid boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
declare v_studio uuid; v_is_staff boolean; v_owns boolean;
begin
  select studio_id into v_studio from members where id = p_member_id;
  if v_studio is null then raise exception 'no such member' using errcode = 'PT404'; end if;
  v_owns := exists (select 1 from members m where m.id = p_member_id and m.user_id = auth.uid());
  v_is_staff := coalesce(is_desk_up(v_studio), false) or is_service_context();
  if not (v_owns or v_is_staff) then
    raise exception 'that is not your statement' using errcode = 'PT403';
  end if;

  return query
  with led as (
    select cl.id, cl.delta, cl.reason::text as reason, cl.booking_id, cl.membership_id,
           cl.created_at,
           (sum(cl.delta) over (order by cl.created_at, cl.id))::int as bal,
           (sum(cl.delta) over (partition by cl.membership_id order by cl.created_at, cl.id))::int as membership_bal
      from credit_ledger cl
     where cl.member_id = p_member_id
  ),
  -- A purchase payment claims the Nth 'purchase' ledger row of its membership;
  -- a refunded payment claims the Nth negative 'manual' row of its membership.
  -- Rank joins, so each ledger id is claimed at most once; a grant with no
  -- payment (e.g. a complimentary membership) stays unclaimed and surfaces as its
  -- own "Credits added" line.
  purch_led as (
    select id, membership_id, row_number() over (partition by membership_id order by created_at, id) rn
      from led where reason = 'purchase' and membership_id is not null),
  purch_pay as (
    select p.id as payment_id, p.membership_id,
           row_number() over (partition by p.membership_id order by coalesce(p.paid_at, p.created_at), p.id) rn
      from payments p
     where p.member_id = p_member_id and p.membership_id is not null
       and p.status in ('succeeded', 'partially_refunded')),
  pay_grant as (
    select pp.payment_id, pl.id as ledger_id
      from purch_pay pp join purch_led pl on pl.membership_id = pp.membership_id and pl.rn = pp.rn),
  forfeit_led as (
    select id, membership_id, row_number() over (partition by membership_id order by created_at, id) rn
      from led where reason = 'manual' and delta < 0 and membership_id is not null),
  refund_pay as (
    select p.id as payment_id, p.membership_id,
           row_number() over (partition by p.membership_id order by coalesce(p.refunded_at, p.updated_at), p.id) rn
      from payments p
     where p.member_id = p_member_id and p.membership_id is not null
       and (p.refunded_at is not null or p.status in ('refunded', 'partially_refunded'))),
  pay_forfeit as (
    select rp.payment_id, fl.id as ledger_id
      from refund_pay rp join forfeit_led fl on fl.membership_id = rp.membership_id and fl.rn = rp.rn),
  ev as (
    -- Decision 95: a flex-rescue email was sent (staff only).
    select coalesce(nt.sent_at, nt.scheduled_for, nt.created_at) as at,
           'rescue_email' as kind, 'Rescue email sent' as title,
           case when nt.template_key = 'flex_rescue_2days'
                then 'Flex class still needs numbers'
                else 'Last call to move the booking' end as detail,
           null::uuid as ledger_id, null::int as amount_cents, null::text as currency,
           null::uuid as occurrence_id, null::uuid as booking_id, null::uuid as membership_id
      from notifications nt
     where nt.member_id = p_member_id and v_is_staff
       and nt.template_key in ('flex_rescue_2days','flex_rescue_final')
    union all
    -- joined (staff only)
    select m.joined_on::timestamptz as at, 'joined' as kind, 'Joined the studio' as title,
           nullif('Came via ' || coalesce(m.source, ''), 'Came via ') as detail,
           null::uuid as ledger_id, null::int as amount_cents, null::text as currency,
           null::uuid as occurrence_id, null::uuid as booking_id, null::uuid as membership_id
      from members m where m.id = p_member_id and v_is_staff and m.joined_on is not null
    union all
    -- booked / waitlisted / free first
    select b.booked_at,
           case when b.status = 'waitlisted' then 'waitlisted'
                when b.payment_source = 'comp'
                     and exists (select 1 from guest_passes gp where gp.guest_booking_id = b.id and gp.host_member_id is null)
                     then 'free_first'
                else 'booked' end,
           case when b.status = 'waitlisted' then 'Joined the waitlist for ' || coalesce(o.name, 'a class')
                when b.payment_source = 'comp'
                     and exists (select 1 from guest_passes gp where gp.guest_booking_id = b.id and gp.host_member_id is null)
                     then 'Booked a free first class — ' || coalesce(o.name, 'a class')
                when b.payment_source = 'group' then
                     (select case when gb.is_host
                                  then 'Group booking — ' || coalesce(o.name, 'a class') || ' · ' || mp.name
                                  else 'Booked by ' || hm.first_name || ' · ' || mp.name end
                        from group_bookings gb
                        join group_purchases gpu on gpu.id = gb.group_purchase_id
                        join membership_plans mp on mp.id = gpu.plan_id
                        join members hm on hm.id = gpu.host_member_id
                       where gb.booking_id = b.id)
                else 'Booked ' || coalesce(o.name, 'a class') end,
           case when b.payment_source = 'group' then
                  (select case when gb.is_host then (
                            select string_agg(coalesce(nullif(m2.first_name,''), m2.email), ', ')
                              from group_bookings gb2 join members m2 on m2.id = gb2.member_id
                             where gb2.group_purchase_id = gb.group_purchase_id and not gb2.is_host)
                          end
                     from group_bookings gb where gb.booking_id = b.id)
                when exists (select 1 from waitlist_offers wo where wo.booking_id = b.id and wo.outcome = 'accepted')
                then 'From the waitlist' end,
           b.credit_entry_id, null, null, b.occurrence_id, b.id, b.membership_id
      from bookings b left join class_occurrences o on o.id = b.occurrence_id
     where b.member_id = p_member_id
       and b.status in ('booked','attended','no_show','cancelled','late_cancelled','waitlisted','pending_payment')
    union all
    -- cancelled (carries the cancellation_refund, or 0 "class used")
    select b.cancelled_at,
           case when b.release_reason = 'studio_released' then 'studio_cancelled'
                when b.status = 'late_cancelled' or b.is_late_cancel then 'late_cancelled'
                else 'cancelled' end,
           case when b.release_reason = 'studio_released' then 'Studio cancelled ' || coalesce(o.name, 'a class')
                when b.status = 'late_cancelled' or b.is_late_cancel then 'Cancelled late — ' || coalesce(o.name, 'a class')
                else 'Cancelled ' || coalesce(o.name, 'a class') end,
           case when b.release_reason = 'studio_released' then 'Credit returned'
                when (b.status = 'late_cancelled' or b.is_late_cancel)
                     and not exists (select 1 from led cl where cl.booking_id = b.id and cl.reason = 'cancellation_refund')
                then 'Class used' end,
           (select cl.id from led cl where cl.booking_id = b.id and cl.reason = 'cancellation_refund' order by cl.created_at, cl.id limit 1),
           null, null, b.occurrence_id, b.id, b.membership_id
      from bookings b left join class_occurrences o on o.id = b.occurrence_id
     where b.member_id = p_member_id and b.status in ('cancelled','late_cancelled')
    union all
    -- checked in / attended
    select ci.checked_in_at, 'attended',
           case when o.id is null then 'Attended a class (imported)' else 'Attended ' || o.name end,
           null, null::uuid, null, null, ci.occurrence_id, ci.booking_id, null
      from check_ins ci left join class_occurrences o on o.id = ci.occurrence_id
     where ci.member_id = p_member_id
    union all
    -- no-show
    select coalesce(b.no_show_at, o.ends_at, b.updated_at), 'no_show',
           'Did not attend ' || coalesce(o.name, 'a class'), null,
           null::uuid, null, null, b.occurrence_id, b.id, b.membership_id
      from bookings b left join class_occurrences o on o.id = b.occurrence_id
     where b.member_id = p_member_id and b.status = 'no_show'
    union all
    -- purchase / refund / failed payment (carries the matched grant/forfeit)
    select coalesce(p.paid_at, p.created_at),
           case when p.refunded_at is not null or p.status in ('refunded','partially_refunded') then 'refund'
                when p.status = 'failed' then 'payment_failed'
                else 'purchase' end,
           case when p.refunded_at is not null or p.status in ('refunded','partially_refunded') then 'Refund — ' || coalesce(p.description, 'a payment')
                when p.status = 'failed' then 'Payment failed — ' || coalesce(p.description, 'a payment')
                else 'Bought ' || coalesce(p.description, 'a plan') end,
           null,
           case when p.refunded_at is not null or p.status in ('refunded','partially_refunded')
                then (select ledger_id from pay_forfeit pf where pf.payment_id = p.id)
                when p.status = 'failed' then null
                else (select ledger_id from pay_grant pg where pg.payment_id = p.id) end,
           case when p.refunded_at is not null then coalesce(p.refunded_cents, p.amount_cents) else p.amount_cents end,
           p.currency, null::uuid, p.booking_id, p.membership_id
      from payments p where p.member_id = p_member_id
    union all
    -- rescheduled / instructor changed, for occurrences the member holds a live booking on
    select oe.at,
           case when oe.kind = 'moved' then 'rescheduled' else 'instructor_changed' end,
           case when oe.kind = 'moved' then 'Class rescheduled — ' || coalesce(o.name, 'a class')
                else 'Instructor changed — ' || coalesce(o.name, 'a class') end,
           null, null::uuid, null, null, oe.occurrence_id, null, null
      from occurrence_events oe left join class_occurrences o on o.id = oe.occurrence_id
     where oe.kind in ('moved','instructor_changed')
       and exists (select 1 from bookings b where b.occurrence_id = oe.occurrence_id
                    and b.member_id = p_member_id and b.status <> 'cancelled')
    union all
    -- message_sent (staff only)
    select coalesce(msg.sent_at, msg.updated_at), 'message_sent', 'Message sent', msg.subject,
           null::uuid, null, null, null, null, null
      from messages msg
     where msg.member_id = p_member_id and v_is_staff and msg.status in ('queued','sent')
    union all
    -- contacted (staff only) — a task contacted the old way (no member_contacts
    -- row). A task linked to a contact (contact_id set) shows via the arm below.
    select mt.contacted_at, 'contacted', 'Contacted', mt.reason,
           null::uuid, null, null, null, null, null
      from member_tasks mt
     where mt.member_id = p_member_id and v_is_staff
       and mt.status = 'contacted' and mt.contacted_at is not null
       and mt.contact_id is null
    union all
    -- Decision 79: retention outreach logged in member_contacts (staff only).
    select mc.contacted_at, 'contacted',
           case when mc.method = 'email' then 'Emailed'
                when mc.method = 'viber' then 'Contacted (Viber)'
                when mc.method = 'call'  then 'Called'
                else 'Contacted (in person)' end
             || coalesce(' by ' || nullif(pr.full_name, ''), ''),
           mc.subject,
           null::uuid, null, null, null, null, null
      from member_contacts mc
      left join profiles pr on pr.id = mc.staff_id
     where mc.member_id = p_member_id and v_is_staff
    union all
    -- Decision 83 (a): a plan that ended (expired, or ended by staff) — NOT
    -- a refund, which tells its own story. Claims the end-forfeit ledger row
    -- so it is not also a bare "Credit adjustment"; unused = classes forfeited.
    select coalesce(ms2.cancelled_at, (ms2.expires_on)::timestamptz), 'plan_ended', 'Plan ended', null,
           (select cl.id from led cl
             where cl.membership_id = ms2.id and cl.reason = 'manual' and cl.delta < 0
               and cl.id not in (select ledger_id from pay_forfeit)
             order by cl.created_at desc, cl.id desc limit 1),
           null, null, null::uuid, null, ms2.id
      from memberships ms2
     where ms2.member_id = p_member_id
       and ms2.status in ('cancelled','expired')
       and coalesce(ms2.cancelled_at, (ms2.expires_on)::timestamptz) is not null
       and not exists (select 1 from payments p where p.membership_id = ms2.id
                        and (p.refunded_at is not null or p.status in ('refunded','partially_refunded')))
  ),
  claimed as (select distinct ledger_id from ev where ledger_id is not null),
  -- ledger rows no event claims: complimentary grants, manual adjustments,
  -- lockout, merch. Shown as their own credit lines.
  adj as (
    select l.created_at as at,
           case when l.reason = 'booking' then 'credit_used'
                when l.delta >= 0 then 'credits_added' else 'credit_adjustment' end as kind,
           case when l.reason = 'booking' then 'Class credit used'
                when l.reason = 'cancellation_refund' then 'Credit returned'
                when l.delta >= 0 then 'Credits added' else 'Credit adjustment' end as title,
           null::text as detail, l.id as ledger_id, null::int as amount_cents, null::text as currency,
           null::uuid as occurrence_id, l.booking_id, l.membership_id
      from led l where l.id not in (select ledger_id from claimed where ledger_id is not null)
  ),
  all_rows as (
    select * from ev
    union all
    select * from adj
  )
  select
    x.at, x.kind, x.title, x.detail,
    coalesce(l.delta, 0) as credit_delta,
    coalesce(l.bal,
             (select l2.bal from led l2 where l2.created_at <= x.at order by l2.created_at desc, l2.id desc limit 1),
             0) as balance_after,
    x.amount_cents, x.currency, x.occurrence_id, x.booking_id, x.membership_id,
    -- Decision 83. plan_name: the plan a booking drew from, a cancellation or a
    -- no-show consumed/returned to, or the ended plan. null on every other kind.
    case when x.kind in ('booked','cancelled','late_cancelled','studio_cancelled','no_show','plan_ended')
         then mp.name end as plan_name,
    -- due_cents: a LIVE unpaid drop-in booking only — the cheapest active public
    -- drop_in plan price, what Pay-now charges (bookings store no per-row price).
    case when x.kind = 'booked' and exists (
           select 1 from bookings b
            where b.id = x.booking_id and b.payment_source = 'drop_in' and b.status = 'booked'
              and not exists (select 1 from payments p
                               where p.booking_id = b.id and p.status in ('succeeded','partially_refunded')))
         then (select dp.price_cents from membership_plans dp
                where dp.studio_id = v_studio and dp.type = 'drop_in'
                  and dp.visibility = 'public' and dp.status = 'active'
                order by dp.price_cents asc, dp.sort_order asc, dp.id limit 1)
         end as due_cents,
    -- is_free_first: true on a free-first comp booking AND on its later cancel /
    -- no-show rows, so the helper can say "Free class used" / "Free class kept".
    (x.booking_id is not null and exists (
       select 1 from bookings b join guest_passes gp on gp.guest_booking_id = b.id
        where b.id = x.booking_id and b.payment_source = 'comp' and gp.host_member_id is null))
      as is_free_first,
    -- Decision 83 (a): the class instant + instructor, for the "{Day} {date},
    -- {time} with {instructor}" line (rowLine renders in the studio timezone).
    occ.starts_at as occurrence_start,
    nullif(split_part(coalesce(inst.display_name, ''), ' ', 1), '') as instructor_first,
    -- credits_left_after: the plan balance after this row. A no-show and a late
    -- cancel that used the credit carry no ledger of their own (the credit was
    -- spent at booking), so read that booking's consume row; a late cancel that
    -- refunded (consumes-off) has a refund ledger row, so coalesce keeps it. null
    -- = no plan credit touched (free first, unlimited, drop-in, money rows).
    case when x.kind in ('no_show','late_cancelled')
         then coalesce(l.membership_bal,
                       (select l2.membership_bal from led l2 join bookings b2 on b2.credit_entry_id = l2.id
                         where b2.id = x.booking_id))
         else l.membership_bal end as credits_left_after,
    -- payment_method / recorded_by_name: the money row's own payment (lateral,
    -- keyed on member + the arm's `at`). recorded_by is null for an online
    -- payment, so recorded_by_name is null unless it was taken at the desk.
    pm.method as payment_method,
    rec.full_name as recorded_by_name,
    case when x.kind = 'purchase' then coalesce(mp.credits, mp.credits_per_period) end as plan_classes,
    case when x.kind = 'purchase' then ms.expires_on end as plan_valid_to,
    case when x.kind = 'plan_ended' then abs(coalesce(l.delta, 0)) end as unused_credits,
    -- Decision 83 (a) follow-up: the booking's own payment_source (comp / drop_in /
    -- class_pack / membership / group), null for a non-booking row; and whether a
    -- booking row has a succeeded or partially_refunded payment, null otherwise.
    -- rowLine reads these to say "Complimentary" vs "Drop-in, paid" vs "due".
    (select b.payment_source::text from bookings b where b.id = x.booking_id) as payment_source,
    case when x.booking_id is not null
         then exists (select 1 from payments p
                       where p.booking_id = x.booking_id and p.status in ('succeeded','partially_refunded'))
         end as is_paid
  from all_rows x
  left join led l on l.id = x.ledger_id
  left join memberships ms on ms.id = x.membership_id
  left join membership_plans mp on mp.id = ms.plan_id
  left join class_occurrences occ on occ.id = x.occurrence_id
  left join instructors inst on inst.id = occ.instructor_id
  left join lateral (
    select p2.method, p2.recorded_by
      from payments p2
     where x.kind in ('purchase','refund','payment_failed')
       and p2.member_id = p_member_id
       and coalesce(p2.paid_at, p2.created_at) = x.at
     order by p2.id limit 1) pm on true
  left join profiles rec on rec.id = pm.recorded_by
  where x.at is not null and x.at::date between p_from and p_to
  order by x.at desc, x.kind;
end $function$;
revoke execute on function member_activity(uuid, date, date) from public, anon;
grant  execute on function member_activity(uuid, date, date) to authenticated, service_role;

-- --- (10) template_sample_context — re-issued with the rescue tokens -----
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
    'bookings_url', member_portal_url(p_studio_id, '/'))
  || jsonb_build_object(
    -- Decision 95: the flex-rescue tokens.
    'class_name', coalesce(o.cname, 'a class'),
    'day', to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMonth'),
    'n_more', 2,
    'cutoff_time', coalesce(v_when, 'the cut-off'),
    'class_list_core', '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:12px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-size:16px;font-weight:600;color:#14170E">' || coalesce(o.cname, 'a class') || '</div><div style="font-size:14px;color:#57534E;margin-top:4px">' || coalesce(v_when, 'soon') || '</div><div style="font-size:13px;color:#78716C;margin-top:2px">3 in already · 4 spots left</div><table role="presentation" style="margin-top:12px"><tr><td style="border-radius:6px;background:{accent}"><a href="#" style="display:inline-block;padding:10px 20px;color:{accent_on};text-decoration:none;font-weight:600;border-radius:6px">Move me to this class</a></td></tr></table></td></tr></table>',
    'class_list_core_text', '- ' || coalesce(o.cname, 'a class') || ' · ' || coalesce(v_when, 'soon') || ' (3 in already, 4 spots left)');
end $function$;
revoke execute on function template_sample_context(uuid, text, text) from public, anon, authenticated;
grant  execute on function template_sample_context(uuid, text, text) to service_role;

-- --- Anon stays EXACTLY THIRTEEN ------------------------------------------
do $$ declare n int; begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % (want 13)', n; end if;
end $$;
