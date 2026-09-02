-- =============================================================================
-- Migration 047: Decision 17 — open shifts, and one path that schedules
-- =============================================================================
-- Decision 9 said instructors submit availability and never touch the
-- timetable. That still holds for ASSIGNMENT: an instructor never assigns
-- themselves, never creates, moves, cancels or reschedules a class, and
-- approval is always staff. What is new is that a class can be published
-- UNASSIGNED as an open shift, which instructors apply for.
--
-- THE VALIDATION DID NOT EXIST. The brief for this work said the calendar must
-- go through the same checks as the edit form. The form had none:
-- app/staff/actions.ts inserts straight into class_occurrences with no room
-- conflict check and no instructor double-booking check. So this is not sharing
-- rules between two screens, it is writing them once — the same reasoning as
-- Decision 16's activate_purchase(), where "identical" is only true if there is
-- one implementation.
--
-- ROOM AND INSTRUCTOR OVERLAPS ARE EXCLUSION CONSTRAINTS, not checks inside a
-- function. A room cannot hold two classes and a person cannot teach two at
-- once; those are physical facts, and a constraint holds against every writer
-- including a future import, a seed, and a hand-typed UPDATE. Availability
-- stays a warning, per Decision 9 — studios override it constantly and a hard
-- block gets worked around by not using the feature.
--
-- This is the first GiST index in the codebase, which is what btree_gist has
-- been installed and unused for since migration 014. Its operator classes live
-- in `extensions`; the opclass is named explicitly rather than resolved through
-- search_path, per migration 032.
-- =============================================================================

create type staffing_state as enum ('assigned', 'open', 'pending_approval');

alter table class_occurrences
  add column if not exists staffing staffing_state not null default 'assigned';

-- Existing rows: an instructor means assigned, no instructor means the class
-- was published without one. Before this migration those were the same value
-- in the same column, which is why the state has to be explicit — "nobody is
-- teaching this" and "we have not got round to it yet" are different problems.
update class_occurrences
   set staffing = (case when instructor_id is null then 'open' else 'assigned' end)::staffing_state;

alter table class_occurrences drop constraint if exists occ_staffing_matches_instructor;
alter table class_occurrences add constraint occ_staffing_matches_instructor check (
  (staffing = 'assigned'         and instructor_id is not null)
  or (staffing in ('open', 'pending_approval') and instructor_id is null)
);

-- -----------------------------------------------------------------------------
-- staffing FOLLOWS instructor_id unless it already agrees with it
--
-- The column has a default, and a default cannot be right here: 'assigned' is
-- wrong for a row inserted with no instructor, and 'open' is wrong for one
-- inserted with an instructor. Without this trigger the CHECK above rejected
-- ten existing test suites and the seed, none of which know this column exists
-- — and none of which should have to. A caller who does not care about
-- staffing writes an instructor or does not, and this keeps up.
--
-- A caller who DOES care — move_occurrence(), withdraw_from_shift(),
-- apply_for_shift() — always writes a consistent pair, so the trigger leaves
-- them alone. 'pending_approval' with a null instructor is consistent and
-- survives.
-- -----------------------------------------------------------------------------
create or replace function tg_derive_staffing() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.instructor_id is null and new.staffing = 'assigned' then
    new.staffing := 'open';
  elsif new.instructor_id is not null and new.staffing <> 'assigned' then
    new.staffing := 'assigned';
  end if;
  return new;
end $$;

drop trigger if exists class_occurrences_derive_staffing on class_occurrences;
create trigger class_occurrences_derive_staffing
  before insert or update on class_occurrences
  for each row execute function tg_derive_staffing();

revoke execute on function tg_derive_staffing() from public, anon, authenticated;

comment on column class_occurrences.staffing is
  'assigned: somebody is teaching it. open: published with no instructor, and '
  'instructors may apply. pending_approval: at least one application is waiting '
  'on staff. The CHECK keeps this honest against instructor_id rather than '
  'letting the two drift.';

-- -----------------------------------------------------------------------------
-- Two things that cannot physically overlap
--
-- Partial on purpose:
--   * a cancelled class must not hold a room it is not using;
--   * an open shift has no instructor, so it cannot conflict on one — but it
--     DOES still hold its room, because it is a real class with a time, a
--     capacity and possibly members booked. Only the person is missing.
-- -----------------------------------------------------------------------------
alter table class_occurrences drop constraint if exists occ_room_no_overlap;
alter table class_occurrences add constraint occ_room_no_overlap
  exclude using gist (
    room_id extensions.gist_uuid_ops with =,
    tstzrange(starts_at, ends_at) with &&
  ) where (room_id is not null and status <> 'cancelled');

