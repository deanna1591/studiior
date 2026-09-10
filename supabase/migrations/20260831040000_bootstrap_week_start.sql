-- =============================================================================
-- Migration 094 — staff_bootstrap() carries the studio's week start
--
-- WHICH DAY A WEEK STARTS ON IS THE STUDIO'S, AND BOTH SIDES OF THE CALENDAR
-- HAVE TO AGREE ABOUT IT. `/schedule` computed a Monday-based week on the
-- server while react-big-calendar rendered a Sunday-based one on the client —
-- its localizer is handed date-fns' bare startOfWeek, which defaults to Sunday
-- when no locale reaches it. With an anchor on a Sunday the server fetched the
-- Monday week BEHIND it while the grid drew the Sunday week starting at it:
-- two days of overlap, five empty columns, and a refresh could not help
-- because nothing was stale — it was simply the wrong week.
--
-- `week_starts_on` has been a column since migration 001 and neither side was
-- reading it. It belongs here beside studio_timezone, which is the same kind
-- of fact: something every screen needs before it can ask its first question.
-- Fetching it separately would put a serial round trip in front of the
-- schedule's range — the hop that studio_today() was removed for.
--
-- Rebuilt from migration 052's FILE, not from the live database: a copy taken
-- with pg_get_functiondef from a database this session has been iterating
-- against has twice contained an earlier draft of the migration being written.
--
-- A RETURNS TABLE cannot gain a column through `create or replace`, so this
-- drops first — and a DROP DISCARDS THE ACL, so the function is reborn with
-- the hosted default grant for anon and authenticated. The revoke below is not
-- tidiness; without it this reopens what migration 011 closed. Asserted at the
-- bottom, in the migration itself, the way migration 034 does.
-- =============================================================================

drop function if exists staff_bootstrap();

create function staff_bootstrap()
returns table (
  staff_id             uuid,
  user_id              uuid,
  email                text,
  role                 staff_role,
  studio_id            uuid,
  studio_name          text,
  studio_timezone      text,
  studio_currency      char(3),
  studio_status        text,
  location_name        text,
  onboarding_complete  boolean,
  is_platform_admin    boolean,
  billing_status       platform_status,
  billing_locked       boolean,
  billing_days_left    int,
  -- 0 = Sunday .. 6 = Saturday, matching JavaScript's getDay() and date-fns'
  -- weekStartsOn, so it travels to the browser without a translation step.
  studio_week_starts_on int
)
language sql stable security definer set search_path = public as $$
  select
    ss.id, ss.user_id, ss.email, ss.role, ss.studio_id,
    s.name, s.timezone, s.currency, s.status,
    (select l.name from locations l
      where l.studio_id = ss.studio_id and l.is_primary
      order by l.created_at limit 1),
    st.onboarding_completed_at is not null,
    is_platform_admin(),
    ps.status,
    coalesce(ps.status = 'locked', false),
    greatest(0, extract(day from
      coalesce(ps.grace_ends_at, ps.trial_ends_at) - now())::int),
    -- Default 1 rather than 0: a studio with no settings row at all is a
    -- Monday studio, which is what the column's own default has always said.
    coalesce(st.week_starts_on, 1)
  from studio_staff ss
  join studios s on s.id = ss.studio_id
  left join studio_settings st on st.studio_id = ss.studio_id
  left join platform_subscriptions ps on ps.studio_id = ss.studio_id
  -- auth.uid(), never a parameter.
  where ss.user_id = auth.uid()
    and ss.status = 'active'
  order by ss.created_at
  limit 1
$$;

revoke execute on function staff_bootstrap() from public, anon;
grant execute on function staff_bootstrap() to authenticated;

comment on function staff_bootstrap() is
  'The staff context in one request: who is asking, their studio, its primary '
  'location, onboarding state, the platform-admin flag, billing, and which day '
  'its week starts on. Migration 094 added the last of those so the calendar '
  'and the query behind it cannot disagree about which seven days a week is.';

-- The drop reopened the default grant; prove the revoke closed it again rather
-- than trusting that it did. Local and hosted have different default ACLs, so
-- this assertion is the only thing that holds on both.
do $$
begin
  if has_function_privilege('anon', 'staff_bootstrap()', 'execute') then
    raise exception 'staff_bootstrap() is anon-callable after being recreated';
  end if;
  if not has_function_privilege('authenticated', 'staff_bootstrap()', 'execute') then
    raise exception 'staff_bootstrap() is not reachable by a signed-in user';
  end if;
end $$;
