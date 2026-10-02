-- =============================================================================
-- Decision 30 amendment — free first classes are GROUPED: core only, curated
-- trial-friendly series, fullest-first, capped, and PROVISIONAL until the class
-- holds N people. A free seat must never be the only person in a room (the
-- instructor is paid the 1-pax rate and the studio earns nothing).
--
-- Four per-studio controls, all defaulting to today's behaviour so the all_off
-- canary is unchanged; the provisional/confirm/release machinery rides the
-- existing commitment cutoff (occurrence_guarantee_run), reusing Decision 21's
-- pending state and Decision 26's once-ever ledger.
--
-- creates:   confirm_provisional_seats_run(uuid), release_provisional_seats_run(uuid),
--            free_first_eligible_classes_run(uuid, uuid, int), free_first_class_list(uuid)
-- re-issues: book_first_free(uuid), book_class(uuid, uuid, booking_source, text, payment_source),
--            book_guest(uuid, text, text, text), queue_booking_notifications(uuid),
--            member_pending_bookings(uuid), evaluate_commitment(uuid),
--            cancel_occurrence(uuid, text, cancellation_cause),
--            bulk_update_series_run(uuid[], jsonb, boolean), notification_wanted(uuid, text)
-- =============================================================================

-- ---- Schema ----------------------------------------------------------------
alter table studio_settings add column if not exists free_first_core_only boolean not null default false;
alter table studio_settings add column if not exists free_first_seats_per_class int;
alter table studio_settings add column if not exists free_first_confirm_at int;
alter table studio_settings drop constraint if exists free_first_seats_per_class_ck;
alter table studio_settings add constraint free_first_seats_per_class_ck
  check (free_first_seats_per_class is null or free_first_seats_per_class > 0);
alter table studio_settings drop constraint if exists free_first_confirm_at_ck;
alter table studio_settings add constraint free_first_confirm_at_ck
  check (free_first_confirm_at is null or free_first_confirm_at >= 2);

alter table class_series add column if not exists free_first_allowed boolean not null default true;

-- provisional: a comp free seat awaiting confirmation. confirmed_at: when it was
-- confirmed (latch — never cleared once set). Existing comp bookings keep
-- provisional = false and are grandfathered: confirmed as they stand.
alter table bookings add column if not exists provisional boolean not null default false;
alter table bookings add column if not exists confirmed_at timestamptz;

comment on column studio_settings.free_first_confirm_at is
  'Decision 30 amendment: a free seat is provisional until the class holds at least this many people in total (paid or free); null = confirmed on booking.';

-- ---- confirm_provisional_seats_run -----------------------------------------
-- Called after every booking INSERT that counts toward the headcount (book_class,
-- book_first_free, book_guest). When the class reaches confirm_at, every
-- provisional free seat on it is confirmed AT ONCE and the person told. A latch:
-- it only ever acts on provisional = true rows, so re-running it never reverts a
-- confirmed seat. Service-role only; reached from the SECURITY DEFINER writers.
create or replace function confirm_provisional_seats_run(p_occurrence_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare o class_occurrences%rowtype; s studios%rowtype; st studio_settings%rowtype;
        v_head int; n int := 0; r record;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then return 0; end if;
  select * into st from studio_settings where studio_id = o.studio_id;
  if st.free_first_confirm_at is null then return 0; end if;

  -- People in the room, paid or free — the same count evaluate_commitment uses.
  select count(*)::int into v_head from bookings
   where occurrence_id = p_occurrence_id
     and status in ('booked','attended','no_show','pending_payment');
  if v_head < st.free_first_confirm_at then return 0; end if;

  select * into s from studios where id = o.studio_id;
  for r in select id, member_id from bookings
            where occurrence_id = p_occurrence_id and status = 'booked' and provisional
  loop
    update bookings set provisional = false, confirmed_at = now() where id = r.id;
    perform queue_notification(o.studio_id, r.member_id, 'free_booking_confirmed',
      jsonb_build_object('class_name', o.name,
        'day',  to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth'),
        'time', to_char(o.starts_at at time zone s.timezone, 'HH24:MI'),
        'cancel_deadline', to_char(
          (o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)))
            at time zone s.timezone, 'HH24:MI "on" FMDay FMDD FMMonth YYYY'),
        'manage_link', 'https://' || s.slug || '.'
          || coalesce(notification_setting('member_app_domain'), 'studiior.app') || '/class/' || o.id,
        'occurrence_id', p_occurrence_id),
      'free_confirmed:' || r.id);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function confirm_provisional_seats_run(uuid) from public, anon, authenticated;
grant  execute on function confirm_provisional_seats_run(uuid) to service_role;

-- ---- free_first_eligible_classes_run ---------------------------------------
-- The classes this member may take as a free first class, FULLEST FIRST. The one
-- predicate behind both the free booker's list and the "next ones" in the
-- not-confirmed email. No caller guard (service-role only); the member-level gate
-- is free_first_eligibility, the class-level gates are inline here.
create or replace function free_first_eligible_classes_run(
  p_studio_id uuid, p_member_id uuid, p_min_headcount int default 0)
returns table(occurrence_id uuid, name text, starts_at timestamptz, duration_min int,
              room_name text, instructor_first text, headcount int, capacity int,
              free_bookable boolean)
