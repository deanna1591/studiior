-- =============================================================================
-- 160  Decision 32: the paid headcount is greatest(booked_at_cutoff,
--      booked_at_start), amending Decision 22.
-- =============================================================================
-- Decision 22 computes per-head pay and the full-house bonus from
-- booked_at_cutoff alone — the count snapshotted when the class committed. But
-- the booking cutoff sits CLOSER to start than the 12h pay cutoff, so a member
-- can book after the pay cutoff and attend, adding a body the pay record never
-- saw; on a nearly-full class that member can take the last seat and never
-- trigger the full-house bonus the instructor earned by teaching a full room.
--
-- The amendment: per-head pay and the full-house bonus use
--   greatest(booked_at_cutoff, booked_at_start).
-- It keeps Decision 22 intact — pay is from bookings, never attendance; a
-- no-show keeps their seat and counts; committed_at stays terminal and stays
-- stamped at the cutoff — and adds two guarantees: the instructor never earns
-- LESS than the cutoff promised (greatest only raises), and a late cancel after
-- the cutoff cannot reduce pay (a lower start count loses to the cutoff).
--
-- WHERE IT IS WRITTEN, AND WHY THE SNAPSHOT IS NEEDED. For core/flex the pay
-- record is written at the cutoff, BEFORE start, so booked_at_start does not
-- exist at write time. sweep_commitments — the same 15-min job that already
-- commits `always` classes at their start — stamps booked_at_start at start and
-- trues up the OPEN-period record from the greater-of. A CLOSED period is never
-- re-touched (it is already paid): the difference is written as an adjustment in
-- the next open period, Decision 22's existing correction mechanism. `always`
-- needs no snapshot — it commits at start, so its booked_at_cutoff is already
-- the start count.
--
-- THIS IS A COMPUTE CHANGE, NOT A RATE CHANGE. The rates (base, per-head,
-- threshold, full-house) are unchanged; only the headcount fed to the formula
-- moves. No new instructor_rate_versions row. compute_class_pay_run is re-issued
-- (create-or-replace, ACL kept). Existing closed-period records stay exactly as
-- computed — they were the old promise, already paid.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- The start snapshot column
-- -----------------------------------------------------------------------------
alter table class_occurrences
  add column if not exists booked_at_start int;

comment on column class_occurrences.booked_at_start is
  'Booked count snapshotted AT the class start, counting the same statuses as '
  'the cutoff snapshot (booked/attended/no_show/pending_payment). Decision 32: '
  'per-head pay and the full-house bonus use greatest(booked_at_cutoff, '
  'booked_at_start). Stamped once by sweep_commitments; null until start.';

