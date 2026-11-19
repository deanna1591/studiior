-- Decision 116 amendment (b) "a private keeps the class's coach". An empty
-- class is offered as a private slot only with its own coach; a free hour with
-- every available private coach. A replaced class pays nothing and sends no coach
-- email; the coach's private confirmation (private_booked) says it replaces
-- their empty class. The private_replaced_class template is REMOVED (nothing
-- sends it any more). Also fixes the double-braced {{book_url}}/{{schedule_url}}
-- in private_time_taken (116 a), which rendered a link wrapped in braces.
--
-- re-issues: private_slots(uuid, uuid, uuid, timestamptz, timestamptz), private_book_run(uuid, uuid, uuid, timestamptz, jsonb, text, text, text), compute_class_pay_run(uuid, integer), private_confirm_run(uuid), render_email(uuid, text, text, text, text, text, jsonb, text)

CREATE OR REPLACE FUNCTION public.private_slots(p_studio_id uuid, p_type_id uuid, p_instructor_id uuid, p_from timestamp with time zone, p_to timestamp with time zone)
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
  room_opts as (
    -- Decision 116(a): every room with nothing in it over the session plus the
    -- buffer (rep null), and every room whose only class then starts with the
    -- session and may be replaced (private_replace_ok). A pending replacement
    -- (room null) holds the room of the class it targets.
    select c.t1, c.t2, r.id as rid, r.name as rname,
           case when ov.n = 0 then null else ov.rep end as rep
      from cand c
      cross join rooms r
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
  ),
  free_pick as (
    -- A true free hour: the first free room at that start.
    select distinct on (ro.t1) ro.t1, ro.t2, ro.rid
      from room_opts ro where ro.rep is null
     order by ro.t1, ro.rname
  ),
  free_out as (
    -- Decision 116(b): a free hour is offered with every private coach who is
    -- available then and not teaching anything over the session.
    select fp.t1, fp.t2, fp.rid,
      array(select i.id from instructors i
            where i.studio_id = p_studio_id and i.status = 'active'
              and coalesce(i.teaches_privates, false)
              and (p_instructor_id is null or i.id = p_instructor_id)
              and instructor_available_at_run(i.id, fp.t1, fp.t2)
              and not exists (select 1 from class_occurrences x
                               where x.instructor_id = i.id and x.status <> 'cancelled'
                                 and tstzrange(x.starts_at, x.ends_at) && tstzrange(fp.t1, fp.t2))
            order by i.display_name) as cids,
      null::uuid as rep
    from free_pick fp
  ),
  rep_out as (
    -- Decision 116(b): with no free room, an empty class is offered only with the
    -- coach assigned to it, and only when that coach teaches privates, is
    -- available, and teaches nothing else over the session. One row per class.
    select ro.t1, ro.t2, ro.rid, array[i.id] as cids, ro.rep
      from room_opts ro
      join class_occurrences rc on rc.id = ro.rep
      join instructors i on i.id = rc.instructor_id
     where ro.rep is not null
       and not exists (select 1 from free_pick f where f.t1 = ro.t1)
       and i.status = 'active' and coalesce(i.teaches_privates, false)
       and (p_instructor_id is null or i.id = p_instructor_id)
       and instructor_available_at_run(i.id, ro.t1, ro.t2)
       and not exists (select 1 from class_occurrences x
                        where x.instructor_id = i.id and x.status <> 'cancelled'
                          and x.id <> ro.rep
                          and tstzrange(x.starts_at, x.ends_at) && tstzrange(ro.t1, ro.t2))
  )
  select u.t1, u.t2, u.rid, u.cids, u.rep
  from (select fo.t1, fo.t2, fo.rid, fo.cids, fo.rep from free_out fo where array_length(fo.cids, 1) >= 1
        union all
        select rr.t1, rr.t2, rr.rid, rr.cids, rr.rep from rep_out rr) u
  order by u.t1, u.rep nulls first;
end $function$;

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
  v_buf int; v_opt record; v_any_coach uuid;
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
      -- Decision 116(b): a replaced class pays nothing, in every case. Only the
      -- class's own coach can teach the private that replaces it, and they are
      -- paid for the private; no coach is ever displaced.
      v_amount := 0;
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

