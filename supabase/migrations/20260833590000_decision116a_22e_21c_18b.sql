-- Decision 116 amendment (a) "an empty class is down-time", Decision 22 amendment
-- (e) "flex state at a glance", Decision 21 amendment (c) "apply the minimum to
-- future classes", Decision 18 amendment (b) "a month's submission is not the
-- weekly pattern". The enum value replaced_by_private is in 20260833585000.
--
-- creates: instructor_rate_at_run(uuid, date), occurrence_empty_run(uuid), private_replace_ok(uuid, timestamptz), flex_minimum_mismatch_count(uuid), apply_flex_minimum_to_future(uuid, integer), tg_audit_guarantee_settings()
-- re-issues: instructor_rate_at(uuid, date), claim_guarantee_terms(uuid), private_book_run(uuid, uuid, uuid, timestamptz, jsonb, text, text, text), private_confirm_run(uuid), compute_class_pay_run(uuid, integer), instructor_digest_block(uuid, uuid, date), instructor_availability_week(uuid), set_instructor_availability_rows(uuid, jsonb, date, date), instructor_available_at_run(uuid, timestamptz, timestamptz), private_slots(uuid, uuid, uuid, timestamptz, timestamptz), schedule_range(uuid, date, date), flex_pending(uuid)

-- ========================================================================
-- Schema
-- ========================================================================
alter table class_occurrences
  add column if not exists replaces_occurrence_id uuid references class_occurrences(id) on delete set null;
create index if not exists class_occurrences_replaces_idx
  on class_occurrences (replaces_occurrence_id) where replaces_occurrence_id is not null;
comment on column class_occurrences.replaces_occurrence_id is
  'Decision 116(a): the empty group class a private replaces. While the private is pending it takes no room and holds this class''s slot; at confirm the class is cancelled (replaced_by_private) and the private takes its room.';

alter table studio_settings
  add column if not exists private_replace_core_hours int not null default 48;
do $c$ begin
  if not exists (select 1 from pg_constraint where conname = 'studio_settings_private_replace_core_hours_check') then
    alter table studio_settings add constraint studio_settings_private_replace_core_hours_check
      check (private_replace_core_hours between 0 and 336);
  end if;
end $c$;
comment on column studio_settings.private_replace_core_hours is
  'Decision 116(a): an empty core or always-runs class may be replaced by a private only when the private starts within this many hours. Flex classes any time.';

-- A pending replacement private carries the coach while the class it replaces is
-- still scheduled (the displaced coach may teach it). It is left out of the coach
-- overlap until it is confirmed; at confirm the class is cancelled first, then the
-- private commits and the constraint applies to it again.
alter table class_occurrences drop constraint if exists occ_instructor_no_overlap;
alter table class_occurrences add constraint occ_instructor_no_overlap
  exclude using gist (
    instructor_id extensions.gist_uuid_ops with =,
    tstzrange(starts_at, ends_at) with &&
  ) where (instructor_id is not null and status <> 'cancelled'
           and not (replaces_occurrence_id is not null and committed_at is null))
  deferrable initially immediate;

