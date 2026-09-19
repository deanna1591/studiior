-- =============================================================================
-- 164  Decision 34 Part A: the waiver is a real, versioned, signed document.
-- =============================================================================
-- Until now "signed the waiver" was a bare members.waiver_signed_at timestamp:
-- no studio-supplied text (studio_settings.waiver_text was never read), nothing
-- shown to the member, nothing recorded about what was agreed. Part A adds the
-- versioned source, the signing record, the member-self write path to the signed
-- document, and the re-sign gate in book_class rule 2.1.4. Part B (later) adds
-- the guest-pass re-sign check and the setup checklist item.
--
-- NO SERVICE-ROLE CLIENT. The signed PDF and the signature PNG are written to
-- the member's own member-documents folder by the member's own session (a new
-- member-self storage policy), and the rows are inserted by a SECURITY DEFINER
-- self-sign function (which bypasses the desk-only row policies as the owner).
-- record_document stays the desk/paper path, unchanged.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. waiver_versions — the studio's waiver, text or PDF, versioned + immutable.
-- -----------------------------------------------------------------------------
create table if not exists waiver_versions (
  id              uuid primary key default gen_random_uuid(),
  studio_id       uuid not null references studios on delete cascade,
  format          text not null check (format in ('text','pdf')),
  body            text,           -- text format
  storage_path    text,           -- pdf format: object in studio-branding
  content_hash    text not null,  -- sha256 of the body (text) or the file (pdf)
  requires_resign boolean not null default false,
  created_by      uuid references profiles on delete set null,
  created_at      timestamptz not null default now(),
  constraint waiver_versions_shape check (
    (format = 'text' and body is not null and storage_path is null) or
    (format = 'pdf'  and storage_path is not null and body is null))
);
create index if not exists waiver_versions_studio on waiver_versions (studio_id, created_at desc);
comment on table waiver_versions is
  'Decision 34. One row per published waiver version; the latest by created_at '
  'is the current one. Immutable — a new version supersedes, never edits.';

alter table waiver_versions enable row level security;
-- Staff of the studio read it; managers write it (only through set_waiver_version,
-- which is the guarded writer). Members never read the table directly — they get
-- the current version through current_waiver().
create policy waiver_versions_staff_read on waiver_versions for select
  using (is_desk_up(studio_id));
create policy waiver_versions_manager_write on waiver_versions for all
  using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));
grant select, insert, update, delete on waiver_versions to authenticated;
grant all on waiver_versions to service_role;

-- -----------------------------------------------------------------------------
-- 2. waiver_signatures — who signed which version, and the provenance.
-- -----------------------------------------------------------------------------
create table if not exists waiver_signatures (
  id             uuid primary key default gen_random_uuid(),
  studio_id      uuid not null references studios on delete cascade,
  member_id      uuid not null references members on delete cascade,
  version_id     uuid not null references waiver_versions on delete restrict,
  content_hash   text not null,           -- copied from the version, not client
  signature_path text,                     -- PNG in the member's folder; null for a paper signing
  method         text not null default 'app' check (method in ('app','paper')),
  document_id    uuid references member_documents on delete set null,  -- the signed PDF
  signed_name    text not null,           -- the member row's name, not client input
  signed_at      timestamptz not null default now(),
  user_id        uuid,                    -- auth.uid() at signing
  user_agent     text,
  ip             inet,                    -- best-effort, where the headers carry it
  created_at     timestamptz not null default now()
);
create index if not exists waiver_signatures_member on waiver_signatures (member_id, signed_at desc);
comment on table waiver_signatures is
  'Decision 34. One row per signing. The signature image lives in the member''s '
  'member-documents folder; this keeps the path, never the bytes.';

alter table waiver_signatures enable row level security;
-- Staff of the studio read all; a member reads their own. No client INSERT — the
-- SECURITY DEFINER sign_waiver_document is the only writer.
create policy waiver_sig_staff_read on waiver_signatures for select
  using (is_desk_up(studio_id));
create policy waiver_sig_self_read on waiver_signatures for select
  using (member_id in (select id from members where user_id = auth.uid()));
grant select on waiver_signatures to authenticated;
grant all on waiver_signatures to service_role;

-- -----------------------------------------------------------------------------
-- 3. Member-self write to member-documents. Every existing write policy on this
--    bucket is desk-only; Decision 34 lets a member write into their OWN folder
--    (foldername[2] = their member id) so they can save their signed PDF and
--    signature PNG with their own session. Same shape as member-avatars owner-write.
-- -----------------------------------------------------------------------------
drop policy if exists "member writes own documents" on storage.objects;
create policy "member writes own documents" on storage.objects for insert
  with check (bucket_id = 'member-documents'
    and exists (select 1 from members m
                 where m.id = ((storage.foldername(name))[2])::uuid
                   and m.user_id = auth.uid()));

