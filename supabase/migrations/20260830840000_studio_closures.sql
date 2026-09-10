-- =============================================================================
-- 074  Studio closures — the days the studio is shut
-- =============================================================================
-- The same idea as `instructor_availability`'s dated exceptions, one level up.
-- Christmas, a refit, a burst pipe: dates on which nothing is generated and
-- nothing can be booked.
--
-- TWO HALVES, and they are different problems. Ahead of the closure the
-- GENERATOR must not make the classes at all — materialising a fortnight of
-- Christmas classes and then cancelling them is a fortnight of emails nobody
-- needed. Behind it, classes ALREADY on the calendar have to be cancelled
-- properly, which is Business Rules §3.2: the studio cancelled, so credits come
-- back regardless of timing, no late fee, everybody booked is told, and the
-- occurrence stays visible as cancelled rather than vanishing.
--
-- REOPENING IS NOT AN UNDO. A cancelled class had members told it was off; a
-- studio changing its mind cannot untell them. Deleting a closure stops the
-- generator skipping those days and lets it fill slots that have no row —
-- which, because a cancelled row keeps its `series_slot_at` (migration 068),
-- means exactly the classes that were never made. The screen says so.
-- =============================================================================

create table if not exists studio_closures (
  id             uuid primary key default gen_random_uuid(),
  studio_id      uuid not null references studios(id) on delete cascade,
  -- Studio-local DATES throughout. A closure is a thing a person writes on a
  -- calendar on the wall, not an instant.
  starts_on      date not null,
  ends_on        date not null,
  -- Null both, or both: a partial day is a pair of times and half of one is a
  -- closure nobody can evaluate.
  starts_at_time time,
  ends_at_time   time,
  reason         text not null,
  created_by     uuid references profiles(id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint studio_closures_dates      check (ends_on >= starts_on),
  constraint studio_closures_times_pair check ((starts_at_time is null) = (ends_at_time is null)),
  constraint studio_closures_time_order check (ends_at_time is null or ends_at_time > starts_at_time),
  constraint studio_closures_reason     check (btrim(reason) <> '')
);
create index if not exists studio_closures_studio_range_idx
  on studio_closures (studio_id, starts_on, ends_on);

drop trigger if exists studio_closures_updated on studio_closures;
create trigger studio_closures_updated before update on studio_closures
  for each row execute function set_updated_at();

alter table studio_closures enable row level security;

drop policy if exists closures_manager_write on studio_closures;
create policy closures_manager_write on studio_closures
  for all using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));

drop policy if exists closures_staff_read on studio_closures;
create policy closures_staff_read on studio_closures
  for select using (studio_id in (select auth_staff_studios()));

-- A member has to be able to tell "we are closed" from "nothing is on". That is
-- the whole member-facing half of this, and it is a READ of the reason — so the
-- policy is on the table rather than a function returning a subset: there is
-- nothing on this row a member may not see.
drop policy if exists closures_member_read on studio_closures;
create policy closures_member_read on studio_closures
  for select using (studio_id in (select auth_member_studios()));

grant select, insert, update, delete on studio_closures to authenticated;
grant all on studio_closures to service_role;

-- -----------------------------------------------------------------------------
-- The one predicate
-- -----------------------------------------------------------------------------
-- Everything asks this: the generator, the impact preview, the member app, the
-- brief. A second implementation of "is this closed" would disagree with this
-- one about a partial day the first time somebody wrote one.
create or replace function studio_closed_at(
  p_studio_id uuid, p_starts_at timestamptz, p_ends_at timestamptz
) returns boolean language plpgsql stable security definer set search_path = public as $$
declare v_tz text; v_date date; v_from time; v_to time;
begin
  select timezone into v_tz from studios where id = p_studio_id;
  if v_tz is null then return false; end if;

  -- Compared in the studio's own terms. A closure written as "25 December" is
  -- 25 December there, whatever instant that is in UTC.
  v_date := (p_starts_at at time zone v_tz)::date;
  v_from := (p_starts_at at time zone v_tz)::time;
  v_to   := (p_ends_at   at time zone v_tz)::time;

  return exists (
    select 1 from studio_closures c
     where c.studio_id = p_studio_id
       and v_date between c.starts_on and c.ends_on
       and (
         -- A whole-day closure takes the day.
         c.starts_at_time is null
         -- A partial one takes only the classes that overlap its hours. A class
         -- ending exactly as the closure begins is not affected.
         or (v_from < c.ends_at_time and v_to > c.starts_at_time)
       ));
end $$;

comment on function studio_closed_at(uuid, timestamptz, timestamptz) is
  'The single definition of "the studio is shut then". Read by the generator, '
  'the closure preview, the member app and the Morning Brief.';

