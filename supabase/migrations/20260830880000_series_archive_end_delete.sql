-- =============================================================================
-- 078  Archive, end and delete a series — and close the cascade behind delete.
-- =============================================================================
-- A studio could not delete a series and was told nothing about why. That was
-- true of the SCREEN. It was never true of the API: `series_manager_write` is
-- `for all using (is_manager_up(studio_id))` and `authenticated` holds DELETE on
-- `class_series`, so a manager has always been able to issue the delete through
-- PostgREST. `class_occurrences.series_id -> class_series` is ON DELETE CASCADE.
--
-- REPRODUCED BEFORE WRITING ANY OF THIS, on the seeded Mat Pilates series:
--
--   BEFORE  occurrences=35  bookings=84  check-ins=63
--   delete from class_series where id = ...   ->  DELETE 1, no error, no warning
--   AFTER   occurrences=0   bookings=0   check-ins=0
--
-- That is migration 062's cascade in a second place: a delete that succeeds
-- while destroying more than it should, and says nothing. The missing button was
-- concealing an open hole rather than standing in front of one.
--
-- THREE ACTIONS, and which one is normal matters as much as what they do:
--
--   ARCHIVE  the ordinary one. Stops the series making new classes, takes it off
--            the working list, KEEPS every class it has already made. Restorable.
--   END      set an end date. The series stops on a day of the studio's choosing
--            and stays visible while it is still recent history.
--   DELETE   for a mistake made five minutes ago. Refused outright the moment
--            anything has run or anyone has booked, and it names what is in the
--            way.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- One definition of what a series is carrying
-- -----------------------------------------------------------------------------
-- Unguarded internal: every caller below is guarded, and having the counts in
-- one place is what stops the preview and the action disagreeing — the fault
-- migration 068's horizon screen shipped with and had to be driven to find.
create or replace function series_counts(p_series_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  with o as (
    select occ.id, occ.starts_at, occ.status, occ.is_exception, occ.assigned_by,
           (select count(*) from bookings b where b.occurrence_id = occ.id) as bookings_all,
           (select count(*) from bookings b where b.occurrence_id = occ.id
              and b.status not in ('cancelled','late_cancelled')) as bookings_live,
           (select count(*) from check_ins c where c.occurrence_id = occ.id) as checkins
      from class_occurrences occ
     where occ.series_id = p_series_id
  )
  select jsonb_build_object(
    'past',            count(*) filter (where starts_at <= now()),
    'future',          count(*) filter (where starts_at >  now()),
    -- Removable: in the future, still scheduled, and carrying no record of
    -- anybody at all. A booking row that was CANCELLED is still a record that
    -- somebody booked and changed their mind, so it keeps its class alive.
    'future_removable', count(*) filter (where starts_at > now() and status = 'scheduled'
                                           and bookings_all = 0 and checkins = 0),
    'future_booked',    count(*) filter (where starts_at > now() and status = 'scheduled'
                                           and bookings_live > 0),
    'future_kept',      count(*) filter (where starts_at > now()
                                           and not (status = 'scheduled' and bookings_all = 0 and checkins = 0)),
    'future_cancelled', count(*) filter (where starts_at > now() and status = 'cancelled'),
    'moved',            count(*) filter (where starts_at > now() and is_exception),
    'hand_assigned',    count(*) filter (where starts_at > now() and assigned_by is not null
                                           and status = 'scheduled' and bookings_all = 0 and checkins = 0),
    'bookings_total',   coalesce(sum(bookings_all), 0),
    'checkins_total',   coalesce(sum(checkins), 0),
    'members_booked',   coalesce(sum(bookings_live) filter (where starts_at > now()), 0)
  ) from o;
$$;

-- -----------------------------------------------------------------------------
-- What each of the three actions would do, before anybody presses anything
-- -----------------------------------------------------------------------------
create or replace function series_impact(p_series_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_studio uuid; v_name text; v_status series_status; v_ends_on date;
  c jsonb; v_removes int; v_kept int; v_booked int;
  v_delete_ok boolean; v_blocked text; v_archive text; v_delete text;
begin
  select studio_id, name, status, ends_on
    into v_studio, v_name, v_status, v_ends_on
    from class_series where id = p_series_id;
  if v_studio is null then
    raise exception 'no such series' using errcode = 'PT404';
  end if;
  if not is_manager_up(v_studio) then
    raise exception 'only owners and managers may archive or delete a series'
      using errcode = 'PT403';
  end if;

  c := series_counts(p_series_id);
  v_removes := (c->>'future_removable')::int;
  v_kept    := (c->>'future_kept')::int;
  v_booked  := (c->>'future_booked')::int;

  -- ARCHIVE. Reads the way a studio thinks about it: what goes, what stays.
  v_archive := case
    when v_removes = 0 and v_kept = 0 then
      format('Archiving %s stops it making new classes. It has none on the calendar to remove.', v_name)
    when v_kept = 0 then
      format('Archiving %s removes %s future class%s.',
             v_name, v_removes, case when v_removes = 1 then '' else 'es' end)
    else
      format('Archiving %s removes %s future class%s. %s ha%s members booked and will be kept.',
             v_name, v_removes, case when v_removes = 1 then '' else 'es' end,
             v_kept, case when v_kept = 1 then 's' else 've' end)
  end;

  -- DELETE. Allowed only where there is nothing to lose: nothing has run, and
  -- no booking or check-in has ever been recorded against any of its classes.
  v_delete_ok := (c->>'past')::int = 0
             and (c->>'bookings_total')::int = 0
             and (c->>'checkins_total')::int = 0;
  if v_delete_ok then
    v_blocked := null;
    v_delete  := case when (c->>'future')::int = 0
      then format('%s has no classes. Deleting it removes the series and nothing else.', v_name)
      else format('Deleting %s removes the series and its %s future class%s. Nothing has run and nobody has booked.',
                  v_name, (c->>'future')::int, case when (c->>'future')::int = 1 then '' else 'es' end) end;
  else
    v_blocked := trim(both ', ' from concat_ws(', ',
      case when (c->>'past')::int > 0
        then format('%s class%s that ha%s already run', (c->>'past')::int,
                    case when (c->>'past')::int = 1 then '' else 'es' end,
                    case when (c->>'past')::int = 1 then 's' else 've' end) end,
      case when (c->>'bookings_total')::int > 0
        then format('%s booking%s', (c->>'bookings_total')::int,
                    case when (c->>'bookings_total')::int = 1 then '' else 's' end) end,
      case when (c->>'checkins_total')::int > 0
        then format('%s check-in%s', (c->>'checkins_total')::int,
                    case when (c->>'checkins_total')::int = 1 then '' else 's' end) end));
    v_delete := format('%s cannot be deleted: it has %s. Archive it instead — that keeps every class it has already made.',
                       v_name, v_blocked);
  end if;

  return jsonb_build_object(
    'ok', true, 'series_id', p_series_id, 'name', v_name,
    'status', v_status, 'ends_on', v_ends_on,
    'counts', c,
    'archive', jsonb_build_object(
      'removes', v_removes, 'keeps', v_kept, 'keeps_booked', v_booked,
      'members_booked', (c->>'members_booked')::int,
      'moved', (c->>'moved')::int, 'hand_assigned', (c->>'hand_assigned')::int,
      'effect', v_archive),
    'delete', jsonb_build_object(
      'allowed', v_delete_ok, 'blocked_by', v_blocked,
      'removes', case when v_delete_ok then (c->>'future')::int else 0 end,
      'effect', v_delete));
end $$;

-- -----------------------------------------------------------------------------
-- Archive: two-step, like archive_record()
-- -----------------------------------------------------------------------------
create or replace function archive_series(p_series_id uuid, p_confirm boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_studio uuid; v_name text; v_status series_status; v_impact jsonb; v_removed int;
begin
  select studio_id, name, status into v_studio, v_name, v_status
    from class_series where id = p_series_id;
  if v_studio is null then
    raise exception 'no such series' using errcode = 'PT404';
  end if;
  if not is_manager_up(v_studio) then
    raise exception 'only owners and managers may archive a series' using errcode = 'PT403';
  end if;
  if v_status = 'archived' then
    raise exception '"%" is already archived', v_name using errcode = 'PT409';
  end if;

  v_impact := series_impact(p_series_id);
  if not coalesce(p_confirm, false) then
    return v_impact || jsonb_build_object('confirm_required', true, 'archived', false);
  end if;

  -- guard_series_archive_path() looks for exactly this.
  perform set_config('studiior.archiving', '1', true);

  update class_series set status = 'archived', updated_at = now() where id = p_series_id;

  -- Future classes nobody is recorded against. DELETED rather than cancelled,
  -- for migration 068's reason: a cancelled row keeps its series_slot_at, and
  -- the unique index on (series_id, series_slot_at) is what makes regeneration
  -- idempotent — so a restored series would find every slot held and come back
  -- to a permanently holed calendar.
  delete from class_occurrences o
   where o.series_id = p_series_id
     and o.starts_at > now()
     and o.status = 'scheduled'
     and not exists (select 1 from bookings  b where b.occurrence_id = o.id)
     and not exists (select 1 from check_ins c where c.occurrence_id = o.id);
  get diagnostics v_removed = row_count;

  -- Everything else stays exactly where it is. A future class somebody is booked
  -- on is not archiving's decision to take away — cancelling it is a separate
  -- act with §3.2 attached, and the studio makes it deliberately or not at all.
  -- A future class already CANCELLED stays too, and it has to: it holds its slot,
  -- which is what stops restoring the series resurrecting a class members were
  -- told was off (migration 074's rule, in a new place).
  -- Past classes are never touched. They are the history.

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (v_studio, auth.uid(), 'series.archived', 'class_series', p_series_id,
          jsonb_build_object('name', v_name, 'removed_future', v_removed,
                             'kept', v_impact->'archive'->>'keeps'));

  return jsonb_build_object(
    'ok', true, 'archived', true, 'series_id', p_series_id, 'name', v_name,
    'removed_future', v_removed,
    'kept', (v_impact->'archive'->>'keeps')::int,
    'kept_booked', (v_impact->'archive'->>'keeps_booked')::int,
    'note', case when (v_impact->'archive'->>'keeps_booked')::int > 0
      then format('%s future class%s with members booked %s kept and will still run. Cancel %s from the calendar if that is what you want.',
                  (v_impact->'archive'->>'keeps_booked')::int,
                  case when (v_impact->'archive'->>'keeps_booked')::int = 1 then '' else 'es' end,
                  case when (v_impact->'archive'->>'keeps_booked')::int = 1 then 'was' else 'were' end,
                  case when (v_impact->'archive'->>'keeps_booked')::int = 1 then 'it' else 'them' end)
      else null end);
end $$;

-- -----------------------------------------------------------------------------
-- Restore
-- -----------------------------------------------------------------------------
create or replace function restore_series(p_series_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_studio uuid; v_name text; v_status series_status; v_gen jsonb;
begin
  select studio_id, name, status into v_studio, v_name, v_status
    from class_series where id = p_series_id;
  if v_studio is null then
    raise exception 'no such series' using errcode = 'PT404';
  end if;
  if not is_manager_up(v_studio) then
    raise exception 'only owners and managers may restore a series' using errcode = 'PT403';
  end if;
  if v_status <> 'archived' then
    raise exception '"%" is not archived', v_name using errcode = 'PT409';
  end if;

  update class_series set status = 'active', updated_at = now() where id = p_series_id;

  -- Refill now rather than at 03:10 tomorrow: a studio that restores a series
  -- and finds the calendar still empty cannot tell that from the restore having
  -- failed. Cancelled slots stay cancelled — the generator steps around them.
  v_gen := generate_occurrences(p_series_id);

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (v_studio, auth.uid(), 'series.restored', 'class_series', p_series_id,
          jsonb_build_object('name', v_name, 'regenerated', v_gen->>'created'));

  return jsonb_build_object('ok', true, 'series_id', p_series_id, 'name', v_name,
    'regenerated', coalesce((v_gen->>'created')::int, 0),
    'note', 'Classes that were cancelled before archiving stay cancelled.');
end $$;

-- -----------------------------------------------------------------------------
-- End it on a date
-- -----------------------------------------------------------------------------
-- Goes through update_series() rather than writing ends_on itself. That function
-- is the only thing that reconciles a changed rule with the classes already on
-- the calendar — it cancels what no longer matches, refuses outright when
-- somebody is booked on a day being dropped, and names them. A second
-- implementation here would agree with it exactly once.
create or replace function end_series(p_series_id uuid,
                                      p_ends_on date default null,
                                      p_confirm boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare s class_series%rowtype; v_end date; v_today date;
begin
  select * into s from class_series where id = p_series_id;
  if s.id is null then
    raise exception 'no such series' using errcode = 'PT404';
  end if;
  if not is_manager_up(s.studio_id) then
    raise exception 'only owners and managers may end a series' using errcode = 'PT403';
  end if;

  v_today := studio_today(s.studio_id);
  v_end   := coalesce(p_ends_on, v_today);

  if v_end < s.starts_on then
    raise exception 'ending "%" on % is before it starts (%). Archive or delete it instead.',
      s.name, v_end, s.starts_on using errcode = 'PT422';
  end if;

  return update_series(
    p_series_id       => p_series_id,
    p_name            => s.name,
    p_class_type_id   => s.class_type_id,
    p_room_id         => s.room_id,
    p_instructor_id   => s.instructor_id,
    p_capacity        => s.capacity,
    p_duration_minutes=> s.duration_minutes,
    p_rrule           => s.rrule,
    p_starts_on       => s.starts_on,
    p_ends_on         => v_end,
    p_time_of_day     => s.time_of_day,
    p_description     => s.description,
    p_effective_from  => null,
    p_confirm         => p_confirm)
    || jsonb_build_object('ended_on', v_end);
end $$;

-- -----------------------------------------------------------------------------
-- The cascade, closed
-- -----------------------------------------------------------------------------
create or replace function guard_series_delete()
returns trigger
language plpgsql
security definer          -- it calls series_counts(), which is closed to client
set search_path to 'public'  -- roles on purpose: an unguarded internal that takes
as $$                        -- an id and returns tenant data must not be reachable
declare c jsonb; v_blocked text;
begin
  -- A demo series is fiction and so is its history. purge_demo_data() detaches
  -- every REAL child from a demo parent before it deletes anything (migration
  -- 062) and counts every non-demo row before and after, raising if one has
  -- gone. That census is a better guard than this one and it is already there.
  if old.is_demo then
    return old;
  end if;

  c := series_counts(old.id);
  v_blocked := trim(both ', ' from concat_ws(', ',
    case when (c->>'past')::int > 0
      then format('%s class(es) that have already run', (c->>'past')::int) end,
    case when (c->>'bookings_total')::int > 0
      then format('%s booking(s)', (c->>'bookings_total')::int) end,
    case when (c->>'checkins_total')::int > 0
      then format('%s check-in(s)', (c->>'checkins_total')::int) end));

  if v_blocked <> '' then
    raise exception '"%" has % and cannot be deleted', old.name, v_blocked
      using errcode = 'PT409',
            hint = 'Archive it instead: that stops it making new classes and '
                   'takes it off the list, while every class it has already '
                   'made keeps its bookings and its history. Or end it on a '
                   'date, which leaves it visible while it is still recent.';
  end if;
  return old;
end $$;

drop trigger if exists tg_guard_series_delete on class_series;
create trigger tg_guard_series_delete
  before delete on class_series
  for each row execute function guard_series_delete();

-- -----------------------------------------------------------------------------
-- Archiving happens through archive_series(), not by setting the column
-- -----------------------------------------------------------------------------
-- The same UPDATE goes straight through PostgREST, so removing the option from a
-- form is not enough. Migration 058's lesson, in the fourth place it applies.
create or replace function guard_series_archive_path()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  if new.status = 'archived' and old.status <> 'archived'
     and coalesce(current_setting('studiior.archiving', true), '') <> '1' then
    raise exception 'archive through archive_series(), not by setting status'
      using errcode = 'PT409',
            hint = 'archive_series() reports what will happen first, removes '
                   'only the future classes nobody is recorded against, and '
                   'keeps the ones with members booked.';
  end if;
  return new;
end $$;

drop trigger if exists tg_guard_series_archive_path on class_series;
create trigger tg_guard_series_archive_path
  before update of status on class_series
  for each row execute function guard_series_archive_path();

-- -----------------------------------------------------------------------------
-- Grants. Functions are closed by default because PostgreSQL's default is the
-- opposite, and the trigger functions are callable by nobody.
-- -----------------------------------------------------------------------------
revoke execute on function series_counts(uuid)            from public, anon, authenticated;
revoke execute on function series_impact(uuid)            from public, anon, authenticated;
revoke execute on function archive_series(uuid, boolean)  from public, anon, authenticated;
revoke execute on function restore_series(uuid)           from public, anon, authenticated;
revoke execute on function end_series(uuid, date, boolean) from public, anon, authenticated;
revoke execute on function guard_series_delete()          from public, anon, authenticated;
revoke execute on function guard_series_archive_path()    from public, anon, authenticated;

grant execute on function series_impact(uuid)             to authenticated;
grant execute on function archive_series(uuid, boolean)   to authenticated;
grant execute on function restore_series(uuid)            to authenticated;
grant execute on function end_series(uuid, date, boolean) to authenticated;
