-- =============================================================================
-- Migration 116 — a flex class, by who is looking
-- =============================================================================
-- sweep_commitments() already cancels a flex class that misses its minimum by
-- the deadline (through the studio-cancellation path) and already sends each
-- instructor a batched "RUNNING / NOT ON" digest at the cutoff. Two things it
-- did not do:
--
--   1. Tell an instructor the moment their class REACHES its minimum, rather
--      than making them wait until the deadline to learn it is on. Someone who
--      knows at 3pm can plan their evening; one who finds out at 20:00 has
--      spent the day unsure. Once, when it crosses — six bookings is one
--      message, not six. And once crossed it does NOT un-confirm if a member
--      later cancels: Decision 21's latch holds.
--
--   2. Make the cancelled class read correctly to STAFF. It read fine to
--      members (gone) and to its instructor (marked not running on their own
--      schedule), but schedule_range() filtered out every cancelled row, so the
--      not-running slot vanished from the calendar — and a slot that cancels
--      eleven weeks running should be obvious in February.
--
-- THE LATCH IS EARLY, THE COMMIT IS NOT. Reaching the minimum stamps
-- flex_reached_minimum_at and sends the message; the formal commitment still
-- happens at the cutoff, so booked_at_cutoff stays the REAL headcount at the
-- cutoff and per-head pay is unaffected. The cutoff then commits a class that
-- EVER reached its minimum even if it has since dropped below — which is what
-- makes "it is going ahead" a promise the studio keeps.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. The early latch
-- -----------------------------------------------------------------------------
alter table class_occurrences add column flex_reached_minimum_at timestamptz;

comment on column class_occurrences.flex_reached_minimum_at is
  'When a flex class first reached its minimum. Once set, the cutoff commits it '
  'even if bookings later fall below — Decision 21''s latch, moved earlier so '
  'the instructor can be told it is going ahead. Migration 116.';

insert into notification_templates (key, subject, text_body, html_body, note) values
('flex_going_ahead',
 '{class_name} is going ahead',
 E'Hi {instructor_name},\n\n{class_name} on {when} has reached its minimum — it is going ahead. {booked_line}\n\nYou can count on it now; it will not be cancelled if someone later drops out.\n\nSee you there,\n{studio_name}',
 '<p>Hi {instructor_name},</p><p><strong>{class_name}</strong> on {when} has reached its minimum — it is going ahead. {booked_line}</p><p>You can count on it now; it will not be cancelled if someone later drops out.</p><p>See you there,<br>{studio_name}</p>',
 'Migration 116. Sent ONCE, the moment a flex class crosses its minimum, to the '
 'instructor teaching it. The deadline digest still covers classes that did not.')
on conflict (key) do nothing;

-- When a flex class's headcount crosses its minimum, stamp it once and tell the
-- instructor. AFTER UPDATE OF booked_count: book_class() maintains booked_count,
-- which is the same set evaluate_commitment counts (migration 069). The nested
-- stamp updates a different column, so it does not re-fire this trigger.
create function tg_flex_reached_minimum() returns trigger
language plpgsql security definer set search_path = public as $$
declare g record; s studios%rowtype; v_user uuid; v_name text;
begin
  -- Cheap exits first: only a flex, scheduled, uncommitted, not-yet-latched
  -- class with somebody to tell is a candidate.
  if not coalesce(new.flex, false)
     or new.status <> 'scheduled'
     or new.committed_at is not null
     or new.flex_reached_minimum_at is not null
     or new.instructor_id is null then
    return new;
  end if;

  select * into g from occurrence_guarantee_run(new.id) g;
  -- Only a class that BEHAVES as flex (studio switch on) has a minimum to
  -- reach; occurrence_guarantee demotes a flex class at a flex-off studio to
  -- 'always', which is correctly ignored here.
  if g.tier is distinct from 'flex' or g.minimum is null or new.booked_count < g.minimum then
    return new;
  end if;

  update class_occurrences set flex_reached_minimum_at = now()
   where id = new.id and flex_reached_minimum_at is null;

  select * into s from studios where id = new.studio_id;
  v_user := instructor_user_id(new.instructor_id);
  if v_user is not null then
    select display_name into v_name from instructors where id = new.instructor_id;
    perform queue_shift_notice(new.studio_id, v_user, 'flex_going_ahead',
      jsonb_build_object(
        'instructor_name', coalesce(v_name, 'there'),
        'studio_name', s.name,
        'class_name', new.name,
        'when', to_char(new.starts_at at time zone s.timezone, 'FMDay FMDD FMMon, HH24:MI'),
        'booked_line', case when new.booked_count = 1 then '1 booked so far.'
                            else new.booked_count || ' booked so far.' end),
      -- Once per class per instructor per start time — a reassignment after a
      -- move is a different person to reassure.
      'flex_going_ahead:' || new.id || ':' || new.instructor_id
        || ':' || extract(epoch from new.starts_at)::bigint);
  end if;

  return new;
