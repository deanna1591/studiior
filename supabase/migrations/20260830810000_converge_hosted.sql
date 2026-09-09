-- =============================================================================
-- 071  Converging hosted with the files, after two migrations were edited in
--      place AFTER they had already been applied
-- =============================================================================
-- The staff calendar showed an empty grid for every day of November on hosted
-- while every local check passed. Reasoning from local kept missing it, so it
-- was diagnosed against the real studio, as it should have been the first time.
--
-- `schedule_range()` ON HOSTED RAISES ON ITS OWN FIRST STATEMENT:
--
--   ERROR: 42702 column reference "id" is ambiguous
--   QUERY: select timezone from studios where id = p_studio_id
--
-- Hosted carries the FIRST draft of migration 070, whose RETURNS TABLE begins
-- `id uuid, name text` — OUT parameters that shadow the columns the body reads.
-- That was hit locally, the names were changed to `occ_*` IN THE MIGRATION FILE,
-- and `db reset` replayed from scratch and looked fixed. Hosted had already
-- recorded 20260830800000 as applied and will never replay it.
-- **An applied migration is immutable — fix forward, never edit in place.**
-- The rule is in CLAUDE.md; this is what breaking it costs.
--
-- Every symptom follows from the function raising. PostgREST returns an error,
-- the page read `data` and ignored `error`, `rows ?? []` came out empty, the
-- grid drew nothing — and with no rows the derived visible hours fell back to
-- their default, which is why the gutter still began at 06:00.
--
-- THE SECOND DIVERGENCE, found by diffing all 184 function definitions rather
-- than by guessing which might be wrong. Hosted has `purge_demo_data(uuid)`
-- with migration 062's census guard inside it, and neither the two-argument
-- signature nor `demo_purge_preview` that the same file creates — so 062 was
-- edited in place too, in an earlier session, and hosted stopped at the draft.
-- **The protection that matters is intact**: the census that refuses to commit
-- if a single non-demo row has gone is present. What is missing is the
-- confirmation step in front of it, so on hosted that function still deletes
-- without asking.
--
-- THE LESSON WORTH MORE THAN EITHER FIX: `supabase migration list` records
-- THAT a version ran, never WHICH. It showed all seventy applied and agreed
-- with itself while two functions differed. Diff the function definitions.
--
-- Both are re-issued below from the FILES that define them, never from a
-- database, and are written to land whichever state a database is in.
-- =============================================================================

drop function if exists schedule_range(uuid, date, date);

create function schedule_range(
  p_studio_id uuid, p_from date, p_to date
) returns table (
  -- Prefixed, because an OUT parameter named `id` shadows `class_occurrences.id`
  -- inside the body and every reference to it becomes ambiguous. PostgREST
  -- returns these names to the caller, so the page reads them prefixed too.
  occ_id         uuid,
  occ_name       text,
  starts_at      timestamptz,
  ends_at        timestamptz,
  -- Resolved HERE, so no caller has to know how to ask.
  local_date     date,
  local_start    text,
  local_end      text,
  start_minutes  int,
  end_minutes    int,
  occ_instructor_id uuid,
  room_name      text,
  occ_capacity   int,
  occ_booked     int,
  occ_waitlist   int,
  occ_staffing   text,
  occ_status     text
) language plpgsql stable security definer set search_path = public as $$
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
         o.staffing::text, o.status::text
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
end $$;;

-- A drop discards the ACL, so 070's grant comes back with it.
revoke execute on function schedule_range(uuid, date, date) from public, anon, authenticated;
grant  execute on function schedule_range(uuid, date, date) to authenticated;

-- -----------------------------------------------------------------------------
-- Migration 062's two-step purge, for the databases that stopped at its draft
-- -----------------------------------------------------------------------------
-- The one-argument signature goes rather than sitting beside the new one: a
-- default does not replace a signature, it creates an overload, and every
-- existing call then fails as ambiguous — migration 028's trap.
drop function if exists purge_demo_data(uuid);

