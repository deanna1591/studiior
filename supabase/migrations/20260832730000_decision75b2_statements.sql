-- =============================================================================
-- Decision 75b-2 (h) period close with a button + (i) statements.
-- =============================================================================
-- pay_statement becomes the ONE statement source for both the instructor My Pay
-- page (period picker Open/Closed/Paid) and the staff per-instructor statement,
-- carrying everything so instructor_pay_summary can be retired from the page
-- (left in place, retire-later). close_pay_period returns its held-records
-- refusal as a reason (house style) instead of raising. record_class_pay's
-- straggler record gains basis.original_period so the statement can label a
-- line "from the previous period". No new anon RPC — anon stays THIRTEEN.
-- =============================================================================

-- creates: instructor_pay_periods(uuid)
-- re-issues: record_class_pay(uuid), pay_statement(uuid, uuid), close_pay_period(uuid)

-- -----------------------------------------------------------------------------
-- 1. record_class_pay — the straggler branch stamps original_period (the closed
--    period the class belonged to). No change to amounts. Re-issued from
--    20260831920000 with that one addition.
-- -----------------------------------------------------------------------------
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


-- -----------------------------------------------------------------------------
-- 2. pay_statement — re-issued carrying everything the pages need (so
--    instructor_pay_summary can be retired from the page). Per line: checked_in
--    (null before finalisation), finalised, booked, from_previous_period,
--    first_class_on (conversion), confirmed/held/payable as today. Header: the
--    Open/Closed/Paid status (Paid = a settlement row exists), settle_on,
--    paid_on/method/reference, held_count. Caller rules unchanged.
-- -----------------------------------------------------------------------------
create or replace function pay_statement(p_instructor_id uuid, p_period_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  p pay_periods%rowtype; v_studio uuid; v_tz text; v_name text; v_cur char(3);
  v_lines jsonb; v_sub jsonb; v_total bigint; v_self boolean; v_conf bigint; v_held bigint;
  v_settle_dow int; v_settle_offset int; v_held_count int;
  v_paid_on date; v_method text; v_reference text; v_status text;
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

  -- Paid = a settlement row for this instructor and period (the money moved
  -- elsewhere and the studio recorded it). That is the third header state.
  select paid_on, method, reference into v_paid_on, v_method, v_reference
    from instructor_pay_settlements
   where period_id = p_period_id and instructor_id = p_instructor_id;
  v_status := case when v_paid_on is not null then 'paid' else p.status::text end;

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
        'time', fmt_clock_s(o.starts_at, v_studio),
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
        -- Decision 75(i): booked at cutoff, and the checked-in count once the
        -- class has been finalised (null before — "awaiting attendance").
        'booked', case when r.type = 'class' then o.booked_at_cutoff end,
        'checked_in', case when r.type = 'class' then (r.basis ->> 'checked_in')::int end,
        'finalised', case when r.type = 'class' then (r.basis ? 'finalised_at') else null end,
        'headcount', case when r.type = 'class' then o.booked_at_cutoff end,
        -- DECISION 32 note, now a detail line: a late booker after the cutoff.
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
        -- A class or adjustment carried from a now-closed period (straggler /
        -- finalise true-up) is tagged "from the previous period".
        'from_previous_period', ((r.basis ->> 'original_period') is not null
                                 and (r.basis ->> 'original_period') <> p_period_id::text),
        -- A conversion bonus can land in a period after the class that earned
        -- it; show that first-class date so the line reads sensibly.
        'first_class_on', case when r.type = 'conversion' then r.basis ->> 'first_class_on' end,
        'capacity',  case when r.type = 'class' then o.capacity end,
        'amount_cents', r.amount_cents,
        'confirmed', r.confirmed_at is not null,
        'payable', r.type <> 'class' or r.confirmed_at is not null,
        'note', r.note,
        'basis', r.basis) as l,
      r.amount_cents as amt
      from instructor_pay_records r
      left join class_occurrences o on o.id = r.occurrence_id
     where r.instructor_id = p_instructor_id and r.period_id = p_period_id
  ) x;

  select coalesce(sum(amount_cents) filter (where type <> 'class' or confirmed_at is not null), 0),
         coalesce(sum(amount_cents) filter (where type = 'class' and confirmed_at is null), 0),
         count(*) filter (where type = 'class' and confirmed_at is null)
    into v_conf, v_held, v_held_count
    from instructor_pay_records where instructor_id = p_instructor_id and period_id = p_period_id;

  select jsonb_object_agg(t, s) into v_sub from (
    select type::text as t, sum(amount_cents) as s
      from instructor_pay_records
     where instructor_id = p_instructor_id and period_id = p_period_id
     group by type) y;

  return jsonb_build_object('ok', true,
    'instructor_id', p_instructor_id, 'instructor_name', v_name,
    'period_id', p.id, 'starts_on', p.starts_on, 'ends_on', p.ends_on,
    'status', v_status, 'currency', v_cur,
    'settle_on', pay_settle_on(p.ends_on, v_settle_dow, v_settle_offset),
    'paid_on', v_paid_on, 'paid_method', v_method, 'paid_reference', v_reference,
    'lines', coalesce(v_lines, '[]'::jsonb),
    'subtotals', coalesce(v_sub, '{}'::jsonb),
    'total_cents', v_total,
    'confirmed_cents', v_conf, 'held_cents', v_held, 'held_count', v_held_count);
