-- =============================================================================
-- Decision 38 — instructors confirm the classes the studio assigns them.
-- Plus Decision 37 amendment (c) — a series assigned to an instructor warns on
-- weeks outside their agreed dates, and blocks nothing.
--
-- ASSIGNED IS NOT AGREED. The owner builds the timetable and assigns; the
-- instructor should see what they were given, confirm it, or hand it back — in
-- the app, with an email nudge — WITHOUT the owner's assignment ever being
-- blocked or undone by silence. Silence changes nothing.
--
-- Per-tenant, opt-in, OFF by default (the all_off canary proves inertness). No
-- new enum values. Anon surface stays EXACTLY ELEVEN.
-- =============================================================================

-- ---- Schema -----------------------------------------------------------------
alter table studio_settings
  add column if not exists assignment_confirmations boolean not null default false;

alter table class_occurrences
  add column if not exists assignment_requested_at timestamptz,
  add column if not exists assignment_confirmed_at  timestamptz;

comment on column class_occurrences.assignment_requested_at is
  'Decision 38. When the instructor was asked to confirm this assigned class '
  '(null = never asked). Stamped by trigger when an occurrence becomes assigned '
  'to a login instructor while assignment_confirmations is on.';
comment on column class_occurrences.assignment_confirmed_at is
  'Decision 38. When the assigned instructor confirmed. Cleared on reassignment.';

-- The demo-promote trigger treats a human edit of class_occurrences as adopting
-- the row. These two columns are MACHINE-set (triggers / confirm_assignment), so
-- they join the system-column ignore list, or a confirm on a demo class would
-- clear its is_demo flag. (Re-issued from migration 063.)
drop trigger if exists occurrences_promote_demo on class_occurrences;
create trigger occurrences_promote_demo before update on class_occurrences for each row
  execute function tg_promote_edited_demo_row(
    'updated_at,booked_count,waitlist_count,series_slot_at,staffing,is_exception,assigned_by,'
    'assignment_requested_at,assignment_confirmed_at');

-- ---- Templates --------------------------------------------------------------
insert into notification_templates (key, subject, text_body, html_body, note) values
('assignment_confirmation_request',
 'Please confirm your classes at {studio_name}',
 E'Hi {first_name},\n\n{studio_name} has put {count} class(es) on your schedule and would like you to confirm them:\n\n{class_list}\n\nConfirm (or ask for cover) here: {schedule_link}\n\n{studio_name}',
 E'<p>Hi {first_name},</p><p>{studio_name} has put <strong>{count}</strong> class(es) on your schedule and would like you to confirm them:</p><p style="white-space:pre-line">{class_list}</p><p><a href="{schedule_link}">Confirm (or ask for cover) here</a></p><p>{studio_name}</p>',
 'Decision 38. One coalesced digest per instructor per day, the pending list '
 'grouped by series, scheduled for the end of the studio-local day.')
on conflict (key) do nothing;

-- ---- Decision 37 amendment (c): the availability warning ---------------------
-- Both create paths call this after a series is assigned to an instructor. It is
-- a COUNT over the occurrences actually materialised (not a re-implementation of
-- the rule): future scheduled occurrences of the series whose assigned instructor
-- is not valid_on their local date. Null (no warning) when the count is zero —
-- which is every Reform instructor today, since none has stated any availability
-- and instructor_valid_on is true when nothing is stated.
create or replace function series_availability_warning(p_series_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_tz text; v_instr uuid; v_name text; v_count int;
begin
  select ser.studio_id, ser.instructor_id into v_studio, v_instr
    from class_series ser where ser.id = p_series_id;
  if v_studio is null then raise exception 'no such series' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(v_studio), false) and not is_service_context() then
    raise exception 'only owners and managers see the timetable' using errcode = 'PT403';
  end if;
  if v_instr is null then return null; end if;               -- unassigned series
  select timezone into v_tz from studios where id = v_studio;
  select count(*) into v_count
    from class_occurrences o
   where o.series_id = p_series_id and o.status = 'scheduled' and o.starts_at > now()
     and o.instructor_id is not null
     and not instructor_valid_on(o.instructor_id, (o.starts_at at time zone v_tz)::date);
  if coalesce(v_count, 0) = 0 then return null; end if;
  select display_name into v_name from instructors where id = v_instr;
  return jsonb_build_object('count', v_count, 'instructor_name', coalesce(v_name, 'that instructor'));
end $$;
revoke execute on function series_availability_warning(uuid) from public, anon;
grant  execute on function series_availability_warning(uuid) to authenticated, service_role;

