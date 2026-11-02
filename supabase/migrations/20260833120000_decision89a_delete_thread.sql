-- Decision 89 (a) — delete a whole conversation, and the member's unread dot.
-- Staff delete the thread, its messages and its attachments; the member's
-- screen returns to the empty state. Single messages cannot be deleted.
--
-- creates: staff_delete_thread(uuid)
-- re-issues: member_bootstrap(text)
--
-- No new anon RPC — staff_delete_thread is authenticated/staff-guarded, and the
-- member_bootstrap drop+recreate re-asserts authenticated-only. Anon stays
-- EXACTLY THIRTEEN.

-- ===========================================================================
-- 1. staff_delete_thread — a non-instructor staff role of the thread's studio
--    (is_desk_up) or a service context. Removes the storage objects under
--    {studio_id}/{thread_id}/, then the messages, then the thread; audited.
-- ===========================================================================
create function staff_delete_thread(p_thread_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_thread  message_threads%rowtype;
  v_prefix  text;
  v_att     int;
  v_msgs    int;
begin
  select * into v_thread from message_threads where id = p_thread_id;
  if not found then raise exception 'no such conversation' using errcode = 'PT404'; end if;
  if not (coalesce(is_desk_up(v_thread.studio_id), false) or is_service_context()) then
    raise exception 'only studio staff can delete a conversation' using errcode = 'PT403';
  end if;

  -- Every attachment of this thread lives under {studio_id}/{thread_id}/ in the
  -- private message-attachments bucket (the one path the storage policies allow).
  -- storage.protect_delete() blocks a direct delete unless this txn-local GUC is
  -- set — the documented escape hatch for a trusted definer removing its own
  -- objects (no service-role key, no Storage API round-trip).
  v_prefix := v_thread.studio_id::text || '/' || p_thread_id::text || '/';
  perform set_config('storage.allow_delete_query', 'true', true);
  delete from storage.objects
   where bucket_id = 'message-attachments' and name like v_prefix || '%';
  get diagnostics v_att = row_count;

  delete from thread_messages where thread_id = p_thread_id;
  get diagnostics v_msgs = row_count;

  delete from message_threads where id = p_thread_id;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (v_thread.studio_id, auth.uid(), 'message.thread_deleted', 'message_threads', p_thread_id,
          jsonb_build_object('member_id', v_thread.member_id,
                             'messages_deleted', v_msgs,
                             'attachments_deleted', v_att));

  return jsonb_build_object('ok', true, 'messages_deleted', v_msgs, 'attachments_deleted', v_att);
end $$;
revoke execute on function staff_delete_thread(uuid) from public, anon;
grant  execute on function staff_delete_thread(uuid) to authenticated, service_role;

-- ===========================================================================
-- 2. member_bootstrap — re-issued (the 20260833110000 body) + one scalar:
--    has_unread_studio_message. A staff message newer than the member's own
--    last_member_read_at drives the header speech-bubble dot. Same single-row
--    read, no new wave; the drop+recreate re-asserts the authenticated-only ACL.
-- ===========================================================================
drop function if exists member_bootstrap(text);
create function member_bootstrap(p_slug text)
 returns table(member_id uuid, studio_id uuid, first_name text, last_name text, preferred_name text,
   avatar_path text, status member_status, current_streak integer, lifetime_visits integer,
   studio_name text, studio_timezone text, logo_url text, theme_preset theme_preset, accent_color text,
   checkin_opens_minutes_before integer, checkin_closes_minutes_after integer,
   cancellation_cutoff_minutes integer, booking_cutoff_minutes integer, waitlist_enabled boolean,
   billing_status platform_status, billing_locked boolean, open_offers integer,
   guest_passes_enabled boolean, has_payment_provider boolean, booking_window_days integer,
   how_to_buy text, studio_contact_email text, xendit_enabled boolean, time_format text,
   trial_used boolean, messages_enabled boolean, has_unread_studio_message boolean)
 language sql stable security definer set search_path to 'public' as $function$
  select
    m.id, m.studio_id, m.first_name, m.last_name, m.preferred_name, m.avatar_url,
    m.status, coalesce(m.current_streak, 0), coalesce(m.lifetime_visits, 0),
    s.name, s.timezone, s.logo_url, s.theme_preset, s.accent_color,
    coalesce(st.checkin_opens_minutes_before, 60),
    coalesce(st.checkin_closes_minutes_after, 30),
    coalesce(st.cancellation_cutoff_minutes, 720),
    coalesce(st.booking_cutoff_minutes, 0),
    coalesce(st.waitlist_enabled, true),
    ps.status,
    coalesce(ps.status = 'locked', false),
    (select count(*)::int from waitlist_offers wo
       join bookings b on b.id = wo.booking_id
      where b.member_id = m.id
        and wo.responded_at is null
        and wo.expires_at > now()),
    coalesce(st.guest_passes_enabled, false),
    (s.stripe_account_id is not null),
    member_booking_window_days(m.id),
    st.how_to_buy,
    s.contact_email,
    exists (select 1 from studio_payment_providers spp
             where spp.studio_id = m.studio_id and spp.provider = 'xendit'),
    coalesce(st.time_format, '24h'),
    exists (select 1 from memberships ms
              join membership_plans mp on mp.id = ms.plan_id
             where ms.member_id = m.id and mp.type = 'trial'),
    coalesce(st.messages_enabled, false),
    coalesce(st.messages_enabled, false) and exists (
      select 1 from message_threads mt
        join thread_messages msg on msg.thread_id = mt.id
       where mt.member_id = m.id and msg.sender_kind = 'staff'
         and msg.created_at > coalesce(mt.last_member_read_at, 'epoch'::timestamptz))
  from members m
  join studios s on s.id = m.studio_id
  left join studio_settings st on st.studio_id = m.studio_id
  left join platform_subscriptions ps on ps.studio_id = m.studio_id
  where m.user_id = auth.uid()
    and s.slug = p_slug
  limit 1
$function$;
revoke execute on function member_bootstrap(text) from public, anon;
grant  execute on function member_bootstrap(text) to authenticated, service_role;

-- Anon stays EXACTLY THIRTEEN.
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % (expected 13)', n; end if;
end $$;
