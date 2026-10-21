-- Decision 79a — the retention board carries the last contact (method, when) and
-- its outcome, hides snoozed members (an open task due in the future), and gains
-- a counts reader for the section headers.
--
-- re-issues: retention_board(uuid)
-- creates:   retention_outcomes(uuid)

drop function if exists retention_board(uuid);
CREATE FUNCTION public.retention_board(p_studio_id uuid)
 RETURNS TABLE(section text, member_id uuid, member_name text, phone text, class_at timestamp with time zone, days_since integer, instructor_name text, offer_ends timestamp with time zone, window_active boolean, plan_name text, expires_on date, task_id uuid, task_status text, suggested_message text, reason text, contacted_at timestamp with time zone, last_contact_at timestamp with time zone, last_contact_method text, outcome text, outcome_days integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_tz text; v_today date;
begin
  if not (coalesce(is_manager_up(p_studio_id), false)
          or (coalesce(is_desk_up(p_studio_id), false)
              and coalesce((select retention_tasks_to from studio_settings
                             where studio_id = p_studio_id), 'owner_manager') = 'front_desk')
          or is_service_context()) then
    raise exception 'that is another studio''s retention board' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  v_today := (now() at time zone v_tz)::date;

  return query
  -- Unconverted free classes (78a).
  with free_members as (
    select distinct on (b.member_id)
           b.member_id, b.occurrence_id, o.starts_at, o.instructor_id
      from bookings b join class_occurrences o on o.id = b.occurrence_id
     where b.studio_id = p_studio_id and b.payment_source = 'comp'
       and not exists (select 1 from guest_passes gp
                        where gp.guest_booking_id = b.id and gp.host_member_id is not null)
     order by b.member_id, b.booked_at
  ),
  board (section, member_id, member_name, phone, class_at, days_since,
         instructor_name, offer_ends, window_active, plan_name, expires_on,
         task_id, task_status, suggested_message, reason, contacted_at) as (
  select 'unconverted'::text, m.id,
         coalesce(nullif(m.first_name, ''), m.email), m.phone,
         fm.starts_at, greatest(0, (v_today - fm.starts_at::date))::int,
         split_part(coalesce(i.display_name, ''), ' ', 1),
         (intro_window(m.id) ->> 'ends_at')::timestamptz,
         coalesce((intro_window(m.id) ->> 'active')::boolean, false),
         null::text, null::date,
         t.id, t.status, t.suggested_message,
         null::text, t.contacted_at
    from free_members fm
    join members m on m.id = fm.member_id and m.deleted_at is null
    left join instructors i on i.id = fm.instructor_id
    left join lateral (
      select mt.id, mt.status, mt.suggested_message, mt.contacted_at
        from member_tasks mt
       where mt.member_id = m.id and mt.kind = 'unconverted_day7' and mt.status <> 'dismissed'
       order by mt.created_at desc limit 1) t on true
   where not exists (select 1 from memberships ms where ms.member_id = m.id)

  union all
  -- Drifting (health band) — read-only; shows the last soft email sent.
  select 'drifting'::text, m.id,
         coalesce(nullif(m.first_name, ''), m.email), m.phone,
         null::timestamptz, 0, mi.name, null::timestamptz, null::boolean,
         null::text, null::date,
         null::uuid, null::text, null::text,
         m.health_reason,
         (select max(nx.created_at) from notifications nx
           where nx.member_id = m.id and nx.template_key = 'keep_drifting')
    from members m
    left join lateral (
      select split_part(i.display_name, ' ', 1) as name
        from check_ins ci
        join class_occurrences o3 on o3.id = ci.occurrence_id
        join instructors i on i.id = o3.instructor_id
       where ci.member_id = m.id
       group by i.display_name order by count(*) desc, i.display_name limit 1) mi on true
   where m.studio_id = p_studio_id and m.deleted_at is null and m.health_band = 'drifting'

  union all
  -- At risk (health band) — carries the open at_risk task, if any.
  select 'at_risk'::text, m.id,
         coalesce(nullif(m.first_name, ''), m.email), m.phone,
         null::timestamptz, 0, mi.name, null::timestamptz, null::boolean,
         null::text, null::date,
         t.id, t.status, t.suggested_message,
         m.health_reason, t.contacted_at
    from members m
    left join lateral (
      select split_part(i.display_name, ' ', 1) as name
        from check_ins ci
        join class_occurrences o3 on o3.id = ci.occurrence_id
        join instructors i on i.id = o3.instructor_id
       where ci.member_id = m.id
       group by i.display_name order by count(*) desc, i.display_name limit 1) mi on true
    left join lateral (
      select mt.id, mt.status, mt.suggested_message, mt.contacted_at
        from member_tasks mt
       where mt.member_id = m.id and mt.kind = 'at_risk' and mt.status <> 'dismissed'
       order by mt.created_at desc limit 1) t on true
   where m.studio_id = p_studio_id and m.deleted_at is null and m.health_band = 'at_risk'

  union all
  -- Expiring this week.
  select 'expiring'::text, m.id, coalesce(nullif(m.first_name, ''), m.email), m.phone,
         null::timestamptz, 0, null::text, null::timestamptz, null::boolean,
         pl.name, mend.d, null::uuid, null::text, null::text, null::text, null::timestamptz
    from memberships ms
    join membership_plans pl on pl.id = ms.plan_id
    join members m on m.id = ms.member_id and m.deleted_at is null
    cross join lateral (select coalesce(ms.expires_on, (ms.current_period_end at time zone v_tz)::date) as d) mend
   where ms.studio_id = p_studio_id
     and ms.status in ('active', 'past_due')
     and not (coalesce(ms.auto_renew, false) or ms.stripe_subscription_id is not null)
     and mend.d between v_today and v_today + 7
     and not exists (select 1 from memberships ms2
                      where ms2.member_id = ms.member_id and ms2.id <> ms.id and ms2.status = 'active'
                        and coalesce(ms2.expires_on, (ms2.current_period_end at time zone v_tz)::date, 'infinity'::date) > mend.d)

  union all
  -- Lapsed this month.
  select 'lapsed'::text, m.id, coalesce(nullif(m.first_name, ''), m.email), m.phone,
         null::timestamptz, greatest(0, v_today - mend.d)::int, null::text, null::timestamptz, null::boolean,
         pl.name, mend.d, null::uuid, null::text, null::text, null::text, null::timestamptz
    from memberships ms
    join membership_plans pl on pl.id = ms.plan_id
    join members m on m.id = ms.member_id and m.deleted_at is null
    cross join lateral (select coalesce(ms.expires_on, (ms.current_period_end at time zone v_tz)::date) as d) mend
   where ms.studio_id = p_studio_id
     and mend.d between v_today - 30 and v_today - 1
     and not exists (select 1 from memberships ms2
                      where ms2.member_id = ms.member_id and ms2.status = 'active'
                        and coalesce(ms2.expires_on, 'infinity'::date) > v_today)
     and not exists (select 1 from memberships ms3
                      where ms3.member_id = ms.member_id
                        and coalesce(ms3.starts_on, '-infinity'::date) > mend.d)
  )
  select b.section, b.member_id, b.member_name, b.phone, b.class_at, b.days_since,
         b.instructor_name, b.offer_ends, b.window_active, b.plan_name, b.expires_on,
         b.task_id, b.task_status, b.suggested_message, b.reason, b.contacted_at,
         lc.contacted_at, lc.method, lc.outcome, lc.outcome_days
    from board b
    left join lateral (select mc.contacted_at, mc.method, mc.outcome, mc.outcome_days
                         from member_contacts mc
                        where mc.member_id = b.member_id
                        order by mc.contacted_at desc limit 1) lc on true
   -- A snoozed member (an open task due in the future) drops off until due.
   where not exists (select 1 from member_tasks mt
                      where mt.member_id = b.member_id and mt.status = 'open'
                        and mt.due_at is not null and mt.due_at > now())
   order by b.section, b.days_since desc, b.member_name;
end $function$

;
revoke execute on function retention_board(uuid) from public, anon;
grant  execute on function retention_board(uuid) to authenticated, service_role;

-- retention_outcomes — the month's "contacted → came back" count for the section
-- headers. Manager-up (front desk when retention is routed to them).
create or replace function retention_outcomes(p_studio_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_tz text; v_month_start date; v_contacted int; v_back int;
begin
  if not (coalesce(is_manager_up(p_studio_id), false)
          or (coalesce(is_desk_up(p_studio_id), false)
              and coalesce((select retention_tasks_to from studio_settings
                             where studio_id = p_studio_id), 'owner_manager') = 'front_desk')
          or is_service_context()) then
    raise exception 'that is another studio''s retention outcomes' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  v_month_start := date_trunc('month', (now() at time zone v_tz))::date;
  select count(*)::int,
         count(*) filter (where outcome in ('booked','visited','bought','renewed'))::int
    into v_contacted, v_back
    from member_contacts
   where studio_id = p_studio_id
     and (contacted_at at time zone v_tz)::date >= v_month_start;
  return jsonb_build_object('contacted', coalesce(v_contacted, 0),
                            'came_back', coalesce(v_back, 0));
end $$;
revoke execute on function retention_outcomes(uuid) from public, anon;
grant  execute on function retention_outcomes(uuid) to authenticated, service_role;
