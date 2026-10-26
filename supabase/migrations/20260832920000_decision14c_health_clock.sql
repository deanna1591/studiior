-- Decision 14 (c) — the health clock starts when the studio does.
-- creates: studio_opened_on(uuid)
-- re-issues: member_health(uuid), convert_keep_sweep(uuid, timestamptz)
--
-- Pre-opening leads read first_month_stalled -> drifting because the health
-- window measured days-since-joined. The window now starts at greatest(joined_on,
-- studio_opened_on); before the studio opens every member is insufficient_history,
-- and convert_keep_sweep does nothing for an unopened studio. No enum changes, no
-- Decision 18 paths touched. Anon stays EXACTLY THIRTEEN (studio_opened_on is not
-- granted to anon). member_health / convert_keep_sweep re-issued VERBATIM from
-- their newest definitions (pg_get_functiondef) with only these changes.

-- --- studio_opened_on: the date a studio first ran a class members attended ---
-- The earliest occurrence with at least one attended booking or a check_in row,
-- OR the earliest IMPORTED check-in (occurrence_id null, import_id set) — a studio
-- that onboarded by importing a year of history HAS been running, and its members
-- must not read "the studio has not opened yet". NOT "attendance finalised" (a
-- studio that never finalises would never open) and NOT "first past non-cancelled
-- occurrence" (an unattended scheduled class is not an opening). STABLE,
-- service-only — never anon.
create or replace function studio_opened_on(p_studio_id uuid)
returns date
language sql stable security definer set search_path = public as $$
  select min(d) from (
    select (o.starts_at at time zone s.timezone)::date as d
      from class_occurrences o
      join studios s on s.id = o.studio_id
     where o.studio_id = p_studio_id
       and ( exists (select 1 from bookings b
                      where b.occurrence_id = o.id and b.status = 'attended')
             or exists (select 1 from check_ins ci where ci.occurrence_id = o.id) )
    union all
    select (ci.checked_in_at at time zone s.timezone)::date
      from check_ins ci
      join studios s on s.id = ci.studio_id
     where ci.studio_id = p_studio_id and ci.import_id is not null
  ) x;
$$;
revoke execute on function studio_opened_on(uuid) from public, anon, authenticated;
grant  execute on function studio_opened_on(uuid) to service_role;

