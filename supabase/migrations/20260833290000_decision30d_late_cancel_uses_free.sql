-- Decision 30 amendment (d, continued) — a late cancel uses the free class too.
-- re-issues: free_first_eligibility_run(uuid, uuid, uuid), convert_booking_to_free_first(uuid), member_plan_overview(uuid)
--
-- (d) originally: a NO-SHOW on the free first class uses it (migration 299).
-- This continues it: a cancel INSIDE the studio's cancellation cutoff
-- (late_cancelled) uses the free class too — the studio and the instructor are
-- paid for the seat whether or not the member came. A cancel BEFORE the cutoff
-- still keeps it (a 'cancelled' comp booking is never counted — unchanged).
--
-- STEP 0 found the gap: free_first_eligibility_run counts only a comp no_show
-- (plus an attended free seat, a live booking, or a membership) as a
-- disqualifier, so a late_cancelled comp seat matched none and the member stayed
-- eligible — a late cancel of the free class left it usable again. This disqualifies
-- it with reason 'late_cancel', but ONLY for cancels on or after a recorded,
-- studio-independent cut-over timestamp (v_cutover below): "earlier late cancels
-- are not reassessed." A late_cancelled row with no cancelled_at (a hand-written
-- or imported row) is treated as pre-cut-over and keeps eligibility (the safe
-- default — never disqualify on a row with no cancel timestamp).
--
-- tg_guest_pass_sync is NOT re-issued, and the reason is structural: it does not
-- "reuse" the once-ever pass — the reuse is book_first_free's upsert on the
-- once-ever index, which runs ONLY after free_first_eligibility passes. A
-- post-cut-over late cancel makes the member ineligible, so book_first_free
-- refuses before the upsert and the pass is never reused. The sync already marks
-- a late_cancelled free-first pass 'cancelled' (via its guest_booking_id arm).
-- So "the pass is not reused after a late cancel" is enforced at the eligibility
-- gate, with no change to the trigger.
--
-- "Staff can still grant another free class by hand with 'Make this their free
-- class'": convert_booking_to_free_first is re-issued to OVERRIDE a 'late_cancel'
-- refusal — that convert IS the by-hand grant. Every other refusal still stands.
--
-- Staff-facing free-first readers say "Free class used (late cancel)":
--  * member_plan_overview.free_stage gains a cut-over-gated 'late_cancel' value
--    (re-issued here), which the Members-list chip maps to the label;
--  * the Journey row (lib/statement.mjs rowLine) refines its existing
--    late_cancelled + is_free_first label to "Free class used (late cancel)" —
--    a display refinement, app-side, no member_activity re-issue.

-- ===========================================================================
-- 1. free_first_eligibility_run — the unguarded twin that carries the logic.
--    Byte-for-byte from migration 20260832990000 with ONE arm added: a comp
--    late_cancelled seat on/after the cut-over is a disqualifier ('late_cancel').
-- ===========================================================================
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

