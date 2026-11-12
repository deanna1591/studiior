-- =============================================================================
-- Decision 97 — Merge members, staff delete, invite trail.
--
-- - guest_passes gains host_name_at_invite + invited_at (the invite snapshot),
--   filled by a trigger at insert and backfilled once where the host name is
--   still live. The guest panel and the Journey read the snapshot, so the trail
--   survives the host's deletion or merge. Scrubbing never blanks it.
-- - members gains merged_into + merged_at.
-- - delete_my_account's scrub body is extracted to a service-only
--   delete_member_run(member, send_email, merged_into) twin keyed on the member
--   id; the login is removed only when the member is the last non-deleted row
--   for that user_id. delete_my_account is the thin auth.uid() wrapper.
-- - delete_member(member) manager-up (sends the email). merge_members(keep,
--   remove) manager-up moves every table, then scrubs remove with no email and
--   merged_into=keep. merge_preview(keep, remove) is the read for the confirm.
-- - guard_member_self_update's account_deleting allowlist gains merged_into /
--   merged_at. member_activity gains "Invited {guest} to {class}" / "Invited by
--   {host}" Journey arms from the snapshot.
--
-- No new anon RPC — anon stays EXACTLY THIRTEEN, asserted at apply. Nothing is
-- purged.
--
-- creates:   delete_member_run(uuid, boolean, uuid), delete_member(uuid),
--            merge_members(uuid, uuid), merge_preview(uuid, uuid),
--            tg_guest_pass_invite_snapshot(), member_is_staff_login(uuid)
-- re-issues: guard_member_self_update(), delete_my_account(), member_activity(uuid, date, date)
-- =============================================================================

-- --- Schema -----------------------------------------------------------------
alter table guest_passes add column if not exists host_name_at_invite text;
alter table guest_passes add column if not exists invited_at timestamptz;
alter table members add column if not exists merged_into uuid references members(id) on delete set null;
alter table members add column if not exists merged_at timestamptz;

-- The snapshot, filled at insert. invited_at defaults to created_at (the invite
-- time); host_name_at_invite is the host's CURRENT first name, null when the
-- host is already scrubbed (never the "Deleted member" sentinel) or when there
-- is no host (a free-first self-signup). coalesce so a caller that sets them
-- wins, otherwise the trigger fills.
create or replace function tg_guest_pass_invite_snapshot() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.invited_at := coalesce(new.invited_at, new.created_at, now());
  if new.host_member_id is not null and new.host_name_at_invite is null then
    new.host_name_at_invite := (
      select m.first_name from members m
       where m.id = new.host_member_id and m.deleted_at is null);
  end if;
  return new;
end $$;
revoke execute on function tg_guest_pass_invite_snapshot() from public, anon, authenticated;

drop trigger if exists guest_pass_invite_snapshot on guest_passes;
create trigger guest_pass_invite_snapshot
  before insert on guest_passes
  for each row execute function tg_guest_pass_invite_snapshot();

-- Backfill once: invited_at from created_at everywhere; host_name_at_invite only
-- where the host is still live (not deleted). A host already scrubbed keeps a
-- null snapshot, never the sentinel.
update guest_passes gp set invited_at = gp.created_at where gp.invited_at is null;
update guest_passes gp
   set host_name_at_invite = m.first_name
  from members m
 where gp.host_member_id = m.id and m.deleted_at is null
   and gp.host_name_at_invite is null;

