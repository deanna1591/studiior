-- Step 13a: Decision 75 (l) instructor pay follows the term sheet, 31 (a)
-- conversion bonus at month-end, 21 (f) a flex class's state follows its live
-- bookings, 35 (b) Mark no-show from the roster, 108 (b) the daily check
-- catches pay mistakes.
--
-- creates: class_seats_used_run(uuid), flex_emptied_run(uuid), mark_no_show_run(uuid, uuid), staff_mark_no_show(uuid, text), tg_rate_version_carry_total()
-- re-issues: compute_class_pay_run(uuid, integer), finalise_pay_true_up(uuid), commitment_pending(uuid), evaluate_commitment(uuid), tg_flex_reached_minimum(), award_conversion_bonus_run(uuid), finalise_attendance_sweep(), member_activity(uuid, date, date), daily_money_check(uuid)
--
-- Newest definitions this re-issues from:
--   compute_class_pay_run: 20260833600000_decision116b_private_keeps_coach.sql:369
--   finalise_pay_true_up: 20260833630000_decision75j_housekeeping.sql:239
--   commitment_pending: 20260831960000_commitment_pending_run_restore.sql:12
--   evaluate_commitment / tg_flex_reached_minimum: 20260833420000_decision101_instructor_digest.sql:485 / 632
--   award_conversion_bonus_run: 20260831910000_xendit_return_check_result.sql:43
--   finalise_attendance_sweep: 20260832720000_decision75b1_checkin_pay_basis.sql:295
--   member_activity: 20260833670000_step12_promotions_return_credit.sql:2125
--   daily_money_check: 20260833650000_step11_reservation_state_fee_choice.sql:1526
-- create or replace keeps every re-issued function's ACL. No new anon surface:
-- anon stays EXACTLY FOURTEEN (asserted at the end).

-- ---- 75 (l): the full-house TOTAL on the rate card -------------------------
alter table instructor_rate_versions
  add column if not exists full_house_total_cents int
  check (full_house_total_cents is null or full_house_total_cents >= 0);
comment on column instructor_rate_versions.full_house_total_cents is
  'Decision 75 (l): when set, a class whose heads reach capacity pays exactly this total (not base + per head + bonus). Null keeps the bonus-on-top model.';

-- A card is never edited, so a later rate change would drop the total; a new
-- card with no total inherits the instructor's previous total.
create function tg_rate_version_carry_total()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.full_house_total_cents is null then
    select rv.full_house_total_cents into new.full_house_total_cents
      from instructor_rate_versions rv
     where rv.instructor_id = new.instructor_id and rv.effective_from < new.effective_from
     order by rv.effective_from desc, rv.created_at desc limit 1;
  end if;
  return new;
end $$;
revoke execute on function tg_rate_version_carry_total() from public, anon, authenticated;
create trigger tg_rate_version_carry_total
  before insert on instructor_rate_versions
  for each row execute function tg_rate_version_carry_total();

-- The 25 Nov cards (a ₱200 bonus on top, written so a full house came to
-- ₱1,400) become a ₱1,400 TOTAL with no bonus, by a NEW card from 26 Nov.
-- Existing cards and past lines are untouched.
insert into instructor_rate_versions (studio_id, instructor_id, effective_from, pay_model, pay_tier,
    currency, base_rate_cents, per_head_rate_cents, per_head_threshold, full_house_bonus_cents,
    private_rate_cents, duo_rate_cents, trio_rate_cents, full_house_total_cents, note)
select x.studio_id, x.instructor_id, date '2026-11-26', x.pay_model, x.pay_tier, x.currency,
       x.base_rate_cents, x.per_head_rate_cents, x.per_head_threshold, 0,
       x.private_rate_cents, x.duo_rate_cents, x.trio_rate_cents, 140000,
       'Decision 75 (l): full house is a ₱1,400 total, not a bonus on top.'
  from (select distinct on (rv.instructor_id) rv.*
          from instructor_rate_versions rv
         where rv.effective_from <= date '2026-11-26'
         order by rv.instructor_id, rv.effective_from desc, rv.created_at desc) x
 where x.note like 'Full house is ₱1,400 total per term sheet%'
   and not exists (select 1 from instructor_rate_versions y
                    where y.instructor_id = x.instructor_id and y.effective_from = date '2026-11-26');

-- ---- 75 (l): seats used -----------------------------------------------------
-- A seat the member USED: checked in, no-show, late cancel, or still booked (a
-- booked seat at or after the class is one finalisation is about to mark), one
-- per member, which takes in walk-ins and anyone added after the cut-off. Not
-- used: on-time cancels, moved bookings (they live on the new class), unpaid
-- holds and provisional free seats released by the system. An unpaid drop-in
-- (Decision 81b) counts once it attends or cancels late.
create function class_seats_used_run(p_occurrence_id uuid)
returns int language sql stable security definer set search_path = public as $$
  select count(distinct b.member_id)::int
    from bookings b
   where b.occurrence_id = p_occurrence_id
     and (b.status in ('attended', 'late_cancelled')
          or (b.status in ('booked','no_show')
              and not coalesce(b.provisional, false)
              -- Decision 81b: an unpaid drop-in that has not come in (booked or
              -- a no-show) never adds to pay until it is paid.
              and not (coalesce(b.payment_source = 'drop_in', false)
                       and not exists (select 1 from payments pmt
                                        where pmt.booking_id = b.id
                                          and pmt.status in ('succeeded','partially_refunded')))));
$$;
revoke execute on function class_seats_used_run(uuid) from public, anon, authenticated;
grant  execute on function class_seats_used_run(uuid) to service_role;

-- ---- 75 (l): compute_class_pay_run ------------------------------------------
CREATE OR REPLACE FUNCTION public.compute_class_pay_run(p_occurrence_id uuid, p_heads integer DEFAULT NULL::integer)
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
  select * into rv from instructor_rate_at_run(o.instructor_id, v_local);
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
  -- DECISION 75 (l): the greater of the cut-off count and the seats used
  -- (class_seats_used_run), so a walk-in or a post-cut-off joiner adds a head
  -- and a late cancel or no-show never takes one away.
  v_heads := coalesce(p_heads, greatest(coalesce(o.booked_at_cutoff, 0), coalesce(o.booked_at_start, 0),
                                        class_seats_used_run(p_occurrence_id)));

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
  --    Decision 75 (l): a committed class later cancelled WITH a cause (studio
  --    fault, force majeure, closure) is paid by that cause in branch 3.
  elsif o.status <> 'cancelled' or (o.committed_at is not null and o.cancellation_cause is null) then
    if v_heads = 0 then
      -- Decision 75 (l): it ran (an always-runs class) with nobody in it. Core
      -- and always pay the holding fee; flex pays nothing.
      v_amount := case when g.tier = 'flex' then 0
                       else coalesce(s.core_unmet_pay_cents,
                                     (rv.base_rate_cents * coalesce(s.core_unmet_pay_pct, 0)) / 100) end;
    elsif o.capacity is not null and v_heads >= o.capacity and rv.full_house_total_cents is not null then
      -- Decision 75 (l): a full house is a fixed TOTAL on the rate card.
      v_amount := rv.full_house_total_cents;
    else
    v_amount := rv.base_rate_cents
              + greatest(0, v_heads - rv.per_head_threshold) * rv.per_head_rate_cents
              -- Keys off THE CLASS's capacity, which varies by room. A capacity
              -- 5 studio and a capacity 6 studio both reach a full house.
              + case when o.capacity is not null and v_heads >= o.capacity
                     then rv.full_house_bonus_cents else 0 end;
    end if;
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
                                     and rv.full_house_total_cents is null
                                     then rv.full_house_bonus_cents else 0 end,
      'full_house_total_cents', case when o.capacity is not null and v_heads >= o.capacity
                                     then rv.full_house_total_cents end,
      'tier', g.tier, 'seats_used', class_seats_used_run(p_occurrence_id),
      'holding_fee', v_heads = 0);

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
    elsif o.cancellation_cause = 'replaced_by_private' then
      -- Decision 116(b): a replaced class pays nothing, in every case. Only the
      -- class's own coach can teach the private that replaces it, and they are
      -- paid for the private; no coach is ever displaced.
      v_amount := 0;
      v_basis := jsonb_build_object('kind', 'group', 'outcome', 'replaced_by_private',
        'tier', g.tier, 'cause', o.cancellation_cause, 'base_cents', rv.base_rate_cents);
    else
      v_amount := case o.cancellation_cause
        -- Decision 75 (l): a studio cancellation pays core its base, flex nothing.
        when 'studio_fault'  then case when g.tier = 'flex' then 0 else rv.base_rate_cents end
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

