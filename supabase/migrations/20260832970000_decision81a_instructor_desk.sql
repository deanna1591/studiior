-- Decision 81a — walk-ins and paying at the desk, from the instructor's roster.
-- creates: instructor_scope(uuid), free_first_eligibility_run(uuid, uuid, uuid), record_manual_payment_run(uuid, uuid, text, integer, text, uuid, uuid, bpchar, text, text, timestamptz, text), add_walk_in(uuid, text, text, text), record_desk_dropin_paid(uuid, text, integer, text), sell_plan_at_desk(uuid, uuid, uuid, text, text, boolean), move_booking_here(uuid, uuid), my_desk_payments(), instructor_roster_pay(uuid)
-- re-issues: free_first_eligibility(uuid, uuid, uuid), record_manual_payment(uuid, uuid, text, integer, text, uuid, uuid, bpchar, text, text, timestamptz, text), queue_booking_notifications(uuid), notification_wanted(uuid, text)
--
-- An instructor is the only staff in the room (Reform opens 9 Nov with no front
-- desk). From the roster of a class they teach TODAY they can add a walk-in,
-- take a desk payment, sell a plan and move a member's same-day booking in.
-- New SECURITY DEFINER RPCs scoped by instructor_scope(); is_desk_up is NOT
-- widened. They delegate to the existing internals — which is why the two money
-- primitives gain an unguarded _run twin (the amendment-9 pattern): an
-- instructor is not the subject and not desk, so it cannot call the guarded
-- wrapper. Owners/managers keep today's member-profile pages. Decision 81b (the
-- online unpaid drop-in) ships separately; Reform's unpaid cap stays 0 until then.

