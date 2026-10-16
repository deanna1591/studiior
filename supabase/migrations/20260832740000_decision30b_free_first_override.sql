-- =============================================================================
-- Decision 30 amendment (b) — per-class "Open to first-timers" override.
-- =============================================================================
-- The studio-wide core-only rule and the per-series switch can only NARROW
-- where free first classes go. A studio needs to open a specific class — a flex
-- slot that already runs, a one-off, a launch-week class — without changing its
-- tier or its series. class_occurrences.free_first_override: null = the studio
-- rules (today); 'open' = accepts free first-timers regardless of core-only and
-- the series switch (the seat cap, peak and provisional rules still apply);
-- 'closed' = never. Read in both the member picker list
-- (free_first_eligible_classes_run) and the belt (book_first_free).
-- No new setting, no new anon RPC — anon stays EXACTLY THIRTEEN.
-- =============================================================================

-- creates: set_free_first_override(uuid, text), effective_free_first(uuid)
-- re-issues: free_first_eligible_classes_run(uuid, uuid, int), book_first_free(uuid)

alter table class_occurrences
  add column if not exists free_first_override text
    check (free_first_override in ('open','closed'));
comment on column class_occurrences.free_first_override is
  'Decision 30 amendment (b). null = studio rules; open = accepts free first-timers regardless of core-only and the series switch (seat cap, peak and provisional still apply); closed = never.';

-- -----------------------------------------------------------------------------
-- 1. free_first_eligible_classes_run — re-issued (from 20260832120000) with the
--    override: 'closed' excluded, 'open' skips core_only + the series switch.
-- -----------------------------------------------------------------------------
create or replace function free_first_eligible_classes_run(
  p_studio_id uuid, p_member_id uuid, p_min_headcount int default 0)
returns table(occurrence_id uuid, name text, starts_at timestamptz, duration_min int,
              room_name text, instructor_first text, headcount int, capacity int,
              free_bookable boolean)
