-- Pooled build (Decisions 26c, 22, 21, 103b + two audits).
--
-- 26(c): only paying members invite a guest, per-studio switch off by default.
--        book_guest refuses invite_needs_plan; member_bootstrap carries
--        can_invite_guest so the invite surfaces swap the button for a plan line.
-- 22:    a core (or always-runs) class stands out on the timetable with an accent
--        tint and an "Always runs" chip; member_bootstrap carries guarantees_enabled
--        and the member Book/class readers carry the occurrence+series tier fields.
-- 21:    a per-occurrence "Runs regardless of bookings" switch sets guarantee_tier
--        to always (on) / null (off); the flex flag and minimum are never touched.
--        Locked once the class is decided or has started.
-- 103b:  the credit-back email (free_reservation_credited) queued by
--        write_reservation_credit on an attended check-in only.
-- audit: sweep_membership_periods now expires a non-recurring membership past its
--        validity date; template_sample_context gains the plans_url token.
--
-- The instructor digest Running list keyed on committed_at alone and so missed an
-- always-runs occurrence the morning before start, so instructor_digest_block is
-- re-issued to treat effective tier core or always as Running.
--
-- creates: set_occurrence_always_runs(uuid, boolean)
-- re-issues: book_guest(uuid, text, text, text), member_bootstrap(text), write_reservation_credit(uuid), instructor_digest_block(uuid, uuid, date), template_sample_context(uuid, text, text), sweep_membership_periods()

-- Decision 26(c): the per-studio switch. Off by default, registered.
alter table studio_settings
  add column if not exists guest_invites_members_only boolean not null default false;


-- Decision 21 amendment: "runs regardless" switch on the class sheet.
-- Sets the occurrence guarantee_tier to 'always' (on) or null (off); the flex
-- flag and minimum are never touched, so turning it off returns the class to flex.
-- occurrence_guarantee_run resolves an occurrence guarantee_tier = 'always' to an
-- at-start commit that never reaches the unmet-minimum branch. Locked once the
-- class is decided (committed or cancelled) or has started.
create or replace function set_occurrence_always_runs(p_occurrence_id uuid, p_on boolean)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare o class_occurrences%rowtype;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then
    raise exception 'no such class' using errcode = 'PT404';
  end if;
  if not coalesce(is_manager_up(o.studio_id), false) then
    raise exception 'only owners and managers change the timetable' using errcode = 'PT403';
  end if;
  if o.status <> 'scheduled' or o.committed_at is not null or now() >= o.starts_at then
    raise exception 'decided at the cut-off' using errcode = 'PT409';
  end if;
  update class_occurrences
     set guarantee_tier = case when p_on then 'always'::guarantee_tier else null end,
         updated_at = now()
   where id = p_occurrence_id;
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (o.studio_id, auth.uid(),
          case when p_on then 'occurrence.always_runs_set' else 'occurrence.always_runs_cleared' end,
          'class_occurrences', p_occurrence_id,
          jsonb_build_object('was_tier', o.guarantee_tier, 'on', p_on));
  return jsonb_build_object('ok', true, 'occurrence_id', p_occurrence_id, 'always_runs', p_on);
end $$;
revoke execute on function set_occurrence_always_runs(uuid, boolean) from public, anon;
grant  execute on function set_occurrence_always_runs(uuid, boolean) to authenticated, service_role;


