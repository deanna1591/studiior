-- =============================================================================
-- Migration 039: the setup checklist stops taking the studio's word for Stripe
-- =============================================================================
-- `connect_stripe` was the only item ticked from studio_settings.setup_progress
-- rather than derived from live data — the escape hatch on the stub screen,
-- which existed because there was nothing real to connect to. There is now, and
-- a checklist that can be ticked without connecting anything is exactly the
-- staleness CLAUDE.md says this checklist avoids.
--
-- The stored flag is left where it is rather than deleted: it is a historical
-- record of somebody pressing a button, and nothing reads it any more.
--
-- Replaced from the LIVE definition.
-- =============================================================================

create or replace function public.studio_setup_state(p_studio_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with prog as (
    select coalesce(setup_progress, '{}'::jsonb) as p
      from studio_settings where studio_id = p_studio_id
  ),
  facts(key, done) as (
    values
      ('rooms',        exists (select 1 from rooms          where studio_id = p_studio_id and status = 'active')),
      ('class_types',  exists (select 1 from class_types    where studio_id = p_studio_id and status = 'active')),
      ('instructors',  exists (select 1 from instructors    where studio_id = p_studio_id and status = 'active')),
      ('plans',        exists (select 1 from membership_plans where studio_id = p_studio_id and status = 'active')),
      ('schedule',     exists (select 1 from class_occurrences where studio_id = p_studio_id)),
      ('staff',       (select count(*) from studio_staff where studio_id = p_studio_id and status = 'active') > 1),
      -- Nothing to derive until Stripe Connect is wired; it is a stored flag.
      ('connect_stripe',
       (select stripe_account_id is not null from studios where id = p_studio_id))
  )
  select jsonb_object_agg(
           f.key,
           jsonb_build_object(
             -- coalesce before ?: on a fresh studio setup_progress is '{}',
             -- so p -> 'done' is NULL and NULL ? key is NULL, not false — the
             -- checklist would render "unknown" rather than "not done".
             -- connect_stripe used to read a stored flag set by "I've done this"
             -- on the stub screen, which was the one item in this checklist that
             -- could go stale — a studio could tick it and never connect
             -- anything. Now that Connect is real it is derived like every other
             -- item: the tick IS a connected account id.
             'done', f.done,
             'dismissed', (select coalesce(p -> 'dismissed', '{}'::jsonb) ? f.key from prog)
           ))
    from facts f
   where exists (select 1 from studio_staff s
                  where s.studio_id = p_studio_id and s.user_id = auth.uid()
                    and s.status = 'active' and s.role in ('owner','manager'))
      or auth.uid() is null;
$function$

;