end $function$;

revoke execute on function pay_statement(uuid, uuid) from public, anon;
grant  execute on function pay_statement(uuid, uuid) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 3. instructor_pay_periods — the periods that have any record or settlement for
--    this instructor, newest first, with Open/Closed/Paid, for the page picker.
-- -----------------------------------------------------------------------------
create or replace function instructor_pay_periods(p_instructor_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_studio uuid; v_rows jsonb;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  if not (is_this_instructor(p_instructor_id) or coalesce(is_manager_up(v_studio), false)) then
    raise exception 'that is somebody else''s pay' using errcode = 'PT403';
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.starts_on desc), '[]'::jsonb) into v_rows
  from (
    select p.id as period_id, p.starts_on, p.ends_on,
           case when exists (select 1 from instructor_pay_settlements s
                              where s.period_id = p.id and s.instructor_id = p_instructor_id)
                then 'paid' else p.status::text end as status
      from pay_periods p
     where p.studio_id = v_studio
       and (exists (select 1 from instructor_pay_records r
                     where r.period_id = p.id and r.instructor_id = p_instructor_id)
         or exists (select 1 from instructor_pay_settlements s
                     where s.period_id = p.id and s.instructor_id = p_instructor_id))
  ) x;
  return v_rows;
end $function$;

revoke execute on function instructor_pay_periods(uuid) from public, anon;
grant  execute on function instructor_pay_periods(uuid) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 4. close_pay_period — unchanged behaviour, but the held-records refusal is now
--    a reason (house style) listing the classes, not a raise. Not-found,
--    not-manager and already-closed stay raises (nothing to act on in the list).
-- -----------------------------------------------------------------------------
create or replace function close_pay_period(p_period_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare p pay_periods%rowtype; n int; v_total bigint; v_tz text; v_classes jsonb;
begin
  select * into p from pay_periods where id = p_period_id;
  if not found then raise exception 'no such period' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(p.studio_id), false) then
    raise exception 'only owners and managers close a period' using errcode = 'PT403';
  end if;
  if p.status = 'closed' then
    raise exception 'that period is already closed' using errcode = 'PT409';
  end if;

  -- Decision 28: a closed period cannot contain a held (unconfirmed class)
  -- record. Return the holdouts as a reason the page can list — not a raise.
  select timezone into v_tz from studios where id = p.studio_id;
  select jsonb_agg(jsonb_build_object(
           'name', o.name,
           'when', to_char(o.starts_at at time zone v_tz, 'FMDy FMDD FMMon') || ' ' || fmt_clock_s(o.starts_at, p.studio_id),
           'instructor', i.display_name) order by o.starts_at)
    into v_classes
    from instructor_pay_records r
    join class_occurrences o on o.id = r.occurrence_id
    join instructors i on i.id = r.instructor_id
   where r.period_id = p_period_id and r.type = 'class' and r.confirmed_at is null;
  if v_classes is not null then
    return jsonb_build_object('ok', false, 'reason', 'held_records', 'classes', v_classes);
  end if;

  select count(*), coalesce(sum(amount_cents), 0) into n, v_total
    from instructor_pay_records where period_id = p_period_id;

  update pay_periods set status = 'closed', closed_at = now(), closed_by = auth.uid()
   where id = p_period_id;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (p.studio_id, auth.uid(), 'pay_period.closed', 'pay_periods', p_period_id,
          jsonb_build_object('records', n, 'total_cents', v_total,
                             'starts_on', p.starts_on, 'ends_on', p.ends_on));

  return jsonb_build_object('ok', true, 'period_id', p_period_id,
    'records', n, 'total_cents', v_total,
    'note', 'Closed. Corrections from here are adjustments in the next period.');
end $function$;

revoke execute on function close_pay_period(uuid) from public, anon;
grant  execute on function close_pay_period(uuid) to authenticated, service_role;

-- anon surface unchanged.
do $$ declare n int; begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where ns.nspname='public' and p.prokind='f'
     and has_function_privilege('anon', p.oid, 'execute') and p.proname not like 'expect_%';
  if n <> 13 then raise exception 'anon surface drifted: expected 13, got %', n; end if;
end $$;
