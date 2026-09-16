-- 151: reassign a class's instructor from the calendar, and tell both people.
--
-- The calendar's popover could assign an unstaffed class and open an assigned
-- one (migration 114), but not SWAP one instructor for another — which is at
-- least as common (somebody calls in sick, two people swap, a week is
-- rebalanced) and until now needed a drag in day view or a trip to the roster.
--
-- reassign_occurrence() puts a named instructor on a class that already has one,
-- through move_occurrence() so it is held to EXACTLY the same gate as a drag: the
-- validity window (hard), the room and double-booking exclusions, the
-- availability warning. move_occurrence already notifies the NEW instructor
-- (queue_instructor_assigned, itself gated on publication); this adds the other
-- half — the instructor taken OFF is told, through the same queue_ pattern and
-- gated on publication the same way, so being removed from a class you expected
-- to teach is not something you learn from a calendar.

insert into notification_templates (key, subject, text_body, html_body, note) values
('class_reassigned_off',
 'You are no longer teaching {class_name}',
 E'Hi {instructor_name},\n\n{studio_name} has taken you off {class_name} on {when} — {new_instructor} is teaching it now.\n\nIf that is a surprise, talk to them.',
 '<p>Hi {instructor_name},</p><p>{studio_name} has taken you off <strong>{class_name}</strong> on {when} — {new_instructor} is teaching it now.</p><p>If that is a surprise, talk to them.</p>',
 'Migration 151. Sent to the instructor reassign_occurrence() swaps OUT of a '
 'class. Publication-gated, like the assigned notice for the one swapped in.')
on conflict (key) do nothing;

create or replace function reassign_occurrence(p_occurrence_id uuid, p_instructor_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  o class_occurrences%rowtype; s studios%rowtype;
  v_old uuid; v_old_name text; v_new_name text; v_user uuid; v_when text;
  v_move jsonb; v_told boolean := false; v_reachable_removal boolean := false;
begin
  select * into o from class_occurrences where id = p_occurrence_id for update;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(o.studio_id), false) then
    raise exception 'only owners and managers change the timetable' using errcode = 'PT403';
  end if;
  if p_instructor_id is null then
    raise exception 'pick who is teaching it' using errcode = 'PT422';
  end if;
  v_old := o.instructor_id;

  -- The one gate. move_occurrence refuses outside the validity window, refuses a
  -- room or double-booking clash, warns on availability, and — because the new
  -- instructor differs from the old — notifies the one swapped IN. p_confirm is
  -- true because reassigning changes no time, so no member is emailed and there
  -- is no booked-members question to answer.
  v_move := move_occurrence(p_occurrence_id => p_occurrence_id,
                            p_instructor_id => p_instructor_id, p_confirm => true);
  if not coalesce((v_move ->> 'ok')::boolean, false) then
    return v_move;   -- the refusal, with blocked_by, passed straight back
  end if;

  -- Tell the instructor taken off — same queue_ pattern, publication-gated like
  -- the assigned notice. Skipped for a no-op (same person) or an empty slot, and
  -- for a draft month (nobody was told they had the class, so nobody is told it
  -- moved).
  if v_old is not null and v_old is distinct from p_instructor_id
     and month_published(o.studio_id, o.starts_at) then
    select * into s from studios where id = o.studio_id;
    select display_name into v_old_name from instructors where id = v_old;
    select display_name into v_new_name from instructors where id = p_instructor_id;
    v_when := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth, HH24:MI');
    v_user := instructor_user_id(v_old);
    v_reachable_removal := true;
    if v_user is not null then
      v_told := queue_shift_notice(o.studio_id, v_user, 'class_reassigned_off',
        jsonb_build_object(
          'instructor_name', coalesce(v_old_name, 'there'),
          'studio_name', s.name, 'class_name', o.name, 'when', v_when,
          'new_instructor', coalesce(v_new_name, 'someone else')),
        'reassigned_off:' || o.id || ':' || v_old || ':' || extract(epoch from o.starts_at)::bigint
      ) is not null;
    end if;
  end if;

  return jsonb_build_object(
    'ok', true, 'occurrence_id', p_occurrence_id,
    'new_instructor', coalesce((select display_name from instructors where id = p_instructor_id), 'them'),
    'removed_instructor', v_old_name,
    'removed_notified', v_told,
    -- true only when there WAS someone to tell (published, real old instructor)
    -- but they have no login — the screen says "tell them yourself".
    'removed_uncontactable', (v_reachable_removal and v_user is null));
end $$;

revoke execute on function reassign_occurrence(uuid, uuid) from public, anon;
grant  execute on function reassign_occurrence(uuid, uuid) to authenticated, service_role;

do $$
begin
  if has_function_privilege('anon', 'reassign_occurrence(uuid, uuid)', 'execute') then
    raise exception 'migration 151: reassign_occurrence is anon-callable';
  end if;
end $$;
