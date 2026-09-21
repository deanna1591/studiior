-- =============================================================================
-- Decision 35, Part A — member self check-in at the door, with a geofence and
-- the waiver enforced at EVERY door.
-- =============================================================================
--  * locations gains coordinates + radius + accuracy cap + require-location.
--  * check_ins gains distance_m + accuracy_m (the raw lat/lng are NEVER stored —
--    they compute the distance and are discarded; §14).
--  * self_check_in(booking, lat, lng, accuracy) — SECURITY DEFINER so no member
--    INSERT policy is added to check_ins; the function writes as its owner.
--  * The member waiver-at-the-door: enforce_guest_waiver now refuses a MEMBER
--    (self / desk / instructor) whose signature is missing or on a stale required
--    version, exactly as it refuses a guest — PT422, pointing at their phone,
--    with the desk paper path (record_document) as the fallback. Guarded so a
--    studio with no published version (the default require_waiver=true state) is
--    unaffected, and an IMPORT row is never gated.
--  * import_commit switches its attendance method 'staff' -> 'import', so 'staff'
--    now means a human at the desk (existing imported rows keep 'staff').
-- =============================================================================

-- --- locations: the geofence lives on the physical place -----------------------
alter table locations
  add column latitude                       double precision,
  add column longitude                      double precision,
  add column self_checkin_radius_m          int     not null default 200
    check (self_checkin_radius_m >= 0),
  add column self_checkin_accuracy_cap_m     int     not null default 150
    check (self_checkin_accuracy_cap_m >= 0),
  add column self_checkin_requires_location  boolean not null default true,
  add constraint locations_latlng_together
    check ((latitude is null) = (longitude is null));

-- --- check_ins: the distance and the accuracy, never the coordinates -----------
alter table check_ins
  add column distance_m int,
  add column accuracy_m int;

-- --- haversine, metres. Pure. --------------------------------------------------
create function earth_distance_m(lat1 double precision, lng1 double precision,
                                 lat2 double precision, lng2 double precision)
returns double precision language sql immutable as $$
  select 2 * 6371000 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) *
    power(sin(radians(lng2 - lng1) / 2), 2)
  ));
$$;
-- Closed by default (PostgreSQL grants EXECUTE to PUBLIC otherwise, and anon is
-- a member of PUBLIC — that is the extra anon surface if this is not revoked).
revoke execute on function earth_distance_m(double precision, double precision, double precision, double precision) from public, anon;

