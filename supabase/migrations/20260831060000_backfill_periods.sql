-- =============================================================================
-- Migration 096 — backfill the periods migration 095 only fixed going forward
--
-- 095 taught activate_purchase() to write a billing period. It said nothing
-- about the memberships already sold, and Reform Collective's own active
-- membership still had three nulls in it the next morning — repaired by hand,
-- which is exactly the repair the next studio would also have to make.
--
-- A fix that only applies to rows created after it is half a fix. The same
-- shape as migration 057's backfill, which took hosted from 403 occurrences to
-- 1,036: the function was right and the data was still wrong.
--
-- ONLY where all three are null, and only for recurring plans with no Stripe
-- subscription. A Connect membership's period is Stripe's to state and a
-- partially-filled row is somebody's deliberate edit; neither is ours to
-- overwrite.
-- =============================================================================
do $$
declare n int;
begin
  with fixed as (
    update memberships ms
       set current_period_start = coalesce(ms.current_period_start, ms.starts_on::timestamptz),
           current_period_end   = plan_period_end(ms.plan_id,
                                    coalesce(ms.current_period_start, ms.starts_on::timestamptz)),
           renews_on            = (plan_period_end(ms.plan_id,
                                    coalesce(ms.current_period_start, ms.starts_on::timestamptz))
                                   at time zone s.timezone)::date
      from membership_plans pl, studios s
     where pl.id = ms.plan_id and s.id = ms.studio_id
       and pl.type = 'recurring'
       and ms.stripe_subscription_id is null
       and ms.status in ('active', 'past_due', 'frozen')
       and ms.current_period_start is null
       and ms.current_period_end is null
       and ms.renews_on is null
    returning ms.id, ms.studio_id, ms.current_period_end)
  insert into membership_events (studio_id, membership_id, type, metadata)
  select f.studio_id, f.id, 'period_backfilled',
         jsonb_build_object('period_end', f.current_period_end,
                            'note', 'Migration 096. Sold before activation wrote a period.')
    from fixed f;
  get diagnostics n = row_count;
  raise notice 'migration 096: % membership(s) given the period they were sold with', n;
end $$;

-- A backfilled period can already be in the past — a membership sold three
-- months ago gets a period that ended two months ago, which is the truth and
-- not a problem to hide. The nightly sweep will mark it past_due on its next
-- run and it will appear on /due, where somebody can decide what to do about
-- it. Marking them here would be the same decision taken silently at midnight
-- by a migration.