-- --- The guard: account_deleting allowlist gains merged_into / merged_at ------
-- Re-issued from its newest (73c) body with the two merge columns added to
-- delete_cols, so the scrub update (now also setting merged_into on a merge)
-- stays column-narrowed.
CREATE OR REPLACE FUNCTION public.guard_member_self_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  owned constant text[] := array[
    'preferred_name', 'phone', 'avatar_url', 'emergency_contact',
    'address', 'date_of_birth', 'marketing_opt_in', 'updated_at'
  ];
  waiver_cols constant text[] := array['waiver_signed_at', 'updated_at'];
  health_cols constant text[] := array['health_band', 'health_reason',
                                       'health_signals', 'health_computed_at', 'updated_at'];
  desk_pay_cols constant text[] := array['desk_pay_blocked_at', 'desk_pay_blocked_reason', 'updated_at'];
  -- Decision 69 / 97: the exact set the scrub (and a merge) sets. NARROW.
  delete_cols constant text[] := array[
    'first_name', 'last_name', 'email', 'phone', 'date_of_birth', 'avatar_url',
    'address', 'emergency_contact', 'preferred_name', 'source', 'status',
    'marketing_opt_in', 'marketing_unsubscribed_at',
    'health_band', 'health_reason', 'health_signals', 'health_computed_at',
    'deleted_at', 'merged_into', 'merged_at', 'user_id', 'updated_at'
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
  if coalesce(current_setting('studiior.account_deleting', true), '') = '1' then
    if (to_jsonb(new) - delete_cols) <> (to_jsonb(old) - delete_cols) then
      raise exception 'account deletion may set only the scrub columns'
        using errcode = 'PT403';
    end if;
    return new;
  end if;
  if coalesce(current_setting('studiior.desk_pay_system', true), '') = '1' then
    if (to_jsonb(new) - desk_pay_cols) <> (to_jsonb(old) - desk_pay_cols) then
      raise exception 'the desk-pay block may set only the desk-pay columns'
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
end $function$;

-- --- member_is_staff_login: a member whose login is studio staff / instructor -
create or replace function member_is_staff_login(p_member_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from members m
    join studio_staff ss on ss.user_id = m.user_id
   where m.id = p_member_id and m.user_id is not null);
$$;
revoke execute on function member_is_staff_login(uuid) from public, anon;
grant  execute on function member_is_staff_login(uuid) to authenticated, service_role;

-- --- The scrub, keyed on the member id (service only) ------------------------
-- Steps 1-5 of delete_my_account, keyed on the member row. The login is removed
-- only when this member is the last non-deleted row for its user_id, so a single
-- studio's delete or merge never signs the person out of their other studios.
-- p_send_email false for a merge (the history lives on under the kept account);
-- p_merged_into set for a merge so the profile reads "Merged into {kept}".
-- Never blanks the invite snapshots.
create or replace function delete_member_run(
  p_member_id uuid, p_send_email boolean default true, p_merged_into uuid default null)
returns void
language plpgsql security definer set search_path = public as $$
declare m members%rowtype; b record; v_studio studios%rowtype;
begin
  select * into m from members where id = p_member_id;
  if not found then
    raise exception 'no such member' using errcode = 'PT404';
  end if;
  if m.deleted_at is not null then
    return;  -- already scrubbed; idempotent
  end if;

  -- 1. Cancel every FUTURE non-terminal booking through the member path, no
  --    penalty (free_cancel_until first). On a merge these have already moved to
  --    the kept member, so there is nothing of this member's left to cancel.
  for b in
    select bk.id from bookings bk
    join class_occurrences o on o.id = bk.occurrence_id
   where bk.member_id = m.id
     and bk.status in ('booked','waitlisted','pending_payment')
     and o.starts_at > now()
  loop
    update bookings set free_cancel_until = now() + interval '1 hour' where id = b.id;
    perform cancel_booking(b.id);
  end loop;

  -- 2. End every live membership; forfeit credits.
  with ended as (
    update memberships
       set status = 'cancelled', cancelled_at = now(), credits_remaining = 0
     where member_id = m.id
       and status in ('trialing','active','past_due','frozen')
    returning id, studio_id
  )
  insert into membership_events (studio_id, membership_id, type, to_status, actor_user_id)
    select studio_id, id, 'account_deleted', 'cancelled'::membership_status, auth.uid() from ended;

  -- 3. The confirmation email, to the PRE-SCRUB address. Not on a merge.
  if p_send_email then
    select * into v_studio from studios where id = m.studio_id;
    perform queue_notification(
      m.studio_id, m.id, 'account_deleted',
      jsonb_build_object('to_email', m.email, 'studio_name', v_studio.name),
      'account_deleted:' || m.id, now());
  end if;

  -- 4. Push / device / personal tokens.
  delete from push_subscriptions where member_id = m.id;
  delete from calendar_tokens      where member_id = m.id;

  -- 5. Scrub. Column-narrowed under the account_deleting flag.
  perform set_config('studiior.account_deleting', '1', true);
  update members set
    first_name = 'Deleted',
    last_name = 'member',
    email = 'deleted+' || m.id || '@deleted.invalid',
    phone = null, date_of_birth = null, avatar_url = null, address = null,
    emergency_contact = null, preferred_name = null, source = null,
    status = 'inactive',
    marketing_opt_in = false, marketing_unsubscribed_at = now(),
    health_band = null, health_reason = null,
    health_signals = '[]'::jsonb, health_computed_at = null,
    merged_into = p_merged_into,
    merged_at = case when p_merged_into is not null then now() else null end,
    deleted_at = now()
  where id = m.id;
  -- Leave the flag set (txn-local): step 6 deletes the auth login, which cascades
  -- members.user_id -> null, an update that fires the guard and is covered by the
  -- account_deleting allowlist. No members update after this needs it off.

  -- 6. Remove the auth login only when this was the last non-deleted member row
  --    for that user_id. The cascade nulls members.user_id.
  if m.user_id is not null
     and not exists (select 1 from members o
                      where o.user_id = m.user_id and o.deleted_at is null and o.id <> m.id) then
    delete from auth.users where id = m.user_id;
  end if;
end $$;
revoke execute on function delete_member_run(uuid, boolean, uuid) from public, anon, authenticated;
grant  execute on function delete_member_run(uuid, boolean, uuid) to service_role;

-- --- delete_my_account: the thin auth.uid() wrapper (self-deletion) ----------
create or replace function delete_my_account()
returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); m record;
begin
  if v_uid is null then
    raise exception 'You are not signed in.' using errcode = 'PT401';
  end if;
  if exists (select 1 from studio_staff ss where ss.user_id = v_uid) then
    raise exception 'This login is part of a studio team, so it can''t be deleted here. Please contact your studio.'
      using errcode = 'PT403';
  end if;
  -- One member row per studio this login belongs to; scrub each. The twin
  -- removes the auth login on the last one (no other non-deleted row remains).
  for m in select id from members where user_id = v_uid and deleted_at is null loop
    perform delete_member_run(m.id, true, null);
  end loop;
end $$;
revoke execute on function delete_my_account() from public, anon;
grant  execute on function delete_my_account() to authenticated;

