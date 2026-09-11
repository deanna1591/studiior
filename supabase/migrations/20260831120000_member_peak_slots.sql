-- =============================================================================
-- 107 — what the member app asks about peak, in one question.
--
-- The screen needs three facts per class — is it peak, how many peak classes
-- are left in THAT CLASS'S period, and when that period ends — and it must not
-- work any of them out for itself. Peak-ness is a half-open comparison against
-- a table of wall times; a period is a fixed week from `week_starts_on`. Both
-- are already decided in SQL, and a TypeScript copy of either would agree until
-- the first studio whose week starts on Sunday.
--
-- One round trip, over the range the page is already fetching.
-- -----------------------------------------------------------------------------
-- THE MEMBERSHIP THIS RESOLVES IS A DISPLAY ANSWER, NOT THE AUTHORITY.
--
-- `book_class()` decides which plan pays by walking Decision 1's priority, and
-- it does that AFTER the eligibility gate with the occurrence in hand. This
-- function picks the member's live membership whose plan carries an allowance,
-- which is the same row in every case the CHECK in migration 104 permits — only
-- an unlimited recurring plan may carry one, and Decision 1 puts exactly that
-- kind first. If the two ever disagreed, the booking gate would win and the
-- screen would be the thing that was wrong, which is the right way round.
-- =============================================================================
create or replace function member_peak_slots(
  p_studio_id uuid, p_from timestamptz, p_to timestamptz)
returns table (
  occurrence_id uuid,
  is_peak       boolean,
  remaining     int,
  allowance     int,
  period_start  date,
  period_end    date)
language plpgsql stable security definer set search_path = public as $$
declare
  v_member uuid;
  v_ms     uuid;
  v_tz     text;
begin
  select m.id into v_member
    from members m
   where m.studio_id = p_studio_id and m.user_id = auth.uid();
  if v_member is null then
    raise exception 'you are not a member of that studio' using errcode = 'PT403';
  end if;

  -- The switch. No rows at all when the studio does not use peak hours, so the
  -- member app draws nothing rather than drawing "off-peak" against every class.
  if not coalesce((select ss.peak_allowance_enabled from studio_settings ss
                    where ss.studio_id = p_studio_id), false) then
    return;
  end if;

  select ms.id into v_ms
    from memberships ms
    join membership_plans mp on mp.id = ms.plan_id
   where ms.member_id = v_member
     and ms.studio_id = p_studio_id
     and ms.status in ('active', 'trialing', 'past_due')
     and mp.peak_allowance is not null
   order by ms.created_at desc
   limit 1;

  -- On no plan that has an allowance: peak is still worth SHOWING, because a
  -- studio that marks its busy hours is telling members something true about
  -- the timetable, but there is no number to put beside it.
  select s.timezone into v_tz from studios s where s.id = p_studio_id;

  return query
  select o.id,
         occurrence_is_peak(o.id),
         case when v_ms is null then null
              else (peak_allowance_state(v_ms, (o.starts_at at time zone v_tz)::date)
                    ->> 'remaining')::int end,
         case when v_ms is null then null
              else (peak_allowance_state(v_ms, (o.starts_at at time zone v_tz)::date)
                    ->> 'allowance')::int end,
         case when v_ms is null then null
              else (peak_allowance_state(v_ms, (o.starts_at at time zone v_tz)::date)
                    ->> 'period_start')::date end,
         case when v_ms is null then null
              else (peak_allowance_state(v_ms, (o.starts_at at time zone v_tz)::date)
                    ->> 'period_end')::date end
    from class_occurrences o
   where o.studio_id = p_studio_id
     and o.status = 'scheduled'
     and o.starts_at >= p_from
     and o.starts_at <  p_to;
end $$;

revoke execute on function member_peak_slots(uuid, timestamptz, timestamptz)
  from public, anon;
grant  execute on function member_peak_slots(uuid, timestamptz, timestamptz)
  to authenticated, service_role;

do $$
begin
  if has_function_privilege('anon',
       'member_peak_slots(uuid,timestamptz,timestamptz)'::regprocedure, 'execute') then
    raise exception 'migration 107: member_peak_slots is reachable by anon';
  end if;
end $$;
