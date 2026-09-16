-- 153: instructors claim across the HORIZON, members book the window.
--
-- Claiming needs no publication reveal: month_published() is true when
-- publication is off, so every open, future class is already claimable (149's
-- gates all route through it). What the portal wants is the RIGHT WINDOW —
-- instructors plan further ahead than members book. Members are held to
-- booking_window_days (book_class, rule 2.1); instructors see the full
-- occurrence horizon, which is exactly "as far ahead as the timetable exists"
-- and is the studio's own occurrence_horizon_days (read, not hardcoded — a
-- studio wanting 90 days ahead sets its horizon to 90).
--
-- instructor_claim_horizon() walks the months the horizon spans and returns a
-- block per month. The per-month availability gate (instructor_can_claim_month)
-- is kept EXACTLY as instructor_claimable enforces it — claiming into January
-- needs January availability, the same relationship the validity window already
-- enforces, applied per month. A month with no availability is returned as
-- {can_claim:false, reason:'no_availability'} with an empty class list, so the
-- portal can say "send us your January availability and these open up" rather
-- than showing a blank month.

create or replace function instructor_claim_horizon(p_instructor_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_studio uuid; v_today date; v_horizon int; v_end date;
  v_m date; v_months jsonb := '[]'::jsonb; v_block jsonb;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  if not (is_manager_up(v_studio) or is_this_instructor(p_instructor_id) or is_service_context()) then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;

  v_today := studio_today(v_studio);
  select coalesce(occurrence_horizon_days, 60) into v_horizon
    from studio_settings where studio_id = v_studio;
  v_horizon := coalesce(v_horizon, 60);
  v_end := v_today + v_horizon;

  -- One block per studio-local month the horizon touches, from this month to the
  -- month the horizon ends in. instructor_claimable does the per-month work
  -- (open + published + valid + future classes, or the no_availability reason),
  -- so the horizon and the single-month portal cannot disagree.
  v_m := date_trunc('month', v_today)::date;
  while v_m <= date_trunc('month', v_end)::date loop
    v_block := instructor_claimable(p_instructor_id, v_m);
    v_months := v_months || jsonb_build_object(
      'month', to_char(v_m, 'YYYY-MM'),
      'can_claim', coalesce((v_block ->> 'can_claim')::boolean, false),
      'reason', v_block ->> 'reason',
      'classes', coalesce(v_block -> 'classes', '[]'::jsonb));
    v_m := (v_m + interval '1 month')::date;
  end loop;

  return jsonb_build_object(
    'horizon_days', v_horizon,
    'core_cap', instructor_core_cap(p_instructor_id),
    'standing', instructor_week_claim_load(p_instructor_id, now()),
    'months', v_months);
end $$;
revoke execute on function instructor_claim_horizon(uuid) from public, anon;
grant execute on function instructor_claim_horizon(uuid) to authenticated, service_role;

do $$
begin
  if has_function_privilege('anon', 'instructor_claim_horizon(uuid)', 'execute') then
    raise exception 'migration 153: instructor_claim_horizon is anon-callable';
  end if;
end $$;
