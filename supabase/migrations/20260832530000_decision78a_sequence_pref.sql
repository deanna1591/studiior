-- Decision 78a — the sequence opt-out, and notification_wanted gating it.
--
-- re-issues: notification_wanted(uuid, text)
--
-- Every 78 template is a convert_/keep_ key. A member can mute the whole set
-- with one switch (sequence_email, default true) without touching their booking
-- or reminder mail. Re-issued from the newest body (20260832170000), adding one
-- prefix-gated branch; everything else is byte-for-byte.

alter table notification_preferences
  add column sequence_email boolean not null default true;

comment on column notification_preferences.sequence_email is
  'Decision 78: the convert/keep retention sequences. Default on; muting it leaves booking and reminder mail alone.';

create or replace function notification_wanted(p_member_id uuid, p_template text)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare p notification_preferences%rowtype; v_ok boolean;
begin
  -- Decision 50: a campaign goes only to a member whose consent still stands.
  if p_template = 'campaign' then
    select (marketing_opt_in and marketing_unsubscribed_at is null) into v_ok
      from members where id = p_member_id;
    return coalesce(v_ok, false);
  end if;

  -- Decision 78: the convert_/keep_ retention sequences share one switch
  -- (sequence_email), so a member can turn them off without losing booking or
  -- reminder mail. Default true — no prefs row, or a null, means on.
  if left(p_template, 8) = 'convert_' or left(p_template, 5) = 'keep_' then
    select sequence_email into v_ok from notification_preferences where member_id = p_member_id;
    return coalesce(v_ok, true);
  end if;

  if p_template in ('class_cancelled', 'instructor_substituted',
                    'payment_failed', 'staff_message', 'class_moved',
                    'member_invite', 'guest_invite', 'guest_host_cancelled',
                    'guest_waiver_reminder', 'guest_waiver_host_nudge',
                    'flex_booking_confirmed', 'flex_booking_not_confirmed',
                    'free_booking_confirmed', 'free_booking_not_confirmed',
                    'membership_ended', 'membership_frozen') then
    return true;
  end if;

  select * into p from notification_preferences where member_id = p_member_id;
  if not found then
    return true;
  end if;

  return case p_template
    when 'booking_confirmed' then p.booking_email
    when 'flex_booking_pending' then p.booking_email
    when 'free_booking_pending' then p.booking_email
    when 'class_reminder'    then p.reminder_email
    when 'waitlist_offer'    then p.waitlist_email
    when 'waitlist_missed'   then p.waitlist_email
    when 'credit_expiry'     then p.credit_expiry_email
    when 'milestone'         then p.milestone_email
    when 'challenge_started' then p.challenge_email
    when 'challenge_ending'  then p.challenge_email
    when 'challenge_completed' then p.challenge_email
    else true
  end;
end $$;
revoke execute on function notification_wanted(uuid, text) from public, anon, authenticated;
grant  execute on function notification_wanted(uuid, text) to service_role;
