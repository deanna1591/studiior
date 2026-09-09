-- =============================================================================
-- 067  One action for the week, and an alarm that is worth hearing
-- =============================================================================
-- An instructor confirms the week ahead in one press — "Confirm all 11 classes"
-- with the list in front of them — and asks for cover on any single class
-- beside it, which raises Decision 18's flow that already exists.
--
-- THE TIMING IS THE FEATURE. An unconfirmed week means those classes need staff
-- attention, and an alarm that goes off too early or too often is one a studio
-- learns to ignore — which is worse than not having it:
--
--   ask       Thursday, for the week ahead. Not Sunday night.
--   remind    once on Saturday, and only if nothing has been answered.
--   escalate  Sunday, to the studio, and ONLY for classes inside the next
--             three days. A Friday class unconfirmed on Sunday is not yet a
--             problem and must not be reported as one.
--
-- Every one of those is a per-studio setting, not a constant: `week_confirm_
-- ask_dow`, `_remind_dow`, `_escalate_dow` and `_escalate_days`. The suite runs
-- two studios on different settings in one pass, because a constant hiding
-- behind a default reads exactly like a setting until a second studio arrives.
--
-- AN UNCONFIRMED CLASS IS NOT AN OPEN SHIFT. Nothing here touches `staffing` or
-- `instructor_id`. Auto-opening a class because somebody was on holiday and
-- missed a button is a worse failure than the one it would be solving: the
-- class had an instructor, and now it does not, and nobody decided that.
--
-- STAFF GET ONE LINE. "3 instructors haven't confirmed this week", with who and
-- which classes — not eleven separate alarms. `unconfirmed_summary()` is that
-- line, and the escalation notice sends one email to the studio, not one per
-- class.
--
-- CONFIRMING LATE CLEARS IT SILENTLY. There is no "you were late" state, no
-- second email, and nothing to dismiss: the summary is derived from the classes
-- themselves, so answering makes it go away.
-- =============================================================================

alter table class_occurrences
  add column if not exists instructor_confirmed_at timestamptz;
comment on column class_occurrences.instructor_confirmed_at is
  'When the assigned instructor confirmed they are teaching it. Null is not an '
  'alarm on its own — see unconfirmed_summary() for what counts, and note that '
  'nothing in migration 067 ever changes staffing because of it.';

create index if not exists class_occurrences_unconfirmed_idx
  on class_occurrences (studio_id, starts_at)
  where instructor_confirmed_at is null and status = 'scheduled'
        and instructor_id is not null;

alter table studio_settings
  add column if not exists week_confirm_ask_dow      int not null default 4,
  add column if not exists week_confirm_remind_dow   int not null default 6,
  add column if not exists week_confirm_escalate_dow int not null default 0,
  add column if not exists week_confirm_escalate_days int not null default 3,
  add column if not exists week_confirm_enabled boolean not null default true;

alter table studio_settings drop constraint if exists studio_settings_week_confirm_dows_check;
alter table studio_settings add constraint studio_settings_week_confirm_dows_check
  check (week_confirm_ask_dow between 0 and 6
     and week_confirm_remind_dow between 0 and 6
     and week_confirm_escalate_dow between 0 and 6
     and week_confirm_escalate_days between 1 and 14);

comment on column studio_settings.week_confirm_ask_dow is
  'Postgres dow: 0 = Sunday. Default 4 = Thursday, asking for the week ahead.';
comment on column studio_settings.week_confirm_escalate_days is
  'Only classes starting within this many days are escalated to the studio. A '
  'Friday class unconfirmed on Sunday is not yet a problem.';

-- -----------------------------------------------------------------------------
-- Which week, in the studio's terms
-- -----------------------------------------------------------------------------
-- `week_starts_on` has been a setting since migration 001 and date_trunc always
-- means Monday, so a studio whose week starts on Sunday would have been asked
-- about the wrong seven days.
create or replace function studio_week_start(p_studio_id uuid, p_date date)
returns date language sql stable set search_path = public as $$
  select p_date - ((extract(dow from p_date)::int
                    - coalesce((select week_starts_on from studio_settings
                                 where studio_id = p_studio_id), 1) + 7) % 7)
