-- =============================================================================
-- Decision 56 — recent bookings on the dashboard, and core/flex tier suggestions.
-- =============================================================================
-- creates: dashboard_recent_bookings(uuid, integer), tier_suggestions(uuid)
--
-- Two read-only views over data that already exists. dashboard_recent_bookings
-- is the newest bookings and cancellations across the studio (desk-up, no
-- amounts); tier_suggestions reads Decision 22's core-minimum rule backwards to
-- flag a core class that keeps missing its minimum or a flex class that always
-- clears it (manager-up — tier is a pay decision). Nothing is stored, nothing
-- changes automatically, no AI is called: the rule IS the suggestion. Neither
-- function is anon — the surface stays exactly twelve.
-- =============================================================================

-- --- Recent bookings: newest bookings and cancellations, desk-up. ------------
-- A member's booking shows as ONE row — a booked seat while booked/attended,
-- a cancellation once they cancel (the same row's status flips, so it is never
-- counted twice). A free-first/comp seat reads "booked a free class". A staff
-- or system class cancellation (Decision 47) is ONE row per occurrence saying
-- how many members it notified; those released bookings carry release_reason
-- 'studio_released', which is exactly what excludes them from the member
-- cancellation list, so a studio release is never double-reported.
create or replace function dashboard_recent_bookings(
  p_studio_id uuid, p_limit int default 30
) returns table (
  kind text, member_name text, class_name text,
  starts_at timestamptz, when_label text, happened_at timestamptz, detail text
)
language plpgsql stable security definer set search_path = public as $$
declare v_tz text; v_fmt text;
begin
  if not (is_desk_up(p_studio_id) or is_service_context()) then
    raise exception 'recent bookings are for the front desk and up' using errcode = 'PT403';
  end if;
  select s.timezone, coalesce(ss.time_format, '24h')
    into v_tz, v_fmt
    from studios s
    left join studio_settings ss on ss.studio_id = s.id
   where s.id = p_studio_id;

  return query
  with evt as (
    -- A seat taken: 'booked', or 'booked_free' for a free-first/comp seat.
    select (case when b.provisional or b.payment_source = 'comp'
                 then 'booked_free' else 'booked' end) as kind,
           (m.first_name || ' ' || m.last_name)         as member_name,
           o.name                                       as class_name,
           o.starts_at                                  as starts_at,
           coalesce(b.booked_at, b.created_at)          as happened_at,
           null::text                                   as detail
      from bookings b
      join members m           on m.id = b.member_id
      join class_occurrences o on o.id = b.occurrence_id
     where b.studio_id = p_studio_id
       and b.status in ('booked', 'attended')
    union all
    -- A member's own cancellation — never a studio release (those are the
    -- class-cancelled row below) and never a free-first non-confirmation.
    select (case when b.status = 'late_cancelled' or b.is_late_cancel
                 then 'cancelled_late' else 'cancelled' end),
           (m.first_name || ' ' || m.last_name),
           o.name, o.starts_at,
           coalesce(b.cancelled_at, b.updated_at),
           null::text
      from bookings b
      join members m           on m.id = b.member_id
      join class_occurrences o on o.id = b.occurrence_id
     where b.studio_id = p_studio_id
       and b.status in ('cancelled', 'late_cancelled')
       and coalesce(b.release_reason::text, '') not in ('studio_released', 'trial_not_confirmed')
    union all
    -- A staff/system class cancellation: one row per occurrence, with how many
    -- members it notified (the bookings it released).
    select 'class_cancelled',
           null::text,
           o.name, o.starts_at,
           o.cancelled_at,
           (select (r.c || ' member' || (case when r.c = 1 then '' else 's' end) || ' notified')
              from (select count(*) as c from bookings rb
                     where rb.occurrence_id = o.id
                       and rb.release_reason = 'studio_released') r)
      from class_occurrences o
     where o.studio_id = p_studio_id
       and o.status = 'cancelled'
       and o.cancelled_at is not null
  )
  select evt.kind, evt.member_name, evt.class_name, evt.starts_at,
         (to_char(evt.starts_at at time zone v_tz, 'Dy DD Mon')
            || ' ' || fmt_clock(evt.starts_at, v_tz, v_fmt)) as when_label,
         evt.happened_at, evt.detail
    from evt
   where evt.happened_at is not null
   order by evt.happened_at desc
   limit greatest(p_limit, 0);
