-- Decision 78b — precedence. While a studio runs the keep sequence, the two
-- standard expiry reminders step aside for it (the sequence supersedes them);
-- while it is off, both behave exactly as before. One added guard each, from the
-- newest definitions.
--
-- re-issues: sweep_membership_expiring(), queue_credit_expiries(uuid)

-- sweep_membership_expiring (from 20260832340000): skip a membership whose studio
-- has the keep sequence on.
create or replace function sweep_membership_expiring()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  if not is_service_context() then
    raise exception 'this is a scheduled job, not a user action' using errcode = 'PT403';
  end if;

  for r in
    select ms.id, ms.studio_id, ms.member_id, s.name as studio_name,
           pl.name as plan_name, s.timezone as tz,
           (ms.current_period_end at time zone s.timezone)::date as end_date
      from memberships ms
      join membership_plans pl on pl.id = ms.plan_id
      join studios s on s.id = ms.studio_id
     where pl.type = 'recurring'
       and ms.status = 'active'
       and ms.auto_renew = false
       and ms.stripe_subscription_id is null
       and ms.current_period_end is not null
       -- Decision 78b: the keep sequence replaces this reminder for its studio.
       and not coalesce((select ss.keep_sequence_enabled from studio_settings ss
                          where ss.studio_id = ms.studio_id), false)
       and (ms.current_period_end at time zone s.timezone)::date
             between (now() at time zone s.timezone)::date
                 and (now() at time zone s.timezone)::date + 7
  loop
    perform queue_notification(
      r.studio_id, r.member_id, 'membership_expiring',
      jsonb_build_object(
        'plan_name', r.plan_name,
        'ends_on', to_char(r.end_date, 'FMDD Mon YYYY'),
        'renew_url', member_portal_url(r.studio_id, '/account/plan')),
      'membership_expiring:' || r.id::text || ':' || r.end_date::text);
    n := n + 1;
  end loop;

  return jsonb_build_object('queued', n);
end $$;
revoke execute on function sweep_membership_expiring() from public, anon, authenticated;
grant  execute on function sweep_membership_expiring() to service_role;

-- queue_credit_expiries (from 20260830400000): return 0 (and send nothing) for a
-- studio running the keep sequence. ACL preserved by create-or-replace.
create or replace function queue_credit_expiries(p_studio_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; v_tz text;
begin
  if not is_manager_up(p_studio_id) and not is_platform_admin()
     and not is_service_context() then
    raise exception 'not permitted' using errcode = 'PT403';
  end if;
  -- Decision 78b: the keep sequence replaces credit-expiry mail for its studio.
  if coalesce((select keep_sequence_enabled from studio_settings
                where studio_id = p_studio_id), false) then
    return 0;
  end if;
  select timezone into v_tz from studios where id = p_studio_id;

  for r in
    select ms.member_id, ms.id, ms.credits_remaining, ms.expires_on
      from memberships ms
     where ms.studio_id = p_studio_id
       and ms.status = 'active'
       and ms.credits_remaining > 0
       and ms.expires_on = ((now() at time zone v_tz)::date + 7)
  loop
    if queue_notification(p_studio_id, r.member_id, 'credit_expiry',
          jsonb_build_object('credits', r.credits_remaining,
                             'expires_on', to_char(r.expires_on, 'FMDD FMMonth')),
          'credit_expiry:' || r.id || ':' || r.expires_on) is not null
    then n := n + 1; end if;
  end loop;
  return n;
end $$;
