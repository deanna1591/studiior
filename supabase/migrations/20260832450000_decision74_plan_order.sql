-- Decision 74 — Plan display order and featured plans.
--
-- membership_plans already carries sort_order (int, default 0) and both the
-- staff Plans list and the member catalogue (/account/plan) already ORDER BY it
-- — it was simply never set meaningfully (every row 0, so the order fell back to
-- name). This migration makes it real:
--   * backfill sort_order = row_number() over (partition by studio_id order by
--     created_at) — so existing studios keep their current creation order until
--     an owner drags;
--   * a partial unique index on (studio_id, sort_order) among LIVE (non-archived)
--     plans — "unique per studio among live plans";
--   * a BEFORE INSERT trigger that appends a new plan at the end (sort_order left
--     0/null -> max+1 for that studio), so every inserter (the staff createPlan
--     action, the seed, the demo generator, tests) appends and never collides
--     with the unique index — the "new plans append to the end" rule lives in the
--     DB, not only in one action.
--
-- Two new columns: `featured boolean not null default false` and `badge text`
-- (max 24 chars). Everywhere plans are shown to members they are listed featured
-- first, then by sort_order, with featured plans highlighted (accent border +
-- badge chip). Public visibility, prices and buy links are unchanged.
--
-- reorder_plans(studio, plan_ids[]) is the one write path for order: authenticated
-- owner/manager, sets sort_order 1..n in the given order in two collision-free
-- passes (negate, then set), refuses an id from another studio and a set that is
-- not exactly the studio's live plans. Featured/badge are written through the
-- existing plans_manager_write RLS (a setPlanFeature action), owner/manager.
--
-- NO reader re-issue: no anon function and no bootstrap enumerates plan columns
-- (the member catalogue and the staff list read membership_plans directly under
-- RLS; the public embed lists classes via public_schedule, not plans). Anon stays
-- EXACTLY THIRTEEN.
--
-- creates: reorder_plans(uuid, uuid[]), tg_plan_append_sort_order()

-- ---- Columns ----------------------------------------------------------------
alter table membership_plans
  add column if not exists featured boolean not null default false,
  add column if not exists badge text;

alter table membership_plans
  add constraint membership_plans_badge_len check (badge is null or char_length(badge) <= 24);

-- ---- Backfill sort_order by created_at (per studio) --------------------------
-- All plans get a distinct rank within their studio, so the live subset is
-- distinct and the partial unique index below builds. On a fresh db reset this
-- touches zero rows (the seed runs after migrations); on hosted it ranks the
-- existing plans by creation date — their current implicit order.
with ranked as (
  select id, row_number() over (partition by studio_id order by created_at, id) as rn
    from membership_plans
)
update membership_plans p
   set sort_order = ranked.rn
  from ranked
 where ranked.id = p.id;

-- ---- Unique per studio among LIVE plans -------------------------------------
create unique index if not exists membership_plans_studio_sort_live
  on membership_plans (studio_id, sort_order)
  where status <> 'archived';

-- ---- Append a new plan at the end -------------------------------------------
-- Every inserter that does not choose a sort_order (0 or null) gets max+1 for
-- its studio, so a new plan lands last and never collides with the unique index.
-- reorder_plans uses UPDATE, so this INSERT trigger never fights it.
create or replace function tg_plan_append_sort_order()
returns trigger language plpgsql as $$
begin
  if new.sort_order is null or new.sort_order = 0 then
    select coalesce(max(sort_order), 0) + 1 into new.sort_order
      from membership_plans where studio_id = new.studio_id;
  end if;
  return new;
end $$;
-- A trigger function is invoked by the trigger, not called by a client: callable
-- by nobody (the convention for trigger functions here).
revoke execute on function tg_plan_append_sort_order() from public, anon, authenticated, service_role;

drop trigger if exists plan_append_sort_order on membership_plans;
create trigger plan_append_sort_order
  before insert on membership_plans
  for each row execute function tg_plan_append_sort_order();

-- ---- reorder_plans ----------------------------------------------------------
create or replace function reorder_plans(p_studio_id uuid, p_plan_ids uuid[])
returns void language plpgsql security definer set search_path = public as $$
declare v_live int; v_given int; v_foreign int;
begin
  -- Owner/manager of this studio only. Front desk and instructors are refused
  -- here, before any write (plans_manager_write would refuse them too, but this
  -- function is SECURITY DEFINER, so the guard is the boundary).
  if not is_manager_up(p_studio_id) then
    raise exception 'only owners and managers change plan order' using errcode = 'PT403';
  end if;

  -- Every id must be a plan of THIS studio.
  select count(*) into v_foreign
    from unnest(p_plan_ids) as u(id)
   where not exists (select 1 from membership_plans mp
                      where mp.id = u.id and mp.studio_id = p_studio_id);
  if v_foreign > 0 then
    raise exception 'plan list contains % id(s) from another studio', v_foreign using errcode = 'PT400';
  end if;

  -- The list must be exactly the studio's live (non-archived) plans — a clean
  -- permutation, so 1..n never collides with a live plan left out of the list.
  select count(*) into v_live from membership_plans
   where studio_id = p_studio_id and status <> 'archived';
  v_given := coalesce(array_length(p_plan_ids, 1), 0);
  if v_given <> v_live then
    raise exception 'plan list has % ids but the studio has % live plans', v_given, v_live using errcode = 'PT400';
  end if;

  -- Two collision-free passes under the partial unique index: negate to a range
  -- no live plan holds, then set the finals. A single UPDATE to 1..n would trip
  -- the index mid-statement (it is checked per row, not deferred). ordinality
  -- `pos` is 1..n in the array's own order.
  update membership_plans p set sort_order = -u.pos
    from unnest(p_plan_ids) with ordinality as u(id, pos)
   where u.id = p.id and p.studio_id = p_studio_id;

  update membership_plans p set sort_order = u.pos
    from unnest(p_plan_ids) with ordinality as u(id, pos)
   where u.id = p.id and p.studio_id = p_studio_id;
end $$;
revoke execute on function reorder_plans(uuid, uuid[]) from public, anon;
grant  execute on function reorder_plans(uuid, uuid[]) to authenticated, service_role;

-- =============================================================================
-- Anon surface stays EXACTLY THIRTEEN (reorder_plans is authenticated, the
-- trigger function is reachable by no client role).
-- =============================================================================
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then
    raise exception 'anon surface is % functions, expected exactly 13', n;
  end if;
end $$;
