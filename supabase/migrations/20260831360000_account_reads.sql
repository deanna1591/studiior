-- The member Account rebuild's reads. Two small things the member app needs:
-- whether the studio has a CONNECTED PAYMENT PROVIDER (so the wallet appears or
-- not, detected never toggled), and a member's milestone standing.

-- ---------------------------------------------------------------------------
-- studio_member_settings gains has_payment_provider. "Connected provider" is a
-- generic concept — Decision 16 made the provider an adapter over the manual
-- foundation, and stripe_account_id is Stripe, its FIRST adapter. Naming it
-- generically means PayMongo or Xendit (which can serve the Philippines, where
-- Stripe cannot) slot in here later with no UI change. A RETURNS TABLE cannot
-- gain a column through create-or-replace, so it drops and re-grants.
-- ---------------------------------------------------------------------------
drop function if exists studio_member_settings(uuid);
create function studio_member_settings(p_studio_id uuid)
returns table(checkin_opens_minutes_before integer, checkin_closes_minutes_after integer,
              cancellation_cutoff_minutes integer, booking_cutoff_minutes integer,
              waitlist_enabled boolean, week_starts_on integer, guest_passes_enabled boolean,
              has_payment_provider boolean)
language sql stable security definer set search_path = public as $$
  select ss.checkin_opens_minutes_before, ss.checkin_closes_minutes_after,
         ss.cancellation_cutoff_minutes, ss.booking_cutoff_minutes,
         ss.waitlist_enabled, ss.week_starts_on, ss.guest_passes_enabled,
         (select st.stripe_account_id is not null from studios st where st.id = ss.studio_id)
    from studio_settings ss
   where ss.studio_id = p_studio_id
     and (p_studio_id in (select auth_member_studios())
          or p_studio_id in (select auth_staff_studios()))
$$;
revoke execute on function studio_member_settings(uuid) from public, anon;
grant  execute on function studio_member_settings(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- member_milestones — the recognition standing, LEADING with the next target.
-- Decision 10: personal, no ranking, no comparison. Targets are the fixed ladder
-- from milestone_visit_targets(); total is the member's lifetime visits (the
-- same figure the rest of the app shows). Returns the next target and how far,
-- and the ladder with each rung marked earned — the screen leads with the next
-- and lists the earned quietly below.
-- ---------------------------------------------------------------------------
create function member_milestones(p_studio_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_member uuid; v_total int; v_targets int[]; v_next int; v_to_go int;
begin
  select m.id, m.lifetime_visits into v_member, v_total
    from members m where m.studio_id = p_studio_id and m.user_id = auth.uid();
  if v_member is null then
    raise exception 'you are not a member of that studio' using errcode = 'PT403';
  end if;

  v_targets := milestone_visit_targets();
  select min(t) into v_next from unnest(v_targets) t where t > v_total;
  v_to_go := case when v_next is null then null else v_next - v_total end;

  return jsonb_build_object(
    'total', v_total,
    'next_target', v_next,           -- null once every rung is passed
    'to_go', v_to_go,
    'ladder', (
      select coalesce(jsonb_agg(jsonb_build_object('target', t, 'earned', v_total >= t) order by t), '[]'::jsonb)
        from unnest(v_targets) t));
end $$;
revoke execute on function member_milestones(uuid) from public, anon;
grant  execute on function member_milestones(uuid) to authenticated, service_role;
