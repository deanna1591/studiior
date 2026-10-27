-- Decision 30 amendment (d) — a no-show on the free first class uses it.
-- re-issues: free_first_eligibility_run(uuid, uuid, uuid), free_first_eligibility(uuid, uuid, uuid)
--
-- Cancelling before the cut-off keeps the free class (unchanged — a cancelled
-- comp booking is never counted). A single NO-SHOW now uses it: the no-show
-- threshold drops 2 -> 1 and the reason is renamed 'missed_twice' -> 'missed'.
-- The studio and the instructor were paid the 1-pax rate for the seat whether
-- or not the member came. Both functions are byte-for-byte their newest bodies
-- (migration 20260832970000, the 81a split) with ONLY that one arm changed;
-- create-or-replace keeps the ACLs, re-asserted below. The missed-you convert
-- email's PLATFORM DEFAULT body (studio_id is null) stops offering a second
-- free class and offers the intro plan instead; a studio override is untouched.

-- ===========================================================================
-- 1. free_first_eligibility_run — the unguarded twin that carries the logic.
--    One no-show (v_noshow >= 1) => 'missed'. Everything else is verbatim.
-- ===========================================================================
create or replace function free_first_eligibility_run(
  p_studio_id uuid, p_member_id uuid, p_exclude_booking uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_member members%rowtype;
  v_has_hostnull  boolean;
  v_noshow        int;
  v_comp_attended int;
  v_comp_live     int;
  v_other_qual    int;
  v_has_membership boolean;
begin
  select * into v_member from members where id = p_member_id;
  if not found or v_member.studio_id <> p_studio_id then
    raise exception 'no such member here' using errcode = 'PT404';
  end if;

  if not coalesce((select free_first_class_enabled from studio_settings
                    where studio_id = p_studio_id), false) then
    return jsonb_build_object('ok', false, 'reason', 'not_enabled');
  end if;

  if exists (select 1 from members
              where studio_id = p_studio_id and id <> p_member_id
                and normalize_email_key(email) = normalize_email_key(v_member.email)) then
    return jsonb_build_object('ok', false, 'reason', 'already_member');
  end if;

  if exists (select 1 from guest_passes
              where studio_id = p_studio_id and host_member_id is not null
                and normalize_email_key(guest_email) = normalize_email_key(v_member.email)) then
    return jsonb_build_object('ok', false, 'reason', 'already_had_free');
  end if;

  v_has_hostnull := exists (select 1 from guest_passes
              where studio_id = p_studio_id and host_member_id is null
                and normalize_email_key(guest_email) = normalize_email_key(v_member.email));

  if v_has_hostnull then
    select
      count(*) filter (where b.payment_source = 'comp' and b.status = 'no_show'),
      count(*) filter (where b.payment_source = 'comp' and b.status = 'attended'),
      count(*) filter (where b.payment_source = 'comp' and b.status in ('booked','waitlisted','pending_payment')),
      count(*) filter (where b.payment_source <> 'comp' and b.status in ('booked','waitlisted','attended','no_show','pending_payment'))
      into v_noshow, v_comp_attended, v_comp_live, v_other_qual
      from bookings b
     where b.member_id = p_member_id and b.studio_id = p_studio_id
       and (p_exclude_booking is null or b.id <> p_exclude_booking);
    v_has_membership := exists (select 1 from memberships ms where ms.member_id = p_member_id);

    if v_comp_attended > 0 or v_has_membership or v_comp_live > 0 or v_other_qual > 0 then
      return jsonb_build_object('ok', false, 'reason', 'already_had_free');
    elsif v_noshow >= 1 then
      -- Decision 30 (d): one no-show uses the free class (was >= 2 / 'missed_twice').
      return jsonb_build_object('ok', false, 'reason', 'missed');
    else
      return jsonb_build_object('ok', true);
    end if;
  end if;

  if exists (select 1 from bookings
              where member_id = p_member_id and studio_id = p_studio_id
                and status in ('booked','waitlisted','attended','no_show','pending_payment')
                and (p_exclude_booking is null or id <> p_exclude_booking)) then
    return jsonb_build_object('ok', false, 'reason', 'not_first');
  end if;

  return jsonb_build_object('ok', true);
end $$;
revoke execute on function free_first_eligibility_run(uuid, uuid, uuid) from public, anon, authenticated;
grant  execute on function free_first_eligibility_run(uuid, uuid, uuid) to service_role;

-- ===========================================================================
-- 2. free_first_eligibility — the guarded wrapper, byte-for-byte from 297.
-- ===========================================================================
create or replace function free_first_eligibility(
  p_studio_id uuid, p_member_id uuid, p_exclude_booking uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_member members%rowtype;
begin
  select * into v_member from members where id = p_member_id;
  if not found or v_member.studio_id <> p_studio_id then
    raise exception 'no such member here' using errcode = 'PT404';
  end if;
  -- Self, desk-up, or a background job (migration 056): the grant is not the guard.
  if not (coalesce(v_member.user_id = auth.uid(), false)
          or coalesce(is_desk_up(p_studio_id), false)
          or is_service_context()) then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;
  return free_first_eligibility_run(p_studio_id, p_member_id, p_exclude_booking);
end $$;
revoke execute on function free_first_eligibility(uuid, uuid, uuid) from public, anon;
grant  execute on function free_first_eligibility(uuid, uuid, uuid) to authenticated, service_role;

-- ===========================================================================
-- 3. convert_missed_you PLATFORM DEFAULT — the free class was used; offer the
--    intro plan with the standard plan card and buy_url (the convert sweep
--    payload already carries offer_plan_name/offer_detail/offer_price/buy_url).
--    notification_templates holds only the platform default (no studio_id); a
--    studio override lives in notification_templates_overrides and is untouched.
-- ===========================================================================
update notification_templates set
  text_body = E'Hi {first_name},\n\nWe had you down for {class_name} and didn''t get to meet you. That was your free first class, so it''s been used — but {offer_plan_name} ({offer_price}) is an easy way to start properly:\n\n{buy_url}\n\n— {studio_name}',
  html_body = '<p>Hi {first_name},</p>
<p>We had you down for {class_name} and didn&#39;t get to meet you. That was your free first class, so it&#39;s been used — but {offer_plan_name} is an easy way to start properly:</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{offer_plan_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">{offer_detail}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;color:#14170E;margin-top:8px">{offer_price}</div><div style="margin-top:4px"><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{buy_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Buy {offer_plan_name} — {offer_price}</a></td></tr></table></div></td></tr></table>
<p>— {studio_name}</p>'
where key = 'convert_missed_you';
