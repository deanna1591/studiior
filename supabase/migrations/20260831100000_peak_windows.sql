-- =============================================================================
-- 104 — Decision 24: when peak is, and which plans are held to it.
--
-- SCHEMA AND ONE PREDICATE. Nothing in this migration changes what happens when
-- anybody books: `book_class()` is untouched, no ledger exists yet, and a studio
-- that turns the switch on and draws its windows sees the windows and nothing
-- else. The allowance itself arrives in 106, after 105 carries the enum values
-- it needs.
--
-- Off by default, invisible when off, and independent of the seat caps in 102 —
-- the three switches of Decision 24 are three switches.
--
-- -----------------------------------------------------------------------------
-- `daily_booking_cap` IS NOT IN THIS MIGRATION BECAUSE IT ALREADY EXISTS.
--
-- The brief asks for a per-plan daily cap. `membership_plans.max_bookings_per_day`
-- has been that column since migration 001, `book_class()` rule 2.1.7 has
-- enforced it per plan in studio-local days since migration 002 with its own
-- `daily_limit_reached` reason, and the plan form has written it since the plans
-- screen was built. Adding `daily_booking_cap` beside it would be a second
-- implementation of one rule — the two would agree the day they were written
-- and the first one edited would silently diverge. Unlimited Monthly's "daily
-- cap 1" is `max_bookings_per_day = 1`, today, with no new code.
-- =============================================================================

alter table studio_settings
  add column if not exists peak_allowance_enabled boolean not null default false;

comment on column studio_settings.peak_allowance_enabled is
  'Decision 24: whether this studio has peak hours that plans can be limited to. '
  'Off by default. While off, peak windows and plan allowances are stored but never consulted.';

-- -----------------------------------------------------------------------------
-- WHEN PEAK IS.
--
-- Per studio, per day of week, as STUDIO-LOCAL WALL TIMES. Storing a time rather
-- than an instant is what makes it DST-proof for nothing: 17:00 is 17:00 on both
-- sides of a clock change, where an offset would have drifted an hour and moved
-- the evening rush off the evening.
--
-- Several per day, deliberately. Reform Collective's are 07:00–09:00 and
-- 17:00–19:00, and a single window per day could not say that.
--
-- `day_of_week` is 0=Sunday, matching `extract(dow)` and `week_starts_on`, so
-- nothing has to translate between two conventions.
-- -----------------------------------------------------------------------------
create table if not exists peak_windows (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid not null references studios(id) on delete cascade,
  day_of_week   int  not null check (day_of_week between 0 and 6),
  starts_at     time not null,
  ends_at       time not null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  is_demo       boolean not null default false,
  -- A window that ends before it starts is not a window. Midnight-spanning is
  -- deliberately not expressible: a 22:00–02:00 "peak" is two windows on two
  -- days, and letting one row mean two days would make every reader of this
  -- table decide for itself what the row means.
  constraint peak_window_ends_after_start check (ends_at > starts_at)
);

-- Overlapping windows on one day are harmless — a class is peak if ANY window
-- covers it — but an exact duplicate is a double-clicked form, not a decision.
create unique index if not exists peak_windows_no_duplicates
  on peak_windows (studio_id, day_of_week, starts_at, ends_at);
create index if not exists peak_windows_studio_day
  on peak_windows (studio_id, day_of_week);

drop trigger if exists peak_windows_updated on peak_windows;
create trigger peak_windows_updated before update on peak_windows
  for each row execute function set_updated_at();

alter table peak_windows enable row level security;

-- Managers decide when peak is; front desk and instructors read it because the
-- roster and the desk both have to be able to say why a member was refused.
-- Members read it because a badged slot in the member app is this table.
drop policy if exists peak_windows_manager_write on peak_windows;
create policy peak_windows_manager_write on peak_windows
  for all using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));

drop policy if exists peak_windows_staff_read on peak_windows;
create policy peak_windows_staff_read on peak_windows
  for select using (studio_id in (select auth_staff_studios()));

drop policy if exists peak_windows_member_read on peak_windows;
create policy peak_windows_member_read on peak_windows
  for select using (studio_id in (select auth_member_studios()));

grant select, insert, update, delete on peak_windows to authenticated;
grant all on peak_windows to service_role;

-- -----------------------------------------------------------------------------
-- WHICH PLANS ARE HELD TO IT.
--
-- `peak_allowance` null means UNLIMITED and is what every plan says until a
-- studio decides otherwise — the same convention `credits_per_period` already
-- uses (Decision 12), so there is one reading of a null allowance in this
-- schema rather than two.
--
-- ZERO IS ALLOWED AND MEANS SOMETHING DIFFERENT: this plan may not book peak
-- classes at all. That is a real off-peak product, and it is not the same
-- sentence as "no limit".
-- -----------------------------------------------------------------------------
alter table membership_plans
  add column if not exists peak_allowance        int,
  add column if not exists peak_allowance_period text not null default 'week';

comment on column membership_plans.peak_allowance is
  'Decision 24: how many peak classes this plan may book per period. Null means no limit, '
  'which is every plan until a studio says otherwise. Zero means no peak classes at all.';
comment on column membership_plans.peak_allowance_period is
  'week or month. A week is a FIXED week from the studio''s week_starts_on, never a rolling 168 hours.';

alter table membership_plans
  drop constraint if exists plan_peak_allowance_not_negative,
  drop constraint if exists plan_peak_allowance_period_known,
  drop constraint if exists plan_peak_allowance_unlimited_only;

