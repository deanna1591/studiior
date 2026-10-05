-- =============================================================================
-- 236 — Decision 35 Part B: the printed studio QR and instructor scanning.
--
-- Part A (migrations 169–170) built member self check-in, the geofence and the
-- member-waiver-at-every-door. Part B adds the two remaining doors from ## 35:
--
-- §3 THE PRINTED STUDIO QR. A per-studio static slug (random hex, re-mintable —
-- re-minting kills the old printout) encoded in a QR of
-- https://{slug}.{member_app_domain}/checkin/{checkin_slug}. Scanning it opens
-- the member app, which runs the SAME self_check_in (window + geofence +
-- waiver) — a shortcut, not a credential: it names the studio, the member's
-- session names who. No new writer; the route reuses self_check_in.
--
-- §4 INSTRUCTOR SCANNING. instructor_resolve_code(occurrence, code) mirrors
-- resolve_checkin_code's shape — resolve the member's 8-char rotating code —
-- but guarded on the occurrence's OWN instructor (or a manager) AND the window
-- open, returning the member only if booked in THAT occurrence. The roster
-- check-in then writes method='instructor' (the enum value Part A added).
--
-- ANON STAYS EXACTLY THIRTEEN. /checkin/{slug} signs the member in first; the
-- slug is resolved by the authed-only checkin_slug_studio() (returns only the
-- owning studio's id — a slug that opens a page is not a credential), so the
-- anon studio_by_slug is NOT touched. check_ins gains no member insert policy —
-- the instructor writes through the existing studio-staff policy (checkins_staff).
-- =============================================================================

-- creates: ensure_checkin_slug(uuid), remint_checkin_slug(uuid),
-- creates: checkin_slug_studio(text), instructor_resolve_code(uuid, text)

-- -----------------------------------------------------------------------------
-- §3. The static slug on the studio. Nullable, no default — minted lazily the
-- first time the owner opens the print view, so a studio that never prints a
-- code never gets one (opt-in by existence).
-- -----------------------------------------------------------------------------
alter table studios add column if not exists checkin_slug text unique;

comment on column studios.checkin_slug is
  'Decision 35 §3: the opaque slug in the printed check-in QR '
  '({member_app}/checkin/{checkin_slug}). Minted lazily; re-minting kills the '
  'old printout. Not a credential — it opens a page; the session is the identity.';

-- Mint if absent, return the current slug. Manager-up (the owner prints it).
-- Locks the studio row so two concurrent first-prints cannot double-mint.
create or replace function ensure_checkin_slug(p_studio_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_slug text;
begin
  if not is_manager_up(p_studio_id) then
    raise exception 'only owners and managers manage the check-in code' using errcode = 'PT403';
  end if;
  select checkin_slug into v_slug from studios where id = p_studio_id for update;
  if v_slug is null then
    v_slug := encode(extensions.gen_random_bytes(16), 'hex');
    update studios set checkin_slug = v_slug where id = p_studio_id;
  end if;
  return v_slug;
end $$;
revoke execute on function ensure_checkin_slug(uuid) from public, anon;
grant  execute on function ensure_checkin_slug(uuid) to authenticated, service_role;

-- Always a fresh slug — the old printout stops working. Manager-up.
create or replace function remint_checkin_slug(p_studio_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_slug text;
begin
  if not is_manager_up(p_studio_id) then
    raise exception 'only owners and managers manage the check-in code' using errcode = 'PT403';
  end if;
  v_slug := encode(extensions.gen_random_bytes(16), 'hex');
  update studios set checkin_slug = v_slug where id = p_studio_id;
  return v_slug;
end $$;
revoke execute on function remint_checkin_slug(uuid) from public, anon;
grant  execute on function remint_checkin_slug(uuid) to authenticated, service_role;

-- Resolve a check-in slug to the studio that owns it (or null). Authed-only, so
-- the /checkin/{slug} page — which has already signed the member in — can tell
-- "this code is this studio's" from "this code is another studio's" without
-- touching the anon studio_by_slug. It returns ONLY a studio id: a member who
-- scanned the code already knows it maps to a studio, and the id unlocks nothing
-- without a membership. No tenant guard — there is nothing tenant-scoped to
-- guard, and the slug space is unguessable random hex.
create or replace function checkin_slug_studio(p_slug text)
returns uuid language sql stable security definer set search_path = public as $$
  select id from studios where checkin_slug = p_slug and status = 'active' limit 1;
$$;
revoke execute on function checkin_slug_studio(text) from public, anon;
grant  execute on function checkin_slug_studio(text) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- §4. Instructor scanning. Mirrors resolve_checkin_code (the 8-char rotating
-- code, current or previous 30s bucket) but: the caller must be the
-- occurrence's OWN instructor or a manager of its studio; the window must be
-- open; and the member must be booked in THAT occurrence. It RESOLVES only —
-- the roster writes the check_ins row (method='instructor') through the
-- existing studio-staff policy, so the waiver trigger fires at that door too.
-- -----------------------------------------------------------------------------
create or replace function instructor_resolve_code(p_occurrence_id uuid, p_code text)
returns table(member_id uuid, first_name text, last_name text, email text)
language plpgsql stable security definer set search_path = public as $$
declare
  v_o      class_occurrences%rowtype;
  v_set    studio_settings%rowtype;
  v_bucket bigint;
  v_code   text := upper(btrim(p_code));
  v_now    timestamptz := now();
begin
  select * into v_o from class_occurrences where id = p_occurrence_id;
  if v_o.id is null then
    raise exception 'no such class' using errcode = 'PT404';
  end if;

  -- The occurrence's own instructor, or a manager of the studio.
  if not (coalesce(auth_instructor_id(v_o.studio_id) = v_o.instructor_id, false)
          or is_manager_up(v_o.studio_id)) then
    raise exception 'that is not your class' using errcode = 'PT403';
  end if;

  -- A locked studio checks nobody in (mirrors resolve_checkin_code).
  if studio_is_locked(v_o.studio_id) then
    raise exception 'this studio''s Studiior subscription is not active' using errcode = 'PT402';
  end if;

  -- The §8 window must be open (respecting the escape hatch).
  select * into v_set from studio_settings where studio_id = v_o.studio_id;
  if coalesce(v_set.checkin_window_enforced, true) then
    if v_now < v_o.starts_at - make_interval(mins => v_set.checkin_opens_minutes_before)
       or v_now > coalesce(v_o.ends_at, v_o.starts_at) + make_interval(mins => v_set.checkin_closes_minutes_after) then
      raise exception 'the check-in window is closed for this class' using errcode = 'PT409';
    end if;
  end if;

  v_bucket := floor(extract(epoch from now()) / 30)::bigint;
  return query
    select m.id, m.first_name, m.last_name, m.email
      from members m
      join bookings b on b.member_id = m.id
                     and b.occurrence_id = p_occurrence_id
                     and b.status in ('booked', 'attended')
     where m.studio_id = v_o.studio_id
       and (checkin_code_for(m.id, v_bucket)     = v_code
         or checkin_code_for(m.id, v_bucket - 1) = v_code)
     limit 1;
end $$;
revoke execute on function instructor_resolve_code(uuid, text) from public, anon;
grant  execute on function instructor_resolve_code(uuid, text) to authenticated, service_role;