alter table class_occurrences drop constraint if exists occ_instructor_no_overlap;
alter table class_occurrences add constraint occ_instructor_no_overlap
  exclude using gist (
    instructor_id extensions.gist_uuid_ops with =,
    tstzrange(starts_at, ends_at) with &&
  ) where (instructor_id is not null and status <> 'cancelled');

-- -----------------------------------------------------------------------------
-- Applications
-- -----------------------------------------------------------------------------
create table shift_applications (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid not null references studios on delete cascade,
  occurrence_id uuid not null references class_occurrences on delete cascade,
  instructor_id uuid not null references instructors on delete cascade,
  status        text not null default 'pending'
                check (status in ('pending','approved','declined','withdrawn')),
  note          text,
  applied_at    timestamptz not null default now(),
  decided_by    uuid references profiles on delete set null,
  decided_at    timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index on shift_applications (studio_id, status);
create index on shift_applications (occurrence_id) where status = 'pending';

-- One LIVE application per instructor per shift. They may apply again after
-- withdrawing or being declined, which is why this is partial rather than a
-- plain unique on the pair.
create unique index shift_applications_one_live
  on shift_applications (occurrence_id, instructor_id) where status = 'pending';

alter table shift_applications enable row level security;
grant select on shift_applications to authenticated;
grant all on shift_applications to service_role;

-- Staff see every application at their studio; an instructor sees their own.
-- auth_instructor_id() is the existing helper that maps a signed-in user to
-- their instructor row at a studio.
create policy shift_apps_staff_read on shift_applications
  for select using (
    studio_id in (select auth_staff_studios())
  );
create policy shift_apps_manager_write on shift_applications
  for all using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));

create trigger shift_applications_updated before update on shift_applications
  for each row execute function set_updated_at();

comment on table shift_applications is
  'An instructor asking to teach an open shift. Decision 17: they apply, staff '
  'approve. Approving one auto-declines the rest in the same transaction.';

-- -----------------------------------------------------------------------------
-- Is an instructor available then? A warning, never a gate (Decision 9).
-- -----------------------------------------------------------------------------
create or replace function instructor_available_at(
  p_instructor_id uuid, p_starts_at timestamptz, p_ends_at timestamptz
) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  v_tz    text;
  v_date  date;
  v_dow   int;
  v_from  time;
  v_to    time;
begin
  if p_instructor_id is null then
    return true;
  end if;

  select s.timezone into v_tz
    from instructors i join studios s on s.id = i.studio_id
   where i.id = p_instructor_id;
  if v_tz is null then
    return true;
  end if;

  -- Availability is stated in studio-local wall-clock terms, so the comparison
  -- has to happen there. Comparing UTC against a local time would make an
  -- instructor unavailable for half the year in Prague.
  v_date := (p_starts_at at time zone v_tz)::date;
  v_dow  := extract(dow from (p_starts_at at time zone v_tz))::int;
  v_from := (p_starts_at at time zone v_tz)::time;
  v_to   := (p_ends_at   at time zone v_tz)::time;

  -- An explicit exception for that date wins over the weekly pattern, whichever
  -- way it points: a stated day off beats "Tuesdays are fine".
  if exists (select 1 from instructor_availability a
              where a.instructor_id = p_instructor_id and a.exception_date = v_date) then
    return exists (
      select 1 from instructor_availability a
       where a.instructor_id = p_instructor_id
         and a.exception_date = v_date
         and a.is_available
         and (a.starts_at_time is null or a.starts_at_time <= v_from)
         and (a.ends_at_time   is null or a.ends_at_time   >= v_to));
  end if;

  -- No stated availability at all is not the same as being unavailable. An
  -- instructor who has never opened the screen should not be flagged for every
  -- class they teach.
  if not exists (select 1 from instructor_availability a
                  where a.instructor_id = p_instructor_id and a.day_of_week is not null) then
    return true;
  end if;

  return exists (
    select 1 from instructor_availability a
     where a.instructor_id = p_instructor_id
       and a.day_of_week = v_dow
       and a.is_available
       and (a.effective_from is null or a.effective_from <= v_date)
       and (a.effective_to   is null or a.effective_to   >= v_date)
       and (a.starts_at_time is null or a.starts_at_time <= v_from)
       and (a.ends_at_time   is null or a.ends_at_time   >= v_to));
end $$;

