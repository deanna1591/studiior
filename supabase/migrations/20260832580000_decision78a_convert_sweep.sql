-- Decision 78a — the hourly convert sweep and its driver.
--
-- creates: quiet_hours_shift(timestamptz, text), convert_keep_sweep(uuid, timestamptz), convert_keep_sweep_all(timestamptz)
--
-- Service-role only. Each rule is evaluated per free-first booking; queue_
-- notification holds delivery via scheduled_for and dedupes on its key, and
-- checks sequence_email, so the sweep is idempotent and respects the opt-out. A
-- target send inside quiet hours (21:00–08:00 studio time) is pushed to 08:00.
-- p_now defaults to now() (the cron) and exists so the suite can drive the rules
-- at chosen instants.

create function quiet_hours_shift(p_ts timestamptz, p_tz text)
returns timestamptz language sql stable set search_path = public as $$
  select case
    when extract(hour from p_ts at time zone p_tz) >= 21
      then (((p_ts at time zone p_tz)::date + 1) + time '08:00') at time zone p_tz
    when extract(hour from p_ts at time zone p_tz) < 8
      then ((p_ts at time zone p_tz)::date + time '08:00') at time zone p_tz
    else p_ts
  end;
$$;
revoke execute on function quiet_hours_shift(timestamptz, text) from public, anon, authenticated;
grant  execute on function quiet_hours_shift(timestamptz, text) to service_role;

create function convert_keep_sweep(p_studio_id uuid, p_now timestamptz default now())
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  st studio_settings%rowtype;
  s  studios%rowtype;
  v_offer membership_plans%rowtype;
  v_tz text; v_fmt text; v_now_date date;
  v_plans text; v_book text; v_buy text;
  v_offer_name text; v_offer_price text;
  r record;
  v_iw jsonb; v_ends timestamptz; v_end_date date;
  v_attended boolean; v_noshow boolean; v_notpurch boolean;
  v_class_date date; v_when text; v_offer_ends text;
  v_payload jsonb; v_sched timestamptz;
  n int := 0;
