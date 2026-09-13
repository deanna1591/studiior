-- Decision 28 — the instructor checks themselves in for pay. Decision 22 built
-- the payroll, but nothing recorded that the instructor was actually in the
-- room: pay is computed from booked_at_cutoff, so an instructor who does not
-- show still gets paid and the studio finds out from members complaining.
--
-- The COMPUTATION does not change — the amount is still Decision 22's, from
-- booked_at_cutoff and the rate version. What changes is a HELD flag: a class
-- that ran writes its pay record HELD (known, not payable) until the instructor
-- confirms — one tap on the class, in the portal, within the class's check-in
-- window — or a manager releases it. A class that did NOT run needs no check-in
-- and is auto-confirmed. A closed period cannot contain a held record.

alter table class_occurrences
  add column if not exists instructor_checked_in_at timestamptz,
  add column if not exists instructor_checked_in_by uuid references auth.users(id);

alter table instructor_pay_records
  add column if not exists confirmed_at timestamptz,
  add column if not exists confirmed_by uuid references auth.users(id),
  add column if not exists confirm_method text
    check (confirm_method in ('self','manager','auto')),
  add column if not exists confirm_note text;

-- Backfill: every EXISTING class pay record is treated as confirmed (auto), so
-- turning this on does not retroactively hold pay a studio already owes.
update instructor_pay_records set confirmed_at = coalesce(confirmed_at, created_at),
       confirm_method = coalesce(confirm_method, 'auto')
 where type = 'class' and confirmed_at is null;

-- ===== re-issued functions =====
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

  c := compute_class_pay(p_occurrence_id);
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

CREATE OR REPLACE FUNCTION public.close_pay_period(p_period_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p pay_periods%rowtype; n int; v_total bigint;
begin
  select * into p from pay_periods where id = p_period_id;
  if not found then raise exception 'no such period' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(p.studio_id), false) then
    raise exception 'only owners and managers close a period' using errcode = 'PT403';
  end if;
  if p.status = 'closed' then
    raise exception 'that period is already closed' using errcode = 'PT409';
  end if;

  -- Decision 28: a closed period cannot contain a held record. Either it is
  -- confirmed (the instructor checked in, or a manager released it) before
  -- close, or close is refused and names how many are holding it.
  select count(*) into n from instructor_pay_records
   where period_id = p_period_id and type = 'class' and confirmed_at is null;
  if n > 0 then
    raise exception '% class record(s) are still unconfirmed — an instructor has not checked in, or a manager must release them. Close is blocked until every held record is confirmed.', n
      using errcode = 'PT409';
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
end $function$

;

CREATE OR REPLACE FUNCTION public.pay_statement(p_instructor_id uuid, p_period_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  p pay_periods%rowtype; v_studio uuid; v_tz text; v_name text; v_cur char(3);
  v_lines jsonb; v_sub jsonb; v_total bigint; v_self boolean; v_conf bigint; v_held bigint;
begin
  select * into p from pay_periods where id = p_period_id;
  if not found then raise exception 'no such period' using errcode = 'PT404'; end if;
  v_studio := p.studio_id;

  -- Manager-up of that studio, or the instructor reading their own. An
  -- instructor seeing their own statement is the point of it; seeing anybody
  -- else's is Permissions §11 in reverse.
  select exists (select 1 from instructors i join studio_staff ss on ss.id = i.staff_id
                  where i.id = p_instructor_id and ss.user_id = auth.uid())
    into v_self;
  if not coalesce(is_manager_up(v_studio), false) and not coalesce(v_self, false) then
    raise exception 'that is not your statement' using errcode = 'PT403';
  end if;

  select timezone, currency into v_tz, v_cur from studios where id = v_studio;
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
        -- The STATUS a studio needs to see, not the raw column: "did not run"
        -- and "cancelled" pay differently and reading the same word for both is
        -- how a statement stops being checkable.
        'status', case
                    when r.type <> 'class' then null
                    when o.status <> 'cancelled' then 'ran'
                    when o.cancellation_cause = 'unmet_minimum' then 'did not run'
                    else 'cancelled — ' || o.cancellation_cause::text end,
        'headcount', case when r.type = 'class' then o.booked_at_cutoff end,
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

  -- Confirmed vs held, so a studio sees what it owes and what is pending.
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
    'lines', coalesce(v_lines, '[]'::jsonb),
    'subtotals', coalesce(v_sub, '{}'::jsonb),
    'total_cents', v_total,
    'confirmed_cents', v_conf, 'held_cents', v_held);
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
           -- occurrence_guarantee() RETURNS TABLE, not jsonb. It is readable
           -- by any staff of the studio, an instructor included, so this is a
           -- call-shape fix and not a permission one.
           (select g.tier::text from occurrence_guarantee(o.id) g) as tier,
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

