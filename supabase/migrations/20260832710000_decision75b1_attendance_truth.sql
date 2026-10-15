-- =============================================================================
-- Decision 75b-1 (f) — ATTENDANCE TRUTH IS check_ins, NOT booking status.
-- =============================================================================
-- STEP 0 inventory (75b) found that an instructor/desk SCAN writes a check_ins
-- row but leaves bookings.status = 'booked' (checkInMember, scanCheckIn, and the
-- staff checkIn action), while self_check_in flips it to 'attended'. So
-- finalise_attendance_sweep — which no-shows every still-'booked' booking at
-- midnight — marks a member who was physically in the room a no_show, and 75d's
-- checked-in pay basis would read that corrupted status.
--
-- The fix, in the order Decision 75(f) sets out:
--   1. ONE check-in path: record_check_in(booking, method) inserts the check_ins
--      row AND flips the booking to 'attended' in the same transaction, matching
--      self_check_in. The four direct inserts (checkInMember, scanCheckIn, staff
--      checkIn, the staff qr-resolve action) all route through it.
--   2. finalise_attendance_sweep flips any booking that HAS a check_in to
--      attended BEFORE no-showing the rest.
--   3. a backfill flips historical booked-with-check-in rows on ended classes.
--
-- The authoritative attendance record is check_ins (unique on booking_id); the
-- checked-in headcount in 75d is count(distinct member) from check_ins.
-- No new anon RPC — the anon surface stays EXACTLY THIRTEEN.
-- =============================================================================

-- creates: record_check_in(uuid, text)
-- re-issues: finalise_attendance_sweep()