-- ===========================================================================
-- 1. instructor_scope — the one gate every function below reads.
--    null = allowed. Staff (is_desk_up) and background jobs pass with no
--    today/own-class restriction; an instructor is held to a PUBLISHED class
--    that is THEIRS and is TODAY in the studio's timezone.
-- ===========================================================================
create or replace function instructor_scope(p_occurrence uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare o class_occurrences%rowtype; v_tz text;
begin
  select * into o from class_occurrences where id = p_occurrence;
  if not found then return 'no such class'; end if;
  if is_service_context() or coalesce(is_desk_up(o.studio_id), false) then
    return null;
  end if;
  if not (o.instructor_id is not null
          and coalesce(is_this_instructor(o.instructor_id), false)
          and occurrence_published(o.id)) then
    return 'not your class';
  end if;
  select timezone into v_tz from studios where id = o.studio_id;
  if (o.starts_at at time zone v_tz)::date <> (now() at time zone v_tz)::date then
    return 'that class is not today';
  end if;
  return null;
end $$;
revoke execute on function instructor_scope(uuid) from public, anon;
grant  execute on function instructor_scope(uuid) to authenticated, service_role;

-- ===========================================================================
-- 2. free_first_eligibility — split into an UNGUARDED _run twin (so add_walk_in,
--    which is not the subject, can judge a walk-in) and a thin guarded wrapper
--    that keeps today's ACL and the self/desk/service boundary. The twin's body
--    is byte-for-byte migration 20260832950000 minus the guard.
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
    elsif v_noshow >= 2 then
      return jsonb_build_object('ok', false, 'reason', 'missed_twice');
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
-- 3. record_manual_payment — split the same way. The _run twin is the full body
--    (from 20260832480000) MINUS the is_desk_up guard; the lockout, amount and
--    member-belongs checks stay. The desk path keeps its is_desk_up boundary in
--    the wrapper; the instructor functions do instructor_scope then call _run.
-- ===========================================================================
create or replace function record_manual_payment_run(
  p_studio_id uuid, p_member_id uuid, p_kind text, p_amount_cents integer, p_method text,
  p_plan_id uuid default null, p_booking_id uuid default null, p_currency char default null,
  p_method_note text default null, p_reference text default null,
  p_paid_at timestamptz default now(), p_description text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_currency char(3);
  v_ms       uuid;
  v_payment  uuid;
  v_confirmed boolean := false;
  v_plan_name text;
  v_renewing uuid;
  v_renewal  jsonb;
  v_is_group boolean := false;
  v_group_purchase uuid;
begin
  if studio_is_locked(p_studio_id) then
    raise exception 'this studio''s Studiior subscription is not active'
      using errcode = 'PT402',
            hint = 'Reactivate it from Billing. Nothing has been deleted.';
  end if;

  if p_amount_cents is null or p_amount_cents < 0 then
    raise exception 'an amount is needed' using errcode = 'PT400';
  end if;
  if not exists (select 1 from members where id = p_member_id and studio_id = p_studio_id) then
    raise exception 'that member does not belong to this studio' using errcode = 'PT403';
  end if;

  select coalesce(p_currency, s.currency) into v_currency
    from studios s where s.id = p_studio_id;

  if p_kind = 'plan' then
    if p_plan_id is null then
      raise exception 'which plan?' using errcode = 'PT400';
    end if;
    select ms.id into v_renewing
      from memberships ms
      join membership_plans pl on pl.id = ms.plan_id
     where ms.studio_id = p_studio_id and ms.member_id = p_member_id
       and ms.plan_id = p_plan_id
       and pl.type = 'recurring'
       and ms.status in ('active', 'past_due')
     order by ms.current_period_end desc nulls last
     limit 1;

    if v_renewing is not null then
      v_ms := v_renewing;
      -- The UNGUARDED twin: record_manual_payment_run is also reached from the
      -- instructor desk (sell_plan_at_desk), where the caller is not desk/service
      -- and advance_membership_period's own guard would refuse. The desk/scope
      -- boundary is enforced by the caller (is_desk_up wrapper / instructor_scope).
      v_renewal := advance_membership_period_run(v_renewing);
    else
      v_ms := activate_purchase(p_studio_id, p_member_id, p_plan_id,
                                p_amount_cents, v_currency);
    end if;
    select name, type = 'group' into v_plan_name, v_is_group
      from membership_plans where id = p_plan_id;
    if v_is_group then v_group_purchase := v_ms; v_ms := null; end if;

  elsif p_kind = 'dropin' then
    if p_booking_id is null then
      raise exception 'which booking?' using errcode = 'PT400';
    end if;
    v_confirmed := confirm_dropin_payment(p_studio_id, p_booking_id);
  end if;

  insert into payments (
    studio_id, member_id, membership_id, group_purchase_id, booking_id, amount_cents, currency,
    status, provider, method, method_note, reference, description,
    paid_at, recorded_by
  ) values (
    p_studio_id, p_member_id, v_ms, v_group_purchase, p_booking_id, p_amount_cents, v_currency,
    'succeeded', 'manual', p_method, p_method_note, p_reference,
    coalesce(p_description,
             case p_kind when 'plan' then v_plan_name
                         when 'dropin' then 'Drop-in class'
                         else 'Payment' end),
    coalesce(p_paid_at, now()), auth.uid()
  ) returning id into v_payment;

  return jsonb_build_object(
    'payment_id', v_payment,
    'membership_id', v_ms,
    'group_purchase_id', v_group_purchase,
    'booking_confirmed', v_confirmed,
    'renewed', v_renewal
  );
end $$;
revoke execute on function record_manual_payment_run(uuid, uuid, text, integer, text, uuid, uuid, char, text, text, timestamptz, text) from public, anon, authenticated;
grant  execute on function record_manual_payment_run(uuid, uuid, text, integer, text, uuid, uuid, char, text, text, timestamptz, text) to service_role;

create or replace function public.record_manual_payment(p_studio_id uuid, p_member_id uuid, p_kind text, p_amount_cents integer, p_method text, p_plan_id uuid DEFAULT NULL::uuid, p_booking_id uuid DEFAULT NULL::uuid, p_currency character DEFAULT NULL::bpchar, p_method_note text DEFAULT NULL::text, p_reference text DEFAULT NULL::text, p_paid_at timestamp with time zone DEFAULT now(), p_description text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not is_desk_up(p_studio_id) then
    raise exception 'only staff can record a payment' using errcode = 'PT403';
  end if;
  return record_manual_payment_run(p_studio_id, p_member_id, p_kind, p_amount_cents, p_method,
    p_plan_id, p_booking_id, p_currency, p_method_note, p_reference, p_paid_at, p_description);
end $function$;
revoke execute on function record_manual_payment(uuid, uuid, text, integer, text, uuid, uuid, bpchar, text, text, timestamptz, text) from public, anon;
grant  execute on function record_manual_payment(uuid, uuid, text, integer, text, uuid, uuid, bpchar, text, text, timestamptz, text) to authenticated, service_role;

-- ===========================================================================
-- 4. queue_booking_notifications — re-issued from 20260832940000 with ONE added
--    line: a transaction-local suppress flag so add_walk_in can send its own
--    combined walk_in_welcome instead of the per-insert booking email. Every
--    other branch is byte-for-byte.
-- ===========================================================================
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
  v_deadline timestamptz;
  v_cutoff timestamptz;
  v_fmt text;
  v_cancel_deadline text;
begin
  select * into b from bookings where id = p_booking_id;
  if not found or b.status <> 'booked' then return 0; end if;

  -- Decision 81a: a walk-in added by an instructor gets ONE combined
  -- walk_in_welcome (new member) or the normal booking email (existing member),
  -- queued by add_walk_in itself; this per-insert email is suppressed for it.
  if current_setting('studiior.suppress_booking_email', true) = '1' then return 0; end if;

  select * into o  from class_occurrences where id = b.occurrence_id;
  select * into m  from members            where id = b.member_id;
  select * into s  from studios            where id = b.studio_id;
  select * into st from studio_settings    where studio_id = b.studio_id;
  v_fmt := coalesce(st.time_format, '24h');

  v_when  := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY, ')
             || fmt_clock(o.starts_at, s.timezone, v_fmt);
  v_where := coalesce((select ', in ' || r.name from rooms r where r.id = o.room_id), '');
  v_manage := 'https://' || s.slug || '.'
              || coalesce(notification_setting('member_app_domain'), 'studiior.app')
              || '/class/' || o.id;

  v_is_free := current_setting('studiior.free_first', true) = '1'
    or (b.payment_source = 'comp'
        and exists (select 1 from guest_passes gp
                     where gp.guest_booking_id = b.id and gp.host_member_id is null));
  v_ff_txt  := case when v_is_free then E'\n\nThis one''s on us — your first class is free.' else '' end;
  v_ff_html := case when v_is_free then '<p>This one''s on us — your first class is free.</p>' else '' end;

  select deadline_at into v_deadline from flex_deadline_for_run(o.id);

  if b.payment_source = 'comp' and b.provisional then
    select cutoff_at into v_cutoff from occurrence_guarantee_run(o.id);
    if queue_notification(b.studio_id, b.member_id, 'free_booking_pending',
          jsonb_build_object('class_name', o.name, 'when', v_when,
            'cutoff_long', fmt_clock(v_cutoff, s.timezone, v_fmt) || ' on ' || to_char(v_cutoff at time zone s.timezone, 'FMDay FMDD FMMonth YYYY'),
            'booking_id', b.id, 'occurrence_id', o.id),
          'booking_confirmed:' || b.id) is not null then n := n + 1; end if;
  elsif v_is_free then
    v_cancel_deadline :=
      fmt_clock(o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)), s.timezone, v_fmt)
      || ' on ' || to_char(
        (o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)))
          at time zone s.timezone, 'FMDay FMDD FMMonth YYYY');
    if queue_notification(b.studio_id, b.member_id, 'free_booking_confirmed',
          jsonb_build_object('class_name', o.name,
            'day',  to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth'),
            'time', fmt_clock(o.starts_at, s.timezone, v_fmt),
            'cancel_deadline', v_cancel_deadline,
            'manage_link', v_manage,
            'occurrence_id', o.id),
          'booking_confirmed:' || b.id) is not null then n := n + 1; end if;
  elsif v_deadline is not null then
    if queue_notification(b.studio_id, b.member_id, 'flex_booking_pending',
          jsonb_build_object('class_name', o.name, 'when', v_when,
            'deadline_short', to_char(v_deadline at time zone s.timezone, 'FMDy ')
                              || fmt_clock(v_deadline, s.timezone, v_fmt),
            'deadline_long', fmt_clock(v_deadline, s.timezone, v_fmt) || ' on ' || to_char(v_deadline at time zone s.timezone, 'FMDay FMDD FMMonth YYYY'),
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
                             'when_time', fmt_clock(o.starts_at, s.timezone, v_fmt),
                             'where_line', v_where),
          'class_reminder:' || b.id, v_remind) is not null then n := n + 1; end if;
  end if;

  return n;
