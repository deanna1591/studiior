-- 155: B — narrowing availability must not silently strand a class.
--
-- An instructor drops Tuesday mornings from their standing pattern. It takes
-- effect immediately (the pattern writes approval_status='approved'), nothing
-- tells the studio, and they stay assigned to Tuesday's 08:00 class — staff find
-- out when nobody turns up. Narrowing availability and dropping a class are two
-- different acts (one is about future months, the other about a class next
-- Tuesday) and until now the first silently implied the second and nothing
-- noticed.
--
-- The class is NOT unstaffed — someone still has to teach it and silently opening
-- it would be worse. Instead: when a standing-pattern edit leaves the instructor
-- still ASSIGNED to future classes now OUTSIDE their availability, tell staff
-- (a notification, and a visible list with a route to reassign or open each) and
-- tell the instructor what they are still holding ("still yours unless you ask
-- for cover"). The month-submission path is unchanged — refusing a non-manager
-- on an approved month is correct.

insert into notification_templates (key, subject, text_body, html_body, note) values
('availability_narrowed_instructor',
 'You still hold {count} class{plural} in hours you just removed',
 E'Hi {instructor_name},\n\nYou have narrowed your availability, but you are still down to teach {count} class{plural} in the hours you removed:\n\n{lines}\n\nThey are still yours unless you ask the studio for cover — narrowing your availability does not take you off a class you are already assigned to.',
 '<p>Hi {instructor_name},</p><p>You have narrowed your availability, but you are still down to teach <strong>{count}</strong> class{plural} in the hours you removed:</p><pre style="font:inherit">{lines}</pre><p>They are still yours unless you ask the studio for cover — narrowing your availability does not take you off a class you are already assigned to.</p>',
 'Migration 155. To the instructor when a standing-pattern edit leaves them '
 'assigned to future classes outside their new availability.'),
('availability_narrowed_staff',
 '{instructor_name} has narrowed their availability',
 E'{instructor_name} has narrowed their availability and is still down to teach {count} class{plural} in the hours they removed:\n\n{lines}\n\nThey stay assigned until you act — reassign each or open it as a shift.',
 '<p><strong>{instructor_name}</strong> has narrowed their availability and is still down to teach <strong>{count}</strong> class{plural} in the hours they removed:</p><pre style="font:inherit">{lines}</pre><p>They stay assigned until you act — reassign each or open it as a shift.</p>',
 'Migration 155. To managers, same weight as an unstaffed class.')
on conflict (key) do nothing;

-- The one predicate a staff surface reads: future scheduled classes whose
-- assigned instructor is no longer available for them. Derived, always fresh —
-- there is no stored "conflict" to drift.
create or replace function availability_conflicts(p_studio_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_tz text; v_res jsonb;
begin
  if not coalesce(is_manager_up(p_studio_id), false) and not is_service_context() then
    raise exception 'only owners and managers see availability conflicts' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;

  select coalesce(jsonb_agg(x order by x.starts_at), '[]'::jsonb) into v_res
  from (
    select o.id as occurrence_id, o.name, o.starts_at, o.booked_count as booked,
           to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMonth, HH24:MI') as local_when,
           o.instructor_id, i.display_name as instructor_name, r.name as room
      from class_occurrences o
      join instructors i on i.id = o.instructor_id
      left join rooms r on r.id = o.room_id
     where o.studio_id = p_studio_id and o.status = 'scheduled'
       and o.instructor_id is not null and o.starts_at > now()
       and not instructor_available_at(o.instructor_id, o.starts_at, o.ends_at)
  ) x;

  return jsonb_build_object('conflicts', v_res, 'count', jsonb_array_length(v_res));
end $$;
revoke execute on function availability_conflicts(uuid) from public, anon;
grant execute on function availability_conflicts(uuid) to authenticated, service_role;

-- Re-issue the standing-pattern writer to detect and report the strand. The
-- write itself is unchanged; the tail computes what the edit orphaned and tells
-- both sides. Only fires when the instructor is left holding something.
create or replace function set_instructor_availability_rows(
  p_instructor_id  uuid,
  p_days           jsonb,
  p_effective_from date default null,
  p_effective_to   date default null
) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_studio uuid; v_tz text;
  v_from   date := p_effective_from;
  v_to     date := p_effective_to;
  d        jsonb; r jsonb; v_day int; n int := 0;
  v_name text; v_user uuid; v_lines text; v_count int; v_fp text;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then
    raise exception 'no such instructor' using errcode = 'PT404';
  end if;
  if not is_manager_up(v_studio)
     and p_instructor_id is distinct from auth_instructor_id(v_studio) then
    raise exception 'only the studio or the instructor may set their availability'
      using errcode = 'PT403';
  end if;
  if v_to is not null and v_from is not null and v_to < v_from then
    raise exception 'the pattern ends before it starts' using errcode = 'PT422';
  end if;

  delete from instructor_availability
   where instructor_id = p_instructor_id
     and day_of_week is not null
     and day_of_week in (
       select (x ->> 'day')::int from jsonb_array_elements(p_days) x);

  for d in select * from jsonb_array_elements(p_days) loop
    v_day := (d ->> 'day')::int;
    if v_day is null or v_day < 0 or v_day > 6 then
      raise exception 'day_of_week must be 0-6, got %', d ->> 'day' using errcode = 'PT422';
    end if;
    for r in select * from jsonb_array_elements(coalesce(d -> 'ranges', '[]'::jsonb)) loop
      if (r ->> 'to')::time <= (r ->> 'from')::time then
        raise exception 'a range must end after it starts (day %, % to %)',
          v_day, r ->> 'from', r ->> 'to' using errcode = 'PT422';
      end if;
      insert into instructor_availability
        (studio_id, instructor_id, day_of_week, starts_at_time, ends_at_time,
         effective_from, effective_to, is_available, created_by)
      values (v_studio, p_instructor_id, v_day,
              (r ->> 'from')::time, (r ->> 'to')::time,
              v_from, v_to, true, auth.uid());
      n := n + 1;
    end loop;
  end loop;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (v_studio, auth.uid(), 'availability.set', 'instructors', p_instructor_id,
          jsonb_build_object('days', p_days, 'effective_from', v_from,
                             'effective_to', v_to, 'ranges_written', n));

  -- B: what the new pattern leaves stranded — future classes the instructor is
  -- STILL assigned to but is no longer available for (studio-local time in the
  -- lines). instructor_available_at reads the new pattern (and honours an
  -- approved month submission, which wins for its days), so a class covered by
  -- an approved submission is not counted.
  select timezone into v_tz from studios where id = v_studio;
  select count(*)::int,
         string_agg('  ' || to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMon, HH24:MI')
                    || ' — ' || o.name, E'\n' order by o.starts_at),
         md5(string_agg(o.id::text, ',' order by o.id))
    into v_count, v_lines, v_fp
    from class_occurrences o
   where o.studio_id = v_studio and o.instructor_id = p_instructor_id
     and o.status = 'scheduled' and o.starts_at > now()
     and not instructor_available_at(p_instructor_id, o.starts_at, o.ends_at);

  if coalesce(v_count, 0) > 0 then
    select display_name into v_name from instructors where id = p_instructor_id;
    -- The instructor, told what they are still holding.
    v_user := instructor_user_id(p_instructor_id);
    if v_user is not null then
      perform queue_shift_notice(v_studio, v_user, 'availability_narrowed_instructor',
        jsonb_build_object('instructor_name', coalesce(v_name, 'there'),
          'count', v_count, 'plural', case when v_count = 1 then '' else 'es' end,
          'lines', v_lines),
        'avail_narrowed_i:' || p_instructor_id || ':' || v_fp);
    end if;
    -- Staff, same weight as an unstaffed class.
    perform queue_shift_notice_to_staff(v_studio, 'availability_narrowed_staff',
      jsonb_build_object('instructor_name', coalesce(v_name, 'An instructor'),
        'count', v_count, 'plural', case when v_count = 1 then '' else 'es' end,
        'lines', v_lines),
      'avail_narrowed_s:' || p_instructor_id || ':' || v_fp);
  end if;

  return n;
end $$;
-- _rows stays an internal: only the set_instructor_availability wrapper calls it
-- (710000 closed it to every client role), so re-assert that after this re-issue.
revoke execute on function set_instructor_availability_rows(uuid, jsonb, date, date) from public, anon, authenticated;
grant execute on function set_instructor_availability_rows(uuid, jsonb, date, date) to service_role;

do $$
begin
  if has_function_privilege('anon', 'availability_conflicts(uuid)', 'execute') then
    raise exception 'migration 155: availability_conflicts is anon-callable';
  end if;
end $$;
