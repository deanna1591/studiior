-- =============================================================================
-- 066  An instructor submits their own availability; staff approve it
-- =============================================================================
-- Decision 18 built the editor and gave it to the studio. This gives the same
-- editor to the instructor, for the month ahead, behind an approval step —
-- because a pattern that changes who the engine will schedule must not change
-- because somebody typed it about themselves.
--
-- WHAT IS ALREADY APPROVED. Every `instructor_availability` row that exists
-- today was entered by staff, and staff entry IS the approval. So
-- `approval_status` defaults to 'approved' and the ALTER rewrites nothing:
-- Reform Collective's instructors keep the patterns they have, and only a
-- pattern an INSTRUCTOR submits ever sits waiting. A manager calling
-- submit_availability() lands approved for the same reason.
--
-- THE PRECEDENCE, which is the part that needed deciding rather than typing.
-- A submitted month does not replace the standing pattern and does not merge
-- with it — either would silently rewrite what a studio entered. It WINS FOR
-- ITS OWN DAYS, exactly the way a dated exception already beats the weekly
-- pattern in this same function:
--
--   1. a dated exception for that day
--   2. an approved submission whose period covers that day
--   3. the standing weekly pattern
--   4. nothing stated at all, which means available (unchanged, on purpose)
--
-- Truncating or splitting the standing pattern around an approved month was the
-- alternative and it is worse: a Jul-Oct pattern with a submitted September has
-- to become two rows, and a studio that later deletes the submission does not
-- get its pattern back.
--
-- THE MONTHLY CYCLE IS A SETTING, never a constant. Patterns for month M are
-- due on `studio_settings.availability_due_day` of the month before, default
-- the 20th. The reminder, the due date and the "who hasn't submitted" list all
-- read that one column.
--
-- COMMITMENTS GATE NOTHING HERE. An instructor who offers fewer hours than they
-- agreed to is still approved if staff approve it. The shortfall is a
-- conversation and `commitment_report()` is where it is had — migration 065.
-- =============================================================================

alter table studio_settings
  add column if not exists availability_due_day int not null default 20;
alter table studio_settings
  drop constraint if exists studio_settings_availability_due_day_check;
alter table studio_settings
  add constraint studio_settings_availability_due_day_check
  check (availability_due_day between 1 and 28);
comment on column studio_settings.availability_due_day is
  'Day of the PRECEDING month by which an instructor''s pattern for the next '
  'month is due. Capped at 28 so the date exists in February.';

-- -----------------------------------------------------------------------------
-- The submission
-- -----------------------------------------------------------------------------
create table if not exists availability_submissions (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid not null references studios(id) on delete cascade,
  instructor_id uuid not null references instructors(id) on delete cascade,
  -- Always the first of the month it covers. A period that is not a whole month
  -- makes "who hasn't submitted for December" unanswerable.
  period_start  date not null,
  status        text not null default 'draft'
                check (status in ('draft','submitted','approved','changes_requested')),
  note          text,
  submitted_at  timestamptz,
  reviewed_by   uuid references profiles(id) on delete set null,
  reviewed_at   timestamptz,
  created_by    uuid references profiles(id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint availability_submissions_period_is_month
    check (period_start = date_trunc('month', period_start)::date)
);
-- One per instructor per month: resubmitting after "changes requested" edits
-- the same row rather than leaving two claims about December on the table.
create unique index if not exists availability_submissions_one_per_period
  on availability_submissions (instructor_id, period_start);
create index if not exists availability_submissions_studio_period_idx
  on availability_submissions (studio_id, period_start, status);

drop trigger if exists availability_submissions_updated on availability_submissions;
create trigger availability_submissions_updated before update on availability_submissions
  for each row execute function set_updated_at();

alter table availability_submissions enable row level security;

drop policy if exists avail_sub_manager_all on availability_submissions;
create policy avail_sub_manager_all on availability_submissions
  for all using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));

-- An instructor reads and writes their OWN, and cannot approve it: approval is
-- a status change and the policy cannot express "any column but that one", so
-- the guard lives in the functions and this policy only has to keep other
-- people's submissions out of reach.
drop policy if exists avail_sub_self on availability_submissions;
create policy avail_sub_self on availability_submissions
  for all using (instructor_id = auth_instructor_id(studio_id))
  with check (instructor_id = auth_instructor_id(studio_id));

