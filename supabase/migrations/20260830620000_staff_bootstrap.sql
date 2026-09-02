-- =============================================================================
-- Migration 052: the same trip-collapsing for the staff app
-- =============================================================================
-- Measured first, as with migration 051. One staff page render made 11 requests
-- to Supabase, 5 of them sequential — 1.25 s of pure latency at 250 ms RTT
-- before anything drew.
--
-- Two of those were getUser(), called once by getStaffAccess() and again by
-- getStaffContext() immediately afterwards; both become zero round trips, for
-- the same reason and with the same verification as the member side.
--
-- Three more were the staff row, then studio_settings and locations (which
-- could not start until the staff row named the studio), then the platform-admin
-- and billing checks. They are one call now.
--
-- SECURITY DEFINER keyed on auth.uid(): it can only ever describe the caller.
-- =============================================================================

create or replace function staff_bootstrap()
returns table (
  staff_id            uuid,
  user_id             uuid,
  email               text,
  role                staff_role,
  studio_id           uuid,
  studio_name         text,
  studio_timezone     text,
  studio_currency     char(3),
  studio_status       text,
  location_name       text,
  onboarding_complete boolean,
  is_platform_admin   boolean,
  billing_status      platform_status,
  billing_locked      boolean,
  billing_days_left   int
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
      coalesce(ps.grace_ends_at, ps.trial_ends_at) - now())::int)
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
  'The staff context, their studio, its primary location, onboarding state, '
  'platform-admin flag and billing state in one request. Replaced five that ran '
  'in sequence. Returns no rows for a caller who is staff of no studio, which '
  'is a real state — a platform admin is exactly that.';