-- ---- 75 (l): finalise_pay_true_up --------------------------------------------
CREATE OR REPLACE FUNCTION public.finalise_pay_true_up(p_occurrence_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o class_occurrences%rowtype; v_rec instructor_pay_records%rowtype;
  s studio_settings%rowtype; v_kind session_kind; c jsonb;
  v_heads int; v_checked int; v_consumed int; v_cut int; v_basis text; v_new int; v_delta int; p pay_periods%rowtype; v_id uuid;
begin
  select * into o from class_occurrences where id = p_occurrence_id for update;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not is_service_context() and not coalesce(is_manager_up(o.studio_id), false) then
    raise exception 'the finalisation true-up is a background job' using errcode = 'PT403';
  end if;

  -- Only when the studio pays on attendance. OFF => the booked basis stands.
  select * into s from studio_settings where studio_id = o.studio_id;
  if not coalesce(s.finalise_attendance, false) then
    return jsonb_build_object('ok', true, 'skipped', 'finalisation_off');
  end if;

  -- Only a committed, still-scheduled class trues up on heads. A not_running or
  -- otherwise cancelled class is paid by its cancellation rule, not a count.
  if o.committed_at is null or o.status <> 'scheduled' then
    return jsonb_build_object('ok', true, 'skipped', 'not a committed running class');
  end if;

  -- A private/duo/trio is a flat line, untouched by headcount.
  select coalesce(ct.session_kind, 'group') into v_kind
    from class_types ct where ct.id = o.class_type_id;
  if coalesce(v_kind, 'group') <> 'group' then
    return jsonb_build_object('ok', true, 'skipped', 'flat_rate');
  end if;

  select * into v_rec from instructor_pay_records
   where occurrence_id = p_occurrence_id and type = 'class';
  if not found then
    return jsonb_build_object('ok', true, 'record', 'none');
  end if;

  -- Idempotent: the in-place path stamps basis.finalised_at; the closed path
  -- leaves an adjustment keyed on finalise_of. Either means we are done.
  if (v_rec.basis ? 'finalised_at')
     or exists (select 1 from instructor_pay_records
                 where type = 'adjustment' and basis ->> 'finalise_of' = p_occurrence_id::text) then
    return jsonb_build_object('ok', true, 'already', 'finalised');
  end if;

  -- Decision 75(j): pay follows the seat, not the body. Seats consumed are
  -- attended, no-show and late cancelled (a late cancel is after the cut-off by
  -- definition); a still-booked seat at finalisation is one the sweep is about
  -- to mark attended or no-show, so it counts too. An on-time cancel never
  -- counts. The heads paid are the greater of the count at the cut-off and the
  -- seats consumed, so pay never drops below the cut-off promise (Decision 32).
  -- checked_in is still recorded so the statement can say "M checked in".
  select count(distinct member_id)::int into v_checked
    from check_ins where occurrence_id = p_occurrence_id;
  -- Decision 75 (l): the seats used, one per member, never a released hold
  -- or a provisional free seat (class_seats_used_run, the one definition).
  v_consumed := class_seats_used_run(p_occurrence_id);
  v_cut := coalesce(o.booked_at_cutoff, 0);
  v_heads := greatest(v_cut, v_consumed);
  v_basis := case when v_consumed > v_cut then 'consumed' else 'cutoff' end;

  c := compute_class_pay_run(p_occurrence_id, v_heads);
  if not (c ->> 'ok')::boolean then
    return jsonb_build_object('ok', true, 'recompute', c);
  end if;
  v_new := (c ->> 'amount_cents')::int;
  v_delta := v_new - v_rec.amount_cents;

  select * into p from pay_periods where id = v_rec.period_id;

  if p.status = 'open' then
    -- Raise OR lower in place, re-copy the instructor from the occurrence (an
    -- accepted cover is paid for the class they taught), and record what the
    -- line now rests on so the statement can say "M checked in · paid on H".
    update instructor_pay_records
       set amount_cents  = v_new,
           instructor_id = o.instructor_id,
           basis = (c -> 'basis')
                   || jsonb_build_object('finalise_of', p_occurrence_id,
                                         'checked_in', v_checked,
                                         'heads_consumed', v_consumed,
                                         'heads_basis', v_basis,
                                         'heads_paid', v_heads,
                                         'finalised_at', now())
     where id = v_rec.id;
    return jsonb_build_object('ok', true, 'trued_up', 'in_place',
      'checked_in', v_checked, 'heads_consumed', v_consumed, 'heads_basis', v_basis,
      'heads_paid', v_heads, 'delta_cents', v_delta, 'amount_cents', v_new);
  end if;

  -- The period is CLOSED — immutable, already paid. The difference goes in the
  -- next open period as an adjustment (signed; it may claw back), naming the
  -- class and the period it came from so the statement can label it "from the
  -- previous period". delta 0 needs no adjustment.
  if v_delta = 0 then
    return jsonb_build_object('ok', true, 'closed', true, 'checked_in', v_checked, 'heads_consumed', v_consumed,
      'heads_basis', v_basis, 'heads_paid', v_heads, 'delta_cents', 0);
  end if;
  p := next_open_pay_period(o.studio_id);
  insert into instructor_pay_records (
    studio_id, instructor_id, period_id, type, amount_cents, currency,
    rate_version_id, basis, note, created_by)
  values (o.studio_id, o.instructor_id, p.id, 'adjustment', v_delta, (c ->> 'currency'),
          (c ->> 'rate_version_id')::uuid,
          jsonb_build_object('finalise_of', p_occurrence_id, 'original_period', v_rec.period_id,
            'checked_in', v_checked, 'heads_consumed', v_consumed, 'heads_basis', v_basis,
            'heads_paid', v_heads, 'booked_at_cutoff', v_cut,
            'reason', 'attendance correction'),
          o.name || ': attendance correction (from the previous period)', auth.uid())
  returning id into v_id;
  return jsonb_build_object('ok', true, 'trued_up', 'adjustment',
    'adjustment_id', v_id, 'checked_in', v_checked, 'heads_consumed', v_consumed,
    'heads_basis', v_basis, 'heads_paid', v_heads, 'delta_cents', v_delta);
end $function$;

-- ---- 21 (f)(4): commitment_pending ------------------------------------------
CREATE OR REPLACE FUNCTION public.commitment_pending(p_studio_id uuid)
 RETURNS TABLE(occ_id uuid, occ_name text, starts_at timestamp with time zone, local_when text, tier guarantee_tier, booked integer, minimum integer, short_by integer, due_at timestamp with time zone, cutoff_shape text, past_due boolean, instructor_id uuid, is_adjacent boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_tz text; s studio_settings%rowtype;
begin
  if not coalesce(is_manager_up(p_studio_id), false) and not is_service_context() then
    raise exception 'only owners and managers see this' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  if v_tz is null then raise exception 'no such studio' using errcode = 'PT404'; end if;
  select * into s from studio_settings where studio_id = p_studio_id;
  -- Either switch puts classes in scope; occurrence_guarantee_run() decides which
  -- tiers those are. Neither means nothing is ever pending, which is what
  -- "sees no change" means.
  if not coalesce(s.guarantees_enabled, false)
     and not coalesce(s.flex_enabled, false) then
    return;
  end if;

  return query
  select o.id, o.name, o.starts_at,
         to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMon, HH24:MI'),
         g.tier, b.n, g.minimum, greatest(0, g.minimum - b.n),
         g.cutoff_at, g.cutoff_shape, now() >= g.cutoff_at,
         o.instructor_id, occurrence_is_adjacent_run(o.id)
    from class_occurrences o
    cross join lateral occurrence_guarantee_run(o.id) g
    cross join lateral (
      select count(*)::int as n from bookings bk
       where bk.occurrence_id = o.id
         and bk.status in ('booked','attended','no_show','pending_payment')
    ) b
   where o.studio_id = p_studio_id
     and o.status = 'scheduled'
     and o.committed_at is null
     -- Decision 21 (f)(4): an always-runs class's decision time IS its start, so
     -- it stays pending for a day after it starts (the sweep runs every 15
     -- minutes) and is committed then, which writes its pay line.
     and (o.starts_at > now() or (g.tier = 'always' and o.starts_at > now() - interval '1 day'))
     -- 'always' is included: it commits at its start time. Only a class with no
     -- cutoff at all — a studio with both switches off — is out of scope.
     and g.cutoff_at is not null
     -- Decision 25: a draft month is not decided. Nobody can book a class in
     -- it, so a flex class evaluated there would be cancelled for want of the
     -- bookings it was never allowed to take.
     and occurrence_published(o.id)
   order by o.starts_at;
end $function$;

-- ---- 21 (f)(2): evaluate_commitment ------------------------------------------
CREATE OR REPLACE FUNCTION public.evaluate_commitment(p_occurrence_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o class_occurrences%rowtype; g record; v_booked int; s studios%rowtype; r record; v_iu uuid;
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
     and status in ('booked','attended','no_show','pending_payment')
     -- Decision 81b: an UNPAID drop-in (the pay_first predicate) holds its
     -- seat but is not counted here, so it never keeps a class alive and
     -- never adds to the pay headcount until it is paid.
     and not (coalesce(bookings.payment_source = 'drop_in', false)
              and not exists (select 1 from payments pmt
                               where pmt.booking_id = bookings.id
                                 and pmt.status in ('succeeded','partially_refunded')));

  -- Decision 21 (f)(2): the live paid count decides, never a stale latch.
  if v_booked >= g.minimum then
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
                  -- Decision 81b: do not tell an unpaid drop-in the flex class
                  -- is confirmed on the strength of their own unpaid seat.
                  and not (coalesce(bookings.payment_source = 'drop_in', false)
                           and not exists (select 1 from payments pmt
                                            where pmt.booking_id = bookings.id
                                              and pmt.status in ('succeeded','partially_refunded')))
      loop
        perform queue_notification(o.studio_id, r.member_id, 'flex_booking_confirmed',
          jsonb_build_object('class_name', o.name,
            'day',  to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth'),
            'time', fmt_clock(o.starts_at, s.timezone,
                     coalesce((select time_format from studio_settings where studio_id = o.studio_id), '24h')),
            -- Decision 21 amendment (20 Oct 2026): plain words read {when} and
            -- {studio_name} — "See you {when} at {studio}".
            'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth') || ' at '
                    || fmt_clock(o.starts_at, s.timezone,
                         coalesce((select time_format from studio_settings where studio_id = o.studio_id), '24h')),
            'studio_name', s.name,
            'manage_link', member_portal_url(o.studio_id, '/class/' || p_occurrence_id),
            'book_url', member_portal_url(o.studio_id, '/book'),
            'occurrence_id', p_occurrence_id),
          'flex_member_confirmed:' || p_occurrence_id || ':' || r.member_id);
      end loop;
    end if;

    return jsonb_build_object('ok', true, 'decision', 'committed',
      'tier', g.tier, 'booked_at_cutoff', v_booked, 'minimum', g.minimum,
      'latched', (v_booked < g.minimum));
  end if;

  update class_occurrences
     set booked_at_cutoff = v_booked, flex_reached_minimum_at = null, core_reached_minimum_at = null
   where id = p_occurrence_id;
  perform cancel_occurrence(p_occurrence_id,
            'Did not reach its minimum by the cutoff', 'unmet_minimum');

  -- Decision 101: the assigned instructor is told via the daily digest at the
  -- cut-off, not a per-class email. (A queue_shift_notice of
  -- instructor_class_cancelled stood here for the not-enough-bookings cause;
  -- removed — sweep_commitments' instructor_daily_digest covers it. The member
  -- flex_booking_not_confirmed, queued inside cancel_occurrence above, stays.)

  return jsonb_build_object('ok', true, 'decision', 'not_running',
    'tier', g.tier, 'booked_at_cutoff', v_booked, 'minimum', g.minimum);
end $function$;

-- ---- 21 (f)(1)(3): tg_flex_reached_minimum ------------------------------------
CREATE OR REPLACE FUNCTION public.tg_flex_reached_minimum()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare g record; v_paid int; v_live int;
begin
  -- Cheap exits first: only a flex, scheduled class with a coach.
  if not (coalesce(new.flex, false) or new.guarantee_tier is not distinct from 'flex')
     or new.status <> 'scheduled'
     or new.instructor_id is null then
    return new;
  end if;
  -- A committed class only matters when a seat went (Decision 21 (f)(3)).
  if new.committed_at is not null and new.booked_count >= old.booked_count then
    return new;
  end if;

  select * into g from occurrence_guarantee_run(new.id) g;
  -- Decision 81b: the latch (Decision 21) is set by PAID seats only, so an
  -- unpaid drop-in (the pay_first predicate) does not make a flex class go
  -- ahead or email the instructor. booked_count still counts the held seat
  -- for capacity; only this decision excludes it.
  select count(*)::int into v_paid from bookings
   where occurrence_id = new.id
     and status in ('booked','attended','no_show','pending_payment')
     and not (coalesce(bookings.payment_source = 'drop_in', false)
              and not exists (select 1 from payments pmt
                               where pmt.booking_id = bookings.id
                                 and pmt.status in ('succeeded','partially_refunded')));
  -- Only a class that BEHAVES as flex (studio switch on) has a minimum to
  -- reach; occurrence_guarantee demotes a flex class at a flex-off studio to
  -- 'always', which is correctly ignored here.
  if g.tier is distinct from 'flex' or g.minimum is null then
    return new;
  end if;

  if new.committed_at is not null then
    -- Decision 21 (f)(3): after the cut-off, a confirmed flex class that has
    -- lost every live booking (and has not started) is cancelled at once.
    if new.starts_at > now() then
      select count(*)::int into v_live from bookings
       where occurrence_id = new.id and status in ('booked','attended','pending_payment');
      if v_live = 0 then perform flex_emptied_run(new.id); end if;
    end if;
    return new;
  end if;

  if new.flex_reached_minimum_at is not null then
    -- Decision 21 (f)(1): before the cut-off the latch follows the live paid
    -- count; it clears the moment paid seats drop below the minimum.
    if v_paid < g.minimum and (g.cutoff_at is null or now() < g.cutoff_at) then
      update class_occurrences set flex_reached_minimum_at = null
       where id = new.id and flex_reached_minimum_at is not null;
    end if;
    return new;
  end if;

  if v_paid < g.minimum then
    return new;
  end if;

  -- The latch is stamped (the commit sweep and other code read it); Decision 101
  -- removes the per-class flex_going_ahead email — flex_going_ahead was the
  -- flex-tier twin of core_committed, and the instructor now learns a class is
  -- going ahead from sweep_commitments' instructor_daily_digest at the cut-off,
  -- not at the first booking that crosses the minimum.
  update class_occurrences set flex_reached_minimum_at = now()
   where id = new.id and flex_reached_minimum_at is null;

  return new;
end $function$;

-- ---- 21 (f)(3): a confirmed flex class that lost every booking --------------
create function flex_emptied_run(p_occurrence_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o class_occurrences%rowtype; v_tz text; v_fmt text; v_date date; v_rec instructor_pay_records%rowtype;
  c jsonb; v_iu uuid; v_n int := 0; v_told text := 'none';
begin
  select * into o from class_occurrences where id = p_occurrence_id for update;
  if not found or o.status <> 'scheduled' or o.committed_at is null or o.starts_at <= now() then
    return jsonb_build_object('ok', true, 'skipped', 'not a confirmed future class');
  end if;
  if exists (select 1 from bookings where occurrence_id = p_occurrence_id
               and status in ('booked','attended','pending_payment')) then
    return jsonb_build_object('ok', true, 'skipped', 'still has a live booking');
  end if;
  select timezone into v_tz from studios where id = o.studio_id;
  select coalesce(time_format, '24h') into v_fmt from studio_settings where studio_id = o.studio_id;
  v_date := (o.starts_at at time zone v_tz)::date;

  -- The class is off. The pay trigger stands aside (it would call the guarded
  -- record_class_pay in a member's own session); the pay line is set below.
  perform set_config('studiior.pay_resolve', '1', true);
  update class_occurrences
     set committed_at = null, flex_reached_minimum_at = null, core_reached_minimum_at = null,
         booked_at_cutoff = 0, status = 'cancelled', cancelled_at = now(),
         cancellation_reason = 'Every booking was cancelled after the cut-off',
         cancellation_cause = 'unmet_minimum', updated_at = now()
   where id = p_occurrence_id;
  perform set_config('studiior.pay_resolve', '', true);

  -- Anybody still waiting has nothing to wait for.
  perform set_config('studiior.releasing', '1', true);
  update bookings set status = 'cancelled', cancelled_at = now(), updated_at = now()
   where occurrence_id = p_occurrence_id and status = 'waitlisted';
  perform set_config('studiior.releasing', '', true);

  -- 75 (l): a flex class that confirmed and then lost every booking pays ₱0.
  select * into v_rec from instructor_pay_records
   where occurrence_id = p_occurrence_id and type = 'class';
  if found then
    c := compute_class_pay_run(p_occurrence_id);
    if (c ->> 'ok')::boolean and (c ->> 'amount_cents')::int <> v_rec.amount_cents then
      update instructor_pay_records
         set amount_cents = (c ->> 'amount_cents')::int,
             basis = (c -> 'basis') || jsonb_build_object('flex_emptied', true),
             confirmed_at = coalesce(confirmed_at, now()),
             confirm_method = coalesce(confirm_method, 'auto')
       where id = v_rec.id;
      insert into audit_logs (studio_id, action, entity_table, entity_id, before, after)
      values (o.studio_id, 'pay.line_corrected', 'instructor_pay_records', v_rec.id,
              jsonb_build_object('amount_cents', v_rec.amount_cents, 'occurrence_id', p_occurrence_id),
              jsonb_build_object('amount_cents', (c ->> 'amount_cents')::int, 'occurrence_id', p_occurrence_id,
                                 'note', 'Flex class lost every booking after the cut-off (Decision 21 (f)).'));
    end if;
  end if;

  -- The coach is told once: the day's pending digest is refreshed, else one notice.
  v_iu := instructor_user_id(o.instructor_id);
  if v_iu is not null then
    update notifications
       set payload = payload || instructor_digest_block(o.studio_id, o.instructor_id, v_date)
     where dedupe_key = 'instructor_digest:' || o.instructor_id || ':' || v_date
       and template_key = 'instructor_daily_digest' and status = 'scheduled';
    get diagnostics v_n = row_count;
    if v_n > 0 then
      v_told := 'digest';
    else
      perform queue_shift_notice(o.studio_id, v_iu, 'instructor_class_cancelled',
        jsonb_build_object('class_name', o.name,
          'when', to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMonth YYYY'),
          'reason', 'lost every booking after the cut-off',
          'occurrence_id', p_occurrence_id),
        'instructor_class_cancelled:' || p_occurrence_id);
      v_told := 'notice';
    end if;
  end if;

  insert into audit_logs (studio_id, action, entity_table, entity_id, after)
  values (o.studio_id, 'occurrence.flex_emptied', 'class_occurrences', p_occurrence_id,
          jsonb_build_object('cause', 'unmet_minimum', 'coach_told', v_told));
  return jsonb_build_object('ok', true, 'cancelled', true, 'coach_told', v_told);
end $$;
revoke execute on function flex_emptied_run(uuid) from public, anon, authenticated;
grant  execute on function flex_emptied_run(uuid) to service_role;

-- ---- 31 (a): award_conversion_bonus_run -------------------------------------
create or replace function award_conversion_bonus_run(p_membership_id uuid)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  m memberships%rowtype; s studio_settings%rowtype; pl membership_plans%rowtype;
  f record; p pay_periods%rowtype; v_tz text; v_first date; v_buy date; v_id uuid;
  v_name text;
begin
  select * into m from memberships where id = p_membership_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such membership'); end if;

  select * into s from studio_settings where studio_id = m.studio_id;
  if not coalesce(s.conversion_bonus_enabled, false) then
    return jsonb_build_object('ok', true, 'awarded', false, 'reason', 'not enabled');
  end if;
  if coalesce(s.conversion_bonus_cents, 0) = 0 then
    return jsonb_build_object('ok', true, 'awarded', false, 'reason', 'bonus is zero');
  end if;

  select * into pl from membership_plans where id = m.plan_id;
  if not coalesce(pl.counts_for_conversion, false) then
    return jsonb_build_object('ok', true, 'awarded', false,
                              'reason', 'plan does not count for conversion');
  end if;

  -- The UNGUARDED internal — this runs from a trigger with no session (anon
  -- webhook) or as the buying member (belt), neither of which is desk-up or
  -- service-context, so the guarded member_first_class would refuse them.
  select * into f from member_first_class_run(m.member_id);
  if f.instructor_id is null then
    return jsonb_build_object('ok', true, 'awarded', false,
                              'reason', 'no attended class to attribute to');
  end if;

  select timezone into v_tz from studios where id = m.studio_id;
  v_first := (f.attended_at at time zone v_tz)::date;
  v_buy   := (coalesce(m.created_at, now()) at time zone v_tz)::date;
  if v_buy - v_first > coalesce(s.conversion_window_days, 30) then
    return jsonb_build_object('ok', true, 'awarded', false, 'reason', 'outside the window',
      'days', v_buy - v_first, 'window', s.conversion_window_days);
  end if;

  select btrim(coalesce(preferred_name, first_name) || ' ' || coalesce(last_name, ''))
    into v_name from members where id = m.member_id;
  -- Decision 31 (a): a conversion bonus is paid at month-end only, in the
  -- period that ends on the last day of the month it was earned.
  p := ensure_pay_period(m.studio_id, (date_trunc('month', v_buy) + interval '1 month - 1 day')::date);
  if p.status = 'closed' then p := next_open_pay_period(m.studio_id); end if;

  begin
    insert into instructor_pay_records (
      studio_id, instructor_id, period_id, type, source_id, amount_cents, currency,
      basis, note, created_by)
    values (m.studio_id, f.instructor_id, p.id, 'conversion', m.member_id,
            s.conversion_bonus_cents,
            (select currency from studios where id = m.studio_id),
            jsonb_build_object('member_id', m.member_id, 'member_name', v_name,
              'plan_id', pl.id, 'plan_name', pl.name, 'membership_id', m.id,
              'first_class_occurrence', f.occurrence_id,
              'first_class_on', v_first, 'purchased_on', v_buy,
              'attribution', 'first_class'),
            'Conversion bonus', auth.uid())
    returning id into v_id;
  exception when unique_violation then
    return jsonb_build_object('ok', true, 'awarded', false,
                              'reason', 'this member has already converted');
  end;

  return jsonb_build_object('ok', true, 'awarded', true, 'pay_record_id', v_id,
    'instructor_id', f.instructor_id, 'amount_cents', s.conversion_bonus_cents);
end $$;

-- ---- 35 (b): one no-show, the sweep's own per-booking body --------------------
create function mark_no_show_run(p_booking_id uuid, p_by uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update bookings set status = 'no_show', no_show_at = now(), no_show_by = p_by, updated_at = now()
   where id = p_booking_id and status = 'booked';
end $$;
revoke execute on function mark_no_show_run(uuid, uuid) from public, anon, authenticated;
grant  execute on function mark_no_show_run(uuid, uuid) to service_role;

-- ---- 35 (b): finalise_attendance_sweep --------------------------------------
create or replace function finalise_attendance_sweep()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_marked int := 0; v_occs int := 0; r record; v_n int; v_tz text; v_fname text; v_when text; v_morning timestamptz; v_bk uuid;
begin
  if not is_service_context() then
    raise exception 'the finalisation sweep is a background job' using errcode = 'PT403';
  end if;

  for r in
    select o.id, o.studio_id, o.name, o.starts_at, o.ends_at, o.instructor_id, s.timezone as tz, s.name as studio_name
      from class_occurrences o
      join studios s on s.id = o.studio_id
      join studio_settings ss on ss.studio_id = o.studio_id
     where ss.finalise_attendance
       and o.status = 'scheduled'
       and o.attendance_finalised_at is null
       and o.ends_at < now()
       and now() >= (((o.ends_at at time zone s.timezone)::date + ss.finalise_days_after)::timestamp at time zone s.timezone)
  loop
    -- Decision 75(f): a scanned/desk check-in leaves the booking 'booked'. Flip
    -- every booked booking that HAS a check_in to attended first, then no_show
    -- only the remainder.
    update bookings set status = 'attended', updated_at = now()
     where occurrence_id = r.id and status = 'booked'
       and exists (select 1 from check_ins ci where ci.booking_id = bookings.id);

    -- Decision 35 (b): one booking at a time through mark_no_show_run, the same
    -- body Mark no-show uses on the roster.
    v_n := 0;
    for v_bk in select id from bookings where occurrence_id = r.id and status = 'booked' order by booked_at, id loop
      perform mark_no_show_run(v_bk, null);
      v_n := v_n + 1;
    end loop;

    update class_occurrences set attendance_finalised_at = now(), updated_at = now() where id = r.id;

    -- Decision 75(g): true up the pay line on checked-in heads (self-guarded).
    perform finalise_pay_true_up(r.id);

    v_occs := v_occs + 1;
    v_marked := v_marked + v_n;

    if v_n > 0 and r.instructor_id is not null and instructor_user_id(r.instructor_id) is not null then
      v_tz := r.tz;
      select split_part(coalesce(i.display_name, ''), ' ', 1) into v_fname
        from instructors i where i.id = r.instructor_id;
      v_when := to_char(r.starts_at at time zone v_tz, 'FMDay FMDD FMMon, HH24:MI');
      v_morning := (date_trunc('day', now() at time zone v_tz) + interval '8 hours') at time zone v_tz;
      insert into notifications (studio_id, recipient_type, user_id, template_key, channel,
                                 payload, dedupe_key, scheduled_for, status)
      values (r.studio_id, 'staff', instructor_user_id(r.instructor_id), 'instructor_unmarked_bookings', 'email',
              jsonb_build_object('first_name', coalesce(nullif(v_fname, ''), 'there'),
                                 'count', v_n, 'class_name', r.name, 'when', v_when,
                                 'studio_name', r.studio_name),
              'unmarked:' || r.id::text, v_morning, 'scheduled')
      on conflict (dedupe_key) do nothing;
    end if;
  end loop;

  insert into job_runs (job_key, run_for, status, finished_at)
  values ('finalise_attendance', current_date, 'done', now())
  on conflict (job_key, run_for) do update
     set attempts = job_runs.attempts + 1, started_at = now(), status = 'done', finished_at = now();

  return jsonb_build_object('occurrences', v_occs, 'marked', v_marked);
end $$;

-- ---- 35 (b): Mark no-show from the roster ------------------------------------
create function staff_mark_no_show(p_booking_id uuid, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  b bookings%rowtype; o class_occurrences%rowtype;
  v_final boolean; v_coach boolean; v_desk boolean; v_mgr boolean;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_first text;
begin
  select * into b from bookings where id = p_booking_id for update;
  if not found then raise exception 'no such booking' using errcode = 'PT404'; end if;
  select * into o from class_occurrences where id = b.occurrence_id;

  v_desk  := coalesce(is_desk_up(b.studio_id), false);
  v_mgr   := coalesce(is_manager_up(b.studio_id), false);
  v_coach := o.instructor_id is not null and coalesce(is_this_instructor(o.instructor_id), false);
  v_final := o.attendance_finalised_at is not null;

  if not (v_desk or v_coach or is_service_context()) then
    raise exception 'only staff or the class''s instructor mark attendance' using errcode = 'PT403';
  end if;
  if b.status = 'no_show' then
    raise exception 'this booking is already a no-show' using errcode = 'PT409';
  end if;
  if b.status = 'attended' or exists (select 1 from check_ins where booking_id = b.id) then
    raise exception 'this member is already checked in' using errcode = 'PT409';
  end if;
  if b.status <> 'booked' then
    raise exception 'only a booked member can be marked a no-show' using errcode = 'PT409';
  end if;
  if o.starts_at > now() then
    raise exception 'the class has not started yet' using errcode = 'PT409';
  end if;
  if v_final then
    if not v_mgr and not is_service_context() then
      raise exception 'only owners and managers correct a finalised day' using errcode = 'PT403';
    end if;
    if v_reason is null then
      raise exception 'say why this member is being marked a no-show' using errcode = 'PT400';
    end if;
  end if;

  perform mark_no_show_run(b.id, auth.uid());

  if v_coach and not v_desk then
    select split_part(coalesce(display_name, ''), ' ', 1) into v_first from instructors where id = o.instructor_id;
  else
    select split_part(coalesce(full_name, ''), ' ', 1) into v_first from profiles where id = auth.uid();
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (b.studio_id, auth.uid(), 'booking.marked_no_show', 'bookings', b.id,
          jsonb_build_object('status', 'booked', 'member_id', b.member_id, 'occurrence_id', o.id),
          jsonb_build_object('status', 'no_show', 'reason', v_reason, 'finalised', v_final,
                             'staff_first', nullif(v_first, ''),
                             'by', case when v_coach and not v_desk then 'instructor' else 'staff' end));
  return jsonb_build_object('ok', true, 'status', 'no_show');
end $$;
revoke execute on function staff_mark_no_show(uuid, text) from public, anon;
grant  execute on function staff_mark_no_show(uuid, text) to authenticated, service_role;

-- ---- 35 (b): member_activity -------------------------------------------------
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
    -- Decision 100: a staff member booked a class for this member (staff only).
    -- Read from the booking.booked_by_staff audit row so the attribution survives.
    select al.created_at as at, 'booked_by_staff' as kind,
           'Booked by ' || coalesce(al.after->>'staff_first', 'the studio')
             || coalesce(' with ' || (al.after->>'source'), '') as title,
           null::text as detail,
           null::uuid, null::int, null::text, null::uuid, null::uuid, null::uuid
      from audit_logs al
     where al.action = 'booking.booked_by_staff' and v_is_staff
       and al.entity_id = p_member_id
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
    -- Decision 36 (a): staff returned what a late cancel took (staff only). The
    -- credit itself rides the cancellation row, which claims its ledger entry.
    select al.created_at as at, 'credit_returned' as kind,
           'Credit returned by ' || coalesce(al.after->>'staff_first', 'the studio')
             || coalesce(': ' || nullif(al.after->>'note', ''), '') as title,
           null::text as detail,
           null::uuid, null::int, null::text, null::uuid, al.entity_id, null::uuid
      from audit_logs al
     where al.action = 'booking.credit_returned_by_studio' and v_is_staff
       and (al.before->>'member_id')::uuid = p_member_id
    union all
    -- Decision 35 (b): marked a no-show from the roster (staff only).
    select al.created_at as at, 'marked_no_show' as kind,
           'Marked no-show by ' || coalesce(al.after->>'staff_first', 'the studio') as title,
           nullif(al.after->>'reason', '') as detail,
           null::uuid, null::int, null::text, null::uuid, al.entity_id, null::uuid
      from audit_logs al
     where al.action = 'booking.marked_no_show' and v_is_staff
       and (al.before->>'member_id')::uuid = p_member_id

    union all
    -- booked / waitlisted / free first
    select b.booked_at,
           case when b.status = 'pending_payment' and b.payment_source = 'comp' then 'reservation_hold'
                when b.status = 'waitlisted' then 'waitlisted'
                when b.payment_source = 'comp'
                     and exists (select 1 from guest_passes gp where gp.guest_booking_id = b.id and gp.host_member_id is null)
                     then 'free_first'
                else 'booked' end,
           case when b.status = 'pending_payment' and b.payment_source = 'comp' then 'Payment pending for ' || coalesce(o.name, 'a class')
                when b.status = 'waitlisted' then 'Joined the waitlist for ' || coalesce(o.name, 'a class')
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
           case when b.payment_source = 'comp'
                     and not exists (select 1 from guest_passes gp where gp.guest_booking_id = b.id and gp.host_member_id is null)
                     and not exists (select 1 from payments p2 where p2.booking_id = b.id and p2.kind = 'reservation_fee' and p2.status in ('succeeded','partially_refunded'))
                     then (case when exists (select 1 from audit_logs al where al.action = 'reservation.hold_released_by_staff' and al.entity_id = b.id) then 'hold_released_staff' else 'hold_released' end)
                when b.release_reason = 'studio_released' then 'studio_cancelled'
                when b.status = 'late_cancelled' or b.is_late_cancel then 'late_cancelled'
                else 'cancelled' end,
           case when b.payment_source = 'comp'
                     and not exists (select 1 from guest_passes gp where gp.guest_booking_id = b.id and gp.host_member_id is null)
                     and not exists (select 1 from payments p2 where p2.booking_id = b.id and p2.kind = 'reservation_fee' and p2.status in ('succeeded','partially_refunded'))
                     then (case when exists (select 1 from audit_logs al where al.action = 'reservation.hold_released_by_staff' and al.entity_id = b.id) then 'Hold released by the studio' else 'Hold released, not paid' end)
                when b.release_reason = 'studio_released' then 'Studio cancelled ' || coalesce(o.name, 'a class')
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
                when p.kind = 'reservation_fee'
                     and exists (select 1 from bookings b2 where b2.id = p.booking_id and b2.status in ('no_show','late_cancelled'))
                     and not exists (select 1 from member_credits mc2 where mc2.booking_id = p.booking_id and mc2.reason = 'reservation_credit' and mc2.voided_at is null)
                     then 'reservation_fee_kept'
                when p.kind = 'reservation_fee' then 'reservation_fee_paid'
                else 'purchase' end,
           case when p.refunded_at is not null or p.status in ('refunded','partially_refunded') then 'Refund — ' || coalesce(p.description, 'a payment')
                when p.status = 'failed' then 'Payment failed — ' || coalesce(p.description, 'a payment')
                when p.kind = 'reservation_fee'
                     and exists (select 1 from bookings b2 where b2.id = p.booking_id and b2.status in ('no_show','late_cancelled'))
                     and not exists (select 1 from member_credits mc2 where mc2.booking_id = p.booking_id and mc2.reason = 'reservation_credit' and mc2.voided_at is null)
                     then 'Reservation fee kept'
                when p.kind = 'reservation_fee' then 'Reservation fee paid'
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
    union all
    -- Decision 103(e): reservation credit granted (attended, on-time cancel, or a
    -- lost seat). From member_credits, which the Journey did not read before.
    select mc.created_at, 'reservation_credit_back', 'Fee credited back', null::text,
           null::uuid, mc.amount_cents, mc.currency::text, null::uuid, mc.booking_id, null::uuid
      from member_credits mc
     where mc.member_id = p_member_id and mc.voided_at is null
       and mc.reason in ('reservation_credit', 'reservation_lost_seat')
    union all
    -- Decision 103(e): a released hold re-booked after the payment, or a
    -- reservation covered by credit. From audit_logs (entity = the booking).
    select al.created_at,
           case when al.action = 'reservation.credit_used' then 'reservation_credit_used'
                else 'reservation_restored' end,
           case when al.action = 'reservation.credit_used' then 'Credit used for a reservation'
                else 'Seat restored after payment' end,
           null::text, null::uuid, null::int, null::text, null::uuid, al.entity_id, null::uuid
      from audit_logs al
     where al.entity_table = 'bookings'
       and al.action in ('reservation.restored', 'reservation.repaired', 'reservation.credit_used')
       and exists (select 1 from bookings b where b.id = al.entity_id and b.member_id = p_member_id)
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

-- ---- 108 (b): daily_money_check ---------------------------------------------
create or replace function daily_money_check(p_studio_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_tz text; v_items jsonb := '[]'::jsonb; v_html text := ''; v_text text := '';
  r record; v_n int; v_line text;
begin
  if not is_service_context() then
    raise exception 'the daily check runs as the backend' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;

  for r in
    -- 1. reservation fee paid, no seat, no credit
    select mname(b.member_id) || ': paid a reservation fee for ' || cname(b.occurrence_id)
           || ' but has no seat and no credit' as line
      from payments p
      join bookings b on b.id = p.booking_id
     where p.studio_id = p_studio_id and p.kind = 'reservation_fee'
       and p.status in ('succeeded','partially_refunded')
       and b.status in ('cancelled','late_cancelled')
       and not exists (select 1 from member_credits mc
                        where mc.booking_id = b.id and mc.reason = 'reservation_credit' and mc.voided_at is null)
    union all
    -- 2. a hold older than its window
    select mname(b.member_id) || ': the hold on ' || cname(b.occurrence_id)
           || ' expired ' || ago(b.hold_until) || ' and is still open'
      from bookings b
     where b.studio_id = p_studio_id and b.hold_until is not null and b.hold_until < now()
       and b.status in ('booked','pending_payment')
    union all
    -- 3. a succeeded payment attached to nothing
    select mname(p.member_id) || ': a succeeded payment of ' || money_txt(p.amount_cents, p.currency)
           || ' is attached to nothing'
      from payments p
     where p.studio_id = p_studio_id and p.status = 'succeeded'
       and p.membership_id is null and p.booking_id is null
       and p.product_order_id is null and p.group_purchase_id is null
       -- Decision 108 (b): a member-less payment (a gift card) is attached to its card.
       and p.member_id is not null
    union all
    -- 4. a member with an active plan still marked lead
    select mname(m.id) || ': has an active plan but is still marked lead'
      from members m
     where m.studio_id = p_studio_id and m.status = 'lead' and m.deleted_at is null
       and exists (select 1 from memberships ms where ms.member_id = m.id and ms.status = 'active')
    union all
    -- 5. a live booking in a cancelled or ended class
    select mname(b.member_id) || ': booked in ' || cname(b.occurrence_id)
           || case when o.status = 'cancelled' then ' which was cancelled' else ' which has already ended' end
      from bookings b join class_occurrences o on o.id = b.occurrence_id
     where b.studio_id = p_studio_id and b.status in ('booked','pending_payment')
       and (o.status = 'cancelled' or (o.status = 'scheduled' and o.ends_at < now()))
    union all
    -- 6. a member double-booked in one class
    select mname(x.member_id) || ': booked twice in ' || cname(x.occurrence_id)
      from (select member_id, occurrence_id from bookings
             where studio_id = p_studio_id and status in ('booked','attended','pending_payment')
             group by member_id, occurrence_id having count(*) > 1) x
    union all
    -- 7. a notification unsent for more than an hour
    select (select count(*) from notifications n
             where n.studio_id = p_studio_id and n.status = 'scheduled'
               and n.scheduled_for < now() - interval '1 hour')::text
           || ' emails have been waiting over an hour to send'
     where exists (select 1 from notifications n
                    where n.studio_id = p_studio_id and n.status = 'scheduled'
                      and n.scheduled_for < now() - interval '1 hour')
    union all
    -- 8. an attended booking with no signed waiver
    select mname(b.member_id) || ': attended ' || cname(b.occurrence_id) || ' without signing the waiver'
      from bookings b join members m on m.id = b.member_id
     where b.studio_id = p_studio_id and b.status = 'attended'
       and coalesce((select require_waiver from studio_settings where studio_id = p_studio_id), false)
       and exists (select 1 from waiver_versions wv where wv.studio_id = p_studio_id)
       and m.waiver_signed_at is null
    union all
    -- 9. emails that failed in the last day, with the reason
    select count(*)::text || ' emails failed: ' || coalesce(nullif(btrim(fx.reason), ''), 'no reason given')
      from (select coalesce(split_part(error, ':', 1), 'unknown') as reason
              from notifications
             where studio_id = p_studio_id and status = 'failed'
               and coalesce(failed_at, created_at) > now() - interval '1 day') fx
     group by fx.reason
    union all
    -- 10. Decision 103(h): a credit-covered booking the owing shape would dun
    -- (the covered marker is missing). The belt against a covered booking being
    -- reported as due; member_reservation_dues excludes covered bookings.
    select mname(b.member_id) || ': covered booking ' || cname(b.occurrence_id)
           || ' is reported as owing the fee'
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
      join studio_settings st on st.studio_id = b.studio_id
     where b.studio_id = p_studio_id
       and not coalesce(b.reservation_credit_covered, false)
       and exists (select 1 from audit_logs a where a.action = 'reservation.credit_used'
                    and a.entity_table = 'bookings' and a.entity_id = b.id)
       and b.status = 'booked' and b.payment_source = 'comp'
       and coalesce(st.free_first_reservation_fee_cents, 0) > 0
       and st.free_first_reservation_from is not null
       and o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)) > now()
       and not exists (select 1 from payments p where p.booking_id = b.id
                        and p.kind = 'reservation_fee' and p.status in ('succeeded','partially_refunded'))
    union all
    -- 11. Decision 108 (a): a flex class before its cut-off carrying a
    -- reached-minimum mark with fewer paid seats than its minimum.
    select cname(o.id) || ' is marked as reached its minimum with '
           || pc.paid || ' paid of ' || o.minimum_bookings
      from class_occurrences o
      cross join lateral (select count(*)::int as paid from bookings b
             where b.occurrence_id = o.id
               and b.status in ('booked','attended','no_show','pending_payment')
               and not (coalesce(b.payment_source = 'drop_in', false)
                        and not exists (select 1 from payments pmt where pmt.booking_id = b.id
                                         and pmt.status in ('succeeded','partially_refunded')))) pc
     where o.studio_id = p_studio_id and o.status = 'scheduled'
       and coalesce(o.flex, false) and o.committed_at is null
       and (o.flex_reached_minimum_at is not null or o.core_reached_minimum_at is not null)
       and o.minimum_bookings is not null and pc.paid < o.minimum_bookings
       and now() < coalesce((select g.cutoff_at from occurrence_guarantee_run(o.id) g), o.starts_at)
    union all
    -- 12. Decision 108 (a): a pay line whose amount does not match its own
    -- recorded basis (group classes that ran, and not-running classes).
    select coalesce((select display_name from instructors where id = ipr.instructor_id), 'An instructor')
           || ': the pay line for ' || coalesce(cname(ipr.occurrence_id), 'a class') || ' is '
           || money_txt(ipr.amount_cents, ipr.currency) || ' but its basis gives '
           || money_txt(x.expected, ipr.currency)
      from instructor_pay_records ipr
      cross join lateral (select case
          when (ipr.basis ->> 'full_house_total_cents') is not null then
            (ipr.basis ->> 'full_house_total_cents')::int
          when coalesce((ipr.basis ->> 'holding_fee')::boolean, false) then null
          when ipr.basis ? 'per_head_cents' and ipr.basis ? 'booked_paid' then
            (ipr.basis ->> 'base_cents')::int
            + greatest(0, (ipr.basis ->> 'booked_paid')::int - (ipr.basis ->> 'per_head_threshold')::int)
              * (ipr.basis ->> 'per_head_cents')::int
            + coalesce((ipr.basis ->> 'full_house_bonus_cents')::int, 0)
          when ipr.basis ->> 'outcome' = 'not_running' and ipr.basis ->> 'tier' = 'flex' then
            coalesce((ipr.basis ->> 'unmet_pay_cents')::int, 0) + coalesce((ipr.basis ->> 'standby_cents')::int, 0)
          when ipr.basis ->> 'outcome' = 'not_running' and ipr.basis ->> 'tier' = 'core' then
            case when ipr.basis ->> 'holding_model' = 'flat' then (ipr.basis ->> 'holding_flat_cents')::int
                 else ((ipr.basis ->> 'base_cents')::int * coalesce((ipr.basis ->> 'holding_pct')::int, 0)) / 100 end
          end as expected) x
     where ipr.studio_id = p_studio_id and ipr.type = 'class'
       and x.expected is not null and x.expected <> ipr.amount_cents
    union all
    -- 12b. Decision 108 (b): a pay line on a decided class whose amount differs
    -- from 75 (l). Lines changed by an authorised write are left alone.
    select coalesce((select display_name from instructors where id = ipr.instructor_id), 'An instructor')
           || ': the pay line for ' || coalesce(cname(ipr.occurrence_id), 'a class') || ' is '
           || money_txt(ipr.amount_cents, ipr.currency)
           || case when x.expected = 0 and o.status = 'cancelled'
                   then ' but the class did not run and pays nothing'
                   else ' but the rules give ' || money_txt(x.expected, ipr.currency) end
      from instructor_pay_records ipr
      join pay_periods pp on pp.id = ipr.period_id and pp.status = 'open'
      join class_occurrences o on o.id = ipr.occurrence_id
      cross join lateral (select (compute_class_pay_run(o.id) ->> 'amount_cents')::int as expected) x
     where ipr.studio_id = p_studio_id and ipr.type = 'class'
       and (o.status = 'cancelled' or o.attendance_finalised_at is not null)
       and x.expected is not null and x.expected <> ipr.amount_cents
       and not exists (select 1 from audit_logs a where a.entity_id = ipr.id
                        and a.action in ('pay.line_voided','pay.line_corrected','pay.line_restored'))
    union all
    -- 13. Decision 103 (j): a free first class seat past its deadline that was
    -- kept because its due email was never sent.
    select mname(b.member_id) || ': ' || cname(b.occurrence_id)
           || ' was kept because the pay-to-keep email never reached them'
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
      join studio_settings st on st.studio_id = b.studio_id
      join members mb on mb.id = b.member_id
     where b.studio_id = p_studio_id and b.status = 'booked' and b.payment_source = 'comp'
       and o.starts_at > now() - interval '1 day'
       and not coalesce(b.reservation_credit_covered, false)
       and mb.reservation_fee_waived_at is null and not coalesce(b.reservation_fee_waived, false)
       and coalesce(st.free_first_reservation_fee_cents, 0) > 0
       and st.free_first_reservation_from is not null
       and o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)) <= now()
       and exists (select 1 from guest_passes gp where gp.guest_booking_id = b.id and gp.host_member_id is null)
       and not exists (select 1 from payments p where p.booking_id = b.id
                        and p.kind = 'reservation_fee' and p.status in ('succeeded','partially_refunded'))
       and exists (select 1 from notifications n
                    where n.dedupe_key = 'free_reservation_due:' || b.id
                       or n.dedupe_key like 'free_reservation_due:' || b.id || ':%')
       and not free_due_sent(b.id, o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)))
    union all
    -- 14. Decision 108 (b): a class that ran with no pay line.
    select coalesce(cname(o.id), 'A class') || ' ran with no pay line'
      from class_occurrences o
      join studio_settings st on st.studio_id = o.studio_id
     where o.studio_id = p_studio_id and o.status = 'scheduled' and o.instructor_id is not null
       and (coalesce(st.guarantees_enabled, false) or coalesce(st.flex_enabled, false))
       and o.ends_at < now() - interval '1 hour' and o.starts_at > now() - interval '14 days'
       and not exists (select 1 from instructor_pay_records ipr2 where ipr2.occurrence_id = o.id)
    union all
    -- 15. Decision 108 (b): an always-runs class past its start never committed.
    select coalesce(cname(o.id), 'An always-runs class') || ' started and was never committed'
      from class_occurrences o
      cross join lateral occurrence_guarantee_run(o.id) g
     where o.studio_id = p_studio_id and o.status = 'scheduled' and g.tier = 'always'
       and o.committed_at is null
       and o.starts_at < now() - interval '30 minutes' and o.starts_at > now() - interval '14 days'
    union all
    -- 16. Decision 108 (b): a pay line held for more than 3 days.
    select coalesce((select display_name from instructors where id = ipr.instructor_id), 'An instructor')
           || ': the pay line for ' || coalesce(cname(ipr.occurrence_id), 'a class') || ' has been held for '
           || extract(day from now() - ipr.created_at)::int || ' days'
      from instructor_pay_records ipr
      join pay_periods pp on pp.id = ipr.period_id and pp.status = 'open'
     where ipr.studio_id = p_studio_id and ipr.confirmed_at is null
       and ipr.created_at < now() - interval '3 days'
  loop
    -- Decision 108 (b): one null line must never wipe the list.
    v_line := coalesce(r.line, 'An item with a missing name');
    v_items := v_items || to_jsonb(v_line);
    v_html  := v_html  || '<li>' || replace(replace(v_line, '&', '&amp;'), '<', '&lt;') || '</li>';
    v_text  := v_text  || '- ' || v_line || E'\n';
  end loop;

  v_n := jsonb_array_length(v_items);
  return jsonb_build_object(
    'n', v_n,
    'all_clear', v_n = 0,
    'items', v_items,
    'items_html', case when v_n = 0 then '<p>All clear.</p>' else '<ul>' || v_html || '</ul>' end,
    'items_text', case when v_n = 0 then 'All clear.' else v_text end,
    'count_label', case when v_n = 0 then 'all clear'
                        else v_n::text || ' item' || case when v_n = 1 then '' else 's' end end);
end $function$;

do $$
declare v_n int;
begin
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'expect\_%';
  if v_n <> 14 then
    raise exception 'anon surface is %, expected exactly fourteen', v_n;
  end if;
end $$;
