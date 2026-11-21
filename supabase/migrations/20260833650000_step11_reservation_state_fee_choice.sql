-- Step 11 (21 Nov 2026): Decision 103 amendments (i) the reservation state is
-- always visible, (j) a seat is released only after it was asked for, (k) staff
-- paths ask for the fee at booking; Decision 21 (e) a day tier switch clears
-- stale latches; Decision 89 (b) message paragraphs; Decision 108 (a) two pay
-- watchdogs; Decision 80 note, three email tokens.
--
-- creates: free_due_sent(uuid, timestamptz), free_seat_reservation_state_run(uuid),
--   free_seat_reservation_state(uuid), occurrence_free_seat_states(uuid),
--   flex_pending_free_seats(uuid), reservation_fee_terms(uuid, uuid),
--   apply_free_fee_choice(uuid, text, text), message_paragraphs_html(text),
--   roster_table_render(jsonb), flex_cutoff_words(uuid),
--   book_first_free(uuid, uuid, text, text), convert_booking_to_free_first(uuid, text, text)
-- re-issues: sweep_free_reservation_dues(timestamptz), staff_book_member(uuid, uuid, jsonb, text),
--   set_occurrence_day_tier(uuid, text), render_email(uuid, text, text, text, text, text, jsonb, text, text),
--   template_sample_context(uuid, text, text), daily_money_check(uuid),
--   member_reservation_fees(uuid)
--
-- (j) The sweep releases an unpaid seat only when a due email for the booking
-- (any key free_reservation_due:{booking} or free_reservation_due:{booking}:*,
-- so a resend counts) has status sent AND was created before the deadline (a
-- member asked after the deadline never had the time). Otherwise the seat is
-- kept and daily_money_check lists it (item 13). A failed due is retried by
-- reconcile_notification_sends, which already treats every template alike
-- (Decision 113); it is not re-issued. Nudge (24 h before the class) and last
-- call (3 h before the deadline) are queued once each for unpaid, unwaived,
-- uncovered seats, on the per-email switch through queue_notification.
--
-- (k) book_first_free and convert_booking_to_free_first are DROPPED and
-- recreated with p_fee_choice ('due' | 'waive') and p_fee_note; grants are
-- re-applied exactly (authenticated, service_role; revoked from public, anon),
-- so no second overload exists. A studio call (p_member_id set, or convert)
-- refuses 'fee_choice_required' while the studio's fee is above zero and the
-- class is on or after the applies-from date and the member is not waived. A
-- member's own call is unchanged. staff_book_member reads fee_choice/fee_note
-- from p_source (a late add keeps Decision 100 (b): staff default waive, the
-- instructor always due).
--
-- No new anon RPC: anon stays EXACTLY FOURTEEN (asserted at apply).

-- ---- 1. Helpers -------------------------------------------------------------
-- A due email the member actually received: any due row for the booking, the
-- original or a resend keyed with a suffix, whose status is sent, and created
-- before p_before (the deadline) when given.
create or replace function free_due_sent(p_booking_id uuid, p_before timestamptz default null)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from notifications n
     where (n.dedupe_key = 'free_reservation_due:' || p_booking_id
            or n.dedupe_key like 'free_reservation_due:' || p_booking_id || ':%')
       and n.status = 'sent'
       and (p_before is null or n.created_at < p_before));
$$;
revoke execute on function free_due_sent(uuid, timestamptz) from public, anon, authenticated;
grant  execute on function free_due_sent(uuid, timestamptz) to service_role;

-- Decision 103 (i): one reservation state per free first class seat.
-- paid > covered > waived > due (a sent due email) > not_asked. Null state when
-- the seat is not a free first class seat or no fee applies to it.
create or replace function free_seat_reservation_state_run(p_booking_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare b bookings%rowtype; o class_occurrences%rowtype; st studio_settings%rowtype;
        s studios%rowtype; m members%rowtype; v_dead timestamptz; v_amt int; v_state text;
begin
  select * into b from bookings where id = p_booking_id;
  if not found or b.payment_source is distinct from 'comp' then
    return jsonb_build_object('state', null);
  end if;
  if not exists (select 1 from guest_passes gp
                  where gp.guest_booking_id = b.id and gp.host_member_id is null) then
    return jsonb_build_object('state', null);
  end if;
  select * into o from class_occurrences where id = b.occurrence_id;
  select * into st from studio_settings where studio_id = b.studio_id;
  select * into s from studios where id = b.studio_id;
  select * into m from members where id = b.member_id;
  if coalesce(st.free_first_reservation_fee_cents, 0) <= 0
     or st.free_first_reservation_from is null
     or (o.starts_at at time zone s.timezone)::date < st.free_first_reservation_from then
    return jsonb_build_object('state', null);
  end if;
  v_dead := o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0));
  select p.amount_cents into v_amt from payments p
   where p.booking_id = b.id and p.kind = 'reservation_fee'
     and p.status in ('succeeded','partially_refunded')
   order by p.created_at desc limit 1;
  v_state := case
    when v_amt is not null then 'paid'
    when coalesce(b.reservation_credit_covered, false) then 'covered'
    when m.reservation_fee_waived_at is not null or coalesce(b.reservation_fee_waived, false) then 'waived'
    when free_due_sent(b.id) then 'due'
    else 'not_asked' end;
  return jsonb_build_object(
    'state', v_state,
    'booking_id', b.id,
    'fee_cents', coalesce(v_amt, st.free_first_reservation_fee_cents),
    'currency', s.currency,
    'deadline_at', v_dead,
    'deadline_label', fmt_clock(v_dead, s.timezone, coalesce(st.time_format, '24h'))
                      || ' ' || to_char(v_dead at time zone s.timezone, 'FMDy FMDD FMMon'));
end $$;
revoke execute on function free_seat_reservation_state_run(uuid) from public, anon, authenticated;
grant  execute on function free_seat_reservation_state_run(uuid) to service_role;

-- The guarded reader: desk-up of the studio, the class's own instructor, the
-- member themself, or a background job.
create or replace function free_seat_reservation_state(p_booking_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare b bookings%rowtype; o class_occurrences%rowtype;
begin
  select * into b from bookings where id = p_booking_id;
  if not found then raise exception 'no such booking' using errcode = 'PT404'; end if;
  select * into o from class_occurrences where id = b.occurrence_id;
  if not (coalesce(is_desk_up(b.studio_id), false) or is_service_context()
          or coalesce(is_this_instructor(o.instructor_id), false)
          or exists (select 1 from members m where m.id = b.member_id and m.user_id = auth.uid())) then
    raise exception 'that is not yours to read' using errcode = 'PT403';
  end if;
  return free_seat_reservation_state_run(p_booking_id);
end $$;
revoke execute on function free_seat_reservation_state(uuid) from public, anon;
grant  execute on function free_seat_reservation_state(uuid) to authenticated, service_role;

-- Every free first class seat on one class with its state: the staff roster
-- and the coach's roster read this (desk-up or the class's own instructor).
create or replace function occurrence_free_seat_states(p_occurrence_id uuid)
returns table(booking_id uuid, state text, fee_cents int, currency text,
              deadline_at timestamptz, deadline_label text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare o class_occurrences%rowtype; r record; j jsonb;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not (coalesce(is_desk_up(o.studio_id), false) or is_service_context()
          or coalesce(is_this_instructor(o.instructor_id), false)) then
    raise exception 'that is not your class' using errcode = 'PT403';
  end if;
  for r in select b.id from bookings b
            where b.occurrence_id = p_occurrence_id and b.payment_source = 'comp'
              and b.status not in ('cancelled','late_cancelled','waitlisted') loop
    j := free_seat_reservation_state_run(r.id);
    if j ->> 'state' is not null then
      booking_id := r.id; state := j ->> 'state'; fee_cents := (j ->> 'fee_cents')::int;
      currency := j ->> 'currency'; deadline_at := (j ->> 'deadline_at')::timestamptz;
      deadline_label := j ->> 'deadline_label';
      return next;
    end if;
  end loop;
end $$;
revoke execute on function occurrence_free_seat_states(uuid) from public, anon;
grant  execute on function occurrence_free_seat_states(uuid) to authenticated, service_role;

-- Flex pending shows classes, not seats: one line per class. paid counts paid
-- and credit-covered seats; due counts seats that owe the fee whether or not
-- the email has gone; waived counts waived seats.
create or replace function flex_pending_free_seats(p_studio_id uuid)
returns table(occurrence_id uuid, n int, paid int, due int, waived int)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not (coalesce(is_desk_up(p_studio_id), false) or is_service_context()) then
    raise exception 'only staff read this' using errcode = 'PT403';
  end if;
  return query
  select x.occ, count(*)::int,
         count(*) filter (where x.st in ('paid','covered'))::int,
         count(*) filter (where x.st in ('due','not_asked'))::int,
         count(*) filter (where x.st = 'waived')::int
    from (select o.id as occ, free_seat_reservation_state_run(b.id) ->> 'state' as st
            from class_occurrences o
            join bookings b on b.occurrence_id = o.id
           where o.studio_id = p_studio_id and o.status = 'scheduled'
             and o.starts_at > now() and coalesce(o.flex, false)
             and o.committed_at is null
             and b.payment_source = 'comp'
             and b.status not in ('cancelled','late_cancelled','waitlisted')) x
   where x.st is not null
   group by x.occ;
end $$;
revoke execute on function flex_pending_free_seats(uuid) from public, anon;
grant  execute on function flex_pending_free_seats(uuid) to authenticated, service_role;

-- Decision 103 (k): what a staff sheet shows before booking a member's free
-- first class on this class. required = the fee choice must be made.
create or replace function reservation_fee_terms(p_occurrence_id uuid, p_member_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare o class_occurrences%rowtype; st studio_settings%rowtype; s studios%rowtype;
        m members%rowtype; v_dead timestamptz; v_req boolean; v_late boolean; v_fmt text;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not (coalesce(is_desk_up(o.studio_id), false) or is_service_context()
          or coalesce(is_this_instructor(o.instructor_id), false)) then
    raise exception 'that is not your class' using errcode = 'PT403';
  end if;
  select * into st from studio_settings where studio_id = o.studio_id;
  select * into s from studios where id = o.studio_id;
  select * into m from members where id = p_member_id and studio_id = o.studio_id;
  v_fmt := coalesce(st.time_format, '24h');
  v_late := now() >= o.starts_at;
  v_req := coalesce(st.free_first_reservation_fee_cents, 0) > 0
           and st.free_first_reservation_from is not null
           and (o.starts_at at time zone s.timezone)::date >= st.free_first_reservation_from
           and m.reservation_fee_waived_at is null;
  v_dead := o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0));
  return jsonb_build_object(
    'required', coalesce(v_req, false),
    'fee_cents', coalesce(st.free_first_reservation_fee_cents, 0),
    'fee_text', fmt_money(coalesce(st.free_first_reservation_fee_cents, 0), s.currency),
    'member_waived', m.reservation_fee_waived_at is not null,
    'deadline_label', case
       when v_late then 'the end of today'
       when v_dead <= now() then 'class time'
       else fmt_clock(v_dead, s.timezone, v_fmt) || ' ' || to_char(v_dead at time zone s.timezone, 'FMDy FMDD FMMon') end);
end $$;
revoke execute on function reservation_fee_terms(uuid, uuid) from public, anon;
grant  execute on function reservation_fee_terms(uuid, uuid) to authenticated, service_role;