end $$;

create trigger tg_flex_reached_minimum
  after update of booked_count on class_occurrences
  for each row execute function tg_flex_reached_minimum();

-- -----------------------------------------------------------------------------
-- 2. The cutoff commits a class that EVER reached its minimum
-- -----------------------------------------------------------------------------
-- Re-issued from migration 091's file, with one clause: the latch. Everything
-- else — the guards, the snapshot-first-then-cancel order, the silence toward
-- members — is unchanged.
create or replace function evaluate_commitment(p_occurrence_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare o class_occurrences%rowtype; g record; v_booked int;
begin
  select * into o from class_occurrences where id = p_occurrence_id for update;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(o.studio_id), false) and not is_service_context() then
    raise exception 'only owners, managers and the sweep decide a class' using errcode = 'PT403';
  end if;

  if o.committed_at is not null then
    return jsonb_build_object('ok', true, 'already', 'committed',
                              'booked_at_cutoff', o.booked_at_cutoff);
  end if;
  if o.status <> 'scheduled' then
    return jsonb_build_object('ok', true, 'already', o.status::text,
                              'cause', o.cancellation_cause);
  end if;

  select * into g from occurrence_guarantee(p_occurrence_id);
  if g.cutoff_at is null then
    return jsonb_build_object('ok', true, 'skipped', 'guarantees are off for this class');
  end if;
  if now() < g.cutoff_at then
    return jsonb_build_object('ok', true, 'skipped', 'not due', 'due_at', g.cutoff_at);
  end if;

  select count(*)::int into v_booked from bookings
   where occurrence_id = p_occurrence_id
     and status in ('booked','attended','no_show','pending_payment');

  -- THE LATCH. A flex class that ever reached its minimum runs, even if a
  -- member has since cancelled and the count is now below — because the
  -- instructor was told it was going ahead and turned their evening over to it.
  -- booked_at_cutoff stays the REAL count so pay is right: a class that
  -- committed with nobody left pays the holding rate, not a per-head sum.
  if v_booked >= g.minimum
     or (o.flex and o.flex_reached_minimum_at is not null) then
    update class_occurrences
       set committed_at = now(), booked_at_cutoff = v_booked, updated_at = now()
     where id = p_occurrence_id;
    return jsonb_build_object('ok', true, 'decision', 'committed',
      'tier', g.tier, 'booked_at_cutoff', v_booked, 'minimum', g.minimum,
      'latched', (v_booked < g.minimum));
  end if;

  update class_occurrences set booked_at_cutoff = v_booked where id = p_occurrence_id;
  perform cancel_occurrence(p_occurrence_id,
            'Did not reach its minimum by the cutoff', 'unmet_minimum');

  return jsonb_build_object('ok', true, 'decision', 'not_running',
    'tier', g.tier, 'booked_at_cutoff', v_booked, 'minimum', g.minimum);
end $$;

-- -----------------------------------------------------------------------------
-- 3. STAFF see the not-running slot — schedule_range() carries it
-- -----------------------------------------------------------------------------
-- schedule_range() filtered out every cancelled row, so a flex class the sweep
-- decided overnight simply vanished from the calendar. Now an unmet-minimum
-- cancellation stays on the grid, carrying its cause and the count that decided
-- it, so "this slot has cancelled for want of one booking eleven weeks running"
-- is visible. Other cancellations (a studio closure, a brownout) stay hidden —
-- they are not a pattern the studio reads off this screen.
--
-- A RETURNS TABLE cannot gain a column through create or replace, so it drops
-- and re-asserts its ACL. Rebuilt from migration 110/150's file with the two
-- changes: occ_cancellation_cause added, and the WHERE relaxed.
drop function if exists schedule_range(uuid, date, date);