-- ========================================================================
-- The empty rule and the replace window
-- ========================================================================
create or replace function occurrence_empty_run(p_occurrence_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  -- Decision 116(a): no seats counted in booked_count, no live payment hold, no
  -- held waitlist offer, not committed, not private, still scheduled.
  select exists (
    select 1 from class_occurrences o
     where o.id = p_occurrence_id
       and o.status = 'scheduled'
       and not coalesce(o.is_private, false)
       and o.committed_at is null
       and coalesce(o.booked_count, 0) = 0
       and not exists (select 1 from bookings b where b.occurrence_id = o.id
                         and b.status in ('booked', 'attended', 'no_show', 'pending_payment'))
       and coalesce(occurrence_seats_held(o.id, null), 0) = 0);
$$;
revoke execute on function occurrence_empty_run(uuid) from public, anon, authenticated;
grant execute on function occurrence_empty_run(uuid) to service_role;

create or replace function private_replace_ok(p_occurrence_id uuid, p_starts_at timestamptz)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_tier guarantee_tier; v_hours int;
begin
  if not occurrence_empty_run(p_occurrence_id) then return false; end if;
  -- a pending private already targets it
  if exists (select 1 from class_occurrences p where p.replaces_occurrence_id = p_occurrence_id
               and p.status = 'scheduled') then return false; end if;
  select studio_id into v_studio from class_occurrences where id = p_occurrence_id;
  select g.tier into v_tier from occurrence_guarantee_run(p_occurrence_id) g;
  if v_tier = 'flex' then return true; end if;
  -- core and always-runs keep their chance to fill: only inside the replace window
  v_hours := coalesce((select private_replace_core_hours from studio_settings where studio_id = v_studio), 48);
  return p_starts_at <= now() + make_interval(hours => v_hours);
end $$;
revoke execute on function private_replace_ok(uuid, timestamptz) from public, anon, authenticated;
grant execute on function private_replace_ok(uuid, timestamptz) to service_role;

-- ========================================================================
-- Private booking, confirm, slots
-- ========================================================================
CREATE OR REPLACE FUNCTION public.private_book_run(p_member_id uuid, p_type_id uuid, p_instructor_id uuid, p_starts_at timestamp with time zone, p_companions jsonb, p_mode text, p_method text DEFAULT NULL::text, p_reference text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  t private_session_types%rowtype; ss studio_settings%rowtype; v_tz text;
  v_member members%rowtype; v_studio uuid; v_coach uuid; v_room uuid; v_ends timestamptz;
  v_loc uuid; v_occ uuid; v_seat_status booking_status; v_booker_booking uuid;
  v_ccy char(3); v_pack uuid; v_purchase uuid; v_conflict text; v_mode text;
  v_ncomp int; v_comp jsonb; v_cmember uuid; v_now timestamptz := now();
  v_emails text[]; v_e text; v_credit int; v_pay uuid;
  v_rep uuid; v_rep_coach uuid;
begin
  select * into t from private_session_types where id = p_type_id and active;
  if t.id is null then return jsonb_build_object('ok', false, 'reason', 'no_such_type'); end if;
  v_studio := t.studio_id;
  select * into ss from studio_settings where studio_id = v_studio;
  if not coalesce(ss.private_sessions_enabled, false) then
    return jsonb_build_object('ok', false, 'reason', 'not_enabled'); end if;
  select * into v_member from members where id = p_member_id and studio_id = v_studio and deleted_at is null;
  if v_member.id is null then raise exception 'you are not a member of that studio' using errcode = 'PT403'; end if;
  select timezone, currency into v_tz, v_ccy from studios where id = v_studio;
  v_ends := p_starts_at + make_interval(mins => t.duration_min);
  v_mode := coalesce(p_mode, 'xendit');
  if v_mode not in ('xendit', 'pack', 'credit', 'desk') then
    return jsonb_build_object('ok', false, 'reason', 'bad_pay_mode'); end if;

  -- companions: exactly people - 1, each a distinct email that is not the booker
  v_ncomp := coalesce(jsonb_array_length(p_companions), 0);
  if v_ncomp <> t.people - 1 then
    return jsonb_build_object('ok', false, 'reason', 'wrong_companion_count', 'need', t.people - 1); end if;
  v_emails := array[lower(btrim(coalesce(v_member.email, '')))];
  for v_comp in select * from jsonb_array_elements(coalesce(p_companions, '[]'::jsonb)) loop
    v_e := lower(btrim(coalesce(v_comp->>'email', '')));
    if v_e not like '%_@_%' or coalesce(nullif(btrim(v_comp->>'name'), ''), '') = '' then
      return jsonb_build_object('ok', false, 'reason', 'companion_details'); end if;
    if v_e = any(v_emails) then
      return jsonb_build_object('ok', false, 'reason', 'companion_duplicate'); end if;
    v_emails := v_emails || v_e;
  end loop;

  -- lead time (a desk booking skips it: staff may book at short notice), hours
  if v_mode <> 'desk'
     and p_starts_at < v_now + make_interval(hours => coalesce(ss.private_lead_time_hours, 24)) then
    return jsonb_build_object('ok', false, 'reason', 'too_soon'); end if;
  if p_starts_at <= v_now then return jsonb_build_object('ok', false, 'reason', 'too_soon'); end if;
  if ss.open_time is null or ss.close_time is null
     or (p_starts_at at time zone v_tz)::time < ss.open_time
     or (v_ends at time zone v_tz)::time > ss.close_time
     or (p_starts_at at time zone v_tz)::date <> (v_ends at time zone v_tz)::date then
    return jsonb_build_object('ok', false, 'reason', 'outside_hours'); end if;

  -- Decision 116(a): a free room over [start - buffer, end + buffer], or a room
  -- whose only class then is empty and may be replaced (private_replace_ok). A
  -- replacing private records that class and takes no room until it is confirmed;
  -- a pending replacement (room null) holds the room of the class it targets.
  select pick.rid, pick.rep into v_room, v_rep from (
    select r.id as rid, case when ov.n = 0 then null else ov.rep end as rep, ov.n, r.name
      from rooms r
      cross join lateral (
        select count(*) as n, (array_agg(o.id))[1] as rep, bool_and(o.starts_at = p_starts_at) as aligned
          from class_occurrences o
         where o.status <> 'cancelled'
           and (o.room_id = r.id
                or (o.room_id is null and o.replaces_occurrence_id in
                      (select x.id from class_occurrences x where x.room_id = r.id)))
           and tstzrange(o.starts_at, o.ends_at)
               && tstzrange(p_starts_at - make_interval(mins => coalesce(ss.private_buffer_minutes, 10)),
                            v_ends + make_interval(mins => coalesce(ss.private_buffer_minutes, 10)))) ov
     where r.studio_id = v_studio and r.status = 'active'
       and (ov.n = 0 or (ov.n = 1 and ov.aligned and private_replace_ok(ov.rep, p_starts_at)))
     order by ov.n, r.name limit 1) pick;
  if v_room is null then return jsonb_build_object('ok', false, 'reason', 'no_room'); end if;
  if v_rep is not null then
    select instructor_id into v_rep_coach from class_occurrences where id = v_rep;
  end if;
  -- coach: the chosen one, or the first available teaches-privates coach
  if p_instructor_id is not null then
    if not exists (select 1 from instructors i where i.id = p_instructor_id and i.studio_id = v_studio
                    and i.status = 'active' and coalesce(i.teaches_privates, false))
       or not instructor_available_at_run(p_instructor_id, p_starts_at, v_ends) then
      return jsonb_build_object('ok', false, 'reason', 'coach_unavailable'); end if;
    if exists (select 1 from class_occurrences x where x.instructor_id = p_instructor_id
                 and x.status <> 'cancelled' and x.id is distinct from v_rep
                 and tstzrange(x.starts_at, x.ends_at) && tstzrange(p_starts_at, v_ends)) then
      return jsonb_build_object('ok', false, 'reason', 'coach_busy'); end if;
    v_coach := p_instructor_id;
  else
    select i.id into v_coach from instructors i
      where i.studio_id = v_studio and i.status = 'active' and coalesce(i.teaches_privates, false)
        and instructor_available_at_run(i.id, p_starts_at, v_ends)
        and not exists (select 1 from class_occurrences x where x.instructor_id = i.id
                          and x.status <> 'cancelled' and x.id is distinct from v_rep
                          and tstzrange(x.starts_at, x.ends_at) && tstzrange(p_starts_at, v_ends))
      order by coalesce(i.id = v_rep_coach, false) desc, i.display_name limit 1;
    if v_coach is null then return jsonb_build_object('ok', false, 'reason', 'coach_unavailable'); end if;
  end if;

  select id into v_loc from locations where studio_id = v_studio and is_primary order by created_at limit 1;

  -- a Xendit private the member's account credit fully covers completes from credit
  if v_mode = 'xendit' and reservation_credit_available(v_studio, p_member_id) >= t.price_cents then
    v_mode := 'credit';
  end if;
  if v_mode = 'credit' and reservation_credit_available(v_studio, p_member_id) < t.price_cents then
    return jsonb_build_object('ok', false, 'reason', 'not_enough_credit'); end if;
  if v_mode = 'xendit' and not exists (select 1 from studio_payment_providers
       where studio_id = v_studio and provider = 'xendit') then
    return jsonb_build_object('ok', false, 'reason', 'no_provider'); end if;
  if v_mode = 'desk' and coalesce(p_method, '') not in ('cash','bank_transfer','card_terminal','gcash','other') then
    return jsonb_build_object('ok', false, 'reason', 'unknown_method'); end if;

  -- a pack resolves up front so a missing pack fails before creating anything
  if v_mode = 'pack' then
    if t.people <> 1 then return jsonb_build_object('ok', false, 'reason', 'pack_1to1_only'); end if;
    v_pack := private_pack_consume(p_member_id, v_studio);
    if v_pack is null then return jsonb_build_object('ok', false, 'reason', 'no_pack_credit'); end if;
  end if;

  v_seat_status := case when v_mode = 'xendit' then 'pending_payment' else 'booked' end::booking_status;

  begin
    insert into class_occurrences (studio_id, location_id, class_type_id, name, instructor_id,
      room_id, capacity, starts_at, ends_at, guarantee_tier, flex, is_private, private_type_id,
      hidden_from_members, replaces_occurrence_id)
    values (v_studio, v_loc, null, t.name || ' · ' || coalesce(nullif(v_member.preferred_name, ''), v_member.first_name),
      v_coach, case when v_rep is null then v_room end, t.people, p_starts_at, v_ends, 'always', false, true, t.id, true,
      v_rep)
    returning id into v_occ;
  exception when exclusion_violation then
    get stacked diagnostics v_conflict = constraint_name;
    if v_pack is not null then
      update memberships set credits_remaining = credits_remaining + 1 where id = v_pack;
      insert into credit_ledger (studio_id, member_id, membership_id, delta, reason, balance_after)
      select v_studio, p_member_id, v_pack, 1, 'booking',
             (select credits_remaining from memberships where id = v_pack);
    end if;
    return jsonb_build_object('ok', false,
      'reason', case when v_conflict = 'occ_room_no_overlap' then 'room_busy' else 'coach_busy' end);
  end;

  -- the private's own private_confirmed is the confirmation; the ordinary
  -- booking_confirmed must not also go (the walk-in flag, txn-local).
  perform set_config('studiior.suppress_booking_email', '1', true);
  -- the booker's seat
  insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source, membership_id)
  values (v_studio, v_occ, p_member_id, v_seat_status,
          (case when v_mode = 'desk' then 'front_desk' else 'member' end)::booking_source,
          'private', v_pack)
  returning id into v_booker_booking;
  update class_occurrences set booked_count = booked_count + 1 where id = v_occ;

  -- companion seats: resolve or create each as a lead; part of the paid private
  for v_comp in select * from jsonb_array_elements(coalesce(p_companions, '[]'::jsonb)) loop
    select id into v_cmember from members where studio_id = v_studio
      and lower(email) = lower(btrim(v_comp->>'email')) and deleted_at is null;
    if v_cmember is null then
      insert into members (studio_id, first_name, last_name, email, status, source)
      values (v_studio, split_part(btrim(v_comp->>'name'), ' ', 1), name_last_part(btrim(v_comp->>'name')),
              lower(btrim(v_comp->>'email')), 'lead', 'private_companion')
      returning id into v_cmember;
    end if;
    insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source)
    values (v_studio, v_occ, v_cmember, v_seat_status,
            (case when v_mode = 'desk' then 'front_desk' else 'member' end)::booking_source, 'private');
    update class_occurrences set booked_count = booked_count + 1 where id = v_occ;
  end loop;
  perform set_config('studiior.suppress_booking_email', '', true);

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (v_studio, auth.uid(), 'private.booked', 'class_occurrences', v_occ,
          jsonb_build_object('type', t.name, 'people', t.people, 'mode', v_mode,
                             'member_id', p_member_id, 'starts_at', p_starts_at,
                             'replaces_occurrence_id', v_rep));

  if v_mode = 'xendit' then
    insert into xendit_purchases (studio_id, member_id, private_occurrence_id, amount_cents, currency)
    values (v_studio, p_member_id, v_occ, t.price_cents, v_ccy)
    returning id into v_purchase;
    return jsonb_build_object('ok', true, 'occurrence_id', v_occ, 'confirmed', false,
      'purchase_id', v_purchase, 'amount_cents', t.price_cents, 'currency', v_ccy);
  end if;

  if v_mode = 'credit' then
    v_credit := consume_reservation_credit(v_studio, p_member_id, t.price_cents);
    insert into payments (studio_id, member_id, booking_id, kind, amount_cents, currency,
                          status, provider, source, description, paid_at)
    values (v_studio, p_member_id, v_booker_booking, 'private', t.price_cents, v_ccy,
            'succeeded', 'manual', 'credit', 'Private session (account credit)', now());
  elsif v_mode = 'desk' then
    insert into payments (studio_id, member_id, booking_id, kind, amount_cents, currency,
                          status, provider, method, reference, recorded_by, description, paid_at)
    values (v_studio, p_member_id, v_booker_booking, 'private', t.price_cents, v_ccy,
            'succeeded', 'manual', p_method, nullif(btrim(coalesce(p_reference, '')), ''),
            auth.uid(), 'Private session', now())
    returning id into v_pay;
  end if;
  perform private_confirm_run(v_occ);
  -- Decision 116(a): the class it replaces was booked in the meantime, so the
  -- private was refused at confirm and the money came back.
  if (select status from class_occurrences where id = v_occ) = 'cancelled' then
    return jsonb_build_object('ok', false, 'reason', 'time_taken', 'occurrence_id', v_occ);
  end if;
  return jsonb_build_object('ok', true, 'occurrence_id', v_occ, 'confirmed', true, 'mode', v_mode);
end $function$;