end $function$;
revoke execute on function queue_booking_notifications(uuid) from public, anon, authenticated;
grant  execute on function queue_booking_notifications(uuid) to service_role;

-- ===========================================================================
-- 5. notification_wanted — re-issued from 20260832810000, adding walk_in_welcome
--    to the always-send set (an instructor's welcome cannot be turned off, and
--    its reader has no preferences row yet — the member_invite rule).
-- ===========================================================================
create or replace function notification_wanted(p_member_id uuid, p_template text)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare p notification_preferences%rowtype; v_ok boolean;
begin
  if p_template = 'campaign' then
    select (marketing_opt_in and marketing_unsubscribed_at is null) into v_ok
      from members where id = p_member_id;
    return coalesce(v_ok, false);
  end if;

  if left(p_template, 8) = 'convert_' or left(p_template, 5) = 'keep_'
     or left(p_template, 10) = 'retention_' or p_template = 'retention' then
    select sequence_email into v_ok from notification_preferences where member_id = p_member_id;
    return coalesce(v_ok, true);
  end if;

  if p_template in ('class_cancelled', 'instructor_substituted',
                    'payment_failed', 'staff_message', 'class_moved',
                    'member_invite', 'guest_invite', 'guest_host_cancelled',
                    'guest_waiver_reminder', 'guest_waiver_host_nudge',
                    'flex_booking_confirmed', 'flex_booking_not_confirmed',
                    'free_booking_confirmed', 'free_booking_not_confirmed',
                    'membership_ended', 'membership_frozen', 'walk_in_welcome') then
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

