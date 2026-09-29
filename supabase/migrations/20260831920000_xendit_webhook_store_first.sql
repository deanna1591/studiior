-- Migration 187 — Xendit webhook: store the event BEFORE processing, so a
-- failure can never erase the evidence.
--
-- Amendment 9's PT403 (award_conversion_bonus_run calling the guarded
-- member_first_class) was invisible for days because xendit_webhook inserted the
-- xendit_events row AND processed in the same transaction: the raise rolled the
-- insert back, the route returned 500, and the table showed nothing had ever
-- arrived. Evidence must survive the failure.
--
-- Re-issued from the newest definition (20260831890000, the v3 amount read),
-- restructured so:
--   * the token check stays FIRST (PT401, nothing stored — unchanged);
--   * the event row is inserted, then all processing runs in an inner
--     BEGIN … EXCEPTION subtransaction. On any raise: the subtransaction rolls
--     back the (partial) processing only — the outer INSERT survives — and the
--     handler records result='failed', error=SQLERRM on the stored row and
--     RETURNS {result:'failed', error_code:SQLSTATE}. It never re-raises (a
--     re-raise would roll the insert back, which is the bug).
--   * a retry of a row whose stored result is 'failed' is NOT a duplicate — it
--     is reprocessed; only a non-failed stored result is a duplicate.
-- xendit_events gains a `result` column (processed / ignored / duplicate /
-- refused / failed). create or replace keeps the ACL; anon stays EXACTLY TWELVE.

alter table xendit_events add column if not exists result text;