-- --- delete_member: manager-up staff delete ---------------------------------
create or replace function delete_member(p_member_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare m members%rowtype;
begin
  select * into m from members where id = p_member_id;
  if not found then
    raise exception 'no such member' using errcode = 'PT404';
  end if;
  if not coalesce(is_manager_up(m.studio_id), false) then
    raise exception 'only owners and managers delete a member' using errcode = 'PT403';
  end if;
  if m.deleted_at is not null then
    raise exception 'That member is already deleted.' using errcode = 'PT409';
  end if;
  if member_is_staff_login(p_member_id) then
    raise exception 'This member has a staff or instructor login, so they can''t be deleted here.'
      using errcode = 'PT409';
  end if;

  perform delete_member_run(p_member_id, true, null);
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before)
    values (m.studio_id, auth.uid(), 'member.deleted', 'members', p_member_id,
            jsonb_build_object('first_name', m.first_name, 'email', m.email));
  return jsonb_build_object('ok', true, 'deleted', p_member_id);
end $$;
revoke execute on function delete_member(uuid) from public, anon;
grant  execute on function delete_member(uuid) to authenticated, service_role;

-- --- merge_preview: the read behind the confirm screen ----------------------
create or replace function merge_preview(p_keep uuid, p_remove uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare k members%rowtype; r members%rowtype; v_reason text;
begin
  select * into k from members where id = p_keep;
  select * into r from members where id = p_remove;
  if k.id is null or r.id is null then
    raise exception 'no such member' using errcode = 'PT404';
  end if;
  if not coalesce(is_manager_up(k.studio_id), false) then
    raise exception 'only owners and managers merge members' using errcode = 'PT403';
  end if;

  v_reason := case
    when p_keep = p_remove then 'same_member'
    when k.studio_id <> r.studio_id then 'different_studios'
    when k.deleted_at is not null or r.deleted_at is not null then 'already_deleted'
    when member_is_staff_login(p_keep) or member_is_staff_login(p_remove) then 'staff_login'
    else null end;

  return jsonb_build_object(
    'ok', v_reason is null,
    'reason', v_reason,
    'keep_name', k.first_name,
    'keep_email', k.email,
    'remove_name', r.first_name,
    'remove_email', r.email,
    'counts', jsonb_build_object(
      'bookings',   (select count(*) from bookings   where member_id = p_remove),
      'payments',   (select count(*) from payments   where member_id = p_remove),
      'credits',    (select count(*) from credit_ledger where member_id = p_remove),
      'passes',     (select count(*) from guest_passes where guest_member_id = p_remove or host_member_id = p_remove),
      'check_ins',  (select count(*) from check_ins  where member_id = p_remove),
      'messages',   (select count(*) from messages   where member_id = p_remove)
                    + (select coalesce(sum(cnt),0) from (
                         select count(*) cnt from thread_messages tm
                         join message_threads mt on mt.id = tm.thread_id
                         where mt.member_id = p_remove) z),
      'memberships_moving', (select count(*) from memberships where member_id = p_remove)),
    'two_active', (select count(*) from memberships
                    where member_id in (p_keep, p_remove)
                      and status in ('trialing','active','past_due','frozen')) > 1);
end $$;
revoke execute on function merge_preview(uuid, uuid) from public, anon;
grant  execute on function merge_preview(uuid, uuid) to authenticated, service_role;

-- --- merge_members: move everything from p_remove to p_keep, then scrub -------
create or replace function merge_members(p_keep uuid, p_remove uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  k members%rowtype; r members%rowtype; v_studio uuid;
  rec record; v_keep_thread uuid; v_remove_thread uuid;
  v_tbl text;
  v_moved jsonb;
  plain_tables constant text[] := array[
    'ai_draft_usage','bookings','check_ins','credit_ledger','group_bookings',
    'member_contacts','member_documents','member_goals','member_infractions',
    'member_notes','memberships','messages','notifications','payments',
    'peak_allowance_ledger','product_orders','promo_redemptions','timeline_events',
    'waiver_signatures','xendit_purchases'];
begin
  select * into k from members where id = p_keep for update;
  select * into r from members where id = p_remove for update;
  if k.id is null or r.id is null then
    raise exception 'no such member' using errcode = 'PT404';
  end if;
  v_studio := k.studio_id;
  if not coalesce(is_manager_up(v_studio), false) then
    raise exception 'only owners and managers merge members' using errcode = 'PT403';
  end if;
  if p_keep = p_remove then
    raise exception 'A member cannot be merged into itself.' using errcode = 'PT409';
  end if;
  if k.studio_id <> r.studio_id then
    raise exception 'Members from different studios cannot be merged.' using errcode = 'PT409';
  end if;
  if k.deleted_at is not null or r.deleted_at is not null then
    raise exception 'A deleted member cannot be merged.' using errcode = 'PT409';
  end if;
  if member_is_staff_login(p_keep) or member_is_staff_login(p_remove) then
    raise exception 'A member with a staff or instructor login cannot be merged.' using errcode = 'PT409';
  end if;

  -- Count what moves (before the move), for the audit row.
  v_moved := jsonb_build_object(
    'bookings',  (select count(*) from bookings where member_id = p_remove),
    'payments',  (select count(*) from payments where member_id = p_remove),
    'credits',   (select count(*) from credit_ledger where member_id = p_remove),
    'check_ins', (select count(*) from check_ins where member_id = p_remove));

  -- 1. Booking collisions: the same occurrence booked live by both keeps the
  --    earlier booking and removes the later. A future class cancels through the
  --    normal path with no penalty; a past class drops the later duplicate row.
  for rec in
    select rb.id as remove_bk, kb.id as keep_bk, rb.booked_at as r_at, kb.booked_at as k_at,
           o.starts_at
      from bookings rb
      join bookings kb on kb.occurrence_id = rb.occurrence_id and kb.member_id = p_keep
      join class_occurrences o on o.id = rb.occurrence_id
     where rb.member_id = p_remove
       and rb.status in ('booked','waitlisted','attended','no_show','pending_payment')
       and kb.status in ('booked','waitlisted','attended','no_show','pending_payment')
  loop
    if rec.starts_at > now() then
      if rec.r_at <= rec.k_at then
        update bookings set free_cancel_until = now() + interval '1 hour' where id = rec.keep_bk;
        perform cancel_booking(rec.keep_bk);
      else
        update bookings set free_cancel_until = now() + interval '1 hour' where id = rec.remove_bk;
        perform cancel_booking(rec.remove_bk);
      end if;
    else
      -- Past collision: keep the earlier, delete the later duplicate.
      if rec.r_at <= rec.k_at then delete from bookings where id = rec.keep_bk;
      else delete from bookings where id = rec.remove_bk; end if;
    end if;
  end loop;

  -- 2. Message threads fold into the kept member's thread.
  select id into v_keep_thread   from message_threads where studio_id = v_studio and member_id = p_keep;
  select id into v_remove_thread from message_threads where studio_id = v_studio and member_id = p_remove;
  if v_remove_thread is not null then
    if v_keep_thread is not null then
      update thread_messages set thread_id = v_keep_thread where thread_id = v_remove_thread;
      delete from message_threads where id = v_remove_thread;
    else
      update message_threads set member_id = p_keep where id = v_remove_thread;
    end if;
  end if;

  -- 3. One-row-per-(member, x) tables: drop the removed member's colliding rows,
  --    keeping the kept member's, then move the rest.
  delete from notification_preferences rr where rr.member_id = p_remove
    and exists (select 1 from notification_preferences kk where kk.member_id = p_keep);
  update notification_preferences set member_id = p_keep where member_id = p_remove;

  delete from member_payment_customers rr where rr.member_id = p_remove
    and exists (select 1 from member_payment_customers kk where kk.member_id = p_keep and kk.provider = rr.provider);
  update member_payment_customers set member_id = p_keep where member_id = p_remove;

  delete from member_tasks rr where rr.member_id = p_remove and rr.status = 'open'
    and exists (select 1 from member_tasks kk where kk.member_id = p_keep and kk.status = 'open' and kk.kind = rr.kind);
  update member_tasks set member_id = p_keep where member_id = p_remove;

  delete from member_invites rr where rr.member_id = p_remove and rr.accepted_at is null
    and exists (select 1 from member_invites kk where kk.member_id = p_keep and kk.accepted_at is null);
  update member_invites set member_id = p_keep where member_id = p_remove;

  delete from challenge_participants rr where rr.member_id = p_remove
    and exists (select 1 from challenge_participants kk where kk.member_id = p_keep and kk.challenge_id = rr.challenge_id);
  update challenge_participants set member_id = p_keep where member_id = p_remove;

  delete from challenge_progress_events rr where rr.member_id = p_remove
    and exists (select 1 from challenge_progress_events kk where kk.member_id = p_keep
                 and kk.challenge_id = rr.challenge_id and kk.booking_id is not distinct from rr.booking_id);
  update challenge_progress_events set member_id = p_keep where member_id = p_remove;

  delete from member_achievements rr where rr.member_id = p_remove
    and exists (select 1 from member_achievements kk where kk.member_id = p_keep and kk.definition_id = rr.definition_id);
  update member_achievements set member_id = p_keep where member_id = p_remove;

  delete from announcement_dismissals rr where rr.member_id = p_remove
    and exists (select 1 from announcement_dismissals kk where kk.member_id = p_keep and kk.announcement_id = rr.announcement_id);
  update announcement_dismissals set member_id = p_keep where member_id = p_remove;

  delete from member_dismissals rr where rr.member_id = p_remove
    and exists (select 1 from member_dismissals kk where kk.member_id = p_keep and kk.key = rr.key);
  update member_dismissals set member_id = p_keep where member_id = p_remove;

  delete from campaign_recipients rr where rr.member_id = p_remove
    and exists (select 1 from campaign_recipients kk where kk.member_id = p_keep and kk.campaign_id = rr.campaign_id);
  update campaign_recipients set member_id = p_keep where member_id = p_remove;

  delete from member_tag_assignments rr where rr.member_id = p_remove
    and exists (select 1 from member_tag_assignments kk where kk.member_id = p_keep and kk.tag_id = rr.tag_id);
  update member_tag_assignments set member_id = p_keep where member_id = p_remove;

  -- guest_passes: the host side can collide on the one-live-per-host index.
  delete from guest_passes rr where rr.host_member_id = p_remove and rr.status in ('invited','confirmed')
    and exists (select 1 from guest_passes kk where kk.host_member_id = p_keep and kk.status in ('invited','confirmed'));
  update guest_passes set host_member_id = p_keep where host_member_id = p_remove;
  update guest_passes set guest_member_id = p_keep where guest_member_id = p_remove;

  -- 4. Plain re-points (member_id, no member-level unique).
  foreach v_tbl in array plain_tables loop
    execute format('update %I set member_id = $1 where member_id = $2', v_tbl) using p_keep, p_remove;
  end loop;
  -- Differently-named columns.
  update gift_cards      set purchaser_member_id = p_keep where purchaser_member_id = p_remove;
  update group_purchases set host_member_id      = p_keep where host_member_id = p_remove;

  -- 5. Semantic folds on the kept member: earliest waiver, marketing on if either.
  update members set
    waiver_signed_at = least(k.waiver_signed_at, r.waiver_signed_at),
    marketing_opt_in = (k.marketing_opt_in or r.marketing_opt_in)
  where id = p_keep;

  -- 6. Scrub the removed member, no email, merged_into the kept one.
  perform delete_member_run(p_remove, false, p_keep);

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
    values (v_studio, auth.uid(), 'member.merged', 'members', p_remove,
            jsonb_build_object('removed', p_remove, 'removed_email', r.email, 'moved', v_moved),
            jsonb_build_object('merged_into', p_keep, 'kept_email', k.email));

  return jsonb_build_object('ok', true, 'kept', p_keep, 'removed', p_remove, 'moved', v_moved);
end $$;
revoke execute on function merge_members(uuid, uuid) from public, anon;
grant  execute on function merge_members(uuid, uuid) to authenticated, service_role;

-- --- member_activity: Journey arms for the invite trail --------------------
CREATE OR REPLACE FUNCTION public.member_activity(p_member_id uuid, p_from date, p_to date)
 RETURNS TABLE(at timestamp with time zone, kind text, title text, detail text, credit_delta integer, balance_after integer, amount_cents integer, currency text, occurrence_id uuid, booking_id uuid, membership_id uuid, plan_name text, due_cents integer, is_free_first boolean, occurrence_start timestamp with time zone, instructor_first text, credits_left_after integer, payment_method text, recorded_by_name text, plan_classes integer, plan_valid_to date, unused_credits integer, payment_source text, is_paid boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
declare v_studio uuid; v_is_staff boolean; v_owns boolean;
begin
  select studio_id into v_studio from members where id = p_member_id;
  if v_studio is null then raise exception 'no such member' using errcode = 'PT404'; end if;
  v_owns := exists (select 1 from members m where m.id = p_member_id and m.user_id = auth.uid());
  v_is_staff := coalesce(is_desk_up(v_studio), false) or is_service_context();
  if not (v_owns or v_is_staff) then
    raise exception 'that is not your statement' using errcode = 'PT403';
  end if;

  return query
  with led as (
    select cl.id, cl.delta, cl.reason::text as reason, cl.booking_id, cl.membership_id,
           cl.created_at,
           (sum(cl.delta) over (order by cl.created_at, cl.id))::int as bal,
           (sum(cl.delta) over (partition by cl.membership_id order by cl.created_at, cl.id))::int as membership_bal
      from credit_ledger cl
     where cl.member_id = p_member_id
  ),
  -- A purchase payment claims the Nth 'purchase' ledger row of its membership;
  -- a refunded payment claims the Nth negative 'manual' row of its membership.
  -- Rank joins, so each ledger id is claimed at most once; a grant with no
  -- payment (e.g. a complimentary membership) stays unclaimed and surfaces as its
  -- own "Credits added" line.
  purch_led as (
    select id, membership_id, row_number() over (partition by membership_id order by created_at, id) rn
      from led where reason = 'purchase' and membership_id is not null),
  purch_pay as (
    select p.id as payment_id, p.membership_id,
           row_number() over (partition by p.membership_id order by coalesce(p.paid_at, p.created_at), p.id) rn
      from payments p
     where p.member_id = p_member_id and p.membership_id is not null
       and p.status in ('succeeded', 'partially_refunded')),
  pay_grant as (
    select pp.payment_id, pl.id as ledger_id
      from purch_pay pp join purch_led pl on pl.membership_id = pp.membership_id and pl.rn = pp.rn),
  forfeit_led as (
    select id, membership_id, row_number() over (partition by membership_id order by created_at, id) rn
      from led where reason = 'manual' and delta < 0 and membership_id is not null),
  refund_pay as (
    select p.id as payment_id, p.membership_id,
           row_number() over (partition by p.membership_id order by coalesce(p.refunded_at, p.updated_at), p.id) rn
      from payments p
     where p.member_id = p_member_id and p.membership_id is not null
       and (p.refunded_at is not null or p.status in ('refunded', 'partially_refunded'))),
  pay_forfeit as (
    select rp.payment_id, fl.id as ledger_id
      from refund_pay rp join forfeit_led fl on fl.membership_id = rp.membership_id and fl.rn = rp.rn),
  ev as (
    -- Decision 95: a flex-rescue email was sent (staff only).
    select coalesce(nt.sent_at, nt.scheduled_for, nt.created_at) as at,
           'rescue_email' as kind, 'Rescue email sent' as title,
           case when nt.template_key = 'flex_rescue_2days'
                then 'Flex class still needs numbers'
                else 'Last call to move the booking' end as detail,
           null::uuid as ledger_id, null::int as amount_cents, null::text as currency,
           null::uuid as occurrence_id, null::uuid as booking_id, null::uuid as membership_id
      from notifications nt
     where nt.member_id = p_member_id and v_is_staff
       and nt.template_key in ('flex_rescue_2days','flex_rescue_final','free_rescue_2days','free_rescue_final')
    union all
    -- joined (staff only)
    select m.joined_on::timestamptz as at, 'joined' as kind, 'Joined the studio' as title,
           nullif('Came via ' || coalesce(m.source, ''), 'Came via ') as detail,
           null::uuid as ledger_id, null::int as amount_cents, null::text as currency,
           null::uuid as occurrence_id, null::uuid as booking_id, null::uuid as membership_id
      from members m where m.id = p_member_id and v_is_staff and m.joined_on is not null
    union all
    -- Decision 97: invited a guest (this member is the host). Derived from
    -- the invite snapshot, so it survives the guest's deletion or merge.
    select gp.invited_at as at, 'invited_guest' as kind,
           'Invited ' || coalesce(g.first_name, 'a guest') || ' to ' || coalesce(o.name, ct.name, 'a class') as title,
           null::text as detail,
           null::uuid as ledger_id, null::int as amount_cents, null::text as currency,
           gp.occurrence_id as occurrence_id, null::uuid as booking_id, null::uuid as membership_id
      from guest_passes gp
      join class_occurrences o on o.id = gp.occurrence_id
      left join class_types ct on ct.id = o.class_type_id
      left join members g on g.id = gp.guest_member_id
     where gp.host_member_id = p_member_id and gp.invited_at is not null
    union all
    -- Decision 97: invited by a host (this member is the guest). The host
    -- name is the invite snapshot, surviving the host's deletion or merge.
    select gp.invited_at as at, 'invited_by' as kind,
           'Invited by ' || coalesce(gp.host_name_at_invite, 'a member') as title,
           null::text as detail,
           null::uuid as ledger_id, null::int as amount_cents, null::text as currency,
           gp.occurrence_id as occurrence_id, null::uuid as booking_id, null::uuid as membership_id
      from guest_passes gp
     where gp.guest_member_id = p_member_id and gp.host_member_id is not null and gp.invited_at is not null
    union all
    -- booked / waitlisted / free first
    select b.booked_at,
           case when b.status = 'waitlisted' then 'waitlisted'
                when b.payment_source = 'comp'
                     and exists (select 1 from guest_passes gp where gp.guest_booking_id = b.id and gp.host_member_id is null)
                     then 'free_first'
                else 'booked' end,
           case when b.status = 'waitlisted' then 'Joined the waitlist for ' || coalesce(o.name, 'a class')
                when b.payment_source = 'comp'
                     and exists (select 1 from guest_passes gp where gp.guest_booking_id = b.id and gp.host_member_id is null)
                     then 'Booked a free first class — ' || coalesce(o.name, 'a class')
                when b.payment_source = 'group' then
                     (select case when gb.is_host
                                  then 'Group booking — ' || coalesce(o.name, 'a class') || ' · ' || mp.name
                                  else 'Booked by ' || hm.first_name || ' · ' || mp.name end
                        from group_bookings gb
                        join group_purchases gpu on gpu.id = gb.group_purchase_id
                        join membership_plans mp on mp.id = gpu.plan_id
                        join members hm on hm.id = gpu.host_member_id
                       where gb.booking_id = b.id)
                else 'Booked ' || coalesce(o.name, 'a class') end,
           case when b.payment_source = 'group' then
                  (select case when gb.is_host then (
                            select string_agg(coalesce(nullif(m2.first_name,''), m2.email), ', ')
                              from group_bookings gb2 join members m2 on m2.id = gb2.member_id
                             where gb2.group_purchase_id = gb.group_purchase_id and not gb2.is_host)
                          end
                     from group_bookings gb where gb.booking_id = b.id)
                when exists (select 1 from waitlist_offers wo where wo.booking_id = b.id and wo.outcome = 'accepted')
                then 'From the waitlist' end,
           b.credit_entry_id, null, null, b.occurrence_id, b.id, b.membership_id
      from bookings b left join class_occurrences o on o.id = b.occurrence_id
     where b.member_id = p_member_id
       and b.status in ('booked','attended','no_show','cancelled','late_cancelled','waitlisted','pending_payment')
    union all
    -- cancelled (carries the cancellation_refund, or 0 "class used")
    select b.cancelled_at,
           case when b.release_reason = 'studio_released' then 'studio_cancelled'
                when b.status = 'late_cancelled' or b.is_late_cancel then 'late_cancelled'
                else 'cancelled' end,
           case when b.release_reason = 'studio_released' then 'Studio cancelled ' || coalesce(o.name, 'a class')
                when b.status = 'late_cancelled' or b.is_late_cancel then 'Cancelled late — ' || coalesce(o.name, 'a class')
                else 'Cancelled ' || coalesce(o.name, 'a class') end,
           case when b.release_reason = 'studio_released' then 'Credit returned'
                when (b.status = 'late_cancelled' or b.is_late_cancel)
                     and not exists (select 1 from led cl where cl.booking_id = b.id and cl.reason = 'cancellation_refund')
                then 'Class used' end,
           (select cl.id from led cl where cl.booking_id = b.id and cl.reason = 'cancellation_refund' order by cl.created_at, cl.id limit 1),
           null, null, b.occurrence_id, b.id, b.membership_id
      from bookings b left join class_occurrences o on o.id = b.occurrence_id
     where b.member_id = p_member_id and b.status in ('cancelled','late_cancelled')
    union all
    -- checked in / attended
    select ci.checked_in_at, 'attended',
           case when o.id is null then 'Attended a class (imported)' else 'Attended ' || o.name end,
           null, null::uuid, null, null, ci.occurrence_id, ci.booking_id, null
      from check_ins ci left join class_occurrences o on o.id = ci.occurrence_id
     where ci.member_id = p_member_id
    union all
    -- no-show
    select coalesce(b.no_show_at, o.ends_at, b.updated_at), 'no_show',
           'Did not attend ' || coalesce(o.name, 'a class'), null,
           null::uuid, null, null, b.occurrence_id, b.id, b.membership_id
      from bookings b left join class_occurrences o on o.id = b.occurrence_id
     where b.member_id = p_member_id and b.status = 'no_show'
    union all
    -- purchase / refund / failed payment (carries the matched grant/forfeit)
    select coalesce(p.paid_at, p.created_at),
           case when p.refunded_at is not null or p.status in ('refunded','partially_refunded') then 'refund'
                when p.status = 'failed' then 'payment_failed'
                else 'purchase' end,
           case when p.refunded_at is not null or p.status in ('refunded','partially_refunded') then 'Refund — ' || coalesce(p.description, 'a payment')
                when p.status = 'failed' then 'Payment failed — ' || coalesce(p.description, 'a payment')
                else 'Bought ' || coalesce(p.description, 'a plan') end,
           null,
           case when p.refunded_at is not null or p.status in ('refunded','partially_refunded')
                then (select ledger_id from pay_forfeit pf where pf.payment_id = p.id)
                when p.status = 'failed' then null
                else (select ledger_id from pay_grant pg where pg.payment_id = p.id) end,
           case when p.refunded_at is not null then coalesce(p.refunded_cents, p.amount_cents) else p.amount_cents end,
           p.currency, null::uuid, p.booking_id, p.membership_id
      from payments p where p.member_id = p_member_id
    union all
    -- rescheduled / instructor changed, for occurrences the member holds a live booking on
    select oe.at,
           case when oe.kind = 'moved' then 'rescheduled' else 'instructor_changed' end,
           case when oe.kind = 'moved' then 'Class rescheduled — ' || coalesce(o.name, 'a class')
                else 'Instructor changed — ' || coalesce(o.name, 'a class') end,
           null, null::uuid, null, null, oe.occurrence_id, null, null
      from occurrence_events oe left join class_occurrences o on o.id = oe.occurrence_id
     where oe.kind in ('moved','instructor_changed')
       and exists (select 1 from bookings b where b.occurrence_id = oe.occurrence_id
                    and b.member_id = p_member_id and b.status <> 'cancelled')
    union all
    -- message_sent (staff only)
    select coalesce(msg.sent_at, msg.updated_at), 'message_sent', 'Message sent', msg.subject,
           null::uuid, null, null, null, null, null
      from messages msg
     where msg.member_id = p_member_id and v_is_staff and msg.status in ('queued','sent')
    union all
    -- contacted (staff only) — a task contacted the old way (no member_contacts
    -- row). A task linked to a contact (contact_id set) shows via the arm below.
    select mt.contacted_at, 'contacted', 'Contacted', mt.reason,
           null::uuid, null, null, null, null, null
      from member_tasks mt
     where mt.member_id = p_member_id and v_is_staff
       and mt.status = 'contacted' and mt.contacted_at is not null
       and mt.contact_id is null
    union all
    -- Decision 79: retention outreach logged in member_contacts (staff only).
    select mc.contacted_at, 'contacted',
           case when mc.method = 'email' then 'Emailed'
                when mc.method = 'viber' then 'Contacted (Viber)'
                when mc.method = 'call'  then 'Called'
                else 'Contacted (in person)' end
             || coalesce(' by ' || nullif(pr.full_name, ''), ''),
           mc.subject,
           null::uuid, null, null, null, null, null
      from member_contacts mc
      left join profiles pr on pr.id = mc.staff_id
     where mc.member_id = p_member_id and v_is_staff
    union all
    -- Decision 83 (a): a plan that ended (expired, or ended by staff) — NOT
    -- a refund, which tells its own story. Claims the end-forfeit ledger row
    -- so it is not also a bare "Credit adjustment"; unused = classes forfeited.
    select coalesce(ms2.cancelled_at, (ms2.expires_on)::timestamptz), 'plan_ended', 'Plan ended', null,
           (select cl.id from led cl
             where cl.membership_id = ms2.id and cl.reason = 'manual' and cl.delta < 0
               and cl.id not in (select ledger_id from pay_forfeit)
             order by cl.created_at desc, cl.id desc limit 1),
           null, null, null::uuid, null, ms2.id
      from memberships ms2
     where ms2.member_id = p_member_id
       and ms2.status in ('cancelled','expired')
       and coalesce(ms2.cancelled_at, (ms2.expires_on)::timestamptz) is not null
       and not exists (select 1 from payments p where p.membership_id = ms2.id
                        and (p.refunded_at is not null or p.status in ('refunded','partially_refunded')))
  ),
  claimed as (select distinct ledger_id from ev where ledger_id is not null),
  -- ledger rows no event claims: complimentary grants, manual adjustments,
  -- lockout, merch. Shown as their own credit lines.
  adj as (
    select l.created_at as at,
           case when l.reason = 'booking' then 'credit_used'
                when l.delta >= 0 then 'credits_added' else 'credit_adjustment' end as kind,
           case when l.reason = 'booking' then 'Class credit used'
                when l.reason = 'cancellation_refund' then 'Credit returned'
                when l.delta >= 0 then 'Credits added' else 'Credit adjustment' end as title,
           null::text as detail, l.id as ledger_id, null::int as amount_cents, null::text as currency,
           null::uuid as occurrence_id, l.booking_id, l.membership_id
      from led l where l.id not in (select ledger_id from claimed where ledger_id is not null)
  ),
  all_rows as (
    select * from ev
    union all
    select * from adj
  )
  select
    x.at, x.kind, x.title, x.detail,
    coalesce(l.delta, 0) as credit_delta,
    coalesce(l.bal,
             (select l2.bal from led l2 where l2.created_at <= x.at order by l2.created_at desc, l2.id desc limit 1),
             0) as balance_after,
    x.amount_cents, x.currency, x.occurrence_id, x.booking_id, x.membership_id,
    -- Decision 83. plan_name: the plan a booking drew from, a cancellation or a
    -- no-show consumed/returned to, or the ended plan. null on every other kind.
    case when x.kind in ('booked','cancelled','late_cancelled','studio_cancelled','no_show','plan_ended')
         then mp.name end as plan_name,
    -- due_cents: a LIVE unpaid drop-in booking only — the cheapest active public
    -- drop_in plan price, what Pay-now charges (bookings store no per-row price).
    case when x.kind = 'booked' and exists (
           select 1 from bookings b
            where b.id = x.booking_id and b.payment_source = 'drop_in' and b.status = 'booked'
              and not exists (select 1 from payments p
                               where p.booking_id = b.id and p.status in ('succeeded','partially_refunded')))
         then (select dp.price_cents from membership_plans dp
                where dp.studio_id = v_studio and dp.type = 'drop_in'
                  and dp.visibility = 'public' and dp.status = 'active'
                order by dp.price_cents asc, dp.sort_order asc, dp.id limit 1)
         end as due_cents,
    -- is_free_first: true on a free-first comp booking AND on its later cancel /
    -- no-show rows, so the helper can say "Free class used" / "Free class kept".
    (x.booking_id is not null and exists (
       select 1 from bookings b join guest_passes gp on gp.guest_booking_id = b.id
        where b.id = x.booking_id and b.payment_source = 'comp' and gp.host_member_id is null))
      as is_free_first,
    -- Decision 83 (a): the class instant + instructor, for the "{Day} {date},
    -- {time} with {instructor}" line (rowLine renders in the studio timezone).
    occ.starts_at as occurrence_start,
    nullif(split_part(coalesce(inst.display_name, ''), ' ', 1), '') as instructor_first,
    -- credits_left_after: the plan balance after this row. A no-show and a late
    -- cancel that used the credit carry no ledger of their own (the credit was
    -- spent at booking), so read that booking's consume row; a late cancel that
    -- refunded (consumes-off) has a refund ledger row, so coalesce keeps it. null
    -- = no plan credit touched (free first, unlimited, drop-in, money rows).
    case when x.kind in ('no_show','late_cancelled')
         then coalesce(l.membership_bal,
                       (select l2.membership_bal from led l2 join bookings b2 on b2.credit_entry_id = l2.id
                         where b2.id = x.booking_id))
         else l.membership_bal end as credits_left_after,
    -- payment_method / recorded_by_name: the money row's own payment (lateral,
    -- keyed on member + the arm's `at`). recorded_by is null for an online
    -- payment, so recorded_by_name is null unless it was taken at the desk.
    pm.method as payment_method,
    rec.full_name as recorded_by_name,
    case when x.kind = 'purchase' then coalesce(mp.credits, mp.credits_per_period) end as plan_classes,
    case when x.kind = 'purchase' then ms.expires_on end as plan_valid_to,
    case when x.kind = 'plan_ended' then abs(coalesce(l.delta, 0)) end as unused_credits,
    -- Decision 83 (a) follow-up: the booking's own payment_source (comp / drop_in /
    -- class_pack / membership / group), null for a non-booking row; and whether a
    -- booking row has a succeeded or partially_refunded payment, null otherwise.
    -- rowLine reads these to say "Complimentary" vs "Drop-in, paid" vs "due".
    (select b.payment_source::text from bookings b where b.id = x.booking_id) as payment_source,
    case when x.booking_id is not null
         then exists (select 1 from payments p
                       where p.booking_id = x.booking_id and p.status in ('succeeded','partially_refunded'))
         end as is_paid
  from all_rows x
  left join led l on l.id = x.ledger_id
  left join memberships ms on ms.id = x.membership_id
  left join membership_plans mp on mp.id = ms.plan_id
  left join class_occurrences occ on occ.id = x.occurrence_id
  left join instructors inst on inst.id = occ.instructor_id
  left join lateral (
    select p2.method, p2.recorded_by
      from payments p2
     where x.kind in ('purchase','refund','payment_failed')
       and p2.member_id = p_member_id
       and coalesce(p2.paid_at, p2.created_at) = x.at
     order by p2.id limit 1) pm on true
  left join profiles rec on rec.id = pm.recorded_by
  where x.at is not null and x.at::date between p_from and p_to
  order by x.at desc, x.kind;
end $function$;
revoke execute on function member_activity(uuid, date, date) from public, anon;
grant  execute on function member_activity(uuid, date, date) to authenticated, service_role;

-- --- Anon stays EXACTLY THIRTEEN --------------------------------------------
do $$ declare n int; begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % (want 13)', n; end if;
end $$;
