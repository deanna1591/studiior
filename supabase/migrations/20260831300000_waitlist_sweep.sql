-- The waitlist sweep — Business Rules §4.2 (the cascade) and §4.4 (the cutoff).
--
-- DIAGNOSIS. Only cancel_booking ever creates an offer, and only one, to the
-- front waiter, with the §4.3 clamp already applied. Nothing cascades:
-- respond_to_offer's decline closes the offer and stops; an expired offer sits
-- outcome=null forever and the next member is never told; nineteen crons and
-- none touches waitlist_offers, though the (expires_at) where outcome is null
-- index was built for exactly this on day one. So a class runs with an empty
-- reformer while people wait.
--
-- (Not fixed here, flagged: a pending offer does NOT hold the seat — book_class
-- gates on booked_count, which excludes offers — so §4.2's "held for the
-- offered member" is not implemented. That is a change to book_class, separate
-- from this sweep.)

-- The "didn't get in this time" notice (§4.4). Opt-outable with the rest of the
-- waitlist mail.
insert into notification_templates (key, subject, text_body, html_body, note) values
('waitlist_missed', 'You didn''t get in this time — {class_name}',
 E'Hi {first_name},\n\nA place didn''t open in time for {class_name} on {when}. You were on the list — sorry you missed out this time.\n\n{studio_name}',
 E'<p>Hi {first_name},</p><p>A place didn''t open in time for <strong>{class_name}</strong> on {when}. You were on the list — sorry you missed out this time.</p>',
 '§4.4. The waitlist closed at the cutoff and this member was not promoted.');

-- Map it to the waitlist preference (create-or-replace keeps the ACL).
create or replace function notification_wanted(p_member_id uuid, p_template text)
returns boolean
language plpgsql stable security definer set search_path = public as $$
declare p notification_preferences%rowtype;
begin
  if p_template in ('class_cancelled', 'instructor_substituted',
                    'payment_failed', 'staff_message', 'class_moved',
                    'member_invite') then
    return true;
  end if;

  select * into p from notification_preferences where member_id = p_member_id;
  if not found then
    return true;
  end if;

  return case p_template
    when 'booking_confirmed' then p.booking_email
    when 'class_reminder'    then p.reminder_email
    when 'waitlist_offer'    then p.waitlist_email
    when 'waitlist_missed'   then p.waitlist_email
    when 'credit_expiry'     then p.credit_expiry_email
    when 'milestone'         then p.milestone_email
    when 'challenge_joined'      then p.challenge_email
    when 'challenge_milestone'   then p.challenge_email
    when 'challenge_completed'   then p.challenge_email
    when 'challenge_ending_soon' then p.challenge_email
    when 'challenge_opening'     then p.challenge_email
    else true
  end;
end $$;