$$;

-- -----------------------------------------------------------------------------
-- What an instructor is being asked about
-- -----------------------------------------------------------------------------
-- A class with a cover request on it is ANSWERED, not unconfirmed: asking for
-- cover is a reply. Treating it as silence would chase somebody for a class
-- they have already told the studio they cannot teach.
create or replace function instructor_week(
  p_instructor_id uuid, p_week_start date default null
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_tz text; v_week date;
begin
  select i.studio_id, s.timezone into v_studio, v_tz
    from instructors i join studios s on s.id = i.studio_id where i.id = p_instructor_id;
  if v_studio is null then
    raise exception 'no such instructor' using errcode = 'PT404';
  end if;
  if not coalesce(is_manager_up(v_studio), false)
     and p_instructor_id is distinct from auth_instructor_id(v_studio)
     and not is_service_context() then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;

  v_week := coalesce(p_week_start,
                     studio_week_start(v_studio, (now() at time zone v_tz)::date));

  return jsonb_build_object(
    'instructor_id', p_instructor_id,
    'week_start', v_week,
    'week_end', v_week + 6,
    'classes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'occurrence_id', o.id,
               'name', o.name,
               'starts_at', o.starts_at,
               'local', to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMon, HH24:MI'),
               'booked', o.booked_count,
               'confirmed', o.instructor_confirmed_at is not null,
               'cover_status', cr.status)
             order by o.starts_at)
        from class_occurrences o
        left join lateral (
          select status from cover_requests c
           where c.occurrence_id = o.id and c.status in ('pending','approved')
           order by c.requested_at desc limit 1) cr on true
       where o.instructor_id = p_instructor_id
         and o.status = 'scheduled'
         and (o.starts_at at time zone v_tz)::date between v_week and v_week + 6
    ), '[]'::jsonb),
    'unanswered', (
      select count(*) from class_occurrences o
       where o.instructor_id = p_instructor_id
         and o.status = 'scheduled'
         and o.instructor_confirmed_at is null
         and (o.starts_at at time zone v_tz)::date between v_week and v_week + 6
         and not exists (select 1 from cover_requests c
                          where c.occurrence_id = o.id and c.status in ('pending','approved'))));
end $$;

