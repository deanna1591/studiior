-- =============================================================================
-- Free first class emails, and the Unpaid-booking chip.
-- re-issues: book_first_free(uuid), queue_booking_notifications(uuid), member_plan_overview(uuid)
-- =============================================================================
-- Two faults:
--  1. A NON-provisional free first class emailed as booking_confirmed (the
--     Decision-80a plan/price card) instead of the free-class confirmation.
--     Cause: book_first_free inserts the booking (firing the AFTER-INSERT trigger
--     that queues notifications) BEFORE it writes the guest_passes row that marks
--     the seat free, so v_is_free was not yet true and the branch fell through to
--     booking_confirmed. Fix: book_first_free sets a transaction-local flag
--     studiior.free_first before the insert; the trigger reads the flag OR the
--     guest_passes row and, for a non-provisional free seat, queues
--     free_booking_confirmed, never booking_confirmed. (A provisional free seat
--     still sends free_booking_pending — keyed on its own provisional flag.)
--  2. A member holding only an unpaid drop-in read "Signed up, nothing booked" on
--     /members (plan_state='none'). member_plan_overview gains has_unpaid_booking.
--
-- No new anon RPC — anon stays EXACTLY THIRTEEN. member_plan_overview grants
-- unchanged. Decision 30 / the 288 hotfix (the guest_passes upsert, free-first
-- eligibility) are untouched.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. book_first_free — re-issued verbatim from 20260832740000 with ONE addition:
--    set_config('studiior.free_first','1',true) immediately before the booking
--    insert, so the AFTER-INSERT trigger knows this seat is a free first class
--    even though the guest_passes row is written after it. The guest_passes
--    upsert is byte-for-byte unchanged (Decision 30 + the 288 hotfix).
-- -----------------------------------------------------------------------------
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
  v_ser    class_series%rowtype;
  v_cfg_tier guarantee_tier;
  v_tz     text;
  v_elig   jsonb;
  v_free   int;
  v_head   int;
  v_cut    timestamptz;
  v_prov   boolean;
  v_booking uuid;
  v_pass    uuid;
