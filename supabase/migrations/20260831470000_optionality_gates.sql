-- =============================================================================
-- 142 — close the optionality leaks the all_off canary surfaced, and give seat
-- caps the one predicate the rest of the opt-in features already have.
-- =============================================================================
-- The audit found defaults that DO something to a studio that opted into
-- nothing. The two payroll ones were closed in 139. These are the instructor
-- OBLIGATION emails: a studio using Studiior purely for booking should not have
-- its instructors asked to confirm a week, submit availability, or check in for
-- pay — a confirmation request implies an obligation to a feature the studio
-- does not run. Each is gated the way record_class_pay was: on the studio's own
-- opt-in, off by default.
--
-- SEAT CAPS get studio_uses_seat_caps(), NOT a rename. plan_seats() already
-- returns no rows when the switch is off (102), so it stays exactly as it is;
-- what was missing is the single predicate the app can ask "are caps on at all"
-- instead of every caller reading a per-plan null. Mirror of studio_uses_payroll.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Seat caps: the one predicate. Reads seat_caps_enabled; staff-scoped, because
-- the seat-cap controls are the plans screens (manager). The member-facing "N
-- places left" already goes through plan_seats(), which is its own guard and
-- returns nothing when the switch is off.
-- -----------------------------------------------------------------------------
create or replace function studio_uses_seat_caps(p_studio_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v boolean;
begin
  if not (coalesce(is_desk_up(p_studio_id), false)
          or exists (select 1 from instructors i join studio_staff ss on ss.id = i.staff_id
                      where i.studio_id = p_studio_id and ss.user_id = auth.uid())
          or is_service_context()) then
    raise exception 'not your studio' using errcode = 'PT403';
  end if;
  select coalesce(seat_caps_enabled, false) into v from studio_settings where studio_id = p_studio_id;
  return coalesce(v, false);
end $$;
revoke execute on function studio_uses_seat_caps(uuid) from public, anon;
grant  execute on function studio_uses_seat_caps(uuid) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Leak 1 — WEEKLY CONFIRMATION was on by default. `week_confirm_enabled` was
-- NOT NULL DEFAULT true, so every provisioned studio had it on and
-- sweep_week_confirmations asked its instructors-with-logins to confirm each
-- week. Flip the default to false: a studio that turns nothing on now gets
-- nothing. Existing rows keep their stored value (a studio already running it
-- is not rug-pulled), and the only production studio has login-less instructors
-- so nothing changes for it either way. The sweep already reads the stored
-- value, so no re-issue is owed — the default was the whole bug.
-- -----------------------------------------------------------------------------
alter table studio_settings alter column week_confirm_enabled set default false;

-- -----------------------------------------------------------------------------
-- Leak 2 — AVAILABILITY REMINDERS had no switch at all: sweep_availability_
-- reminders looped every active studio unconditionally and nudged instructors
-- to submit availability. Give it its own switch, off by default, and gate the
-- sweep on it. The availability EDITOR stays open (an instructor may still
-- submit); it is the automated nudge — the obligation — that becomes opt-in.
-- -----------------------------------------------------------------------------
alter table studio_settings
  add column if not exists availability_reminders_enabled boolean not null default false;

create or replace function sweep_availability_reminders()
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; v_studios int := 0;
begin
  if not is_service_context() then
    raise exception 'the reminder sweep is a background job' using errcode = 'PT403';
  end if;
  -- Only studios that turned the reminders on. A booking-only studio is not in
  -- this loop at all, so its instructors are never nudged.
  for r in
    select st.id from studios st
      join studio_settings ss on ss.studio_id = st.id
     where st.status = 'active'
       and coalesce(ss.availability_reminders_enabled, false)
     order by st.id
  loop
    n := n + queue_availability_reminders(r.id);
    v_studios := v_studios + 1;
  end loop;
  return jsonb_build_object('studios', v_studios, 'queued', n);
end $$;

-- -----------------------------------------------------------------------------
-- Leak 3 — PAY CHECK-IN reminders. sweep_instructor_confirmations reminds an
-- instructor whose pay record is still held. Held pay records only exist where
-- payroll wrote them, so this is already inert for a booking-only studio — but
-- gate it explicitly, the record_class_pay way (guarantees OR flex), so it is a
-- payroll-only sweep by statement rather than by emergent property. Re-issued
-- from migration 135 with that one clause added.
-- -----------------------------------------------------------------------------
create or replace function sweep_instructor_confirmations() returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; v_sent int := 0;
begin
  if not is_service_context() then
    raise exception 'the instructor confirmation sweep is a background job' using errcode = 'PT403';
  end if;
  for r in
    select pr.id as rec_id, o.studio_id, o.instructor_id, o.name, o.starts_at,
           (select timezone from studios where id = o.studio_id) as tz
      from instructor_pay_records pr
      join class_occurrences o on o.id = pr.occurrence_id
     where pr.type = 'class' and pr.confirmed_at is null
       and o.status <> 'cancelled'
       and o.ends_at < now() and o.ends_at > now() - interval '7 days'
       -- Payroll-only, by statement. A studio that never turned guarantees or
       -- flex on is not reminding anyone to check in for a pay record it does
       -- not keep.
       and exists (select 1 from studio_settings ss
                    where ss.studio_id = o.studio_id
                      and (coalesce(ss.guarantees_enabled, false) or coalesce(ss.flex_enabled, false)))
  loop
    if queue_shift_notice(r.studio_id, instructor_user_id(r.instructor_id), 'instructor_unconfirmed',
         jsonb_build_object('class_name', r.name,
           'when', to_char(r.starts_at at time zone r.tz, 'FMDay FMDD FMMonth, HH24:MI')),
         'instructor_unconfirmed:' || r.rec_id) is not null then
      v_sent := v_sent + 1;
    end if;
  end loop;
  insert into job_runs (job_key, run_for, status, finished_at)
  values ('instructor_confirmations', current_date, 'done', now())
  on conflict (job_key, run_for) do update
     set attempts = job_runs.attempts + 1, started_at = now(), status = 'done', finished_at = now();
  return jsonb_build_object('reminded', v_sent);
end $$;