CREATE OR REPLACE FUNCTION public.instructor_pay_summary(p_instructor_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_studio uuid; v_tz text; v_cur char(3); v_period pay_periods%rowtype; v_rows jsonb;
begin
  select i.studio_id into v_studio from instructors i where i.id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  -- An instructor reads their OWN. Migration 086 exists because eight
  -- functions in this area took an id and answered for anybody.
  if not (is_this_instructor(p_instructor_id) or is_manager_up(v_studio)) then
    raise exception 'that is somebody else''s pay' using errcode = 'PT403';
  end if;
  select s.timezone, s.currency into v_tz, v_cur from studios s where s.id = v_studio;

  select * into v_period from pay_periods
   where studio_id = v_studio and status = 'open'
   order by starts_on limit 1;

  if v_period.id is null then
    return jsonb_build_object('state', 'no_period', 'currency', v_cur,
      'empty_hint', 'Your studio has not opened a pay period yet. Once it does, every class you teach lands here with what it paid.');
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.starts_at desc), '[]'::jsonb)
    into v_rows from (
    select pr.id, pr.occurrence_id, o.name, o.starts_at,
           to_char(o.starts_at at time zone v_tz, 'DD Mon HH24:MI') as local_when,
           pr.amount_cents,
           -- The breakdown lives in basis (jsonb), not top-level columns — the
           -- previous version read columns that do not exist and errored for any
           -- instructor who had pay records.
           coalesce((pr.basis ->> 'base_cents')::int, 0) as base_cents,
           coalesce((pr.basis ->> 'per_head_cents')::int, 0) as per_head_cents,
           coalesce((pr.basis ->> 'full_house_bonus_cents')::int, 0) as bonus_cents,
           coalesce((pr.basis ->> 'booked_at_cutoff')::int, 0) as head_count,
           pr.type::text as kind,
           o.status::text as occurrence_status,
           o.cancellation_cause::text as cancellation_cause,
           o.status = 'cancelled' as did_not_run,
           -- Decision 28: held (computed, not yet payable) vs confirmed.
           pr.confirmed_at is not null as confirmed,
           (pr.type = 'class' and pr.confirmed_at is null) as held
      from instructor_pay_records pr
      left join class_occurrences o on o.id = pr.occurrence_id
     where pr.instructor_id = p_instructor_id and pr.period_id = v_period.id) x;

  return jsonb_build_object(
    'state', case when jsonb_array_length(v_rows) = 0 then 'empty' else 'ok' end,
    'currency', v_cur,
    'period', jsonb_build_object('id', v_period.id, 'starts_on', v_period.starts_on,
                                 'ends_on', v_period.ends_on, 'status', v_period.status),
    'total_cents', (select coalesce(sum((r ->> 'amount_cents')::bigint), 0)
                      from jsonb_array_elements(v_rows) r),
    'classes_paid', (select count(*) from jsonb_array_elements(v_rows) r
                      where (r ->> 'did_not_run')::boolean is not true),
    'not_running_paid', (select count(*) from jsonb_array_elements(v_rows) r
                          where (r ->> 'did_not_run')::boolean),
    'held_cents', (select coalesce(sum((r ->> 'amount_cents')::bigint), 0)
                     from jsonb_array_elements(v_rows) r where (r ->> 'held')::boolean),
    'records', v_rows,
    'empty_hint', 'Nothing in this period yet. A class pays once it is done, so today''s classes appear tonight.',
    'read_only', 'These are the studio''s figures. If something looks wrong, tell them — nothing here can be edited from this screen.');
