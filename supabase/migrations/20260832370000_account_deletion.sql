-- =============================================================================
-- 237 — Decision 69: member self-service account deletion.
--
-- A member deletes their OWN account from the member app, after typing DELETE.
-- Deletion SCRUBS, it does not purge: the member row is kept (so sales, refunds,
-- attendance and signed waivers stay attached for the studio's accounting and
-- legal records) with the personal fields blanked and `deleted_at` set, the auth
-- login removed, future bookings cancelled through the normal member path (so
-- seats free and the waitlist promotes, no late-cancel penalty), memberships
-- ended, marketing unsubscribed, push/device rows removed. A login that is also
-- studio staff or an instructor is refused — they contact the studio.
--
-- No new anon RPC: delete_my_account() is AUTHENTICATED ONLY and acts on
-- auth.uid() alone. Anon stays EXACTLY THIRTEEN.
--
-- creates: delete_my_account()
-- re-issues: guard_member_self_update(), member_plan_overview(uuid), campaign_audience(uuid, jsonb)
-- =============================================================================

-- The deletion marker. Nullable; null = a live member (every existing row).
alter table members add column if not exists deleted_at timestamptz;

-- One transactional confirmation email, sent to the PRE-SCRUB address (the
-- payload carries to_email, which render_notification prefers). No {first_name}
-- — the member row is scrubbed by delivery time, so the greeting is generic.
insert into notification_templates (key, subject, text_body, html_body, note) values
('account_deleted', 'Your account at {studio_name} has been deleted',
 E'Your account at {studio_name} has been deleted, as you asked.\n\nAny upcoming classes you had booked have been cancelled. Your booking and payment history is kept for the studio''s records but is no longer linked to your name.\n\nIf you did not ask for this, reply to this email and we''ll help.\n\n{studio_name}',
 E'<p>Your account at {studio_name} has been deleted, as you asked.</p><p>Any upcoming classes you had booked have been cancelled. Your booking and payment history is kept for the studio''s records but is no longer linked to your name.</p><p>If you did not ask for this, reply to this email and we''ll help.</p>',
 'Decision 69. Sent when a member deletes their own account. Always-send (account-level).')
on conflict (key) do nothing;

-- -----------------------------------------------------------------------------
-- delete_my_account() — AUTHENTICATED, acts on auth.uid() only.
-- -----------------------------------------------------------------------------
create or replace function delete_my_account()
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  m record;
  b record;
  v_studio studios%rowtype;
begin
  if v_uid is null then
    raise exception 'You are not signed in.' using errcode = 'PT401';
  end if;

  -- Refuse a login that is also studio staff or an instructor (an instructor
  -- with a login has a studio_staff row). Deleting it would break their team
  -- access — they contact the studio instead.
  if exists (select 1 from studio_staff ss where ss.user_id = v_uid) then
    raise exception 'This login is part of a studio team, so it can''t be deleted here. Please contact your studio.'
      using errcode = 'PT403';
  end if;

  -- One member row per studio this login belongs to; handle each.
  for m in select * from members where user_id = v_uid loop
    -- 1. Cancel every FUTURE non-terminal booking through the member path, so a
    --    seat frees and the waitlist promotes. free_cancel_until first, so the
    --    account's exit is never recorded as a late cancellation (no penalty).
    for b in
      select bk.id
        from bookings bk
        join class_occurrences o on o.id = bk.occurrence_id
       where bk.member_id = m.id
         and bk.status in ('booked','waitlisted','pending_payment')
         and o.starts_at > now()
    loop
      update bookings set free_cancel_until = now() + interval '1 hour' where id = b.id;
      perform cancel_booking(b.id);
    end loop;

    -- 2. End every live membership (paid and complimentary); forfeit credits.
    with ended as (
      update memberships
         set status = 'cancelled', cancelled_at = now(), credits_remaining = 0
       where member_id = m.id
         and status in ('trialing','active','past_due','frozen')
      returning id, studio_id
    )
    insert into membership_events (studio_id, membership_id, type, to_status, actor_user_id)
      select studio_id, id, 'account_deleted', 'cancelled'::membership_status, v_uid from ended;

    -- 3. The confirmation email, to the PRE-SCRUB address (m is a snapshot).
    select * into v_studio from studios where id = m.studio_id;
    perform queue_notification(
      m.studio_id, m.id, 'account_deleted',
      jsonb_build_object('to_email', m.email, 'studio_name', v_studio.name),
      'account_deleted:' || m.id, now());

    -- 4. Push / device / personal tokens.
    delete from push_subscriptions where member_id = m.id;
    delete from calendar_tokens      where member_id = m.id;

    -- 5. Scrub personal fields; set deleted_at. The name becomes "Deleted
    --    member", so every history reader (sales, rosters, attendance, timeline)
    --    shows that with no further code. status -> inactive so the member drops
    --    out of active counts; marketing off; health cleared. Email becomes a
    --    unique sentinel (the column is NOT NULL and uniquely indexed).
    --    guard_member_self_update honours studiior.account_deleting (exempting
    --    exactly the scrub columns) so the member can scrub their own row.
    perform set_config('studiior.account_deleting', '1', true);
    update members set
      first_name = 'Deleted',
      last_name = 'member',
      email = 'deleted+' || m.id || '@deleted.invalid',
      phone = null,
      date_of_birth = null,
      avatar_url = null,
      address = null,
      emergency_contact = null,
      preferred_name = null,
      source = null,
      status = 'inactive',
      marketing_opt_in = false,
      marketing_unsubscribed_at = now(),
      health_band = null, health_reason = null,
      health_signals = '[]'::jsonb, health_computed_at = null,
      deleted_at = now()
    where id = m.id;
  end loop;

  -- 6. Remove the auth login LAST. profiles.id -> auth.users is ON DELETE
  --    CASCADE, and members.user_id -> profiles is ON DELETE SET NULL, so the
  --    login and profile go and the scrubbed member rows are left unlinked.
  delete from auth.users where id = v_uid;
