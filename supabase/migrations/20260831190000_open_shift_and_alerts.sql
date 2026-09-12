-- =============================================================================
-- Migration 114 — a staff control to OPEN a shift, and an alert to the
-- instructors who could take it
-- =============================================================================
-- Decision 17's apply-and-approve is untouched: instructors apply, every
-- application stands, staff pick. This is the step BEFORE that — putting a
-- class up for grabs in the first place.
--
-- Two halves:
--   1. open_shift() — staff take an instructor off a class and publish it as an
--      open shift. The class stays bookable throughout; the instructor removed
--      is TOLD (finding out from the calendar that you are off a class is the
--      wrong way to learn it); it is audited with who and why.
--   2. notify_open_shifts() — when a shift opens, email every instructor
--      QUALIFIED for that class type. Available-and-in-window first, the rest
--      told too but plainly marked ("outside the hours you gave us"), because a
--      6am gap wants anyone who can stand in front of the room. Batched: six
--      shifts that open together are one email listing six.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Opening a class — the direct control
-- -----------------------------------------------------------------------------
-- approve_cover_request()'s 'open' mode and stamp_open_shift() already open a
-- class INTERNALLY, but only off the back of a cover request an instructor
-- raised. There was no way for staff to simply take somebody off a class. This
-- is that, and it goes through move_occurrence() so the clearing hits the same
-- exclusion checks and the same assigned_by stamp — the engine will not refill
-- a shift the studio deliberately opened (Decision 17).
create function open_shift(p_occurrence_id uuid, p_reason text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  o class_occurrences%rowtype; s studios%rowtype;
  v_old_instr uuid; v_old_name text; v_user uuid; v_when text; v_told boolean := false;
  v_move jsonb;
begin
  select * into o from class_occurrences where id = p_occurrence_id for update;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(o.studio_id), false) then
    raise exception 'only owners and managers open a shift' using errcode = 'PT403';
  end if;
  if o.status <> 'scheduled' then
    raise exception 'a % class cannot be opened', o.status using errcode = 'PT409';
  end if;
  if o.instructor_id is null then
    raise exception 'that class already has nobody on it' using errcode = 'PT409';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'say why — the instructor being taken off gets this, and the studio''s record keeps it'
      using errcode = 'PT422';
  end if;

  v_old_instr := o.instructor_id;
  select display_name into v_old_name from instructors where id = v_old_instr;
  select * into s from studios where id = o.studio_id;
  v_when := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth, HH24:MI');

  -- Clear through move_occurrence(): p_confirm true because opening a class is
  -- not moving anybody's booking — the members keep their seats and the class
  -- stays bookable — and p_clear_instructor makes staffing 'open'. This also
  -- stamps assigned_by via stamp_open_shift below, so "fill a month" leaves it
  -- alone.
  v_move := move_occurrence(p_occurrence_id => p_occurrence_id, p_confirm => true,
                            p_clear_instructor => true);
  if not coalesce((v_move ->> 'ok')::boolean, false) then
    return v_move;
  end if;
  perform stamp_open_shift(p_occurrence_id);

  -- The instructor removed is told. queue_shift_notice returns null for
  -- somebody with no login (the ordinary case), which is reported rather than
  -- passed off as a message that was sent.
  v_user := instructor_user_id(v_old_instr);
  if v_user is not null then
    v_told := queue_shift_notice(o.studio_id, v_user, 'shift_taken_off',
      jsonb_build_object(
        'instructor_name', coalesce(v_old_name, 'there'),
        'studio_name', s.name,
        'class_name', o.name,
        'when', v_when,
        'reason', btrim(p_reason)),
      -- Keyed on the class and the instructor and the time: taken off the same
      -- class twice at different times is two notices, the same one is one.
      'shift_taken_off:' || o.id || ':' || v_old_instr || ':' || extract(epoch from o.starts_at)::bigint
    ) is not null;
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (o.studio_id, auth.uid(), 'occurrence.opened', 'class_occurrences', p_occurrence_id,
          jsonb_build_object('instructor_id', v_old_instr, 'instructor_name', v_old_name),
          jsonb_build_object('reason', btrim(p_reason), 'booked_count', o.booked_count,
                             'removed_notified', v_told, 'at', now()));

  return jsonb_build_object(
    'ok', true, 'occurrence_id', p_occurrence_id,
    'removed_instructor', v_old_name,
    'removed_notified', v_told,
    -- Named so the caller can tell "taken off but has no login to hear it" from
    -- "told" — the screen says "tell them yourself" in that case.
    'removed_uncontactable', (v_user is null),
    'booked_count', o.booked_count);
