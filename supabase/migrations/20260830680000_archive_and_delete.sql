-- =============================================================================
-- Migration 058: archive and delete for class types, rooms and instructors
-- =============================================================================
-- All three have carried a `status` column since migration 001. Two things were
-- true of it and neither was obvious from reading the schema:
--
--   1. NO MEMBER-FACING POLICY HAS EVER LOOKED AT IT. Asked as a real member
--      session: an archived instructor, class type and room are all fully
--      readable, including the instructor's bio. The /book filter pills happen
--      to filter in the query, and the class detail screen joins through the
--      occurrence and does not — so archiving hid a class type from one screen
--      and left it on another. Same shape as instructor_availability having no
--      writer: the column was there, the enforcement was not.
--
--   2. DELETE ALREADY "WORKED", AND THAT IS THE PROBLEM. Every FK onto these
--      tables is ON DELETE SET NULL, so deleting an instructor does not fail —
--      it succeeds and silently strips them from every past class. Proved:
--      deleting Bo Fictitious took his name off 394 occurrences and returned
--      DELETE 1. A studio tidying up their instructor list loses their history
--      and is told nothing.
--
-- `status` is also unconstrained text, so 'Archived', 'inactive' or a typo all
-- store happily and behave like neither state.
-- =============================================================================

update class_types  set status = 'active' where status not in ('active','archived');
update rooms        set status = 'active' where status not in ('active','archived');
update instructors  set status = 'active' where status not in ('active','archived');

alter table class_types  drop constraint if exists class_types_status_known;
alter table rooms        drop constraint if exists rooms_status_known;
alter table instructors  drop constraint if exists instructors_status_known;
alter table class_types  add constraint class_types_status_known  check (status in ('active','archived'));
alter table rooms        add constraint rooms_status_known        check (status in ('active','archived'));
alter table instructors  add constraint instructors_status_known  check (status in ('active','archived'));

-- -----------------------------------------------------------------------------
-- Archived is invisible to members, and the policy is what makes it so
-- -----------------------------------------------------------------------------
-- In the POLICY rather than in the screens, because there are eight places the
-- member app reads these three tables and a rule that lives in eight queries is
-- a rule the ninth will not have. Each of these degrades into a path the app
-- already handles: a null instructor join is Decision 17's "no instructor yet"
-- (which deliberately shows nothing rather than "TBC"), a null class type is
-- the no-description case, and a null room omits the room line.
--
-- The cost, stated: a member looking at a class taught by a since-archived
-- instructor sees no instructor name. That is the intended reading of "hidden
-- from members entirely", and it is better than a name the studio has retired.
drop policy if exists class_types_member_read on class_types;
create policy class_types_member_read on class_types for select
  using (studio_id in (select auth_member_studios()) and status <> 'archived');

drop policy if exists rooms_member_read on rooms;
create policy rooms_member_read on rooms for select
  using (studio_id in (select auth_member_studios()) and status <> 'archived');

drop policy if exists instructors_member_read on instructors;
create policy instructors_member_read on instructors for select
  using (studio_id in (select auth_member_studios()) and status <> 'archived');

