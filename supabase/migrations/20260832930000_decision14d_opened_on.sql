-- Decision 14 (d) — the owner can state the opening date.
-- re-issues: studio_opened_on(uuid)
-- =============================================================================
-- (c) infers the opening date from the first attended/checked-in occurrence (or
-- an imported check-in). But an owner tests their own check-in and pay flows
-- before launch, and that test attendance must not open the studio. (d) lets the
-- owner state the date: studio_settings.opened_on, nullable, overrides the
-- inference when set, falls back to it when NULL.
--
-- member_health and convert_keep_sweep are UNCHANGED — they already call
-- studio_opened_on, so moving the override inside the helper reaches both.
-- =============================================================================

alter table studio_settings
  add column if not exists opened_on date;

comment on column studio_settings.opened_on is
  'Decision 14(d): the studio opening date, owner-stated. When set it overrides '
  'the attended/checked-in/imported inference in studio_opened_on; NULL = infer. '
  'Until this date member health reads insufficient_history and no convert/keep/'
  'retention mail or tasks are sent.';

-- Re-issued from the newest definition (migration 20260832920000) with ONE
-- change: a stated opened_on wins over the inference. Still STABLE and
-- service-only, so the anon surface is untouched (EXACTLY THIRTEEN).
create or replace function studio_opened_on(p_studio_id uuid)
returns date
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select opened_on from studio_settings where studio_id = p_studio_id),
    (select min(d) from (
      select (o.starts_at at time zone s.timezone)::date as d
        from class_occurrences o
        join studios s on s.id = o.studio_id
       where o.studio_id = p_studio_id
         and ( exists (select 1 from bookings b
                        where b.occurrence_id = o.id and b.status = 'attended')
               or exists (select 1 from check_ins ci where ci.occurrence_id = o.id) )
      union all
      select (ci.checked_in_at at time zone s.timezone)::date
        from check_ins ci
        join studios s on s.id = ci.studio_id
       where ci.studio_id = p_studio_id and ci.import_id is not null
    ) x)
  );
$$;
revoke execute on function studio_opened_on(uuid) from public, anon, authenticated;
grant  execute on function studio_opened_on(uuid) to service_role;

-- Anon surface must still be EXACTLY THIRTEEN.
do $$
declare n int;
begin
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'expect_%'
     and p.proname not in ('login','sig','psig');
  if n <> 13 then
    raise exception 'anon surface is %, expected 13', n;
  end if;
end $$;
