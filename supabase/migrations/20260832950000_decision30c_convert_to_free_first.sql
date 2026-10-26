-- =============================================================================
-- Decision 30 amendment (c): "Make this their free class" from the roster.
-- creates: convert_booking_to_free_first(uuid)
-- re-issues: free_first_eligibility(uuid, uuid, uuid)
-- =============================================================================
-- STEP 0 found nine Reform members whose provisional free seat was released by the
-- three-confirmation sweep, who were then (pre-288) told they had used their free
-- class and booked an unpaid drop-in instead. Each holds a host-null guest_passes
-- ledger row, no comp/attended free seat, no membership, and one unpaid drop-in on
-- a class open to first-timers. Staff convert that drop-in into the free class in
-- place.
--
-- The eligibility helper is re-issued (drop + recreate, NOT an overload) to take an
-- optional p_exclude_booking: every place it counts the member's qualifying
-- bookings excludes that one booking when given, so the drop-in being converted no
-- longer makes the member read `already_had_free`/`not_first`. Existing two-arg
-- callers (book_first_free, the member app) resolve to the three-arg function with
-- p_exclude_booking defaulting to null — unchanged behaviour. Same grants
-- (anon=f, authenticated=t, service_role=t), so the anon surface stays THIRTEEN.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. free_first_eligibility — re-issued verbatim from 20260832880000 with ONE
--    addition: an optional p_exclude_booking, threaded into the two places that
--    count the member's own qualifying bookings. The guest-pass, membership and
--    email-variant checks are NOT excluded — a real free class consumed as a guest
--    or a membership held is a disqualifier whatever this drop-in is.
-- -----------------------------------------------------------------------------
drop function if exists free_first_eligibility(uuid, uuid);

