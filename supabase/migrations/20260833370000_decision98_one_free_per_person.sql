-- Decision 98 — one free class per person; + Decision 97 amendment (a) merge
-- trace on the kept profile; + Decision 92 amendment (b) remove a member from a class.
-- creates: normalise_name(text), normalise_phone(text, text),
--   member_has_had_free(uuid, uuid), same_person_match(uuid, uuid),
--   member_duplicates(uuid), recheck_free_first_duplicate(uuid),
--   tg_member_phone_recheck(), sweep_free_duplicate_holds(), staff_remove_booking(uuid, boolean, text),
--   member_merge_trace(uuid)
-- re-issues: free_first_eligibility_run(uuid, uuid, uuid), book_guest(uuid, text, text, text),
--   claim_member_account(text, text, text), sweep_unpaid_dropins(),
--   merge_members(uuid, uuid), member_activity(uuid, date, date),
--   convert_booking_to_free_first(uuid)
--
-- One free class per person: the once-ever guarantee keys on the email (migration
-- 158/163); a second email defeats it. This tests the PERSON — normalised full
-- name OR phone equal, within one studio — and adds a 'duplicate' refusal to the
-- free-first gate, a name-only refusal at guest-invite time, and a re-check hook
-- at claim and at phone-save (a member phone trigger) that flips an already-booked
-- free seat to a 24-hour paid-or-lose hold. The hold has its OWN hold_until column
-- and sweep step; held bookings are EXCLUDED from the 15-minute drop-in sweep
-- (whose window keys on booked_at and would cancel a re-flagged seat at once).
-- Nothing retroactive. 'Make this their free class' still overrides. Anon stays THIRTEEN.

-- ===========================================================================
-- Columns: the 24-hour duplicate hold.
-- ===========================================================================
alter table bookings
  add column if not exists hold_until  timestamptz,
  add column if not exists hold_reason text;

-- ===========================================================================
-- normalise_name — IMMUTABLE translate()-based accent strip (NOT unaccent, which
-- is not installed and is STABLE). Lower, strip accents, collapse whitespace.
-- ===========================================================================
create or replace function normalise_name(p text) returns text
language sql immutable set search_path = public as $$
  select nullif(
    btrim(regexp_replace(
      lower(translate(coalesce(p, ''),
        'ÀÁÂÃÄÅàáâãäåÈÉÊËèéêëÌÍÎÏìíîïÒÓÔÕÖØòóôõöøÙÚÛÜùúûüÑñÇçÝýÿ',
        'aaaaaaaaaaaaeeeeeeeeiiiiiiiioooooooooooouuuuuuuunnccyyy')),
      '\s+', ' ', 'g')),
    '');
$$;

-- normalise_phone — IMMUTABLE, mirrors lib/phone.mjs: PH 09/639/9 forms fold to
-- +639XXXXXXXXX; any other country keeps the digit string. Blank -> null, so a
-- blank phone never matches anything.
create or replace function normalise_phone(p_phone text, p_country text) returns text
language sql immutable set search_path = public as $$
  with d as (select regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g') as digits)
  select nullif(case
    when p_country = 'PH' then
      case
        when digits ~ '^09[0-9]{9}$'  then '+63' || substring(digits from 2)
        when digits ~ '^639[0-9]{9}$' then '+' || digits
        when digits ~ '^9[0-9]{9}$'   then '+63' || digits
        else nullif(digits, '') end
    else nullif(digits, '') end, '')
  from d;
$$;
revoke execute on function normalise_name(text)          from public, anon;
revoke execute on function normalise_phone(text, text)   from public, anon;
grant  execute on function normalise_name(text)          to authenticated, service_role;
grant  execute on function normalise_phone(text, text)   to authenticated, service_role;

-- ===========================================================================
-- member_has_had_free — a comp booking in a used state, or a self-signup free
-- first class (host-null guest pass). A timely-cancelled comp is NOT "had".
-- ===========================================================================
create or replace function member_has_had_free(p_studio_id uuid, p_member_id uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  -- "Had a free class" is a comp seat the member actually holds or used: a free
  -- first class is a comp booking (book_first_free writes both the comp booking
  -- AND the host-null pass), so the comp booking in a used state IS the test. A
  -- TIMELY-cancelled comp ('cancelled') is not counted — the gate restores it —
  -- so a lingering host-null pass must NOT be read as "had free" on its own.
  select exists (
    select 1 from bookings b
     where b.member_id = p_member_id and b.studio_id = p_studio_id
       and b.payment_source = 'comp'
       and b.status in ('booked','attended','no_show','late_cancelled'));
$$;
revoke execute on function member_has_had_free(uuid, uuid) from public, anon, authenticated;
grant  execute on function member_has_had_free(uuid, uuid) to service_role;

-- ===========================================================================
-- same_person_match — OTHER live members of the same studio who are the same
-- person: normalised full name equal OR normalised phone equal. Service-only.
-- ===========================================================================
create or replace function same_person_match(p_studio_id uuid, p_member_id uuid)
returns setof uuid
language sql stable security definer set search_path = public as $$
  with me as (
    select m.id, m.studio_id,
           normalise_name(coalesce(m.first_name, '') || ' ' || coalesce(m.last_name, '')) as nn,
           normalise_phone(m.phone, s.country) as np
      from members m join studios s on s.id = m.studio_id
     where m.id = p_member_id)
  select o.id
    from members o
    join me on o.studio_id = me.studio_id
    join studios s on s.id = o.studio_id
   where o.id <> me.id
     and o.deleted_at is null
     and (
       (me.nn is not null
          and normalise_name(coalesce(o.first_name, '') || ' ' || coalesce(o.last_name, '')) = me.nn)
       or (me.np is not null
          and normalise_phone(o.phone, s.country) = me.np));
$$;
revoke execute on function same_person_match(uuid, uuid) from public, anon, authenticated;
grant  execute on function same_person_match(uuid, uuid) to service_role;

-- member_duplicates — the staff "Possible duplicate" reader (desk-up). Returns
-- the OTHER members this one looks like, so the profile can offer a merge.
create or replace function member_duplicates(p_member_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid;
begin
  select studio_id into v_studio from members where id = p_member_id;
  if v_studio is null then raise exception 'no such member' using errcode = 'PT404'; end if;
  if not coalesce(is_desk_up(v_studio), false) and not is_service_context() then
    raise exception 'that is not yours to read' using errcode = 'PT403';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', o.id, 'first_name', o.first_name, 'last_name', o.last_name,
             'email', o.email, 'had_free', member_has_had_free(v_studio, o.id))
             order by o.created_at)
      from members o
     where o.id in (select same_person_match(v_studio, p_member_id))), '[]'::jsonb);
end $$;
revoke execute on function member_duplicates(uuid) from public, anon;
grant  execute on function member_duplicates(uuid) to authenticated, service_role;

