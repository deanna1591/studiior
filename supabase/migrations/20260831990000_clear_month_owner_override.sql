-- =============================================================================
-- Decision 42a amendment — the OWNER may clear a published month with bookings.
-- =============================================================================
-- clear_month_assignments stays refused (PT409) on a published month members
-- have booked into — EXCEPT for the studio OWNER with an explicit acknowledge.
-- Member bookings are never touched (the per-occurrence unassign is unchanged:
-- move_occurrence(p_clear_instructor) only takes the instructor off and opens
-- the shift; its member notification is gated on v_moved, which a clear is not).
-- A manager with acknowledge still gets the refusal.
--
-- Adding p_acknowledge is a SIGNATURE CHANGE, so the 3-arg function is DROPPED
-- and recreated 4-arg (the 028 overload trap); the ACL is re-asserted after.
--
-- The Publish page's owner acknowledgement names N members and M classes, and
-- every figure is computed in SQL (never in the app, never by TS timezone
-- math), so month_publication_facts is re-issued to carry booking_members and
-- booking_classes beside the existing bookings count — the same
-- b.status <> 'cancelled' set the clear guard uses, so the sentence describes
-- exactly the bookings that trigger the refusal.
--
-- re-issues: clear_month_assignments(uuid, date, boolean, boolean),
--   month_publication_facts(uuid, date)
-- =============================================================================

