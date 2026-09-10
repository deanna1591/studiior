-- =============================================================================
-- 080  Decision 22, part 1: guarantee tiers.
-- =============================================================================
-- Decision 21 built flex as a boolean. A boolean has two states and this needs
-- three, so `flex` becomes a TIER and the boolean stays as the compatibility
-- surface underneath it rather than a second source of truth.
--
--   core    runs at >= core_min_bookings. If unmet it does not run and the
--           instructor is paid a holding rate. THE DEFAULT, and the reason a
--           studio that never touches any of this sees no change: at
--           core_min_bookings 1, a class with one booking commits and pays in
--           full, which is what happens today.
--   flex    runs at >= min_bookings. If unmet, no pay and no obligation.
--           Decision 21's existing behaviour, unchanged.
--   always  runs unconditionally and is never auto-cancelled.
--
-- TWO CUTOFF SHAPES, NOT COLLAPSED. Core measures backwards from the class
-- because it mirrors the cancellation window and the headcount is effectively
-- final by then. Flex is a wall-clock time the evening before, so an instructor
-- can plan a whole day at once. Decision 21 already implements both shapes in
-- flex_pending(); this keeps them and gives each tier its own.
-- =============================================================================

create type guarantee_tier as enum ('core', 'flex', 'always');

alter table class_series
  add column if not exists guarantee_tier guarantee_tier not null default 'core';
alter table class_occurrences
  add column if not exists guarantee_tier guarantee_tier;

comment on column class_occurrences.guarantee_tier is
  'Overrides the series tier for this one class. Null means inherit. Resolved '
  'through occurrence_tier(), never by reading either column directly.';

-- Decision 21's rows carry flex = true and no tier. Bring them across so the
-- two never disagree, in the one direction that is safe: a flex series is a
-- flex-tier series, and everything else is core, which is what it already was.
update class_series     set guarantee_tier = 'flex' where flex;
update class_occurrences set guarantee_tier = 'flex' where flex;

-- -----------------------------------------------------------------------------
-- Per-studio settings, overridable per series
-- -----------------------------------------------------------------------------
-- Money is integer cents plus the studio's own currency, never floats, and a
-- percentage is an integer.
alter table studio_settings
  add column if not exists guarantees_enabled     boolean not null default false,
  add column if not exists core_min_bookings      int  not null default 1,
  add column if not exists core_cutoff_hours      int  not null default 12,
  add column if not exists core_unmet_pay_pct     int  not null default 50,
  add column if not exists flex_min_bookings      int  not null default 1,
  add column if not exists flex_unmet_pay_cents   int  not null default 0,
  add column if not exists flex_standby_pay_cents int  not null default 0,
  add column if not exists adjacency_minutes      int  not null default 90;

alter table studio_settings
  add constraint core_unmet_pay_pct_range check (core_unmet_pay_pct between 0 and 100),
  add constraint core_min_bookings_sane   check (core_min_bookings   >= 0),
  add constraint flex_min_bookings_sane   check (flex_min_bookings   >= 0),
  add constraint core_cutoff_hours_sane   check (core_cutoff_hours   >= 0),
  add constraint adjacency_minutes_sane   check (adjacency_minutes   between 0 and 1440),
  add constraint flex_unmet_pay_sane      check (flex_unmet_pay_cents   >= 0),
  add constraint flex_standby_pay_sane    check (flex_standby_pay_cents >= 0);

-- flex_deadline_mode / _hours / _time already exist from Decision 21 and are the
-- FLEX cutoff. Core's is core_cutoff_hours, a rolling offset, deliberately a
-- different shape.

alter table class_series
  add column if not exists core_min_bookings int,
  add column if not exists core_cutoff_hours int;
alter table class_occurrences
  add column if not exists core_min_bookings int;