-- re-issue book_guest (Decision 26c gate) ---------------------------------
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

  -- Decision 26(c): when the studio only lets paying members invite, a member
  -- with no usable plan is refused. The host is the caller's OWN member row
  -- (member-driven), so this never gates a staff-brought or walk-in guest.
  if coalesce((select guest_invites_members_only from studio_settings
                where studio_id = v_occ.studio_id), false)
     and not exists (
       select 1 from memberships ms
        where ms.member_id = v_host.id and ms.status in ('active', 'trialing')
          and (ms.credits_remaining is null or ms.credits_remaining > 0)) then
    return jsonb_build_object('ok', false, 'reason', 'invite_needs_plan');
  end if;

  -- Decision 98: one free class per person. A guest invite is name-only (no phone
  -- at invite). Refuse if the name matches an existing member who has had a free class.
  if normalise_name(coalesce(p_guest_first, '') || ' ' || coalesce(p_guest_last, '')) is not null
     and exists (
       select 1 from members m
        where m.studio_id = v_occ.studio_id and m.deleted_at is null
          and normalise_name(coalesce(m.first_name, '') || ' ' || coalesce(m.last_name, ''))
              = normalise_name(coalesce(p_guest_first, '') || ' ' || coalesce(p_guest_last, ''))
          and member_has_had_free(m.studio_id, m.id)) then
    return jsonb_build_object('ok', false, 'reason', 'duplicate');
  end if;

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
          coalesce(nullif(btrim(p_guest_last), ''), ''),
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
end $function$;

revoke execute on function book_guest(uuid, text, text, text) from public, anon;
grant  execute on function book_guest(uuid, text, text, text) to authenticated, service_role;


