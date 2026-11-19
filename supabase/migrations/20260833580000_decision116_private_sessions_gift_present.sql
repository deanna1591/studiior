-- Decision 116 — private sessions, and Decision 110 amendment (a) — gift card
-- presentation, visibility and corrections.
--
-- A studio offers private sessions (1:1 / Duo / Trio) in its down time. A private
-- is a one-off class_occurrences row marked is_private + hidden_from_members, so
-- every member reader, the public timetable and the embed exclude it by the
-- existing `not hidden_from_members` predicate while staff and the coach see it.
-- The booker's and companions' seats are inserted in the SAME definer transaction
-- that creates and hides the occurrence, so they see it through occ_member_own_read
-- while no one else can. Pay is the type's flat coach pay. Packs are 1:1-only
-- class_pack plans. Gift: the card value is the chosen face amount, a composited
-- image is rendered once at issue, refund voids an unredeemed card, and an Apple
-- Pay verified switch gates the channel list.
--
-- creates: private_session_types_for(uuid), private_slots(uuid, uuid, uuid, timestamptz, timestamptz), private_confirm_run(uuid), private_pack_consume(uuid, uuid), private_book_run(uuid, uuid, uuid, timestamptz, jsonb, text, text, text), private_book(uuid, uuid, timestamptz, jsonb, text), private_book_desk(uuid, uuid, uuid, timestamptz, jsonb, text, text), private_guard_booker(uuid), private_refund_run(uuid), private_cancel(uuid), private_move(uuid, timestamptz), private_studio_cancel(uuid, text), private_release_run(uuid), private_type_save(uuid, uuid, text, int, int, int, int), private_type_toggle(uuid, boolean)
-- re-issues: compute_class_pay_run(uuid, int), record_class_pay(uuid), xendit_activate_success_internal(uuid, text, text), set_occurrence_visibility(uuid, boolean), xendit_fail_purchase_internal(uuid, text, text), sweep_unpaid_dropins(), schedule_range(uuid, date, date), dashboard_revenue(uuid, date, date), sales_history(uuid, date, date, uuid, text), sales_totals(uuid, date, date, uuid, text), member_bootstrap(text), apply_payment_refund(uuid), refund_payment(uuid, int, text, text, text), public_schedule(text, integer), gift_card_begin(uuid, int, text, text, text, text, text, date), gift_card_resend(uuid), studio_by_slug(text), book_class(uuid, uuid, booking_source, text, payment_source, uuid)

-- ========================================================================
-- SCHEMA
-- ========================================================================

