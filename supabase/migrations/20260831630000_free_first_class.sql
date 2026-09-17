-- =============================================================================
-- Decision 30 — a new member's first class is free.
--
-- Optional per studio, OFF by default (free_first_class_enabled). A stranger
-- signs up on their own, books a class, and it costs nothing — no host, no
-- invite, no card, no credits. Reform Collective opens on 9 November with no
-- card provider (Stripe does not serve the Philippines), so this is how a
-- first-timer gets in the door at all.
--
-- IT SHARES DECISION 26'S ONCE-EVER LEDGER. `guest_passes` is already "who has
-- had their one free class here", keyed on email. This is the SAME free class
-- through a different door, so a self-signup free class is recorded as a
-- guest_passes row with NO HOST — the free-once email index then spans both
-- doors automatically, and `guest_pass_eligibility` (which already reads the
-- ledger by email) refuses a signup-then-guest, or a guest-then-signup, with
-- the same `already_had_free`. One free class per person, whichever route.
--
-- The waiver, the check-in gate, the host-cancel/attend sync and the conversion
-- derivation are all Decision 26's, reused unchanged: a self-signup free class
-- is a guest_passes row, so the same triggers fire.
-- =============================================================================

-- The door, and the peak guard. Off by default; peak ALLOWED by default, since a
-- new studio wants people in the room at any hour — a studio that would rather
-- not give a free seat away at 7am on a Tuesday turns it off.
alter table studio_settings
  add column if not exists free_first_class_enabled boolean not null default false,
  add column if not exists free_first_peak_allowed  boolean not null default true;

-- A self-signup free class has no host, so the ledger's host becomes nullable.
-- The free-once email index is rebuilt below over the shared normalized key and
-- now covers both doors; the one-live-per-host index is partial on host, and a
-- NULL host is distinct in a unique index, so signups never collide with each
-- other or with a member's live guest.
alter table guest_passes alter column host_member_id drop not null;

-- ---------------------------------------------------------------------------
-- normalize_email_key — the SHARED once-ever key (Decision 26 + Decision 30).
-- Two addresses that reach the same inbox are one person for "free once ever":
-- lowercase, trim, drop the +tag for every provider, and drop dots in the local
-- part for gmail/googlemail only (dots are significant elsewhere).
--
-- IMMUTABLE, so it can back a functional unique index. It answers ONE question —
-- "has this person had their free class, or are they already a member here" — in
-- exactly these places: the free-once index, and the already_had_free AND
-- already_member refusals in guest_pass_eligibility and free_first_eligibility.
-- For NOTHING that links or addresses a person: not sending, display, login, or
-- account claiming. Mail is addressed via the member row's raw email. (Decision 30.)
-- ---------------------------------------------------------------------------
create function normalize_email_key(p_email text) returns text
language sql immutable returns null on null input as $$
  with a as (select lower(btrim(p_email)) as addr),
  p as (
    select
      case when position('@' in addr) > 0
           then left(addr, length(addr) - position('@' in reverse(addr)))
           else addr end as loc,
      case when position('@' in addr) > 0
           then right(addr, position('@' in reverse(addr)) - 1)
           else '' end as dom
    from a
  ),
  q as (select split_part(loc, '+', 1) as loc_notag, dom from p)
  select case
    when dom = '' then loc_notag
    -- gmail.com and googlemail.com are the same inbox: strip dots AND fold the
    -- domain to gmail.com, so a.b@googlemail.com and ab@gmail.com are one person.
    when dom in ('gmail.com','googlemail.com') then replace(loc_notag, '.', '') || '@gmail.com'
    else loc_notag || '@' || dom
  end
  from q;
$$;
-- An internal helper: used only inside definer functions and the index, so no
-- client role executes it (and it must NOT become an eleventh anon surface).
revoke execute on function normalize_email_key(text) from public, anon, authenticated;
grant  execute on function normalize_email_key(text) to service_role;

