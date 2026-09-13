-- Latency: fold two studio flags into member_bootstrap so no member screen makes
-- a separate studio_member_settings round trip for them. guest_passes_enabled and
-- has_payment_provider ("connected provider", stripe_account_id is not null, named
-- generically per Decision 16) are flags every screen pays for once with the
-- member — the class detail sheet, /account/pay and /account/plan each fetched
-- them on their own. A RETURNS TABLE cannot gain a column via create-or-replace,
-- so it drops and re-grants.
drop function if exists member_bootstrap(text);
create function member_bootstrap(p_slug text)
returns table(member_id uuid, studio_id uuid, first_name text, last_name text,
  preferred_name text, avatar_path text, status member_status, current_streak integer,
  lifetime_visits integer, studio_name text, studio_timezone text, logo_url text,
  theme_preset theme_preset, accent_color text, checkin_opens_minutes_before integer,
  checkin_closes_minutes_after integer, cancellation_cutoff_minutes integer,
  booking_cutoff_minutes integer, waitlist_enabled boolean, billing_status platform_status,
  billing_locked boolean, open_offers integer,
  guest_passes_enabled boolean, has_payment_provider boolean)
language sql stable security definer set search_path = public as $function$
  select
    m.id, m.studio_id, m.first_name, m.last_name, m.preferred_name, m.avatar_url,
    m.status, coalesce(m.current_streak, 0), coalesce(m.lifetime_visits, 0),
    s.name, s.timezone, s.logo_url, s.theme_preset, s.accent_color,
    coalesce(st.checkin_opens_minutes_before, 60),
    coalesce(st.checkin_closes_minutes_after, 30),
    coalesce(st.cancellation_cutoff_minutes, 720),
    coalesce(st.booking_cutoff_minutes, 0),
    coalesce(st.waitlist_enabled, true),
    ps.status,
    coalesce(ps.status = 'locked', false),
    (select count(*)::int from waitlist_offers wo
       join bookings b on b.id = wo.booking_id
      where b.member_id = m.id
        and wo.responded_at is null
        and wo.expires_at > now()),
    coalesce(st.guest_passes_enabled, false),
    (s.stripe_account_id is not null)
  from members m
  join studios s on s.id = m.studio_id
  left join studio_settings st on st.studio_id = m.studio_id
  left join platform_subscriptions ps on ps.studio_id = m.studio_id
  where m.user_id = auth.uid()
    and s.slug = p_slug
  limit 1
$function$;
revoke execute on function member_bootstrap(text) from public, anon;
grant  execute on function member_bootstrap(text) to authenticated, service_role;