begin
  if not is_service_context() then
    raise exception 'this is a scheduled job, not a user action' using errcode = 'PT403';
  end if;

  select * into st from studio_settings where studio_id = p_studio_id;
  if not found or not coalesce(st.convert_sequence_enabled, false) then
    return jsonb_build_object('queued', 0);   -- off: the sweep writes nothing
  end if;
  select * into s from studios where id = p_studio_id;
  v_tz  := s.timezone;
  v_fmt := coalesce(st.time_format, '24h');
  v_now_date := (p_now at time zone v_tz)::date;

  v_plans := member_portal_url(p_studio_id, '/account/plan');
  v_book  := member_portal_url(p_studio_id, '/book');
  if st.intro_offer_plan_id is not null then
    select * into v_offer from membership_plans where id = st.intro_offer_plan_id;
  end if;
  if v_offer.id is not null then
    v_buy        := member_portal_url(p_studio_id, '/buy/' || v_offer.id::text);
    v_offer_name := v_offer.name;
    v_offer_price := v_offer.currency || ' ' || trim(to_char(round(v_offer.price_cents / 100.0, 2), 'FM999999990.00'));
  else
    v_buy        := v_plans;
    v_offer_name := 'a membership';
    v_offer_price := '';
  end if;

  -- Every free-first class of the studio (a member's OWN comp booking, not a
  -- guest seat). Each booking carries its own sequence, so a no-show rebook (a
  -- second comp booking) is sequenced independently.
  for r in
    select b.id as booking_id, b.member_id, b.status as bstatus,
           o.starts_at, o.ends_at,
           coalesce(ct.name, 'your class') as class_name,
           split_part(coalesce(i.display_name, ''), ' ', 1) as instr_first,
           coalesce(nullif(m.first_name, ''), 'there') as first_name
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
      left join class_types ct on ct.id = o.class_type_id
      left join instructors i on i.id = o.instructor_id
      join members m on m.id = b.member_id
     where b.studio_id = p_studio_id
       and b.payment_source = 'comp'
       and m.deleted_at is null
       and not exists (select 1 from guest_passes gp
                        where gp.guest_booking_id = b.id and gp.host_member_id is not null)
  loop
    v_notpurch := not exists (select 1 from memberships ms where ms.member_id = r.member_id);
    v_attended := r.bstatus = 'attended'
                  or exists (select 1 from check_ins ci where ci.booking_id = r.booking_id);
    v_noshow   := r.bstatus = 'no_show';
    v_class_date := (r.starts_at at time zone v_tz)::date;
    v_iw   := intro_window(r.member_id, p_now);
    v_ends := nullif(v_iw ->> 'ends_at', '')::timestamptz;
    v_end_date := (v_ends at time zone v_tz)::date;
    v_when := to_char(r.starts_at at time zone v_tz, 'FMDay FMDD Mon') || ' at ' || fmt_clock(r.starts_at, v_tz, v_fmt);
    v_offer_ends := case when v_ends is not null then to_char(v_ends at time zone v_tz, 'FMDD Mon YYYY') else '' end;

    v_payload := jsonb_build_object(
      'first_name', r.first_name, 'studio_name', s.name,
      'class_name', r.class_name, 'when', v_when,
      'instructor_first_name', coalesce(nullif(r.instr_first, ''), 'your instructor'),
      'offer_plan_name', v_offer_name, 'offer_price', v_offer_price,
      'offer_ends', v_offer_ends, 'buy_url', v_buy,
      'plans_url', v_plans, 'book_url', v_book);

    -- before_class — the evening before (18:00 local), class is tomorrow, booked.
    if r.bstatus = 'booked' and v_class_date = v_now_date + 1 then
      v_sched := quiet_hours_shift((v_now_date + time '18:00') at time zone v_tz, v_tz);
      if queue_notification(p_studio_id, r.member_id, 'convert_before_class', v_payload,
            'convert_before_class:' || r.booking_id::text, v_sched) is not null then n := n + 1; end if;
    end if;

    -- missed_you — a no-show, the morning after, once, not purchased.
    if v_noshow and v_notpurch and v_now_date = v_class_date + 1 then
      v_sched := quiet_hours_shift((v_now_date + time '10:00') at time zone v_tz, v_tz);
      if queue_notification(p_studio_id, r.member_id, 'convert_missed_you', v_payload,
            'convert_missed_you:' || r.booking_id::text, v_sched) is not null then n := n + 1; end if;
    end if;

    -- The ladder — only for a member who ATTENDED their free class and has not
    -- purchased. Re-checked each day, so a purchase stops it.
    if v_attended and v_notpurch then
      if p_now >= r.ends_at + interval '2 hours' and p_now < r.ends_at + interval '26 hours' then
        v_sched := quiet_hours_shift(r.ends_at + interval '2 hours', v_tz);
        if queue_notification(p_studio_id, r.member_id, 'convert_after_class', v_payload,
              'convert_after_class:' || r.booking_id::text, v_sched) is not null then n := n + 1; end if;
      end if;

      if v_now_date = v_class_date + 3 then
        v_sched := quiet_hours_shift((v_now_date + time '10:00') at time zone v_tz, v_tz);
        if queue_notification(p_studio_id, r.member_id, 'convert_day3', v_payload,
              'convert_day3:' || r.booking_id::text, v_sched) is not null then n := n + 1; end if;
      end if;

      if v_now_date = v_class_date + 7 then
        v_sched := quiet_hours_shift((v_now_date + time '10:00') at time zone v_tz, v_tz);
        if queue_notification(p_studio_id, r.member_id, 'convert_day7', v_payload,
              'convert_day7:' || r.booking_id::text, v_sched) is not null then n := n + 1; end if;
        -- the retention task — a short Viber text, assigned per the studio's setting.
        insert into member_tasks (studio_id, member_id, kind, reason, suggested_message, assigned_role)
        values (p_studio_id, r.member_id, 'unconverted_day7',
                'Free class ' || (v_now_date - v_class_date) || ' days ago, not yet booked again',
                'Hi ' || r.first_name || '! It''s ' || s.name || ' — hope you enjoyed your first class. '
                  || 'If you''d like to keep going, ' || v_offer_name || ' is a lovely place to start. '
                  || 'Any questions, just message me here.',
                st.retention_tasks_to)
        on conflict (member_id, kind) where status = 'open' do nothing;
      end if;

      if v_offer.id is not null and v_ends is not null and v_now_date = v_end_date then
        v_sched := quiet_hours_shift((v_now_date + time '10:00') at time zone v_tz, v_tz);
        if queue_notification(p_studio_id, r.member_id, 'convert_last_day', v_payload,
              'convert_last_day:' || r.booking_id::text || ':' || v_end_date::text, v_sched) is not null then n := n + 1; end if;
      end if;
    end if;
  end loop;

  return jsonb_build_object('queued', n);
end $$;
revoke execute on function convert_keep_sweep(uuid, timestamptz) from public, anon, authenticated;
grant  execute on function convert_keep_sweep(uuid, timestamptz) to service_role;

-- The driver — every active studio with a 78 toggle on (78a: the convert switch).
create function convert_keep_sweep_all(p_now timestamptz default now())
returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  if not is_service_context() then
    raise exception 'this is a scheduled job, not a user action' using errcode = 'PT403';
  end if;
  for r in
    select ss.studio_id
      from studio_settings ss join studios s on s.id = ss.studio_id
     where s.status = 'active' and coalesce(ss.convert_sequence_enabled, false)
  loop
    perform convert_keep_sweep(r.studio_id, p_now);
    n := n + 1;
  end loop;
  return jsonb_build_object('studios', n);
end $$;
revoke execute on function convert_keep_sweep_all(timestamptz) from public, anon, authenticated;
grant  execute on function convert_keep_sweep_all(timestamptz) to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin perform cron.unschedule('studiior-convert-keep'); exception when others then null; end;
    perform cron.schedule('studiior-convert-keep', '0 * * * *',
      $c$select convert_keep_sweep_all()$c$);
  end if;
end $$;
