-- =============================================================================
-- Migration 115 — reliability, MEASURED and never enforced
-- =============================================================================
-- An instructor who claims shifts and withdraws late is a real problem: the
-- studio scrambles, and whoever would reliably have taken it never got the
-- chance. So it is worth SEEING — per instructor, how many shifts they applied
-- for, were approved for, and withdrew from, and how much notice each
-- withdrawal gave.
--
-- NO CAP, NO SCORE, NO AUTOMATIC ANYTHING. A damaged score would make an
-- instructor less likely to be offered shifts exactly when the studio is short;
-- genuine illness and chronic overcommitting would be marked identically, and
-- the honest one would stop applying; and with six instructors nobody ranked
-- lower is actually passed over, because there is nobody else. Same posture as
-- the commitment report: Studiior measures, the studio judges. Nothing here
-- reads back into who gets offered a shift.
--
-- Also fixes a live bug: the portal's "withdraw application" called
-- withdraw_from_shift(), which since migration 064 requires being the ASSIGNED
-- instructor and raises a cover request — so withdrawing a PENDING application
-- (an OPEN shift, no assigned instructor) answered PT403. Decision 18 kept
-- pending-withdrawal untouched; it had quietly regressed. withdraw_application()
-- restores it, and records the withdrawal.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. The three facts a withdrawal leaves behind
-- -----------------------------------------------------------------------------
-- approved_at is set once and never cleared, so "approved for 14" is a lifetime
-- count even after some were later withdrawn. withdrawn_at and the notice are
-- the withdrawal itself; the notice is SNAPSHOT at withdrawal, because a class
-- that later moves must not rewrite how much warning was actually given.
alter table shift_applications
  add column approved_at             timestamptz,
  add column withdrawn_at            timestamptz,
  add column withdrawal_notice_hours numeric;

-- Backfill approved_at for applications already approved, from decided_at, so
-- the lifetime count is right from day one rather than only counting future
-- approvals.
update shift_applications set approved_at = decided_at
 where status = 'approved' and approved_at is null;

comment on column shift_applications.approved_at is
  'When this application was approved. Set once, never cleared — so a lifetime '
  '"approved for" count survives a later withdrawal. Migration 115.';
comment on column shift_applications.withdrawal_notice_hours is
  'Hours between the withdrawal and the class start, snapshot at withdrawal. '
  'A withdrawal inside cover_escalation_hours costs the studio a scramble; one '
  'three weeks out does not. Measured, never enforced.';