-- ===========================================================================
-- 2. convert_booking_to_free_first — the by-hand staff grant ("Make this their
--    free class"). Byte-for-byte from migration 20260832950000 with ONE arm
--    changed: a 'late_cancel' eligibility refusal is OVERRIDDEN (this convert IS
--    the by-hand grant the amendment allows). Every other refusal still stands.
-- ===========================================================================
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
  if not (v_elig ->> 'ok')::boolean and (v_elig ->> 'reason') is distinct from 'late_cancel' then
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

-- ===========================================================================
-- 3. member_plan_overview — byte-for-byte from migration 20260833130000 with
--    the comp CTE and free_stage branch extended: a comp late_cancelled seat
--    on/after the cut-over reads free_stage 'late_cancel' (the Members-list chip
--    maps it to "Free class used (late cancel)").
-- ===========================================================================
create or replace function member_plan_overview(p_studio_id uuid)
returns table (
  id uuid, first_name text, last_name text, email text, status text,
  lifetime_visits int, last_visit_at timestamptz,
  health_band text, health_reason text, user_id uuid,
  membership_id uuid, current_plan_name text, plan_type text,
  membership_status text, expires_on date, credits_remaining int,
  had_free_class boolean, has_ever_paid boolean, plan_state text,
  complimentary boolean, free_stage text, has_unpaid_booking boolean,
  joined_on date, desk_pay_blocked boolean
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare v_tz text; v_today date;
  -- Decision 30(d, continued): the same cut-over free_first_eligibility_run uses.
  v_cutover constant timestamptz := '2026-11-09 00:00:00+00';
begin
  if not (is_desk_up(p_studio_id) or is_service_context()) then
    raise exception 'that is another studio''s members' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios s where s.id = p_studio_id;
  v_today := (now() at time zone v_tz)::date;

  return query
  with mem as (
    select m.id, m.first_name, m.last_name, m.email, m.status::text as status,
           m.lifetime_visits, m.last_visit_at,
           m.health_band::text as health_band, m.health_reason, m.user_id,
           m.joined_on, m.desk_pay_blocked_at
      from members m
     where m.studio_id = p_studio_id and m.status <> 'archived'
       and m.deleted_at is null
  ),
  live as (
    select distinct on (ms.member_id)
           ms.member_id, ms.id as membership_id, ms.status as ms_status,
           ms.expires_on, ms.credits_remaining, mp.name as plan_name, mp.type as plan_type,
           ms.complimentary,
           (ms.status in ('active','trialing','past_due','frozen')
            and (mp.type = 'recurring'
                 or coalesce(ms.credits_remaining,0) > 0)
            and (ms.expires_on is null or ms.expires_on >= v_today)) as usable
      from memberships ms
      join membership_plans mp on mp.id = ms.plan_id
     where ms.studio_id = p_studio_id and ms.status <> 'cancelled'
     order by ms.member_id,
              (ms.status in ('active','trialing','past_due','frozen')) desc,
              ms.expires_on desc nulls first, ms.created_at desc
  ),
  paid as (
    select distinct member_id from payments
     where studio_id = p_studio_id and status in ('succeeded','partially_refunded')
  ),
  freebie as (
    select distinct guest_member_id as member_id from guest_passes
     where studio_id = p_studio_id
  ),
  comp as (
    select b.member_id,
           bool_or(b.status = 'attended') as any_attended,
           bool_or(b.status = 'booked')   as any_booked,
           bool_or(b.status = 'no_show')  as any_no_show,
           bool_or(b.status = 'late_cancelled'
                   and b.cancelled_at >= v_cutover) as any_late_cancel,
           max(o.starts_at) filter (where b.status = 'no_show') as last_no_show_at
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
     where b.studio_id = p_studio_id
       and b.payment_source = 'comp'
       and b.status in ('booked','attended','no_show','late_cancelled')
     group by b.member_id
  ),
  unpaid as (
    select distinct b.member_id
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
     where b.studio_id = p_studio_id
       and b.payment_source = 'drop_in'
       and b.status in ('booked','pending_payment')
       and o.starts_at > now()
       and not exists (select 1 from payments p
                        where p.booking_id = b.id
                          and p.status in ('succeeded','partially_refunded'))
  )
  select mem.id, mem.first_name, mem.last_name, mem.email, mem.status,
         mem.lifetime_visits, mem.last_visit_at, mem.health_band, mem.health_reason, mem.user_id,
         live.membership_id, live.plan_name, live.plan_type::text,
         live.ms_status::text, live.expires_on, live.credits_remaining,
         (freebie.member_id is not null) as had_free_class,
         (paid.member_id is not null) as has_ever_paid,
         case
           when coalesce(live.usable, false) then
             case when live.expires_on is not null
                       and live.expires_on <= v_today + 14 then 'expiring' else 'on_plan' end
           when paid.member_id is not null then 'expired'
           when freebie.member_id is not null then 'free_only'
           else 'none'
         end as plan_state,
         coalesce(live.complimentary, false) as complimentary,
         case
           when comp.any_attended then 'taken'
           when comp.any_booked   then 'booked'
           when comp.any_no_show
                and not exists (
                  select 1 from bookings b2
                  join class_occurrences o2 on o2.id = b2.occurrence_id
                  where b2.member_id = mem.id and b2.studio_id = p_studio_id
                    and b2.status not in ('cancelled','late_cancelled')
                    and o2.starts_at > comp.last_no_show_at
                ) then 'missed'
           when comp.any_late_cancel then 'late_cancel'
           else null
         end as free_stage,
         (unpaid.member_id is not null) as has_unpaid_booking,
         mem.joined_on,
         (mem.desk_pay_blocked_at is not null) as desk_pay_blocked
    from mem
    left join live    on live.member_id = mem.id
    left join paid    on paid.member_id = mem.id
    left join freebie on freebie.member_id = mem.id
    left join comp    on comp.member_id = mem.id
    left join unpaid  on unpaid.member_id = mem.id;
end $$;

revoke all on function member_plan_overview(uuid) from public, anon;
grant execute on function member_plan_overview(uuid) to authenticated, service_role;

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
