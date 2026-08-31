-- =============================================================================
-- MIGRATION 025 — everything the member app needs that did not exist
--
-- Written after asking the database what a real member session actually
-- returns, rather than after designing screens and hoping. Signed in as a
-- member with 76 attended classes:
--
--   own check-ins visible ............ 76
--   ...of which the class is named ...  0
--   past occurrences visible .........  0
--   rooms visible ....................  0
--   studio_settings visible ..........  0
--
-- The History screen would have rendered seventy-six rows reading "Visit", and
-- looked finished. occ_member_read is `status = 'scheduled'`, which is right
-- for a schedule and wrong for a history: a class disappears from the member's
-- view the moment it runs.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. A member may read the classes they were actually at
--
-- Deliberately not "widen occ_member_read to all statuses". That would hand
-- every member the studio's entire past schedule. This is scoped to
-- occurrences the member has a booking or a check-in for, which is exactly
-- their own history and nothing else.
-- -----------------------------------------------------------------------------
create policy occ_member_own_read on class_occurrences
  for select using (
    exists (
      select 1 from bookings b join members m on m.id = b.member_id
       where b.occurrence_id = class_occurrences.id and m.user_id = auth.uid()
    )
    or exists (
      select 1 from check_ins c join members m on m.id = c.member_id
       where c.occurrence_id = class_occurrences.id and m.user_id = auth.uid()
    )
  );

-- A member arriving needs to know which room to walk into.
create policy rooms_member_read on rooms
  for select using (studio_id in (select auth_member_studios()));

-- -----------------------------------------------------------------------------
-- 2. The settings a member is allowed to know
--
-- Not a policy on studio_settings: RLS is row-level, so a read policy would
-- also hand over morning_brief_send_at, every fee setting and the onboarding
-- state. A function returns the four things the app needs and nothing else —
-- the same shape as studio_by_slug() in migration 004.
-- -----------------------------------------------------------------------------
create function studio_member_settings(p_studio_id uuid)
returns table (
  checkin_opens_minutes_before int,
  checkin_closes_minutes_after int,
  cancellation_cutoff_minutes  int,
  booking_cutoff_minutes       int,
  waitlist_enabled             boolean,
  week_starts_on               int
)
language sql stable security definer set search_path = public as $$
  select s.checkin_opens_minutes_before, s.checkin_closes_minutes_after,
         s.cancellation_cutoff_minutes, s.booking_cutoff_minutes,
         s.waitlist_enabled, s.week_starts_on
    from studio_settings s
   where s.studio_id = p_studio_id
     and (p_studio_id in (select auth_member_studios())
          or p_studio_id in (select auth_staff_studios()))
$$;
revoke execute on function studio_member_settings(uuid) from public;
grant execute on function studio_member_settings(uuid) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 3. The rotating check-in code — Permissions §8 note 13
--
-- No table and no stored tokens. The code is an HMAC of the member id and a
-- 30-second time bucket, keyed by a per-studio secret the member can never
-- read. It therefore cannot be forged, and a screenshot is worthless thirty
-- seconds later.
--
-- resolve_checkin_code() accepts the current bucket or the one before it: a
-- scan takes a moment, and a code that stops working mid-rotation is a member
-- standing at the desk holding up a phone that has just gone stale.
-- -----------------------------------------------------------------------------
alter table studio_settings
  add column checkin_secret uuid not null default gen_random_uuid();

create function checkin_code_for(p_member_id uuid, p_bucket bigint) returns text
language sql stable security definer set search_path = public, extensions as $$
  select upper(substring(
           encode(hmac(m.id::text || ':' || p_bucket::text, s.checkin_secret::text, 'sha256'), 'hex')
           from 1 for 8))
    from members m
    join studio_settings s on s.studio_id = m.studio_id
   where m.id = p_member_id
$$;
revoke execute on function checkin_code_for(uuid, bigint) from public;

/** The member's own code, and how long before it changes. */
create function member_checkin_code()
returns table (code text, member_name text, seconds_left int)
language plpgsql stable security definer set search_path = public as $$
declare m members%rowtype; v_bucket bigint;
begin
  select * into m from members where user_id = auth.uid() limit 1;
  if not found then
    raise exception 'no member for this account' using errcode = 'PT403';
  end if;
  v_bucket := floor(extract(epoch from now()) / 30)::bigint;
  return query
    select checkin_code_for(m.id, v_bucket),
           m.first_name || ' ' || m.last_name,
           (30 - (floor(extract(epoch from now()))::bigint % 30))::int;
