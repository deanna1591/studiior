-- re-issues: force_commit_occurrence(uuid, text)
-- =============================================================================
-- Decision 72 (b) — "Run anyway" tells the instructor.
--
-- force_commit_occurrence (Decision 22's UI) makes a below-minimum class run; it
-- had no notification, so the instructor learned nothing. It now queues the
-- existing core_committed notice to the assigned instructor — if they have an
-- app login — after the commit, carrying occurrence_id, built exactly the way
-- tg_core_reached_minimum (20260831430000, the one other core_committed sender)
-- builds it. No new template.
--
-- queue_shift_notice and instructor_user_id are service-role-only, but this
-- function is SECURITY DEFINER owned by postgres, so it may call them the way
-- the sweeps do. Re-issued from the 20260830910000 body with only the notify
-- block added before the return; ACL re-asserted (anon=false, authed=true).
-- =============================================================================

create or replace function force_commit_occurrence(p_occurrence_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare o class_occurrences%rowtype; v_booked int; s studios%rowtype;
        v_user uuid; v_name text;
begin
  select * into o from class_occurrences where id = p_occurrence_id for update;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(o.studio_id), false) then
    raise exception 'only owners and managers force a class to run' using errcode = 'PT403';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'say why — a forced commitment with no reason is one nobody can explain'
      using errcode = 'PT422';
  end if;
  if o.committed_at is not null then
    raise exception '"%" is already committed', o.name using errcode = 'PT409';
  end if;

  select count(*)::int into v_booked from bookings
   where occurrence_id = p_occurrence_id
     and status in ('booked','attended','no_show','pending_payment');

  -- Reviving a class that was cancelled brings back its slot and its room, so
  -- it goes back to 'scheduled' explicitly rather than only gaining a latch.
  update class_occurrences
     set status = 'scheduled', committed_at = now(), booked_at_cutoff = v_booked,
         cancelled_at = null, cancellation_cause = null, cancellation_pays = null,
         updated_at = now()
   where id = p_occurrence_id;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (o.studio_id, auth.uid(), 'occurrence.force_committed', 'class_occurrences',
          p_occurrence_id,
          jsonb_build_object('status', o.status, 'cause', o.cancellation_cause,
                             'booked_at_cutoff', o.booked_at_cutoff),
          jsonb_build_object('reason', btrim(p_reason), 'booked_at_cutoff', v_booked,
                             'at', now()));

  -- Decision 72(b): tell the assigned instructor it is confirmed to run. The
  -- instructor does not change on a force-commit, so o.instructor_id is the
  -- assignee; only an instructor WITH a login can be reached. Same core_committed
  -- payload tg_core_reached_minimum builds, plus occurrence_id, same dedupe key.
  if o.instructor_id is not null then
    v_user := instructor_user_id(o.instructor_id);
    if v_user is not null then
      select * into s from studios where id = o.studio_id;
      select display_name into v_name from instructors where id = o.instructor_id;
      perform queue_shift_notice(o.studio_id, v_user, 'core_committed',
        jsonb_build_object(
          'instructor_name', coalesce(v_name, 'there'),
          'studio_name', s.name,
          'class_name', o.name,
          'occurrence_id', p_occurrence_id,
          'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMon, HH24:MI'),
          'booked_line', case when v_booked = 1 then '1 booked.'
                              else v_booked || ' booked.' end),
        'core_committed:' || p_occurrence_id || ':' || o.instructor_id
          || ':' || extract(epoch from o.starts_at)::bigint);
    end if;
  end if;

  return jsonb_build_object('ok', true, 'occurrence_id', p_occurrence_id,
    'booked_at_cutoff', v_booked, 'reason', btrim(p_reason));
end $$;

revoke execute on function force_commit_occurrence(uuid, text) from public, anon;
grant  execute on function force_commit_occurrence(uuid, text) to authenticated, service_role;
