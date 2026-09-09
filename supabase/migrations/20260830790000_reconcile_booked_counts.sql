-- =============================================================================
-- 069  The nightly reconcile that `booked_count` was assumed to already have
-- =============================================================================
-- `class_occurrences.booked_count` is a cache. `book_class()` increments it and
-- `cancel_booking()` decrements it, both inside the booking transaction and
-- under the row lock, which is why the count is right on every path the product
-- actually uses — checked against Reform Collective before writing this:
-- **455 occurrences, 0 disagreements, and 0 on waitlist_count.**
--
-- What did not exist is the safety net. Grepping every function in the schema
-- for `booked_count` returns the writers and no reconciler: nothing has ever
-- recomputed it. Any writer of `bookings` that is not those two functions
-- drifts silently and forever — which is exactly what the eight drifted rows on
-- this database are, all of them in test-suite studios whose fixtures insert
-- bookings directly.
--
-- That was tolerable while the number lived in a metadata line. The calendar
-- now shows it as the largest thing on every block, so it is the first place a
-- drift would be believed.
--
-- THE RULE, taken from what the two writers implement rather than from what
-- the column name suggests: a seat is taken by any booking that is not
-- cancelled, late-cancelled or waitlisted. `attended` and `no_show` KEEP their
-- seat — somebody who did not turn up still occupied the place — and reading
-- the column as "currently booked" is how a first pass at this reported 312
-- false drifts on a database with 8 real ones.
-- =============================================================================

create or replace function occurrence_seats_taken(p_occurrence_id uuid)
returns int language sql stable set search_path = public as $$
  select count(*)::int from bookings b
   where b.occurrence_id = p_occurrence_id
     and b.status not in ('cancelled', 'late_cancelled', 'waitlisted')
$$;

comment on function occurrence_seats_taken(uuid) is
  'What booked_count is a cache OF. One definition, so the reconciler and any '
  'future reader cannot disagree about whether a no-show kept their seat.';

-- -----------------------------------------------------------------------------
-- Recount, report, and only write what is actually wrong
-- -----------------------------------------------------------------------------
create or replace function reconcile_booked_counts(
  p_studio_id uuid default null, p_dry_run boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r record;
  n_checked int := 0;
  n_fixed   int := 0;
  v_detail  jsonb := '[]'::jsonb;
begin
  -- Platform-wide only from a background job; a studio may reconcile its own.
  if p_studio_id is null then
    if not is_service_context() and not is_platform_admin() then
      raise exception 'reconciling every studio is a background job'
        using errcode = 'PT403';
    end if;
  elsif not coalesce(is_manager_up(p_studio_id), false)
        and not is_service_context() and not is_platform_admin() then
    raise exception 'only owners and managers reconcile a studio''s counts'
      using errcode = 'PT403';
  end if;

  for r in
    select o.id, o.studio_id, o.name, o.starts_at,
           o.booked_count as cached_booked,
           o.waitlist_count as cached_wait,
           occurrence_seats_taken(o.id) as live_booked,
           (select count(*)::int from bookings b
             where b.occurrence_id = o.id and b.status = 'waitlisted') as live_wait
      from class_occurrences o
     where p_studio_id is null or o.studio_id = p_studio_id
     order by o.id
  loop
    n_checked := n_checked + 1;
    if r.cached_booked is distinct from r.live_booked
       or r.cached_wait is distinct from r.live_wait then
      n_fixed := n_fixed + 1;
      -- Capped: a report meant to be read, not a dump of every row on a
      -- database where something has gone badly wrong.
      if jsonb_array_length(v_detail) < 50 then
        v_detail := v_detail || jsonb_build_object(
          'occurrence_id', r.id, 'studio_id', r.studio_id, 'name', r.name,
          'starts_at', r.starts_at,
          'booked_was', r.cached_booked, 'booked_now', r.live_booked,
          'waitlist_was', r.cached_wait, 'waitlist_now', r.live_wait);
      end if;
      if not p_dry_run then
        -- Only the rows that are wrong. Rewriting all of them would touch
        -- updated_at on every occurrence in the studio every night, which is a
        -- lie about when the class last changed.
        update class_occurrences
           set booked_count = r.live_booked, waitlist_count = r.live_wait
         where id = r.id;
      end if;
    end if;
  end loop;

  return jsonb_build_object(
    'ok', true, 'dry_run', p_dry_run,
    'checked', n_checked, 'corrected', n_fixed, 'detail', v_detail);
end $$;

create or replace function sweep_booked_count_reconcile()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  if not is_service_context() then
    raise exception 'the reconcile sweep is a background job' using errcode = 'PT403';
  end if;
  v := reconcile_booked_counts(null, false);
  -- Recorded when it actually corrects something. A nightly job that logs
  -- "0 corrected" every night is a line nobody reads on the night it says 40.
  if coalesce((v ->> 'corrected')::int, 0) > 0 then
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    select (d ->> 'studio_id')::uuid, null, 'booked_count.reconciled',
           'class_occurrences', (d ->> 'occurrence_id')::uuid, d
      from jsonb_array_elements(v -> 'detail') d;
  end if;
  return v;
end $$;

do $cron$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron unavailable; booked_count reconcile not scheduled';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'studiior-reconcile-booked-counts') then
    perform cron.unschedule('studiior-reconcile-booked-counts');
  end if;
  -- 03:40, after the occurrence generator at 03:10 and the platform billing
  -- sweep at 03:20, so a night's writes are all in before anything recounts.
  perform cron.schedule('studiior-reconcile-booked-counts', '40 3 * * *',
                        'select sweep_booked_count_reconcile()');
end $cron$;

revoke execute on function occurrence_seats_taken(uuid)          from public, anon, authenticated;
grant  execute on function occurrence_seats_taken(uuid)          to authenticated, service_role;
revoke execute on function reconcile_booked_counts(uuid, boolean) from public, anon, authenticated;
grant  execute on function reconcile_booked_counts(uuid, boolean) to authenticated;
revoke execute on function sweep_booked_count_reconcile()        from public, anon, authenticated;
grant  execute on function sweep_booked_count_reconcile()        to service_role;