end $$;

revoke execute on function delete_my_account() from public, anon;
grant  execute on function delete_my_account() to authenticated;

-- -----------------------------------------------------------------------------
-- Re-issue guard_member_self_update — add the account_deleting flag branch.
-- Byte-for-byte the 20260831750000 body + a THIRD column-narrowed exemption:
-- delete_my_account() holds studiior.account_deleting around its scrub and may
-- touch ONLY the scrub columns (everything the deletion blanks/sets); anything
-- else on the row still raises, exactly like the waiver and health flags.
-- -----------------------------------------------------------------------------
create or replace function guard_member_self_update() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  owned constant text[] := array[
    'preferred_name', 'phone', 'avatar_url', 'emergency_contact',
    'address', 'date_of_birth', 'marketing_opt_in', 'updated_at'
  ];
  waiver_cols constant text[] := array['waiver_signed_at', 'updated_at'];
  health_cols constant text[] := array['health_band', 'health_reason',
                                       'health_signals', 'health_computed_at', 'updated_at'];
  -- Decision 69: the exact set delete_my_account() blanks or sets when a member
  -- deletes their own account. NARROW — the scrub columns and nothing else.
  -- user_id is here because removing the auth login cascades profiles ->
  -- members.user_id SET NULL, which fires this guard while the flag is held.
  delete_cols constant text[] := array[
    'first_name', 'last_name', 'email', 'phone', 'date_of_birth', 'avatar_url',
    'address', 'emergency_contact', 'preferred_name', 'source', 'status',
    'marketing_opt_in', 'marketing_unsubscribed_at',
    'health_band', 'health_reason', 'health_signals', 'health_computed_at',
    'deleted_at', 'user_id', 'updated_at'
  ];
begin
  if is_service_context() then
    return new;
  end if;
  if coalesce(current_setting('studiior.waiver_signing', true), '') = '1' then
    if (to_jsonb(new) - waiver_cols) <> (to_jsonb(old) - waiver_cols) then
      raise exception 'waiver signing may set only the signature timestamp'
        using errcode = 'PT403';
    end if;
    return new;
  end if;
  if coalesce(current_setting('studiior.checkin_health', true), '') = '1' then
    if (to_jsonb(new) - health_cols) <> (to_jsonb(old) - health_cols) then
      raise exception 'the check-in health cascade may set only the health columns'
        using errcode = 'PT403';
    end if;
    return new;
  end if;
  -- Decision 69: a member deleting their own account scrubs their own row.
  if coalesce(current_setting('studiior.account_deleting', true), '') = '1' then
    if (to_jsonb(new) - delete_cols) <> (to_jsonb(old) - delete_cols) then
      raise exception 'account deletion may set only the scrub columns'
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