begin
  select * into v_occ from class_occurrences where id = p_occurrence_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;

  select * into v_member from members
   where studio_id = v_occ.studio_id and user_id = auth.uid();
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_authorised'); end if;

  v_elig := free_first_eligibility(v_occ.studio_id, v_member.id);
  if not (v_elig ->> 'ok')::boolean then return v_elig; end if;

  select * into v_set from studio_settings where studio_id = v_occ.studio_id;
  select timezone into v_tz from studios where id = v_occ.studio_id;

  if v_occ.status <> 'scheduled' then return jsonb_build_object('ok', false, 'reason', 'class_not_bookable'); end if;
  if v_occ.starts_at <= now() then return jsonb_build_object('ok', false, 'reason', 'class_in_past'); end if;
  if not month_published(v_occ.studio_id, v_occ.starts_at) then
    return jsonb_build_object('ok', false, 'reason', 'month_not_published');
  end if;
  if studio_hides_unstaffed(v_occ.studio_id) and v_occ.staffing <> 'assigned' then
    return jsonb_build_object('ok', false, 'reason', 'not_staffed_yet');
  end if;
  if v_occ.starts_at > now() + make_interval(days => coalesce(v_set.booking_window_days, 30)) then
    return jsonb_build_object('ok', false, 'reason', 'outside_booking_window');
  end if;
  if v_occ.starts_at < now() + make_interval(mins => coalesce(v_set.booking_cutoff_minutes, 0)) then
    return jsonb_build_object('ok', false, 'reason', 'past_booking_cutoff');
  end if;

  -- Decision 30 amendment (b): a per-class override. 'closed' = never, whatever
  -- the rules say; 'open' skips core_only and the series switch below (seat cap
  -- and peak still apply).
  if v_occ.free_first_override = 'closed' then
    return jsonb_build_object('ok', false, 'reason', 'free_first_closed_here');
  end if;

  if not coalesce(v_set.free_first_peak_allowed, true) and occurrence_is_peak(p_occurrence_id) then
    return jsonb_build_object('ok', false, 'reason', 'peak_not_allowed');
  end if;

  if v_occ.series_id is not null then
    select * into v_ser from class_series where id = v_occ.series_id;
  end if;
  v_cfg_tier := coalesce(v_occ.guarantee_tier,
                         case when v_occ.flex then 'flex'::guarantee_tier end,
                         v_ser.guarantee_tier,
                         case when v_ser.flex then 'flex'::guarantee_tier end,
                         'core'::guarantee_tier);
  if coalesce(v_set.free_first_core_only, false) and v_cfg_tier <> 'core'
     and v_occ.free_first_override is distinct from 'open' then
    return jsonb_build_object('ok', false, 'reason', 'flex_not_allowed');
  end if;
  if v_occ.series_id is not null
     and not coalesce(v_ser.free_first_allowed, true)
     and v_occ.free_first_override is distinct from 'open' then
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

  v_free := v_occ.capacity - occurrence_seats_taken(p_occurrence_id)
                           - occurrence_seats_held(p_occurrence_id);
  if v_free < 1 then return jsonb_build_object('ok', false, 'reason', 'class_full'); end if;

  v_head := occurrence_seats_taken(p_occurrence_id) + 1;
  select cutoff_at into v_cut from occurrence_guarantee_run(p_occurrence_id);
  v_prov := v_set.free_first_confirm_at is not null
            and v_cut is not null
            and v_head < v_set.free_first_confirm_at;

  -- Mark this seat a free first class for the AFTER-INSERT notification trigger,
  -- which fires before the guest_passes row below is written.
  perform set_config('studiior.free_first', '1', true);

  insert into bookings (studio_id, occurrence_id, member_id, status, source,
                        payment_source, provisional, confirmed_at)
  values (v_occ.studio_id, p_occurrence_id, v_member.id, 'booked', 'member', 'comp',
          v_prov, case when v_prov then null else now() end)
  returning id into v_booking;
  update class_occurrences set booked_count = booked_count + 1 where id = p_occurrence_id;

  -- The shared once-ever ledger row. Decision 78: a no-show member's rebook
  -- REUSES this row (upsert on the once-ever index) rather than inserting a
  -- second — the index and its hard guarantee are untouched; the member's comp
  -- no_show bookings are what count the attempts.
  insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email,
                            occurrence_id, guest_booking_id, status, waiver_signed_at)
  values (v_occ.studio_id, null, v_member.id, lower(btrim(v_member.email)),
          p_occurrence_id, v_booking,
          case when v_member.waiver_signed_at is not null then 'confirmed' else 'invited' end,
          v_member.waiver_signed_at)
  on conflict (studio_id, normalize_email_key(guest_email)) do update
    set host_member_id   = excluded.host_member_id,
        guest_member_id  = excluded.guest_member_id,
        occurrence_id    = excluded.occurrence_id,
        guest_booking_id = excluded.guest_booking_id,
        status           = excluded.status,
        waiver_signed_at = excluded.waiver_signed_at
  returning id into v_pass;

  perform confirm_provisional_seats_run(p_occurrence_id);

  return jsonb_build_object('ok', true, 'booking_id', v_booking,
    'guest_pass_id', v_pass, 'provisional', v_prov);