-- --- the one waiver-at-the-door predicate, shared by the trigger and the door --
-- True when the member satisfies the studio's waiver requirement: the switch is
-- off, OR nothing has been published to sign, OR they are signed and not on a
-- stale required version. Mirrors book_class rule 2.1.4 exactly, so the booking
-- gate and the door agree. Internal — closed to clients (the grant is the
-- boundary; it steps over RLS on members/waiver tables).
create function member_waiver_current(p_member_id uuid, p_studio_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select case
    when not coalesce((select require_waiver from studio_settings where studio_id = p_studio_id), false)
      then true
    when not exists (select 1 from waiver_versions where studio_id = p_studio_id)
      then true
    when (select waiver_signed_at from members where id = p_member_id) is null
      then false
    when exists (
      select 1 from waiver_versions wv
       where wv.studio_id = p_studio_id and wv.requires_resign
         and wv.created_at = (select max(created_at) from waiver_versions where studio_id = p_studio_id)
         and not exists (select 1 from waiver_signatures ws
                          where ws.member_id = p_member_id and ws.version_id = wv.id))
      then false
    else true
  end;
$$;
revoke execute on function member_waiver_current(uuid, uuid) from public, anon, authenticated;

-- --- enforce_guest_waiver: now every door, member as well as guest -------------
-- Re-issued from migration 165 (newest, via scripts/newest-definition.sh). The
-- two guest branches are unchanged (guest-specific messages); a member branch is
-- added AFTER them, so a guest keeps its own wording and a non-guest member is
-- refused with the phone sentence. Skipped for import rows (importing history
-- must not be waiver-gated) and for a studio with no published version.
create or replace function enforce_guest_waiver() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- Unsigned guest — the original gate.
  if exists (
    select 1 from guest_passes gp
      join members m on m.id = gp.guest_member_id
     where gp.guest_member_id = new.member_id
       and gp.occurrence_id  = new.occurrence_id
       and m.waiver_signed_at is null
  ) then
    raise exception 'this guest has not signed the waiver yet'
      using errcode = 'PT422',
            hint = 'Ask them to sign it in the app, then check them in.';
  end if;

  -- Guest signed only an OLDER required version.
  if exists (
    select 1 from guest_passes gp
     where gp.guest_member_id = new.member_id
       and gp.occurrence_id  = new.occurrence_id
       and exists (
         select 1 from waiver_versions wv
          where wv.studio_id = gp.studio_id
            and wv.requires_resign
            and wv.created_at = (select max(created_at) from waiver_versions
                                  where studio_id = gp.studio_id)
            and not exists (select 1 from waiver_signatures ws
                             where ws.member_id = new.member_id and ws.version_id = wv.id))
  ) then
    raise exception 'this guest signed an older version of the waiver'
      using errcode = 'PT422',
            hint = 'Ask them to sign the current version in the app, then check them in.';
  end if;

  -- Decision 35: a MEMBER at ANY door (self, desk, instructor) whose signature
  -- is missing or on a stale required version is refused too. Never for an
  -- import row (importing history), and member_waiver_current returns true when
  -- the studio has published nothing to sign, so the default require_waiver=true
  -- state with no version is unaffected.
  if new.import_id is null and not member_waiver_current(new.member_id, new.studio_id) then
    raise exception 'please sign the studio waiver before checking in'
      using errcode = 'PT422',
            hint = 'Sign it in the app on your phone, or the desk can record a paper waiver.';
  end if;

  return new;
end $$;
revoke execute on function enforce_guest_waiver() from public, anon, authenticated;

-- --- self_check_in -------------------------------------------------------------
-- The member checks themselves in from their phone. SECURITY DEFINER precisely
-- so no member INSERT policy is added to check_ins. Per booking, so nothing is
-- guessed; idempotent on the check_ins.booking_id unique index. PT403 for a
-- booking that is not the caller's own; PT422 for a stale/missing waiver; every
-- other refusal is a soft {ok:false, reason} the app renders as a sentence.
create function self_check_in(p_booking_id uuid,
                              p_lat double precision default null,
                              p_lng double precision default null,
                              p_accuracy_m double precision default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_b   bookings%rowtype;
  v_m   members%rowtype;
  v_o   class_occurrences%rowtype;
  v_l   locations%rowtype;
  v_set studio_settings%rowtype;
  v_now timestamptz := now();
  v_dist double precision;
  v_cap  int;
  v_eff  double precision;
begin
  select * into v_b from bookings where id = p_booking_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;

  select * into v_m from members where id = v_b.member_id;
  -- Own booking only. A NULL user_id (unclaimed) can never match auth.uid().
  if not coalesce(v_m.user_id = auth.uid(), false) then
    raise exception 'that is not your booking' using errcode = 'PT403';
  end if;

  if v_b.status not in ('booked', 'attended') then
    return jsonb_build_object('ok', false, 'reason', 'not_booked');
  end if;

  select * into v_o from class_occurrences where id = v_b.occurrence_id;
  if v_o.status <> 'scheduled' then
    return jsonb_build_object('ok', false, 'reason', 'class_not_scheduled');
  end if;

  -- Decision 25: only a published month is checkable.
  if not month_published(v_o.studio_id, v_o.starts_at) then
    return jsonb_build_object('ok', false, 'reason', 'month_not_published');
  end if;

  -- §8 window (respecting the escape hatch). The trigger enforces it too; this
  -- pre-check gives a clean sentence rather than a raw trigger error.
  select * into v_set from studio_settings where studio_id = v_o.studio_id;
  if coalesce(v_set.checkin_window_enforced, true) then
    if v_now < v_o.starts_at - make_interval(mins => v_set.checkin_opens_minutes_before)
       or v_now > coalesce(v_o.ends_at, v_o.starts_at) + make_interval(mins => v_set.checkin_closes_minutes_after) then
      return jsonb_build_object('ok', false, 'reason', 'window_closed');
    end if;
  end if;

  -- Waiver at the door (belt-and-braces with the trigger). PT422 like a guest.
  if not member_waiver_current(v_m.id, v_o.studio_id) then
    raise exception 'please sign the studio waiver before checking in'
      using errcode = 'PT422',
            hint = 'Sign it in the app on your phone, or ask the desk.';
  end if;

  -- Geofence, against the OCCURRENCE's own location.
  select * into v_l from locations where id = v_o.location_id;
  v_cap := coalesce(v_l.self_checkin_accuracy_cap_m, 150);
  if coalesce(v_l.self_checkin_requires_location, true) then
    if v_l.latitude is null or v_l.longitude is null then
      return jsonb_build_object('ok', false, 'reason', 'studio_has_no_location');
    end if;
    if p_lat is null or p_lng is null then
      return jsonb_build_object('ok', false, 'reason', 'no_location');
    end if;
    -- Accuracy is client-supplied: cap it FIRST, or a phone reporting 5000 m
    -- passes from anywhere. Over the cap is its own refusal.
    if p_accuracy_m is not null and p_accuracy_m > v_cap then
      return jsonb_build_object('ok', false, 'reason', 'low_accuracy');
    end if;
    v_dist := earth_distance_m(v_l.latitude, v_l.longitude, p_lat, p_lng);
    v_eff  := least(coalesce(p_accuracy_m, 0), v_cap);
    if v_dist > coalesce(v_l.self_checkin_radius_m, 200) + v_eff then
      return jsonb_build_object('ok', false, 'reason', 'too_far', 'distance_m', round(v_dist)::int);
    end if;
  else
    -- Trust-based: geofence off. Record a distance only if we have both ends.
    if v_l.latitude is not null and v_l.longitude is not null and p_lat is not null and p_lng is not null then
      v_dist := earth_distance_m(v_l.latitude, v_l.longitude, p_lat, p_lng);
    end if;
  end if;

  -- Write. Idempotent: a second call for the same booking is the same success.
  -- The AFTER-insert health trigger (health_on_check_in -> refresh_member_health)
  -- writes members.health_*; here auth.uid() IS the member, so guard_member_self_update
  -- would block that system cascade (a desk check-in is exempt via is_desk_up).
  -- The flag exempts the health refresh only, the sign_waiver pattern — a client
  -- cannot set it (only this SECURITY DEFINER function does).
  begin
    perform set_config('studiior.checkin_health', '1', true);
    insert into check_ins (studio_id, booking_id, member_id, occurrence_id,
                           method, checked_in_by, distance_m, accuracy_m)
    values (v_o.studio_id, v_b.id, v_m.id, v_o.id, 'self',
            (select id from profiles where id = auth.uid()),
            case when v_dist is not null then round(v_dist)::int else null end,
            case when p_accuracy_m is not null then round(p_accuracy_m)::int else null end);
    update bookings set status = 'attended' where id = v_b.id and status = 'booked';
    perform set_config('studiior.checkin_health', '', true);
  exception when unique_violation then
    perform set_config('studiior.checkin_health', '', true);
    return jsonb_build_object('ok', true, 'already', true);
  end;

  return jsonb_build_object('ok', true, 'checked_in', true,
    'distance_m', case when v_dist is not null then round(v_dist)::int else null end);
end $$;
revoke execute on function self_check_in(uuid, double precision, double precision, double precision) from public, anon;
grant  execute on function self_check_in(uuid, double precision, double precision, double precision) to authenticated;

-- --- import_commit: attendance method 'staff' -> 'import' -----------------------
-- Re-issued verbatim from migration 550 (the newest), one literal changed, so
-- 'staff' now means a human at the desk. Existing imported rows keep 'staff'
-- (not retroactive).
create or replace function public.import_commit(p_import_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  imp     imports%rowtype;
  r       record;
  created int := 0;
  mid     uuid;
  touched uuid[] := '{}';
begin
  select * into imp from imports where id = p_import_id for update;
  if not found then
    raise exception 'no such import' using errcode = 'PT404';
  end if;
  if not is_manager_up(imp.studio_id) then
    raise exception 'only owners and managers may import' using errcode = 'PT403';
  end if;
  -- Lockout (migration 044). The studio's own subscription to Studiior has
  -- lapsed past its grace period. Reads stay open everywhere so nothing looks
  -- lost; this is one of the four places where DOING something stops.
  if studio_is_locked(imp.studio_id) then
    raise exception 'this studio''s Studiior subscription is not active'
      using errcode = 'PT402',
            hint = 'Reactivate it from Billing. Nothing has been deleted.';
  end if;

  if imp.status <> 'dry_run_complete' then
    raise exception 'run the dry run first — this import is %', imp.status
      using errcode = 'PT409',
            hint = 'Nothing is committed until the owner has seen what will happen.';
  end if;

  for r in select * from import_rows
            where import_id = p_import_id and status = 'ok' order by row_number
  loop
    if imp.type = 'members' then
      insert into members (studio_id, first_name, last_name, email, phone,
                           joined_on, status, waiver_signed_at)
      values (imp.studio_id,
              coalesce(nullif(r.normalized ->> 'first_name', ''), '—'),
              coalesce(nullif(r.normalized ->> 'last_name', ''), '—'),
              lower(r.normalized ->> 'email'),
              nullif(r.normalized ->> 'phone', ''),
              coalesce((r.normalized ->> 'joined_on')::date, current_date),
              coalesce(import_member_status(r.normalized ->> 'status'), 'active'),
              (r.normalized ->> 'waiver_signed_at')::timestamptz)
      returning id into mid;

      update import_rows set entity_table = 'members', entity_id = mid,
                             status = 'committed'
       where id = r.id;

    elsif imp.type = 'memberships' then
      insert into memberships (studio_id, member_id, plan_id, status, price_cents,
                               currency, starts_on, expires_on, credits_remaining)
      select imp.studio_id, m.id, p.id,
             coalesce(import_membership_status(r.normalized ->> 'status'), 'active'),
             -- §7.1: the price is snapshotted at purchase. An import carries
             -- what they actually paid when it is in the file, and falls back
             -- to today's plan price only when it is not.
             coalesce((r.normalized ->> 'price_cents')::int, p.price_cents),
             p.currency,
             coalesce((r.normalized ->> 'starts_on')::date, current_date),
             (r.normalized ->> 'expires_on')::date,
             coalesce((r.normalized ->> 'credits_remaining')::int,
                      p.credits, p.credits_per_period)
        from members m, membership_plans p
       where m.studio_id = imp.studio_id
         and lower(m.email) = lower(r.normalized ->> 'email')
         and p.studio_id = imp.studio_id
         and lower(p.name) = lower(r.normalized ->> 'plan')
      returning id into mid;

      update import_rows set entity_table = 'memberships', entity_id = mid,
                             status = 'committed'
       where id = r.id;

    else  -- attendance
      -- No occurrence and no booking: the class this visit belonged to is not
      -- in the export and inventing one would put thousands of classes that
      -- never ran into the calendar. import_id carries the provenance and
      -- exempts the row from the §8 check-in window, which is about people
      -- arriving, not about recording that they did. method 'import' (Decision
      -- 35) so 'staff' means a human at the desk.
      insert into check_ins (studio_id, booking_id, member_id, occurrence_id,
                             checked_in_at, method, import_id)
      select imp.studio_id, null, m.id, null,
             (r.normalized ->> 'attended_at')::timestamptz, 'import', p_import_id
        from members m
       where m.studio_id = imp.studio_id
         and lower(m.email) = lower(r.normalized ->> 'email')
      returning id, member_id into mid, mid;

      select m.id into mid from members m
       where m.studio_id = imp.studio_id
         and lower(m.email) = lower(r.normalized ->> 'email');
      touched := touched || mid;

      update import_rows set entity_table = 'check_ins',
                             entity_id = (select ci.id from check_ins ci
                                           where ci.import_id = p_import_id
                                             and ci.member_id = mid
                                           order by ci.created_at desc limit 1),
                             status = 'committed'
       where id = r.id;
    end if;

    created := created + 1;
  end loop;

  update imports set status = 'complete' where id = p_import_id;

  -- Imported attendance changes what every visit-derived number means.
  if imp.type = 'attendance' and array_length(touched, 1) is not null then
    perform recompute_member_stats(imp.studio_id, touched);
    perform refresh_studio_health(imp.studio_id);
  end if;

  return jsonb_build_object('created', created, 'type', imp.type);
end $function$;

-- --- guard_member_self_update honours the self check-in health flag ------------
-- Re-issued from migration 163 with one added exemption. Without it, a member's
-- own self_check_in trips the guard when the health trigger refreshes their band
-- (auth.uid() = the member). The flag is transaction-local and set only inside
-- self_check_in (a SECURITY DEFINER function); nothing a client can reach sets
-- it, exactly like studiior.waiver_signing.
create or replace function guard_member_self_update() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  owned constant text[] := array[
    'preferred_name', 'phone', 'avatar_url', 'emergency_contact',
    'address', 'date_of_birth', 'marketing_opt_in', 'updated_at'
  ];
  -- The columns each SECURITY DEFINER writer is allowed to touch while holding
  -- its transaction-local flag. NARROW, not a blanket bypass: a member session
  -- can never hold a flag (a client cannot set_config), but if one ever leaked
  -- the exemption still lets through only the writer's own columns — never the
  -- rest of the member row.
  waiver_cols constant text[] := array['waiver_signed_at', 'updated_at'];
  health_cols constant text[] := array['health_band', 'health_reason',
                                       'health_signals', 'health_computed_at', 'updated_at'];
begin
  if is_service_context() then
    return new;
  end if;
  -- sign_waiver_document() stamps members.waiver_signed_at as the member. Exempt
  -- ONLY that column (+ updated_at); anything else on the row still raises.
  if coalesce(current_setting('studiior.waiver_signing', true), '') = '1' then
    if (to_jsonb(new) - waiver_cols) <> (to_jsonb(old) - waiver_cols) then
      raise exception 'waiver signing may set only the signature timestamp'
        using errcode = 'PT403';
    end if;
    return new;
  end if;
  -- Decision 35: the self check-in health cascade (refresh_member_health) writes
  -- members.health_* while auth.uid() is the member. Exempt ONLY the four health
  -- columns (+ updated_at) — health is the system's to compute, never the
  -- member's to set, and only self_check_in raises this flag around its insert.
  if coalesce(current_setting('studiior.checkin_health', true), '') = '1' then
    if (to_jsonb(new) - health_cols) <> (to_jsonb(old) - health_cols) then
      raise exception 'the check-in health cascade may set only the health columns'
        using errcode = 'PT403';
    end if;
    return new;
  end if;
  if is_desk_up(new.studio_id) then
    return new;
  end if;
  if old.user_id is null then
    return new;
  end if;
  if auth.uid() is null or old.user_id is distinct from auth.uid() then
    return new;
  end if;
  if (to_jsonb(new) - owned) <> (to_jsonb(old) - owned) then
    raise exception 'a member may change their own contact details, not their membership'
      using errcode = 'PT403',
            hint = 'Editable by the member: ' || array_to_string(owned, ', ')
                   || '. Everything else is the studio''s to set.';
  end if;
  return new;
end $$;

-- --- Anon surface must stay exactly eleven. -----------------------------------
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 11 then raise exception 'anon surface is % (expected 11)', n; end if;
end $$;
