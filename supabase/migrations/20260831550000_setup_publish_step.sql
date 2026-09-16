-- 150: the setup checklist learns that publishing a month is a prerequisite.
--
-- Decision 25: with publication on, members can see and book only PUBLISHED
-- months. A studio can finish everything else on the checklist — rooms, classes,
-- instructors, a full timetable — and still have members unable to book anything,
-- because the current month is a draft. That is exactly the "discover it when
-- nobody can book" failure the checklist exists to prevent, so it now carries a
-- `publish` step.
--
-- The step exists ONLY for a studio that uses publication. A studio running the
-- rolling-window model (publication off, booking_window_days) never publishes a
-- month, so the `publish` key is omitted from its checklist entirely — not shown
-- as a ticked "done" row it would never do, and not (via a missing key) rendered
-- as outstanding either. The final WHERE drops it when publication is off.
--
-- When publication IS on it is scoped to the CURRENT month, deliberately.
-- month_published(studio, now()) is true when this month is out, so the step is
-- outstanding ONLY when the current month has scheduled classes that are not yet
-- published. Future draft months are the normal build-ahead workflow, not a
-- setup gap — gating on them would nag forever for a studio that always keeps a
-- month in draft. Derived like every tick: it clears the moment the month is
-- published.
create or replace function studio_setup_state(p_studio_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  with prog as (
    select coalesce(setup_progress, '{}'::jsonb) as p
      from studio_settings where studio_id = p_studio_id
  ),
  live as (
    select id from instructors where studio_id = p_studio_id and status = 'active'
  ),
  facts(key, done) as (
    values
      ('rooms',        exists (select 1 from rooms          where studio_id = p_studio_id and status = 'active')),
      ('class_types',  exists (select 1 from class_types    where studio_id = p_studio_id and status = 'active')),
      ('instructors',  exists (select 1 from instructors    where studio_id = p_studio_id and status = 'active')),
      ('plans',        exists (select 1 from membership_plans where studio_id = p_studio_id and status = 'active')),
      ('schedule',     exists (select 1 from class_occurrences where studio_id = p_studio_id)),
      ('staff',       (select count(*) from studio_staff where studio_id = p_studio_id and status = 'active') > 1),
      ('qualifications',
       exists (select 1 from live)
       and not exists (
         select 1 from live l
          where not exists (select 1 from instructor_class_types m
                             where m.instructor_id = l.id))),
      ('availability',
       exists (select 1 from live)
       and not exists (
         select 1 from live l
          where not exists (select 1 from instructor_availability a
                             where a.instructor_id = l.id
                               and a.day_of_week is not null))),
      ('commitments',
       exists (select 1 from live)
       and not exists (
         select 1 from live l
          where not exists (select 1 from instructor_commitments c
                             where c.instructor_id = l.id and c.status = 'active'))),
      -- Publishing the CURRENT month (Decision 25). True (done) when publication
      -- is off or the month is already out — month_published covers both — or the
      -- current studio-local month has no scheduled classes to publish at all.
      ('publish',
       month_published(p_studio_id, now())
       or not exists (
         select 1 from class_occurrences o join studios s on s.id = o.studio_id
          where o.studio_id = p_studio_id and o.status = 'scheduled'
            and date_trunc('month', o.starts_at at time zone s.timezone)
              = date_trunc('month', now() at time zone s.timezone))),
      -- Nothing to derive until Stripe Connect is wired; it is a stored flag.
      ('connect_stripe',
       (select stripe_account_id is not null from studios where id = p_studio_id))
  )
  select jsonb_object_agg(
           f.key,
           jsonb_build_object(
             'done', f.done,
             'dismissed', (select coalesce(p -> 'dismissed', '{}'::jsonb) ? f.key from prog),
             'optional', (select f.key = any (st.setup_optional_items)
                            from studio_settings st where st.studio_id = p_studio_id)
           ))
    from facts f
   where (exists (select 1 from studio_staff s
                   where s.studio_id = p_studio_id and s.user_id = auth.uid()
                     and s.status = 'active' and s.role in ('owner','manager'))
          or auth.uid() is null)
     -- The publish step exists only for a studio that publishes months. Omitted
     -- entirely (not "done", not "outstanding") when publication is off.
     and (f.key <> 'publish'
          or coalesce((select publication_enabled from studio_settings where studio_id = p_studio_id), false));
$$;
-- create-or-replace keeps the ACL.
revoke execute on function studio_setup_state(uuid) from public, anon;
grant  execute on function studio_setup_state(uuid) to authenticated;
