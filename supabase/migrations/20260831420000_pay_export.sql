-- CSV export for accounting. The export must reflect a closed period exactly as
-- the statement does — if the CSV and the statement disagree, the CSV is what an
-- accountant believes and the studio has a problem. So this reads the same source
-- (instructor_pay_records + occurrences) in the same line shape as pay_statement,
-- across every instructor in the period. The app formats the CSV; the numbers are
-- the database's.

create function pay_period_export(p_period_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare pr pay_periods%rowtype; v_tz text; v_cur char(3); v_rows jsonb; v_sum jsonb;
begin
  select * into pr from pay_periods where id = p_period_id;
  if not found then raise exception 'no such period' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(pr.studio_id), false) then
    raise exception 'only owners and managers export payroll' using errcode = 'PT403';
  end if;
  select timezone, currency into v_tz, v_cur from studios where id = pr.studio_id;

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
      -- The same status words the statement uses, so the two cannot disagree.
      'status', case
                  when r.type <> 'class' then null
                  when o.status <> 'cancelled' then 'ran'
                  when o.cancellation_cause = 'unmet_minimum' then 'did not run'
                  else 'cancelled — ' || o.cancellation_cause::text end,
      'headcount', case when r.type = 'class' then o.booked_at_cutoff end,
      'rate_version_id', r.rate_version_id,
      'amount_cents', r.amount_cents,
      -- The category an accountant files it under.
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
    'rows', coalesce(v_rows, '[]'::jsonb), 'summary', coalesce(v_sum, '[]'::jsonb));
end $$;
revoke execute on function pay_period_export(uuid) from public, anon;
grant  execute on function pay_period_export(uuid) to authenticated, service_role;
