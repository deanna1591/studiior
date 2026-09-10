-- =============================================================================
-- 084  Decision 22: the period statement, and what a studio does with it.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- One instructor, one period, every line
-- -----------------------------------------------------------------------------
create or replace function pay_statement(p_instructor_id uuid, p_period_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  p pay_periods%rowtype; v_studio uuid; v_tz text; v_name text; v_cur char(3);
  v_lines jsonb; v_sub jsonb; v_total bigint; v_self boolean;
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
        'basis', r.basis) as l,
      r.amount_cents as amt
      from instructor_pay_records r
      left join class_occurrences o on o.id = r.occurrence_id
     where r.instructor_id = p_instructor_id and r.period_id = p_period_id
  ) x;

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
    'total_cents', v_total);
end $$;

-- -----------------------------------------------------------------------------
-- What the studio acts on
-- -----------------------------------------------------------------------------
-- THE not_running RATE LEADS, because it is the number a studio can do
-- something about: a slot that does not run half the time is a slot in the
-- wrong place, and everything else here is a consequence of that.
create or replace function guarantee_report(p_studio_id uuid, p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_tz text; v_by_slot jsonb; v_by_tier jsonb; v_totals jsonb;
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers see the numbers' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;

  with o as (
    select occ.*, (occ.starts_at at time zone v_tz)::date as local_date,
           to_char(occ.starts_at at time zone v_tz, 'Dy HH24:MI') as slot,
           coalesce(occ.guarantee_tier,
                    case when occ.flex then 'flex'::guarantee_tier end,
                    'core'::guarantee_tier) as tier,
           (occ.status = 'cancelled' and occ.cancellation_cause = 'unmet_minimum') as not_running,
           coalesce(occ.booked_at_cutoff, occ.booked_count, 0) as heads
      from class_occurrences occ
     where occ.studio_id = p_studio_id
       and (occ.starts_at at time zone v_tz)::date between p_from and p_to
  ),
  pay as (
    select r.occurrence_id, r.amount_cents from instructor_pay_records r
     where r.studio_id = p_studio_id and r.type = 'class'
  ),
  rev as (
    -- Revenue attributed to a class: what was actually taken for a booking on
    -- it. A membership booking has no payment of its own, so this understates
    -- for subscription studios and the report says so rather than inventing an
    -- apportionment nobody agreed to.
    select b.occurrence_id, coalesce(sum(p.amount_cents), 0) as cents
      from bookings b
      join payments p on p.booking_id = b.id and p.status = 'succeeded'
     where b.studio_id = p_studio_id
     group by b.occurrence_id
  )
  select
    jsonb_agg(jsonb_build_object(
      'slot', slot, 'classes', n, 'not_running', n_not,
      'not_running_pct', round(100.0 * n_not / nullif(n, 0), 1),
      'avg_fill_pct', round(avg_fill, 1),
      'cost_cents', cost, 'revenue_cents', revenue)
      order by (1.0 * n_not / nullif(n, 0)) desc nulls last, slot)
    into v_by_slot
  from (
    select o.slot, count(*) as n,
           count(*) filter (where o.not_running) as n_not,
           avg(100.0 * o.heads / nullif(o.capacity, 0)) as avg_fill,
           coalesce(sum(pay.amount_cents), 0) as cost,
           coalesce(sum(rev.cents), 0) as revenue
      from o left join pay on pay.occurrence_id = o.id
             left join rev on rev.occurrence_id = o.id
     group by o.slot) s;

  select jsonb_agg(jsonb_build_object(
      'tier', tier, 'classes', n, 'not_running', n_not,
      'not_running_pct', round(100.0 * n_not / nullif(n, 0), 1))
      order by tier)
    into v_by_tier
  from (select o.tier, count(*) as n, count(*) filter (where o.not_running) as n_not
          from o group by o.tier) t;

  select jsonb_build_object(
      'classes', count(*),
      'not_running', count(*) filter (where o.not_running),
      'not_running_pct', round(100.0 * count(*) filter (where o.not_running) / nullif(count(*), 0), 1),
      'cost_cents', coalesce(sum(pay.amount_cents), 0),
      'revenue_cents', coalesce(sum(rev.cents), 0),
      'cost_share_of_revenue_pct',
        round(100.0 * coalesce(sum(pay.amount_cents), 0)
              / nullif(coalesce(sum(rev.cents), 0), 0), 1))
    into v_totals
  from o left join pay on pay.occurrence_id = o.id
         left join rev on rev.occurrence_id = o.id;

  return jsonb_build_object('ok', true, 'from', p_from, 'to', p_to,
    'totals', v_totals,
    'by_slot', coalesce(v_by_slot, '[]'::jsonb),
    'by_tier', coalesce(v_by_tier, '[]'::jsonb),
    'revenue_note', 'Revenue counts payments recorded against a booking. A class '
                    'filled by memberships shows no revenue of its own, so cost '
                    'share is only meaningful where classes are paid for singly.');
end $$;

revoke execute on function pay_statement(uuid, uuid)          from public, anon, authenticated;
revoke execute on function guarantee_report(uuid, date, date) from public, anon, authenticated;
grant execute on function pay_statement(uuid, uuid)           to authenticated;
grant execute on function guarantee_report(uuid, date, date)  to authenticated;
