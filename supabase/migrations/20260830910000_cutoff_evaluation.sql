-- =============================================================================
-- 081  Decision 22, part 2: cutoff evaluation.
-- =============================================================================
-- At its cutoff every occurrence becomes COMMITTED or NOT RUNNING, and
-- committed is TERMINAL. Decision 21 already built the latch and proved it: a
-- member drops out after the deadline, the headcount falls below the minimum,
-- and the class still runs, because the coach has already been told to come in.
-- This extends that latch to all three tiers rather than building a second one.
--
-- NOT RUNNING IS NOT A NEW STATUS. It is status = 'cancelled' with
-- cancellation_cause = 'unmet_minimum' (migration 079). Making it a fourth
-- occurrence_status would mean teaching thirty-odd places that filter on
-- 'cancelled' about a second way for a class to be off, and every one of them
-- would have to be found. The two facts are already typed and already travel
-- together.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- The latch stops being about flex
-- -----------------------------------------------------------------------------
-- `flex_confirmed_at` is the right mechanism under the wrong name: on a CORE
-- class it would be a lie. Renamed rather than joined by a second column,
-- because two latches drift and the first one edited wins silently.
alter table class_occurrences rename column flex_confirmed_at to committed_at;

comment on column class_occurrences.committed_at is
  'When this class became committed at its cutoff. TERMINAL: a later '
  'cancellation never un-commits it and never changes what is owed for it.';

-- The headcount AT THE CUTOFF, snapshotted, because pay is calculated from it
-- and never from attendance. A no-show must not reduce what an instructor is
-- owed for a class they turned up and taught.
alter table class_occurrences
  add column if not exists booked_at_cutoff int;

comment on column class_occurrences.booked_at_cutoff is
  'Headcount at the moment of commitment. Pay reads this, never booked_count '
  'and never attendance. Null until the class is evaluated.';

-- -----------------------------------------------------------------------------
-- What is waiting to be decided
-- -----------------------------------------------------------------------------
-- Replaces flex_pending() for all three tiers. 'always' never appears: it has
-- no cutoff and nothing to decide.
create or replace function commitment_pending(p_studio_id uuid)
returns table (occ_id uuid, occ_name text, starts_at timestamptz, local_when text,
               tier guarantee_tier, booked int, minimum int, short_by int,
               due_at timestamptz, cutoff_shape text, past_due boolean,
               instructor_id uuid, is_adjacent boolean)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_tz text; s studio_settings%rowtype;
begin
  if not coalesce(is_manager_up(p_studio_id), false) and not is_service_context() then
    raise exception 'only owners and managers see this' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  if v_tz is null then raise exception 'no such studio' using errcode = 'PT404'; end if;
  select * into s from studio_settings where studio_id = p_studio_id;
  -- Either switch puts classes in scope; occurrence_guarantee() decides which
  -- tiers those are. Neither means nothing is ever pending, which is what
  -- "sees no change" means.
  if not coalesce(s.guarantees_enabled, false)
     and not coalesce(s.flex_enabled, false) then
    return;
  end if;

  return query
  select o.id, o.name, o.starts_at,
         to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMon, HH24:MI'),
         g.tier, b.n, g.minimum, greatest(0, g.minimum - b.n),
         g.cutoff_at, g.cutoff_shape, now() >= g.cutoff_at,
         o.instructor_id, occurrence_is_adjacent(o.id)
    from class_occurrences o
    cross join lateral occurrence_guarantee(o.id) g
    cross join lateral (
      select count(*)::int as n from bookings bk
       where bk.occurrence_id = o.id
         and bk.status in ('booked','attended','no_show','pending_payment')
    ) b
   where o.studio_id = p_studio_id
     and o.status = 'scheduled'
     and o.committed_at is null
     and o.starts_at > now()
     -- 'always' is included: it commits at its start time. Only a class with no
     -- cutoff at all — a studio with both switches off — is out of scope.
     and g.cutoff_at is not null
   order by o.starts_at;
end $$;