-- Private session types, per studio. people 1..3 maps to the session_kind used
-- for pay and the digest (1 private, 2 duo, 3 trio). coach_pay_cents is the flat
-- amount the coach is paid for the session, the studio's choice per type.
create table if not exists private_session_types (
  id uuid primary key default gen_random_uuid(),
  studio_id uuid not null references studios(id) on delete cascade,
  name text not null,
  price_cents int not null check (price_cents >= 0),
  people int not null check (people between 1 and 3),
  duration_min int not null check (duration_min between 10 and 240),
  coach_pay_cents int not null check (coach_pay_cents >= 0),
  active boolean not null default true,
  sort int not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists private_session_types_studio on private_session_types(studio_id) where active;

alter table private_session_types enable row level security;
drop policy if exists pst_staff_read on private_session_types;
create policy pst_staff_read on private_session_types for select to authenticated
  using (coalesce(is_desk_up(studio_id), false));
drop policy if exists pst_manager_write on private_session_types;
create policy pst_manager_write on private_session_types for all to authenticated
  using (coalesce(is_manager_up(studio_id), false))
  with check (coalesce(is_manager_up(studio_id), false));

-- Studio settings: the switch, the buffer, the lead time, and the gift fields.
alter table studio_settings
  add column if not exists private_sessions_enabled boolean not null default false,
  add column if not exists private_buffer_minutes int not null default 10 check (private_buffer_minutes between 0 and 120),
  add column if not exists private_lead_time_hours int not null default 24 check (private_lead_time_hours between 0 and 336),
  add column if not exists gift_card_image_path text,
  add column if not exists gift_apple_pay_verified boolean not null default false;

-- A private occurrence is marked, and links the type it was booked as.
alter table class_occurrences
  add column if not exists is_private boolean not null default false,
  add column if not exists private_type_id uuid references private_session_types(id);
create index if not exists class_occurrences_private on class_occurrences(studio_id) where is_private;

-- A 1:1 private pack is a class_pack plan flagged private, usable only for a 1:1
-- private at the booking step (never a group class).
alter table membership_plans
  add column if not exists private_pack boolean not null default false;

-- Which coaches teach privates.
alter table instructors
  add column if not exists teaches_privates boolean not null default false;

-- Decision 110 amendment (a): the composited gift card image, rendered at issue.
alter table gift_cards
  add column if not exists card_image_path text;

-- A private pays through Xendit against the private occurrence. Add it as a
-- target on xendit_purchases, widening the one-target CHECK.
alter table xendit_purchases
  add column if not exists private_occurrence_id uuid references class_occurrences(id);
do $$ begin
  alter table xendit_purchases drop constraint if exists xendit_purchases_one_target;
exception when others then null; end $$;
alter table xendit_purchases
  add constraint xendit_purchases_one_target check (
    (case when plan_id is not null then 1 else 0 end)
  + (case when product_order_id is not null then 1 else 0 end)
  + (case when booking_id is not null then 1 else 0 end)
  + (case when gift_card_id is not null then 1 else 0 end)
  + (case when private_occurrence_id is not null then 1 else 0 end) = 1);

-- ========================================================================
-- PRIVATE SESSIONS — read side
-- ========================================================================

-- Member-callable reader of a studio's active private types (the Book picker).
create or replace function private_session_types_for(p_studio_id uuid)
returns table(id uuid, name text, price_cents int, people int, duration_min int, coach_pay_cents int)
language sql stable security definer set search_path = public as $$
  select t.id, t.name, t.price_cents, t.people, t.duration_min, t.coach_pay_cents
  from private_session_types t
  join studio_settings ss on ss.studio_id = t.studio_id
  where t.studio_id = p_studio_id and t.active
    and coalesce(ss.private_sessions_enabled, false)
    and (exists (select 1 from members m where m.studio_id = p_studio_id and m.user_id = auth.uid() and m.deleted_at is null)
         or coalesce(is_desk_up(p_studio_id), false) or is_service_context())
  order by t.sort, t.people, t.name;
$$;
revoke execute on function private_session_types_for(uuid) from public, anon;
grant execute on function private_session_types_for(uuid) to authenticated, service_role;

-- private_slots — the free gaps for a private of a given type, optionally with a
-- chosen coach, over [p_from, p_to]. A slot is free when, in studio-local time:
--   - it is inside the studio's opening hours (whole session within open..close),
--   - it is at least the lead time ahead of now,
--   - at least one active room has no non-cancelled occurrence overlapping
--     [t - buffer, t + duration + buffer],
--   - at least one teaches-privates coach (the chosen one, or any) is available
--     under instructor_available_at_run and not on time off, and teaches privates.
-- Returns one row per free 30-minute start with the usable room and the coaches
-- free for it. SECURITY DEFINER so it can call the service-only availability twin;
-- member-guarded.
create or replace function private_slots(
  p_studio_id uuid, p_type_id uuid, p_instructor_id uuid,
  p_from timestamptz, p_to timestamptz)
returns table(starts_at timestamptz, ends_at timestamptz, room_id uuid, coach_ids uuid[])
language plpgsql stable security definer set search_path = public as $$
declare
  v_tz text; v_open time; v_close time; v_buffer int; v_lead int; v_dur int;
  v_now timestamptz := now();
begin
  if not (exists (select 1 from members m where m.studio_id = p_studio_id and m.user_id = auth.uid() and m.deleted_at is null)
          or coalesce(is_desk_up(p_studio_id), false) or is_service_context()) then
    raise exception 'you are not a member of that studio' using errcode = 'PT403';
  end if;
  select s.timezone, ss.open_time, ss.close_time,
         coalesce(ss.private_buffer_minutes, 10), coalesce(ss.private_lead_time_hours, 24)
    into v_tz, v_open, v_close, v_buffer, v_lead
    from studios s join studio_settings ss on ss.studio_id = s.id
   where s.id = p_studio_id;
  select t.duration_min into v_dur from private_session_types t
   where t.id = p_type_id and t.studio_id = p_studio_id and t.active;
  if v_dur is null then return; end if;
  if v_open is null or v_close is null then return; end if;  -- no opening hours set, no private slots

  return query
  with cand as (
    -- 30-minute candidate starts across the window, built in studio-local time.
    select gs as t1, gs + make_interval(mins => v_dur) as t2
    from generate_series(
           date_trunc('day', (greatest(p_from, v_now + make_interval(hours => v_lead)) at time zone v_tz)) at time zone v_tz,
           (p_to at time zone v_tz) at time zone v_tz,
           interval '30 minutes') gs
    where gs >= v_now + make_interval(hours => v_lead)
      and gs >= p_from and gs + make_interval(mins => v_dur) <= p_to
      -- whole session inside opening hours (studio-local wall clock)
      and (gs at time zone v_tz)::time >= v_open
      and ((gs + make_interval(mins => v_dur)) at time zone v_tz)::time <= v_close
      and (gs at time zone v_tz)::date = ((gs + make_interval(mins => v_dur)) at time zone v_tz)::date
  ),
  rooms_free as (
    select c.t1, c.t2,
      (select r.id from rooms r
        where r.studio_id = p_studio_id and r.status = 'active'
          and not exists (select 1 from class_occurrences o
            where o.room_id = r.id and o.status <> 'cancelled'
              and tstzrange(o.starts_at, o.ends_at)
                  && tstzrange(c.t1 - make_interval(mins => v_buffer), c.t2 + make_interval(mins => v_buffer)))
        order by r.name limit 1) as rid
    from cand c
  ),
  coaches_free as (
    select rf.t1, rf.t2, rf.rid,
      array(select i.id from instructors i
            where i.studio_id = p_studio_id and i.status = 'active'
              and coalesce(i.teaches_privates, false)
              and (p_instructor_id is null or i.id = p_instructor_id)
              and instructor_available_at_run(i.id, rf.t1, rf.t2)
              -- not already teaching anything (any room) over the session
              and not exists (select 1 from class_occurrences x
                               where x.instructor_id = i.id and x.status <> 'cancelled'
                                 and tstzrange(x.starts_at, x.ends_at) && tstzrange(rf.t1, rf.t2))) as cids
    from rooms_free rf
    where rf.rid is not null
  )
  select cf.t1, cf.t2, cf.rid, cf.cids
  from coaches_free cf
  where array_length(cf.cids, 1) >= 1
  order by cf.t1;
end $$;
revoke execute on function private_slots(uuid, uuid, uuid, timestamptz, timestamptz) from public, anon;
grant execute on function private_slots(uuid, uuid, uuid, timestamptz, timestamptz) to authenticated, service_role;

-- ========================================================================
-- PRIVATE SESSIONS — booking
-- ========================================================================

-- Confirm a private at once: commit it (so the pay record is written and it
-- shows under Running), flip its pending seats to booked, and tell the booker,
-- the companions and the coach. Shared by the pack path (inline) and the Xendit
-- webhook branch. Service-only, idempotent on committed_at.
create or replace function private_confirm_run(p_occurrence_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare o class_occurrences%rowtype; t private_session_types%rowtype;
        v_tz text; v_when text; v_booker uuid; r record; v_token text; v_claim text;
begin
  select * into o from class_occurrences where id = p_occurrence_id for update;
  if o.id is null or not o.is_private then return; end if;
  if o.committed_at is not null then return; end if;  -- already confirmed
  select * into t from private_session_types where id = o.private_type_id;
  select timezone into v_tz from studios where id = o.studio_id;
  v_when := to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMon') || ', '
            || fmt_clock(o.starts_at, v_tz, (select time_format from studio_settings where studio_id = o.studio_id));

  perform set_config('studiior.suppress_booking_email', '1', true);
  update bookings set status = 'booked'
   where occurrence_id = p_occurrence_id and status = 'pending_payment';
  perform set_config('studiior.suppress_booking_email', '', true);
  -- the committed_at write fires tg_record_class_pay -> record_class_pay, which is
  -- manager/service only; this flag lets the pack path (member context) write the
  -- one flat private pay record. Txn-local, reset straight after.
  perform set_config('studiior.private_pay', '1', true);
  update class_occurrences set committed_at = now() where id = p_occurrence_id;
  perform set_config('studiior.private_pay', '', true);

  -- the booker is the first seat booked; companions follow.
  select b.member_id into v_booker from bookings b
   where b.occurrence_id = p_occurrence_id and b.status = 'booked'
   order by b.created_at limit 1;

  -- tell every booked member (booker + companions) the session is confirmed. A
  -- companion with no account gets a claim + waiver link (they must sign before
  -- the session), minted here like the guest invite.
  for r in select b.member_id, m.email, m.first_name, m.user_id from bookings b
             join members m on m.id = b.member_id
            where b.occurrence_id = p_occurrence_id and b.status = 'booked'
  loop
    v_claim := '';
    if r.user_id is null then
      v_token := encode(extensions.gen_random_bytes(24), 'hex');
      -- one live invite per member: the newest link is the one that works
      delete from member_invites where member_id = r.member_id and accepted_at is null;
      insert into member_invites (studio_id, member_id, email, token_hash, expires_at)
      values (o.studio_id, r.member_id, r.email, encode(extensions.digest(v_token, 'sha256'), 'hex'),
              now() + interval '14 days');
      v_claim := 'https://' || (select slug from studios where id = o.studio_id) || '.'
                 || coalesce(notification_setting('member_app_domain'), 'studiior.app')
                 || '/claim/' || v_token;
    end if;
    perform queue_notification(o.studio_id, r.member_id, 'private_confirmed',
      jsonb_build_object('first_name', r.first_name, 'type_name', t.name,
        'when', v_when, 'studio_name', (select name from studios where id = o.studio_id),
        'occurrence_id', o.id, 'is_companion', (r.member_id <> v_booker),
        'manage_url', member_portal_url(o.studio_id, '/private/' || o.id),
        'booker_name', (select first_name from members where id = v_booker),
        'claim_url', v_claim,
        'claim_line', case when v_claim = '' then '' else
          E'\n\nBefore the session, set up your account and sign the studio waiver: ' || v_claim end,
        'claim_html', case when v_claim = '' then '' else
          '<p>Before the session, set up your account and sign the studio waiver.</p>'
          || '<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="'
          || v_claim || '" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Set up my account</a></td></tr></table>' end,
        'amount', fmt_money(t.price_cents, (select currency from studios where id = o.studio_id))),
      'private_confirmed:' || r.member_id::text || ':' || o.id::text);
  end loop;

  -- tell the coach (if they have a login)
  if o.instructor_id is not null and instructor_user_id(o.instructor_id) is not null then
    perform queue_shift_notice(o.studio_id, instructor_user_id(o.instructor_id), 'private_booked',
      jsonb_build_object('type_name', t.name, 'when', v_when,
        'first_name', (select split_part(display_name, ' ', 1) from instructors where id = o.instructor_id),
        'client_name', (select first_name from members where id = v_booker),
        'people', t.people, 'occurrence_id', o.id,
        'schedule_url', instructor_portal_url(o.studio_id, '/instructor/schedule')),
      'private_booked:' || o.id::text);
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (o.studio_id, auth.uid(), 'private.confirmed', 'class_occurrences', o.id,
          jsonb_build_object('type', t.name, 'people', t.people, 'when', v_when));
end $$;
revoke execute on function private_confirm_run(uuid) from public, anon, authenticated;
grant execute on function private_confirm_run(uuid) to service_role;

-- Consume one credit from a 1:1 private pack the member holds. Returns the
-- membership id used, or null when none usable. Service/internal.
create or replace function private_pack_consume(p_member_id uuid, p_studio_id uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare ms memberships%rowtype; v_bal int;
begin
  select m.* into ms from memberships m
    join membership_plans p on p.id = m.plan_id
   where m.member_id = p_member_id and m.studio_id = p_studio_id
     and p.private_pack and m.status in ('active', 'trialing')
     and coalesce(m.credits_remaining, 0) > 0
     and (m.expires_on is null or m.expires_on >= (now() at time zone (select timezone from studios where id = p_studio_id))::date)
   order by m.expires_on nulls last, m.created_at limit 1;
  if ms.id is null then return null; end if;
  v_bal := ms.credits_remaining - 1;
  insert into credit_ledger (studio_id, member_id, membership_id, delta, reason, balance_after)
  values (p_studio_id, p_member_id, ms.id, -1, 'booking', v_bal);
  update memberships set credits_remaining = v_bal where id = ms.id;
  return ms.id;
end $$;
revoke execute on function private_pack_consume(uuid, uuid) from public, anon, authenticated;
grant execute on function private_pack_consume(uuid, uuid) to service_role;

-- private_book_run — the ONE private builder, service-only. A private is
-- created hidden + is_private with the booker and companion seats inserted in
-- THIS transaction (a plain book_class would refuse a hidden class, so the
-- private flow never uses it). p_mode:
--   'xendit' — seats pending_payment, a xendit_purchases row returned for the
--              checkout session (the webhook confirms). When the member's account
--              credit covers the whole price it completes at once from credit.
--   'pack'   — a 1:1 private pack credit is consumed and the session confirmed.
--   'credit' — account credit covers the whole price (a free rebook after a
--              studio cancel); confirmed at once, a source-credit payment.
--   'desk'   — staff recorded a desk payment (p_method/p_reference); confirmed.
-- The occurrence name carries the client's first name ("Duo · Maria") so every
-- staff and coach reader — Schedule, My schedule, roster, pay statement, digest —
-- shows who it is for without a per-reader change.
create or replace function private_book_run(
  p_member_id uuid, p_type_id uuid, p_instructor_id uuid, p_starts_at timestamptz,
  p_companions jsonb, p_mode text, p_method text default null, p_reference text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  t private_session_types%rowtype; ss studio_settings%rowtype; v_tz text;
  v_member members%rowtype; v_studio uuid; v_coach uuid; v_room uuid; v_ends timestamptz;
  v_loc uuid; v_occ uuid; v_seat_status booking_status; v_booker_booking uuid;
  v_ccy char(3); v_pack uuid; v_purchase uuid; v_conflict text; v_mode text;
  v_ncomp int; v_comp jsonb; v_cmember uuid; v_now timestamptz := now();
  v_emails text[]; v_e text; v_credit int; v_pay uuid;
begin
  select * into t from private_session_types where id = p_type_id and active;
  if t.id is null then return jsonb_build_object('ok', false, 'reason', 'no_such_type'); end if;
  v_studio := t.studio_id;
  select * into ss from studio_settings where studio_id = v_studio;
  if not coalesce(ss.private_sessions_enabled, false) then
    return jsonb_build_object('ok', false, 'reason', 'not_enabled'); end if;
  select * into v_member from members where id = p_member_id and studio_id = v_studio and deleted_at is null;
  if v_member.id is null then raise exception 'you are not a member of that studio' using errcode = 'PT403'; end if;
  select timezone, currency into v_tz, v_ccy from studios where id = v_studio;
  v_ends := p_starts_at + make_interval(mins => t.duration_min);
  v_mode := coalesce(p_mode, 'xendit');
  if v_mode not in ('xendit', 'pack', 'credit', 'desk') then
    return jsonb_build_object('ok', false, 'reason', 'bad_pay_mode'); end if;

  -- companions: exactly people - 1, each a distinct email that is not the booker
  v_ncomp := coalesce(jsonb_array_length(p_companions), 0);
  if v_ncomp <> t.people - 1 then
    return jsonb_build_object('ok', false, 'reason', 'wrong_companion_count', 'need', t.people - 1); end if;
  v_emails := array[lower(btrim(coalesce(v_member.email, '')))];
  for v_comp in select * from jsonb_array_elements(coalesce(p_companions, '[]'::jsonb)) loop
    v_e := lower(btrim(coalesce(v_comp->>'email', '')));
    if v_e not like '%_@_%' or coalesce(nullif(btrim(v_comp->>'name'), ''), '') = '' then
      return jsonb_build_object('ok', false, 'reason', 'companion_details'); end if;
    if v_e = any(v_emails) then
      return jsonb_build_object('ok', false, 'reason', 'companion_duplicate'); end if;
    v_emails := v_emails || v_e;
  end loop;

  -- lead time (a desk booking skips it: staff may book at short notice), hours
  if v_mode <> 'desk'
     and p_starts_at < v_now + make_interval(hours => coalesce(ss.private_lead_time_hours, 24)) then
    return jsonb_build_object('ok', false, 'reason', 'too_soon'); end if;
  if p_starts_at <= v_now then return jsonb_build_object('ok', false, 'reason', 'too_soon'); end if;
  if ss.open_time is null or ss.close_time is null
     or (p_starts_at at time zone v_tz)::time < ss.open_time
     or (v_ends at time zone v_tz)::time > ss.close_time
     or (p_starts_at at time zone v_tz)::date <> (v_ends at time zone v_tz)::date then
    return jsonb_build_object('ok', false, 'reason', 'outside_hours'); end if;

  -- coach: the chosen one, or the first available teaches-privates coach
  if p_instructor_id is not null then
    if not exists (select 1 from instructors i where i.id = p_instructor_id and i.studio_id = v_studio
                    and i.status = 'active' and coalesce(i.teaches_privates, false))
       or not instructor_available_at_run(p_instructor_id, p_starts_at, v_ends) then
      return jsonb_build_object('ok', false, 'reason', 'coach_unavailable'); end if;
    if exists (select 1 from class_occurrences x where x.instructor_id = p_instructor_id
                 and x.status <> 'cancelled' and tstzrange(x.starts_at, x.ends_at) && tstzrange(p_starts_at, v_ends)) then
      return jsonb_build_object('ok', false, 'reason', 'coach_busy'); end if;
    v_coach := p_instructor_id;
  else
    select i.id into v_coach from instructors i
      where i.studio_id = v_studio and i.status = 'active' and coalesce(i.teaches_privates, false)
        and instructor_available_at_run(i.id, p_starts_at, v_ends)
        and not exists (select 1 from class_occurrences x where x.instructor_id = i.id
                          and x.status <> 'cancelled' and tstzrange(x.starts_at, x.ends_at) && tstzrange(p_starts_at, v_ends))
      order by i.display_name limit 1;
    if v_coach is null then return jsonb_build_object('ok', false, 'reason', 'coach_unavailable'); end if;
  end if;

  -- a free room over [start - buffer, end + buffer]
  select r.id into v_room from rooms r
    where r.studio_id = v_studio and r.status = 'active'
      and not exists (select 1 from class_occurrences o where o.room_id = r.id and o.status <> 'cancelled'
        and tstzrange(o.starts_at, o.ends_at)
            && tstzrange(p_starts_at - make_interval(mins => coalesce(ss.private_buffer_minutes, 10)),
                         v_ends + make_interval(mins => coalesce(ss.private_buffer_minutes, 10))))
    order by r.name limit 1;
  if v_room is null then return jsonb_build_object('ok', false, 'reason', 'no_room'); end if;
  select id into v_loc from locations where studio_id = v_studio and is_primary order by created_at limit 1;

  -- a Xendit private the member's account credit fully covers completes from credit
  if v_mode = 'xendit' and reservation_credit_available(v_studio, p_member_id) >= t.price_cents then
    v_mode := 'credit';
  end if;
  if v_mode = 'credit' and reservation_credit_available(v_studio, p_member_id) < t.price_cents then
    return jsonb_build_object('ok', false, 'reason', 'not_enough_credit'); end if;
  if v_mode = 'xendit' and not exists (select 1 from studio_payment_providers
       where studio_id = v_studio and provider = 'xendit') then
    return jsonb_build_object('ok', false, 'reason', 'no_provider'); end if;
  if v_mode = 'desk' and coalesce(p_method, '') not in ('cash','bank_transfer','card_terminal','gcash','other') then
    return jsonb_build_object('ok', false, 'reason', 'unknown_method'); end if;

  -- a pack resolves up front so a missing pack fails before creating anything
  if v_mode = 'pack' then
    if t.people <> 1 then return jsonb_build_object('ok', false, 'reason', 'pack_1to1_only'); end if;
    v_pack := private_pack_consume(p_member_id, v_studio);
    if v_pack is null then return jsonb_build_object('ok', false, 'reason', 'no_pack_credit'); end if;
  end if;

  v_seat_status := case when v_mode = 'xendit' then 'pending_payment' else 'booked' end::booking_status;

  begin
    insert into class_occurrences (studio_id, location_id, class_type_id, name, instructor_id,
      room_id, capacity, starts_at, ends_at, guarantee_tier, flex, is_private, private_type_id,
      hidden_from_members)
    values (v_studio, v_loc, null, t.name || ' · ' || coalesce(nullif(v_member.preferred_name, ''), v_member.first_name),
      v_coach, v_room, t.people, p_starts_at, v_ends, 'always', false, true, t.id, true)
    returning id into v_occ;
  exception when exclusion_violation then
    get stacked diagnostics v_conflict = constraint_name;
    if v_pack is not null then
      update memberships set credits_remaining = credits_remaining + 1 where id = v_pack;
      insert into credit_ledger (studio_id, member_id, membership_id, delta, reason, balance_after)
      select v_studio, p_member_id, v_pack, 1, 'booking',
             (select credits_remaining from memberships where id = v_pack);
    end if;
    return jsonb_build_object('ok', false,
      'reason', case when v_conflict = 'occ_room_no_overlap' then 'room_busy' else 'coach_busy' end);
  end;

  -- the private's own private_confirmed is the confirmation; the ordinary
  -- booking_confirmed must not also go (the walk-in flag, txn-local).
  perform set_config('studiior.suppress_booking_email', '1', true);
  -- the booker's seat
  insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source, membership_id)
  values (v_studio, v_occ, p_member_id, v_seat_status,
          (case when v_mode = 'desk' then 'front_desk' else 'member' end)::booking_source,
          'private', v_pack)
  returning id into v_booker_booking;
  update class_occurrences set booked_count = booked_count + 1 where id = v_occ;

  -- companion seats: resolve or create each as a lead; part of the paid private
  for v_comp in select * from jsonb_array_elements(coalesce(p_companions, '[]'::jsonb)) loop
    select id into v_cmember from members where studio_id = v_studio
      and lower(email) = lower(btrim(v_comp->>'email')) and deleted_at is null;
    if v_cmember is null then
      insert into members (studio_id, first_name, last_name, email, status, source)
      values (v_studio, split_part(btrim(v_comp->>'name'), ' ', 1), name_last_part(btrim(v_comp->>'name')),
              lower(btrim(v_comp->>'email')), 'lead', 'private_companion')
      returning id into v_cmember;
    end if;
    insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source)
    values (v_studio, v_occ, v_cmember, v_seat_status,
            (case when v_mode = 'desk' then 'front_desk' else 'member' end)::booking_source, 'private');
    update class_occurrences set booked_count = booked_count + 1 where id = v_occ;
  end loop;
  perform set_config('studiior.suppress_booking_email', '', true);

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (v_studio, auth.uid(), 'private.booked', 'class_occurrences', v_occ,
          jsonb_build_object('type', t.name, 'people', t.people, 'mode', v_mode,
                             'member_id', p_member_id, 'starts_at', p_starts_at));

  if v_mode = 'xendit' then
    insert into xendit_purchases (studio_id, member_id, private_occurrence_id, amount_cents, currency)
    values (v_studio, p_member_id, v_occ, t.price_cents, v_ccy)
    returning id into v_purchase;
    return jsonb_build_object('ok', true, 'occurrence_id', v_occ, 'confirmed', false,
      'purchase_id', v_purchase, 'amount_cents', t.price_cents, 'currency', v_ccy);
  end if;

  if v_mode = 'credit' then
    v_credit := consume_reservation_credit(v_studio, p_member_id, t.price_cents);
    insert into payments (studio_id, member_id, booking_id, kind, amount_cents, currency,
                          status, provider, source, description, paid_at)
    values (v_studio, p_member_id, v_booker_booking, 'private', t.price_cents, v_ccy,
            'succeeded', 'manual', 'credit', 'Private session (account credit)', now());
  elsif v_mode = 'desk' then
    insert into payments (studio_id, member_id, booking_id, kind, amount_cents, currency,
                          status, provider, method, reference, recorded_by, description, paid_at)
    values (v_studio, p_member_id, v_booker_booking, 'private', t.price_cents, v_ccy,
            'succeeded', 'manual', p_method, nullif(btrim(coalesce(p_reference, '')), ''),
            auth.uid(), 'Private session', now())
    returning id into v_pay;
  end if;
  perform private_confirm_run(v_occ);
  return jsonb_build_object('ok', true, 'occurrence_id', v_occ, 'confirmed', true, 'mode', v_mode);
end $$;
revoke execute on function private_book_run(uuid, uuid, uuid, timestamptz, jsonb, text, text, text) from public, anon, authenticated;
grant execute on function private_book_run(uuid, uuid, uuid, timestamptz, jsonb, text, text, text) to service_role;

-- private_book — a member books their own private. Resolves the caller's member
-- row in the type's studio and delegates to private_book_run. A 'desk' mode is
-- never a member's to choose.
create or replace function private_book(
  p_type_id uuid, p_instructor_id uuid, p_starts_at timestamptz,
  p_companions jsonb default '[]'::jsonb, p_pay_mode text default 'xendit')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_studio uuid; v_member uuid;
begin
  select studio_id into v_studio from private_session_types where id = p_type_id;
  if v_studio is null then return jsonb_build_object('ok', false, 'reason', 'no_such_type'); end if;
  select id into v_member from members where studio_id = v_studio and user_id = auth.uid() and deleted_at is null;
  if v_member is null then raise exception 'you are not a member of that studio' using errcode = 'PT403'; end if;
  if coalesce(p_pay_mode, 'xendit') not in ('xendit', 'pack', 'credit') then
    return jsonb_build_object('ok', false, 'reason', 'bad_pay_mode'); end if;
  return private_book_run(v_member, p_type_id, p_instructor_id, p_starts_at,
                          coalesce(p_companions, '[]'::jsonb), coalesce(p_pay_mode, 'xendit'));
end $$;
revoke execute on function private_book(uuid, uuid, timestamptz, jsonb, text) from public, anon;
grant execute on function private_book(uuid, uuid, timestamptz, jsonb, text) to authenticated, service_role;

-- private_book_desk — staff (front desk and up) book a private for a member from
-- the profile and record the desk payment, or spend the member's 1:1 pack credit
-- (p_method 'pack'). Confirmed at once.
create or replace function private_book_desk(
  p_member_id uuid, p_type_id uuid, p_instructor_id uuid, p_starts_at timestamptz,
  p_companions jsonb default '[]'::jsonb, p_method text default 'cash', p_reference text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_studio uuid;
begin
  select studio_id into v_studio from private_session_types where id = p_type_id;
  if v_studio is null then return jsonb_build_object('ok', false, 'reason', 'no_such_type'); end if;
  if not coalesce(is_desk_up(v_studio), false) then
    raise exception 'only staff book a private for a member' using errcode = 'PT403'; end if;
  if not exists (select 1 from members where id = p_member_id and studio_id = v_studio and deleted_at is null) then
    raise exception 'no such member' using errcode = 'PT404'; end if;
  return private_book_run(p_member_id, p_type_id, p_instructor_id, p_starts_at,
    coalesce(p_companions, '[]'::jsonb),
    case when p_method = 'pack' then 'pack' else 'desk' end,
    case when p_method = 'pack' then null else p_method end, p_reference);
end $$;
revoke execute on function private_book_desk(uuid, uuid, uuid, timestamptz, jsonb, text, text) from public, anon;
grant execute on function private_book_desk(uuid, uuid, uuid, timestamptz, jsonb, text, text) to authenticated, service_role;

-- ========================================================================
-- PRIVATE SESSIONS — pay (re-issue compute_class_pay_run from newest + the private arm)
-- ========================================================================
CREATE OR REPLACE FUNCTION public.compute_class_pay_run(p_occurrence_id uuid, p_heads int default null)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o class_occurrences%rowtype; s studio_settings%rowtype; g record;
  rv instructor_rate_versions%rowtype; v_kind session_kind; v_tz text;
  v_local date; v_amount int; v_basis jsonb; v_heads int; v_flat int;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if o.instructor_id is null then
    return jsonb_build_object('ok', false, 'reason', 'no instructor on this class');
  end if;

  select * into s from studio_settings where studio_id = o.studio_id;
  select timezone into v_tz from studios where id = o.studio_id;
  v_local := (o.starts_at at time zone v_tz)::date;

  -- Decision 116: a private is a flat line paid at the TYPE's coach pay, with the
  -- kind from its people (1 private, 2 duo, 3 trio). It needs NO instructor rate
  -- version, so it returns before the (guarded) rate lookup. A studio-cancelled
  -- private pays the coach nothing; otherwise the coach is paid the flat amount.
  if coalesce(o.is_private, false) then
    select coach_pay_cents,
           (case people when 1 then 'private' when 2 then 'duo' else 'trio' end)::session_kind
      into v_flat, v_kind
      from private_session_types where id = o.private_type_id;
    v_flat := coalesce(v_flat, 0);
    v_amount := case when o.status = 'cancelled' then 0 else v_flat end;
    v_basis := jsonb_build_object('kind', coalesce(v_kind, 'private'),
      'flat_rate_cents', v_flat, 'private', true,
      'status', o.status, 'cause', o.cancellation_cause);
    return jsonb_build_object('ok', true, 'amount_cents', v_amount,
      'currency', (select currency from studios where id = o.studio_id),
      'rate_version_id', null,
      'instructor_id', o.instructor_id, 'local_date', v_local, 'basis', v_basis);
  end if;

  -- The version in force ON THE DAY OF THE CLASS, not today. This is what makes
  -- a rate change next month leave last month alone.
  select * into rv from instructor_rate_at(o.instructor_id, v_local);
  if rv.id is null then
    return jsonb_build_object('ok', false, 'reason', 'no rate on file for that date');
  end if;

  select coalesce(ct.session_kind, 'group') into v_kind
    from class_types ct where ct.id = o.class_type_id;
  v_kind := coalesce(v_kind, 'group');

  select * into g from occurrence_guarantee_run(p_occurrence_id);
  -- DECISION 32: the greater of the cutoff count and the start count. When the
  -- start snapshot has not been taken (not yet started, or an `always` class
  -- whose cutoff count already IS the start count) booked_at_start is null and
  -- the greatest collapses to the cutoff — so nothing changes until a real late
  -- booker moves the start count above it.
  -- DECISION 75d: an optional checked-in-head override (finalise_pay_true_up
  -- passes count(distinct member) from check_ins). Null keeps Decision 32's
  -- greater-of booked basis, so every other caller is byte-for-byte unchanged.
  v_heads := coalesce(p_heads, greatest(coalesce(o.booked_at_cutoff, 0), coalesce(o.booked_at_start, 0)));

  -- 1. A private, duo or trio REPLACES the whole calculation. Flat, by product.
  if v_kind <> 'group' then
    v_flat := case v_kind
      when 'private' then rv.private_rate_cents
      when 'duo'     then rv.duo_rate_cents
      else                rv.trio_rate_cents end;
    if v_flat is null then
      return jsonb_build_object('ok', false,
        'reason', format('no %s rate on file', v_kind));
    end if;
    -- A private that did not run follows the same cancellation rules as any
    -- other class, against its flat rate rather than a base.
    if o.status = 'cancelled' then
      v_amount := case o.cancellation_cause
        when 'unmet_minimum' then
          case when g.tier = 'flex' then coalesce(s.flex_unmet_pay_cents, 0)
               else (v_flat * coalesce(s.core_unmet_pay_pct, 0)) / 100 end
        when 'studio_fault'  then v_flat
        when 'force_majeure' then 0
        when 'closure'       then case when coalesce(o.cancellation_pays, false) then v_flat else 0 end
        else 0 end;
    else
      v_amount := v_flat;
    end if;
    v_basis := jsonb_build_object('kind', v_kind, 'flat_rate_cents', v_flat,
                                  'status', o.status, 'cause', o.cancellation_cause);

  -- 2. It ran, or it is committed and therefore owed in full whatever happened
  --    afterwards.
  elsif o.status <> 'cancelled' or o.committed_at is not null then
    v_amount := rv.base_rate_cents
              + greatest(0, v_heads - rv.per_head_threshold) * rv.per_head_rate_cents
              -- Keys off THE CLASS's capacity, which varies by room. A capacity
              -- 5 studio and a capacity 6 studio both reach a full house.
              + case when o.capacity is not null and v_heads >= o.capacity
                     then rv.full_house_bonus_cents else 0 end;
    v_basis := jsonb_build_object(
      'kind', 'group', 'base_cents', rv.base_rate_cents,
      -- Both counts and the one actually paid, so the statement can say "2 at
      -- cutoff, 3 at start" and the CSV can agree line for line.
      'booked_at_cutoff', coalesce(o.booked_at_cutoff, 0),
      'booked_at_start', o.booked_at_start,
      'booked_paid', v_heads,
      'capacity', o.capacity,
      'per_head_cents', rv.per_head_rate_cents, 'per_head_threshold', rv.per_head_threshold,
      'heads_paid', greatest(0, v_heads - rv.per_head_threshold),
      'full_house', (o.capacity is not null and v_heads >= o.capacity),
      'full_house_bonus_cents', case when o.capacity is not null and v_heads >= o.capacity
                                     then rv.full_house_bonus_cents else 0 end);

  -- 3. It is not running.
  else
    if o.cancellation_cause = 'unmet_minimum' then
      if g.tier = 'flex' then
        -- Standby is paid when the slot was STANDALONE. A flex class next to
        -- another of the instructor's classes costs them nothing extra; one on
        -- its own cost them the trip. Both settings default to 0, so a studio
        -- that has not set them is unaffected either way.
        v_amount := coalesce(s.flex_unmet_pay_cents, 0)
                  + case when occurrence_is_adjacent_run(p_occurrence_id)
                         then 0 else coalesce(s.flex_standby_pay_cents, 0) end;
        v_basis := jsonb_build_object('kind', 'group', 'outcome', 'not_running',
          'tier', 'flex', 'unmet_pay_cents', coalesce(s.flex_unmet_pay_cents, 0),
          'standby_cents', case when occurrence_is_adjacent_run(p_occurrence_id)
                                then 0 else coalesce(s.flex_standby_pay_cents, 0) end,
          'adjacent', occurrence_is_adjacent_run(p_occurrence_id));
      else
        -- The slot-holding fee: a FLAT amount when the studio set one
        -- (core_unmet_pay_cents), otherwise the percentage of base. Flat wins
        -- because "pay 400 regardless" cannot be a percentage of a rate that
        -- changes; the percentage stays the fallback so existing studios that
        -- only ever set a pct are untouched.
        v_amount := coalesce(s.core_unmet_pay_cents,
                             (rv.base_rate_cents * coalesce(s.core_unmet_pay_pct, 0)) / 100);
        v_basis := jsonb_build_object('kind', 'group', 'outcome', 'not_running',
          'tier', 'core', 'base_cents', rv.base_rate_cents,
          'holding_model', case when s.core_unmet_pay_cents is not null then 'flat' else 'pct' end,
          'holding_flat_cents', s.core_unmet_pay_cents,
          'holding_pct', coalesce(s.core_unmet_pay_pct, 0));
      end if;
    else
      v_amount := case o.cancellation_cause
        when 'studio_fault'  then rv.base_rate_cents
        when 'force_majeure' then 0
        when 'closure' then case when coalesce(o.cancellation_pays, false)
                                 then rv.base_rate_cents else 0 end
        else 0 end;
      v_basis := jsonb_build_object('kind', 'group', 'outcome', 'cancelled',
        'cause', o.cancellation_cause, 'base_cents', rv.base_rate_cents,
        'closure_pays', o.cancellation_pays);
    end if;
  end if;

  return jsonb_build_object('ok', true, 'amount_cents', v_amount,
    'currency', rv.currency, 'rate_version_id', rv.id,
    'instructor_id', o.instructor_id, 'local_date', v_local, 'basis', v_basis);
end $function$;


revoke execute on function compute_class_pay_run(uuid, int) from public, anon, authenticated;
grant  execute on function compute_class_pay_run(uuid, int) to service_role;

-- re-issue record_class_pay (byte-faithful) honouring the private_pay flag -----
CREATE OR REPLACE FUNCTION public.record_class_pay(p_occurrence_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o class_occurrences%rowtype; c jsonb; p pay_periods%rowtype; v_id uuid; v_tz text;
  v_conf_at timestamptz; v_conf_by uuid; v_conf_method text; v_orig_period uuid;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  -- Decision 116: private_confirm_run commits a private in the booker's own
  -- (member) context for the pack path, which must write the flat pay record; the
  -- txn-local flag it sets lets that one write through.
  if not coalesce(is_manager_up(o.studio_id), false) and not is_service_context()
     and coalesce(current_setting('studiior.private_pay', true), '') <> '1' then
    raise exception 'only owners, managers and the sweep write pay' using errcode = 'PT403';
  end if;

  -- Already paid for. The unique index would refuse it anyway; answering here
  -- keeps a retry quiet rather than making it an error somebody has to read.
  if exists (select 1 from instructor_pay_records
              where occurrence_id = p_occurrence_id and type = 'class') then
    return jsonb_build_object('ok', true, 'already_recorded', true);
  end if;

  c := compute_class_pay_run(p_occurrence_id);
  if not (c ->> 'ok')::boolean then
    return c;  -- no instructor, or no rate on file. Not an error: a studio that
               -- has not set rates yet still runs classes.
  end if;

  -- Decision 28: a class that RAN is HELD until the instructor checks in (or a
  -- manager releases it); a class that did NOT run needs no check-in and is
  -- auto-confirmed, because its pay is Decision 22's, not attendance.
  if o.status = 'cancelled' then
    v_conf_at := now(); v_conf_by := null; v_conf_method := 'auto';
  else
    v_conf_at := o.instructor_checked_in_at; v_conf_by := o.instructor_checked_in_by;
    v_conf_method := case when o.instructor_checked_in_at is not null then 'self' end;
  end if;

  select timezone into v_tz from studios where id = o.studio_id;
  p := ensure_pay_period(o.studio_id, (c ->> 'local_date')::date);
  if p.status = 'closed' then
    -- The class belongs to a period already paid. It goes in the next open one
    -- as an adjustment rather than reopening history.
    v_orig_period := p.id;  -- the period the class belonged to
    p := next_open_pay_period(o.studio_id);
    insert into instructor_pay_records (
      studio_id, instructor_id, period_id, type, occurrence_id, amount_cents,
      currency, rate_version_id, basis, note, created_by,
      confirmed_at, confirmed_by, confirm_method)
    values (o.studio_id, (c ->> 'instructor_id')::uuid, p.id, 'class',
            p_occurrence_id, (c ->> 'amount_cents')::int, c ->> 'currency',
            (c ->> 'rate_version_id')::uuid,
            (c -> 'basis') || jsonb_build_object('original_period', v_orig_period),
            'Class fell in a closed period; recorded here instead', auth.uid(),
            v_conf_at, v_conf_by, v_conf_method)
    returning id into v_id;
    return jsonb_build_object('ok', true, 'pay_record_id', v_id, 'period_id', p.id,
      'amount_cents', (c ->> 'amount_cents')::int, 'late', true);
  end if;

  insert into instructor_pay_records (
    studio_id, instructor_id, period_id, type, occurrence_id, amount_cents,
    currency, rate_version_id, basis, created_by,
    confirmed_at, confirmed_by, confirm_method)
  values (o.studio_id, (c ->> 'instructor_id')::uuid, p.id, 'class',
          p_occurrence_id, (c ->> 'amount_cents')::int, c ->> 'currency',
          (c ->> 'rate_version_id')::uuid, c -> 'basis', auth.uid(),
          v_conf_at, v_conf_by, v_conf_method)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'pay_record_id', v_id, 'period_id', p.id,
    'amount_cents', (c ->> 'amount_cents')::int,
    'rate_version_id', c ->> 'rate_version_id');
end $function$;

-- ========================================================================
-- PRIVATE SESSIONS — move, cancel, studio cancel, desk, rebook
-- ========================================================================

-- A member's own private. Shared guard: the caller is the booker (first seat).
create or replace function private_guard_booker(p_occurrence_id uuid)
returns class_occurrences language plpgsql stable security definer set search_path = public as $$
declare o class_occurrences%rowtype; v_booker uuid;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if o.id is null or not o.is_private then raise exception 'no such private' using errcode = 'PT404'; end if;
  select b.member_id into v_booker from bookings b
   where b.occurrence_id = p_occurrence_id and b.status in ('booked','pending_payment')
   order by b.created_at limit 1;
  if not (coalesce((select user_id from members where id = v_booker) = auth.uid(), false)
          or coalesce(is_desk_up(o.studio_id), false) or is_service_context()) then
    raise exception 'that is not your private' using errcode = 'PT403';
  end if;
  return o;
end $$;
revoke execute on function private_guard_booker(uuid) from public, anon;
grant execute on function private_guard_booker(uuid) to authenticated, service_role;

-- Refund a private's payment as credit (pack credit back, or a member_credits
-- cash credit for a full-paid private). Service/internal.
create or replace function private_refund_run(p_occurrence_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare o class_occurrences%rowtype; b bookings%rowtype; p payments%rowtype; v_bal int;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  select * into b from bookings where occurrence_id = p_occurrence_id
    and payment_source = 'private' order by created_at limit 1;  -- the booker's seat
  if b.id is null then return; end if;
  if b.membership_id is not null then
    -- pack credit back
    select credits_remaining + 1 into v_bal from memberships where id = b.membership_id;
    update memberships set credits_remaining = v_bal where id = b.membership_id;
    insert into credit_ledger (studio_id, member_id, membership_id, delta, reason, balance_after)
    values (o.studio_id, b.member_id, b.membership_id, 1, 'booking', v_bal);
  else
    -- a full-paid private: the succeeded private payment becomes account credit
    select * into p from payments where booking_id = b.id
      and kind = 'private' and status in ('succeeded', 'partially_refunded')
      order by paid_at desc limit 1;
    if p.id is not null then
      insert into member_credits (studio_id, member_id, amount_cents, currency, reason, payment_id)
      values (o.studio_id, b.member_id, p.amount_cents, p.currency, 'private_refund', p.id);
    end if;
  end if;
end $$;
revoke execute on function private_refund_run(uuid) from public, anon, authenticated;
grant execute on function private_refund_run(uuid) to service_role;

-- private_cancel — the booker cancels. On time (at least the lead time before):
-- the occurrence is cancelled, the payment returns as credit, the coach is not
-- paid (its held pay record is removed). Late: the fee is kept and the coach is
-- paid, so the occurrence stays and the booker's seat is a late cancel.
create or replace function private_cancel(p_occurrence_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o class_occurrences%rowtype; ss studio_settings%rowtype; v_on_time boolean;
        v_tz text; v_when text; r record;
begin
  o := private_guard_booker(p_occurrence_id);
  if o.status = 'cancelled' then return jsonb_build_object('ok', false, 'reason', 'already_cancelled'); end if;
  select * into ss from studio_settings where studio_id = o.studio_id;
  v_on_time := now() < o.starts_at - make_interval(hours => coalesce(ss.private_lead_time_hours, 24));
  select timezone into v_tz from studios where id = o.studio_id;
  v_when := to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMon') || ', '
            || fmt_clock(o.starts_at, v_tz, ss.time_format);

  if v_on_time then
    perform private_refund_run(p_occurrence_id);
    -- the session is off, so the coach is NOT owed "your pay is unchanged"
    perform set_config('studiior.releasing', '1', true);
    update bookings set status = 'cancelled', cancelled_at = now(), release_reason = 'member_cancelled'
     where occurrence_id = p_occurrence_id and status in ('booked','pending_payment');
    perform set_config('studiior.releasing', '', true);
    update class_occurrences set status = 'cancelled', cancelled_at = now(),
           cancellation_cause = 'studio_fault' where id = p_occurrence_id;
    delete from instructor_pay_records where occurrence_id = p_occurrence_id and confirmed_at is null;

  -- tell the coach the session is off (not on a late cancel: the session stands
  -- and they are paid, which tg_notify_committed_cancel already says).
  if o.instructor_id is not null and instructor_user_id(o.instructor_id) is not null then
    perform queue_shift_notice(o.studio_id, instructor_user_id(o.instructor_id), 'instructor_class_cancelled',
      jsonb_build_object('first_name', (select split_part(display_name, ' ', 1) from instructors where id = o.instructor_id),
        'class_name', o.name, 'when', v_when, 'occurrence_id', o.id,
        'reason', 'the client cancelled in time', 'studio_name', (select name from studios where id = o.studio_id)),
      'private_coach_cancelled:' || o.id::text);
  end if;
  else
    update bookings set status = 'late_cancelled', cancelled_at = now(), is_late_cancel = true
     where occurrence_id = p_occurrence_id and status = 'booked';
  end if;

  for r in select b.member_id from bookings b where b.occurrence_id = p_occurrence_id loop
    perform queue_notification(o.studio_id, r.member_id, 'private_cancelled',
      jsonb_build_object('first_name', (select coalesce(nullif(preferred_name, ''), first_name) from members where id = r.member_id),
        'type_name', (select name from private_session_types where id = o.private_type_id),
        'when', v_when, 'on_time', v_on_time,
        'outcome_line', case when v_on_time
          then 'You cancelled in time, so your ' || (select case when exists (select 1 from bookings bb where bb.occurrence_id = o.id and bb.membership_id is not null) then 'pack credit is' else fmt_money((select price_cents from private_session_types where id = o.private_type_id), (select currency from studios where id = o.studio_id)) || ' is' end) || ' back on your account.'
          else 'It was less than ' || coalesce(ss.private_lead_time_hours, 24) || ' hours before the session, so the fee is kept.' end,
        'studio_name', (select name from studios where id = o.studio_id),
        'book_url', member_portal_url(o.studio_id, '/book/private')),
      'private_cancelled:' || r.member_id::text || ':' || o.id::text);
  end loop;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (o.studio_id, auth.uid(), 'private.cancelled', 'class_occurrences', o.id,
          jsonb_build_object('on_time', v_on_time, 'when', v_when));
  return jsonb_build_object('ok', true, 'on_time', v_on_time);
end $$;
revoke execute on function private_cancel(uuid) from public, anon;
grant execute on function private_cancel(uuid) to authenticated, service_role;

-- private_move — the booker moves to a new start (the one free reschedule, on
-- time only). Re-validates the slot (room, coach, hours, lead) and keeps the pay
-- line as it was (the session still happens).
create or replace function private_move(p_occurrence_id uuid, p_new_start timestamptz)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o class_occurrences%rowtype; ss studio_settings%rowtype; t private_session_types%rowtype;
        v_tz text; v_ends timestamptz; v_room uuid; r record; v_when text;
begin
  o := private_guard_booker(p_occurrence_id);
  if o.status <> 'scheduled' then return jsonb_build_object('ok', false, 'reason', 'not_scheduled'); end if;
  select * into ss from studio_settings where studio_id = o.studio_id;
  select * into t from private_session_types where id = o.private_type_id;
  select timezone into v_tz from studios where id = o.studio_id;
  if now() >= o.starts_at - make_interval(hours => coalesce(ss.private_lead_time_hours, 24)) then
    return jsonb_build_object('ok', false, 'reason', 'too_late_to_move'); end if;
  -- one free reschedule: a booker moves a private once (staff may move it again)
  if not coalesce(is_desk_up(o.studio_id), false)
     and exists (select 1 from audit_logs al where al.entity_id = o.id and al.action = 'private.moved') then
    return jsonb_build_object('ok', false, 'reason', 'already_moved'); end if;
  v_ends := p_new_start + make_interval(mins => t.duration_min);
  if p_new_start < now() + make_interval(hours => coalesce(ss.private_lead_time_hours, 24)) then
    return jsonb_build_object('ok', false, 'reason', 'too_soon'); end if;
  if ss.open_time is null or (p_new_start at time zone v_tz)::time < ss.open_time
     or (v_ends at time zone v_tz)::time > ss.close_time
     or (p_new_start at time zone v_tz)::date <> (v_ends at time zone v_tz)::date then
    return jsonb_build_object('ok', false, 'reason', 'outside_hours'); end if;
  if o.instructor_id is not null and not instructor_available_at_run(o.instructor_id, p_new_start, v_ends) then
    return jsonb_build_object('ok', false, 'reason', 'coach_unavailable'); end if;
  -- a free room at the new time (its own room if free, else any)
  select r2.id into v_room from rooms r2 where r2.studio_id = o.studio_id and r2.status = 'active'
    and not exists (select 1 from class_occurrences x where x.room_id = r2.id and x.status <> 'cancelled'
      and x.id <> o.id and tstzrange(x.starts_at, x.ends_at)
          && tstzrange(p_new_start - make_interval(mins => coalesce(ss.private_buffer_minutes,10)),
                       v_ends + make_interval(mins => coalesce(ss.private_buffer_minutes,10))))
    order by (r2.id = o.room_id) desc, r2.name limit 1;
  if v_room is null then return jsonb_build_object('ok', false, 'reason', 'no_room'); end if;
  begin
    update class_occurrences set starts_at = p_new_start, ends_at = v_ends, room_id = v_room,
           is_exception = true where id = o.id;
  exception when exclusion_violation then
    return jsonb_build_object('ok', false, 'reason', 'slot_busy'); end;
  v_when := to_char(p_new_start at time zone v_tz, 'FMDay FMDD FMMon') || ', '
            || fmt_clock(p_new_start, v_tz, ss.time_format);
  for r in select b.member_id from bookings b where b.occurrence_id = o.id and b.status in ('booked','pending_payment') loop
    perform queue_notification(o.studio_id, r.member_id, 'private_moved',
      jsonb_build_object('first_name', (select coalesce(nullif(preferred_name, ''), first_name) from members where id = r.member_id),
        'type_name', t.name, 'when', v_when,
        'studio_name', (select name from studios where id = o.studio_id),
        'manage_url', member_portal_url(o.studio_id, '/private/' || o.id)),
      'private_moved:' || r.member_id::text || ':' || o.id::text || ':' || extract(epoch from p_new_start)::bigint::text);
  end loop;
  if o.instructor_id is not null and instructor_user_id(o.instructor_id) is not null then
    perform queue_shift_notice(o.studio_id, instructor_user_id(o.instructor_id), 'private_booked',
      jsonb_build_object('type_name', t.name, 'when', v_when,
        'first_name', (select split_part(display_name, ' ', 1) from instructors where id = o.instructor_id),
        'client_name', split_part(o.name, ' · ', 2), 'people', t.people, 'occurrence_id', o.id,
        'moved', true,
        'schedule_url', instructor_portal_url(o.studio_id, '/instructor/schedule')),
      'private_booked:' || o.id::text || ':' || extract(epoch from p_new_start)::bigint::text);
  end if;
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (o.studio_id, auth.uid(), 'private.moved', 'class_occurrences', o.id,
          jsonb_build_object('new_start', p_new_start, 'when', v_when));
  return jsonb_build_object('ok', true, 'occurrence_id', o.id, 'when', v_when);
end $$;
revoke execute on function private_move(uuid, timestamptz) from public, anon;
grant execute on function private_move(uuid, timestamptz) to authenticated, service_role;

-- private_studio_cancel — a manager cancels. The member is refunded as credit and
-- gets the choice (handled app-side: a free rebook, or a cash refund via Payments);
-- the coach is NOT paid. Manager-up.
create or replace function private_studio_cancel(p_occurrence_id uuid, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o class_occurrences%rowtype; v_tz text; v_when text; r record;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if o.id is null or not o.is_private then raise exception 'no such private' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(o.studio_id), false) then
    raise exception 'only owners and managers cancel a private' using errcode = 'PT403'; end if;
  if o.status = 'cancelled' then return jsonb_build_object('ok', false, 'reason', 'already_cancelled'); end if;
  select timezone into v_tz from studios where id = o.studio_id;
  v_when := to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMon') || ', '
            || fmt_clock(o.starts_at, v_tz, (select time_format from studio_settings where studio_id = o.studio_id));
  perform private_refund_run(p_occurrence_id);
  perform set_config('studiior.releasing', '1', true);
  update bookings set status = 'cancelled', cancelled_at = now(), release_reason = 'studio_released'
   where occurrence_id = p_occurrence_id and status in ('booked','pending_payment');
  perform set_config('studiior.releasing', '', true);
  update class_occurrences set status = 'cancelled', cancelled_at = now(),
         cancellation_cause = 'studio_fault' where id = p_occurrence_id;
  delete from instructor_pay_records where occurrence_id = p_occurrence_id and confirmed_at is null;

  -- tell the coach the session is off (not on a late cancel: the session stands
  -- and they are paid, which tg_notify_committed_cancel already says).
  if o.instructor_id is not null and instructor_user_id(o.instructor_id) is not null then
    perform queue_shift_notice(o.studio_id, instructor_user_id(o.instructor_id), 'instructor_class_cancelled',
      jsonb_build_object('first_name', (select split_part(display_name, ' ', 1) from instructors where id = o.instructor_id),
        'class_name', o.name, 'when', v_when, 'occurrence_id', o.id,
        'reason', coalesce(nullif(btrim(p_reason), ''), 'the studio cancelled it'), 'studio_name', (select name from studios where id = o.studio_id)),
      'private_coach_cancelled:' || o.id::text);
  end if;

  for r in select b.member_id from bookings b where b.occurrence_id = p_occurrence_id loop
    perform queue_notification(o.studio_id, r.member_id, 'private_studio_cancelled',
      jsonb_build_object('first_name', (select coalesce(nullif(preferred_name, ''), first_name) from members where id = r.member_id),
        'type_name', (select name from private_session_types where id = o.private_type_id),
        'when', v_when, 'reason', coalesce(p_reason, ''),
        'reason_line', case when coalesce(btrim(p_reason), '') = '' then '' else btrim(p_reason) || '. ' end,
        'amount', fmt_money((select price_cents from private_session_types where id = o.private_type_id),
                            (select currency from studios where id = o.studio_id)),
        'studio_name', (select name from studios where id = o.studio_id),
        'book_url', member_portal_url(o.studio_id, '/book/private')),
      'private_studio_cancelled:' || r.member_id::text || ':' || o.id::text);
  end loop;
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (o.studio_id, auth.uid(), 'private.studio_cancelled', 'class_occurrences', o.id,
          jsonb_build_object('reason', p_reason, 'when', v_when));
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function private_studio_cancel(uuid, text) from public, anon;
grant execute on function private_studio_cancel(uuid, text) to authenticated, service_role;

-- ========================================================================
-- re-issue xendit_activate_success_internal (byte-faithful) + the private branch
-- ========================================================================
create or replace function xendit_activate_success_internal(p_purchase_id uuid, p_payment_id text, p_source text default 'xendit')
returns text
language plpgsql security definer set search_path = public as $$
declare p xendit_purchases%rowtype; v_ms uuid; v_prior text;
        v_group uuid; v_is_group boolean;
        o product_orders%rowtype; prod products%rowtype;
        v_b bookings%rowtype; v_occ class_occurrences%rowtype; v_free int; v_pay_id uuid;
        gc gift_cards%rowtype; v_code text; v_prov payment_provider; v_src text; v_ref text; v_send timestamptz;
begin
  select * into p from xendit_purchases where id = p_purchase_id for update;
  if p.id is null then return 'unknown_purchase'; end if;
  if p.status = 'succeeded' then return 'already_succeeded'; end if;
  v_prior := p.status;

  -- A full-credit (Decision 103(f)) completion: the payment row is source credit,
  -- provider manual, no processor reference.
  v_prov := case when p_source = 'credit' then 'manual'::payment_provider else 'xendit'::payment_provider end;
  v_src  := nullif(p_source, 'xendit');
  v_ref  := case when p_source = 'credit' then null else nullif(p_payment_id, '') end;

  if p.booking_id is not null then
    insert into payments (studio_id, member_id, booking_id, kind, amount_cents, currency,
                          status, provider, source, reference, description, paid_at)
    values (p.studio_id, p.member_id, p.booking_id, 'reservation_fee', p.amount_cents, p.currency,
            'succeeded', v_prov, v_src, v_ref, 'Reservation fee', now())
    returning id into v_pay_id;
    select * into v_b from bookings where id = p.booking_id;
    if v_b.status in ('booked', 'pending_payment') then
      perform book_first_free_run(p.booking_id);
    else
      select * into v_occ from class_occurrences where id = v_b.occurrence_id;
      v_free := coalesce(v_occ.capacity, 0) - occurrence_seats_taken(v_occ.id)
                - occurrence_seats_held(v_occ.id);
      if v_occ.id is not null and v_occ.status = 'scheduled'
         and v_occ.starts_at > now() and v_free >= 1 then
        perform restore_reservation_booking(p.booking_id);
      else
        insert into member_credits (studio_id, member_id, amount_cents, currency, reason,
                                    payment_id, booking_id)
        values (p.studio_id, p.member_id, p.amount_cents, p.currency, 'reservation_lost_seat',
                v_pay_id, p.booking_id);
        perform queue_notification(p.studio_id, p.member_id, 'free_reservation_lost_seat',
          jsonb_build_object('fee', fmt_money(p.amount_cents, p.currency),
            'class_name', coalesce(v_occ.name, 'a class'),
            'plans_url', member_portal_url(p.studio_id, '/account/plan')),
          'free_reservation_lost_seat:' || p.booking_id::text);
      end if;
    end if;

  elsif p.gift_card_id is not null then
    -- Decision 110: issue the gift card. Mint the code, record the sale (a real
    -- payment, so it counts in revenue once; linked by gift_card_id). Email the
    -- buyer at once; schedule the recipient for the delivery date (now when none).
    select * into gc from gift_cards where id = p.gift_card_id for update;
    v_code := gift_code(p.studio_id);
    -- Decision 110(a): the composited card image (amount + code over the studio's
    -- card) is served by the member host's next/og route; its path is stored on
    -- the card at issue and carried on gift_card_sent.
    update gift_cards set status = 'active', code = v_code, issued_at = now(),
           card_image_path = '/giftcard/' || gc.id::text || '/' || v_code || '/' || gc.amount_cents::text
     where id = gc.id and status in ('pending', 'active');

    insert into payments (studio_id, member_id, gift_card_id, kind, amount_cents, currency,
                          status, provider, source, reference, description, paid_at)
    values (p.studio_id, p.member_id, gc.id, 'gift_card', p.amount_cents, p.currency,
            'succeeded', v_prov, v_src, v_ref, 'Gift card', now());

    perform queue_notification(p.studio_id, gc.buyer_member_id, 'gift_card_receipt',
      jsonb_build_object('to_email', gc.buyer_email, 'buyer_name', coalesce(gc.buyer_name, 'there'),
        'recipient_name', coalesce(gc.recipient_name, 'your friend'),
        'code', v_code, 'amount', fmt_money(p.amount_cents, p.currency),
        'studio_name', (select name from studios where id = p.studio_id)),
      'gift_card_receipt:' || gc.id::text);

    v_send := case
      when gc.delivery_date is null then now()
      else greatest(now(),
        ((gc.delivery_date::text || ' 08:00')::timestamp
          at time zone (select timezone from studios where id = p.studio_id))) end;
    perform queue_notification(p.studio_id, gc.redeemed_by_member_id, 'gift_card_sent',
      jsonb_build_object('to_email', gc.recipient_email,
        'recipient_name', coalesce(gc.recipient_name, 'there'),
        'buyer_name', coalesce(gc.buyer_name, 'A friend'),
        'code', v_code, 'amount', fmt_money(p.amount_cents, p.currency),
        'message', coalesce(gc.message, ''),
        'message_html', case when coalesce(btrim(gc.message), '') = '' then ''
          else '<p style="font-style:italic;color:#57534e">&ldquo;' || replace(replace(replace(gc.message, '&', '&amp;'), '<', '&lt;'), '>', '&gt;') || '&rdquo;</p>' end,
        'card_image_url', member_portal_url(p.studio_id,
          '/giftcard/' || gc.id::text || '/' || v_code || '/' || gc.amount_cents::text),
        'redeem_url', member_portal_url(p.studio_id, '/account/redeem'),
        'studio_name', (select name from studios where id = p.studio_id)),
      'gift_card_sent:' || gc.id::text, v_send);

  elsif p.private_occurrence_id is not null then
    -- Decision 116: a full-paid private. Record the 'private' payment against the
    -- booker's seat (so Sales buckets it by the occurrence), then confirm the
    -- session at once (commit, flip seats, tell everyone, write the flat pay line).
    insert into payments (studio_id, member_id, booking_id, kind, amount_cents, currency,
                          status, provider, source, reference, description, paid_at)
    select p.studio_id, p.member_id, (select b.id from bookings b
             where b.occurrence_id = p.private_occurrence_id and b.payment_source = 'private'
             order by b.created_at limit 1),
           'private', p.amount_cents, p.currency, 'succeeded', v_prov, v_src, v_ref,
           'Private session', now()
    returning id into v_pay_id;
    select * into v_occ from class_occurrences where id = p.private_occurrence_id;
    if v_occ.status = 'scheduled' and v_occ.starts_at > now() then
      perform private_confirm_run(p.private_occurrence_id);
    else
      -- a late success on a private already released (expired session): the
      -- money is never lost, it lands as account credit (the 103(e) rule).
      insert into member_credits (studio_id, member_id, amount_cents, currency, reason, payment_id)
      values (p.studio_id, p.member_id, p.amount_cents, p.currency, 'private_refund', v_pay_id);
    end if;

  elsif p.product_order_id is not null then
    select * into o from product_orders where id = p.product_order_id for update;
    select * into prod from products where id = o.product_id for update;

    update product_orders set status = 'paid' where id = o.id and status in ('reserved', 'pending');

    if prod.track_stock then
      update products set stock = stock + o.quantity where id = prod.id;
      insert into stock_movements (studio_id, product_id, delta, reason, order_id)
      values (p.studio_id, prod.id, o.quantity, 'release', o.id);
      update products set stock = stock - o.quantity where id = prod.id;
      insert into stock_movements (studio_id, product_id, delta, reason, order_id)
      values (p.studio_id, prod.id, -o.quantity, 'sale', o.id);
    end if;

    insert into payments (studio_id, member_id, product_order_id, amount_cents, currency,
                          status, provider, source, reference, description, paid_at)
    values (p.studio_id, p.member_id, o.id, p.amount_cents, p.currency, 'succeeded', v_prov,
            v_src, v_ref, prod.name || ' ×' || o.quantity, now());

    perform queue_notification(
      p.studio_id, p.member_id, 'product_order_paid',
      jsonb_build_object('product', prod.name, 'quantity', o.quantity),
      'product_order_paid:' || o.id::text);

  else
    select type = 'group' into v_is_group from membership_plans where id = p.plan_id;
    if v_is_group then
      v_group := activate_purchase(p.studio_id, p.member_id, p.plan_id, p.amount_cents, p.currency, null, null, false);
      insert into payments (studio_id, member_id, group_purchase_id, amount_cents, currency,
                            status, provider, source, reference, description, paid_at)
      select p.studio_id, p.member_id, v_group, p.amount_cents, p.currency, 'succeeded', v_prov,
             v_src, v_ref, mp.name, now()
        from membership_plans mp where mp.id = p.plan_id;
    else
    if p.renews_membership_id is not null and exists (
         select 1 from memberships where id = p.renews_membership_id
            and status in ('active', 'past_due') and not membership_frozen_now(id)) then
      v_ms := p.renews_membership_id;
      perform advance_membership_period_run(p.renews_membership_id);
    else
      v_ms := activate_purchase(p.studio_id, p.member_id, p.plan_id, p.amount_cents, p.currency,
                                null, null, false);
      update memberships set auto_renew = false where id = v_ms;
    end if;

    perform apply_plan_to_unpaid(p.studio_id, p.member_id, v_ms);

    insert into payments (studio_id, member_id, membership_id, amount_cents, currency,
                          status, provider, source, reference, description, paid_at)
    select p.studio_id, p.member_id, v_ms, p.amount_cents, p.currency, 'succeeded', v_prov,
           v_src, v_ref, mp.name, now()
      from membership_plans mp where mp.id = p.plan_id;
    end if;
  end if;

  -- ONE consume: a plan/product (and reservation, when not via reserve_free_first)
  -- purchase consumes any reservation/gift credit applied at begin. A gift sale
  -- never carries credit_applied, so this is a no-op there.
  if p.credit_applied_cents > 0 then
    perform consume_reservation_credit(p.studio_id, p.member_id, p.credit_applied_cents);
  end if;

  if v_prior = 'expired' then
    insert into audit_logs (studio_id, action, entity_table, entity_id, after)
    values (p.studio_id, 'xendit.expiry_overridden', 'xendit_purchases', p.id,
            jsonb_build_object('prior_status', v_prior,
                               'payment_id', nullif(p_payment_id, ''),
                               'note', 'paid after local expiry'));
  end if;

  update xendit_purchases
     set status = 'succeeded', xendit_payment_id = nullif(p_payment_id, ''),
         completed_at = now(), failure_reason = null, updated_at = now()
   where id = p_purchase_id;

  return case when v_prior = 'expired' then 'activated_after_expiry' else 'activated' end;
end $$;
revoke execute on function xendit_activate_success_internal(uuid, text, text) from public, anon, authenticated;
grant  execute on function xendit_activate_success_internal(uuid, text, text) to service_role;

-- ========================================================================
-- set_occurrence_visibility — re-issued (from 20260833190000) refusing to
-- unhide a private (Decision 116).
-- ========================================================================
create or replace function set_occurrence_visibility(p_occurrence_id uuid, p_visible boolean)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare o class_occurrences%rowtype;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no_such_class'); end if;
  if not coalesce(is_manager_up(o.studio_id), false) then
    raise exception 'only owners and managers hide a class from members' using errcode = 'PT403';
  end if;
  -- Decision 116: a private is hidden by definition and can never be unhidden.
  if coalesce(o.is_private, false) and coalesce(p_visible, true) then
    raise exception 'a private session stays hidden from other members' using errcode = 'PT409';
  end if;
  update class_occurrences set hidden_from_members = not coalesce(p_visible, true), updated_at = now()
   where id = p_occurrence_id;
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (o.studio_id, auth.uid(), 'occurrence.visibility_set', 'class_occurrences', p_occurrence_id,
          jsonb_build_object('hidden_from_members', not coalesce(p_visible, true)));
  return jsonb_build_object('ok', true, 'hidden_from_members', not coalesce(p_visible, true));
end $fn$;
revoke execute on function set_occurrence_visibility(uuid, boolean) from public, anon;
grant  execute on function set_occurrence_visibility(uuid, boolean) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- MEMBERS: the Book tab / class page / Home read class_occurrences directly, so
-- the RLS is the boundary. The booked-member exception is occ_member_own_read
-- (025, OR'd, untouched): a member keeps seeing a class they booked even hidden.
-- ---------------------------------------------------------------------------
drop policy occ_member_read on class_occurrences;
create policy occ_member_read on class_occurrences for select
  using (studio_id in (select auth_member_studios())
         and status = 'scheduled'
         and month_published(studio_id, starts_at)
         and (staffing = 'assigned' or not studio_hides_unstaffed(studio_id))
         and not hidden_from_members);

-- ---------------------------------------------------------------------------
-- schedule_range (STAFF): carries occ_hidden for the "Hidden" chip; staff see all.
-- ---------------------------------------------------------------------------
drop function if exists schedule_range(uuid, date, date);
create function public.schedule_range(p_studio_id uuid, p_from date, p_to date)
 RETURNS TABLE(occ_id uuid, occ_name text, starts_at timestamp with time zone, ends_at timestamp with time zone, local_date date, local_start text, local_end text, start_minutes integer, end_minutes integer, occ_instructor_id uuid, room_name text, occ_capacity integer, occ_booked integer, occ_waitlist integer, occ_staffing text, occ_status text, occ_flex boolean, occ_confirmed boolean, occ_tier text, occ_standalone boolean, occ_series_tier text, occ_minimum integer, occ_cancellation_cause text, occ_assignment_requested boolean, occ_assignment_confirmed boolean, occ_free_first jsonb, occ_hidden boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_tz text; v_ff boolean;
begin
  if not coalesce(is_manager_up(p_studio_id), false) and not is_service_context() then
    raise exception 'the timetable is the owner''s and managers'' to see'
      using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  if v_tz is null then
    raise exception 'no such studio' using errcode = 'PT404';
  end if;
  if p_to < p_from then
    raise exception 'that range ends before it starts' using errcode = 'PT400';
  end if;
  if p_to - p_from > 62 then
    raise exception 'ask for at most 62 days at a time' using errcode = 'PT422';
  end if;

  -- Decision 30 amendment (b) follow-up: only compute the per-class free-first
  -- state when the studio uses the feature — otherwise it is null and the popup
  -- card and the "Trials" marker are hidden.
  select free_first_class_enabled into v_ff from studio_settings where studio_id = p_studio_id;

  return query
  select o.id, o.name, o.starts_at, o.ends_at,
         (o.starts_at at time zone v_tz)::date,
         to_char(o.starts_at at time zone v_tz, 'HH24:MI'),
         to_char(o.ends_at   at time zone v_tz, 'HH24:MI'),
         (extract(hour from o.starts_at at time zone v_tz) * 60
          + extract(minute from o.starts_at at time zone v_tz))::int,
         (extract(hour from o.ends_at at time zone v_tz) * 60
          + extract(minute from o.ends_at at time zone v_tz))::int,
         o.instructor_id, r.name, o.capacity, o.booked_count, o.waitlist_count,
         o.staffing::text, o.status::text,
         o.flex, o.committed_at is not null,
         g.tier::text,
         (g.tier = 'flex' and not occurrence_is_adjacent_run(o.id)),
         coalesce(
           o.guarantee_tier,
           case when o.flex then 'flex'::guarantee_tier end,
           ser.guarantee_tier,
           case when ser.flex then 'flex'::guarantee_tier end,
           'core'::guarantee_tier)::text,
         g.minimum,
         o.cancellation_cause::text,
         o.assignment_requested_at is not null,
         o.assignment_confirmed_at is not null,
         case when coalesce(v_ff, false) then effective_free_first(o.id) else null end,
         o.hidden_from_members
    from class_occurrences o
    cross join lateral occurrence_guarantee_run(o.id) g
    left join class_series ser on ser.id = o.series_id
    left join rooms r on r.id = o.room_id
   where o.studio_id = p_studio_id
     and (o.status <> 'cancelled'
          or o.cancellation_cause in ('unmet_minimum','no_instructor','studio_fault','force_majeure'))
     and (o.starts_at at time zone v_tz)::date between p_from and p_to
   order by o.starts_at;
end $function$;
revoke execute on function set_occurrence_visibility(uuid, boolean) from public, anon;
grant  execute on function set_occurrence_visibility(uuid, boolean) to authenticated, service_role;

-- ========================================================================
-- private_release_run — an unpaid Xendit private (payment failed or expired)
-- is released: its pending seats and the occurrence are cancelled so the room
-- and the coach are free again. No refund (nothing was paid), no email. Service.
-- ========================================================================
create or replace function private_release_run(p_occurrence_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare o class_occurrences%rowtype;
begin
  select * into o from class_occurrences where id = p_occurrence_id for update;
  if o.id is null or not coalesce(o.is_private, false) then return; end if;
  if o.committed_at is not null or o.status <> 'scheduled' then return; end if;  -- paid, or already gone
  perform set_config('studiior.releasing', '1', true);
  update bookings set status = 'cancelled', cancelled_at = now(), release_reason = 'studio_released'
   where occurrence_id = p_occurrence_id and status = 'pending_payment';
  perform set_config('studiior.releasing', '', true);
  update class_occurrences set status = 'cancelled', cancelled_at = now(),
         cancellation_cause = 'studio_fault' where id = p_occurrence_id;
  insert into audit_logs (studio_id, action, entity_table, entity_id, after)
  values (o.studio_id, 'private.released_unpaid', 'class_occurrences', o.id,
          jsonb_build_object('starts_at', o.starts_at));
end $$;
revoke execute on function private_release_run(uuid) from public, anon, authenticated;
grant  execute on function private_release_run(uuid) to service_role;

-- xendit_fail_purchase_internal — re-issued (from 20260833560000) with the
-- private branch: a failed or expired private session releases the hold.
create or replace function xendit_fail_purchase_internal(p_purchase_id uuid, p_status text, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare p xendit_purchases%rowtype; o product_orders%rowtype; prod products%rowtype; n int;
begin
  select * into p from xendit_purchases where id = p_purchase_id for update;
  if p.id is null or p.status in ('succeeded') then return; end if;

  update xendit_purchases
     set status = p_status, failure_reason = p_reason, completed_at = now(), updated_at = now()
   where id = p_purchase_id and status = 'pending';

  if p.booking_id is not null then
    -- Decision 103(e): release the held seat at once rather than waiting for the
    -- sweep. No email (the class page tells the member "Your spot wasn't held.").
    if exists (select 1 from bookings b where b.id = p.booking_id and b.status = 'pending_payment') then
      perform cancel_booking(p.booking_id);
    end if;
    return;
  elsif p.private_occurrence_id is not null then
    -- Decision 116: an unpaid private is released (room and coach freed). No email.
    perform private_release_run(p.private_occurrence_id);
    return;
  elsif p.gift_card_id is not null then
    -- Decision 110: the gift was never issued (payment failed). Void the pending
    -- card so a later card is minted fresh; nobody is emailed.
    update gift_cards set status = 'void', voided_at = now(), void_reason = coalesce(p_reason, 'payment failed')
     where id = p.gift_card_id and status = 'pending';
    return;
  elsif p.product_order_id is not null then
    select * into o from product_orders where id = p.product_order_id for update;
    update product_orders set status = 'cancelled'
     where id = p.product_order_id and status in ('reserved', 'pending');
    get diagnostics n = row_count;
    if n = 1 then
      select * into prod from products where id = o.product_id for update;
      if prod.track_stock then
        update products set stock = stock + o.quantity where id = prod.id;
        insert into stock_movements (studio_id, product_id, delta, reason, order_id)
        values (p.studio_id, prod.id, o.quantity, 'release', o.id);
      end if;
    end if;
    perform queue_notification(
      p.studio_id, p.member_id, 'xendit_purchase_failed',
      jsonb_build_object('plan_name', (select name from products where id = o.product_id)),
      'xendit_failed:' || p_purchase_id::text);
  else
    perform queue_notification(
      p.studio_id, p.member_id, 'xendit_purchase_failed',
      jsonb_build_object('plan_name', (select name from membership_plans where id = p.plan_id)),
      'xendit_failed:' || p_purchase_id::text);
  end if;
end $$;
revoke execute on function xendit_fail_purchase_internal(uuid, text, text) from public, anon, authenticated;
grant  execute on function xendit_fail_purchase_internal(uuid, text, text) to service_role;

-- sweep_unpaid_dropins — re-issued (from 20260833500000) leaving a private's
-- pending seats to the private release path.
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
       and coalesce(b.hold_reason, '') <> 'free_class_duplicate'  -- Decision 98 holds have their own 24h sweep
       -- Decision 116: a private's pending seats are released with the whole
       -- occurrence by the Xendit failure/expiry path, never one seat at a time.
       and b.payment_source is distinct from 'private'
       and (
         -- Decision 103(e): a reservation hold lasts until its hold_until (30 min).
         (b.hold_until is not null and now() >= b.hold_until)
         -- an unpaid drop-in (and a legacy reservation hold) at booked_at + window.
         or (b.hold_until is null and b.booked_at < now()
               - make_interval(mins => coalesce(st.dropin_payment_window_minutes, 15)))
       )
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

      -- Decision 103(c): expire the matching pending xendit purchase now, rather
      -- than leaving it for the daily reconcile — its booking is cancelled.
      update xendit_purchases
         set status = 'expired',
             failure_reason = 'hold_released',
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

-- ========================================================================
-- Private session types — manager-up CRUD (Settings). At most three active
-- types per studio (Decision 116: up to three).
-- ========================================================================
create or replace function private_type_save(
  p_studio_id uuid, p_id uuid, p_name text, p_price_cents int, p_people int,
  p_duration_min int, p_coach_pay_cents int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers set up private sessions' using errcode = 'PT403'; end if;
  if coalesce(btrim(p_name), '') = '' then raise exception 'a name is needed' using errcode = 'PT400'; end if;
  if p_people is null or p_people not between 1 and 3 then
    raise exception 'a private is for 1, 2 or 3 people' using errcode = 'PT400'; end if;
  if p_price_cents is null or p_price_cents < 0 or p_coach_pay_cents is null or p_coach_pay_cents < 0 then
    raise exception 'price and coach pay must be zero or more' using errcode = 'PT400'; end if;
  if p_duration_min is null or p_duration_min not between 10 and 240 then
    raise exception 'a private runs 10 to 240 minutes' using errcode = 'PT400'; end if;
  if p_id is null then
    if (select count(*) from private_session_types where studio_id = p_studio_id and active) >= 3 then
      raise exception 'a studio offers up to three private session types' using errcode = 'PT409'; end if;
    insert into private_session_types (studio_id, name, price_cents, people, duration_min, coach_pay_cents, sort)
    values (p_studio_id, btrim(p_name), p_price_cents, p_people, p_duration_min, p_coach_pay_cents,
            coalesce((select max(sort) + 1 from private_session_types where studio_id = p_studio_id), 1))
    returning id into v_id;
  else
    update private_session_types
       set name = btrim(p_name), price_cents = p_price_cents, people = p_people,
           duration_min = p_duration_min, coach_pay_cents = p_coach_pay_cents
     where id = p_id and studio_id = p_studio_id
    returning id into v_id;
    if v_id is null then raise exception 'no such private session type' using errcode = 'PT404'; end if;
  end if;
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (p_studio_id, auth.uid(), 'private_type.saved', 'private_session_types', v_id,
          jsonb_build_object('name', p_name, 'price_cents', p_price_cents, 'people', p_people,
                             'duration_min', p_duration_min, 'coach_pay_cents', p_coach_pay_cents));
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;
revoke execute on function private_type_save(uuid, uuid, text, int, int, int, int) from public, anon;
grant  execute on function private_type_save(uuid, uuid, text, int, int, int, int) to authenticated, service_role;

create or replace function private_type_toggle(p_id uuid, p_active boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t private_session_types%rowtype;
begin
  select * into t from private_session_types where id = p_id;
  if t.id is null then raise exception 'no such private session type' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(t.studio_id), false) then
    raise exception 'only owners and managers set up private sessions' using errcode = 'PT403'; end if;
  if coalesce(p_active, false) and not t.active
     and (select count(*) from private_session_types where studio_id = t.studio_id and active) >= 3 then
    raise exception 'a studio offers up to three private session types' using errcode = 'PT409'; end if;
  update private_session_types set active = coalesce(p_active, false) where id = p_id;
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (t.studio_id, auth.uid(), 'private_type.toggled', 'private_session_types', p_id,
          jsonb_build_object('active', coalesce(p_active, false)));
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function private_type_toggle(uuid, boolean) from public, anon;
grant  execute on function private_type_toggle(uuid, boolean) to authenticated, service_role;

-- ========================================================================
-- schedule_range — re-issued (from 20260833190000) with occ_is_private so the
-- staff Schedule draws a "Private" block; a cancelled private leaves the
-- calendar (its room is free again). RETURNS TABLE changes: drop + recreate.
-- ========================================================================
drop function if exists schedule_range(uuid, date, date);
create function public.schedule_range(p_studio_id uuid, p_from date, p_to date)
 RETURNS TABLE(occ_id uuid, occ_name text, starts_at timestamp with time zone, ends_at timestamp with time zone, local_date date, local_start text, local_end text, start_minutes integer, end_minutes integer, occ_instructor_id uuid, room_name text, occ_capacity integer, occ_booked integer, occ_waitlist integer, occ_staffing text, occ_status text, occ_flex boolean, occ_confirmed boolean, occ_tier text, occ_standalone boolean, occ_series_tier text, occ_minimum integer, occ_cancellation_cause text, occ_assignment_requested boolean, occ_assignment_confirmed boolean, occ_free_first jsonb, occ_hidden boolean, occ_is_private boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_tz text; v_ff boolean;
begin
  if not coalesce(is_manager_up(p_studio_id), false) and not is_service_context() then
    raise exception 'the timetable is the owner''s and managers'' to see'
      using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  if v_tz is null then
    raise exception 'no such studio' using errcode = 'PT404';
  end if;
  if p_to < p_from then
    raise exception 'that range ends before it starts' using errcode = 'PT400';
  end if;
  if p_to - p_from > 62 then
    raise exception 'ask for at most 62 days at a time' using errcode = 'PT422';
  end if;

  -- Decision 30 amendment (b) follow-up: only compute the per-class free-first
  -- state when the studio uses the feature — otherwise it is null and the popup
  -- card and the "Trials" marker are hidden.
  select free_first_class_enabled into v_ff from studio_settings where studio_id = p_studio_id;

  return query
  select o.id, o.name, o.starts_at, o.ends_at,
         (o.starts_at at time zone v_tz)::date,
         to_char(o.starts_at at time zone v_tz, 'HH24:MI'),
         to_char(o.ends_at   at time zone v_tz, 'HH24:MI'),
         (extract(hour from o.starts_at at time zone v_tz) * 60
          + extract(minute from o.starts_at at time zone v_tz))::int,
         (extract(hour from o.ends_at at time zone v_tz) * 60
          + extract(minute from o.ends_at at time zone v_tz))::int,
         o.instructor_id, r.name, o.capacity, o.booked_count, o.waitlist_count,
         o.staffing::text, o.status::text,
         o.flex, o.committed_at is not null,
         g.tier::text,
         (g.tier = 'flex' and not occurrence_is_adjacent_run(o.id)),
         coalesce(
           o.guarantee_tier,
           case when o.flex then 'flex'::guarantee_tier end,
           ser.guarantee_tier,
           case when ser.flex then 'flex'::guarantee_tier end,
           'core'::guarantee_tier)::text,
         g.minimum,
         o.cancellation_cause::text,
         o.assignment_requested_at is not null,
         o.assignment_confirmed_at is not null,
         case when coalesce(v_ff, false) then effective_free_first(o.id) else null end,
         o.hidden_from_members,
         coalesce(o.is_private, false)
    from class_occurrences o
    cross join lateral occurrence_guarantee_run(o.id) g
    left join class_series ser on ser.id = o.series_id
    left join rooms r on r.id = o.room_id
   where o.studio_id = p_studio_id
     and (o.status <> 'cancelled'
          or (not coalesce(o.is_private, false)
              and o.cancellation_cause in ('unmet_minimum','no_instructor','studio_fault','force_majeure')))
     and (o.starts_at at time zone v_tz)::date between p_from and p_to
   order by o.starts_at;
end $function$;
revoke execute on function schedule_range(uuid, date, date) from public, anon;
grant  execute on function schedule_range(uuid, date, date) to authenticated, service_role;

-- dashboard_revenue — re-issued (from 20260833560000): a Decision 116 private
-- (is_private occurrence / 'private' payment) buckets as Private sessions.
create or replace function dashboard_revenue(
  p_studio_id uuid, p_from date, p_to date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tz text; v_currency char(3); v_today date;
  v_f0 timestamptz; v_t1 timestamptz;
  v_span int; v_pf0 timestamptz; v_pt1 timestamptz;
  v_total bigint; v_prior bigint; v_refunds bigint; v_ever bigint;
  v_series jsonb; v_sources jsonb; v_counts jsonb;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'revenue is for owners and managers' using errcode = 'PT403';
  end if;
  select s.timezone, s.currency into v_tz, v_currency from studios s where s.id = p_studio_id;
  if v_tz is null then raise exception 'no such studio' using errcode = 'PT404'; end if;
  if p_to < p_from then
    raise exception 'the range ends before it starts' using errcode = 'PT422';
  end if;

  v_today := studio_today(p_studio_id);
  select day_start into v_f0 from studio_day_bounds(p_studio_id, p_from);
  select day_start into v_t1 from studio_day_bounds(p_studio_id, p_to + 1);
  v_span := (p_to - p_from) + 1;
  select day_start into v_pf0 from studio_day_bounds(p_studio_id, p_from - v_span);
  select day_start into v_pt1 from studio_day_bounds(p_studio_id, p_from);

  v_total := studio_revenue_between(p_studio_id, v_f0, v_t1);
  v_prior := studio_revenue_between(p_studio_id, v_pf0, v_pt1);
  select coalesce(sum(p.amount_cents),0)::bigint into v_ever from payments p
   where p.studio_id = p_studio_id and p.status in ('succeeded','partially_refunded')
     and coalesce(p.source, '') <> 'credit';

  select coalesce(sum(r.amount_cents),0)::bigint into v_refunds
    from refunds r join payments p on p.id = r.payment_id
   where p.studio_id = p_studio_id
     and r.created_at >= v_f0 and r.created_at < v_t1;

  select coalesce(jsonb_agg(jsonb_build_object('date', d.day, 'cents', coalesce(x.cents,0))
                            order by d.day), '[]'::jsonb)
    into v_series
    from generate_series(p_from, p_to, interval '1 day') g(day_ts)
    cross join lateral (select g.day_ts::date as day) d
    left join lateral (
      select coalesce(sum(p.amount_cents),0)::bigint as cents
        from payments p
       where p.studio_id = p_studio_id and p.status in ('succeeded','partially_refunded')
         and coalesce(p.source, '') <> 'credit'
         and (coalesce(p.paid_at, p.created_at) at time zone v_tz)::date = d.day
    ) x on true;

  with classified as (
    select p.amount_cents,
           case
             when p.gift_card_id is not null then 'gift'
             when p.product_order_id is not null then 'merch'
             when p.kind = 'reservation_fee' and coalesce(p.method, '') <> 'reservation_credit' then 'reservation'
             when coalesce(o.is_private, false) or p.kind = 'private' then 'private'
             when ct.session_kind in ('private','duo','trio') then 'private'
             when pl.type = 'recurring'  then 'membership'
             when pl.type = 'class_pack' then 'pack'
             when pl.type = 'trial'      then 'trial'
             when b.payment_source = 'drop_in' then 'drop_in'
             when pl.type = 'drop_in'    then 'drop_in'
             else 'other'
           end as src
      from payments p
      left join memberships ms on ms.id = p.membership_id
      left join membership_plans pl on pl.id = ms.plan_id
      left join bookings b on b.id = p.booking_id
      left join class_occurrences o on o.id = b.occurrence_id
      left join class_types ct on ct.id = o.class_type_id
     where p.studio_id = p_studio_id and p.status in ('succeeded','partially_refunded')
       and coalesce(p.source, '') <> 'credit'
       and coalesce(p.paid_at, p.created_at) >= v_f0
       and coalesce(p.paid_at, p.created_at) <  v_t1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'source', src, 'label', dashboard_source_label(src), 'cents', cents,
           'pct', case when v_total = 0 then 0 else round(100.0 * cents / v_total) end)
           order by cents desc), '[]'::jsonb)
    into v_sources
    from (select src, sum(amount_cents)::bigint as cents from classified group by src) s;

  select jsonb_build_object(
      'bookings', (select count(*) from bookings b
                    where b.studio_id = p_studio_id and b.status <> 'waitlisted'
                      and b.booked_at >= v_f0 and b.booked_at < v_t1),
      'memberships_sold', (select count(*) from memberships ms
                    where ms.studio_id = p_studio_id
                      and ms.created_at >= v_f0 and ms.created_at < v_t1
                      and not coalesce(ms.complimentary, false)),
      'refunds_cents', v_refunds)
    into v_counts;

  return jsonb_build_object(
    'from', p_from, 'to', p_to, 'days', v_span, 'currency', v_currency,
    'state', case when v_ever = 0 then 'empty' else 'ok' end,
    'total_cents', v_total,
    'trend', dashboard_trend(v_total, v_prior, 'the ' || v_span || ' days before'),
    'series', v_series, 'by_source', v_sources, 'counts', v_counts,
    'empty_hint', 'Every payment you take shows up here — by day, and split by what it was for. Record a payment at the desk or connect Stripe and this starts filling.');
end $$;

-- sales_history — re-issued (from 20260833560000) with the private arm.
create or replace function sales_history(
  p_studio_id uuid, p_from date, p_to date,
  p_plan_id uuid default null, p_status text default null
) returns table (
  membership_id uuid, member_id uuid, member_name text,
  plan_id uuid, plan_name text, plan_type text,
  amount_cents int, currency char(3), payment_source text,
  bought_on timestamptz, starts_on date, expires_on date, sale_status text,
  is_renewal boolean
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare v_tz text; v_today date; v_f0 timestamptz; v_t1 timestamptz;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'sales are for owners and managers' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios s where s.id = p_studio_id;
  v_today := (now() at time zone v_tz)::date;
  select day_start into v_f0 from studio_day_bounds(p_studio_id, p_from);
  select day_start into v_t1 from studio_day_bounds(p_studio_id, p_to + 1);

  return query
  with pay as (
    select distinct on (p.membership_id)
           p.membership_id, p.amount_cents, p.currency, p.provider, p.method, p.status as pstatus,
           coalesce(p.paid_at, p.created_at) as paid_ts
      from payments p
     where p.studio_id = p_studio_id and p.membership_id is not null
     order by p.membership_id, coalesce(p.paid_at, p.created_at) desc
  )
  select ms.id, ms.member_id,
         (m.first_name || ' ' || m.last_name) as member_name,
         ms.plan_id, mp.name, mp.type::text,
         coalesce(pay.amount_cents, ms.price_cents) as amount_cents,
         ms.currency,
         coalesce(
           case when pay.provider = 'stripe' then 'Card (Stripe)'
                when pay.provider = 'xendit' then 'Card (Xendit)'
                when pay.method = 'gcash' then 'GCash'
                when pay.method = 'bank_transfer' then 'Bank transfer'
                when pay.method = 'card_terminal' then 'Card (terminal)'
                when pay.method = 'cash' then 'Cash'
                when pay.method = 'other' then 'Other'
                when pay.membership_id is not null then 'Recorded'
           end, 'Unpaid') as payment_source,
         coalesce(pay.paid_ts, ms.created_at) as bought_on,
         ms.starts_on, ms.expires_on,
         (case
            when pay.pstatus = 'refunded' then 'refunded'
            when ms.status = 'frozen' then 'frozen'
            when pay.membership_id is null or pay.pstatus = 'pending' then 'unpaid'
            when ms.status in ('cancelled', 'expired') then 'expired'
            when ms.expires_on is not null and ms.expires_on <= v_today + 14 then 'expiring'
            else 'active'
          end) as sale_status,
         (select count(*) from payments p2
           where p2.membership_id = ms.id
             and p2.status in ('succeeded', 'partially_refunded')) > 1 as is_renewal
    from memberships ms
    join members m on m.id = ms.member_id
    join membership_plans mp on mp.id = ms.plan_id
    left join pay on pay.membership_id = ms.id
   where ms.studio_id = p_studio_id
     and not coalesce(ms.complimentary, false)
     and coalesce(pay.paid_ts, ms.created_at) >= v_f0
     and coalesce(pay.paid_ts, ms.created_at) <  v_t1
     and (p_plan_id is null or ms.plan_id = p_plan_id)
     and (p_status  is null or p_status = (case
            when pay.pstatus = 'refunded' then 'refunded'
            when ms.status = 'frozen' then 'frozen'
            when pay.membership_id is null or pay.pstatus = 'pending' then 'unpaid'
            when ms.status in ('cancelled', 'expired') then 'expired'
            when ms.expires_on is not null and ms.expires_on <= v_today + 14 then 'expiring'
            else 'active' end))

  union all

  select null::uuid, p.member_id,
         coalesce(m.first_name || ' ' || m.last_name, 'Walk-in') as member_name,
         null::uuid, (pr.name || ' ×' || po.quantity) as plan_name, 'merch' as plan_type,
         p.amount_cents, p.currency,
         (case when p.provider = 'xendit' then 'Card (Xendit)'
               when p.provider = 'stripe' then 'Card (Stripe)'
               when p.method = 'gcash' then 'GCash'
               when p.method = 'bank_transfer' then 'Bank transfer'
               when p.method = 'card_terminal' then 'Card (terminal)'
               when p.method = 'cash' then 'Cash'
               when p.method = 'other' then 'Other'
               else 'Recorded' end) as payment_source,
         coalesce(p.paid_at, p.created_at) as bought_on,
         null::date, null::date,
         (case when p.status in ('refunded','partially_refunded') or coalesce(p.refunded_cents,0) > 0
               then 'refunded' else 'active' end) as sale_status,
         false as is_renewal
    from payments p
    join product_orders po on po.id = p.product_order_id
    join products pr on pr.id = po.product_id
    left join members m on m.id = p.member_id
   where p.studio_id = p_studio_id and p.status in ('succeeded','partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1
     and p_plan_id is null
     and (p_status is null or p_status = (case
            when p.status in ('refunded','partially_refunded') or coalesce(p.refunded_cents,0) > 0
            then 'refunded' else 'active' end))

  union all

  select null::uuid, p.member_id,
         coalesce(m.first_name || ' ' || m.last_name, 'Walk-in') as member_name,
         null::uuid, ('Reservation · ' || coalesce(o.name, 'a class')) as plan_name,
         'reservation_fee' as plan_type,
         p.amount_cents, p.currency,
         (case when p.provider = 'xendit' then 'Card (Xendit)'
               when p.provider = 'stripe' then 'Card (Stripe)'
               when p.method = 'gcash' then 'GCash'
               when p.method = 'card_terminal' then 'Card (terminal)'
               when p.method = 'cash' then 'Cash'
               else 'Recorded' end) as payment_source,
         coalesce(p.paid_at, p.created_at) as bought_on,
         null::date, null::date,
         (case when p.status in ('refunded','partially_refunded') or coalesce(p.refunded_cents,0) > 0
               then 'refunded' else 'active' end) as sale_status,
         false as is_renewal
    from payments p
    left join bookings b on b.id = p.booking_id
    left join class_occurrences o on o.id = b.occurrence_id
    left join members m on m.id = p.member_id
   where p.studio_id = p_studio_id and p.kind = 'reservation_fee'
     and coalesce(p.method, '') <> 'reservation_credit'
     and p.status in ('succeeded','partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1
     and p_plan_id is null
     and (p_status is null or p_status = (case
            when p.status in ('refunded','partially_refunded') or coalesce(p.refunded_cents,0) > 0
            then 'refunded' else 'active' end))

  union all

  -- Decision 110: a gift card SALE (real cash; counted once, here). plan_type
  -- 'gift'; no membership, never a renewal. The redemption is NOT a sale.
  select null::uuid, p.member_id,
         coalesce(gc.buyer_name, 'Gift purchase') as member_name,
         null::uuid, ('Gift card · ' || coalesce(gc.recipient_name, gc.recipient_email, 'a friend')) as plan_name,
         'gift' as plan_type,
         p.amount_cents, p.currency,
         (case when p.provider = 'xendit' then 'Card (Xendit)'
               when p.provider = 'stripe' then 'Card (Stripe)'
               else 'Recorded' end) as payment_source,
         coalesce(p.paid_at, p.created_at) as bought_on,
         null::date, null::date,
         (case when p.status in ('refunded','partially_refunded') or coalesce(p.refunded_cents,0) > 0
               then 'refunded' else 'active' end) as sale_status,
         false as is_renewal
    from payments p
    join gift_cards gc on gc.id = p.gift_card_id
   where p.studio_id = p_studio_id and p.gift_card_id is not null
     and coalesce(p.source, '') <> 'credit'
     and p.status in ('succeeded','partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1
     and p_plan_id is null
     and (p_status is null or p_status = (case
            when p.status in ('refunded','partially_refunded') or coalesce(p.refunded_cents,0) > 0
            then 'refunded' else 'active' end))

  union all

  -- Decision 116: a private session sale (the booker's 'private' payment, cash
  -- or card; a source-credit rebook is not a sale). plan_type 'private'.
  select null::uuid, p.member_id,
         coalesce(m.first_name || ' ' || m.last_name, 'Walk-in') as member_name,
         null::uuid, ('Private · ' || coalesce(pst.name, 'session')) as plan_name,
         'private' as plan_type,
         p.amount_cents, p.currency,
         (case when p.provider = 'xendit' then 'Card (Xendit)'
               when p.provider = 'stripe' then 'Card (Stripe)'
               when p.method = 'gcash' then 'GCash'
               when p.method = 'bank_transfer' then 'Bank transfer'
               when p.method = 'card_terminal' then 'Card (terminal)'
               when p.method = 'cash' then 'Cash'
               when p.method = 'other' then 'Other'
               else 'Recorded' end) as payment_source,
         coalesce(p.paid_at, p.created_at) as bought_on,
         (o.starts_at at time zone v_tz)::date, null::date,
         (case when p.status in ('refunded','partially_refunded') or coalesce(p.refunded_cents,0) > 0
               then 'refunded' else 'active' end) as sale_status,
         false as is_renewal
    from payments p
    join bookings b on b.id = p.booking_id
    join class_occurrences o on o.id = b.occurrence_id
    left join private_session_types pst on pst.id = o.private_type_id
    left join members m on m.id = p.member_id
   where p.studio_id = p_studio_id and p.kind = 'private'
     and coalesce(p.source, '') <> 'credit'
     and p.status in ('succeeded','partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1
     and p_plan_id is null
     and (p_status is null or p_status = (case
            when p.status in ('refunded','partially_refunded') or coalesce(p.refunded_cents,0) > 0
            then 'refunded' else 'active' end))

  order by bought_on desc;
end $$;
revoke all on function sales_history(uuid, date, date, uuid, text) from public, anon;
grant execute on function sales_history(uuid, date, date, uuid, text) to authenticated, service_role;

-- sales_totals — re-issued (from 20260833560000) with the Private sessions line:
-- price, after VAT (12 percent inclusive), coach pay, studio keeps.
create or replace function sales_totals(
  p_studio_id uuid, p_from date, p_to date,
  p_plan_id uuid default null, p_status text default null
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_currency char(3); v_count int; v_gross bigint; v_refunded bigint; v_studio_total bigint;
  v_f0 timestamptz; v_t1 timestamptz; v_resv_count int; v_resv_total bigint;
  v_ref_count int; v_ref_total bigint;
  v_gift_count int; v_gift_total bigint; v_redeem_count int; v_redeem_total bigint;
  v_priv_count int; v_priv_total bigint; v_priv_coach bigint;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'sales are for owners and managers' using errcode = 'PT403';
  end if;
  select currency into v_currency from studios s where s.id = p_studio_id;
  select day_start into v_f0 from studio_day_bounds(p_studio_id, p_from);
  select day_start into v_t1 from studio_day_bounds(p_studio_id, p_to + 1);

  select count(*) into v_count
    from sales_history(p_studio_id, p_from, p_to, p_plan_id, p_status);

  select coalesce(sum(p.amount_cents), 0)::bigint,
         coalesce(sum(p.refunded_cents), 0)::bigint
    into v_gross, v_refunded
    from payments p
    left join memberships ms on ms.id = p.membership_id
   where p.studio_id = p_studio_id
     and p.status in ('succeeded', 'partially_refunded')
     and (p.membership_id is not null or p.product_order_id is not null)
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1
     and (p_plan_id is null or ms.plan_id = p_plan_id);

  v_studio_total := studio_revenue_between(p_studio_id, v_f0, v_t1);

  select count(*), coalesce(sum(p.amount_cents - coalesce(p.refunded_cents, 0)), 0)::bigint
    into v_resv_count, v_resv_total
    from payments p
   where p.studio_id = p_studio_id and p.kind = 'reservation_fee'
     and coalesce(p.method, '') <> 'reservation_credit'
     and p.status in ('succeeded', 'partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1;

  select count(*), coalesce(sum(pr.amount_cents), 0)::bigint
    into v_ref_count, v_ref_total
    from payment_refunds pr
   where pr.studio_id = p_studio_id and pr.status = 'succeeded'
     and coalesce(pr.settled_at, pr.created_at) >= v_f0
     and coalesce(pr.settled_at, pr.created_at) <  v_t1;

  -- Decision 110: gift cards sold (cash received), and gift credit redeemed
  -- (source credit, excluded from revenue — shown so the two can be reconciled).
  select count(*), coalesce(sum(p.amount_cents - coalesce(p.refunded_cents, 0)), 0)::bigint
    into v_gift_count, v_gift_total
    from payments p
   where p.studio_id = p_studio_id and p.gift_card_id is not null
     and coalesce(p.source, '') <> 'credit'
     and p.status in ('succeeded', 'partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1;

  select count(*), coalesce(sum(p.amount_cents), 0)::bigint
    into v_redeem_count, v_redeem_total
    from payments p
   where p.studio_id = p_studio_id and coalesce(p.source, '') = 'credit'
     and p.status in ('succeeded', 'partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1;

  -- Decision 116: private sessions sold in the period (cash/card, not a credit
  -- rebook), the coach pay read from each session's pay record, and the VAT
  -- split (12 percent inclusive, the Decision 88c invoice arithmetic).
  select count(*), coalesce(sum(p.amount_cents - coalesce(p.refunded_cents, 0)), 0)::bigint,
         coalesce(sum(coalesce((select ipr.amount_cents from instructor_pay_records ipr
                                 where ipr.occurrence_id = b.occurrence_id and ipr.type = 'class'
                                 limit 1), 0)), 0)::bigint
    into v_priv_count, v_priv_total, v_priv_coach
    from payments p
    join bookings b on b.id = p.booking_id
   where p.studio_id = p_studio_id and p.kind = 'private'
     and coalesce(p.source, '') <> 'credit'
     and p.status in ('succeeded', 'partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1;

  return jsonb_build_object(
    'private', jsonb_build_object('count', v_priv_count, 'total_cents', v_priv_total,
      'after_vat_cents', round(v_priv_total / 1.12)::bigint,
      'vat_cents', v_priv_total - round(v_priv_total / 1.12)::bigint,
      'coach_pay_cents', v_priv_coach,
      'studio_keeps_cents', v_priv_total - v_priv_coach),
    'refunds', jsonb_build_object('count', v_ref_count, 'total_cents', v_ref_total),
    'reservation_fees', jsonb_build_object('count', v_resv_count, 'total_cents', v_resv_total),
    'gift_sold', jsonb_build_object('count', v_gift_count, 'total_cents', v_gift_total),
    'gift_redeemed', jsonb_build_object('count', v_redeem_count, 'total_cents', v_redeem_total),
    'count', v_count,
    'gross_cents', v_gross,
    'refunded_cents', v_refunded,
    'net_cents', v_gross - v_refunded,
    'studio_total_cents', v_studio_total,
    'currency', v_currency);
end $$;

-- ========================================================================
-- member_bootstrap — re-issued (from 20260833470000) + gift_credit_cents,
-- private_sessions_enabled, gift_enabled, private_pack_credits. RETURNS TABLE
-- changes: drop + recreate, authenticated-only.
-- ========================================================================
drop function if exists member_bootstrap(text);
CREATE FUNCTION public.member_bootstrap(p_slug text)
 RETURNS TABLE(member_id uuid, studio_id uuid, first_name text, last_name text, preferred_name text, avatar_path text, status member_status, current_streak integer, lifetime_visits integer, studio_name text, studio_timezone text, logo_url text, theme_preset theme_preset, accent_color text, checkin_opens_minutes_before integer, checkin_closes_minutes_after integer, cancellation_cutoff_minutes integer, booking_cutoff_minutes integer, waitlist_enabled boolean, billing_status platform_status, billing_locked boolean, open_offers integer, guest_passes_enabled boolean, has_payment_provider boolean, booking_window_days integer, how_to_buy text, studio_contact_email text, xendit_enabled boolean, time_format text, trial_used boolean, messages_enabled boolean, has_unread_studio_message boolean, desk_pay_available boolean, payee_notice_name text, has_phone boolean, country text, free_first_reservation_fee_cents integer, currency text, fee_waived boolean, reservation_credit_cents integer, free_first_core_only boolean, guarantees_enabled boolean, can_invite_guest boolean, gift_credit_cents integer, private_sessions_enabled boolean, gift_enabled boolean, private_pack_credits integer, private_lead_time_hours integer)
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
                    and (ms2.credits_remaining is null or ms2.credits_remaining > 0))),
    -- Decision 110(a): the Account Credits card names gift credit apart from the
    -- reservation and refund credit (reservation_credit_cents stays the TOTAL the
    -- checkout applies).
    coalesce((select sum(mc.amount_cents - mc.used_cents)::int from member_credits mc
               where mc.studio_id = m.studio_id and mc.member_id = m.id and mc.voided_at is null
                 and mc.reason = 'gift_credit'), 0),
    -- Decision 116: the Book tab offers Private sessions when the studio does.
    coalesce(st.private_sessions_enabled, false)
      and exists (select 1 from private_session_types pst where pst.studio_id = m.studio_id and pst.active),
    coalesce(st.gift_enabled, false),
    coalesce((select sum(ms3.credits_remaining)::int from memberships ms3
               join membership_plans mp3 on mp3.id = ms3.plan_id
              where ms3.member_id = m.id and mp3.private_pack
                and ms3.status in ('active', 'trialing') and coalesce(ms3.credits_remaining, 0) > 0
                and (ms3.expires_on is null or ms3.expires_on >= (now() at time zone s.timezone)::date)), 0),
    coalesce(st.private_lead_time_hours, 24)
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

-- apply_payment_refund — re-issued (from 20260833540000) voiding an unredeemed
-- gift card whose sale is refunded (Decision 110(a)).
create or replace function apply_payment_refund(p_refund_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare rf payment_refunds%rowtype; pay payments%rowtype; ms memberships%rowtype;
        plan membership_plans%rowtype; v_total int; v_full boolean; v_bal int; v_take int := 0;
begin
  select * into rf from payment_refunds where id = p_refund_id for update;
  if not found then return; end if;
  select * into pay from payments where id = rf.payment_id for update;
  if not found then return; end if;

  v_total := coalesce(pay.refunded_cents, 0) + rf.amount_cents;
  v_full  := v_total >= pay.amount_cents;
  update payments
     set refunded_cents = v_total, refunded_at = now(),
         refund_reason = coalesce(rf.reason, refund_reason),
         status = (case when v_full then 'refunded' else 'partially_refunded' end)::payment_status,
         updated_at = now()
   where id = pay.id;

  -- Decision 103: refunding a reservation fee removes the UNUSED remainder of its
  -- credit (used stays used). refund_payment already refused a spent credit.
  if pay.kind = 'reservation_fee' then
    update member_credits set used_cents = amount_cents, voided_at = now()
     where payment_id = pay.id and voided_at is null;
  end if;

  -- Decision 110(a): refunding a gift card sale voids the card (refund_payment
  -- has already refused one that was redeemed). Nobody is emailed about the void.
  if pay.gift_card_id is not null then
    update gift_cards set status = 'void', voided_at = now(), voided_by = rf.refunded_by,
           void_reason = coalesce(rf.reason, 'refunded')
     where id = pay.gift_card_id and status in ('pending', 'active');
  end if;

  -- A full refund of a membership payment cancels the membership and claws back
  -- unused pack credits (mirrors record_refund).
  if v_full and pay.membership_id is not null then
    select * into ms from memberships where id = pay.membership_id;
    select * into plan from membership_plans where id = ms.plan_id;
    if plan.type = 'class_pack' then
      select coalesce(sum(delta), 0) into v_bal from credit_ledger
       where studio_id = pay.studio_id and member_id = pay.member_id;
      v_take := least(coalesce(ms.credits_remaining, 0), greatest(v_bal, 0));
      if v_take > 0 then
        insert into credit_ledger (studio_id, member_id, membership_id, delta, reason, balance_after, actor_user_id)
        values (pay.studio_id, pay.member_id, ms.id, -v_take, 'manual', v_bal - v_take, rf.refunded_by);
        update memberships set credits_remaining = coalesce(credits_remaining, 0) - v_take where id = ms.id;
      end if;
    end if;
    update memberships set status = 'cancelled', cancelled_at = now(),
           cancellation_reason = coalesce(rf.reason, 'refunded')
     where id = ms.id and status <> 'cancelled';
  end if;

  -- Decision 110(a): a gift sale has no member (the buyer may have no account),
  -- so its refund email is addressed to the buyer's email; nobody else is told.
  if pay.member_id is null and (pay.gift_card_id is null
     or (select coalesce(btrim(buyer_email), '') from gift_cards where id = pay.gift_card_id) = '') then
    return;
  end if;
  perform queue_notification(pay.studio_id, pay.member_id, 'payment_refunded',
    (case when pay.member_id is null
          then jsonb_build_object('to_email', (select buyer_email from gift_cards where id = pay.gift_card_id))
          else '{}'::jsonb end) ||
    jsonb_build_object(
      'amount', fmt_money(rf.amount_cents, rf.currency),
      'method', case rf.method
                  when 'xendit' then 'card or GCash'
                  when 'card_terminal' then 'card'
                  when 'bank_transfer' then 'bank transfer'
                  when 'gcash' then 'GCash'
                  when 'cash' then 'cash' else 'the studio' end,
      'reference', coalesce(rf.xendit_refund_id, rf.reference, 'n/a')),
    'payment_refunded:' || rf.id);
end $$;
revoke execute on function apply_payment_refund(uuid) from public, anon, authenticated;
grant  execute on function apply_payment_refund(uuid) to service_role;

-- refund_payment — re-issued (from 20260833540000) refusing a redeemed gift card.
create or replace function refund_payment(
  p_payment_id uuid, p_amount_cents int default null, p_reason text default null,
  p_method text default null, p_reference text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pay payments%rowtype; v_amount int; v_remaining int; v_id uuid; v_ccy char(3);
begin
  select * into pay from payments where id = p_payment_id for update;
  if not found then raise exception 'no such payment' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(pay.studio_id), false) then
    raise exception 'refunds are the owner''s or a manager''s to make' using errcode = 'PT403';
  end if;
  if pay.status not in ('succeeded', 'partially_refunded') then
    raise exception 'a % payment cannot be refunded', pay.status using errcode = 'PT409';
  end if;

  -- Decision 111: a reservation fee whose credit has been spent cannot be refunded.
  if pay.kind = 'reservation_fee'
     and exists (select 1 from member_credits mc
                  where mc.payment_id = pay.id and mc.voided_at is null and mc.used_cents > 0) then
    raise exception 'this fee was used as credit, so it cannot be refunded'
      using errcode = 'PT409';
  end if;

  -- Decision 110(a): a gift card that has been redeemed cannot be refunded (its
  -- value is already on somebody's account as gift credit).
  if pay.gift_card_id is not null
     and exists (select 1 from gift_cards gc where gc.id = pay.gift_card_id and gc.status = 'redeemed') then
    raise exception 'this gift card has been redeemed, so it cannot be refunded'
      using errcode = 'PT409';
  end if;

  v_remaining := pay.amount_cents - coalesce(pay.refunded_cents, 0);
  v_amount := coalesce(p_amount_cents, v_remaining);
  if v_amount <= 0 or v_amount > v_remaining then
    raise exception 'that is more than is left to refund' using errcode = 'PT400';
  end if;
  v_ccy := pay.currency;

  if coalesce(p_method, '') = 'xendit' then
    -- The server action has already called POST /v3/refunds; p_reference is the
    -- rfd- id. Record pending; the webhook settles it.
    insert into payment_refunds (studio_id, payment_id, member_id, amount_cents, currency,
                                 reason, method, reference, status, xendit_refund_id, refunded_by)
    values (pay.studio_id, pay.id, pay.member_id, v_amount, v_ccy,
            p_reason, 'xendit', p_reference, 'pending', p_reference, auth.uid())
    returning id into v_id;
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (pay.studio_id, auth.uid(), 'payment.refunded', 'payments', pay.id,
            jsonb_build_object('refund_id', v_id, 'amount_cents', v_amount, 'method', 'xendit',
                               'reason', p_reason, 'reference', p_reference, 'status', 'pending'));
    return jsonb_build_object('ok', true, 'refund_id', v_id, 'status', 'pending', 'amount_cents', v_amount);
  else
    -- Studio-recorded: method required and valid, reference required.
    if coalesce(p_method, '') not in ('cash','bank_transfer','card_terminal','gcash','other') then
      raise exception 'unknown refund method' using errcode = 'PT400';
    end if;
    if coalesce(btrim(p_reference), '') = '' then
      raise exception 'a refund reference is required' using errcode = 'PT400';
    end if;
    insert into payment_refunds (studio_id, payment_id, member_id, amount_cents, currency,
                                 reason, method, reference, status, settled_at, refunded_by)
    values (pay.studio_id, pay.id, pay.member_id, v_amount, v_ccy,
            p_reason, p_method, p_reference, 'succeeded', now(), auth.uid())
    returning id into v_id;
    perform apply_payment_refund(v_id);
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (pay.studio_id, auth.uid(), 'payment.refunded', 'payments', pay.id,
            jsonb_build_object('refund_id', v_id, 'amount_cents', v_amount, 'method', p_method,
                               'reason', p_reason, 'reference', p_reference, 'status', 'succeeded'));
    return jsonb_build_object('ok', true, 'refund_id', v_id, 'status', 'succeeded', 'amount_cents', v_amount);
  end if;
end $$;
revoke execute on function refund_payment(uuid, int, text, text, text) from public, anon;
grant  execute on function refund_payment(uuid, int, text, text, text) to authenticated, service_role;

-- ========================================================================
-- public_schedule — re-issued (from 20260833480000) carrying gift_enabled and
-- the gift page URL for the embed link. One of the FOURTEEN anon surfaces; the
-- grant is re-asserted and the count does not change.
-- ========================================================================
CREATE OR REPLACE FUNCTION public.public_schedule(p_slug text, p_days integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_studio   studios%rowtype;
  v_tz       text;
  v_window   int;
  v_days     int;
  v_from     timestamptz;
  v_to       timestamptz;
  v_cached   jsonb;
  v_payload  jsonb;
  v_classes  jsonb;
  v_state    text;
  v_next_pub timestamptz;
  v_next_any timestamptz;
  v_next_from text;
  v_limit    int := 40;   -- the fallback's "next N classes" cap (bounded for anon)
  v_name_mode text;
  v_fmt text;
  v_guar boolean;         -- 22c: does the studio run guarantees (drives the embed tint)
  v_gift boolean;         -- 110(a): the embed links to the gift page when gift cards are on
begin
  select * into v_studio from studios where slug = lower(p_slug) and status = 'active';
  if not found then
    return jsonb_build_object('found', false);
  end if;
  v_tz := v_studio.timezone;

  select coalesce(booking_window_days, 30) into v_window
    from studio_settings where studio_id = v_studio.id;
  v_window := coalesce(v_window, 30);
  select coalesce(public_instructor_name, 'first') into v_name_mode
    from studio_settings where studio_id = v_studio.id;
  v_name_mode := coalesce(v_name_mode, 'first');
  select coalesce(time_format, '24h') into v_fmt
    from studio_settings where studio_id = v_studio.id;
  v_fmt := coalesce(v_fmt, '24h');
  select coalesce(guarantees_enabled, false) into v_guar
    from studio_settings where studio_id = v_studio.id;
  v_guar := coalesce(v_guar, false);
  select coalesce(gift_enabled, false) into v_gift
    from studio_settings where studio_id = v_studio.id;
  v_gift := coalesce(v_gift, false);
  v_days := least(greatest(coalesce(p_days, v_window), 1), v_window);

  select payload into v_cached
    from public_schedule_cache
   where slug = v_studio.slug and days = v_days
     and computed_at > now() - interval '5 minutes';
  if v_cached is not null then
    return v_cached;
  end if;

  v_from := (date_trunc('day', now() at time zone v_tz)) at time zone v_tz;
  v_to   := (date_trunc('day', now() at time zone v_tz) + make_interval(days => v_days)) at time zone v_tz;

  if exists (
    select 1 from class_occurrences o
     where o.studio_id = v_studio.id and o.status = 'scheduled' and not o.hidden_from_members
       and o.starts_at >= v_from and o.starts_at < v_to
       and month_published(v_studio.id, o.starts_at)
       and (o.staffing = 'assigned' or not studio_hides_unstaffed(v_studio.id))
  ) then
    v_state := 'in_window';
  else
    select min(o.starts_at) into v_next_pub
      from class_occurrences o
     where o.studio_id = v_studio.id and o.status = 'scheduled' and not o.hidden_from_members
       and o.starts_at >= v_to
       and month_published(v_studio.id, o.starts_at)
       and (o.staffing = 'assigned' or not studio_hides_unstaffed(v_studio.id));
    if v_next_pub is not null then
      v_state    := 'upcoming';
      v_next_from := to_char(v_next_pub at time zone v_tz, 'YYYY-MM-DD');
    else
      select min(o.starts_at) into v_next_any
        from class_occurrences o
       where o.studio_id = v_studio.id and o.status = 'scheduled' and not o.hidden_from_members
         and o.starts_at >= v_from;
      if v_next_any is not null then
        v_state    := 'unpublished';
        v_next_from := to_char(v_next_any at time zone v_tz, 'YYYY-MM-DD');
      else
        v_state := 'empty';
      end if;
    end if;
  end if;

  if v_state in ('in_window', 'upcoming') then
    select coalesce(jsonb_agg(c order by c.starts_at), '[]'::jsonb) into v_classes
    from (
      select
        o.id,
        to_char(o.starts_at at time zone v_tz, 'YYYY-MM-DD')            as date,
        to_char(o.starts_at at time zone v_tz, 'HH24:MI')              as time,
        o.starts_at,
        ct.duration_minutes,
        ct.name                                                        as class_name,
        ct.description,
        ct.color,
        -- Decision 22(c): the effective tier, resolved the same way the member
        -- Book tab and occurrence_guarantee_run do (occurrence first, then the
        -- series, then core). The embed draws core and always with the tint and
        -- the "Always runs" chip; flex is plain.
        case when not v_guar then null
          else case
            when o.guarantee_tier is not null then o.guarantee_tier::text
            when o.flex then 'flex'
            when cs.guarantee_tier is not null then cs.guarantee_tier::text
            when cs.flex then 'flex'
            else 'core'
          end
        end                                                            as tier,
        case when o.instructor_id is null then null
             when v_name_mode = 'full' then i.display_name
             else split_part(i.display_name, ' ', 1) end              as instructor_first_name,
        i.avatar_url                                                   as instructor_avatar_url,
        r.name                                                         as room,
        o.capacity,
        greatest(o.capacity - o.booked_count, 0)                       as spaces_left,
        (o.booked_count >= o.capacity)                                 as full,
        'https://' || v_studio.slug || '.studiior.app/class/' || o.id  as book_url
      from class_occurrences o
      join class_types ct on ct.id = o.class_type_id
      left join class_series cs on cs.id = o.series_id
      left join instructors i on i.id = o.instructor_id
      left join rooms r on r.id = o.room_id
      where o.studio_id = v_studio.id
        and o.status = 'scheduled' and not o.hidden_from_members
        and o.starts_at >= v_from
        and (v_state = 'upcoming' or o.starts_at < v_to)
        and month_published(v_studio.id, o.starts_at)
        and (o.staffing = 'assigned' or not studio_hides_unstaffed(v_studio.id))
      order by o.starts_at
      limit case when v_state = 'upcoming' then v_limit else null end
    ) c;
  else
    v_classes := '[]'::jsonb;
  end if;

  v_payload := jsonb_build_object(
    'found', true,
    'state', v_state,
    'next_from', v_next_from,
    'window_days', v_days,
    'generated_at', now(),
    'studio', jsonb_build_object(
      'name',               v_studio.name,
      'slug',               v_studio.slug,
      'timezone',           v_tz,
      'accent_color',       v_studio.accent_color,
      'theme_preset',       v_studio.theme_preset,
      'logo_url',           v_studio.logo_url,
      'app_origin',         'https://' || v_studio.slug || '.studiior.app',
      'time_format',        v_fmt,
      'guarantees_enabled', v_guar,
      'gift_enabled',       v_gift,
      'gift_url',           case when v_gift then 'https://' || v_studio.slug || '.studiior.app/gift' end
    ),
    'classes', v_classes
  );

  insert into public_schedule_cache (slug, days, payload, computed_at)
  values (v_studio.slug, v_days, v_payload, now())
  on conflict (slug, days) do update
    set payload = excluded.payload, computed_at = excluded.computed_at;

  return v_payload;
end $function$;
revoke execute on function public_schedule(text, integer) from public;
grant  execute on function public_schedule(text, integer) to anon, authenticated, service_role;
delete from public_schedule_cache;

-- ========================================================================
-- gift_card_begin — re-issued (from 20260833560000): whole hundreds, and it
-- returns apple_pay_verified so the server action passes an explicit channel
-- list when Apple Pay is not verified. RETURNS TABLE changes: drop + recreate.
-- Still ONE of the fourteen anon surfaces (re-granted below).
-- ========================================================================
drop function if exists gift_card_begin(uuid, int, text, text, text, text, text, date);
create or replace function gift_card_begin(
  p_studio_id uuid, p_amount_cents int,
  p_buyer_name text default null, p_buyer_email text default null,
  p_recipient_name text default null, p_recipient_email text default null,
  p_message text default null, p_delivery_date date default null
) returns table(purchase_id uuid, amount_cents int, currency char(3),
                secret_key_ciphertext text, test_mode boolean, apple_pay_verified boolean)
language plpgsql security definer set search_path = public as $$
declare ss studio_settings%rowtype; v_ccy char(3); v_today date; v_tz text;
        v_gift uuid; v_id uuid; v_buyer text;
begin
  select * into ss from studio_settings where studio_id = p_studio_id;
  if ss.studio_id is null or not coalesce(ss.gift_enabled, false) then
    raise exception 'gift cards are not available' using errcode = 'PT404';
  end if;
  if not exists (select 1 from studio_payment_providers where studio_id = p_studio_id and provider = 'xendit') then
    raise exception 'this studio is not set up to take online payments' using errcode = 'PT409';
  end if;

  if p_amount_cents is null or p_amount_cents < coalesce(ss.gift_min_cents, 50000)
     or p_amount_cents > 100000000 then
    raise exception 'that amount is not allowed' using errcode = 'PT422';
  end if;
  -- Decision 110(a): a custom amount is whole hundreds; the card is issued at
  -- exactly the amount chosen (any processor fee stays on the sale).
  if p_amount_cents % 10000 <> 0 then
    raise exception 'choose an amount in whole hundreds' using errcode = 'PT422';
  end if;
  if coalesce(nullif(btrim(p_buyer_email), ''), '') not like '%@%'
     or coalesce(nullif(btrim(p_recipient_email), ''), '') not like '%@%' then
    raise exception 'a buyer and a recipient email are needed' using errcode = 'PT422';
  end if;
  if length(coalesce(p_message, '')) > 200 then
    raise exception 'that message is too long' using errcode = 'PT422';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  v_today := (now() at time zone coalesce(v_tz, 'UTC'))::date;
  if p_delivery_date is not null and (p_delivery_date < v_today or p_delivery_date > v_today + 90) then
    raise exception 'that delivery date is out of range' using errcode = 'PT422';
  end if;

  v_buyer := lower(btrim(p_buyer_email));
  if (select count(*) from gift_cards where studio_id = p_studio_id
        and created_at > now() - interval '1 minute') >= 10 then
    raise exception 'too many right now, try again in a minute' using errcode = 'PT429';
  end if;
  if (select count(*) from gift_cards where studio_id = p_studio_id
        and lower(btrim(buyer_email)) = v_buyer
        and created_at > now() - interval '1 minute') >= 3 then
    raise exception 'too many right now, try again in a minute' using errcode = 'PT429';
  end if;

  select s.currency into v_ccy from studios s where s.id = p_studio_id;

  insert into gift_cards (studio_id, amount_cents, currency, status,
                          buyer_name, buyer_email, recipient_name, recipient_email,
                          message, delivery_date)
  values (p_studio_id, p_amount_cents, v_ccy, 'pending',
          nullif(btrim(p_buyer_name), ''), v_buyer,
          nullif(btrim(p_recipient_name), ''), lower(btrim(p_recipient_email)),
          nullif(btrim(p_message), ''), p_delivery_date)
  returning id into v_gift;

  insert into xendit_purchases (studio_id, member_id, gift_card_id, amount_cents, currency)
  values (p_studio_id, null, v_gift, p_amount_cents, v_ccy)
  returning id into v_id;

  return query
    select v_id, p_amount_cents, v_ccy, spp.secret_key_ciphertext, spp.test_mode,
           coalesce(ss.gift_apple_pay_verified, false)
      from studio_payment_providers spp
     where spp.studio_id = p_studio_id and spp.provider = 'xendit';
end $$;
revoke execute on function gift_card_begin(uuid, int, text, text, text, text, text, date) from public;
grant  execute on function gift_card_begin(uuid, int, text, text, text, text, text, date) to anon, authenticated, service_role;

-- gift_card_resend — re-issued (from 20260833560000) carrying the card image.
create or replace function gift_card_resend(p_gift_card_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare gc gift_cards%rowtype;
begin
  select * into gc from gift_cards where id = p_gift_card_id;
  if gc.id is null then raise exception 'no such gift card' using errcode = 'PT404'; end if;
  if not is_manager_up(gc.studio_id) then
    raise exception 'resending a gift card is the owner''s or a manager''s to do' using errcode = 'PT403';
  end if;
  if gc.status <> 'active' or gc.code is null then
    raise exception 'that card cannot be resent' using errcode = 'PT409';
  end if;
  perform queue_notification(gc.studio_id, gc.redeemed_by_member_id, 'gift_card_sent',
    jsonb_build_object('to_email', gc.recipient_email,
      'recipient_name', coalesce(gc.recipient_name, 'there'),
      'buyer_name', coalesce(gc.buyer_name, 'A friend'),
      'code', gc.code, 'amount', fmt_money(gc.amount_cents, gc.currency),
      'message', coalesce(gc.message, ''),
      'message_html', case when coalesce(btrim(gc.message), '') = '' then ''
        else '<p style="font-style:italic;color:#57534e">&ldquo;' || replace(replace(replace(gc.message, '&', '&amp;'), '<', '&lt;'), '>', '&gt;') || '&rdquo;</p>' end,
      'card_image_url', member_portal_url(gc.studio_id,
        coalesce(gc.card_image_path, '/giftcard/' || gc.id::text || '/' || gc.code || '/' || gc.amount_cents::text)),
      'redeem_url', member_portal_url(gc.studio_id, '/account/redeem'),
      'studio_name', (select name from studios where id = gc.studio_id)),
    'gift_card_resend:' || gc.id::text || ':' || floor(extract(epoch from now()))::text);
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function gift_card_resend(uuid) from public, anon;
grant  execute on function gift_card_resend(uuid) to authenticated, service_role;

-- ========================================================================
-- studio_by_slug — re-issued (from 20260833560000) + gift_card_image_url, the
-- studio's uploaded card (public studio-branding URL) the card route draws on.
-- Same anon surface; drop + recreate re-grants it.
-- ========================================================================
drop function if exists studio_by_slug(text);
create function studio_by_slug(p_slug text)
 returns table(id uuid, name text, slug text, timezone text, currency text, logo_url text,
   theme_preset theme_preset, accent_color text, login_image_url text,
   login_image_focus_x smallint, login_image_focus_y smallint,
   free_first_class_enabled boolean, login_tagline text, install_welcome text, time_format text,
   android_package text, android_sha256_fingerprints text, ios_team_id text, ios_bundle_id text,
   gift_enabled boolean, gift_presets int[], gift_min_cents int, gift_card_image_url text)
 language sql stable security definer set search_path to 'public' as $function$
  select s.id, s.name, s.slug, s.timezone, s.currency,
         s.logo_url, s.theme_preset, s.accent_color, s.login_image_url,
         s.login_image_focus_x, s.login_image_focus_y,
         coalesce(ss.free_first_class_enabled, false),
         s.login_tagline, s.install_welcome,
         coalesce(ss.time_format, '24h'),
         s.android_package, s.android_sha256_fingerprints, s.ios_team_id, s.ios_bundle_id,
         coalesce(ss.gift_enabled, false),
         coalesce(ss.gift_presets, array[100000, 250000, 500000]),
         coalesce(ss.gift_min_cents, 50000),
         ss.gift_card_image_path
    from studios s
    left join studio_settings ss on ss.studio_id = s.id
   where s.slug = p_slug and s.status = 'active'
$function$;
revoke execute on function studio_by_slug(text) from public;
grant  execute on function studio_by_slug(text) to anon, authenticated, service_role;

-- ========================================================================
-- The five private templates (80a frame): platform defaults. No prices typed;
-- amounts come as tokens.
-- ========================================================================
insert into notification_templates (key, subject, text_body, html_body, note) values('private_confirmed',
 'You''re booked: {type_name}, {when}',
 E'Hi {first_name},\n\nYou''re booked in for a {type_name} on {when}. It is yours alone, so nobody else can book this time.{claim_line}\n\nCan''t make it? Move or cancel in the app at least the studio''s notice before the session.\n\nManage it here: {manage_url}',
 '<p>Hi {first_name},</p>
<p>You&#39;re booked in for a <strong>{type_name}</strong> on {when}. It is yours alone, so nobody else can book this time.</p>
{claim_html}
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{type_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">{when}</div></td></tr></table>
<p>Can&#39;t make it? Move or cancel in the app at least the studio&#39;s notice before the session.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{manage_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Manage this session</a></td></tr></table>
<p>{studio_name}</p>',
 'Decision 116: private confirmed.'),
('private_booked',
 'Private booked: {type_name} with {client_name}, {when}',
 E'Hi {first_name},\n\nYou have a private session: {type_name} with {client_name} on {when}. It is on your schedule and you''re paid for it as a private.\n\nSee my schedule: {schedule_url}',
 '<p>Hi {first_name},</p>
<p>You have a private session: <strong>{type_name}</strong> with {client_name} on {when}. It is on your schedule and you&#39;re paid for it as a private.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{schedule_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">See my schedule</a></td></tr></table>
<p>{studio_name}</p>',
 'Decision 116: private booked.'),
('private_moved',
 'Your {type_name} has moved to {when}',
 E'Hi {first_name},\n\nYour {type_name} is now on {when}. Everything else stays the same.\n\nManage it here: {manage_url}',
 '<p>Hi {first_name},</p>
<p>Your <strong>{type_name}</strong> is now on {when}. Everything else stays the same.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{manage_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Manage this session</a></td></tr></table>
<p>{studio_name}</p>',
 'Decision 116: private moved.'),
('private_cancelled',
 'Your {type_name} on {when} is cancelled',
 E'Hi {first_name},\n\nYour {type_name} on {when} is cancelled. {outcome_line}\n\nBook another time: {book_url}',
 '<p>Hi {first_name},</p>
<p>Your <strong>{type_name}</strong> on {when} is cancelled. {outcome_line}</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{book_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Book another time</a></td></tr></table>
<p>{studio_name}</p>',
 'Decision 116: private cancelled.'),
('private_studio_cancelled',
 'We had to cancel your {type_name} on {when}',
 E'Hi {first_name},\n\nWe''re sorry, we had to cancel your {type_name} on {when}. {reason_line}Your {amount} is back on your account as credit, so you can book a new time free, or ask us for a full refund instead.\n\nBook a new time: {book_url}',
 '<p>Hi {first_name},</p>
<p>We&#39;re sorry, we had to cancel your <strong>{type_name}</strong> on {when}. {reason_line}Your {amount} is back on your account as credit, so you can book a new time free, or ask us for a full refund instead.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{book_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Book a new time</a></td></tr></table>
<p>{studio_name}</p>',
 'Decision 116: private studio cancelled.')
on conflict (key) do update set subject = excluded.subject, text_body = excluded.text_body,
  html_body = excluded.html_body, note = excluded.note;

-- Decision 110(a): gift_card_sent shows the composited card (amount + code on
-- the studio's card, or the default card in the studio accent) with the buyer's
-- name and message beneath; the subject default changes.
update notification_templates
   set subject = 'A gift of Pilates from {buyer_name} at {studio_name}',
       text_body = E'Hi {recipient_name},\n\n{buyer_name} has sent you a {amount} gift card for {studio_name}.\n\n{message}\n\nYour code is {code}. Redeem it here: {redeem_url}',
       html_body = '<p>Hi {recipient_name},</p>
<p><img src="{card_image_url}" width="480" alt="{amount} gift card for {studio_name}, code {code}" style="display:block;width:100%;max-width:480px;height:auto;border-radius:12px;border:0"></p>
<p>{buyer_name} has sent you a <strong>{amount}</strong> gift card for {studio_name}.</p>
{message_html}
<p>Your code is <strong>{code}</strong>.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{redeem_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Redeem your gift card</a></td></tr></table>
<p>{studio_name}</p>'
 where key = 'gift_card_sent';

-- Reform overrides in RPC voice (member sign-off "See you at the reformer!🎀 /
-- RPC Studio", coach sign-off "Thank you! / RPC Studio"). Keyed on slug.
insert into notification_templates_overrides (studio_id, key, subject, body, body_html, updated_at)
select s.id, v.key, v.subject, v.body, v.body_html, now()
  from studios s
  cross join (values
  ('private_confirmed', 'You''re booked: {type_name}, {when}', E'Hi {first_name},\n\nYou''re booked in for a {type_name} on {when}. It is yours alone, so nobody else can book this time.{claim_line}\n\nCan''t make it? Move or cancel in the app at least the studio''s notice before the session.\n\nManage it here: {manage_url}\n\nSee you at the reformer!🎀\nRPC Studio', '<p>Hi {first_name},</p>
<p>You&#39;re booked in for a <strong>{type_name}</strong> on {when}. It is yours alone, so nobody else can book this time.</p>
{claim_html}
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{type_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">{when}</div></td></tr></table>
<p>Can&#39;t make it? Move or cancel in the app at least the studio&#39;s notice before the session.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{manage_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Manage this session</a></td></tr></table>
<p>See you at the reformer!🎀<br>RPC Studio</p>'),
  ('private_booked', 'Private booked: {type_name} with {client_name}, {when}', E'Hi Coach {first_name},\n\nYou have a private session: {type_name} with {client_name} on {when}. It is on your schedule and you''re paid for it as a private.\n\nSee my schedule: {schedule_url}\n\nThank you!\nRPC Studio', '<p>Hi Coach {first_name},</p>
<p>You have a private session: <strong>{type_name}</strong> with {client_name} on {when}. It is on your schedule and you&#39;re paid for it as a private.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{schedule_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">See my schedule</a></td></tr></table>
<p>Thank you!<br>RPC Studio</p>'),
  ('private_moved', 'Your {type_name} has moved to {when}', E'Hi {first_name},\n\nYour {type_name} is now on {when}. Everything else stays the same.\n\nManage it here: {manage_url}\n\nSee you at the reformer!🎀\nRPC Studio', '<p>Hi {first_name},</p>
<p>Your <strong>{type_name}</strong> is now on {when}. Everything else stays the same.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{manage_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Manage this session</a></td></tr></table>
<p>See you at the reformer!🎀<br>RPC Studio</p>'),
  ('private_cancelled', 'Your {type_name} on {when} is cancelled', E'Hi {first_name},\n\nYour {type_name} on {when} is cancelled. {outcome_line}\n\nBook another time: {book_url}\n\nSee you at the reformer!🎀\nRPC Studio', '<p>Hi {first_name},</p>
<p>Your <strong>{type_name}</strong> on {when} is cancelled. {outcome_line}</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{book_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Book another time</a></td></tr></table>
<p>See you at the reformer!🎀<br>RPC Studio</p>'),
  ('private_studio_cancelled', 'We had to cancel your {type_name} on {when}', E'Hi {first_name},\n\nWe''re sorry, we had to cancel your {type_name} on {when}. {reason_line}Your {amount} is back on your account as credit, so you can book a new time free, or ask us for a full refund instead.\n\nBook a new time: {book_url}\n\nSee you at the reformer!🎀\nRPC Studio', '<p>Hi {first_name},</p>
<p>We&#39;re sorry, we had to cancel your <strong>{type_name}</strong> on {when}. {reason_line}Your {amount} is back on your account as credit, so you can book a new time free, or ask us for a full refund instead.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{book_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Book a new time</a></td></tr></table>
<p>See you at the reformer!🎀<br>RPC Studio</p>')
  ) as v(key, subject, body, body_html)
 where s.slug in ('reform', 'reformcollective')
on conflict (studio_id, key) do update set subject = excluded.subject, body = excluded.body,
  body_html = excluded.body_html, updated_at = now();

-- ========================================================================
-- Reform config (keyed on slug): three private types, two 1:1 packs, on,
-- 12-hour lead, 10-minute buffer, every active coach teaches privates (the
-- owner unticks any who do not).
-- ========================================================================
do $reform$
declare v_studio uuid; v_ccy char(3);
begin
  select id, currency into v_studio, v_ccy from studios where slug in ('reformcollective', 'reform')
   order by (slug = 'reformcollective') desc limit 1;
  if v_studio is null then return; end if;

  update studio_settings set private_sessions_enabled = true, private_lead_time_hours = 12,
         private_buffer_minutes = 10 where studio_id = v_studio;

  if not exists (select 1 from private_session_types where studio_id = v_studio) then
    insert into private_session_types (studio_id, name, price_cents, people, duration_min, coach_pay_cents, sort) values
      (v_studio, 'Private 1:1', 220000, 1, 50, 100000, 1),
      (v_studio, 'Duo',         300000, 2, 50, 140000, 2),
      (v_studio, 'Trio',        360000, 3, 50, 160000, 3);
  end if;

  -- A private pack is a class_pack plan flagged private_pack and restricted to no
  -- group class type (a sentinel id no class type carries), so book_class, the
  -- coverage reader and apply_plan_to_unpaid never spend it on a group class.
  if not exists (select 1 from membership_plans where studio_id = v_studio and private_pack) then
    insert into membership_plans (studio_id, name, type, price_cents, currency, credits, validity_days,
                                  visibility, status, private_pack, restrictions, description)
    values
      (v_studio, '5 Privates',  'class_pack', 1050000, v_ccy, 5,  null, 'public', 'active', true,
       '{"class_type_ids": ["private-only"]}'::jsonb, 'Five 1:1 private sessions. No expiry.'),
      (v_studio, '10 Privates', 'class_pack', 2000000, v_ccy, 10, null, 'public', 'active', true,
       '{"class_type_ids": ["private-only"]}'::jsonb, 'Ten 1:1 private sessions. No expiry.');
  end if;

  update instructors set teaches_privates = true where studio_id = v_studio and status = 'active';
end $reform$;


-- ========================================================================
-- book_class — re-issued (from 20260833510000) excluding a private-pack
-- membership from the plan walk (Decision 116).
-- ========================================================================
CREATE OR REPLACE FUNCTION public.book_class(p_occurrence_id uuid, p_member_id uuid, p_source booking_source, p_override_reason text DEFAULT NULL::text, p_payment_source payment_source DEFAULT NULL::payment_source, p_membership_id uuid DEFAULT NULL::uuid)
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

  v_is_desk := coalesce(is_desk_up(v_occ.studio_id), false)
               or coalesce(current_setting('studiior.late_add', true) = '1', false);
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
  -- Decision 100 amendment (b): a roster late add (the studiior.late_add
  -- flag, set by staff_book_member after it authorises desk-up or the
  -- class's own instructor) books into a class that has started, until it
  -- ends; after the end it is class_ended. A member (no flag) keeps the
  -- starts_at guard.
  if current_setting('studiior.late_add', true) = '1' then
    if v_occ.ends_at <= now() then
      return (null, null, null, null, 'class_ended')::book_class_result;
    end if;
  elsif v_occ.starts_at <= now() then
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

  -- 2.1.1d Decision 91: a class HIDDEN from members (set_occurrence_visibility) is
  -- closed to NEW bookings — including by link and from the desk — unless the
  -- member ALREADY holds a non-cancelled booking on it, so cancel-and-rebook and
  -- waitlist promotion still work for them. Mirrors not_staffed_yet above.
  if v_occ.hidden_from_members
     and not exists (select 1 from bookings b
                      where b.occurrence_id = p_occurrence_id and b.member_id = p_member_id
                        and b.status <> 'cancelled') then
    return (null, null, null, null, 'class_hidden')::book_class_result;
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
  if current_setting('studiior.late_add', true) = '1' then
    null;  -- a late add is inside the cutoff by definition; the flag bypasses it
  elsif not v_override then
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

  -- 2.1.3c Decision 73: while this member's free first class is still
  -- PROVISIONAL (Decision 30 grouped — booked but awaiting its cutoff), they may
  -- not make any other app booking OR join a waitlist. A pending free class is
  -- undecided, and stacking bookings on top of it is what this prevents. Self
  -- only (a desk or service booking is never affected); never the free-first
  -- booking itself (that goes through book_first_free, not here); and a
  -- studio-offered waitlist PROMOTION is exempt (respond_to_offer sets
  -- studiior.waitlist_promoting). Tied to a host-null guest_passes row, so it is
  -- precisely a free-first seat and inert for every member not holding one.
  if v_is_self and not (v_is_desk or v_trusted)
     and current_setting('studiior.waitlist_promoting', true) is distinct from '1'
     and exists (
       select 1 from bookings b
         join guest_passes gp on gp.guest_booking_id = b.id and gp.host_member_id is null
        where b.member_id = p_member_id and b.studio_id = v_occ.studio_id
          and b.payment_source = 'comp' and b.provisional and b.status = 'booked')
  then
    return (null, null, null, null, 'free_first_pending')::book_class_result;
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
         -- Decision 100: when staff pin a specific plan, consider only it.
         and (p_membership_id is null or ms.id = p_membership_id)
         and ms.studio_id = v_occ.studio_id
         -- Decision 116: a private pack is spent only at the private booking
         -- step, never on a group class (a holder of only a private pack books
         -- a group class as a drop-in, exactly as before).
         and not coalesce(mp.private_pack, false)
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
      -- Decision 100: staff pinned a plan that did not resolve or does not cover
      -- this class. Refuse with plan_not_covering rather than falling to drop-in.
      if p_membership_id is not null then
        return (null, null, null, null, 'plan_not_covering')::book_class_result;
      end if;
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
      -- Decision 49: the plan they would book on is frozen. Rather than
      -- silently charge a drop-in, refuse with its own reason (the member app
      -- says "paused until {date}"). A usable non-frozen pack was already
      -- resolved above, so this only fires when a frozen membership is the
      -- only plan they have.
      if exists (
        select 1 from memberships ms2
         where ms2.member_id = p_member_id and ms2.studio_id = v_occ.studio_id
           and ms2.freeze_start is not null and ms2.freeze_end is not null
           and v_today between ms2.freeze_start and ms2.freeze_end
      ) then
        return (null, null, null, null, 'membership_frozen')::book_class_result;
      end if;
      v_pay := 'drop_in';

      -- Decision 73 (c): pay at the desk is EARNED. This booking resolved to an
      -- unpaid desk drop-in; refuse it (desk_pay_blocked) when the member has
      -- lost the privilege. 'earned' mode: once they have a no-show or late
      -- cancel on a desk booking (members.desk_pay_blocked_at set). 'first_visit
      -- _only' mode: once they have ever held a desk booking that was not
      -- cancelled in time. The app then shows "pay online to book". Self only; a
      -- desk/staff booking and a studio-offered waitlist promotion are never
      -- blocked, and the instructor desk RPCs do not reach book_class at all.
      if v_is_self and not (v_is_desk or v_trusted)
         and current_setting('studiior.waitlist_promoting', true) is distinct from '1'
         and (
           (coalesce(v_set.desk_pay_mode, 'earned') = 'earned'
              and exists (select 1 from members dm
                           where dm.id = p_member_id and dm.desk_pay_blocked_at is not null))
           or
           (coalesce(v_set.desk_pay_mode, 'earned') = 'first_visit_only'
              and exists (select 1 from bookings db
                           where db.member_id = p_member_id and db.studio_id = v_occ.studio_id
                             and db.payment_source = 'drop_in' and db.status <> 'cancelled'))
         )
      then
        return (null, null, null, null, 'desk_pay_blocked')::book_class_result;
      end if;

      -- Decision 73: a studio may cap how many UNPAID app bookings a member
      -- holds (max_unpaid_bookings; null = no limit = today's behaviour). This
      -- booking has resolved to an unpaid drop-in; if the member already holds
      -- that many unpaid drop-ins, refuse with pay_first — the app then offers
      -- Pay now / Pay at the desk. Self only: a desk booking (money at the
      -- counter) and a studio-offered waitlist promotion are never capped. A
      -- booking counts while it is a live drop-in with no settling payment row;
      -- a desk or Pay-now payment clears it (73b flips payment_source off
      -- drop_in), so a paid booking no longer counts.
      if v_set.max_unpaid_bookings is not null
         and v_is_self and not (v_is_desk or v_trusted)
         and current_setting('studiior.waitlist_promoting', true) is distinct from '1'
         and (
           select count(*) from bookings b
            where b.member_id = p_member_id and b.studio_id = v_occ.studio_id
              and b.payment_source = 'drop_in'
              and b.status in ('booked', 'pending_payment')
              and not exists (select 1 from payments p
                               where p.booking_id = b.id
                                 and p.status in ('succeeded', 'partially_refunded'))
         ) >= v_set.max_unpaid_bookings
      then
        return (null, null, null, null, 'pay_first')::book_class_result;
      end if;
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
revoke execute on function book_class(uuid, uuid, booking_source, text, payment_source, uuid) from public, anon;
grant  execute on function book_class(uuid, uuid, booking_source, text, payment_source, uuid) to authenticated, service_role;

-- ========================================================================
-- Anon stays EXACTLY FOURTEEN (Decision 116 adds no anon surface).
-- ========================================================================
do $mig$ declare n int; begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'expect\_%';
  if n <> 14 then raise exception 'anon surface is % (want 14)', n; end if;
end $mig$;
