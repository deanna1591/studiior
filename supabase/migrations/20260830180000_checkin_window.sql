-- =============================================================================
-- MIGRATION 007 — the check-in window, Business Rules §8
--
--   "Check-in window opens 60 minutes before start and closes 30 minutes
--    after end."
--
-- The slice enforced this nowhere, so front desk could check a member into
-- tomorrow's class. It goes here rather than in the application for the same
-- reason every other rule does: a check that lives only in TypeScript is not a
-- rule, it is a suggestion that the next caller — an import, a job, a second
-- client — will not hear.
--
-- A trigger rather than a book_class()-style function, because check-in has no
-- concurrency problem to solve: there is one row per booking and a unique
-- constraint already enforces that. What it needs is to be true on every
-- insert path, which is exactly what a trigger gives.
--
-- Bounds are studio settings, matching how every other timing rule in this
-- schema is expressed (booking_cutoff_minutes, cancellation_cutoff_minutes,
-- waitlist_cutoff_minutes). §8 states them as constants; they are the defaults.
-- =============================================================================

alter table studio_settings
  add column checkin_opens_minutes_before int     not null default 60
    check (checkin_opens_minutes_before >= 0),
  add column checkin_closes_minutes_after int     not null default 30
    check (checkin_closes_minutes_after >= 0),
  add column checkin_window_enforced      boolean not null default true;

comment on column studio_settings.checkin_window_enforced is
  'Business Rules §8. When false, check-in is accepted at any time for this '
  'studio. The documented escape hatch: importing historical attendance, and '
  'demoing the slice against a class that is not starting in the next hour. '
  'Off means off — there is no per-check-in override, deliberately, so the '
  'setting is the only thing anyone has to inspect to know whether the rule '
  'is live.';

create function enforce_checkin_window() returns trigger
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
  select checkin_opens_minutes_before, checkin_closes_minutes_after,
         checkin_window_enforced
    into v_opens, v_closes, v_on
    from studio_settings
   where studio_id = new.studio_id;

  -- No settings row means the studio is half-built; the FK on studio_id is the
  -- thing that should complain, not this.
  if not found or not v_on then
    return new;
  end if;

  select starts_at, ends_at into v_starts, v_ends
    from class_occurrences where id = new.occurrence_id;
  if not found then
    return new;                       -- the FK will reject it
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

comment on function enforce_checkin_window() is
  'Business Rules §8 check-in window. Fires on every insert path, so the rule '
  'holds for the app, imports and jobs alike.';

create trigger check_ins_window
  before insert or update of checked_in_at, occurrence_id on check_ins
  for each row execute function enforce_checkin_window();

revoke execute on function enforce_checkin_window() from public;