-- -----------------------------------------------------------------------------
-- 2. Withdrawing a PENDING application — restored, and recorded
-- -----------------------------------------------------------------------------
-- Decision 18: nobody is counting on you before you have been approved, so this
-- is a plain withdrawal, not a cover request. It still records the notice, so
-- the pattern is visible even when each one was cheap.
create function withdraw_application(p_occurrence_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  occ class_occurrences%rowtype; v_instr uuid; app shift_applications%rowtype; v_notice numeric;
begin
  select * into occ from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  v_instr := auth_instructor_id(occ.studio_id);
  if v_instr is null then
    raise exception 'only an instructor at this studio can withdraw an application'
      using errcode = 'PT403';
  end if;

  select * into app from shift_applications
   where occurrence_id = p_occurrence_id and instructor_id = v_instr and status = 'pending'
   for update;
  if not found then
    raise exception 'you have no pending application for that class' using errcode = 'PT409';
  end if;

  v_notice := greatest(0, extract(epoch from (occ.starts_at - now())) / 3600.0);
  update shift_applications
     set status = 'withdrawn', withdrawn_at = now(),
         withdrawal_notice_hours = round(v_notice, 1), decided_at = now(), updated_at = now()
   where id = app.id;

  return jsonb_build_object('ok', true, 'occurrence_id', p_occurrence_id,
                            'notice_hours', round(v_notice, 1));
end $$;

-- -----------------------------------------------------------------------------
-- 3. Backing out AFTER approval — the costly kind — is recorded too
-- -----------------------------------------------------------------------------
-- withdraw_from_shift() (migration 064) keeps its behaviour exactly: an
-- instructor who took a class and can no longer do it raises a COVER REQUEST
-- and stays on it until staff act — Decision 18. The only addition is that if
-- they held an APPROVED application for it, that application is marked withdrawn
-- with the notice given, so the backout appears in their reliability record.
-- Re-issued from migration 064's file, the newest that defines it, plus that
-- one recording step.
create or replace function withdraw_from_shift(p_occurrence_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare occ class_occurrences%rowtype; v_res jsonb; v_instr uuid; v_notice numeric;
begin
  select * into occ from class_occurrences where id = p_occurrence_id;
  if not found then
    raise exception 'no such class' using errcode = 'PT404';
  end if;
  v_instr := auth_instructor_id(occ.studio_id);
  if v_instr is distinct from occ.instructor_id then
    raise exception 'you are not teaching that class' using errcode = 'PT403';
  end if;

  -- The record: if they got the class through an approved application, backing
  -- out withdraws it, with the notice. If they were assigned directly (the
  -- engine, or by hand) there is no application to mark and the cover request
  -- itself is the trail.
  v_notice := greatest(0, extract(epoch from (occ.starts_at - now())) / 3600.0);
  update shift_applications
     set status = 'withdrawn', withdrawn_at = now(),
         withdrawal_notice_hours = round(v_notice, 1), updated_at = now()
   where occurrence_id = p_occurrence_id and instructor_id = v_instr and status = 'approved';

  -- Everything this used to do, minus the release. request_cover() carries the
  -- staff notification, the booked count and the escalation.
  v_res := request_cover(p_occurrence_id, 'Withdrawn from the shift they took');

  return jsonb_build_object(
    'occurrence_id', occ.id,
    'booked_count', occ.booked_count,
    'cover_requested', true,
    'still_assigned', true,
    'notice_hours', round(v_notice, 1),
    'request_id', v_res ->> 'request_id');
end $$;

-- -----------------------------------------------------------------------------
-- 4. approve_shift_application stamps approved_at — re-issued from migration 057
-- -----------------------------------------------------------------------------
create or replace function approve_shift_application(p_application_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  app  shift_applications%rowtype;
  occ  class_occurrences%rowtype;
  r    record;
  v_tz text; v_when text; v_where text;
  n_declined int := 0;
  v_res jsonb;
begin
  select * into app from shift_applications where id = p_application_id for update;
  if not found then
    raise exception 'no such application' using errcode = 'PT404';
  end if;
  if not is_manager_up(app.studio_id) then
    raise exception 'approving a shift is the owner''s or a manager''s to do'
      using errcode = 'PT403';
  end if;
  if app.status <> 'pending' then
    raise exception 'that application is already %', app.status using errcode = 'PT409';
  end if;

  select * into occ from class_occurrences where id = app.occurrence_id for update;

  v_res := move_occurrence(occ.id, null, null, app.instructor_id, null, true);
  if not (v_res ->> 'ok')::boolean then
    raise exception 'cannot assign them: %', v_res ->> 'reason'
      using errcode = 'PT409',
            hint = 'They are teaching something else at that time.';
  end if;

  update shift_applications
     set status = 'approved', approved_at = now(), decided_by = auth.uid(), decided_at = now()
   where id = p_application_id;

  select s.timezone into v_tz from studios s where s.id = occ.studio_id;
  v_when  := to_char(occ.starts_at at time zone v_tz, 'FMDay FMDD FMMonth, HH24:MI');
  v_where := coalesce((select ', in ' || rm.name from rooms rm where rm.id = occ.room_id), '');

  perform queue_shift_notice(
    occ.studio_id,
    instructor_user_id(app.instructor_id),
    'shift_approved',
    jsonb_build_object('class_name', occ.name, 'when', v_when, 'where_line', v_where),
    'shift_approved:' || app.id);

  for r in
    select sa.*, instructor_user_id(sa.instructor_id) as staff_user
      from shift_applications sa
     where sa.occurrence_id = occ.id and sa.status = 'pending' and sa.id <> app.id
    for update
  loop
    update shift_applications
       set status = 'declined', decided_by = auth.uid(), decided_at = now()
     where id = r.id;
    perform queue_shift_notice(occ.studio_id, r.staff_user, 'shift_declined',
      jsonb_build_object('class_name', occ.name, 'when', v_when,
        'shifts_url', coalesce(nullif(notification_setting('staff_app_origin'), ''),
                               'https://app.studiior.com') || '/shifts'),
      'shift_declined:' || r.id);
    n_declined := n_declined + 1;
  end loop;

  return jsonb_build_object('approved', app.id, 'auto_declined', n_declined,
                            'warnings', v_res -> 'warnings');
end $$;

-- -----------------------------------------------------------------------------
-- 5. The reliability record — read only, no verdict
-- -----------------------------------------------------------------------------
-- Manager-up of the instructor's studio, or the instructor themselves. Numbers
-- and a list of the withdrawals; nothing derived into "good" or "bad", and
-- nothing that feeds a decision. An instructor who can see their own record
-- usually manages it.
create function instructor_reliability(p_instructor_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_tz text; v_window int; v_row record;
begin
  select i.studio_id into v_studio from instructors i where i.id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  if not (coalesce(is_this_instructor(p_instructor_id), false)
          or coalesce(is_manager_up(v_studio), false)) then
    raise exception 'that is somebody else''s record' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = v_studio;
  select coalesce(cover_escalation_hours, 4) into v_window
    from studio_settings where studio_id = v_studio;
  v_window := coalesce(v_window, 4);

  select
    count(*)::int as applied,
    count(*) filter (where approved_at is not null)::int as approved,
    count(*) filter (where withdrawn_at is not null)::int as withdrawn,
    count(*) filter (where withdrawn_at is not null
                       and withdrawal_notice_hours is not null
                       and withdrawal_notice_hours < v_window)::int as short_notice,
    coalesce(jsonb_agg(jsonb_build_object(
               'occurrence_id', sa.occurrence_id,
               'class_name', o.name,
               'when', to_char(o.starts_at at time zone v_tz, 'FMDD FMMon, HH24:MI'),
               'notice_hours', sa.withdrawal_notice_hours,
               -- Snapshot against the studio's OWN escalation window: the same
               -- act costs differently at studios that escalate at 4 hours and
               -- at 24.
               'short_notice', sa.withdrawal_notice_hours is not null
                               and sa.withdrawal_notice_hours < v_window)
             order by sa.withdrawn_at desc)
             filter (where sa.withdrawn_at is not null), '[]'::jsonb) as withdrawals
    into v_row
    from shift_applications sa
    join class_occurrences o on o.id = sa.occurrence_id
   where sa.instructor_id = p_instructor_id;

  return jsonb_build_object(
    'instructor_id', p_instructor_id,
    'applied', coalesce(v_row.applied, 0),
    'approved', coalesce(v_row.approved, 0),
    'withdrawn', coalesce(v_row.withdrawn, 0),
    'short_notice', coalesce(v_row.short_notice, 0),
    'escalation_window_hours', v_window,
    'withdrawals', coalesce(v_row.withdrawals, '[]'::jsonb),
    -- One plain sentence for a chip beside their name. Context, not a grade.
    'summary', case
      when coalesce(v_row.applied, 0) = 0 then 'No applications yet'
      else format('applied for %s, withdrew from %s', v_row.applied, v_row.withdrawn) end);
end $$;

-- -----------------------------------------------------------------------------
-- Grants
-- -----------------------------------------------------------------------------
revoke execute on function withdraw_application(uuid)     from public, anon;
grant  execute on function withdraw_application(uuid)     to authenticated;
revoke execute on function instructor_reliability(uuid)   from public, anon;
grant  execute on function instructor_reliability(uuid)   to authenticated, service_role;

do $$
begin
  if has_function_privilege('anon', 'withdraw_application(uuid)', 'execute')
     or has_function_privilege('anon', 'instructor_reliability(uuid)', 'execute') then
    raise exception 'migration 115: something is anon-callable';
  end if;
end $$;