end $function$;
revoke execute on function book_first_free(uuid) from public, anon;
grant  execute on function book_first_free(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 2. queue_booking_notifications — re-issued from 20260832750000. Two changes:
--    (a) v_is_free reads the flag OR the guest_passes row; (b) a NON-provisional
--    free seat queues free_booking_confirmed (never booking_confirmed), placed
--    BEFORE the flex branch so a free first class never reaches flex/paid. Every
--    other branch is unchanged.
-- -----------------------------------------------------------------------------
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
  v_fmt text;              -- Decision 55
  v_cancel_deadline text;  -- free_booking_confirmed payload
begin
  select * into b from bookings where id = p_booking_id;
  if not found or b.status <> 'booked' then return 0; end if;

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

  -- Free first class: the flag (set by book_first_free before the booking insert,
  -- so the guest_passes row does not exist yet at this trigger) OR a host-null
  -- guest_passes row for this booking.
  v_is_free := current_setting('studiior.free_first', true) = '1'
    or (b.payment_source = 'comp'
        and exists (select 1 from guest_passes gp
                     where gp.guest_booking_id = b.id and gp.host_member_id is null));
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
            'cutoff_long', fmt_clock(v_cutoff, s.timezone, v_fmt) || ' on ' || to_char(v_cutoff at time zone s.timezone, 'FMDay FMDD FMMonth YYYY'),
            'booking_id', b.id, 'occurrence_id', o.id),
          'booking_confirmed:' || b.id) is not null then n := n + 1; end if;
  elsif v_is_free then
    -- A NON-provisional free first class: the free-class confirmation, never the
    -- plan/price card. Payload shape mirrors confirm_provisional_seats_run so the
    -- template's class card and manage button render. Same dedupe key as the
    -- other at-booking receipts (withdrawn on release).
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
            -- Decision 21 amendment (20 Oct 2026): the short "Sun 8:00 PM" the
            -- plain-words subject/body read. {Day} {time} via fmt_clock.
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

-- -----------------------------------------------------------------------------
-- 3. member_plan_overview — re-issued from 20260832770000 with ONE additive
--    column has_unpaid_booking: the member holds a live unpaid drop-in (the 73a
--    predicate) on a FUTURE occurrence. plan_state is UNCHANGED. Adding an output
--    column to a RETURNS TABLE is a DROP + recreate; ACL re-asserted.
-- -----------------------------------------------------------------------------
drop function if exists member_plan_overview(uuid);

create or replace function member_plan_overview(p_studio_id uuid)
returns table (
  id uuid, first_name text, last_name text, email text, status text,
  lifetime_visits int, last_visit_at timestamptz,
  health_band text, health_reason text, user_id uuid,
  membership_id uuid, current_plan_name text, plan_type text,
  membership_status text, expires_on date, credits_remaining int,
  had_free_class boolean, has_ever_paid boolean, plan_state text,
  complimentary boolean, free_stage text, has_unpaid_booking boolean
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare v_tz text; v_today date;
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
           m.health_band::text as health_band, m.health_reason, m.user_id
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
  -- The member's free (comp) bookings, cancelled/late_cancelled excluded. A
  -- no_show's class instant is kept so "no later booking" can be tested.
  comp as (
    select b.member_id,
           bool_or(b.status = 'attended') as any_attended,
           bool_or(b.status = 'booked')   as any_booked,
           bool_or(b.status = 'no_show')  as any_no_show,
           max(o.starts_at) filter (where b.status = 'no_show') as last_no_show_at
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
     where b.studio_id = p_studio_id
       and b.payment_source = 'comp'
       and b.status in ('booked','attended','no_show')
     group by b.member_id
  ),
  -- A live unpaid drop-in (the Decision 73a predicate) on a FUTURE occurrence:
  -- booked, not settled by a succeeded/partially-refunded payment. Distinct from
  -- plan_state, which stays 'none' for such a member — the chip is additive.
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
           else null
         end as free_stage,
         (unpaid.member_id is not null) as has_unpaid_booking
    from mem
    left join live    on live.member_id = mem.id
    left join paid    on paid.member_id = mem.id
    left join freebie on freebie.member_id = mem.id
    left join comp    on comp.member_id = mem.id
    left join unpaid  on unpaid.member_id = mem.id;
end $$;

revoke all on function member_plan_overview(uuid) from public, anon;
grant execute on function member_plan_overview(uuid) to authenticated, service_role;

-- Anon surface must still be EXACTLY THIRTEEN.
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
    raise exception 'anon surface is %, expected 13', n;
  end if;
end $$;
