-- creates: email_markup_text(text), my_private_credits(uuid), set_member_test_account(uuid, boolean), tg_plan_private_type_default(), tg_member_tasks_skip_test(), private_pack_consume(uuid, uuid, uuid), discount_code_validate_batch_run(uuid, text, int, date, date, uuid[], boolean, uuid[]), discount_code_create_batch(uuid, text, int, int, date, date, uuid[], boolean, uuid[]), discount_code_create_shared(uuid, text, text, int, date, date, uuid[], int, boolean, uuid[]), discount_code_preview(uuid, text, uuid, uuid, uuid, uuid, int), xendit_begin_product_purchase(uuid, uuid, int, text), record_product_sale(uuid, uuid, int, uuid, text, text, text, text)
-- re-issues: private_book_run(uuid, uuid, uuid, timestamptz, jsonb, text, text, text, text), private_refund_run(uuid), discount_code_check_run(uuid, text, uuid, boolean, uuid, text, int, timestamptz), tg_payment_discount_code_fill(), plan_buy_begin(uuid, uuid, text, text, text, text, boolean), record_refund(uuid, int, text, boolean), refund_payment_run(uuid, int, text, text, text), render_email(uuid, text, text, text, text, text, jsonb, text, text), reservation_fee_terms(uuid, uuid), apply_free_fee_choice(uuid, text, text), book_first_free(uuid, uuid, text, text), convert_booking_to_free_first(uuid, text, text), checkout_rescue_run(uuid, timestamptz, boolean), core_classes_for_rescue(uuid, uuid), notification_wanted(uuid, text), campaign_audience(uuid, jsonb), dashboard_kpis(uuid), daily_money_check(uuid), write_reservation_credit(uuid)
--
-- Step 13 (26 Nov 2026). Decisions 116 (d), 80 (f), 103 (l), 97 (b), 119 (a),
-- 95 (c), 120 (a) and 120 (b), plus two Reform override edits.
--
-- 116 (d): a private pack names the session type it is for
--   (membership_plans.private_session_type_id, required when private_pack,
--   filled with the studio's one-person type when left blank). A pack credit is
--   spent only on its own type; refunds, moves and studio cancellations return
--   it to the same pack (private_refund_run already returns to b.membership_id).
--   Reform's 5 and 10 session packs are set to "Private 1:1".
-- 80 (f): overrides keep a plain-text rendering (body_text, filled once here by
--   email_markup_text, the SQL port of renderBody's text path); render_email
--   uses it, renders any markup left in the text part, and pairs {x_line} /
--   {x_html} so neither part loses a line. preview_template renders through
--   render_email, so it takes the same rule with no re-issue.
-- 103 (l): a staff free-first booking whose member's credit covers the fee is
--   credit-covered automatically (no due row, no nudge, no choice).
-- 97 (b): members.is_test_account, excluded from campaigns, sequences, rescue,
--   audience counts, dashboard member counts, the daily check's member items and
--   retention tasks. Transactional emails still send. No members export exists.
-- 119 (a): a private session checkout gets a rescue email; the reservation
--   rescue's full or past version has its own subject.
-- 95 (c): rescue labels read "Needs 1 more to run" / "Needs 2 more to run".
-- 120 (a): a code may be 100% off; at 0 the purchase completes through the
--   full-credit path with no Xendit session, and a 0 payment can be refunded.
-- 120 (b): a code may name shop items; the shop checkout and the desk sale take it.
--
-- NO NEW ANON FUNCTION. The anon surface stays exactly fifteen.


-- ===================================================================== 116 (d)
alter table membership_plans add column if not exists private_session_type_id uuid
  references private_session_types(id) on delete restrict;

create or replace function tg_plan_private_type_default()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(new.private_pack, false) then
    new.private_session_type_id := null;
  elsif new.private_session_type_id is null then
    select t.id into new.private_session_type_id from private_session_types t
     where t.studio_id = new.studio_id
     order by (t.people <> 1), t.active desc, t.people, t.sort, t.created_at limit 1;
  end if;
  return new;
end $$;
revoke execute on function tg_plan_private_type_default() from public, anon, authenticated;
grant  execute on function tg_plan_private_type_default() to service_role;
drop trigger if exists membership_plans_private_type on membership_plans;
create trigger membership_plans_private_type before insert or update of private_pack, private_session_type_id
  on membership_plans for each row execute function tg_plan_private_type_default();

-- Reform's 5 and 10 session packs are for "Private 1:1".
update membership_plans p set private_session_type_id = t.id
  from studios s, private_session_types t
 where s.id = p.studio_id and s.slug = 'reformcollective' and t.studio_id = s.id
   and t.name = 'Private 1:1' and p.private_pack;
-- Every other pack takes its studio's one-person type.
update membership_plans p set private_session_type_id = (
    select t.id from private_session_types t where t.studio_id = p.studio_id
     order by (t.people <> 1), t.active desc, t.people, t.sort, t.created_at limit 1)
 where p.private_pack and p.private_session_type_id is null;

alter table membership_plans drop constraint if exists membership_plans_private_type_needed;
alter table membership_plans add constraint membership_plans_private_type_needed
  check (not private_pack or private_session_type_id is not null) not valid;
do $$ begin
  if not exists (select 1 from membership_plans where private_pack and private_session_type_id is null) then
    alter table membership_plans validate constraint membership_plans_private_type_needed;
  end if;
end $$;

drop function if exists private_pack_consume(uuid, uuid);
create or replace function private_pack_consume(p_member_id uuid, p_studio_id uuid, p_type_id uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare ms memberships%rowtype; v_bal int;
begin
  select m.* into ms from memberships m
    join membership_plans p on p.id = m.plan_id
   where m.member_id = p_member_id and m.studio_id = p_studio_id
     and p.private_pack and p.private_session_type_id = p_type_id
     and m.status in ('active', 'trialing')
     and coalesce(m.credits_remaining, 0) > 0
     and (m.expires_on is null or m.expires_on >= (now() at time zone (select timezone from studios where id = p_studio_id))::date)
   order by m.expires_on nulls last, m.created_at limit 1;
  if ms.id is null then return null; end if;
  v_bal := ms.credits_remaining - 1;
  insert into credit_ledger (studio_id, member_id, membership_id, delta, reason, balance_after)
  values (p_studio_id, p_member_id, ms.id, -1, 'booking', v_bal);
  update memberships set credits_remaining = v_bal where id = ms.id;
  return ms.id;
end $$;
revoke execute on function private_pack_consume(uuid, uuid, uuid) from public, anon, authenticated;
grant  execute on function private_pack_consume(uuid, uuid, uuid) to service_role;

CREATE OR REPLACE FUNCTION public.private_book_run(p_member_id uuid, p_type_id uuid, p_instructor_id uuid, p_starts_at timestamp with time zone, p_companions jsonb, p_mode text, p_method text DEFAULT NULL::text, p_reference text DEFAULT NULL::text, p_code text DEFAULT NULL::text)
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
  v_buf int; v_opt record; v_any_coach uuid;
  v_code jsonb; v_price int; v_use uuid;
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

  -- Decision 120: a code on the private session pay step, checked before
  -- anything is written.
  v_price := t.price_cents;
  if v_mode = 'xendit' and nullif(btrim(coalesce(p_code, '')), '') is not null then
    v_code := discount_code_check_run(v_studio, p_code, null, true, p_member_id, v_member.email,
                                      t.price_cents, now());
    if not (v_code ->> 'ok')::boolean then
      return jsonb_build_object('ok', false, 'reason', 'code', 'message', v_code ->> 'message');
    end if;
    v_price := (v_code ->> 'price_cents')::int;
  end if;

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

  -- Decision 116(a)/(b): a free room over [start - buffer, end + buffer] is used
  -- with any available private coach. With no free room, a room whose only class
  -- then is empty and replaceable (private_replace_ok) is used, and only with
  -- THAT class's own coach (116 b): no coach is ever displaced. A replacing
  -- private records the class and takes no room until it is confirmed; a pending
  -- replacement (room null) holds the room of the class it targets.
  v_buf := coalesce(ss.private_buffer_minutes, 10);
  select r.id into v_room
    from rooms r
    cross join lateral (
        select count(*) as n, (array_agg(o.id))[1] as rep, bool_and(o.starts_at = p_starts_at) as aligned
          from class_occurrences o
         where o.status <> 'cancelled'
           and (o.room_id = r.id
                or (o.room_id is null and o.replaces_occurrence_id in
                      (select x.id from class_occurrences x where x.room_id = r.id)))
           and tstzrange(o.starts_at, o.ends_at)
               && tstzrange(p_starts_at - make_interval(mins => v_buf),
                            v_ends + make_interval(mins => v_buf))) ov
   where r.studio_id = v_studio and r.status = 'active' and ov.n = 0
   order by r.name limit 1;

  if v_room is null then
    for v_opt in
      select r.id as rid, ov.rep,
             (select z.instructor_id from class_occurrences z where z.id = ov.rep) as rcoach
        from rooms r
        cross join lateral (
        select count(*) as n, (array_agg(o.id))[1] as rep, bool_and(o.starts_at = p_starts_at) as aligned
          from class_occurrences o
         where o.status <> 'cancelled'
           and (o.room_id = r.id
                or (o.room_id is null and o.replaces_occurrence_id in
                      (select x.id from class_occurrences x where x.room_id = r.id)))
           and tstzrange(o.starts_at, o.ends_at)
               && tstzrange(p_starts_at - make_interval(mins => v_buf),
                            v_ends + make_interval(mins => v_buf))) ov
       where r.studio_id = v_studio and r.status = 'active'
         and ov.n = 1 and ov.aligned and private_replace_ok(ov.rep, p_starts_at)
       order by r.name
    loop
      if v_any_coach is null then v_any_coach := v_opt.rcoach; end if;
      if v_opt.rcoach is not null
         and (p_instructor_id is null or v_opt.rcoach = p_instructor_id)
         and exists (select 1 from instructors i where i.id = v_opt.rcoach and i.status = 'active'
                       and coalesce(i.teaches_privates, false))
         and instructor_available_at_run(v_opt.rcoach, p_starts_at, v_ends)
         and not exists (select 1 from class_occurrences x where x.instructor_id = v_opt.rcoach
                           and x.status <> 'cancelled' and x.id <> v_opt.rep
                           and tstzrange(x.starts_at, x.ends_at) && tstzrange(p_starts_at, v_ends)) then
        v_room := v_opt.rid; v_rep := v_opt.rep; v_rep_coach := v_opt.rcoach;
        exit;
      end if;
    end loop;
    if v_room is null then
      -- the time is an empty class with another coach: name them
      if p_instructor_id is not null and v_any_coach is not null and v_any_coach <> p_instructor_id then
        raise exception 'That time is with %. Pick that coach or another time.',
          (select split_part(display_name, ' ', 1) from instructors where id = v_any_coach)
          using errcode = 'PT409', detail = 'private_coach_mismatch';
      end if;
      return jsonb_build_object('ok', false,
        'reason', case when v_any_coach is null then 'no_room' else 'coach_unavailable' end);
    end if;
    v_coach := v_rep_coach;
  elsif p_instructor_id is not null then
    -- a free room: the chosen coach
    if not exists (select 1 from instructors i where i.id = p_instructor_id and i.studio_id = v_studio
                    and i.status = 'active' and coalesce(i.teaches_privates, false))
       or not instructor_available_at_run(p_instructor_id, p_starts_at, v_ends) then
      return jsonb_build_object('ok', false, 'reason', 'coach_unavailable'); end if;
    if exists (select 1 from class_occurrences x where x.instructor_id = p_instructor_id
                 and x.status <> 'cancelled'
                 and tstzrange(x.starts_at, x.ends_at) && tstzrange(p_starts_at, v_ends)) then
      return jsonb_build_object('ok', false, 'reason', 'coach_busy'); end if;
    v_coach := p_instructor_id;
  else
    -- a free room, no coach chosen: the first available private coach
    select i.id into v_coach from instructors i
      where i.studio_id = v_studio and i.status = 'active' and coalesce(i.teaches_privates, false)
        and instructor_available_at_run(i.id, p_starts_at, v_ends)
        and not exists (select 1 from class_occurrences x where x.instructor_id = i.id
                          and x.status <> 'cancelled'
                          and tstzrange(x.starts_at, x.ends_at) && tstzrange(p_starts_at, v_ends))
      order by i.display_name limit 1;
    if v_coach is null then return jsonb_build_object('ok', false, 'reason', 'coach_unavailable'); end if;
  end if;

  select id into v_loc from locations where studio_id = v_studio and is_primary order by created_at limit 1;

  -- a Xendit private the member's account credit fully covers completes from credit
  -- Decision 120(a): a code that brings the price to 0 completes here too.
  if v_mode = 'xendit' and reservation_credit_available(v_studio, p_member_id) >= v_price then
    v_mode := 'credit';
  end if;
  if v_mode = 'credit' and reservation_credit_available(v_studio, p_member_id) < v_price then
    return jsonb_build_object('ok', false, 'reason', 'not_enough_credit'); end if;
  if v_mode = 'xendit' and not exists (select 1 from studio_payment_providers
       where studio_id = v_studio and provider = 'xendit') then
    return jsonb_build_object('ok', false, 'reason', 'no_provider'); end if;
  if v_mode = 'desk' and coalesce(p_method, '') not in ('cash','bank_transfer','card_terminal','gcash','other') then
    return jsonb_build_object('ok', false, 'reason', 'unknown_method'); end if;

  -- a pack resolves up front so a missing pack fails before creating anything
  if v_mode = 'pack' then
    -- Decision 116(d): a pack is spent only on its own session type.
    v_pack := private_pack_consume(p_member_id, v_studio, t.id);
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
    if v_code is not null then
      v_use := discount_code_hold_run(v_studio, (v_code ->> 'code_id')::uuid, (v_code ->> 'batch_id')::uuid,
                 p_member_id, v_member.email, null, v_occ, t.price_cents, t.price_cents - v_price);
    end if;
    insert into xendit_purchases (studio_id, member_id, private_occurrence_id, amount_cents, currency,
                                  list_price_cents, discount_cents, discount_code_use_id)
    values (v_studio, p_member_id, v_occ, v_price, v_ccy,
            case when v_use is not null then t.price_cents end,
            case when v_use is not null then t.price_cents - v_price end, v_use)
    returning id into v_purchase;
    update discount_code_uses set purchase_id = v_purchase where id = v_use;
    return jsonb_build_object('ok', true, 'occurrence_id', v_occ, 'confirmed', false,
      'purchase_id', v_purchase, 'amount_cents', v_price, 'currency', v_ccy);
  end if;

  if v_mode = 'credit' then
    if v_code is not null then
      v_use := discount_code_hold_run(v_studio, (v_code ->> 'code_id')::uuid, (v_code ->> 'batch_id')::uuid,
                 p_member_id, v_member.email, null, v_occ, t.price_cents, t.price_cents - v_price);
    end if;
    if v_price > 0 then
      v_credit := consume_reservation_credit(v_studio, p_member_id, v_price);
    end if;
    insert into payments (studio_id, member_id, booking_id, kind, amount_cents, currency,
                          status, provider, source, description, paid_at,
                          list_price_cents, discount_cents, discount_code_use_id)
    values (v_studio, p_member_id, v_booker_booking, 'private', v_price, v_ccy,
            'succeeded', 'manual', 'credit',
            case when v_price = 0 then 'Private session' else 'Private session (account credit)' end, now(),
            case when v_use is not null then t.price_cents end,
            case when v_use is not null then t.price_cents - v_price end, v_use)
    returning id into v_pay;
    update discount_code_uses set payment_id = v_pay where id = v_use and payment_id is null;
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
revoke execute on function private_book_run(uuid, uuid, uuid, timestamptz, jsonb, text, text, text, text) from public, anon, authenticated;
grant  execute on function private_book_run(uuid, uuid, uuid, timestamptz, jsonb, text, text, text, text) to service_role;

create or replace function private_refund_run(p_occurrence_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare o class_occurrences%rowtype; b bookings%rowtype; p payments%rowtype; v_bal int;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  select * into b from bookings where occurrence_id = p_occurrence_id
    and payment_source = 'private' order by created_at limit 1;  -- the booker's seat
  if b.id is null then return; end if;
  if b.membership_id is not null then
    -- pack credit back
    select credits_remaining + 1 into v_bal from memberships where id = b.membership_id;
    update memberships set credits_remaining = v_bal where id = b.membership_id;
    insert into credit_ledger (studio_id, member_id, membership_id, delta, reason, balance_after)
    values (o.studio_id, b.member_id, b.membership_id, 1, 'booking', v_bal);
  else
    -- a full-paid private: the succeeded private payment becomes account credit
    select * into p from payments where booking_id = b.id
      and kind = 'private' and status in ('succeeded', 'partially_refunded')
      order by paid_at desc limit 1;
    if p.id is not null and p.amount_cents = 0 then
      -- Decision 120(a): a session booked free with a 100% code gives the code back.
      perform discount_code_return_run(p.id);
      update payments set status = 'refunded', refunded_cents = 0, refunded_at = now(), updated_at = now()
       where id = p.id;
    elsif p.id is not null then
      insert into member_credits (studio_id, member_id, amount_cents, currency, reason, payment_id)
      values (o.studio_id, b.member_id, p.amount_cents, p.currency, 'private_refund', p.id);
    end if;
  end if;
end $$;
revoke execute on function private_refund_run(uuid) from public, anon, authenticated;
grant  execute on function private_refund_run(uuid) to service_role;

-- The member's private pack credits, by session type.
create or replace function my_private_credits(p_studio_id uuid)
returns table(type_id uuid, type_name text, people int, credits int, expires_on date)
language plpgsql stable security definer set search_path = public as $$
declare v_member uuid; v_today date;
begin
  select id into v_member from members
   where studio_id = p_studio_id and user_id = auth.uid() and deleted_at is null;
  if v_member is null then raise exception 'you are not a member of that studio' using errcode = 'PT403'; end if;
  v_today := (now() at time zone (select timezone from studios where id = p_studio_id))::date;
  return query
    select t.id, t.name, t.people, sum(m.credits_remaining)::int, min(m.expires_on)
      from memberships m
      join membership_plans p on p.id = m.plan_id
      join private_session_types t on t.id = p.private_session_type_id
     where m.member_id = v_member and m.studio_id = p_studio_id and p.private_pack
       and m.status in ('active', 'trialing') and coalesce(m.credits_remaining, 0) > 0
       and (m.expires_on is null or m.expires_on >= v_today)
     group by t.id, t.name, t.people
     order by t.people;
end $$;
revoke execute on function my_private_credits(uuid) from public, anon;
grant  execute on function my_private_credits(uuid) to authenticated, service_role;


-- ===================================================================== 80 (f)
alter table notification_templates_overrides add column if not exists body_text text;

-- The SQL port of lib/email-body.mjs renderBody's TEXT output: a card is its
-- lines, a button "Label: url", an image "[alt]", inline links their label,
-- **bold** its words, a rule nothing. Blocks are separated by a blank line.
create or replace function email_markup_text(p_src text)
returns text language plpgsql immutable set search_path = public as $$
declare v_blocks text[]; b text; t text; parts text[] := '{}'; m text[]; ls text[]; l text;
        c_name text; c_detail text; c_price text; c_bl text; c_bu text; k text; v text; pos int;
        i int; cl text[]; all_q boolean; outl text[];
begin
  if p_src is null then return null; end if;
  v_blocks := regexp_split_to_array(replace(p_src, E'\r\n', E'\n'), E'\n{2,}');
  foreach b in array v_blocks loop
    b := regexp_replace(regexp_replace(b, E'^\n+', ''), E'\n+$', '');
    if b = '' then continue; end if;
    t := btrim(b, E' \t\n');
    if t = '---' then continue; end if;
    m := regexp_match(t, '^\[([^\]]+)\]\(([^)]+)\)\{button\}$');
    if m is not null and (btrim(m[2]) ~* '^https?://[^\s)]+$' or btrim(m[2]) ~ '^\{[a-zA-Z_]+\}$') then
      parts := parts || (m[1] || ': ' || btrim(m[2]));
      continue;
    end if;
    if left(t, 3) = ':::' then
      ls := string_to_array(t, E'\n');
      if btrim(ls[1]) ~ '^:::\s+card$' then
        c_name := null; c_detail := null; c_price := null; c_bl := null; c_bu := null;
        for i in 2 .. coalesce(array_length(ls, 1), 1) loop
          l := btrim(ls[i]);
          if l = ':::' then continue; end if;
          pos := position(':' in l);
          if pos = 0 then c_detail := case when c_detail is null then l else c_detail || ' ' || l end; continue; end if;
          k := lower(btrim(left(l, pos - 1))); v := btrim(substr(l, pos + 1));
          if k = 'name' then c_name := v;
          elsif k = 'detail' then c_detail := v;
          elsif k = 'price' then c_price := v;
          elsif k = 'button' then
            if position('|' in v) > 0 then
              c_bl := btrim(left(v, position('|' in v) - 1)); c_bu := btrim(substr(v, position('|' in v) + 1));
            end if;
          elsif k = 'style' then null;
          else c_detail := case when c_detail is null then l else c_detail || ' ' || l end;
          end if;
        end loop;
        if coalesce(c_name, c_detail, c_price) is not null
           or (c_bl is not null and (c_bu ~* '^https?://[^\s)]+$' or c_bu ~ '^\{[a-zA-Z_]+\}$')) then
          cl := '{}';
          if c_name is not null then cl := cl || c_name; end if;
          if c_detail is not null then cl := cl || c_detail; end if;
          if c_price is not null then cl := cl || c_price; end if;
          if c_bl is not null and c_bl <> '' then cl := cl || (c_bl || ': ' || coalesce(c_bu, '')); end if;
          parts := parts || array_to_string(cl, E'\n');
          continue;
        end if;
      end if;
    end if;
    ls := string_to_array(b, E'\n');
    all_q := true;
    foreach l in array ls loop
      if l !~ '^>\s?' then all_q := false; end if;
    end loop;
    if all_q then
      outl := '{}';
      foreach l in array ls loop outl := outl || regexp_replace(l, '^>\s?', ''); end loop;
      parts := parts || array_to_string(outl, E'\n');
      continue;
    end if;
    m := regexp_match(t, '^!\[([^\]]*)\]\(([^)]*)\)$');
    if m is not null and btrim(m[2]) ~* '^https?://[^\s)]+$' then
      parts := parts || ('[' || coalesce(nullif(m[1], ''), 'image') || ']');
      continue;
    end if;
    outl := '{}';
    foreach l in array ls loop
      l := regexp_replace(l, '\[([^\]]+)\]\(\s*((https?://[^\s)]+)|(\{[a-zA-Z_]+\}))\s*\)', '\1', 'g');
      l := regexp_replace(l, '\*\*([^*]+)\*\*', '\1', 'g');
      outl := outl || l;
    end loop;
    parts := parts || array_to_string(outl, E'\n');
  end loop;
  return array_to_string(parts, E'\n\n');
end $$;
revoke execute on function email_markup_text(text) from public, anon;
grant  execute on function email_markup_text(text) to authenticated, service_role;

-- Existing overrides are rendered once, so their text part reads as prose.
update notification_templates_overrides set body_text = email_markup_text(body)
 where body_text is null and body is not null;

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
  v_offer uuid; v_pr jsonb; v_promo text;
  v_ov_body text; v_ov_text text; v_base text;
begin
  select * into s from studios where id = p_studio_id;
  select coalesce(time_format, '24h') into v_fmt from studio_settings where studio_id = p_studio_id;
  v_fmt := coalesce(v_fmt, '24h');
  v_is_staff := p_recipient_type = 'staff';
  v_sub := p_subject; v_txt := p_text; v_html := p_html;

  -- Decision 80 (f): the text part reads as prose. A studio override carries its
  -- saved plain-text rendering; any composer markup still in the text (cards,
  -- buttons, links) is rendered the same way, so ":::" never reaches a member.
  select o.body, o.body_text into v_ov_body, v_ov_text
    from notification_templates_overrides o
   where o.studio_id = p_studio_id and o.key = p_template_key;
  if v_ov_text is not null and p_text is not distinct from v_ov_body then
    v_txt := v_ov_text;
  elsif coalesce(v_txt, '') ~ '(^|\n):::|\{button\}|\]\((https?://|\{)|\*\*|!\[' then
    v_txt := email_markup_text(v_txt);
  end if;
  -- Decision 119(a): a sender may give the subject for this one email.
  if nullif(btrim(coalesce(p_payload ->> 'subject_override', '')), '') is not null then
    v_sub := p_payload ->> 'subject_override';
  end if;

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

  -- Decision 117: the offer plan's price as of the send, and {promo_line}.
  -- A paragraph that is only {promo_line} is dropped when the line is empty.
  v_offer := nullif(p_payload ->> 'offer_plan_id', '')::uuid;
  if v_offer is not null then
    v_pr := plan_price_now_run(v_offer, now());
    if v_pr is not null then
      p_payload := p_payload || jsonb_build_object(
        'offer_price', fmt_money((v_pr ->> 'price_cents')::int, v_pr ->> 'currency'),
        'promo_line', case when nullif(v_pr ->> 'promotion_id', '') is not null
                           then (v_pr ->> 'promotion_name') || ': ' || (v_pr ->> 'pct') || '% off until '
                                || (v_pr ->> 'ends_label')
                           else '' end);
    end if;
  end if;
  v_promo := coalesce(p_payload ->> 'promo_line', '');
  if v_promo = '' then
    v_html := regexp_replace(coalesce(v_html, ''), '<p[^>]*>\s*\{promo_line\}\s*</p>\s*', '', 'g');
    v_txt  := regexp_replace(coalesce(v_txt, ''), E'\n\n[ \t]*\{promo_line\}[ \t]*(?=\n\n)', '', 'g');
    v_txt  := regexp_replace(v_txt, E'\n[ \t]*\{promo_line\}[ \t]*(?=\n|$)', '', 'g');
    v_txt  := regexp_replace(v_txt, E'^[ \t]*\{promo_line\}[ \t]*\n*', '');
  end if;

  -- Decision 80 (f): paired tokens. When the payload carries both {x_line} (or
  -- {x_text}) and {x_html}, the HTML part uses x_html and the text part uses the
  -- plain one, whichever the template names, so neither part loses a line.
  for k in select jsonb_object_keys(p_payload) loop
    if k ~ '_(line|text)$' then
      v_base := regexp_replace(k, '_(line|text)$', '');
      if p_payload ? (v_base || '_html') then
        v_html := replace(v_html, '{' || k || '}', '{' || v_base || '_html}');
        v_txt  := replace(v_txt,  '{' || v_base || '_html}', '{' || k || '}');
      end if;
    end if;
  end loop;

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
                               'class_when','schedule_link','replaces_line','replaces_html','roster_table',
                               'button','promo_line'])) then
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
revoke execute on function render_email(uuid, text, text, text, text, text, jsonb, text, text) from public, anon, authenticated;
grant  execute on function render_email(uuid, text, text, text, text, text, jsonb, text, text) to service_role;


-- ===================================================================== 103 (l)
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
    -- Decision 103 (l): unused reservation credit covers the fee.
    'credit_covers', coalesce(v_req, false) and m.id is not null
                     and reservation_credit_available(o.studio_id, m.id) >= coalesce(st.free_first_reservation_fee_cents, 0),
    'deadline_label', case
       when v_late then 'the end of today'
       when v_dead <= now() then 'class time'
       else fmt_clock(v_dead, s.timezone, v_fmt) || ' ' || to_char(v_dead at time zone s.timezone, 'FMDy FMDD FMMon') end);