end $$;

-- -----------------------------------------------------------------------------
-- 2. When a shift opens — who could take it, and telling them
-- -----------------------------------------------------------------------------
alter table class_occurrences
  add column shift_opened_at    timestamptz,
  add column shift_alert_sent_at timestamptz;

comment on column class_occurrences.shift_opened_at is
  'When this class last became an open shift. Set by tg_stamp_shift_opened on '
  'the transition to staffing=open; notify_open_shifts() reads it.';
comment on column class_occurrences.shift_alert_sent_at is
  'When qualified instructors were last emailed about this open shift. Null '
  'again each time it re-opens, so a re-opened shift alerts afresh.';

-- One point, every path: whenever a class becomes an open shift — created open,
-- opened by open_shift(), opened by a cover approval, left open by the engine —
-- stamp it. A trigger rather than a line in each caller, so the next opener
-- cannot forget. Runs after tg_derive_staffing (alphabetical: d < s), so
-- NEW.staffing is settled.
create function tg_stamp_shift_opened() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    if new.staffing = 'open' then
      new.shift_opened_at := now();
      new.shift_alert_sent_at := null;
    end if;
  elsif new.staffing = 'open' and coalesce(old.staffing::text, '') <> 'open' then
    new.shift_opened_at := now();
    new.shift_alert_sent_at := null;
  end if;
  return new;
end $$;

create trigger tg_stamp_shift_opened
  before insert or update of staffing, instructor_id on class_occurrences
  for each row execute function tg_stamp_shift_opened();

-- Everything already open on the day this ships has been open for a while and
-- nobody is waiting on an email about it; mark it alerted so the first sweep
-- does not blast the backlog. Only shifts that open AFTER this alert.
update class_occurrences set shift_alert_sent_at = now()
 where staffing = 'open' and shift_alert_sent_at is null;

insert into notification_templates (key, subject, text_body, html_body, note) values
('shift_taken_off',
 'You have been taken off {class_name}',
 E'Hi {instructor_name},\n\n{studio_name} has taken you off {class_name} on {when}.\n\nWhy: {reason}\n\nIf that is a surprise, talk to them.',
 '<p>Hi {instructor_name},</p><p>{studio_name} has taken you off <strong>{class_name}</strong> on {when}.</p><p><strong>Why:</strong> {reason}</p><p>If that is a surprise, talk to them.</p>',
 'Migration 114. Sent to the instructor open_shift() removes from a class.'),
('open_shifts_available',
 '{count} class{plural} you could take at {studio_name}',
 E'Hi {instructor_name},\n\n{studio_name} has {count} open class{plural} you are qualified for:\n\n{lines}\n\nApply for any of them here: {href}\n\nWhoever applies, the studio decides.',
 '<p>Hi {instructor_name},</p><p>{studio_name} has <strong>{count}</strong> open class{plural} you are qualified for:</p><pre style="font:inherit">{lines}</pre><p><a href="{href}">Apply for any of them</a> — whoever applies, the studio decides.</p>',
 'Migration 114. One digest per instructor, batching every shift that opened '
 'since the last sweep. Available-and-in-window classes first, the rest marked.')
on conflict (key) do nothing;

-- The sweep. Batches per instructor: every open shift they are qualified for
-- that has not been alerted, available ones first, the rest flagged.
create function notify_open_shifts()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  st record; d record; v_tz text;
  n_studios int := 0; n_told int := 0; n_shifts int := 0;
  v_uncontactable jsonb := '[]'::jsonb;
