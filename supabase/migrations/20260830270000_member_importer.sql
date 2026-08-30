-- =============================================================================
-- MIGRATION 016 — the member importer
--
-- Three types, in dependency order: members, memberships, attendance.
-- Not classes; a studio switching systems rebuilds its schedule anyway.
--
-- =============================================================================
-- THE ATTENDANCE DECISION: check_ins without an occurrence
--
-- Attendance needs something to hang off. Two options were open: synthesise a
-- class_occurrence per imported visit, or let an imported check_in carry no
-- occurrence. This takes the second.
--
-- Synthesising loses more than it gains. Two years of history is thousands of
-- invented classes with no instructor, no room and a guessed capacity. They
-- would appear in the week view for every past week, and every fill-rate and
-- utilisation report would be computed against classes that never ran. The
-- studio would be trading one missing fact for a large number of false ones.
--
-- A check_in is the attendance fact. The occurrence is context we genuinely do
-- not have, and null is the honest way to say so. So for imported rows,
-- occurrence_id and booking_id are null, and import_id says why.
--
-- What has to keep working is stated in the brief: lifetime visits,
-- last_visit_at and streaks. All three read check_ins, not occurrences, so all
-- three are computed by recompute_member_stats() below and are correct whether
-- a visit came from the door or from a CSV. The same is true of the two things
-- this exists to feed — days-since-last-visit and median visit gap, which
-- Business Rules §11 uses for retention_risk.
--
-- What is lost: an imported visit cannot say which class it was. That is
-- already true of the source data in most exports, and it is not an input to
-- any V1 insight.
-- =============================================================================

alter table check_ins
  alter column occurrence_id drop not null,
  alter column booking_id    drop not null,
  add column import_id uuid references imports on delete set null;

create index on check_ins (import_id) where import_id is not null;

-- A check-in is either something that happened here — with a booking behind it
-- — or history somebody imported. Never neither: that would be a visit with no
-- provenance at all.
alter table check_ins
  add constraint check_ins_booked_or_imported
  check (booking_id is not null or import_id is not null);

comment on column check_ins.import_id is
  'Set when this visit came from a CSV rather than the door. Imported rows '
  'carry no booking and no occurrence — see migration 016 for why — and are '
  'exempt from the §8 check-in window, which is about people arriving for a '
  'class, not about recording that they did two years ago.';

-- -----------------------------------------------------------------------------
-- The §8 window does not apply to history. Fixed forward: migration 007 has run
-- against the hosted project.
--
-- Without this the importer would have to turn checkin_window_enforced off for
-- the whole studio mid-import — which 007 offered as the escape hatch, but
-- which races with anyone checking in at the desk while the import runs.
-- -----------------------------------------------------------------------------
create or replace function enforce_checkin_window() returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_opens  int;
  v_closes int;
  v_on     boolean;
  v_starts timestamptz;
  v_ends   timestamptz;
begin
  -- Imported history is a record of the past, not an arrival.
  if new.import_id is not null then
    return new;
  end if;

  select checkin_opens_minutes_before, checkin_closes_minutes_after,
         checkin_window_enforced
    into v_opens, v_closes, v_on
    from studio_settings
   where studio_id = new.studio_id;

  if not found or not v_on then
    return new;
  end if;

  select starts_at, ends_at into v_starts, v_ends
    from class_occurrences where id = new.occurrence_id;
  if not found then
    return new;
  end if;

  if new.checked_in_at < v_starts - make_interval(mins => v_opens) then
    raise exception
      'check-in opens % minutes before the class starts (class starts %)',
      v_opens, v_starts
      using errcode = 'PT422',
            hint = 'Business Rules §8. To accept check-ins outside the window '
                   'for this studio, set studio_settings.checkin_window_enforced '
                   '= false.';
  end if;

  if new.checked_in_at > v_ends + make_interval(mins => v_closes) then
    raise exception
      'check-in closed % minutes after the class ended (class ended %)',
      v_closes, v_ends
      using errcode = 'PT422',
            hint = 'Business Rules §8. To accept check-ins outside the window '
                   'for this studio, set studio_settings.checkin_window_enforced '
                   '= false.';
  end if;

  return new;
end $$;

-- =============================================================================
-- Member visit statistics, derived from check_ins
--
-- Imported visits and door visits are the same fact, so this reads check_ins
-- and nothing else. Called after an attendance import and after a rollback, so
-- the numbers are right in both directions.
-- =============================================================================

create function recompute_member_stats(p_studio_id uuid, p_member_ids uuid[] default null)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tz text;
  n    int;
begin
  if not is_manager_up(p_studio_id) then
    return 0;
  end if;

  select timezone into v_tz from studios where id = p_studio_id;

  update members m
     set lifetime_visits = coalesce(v.visits, 0),
         first_visit_at  = v.first_at,
         last_visit_at   = v.last_at
    from (
      select mm.id as member_id,
             count(ci.id)          as visits,
             min(ci.checked_in_at) as first_at,
             max(ci.checked_in_at) as last_at
        from members mm
        left join check_ins ci on ci.member_id = mm.id
       where mm.studio_id = p_studio_id
         and (p_member_ids is null or mm.id = any(p_member_ids))
       group by mm.id
    ) v
   where m.id = v.member_id;
  get diagnostics n = row_count;

  -- Decision 5: a streak is consecutive WEEKS with at least one attended class,
  -- in studio-local weeks, broken if last week was missed.
  update members m
     set current_streak = coalesce(st.streak, 0)
    from (
      select mm.id as member_id,
             coalesce((
               select count(*)
                 from (
                   select w.wk,
                          row_number() over (order by w.wk desc) as rn,
                          max(w.wk) over () as latest
                     from (
                       select distinct
                              date_trunc('week', ci.checked_in_at at time zone v_tz)::date as wk
                         from check_ins ci where ci.member_id = mm.id
                     ) w
                 ) run
                where run.wk = run.latest - (((run.rn - 1) * 7)::int)
                  and run.latest >= date_trunc(
                        'week', (now() at time zone v_tz))::date - 7
             ), 0) as streak
        from members mm
       where mm.studio_id = p_studio_id
         and (p_member_ids is null or mm.id = any(p_member_ids))
    ) st
   where m.id = st.member_id;

  return n;
end $$;

revoke execute on function recompute_member_stats(uuid, uuid[]) from public, anon;
grant execute on function recompute_member_stats(uuid, uuid[]) to authenticated, service_role;