CREATE OR REPLACE FUNCTION public.private_confirm_run(p_occurrence_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o class_occurrences%rowtype; t private_session_types%rowtype;
        v_tz text; v_when text; v_booker uuid; r record; v_token text; v_claim text;
        x class_occurrences%rowtype; v_seat bookings%rowtype; v_xwhen text; v_pay_line text;
        v_rep_line text := ''; v_rep_html text := '';
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
      -- Decision 116(b): the private's coach IS the class's coach, so nobody is
      -- displaced and no separate notice goes; their private confirmation
      -- (private_booked) says it replaces their empty class.
      v_xwhen := fmt_clock(x.starts_at, v_tz, (select time_format from studio_settings where studio_id = o.studio_id));
      v_rep_line := E'\n\nThis replaces your empty '
                    || coalesce(x.name, (select name from class_types where id = x.class_type_id), 'class')
                    || ' at ' || v_xwhen || '.';
      v_rep_html := '<p>This replaces your empty <strong>'
                    || coalesce(x.name, (select name from class_types where id = x.class_type_id), 'class')
                    || '</strong> at ' || v_xwhen || '.</p>';
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
        'replaces_line', v_rep_line, 'replaces_html', v_rep_html,
        'schedule_url', instructor_portal_url(o.studio_id, '/instructor/schedule')),
      'private_booked:' || o.id::text);
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (o.studio_id, auth.uid(), 'private.confirmed', 'class_occurrences', o.id,
          jsonb_build_object('type', t.name, 'people', t.people, 'when', v_when));
end $function$;

CREATE OR REPLACE FUNCTION public.render_email(p_studio_id uuid, p_template_key text, p_recipient_type text, p_subject text, p_text text, p_html text, p_payload jsonb, p_first_name text DEFAULT NULL::text)
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
begin
  select * into s from studios where id = p_studio_id;
  select coalesce(time_format, '24h') into v_fmt from studio_settings where studio_id = p_studio_id;
  v_fmt := coalesce(v_fmt, '24h');
  v_is_staff := p_recipient_type = 'staff';
  v_sub := p_subject; v_txt := p_text; v_html := p_html;


  for k in select jsonb_object_keys(p_payload) loop
    v_sub  := replace(v_sub,  '{' || k || '}', coalesce(p_payload ->> k, ''));
    v_txt  := replace(v_txt,  '{' || k || '}', coalesce(p_payload ->> k, ''));
    v_html := replace(v_html, '{' || k || '}', coalesce(p_payload ->> k, ''));
  end loop;
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
                               'class_when','schedule_link','replaces_line','replaces_html'])) then
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
    case when v_is_staff then 'Your billing: ' || v_link
         when p_template_key in ('member_invite', 'instructor_invite', 'guest_invite', 'guest_waiver_reminder')
         then 'You are getting this because ' || s.name || ' set up your account.'
         when v_always
         then 'We always send this one — it''s about your booking or your membership. '
              || 'Choose which other emails you get: ' || v_link
         else 'Choose which emails you get: ' || v_link end);

  v_foot_html := concat_ws('<br>',
    v_contact_html, v_addr,
    case when v_is_staff then '<a href="' || v_link || '" style="color:#78716C">Your billing</a>'
         when p_template_key in ('member_invite', 'instructor_invite', 'guest_invite', 'guest_waiver_reminder')
         then 'You are getting this because ' || s.name || ' set up your account.'
         when v_always
         then 'We always send this one — it''s about your booking or your membership. '
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

-- ========================================================================
-- Templates
-- ========================================================================
-- private_booked (coach): the replacement line, platform default and every
-- override, inserted in place so nothing else in the text changes.
update notification_templates
   set text_body = replace(text_body, 'paid for it as a private.', 'paid for it as a private.{replaces_line}'),
       html_body = replace(html_body, 'paid for it as a private.</p>', 'paid for it as a private.</p>
{replaces_html}')
 where key = 'private_booked' and position('{replaces_line}' in text_body) = 0;
update notification_templates_overrides
   set body = replace(body, 'paid for it as a private.', 'paid for it as a private.{replaces_line}'),
       body_html = replace(body_html, 'paid for it as a private.</p>', 'paid for it as a private.</p>
{replaces_html}'),
       updated_at = now()
 where key = 'private_booked' and position('{replaces_line}' in body) = 0;

-- private_time_taken: the link was written {{book_url}}, which renders {https://...}.
update notification_templates
   set html_body = replace(html_body, '{{book_url}}', '{book_url}')
 where key = 'private_time_taken';
update notification_templates_overrides
   set body_html = replace(body_html, '{{book_url}}', '{book_url}'), updated_at = now()
 where key = 'private_time_taken';

-- private_replaced_class: nothing sends it any more (116 b). Removed.
delete from notification_templates_overrides where key = 'private_replaced_class';
delete from notification_templates where key = 'private_replaced_class';

do $chk$ begin
  if exists (select 1 from notification_templates where key = 'private_booked'
              and (position('{replaces_line}' in text_body) = 0 or position('{replaces_html}' in html_body) = 0)) then
    raise exception 'private_booked default did not take the replacement line';
  end if;
  if exists (select 1 from notification_templates_overrides where key = 'private_booked'
              and (position('{replaces_line}' in body) = 0 or position('{replaces_html}' in body_html) = 0)) then
    raise exception 'a private_booked override did not take the replacement line';
  end if;
end $chk$;

-- ========================================================================
-- Anon stays EXACTLY FOURTEEN.
-- ========================================================================
do $mig$ declare n int; begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'expect\_%';
  if n <> 14 then raise exception 'anon surface is % (want 14)', n; end if;
end $mig$;
