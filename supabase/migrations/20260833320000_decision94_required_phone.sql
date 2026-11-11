-- =============================================================================
-- Decision 94 — members must give a phone number (11 Nov 2026)
-- =============================================================================
-- member_bootstrap carries two new columns so the member app can prompt for a
-- missing number and validate it per the studio's country:
--   has_phone boolean  = the member's phone column is non-empty
--   country   text     = studios.country (char(2)), so the PH-vs-other rule is
--                        decided server-side and the sheet never hardcodes it
--
-- Re-issued from its newest definition (20260833180000) with ONLY these two
-- columns appended to the RETURNS TABLE and the select. A RETURNS TABLE column
-- change is a DROP+recreate, which discards the ACL, so it is re-asserted
-- authenticated-only (NOT anon). No new function signature, no new anon RPC.
--
-- No new anon surface — anon stays EXACTLY THIRTEEN (asserted at apply).
--
-- re-issues: member_bootstrap(text)
-- =============================================================================

drop function if exists member_bootstrap(text);
create function public.member_bootstrap(p_slug text)
 returns table(member_id uuid, studio_id uuid, first_name text, last_name text, preferred_name text, avatar_path text, status member_status, current_streak integer, lifetime_visits integer, studio_name text, studio_timezone text, logo_url text, theme_preset theme_preset, accent_color text, checkin_opens_minutes_before integer, checkin_closes_minutes_after integer, cancellation_cutoff_minutes integer, booking_cutoff_minutes integer, waitlist_enabled boolean, billing_status platform_status, billing_locked boolean, open_offers integer, guest_passes_enabled boolean, has_payment_provider boolean, booking_window_days integer, how_to_buy text, studio_contact_email text, xendit_enabled boolean, time_format text, trial_used boolean, messages_enabled boolean, has_unread_studio_message boolean, desk_pay_available boolean, payee_notice_name text, has_phone boolean, country text)
 language sql
 stable security definer
 set search_path to 'public'
as $function$
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
    (s.stripe_account_id is not null),
    member_booking_window_days(m.id),
    st.how_to_buy,
    s.contact_email,
    exists (select 1 from studio_payment_providers spp
             where spp.studio_id = m.studio_id and spp.provider = 'xendit'),
    coalesce(st.time_format, '24h'),
    exists (select 1 from memberships ms
              join membership_plans mp on mp.id = ms.plan_id
             where ms.member_id = m.id and mp.type = 'trial'),
    coalesce(st.messages_enabled, false),
    coalesce(st.messages_enabled, false) and exists (
      select 1 from message_threads mt
        join thread_messages msg on msg.thread_id = mt.id
       where mt.member_id = m.id and msg.sender_kind = 'staff'
         and msg.created_at > coalesce(mt.last_member_read_at, 'epoch'::timestamptz)),
    not (
      (coalesce(st.desk_pay_mode, 'earned') = 'earned' and m.desk_pay_blocked_at is not null)
      or (coalesce(st.desk_pay_mode, 'earned') = 'first_visit_only'
          and exists (select 1 from bookings bdp
                       where bdp.member_id = m.id and bdp.studio_id = m.studio_id
                         and bdp.payment_source = 'drop_in' and bdp.status <> 'cancelled'))
    ),
    st.payee_notice_name,
    (nullif(btrim(coalesce(m.phone, '')), '') is not null),
    s.country
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

-- --- Anon stays EXACTLY THIRTEEN --------------------------------------------
do $$
declare n int;
begin
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then
    raise exception 'anon surface is % (want 13)', n;
  end if;
end $$;
