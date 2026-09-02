-- =============================================================================
-- Migration 051: everything a member screen needs, in one round trip
-- =============================================================================
-- Measured before writing this: one member Home render made 14 requests to
-- Supabase, 7 of them strictly sequential. Serial depth is the whole cost —
-- at 250 ms from Manila to Frankfurt that is 1.75 s of pure latency before
-- anything renders, per navigation.
--
-- Two of those hops were getUser() (middleware and getMemberContext), which
-- become zero: this project signs ES256 on local AND hosted, so getClaims()
-- verifies the signature locally against a cached JWKS. Two more were
-- getMemberContext's member lookup and memberScreen's batch, which had to be
-- sequential because the batch needed the studio id the lookup returned.
--
-- This is those two, merged. One function, one request, and the caller can
-- start the page's own queries immediately afterwards.
--
-- SECURITY DEFINER and keyed on auth.uid(), the same shape as
-- studio_member_settings(): it can only ever return the context of the person
-- calling it, whatever slug they pass. The slug narrows WHICH of their
-- memberships is meant — one login can hold several — and never widens it.
-- =============================================================================

create or replace function member_bootstrap(p_slug text)
returns table (
  member_id           uuid,
  studio_id           uuid,
  first_name          text,
  last_name           text,
  preferred_name      text,
  avatar_path         text,
  status              member_status,
  current_streak      int,
  lifetime_visits     int,
  studio_name         text,
  studio_timezone     text,
  logo_url            text,
  theme_preset        theme_preset,
  accent_color        text,
  checkin_opens_minutes_before  int,
  checkin_closes_minutes_after  int,
  cancellation_cutoff_minutes   int,
  booking_cutoff_minutes        int,
  waitlist_enabled              boolean,
  billing_status      platform_status,
  billing_locked      boolean,
  open_offers         int
)
language sql stable security definer set search_path = public as $$
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
        and wo.expires_at > now())
  from members m
  join studios s on s.id = m.studio_id
  left join studio_settings st on st.studio_id = m.studio_id
  left join platform_subscriptions ps on ps.studio_id = m.studio_id
  -- auth.uid(), not a parameter. The caller cannot ask about anybody else.
  where m.user_id = auth.uid()
    and s.slug = p_slug
  limit 1
$$;

revoke execute on function member_bootstrap(text) from public, anon;
grant execute on function member_bootstrap(text) to authenticated;

comment on function member_bootstrap(text) is
  'One round trip for the member context, the studio, its member-facing '
  'settings, its billing state and any live waitlist offer. Replaces four '
  'sequential requests. Keyed on auth.uid(): the slug picks which of the '
  'caller''s memberships is meant and can never reach somebody else''s.';