alter table membership_plans
  add constraint plan_peak_allowance_not_negative
    check (peak_allowance is null or peak_allowance >= 0),
  add constraint plan_peak_allowance_period_known
    check (peak_allowance_period in ('week', 'month')),
  -- A PLAN WITH CREDITS DOES NOT GET A SECOND PENALTY, and this makes that a
  -- rule rather than a convention somebody follows until they do not.
  --
  -- A pack, a drop-in and an 8-a-month plan already pay for a wasted class with
  -- the credit, which is worth real money and which `no_show_consumes_credit`
  -- and `late_cancel_consumes_credit` already take. An allowance on top would
  -- charge twice for one no-show. Only an UNLIMITED recurring plan has no such
  -- penalty, and it is the only kind that can carry one — which is exactly the
  -- plan whose scarcity is the problem: Reform Collective's Unlimited Monthly.
  --
  -- Migrations 009 and 010 set this shape: the plan-type field rules are CHECK
  -- constraints, not documentation.
  add constraint plan_peak_allowance_unlimited_only
    check (peak_allowance is null
           or (type = 'recurring' and credits_per_period is null));

-- -----------------------------------------------------------------------------
-- IS THIS CLASS PEAK? One predicate, and everything asks it.
--
-- A class is peak if its SCHEDULED START falls inside a window. Half-open on
-- purpose: 16:55 against a 17:00–19:00 window is off-peak, and so is a 19:00
-- class, because a window is the hours you are trying to protect and a class
-- starting as it ends is not in it. That rule has to live in one place or the
-- member app, the booking gate and the reporting will each round it differently.
--
-- The class's own local day and time, resolved through the studio's timezone, so
-- a 07:00 Manila class is Manila's Wednesday 07:00 whatever the server thinks.
--
-- Unguarded and SECURITY DEFINER: it answers a question about an occurrence,
-- and every caller is either inside the database or has already been through
-- RLS on `class_occurrences`. It is closed to every client role — the screens
-- ask `occurrence_peak_flags()` below, which is guarded.
-- -----------------------------------------------------------------------------
create or replace function occurrence_is_peak(p_occurrence_id uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
      from class_occurrences o
      join studios s on s.id = o.studio_id
      join peak_windows w on w.studio_id = o.studio_id
     where o.id = p_occurrence_id
       and w.day_of_week = extract(dow from (o.starts_at at time zone s.timezone))::int
       and (o.starts_at at time zone s.timezone)::time >= w.starts_at
       and (o.starts_at at time zone s.timezone)::time <  w.ends_at
  )
$$;

-- -----------------------------------------------------------------------------
-- What a screen asks: the studio's windows, and how much of its timetable each
-- one actually catches.
--
-- THE COUNT IS THE POINT. A studio drawing 07:00–09:00 on a grid cannot tell
-- from the grid whether that is four classes a week or forty, and a peak window
-- that catches the whole timetable is an allowance that stops everybody booking
-- anything. The number is measured against the classes that are really there.
--
-- NO ROWS when the switch is off, the same as `plan_seats()`: "this studio does
-- not use peak hours" and "no windows drawn" are the same absence.
-- -----------------------------------------------------------------------------
create or replace function studio_peak_windows(p_studio_id uuid)
returns table (
  id            uuid,
  day_of_week   int,
  starts_at     time,
  ends_at       time,
  upcoming      int)
language plpgsql stable security definer set search_path = public as $$
declare
  v_staff boolean;
  v_member boolean;
  v_tz text;
begin
  -- Staff at ANY role, instructors included: a roster that badges a peak class
  -- is this table, and an instructor explaining a refusal at the door needs to
  -- be able to see the window that caused it.
  v_staff  := p_studio_id in (select auth_staff_studios());
  v_member := p_studio_id in (select auth_member_studios());
  if not (coalesce(v_staff, false) or coalesce(v_member, false)) then
    raise exception 'that studio is not yours' using errcode = 'PT403';
  end if;

  if not coalesce((select ss.peak_allowance_enabled from studio_settings ss
                    where ss.studio_id = p_studio_id), false) then
    return;
  end if;

  select s.timezone into v_tz from studios s where s.id = p_studio_id;

  return query
  select w.id, w.day_of_week, w.starts_at, w.ends_at,
         (select count(*)::int
            from class_occurrences o
           where o.studio_id = p_studio_id
             and o.status = 'scheduled'
             and o.starts_at > now()
             and o.starts_at < now() + interval '28 days'
             and extract(dow from (o.starts_at at time zone v_tz))::int = w.day_of_week
             and (o.starts_at at time zone v_tz)::time >= w.starts_at
             and (o.starts_at at time zone v_tz)::time <  w.ends_at)
    from peak_windows w
   where w.studio_id = p_studio_id
   order by w.day_of_week, w.starts_at;
end $$;

revoke execute on function occurrence_is_peak(uuid) from public, anon, authenticated;
grant  execute on function occurrence_is_peak(uuid) to service_role;

revoke execute on function studio_peak_windows(uuid) from public, anon;
grant  execute on function studio_peak_windows(uuid) to authenticated, service_role;

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure::text as sig,
           has_function_privilege('anon', p.oid, 'execute') as anon,
           has_function_privilege('authenticated', p.oid, 'execute') as authed
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('occurrence_is_peak', 'studio_peak_windows')
  loop
    if r.anon then
      raise exception 'migration 104: % is reachable by anon', r.sig;
    end if;
    if r.authed and r.sig not like 'studio_peak_windows(%' then
      raise exception 'migration 104: % is reachable by authenticated', r.sig;
    end if;
  end loop;
end $$;