-- -----------------------------------------------------------------------------
-- Business Rules §3.2: the STUDIO cancels a class
-- -----------------------------------------------------------------------------
-- `queue_occurrence_cancelled()` has existed since migration 030 with no caller
-- at all, because nothing in the product had ever cancelled a class with people
-- in it. This is that caller.
--
-- It goes through `cancel_booking()` per booking rather than updating rows —
-- the same reason `sweep_unpaid_dropins()` does: that function is the only code
-- that returns a credit, and a second implementation would agree with it once.
-- §3.2 says credits come back regardless of timing, which is exactly what
-- `free_cancel_until` already means (Decision 2, migration 050) — so it is set
-- ahead of each cancellation rather than teaching cancel_booking a new mode.
--
-- ORDER MATTERS, three times over:
--   1. NOTIFY FIRST. queue_occurrence_cancelled() reads the bookings that are
--      still booked or waitlisted; run it afterwards and it finds nobody.
--   2. MARK THE OCCURRENCE CANCELLED SECOND, which also frees its room — both
--      exclusion constraints are partial on `status <> 'cancelled'`.
--   3. CANCEL THE WAITLIST BEFORE THE BOOKINGS. cancel_booking() offers a freed
--      seat to the front of the waitlist and does not check whether the class
--      still exists, so cancelling a booked seat first would hand somebody an
--      offer for a class that is off.
create or replace function cancel_occurrence(
  p_occurrence_id uuid, p_reason text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  occ class_occurrences%rowtype;
  r record;
  n_notified int := 0; n_cancelled int := 0; n_credited int := 0;
  v_res record;
begin
  select * into occ from class_occurrences where id = p_occurrence_id for update;
  if not found then
    raise exception 'no such class' using errcode = 'PT404';
  end if;
  if not coalesce(is_manager_up(occ.studio_id), false) and not is_service_context() then
    raise exception 'only owners and managers cancel a class' using errcode = 'PT403';
  end if;
  if occ.status = 'cancelled' then
    return jsonb_build_object('ok', true, 'already_cancelled', true,
                              'notified', 0, 'bookings_cancelled', 0);
  end if;

  n_notified := coalesce(queue_occurrence_cancelled(p_occurrence_id), 0);

  update class_occurrences
     set status = 'cancelled', updated_at = now()
   where id = p_occurrence_id;

  -- §3.2: the studio cancelled, so nobody is late. free_cancel_until is the
  -- lever that already means this.
  update bookings set free_cancel_until = now() + interval '1 hour'
   where occurrence_id = p_occurrence_id
     and status in ('booked', 'waitlisted', 'pending_payment');

  for r in
    select id from bookings
     where occurrence_id = p_occurrence_id
       and status in ('booked', 'waitlisted', 'pending_payment')
     -- Waitlisted first: see (3) above.
     order by (status = 'waitlisted') desc, booked_at
  loop
    select * into v_res from cancel_booking(r.id);
    n_cancelled := n_cancelled + 1;
    if coalesce(v_res.credit_returned, false) then n_credited := n_credited + 1; end if;
  end loop;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (occ.studio_id, auth.uid(), 'occurrence.cancelled', 'class_occurrences',
          p_occurrence_id, jsonb_build_object('reason', p_reason,
                                              'notified', n_notified,
                                              'bookings_cancelled', n_cancelled));

  return jsonb_build_object('ok', true, 'notified', n_notified,
                            'bookings_cancelled', n_cancelled,
                            'credits_returned', n_credited);
end $$;

-- -----------------------------------------------------------------------------
-- What closing would cost, before anybody confirms
-- -----------------------------------------------------------------------------
-- Same two-step as archive_record(): the studio is told the counts and the
-- classes by name, and nothing happens until it says so again.
create or replace function closure_impact(
  p_studio_id uuid, p_starts_on date, p_ends_on date,
  p_starts_at_time time default null, p_ends_at_time time default null
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_tz text; v_classes int := 0; v_members int := 0; v_detail jsonb := '[]'::jsonb;
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers close the studio' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  if v_tz is null then
    raise exception 'no such studio' using errcode = 'PT404';
  end if;
  if p_ends_on < p_starts_on then
    raise exception 'that closure ends before it starts' using errcode = 'PT400';
  end if;

  with hit as (
    select o.id, o.name, o.starts_at, o.booked_count,
           to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMon, HH24:MI') as local,
           (select count(*) from bookings b
             where b.occurrence_id = o.id
               and b.status in ('booked','waitlisted','pending_payment')) as booked
      from class_occurrences o
     where o.studio_id = p_studio_id
       and o.status = 'scheduled'
       -- Only what is still ahead: a class that already ran cannot be cancelled
       -- by closing next Christmas.
       and o.starts_at > now()
       and (o.starts_at at time zone v_tz)::date between p_starts_on and p_ends_on
       and (p_starts_at_time is null
            or ((o.starts_at at time zone v_tz)::time < p_ends_at_time
                and (o.ends_at at time zone v_tz)::time > p_starts_at_time))
  )
  select count(*)::int, coalesce(sum(booked), 0)::int,
         coalesce(jsonb_agg(jsonb_build_object('occurrence_id', id, 'name', name,
                                               'local', local, 'booked', booked)
                            order by starts_at), '[]'::jsonb)
    into v_classes, v_members, v_detail from hit;

  return jsonb_build_object(
    'starts_on', p_starts_on, 'ends_on', p_ends_on,
    'partial', p_starts_at_time is not null,
    'classes', v_classes, 'members_booked', v_members, 'detail', v_detail);
end $$;

-- -----------------------------------------------------------------------------
-- The generator learns to stay shut
-- -----------------------------------------------------------------------------
-- Rebuilt from 20260830780000, the newest FILE that defines it. One branch.
create or replace function generate_occurrences(
  p_series_id uuid, p_horizon_days int default null, p_from date default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  ser        class_series%rowtype;
  v_tz       text;
  v_days_out int;
  v_days     int[];
  v_interval int;
  v_until    date;
  v_today    date;
  v_from     date;
  v_to       date;
  v_anchor   date;
  d          date;
  v_start    timestamptz;
  v_created  int := 0;
  v_skipped  int := 0;
  v_closed   int := 0;
  v_conf     jsonb := '[]'::jsonb;
begin
  select * into ser from class_series where id = p_series_id;
  if not found then
    raise exception 'no such series' using errcode = 'PT404';
  end if;
  if not is_manager_up(ser.studio_id)
     and not is_platform_admin()
     and not is_service_context() then
    raise exception 'only owners, managers or the scheduler may materialise a timetable'
      using errcode = 'PT403';
  end if;

  select timezone into v_tz from studios where id = ser.studio_id;
  select coalesce(p_horizon_days, occurrence_horizon_days, 60)
    into v_days_out from studio_settings where studio_id = ser.studio_id;
  v_days_out := coalesce(v_days_out, coalesce(p_horizon_days, 60));

  v_days     := rrule_weekdays(ser.rrule);
  v_interval := coalesce(nullif(rrule_part(ser.rrule, 'INTERVAL'), '')::int, 1);
  v_until    := rrule_last_date(ser.rrule, ser.starts_on);

  -- Today IN THE STUDIO'S ZONE. A horizon measured from the server's date is a
  -- different horizon for every studio east of London.
  v_today := (now() at time zone v_tz)::date;

  -- Never backfill the past. p_from is how update_series() stops the generator
  -- undoing the one thing an edit promises: that it changes nothing before its
  -- effective date.
  v_from := greatest(ser.starts_on, v_today, coalesce(p_from, '-infinity'::date));
  v_to   := least(
    v_today + v_days_out,
    coalesce(ser.ends_on,  'infinity'::date),
    coalesce(v_until,      'infinity'::date));

  if ser.status <> 'active' then
    return jsonb_build_object('series_id', ser.id, 'created', 0,
      'skipped', 0, 'conflicts', '[]'::jsonb, 'reason', 'series is ' || ser.status);
  end if;

  v_anchor := ser.starts_on - extract(dow from ser.starts_on)::int;

  d := v_from;
  while d <= v_to loop
    if extract(dow from d)::int = any (v_days)
       and (v_interval = 1
            or ((d - extract(dow from d)::int - v_anchor) / 7) % v_interval = 0)
    then
      -- Local wall clock, then interpreted in the zone. NOT starts_at plus an
      -- interval: that drifts an hour across a DST boundary and a 07:00 class
      -- stops being a 07:00 class.
      v_start := (d + ser.time_of_day) at time zone v_tz;

      -- Migration 074: the studio is shut. Skipped rather than made and then
      -- cancelled — materialising a fortnight of Christmas classes so they can
      -- be cancelled again is a fortnight of emails nobody needed, and a
      -- calendar that shows them until the job that removes them runs.
      if studio_closed_at(ser.studio_id, v_start,
                          v_start + make_interval(mins => ser.duration_minutes)) then
        v_closed := v_closed + 1;
        d := d + 1;
        continue;
      end if;

      begin
        insert into class_occurrences
          (studio_id, location_id, series_id, class_type_id, name, description,
           instructor_id, room_id, capacity, starts_at, ends_at,
           status, staffing, series_slot_at)
        values (ser.studio_id, ser.location_id, ser.id, ser.class_type_id,
                ser.name, ser.description, ser.instructor_id, ser.room_id,
                ser.capacity, v_start,
                v_start + make_interval(mins => ser.duration_minutes),
                'scheduled',
                (case when ser.instructor_id is null then 'open' else 'assigned' end)::staffing_state,
                v_start);
        v_created := v_created + 1;
      exception
        when unique_violation then
          v_skipped := v_skipped + 1;
        when exclusion_violation then
          v_conf := v_conf || jsonb_build_object(
            'starts_at', v_start,
            'local', to_char(v_start at time zone v_tz, 'YYYY-MM-DD HH24:MI'),
            'reason', case when sqlerrm like '%occ_room_no_overlap%'
                           then 'room_busy' else 'instructor_busy' end);
      end;
    end if;
    d := d + 1;
  end loop;

  return jsonb_build_object(
    'series_id', ser.id,
    'created',   v_created,
    'skipped',   v_skipped,
    'closed',    v_closed,
    'conflicts', v_conf,
    'horizon_to', v_to);
end $$;;

-- -----------------------------------------------------------------------------
-- Closing, and opening again
-- -----------------------------------------------------------------------------
create or replace function close_studio(
  p_studio_id uuid, p_starts_on date, p_ends_on date, p_reason text,
  p_starts_at_time time default null, p_ends_at_time time default null,
  p_confirm boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_impact jsonb; v_id uuid; r record; v_cancelled int := 0; v_notified int := 0; v jsonb;
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers close the studio' using errcode = 'PT403';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'say why — a closure with no reason is one nobody can explain to a member'
      using errcode = 'PT422';
  end if;
  if (p_starts_at_time is null) <> (p_ends_at_time is null) then
    raise exception 'a partial day needs both a start and an end time' using errcode = 'PT422';
  end if;

  v_impact := closure_impact(p_studio_id, p_starts_on, p_ends_on,
                             p_starts_at_time, p_ends_at_time);

  if not p_confirm then
    return v_impact || jsonb_build_object('ok', false, 'requires_confirmation', true);
  end if;

  insert into studio_closures (studio_id, starts_on, ends_on, starts_at_time,
                               ends_at_time, reason, created_by)
  values (p_studio_id, p_starts_on, p_ends_on, p_starts_at_time, p_ends_at_time,
          btrim(p_reason), auth.uid())
  returning id into v_id;

  -- Everything already on the calendar goes through §3.2's path, one at a time,
  -- so each one's members are told and each one's credits come back.
  for r in select (d ->> 'occurrence_id')::uuid as id
             from jsonb_array_elements(v_impact -> 'detail') d
  loop
    v := cancel_occurrence(r.id, 'Studio closed: ' || btrim(p_reason));
    v_cancelled := v_cancelled + 1;
    v_notified := v_notified + coalesce((v ->> 'notified')::int, 0);
  end loop;

  return jsonb_build_object(
    'ok', true, 'closure_id', v_id,
    'starts_on', p_starts_on, 'ends_on', p_ends_on,
    'classes_cancelled', v_cancelled, 'members_notified', v_notified);
end $$;

-- Reopening is not an undo, and the return value says so rather than leaving a
-- studio to discover it. A cancelled class had members told it was off; what
-- comes back is the classes that were never made, because a cancelled row keeps
-- its `series_slot_at` and the generator steps around it.
create or replace function reopen_studio(p_closure_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c studio_closures%rowtype; v_gen jsonb; v_left int;
begin
  select * into c from studio_closures where id = p_closure_id;
  if not found then
    raise exception 'no such closure' using errcode = 'PT404';
  end if;
  if not coalesce(is_manager_up(c.studio_id), false) then
    raise exception 'only owners and managers reopen the studio' using errcode = 'PT403';
  end if;

  delete from studio_closures where id = p_closure_id;
  v_gen := generate_all_occurrences_for(c.studio_id);

  select count(*) into v_left from class_occurrences o
   where o.studio_id = c.studio_id and o.status = 'cancelled'
     and (o.starts_at at time zone (select timezone from studios where id = c.studio_id))::date
         between c.starts_on and c.ends_on;

  return jsonb_build_object(
    'ok', true, 'reopened', c.starts_on || ' to ' || c.ends_on,
    'classes_regenerated', coalesce((v_gen ->> 'created')::int, 0),
    -- Named, not hidden: these stay cancelled and the studio has to put them
    -- back deliberately if it wants them.
    'still_cancelled', v_left);
end $$;

revoke execute on function studio_closed_at(uuid, timestamptz, timestamptz) from public, anon, authenticated;
grant  execute on function studio_closed_at(uuid, timestamptz, timestamptz) to authenticated, service_role;
revoke execute on function cancel_occurrence(uuid, text)        from public, anon, authenticated;
grant  execute on function cancel_occurrence(uuid, text)        to authenticated;
revoke execute on function closure_impact(uuid, date, date, time, time) from public, anon, authenticated;
grant  execute on function closure_impact(uuid, date, date, time, time) to authenticated;
revoke execute on function close_studio(uuid, date, date, text, time, time, boolean) from public, anon, authenticated;
grant  execute on function close_studio(uuid, date, date, text, time, time, boolean) to authenticated;
revoke execute on function reopen_studio(uuid)                  from public, anon, authenticated;
grant  execute on function reopen_studio(uuid)                  to authenticated;
revoke execute on function generate_occurrences(uuid, int, date) from public, anon, authenticated;
grant  execute on function generate_occurrences(uuid, int, date) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- The brief notices a class on a day the studio is shut
-- -----------------------------------------------------------------------------
-- Rebuilt from 20260830650000, the newest FILE that defines it. One insight.
CREATE OR REPLACE FUNCTION public.generate_morning_brief(p_studio_id uuid, p_for_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_tz        text;
  v_cur       text;
  v_date      date;
  v_max       int;
  v_dedupe    int;
  n_kept      int;
  v_summary   text;
  v_ids       uuid[];
  v_brief_id  uuid;
begin
  if not is_manager_up(p_studio_id)
     and not is_platform_admin()
     and not is_service_context() then
    raise exception 'only owners, managers or the scheduler may generate a brief'
      using errcode = 'PT403';
  end if;

  select timezone, currency into v_tz, v_cur from studios where id = p_studio_id;
  if v_tz is null then
    raise exception 'no such studio' using errcode = 'PT404';
  end if;

  v_date   := coalesce(p_for_date, (now() at time zone v_tz)::date);
  v_max    := insight_threshold(p_studio_id, 'max_insights')::int;
  v_dedupe := insight_threshold(p_studio_id, 'dedupe_days')::int;

  -- Dropped first, not merely created. `on commit drop` cleans up at COMMIT,
  -- and the scheduler loops over every due studio inside ONE transaction — so
  -- the second studio hit "relation _cand already exists" and failed, and with
  -- ten design partners nine briefs would fail every morning while the first
  -- one looked fine. Exactly the shape of the generate_demo_data() bug already
  -- in CLAUDE.md, which is why that note says "once per transaction".
  -- Checked rather than DROP IF EXISTS, which emits a NOTICE every time it
  -- finds nothing — ninety-six runs a day of "table _cand does not exist,
  -- skipping" in the cron log is how real messages get missed.
  if to_regclass('pg_temp._cand') is not null then
    drop table _cand;
  end if;
  create temp table _cand (
    type text, severity text, rank int,
    title text, observation text, why_it_matters text, recommended_action text,
    action_type text, action_payload jsonb,
    subject_type text, subject_id uuid,
    estimated_impact_cents int
  ) on commit drop;

  insert into _cand
  select 'retention_risk', 'warning', 2,
         m.first_name || ' ' || m.last_name || ' is drifting',
         m.health_reason,
         'They are still a member and have not decided to leave. The gap is the moment to say something.',
         'Send them a note — the draft is already written.',
         'message_member',
         jsonb_build_object('member_id', m.id,
                            'href', '/members/' || m.id || '/message'),
         'member', m.id,
         coalesce((select ms.price_cents from memberships ms
                    where ms.member_id = m.id
                      and ms.status not in ('cancelled','expired')
                    order by ms.starts_on desc limit 1), 0)
    from members m
   where m.studio_id = p_studio_id
     and m.status = 'active'
     and m.health_band in ('at_risk','drifting')
     and m.health_signals ->> 0 = 'rhythm_deviation';

  insert into _cand
  select 'payment_failed', 'urgent', 1,
         m.first_name || ' ' || m.last_name || ' cannot book',
         'Their membership is past due, so booking is closed to them until it is settled.',
         'This is money already earned and not collected, and they cannot use what they are paying for.',
         'Tell them the card failed and how to fix it.',
         'message_member',
         jsonb_build_object('member_id', m.id,
                            'href', '/members/' || m.id || '/message'),
         'member', m.id,
         ms.price_cents
    from memberships ms
    join members m on m.id = ms.member_id
   where ms.studio_id = p_studio_id
     and ms.status = 'past_due'
     and m.status = 'active';

  insert into _cand
  select 'new_member_stalled', 'warning', 3,
         m.first_name || ' ' || m.last_name || ' has not got going',
         format('Joined %s days ago, %s visit%s, and nothing booked.',
                v_date - m.joined_on, m.lifetime_visits,
                case when m.lifetime_visits = 1 then '' else 's' end),
         'The first month decides whether someone stays. This is the most rescuable member you have.',
         'Ask how they got on and help them pick a class.',
         'message_member',
         jsonb_build_object('member_id', m.id,
                            'href', '/members/' || m.id || '/message'),
         'member', m.id, 0
    from members m
   where m.studio_id = p_studio_id
     and m.status = 'active'
     and v_date - m.joined_on <= insight_threshold(p_studio_id,'stalled_max_days')::int
     and m.lifetime_visits < insight_threshold(p_studio_id,'stalled_max_visits')::int
     and not exists (
       select 1 from bookings b
         join class_occurrences o on o.id = b.occurrence_id
        where b.member_id = m.id
          and b.status in ('booked','waitlisted')
          and o.starts_at between now()
              and now() + make_interval(days => insight_threshold(p_studio_id,'stalled_no_booking_days')::int));

  insert into _cand
  select 'milestone_upcoming', 'info', 5,
         m.first_name || ' ' || m.last_name || ' is one visit from ' || t.target,
         format('%s visits so far. The next one makes %s.', m.lifetime_visits, t.target),
         'Noticing is free and it is the kind of thing people tell their friends about.',
         'Say something when they come in.',
         'celebrate',
         jsonb_build_object('member_id', m.id, 'milestone', t.target,
                            'href', '/members/' || m.id),
         'member', m.id, 0
    from members m
    cross join lateral unnest(milestone_visit_targets()) as t(target)
   where m.studio_id = p_studio_id
     and m.status = 'active'
     and t.target - m.lifetime_visits
         between 1 and insight_threshold(p_studio_id,'milestone_within_visits')::int;

  insert into _cand
  select 'milestone_upcoming', 'info', 5,
         m.first_name || ' ' || m.last_name || ' has an anniversary coming up',
         format('%s years with you on %s.',
                extract(year from age(v_date, m.joined_on))::int + 1,
                to_char(m.joined_on, 'FMDD Month')),
         'A year is worth marking, and nobody else is going to mention it.',
         'Say something when they come in.',
         'celebrate',
         jsonb_build_object('member_id', m.id, 'href', '/members/' || m.id),
         'member', m.id, 0
    from members m
   where m.studio_id = p_studio_id
     and m.status = 'active'
     and m.joined_on < v_date - interval '300 days'
     and ((to_char(m.joined_on, 'MM-DD')::text) in (
            select to_char(v_date + i, 'MM-DD')
              from generate_series(0, insight_threshold(p_studio_id,'milestone_days_ahead')::int) i));

  -- ---- unstaffed_class (Decision 17) ----------------------------------------
  -- §11 lists nine insight types and none of them covers a class with nobody
  -- teaching it. Ranked 1 and 'urgent', above a failed card: a declined card
  -- can be sorted out on Thursday; a 7am class tomorrow with people booked and
  -- no instructor cannot.
  insert into _cand
  select 'unstaffed_class', 'urgent', 1,
         o.name || ' on ' || to_char(o.starts_at at time zone v_tz, 'FMDay') ||
           ' has nobody teaching it',
         case when o.booked_count > 0
              then format('%s member%s booked, and the class is unstaffed.',
                          o.booked_count, case when o.booked_count = 1 then '' else 's' end)
              else 'Published with no instructor, and nobody has picked it up.' end,
         case when o.booked_count > 0
              then 'Members are expecting a class that currently has nobody to run it.'
              else 'It is on the timetable with nobody assigned.' end,
         case when exists (select 1 from shift_applications sa
                            where sa.occurrence_id = o.id and sa.status = 'pending')
              then 'Somebody has applied. Approve them.'
              else 'Assign someone, or leave it open for an instructor to take.' end,
         'open_shift',
         jsonb_build_object('occurrence_id', o.id, 'href', '/schedule?occurrence=' || o.id),
         'occurrence', o.id,
         0
    from class_occurrences o
   where o.studio_id = p_studio_id
     and o.status = 'scheduled'
     and o.staffing <> 'assigned'
     and o.starts_at > now()
     -- The studio's own staffing deadline, in hours, rather than a window of
     -- days invented here. Past it with nobody assigned is precisely the state
     -- the brief exists to surface: a class members can book that nobody has
     -- agreed to teach.
     and o.starts_at < now() + make_interval(hours => coalesce(
           (select st.unstaffed_deadline_hours from studio_settings st
             where st.studio_id = p_studio_id), 48));

  insert into _cand
  select 'class_underfilled', 'info', 4,
         o.name || ' on ' || to_char(o.starts_at at time zone v_tz, 'FMDay') ||
           ' is half empty',
         format('%s of %s booked, against a usual %s%% for this class.',
                o.booked_count, o.capacity, round(h.avg_fill * 100)),
         'A class that normally fills and suddenly does not is worth a look before it runs.',
         'Open the class and see who usually comes.',
         'open_class',
         jsonb_build_object('occurrence_id', o.id, 'href', '/roster/' || o.id),
         'occurrence', o.id,
         (o.capacity - o.booked_count) * coalesce(
           (select price_cents from membership_plans
             where studio_id = p_studio_id and type = 'drop_in' and status = 'active'
             order by price_cents limit 1), 0)
    from class_occurrences o
    join lateral (
      select avg(p.booked_count::numeric / nullif(p.capacity,0)) as avg_fill,
             count(*) as n
        from class_occurrences p
       where p.series_id is not distinct from o.series_id
         and p.studio_id = p_studio_id
         and p.starts_at < now()
         and p.status <> 'cancelled'
    ) h on true
   where o.studio_id = p_studio_id
     and o.status = 'scheduled'
     and o.starts_at between now()
         and now() + make_interval(days => insight_threshold(p_studio_id,'underfilled_window_days')::int)
     and o.capacity > 0
     and o.booked_count::numeric / o.capacity < insight_threshold(p_studio_id,'underfilled_pct')
     and h.n >= insight_threshold(p_studio_id,'underfilled_min_history')::int
     and h.avg_fill > insight_threshold(p_studio_id,'underfilled_series_pct');

  insert into _cand
  select 'class_overfilled', 'info', 4,
         nxt.name || ' has been full for ' ||
           insight_threshold(p_studio_id,'overfilled_weeks')::int || ' weeks',
         format('Averaging %s%% of capacity. People are being turned away.',
                round(w.min_fill * 100)),
         'A class this full is a second class waiting to be scheduled, or a bigger room.',
         'Open it and see the waitlist.',
         'open_class',
         jsonb_build_object('occurrence_id', nxt.id, 'series_id', w.series_id,
                            'href', '/roster/' || nxt.id),
         'occurrence', nxt.id, 0
    from (
      select p.series_id,
             min(wk.fill) as min_fill
        from class_occurrences p
        join lateral (
          select avg(q.booked_count::numeric / nullif(q.capacity,0)) as fill
            from class_occurrences q
           where q.series_id = p.series_id and q.studio_id = p_studio_id
             and q.starts_at >= now() - make_interval(weeks => 1)
             and q.starts_at < now()
        ) wk on true
       where p.studio_id = p_studio_id and p.series_id is not null
       group by p.series_id
    ) w
    join lateral (
      select o.id, o.name from class_occurrences o
       where o.series_id = w.series_id and o.starts_at > now()
         and o.status = 'scheduled'
       order by o.starts_at limit 1
    ) nxt on true
   where w.min_fill >= insight_threshold(p_studio_id,'overfilled_pct');

  if insight_threshold(p_studio_id, 'challenge_enabled') >= 1 then
    insert into _cand
    select 'challenge_opportunity', 'info', 6,
           'Enough members for a challenge',
           format('%s members are coming regularly and none of them is in a challenge.',
                  count(*)),
           'A challenge gives regulars a reason to come more often without discounting anything.',
           'Launch one.',
           'launch_challenge',
           jsonb_build_object('href', '/challenges/new'),
           'studio', p_studio_id, 0
      from members m
     where m.studio_id = p_studio_id and m.status = 'active'
       and m.health_band = 'healthy'
    having count(*) >= insight_threshold(p_studio_id,'challenge_min_members')::int;
  end if;

  -- ---- cover_unanswered (Decision 18) ---------------------------------------
  -- RANK 0, above unstaffed_class, which Decision 17 put above a declined card.
  -- An unanswered cover request inside the escalation window is the same
  -- emergency as a class with nobody teaching it, arriving earlier and still
  -- fixable — and it is only an emergency BECAUSE approval is required. Outside
  -- the window it is rank 1: still urgent, not yet the loudest thing.
  insert into _cand
  select 'cover_unanswered',
         'urgent',
         case when cr_urgent then 0 else 1 end,
         v_who || ' needs cover for ' || v_cls ||
           case when cr_urgent then ' in ' || v_left else '' end,
         case when v_booked > 0
              then format('Asked %s and nobody has answered. %s member%s booked.',
                          v_ago, v_booked,
                          case when v_booked = 1 then ' is' else 's are' end)
              else format('Asked %s and nobody has answered.', v_ago) end,
         case when cr_urgent
              then 'They are still on the class until somebody decides, and the class is about to run.'
              else 'They stay on the class until this is answered, so nothing is broken yet — but nothing is arranged either.' end,
         'Assign someone, or open it up for another instructor.',
         'cover_request',
         jsonb_build_object('request_id', cr_id, 'occurrence_id', cr_occ,
                            'href', '/shifts/cover?request=' || cr_id),
         'occurrence', cr_occ,
         0
    from (
      select cr.id as cr_id, cr.occurrence_id as cr_occ,
             i.display_name as v_who, o.name as v_cls, o.booked_count as v_booked,
             o.starts_at <= now() + make_interval(
               hours => coalesce(st.cover_escalation_hours, 4)) as cr_urgent,
             case when extract(epoch from o.starts_at - now()) < 3600
                  then round(extract(epoch from o.starts_at - now()) / 60) || ' minutes'
                  else round(extract(epoch from o.starts_at - now()) / 3600) || ' hours' end as v_left,
             case when now() - cr.requested_at < interval '1 hour'
                  then round(extract(epoch from now() - cr.requested_at) / 60) || ' minutes ago'
                  when now() - cr.requested_at < interval '48 hours'
                  then round(extract(epoch from now() - cr.requested_at) / 3600) || ' hours ago'
                  else round(extract(epoch from now() - cr.requested_at) / 86400) || ' days ago' end as v_ago
        from cover_requests cr
        join class_occurrences o on o.id = cr.occurrence_id
        join instructors i       on i.id = cr.instructor_id
        left join studio_settings st on st.studio_id = cr.studio_id
       where cr.studio_id = p_studio_id
         and cr.status = 'pending'
         and o.status = 'scheduled'
         and o.starts_at > now()
    ) c;

  -- ---- commitment_shortfall (Decision 18) -----------------------------------
  -- The entire reason instructor_commitments exists. A three-month agreement
  -- that quietly ran at six classes a week instead of nine is a conversation
  -- that has to happen in week three; found in month three it is a grievance.
  -- Consecutive weeks, not a total: one week under is a holiday and everybody
  -- at the studio already knows about it.
  insert into _cand
  select 'commitment_shortfall', 'warning', 3,
         v_name || ' is under what was agreed',
         format('%s week%s in a row below %s classes — %s.',
                v_weeks, case when v_weeks = 1 then '' else 's' end,
                v_min, v_detail),
         'They committed to a weekly minimum and the weeks are going by. This is a conversation, not a problem yet.',
         'Have a word before it becomes three months of it.',
         'open_instructor',
         jsonb_build_object('instructor_id', v_iid,
                            'href', '/instructors/' || v_iid),
         'instructor', v_iid,
         0
    from (
      select c.instructor_id as v_iid, i.display_name as v_name,
             c.min_per_week as v_min,
             (select count(*) from unnest(w.loads) l where l < c.min_per_week)::int as v_weeks,
             array_to_string(w.loads, ', ') as v_detail
        from instructor_commitments c
        join instructors i on i.id = c.instructor_id
        join lateral (
          -- The most recent N COMPLETE weeks, newest last.
          select array_agg(classes order by week_start) as loads
            from (select * from instructor_weekly_load(c.instructor_id,
                    insight_threshold(p_studio_id,'commitment_weeks')::int)
                   order by week_start desc
                   limit insight_threshold(p_studio_id,'commitment_weeks')::int) z
        ) w on true
       where c.studio_id = p_studio_id
         and c.status = 'active'
         and c.min_per_week > 0
         and c.starts_on <= v_date
         and (c.ends_on is null or c.ends_on >= v_date)
         -- Every one of the last N weeks under. `all` rather than a count, so a
         -- good week resets it — which is what "persistently" has to mean.
         and w.loads is not null
         and array_length(w.loads, 1) >= insight_threshold(p_studio_id,'commitment_weeks')::int
         and not exists (select 1 from unnest(w.loads) l where l >= c.min_per_week)
    ) s;

  -- ---- studio_closed_with_bookings (migration 074) --------------------------
  -- Closing the studio cancels what is already on the calendar, so a class
  -- inside a closure is one that arrived AFTER it: typed in by hand, or dragged
  -- there. Nobody meant that, and the members booked on it think they have a
  -- class. Ranked beside an unstaffed class because it is the same shape — a
  -- room of people expecting a session that is not going to happen.
  insert into _cand
  select 'studio_closed_with_bookings', 'warning', 1,
         'Classes on a day the studio is shut',
         -- The reason is free text a studio wrote, so it is QUOTED as its own
         -- clause rather than folded into a sentence: "closed for Closed for
         -- Christmas" is what folding it produced.
         format('%s on %s, and you are shut that day — "%s". %s still booked.',
                case when v_n = 1 then '1 class' else v_n || ' classes' end,
                to_char(v_when, 'FMDD FMMonth'), v_why,
                case when v_bk = 1 then '1 member is' else v_bk || ' members are' end),
         'They are expecting a class. The closure did not remove these because '
         'they were put on the calendar after it.',
         'Cancel them, or lift the closure for that day.',
         'open_schedule',
         jsonb_build_object('href', '/schedule?d=' || v_when || '&view=day',
                            'date', v_when),
         'studio', p_studio_id,
         0
    from (
      select (o.starts_at at time zone v_tz)::date as v_when,
             min(cl.reason) as v_why,
             count(*)::int as v_n,
             coalesce(sum((select count(*) from bookings b
                            where b.occurrence_id = o.id
                              and b.status in ('booked','waitlisted','pending_payment'))), 0)::int as v_bk
        from class_occurrences o
        join studio_closures cl
          on cl.studio_id = o.studio_id
         and (o.starts_at at time zone v_tz)::date between cl.starts_on and cl.ends_on
         and (cl.starts_at_time is null
              or ((o.starts_at at time zone v_tz)::time < cl.ends_at_time
                  and (o.ends_at at time zone v_tz)::time > cl.starts_at_time))
       where o.studio_id = p_studio_id
         and o.status = 'scheduled'
         and o.starts_at > now()
       group by 1
       having coalesce(sum((select count(*) from bookings b
                             where b.occurrence_id = o.id
                               and b.status in ('booked','waitlisted','pending_payment'))), 0) > 0
    ) z;

  delete from _cand c
   where exists (
     select 1 from ai_insights i
      where i.studio_id = p_studio_id
        and i.type = c.type
        and i.subject_id is not distinct from c.subject_id
        and i.status in ('actioned','dismissed')
        and coalesce(i.actioned_at, i.dismissed_at)
            > now() - make_interval(days => v_dedupe));

  delete from _cand a
   using _cand b
   where a.type = b.type
     and a.subject_id is not distinct from b.subject_id
     and a.ctid > b.ctid;

  delete from _cand a
   using _cand b
   where a.subject_id is not distinct from b.subject_id
     and a.subject_id is not null
     and (b.rank < a.rank or (b.rank = a.rank and b.ctid < a.ctid));

  insert into ai_insights
    (studio_id, type, severity, title, observation, why_it_matters,
     recommended_action, action_type, action_payload, subject_type, subject_id,
     estimated_impact_cents, for_date, status)
  select p_studio_id, c.type, c.severity, c.title, c.observation, c.why_it_matters,
         c.recommended_action, c.action_type, c.action_payload, c.subject_type,
         c.subject_id, nullif(c.estimated_impact_cents, 0), v_date, 'new'
    from (
      select * from _cand
       order by rank, estimated_impact_cents desc nulls last, subject_id
       limit v_max
    ) c
  on conflict (studio_id, type, subject_id, for_date) do update
     set title = excluded.title,
         observation = excluded.observation,
         action_payload = excluded.action_payload,
         estimated_impact_cents = excluded.estimated_impact_cents;

  select count(*), array_agg(id order by
           case severity when 'urgent' then 1 when 'warning' then 2 else 3 end,
           estimated_impact_cents desc nulls last)
    into n_kept, v_ids
    from ai_insights
   where studio_id = p_studio_id and for_date = v_date;

  v_summary := brief_summary(p_studio_id, v_date);

  insert into morning_briefs (studio_id, brief_date, summary, metrics, insight_ids)
  values (p_studio_id, v_date, v_summary,
          jsonb_build_object(
            'insight_count', n_kept,
            'candidates_considered', (select count(*) from _cand),
            'money_at_stake_cents', coalesce((
              select sum(estimated_impact_cents) from ai_insights
               where studio_id = p_studio_id and for_date = v_date), 0),
            'currency', v_cur),
          coalesce(v_ids, '{}'))
  on conflict (studio_id, brief_date) do update
     set summary = excluded.summary,
         metrics = excluded.metrics,
         insight_ids = excluded.insight_ids,
         generated_at = now()
  returning id into v_brief_id;

  return jsonb_build_object('brief_id', v_brief_id, 'for_date', v_date,
                            'insights', n_kept, 'summary', v_summary);
end $function$;
revoke execute on function generate_morning_brief(uuid, date) from public, anon, authenticated;
grant  execute on function generate_morning_brief(uuid, date) to authenticated, service_role;