-- ---- The request stamp (a trigger, so every assignment path is caught) -------
-- BEFORE the write, so it can set the row's own columns. A request is recorded
-- when an occurrence BECOMES assigned to a login instructor while the setting is
-- on. Reassignment clears both and re-requests; unassigning clears both.
create or replace function tg_stamp_assignment_request() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_on boolean;
begin
  -- Only when the assignment actually changes (or on insert). A time-only move
  -- that re-sets instructor_id to the same value leaves the confirmation alone.
  if tg_op = 'UPDATE' and new.instructor_id is not distinct from old.instructor_id then
    return new;
  end if;
  -- The arrangement changed: a prior confirmation no longer holds.
  new.assignment_confirmed_at := null;
  new.assignment_requested_at := null;
  if new.instructor_id is not null then
    select assignment_confirmations into v_on from studio_settings where studio_id = new.studio_id;
    if coalesce(v_on, false) and instructor_user_id(new.instructor_id) is not null then
      new.assignment_requested_at := now();
    end if;
  end if;
  return new;
end $$;
revoke execute on function tg_stamp_assignment_request() from public, anon, authenticated;

drop trigger if exists class_occurrences_stamp_assignment on class_occurrences;
create trigger class_occurrences_stamp_assignment
  before insert or update of instructor_id on class_occurrences
  for each row execute function tg_stamp_assignment_request();