create or replace function xendit_webhook(p_event jsonb, p_token text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  d jsonb := p_event -> 'data';
  v_event text := p_event ->> 'event';
  v_status text := upper(coalesce(d ->> 'status', ''));
  v_payment_id text := coalesce(nullif(d ->> 'payment_id', ''), nullif(d ->> 'id', ''));
  v_amount numeric := coalesce(
    nullif(d ->> 'amount', ''),
    nullif(d ->> 'request_amount', ''),
    nullif(d -> 'captures' -> 0 ->> 'capture_amount', '')
  )::numeric;
  v_currency text := upper(nullif(d ->> 'currency', ''));
  v_studio uuid;
  v_event_id text; n int; v_success boolean; v_failure boolean;
  v_pid uuid; p xendit_purchases%rowtype; v_prior text;
begin
  -- Token first: a bad token stores NOTHING (PT401).
  if p_token is null then
    raise exception 'bad Xendit callback token' using errcode = 'PT401';
  end if;
  select studio_id into v_studio from studio_payment_providers
   where provider = 'xendit'
     and callback_token_sha256 = encode(digest(p_token, 'sha256'), 'hex')
   limit 1;
  if v_studio is null then
    raise exception 'bad Xendit callback token' using errcode = 'PT401';
  end if;

  v_event_id := coalesce(nullif(v_event, ''), 'event') || ':'
             || coalesce(nullif(v_payment_id, ''), nullif(d ->> 'payment_session_id', ''),
                         nullif(p_event ->> 'id', ''), encode(digest(p_event::text, 'sha256'), 'hex'));

  -- STORE FIRST — the row exists (outer txn) before any processing, so a raise
  -- below cannot erase it. A retry of a FAILED row is reprocessed, not a dup.
  insert into xendit_events (studio_id, event_id, event_type, payload)
  values (v_studio, v_event_id, v_event, p_event)
  on conflict (event_id) do nothing;
  get diagnostics n = row_count;
  if n = 0 then
    select result into v_prior from xendit_events where event_id = v_event_id;
    if v_prior is distinct from 'failed' then
      return jsonb_build_object('result', 'duplicate');
    end if;
    -- a previously-failed row: fall through and reprocess it.
  end if;

  -- PROCESS in a subtransaction. A raise rolls back ONLY the processing (any
  -- partial activation and the purchase_id stamp); the handler then records the
  -- failure on the stored row and returns without re-raising.
  begin
    v_pid := xendit_resolve_purchase(d);
    if v_pid is null then
      update xendit_events set result = 'ignored', error = 'bad_reference', processed_at = now() where event_id = v_event_id;
      return jsonb_build_object('result', 'ignored', 'reason', 'bad_reference');
    end if;
    select * into p from xendit_purchases where id = v_pid;
    if p.studio_id <> v_studio then
      update xendit_events set result = 'ignored', error = 'cross_tenant', processed_at = now() where event_id = v_event_id;
      return jsonb_build_object('result', 'ignored', 'reason', 'cross_tenant');
    end if;
    update xendit_events set purchase_id = p.id where event_id = v_event_id;

    v_success := v_status in ('SUCCEEDED', 'COMPLETED') or v_event in ('payment.succeeded', 'payment.capture');
    v_failure := v_event = 'payment.failure' or v_status in ('FAILED', 'FAILURE', 'VOIDED', 'EXPIRED', 'CANCELED', 'CANCELLED');

    if v_success then
      if v_amount is not null and round(v_amount * 100) <> p.amount_cents then
        update xendit_events set result = 'refused', error = 'amount_mismatch', processed_at = now() where event_id = v_event_id;
        return jsonb_build_object('result', 'refused', 'reason', 'amount_mismatch');
      end if;
      if v_currency is not null and v_currency <> upper(p.currency) then
        update xendit_events set result = 'refused', error = 'currency_mismatch', processed_at = now() where event_id = v_event_id;
        return jsonb_build_object('result', 'refused', 'reason', 'currency_mismatch');
      end if;
      perform xendit_activate_success_internal(p.id, v_payment_id);
      update xendit_events set result = 'processed', error = null, processed_at = now() where event_id = v_event_id;
      return jsonb_build_object('result', 'processed', 'outcome', 'succeeded');

    elsif v_failure then
      perform xendit_fail_purchase_internal(p.id, 'failed', coalesce(d ->> 'failure_code', v_event));
      update xendit_events set result = 'processed', error = null, processed_at = now() where event_id = v_event_id;
      return jsonb_build_object('result', 'processed', 'outcome', 'failed');
    end if;

    update xendit_events set result = 'ignored', error = 'non_terminal', processed_at = now() where event_id = v_event_id;
    return jsonb_build_object('result', 'ignored', 'reason', 'non_terminal');

  exception when others then
    -- The row was inserted in the OUTER txn, so it survives this rollback; record
    -- WHY it failed and return (never re-raise). The route turns this into a 500
    -- so Xendit retries, and the retry reprocesses the stored 'failed' row.
    update xendit_events set result = 'failed', error = left(coalesce(SQLERRM, ''), 300), processed_at = now()
     where event_id = v_event_id;
    return jsonb_build_object('result', 'failed', 'error_code', SQLSTATE);
  end;
end $$;

revoke execute on function xendit_webhook(jsonb, text) from public;
grant  execute on function xendit_webhook(jsonb, text) to anon, authenticated, service_role;

-- The owner "Check pending payments" reprocess must also pick up result='failed'
-- rows (a failure leaves purchase_id null — the stamp is inside the rolled-back
-- subtransaction). On success it flips the row to result='processed'.
create or replace function xendit_reprocess_ignored(p_studio_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; v_id uuid; p xendit_purchases%rowtype; n int := 0; v_success boolean;
begin
  if not is_manager_up(p_studio_id) then
    raise exception 'that is not your studio' using errcode = 'PT403';
  end if;
  for r in
    select id, payload from xendit_events
     where studio_id = p_studio_id
       and (error in ('bad_reference', 'unknown_reference') or result = 'failed')
       and purchase_id is null
  loop
    v_id := xendit_resolve_purchase(r.payload -> 'data');
    if v_id is null then continue; end if;
    select * into p from xendit_purchases where id = v_id and studio_id = p_studio_id;
    if p.id is null then continue; end if;
    v_success := upper(coalesce(r.payload -> 'data' ->> 'status', '')) in ('SUCCEEDED', 'COMPLETED')
              or (r.payload ->> 'event') in ('payment.succeeded', 'payment.capture');
    if v_success and p.status <> 'succeeded' then
      perform xendit_activate_success_internal(p.id, r.payload -> 'data' ->> 'payment_id');
      update xendit_events set purchase_id = p.id, result = 'processed', error = null, processed_at = now() where id = r.id;
      n := n + 1;
    end if;
  end loop;
  return jsonb_build_object('reprocessed', n);
end $$;
revoke execute on function xendit_reprocess_ignored(uuid) from public, anon;
grant  execute on function xendit_reprocess_ignored(uuid) to authenticated, service_role;

-- The owner's Settings → Xendit screen shows the recent webhook events and, for
-- a failed one, WHY. xendit_events is closed to every client role (the token is
-- a credential and the payload is opaque), so a manager-up reader returns just
-- the safe columns — never the payload, never a secret. Read-only, no action.
create or replace function xendit_recent_events(p_studio_id uuid)
returns table(event_type text, result text, error text, received_at timestamptz, processed_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_manager_up(p_studio_id) then
    raise exception 'that is not your studio' using errcode = 'PT403';
  end if;
  return query
    select e.event_type, e.result, e.error, e.received_at, e.processed_at
      from xendit_events e
     where e.studio_id = p_studio_id
     order by e.received_at desc
     limit 20;
end $$;
revoke execute on function xendit_recent_events(uuid) from public, anon;
grant  execute on function xendit_recent_events(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Amendment-9 sweep (scripts/check-guarded-callers.sh): six internal/definer
-- functions called the GUARDED occurrence_guarantee / occurrence_is_adjacent /
-- compute_class_pay instead of the *_run internals. They pass today (every
-- caller reaches them as staff-of-the-studio or in a service context, so the
-- auth_staff_studios()/is_manager_up OR is_service_context guard is satisfied),
-- but that is the exact fragility amendment 9 was — a rename or a new anon path
-- would break them silently. Re-issued from their newest definitions with the
-- call pointed at the _run twin (identical data, no redundant guard). ACL kept.
-- ---------------------------------------------------------------------------

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
     and o.starts_at > now()
     -- 'always' is included: it commits at its start time. Only a class with no
     -- cutoff at all — a studio with both switches off — is out of scope.
     and g.cutoff_at is not null
     -- Decision 25: a draft month is not decided. Nobody can book a class in
     -- it, so a flex class evaluated there would be cancelled for want of the
     -- bookings it was never allowed to take.
     and occurrence_published(o.id)
   order by o.starts_at;
end $function$

;

CREATE OR REPLACE FUNCTION public.compute_class_pay_run(p_occurrence_id uuid)
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
end $function$

;

CREATE OR REPLACE FUNCTION public.evaluate_commitment(p_occurrence_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o class_occurrences%rowtype; g record; v_booked int;
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

  select count(*)::int into v_booked from bookings
   where occurrence_id = p_occurrence_id
     and status in ('booked','attended','no_show','pending_payment');

  -- THE LATCH. A flex class that ever reached its minimum runs, even if a
  -- member has since cancelled and the count is now below — because the
  -- instructor was told it was going ahead and turned their evening over to it.
  -- booked_at_cutoff stays the REAL count so pay is right: a class that
  -- committed with nobody left pays the holding rate, not a per-head sum.
  if v_booked >= g.minimum
     or (o.flex and o.flex_reached_minimum_at is not null) then
    update class_occurrences
       set committed_at = now(), booked_at_cutoff = v_booked, updated_at = now()
     where id = p_occurrence_id;
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

CREATE OR REPLACE FUNCTION public.instructor_week(p_instructor_id uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_studio uuid; v_tz text; v_rows jsonb; v_opens int; v_closes int; v_enforced boolean;
begin
  select i.studio_id into v_studio from instructors i where i.id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  if not (is_this_instructor(p_instructor_id) or is_manager_up(v_studio)) then
    raise exception 'that is somebody else''s week' using errcode = 'PT403';
  end if;
  select s.timezone into v_tz from studios s where s.id = v_studio;
  select coalesce(checkin_opens_minutes_before, 60), coalesce(checkin_closes_minutes_after, 30),
         coalesce(checkin_window_enforced, true)
    into v_opens, v_closes, v_enforced from studio_settings where studio_id = v_studio;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.starts_at), '[]'::jsonb)
    into v_rows from (
    select o.id as occurrence_id, o.name, o.starts_at, o.ends_at,
           (o.starts_at at time zone v_tz)::date as local_date,
           to_char(o.starts_at at time zone v_tz, 'HH24:MI') as local_start,
           to_char(o.ends_at   at time zone v_tz, 'HH24:MI') as local_end,
           r.name as room_name, o.capacity, o.booked_count, o.waitlist_count,
           o.status::text as status, o.cancellation_reason,
           o.cancellation_cause::text as cancellation_cause,
           o.flex, o.minimum_bookings, o.committed_at is not null as committed,
           -- occurrence_guarantee_run() RETURNS TABLE, not jsonb. It is readable
           -- by any staff of the studio, an instructor included, so this is a
           -- call-shape fix and not a permission one.
           (select g.tier::text from occurrence_guarantee_run(o.id) g) as tier,
           -- Confirmed for the week (migration 067) is a fact about the class,
           -- not about the instructor, so it travels with the row.
           o.instructor_confirmed_at is not null as confirmed,
           -- Decision 28: the instructor's own pay check-in (not the roster
           -- confirm above). Whether they have tapped, and whether the window
           -- is open right now so the tap is offered.
           o.instructor_checked_in_at is not null as checked_in,
           (not coalesce(v_enforced, true)
            or (now() >= o.starts_at - make_interval(mins => coalesce(v_opens,60))
                and now() <= o.ends_at + make_interval(mins => coalesce(v_closes,30)))) as checkin_open,
           exists (select 1 from cover_requests c
                    where c.occurrence_id = o.id and c.status = 'pending') as cover_requested
      from class_occurrences o
      left join rooms r on r.id = o.room_id
     where o.studio_id = v_studio and o.instructor_id = p_instructor_id
       and (o.starts_at at time zone v_tz)::date between p_from and p_to
       -- Decision 25: a draft month is not on their schedule.
       and month_published(v_studio, o.starts_at)) x;

  return jsonb_build_object(
    'from', p_from, 'to', p_to, 'timezone', v_tz, 'classes', v_rows,
    'state', case when jsonb_array_length(v_rows) = 0 then 'empty' else 'ok' end,
    'empty_hint', 'Nothing on this week. Classes you are down to teach appear here as soon as the studio schedules them, and open shifts you can apply for are under Shifts.');
end $function$

;

CREATE OR REPLACE FUNCTION public.record_class_pay(p_occurrence_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o class_occurrences%rowtype; c jsonb; p pay_periods%rowtype; v_id uuid; v_tz text;
  v_conf_at timestamptz; v_conf_by uuid; v_conf_method text;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(o.studio_id), false) and not is_service_context() then
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
    p := next_open_pay_period(o.studio_id);
    insert into instructor_pay_records (
      studio_id, instructor_id, period_id, type, occurrence_id, amount_cents,
      currency, rate_version_id, basis, note, created_by,
      confirmed_at, confirmed_by, confirm_method)
    values (o.studio_id, (c ->> 'instructor_id')::uuid, p.id, 'class',
            p_occurrence_id, (c ->> 'amount_cents')::int, c ->> 'currency',
            (c ->> 'rate_version_id')::uuid, c -> 'basis',
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
end $function$

;

CREATE OR REPLACE FUNCTION public.schedule_range(p_studio_id uuid, p_from date, p_to date)
 RETURNS TABLE(occ_id uuid, occ_name text, starts_at timestamp with time zone, ends_at timestamp with time zone, local_date date, local_start text, local_end text, start_minutes integer, end_minutes integer, occ_instructor_id uuid, room_name text, occ_capacity integer, occ_booked integer, occ_waitlist integer, occ_staffing text, occ_status text, occ_flex boolean, occ_confirmed boolean, occ_tier text, occ_standalone boolean, occ_series_tier text, occ_minimum integer, occ_cancellation_cause text, occ_assignment_requested boolean, occ_assignment_confirmed boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_tz text;
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
         -- Decision 38: the assigned-class confirmation state, for the calendar.
         o.assignment_requested_at is not null,
         o.assignment_confirmed_at is not null
    from class_occurrences o
    cross join lateral occurrence_guarantee_run(o.id) g
    left join class_series ser on ser.id = o.series_id
    left join rooms r on r.id = o.room_id
   where o.studio_id = p_studio_id
     and (o.status <> 'cancelled' or o.cancellation_cause = 'unmet_minimum')
     and (o.starts_at at time zone v_tz)::date between p_from and p_to
   order by o.starts_at;
end $function$

;

do $$
declare v_n int;
begin
  select count(*) into v_n from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
   where nsp.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if v_n <> 12 then raise exception 'anon surface is % functions, expected 12', v_n; end if;
end $$;