end $$;
revoke execute on function member_checkin_code() from public;
grant execute on function member_checkin_code() to authenticated;

/** Desk side: turn a scanned code back into a member. */
create function resolve_checkin_code(p_code text)
returns table (member_id uuid, first_name text, last_name text, email text)
language plpgsql stable security definer set search_path = public as $$
declare v_bucket bigint; v_code text := upper(btrim(p_code));
begin
  v_bucket := floor(extract(epoch from now()) / 30)::bigint;
  return query
    select m.id, m.first_name, m.last_name, m.email
      from members m
     where is_desk_up(m.studio_id)
       and (checkin_code_for(m.id, v_bucket)     = v_code
         or checkin_code_for(m.id, v_bucket - 1) = v_code)
     limit 1;
end $$;
revoke execute on function resolve_checkin_code(text) from public;
grant execute on function resolve_checkin_code(text) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 4. Cancelling — Business Rules §3.1
--
-- Before the cutoff the credit comes back; after it, the credit is consumed if
-- the studio says so. Either way the seat is released, because §3.1 is explicit
-- that penalising the member and holding the seat empty helps nobody.
--
-- A returned credit is restored to the entry it came from and keeps that
-- entry's expiry. If the pack has since expired the credit is not returned and
-- the member is told why rather than left to notice a number that did not move.
-- -----------------------------------------------------------------------------
create type cancel_result as (
  status         booking_status,
  credit_returned boolean,
  reason          text,       -- why a credit did not come back, when it did not
  offer_made      boolean
);

create function cancel_booking(p_booking_id uuid) returns cancel_result
language plpgsql security definer set search_path = public as $$
declare
  b        bookings%rowtype;
  occ      class_occurrences%rowtype;
  st       studio_settings%rowtype;
  v_member members%rowtype;
  v_late   boolean;
  v_entry  credit_ledger%rowtype;
  v_bal    int;
  v_res    cancel_result;
  v_mins   int;
  v_window int;
  v_next   bookings%rowtype;
begin
  select * into b from bookings where id = p_booking_id;
  if not found then
    raise exception 'no such booking' using errcode = 'PT404';
  end if;

  select * into v_member from members where id = b.member_id for update;

  -- The member themselves, or desk-up staff acting for them.
  if not (v_member.user_id = auth.uid() or is_desk_up(b.studio_id)) then
    raise exception 'that is not your booking' using errcode = 'PT403';
  end if;

  if b.status not in ('booked', 'waitlisted') then
    raise exception 'this booking is already %', b.status using errcode = 'PT409';
  end if;

  select * into occ from class_occurrences where id = b.occurrence_id for update;
  select * into st  from studio_settings where studio_id = b.studio_id;

  -- Leaving a waitlist is free and unconditional — §4.1.
  if b.status = 'waitlisted' then
    update bookings set status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid()
     where id = p_booking_id;
    update class_occurrences
       set waitlist_count = greatest(0, waitlist_count - 1)
     where id = occ.id;
    v_res := ('cancelled'::booking_status, false, null, false);
    return v_res;
  end if;

  v_late := now() > occ.starts_at - make_interval(mins => st.cancellation_cutoff_minutes);

  -- Cast explicitly: a CASE over two string literals is text, and assigning
  -- text to a booking_status column fails at runtime rather than at create
  -- time, so the function looked fine until something cancelled anything.
  update bookings
     set status = (case when v_late then 'late_cancelled' else 'cancelled' end)::booking_status,
         cancelled_at = now(), cancelled_by = auth.uid(),
         is_late_cancel = v_late
   where id = p_booking_id;

  update class_occurrences
     set booked_count = greatest(0, booked_count - 1)
   where id = occ.id;

  v_res.status := (case when v_late then 'late_cancelled' else 'cancelled' end)::booking_status;
  v_res.credit_returned := false;
  v_res.offer_made := false;

  -- Credit, if one was taken.
  if b.credit_entry_id is not null then
    select * into v_entry from credit_ledger where id = b.credit_entry_id;

    if v_late and coalesce(st.late_cancel_consumes_credit, true) then
      v_res.reason := 'Cancelled inside the notice period, so the class is used.';
    elsif v_entry.expires_at is not null and v_entry.expires_at < now() then
      -- §3.1: a credit cannot be resurrected past its expiry.
      v_res.reason := 'That class pack has expired, so the credit could not go back on.';
    else
      select coalesce(sum(delta), 0) into v_bal
        from credit_ledger
       where studio_id = b.studio_id and member_id = b.member_id;

      insert into credit_ledger (studio_id, member_id, membership_id, delta, reason,
                                 booking_id, balance_after, expires_at, actor_user_id)
      values (b.studio_id, b.member_id, v_entry.membership_id, 1, 'cancellation_refund',
              p_booking_id, v_bal + 1, v_entry.expires_at, auth.uid());

      if v_entry.membership_id is not null then
        update memberships set credits_remaining = coalesce(credits_remaining, 0) + 1
         where id = v_entry.membership_id;
      end if;
      v_res.credit_returned := true;
    end if;
  end if;

  -- §4.2: a freed seat offers itself to the front of the waitlist. §4.3 clamps
  -- the window, and refuses to make an offer nobody could realistically take.
  if coalesce(st.waitlist_enabled, true) then
    select * into v_next from bookings
     where occurrence_id = occ.id and status = 'waitlisted'
     order by waitlist_position
     limit 1;

    if found then
      v_mins   := floor(extract(epoch from occ.starts_at - now()) / 60)::int;
      v_window := least(coalesce(st.waitlist_offer_window_minutes, 120),
                        v_mins - coalesce(st.waitlist_cutoff_minutes, 60));
      if v_window >= 15 then
        insert into waitlist_offers (studio_id, booking_id, occurrence_id, expires_at)
        values (occ.studio_id, v_next.id, occ.id,
                now() + make_interval(mins => v_window));
        v_res.offer_made := true;
      end if;
    end if;
  end if;

  return v_res;