-- ---- The coalesced email (mirrors Decision 33's booking-alert writer) --------
-- ONE digest per instructor per studio-local day: dedupe on instructor + local
-- date, schedule at the end of the local day so the day's assignments arrive as
-- one email, and recompute the FULL pending list into the payload each call so
-- the digest lists everything still needing confirmation. Published months only.
create or replace function queue_assignment_request(p_occurrence_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  o class_occurrences%rowtype; s studios%rowtype; st studio_settings%rowtype;
  v_user uuid; v_day date; v_dedupe text; v_sched timestamptz;
  v_body text; v_link text; v_fname text; v_n int;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found or o.instructor_id is null then return; end if;
  select * into st from studio_settings where studio_id = o.studio_id;
  if not coalesce(st.assignment_confirmations, false) then return; end if;   -- switch off
  if not month_published(o.studio_id, o.starts_at) then return; end if;      -- Decision 25
  v_user := instructor_user_id(o.instructor_id);
  if v_user is null then return; end if;                                     -- no login
  select * into s from studios where id = o.studio_id;

  v_day    := (now() at time zone s.timezone)::date;
  v_dedupe := 'assignment_confirm:' || o.instructor_id || ':' || v_day;
  v_sched  := (date_trunc('day', (now() at time zone s.timezone)) + interval '1 day') at time zone s.timezone;
  v_fname  := split_part(coalesce((select display_name from instructors where id = o.instructor_id), ''), ' ', 1);
  v_link   := 'https://' || s.slug || '.'
              || coalesce(notification_setting('member_app_domain'), 'studiior.app')
              || '/instructor/schedule';

  -- The full pending list for this instructor, grouped by series slot.
  select string_agg(line, E'\n' order by first_at), sum(cnt)::int
    into v_body, v_n
    from (
      select
        'Every ' || to_char(min(o2.starts_at at time zone s.timezone), 'FMDy') || ' '
          || to_char(min(o2.starts_at at time zone s.timezone), 'HH24:MI') || ' ' || o2.name
          || ' — ' || count(*) || ' ' || case when count(*) = 1 then 'class' else 'classes' end
          || ', ' || to_char(min(o2.starts_at at time zone s.timezone), 'FMDD FMMon')
          || ' to ' || to_char(max(o2.starts_at at time zone s.timezone), 'FMDD FMMon') as line,
        count(*) as cnt, min(o2.starts_at) as first_at
        from class_occurrences o2
       where o2.instructor_id = o.instructor_id and o2.status = 'scheduled'
         and o2.starts_at > now()
         and o2.assignment_requested_at is not null and o2.assignment_confirmed_at is null
         and month_published(o2.studio_id, o2.starts_at)
       group by coalesce(o2.series_id::text, o2.id::text), o2.name,
                extract(dow from o2.starts_at at time zone s.timezone),
                to_char(o2.starts_at at time zone s.timezone, 'HH24:MI')
    ) q;
  if coalesce(v_n, 0) = 0 then return; end if;

  insert into notifications (studio_id, recipient_type, user_id, template_key, channel,
                             payload, dedupe_key, scheduled_for, status)
  values (o.studio_id, 'staff', v_user, 'assignment_confirmation_request', 'email',
          jsonb_build_object('first_name', v_fname, 'class_list', v_body, 'count', v_n,
                             'schedule_link', v_link, 'studio_name', s.name),
          v_dedupe, v_sched, 'scheduled')
  on conflict (dedupe_key) do update
    set payload = excluded.payload
    where notifications.status = 'scheduled';
end $$;
revoke execute on function queue_assignment_request(uuid) from public, anon, authenticated;
grant  execute on function queue_assignment_request(uuid) to service_role;

create or replace function tg_queue_assignment_request() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.assignment_requested_at is not null and new.assignment_confirmed_at is null
     and (tg_op = 'INSERT' or new.instructor_id is distinct from old.instructor_id) then
    perform queue_assignment_request(new.id);
  end if;
  return null;
end $$;
revoke execute on function tg_queue_assignment_request() from public, anon, authenticated;

drop trigger if exists class_occurrences_queue_assignment on class_occurrences;
create trigger class_occurrences_queue_assignment
  after insert or update of instructor_id on class_occurrences
  for each row execute function tg_queue_assignment_request();

-- ---- Instructor: confirm --------------------------------------------------
create or replace function confirm_assignment(p_occurrence_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o class_occurrences%rowtype;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if o.instructor_id is null or o.instructor_id is distinct from auth_instructor_id(o.studio_id) then
    raise exception 'that is not your class to confirm' using errcode = 'PT403';
  end if;
  update class_occurrences set assignment_confirmed_at = now()
   where id = p_occurrence_id
     and assignment_requested_at is not null and assignment_confirmed_at is null;
  return jsonb_build_object('ok', true, 'occurrence_id', p_occurrence_id);
end $$;
revoke execute on function confirm_assignment(uuid) from public, anon;
grant  execute on function confirm_assignment(uuid) to authenticated, service_role;

create or replace function confirm_series_assignments(p_series_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_studio uuid; v_me uuid; v_n int;
begin
  select studio_id into v_studio from class_series where id = p_series_id;
  if v_studio is null then raise exception 'no such series' using errcode = 'PT404'; end if;
  v_me := auth_instructor_id(v_studio);
  if v_me is null then raise exception 'that is not yours to confirm' using errcode = 'PT403'; end if;
  with upd as (
    update class_occurrences set assignment_confirmed_at = now()
     where series_id = p_series_id and instructor_id = v_me
       and status = 'scheduled' and starts_at > now()
       and assignment_requested_at is not null and assignment_confirmed_at is null
    returning 1)
  select count(*) into v_n from upd;
  return jsonb_build_object('ok', true, 'confirmed', v_n);
end $$;
revoke execute on function confirm_series_assignments(uuid) from public, anon;
grant  execute on function confirm_series_assignments(uuid) to authenticated, service_role;

-- "Can't make it" is NOT a new function. Decision 18 stands: an instructor never
-- releases a class themselves. The confirmation UI's "Can't make it" calls the
-- existing withdraw_from_shift(), which raises a COVER REQUEST and leaves the
-- class assigned to them until someone covers it. The assignment_requested_at /
-- assignment_confirmed_at state is untouched by that path (it does not change
-- instructor_id), so the class stays requested-and-unconfirmed until it is
-- covered or confirmed. No decline_assignment function exists.

-- ---- Instructor: the "Needs your confirmation" reader ------------------------
create or replace function instructor_assignment_requests(p_instructor_id uuid)
returns table(occurrence_id uuid, name text, local_date date, local_start text,
              local_end text, room_name text, series_id uuid, series_name text)
language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_tz text;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(v_studio), false)
     and p_instructor_id is distinct from auth_instructor_id(v_studio)
     and not is_service_context() then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = v_studio;
  return query
  select o.id, o.name, (o.starts_at at time zone v_tz)::date,
         to_char(o.starts_at at time zone v_tz, 'HH24:MI'),
         to_char(o.ends_at   at time zone v_tz, 'HH24:MI'),
         r.name, o.series_id, ser.name
    from class_occurrences o
    left join rooms r on r.id = o.room_id
    left join class_series ser on ser.id = o.series_id
   where o.instructor_id = p_instructor_id and o.status = 'scheduled'
     and o.starts_at > now()
     and o.assignment_requested_at is not null and o.assignment_confirmed_at is null
     and month_published(v_studio, o.starts_at)
   order by o.starts_at;
end $$;
revoke execute on function instructor_assignment_requests(uuid) from public, anon;
grant  execute on function instructor_assignment_requests(uuid) to authenticated, service_role;

-- ---- Owner: series page — summary and the "ask" for pre-existing assignments -
create or replace function series_confirmation_summary(p_series_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_total int; v_conf int;
begin
  select studio_id into v_studio from class_series where id = p_series_id;
  if v_studio is null then raise exception 'no such series' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(v_studio), false) and not is_service_context() then
    raise exception 'only owners and managers see the timetable' using errcode = 'PT403';
  end if;
  select count(*), count(*) filter (where assignment_confirmed_at is not null)
    into v_total, v_conf
    from class_occurrences
   where series_id = p_series_id and status = 'scheduled' and starts_at > now()
     and assignment_requested_at is not null;
  if coalesce(v_total, 0) = 0 then return null; end if;
  return jsonb_build_object('confirmed', v_conf, 'total', v_total);
end $$;
revoke execute on function series_confirmation_summary(uuid) from public, anon;
grant  execute on function series_confirmation_summary(uuid) to authenticated, service_role;

-- Requests confirmation for the future unconfirmed occurrences of a series whose
-- instructor has a login — the path for classes assigned BEFORE the setting was
-- turned on (the trigger never fired for those). A direct UPDATE of
-- assignment_requested_at does not touch instructor_id, so it does not fire the
-- queue trigger; this queues the digest itself.
create or replace function request_series_confirmations(p_series_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_studio uuid; v_on boolean; v_n int; rec record;
begin
  select studio_id into v_studio from class_series where id = p_series_id;
  if v_studio is null then raise exception 'no such series' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(v_studio), false) then
    raise exception 'only owners and managers change the timetable' using errcode = 'PT403';
  end if;
  select assignment_confirmations into v_on from studio_settings where studio_id = v_studio;
  if not coalesce(v_on, false) then
    return jsonb_build_object('ok', false, 'reason', 'off', 'requested', 0);
  end if;
  with upd as (
    update class_occurrences o set assignment_requested_at = now()
     where o.series_id = p_series_id and o.status = 'scheduled' and o.starts_at > now()
       and o.instructor_id is not null and instructor_user_id(o.instructor_id) is not null
       and o.assignment_requested_at is null and o.assignment_confirmed_at is null
    returning o.id)
  select count(*) into v_n from upd;

  -- Queue one digest per affected instructor (coalesced inside the queue fn).
  for rec in
    select distinct on (o.instructor_id) o.id
      from class_occurrences o
     where o.series_id = p_series_id and o.status = 'scheduled' and o.starts_at > now()
       and o.assignment_requested_at is not null and o.assignment_confirmed_at is null
     order by o.instructor_id, o.starts_at
  loop
    perform queue_assignment_request(rec.id);
  end loop;

  return jsonb_build_object('ok', true, 'requested', v_n);
end $$;
revoke execute on function request_series_confirmations(uuid) from public, anon;
grant  execute on function request_series_confirmations(uuid) to authenticated, service_role;

-- ---- schedule_range carries the two states (drop + recreate: a RETURNS TABLE
--      cannot gain columns via create-or-replace; re-assert the ACL) -----------
drop function if exists schedule_range(uuid, date, date);
create function schedule_range(p_studio_id uuid, p_from date, p_to date)
 returns table(occ_id uuid, occ_name text, starts_at timestamptz, ends_at timestamptz,
   local_date date, local_start text, local_end text, start_minutes integer, end_minutes integer,
   occ_instructor_id uuid, room_name text, occ_capacity integer, occ_booked integer,
   occ_waitlist integer, occ_staffing text, occ_status text, occ_flex boolean, occ_confirmed boolean,
   occ_tier text, occ_standalone boolean, occ_series_tier text, occ_minimum integer,
   occ_cancellation_cause text, occ_assignment_requested boolean, occ_assignment_confirmed boolean)
 language plpgsql stable security definer set search_path = public as $function$
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
         o.cancellation_cause::text,
         -- Decision 38: the assigned-class confirmation state, for the calendar.
         o.assignment_requested_at is not null,
         o.assignment_confirmed_at is not null
    from class_occurrences o
    cross join lateral occurrence_guarantee(o.id) g
    left join class_series ser on ser.id = o.series_id
    left join rooms r on r.id = o.room_id
   where o.studio_id = p_studio_id
     and (o.status <> 'cancelled' or o.cancellation_cause = 'unmet_minimum')
     and (o.starts_at at time zone v_tz)::date between p_from and p_to
   order by o.starts_at;
end $function$;
revoke execute on function schedule_range(uuid, date, date) from public, anon;
grant  execute on function schedule_range(uuid, date, date) to authenticated, service_role;

-- ---- Anon surface unchanged --------------------------------------------------
do $$
declare v_n int;
begin
  select count(*) into v_n from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
   where nsp.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if v_n <> 11 then raise exception 'anon surface is % functions, expected 11', v_n; end if;
  if has_function_privilege('anon', 'schedule_range(uuid,date,date)'::regprocedure, 'execute') then
    raise exception 'schedule_range is reachable by anon';
  end if;
  if not has_function_privilege('authenticated', 'schedule_range(uuid,date,date)'::regprocedure, 'execute') then
    raise exception 'schedule_range lost the grant it needs';
  end if;
end $$;