end $$;
revoke execute on function reservation_fee_terms(uuid, uuid) from public, anon;
grant  execute on function reservation_fee_terms(uuid, uuid) to authenticated, service_role;

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
  -- Decision 103 (l): the member's unused reservation credit covers the fee. The
  -- seat is confirmed and credit-covered: no due row, no nudge, no last call.
  if p_choice = 'credit' then
    if reservation_credit_available(b.studio_id, b.member_id) >= coalesce(st.free_first_reservation_fee_cents, 0)
       and coalesce(st.free_first_reservation_fee_cents, 0) > 0 then
      update bookings set reservation_credit_covered = true, updated_at = now() where id = p_booking_id;
      perform consume_reservation_credit(b.studio_id, b.member_id, st.free_first_reservation_fee_cents);
      insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
      values (b.studio_id, auth.uid(), 'reservation.credit_used', 'bookings', p_booking_id,
              jsonb_build_object('fee_cents', st.free_first_reservation_fee_cents, 'by_staff', true,
                                 'occurrence_id', o.id, 'member_id', b.member_id));
      return;
    end if;
    p_choice := 'due';
  end if;
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

CREATE OR REPLACE FUNCTION public.book_first_free(p_occurrence_id uuid, p_member_id uuid DEFAULT NULL::uuid, p_fee_choice text DEFAULT NULL::text, p_fee_note text DEFAULT NULL::text)
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
  v_covers  boolean := false;
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
    -- Decision 103 (l): credit that covers the fee is used; no choice is asked.
    v_covers := v_fee_req and reservation_credit_available(v_occ.studio_id, v_member.id)
                              >= coalesce(v_set.free_first_reservation_fee_cents, 0);
    if v_fee_req and not v_covers and coalesce(p_fee_choice, '') not in ('due', 'waive') then
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
    perform apply_free_fee_choice(v_booking, case when v_covers then 'credit' else p_fee_choice end, p_fee_note);
  end if;

  return jsonb_build_object('ok', true, 'booking_id', v_booking,
    'guest_pass_id', v_pass, 'provisional', v_prov, 'credit_covered', v_covers);
end $function$;
revoke execute on function book_first_free(uuid, uuid, text, text) from public, anon;
grant  execute on function book_first_free(uuid, uuid, text, text) to authenticated, service_role;

create or replace function convert_booking_to_free_first(p_booking_id uuid, p_fee_choice text default null, p_fee_note text default null)
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
  v_covers  boolean := false;
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
  -- Decision 103 (l): credit that covers the fee is used; no choice is asked.
  v_covers := v_fee_req and reservation_credit_available(v_b.studio_id, v_b.member_id)
                            >= coalesce(v_st.free_first_reservation_fee_cents, 0);
  if v_fee_req and not v_covers and coalesce(p_fee_choice, '') not in ('due', 'waive') then
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
    perform apply_free_fee_choice(p_booking_id, case when v_covers then 'credit' else p_fee_choice end, p_fee_note);
  end if;

  return jsonb_build_object('ok', true, 'booking_id', p_booking_id, 'guest_pass_id', v_pass);
end $$;
revoke execute on function convert_booking_to_free_first(uuid, text, text) from public, anon;
grant  execute on function convert_booking_to_free_first(uuid, text, text) to authenticated, service_role;


-- ===================================================================== 97 (b)
alter table members add column if not exists is_test_account boolean not null default false;

