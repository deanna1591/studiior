-- =============================================================================
-- Migration 062: purge_demo_data destroyed real data. This is the fix.
-- =============================================================================
-- WHAT HAPPENED, traced rather than guessed. The function itself only ever
-- deleted rows where is_demo is true — the damage came from a CASCADE off one
-- of those deletes:
--
--     class_occurrences.series_id -> class_series  ON DELETE CASCADE
--
-- `delete from class_series where is_demo` therefore took every occurrence of
-- that series with it, whatever the occurrence's own is_demo said. On
-- production the thirteen series were demo-flagged and migration 057's nightly
-- generator had since materialised 1,036 REAL occurrences against them, so the
-- purge reported deleting a few hundred demo classes and silently destroyed all
-- of them — and with them, by further cascade, every booking, check-in and
-- timeline event that hung off those classes.
--
-- Reproduced before fixing: 342 demo occurrences and 680 real ones, purge
-- reported 342, real ones remaining afterwards: 0.
--
-- Exactly the shape of migration 058's ON DELETE SET NULL finding — a delete
-- that succeeds while destroying more than it should, and says nothing.
--
-- THE RULE: purge_demo_data deletes exactly what is_demo marks. Nothing else,
-- ever, by any path. Two changes make that true rather than intended:
--
--   1. Real children are DETACHED from demo parents before the parent goes, so
--      no cascade can reach them.
--   2. The function COUNTS every non-demo row before and after and raises if a
--      single one has gone. That aborts the transaction and rolls the purge
--      back, so the next cascade nobody predicted fails loudly instead of
--      quietly. Fixing only (1) would fix the cascade we know about.
-- =============================================================================

-- DROPPED first. A default argument does not replace the old signature, it
-- creates an OVERLOAD, and every existing purge_demo_data(uuid) call then fails
-- as ambiguous — the trap migration 028 already hit. Dropping discards the ACL
-- too, so the grants are re-applied at the bottom.
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
end $$;

-- Every is_demo table, non-demo rows only, for one studio. Written as one
-- function so the before and after counts cannot drift apart, and so a table
-- gaining an is_demo column later is one line rather than two.
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

revoke execute on function demo_purge_census(uuid) from public, anon, authenticated;


revoke execute on function purge_demo_data(uuid, boolean) from public, anon, authenticated;
grant execute on function purge_demo_data(uuid, boolean) to authenticated, service_role;