-- Applies a staff fee choice to a free first class seat (internal; called by
-- book_first_free and convert_booking_to_free_first after they authorise).
-- 'waive' flags the booking waived with the note; 'due' sends the due email at
-- once. A late add (the studiior.late_add flag) is due by the end of today.
create or replace function apply_free_fee_choice(p_booking_id uuid, p_choice text, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype; o class_occurrences%rowtype; st studio_settings%rowtype;
        s studios%rowtype; v_dead timestamptz; v_fmt text; v_dl text; v_late boolean;
begin
  select * into b from bookings where id = p_booking_id;
  select * into o from class_occurrences where id = b.occurrence_id;
  select * into st from studio_settings where studio_id = b.studio_id;
  select * into s from studios where id = b.studio_id;
  v_fmt := coalesce(st.time_format, '24h');
  v_late := coalesce(current_setting('studiior.late_add', true), '') = '1';
  if p_choice = 'waive' then
    update bookings set reservation_fee_waived = true, updated_at = now() where id = p_booking_id;
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (b.studio_id, auth.uid(), 'booking.reservation_fee_waived', 'bookings', p_booking_id,
            jsonb_build_object('note', nullif(btrim(coalesce(p_note, '')), ''),
                               'occurrence_id', o.id, 'member_id', b.member_id));
  elsif p_choice = 'due' then
    if v_late then
      v_dl := 'the end of today';
    else
      v_dead := o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0));
      v_dl := case when v_dead <= now() then 'class time'
                   else fmt_clock(v_dead, s.timezone, v_fmt) || ' on '
                        || to_char(v_dead at time zone s.timezone, 'FMDay FMDD FMMonth') end;
    end if;
    perform queue_notification(b.studio_id, b.member_id, 'free_reservation_due',
      jsonb_build_object(
        'class_name', coalesce(o.name, (select name from class_types where id = o.class_type_id)),
        'day', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth'),
        'time', fmt_clock(o.starts_at, s.timezone, v_fmt),
        'fee', fmt_money(st.free_first_reservation_fee_cents, s.currency),
        'from_date', to_char(coalesce(st.free_first_reservation_from, now()::date), 'FMDD Mon'),
        'deadline', v_dl,
        'pay_url', member_portal_url(b.studio_id, '/class/' || o.id),
        'cancel_url', member_portal_url(b.studio_id, '/class/' || o.id)),
      'free_reservation_due:' || p_booking_id);
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (b.studio_id, auth.uid(), 'booking.reservation_fee_asked', 'bookings', p_booking_id,
            jsonb_build_object('deadline', v_dl, 'occurrence_id', o.id, 'member_id', b.member_id));
  end if;
end $$;
revoke execute on function apply_free_fee_choice(uuid, text, text) from public, anon, authenticated;
grant  execute on function apply_free_fee_choice(uuid, text, text) to service_role;

