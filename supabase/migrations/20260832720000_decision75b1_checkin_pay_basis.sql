-- =============================================================================
-- Decision 75b-1 (g) — CHECKED-IN PAY BASIS at finalisation.
-- =============================================================================
-- Decision 75(d)/(g): a class that ran is paid on CHECKED-IN heads, decided at
-- finalisation. The pay line is still written at commit on today's basis
-- (greatest(booked_at_cutoff, booked_at_start), Decisions 32/72) and trued up
-- ONCE MORE at finalisation on checked-in heads, reusing snapshot_start_headcount's
-- open-in-place / closed-adjustment tail exactly, idempotent on basis->>'finalise_of'.
--
-- When finalise_attendance is OFF for a studio the basis stays the booked one —
-- pay-on-checked-in is the behaviour of finalisation ON, never a silent cut.
--
-- compute_class_pay_run gains an optional p_heads override rather than a fork, so
-- every existing caller (record_class_pay, snapshot_start_headcount) is
-- byte-for-byte unchanged (null => today's basis). Only ran/committed GROUP
-- classes are trued up — unmet_minimum, cancelled, and private/duo/trio flat
-- lines are untouched. At finalisation the pay row's instructor_id is re-copied
-- from the occurrence, so an accepted cover is paid for the class they taught.
-- No new anon RPC — the anon surface stays EXACTLY THIRTEEN.
-- =============================================================================

-- creates: finalise_pay_true_up(uuid)
-- re-issues: compute_class_pay_run(uuid, int), finalise_attendance_sweep()

-- -----------------------------------------------------------------------------
-- 1. compute_class_pay_run gains p_heads (adding a param = overload, so the
--    1-arg form is DROPPED first and the ACL re-asserted — the 028 trap). Every
--    1-arg caller resolves to the default (null => today's basis).
-- -----------------------------------------------------------------------------
drop function if exists compute_class_pay_run(uuid);

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

-- -----------------------------------------------------------------------------
-- 2. finalise_pay_true_up — the once-more true-up at finalisation on checked-in
--    heads. Mirrors snapshot_start_headcount's tail: in place while the period
--    is open, an adjustment in next_open_pay_period when closed, idempotent on
--    basis->>'finalise_of'. Service-role only (the sweep calls it; a manager may
--    too). UNLIKE the start snapshot it may LOWER pay — 6 booked, 4 checked in
--    pays 4 — because checked-in IS the basis once finalisation is on.
-- -----------------------------------------------------------------------------
create or replace function finalise_pay_true_up(p_occurrence_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  o class_occurrences%rowtype; v_rec instructor_pay_records%rowtype;
  s studio_settings%rowtype; v_kind session_kind; c jsonb;
  v_heads int; v_new int; v_delta int; p pay_periods%rowtype; v_id uuid;
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

  -- Checked-in heads: the authoritative record is check_ins, not booking status.
  select count(distinct member_id)::int into v_heads
    from check_ins where occurrence_id = p_occurrence_id;

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
    -- line now rests on so the statement can say "M checked in".
    update instructor_pay_records
       set amount_cents  = v_new,
           instructor_id = o.instructor_id,
           basis = (c -> 'basis')
                   || jsonb_build_object('finalise_of', p_occurrence_id,
                                         'checked_in', v_heads,
                                         'finalised_at', now())
     where id = v_rec.id;
    return jsonb_build_object('ok', true, 'trued_up', 'in_place',
      'checked_in', v_heads, 'delta_cents', v_delta, 'amount_cents', v_new);
  end if;

  -- The period is CLOSED — immutable, already paid. The difference goes in the
  -- next open period as an adjustment (signed; it may claw back), naming the
  -- class and the period it came from so the statement can label it "from the
  -- previous period". delta 0 needs no adjustment.
  if v_delta = 0 then
    return jsonb_build_object('ok', true, 'closed', true, 'checked_in', v_heads, 'delta_cents', 0);
  end if;
  p := next_open_pay_period(o.studio_id);
  insert into instructor_pay_records (
    studio_id, instructor_id, period_id, type, amount_cents, currency,
    rate_version_id, basis, note, created_by)
  values (o.studio_id, o.instructor_id, p.id, 'adjustment', v_delta, (c ->> 'currency'),
          (c ->> 'rate_version_id')::uuid,
          jsonb_build_object('finalise_of', p_occurrence_id, 'original_period', v_rec.period_id,
            'checked_in', v_heads, 'booked_at_cutoff', coalesce(o.booked_at_cutoff, 0),
            'reason', 'attendance correction'),
          o.name || ': attendance correction (from the previous period)', auth.uid())
  returning id into v_id;
  return jsonb_build_object('ok', true, 'trued_up', 'adjustment',
    'adjustment_id', v_id, 'checked_in', v_heads, 'delta_cents', v_delta);
end $$;

revoke execute on function finalise_pay_true_up(uuid) from public, anon, authenticated;
grant  execute on function finalise_pay_true_up(uuid) to service_role;

-- -----------------------------------------------------------------------------
-- 3. finalise_attendance_sweep — re-issued from 75b-1(f)'s body, adding ONE
--    call: after stamping attendance_finalised_at, true up the pay line on
--    checked-in heads. finalise_pay_true_up self-guards (off / not-committed /
--    flat / no record), so calling it per occurrence is safe. create-or-replace
--    keeps the ACL (service-role only).
-- -----------------------------------------------------------------------------
create or replace function finalise_attendance_sweep()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_marked int := 0; v_occs int := 0; r record; v_n int; v_tz text; v_fname text; v_when text; v_morning timestamptz;
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

    update bookings set status = 'no_show', no_show_at = now(), no_show_by = null, updated_at = now()
     where occurrence_id = r.id and status = 'booked';
    get diagnostics v_n = row_count;

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
revoke execute on function finalise_attendance_sweep() from public, anon, authenticated;
grant  execute on function finalise_attendance_sweep() to service_role;
