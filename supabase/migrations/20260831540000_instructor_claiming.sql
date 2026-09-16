-- 149: instructor CLAIMING — inverting how a month gets staffed.
--
-- The assigned model: staff assign a roster, publish it (Decision 25), and
-- instructors CONFIRM what they were given; carry-forward fills gaps on silence.
-- Claiming inverts it PER TENANT: publish a month of UNASSIGNED classes — each
-- already marked core or flex by its series — and instructors CLAIM them, staff
-- approving every claim. The tier is fixed by the series; the commit button does
-- not ask, it tells them which it is and where they stand.
--
-- Decision 17's apply-and-approve IS the spine. apply_for_shift already flips
-- staffing open->pending_approval and notifies staff; approve_shift_application
-- already assigns via move_occurrence (hard-gating validity dates + the
-- double-booking exclusion), auto-declines every other pending application, and
-- notifies each. What is NEW: the per-instructor CORE cap, the two tiers
-- behaving differently, and the eligibility gates that a claim (unlike a cover
-- apply) is held to.
--
-- SUPERSEDES, when claiming is on: roster confirmation and carry-forward. A
-- claim IS the confirmation; carry-forward has no assigned baseline. publish_month
-- already emails nobody for unassigned classes (its inner join to instructors),
-- and a claiming studio keeps carry_forward_enabled off, so those flows go inert
-- without being re-issued here. COEXISTS: instructor_commitments' weekly minimum
-- stays a MEASURE (Decision 22/65) — the cap is a different number with the
-- opposite job (a ceiling, not a floor) and lives on its own column.

-- ---- Schema -----------------------------------------------------------------
alter table studio_settings
  add column if not exists claiming_enabled     boolean not null default false,
  add column if not exists core_claim_default_cap int   not null default 3
    check (core_claim_default_cap >= 0);
comment on column studio_settings.claiming_enabled is
  'Per tenant, off by default. On: publish unassigned classes and instructors '
  'claim them; roster confirmation and carry-forward are superseded. A studio '
  'uses EITHER this OR the assigned roster, never both.';

alter table instructors
  add column if not exists core_weekly_cap int check (core_weekly_cap >= 0);
comment on column instructors.core_weekly_cap is
  'This instructor''s weekly cap on CORE claims (soft — staff can approve past '
  'it). Null falls back to studio_settings.core_claim_default_cap. Part of what '
  'was agreed with them individually.';

alter table shift_applications
  add column if not exists over_cap boolean not null default false;
comment on column shift_applications.over_cap is
  'A core claim the instructor made past their weekly cap, with "ask anyway". '
  'Staff see it flagged on the approval screen; the cap guides, never blocks.';

-- ---- Predicates & helpers ---------------------------------------------------

-- The switch, the publication_enabled shape.
create or replace function claiming_enabled(p_studio_id uuid) returns boolean
language sql stable set search_path = public as $$
  select coalesce((select claiming_enabled from studio_settings where studio_id = p_studio_id), false)
$$;
revoke execute on function claiming_enabled(uuid) from public, anon;
grant execute on function claiming_enabled(uuid) to authenticated, service_role;

-- The effective cap: the instructor's own, else the studio default.
create or replace function instructor_core_cap(p_instructor_id uuid) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(
    i.core_weekly_cap,
    (select core_claim_default_cap from studio_settings where studio_id = i.studio_id),
    3)
  from instructors i where i.id = p_instructor_id
$$;
revoke execute on function instructor_core_cap(uuid) from public, anon;
grant execute on function instructor_core_cap(uuid) to authenticated, service_role;