CREATE OR REPLACE FUNCTION public.private_confirm_run(p_occurrence_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o class_occurrences%rowtype; t private_session_types%rowtype;
        v_tz text; v_when text; v_booker uuid; r record; v_token text; v_claim text;
        x class_occurrences%rowtype; v_seat bookings%rowtype; v_xwhen text; v_pay_line text;
begin
  select * into o from class_occurrences where id = p_occurrence_id for update;
  if o.id is null or not o.is_private then return; end if;
  if o.committed_at is not null then return; end if;  -- already confirmed
  select * into t from private_session_types where id = o.private_type_id;
  select timezone into v_tz from studios where id = o.studio_id;
  v_when := to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMon') || ', '
            || fmt_clock(o.starts_at, v_tz, (select time_format from studio_settings where studio_id = o.studio_id));

  -- Decision 116(a): a private that replaces an empty group class. Under a row
  -- lock the class is checked again. Still empty: it is cancelled with the cause
  -- replaced_by_private (it has no members, so no member email goes), its coach
  -- is told unless they teach this private, and the private takes its room.
  -- Booked or committed in the meantime: the private is refused, the money comes
  -- back (credit, or the pack session), and the member is told.
  if o.replaces_occurrence_id is not null and o.room_id is null then
    select * into x from class_occurrences where id = o.replaces_occurrence_id for update;
    if x.id is not null and occurrence_empty_run(x.id) then
      -- the cancel fires the pay trigger (record_class_pay is manager/service);
      -- the private-pay flag lets this one write through, txn-local.
      perform set_config('studiior.private_pay', '1', true);
      update class_occurrences
         set status = 'cancelled', cancelled_at = now(), updated_at = now(),
             cancellation_cause = 'replaced_by_private',
             cancellation_reason = 'Replaced by a private session'
       where id = x.id;
      perform set_config('studiior.private_pay', '', true);
      update class_occurrences set room_id = x.room_id where id = p_occurrence_id;
      o.room_id := x.room_id;
      if x.instructor_id is not null and x.instructor_id is distinct from o.instructor_id
         and instructor_user_id(x.instructor_id) is not null then
        v_xwhen := to_char(x.starts_at at time zone v_tz, 'FMDay FMDD FMMon') || ', '
                   || fmt_clock(x.starts_at, v_tz, (select time_format from studio_settings where studio_id = o.studio_id));
        v_pay_line := case
          when (select g.tier from occurrence_guarantee_run(x.id) g) = 'flex' then
            case when coalesce((select flex_unmet_pay_cents from studio_settings where studio_id = o.studio_id), 0) > 0
                 then 'You''re paid the flex standby amount for it.' else '' end
          else 'You''re paid the core holding fee for it.' end;
        perform queue_shift_notice(o.studio_id, instructor_user_id(x.instructor_id), 'private_replaced_class',
          jsonb_build_object('first_name', (select split_part(display_name, ' ', 1) from instructors where id = x.instructor_id),
            'class_name', coalesce(x.name, (select name from class_types where id = x.class_type_id), 'Your class'),
            'when', v_xwhen, 'type_name', t.name, 'pay_line', v_pay_line, 'occurrence_id', x.id,
            'studio_name', (select name from studios where id = o.studio_id),
            'schedule_url', instructor_portal_url(o.studio_id, '/instructor/schedule')),
          'private_replaced:' || x.id::text);
      end if;
      insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
      values (o.studio_id, auth.uid(), 'private.replaced_class', 'class_occurrences', x.id,
              jsonb_build_object('private_occurrence_id', o.id, 'cause', 'replaced_by_private',
                                 'displaced_instructor_id', x.instructor_id,
                                 'private_instructor_id', o.instructor_id,
                                 'starts_at', x.starts_at));
    else
      select * into v_seat from bookings where occurrence_id = p_occurrence_id
        and payment_source = 'private' order by created_at limit 1;
      perform private_refund_run(p_occurrence_id);
      perform set_config('studiior.releasing', '1', true);
      update bookings set status = 'cancelled', cancelled_at = now(), release_reason = 'studio_released'
       where occurrence_id = p_occurrence_id and status in ('pending_payment', 'booked');
      perform set_config('studiior.releasing', '', true);
      perform set_config('studiior.private_pay', '1', true);
      update class_occurrences
         set status = 'cancelled', cancelled_at = now(), updated_at = now(),
             cancellation_cause = 'studio_fault', cancellation_reason = 'time_taken'
       where id = p_occurrence_id;
      perform set_config('studiior.private_pay', '', true);
      if v_seat.id is not null then
        perform queue_notification(o.studio_id, v_seat.member_id, 'private_time_taken',
          jsonb_build_object('first_name', (select first_name from members where id = v_seat.member_id),
            'type_name', t.name, 'when', v_when, 'occurrence_id', o.id,
            'studio_name', (select name from studios where id = o.studio_id),
            'refund_line', case when v_seat.membership_id is not null
                                then 'Your session is back on your pack.'
                                else 'Your ' || fmt_money(t.price_cents, (select currency from studios where id = o.studio_id))
                                     || ' is back on your account as credit.' end,
            'book_url', member_portal_url(o.studio_id, '/book/private')),
          'private_time_taken:' || o.id::text);
      end if;
      insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
      values (o.studio_id, auth.uid(), 'private.refused_time_taken', 'class_occurrences', o.id,
              jsonb_build_object('replaces_occurrence_id', o.replaces_occurrence_id,
                                 'member_id', v_seat.member_id, 'pack', v_seat.membership_id is not null));
      return;
    end if;
  end if;

  perform set_config('studiior.suppress_booking_email', '1', true);
  update bookings set status = 'booked'
   where occurrence_id = p_occurrence_id and status = 'pending_payment';
  perform set_config('studiior.suppress_booking_email', '', true);
  -- the committed_at write fires tg_record_class_pay -> record_class_pay, which is
  -- manager/service only; this flag lets the pack path (member context) write the
  -- one flat private pay record. Txn-local, reset straight after.
  perform set_config('studiior.private_pay', '1', true);
  update class_occurrences set committed_at = now() where id = p_occurrence_id;
  perform set_config('studiior.private_pay', '', true);

  -- the booker is the first seat booked; companions follow.
  select b.member_id into v_booker from bookings b
   where b.occurrence_id = p_occurrence_id and b.status = 'booked'
   order by b.created_at limit 1;

  -- tell every booked member (booker + companions) the session is confirmed. A
  -- companion with no account gets a claim + waiver link (they must sign before
  -- the session), minted here like the guest invite.
  for r in select b.member_id, m.email, m.first_name, m.user_id from bookings b
             join members m on m.id = b.member_id
            where b.occurrence_id = p_occurrence_id and b.status = 'booked'
  loop
    v_claim := '';
    if r.user_id is null then
      v_token := encode(extensions.gen_random_bytes(24), 'hex');
      -- one live invite per member: the newest link is the one that works
      delete from member_invites where member_id = r.member_id and accepted_at is null;
      insert into member_invites (studio_id, member_id, email, token_hash, expires_at)
      values (o.studio_id, r.member_id, r.email, encode(extensions.digest(v_token, 'sha256'), 'hex'),
              now() + interval '14 days');
      v_claim := 'https://' || (select slug from studios where id = o.studio_id) || '.'
                 || coalesce(notification_setting('member_app_domain'), 'studiior.app')
                 || '/claim/' || v_token;
    end if;
    perform queue_notification(o.studio_id, r.member_id, 'private_confirmed',
      jsonb_build_object('first_name', r.first_name, 'type_name', t.name,
        'when', v_when, 'studio_name', (select name from studios where id = o.studio_id),
        'occurrence_id', o.id, 'is_companion', (r.member_id <> v_booker),
        'manage_url', member_portal_url(o.studio_id, '/private/' || o.id),
        'booker_name', (select first_name from members where id = v_booker),
        'claim_url', v_claim,
        'claim_line', case when v_claim = '' then '' else
          E'\n\nBefore the session, set up your account and sign the studio waiver: ' || v_claim end,
        'claim_html', case when v_claim = '' then '' else
          '<p>Before the session, set up your account and sign the studio waiver.</p>'
          || '<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="'
          || v_claim || '" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Set up my account</a></td></tr></table>' end,
        'amount', fmt_money(t.price_cents, (select currency from studios where id = o.studio_id))),
      'private_confirmed:' || r.member_id::text || ':' || o.id::text);
  end loop;

  -- tell the coach (if they have a login)
  if o.instructor_id is not null and instructor_user_id(o.instructor_id) is not null then
    perform queue_shift_notice(o.studio_id, instructor_user_id(o.instructor_id), 'private_booked',
      jsonb_build_object('type_name', t.name, 'when', v_when,
        'first_name', (select split_part(display_name, ' ', 1) from instructors where id = o.instructor_id),
        'client_name', (select first_name from members where id = v_booker),
        'people', t.people, 'occurrence_id', o.id,
        'schedule_url', instructor_portal_url(o.studio_id, '/instructor/schedule')),
      'private_booked:' || o.id::text);
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (o.studio_id, auth.uid(), 'private.confirmed', 'class_occurrences', o.id,
          jsonb_build_object('type', t.name, 'people', t.people, 'when', v_when));
end $function$;

drop function if exists private_slots(uuid, uuid, uuid, timestamptz, timestamptz);
CREATE FUNCTION public.private_slots(p_studio_id uuid, p_type_id uuid, p_instructor_id uuid, p_from timestamp with time zone, p_to timestamp with time zone)
 RETURNS TABLE(starts_at timestamp with time zone, ends_at timestamp with time zone, room_id uuid, coach_ids uuid[], replaces_occurrence_id uuid)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_tz text; v_open time; v_close time; v_buffer int; v_lead int; v_dur int;
  v_now timestamptz := now();
begin
  if not (exists (select 1 from members m where m.studio_id = p_studio_id and m.user_id = auth.uid() and m.deleted_at is null)
          or coalesce(is_desk_up(p_studio_id), false) or is_service_context()) then
    raise exception 'you are not a member of that studio' using errcode = 'PT403';
  end if;
  select s.timezone, ss.open_time, ss.close_time,
         coalesce(ss.private_buffer_minutes, 10), coalesce(ss.private_lead_time_hours, 24)
    into v_tz, v_open, v_close, v_buffer, v_lead
    from studios s join studio_settings ss on ss.studio_id = s.id
   where s.id = p_studio_id;
  select t.duration_min into v_dur from private_session_types t
   where t.id = p_type_id and t.studio_id = p_studio_id and t.active;
  if v_dur is null then return; end if;
  if v_open is null or v_close is null then return; end if;  -- no opening hours set, no private slots

  return query
  with cand as (
    -- 30-minute candidate starts across the window, built in studio-local time.
    select gs as t1, gs + make_interval(mins => v_dur) as t2
    from generate_series(
           date_trunc('day', (greatest(p_from, v_now + make_interval(hours => v_lead)) at time zone v_tz)) at time zone v_tz,
           (p_to at time zone v_tz) at time zone v_tz,
           interval '30 minutes') gs
    where gs >= v_now + make_interval(hours => v_lead)
      and gs >= p_from and gs + make_interval(mins => v_dur) <= p_to
      -- whole session inside opening hours (studio-local wall clock)
      and (gs at time zone v_tz)::time >= v_open
      and ((gs + make_interval(mins => v_dur)) at time zone v_tz)::time <= v_close
      and (gs at time zone v_tz)::date = ((gs + make_interval(mins => v_dur)) at time zone v_tz)::date
  ),
  rooms_free as (
    -- Decision 116(a): a room with nothing in it over the session plus the buffer,
    -- or one whose only class then starts with the session, is empty and may be
    -- replaced (private_replace_ok). A pending replacement (room null) holds the
    -- room of the class it targets. A free room is preferred over a replacement.
    select c.t1, c.t2, pick.rid, pick.rep
    from cand c
    cross join lateral (
      select r.id as rid, case when ov.n = 0 then null else ov.rep end as rep
        from rooms r
        cross join lateral (
          select count(*) as n, (array_agg(o.id))[1] as rep, bool_and(o.starts_at = c.t1) as aligned
            from class_occurrences o
           where o.status <> 'cancelled'
             and (o.room_id = r.id
                  or (o.room_id is null and o.replaces_occurrence_id in
                        (select y.id from class_occurrences y where y.room_id = r.id)))
             and tstzrange(o.starts_at, o.ends_at)
                 && tstzrange(c.t1 - make_interval(mins => v_buffer), c.t2 + make_interval(mins => v_buffer))) ov
       where r.studio_id = p_studio_id and r.status = 'active'
         and (ov.n = 0 or (ov.n = 1 and ov.aligned and private_replace_ok(ov.rep, c.t1)))
       order by ov.n, r.name limit 1) pick
  ),
  coaches_free as (
    select rf.t1, rf.t2, rf.rid, rf.rep,
      array(select i.id from instructors i
            where i.studio_id = p_studio_id and i.status = 'active'
              and coalesce(i.teaches_privates, false)
              and (p_instructor_id is null or i.id = p_instructor_id)
              and instructor_available_at_run(i.id, rf.t1, rf.t2)
              -- not already teaching anything (any room) over the session; the
              -- class being replaced never counts as them being busy
              and not exists (select 1 from class_occurrences x
                               where x.instructor_id = i.id and x.status <> 'cancelled'
                                 and x.id is distinct from rf.rep
                                 and tstzrange(x.starts_at, x.ends_at) && tstzrange(rf.t1, rf.t2))
            -- the displaced coach is offered first
            order by coalesce(i.id = (select z.instructor_id from class_occurrences z where z.id = rf.rep), false) desc,
                     i.display_name) as cids
    from rooms_free rf
  )
  select cf.t1, cf.t2, cf.rid, cf.cids, cf.rep
  from coaches_free cf
  where array_length(cf.cids, 1) >= 1
  order by cf.t1;
end $function$;

revoke execute on function private_slots(uuid, uuid, uuid, timestamptz, timestamptz) from public, anon;
grant execute on function private_slots(uuid, uuid, uuid, timestamptz, timestamptz) to authenticated, service_role;

-- ========================================================================
-- The rate reader's unguarded twin. compute_class_pay_run runs inside the
-- private confirm in the member's context (a pack booking), where the guarded
-- name refuses. Internals call the twin; the guarded name stays for clients.
-- ========================================================================
create or replace function instructor_rate_at_run(p_instructor_id uuid, p_on date)
returns instructor_rate_versions language sql stable security definer set search_path = public as $$
  select * from instructor_rate_versions
   where instructor_id = p_instructor_id and effective_from <= p_on
   order by effective_from desc limit 1;
$$;
revoke execute on function instructor_rate_at_run(uuid, date) from public, anon, authenticated;
grant execute on function instructor_rate_at_run(uuid, date) to service_role;

CREATE OR REPLACE FUNCTION public.instructor_rate_at(p_instructor_id uuid, p_on date)
 RETURNS instructor_rate_versions
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_studio uuid; rv instructor_rate_versions%rowtype;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then
    raise exception 'no such instructor' using errcode = 'PT404';
  end if;
  if not coalesce(is_manager_up(v_studio), false)
     and not is_this_instructor(p_instructor_id)
     and not is_service_context() then
    raise exception 'that is not your rate' using errcode = 'PT403';
  end if;
  select * into rv from instructor_rate_at_run(p_instructor_id, p_on);
  return rv;
end $function$;

-- claim_guarantee_terms reads the rate after its own guard; it calls the twin.
CREATE OR REPLACE FUNCTION public.claim_guarantee_terms(p_instructor_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_studio uuid; s studio_settings%rowtype; v_base int; v_hold int; v_kind text;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  if not (is_manager_up(v_studio) or is_this_instructor(p_instructor_id) or is_service_context()) then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;
  select * into s from studio_settings where studio_id = v_studio;

  -- Guarantees off -> no footnote at all (the popup shows none).
  if not coalesce(s.guarantees_enabled, false) and not coalesce(s.flex_enabled, false) then
    return jsonb_build_object('guarantees_enabled', false, 'flex_enabled', false);
  end if;

  -- The holding fee: a flat amount wins where set (145), else a percentage of
  -- the instructor's own base rate. Resolved to an amount here so the copy does
  -- not do money arithmetic.
  select base_rate_cents into v_base from instructor_rate_at_run(p_instructor_id, current_date);
  if s.core_unmet_pay_cents is not null then
    v_hold := s.core_unmet_pay_cents; v_kind := 'flat';
  elsif v_base is not null and coalesce(s.core_unmet_pay_pct, 0) > 0 then
    v_hold := round(v_base * s.core_unmet_pay_pct / 100.0); v_kind := 'pct';
  else
    v_hold := null; v_kind := null;
  end if;

  return jsonb_build_object(
    'guarantees_enabled', coalesce(s.guarantees_enabled, false),
    'flex_enabled', coalesce(s.flex_enabled, false),
    'core_cutoff_hours', s.core_cutoff_hours,
    'holding_kind', v_kind,           -- 'flat' | 'pct' | null
    'holding_cents', v_hold,          -- resolved amount, or null if unknowable
    'holding_pct', s.core_unmet_pay_pct,
    'flex_deadline_mode', s.flex_deadline_mode,   -- 'previous_day_at' | 'hours_before'
    'flex_deadline_time', to_char(s.flex_deadline_time, 'HH24:MI'),
    'flex_deadline_hours', s.flex_deadline_hours);
end $function$;

-- ========================================================================
-- Pay, digest
-- ========================================================================
CREATE OR REPLACE FUNCTION public.compute_class_pay_run(p_occurrence_id uuid, p_heads integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o class_occurrences%rowtype; s studio_settings%rowtype; g record;
  rv instructor_rate_versions%rowtype; v_kind session_kind; v_tz text;
  v_local date; v_amount int; v_basis jsonb; v_heads int; v_flat int;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if o.instructor_id is null then
    return jsonb_build_object('ok', false, 'reason', 'no instructor on this class');
  end if;

  select * into s from studio_settings where studio_id = o.studio_id;
  select timezone into v_tz from studios where id = o.studio_id;
  v_local := (o.starts_at at time zone v_tz)::date;

  -- Decision 116: a private is a flat line paid at the TYPE's coach pay, with the
  -- kind from its people (1 private, 2 duo, 3 trio). It needs NO instructor rate
  -- version, so it returns before the (guarded) rate lookup. A studio-cancelled
  -- private pays the coach nothing; otherwise the coach is paid the flat amount.
  if coalesce(o.is_private, false) then
    select coach_pay_cents,
           (case people when 1 then 'private' when 2 then 'duo' else 'trio' end)::session_kind
      into v_flat, v_kind
      from private_session_types where id = o.private_type_id;
    v_flat := coalesce(v_flat, 0);
    v_amount := case when o.status = 'cancelled' then 0 else v_flat end;
    v_basis := jsonb_build_object('kind', coalesce(v_kind, 'private'),
      'flat_rate_cents', v_flat, 'private', true,
      'status', o.status, 'cause', o.cancellation_cause);
    return jsonb_build_object('ok', true, 'amount_cents', v_amount,
      'currency', (select currency from studios where id = o.studio_id),
      'rate_version_id', null,
      'instructor_id', o.instructor_id, 'local_date', v_local, 'basis', v_basis);
  end if;

  -- The version in force ON THE DAY OF THE CLASS, not today. This is what makes
  -- a rate change next month leave last month alone.
  select * into rv from instructor_rate_at_run(o.instructor_id, v_local);
  if rv.id is null then
    return jsonb_build_object('ok', false, 'reason', 'no rate on file for that date');
  end if;

  select coalesce(ct.session_kind, 'group') into v_kind
    from class_types ct where ct.id = o.class_type_id;
  v_kind := coalesce(v_kind, 'group');

  select * into g from occurrence_guarantee_run(p_occurrence_id);
  -- DECISION 32: the greater of the cutoff count and the start count. When the
  -- start snapshot has not been taken (not yet started, or an `always` class
  -- whose cutoff count already IS the start count) booked_at_start is null and
  -- the greatest collapses to the cutoff — so nothing changes until a real late
  -- booker moves the start count above it.
  -- DECISION 75d: an optional checked-in-head override (finalise_pay_true_up
  -- passes count(distinct member) from check_ins). Null keeps Decision 32's
  -- greater-of booked basis, so every other caller is byte-for-byte unchanged.
  v_heads := coalesce(p_heads, greatest(coalesce(o.booked_at_cutoff, 0), coalesce(o.booked_at_start, 0)));

  -- 1. A private, duo or trio REPLACES the whole calculation. Flat, by product.
  if v_kind <> 'group' then
    v_flat := case v_kind
      when 'private' then rv.private_rate_cents
      when 'duo'     then rv.duo_rate_cents
      else                rv.trio_rate_cents end;
    if v_flat is null then
      return jsonb_build_object('ok', false,
        'reason', format('no %s rate on file', v_kind));
    end if;
    -- A private that did not run follows the same cancellation rules as any
    -- other class, against its flat rate rather than a base.
    if o.status = 'cancelled' then
      v_amount := case o.cancellation_cause
        when 'unmet_minimum' then
          case when g.tier = 'flex' then coalesce(s.flex_unmet_pay_cents, 0)
               else (v_flat * coalesce(s.core_unmet_pay_pct, 0)) / 100 end
        when 'studio_fault'  then v_flat
        when 'force_majeure' then 0
        when 'closure'       then case when coalesce(o.cancellation_pays, false) then v_flat else 0 end
        else 0 end;
    else
      v_amount := v_flat;
    end if;
    v_basis := jsonb_build_object('kind', v_kind, 'flat_rate_cents', v_flat,
                                  'status', o.status, 'cause', o.cancellation_cause);

  -- 2. It ran, or it is committed and therefore owed in full whatever happened
  --    afterwards.
  elsif o.status <> 'cancelled' or o.committed_at is not null then
    v_amount := rv.base_rate_cents
              + greatest(0, v_heads - rv.per_head_threshold) * rv.per_head_rate_cents
              -- Keys off THE CLASS's capacity, which varies by room. A capacity
              -- 5 studio and a capacity 6 studio both reach a full house.
              + case when o.capacity is not null and v_heads >= o.capacity
                     then rv.full_house_bonus_cents else 0 end;
    v_basis := jsonb_build_object(
      'kind', 'group', 'base_cents', rv.base_rate_cents,
      -- Both counts and the one actually paid, so the statement can say "2 at
      -- cutoff, 3 at start" and the CSV can agree line for line.
      'booked_at_cutoff', coalesce(o.booked_at_cutoff, 0),
      'booked_at_start', o.booked_at_start,
      'booked_paid', v_heads,
      'capacity', o.capacity,
      'per_head_cents', rv.per_head_rate_cents, 'per_head_threshold', rv.per_head_threshold,
      'heads_paid', greatest(0, v_heads - rv.per_head_threshold),
      'full_house', (o.capacity is not null and v_heads >= o.capacity),
      'full_house_bonus_cents', case when o.capacity is not null and v_heads >= o.capacity
                                     then rv.full_house_bonus_cents else 0 end);

  -- 3. It is not running.
  else
    if o.cancellation_cause = 'unmet_minimum' then
      if g.tier = 'flex' then
        -- Standby is paid when the slot was STANDALONE. A flex class next to
        -- another of the instructor's classes costs them nothing extra; one on
        -- its own cost them the trip. Both settings default to 0, so a studio
        -- that has not set them is unaffected either way.
        v_amount := coalesce(s.flex_unmet_pay_cents, 0)
                  + case when occurrence_is_adjacent_run(p_occurrence_id)
                         then 0 else coalesce(s.flex_standby_pay_cents, 0) end;
        v_basis := jsonb_build_object('kind', 'group', 'outcome', 'not_running',
          'tier', 'flex', 'unmet_pay_cents', coalesce(s.flex_unmet_pay_cents, 0),
          'standby_cents', case when occurrence_is_adjacent_run(p_occurrence_id)
                                then 0 else coalesce(s.flex_standby_pay_cents, 0) end,
          'adjacent', occurrence_is_adjacent_run(p_occurrence_id));
      else
        -- The slot-holding fee: a FLAT amount when the studio set one
        -- (core_unmet_pay_cents), otherwise the percentage of base. Flat wins
        -- because "pay 400 regardless" cannot be a percentage of a rate that
        -- changes; the percentage stays the fallback so existing studios that
        -- only ever set a pct are untouched.
        v_amount := coalesce(s.core_unmet_pay_cents,
                             (rv.base_rate_cents * coalesce(s.core_unmet_pay_pct, 0)) / 100);
        v_basis := jsonb_build_object('kind', 'group', 'outcome', 'not_running',
          'tier', 'core', 'base_cents', rv.base_rate_cents,
          'holding_model', case when s.core_unmet_pay_cents is not null then 'flat' else 'pct' end,
          'holding_flat_cents', s.core_unmet_pay_cents,
          'holding_pct', coalesce(s.core_unmet_pay_pct, 0));
      end if;
    elsif o.cancellation_cause = 'replaced_by_private' then
      -- Decision 116(a): an empty class replaced by a private. Nothing when the
      -- displaced coach teaches the private (they are paid for the private); the
      -- flex standby amount for a flex class; the core holding fee otherwise.
      if exists (select 1 from class_occurrences pv
                  where pv.replaces_occurrence_id = o.id and pv.status <> 'cancelled'
                    and pv.instructor_id = o.instructor_id) then
        v_amount := 0;
      elsif g.tier = 'flex' then
        v_amount := coalesce(s.flex_unmet_pay_cents, 0);
      else
        v_amount := coalesce(s.core_unmet_pay_cents,
                             (rv.base_rate_cents * coalesce(s.core_unmet_pay_pct, 0)) / 100);
      end if;
      v_basis := jsonb_build_object('kind', 'group', 'outcome', 'replaced_by_private',
        'tier', g.tier, 'cause', o.cancellation_cause, 'base_cents', rv.base_rate_cents);
    else
      v_amount := case o.cancellation_cause
        when 'studio_fault'  then rv.base_rate_cents
        when 'force_majeure' then 0
        when 'closure' then case when coalesce(o.cancellation_pays, false)
                                 then rv.base_rate_cents else 0 end
        else 0 end;
      v_basis := jsonb_build_object('kind', 'group', 'outcome', 'cancelled',
        'cause', o.cancellation_cause, 'base_cents', rv.base_rate_cents,
        'closure_pays', o.cancellation_pays);
    end if;
  end if;

  return jsonb_build_object('ok', true, 'amount_cents', v_amount,
    'currency', rv.currency, 'rate_version_id', rv.id,
    'instructor_id', o.instructor_id, 'local_date', v_local, 'basis', v_basis);
end $function$;

CREATE OR REPLACE FUNCTION public.instructor_digest_block(p_studio_id uuid, p_instructor_id uuid, p_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_tz text; v_fmt text;
  th text := 'style="text-align:left;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;font-size:12px;font-weight:600;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4"';
  td text := 'style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4"';
  v_run_rows text; v_run_text text; v_can_rows text; v_can_text text;
  v_n_run int; v_n_can int; v_go_html text; v_go_text text; v_ca_html text; v_ca_text text;
begin
  select timezone into v_tz from studios where id = p_studio_id;
  v_fmt := coalesce((select time_format from studio_settings where studio_id = p_studio_id), '24h');

  -- Going ahead: the instructor's committed, still-scheduled classes that day.
  select count(*),
         string_agg('<tr><td ' || td || '>' || fmt_clock(o.starts_at, v_tz, v_fmt)
                    || '</td><td ' || td || '>' || coalesce(o.name, ct.name, 'a class')
                    || '</td><td ' || td || '>' || coalesce(o.booked_at_cutoff, o.booked_count) || ' of ' || o.capacity
                    || '</td></tr>', '' order by o.starts_at),
         string_agg('  ' || fmt_clock(o.starts_at, v_tz, v_fmt) || '  '
                    || coalesce(o.name, ct.name, 'a class') || '  '
                    || coalesce(o.booked_at_cutoff, o.booked_count) || ' of ' || o.capacity, E'\n' order by o.starts_at)
    into v_n_run, v_run_rows, v_run_text
    from class_occurrences o
    left join class_types ct on ct.id = o.class_type_id
    -- Decision 21 amendment: an always-runs occurrence commits at START, so the
    -- morning before class its committed_at is still null. It is going ahead all
    -- the same; a core class is too. Treat effective tier core or always as
    -- Running, exactly as a committed class.
    cross join lateral occurrence_guarantee_run(o.id) g
   where o.studio_id = p_studio_id and o.instructor_id = p_instructor_id
     and (o.starts_at at time zone v_tz)::date = p_date
     and o.status = 'scheduled'
     and (o.committed_at is not null or g.tier in ('core', 'always'));

  -- Cancelled for want of bookings: unmet_minimum cancellations that day. The
  -- minimum comes from the occurrence's own guarantee.
  select count(*),
         string_agg('<tr><td ' || td || '>' || fmt_clock(o.starts_at, v_tz, v_fmt)
                    || '</td><td ' || td || '>' || coalesce(o.name, ct.name, 'a class')
                    || '</td><td ' || td || '>'
                    || case when o.cancellation_cause = 'replaced_by_private' then 'Replaced by a private session'
                            else o.booked_at_cutoff || ' of ' || coalesce(g.minimum, 0) || ' needed' end
                    || '</td></tr>', '' order by o.starts_at),
         string_agg('  ' || fmt_clock(o.starts_at, v_tz, v_fmt) || '  '
                    || coalesce(o.name, ct.name, 'a class') || '  '
                    || case when o.cancellation_cause = 'replaced_by_private' then 'Replaced by a private session'
                            else o.booked_at_cutoff || ' of ' || coalesce(g.minimum, 0) || ' needed' end, E'\n' order by o.starts_at)
    into v_n_can, v_can_rows, v_can_text
    from class_occurrences o
    left join class_types ct on ct.id = o.class_type_id
    cross join lateral occurrence_guarantee_run(o.id) g
   where o.studio_id = p_studio_id and o.instructor_id = p_instructor_id
     and (o.starts_at at time zone v_tz)::date = p_date
     and o.status = 'cancelled' and o.cancellation_cause in ('unmet_minimum', 'replaced_by_private');

  v_n_run := coalesce(v_n_run, 0); v_n_can := coalesce(v_n_can, 0);

  if v_n_run > 0 then
    v_go_html := '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:12px 0;border-collapse:collapse">'
      || '<tr><td colspan="3" style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;color:#14170E;padding:0 0 6px 0">Running</td></tr>'
      || '<tr><th ' || th || '>Time</th><th ' || th || '>Class</th><th ' || th || '>Booked</th></tr>'
      || v_run_rows || '</table>';
    v_go_text := 'Running' || E'\n' || v_run_text;
  else
    v_go_html := '<p style="margin:12px 0">Nothing running.</p>';
    v_go_text := 'Nothing running.';
  end if;

  if v_n_can > 0 then
    v_ca_html := '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:12px 0;border-collapse:collapse">'
      || '<tr><td colspan="3" style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;color:#14170E;padding:0 0 6px 0">Cancelled, not enough bookings</td></tr>'
      || '<tr><th ' || th || '>Time</th><th ' || th || '>Class</th><th ' || th || '>Booked</th></tr>'
      || v_can_rows || '</table>';
    v_ca_text := 'Cancelled, not enough bookings' || E'\n' || v_can_text;
  else
    v_ca_html := '<p style="margin:12px 0">Nothing cancelled.</p>';
    v_ca_text := 'Nothing cancelled.';
  end if;

  return jsonb_build_object(
    'n_running', v_n_run, 'n_cancelled', v_n_can,
    'day', to_char(p_date, 'FMDay FMDD FMMonth'),
    'going_ahead', v_go_html, 'going_ahead_text', v_go_text,
    'cancelled', v_ca_html, 'cancelled_text', v_ca_text);
end $function$;


-- ========================================================================
-- Decision 22(e): schedule_range and flex_pending carry the latch and counts
-- ========================================================================
drop function if exists schedule_range(uuid, date, date);
CREATE FUNCTION public.schedule_range(p_studio_id uuid, p_from date, p_to date)
 RETURNS TABLE(occ_id uuid, occ_name text, starts_at timestamp with time zone, ends_at timestamp with time zone, local_date date, local_start text, local_end text, start_minutes integer, end_minutes integer, occ_instructor_id uuid, room_name text, occ_capacity integer, occ_booked integer, occ_waitlist integer, occ_staffing text, occ_status text, occ_flex boolean, occ_confirmed boolean, occ_tier text, occ_standalone boolean, occ_series_tier text, occ_minimum integer, occ_cancellation_cause text, occ_assignment_requested boolean, occ_assignment_confirmed boolean, occ_free_first jsonb, occ_hidden boolean, occ_is_private boolean, occ_reached_minimum boolean, occ_paid_count integer, occ_unpaid_count integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_tz text; v_ff boolean;
begin
  if not coalesce(is_manager_up(p_studio_id), false) and not is_service_context() then
    raise exception 'the timetable is the owner''s and managers'' to see'
      using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  if v_tz is null then
    raise exception 'no such studio' using errcode = 'PT404';
  end if;
  if p_to < p_from then
    raise exception 'that range ends before it starts' using errcode = 'PT400';
  end if;
  if p_to - p_from > 62 then
    raise exception 'ask for at most 62 days at a time' using errcode = 'PT422';
  end if;

  -- Decision 30 amendment (b) follow-up: only compute the per-class free-first
  -- state when the studio uses the feature — otherwise it is null and the popup
  -- card and the "Trials" marker are hidden.
  select free_first_class_enabled into v_ff from studio_settings where studio_id = p_studio_id;

  return query
  select o.id, o.name, o.starts_at, o.ends_at,
         (o.starts_at at time zone v_tz)::date,
         to_char(o.starts_at at time zone v_tz, 'HH24:MI'),
         to_char(o.ends_at   at time zone v_tz, 'HH24:MI'),
         (extract(hour from o.starts_at at time zone v_tz) * 60
          + extract(minute from o.starts_at at time zone v_tz))::int,
         (extract(hour from o.ends_at at time zone v_tz) * 60
          + extract(minute from o.ends_at at time zone v_tz))::int,
         o.instructor_id, r.name, o.capacity, o.booked_count, o.waitlist_count,
         o.staffing::text, o.status::text,
         o.flex, o.committed_at is not null,
         g.tier::text,
         (g.tier = 'flex' and not occurrence_is_adjacent_run(o.id)),
         coalesce(
           o.guarantee_tier,
           case when o.flex then 'flex'::guarantee_tier end,
           ser.guarantee_tier,
           case when ser.flex then 'flex'::guarantee_tier end,
           'core'::guarantee_tier)::text,
         g.minimum,
         o.cancellation_cause::text,
         o.assignment_requested_at is not null,
         o.assignment_confirmed_at is not null,
         case when coalesce(v_ff, false) then effective_free_first(o.id) else null end,
         o.hidden_from_members,
         coalesce(o.is_private, false),
         -- Decision 22(e): the running latch and the count it uses (paid seats;
         -- an unpaid drop-in does not count, Decision 81b), plus the unpaid seats.
         o.flex_reached_minimum_at is not null,
         pc.paid, pc.unpaid
    from class_occurrences o
    cross join lateral (
      select count(*) filter (where not unpaid_dropin)::int as paid,
             count(*) filter (where unpaid_dropin)::int as unpaid
        from (select coalesce(b.payment_source = 'drop_in', false)
                     and not exists (select 1 from payments pmt
                                      where pmt.booking_id = b.id
                                        and pmt.status in ('succeeded','partially_refunded')) as unpaid_dropin
                from bookings b
               where b.occurrence_id = o.id
                 and b.status in ('booked','attended','no_show','pending_payment')) bb) pc
    cross join lateral occurrence_guarantee_run(o.id) g
    left join class_series ser on ser.id = o.series_id
    left join rooms r on r.id = o.room_id
   where o.studio_id = p_studio_id
     and (o.status <> 'cancelled'
          or (not coalesce(o.is_private, false)
              and o.cancellation_cause in ('unmet_minimum','no_instructor','studio_fault','force_majeure','replaced_by_private')))
     and (o.starts_at at time zone v_tz)::date between p_from and p_to
   order by o.starts_at;
end $function$;

revoke execute on function schedule_range(uuid, date, date) from public, anon;
grant execute on function schedule_range(uuid, date, date) to authenticated, service_role;

drop function if exists flex_pending(uuid);
CREATE FUNCTION public.flex_pending(p_studio_id uuid)
 RETURNS TABLE(occ_id uuid, occ_name text, starts_at timestamp with time zone, local_when text, booked integer, minimum integer, short_by integer, due_at timestamp with time zone, past_due boolean, reached_minimum boolean, paid_count integer, unpaid_count integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- DEPRECATED: commitment_pending() is the one to call. This exists only so
  -- the existing flex screen does not break in the same migration that changes
  -- what it is a view of.
  -- Decision 22(e): the latch and the paid / unpaid counts for the state chip.
  select cp.occ_id, cp.occ_name, cp.starts_at, cp.local_when, cp.booked, cp.minimum, cp.short_by,
         cp.due_at, cp.past_due,
         (o.flex_reached_minimum_at is not null or o.committed_at is not null),
         (select count(*)::int from bookings b where b.occurrence_id = cp.occ_id
             and b.status in ('booked','attended','no_show','pending_payment')
             and not (coalesce(b.payment_source = 'drop_in', false)
                      and not exists (select 1 from payments pmt where pmt.booking_id = b.id
                                        and pmt.status in ('succeeded','partially_refunded')))),
         (select count(*)::int from bookings b where b.occurrence_id = cp.occ_id
             and b.status in ('booked','attended','no_show','pending_payment')
             and coalesce(b.payment_source = 'drop_in', false)
             and not exists (select 1 from payments pmt where pmt.booking_id = b.id
                               and pmt.status in ('succeeded','partially_refunded')))
    from commitment_pending(p_studio_id) cp
    join class_occurrences o on o.id = cp.occ_id
   where cp.tier = 'flex';
$function$;

revoke execute on function flex_pending(uuid) from public, anon;
grant execute on function flex_pending(uuid) to authenticated, service_role;

-- ========================================================================
-- Decision 21(c): apply the flex minimum to future classes
-- ========================================================================
create or replace function flex_minimum_mismatch_count(p_studio_id uuid)
returns integer language plpgsql stable security definer set search_path = public as $$
declare v_min int; n int;
begin
  if not coalesce(is_manager_up(p_studio_id), false) and not is_service_context() then
    raise exception 'only owners and managers change the timetable' using errcode = 'PT403';
  end if;
  select coalesce(flex_min_bookings, 1) into v_min from studio_settings where studio_id = p_studio_id;
  select count(*)::int into n
    from class_occurrences o
    cross join lateral occurrence_guarantee_run(o.id) g
   where o.studio_id = p_studio_id and o.status = 'scheduled'
     and not coalesce(o.is_private, false)
     and o.starts_at > now() and o.committed_at is null
     and g.tier = 'flex' and (g.cutoff_at is null or g.cutoff_at > now())
     and g.minimum is distinct from v_min;
  return coalesce(n, 0);
end $$;
revoke execute on function flex_minimum_mismatch_count(uuid) from public, anon;
grant execute on function flex_minimum_mismatch_count(uuid) to authenticated, service_role;

create or replace function apply_flex_minimum_to_future(p_studio_id uuid, p_min integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n_series int; n_classes int; n_committed int; n_cut int;
begin
  if not coalesce(is_manager_up(p_studio_id), false) and not is_service_context() then
    raise exception 'only owners and managers change the timetable' using errcode = 'PT403';
  end if;
  if p_min is null or p_min < 1 then
    raise exception 'a flex minimum is at least 1' using errcode = 'PT422';
  end if;

  update class_series set minimum_bookings = p_min, updated_at = now()
   where studio_id = p_studio_id and status = 'active'
     and (coalesce(flex, false) or guarantee_tier = 'flex')
     and minimum_bookings is distinct from p_min;
  get diagnostics n_series = row_count;

  -- one filtered pass: future flex classes not committed and not past the cut-off
  update class_occurrences o set minimum_bookings = p_min, updated_at = now()
    from (select o2.id from class_occurrences o2
            cross join lateral occurrence_guarantee_run(o2.id) g
           where o2.studio_id = p_studio_id and o2.status = 'scheduled'
             and not coalesce(o2.is_private, false)
             and o2.starts_at > now() and o2.committed_at is null
             and g.tier = 'flex' and (g.cutoff_at is null or g.cutoff_at > now())
             and g.minimum is distinct from p_min) t
   where o.id = t.id;
  get diagnostics n_classes = row_count;

  select count(*) filter (where o.committed_at is not null)::int,
         count(*) filter (where o.committed_at is null and g.cutoff_at is not null and g.cutoff_at <= now())::int
    into n_committed, n_cut
    from class_occurrences o cross join lateral occurrence_guarantee_run(o.id) g
   where o.studio_id = p_studio_id and o.status = 'scheduled'
     and not coalesce(o.is_private, false) and o.starts_at > now() and g.tier = 'flex';

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (p_studio_id, auth.uid(), 'flex.minimum_applied', 'studios', p_studio_id,
          jsonb_build_object('minimum', p_min, 'series_updated', n_series,
                             'classes_updated', n_classes,
                             'left_committed', coalesce(n_committed, 0),
                             'left_past_cutoff', coalesce(n_cut, 0)));
  return jsonb_build_object('ok', true, 'series_updated', n_series, 'classes_updated', n_classes,
                            'left_committed', coalesce(n_committed, 0), 'left_past_cutoff', coalesce(n_cut, 0));
end $$;
revoke execute on function apply_flex_minimum_to_future(uuid, integer) from public, anon;
grant execute on function apply_flex_minimum_to_future(uuid, integer) to authenticated, service_role;

-- Saving the guarantee and flex settings writes an audit row with before and after.
create or replace function tg_audit_guarantee_settings()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_before jsonb; v_after jsonb;
  k text[] := array['guarantees_enabled','flex_enabled','core_min_bookings','core_cutoff_hours',
    'core_unmet_pay_pct','core_unmet_pay_cents','flex_min_bookings','flex_deadline_mode',
    'flex_deadline_time','flex_deadline_hours','flex_unmet_pay_cents','flex_standby_pay_cents',
    'flex_rescue_hours_before','adjacency_minutes','private_replace_core_hours'];
  c text;
begin
  v_before := '{}'::jsonb; v_after := '{}'::jsonb;
  foreach c in array k loop
    if (to_jsonb(old) -> c) is distinct from (to_jsonb(new) -> c) then
      v_before := v_before || jsonb_build_object(c, to_jsonb(old) -> c);
      v_after  := v_after  || jsonb_build_object(c, to_jsonb(new) -> c);
    end if;
  end loop;
  if v_after <> '{}'::jsonb then
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
    values (new.studio_id, auth.uid(), 'settings.guarantees_saved', 'studio_settings', new.studio_id,
            v_before, v_after);
  end if;
  return new;
end $$;
revoke execute on function tg_audit_guarantee_settings() from public, anon, authenticated;
drop trigger if exists studio_settings_audit_guarantees on studio_settings;
create trigger studio_settings_audit_guarantees after update on studio_settings
  for each row execute function tg_audit_guarantee_settings();

-- ========================================================================
-- Decision 18(b): a month's submission is not the weekly pattern
-- ========================================================================
CREATE OR REPLACE FUNCTION public.instructor_availability_week(p_instructor_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_studio uuid;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then
    -- Not "no such instructor". A caller who may not read this must not be able
    -- to use the error to find out whether an id exists.
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;
  if not is_manager_up(v_studio)
     and p_instructor_id is distinct from auth_instructor_id(v_studio)
     and not is_service_context() then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;

  return (select jsonb_build_object(
    'days', (
      select coalesce(jsonb_agg(jsonb_build_object('day', dow, 'ranges', ranges) order by dow), '[]'::jsonb)
        from (
          select a.day_of_week as dow,
                 jsonb_agg(jsonb_build_object(
                   'from', to_char(a.starts_at_time, 'HH24:MI'),
                   'to',   to_char(a.ends_at_time,   'HH24:MI'))
                   order by a.starts_at_time) as ranges
            from instructor_availability a
           where a.instructor_id = p_instructor_id
             and a.day_of_week is not null and a.is_available
             and a.submission_id is null
           group by a.day_of_week
        ) g),
    'effective_from', (select min(effective_from) from instructor_availability
                        where instructor_id = p_instructor_id and day_of_week is not null
                          and submission_id is null),
    'effective_to',   (select max(effective_to) from instructor_availability
                        where instructor_id = p_instructor_id and day_of_week is not null
                          and submission_id is null),
    'exceptions', (
      select coalesce(jsonb_agg(e order by e ->> 'date'), '[]'::jsonb) from (
        select jsonb_build_object(
                 'date', a.exception_date,
                 'available', bool_or(a.is_available),
                 'note', min(a.note),
                 'ranges', coalesce(jsonb_agg(jsonb_build_object(
                     'from', to_char(a.starts_at_time, 'HH24:MI'),
                     'to',   to_char(a.ends_at_time,   'HH24:MI'))
                     order by a.starts_at_time)
                     filter (where a.starts_at_time is not null), '[]'::jsonb)) as e
          from instructor_availability a
         where a.instructor_id = p_instructor_id and a.exception_date is not null
         group by a.exception_date
      ) x)
  ));
end $function$;

CREATE OR REPLACE FUNCTION public.set_instructor_availability_rows(p_instructor_id uuid, p_days jsonb, p_effective_from date DEFAULT NULL::date, p_effective_to date DEFAULT NULL::date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_studio uuid; v_tz text;
  v_from   date := p_effective_from;
  v_to     date := p_effective_to;
  d        jsonb; r jsonb; v_day int; n int := 0;
  v_name text; v_user uuid; v_lines text; v_count int; v_fp text;
  v_before jsonb;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then
    raise exception 'no such instructor' using errcode = 'PT404';
  end if;
  if not is_manager_up(v_studio)
     and p_instructor_id is distinct from auth_instructor_id(v_studio) then
    raise exception 'only the studio or the instructor may set their availability'
      using errcode = 'PT403';
  end if;
  if v_to is not null and v_from is not null and v_to < v_from then
    raise exception 'the pattern ends before it starts' using errcode = 'PT422';
  end if;

  -- Decision 46: under "no availability means not available", a standing pattern
  -- must carry an end date — the studio checks month by month, so an open-ended
  -- row (which counts as available forever) is the opposite of that.
  if v_to is null
     and coalesce((select ss.assign_requires_availability from studio_settings ss
                    where ss.studio_id = v_studio), false) then
    raise exception 'Give this pattern an end date — the studio checks availability month by month.'
      using errcode = 'PT400';
  end if;

  -- Decision 18(b): the before ranges for the audit row, and the delete restricted
  -- to the weekly pattern. A month's submission rows (submission_id set) are never
  -- part of the pattern and never deleted by a pattern save.
  select jsonb_agg(jsonb_build_object('day', day_of_week,
           'from', to_char(starts_at_time, 'HH24:MI'), 'to', to_char(ends_at_time, 'HH24:MI'),
           'effective_from', effective_from, 'effective_to', effective_to)
           order by day_of_week, starts_at_time)
    into v_before
    from instructor_availability
   where instructor_id = p_instructor_id and day_of_week is not null and submission_id is null;

  delete from instructor_availability
   where instructor_id = p_instructor_id
     and day_of_week is not null
     and submission_id is null
     and day_of_week in (
       select (x ->> 'day')::int from jsonb_array_elements(p_days) x);

  for d in select * from jsonb_array_elements(p_days) loop
    v_day := (d ->> 'day')::int;
    if v_day is null or v_day < 0 or v_day > 6 then
      raise exception 'day_of_week must be 0-6, got %', d ->> 'day' using errcode = 'PT422';
    end if;
    for r in select * from jsonb_array_elements(coalesce(d -> 'ranges', '[]'::jsonb)) loop
      if (r ->> 'to')::time <= (r ->> 'from')::time then
        raise exception 'a range must end after it starts (day %, % to %)',
          v_day, r ->> 'from', r ->> 'to' using errcode = 'PT422';
      end if;
      insert into instructor_availability
        (studio_id, instructor_id, day_of_week, starts_at_time, ends_at_time,
         effective_from, effective_to, is_available, created_by)
      values (v_studio, p_instructor_id, v_day,
              (r ->> 'from')::time, (r ->> 'to')::time,
              v_from, v_to, true, auth.uid());
      n := n + 1;
    end loop;
  end loop;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (v_studio, auth.uid(), 'availability.set', 'instructors', p_instructor_id,
          jsonb_build_object('ranges', coalesce(v_before, '[]'::jsonb)),
          jsonb_build_object('days', p_days, 'effective_from', v_from,
                             'effective_to', v_to, 'ranges_written', n));

  -- B: what the new pattern leaves stranded — future classes the instructor is
  -- STILL assigned to but is no longer available for (studio-local time in the
  -- lines). instructor_available_at reads the new pattern (and honours an
  -- approved month submission, which wins for its days), so a class covered by
  -- an approved submission is not counted.
  select timezone into v_tz from studios where id = v_studio;
  select count(*)::int,
         string_agg('  ' || to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMon, HH24:MI')
                    || ' — ' || o.name, E'\n' order by o.starts_at),
         md5(string_agg(o.id::text, ',' order by o.id))
    into v_count, v_lines, v_fp
    from class_occurrences o
   where o.studio_id = v_studio and o.instructor_id = p_instructor_id
     and o.status = 'scheduled' and o.starts_at > now()
     and not instructor_available_at(p_instructor_id, o.starts_at, o.ends_at);

  if coalesce(v_count, 0) > 0 then
    select display_name into v_name from instructors where id = p_instructor_id;
    v_user := instructor_user_id(p_instructor_id);
    if v_user is not null then
      perform queue_shift_notice(v_studio, v_user, 'availability_narrowed_instructor',
        jsonb_build_object('instructor_name', coalesce(v_name, 'there'),
          'count', v_count, 'plural', case when v_count = 1 then '' else 'es' end,
          'lines', v_lines),
        'avail_narrowed_i:' || p_instructor_id || ':' || v_fp);
    end if;
    perform queue_shift_notice_to_staff(v_studio, 'availability_narrowed_staff',
      jsonb_build_object('instructor_name', coalesce(v_name, 'An instructor'),
        'count', v_count, 'plural', case when v_count = 1 then '' else 'es' end,
        'lines', v_lines),
      'avail_narrowed_s:' || p_instructor_id || ':' || v_fp);
  end if;

  return n;
end $function$;

CREATE OR REPLACE FUNCTION public.instructor_available_at_run(p_instructor_id uuid, p_starts_at timestamp with time zone, p_ends_at timestamp with time zone)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_studio uuid; v_tz text; v_date date; v_dow int; v_from time; v_to time;
        v_sub uuid; v_strict boolean;
begin
  if p_instructor_id is null then
    return true;
  end if;

  select i.studio_id, s.timezone into v_studio, v_tz
    from instructors i join studios s on s.id = i.studio_id
   where i.id = p_instructor_id;
  if v_studio is null then
    return false;
  end if;

  v_date := (p_starts_at at time zone v_tz)::date;
  v_dow  := extract(dow from (p_starts_at at time zone v_tz))::int;
  v_from := (p_starts_at at time zone v_tz)::time;
  v_to   := (p_ends_at   at time zone v_tz)::time;

  -- 1. An explicit exception for that date wins over everything.
  if exists (select 1 from instructor_availability a
              where a.instructor_id = p_instructor_id and a.exception_date = v_date) then
    return exists (
      select 1 from instructor_availability a
       where a.instructor_id = p_instructor_id
         and a.exception_date = v_date
         and a.is_available
         and (a.starts_at_time is null or a.starts_at_time <= v_from)
         and (a.ends_at_time   is null or a.ends_at_time   >= v_to));
  end if;

  -- 2. An APPROVED submission whose month covers this date answers for it alone.
  select s.id into v_sub
    from availability_submissions s
   where s.instructor_id = p_instructor_id
     and s.status = 'approved'
     and v_date between s.period_start
                    and (s.period_start + interval '1 month' - interval '1 day')::date
   order by s.period_start desc
   limit 1;

  if v_sub is not null then
    return exists (
      select 1 from instructor_availability a
       where a.submission_id = v_sub
         and a.day_of_week = v_dow
         and a.approval_status = 'approved'
         and a.is_available
         and (a.starts_at_time is null or a.starts_at_time <= v_from)
         and (a.ends_at_time   is null or a.ends_at_time   >= v_to));
  end if;

  -- 3. No stated availability is not the same as being unavailable — UNLESS the
  --    studio has turned on "no availability means not available" (Decision 46),
  --    in which case an instructor with nothing on file falls through to step 4
  --    (the standing pattern) and, having none, is not available.
  select coalesce(ss.assign_requires_availability, false) into v_strict
    from studio_settings ss where ss.studio_id = v_studio;
  if not v_strict then
    if not exists (select 1 from instructor_availability a
                    where a.instructor_id = p_instructor_id
                      and a.day_of_week is not null
                      and a.submission_id is null
                      and a.approval_status = 'approved') then
      return true;
    end if;
  end if;

  -- 4. The standing weekly pattern (already bounded on effective_from/to).
  return exists (
    select 1 from instructor_availability a
     where a.instructor_id = p_instructor_id
       and a.day_of_week = v_dow
       and a.submission_id is null
       and a.approval_status = 'approved'
       and a.is_available
       and (a.effective_from is null or a.effective_from <= v_date)
       and (a.effective_to   is null or a.effective_to   >= v_date)
       and (a.starts_at_time is null or a.starts_at_time <= v_from)
       and (a.ends_at_time   is null or a.ends_at_time   >= v_to));
end $function$;


-- ========================================================================
-- Templates: private_time_taken (member), private_replaced_class (coach)
-- ========================================================================
insert into notification_templates (key, subject, text_body, html_body, note) values
('private_time_taken', 'That time was just taken',
 E'Hi {first_name},\n\nThat time was just taken. Pick another time. Someone booked the class in that slot before your {type_name} on {when} could be confirmed. {refund_line}\n\nPick another time: {book_url}',
 '<p>Hi {first_name},</p>
<p>That time was just taken. Pick another time. Someone booked the class in that slot before your <strong>{type_name}</strong> on {when} could be confirmed. {refund_line}</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{{book_url}}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Pick another time</a></td></tr></table>
<p>{studio_name}</p>',
 'Decision 116(a): a replacing private refused at confirm.'),
('private_replaced_class', '{class_name} on {when} is replaced by a private session',
 E'Hi {first_name},\n\nNobody had booked {class_name} on {when}, so it has been replaced by a private session ({type_name}) and taken off your schedule. {pay_line}\n\nSee my schedule: {schedule_url}',
 '<p>Hi {first_name},</p>
<p>Nobody had booked <strong>{class_name}</strong> on {when}, so it has been replaced by a private session ({type_name}) and taken off your schedule. {pay_line}</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{{schedule_url}}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">See my schedule</a></td></tr></table>
<p>{studio_name}</p>',
 'Decision 116(a): the coach of an empty class a private replaced.')
on conflict (key) do update set subject = excluded.subject, text_body = excluded.text_body,
  html_body = excluded.html_body, note = excluded.note;

insert into notification_templates_overrides (studio_id, key, subject, body, body_html, updated_at)
select s.id, v.key, v.subject, v.body, v.body_html, now()
  from studios s
  cross join (values
  ('private_time_taken', 'That time was just taken',
   E'Hi {first_name},\n\nThat time was just taken. Pick another time. Someone booked the class in that slot before your {type_name} on {when} could be confirmed. {refund_line}\n\nPick another time: {book_url}\n\nSee you at the reformer!🎀\nRPC Studio',
   '<p>Hi {first_name},</p>
<p>That time was just taken. Pick another time. Someone booked the class in that slot before your <strong>{type_name}</strong> on {when} could be confirmed. {refund_line}</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{{book_url}}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Pick another time</a></td></tr></table>
<p>See you at the reformer!🎀<br>RPC Studio</p>'),
  ('private_replaced_class', '{class_name} on {when} is replaced by a private session',
   E'Hi Coach {first_name},\n\nNobody had booked {class_name} on {when}, so it has been replaced by a private session ({type_name}) and taken off your schedule. {pay_line}\n\nSee my schedule: {schedule_url}\n\nThank you!\nRPC Studio',
   '<p>Hi Coach {first_name},</p>
<p>Nobody had booked <strong>{class_name}</strong> on {when}, so it has been replaced by a private session ({type_name}) and taken off your schedule. {pay_line}</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{{schedule_url}}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">See my schedule</a></td></tr></table>
<p>Thank you!<br>RPC Studio</p>')
  ) as v(key, subject, body, body_html)
 where s.slug in ('reform', 'reformcollective')
on conflict (studio_id, key) do update set subject = excluded.subject, body = excluded.body,
  body_html = excluded.body_html, updated_at = now();

-- ========================================================================
-- Anon stays EXACTLY FOURTEEN; the new functions are not anon.
-- ========================================================================
do $mig$ declare n int; begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'expect\_%';
  if n <> 14 then raise exception 'anon surface is % (want 14)', n; end if;
end $mig$;