-- ===========================================================================
-- 6. add_walk_in — the instructor's "Add walk-in" from the roster.
-- ===========================================================================
create or replace function add_walk_in(p_occurrence uuid, p_name text, p_email text, p_mobile text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_scope   text;
  v_occ     class_occurrences%rowtype;
  v_set     studio_settings%rowtype;
  v_ser     class_series%rowtype;
  v_s       studios%rowtype;
  v_tz      text;
  v_today   date;
  v_email   text;
  v_key     text;
  v_member  members%rowtype;
  v_new     boolean := false;
  v_first   text;
  v_last    text;
  v_token   text;
  v_claim   text;
  v_elig    jsonb;
  v_cfg_tier guarantee_tier;
  v_open    boolean;
  v_free    int;
  v_seat    text;
  v_booking uuid;
  v_due     int := null;
  -- plan pick (book_class §2.2)
  v_cand    record;
  v_covers  boolean;
  v_pay     payment_source;
  v_membership uuid;
  v_consume boolean := false;
  v_balance int;
  v_ledger  uuid;
  -- booked elsewhere / alternatives
  v_other   record;
  v_alts    jsonb;
  v_class_when text;
  v_ci      jsonb;
  v_checked boolean := false;
  v_ci_reason text := null;
begin
  v_scope := instructor_scope(p_occurrence);
  if v_scope is not null then
    return jsonb_build_object('ok', false, 'reason', v_scope);
  end if;

  select * into v_occ from class_occurrences where id = p_occurrence for update;
  select * into v_set from studio_settings where studio_id = v_occ.studio_id;
  select * into v_s   from studios where id = v_occ.studio_id;
  v_tz := v_s.timezone;
  v_today := (now() at time zone v_tz)::date;

  if v_occ.status <> 'scheduled' then
    return jsonb_build_object('ok', false, 'reason', 'class is not open for booking');
  end if;

  v_email := lower(btrim(coalesce(p_email, '')));
  if v_email = '' or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    return jsonb_build_object('ok', false, 'reason', 'a valid email is needed');
  end if;
  if coalesce(btrim(p_name), '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'a name is needed');
  end if;
  v_key := normalize_email_key(v_email);

  -- Match by normalized email in this studio, else create an unclaimed member.
  select * into v_member from members
   where studio_id = v_occ.studio_id and normalize_email_key(email) = v_key
   order by created_at limit 1;

  if not found then
    v_first := split_part(btrim(p_name), ' ', 1);
    v_last  := btrim(substr(btrim(p_name), length(v_first) + 1));
    if v_last = '' then v_last := v_first; end if;
    insert into members (studio_id, first_name, last_name, email, phone, source, status)
    values (v_occ.studio_id, v_first, v_last, v_email, nullif(btrim(coalesce(p_mobile,'')), ''),
            'front_desk', 'active')
    returning * into v_member;
    v_new := true;

    -- Mint the invite token the way create_member_invite does, WITHOUT sending
    -- member_invite (walk_in_welcome carries the claim link instead). Inlined
    -- because create_member_invite guards is_desk_up and the caller is an
    -- instructor.
    v_token := encode(gen_random_bytes(24), 'hex');
    delete from member_invites where member_id = v_member.id and accepted_at is null;
    insert into member_invites (studio_id, member_id, email, token_hash, expires_at, created_by)
    values (v_occ.studio_id, v_member.id, v_email,
            encode(digest(v_token, 'sha256'), 'hex'), now() + make_interval(days => 14), auth.uid());
    v_claim := 'https://' || v_s.slug || '.'
               || coalesce(notification_setting('member_app_domain'), 'studiior.app')
               || '/claim/' || v_token;
  end if;

  -- Already in this class?
  if exists (select 1 from bookings
              where occurrence_id = p_occurrence and member_id = v_member.id
                and status in ('booked','attended','pending_payment','waitlisted')) then
    return jsonb_build_object('ok', false, 'reason', 'member already has a seat in this class');
  end if;

  -- A live booking for ANOTHER class today → offer Move here, do not book.
  select b.id as booking_id, o2.name as class_name, o2.starts_at
    into v_other
    from bookings b join class_occurrences o2 on o2.id = b.occurrence_id
   where b.member_id = v_member.id and b.studio_id = v_occ.studio_id
     and b.occurrence_id <> p_occurrence
     and b.status in ('booked','attended')
     and (o2.starts_at at time zone v_tz)::date = v_today
   order by o2.starts_at limit 1;
  if found then
    return jsonb_build_object('ok', false, 'reason', 'booked elsewhere today',
      'booking_id', v_other.booking_id, 'class_name', v_other.class_name,
      'when', fmt_clock(v_other.starts_at, v_tz, coalesce(v_set.time_format,'24h')),
      'member_id', v_member.id, 'new_member', v_new);
  end if;

  -- Capacity.
  v_free := v_occ.capacity - occurrence_seats_taken(p_occurrence) - occurrence_seats_held(p_occurrence);
  if v_free < 1 then
    select jsonb_agg(jsonb_build_object(
             'occurrence_id', x.id, 'name', x.name, 'start', x.starts_at,
             'seats_left', x.capacity - occurrence_seats_taken(x.id) - occurrence_seats_held(x.id))
             order by x.starts_at)
      into v_alts
      from (select o3.* from class_occurrences o3
             where o3.studio_id = v_occ.studio_id and o3.status = 'scheduled'
               and o3.id <> p_occurrence
               and o3.starts_at > now()
               and (o3.starts_at at time zone v_tz)::date between v_today and v_today + 1
               and month_published(o3.studio_id, o3.starts_at)
               and (not studio_hides_unstaffed(o3.studio_id) or o3.staffing = 'assigned')
               and o3.capacity - occurrence_seats_taken(o3.id) - occurrence_seats_held(o3.id) > 0
             order by o3.starts_at limit 3) x;
    return jsonb_build_object('ok', false, 'reason', 'class is full',
      'alternatives', coalesce(v_alts, '[]'::jsonb), 'member_id', v_member.id, 'new_member', v_new);
  end if;

  -- ---- seat kind: free first class, else a covering plan, else drop-in -------
  if v_occ.series_id is not null then select * into v_ser from class_series where id = v_occ.series_id; end if;
  v_cfg_tier := coalesce(v_occ.guarantee_tier, case when v_occ.flex then 'flex'::guarantee_tier end,
                         v_ser.guarantee_tier, case when v_ser.flex then 'flex'::guarantee_tier end,
                         'core'::guarantee_tier);
  -- The class is open to first-timers iff book_first_free's gates pass.
  v_open := coalesce(v_set.free_first_class_enabled, false)
    and v_occ.free_first_override is distinct from 'closed'
    and (coalesce(v_occ.free_first_override = 'open', false)
         or ((not coalesce(v_set.free_first_core_only, false) or v_cfg_tier = 'core')
             and (v_occ.series_id is null or coalesce(v_ser.free_first_allowed, true))))
    and not (not coalesce(v_set.free_first_peak_allowed, true) and occurrence_is_peak(p_occurrence))
    and not (v_set.free_first_seats_per_class is not null
             and (select count(*) from bookings b
                   where b.occurrence_id = p_occurrence and b.status = 'booked'
                     and b.payment_source = 'comp'
                     and exists (select 1 from guest_passes gp
                                  where gp.guest_booking_id = b.id and gp.host_member_id is null))
                 >= v_set.free_first_seats_per_class);

  v_elig := free_first_eligibility_run(v_occ.studio_id, v_member.id);

  if v_new then perform set_config('studiior.suppress_booking_email', '1', true); end if;

  if (v_elig ->> 'ok')::boolean and v_open then
    -- A comp free-first seat, written as book_first_free writes it. A walk-in is
    -- checked in at once, so the seat is CONFIRMED (non-provisional).
    v_seat := 'free_first';
    perform set_config('studiior.free_first', '1', true);
    insert into bookings (studio_id, occurrence_id, member_id, status, source,
                          payment_source, provisional, confirmed_at)
    values (v_occ.studio_id, p_occurrence, v_member.id, 'booked', 'front_desk', 'comp', false, now())
    returning id into v_booking;
    update class_occurrences set booked_count = booked_count + 1 where id = p_occurrence;
    insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email,
                              occurrence_id, guest_booking_id, status, waiver_signed_at)
    values (v_occ.studio_id, null, v_member.id, lower(btrim(v_member.email)),
            p_occurrence, v_booking,
            case when v_member.waiver_signed_at is not null then 'confirmed' else 'invited' end,
            v_member.waiver_signed_at)
    on conflict (studio_id, normalize_email_key(guest_email)) do update
      set host_member_id   = excluded.host_member_id,
          guest_member_id  = excluded.guest_member_id,
          occurrence_id    = excluded.occurrence_id,
          guest_booking_id = excluded.guest_booking_id,
          status           = excluded.status,
          waiver_signed_at = excluded.waiver_signed_at;
    perform confirm_provisional_seats_run(p_occurrence);
  else
    -- A covering plan with credit (book_class §2.2 pick), else an unpaid drop-in.
    for v_cand in
      select ms.id, ms.credits_remaining, mp.restrictions,
             case when mp.type = 'recurring' and mp.credits_per_period is null and ms.credits_remaining is null then 1
                  when mp.type = 'recurring' and coalesce(ms.credits_remaining,0) > 0 then 2
                  when mp.type in ('class_pack','drop_in','trial') and coalesce(ms.credits_remaining,0) > 0 then 3
                  else 99 end as priority
        from memberships ms join membership_plans mp on mp.id = ms.plan_id
       where ms.member_id = v_member.id and ms.studio_id = v_occ.studio_id
         and (ms.status in ('active','trialing')
              or (ms.status = 'past_due'
                  and now() < coalesce(ms.current_period_end, now()) + make_interval(days => v_set.payment_grace_days)))
         and not (ms.freeze_start is not null and ms.freeze_end is not null and v_today between ms.freeze_start and ms.freeze_end)
         and (ms.expires_on is null or ms.expires_on >= v_today)
       order by priority, ms.expires_on asc nulls last, ms.created_at asc
    loop
      exit when v_cand.priority = 99;
      v_covers := (v_cand.restrictions -> 'class_type_ids') is null
               or jsonb_typeof(v_cand.restrictions -> 'class_type_ids') <> 'array'
               or jsonb_array_length(v_cand.restrictions -> 'class_type_ids') = 0
               or (v_occ.class_type_id is not null
                   and jsonb_exists(v_cand.restrictions -> 'class_type_ids', v_occ.class_type_id::text));
      if not v_covers then continue; end if;
      v_pay        := case when v_cand.priority in (1,2) then 'membership'::payment_source else 'class_pack'::payment_source end;
      v_membership := v_cand.id;
      v_consume    := v_cand.priority in (2,3);
      exit;
    end loop;

    if v_pay is null then
      v_pay := 'drop_in';
      v_seat := 'drop_in';
      select price_cents into v_due from membership_plans
       where studio_id = v_occ.studio_id and type = 'drop_in'
         and visibility = 'public' and status = 'active'
       order by price_cents asc limit 1;
    else
      v_seat := 'plan';
    end if;

    insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source, membership_id)
    values (v_occ.studio_id, p_occurrence, v_member.id, 'booked', 'front_desk', v_pay,
            case when v_pay in ('membership','class_pack') then v_membership end)
    returning id into v_booking;
    update class_occurrences set booked_count = booked_count + 1 where id = p_occurrence;

    if v_consume then
      select coalesce(sum(delta), 0) into v_balance from credit_ledger
       where studio_id = v_occ.studio_id and member_id = v_member.id;
      insert into credit_ledger (studio_id, member_id, membership_id, delta, reason,
                                 booking_id, balance_after, expires_at, actor_user_id)
      select v_occ.studio_id, v_member.id, v_membership, -1, 'booking', v_booking, v_balance - 1,
             case when ms.expires_on is not null then (ms.expires_on + 1)::timestamp at time zone v_tz end,
             auth.uid()
        from memberships ms where ms.id = v_membership
      returning id into v_ledger;
      update memberships set credits_remaining = credits_remaining - 1 where id = v_membership;
      update bookings set credit_entry_id = v_ledger where id = v_booking;
    end if;
  end if;

  -- Checked in at once (method 'instructor'). The §8 window + waiver triggers
  -- fire; if they refuse (window shut, waiver unsigned) the seat stands and the
  -- result says it was not checked in.
  begin
    v_ci := record_check_in(v_booking, 'instructor');
    v_checked := coalesce((v_ci ->> 'ok')::boolean, false);
    if not v_checked then v_ci_reason := v_ci ->> 'reason'; end if;
  exception when others then
    v_checked := false; v_ci_reason := 'check-in not available yet';
  end;

  -- Email. A new member → one combined walk_in_welcome (the booking email was
  -- suppressed above). An existing member → the normal booking email from the
  -- insert trigger; nothing extra here.
  if v_new then
    v_class_when := to_char(v_occ.starts_at at time zone v_tz, 'FMDay FMDD FMMonth, ')
                    || fmt_clock(v_occ.starts_at, v_tz, coalesce(v_set.time_format,'24h'));
    perform queue_notification(v_occ.studio_id, v_member.id, 'walk_in_welcome',
      jsonb_build_object('claim_url', v_claim, 'class_name', v_occ.name,
        'class_when', v_class_when,
        'due_line', case when v_seat = 'drop_in' and v_due is not null
                         then 'Pay ' || fmt_money(v_due, v_s.currency) || ' at the desk today.' else '' end),
      'walk_in_welcome:' || v_booking);
  end if;

  return jsonb_build_object('ok', true, 'booking_id', v_booking, 'member_id', v_member.id,
    'seat', v_seat, 'due_cents', v_due, 'new_member', v_new,
    'checked_in', v_checked, 'checkin_reason', v_ci_reason);