-- member_merge_trace — Decision 97(a). The merges INTO this member, read from the
-- member.merged audit rows (audit_logs is owner-only, so a desk-up definer reads
-- it). Carries the removed names + email + the staff first name, which survive
-- the removed member's scrub.
create or replace function member_merge_trace(p_member_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid;
begin
  select studio_id into v_studio from members where id = p_member_id;
  if v_studio is null then raise exception 'no such member' using errcode = 'PT404'; end if;
  if not coalesce(is_desk_up(v_studio), false) and not is_service_context() then
    raise exception 'that is not yours to read' using errcode = 'PT403';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'removed_first', al.before->>'removed_first',
             'removed_last',  al.before->>'removed_last',
             'removed_email', al.before->>'removed_email',
             'at', al.created_at,
             'staff_first', coalesce(nullif(split_part(pr.full_name, ' ', 1), ''), 'the studio'))
             order by al.created_at desc)
      from audit_logs al
      left join profiles pr on pr.id = al.actor_user_id
     where al.studio_id = v_studio and al.action = 'member.merged'
       and (al.after->>'merged_into')::uuid = p_member_id), '[]'::jsonb);
end $$;
revoke execute on function member_merge_trace(uuid) from public, anon;
grant  execute on function member_merge_trace(uuid) to authenticated, service_role;

-- ===========================================================================
-- recheck_free_first_duplicate — the claim / phone-save hook. If this member is
-- now a same-person twin of someone who has had a free class, flip their own
-- still-booked free first class to a 24-hour paid-or-lose hold and email them.
-- Keying the flip on status booked -> pending_payment fires no harmful trigger:
-- queue/cancel-notify act only on ->booked / ->cancelled, guest-sync only on
-- ->cancelled/attended, peak returns on null membership, infraction and desk-pay
-- only on no_show/late. booked_count stays correct (occurrence_seats_taken counts
-- pending_payment too). Idempotent: a seat already held is not re-flipped.
-- ===========================================================================
create or replace function recheck_free_first_duplicate(p_member_id uuid)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_m members%rowtype; v_studio uuid; v_s studios%rowtype; v_st studio_settings%rowtype;
  v_bk bookings%rowtype; v_occ class_occurrences%rowtype;
  v_hold timestamptz; v_fmt text; v_when text; v_class text;
begin
  select * into v_m from members where id = p_member_id;
  if not found then return false; end if;
  v_studio := v_m.studio_id;

  if not exists (select 1 from same_person_match(v_studio, p_member_id) sp
                  where member_has_had_free(v_studio, sp)) then
    return false;
  end if;

  select b.* into v_bk
    from bookings b
    join class_occurrences o on o.id = b.occurrence_id
    join guest_passes gp on gp.guest_booking_id = b.id and gp.host_member_id is null
   where b.member_id = p_member_id and b.studio_id = v_studio
     and b.payment_source = 'comp' and b.status = 'booked'
     and b.hold_until is null and o.starts_at > now()
   order by o.starts_at
   limit 1;
  if not found then return false; end if;

  v_hold := now() + interval '24 hours';
  update bookings
     set status = 'pending_payment', payment_source = 'drop_in',
         hold_until = v_hold, hold_reason = 'free_class_duplicate'
   where id = v_bk.id;

  select * into v_occ from class_occurrences where id = v_bk.occurrence_id;
  select * into v_s   from studios          where id = v_studio;
  select * into v_st  from studio_settings  where studio_id = v_studio;
  v_fmt   := coalesce(v_st.time_format, '24h');
  v_class := coalesce((select name from class_types where id = v_occ.class_type_id), v_occ.name, 'your class');
  v_when  := to_char(v_occ.starts_at at time zone v_s.timezone, 'FMDay FMDD FMMon')
             || ' at ' || fmt_clock(v_occ.starts_at, v_s.timezone, v_fmt);

  perform queue_notification(v_studio, p_member_id, 'free_class_duplicate',
    jsonb_build_object(
      'first_name',  v_m.first_name,
      'studio_name', v_s.name,
      'class_name',  v_class,
      'when',        v_when,
      'hold_time',   fmt_clock(v_hold, v_s.timezone, v_fmt) || ' on '
                     || to_char(v_hold at time zone v_s.timezone, 'FMDay FMDD FMMon'),
      'checkout_url','https://' || v_s.slug || '.'
                     || coalesce(notification_setting('member_app_domain'), 'studiior.app')
                     || '/checkout/' || v_bk.occurrence_id),
    'free_class_duplicate:' || v_bk.id);
  return true;
end $$;
revoke execute on function recheck_free_first_duplicate(uuid) from public, anon, authenticated;
grant  execute on function recheck_free_first_duplicate(uuid) to service_role;

-- A phone saved or changed re-runs the check (Decision 94's phone sheet, import,
-- staff edit — every path). claim_member_account calls it explicitly (below).
create or replace function tg_member_phone_recheck() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.phone is distinct from old.phone and nullif(btrim(coalesce(new.phone, '')), '') is not null then
    perform recheck_free_first_duplicate(new.id);
  end if;
  return new;
end $$;
revoke execute on function tg_member_phone_recheck() from public, anon, authenticated;
drop trigger if exists members_phone_recheck on members;
create trigger members_phone_recheck after update of phone on members
  for each row execute function tg_member_phone_recheck();


-- === free_first_eligibility_run (re-issued from 20260833290000 + 'duplicate') ===

