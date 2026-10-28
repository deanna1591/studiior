-- Decision 78 amendment (d): the signed-up-but-never-booked nudge.
-- re-issues: convert_keep_sweep(uuid, timestamptz)
--
-- A member who signed up, has never held a booking, and is still eligible for a
-- free first class gets convert_book_first at day 1 and again at day 7 if nothing
-- is booked. It asks for a booking rather than following a class, so it sends
-- whenever the studio has published bookable classes — including before the
-- opening date (it runs ahead of the Decision 14(c) opening skip). Gated by the
-- convert sequence switch; capped per studio per night, oldest sign-ups first.

-- The per-night cap. Default 30; a studio with more eligible sign-ups than this
-- sends the cap tonight (oldest first) and the rest on the next night.
alter table studio_settings
  add column if not exists convert_book_first_daily_cap int not null default 30;
alter table studio_settings
  drop constraint if exists convert_book_first_daily_cap_nonneg;
alter table studio_settings
  add constraint convert_book_first_daily_cap_nonneg
  check (convert_book_first_daily_cap >= 0);

-- The email, in the 80a frame (render_notification wraps it and fills
-- {accent}/{accent_on}). No em dashes. convert_* is gated on sequence_email
-- by notification_wanted, so a member who muted the sequence does not get it.
insert into notification_templates (key, subject, text_body, html_body) values
  ('convert_book_first',
   'Your first class is on us, {first_name}',
   'Hi {first_name},

You signed up with {studio_name} but haven''t picked a class yet. Your first class is free. Pick any time that suits and we''ll take it from there.

{book_url}

{studio_name}',
   '<p>Hi {first_name},</p>
<p>You signed up with {studio_name} but haven&#39;t picked a class yet. Your first class is free. Pick any time that suits and we&#39;ll take it from there.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{book_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Book your free class</a></td></tr></table>
<p>{studio_name}</p>')
on conflict (key) do nothing;

CREATE OR REPLACE FUNCTION public.convert_keep_sweep(p_studio_id uuid, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  st studio_settings%rowtype;
  s  studios%rowtype;
  v_offer membership_plans%rowtype;
  v_tz text; v_fmt text; v_now_date date;
  v_plans text; v_book text; v_buy text;
  v_offer_name text; v_offer_price text; v_offer_detail text;
  r record;
  v_iw jsonb; v_ends timestamptz; v_end_date date;
  v_attended boolean; v_noshow boolean; v_notpurch boolean;
  v_class_date date; v_when text; v_offer_ends text;
  v_payload jsonb; v_sched timestamptz;
  km record; v_newer boolean; v_has_active boolean; v_mend date; v_auto boolean;
  v_kbuy text; v_kpayload jsonb;
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
    return jsonb_build_object('queued', 0);
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
    v_offer_price  := fmt_money(v_offer.price_cents, v_offer.currency);
    v_offer_detail := plan_card_detail(v_offer.id);
  else
    v_buy        := v_plans;
    v_offer_name := 'a membership';
    v_offer_price := ''; v_offer_detail := '';
  end if;

  if coalesce(st.retention_tasks_enabled, false) or coalesce(st.keep_sequence_enabled, false) then
    insert into job_runs (job_key, run_for, status)
    values ('health_refresh:' || p_studio_id::text, v_now_date, 'done')
    on conflict (job_key, run_for) do nothing;
    if found then perform refresh_studio_health(p_studio_id); end if;
  end if;

  -- Decision 78 (d): the signed-up-but-never-booked nudge. A member who joined,
  -- has never held a booking, and is still free-first eligible gets one email at
  -- day 1 and again at day 7 if nothing is booked. It asks for a booking rather
  -- than following a class, so it runs BEFORE the opening skip below and sends
  -- even before the studio has opened, as long as there are published bookable
  -- classes to pick from. Capped per studio per night, oldest sign-ups first; the
  -- WHERE excludes anyone already sent this step, so the cap counts new emails and
  -- the newest never starve behind an already-emailed older cohort.
  if coalesce(st.convert_sequence_enabled, false)
     and exists (select 1 from class_occurrences o
                  where o.studio_id = p_studio_id and o.status = 'scheduled'
                    and o.starts_at > p_now and month_published(p_studio_id, o.starts_at)) then
    v_sched := quiet_hours_shift((v_now_date + time '10:00') at time zone v_tz, v_tz);
    for r in
      select m.id as member_id,
             coalesce(nullif(m.first_name, ''), 'there') as first_name,
             case when m.joined_on <= v_now_date - 7 then 7 else 1 end as step
        from members m
       where m.studio_id = p_studio_id
         and m.deleted_at is null
         and m.joined_on is not null
         and m.joined_on <= v_now_date - 1
         and not exists (select 1 from bookings b where b.member_id = m.id)
         and coalesce((free_first_eligibility_run(p_studio_id, m.id, null) ->> 'ok')::boolean, false)
         and not exists (select 1 from notifications nx
                          where nx.dedupe_key = 'convert_book_first:'
                            || (case when m.joined_on <= v_now_date - 7 then '7' else '1' end)
                            || ':' || m.id::text)
       order by m.joined_on asc, m.id
       limit greatest(coalesce(st.convert_book_first_daily_cap, 30), 0)
    loop
      v_payload := jsonb_build_object(
        'first_name', r.first_name, 'studio_name', s.name,
        'book_url', v_book, 'plans_url', v_plans);
      if queue_notification(p_studio_id, r.member_id, 'convert_book_first', v_payload,
            'convert_book_first:' || r.step::text || ':' || r.member_id::text, v_sched) is not null then n := n + 1; end if;
    end loop;
  end if;

  -- Decision 14(c): a studio that has not opened yet (no attended/checked-in
  -- class, or its first is still ahead) gets no convert/keep/retention action —
  -- nobody can have drifted before a class has run. The health refresh above
  -- still runs; member_health now returns insufficient_history for its members.
  if studio_opened_on(p_studio_id) is null
     or studio_opened_on(p_studio_id) > v_now_date then
    return jsonb_build_object('queued', n, 'skipped', 'not_opened');
  end if;

  select coalesce(ov.body, df.text_body) into v_unconv_tpl
    from notification_templates df
    left join notification_templates_overrides ov on ov.studio_id = p_studio_id and ov.key = 'task_unconverted_message'
   where df.key = 'task_unconverted_message';
  select coalesce(ov.body, df.text_body) into v_atrisk_tpl
    from notification_templates df
    left join notification_templates_overrides ov on ov.studio_id = p_studio_id and ov.key = 'task_at_risk_message'
   where df.key = 'task_at_risk_message';

  if coalesce(st.convert_sequence_enabled, false) then
  for r in
    select b.id as booking_id, b.member_id, b.status as bstatus,
           o.id as occ_id, o.starts_at, o.ends_at,
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
      'class_name', r.class_name, 'when', v_when, 'occurrence_id', r.occ_id,
      'instructor_first_name', coalesce(nullif(r.instr_first, ''), 'your instructor'),
      'offer_plan_name', v_offer_name, 'offer_price', v_offer_price, 'offer_detail', v_offer_detail,
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
  end if;

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
      v_mend := coalesce(km.expires_on, (km.current_period_end at time zone v_tz)::date);
      v_auto := coalesce(km.auto_renew, false) or km.stripe_subscription_id is not null;
      v_newer := exists (select 1 from memberships ms2
                          where ms2.member_id = km.member_id and ms2.id <> km.mid
                            and ms2.status = 'active'
                            and coalesce(ms2.starts_on, '-infinity'::date) >= coalesce(km.starts_on, '-infinity'::date));
      v_has_active := exists (select 1 from memberships ms2
                               where ms2.member_id = km.member_id and ms2.status = 'active'
                                 and coalesce(ms2.expires_on, 'infinity'::date) > v_now_date);
      v_kbuy := case when coalesce(km.plan_status, 'active') <> 'archived'
                     then member_portal_url(p_studio_id, '/buy/' || km.plan_id::text)
                     else v_plans end;
      v_kpayload := jsonb_build_object(
        'first_name', km.first_name, 'studio_name', s.name,
        'plan_name', km.plan_name,
        'expires_on', case when v_mend is not null then to_char(v_mend, 'FMDD Mon YYYY') else '' end,
        'credits_left', coalesce(km.credits_remaining, 0),
        'buy_url', v_kbuy, 'book_url', v_book, 'schedule_url', v_book);

      if km.plan_type = 'recurring' and not v_auto and km.status in ('active', 'past_due')
         and not v_newer and v_mend is not null then
        if v_now_date = v_mend - 7 and queue_notification(p_studio_id, km.member_id, 'keep_renew_7',
              v_kpayload, 'keep_renew_7:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
        if v_now_date = v_mend - 1 and queue_notification(p_studio_id, km.member_id, 'keep_renew_1',
              v_kpayload, 'keep_renew_1:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
        if v_now_date = v_mend and queue_notification(p_studio_id, km.member_id, 'keep_renew_0',
              v_kpayload, 'keep_renew_0:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
        if v_now_date = v_mend + 3 and not v_has_active
           and queue_notification(p_studio_id, km.member_id, 'keep_lapsed_3',
              v_kpayload, 'keep_lapsed_3:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
      end if;

      if km.credits_remaining > 0 and km.expires_on is not null
         and km.status = 'active' and not v_newer then
        if v_now_date = km.expires_on - 7 and queue_notification(p_studio_id, km.member_id, 'keep_credits_7',
              v_kpayload, 'keep_credits_7:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
        if v_now_date = km.expires_on - 2 and queue_notification(p_studio_id, km.member_id, 'keep_credits_2',
              v_kpayload, 'keep_credits_2:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
      end if;

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
  end if;

  if coalesce(st.retention_tasks_enabled, false) then
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
        if not exists (select 1 from notifications nx where nx.member_id = km.member_id
                        and nx.template_key = 'keep_drifting' and nx.created_at > p_now - interval '30 days') then
          v_sched := quiet_hours_shift((v_now_date + time '10:00') at time zone v_tz, v_tz);
          if queue_notification(p_studio_id, km.member_id, 'keep_drifting',
                jsonb_build_object('first_name', km.first_name, 'studio_name', s.name, 'schedule_url', v_book, 'book_url', v_book),
                'keep_drifting:' || km.member_id::text || ':' || v_now_date::text, v_sched) is not null then n := n + 1; end if;
        end if;
        insert into member_tasks (studio_id, member_id, kind, reason, suggested_message, assigned_role)
        values (p_studio_id, km.member_id, 'drifting_fyi', km.hr, null, st.retention_tasks_to)
        on conflict (member_id, kind) where status = 'open' do nothing;
      end if;
    end loop;
  end if;

  return jsonb_build_object('queued', n);
end $function$;

revoke execute on function convert_keep_sweep(uuid, timestamptz) from public, anon, authenticated;
grant  execute on function convert_keep_sweep(uuid, timestamptz) to service_role;

-- The anon surface must not have moved: this migration adds no anon function.
do $$
declare n int;
begin
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'expect_%' and p.proname not in ('login','sig','psig');
  if n <> 13 then raise exception 'anon surface drifted: expected 13, got %', n; end if;
end $$;
