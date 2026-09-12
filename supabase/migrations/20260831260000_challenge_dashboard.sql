-- Challenges, part 5: the dashboard's Challenge Participation KPI comes back,
-- and its "arrives with challenges" placeholder goes.
--
-- The card is a SEPARATE function the dashboard page appends, rather than a new
-- branch inside dashboard_kpis — one card is not worth re-issuing that whole
-- function, and this keeps the gating in one obvious place: it returns null when
-- the studio has never published a challenge, so a studio that does not use the
-- feature shows nothing, not an empty card.

-- Drop the placeholder. challenge_participation is no longer "coming"; it either
-- shows as a real KPI (below) or is absent entirely. revenue_forecast stays.
create or replace function dashboard_absent_cards(p_studio_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_have int; v_need int; v_tz text; v_today date;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'the dashboard is for owners and managers' using errcode = 'PT403';
  end if;
  select s.timezone into v_tz from studios s where s.id = p_studio_id;
  v_today := studio_today(p_studio_id);
  v_need := dashboard_forecast_min_months();
  select count(*) into v_have from (
    select 1 from payments p
     where p.studio_id = p_studio_id and p.status in ('succeeded','partially_refunded')
       and coalesce(p.paid_at, p.created_at)
           < (date_trunc('month', v_today)::date::timestamp at time zone v_tz)
     group by date_trunc('month', (coalesce(p.paid_at, p.created_at) at time zone v_tz))) x;

  return (
    select coalesce(jsonb_agg(c), '[]'::jsonb) from (
      select jsonb_build_object(
        'key','revenue_forecast',
        'label','Monthly revenue forecast',
        'why','A projection needs ' || v_need || ' complete months of takings to '
              || 'sit on. You have ' || v_have || '. Anything sooner is a made-up '
              || 'number with a currency symbol on it.') as c
       where v_have < v_need
    ) t(c));
end $$;

-- The KPI. Null unless the studio has published at least one challenge — that
-- absence is what keeps the feature invisible to a studio that never created
-- one. When present it counts across the CURRENTLY ACTIVE challenges (or, if
-- none are active, the most recent published one), because "participation" is a
-- now number, not a lifetime tally.
create function dashboard_challenge_kpi(p_studio_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_active int; v_joined int; v_completed int; v_scope text;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'the dashboard is for owners and managers' using errcode = 'PT403';
  end if;

  -- Never published one → no card, no trace.
  if not exists (select 1 from challenges
                  where studio_id = p_studio_id and audience = 'member'
                    and status in ('scheduled','active','ended')) then
    return null;
  end if;

  select count(*) into v_active from challenges
   where studio_id = p_studio_id and audience = 'member' and status = 'active';

  if v_active > 0 then
    v_scope := 'active';
    select count(*), count(*) filter (where p.completed_at is not null)
      into v_joined, v_completed
      from challenge_participants p
      join challenges c on c.id = p.challenge_id
     where c.studio_id = p_studio_id and c.audience = 'member' and c.status = 'active';
  else
    v_scope := 'recent';
    select count(*), count(*) filter (where p.completed_at is not null)
      into v_joined, v_completed
      from challenge_participants p
     where p.challenge_id = (
       select id from challenges
        where studio_id = p_studio_id and audience = 'member'
          and status in ('scheduled','ended')
        order by ends_on desc limit 1);
  end if;

  return jsonb_build_object(
    'key', 'challenge_participation',
    'label', 'Challenge participation',
    'state', case when coalesce(v_joined,0) = 0 then 'empty' else 'ok' end,
    'kind', 'count',
    'value', coalesce(v_joined, 0),
    'sub', coalesce(v_completed,0) || ' completed'
           || case when v_active > 0 then ' · ' || v_active || ' running' else '' end,
    'href', '/challenges',
    'empty_hint', 'Nobody has joined yet. It fills as members opt in.');
end $$;

revoke execute on function dashboard_challenge_kpi(uuid) from public, anon;
grant  execute on function dashboard_challenge_kpi(uuid) to authenticated, service_role;