create or replace function free_first_eligibility(
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
  -- Self, desk-up, or a background job. Takes an id, returns member-shaped data
  -- (migration 056): the grant is not the guard.
  if not (coalesce(v_member.user_id = auth.uid(), false)
          or coalesce(is_desk_up(p_studio_id), false)
          or is_service_context()) then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;

  if not coalesce((select free_first_class_enabled from studio_settings
                    where studio_id = p_studio_id), false) then
    return jsonb_build_object('ok', false, 'reason', 'not_enabled');
  end if;

  -- Already a member here under an email VARIANT (same normalized key, a
  -- different member row). Decision 30 is for NEW members.
  if exists (select 1 from members
              where studio_id = p_studio_id and id <> p_member_id
                and normalize_email_key(email) = normalize_email_key(v_member.email)) then
    return jsonb_build_object('ok', false, 'reason', 'already_member');
  end if;

  -- The GUEST door (Decision 26): a host-not-null pass on the once-ever key means
  -- they had their free class as someone's guest — done, whatever the booking did.
  if exists (select 1 from guest_passes
              where studio_id = p_studio_id and host_member_id is not null
                and normalize_email_key(guest_email) = normalize_email_key(v_member.email)) then
    return jsonb_build_object('ok', false, 'reason', 'already_had_free');
  end if;

  -- The free-first (signup) door: a host-null pass on the key.
  v_has_hostnull := exists (select 1 from guest_passes
              where studio_id = p_studio_id and host_member_id is null
                and normalize_email_key(guest_email) = normalize_email_key(v_member.email));

  if v_has_hostnull then
    -- Decision 78: a no-show gets ONE more chance. Count the member's OWN free
    -- attempts by the comp bookings they produced (the ledger row is reused on
    -- rebook, so it is never the counter). Attended-a-free-class or holds-any-
    -- membership means they had it / converted; a live comp seat means a free
    -- class is pending; any non-comp class means they are no longer a first-timer.
    -- p_exclude_booking (Decision 30 (c)): the drop-in being converted is excluded
    -- from these counts, so a member holding only that drop-in reads as a
    -- first-timer again.
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
    elsif v_noshow >= 2 then
      return jsonb_build_object('ok', false, 'reason', 'missed_twice');
    else
      -- Decision 30: a CANCELLED free first class never counts (v_noshow = 0, the
      -- only free booking(s) were cancelled), and a single no-show gets one more
      -- chance — either way a first-timer again. book_first_free reuses the single
      -- once-ever ledger row on the rebook.
      return jsonb_build_object('ok', true);
    end if;
  end if;

  -- No free attempt yet. An ordinary not-first-timer check — a comp no_show
  -- cannot reach here (it implies a host-null pass), so this is unchanged. The
  -- drop-in being converted is excluded here too.
  if exists (select 1 from bookings
              where member_id = p_member_id and studio_id = p_studio_id
                and status in ('booked','waitlisted','attended','no_show','pending_payment')
                and (p_exclude_booking is null or id <> p_exclude_booking)) then
    return jsonb_build_object('ok', false, 'reason', 'not_first');
  end if;

  return jsonb_build_object('ok', true);
end $$;
revoke execute on function free_first_eligibility(uuid, uuid, uuid) from public, anon;
grant  execute on function free_first_eligibility(uuid, uuid, uuid) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 2. convert_booking_to_free_first — owner/manager (or service) converts a live
--    unpaid drop-in into the member's free first class, in place, in one
--    transaction. The seat is CONFIRMED and non-provisional whatever
--    free_first_confirm_at is (so the confirmation sweep can never release it), the
--    once-ever guest_passes row is written/reused exactly as book_first_free does,
--    and free_booking_confirmed is queued explicitly (an UPDATE does not fire the
--    AFTER-INSERT notification trigger). No credits, payments or holding fees.
-- -----------------------------------------------------------------------------
create or replace function convert_booking_to_free_first(p_booking_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_b    bookings%rowtype;
  v_occ  class_occurrences%rowtype;
  v_m    members%rowtype;
  v_s    studios%rowtype;
  v_st   studio_settings%rowtype;
  v_elig jsonb;
  v_fmt  text;
  v_manage text;
  v_cancel_deadline text;
  v_pass uuid;
begin
  select * into v_b from bookings where id = p_booking_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;

  -- Owner/manager of the booking's studio, or a background job.
  if not (coalesce(is_manager_up(v_b.studio_id), false) or is_service_context()) then
    raise exception 'only owners and managers do this' using errcode = 'PT403';
  end if;

  if v_b.status in ('cancelled','late_cancelled') then
    return jsonb_build_object('ok', false, 'reason', 'booking is cancelled');
  end if;
  if v_b.payment_source <> 'drop_in' then
    return jsonb_build_object('ok', false, 'reason', 'not a drop-in booking');
  end if;
  if exists (select 1 from payments p
              where p.booking_id = p_booking_id and p.status in ('succeeded','partially_refunded')) then
    return jsonb_build_object('ok', false, 'reason', 'booking is paid');
  end if;

  -- Free-first eligibility judged as if this booking did not exist (answer 1): the
  -- drop-in being converted is excluded from the qualifying-booking counts. Any
  -- other reason (already_had_free via a real free class / membership / guest pass,
  -- already_member, missed_twice, not_first via another paid class, not_enabled)
  -- refuses with the helper's own wording.
  v_elig := free_first_eligibility(v_b.studio_id, v_b.member_id, p_booking_id);
  if not (v_elig ->> 'ok')::boolean then return v_elig; end if;

  -- The class must be open to first-timers (Decision 30 amendment b).
  if not coalesce((effective_free_first(v_b.occurrence_id) ->> 'effective_open')::boolean, false) then
    return jsonb_build_object('ok', false, 'reason', 'class is not open to first-timers');
  end if;

  select * into v_occ from class_occurrences where id = v_b.occurrence_id for update;
  select * into v_m from members where id = v_b.member_id;
  select * into v_s from studios where id = v_b.studio_id;
  select * into v_st from studio_settings where studio_id = v_b.studio_id;
  v_fmt := coalesce(v_st.time_format, '24h');

  -- Mark the seat a free first class (harmless on an UPDATE, consistent with
  -- book_first_free). The seat is CONFIRMED and non-provisional whatever
  -- free_first_confirm_at is, so release_provisional_seats_run never touches it.
  perform set_config('studiior.free_first', '1', true);

  update bookings
     set payment_source = 'comp',
         provisional    = false,
         confirmed_at    = now(),
         status          = 'booked',
         updated_at      = now()
   where id = p_booking_id;
  -- booked_count is unchanged: a booked drop-in already occupies the seat; only the
  -- payment source changes.

  -- The shared once-ever ledger row, written/reused exactly as book_first_free's
  -- upsert on the once-ever index (the nine already have a host-null row — it is
  -- re-pointed at this booking).
  insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email,
                            occurrence_id, guest_booking_id, status, waiver_signed_at)
  values (v_b.studio_id, null, v_m.id, lower(btrim(v_m.email)),
          v_b.occurrence_id, p_booking_id,
          case when v_m.waiver_signed_at is not null then 'confirmed' else 'invited' end,
          v_m.waiver_signed_at)
  on conflict (studio_id, normalize_email_key(guest_email)) do update
    set host_member_id   = excluded.host_member_id,
        guest_member_id  = excluded.guest_member_id,
        occurrence_id    = excluded.occurrence_id,
        guest_booking_id = excluded.guest_booking_id,
        status           = excluded.status,
        waiver_signed_at = excluded.waiver_signed_at
  returning id into v_pass;

  -- free_booking_confirmed, the exact payload shape queue_booking_notifications
  -- builds for its non-provisional free branch. Its own dedupe key (the drop-in's
  -- original booking_confirmed row, if any, used 'booking_confirmed:<id>').
  v_manage := 'https://' || v_s.slug || '.'
              || coalesce(notification_setting('member_app_domain'), 'studiior.app')
              || '/class/' || v_occ.id;
  v_cancel_deadline :=
    fmt_clock(v_occ.starts_at - make_interval(mins => coalesce(v_st.cancellation_cutoff_minutes, 0)), v_s.timezone, v_fmt)
    || ' on ' || to_char(
      (v_occ.starts_at - make_interval(mins => coalesce(v_st.cancellation_cutoff_minutes, 0)))
        at time zone v_s.timezone, 'FMDay FMDD FMMonth YYYY');

  perform queue_notification(v_b.studio_id, v_b.member_id, 'free_booking_confirmed',
    jsonb_build_object('class_name', v_occ.name,
      'day',  to_char(v_occ.starts_at at time zone v_s.timezone, 'FMDay FMDD FMMonth'),
      'time', fmt_clock(v_occ.starts_at, v_s.timezone, v_fmt),
      'cancel_deadline', v_cancel_deadline,
      'manage_link', v_manage,
      'occurrence_id', v_occ.id),
    'free_booking_confirmed:' || p_booking_id);

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (v_b.studio_id, auth.uid(), 'booking.converted_to_free_first', 'bookings', p_booking_id,
          jsonb_build_object('occurrence_id', v_occ.id, 'member_id', v_b.member_id));

  return jsonb_build_object('ok', true, 'booking_id', p_booking_id, 'guest_pass_id', v_pass);
end $$;
revoke execute on function convert_booking_to_free_first(uuid) from public, anon;
grant  execute on function convert_booking_to_free_first(uuid) to authenticated, service_role;

-- Anon surface unchanged — assert THIRTEEN at apply.
do $$
declare n int;
begin
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'expect_%'
     and p.proname not in ('login','sig','psig');
  if n <> 13 then
    raise exception 'anon surface drifted: expected 13, got %', n;
  end if;
end $$;