create function schedule_range(p_studio_id uuid, p_from date, p_to date)
 RETURNS TABLE(occ_id uuid, occ_name text, starts_at timestamp with time zone, ends_at timestamp with time zone, local_date date, local_start text, local_end text, start_minutes integer, end_minutes integer, occ_instructor_id uuid, room_name text, occ_capacity integer, occ_booked integer, occ_waitlist integer, occ_staffing text, occ_status text, occ_flex boolean, occ_confirmed boolean, occ_tier text, occ_standalone boolean, occ_series_tier text, occ_minimum integer, occ_cancellation_cause text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_tz text;
begin
  if not coalesce(is_manager_up(p_studio_id), false) and not is_service_context() then
    raise exception 'the timetable is the owner''s and managers'' to see'
      using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  if v_tz is null then
    raise exception 'no such studio' using errcode = 'PT404';
  end if;
  if p_to < p_from then
    raise exception 'that range ends before it starts' using errcode = 'PT400';
  end if;
  if p_to - p_from > 62 then
    raise exception 'ask for at most 62 days at a time' using errcode = 'PT422';
  end if;

  return query
  select o.id, o.name, o.starts_at, o.ends_at,
         (o.starts_at at time zone v_tz)::date,
         to_char(o.starts_at at time zone v_tz, 'HH24:MI'),
         to_char(o.ends_at   at time zone v_tz, 'HH24:MI'),
         (extract(hour from o.starts_at at time zone v_tz) * 60
          + extract(minute from o.starts_at at time zone v_tz))::int,
         (extract(hour from o.ends_at at time zone v_tz) * 60
          + extract(minute from o.ends_at at time zone v_tz))::int,
         o.instructor_id, r.name, o.capacity, o.booked_count, o.waitlist_count,
         o.staffing::text, o.status::text,
         o.flex, o.committed_at is not null,
         g.tier::text,
         (g.tier = 'flex' and not occurrence_is_adjacent(o.id)),
         coalesce(
           o.guarantee_tier,
           case when o.flex then 'flex'::guarantee_tier end,
           ser.guarantee_tier,
           case when ser.flex then 'flex'::guarantee_tier end,
           'core'::guarantee_tier)::text,
         g.minimum,
         -- New: the cause, so the calendar can mark an unmet-minimum row "not
         -- running" rather than as a generic cancellation.
         o.cancellation_cause::text
    from class_occurrences o
    cross join lateral occurrence_guarantee(o.id) g
    left join class_series ser on ser.id = o.series_id
    left join rooms r on r.id = o.room_id
   where o.studio_id = p_studio_id
     -- Scheduled classes, plus flex classes the cutoff turned off. A generic
     -- cancellation stays hidden; not-running is a decided flex state the
     -- studio reads for its rate.
     and (o.status <> 'cancelled' or o.cancellation_cause = 'unmet_minimum')
     and (o.starts_at at time zone v_tz)::date between p_from and p_to
   order by o.starts_at;
end $function$;

revoke execute on function schedule_range(uuid, date, date) from public, anon;
grant  execute on function schedule_range(uuid, date, date) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Grants and assertions
-- -----------------------------------------------------------------------------
revoke execute on function tg_flex_reached_minimum()      from public, anon, authenticated;

do $$
begin
  if has_function_privilege('anon', 'schedule_range(uuid,date,date)'::regprocedure, 'execute') then
    raise exception 'migration 116: schedule_range is reachable by anon';
  end if;
  if not has_function_privilege('authenticated', 'schedule_range(uuid,date,date)'::regprocedure, 'execute') then
    raise exception 'migration 116: schedule_range lost the grant it needs';
  end if;
  if has_function_privilege('authenticated', 'tg_flex_reached_minimum()', 'execute') then
    raise exception 'migration 116: the trigger fn is reachable by authenticated';
  end if;
end $$;