-- -----------------------------------------------------------------------------
-- What archiving will do, before anyone confirms it
-- -----------------------------------------------------------------------------
create or replace function archive_impact(p_kind text, p_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_studio uuid; v_name text; v_tz text;
  v_future int := 0; v_past int := 0; v_series int := 0;
  v_booked int := 0; v_earliest timestamptz; v_blocked boolean := false;
  v_effect text; v_reason text;
begin
  if p_kind = 'class_type' then
    select studio_id, name into v_studio, v_name from class_types where id = p_id;
  elsif p_kind = 'room' then
    select studio_id, name into v_studio, v_name from rooms where id = p_id;
  elsif p_kind = 'instructor' then
    select studio_id, display_name into v_studio, v_name from instructors where id = p_id;
  else
    raise exception 'kind must be class_type, room or instructor' using errcode = 'PT422';
  end if;
  if v_studio is null then
    raise exception 'no such record' using errcode = 'PT404';
  end if;
  if not is_manager_up(v_studio) then
    raise exception 'only owners and managers may archive' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = v_studio;

  select count(*) filter (where o.starts_at >  now() and o.status = 'scheduled'),
         count(*) filter (where o.starts_at <= now()),
         coalesce(sum(o.booked_count) filter (where o.starts_at > now() and o.status = 'scheduled'), 0),
         min(o.starts_at) filter (where o.starts_at > now() and o.status = 'scheduled')
    into v_future, v_past, v_booked, v_earliest
    from class_occurrences o
   where (p_kind = 'class_type' and o.class_type_id = p_id)
      or (p_kind = 'room'       and o.room_id       = p_id)
      or (p_kind = 'instructor' and o.instructor_id = p_id);

  select count(*) into v_series from class_series cs
   where cs.status = 'active'
     and ((p_kind = 'class_type' and cs.class_type_id = p_id)
       or (p_kind = 'room'       and cs.room_id       = p_id)
       or (p_kind = 'instructor' and cs.instructor_id = p_id));

  -- The three answers, and they differ because the situations differ.
  if p_kind = 'class_type' then
    -- Those classes still run. Archiving stops it being chosen for NEW ones,
    -- which means the recurring series that would keep making them has to stop
    -- too — a series that goes on materialising an archived type every night is
    -- the archive not having happened.
    v_effect := case when v_series > 0
      then format('%s scheduled class%s will still run. %s recurring series will stop making new ones.',
                  v_future, case when v_future = 1 then '' else 'es' end, v_series)
      else format('%s scheduled class%s will still run.',
                  v_future, case when v_future = 1 then '' else 'es' end) end;

  elsif p_kind = 'instructor' then
    -- The dangerous one. An archived instructor silently teaching next Tuesday
    -- is the worst outcome, so the classes are OPENED rather than left assigned
    -- — Decision 17's open shift is a real state the calendar hatches, the
    -- brief escalates and other instructors can apply for. Refusing instead
    -- would mean a studio cannot archive somebody who has already left, which
    -- is exactly when they need to.
    v_effect := case when v_future > 0
      then format('%s is teaching %s class%s. Archiving leaves %s unstaffed and open for another instructor to pick up%s.',
                  v_name, v_future, case when v_future = 1 then '' else 'es' end,
                  case when v_future = 1 then 'it' else 'them' end,
                  case when v_booked > 0
                       then format(' — %s member%s already booked', v_booked,
                                   case when v_booked = 1 then ' is' else 's are' end)
                       else '' end)
      else format('%s is not teaching anything upcoming.', v_name) end;

  else -- room
    -- REFUSED while classes are in it, and this is the one place archiving is
    -- blocked rather than warned. There is no "open room" state: nulling
    -- room_id would free the slot for a double-booking the exclusion constraint
    -- can no longer catch, and which other room a class should move to is a
    -- decision only the studio can make.
    if v_future > 0 then
      v_blocked := true;
      v_reason := format('%s has %s class%s scheduled in it, the first on %s. Move or cancel %s first.',
                         v_name, v_future, case when v_future = 1 then '' else 'es' end,
                         to_char(v_earliest at time zone v_tz, 'FMDay FMDD FMMonth'),
                         case when v_future = 1 then 'it' else 'them' end);
    end if;
    v_effect := case when v_blocked then v_reason
                     else format('Nothing is scheduled in %s.', v_name) end;
  end if;

  return jsonb_build_object(
    'kind', p_kind, 'id', p_id, 'name', v_name,
    'future_classes', v_future, 'past_classes', v_past,
    'active_series', v_series, 'members_booked', v_booked,
    'earliest', v_earliest,
    'blocked', v_blocked, 'blocked_reason', v_reason,
    'effect', v_effect,
    -- Anything with consequences has to be shown before it is done.
    'requires_confirmation', (v_future > 0 or v_series > 0));
end $$;

-- -----------------------------------------------------------------------------
-- Archiving
-- -----------------------------------------------------------------------------
-- Two-step wherever there are consequences, the same shape as
-- move_occurrence(): the first call REFUSES and returns what will happen, the
-- caller shows it, the second call does it. A studio must never find out what
-- archiving did by watching it happen.
create or replace function archive_record(
  p_kind text, p_id uuid, p_confirm boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_impact jsonb; v_studio uuid; v_name text; v_opened int := 0;
  v_series int := 0; v_withdrawn int := 0;
begin
  v_impact := archive_impact(p_kind, p_id);

  if (v_impact ->> 'blocked')::boolean then
    return jsonb_build_object('ok', false, 'blocked', true,
      'reason', v_impact ->> 'blocked_reason', 'impact', v_impact);
  end if;
  if (v_impact ->> 'requires_confirmation')::boolean and not p_confirm then
    return jsonb_build_object('ok', false, 'requires_confirmation', true,
      'effect', v_impact ->> 'effect', 'impact', v_impact);
  end if;

  -- Transaction-local, so it cannot leak into another statement on the same
  -- connection. guard_archive_path() looks for exactly this.
  perform set_config('studiior.archiving', '1', true);

  if p_kind = 'class_type' then
    update class_types set status = 'archived' where id = p_id
      returning studio_id, name into v_studio, v_name;
    update class_series set status = 'ended'
     where class_type_id = p_id and status = 'active';
    get diagnostics v_series = row_count;

  elsif p_kind = 'room' then
    update rooms set status = 'archived' where id = p_id
      returning studio_id, name into v_studio, v_name;
    update class_series set status = 'ended'
     where room_id = p_id and status = 'active';
    get diagnostics v_series = row_count;

  else
    update instructors set status = 'archived' where id = p_id
      returning studio_id, display_name into v_studio, v_name;

    -- Future classes become open shifts. Not cancelled: the members booked into
    -- them are still coming and the studio still owes them a class.
    update class_occurrences
       set instructor_id = null, staffing = 'open', updated_at = now()
     where instructor_id = p_id and starts_at > now() and status = 'scheduled';
    get diagnostics v_opened = row_count;

    update class_series set instructor_id = null
     where instructor_id = p_id and status = 'active';
    get diagnostics v_series = row_count;

    -- Anything they had in flight is moot the moment they are archived.
    update shift_applications set status = 'withdrawn', decided_at = now()
     where instructor_id = p_id and status = 'pending';
    get diagnostics v_withdrawn = row_count;
    update cover_requests set status = 'withdrawn'
     where instructor_id = p_id and status = 'pending';
    update instructor_commitments set status = 'ended'
     where instructor_id = p_id and status = 'active';

    -- Loudly, and only when there is something to be loud about.
    if v_opened > 0 then
      perform queue_shift_notice_to_staff(v_studio, 'instructor_archived',
        jsonb_build_object(
          'instructor_name', v_name,
          'count', v_opened,
          'booked_line', case when (v_impact ->> 'members_booked')::int > 0
            then format('%s member%s already booked into them.',
                        v_impact ->> 'members_booked',
                        case when (v_impact ->> 'members_booked')::int = 1 then ' is' else 's are' end)
            else 'Nobody is booked into them yet.' end,
          'shifts_url', '/shifts/applications'),
        'instructor_archived:' || p_id || ':' || extract(epoch from now())::bigint);
    end if;
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (v_studio, auth.uid(), 'record.archived',
          case p_kind when 'class_type' then 'class_types'
                      when 'room' then 'rooms' else 'instructors' end,
          p_id, v_impact || jsonb_build_object('opened', v_opened, 'series_stopped', v_series));

  return jsonb_build_object('ok', true, 'kind', p_kind, 'name', v_name,
    'classes_opened', v_opened, 'series_stopped', v_series,
    'applications_withdrawn', v_withdrawn, 'impact', v_impact);
end $$;

create or replace function restore_record(p_kind text, p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_studio uuid; v_name text;
begin
  if p_kind = 'class_type' then
    update class_types set status = 'active' where id = p_id
      returning studio_id, name into v_studio, v_name;
  elsif p_kind = 'room' then
    update rooms set status = 'active' where id = p_id
      returning studio_id, name into v_studio, v_name;
  elsif p_kind = 'instructor' then
    update instructors set status = 'active' where id = p_id
      returning studio_id, display_name into v_studio, v_name;
  else
    raise exception 'kind must be class_type, room or instructor' using errcode = 'PT422';
  end if;
  if v_studio is null then
    raise exception 'no such record' using errcode = 'PT404';
  end if;
  if not is_manager_up(v_studio) then
    raise exception 'only owners and managers may restore' using errcode = 'PT403';
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (v_studio, auth.uid(), 'record.restored',
          case p_kind when 'class_type' then 'class_types'
                      when 'room' then 'rooms' else 'instructors' end,
          p_id, jsonb_build_object('name', v_name));

  -- Deliberately does NOT put an instructor back on the classes archiving
  -- opened. Somebody may have applied for them, or been given them, in between
  -- — silently taking a class back off the person now teaching it would be a
  -- second surprise on top of the first.
  return jsonb_build_object('ok', true, 'kind', p_kind, 'name', v_name,
    'note', case when p_kind = 'instructor'
                 then 'Any classes that were opened stay open. Assign them if you want them back.'
                 else null end);
end $$;

-- -----------------------------------------------------------------------------
-- Delete refuses when anything points at it
-- -----------------------------------------------------------------------------
-- Triggers rather than checks at the call sites, the same shape as
-- guard_plan_delete: every FK here is ON DELETE SET NULL, so without a guard
-- the delete SUCCEEDS and quietly empties the history instead of failing.
create or replace function guard_class_type_delete() returns trigger
language plpgsql set search_path = public as $$
declare n_occ int; n_ser int;
begin
  select count(*) into n_occ from class_occurrences where class_type_id = old.id;
  select count(*) into n_ser from class_series      where class_type_id = old.id;
  if n_occ > 0 or n_ser > 0 then
    raise exception '"%" has % class(es) and % series and cannot be deleted',
      old.name, n_occ, n_ser
      using errcode = 'PT409',
            hint = 'Archive it instead. Past classes keep their type, and it '
                   'stops being available for new ones.';
  end if;
  return old;
end $$;

create or replace function guard_room_delete() returns trigger
language plpgsql set search_path = public as $$
declare n_occ int; n_ser int;
begin
  select count(*) into n_occ from class_occurrences where room_id = old.id;
  select count(*) into n_ser from class_series      where room_id = old.id;
  if n_occ > 0 or n_ser > 0 then
    raise exception '"%" has % class(es) and % series in it and cannot be deleted',
      old.name, n_occ, n_ser
      using errcode = 'PT409',
            hint = 'Archive it instead. Past classes keep the room they were in.';
  end if;
  return old;
end $$;

create or replace function guard_instructor_delete() returns trigger
language plpgsql set search_path = public as $$
declare n_occ int; n_sub int; n_ser int;
begin
  select count(*) into n_occ from class_occurrences where instructor_id = old.id;
  select count(*) into n_sub from class_occurrences where substitute_for = old.id;
  select count(*) into n_ser from class_series      where instructor_id = old.id;
  if n_occ > 0 or n_sub > 0 or n_ser > 0 then
    raise exception '% has taught % class(es) and cannot be deleted',
      old.display_name, n_occ + n_sub
      using errcode = 'PT409',
            hint = 'Archive them instead. Deleting would take their name off '
                   'every class they have ever taught — the foreign keys are '
                   'ON DELETE SET NULL, so it would succeed and say nothing.';
  end if;
  return old;
end $$;

drop trigger if exists class_types_delete_guard on class_types;
create trigger class_types_delete_guard before delete on class_types
  for each row execute function guard_class_type_delete();
drop trigger if exists rooms_delete_guard on rooms;
create trigger rooms_delete_guard before delete on rooms
  for each row execute function guard_room_delete();
drop trigger if exists instructors_delete_guard on instructors;
create trigger instructors_delete_guard before delete on instructors
  for each row execute function guard_instructor_delete();

insert into notification_templates (key, subject, text_body, html_body, note) values
('instructor_archived',
 '{instructor_name} has been archived — {count} class(es) need an instructor',
 E'Hi {first_name},\n\n{instructor_name} has been archived, and the {count} class(es) they were teaching are now open shifts.\n\n{booked_line}\n\nAssign someone, or let instructors apply: {shifts_url}',
 E'<p>Hi {first_name},</p><p><strong>{instructor_name}</strong> has been archived, and the {count} class(es) they were teaching are now open shifts.</p><p>{booked_line}</p><p><a href="{shifts_url}">Assign someone, or let instructors apply</a></p>',
 'Decision 18-adjacent: archiving an instructor with future classes leaves them unstaffed, which is loud by design.')
on conflict (key) do nothing;

revoke execute on function archive_impact(text, uuid)             from public, anon, authenticated;
revoke execute on function archive_record(text, uuid, boolean)    from public, anon, authenticated;
revoke execute on function restore_record(text, uuid)             from public, anon, authenticated;
revoke execute on function guard_class_type_delete()              from public, anon, authenticated;
revoke execute on function guard_room_delete()                    from public, anon, authenticated;
revoke execute on function guard_instructor_delete()              from public, anon, authenticated;
grant execute on function archive_impact(text, uuid)          to authenticated, service_role;
grant execute on function archive_record(text, uuid, boolean) to authenticated, service_role;
grant execute on function restore_record(text, uuid)          to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Archiving cannot be done round the side
-- -----------------------------------------------------------------------------
-- All three edit forms already offered "Archived" in a plain <select> that
-- writes `status` directly. That path skips every consequence archive_record()
-- exists to handle: no preview, no counts, no opening of the classes, no email
-- to the managers, and no refusal for a room that still has classes in it. A
-- manager archiving an instructor from the form would have left her silently
-- teaching next Tuesday, which is the exact outcome this work is meant to
-- prevent.
--
-- Removing the option from the form is not enough — the same UPDATE goes
-- straight through PostgREST. So the rule lives here: archiving is only legal
-- inside archive_record(), which sets a transaction-local flag before it
-- writes. Restoring is left open, because restoring has no consequences to
-- skip.
create or replace function guard_archive_path() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.status = 'archived' and old.status <> 'archived'
     and coalesce(current_setting('studiior.archiving', true), '') <> '1' then
    raise exception 'archive through archive_record(), not by setting status'
      using errcode = 'PT409',
            hint = 'archive_record() reports what will happen first, opens any '
                   'classes the instructor was teaching, tells the managers, '
                   'and refuses a room that still has classes in it.';
  end if;
  return new;
end $$;

drop trigger if exists class_types_archive_path on class_types;
create trigger class_types_archive_path before update of status on class_types
  for each row execute function guard_archive_path();
drop trigger if exists rooms_archive_path on rooms;
create trigger rooms_archive_path before update of status on rooms
  for each row execute function guard_archive_path();
drop trigger if exists instructors_archive_path on instructors;
create trigger instructors_archive_path before update of status on instructors
  for each row execute function guard_archive_path();

revoke execute on function guard_archive_path() from public, anon, authenticated;
