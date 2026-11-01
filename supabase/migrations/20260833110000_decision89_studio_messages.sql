-- Decision 89 — Studio messages (docs ## 89). Members message the studio; any
-- non-instructor staff role replies. One thread per member per studio; messages
-- never cross studios. Off by default (studio_settings.messages_enabled).
--
-- creates: member_messages(uuid), member_send_message(uuid, text, text, text, integer, text), staff_message_threads(uuid), staff_message_thread(uuid), staff_send_message(uuid, text, text, text, integer, text), staff_mark_thread_read(uuid)
-- re-issues: staff_bootstrap(), member_bootstrap(text), template_sample_context(uuid, text, text)
--
-- No service-role key anywhere: the member/staff client uploads an attachment
-- with its OWN session (storage RLS below), then calls an RPC with the path.
-- Every message write goes through a SECURITY DEFINER RPC — there is no
-- client INSERT grant on thread_messages/message_threads. Size and type are enforced in
-- the RPC too, never only at the bucket. Anon stays EXACTLY THIRTEEN.

-- ===========================================================================
-- 0. Setting
-- ===========================================================================
alter table studio_settings
  add column if not exists messages_enabled boolean not null default false;

-- ===========================================================================
-- 1. Tables
-- ===========================================================================
create table message_threads (
  id                  uuid primary key default gen_random_uuid(),
  studio_id           uuid not null references studios(id) on delete cascade,
  member_id           uuid not null references members(id) on delete cascade,
  last_message_at     timestamptz,
  last_member_read_at timestamptz,
  last_staff_read_at  timestamptz,
  created_at          timestamptz not null default now(),
  unique (studio_id, member_id)
);
create index message_threads_studio_idx
  on message_threads (studio_id, last_message_at desc nulls last);

create table thread_messages (
  id              uuid primary key default gen_random_uuid(),
  thread_id       uuid not null references message_threads(id) on delete cascade,
  studio_id       uuid not null references studios(id) on delete cascade,
  sender_kind     message_sender_kind not null,
  sender_user_id  uuid,
  body            text not null check (char_length(body) between 1 and 2000),
  attachment_path text,
  attachment_name text,
  attachment_bytes integer,
  attachment_mime text,
  created_at      timestamptz not null default now()
);
create index thread_messages_idx on thread_messages (thread_id, created_at);

-- ===========================================================================
-- 2. RLS — members read their own thread, staff (non-instructor) read their
--    studio. No INSERT/UPDATE/DELETE policy or grant: writes go through the RPCs.
-- ===========================================================================
alter table message_threads enable row level security;
alter table thread_messages        enable row level security;

create policy message_threads_member_read on message_threads for select to authenticated
  using (member_id in (select id from members where user_id = auth.uid()));
create policy message_threads_staff_read on message_threads for select to authenticated
  using (coalesce(is_desk_up(studio_id), false));

create policy thread_messages_member_read on thread_messages for select to authenticated
  using (thread_id in (
    select t.id from message_threads t
     where t.member_id in (select id from members where user_id = auth.uid())));
create policy thread_messages_staff_read on thread_messages for select to authenticated
  using (coalesce(is_desk_up(studio_id), false));

grant select on message_threads to authenticated;
grant select on thread_messages        to authenticated;
grant all    on message_threads to service_role;
grant all    on thread_messages        to service_role;

-- ===========================================================================
-- 3. Storage — a private bucket, 1 MB, photos + PDF. A member may insert/read
--    under {studio_id}/{thread_id}/ for a thread they own; staff of the studio
--    under {studio_id}/; nobody else. The client uploads with its own session.
-- ===========================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('message-attachments', 'message-attachments', false, 1048576,
        array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict (id) do nothing;

-- Staff of the studio (owner/manager/front_desk) — the whole studio prefix.
create policy msg_attach_staff_write on storage.objects for insert to authenticated
  with check (bucket_id = 'message-attachments'
    and coalesce(is_desk_up(((storage.foldername(name))[1])::uuid), false));
create policy msg_attach_staff_read on storage.objects for select to authenticated
  using (bucket_id = 'message-attachments'
    and coalesce(is_desk_up(((storage.foldername(name))[1])::uuid), false));

-- A member — only under a thread (segment 2) that belongs to them, in its studio.
create policy msg_attach_member_write on storage.objects for insert to authenticated
  with check (bucket_id = 'message-attachments' and exists (
    select 1 from message_threads t join members mm on mm.id = t.member_id
     where t.id = ((storage.foldername(name))[2])::uuid
       and t.studio_id = ((storage.foldername(name))[1])::uuid
       and mm.user_id = auth.uid()));
create policy msg_attach_member_read on storage.objects for select to authenticated
  using (bucket_id = 'message-attachments' and exists (
    select 1 from message_threads t join members mm on mm.id = t.member_id
     where t.id = ((storage.foldername(name))[2])::uuid
       and t.studio_id = ((storage.foldername(name))[1])::uuid
       and mm.user_id = auth.uid()));

-- ===========================================================================
-- 4. Member RPCs
-- ===========================================================================

-- member_messages — the caller's own thread for this studio (created if none),
-- newest 100 messages oldest→newest, and marks the member's read line.
create function member_messages(p_studio_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_member members%rowtype; v_thread message_threads%rowtype; v_msgs jsonb;
begin
  select * into v_member from members
   where user_id = auth.uid() and studio_id = p_studio_id and deleted_at is null;
  if not found then
    raise exception 'not a member of this studio' using errcode = 'PT403';
  end if;
  if not coalesce((select messages_enabled from studio_settings where studio_id = p_studio_id), false) then
    return jsonb_build_object('ok', false, 'reason', 'Messages are off for this studio');
  end if;

  insert into message_threads (studio_id, member_id)
  values (p_studio_id, v_member.id)
  on conflict (studio_id, member_id) do update set studio_id = excluded.studio_id
  returning * into v_thread;

  update message_threads set last_member_read_at = now() where id = v_thread.id;

  select coalesce(jsonb_agg(x order by x.created_at), '[]'::jsonb) into v_msgs from (
    select msg.id, msg.sender_kind, msg.body, msg.created_at,
           msg.attachment_path, msg.attachment_name, msg.attachment_bytes, msg.attachment_mime,
           case when msg.sender_kind = 'member'
                then coalesce(nullif(btrim(v_member.preferred_name), ''), v_member.first_name, 'You')
                else coalesce(split_part(pr.full_name, ' ', 1), 'The studio') end as sender_name
      from thread_messages msg
      left join profiles pr on pr.id = msg.sender_user_id
     where msg.thread_id = v_thread.id
     order by msg.created_at desc
     limit 100
  ) x;

  return jsonb_build_object('ok', true, 'thread_id', v_thread.id, 'messages', v_msgs);
end $$;

-- member_send_message — validate, create the thread on first message, insert,
-- and tell the studio (one email per message). Refusals as reasons.
create function member_send_message(
  p_studio_id uuid, p_body text,
  p_attachment_path text default null, p_attachment_name text default null,
  p_attachment_bytes integer default null, p_attachment_mime text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_member members%rowtype; v_thread message_threads%rowtype; v_studio studios%rowtype;
  v_msg uuid; v_owner uuid; v_name text; v_html text;
begin
  select * into v_member from members
   where user_id = auth.uid() and studio_id = p_studio_id and deleted_at is null;
  if not found then
    raise exception 'not a member of this studio' using errcode = 'PT403';
  end if;
  if not coalesce((select messages_enabled from studio_settings where studio_id = p_studio_id), false) then
    return jsonb_build_object('ok', false, 'reason', 'Messages are off for this studio');
  end if;

  if coalesce(btrim(p_body), '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'Write a message before sending.');
  end if;
  if char_length(p_body) > 2000 then
    return jsonb_build_object('ok', false, 'reason', 'Keep your message to 2000 characters or fewer.');
  end if;
  if p_attachment_path is not null then
    if coalesce(p_attachment_bytes, 0) > 1048576 then
      return jsonb_build_object('ok', false, 'reason', 'That file is over 1 MB. Try a smaller photo or PDF.');
    end if;
    if coalesce(p_attachment_mime, '') not in ('image/jpeg','image/png','image/webp','application/pdf') then
      return jsonb_build_object('ok', false, 'reason', 'Photos and PDFs only.');
    end if;
  end if;

  insert into message_threads (studio_id, member_id)
  values (p_studio_id, v_member.id)
  on conflict (studio_id, member_id) do update set studio_id = excluded.studio_id
  returning * into v_thread;

  insert into thread_messages (thread_id, studio_id, sender_kind, sender_user_id, body,
                        attachment_path, attachment_name, attachment_bytes, attachment_mime)
  values (v_thread.id, p_studio_id, 'member', auth.uid(), p_body,
          p_attachment_path, p_attachment_name,
          case when p_attachment_path is null then null else p_attachment_bytes end,
          case when p_attachment_path is null then null else p_attachment_mime end)
  returning id into v_msg;

  update message_threads set last_message_at = now(), last_member_read_at = now()
   where id = v_thread.id;

  -- Tell the studio. ONE email per member message — to the owner, the address
  -- existing studio-facing mail uses (platform warnings go to the owner). Keyed
  -- on the message id so a retry cannot double-send. The per-email switch applies
  -- (queue_shift_notice checks studio_template_enabled).
  select * into v_studio from studios where id = p_studio_id;
  v_name := coalesce(
    nullif(btrim(coalesce(v_member.first_name, '') || ' ' || coalesce(v_member.last_name, '')), ''),
    v_member.first_name, 'A member');
  v_html := replace(replace(replace(p_body, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
  v_html := replace(v_html, E'\n', '<br>');
  select ss.user_id into v_owner from studio_staff ss
   where ss.studio_id = p_studio_id and ss.role = 'owner' and ss.status = 'active'
   order by ss.created_at limit 1;
  if v_owner is not null then
    perform queue_shift_notice(
      p_studio_id, v_owner, 'message_to_studio',
      jsonb_build_object(
        'member_name', v_name,
        'message', p_body,
        'message_html', v_html,
        'reply_url', coalesce(nullif(notification_setting('staff_app_origin'), ''),
                              'https://app.studiior.com') || '/messages/' || v_thread.id::text,
        'studio_name', v_studio.name),
      'msg_to_studio:' || v_msg::text);
  end if;

  return jsonb_build_object('ok', true, 'message_id', v_msg, 'thread_id', v_thread.id);
end $$;

-- ===========================================================================
-- 5. Staff RPCs — guarded to non-instructor staff of the studio (is_desk_up).
-- ===========================================================================

-- staff_message_threads — the studio's threads with a message, newest first.
create function staff_message_threads(p_studio_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_rows jsonb;
begin
  if not (coalesce(is_desk_up(p_studio_id), false) or is_service_context()) then
    raise exception 'only studio staff can read messages' using errcode = 'PT403';
  end if;
  select coalesce(jsonb_agg(x order by x.last_message_at desc), '[]'::jsonb) into v_rows from (
    select t.id as thread_id, t.member_id,
      coalesce(nullif(btrim(m.preferred_name), ''),
               nullif(btrim(coalesce(m.first_name, '') || ' ' || coalesce(m.last_name, '')), ''),
               m.email) as member_name,
      m.avatar_url as photo_path,
      t.last_message_at,
      (select msg.body from thread_messages msg where msg.thread_id = t.id
        order by msg.created_at desc limit 1) as latest,
      exists (select 1 from thread_messages msg
               where msg.thread_id = t.id and msg.sender_kind = 'member'
                 and msg.created_at > coalesce(t.last_staff_read_at, 'epoch'::timestamptz)) as unread
    from message_threads t
    join members m on m.id = t.member_id
    where t.studio_id = p_studio_id and t.last_message_at is not null
  ) x;
  return v_rows;
end $$;

-- staff_message_thread — one thread: the exchange + the member header facts.
-- Read-only; opening marks read via staff_mark_thread_read.
create function staff_message_thread(p_thread_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_thread message_threads%rowtype; v_member members%rowtype;
  v_msgs jsonb; v_plan text; v_unpaid boolean; v_next jsonb;
begin
  select * into v_thread from message_threads where id = p_thread_id;
  if not found then raise exception 'no such thread' using errcode = 'PT404'; end if;
  if not (coalesce(is_desk_up(v_thread.studio_id), false) or is_service_context()) then
    raise exception 'only studio staff can read messages' using errcode = 'PT403';
  end if;
  select * into v_member from members where id = v_thread.member_id;

  select coalesce(jsonb_agg(x order by x.created_at), '[]'::jsonb) into v_msgs from (
    select msg.id, msg.sender_kind, msg.body, msg.created_at,
           msg.attachment_path, msg.attachment_name, msg.attachment_bytes, msg.attachment_mime,
           case when msg.sender_kind = 'member'
                then coalesce(nullif(btrim(v_member.preferred_name), ''), v_member.first_name, 'Member')
                else coalesce(split_part(pr.full_name, ' ', 1), 'Studio') end as sender_name
      from thread_messages msg
      left join profiles pr on pr.id = msg.sender_user_id
     where msg.thread_id = p_thread_id
  ) x;

  select mp.name into v_plan
    from memberships ms join membership_plans mp on mp.id = ms.plan_id
   where ms.member_id = v_member.id and ms.status not in ('cancelled', 'expired')
   order by ms.starts_on desc limit 1;

  v_unpaid := exists (
    select 1 from bookings b join class_occurrences o on o.id = b.occurrence_id
     where b.member_id = v_member.id and b.payment_source = 'drop_in'
       and b.status in ('booked', 'pending_payment') and o.starts_at > now()
       and not exists (select 1 from payments p where p.booking_id = b.id
                        and p.status in ('succeeded', 'partially_refunded')));

  select jsonb_build_object('class_name', coalesce(o.name, ct.name), 'starts_at', o.starts_at)
    into v_next
    from bookings b join class_occurrences o on o.id = b.occurrence_id
    left join class_types ct on ct.id = o.class_type_id
   where b.member_id = v_member.id and b.status in ('booked', 'attended')
     and o.starts_at > now() and o.status = 'scheduled'
   order by o.starts_at limit 1;

  return jsonb_build_object(
    'ok', true, 'thread_id', p_thread_id, 'member_id', v_member.id,
    'member_name', coalesce(
      nullif(btrim(v_member.preferred_name), ''),
      nullif(btrim(coalesce(v_member.first_name, '') || ' ' || coalesce(v_member.last_name, '')), ''),
      v_member.email),
    'plan_name', v_plan, 'has_unpaid_booking', v_unpaid, 'next_booking', v_next,
    'messages', v_msgs);
end $$;

-- staff_send_message — a studio reply. Validate, insert, email the member.
create function staff_send_message(
  p_thread_id uuid, p_body text,
  p_attachment_path text default null, p_attachment_name text default null,
  p_attachment_bytes integer default null, p_attachment_mime text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_thread message_threads%rowtype; v_member members%rowtype; v_studio studios%rowtype;
  v_msg uuid; v_fname text; v_html text;
begin
  select * into v_thread from message_threads where id = p_thread_id;
  if not found then raise exception 'no such thread' using errcode = 'PT404'; end if;
  if not (coalesce(is_desk_up(v_thread.studio_id), false) or is_service_context()) then
    raise exception 'only studio staff can reply' using errcode = 'PT403';
  end if;
  if not coalesce((select messages_enabled from studio_settings where studio_id = v_thread.studio_id), false) then
    return jsonb_build_object('ok', false, 'reason', 'Messages are off for this studio');
  end if;

  if coalesce(btrim(p_body), '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'Write a message before sending.');
  end if;
  if char_length(p_body) > 2000 then
    return jsonb_build_object('ok', false, 'reason', 'Keep your message to 2000 characters or fewer.');
  end if;
  if p_attachment_path is not null then
    if coalesce(p_attachment_bytes, 0) > 1048576 then
      return jsonb_build_object('ok', false, 'reason', 'That file is over 1 MB. Try a smaller photo or PDF.');
    end if;
    if coalesce(p_attachment_mime, '') not in ('image/jpeg','image/png','image/webp','application/pdf') then
      return jsonb_build_object('ok', false, 'reason', 'Photos and PDFs only.');
    end if;
  end if;

  insert into thread_messages (thread_id, studio_id, sender_kind, sender_user_id, body,
                        attachment_path, attachment_name, attachment_bytes, attachment_mime)
  values (p_thread_id, v_thread.studio_id, 'staff', auth.uid(), p_body,
          p_attachment_path, p_attachment_name,
          case when p_attachment_path is null then null else p_attachment_bytes end,
          case when p_attachment_path is null then null else p_attachment_mime end)
  returning id into v_msg;

  update message_threads set last_message_at = now(), last_staff_read_at = now()
   where id = p_thread_id;

  select * into v_member from members where id = v_thread.member_id;
  select * into v_studio from studios where id = v_thread.studio_id;
  select split_part(coalesce(pr.full_name, ss.email), ' ', 1) into v_fname
    from studio_staff ss left join profiles pr on pr.id = ss.user_id
   where ss.studio_id = v_thread.studio_id and ss.user_id = auth.uid() and ss.status = 'active'
   limit 1;
  v_html := replace(replace(replace(p_body, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
  v_html := replace(v_html, E'\n', '<br>');

  perform queue_notification(
    v_thread.studio_id, v_member.id, 'message_to_member',
    jsonb_build_object(
      'staff_first_name', coalesce(nullif(v_fname, ''), 'The studio'),
      'message', p_body,
      'message_html', v_html,
      'messages_url', member_portal_url(v_thread.studio_id, '/messages'),
      'studio_name', v_studio.name),
    'msg_to_member:' || v_msg::text);

  return jsonb_build_object('ok', true, 'message_id', v_msg, 'thread_id', p_thread_id);
end $$;

-- staff_mark_thread_read — opening a thread clears its unread.
create function staff_mark_thread_read(p_thread_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_studio uuid;
begin
  select studio_id into v_studio from message_threads where id = p_thread_id;
  if v_studio is null then raise exception 'no such thread' using errcode = 'PT404'; end if;
  if not (coalesce(is_desk_up(v_studio), false) or is_service_context()) then
    raise exception 'only studio staff can read messages' using errcode = 'PT403';
  end if;
  update message_threads set last_staff_read_at = now() where id = p_thread_id;
  return jsonb_build_object('ok', true);
end $$;

revoke execute on function member_messages(uuid)             from public, anon;
revoke execute on function member_send_message(uuid, text, text, text, integer, text) from public, anon;
revoke execute on function staff_message_threads(uuid)       from public, anon;
revoke execute on function staff_message_thread(uuid)        from public, anon;
revoke execute on function staff_send_message(uuid, text, text, text, integer, text) from public, anon;
revoke execute on function staff_mark_thread_read(uuid)      from public, anon;
grant  execute on function member_messages(uuid)             to authenticated, service_role;
grant  execute on function member_send_message(uuid, text, text, text, integer, text) to authenticated, service_role;
grant  execute on function staff_message_threads(uuid)       to authenticated, service_role;
grant  execute on function staff_message_thread(uuid)        to authenticated, service_role;
grant  execute on function staff_send_message(uuid, text, text, text, integer, text) to authenticated, service_role;
grant  execute on function staff_mark_thread_read(uuid)      to authenticated, service_role;

-- ===========================================================================
-- 6. Templates — in the 80a frame. {message}=plain for text, {message_html}=
--    HTML-escaped for the html body (render_email substitutes payload values raw).
-- ===========================================================================
insert into notification_templates (key, subject, text_body, html_body, note) values
 ('message_to_member',
  'New message from {studio_name}',
  E'Hi {first_name},\n\n{staff_first_name} replied to your message:\n\n> {message}\n\nOpen your messages: {messages_url}\n\n{studio_name}',
  '<p>Hi {first_name},</p>'
  '<p>{staff_first_name} replied to your message:</p>'
  '<blockquote style="margin:0;padding:10px 14px;border-left:3px solid {accent};background:#F5F5F4;border-radius:6px;color:#44403C">{message_html}</blockquote>'
  '<p style="margin-top:16px"><a href="{messages_url}" style="display:inline-block;background:{accent};color:{accent_on};text-decoration:none;padding:12px 22px;border-radius:10px;font-weight:600">Open message</a></p>'
  '<p>{studio_name}</p>',
  'Decision 89. Sent to a member when staff reply. {message_html} is the escaped body.'),
 ('message_to_studio',
  'New message from {member_name}',
  E'{member_name} sent a message:\n\n> {message}\n\nReply: {reply_url}',
  '<p><strong>{member_name}</strong> sent a message:</p>'
  '<blockquote style="margin:0;padding:10px 14px;border-left:3px solid {accent};background:#F5F5F4;border-radius:6px;color:#44403C">{message_html}</blockquote>'
  '<p style="margin-top:16px"><a href="{reply_url}" style="display:inline-block;background:{accent};color:{accent_on};text-decoration:none;padding:12px 22px;border-radius:10px;font-weight:600">Reply</a></p>',
  'Decision 89. Sent to the studio (owner) once per member message. {message_html} is the escaped body.')
on conflict (key) do update
  set subject = excluded.subject, text_body = excluded.text_body,
      html_body = excluded.html_body, note = excluded.note;

-- ===========================================================================
-- 7. template_sample_context — re-issued (newest body, 20260833090000) with the
--    message tokens so send_template_test / preview_template render cleanly.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.template_sample_context(p_studio_id uuid, p_to_email text, p_first_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s studios%rowtype; st studio_settings%rowtype; v_tz text; v_fmt text;
  v_plan membership_plans%rowtype; o record; v_when text; v_offer_ends text;
  v_n3 text; v_n3line text; v_n3html text; v_links text;
  v_clist text; v_roster text; v_roster_html text; v_li text;
begin
  select * into s from studios where id = p_studio_id;
  select * into st from studio_settings where studio_id = p_studio_id;
  v_tz := s.timezone; v_fmt := coalesce(st.time_format, '24h');

  select o2.id, coalesce(ct.name, o2.name, 'a class') as cname, o2.starts_at,
         rm.name as room, split_part(coalesce(i.display_name, ''), ' ', 1) as instr
    into o
    from class_occurrences o2
    left join class_types ct on ct.id = o2.class_type_id
    left join rooms rm on rm.id = o2.room_id
    left join instructors i on i.id = o2.instructor_id
   where o2.studio_id = p_studio_id and o2.status = 'scheduled' and o2.starts_at > now()
   order by o2.starts_at limit 1;

  if st.intro_offer_plan_id is not null then
    select * into v_plan from membership_plans where id = st.intro_offer_plan_id;
  end if;
  if v_plan.id is null then
    select * into v_plan from membership_plans
     where studio_id = p_studio_id and status = 'active' order by sort_order limit 1;
  end if;

  v_when := case when o.starts_at is not null
    then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD Mon') || ' at ' || fmt_clock(o.starts_at, v_tz, v_fmt)
    else '' end;
  v_offer_ends := to_char((now() + interval '14 days') at time zone v_tz, 'FMDD Mon YYYY');

  with s3(nm, ts) as (
    values
      ('Reformer Flow', ((((now() at time zone v_tz)::date + 1) + time '07:00') at time zone v_tz)),
      ('Barre',         ((((now() at time zone v_tz)::date + 2) + time '18:00') at time zone v_tz)),
      ('Mat Pilates',   ((((now() at time zone v_tz)::date + 3) + time '09:00') at time zone v_tz))
  )
  select
    string_agg(to_char(ts at time zone v_tz, 'FMDy ') || fmt_clock(ts, v_tz, v_fmt) || ' ' || nm, '; ' order by ts),
    string_agg('<a href="' || member_portal_url(p_studio_id, '/book') || '">'
               || to_char(ts at time zone v_tz, 'FMDy ') || fmt_clock(ts, v_tz, v_fmt) || ' ' || nm || '</a>', ', ' order by ts),
    string_agg(to_char(ts at time zone v_tz, 'FMDay FMDD FMMon, ') || fmt_clock(ts, v_tz, v_fmt) || ' ' || nm, E'\n' order by ts),
    string_agg('<li>' || to_char(ts at time zone v_tz, 'FMDay FMDD FMMon, ') || fmt_clock(ts, v_tz, v_fmt) || ' ' || nm || '</li>', '' order by ts)
    into v_n3, v_links, v_roster, v_li
    from s3;
  v_clist := v_roster;
  v_roster_html := '<ul style="margin:0;padding-left:20px">' || v_li || '</ul>';
  v_n3line := ' Here are the next ones with space: ' || v_n3 || '.';
  v_n3html := '<p>Here are the next ones with space: ' || v_links || '.</p>';

  return jsonb_build_object(
    'to_email', p_to_email,
    'first_name', p_first_name,
    'studio_name', s.name,
    'class_name', coalesce(o.cname, 'a class'),
    'occurrence_id', o.id,
    'when', v_when,
    'where_line', case when nullif(o.room, '') is not null then ', in ' || o.room else '' end,
    'when_short', 'tomorrow',
    'when_time', case when o.starts_at is not null then fmt_clock(o.starts_at, v_tz, v_fmt) else '' end,
    'day', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMonth') else 'Monday 9 November' end,
    'time', case when o.starts_at is not null then fmt_clock(o.starts_at, v_tz, v_fmt) else '' end,
    'deadline_short', case when o.starts_at is not null then fmt_clock(o.starts_at - interval '12 hours', v_tz, v_fmt) || ' ' || to_char((o.starts_at - interval '12 hours') at time zone v_tz, 'FMDy') else 'the evening before' end,
    'cancel_deadline', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD Mon') else 'the day before' end,
    'manage_link', member_portal_url(p_studio_id, '/class/' || coalesce(o.id::text, '')),
    'book_url', member_portal_url(p_studio_id, '/book'),
    'schedule_url', member_portal_url(p_studio_id, '/book'),
    'offer_plan_name', coalesce(v_plan.name, 'a membership'),
    'offer_detail', coalesce(plan_card_detail(v_plan.id), ''),
    'offer_price', case when v_plan.id is not null then fmt_money(v_plan.price_cents, v_plan.currency) else '' end,
    'offer_ends', v_offer_ends,
    'buy_url', case when v_plan.id is not null then member_portal_url(p_studio_id, '/buy/' || v_plan.id::text) else member_portal_url(p_studio_id, '/account/plan') end,
    'plan_name', coalesce(v_plan.name, 'your plan'),
    'credits', '3', 'credits_left', '3',
    'expires_on', v_offer_ends, 'ends_on', v_offer_ends,
    'renew_url', case when v_plan.id is not null then member_portal_url(p_studio_id, '/buy/' || v_plan.id::text) else member_portal_url(p_studio_id, '/account/plan') end,
    'last_class', coalesce(o.cname, 'your class'),
    'last_class_date', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDD Mon') else '' end,
    'instructor_first', coalesce(nullif(o.instr, ''), 'your instructor'),
    'instructor_first_name', coalesce(nullif(o.instr, ''), 'your instructor'),
    'days_since', '10',
    'product', 'Grip socks', 'quantity', '1')
  || jsonb_build_object(
    'instructor_name', p_first_name,
    'href', instructor_portal_url(p_studio_id, '/instructor/schedule'),
    'schedule_link', instructor_portal_url(p_studio_id, '/instructor/schedule'),
    'booked_line', '3 booked',
    'count', '3',
    'plural', 's',
    'month', to_char(now() at time zone v_tz, 'FMMonth'),
    'period', 'this period',
    'due_on', to_char((now() + interval '3 days') at time zone v_tz, 'FMDay FMDD Mon'),
    'due_wording', 'soon',
    'hours', '12',
    'amount', fmt_money(90000, s.currency),
    'old_when', case when o.starts_at is not null
                     then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMonth YYYY, ') || fmt_clock(o.starts_at, v_tz, v_fmt)
                     else 'Monday 9 November, 07:00' end,
    'cancelled_count', '1',
    'booked', '4',
    'capacity', '8',
    'reason', 'cancelled by the studio',
    'claim_url', member_portal_url(p_studio_id, '/class/' || coalesce(o.id::text, '')))
  || jsonb_build_object(
    'next_three', v_n3,
    'next_three_line', v_n3line,
    'next_three_html', v_n3html,
    'class_list', v_clist,
    'roster', v_roster,
    'roster_html', v_roster_html)
  -- Decision 89: the Messages templates' tokens, so a test send / preview fills.
  || jsonb_build_object(
    'staff_first_name', p_first_name,
    'member_name', coalesce(nullif(p_first_name, ''), 'A member'),
    'message', 'Hi, could I move my Saturday class to Sunday?',
    'message_html', 'Hi, could I move my Saturday class to Sunday?',
    'messages_url', member_portal_url(p_studio_id, '/messages'),
    'reply_url', coalesce(nullif(notification_setting('staff_app_origin'), ''), 'https://app.studiior.com') || '/messages');
end $function$;

revoke execute on function template_sample_context(uuid, text, text) from public, anon, authenticated;
grant  execute on function template_sample_context(uuid, text, text) to service_role;

-- ===========================================================================
-- 8. member_bootstrap — re-issued (newest body, 20260832260000) + messages_enabled.
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
   trial_used boolean, messages_enabled boolean)
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
    coalesce(st.messages_enabled, false)
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

-- ===========================================================================
-- 9. staff_bootstrap — re-issued (newest body, 20260832130000) + unread_messages.
--    One scalar more in the same single-row select — no new wave. Counts only for
--    a non-instructor staff role (an instructor sees no messages).
-- ===========================================================================
drop function if exists staff_bootstrap();
create function staff_bootstrap()
 returns table(staff_id uuid, user_id uuid, email text, role staff_role, studio_id uuid,
   studio_name text, studio_timezone text, studio_currency character, studio_status text,
   location_name text, onboarding_complete boolean, is_platform_admin boolean,
   billing_status platform_status, billing_locked boolean, billing_days_left integer,
   studio_week_starts_on integer, publication_enabled boolean, time_format text,
   unread_messages integer, messages_enabled boolean)
 language sql stable security definer set search_path to 'public' as $function$
  select
    ss.id, ss.user_id, ss.email, ss.role, ss.studio_id,
    s.name, s.timezone, s.currency, s.status,
    (select l.name from locations l
      where l.studio_id = ss.studio_id and l.is_primary
      order by l.created_at limit 1),
    st.onboarding_completed_at is not null,
    is_platform_admin(),
    ps.status,
    coalesce(ps.status = 'locked', false),
    greatest(0, extract(day from
      coalesce(ps.grace_ends_at, ps.trial_ends_at) - now())::int),
    coalesce(st.week_starts_on, 1),
    coalesce(st.publication_enabled, false),
    coalesce(st.time_format, '24h'),
    case when ss.role in ('owner', 'manager', 'front_desk') then coalesce((
      select count(*)::int from message_threads mt
       where mt.studio_id = ss.studio_id
         and exists (select 1 from thread_messages msg
                      where msg.thread_id = mt.id and msg.sender_kind = 'member'
                        and msg.created_at > coalesce(mt.last_staff_read_at, 'epoch'::timestamptz))), 0)
    else 0 end,
    coalesce(st.messages_enabled, false)
  from studio_staff ss
  join studios s on s.id = ss.studio_id
  left join studio_settings st on st.studio_id = ss.studio_id
  left join platform_subscriptions ps on ps.studio_id = ss.studio_id
  where ss.user_id = auth.uid()
    and ss.status = 'active'
  order by ss.created_at
  limit 1
$function$;
revoke execute on function staff_bootstrap() from public, anon;
grant  execute on function staff_bootstrap() to authenticated, service_role;

-- ===========================================================================
-- Anon surface unchanged: exactly THIRTEEN (Decision 89 adds no anon function).
-- ===========================================================================
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % (expected 13 — Decision 89 adds no anon function)', n; end if;
end $$;