-- -----------------------------------------------------------------------------
-- Confirming
-- -----------------------------------------------------------------------------
create or replace function confirm_week(
  p_instructor_id uuid, p_week_start date default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_studio uuid; v_tz text; v_week date; n int; v_cover int;
begin
  select i.studio_id, s.timezone into v_studio, v_tz
    from instructors i join studios s on s.id = i.studio_id where i.id = p_instructor_id;
  if v_studio is null then
    raise exception 'no such instructor' using errcode = 'PT404';
  end if;
  -- The instructor, or the studio on their behalf: somebody who says yes at the
  -- desk should not have to open the app for a manager to record it.
  if not coalesce(is_manager_up(v_studio), false)
     and p_instructor_id is distinct from auth_instructor_id(v_studio) then
    raise exception 'only the studio or the instructor confirms their week'
      using errcode = 'PT403';
  end if;

  v_week := coalesce(p_week_start,
                     studio_week_start(v_studio, (now() at time zone v_tz)::date));

  -- Everything in the week at once, which is the whole point: eleven presses is
  -- how a studio ends up with nine confirmations and two people it has to chase
  -- about a button rather than about a class.
  with done as (
    update class_occurrences o
       set instructor_confirmed_at = now(), updated_at = now()
     where o.instructor_id = p_instructor_id
       and o.status = 'scheduled'
       and o.instructor_confirmed_at is null
       and (o.starts_at at time zone v_tz)::date between v_week and v_week + 6
       -- A class they have asked for cover on is not theirs to confirm.
       and not exists (select 1 from cover_requests c
                        where c.occurrence_id = o.id and c.status in ('pending','approved'))
    returning 1)
  select count(*) into n from done;

  select count(*) into v_cover from class_occurrences o
   where o.instructor_id = p_instructor_id and o.status = 'scheduled'
     and (o.starts_at at time zone v_tz)::date between v_week and v_week + 6
     and exists (select 1 from cover_requests c
                  where c.occurrence_id = o.id and c.status in ('pending','approved'));

  return jsonb_build_object(
    'ok', true, 'week_start', v_week, 'confirmed', n, 'cover_requested', v_cover);
end $$;

create or replace function confirm_occurrence(p_occurrence_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o class_occurrences%rowtype;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then
    raise exception 'no such class' using errcode = 'PT404';
  end if;
  if o.instructor_id is null then
    raise exception 'nobody is assigned to that class' using errcode = 'PT409';
  end if;
  if not coalesce(is_manager_up(o.studio_id), false)
     and o.instructor_id is distinct from auth_instructor_id(o.studio_id) then
    raise exception 'only the studio or the assigned instructor confirms a class'
      using errcode = 'PT403';
  end if;

  update class_occurrences set instructor_confirmed_at = now(), updated_at = now()
   where id = p_occurrence_id and instructor_confirmed_at is null;
  return jsonb_build_object('ok', true, 'occurrence_id', p_occurrence_id);
end $$;

-- -----------------------------------------------------------------------------
-- The one line staff see
-- -----------------------------------------------------------------------------
-- p_within_days null means the whole week; the escalation passes the studio's
-- own window so Sunday's alarm is about Monday, Tuesday and Wednesday and not
-- about Friday.
create or replace function unconfirmed_summary(
  p_studio_id uuid, p_week_start date default null, p_within_days int default null
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_tz text; v_week date; v_today date; v_cut date;
begin
  if not coalesce(is_manager_up(p_studio_id), false) and not is_service_context() then
    raise exception 'only owners and managers see who has not confirmed'
      using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  if v_tz is null then
    raise exception 'no such studio' using errcode = 'PT404';
  end if;

  v_today := (now() at time zone v_tz)::date;
  v_week  := coalesce(p_week_start, studio_week_start(p_studio_id, v_today));
  -- The window closes on the earlier of the week's end and the cut-off, and it
  -- never opens behind today: a class that has already run is not something
  -- anybody can confirm now.
  v_cut := case when p_within_days is null then v_week + 6
                else least(v_week + 6, v_today + p_within_days) end;

  return (
    with bad as (
      select o.id, o.name, o.starts_at, o.booked_count, o.instructor_id,
             i.display_name
        from class_occurrences o
        join instructors i on i.id = o.instructor_id
       where o.studio_id = p_studio_id
         and o.status = 'scheduled'
         and o.instructor_confirmed_at is null
         and (o.starts_at at time zone v_tz)::date
             between greatest(v_week, v_today) and v_cut
         and not exists (select 1 from cover_requests c
                          where c.occurrence_id = o.id and c.status in ('pending','approved'))
    )
    select jsonb_build_object(
      'week_start', v_week,
      'through', v_cut,
      'instructors', (select count(distinct instructor_id) from bad),
      'classes', (select count(*) from bad),
      -- One line, composed here rather than in a screen, so the brief, the
      -- email and the page cannot each say it slightly differently.
      'line', case when (select count(*) from bad) = 0 then null else
        format('%s instructor%s %s not confirmed %s class%s this week',
               (select count(distinct instructor_id) from bad),
               case when (select count(distinct instructor_id) from bad) = 1 then '' else 's' end,
               case when (select count(distinct instructor_id) from bad) = 1 then 'has' else 'have' end,
               (select count(*) from bad),
               case when (select count(*) from bad) = 1 then '' else 'es' end) end,
      'detail', coalesce((
        select jsonb_agg(x order by x ->> 'name')
          from (
            select jsonb_build_object(
                     'instructor_id', b.instructor_id,
                     'name', b.display_name,
                     'classes', count(*),
                     'booked', sum(b.booked_count),
                     'next', min(b.starts_at),
                     'list', jsonb_agg(jsonb_build_object(
                               'occurrence_id', b.id, 'name', b.name,
                               'local', to_char(b.starts_at at time zone v_tz,
                                                'FMDay FMDD FMMon, HH24:MI'))
                             order by b.starts_at)) as x
              from bad b group by b.instructor_id, b.display_name) z
      ), '[]'::jsonb)));
end $$;

-- -----------------------------------------------------------------------------
-- Ask, remind, escalate
-- -----------------------------------------------------------------------------
insert into notification_templates (key, subject, text_body, html_body, note) values
('week_confirm_ask',
 'Confirm your classes for {week}',
 E'Hi {instructor_name},\n\nYou have {count} classes at {studio_name} in the week of {week}.\n\nConfirm them all in one go, or ask for cover on any you cannot make: {href}\n\nThank you,\n{studio_name}',
 '<p>Hi {instructor_name},</p><p>You have <strong>{count}</strong> classes at {studio_name} in the week of {week}.</p><p><a href="{href}">Confirm them all</a>, or ask for cover on any you cannot make.</p><p>Thank you,<br>{studio_name}</p>',
 'Migration 067. Sent on the studio''s week_confirm_ask_dow for the week ahead.'),
('week_confirm_reminder',
 'Still to confirm: {count} classes next week',
 E'Hi {instructor_name},\n\n{count} of your classes in the week of {week} are still unconfirmed.\n\nConfirm them, or ask for cover: {href}\n\nThank you,\n{studio_name}',
 '<p>Hi {instructor_name},</p><p><strong>{count}</strong> of your classes in the week of {week} are still unconfirmed.</p><p><a href="{href}">Confirm them</a>, or ask for cover.</p><p>Thank you,<br>{studio_name}</p>',
 'Migration 067. ONE reminder, on week_confirm_remind_dow, only if something is '
 'still unanswered. Confirming after it arrives clears everything silently.'),
('week_unconfirmed',
 'Classes not yet confirmed in the next {days} days',
 E'{line}.\n\n{detail}\n\nOpen the staff app to see who and which classes.',
 '<p>{line}.</p><p>{detail}</p><p>Open the staff app to see who and which classes.</p>',
 'Migration 067. ONE email to the studio on week_confirm_escalate_dow, covering '
 'only classes inside week_confirm_escalate_days. Never one per class.')
on conflict (key) do nothing;

create or replace function sweep_week_confirmations()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  s record; r record;
  v_tz text; v_today date; v_dow int; v_week date; v_n int;
  n_ask int := 0; n_remind int := 0; n_escalate int := 0; v_studios int := 0;
  v_sum jsonb;
begin
  if not is_service_context() then
    raise exception 'the confirmation sweep is a background job' using errcode = 'PT403';
  end if;

  for s in
    select st.id, st.name, st.timezone,
           coalesce(cfg.week_confirm_enabled, true)        as enabled,
           coalesce(cfg.week_confirm_ask_dow, 4)           as ask_dow,
           coalesce(cfg.week_confirm_remind_dow, 6)        as remind_dow,
           coalesce(cfg.week_confirm_escalate_dow, 0)      as esc_dow,
           coalesce(cfg.week_confirm_escalate_days, 3)     as esc_days
      from studios st
      left join studio_settings cfg on cfg.studio_id = st.id
     where st.status = 'active'
     order by st.id
  loop
    v_studios := v_studios + 1;
    if not s.enabled then continue; end if;

    v_tz    := s.timezone;
    v_today := (now() at time zone v_tz)::date;
    v_dow   := extract(dow from v_today)::int;

    -- ---- ask, for the week AHEAD ------------------------------------------
    if v_dow = s.ask_dow then
      v_week := studio_week_start(s.id, v_today) + 7;
      for r in
        -- instructors.staff_id is a studio_staff id, not an auth user id.
        select i.id, i.display_name, instructor_user_id(i.id) as user_id, count(*)::int as n
          from instructors i
          join class_occurrences o on o.instructor_id = i.id and o.status = 'scheduled'
         where i.studio_id = s.id and i.status = 'active'
           and instructor_user_id(i.id) is not null
           and (o.starts_at at time zone v_tz)::date between v_week and v_week + 6
         group by i.id, i.display_name
      loop
        if queue_shift_notice(s.id, r.user_id, 'week_confirm_ask',
             jsonb_build_object('instructor_name', r.display_name, 'studio_name', s.name,
                                'count', r.n, 'week', to_char(v_week, 'FMDD FMMonth'),
                                'href', '/my/week?w=' || v_week),
             'week_ask:' || r.id || ':' || v_week) is not null
        then n_ask := n_ask + 1; end if;
      end loop;
    end if;

    -- ---- remind, once, and only if something is unanswered -----------------
    if v_dow = s.remind_dow then
      v_week := studio_week_start(s.id, v_today) + 7;
      for r in
        select i.id, i.display_name, instructor_user_id(i.id) as user_id,
               (instructor_week(i.id, v_week) ->> 'unanswered')::int as n
          from instructors i
         where i.studio_id = s.id and i.status = 'active'
           and instructor_user_id(i.id) is not null
      loop
        if r.n > 0 and queue_shift_notice(s.id, r.user_id, 'week_confirm_reminder',
             jsonb_build_object('instructor_name', r.display_name, 'studio_name', s.name,
                                'count', r.n, 'week', to_char(v_week, 'FMDD FMMonth'),
                                'href', '/my/week?w=' || v_week),
             -- One reminder for that week, ever. A second is nagging, and the
             -- escalation is the next step rather than a louder repeat.
             'week_remind:' || r.id || ':' || v_week) is not null
        then n_remind := n_remind + 1; end if;
      end loop;
    end if;

    -- ---- escalate, to the studio, about the next few days only -------------
    if v_dow = s.esc_dow then
      v_sum := unconfirmed_summary(s.id, studio_week_start(s.id, v_today) + 7, s.esc_days);
      -- The window straddles the week boundary on a Sunday, so ask about the
      -- week that is starting as well as the one just ending.
      if coalesce((v_sum ->> 'classes')::int, 0) = 0 then
        v_sum := unconfirmed_summary(s.id, studio_week_start(s.id, v_today), s.esc_days);
      end if;
      if coalesce((v_sum ->> 'classes')::int, 0) > 0 then
        v_n := queue_shift_notice_to_staff(s.id, 'week_unconfirmed',
          jsonb_build_object(
            'line', v_sum ->> 'line',
            'days', s.esc_days,
            'detail', coalesce((
              select string_agg(format('%s — %s class(es), next %s',
                                       d ->> 'name', d ->> 'classes',
                                       to_char((d ->> 'next')::timestamptz at time zone v_tz,
                                               'FMDay HH24:MI')), E'\n')
                from jsonb_array_elements(v_sum -> 'detail') d), '')),
          -- Per studio per day, so the same Sunday cannot send twice.
          'week_unconfirmed:' || s.id || ':' || v_today);
        n_escalate := n_escalate + coalesce(v_n, 0);
      end if;
    end if;
  end loop;

  return jsonb_build_object('studios', v_studios, 'asked', n_ask,
                            'reminded', n_remind, 'escalated', n_escalate);
end $$;

do $cron$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron unavailable; weekly confirmation not scheduled';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'studiior-week-confirmations') then
    perform cron.unschedule('studiior-week-confirmations');
  end if;
  -- Hourly: "Thursday" is a different day in Manila and in Prague, and every
  -- branch is idempotent per studio per week or per day, so an hour that has
  -- already run queues nothing.
  perform cron.schedule('studiior-week-confirmations', '35 * * * *',
                        'select sweep_week_confirmations()');
end $cron$;

revoke execute on function studio_week_start(uuid, date)          from public, anon, authenticated;
grant  execute on function studio_week_start(uuid, date)          to authenticated, service_role;
revoke execute on function instructor_week(uuid, date)            from public, anon, authenticated;
grant  execute on function instructor_week(uuid, date)            to authenticated;
revoke execute on function confirm_week(uuid, date)               from public, anon, authenticated;
grant  execute on function confirm_week(uuid, date)               to authenticated;
revoke execute on function confirm_occurrence(uuid)               from public, anon, authenticated;
grant  execute on function confirm_occurrence(uuid)               to authenticated;
revoke execute on function unconfirmed_summary(uuid, date, int)   from public, anon, authenticated;
grant  execute on function unconfirmed_summary(uuid, date, int)   to authenticated;
revoke execute on function sweep_week_confirmations()             from public, anon, authenticated;
grant  execute on function sweep_week_confirmations()             to service_role;