create or replace function demo_purge_preview(p_studio_id uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'bookings',          nullif((select count(*) from bookings          where studio_id = p_studio_id and is_demo), 0),
    'check_ins',         nullif((select count(*) from check_ins         where studio_id = p_studio_id and is_demo), 0),
    'class_occurrences', nullif((select count(*) from class_occurrences where studio_id = p_studio_id and is_demo), 0),
    'class_series',      nullif((select count(*) from class_series      where studio_id = p_studio_id and is_demo), 0),
    'class_types',       nullif((select count(*) from class_types       where studio_id = p_studio_id and is_demo), 0),
    'credit_ledger',     nullif((select count(*) from credit_ledger     where studio_id = p_studio_id and is_demo), 0),
    'instructors',       nullif((select count(*) from instructors       where studio_id = p_studio_id and is_demo), 0),
    'members',           nullif((select count(*) from members           where studio_id = p_studio_id and is_demo), 0),
    'membership_plans',  nullif((select count(*) from membership_plans  where studio_id = p_studio_id and is_demo), 0),
    'memberships',       nullif((select count(*) from memberships       where studio_id = p_studio_id and is_demo), 0),
    'payments',          nullif((select count(*) from payments          where studio_id = p_studio_id and is_demo), 0),
    'rooms',             nullif((select count(*) from rooms             where studio_id = p_studio_id and is_demo), 0)))
$$;
revoke execute on function demo_purge_preview(uuid) from public, anon, authenticated;