begin
  if not is_service_context() then
    raise exception 'the open-shift alert is a background job' using errcode = 'PT403';
  end if;

  for st in
    select s.id, s.name, s.timezone from studios s where s.status = 'active' order by s.id
  loop
    v_tz := st.timezone;

    -- The shifts to alert on this pass. Future, still open, never alerted.
    create temporary table if not exists _os (occ_id uuid, occ_name text, class_type_id uuid,
                                              starts_at timestamptz, ends_at timestamptz, local_when text, booked int)
      on commit drop;
    delete from _os;
    insert into _os
    select o.id, o.name, o.class_type_id, o.starts_at, o.ends_at,
           to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMon, HH24:MI'), o.booked_count
      from class_occurrences o
     where o.studio_id = st.id
       and o.status = 'scheduled'
       and o.staffing = 'open'
       and o.starts_at > now()
       and o.shift_opened_at is not null
       and o.shift_alert_sent_at is null;

    if not exists (select 1 from _os) then continue; end if;
    n_shifts := n_shifts + (select count(*) from _os);

    -- Every (qualified instructor, shift) pair, with whether the instructor is
    -- inside their validity window AND free at the time. Qualified is the hard
    -- filter; availability only orders and labels — a 6am gap wants anyone who
    -- can teach it, said plainly.
    for d in
      select i.id as instructor_id, i.display_name,
             instructor_user_id(i.id) as user_id,
             string_agg(
               case when av.ok
                 then '  ' || _os.local_when || ' — ' || _os.occ_name
                      || case when _os.booked > 0 then ' (' || _os.booked || ' booked)' else '' end
                 else '  ' || _os.local_when || ' — ' || _os.occ_name
                      || ' — outside the hours you gave us'
               end,
               E'\n' order by av.ok desc, _os.starts_at) as lines,
             count(*) as n,
             md5(string_agg(_os.occ_id::text, ',' order by _os.occ_id)) as fingerprint
        from instructors i
        join _os on instructor_qualified(i.id, _os.class_type_id)
        cross join lateral (
          select instructor_valid_on(i.id, (_os.starts_at at time zone v_tz)::date)
                 and instructor_available_at(i.id, _os.starts_at, _os.ends_at) as ok
        ) av
       where i.studio_id = st.id and i.status = 'active'
       group by i.id, i.display_name
    loop
      if d.user_id is null then
        -- Qualified, but no login to reach. Reported rather than counted as
        -- told: an email nobody can receive is not a message.
        v_uncontactable := v_uncontactable || jsonb_build_object(
          'instructor_id', d.instructor_id, 'name', d.display_name, 'studio_id', st.id);
        continue;
      end if;
      if queue_shift_notice(st.id, d.user_id, 'open_shifts_available',
           jsonb_build_object(
             'instructor_name', coalesce(d.display_name, 'there'),
             'studio_name', st.name,
             'count', d.n,
             'plural', case when d.n = 1 then '' else 'es' end,
             'lines', d.lines,
             'href', coalesce(nullif(notification_setting('member_app_domain'), ''), 'studiior.app')),
           -- Per instructor per SET of shifts, so a genuinely different batch
           -- sends and a retry of the same one does not.
           'open_shifts:' || d.instructor_id || ':' || d.fingerprint) is not null
      then n_told := n_told + 1; end if;
    end loop;

    update class_occurrences set shift_alert_sent_at = now()
     where id in (select occ_id from _os);
    n_studios := n_studios + 1;
  end loop;

  return jsonb_build_object('studios', n_studios, 'shifts', n_shifts,
                            'instructors_told', n_told, 'uncontactable', v_uncontactable);
end $$;

do $cron$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron unavailable; open-shift alert not scheduled';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'studiior-open-shifts') then
    perform cron.unschedule('studiior-open-shifts');
  end if;
  -- Every fifteen minutes: near-immediate, and the window is what does the
  -- batching — six shifts opened in one action land in one pass.
  perform cron.schedule('studiior-open-shifts', '*/15 * * * *', 'select notify_open_shifts()');
end $cron$;

-- -----------------------------------------------------------------------------
-- Grants, and the assertion
-- -----------------------------------------------------------------------------
revoke execute on function open_shift(uuid, text)        from public, anon, authenticated;
grant  execute on function open_shift(uuid, text)        to authenticated;
revoke execute on function tg_stamp_shift_opened()       from public, anon, authenticated;
revoke execute on function notify_open_shifts()          from public, anon, authenticated;
grant  execute on function notify_open_shifts()          to service_role;

do $$
begin
  if has_function_privilege('anon', 'open_shift(uuid, text)', 'execute') then
    raise exception 'migration 114: open_shift is anon-callable';
  end if;
  if not has_function_privilege('authenticated', 'open_shift(uuid, text)', 'execute') then
    raise exception 'migration 114: open_shift lost its grant';
  end if;
  if has_function_privilege('authenticated', 'notify_open_shifts()', 'execute')
     or has_function_privilege('authenticated', 'tg_stamp_shift_opened()', 'execute') then
    raise exception 'migration 114: an internal is reachable by authenticated';
  end if;
end $$;
