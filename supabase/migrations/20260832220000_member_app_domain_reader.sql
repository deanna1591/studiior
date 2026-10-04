-- Decision 57 follow-up — a staff-readable member_app_domain(), so the staff
-- website buy link uses the SAME source the SQL email-link helpers use
-- (notification_config 'member_app_domain', e.g. 'studiior.app') rather than a
-- Vercel env var that is unset on the staff deployment (app.studiior.com) and
-- falls back to localhost:3000.
--
-- creates: member_app_domain()
-- re-issues: (none)
--
-- There was NO manager-readable path: notification_config has only a
-- platform-admin RLS policy, and notification_setting(text) is service-role
-- only. This SECURITY DEFINER reader returns the GLOBAL member-app domain — a
-- public, non-tenant constant (the host every member app is already served on,
-- which the live member URL plainly reveals), so it carries NO tenant guard:
-- it is granted to authenticated/service_role and returns the same value to
-- any signed-in staff session. It is not anon (anon stays exactly thirteen).

create or replace function member_app_domain() returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    nullif((select value from notification_config where key = 'member_app_domain'), ''),
    'studiior.app'
  )
$$;

revoke execute on function member_app_domain() from public, anon;
grant  execute on function member_app_domain() to authenticated, service_role;