-- re-issue member_bootstrap (+ guarantees_enabled, + can_invite_guest) -----
drop function if exists member_bootstrap(text);
CREATE FUNCTION public.member_bootstrap(p_slug text)
 RETURNS TABLE(member_id uuid, studio_id uuid, first_name text, last_name text, preferred_name text, avatar_path text, status member_status, current_streak integer, lifetime_visits integer, studio_name text, studio_timezone text, logo_url text, theme_preset theme_preset, accent_color text, checkin_opens_minutes_before integer, checkin_closes_minutes_after integer, cancellation_cutoff_minutes integer, booking_cutoff_minutes integer, waitlist_enabled boolean, billing_status platform_status, billing_locked boolean, open_offers integer, guest_passes_enabled boolean, has_payment_provider boolean, booking_window_days integer, how_to_buy text, studio_contact_email text, xendit_enabled boolean, time_format text, trial_used boolean, messages_enabled boolean, has_unread_studio_message boolean, desk_pay_available boolean, payee_notice_name text, has_phone boolean, country text, free_first_reservation_fee_cents integer, currency text, fee_waived boolean, reservation_credit_cents integer, free_first_core_only boolean, guarantees_enabled boolean, can_invite_guest boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    s.country,
    coalesce(st.free_first_reservation_fee_cents, 0),
    s.currency,
    (m.reservation_fee_waived_at is not null),
    coalesce((select sum(mc.amount_cents - mc.used_cents)::int from member_credits mc
               where mc.studio_id = m.studio_id and mc.member_id = m.id and mc.voided_at is null), 0),
    coalesce(st.free_first_core_only, false),
    -- Decision 22 amendment: the member Book and class readers tint a core
    -- class only when the studio runs guarantees.
    coalesce(st.guarantees_enabled, false),
    -- Decision 26(c): the member may invite a guest when the studio does not
    -- gate invites, or when they hold a usable plan.
    ((not coalesce(st.guest_invites_members_only, false))
      or exists (select 1 from memberships ms2
                  where ms2.member_id = m.id and ms2.status in ('active', 'trialing')
                    and (ms2.credits_remaining is null or ms2.credits_remaining > 0)))
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


-- re-issue write_reservation_credit (Decision 103b email) -----------------
CREATE OR REPLACE FUNCTION public.write_reservation_credit(p_booking_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare b bookings%rowtype; pay payments%rowtype;
begin
  select * into b from bookings where id = p_booking_id;
  if not found then return; end if;
  if exists (select 1 from member_credits
              where booking_id = p_booking_id and reason = 'reservation_credit') then
    return;
  end if;
  select * into pay from payments
   where booking_id = p_booking_id and kind = 'reservation_fee'
     and status in ('succeeded', 'partially_refunded')
   order by created_at limit 1;
  if not found then return; end if;
  insert into member_credits (studio_id, member_id, amount_cents, currency, reason,
                              payment_id, booking_id)
  values (pay.studio_id, b.member_id, pay.amount_cents - coalesce(pay.refunded_cents, 0),
          pay.currency, 'reservation_credit', pay.id, p_booking_id);

  -- Decision 103 amendment (b): a CHECK-IN (attended) writes one credit-back
  -- email. An on-time cancel also writes the credit (Decision 103) but gets no
  -- "thanks for coming" email, so this is gated on the booking being attended.
  if b.status = 'attended' then
    perform queue_notification(pay.studio_id, b.member_id, 'free_reservation_credited',
      jsonb_build_object(
        'fee', fmt_money(pay.amount_cents - coalesce(pay.refunded_cents, 0), pay.currency),
        'class_name', coalesce((select coalesce(o.name, ct.name, 'your class')
                                  from class_occurrences o
                                  left join class_types ct on ct.id = o.class_type_id
                                 where o.id = b.occurrence_id), 'your class'),
        'plans_url', member_portal_url(pay.studio_id, '/account/plan')),
      'free_reservation_credited:' || p_booking_id);
  end if;
end $function$;

revoke execute on function write_reservation_credit(uuid) from public, anon, authenticated;
grant  execute on function write_reservation_credit(uuid) to service_role;


-- re-issue instructor_digest_block (always-runs Running) ------------------
CREATE OR REPLACE FUNCTION public.instructor_digest_block(p_studio_id uuid, p_instructor_id uuid, p_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_tz text; v_fmt text;
  th text := 'style="text-align:left;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;font-size:12px;font-weight:600;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4"';
  td text := 'style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4"';
  v_run_rows text; v_run_text text; v_can_rows text; v_can_text text;
  v_n_run int; v_n_can int; v_go_html text; v_go_text text; v_ca_html text; v_ca_text text;
begin
  select timezone into v_tz from studios where id = p_studio_id;
  v_fmt := coalesce((select time_format from studio_settings where studio_id = p_studio_id), '24h');

  -- Going ahead: the instructor's committed, still-scheduled classes that day.
  select count(*),
         string_agg('<tr><td ' || td || '>' || fmt_clock(o.starts_at, v_tz, v_fmt)
                    || '</td><td ' || td || '>' || coalesce(o.name, ct.name, 'a class')
                    || '</td><td ' || td || '>' || coalesce(o.booked_at_cutoff, o.booked_count) || ' of ' || o.capacity
                    || '</td></tr>', '' order by o.starts_at),
         string_agg('  ' || fmt_clock(o.starts_at, v_tz, v_fmt) || '  '
                    || coalesce(o.name, ct.name, 'a class') || '  '
                    || coalesce(o.booked_at_cutoff, o.booked_count) || ' of ' || o.capacity, E'\n' order by o.starts_at)
    into v_n_run, v_run_rows, v_run_text
    from class_occurrences o
    left join class_types ct on ct.id = o.class_type_id
    -- Decision 21 amendment: an always-runs occurrence commits at START, so the
    -- morning before class its committed_at is still null. It is going ahead all
    -- the same; a core class is too. Treat effective tier core or always as
    -- Running, exactly as a committed class.
    cross join lateral occurrence_guarantee_run(o.id) g
   where o.studio_id = p_studio_id and o.instructor_id = p_instructor_id
     and (o.starts_at at time zone v_tz)::date = p_date
     and o.status = 'scheduled'
     and (o.committed_at is not null or g.tier in ('core', 'always'));

  -- Cancelled for want of bookings: unmet_minimum cancellations that day. The
  -- minimum comes from the occurrence's own guarantee.
  select count(*),
         string_agg('<tr><td ' || td || '>' || fmt_clock(o.starts_at, v_tz, v_fmt)
                    || '</td><td ' || td || '>' || coalesce(o.name, ct.name, 'a class')
                    || '</td><td ' || td || '>' || o.booked_at_cutoff || ' of '
                    || coalesce(g.minimum, 0) || ' needed'
                    || '</td></tr>', '' order by o.starts_at),
         string_agg('  ' || fmt_clock(o.starts_at, v_tz, v_fmt) || '  '
                    || coalesce(o.name, ct.name, 'a class') || '  '
                    || o.booked_at_cutoff || ' of '
                    || coalesce(g.minimum, 0) || ' needed', E'\n' order by o.starts_at)
    into v_n_can, v_can_rows, v_can_text
    from class_occurrences o
    left join class_types ct on ct.id = o.class_type_id
    cross join lateral occurrence_guarantee_run(o.id) g
   where o.studio_id = p_studio_id and o.instructor_id = p_instructor_id
     and (o.starts_at at time zone v_tz)::date = p_date
     and o.status = 'cancelled' and o.cancellation_cause = 'unmet_minimum';

  v_n_run := coalesce(v_n_run, 0); v_n_can := coalesce(v_n_can, 0);

  if v_n_run > 0 then
    v_go_html := '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:12px 0;border-collapse:collapse">'
      || '<tr><td colspan="3" style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;color:#14170E;padding:0 0 6px 0">Running</td></tr>'
      || '<tr><th ' || th || '>Time</th><th ' || th || '>Class</th><th ' || th || '>Booked</th></tr>'
      || v_run_rows || '</table>';
    v_go_text := 'Running' || E'\n' || v_run_text;
  else
    v_go_html := '<p style="margin:12px 0">Nothing running.</p>';
    v_go_text := 'Nothing running.';
  end if;

  if v_n_can > 0 then
    v_ca_html := '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:12px 0;border-collapse:collapse">'
      || '<tr><td colspan="3" style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;color:#14170E;padding:0 0 6px 0">Cancelled, not enough bookings</td></tr>'
      || '<tr><th ' || th || '>Time</th><th ' || th || '>Class</th><th ' || th || '>Booked</th></tr>'
      || v_can_rows || '</table>';
    v_ca_text := 'Cancelled, not enough bookings' || E'\n' || v_can_text;
  else
    v_ca_html := '<p style="margin:12px 0">Nothing cancelled.</p>';
    v_ca_text := 'Nothing cancelled.';
  end if;

  return jsonb_build_object(
    'n_running', v_n_run, 'n_cancelled', v_n_can,
    'day', to_char(p_date, 'FMDay FMDD FMMonth'),
    'going_ahead', v_go_html, 'going_ahead_text', v_go_text,
    'cancelled', v_ca_html, 'cancelled_text', v_ca_text);
end $function$;

revoke execute on function instructor_digest_block(uuid, uuid, date) from public, anon, authenticated;
grant  execute on function instructor_digest_block(uuid, uuid, date) to service_role;


-- re-issue template_sample_context (+ plans_url) --------------------------
CREATE OR REPLACE FUNCTION public.template_sample_context(p_studio_id uuid, p_to_email text, p_first_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s studios%rowtype; st studio_settings%rowtype; v_tz text; v_fmt text;
  v_plan membership_plans%rowtype; o record; v_when text; v_offer_ends text;
  v_n3 text; v_n3line text; v_n3html text; v_links text;
  v_clist text; v_roster text; v_roster_html text; v_li text;
  v_fee text;
begin
  select * into s from studios where id = p_studio_id;
  select * into st from studio_settings where studio_id = p_studio_id;
  v_tz := s.timezone; v_fmt := coalesce(st.time_format, '24h');
  v_fee := fmt_money(coalesce(nullif(st.free_first_reservation_fee_cents, 0), 15000), s.currency);

  select o2.id, coalesce(ct.name, o2.name, 'a class') as cname, o2.starts_at,
         rm.name as room, split_part(coalesce(i.display_name, ''), ' ', 1) as instr
    into o
    from class_occurrences o2
    left join class_types ct on ct.id = o2.class_type_id
    left join rooms rm on rm.id = o2.room_id
    left join instructors i on i.id = o2.instructor_id
   where o2.studio_id = p_studio_id and o2.status = 'scheduled' and o2.starts_at > now()
   order by o2.starts_at limit 1;

  if st.intro_offer_plan_id is not null then
    select * into v_plan from membership_plans where id = st.intro_offer_plan_id;
  end if;
  if v_plan.id is null then
    select * into v_plan from membership_plans
     where studio_id = p_studio_id and status = 'active' order by sort_order limit 1;
  end if;

  v_when := case when o.starts_at is not null
    then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD Mon') || ' at ' || fmt_clock(o.starts_at, v_tz, v_fmt)
    else '' end;
  v_offer_ends := to_char((now() + interval '14 days') at time zone v_tz, 'FMDD Mon YYYY');

  with s3(nm, ts) as (
    values
      ('Reformer Flow', ((((now() at time zone v_tz)::date + 1) + time '07:00') at time zone v_tz)),
      ('Barre',         ((((now() at time zone v_tz)::date + 2) + time '18:00') at time zone v_tz)),
      ('Mat Pilates',   ((((now() at time zone v_tz)::date + 3) + time '09:00') at time zone v_tz))
  )
  select
    string_agg(to_char(ts at time zone v_tz, 'FMDy ') || fmt_clock(ts, v_tz, v_fmt) || ' ' || nm, '; ' order by ts),
    string_agg('<a href="' || member_portal_url(p_studio_id, '/book') || '">'
               || to_char(ts at time zone v_tz, 'FMDy ') || fmt_clock(ts, v_tz, v_fmt) || ' ' || nm || '</a>', ', ' order by ts),
    string_agg(to_char(ts at time zone v_tz, 'FMDay FMDD FMMon, ') || fmt_clock(ts, v_tz, v_fmt) || ' ' || nm, E'\n' order by ts),
    string_agg('<li>' || to_char(ts at time zone v_tz, 'FMDay FMDD FMMon, ') || fmt_clock(ts, v_tz, v_fmt) || ' ' || nm || '</li>', '' order by ts)
    into v_n3, v_links, v_roster, v_li
    from s3;
  v_clist := v_roster;
  v_roster_html := '<ul style="margin:0;padding-left:20px">' || v_li || '</ul>';
  v_n3line := ' Here are the next ones with space: ' || v_n3 || '.';
  v_n3html := '<p>Here are the next ones with space: ' || v_links || '.</p>';

  return jsonb_build_object(
    'to_email', p_to_email,
    'first_name', p_first_name,
    'studio_name', s.name,
    'class_name', coalesce(o.cname, 'a class'),
    'occurrence_id', o.id,
    'when', v_when,
    'where_line', case when nullif(o.room, '') is not null then ', in ' || o.room else '' end,
    'when_short', 'tomorrow',
    'when_time', case when o.starts_at is not null then fmt_clock(o.starts_at, v_tz, v_fmt) else '' end,
    'day', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMonth') else 'Monday 9 November' end,
    'time', case when o.starts_at is not null then fmt_clock(o.starts_at, v_tz, v_fmt) else '' end,
    'deadline_short', case when o.starts_at is not null then fmt_clock(o.starts_at - interval '12 hours', v_tz, v_fmt) || ' ' || to_char((o.starts_at - interval '12 hours') at time zone v_tz, 'FMDy') else 'the evening before' end,
    'cancel_deadline', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD Mon') else 'the day before' end,
    'manage_link', member_portal_url(p_studio_id, '/class/' || coalesce(o.id::text, '')),
    'book_url', member_portal_url(p_studio_id, '/book'),
    'schedule_url', member_portal_url(p_studio_id, '/book'),
    'offer_plan_name', coalesce(v_plan.name, 'a membership'),
    'offer_detail', coalesce(plan_card_detail(v_plan.id), ''),
    'offer_price', case when v_plan.id is not null then fmt_money(v_plan.price_cents, v_plan.currency) else '' end,
    'offer_ends', v_offer_ends,
    'buy_url', case when v_plan.id is not null then member_portal_url(p_studio_id, '/buy/' || v_plan.id::text) else member_portal_url(p_studio_id, '/account/plan') end,
    'plan_name', coalesce(v_plan.name, 'your plan'),
    'credits', '3', 'credits_left', '3',
    'expires_on', v_offer_ends, 'ends_on', v_offer_ends,
    'renew_url', case when v_plan.id is not null then member_portal_url(p_studio_id, '/buy/' || v_plan.id::text) else member_portal_url(p_studio_id, '/account/plan') end,
    'last_class', coalesce(o.cname, 'your class'),
    'last_class_date', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDD Mon') else '' end,
    'instructor_first', coalesce(nullif(o.instr, ''), 'your instructor'),
    'instructor_first_name', coalesce(nullif(o.instr, ''), 'your instructor'),
    'days_since', '10',
    'product', 'Grip socks', 'quantity', '1')
  || jsonb_build_object(
    'instructor_name', p_first_name,
    'href', instructor_portal_url(p_studio_id, '/instructor/schedule'),
    'schedule_link', instructor_portal_url(p_studio_id, '/instructor/schedule'),
    'booked_line', '3 booked',
    'count', '3',
    'plural', 's',
    'month', to_char(now() at time zone v_tz, 'FMMonth'),
    'period', 'this period',
    'due_on', to_char((now() + interval '3 days') at time zone v_tz, 'FMDay FMDD Mon'),
    'due_wording', 'soon',
    'hours', '12',
    'amount', fmt_money(90000, s.currency),
    'old_when', case when o.starts_at is not null
                     then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMonth YYYY, ') || fmt_clock(o.starts_at, v_tz, v_fmt)
                     else 'Monday 9 November, 07:00' end,
    'cancelled_count', '1',
    'booked', '4',
    'capacity', '8',
    'reason', 'cancelled by the studio',
    'claim_url', member_portal_url(p_studio_id, '/class/' || coalesce(o.id::text, '')))
  || jsonb_build_object(
    'next_three', v_n3,
    'next_three_line', v_n3line,
    'next_three_html', v_n3html,
    'class_list', v_clist,
    'roster', v_roster,
    'roster_html', v_roster_html)
  || jsonb_build_object(
    'staff_first_name', p_first_name,
    'member_name', coalesce(nullif(p_first_name, ''), 'A member'),
    'message', 'Hi, could I move my Saturday class to Sunday?',
    'message_html', 'Hi, could I move my Saturday class to Sunday?',
    'messages_url', member_portal_url(p_studio_id, '/messages'),
    'reply_url', coalesce(nullif(notification_setting('staff_app_origin'), ''), 'https://app.studiior.com') || '/messages')
  || jsonb_build_object(
    'old_class_name', coalesce(o.cname, 'a class'),
    'bookings_url', member_portal_url(p_studio_id, '/'))
  || jsonb_build_object(
    'class_name', coalesce(o.cname, 'a class'),
    'day', to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMonth'),
    'n_more', 2,
    'cutoff_time', coalesce(v_when, 'the cut-off'),
    'class_list_core', '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:12px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-size:16px;font-weight:600;color:#14170E">' || coalesce(o.cname, 'a class') || '</div><div style="font-size:14px;color:#57534E;margin-top:4px">' || coalesce(v_when, 'soon') || '</div><div style="font-size:13px;color:#78716C;margin-top:2px">3 in already · 4 spots left</div><table role="presentation" style="margin-top:12px"><tr><td style="border-radius:6px;background:{accent}"><a href="#" style="display:inline-block;padding:10px 20px;color:{accent_on};text-decoration:none;font-weight:600;border-radius:6px">Move me to this class</a></td></tr></table></td></tr></table>',
    'class_list_core_text', '- ' || coalesce(o.cname, 'a class') || ' · ' || coalesce(v_when, 'soon') || ' (3 in already, 4 spots left)')
  || jsonb_build_object(
    'n_running', 2, 'n_cancelled', 1,
    'pay_line', 'You''re paid on who''s checked in.',
    'going_ahead', '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:12px 0;border-collapse:collapse"><tr><td colspan="3" style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;color:#14170E;padding:0 0 6px 0">Running</td></tr><tr><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Time</th><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Class</th><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Booked</th></tr><tr><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">' || fmt_clock(((now() at time zone v_tz)::date + time '07:00') at time zone v_tz, v_tz, v_fmt) || '</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">Reformer Flow</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">4 of 6</td></tr><tr><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">' || fmt_clock(((now() at time zone v_tz)::date + time '18:00') at time zone v_tz, v_tz, v_fmt) || '</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">Barre</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">5 of 8</td></tr></table>',
    'going_ahead_text', 'Running' || E'\n  ' || fmt_clock(((now() at time zone v_tz)::date + time '07:00') at time zone v_tz, v_tz, v_fmt) || '  Reformer Flow  4 of 6' || E'\n  ' || fmt_clock(((now() at time zone v_tz)::date + time '18:00') at time zone v_tz, v_tz, v_fmt) || '  Barre  5 of 8',
    'cancelled', '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:12px 0;border-collapse:collapse"><tr><td colspan="3" style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;color:#14170E;padding:0 0 6px 0">Cancelled, not enough bookings</td></tr><tr><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Time</th><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Class</th><th style="text-align:left;font-size:12px;color:#78716C;padding:4px 10px 4px 0;border-bottom:1px solid #E7E5E4">Booked</th></tr><tr><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">' || fmt_clock(((now() at time zone v_tz)::date + time '09:00') at time zone v_tz, v_tz, v_fmt) || '</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">Mat Pilates</td><td style="font-size:14px;color:#14170E;padding:6px 10px 6px 0;border-bottom:1px solid #F5F5F4">1 of 3 needed</td></tr></table>',
    'cancelled_text', 'Cancelled, not enough bookings' || E'\n  ' || fmt_clock(((now() at time zone v_tz)::date + time '09:00') at time zone v_tz, v_tz, v_fmt) || '  Mat Pilates  1 of 3 needed')
  -- Decision 103: reservation tokens.
  || jsonb_build_object(
    'fee', v_fee,
    'from_date', to_char(now() at time zone v_tz, 'FMDD Mon'),
    'deadline', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD Mon') else 'the day before' end,
    'plans_url', member_portal_url(p_studio_id, '/account/plan'),
    'pay_url', member_portal_url(p_studio_id, '/class/' || coalesce(o.id::text, '')),
    'cancel_url', member_portal_url(p_studio_id, '/class/' || coalesce(o.id::text, '')),
    'reservation_line', '',
    'reservation_html', '')
  -- Decision 103a: closure sample tokens so the Templates preview fills them.
  || jsonb_build_object(
    'from', to_char(now() at time zone v_tz, 'FMDy FMDD FMMon'),
    'to', to_char((now() + interval '2 days') at time zone v_tz, 'FMDy FMDD FMMon'),
    'resume_date', to_char((now() + interval '7 days') at time zone v_tz, 'FMDay FMDD FMMonth YYYY'),
    'notice', 'We are closed for renovations.',
    'class_list_html', closure_card_html('Reformer Flow', v_clist),
    'schedule_url', instructor_portal_url(p_studio_id, '/instructor/schedule'));
end $function$;

revoke execute on function template_sample_context(uuid, text, text) from public, anon, authenticated;
grant  execute on function template_sample_context(uuid, text, text) to service_role;


-- re-issue sweep_membership_periods (non-recurring expiry) ----------------
CREATE OR REPLACE FUNCTION public.sweep_membership_periods()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare n_due int := 0; n_rolled int := 0; n_ended int := 0; n_expired int := 0; r record;
begin
  if not is_service_context() then
    raise exception 'this is a scheduled job, not a user action' using errcode = 'PT403';
  end if;

  with lapsed as (
    update memberships ms
       set status = 'past_due'
      from membership_plans pl
     where pl.id = ms.plan_id and pl.type = 'recurring'
       and ms.status = 'active'
       and ms.stripe_subscription_id is null
       and ms.current_period_end is not null
       and ms.current_period_end <= now()
       -- §7.4: a frozen membership is not overdue, it is paused. Its period
       -- end is meaningless while the freeze runs.
       and not membership_frozen_now(ms.id)
       -- Decision 61: a complimentary membership is never "due" — handled below.
       and not coalesce(ms.complimentary, false)
    returning ms.id, ms.studio_id, ms.status)
  insert into membership_events (studio_id, membership_id, type, from_status, to_status)
  select l.studio_id, l.id, 'period_lapsed', 'active', 'past_due' from lapsed l;
  get diagnostics n_due = row_count;

  -- Decision 61: a complimentary recurring membership whose period has ended
  -- either ENDS (its granted end date, expires_on, has passed) or ROLLS to the
  -- next period with no payment due. Never past_due.
  for r in
    select ms.id, ms.studio_id,
           (ms.expires_on is not null
            and ms.expires_on < studio_today(ms.studio_id)) as past_end
      from memberships ms
      join membership_plans pl on pl.id = ms.plan_id
     where pl.type = 'recurring'
       and ms.status = 'active'
       and coalesce(ms.complimentary, false)
       and ms.current_period_end is not null
       and ms.current_period_end <= now()
       and not membership_frozen_now(ms.id)
  loop
    if r.past_end then
      update memberships set status = 'expired', cancelled_at = now(),
             cancellation_reason = 'complimentary period ended'
       where id = r.id;
      insert into membership_events (studio_id, membership_id, type, from_status, to_status)
      values (r.studio_id, r.id, 'complimentary_ended', 'active', 'expired');
      n_ended := n_ended + 1;
    else
      perform advance_membership_period(r.id);
      n_rolled := n_rolled + 1;
    end if;
  end loop;

  -- Audit (Decision 23 follow-up): a NON-recurring membership (pack, intro,
  -- drop-in, trial) whose validity date has passed is expired. Nothing did this
  -- before, so an expired pack sat 'active' forever and still read as "on a plan".
  -- Recurring memberships are handled above.
  with gone as (
    update memberships ms
       set status = 'expired', cancelled_at = now(),
           cancellation_reason = 'validity period ended'
      from membership_plans pl
     where pl.id = ms.plan_id and pl.type <> 'recurring'
       and ms.status = 'active'
       and ms.expires_on is not null
       and ms.expires_on < studio_today(ms.studio_id)
       and not membership_frozen_now(ms.id)
    returning ms.id, ms.studio_id)
  insert into membership_events (studio_id, membership_id, type, from_status, to_status)
  select g.studio_id, g.id, 'membership_expired', 'active', 'expired' from gone g;
  get diagnostics n_expired = row_count;

  return jsonb_build_object('marked_past_due', n_due,
                            'complimentary_rolled', n_rolled,
                            'complimentary_ended', n_ended,
                            'non_recurring_expired', n_expired);
end $function$;

revoke execute on function sweep_membership_periods() from public, anon, authenticated;
grant  execute on function sweep_membership_periods() to service_role;


-- Decision 103 amendment (b): the credit-back email. 80a frame, a "See plans"
-- accent button to the member /account/plan. Platform default only.
insert into notification_templates (key, subject, text_body, html_body, note) values
('free_reservation_credited',
 'Your {fee} is back on your account',
 E'Hi {first_name},\n\nThanks for coming to {class_name} today. Your {fee} reservation fee is now credit on your account. It comes off your next class package or merchandise automatically.\n\nSee plans: {plans_url}',
 '<p>Hi {first_name},</p>
<p>Thanks for coming to <strong>{class_name}</strong> today. Your {fee} reservation fee is now credit on your account. It comes off your next class package or merchandise automatically.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{plans_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">See plans</a></td></tr></table>
<p>{studio_name}</p>',
 'Decision 103b: a reservation fee came back as account credit after a check-in.')
on conflict (key) do nothing;


-- --- Anon stays EXACTLY THIRTEEN --------------------------------------------
do $$ declare n int; begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % (want 13)', n; end if;
end $$;