language plpgsql stable security definer set search_path = public as $$
declare st studio_settings%rowtype; v_elig jsonb;
begin
  select * into st from studio_settings where studio_id = p_studio_id;
  v_elig := free_first_eligibility(p_studio_id, p_member_id);
  if not coalesce((v_elig ->> 'ok')::boolean, false) then return; end if;

  return query
  select o.id, o.name, o.starts_at,
         coalesce(ct.duration_minutes, 0),
         (select r.name from rooms r where r.id = o.room_id),
         (select split_part(i.display_name, ' ', 1) from instructors i where i.id = o.instructor_id),
         coalesce(o.booked_count, 0), o.capacity,
         ( o.capacity - occurrence_seats_taken(o.id) - occurrence_seats_held(o.id) >= 1
           and (st.free_first_seats_per_class is null
                or (select count(*) from bookings b
                     where b.occurrence_id = o.id and b.status = 'booked'
                       and b.payment_source = 'comp'
                       and exists (select 1 from guest_passes gp
                                    where gp.guest_booking_id = b.id and gp.host_member_id is null))
                    < st.free_first_seats_per_class) )
    from class_occurrences o
    left join class_series ser on ser.id = o.series_id
    left join class_types  ct  on ct.id  = o.class_type_id
   where o.studio_id = p_studio_id
     and o.status = 'scheduled'
     and o.starts_at > now()
     and o.starts_at <= now() + make_interval(days => coalesce(st.booking_window_days, 30))
     and o.starts_at >= now() + make_interval(mins => coalesce(st.booking_cutoff_minutes, 0))
     -- Decision 48 (and scheduled + published) for THIS member.
     and occurrence_member_visible_run(o.id, p_member_id)
     -- core_only: the CONFIGURED tier (the studio's intent), not the demoted one.
     and (not coalesce(st.free_first_core_only, false)
          or coalesce(o.guarantee_tier, case when o.flex then 'flex'::guarantee_tier end,
                      ser.guarantee_tier, case when ser.flex then 'flex'::guarantee_tier end,
                      'core'::guarantee_tier) = 'core')
     -- the series toggle (a one-off has no series and is allowed)
     and (o.series_id is null or coalesce(ser.free_first_allowed, true))
     -- peak, if the studio keeps free classes out of its peak hours
     and not (not coalesce(st.free_first_peak_allowed, true) and occurrence_is_peak(o.id))
     and coalesce(o.booked_count, 0) >= p_min_headcount
   order by coalesce(o.booked_count, 0) desc, o.starts_at;
end $$;
revoke execute on function free_first_eligible_classes_run(uuid, uuid, int) from public, anon, authenticated;
grant  execute on function free_first_eligible_classes_run(uuid, uuid, int) to service_role;

-- ---- free_first_class_list -------------------------------------------------
-- The free booker's list, member-guarded (self), fullest first.
create or replace function free_first_class_list(p_studio_id uuid)
returns table(occurrence_id uuid, name text, starts_at timestamptz, duration_min int,
              room_name text, instructor_first text, headcount int, capacity int,
              free_bookable boolean)
language plpgsql stable security definer set search_path = public as $$
declare v_member uuid;
begin
  select id into v_member from members where user_id = auth.uid() and studio_id = p_studio_id;
  if v_member is null then
    raise exception 'not a member of that studio' using errcode = 'PT403';
  end if;
  return query select * from free_first_eligible_classes_run(p_studio_id, v_member, 0);
end $$;
revoke execute on function free_first_class_list(uuid) from public, anon;
grant  execute on function free_first_class_list(uuid) to authenticated, service_role;

-- ---- release_provisional_seats_run -----------------------------------------
-- At the class's cutoff (or a manual cancellation), a still-provisional free
-- seat is released: cancelled with release_reason trial_not_confirmed, the
-- booked_count decremented, the once-ever guest_passes row REMOVED (the person
-- keeps their free class), and the person told with the next classes that
-- already have people in. Service-role only; reached from evaluate_commitment
-- and cancel_occurrence. Idempotent — a second call finds no provisional seats.
create or replace function release_provisional_seats_run(p_occurrence_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare o class_occurrences%rowtype; s studios%rowtype; r record; n int := 0;
        v_when text; v_when_short text; v_list text;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then return 0; end if;
  select * into s from studios where id = o.studio_id;
  v_when       := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY');
  v_when_short := to_char(o.starts_at at time zone s.timezone, 'FMDy FMDD FMMon HH24:MI');

  for r in select b.id, b.member_id from bookings b
            where b.occurrence_id = p_occurrence_id and b.status = 'booked' and b.provisional
  loop
    -- Release, directly: the explicit release_reason means the BEFORE stamp
    -- trigger leaves it, is_late_cancel false means no infraction, and a comp
    -- seat has no credit to return.
    update bookings
       set status = 'cancelled', release_reason = 'trial_not_confirmed',
           cancelled_at = now(), cancelled_by = null, is_late_cancel = false
     where id = r.id;
    update class_occurrences set booked_count = greatest(0, booked_count - 1)
     where id = p_occurrence_id;
    -- The once-ever row goes, so the person is eligible again and keeps their
    -- free class. Removed, not left 'cancelled' — free_first_eligibility's
    -- already_had_free check does not look at status.
    delete from guest_passes where guest_booking_id = r.id;

    -- Now eligible again, so the "next ones" are computed with this person's own
    -- gates: fullest first, with someone already in; fall back to any eligible.
    select string_agg(z.line, '; ' order by z.ord)
      into v_list
      from (
        select to_char(c.starts_at at time zone s.timezone, 'FMDay HH24:MI') || ' ' || c.name as line,
               row_number() over (order by c.headcount desc, c.starts_at) as ord
          from free_first_eligible_classes_run(o.studio_id, r.member_id, 1) c
         where c.occurrence_id <> p_occurrence_id and c.free_bookable
         limit 3) z;
    if v_list is null then
      select string_agg(z.line, '; ' order by z.ord)
        into v_list
        from (
          select to_char(c.starts_at at time zone s.timezone, 'FMDay HH24:MI') || ' ' || c.name as line,
                 row_number() over (order by c.headcount desc, c.starts_at) as ord
            from free_first_eligible_classes_run(o.studio_id, r.member_id, 0) c
           where c.occurrence_id <> p_occurrence_id and c.free_bookable
           limit 3) z;
    end if;

    perform queue_notification(o.studio_id, r.member_id, 'free_booking_not_confirmed',
      jsonb_build_object('class_name', o.name, 'when', v_when, 'day_short', v_when_short,
        'time', to_char(o.starts_at at time zone s.timezone, 'HH24:MI'),
        'next_three', coalesce(v_list, 'see the full schedule'),
        'occurrence_id', p_occurrence_id),
      'free_not_confirmed:' || r.id);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function release_provisional_seats_run(uuid) from public, anon, authenticated;
grant  execute on function release_provisional_seats_run(uuid) to service_role;

-- ---- Templates (member). Year in dates per Decision 33 amendment. ----------
insert into notification_templates (key, subject, text_body, html_body, note) values
('free_booking_pending',
 'You''re booked — {class_name}',
 E'You''re booked for {class_name}, {when}, as your free first class. You''ll receive a confirmation of your booking as soon as the class is on — at the latest by {cutoff_long}. Nothing else to do for now.',
 '<p>You''re booked for <strong>{class_name}</strong>, {when}, as your free first class.</p><p>You''ll receive a confirmation of your booking as soon as the class is on — at the latest by {cutoff_long}. Nothing else to do for now.</p>',
 'Decision 30 amendment. A provisional free seat''s receipt; same dedupe key as booking_confirmed, so it is withdrawn on release.'),
('free_booking_confirmed',
 '{class_name} on {day} is confirmed',
 E'{class_name} on {day} is confirmed — see you at {time}. This is your free first class: if you can''t make it, cancel before {cancel_deadline} or rebook another class, otherwise the free class is used.\n\nManage your booking: {manage_link}',
 '<p><strong>{class_name}</strong> on {day} is confirmed — see you at {time}.</p><p>This is your free first class: if you can''t make it, cancel before {cancel_deadline} or rebook another class, otherwise the free class is used.</p><p><a href="{manage_link}">Manage booking</a></p>',
 'Decision 30 amendment. Sent when a free class reaches its confirm-at headcount.'),
('free_booking_not_confirmed',
 '{class_name}, {day_short} — booking not confirmed',
 E'Your booking for {class_name} on {when} wasn''t confirmed this time. Your free first class is still yours — pick another class and we''ll see you there. Here are the next ones with people already in: {next_three}.',
 '<p>Your booking for <strong>{class_name}</strong> on {when} wasn''t confirmed this time.</p><p>Your free first class is still yours — pick another class and we''ll see you there.</p><p>Here are the next ones with people already in: {next_three}.</p>',
 'Decision 30 amendment. Sent when a provisional free seat is released at the cutoff; the person keeps their free class.')
on conflict (key) do nothing;

-- ---- notification_wanted: the two outcomes always send; the pending receipt
--      follows booking_email (like the Decision 21 flex pair). ---------------
create or replace function notification_wanted(p_member_id uuid, p_template text)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare p notification_preferences%rowtype;
begin
  if p_template in ('class_cancelled', 'instructor_substituted',
                    'payment_failed', 'staff_message', 'class_moved',
                    'member_invite', 'guest_invite', 'guest_host_cancelled',
                    'guest_waiver_reminder', 'guest_waiver_host_nudge',
                    'flex_booking_confirmed', 'flex_booking_not_confirmed',
                    -- Decision 30 amendment: the free-booking outcome, either way.
                    'free_booking_confirmed', 'free_booking_not_confirmed') then
    return true;
  end if;

  select * into p from notification_preferences where member_id = p_member_id;
  if not found then
    return true;
  end if;

  return case p_template
    when 'booking_confirmed' then p.booking_email
    when 'flex_booking_pending' then p.booking_email
    -- Decision 30 amendment: the provisional free receipt is a booking receipt.
    when 'free_booking_pending' then p.booking_email
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

-- =============================================================================
-- Re-issued functions follow (book_first_free, book_class, book_guest,
-- queue_booking_notifications, member_pending_bookings, evaluate_commitment,
-- cancel_occurrence, bulk_update_series_run) — each from its newest definition
-- with the amendment edits only. ACLs are kept by create-or-replace.
-- =============================================================================

-- ---- book_first_free ----
CREATE OR REPLACE FUNCTION public.book_first_free(p_occurrence_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_occ    class_occurrences%rowtype;
  v_member members%rowtype;
  v_set    studio_settings%rowtype;
  v_ser    class_series%rowtype;         -- Decision 30 amendment
  v_cfg_tier guarantee_tier;             -- Decision 30 amendment
  v_tz     text;
  v_elig   jsonb;
  v_free   int;
  v_head   int;                          -- Decision 30 amendment: headcount after this seat
  v_cut    timestamptz;                  -- Decision 30 amendment: the class's own cutoff
  v_prov   boolean;                      -- Decision 30 amendment
  v_booking uuid;
  v_pass    uuid;
begin
  select * into v_occ from class_occurrences where id = p_occurrence_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;

  -- The caller's own member row in this studio (self only — a member books their
  -- own free class, never someone else's).
  select * into v_member from members
   where studio_id = v_occ.studio_id and user_id = auth.uid();
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_authorised'); end if;

  v_elig := free_first_eligibility(v_occ.studio_id, v_member.id);
  if not (v_elig ->> 'ok')::boolean then return v_elig; end if;

  select * into v_set from studio_settings where studio_id = v_occ.studio_id;
  select timezone into v_tz from studios where id = v_occ.studio_id;

  -- The occurrence must be bookable at all: scheduled, ahead, published, inside
  -- the window and before the cutoff — the same shape as book_class's own gates,
  -- so a free class cannot reach a class a paid one could not.
  if v_occ.status <> 'scheduled' then return jsonb_build_object('ok', false, 'reason', 'class_not_bookable'); end if;
  if v_occ.starts_at <= now() then return jsonb_build_object('ok', false, 'reason', 'class_in_past'); end if;
  if not month_published(v_occ.studio_id, v_occ.starts_at) then
    return jsonb_build_object('ok', false, 'reason', 'month_not_published');
  end if;
  -- Decision 48: an unstaffed hidden class is closed to new bookings.
  if studio_hides_unstaffed(v_occ.studio_id) and v_occ.staffing <> 'assigned' then
    return jsonb_build_object('ok', false, 'reason', 'not_staffed_yet');
  end if;
  if v_occ.starts_at > now() + make_interval(days => coalesce(v_set.booking_window_days, 30)) then
    return jsonb_build_object('ok', false, 'reason', 'outside_booking_window');
  end if;
  if v_occ.starts_at < now() + make_interval(mins => coalesce(v_set.booking_cutoff_minutes, 0)) then
    return jsonb_build_object('ok', false, 'reason', 'past_booking_cutoff');
  end if;

  -- A free class displaces a paying member and the instructor is paid regardless,
  -- so a studio can keep free classes out of its peak hours.
  if not coalesce(v_set.free_first_peak_allowed, true) and occurrence_is_peak(p_occurrence_id) then
    return jsonb_build_object('ok', false, 'reason', 'peak_not_allowed');
  end if;

  -- Decision 30 amendment — grouped free classes. The configured tier (the
  -- studio's intent, before any switch demotion), the series toggle, and the
  -- per-class cap. A reason per gate, rendered as a sentence by the UI.
  if v_occ.series_id is not null then
    select * into v_ser from class_series where id = v_occ.series_id;
  end if;
  v_cfg_tier := coalesce(v_occ.guarantee_tier,
                         case when v_occ.flex then 'flex'::guarantee_tier end,
                         v_ser.guarantee_tier,
                         case when v_ser.flex then 'flex'::guarantee_tier end,
                         'core'::guarantee_tier);
  if coalesce(v_set.free_first_core_only, false) and v_cfg_tier <> 'core' then
    return jsonb_build_object('ok', false, 'reason', 'flex_not_allowed');
  end if;
  if v_occ.series_id is not null
     and not coalesce(v_ser.free_first_allowed, true) then
    return jsonb_build_object('ok', false, 'reason', 'not_trial_class');
  end if;
  if v_set.free_first_seats_per_class is not null
     and (select count(*) from bookings b
           where b.occurrence_id = p_occurrence_id and b.status = 'booked'
             and b.payment_source = 'comp'
             and exists (select 1 from guest_passes gp
                          where gp.guest_booking_id = b.id and gp.host_member_id is null))
         >= v_set.free_first_seats_per_class then
    return jsonb_build_object('ok', false, 'reason', 'free_seats_full');
  end if;

  -- One seat, and a live waitlist offer's held seat (§4.2) is not free to take.
  v_free := v_occ.capacity - occurrence_seats_taken(p_occurrence_id)
                           - occurrence_seats_held(p_occurrence_id);
  if v_free < 1 then return jsonb_build_object('ok', false, 'reason', 'class_full'); end if;

  -- Decision 30 amendment: PROVISIONAL until the class holds confirm_at people.
  -- The headcount this seat makes is the current taken count plus one. Provisional
  -- only when a real cutoff exists (occurrence_guarantee_run), so a provisional
  -- seat is always resolved — confirmed when the class fills, or released at that
  -- cutoff by the sweep. With confirm_at null, or no cutoff, the seat is confirmed
  -- on booking, which is today's behaviour.
  v_head := occurrence_seats_taken(p_occurrence_id) + 1;
  select cutoff_at into v_cut from occurrence_guarantee_run(p_occurrence_id);
  v_prov := v_set.free_first_confirm_at is not null
            and v_cut is not null
            and v_head < v_set.free_first_confirm_at;

  -- The free, separate seat: comp, no membership, no credit, no peak allowance.
  insert into bookings (studio_id, occurrence_id, member_id, status, source,
                        payment_source, provisional, confirmed_at)
  values (v_occ.studio_id, p_occurrence_id, v_member.id, 'booked', 'member', 'comp',
          v_prov, case when v_prov then null else now() end)
  returning id into v_booking;
  update class_occurrences set booked_count = booked_count + 1 where id = p_occurrence_id;

  -- Recorded in the shared ledger with NO HOST — this is the once-ever key, and
  -- it gives the free-first class Decision 26's waiver-at-check-in gate, the
  -- attend/cancel sync and the conversion derivation for free. Confirmed already
  -- if their waiver is signed; otherwise chased exactly as a guest's is.
  insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email,
                            occurrence_id, guest_booking_id, status, waiver_signed_at)
  values (v_occ.studio_id, null, v_member.id, lower(btrim(v_member.email)),
          p_occurrence_id, v_booking,
          case when v_member.waiver_signed_at is not null then 'confirmed' else 'invited' end,
          v_member.waiver_signed_at)
  returning id into v_pass;

  -- Decision 30 amendment: if this seat completed the confirm-at total, confirm
  -- every provisional free seat on the class at once (this one is non-provisional
  -- already in that case; the earlier ones are confirmed here).
  perform confirm_provisional_seats_run(p_occurrence_id);

  return jsonb_build_object('ok', true, 'booking_id', v_booking,
    'guest_pass_id', v_pass, 'provisional', v_prov);
end $function$

;

-- ---- book_class ----
CREATE OR REPLACE FUNCTION public.book_class(p_occurrence_id uuid, p_member_id uuid, p_source booking_source, p_override_reason text DEFAULT NULL::text, p_payment_source payment_source DEFAULT NULL::payment_source)
 RETURNS book_class_result
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_result       book_class_result;
  v_occ          class_occurrences%rowtype;
  v_member       members%rowtype;
  v_set          studio_settings%rowtype;
  v_tz           text;

  v_actor        uuid := auth.uid();
  v_caller_role  text;
  v_trusted      boolean;
  v_is_desk      boolean;
  v_is_self      boolean;
  v_override     boolean := false;
  v_bypassed     text[] := '{}';
  v_comp         boolean := false;
  -- 'booked' unless the member is paying for a drop-in themselves, in which
  -- case the seat is held as 'pending_payment' until Stripe says otherwise.
  v_status       booking_status := 'booked';

  v_window_days  int;
  v_max_per_day  int;
  v_day_count    int;
  v_future_count int;
  v_today        date;

  v_cand         record;
  v_covers       boolean;
  v_restricted   boolean := false;   -- a live plan was blocked purely on class type
  v_peak         jsonb;             -- Decision 24: the paying plan's peak allowance, or null
  v_susp         jsonb;             -- Decision 24: where this member stands on the ladder
  v_pay          payment_source;
  v_membership   uuid;
  v_consume      boolean := false;

  v_booking_id   uuid;
  v_ledger_id    uuid;
  v_balance      int;
  v_position     int;
  v_full         boolean;
  v_phys_full    boolean;   -- capacity reached by REAL seats
  v_held         int;       -- §4.2: seats a live waitlist offer is holding for someone else
begin
  -- ===========================================================================
  -- 0. Locate and authorise. Nothing is written before this passes.
  -- ===========================================================================

  select * into v_occ from class_occurrences where id = p_occurrence_id;
  if not found then
    return (null, null, null, null, 'not_found')::book_class_result;
  end if;

  -- Lockout (migration 044). The studio's own subscription to Studiior has
  -- lapsed past its grace period. Reads stay open everywhere so nothing looks
  -- lost; this is one of the four places where DOING something stops.
  if studio_is_locked(v_occ.studio_id) then
    raise exception 'this studio''s Studiior subscription is not active'
      using errcode = 'PT402',
            hint = 'Reactivate it from Billing. Nothing has been deleted.';
  end if;

  select * into v_member from members where id = p_member_id;
  if not found then
    return (null, null, null, null, 'member_not_found')::book_class_result;
  end if;
  if v_member.studio_id <> v_occ.studio_id then
    return (null, null, null, null, 'member_wrong_studio')::book_class_result;
  end if;

  select * into v_set from studio_settings where studio_id = v_occ.studio_id;
  select timezone into v_tz from studios where id = v_occ.studio_id;

  -- --- Trust is a property of the ROLE, never of a missing auth.uid() -------
  --
  -- A null auth.uid() proves nothing: an `authenticated` caller whose JWT
  -- carries no `sub` claim has one too, and migration 002 handed that caller
  -- full booking rights over every member in the studio.
  --
  -- current_user is useless here — inside a security definer function it is
  -- always the function owner, not the caller. The caller's effective role is
  -- the `role` GUC, which is what PostgREST sets per request and what SET ROLE
  -- sets in a direct session; it is NOT changed by security definer entry.
  -- 'none' means no SET ROLE happened at all, i.e. a direct login session.
  --
  -- rolbypassrls is the honest test of "already privileged above RLS":
  -- service_role, postgres and supabase_admin have it, and gain nothing from
  -- this function that they could not do by writing the tables directly.
  -- authenticated, anon and authenticator do not have it.
  v_caller_role := coalesce(nullif(current_setting('role', true), 'none'),
                            session_user);
  v_trusted := exists (
    select 1 from pg_roles
     where rolname = v_caller_role
       and (rolsuper or rolbypassrls)
  );

  v_is_desk := coalesce(is_desk_up(v_occ.studio_id), false);
  v_is_self := v_actor is not null
               and v_member.user_id is not null
               and v_member.user_id = v_actor;

  if not (v_trusted or v_is_desk or v_is_self) then
    return (null, null, null, null, 'not_authorised')::book_class_result;
  end if;
  -- A member may only book as themselves, and never on a staff source.
  if not (v_trusted or v_is_desk) and p_source <> 'member' then
    return (null, null, null, null, 'not_authorised')::book_class_result;
  end if;

  -- --- §2.4 comp -----------------------------------------------------------
  -- payment_source is otherwise resolved, never chosen (§2.2). 'comp' is the
  -- single exception the business rules allow, and it is staff-only.
  if p_payment_source is not null then
    if p_payment_source <> 'comp' then
      return (null, null, null, null, 'unsupported_payment_source')
             ::book_class_result;
    end if;
    if not (v_trusted or v_is_desk) then
      return (null, null, null, null, 'not_authorised')::book_class_result;
    end if;
    v_comp := true;
  end if;

  -- Business Rules §2.3: overrides are front desk and above only, and always
  -- carry a reason. Rules 1 (past/cancelled), 4 (waiver) and 6 (duplicate)
  -- stay unoverridable below.
  v_override := p_override_reason is not null
                and btrim(p_override_reason) <> ''
                and (v_trusted or v_is_desk);

  -- ===========================================================================
  -- 1. THE LOCK. Data Model §6 — before anything reads booked_count.
  -- ===========================================================================

  select * into v_occ
    from class_occurrences
   where id = p_occurrence_id
     for update;

  -- Then the member row, which serialises this member's own concurrent
  -- bookings so credits_remaining and credit_ledger.balance_after stay
  -- consistent. Lock order is always occurrence -> member; the nightly expiry
  -- job and the Stripe webhook handlers must take the member lock the same way.
  select * into v_member from members where id = p_member_id for update;

  v_today := (now() at time zone v_tz)::date;

  -- ===========================================================================
  -- 2. Eligibility gate — Business Rules §2.1, in order. First failure wins.
  -- ===========================================================================

  -- 2.1.1 Occurrence is scheduled, not cancelled, not in the past. Not overridable.
  if v_occ.status = 'cancelled' then
    return (null, null, null, null, 'class_cancelled')::book_class_result;
  end if;
  if v_occ.status = 'completed' then
    return (null, null, null, null, 'class_completed')::book_class_result;
  end if;
  if v_occ.starts_at <= now() then
    return (null, null, null, null, 'class_in_past')::book_class_result;
  end if;

  -- 2.1.1b Decision 25: the class is on a PUBLISHED month. Placed with the
  -- occurrence checks and BEFORE the booking window, deliberately: an
  -- unpublished class is invisible to members under occ_member_read, so a
  -- member can only reach here with an id they cannot see, and the refusal
  -- names the reason the class is invisible rather than a rule about how far
  -- ahead their plan lets them book. That keeps the two gates composed the
  -- same way on this side as on the screen: "not published" is about the
  -- class, "outside the window" is about the member, and outside_booking_window
  -- goes on meaning exactly what it has since migration 002 — a class on the
  -- timetable that this member may not book YET. month_published() is true for
  -- every studio with the switch off, so nothing changes for them.
  -- Overridable with a reason, like the window: the desk pencilling somebody
  -- into a draft is a deliberate act and is recorded as one.
  if not month_published(v_occ.studio_id, v_occ.starts_at) then
    if v_override then
      v_bypassed := v_bypassed || 'month_not_published'::text;
    else
      return (null, null, null, null, 'month_not_published')::book_class_result;
    end if;
  end if;

  -- 2.1.1c Decision 48: a studio may keep an unstaffed class off the member side
  -- until an instructor is on it. The staffing arm of occurrence_member_visible
  -- (the published/scheduled arms are the checks just above): with the switch on
  -- and the class not assigned, it is closed to NEW bookings. A member who
  -- ALREADY holds a non-cancelled booking is unaffected — they keep their seat
  -- and the class stays visible to them (occ_member_own_read). Hard refusal: a
  -- class nobody is teaching is not something even the desk books into.
  if studio_hides_unstaffed(v_occ.studio_id)
     and v_occ.staffing <> 'assigned'
     and not exists (select 1 from bookings b
                      where b.occurrence_id = p_occurrence_id and b.member_id = p_member_id
                        and b.status <> 'cancelled') then
    return (null, null, null, null, 'not_staffed_yet')::book_class_result;
  end if;

  -- Plan-level overrides for rules 2 and 7 come from the member's highest
  -- priority usable plan (§2.1.2 "plan-level override wins over studio
  -- default"). Read before the gate; the paying source is resolved in §3.
  -- The WINDOW is resolved through member_booking_window_days() — the single
  -- definition of §2.1.2 the member app reads too, so the "Opens for booking"
  -- screen and this rule can never disagree (Decision 36). The daily cap keeps
  -- its own read of the SAME row (identical selection) so behaviour is unchanged.
  v_window_days := member_booking_window_days(p_member_id);
  select mp.max_bookings_per_day
    into v_max_per_day
    from memberships ms
    join membership_plans mp on mp.id = ms.plan_id
   where ms.member_id  = p_member_id
     and ms.studio_id  = v_occ.studio_id
     and ms.status in ('active','trialing')
     and (ms.expires_on is null or ms.expires_on >= v_today)
     and (mp.booking_window_days is not null or mp.max_bookings_per_day is not null)
   order by case mp.type when 'recurring' then 1 when 'trial' then 2 else 3 end,
            ms.expires_on asc nulls last
   limit 1;

  v_max_per_day := coalesce(v_max_per_day, v_set.max_bookings_per_day);

  -- 2.1.2 Booking window.
  if not v_override then
    if v_occ.starts_at > now() + make_interval(days => v_window_days) then
      return (null, null, null, null, 'outside_booking_window')::book_class_result;
    end if;
  elsif v_occ.starts_at > now() + make_interval(days => v_window_days) then
    v_bypassed := v_bypassed || 'booking_window'::text;
  end if;

  -- 2.1.3 Booking cutoff. Default 0 — booking allowed right up to start.
  if not v_override then
    if v_occ.starts_at < now() + make_interval(mins => v_set.booking_cutoff_minutes) then
      return (null, null, null, null, 'past_booking_cutoff')::book_class_result;
    end if;
  elsif v_occ.starts_at < now() + make_interval(mins => v_set.booking_cutoff_minutes) then
    v_bypassed := v_bypassed || 'booking_cutoff'::text;
  end if;

  -- 2.1.3b Decision 30 belt: a self-serve LEAD owed a free first class must
  -- spend it on the free path (book_first_free), not a paid drop-in. Gated on
  -- status = 'lead' — Decision 15's self-signup with no plan; an active member
  -- (including one bringing a guest through book_guest, which books their own
  -- seat here) is never a lead and books normally. Fires only when they book
  -- themselves (not desk/override) and are still eligible, and before the waiver
  -- gate, so a fresh unsigned lead is routed to the free path (which gates the
  -- waiver at check-in) rather than told to sign. The switch off makes
  -- free_first_eligibility return ok=false, so nothing here fires.
  if v_is_self and not (v_is_desk or v_trusted or v_override)
     and v_member.status = 'lead'
     and (free_first_eligibility(v_occ.studio_id, v_member.id) ->> 'ok')::boolean then
    return (null, null, null, null, 'use_free_first')::book_class_result;
  end if;

  -- 2.1.4 Waiver. Not overridable. Decision 34: a signature is tied to a waiver
  -- version, and a NEW version marked requires_resign turns an older signature
  -- stale — a member who signed only an earlier required version is treated as
  -- unsigned. A studio with no version yet is unaffected (the current-version
  -- subquery finds nothing), so existing bare-timestamp signatures stand.
  if v_set.require_waiver then
    if v_member.waiver_signed_at is null then
      -- Part B: require_waiver is on but the studio has published NO version, so
      -- there is nothing to sign in the app. A distinct reason, so the member is
      -- pointed at the studio rather than told to "please sign" a screen with
      -- nothing on it. The desk paper path can still sign them.
      if not exists (select 1 from waiver_versions where studio_id = v_occ.studio_id) then
        return (null, null, null, null, 'waiver_unavailable')::book_class_result;
      end if;
      return (null, null, null, null, 'waiver_not_signed')::book_class_result;
    end if;
    if exists (
      select 1 from waiver_versions wv
       where wv.studio_id = v_occ.studio_id
         and wv.requires_resign
         and wv.created_at = (select max(created_at) from waiver_versions
                               where studio_id = v_occ.studio_id)
         and not exists (select 1 from waiver_signatures ws
                          where ws.member_id = v_member.id and ws.version_id = wv.id))
    then
      return (null, null, null, null, 'waiver_not_signed')::book_class_result;
    end if;
  end if;

  -- 2.1.5 Member status — Decision 15. A `lead` passes here, and is held to
  -- drop-in by the guard after §2.2 resolution below.
  if not book_class_status_ok(v_member.status) then
    return (null, null, null, null, 'member_not_active')::book_class_result;
  end if;

  -- 2.1.6 No existing live booking for this occurrence. Not overridable.
  -- Mirrors the bookings_one_live_per_member partial unique index.
  if exists (
    select 1 from bookings
     where occurrence_id = p_occurrence_id
       and member_id     = p_member_id
       and status in ('booked','waitlisted','attended','no_show','pending_payment')
  ) then
    -- 'pending_payment' is in this list, and deliberately NOT in the daily or
    -- forward limit counts below: a member may not start two checkouts for the
    -- same class, but three abandoned checkouts must not exhaust the limits on
    -- classes they never paid for.
    return (null, null, null, null, 'already_booked')::book_class_result;
  end if;

  -- 2.1.7 Daily limit, counted in studio-local days.
  if v_max_per_day is not null then
    select count(*) into v_day_count
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
     where b.member_id = p_member_id
       and b.studio_id = v_occ.studio_id
       and b.status in ('booked','waitlisted','attended','no_show')
       and (o.starts_at at time zone v_tz)::date
         = (v_occ.starts_at at time zone v_tz)::date;

    if v_day_count >= v_max_per_day then
      if v_override then
        v_bypassed := v_bypassed || 'daily_limit'::text;
      else
        return (null, null, null, null, 'daily_limit_reached')::book_class_result;
      end if;
    end if;
  end if;

  -- 2.1.8 Forward limit on live future bookings.
  if v_set.max_future_bookings is not null then
    select count(*) into v_future_count
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
     where b.member_id = p_member_id
       and b.studio_id = v_occ.studio_id
       and b.status in ('booked','waitlisted')
       and o.starts_at > now();

    if v_future_count >= v_set.max_future_bookings then
      if v_override then
        v_bypassed := v_bypassed || 'future_limit'::text;
      else
        return (null, null, null, null, 'future_limit_reached')::book_class_result;
      end if;
    end if;
  end if;

  -- ===========================================================================
  -- 3. Payment source resolution — Business Rules §2.2, Decision 1.
  --    unlimited membership -> limited membership allowance -> pack credits
  --    soonest expiry first -> drop-in. The member never chooses.
  --    Consumed at booking time, not at attendance (§2.2, §6).
  -- ===========================================================================

  if v_comp then
    -- §2.4: nothing consumed, nothing charged. The booking is an ordinary
    -- 'booked' row, so check-in, challenges and milestones count it exactly
    -- like any other attendance. Rule 2.1.9 is vacuous — no membership is
    -- paying, so no membership's class-type restriction applies.
    v_pay     := 'comp';
    v_consume := false;
  else
    for v_cand in
      select ms.id,
             ms.credits_remaining,
             mp.restrictions,
             case
               -- credits_per_period null on a recurring plan == unlimited
               -- (Data Model §7).
               when mp.type = 'recurring'
                    and mp.credits_per_period is null
                    and ms.credits_remaining is null              then 1
               when mp.type = 'recurring'
                    and coalesce(ms.credits_remaining, 0) > 0     then 2
               when mp.type in ('class_pack','drop_in','trial')
                    and coalesce(ms.credits_remaining, 0) > 0     then 3
               else 99
             end as priority
        from memberships ms
        join membership_plans mp on mp.id = ms.plan_id
       where ms.member_id = p_member_id
         and ms.studio_id = v_occ.studio_id
         -- §7.3 / Decision 4: past_due blocks NEW bookings only once the
         -- studio's grace period has run out.
         and (
               ms.status in ('active','trialing')
            or (ms.status = 'past_due'
                and now() < coalesce(ms.current_period_end, now())
                            + make_interval(days => v_set.payment_grace_days))
         )
         -- §7.4: a frozen membership cannot book.
         and not (ms.freeze_start is not null and ms.freeze_end is not null
                  and v_today between ms.freeze_start and ms.freeze_end)
         -- §6: a credit cannot be spent past its expiry.
         and (ms.expires_on is null or ms.expires_on >= v_today)
       order by priority,
                ms.expires_on asc nulls last,   -- soonest expiry first
                ms.created_at asc
    loop
      exit when v_cand.priority = 99;

      -- §2.1.9 plan restrictions: an empty or absent class_type_ids covers
      -- everything.
      v_covers := (v_cand.restrictions -> 'class_type_ids') is null
               or jsonb_typeof(v_cand.restrictions -> 'class_type_ids') <> 'array'
               or jsonb_array_length(v_cand.restrictions -> 'class_type_ids') = 0
               or (v_occ.class_type_id is not null
                   and jsonb_exists(v_cand.restrictions -> 'class_type_ids',
                                    v_occ.class_type_id::text));

      if not v_covers then
        v_restricted := true;   -- remembered for the §2.1.9 failure below
        continue;
      end if;

      v_pay        := case when v_cand.priority in (1, 2)
                           then 'membership'::payment_source
                           else 'class_pack'::payment_source end;
      v_membership := v_cand.id;
      v_consume    := v_cand.priority in (2, 3);
      exit;
    end loop;

    if v_pay is null then
      -- §2.1.9: the member holds a live plan and it does not cover this class
      -- type. That is a specific refusal, not a silent fall-through to drop-in.
      if v_restricted then
        if v_override then
          v_bypassed := v_bypassed || 'plan_restriction'::text;
        else
          return (null, null, null, null, 'class_type_not_in_plan')::book_class_result;
        end if;
      end if;
      -- §2.2 priority 4: nothing covers it, so the class is a drop-in. The
      -- charge itself is a payments row raised by the caller against the
      -- returned booking; no credit is consumed here.
      v_pay := 'drop_in';
    end if;
  end if;

  -- The seat is held while the member pays for it.
  --
  -- Only when the MEMBER is booking their own drop-in and the studio has a
  -- connected Stripe account. A staff booking at the desk is money changing
  -- hands in the room, and a studio with no Stripe connected has no checkout to
  -- send anyone to — both of those still book outright, exactly as before, which
  -- is also why every existing fixture in the suite is unaffected.
  if v_pay = 'drop_in' and p_source = 'member'
     and exists (
       select 1 from studios s
        where s.id = v_occ.studio_id and s.stripe_account_id is not null
     )
  then
    v_status := 'pending_payment';
  end if;

  -- Decision 15's second half, after §2.2 has resolved who pays. A lead has
  -- bought nothing, so it should always be drop-in by this point; if it is
  -- not, staff have attached a plan to somebody they never activated, and
  -- spending its credits is not what `lead` is meant to allow.
  if v_member.status = 'lead' and v_pay <> 'drop_in' then
    return (null, null, null, null, 'member_not_active')::book_class_result;
  end if;

  -- ===========================================================================
  -- 2.1.9 SUSPENSION — Decision 24.
  --
  -- In the §2.1 gate and not beside the peak rule, because it has nothing to do
  -- with which plan pays: a suspended member is suspended whatever they were
  -- going to book it with, including a drop-in they would have paid cash for.
  --
  -- IT RESTRICTS ADVANCE BOOKING ONLY. Same-day still works, on whatever seats
  -- are left — the penalty is losing the ability to hold a place ahead of
  -- everyone else, not being shut out of the studio. A suspension that stopped
  -- somebody walking in would cost the studio the sale as well as the member the
  -- class, and it would be a harsher thing than any studio described wanting.
  --
  -- The allowance still applies on top: a suspension does not hand out free peak
  -- slots, and a member with nothing left is refused by the rule below whether
  -- or not they are suspended.
  --
  -- Overridable, like the other capacity-shaped rules. A studio that wants to
  -- let somebody in anyway has heard the reason at the counter.
  -- ===========================================================================
  v_susp := member_suspension(p_member_id);
  if v_susp is not null and (v_susp ->> 'suspended')::boolean
     and (v_occ.starts_at at time zone v_tz)::date > v_today
  then
    if v_override then
      v_bypassed := v_bypassed || 'suspended'::text;
    else
      return (null, null, null, null, 'suspended')::book_class_result;
    end if;
  end if;

  -- ===========================================================================
  -- 3b. THE PEAK ALLOWANCE — Decision 24.
  --
  -- AFTER §2.2, and that placement is the whole correctness argument: the plan
  -- that PAYS is the plan held to its allowance. Resolving it up in the §2.1
  -- gate would mean a second plan-priority query beside the one rules 2 and 7
  -- use, and the two would pick the same plan right up until they did not —
  -- a member holding both an unlimited plan and a pack would have the pack's
  -- booking measured against the unlimited plan's allowance.
  --
  -- Only a membership can consume one. A drop-in and a pack cannot carry an
  -- allowance at all (migration 104's CHECK), so `v_pay = 'membership'` is not
  -- an optimisation, it is the rule.
  --
  -- peak_allowance_state() answers null for a plan with no allowance AND for a
  -- studio with the switch off, so a studio that has never heard of this
  -- feature takes one null check and nothing else.
  --
  -- WAITLISTING NEEDS NO SPECIAL CASE. This refuses before §4, so a member with
  -- nothing left cannot join the queue for a peak class either — which is the
  -- honest answer, rather than letting them wait for an offer they could not
  -- accept. And nothing is CONSUMED here: the ledger row is written by the
  -- trigger when a seat actually becomes real, so a waitlisted row costs
  -- nothing and a promotion costs one. `respond_to_offer()` cancels the
  -- waitlist row and calls this function again, so a promotion is measured
  -- against the allowance as it stands at that moment, not at join time.
  -- ===========================================================================
  if v_pay = 'membership' and v_membership is not null
     and occurrence_is_peak(p_occurrence_id)
  then
    v_peak := peak_allowance_state(v_membership,
                                   (v_occ.starts_at at time zone v_tz)::date);
    if v_peak is not null and (v_peak ->> 'remaining')::int <= 0 then
      if v_override then
        v_bypassed := v_bypassed || 'peak_allowance'::text;
      else
        return (null, null, null, null, 'peak_allowance_exhausted')::book_class_result;
      end if;
    end if;
  end if;

  -- ===========================================================================
  -- 4. Capacity — §2.1.10, §4.1, §5. booked_count was read under the lock.
  -- ===========================================================================

  -- §4.2: a pending waitlist offer HOLDS its seat — the offered member was
  -- formally offered it, and general booking must not take it from under them.
  -- Derived from live offers at gate time rather than cached: booked_count goes
  -- on counting real seats only, so the nightly reconcile stays a no-op, and the
  -- hold ends the instant the offer does (expired-but-unswept offers hold
  -- nothing — occurrence_seats_held gates on expires_at > now()). The offered
  -- member's own offer is excluded, or accepting through respond_to_offer would
  -- be refused for the very seat they were offered.
  v_held      := occurrence_seats_held(p_occurrence_id, p_member_id);
  v_phys_full := v_occ.booked_count >= v_occ.capacity;
  v_full      := (v_occ.booked_count + v_held) >= v_occ.capacity;

  if v_full and not v_override then
    if not v_set.waitlist_enabled then
      return (null, null, null, null, 'class_full')::book_class_result;
    end if;

    -- §4.4: no promotions inside waitlist_cutoff_minutes, so joining there is
    -- an offer that can never be made.
    if v_occ.starts_at < now() + make_interval(mins => v_set.waitlist_cutoff_minutes) then
      return (null, null, null, null, 'waitlist_closed')::book_class_result;
    end if;

    -- §4.1: strictly FIFO, no priority tiers in V1, and NO credit consumed on
    -- joining. The paying source is re-resolved when the offer is accepted
    -- (§4.2.4), so it is deliberately left null on the row — including for a
    -- comp, whose comp intent must be supplied again at promotion.
    select coalesce(max(waitlist_position), 0) + 1
      into v_position
      from bookings
     where occurrence_id = p_occurrence_id
       and status = 'waitlisted';

    insert into bookings (
      studio_id, occurrence_id, member_id, status, source,
      payment_source, membership_id, waitlist_position
    ) values (
      v_occ.studio_id, p_occurrence_id, p_member_id, 'waitlisted', p_source,
      null, null, v_position
    ) returning id into v_booking_id;

    update class_occurrences
       set waitlist_count = waitlist_count + 1
     where id = p_occurrence_id;

    return (v_booking_id, 'waitlisted'::booking_status, null, v_position, null)
           ::book_class_result;
  end if;

  if v_full then
    -- §2.3 / §5 / §14: a staff override reaches here. Two shapes, told apart for
    -- the audit: physically full is a walk-in booked OVER capacity; held-only is
    -- the desk deliberately taking a seat reserved for a waitlisted member (the
    -- offer stands and will fail on acceptance — a deliberate act, §14). The hold
    -- is never applied to an override, so front desk can always seat someone.
    if v_phys_full then
      v_bypassed := v_bypassed || 'capacity'::text;
    else
      v_bypassed := v_bypassed || 'held_seat'::text;
    end if;
  end if;

  -- ===========================================================================
  -- 5. Write. Booking, ledger and booked_count, one transaction.
  -- ===========================================================================

  insert into bookings (
    studio_id, occurrence_id, member_id, status, source,
    payment_source, membership_id, override_reason, overridden_rules
  ) values (
    v_occ.studio_id, p_occurrence_id, p_member_id, v_status, p_source,
    v_pay, case when v_pay in ('membership','class_pack') then v_membership end,
    -- §2.3: a reason that bypassed nothing was not an override, so it is not
    -- recorded as one.
    case when array_length(v_bypassed, 1) is not null then p_override_reason end,
    case when array_length(v_bypassed, 1) is not null then v_bypassed end
  ) returning id into v_booking_id;

  if v_consume then
    -- §6: the balance is derived from the ledger, never edited in place, and
    -- every row carries balance_after so any point in history is
    -- reconstructable without replaying. balance_after is the member's total
    -- credit balance across every source; the member row lock above makes the
    -- read-then-write safe.
    select coalesce(sum(delta), 0) into v_balance
      from credit_ledger
     where studio_id = v_occ.studio_id
       and member_id = p_member_id;

    insert into credit_ledger (
      studio_id, member_id, membership_id, delta, reason,
      booking_id, balance_after, expires_at, actor_user_id
    )
    select v_occ.studio_id, p_member_id, v_membership, -1, 'booking',
           v_booking_id, v_balance - 1,
           case when ms.expires_on is not null
                then (ms.expires_on + 1)::timestamp at time zone v_tz end,
           v_actor
      from memberships ms
     where ms.id = v_membership
    returning id into v_ledger_id;

    -- credits_remaining is a cache. Written in the same transaction as the
    -- ledger row, never independently of it.
    update memberships
       set credits_remaining = credits_remaining - 1
     where id = v_membership;

    update bookings set credit_entry_id = v_ledger_id where id = v_booking_id;
  end if;

  update class_occurrences
     set booked_count = booked_count + 1
   where id = p_occurrence_id;

  -- §2.3 / §13: every override that actually bypassed a rule is audited with
  -- actor and reason. The booking row carries the same reason (above) so it is
  -- visible without a join to audit_logs.
  if v_override and array_length(v_bypassed, 1) is not null then
    insert into audit_logs (
      studio_id, actor_user_id, action, entity_table, entity_id, after
    ) values (
      v_occ.studio_id, v_actor, 'booking.override', 'bookings', v_booking_id,
      jsonb_build_object(
        'reason',        p_override_reason,
        'rules_bypassed', to_jsonb(v_bypassed),
        'occurrence_id', p_occurrence_id,
        'member_id',     p_member_id,
        'over_capacity', v_occ.booked_count + 1 > v_occ.capacity
      )
    );
  end if;

  -- Decision 30 amendment: a seat that counts toward the headcount may have just
  -- completed a free class's confirm-at total, confirming its provisional free
  -- seats at once. A no-op when the class has none or is still short.
  if v_status in ('booked', 'pending_payment') then
    perform confirm_provisional_seats_run(p_occurrence_id);
  end if;

  -- The caller needs to know it is holding rather than booked, because that is
  -- what decides whether the member is sent to Checkout next.
  return (v_booking_id, v_status, v_pay, null, null)
         ::book_class_result;
end $function$

;

-- ---- book_guest ----
CREATE OR REPLACE FUNCTION public.book_guest(p_occurrence_id uuid, p_guest_email text, p_guest_first text, p_guest_last text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_occ    class_occurrences%rowtype;
  v_host   members%rowtype;
  v_studio studios%rowtype;
  v_actor  uuid := auth.uid();
  v_email  text := lower(btrim(p_guest_email));
  v_elig   jsonb;
  v_host_booking  uuid;
  v_guest         uuid;
  v_guest_booking uuid;
  v_need   int;
  v_free   int;
  v_res    book_class_result;
  v_token  text;
  v_pass   uuid;
  v_url    text;
begin
  select * into v_occ from class_occurrences where id = p_occurrence_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;

  -- The host is the caller's own member row in this studio (member-driven, §26).
  select * into v_host from members
   where studio_id = v_occ.studio_id and user_id = v_actor;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_authorised'); end if;

  -- Decision 48: an unstaffed hidden class is closed to NEW bookings — a guest
  -- is one, so a member cannot bring a guest into a class nobody is teaching.
  if studio_hides_unstaffed(v_occ.studio_id) and v_occ.staffing <> 'assigned' then
    return jsonb_build_object('ok', false, 'reason', 'not_staffed_yet');
  end if;

  -- Eligibility (enabled, email, one-at-a-time, free-once). No writes yet.
  v_elig := guest_pass_eligibility(v_occ.studio_id, v_host.id, p_guest_email);
  if not (v_elig ->> 'ok')::boolean then return v_elig; end if;

  -- Capacity, under the lock. A guest never takes a seat the host didn't also
  -- take: if the host is not already booked we need TWO seats, else one. Held
  -- waitlist seats (§4.2) are not available to a guest either.
  select id into v_host_booking from bookings
   where occurrence_id = p_occurrence_id and member_id = v_host.id
     and status in ('booked','attended','no_show','pending_payment');
  v_need := case when v_host_booking is null then 2 else 1 end;
  v_free := v_occ.capacity - occurrence_seats_taken(p_occurrence_id)
                           - occurrence_seats_held(p_occurrence_id);
  if v_free < v_need then
    if v_free = 1 and v_need = 2 then
      return jsonb_build_object('ok', false, 'reason', 'only_one_seat');
    end if;
    return jsonb_build_object('ok', false, 'reason', 'class_full');
  end if;

  -- Book the host their own seat if they have none, through the ordinary gate
  -- (their payment, their peak allowance, their eligibility). Must be a real
  -- confirmed seat — a waitlisted or unpaid host is not "in".
  if v_host_booking is null then
    v_res := book_class(p_occurrence_id, v_host.id, 'member');
    if v_res.failure_reason is not null then
      return jsonb_build_object('ok', false, 'reason', 'host_' || v_res.failure_reason);
    end if;
    if v_res.status <> 'booked' then
      return jsonb_build_object('ok', false, 'reason', 'host_not_booked');
    end if;
    v_host_booking := v_res.booking_id;
  end if;

  -- The guest is a real member, status 'lead' (Decision 15). Email pre-checked
  -- unique, so the insert is safe against members_email.
  insert into members (studio_id, first_name, last_name, email, status, source)
  values (v_occ.studio_id,
          coalesce(nullif(btrim(p_guest_first), ''), 'Guest'),
          coalesce(nullif(btrim(p_guest_last), ''), '—'),
          btrim(p_guest_email), 'lead', 'guest_pass')
  returning id into v_guest;

  -- The free, separate seat: comp, no credit, no membership, no peak. Counts on
  -- the roster like any booking, so booked_count moves with it.
  insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source)
  values (v_occ.studio_id, p_occurrence_id, v_guest, 'booked', 'member', 'comp')
  returning id into v_guest_booking;
  update class_occurrences set booked_count = booked_count + 1 where id = p_occurrence_id;

  insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email,
                            occurrence_id, host_booking_id, guest_booking_id, status)
  values (v_occ.studio_id, v_host.id, v_guest, v_email, p_occurrence_id,
          v_host_booking, v_guest_booking, 'invited')
  returning id into v_pass;

  -- Mint the claim+waiver invite inline: create_member_invite/invite_member both
  -- guard is_desk_up, and the host is a member, so this replicates the minter
  -- here (this function is SECURITY DEFINER). Same hashed, single-use, 14-day token.
  select * into v_studio from studios where id = v_occ.studio_id;
  v_token := encode(gen_random_bytes(24), 'hex');
  insert into member_invites (studio_id, member_id, email, token_hash, expires_at, created_by)
  values (v_occ.studio_id, v_guest, btrim(p_guest_email),
          encode(digest(v_token, 'sha256'), 'hex'), now() + interval '14 days', v_actor);
  v_url := 'https://' || v_studio.slug || '.'
           || coalesce(notification_setting('member_app_domain'), 'studiior.app')
           || '/claim/' || v_token;
  perform queue_notification(v_occ.studio_id, v_guest, 'guest_invite',
    jsonb_build_object('claim_url', v_url, 'host_name', v_host.first_name,
                       'class_name', v_occ.name),
    'guest_invite:' || v_pass);

  -- Decision 30 amendment: the host (and guest) seats may complete a free class's
  -- confirm-at total. A no-op when the class has no provisional free seats.
  perform confirm_provisional_seats_run(p_occurrence_id);

  return jsonb_build_object('ok', true, 'guest_pass_id', v_pass,
    'guest_member_id', v_guest, 'guest_booking_id', v_guest_booking,
    'host_booking_id', v_host_booking, 'seats_taken', v_need);
end $function$

;

-- ---- queue_booking_notifications ----
CREATE OR REPLACE FUNCTION public.queue_booking_notifications(p_booking_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  b bookings%rowtype; o class_occurrences%rowtype; m members%rowtype;
  st studio_settings%rowtype; s studios%rowtype;
  v_when text; v_where text; n int := 0; v_remind timestamptz;
  v_manage text;
  v_is_free boolean; v_ff_txt text; v_ff_html text;
  v_deadline timestamptz;  -- Decision 21 amendment
  v_cutoff timestamptz;    -- Decision 30 amendment
begin
  select * into b from bookings where id = p_booking_id;
  if not found or b.status <> 'booked' then return 0; end if;

  select * into o  from class_occurrences where id = b.occurrence_id;
  select * into m  from members            where id = b.member_id;
  select * into s  from studios            where id = b.studio_id;
  select * into st from studio_settings    where studio_id = b.studio_id;

  v_when  := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY, HH24:MI');
  v_where := coalesce((select ', in ' || r.name from rooms r where r.id = o.room_id), '');
  v_manage := 'https://' || s.slug || '.'
              || coalesce(notification_setting('member_app_domain'), 'studiior.app')
              || '/class/' || o.id;

  v_is_free := b.payment_source = 'comp'
    and exists (select 1 from guest_passes gp
                 where gp.guest_booking_id = b.id and gp.host_member_id is null);
  v_ff_txt  := case when v_is_free then E'\n\nThis one''s on us — your first class is free.' else '' end;
  v_ff_html := case when v_is_free then '<p>This one''s on us — your first class is free.</p>' else '' end;

  -- Decision 21 amendment: a flex class not yet decided sends the "waiting for
  -- confirmation" receipt instead of booking_confirmed — same dedupe key.
  select deadline_at into v_deadline from flex_deadline_for_run(o.id);

  -- Decision 30 amendment: a PROVISIONAL free seat sends the free "waiting for
  -- confirmation" receipt — checked first, because a free seat on a flex class
  -- is still a free seat. Same dedupe key, so tg_cancel_booking_notifications
  -- withdraws it if the seat is later released. Keyed on the booking's OWN
  -- provisional flag (not the guest_passes row): this trigger fires on INSERT,
  -- before book_first_free writes the guest_pass, so v_is_free is not yet true —
  -- but provisional is set at insert, and only a free-first seat is ever
  -- provisional (guest and paid seats never are).
  if b.payment_source = 'comp' and b.provisional then
    select cutoff_at into v_cutoff from occurrence_guarantee_run(o.id);
    if queue_notification(b.studio_id, b.member_id, 'free_booking_pending',
          jsonb_build_object('class_name', o.name, 'when', v_when,
            'cutoff_long', to_char(v_cutoff at time zone s.timezone,
                                   'HH24:MI "on" FMDay FMDD FMMonth YYYY'),
            'booking_id', b.id, 'occurrence_id', o.id),
          'booking_confirmed:' || b.id) is not null then n := n + 1; end if;
  elsif v_deadline is not null then
    if queue_notification(b.studio_id, b.member_id, 'flex_booking_pending',
          jsonb_build_object('class_name', o.name, 'when', v_when,
            'deadline_long', to_char(v_deadline at time zone s.timezone,
                                     'HH24:MI "on" FMDay FMDD FMMonth YYYY'),
            'booking_id', b.id, 'occurrence_id', o.id),
          'booking_confirmed:' || b.id) is not null then n := n + 1; end if;
  else
    if queue_notification(b.studio_id, b.member_id, 'booking_confirmed',
          jsonb_build_object('class_name', o.name, 'when', v_when, 'where_line', v_where,
                             'manage_link', v_manage,
                             'free_first_line', v_ff_txt, 'free_first_html', v_ff_html,
                             'booking_id', b.id, 'occurrence_id', o.id),
          'booking_confirmed:' || b.id) is not null then n := n + 1; end if;
  end if;

  v_remind := o.starts_at - make_interval(hours => coalesce(st.reminder_hours_before, 12));
  if v_remind > now() then
    if queue_notification(b.studio_id, b.member_id, 'class_reminder',
          jsonb_build_object('class_name', o.name,
                             'when_short', 'tomorrow',
                             'when_time', to_char(o.starts_at at time zone s.timezone, 'HH24:MI'),
                             'where_line', v_where),
          'class_reminder:' || b.id, v_remind) is not null then n := n + 1; end if;
  end if;

  return n;
end $function$

;

-- ---- member_pending_bookings ----
CREATE OR REPLACE FUNCTION public.member_pending_bookings(p_studio_id uuid)
 RETURNS TABLE(occurrence_id uuid, pending_until timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_member uuid;
begin
  select id into v_member from members where user_id = auth.uid() and studio_id = p_studio_id;
  if v_member is null then
    raise exception 'not a member of that studio' using errcode = 'PT403';
  end if;
  return query
  select o.id, d.deadline_at
    from bookings b
    join class_occurrences o on o.id = b.occurrence_id
    cross join lateral flex_deadline_for_run(o.id) d
   where b.member_id = v_member
     and b.status in ('booked', 'pending_payment')
     and coalesce(o.flex, false) and o.committed_at is null and o.status = 'scheduled'
     and d.deadline_at is not null
  -- Decision 30 amendment: a provisional free seat is pending too, with NO time
  -- shown (pending_until null) — it confirms the moment the class is on, which
  -- may be any moment, so a deadline would mislead. Presence in this set is the
  -- "Waiting for confirmation" state; the client shows a time only when one is
  -- returned (the flex case above).
  union all
  select b.occurrence_id, null::timestamptz
    from bookings b
    join class_occurrences o on o.id = b.occurrence_id
   where b.member_id = v_member
     and b.status = 'booked' and b.provisional
     and o.status = 'scheduled';
end $function$

;

-- ---- evaluate_commitment ----
CREATE OR REPLACE FUNCTION public.evaluate_commitment(p_occurrence_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o class_occurrences%rowtype; g record; v_booked int; s studios%rowtype; r record;
begin
  select * into o from class_occurrences where id = p_occurrence_id for update;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(o.studio_id), false) and not is_service_context() then
    raise exception 'only owners, managers and the sweep decide a class' using errcode = 'PT403';
  end if;

  if o.committed_at is not null then
    return jsonb_build_object('ok', true, 'already', 'committed',
                              'booked_at_cutoff', o.booked_at_cutoff);
  end if;
  if o.status <> 'scheduled' then
    return jsonb_build_object('ok', true, 'already', o.status::text,
                              'cause', o.cancellation_cause);
  end if;

  select * into g from occurrence_guarantee_run(p_occurrence_id);
  if g.cutoff_at is null then
    return jsonb_build_object('ok', true, 'skipped', 'guarantees are off for this class');
  end if;
  if now() < g.cutoff_at then
    return jsonb_build_object('ok', true, 'skipped', 'not due', 'due_at', g.cutoff_at);
  end if;

  -- Decision 30 amendment: we are AT the class's cutoff. A free seat that never
  -- reached its confirm-at total is released NOW, before the headcount is
  -- counted — the member keeps their free class and is told, and the class is
  -- evaluated on who actually remains (so a core 1-paid + 1-released-trial runs,
  -- and a flex min-2 with 1 paid + 1 released trial does not).
  perform release_provisional_seats_run(p_occurrence_id);

  select count(*)::int into v_booked from bookings
   where occurrence_id = p_occurrence_id
     and status in ('booked','attended','no_show','pending_payment');

  if v_booked >= g.minimum
     or (o.flex and o.flex_reached_minimum_at is not null) then
    update class_occurrences
       set committed_at = now(), booked_at_cutoff = v_booked, updated_at = now()
     where id = p_occurrence_id;

    -- Decision 21 amendment: a member who booked a FLEX class was shown "waiting
    -- for confirmation" — tell them it is confirmed. Only flex; a core class was
    -- never pending to a member. Dedupe per member per occurrence.
    if g.tier = 'flex' then
      select * into s from studios where id = o.studio_id;
      for r in select member_id from bookings
                where occurrence_id = p_occurrence_id
                  and status in ('booked','attended','no_show','pending_payment')
      loop
        perform queue_notification(o.studio_id, r.member_id, 'flex_booking_confirmed',
          jsonb_build_object('class_name', o.name,
            'day',  to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth'),
            'time', to_char(o.starts_at at time zone s.timezone, 'HH24:MI'),
            'occurrence_id', p_occurrence_id),
          'flex_member_confirmed:' || p_occurrence_id || ':' || r.member_id);
      end loop;
    end if;

    return jsonb_build_object('ok', true, 'decision', 'committed',
      'tier', g.tier, 'booked_at_cutoff', v_booked, 'minimum', g.minimum,
      'latched', (v_booked < g.minimum));
  end if;

  update class_occurrences set booked_at_cutoff = v_booked where id = p_occurrence_id;
  perform cancel_occurrence(p_occurrence_id,
            'Did not reach its minimum by the cutoff', 'unmet_minimum');

  return jsonb_build_object('ok', true, 'decision', 'not_running',
    'tier', g.tier, 'booked_at_cutoff', v_booked, 'minimum', g.minimum);
end $function$

;

-- ---- cancel_occurrence ----
CREATE OR REPLACE FUNCTION public.cancel_occurrence(p_occurrence_id uuid, p_reason text DEFAULT NULL::text, p_cause cancellation_cause DEFAULT 'studio_fault'::cancellation_cause)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  occ class_occurrences%rowtype;
  r record;
  n_notified int := 0; n_cancelled int := 0; n_credited int := 0;
  v_res record;
begin
  select * into occ from class_occurrences where id = p_occurrence_id for update;
  if not found then
    raise exception 'no such class' using errcode = 'PT404';
  end if;
  if not coalesce(is_manager_up(occ.studio_id), false) and not is_service_context() then
    raise exception 'only owners and managers cancel a class' using errcode = 'PT403';
  end if;
  if occ.status = 'cancelled' then
    return jsonb_build_object('ok', true, 'already_cancelled', true,
                              'notified', 0, 'bookings_cancelled', 0);
  end if;

  -- Decision 30 amendment: release any still-provisional free seats FIRST, so
  -- those members get the "booking not confirmed" treatment and keep their free
  -- class, rather than the ordinary class_cancelled. They are cancelled by the
  -- time queue_occurrence_cancelled and the booking loop below run, so neither
  -- touches them again.
  perform release_provisional_seats_run(p_occurrence_id);

  perform set_config('studiior.releasing', '1', true);

  n_notified := coalesce(queue_occurrence_cancelled(p_occurrence_id, p_cause), 0);

  update class_occurrences
     set status = 'cancelled', updated_at = now(),
         cancelled_at = coalesce(cancelled_at, now()),
         cancellation_reason = coalesce(p_reason, cancellation_reason),
         cancellation_cause = p_cause
   where id = p_occurrence_id;

  update bookings set free_cancel_until = now() + interval '1 hour'
   where occurrence_id = p_occurrence_id
     and status in ('booked', 'waitlisted', 'pending_payment');

  for r in
    select id from bookings
     where occurrence_id = p_occurrence_id
       and status in ('booked', 'waitlisted', 'pending_payment')
     order by (status = 'waitlisted') desc, booked_at
  loop
    select * into v_res from cancel_booking(r.id);
    n_cancelled := n_cancelled + 1;
    if coalesce(v_res.credit_returned, false) then n_credited := n_credited + 1; end if;
  end loop;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (occ.studio_id, auth.uid(), 'occurrence.cancelled', 'class_occurrences',
          p_occurrence_id, jsonb_build_object('reason', p_reason, 'cause', p_cause,
                                              'notified', n_notified,
                                              'bookings_cancelled', n_cancelled));

  perform set_config('studiior.releasing', '', true);

  return jsonb_build_object('ok', true, 'cause', p_cause, 'notified', n_notified,
                            'bookings_cancelled', n_cancelled,
                            'credits_returned', n_credited);
end $function$

;

-- ---- bulk_update_series_run ----
CREATE OR REPLACE FUNCTION public.bulk_update_series_run(p_series_ids uuid[], p_change jsonb, p_preview boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_studio uuid; v_type text; v_have int; v_cnt int;
  rec record; ser class_series%rowtype;
  v_res jsonb; v_bad boolean; v_reason text;
  v_cur text; v_new text; v_when text; v_day text;
  v_changed jsonb := '[]'::jsonb;
  v_refused jsonb := '[]'::jsonb;
  v_warn    jsonb := '[]'::jsonb;
  v_n_changed int := 0; v_n_refused int := 0;
  r_name text;
begin
  if p_series_ids is null or array_length(p_series_ids, 1) is null then
    raise exception 'select at least one series' using errcode = 'PT422';
  end if;

  -- One studio, every id present, and the caller manages it. A foreign or
  -- unknown id anywhere -> PT403 (never act on a partial, mixed-studio set).
  select count(distinct studio_id), (array_agg(distinct studio_id))[1] into v_cnt, v_studio
    from class_series where id = any(p_series_ids);
  if v_cnt <> 1 then
    raise exception 'those series are not all in one studio you manage' using errcode = 'PT403';
  end if;
  if not coalesce(is_manager_up(v_studio), false) then
    raise exception 'only owners and managers change the timetable' using errcode = 'PT403';
  end if;
  select count(*) into v_have from class_series
   where studio_id = v_studio and id = any(p_series_ids);
  if v_have <> (select count(distinct x) from unnest(p_series_ids) x) then
    raise exception 'those series are not all in one studio you manage' using errcode = 'PT403';
  end if;

  -- Which single change family.
  v_type := case
    when p_change ? 'tier'          then 'tier'
    when p_change ? 'room_id'       then 'room'
    when p_change ? 'ends_on'       then 'ends_on'
    when p_change ? 'starts_on'     then 'starts_on'
    when p_change ? 'instructor_id' then 'instructor'
    when p_change ? 'free_first_allowed' then 'free_first'
    when p_change ? 'minimum'       then 'minimum'
    else null end;
  if v_type is null then
    raise exception 'that is not a change this can apply' using errcode = 'PT422';
  end if;

  for rec in
    select cs.id from class_series cs
     where cs.id = any(p_series_ids)
     order by cs.name, cs.time_of_day
  loop
    select * into ser from class_series where id = rec.id;
    r_name := ser.name;

    -- "Mon 07:00": the first BYDAY of the rule plus the time. Built in SQL so the
    -- refusal sentence the UI renders carries the database's own label.
    v_day := substring(ser.rrule from 'BYDAY=([A-Z]{2})');
    v_when := trim(coalesce(
      case v_day when 'MO' then 'Mon' when 'TU' then 'Tue' when 'WE' then 'Wed'
                 when 'TH' then 'Thu' when 'FR' then 'Fri' when 'SA' then 'Sat'
                 when 'SU' then 'Sun' else '' end, '')
      || ' ' || to_char(ser.time_of_day, 'HH24:MI'));

    -- current -> new, for the preview table.
    if v_type = 'minimum' then
      v_cur := 'min ' || coalesce((case ser.guarantee_tier
                 when 'flex' then ser.minimum_bookings
                 when 'core' then ser.core_min_bookings else null end)::text, '—');
      v_new := 'min ' || (p_change ->> 'minimum');
    elsif v_type = 'tier' then
      v_cur := ser.guarantee_tier::text;
      v_new := (p_change ->> 'tier')
               || case when nullif(p_change ->> 'minimum','') is not null
                       then ' · min ' || (p_change ->> 'minimum') else '' end;
    elsif v_type = 'room' then
      v_cur := coalesce((select name from rooms where id = ser.room_id), 'no room');
      v_new := coalesce((select name from rooms where id = (p_change ->> 'room_id')::uuid), 'no room');
    elsif v_type = 'ends_on' then
      v_cur := coalesce(ser.ends_on::text, 'no end');
      v_new := coalesce(nullif(p_change ->> 'ends_on','')::date::text, 'no end');
    elsif v_type = 'starts_on' then
      v_cur := ser.starts_on::text;
      v_new := (p_change ->> 'starts_on');
    elsif v_type = 'free_first' then
      v_cur := case when ser.free_first_allowed then 'free classes on' else 'free classes off' end;
      v_new := case when (p_change ->> 'free_first_allowed')::boolean then 'free classes on' else 'free classes off' end;
    else  -- instructor
      v_cur := coalesce((select display_name from instructors where id = ser.instructor_id), 'Unassigned');
      v_new := coalesce((select display_name from instructors where id = nullif(p_change ->> 'instructor_id','')::uuid), 'Unassigned');
    end if;

    v_res := null;
    begin   -- SAVEPOINT per series
      if v_type = 'minimum' then
        v_res := set_series_guarantee(rec.id, ser.guarantee_tier, (p_change ->> 'minimum')::int, null);
      elsif v_type = 'tier' then
        v_res := set_series_guarantee(rec.id, (p_change ->> 'tier')::guarantee_tier,
                                      nullif(p_change ->> 'minimum','')::int, null);
      elsif v_type = 'room' then
        v_res := update_series(rec.id, ser.name, ser.class_type_id, (p_change ->> 'room_id')::uuid,
                   ser.instructor_id, ser.capacity, ser.duration_minutes, ser.rrule,
                   ser.starts_on, ser.ends_on, ser.time_of_day, ser.description, null, true);
      elsif v_type = 'ends_on' then
        v_res := update_series(rec.id, ser.name, ser.class_type_id, ser.room_id,
                   ser.instructor_id, ser.capacity, ser.duration_minutes, ser.rrule,
                   ser.starts_on, nullif(p_change ->> 'ends_on','')::date, ser.time_of_day,
                   ser.description, null, true);
      elsif v_type = 'starts_on' then
        v_res := update_series(rec.id, ser.name, ser.class_type_id, ser.room_id,
                   ser.instructor_id, ser.capacity, ser.duration_minutes, ser.rrule,
                   (p_change ->> 'starts_on')::date, ser.ends_on, ser.time_of_day,
                   ser.description, null, true);
      elsif v_type = 'free_first' then
        -- Decision 30 amendment: free_first_allowed is NOT a materialise-trigger
        -- column, so a direct template write touches no occurrence and fires no
        -- trigger — no series_editing flag needed.
        update class_series set free_first_allowed = (p_change ->> 'free_first_allowed')::boolean,
               updated_at = now() where id = rec.id;
        v_res := jsonb_build_object('ok', true);
      else  -- instructor: template only, zero occurrences touched (42a/43).
        -- instructor_id is a materialise-trigger column, so suppress the trigger
        -- (series_editing) — the write must touch no occurrence, not generate.
        perform set_config('studiior.series_editing', 'on', true);
        update class_series set instructor_id = nullif(p_change ->> 'instructor_id','')::uuid,
               updated_at = now() where id = rec.id;
        perform set_config('studiior.series_editing', 'off', true);
        v_res := jsonb_build_object('ok', true);
      end if;

      -- Refused: the function said no, or (a room change) left a per-occurrence
      -- clash — all-or-nothing per series in a batch, so the whole series rolls
      -- back and is listed.
      v_bad := (not coalesce((v_res ->> 'ok')::boolean, true))
            or (jsonb_array_length(coalesce(v_res -> 'conflicts', '[]'::jsonb)) > 0);

      if p_preview or v_bad then
        raise exception 'discard' using errcode = 'PT000';
      end if;

      -- Apply, kept.
      v_changed := v_changed || jsonb_build_object('series_id', rec.id, 'name', r_name,
                     'when', v_when, 'current', v_cur, 'new', v_new);
      v_n_changed := v_n_changed + 1;
      if coalesce((v_res ->> 'standalone_count')::int, 0) > 0 then
        v_warn := v_warn || jsonb_build_object('series_id', rec.id, 'code', 'standalone_flex');
      end if;

    exception
      when sqlstate 'PT000' then
        -- Our own forced rollback. v_res holds what the function returned.
        if (not coalesce((v_res ->> 'ok')::boolean, true))
           or (jsonb_array_length(coalesce(v_res -> 'conflicts', '[]'::jsonb)) > 0) then
          v_reason := case
            when jsonb_array_length(coalesce(v_res -> 'conflicts', '[]'::jsonb)) > 0
                 then 'the room is taken on some of its classes'
            when (v_res ->> 'reason') = 'members_booked_on_dropped_classes' and v_type = 'starts_on'
                 then 'earlier classes have bookings'
            when (v_res ->> 'reason') = 'members_booked_on_dropped_classes'
                 then 'later classes have bookings'
            else coalesce(v_res ->> 'reason', 'refused') end;
          v_refused := v_refused || jsonb_build_object('series_id', rec.id, 'name', r_name,
                         'when', v_when, 'reason', v_reason);
          v_n_refused := v_n_refused + 1;
        else
          -- Preview: this one WOULD change (nothing kept).
          v_changed := v_changed || jsonb_build_object('series_id', rec.id, 'name', r_name,
                         'when', v_when, 'current', v_cur, 'new', v_new);
          v_n_changed := v_n_changed + 1;
          if coalesce((v_res ->> 'standalone_count')::int, 0) > 0 then
            v_warn := v_warn || jsonb_build_object('series_id', rec.id, 'code', 'standalone_flex');
          end if;
        end if;
      when others then
        -- The single-series function itself raised (bad input, locked studio …).
        v_reason := case
          when sqlstate = 'PT402' then 'this studio''s subscription is not active'
          when sqlstate = 'PT422' then 'that change is not allowed for this series'
          else coalesce(sqlerrm, 'refused') end;
        v_refused := v_refused || jsonb_build_object('series_id', rec.id, 'name', r_name,
                       'when', v_when, 'reason', v_reason);
        v_n_refused := v_n_refused + 1;
    end;
  end loop;

  -- One batch audit line on apply (the single-series functions write their own
  -- rows; this records the batch and its counts).
  if not p_preview then
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (v_studio, auth.uid(), 'series.bulk_updated', 'class_series', v_studio,
            jsonb_build_object('change', p_change, 'change_type', v_type,
                               'changed', v_n_changed, 'refused', v_n_refused,
                               'series', p_series_ids));
  end if;

  return jsonb_build_object('ok', true, 'preview', p_preview, 'change_type', v_type,
                            'changed', v_changed, 'refused', v_refused, 'warnings', v_warn);
end $function$

;

-- =============================================================================
-- The anon surface is unchanged — exactly TWELVE pre-login functions. None of
-- the new functions is anon (confirm/release/eligible_classes_run are
-- service-role only; free_first_class_list is authenticated); the re-issues kept
-- their ACLs through create-or-replace.
-- =============================================================================
do $$
declare v_n int;
begin
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and has_function_privilege('anon', p.oid, 'execute');
  if v_n <> 12 then
    raise exception 'anon surface is %, expected exactly twelve', v_n;
  end if;
end $$;