-- Decision 89 (b): a blank line starts a paragraph, a single break is a <br>,
-- Windows line endings normalised. Escapes &, <, >.
create or replace function message_paragraphs_html(p_text text)
returns text language sql immutable set search_path = public as $$
  select coalesce(string_agg(
           '<p style="margin:0 0 10px">'
           || replace(replace(replace(replace(btrim(para, E'\n'), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'),
                      E'\n', '<br>')
           || '</p>', '' order by ord), '')
    from regexp_split_to_table(
           regexp_replace(replace(replace(coalesce(p_text, ''), E'\r\n', E'\n'), E'\r', E'\n'),
                          E'\\n{3,}', E'\n\n', 'g'),
           E'\\n[ \\t]*\\n') with ordinality as t(para, ord)
   where btrim(para, E' \t\n') <> '';
$$;
revoke execute on function message_paragraphs_html(text) from public, anon;
grant  execute on function message_paragraphs_html(text) to authenticated, service_role;

-- Decision 80 note: {roster_table}. rows = [{day, time, class}].
create or replace function roster_table_render(p_rows jsonb)
returns table(html text, txt text) language sql immutable set search_path = public as $$
  with r as (
    select e ->> 'day' as day, e ->> 'time' as tm, e ->> 'class' as cls, ord
      from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) with ordinality as x(e, ord))
  select
    '<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="border-collapse:collapse;margin:12px 0;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;color:#14170E">'
    || '<tr><th align="left" style="padding:6px 14px 6px 0;border-bottom:1px solid #E7E5E4;color:#57534E;font-weight:600">Day</th>'
    || '<th align="left" style="padding:6px 14px 6px 0;border-bottom:1px solid #E7E5E4;color:#57534E;font-weight:600">Time</th>'
    || '<th align="left" style="padding:6px 0;border-bottom:1px solid #E7E5E4;color:#57534E;font-weight:600">Class</th></tr>'
    || coalesce((select string_agg('<tr><td style="padding:6px 14px 6px 0;border-bottom:1px solid #F5F5F4">'
           || replace(replace(coalesce(day,''),'&','&amp;'),'<','&lt;') || '</td><td style="padding:6px 14px 6px 0;border-bottom:1px solid #F5F5F4">'
           || replace(replace(coalesce(tm,''),'&','&amp;'),'<','&lt;') || '</td><td style="padding:6px 0;border-bottom:1px solid #F5F5F4">'
           || replace(replace(coalesce(cls,''),'&','&amp;'),'<','&lt;') || '</td></tr>', '' order by ord) from r), '')
    || '</table>',
    coalesce((select string_agg(rpad(coalesce(day,''), (select greatest(max(length(coalesce(day,''))), 3) from r) + 2)
                                || rpad(coalesce(tm,''), (select greatest(max(length(coalesce(tm,''))), 4) from r) + 2)
                                || coalesce(cls,''), E'\n' order by ord) from r), '');
$$;
revoke execute on function roster_table_render(jsonb) from public, anon;
grant  execute on function roster_table_render(jsonb) to authenticated, service_role;

-- Decision 80 note: {flex_cutoff} in words, per the studio's flex rule.
create or replace function flex_cutoff_words(p_studio_id uuid)
returns text language sql stable security definer set search_path = public as $$
  select case
    when st.flex_deadline_mode = 'previous_day_at' and st.flex_deadline_time is not null then
      fmt_clock((date '2000-01-01' + st.flex_deadline_time)::timestamp at time zone 'UTC', 'UTC',
                coalesce(st.time_format, '24h')) || ' the evening before'
    else coalesce(st.flex_deadline_hours, 12)::text || ' hours before class' end
  from studio_settings st where st.studio_id = p_studio_id;
$$;
revoke execute on function flex_cutoff_words(uuid) from public, anon, authenticated;
grant  execute on function flex_cutoff_words(uuid) to service_role;

-- ---- 2. Templates (platform defaults; Reform overrides in RPC voice) --------
insert into notification_templates (key, subject, text_body, html_body, note) values
('free_reservation_nudge', 'Your free class is tomorrow: pay {fee} by {deadline}',
 E'Hi {first_name},\n\nYour free class is tomorrow: {class_name}, {day} at {time}.\n\nPay the {fee} reservation fee by {deadline} to keep your spot.\n\nThis is a reservation fee, not a charge for the class. Show up and the {fee} comes back to you as studio credit to use on class packages or merchandise. If you don''t show up or cancel late, the fee is kept.\n\nPay {fee} to keep my spot: {pay_url}\nCancel my booking: {cancel_url}',
 '<p>Hi {first_name},</p><table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{class_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">{day} · {time}</div></td></tr></table><p>Your free class is tomorrow. Pay the {fee} reservation fee by {deadline} to keep your spot.</p><p>This is a reservation fee, not a charge for the class. Show up and the {fee} comes back to you as studio credit to use on class packages or merchandise. If you don&#39;t show up or cancel late, the fee is kept.</p><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{pay_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Pay {fee} to keep my spot</a></td></tr></table><p><a href="{cancel_url}" style="color:#57534E">Cancel my booking</a></p><p>{studio_name}</p>',
 'Decision 103 (j). An unpaid free first class seat, 24 hours before the class.')
on conflict (key) do nothing;
insert into notification_templates (key, subject, text_body, html_body, note) values
('free_reservation_last_call', 'Last call: pay {fee} by {deadline} to keep your spot',
 E'Hi {first_name},\n\nThis is the last call for your free class: {class_name}, {day} at {time}. The {fee} reservation fee is due by {deadline}. After that we release the spot.\n\nThis is a reservation fee, not a charge for the class. Show up and the {fee} comes back to you as studio credit to use on class packages or merchandise. If you don''t show up or cancel late, the fee is kept.\n\nPay {fee} to keep my spot: {pay_url}\nCancel my booking: {cancel_url}',
 '<p>Hi {first_name},</p><table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{class_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">{day} · {time}</div></td></tr></table><p>This is the last call. The {fee} reservation fee is due by {deadline}. After that we release the spot.</p><p>This is a reservation fee, not a charge for the class. Show up and the {fee} comes back to you as studio credit to use on class packages or merchandise. If you don&#39;t show up or cancel late, the fee is kept.</p><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{pay_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Pay {fee} to keep my spot</a></td></tr></table><p><a href="{cancel_url}" style="color:#57534E">Cancel my booking</a></p><p>{studio_name}</p>',
 'Decision 103 (j). An unpaid free first class seat, 3 hours before the deadline.')
on conflict (key) do nothing;
insert into notification_templates_overrides (studio_id, key, subject, body, body_html)
select s.id, 'free_reservation_nudge', 'See you tomorrow, {first_name}! Keep your spot 🎀',
 E'Hi {first_name}!\n\nSo excited to see you tomorrow for {class_name}, {day} at {time}! 🎀\n\nTo keep your spot, please settle the {fee} reservation fee by {deadline}.\n\nThis is a reservation fee, not a charge for the class. Show up and the {fee} comes back to you as studio credit to use on class packages or merchandise. If you don''t show up or cancel late, the fee is kept.\n\n[Pay {fee} to keep my spot]({pay_url}){button}\n\nCan''t make it anymore? You can cancel here: {cancel_url}\n\nSee you at the reformer!\nRPC Studio',
 '<p>Hi {first_name}!</p><table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{class_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">{day} · {time}</div></td></tr></table><p>So excited to see you tomorrow! 🎀 To keep your spot, please settle the {fee} reservation fee by {deadline}.</p><p>This is a reservation fee, not a charge for the class. Show up and the {fee} comes back to you as studio credit to use on class packages or merchandise. If you don&#39;t show up or cancel late, the fee is kept.</p><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{pay_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Pay {fee} to keep my spot</a></td></tr></table><p>Can&#39;t make it anymore? <a href="{cancel_url}" style="color:#57534E">You can cancel here</a>.</p><p>See you at the reformer!<br>RPC Studio</p>'
  from studios s where s.slug = 'reformcollective'
on conflict (studio_id, key) do nothing;
insert into notification_templates_overrides (studio_id, key, subject, body, body_html)
select s.id, 'free_reservation_last_call', 'Last call to keep your spot, {first_name}',
 E'Hi {first_name}!\n\nJust a gentle last reminder for your free class, {class_name}, {day} at {time}. 💗\n\nThe {fee} reservation fee is due by {deadline}. After that we''ll have to release your spot to someone on the list.\n\nThis is a reservation fee, not a charge for the class. Show up and the {fee} comes back to you as studio credit to use on class packages or merchandise. If you don''t show up or cancel late, the fee is kept.\n\n[Pay {fee} to keep my spot]({pay_url}){button}\n\nCan''t make it anymore? You can cancel here: {cancel_url}\n\nRPC Studio',
 '<p>Hi {first_name}!</p><table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{class_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">{day} · {time}</div></td></tr></table><p>Just a gentle last reminder for your free class. 💗 The {fee} reservation fee is due by {deadline}. After that we&#39;ll have to release your spot to someone on the list.</p><p>This is a reservation fee, not a charge for the class. Show up and the {fee} comes back to you as studio credit to use on class packages or merchandise. If you don&#39;t show up or cancel late, the fee is kept.</p><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{pay_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Pay {fee} to keep my spot</a></td></tr></table><p>Can&#39;t make it anymore? <a href="{cancel_url}" style="color:#57534E">You can cancel here</a>.</p><p>RPC Studio</p>'
  from studios s where s.slug = 'reformcollective'
on conflict (studio_id, key) do nothing;

-- ---- 3. book_first_free: DROP + recreate with the fee choice ---------------
drop function if exists public.book_first_free(uuid, uuid);
CREATE FUNCTION public.book_first_free(p_occurrence_id uuid, p_member_id uuid DEFAULT NULL::uuid, p_fee_choice text DEFAULT NULL::text, p_fee_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_occ    class_occurrences%rowtype;
  v_member members%rowtype;
  v_set    studio_settings%rowtype;
  v_ser    class_series%rowtype;
  v_cfg_tier guarantee_tier;
  v_tz     text;
  v_elig   jsonb;
  v_free   int;
  v_head   int;
  v_cut    timestamptz;
  v_prov   boolean;
  v_booking uuid;
  v_pass    uuid;
  v_fee_req boolean := false;
begin
  select * into v_occ from class_occurrences where id = p_occurrence_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;

  -- Decision 100: staff may book a member's free first class (desk-up). Self when
  -- p_member_id is null, which is how the member's own call resolves.
  if p_member_id is not null then
    if not (coalesce(is_desk_up(v_occ.studio_id), false) or is_service_context()
            or coalesce(current_setting('studiior.late_add', true) = '1', false)) then
      return jsonb_build_object('ok', false, 'reason', 'not_authorised');
    end if;
    select * into v_member from members
     where id = p_member_id and studio_id = v_occ.studio_id and deleted_at is null;
  else
    select * into v_member from members
     where studio_id = v_occ.studio_id and user_id = auth.uid();
  end if;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_authorised'); end if;

  -- Decision 100 amendment (b): a late add by the class's own instructor is not
  -- desk-up, so use the unguarded eligibility twin under the flag (the picker
  -- already offered free first after its own check).
  if current_setting('studiior.late_add', true) = '1' then
    v_elig := free_first_eligibility_run(v_occ.studio_id, v_member.id, null);
  else
    v_elig := free_first_eligibility(v_occ.studio_id, v_member.id);
  end if;
  if not (v_elig ->> 'ok')::boolean then return v_elig; end if;

  select * into v_set from studio_settings where studio_id = v_occ.studio_id;
  select timezone into v_tz from studios where id = v_occ.studio_id;

  if v_occ.status <> 'scheduled' then return jsonb_build_object('ok', false, 'reason', 'class_not_bookable'); end if;
  if current_setting('studiior.late_add', true) = '1' then
    if v_occ.ends_at <= now() then return jsonb_build_object('ok', false, 'reason', 'class_ended'); end if;
  elsif v_occ.starts_at <= now() then return jsonb_build_object('ok', false, 'reason', 'class_in_past'); end if;
  if not month_published(v_occ.studio_id, v_occ.starts_at) then
    return jsonb_build_object('ok', false, 'reason', 'month_not_published');
  end if;
  if studio_hides_unstaffed(v_occ.studio_id) and v_occ.staffing <> 'assigned' then
    return jsonb_build_object('ok', false, 'reason', 'not_staffed_yet');
  end if;
  if v_occ.hidden_from_members then
    return jsonb_build_object('ok', false, 'reason', 'class_hidden');
  end if;
  if v_occ.starts_at > now() + make_interval(days => coalesce(v_set.booking_window_days, 30)) then
    return jsonb_build_object('ok', false, 'reason', 'outside_booking_window');
  end if;
  if current_setting('studiior.late_add', true) = '1' then
    null;  -- a late add is inside the cutoff by definition; the flag bypasses it
  elsif v_occ.starts_at < now() + make_interval(mins => coalesce(v_set.booking_cutoff_minutes, 0)) then
    return jsonb_build_object('ok', false, 'reason', 'past_booking_cutoff');
  end if;

  -- Decision 30 amendment (b): a per-class override. 'closed' = never, whatever
  -- the rules say; 'open' skips core_only and the series switch below (seat cap
  -- and peak still apply).
  if v_occ.free_first_override = 'closed' then
    return jsonb_build_object('ok', false, 'reason', 'free_first_closed_here');
  end if;

  if not coalesce(v_set.free_first_peak_allowed, true) and occurrence_is_peak(p_occurrence_id) then
    return jsonb_build_object('ok', false, 'reason', 'peak_not_allowed');
  end if;

  if v_occ.series_id is not null then
    select * into v_ser from class_series where id = v_occ.series_id;
  end if;
  v_cfg_tier := coalesce(v_occ.guarantee_tier,
                         case when v_occ.flex then 'flex'::guarantee_tier end,
                         v_ser.guarantee_tier,
                         case when v_ser.flex then 'flex'::guarantee_tier end,
                         'core'::guarantee_tier);
  if coalesce(v_set.free_first_core_only, false) and v_cfg_tier <> 'core'
     and v_occ.free_first_override is distinct from 'open'
     and coalesce(current_setting('studiior.free_on_flex', true), '') is distinct from '1' then
    return jsonb_build_object('ok', false, 'reason', 'flex_not_allowed');
  end if;
  if v_occ.series_id is not null
     and not coalesce(v_ser.free_first_allowed, true)
     and v_occ.free_first_override is distinct from 'open' then
    return jsonb_build_object('ok', false, 'reason', 'not_trial_class');
  end if;
  if v_set.free_first_seats_per_class is not null
     and (select count(*) from bookings b
           where b.occurrence_id = p_occurrence_id and b.status = 'booked'
             and b.payment_source = 'comp'
             and exists (select 1 from guest_passes gp
                          where gp.guest_booking_id = b.id and gp.host_member_id is null))
         >= v_set.free_first_seats_per_class then
    return jsonb_build_object('ok', false, 'reason', 'free_seats_full');
  end if;

  v_free := v_occ.capacity - occurrence_seats_taken(p_occurrence_id)
                           - occurrence_seats_held(p_occurrence_id);
  if v_free < 1 then return jsonb_build_object('ok', false, 'reason', 'class_full'); end if;

  v_head := occurrence_seats_taken(p_occurrence_id) + 1;
  select cutoff_at into v_cut from occurrence_guarantee_run(p_occurrence_id);
  v_prov := v_set.free_first_confirm_at is not null
            and v_cut is not null
            and v_head < v_set.free_first_confirm_at;

  -- Decision 103 (k): a studio call (p_member_id set) must choose due or waive
  -- while the studio's fee is above zero, the class is on or after the
  -- applies-from date and the member is not waived. A member's own call is
  -- unchanged (the app's reserve path takes the fee).
  if p_member_id is not null then
    -- A late add (Decision 100 b) asks whenever a fee is set, whatever the
    -- applies-from date, as it always has.
    v_fee_req := coalesce(v_set.free_first_reservation_fee_cents, 0) > 0
                 and v_member.reservation_fee_waived_at is null
                 and (coalesce(current_setting('studiior.late_add', true) = '1', false)
                      or (v_set.free_first_reservation_from is not null
                          and (v_occ.starts_at at time zone v_tz)::date >= v_set.free_first_reservation_from));
    if v_fee_req and coalesce(p_fee_choice, '') not in ('due', 'waive') then
      return jsonb_build_object('ok', false, 'reason', 'fee_choice_required');
    end if;
  end if;

  -- Mark this seat a free first class for the AFTER-INSERT notification trigger,
  -- which fires before the guest_passes row below is written.
  perform set_config('studiior.free_first', '1', true);

  insert into bookings (studio_id, occurrence_id, member_id, status, source,
                        payment_source, provisional, confirmed_at)
  values (v_occ.studio_id, p_occurrence_id, v_member.id, 'booked', 'member', 'comp',
          v_prov, case when v_prov then null else now() end)
  returning id into v_booking;
  update class_occurrences set booked_count = booked_count + 1 where id = p_occurrence_id;

  -- The shared once-ever ledger row. Decision 78: a no-show member's rebook
  -- REUSES this row (upsert on the once-ever index) rather than inserting a
  -- second — the index and its hard guarantee are untouched; the member's comp
  -- no_show bookings are what count the attempts.
  insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email,
                            occurrence_id, guest_booking_id, status, waiver_signed_at)
  values (v_occ.studio_id, null, v_member.id, lower(btrim(v_member.email)),
          p_occurrence_id, v_booking,
          case when v_member.waiver_signed_at is not null then 'confirmed' else 'invited' end,
          v_member.waiver_signed_at)
  on conflict (studio_id, normalize_email_key(guest_email)) do update
    set host_member_id   = excluded.host_member_id,
        guest_member_id  = excluded.guest_member_id,
        occurrence_id    = excluded.occurrence_id,
        guest_booking_id = excluded.guest_booking_id,
        status           = excluded.status,
        waiver_signed_at = excluded.waiver_signed_at
  returning id into v_pass;

  perform confirm_provisional_seats_run(p_occurrence_id);

  if v_fee_req then
    perform apply_free_fee_choice(v_booking, p_fee_choice, p_fee_note);
  end if;

  return jsonb_build_object('ok', true, 'booking_id', v_booking,
    'guest_pass_id', v_pass, 'provisional', v_prov);
end $function$;

revoke execute on function book_first_free(uuid, uuid, text, text) from public, anon;
grant  execute on function book_first_free(uuid, uuid, text, text) to authenticated, service_role;

-- ---- 4. convert_booking_to_free_first: DROP + recreate with the fee choice --
drop function if exists public.convert_booking_to_free_first(uuid);
create function convert_booking_to_free_first(p_booking_id uuid, p_fee_choice text default null, p_fee_note text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_b    bookings%rowtype;
  v_occ  class_occurrences%rowtype;
  v_m    members%rowtype;
  v_s    studios%rowtype;
  v_st   studio_settings%rowtype;
  v_elig jsonb;
  v_fmt  text;
  v_manage text;
  v_cancel_deadline text;
  v_pass uuid;
  v_fee_req boolean := false;
begin
  select * into v_b from bookings where id = p_booking_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;

  -- Owner/manager of the booking's studio, or a background job.
  if not (coalesce(is_manager_up(v_b.studio_id), false) or is_service_context()) then
    raise exception 'only owners and managers do this' using errcode = 'PT403';
  end if;

  if v_b.status in ('cancelled','late_cancelled') then
    return jsonb_build_object('ok', false, 'reason', 'booking is cancelled');
  end if;
  if v_b.payment_source <> 'drop_in' then
    return jsonb_build_object('ok', false, 'reason', 'not a drop-in booking');
  end if;
  if exists (select 1 from payments p
              where p.booking_id = p_booking_id and p.status in ('succeeded','partially_refunded')) then
    return jsonb_build_object('ok', false, 'reason', 'booking is paid');
  end if;

  -- Free-first eligibility judged as if this booking did not exist (answer 1): the
  -- drop-in being converted is excluded from the qualifying-booking counts. Any
  -- other reason (already_had_free via a real free class / membership / guest pass,
  -- already_member, missed, not_first via another paid class, not_enabled) refuses
  -- with the helper's own wording.
  --
  -- Decision 30 (d, continued): a late cancel uses the free class, BUT staff may
  -- still grant another by hand — so a 'late_cancel' refusal is OVERRIDDEN here
  -- (this convert IS that by-hand grant). It re-points the once-ever pass at the
  -- new seat, which is the one allowed reuse after a late cancel.
  v_elig := free_first_eligibility(v_b.studio_id, v_b.member_id, p_booking_id);
  if not (v_elig ->> 'ok')::boolean and (v_elig ->> 'reason') not in ('late_cancel', 'duplicate') then
    return v_elig;
  end if;

  -- The class must be open to first-timers (Decision 30 amendment b).
  if not coalesce((effective_free_first(v_b.occurrence_id) ->> 'effective_open')::boolean, false) then
    return jsonb_build_object('ok', false, 'reason', 'class is not open to first-timers');
  end if;

  select * into v_occ from class_occurrences where id = v_b.occurrence_id for update;
  select * into v_m from members where id = v_b.member_id;
  select * into v_s from studios where id = v_b.studio_id;
  select * into v_st from studio_settings where studio_id = v_b.studio_id;
  v_fmt := coalesce(v_st.time_format, '24h');

  -- Decision 103 (k): the studio chooses due or waive while a fee applies.
  v_fee_req := coalesce(v_st.free_first_reservation_fee_cents, 0) > 0
               and v_st.free_first_reservation_from is not null
               and (v_occ.starts_at at time zone v_s.timezone)::date >= v_st.free_first_reservation_from
               and v_m.reservation_fee_waived_at is null;
  if v_fee_req and coalesce(p_fee_choice, '') not in ('due', 'waive') then
    return jsonb_build_object('ok', false, 'reason', 'fee_choice_required');
  end if;

  -- Mark the seat a free first class (harmless on an UPDATE, consistent with
  -- book_first_free). The seat is CONFIRMED and non-provisional whatever
  -- free_first_confirm_at is, so release_provisional_seats_run never touches it.
  perform set_config('studiior.free_first', '1', true);

  update bookings
     set payment_source = 'comp',
         provisional    = false,
         confirmed_at    = now(),
         status          = 'booked',
         updated_at      = now()
   where id = p_booking_id;
  -- booked_count is unchanged: a booked drop-in already occupies the seat; only the
  -- payment source changes.

  -- The shared once-ever ledger row, written/reused exactly as book_first_free's
  -- upsert on the once-ever index (the nine already have a host-null row — it is
  -- re-pointed at this booking; a late-cancel member's row is likewise re-pointed,
  -- which is the by-hand reuse this amendment allows).
  insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email,
                            occurrence_id, guest_booking_id, status, waiver_signed_at)
  values (v_b.studio_id, null, v_m.id, lower(btrim(v_m.email)),
          v_b.occurrence_id, p_booking_id,
          case when v_m.waiver_signed_at is not null then 'confirmed' else 'invited' end,
          v_m.waiver_signed_at)
  on conflict (studio_id, normalize_email_key(guest_email)) do update
    set host_member_id   = excluded.host_member_id,
        guest_member_id  = excluded.guest_member_id,
        occurrence_id    = excluded.occurrence_id,
        guest_booking_id = excluded.guest_booking_id,
        status           = excluded.status,
        waiver_signed_at = excluded.waiver_signed_at
  returning id into v_pass;

  v_manage := 'https://' || v_s.slug || '.'
              || coalesce(notification_setting('member_app_domain'), 'studiior.app')
              || '/class/' || v_occ.id;
  v_cancel_deadline :=
    fmt_clock(v_occ.starts_at - make_interval(mins => coalesce(v_st.cancellation_cutoff_minutes, 0)), v_s.timezone, v_fmt)
    || ' on ' || to_char(
      (v_occ.starts_at - make_interval(mins => coalesce(v_st.cancellation_cutoff_minutes, 0)))
        at time zone v_s.timezone, 'FMDay FMDD FMMonth YYYY');

  perform queue_notification(v_b.studio_id, v_b.member_id, 'free_booking_confirmed',
    jsonb_build_object('class_name', v_occ.name,
      'day',  to_char(v_occ.starts_at at time zone v_s.timezone, 'FMDay FMDD FMMonth'),
      'time', fmt_clock(v_occ.starts_at, v_s.timezone, v_fmt),
      'cancel_deadline', v_cancel_deadline,
      'manage_link', v_manage,
      'occurrence_id', v_occ.id),
    'free_booking_confirmed:' || p_booking_id);

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (v_b.studio_id, auth.uid(), 'booking.converted_to_free_first', 'bookings', p_booking_id,
          jsonb_build_object('occurrence_id', v_occ.id, 'member_id', v_b.member_id));

  if v_fee_req then
    perform apply_free_fee_choice(p_booking_id, p_fee_choice, p_fee_note);
  end if;

  return jsonb_build_object('ok', true, 'booking_id', p_booking_id, 'guest_pass_id', v_pass);
end $$;

revoke execute on function convert_booking_to_free_first(uuid, text, text) from public, anon;
grant  execute on function convert_booking_to_free_first(uuid, text, text) to authenticated, service_role;

-- ---- 5. staff_book_member: pass the fee choice through ---------------------
CREATE OR REPLACE FUNCTION public.staff_book_member(p_member_id uuid, p_occurrence_id uuid, p_source jsonb, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_occ    class_occurrences%rowtype;
  v_set    studio_settings%rowtype;
  v_member members%rowtype;
  v_mgr    boolean;
  v_kind   text;
  v_res    book_class_result;
  v_booking uuid;
  v_conv   jsonb;
  v_pay    jsonb;
  v_staff_first text;
  v_cap    int;
  v_unpaid int;
  v_label  text;
  v_late   boolean;
  v_method text;
  v_tz     text;
  v_fmt    text;
  v_fee    int;
  v_waive  boolean;
  v_deadline timestamptz;
  v_choice text;
  v_fnote  text;
begin
  select * into v_occ from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  -- Decision 100 amendment (b): desk-up adds any member; the class's own
  -- instructor may add a member to THAT class only.
  if not (coalesce(is_desk_up(v_occ.studio_id), false) or is_service_context()
          or coalesce(is_this_instructor(v_occ.instructor_id), false)) then
    raise exception 'only the desk and up, or the class instructor, book for a member' using errcode = 'PT403';
  end if;
  select * into v_member from members where id = p_member_id and studio_id = v_occ.studio_id and deleted_at is null;
  if not found then raise exception 'no such member' using errcode = 'PT404'; end if;
  select * into v_set from studio_settings where studio_id = v_occ.studio_id;
  v_mgr := coalesce(is_manager_up(v_occ.studio_id), false) or is_service_context();
  v_staff_first := coalesce(
    nullif(split_part((select full_name from profiles where id = auth.uid()), ' ', 1), ''),
    'the studio');
  v_kind := p_source ->> 'kind';
  v_label := p_source ->> 'kind';

  -- Decision 100 amendment (b): a late add books into a class that has
  -- started; after it ends the roster offers no add.
  select timezone into v_tz from studios where id = v_occ.studio_id;
  v_fmt  := v_set.time_format;
  v_late := now() >= v_occ.starts_at;
  if v_late and now() >= v_occ.ends_at then
    return jsonb_build_object('ok', false, 'reason', 'class_ended', 'member_first', v_member.first_name);
  end if;
  v_method := case when coalesce(is_this_instructor(v_occ.instructor_id), false)
                     and not coalesce(is_desk_up(v_occ.studio_id), false)
                   then 'instructor' else 'staff' end;
  if v_late then perform set_config('studiior.late_add', '1', true); end if;

  -- Decision 103 (k): the fee choice for a free first class, read from the
  -- sheet ('due' or 'waive', and a note). A late add keeps Decision 100 (b):
  -- staff default waive, the class's instructor is always due.
  v_choice := nullif(p_source ->> 'fee_choice', '');
  v_fnote  := nullif(btrim(coalesce(p_source ->> 'fee_note', '')), '');
  if v_late and v_choice is null then
    v_choice := case when coalesce((p_source ->> 'waive_fee')::boolean, true) then 'waive' else 'due' end;
  end if;
  if v_method = 'instructor' and v_choice is not null then v_choice := 'due'; end if;
  -- Refuse before any write (the override path books a drop-in first).
  if v_kind in ('free_first','free_first_override')
     and coalesce(v_set.free_first_reservation_fee_cents, 0) > 0
     and v_set.free_first_reservation_from is not null
     and (v_occ.starts_at at time zone v_tz)::date >= v_set.free_first_reservation_from
     and v_member.reservation_fee_waived_at is null
     and coalesce(v_choice, '') not in ('due', 'waive') then
    return jsonb_build_object('ok', false, 'reason', 'fee_choice_required', 'member_first', v_member.first_name);
  end if;

  if v_kind in ('free_first_override','complimentary') and not v_mgr then
    raise exception 'only owners and managers do this' using errcode = 'PT403';
  end if;

  if v_kind = 'plan' then
    v_res := book_class(p_occurrence_id, p_member_id, 'front_desk', null, null,
                        (p_source ->> 'membership_id')::uuid);
    v_label := 'a plan';

  elsif v_kind = 'free_first' then
    -- Decision 30(e): a manager may allow this one free class on a flex class.
    if coalesce((p_source ->> 'allow_free_on_flex')::boolean, false) then
      if not v_mgr then
        raise exception 'only owners and managers do this' using errcode = 'PT403';
      end if;
      perform set_config('studiior.free_on_flex', '1', true);
    end if;
    v_conv := book_first_free(p_occurrence_id, p_member_id, v_choice, v_fnote);
    if not (v_conv ->> 'ok')::boolean then
      return jsonb_build_object('ok', false, 'reason', v_conv ->> 'reason', 'member_first', v_member.first_name);
    end if;
    v_booking := (v_conv ->> 'booking_id')::uuid;
    if coalesce((p_source ->> 'allow_free_on_flex')::boolean, false) then
      insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
      values (v_occ.studio_id, auth.uid(), 'booking.free_on_flex', 'bookings', v_booking,
              jsonb_build_object('occurrence_id', v_occ.id));
    end if;
    v_label := 'a free first class';

  elsif v_kind = 'free_first_override' then
    -- Book a drop-in, then convert it (overrides the eligibility refusal).
    v_res := book_class(p_occurrence_id, p_member_id, 'front_desk', null, null, null);
    if v_res.failure_reason is not null then
      return jsonb_build_object('ok', false, 'reason', v_res.failure_reason, 'member_first', v_member.first_name);
    end if;
    if v_res.payment_source is distinct from 'drop_in' then
      return jsonb_build_object('ok', false, 'reason', 'plan_not_covering', 'member_first', v_member.first_name);
    end if;
    v_booking := v_res.booking_id;
    v_conv := convert_booking_to_free_first(v_booking, v_choice, v_fnote);
    if not (v_conv ->> 'ok')::boolean then
      return jsonb_build_object('ok', false, 'reason', v_conv ->> 'reason', 'member_first', v_member.first_name);
    end if;
    v_label := 'a free first class (override)';

  elsif v_kind = 'drop_in_paid' then
    v_res := book_class(p_occurrence_id, p_member_id, 'front_desk', null, null, null);
    if v_res.failure_reason is not null then
      return jsonb_build_object('ok', false, 'reason', v_res.failure_reason, 'member_first', v_member.first_name);
    end if;
    v_booking := v_res.booking_id;
    v_pay := record_desk_dropin_paid(v_booking, coalesce(p_source ->> 'method','cash'),
               (p_source ->> 'amount_cents')::int, nullif(p_source ->> 'reference',''));
    if not coalesce((v_pay ->> 'ok')::boolean, true) then
      return jsonb_build_object('ok', false, 'reason', v_pay ->> 'reason', 'member_first', v_member.first_name);
    end if;
    v_label := 'a drop-in, paid at the studio';

  elsif v_kind = 'drop_in_later' then
    -- Enforce the unpaid cap here, because a desk booking bypasses book_class's.
    v_cap := v_set.max_unpaid_bookings;
    select count(*) into v_unpaid from bookings b
     where b.member_id = p_member_id and b.studio_id = v_occ.studio_id
       and b.payment_source = 'drop_in' and b.status in ('booked','pending_payment')
       and not exists (select 1 from payments p where p.booking_id = b.id
                         and p.status in ('succeeded','partially_refunded'));
    if v_cap is not null and v_unpaid >= v_cap then
      return jsonb_build_object('ok', false, 'reason', 'pay_first', 'member_first', v_member.first_name);
    end if;
    v_res := book_class(p_occurrence_id, p_member_id, 'front_desk', null, null, null);
    if v_res.failure_reason is not null then
      return jsonb_build_object('ok', false, 'reason', v_res.failure_reason, 'member_first', v_member.first_name);
    end if;
    v_booking := v_res.booking_id;
    v_label := 'a drop-in, pay later';

  elsif v_kind = 'complimentary' then
    v_res := book_class(p_occurrence_id, p_member_id, 'front_desk',
                        coalesce(nullif(btrim(coalesce(p_note,'')), ''), 'staff_comp'), 'comp', null);
    if v_res.failure_reason is not null then
      return jsonb_build_object('ok', false, 'reason', v_res.failure_reason, 'member_first', v_member.first_name);
    end if;
    v_booking := v_res.booking_id;
    v_label := 'a complimentary seat';

  else
    raise exception 'unknown booking source' using errcode = 'PT400';
  end if;

  -- The plan / drop-in / comp paths return through v_res; carry its refusal.
  if v_kind in ('plan') and v_res.failure_reason is not null then
    return jsonb_build_object('ok', false, 'reason', v_res.failure_reason, 'member_first', v_member.first_name);
  end if;
  if v_kind = 'plan' then v_booking := v_res.booking_id; end if;

  -- Decision 100 amendment (b): a late add is marked attended at once. The
  -- reservation fee choice is applied inside book_first_free /
  -- convert_booking_to_free_first (Decision 103 (k)).
  if v_late and v_booking is not null then
    perform record_check_in(v_booking, v_method);
  end if;

  -- The attribution: one audit row (booking.late_add for a late add, else
  -- booking.booked_by_staff, read back by member_activity's Journey arm).
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (v_occ.studio_id, auth.uid(),
            case when v_late then 'booking.late_add' else 'booking.booked_by_staff' end,
            'members', p_member_id,
            jsonb_build_object('staff_first', v_staff_first, 'source', v_label,
                               'occurrence_id', p_occurrence_id, 'booking_id', v_booking,
                               'late', coalesce(v_late, false), 'method', v_method,
                               'note', nullif(btrim(coalesce(p_note,'')), '')));

  return jsonb_build_object('ok', true, 'booking_id', v_booking, 'source', v_label,
                            'late', coalesce(v_late, false), 'member_first', v_member.first_name);
end $function$;

revoke execute on function staff_book_member(uuid, uuid, jsonb, text) from public, anon;
grant  execute on function staff_book_member(uuid, uuid, jsonb, text) to authenticated, service_role;

-- ---- 6. sweep_free_reservation_dues: release only when the due was sent -----
create or replace function sweep_free_reservation_dues(p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record; v_asked int := 0; v_released int := 0; v_kept int := 0; v_nudged int := 0; v_last int := 0;
        v_tz text; v_s studios%rowtype; v_payload jsonb;
        v_deadline timestamptz; v_day text; v_fmt text; v_res cancel_result;
begin
  if not is_service_context() then
    raise exception 'the reservation-dues sweep runs as the backend, not as a user'
      using errcode = 'PT403';
  end if;

  for r in
    select b.id as booking_id, b.studio_id, b.member_id, o.id as occ_id, o.name as cname,
           o.starts_at, st.cancellation_cutoff_minutes, st.free_first_reservation_fee_cents,
           st.free_first_reservation_from
      from bookings b
      join class_occurrences o   on o.id = b.occurrence_id
      join studio_settings st    on st.studio_id = b.studio_id
      join members mb            on mb.id = b.member_id
     where b.status = 'booked' and b.payment_source = 'comp'
       and not coalesce(b.reservation_credit_covered, false)  -- Decision 103(h): covered bookings are paid
       and mb.reservation_fee_waived_at is null
       and not b.reservation_fee_waived
       and st.free_first_reservation_from is not null
       and coalesce(st.free_first_reservation_fee_cents, 0) > 0
       and exists (select 1 from guest_passes gp
                    where gp.guest_booking_id = b.id and gp.host_member_id is null)
       and not exists (select 1 from payments p
                        where p.booking_id = b.id and p.kind = 'reservation_fee'
                          and p.status in ('succeeded','partially_refunded'))
  loop
    select timezone into v_tz from studios where id = r.studio_id;
    v_fmt := coalesce((select time_format from studio_settings where studio_id = r.studio_id), '24h');
    -- Only classes on/after the applies-from date (studio-local).
    if (r.starts_at at time zone v_tz)::date < r.free_first_reservation_from then
      continue;
    end if;
    v_deadline := r.starts_at - make_interval(mins => coalesce(r.cancellation_cutoff_minutes, 0));
    v_day := to_char(r.starts_at at time zone v_tz, 'FMDay FMDD FMMonth');

    v_payload := jsonb_build_object(
              'class_name', r.cname, 'day', v_day,
              'time', fmt_clock(r.starts_at, v_tz, v_fmt),
              'fee', fmt_money(r.free_first_reservation_fee_cents,
                               (select currency from studios where id = r.studio_id)),
              'from_date', to_char(r.free_first_reservation_from, 'FMDD Mon'),
              'deadline', fmt_clock(v_deadline, v_tz, v_fmt) || ' on '
                          || to_char(v_deadline at time zone v_tz, 'FMDay FMDD FMMonth'),
              'pay_url', member_portal_url(r.studio_id, '/class/' || r.occ_id),
              'cancel_url', member_portal_url(r.studio_id, '/class/' || r.occ_id),
              'occurrence_id', r.occ_id);

    if p_now < v_deadline then
      -- Ask once. The cut-off (deadline) has not passed.
      if queue_notification(r.studio_id, r.member_id, 'free_reservation_due', v_payload,
            'free_reservation_due:' || r.booking_id) is not null then
        v_asked := v_asked + 1;
      end if;
      -- Decision 103 (j): the nudge 24 hours before the class and the last call
      -- 3 hours before the deadline, once each per booking.
      if p_now >= r.starts_at - interval '24 hours' then
        if queue_notification(r.studio_id, r.member_id, 'free_reservation_nudge', v_payload,
              'free_reservation_nudge:' || r.booking_id) is not null then
          v_nudged := v_nudged + 1;
        end if;
      end if;
      if p_now >= v_deadline - interval '3 hours' then
        if queue_notification(r.studio_id, r.member_id, 'free_reservation_last_call', v_payload,
              'free_reservation_last_call:' || r.booking_id) is not null then
          v_last := v_last + 1;
        end if;
      end if;
    else
      -- Decision 103 (j): release ONLY when a due email for this booking (the
      -- original or a resend) was actually SENT, and sent before the deadline.
      -- A due that failed or never went out keeps the seat; the daily check
      -- lists it.
      if free_due_sent(r.booking_id, v_deadline) then
        -- On-time path: set free_cancel_until so cancel_booking does not mark it
        -- a late cancel. The free class stays available (a cancelled comp seat
        -- remains free-first eligible, Decision 30d).
        update bookings set free_cancel_until = p_now + interval '1 hour' where id = r.booking_id;
        v_res := cancel_booking(r.booking_id);
        perform queue_notification(r.studio_id, r.member_id, 'free_reservation_released',
          jsonb_build_object('class_name', r.cname, 'day', v_day,
                             'book_url', member_portal_url(r.studio_id, '/book')),
          'free_reservation_released:' || r.booking_id);
        v_released := v_released + 1;
      elsif exists (select 1 from notifications n
                     where n.dedupe_key = 'free_reservation_due:' || r.booking_id
                        or n.dedupe_key like 'free_reservation_due:' || r.booking_id || ':%') then
        v_kept := v_kept + 1;
      end if;
    end if;
  end loop;

  return jsonb_build_object('asked', v_asked, 'released', v_released, 'kept_unsent', v_kept,
                            'nudged', v_nudged, 'last_call', v_last);
end $$;

revoke execute on function sweep_free_reservation_dues(timestamptz) from public, anon, authenticated;
grant  execute on function sweep_free_reservation_dues(timestamptz) to service_role;

-- ---- 7. set_occurrence_day_tier: clear stale latches -----------------------
create or replace function set_occurrence_day_tier(p_occurrence_id uuid, p_tier text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o class_occurrences%rowtype; st studio_settings%rowtype; s studios%rowtype;
        v_dir text; v_min int; v_cut timestamptz; v_tz text; v_fmt text; r record; v_restore boolean;
begin
  if p_tier not in ('core','flex') then
    raise exception 'tier must be core or flex' using errcode = 'PT422';
  end if;
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(o.studio_id), false) then
    raise exception 'only owners and managers change the timetable' using errcode = 'PT403';
  end if;
  if o.status <> 'scheduled' or o.committed_at is not null or now() >= o.starts_at then
    raise exception 'decided at the cut-off' using errcode = 'PT409';
  end if;
  select * into st from studio_settings where studio_id = o.studio_id;
  select * into s  from studios where id = o.studio_id;
  v_tz := s.timezone; v_fmt := coalesce(st.time_format, '24h');

  -- A flip back to the saved original direction restores the saved values.
  v_restore := o.day_tier_saved is not null and p_tier = (o.day_tier_saved ->> 'dir');
  if v_restore then
    update class_occurrences
       set flex = (o.day_tier_saved ->> 'flex')::boolean,
           minimum_bookings = nullif(o.day_tier_saved ->> 'minimum_bookings','')::int,
           guarantee_tier = nullif(o.day_tier_saved ->> 'guarantee_tier','')::guarantee_tier,
           day_tier_saved = null, updated_at = now()
     where id = p_occurrence_id;

    -- Decision 21 (e): switching to flex clears stale reached-minimum marks on an
    -- uncommitted class (the guard above refuses a committed one) and re-latches
    -- only if paid seats already meet the new minimum (paid = the 81b predicate).
    if p_tier = 'flex' then
      update class_occurrences
         set flex_reached_minimum_at = null, core_reached_minimum_at = null
       where id = p_occurrence_id;
      select minimum_bookings into v_min from class_occurrences where id = p_occurrence_id;
      if v_min is not null and (select count(*) from bookings b
           where b.occurrence_id = p_occurrence_id
             and b.status in ('booked','attended','no_show','pending_payment')
             and not (coalesce(b.payment_source = 'drop_in', false)
                      and not exists (select 1 from payments pmt
                                       where pmt.booking_id = b.id
                                         and pmt.status in ('succeeded','partially_refunded')))) >= v_min then
        update class_occurrences set flex_reached_minimum_at = now() where id = p_occurrence_id;
      end if;
    end if;
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (o.studio_id, auth.uid(), 'occurrence.day_tier_restored', 'class_occurrences', p_occurrence_id,
            jsonb_build_object('to', p_tier));
    return jsonb_build_object('ok', true, 'occurrence_id', p_occurrence_id, 'tier', p_tier, 'restored', true);
  end if;

  -- Otherwise apply the override, saving the original once.
  select case when g.tier = 'flex' then 'flex' else 'core' end into v_dir
    from occurrence_guarantee_run(p_occurrence_id) g;
  if o.day_tier_saved is null then
    update class_occurrences
       set day_tier_saved = jsonb_build_object('dir', v_dir, 'flex', o.flex,
             'minimum_bookings', o.minimum_bookings, 'guarantee_tier', o.guarantee_tier)
     where id = p_occurrence_id;
  end if;

  if p_tier = 'flex' then
    v_min := coalesce(st.flex_min_bookings, 2);
    update class_occurrences
       set flex = true, minimum_bookings = v_min, guarantee_tier = null, updated_at = now()
     where id = p_occurrence_id;

    -- Decision 21 (e): switching to flex clears stale reached-minimum marks on an
    -- uncommitted class (the guard above refuses a committed one) and re-latches
    -- only if paid seats already meet the new minimum (paid = the 81b predicate).
    if p_tier = 'flex' then
      update class_occurrences
         set flex_reached_minimum_at = null, core_reached_minimum_at = null
       where id = p_occurrence_id;
      select minimum_bookings into v_min from class_occurrences where id = p_occurrence_id;
      if v_min is not null and (select count(*) from bookings b
           where b.occurrence_id = p_occurrence_id
             and b.status in ('booked','attended','no_show','pending_payment')
             and not (coalesce(b.payment_source = 'drop_in', false)
                      and not exists (select 1 from payments pmt
                                       where pmt.booking_id = b.id
                                         and pmt.status in ('succeeded','partially_refunded')))) >= v_min then
        update class_occurrences set flex_reached_minimum_at = now() where id = p_occurrence_id;
      end if;
    end if;
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (o.studio_id, auth.uid(), 'occurrence.day_tier_flex', 'class_occurrences', p_occurrence_id,
            jsonb_build_object('minimum_bookings', v_min));
    -- Tell members already booked that it now runs only if it reaches the minimum.
    select cutoff_at into v_cut from occurrence_guarantee_run(p_occurrence_id);
    for r in select b.member_id from bookings b
               where b.occurrence_id = p_occurrence_id and b.status in ('booked','pending_payment') loop
      perform queue_notification(o.studio_id, r.member_id, 'day_tier_flex',
        jsonb_build_object('class_name', coalesce(o.name, (select name from class_types where id = o.class_type_id)),
          'when', to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMonth') || ' at ' || fmt_clock(o.starts_at, v_tz, v_fmt),
          'min', v_min::text,
          'cutoff', case when v_cut is not null then fmt_clock(v_cut, v_tz, v_fmt) || ' on ' || to_char(v_cut at time zone v_tz, 'FMDay FMDD FMMonth') else 'the cut-off' end,
          'manage_link', member_portal_url(o.studio_id, '/class/' || o.id),
          'book_url', member_portal_url(o.studio_id, '/book')),
        'day_flex:' || p_occurrence_id::text || ':' || r.member_id::text);
    end loop;
  else
    -- Core today on a flex class: runs regardless of bookings (the always path).
    update class_occurrences
       set guarantee_tier = 'always'::guarantee_tier, updated_at = now()
     where id = p_occurrence_id;
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (o.studio_id, auth.uid(), 'occurrence.day_tier_core', 'class_occurrences', p_occurrence_id,
            jsonb_build_object('runs_regardless', true));
  end if;
  return jsonb_build_object('ok', true, 'occurrence_id', p_occurrence_id, 'tier', p_tier, 'restored', false);
end $$;

revoke execute on function set_occurrence_day_tier(uuid, text) from public, anon;
grant  execute on function set_occurrence_day_tier(uuid, text) to authenticated, service_role;

-- ---- 8. render_email: message paragraphs and three tokens ------------------
CREATE OR REPLACE FUNCTION public.render_email(p_studio_id uuid, p_template_key text, p_recipient_type text, p_subject text, p_text text, p_html text, p_payload jsonb, p_first_name text DEFAULT NULL::text, p_recipient_role text DEFAULT NULL::text)
 RETURNS TABLE(subject text, text_body text, html_body text, stripped text[])
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s studios%rowtype;
  v_is_staff boolean; v_sub text; v_txt text; v_html text; k text; rule text; v_on text;
  v_addr text; v_link text; v_contact text; v_contact_html text; v_ig text;
  v_always boolean; v_foot_txt text; v_foot_html text;
  v_logo text; v_fmt text; v_occ_id uuid; v_class_line text; v_class_when text;
  v_tok text; v_stripped text[] := '{}';
  v_rows jsonb; v_rt_html text; v_rt_txt text; v_msg text;
begin
  select * into s from studios where id = p_studio_id;
  select coalesce(time_format, '24h') into v_fmt from studio_settings where studio_id = p_studio_id;
  v_fmt := coalesce(v_fmt, '24h');
  v_is_staff := p_recipient_type = 'staff';
  v_sub := p_subject; v_txt := p_text; v_html := p_html;

  -- Decision 89 (b): a studio message keeps its paragraphs. {message_html} is
  -- rebuilt from the plain message (a blank line is a paragraph, a single break
  -- a <br>, Windows line endings normalised); {message} keeps its breaks.
  if p_payload ? 'message' then
    v_msg := regexp_replace(replace(replace(p_payload ->> 'message', E'\r\n', E'\n'), E'\r', E'\n'),
                            E'\n{3,}', E'\n\n', 'g');
    v_html := replace(v_html, '{message_html}', message_paragraphs_html(p_payload ->> 'message'));
    v_txt  := replace(v_txt,  '{message}', v_msg);
  end if;

  -- Decision 80 note: {roster_table}, from the payload's rows or, for the month
  -- roster emails, from the instructor's published classes that month.
  if coalesce(v_html, '') like '%{roster_table}%' or coalesce(v_txt, '') like '%{roster_table}%' then
    if p_payload ? 'roster_rows' then
      v_rows := p_payload -> 'roster_rows';
    elsif p_payload ? 'instructor_id' and p_payload ? 'month_ym' then
      select coalesce(jsonb_agg(jsonb_build_object(
               'day', to_char(o.starts_at at time zone s.timezone, 'FMDy FMDD FMMon'),
               'time', fmt_clock(o.starts_at, s.timezone, v_fmt),
               'class', coalesce(o.name, ct.name, 'Class')) order by o.starts_at), '[]'::jsonb)
        into v_rows
        from class_occurrences o
        left join class_types ct on ct.id = o.class_type_id
       where o.studio_id = p_studio_id
         and o.instructor_id = (p_payload ->> 'instructor_id')::uuid
         and o.status = 'scheduled'
         and to_char(o.starts_at at time zone s.timezone, 'YYYY-MM') = p_payload ->> 'month_ym';
    end if;
    if v_rows is not null then
      select rt.html, rt.txt into v_rt_html, v_rt_txt from roster_table_render(v_rows) rt;
      v_html := replace(v_html, '{roster_table}', v_rt_html);
      v_txt  := replace(v_txt,  '{roster_table}', v_rt_txt);
      v_sub  := replace(v_sub,  '{roster_table}', '');
    end if;
  end if;


  for k in select jsonb_object_keys(p_payload) loop
    v_sub  := replace(v_sub,  '{' || k || '}', coalesce(p_payload ->> k, ''));
    v_txt  := replace(v_txt,  '{' || k || '}', coalesce(p_payload ->> k, ''));
    v_html := replace(v_html, '{' || k || '}', coalesce(p_payload ->> k, ''));
  end loop;
  -- Decision 80 note: {flex_min} and {flex_cutoff} in every email.
  v_sub  := replace(replace(v_sub,  '{flex_min}', coalesce((select flex_min_bookings::text from studio_settings where studio_id = p_studio_id), '2')), '{flex_cutoff}', coalesce(flex_cutoff_words(p_studio_id), ''));
  v_txt  := replace(replace(v_txt,  '{flex_min}', coalesce((select flex_min_bookings::text from studio_settings where studio_id = p_studio_id), '2')), '{flex_cutoff}', coalesce(flex_cutoff_words(p_studio_id), ''));
  v_html := replace(replace(v_html, '{flex_min}', coalesce((select flex_min_bookings::text from studio_settings where studio_id = p_studio_id), '2')), '{flex_cutoff}', coalesce(flex_cutoff_words(p_studio_id), ''));
  for k in select unnest(array['first_name','studio_name']) loop
    v_sub  := replace(v_sub,  '{' || k || '}',
                      case k when 'first_name'
                             then coalesce(p_first_name, 'there')
                             else s.name end);
    v_txt  := replace(v_txt,  '{' || k || '}',
                      case k when 'first_name'
                             then coalesce(p_first_name, 'there')
                             else s.name end);
    v_html := replace(v_html, '{' || k || '}',
                      case k when 'first_name'
                             then coalesce(p_first_name, 'there')
                             else s.name end);
  end loop;

  -- Decision 80a fix: the class card's ONE detail line, built from the occurrence
  -- so every class email reads the same — Day · time · room · with {instructor},
  -- times via fmt_clock in the studio format, missing parts dropped cleanly.
  v_occ_id := nullif(p_payload ->> 'occurrence_id', '')::uuid;
  if v_occ_id is not null then
    select concat_ws(' · ',
             nullif(to_char(o.starts_at at time zone s.timezone, 'FMDy FMDD FMMon'), ''),
             fmt_clock(o.starts_at, s.timezone, v_fmt),
             nullif(rm.name, ''),
             nullif('with ' || split_part(coalesce(i.display_name, ''), ' ', 1), 'with '))
      into v_class_line
      from class_occurrences o
      left join rooms rm on rm.id = o.room_id
      left join instructors i on i.id = o.instructor_id
     where o.id = v_occ_id;
  end if;
  v_sub  := replace(v_sub,  '{class_line}', coalesce(v_class_line, ''));
  v_txt  := replace(v_txt,  '{class_line}', coalesce(v_class_line, ''));
  v_html := replace(v_html, '{class_line}', coalesce(v_class_line, ''));

  -- Decision 101: {class_when} — the instructor-facing class line, "Class on Day
  -- at time" plus the room ONLY when the studio has more than one. Resolved from
  -- occurrence_id, so every instructor template that carries it reads the same,
  -- and the room rule lives in one place. Known-optional (strip-exempt below).
  if v_occ_id is not null then
    select coalesce(o.name, ct.name, 'your class') || ' on '
           || to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth')
           || ' at ' || fmt_clock(o.starts_at, s.timezone, v_fmt)
           || case when (select count(*) from rooms where studio_id = s.id and status = 'active') > 1
                     and nullif(rm.name, '') is not null then ' in ' || rm.name else '' end
      into v_class_when
      from class_occurrences o
      left join class_types ct on ct.id = o.class_type_id
      left join rooms rm on rm.id = o.room_id
     where o.id = v_occ_id;
  end if;
  v_sub  := replace(v_sub,  '{class_when}', coalesce(v_class_when, ''));
  v_txt  := replace(v_txt,  '{class_when}', coalesce(v_class_when, ''));
  v_html := replace(v_html, '{class_when}', coalesce(v_class_when, ''));

  -- Decision 101: {schedule_link} — the instructor's own schedule. Filled for a
  -- staff recipient when the payload did not already supply it (the digest and a
  -- test send supply their own). Known-optional (strip-exempt below).
  if v_is_staff then
    v_sub  := replace(v_sub,  '{schedule_link}', instructor_portal_url(s.id, '/instructor/schedule'));
    v_txt  := replace(v_txt,  '{schedule_link}', instructor_portal_url(s.id, '/instructor/schedule'));
    v_html := replace(v_html, '{schedule_link}', instructor_portal_url(s.id, '/instructor/schedule'));
  end if;

  -- Accent (80a): a static template button carries {accent}/{accent_on}.
  rule := coalesce(s.accent_color, '#78716C');
  v_on := email_on_accent(rule);
  v_html := replace(replace(v_html, '{accent_on}', v_on), '{accent}', rule);
  v_txt  := replace(replace(v_txt,  '{accent_on}', v_on), '{accent}', rule);

  -- STRIP any residual {token}: a known-optional one silently, anything else to
  -- empty AND recorded in `stripped` (deliver_notification logs it). No token
  -- ever reaches a member.
  for v_tok in
    select distinct (regexp_matches(coalesce(v_sub,'') || E'\n' || coalesce(v_txt,'') || E'\n' || coalesce(v_html,''),
                                    '\{([a-z_][a-z0-9_]*)\}', 'g'))[1]
  loop
    if not (v_tok = any (array['where_line','free_first_line','free_first_html',
                               'next_three_line','next_three_html','system_text','system_html','class_line',
                               'class_when','schedule_link','replaces_line','replaces_html','roster_table'])) then
      v_stripped := array_append(v_stripped, v_tok);
    end if;
    v_sub  := replace(v_sub,  '{' || v_tok || '}', '');
    v_txt  := replace(v_txt,  '{' || v_tok || '}', '');
    v_html := replace(v_html, '{' || v_tok || '}', '');
  end loop;

  select nullif(concat_ws(', ',
           nullif(l.address ->> 'line1', ''), nullif(l.address ->> 'line2', ''),
           nullif(l.address ->> 'city', ''), nullif(l.address ->> 'postal_code', ''),
           nullif(l.address ->> 'country', '')), '')
    into v_addr
    from locations l
   where l.studio_id = s.id and l.status = 'active'
   order by l.is_primary desc, l.created_at limit 1;

  if v_is_staff then
    v_link := coalesce(nullif(notification_setting('staff_app_origin'), ''),
                       'https://app.studiior.com') || '/billing';
  else
  v_link := 'https://' || s.slug || '.'
            || coalesce(notification_setting('member_app_domain'), 'studiior.app') || '/settings';
  end if;

  v_ig := nullif(s.instagram_handle, '');
  v_contact := nullif(concat_ws(' · ', s.contact_email, s.contact_phone,
                 case when v_ig is not null then '@' || v_ig else null end), '');
  v_contact_html := nullif(concat_ws(' · ', s.contact_email, s.contact_phone,
                 case when v_ig is not null
                      then '<a href="https://instagram.com/' || v_ig || '" style="color:#78716C">@' || v_ig || '</a>'
                      else null end), '');

  v_always := p_template_key in ('class_cancelled', 'instructor_substituted',
                                 'guest_invite', 'guest_host_cancelled',
                                 'guest_waiver_reminder', 'guest_waiver_host_nudge',
                                 'member_invite', 'payment_failed', 'staff_message',
                                 'platform_billing_warning', 'class_moved',
                                 'shift_application_received', 'shift_approved',
                                 'shift_declined', 'shift_withdrawn');

  v_foot_txt := concat_ws(E'\n',
    v_contact, v_addr,
    case when v_is_staff then case when p_recipient_role = 'owner' then 'Your billing: ' || v_link end
         when p_template_key in ('member_invite', 'instructor_invite', 'guest_invite', 'guest_waiver_reminder')
         then 'You are getting this because ' || s.name || ' set up your account.'
         when v_always
         then 'We always send this one. It is about your booking or your membership. '
              || 'Choose which other emails you get: ' || v_link
         else 'Choose which emails you get: ' || v_link end);

  v_foot_html := concat_ws('<br>',
    v_contact_html, v_addr,
    case when v_is_staff then case when p_recipient_role = 'owner' then '<a href="' || v_link || '" style="color:#78716C">Your billing</a>' end
         when p_template_key in ('member_invite', 'instructor_invite', 'guest_invite', 'guest_waiver_reminder')
         then 'You are getting this because ' || s.name || ' set up your account.'
         when v_always
         then 'We always send this one. It is about your booking or your membership. '
              || '<a href="' || v_link || '" style="color:#78716C">Choose which other emails you get</a>'
         else '<a href="' || v_link || '" style="color:#78716C">Choose which emails you get</a>' end);

  v_logo := case when s.logo_url is not null
    then '<img src="' || s.logo_url || '" alt="' || replace(s.name, '"', '')
         || '" width="40" height="40" style="display:block;border:0;border-radius:6px" />'
    else '<div style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;'
         || 'font-weight:600;font-size:18px;color:#14170E">' || s.name || '</div>' end;

  -- The FLUID frame. The content table ("sd-card") is width 100% / max-width 600px
  -- so it reflows on a phone; the <style> media query shrinks the padding and body
  -- text under 480px and caps images; the MSO ghost table stays 600 for Outlook.
  return query select v_sub, v_txt || E'\n\n--\n' || v_foot_txt,
    '<style>'
      || '.sd-body img{max-width:100%;height:auto}'
      || '@media only screen and (max-width:480px){'
      || '.sd-card{width:100%!important;border-radius:0!important}'
      || '.sd-pad{padding-left:16px!important;padding-right:16px!important}'
      || '.sd-body{font-size:14px!important;line-height:22px!important}'
      || '}'
      || '</style>'
      || '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" '
      || 'style="background:#F5F5F4;margin:0;padding:0;width:100%"><tr>'
      || '<td align="center" style="padding:24px 12px">'
      || '<!--[if mso]><table role="presentation" width="600" cellspacing="0" cellpadding="0" border="0"><tr><td><![endif]-->'
      || '<table role="presentation" width="100%" class="sd-card" cellspacing="0" cellpadding="0" border="0" '
      || 'style="width:100%;max-width:600px;background:#FFFFFF;border-radius:12px">'
      || '<tr><td class="sd-pad" style="padding:28px 28px 0 28px">'
      || v_logo
      || '<div style="height:3px;width:44px;background:' || rule || ';margin:16px 0 4px"></div>'
      || '</td></tr>'
      || '<tr><td class="sd-pad sd-body" style="padding:12px 28px 8px 28px;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;'
      || 'font-size:15px;line-height:22px;color:#14170E">'
      || v_html
      || '</td></tr>'
      || '<tr><td class="sd-pad" style="padding:16px 28px 28px 28px">'
      || '<div style="border-top:1px solid #E7E5E4;padding-top:14px;'
      || 'font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;'
      || 'font-size:13px;line-height:18px;color:#78716C">' || v_foot_html || '</div>'
      || '</td></tr></table>'
      || '<!--[if mso]></td></tr></table><![endif]-->'
      || '</td></tr></table>',
    v_stripped;
end $function$;


-- ---- 9. template_sample_context: Step 11 sample tokens ---------------------
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
  v_fee text;
begin
  select * into s from studios where id = p_studio_id;
  select * into st from studio_settings where studio_id = p_studio_id;
  v_tz := s.timezone; v_fmt := coalesce(st.time_format, '24h');
  v_fee := fmt_money(coalesce(nullif(st.free_first_reservation_fee_cents, 0), 15000), s.currency);

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
  || jsonb_build_object(
    'staff_first_name', p_first_name,
    'member_name', coalesce(nullif(p_first_name, ''), 'A member'),
    'message', 'Hi, could I move my Saturday class to Sunday?',
    'message_html', 'Hi, could I move my Saturday class to Sunday?',
    'messages_url', member_portal_url(p_studio_id, '/messages'),
    'reply_url', coalesce(nullif(notification_setting('staff_app_origin'), ''), 'https://app.studiior.com') || '/messages')
  || jsonb_build_object(
    'old_class_name', coalesce(o.cname, 'a class'),
    'bookings_url', member_portal_url(p_studio_id, '/'))
  || jsonb_build_object(
    'class_name', coalesce(o.cname, 'a class'),
    'day', to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMonth'),
    'n_more', 2,
    'cutoff_time', coalesce(v_when, 'the cut-off'),
    'class_list_core', '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:12px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-size:16px;font-weight:600;color:#14170E">' || coalesce(o.cname, 'a class') || '</div><div style="font-size:14px;color:#57534E;margin-top:4px">' || coalesce(v_when, 'soon') || '</div><div style="font-size:13px;color:#78716C;margin-top:2px">3 in already · 4 spots left</div><table role="presentation" style="margin-top:12px"><tr><td style="border-radius:6px;background:{accent}"><a href="#" style="display:inline-block;padding:10px 20px;color:{accent_on};text-decoration:none;font-weight:600;border-radius:6px">Move me to this class</a></td></tr></table></td></tr></table>',
    'class_list_core_text', '- ' || coalesce(o.cname, 'a class') || ' · ' || coalesce(v_when, 'soon') || ' (3 in already, 4 spots left)')
  || jsonb_build_object(
    'n_running', 2, 'n_cancelled', 1,
    'pay_line', 'You''re paid on who''s checked in.',
    'going_ahead', '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:12px 0;border-collapse:collapse"><tr><td colspan="3" style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;color:#14170E;padding:0 0 6px 0">Running</td></tr><tr><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Time</th><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Class</th><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Booked</th></tr><tr><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">' || fmt_clock(((now() at time zone v_tz)::date + time '07:00') at time zone v_tz, v_tz, v_fmt) || '</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">Reformer Flow</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">4 of 6</td></tr><tr><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">' || fmt_clock(((now() at time zone v_tz)::date + time '18:00') at time zone v_tz, v_tz, v_fmt) || '</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">Barre</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">5 of 8</td></tr></table>',
    'going_ahead_text', 'Running' || E'\n  ' || fmt_clock(((now() at time zone v_tz)::date + time '07:00') at time zone v_tz, v_tz, v_fmt) || '  Reformer Flow  4 of 6' || E'\n  ' || fmt_clock(((now() at time zone v_tz)::date + time '18:00') at time zone v_tz, v_tz, v_fmt) || '  Barre  5 of 8',
    'cancelled', '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:12px 0;border-collapse:collapse"><tr><td colspan="3" style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;color:#14170E;padding:0 0 6px 0">Cancelled, not enough bookings</td></tr><tr><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Time</th><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Class</th><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Booked</th></tr><tr><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">' || fmt_clock(((now() at time zone v_tz)::date + time '09:00') at time zone v_tz, v_tz, v_fmt) || '</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">Mat Pilates</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">1 of 3 needed</td></tr></table>',
    'cancelled_text', 'Cancelled, not enough bookings' || E'\n  ' || fmt_clock(((now() at time zone v_tz)::date + time '09:00') at time zone v_tz, v_tz, v_fmt) || '  Mat Pilates  1 of 3 needed')
  -- Decision 103: reservation tokens.
  || jsonb_build_object(
    'fee', v_fee,
    'from_date', to_char(now() at time zone v_tz, 'FMDD Mon'),
    'deadline', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD Mon') else 'the day before' end,
    'plans_url', member_portal_url(p_studio_id, '/account/plan'),
    'pay_url', member_portal_url(p_studio_id, '/class/' || coalesce(o.id::text, '')),
    'cancel_url', member_portal_url(p_studio_id, '/class/' || coalesce(o.id::text, '')),
    'reservation_line', '',
    'reservation_html', '')
  -- Decision 103a: closure sample tokens so the Templates preview fills them.
  || jsonb_build_object(
    'from', to_char(now() at time zone v_tz, 'FMDy FMDD FMMon'),
    'to', to_char((now() + interval '2 days') at time zone v_tz, 'FMDy FMDD FMMon'),
    'resume_date', to_char((now() + interval '7 days') at time zone v_tz, 'FMDay FMDD FMMonth YYYY'),
    'notice', 'We are closed for renovations.',
    'class_list_html', closure_card_html('Reformer Flow', v_clist),
    'schedule_url', instructor_portal_url(p_studio_id, '/instructor/schedule'))
  -- Housekeeping: refund + credited-back tokens so those previews render clean.
  || jsonb_build_object(
    'method', 'GCash', 'reference', 'rfd-sample-0001',
    'plan_link', member_portal_url(p_studio_id, '/account/plan'), 'button', '')
  -- Step 11: the roster table rows and a two-paragraph sample message.
  || jsonb_build_object(
    'roster_rows', jsonb_build_array(
      jsonb_build_object('day', 'Mon 7 Dec', 'time', fmt_clock(timestamptz '2026-12-07 07:00+00', 'UTC', v_fmt), 'class', 'Reformer Flow'),
      jsonb_build_object('day', 'Wed 9 Dec', 'time', fmt_clock(timestamptz '2026-12-09 18:00+00', 'UTC', v_fmt), 'class', 'Reformer Sculpt')),
    'message', E'Hi! Just a reminder about tomorrow.\n\nBring grip socks and water.\nSee you there!',
    'message_html', 'Hi! Just a reminder about tomorrow.<br><br>Bring grip socks and water.<br>See you there!');
end $function$;


-- ---- 10. daily_money_check: items 11, 12 and 13 ----------------------------
create or replace function daily_money_check(p_studio_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_tz text; v_items jsonb := '[]'::jsonb; v_html text := ''; v_text text := '';
  r record; v_n int;
begin
  if not is_service_context() then
    raise exception 'the daily check runs as the backend' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;

  for r in
    -- 1. reservation fee paid, no seat, no credit
    select mname(b.member_id) || ': paid a reservation fee for ' || cname(b.occurrence_id)
           || ' but has no seat and no credit' as line
      from payments p
      join bookings b on b.id = p.booking_id
     where p.studio_id = p_studio_id and p.kind = 'reservation_fee'
       and p.status in ('succeeded','partially_refunded')
       and b.status in ('cancelled','late_cancelled')
       and not exists (select 1 from member_credits mc
                        where mc.booking_id = b.id and mc.reason = 'reservation_credit' and mc.voided_at is null)
    union all
    -- 2. a hold older than its window
    select mname(b.member_id) || ': the hold on ' || cname(b.occurrence_id)
           || ' expired ' || ago(b.hold_until) || ' and is still open'
      from bookings b
     where b.studio_id = p_studio_id and b.hold_until is not null and b.hold_until < now()
       and b.status in ('booked','pending_payment')
    union all
    -- 3. a succeeded payment attached to nothing
    select mname(p.member_id) || ': a succeeded payment of ' || money_txt(p.amount_cents, p.currency)
           || ' is attached to nothing'
      from payments p
     where p.studio_id = p_studio_id and p.status = 'succeeded'
       and p.membership_id is null and p.booking_id is null
       and p.product_order_id is null and p.group_purchase_id is null
    union all
    -- 4. a member with an active plan still marked lead
    select mname(m.id) || ': has an active plan but is still marked lead'
      from members m
     where m.studio_id = p_studio_id and m.status = 'lead' and m.deleted_at is null
       and exists (select 1 from memberships ms where ms.member_id = m.id and ms.status = 'active')
    union all
    -- 5. a live booking in a cancelled or ended class
    select mname(b.member_id) || ': booked in ' || cname(b.occurrence_id)
           || case when o.status = 'cancelled' then ' which was cancelled' else ' which has already ended' end
      from bookings b join class_occurrences o on o.id = b.occurrence_id
     where b.studio_id = p_studio_id and b.status in ('booked','pending_payment')
       and (o.status = 'cancelled' or (o.status = 'scheduled' and o.ends_at < now()))
    union all
    -- 6. a member double-booked in one class
    select mname(x.member_id) || ': booked twice in ' || cname(x.occurrence_id)
      from (select member_id, occurrence_id from bookings
             where studio_id = p_studio_id and status in ('booked','attended','pending_payment')
             group by member_id, occurrence_id having count(*) > 1) x
    union all
    -- 7. a notification unsent for more than an hour
    select (select count(*) from notifications n
             where n.studio_id = p_studio_id and n.status = 'scheduled'
               and n.scheduled_for < now() - interval '1 hour')::text
           || ' emails have been waiting over an hour to send'
     where exists (select 1 from notifications n
                    where n.studio_id = p_studio_id and n.status = 'scheduled'
                      and n.scheduled_for < now() - interval '1 hour')
    union all
    -- 8. an attended booking with no signed waiver
    select mname(b.member_id) || ': attended ' || cname(b.occurrence_id) || ' without signing the waiver'
      from bookings b join members m on m.id = b.member_id
     where b.studio_id = p_studio_id and b.status = 'attended'
       and coalesce((select require_waiver from studio_settings where studio_id = p_studio_id), false)
       and exists (select 1 from waiver_versions wv where wv.studio_id = p_studio_id)
       and m.waiver_signed_at is null
    union all
    -- 9. emails that failed in the last day, with the reason
    select count(*)::text || ' emails failed: ' || coalesce(nullif(btrim(fx.reason), ''), 'no reason given')
      from (select coalesce(split_part(error, ':', 1), 'unknown') as reason
              from notifications
             where studio_id = p_studio_id and status = 'failed'
               and coalesce(failed_at, created_at) > now() - interval '1 day') fx
     group by fx.reason
    union all
    -- 10. Decision 103(h): a credit-covered booking the owing shape would dun
    -- (the covered marker is missing). The belt against a covered booking being
    -- reported as due; member_reservation_dues excludes covered bookings.
    select mname(b.member_id) || ': covered booking ' || cname(b.occurrence_id)
           || ' is reported as owing the fee'
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
      join studio_settings st on st.studio_id = b.studio_id
     where b.studio_id = p_studio_id
       and not coalesce(b.reservation_credit_covered, false)
       and exists (select 1 from audit_logs a where a.action = 'reservation.credit_used'
                    and a.entity_table = 'bookings' and a.entity_id = b.id)
       and b.status = 'booked' and b.payment_source = 'comp'
       and coalesce(st.free_first_reservation_fee_cents, 0) > 0
       and st.free_first_reservation_from is not null
       and o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)) > now()
       and not exists (select 1 from payments p where p.booking_id = b.id
                        and p.kind = 'reservation_fee' and p.status in ('succeeded','partially_refunded'))
    union all
    -- 11. Decision 108 (a): a flex class before its cut-off carrying a
    -- reached-minimum mark with fewer paid seats than its minimum.
    select cname(o.id) || ' is marked as reached its minimum with '
           || pc.paid || ' paid of ' || o.minimum_bookings
      from class_occurrences o
      cross join lateral (select count(*)::int as paid from bookings b
             where b.occurrence_id = o.id
               and b.status in ('booked','attended','no_show','pending_payment')
               and not (coalesce(b.payment_source = 'drop_in', false)
                        and not exists (select 1 from payments pmt where pmt.booking_id = b.id
                                         and pmt.status in ('succeeded','partially_refunded')))) pc
     where o.studio_id = p_studio_id and o.status = 'scheduled'
       and coalesce(o.flex, false) and o.committed_at is null
       and (o.flex_reached_minimum_at is not null or o.core_reached_minimum_at is not null)
       and o.minimum_bookings is not null and pc.paid < o.minimum_bookings
       and now() < coalesce((select g.cutoff_at from occurrence_guarantee_run(o.id) g), o.starts_at)
    union all
    -- 12. Decision 108 (a): a pay line whose amount does not match its own
    -- recorded basis (group classes that ran, and not-running classes).
    select coalesce((select display_name from instructors where id = ipr.instructor_id), 'An instructor')
           || ': the pay line for ' || coalesce(cname(ipr.occurrence_id), 'a class') || ' is '
           || money_txt(ipr.amount_cents, ipr.currency) || ' but its basis gives '
           || money_txt(x.expected, ipr.currency)
      from instructor_pay_records ipr
      cross join lateral (select case
          when ipr.basis ? 'per_head_cents' and ipr.basis ? 'booked_paid' then
            (ipr.basis ->> 'base_cents')::int
            + greatest(0, (ipr.basis ->> 'booked_paid')::int - (ipr.basis ->> 'per_head_threshold')::int)
              * (ipr.basis ->> 'per_head_cents')::int
            + coalesce((ipr.basis ->> 'full_house_bonus_cents')::int, 0)
          when ipr.basis ->> 'outcome' = 'not_running' and ipr.basis ->> 'tier' = 'flex' then
            coalesce((ipr.basis ->> 'unmet_pay_cents')::int, 0) + coalesce((ipr.basis ->> 'standby_cents')::int, 0)
          when ipr.basis ->> 'outcome' = 'not_running' and ipr.basis ->> 'tier' = 'core' then
            case when ipr.basis ->> 'holding_model' = 'flat' then (ipr.basis ->> 'holding_flat_cents')::int
                 else ((ipr.basis ->> 'base_cents')::int * coalesce((ipr.basis ->> 'holding_pct')::int, 0)) / 100 end
          end as expected) x
     where ipr.studio_id = p_studio_id and ipr.type = 'class'
       and x.expected is not null and x.expected <> ipr.amount_cents
    union all
    -- 13. Decision 103 (j): a free first class seat past its deadline that was
    -- kept because its due email was never sent.
    select mname(b.member_id) || ': ' || cname(b.occurrence_id)
           || ' was kept because the pay-to-keep email never reached them'
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
      join studio_settings st on st.studio_id = b.studio_id
      join members mb on mb.id = b.member_id
     where b.studio_id = p_studio_id and b.status = 'booked' and b.payment_source = 'comp'
       and o.starts_at > now() - interval '1 day'
       and not coalesce(b.reservation_credit_covered, false)
       and mb.reservation_fee_waived_at is null and not coalesce(b.reservation_fee_waived, false)
       and coalesce(st.free_first_reservation_fee_cents, 0) > 0
       and st.free_first_reservation_from is not null
       and o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)) <= now()
       and exists (select 1 from guest_passes gp where gp.guest_booking_id = b.id and gp.host_member_id is null)
       and not exists (select 1 from payments p where p.booking_id = b.id
                        and p.kind = 'reservation_fee' and p.status in ('succeeded','partially_refunded'))
       and exists (select 1 from notifications n
                    where n.dedupe_key = 'free_reservation_due:' || b.id
                       or n.dedupe_key like 'free_reservation_due:' || b.id || ':%')
       and not free_due_sent(b.id, o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)))
  loop
    v_items := v_items || to_jsonb(r.line);
    v_html  := v_html  || '<li>' || replace(replace(r.line, '&', '&amp;'), '<', '&lt;') || '</li>';
    v_text  := v_text  || '- ' || r.line || E'\n';
  end loop;

  v_n := jsonb_array_length(v_items);
  return jsonb_build_object(
    'n', v_n,
    'all_clear', v_n = 0,
    'items', v_items,
    'items_html', case when v_n = 0 then '<p>All clear.</p>' else '<ul>' || v_html || '</ul>' end,
    'items_text', case when v_n = 0 then 'All clear.' else v_text end,
    'count_label', case when v_n = 0 then 'all clear'
                        else v_n::text || ' item' || case when v_n = 1 then '' else 's' end end);
end $function$;

revoke execute on function daily_money_check(uuid) from public, anon, authenticated;
grant  execute on function daily_money_check(uuid) to service_role;

-- ---- 11. member_reservation_fees: the unpaid seat states (103 (i)) ---------
create or replace function member_reservation_fees(p_member_id uuid)
returns table(payment_id uuid, paid_at timestamptz, fee_cents int, currency text,
              class_name text, occurrence_start timestamptz, state text, state_at timestamptz,
              method text, reference text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare v_studio uuid;
begin
  select studio_id into v_studio from members where id = p_member_id;
  if v_studio is null then raise exception 'no such member' using errcode = 'PT404'; end if;
  if not (coalesce(is_desk_up(v_studio), false) or is_service_context()
          or exists (select 1 from members m where m.id = p_member_id and m.user_id = auth.uid())) then
    raise exception 'that is not your statement' using errcode = 'PT403';
  end if;

  return query
  -- Paid fees (a reservation_fee payment).
  select p.id, p.paid_at, p.amount_cents, p.currency::text,
         coalesce(o.name, 'a class') as class_name, o.starts_at,
         case
           when p.refunded_at is not null or p.status = 'refunded'
                or coalesce(p.refunded_cents, 0) >= p.amount_cents then 'refunded'
           when mc.used_cents >= mc.amount_cents then 'used'
           when mc.id is not null then 'credited'
           when b.status in ('no_show', 'late_cancelled') then 'kept'
           else 'held'
         end as state,
         coalesce(mc.created_at, b.cancelled_at, p.refunded_at) as state_at,
         rf.method, coalesce(rf.xendit_refund_id, rf.reference)
    from payments p
    left join bookings b on b.id = p.booking_id
    left join class_occurrences o on o.id = b.occurrence_id
    left join lateral (
      select id, amount_cents, used_cents, created_at
        from member_credits mc2
       where mc2.payment_id = p.id and mc2.voided_at is null
         and mc2.reason in ('reservation_credit', 'reservation_lost_seat')
       order by created_at limit 1) mc on true
    left join lateral (
      select method, reference, xendit_refund_id
        from payment_refunds pr
       where pr.payment_id = p.id and pr.status = 'succeeded'
       order by settled_at desc nulls last, created_at desc limit 1) rf on true
   where p.member_id = p_member_id and p.kind = 'reservation_fee'
     and coalesce(p.method, '') <> 'reservation_credit'

  union all
  -- Decision 103(h): a credit-covered reservation (no payment). State follows the
  -- booking it covers now: covering (booked), used (attended), returned (on-time
  -- cancel, credit back), kept (late cancel / no-show, credit kept).
  select null::uuid, b.booked_at,
         coalesce((a.after ->> 'fee_cents')::int,
                  (select free_first_reservation_fee_cents from studio_settings where studio_id = b.studio_id)),
         (select currency from studios where id = b.studio_id)::text,
         coalesce(o.name, 'a class'), o.starts_at,
         case
           when b.status = 'attended' then 'used'
           when b.status = 'cancelled' then 'returned'
           when b.status in ('no_show', 'late_cancelled') then 'kept'
           else 'covering'
         end,
         coalesce(b.cancelled_at, b.booked_at),
         null::text, null::text
    from bookings b
    left join class_occurrences o on o.id = b.occurrence_id
    left join lateral (
      select after from audit_logs a2
       where a2.action = 'reservation.credit_used' and a2.entity_table = 'bookings'
         and a2.entity_id = b.id order by a2.created_at desc limit 1) a on true
   where b.member_id = p_member_id and coalesce(b.reservation_credit_covered, false)

  union all
  -- Decision 103 (i): an upcoming free first class seat that has not paid and
  -- is not covered, in the same words as the roster chip: waived, due (the
  -- pay-to-keep email was sent) or not_asked. state_at is the deadline.
  select null::uuid, b.booked_at,
         (x.j ->> 'fee_cents')::int, x.j ->> 'currency',
         coalesce(o.name, 'a class'), o.starts_at,
         x.j ->> 'state', (x.j ->> 'deadline_at')::timestamptz,
         null::text, null::text
    from bookings b
    join class_occurrences o on o.id = b.occurrence_id
    cross join lateral (select free_seat_reservation_state_run(b.id) as j) x
   where b.member_id = p_member_id and b.status = 'booked' and b.payment_source = 'comp'
     and o.starts_at > now()
     and x.j ->> 'state' in ('waived', 'due', 'not_asked')

   order by paid_at desc nulls last;
end $$;

revoke execute on function member_reservation_fees(uuid) from public, anon;
grant  execute on function member_reservation_fees(uuid) to authenticated, service_role;

-- ---- 12. Anon surface: EXACTLY FOURTEEN -----------------------------------
do $$
declare n int;
begin
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'expect\_%' and p.proname not in ('call_jsonb');
  if n <> 14 then
    raise exception 'anon surface is %, expected exactly fourteen', n;
  end if;
end $$;
