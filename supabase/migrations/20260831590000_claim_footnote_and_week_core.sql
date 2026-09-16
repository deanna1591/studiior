-- 154: the claim calendar's two extras — per-class week-core, and the guarantee
-- footnote read live from the studio's own settings.
--
-- (1) instructor_claimable's classes gain `week_core`: the core classes the
--     instructor already holds or is claiming in THAT CLASS'S studio week. The
--     confirm popup needs "you are at 2 of 3 core that week" for the class's own
--     week, not the current one, and whether committing would go over the cap.
--     instructor_claim_horizon inherits it (it calls this function).
--
-- (2) claim_guarantee_terms(): the footnote in the confirm popup is GENERATED
--     from studio_settings and the instructor's rate version, never fixed copy —
--     the core cutoff, the holding fee (flat cents or a percentage of the
--     instructor's base, resolved here), and the flex deadline (mode + time or
--     hours). Guarantees off -> null, and the popup shows no footnote at all.
--     Same pattern as Decision 24's plan-card policy line.

-- ---- (1) instructor_claimable + week_core -----------------------------------
create or replace function instructor_claimable(p_instructor_id uuid, p_month date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_studio uuid; v_tz text; v_from timestamptz; v_to timestamptz; v_list jsonb;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  if not (is_manager_up(v_studio) or is_this_instructor(p_instructor_id) or is_service_context()) then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = v_studio;

  if not instructor_can_claim_month(p_instructor_id, p_month) then
    return jsonb_build_object('can_claim', false, 'reason', 'no_availability',
      'month', to_char(p_month, 'YYYY-MM'),
      'standing', instructor_week_claim_load(p_instructor_id, now()));
  end if;

  v_from := greatest(now(), (date_trunc('month', p_month))::date::timestamp at time zone v_tz);
  v_to   := (date_trunc('month', p_month) + interval '1 month')::date::timestamp at time zone v_tz;

  select coalesce(jsonb_agg(x order by x.starts_at), '[]'::jsonb) into v_list
  from (
    select
      o.id, o.starts_at,
      to_char(o.starts_at at time zone v_tz, 'YYYY-MM-DD') as date,
      to_char(o.starts_at at time zone v_tz, 'HH24:MI')    as time,
      ct.name as class_name, ct.duration_minutes, r.name as room,
      greatest(o.capacity - o.booked_count, 0) as spaces_left, o.capacity,
      occurrence_claim_tier(o.id) as tier,
      instructor_qualified(p_instructor_id, o.class_type_id) as qualified,
      instructor_available_at(p_instructor_id, o.starts_at, o.ends_at) as available,
      instructor_valid_on(p_instructor_id, (o.starts_at at time zone v_tz)::date) as valid,
      -- The class's OWN studio week: core held-or-claimed, for the confirm popup.
      (instructor_week_claim_load(p_instructor_id, o.starts_at) ->> 'core')::int as week_core,
      exists (select 1 from shift_applications sa
               where sa.occurrence_id = o.id and sa.instructor_id = p_instructor_id
                 and sa.status in ('pending','approved')) as mine,
      exists (
        select 1 from class_occurrences h
         where h.id <> o.id and h.status = 'scheduled'
           and tstzrange(h.starts_at, h.ends_at) && tstzrange(o.starts_at, o.ends_at)
           and (h.instructor_id = p_instructor_id
                or exists (select 1 from shift_applications sa2
                            where sa2.occurrence_id = h.id and sa2.instructor_id = p_instructor_id
                              and sa2.status = 'pending'))
      ) as clashes
    from class_occurrences o
    join class_types ct on ct.id = o.class_type_id
    left join rooms r on r.id = o.room_id
    where o.studio_id = v_studio and o.status = 'scheduled' and o.staffing = 'open'
      and o.starts_at >= v_from and o.starts_at < v_to
      and month_published(v_studio, o.starts_at)
      and instructor_valid_on(p_instructor_id, (o.starts_at at time zone v_tz)::date)
  ) x;

  return jsonb_build_object(
    'can_claim', true,
    'month', to_char(p_month, 'YYYY-MM'),
    'standing', instructor_week_claim_load(p_instructor_id, now()),
    'core_cap', instructor_core_cap(p_instructor_id),
    'classes', v_list);
end $$;
revoke execute on function instructor_claimable(uuid, date) from public, anon;
grant execute on function instructor_claimable(uuid, date) to authenticated, service_role;

-- ---- (2) claim_guarantee_terms — the footnote's facts -----------------------
create or replace function claim_guarantee_terms(p_instructor_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
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
  select base_rate_cents into v_base from instructor_rate_at(p_instructor_id, current_date);
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
end $$;
revoke execute on function claim_guarantee_terms(uuid) from public, anon;
grant execute on function claim_guarantee_terms(uuid) to authenticated, service_role;

do $$
begin
  if has_function_privilege('anon', 'claim_guarantee_terms(uuid)', 'execute')
     or has_function_privilege('anon', 'instructor_claimable(uuid, date)', 'execute') then
    raise exception 'migration 154: a claim reader is anon-callable';
  end if;
end $$;