-- The CONFIGURED tier ('core'|'flex'|'always') the studio set — the same
-- resolution schedule_range's occ_series_tier uses, NOT the demoted
-- occurrence_guarantee(). o.flex is propagated to occurrences by set_series_flex,
-- so it is caught before the never-null series guarantee_tier column (028's trap).
create or replace function occurrence_claim_tier(p_occurrence_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    o.guarantee_tier,
    case when o.flex then 'flex'::guarantee_tier end,
    ser.guarantee_tier,
    case when ser.flex then 'flex'::guarantee_tier end,
    'core'::guarantee_tier)::text
  from class_occurrences o
  left join class_series ser on ser.id = o.series_id
  where o.id = p_occurrence_id
$$;
revoke execute on function occurrence_claim_tier(uuid) from public, anon;
grant execute on function occurrence_claim_tier(uuid) to authenticated, service_role;

-- How many core / flex / other classes the instructor HOLDS OR IS CLAIMING in
-- the studio week containing `at`. Counted per STUDIO week from week_starts_on in
-- studio-local time (studio_week_start, NOT date_trunc('week') which is always
-- ISO Monday). Approved (=assigned) and PENDING both count — or an instructor
-- could claim six and sit at the front of every queue.
create or replace function instructor_week_claim_load(p_instructor_id uuid, p_at timestamptz)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_studio uuid; v_tz text; v_ws date; v_we date;
  v_core int := 0; v_flex int := 0; v_other int := 0;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then return jsonb_build_object('core',0,'flex',0,'other',0); end if;
  if not (is_manager_up(v_studio) or is_this_instructor(p_instructor_id) or is_service_context()) then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = v_studio;
  v_ws := studio_week_start(v_studio, (p_at at time zone v_tz)::date);
  v_we := v_ws + 7;

  with rows as (
    -- classes assigned to them (an approved claim assigns the occurrence)
    select occurrence_claim_tier(o.id) as tier
      from class_occurrences o
     where o.instructor_id = p_instructor_id and o.status = 'scheduled'
       and (o.starts_at at time zone v_tz)::date >= v_ws
       and (o.starts_at at time zone v_tz)::date <  v_we
    union all
    -- pending claims by them (not yet assigned)
    select occurrence_claim_tier(o.id) as tier
      from shift_applications sa
      join class_occurrences o on o.id = sa.occurrence_id
     where sa.instructor_id = p_instructor_id and sa.status = 'pending'
       and o.status = 'scheduled'
       and (o.starts_at at time zone v_tz)::date >= v_ws
       and (o.starts_at at time zone v_tz)::date <  v_we
  )
  select
    count(*) filter (where tier = 'core'),
    count(*) filter (where tier = 'flex'),
    count(*) filter (where tier not in ('core','flex'))
  into v_core, v_flex, v_other from rows;

  return jsonb_build_object('core', v_core, 'flex', v_flex, 'other', v_other,
                            'week_start', v_ws);
end $$;
revoke execute on function instructor_week_claim_load(uuid, timestamptz) from public, anon;
grant execute on function instructor_week_claim_load(uuid, timestamptz) to authenticated, service_role;

-- Has the instructor given availability covering a class's month? Closes
-- instructor_valid_on's "no availability at all -> true" loophole for claiming:
-- Decision 18's hard gate here is "you cannot claim a class in a month you have
-- given no availability for". True when an approved availability_submission
-- exists for that studio-local month, OR an approved standing pattern overlaps it.
create or replace function instructor_can_claim_month(p_instructor_id uuid, p_month date)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from availability_submissions s
     where s.instructor_id = p_instructor_id and s.status = 'approved'
       and date_trunc('month', s.period_start)::date = date_trunc('month', p_month)::date
  ) or exists (
    select 1 from instructor_availability a
     where a.instructor_id = p_instructor_id and a.approval_status = 'approved'
       and coalesce(a.effective_from, p_month) <= (date_trunc('month', p_month) + interval '1 month - 1 day')::date
       and coalesce(a.effective_to,   p_month) >= date_trunc('month', p_month)::date
  )
$$;
revoke execute on function instructor_can_claim_month(uuid, date) from public, anon;
grant execute on function instructor_can_claim_month(uuid, date) to authenticated, service_role;