-- -----------------------------------------------------------------------------
-- compute_class_pay_run: the RAN group branch pays on the greater-of count.
-- Re-issued from migration 138's body with two changes, both in that branch:
-- v_heads is greatest(cutoff, start), and the basis records both counts and the
-- count actually paid. Every other branch is byte-for-byte 138. create-or-
-- replace keeps its ACL.
-- -----------------------------------------------------------------------------
create or replace function compute_class_pay_run(p_occurrence_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
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

  select * into g from occurrence_guarantee(p_occurrence_id);
  -- DECISION 32: the greater of the cutoff count and the start count. When the
  -- start snapshot has not been taken (not yet started, or an `always` class
  -- whose cutoff count already IS the start count) booked_at_start is null and
  -- the greatest collapses to the cutoff — so nothing changes until a real late
  -- booker moves the start count above it.
  v_heads := greatest(coalesce(o.booked_at_cutoff, 0), coalesce(o.booked_at_start, 0));

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
                  + case when occurrence_is_adjacent(p_occurrence_id)
                         then 0 else coalesce(s.flex_standby_pay_cents, 0) end;
        v_basis := jsonb_build_object('kind', 'group', 'outcome', 'not_running',
          'tier', 'flex', 'unmet_pay_cents', coalesce(s.flex_unmet_pay_cents, 0),
          'standby_cents', case when occurrence_is_adjacent(p_occurrence_id)
                                then 0 else coalesce(s.flex_standby_pay_cents, 0) end,
          'adjacent', occurrence_is_adjacent(p_occurrence_id));
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
end $$;

-- -----------------------------------------------------------------------------
-- snapshot_start_headcount: stamp booked_at_start at start and true up the pay.
-- -----------------------------------------------------------------------------
-- INTERNAL. Called by sweep_commitments (service context) and by nobody a client
-- can be — the grant is the boundary. It is idempotent per occurrence
-- (booked_at_start null is the gate), and the true-up can only ever RAISE the
-- amount, because greatest() is monotonic in the start count.
create or replace function snapshot_start_headcount(p_occurrence_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  o class_occurrences%rowtype; v_start int; v_rec instructor_pay_records%rowtype;
  c jsonb; v_new int; v_delta int; p pay_periods%rowtype; v_id uuid;
begin
  select * into o from class_occurrences where id = p_occurrence_id for update;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not is_service_context() and not coalesce(is_manager_up(o.studio_id), false) then
    raise exception 'the start snapshot is a background job' using errcode = 'PT403';
  end if;

  -- Idempotent: stamped once.
  if o.booked_at_start is not null then
    return jsonb_build_object('ok', true, 'already', 'snapshotted',
                              'booked_at_start', o.booked_at_start);
  end if;
  if o.starts_at > now() then
    return jsonb_build_object('ok', true, 'skipped', 'not started');
  end if;
  -- Only a committed, still-scheduled class trues up on headcount. A not_running
  -- or otherwise cancelled class is paid by its cancellation rule, not a count.
  if o.committed_at is null or o.status <> 'scheduled' then
    return jsonb_build_object('ok', true, 'skipped', 'not a committed running class');
  end if;

  -- THE SAME statuses evaluate_commitment counts, written the same way, so the
  -- cutoff snapshot and the start snapshot can never disagree about a body.
  select count(*)::int into v_start from bookings
   where occurrence_id = p_occurrence_id
     and status in ('booked','attended','no_show','pending_payment');

  update class_occurrences set booked_at_start = v_start, updated_at = now()
   where id = p_occurrence_id;

  -- Nothing to true up unless a class pay record was written at the cutoff
  -- (payroll off, or no rate on file, leaves none — and there is nothing owed).
  select * into v_rec from instructor_pay_records
   where occurrence_id = p_occurrence_id and type = 'class';
  if not found then
    return jsonb_build_object('ok', true, 'booked_at_start', v_start, 'record', 'none');
  end if;

  -- Recompute now that booked_at_start is stamped: greatest(cutoff, start).
  c := compute_class_pay_run(p_occurrence_id);
  if not (c ->> 'ok')::boolean then
    return jsonb_build_object('ok', true, 'booked_at_start', v_start, 'recompute', c);
  end if;
  v_new := (c ->> 'amount_cents')::int;
  v_delta := v_new - v_rec.amount_cents;

  select * into p from pay_periods where id = v_rec.period_id;

  -- greatest() can only raise, never lower; a late cancel picks the cutoff. When
  -- the count moved but the money did not (still below the per-head threshold),
  -- fold the start count into the basis so the statement can show it — but only
  -- while the period is open (a closed one is immutable and already paid).
  if v_delta <= 0 then
    if p.status = 'open' then
      update instructor_pay_records set basis = c -> 'basis' where id = v_rec.id;
    end if;
    return jsonb_build_object('ok', true, 'booked_at_start', v_start,
      'booked_at_cutoff', coalesce(o.booked_at_cutoff, 0), 'delta_cents', 0);
  end if;

  if p.status = 'open' then
    -- Same open period: raise the amount in place and record what it now rests on.
    update instructor_pay_records
       set amount_cents = v_new, basis = c -> 'basis'
     where id = v_rec.id;
    return jsonb_build_object('ok', true, 'booked_at_start', v_start,
      'trued_up', 'in_place', 'delta_cents', v_delta, 'amount_cents', v_new);
  end if;

  -- The period is CLOSED — already paid, and immutable at the trigger. Decision
  -- 22's correction mechanism: the difference is an adjustment in the next open
  -- period, naming the class and why. Idempotent — one true-up adjustment ever.
  if exists (select 1 from instructor_pay_records
              where type = 'adjustment' and basis ->> 'true_up_of' = p_occurrence_id::text) then
    return jsonb_build_object('ok', true, 'booked_at_start', v_start,
      'trued_up', 'already_adjusted');
  end if;
  p := next_open_pay_period(o.studio_id);
  insert into instructor_pay_records (
    studio_id, instructor_id, period_id, type, amount_cents, currency,
    rate_version_id, basis, note, created_by)
  values (o.studio_id, o.instructor_id, p.id, 'adjustment', v_delta, (c ->> 'currency'),
          (c ->> 'rate_version_id')::uuid,
          jsonb_build_object('true_up_of', p_occurrence_id, 'original_period', v_rec.period_id,
            'booked_at_cutoff', coalesce(o.booked_at_cutoff, 0), 'booked_at_start', v_start,
            'reason', 'late bookings after cutoff'),
          o.name || ': late bookings after cutoff', auth.uid())
  returning id into v_id;
  return jsonb_build_object('ok', true, 'booked_at_start', v_start,
    'trued_up', 'adjustment', 'adjustment_id', v_id, 'delta_cents', v_delta);
end $$;

revoke execute on function snapshot_start_headcount(uuid) from public, anon, authenticated;
grant  execute on function snapshot_start_headcount(uuid) to service_role;

-- -----------------------------------------------------------------------------
-- sweep_commitments: re-issued from migration 081's body, byte-for-byte, with
-- one added pass per studio — the start snapshot for committed classes that have
-- started. Everything else is unchanged. create-or-replace keeps its ACL.
-- -----------------------------------------------------------------------------
create or replace function sweep_commitments()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  st record; r record; d record; v_job uuid; v_tz text;
  n_comm int := 0; n_not int := 0; n_studios int := 0; n_told int := 0; n_start int := 0;
  v_res jsonb; v_user uuid; v_key text;
  v_lines text; v_intro text; v_close text; v_summary text;
  v_n_comm int; v_n_not int;
begin
  if not is_service_context() then
    raise exception 'the commitment sweep is a background job' using errcode = 'PT403';
  end if;

  for st in
    select s.id, s.name, s.timezone
      from studios s
      join studio_settings cfg on cfg.studio_id = s.id
     where s.status = 'active'
       and (coalesce(cfg.guarantees_enabled, false) or coalesce(cfg.flex_enabled, false))
     order by s.id
  loop
    n_studios := n_studios + 1;
    v_tz := st.timezone;

    -- job_runs RECORDS the pass and counts attempts. It does not gate it: core's
    -- cutoff is a rolling offset, so there is a decision point at every hour of
    -- the day, and a once-a-day claim would answer only the first of them. The
    -- idempotency is each occurrence's own state.
    insert into job_runs (job_key, run_for, status)
    values ('commitments:' || st.id, (now() at time zone v_tz)::date, 'running')
    on conflict (job_key, run_for) do update
       set attempts = job_runs.attempts + 1, started_at = now(), status = 'running'
    returning id into v_job;

    -- What this pass decided, per instructor, so the notification can be one
    -- message rather than one per class.
    create temporary table if not exists _decided (
      instructor_id uuid, user_id uuid, occ_id uuid, occ_name text,
      local_when text, decision text, booked int, minimum int, tier text
    ) on commit drop;
    delete from _decided;

    for r in select * from commitment_pending(st.id) where past_due loop
      v_res := evaluate_commitment(r.occ_id);
      if v_res ? 'decision' then
        if v_res ->> 'decision' = 'committed' then n_comm := n_comm + 1;
        else n_not := n_not + 1; end if;
        insert into _decided values (
          r.instructor_id, instructor_user_id(r.instructor_id), r.occ_id, r.occ_name,
          r.local_when, v_res ->> 'decision',
          (v_res ->> 'booked_at_cutoff')::int, r.minimum, r.tier::text);
      end if;
    end loop;

    -- One digest per instructor who has a login. An instructor with none comes
    -- out null and is simply not queued — two of three seeded instructors have
    -- no login and that is the ordinary case, not an edge.
    for d in
      select user_id,
             (select display_name from instructors i where i.id = _d.instructor_id) as name,
             count(*) filter (where decision = 'committed') as n_comm,
             count(*) filter (where decision = 'not_running') as n_not,
             string_agg(
               case when decision = 'committed'
                 then '  RUNNING   ' || occ_name || ' — ' || local_when
                      || ' (' || booked || ' booked)'
                 else '  NOT ON    ' || occ_name || ' — ' || local_when
                      || ' (needed ' || minimum || ', had ' || booked || ')'
               end, E'\n' order by local_when) as lines,
             md5(string_agg(occ_id::text, ',' order by occ_id)) as fingerprint
        from _decided _d
       where user_id is not null
       group by user_id, _d.instructor_id
    loop
      v_n_comm := d.n_comm; v_n_not := d.n_not;
      v_summary := case
        when v_n_not = 0 then v_n_comm || ' running'
        when v_n_comm = 0 then v_n_not || ' not going ahead'
        else v_n_comm || ' running, ' || v_n_not || ' not' end;
      v_intro := case
        when v_n_not = 0 then 'Everything below has the numbers and is going ahead.'
        when v_n_comm = 0 then 'These did not reach their minimum by the cutoff, so they are off.'
        else 'Here is where your classes landed at their cutoff.' end;
      v_close := case
        when v_n_not = 0 then 'See you there,'
        else 'You do not need to come in for anything marked NOT ON.' end;

      -- DEDUPED ON THE SET, not on the day. A retry decides nothing and sends
      -- nothing; a genuinely later batch contains different classes and so
      -- carries a different key and does send. Keying on the instructor and the
      -- date would suppress the second, which is the mistake migration 073's
      -- resend already made once.
      v_key := 'commitment_digest:' || d.fingerprint;
      if queue_shift_notice(st.id, d.user_id, 'commitment_digest',
           jsonb_build_object('instructor_name', coalesce(d.name, 'there'),
             'studio_name', st.name, 'summary_line', v_summary,
             'intro_line', v_intro, 'lines', d.lines, 'closing_line', v_close),
           v_key) is not null
      then n_told := n_told + 1; end if;
    end loop;

    -- DECISION 32: true up committed classes that have started. A late booker
    -- after the pay cutoff adds a body the commit snapshot never saw; the
    -- greater-of pays for them. Stamped once (booked_at_start null is the gate),
    -- so a re-run is a no-op. `always` classes match too and cost nothing — their
    -- cutoff count already IS the start count, so the delta is zero.
    for r in
      select o.id
        from class_occurrences o
       where o.studio_id = st.id
         and o.status = 'scheduled'
         and o.committed_at is not null
         and o.booked_at_start is null
         and o.starts_at <= now()
    loop
      perform snapshot_start_headcount(r.id);
      n_start := n_start + 1;
    end loop;

    update job_runs set status = 'done', finished_at = now(), error = null where id = v_job;
  end loop;

  return jsonb_build_object('studios', n_studios, 'committed', n_comm,
                            'not_running', n_not, 'instructors_told', n_told,
                            'start_snapshots', n_start);
end $$;

revoke execute on function sweep_commitments() from public, anon, authenticated;
grant  execute on function sweep_commitments() to service_role;

-- -----------------------------------------------------------------------------
-- pay_statement and pay_period_export: the line carries a note when the start
-- count raised the amount. Read from the record's basis, so the statement and
-- the CSV agree line for line. Re-issued from migration 159's bodies with the
-- one added field; guards, totals and settle date unchanged. ACL kept.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pay_statement(p_instructor_id uuid, p_period_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  p pay_periods%rowtype; v_studio uuid; v_tz text; v_name text; v_cur char(3);
  v_lines jsonb; v_sub jsonb; v_total bigint; v_self boolean; v_conf bigint; v_held bigint;
  v_settle_dow int; v_settle_offset int;
begin
  select * into p from pay_periods where id = p_period_id;
  if not found then raise exception 'no such period' using errcode = 'PT404'; end if;
  v_studio := p.studio_id;

  select exists (select 1 from instructors i join studio_staff ss on ss.id = i.staff_id
                  where i.id = p_instructor_id and ss.user_id = auth.uid())
    into v_self;
  if not coalesce(is_manager_up(v_studio), false) and not coalesce(v_self, false) then
    raise exception 'that is not your statement' using errcode = 'PT403';
  end if;

  select timezone, currency into v_tz, v_cur from studios where id = v_studio;
  select pay_settle_dow, pay_settle_offset_days into v_settle_dow, v_settle_offset
    from studio_settings where studio_id = v_studio;
  select display_name into v_name from instructors where id = p_instructor_id;

  select jsonb_agg(l order by l ->> 'sort'), coalesce(sum(amt), 0)
    into v_lines, v_total
  from (
    select
      jsonb_build_object(
        'sort', coalesce(to_char(o.starts_at at time zone v_tz, 'YYYY-MM-DD HH24:MI'),
                         to_char(r.created_at at time zone v_tz, 'YYYY-MM-DD HH24:MI')),
        'type', r.type,
        'date', coalesce(to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMon'),
                         to_char(r.created_at at time zone v_tz, 'FMDay FMDD FMMon')),
        'time', to_char(o.starts_at at time zone v_tz, 'HH24:MI'),
        'name', case r.type
                  when 'class' then o.name
                  when 'conversion' then 'Conversion — ' || coalesce(r.basis ->> 'member_name', 'a member')
                                          || ' (' || coalesce(r.basis ->> 'plan_name', 'a plan') || ')'
                  else coalesce(r.note, 'Adjustment') end,
        'status', case
                    when r.type <> 'class' then null
                    when o.status <> 'cancelled' then 'ran'
                    when o.cancellation_cause = 'unmet_minimum' then 'did not run'
                    else 'cancelled — ' || o.cancellation_cause::text end,
        'headcount', case when r.type = 'class' then o.booked_at_cutoff end,
        -- DECISION 32: say so when a late booker after the cutoff raised the pay.
        'headcount_note', case
            when (r.basis ->> 'booked_at_start') is not null
             and (r.basis ->> 'booked_at_start')::int
                 > coalesce((r.basis ->> 'booked_at_cutoff')::int, 0)
            then coalesce(r.basis ->> 'booked_at_cutoff', '0') || ' at cutoff, '
                 || (r.basis ->> 'booked_at_start') || ' at start'
            when r.type = 'adjustment' and (r.basis ->> 'true_up_of') is not null
            then coalesce(r.basis ->> 'booked_at_cutoff', '0') || ' at cutoff, '
                 || coalesce(r.basis ->> 'booked_at_start', '0') || ' at start'
            else null end,
        'capacity',  case when r.type = 'class' then o.capacity end,
        'amount_cents', r.amount_cents,
        'confirmed', r.confirmed_at is not null,
        'payable', r.type <> 'class' or r.confirmed_at is not null,
        'basis', r.basis) as l,
      r.amount_cents as amt
      from instructor_pay_records r
      left join class_occurrences o on o.id = r.occurrence_id
     where r.instructor_id = p_instructor_id and r.period_id = p_period_id
  ) x;

  select coalesce(sum(amount_cents) filter (where type <> 'class' or confirmed_at is not null), 0),
         coalesce(sum(amount_cents) filter (where type = 'class' and confirmed_at is null), 0)
    into v_conf, v_held
    from instructor_pay_records where instructor_id = p_instructor_id and period_id = p_period_id;

  select jsonb_object_agg(t, s) into v_sub from (
    select type::text as t, sum(amount_cents) as s
      from instructor_pay_records
     where instructor_id = p_instructor_id and period_id = p_period_id
     group by type) y;

  return jsonb_build_object('ok', true,
    'instructor_id', p_instructor_id, 'instructor_name', v_name,
    'period_id', p.id, 'starts_on', p.starts_on, 'ends_on', p.ends_on,
    'status', p.status, 'currency', v_cur,
    'settle_on', pay_settle_on(p.ends_on, v_settle_dow, v_settle_offset),
    'lines', coalesce(v_lines, '[]'::jsonb),
    'subtotals', coalesce(v_sub, '{}'::jsonb),
    'total_cents', v_total,
    'confirmed_cents', v_conf, 'held_cents', v_held);
end $function$;

create or replace function pay_period_export(p_period_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare pr pay_periods%rowtype; v_tz text; v_cur char(3); v_rows jsonb; v_sum jsonb;
        v_settle_dow int; v_settle_offset int;
begin
  select * into pr from pay_periods where id = p_period_id;
  if not found then raise exception 'no such period' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(pr.studio_id), false) then
    raise exception 'only owners and managers export payroll' using errcode = 'PT403';
  end if;
  select timezone, currency into v_tz, v_cur from studios where id = pr.studio_id;
  select pay_settle_dow, pay_settle_offset_days into v_settle_dow, v_settle_offset
    from studio_settings where studio_id = pr.studio_id;

  select jsonb_agg(l order by l ->> 'instructor_name', l ->> 'sort') into v_rows from (
    select jsonb_build_object(
      'instructor_id', r.instructor_id,
      'instructor_name', i.display_name,
      'sort', coalesce(to_char(o.starts_at at time zone v_tz, 'YYYY-MM-DD HH24:MI'),
                       to_char(r.created_at at time zone v_tz, 'YYYY-MM-DD HH24:MI')),
      'date', to_char(coalesce(o.starts_at, r.created_at) at time zone v_tz, 'YYYY-MM-DD'),
      'time', to_char(o.starts_at at time zone v_tz, 'HH24:MI'),
      'name', case r.type
                when 'class' then o.name
                when 'conversion' then 'Conversion — ' || coalesce(r.basis ->> 'member_name', 'a member')
                else coalesce(r.note, 'Adjustment') end,
      'status', case
                  when r.type <> 'class' then null
                  when o.status <> 'cancelled' then 'ran'
                  when o.cancellation_cause = 'unmet_minimum' then 'did not run'
                  else 'cancelled — ' || o.cancellation_cause::text end,
      'headcount', case when r.type = 'class' then o.booked_at_cutoff end,
      -- DECISION 32: identical note to pay_statement, from the same basis.
      'headcount_note', case
          when (r.basis ->> 'booked_at_start') is not null
           and (r.basis ->> 'booked_at_start')::int
               > coalesce((r.basis ->> 'booked_at_cutoff')::int, 0)
          then coalesce(r.basis ->> 'booked_at_cutoff', '0') || ' at cutoff, '
               || (r.basis ->> 'booked_at_start') || ' at start'
          when r.type = 'adjustment' and (r.basis ->> 'true_up_of') is not null
          then coalesce(r.basis ->> 'booked_at_cutoff', '0') || ' at cutoff, '
               || coalesce(r.basis ->> 'booked_at_start', '0') || ' at start'
          else null end,
      'rate_version_id', r.rate_version_id,
      'amount_cents', r.amount_cents,
      'category', case r.type
                    when 'conversion' then 'bonus'
                    when 'adjustment' then 'adjustment'
                    else case when o.status <> 'cancelled' then 'taught'
                              when o.cancellation_cause = 'unmet_minimum' then 'not run'
                              else 'cancelled' end end,
      'confirmed', r.confirmed_at is not null) as l
      from instructor_pay_records r
      join instructors i on i.id = r.instructor_id
      left join class_occurrences o on o.id = r.occurrence_id
     where r.period_id = p_period_id) x;

  select jsonb_agg(s order by s ->> 'instructor_name') into v_sum from (
    select jsonb_build_object('instructor_id', r.instructor_id, 'instructor_name', i.display_name,
      'total_cents', sum(r.amount_cents),
      'held_cents', coalesce(sum(r.amount_cents) filter (where r.type='class' and r.confirmed_at is null), 0)) as s
      from instructor_pay_records r join instructors i on i.id = r.instructor_id
     where r.period_id = p_period_id group by r.instructor_id, i.display_name) y;

  return jsonb_build_object('ok', true, 'period_id', pr.id,
    'starts_on', pr.starts_on, 'ends_on', pr.ends_on, 'status', pr.status, 'currency', v_cur,
    'settle_on', pay_settle_on(pr.ends_on, v_settle_dow, v_settle_offset),
    'rows', coalesce(v_rows, '[]'::jsonb), 'summary', coalesce(v_sum, '[]'::jsonb));
end $$;