end $$;
revoke execute on function cancel_booking(uuid) from public;
grant execute on function cancel_booking(uuid) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 5. Answering an offer
--
-- The seat is held for this member for the duration of the offer, so an offer
-- with nowhere to be accepted holds the seat empty until it expires — worse
-- than no waitlist at all. Accepting re-runs the eligibility gate through
-- book_class(), because their membership may have lapsed since they joined.
-- -----------------------------------------------------------------------------
create function respond_to_offer(p_offer_id uuid, p_accept boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  o   waitlist_offers%rowtype;
  b   bookings%rowtype;
  m   members%rowtype;
  res book_class_result;
begin
  select * into o from waitlist_offers where id = p_offer_id for update;
  if not found then
    raise exception 'no such offer' using errcode = 'PT404';
  end if;
  if o.outcome is not null then
    raise exception 'that offer has already been answered' using errcode = 'PT409';
  end if;
  if o.expires_at < now() then
    update waitlist_offers set outcome = 'expired', responded_at = now() where id = o.id;
    return jsonb_build_object('ok', false, 'reason', 'expired');
  end if;

  select * into b from bookings where id = o.booking_id;
  select * into m from members where id = b.member_id;
  if not (m.user_id = auth.uid() or is_desk_up(o.studio_id)) then
    raise exception 'that is not your offer' using errcode = 'PT403';
  end if;

  if not p_accept then
    update waitlist_offers set outcome = 'declined', responded_at = now() where id = o.id;
    update bookings set status = 'cancelled', cancelled_at = now() where id = b.id;
    update class_occurrences set waitlist_count = greatest(0, waitlist_count - 1)
     where id = o.occurrence_id;
    return jsonb_build_object('ok', true, 'accepted', false);
  end if;

  -- Drop the waitlist row first so book_class() sees a clean slate, then run
  -- the real gate: eligibility, payment source, credit, capacity, all of it.
  update bookings set status = 'cancelled', cancelled_at = now() where id = b.id;
  update class_occurrences set waitlist_count = greatest(0, waitlist_count - 1)
   where id = o.occurrence_id;

  res := book_class(o.occurrence_id, b.member_id, 'member');

  if res.failure_reason is not null then
    update waitlist_offers set outcome = 'failed', responded_at = now() where id = o.id;
    return jsonb_build_object('ok', false, 'reason', res.failure_reason);
  end if;

  update waitlist_offers set outcome = 'accepted', responded_at = now() where id = o.id;
  return jsonb_build_object('ok', true, 'accepted', true,
                            'booking_id', res.booking_id, 'status', res.status);
end $$;
revoke execute on function respond_to_offer(uuid, boolean) from public;
grant execute on function respond_to_offer(uuid, boolean) to authenticated, service_role;

comment on function member_checkin_code() is
  'The member''s rotating check-in code, 30-second bucket. Permissions §8 '
  'note 13. Derived from a per-studio secret the member cannot read, so it '
  'cannot be forged and a screenshot expires with the bucket.';