-- ---- apply_for_shift — claiming-aware -------------------------------------
-- Non-claiming studios behave EXACTLY as before (every new gate is behind
-- claiming_enabled). Adding p_over_cap_ack is a new default arg = an overload, so
-- the 2-arg signature is dropped first and the ACL re-asserted (028's trap).
drop function if exists apply_for_shift(uuid, text);

create function apply_for_shift(p_occurrence_id uuid, p_note text default null,
                                p_over_cap_ack boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  occ class_occurrences%rowtype;
  v_instructor uuid;
  v_app uuid;
  v_available boolean;
  v_when text; v_tz text;
  v_tier text; v_cap int; v_core int; v_over boolean := false;
  v_load jsonb;
begin
  select * into occ from class_occurrences where id = p_occurrence_id for update;
  if not found then
    raise exception 'no such class' using errcode = 'PT404';
  end if;

  v_instructor := auth_instructor_id(occ.studio_id);
  if v_instructor is null then
    raise exception 'only an instructor at this studio can apply for a shift'
      using errcode = 'PT403';
  end if;
  if studio_is_locked(occ.studio_id) then
    raise exception 'this studio''s Studiior subscription is not active'
      using errcode = 'PT402';
  end if;
  if occ.staffing = 'assigned' then
    raise exception 'that class already has an instructor' using errcode = 'PT409';
  end if;
  if occ.status <> 'scheduled' then
    raise exception 'that class is %', occ.status using errcode = 'PT409';
  end if;
  if occ.starts_at < now() then
    raise exception 'that class has already happened' using errcode = 'PT409';
  end if;

  select s.timezone into v_tz from studios s where s.id = occ.studio_id;

  -- CLAIMING gates — only when this studio uses claiming. Cover-shift applies at
  -- an assigned-model studio are untouched.
  if claiming_enabled(occ.studio_id) then
    -- Publishing is the reveal: an unpublished month is not claimable.
    if not month_published(occ.studio_id, occ.starts_at) then
      raise exception 'that class is not published yet' using errcode = 'PT409';
    end if;
    -- HARD: you cannot claim in a month you gave no availability for, nor outside
    -- your validity dates (Decision 18). Availability HOURS stay a soft warning.
    if not instructor_can_claim_month(v_instructor, (date_trunc('month', occ.starts_at at time zone v_tz))::date)
       or not instructor_valid_on(v_instructor, (occ.starts_at at time zone v_tz)::date) then
      return jsonb_build_object('ok', false, 'reason', 'outside_validity');
    end if;
    -- CORE cap: soft. Refuse the self-claim past it with the numbers, and offer
    -- "ask anyway" (p_over_cap_ack) which records the over-cap flag for staff.
    v_tier := occurrence_claim_tier(occ.id);
    if v_tier = 'core' then
      v_cap  := instructor_core_cap(v_instructor);
      v_load := instructor_week_claim_load(v_instructor, occ.starts_at);
      v_core := (v_load ->> 'core')::int;
      if v_core >= v_cap and not p_over_cap_ack then
        return jsonb_build_object('ok', false, 'reason', 'over_cap',
                                  'tier', 'core', 'current', v_core, 'cap', v_cap);
      end if;
      v_over := v_core >= v_cap;   -- true only when they asked anyway
    end if;
  end if;

  insert into shift_applications (studio_id, occurrence_id, instructor_id, note, over_cap)
  values (occ.studio_id, occ.id, v_instructor, p_note, v_over)
  on conflict (occurrence_id, instructor_id) where status = 'pending'
  do nothing
  returning id into v_app;

  if v_app is null then
    raise exception 'you have already applied for that shift' using errcode = 'PT409';
  end if;

  update class_occurrences set staffing = 'pending_approval', updated_at = now()
   where id = occ.id and staffing = 'open';

  v_available := instructor_available_at(v_instructor, occ.starts_at, occ.ends_at);
  v_when := to_char(occ.starts_at at time zone v_tz, 'FMDay FMDD FMMonth, HH24:MI');

  perform queue_shift_notice_to_staff(occ.studio_id, 'shift_application_received',
    jsonb_build_object(
      'class_name', occ.name,
      'when', v_when,
      'instructor_name', (select display_name from instructors where id = v_instructor),
      'availability_note', case when v_available then ''
        else 'This is outside the availability they have given us. ' end,
      'applications_url', coalesce(nullif(notification_setting('staff_app_origin'), ''),
                                   'https://app.studiior.com') || '/shifts/applications'),
    'shift_applied:' || v_app);

  return jsonb_build_object('ok', true, 'application_id', v_app,
                            'outside_availability', not v_available,
                            'tier', v_tier, 'over_cap', v_over,
                            'standing', case when claiming_enabled(occ.studio_id)
                              then jsonb_build_object('core', coalesce((instructor_week_claim_load(v_instructor, occ.starts_at) ->> 'core')::int, 0),
                                                      'cap', instructor_core_cap(v_instructor),
                                                      'flex', coalesce((instructor_week_claim_load(v_instructor, occ.starts_at) ->> 'flex')::int, 0))
                              else null end);
end $$;
revoke execute on function apply_for_shift(uuid, text, boolean) from public, anon;
grant execute on function apply_for_shift(uuid, text, boolean) to authenticated, service_role;

-- ---- notify_open_shifts — respect publication ------------------------------
-- A draft month's open classes must never be emailed: for claiming, publishing
-- is the reveal; for the assigned model it closes a minor draft-shift leak. This
-- re-issue adds only the month_published predicate to the _os select.
create or replace function notify_open_shifts()
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
       and o.shift_alert_sent_at is null
       and month_published(o.studio_id, o.starts_at);   -- 149: never email a draft month

    if not exists (select 1 from _os) then continue; end if;
    n_shifts := n_shifts + (select count(*) from _os);

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
        v_uncontactable := v_uncontactable || jsonb_build_object(
          'studio_id', st.id, 'name', d.display_name);
        continue;
      end if;
      if queue_shift_notice(st.id, d.user_id, 'open_shifts_available',
           jsonb_build_object('instructor_name', d.display_name, 'studio_name', st.name,
             'count', d.n, 'plural', case when d.n = 1 then '' else 'es' end, 'lines', d.lines,
             'href', coalesce(nullif(notification_setting('member_app_origin'), ''),
                              'https://' || (select slug from studios where id = st.id) || '.studiior.app')
                     || '/instructor/shifts'),
           'open_shifts:' || d.instructor_id || ':' || d.fingerprint) is not null
      then
        n_told := n_told + 1;
      end if;
    end loop;
    update class_occurrences set shift_alert_sent_at = now()
     where studio_id = st.id and staffing = 'open' and shift_alert_sent_at is null
       and starts_at > now() and month_published(studio_id, starts_at);
    n_studios := n_studios + 1;
  end loop;

  return jsonb_build_object('studios', n_studios, 'shifts', n_shifts,
                            'told', n_told, 'uncontactable', v_uncontactable);
end $$;
revoke execute on function notify_open_shifts() from public, anon, authenticated;
grant execute on function notify_open_shifts() to service_role;

-- ---- Readers ----------------------------------------------------------------

-- Backs the approval screen's ranking: each pending claimant's position, so the
-- fact that decides it ("Christian 1 of 3" beside "Jhon 3 of 3") is on screen.
create or replace function claim_ranking(p_occurrence_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare occ class_occurrences%rowtype; v_tier text; v_tz text; v_res jsonb;
begin
  select * into occ from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not is_manager_up(occ.studio_id) then
    raise exception 'only owners and managers review claims' using errcode = 'PT403';
  end if;
  v_tier := occurrence_claim_tier(occ.id);
  select s.timezone into v_tz from studios s where s.id = occ.studio_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'application_id', sa.id,
           'instructor_id', sa.instructor_id,
           'display_name', i.display_name,
           'over_cap', sa.over_cap,
           'core_this_week', (instructor_week_claim_load(sa.instructor_id, occ.starts_at) ->> 'core')::int,
           'core_cap', instructor_core_cap(sa.instructor_id),
           'flex_this_week', (instructor_week_claim_load(sa.instructor_id, occ.starts_at) ->> 'flex')::int,
           'qualified', instructor_qualified(sa.instructor_id, occ.class_type_id),
           'valid', instructor_valid_on(sa.instructor_id, (occ.starts_at at time zone v_tz)::date),
           'available', instructor_available_at(sa.instructor_id, occ.starts_at, occ.ends_at)
         ) order by i.display_name), '[]'::jsonb)
    into v_res
    from shift_applications sa join instructors i on i.id = sa.instructor_id
   where sa.occurrence_id = occ.id and sa.status = 'pending';

  return jsonb_build_object('tier', v_tier, 'claimants', v_res);
