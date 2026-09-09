-- =============================================================================
-- Migration 060: which instructors can teach which class types
-- =============================================================================
-- The missing input to any automatic assignment. Until now the only thing the
-- scheduler could ask about an instructor was whether they were free — not
-- whether they can teach Reformer.
--
-- AN EMPTY MAPPING MEANS QUALIFIED FOR NOTHING, deliberately, and that is the
-- expensive reading rather than the cheap one. "No rows means everything" makes
-- the feature invisible until it is wrong: a studio would map two instructors,
-- and the third — who is mapped to nothing — would silently stay eligible for
-- every class. Every screen that surfaces this has to say so out loud, because
-- the day it ships every studio is unmapped and it must read as "not set up
-- yet" rather than as broken.
-- =============================================================================

create table if not exists instructor_class_types (
  studio_id     uuid not null references studios on delete cascade,
  instructor_id uuid not null references instructors on delete cascade,
  class_type_id uuid not null references class_types on delete cascade,
  created_by    uuid references profiles on delete set null,
  created_at    timestamptz not null default now(),
  primary key (instructor_id, class_type_id)
);
create index if not exists instructor_class_types_by_type
  on instructor_class_types (studio_id, class_type_id);

alter table instructor_class_types enable row level security;
grant select, insert, update, delete on instructor_class_types to authenticated;
grant all on instructor_class_types to service_role;

comment on table instructor_class_types is
  'Who can teach what. NO ROWS FOR AN INSTRUCTOR MEANS QUALIFIED FOR NOTHING, '
  'not everything — the assignment engine reads it that way and every screen '
  'that shows it says so.';

-- Manager-up writes, all staff read (a roster or a schedule needs to show it),
-- and an instructor reads their own — the same split as instructor_commitments,
-- which they can also read and not write.
create policy ict_manager_all on instructor_class_types for all
  using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));
create policy ict_staff_read on instructor_class_types for select
  using (studio_id in (select auth_staff_studios()));

-- The question the engine asks, and the one the warning on the schedule asks.
create or replace function instructor_qualified(
  p_instructor_id uuid, p_class_type_id uuid
) returns boolean
language sql stable security definer set search_path = public as $$
  -- A class with no type is not a qualification question — a one-off "Studio
  -- closed for a workshop" has nothing to be qualified for.
  select case
    when p_instructor_id is null then false
    when p_class_type_id is null then true
    else exists (select 1 from instructor_class_types t
                  where t.instructor_id = p_instructor_id
                    and t.class_type_id = p_class_type_id)
  end
$$;

-- Set the whole list for one instructor in one call, the same shape and for the
-- same reason as set_instructor_availability(): a half-applied qualification
-- list silently changes who the engine will pick.
create or replace function set_instructor_class_types(
  p_instructor_id uuid, p_class_type_ids uuid[]
) returns int
language plpgsql security definer set search_path = public as $$
declare v_studio uuid; n int;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then
    raise exception 'no such instructor' using errcode = 'PT404';
  end if;
  if not is_manager_up(v_studio) then
    raise exception 'only owners and managers may say who can teach what'
      using errcode = 'PT403';
  end if;

  delete from instructor_class_types where instructor_id = p_instructor_id;
  insert into instructor_class_types (studio_id, instructor_id, class_type_id, created_by)
  select v_studio, p_instructor_id, ct.id, auth.uid()
    from class_types ct
   where ct.id = any (coalesce(p_class_type_ids, '{}'::uuid[]))
     -- Scoped, so a manager cannot map their instructor to another studio's
     -- class type by passing its id.
     and ct.studio_id = v_studio;
  get diagnostics n = row_count;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (v_studio, auth.uid(), 'instructor.qualifications', 'instructors', p_instructor_id,
          jsonb_build_object('class_type_ids', p_class_type_ids, 'written', n));
  return n;
end $$;

-- And the mirror, from the class type's side.
create or replace function set_class_type_instructors(
  p_class_type_id uuid, p_instructor_ids uuid[]
) returns int
language plpgsql security definer set search_path = public as $$
declare v_studio uuid; n int;
begin
  select studio_id into v_studio from class_types where id = p_class_type_id;
  if v_studio is null then
    raise exception 'no such class type' using errcode = 'PT404';
  end if;
  if not is_manager_up(v_studio) then
    raise exception 'only owners and managers may say who can teach what'
      using errcode = 'PT403';
  end if;

  delete from instructor_class_types where class_type_id = p_class_type_id;
  insert into instructor_class_types (studio_id, instructor_id, class_type_id, created_by)
  select v_studio, i.id, p_class_type_id, auth.uid()
    from instructors i
   where i.id = any (coalesce(p_instructor_ids, '{}'::uuid[]))
     and i.studio_id = v_studio;
  get diagnostics n = row_count;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (v_studio, auth.uid(), 'class_type.instructors', 'class_types', p_class_type_id,
          jsonb_build_object('instructor_ids', p_instructor_ids, 'written', n));
  return n;
end $$;

revoke execute on function instructor_qualified(uuid, uuid)                from public, anon, authenticated;
revoke execute on function set_instructor_class_types(uuid, uuid[])        from public, anon, authenticated;
revoke execute on function set_class_type_instructors(uuid, uuid[])        from public, anon, authenticated;
grant execute on function instructor_qualified(uuid, uuid)         to authenticated, service_role;
grant execute on function set_instructor_class_types(uuid, uuid[]) to authenticated, service_role;
grant execute on function set_class_type_instructors(uuid, uuid[]) to authenticated, service_role;
