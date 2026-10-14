-- Decision 78c — the sweep gains a daily health refresh and the health-band
-- task rules (at_risk tasks with auto-close, drifting FYI + the soft email).
-- Re-issued from 20260832620000; the convert and keep blocks are unchanged.
--
-- re-issues: convert_keep_sweep(uuid, timestamptz), convert_keep_sweep_all(timestamptz)

create or replace function convert_keep_sweep(p_studio_id uuid, p_now timestamptz default now())
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
  -- keep
  km record; v_newer boolean; v_has_active boolean; v_mend date; v_auto boolean;
  v_kbuy text; v_kpayload jsonb;
  -- tasks (78c)
  v_atrisk_tpl text; v_unconv_tpl text;
  n int := 0;
begin
  if not is_service_context() then
    raise exception 'this is a scheduled job, not a user action' using errcode = 'PT403';
  end if;

  select * into st from studio_settings where studio_id = p_studio_id;
  if not found or not (coalesce(st.convert_sequence_enabled, false)
                       or coalesce(st.keep_sequence_enabled, false)
                       or coalesce(st.retention_tasks_enabled, false)) then
    return jsonb_build_object('queued', 0);   -- all off: the sweep writes nothing
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

  -- Decision 78c: refresh health once per studio-local day (deduped via a
  -- per-studio job_runs row), so bands move for a member who simply stops
  -- coming. Idempotent and cheap; runs for tasks/keep studios.
  if coalesce(st.retention_tasks_enabled, false) or coalesce(st.keep_sequence_enabled, false) then
    insert into job_runs (job_key, run_for, status)
    values ('health_refresh:' || p_studio_id::text, v_now_date, 'done')
    on conflict (job_key, run_for) do nothing;
    if found then perform refresh_studio_health(p_studio_id); end if;
  end if;

  -- The task Viber copy — a per-studio override wins over the default template.
  select coalesce(ov.body, df.text_body) into v_unconv_tpl
    from notification_templates df
    left join notification_templates_overrides ov on ov.studio_id = p_studio_id and ov.key = 'task_unconverted_message'
   where df.key = 'task_unconverted_message';
  select coalesce(ov.body, df.text_body) into v_atrisk_tpl
    from notification_templates df
    left join notification_templates_overrides ov on ov.studio_id = p_studio_id and ov.key = 'task_at_risk_message'
   where df.key = 'task_at_risk_message';

  -- =========================================================================
  -- CONVERT (78a) — free-first members, gated on the convert switch.
  -- =========================================================================
  if coalesce(st.convert_sequence_enabled, false) then
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

    if r.bstatus = 'booked' and v_class_date = v_now_date + 1 then
      v_sched := quiet_hours_shift((v_now_date + time '18:00') at time zone v_tz, v_tz);
      if queue_notification(p_studio_id, r.member_id, 'convert_before_class', v_payload,
            'convert_before_class:' || r.booking_id::text, v_sched) is not null then n := n + 1; end if;
    end if;

    if v_noshow and v_notpurch and v_now_date = v_class_date + 1 then
      v_sched := quiet_hours_shift((v_now_date + time '10:00') at time zone v_tz, v_tz);
      if queue_notification(p_studio_id, r.member_id, 'convert_missed_you', v_payload,
            'convert_missed_you:' || r.booking_id::text, v_sched) is not null then n := n + 1; end if;
    end if;

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
        insert into member_tasks (studio_id, member_id, kind, reason, suggested_message, assigned_role)
        values (p_studio_id, r.member_id, 'unconverted_day7',
                'Free class ' || (v_now_date - v_class_date) || ' days ago, not yet booked again',
                replace(replace(replace(v_unconv_tpl, '{first_name}', r.first_name), '{studio_name}', s.name), '{offer_plan_name}', v_offer_name),
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
  end if;  -- convert

  -- =========================================================================
  -- KEEP (78b) — renewals, credit expiry, win-back. Gated on the keep switch.
  -- One scheduled send time (10:00 local, quiet-shifted) for every keep rule.
  -- =========================================================================
  if coalesce(st.keep_sequence_enabled, false) then
    v_sched := quiet_hours_shift((v_now_date + time '10:00') at time zone v_tz, v_tz);
    for km in
      select ms.id as mid, ms.member_id, ms.plan_id, ms.status, ms.starts_on,
             ms.expires_on, ms.current_period_end, ms.credits_remaining,
             ms.auto_renew, ms.stripe_subscription_id,
             pl.name as plan_name, pl.type as plan_type, pl.status as plan_status,
             coalesce(nullif(m.first_name, ''), 'there') as first_name
        from memberships ms
        join membership_plans pl on pl.id = ms.plan_id
        join members m on m.id = ms.member_id
       where ms.studio_id = p_studio_id and m.deleted_at is null
    loop
      -- The membership's own end date (recurring ends on current_period_end,
      -- packs on expires_on).
      v_mend := coalesce(km.expires_on, (km.current_period_end at time zone v_tz)::date);
      -- Auto-renewing (saved card / subscription) memberships renew themselves.
      v_auto := coalesce(km.auto_renew, false) or km.stripe_subscription_id is not null;
      -- A newer/replacement active membership stops the lapsing one's chase.
      v_newer := exists (select 1 from memberships ms2
                          where ms2.member_id = km.member_id and ms2.id <> km.mid
                            and ms2.status = 'active'
                            and coalesce(ms2.starts_on, '-infinity'::date) >= coalesce(km.starts_on, '-infinity'::date));
      -- Any active, not-yet-expired membership the member holds right now.
      v_has_active := exists (select 1 from memberships ms2
                               where ms2.member_id = km.member_id and ms2.status = 'active'
                                 and coalesce(ms2.expires_on, 'infinity'::date) > v_now_date);
      -- Keep buy_url: this plan unless archived, then the plans page.
      v_kbuy := case when coalesce(km.plan_status, 'active') <> 'archived'
                     then member_portal_url(p_studio_id, '/buy/' || km.plan_id::text)
                     else v_plans end;
      v_kpayload := jsonb_build_object(
        'first_name', km.first_name, 'studio_name', s.name,
        'plan_name', km.plan_name,
        'expires_on', case when v_mend is not null then to_char(v_mend, 'FMDD Mon YYYY') else '' end,
        'credits_left', coalesce(km.credits_remaining, 0),
        'buy_url', v_kbuy, 'book_url', v_book, 'schedule_url', v_book);

      -- RENEW — a recurring membership that must be renewed by hand.
      if km.plan_type = 'recurring' and not v_auto and km.status in ('active', 'past_due')
         and not v_newer and v_mend is not null then
        if v_now_date = v_mend - 7 and queue_notification(p_studio_id, km.member_id, 'keep_renew_7',
              v_kpayload, 'keep_renew_7:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
        if v_now_date = v_mend - 1 and queue_notification(p_studio_id, km.member_id, 'keep_renew_1',
              v_kpayload, 'keep_renew_1:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
        if v_now_date = v_mend and queue_notification(p_studio_id, km.member_id, 'keep_renew_0',
              v_kpayload, 'keep_renew_0:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
        -- LAPSED — 3 days after it ended, and nothing has replaced it.
        if v_now_date = v_mend + 3 and not v_has_active
           and queue_notification(p_studio_id, km.member_id, 'keep_lapsed_3',
              v_kpayload, 'keep_lapsed_3:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
      end if;

      -- CREDITS — a pack with classes left, keyed on the credit expiry.
      if km.credits_remaining > 0 and km.expires_on is not null
         and km.status = 'active' and not v_newer then
        if v_now_date = km.expires_on - 7 and queue_notification(p_studio_id, km.member_id, 'keep_credits_7',
              v_kpayload, 'keep_credits_7:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
        if v_now_date = km.expires_on - 2 and queue_notification(p_studio_id, km.member_id, 'keep_credits_2',
              v_kpayload, 'keep_credits_2:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
      end if;

      -- WIN-BACK — 30 and 60 days after a membership ended with no membership
      -- since (so only the member's last one fires) and nothing active now.
      if v_mend is not null and not v_has_active
         and not exists (select 1 from memberships ms3
                          where ms3.member_id = km.member_id
                            and coalesce(ms3.starts_on, '-infinity'::date) > v_mend) then
        if v_now_date = v_mend + 30 and queue_notification(p_studio_id, km.member_id, 'keep_winback_30',
              v_kpayload, 'keep_winback_30:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
        if v_now_date = v_mend + 60 and queue_notification(p_studio_id, km.member_id, 'keep_winback_60',
              v_kpayload, 'keep_winback_60:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
      end if;
    end loop;
  end if;  -- keep

  -- =========================================================================
  -- TASKS (78c) — health-band retention tasks. Gated on retention_tasks_enabled;
  -- the daily health refresh above has already moved bands.
  -- =========================================================================
  if coalesce(st.retention_tasks_enabled, false) then
    -- Recovered: close an open at_risk/drifting task when the band is healthy or
    -- new again, or the member has checked in since the task was raised.
    update member_tasks mt
       set status = 'dismissed', closed_at = now(), close_note = 'recovered'
     where mt.studio_id = p_studio_id and mt.status = 'open'
       and mt.kind in ('at_risk', 'drifting_fyi')
       and ( coalesce((select m.health_band from members m where m.id = mt.member_id), 'new') in ('healthy', 'new')
          or exists (select 1 from check_ins ci where ci.member_id = mt.member_id and ci.checked_in_at > mt.created_at) );

    for km in
      select m.id as member_id, m.health_band as hb, m.health_reason as hr,
             coalesce(nullif(m.first_name, ''), 'there') as first_name
        from members m
       where m.studio_id = p_studio_id and m.status <> 'archived'
         and m.health_band in ('at_risk', 'drifting')
    loop
      if km.hb = 'at_risk' then
        insert into member_tasks (studio_id, member_id, kind, reason, suggested_message, assigned_role)
        values (p_studio_id, km.member_id, 'at_risk', km.hr,
                replace(replace(v_atrisk_tpl, '{first_name}', km.first_name), '{studio_name}', s.name),
                st.retention_tasks_to)
        on conflict (member_id, kind) where status = 'open' do nothing;
      elsif km.hb = 'drifting' then
        -- the soft email, at most once per 30 days (sequence_email gate + quiet hours)
        if not exists (select 1 from notifications nx where nx.member_id = km.member_id
                        and nx.template_key = 'keep_drifting' and nx.created_at > p_now - interval '30 days') then
          v_sched := quiet_hours_shift((v_now_date + time '10:00') at time zone v_tz, v_tz);
          if queue_notification(p_studio_id, km.member_id, 'keep_drifting',
                jsonb_build_object('first_name', km.first_name, 'studio_name', s.name, 'schedule_url', v_book, 'book_url', v_book),
                'keep_drifting:' || km.member_id::text || ':' || v_now_date::text, v_sched) is not null then n := n + 1; end if;
        end if;
        -- the FYI marker (read only by the instructor roster; never a task-list row)
        insert into member_tasks (studio_id, member_id, kind, reason, suggested_message, assigned_role)
        values (p_studio_id, km.member_id, 'drifting_fyi', km.hr, null, st.retention_tasks_to)
        on conflict (member_id, kind) where status = 'open' do nothing;
      end if;
    end loop;
  end if;  -- tasks

  return jsonb_build_object('queued', n);
end $$;
revoke execute on function convert_keep_sweep(uuid, timestamptz) from public, anon, authenticated;
grant  execute on function convert_keep_sweep(uuid, timestamptz) to service_role;

-- The driver — every active studio with a 78 toggle on (convert OR keep).
create or replace function convert_keep_sweep_all(p_now timestamptz default now())
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
     where s.status = 'active'
       and (coalesce(ss.convert_sequence_enabled, false) or coalesce(ss.keep_sequence_enabled, false)
            or coalesce(ss.retention_tasks_enabled, false))
  loop
    perform convert_keep_sweep(r.studio_id, p_now);
    n := n + 1;
  end loop;
  return jsonb_build_object('studios', n);
end $$;
revoke execute on function convert_keep_sweep_all(timestamptz) from public, anon, authenticated;
grant  execute on function convert_keep_sweep_all(timestamptz) to service_role;