end $function$

;

-- ===== new functions =====

-- The instructor's own tap, in the portal, on My week. Within the class's
-- check-in window (the member window from migration 007 — the studio's own
-- setting, not hardcoded), on a class that ran, by that class's instructor.
create function instructor_confirm_class(p_occurrence_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o class_occurrences%rowtype; v_opens int; v_closes int; v_enforced boolean;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if o.instructor_id is null or not coalesce(is_this_instructor(o.instructor_id), false) then
    raise exception 'that is not your class' using errcode = 'PT403';
  end if;
  if o.status = 'cancelled' then
    raise exception 'that class did not run — there is nothing to check in to' using errcode = 'PT409';
  end if;
  select coalesce(checkin_opens_minutes_before, 60), coalesce(checkin_closes_minutes_after, 30),
         coalesce(checkin_window_enforced, true)
    into v_opens, v_closes, v_enforced from studio_settings where studio_id = o.studio_id;
  if coalesce(v_enforced, true) then
    if now() < o.starts_at - make_interval(mins => v_opens) then
      raise exception 'too early — you can check in from % minutes before the class starts', v_opens using errcode = 'PT422';
    end if;
    if now() > o.ends_at + make_interval(mins => v_closes) then
      raise exception 'the check-in window has closed — ask a manager to release the pay' using errcode = 'PT422';
    end if;
  end if;

  update class_occurrences
     set instructor_checked_in_at = coalesce(instructor_checked_in_at, now()),
         instructor_checked_in_by = coalesce(instructor_checked_in_by, auth.uid())
   where id = p_occurrence_id;
  -- Confirm the held pay record if it has been written yet (it usually has —
  -- written at the terminal transition, before the class). If not, record_class_pay
  -- reads the occurrence stamp above when it writes.
  update instructor_pay_records
     set confirmed_at = coalesce(confirmed_at, now()),
         confirmed_by = coalesce(confirmed_by, auth.uid()),
         confirm_method = coalesce(confirm_method, 'self')
   where occurrence_id = p_occurrence_id and type = 'class' and confirmed_at is null;
  return jsonb_build_object('ok', true, 'confirmed', true);
end $$;

-- A manager releases a held record on the instructor's behalf, with a reason,
-- audited. THE failure mode that matters: the instructor taught, forgot to tap,
-- and their pay sits held. Without this the feature is a way to not pay people.
create function confirm_class_for_pay(p_occurrence_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o class_occurrences%rowtype; v_rec instructor_pay_records%rowtype;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(o.studio_id), false) then
    raise exception 'only owners and managers release pay' using errcode = 'PT403';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'say why — the instructor did the work, and this goes on the record' using errcode = 'PT422';
  end if;
  select * into v_rec from instructor_pay_records where occurrence_id = p_occurrence_id and type = 'class';
  if not found then raise exception 'no pay record for that class' using errcode = 'PT404'; end if;
  if v_rec.confirmed_at is not null then raise exception 'that class is already confirmed' using errcode = 'PT409'; end if;

  update instructor_pay_records
     set confirmed_at = now(), confirmed_by = auth.uid(),
         confirm_method = 'manager', confirm_note = btrim(p_reason)
   where id = v_rec.id;
  update class_occurrences
     set instructor_checked_in_at = coalesce(instructor_checked_in_at, now()),
         instructor_checked_in_by = coalesce(instructor_checked_in_by, auth.uid())
   where id = p_occurrence_id;
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (o.studio_id, auth.uid(), 'pay_record.released', 'instructor_pay_records', v_rec.id,
    jsonb_build_object('occurrence_id', p_occurrence_id, 'instructor_id', v_rec.instructor_id,
                       'reason', btrim(p_reason)));
  return jsonb_build_object('ok', true, 'released', true);
end $$;

-- How many held records a studio has outstanding, for a staff surface.
create function studio_unconfirmed_pay_count(p_studio_id uuid) returns int
language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(is_manager_up(p_studio_id), false) and not is_service_context() then
    raise exception 'not authorised' using errcode = 'PT403';
  end if;
  return (select count(*)::int from instructor_pay_records pr
            join class_occurrences o on o.id = pr.occurrence_id
           where pr.studio_id = p_studio_id and pr.type = 'class'
             and pr.confirmed_at is null and o.status <> 'cancelled');
end $$;

-- Remind an instructor, the same day, about a class that finished unconfirmed —
-- they are the person who can fix it in one tap. Once per record.
insert into notification_templates (key, subject, text_body, html_body, note) values
('instructor_unconfirmed', 'Check in for {class_name} so your pay is released',
 E'Hi {first_name},\n\n{class_name} on {when} is done, but you have not checked in — your pay for it is held until you do. Open the app and tap the class; it takes a second.\n\n{studio_name}',
 E'<p>Hi {first_name},</p><p>{class_name} on {when} is done, but you have not checked in — your pay for it is held until you do. Open the app and tap the class.</p>',
 'Decision 28. Sent to an instructor whose finished class is still unconfirmed for pay.');

create function sweep_instructor_confirmations() returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; v_sent int := 0;
begin
  if not is_service_context() then
    raise exception 'the instructor confirmation sweep is a background job' using errcode = 'PT403';
  end if;
  for r in
    select pr.id as rec_id, o.studio_id, o.instructor_id, o.name, o.starts_at,
           (select timezone from studios where id = o.studio_id) as tz
      from instructor_pay_records pr
      join class_occurrences o on o.id = pr.occurrence_id
     where pr.type = 'class' and pr.confirmed_at is null
       and o.status <> 'cancelled'
       and o.ends_at < now() and o.ends_at > now() - interval '7 days'
  loop
    if queue_shift_notice(r.studio_id, instructor_user_id(r.instructor_id), 'instructor_unconfirmed',
         jsonb_build_object('class_name', r.name,
           'when', to_char(r.starts_at at time zone r.tz, 'FMDay FMDD FMMonth, HH24:MI')),
         'instructor_unconfirmed:' || r.rec_id) is not null then
      v_sent := v_sent + 1;
    end if;
  end loop;
  insert into job_runs (job_key, run_for, status, finished_at)
  values ('instructor_confirmations', current_date, 'done', now())
  on conflict (job_key, run_for) do update
     set attempts = job_runs.attempts + 1, started_at = now(), status = 'done', finished_at = now();
  return jsonb_build_object('reminded', v_sent);
end $$;

do $$ begin
  if exists (select 1 from cron.job where jobname = 'studiior-instructor-confirmations') then
    perform cron.unschedule('studiior-instructor-confirmations');
  end if;
  perform cron.schedule('studiior-instructor-confirmations', '*/30 * * * *',
                        $job$select sweep_instructor_confirmations()$job$);
end $$;

revoke execute on function instructor_confirm_class(uuid)        from public, anon;
revoke execute on function confirm_class_for_pay(uuid, text)     from public, anon;
revoke execute on function studio_unconfirmed_pay_count(uuid)    from public, anon;
revoke execute on function sweep_instructor_confirmations()      from public, anon, authenticated;
grant  execute on function instructor_confirm_class(uuid)        to authenticated;
grant  execute on function confirm_class_for_pay(uuid, text)     to authenticated;
grant  execute on function studio_unconfirmed_pay_count(uuid)    to authenticated, service_role;
grant  execute on function sweep_instructor_confirmations()      to service_role;