-- -----------------------------------------------------------------------------
-- Resolving a tier and its threshold, in ONE place
-- -----------------------------------------------------------------------------
-- Occurrence override, then series, then studio default. Every reader goes
-- through this: a precedence rule written out at each call site is one the next
-- call site will get subtly wrong, which is what happened to availability
-- before migration 066 gave it a single ladder.
create or replace function occurrence_guarantee(p_occurrence_id uuid)
returns table (tier guarantee_tier, minimum int, cutoff_at timestamptz, cutoff_shape text)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare o class_occurrences%rowtype; ser class_series%rowtype;
        s studio_settings%rowtype; v_tz text; v_tier guarantee_tier;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then return; end if;
  select * into s from studio_settings where studio_id = o.studio_id;
  select timezone into v_tz from studios where id = o.studio_id;
  if o.series_id is not null then
    select * into ser from class_series where id = o.series_id;
  end if;

  -- The boolean is the COMPATIBILITY SURFACE and is read here, not ignored.
  -- Decision 21's writers, the existing screens and any hand-written row set
  -- `flex` and nothing else; a resolver that only looked at the new column
  -- would quietly demote every one of them to core — which is a class that
  -- cancels for want of one booking becoming a class somebody is paid a holding
  -- rate for. Occurrence column, occurrence boolean, series column, series
  -- boolean, then core.
  v_tier := coalesce(
    o.guarantee_tier,
    case when o.flex then 'flex'::guarantee_tier end,
    ser.guarantee_tier,
    case when ser.flex then 'flex'::guarantee_tier end,
    'core'::guarantee_tier);

  -- TWO SWITCHES, NOT ONE, and collapsing them breaks Decision 21.
  --
  -- flex_enabled has governed flex evaluation since Decision 21 and goes on
  -- doing exactly that. guarantees_enabled is Decision 22's own switch and
  -- governs CORE. A studio already running flex therefore keeps working
  -- untouched without opting into anything, and — the half that matters more —
  -- does not silently acquire core evaluation on every other class it runs.
  --
  -- A tier whose switch is off resolves to 'always': it runs, nothing evaluates
  -- it, nothing is owed for it not running. That is exactly what a studio that
  -- has never heard of this feature already experiences, and saying it once
  -- here rather than filtering in five callers is what makes "sees no change"
  -- true rather than merely intended.
  if v_tier = 'core' and not coalesce(s.guarantees_enabled, false) then
    return query select 'always'::guarantee_tier, 0, null::timestamptz, 'none'::text;
    return;
  elsif v_tier = 'flex' and not coalesce(s.flex_enabled, false) then
    return query select 'always'::guarantee_tier, 0, null::timestamptz, 'none'::text;
    return;
  end if;

  if v_tier = 'always' then
    -- ALWAYS STILL COMMITS, at the moment the class starts.
    --
    -- It has no minimum to reach, but it does need a terminal transition, because
    -- that is where pay is written and locked. Without one an 'always' class
    -- would be the only tier nobody is ever paid for. Nothing in this codebase
    -- moves a class to status 'completed' — only the demo generator and the seed
    -- ever write that value — so the class's own start time is the honest
    -- boundary, and the headcount at that moment is what it ran with.
    --
    -- The distinction from a demoted tier is the SHAPE: 'at_start' is a real
    -- always-tier class that will commit, 'none' is a studio with the switch off
    -- and nothing to evaluate at all.
    return query select v_tier, 0,
      case when coalesce(s.guarantees_enabled, false) or coalesce(s.flex_enabled, false)
           then o.starts_at end,
      case when coalesce(s.guarantees_enabled, false) or coalesce(s.flex_enabled, false)
           then 'at_start' else 'none' end::text;
  elsif v_tier = 'core' then
    return query select v_tier,
      coalesce(o.core_min_bookings, ser.core_min_bookings, s.core_min_bookings, 1),
      -- A ROLLING OFFSET from the class. Nothing to convert: an interval before
      -- an instant is the same instant in every timezone.
      o.starts_at - make_interval(hours => coalesce(ser.core_cutoff_hours, s.core_cutoff_hours, 12)),
      'hours_before'::text;
  else
    return query select v_tier,
      coalesce(o.minimum_bookings, ser.minimum_bookings, s.flex_min_bookings, 1),
      case
        when s.flex_deadline_mode = 'hours_before'
          then o.starts_at - make_interval(hours => s.flex_deadline_hours)
        -- The night before at the studio's own clock time, computed by taking
        -- the class's LOCAL date, stepping back a day and pinning the time, then
        -- interpreting that back in the zone. Never by subtracting an interval,
        -- which drifts an hour across a clock change — 20:00 stays 20:00.
        else ((((o.starts_at at time zone v_tz)::date - 1) + s.flex_deadline_time)
              at time zone v_tz)
      end,
      coalesce(s.flex_deadline_mode, 'previous_day_at')::text;
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- Adjacency: is this a standalone trip?
-- -----------------------------------------------------------------------------
-- Computed at evaluation, never stored: it depends on what else is on the
-- instructor's day, and what else is on the instructor's day changes until the
-- moment it is asked. A standalone flex slot costs a trip for one class, which
-- is where standby pay is warranted and why the schedule editor flags it.
create or replace function occurrence_is_adjacent(p_occurrence_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare o class_occurrences%rowtype; v_tz text; v_mins int; v_found boolean;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found or o.instructor_id is null then return false; end if;
  select timezone into v_tz from studios where id = o.studio_id;
  select coalesce(adjacency_minutes, 90) into v_mins
    from studio_settings where studio_id = o.studio_id;

  select exists (
    select 1 from class_occurrences x
     where x.instructor_id = o.instructor_id
       and x.id <> o.id
       and x.status = 'scheduled'
       -- The STUDIO's day, not the server's. An instructor's day is the one
       -- they turn up for.
       and (x.starts_at at time zone v_tz)::date = (o.starts_at at time zone v_tz)::date
       -- Gap measured edge to edge, in either direction.
       and least(x.ends_at, o.ends_at) + make_interval(mins => v_mins)
             >= greatest(x.starts_at, o.starts_at)
  ) into v_found;
  return coalesce(v_found, false);
end $$;

-- -----------------------------------------------------------------------------
-- Setting a tier
-- -----------------------------------------------------------------------------
-- Reaches the classes already on the calendar, for the reason set_series_flex()
-- was written that way: a studio that changes a tier and finds nothing changes
-- for sixty days has been given a setting that does nothing.
create or replace function set_series_guarantee(p_series_id uuid,
                                                p_tier guarantee_tier,
                                                p_min_bookings int default null,
                                                p_core_cutoff_hours int default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare ser class_series%rowtype; n int;
begin
  select * into ser from class_series where id = p_series_id;
  if not found then raise exception 'no such series' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(ser.studio_id), false) then
    raise exception 'only owners and managers set a guarantee' using errcode = 'PT403';
  end if;
  if p_min_bookings is not null and p_min_bookings < 0 then
    raise exception 'a minimum cannot be negative' using errcode = 'PT422';
  end if;

  update class_series
     set guarantee_tier   = p_tier,
         flex             = (p_tier = 'flex'),   -- kept in step, never consulted separately
         minimum_bookings = case when p_tier = 'flex'
                                 then coalesce(p_min_bookings, minimum_bookings)
                                 else minimum_bookings end,
         core_min_bookings = case when p_tier = 'core'
                                  then coalesce(p_min_bookings, core_min_bookings)
                                  else core_min_bookings end,
         core_cutoff_hours = coalesce(p_core_cutoff_hours, core_cutoff_hours),
         updated_at = now()
   where id = p_series_id;

  update class_occurrences o
     set guarantee_tier = p_tier,
         flex           = (p_tier = 'flex'),
         minimum_bookings = case when p_tier = 'flex'
                                 then coalesce(p_min_bookings, o.minimum_bookings)
                                 else o.minimum_bookings end,
         core_min_bookings = case when p_tier = 'core'
                                  then coalesce(p_min_bookings, o.core_min_bookings)
                                  else o.core_min_bookings end,
         updated_at = now()
   where o.series_id = p_series_id
     and o.starts_at > now()
     and o.status = 'scheduled'
     and o.flex_confirmed_at is null;   -- a committed class is settled.
                                        -- 081 renames this to committed_at.
  get diagnostics n = row_count;

  return jsonb_build_object('ok', true, 'tier', p_tier, 'occurrences_updated', n);
end $$;

revoke execute on function occurrence_guarantee(uuid)   from public, anon, authenticated;
revoke execute on function occurrence_is_adjacent(uuid) from public, anon, authenticated;
revoke execute on function set_series_guarantee(uuid, guarantee_tier, int, int)
  from public, anon, authenticated;
grant execute on function occurrence_guarantee(uuid)   to authenticated, service_role;
grant execute on function occurrence_is_adjacent(uuid) to authenticated, service_role;
grant execute on function set_series_guarantee(uuid, guarantee_tier, int, int) to authenticated;
