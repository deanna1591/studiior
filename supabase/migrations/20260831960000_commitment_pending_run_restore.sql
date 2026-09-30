-- Fix-forward: restore commitment_pending's _run calls.
--
-- Migration 950000 (opening hours) re-issued move_occurrence by copying a range
-- from 20260831170000 that overran into commitment_pending — 170000's version
-- predates migration 187's guarded-caller fix, so it silently reverted
-- commitment_pending to call the GUARDED occurrence_guarantee / occurrence_is_adjacent
-- instead of their _run twins (caught by check-guarded-callers.sh). Not a live bug
-- (its callers are the flex sweep / flex_pending, which run in a service context
-- where the guard passes), but it is the fragile pattern 187 removed. Re-issued
-- here VERBATIM from 187's (920000) body, which calls the _run twins.

CREATE OR REPLACE FUNCTION public.commitment_pending(p_studio_id uuid)
 RETURNS TABLE(occ_id uuid, occ_name text, starts_at timestamp with time zone, local_when text, tier guarantee_tier, booked integer, minimum integer, short_by integer, due_at timestamp with time zone, cutoff_shape text, past_due boolean, instructor_id uuid, is_adjacent boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_tz text; s studio_settings%rowtype;
begin
  if not coalesce(is_manager_up(p_studio_id), false) and not is_service_context() then
    raise exception 'only owners and managers see this' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  if v_tz is null then raise exception 'no such studio' using errcode = 'PT404'; end if;
  select * into s from studio_settings where studio_id = p_studio_id;
  -- Either switch puts classes in scope; occurrence_guarantee_run() decides which
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
         o.instructor_id, occurrence_is_adjacent_run(o.id)
    from class_occurrences o
    cross join lateral occurrence_guarantee_run(o.id) g
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
     -- Decision 25: a draft month is not decided. Nobody can book a class in
     -- it, so a flex class evaluated there would be cancelled for want of the
     -- bookings it was never allowed to take.
     and occurrence_published(o.id)
   order by o.starts_at;
end $function$

;

do $$
declare v_n int;
begin
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and has_function_privilege('anon', p.oid, 'execute');
  if v_n <> 12 then
    raise exception 'anon surface is %, expected exactly twelve', v_n;
  end if;
end $$;