create function queue_waitlist_missed(p_booking_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare b bookings%rowtype; o class_occurrences%rowtype; s studios%rowtype; v_when text;
begin
  select * into b from bookings where id = p_booking_id;
  select * into o from class_occurrences where id = b.occurrence_id;
  select * into s from studios where id = b.studio_id;
  v_when := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth, HH24:MI');
  return case when queue_notification(b.studio_id, b.member_id, 'waitlist_missed',
      jsonb_build_object('class_name', o.name, 'when', v_when),
      'waitlist_missed:' || p_booking_id) is not null then 1 else 0 end;
end $$;

-- -----------------------------------------------------------------------------
-- §4.2 / §4.3, in one place. Offer the freed seat to the front waiter, with the
-- window clamped, or make no offer at all if there is not a real opportunity —
-- in which case the seat simply stays open. The same formula cancel_booking
-- applies inline for the first offer; this is what every subsequent one uses.
-- Returns whether an offer was made.
-- -----------------------------------------------------------------------------
create function offer_waitlist_seat(p_occurrence_id uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare occ class_occurrences%rowtype; st studio_settings%rowtype; v_next bookings%rowtype;
  v_mins int; v_window int;
begin
  select * into occ from class_occurrences where id = p_occurrence_id for update;
  if not found or occ.status <> 'scheduled' then return false; end if;
  select * into st from studio_settings where studio_id = occ.studio_id;
  if not coalesce(st.waitlist_enabled, true) then return false; end if;

  -- One offer at a time: a pending offer already holds this occurrence's turn.
  if exists (select 1 from waitlist_offers
              where occurrence_id = occ.id and outcome is null) then
    return false;
  end if;
  -- Only when a seat is actually free.
  if occurrence_seats_taken(occ.id) >= occ.capacity then return false; end if;

  select * into v_next from bookings
   where occurrence_id = occ.id and status = 'waitlisted'
   order by waitlist_position
   limit 1;
  if not found then return false; end if;

  -- §4.3: min(window, minutes_to_start − cutoff); under 15 no offer is made.
  v_mins   := floor(extract(epoch from occ.starts_at - now()) / 60)::int;
  v_window := least(coalesce(st.waitlist_offer_window_minutes, 120),
                    v_mins - coalesce(st.waitlist_cutoff_minutes, 60));
  if v_window < 15 then
    return false;   -- a ten-minute window at 6am is not a real opportunity
  end if;

  insert into waitlist_offers (studio_id, booking_id, occurrence_id, expires_at)
  values (occ.studio_id, v_next.id, occ.id, now() + make_interval(mins => v_window));
  return true;   -- the insert trigger sends the offer
end $$;

-- -----------------------------------------------------------------------------
-- The sweep. All studios in one run, each studio's own cutoff and window, a
-- pass recorded in job_runs. EVERY 5 MINUTES: the actionable window between an
-- offer expiring and the cutoff can be as little as 15 minutes, so a 15-minute
-- job could waste a third of it or miss the chance to cascade before the cutoff
-- entirely; the query is a cheap index scan. Idempotent — a closed offer and a
-- cancelled booking are not re-selected, and a pending offer blocks a second, so
-- a re-run is a no-op.
-- -----------------------------------------------------------------------------
create function sweep_waitlist() returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; v_expired int := 0; v_closed int := 0; v_offered int := 0;
begin
  if not is_service_context() then
    raise exception 'the waitlist sweep is a background job' using errcode = 'PT403';
  end if;

  -- 1. EXPIRE (§4.2 step 5). A pending offer past its window closes, and the
  --    member who let it pass leaves the front — the same effect as a decline,
  --    so FIFO moves on rather than re-offering the same person forever.
  for r in
    select w.id as offer_id, w.booking_id, w.occurrence_id
      from waitlist_offers w
     where w.outcome is null and w.expires_at < now()
  loop
    update waitlist_offers set outcome = 'expired', responded_at = now() where id = r.offer_id;
    update bookings set status = 'cancelled', cancelled_at = now()
     where id = r.booking_id and status = 'waitlisted';
    update class_occurrences set waitlist_count = greatest(0, waitlist_count - 1)
     where id = r.occurrence_id;
    v_expired := v_expired + 1;
  end loop;

  -- 2. CUTOFF (§4.4). Inside waitlist_cutoff_minutes, promotions stop: every
  --    remaining waitlisted entry is closed with a "didn't get in" notice, and
  --    any still-pending offer is voided. The seat is already open to general
  --    booking (there is no hold), so that half of §4.4 is a no-op today.
  for r in
    select b.id as booking_id, b.occurrence_id
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
      left join studio_settings st on st.studio_id = b.studio_id
     where b.status = 'waitlisted'
       and o.status = 'scheduled'
       and now() >= o.starts_at - make_interval(mins => coalesce(st.waitlist_cutoff_minutes, 60))
       and now() <  o.starts_at + interval '2 hours'
  loop
    perform queue_waitlist_missed(r.booking_id);
    update bookings set status = 'cancelled', cancelled_at = now() where id = r.booking_id;
    update class_occurrences set waitlist_count = greatest(0, waitlist_count - 1)
     where id = r.occurrence_id;
    update waitlist_offers set outcome = 'closed', responded_at = now()
     where occurrence_id = r.occurrence_id and outcome is null;
    v_closed := v_closed + 1;
  end loop;

  -- 3. PROMOTE (§4.2 cascade). A free seat with waiters and no pending offer,
  --    OUTSIDE the cutoff, gets the next offer. This is how an expiry and a
  --    decline cascade, and how a capacity increase is picked up.
  for r in
    select distinct o.id as occurrence_id
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
      left join studio_settings st on st.studio_id = o.studio_id
     where b.status = 'waitlisted'
       and o.status = 'scheduled'
       and occurrence_seats_taken(o.id) < o.capacity
       and now() < o.starts_at - make_interval(mins => coalesce(st.waitlist_cutoff_minutes, 60))
       and not exists (select 1 from waitlist_offers w
                        where w.occurrence_id = o.id and w.outcome is null)
  loop
    if offer_waitlist_seat(r.occurrence_id) then v_offered := v_offered + 1; end if;
  end loop;

  insert into job_runs (job_key, run_for, status, finished_at)
  values ('waitlist', current_date, 'done', now())
  on conflict (job_key, run_for) do update
     set attempts = job_runs.attempts + 1, started_at = now(),
         status = 'done', finished_at = now();

  return jsonb_build_object('expired', v_expired, 'closed', v_closed, 'offered', v_offered);
end $$;

do $$ begin
  if exists (select 1 from cron.job where jobname = 'studiior-waitlist') then
    perform cron.unschedule('studiior-waitlist');
  end if;
  perform cron.schedule('studiior-waitlist', '*/5 * * * *', $job$select sweep_waitlist()$job$);
end $$;

revoke execute on function offer_waitlist_seat(uuid)  from public, anon, authenticated;
revoke execute on function queue_waitlist_missed(uuid) from public, anon, authenticated;
revoke execute on function sweep_waitlist()            from public, anon, authenticated;
grant  execute on function offer_waitlist_seat(uuid)   to service_role;
grant  execute on function queue_waitlist_missed(uuid) to service_role;
grant  execute on function sweep_waitlist()            to service_role;