-- -----------------------------------------------------------------------------
-- Deciding ONE occurrence
-- -----------------------------------------------------------------------------
-- IDEMPOTENT, and the idempotency is the occurrence's own state rather than the
-- job_runs claim: a decided class is committed or cancelled and never comes back
-- through here. That is what makes a fifteen-minute sweep safe, and it has to
-- be — core's cutoff is a rolling offset, so there is a decision point at every
-- hour of the day and a once-a-day claim would answer only the first of them.
create or replace function evaluate_commitment(p_occurrence_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare o class_occurrences%rowtype; g record; v_booked int;
begin
  select * into o from class_occurrences where id = p_occurrence_id for update;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(o.studio_id), false) and not is_service_context() then
    raise exception 'only owners, managers and the sweep decide a class' using errcode = 'PT403';
  end if;

  -- Already decided. A retry changes no status and sends no second notification.
  if o.committed_at is not null then
    return jsonb_build_object('ok', true, 'already', 'committed',
                              'booked_at_cutoff', o.booked_at_cutoff);
  end if;
  if o.status <> 'scheduled' then
    return jsonb_build_object('ok', true, 'already', o.status::text,
                              'cause', o.cancellation_cause);
  end if;

  select * into g from occurrence_guarantee(p_occurrence_id);
  if g.cutoff_at is null then
    return jsonb_build_object('ok', true, 'skipped', 'guarantees are off for this class');
  end if;
  if now() < g.cutoff_at then
    return jsonb_build_object('ok', true, 'skipped', 'not due', 'due_at', g.cutoff_at);
  end if;

  select count(*)::int into v_booked from bookings
   where occurrence_id = p_occurrence_id
     and status in ('booked','attended','no_show','pending_payment');

  if v_booked >= g.minimum then
    -- Committing is SILENT from the member's side: nothing about the class
    -- changes, because nothing about it was ever different.
    update class_occurrences
       set committed_at = now(), booked_at_cutoff = v_booked, updated_at = now()
     where id = p_occurrence_id;
    return jsonb_build_object('ok', true, 'decision', 'committed',
      'tier', g.tier, 'booked_at_cutoff', v_booked, 'minimum', g.minimum);
  end if;

  -- Not running. The snapshot is written FIRST and separately, because
  -- cancel_occurrence() is what makes the row cancelled and pay has to be able
  -- to read the headcount that decided it afterwards.
  update class_occurrences set booked_at_cutoff = v_booked where id = p_occurrence_id;
  perform cancel_occurrence(p_occurrence_id,
            'Did not reach its minimum by the cutoff', 'unmet_minimum');

  -- NEVER NOTIFY MEMBERS OF not_running. By definition there are fewer than the
  -- minimum and usually none at all; cancel_occurrence() tells whoever is
  -- actually booked, through §3.2, and at threshold 1 with nobody booked that
  -- is nobody. A roster fan-out here would be a second, wrong message.
  return jsonb_build_object('ok', true, 'decision', 'not_running',
    'tier', g.tier, 'booked_at_cutoff', v_booked, 'minimum', g.minimum);
end $$;

-- -----------------------------------------------------------------------------
-- Force-commit
-- -----------------------------------------------------------------------------
create or replace function force_commit_occurrence(p_occurrence_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare o class_occurrences%rowtype; v_booked int;
begin
  select * into o from class_occurrences where id = p_occurrence_id for update;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(o.studio_id), false) then
    raise exception 'only owners and managers force a class to run' using errcode = 'PT403';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'say why — a forced commitment with no reason is one nobody can explain'
      using errcode = 'PT422';
  end if;
  if o.committed_at is not null then
    raise exception '"%" is already committed', o.name using errcode = 'PT409';
  end if;

  select count(*)::int into v_booked from bookings
   where occurrence_id = p_occurrence_id
     and status in ('booked','attended','no_show','pending_payment');

  -- Reviving a class that was cancelled brings back its slot and its room, so
  -- it goes back to 'scheduled' explicitly rather than only gaining a latch.
  update class_occurrences
     set status = 'scheduled', committed_at = now(), booked_at_cutoff = v_booked,
         cancelled_at = null, cancellation_cause = null, cancellation_pays = null,
         updated_at = now()
   where id = p_occurrence_id;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (o.studio_id, auth.uid(), 'occurrence.force_committed', 'class_occurrences',
          p_occurrence_id,
          jsonb_build_object('status', o.status, 'cause', o.cancellation_cause,
                             'booked_at_cutoff', o.booked_at_cutoff),
          jsonb_build_object('reason', btrim(p_reason), 'booked_at_cutoff', v_booked,
                             'at', now()));

  return jsonb_build_object('ok', true, 'occurrence_id', p_occurrence_id,
    'booked_at_cutoff', v_booked, 'reason', btrim(p_reason));