create or replace function free_first_eligibility_run(
  p_studio_id uuid, p_member_id uuid, p_exclude_booking uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_member members%rowtype;
  v_has_hostnull  boolean;
  v_noshow        int;
  v_late_cancel   int;
  v_comp_attended int;
  v_comp_live     int;
  v_other_qual    int;
  v_has_membership boolean;
  -- Decision 30(d, continued): a studio-independent cut-over. Late cancels on or
  -- after this use the free class; earlier ones are not reassessed.
  v_cutover constant timestamptz := '2026-11-09 00:00:00+00';
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

  -- Decision 98: one free class per person. If a same-person twin (normalised
  -- name OR phone) of this member has already had a free class, this one is a
  -- duplicate. 'Make this their free class' overrides it (convert_booking_to_free_first).
  if exists (select 1 from same_person_match(p_studio_id, p_member_id) sp
              where member_has_had_free(p_studio_id, sp)) then
    return jsonb_build_object('ok', false, 'reason', 'duplicate');
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
      count(*) filter (where b.payment_source = 'comp' and b.status = 'late_cancelled'
                         and b.cancelled_at >= v_cutover),
      count(*) filter (where b.payment_source = 'comp' and b.status = 'attended'),
      count(*) filter (where b.payment_source = 'comp' and b.status in ('booked','waitlisted','pending_payment')),
      count(*) filter (where b.payment_source <> 'comp' and b.status in ('booked','waitlisted','attended','no_show','pending_payment'))
      into v_noshow, v_late_cancel, v_comp_attended, v_comp_live, v_other_qual
      from bookings b
     where b.member_id = p_member_id and b.studio_id = p_studio_id
       and (p_exclude_booking is null or b.id <> p_exclude_booking);
    v_has_membership := exists (select 1 from memberships ms where ms.member_id = p_member_id);

    if v_comp_attended > 0 or v_has_membership or v_comp_live > 0 or v_other_qual > 0 then
      return jsonb_build_object('ok', false, 'reason', 'already_had_free');
    elsif v_noshow >= 1 then
      -- Decision 30 (d): one no-show uses the free class.
      return jsonb_build_object('ok', false, 'reason', 'missed');
    elsif v_late_cancel >= 1 then
      -- Decision 30 (d, continued): a late cancel on/after the cut-over uses it.
      return jsonb_build_object('ok', false, 'reason', 'late_cancel');
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


-- === book_guest (re-issued from 20260832120000 + name-only duplicate refusal) ===

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



-- === claim_member_account (re-issued from 20260830370000 + Decision 98 recheck hook) ===

create or replace function claim_member_account(
  p_token     text,
  p_password  text,
  p_full_name text default null
) returns member_claim
language plpgsql security definer set search_path = public, extensions as $$
declare
  inv    member_invites%rowtype;
  m      members%rowtype;
  s      studios%rowtype;
  v_user uuid := gen_random_uuid();
begin
  select * into inv from member_invites
   where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex');
  if not found then
    return (null, null, null, null, 'invalid_token')::member_claim;
  end if;
  if inv.accepted_at is not null then
    return (null, null, null, null, 'token_used')::member_claim;
  end if;
  if inv.expires_at <= now() then
    return (null, null, null, null, 'token_expired')::member_claim;
  end if;
  if length(coalesce(p_password, '')) < 8 then
    return (null, null, null, null, 'password_too_short')::member_claim;
  end if;

  select * into m from members where id = inv.member_id;
  select * into s from studios  where id = inv.studio_id;

  if m.user_id is not null then
    return (null, null, null, null, 'already_claimed')::member_claim;
  end if;

  -- One email is one account, project-wide: auth.users carries a global unique
  -- index on it. If this person already has a login — because they are a
  -- member of another studio — the invite links the existing account to this
  -- member row rather than trying to mint a second one that Postgres would
  -- refuse anyway.
  select id into v_user from auth.users where lower(email) = lower(inv.email);

  if v_user is null then
    v_user := gen_random_uuid();
    insert into auth.users (
      id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
      created_at, updated_at,
      confirmation_token, recovery_token, email_change, email_change_token_new,
      email_change_token_current, phone_change, phone_change_token,
      reauthentication_token
    ) values (
      v_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
      inv.email, crypt(p_password, gen_salt('bf')), now(),
      now(), now(), '', '', '', '', '', '', '', ''
    );
    insert into profiles (id, email, full_name)
    values (v_user, inv.email,
            coalesce(nullif(btrim(p_full_name), ''), m.first_name || ' ' || m.last_name));
  else
    insert into profiles (id, email, full_name)
    values (v_user, inv.email, m.first_name || ' ' || m.last_name)
    on conflict (id) do nothing;
  end if;

  update members set user_id = v_user where id = m.id;
  update member_invites set accepted_at = now(), accepted_by = v_user where id = inv.id;

  -- Decision 98 (a new hook): the claim re-checks for a duplicate free class
  -- (a twin may have taken theirs since this member booked).
  perform recheck_free_first_duplicate(inv.member_id);

  return (v_user, m.id, s.slug, inv.email, null)::member_claim;
end $$;


-- === sweep_unpaid_dropins (re-issued from 20260830470000 + exclude Decision 98 holds) ===

create or replace function sweep_unpaid_dropins() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r record;
  n_cancelled int := 0;
  n_offered   int := 0;
  v_res       cancel_result;
begin
  if not is_service_context() then
    raise exception 'the drop-in sweep runs as the backend, not as a user'
      using errcode = 'PT403';
  end if;

  for r in
    select b.id, b.studio_id
      from bookings b
      join studio_settings st on st.studio_id = b.studio_id
     where b.status = 'pending_payment'
       and b.hold_until is null  -- Decision 98: free-class holds have their own 24h sweep
       and b.booked_at < now()
           - make_interval(mins => coalesce(st.dropin_payment_window_minutes, 15))
  loop
    begin
      v_res := cancel_booking(r.id);
      n_cancelled := n_cancelled + 1;
      if v_res.offer_made then
        n_offered := n_offered + 1;
      end if;

      -- The abandoned charge, marked so it stops looking like money in flight.
      update payments
         set status = 'failed',
             failure_code = 'checkout_abandoned',
             failure_message = 'The member did not finish paying inside the window.',
             updated_at = now()
       where booking_id = r.id and status = 'pending';
    exception when others then
      -- One studio's bad row must not stop every other studio's sweep, the same
      -- reasoning as a missing API key not taking the notification cron down.
      raise warning 'sweep_unpaid_dropins: booking % failed: %', r.id, sqlerrm;
    end;
  end loop;

  return jsonb_build_object('cancelled', n_cancelled, 'waitlist_offers', n_offered);
end $$;

revoke execute on function sweep_unpaid_dropins() from public, anon, authenticated;
grant execute on function sweep_unpaid_dropins() to service_role;

-- ===========================================================================
-- sweep_free_duplicate_holds — Decision 98's OWN 24-hour sweep. Cancels a
-- free-class-duplicate hold whose window has run out, through cancel_booking()
-- so the seat offers itself to the waitlist like any other. Hourly.
-- ===========================================================================
create or replace function sweep_free_duplicate_holds() returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; v_res cancel_result;
begin
  if not is_service_context() then
    raise exception 'the free-class hold sweep runs as the backend, not as a user'
      using errcode = 'PT403';
  end if;
  for r in
    select b.id from bookings b
     where b.hold_reason = 'free_class_duplicate'
       and b.status = 'pending_payment'
       and b.hold_until is not null and b.hold_until < now()
  loop
    begin
      v_res := cancel_booking(r.id);
      n := n + 1;
    exception when others then
      raise warning 'sweep_free_duplicate_holds: booking % failed: %', r.id, sqlerrm;
    end;
  end loop;
  return jsonb_build_object('cancelled', n);
end $$;
revoke execute on function sweep_free_duplicate_holds() from public, anon, authenticated;
grant  execute on function sweep_free_duplicate_holds() to service_role;

do $$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron missing; free-class duplicate holds will not sweep.';
    return;
  end if;
  create extension if not exists pg_cron;
  if exists (select 1 from cron.job where jobname = 'studiior-free-duplicate-holds') then
    perform cron.unschedule('studiior-free-duplicate-holds');
  end if;
  perform cron.schedule('studiior-free-duplicate-holds', '7 * * * *',
    $job$select sweep_free_duplicate_holds()$job$);
end $$;

-- ===========================================================================
-- Templates (Decision 80a frame; per-email switch via queue_notification).
-- ===========================================================================
insert into notification_templates (key, subject, text_body, html_body, note) values (
 'free_class_duplicate',
 'Your {class_name} spot needs payment ({studio_name})',
 E'Hi {first_name},\n\nThis class is no longer free on your account, because it looks like you have taken a free class with us before. Pay to keep your spot in {class_name} on {when} before {hold_time}, or it will be released.\n\nPay now: {checkout_url}\n\nSee you in class,\n{studio_name}',
 '<p>Hi {first_name},</p>'
 '<p>This class is no longer free on your account, because it looks like you have taken a free class with us before. Pay to keep your spot in <strong>{class_name}</strong> on {when} before {hold_time}, or it will be released.</p>'
 '<p><a href="{checkout_url}" style="display:inline-block;background:{accent};color:{accent_on};text-decoration:none;padding:12px 22px;border-radius:10px;font-weight:600">Pay to keep my spot</a></p>'
 '<p>See you in class,<br>{studio_name}</p>',
 'Decision 98. Sent when a free first class is re-flagged as a duplicate and held 24h. '
 'Tokens: first_name, class_name, when, hold_time, checkout_url, studio_name.')
on conflict (key) do update
  set subject = excluded.subject, text_body = excluded.text_body,
      html_body = excluded.html_body, note = excluded.note;

insert into notification_templates (key, subject, text_body, html_body, note) values (
 'booking_removed_by_studio',
 '{studio_name} took you off {class_name} on {day}',
 E'Hi {first_name},\n\n{studio_name} has taken you off {class_name} on {when}.{note_line}{credit_line}\n\nSee what else is on: {book_url}\n\n{studio_name}',
 '<p>Hi {first_name},</p>'
 '<p>{studio_name} has taken you off <strong>{class_name}</strong> on {when}.{note_html}{credit_html}</p>'
 '<p><a href="{book_url}" style="display:inline-block;background:{accent};color:{accent_on};text-decoration:none;padding:12px 22px;border-radius:10px;font-weight:600">See what is on</a></p>'
 '<p>{studio_name}</p>',
 'Decision 92(b). Sent when desk-up staff remove a member from a class. Tokens: '
 'first_name, studio_name, class_name, when, day, note_line, note_html, credit_line, credit_html, book_url.')
on conflict (key) do update
  set subject = excluded.subject, text_body = excluded.text_body,
      html_body = excluded.html_body, note = excluded.note;

-- ===========================================================================
-- staff_remove_booking — Decision 92(b). Desk-up removes ONE booking from a
-- roster. p_return on: a no-penalty cancel (free_cancel_until set first, credit
-- or free class returned, seat freed, waitlist promoted). p_return off: a late
-- cancel (cancel_booking decides late inside the cutoff). One email, audit row,
-- and a Journey row (member_activity reads the audit row).
-- ===========================================================================
create or replace function staff_remove_booking(p_booking_id uuid, p_return boolean default true, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  b bookings%rowtype; o class_occurrences%rowtype; v_s studios%rowtype; v_st studio_settings%rowtype;
  m members%rowtype; v_staff text; v_fmt text; v_when text; v_day text; v_class text;
  v_note_line text := ''; v_note_html text := ''; v_credit_line text; v_credit_html text;
begin
  select * into b from bookings where id = p_booking_id;
  if not found then raise exception 'no such booking' using errcode = 'PT404'; end if;
  if not coalesce(is_desk_up(b.studio_id), false) and not is_service_context() then
    raise exception 'only studio staff remove a booking' using errcode = 'PT403';
  end if;
  if b.status not in ('booked','waitlisted','pending_payment') then
    raise exception 'This booking is not live.' using errcode = 'PT409';
  end if;
  select * into o from class_occurrences where id = b.occurrence_id;
  if o.starts_at <= now() then
    raise exception 'That class has already started.' using errcode = 'PT409';
  end if;
  if exists (select 1 from check_ins ci where ci.booking_id = p_booking_id) then
    raise exception 'They have already checked in.' using errcode = 'PT409';
  end if;

  if p_return then
    update bookings set free_cancel_until = now() + interval '1 hour' where id = p_booking_id;
  end if;
  perform cancel_booking(p_booking_id);

  -- Compose the email.
  select * into m    from members where id = b.member_id;
  select * into v_s  from studios where id = b.studio_id;
  select * into v_st from studio_settings where studio_id = b.studio_id;
  v_fmt   := coalesce(v_st.time_format, '24h');
  v_class := coalesce((select name from class_types where id = o.class_type_id), o.name, 'a class');
  v_day   := to_char(o.starts_at at time zone v_s.timezone, 'FMDay FMDD FMMon');
  v_when  := v_day || ' at ' || fmt_clock(o.starts_at, v_s.timezone, v_fmt);
  v_staff := coalesce(nullif(split_part((select full_name from profiles where id = auth.uid()), ' ', 1), ''),
                      'the studio');
  if nullif(btrim(coalesce(p_note, '')), '') is not null then
    v_note_line := ' ' || btrim(p_note);
    v_note_html := ' ' || btrim(p_note);
  end if;
  if p_return then
    v_credit_line := ' Your credit or free class is back on your account.';
    v_credit_html := ' Your credit or free class is back on your account.';
  else
    v_credit_line := ''; v_credit_html := '';
  end if;

  perform queue_notification(b.studio_id, b.member_id, 'booking_removed_by_studio',
    jsonb_build_object(
      'first_name', m.first_name, 'studio_name', v_s.name,
      'class_name', v_class, 'when', v_when, 'day', v_day,
      'note_line', v_note_line, 'note_html', v_note_html,
      'credit_line', v_credit_line, 'credit_html', v_credit_html,
      'book_url', 'https://' || v_s.slug || '.'
                  || coalesce(notification_setting('member_app_domain'), 'studiior.app') || '/book'),
    'booking_removed_by_studio:' || p_booking_id);

  -- Audit + the Journey row (member_activity reads this).
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
    values (b.studio_id, auth.uid(), 'booking.removed_by_staff', 'bookings', p_booking_id,
            jsonb_build_object('member_id', b.member_id, 'occurrence_id', b.occurrence_id, 'returned', p_return),
            jsonb_build_object('class_name', v_class, 'when', v_when, 'staff_first', v_staff,
                               'returned', p_return, 'note', nullif(btrim(coalesce(p_note, '')), '')));

  return jsonb_build_object('ok', true, 'returned', p_return, 'class_name', v_class, 'when', v_when);
end $$;
revoke execute on function staff_remove_booking(uuid, boolean, text) from public, anon;
grant  execute on function staff_remove_booking(uuid, boolean, text) to authenticated, service_role;


-- === merge_members (re-issued from 20260833360000 + removed names in the audit, Decision 97(a)) ===

create or replace function merge_members(p_keep uuid, p_remove uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  k members%rowtype; r members%rowtype; v_studio uuid;
  rec record; v_keep_thread uuid; v_remove_thread uuid;
  v_tbl text;
  v_moved jsonb;
  plain_tables constant text[] := array[
    'ai_draft_usage','bookings','check_ins','credit_ledger','group_bookings',
    'member_contacts','member_documents','member_goals','member_infractions',
    'member_notes','memberships','messages','notifications','payments',
    'peak_allowance_ledger','product_orders','promo_redemptions','timeline_events',
    'waiver_signatures','xendit_purchases'];
begin
  select * into k from members where id = p_keep for update;
  select * into r from members where id = p_remove for update;
  if k.id is null or r.id is null then
    raise exception 'no such member' using errcode = 'PT404';
  end if;
  v_studio := k.studio_id;
  if not coalesce(is_manager_up(v_studio), false) then
    raise exception 'only owners and managers merge members' using errcode = 'PT403';
  end if;
  if p_keep = p_remove then
    raise exception 'A member cannot be merged into itself.' using errcode = 'PT409';
  end if;
  if k.studio_id <> r.studio_id then
    raise exception 'Members from different studios cannot be merged.' using errcode = 'PT409';
  end if;
  if k.deleted_at is not null or r.deleted_at is not null then
    raise exception 'A deleted member cannot be merged.' using errcode = 'PT409';
  end if;
  if member_is_staff_login(p_keep) or member_is_staff_login(p_remove) then
    raise exception 'A member with a staff or instructor login cannot be merged.' using errcode = 'PT409';
  end if;

  -- Count what moves (before the move), for the audit row.
  v_moved := jsonb_build_object(
    'bookings',  (select count(*) from bookings where member_id = p_remove),
    'payments',  (select count(*) from payments where member_id = p_remove),
    'credits',   (select count(*) from credit_ledger where member_id = p_remove),
    'check_ins', (select count(*) from check_ins where member_id = p_remove));

  -- 1. Booking collisions: the same occurrence booked live by both keeps the
  --    earlier booking and removes the later. A future class cancels through the
  --    normal path with no penalty; a past class drops the later duplicate row.
  for rec in
    select rb.id as remove_bk, kb.id as keep_bk, rb.booked_at as r_at, kb.booked_at as k_at,
           o.starts_at
      from bookings rb
      join bookings kb on kb.occurrence_id = rb.occurrence_id and kb.member_id = p_keep
      join class_occurrences o on o.id = rb.occurrence_id
     where rb.member_id = p_remove
       and rb.status in ('booked','waitlisted','attended','no_show','pending_payment')
       and kb.status in ('booked','waitlisted','attended','no_show','pending_payment')
  loop
    if rec.starts_at > now() then
      if rec.r_at <= rec.k_at then
        update bookings set free_cancel_until = now() + interval '1 hour' where id = rec.keep_bk;
        perform cancel_booking(rec.keep_bk);
      else
        update bookings set free_cancel_until = now() + interval '1 hour' where id = rec.remove_bk;
        perform cancel_booking(rec.remove_bk);
      end if;
    else
      -- Past collision: keep the earlier, delete the later duplicate.
      if rec.r_at <= rec.k_at then delete from bookings where id = rec.keep_bk;
      else delete from bookings where id = rec.remove_bk; end if;
    end if;
  end loop;

  -- 2. Message threads fold into the kept member's thread.
  select id into v_keep_thread   from message_threads where studio_id = v_studio and member_id = p_keep;
  select id into v_remove_thread from message_threads where studio_id = v_studio and member_id = p_remove;
  if v_remove_thread is not null then
    if v_keep_thread is not null then
      update thread_messages set thread_id = v_keep_thread where thread_id = v_remove_thread;
      delete from message_threads where id = v_remove_thread;
    else
      update message_threads set member_id = p_keep where id = v_remove_thread;
    end if;
  end if;

  -- 3. One-row-per-(member, x) tables: drop the removed member's colliding rows,
  --    keeping the kept member's, then move the rest.
  delete from notification_preferences rr where rr.member_id = p_remove
    and exists (select 1 from notification_preferences kk where kk.member_id = p_keep);
  update notification_preferences set member_id = p_keep where member_id = p_remove;

  delete from member_payment_customers rr where rr.member_id = p_remove
    and exists (select 1 from member_payment_customers kk where kk.member_id = p_keep and kk.provider = rr.provider);
  update member_payment_customers set member_id = p_keep where member_id = p_remove;

  delete from member_tasks rr where rr.member_id = p_remove and rr.status = 'open'
    and exists (select 1 from member_tasks kk where kk.member_id = p_keep and kk.status = 'open' and kk.kind = rr.kind);
  update member_tasks set member_id = p_keep where member_id = p_remove;

  delete from member_invites rr where rr.member_id = p_remove and rr.accepted_at is null
    and exists (select 1 from member_invites kk where kk.member_id = p_keep and kk.accepted_at is null);
  update member_invites set member_id = p_keep where member_id = p_remove;

  delete from challenge_participants rr where rr.member_id = p_remove
    and exists (select 1 from challenge_participants kk where kk.member_id = p_keep and kk.challenge_id = rr.challenge_id);
  update challenge_participants set member_id = p_keep where member_id = p_remove;

  delete from challenge_progress_events rr where rr.member_id = p_remove
    and exists (select 1 from challenge_progress_events kk where kk.member_id = p_keep
                 and kk.challenge_id = rr.challenge_id and kk.booking_id is not distinct from rr.booking_id);
  update challenge_progress_events set member_id = p_keep where member_id = p_remove;

  delete from member_achievements rr where rr.member_id = p_remove
    and exists (select 1 from member_achievements kk where kk.member_id = p_keep and kk.definition_id = rr.definition_id);
  update member_achievements set member_id = p_keep where member_id = p_remove;

  delete from announcement_dismissals rr where rr.member_id = p_remove
    and exists (select 1 from announcement_dismissals kk where kk.member_id = p_keep and kk.announcement_id = rr.announcement_id);
  update announcement_dismissals set member_id = p_keep where member_id = p_remove;

  delete from member_dismissals rr where rr.member_id = p_remove
    and exists (select 1 from member_dismissals kk where kk.member_id = p_keep and kk.key = rr.key);
  update member_dismissals set member_id = p_keep where member_id = p_remove;

  delete from campaign_recipients rr where rr.member_id = p_remove
    and exists (select 1 from campaign_recipients kk where kk.member_id = p_keep and kk.campaign_id = rr.campaign_id);
  update campaign_recipients set member_id = p_keep where member_id = p_remove;

  delete from member_tag_assignments rr where rr.member_id = p_remove
    and exists (select 1 from member_tag_assignments kk where kk.member_id = p_keep and kk.tag_id = rr.tag_id);
  update member_tag_assignments set member_id = p_keep where member_id = p_remove;

  -- guest_passes: the host side can collide on the one-live-per-host index.
  delete from guest_passes rr where rr.host_member_id = p_remove and rr.status in ('invited','confirmed')
    and exists (select 1 from guest_passes kk where kk.host_member_id = p_keep and kk.status in ('invited','confirmed'));
  update guest_passes set host_member_id = p_keep where host_member_id = p_remove;
  update guest_passes set guest_member_id = p_keep where guest_member_id = p_remove;

  -- 4. Plain re-points (member_id, no member-level unique).
  foreach v_tbl in array plain_tables loop
    execute format('update %I set member_id = $1 where member_id = $2', v_tbl) using p_keep, p_remove;
  end loop;
  -- Differently-named columns.
  update gift_cards      set purchaser_member_id = p_keep where purchaser_member_id = p_remove;
  update group_purchases set host_member_id      = p_keep where host_member_id = p_remove;

  -- 5. Semantic folds on the kept member: earliest waiver, marketing on if either.
  update members set
    waiver_signed_at = least(k.waiver_signed_at, r.waiver_signed_at),
    marketing_opt_in = (k.marketing_opt_in or r.marketing_opt_in)
  where id = p_keep;

  -- 6. Scrub the removed member, no email, merged_into the kept one.
  perform delete_member_run(p_remove, false, p_keep);

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
    values (v_studio, auth.uid(), 'member.merged', 'members', p_remove,
            jsonb_build_object('removed', p_remove, 'removed_email', r.email,
                               'removed_first', r.first_name, 'removed_last', r.last_name,
                               'moved', v_moved),
            jsonb_build_object('merged_into', p_keep, 'kept_email', k.email));

  return jsonb_build_object('ok', true, 'kept', p_keep, 'removed', p_remove, 'moved', v_moved);
end $$;
revoke execute on function merge_members(uuid, uuid) from public, anon;
grant  execute on function merge_members(uuid, uuid) to authenticated, service_role;


-- === member_activity (re-issued from 20260833360000 + merged & removed-by-studio arms) ===

CREATE OR REPLACE FUNCTION public.member_activity(p_member_id uuid, p_from date, p_to date)
 RETURNS TABLE(at timestamp with time zone, kind text, title text, detail text, credit_delta integer, balance_after integer, amount_cents integer, currency text, occurrence_id uuid, booking_id uuid, membership_id uuid, plan_name text, due_cents integer, is_free_first boolean, occurrence_start timestamp with time zone, instructor_first text, credits_left_after integer, payment_method text, recorded_by_name text, plan_classes integer, plan_valid_to date, unused_credits integer, payment_source text, is_paid boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
declare v_studio uuid; v_is_staff boolean; v_owns boolean;
begin
  select studio_id into v_studio from members where id = p_member_id;
  if v_studio is null then raise exception 'no such member' using errcode = 'PT404'; end if;
  v_owns := exists (select 1 from members m where m.id = p_member_id and m.user_id = auth.uid());
  v_is_staff := coalesce(is_desk_up(v_studio), false) or is_service_context();
  if not (v_owns or v_is_staff) then
    raise exception 'that is not your statement' using errcode = 'PT403';
  end if;

  return query
  with led as (
    select cl.id, cl.delta, cl.reason::text as reason, cl.booking_id, cl.membership_id,
           cl.created_at,
           (sum(cl.delta) over (order by cl.created_at, cl.id))::int as bal,
           (sum(cl.delta) over (partition by cl.membership_id order by cl.created_at, cl.id))::int as membership_bal
      from credit_ledger cl
     where cl.member_id = p_member_id
  ),
  -- A purchase payment claims the Nth 'purchase' ledger row of its membership;
  -- a refunded payment claims the Nth negative 'manual' row of its membership.
  -- Rank joins, so each ledger id is claimed at most once; a grant with no
  -- payment (e.g. a complimentary membership) stays unclaimed and surfaces as its
  -- own "Credits added" line.
  purch_led as (
    select id, membership_id, row_number() over (partition by membership_id order by created_at, id) rn
      from led where reason = 'purchase' and membership_id is not null),
  purch_pay as (
    select p.id as payment_id, p.membership_id,
           row_number() over (partition by p.membership_id order by coalesce(p.paid_at, p.created_at), p.id) rn
      from payments p
     where p.member_id = p_member_id and p.membership_id is not null
       and p.status in ('succeeded', 'partially_refunded')),
  pay_grant as (
    select pp.payment_id, pl.id as ledger_id
      from purch_pay pp join purch_led pl on pl.membership_id = pp.membership_id and pl.rn = pp.rn),
  forfeit_led as (
    select id, membership_id, row_number() over (partition by membership_id order by created_at, id) rn
      from led where reason = 'manual' and delta < 0 and membership_id is not null),
  refund_pay as (
    select p.id as payment_id, p.membership_id,
           row_number() over (partition by p.membership_id order by coalesce(p.refunded_at, p.updated_at), p.id) rn
      from payments p
     where p.member_id = p_member_id and p.membership_id is not null
       and (p.refunded_at is not null or p.status in ('refunded', 'partially_refunded'))),
  pay_forfeit as (
    select rp.payment_id, fl.id as ledger_id
      from refund_pay rp join forfeit_led fl on fl.membership_id = rp.membership_id and fl.rn = rp.rn),
  ev as (
    -- Decision 95: a flex-rescue email was sent (staff only).
    select coalesce(nt.sent_at, nt.scheduled_for, nt.created_at) as at,
           'rescue_email' as kind, 'Rescue email sent' as title,
           case when nt.template_key = 'flex_rescue_2days'
                then 'Flex class still needs numbers'
                else 'Last call to move the booking' end as detail,
           null::uuid as ledger_id, null::int as amount_cents, null::text as currency,
           null::uuid as occurrence_id, null::uuid as booking_id, null::uuid as membership_id
      from notifications nt
     where nt.member_id = p_member_id and v_is_staff
       and nt.template_key in ('flex_rescue_2days','flex_rescue_final','free_rescue_2days','free_rescue_final')
    union all
    -- joined (staff only)
    select m.joined_on::timestamptz as at, 'joined' as kind, 'Joined the studio' as title,
           nullif('Came via ' || coalesce(m.source, ''), 'Came via ') as detail,
           null::uuid as ledger_id, null::int as amount_cents, null::text as currency,
           null::uuid as occurrence_id, null::uuid as booking_id, null::uuid as membership_id
      from members m where m.id = p_member_id and v_is_staff and m.joined_on is not null
    union all
    -- Decision 97: invited a guest (this member is the host). Derived from
    -- the invite snapshot, so it survives the guest's deletion or merge.
    select gp.invited_at as at, 'invited_guest' as kind,
           'Invited ' || coalesce(g.first_name, 'a guest') || ' to ' || coalesce(o.name, ct.name, 'a class') as title,
           null::text as detail,
           null::uuid as ledger_id, null::int as amount_cents, null::text as currency,
           gp.occurrence_id as occurrence_id, null::uuid as booking_id, null::uuid as membership_id
      from guest_passes gp
      join class_occurrences o on o.id = gp.occurrence_id
      left join class_types ct on ct.id = o.class_type_id
      left join members g on g.id = gp.guest_member_id
     where gp.host_member_id = p_member_id and gp.invited_at is not null
    union all
    -- Decision 97: invited by a host (this member is the guest). The host
    -- name is the invite snapshot, surviving the host's deletion or merge.
    select gp.invited_at as at, 'invited_by' as kind,
           'Invited by ' || coalesce(gp.host_name_at_invite, 'a member') as title,
           null::text as detail,
           null::uuid as ledger_id, null::int as amount_cents, null::text as currency,
           gp.occurrence_id as occurrence_id, null::uuid as booking_id, null::uuid as membership_id
      from guest_passes gp
     where gp.guest_member_id = p_member_id and gp.host_member_id is not null and gp.invited_at is not null
    union all
    -- Decision 97 (a): a member merged into this account (staff only). Read from
    -- the member.merged audit row so a past merge shows and the removed email survives.
    select al.created_at as at, 'merged' as kind,
           'Merged ' || coalesce(al.before->>'removed_email', 'an account') || ' into this account' as title,
           null::text as detail,
           null::uuid, null::int, null::text, null::uuid, null::uuid, null::uuid
      from audit_logs al
     where al.action = 'member.merged' and v_is_staff
       and (al.after->>'merged_into')::uuid = p_member_id
    union all
    -- Decision 92 (b): removed from a class by staff. From the audit row, so the
    -- class name and the staff first name survive.
    select al.created_at as at, 'removed_by_studio' as kind,
           'Removed from ' || coalesce(al.after->>'class_name', 'a class')
             || ' by ' || coalesce(al.after->>'staff_first', 'the studio') as title,
           null::text as detail,
           null::uuid, null::int, null::text, null::uuid, al.entity_id, null::uuid
      from audit_logs al
     where al.action = 'booking.removed_by_staff' and v_is_staff
       and (al.before->>'member_id')::uuid = p_member_id

    union all
    -- booked / waitlisted / free first
    select b.booked_at,
           case when b.status = 'waitlisted' then 'waitlisted'
                when b.payment_source = 'comp'
                     and exists (select 1 from guest_passes gp where gp.guest_booking_id = b.id and gp.host_member_id is null)
                     then 'free_first'
                else 'booked' end,
           case when b.status = 'waitlisted' then 'Joined the waitlist for ' || coalesce(o.name, 'a class')
                when b.payment_source = 'comp'
                     and exists (select 1 from guest_passes gp where gp.guest_booking_id = b.id and gp.host_member_id is null)
                     then 'Booked a free first class — ' || coalesce(o.name, 'a class')
                when b.payment_source = 'group' then
                     (select case when gb.is_host
                                  then 'Group booking — ' || coalesce(o.name, 'a class') || ' · ' || mp.name
                                  else 'Booked by ' || hm.first_name || ' · ' || mp.name end
                        from group_bookings gb
                        join group_purchases gpu on gpu.id = gb.group_purchase_id
                        join membership_plans mp on mp.id = gpu.plan_id
                        join members hm on hm.id = gpu.host_member_id
                       where gb.booking_id = b.id)
                else 'Booked ' || coalesce(o.name, 'a class') end,
           case when b.payment_source = 'group' then
                  (select case when gb.is_host then (
                            select string_agg(coalesce(nullif(m2.first_name,''), m2.email), ', ')
                              from group_bookings gb2 join members m2 on m2.id = gb2.member_id
                             where gb2.group_purchase_id = gb.group_purchase_id and not gb2.is_host)
                          end
                     from group_bookings gb where gb.booking_id = b.id)
                when exists (select 1 from waitlist_offers wo where wo.booking_id = b.id and wo.outcome = 'accepted')
                then 'From the waitlist' end,
           b.credit_entry_id, null, null, b.occurrence_id, b.id, b.membership_id
      from bookings b left join class_occurrences o on o.id = b.occurrence_id
     where b.member_id = p_member_id
       and b.status in ('booked','attended','no_show','cancelled','late_cancelled','waitlisted','pending_payment')
    union all
    -- cancelled (carries the cancellation_refund, or 0 "class used")
    select b.cancelled_at,
           case when b.release_reason = 'studio_released' then 'studio_cancelled'
                when b.status = 'late_cancelled' or b.is_late_cancel then 'late_cancelled'
                else 'cancelled' end,
           case when b.release_reason = 'studio_released' then 'Studio cancelled ' || coalesce(o.name, 'a class')
                when b.status = 'late_cancelled' or b.is_late_cancel then 'Cancelled late — ' || coalesce(o.name, 'a class')
                else 'Cancelled ' || coalesce(o.name, 'a class') end,
           case when b.release_reason = 'studio_released' then 'Credit returned'
                when (b.status = 'late_cancelled' or b.is_late_cancel)
                     and not exists (select 1 from led cl where cl.booking_id = b.id and cl.reason = 'cancellation_refund')
                then 'Class used' end,
           (select cl.id from led cl where cl.booking_id = b.id and cl.reason = 'cancellation_refund' order by cl.created_at, cl.id limit 1),
           null, null, b.occurrence_id, b.id, b.membership_id
      from bookings b left join class_occurrences o on o.id = b.occurrence_id
     where b.member_id = p_member_id and b.status in ('cancelled','late_cancelled')
       and not exists (select 1 from audit_logs al
                        where al.action = 'booking.removed_by_staff' and al.entity_id = b.id)
    union all
    -- checked in / attended
    select ci.checked_in_at, 'attended',
           case when o.id is null then 'Attended a class (imported)' else 'Attended ' || o.name end,
           null, null::uuid, null, null, ci.occurrence_id, ci.booking_id, null
      from check_ins ci left join class_occurrences o on o.id = ci.occurrence_id
     where ci.member_id = p_member_id
    union all
    -- no-show
    select coalesce(b.no_show_at, o.ends_at, b.updated_at), 'no_show',
           'Did not attend ' || coalesce(o.name, 'a class'), null,
           null::uuid, null, null, b.occurrence_id, b.id, b.membership_id
      from bookings b left join class_occurrences o on o.id = b.occurrence_id
     where b.member_id = p_member_id and b.status = 'no_show'
    union all
    -- purchase / refund / failed payment (carries the matched grant/forfeit)
    select coalesce(p.paid_at, p.created_at),
           case when p.refunded_at is not null or p.status in ('refunded','partially_refunded') then 'refund'
                when p.status = 'failed' then 'payment_failed'
                else 'purchase' end,
           case when p.refunded_at is not null or p.status in ('refunded','partially_refunded') then 'Refund — ' || coalesce(p.description, 'a payment')
                when p.status = 'failed' then 'Payment failed — ' || coalesce(p.description, 'a payment')
                else 'Bought ' || coalesce(p.description, 'a plan') end,
           null,
           case when p.refunded_at is not null or p.status in ('refunded','partially_refunded')
                then (select ledger_id from pay_forfeit pf where pf.payment_id = p.id)
                when p.status = 'failed' then null
                else (select ledger_id from pay_grant pg where pg.payment_id = p.id) end,
           case when p.refunded_at is not null then coalesce(p.refunded_cents, p.amount_cents) else p.amount_cents end,
           p.currency, null::uuid, p.booking_id, p.membership_id
      from payments p where p.member_id = p_member_id
    union all
    -- rescheduled / instructor changed, for occurrences the member holds a live booking on
    select oe.at,
           case when oe.kind = 'moved' then 'rescheduled' else 'instructor_changed' end,
           case when oe.kind = 'moved' then 'Class rescheduled — ' || coalesce(o.name, 'a class')
                else 'Instructor changed — ' || coalesce(o.name, 'a class') end,
           null, null::uuid, null, null, oe.occurrence_id, null, null
      from occurrence_events oe left join class_occurrences o on o.id = oe.occurrence_id
     where oe.kind in ('moved','instructor_changed')
       and exists (select 1 from bookings b where b.occurrence_id = oe.occurrence_id
                    and b.member_id = p_member_id and b.status <> 'cancelled')
    union all
    -- message_sent (staff only)
    select coalesce(msg.sent_at, msg.updated_at), 'message_sent', 'Message sent', msg.subject,
           null::uuid, null, null, null, null, null
      from messages msg
     where msg.member_id = p_member_id and v_is_staff and msg.status in ('queued','sent')
    union all
    -- contacted (staff only) — a task contacted the old way (no member_contacts
    -- row). A task linked to a contact (contact_id set) shows via the arm below.
    select mt.contacted_at, 'contacted', 'Contacted', mt.reason,
           null::uuid, null, null, null, null, null
      from member_tasks mt
     where mt.member_id = p_member_id and v_is_staff
       and mt.status = 'contacted' and mt.contacted_at is not null
       and mt.contact_id is null
    union all
    -- Decision 79: retention outreach logged in member_contacts (staff only).
    select mc.contacted_at, 'contacted',
           case when mc.method = 'email' then 'Emailed'
                when mc.method = 'viber' then 'Contacted (Viber)'
                when mc.method = 'call'  then 'Called'
                else 'Contacted (in person)' end
             || coalesce(' by ' || nullif(pr.full_name, ''), ''),
           mc.subject,
           null::uuid, null, null, null, null, null
      from member_contacts mc
      left join profiles pr on pr.id = mc.staff_id
     where mc.member_id = p_member_id and v_is_staff
    union all
    -- Decision 83 (a): a plan that ended (expired, or ended by staff) — NOT
    -- a refund, which tells its own story. Claims the end-forfeit ledger row
    -- so it is not also a bare "Credit adjustment"; unused = classes forfeited.
    select coalesce(ms2.cancelled_at, (ms2.expires_on)::timestamptz), 'plan_ended', 'Plan ended', null,
           (select cl.id from led cl
             where cl.membership_id = ms2.id and cl.reason = 'manual' and cl.delta < 0
               and cl.id not in (select ledger_id from pay_forfeit)
             order by cl.created_at desc, cl.id desc limit 1),
           null, null, null::uuid, null, ms2.id
      from memberships ms2
     where ms2.member_id = p_member_id
       and ms2.status in ('cancelled','expired')
       and coalesce(ms2.cancelled_at, (ms2.expires_on)::timestamptz) is not null
       and not exists (select 1 from payments p where p.membership_id = ms2.id
                        and (p.refunded_at is not null or p.status in ('refunded','partially_refunded')))
  ),
  claimed as (select distinct ledger_id from ev where ledger_id is not null),
  -- ledger rows no event claims: complimentary grants, manual adjustments,
  -- lockout, merch. Shown as their own credit lines.
  adj as (
    select l.created_at as at,
           case when l.reason = 'booking' then 'credit_used'
                when l.delta >= 0 then 'credits_added' else 'credit_adjustment' end as kind,
           case when l.reason = 'booking' then 'Class credit used'
                when l.reason = 'cancellation_refund' then 'Credit returned'
                when l.delta >= 0 then 'Credits added' else 'Credit adjustment' end as title,
           null::text as detail, l.id as ledger_id, null::int as amount_cents, null::text as currency,
           null::uuid as occurrence_id, l.booking_id, l.membership_id
      from led l where l.id not in (select ledger_id from claimed where ledger_id is not null)
  ),
  all_rows as (
    select * from ev
    union all
    select * from adj
  )
  select
    x.at, x.kind, x.title, x.detail,
    coalesce(l.delta, 0) as credit_delta,
    coalesce(l.bal,
             (select l2.bal from led l2 where l2.created_at <= x.at order by l2.created_at desc, l2.id desc limit 1),
             0) as balance_after,
    x.amount_cents, x.currency, x.occurrence_id, x.booking_id, x.membership_id,
    -- Decision 83. plan_name: the plan a booking drew from, a cancellation or a
    -- no-show consumed/returned to, or the ended plan. null on every other kind.
    case when x.kind in ('booked','cancelled','late_cancelled','studio_cancelled','no_show','plan_ended')
         then mp.name end as plan_name,
    -- due_cents: a LIVE unpaid drop-in booking only — the cheapest active public
    -- drop_in plan price, what Pay-now charges (bookings store no per-row price).
    case when x.kind = 'booked' and exists (
           select 1 from bookings b
            where b.id = x.booking_id and b.payment_source = 'drop_in' and b.status = 'booked'
              and not exists (select 1 from payments p
                               where p.booking_id = b.id and p.status in ('succeeded','partially_refunded')))
         then (select dp.price_cents from membership_plans dp
                where dp.studio_id = v_studio and dp.type = 'drop_in'
                  and dp.visibility = 'public' and dp.status = 'active'
                order by dp.price_cents asc, dp.sort_order asc, dp.id limit 1)
         end as due_cents,
    -- is_free_first: true on a free-first comp booking AND on its later cancel /
    -- no-show rows, so the helper can say "Free class used" / "Free class kept".
    (x.booking_id is not null and exists (
       select 1 from bookings b join guest_passes gp on gp.guest_booking_id = b.id
        where b.id = x.booking_id and b.payment_source = 'comp' and gp.host_member_id is null))
      as is_free_first,
    -- Decision 83 (a): the class instant + instructor, for the "{Day} {date},
    -- {time} with {instructor}" line (rowLine renders in the studio timezone).
    occ.starts_at as occurrence_start,
    nullif(split_part(coalesce(inst.display_name, ''), ' ', 1), '') as instructor_first,
    -- credits_left_after: the plan balance after this row. A no-show and a late
    -- cancel that used the credit carry no ledger of their own (the credit was
    -- spent at booking), so read that booking's consume row; a late cancel that
    -- refunded (consumes-off) has a refund ledger row, so coalesce keeps it. null
    -- = no plan credit touched (free first, unlimited, drop-in, money rows).
    case when x.kind in ('no_show','late_cancelled')
         then coalesce(l.membership_bal,
                       (select l2.membership_bal from led l2 join bookings b2 on b2.credit_entry_id = l2.id
                         where b2.id = x.booking_id))
         else l.membership_bal end as credits_left_after,
    -- payment_method / recorded_by_name: the money row's own payment (lateral,
    -- keyed on member + the arm's `at`). recorded_by is null for an online
    -- payment, so recorded_by_name is null unless it was taken at the desk.
    pm.method as payment_method,
    rec.full_name as recorded_by_name,
    case when x.kind = 'purchase' then coalesce(mp.credits, mp.credits_per_period) end as plan_classes,
    case when x.kind = 'purchase' then ms.expires_on end as plan_valid_to,
    case when x.kind = 'plan_ended' then abs(coalesce(l.delta, 0)) end as unused_credits,
    -- Decision 83 (a) follow-up: the booking's own payment_source (comp / drop_in /
    -- class_pack / membership / group), null for a non-booking row; and whether a
    -- booking row has a succeeded or partially_refunded payment, null otherwise.
    -- rowLine reads these to say "Complimentary" vs "Drop-in, paid" vs "due".
    (select b.payment_source::text from bookings b where b.id = x.booking_id) as payment_source,
    case when x.booking_id is not null
         then exists (select 1 from payments p
                       where p.booking_id = x.booking_id and p.status in ('succeeded','partially_refunded'))
         end as is_paid
  from all_rows x
  left join led l on l.id = x.ledger_id
  left join memberships ms on ms.id = x.membership_id
  left join membership_plans mp on mp.id = ms.plan_id
  left join class_occurrences occ on occ.id = x.occurrence_id
  left join instructors inst on inst.id = occ.instructor_id
  left join lateral (
    select p2.method, p2.recorded_by
      from payments p2
     where x.kind in ('purchase','refund','payment_failed')
       and p2.member_id = p_member_id
       and coalesce(p2.paid_at, p2.created_at) = x.at
     order by p2.id limit 1) pm on true
  left join profiles rec on rec.id = pm.recorded_by
  where x.at is not null and x.at::date between p_from and p_to
  order by x.at desc, x.kind;
end $function$;
revoke execute on function member_activity(uuid, date, date) from public, anon;
grant  execute on function member_activity(uuid, date, date) to authenticated, service_role;



-- === convert_booking_to_free_first (re-issued from 20260833290000 + override 'duplicate', Decision 98) ===
-- 'Make this their free class' overrides a 'duplicate' refusal, exactly as it overrides 'late_cancel'.
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
  -- already_member, missed, not_first via another paid class, not_enabled) refuses
  -- with the helper's own wording.
  --
  -- Decision 30 (d, continued): a late cancel uses the free class, BUT staff may
  -- still grant another by hand — so a 'late_cancel' refusal is OVERRIDDEN here
  -- (this convert IS that by-hand grant). It re-points the once-ever pass at the
  -- new seat, which is the one allowed reuse after a late cancel.
  v_elig := free_first_eligibility(v_b.studio_id, v_b.member_id, p_booking_id);
  if not (v_elig ->> 'ok')::boolean and (v_elig ->> 'reason') not in ('late_cancel', 'duplicate') then
    return v_elig;
  end if;

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
  -- re-pointed at this booking; a late-cancel member's row is likewise re-pointed,
  -- which is the by-hand reuse this amendment allows).
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

-- --- Anon stays EXACTLY THIRTEEN --------------------------------------------
do $$ declare n int; begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % (want 13)', n; end if;
end $$;