-- month_publication_facts re-issued VERBATIM from 20260831170000 with two added
-- counts and their two return keys; service_role-only ACL kept (create or
-- replace, re-asserted at the end to be explicit).
create or replace function month_publication_facts(p_studio_id uuid, p_month date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tz text; v_month date; v_from timestamptz; v_to timestamptz;
  v_pub schedule_publications%rowtype;
  v_classes int; v_open int; v_booked int; v_instructors jsonb;
  v_bk_members int; v_bk_classes int;
begin
  select timezone into v_tz from studios where id = p_studio_id;
  if v_tz is null then raise exception 'no such studio' using errcode = 'PT404'; end if;

  v_month := date_trunc('month', p_month)::date;
  v_from := (v_month::timestamp) at time zone v_tz;
  v_to   := ((v_month + interval '1 month')::timestamp) at time zone v_tz;

  select * into v_pub from schedule_publications
   where studio_id = p_studio_id and month = v_month;

  select count(*)::int,
         count(*) filter (where staffing = 'open')::int
    into v_classes, v_open
    from class_occurrences o
   where o.studio_id = p_studio_id and o.status = 'scheduled'
     and o.starts_at >= v_from and o.starts_at < v_to;

  select count(*)::int into v_booked
    from bookings b join class_occurrences o on o.id = b.occurrence_id
   where o.studio_id = p_studio_id and o.status = 'scheduled'
     and o.starts_at >= v_from and o.starts_at < v_to
     and b.status in ('booked','waitlisted','pending_payment');

  -- N members / M classes for the owner acknowledgement, the clear guard's own
  -- set (b.status <> 'cancelled').
  select count(distinct b.member_id)::int, count(distinct b.occurrence_id)::int
    into v_bk_members, v_bk_classes
    from bookings b join class_occurrences o on o.id = b.occurrence_id
   where o.studio_id = p_studio_id and o.status = 'scheduled'
     and o.starts_at >= v_from and o.starts_at < v_to
     and b.status <> 'cancelled';

  select coalesce(jsonb_agg(x order by x ->> 'name'), '[]'::jsonb) into v_instructors
    from (
      select jsonb_build_object(
               'instructor_id', i.id,
               'name', i.display_name,
               'classes', count(*),
               'reachable', instructor_user_id(i.id) is not null,
               'notified_at', rc.notified_at,
               'confirmed_at', rc.confirmed_at,
               'cover_pending', count(*) filter (where exists (
                   select 1 from cover_requests c
                    where c.occurrence_id = o.id and c.status = 'pending'))) as x
        from class_occurrences o
        join instructors i on i.id = o.instructor_id
        left join roster_confirmations rc
          on rc.studio_id = p_studio_id and rc.instructor_id = i.id and rc.month = v_month
       where o.studio_id = p_studio_id and o.status = 'scheduled'
         and o.starts_at >= v_from and o.starts_at < v_to
       group by i.id, i.display_name, rc.notified_at, rc.confirmed_at) z;

  return jsonb_build_object(
    'month', v_month,
    'label', to_char(v_month, 'FMMonth YYYY'),
    'enabled', publication_enabled(p_studio_id),
    'is_current', v_month = date_trunc('month', now() at time zone v_tz)::date,
    'is_past',    v_month < date_trunc('month', now() at time zone v_tz)::date,
    'published',  v_pub.id is not null,
    'published_at', v_pub.published_at,
    'published_by', v_pub.published_by,
    'auto', coalesce(v_pub.auto, false),
    'classes', v_classes,
    'open_shifts', v_open,
    'bookings', v_booked,
    'booking_members', v_bk_members,
    'booking_classes', v_bk_classes,
    'instructors', v_instructors);
end $$;
revoke execute on function month_publication_facts(uuid, date) from public, anon, authenticated;
grant  execute on function month_publication_facts(uuid, date) to service_role;

drop function if exists clear_month_assignments(uuid, date, boolean);

create function clear_month_assignments(
  p_studio_id uuid, p_month date, p_clear_templates boolean default true,
  p_acknowledge boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_tz text; v_month_start date; v_month_end date;
  v_published boolean; v_has_bookings boolean;
  v_count int := 0; v_templates int := 0;
  rec record; v_res jsonb; v_old uuid; v_other uuid; v_dedupe text;
  v_affected uuid[] := '{}';
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers change the timetable' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  if v_tz is null then raise exception 'no such studio' using errcode = 'PT404'; end if;
  v_month_start := date_trunc('month', p_month)::date;
  v_month_end   := (v_month_start + interval '1 month' - interval '1 day')::date;

  -- A draft month (publication on, not yet published) is always clearable — no
  -- member can have booked into it. A published month (or a studio not using
  -- publication, where month_published is true by definition) is clearable only
  -- when no member has booked into it; otherwise change assignments class by
  -- class from the Schedule (Decision 25 offers no unpublish) — UNLESS the
  -- caller is the OWNER and has explicitly acknowledged (Decision 42a
  -- amendment): the instructor comes off each class and the class becomes an
  -- open shift, and members' bookings are untouched.
  v_published := month_published(p_studio_id, ((v_month_start + 14)::date + time '12:00') at time zone v_tz);
  select exists(
    select 1 from bookings b join class_occurrences o on o.id = b.occurrence_id
     where o.studio_id = p_studio_id and o.status = 'scheduled'
       and (o.starts_at at time zone v_tz)::date between v_month_start and v_month_end
       and b.status <> 'cancelled'
  ) into v_has_bookings;
  if v_published and v_has_bookings
     and not (coalesce(is_owner(p_studio_id), false) and p_acknowledge) then
    raise exception 'This month is published and members have booked into it — change assignments class by class from the Schedule instead.'
      using errcode = 'PT409';
  end if;

  for rec in
    select o.id, o.instructor_id from class_occurrences o
     where o.studio_id = p_studio_id and o.status = 'scheduled'
       and o.instructor_id is not null
       and (o.starts_at at time zone v_tz)::date between v_month_start and v_month_end
     order by o.starts_at
  loop
    v_old := rec.instructor_id;
    begin
      v_res := move_occurrence(p_occurrence_id => rec.id, p_confirm => true,
                               p_clear_instructor => true);
      if coalesce((v_res ->> 'ok')::boolean, false) then
        v_count := v_count + 1;
        if not (v_old = any(v_affected)) then v_affected := v_affected || v_old; end if;
      end if;
    exception when others then null;   -- one stubborn class never aborts the clear
    end;
  end loop;

  -- Withdraw the affected instructors' pending digests, as the per-occurrence
  -- unassign does.
  foreach v_old in array v_affected loop
    select id into v_other from class_occurrences
      where instructor_id = v_old and status = 'scheduled' and starts_at > now()
        and assignment_requested_at is not null and assignment_confirmed_at is null
      limit 1;
    if v_other is not null then
      perform queue_assignment_request(v_other);
    else
      v_dedupe := 'assignment_confirm:' || v_old || ':' || (now() at time zone v_tz)::date;
      delete from notifications where dedupe_key = v_dedupe and status = 'scheduled';
    end if;
  end loop;

  -- The template too, if asked: future months start unassigned. Only the series
  -- with occurrences IN this month; existing occurrences in OTHER months are
  -- untouched (we cleared only this month's). At a switch-ON studio nulling the
  -- template re-fires tg_assign_after_series; this is a tool for switch-OFF.
  if p_clear_templates then
    update class_series cs set instructor_id = null
     where cs.studio_id = p_studio_id and cs.instructor_id is not null
       and cs.id in (
         select distinct o.series_id from class_occurrences o
          where o.studio_id = p_studio_id and o.series_id is not null
            and (o.starts_at at time zone v_tz)::date between v_month_start and v_month_end);
    get diagnostics v_templates = row_count;
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (p_studio_id, auth.uid(), 'month.assignments_cleared', 'studios', p_studio_id,
          jsonb_build_object('month', v_month_start, 'cleared', v_count,
                             'templates_cleared', v_templates, 'clear_templates', p_clear_templates,
                             'acknowledged', (v_published and v_has_bookings)));

  return jsonb_build_object('ok', true, 'cleared', v_count, 'templates_cleared', v_templates,
                            'month', to_char(v_month_start, 'FMMonth YYYY'));
end $$;
revoke execute on function clear_month_assignments(uuid, date, boolean, boolean) from public, anon;
grant  execute on function clear_month_assignments(uuid, date, boolean, boolean) to authenticated, service_role;

-- The anon surface is unchanged — exactly TWELVE pre-login functions.
do $$
declare v_anon int;
begin
  select count(*) into v_anon
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not in ('expect_num','expect_text','expect_true','expect_false','login','sig','psig');
  if v_anon <> 12 then
    raise exception 'anon surface is % functions, expected exactly 12', v_anon;
  end if;
end $$;
