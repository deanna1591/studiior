-- =============================================================================
-- 088  set_series_guarantee() has raised on every call since migration 081.
-- =============================================================================
-- 081 renamed `class_occurrences.flex_confirmed_at` to `committed_at` and
-- re-issued schedule_range(), set_series_flex(), flex_pending() and the sweep.
-- It did NOT re-issue set_series_guarantee(), which 080 had just created against
-- the old name — and 080's own comment even says "081 renames this to
-- committed_at", which is as close to writing the bug down as it is possible to
-- get without fixing it.
--
--   ERROR:  column o.flex_confirmed_at does not exist
--
-- Every call since. NOTHING CAUGHT IT, and the reason is the thing this pass was
-- looking for: `guarantee_tier` had no control anywhere, so the only writer of
-- it was never called by anything. A column with no UI hides a broken writer as
-- well as an unreachable setting — the audit found the setting, and the setting
-- found the bug.
--
-- No test called it either. guarantee_pay_test.sql sets tiers by inserting rows
-- with the column already populated, which exercises the READ path and not this.
-- =============================================================================

create or replace function set_series_guarantee(p_series_id uuid, p_tier guarantee_tier, p_min_bookings integer DEFAULT NULL::integer, p_core_cutoff_hours integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare ser class_series%rowtype; n int;
begin
  select * into ser from class_series where id = p_series_id;
  if not found then raise exception 'no such series' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(ser.studio_id), false) then
    raise exception 'only owners and managers set a guarantee' using errcode = 'PT403';
  end if;
  if p_min_bookings is not null and p_min_bookings < 0 then
    raise exception 'a minimum cannot be negative' using errcode = 'PT422';
  end if;

  update class_series
     set guarantee_tier   = p_tier,
         flex             = (p_tier = 'flex'),   -- kept in step, never consulted separately
         minimum_bookings = case when p_tier = 'flex'
                                 then coalesce(p_min_bookings, minimum_bookings)
                                 else minimum_bookings end,
         core_min_bookings = case when p_tier = 'core'
                                  then coalesce(p_min_bookings, core_min_bookings)
                                  else core_min_bookings end,
         core_cutoff_hours = coalesce(p_core_cutoff_hours, core_cutoff_hours),
         updated_at = now()
   where id = p_series_id;

  update class_occurrences o
     set guarantee_tier = p_tier,
         flex           = (p_tier = 'flex'),
         minimum_bookings = case when p_tier = 'flex'
                                 then coalesce(p_min_bookings, o.minimum_bookings)
                                 else o.minimum_bookings end,
         core_min_bookings = case when p_tier = 'core'
                                  then coalesce(p_min_bookings, o.core_min_bookings)
                                  else o.core_min_bookings end,
         updated_at = now()
   where o.series_id = p_series_id
     and o.starts_at > now()
     and o.status = 'scheduled'
     and o.committed_at is null;   -- a committed class is settled.
                                        -- 081 renames this to committed_at.
  get diagnostics n = row_count;

  return jsonb_build_object('ok', true, 'tier', p_tier, 'occurrences_updated', n);
end $function$;

revoke execute on function set_series_guarantee(uuid, guarantee_tier, int, int)
  from public, anon, authenticated;
grant execute on function set_series_guarantee(uuid, guarantee_tier, int, int) to authenticated;