end $$;
revoke execute on function claim_ranking(uuid) from public, anon;
grant execute on function claim_ranking(uuid) to authenticated, service_role;

-- What an instructor can claim from a published month — filtered to what they can
-- ACTUALLY take, the rest labelled. {can_claim:false, reason:'no_availability'}
-- when they have submitted nothing for the month (the portal says why rather than
-- an empty list).
create or replace function instructor_claimable(p_instructor_id uuid, p_month date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_studio uuid; v_tz text; v_from timestamptz; v_to timestamptz; v_list jsonb;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  if not (is_manager_up(v_studio) or is_this_instructor(p_instructor_id) or is_service_context()) then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = v_studio;

  if not instructor_can_claim_month(p_instructor_id, p_month) then
    return jsonb_build_object('can_claim', false, 'reason', 'no_availability',
      'month', to_char(p_month, 'YYYY-MM'),
      'standing', instructor_week_claim_load(p_instructor_id, now()));
  end if;

  v_from := greatest(now(), (date_trunc('month', p_month))::date::timestamp at time zone v_tz);
  v_to   := (date_trunc('month', p_month) + interval '1 month')::date::timestamp at time zone v_tz;

  select coalesce(jsonb_agg(x order by x.starts_at), '[]'::jsonb) into v_list
  from (
    select
      o.id, o.starts_at,
      to_char(o.starts_at at time zone v_tz, 'YYYY-MM-DD') as date,
      to_char(o.starts_at at time zone v_tz, 'HH24:MI')    as time,
      ct.name as class_name, ct.duration_minutes, r.name as room,
      greatest(o.capacity - o.booked_count, 0) as spaces_left, o.capacity,
      occurrence_claim_tier(o.id) as tier,
      instructor_qualified(p_instructor_id, o.class_type_id) as qualified,
      instructor_available_at(p_instructor_id, o.starts_at, o.ends_at) as available,
      instructor_valid_on(p_instructor_id, (o.starts_at at time zone v_tz)::date) as valid,
      exists (select 1 from shift_applications sa
               where sa.occurrence_id = o.id and sa.instructor_id = p_instructor_id
                 and sa.status in ('pending','approved')) as mine,
      -- clash: another class this instructor already holds or is claiming at the
      -- same time (a physical double-booking they cannot take)
      exists (
        select 1 from class_occurrences h
         where h.id <> o.id and h.status = 'scheduled'
           and tstzrange(h.starts_at, h.ends_at) && tstzrange(o.starts_at, o.ends_at)
           and (h.instructor_id = p_instructor_id
                or exists (select 1 from shift_applications sa2
                            where sa2.occurrence_id = h.id and sa2.instructor_id = p_instructor_id
                              and sa2.status = 'pending'))
      ) as clashes
    from class_occurrences o
    join class_types ct on ct.id = o.class_type_id
    left join rooms r on r.id = o.room_id
    where o.studio_id = v_studio and o.status = 'scheduled' and o.staffing = 'open'
      and o.starts_at >= v_from and o.starts_at < v_to
      and month_published(v_studio, o.starts_at)
      and instructor_valid_on(p_instructor_id, (o.starts_at at time zone v_tz)::date)  -- hard gate
  ) x;

  return jsonb_build_object(
    'can_claim', true,
    'month', to_char(p_month, 'YYYY-MM'),
    'standing', instructor_week_claim_load(p_instructor_id, now()),
    'core_cap', instructor_core_cap(p_instructor_id),
    'classes', v_list);
end $$;
revoke execute on function instructor_claimable(uuid, date) from public, anon;
grant execute on function instructor_claimable(uuid, date) to authenticated, service_role;