end $$;

-- --- Tier suggestions: Decision 22's core minimum, read backwards. -----------
-- A core class below the core minimum in 3+ of its last 4 completed classes is
-- paying a guarantee it is not earning (suggest flex); a flex class that met
-- the minimum all 4 is under-paying its instructor relative to a core class
-- (suggest core). Fewer than 4 completed classes in the last 28 days → no row.
-- Inert when neither guarantees nor flex is enabled. Nothing changes here — the
-- owner opens the series and decides.
create or replace function tier_suggestions(p_studio_id uuid)
returns table (
  series_id uuid, class_name text, current_tier text, suggested_tier text,
  considered int, below_or_met int, avg_booked numeric, sentence text
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare v_core_min int; v_guar boolean; v_flex boolean;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'tier suggestions are for owners and managers' using errcode = 'PT403';
  end if;
  select coalesce(ss.core_min_bookings, 1),
         coalesce(ss.guarantees_enabled, false),
         coalesce(ss.flex_enabled, false)
    into v_core_min, v_guar, v_flex
    from studio_settings ss
   where ss.studio_id = p_studio_id;

  -- A studio that runs neither tier never sees a suggestion.
  if not coalesce(v_guar, false) and not coalesce(v_flex, false) then
    return;
  end if;

  return query
  with occ as (
    select o.series_id, o.starts_at,
           (select count(*) from bookings b
             where b.occurrence_id = o.id
               and b.status in ('booked', 'attended', 'no_show')
               and not b.provisional) as booked_start
      from class_occurrences o
     where o.studio_id = p_studio_id
       and o.series_id is not null
       and o.status <> 'cancelled'
       and o.starts_at <  now()
       and o.starts_at >= now() - interval '28 days'
  ),
  ranked as (
    select occ.*, row_number() over (partition by series_id order by starts_at desc) as rn
      from occ
  ),
  last4 as (
    select series_id,
           count(*)                                       as considered,
           count(*) filter (where booked_start <  v_core_min) as below,
           count(*) filter (where booked_start >= v_core_min) as met,
           round(avg(booked_start)::numeric, 1)           as avg_booked
      from ranked
     where rn <= 4
     group by series_id
    having count(*) >= 4
  ),
  sug as (
    select cs.id as series_id, cs.name as class_name,
           (case when cs.flex then 'flex'
                 else coalesce(cs.guarantee_tier::text, 'core') end) as current_tier,
           l.considered, l.below, l.met, l.avg_booked
      from last4 l
      join class_series cs on cs.id = l.series_id
     where cs.studio_id = p_studio_id and cs.status = 'active'
  )
  select sug.series_id, sug.class_name, sug.current_tier,
         (case when sug.current_tier = 'core' then 'flex' else 'core' end) as suggested_tier,
         sug.considered::int,
         (case when sug.current_tier = 'core' then sug.below else sug.met end)::int as below_or_met,
         sug.avg_booked,
         (case when sug.current_tier = 'core'
               then 'Consider making ' || sug.class_name || ' flex — ' || sug.below
                    || ' of the last 4 classes had fewer than ' || v_core_min
                    || ' booked (avg ' || sug.avg_booked || ')'
               else 'Consider making ' || sug.class_name
                    || ' core — all of the last 4 met the core minimum (avg '
                    || sug.avg_booked || ')'
          end) as sentence
    from sug
   where (sug.current_tier = 'core' and sug.below >= 3)
      or (sug.current_tier = 'flex' and sug.met = 4)
   order by (case when sug.current_tier = 'core' then 0 else 1 end), sug.avg_booked;
end $$;

-- =============================================================================
-- Grants. Both guard inside; dashboard_recent_bookings is desk-up,
-- tier_suggestions is manager-up; neither is anon.
-- =============================================================================
revoke all on function dashboard_recent_bookings(uuid, integer) from public, anon;
revoke all on function tier_suggestions(uuid) from public, anon;
grant execute on function dashboard_recent_bookings(uuid, integer) to authenticated, service_role;
grant execute on function tier_suggestions(uuid) to authenticated, service_role;