language plpgsql stable security definer set search_path = public as $$
declare st studio_settings%rowtype; v_elig jsonb;
begin
  select * into st from studio_settings where studio_id = p_studio_id;
  v_elig := free_first_eligibility(p_studio_id, p_member_id);
  if not coalesce((v_elig ->> 'ok')::boolean, false) then return; end if;

  return query
  select o.id, o.name, o.starts_at,
         coalesce(ct.duration_minutes, 0),
         (select r.name from rooms r where r.id = o.room_id),
         (select split_part(i.display_name, ' ', 1) from instructors i where i.id = o.instructor_id),
         coalesce(o.booked_count, 0), o.capacity,
         ( o.capacity - occurrence_seats_taken(o.id) - occurrence_seats_held(o.id) >= 1
           and (st.free_first_seats_per_class is null
                or (select count(*) from bookings b
                     where b.occurrence_id = o.id and b.status = 'booked'
                       and b.payment_source = 'comp'
                       and exists (select 1 from guest_passes gp
                                    where gp.guest_booking_id = b.id and gp.host_member_id is null))
                    < st.free_first_seats_per_class) )
    from class_occurrences o
    left join class_series ser on ser.id = o.series_id
    left join class_types  ct  on ct.id  = o.class_type_id
   where o.studio_id = p_studio_id
     and o.status = 'scheduled'
     and o.starts_at > now()
     and o.starts_at <= now() + make_interval(days => coalesce(st.booking_window_days, 30))
     and o.starts_at >= now() + make_interval(mins => coalesce(st.booking_cutoff_minutes, 0))
     -- Decision 48 (and scheduled + published) for THIS member.
     and occurrence_member_visible_run(o.id, p_member_id)
     -- Decision 30 amendment (b): a per-class override. 'closed' → never;
     -- 'open' → skip core_only and the series switch (seat cap and peak still
     -- apply below); null → the studio rules.
     and o.free_first_override is distinct from 'closed'
     and (o.free_first_override = 'open' or (
            -- core_only: the CONFIGURED tier (the studio's intent), not demoted.
            (not coalesce(st.free_first_core_only, false)
             or coalesce(o.guarantee_tier, case when o.flex then 'flex'::guarantee_tier end,
                         ser.guarantee_tier, case when ser.flex then 'flex'::guarantee_tier end,
                         'core'::guarantee_tier) = 'core')
            -- the series toggle (a one-off has no series and is allowed)
            and (o.series_id is null or coalesce(ser.free_first_allowed, true))
          ))
     -- peak, if the studio keeps free classes out of its peak hours
     and not (not coalesce(st.free_first_peak_allowed, true) and occurrence_is_peak(o.id))
     and coalesce(o.booked_count, 0) >= p_min_headcount
   order by coalesce(o.booked_count, 0) desc, o.starts_at;
end $$;

-- -----------------------------------------------------------------------------
-- 2. book_first_free — re-issued (from 20260832550000) with the override: a
--    'closed' class is refused (free_first_closed_here); 'open' skips the
--    core_only and series gates (peak, seat cap and provisional still apply).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.book_first_free(p_occurrence_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_occ    class_occurrences%rowtype;
  v_member members%rowtype;
  v_set    studio_settings%rowtype;
  v_ser    class_series%rowtype;
  v_cfg_tier guarantee_tier;
  v_tz     text;
  v_elig   jsonb;
  v_free   int;
  v_head   int;
  v_cut    timestamptz;
  v_prov   boolean;
  v_booking uuid;
  v_pass    uuid;
begin
  select * into v_occ from class_occurrences where id = p_occurrence_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;

  select * into v_member from members
   where studio_id = v_occ.studio_id and user_id = auth.uid();
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_authorised'); end if;

  v_elig := free_first_eligibility(v_occ.studio_id, v_member.id);
  if not (v_elig ->> 'ok')::boolean then return v_elig; end if;

  select * into v_set from studio_settings where studio_id = v_occ.studio_id;
  select timezone into v_tz from studios where id = v_occ.studio_id;

  if v_occ.status <> 'scheduled' then return jsonb_build_object('ok', false, 'reason', 'class_not_bookable'); end if;
  if v_occ.starts_at <= now() then return jsonb_build_object('ok', false, 'reason', 'class_in_past'); end if;
  if not month_published(v_occ.studio_id, v_occ.starts_at) then
    return jsonb_build_object('ok', false, 'reason', 'month_not_published');
  end if;
  if studio_hides_unstaffed(v_occ.studio_id) and v_occ.staffing <> 'assigned' then
    return jsonb_build_object('ok', false, 'reason', 'not_staffed_yet');
  end if;
  if v_occ.starts_at > now() + make_interval(days => coalesce(v_set.booking_window_days, 30)) then
    return jsonb_build_object('ok', false, 'reason', 'outside_booking_window');
  end if;
  if v_occ.starts_at < now() + make_interval(mins => coalesce(v_set.booking_cutoff_minutes, 0)) then
    return jsonb_build_object('ok', false, 'reason', 'past_booking_cutoff');
  end if;

  -- Decision 30 amendment (b): a per-class override. 'closed' = never, whatever
  -- the rules say; 'open' skips core_only and the series switch below (seat cap
  -- and peak still apply).
  if v_occ.free_first_override = 'closed' then
    return jsonb_build_object('ok', false, 'reason', 'free_first_closed_here');
  end if;

  if not coalesce(v_set.free_first_peak_allowed, true) and occurrence_is_peak(p_occurrence_id) then
    return jsonb_build_object('ok', false, 'reason', 'peak_not_allowed');
  end if;

  if v_occ.series_id is not null then
    select * into v_ser from class_series where id = v_occ.series_id;
  end if;
  v_cfg_tier := coalesce(v_occ.guarantee_tier,
                         case when v_occ.flex then 'flex'::guarantee_tier end,
                         v_ser.guarantee_tier,
                         case when v_ser.flex then 'flex'::guarantee_tier end,
                         'core'::guarantee_tier);
  if coalesce(v_set.free_first_core_only, false) and v_cfg_tier <> 'core'
     and v_occ.free_first_override is distinct from 'open' then
    return jsonb_build_object('ok', false, 'reason', 'flex_not_allowed');
  end if;
  if v_occ.series_id is not null
     and not coalesce(v_ser.free_first_allowed, true)
     and v_occ.free_first_override is distinct from 'open' then
    return jsonb_build_object('ok', false, 'reason', 'not_trial_class');
  end if;
  if v_set.free_first_seats_per_class is not null
     and (select count(*) from bookings b
           where b.occurrence_id = p_occurrence_id and b.status = 'booked'
             and b.payment_source = 'comp'
             and exists (select 1 from guest_passes gp
                          where gp.guest_booking_id = b.id and gp.host_member_id is null))
         >= v_set.free_first_seats_per_class then
    return jsonb_build_object('ok', false, 'reason', 'free_seats_full');
  end if;

  v_free := v_occ.capacity - occurrence_seats_taken(p_occurrence_id)
                           - occurrence_seats_held(p_occurrence_id);
  if v_free < 1 then return jsonb_build_object('ok', false, 'reason', 'class_full'); end if;

  v_head := occurrence_seats_taken(p_occurrence_id) + 1;
  select cutoff_at into v_cut from occurrence_guarantee_run(p_occurrence_id);
  v_prov := v_set.free_first_confirm_at is not null
            and v_cut is not null
            and v_head < v_set.free_first_confirm_at;

  insert into bookings (studio_id, occurrence_id, member_id, status, source,
                        payment_source, provisional, confirmed_at)
  values (v_occ.studio_id, p_occurrence_id, v_member.id, 'booked', 'member', 'comp',
          v_prov, case when v_prov then null else now() end)
  returning id into v_booking;
  update class_occurrences set booked_count = booked_count + 1 where id = p_occurrence_id;

  -- The shared once-ever ledger row. Decision 78: a no-show member's rebook
  -- REUSES this row (upsert on the once-ever index) rather than inserting a
  -- second — the index and its hard guarantee are untouched; the member's comp
  -- no_show bookings are what count the attempts.
  insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email,
                            occurrence_id, guest_booking_id, status, waiver_signed_at)
  values (v_occ.studio_id, null, v_member.id, lower(btrim(v_member.email)),
          p_occurrence_id, v_booking,
          case when v_member.waiver_signed_at is not null then 'confirmed' else 'invited' end,
          v_member.waiver_signed_at)
  on conflict (studio_id, normalize_email_key(guest_email)) do update
    set host_member_id   = excluded.host_member_id,
        guest_member_id  = excluded.guest_member_id,
        occurrence_id    = excluded.occurrence_id,
        guest_booking_id = excluded.guest_booking_id,
        status           = excluded.status,
        waiver_signed_at = excluded.waiver_signed_at
  returning id into v_pass;

  perform confirm_provisional_seats_run(p_occurrence_id);

  return jsonb_build_object('ok', true, 'booking_id', v_booking,
    'guest_pass_id', v_pass, 'provisional', v_prov);
end $function$;
revoke execute on function book_first_free(uuid) from public, anon;
grant  execute on function book_first_free(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 3. effective_free_first — the true per-class state for the roster checkbox.
--    rules_open is the core_only + series dimensions (peak/cap are situational,
--    enforced at booking); effective_open folds in the override and the switch.
-- -----------------------------------------------------------------------------
create or replace function effective_free_first(p_occurrence_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare o class_occurrences%rowtype; ser class_series%rowtype; st studio_settings%rowtype;
  v_tier guarantee_tier; v_rules_open boolean; v_reason text; v_eff boolean;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not coalesce(is_desk_up(o.studio_id), false) and not is_service_context() then
    raise exception 'only studio staff see this' using errcode = 'PT403';
  end if;
  select * into st from studio_settings where studio_id = o.studio_id;
  if o.series_id is not null then select * into ser from class_series where id = o.series_id; end if;
  v_tier := coalesce(o.guarantee_tier, case when o.flex then 'flex'::guarantee_tier end,
                     ser.guarantee_tier, case when ser.flex then 'flex'::guarantee_tier end,
                     'core'::guarantee_tier);
  v_rules_open := coalesce(st.free_first_class_enabled, false)
    and (not coalesce(st.free_first_core_only, false) or v_tier = 'core')
    and (o.series_id is null or coalesce(ser.free_first_allowed, true));
  v_reason := case
    when not coalesce(st.free_first_class_enabled, false) then 'disabled'
    when coalesce(st.free_first_core_only, false) and v_tier <> 'core' then 'core_only'
    when o.series_id is not null and not coalesce(ser.free_first_allowed, true) then 'series'
    else null end;
  v_eff := coalesce(st.free_first_class_enabled, false)
           and o.free_first_override is distinct from 'closed'
           and (coalesce(o.free_first_override = 'open', false) or v_rules_open);
  return jsonb_build_object(
    'override', o.free_first_override,
    'rules_open', v_rules_open,
    'effective_open', v_eff,
    'why', case when o.free_first_override is not null then 'override' else 'rules' end,
    'reason', v_reason,
    'tier', v_tier::text,
    'enabled', coalesce(st.free_first_class_enabled, false));
end $$;
revoke execute on function effective_free_first(uuid) from public, anon;
grant  execute on function effective_free_first(uuid) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 4. set_free_first_override — front desk and up set it from the roster page.
--    null clears (follow studio rules). Refusals as reasons. Audited.
-- -----------------------------------------------------------------------------
create or replace function set_free_first_override(p_occurrence_id uuid, p_value text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare o class_occurrences%rowtype;
begin
  if p_value is not null and p_value not in ('open','closed') then
    raise exception 'free_first_override must be open, closed or null' using errcode = 'PT400';
  end if;
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no_such_class'); end if;
  if not coalesce(is_desk_up(o.studio_id), false) then
    raise exception 'only studio staff set this' using errcode = 'PT403';
  end if;
  if o.status = 'cancelled' then return jsonb_build_object('ok', false, 'reason', 'cancelled'); end if;
  if o.starts_at <= now() then return jsonb_build_object('ok', false, 'reason', 'past_class'); end if;

  update class_occurrences set free_first_override = p_value, updated_at = now()
   where id = p_occurrence_id;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (o.studio_id, auth.uid(), 'occurrence.free_first_override', 'class_occurrences', p_occurrence_id,
          jsonb_build_object('override', p_value));

  return effective_free_first(p_occurrence_id) || jsonb_build_object('ok', true);
end $$;
revoke execute on function set_free_first_override(uuid, text) from public, anon;
grant  execute on function set_free_first_override(uuid, text) to authenticated, service_role;

-- anon surface unchanged.
do $$ declare n int; begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where ns.nspname='public' and p.prokind='f'
     and has_function_privilege('anon', p.oid, 'execute') and p.proname not like 'expect_%';
  if n <> 13 then raise exception 'anon surface drifted: expected 13, got %', n; end if;
end $$;