end $$;

-- -----------------------------------------------------------------------------
-- Everything that read the old column name
-- -----------------------------------------------------------------------------
-- A rename does not tell the functions that referenced it. All three are
-- re-issued here rather than discovered failing later: schedule_range() feeds
-- the staff calendar, set_series_flex() is Decision 21's writer, and
-- flex_pending() is superseded outright by commitment_pending().
--
-- schedule_range's OUT parameter is still called occ_confirmed. The calendar
-- and app/staff/schedule/page.tsx read that name, and what it means — "this
-- class is settled" — did not change.

drop function if exists schedule_range(uuid, date, date);

create function schedule_range(p_studio_id uuid, p_from date, p_to date)
 RETURNS TABLE(occ_id uuid, occ_name text, starts_at timestamp with time zone, ends_at timestamp with time zone, local_date date, local_start text, local_end text, start_minutes integer, end_minutes integer, occ_instructor_id uuid, room_name text, occ_capacity integer, occ_booked integer, occ_waitlist integer, occ_staffing text, occ_status text, occ_flex boolean, occ_confirmed boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_tz text;
begin
  if not coalesce(is_manager_up(p_studio_id), false) and not is_service_context() then
    raise exception 'the timetable is the owner''s and managers'' to see'
      using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  if v_tz is null then
    raise exception 'no such studio' using errcode = 'PT404';
  end if;
  if p_to < p_from then
    raise exception 'that range ends before it starts' using errcode = 'PT400';
  end if;
  -- A calendar asks for a day, a week or a month. Anything much larger is a
  -- mistake rather than a request, and it would be paid for in one query.
  if p_to - p_from > 62 then
    raise exception 'ask for at most 62 days at a time' using errcode = 'PT422';
  end if;

  -- The OUT parameters share their names with the columns, so every reference
  -- inside the query is qualified and the table is aliased. Unqualified `id`
  -- resolves to the output column and is ambiguous.
  return query
  select o.id, o.name, o.starts_at, o.ends_at,
         (o.starts_at at time zone v_tz)::date,
         to_char(o.starts_at at time zone v_tz, 'HH24:MI'),
         to_char(o.ends_at   at time zone v_tz, 'HH24:MI'),
         (extract(hour from o.starts_at at time zone v_tz) * 60
          + extract(minute from o.starts_at at time zone v_tz))::int,
         (extract(hour from o.ends_at at time zone v_tz) * 60
          + extract(minute from o.ends_at at time zone v_tz))::int,
         o.instructor_id, r.name, o.capacity, o.booked_count, o.waitlist_count,
         o.staffing::text, o.status::text,
         o.flex, o.committed_at is not null
    from class_occurrences o
    left join rooms r on r.id = o.room_id
   where o.studio_id = p_studio_id
     and o.status <> 'cancelled'
     -- THE WHOLE POINT: the range is expressed in the studio's days, and the
     -- comparison happens after converting. Comparing UTC instants against a
     -- date loses the classes either side of local midnight — which for Manila
     -- is every 07:00 class in the timetable.
     and (o.starts_at at time zone v_tz)::date between p_from and p_to
   order by o.starts_at;
end $function$;

revoke execute on function schedule_range(uuid, date, date) from public, anon, authenticated;
grant  execute on function schedule_range(uuid, date, date) to authenticated;

create or replace function set_series_flex(p_series_id uuid, p_flex boolean, p_minimum_bookings integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare ser class_series%rowtype; v_min int; n int;
begin
  select * into ser from class_series where id = p_series_id;
  if not found then
    raise exception 'no such series' using errcode = 'PT404';
  end if;
  if not coalesce(is_manager_up(ser.studio_id), false) then
    raise exception 'only owners and managers change the timetable' using errcode = 'PT403';
  end if;
  if p_flex and coalesce(p_minimum_bookings, 0) < 1 then
    raise exception 'a flex class needs a minimum of at least one booking'
      using errcode = 'PT422';
  end if;
  v_min := case when p_flex then p_minimum_bookings else null end;

  update class_series set flex = p_flex, minimum_bookings = v_min, updated_at = now()
   where id = p_series_id;

  with touched as (
    update class_occurrences
       set flex = p_flex, minimum_bookings = v_min, updated_at = now()
     where series_id = p_series_id
       and status = 'scheduled'
       and starts_at > now()
       and committed_at is null
    returning 1)
  select count(*) into n from touched;

  return jsonb_build_object('ok', true, 'flex', p_flex,
                            'minimum_bookings', v_min, 'occurrences_updated', n);
end $function$;

-- flex_pending() is replaced by commitment_pending(), which answers the same
-- question for all three tiers. Kept as a thin wrapper so the screen at
-- /schedule/flex keeps working until it is rebuilt around tiers, and marked so
-- nobody adds a second caller.
drop function if exists flex_pending(uuid);

create or replace function flex_pending(p_studio_id uuid)
returns table (occ_id uuid, occ_name text, starts_at timestamptz, local_when text,
               booked int, minimum int, short_by int, due_at timestamptz, past_due boolean)
language sql
stable
security definer
set search_path to 'public'
as $$
  -- DEPRECATED: commitment_pending() is the one to call. This exists only so
  -- the existing flex screen does not break in the same migration that changes
  -- what it is a view of.
  select occ_id, occ_name, starts_at, local_when, booked, minimum, short_by, due_at, past_due
    from commitment_pending(p_studio_id)
   where tier = 'flex';
$$;

revoke execute on function flex_pending(uuid) from public, anon, authenticated;
grant  execute on function flex_pending(uuid) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- One message per instructor per run, not five pings
-- -----------------------------------------------------------------------------
insert into notification_templates (key, subject, text_body, html_body, note) values
('commitment_digest',
 'Your classes: {summary_line}',
 E'Hi {instructor_name},\n\n{intro_line}\n\n{lines}\n\n{closing_line}\n\n{studio_name}',
 -- The list is preformatted in the text body and stays that way in the HTML:
 -- a class name, a time and two numbers line up when they are monospaced and
 -- turn into a paragraph when they are not.
 '<p>Hi {instructor_name},</p><p>{intro_line}</p>'
 '<pre style="font:13px/1.5 ui-monospace,Menlo,Consolas,monospace;margin:0">{lines}</pre>'
 '<p>{closing_line}<br>{studio_name}</p>',
 'Decision 22. One digest per instructor per evaluation run. Sent instead of a '
 'message per class, because five pings about five classes is how a studio '
 'teaches its instructors to stop reading them.')
on conflict (key) do update
  set subject = excluded.subject, text_body = excluded.text_body,
      html_body = excluded.html_body, note = excluded.note;

-- -----------------------------------------------------------------------------
-- The sweep
-- -----------------------------------------------------------------------------
create or replace function sweep_commitments()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  st record; r record; d record; v_job uuid; v_tz text;
  n_comm int := 0; n_not int := 0; n_studios int := 0; n_told int := 0;
  v_res jsonb; v_user uuid; v_key text;
  v_lines text; v_intro text; v_close text; v_summary text;
  v_n_comm int; v_n_not int;
begin
  if not is_service_context() then
    raise exception 'the commitment sweep is a background job' using errcode = 'PT403';
  end if;

  for st in
    select s.id, s.name, s.timezone
      from studios s
      join studio_settings cfg on cfg.studio_id = s.id
     where s.status = 'active'
       and (coalesce(cfg.guarantees_enabled, false) or coalesce(cfg.flex_enabled, false))
     order by s.id
  loop
    n_studios := n_studios + 1;
    v_tz := st.timezone;

    -- job_runs RECORDS the pass and counts attempts. It does not gate it: core's
    -- cutoff is a rolling offset, so there is a decision point at every hour of
    -- the day, and a once-a-day claim would answer only the first of them. The
    -- idempotency is each occurrence's own state.
    insert into job_runs (job_key, run_for, status)
    values ('commitments:' || st.id, (now() at time zone v_tz)::date, 'running')
    on conflict (job_key, run_for) do update
       set attempts = job_runs.attempts + 1, started_at = now(), status = 'running'
    returning id into v_job;

    -- What this pass decided, per instructor, so the notification can be one
    -- message rather than one per class.
    create temporary table if not exists _decided (
      instructor_id uuid, user_id uuid, occ_id uuid, occ_name text,
      local_when text, decision text, booked int, minimum int, tier text
    ) on commit drop;
    delete from _decided;

    for r in select * from commitment_pending(st.id) where past_due loop
      v_res := evaluate_commitment(r.occ_id);
      if v_res ? 'decision' then
        if v_res ->> 'decision' = 'committed' then n_comm := n_comm + 1;
        else n_not := n_not + 1; end if;
        insert into _decided values (
          r.instructor_id, instructor_user_id(r.instructor_id), r.occ_id, r.occ_name,
          r.local_when, v_res ->> 'decision',
          (v_res ->> 'booked_at_cutoff')::int, r.minimum, r.tier::text);
      end if;
    end loop;

    -- One digest per instructor who has a login. An instructor with none comes
    -- out null and is simply not queued — two of three seeded instructors have
    -- no login and that is the ordinary case, not an edge.
    for d in
      select user_id,
             (select display_name from instructors i where i.id = _d.instructor_id) as name,
             count(*) filter (where decision = 'committed') as n_comm,
             count(*) filter (where decision = 'not_running') as n_not,
             string_agg(
               case when decision = 'committed'
                 then '  RUNNING   ' || occ_name || ' — ' || local_when
                      || ' (' || booked || ' booked)'
                 else '  NOT ON    ' || occ_name || ' — ' || local_when
                      || ' (needed ' || minimum || ', had ' || booked || ')'
               end, E'\n' order by local_when) as lines,
             md5(string_agg(occ_id::text, ',' order by occ_id)) as fingerprint
        from _decided _d
       where user_id is not null
       group by user_id, _d.instructor_id
    loop
      v_n_comm := d.n_comm; v_n_not := d.n_not;
      v_summary := case
        when v_n_not = 0 then v_n_comm || ' running'
        when v_n_comm = 0 then v_n_not || ' not going ahead'
        else v_n_comm || ' running, ' || v_n_not || ' not' end;
      v_intro := case
        when v_n_not = 0 then 'Everything below has the numbers and is going ahead.'
        when v_n_comm = 0 then 'These did not reach their minimum by the cutoff, so they are off.'
        else 'Here is where your classes landed at their cutoff.' end;
      v_close := case
        when v_n_not = 0 then 'See you there,'
        else 'You do not need to come in for anything marked NOT ON.' end;

      -- DEDUPED ON THE SET, not on the day. A retry decides nothing and sends
      -- nothing; a genuinely later batch contains different classes and so
      -- carries a different key and does send. Keying on the instructor and the
      -- date would suppress the second, which is the mistake migration 073's
      -- resend already made once.
      v_key := 'commitment_digest:' || d.fingerprint;
      if queue_shift_notice(st.id, d.user_id, 'commitment_digest',
           jsonb_build_object('instructor_name', coalesce(d.name, 'there'),
             'studio_name', st.name, 'summary_line', v_summary,
             'intro_line', v_intro, 'lines', d.lines, 'closing_line', v_close),
           v_key) is not null
      then n_told := n_told + 1; end if;
    end loop;

    update job_runs set status = 'done', finished_at = now(), error = null where id = v_job;
  end loop;

  return jsonb_build_object('studios', n_studios, 'committed', n_comm,
                            'not_running', n_not, 'instructors_told', n_told);
end $$;

-- -----------------------------------------------------------------------------
-- Retire the flex-only sweep and put the new one on the same schedule
-- -----------------------------------------------------------------------------
drop function if exists sweep_flex_decisions();

do $cron$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron unavailable; commitment sweep not scheduled';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'studiior-flex-decisions') then
    perform cron.unschedule('studiior-flex-decisions');
  end if;
  if exists (select 1 from cron.job where jobname = 'studiior-commitments') then
    perform cron.unschedule('studiior-commitments');
  end if;
  -- Every fifteen minutes, and now it matters more than it did for flex alone:
  -- core's cutoff is a rolling offset from each class, so cutoffs fall at every
  -- hour of the day rather than once each evening.
  perform cron.schedule('studiior-commitments', '*/15 * * * *',
                        'select sweep_commitments()');
end $cron$;

revoke execute on function commitment_pending(uuid)          from public, anon, authenticated;
revoke execute on function evaluate_commitment(uuid)         from public, anon, authenticated;
revoke execute on function force_commit_occurrence(uuid,text) from public, anon, authenticated;
revoke execute on function sweep_commitments()               from public, anon, authenticated;
grant execute on function commitment_pending(uuid)           to authenticated, service_role;
grant execute on function evaluate_commitment(uuid)          to authenticated, service_role;
grant execute on function force_commit_occurrence(uuid,text) to authenticated;
grant execute on function sweep_commitments()                to service_role;