create or replace function purge_demo_data(p_studio_id uuid, p_confirm boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  n_members int; n_payments int; n_occ int; n_plans int; n_misc int;
  v_before jsonb; v_after jsonb; k text; lost text[] := '{}';
  v_kept_plans jsonb := '[]'::jsonb;
begin
  if not is_platform_admin() then
    raise exception 'only a platform admin may purge demo data'
      using errcode = 'PT403';
  end if;

  -- Every is_demo table, counted for this studio, BEFORE anything is deleted.
  v_before := demo_purge_census(p_studio_id);

  -- SAYS WHAT IT WILL DELETE AND WAITS, the same two-step as archive_record().
  -- There is no screen behind this — an operator runs it in a SQL console, and
  -- that is exactly the situation where nothing makes you stop and read.
  if not p_confirm then
    return jsonb_build_object(
      'ok', false,
      'requires_confirmation', true,
      'will_delete', demo_purge_preview(p_studio_id),
      'will_keep', v_before,
      'hint', 'Nothing has been deleted. Call purge_demo_data(studio_id, true) '
              'to go ahead. Every row under will_keep must still be there '
              'afterwards, and the function refuses to commit if it is not.');
  end if;

  -- ---- detach real children from demo parents -----------------------------
  -- A real occurrence generated against demo scaffolding is still a real class
  -- with real bookings on it. It loses the scaffolding and keeps everything
  -- that matters: the series is fiction, the class is not.
  --
  -- Every demo parent a real row can point at, not just the series. The series
  -- was the one that CASCADED; the others are ON DELETE SET NULL, which sounds
  -- harmless and is not — migration 058's delete guards count references, so a
  -- demo instructor still named by a real class cannot be deleted at all and
  -- the whole purge fails. Detaching first is what makes both work.
  update class_occurrences o
     set series_id = null
   where o.studio_id = p_studio_id and not o.is_demo
     and o.series_id in (select s.id from class_series s
                          where s.studio_id = p_studio_id and s.is_demo);

  -- The class survives without a teacher, which is Decision 17's open shift —
  -- an honest state the calendar hatches and the brief raises.
  update class_occurrences o
     set instructor_id = null, staffing = 'open'
   where o.studio_id = p_studio_id and not o.is_demo
     and o.instructor_id in (select i.id from instructors i
                              where i.studio_id = p_studio_id and i.is_demo);

  update class_occurrences o set room_id = null
   where o.studio_id = p_studio_id and not o.is_demo
     and o.room_id in (select r.id from rooms r
                        where r.studio_id = p_studio_id and r.is_demo);

  update class_occurrences o set class_type_id = null
   where o.studio_id = p_studio_id and not o.is_demo
     and o.class_type_id in (select ct.id from class_types ct
                              where ct.studio_id = p_studio_id and ct.is_demo);

  -- And a real series built on demo scaffolding, for the same reasons.
  update class_series cs
     set instructor_id = case when cs.instructor_id in (
             select i.id from instructors i where i.studio_id = p_studio_id and i.is_demo)
           then null else cs.instructor_id end,
         room_id = case when cs.room_id in (
             select r.id from rooms r where r.studio_id = p_studio_id and r.is_demo)
           then null else cs.room_id end,
         class_type_id = case when cs.class_type_id in (
             select ct.id from class_types ct where ct.studio_id = p_studio_id and ct.is_demo)
           then null else cs.class_type_id end
   where cs.studio_id = p_studio_id and not cs.is_demo;

  -- payments.member_id is ON DELETE SET NULL, so these do not cascade with the
  -- member and have to go first or they are orphaned rather than removed.
  delete from payments where studio_id = p_studio_id and is_demo;
  get diagnostics n_payments = row_count;

  -- Deleting the member cascades bookings, check_ins, credit_ledger and
  -- memberships — all of which belong to that demo member and are demo by
  -- construction. The census below is what proves it.
  delete from members where studio_id = p_studio_id and is_demo;
  get diagnostics n_members = row_count;

  delete from class_occurrences where studio_id = p_studio_id and is_demo;
  get diagnostics n_occ = row_count;
  delete from class_series where studio_id = p_studio_id and is_demo;

  -- A demo plan a REAL membership still sits on is not deletable without
  -- destroying that membership, and the rule is that nothing real goes. So it
  -- stays, and the result says which — the operator can decide whether to move
  -- that member onto a plan of their own. guard_plan_delete() would refuse the
  -- whole purge otherwise, which is the right instinct in the wrong place.
  select coalesce(jsonb_agg(p.name order by p.name), '[]'::jsonb) into v_kept_plans
    from membership_plans p
   where p.studio_id = p_studio_id and p.is_demo
     -- ANY surviving membership, not just an is_demo = false one. Demo members
     -- were deleted above and their memberships cascaded with them, so whatever
     -- is left belongs to a real person — including a membership that still
     -- carries the demo flag because its MEMBER was promoted by being edited.
     and exists (select 1 from memberships ms where ms.plan_id = p.id);

  delete from membership_plans p
   where p.studio_id = p_studio_id and p.is_demo
     and not exists (select 1 from memberships ms where ms.plan_id = p.id);
  get diagnostics n_plans = row_count;

  delete from instructors where studio_id = p_studio_id and is_demo;
  delete from rooms       where studio_id = p_studio_id and is_demo;
  delete from class_types where studio_id = p_studio_id and is_demo;
  get diagnostics n_misc = row_count;

  -- ---- and prove it took nothing else -------------------------------------
  v_after := demo_purge_census(p_studio_id);
  for k in select jsonb_object_keys(v_before) loop
    if (v_after ->> k)::int < (v_before ->> k)::int then
      lost := lost || format('%s (%s of %s)', k,
                             (v_before ->> k)::int - (v_after ->> k)::int,
                             (v_before ->> k)::int);
    end if;
  end loop;
  if array_length(lost, 1) > 0 then
    -- Rolls the whole purge back. A purge that cannot prove it took only demo
    -- rows must not commit.
    raise exception 'purge would have destroyed real data: %', array_to_string(lost, ', ')
      using errcode = 'PT409',
            hint = 'This is a cascade from a demo-flagged parent. Nothing has '
                   'been deleted. Report the table named above.';
  end if;

  -- A real member may have booked a demo class before the purge; their booking
  -- went with the occurrence, so any counter that survived is now wrong.
  update class_occurrences o
     set booked_count = coalesce((
           select count(*) from bookings b
            where b.occurrence_id = o.id
              and b.status in ('booked','attended','no_show')), 0),
         waitlist_count = coalesce((
           select count(*) from bookings b
            where b.occurrence_id = o.id and b.status = 'waitlisted'), 0)
   where o.studio_id = p_studio_id;

  perform recompute_member_stats(p_studio_id);

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (p_studio_id, auth.uid(), 'demo.purged', 'studios', p_studio_id, v_before, v_after);

  return jsonb_build_object(
    'members', n_members, 'payments', n_payments, 'occurrences', n_occ,
    'plans', n_plans, 'class_types', n_misc,
    'plans_kept_for_real_members', v_kept_plans,
    'real_rows_kept', v_after);
end $$;;

create or replace function purge_demo_data(p_studio_id uuid, p_confirm boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  n_members int; n_payments int; n_occ int; n_plans int; n_misc int;
  v_before jsonb; v_after jsonb; k text; lost text[] := '{}';
  v_kept_plans jsonb := '[]'::jsonb;
begin
  if not is_platform_admin() then
    raise exception 'only a platform admin may purge demo data'
      using errcode = 'PT403';
  end if;

  -- Every is_demo table, counted for this studio, BEFORE anything is deleted.
  v_before := demo_purge_census(p_studio_id);

  -- SAYS WHAT IT WILL DELETE AND WAITS, the same two-step as archive_record().
  -- There is no screen behind this — an operator runs it in a SQL console, and
  -- that is exactly the situation where nothing makes you stop and read.
  if not p_confirm then
    return jsonb_build_object(
      'ok', false,
      'requires_confirmation', true,
      'will_delete', demo_purge_preview(p_studio_id),
      'will_keep', v_before,
      'hint', 'Nothing has been deleted. Call purge_demo_data(studio_id, true) '
              'to go ahead. Every row under will_keep must still be there '
              'afterwards, and the function refuses to commit if it is not.');
  end if;

  -- ---- detach real children from demo parents -----------------------------
  -- A real occurrence generated against demo scaffolding is still a real class
  -- with real bookings on it. It loses the scaffolding and keeps everything
  -- that matters: the series is fiction, the class is not.
  --
  -- Every demo parent a real row can point at, not just the series. The series
  -- was the one that CASCADED; the others are ON DELETE SET NULL, which sounds
  -- harmless and is not — migration 058's delete guards count references, so a
  -- demo instructor still named by a real class cannot be deleted at all and
  -- the whole purge fails. Detaching first is what makes both work.
  update class_occurrences o
     set series_id = null
   where o.studio_id = p_studio_id and not o.is_demo
     and o.series_id in (select s.id from class_series s
                          where s.studio_id = p_studio_id and s.is_demo);

  -- The class survives without a teacher, which is Decision 17's open shift —
  -- an honest state the calendar hatches and the brief raises.
  update class_occurrences o
     set instructor_id = null, staffing = 'open'
   where o.studio_id = p_studio_id and not o.is_demo
     and o.instructor_id in (select i.id from instructors i
                              where i.studio_id = p_studio_id and i.is_demo);

  update class_occurrences o set room_id = null
   where o.studio_id = p_studio_id and not o.is_demo
     and o.room_id in (select r.id from rooms r
                        where r.studio_id = p_studio_id and r.is_demo);

  update class_occurrences o set class_type_id = null
   where o.studio_id = p_studio_id and not o.is_demo
     and o.class_type_id in (select ct.id from class_types ct
                              where ct.studio_id = p_studio_id and ct.is_demo);

  -- And a real series built on demo scaffolding, for the same reasons.
  update class_series cs
     set instructor_id = case when cs.instructor_id in (
             select i.id from instructors i where i.studio_id = p_studio_id and i.is_demo)
           then null else cs.instructor_id end,
         room_id = case when cs.room_id in (
             select r.id from rooms r where r.studio_id = p_studio_id and r.is_demo)
           then null else cs.room_id end,
         class_type_id = case when cs.class_type_id in (
             select ct.id from class_types ct where ct.studio_id = p_studio_id and ct.is_demo)
           then null else cs.class_type_id end
   where cs.studio_id = p_studio_id and not cs.is_demo;

  -- payments.member_id is ON DELETE SET NULL, so these do not cascade with the
  -- member and have to go first or they are orphaned rather than removed.
  delete from payments where studio_id = p_studio_id and is_demo;
  get diagnostics n_payments = row_count;

  -- Deleting the member cascades bookings, check_ins, credit_ledger and
  -- memberships — all of which belong to that demo member and are demo by
  -- construction. The census below is what proves it.
  delete from members where studio_id = p_studio_id and is_demo;
  get diagnostics n_members = row_count;

  delete from class_occurrences where studio_id = p_studio_id and is_demo;
  get diagnostics n_occ = row_count;
  delete from class_series where studio_id = p_studio_id and is_demo;

  -- A demo plan a REAL membership still sits on is not deletable without
  -- destroying that membership, and the rule is that nothing real goes. So it
  -- stays, and the result says which — the operator can decide whether to move
  -- that member onto a plan of their own. guard_plan_delete() would refuse the
  -- whole purge otherwise, which is the right instinct in the wrong place.
  select coalesce(jsonb_agg(p.name order by p.name), '[]'::jsonb) into v_kept_plans
    from membership_plans p
   where p.studio_id = p_studio_id and p.is_demo
     -- ANY surviving membership, not just an is_demo = false one. Demo members
     -- were deleted above and their memberships cascaded with them, so whatever
     -- is left belongs to a real person — including a membership that still
     -- carries the demo flag because its MEMBER was promoted by being edited.
     and exists (select 1 from memberships ms where ms.plan_id = p.id);

  delete from membership_plans p
   where p.studio_id = p_studio_id and p.is_demo
     and not exists (select 1 from memberships ms where ms.plan_id = p.id);
  get diagnostics n_plans = row_count;

  delete from instructors where studio_id = p_studio_id and is_demo;
  delete from rooms       where studio_id = p_studio_id and is_demo;
  delete from class_types where studio_id = p_studio_id and is_demo;
  get diagnostics n_misc = row_count;

  -- ---- and prove it took nothing else -------------------------------------
  v_after := demo_purge_census(p_studio_id);
  for k in select jsonb_object_keys(v_before) loop
    if (v_after ->> k)::int < (v_before ->> k)::int then
      lost := lost || format('%s (%s of %s)', k,
                             (v_before ->> k)::int - (v_after ->> k)::int,
                             (v_before ->> k)::int);
    end if;
  end loop;
  if array_length(lost, 1) > 0 then
    -- Rolls the whole purge back. A purge that cannot prove it took only demo
    -- rows must not commit.
    raise exception 'purge would have destroyed real data: %', array_to_string(lost, ', ')
      using errcode = 'PT409',
            hint = 'This is a cascade from a demo-flagged parent. Nothing has '
                   'been deleted. Report the table named above.';
  end if;

  -- A real member may have booked a demo class before the purge; their booking
  -- went with the occurrence, so any counter that survived is now wrong.
  update class_occurrences o
     set booked_count = coalesce((
           select count(*) from bookings b
            where b.occurrence_id = o.id
              and b.status in ('booked','attended','no_show')), 0),
         waitlist_count = coalesce((
           select count(*) from bookings b
            where b.occurrence_id = o.id and b.status = 'waitlisted'), 0)
   where o.studio_id = p_studio_id;

  perform recompute_member_stats(p_studio_id);

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (p_studio_id, auth.uid(), 'demo.purged', 'studios', p_studio_id, v_before, v_after);

  return jsonb_build_object(
    'members', n_members, 'payments', n_payments, 'occurrences', n_occ,
    'plans', n_plans, 'class_types', n_misc,
    'plans_kept_for_real_members', v_kept_plans,
    'real_rows_kept', v_after);
end $$;;

create or replace function demo_purge_census(p_studio_id uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'bookings',          (select count(*) from bookings          where studio_id = p_studio_id and not is_demo),
    'check_ins',         (select count(*) from check_ins         where studio_id = p_studio_id and not is_demo),
    'class_occurrences', (select count(*) from class_occurrences where studio_id = p_studio_id and not is_demo),
    'class_series',      (select count(*) from class_series      where studio_id = p_studio_id and not is_demo),
    'class_types',       (select count(*) from class_types       where studio_id = p_studio_id and not is_demo),
    'credit_ledger',     (select count(*) from credit_ledger     where studio_id = p_studio_id and not is_demo),
    'instructors',       (select count(*) from instructors       where studio_id = p_studio_id and not is_demo),
    'members',           (select count(*) from members           where studio_id = p_studio_id and not is_demo),
    'membership_plans',  (select count(*) from membership_plans  where studio_id = p_studio_id and not is_demo),
    'memberships',       (select count(*) from memberships       where studio_id = p_studio_id and not is_demo),
    'payments',          (select count(*) from payments          where studio_id = p_studio_id and not is_demo),
    'rooms',             (select count(*) from rooms             where studio_id = p_studio_id and not is_demo),
    -- No is_demo of its own, and it belongs entirely to a parent that has one —
    -- so "real" here means "belonging to a real instructor". A demo
    -- instructor's availability goes with them and is not a loss; a REAL
    -- instructor's disappearing is exactly what happened in production.
    'instructor_availability', (select count(*) from instructor_availability a
                                 join instructors i on i.id = a.instructor_id
                                where a.studio_id = p_studio_id and not i.is_demo))
  -- timeline_events is DELIBERATELY NOT COUNTED. It is derived — every row is
  -- rebuilt by rebuild_timeline_rows() from members, bookings, check_ins,
  -- payments and memberships, all of which ARE counted here. Counting the
  -- shadow as well as the thing casting it gives false alarms: a demo member
  -- promoted to real by editing keeps their identity but attended demo classes,
  -- so purging those classes correctly removes that attendance and the derived
  -- event with it. If none of the real SOURCE rows is lost, the timeline is
  -- right by construction; if one is, the census catches it there.
$$;

-- The census differs on hosted too — same draft, same cause. It is what the
-- purge counts before and after itself, so the two must be of one vintage.
revoke execute on function demo_purge_census(uuid)           from public, anon, authenticated;
grant  execute on function demo_purge_census(uuid)           to authenticated, service_role;
revoke execute on function demo_purge_preview(uuid)          from public, anon, authenticated;
grant  execute on function demo_purge_preview(uuid)          to authenticated, service_role;
revoke execute on function purge_demo_data(uuid, boolean)    from public, anon, authenticated;
grant  execute on function purge_demo_data(uuid, boolean)    to authenticated, service_role;