-- --- member_health: window starts at greatest(joined_on, studio_opened_on) ---
CREATE OR REPLACE FUNCTION public.member_health(p_member_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  m            members%rowtype;
  tz           text;
  today        date;
  v_opened     date;
  v_window_start date;
  visits       int;
  last_visit   timestamptz;
  baseline     numeric;      -- median gap in days, the member's own rhythm
  gap_days     numeric;
  signals      jsonb := '[]'::jsonb;
  reason       text;
  band         text;
  severe       boolean := false;   -- signal 1 at >=3x, or signal 4
  -- signal 2
  bk_total     int;  bk_bad int;  bk_attended int;
  -- signal 4
  pd_when      date;
  pack_expired date;
  -- signal 5
  renews       date;  cur_use int;  prev_use int;
begin
  select * into m from members where id = p_member_id;
  if not found then return null; end if;

  select timezone into tz from studios where id = m.studio_id;
  today := (now() at time zone tz)::date;

  -- Decision 14(c): the health window starts when the STUDIO opens (its first
  -- attended/checked-in class), not when the member joined. Before the studio
  -- opens, every member is insufficient_history — no class has run, so nobody
  -- can have stalled or drifted.
  v_opened := studio_opened_on(m.studio_id);
  if v_opened is null or v_opened > today then
    return jsonb_build_object('band', 'insufficient_history',
      'reason', 'The studio has not opened yet — no classes have run.',
      'signals', '[]'::jsonb);
  end if;
  v_window_start := greatest(m.joined_on, v_opened);

  select count(*), max(checked_in_at) into visits, last_visit
    from check_ins where member_id = p_member_id;

  -- --- The first fortnight (Decision 14 amendment) -------------------------
  -- Not a warning and not a verdict: the signals have not had time to mean
  -- anything. Returned before them, because "the signals do not apply yet" is
  -- the whole content of this band. Without it days 0-13 fell through to
  -- `healthy` — signal 3 starts at day 14 and insufficient_history needs 35 —
  -- and a member who has never been in was described as though nothing was
  -- wrong, which is the opposite of true for the most rescuable member a studio
  -- has.
  if today - v_window_start < 14 then
    return jsonb_build_object(
      'band', 'new',
      'reason', case when visits = 0
                     then format('Joined %s days ago, no visits yet.', today - m.joined_on)
                     else format('Joined %s days ago, %s visit%s.',
                                 today - m.joined_on, visits,
                                 case when visits = 1 then '' else 's' end) end,
      'signals', '[]'::jsonb);
  end if;

  -- --- Signal 1: rhythm deviation, against the member's own baseline -------
  -- Minimum 6 visits to establish a baseline; below that there is no rhythm to
  -- deviate from and this signal stays silent rather than guessing.
  if visits >= 6 then
    select percentile_cont(0.5) within group (order by gap) into baseline
      from (
        select extract(epoch from (checked_in_at
               - lag(checked_in_at) over (order by checked_in_at))) / 86400 as gap
          from check_ins where member_id = p_member_id
      ) g where gap is not null;

    gap_days := extract(epoch from (now() - last_visit)) / 86400;

    if baseline is not null and baseline > 0
       and gap_days > greatest(baseline * 2, 10) then
      signals := signals || '"rhythm_deviation"'::jsonb;
      severe  := severe or gap_days >= baseline * 3;
      reason  := format(
        'Was coming about every %s days, last visit %s days ago (%s).',
        round(baseline)::int, floor(gap_days)::int,
        to_char(last_visit at time zone tz, 'FMDD FMMonth'));
    end if;
  end if;

  -- --- Signal 2: booking-to-attendance drift ------------------------------
  -- Intent persists, follow-through is going. Earlier than absence.
  select count(*),
         count(*) filter (where status in ('late_cancelled','no_show')),
         count(*) filter (where status = 'attended')
    into bk_total, bk_bad, bk_attended
    from bookings
   where member_id = p_member_id
     and booked_at >= now() - interval '6 weeks'
     and status in ('attended','no_show','late_cancelled');

  if bk_total >= 4 and bk_bad::numeric / bk_total >= 0.40 then
    signals := signals || '"booking_drift"'::jsonb;
    if reason is null then
      reason := format(
        'Booked %s classes in the last six weeks and attended %s — %s late cancellation%s and %s no-show%s.',
        bk_total, bk_attended,
        (select count(*) from bookings where member_id = p_member_id
          and booked_at >= now() - interval '6 weeks' and status = 'late_cancelled'),
        case when (select count(*) from bookings where member_id = p_member_id
                    and booked_at >= now() - interval '6 weeks' and status = 'late_cancelled') = 1
             then '' else 's' end,
        (select count(*) from bookings where member_id = p_member_id
          and booked_at >= now() - interval '6 weeks' and status = 'no_show'),
        case when (select count(*) from bookings where member_id = p_member_id
                    and booked_at >= now() - interval '6 weeks' and status = 'no_show') = 1
             then '' else 's' end);
    end if;
  end if;

  -- --- Signal 3: the first thirty days -------------------------------------
  if today - v_window_start between 14 and 35 and visits < 3 then
    signals := signals || '"first_month_stalled"'::jsonb;
    if reason is null then
      reason := format('Joined %s days ago, %s visit%s since.',
                       today - m.joined_on, visits, case when visits = 1 then '' else 's' end);
    end if;
  end if;

  -- --- Signal 4: payment state ---------------------------------------------
  -- Factual rather than predictive, but a live reason they cannot book.
  -- Dated from the failed payment, not from current_period_end: the period end
  -- is in the future for a membership that has only just failed, and a reason
  -- reading "unpaid since 1 September" on 30 August is not a fact.
  select coalesce(
           (select p.created_at::date from payments p
             where p.member_id = p_member_id and p.membership_id = ms.id
               and p.status = 'failed'
             order by p.created_at desc limit 1),
           ms.current_period_start::date)
    into pd_when
    from memberships ms
   where ms.member_id = p_member_id and ms.status = 'past_due'
   order by ms.current_period_end desc nulls last limit 1;

  if pd_when is not null then
    signals := signals || '"payment_state"'::jsonb;
    severe  := true;
    if reason is null then
      reason := format('Membership payment failed on %s, %s days ago.',
                       to_char(pd_when, 'FMDD FMMonth'), today - pd_when);
    end if;
  else
    select ms.expires_on into pack_expired
      from memberships ms join membership_plans p on p.id = ms.plan_id
     where ms.member_id = p_member_id and p.type = 'class_pack'
       and ms.expires_on between today - 30 and today
     order by ms.expires_on desc limit 1;

    if pack_expired is not null
       and not exists (
         select 1 from memberships ms2
          where ms2.member_id = p_member_id
            and ms2.starts_on > pack_expired
       ) then
      signals := signals || '"payment_state"'::jsonb;
      severe  := true;
      if reason is null then
        reason := format('Class pack expired %s days ago and nothing has been bought since.',
                         today - pack_expired);
      end if;
    end if;
  end if;

  -- --- Signal 5: renewal approaching, usage falling ------------------------
  -- Either half alone is not a signal. Together they are the moment someone
  -- decides not to renew.
  select ms.renews_on into renews
    from memberships ms
   where ms.member_id = p_member_id and ms.status = 'active'
     and ms.renews_on between today and today + 21
   order by ms.renews_on limit 1;

  if renews is not null then
    select count(*) into cur_use from check_ins
     where member_id = p_member_id
       and (checked_in_at at time zone tz)::date >= date_trunc('month', today)::date;
    select count(*) into prev_use from check_ins
     where member_id = p_member_id
       and (checked_in_at at time zone tz)::date
           >= (date_trunc('month', today) - interval '1 month')::date
       and (checked_in_at at time zone tz)::date < date_trunc('month', today)::date;

    if prev_use > 0 and cur_use::numeric / prev_use < 0.60 then
      signals := signals || '"expiry_declining_use"'::jsonb;
      if reason is null then
        reason := format(
          'Renews in %s days; %s class%s this period against %s last.',
          renews - today, cur_use, case when cur_use = 1 then '' else 'es' end, prev_use);
      end if;
    end if;
  end if;

  -- --- Band ----------------------------------------------------------------
  if jsonb_array_length(signals) = 0 then
    -- Absence of evidence is not evidence of health. Checked after the signals
    -- rather than before: if something did fire we know a fact about this
    -- member, and a fact beats "we cannot tell".
    if visits < 6 and today - v_window_start > 35 then
      band := 'insufficient_history';
      reason := format('Only %s visit%s on record since joining %s days ago — not enough to read a pattern.',
                       visits, case when visits = 1 then '' else 's' end, today - m.joined_on);
    else
      band := 'healthy';
      reason := null;
    end if;
  elsif severe or jsonb_array_length(signals) >= 2 then
    band := 'at_risk';
  else
    band := 'drifting';
  end if;

  return jsonb_build_object('band', band, 'reason', reason, 'signals', signals);
end $function$;

revoke execute on function member_health(uuid) from public, anon;
grant  execute on function member_health(uuid) to authenticated, service_role;

-- --- convert_keep_sweep: skip a studio that has not opened yet ---------------
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

  -- Decision 14(c): a studio that has not opened yet (no attended/checked-in
  -- class, or its first is still ahead) gets no convert/keep/retention action —
  -- nobody can have drifted before a class has run. The health refresh above
  -- still runs; member_health now returns insufficient_history for its members.
  if studio_opened_on(p_studio_id) is null
     or studio_opened_on(p_studio_id) > v_now_date then
    return jsonb_build_object('queued', 0, 'skipped', 'not_opened');
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