end $$;
revoke execute on function add_walk_in(uuid, text, text, text) from public, anon;
grant  execute on function add_walk_in(uuid, text, text, text) to authenticated, service_role;

-- ===========================================================================
-- 7. record_desk_dropin_paid — settle an unpaid drop-in at the desk.
-- ===========================================================================
create or replace function record_desk_dropin_paid(p_booking uuid, p_method text, p_amount_cents int, p_reference text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_b bookings%rowtype; v_scope text; v_res jsonb;
begin
  select * into v_b from bookings where id = p_booking;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such booking'); end if;
  v_scope := instructor_scope(v_b.occurrence_id);
  if v_scope is not null then return jsonb_build_object('ok', false, 'reason', v_scope); end if;

  if p_method not in ('gcash','cash','card_terminal') then
    return jsonb_build_object('ok', false, 'reason', 'unknown payment method');
  end if;
  if v_b.payment_source <> 'drop_in'
     or exists (select 1 from payments p where p.booking_id = v_b.id and p.status in ('succeeded','partially_refunded')) then
    return jsonb_build_object('ok', false, 'reason', 'payment already recorded');
  end if;

  v_res := record_manual_payment_run(v_b.studio_id, v_b.member_id, 'dropin', p_amount_cents, p_method,
             null, v_b.id, null, null, nullif(btrim(coalesce(p_reference,'')), ''));
  return jsonb_build_object('ok', true, 'payment_id', v_res ->> 'payment_id');
end $$;
revoke execute on function record_desk_dropin_paid(uuid, text, int, text) from public, anon;
grant  execute on function record_desk_dropin_paid(uuid, text, int, text) to authenticated, service_role;

-- ===========================================================================
-- 8. sell_plan_at_desk — sell a plan to a member who holds a seat in this class;
--    optionally pay today's unpaid drop-in from it (Decision 73b apply path).
-- ===========================================================================
create or replace function sell_plan_at_desk(p_occurrence uuid, p_member uuid, p_plan uuid,
                                             p_method text, p_reference text, p_use_for_today boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_scope text; v_occ class_occurrences%rowtype; mp membership_plans%rowtype;
        v_res jsonb; v_ms uuid; v_seat bookings%rowtype;
begin
  v_scope := instructor_scope(p_occurrence);
  if v_scope is not null then return jsonb_build_object('ok', false, 'reason', v_scope); end if;
  select * into v_occ from class_occurrences where id = p_occurrence;

  if p_method not in ('gcash','cash','card_terminal') then
    return jsonb_build_object('ok', false, 'reason', 'unknown payment method');
  end if;
  if not exists (select 1 from bookings where occurrence_id = p_occurrence and member_id = p_member
                  and status in ('booked','attended','pending_payment')) then
    return jsonb_build_object('ok', false, 'reason', 'member already has a seat in this class' );
  end if;
  select * into mp from membership_plans
   where id = p_plan and studio_id = v_occ.studio_id and status = 'active' and visibility = 'public';
  if not found then return jsonb_build_object('ok', false, 'reason', 'plan not for sale here'); end if;

  v_res := record_manual_payment_run(v_occ.studio_id, p_member, 'plan', mp.price_cents, p_method,
             p_plan, null, null, null, nullif(btrim(coalesce(p_reference,'')), ''));
  v_ms := nullif(v_res ->> 'membership_id', '')::uuid;

  -- Use it for today: pay the member's unpaid drop-in in THIS class from the new
  -- plan (Decision 73b apply-on-activation), so its due becomes zero.
  if p_use_for_today and v_ms is not null then
    select * into v_seat from bookings
     where occurrence_id = p_occurrence and member_id = p_member and payment_source = 'drop_in'
       and status in ('booked','attended')
       and not exists (select 1 from payments p where p.booking_id = bookings.id and p.status in ('succeeded','partially_refunded'))
     limit 1;
    if found then perform apply_plan_to_unpaid(v_occ.studio_id, p_member, v_ms); end if;
  end if;

  return jsonb_build_object('ok', true, 'membership_id', v_ms, 'payment_id', v_res ->> 'payment_id',
    'renewed', v_res -> 'renewed');
end $$;
revoke execute on function sell_plan_at_desk(uuid, uuid, uuid, text, text, boolean) from public, anon;
grant  execute on function sell_plan_at_desk(uuid, uuid, uuid, text, text, boolean) to authenticated, service_role;

-- ===========================================================================
-- 9. move_booking_here — move a member's same-day booking into this class.
-- ===========================================================================
create or replace function move_booking_here(p_booking uuid, p_target uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_scope text; v_b bookings%rowtype; v_src class_occurrences%rowtype;
        v_tgt class_occurrences%rowtype; v_tz text; v_today date; v_free int; v_ci jsonb;
begin
  v_scope := instructor_scope(p_target);
  if v_scope is not null then return jsonb_build_object('ok', false, 'reason', v_scope); end if;

  select * into v_tgt from class_occurrences where id = p_target for update;
  select * into v_b from bookings where id = p_booking;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such booking'); end if;
  if v_b.status not in ('booked','attended') then
    return jsonb_build_object('ok', false, 'reason', 'that booking is not live');
  end if;
  if v_b.studio_id <> v_tgt.studio_id then
    return jsonb_build_object('ok', false, 'reason', 'not your class');
  end if;
  if v_b.occurrence_id = p_target then
    return jsonb_build_object('ok', false, 'reason', 'member already has a seat in this class');
  end if;

  select * into v_src from class_occurrences where id = v_b.occurrence_id;
  select timezone into v_tz from studios where id = v_tgt.studio_id;
  v_today := (now() at time zone v_tz)::date;
  if (v_src.starts_at at time zone v_tz)::date <> v_today then
    return jsonb_build_object('ok', false, 'reason', 'that booking is not today');
  end if;

  if exists (select 1 from bookings where occurrence_id = p_target and member_id = v_b.member_id
              and status in ('booked','attended','pending_payment','waitlisted')) then
    return jsonb_build_object('ok', false, 'reason', 'member already has a seat in this class');
  end if;

  v_free := v_tgt.capacity - occurrence_seats_taken(p_target) - occurrence_seats_held(p_target);
  if v_free < 1 then return jsonb_build_object('ok', false, 'reason', 'class is full'); end if;

  -- Move in place: payment_source / membership_id / credit_entry_id / the
  -- guest_passes link all stay. No fee, no credit movement.
  update bookings set occurrence_id = p_target, updated_at = now() where id = p_booking;
  update guest_passes set occurrence_id = p_target where guest_booking_id = p_booking;
  update class_occurrences set booked_count = greatest(booked_count - 1, 0) where id = v_src.id;
  update class_occurrences set booked_count = booked_count + 1 where id = p_target;

  v_ci := record_check_in(p_booking, 'instructor');

  -- The vacated source seat opens to the waitlist, as an ordinary cancellation
  -- would — without charging the member.
  perform offer_waitlist_seat(v_src.id);

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (v_tgt.studio_id, auth.uid(), 'booking.moved_by_staff', 'bookings', p_booking,
          jsonb_build_object('from_occurrence', v_src.id, 'to_occurrence', p_target,
                             'member_id', v_b.member_id));

  return jsonb_build_object('ok', true, 'booking_id', p_booking, 'member_id', v_b.member_id,
    'checked_in', coalesce((v_ci ->> 'ok')::boolean, false));
end $$;
revoke execute on function move_booking_here(uuid, uuid) from public, anon;
grant  execute on function move_booking_here(uuid, uuid) to authenticated, service_role;

-- ===========================================================================
-- 10. my_desk_payments — the instructor's end-of-day reconciliation list.
--     Money they took at the desk for the studio; NOT their pay. Scoped by
--     recorded_by = the caller, so it needs no studio arg and no guard.
-- ===========================================================================
create or replace function my_desk_payments()
returns table(paid_at timestamptz, member_name text, amount_cents int, currency text, method text, reference text, kind text)
language sql stable security definer set search_path = public as $$
  select p.paid_at,
         m.first_name || ' ' || m.last_name,
         p.amount_cents, p.currency::text, p.method, p.reference,
         case when p.booking_id is not null then 'drop-in'
              when p.membership_id is not null then 'plan'
              when p.group_purchase_id is not null then 'group'
              else 'payment' end
    from payments p
    left join members m on m.id = p.member_id
   where p.recorded_by = auth.uid()
     and p.provider = 'manual'
     and p.paid_at >= now() - interval '60 days'
   order by p.paid_at desc
$$;
revoke execute on function my_desk_payments() from public, anon;
grant  execute on function my_desk_payments() to authenticated, service_role;

-- ===========================================================================
-- 10b. instructor_roster_pay — the per-booking pay state for the roster's
--      "Unpaid — {amount}" marker + payment buttons. An instructor is denied
--      `payments` by RLS (§14), so this instructor-scoped reader supplies the
--      paid/unpaid + live drop-in price the roster cannot read directly.
-- ===========================================================================
create or replace function instructor_roster_pay(p_occurrence uuid)
returns table(booking_id uuid, member_id uuid, member_name text, payment_source text, paid boolean, due_cents int)
language plpgsql stable security definer set search_path = public as $$
declare v_scope text; v_occ class_occurrences%rowtype; v_due int;
begin
  v_scope := instructor_scope(p_occurrence);
  if v_scope is not null then raise exception '%', v_scope using errcode = 'PT403'; end if;
  select * into v_occ from class_occurrences where id = p_occurrence;
  select price_cents into v_due from membership_plans
    where studio_id = v_occ.studio_id and type = 'drop_in'
      and visibility = 'public' and status = 'active'
    order by price_cents asc limit 1;
  return query
    select b.id, b.member_id, m.first_name || ' ' || m.last_name, b.payment_source::text,
           exists (select 1 from payments p where p.booking_id = b.id
                     and p.status in ('succeeded','partially_refunded')),
           case when b.payment_source = 'drop_in' then v_due end
      from bookings b join members m on m.id = b.member_id
     where b.occurrence_id = p_occurrence and b.status in ('booked','attended');
end $$;
revoke execute on function instructor_roster_pay(uuid) from public, anon;
grant  execute on function instructor_roster_pay(uuid) to authenticated, service_role;

-- ===========================================================================
-- 11. walk_in_welcome template — welcome + set-your-password + today's class +
--     the amount DUE at the desk (sent at add-time, before any payment). In the
--     80a frame via render_notification; {accent}/{accent_on} are filled there.
-- ===========================================================================
insert into notification_templates (key, subject, text_body, html_body, note) values (
 'walk_in_welcome',
 'Welcome to {studio_name} — you''re in',
 E'Hi {first_name},\n\n{studio_name} has set up your account and booked you into {class_name} ({class_when}).\n\nChoose a password to see your history and show your check-in code:\n\n{claim_url}\n\n{due_line}\n\nSee you in class,\n{studio_name}',
 '<p>Hi {first_name},</p>'
 '<p><strong>{studio_name}</strong> has set up your account and booked you into <strong>{class_name}</strong> ({class_when}).</p>'
 '<p><a href="{claim_url}" style="display:inline-block;background:{accent};color:{accent_on};text-decoration:none;padding:12px 22px;border-radius:10px;font-weight:600">Set your password</a></p>'
 '<p>{due_line}</p>'
 '<p>See you in class,<br>{studio_name}</p>',
 'Decision 81a. The one email a walk-in gets, in the studio frame. {due_line} is '
 'empty unless a drop-in is owed, and the email is sent when the walk-in is added '
 '— before any payment — so it states what is DUE at the desk, not what was paid.')
on conflict (key) do update
  set subject = excluded.subject, text_body = excluded.text_body,
      html_body = excluded.html_body, note = excluded.note;

-- ===========================================================================
-- The anon surface is unchanged: THIRTEEN, and none of the above is anon.
-- ===========================================================================
do $$
declare n int;
begin
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then
    raise exception 'anon surface is % (expected 13 — Decision 81a adds no anon function)', n;
  end if;
end $$;