grant select, insert, update, delete on availability_submissions to authenticated;
grant all on availability_submissions to service_role;

-- -----------------------------------------------------------------------------
-- The rows learn which submission they came from, and whether they count
-- -----------------------------------------------------------------------------
alter table instructor_availability
  add column if not exists submission_id uuid
    references availability_submissions(id) on delete cascade;
alter table instructor_availability
  add column if not exists approval_status text not null default 'approved';
alter table instructor_availability
  drop constraint if exists instructor_availability_approval_status_check;
alter table instructor_availability
  add constraint instructor_availability_approval_status_check
  check (approval_status in ('draft','submitted','approved','changes_requested'));

comment on column instructor_availability.approval_status is
  'Defaults to approved because staff entry IS approval, and because every row '
  'that existed before migration 066 was entered by staff. Only the engine-'
  'visible value is ''approved''; instructor_available_at() reads nothing else.';

create index if not exists instructor_availability_approved_idx
  on instructor_availability (instructor_id, day_of_week)
  where approval_status = 'approved' and day_of_week is not null;

-- -----------------------------------------------------------------------------
-- The reader the engine uses, with the submission slotted into its precedence
-- -----------------------------------------------------------------------------
-- Rebuilt from 056's file, which is the newest that defines it. Two changes:
-- every pattern read is now `approval_status = 'approved'`, and an approved
-- submission covering the date is consulted INSTEAD of the standing pattern
-- rather than alongside it.
create or replace function instructor_available_at(
  p_instructor_id uuid, p_starts_at timestamptz, p_ends_at timestamptz
) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_tz text; v_date date; v_dow int; v_from time; v_to time;
        v_sub uuid;
begin
  if p_instructor_id is null then
    return true;
  end if;

  select i.studio_id, s.timezone into v_studio, v_tz
    from instructors i join studios s on s.id = i.studio_id
   where i.id = p_instructor_id;
  if v_studio is null then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;
  if not is_manager_up(v_studio)
     and p_instructor_id is distinct from auth_instructor_id(v_studio)
     and not is_service_context() then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;

  -- Availability is stated in studio-local wall-clock terms, so the comparison
  -- has to happen there. Comparing UTC against a local time would make an
  -- instructor unavailable for half the year in Prague.
  v_date := (p_starts_at at time zone v_tz)::date;
  v_dow  := extract(dow from (p_starts_at at time zone v_tz))::int;
  v_from := (p_starts_at at time zone v_tz)::time;
  v_to   := (p_ends_at   at time zone v_tz)::time;

  -- 1. An explicit exception for that date wins over everything, whichever way
  --    it points: a stated day off beats "Tuesdays are fine".
  if exists (select 1 from instructor_availability a
              where a.instructor_id = p_instructor_id and a.exception_date = v_date) then
    return exists (
      select 1 from instructor_availability a
       where a.instructor_id = p_instructor_id
         and a.exception_date = v_date
         and a.is_available
         and (a.starts_at_time is null or a.starts_at_time <= v_from)
         and (a.ends_at_time   is null or a.ends_at_time   >= v_to));
  end if;

  -- 2. An APPROVED submission whose month covers this date answers for it, on
  --    its own. "This is my December" is a complete statement about December,
  --    so the standing pattern is not also consulted — the alternative is a
  --    union, where an instructor can only ever add availability and never
  --    withdraw any.
  select s.id into v_sub
    from availability_submissions s
   where s.instructor_id = p_instructor_id
     and s.status = 'approved'
     and v_date between s.period_start
                    and (s.period_start + interval '1 month' - interval '1 day')::date
   order by s.period_start desc
   limit 1;

  if v_sub is not null then
    return exists (
      select 1 from instructor_availability a
       where a.submission_id = v_sub
         and a.day_of_week = v_dow
         and a.approval_status = 'approved'
         and a.is_available
         and (a.starts_at_time is null or a.starts_at_time <= v_from)
         and (a.ends_at_time   is null or a.ends_at_time   >= v_to));
  end if;

  -- 3. No stated availability at all is not the same as being unavailable. An
  --    instructor who has never opened the screen should not be flagged for
  --    every class they teach. A pattern still WAITING for approval does not
  --    count as stated — it must not narrow anything before somebody says yes.
  if not exists (select 1 from instructor_availability a
                  where a.instructor_id = p_instructor_id
                    and a.day_of_week is not null
                    and a.approval_status = 'approved') then
    return true;
  end if;

  -- 4. The standing weekly pattern.
  return exists (
    select 1 from instructor_availability a
     where a.instructor_id = p_instructor_id
       and a.day_of_week = v_dow
       and a.approval_status = 'approved'
       and a.is_available
       and (a.effective_from is null or a.effective_from <= v_date)
       and (a.effective_to   is null or a.effective_to   >= v_date)
       and (a.starts_at_time is null or a.starts_at_time <= v_from)
       and (a.ends_at_time   is null or a.ends_at_time   >= v_to));