-- The free-once index becomes FUNCTIONAL: guest_email is stored lowercased and
-- trimmed at BOTH doors (book_guest and book_first_free), never plus- or
-- dot-mangled — the once-ever key is COMPUTED by normalize_email_key, never
-- stored — and the index enforces uniqueness on that computed key. Replaces
-- migration 320000's (studio_id, lower(guest_email)). Mail is addressed via the
-- member row's own email, not this column.
drop index if exists guest_passes_one_per_email;
create unique index guest_passes_one_per_email
  on guest_passes (studio_id, normalize_email_key(guest_email));

-- guest_pass_eligibility (Decision 26) re-issued to read the ledger by the shared
-- normalized key. The "already a member" check below ALSO uses that key: an
-- existing member under a plus/dot variant must not slip past it as a stranger.
create or replace function guest_pass_eligibility(p_studio_id uuid, p_host_member_id uuid, p_email text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_email text := lower(btrim(p_email));
begin
  if not coalesce((select guest_passes_enabled from studio_settings where studio_id = p_studio_id), false) then
    return jsonb_build_object('ok', false, 'reason', 'not_enabled');
  end if;
  if v_email = '' or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    return jsonb_build_object('ok', false, 'reason', 'bad_email');
  end if;
  -- One guest at a time.
  if exists (select 1 from guest_passes
              where host_member_id = p_host_member_id and status in ('invited','confirmed')) then
    return jsonb_build_object('ok', false, 'reason', 'have_active_guest');
  end if;
  -- Free once ever, keyed on the normalized email (spans guest + free-first).
  if exists (select 1 from guest_passes
              where studio_id = p_studio_id
                and normalize_email_key(guest_email) = normalize_email_key(p_email)) then
    return jsonb_build_object('ok', false, 'reason', 'already_had_free');
  end if;
  -- Already a member here — matched on the once-ever KEY, not raw lower(): an
  -- existing member a@gmail.com must not slip in as a+1@gmail.com, where the
  -- variant hides them AND no pass yet exists to trip the index.
  if exists (select 1 from members
              where studio_id = p_studio_id
                and normalize_email_key(email) = normalize_email_key(p_email)) then
    return jsonb_build_object('ok', false, 'reason', 'already_member');
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------------
-- sweep_guest_waivers re-issued — TWO fixes, because the real defect is that one
-- uncaught error took guest-waiver reminders down for every tenant at once, and
-- the null host was merely the first thing to trigger it.
--   (a) A free-first pass (Decision 30) has NO host, so the host nudge is only
--       attempted when host_member_id is not null — queue_notification refuses a
--       null recipient (PT422).
--   (b) Each pass is processed in its OWN subtransaction, so any failure on one
--       row is logged and skipped rather than aborting the whole sweep.
-- ---------------------------------------------------------------------------
create or replace function sweep_guest_waivers() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r record; v_guest int := 0; v_host int := 0; v_skipped int := 0;
        v_token text; v_url text; v_when text; v_did_guest boolean; v_did_host boolean;
        v_state text; v_msg text;
begin
  if not is_service_context() then
    raise exception 'the guest waiver sweep is a background job' using errcode = 'PT403';
  end if;

  for r in
    select gp.id as pass_id, gp.studio_id, gp.guest_member_id, gp.host_member_id,
           gp.occurrence_id, o.name as class_name, o.starts_at,
           gm.user_id as guest_user_id, gm.email as guest_email,
           s.slug, s.timezone
      from guest_passes gp
      join class_occurrences o on o.id = gp.occurrence_id
      join members gm on gm.id = gp.guest_member_id
      join studios s on s.id = gp.studio_id
     where gp.status = 'invited'                       -- unsigned
       and gm.waiver_signed_at is null
       and o.status = 'scheduled'
       and now() >= o.starts_at - interval '4 hours'
       and now() <  o.starts_at
  loop
    begin
      v_when := to_char(r.starts_at at time zone r.timezone, 'FMDay FMDD FMMonth, HH24:MI');

      -- The guest's link: claim if no account yet (fresh token), else the app home.
      if r.guest_user_id is null then
        v_token := encode(gen_random_bytes(24), 'hex');
        delete from member_invites where member_id = r.guest_member_id and accepted_at is null;
        insert into member_invites (studio_id, member_id, email, token_hash, expires_at)
        values (r.studio_id, r.guest_member_id, r.guest_email,
                encode(digest(v_token, 'sha256'), 'hex'), now() + interval '14 days');
        v_url := 'https://' || r.slug || '.'
                 || coalesce(notification_setting('member_app_domain'), 'studiior.app')
                 || '/claim/' || v_token;
      else
        v_url := 'https://' || r.slug || '.'
                 || coalesce(notification_setting('member_app_domain'), 'studiior.app') || '/';
      end if;

      v_did_guest := queue_notification(r.studio_id, r.guest_member_id, 'guest_waiver_reminder',
           jsonb_build_object('claim_url', v_url, 'class_name', r.class_name, 'when', v_when),
           'guest_waiver_reminder:' || r.pass_id) is not null;

      -- (a) Only nudge a host who exists. A free-first pass has host_member_id null.
      if r.host_member_id is not null then
        v_did_host := queue_notification(r.studio_id, r.host_member_id, 'guest_waiver_host_nudge',
             jsonb_build_object('class_name', r.class_name, 'when', v_when),
             'guest_waiver_host_nudge:' || r.pass_id) is not null;
      else
        v_did_host := false;
      end if;

      -- Count only after the whole row commits — a caught error rolls the row's
      -- inserts back, so the counters must not have moved for it.
      if v_did_guest then v_guest := v_guest + 1; end if;
      if v_did_host  then v_host  := v_host  + 1; end if;
    exception when others then
      -- (b) One bad pass is logged and skipped, never fatal for the rest. The
      -- raise warning is ephemeral and the return value is discarded by cron, so
      -- a pass that fails every 15 minutes would be silent forever. Record it
      -- durably in audit_logs, ONCE per pass per day (a permanently bad row must
      -- not write 96 audit rows a day), best-effort so an audit failure cannot
      -- itself defeat the isolation this handler exists for.
      v_state := sqlstate; v_msg := sqlerrm;
      raise warning 'sweep_guest_waivers: pass % skipped: % (%)', r.pass_id, v_msg, v_state;
      v_skipped := v_skipped + 1;
      begin
        insert into audit_logs (studio_id, action, entity_table, entity_id, after)
        select r.studio_id, 'guest_waiver_sweep.pass_skipped', 'guest_passes', r.pass_id,
               jsonb_build_object('sqlstate', v_state, 'message', v_msg)
        where not exists (
          select 1 from audit_logs
           where action = 'guest_waiver_sweep.pass_skipped'
             and entity_id = r.pass_id
             and created_at >= current_date );
      exception when others then
        raise warning 'sweep_guest_waivers: could not record skip for pass %: %', r.pass_id, sqlerrm;
      end;
    end;
  end loop;

  insert into job_runs (job_key, run_for, status, finished_at)
  values ('guest_waivers', current_date, 'done', now())
  on conflict (job_key, run_for) do update
     set attempts = job_runs.attempts + 1, started_at = now(),
         status = 'done', finished_at = now();

  return jsonb_build_object('reminded', v_guest, 'nudged', v_host, 'skipped', v_skipped);
end $$;

-- ---------------------------------------------------------------------------
-- free_first_eligibility — the SHARED once-ever check, member-centric. The app
-- previews it and book_first_free runs it; capacity and peak are in the booking
-- function (they need the lock / the occurrence).
--
-- It reads the guest_passes ledger by email, which is BOTH the guest pass ledger
-- AND the record of any prior free booking (a free-first booking is a ledger
-- row) — one read, both doors. Plus "this is genuinely their first class": a
-- member who already holds a live/attended booking is not a first-timer.
-- ---------------------------------------------------------------------------
create function free_first_eligibility(p_studio_id uuid, p_member_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_member members%rowtype;
begin
  select * into v_member from members where id = p_member_id;
  if not found or v_member.studio_id <> p_studio_id then
    raise exception 'no such member here' using errcode = 'PT404';
  end if;
  -- Self, desk-up, or a background job. Takes an id, returns member-shaped data
  -- (migration 056): the grant is not the guard.
  if not (coalesce(v_member.user_id = auth.uid(), false)
          or coalesce(is_desk_up(p_studio_id), false)
          or is_service_context()) then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;

  if not coalesce((select free_first_class_enabled from studio_settings
                    where studio_id = p_studio_id), false) then
    return jsonb_build_object('ok', false, 'reason', 'not_enabled');
  end if;

  -- Already had a free class, either door (guest or a prior signup): the ledger
  -- is keyed on email, so a returning person is caught whatever member row they
  -- are booking from now.
  if exists (select 1 from guest_passes
              where studio_id = p_studio_id
                and normalize_email_key(guest_email) = normalize_email_key(v_member.email)) then
    return jsonb_build_object('ok', false, 'reason', 'already_had_free');
  end if;

  -- Already a member here under an email VARIANT (same normalized key, a
  -- different member row). Decision 30 is for NEW members, so a@gmail.com signing
  -- up again as a+1@gmail.com is not eligible — matched on the once-ever key, the
  -- same reach the guest door has, so a variant cannot hide an existing member.
  if exists (select 1 from members
              where studio_id = p_studio_id and id <> p_member_id
                and normalize_email_key(email) = normalize_email_key(v_member.email)) then
    return jsonb_build_object('ok', false, 'reason', 'already_member');
  end if;

  -- Not a first-timer: they already hold or have held a class. A cancelled
  -- booking does not count — they never actually took a class.
  if exists (select 1 from bookings
              where member_id = p_member_id and studio_id = p_studio_id
                and status in ('booked','waitlisted','attended','no_show','pending_payment')) then
    return jsonb_build_object('ok', false, 'reason', 'not_first');
  end if;

  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------------
-- book_first_free — the caller books their OWN free first class. Self-serve,
-- like sign_waiver: an ordinary signed-in member with no plan, no card, no
-- credits. Mirrors book_guest's direct comp-seat insert rather than routing
-- through book_class — book_class §2.1.4 would gate the waiver at BOOKING, and
-- Decision 26's rule (reused here) is that the waiver gates CHECK-IN, not
-- booking. The seat is `comp`: nothing consumed, nothing charged, ever — which
-- is also why turning the feature off cannot retroactively charge anyone, the
-- booking stands on its own.
-- ---------------------------------------------------------------------------
create function book_first_free(p_occurrence_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_occ    class_occurrences%rowtype;
  v_member members%rowtype;
  v_set    studio_settings%rowtype;
  v_tz     text;
  v_elig   jsonb;
  v_free   int;
  v_booking uuid;
  v_pass    uuid;
begin
  select * into v_occ from class_occurrences where id = p_occurrence_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;

  -- The caller's own member row in this studio (self only — a member books their
  -- own free class, never someone else's).
  select * into v_member from members
   where studio_id = v_occ.studio_id and user_id = auth.uid();
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_authorised'); end if;

  v_elig := free_first_eligibility(v_occ.studio_id, v_member.id);
  if not (v_elig ->> 'ok')::boolean then return v_elig; end if;

  select * into v_set from studio_settings where studio_id = v_occ.studio_id;
  select timezone into v_tz from studios where id = v_occ.studio_id;

  -- The occurrence must be bookable at all: scheduled, ahead, published, inside
  -- the window and before the cutoff — the same shape as book_class's own gates,
  -- so a free class cannot reach a class a paid one could not.
  if v_occ.status <> 'scheduled' then return jsonb_build_object('ok', false, 'reason', 'class_not_bookable'); end if;
  if v_occ.starts_at <= now() then return jsonb_build_object('ok', false, 'reason', 'class_in_past'); end if;
  if not month_published(v_occ.studio_id, v_occ.starts_at) then
    return jsonb_build_object('ok', false, 'reason', 'month_not_published');
  end if;
  if v_occ.starts_at > now() + make_interval(days => coalesce(v_set.booking_window_days, 30)) then
    return jsonb_build_object('ok', false, 'reason', 'outside_booking_window');
  end if;
  if v_occ.starts_at < now() + make_interval(mins => coalesce(v_set.booking_cutoff_minutes, 0)) then
    return jsonb_build_object('ok', false, 'reason', 'past_booking_cutoff');
  end if;

  -- A free class displaces a paying member and the instructor is paid regardless,
  -- so a studio can keep free classes out of its peak hours.
  if not coalesce(v_set.free_first_peak_allowed, true) and occurrence_is_peak(p_occurrence_id) then
    return jsonb_build_object('ok', false, 'reason', 'peak_not_allowed');
  end if;

  -- One seat, and a live waitlist offer's held seat (§4.2) is not free to take.
  v_free := v_occ.capacity - occurrence_seats_taken(p_occurrence_id)
                           - occurrence_seats_held(p_occurrence_id);
  if v_free < 1 then return jsonb_build_object('ok', false, 'reason', 'class_full'); end if;

  -- The free, separate seat: comp, no membership, no credit, no peak allowance.
  insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source)
  values (v_occ.studio_id, p_occurrence_id, v_member.id, 'booked', 'member', 'comp')
  returning id into v_booking;
  update class_occurrences set booked_count = booked_count + 1 where id = p_occurrence_id;

  -- Recorded in the shared ledger with NO HOST — this is the once-ever key, and
  -- it gives the free-first class Decision 26's waiver-at-check-in gate, the
  -- attend/cancel sync and the conversion derivation for free. Confirmed already
  -- if their waiver is signed; otherwise chased exactly as a guest's is.
  insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email,
                            occurrence_id, guest_booking_id, status, waiver_signed_at)
  values (v_occ.studio_id, null, v_member.id, lower(btrim(v_member.email)),
          p_occurrence_id, v_booking,
          case when v_member.waiver_signed_at is not null then 'confirmed' else 'invited' end,
          v_member.waiver_signed_at)
  returning id into v_pass;

  return jsonb_build_object('ok', true, 'booking_id', v_booking, 'guest_pass_id', v_pass);
end $$;

-- ---------------------------------------------------------------------------
-- Reporting. The ledger now holds both doors, so the two reports are scoped by
-- route: guests are host-not-null, signups are host-null. Each derives
-- "converted" the same way — the free member holds any membership.
-- ---------------------------------------------------------------------------

-- Guest report re-scoped to the guest door only, so signups do not inflate it.
create or replace function guest_pass_report(p_studio_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (coalesce(is_manager_up(p_studio_id), false) or is_service_context()) then
    raise exception 'only owners and managers read the guest report' using errcode = 'PT403';
  end if;
  return (
    select jsonb_build_object(
      'total',     count(*),
      'attended',  count(*) filter (where gp.status = 'attended'),
      'pending',   count(*) filter (where gp.status in ('invited','confirmed')),
      'converted', count(*) filter (where exists (
                     select 1 from memberships ms where ms.member_id = gp.guest_member_id)),
      'conversion_rate', case when count(*) filter (where gp.status = 'attended') = 0 then null
        else round(100.0 * count(*) filter (where gp.status = 'attended'
               and exists (select 1 from memberships ms where ms.member_id = gp.guest_member_id))
             / count(*) filter (where gp.status = 'attended')) end)
    from guest_passes gp
   where gp.studio_id = p_studio_id and gp.host_member_id is not null);
end $$;

create or replace function dashboard_guest_kpi(p_studio_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_total int; v_conv int;
begin
  if not (coalesce(is_manager_up(p_studio_id), false) or is_service_context()) then
    raise exception 'not authorised' using errcode = 'PT403';
  end if;
  if not coalesce((select guest_passes_enabled from studio_settings where studio_id = p_studio_id), false) then
    return null;
  end if;
  select count(*),
         count(*) filter (where exists (select 1 from memberships ms where ms.member_id = gp.guest_member_id))
    into v_total, v_conv
    from guest_passes gp where gp.studio_id = p_studio_id and gp.host_member_id is not null;
  if coalesce(v_total, 0) = 0 then return null; end if;
  return jsonb_build_object(
    'key', 'guest_conversion', 'label', 'Guests converted',
    'state', case when v_conv = 0 then 'empty' else 'ok' end,
    'kind', 'count', 'value', v_conv,
    'sub', 'of ' || v_total || ' guest' || case when v_total = 1 then '' else 's' end,
    'href', '/members', 'empty_hint', 'None have bought a plan yet.');
end $$;

-- The free-first report — the whole justification for the feature: how many free
-- first classes, and how many of those people bought something afterwards.
create function free_first_report(p_studio_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (coalesce(is_manager_up(p_studio_id), false) or is_service_context()) then
    raise exception 'only owners and managers read this report' using errcode = 'PT403';
  end if;
  return (
    select jsonb_build_object(
      'total',     count(*),
      'attended',  count(*) filter (where gp.status = 'attended'),
      'pending',   count(*) filter (where gp.status in ('invited','confirmed')),
      'converted', count(*) filter (where exists (
                     select 1 from memberships ms where ms.member_id = gp.guest_member_id)),
      'conversion_rate', case when count(*) filter (where gp.status = 'attended') = 0 then null
        else round(100.0 * count(*) filter (where gp.status = 'attended'
               and exists (select 1 from memberships ms where ms.member_id = gp.guest_member_id))
             / count(*) filter (where gp.status = 'attended')) end)
    from guest_passes gp
   where gp.studio_id = p_studio_id and gp.host_member_id is null);
end $$;

create function dashboard_free_first_kpi(p_studio_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_total int; v_conv int;
begin
  if not (coalesce(is_manager_up(p_studio_id), false) or is_service_context()) then
    raise exception 'not authorised' using errcode = 'PT403';
  end if;
  if not coalesce((select free_first_class_enabled from studio_settings where studio_id = p_studio_id), false) then
    return null;
  end if;
  select count(*),
         count(*) filter (where exists (select 1 from memberships ms where ms.member_id = gp.guest_member_id))
    into v_total, v_conv
    from guest_passes gp where gp.studio_id = p_studio_id and gp.host_member_id is null;
  if coalesce(v_total, 0) = 0 then return null; end if;
  return jsonb_build_object(
    'key', 'free_first_conversion', 'label', 'First-timers converted',
    'state', case when v_conv = 0 then 'empty' else 'ok' end,
    'kind', 'count', 'value', v_conv,
    'sub', 'of ' || v_total || ' free first ' || case when v_total = 1 then 'class' else 'classes' end,
    'href', '/members', 'empty_hint', 'None have bought a plan yet.');
end $$;

-- ---------------------------------------------------------------------------
-- Surface the flag to the pre-login signup screen. studio_by_slug is where the
-- member app reads a studio before anyone is a member, and "your first class is
-- on us" belongs on the signup screen, where they decide. It is ONE OF THE TEN
-- pre-login surfaces, so the grant is re-asserted and the anon surface re-checked
-- exactly as migration 111 established.
-- ---------------------------------------------------------------------------
drop function if exists studio_by_slug(text);
create function studio_by_slug(p_slug text)
returns table (
  id uuid, name text, slug text, timezone text, currency text,
  logo_url text, theme_preset theme_preset, accent_color text, login_image_url text,
  login_image_focus_x smallint, login_image_focus_y smallint, free_first_class_enabled boolean
)
language sql stable security definer set search_path = public as $$
  select s.id, s.name, s.slug, s.timezone, s.currency,
         s.logo_url, s.theme_preset, s.accent_color, s.login_image_url,
         s.login_image_focus_x, s.login_image_focus_y,
         coalesce(ss.free_first_class_enabled, false)
    from studios s
    left join studio_settings ss on ss.studio_id = s.id
   where s.slug = p_slug and s.status = 'active'
$$;
revoke execute on function studio_by_slug(text) from public;
grant  execute on function studio_by_slug(text) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- A claimed member could not sign their OWN waiver — and this is a latent
-- Decision 26 bug the free-first door is the first to hit. guard_member_self_update
-- (migration 035) protects waiver_signed_at from a member editing their own row,
-- because a member self-signing would walk past the §2.1 booking gate. But
-- sign_waiver IS the controlled path for signing your own waiver, and a guest
-- only got away with it because they were unclaimed (user_id null) at the time.
-- A self-signup member is claimed, so their sign_waiver was refused PT403.
--
-- The fix is the same shape as the other transaction-local flags (studiior.releasing,
-- studiior.series_editing): sign_waiver sets studiior.waiver_signing, and the guard
-- trusts ONLY that flag — a raw PATCH cannot set it, so the protection migration
-- 035 exists for is untouched.
-- ---------------------------------------------------------------------------
create or replace function guard_member_self_update() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  owned constant text[] := array[
    'preferred_name', 'phone', 'avatar_url', 'emergency_contact',
    'address', 'date_of_birth', 'marketing_opt_in', 'updated_at'
  ];
begin
  if is_service_context() then
    return new;
  end if;
  -- The controlled self-serve waiver path: sign_waiver sets this flag around its
  -- own update. Nothing a client can reach sets it, so it cannot be used to forge
  -- an edit to any other protected column. (The desk paper path is already
  -- exempt through is_desk_up below.)
  if coalesce(current_setting('studiior.waiver_signing', true), '') = '1' then
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

-- sign_waiver re-issued to raise the flag around its own update. Otherwise
-- unchanged (it confirms any live guest pass, now including a free-first pass).
create or replace function sign_waiver(p_member_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare m members%rowtype;
begin
  select * into m from members where id = p_member_id;
  if not found then raise exception 'no such member' using errcode = 'PT404'; end if;
  if not (coalesce(m.user_id = auth.uid(), false) or coalesce(is_desk_up(m.studio_id), false)) then
    raise exception 'that is not your waiver to sign' using errcode = 'PT403';
  end if;
  perform set_config('studiior.waiver_signing', '1', true);
  update members set waiver_signed_at = coalesce(waiver_signed_at, now()) where id = p_member_id;
  update guest_passes set status = 'confirmed', waiver_signed_at = now()
   where guest_member_id = p_member_id and status = 'invited';
  perform set_config('studiior.waiver_signing', '', true);
  return jsonb_build_object('ok', true, 'waiver_signed', true);
end $$;

-- Grants for the new functions. All guarded inside; callable by a signed-in
-- client, none by anon.
revoke execute on function free_first_eligibility(uuid, uuid)  from public, anon;
revoke execute on function book_first_free(uuid)               from public, anon;
revoke execute on function free_first_report(uuid)             from public, anon;
revoke execute on function dashboard_free_first_kpi(uuid)      from public, anon;
grant  execute on function free_first_eligibility(uuid, uuid)  to authenticated, service_role;
grant  execute on function book_first_free(uuid)               to authenticated;
grant  execute on function free_first_report(uuid)             to authenticated, service_role;
grant  execute on function dashboard_free_first_kpi(uuid)      to authenticated, service_role;

-- The anon surface must STILL be exactly ten — a drop-and-recreate of a pre-login
-- surface is exactly how an eleventh would arrive unnoticed.
do $$
declare v_oid oid := 'studio_by_slug(text)'::regprocedure;
begin
  if not has_function_privilege('anon', v_oid, 'execute') then
    raise exception 'free_first: studio_by_slug lost the anon grant the login screen needs';
  end if;
  if not has_function_privilege('authenticated', v_oid, 'execute') then
    raise exception 'free_first: studio_by_slug lost the authenticated grant';
  end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and has_function_privilege('anon', p.oid, 'execute')
         and p.proname not in (select proname from (
           -- test helpers a suite defines but no migration does are not surface
           select 'expect'::text as proname) x)
         and p.proname not like 'expect%'
         and p.proname not in ('login','sig','psig','t_late_cancel')) <> 10
  then
    raise exception 'free_first: the anon surface is no longer exactly ten';
  end if;
end $$;