create or replace function set_member_test_account(p_member_id uuid, p_on boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m members%rowtype;
begin
  select * into m from members where id = p_member_id;
  if m.id is null then raise exception 'no such member' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(m.studio_id), false) then
    raise exception 'only owners and managers mark a test account' using errcode = 'PT403';
  end if;
  update members set is_test_account = coalesce(p_on, false), updated_at = now() where id = p_member_id;
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (m.studio_id, auth.uid(), 'member.test_account_set', 'members', p_member_id,
          jsonb_build_object('is_test_account', m.is_test_account),
          jsonb_build_object('is_test_account', coalesce(p_on, false)));
  return jsonb_build_object('ok', true, 'is_test_account', coalesce(p_on, false));
end $$;
revoke execute on function set_member_test_account(uuid, boolean) from public, anon;
grant  execute on function set_member_test_account(uuid, boolean) to authenticated, service_role;

-- A test account never gets a retention task.
create or replace function tg_member_tasks_skip_test()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from members where id = new.member_id and is_test_account) then return null; end if;
  return new;
end $$;
revoke execute on function tg_member_tasks_skip_test() from public, anon, authenticated;
grant  execute on function tg_member_tasks_skip_test() to service_role;
drop trigger if exists member_tasks_skip_test on member_tasks;
create trigger member_tasks_skip_test before insert on member_tasks
  for each row execute function tg_member_tasks_skip_test();

-- Reform: Deanna's accounts and every @example.com member.
update members m set is_test_account = true
  from studios s
 where s.id = m.studio_id and s.slug = 'reformcollective'
   and (lower(btrim(m.email)) in ('drewdeanna15@gmail.com', 'deannasallao15@gmail.com', 'deanna@dsvdigital.com')
        or lower(btrim(m.email)) like '%@example.com');