-- -----------------------------------------------------------------------------
-- 1. record_check_in — the single staff/instructor/desk check-in path.
-- -----------------------------------------------------------------------------
-- SECURITY DEFINER (so it may both insert the check_in and flip the booking in
-- one transaction), guarded to staff of the occurrence's own studio — EXACTLY
-- the boundary the checkins_staff RLS policy already draws for the direct
-- inserts this replaces (studio_id in auth_staff_studios()), plus service. The
-- §8 window trigger (check_ins_window) and the waiver trigger
-- (enforce_guest_waiver) still fire on the insert, so their PT422s propagate
-- unchanged. self_check_in (method 'self') and import_commit (method 'import')
-- keep their own paths — this is the human-at-the-desk / instructor path only.
create or replace function record_check_in(p_booking_id uuid, p_method text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_b bookings%rowtype; v_o class_occurrences%rowtype;
begin
  if p_method not in ('staff','qr','instructor') then
    raise exception 'unknown check-in method' using errcode = 'PT400';
  end if;

  select * into v_b from bookings where id = p_booking_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;

  select * into v_o from class_occurrences where id = v_b.occurrence_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;

  -- The checkins_staff boundary, in the function because DEFINER bypasses RLS.
  if not (v_o.studio_id in (select auth_staff_studios()) or is_service_context()) then
    raise exception 'you cannot check members in at that studio' using errcode = 'PT403';
  end if;

  if v_b.status not in ('booked', 'attended') then
    return jsonb_build_object('ok', false, 'reason', 'not_booked');
  end if;

  -- The window trigger and the waiver trigger fire on this insert and raise
  -- PT422 if the window is shut or the member has not signed — the caller maps
  -- those to a sentence, exactly as the direct inserts did.
  begin
    insert into check_ins (studio_id, booking_id, member_id, occurrence_id,
                           method, checked_in_by)
    values (v_o.studio_id, v_b.id, v_b.member_id, v_o.id, p_method::checkin_method, auth.uid());
  exception when unique_violation then
    -- Already has a check_in. Flip the booking in case an older direct-insert
    -- path left it 'booked' (this is the repair for a row the backfill would
    -- otherwise have to catch), then report success.
    update bookings set status = 'attended', updated_at = now()
     where id = v_b.id and status = 'booked';
    return jsonb_build_object('ok', true, 'already', true);
  end;

  update bookings set status = 'attended', updated_at = now()
   where id = v_b.id and status = 'booked';

  return jsonb_build_object('ok', true, 'checked_in', true);
end $$;

revoke execute on function record_check_in(uuid, text) from public, anon;
grant  execute on function record_check_in(uuid, text) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 2. finalise_attendance_sweep — re-issued from 20260832460000 byte-for-byte,
--    with ONE addition: before no-showing, flip every booked booking that has a
--    check_in to attended. create-or-replace keeps the ACL (service-role only).
-- -----------------------------------------------------------------------------
create or replace function finalise_attendance_sweep()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_marked int := 0; v_occs int := 0; r record; v_n int; v_tz text; v_fname text; v_when text; v_morning timestamptz;
begin
  if not is_service_context() then
    raise exception 'the finalisation sweep is a background job' using errcode = 'PT403';
  end if;

  for r in
    select o.id, o.studio_id, o.name, o.starts_at, o.ends_at, o.instructor_id, s.timezone as tz, s.name as studio_name
      from class_occurrences o
      join studios s on s.id = o.studio_id
      join studio_settings ss on ss.studio_id = o.studio_id
     where ss.finalise_attendance
       and o.status = 'scheduled'
       and o.attendance_finalised_at is null
       and o.ends_at < now()
       -- midnight studio time, finalise_days_after days after the class's local day
       and now() >= (((o.ends_at at time zone s.timezone)::date + ss.finalise_days_after)::timestamp at time zone s.timezone)
  loop
    -- Decision 75(f): attendance truth is check_ins. A scanned/desk check-in
    -- leaves the booking 'booked', so flip every booked booking that HAS a
    -- check_in to attended FIRST — finalisation never no-shows someone who was
    -- in the room — then no_show only the remainder.
    update bookings set status = 'attended', updated_at = now()
     where occurrence_id = r.id and status = 'booked'
       and exists (select 1 from check_ins ci where ci.booking_id = bookings.id);

    update bookings set status = 'no_show', no_show_at = now(), no_show_by = null, updated_at = now()
     where occurrence_id = r.id and status = 'booked';
    get diagnostics v_n = row_count;

    update class_occurrences set attendance_finalised_at = now(), updated_at = now() where id = r.id;
    v_occs := v_occs + 1;
    v_marked := v_marked + v_n;

    -- Tell the instructor (if they have a login), once per occurrence, scheduled
    -- for 08:00 studio-local of the finalisation day. Only when something was
    -- auto-marked.
    if v_n > 0 and r.instructor_id is not null and instructor_user_id(r.instructor_id) is not null then
      v_tz := r.tz;
      select split_part(coalesce(i.display_name, ''), ' ', 1) into v_fname
        from instructors i where i.id = r.instructor_id;
      v_when := to_char(r.starts_at at time zone v_tz, 'FMDay FMDD FMMon, HH24:MI');
      v_morning := (date_trunc('day', now() at time zone v_tz) + interval '8 hours') at time zone v_tz;
      insert into notifications (studio_id, recipient_type, user_id, template_key, channel,
                                 payload, dedupe_key, scheduled_for, status)
      values (r.studio_id, 'staff', instructor_user_id(r.instructor_id), 'instructor_unmarked_bookings', 'email',
              jsonb_build_object('first_name', coalesce(nullif(v_fname, ''), 'there'),
                                 'count', v_n, 'class_name', r.name, 'when', v_when,
                                 'studio_name', r.studio_name),
              'unmarked:' || r.id::text, v_morning, 'scheduled')
      on conflict (dedupe_key) do nothing;
    end if;
  end loop;

  insert into job_runs (job_key, run_for, status, finished_at)
  values ('finalise_attendance', current_date, 'done', now())
  on conflict (job_key, run_for) do update
     set attempts = job_runs.attempts + 1, started_at = now(), status = 'done', finished_at = now();

  return jsonb_build_object('occurrences', v_occs, 'marked', v_marked);
end $$;
revoke execute on function finalise_attendance_sweep() from public, anon, authenticated;
grant  execute on function finalise_attendance_sweep() to service_role;

-- -----------------------------------------------------------------------------
-- 3. Backfill — historical booked-with-check-in rows on ended classes become
--    attended. One-time correction of existing attendance records (not new
--    data). Idempotent: re-running flips nothing, because the second pass finds
--    no 'booked' row that still has a check_in.
-- -----------------------------------------------------------------------------
do $$
declare v_n int;
begin
  update bookings b set status = 'attended', updated_at = now()
    from class_occurrences o
   where b.occurrence_id = o.id
     and b.status = 'booked'
     and o.ends_at < now()
     and exists (select 1 from check_ins ci where ci.booking_id = b.id);
  get diagnostics v_n = row_count;
  raise notice 'Decision 75b-1 attendance backfill: % booked-with-check-in rows flipped to attended', v_n;
end $$;