end $$;

-- -----------------------------------------------------------------------------
-- Submitting
-- -----------------------------------------------------------------------------
-- Same payload as `set_instructor_availability()` — the editor is the same
-- editor, and two shapes for one week is how the copy-to-days control ends up
-- written twice.
create or replace function submit_availability(
  p_instructor_id uuid,
  p_period_start  date,
  p_days          jsonb,
  p_submit        boolean default true
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_studio uuid;
  v_tz     text;
  v_today  date;
  v_end    date;
  v_status text;
  v_sub    availability_submissions%rowtype;
  v_is_mgr boolean;
  d jsonb; r jsonb; v_day int; n int := 0;
begin
  select i.studio_id, s.timezone into v_studio, v_tz
    from instructors i join studios s on s.id = i.studio_id
   where i.id = p_instructor_id;
  if v_studio is null then
    raise exception 'no such instructor' using errcode = 'PT404';
  end if;

  v_is_mgr := coalesce(is_manager_up(v_studio), false);
  if not v_is_mgr and p_instructor_id is distinct from auth_instructor_id(v_studio) then
    raise exception 'only the studio or the instructor may submit their availability'
      using errcode = 'PT403';
  end if;

  if p_period_start <> date_trunc('month', p_period_start)::date then
    raise exception 'a submission covers a whole month, so it starts on the 1st'
      using errcode = 'PT422';
  end if;
  v_today := (now() at time zone v_tz)::date;
  if p_period_start < date_trunc('month', v_today)::date then
    raise exception 'that month has already been and gone' using errcode = 'PT422';
  end if;
  v_end := (p_period_start + interval '1 month' - interval '1 day')::date;

  -- Staff entry IS approval, and this is the same rule the default on
  -- approval_status encodes. A manager typing up what somebody sent by message
  -- must not create work for a manager.
  v_status := case
    when v_is_mgr then 'approved'
    when p_submit then 'submitted'
    else 'draft' end;

  insert into availability_submissions
    (studio_id, instructor_id, period_start, status, submitted_at,
     reviewed_by, reviewed_at, created_by, note)
  values (v_studio, p_instructor_id, p_period_start, v_status,
          case when v_status in ('submitted','approved') then now() end,
          case when v_status = 'approved' then auth.uid() end,
          case when v_status = 'approved' then now() end,
          auth.uid(), null)
  on conflict (instructor_id, period_start) do update
    set status = excluded.status,
        submitted_at = excluded.submitted_at,
        reviewed_by = excluded.reviewed_by,
        reviewed_at = excluded.reviewed_at,
        -- A resubmission answers the note; leaving it would show the studio's
        -- old objection beside the new pattern.
        note = null,
        updated_at = now()
  returning * into v_sub;

  if v_sub.id is null then
    raise exception 'that submission is not yours' using errcode = 'PT403';
  end if;
  if v_sub.status = 'approved' and not v_is_mgr then
    raise exception 'that month is already approved — ask the studio to reopen it'
      using errcode = 'PT409';
  end if;

  -- The whole month replaced in one go, for the same reason Decision 18 gives:
  -- a half-applied week silently changes who the scheduler says can teach.
  delete from instructor_availability where submission_id = v_sub.id;

  for d in select * from jsonb_array_elements(p_days) loop
    v_day := (d ->> 'day')::int;
    if v_day is null or v_day < 0 or v_day > 6 then
      raise exception 'day_of_week must be 0-6, got %', d ->> 'day' using errcode = 'PT422';
    end if;
    for r in select * from jsonb_array_elements(coalesce(d -> 'ranges', '[]'::jsonb)) loop
      if (r ->> 'to')::time <= (r ->> 'from')::time then
        raise exception 'a range must end after it starts (day %, % to %)',
          v_day, r ->> 'from', r ->> 'to' using errcode = 'PT422';
      end if;
      insert into instructor_availability
        (studio_id, instructor_id, day_of_week, starts_at_time, ends_at_time,
         effective_from, effective_to, is_available, created_by,
         submission_id, approval_status)
      values (v_studio, p_instructor_id, v_day,
              (r ->> 'from')::time, (r ->> 'to')::time,
              p_period_start, v_end, true, auth.uid(),
              v_sub.id, v_sub.status);
      n := n + 1;
    end loop;
  end loop;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (v_studio, auth.uid(), 'availability.submitted', 'instructors', p_instructor_id,
          jsonb_build_object('period', p_period_start, 'status', v_sub.status,
                             'ranges', n));

  -- An approved submission changes who the engine may pick, so let it fill what
  -- it now can. Open, unassigned, future classes only — it cannot take a class
  -- off anybody (Decision 9, and 061's assigned_by gate).
  if v_sub.status = 'approved' then
    perform assign_instructors_run(v_studio);
  end if;

  return jsonb_build_object(
    'submission_id', v_sub.id, 'status', v_sub.status,
    'period_start', p_period_start, 'period_end', v_end,
    'ranges', n,
    -- Reported rather than left to be noticed: a manager who expected to review
    -- this later needs to know it is already live.
    'auto_approved', v_is_mgr);
end $$;

-- -----------------------------------------------------------------------------
-- Approving, and asking for changes
-- -----------------------------------------------------------------------------
create or replace function approve_availability_submission(p_submission_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_sub availability_submissions%rowtype; v_name text; v_uid uuid;
begin
  select * into v_sub from availability_submissions where id = p_submission_id for update;
  if not found then
    raise exception 'no such submission' using errcode = 'PT404';
  end if;
  if not coalesce(is_manager_up(v_sub.studio_id), false) then
    raise exception 'only owners and managers approve availability' using errcode = 'PT403';
  end if;
  if v_sub.status = 'draft' then
    raise exception 'that pattern has not been submitted yet' using errcode = 'PT409';
  end if;

  update availability_submissions
     set status = 'approved', reviewed_by = auth.uid(), reviewed_at = now(), note = null
   where id = p_submission_id;
  update instructor_availability
     set approval_status = 'approved', updated_at = now()
   where submission_id = p_submission_id;

  -- instructors.staff_id is a studio_staff id, NOT an auth user id, and
  -- queue_shift_notice takes the latter. instructor_user_id() is the join, and
  -- it returns null for an instructor with no login — which is the ordinary
  -- case here, not an edge.
  select i.display_name into v_name from instructors i where i.id = v_sub.instructor_id;
  v_uid := instructor_user_id(v_sub.instructor_id);

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (v_sub.studio_id, auth.uid(), 'availability.approved', 'instructors',
          v_sub.instructor_id, jsonb_build_object('period', v_sub.period_start));

  -- Now that it counts, let the engine use it. Only open, unassigned, future
  -- classes: approving somebody's December cannot take a class off anyone.
  perform assign_instructors_run(v_sub.studio_id);

  return jsonb_build_object(
    'ok', true, 'submission_id', p_submission_id, 'period_start', v_sub.period_start,
    'instructor', v_name,
    -- An instructor with no login has no address anywhere in the schema, which
    -- is the ordinary case rather than an edge — so the screen says "tell them
    -- yourself" instead of implying an email that was never sent.
    'notified', queue_shift_notice(v_sub.studio_id, v_uid, 'availability_approved',
      jsonb_build_object('period', to_char(v_sub.period_start, 'FMMonth YYYY'),
                         'instructor_name', v_name),
      'avail_approved:' || p_submission_id) is not null);
end $$;

create or replace function request_availability_changes(
  p_submission_id uuid, p_note text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_sub availability_submissions%rowtype; v_name text; v_uid uuid;
begin
  select * into v_sub from availability_submissions where id = p_submission_id for update;
  if not found then
    raise exception 'no such submission' using errcode = 'PT404';
  end if;
  if not coalesce(is_manager_up(v_sub.studio_id), false) then
    raise exception 'only owners and managers review availability' using errcode = 'PT403';
  end if;
  if coalesce(btrim(p_note), '') = '' then
    raise exception 'say what needs changing — a bare refusal is not a review'
      using errcode = 'PT422';
  end if;

  update availability_submissions
     set status = 'changes_requested', note = btrim(p_note),
         reviewed_by = auth.uid(), reviewed_at = now()
   where id = p_submission_id;
  -- The rows stop counting the moment changes are asked for. They were never
  -- approved, so nothing the engine did is being undone.
  update instructor_availability
     set approval_status = 'changes_requested', updated_at = now()
   where submission_id = p_submission_id;

  -- instructors.staff_id is a studio_staff id, NOT an auth user id, and
  -- queue_shift_notice takes the latter. instructor_user_id() is the join, and
  -- it returns null for an instructor with no login — which is the ordinary
  -- case here, not an edge.
  select i.display_name into v_name from instructors i where i.id = v_sub.instructor_id;
  v_uid := instructor_user_id(v_sub.instructor_id);

  return jsonb_build_object(
    'ok', true, 'submission_id', p_submission_id, 'instructor', v_name,
    'notified', queue_shift_notice(v_sub.studio_id, v_uid, 'availability_changes_requested',
      jsonb_build_object('period', to_char(v_sub.period_start, 'FMMonth YYYY'),
                         'instructor_name', v_name, 'note', btrim(p_note)),
      -- Keyed on the review, not the submission: a second round of changes on
      -- the same month is a second thing to tell somebody.
      'avail_changes:' || p_submission_id || ':' || extract(epoch from now())::bigint) is not null);
end $$;

-- -----------------------------------------------------------------------------
-- Reading one back into the editor
-- -----------------------------------------------------------------------------
create or replace function availability_submission_week(
  p_instructor_id uuid, p_period_start date
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_sub availability_submissions%rowtype;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then
    raise exception 'no such instructor' using errcode = 'PT404';
  end if;
  if not coalesce(is_manager_up(v_studio), false)
     and p_instructor_id is distinct from auth_instructor_id(v_studio) then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;

  select * into v_sub from availability_submissions
   where instructor_id = p_instructor_id and period_start = p_period_start;

  return jsonb_build_object(
    'submission_id', v_sub.id,
    'status', coalesce(v_sub.status, 'none'),
    'note', v_sub.note,
    'submitted_at', v_sub.submitted_at,
    'reviewed_at', v_sub.reviewed_at,
    'period_start', p_period_start,
    'period_end', (p_period_start + interval '1 month' - interval '1 day')::date,
    'days', coalesce((
      select jsonb_agg(jsonb_build_object('day', day_of_week, 'ranges', ranges)
                       order by day_of_week)
        from (
          select a.day_of_week,
                 jsonb_agg(jsonb_build_object('from', to_char(a.starts_at_time,'HH24:MI'),
                                              'to',   to_char(a.ends_at_time,'HH24:MI'))
                           order by a.starts_at_time) as ranges
            from instructor_availability a
           where a.submission_id = v_sub.id and a.day_of_week is not null
           group by a.day_of_week) z
    ), '[]'::jsonb));
end $$;

-- -----------------------------------------------------------------------------
-- The monthly cycle, and who has not answered it
-- -----------------------------------------------------------------------------
-- Every date here is derived from `availability_due_day`. Chasing six people by
-- message is the work this exists to remove, so the list has to be a query
-- rather than somebody's memory.
create or replace function availability_cycle(
  p_studio_id uuid, p_period_start date default null
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_tz text; v_today date; v_period date; v_due date; v_settings studio_settings%rowtype;
begin
  if not coalesce(is_manager_up(p_studio_id), false) and not is_service_context() then
    raise exception 'only owners and managers see who has submitted' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  if v_tz is null then
    raise exception 'no such studio' using errcode = 'PT404';
  end if;
  select * into v_settings from studio_settings where studio_id = p_studio_id;

  v_today  := (now() at time zone v_tz)::date;
  -- Default to the month being collected: next month.
  v_period := coalesce(p_period_start,
                       (date_trunc('month', v_today) + interval '1 month')::date);
  -- Due on the configured day of the month BEFORE the one being collected.
  v_due := (date_trunc('month', v_period) - interval '1 month')::date
           + (coalesce(v_settings.availability_due_day, 20) - 1);

  return jsonb_build_object(
    'period_start', v_period,
    'period_end', (v_period + interval '1 month' - interval '1 day')::date,
    'due_on', v_due,
    'due_day', coalesce(v_settings.availability_due_day, 20),
    'overdue', v_today > v_due,
    'days_left', v_due - v_today,
    'instructors', coalesce((
      select jsonb_agg(jsonb_build_object(
               'instructor_id', i.id,
               'name', i.display_name,
               'has_login', instructor_user_id(i.id) is not null,
               'submission_id', s.id,
               'status', coalesce(s.status, 'none'),
               'submitted_at', s.submitted_at)
             order by (coalesce(s.status,'none') = 'submitted') desc, i.display_name)
        from instructors i
        left join availability_submissions s
               on s.instructor_id = i.id and s.period_start = v_period
       where i.studio_id = p_studio_id and i.status = 'active'
    ), '[]'::jsonb),
    'awaiting_review', (
      select count(*) from availability_submissions s
       where s.studio_id = p_studio_id and s.period_start = v_period
         and s.status = 'submitted'),
    'not_submitted', (
      select count(*) from instructors i
       where i.studio_id = p_studio_id and i.status = 'active'
         and not exists (select 1 from availability_submissions s
                          where s.instructor_id = i.id and s.period_start = v_period
                            and s.status in ('submitted','approved'))));
end $$;

-- -----------------------------------------------------------------------------
-- The reminder
-- -----------------------------------------------------------------------------
insert into notification_templates (key, subject, text_body, html_body, note) values
('availability_due',
 'Your {period} availability is due {due_wording}',
 E'Hi {instructor_name},\n\n{studio_name} needs your availability for {period} by {due_on}.\n\nOpen the staff app and fill in the week you can teach: {href}\n\nThank you,\n{studio_name}',
 '<p>Hi {instructor_name},</p><p>{studio_name} needs your availability for <strong>{period}</strong> by {due_on}.</p><p><a href="{href}">Fill in the month</a></p><p>Thank you,<br>{studio_name}</p>',
 'Migration 066. Sent on the studio''s availability_due_day and again if the '
 'day passes with nothing submitted. Keyed per instructor per period per day.'),
('availability_approved',
 'Your {period} availability is approved',
 E'Hi {instructor_name},\n\nYour availability for {period} has been approved. Classes will be scheduled around it.\n\nThank you,\n{studio_name}',
 '<p>Hi {instructor_name},</p><p>Your availability for <strong>{period}</strong> has been approved. Classes will be scheduled around it.</p><p>Thank you,<br>{studio_name}</p>',
 'Migration 066.'),
('availability_changes_requested',
 'A change to your {period} availability',
 E'Hi {instructor_name},\n\n{studio_name} has asked for a change to your {period} availability:\n\n{note}\n\nOpen the staff app to update it.\n\nThank you,\n{studio_name}',
 '<p>Hi {instructor_name},</p><p>{studio_name} has asked for a change to your <strong>{period}</strong> availability:</p><blockquote>{note}</blockquote><p>Open the staff app to update it.</p><p>Thank you,<br>{studio_name}</p>',
 'Migration 066. Carries the studio''s note, because "changes requested" with '
 'no reason is a refusal wearing a softer word.')
on conflict (key) do nothing;

-- One studio's reminders, idempotent per instructor per period per day.
create or replace function queue_availability_reminders(p_studio_id uuid)
returns int language plpgsql security definer set search_path = public as $$
declare
  v_cycle jsonb; v_tz text; v_today date; v_due date; v_period date;
  v_studio_name text; r record; n int := 0; v_wording text;
begin
  select s.timezone, s.name into v_tz, v_studio_name from studios s where s.id = p_studio_id;
  if v_tz is null then return 0; end if;
  v_today := (now() at time zone v_tz)::date;

  v_cycle  := availability_cycle(p_studio_id);
  v_due    := (v_cycle ->> 'due_on')::date;
  v_period := (v_cycle ->> 'period_start')::date;

  -- On the due day, and every day after it while somebody has still not
  -- answered. Not before: a reminder three weeks early teaches people to ignore
  -- the next one.
  if v_today < v_due then
    return 0;
  end if;
  v_wording := case when v_today = v_due then 'today' else 'on ' || to_char(v_due, 'FMDD FMMonth') end;

  for r in
    select i.id, i.display_name, instructor_user_id(i.id) as user_id
      from instructors i
     where i.studio_id = p_studio_id and i.status = 'active'
       -- An instructor with no login has no address anywhere in the schema, so
       -- there is nobody to remind. They show on the staff list instead.
       and instructor_user_id(i.id) is not null
       and not exists (select 1 from availability_submissions s
                        where s.instructor_id = i.id and s.period_start = v_period
                          and s.status in ('submitted','approved'))
  loop
    if queue_shift_notice(p_studio_id, r.user_id, 'availability_due',
         jsonb_build_object(
           'instructor_name', r.display_name,
           'studio_name', v_studio_name,
           'period', to_char(v_period, 'FMMonth YYYY'),
           'due_on', to_char(v_due, 'FMDD FMMonth'),
           'due_wording', v_wording,
           'href', '/instructors/' || r.id || '/availability'),
         -- Per person, per month, per DAY: one nudge a day at most, and a
         -- second month's chase is not deduped against the first.
         'avail_due:' || r.id || ':' || v_period || ':' || v_today) is not null
    then n := n + 1; end if;
  end loop;
  return n;
end $$;

create or replace function sweep_availability_reminders()
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; v_studios int := 0;
begin
  if not is_service_context() then
    raise exception 'the reminder sweep is a background job' using errcode = 'PT403';
  end if;
  for r in select id from studios where status = 'active' order by id loop
    -- Per studio, because the due day is per studio. No temp table anywhere in
    -- here: this loops over every studio in ONE transaction, which is exactly
    -- where `on commit drop` bit generate_morning_brief().
    n := n + queue_availability_reminders(r.id);
    v_studios := v_studios + 1;
  end loop;
  return jsonb_build_object('studios', v_studios, 'queued', n);
end $$;

do $cron$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron unavailable; availability reminders not scheduled';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'studiior-availability-reminders') then
    perform cron.unschedule('studiior-availability-reminders');
  end if;
  -- Hourly, not daily: "today" is a different day in Manila and in Prague, and
  -- the function is idempotent per studio per day, so an hour that has already
  -- run queues nothing.
  perform cron.schedule('studiior-availability-reminders', '25 * * * *',
                        'select sweep_availability_reminders()');
end $cron$;

-- -----------------------------------------------------------------------------
-- Grants
-- -----------------------------------------------------------------------------
revoke execute on function instructor_available_at(uuid, timestamptz, timestamptz)
                                                       from public, anon, authenticated;
grant  execute on function instructor_available_at(uuid, timestamptz, timestamptz)
                                                       to authenticated, service_role;
revoke execute on function submit_availability(uuid, date, jsonb, boolean)
                                                       from public, anon, authenticated;
grant  execute on function submit_availability(uuid, date, jsonb, boolean) to authenticated;
revoke execute on function approve_availability_submission(uuid) from public, anon, authenticated;
grant  execute on function approve_availability_submission(uuid) to authenticated;
revoke execute on function request_availability_changes(uuid, text) from public, anon, authenticated;
grant  execute on function request_availability_changes(uuid, text) to authenticated;
revoke execute on function availability_submission_week(uuid, date) from public, anon, authenticated;
grant  execute on function availability_submission_week(uuid, date) to authenticated;
revoke execute on function availability_cycle(uuid, date) from public, anon, authenticated;
grant  execute on function availability_cycle(uuid, date) to authenticated;
-- Background only. Both are reachable by nobody with a session.
revoke execute on function queue_availability_reminders(uuid) from public, anon, authenticated;
revoke execute on function sweep_availability_reminders()     from public, anon, authenticated;
grant  execute on function sweep_availability_reminders()     to service_role;