CREATE OR REPLACE FUNCTION public.notification_wanted(p_member_id uuid, p_template text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p notification_preferences%rowtype; v_ok boolean;
begin
  -- Decision 97 (b): a test account gets no campaign, sequence or rescue email.
  -- Its own booking and purchase emails still send.
  if (p_template = 'campaign' or left(p_template, 9) = 'campaign_' or left(p_template, 8) = 'convert_'
      or left(p_template, 5) = 'keep_' or left(p_template, 10) = 'retention_' or p_template = 'retention'
      or left(p_template, 16) = 'checkout_rescue_')
     and coalesce((select is_test_account from members where id = p_member_id), false) then
    return false;
  end if;

  if p_template = 'campaign'
     or p_template = any(array['convert_week_2','convert_week_3','convert_week_4','convert_week_5','convert_week_6','convert_monthly','campaign_try_format','campaign_free_waiting']) then
    select (marketing_opt_in and marketing_unsubscribed_at is null) into v_ok
      from members where id = p_member_id;
    return coalesce(v_ok, false);
  end if;

  if left(p_template, 8) = 'convert_' or left(p_template, 5) = 'keep_'
     or left(p_template, 10) = 'retention_' or p_template = 'retention' then
    select sequence_email into v_ok from notification_preferences where member_id = p_member_id;
    return coalesce(v_ok, true);
  end if;

  if p_template in ('class_cancelled', 'instructor_substituted',
                    'payment_failed', 'staff_message', 'class_moved',
                    'member_invite', 'guest_invite', 'guest_host_cancelled',
                    'guest_waiver_reminder', 'guest_waiver_host_nudge',
                    'flex_booking_confirmed', 'flex_booking_not_confirmed',
                    'free_booking_confirmed', 'free_booking_not_confirmed',
                    'membership_ended', 'membership_frozen', 'walk_in_welcome', 'day_tier_flex') then
    return true;
  end if;

  select * into p from notification_preferences where member_id = p_member_id;
  if not found then
    return true;
  end if;

  return case p_template
    when 'booking_confirmed' then p.booking_email
    when 'flex_booking_pending' then p.booking_email
    when 'free_booking_pending' then p.booking_email
    when 'class_reminder'    then p.reminder_email
    when 'waitlist_offer'    then p.waitlist_email
    when 'waitlist_missed'   then p.waitlist_email
    when 'credit_expiry'     then p.credit_expiry_email
    when 'milestone'         then p.milestone_email
    when 'challenge_started' then p.challenge_email
    when 'challenge_ending'  then p.challenge_email
    when 'challenge_completed' then p.challenge_email
    else true
  end;
end $function$;
revoke execute on function notification_wanted(uuid, text) from public, anon, authenticated;
grant  execute on function notification_wanted(uuid, text) to service_role;

create or replace function campaign_audience(p_studio_id uuid, p_filter jsonb)
returns table (member_id uuid, first_name text, last_name text, email text)
language plpgsql stable security definer set search_path = public as $$
declare
  v_plan   text := nullif(p_filter ->> 'plan_state', '');
  v_health text := nullif(p_filter ->> 'health', '');
  v_joined int  := nullif(p_filter ->> 'joined_days', '')::int;
  v_tz text; v_today date;
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'campaigns are for owners and managers' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  v_today := (now() at time zone v_tz)::date;

  return query
  select o.id, o.first_name, o.last_name, o.email
    from member_plan_overview(p_studio_id) o
    join members m on m.id = o.id
   where m.marketing_opt_in = true
     and m.marketing_unsubscribed_at is null
     and m.archived_at is null
     and m.deleted_at is null
     and not m.is_test_account
     and nullif(m.email, '') is not null
     and (v_plan   is null or o.plan_state = v_plan)
     and (v_health is null or o.health_band = v_health)
     and (v_joined is null or m.joined_on >= v_today - v_joined);
end $$;
revoke execute on function campaign_audience(uuid, jsonb) from public, anon;
grant  execute on function campaign_audience(uuid, jsonb) to authenticated, service_role;

create or replace function dashboard_kpis(p_studio_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tz text; v_currency char(3); v_today date; v_dayname text;
  v_t0 timestamptz; v_t1 timestamptz; v_p0 timestamptz; v_p1 timestamptz;
  v_cards jsonb := '[]'::jsonb;
  v_rev_today bigint; v_rev_prior bigint; v_rev_ever bigint;
  v_bk_today int; v_bk_prior int; v_bk_ever int;
  v_att_num int; v_att_den int; v_att_pnum int; v_att_pden int;
  v_active int; v_attended_30d int; v_joined_m int; v_members_ever int;
  v_at_risk int; v_banded int;
  v_occ_b bigint; v_occ_c bigint; v_occ_pb bigint; v_occ_pc bigint;
  v_months int; v_forecast bigint;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'the dashboard is for owners and managers'
      using errcode = 'PT403';
  end if;
  select s.timezone, s.currency into v_tz, v_currency
    from studios s where s.id = p_studio_id;
  if v_tz is null then raise exception 'no such studio' using errcode = 'PT404'; end if;

  v_today := studio_today(p_studio_id);
  select day_start, day_end into v_t0, v_t1 from studio_day_bounds(p_studio_id, v_today);
  select day_start, day_end into v_p0, v_p1 from studio_day_bounds(p_studio_id, v_today - 7);
  v_dayname := 'last ' || trim(to_char(v_today, 'Day'));

  -- 1. Today's revenue -- unchanged figure (studio_revenue_between is the sum of
  -- every succeeded/partially-refunded payment in today's bounds), now opening
  -- the per-payment list whose total is that same number.
  v_rev_today := studio_revenue_between(p_studio_id, v_t0, v_t1);
  v_rev_prior := studio_revenue_between(p_studio_id, v_p0, v_p1);
  select coalesce(sum(p.amount_cents), 0)::bigint into v_rev_ever
    from payments p where p.studio_id = p_studio_id
     and p.status in ('succeeded', 'partially_refunded');

  v_cards := v_cards || jsonb_build_array(jsonb_build_object(
    'key', 'revenue_today', 'label', 'Today''s revenue',
    'state', case when v_rev_ever = 0 then 'empty' else 'ok' end,
    'kind', 'money', 'value', v_rev_today, 'currency', v_currency,
    'trend', dashboard_trend(v_rev_today, v_rev_prior, v_dayname),
    'href', '/dashboard/revenue/today',
    'empty_hint', 'Once you take your first payment this shows what came in today, against the same day last week.'));

  -- 2. Today's bookings -- SEATS IN TODAY'S CLASSES (Decision 86), not bookings
  -- made today. The same set the Today's classes list shows: a seat on a
  -- non-cancelled occurrence starting today, held or taken or already attended.
  select count(*) into v_bk_today
    from bookings b join class_occurrences o on o.id = b.occurrence_id
   where b.studio_id = p_studio_id and o.status <> 'cancelled'
     and b.status in ('booked','attended','no_show','pending_payment')
     and o.starts_at >= v_t0 and o.starts_at < v_t1;
  select count(*) into v_bk_prior
    from bookings b join class_occurrences o on o.id = b.occurrence_id
   where b.studio_id = p_studio_id and o.status <> 'cancelled'
     and b.status in ('booked','attended','no_show','pending_payment')
     and o.starts_at >= v_p0 and o.starts_at < v_p1;
  select count(*) into v_bk_ever from bookings b where b.studio_id = p_studio_id;

  v_cards := v_cards || jsonb_build_array(jsonb_build_object(
    'key', 'bookings_today', 'label', 'Today''s bookings',
    'state', case when v_bk_ever = 0 then 'empty' else 'ok' end,
    'kind', 'count', 'value', v_bk_today,
    'trend', dashboard_trend(v_bk_today, v_bk_prior, v_dayname),
    'href', '/dashboard/classes',
    'empty_hint', 'Seats in today''s classes. Nobody has booked anything yet, so invite your members and this starts moving.'));

  -- 3. Attendance -- of the seats on classes that have ALREADY ENDED today, how
  -- many came. ends_at, not starts_at: a class in progress has nobody to mark
  -- a no-show yet.
  select count(*) filter (where b.status = 'attended'),
         count(*) filter (where b.status in ('attended','no_show','booked'))
    into v_att_num, v_att_den
    from bookings b join class_occurrences o on o.id = b.occurrence_id
   where b.studio_id = p_studio_id and o.status <> 'cancelled'
     and o.starts_at >= v_t0 and o.starts_at < v_t1 and o.ends_at <= now();
  select count(*) filter (where b.status = 'attended'),
         count(*) filter (where b.status in ('attended','no_show','booked'))
    into v_att_pnum, v_att_pden
    from bookings b join class_occurrences o on o.id = b.occurrence_id
   where b.studio_id = p_studio_id and o.status <> 'cancelled'
     and o.starts_at >= v_p0 and o.starts_at < v_p1;

  v_cards := v_cards || jsonb_build_array(jsonb_build_object(
    'key', 'attendance_today', 'label', 'Attendance',
    'sub', 'Turned up, of those booked in',
    'state', case when v_att_den = 0 then 'empty' else 'ok' end,
    'kind', 'percent',
    'value', case when v_att_den = 0 then null else round(100.0 * v_att_num / v_att_den) end,
    'trend', case when v_att_den = 0 or v_att_pden = 0 then null
                  else dashboard_trend(round(100.0 * v_att_num / v_att_den),
                                       round(100.0 * v_att_pnum / v_att_pden), v_dayname) end,
    'href', '/dashboard/classes?ended=1',
    'empty_hint', 'Once a class with people booked into it has ended today, this shows how many of them came.'));

  -- 4. Active members -- WHO CAN BOOK RIGHT NOW (a live plan or classes left),
  -- read from member_plan_overview so the card and the /members can-book filter
  -- cannot disagree. Second line: who came in the last 30 days. Both lines, and
  -- "joined this month", open their own filtered list.
  select
    count(*) filter (where plan_state in ('on_plan','expiring')),
    count(*) filter (where last_visit_at >= now() - interval '30 days'),
    count(*) filter (where joined_on >= date_trunc('month', v_today)::date),
    count(*)
  into v_active, v_attended_30d, v_joined_m, v_members_ever
  from member_plan_overview(p_studio_id) mpo
  -- Decision 97 (b): test accounts are not counted.
  where not exists (select 1 from members tm where tm.id = mpo.id and tm.is_test_account);

  v_cards := v_cards || jsonb_build_array(jsonb_build_object(
    'key', 'active_members', 'label', 'Active members',
    'sub', v_attended_30d || ' came in the last 30 days',
    'state', case when v_members_ever = 0 then 'empty' else 'ok' end,
    'kind', 'count', 'value', v_active,
    'href', '/members?filter=can_book',
    'links', jsonb_build_array(
      jsonb_build_object('label', v_attended_30d || ' came in the last 30 days',
                         'href', '/members?filter=attended_30d'),
      jsonb_build_object('label', v_joined_m || ' joined this month',
                         'href', '/members?filter=joined_month')),
    'empty_hint', 'Nobody on the books yet. Import your members or add one at the desk, and this counts everyone who can book.'));

  -- 5. Members at risk -- opens the retention board at its at-risk section.
  select count(*) filter (where m.health_band = 'at_risk'),
         count(*) filter (where m.health_band is not null)
    into v_at_risk, v_banded
    from members m where m.studio_id = p_studio_id and m.status <> 'archived' and not m.is_test_account;

  v_cards := v_cards || jsonb_build_array(jsonb_build_object(
    'key', 'members_at_risk', 'label', 'Members at risk',
    'sub', case when v_at_risk > 0 then 'Needs attention' else null end,
    'state', case when v_banded = 0 then 'empty' else 'ok' end,
    'kind', 'count', 'value', v_at_risk,
    'tone', case when v_at_risk > 0 then 'amber' else 'normal' end,
    'href', '/retention#at_risk',
    'empty_hint', 'Health is worked out overnight from each member''s own attendance rhythm. Once there are a few visits between them, anyone slipping shows up here.'));

  -- 6. Average class occupancy -- seats filled over capacity across classes that
  -- RAN in the last 30 days; opens the per-class list, emptiest first.
  select coalesce(sum(o.booked_count),0)::bigint, coalesce(sum(o.capacity),0)::bigint
    into v_occ_b, v_occ_c
    from class_occurrences o
   where o.studio_id = p_studio_id and o.status <> 'cancelled'
     and o.starts_at >= v_t0 - interval '30 days' and o.starts_at <= least(v_t1, now());
  select coalesce(sum(o.booked_count),0)::bigint, coalesce(sum(o.capacity),0)::bigint
    into v_occ_pb, v_occ_pc
    from class_occurrences o
   where o.studio_id = p_studio_id and o.status <> 'cancelled'
     and o.starts_at >= v_t0 - interval '60 days' and o.starts_at < v_t0 - interval '30 days';

  v_cards := v_cards || jsonb_build_array(jsonb_build_object(
    'key', 'avg_occupancy', 'label', 'Average class occupancy',
    'sub', 'Last 30 days',
    'state', case when v_occ_c = 0 then 'empty' else 'ok' end,
    'kind', 'percent',
    'value', case when v_occ_c = 0 then null else round(100.0 * v_occ_b / v_occ_c) end,
    'trend', case when v_occ_c = 0 or v_occ_pc = 0 then null
                  else dashboard_trend(round(100.0 * v_occ_b / v_occ_c),
                                       round(100.0 * v_occ_pb / v_occ_pc),
                                       'the 30 days before') end,
    'href', '/dashboard/occupancy',
    'empty_hint', 'How full your classes run, averaged over a month. Fills in once classes with bookings have taken place.'));

  -- 7. This month, projected -- unchanged.
  select count(*) into v_months from (
    select 1 from payments p
     where p.studio_id = p_studio_id and p.status in ('succeeded','partially_refunded')
       and coalesce(p.paid_at, p.created_at)
           < (date_trunc('month', v_today)::date::timestamp at time zone v_tz)
     group by date_trunc('month', (coalesce(p.paid_at, p.created_at) at time zone v_tz))
  ) x;

  if v_months >= dashboard_forecast_min_months() then
    v_forecast := dashboard_forecast_cents(p_studio_id);
    v_cards := v_cards || jsonb_build_array(jsonb_build_object(
      'key', 'revenue_forecast', 'label', 'This month, projected',
      'sub', 'From ' || v_months || ' complete months and what is already agreed',
      'state', 'ok', 'kind', 'money', 'value', v_forecast, 'currency', v_currency,
      'href', '/dashboard/revenue', 'forecast', true));
  end if;

  return jsonb_build_object(
    'today', v_today, 'currency', v_currency, 'cards', v_cards,
    'forecast_months_needed', dashboard_forecast_min_months(),
    'forecast_months_have', v_months);
end $$;
revoke execute on function dashboard_kpis(uuid) from public, anon;
grant  execute on function dashboard_kpis(uuid) to authenticated, service_role;

create or replace function daily_money_check(p_studio_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_tz text; v_items jsonb := '[]'::jsonb; v_html text := ''; v_text text := '';
  r record; v_n int; v_line text;
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
       -- Decision 108 (b): a member-less payment (a gift card) is attached to its card.
       and p.member_id is not null
    union all
    -- 4. a member with an active plan still marked lead
    select mname(m.id) || ': has an active plan but is still marked lead'
      from members m
     where m.studio_id = p_studio_id and m.status = 'lead' and m.deleted_at is null and not m.is_test_account
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
       and m.waiver_signed_at is null and not m.is_test_account
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
    -- 12. Decision 108 (a) and (c): a pay line whose amount does not match its
    -- own recorded basis, read at the tier the class had when it was decided.
    -- Settled lines (corrected, voided, restored) are skipped.
    select coalesce((select display_name from instructors where id = ipr.instructor_id), 'An instructor')
           || ': the pay line for ' || coalesce(cname(ipr.occurrence_id), 'a class') || ' is '
           || money_txt(ipr.amount_cents, ipr.currency) || ' but its basis gives '
           || money_txt((rv ->> 'basis_expected')::int, ipr.currency)
      from instructor_pay_records ipr
      cross join lateral pay_line_review_run(ipr.id) rv
     where ipr.studio_id = p_studio_id and ipr.type = 'class'
       and not (rv ->> 'settled')::boolean
       and (rv ->> 'basis_expected') is not null
       and (rv ->> 'basis_expected')::int <> ipr.amount_cents
    union all
    -- 12b. Decision 108 (b) and (c): a pay line on a decided class whose amount
    -- differs from 75 (l). Settled lines are skipped, and a class whose tier
    -- changed since it was decided is left to item 12's basis check.
    select coalesce((select display_name from instructors where id = ipr.instructor_id), 'An instructor')
           || ': the pay line for ' || coalesce(cname(ipr.occurrence_id), 'a class') || ' is '
           || money_txt(ipr.amount_cents, ipr.currency)
           || case when x.expected = 0 and o.status = 'cancelled'
                   then ' but the class did not run and pays nothing'
                   else ' but the rules give ' || money_txt(x.expected, ipr.currency) end
      from instructor_pay_records ipr
      join pay_periods pp on pp.id = ipr.period_id and pp.status = 'open'
      join class_occurrences o on o.id = ipr.occurrence_id
      cross join lateral pay_line_review_run(ipr.id) rv
      cross join lateral (select (compute_class_pay_run(o.id) ->> 'amount_cents')::int as expected) x
     where ipr.studio_id = p_studio_id and ipr.type = 'class'
       and (o.status = 'cancelled' or o.attendance_finalised_at is not null)
       and not (rv ->> 'settled')::boolean
       and (rv ->> 'decision_tier') is not distinct from (rv ->> 'today_tier')
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
       and not mb.is_test_account
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
    union all
    -- 14. Decision 108 (b): a class that ran with no pay line.
    select coalesce(cname(o.id), 'A class') || ' ran with no pay line'
      from class_occurrences o
      join studio_settings st on st.studio_id = o.studio_id
     where o.studio_id = p_studio_id and o.status = 'scheduled' and o.instructor_id is not null
       and (coalesce(st.guarantees_enabled, false) or coalesce(st.flex_enabled, false))
       and o.ends_at < now() - interval '1 hour' and o.starts_at > now() - interval '14 days'
       and not exists (select 1 from instructor_pay_records ipr2 where ipr2.occurrence_id = o.id)
    union all
    -- 15. Decision 108 (b): an always-runs class past its start never committed.
    select coalesce(cname(o.id), 'An always-runs class') || ' started and was never committed'
      from class_occurrences o
      cross join lateral occurrence_guarantee_run(o.id) g
     where o.studio_id = p_studio_id and o.status = 'scheduled' and g.tier = 'always'
       and o.committed_at is null
       and o.starts_at < now() - interval '30 minutes' and o.starts_at > now() - interval '14 days'
    union all
    -- 16. Decision 108 (b): a pay line held for more than 3 days.
    select coalesce((select display_name from instructors where id = ipr.instructor_id), 'An instructor')
           || ': the pay line for ' || coalesce(cname(ipr.occurrence_id), 'a class') || ' has been held for '
           || extract(day from now() - ipr.created_at)::int || ' days'
      from instructor_pay_records ipr
      join pay_periods pp on pp.id = ipr.period_id and pp.status = 'open'
     where ipr.studio_id = p_studio_id and ipr.confirmed_at is null
       and ipr.created_at < now() - interval '3 days'
    union all
    -- 17. Decision 118: a plan bought without an account, not claimed in 30 days.
    select coalesce(xp.buyer_name, xp.buyer_email, 'A buyer') || ': '
           || coalesce((select name from membership_plans where id = xp.plan_id), 'a plan')
           || ' bought, not yet claimed for 30 days'
      from xendit_purchases xp
     where xp.studio_id = p_studio_id and xp.guest_status = 'held'
       and xp.completed_at < now() - interval '30 days'
    union all
    -- 18. Decision 118: an intro offer refund at claim that did not go through.
    select coalesce(xp.buyer_name, xp.buyer_email, 'A buyer') || ': the refund for '
           || coalesce((select name from membership_plans where id = xp.plan_id), 'a plan')
           || ' did not go through. Refund it from Bought, not yet claimed'
      from xendit_purchases xp
     where xp.studio_id = p_studio_id and xp.guest_status = 'refund_pending'
       and xp.updated_at < now() - interval '1 hour'
  loop
    -- Decision 108 (b): one null line must never wipe the list.
    v_line := coalesce(r.line, 'An item with a missing name');
    v_items := v_items || to_jsonb(v_line);
    v_html  := v_html  || '<li>' || replace(replace(v_line, '&', '&amp;'), '<', '&lt;') || '</li>';
    v_text  := v_text  || '- ' || v_line || E'\n';
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


-- ===================================================================== 119 (a), 95 (c)
create or replace function checkout_rescue_run(
  p_purchase_id uuid, p_now timestamptz default now(), p_backfill boolean default false
) returns text
language plpgsql security definer set search_path = public as $$
declare
  x xendit_purchases%rowtype;
  m members%rowtype;
  gc gift_cards%rowtype;
  v_tz text; v_fmt text; v_studio_name text; v_msg_on boolean;
  v_end timestamptz;
  v_kind text; v_key text; v_template text;
  v_mid uuid; v_email text; v_first text;
  v_item text; v_retry text; v_label text; v_spots_line text;
  v_payload jsonb; v_reason text; v_nid uuid;
  v_plan membership_plans%rowtype;
  v_prod uuid; v_prod_name text; v_prod_live boolean;
  o class_occurrences%rowtype; v_class text; v_spots int; v_open boolean;
  v_ptype private_session_types%rowtype;
begin
  select * into x from xendit_purchases where id = p_purchase_id;
  if not found then return 'no_such_purchase'; end if;
  if exists (select 1 from checkout_rescues where purchase_id = x.id) then return 'done'; end if;
  if x.status not in ('failed', 'expired') then return 'not_ended'; end if;
  v_end := coalesce(x.completed_at, x.updated_at, x.created_at);
  if v_end > p_now - interval '1 hour' then return 'too_soon'; end if;

  select s.timezone, s.name, coalesce(ss.time_format, '24h'), coalesce(ss.messages_enabled, false)
    into v_tz, v_studio_name, v_fmt, v_msg_on
    from studios s left join studio_settings ss on ss.studio_id = s.id
   where s.id = x.studio_id;

  v_kind := case when x.plan_id is not null then 'plan'
                 when x.gift_card_id is not null then 'gift'
                 when x.product_order_id is not null then 'shop'
                 when x.booking_id is not null then 'reservation'
                 when x.private_occurrence_id is not null then 'private'
                 else 'other' end;

  if v_kind = 'reservation' and p_backfill then
    return 'backfill_excludes_reservation';
  end if;

  if v_kind = 'other' then
    v_reason := 'not_covered';
  elsif v_kind = 'reservation'
        and x.created_at < ('2026-11-25'::date::timestamp at time zone v_tz) then
    v_reason := 'reservation_before_cutover';
  end if;

  if x.gift_card_id is not null then
    select * into gc from gift_cards where id = x.gift_card_id;
  end if;
  v_mid := coalesce(x.member_id, x.claimed_member_id, gc.buyer_member_id, gc.purchaser_member_id);
  if v_mid is not null then
    select * into m from members where id = v_mid and studio_id = x.studio_id;
    if not found then v_mid := null; end if;
  end if;
  v_email := lower(btrim(coalesce(nullif(btrim(m.email), ''), nullif(btrim(x.buyer_email), ''),
                                  nullif(btrim(gc.buyer_email), ''))));
  v_first := coalesce(nullif(btrim(m.first_name), ''),
                      nullif(split_part(btrim(coalesce(x.buyer_name, gc.buyer_name, '')), ' ', 1), ''),
                      'there');

  v_key := case v_kind
             when 'plan' then 'plan:' || x.plan_id
             when 'gift' then 'gift'
             when 'reservation' then 'reservation'
             else null end;
  if v_kind = 'shop' then
    select po.product_id, p.name, (p.status = 'active')
      into v_prod, v_prod_name, v_prod_live
      from product_orders po join products p on p.id = po.product_id
     where po.id = x.product_order_id;
    v_key := 'product:' || v_prod;
  end if;
  -- Decision 119(a): a private session, keyed by its session type.
  if v_kind = 'private' then
    select t.* into v_ptype from class_occurrences o3
      join private_session_types t on t.id = o3.private_type_id
     where o3.id = x.private_occurrence_id;
    v_key := 'private:' || coalesce(v_ptype.id::text, 'any');
  end if;

  if v_reason is null and v_email is null then v_reason := 'no_email'; end if;
  if v_reason is null and m.id is not null and m.deleted_at is not null then v_reason := 'member_deleted'; end if;
  -- Decision 97 (b): a test account never gets a rescue email.
  if v_reason is null and (coalesce(m.is_test_account, false) or exists (
       select 1 from members m2 where m2.studio_id = x.studio_id and lower(m2.email) = v_email
          and m2.is_test_account)) then
    v_reason := 'test_account';
  end if;

  -- The studio owner's own account.
  if v_reason is null and exists (
       select 1 from studio_staff ss
        where ss.studio_id = x.studio_id and ss.role = 'owner' and ss.status = 'active'
          and (coalesce(ss.user_id = m.user_id, false) or lower(ss.email) = v_email)) then
    v_reason := 'owner';
  end if;

  -- An address marked invalid or bounced.
  if v_reason is null and (
       coalesce(m.email_status, 'valid') <> 'valid'
       or exists (select 1 from members m2
                   where m2.studio_id = x.studio_id and lower(m2.email) = v_email
                     and coalesce(m2.email_status, 'valid') <> 'valid')
       or exists (select 1 from notifications n
                   where n.studio_id = x.studio_id and n.bounced_at is not null
                     and lower(n.payload ->> 'to_email') = v_email)) then
    v_reason := 'invalid_email';
  end if;

  -- Paid since (for plans, any plan).
  if v_reason is null then
    if v_kind = 'plan' and (
         exists (select 1 from xendit_purchases x2
                  where x2.studio_id = x.studio_id and x2.status = 'succeeded'
                    and x2.plan_id is not null and x2.created_at > x.created_at
                    and (coalesce(x2.member_id = v_mid, false) or coalesce(x2.claimed_member_id = v_mid, false)
                         or lower(x2.buyer_email) = v_email))
         or exists (select 1 from memberships ms
                     where ms.member_id = v_mid and ms.created_at > x.created_at)) then
      v_reason := 'paid_since';
    elsif v_kind = 'gift' and exists (
         select 1 from xendit_purchases x2 join gift_cards g2 on g2.id = x2.gift_card_id
          where x2.studio_id = x.studio_id and x2.status = 'succeeded' and x2.created_at > x.created_at
            and (lower(g2.buyer_email) = v_email or coalesce(x2.member_id = v_mid, false))) then
      v_reason := 'paid_since';
    elsif v_kind = 'shop' and exists (
         select 1 from product_orders po2
          where po2.product_id = v_prod and po2.status in ('paid', 'collected')
            and po2.member_id = v_mid and po2.created_at > x.created_at) then
      v_reason := 'paid_since';
    elsif v_kind = 'private' and exists (
         select 1 from bookings b2 join class_occurrences o4 on o4.id = b2.occurrence_id
          where b2.member_id = v_mid and o4.is_private and o4.private_type_id = v_ptype.id
            and b2.created_at > x.created_at and b2.status in ('booked', 'attended')) then
      v_reason := 'paid_since';
    elsif v_kind = 'reservation' and (
         exists (select 1 from xendit_purchases x2
                  where x2.studio_id = x.studio_id and x2.status = 'succeeded'
                    and x2.booking_id is not null and x2.member_id = v_mid
                    and x2.created_at > x.created_at)
         or exists (select 1 from bookings b2
                     where b2.member_id = v_mid and b2.created_at > x.created_at
                       and b2.status in ('booked', 'attended'))
         or not coalesce((free_first_eligibility_run(x.studio_id, v_mid, null) ->> 'ok')::boolean, false)) then
      v_reason := 'paid_since';
    end if;
  end if;

  -- One rescue per person per item in seven days.
  if v_reason is null and exists (
       select 1 from checkout_rescues cr
        where cr.studio_id = x.studio_id and cr.outcome = 'sent'
          and lower(cr.email) = v_email and cr.item_key = v_key
          and cr.created_at > p_now - interval '7 days') then
    v_reason := 'sent_recently';
  end if;

  if v_reason is not null then
    insert into checkout_rescues (purchase_id, studio_id, email, item_key, kind, outcome, reason)
    values (x.id, x.studio_id, v_email, v_key, v_kind, 'skipped', v_reason);
    return v_reason;
  end if;

  -- What to say and where the button goes.
  if v_kind = 'plan' then
    select * into v_plan from membership_plans where id = x.plan_id;
    v_template := 'checkout_rescue_plan';
    v_item := v_plan.name;
    v_retry := case when v_plan.status = 'active' and v_plan.visibility = 'public'
                    then '/buy/' || x.plan_id else '/buy' end;
    v_label := 'Finish my purchase';
  elsif v_kind = 'gift' then
    v_template := 'checkout_rescue_gift';
    v_item := 'Gift card';
    v_retry := '/gift?amount=' || (coalesce(gc.amount_cents, x.amount_cents) / 100)::text;
    v_label := 'Finish my gift';
  elsif v_kind = 'shop' then
    v_template := 'checkout_rescue_shop';
    v_item := v_prod_name;
    v_retry := case when coalesce(v_prod_live, false) then '/shop#product-' || v_prod else '/shop' end;
    v_label := 'Finish my order';
  elsif v_kind = 'private' then
    v_template := 'checkout_rescue_private';
    v_item := coalesce(v_ptype.name, 'private session');
    v_retry := '/book/private' || case when v_ptype.id is not null and v_ptype.active
                                       then '?type=' || v_ptype.id::text else '' end;
    v_label := 'Finish my booking';
  else
    v_template := 'checkout_rescue_reservation';
    select o2.* into o from bookings b join class_occurrences o2 on o2.id = b.occurrence_id
     where b.id = x.booking_id;
    select coalesce(o.name, ct.name) into v_class from class_types ct where ct.id = o.class_type_id;
    v_class := coalesce(v_class, o.name, 'your class');
    v_spots := greatest(o.capacity - occurrence_seats_taken(o.id) - occurrence_seats_held(o.id, null), 0);
    v_open := o.status = 'scheduled' and o.starts_at > p_now
              and not coalesce(o.hidden_from_members, false) and v_spots > 0;
    v_item := v_class;
    if v_open then
      v_spots_line := case when v_spots = 1
        then 'There is only 1 spot left in that class. Grab yours before someone else does.'
        else 'There are only ' || v_spots || ' spots left in that class. Grab yours before someone else does.' end;
      v_label := 'Hold my spot';
      v_retry := '/class/' || o.id;
    else
      v_spots_line := 'That class filled up, but your free class is still waiting. Pick another time this week.';
      v_label := 'Book my free class';
      v_retry := '/book';
    end if;
  end if;

  v_payload := jsonb_build_object(
    'to_email', v_email,
    'first_name', v_first,
    'studio_name', v_studio_name,
    'item_name', v_item,
    'retry_label', v_label,
    'retry_url', member_portal_url(x.studio_id, v_retry),
    'message_url', member_portal_url(x.studio_id,
                     case when v_mid is not null and v_msg_on then '/messages' else '/buy#contact' end),
    'amount', fmt_money(x.amount_cents, x.currency),
    'purchase_id', x.id);
  if v_kind = 'gift' then
    v_payload := v_payload || jsonb_build_object(
      'recipient_name', coalesce(nullif(btrim(gc.recipient_name), ''), 'your friend'));
  elsif v_kind = 'reservation' then
    v_payload := v_payload || jsonb_build_object(
      'class_name', v_class,
      'day', to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMonth'),
      'time', fmt_clock(o.starts_at, v_tz, v_fmt),
      'spots_left', v_spots,
      'spots_line', v_spots_line,
      'fee', fmt_money(x.amount_cents, x.currency),
      'occurrence_id', o.id);
    -- Decision 119(a): the full or past version has its own subject.
    if not v_open then
      v_payload := v_payload || jsonb_build_object('subject_override',
        'Your free class is still waiting, ' || v_first);
    end if;
  end if;

  v_nid := queue_notification(x.studio_id, v_mid, v_template, v_payload,
                              'checkout_rescue:' || x.id, quiet_hours_shift(p_now, v_tz));
  if v_nid is null then
    insert into checkout_rescues (purchase_id, studio_id, email, item_key, kind, outcome, reason)
    values (x.id, x.studio_id, v_email, v_key, v_kind, 'skipped', 'switched_off');
    return 'switched_off';
  end if;

  insert into checkout_rescues (purchase_id, studio_id, email, item_key, kind, outcome, notification_id)
  values (x.id, x.studio_id, v_email, v_key, v_kind, 'sent', v_nid);
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (x.studio_id, auth.uid(), 'checkout.rescue_sent', 'xendit_purchases', x.id,
          jsonb_build_object('kind', v_kind, 'template', v_template, 'email', v_email,
                             'item', v_item, 'notification_id', v_nid, 'backfill', p_backfill));
  return 'sent';
end $$;
revoke execute on function checkout_rescue_run(uuid, timestamptz, boolean) from public, anon, authenticated;
grant  execute on function checkout_rescue_run(uuid, timestamptz, boolean) to service_role;

insert into notification_templates (key, subject, text_body, html_body, note) values
('checkout_rescue_private', 'Still thinking about your {item_name}, {first_name}?', 'Hi {first_name},

Your payment link for your {item_name} at {studio_name} timed out before it went through, so nothing was charged.

Your coach and time may still be open.

Finish my booking: {retry_url}

Got a question first? Message the studio.

Message the studio: {message_url}

{studio_name}', '<p>Hi {first_name},</p>
<p>Your payment link for your {item_name} at {studio_name} timed out before it went through, so nothing was charged.</p>
<p>Your coach and time may still be open.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{retry_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Finish my booking</a></td></tr></table>
<p>Got a question first? Message the studio.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{message_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Message the studio</a></td></tr></table>
<p>{studio_name}</p>',
 'Decision 119 (a): a private session checkout that expired or failed')
on conflict (key) do nothing;
insert into notification_templates_overrides (studio_id, key, subject, body, body_html, body_text)
select s.id, 'checkout_rescue_private', 'Still thinking about your {item_name}, {first_name}?', 'Hi {first_name},

We saw you booking a {item_name}. Your payment link timed out before it went through, so nothing was charged.

Your coach and time may still be open.

[Finish my booking]({retry_url}){button}

Got a question first? Message us and we''ll help.

[Message the studio]({message_url}){button}

See you at the reformer!🎀

RPC Studio', '<p>Hi {first_name},</p>
<p>We saw you booking a {item_name}. Your payment link timed out before it went through, so nothing was charged.</p>
<p>Your coach and time may still be open.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{retry_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Finish my booking</a></td></tr></table>
<p>Got a question first? Message us and we&#39;ll help.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{message_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Message the studio</a></td></tr></table>
<p>See you at the reformer!🎀</p>
<p>RPC Studio</p>', 'Hi {first_name},

We saw you booking a {item_name}. Your payment link timed out before it went through, so nothing was charged.

Your coach and time may still be open.

Finish my booking: {retry_url}

Got a question first? Message us and we''ll help.

Message the studio: {message_url}

See you at the reformer!🎀

RPC Studio'
  from studios s where s.slug = 'reformcollective'
on conflict (studio_id, key) do nothing;

create or replace function core_classes_for_rescue(p_occurrence_id uuid, p_booking_id uuid default null)
returns table(occurrence_id uuid, name text, starts_at timestamptz, day_label text,
              time_label text, coach_first text, n_booked int, spots_left int,
              label text, kind text)
language plpgsql stable security definer set search_path = public as $function$
declare v_src class_occurrences%rowtype; s studios%rowtype; v_fmt text;
        v_member uuid; v_core_only boolean := false; v_free boolean := false;
begin
  select * into v_src from class_occurrences where id = p_occurrence_id;
  if not found then return; end if;
  select * into s from studios where id = v_src.studio_id;
  v_fmt := coalesce((select time_format from studio_settings where studio_id = v_src.studio_id), '24h');

  -- The booking says whose list this is; only its member, the desk or the
  -- service may pass it (it leaves out the classes that member holds).
  if p_booking_id is not null and not is_service_context()
     and not coalesce(is_desk_up(v_src.studio_id), false)
     and not exists (select 1 from bookings bk join members m on m.id = bk.member_id
                      where bk.id = p_booking_id and m.user_id = auth.uid()) then
    raise exception 'that is not your booking' using errcode = 'PT403';
  end if;

  if p_booking_id is not null then
    select b.member_id,
           (b.payment_source = 'comp' and exists (select 1 from guest_passes gp
              where gp.guest_booking_id = b.id and gp.host_member_id is null))
      into v_member, v_free
      from bookings b where b.id = p_booking_id;
    v_free := coalesce(v_free, false);
    if v_free then
      v_core_only := coalesce((select free_first_core_only from studio_settings
                                where studio_id = v_src.studio_id), false);
    end if;
  end if;

  return query
  with cand as (
    select o.id,
           coalesce(nullif(o.name, ''), ct.name) as name,
           o.starts_at,
           to_char(o.starts_at at time zone s.timezone, 'FMDy FMDD FMMon') as day_label,
           fmt_clock(o.starts_at, s.timezone, v_fmt) as time_label,
           split_part(coalesce(i.display_name, ''), ' ', 1) as coach_first,
           o.booked_count as n_booked,
           (o.capacity - occurrence_seats_taken(o.id) - occurrence_seats_held(o.id)) as spots_left,
           coalesce(o.guarantee_tier,
                    case when o.flex then 'flex'::guarantee_tier end,
                    cs.guarantee_tier,
                    case when cs.flex then 'flex'::guarantee_tier end,
                    'core') as cfg_tier,
           g.tier as eff_tier, g.minimum,
           o.flex_reached_minimum_at is not null or o.committed_at is not null as running
      from class_occurrences o
      join class_types ct on ct.id = o.class_type_id
      left join class_series cs on cs.id = o.series_id
      left join instructors i on i.id = o.instructor_id
      cross join lateral occurrence_guarantee_run(o.id) g
     where o.studio_id = v_src.studio_id
       and o.id <> p_occurrence_id
       and o.status = 'scheduled'
       and not o.hidden_from_members
       and not coalesce(o.is_private, false)
       and occurrence_published(o.id)
       and o.starts_at > now()
       and o.starts_at >= v_src.starts_at
       and o.starts_at < v_src.starts_at + interval '7 days'
       and (o.capacity - occurrence_seats_taken(o.id) - occurrence_seats_held(o.id)) >= 1
       and (v_member is null or not exists (
             select 1 from bookings mb where mb.occurrence_id = o.id and mb.member_id = v_member
                and mb.status in ('booked','attended','pending_payment','waitlisted')))
  ),
  short as (
    select c.*, (c.minimum - occurrence_paid_count_run(c.id)) as need
      from cand c
     where not v_core_only
       and c.eff_tier = 'flex' and not c.running and coalesce(c.minimum, 0) > 0
  ),
  one_short as (
    select s1.*, row_number() over (order by s1.starts_at) as rn
      from short s1 where s1.need = 1
  ),
  two_short as (
    select s2.*, row_number() over (order by s2.starts_at) as rn
      from short s2 where s2.need = 2
  ),
  n1 as (select count(*)::int as n from one_short),
  core as (
    select c.*, row_number() over (order by (c.n_booked > 0) desc, c.starts_at) as rn
      from cand c where c.cfg_tier = 'core'
  ),
  picked as (
    select o1.id, o1.name, o1.starts_at, o1.day_label, o1.time_label, o1.coach_first,
           o1.n_booked, o1.spots_left, 'Needs 1 more to run'::text as label, 'flex'::text as kind,
           1 as grp, o1.rn
      from one_short o1
    union all
    select t2.id, t2.name, t2.starts_at, t2.day_label, t2.time_label, t2.coach_first,
           t2.n_booked, t2.spots_left, 'Needs 2 more to run', 'flex', 2, t2.rn
      from two_short t2, n1
     where n1.n + t2.rn <= 4 and n1.n < 4
    union all
    select k.id, k.name, k.starts_at, k.day_label, k.time_label, k.coach_first,
           k.n_booked, k.spots_left, 'Always runs', 'core', 3, k.rn
      from core k
  )
  select p.id, p.name, p.starts_at, p.day_label, p.time_label, p.coach_first,
         p.n_booked, p.spots_left, p.label, p.kind
    from picked p
   order by p.grp, p.rn
   limit 8;
end $function$;
revoke execute on function core_classes_for_rescue(uuid, uuid) from public, anon;
grant  execute on function core_classes_for_rescue(uuid, uuid) to authenticated, service_role;


-- ===================================================================== Reform override edits
CREATE OR REPLACE FUNCTION public.write_reservation_credit(p_booking_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare b bookings%rowtype; pay payments%rowtype; v_offer membership_plans%rowtype;
begin
  select * into b from bookings where id = p_booking_id;
  if not found then return; end if;
  if exists (select 1 from member_credits
              where booking_id = p_booking_id and reason = 'reservation_credit') then
    return;
  end if;
  select * into pay from payments
   where booking_id = p_booking_id and kind = 'reservation_fee'
     and status in ('succeeded', 'partially_refunded')
   order by created_at limit 1;
  if not found then return; end if;
  insert into member_credits (studio_id, member_id, amount_cents, currency, reason,
                              payment_id, booking_id)
  values (pay.studio_id, b.member_id, pay.amount_cents - coalesce(pay.refunded_cents, 0),
          pay.currency, 'reservation_credit', pay.id, p_booking_id);

  -- Decision 103 amendment (b): a CHECK-IN (attended) writes one credit-back
  -- email. An on-time cancel also writes the credit (Decision 103) but gets no
  -- "thanks for coming" email, so this is gated on the booking being attended.
  if b.status = 'attended' then
    -- Step 13: the studio's intro offer, for an offer button ({offer_plan_name},
    -- {offer_price} resolved at send time from offer_plan_id, {buy_url}).
    select mp.* into v_offer from studio_settings st join membership_plans mp on mp.id = st.intro_offer_plan_id
     where st.studio_id = pay.studio_id and mp.status = 'active';
    perform queue_notification(pay.studio_id, b.member_id, 'free_reservation_credited',
      jsonb_build_object(
        'fee', fmt_money(pay.amount_cents - coalesce(pay.refunded_cents, 0), pay.currency),
        'class_name', coalesce((select coalesce(o.name, ct.name, 'your class')
                                  from class_occurrences o
                                  left join class_types ct on ct.id = o.class_type_id
                                 where o.id = b.occurrence_id), 'your class'),
        'plans_url', member_portal_url(pay.studio_id, '/account/plan'),
        'offer_plan_id', v_offer.id,
        'offer_plan_name', coalesce(v_offer.name, 'a class pack'),
        'buy_url', case when v_offer.id is not null
                        then member_portal_url(pay.studio_id, '/buy/' || v_offer.id::text)
                        else member_portal_url(pay.studio_id, '/account/plan') end),
      'free_reservation_credited:' || p_booking_id);
  end if;
end $function$;
revoke execute on function write_reservation_credit(uuid) from public, anon, authenticated;
grant  execute on function write_reservation_credit(uuid) to service_role;

-- The credit-back button names the offer; the month roster lists the classes.
-- Each is changed only when the stored body is exactly the one read on 26 Nov.
update notification_templates_overrides o
   set body = 'Hi {first_name},

::: card
style: accent
name: {fee} credit is yours
detail: Your {class_name} reservation fee, back as studio credit
:::

You came, you moved, and the {fee} is back on your account. Use it now: it comes straight off your next purchase at checkout.

First class done, so keep the pace going. The Intro Offer is three classes in two weeks, and your credit comes off it too. Lock it in today while the feeling is fresh.

[Grab the {offer_plan_name}, {offer_price}]({buy_url}){button}

See you at the reformer!🎀

RPC Studio', body_html = '<p>Hi {first_name},</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="background:{accent};border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#FFFFFF">{fee} credit is yours</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#FFFFFF;margin-top:4px">Your {class_name} reservation fee, back as studio credit</div></td></tr></table>
<p>You came, you moved, and the {fee} is back on your account. Use it now: it comes straight off your next purchase at checkout.</p>
<p>First class done, so keep the pace going. The Intro Offer is three classes in two weeks, and your credit comes off it too. Lock it in today while the feeling is fresh.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{buy_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Grab the {offer_plan_name}, {offer_price}</a></td></tr></table>
<p>See you at the reformer!🎀</p>
<p>RPC Studio</p>', body_text = 'Hi {first_name},

{fee} credit is yours
Your {class_name} reservation fee, back as studio credit

You came, you moved, and the {fee} is back on your account. Use it now: it comes straight off your next purchase at checkout.

First class done, so keep the pace going. The Intro Offer is three classes in two weeks, and your credit comes off it too. Lock it in today while the feeling is fresh.

Grab the {offer_plan_name}, {offer_price}: {buy_url}

See you at the reformer!🎀

RPC Studio', updated_at = now()
  from studios s
 where s.id = o.studio_id and s.slug = 'reformcollective' and o.key = 'free_reservation_credited'
   and o.body = 'Hi {first_name},

::: card
style: accent
name: {fee} credit is yours
detail: Your {class_name} reservation fee, back as studio credit
:::

You came, you moved, and the {fee} is back on your account. Use it now: it comes straight off your next purchase at checkout.

First class done, so keep the pace going. The Intro Offer is three classes in two weeks, and your credit comes off it too. Lock it in today while the feeling is fresh.

[Grab the Intro Offer]({plans_url}){button}

See you at the reformer!🎀

RPC Studio';
update notification_templates_overrides o
   set body = 'Hi Coach {instructor_name},

::: card
style: accent
name: {month} is published
detail: Classes this month: {count}
:::

Your classes this month:

{roster_table}

Please have a look at your schedule. If a class does not work for you, kindly ask for cover in the app at least {hours} hours before it starts.

You can ask a colleague directly and they confirm from their phone, or let us know so we can assist you.

How classes confirm:

- Core classes always run.
- Flex classes need {flex_min} bookings by {flex_cutoff}, or they are cancelled.
- You get one email each evening after the cut-off with the next day''s running and cancelled classes.

[Open my schedule]({href}){button}

Thank you!

RPC Studio', body_html = '<p>Hi Coach {instructor_name},</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="background:{accent};border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#FFFFFF">{month} is published</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#FFFFFF;margin-top:4px">Classes this month: {count}</div></td></tr></table>
<p>Your classes this month:</p>
<p>{roster_table}</p>
<p>Please have a look at your schedule. If a class does not work for you, kindly ask for cover in the app at least {hours} hours before it starts.</p>
<p>You can ask a colleague directly and they confirm from their phone, or let us know so we can assist you.</p>
<p>How classes confirm:</p>
<p>- Core classes always run.<br>- Flex classes need {flex_min} bookings by {flex_cutoff}, or they are cancelled.<br>- You get one email each evening after the cut-off with the next day&#39;s running and cancelled classes.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{href}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Open my schedule</a></td></tr></table>
<p>Thank you!</p>
<p>RPC Studio</p>', body_text = 'Hi Coach {instructor_name},

{month} is published
Classes this month: {count}

Your classes this month:

{roster_table}

Please have a look at your schedule. If a class does not work for you, kindly ask for cover in the app at least {hours} hours before it starts.

You can ask a colleague directly and they confirm from their phone, or let us know so we can assist you.

How classes confirm:

- Core classes always run.
- Flex classes need {flex_min} bookings by {flex_cutoff}, or they are cancelled.
- You get one email each evening after the cut-off with the next day''s running and cancelled classes.

Open my schedule: {href}

Thank you!

RPC Studio', updated_at = now()
  from studios s
 where s.id = o.studio_id and s.slug = 'reformcollective' and o.key = 'month_roster_plain'
   and o.body = 'Hi Coach {instructor_name},

::: card
style: accent
name: {month} is published
detail: Classes this month: {count}
:::

Please have a look at your schedule. If a class does not work for you, kindly ask for cover in the app at least {hours} hours before it starts.

You can ask a colleague directly and they confirm from their phone, or let us know so we can assist you.

How classes confirm:

- Core classes always run.
- Flex classes need {flex_min} bookings by {flex_cutoff}, or they are cancelled.
- You get one email each evening after the cut-off with the next day''s running and cancelled classes.

[Open my schedule]({href}){button}

Thank you!

RPC Studio';


-- ===================================================================== 120 (a), 120 (b)
do $$ declare c text; begin
  for c in select conname from pg_constraint
            where conrelid = 'discount_code_batches'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) ilike '%pct%' loop
    execute format('alter table discount_code_batches drop constraint %I', c);
  end loop;
end $$;
alter table discount_code_batches add constraint discount_code_batches_pct_check check (pct between 1 and 100);
alter table discount_code_batches add column if not exists product_ids uuid[] not null default '{}';
alter table discount_code_uses add column if not exists product_order_id uuid references product_orders(id) on delete set null;
-- A 0 payment refunded at 0 (Decision 120 a) is recorded with a 0 refund row.
alter table payment_refunds drop constraint if exists payment_refunds_amount_cents_check;
alter table payment_refunds add constraint payment_refunds_amount_cents_check check (amount_cents >= 0);

create or replace function discount_code_check_run(
  p_studio_id uuid, p_code text, p_plan_id uuid, p_private boolean,
  p_member_id uuid, p_email text, p_list_cents int, p_at timestamptz default now())
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_code text; v_email text; c discount_codes%rowtype; b discount_code_batches%rowtype;
        v_tz text; v_today date; v_used int; v_held int; v_price int;
begin
  v_code := upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g'));
  v_email := lower(nullif(btrim(coalesce(p_email, '')), ''));

  -- Rate limits over ten minutes: per studio, per member, per email.
  if (select count(*) from discount_code_checks k
       where k.studio_id = p_studio_id and k.created_at > p_at - interval '10 minutes') >= 200
     or (p_member_id is not null and (select count(*) from discount_code_checks k
       where k.studio_id = p_studio_id and k.member_id = p_member_id
         and k.created_at > p_at - interval '10 minutes') >= 10)
     or (v_email is not null and (select count(*) from discount_code_checks k
       where k.studio_id = p_studio_id and k.buyer_email = v_email
         and k.created_at > p_at - interval '10 minutes') >= 10) then
    return jsonb_build_object('ok', false, 'reason', 'rate_limited',
      'message', 'Too many tries. Try again in a few minutes.');
  end if;

  select timezone into v_tz from studios where id = p_studio_id;
  v_today := (p_at at time zone v_tz)::date;
  select * into c from discount_codes where studio_id = p_studio_id and upper(code) = v_code;
  if c.id is not null then select * into b from discount_code_batches where id = c.batch_id; end if;

  insert into discount_code_checks (studio_id, member_id, buyer_email, ok)
  values (p_studio_id, p_member_id, v_email, c.id is not null);

  if v_code = '' or c.id is null or c.cancelled_at is not null or b.cancelled_at is not null
     or v_today < b.starts_on then
    return jsonb_build_object('ok', false, 'reason', 'invalid', 'message', 'That code isn''t valid.');
  end if;
  if v_today > b.ends_on then
    return jsonb_build_object('ok', false, 'reason', 'expired', 'message', 'That code has expired.');
  end if;
  -- Decision 120(b): p_plan_id may name a shop product; a product is matched
  -- against the batch's product list.
  if exists (select 1 from products pr where pr.id = p_plan_id and pr.studio_id = p_studio_id) then
    if not (p_plan_id = any (coalesce(b.product_ids, '{}'::uuid[]))) then
      return jsonb_build_object('ok', false, 'reason', 'not_this_plan',
        'message', 'That code doesn''t apply to this item.');
    end if;
  elsif (coalesce(p_private, false) and not b.private_sessions)
     or (not coalesce(p_private, false) and (p_plan_id is null or not (p_plan_id = any (b.plan_ids)))) then
    return jsonb_build_object('ok', false, 'reason', 'not_this_plan',
      'message', 'That code doesn''t apply to this plan.');
  end if;

  if b.kind = 'shared' and exists (
       select 1 from discount_code_uses u
        where u.batch_id = b.id and u.status = 'redeemed'
          and (coalesce(u.member_id = p_member_id, false) or coalesce(lower(u.buyer_email) = v_email, false))) then
    return jsonb_build_object('ok', false, 'reason', 'used_by_you', 'message', 'You''ve already used this code.');
  end if;

  select count(*) filter (where u.status = 'redeemed'),
         count(*) filter (where u.status = 'held' and exists (
           select 1 from xendit_purchases xp where xp.id = u.purchase_id
              and xp.status = 'pending' and xp.created_at > p_at - interval '2 hours'))
    into v_used, v_held
    from discount_code_uses u where u.code_id = c.id;

  if b.kind = 'batch' then
    if v_used > 0 then
      return jsonb_build_object('ok', false, 'reason', 'used', 'message', 'That code has already been used.');
    end if;
    if v_held > 0 then
      return jsonb_build_object('ok', false, 'reason', 'in_use',
        'message', 'This code is being used in another checkout. Try again in 30 minutes.');
    end if;
  else
    if exists (select 1 from discount_code_uses u join xendit_purchases xp on xp.id = u.purchase_id
                where u.code_id = c.id and u.status = 'held' and xp.status = 'pending'
                  and xp.created_at > p_at - interval '2 hours'
                  and (coalesce(u.member_id = p_member_id, false) or coalesce(lower(u.buyer_email) = v_email, false))) then
      return jsonb_build_object('ok', false, 'reason', 'in_use',
        'message', 'This code is being used in another checkout. Try again in 30 minutes.');
    end if;
    if v_used + v_held >= b.max_uses then
      if v_used >= b.max_uses then
        return jsonb_build_object('ok', false, 'reason', 'used', 'message', 'That code has already been used.');
      end if;
      return jsonb_build_object('ok', false, 'reason', 'in_use',
        'message', 'This code is being used in another checkout. Try again in 30 minutes.');
    end if;
  end if;

  v_price := promo_sale_cents(p_list_cents, b.pct);
  return jsonb_build_object('ok', true, 'code_id', c.id, 'batch_id', b.id, 'code', c.code,
    'pct', b.pct, 'list_cents', p_list_cents, 'price_cents', v_price,
    'amount_off_cents', p_list_cents - v_price);
end $$;
revoke execute on function discount_code_check_run(uuid, text, uuid, boolean, uuid, text, int, timestamptz) from public, anon, authenticated;
grant  execute on function discount_code_check_run(uuid, text, uuid, boolean, uuid, text, int, timestamptz) to service_role;

drop function if exists discount_code_validate_batch_run(uuid, text, int, date, date, uuid[], boolean);
create or replace function discount_code_validate_batch_run(
  p_studio_id uuid, p_name text, p_pct int, p_starts date, p_ends date, p_plan_ids uuid[], p_private boolean,
  p_product_ids uuid[])
returns text language plpgsql stable security definer set search_path = public as $$
begin
  if btrim(coalesce(p_name, '')) = '' or length(btrim(p_name)) > 60 then return 'Give the code a name.'; end if;
  if p_pct is null or p_pct < 1 or p_pct > 100 then return 'The percent off is a whole number from 1 to 100.'; end if;
  if p_starts is null or p_ends is null or p_ends < p_starts then return 'The end date is before the start date.'; end if;
  if coalesce(array_length(p_plan_ids, 1), 0) = 0 and not coalesce(p_private, false)
     and coalesce(array_length(p_product_ids, 1), 0) = 0 then
    return 'Choose at least one plan or item.';
  end if;
  if exists (select 1 from unnest(coalesce(p_product_ids, '{}'::uuid[])) x
              where not exists (select 1 from products pr where pr.id = x and pr.studio_id = p_studio_id)) then
    return 'One of those items is not this studio''s.';
  end if;
  if exists (select 1 from unnest(coalesce(p_plan_ids, '{}'::uuid[])) x
              where not exists (select 1 from membership_plans mp where mp.id = x and mp.studio_id = p_studio_id)) then
    return 'One of those plans is not this studio''s.';
  end if;
  return null;
end $$;
revoke execute on function discount_code_validate_batch_run(uuid, text, int, date, date, uuid[], boolean, uuid[]) from public, anon, authenticated;
grant  execute on function discount_code_validate_batch_run(uuid, text, int, date, date, uuid[], boolean, uuid[]) to service_role;

drop function if exists discount_code_create_batch(uuid, text, int, int, date, date, uuid[], boolean);
create or replace function discount_code_create_batch(
  p_studio_id uuid, p_name text, p_pct int, p_count int, p_starts date, p_ends date,
  p_plan_ids uuid[], p_private boolean default false, p_product_ids uuid[] default '{}'::uuid[])
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_msg text; v_batch uuid; v_prefix text; v_code text; v_made int := 0; v_try int := 0;
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers create discount codes' using errcode = 'PT403';
  end if;
  v_msg := discount_code_validate_batch_run(p_studio_id, p_name, p_pct, p_starts, p_ends, p_plan_ids, p_private, p_product_ids);
  if v_msg is null and (p_count is null or p_count < 1 or p_count > 500) then
    v_msg := 'Make between 1 and 500 codes.';
  end if;
  if v_msg is not null then return jsonb_build_object('ok', false, 'message', v_msg); end if;

  insert into discount_code_batches (studio_id, kind, name, pct, starts_on, ends_on, plan_ids, private_sessions, created_by, product_ids)
  values (p_studio_id, 'batch', btrim(p_name), p_pct, p_starts, p_ends,
          array(select distinct unnest(coalesce(p_plan_ids, '{}'::uuid[]))), coalesce(p_private, false), auth.uid(),
          array(select distinct unnest(coalesce(p_product_ids, '{}'::uuid[]))))
  returning id into v_batch;
  v_prefix := discount_code_prefix(p_studio_id);
  while v_made < p_count and v_try < p_count * 5 loop
    v_try := v_try + 1;
    v_code := v_prefix || '-' || discount_code_random(4) || '-' || discount_code_random(4);
    begin
      insert into discount_codes (studio_id, batch_id, code) values (p_studio_id, v_batch, v_code);
      v_made := v_made + 1;
    exception when unique_violation then null;
    end;
  end loop;
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (p_studio_id, auth.uid(), 'discount_code.batch_created', 'discount_code_batches', v_batch,
          jsonb_build_object('kind', 'batch', 'name', btrim(p_name), 'pct', p_pct, 'count', v_made,
                             'starts_on', p_starts, 'ends_on', p_ends, 'plan_ids', p_plan_ids,
                             'private_sessions', coalesce(p_private, false),
                             'product_ids', p_product_ids));
  return jsonb_build_object('ok', true, 'batch_id', v_batch, 'count', v_made);
end $$;
revoke execute on function discount_code_create_batch(uuid, text, int, int, date, date, uuid[], boolean, uuid[]) from public, anon;
grant  execute on function discount_code_create_batch(uuid, text, int, int, date, date, uuid[], boolean, uuid[]) to authenticated, service_role;

drop function if exists discount_code_create_shared(uuid, text, text, int, date, date, uuid[], int, boolean);
create or replace function discount_code_create_shared(
  p_studio_id uuid, p_code text, p_name text, p_pct int, p_starts date, p_ends date,
  p_plan_ids uuid[], p_max_uses int, p_private boolean default false, p_product_ids uuid[] default '{}'::uuid[])
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_msg text; v_batch uuid; v_code text;
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers create discount codes' using errcode = 'PT403';
  end if;
  v_code := upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g'));
  if v_code !~ '^[A-Z0-9]{3,20}$' then
    return jsonb_build_object('ok', false, 'message', 'A code is 3 to 20 letters and digits.');
  end if;
  if exists (select 1 from discount_codes where studio_id = p_studio_id and upper(code) = v_code) then
    return jsonb_build_object('ok', false, 'message', 'That code is already in use. Choose another.');
  end if;
  v_msg := discount_code_validate_batch_run(p_studio_id, coalesce(nullif(btrim(p_name), ''), v_code),
             p_pct, p_starts, p_ends, p_plan_ids, p_private, p_product_ids);
  if v_msg is null and (p_max_uses is null or p_max_uses < 1 or p_max_uses > 100000) then
    v_msg := 'Set how many times the code can be used.';
  end if;
  if v_msg is not null then return jsonb_build_object('ok', false, 'message', v_msg); end if;

  insert into discount_code_batches (studio_id, kind, name, pct, starts_on, ends_on, plan_ids,
                                     private_sessions, max_uses, created_by, product_ids)
  values (p_studio_id, 'shared', coalesce(nullif(btrim(p_name), ''), v_code), p_pct, p_starts, p_ends,
          array(select distinct unnest(coalesce(p_plan_ids, '{}'::uuid[]))), coalesce(p_private, false),
          p_max_uses, auth.uid(), array(select distinct unnest(coalesce(p_product_ids, '{}'::uuid[]))))
  returning id into v_batch;
  insert into discount_codes (studio_id, batch_id, code) values (p_studio_id, v_batch, v_code);
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (p_studio_id, auth.uid(), 'discount_code.batch_created', 'discount_code_batches', v_batch,
          jsonb_build_object('kind', 'shared', 'code', v_code, 'pct', p_pct, 'max_uses', p_max_uses,
                             'starts_on', p_starts, 'ends_on', p_ends, 'plan_ids', p_plan_ids,
                             'private_sessions', coalesce(p_private, false),
                             'product_ids', p_product_ids));
  return jsonb_build_object('ok', true, 'batch_id', v_batch, 'code', v_code);
end $$;
revoke execute on function discount_code_create_shared(uuid, text, text, int, date, date, uuid[], int, boolean, uuid[]) from public, anon;
grant  execute on function discount_code_create_shared(uuid, text, text, int, date, date, uuid[], int, boolean, uuid[]) to authenticated, service_role;

drop function if exists discount_code_preview(uuid, text, uuid, uuid, uuid);
create or replace function discount_code_preview(
  p_studio_id uuid, p_code text, p_plan_id uuid default null,
  p_member_id uuid default null, p_private_type_id uuid default null,
  p_product_id uuid default null, p_quantity int default 1)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_member uuid; v_email text; v_pr jsonb; v_chk jsonb; t private_session_types%rowtype; v_ccy char(3);
        prod products%rowtype; v_list int;
begin
  -- Decision 120(b): staff check a code on a desk shop sale with no member.
  if p_member_id is null and p_product_id is not null
     and (coalesce(is_desk_up(p_studio_id), false) or is_service_context()) then
    null;
  elsif p_member_id is null then
    select id, email into v_member, v_email from members
     where studio_id = p_studio_id and user_id = auth.uid() and deleted_at is null;
    if v_member is null then raise exception 'you are not a member of that studio' using errcode = 'PT403'; end if;
  else
    if not (coalesce(is_desk_up(p_studio_id), false) or auth_instructor_id(p_studio_id) is not null
            or is_service_context()) then
      raise exception 'only staff check a code for a member' using errcode = 'PT403';
    end if;
    select id, email into v_member, v_email from members where id = p_member_id and studio_id = p_studio_id;
    if v_member is null then raise exception 'no such member' using errcode = 'PT404'; end if;
  end if;

  -- Decision 120(b): a shop item, priced on the line total.
  if p_product_id is not null then
    select * into prod from products where id = p_product_id and studio_id = p_studio_id;
    if prod.id is null then raise exception 'no such item' using errcode = 'PT404'; end if;
    v_list := prod.price_cents * greatest(coalesce(p_quantity, 1), 1);
    v_chk := discount_code_check_run(p_studio_id, p_code, p_product_id, false, v_member, v_email, v_list, now());
    if not (v_chk ->> 'ok')::boolean then
      return jsonb_build_object('list_cents', v_list, 'price_cents', v_list, 'currency', prod.currency,
        'code_ok', false, 'code_reason', v_chk ->> 'reason', 'code_message', v_chk ->> 'message');
    end if;
    return jsonb_build_object('list_cents', v_list, 'price_cents', (v_chk ->> 'price_cents')::int,
      'discount_cents', (v_chk ->> 'amount_off_cents')::int, 'currency', prod.currency,
      'code_ok', true, 'code_applied', true, 'code', v_chk ->> 'code');
  end if;

  if p_private_type_id is not null then
    select * into t from private_session_types where id = p_private_type_id and studio_id = p_studio_id;
    if t.id is null then raise exception 'no such private session' using errcode = 'PT404'; end if;
    select currency into v_ccy from studios where id = p_studio_id;
    v_chk := discount_code_check_run(p_studio_id, p_code, null, true, v_member, v_email, t.price_cents, now());
    if not (v_chk ->> 'ok')::boolean then
      return jsonb_build_object('list_cents', t.price_cents, 'price_cents', t.price_cents, 'currency', v_ccy,
        'code_ok', false, 'code_reason', v_chk ->> 'reason', 'code_message', v_chk ->> 'message');
    end if;
    return jsonb_build_object('list_cents', t.price_cents, 'price_cents', (v_chk ->> 'price_cents')::int,
      'discount_cents', (v_chk ->> 'amount_off_cents')::int, 'currency', v_ccy,
      'code_ok', true, 'code_applied', true, 'code', v_chk ->> 'code');
  end if;

  if not exists (select 1 from membership_plans where id = p_plan_id and studio_id = p_studio_id) then
    raise exception 'no such plan' using errcode = 'PT404';
  end if;
  return discount_code_price_run(p_plan_id, p_code, v_member, v_email, now());
end $$;
revoke execute on function discount_code_preview(uuid, text, uuid, uuid, uuid, uuid, int) from public, anon;
grant  execute on function discount_code_preview(uuid, text, uuid, uuid, uuid, uuid, int) to authenticated, service_role;

create or replace function tg_payment_discount_code_fill()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- Decision 120(b): a shop payment written by the Xendit activation carries the
  -- code its checkout held.
  if new.discount_code_use_id is null and new.product_order_id is not null then
    select xp.discount_code_use_id into new.discount_code_use_id
      from xendit_purchases xp
     where xp.product_order_id = new.product_order_id and xp.discount_code_use_id is not null
     order by xp.created_at desc limit 1;
  end if;
  if new.discount_code_use_id is not null and new.discount_cents is null then
    select u.amount_off_cents, u.list_cents into new.discount_cents, new.list_price_cents
      from discount_code_uses u where u.id = new.discount_code_use_id;
  end if;
  if new.discount_code_use_id is not null and new.discount_code is null then
    select c.code into new.discount_code
      from discount_code_uses u join discount_codes c on c.id = u.code_id
     where u.id = new.discount_code_use_id;
  end if;
  return new;
end $$;
revoke execute on function tg_payment_discount_code_fill() from public, anon, authenticated;
grant  execute on function tg_payment_discount_code_fill() to service_role;

create or replace function plan_buy_begin(
  p_studio_id uuid, p_plan_id uuid,
  p_buyer_name text default null, p_buyer_email text default null, p_buyer_phone text default null,
  p_code text default null, p_preview boolean default false
) returns table(purchase_id uuid, amount_cents int, currency char(3),
                secret_key_ciphertext text, test_mode boolean, apple_pay_verified boolean, plan_name text,
                list_cents int, discount_cents int, code_applied boolean, code text, code_message text)
language plpgsql security definer set search_path = public as $$
declare mp membership_plans%rowtype; ss studio_settings%rowtype; v_country text;
        v_email text; v_name text; v_phone text; v_pr jsonb; v_price int; v_promo uuid;
        v_list int; v_disc int; v_id uuid; v_use uuid; v_has_code boolean;
begin
  if not exists (select 1 from studios where id = p_studio_id and status = 'active') then
    raise exception 'no such studio' using errcode = 'PT404';
  end if;
  if not exists (select 1 from studio_payment_providers where studio_id = p_studio_id and provider = 'xendit') then
    raise exception 'this studio is not set up to take online payments' using errcode = 'PT409';
  end if;
  select * into mp from membership_plans where id = p_plan_id and studio_id = p_studio_id;
  if mp.id is null or mp.status <> 'active' or mp.visibility <> 'public'
     or mp.type not in ('class_pack', 'drop_in', 'trial', 'recurring', 'group') then
    raise exception 'that plan is not on sale' using errcode = 'PT404';
  end if;
  select * into ss from studio_settings where studio_id = p_studio_id;
  if mp.max_active_members is not null and coalesce(ss.seat_caps_enabled, false)
     and plan_seats_taken(mp.id) >= mp.max_active_members then
    raise exception '% is full.', mp.name using errcode = 'PT409';
  end if;

  v_name := nullif(btrim(coalesce(p_buyer_name, '')), '');
  v_email := lower(nullif(btrim(coalesce(p_buyer_email, '')), ''));
  v_has_code := nullif(btrim(coalesce(p_code, '')), '') is not null;

  if not coalesce(p_preview, false) then
    if v_name is null or length(v_name) > 120 then
      raise exception 'a name is needed' using errcode = 'PT422';
    end if;
    if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 254 then
      raise exception 'an email address is needed' using errcode = 'PT422';
    end if;
    select country into v_country from studios where id = p_studio_id;
    v_phone := normalise_phone(p_buyer_phone, v_country);
    if nullif(btrim(coalesce(v_phone, '')), '') is null
       or (v_country = 'PH' and v_phone !~ '^\+639[0-9]{9}$')
       or (coalesce(v_country,'') <> 'PH'
           and length(regexp_replace(coalesce(v_phone,''), '[^0-9]', '', 'g')) not between 7 and 15) then
      raise exception 'that does not look like a mobile number' using errcode = 'PT422';
    end if;

    if (select count(*) from xendit_purchases xp where xp.studio_id = p_studio_id
          and xp.buyer_email is not null and xp.created_at > now() - interval '1 minute') >= 10 then
      raise exception 'too many right now, try again in a minute' using errcode = 'PT429';
    end if;
    if (select count(*) from xendit_purchases xp where xp.studio_id = p_studio_id
          and lower(xp.buyer_email) = v_email and xp.created_at > now() - interval '1 minute') >= 3 then
      raise exception 'too many right now, try again in a minute' using errcode = 'PT429';
    end if;
  elsif v_email is not null and (v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 254) then
    v_email := null;
  end if;

  -- Decision 117: the price is fixed now, from the promotion in force.
  -- Decision 120: with a code, the lower of the sale and the code price.
  if v_has_code then
    v_pr := discount_code_price_run(p_plan_id, p_code, null, v_email, now());
    if not coalesce((v_pr ->> 'code_ok')::boolean, false) then
      if coalesce(p_preview, false) then
        return query select null::uuid, (v_pr ->> 'price_cents')::int, mp.currency, null::text, null::boolean,
                            null::boolean, mp.name, (v_pr ->> 'list_cents')::int,
                            (v_pr ->> 'discount_cents')::int, false, null::text, v_pr ->> 'code_message';
        return;
      end if;
      raise exception '%', v_pr ->> 'code_message' using errcode = 'PT460';
    end if;
  else
    v_pr := plan_price_now_run(p_plan_id, now());
  end if;
  v_price := (v_pr ->> 'price_cents')::int;
  v_promo := nullif(v_pr ->> 'promotion_id', '')::uuid;
  v_list  := case when v_promo is not null then (v_pr ->> 'list_cents')::int end;
  v_disc  := case when v_promo is not null then (v_pr ->> 'discount_cents')::int end;
  if coalesce((v_pr ->> 'code_applied')::boolean, false) then
    v_list := (v_pr ->> 'list_cents')::int;
    v_disc := (v_pr ->> 'discount_cents')::int;
  end if;

  if coalesce(p_preview, false) then
    return query select null::uuid, v_price, mp.currency, null::text, null::boolean, null::boolean, mp.name,
                        (v_pr ->> 'list_cents')::int, coalesce(v_disc, 0),
                        coalesce((v_pr ->> 'code_applied')::boolean, false), v_pr ->> 'code',
                        v_pr ->> 'code_message';
    return;
  end if;

  if coalesce((v_pr ->> 'code_applied')::boolean, false) then
    v_use := discount_code_hold_run(p_studio_id, (v_pr ->> 'code_id')::uuid, (v_pr ->> 'batch_id')::uuid,
               null, v_email, p_plan_id, null, v_list, v_disc);
  end if;

  insert into xendit_purchases (studio_id, member_id, plan_id, amount_cents, currency,
                                list_price_cents, promotion_id, discount_cents,
                                buyer_email, buyer_name, buyer_phone, discount_code_use_id)
  values (p_studio_id, null, p_plan_id, v_price, mp.currency, v_list, v_promo, v_disc,
          v_email, v_name, v_phone, v_use)
  returning id into v_id;
  update discount_code_uses set purchase_id = v_id where id = v_use;

  -- Decision 120(a): a code that brings the price to 0 needs no checkout. The
  -- purchase completes through the full-credit path; a guest's plan is held for
  -- claim exactly as a paid one (Decision 118).
  if v_price = 0 then
    perform xendit_activate_success_internal(v_id, null, 'credit');
  end if;

  return query
    select v_id, v_price, mp.currency, spp.secret_key_ciphertext, spp.test_mode,
           coalesce(ss.gift_apple_pay_verified, false), mp.name,
           (v_pr ->> 'list_cents')::int, coalesce(v_disc, 0),
           coalesce((v_pr ->> 'code_applied')::boolean, false), v_pr ->> 'code', v_pr ->> 'code_message'
      from studio_payment_providers spp
     where spp.studio_id = p_studio_id and spp.provider = 'xendit';
end $$;
revoke execute on function plan_buy_begin(uuid, uuid, text, text, text, text, boolean) from public;
grant  execute on function plan_buy_begin(uuid, uuid, text, text, text, text, boolean) to anon, authenticated, service_role;

drop function if exists xendit_begin_product_purchase(uuid, uuid, integer);
create function xendit_begin_product_purchase(p_studio_id uuid, p_product_id uuid, p_quantity int,
  p_code text default null)
returns table(purchase_id uuid, amount_cents int, currency char(3), credit_applied_cents int)
language plpgsql security definer set search_path = public as $$
declare v_member uuid; prod products%rowtype; v_order uuid; v_id uuid; v_amount int;
        v_avail int; v_applied int; v_due int;
        v_email text; v_chk jsonb; v_list int; v_disc int; v_use uuid;
begin
  select id, email into v_member, v_email from members where studio_id = p_studio_id and user_id = auth.uid();
  if v_member is null then
    raise exception 'you are not a member of that studio' using errcode = 'PT403';
  end if;
  if not exists (select 1 from studio_payment_providers where studio_id = p_studio_id and provider = 'xendit') then
    raise exception 'this studio is not set up to take online payments' using errcode = 'PT409';
  end if;

  select * into prod from products where id = p_product_id and studio_id = p_studio_id for update;
  if prod.id is null then
    raise exception 'that product is not on sale' using errcode = 'PT404';
  end if;
  if prod.status <> 'active' then
    raise exception 'That product is no longer on sale.' using errcode = 'PT409';
  end if;
  if p_quantity is null or p_quantity < 1 then
    raise exception 'how many?' using errcode = 'PT400';
  end if;
  if prod.track_stock and prod.stock < p_quantity then
    raise exception 'Only % left.', prod.stock using errcode = 'PT409';
  end if;

  v_amount := prod.price_cents * p_quantity;

  -- Decision 120(b): a code on a shop item, checked against the line total.
  if nullif(btrim(coalesce(p_code, '')), '') is not null then
    v_chk := discount_code_check_run(p_studio_id, p_code, p_product_id, false, v_member, v_email, v_amount, now());
    if not (v_chk ->> 'ok')::boolean then
      raise exception '%', v_chk ->> 'message' using errcode = 'PT460';
    end if;
    v_list := v_amount;
    v_disc := (v_chk ->> 'amount_off_cents')::int;
    v_amount := (v_chk ->> 'price_cents')::int;
  end if;

  insert into product_orders (studio_id, product_id, member_id, quantity, unit_price_cents,
                              currency, status, channel, created_by)
  values (p_studio_id, p_product_id, v_member, p_quantity, prod.price_cents,
          prod.currency, 'reserved', 'app', auth.uid())
  returning id into v_order;

  if prod.track_stock then
    update products set stock = stock - p_quantity where id = p_product_id;
    insert into stock_movements (studio_id, product_id, delta, reason, order_id, created_by)
    values (p_studio_id, p_product_id, -p_quantity, 'reserve', v_order, auth.uid());
  end if;

  if v_chk is not null then
    v_use := discount_code_hold_run(p_studio_id, (v_chk ->> 'code_id')::uuid, (v_chk ->> 'batch_id')::uuid,
               v_member, v_email, null, null, v_list, v_disc);
    update discount_code_uses set product_order_id = v_order where id = v_use;
  end if;

  v_avail := reservation_credit_available(p_studio_id, v_member);

  if v_avail >= v_amount then
    insert into xendit_purchases (studio_id, member_id, product_order_id, amount_cents, currency, credit_applied_cents,
                                  list_price_cents, discount_cents, discount_code_use_id)
    values (p_studio_id, v_member, v_order, v_amount, prod.currency, v_amount, v_list, v_disc, v_use)
    returning id into v_id;
    update discount_code_uses set purchase_id = v_id where id = v_use;
    perform xendit_activate_success_internal(v_id, null, 'credit');
    return query select v_id, 0, prod.currency, v_amount;
    return;
  end if;

  v_applied := least(greatest(v_avail, 0), greatest(v_amount - 2000, 0));
  v_due := v_amount - v_applied;

  insert into xendit_purchases (studio_id, member_id, product_order_id, amount_cents, currency, credit_applied_cents,
                                list_price_cents, discount_cents, discount_code_use_id)
  values (p_studio_id, v_member, v_order, v_due, prod.currency, v_applied, v_list, v_disc, v_use)
  returning id into v_id;
  update discount_code_uses set purchase_id = v_id where id = v_use;

  return query select v_id, v_due, prod.currency, v_applied;
end $$;
revoke execute on function xendit_begin_product_purchase(uuid, uuid, int, text) from public, anon;
grant  execute on function xendit_begin_product_purchase(uuid, uuid, int, text) to authenticated, service_role;

drop function if exists record_product_sale(uuid, uuid, integer, uuid, text, text, text);
create function record_product_sale(
  p_studio_id uuid, p_product_id uuid, p_quantity int,
  p_member_id uuid default null, p_method text default 'cash',
  p_method_note text default null, p_reference text default null, p_code text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare prod products%rowtype; v_order uuid; v_payment uuid; v_amount int;
        v_chk jsonb; v_list int; v_disc int; v_use uuid; v_email text;
begin
  if not is_desk_up(p_studio_id) then
    raise exception 'only staff can record a sale' using errcode = 'PT403';
  end if;
  if studio_is_locked(p_studio_id) then
    raise exception 'this studio''s Studiior subscription is not active'
      using errcode = 'PT402', hint = 'Reactivate it from Billing. Nothing has been deleted.';
  end if;
  select * into prod from products where id = p_product_id and studio_id = p_studio_id for update;
  if not found then raise exception 'no such product' using errcode = 'PT404'; end if;
  if prod.status <> 'active' then
    raise exception 'That product is archived.' using errcode = 'PT409';
  end if;
  if p_quantity is null or p_quantity < 1 then
    raise exception 'how many?' using errcode = 'PT400';
  end if;
  if prod.track_stock and prod.stock < p_quantity then
    raise exception 'Only % left.', prod.stock using errcode = 'PT409';
  end if;
  if p_member_id is not null and not exists (
       select 1 from members where id = p_member_id and studio_id = p_studio_id) then
    raise exception 'that member does not belong to this studio' using errcode = 'PT403';
  end if;

  v_amount := prod.price_cents * p_quantity;

  -- Decision 120(b): a code at the desk, same rules as the shop checkout.
  if nullif(btrim(coalesce(p_code, '')), '') is not null then
    select email into v_email from members where id = p_member_id;
    v_chk := discount_code_check_run(p_studio_id, p_code, p_product_id, false, p_member_id, v_email, v_amount, now());
    if not (v_chk ->> 'ok')::boolean then
      raise exception '%', v_chk ->> 'message' using errcode = 'PT460';
    end if;
    v_list := v_amount;
    v_disc := (v_chk ->> 'amount_off_cents')::int;
    v_amount := (v_chk ->> 'price_cents')::int;
  end if;

  insert into product_orders (studio_id, product_id, member_id, quantity, unit_price_cents,
                              currency, status, channel, created_by, collected_at, collected_by)
  values (p_studio_id, p_product_id, p_member_id, p_quantity, prod.price_cents,
          prod.currency, 'collected', 'desk', auth.uid(), now(), auth.uid())
  returning id into v_order;

  -- Stock down (tracked only), with a ledger row.
  if prod.track_stock then
    update products set stock = stock - p_quantity where id = p_product_id;
    insert into stock_movements (studio_id, product_id, delta, reason, order_id, created_by)
    values (p_studio_id, p_product_id, -p_quantity, 'sale', v_order, auth.uid());
  end if;

  -- The money: an ordinary payments row, provider 'manual' + the method, tagged
  -- with the order it paid for.
  if v_chk is not null then
    v_use := discount_code_hold_run(p_studio_id, (v_chk ->> 'code_id')::uuid, (v_chk ->> 'batch_id')::uuid,
               p_member_id, v_email, null, null, v_list, v_disc);
    update discount_code_uses set product_order_id = v_order where id = v_use;
  end if;

  insert into payments (studio_id, member_id, product_order_id, amount_cents, currency,
                        status, description, provider, method, method_note, reference,
                        recorded_by, paid_at, list_price_cents, discount_cents, discount_code_use_id)
  values (p_studio_id, p_member_id, v_order, v_amount, prod.currency, 'succeeded',
          prod.name || ' ×' || p_quantity, 'manual', p_method,
          nullif(btrim(coalesce(p_method_note,'')), ''), nullif(btrim(coalesce(p_reference,'')), ''),
          auth.uid(), now(), v_list, v_disc, v_use)
  returning id into v_payment;

  return jsonb_build_object('ok', true, 'order_id', v_order, 'payment_id', v_payment,
                            'amount_cents', v_amount);
end $$;
revoke execute on function record_product_sale(uuid, uuid, int, uuid, text, text, text, text) from public, anon;
grant  execute on function record_product_sale(uuid, uuid, int, uuid, text, text, text, text) to authenticated, service_role;

create or replace function record_refund(
  p_payment_id uuid, p_amount_cents int default null, p_reason text default null,
  p_restock boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  pay      payments%rowtype;
  plan     membership_plans%rowtype;
  ms       memberships%rowtype;
  o        product_orders%rowtype;
  prod     products%rowtype;
  v_amount int;
  v_total  int;
  v_full   boolean;
  v_bal    int;
  v_take   int := 0;
begin
  select * into pay from payments where id = p_payment_id for update;
  if not found then
    raise exception 'no such payment' using errcode = 'PT404';
  end if;
  if not is_manager_up(pay.studio_id) then
    raise exception 'refunds are the owner''s or a manager''s to make'
      using errcode = 'PT403';
  end if;
  if pay.status not in ('succeeded', 'partially_refunded') then
    raise exception 'a % payment cannot be refunded', pay.status using errcode = 'PT409';
  end if;

  v_amount := coalesce(p_amount_cents, pay.amount_cents - pay.refunded_cents);
  -- Decision 120(a): a 0 payment (a 100% code) is refunded at 0, which cancels it.
  if (v_amount <= 0 and pay.amount_cents > 0) or v_amount < 0 or v_amount > pay.amount_cents - pay.refunded_cents then
    raise exception 'that is more than is left to refund' using errcode = 'PT400';
  end if;

  v_total := pay.refunded_cents + v_amount;
  v_full  := v_total >= pay.amount_cents;

  update payments
     set refunded_cents = v_total,
         refunded_at = now(),
         refund_reason = coalesce(p_reason, refund_reason),
         status = (case when v_full then 'refunded' else 'partially_refunded' end)::payment_status,
         updated_at = now()
   where id = p_payment_id;

  if v_full and pay.membership_id is not null then
    select * into ms from memberships where id = pay.membership_id;
    select * into plan from membership_plans where id = ms.plan_id;

    if plan.type = 'class_pack' then
      select coalesce(sum(delta), 0) into v_bal
        from credit_ledger
       where studio_id = pay.studio_id and member_id = pay.member_id;

      v_take := least(coalesce(ms.credits_remaining, 0), greatest(v_bal, 0));
      if v_take > 0 then
        insert into credit_ledger (studio_id, member_id, membership_id, delta, reason,
                                   balance_after, actor_user_id)
        values (pay.studio_id, pay.member_id, ms.id, -v_take, 'manual',
                v_bal - v_take, auth.uid());
        update memberships set credits_remaining = coalesce(credits_remaining, 0) - v_take
         where id = ms.id;
      end if;
    end if;

    update memberships
       set status = 'cancelled', cancelled_at = now(),
           cancellation_reason = coalesce(p_reason, 'refunded')
     where id = ms.id and status <> 'cancelled';

    insert into membership_events (studio_id, membership_id, type, from_status,
                                   to_status, actor_user_id, metadata)
    values (pay.studio_id, ms.id, 'cancelled', ms.status, 'cancelled', auth.uid(),
            jsonb_build_object('reason', p_reason, 'payment_id', p_payment_id,
                               'credits_removed', v_take));
  end if;

  -- Decision 103: refunding a reservation fee removes the UNUSED remainder of its
  -- credit (used stays used — a member cannot keep a credit from money returned).
  if pay.kind = 'reservation_fee' then
    update member_credits
       set used_cents = amount_cents, voided_at = now()
     where payment_id = p_payment_id and voided_at is null;
  end if;

  if p_restock and pay.product_order_id is not null then
    select * into o from product_orders where id = pay.product_order_id;
    if o.id is not null then
      select * into prod from products where id = o.product_id;
      if prod.track_stock then
        update products set stock = stock + o.quantity where id = o.product_id;
        insert into stock_movements (studio_id, product_id, delta, reason, order_id, created_by)
        values (o.studio_id, o.product_id, o.quantity, 'refund_restock', o.id, auth.uid());
      end if;
      update product_orders set status = 'refunded' where id = o.id;
    end if;
  end if;

  return jsonb_build_object('payment_id', p_payment_id, 'refunded_cents', v_total,
                            'full', v_full, 'credits_removed', v_take);
end $$;
revoke execute on function record_refund(uuid, int, text, boolean) from public, anon;
grant  execute on function record_refund(uuid, int, text, boolean) to authenticated;

create or replace function refund_payment_run(
  p_payment_id uuid, p_amount_cents int default null, p_reason text default null,
  p_method text default null, p_reference text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pay payments%rowtype; v_amount int; v_remaining int; v_id uuid; v_ccy char(3);
begin
  select * into pay from payments where id = p_payment_id for update;
  if not found then raise exception 'no such payment' using errcode = 'PT404'; end if;
  if pay.status not in ('succeeded', 'partially_refunded') then
    raise exception 'a % payment cannot be refunded', pay.status using errcode = 'PT409';
  end if;

  -- Decision 111: a reservation fee whose credit has been spent cannot be refunded.
  if pay.kind = 'reservation_fee'
     and exists (select 1 from member_credits mc
                  where mc.payment_id = pay.id and mc.voided_at is null and mc.used_cents > 0) then
    raise exception 'this fee was used as credit, so it cannot be refunded'
      using errcode = 'PT409';
  end if;

  -- Decision 110(a): a gift card that has been redeemed cannot be refunded (its
  -- value is already on somebody's account as gift credit).
  if pay.gift_card_id is not null
     and exists (select 1 from gift_cards gc where gc.id = pay.gift_card_id and gc.status = 'redeemed') then
    raise exception 'this gift card has been redeemed, so it cannot be refunded'
      using errcode = 'PT409';
  end if;

  v_remaining := pay.amount_cents - coalesce(pay.refunded_cents, 0);
  v_amount := coalesce(p_amount_cents, v_remaining);
  -- Decision 120(a): a 0 payment (a 100% code) is refunded at 0, which cancels it.
  if (v_amount <= 0 and pay.amount_cents > 0) or v_amount < 0 or v_amount > v_remaining then
    raise exception 'that is more than is left to refund' using errcode = 'PT400';
  end if;
  v_ccy := pay.currency;

  -- Decision 118: a refund before the plan is claimed cancels the waiting plan.
  update xendit_purchases set guest_status = 'refunded', updated_at = now()
   where guest_payment_id = pay.id and guest_status in ('held', 'refund_pending');

  if v_amount = 0 then
    p_method := coalesce(nullif(p_method, 'xendit'), 'other');
    p_reference := coalesce(nullif(btrim(coalesce(p_reference, '')), ''), 'No charge (code)');
  end if;

  if coalesce(p_method, '') = 'xendit' then
    -- The server action has already called POST /v3/refunds; p_reference is the
    -- rfd- id. Record pending; the webhook settles it.
    insert into payment_refunds (studio_id, payment_id, member_id, amount_cents, currency,
                                 reason, method, reference, status, xendit_refund_id, refunded_by)
    values (pay.studio_id, pay.id, pay.member_id, v_amount, v_ccy,
            p_reason, 'xendit', p_reference, 'pending', p_reference, auth.uid())
    returning id into v_id;
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (pay.studio_id, auth.uid(), 'payment.refunded', 'payments', pay.id,
            jsonb_build_object('refund_id', v_id, 'amount_cents', v_amount, 'method', 'xendit',
                               'reason', p_reason, 'reference', p_reference, 'status', 'pending'));
    return jsonb_build_object('ok', true, 'refund_id', v_id, 'status', 'pending', 'amount_cents', v_amount);
  else
    -- Studio-recorded: method required and valid, reference required.
    if coalesce(p_method, '') not in ('cash','bank_transfer','card_terminal','gcash','other') then
      raise exception 'unknown refund method' using errcode = 'PT400';
    end if;
    if coalesce(btrim(p_reference), '') = '' then
      raise exception 'a refund reference is required' using errcode = 'PT400';
    end if;
    insert into payment_refunds (studio_id, payment_id, member_id, amount_cents, currency,
                                 reason, method, reference, status, settled_at, refunded_by)
    values (pay.studio_id, pay.id, pay.member_id, v_amount, v_ccy,
            p_reason, p_method, p_reference, 'succeeded', now(), auth.uid())
    returning id into v_id;
    perform apply_payment_refund(v_id);
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (pay.studio_id, auth.uid(), 'payment.refunded', 'payments', pay.id,
            jsonb_build_object('refund_id', v_id, 'amount_cents', v_amount, 'method', p_method,
                               'reason', p_reason, 'reference', p_reference, 'status', 'succeeded'));
    return jsonb_build_object('ok', true, 'refund_id', v_id, 'status', 'succeeded', 'amount_cents', v_amount);
  end if;
end $$;
revoke execute on function refund_payment_run(uuid, int, text, text, text) from public, anon, authenticated;
grant  execute on function refund_payment_run(uuid, int, text, text, text) to service_role;

-- The anon surface is unchanged: exactly FIFTEEN.
do $$ declare n int; begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'expect\_%' and p.proname <> 'call_jsonb';
  if n <> 15 then raise exception 'anon surface is % not 15', n; end if;
end $$;
