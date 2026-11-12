-- =============================================================================
-- Decision 96 — Reopen availability before the cut-off.
--
-- An owner or manager reopens a submitted or approved availability submission so
-- the instructor can edit it, before the availability due day for that period.
-- Reopening flips the submission and its rows back to changes_requested (exactly
-- what request_availability_changes already does — touching no class_occurrences,
-- so assignments stand) and sends the availability_changes_requested email with
-- the note, or a default sentence when none is given. After the cut-off the
-- function refuses (cutoff_passed). The cut-off date is read from
-- availability_cycle(studio_id, period_start)->>'due_on', the single existing
-- source, and is not computed again.
--
-- The request_availability_changes body is extracted into a service-only _run
-- twin so there is one implementation of "send a month back to the instructor";
-- the public request_availability_changes (still note-required) and the reopen
-- wrapper both call it. No new anon RPC — anon stays EXACTLY THIRTEEN.
--
-- creates:   request_availability_changes_run(uuid, text), reopen_availability_submission(uuid, text)
-- re-issues: request_availability_changes(uuid, text)
-- =============================================================================

-- --- The shared body: flip to changes_requested, email the instructor --------
-- Service-only. The callers resolve and authorise the note; this does the flip
-- and the notice. instructors.staff_id is a studio_staff id, NOT an auth user
-- id, so instructor_user_id() is the join (null for a no-login instructor, the
-- ordinary case). The rows stop counting the moment changes are asked for; they
-- were never approved from the engine's point of view, so nothing it did is
-- undone, and class_occurrences are untouched.
create or replace function request_availability_changes_run(
  p_submission_id uuid, p_note text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_sub availability_submissions%rowtype; v_name text; v_uid uuid;
begin
  select * into v_sub from availability_submissions where id = p_submission_id for update;
  if not found then
    raise exception 'no such submission' using errcode = 'PT404';
  end if;

  update availability_submissions
     set status = 'changes_requested', note = btrim(p_note),
         reviewed_by = auth.uid(), reviewed_at = now()
   where id = p_submission_id;
  update instructor_availability
     set approval_status = 'changes_requested', updated_at = now()
   where submission_id = p_submission_id;

  select i.display_name into v_name from instructors i where i.id = v_sub.instructor_id;
  v_uid := instructor_user_id(v_sub.instructor_id);

  return jsonb_build_object(
    'ok', true, 'submission_id', p_submission_id, 'instructor', v_name,
    'period_start', v_sub.period_start,
    'notified', queue_shift_notice(v_sub.studio_id, v_uid, 'availability_changes_requested',
      jsonb_build_object('period', to_char(v_sub.period_start, 'FMMonth YYYY'),
                         'instructor_name', v_name, 'note', btrim(p_note)),
      -- Keyed on the review, not the submission: a second round of changes on
      -- the same month is a second thing to tell somebody.
      'avail_changes:' || p_submission_id || ':' || extract(epoch from now())::bigint) is not null);
end $$;

revoke execute on function request_availability_changes_run(uuid, text) from public, anon, authenticated;
grant  execute on function request_availability_changes_run(uuid, text) to service_role;

-- --- The public reviewer path: unchanged behaviour, now over the twin --------
-- Still manager-up, still note-required (PT422). A bare refusal is not a review.
create or replace function request_availability_changes(
  p_submission_id uuid, p_note text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_studio uuid;
begin
  select studio_id into v_studio from availability_submissions where id = p_submission_id;
  if v_studio is null then
    raise exception 'no such submission' using errcode = 'PT404';
  end if;
  if not coalesce(is_manager_up(v_studio), false) then
    raise exception 'only owners and managers review availability' using errcode = 'PT403';
  end if;
  if coalesce(btrim(p_note), '') = '' then
    raise exception 'say what needs changing — a bare refusal is not a review'
      using errcode = 'PT422';
  end if;
  return request_availability_changes_run(p_submission_id, btrim(p_note));
end $$;

revoke execute on function request_availability_changes(uuid, text) from public, anon, authenticated;
grant  execute on function request_availability_changes(uuid, text) to authenticated;

-- --- Reopen before the cut-off -----------------------------------------------
-- Manager-up. The note is optional; when blank it defaults to a studio-named
-- sentence. The cut-off is availability_cycle(studio, period)->>'due_on' — the
-- one source — compared against the studio-local date; past it, cutoff_passed.
create or replace function reopen_availability_submission(
  p_submission_id uuid, p_note text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_sub availability_submissions%rowtype;
  v_tz text; v_today date; v_due date; v_note text; v_studio_name text;
begin
  select * into v_sub from availability_submissions where id = p_submission_id;
  if not found then
    raise exception 'no such submission' using errcode = 'PT404';
  end if;
  if not coalesce(is_manager_up(v_sub.studio_id), false) then
    raise exception 'only owners and managers reopen availability' using errcode = 'PT403';
  end if;

  -- The cut-off: the availability due day for this period, from the one source.
  v_due := (availability_cycle(v_sub.studio_id, v_sub.period_start) ->> 'due_on')::date;
  select timezone into v_tz from studios where id = v_sub.studio_id;
  v_today := (now() at time zone v_tz)::date;
  if v_today > v_due then
    raise exception 'The cut-off for % was %. Ask the instructor to send a change request instead.',
      to_char(v_sub.period_start, 'FMMonth YYYY'), to_char(v_due, 'FMDD FMMonth YYYY')
      using errcode = 'PT409', detail = 'cutoff_passed';
  end if;

  if coalesce(btrim(p_note), '') = '' then
    select name into v_studio_name from studios where id = v_sub.studio_id;
    v_note := 'Reopened by ' || v_studio_name || ' so you can make changes.';
  else
    v_note := btrim(p_note);
  end if;

  return request_availability_changes_run(p_submission_id, v_note);
end $$;

revoke execute on function reopen_availability_submission(uuid, text) from public, anon, authenticated;
grant  execute on function reopen_availability_submission(uuid, text) to authenticated;

-- --- Anon stays EXACTLY THIRTEEN --------------------------------------------
do $$ declare n int; begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % (want 13)', n; end if;
end $$;