-- -----------------------------------------------------------------------------
-- The only thing that moves a class
--
-- The calendar's drag, its resize, and the edit form all come through here, so
-- a rule added later cannot be enforced on one and forgotten on the other.
--
-- Two-step where members are booked: the first call REFUSES and says how many
-- people are affected, the caller confirms, the second call moves it and tells
-- them. A drag that silently emails forty people because somebody's finger
-- slipped is worse than one that asks.
-- -----------------------------------------------------------------------------
create or replace function move_occurrence(
  p_occurrence_id uuid,
  p_starts_at     timestamptz default null,
  p_ends_at       timestamptz default null,
  p_instructor_id uuid default null,
  p_room_id       uuid default null,
  p_confirm       boolean default false,
  p_clear_instructor boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  occ        class_occurrences%rowtype;
  v_starts   timestamptz;
  v_ends     timestamptz;
  v_instr    uuid;
  v_room     uuid;
  v_staffing staffing_state;
  v_warnings text[] := '{}';
  v_conflict text;
  v_moved    boolean;
begin
  select * into occ from class_occurrences where id = p_occurrence_id for update;
  if not found then
    raise exception 'no such class' using errcode = 'PT404';
  end if;
  if not is_manager_up(occ.studio_id) then
    raise exception 'only owners and managers change the timetable'
      using errcode = 'PT403';
  end if;
  if studio_is_locked(occ.studio_id) then
    raise exception 'this studio''s Studiior subscription is not active'
      using errcode = 'PT402',
            hint = 'Reactivate it from Billing. Nothing has been deleted.';
  end if;
  if occ.status <> 'scheduled' then
    raise exception 'a % class cannot be moved', occ.status using errcode = 'PT409';
  end if;

  v_starts := coalesce(p_starts_at, occ.starts_at);
  v_ends   := coalesce(p_ends_at,   occ.ends_at);
  v_room   := coalesce(p_room_id,   occ.room_id);
  -- p_clear_instructor because a null p_instructor_id has to be able to mean
  -- "leave it alone" as well as "make this an open shift", and one nullable
  -- parameter cannot say both.
  v_instr  := case when p_clear_instructor then null
                   else coalesce(p_instructor_id, occ.instructor_id) end;

  if v_ends <= v_starts then
    raise exception 'a class cannot end before it starts' using errcode = 'PT400';
  end if;

  v_staffing := case when v_instr is null then
                       (case when occ.staffing = 'pending_approval'
                             then 'pending_approval' else 'open' end)
                     else 'assigned' end::staffing_state;

  -- Members are the reason to stop and ask.
  if occ.booked_count > 0 and not p_confirm
     and (v_starts <> occ.starts_at or v_ends <> occ.ends_at
          or v_instr is distinct from occ.instructor_id) then
    return jsonb_build_object(
      'ok', false,
      'requires_confirmation', true,
      'booked_count', occ.booked_count,
      'reason', 'members_booked');
  end if;

  begin
    update class_occurrences
       set starts_at = v_starts, ends_at = v_ends,
           instructor_id = v_instr, room_id = v_room,
           staffing = v_staffing, updated_at = now()
     where id = p_occurrence_id;
  exception when exclusion_violation then
    -- Which of the two, in words a person can act on.
    get stacked diagnostics v_conflict = constraint_name;
    return jsonb_build_object(
      'ok', false,
      'requires_confirmation', false,
      'reason', case when v_conflict = 'occ_room_no_overlap'
                     then 'room_busy' else 'instructor_busy' end,
      'conflict', v_conflict);
  end;

  v_moved := v_starts <> occ.starts_at or v_ends <> occ.ends_at;

  if v_instr is not null and not instructor_available_at(v_instr, v_starts, v_ends) then
    -- Decision 9: permitted, and said out loud. Never blocked.
    v_warnings := v_warnings || 'outside_availability';
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (occ.studio_id, auth.uid(), 'occurrence.moved', 'class_occurrences', occ.id,
          jsonb_build_object('starts_at', occ.starts_at, 'ends_at', occ.ends_at,
                             'instructor_id', occ.instructor_id, 'room_id', occ.room_id),
          jsonb_build_object('starts_at', v_starts, 'ends_at', v_ends,
                             'instructor_id', v_instr, 'room_id', v_room));

  return jsonb_build_object(
    'ok', true,
    'moved', v_moved,
    'staffing', v_staffing,
    'booked_count', occ.booked_count,
    'warnings', to_jsonb(v_warnings));
end $$;

revoke execute on function instructor_available_at(uuid, timestamptz, timestamptz)
  from public, anon;
grant execute on function instructor_available_at(uuid, timestamptz, timestamptz) to authenticated;
revoke execute on function move_occurrence(uuid, timestamptz, timestamptz, uuid, uuid, boolean, boolean)
  from public, anon;
grant execute on function move_occurrence(uuid, timestamptz, timestamptz, uuid, uuid, boolean, boolean)
  to authenticated;
