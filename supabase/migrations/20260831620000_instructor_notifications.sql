-- =============================================================================
-- 157 — In-app notifications for the instructor portal, and the two readers the
--       rebuilt portal needs (pending claims for My schedule; the notification
--       list + unread count for the bell).
--
-- Everything built over the last week reaches an instructor by EMAIL only —
-- assignment, cover, roster publication, flex decisions, approval and decline
-- of a claim, availability reminders. An instructor who deletes the email has
-- no way to see it again. The `notifications` table already holds every one of
-- those rows (recipient_type='staff', user_id = the instructor's login), so the
-- portal only needs to READ them per instructor and remember which were seen.
--
-- READ STATE is the one new fact: a nullable `read_at` on `notifications`. It is
-- stamped when the instructor opens the list, so the bell counts what has
-- arrived since they last looked. Backfilled to NULL — the first visit clears
-- the backlog, which is the honest behaviour for a state added after the fact.
-- =============================================================================

alter table notifications add column if not exists read_at timestamptz;

-- An instructor's notices are the rows addressed to their own login and studio.
-- SECURITY DEFINER because notifications is closed to clients (manager-up RLS);
-- the guard is the same shape as every other instructor reader — the instructor
-- themselves, a manager of their studio, or a background job.
create or replace function instructor_notifications(
  p_instructor_id uuid, p_limit int default 40
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_user uuid;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;
  if not is_manager_up(v_studio)
     and p_instructor_id is distinct from auth_instructor_id(v_studio)
     and not is_service_context() then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;

  v_user := instructor_user_id(p_instructor_id);
  if v_user is null then
    -- No login, so nothing was ever addressed to them.
    return jsonb_build_object('unread', 0, 'items', '[]'::jsonb);
  end if;

  return jsonb_build_object(
    'unread', (
      select count(*) from notifications n
       where n.user_id = v_user and n.studio_id = v_studio
         and n.channel = 'email' and n.status <> 'failed' and n.read_at is null),
    'items', coalesce((
      select jsonb_agg(row_to_json(x)) from (
        select n.id, n.template_key, n.payload, n.created_at,
               (n.read_at is not null) as read
          from notifications n
         where n.user_id = v_user and n.studio_id = v_studio
           and n.channel = 'email' and n.status <> 'failed'
         order by n.created_at desc
         limit greatest(p_limit, 1)
      ) x), '[]'::jsonb)
  );
end $$;

-- Stamps every unseen notice read. Self or a background job only — a manager has
-- no business clearing somebody else's unread count.
create or replace function mark_instructor_notifications_read(p_instructor_id uuid)
returns int
language plpgsql security definer set search_path = public as $$
declare v_studio uuid; v_user uuid; v_n int;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;
  if p_instructor_id is distinct from auth_instructor_id(v_studio)
     and not is_service_context() then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;
  v_user := instructor_user_id(p_instructor_id);
  if v_user is null then return 0; end if;

  update notifications set read_at = now()
   where user_id = v_user and studio_id = v_studio
     and channel = 'email' and read_at is null;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- A claim that is waiting on the studio is NOT on the instructor's calendar yet
-- (the occurrence keeps instructor_id null until staff approve), so My schedule
-- cannot see it through instructor_week. This returns the instructor's pending
-- claims with the occurrence details, so the schedule can show them alongside
-- confirmed classes, marked pending — an instructor sees everything they are
-- holding and its state in one place.
create or replace function instructor_pending_claims(p_instructor_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_tz text;
begin
  select i.studio_id, s.timezone into v_studio, v_tz
    from instructors i join studios s on s.id = i.studio_id
   where i.id = p_instructor_id;
  if v_studio is null then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;
  if not is_manager_up(v_studio)
     and p_instructor_id is distinct from auth_instructor_id(v_studio)
     and not is_service_context() then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'occurrence_id', o.id,
      'name', o.name,
      'local_date',  to_char((o.starts_at at time zone v_tz)::date, 'YYYY-MM-DD'),
      'local_start', to_char(o.starts_at at time zone v_tz, 'HH24:MI'),
      'local_end',   to_char(o.ends_at   at time zone v_tz, 'HH24:MI'),
      'room_name',   r.name,
      'capacity',    o.capacity,
      'booked_count', o.booked_count
    ) order by o.starts_at)
    from shift_applications sa
    join class_occurrences o on o.id = sa.occurrence_id
    left join rooms r on r.id = o.room_id
   where sa.instructor_id = p_instructor_id
     and sa.status = 'pending'
     and o.status = 'scheduled'
     and o.starts_at >= now()
  ), '[]'::jsonb);
end $$;

revoke execute on function instructor_notifications(uuid, int)      from public, anon;
grant  execute on function instructor_notifications(uuid, int)      to authenticated, service_role;
revoke execute on function mark_instructor_notifications_read(uuid) from public, anon;
grant  execute on function mark_instructor_notifications_read(uuid) to authenticated, service_role;
revoke execute on function instructor_pending_claims(uuid)          from public, anon;
grant  execute on function instructor_pending_claims(uuid)          to authenticated, service_role;
