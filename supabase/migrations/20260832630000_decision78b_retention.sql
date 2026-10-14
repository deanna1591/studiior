-- Decision 78b — the retention board gains two read-only sections: "Expiring
-- this week" and "Lapsed this month" (tasks for these come in 78c). A section
-- column is added, so retention_board is dropped and recreated; the unconverted
-- branch is unchanged. retention_unconverted_count counts only the unconverted
-- section, so the dashboard tile and morning-brief line are unaffected.
--
-- re-issues: retention_board(uuid), retention_unconverted_count(uuid)

drop function if exists retention_board(uuid);
create function retention_board(p_studio_id uuid)
returns table (
  section text,
  member_id uuid, member_name text, phone text,
  class_at timestamptz, days_since int, instructor_name text,
  offer_ends timestamptz, window_active boolean,
  plan_name text, expires_on date,
  task_id uuid, task_status text, suggested_message text)
language plpgsql stable security definer set search_path = public as $$
declare v_tz text; v_today date;
begin
  if not (coalesce(is_manager_up(p_studio_id), false)
          or (coalesce(is_desk_up(p_studio_id), false)
              and coalesce((select retention_tasks_to from studio_settings
                             where studio_id = p_studio_id), 'owner_manager') = 'front_desk')
          or is_service_context()) then
    raise exception 'that is another studio''s retention board' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  v_today := (now() at time zone v_tz)::date;

  return query
  -- Unconverted free classes (78a) — unchanged.
  with free_members as (
    select distinct on (b.member_id)
           b.member_id, b.occurrence_id, o.starts_at, o.instructor_id
      from bookings b join class_occurrences o on o.id = b.occurrence_id
     where b.studio_id = p_studio_id and b.payment_source = 'comp'
       and not exists (select 1 from guest_passes gp
                        where gp.guest_booking_id = b.id and gp.host_member_id is not null)
     order by b.member_id, b.booked_at
  )
  select 'unconverted'::text,
         m.id,
         coalesce(nullif(m.first_name, ''), m.email),
         m.phone,
         fm.starts_at,
         greatest(0, (v_today - fm.starts_at::date))::int,
         split_part(coalesce(i.display_name, ''), ' ', 1),
         (intro_window(m.id) ->> 'ends_at')::timestamptz,
         coalesce((intro_window(m.id) ->> 'active')::boolean, false),
         null::text, null::date,
         t.id, t.status, t.suggested_message
    from free_members fm
    join members m on m.id = fm.member_id and m.deleted_at is null
    left join instructors i on i.id = fm.instructor_id
    left join lateral (
      select mt.id, mt.status, mt.suggested_message
        from member_tasks mt
       where mt.member_id = m.id and mt.kind = 'unconverted_day7' and mt.status <> 'dismissed'
       order by mt.created_at desc limit 1) t on true
   where not exists (select 1 from memberships ms where ms.member_id = m.id)

  union all
  -- Expiring this week — an active, non-auto-renewing membership ending within 7
  -- studio-local days (and the member's latest-ending active one).
  select 'expiring'::text,
         m.id, coalesce(nullif(m.first_name, ''), m.email), m.phone,
         null::timestamptz, 0, null::text, null::timestamptz, null::boolean,
         pl.name, mend.d,
         null::uuid, null::text, null::text
    from memberships ms
    join membership_plans pl on pl.id = ms.plan_id
    join members m on m.id = ms.member_id and m.deleted_at is null
    cross join lateral (select coalesce(ms.expires_on, (ms.current_period_end at time zone v_tz)::date) as d) mend
   where ms.studio_id = p_studio_id
     and ms.status in ('active', 'past_due')
     and not (coalesce(ms.auto_renew, false) or ms.stripe_subscription_id is not null)
     and mend.d between v_today and v_today + 7
     and not exists (select 1 from memberships ms2
                      where ms2.member_id = ms.member_id and ms2.id <> ms.id and ms2.status = 'active'
                        and coalesce(ms2.expires_on, (ms2.current_period_end at time zone v_tz)::date, 'infinity'::date) > mend.d)

  union all
  -- Lapsed this month — a membership that ended in the last 30 days, with no
  -- active membership now and nothing started since (so only their last one).
  select 'lapsed'::text,
         m.id, coalesce(nullif(m.first_name, ''), m.email), m.phone,
         null::timestamptz, greatest(0, v_today - mend.d)::int, null::text, null::timestamptz, null::boolean,
         pl.name, mend.d,
         null::uuid, null::text, null::text
    from memberships ms
    join membership_plans pl on pl.id = ms.plan_id
    join members m on m.id = ms.member_id and m.deleted_at is null
    cross join lateral (select coalesce(ms.expires_on, (ms.current_period_end at time zone v_tz)::date) as d) mend
   where ms.studio_id = p_studio_id
     and mend.d between v_today - 30 and v_today - 1
     and not exists (select 1 from memberships ms2
                      where ms2.member_id = ms.member_id and ms2.status = 'active'
                        and coalesce(ms2.expires_on, 'infinity'::date) > v_today)
     and not exists (select 1 from memberships ms3
                      where ms3.member_id = ms.member_id
                        and coalesce(ms3.starts_on, '-infinity'::date) > mend.d)

  order by 1, 6 desc, 3;
end $$;
revoke execute on function retention_board(uuid) from public, anon;
grant  execute on function retention_board(uuid) to authenticated, service_role;

create or replace function retention_unconverted_count(p_studio_id uuid)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from retention_board(p_studio_id) where section = 'unconverted';
$$;
revoke execute on function retention_unconverted_count(uuid) from public, anon;
grant  execute on function retention_unconverted_count(uuid) to authenticated, service_role;