-- -----------------------------------------------------------------------------
-- Re-issue member_plan_overview — exclude deleted members from the staff list
-- (and, transitively, from campaign_audience, which reads this). Byte-for-byte
-- the 20260832240000 body with ONE added predicate: `and m.deleted_at is null`.
-- -----------------------------------------------------------------------------
create or replace function member_plan_overview(p_studio_id uuid)
returns table (
  id uuid, first_name text, last_name text, email text, status text,
  lifetime_visits int, last_visit_at timestamptz,
  health_band text, health_reason text, user_id uuid,
  membership_id uuid, current_plan_name text, plan_type text,
  membership_status text, expires_on date, credits_remaining int,
  had_free_class boolean, has_ever_paid boolean, plan_state text,
  complimentary boolean
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare v_tz text; v_today date;
begin
  if not (is_desk_up(p_studio_id) or is_service_context()) then
    raise exception 'that is another studio''s members' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios s where s.id = p_studio_id;
  v_today := (now() at time zone v_tz)::date;

  return query
  with mem as (
    select m.id, m.first_name, m.last_name, m.email, m.status::text as status,
           m.lifetime_visits, m.last_visit_at,
           m.health_band::text as health_band, m.health_reason, m.user_id
      from members m
     where m.studio_id = p_studio_id and m.status <> 'archived'
       and m.deleted_at is null
  ),
  live as (
    select distinct on (ms.member_id)
           ms.member_id, ms.id as membership_id, ms.status as ms_status,
           ms.expires_on, ms.credits_remaining, mp.name as plan_name, mp.type as plan_type,
           ms.complimentary,
           (ms.status in ('active','trialing','past_due','frozen')
            and (mp.type = 'recurring'
                 or coalesce(ms.credits_remaining,0) > 0)
            and (ms.expires_on is null or ms.expires_on >= v_today)) as usable
      from memberships ms
      join membership_plans mp on mp.id = ms.plan_id
     where ms.studio_id = p_studio_id and ms.status <> 'cancelled'
     order by ms.member_id,
              (ms.status in ('active','trialing','past_due','frozen')) desc,
              ms.expires_on desc nulls first, ms.created_at desc
  ),
  paid as (
    select distinct member_id from payments
     where studio_id = p_studio_id and status in ('succeeded','partially_refunded')
  ),
  freebie as (
    select distinct guest_member_id as member_id from guest_passes
     where studio_id = p_studio_id
  )
  select mem.id, mem.first_name, mem.last_name, mem.email, mem.status,
         mem.lifetime_visits, mem.last_visit_at, mem.health_band, mem.health_reason, mem.user_id,
         live.membership_id, live.plan_name, live.plan_type::text,
         live.ms_status::text, live.expires_on, live.credits_remaining,
         (freebie.member_id is not null) as had_free_class,
         (paid.member_id is not null) as has_ever_paid,
         case
           when coalesce(live.usable, false) then
             case when live.expires_on is not null
                       and live.expires_on <= v_today + 14 then 'expiring' else 'on_plan' end
           when paid.member_id is not null then 'expired'
           when freebie.member_id is not null then 'free_only'
           else 'none'
         end as plan_state,
         coalesce(live.complimentary, false) as complimentary
    from mem
    left join live    on live.member_id = mem.id
    left join paid    on paid.member_id = mem.id
    left join freebie on freebie.member_id = mem.id;
end $$;

-- -----------------------------------------------------------------------------
-- Re-issue campaign_audience — exclude deleted members explicitly (they are
-- already out via marketing_opt_in=false and the overview filter, but state it).
-- Byte-for-byte the 20260832170000 body + `and m.deleted_at is null`.
-- -----------------------------------------------------------------------------
create or replace function campaign_audience(p_studio_id uuid, p_filter jsonb)
returns table (member_id uuid, first_name text, last_name text, email text)
language plpgsql stable security definer set search_path = public as $$
declare
  v_plan   text := nullif(p_filter ->> 'plan_state', '');
  v_health text := nullif(p_filter ->> 'health', '');
  v_joined int  := nullif(p_filter ->> 'joined_days', '')::int;
  v_tz text; v_today date;
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'campaigns are for owners and managers' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  v_today := (now() at time zone v_tz)::date;

  return query
  select o.id, o.first_name, o.last_name, o.email
    from member_plan_overview(p_studio_id) o
    join members m on m.id = o.id
   where m.marketing_opt_in = true
     and m.marketing_unsubscribed_at is null
     and m.archived_at is null
     and m.deleted_at is null
     and nullif(m.email, '') is not null
     and (v_plan   is null or o.plan_state = v_plan)
     and (v_health is null or o.health_band = v_health)
     and (v_joined is null or m.joined_on >= v_today - v_joined);
end $$;