-- -----------------------------------------------------------------------------
-- 4. set_waiver_version — the guarded writer (Settings → Member features).
--    Manager-up. Text hashes its own body; a PDF's hash is the file's sha256,
--    computed by the Next upload action and passed in.
-- -----------------------------------------------------------------------------
create or replace function set_waiver_version(
  p_studio_id uuid, p_format text, p_body text default null,
  p_storage_path text default null, p_content_hash text default null,
  p_requires_resign boolean default false
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_hash text; v_id uuid;
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers set the waiver' using errcode = 'PT403';
  end if;
  if p_format = 'text' then
    if nullif(btrim(coalesce(p_body,'')), '') is null then
      raise exception 'the waiver text is empty' using errcode = 'PT422';
    end if;
    v_hash := encode(digest(p_body, 'sha256'), 'hex');
    insert into waiver_versions (studio_id, format, body, content_hash, requires_resign, created_by)
    values (p_studio_id, 'text', p_body, v_hash, coalesce(p_requires_resign,false), auth.uid())
    returning id into v_id;
  elsif p_format = 'pdf' then
    if nullif(btrim(coalesce(p_storage_path,'')), '') is null
       or nullif(btrim(coalesce(p_content_hash,'')), '') is null then
      raise exception 'a PDF version needs a stored file and its hash' using errcode = 'PT422';
    end if;
    insert into waiver_versions (studio_id, format, storage_path, content_hash, requires_resign, created_by)
    values (p_studio_id, 'pdf', p_storage_path, p_content_hash, coalesce(p_requires_resign,false), auth.uid())
    returning id into v_id;
  else
    raise exception 'format must be text or pdf' using errcode = 'PT422';
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (p_studio_id, auth.uid(), 'waiver.version_published', 'waiver_versions', v_id,
          jsonb_build_object('format', p_format, 'requires_resign', coalesce(p_requires_resign,false)));
  return jsonb_build_object('ok', true, 'version_id', v_id, 'content_hash', v_hash);
end $$;
revoke execute on function set_waiver_version(uuid, text, text, text, text, boolean) from public, anon;
grant  execute on function set_waiver_version(uuid, text, text, text, text, boolean) to authenticated;

-- -----------------------------------------------------------------------------
-- 5. current_waiver — what the member's signing screen (and staff editor) reads:
--    the current version, plus whether THIS member has already signed it. A
--    member of the studio or its staff. Null when the studio has none.
-- -----------------------------------------------------------------------------
create or replace function current_waiver(p_studio_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v waiver_versions%rowtype; v_member uuid; v_signed boolean := false;
begin
  if not (exists (select 1 from members where studio_id = p_studio_id and user_id = auth.uid())
          or coalesce(is_desk_up(p_studio_id), false)) then
    raise exception 'not your studio' using errcode = 'PT403';
  end if;
  select * into v from waiver_versions where studio_id = p_studio_id
   order by created_at desc limit 1;
  if not found then
    return jsonb_build_object('exists', false);
  end if;
  select id into v_member from members where studio_id = p_studio_id and user_id = auth.uid();
  if v_member is not null then
    v_signed := exists (select 1 from waiver_signatures where member_id = v_member and version_id = v.id);
  end if;
  return jsonb_build_object(
    'exists', true, 'version_id', v.id, 'format', v.format,
    'body', v.body, 'storage_path', v.storage_path, 'content_hash', v.content_hash,
    'requires_resign', v.requires_resign, 'signed', v_signed);
end $$;
revoke execute on function current_waiver(uuid) from public, anon;
grant  execute on function current_waiver(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 6. sign_waiver_document — the member's self-sign. SECURITY DEFINER so it can
--    insert the desk-only member_documents row and set waiver_signed_at as the
--    owner. The Next action has already uploaded the signed PDF and the PNG to
--    the member's own folder (the storage policy above) and passes their paths.
--    The NAME is derived from the member row here, never trusted from the client.
--    The version must be the current one, and its hash must match.
-- -----------------------------------------------------------------------------
create or replace function sign_waiver_document(
  p_member_id uuid, p_version_id uuid, p_content_hash text,
  p_document_path text, p_document_filename text, p_document_size int,
  p_signature_path text, p_user_agent text default null, p_ip text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m members%rowtype; v waiver_versions%rowtype; v_name text; v_doc uuid; v_sig uuid;
begin
  select * into m from members where id = p_member_id;
  if not found then raise exception 'no such member' using errcode = 'PT404'; end if;
  -- Self only. The signature is tied to the person the studio knows.
  if not coalesce(m.user_id = auth.uid(), false) then
    raise exception 'that is not your waiver to sign' using errcode = 'PT403';
  end if;

  select * into v from waiver_versions where id = p_version_id and studio_id = m.studio_id;
  if not found then raise exception 'no such waiver version' using errcode = 'PT404'; end if;
  -- Must be the CURRENT version, and the hash must match what was shown.
  if v.id <> (select id from waiver_versions where studio_id = m.studio_id
               order by created_at desc limit 1) then
    raise exception 'the waiver has changed — reload and sign the current version'
      using errcode = 'PT409';
  end if;
  if v.content_hash <> p_content_hash then
    raise exception 'waiver content mismatch' using errcode = 'PT409';
  end if;

  v_name := btrim(coalesce(m.first_name,'') || ' ' || coalesce(m.last_name,''));

  -- The signed PDF as a member document (kind waiver), which is what staff see.
  insert into member_documents
    (studio_id, member_id, kind, filename, storage_path, mime_type, size_bytes,
     note, uploaded_by, signed_at)
  values (m.studio_id, p_member_id, 'waiver', p_document_filename, p_document_path,
          'application/pdf', p_document_size, 'Signed in the app', auth.uid(), now())
  returning id into v_doc;

  insert into waiver_signatures
    (studio_id, member_id, version_id, content_hash, signature_path, document_id,
     signed_name, user_id, user_agent, ip)
  values (m.studio_id, p_member_id, v.id, v.content_hash, p_signature_path, v_doc,
          v_name, auth.uid(), nullif(p_user_agent,''), nullif(p_ip,'')::inet)
  returning id into v_sig;

  -- The booking gate. guard_member_self_update() protects waiver_signed_at from
  -- the member, so the flag opens it for this one write (as sign_waiver does).
  perform set_config('studiior.waiver_signing', '1', true);
  update members set waiver_signed_at = coalesce(waiver_signed_at, now()) where id = p_member_id;
  -- Confirm any guest pass the same way sign_waiver does.
  update guest_passes set status = 'confirmed', waiver_signed_at = now()
   where guest_member_id = p_member_id and status = 'invited';
  perform set_config('studiior.waiver_signing', '', true);

  return jsonb_build_object('ok', true, 'document_id', v_doc, 'signature_id', v_sig,
                            'signed_name', v_name);
end $$;
revoke execute on function sign_waiver_document(uuid, uuid, text, text, text, int, text, text, text) from public, anon;
grant  execute on function sign_waiver_document(uuid, uuid, text, text, text, int, text, text, text) to authenticated;

-- -----------------------------------------------------------------------------
-- 7. book_class rule 2.1.4 gains the re-sign check. Re-issued from migration 163
--    (proven the newest by a sorted grep of every book_class definition before
--    this drop). create-or-replace keeps the ACL.
-- -----------------------------------------------------------------------------
create or replace function public.book_class(p_occurrence_id uuid, p_member_id uuid, p_source booking_source, p_override_reason text DEFAULT NULL::text, p_payment_source payment_source DEFAULT NULL::payment_source)
 RETURNS book_class_result
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_result       book_class_result;
  v_occ          class_occurrences%rowtype;
  v_member       members%rowtype;
  v_set          studio_settings%rowtype;
  v_tz           text;

  v_actor        uuid := auth.uid();
  v_caller_role  text;
  v_trusted      boolean;
  v_is_desk      boolean;
  v_is_self      boolean;
  v_override     boolean := false;
  v_bypassed     text[] := '{}';
  v_comp         boolean := false;
  -- 'booked' unless the member is paying for a drop-in themselves, in which
  -- case the seat is held as 'pending_payment' until Stripe says otherwise.
  v_status       booking_status := 'booked';

  v_window_days  int;
  v_max_per_day  int;
  v_day_count    int;
  v_future_count int;
  v_today        date;

  v_cand         record;
  v_covers       boolean;
  v_restricted   boolean := false;   -- a live plan was blocked purely on class type
  v_peak         jsonb;             -- Decision 24: the paying plan's peak allowance, or null
  v_susp         jsonb;             -- Decision 24: where this member stands on the ladder
  v_pay          payment_source;
  v_membership   uuid;
  v_consume      boolean := false;

  v_booking_id   uuid;
  v_ledger_id    uuid;
  v_balance      int;
  v_position     int;
  v_full         boolean;
  v_phys_full    boolean;   -- capacity reached by REAL seats
  v_held         int;       -- §4.2: seats a live waitlist offer is holding for someone else
begin
  -- ===========================================================================
  -- 0. Locate and authorise. Nothing is written before this passes.
  -- ===========================================================================

  select * into v_occ from class_occurrences where id = p_occurrence_id;
  if not found then
    return (null, null, null, null, 'not_found')::book_class_result;
  end if;

  -- Lockout (migration 044). The studio's own subscription to Studiior has
  -- lapsed past its grace period. Reads stay open everywhere so nothing looks
  -- lost; this is one of the four places where DOING something stops.
  if studio_is_locked(v_occ.studio_id) then
    raise exception 'this studio''s Studiior subscription is not active'
      using errcode = 'PT402',
            hint = 'Reactivate it from Billing. Nothing has been deleted.';
  end if;

  select * into v_member from members where id = p_member_id;
  if not found then
    return (null, null, null, null, 'member_not_found')::book_class_result;
  end if;
  if v_member.studio_id <> v_occ.studio_id then
    return (null, null, null, null, 'member_wrong_studio')::book_class_result;
  end if;

  select * into v_set from studio_settings where studio_id = v_occ.studio_id;
  select timezone into v_tz from studios where id = v_occ.studio_id;

  -- --- Trust is a property of the ROLE, never of a missing auth.uid() -------
  --
  -- A null auth.uid() proves nothing: an `authenticated` caller whose JWT
  -- carries no `sub` claim has one too, and migration 002 handed that caller
  -- full booking rights over every member in the studio.
  --
  -- current_user is useless here — inside a security definer function it is
  -- always the function owner, not the caller. The caller's effective role is
  -- the `role` GUC, which is what PostgREST sets per request and what SET ROLE
  -- sets in a direct session; it is NOT changed by security definer entry.
  -- 'none' means no SET ROLE happened at all, i.e. a direct login session.
  --
  -- rolbypassrls is the honest test of "already privileged above RLS":
  -- service_role, postgres and supabase_admin have it, and gain nothing from
  -- this function that they could not do by writing the tables directly.
  -- authenticated, anon and authenticator do not have it.
  v_caller_role := coalesce(nullif(current_setting('role', true), 'none'),
                            session_user);
  v_trusted := exists (
    select 1 from pg_roles
     where rolname = v_caller_role
       and (rolsuper or rolbypassrls)
  );

  v_is_desk := coalesce(is_desk_up(v_occ.studio_id), false);
  v_is_self := v_actor is not null
               and v_member.user_id is not null
               and v_member.user_id = v_actor;

  if not (v_trusted or v_is_desk or v_is_self) then
    return (null, null, null, null, 'not_authorised')::book_class_result;
  end if;
  -- A member may only book as themselves, and never on a staff source.
  if not (v_trusted or v_is_desk) and p_source <> 'member' then
    return (null, null, null, null, 'not_authorised')::book_class_result;
  end if;

  -- --- §2.4 comp -----------------------------------------------------------
  -- payment_source is otherwise resolved, never chosen (§2.2). 'comp' is the
  -- single exception the business rules allow, and it is staff-only.
  if p_payment_source is not null then
    if p_payment_source <> 'comp' then
      return (null, null, null, null, 'unsupported_payment_source')
             ::book_class_result;
    end if;
    if not (v_trusted or v_is_desk) then
      return (null, null, null, null, 'not_authorised')::book_class_result;
    end if;
    v_comp := true;
  end if;

  -- Business Rules §2.3: overrides are front desk and above only, and always
  -- carry a reason. Rules 1 (past/cancelled), 4 (waiver) and 6 (duplicate)
  -- stay unoverridable below.
  v_override := p_override_reason is not null
                and btrim(p_override_reason) <> ''
                and (v_trusted or v_is_desk);

  -- ===========================================================================
  -- 1. THE LOCK. Data Model §6 — before anything reads booked_count.
  -- ===========================================================================

  select * into v_occ
    from class_occurrences
   where id = p_occurrence_id
     for update;

  -- Then the member row, which serialises this member's own concurrent
  -- bookings so credits_remaining and credit_ledger.balance_after stay
  -- consistent. Lock order is always occurrence -> member; the nightly expiry
  -- job and the Stripe webhook handlers must take the member lock the same way.
  select * into v_member from members where id = p_member_id for update;

  v_today := (now() at time zone v_tz)::date;

  -- ===========================================================================
  -- 2. Eligibility gate — Business Rules §2.1, in order. First failure wins.
  -- ===========================================================================

  -- 2.1.1 Occurrence is scheduled, not cancelled, not in the past. Not overridable.
  if v_occ.status = 'cancelled' then
    return (null, null, null, null, 'class_cancelled')::book_class_result;
  end if;
  if v_occ.status = 'completed' then
    return (null, null, null, null, 'class_completed')::book_class_result;
  end if;
  if v_occ.starts_at <= now() then
    return (null, null, null, null, 'class_in_past')::book_class_result;
  end if;

  -- 2.1.1b Decision 25: the class is on a PUBLISHED month. Placed with the
  -- occurrence checks and BEFORE the booking window, deliberately: an
  -- unpublished class is invisible to members under occ_member_read, so a
  -- member can only reach here with an id they cannot see, and the refusal
  -- names the reason the class is invisible rather than a rule about how far
  -- ahead their plan lets them book. That keeps the two gates composed the
  -- same way on this side as on the screen: "not published" is about the
  -- class, "outside the window" is about the member, and outside_booking_window
  -- goes on meaning exactly what it has since migration 002 — a class on the
  -- timetable that this member may not book YET. month_published() is true for
  -- every studio with the switch off, so nothing changes for them.
  -- Overridable with a reason, like the window: the desk pencilling somebody
  -- into a draft is a deliberate act and is recorded as one.
  if not month_published(v_occ.studio_id, v_occ.starts_at) then
    if v_override then
      v_bypassed := v_bypassed || 'month_not_published'::text;
    else
      return (null, null, null, null, 'month_not_published')::book_class_result;
    end if;
  end if;

  -- Plan-level overrides for rules 2 and 7 come from the member's highest
  -- priority usable plan (§2.1.2 "plan-level override wins over studio
  -- default"). Read before the gate; the paying source is resolved in §3.
  select mp.booking_window_days, mp.max_bookings_per_day
    into v_window_days, v_max_per_day
    from memberships ms
    join membership_plans mp on mp.id = ms.plan_id
   where ms.member_id  = p_member_id
     and ms.studio_id  = v_occ.studio_id
     and ms.status in ('active','trialing')
     and (ms.expires_on is null or ms.expires_on >= v_today)
     and (mp.booking_window_days is not null or mp.max_bookings_per_day is not null)
   order by case mp.type when 'recurring' then 1 when 'trial' then 2 else 3 end,
            ms.expires_on asc nulls last
   limit 1;

  v_window_days := coalesce(v_window_days, v_set.booking_window_days);
  v_max_per_day := coalesce(v_max_per_day, v_set.max_bookings_per_day);

  -- 2.1.2 Booking window.
  if not v_override then
    if v_occ.starts_at > now() + make_interval(days => v_window_days) then
      return (null, null, null, null, 'outside_booking_window')::book_class_result;
    end if;
  elsif v_occ.starts_at > now() + make_interval(days => v_window_days) then
    v_bypassed := v_bypassed || 'booking_window'::text;
  end if;

  -- 2.1.3 Booking cutoff. Default 0 — booking allowed right up to start.
  if not v_override then
    if v_occ.starts_at < now() + make_interval(mins => v_set.booking_cutoff_minutes) then
      return (null, null, null, null, 'past_booking_cutoff')::book_class_result;
    end if;
  elsif v_occ.starts_at < now() + make_interval(mins => v_set.booking_cutoff_minutes) then
    v_bypassed := v_bypassed || 'booking_cutoff'::text;
  end if;

  -- 2.1.3b Decision 30 belt: a self-serve LEAD owed a free first class must
  -- spend it on the free path (book_first_free), not a paid drop-in. Gated on
  -- status = 'lead' — Decision 15's self-signup with no plan; an active member
  -- (including one bringing a guest through book_guest, which books their own
  -- seat here) is never a lead and books normally. Fires only when they book
  -- themselves (not desk/override) and are still eligible, and before the waiver
  -- gate, so a fresh unsigned lead is routed to the free path (which gates the
  -- waiver at check-in) rather than told to sign. The switch off makes
  -- free_first_eligibility return ok=false, so nothing here fires.
  if v_is_self and not (v_is_desk or v_trusted or v_override)
     and v_member.status = 'lead'
     and (free_first_eligibility(v_occ.studio_id, v_member.id) ->> 'ok')::boolean then
    return (null, null, null, null, 'use_free_first')::book_class_result;
  end if;

  -- 2.1.4 Waiver. Not overridable. Decision 34: a signature is tied to a waiver
  -- version, and a NEW version marked requires_resign turns an older signature
  -- stale — a member who signed only an earlier required version is treated as
  -- unsigned. A studio with no version yet is unaffected (the current-version
  -- subquery finds nothing), so existing bare-timestamp signatures stand.
  if v_set.require_waiver then
    if v_member.waiver_signed_at is null then
      return (null, null, null, null, 'waiver_not_signed')::book_class_result;
    end if;
    if exists (
      select 1 from waiver_versions wv
       where wv.studio_id = v_occ.studio_id
         and wv.requires_resign
         and wv.created_at = (select max(created_at) from waiver_versions
                               where studio_id = v_occ.studio_id)
         and not exists (select 1 from waiver_signatures ws
                          where ws.member_id = v_member.id and ws.version_id = wv.id))
    then
      return (null, null, null, null, 'waiver_not_signed')::book_class_result;
    end if;
  end if;

  -- 2.1.5 Member status — Decision 15. A `lead` passes here, and is held to
  -- drop-in by the guard after §2.2 resolution below.
  if not book_class_status_ok(v_member.status) then
    return (null, null, null, null, 'member_not_active')::book_class_result;
  end if;

  -- 2.1.6 No existing live booking for this occurrence. Not overridable.
  -- Mirrors the bookings_one_live_per_member partial unique index.
  if exists (
    select 1 from bookings
     where occurrence_id = p_occurrence_id
       and member_id     = p_member_id
       and status in ('booked','waitlisted','attended','no_show','pending_payment')
  ) then
    -- 'pending_payment' is in this list, and deliberately NOT in the daily or
    -- forward limit counts below: a member may not start two checkouts for the
    -- same class, but three abandoned checkouts must not exhaust the limits on
    -- classes they never paid for.
    return (null, null, null, null, 'already_booked')::book_class_result;
  end if;

  -- 2.1.7 Daily limit, counted in studio-local days.
  if v_max_per_day is not null then
    select count(*) into v_day_count
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
     where b.member_id = p_member_id
       and b.studio_id = v_occ.studio_id
       and b.status in ('booked','waitlisted','attended','no_show')
       and (o.starts_at at time zone v_tz)::date
         = (v_occ.starts_at at time zone v_tz)::date;

    if v_day_count >= v_max_per_day then
      if v_override then
        v_bypassed := v_bypassed || 'daily_limit'::text;
      else
        return (null, null, null, null, 'daily_limit_reached')::book_class_result;
      end if;
    end if;
  end if;

  -- 2.1.8 Forward limit on live future bookings.
  if v_set.max_future_bookings is not null then
    select count(*) into v_future_count
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
     where b.member_id = p_member_id
       and b.studio_id = v_occ.studio_id
       and b.status in ('booked','waitlisted')
       and o.starts_at > now();

    if v_future_count >= v_set.max_future_bookings then
      if v_override then
        v_bypassed := v_bypassed || 'future_limit'::text;
      else
        return (null, null, null, null, 'future_limit_reached')::book_class_result;
      end if;
    end if;
  end if;

  -- ===========================================================================
  -- 3. Payment source resolution — Business Rules §2.2, Decision 1.
  --    unlimited membership -> limited membership allowance -> pack credits
  --    soonest expiry first -> drop-in. The member never chooses.
  --    Consumed at booking time, not at attendance (§2.2, §6).
  -- ===========================================================================

  if v_comp then
    -- §2.4: nothing consumed, nothing charged. The booking is an ordinary
    -- 'booked' row, so check-in, challenges and milestones count it exactly
    -- like any other attendance. Rule 2.1.9 is vacuous — no membership is
    -- paying, so no membership's class-type restriction applies.
    v_pay     := 'comp';
    v_consume := false;
  else
    for v_cand in
      select ms.id,
             ms.credits_remaining,
             mp.restrictions,
             case
               -- credits_per_period null on a recurring plan == unlimited
               -- (Data Model §7).
               when mp.type in ('recurring','trial')
                    and mp.credits_per_period is null
                    and ms.credits_remaining is null              then 1
               when mp.type in ('recurring','trial')
                    and coalesce(ms.credits_remaining, 0) > 0     then 2
               when mp.type = 'class_pack'
                    and coalesce(ms.credits_remaining, 0) > 0     then 3
               else 99
             end as priority
        from memberships ms
        join membership_plans mp on mp.id = ms.plan_id
       where ms.member_id = p_member_id
         and ms.studio_id = v_occ.studio_id
         -- §7.3 / Decision 4: past_due blocks NEW bookings only once the
         -- studio's grace period has run out.
         and (
               ms.status in ('active','trialing')
            or (ms.status = 'past_due'
                and now() < coalesce(ms.current_period_end, now())
                            + make_interval(days => v_set.payment_grace_days))
         )
         -- §7.4: a frozen membership cannot book.
         and not (ms.freeze_start is not null and ms.freeze_end is not null
                  and v_today between ms.freeze_start and ms.freeze_end)
         -- §6: a credit cannot be spent past its expiry.
         and (ms.expires_on is null or ms.expires_on >= v_today)
       order by priority,
                ms.expires_on asc nulls last,   -- soonest expiry first
                ms.created_at asc
    loop
      exit when v_cand.priority = 99;

      -- §2.1.9 plan restrictions: an empty or absent class_type_ids covers
      -- everything.
      v_covers := (v_cand.restrictions -> 'class_type_ids') is null
               or jsonb_typeof(v_cand.restrictions -> 'class_type_ids') <> 'array'
               or jsonb_array_length(v_cand.restrictions -> 'class_type_ids') = 0
               or (v_occ.class_type_id is not null
                   and jsonb_exists(v_cand.restrictions -> 'class_type_ids',
                                    v_occ.class_type_id::text));

      if not v_covers then
        v_restricted := true;   -- remembered for the §2.1.9 failure below
        continue;
      end if;

      v_pay        := case when v_cand.priority in (1, 2)
                           then 'membership'::payment_source
                           else 'class_pack'::payment_source end;
      v_membership := v_cand.id;
      v_consume    := v_cand.priority in (2, 3);
      exit;
    end loop;

    if v_pay is null then
      -- §2.1.9: the member holds a live plan and it does not cover this class
      -- type. That is a specific refusal, not a silent fall-through to drop-in.
      if v_restricted then
        if v_override then
          v_bypassed := v_bypassed || 'plan_restriction'::text;
        else
          return (null, null, null, null, 'class_type_not_in_plan')::book_class_result;
        end if;
      end if;
      -- §2.2 priority 4: nothing covers it, so the class is a drop-in. The
      -- charge itself is a payments row raised by the caller against the
      -- returned booking; no credit is consumed here.
      v_pay := 'drop_in';
    end if;
  end if;

  -- The seat is held while the member pays for it.
  --
  -- Only when the MEMBER is booking their own drop-in and the studio has a
  -- connected Stripe account. A staff booking at the desk is money changing
  -- hands in the room, and a studio with no Stripe connected has no checkout to
  -- send anyone to — both of those still book outright, exactly as before, which
  -- is also why every existing fixture in the suite is unaffected.
  if v_pay = 'drop_in' and p_source = 'member'
     and exists (
       select 1 from studios s
        where s.id = v_occ.studio_id and s.stripe_account_id is not null
     )
  then
    v_status := 'pending_payment';
  end if;

  -- Decision 15's second half, after §2.2 has resolved who pays. A lead has
  -- bought nothing, so it should always be drop-in by this point; if it is
  -- not, staff have attached a plan to somebody they never activated, and
  -- spending its credits is not what `lead` is meant to allow.
  if v_member.status = 'lead' and v_pay <> 'drop_in' then
    return (null, null, null, null, 'member_not_active')::book_class_result;
  end if;

  -- ===========================================================================
  -- 2.1.9 SUSPENSION — Decision 24.
  --
  -- In the §2.1 gate and not beside the peak rule, because it has nothing to do
  -- with which plan pays: a suspended member is suspended whatever they were
  -- going to book it with, including a drop-in they would have paid cash for.
  --
  -- IT RESTRICTS ADVANCE BOOKING ONLY. Same-day still works, on whatever seats
  -- are left — the penalty is losing the ability to hold a place ahead of
  -- everyone else, not being shut out of the studio. A suspension that stopped
  -- somebody walking in would cost the studio the sale as well as the member the
  -- class, and it would be a harsher thing than any studio described wanting.
  --
  -- The allowance still applies on top: a suspension does not hand out free peak
  -- slots, and a member with nothing left is refused by the rule below whether
  -- or not they are suspended.
  --
  -- Overridable, like the other capacity-shaped rules. A studio that wants to
  -- let somebody in anyway has heard the reason at the counter.
  -- ===========================================================================
  v_susp := member_suspension(p_member_id);
  if v_susp is not null and (v_susp ->> 'suspended')::boolean
     and (v_occ.starts_at at time zone v_tz)::date > v_today
  then
    if v_override then
      v_bypassed := v_bypassed || 'suspended'::text;
    else
      return (null, null, null, null, 'suspended')::book_class_result;
    end if;
  end if;

  -- ===========================================================================
  -- 3b. THE PEAK ALLOWANCE — Decision 24.
  --
  -- AFTER §2.2, and that placement is the whole correctness argument: the plan
  -- that PAYS is the plan held to its allowance. Resolving it up in the §2.1
  -- gate would mean a second plan-priority query beside the one rules 2 and 7
  -- use, and the two would pick the same plan right up until they did not —
  -- a member holding both an unlimited plan and a pack would have the pack's
  -- booking measured against the unlimited plan's allowance.
  --
  -- Only a membership can consume one. A drop-in and a pack cannot carry an
  -- allowance at all (migration 104's CHECK), so `v_pay = 'membership'` is not
  -- an optimisation, it is the rule.
  --
  -- peak_allowance_state() answers null for a plan with no allowance AND for a
  -- studio with the switch off, so a studio that has never heard of this
  -- feature takes one null check and nothing else.
  --
  -- WAITLISTING NEEDS NO SPECIAL CASE. This refuses before §4, so a member with
  -- nothing left cannot join the queue for a peak class either — which is the
  -- honest answer, rather than letting them wait for an offer they could not
  -- accept. And nothing is CONSUMED here: the ledger row is written by the
  -- trigger when a seat actually becomes real, so a waitlisted row costs
  -- nothing and a promotion costs one. `respond_to_offer()` cancels the
  -- waitlist row and calls this function again, so a promotion is measured
  -- against the allowance as it stands at that moment, not at join time.
  -- ===========================================================================
  if v_pay = 'membership' and v_membership is not null
     and occurrence_is_peak(p_occurrence_id)
  then
    v_peak := peak_allowance_state(v_membership,
                                   (v_occ.starts_at at time zone v_tz)::date);
    if v_peak is not null and (v_peak ->> 'remaining')::int <= 0 then
      if v_override then
        v_bypassed := v_bypassed || 'peak_allowance'::text;
      else
        return (null, null, null, null, 'peak_allowance_exhausted')::book_class_result;
      end if;
    end if;
  end if;

  -- ===========================================================================
  -- 4. Capacity — §2.1.10, §4.1, §5. booked_count was read under the lock.
  -- ===========================================================================

  -- §4.2: a pending waitlist offer HOLDS its seat — the offered member was
  -- formally offered it, and general booking must not take it from under them.
  -- Derived from live offers at gate time rather than cached: booked_count goes
  -- on counting real seats only, so the nightly reconcile stays a no-op, and the
  -- hold ends the instant the offer does (expired-but-unswept offers hold
  -- nothing — occurrence_seats_held gates on expires_at > now()). The offered
  -- member's own offer is excluded, or accepting through respond_to_offer would
  -- be refused for the very seat they were offered.
  v_held      := occurrence_seats_held(p_occurrence_id, p_member_id);
  v_phys_full := v_occ.booked_count >= v_occ.capacity;
  v_full      := (v_occ.booked_count + v_held) >= v_occ.capacity;

  if v_full and not v_override then
    if not v_set.waitlist_enabled then
      return (null, null, null, null, 'class_full')::book_class_result;
    end if;

    -- §4.4: no promotions inside waitlist_cutoff_minutes, so joining there is
    -- an offer that can never be made.
    if v_occ.starts_at < now() + make_interval(mins => v_set.waitlist_cutoff_minutes) then
      return (null, null, null, null, 'waitlist_closed')::book_class_result;
    end if;

    -- §4.1: strictly FIFO, no priority tiers in V1, and NO credit consumed on
    -- joining. The paying source is re-resolved when the offer is accepted
    -- (§4.2.4), so it is deliberately left null on the row — including for a
    -- comp, whose comp intent must be supplied again at promotion.
    select coalesce(max(waitlist_position), 0) + 1
      into v_position
      from bookings
     where occurrence_id = p_occurrence_id
       and status = 'waitlisted';

    insert into bookings (
      studio_id, occurrence_id, member_id, status, source,
      payment_source, membership_id, waitlist_position
    ) values (
      v_occ.studio_id, p_occurrence_id, p_member_id, 'waitlisted', p_source,
      null, null, v_position
    ) returning id into v_booking_id;

    update class_occurrences
       set waitlist_count = waitlist_count + 1
     where id = p_occurrence_id;

    return (v_booking_id, 'waitlisted'::booking_status, null, v_position, null)
           ::book_class_result;
  end if;

  if v_full then
    -- §2.3 / §5 / §14: a staff override reaches here. Two shapes, told apart for
    -- the audit: physically full is a walk-in booked OVER capacity; held-only is
    -- the desk deliberately taking a seat reserved for a waitlisted member (the
    -- offer stands and will fail on acceptance — a deliberate act, §14). The hold
    -- is never applied to an override, so front desk can always seat someone.
    if v_phys_full then
      v_bypassed := v_bypassed || 'capacity'::text;
    else
      v_bypassed := v_bypassed || 'held_seat'::text;
    end if;
  end if;

  -- ===========================================================================
  -- 5. Write. Booking, ledger and booked_count, one transaction.
  -- ===========================================================================

  insert into bookings (
    studio_id, occurrence_id, member_id, status, source,
    payment_source, membership_id, override_reason, overridden_rules
  ) values (
    v_occ.studio_id, p_occurrence_id, p_member_id, v_status, p_source,
    v_pay, case when v_pay in ('membership','class_pack') then v_membership end,
    -- §2.3: a reason that bypassed nothing was not an override, so it is not
    -- recorded as one.
    case when array_length(v_bypassed, 1) is not null then p_override_reason end,
    case when array_length(v_bypassed, 1) is not null then v_bypassed end
  ) returning id into v_booking_id;

  if v_consume then
    -- §6: the balance is derived from the ledger, never edited in place, and
    -- every row carries balance_after so any point in history is
    -- reconstructable without replaying. balance_after is the member's total
    -- credit balance across every source; the member row lock above makes the
    -- read-then-write safe.
    select coalesce(sum(delta), 0) into v_balance
      from credit_ledger
     where studio_id = v_occ.studio_id
       and member_id = p_member_id;

    insert into credit_ledger (
      studio_id, member_id, membership_id, delta, reason,
      booking_id, balance_after, expires_at, actor_user_id
    )
    select v_occ.studio_id, p_member_id, v_membership, -1, 'booking',
           v_booking_id, v_balance - 1,
           case when ms.expires_on is not null
                then (ms.expires_on + 1)::timestamp at time zone v_tz end,
           v_actor
      from memberships ms
     where ms.id = v_membership
    returning id into v_ledger_id;

    -- credits_remaining is a cache. Written in the same transaction as the
    -- ledger row, never independently of it.
    update memberships
       set credits_remaining = credits_remaining - 1
     where id = v_membership;

    update bookings set credit_entry_id = v_ledger_id where id = v_booking_id;
  end if;

  update class_occurrences
     set booked_count = booked_count + 1
   where id = p_occurrence_id;

  -- §2.3 / §13: every override that actually bypassed a rule is audited with
  -- actor and reason. The booking row carries the same reason (above) so it is
  -- visible without a join to audit_logs.
  if v_override and array_length(v_bypassed, 1) is not null then
    insert into audit_logs (
      studio_id, actor_user_id, action, entity_table, entity_id, after
    ) values (
      v_occ.studio_id, v_actor, 'booking.override', 'bookings', v_booking_id,
      jsonb_build_object(
        'reason',        p_override_reason,
        'rules_bypassed', to_jsonb(v_bypassed),
        'occurrence_id', p_occurrence_id,
        'member_id',     p_member_id,
        'over_capacity', v_occ.booked_count + 1 > v_occ.capacity
      )
    );
  end if;

  -- The caller needs to know it is holding rather than booked, because that is
  -- what decides whether the member is sent to Checkout next.
  return (v_booking_id, v_status, v_pay, null, null)
         ::book_class_result;
end $function$;

-- create-or-replace keeps book_class's ACL (authenticated); re-assert for safety.
revoke execute on function public.book_class(uuid, uuid, booking_source, text, payment_source) from public, anon;
grant  execute on function public.book_class(uuid, uuid, booking_source, text, payment_source) to authenticated, service_role;

-- Nothing here is anon. Assert the surface is unchanged at apply time.
do $$
declare v_n int;
begin
  select count(*) into v_n from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
   where nsp.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if v_n <> 11 then raise exception 'anon surface is % functions, expected 11', v_n; end if;
end $$;
-- Decision 34: record_document records the version on a paper waiver too. Re-issued from 128.
CREATE OR REPLACE FUNCTION public.record_document(p_member_id uuid, p_kind text, p_filename text, p_storage_path text, p_mime text DEFAULT NULL::text, p_size integer DEFAULT NULL::integer, p_note text DEFAULT NULL::text, p_signed_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_studio uuid; v_id uuid; v_waiver boolean := false;
begin
  select studio_id into v_studio from members where id = p_member_id;
  if v_studio is null then
    raise exception 'no such member' using errcode = 'PT404';
  end if;
  if not is_desk_up(v_studio) then
    raise exception 'only front desk and above may file a document'
      using errcode = 'PT403';
  end if;
  if p_kind not in ('waiver','medical','id','other') then
    raise exception 'kind must be waiver, medical, id or other' using errcode = 'PT422';
  end if;

  insert into member_documents
    (studio_id, member_id, kind, filename, storage_path, mime_type, size_bytes,
     note, uploaded_by, signed_at)
  values (v_studio, p_member_id, p_kind, p_filename, p_storage_path, p_mime,
          p_size, nullif(btrim(coalesce(p_note,'')), ''), auth.uid(),
          case when p_kind = 'waiver' then coalesce(p_signed_at, now()) end)
  returning id into v_id;

  -- THE POINT OF THE WAIVER CASE. members.waiver_signed_at is §2.1's booking
  -- gate and has been set by hand since migration 001; filing the signed
  -- document is what should set it, so the gate and the paperwork agree.
  -- guard_member_self_update() protects waiver_signed_at from the MEMBER, not
  -- from the desk, and this runs as the desk.
  if p_kind = 'waiver' then
    update members
       set waiver_signed_at = coalesce(p_signed_at, now())
     where id = p_member_id and waiver_signed_at is null;
    v_waiver := found;
    -- Decision 26: a guest signs on PAPER at the door. Filing that waiver
    -- confirms their pass, the same as signing in the app — a studio hands an
    -- unsigned guest a form rather than sending them home, and the product has
    -- to be able to record it.
 
    update guest_passes
       set status = 'confirmed', waiver_signed_at = coalesce(p_signed_at, now())
     where guest_member_id = p_member_id and status = 'invited';

    -- Decision 34: if the studio has a current waiver version, record the paper
    -- signing against it too (method 'paper', no drawn image), so a filed paper
    -- waiver counts as having signed the current version for the re-sign gate.
    insert into waiver_signatures
      (studio_id, member_id, version_id, content_hash, signature_path, document_id,
       signed_name, user_id, method)
    select v_studio, p_member_id, wv.id, wv.content_hash, null, v_id,
           btrim(coalesce(mm.first_name,'') || ' ' || coalesce(mm.last_name,'')),
           auth.uid(), 'paper'
      from waiver_versions wv
      join members mm on mm.id = p_member_id
     where wv.studio_id = v_studio
       and wv.created_at = (select max(created_at) from waiver_versions where studio_id = v_studio)
       and not exists (select 1 from waiver_signatures ws
                        where ws.member_id = p_member_id and ws.version_id = wv.id);
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (v_studio, auth.uid(), 'document.filed', 'member_documents', v_id,
          jsonb_build_object('kind', p_kind, 'filename', p_filename,
                             'member_id', p_member_id, 'waiver_set', v_waiver));

  return jsonb_build_object('ok', true, 'document_id', v_id, 'waiver_signed', v_waiver);
end $function$;
