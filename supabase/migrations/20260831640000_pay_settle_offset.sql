-- =============================================================================
-- Decision 31 — the settle date gains a second shape: a fixed OFFSET IN DAYS
-- after the period closes (0 = the close date itself), beside migration 140's
-- weekday rule. Reform Collective pays on the 15th and the last day of the
-- month — a semimonthly cycle whose pay date IS each period's own end — which no
-- weekday rule can express.
--
-- Exactly one shape may be set (a CHECK), and the offset is bounded 0..31 so a
-- fat-fingered 300 cannot push the pay date a year out. Both null = no date
-- shown, exactly as today (off by default, per tenant).
-- =============================================================================

alter table studio_settings
  add column if not exists pay_settle_offset_days int;

-- Bounded, and mutually exclusive with the weekday rule.
alter table studio_settings
  add constraint pay_settle_offset_bounds
    check (pay_settle_offset_days is null or pay_settle_offset_days between 0 and 31);
alter table studio_settings
  add constraint pay_settle_one_shape
    check (pay_settle_dow is null or pay_settle_offset_days is null);

comment on column studio_settings.pay_settle_offset_days is
  'Days after a period''s ends_on that pay lands (0 = the close date). The second '
  'settle shape (Decision 31), mutually exclusive with pay_settle_dow. NULL both = '
  'no payment date shown. Bounded 0..31.';

-- -----------------------------------------------------------------------------
-- pay_settle_on gains the offset branch. Still pure date arithmetic — no tenant
-- read, no security surface — so it stays IMMUTABLE and the guarded readers hand
-- in the studio's own dow AND offset. A new arity (dow + offset), so the 2-arg
-- form is DROPPED and its three callers are re-issued below to pass the offset;
-- keeping the old 2-arg would be a footgun that silently ignores the offset.
--
-- The offset wins when it is set (the new CHECK guarantees at most one is), and
-- an offset of 0 is the close date itself. Otherwise the weekday rule: the first
-- p_dow STRICTLY AFTER ends_on.
-- -----------------------------------------------------------------------------
drop function if exists pay_settle_on(date, int);
create function pay_settle_on(p_ends_on date, p_dow int, p_offset_days int)
returns date
language sql
immutable
as $$
  select case
    when p_offset_days is not null then p_ends_on + p_offset_days
    when p_dow is null or p_dow < 0 or p_dow > 6 then null
    else (p_ends_on + 1)
         + ((p_dow - extract(dow from (p_ends_on + 1))::int + 7) % 7)
  end;
$$;
-- A fresh create is born with the hosted default anon grant; it must NOT become
-- an eleventh anon surface, and it stays authenticated like the 2-arg form was.
revoke execute on function pay_settle_on(date, int, int) from public, anon;
grant  execute on function pay_settle_on(date, int, int) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- The three readers, re-issued from migration 140's definitions with the offset
-- read alongside the dow and passed into the 3-arg pay_settle_on. Guards, lines
-- and totals unchanged. create-or-replace keeps their ACL.
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

CREATE OR REPLACE FUNCTION public.instructor_pay_summary(p_instructor_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_studio uuid; v_tz text; v_cur char(3); v_period pay_periods%rowtype; v_rows jsonb;
        v_settle_dow int; v_settle_offset int;
begin
  select i.studio_id into v_studio from instructors i where i.id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  if not (is_this_instructor(p_instructor_id) or is_manager_up(v_studio)) then
    raise exception 'that is somebody else''s pay' using errcode = 'PT403';
  end if;
  select s.timezone, s.currency into v_tz, v_cur from studios s where s.id = v_studio;
  select pay_settle_dow, pay_settle_offset_days into v_settle_dow, v_settle_offset
    from studio_settings where studio_id = v_studio;

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
           coalesce((pr.basis ->> 'base_cents')::int, 0) as base_cents,
           coalesce((pr.basis ->> 'per_head_cents')::int, 0) as per_head_cents,
           coalesce((pr.basis ->> 'full_house_bonus_cents')::int, 0) as bonus_cents,
           coalesce((pr.basis ->> 'booked_at_cutoff')::int, 0) as head_count,
           pr.type::text as kind,
           o.status::text as occurrence_status,
           o.cancellation_cause::text as cancellation_cause,
           o.status = 'cancelled' as did_not_run,
           pr.confirmed_at is not null as confirmed,
           (pr.type = 'class' and pr.confirmed_at is null) as held
      from instructor_pay_records pr
      left join class_occurrences o on o.id = pr.occurrence_id
     where pr.instructor_id = p_instructor_id and pr.period_id = v_period.id) x;

  return jsonb_build_object(
    'state', case when jsonb_array_length(v_rows) = 0 then 'empty' else 'ok' end,
    'currency', v_cur,
    'period', jsonb_build_object('id', v_period.id, 'starts_on', v_period.starts_on,
                                 'ends_on', v_period.ends_on, 'status', v_period.status,
                                 'settle_on', pay_settle_on(v_period.ends_on, v_settle_dow, v_settle_offset)),
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
end $function$;
