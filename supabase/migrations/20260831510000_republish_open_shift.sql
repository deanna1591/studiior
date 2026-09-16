-- 146: re-notify qualified instructors about an open shift.
--
-- An unassigned class is ALREADY an open shift: created with no instructor it
-- gets staffing='open' (tg_derive_staffing), which stamps shift_opened_at
-- (tg_stamp_shift_opened), and notify_open_shifts() emails every qualified
-- instructor once — keyed on shift_alert_sent_at, so it does not repeat. There
-- is no separate "publish" state to reach; the class is out to instructors the
-- moment it exists without one.
--
-- What there was NO way to do was ask again. A manager looking at a gap that
-- nobody has applied for could assign somebody (move_occurrence) but could not
-- re-solicit — the one alert had already gone. republish_open_shift() clears
-- shift_alert_sent_at so the next notify_open_shifts sweep re-alerts the room.
-- This is the honest action-form of "put it out to instructors" for a shift
-- that is already open: a nudge, not a first publish.
--
-- Manager-up, and only for a FUTURE, SCHEDULED, still-open class — re-alerting a
-- past shift or an assigned one is meaningless, and notify_open_shifts only
-- looks at future open shifts anyway. Returns how many qualified instructors
-- have a login to reach, so the screen can say who will actually be emailed
-- rather than implying an email to instructors who cannot receive one (the same
-- honesty open_shift() keeps about an uncontactable removed instructor).

create or replace function republish_open_shift(p_occurrence_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  occ class_occurrences%rowtype;
  v_contactable int;
begin
  select * into occ from class_occurrences where id = p_occurrence_id for update;
  if not found then
    raise exception 'no such class' using errcode = 'PT404';
  end if;
  if not is_manager_up(occ.studio_id) then
    raise exception 'only owners and managers open a shift to instructors'
      using errcode = 'PT403';
  end if;
  if studio_is_locked(occ.studio_id) then
    raise exception 'this studio''s Studiior subscription is not active'
      using errcode = 'PT402';
  end if;
  if occ.status <> 'scheduled' then
    raise exception 'a % class is not an open shift', occ.status using errcode = 'PT409';
  end if;
  -- staffing='open' is the derived truth of "no instructor, published as a
  -- shift". An assigned class has somebody teaching it and is not open to apply
  -- for; if the studio wants it open they take the instructor off first
  -- (open_shift), which is a different, emailing act.
  if occ.staffing <> 'open' then
    raise exception 'that class already has an instructor — take them off to open it'
      using errcode = 'PT409';
  end if;
  if occ.starts_at <= now() then
    raise exception 'that class has already started' using errcode = 'PT409';
  end if;

  -- Clear the alert latch so notify_open_shifts() picks it up again. It stays
  -- open (nothing about staffing changes), and shift_opened_at is left as it
  -- was — this is a re-alert, not a re-open.
  update class_occurrences
     set shift_alert_sent_at = null, updated_at = now()
   where id = p_occurrence_id;

  -- Qualified, active, and reachable: an instructor with no login is counted by
  -- notify_open_shifts as uncontactable rather than emailed, so it would be a
  -- lie to promise them here.
  select count(*) into v_contactable
    from instructors i
   where i.studio_id = occ.studio_id
     and i.status = 'active'
     and instructor_qualified(i.id, occ.class_type_id)
     and instructor_user_id(i.id) is not null;

  return jsonb_build_object('ok', true, 'qualified_contactable', v_contactable);
end $$;

comment on function republish_open_shift(uuid) is
  'Manager-up. Clears shift_alert_sent_at on a future, scheduled, open shift so '
  'notify_open_shifts() re-alerts qualified instructors. Returns the count of '
  'qualified instructors with a login who will be emailed.';

revoke execute on function republish_open_shift(uuid) from public, anon, authenticated;
grant execute on function republish_open_shift(uuid) to authenticated, service_role;
