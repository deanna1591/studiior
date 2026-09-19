-- Decision 27 AMENDMENT — announcements are two TYPES, gain a link, and the
-- built-in free-first banner is retired in their favour.
--
-- Migration 166 added a one-line dismissible strip at the top of /book for
-- *pinned* posts, but "pinned" was doing two jobs (first-in-What's-on AND the
-- strip) and a full What's-on post is the wrong shape for a one-line strip.
-- This splits the concept:
--   kind='post'   — what exists today (title, body, photo, dates, pinned) in
--                   the "What's on" section, pinned first.
--   kind='banner' — title only (<=120 chars), no body, no photo, rendered as
--                   the dismissible one-line strip at the top of Home AND Book.
-- THE STRIP NOW SHOWS kind='banner' ONLY; pinned no longer drives it.
-- Every existing row becomes 'post' by the default, so nothing published moves.
--
-- Plus an optional link on ANY announcement (link_url https-only, link_label
-- default "Learn more"): a button under a post's body, or — on a banner —
-- tapping the strip opens it. No switch, existence still governs visibility.

alter table announcements
  add column kind       text not null default 'post' check (kind in ('post','banner')),
  add column link_url   text,
  add column link_label text;

-- https only, validated at rest as well as in the writer (an http:// link in a
-- banner is a downgrade a member should never be handed).
alter table announcements add constraint announcements_link_https
  check (link_url is null or link_url like 'https://%');
-- A banner is one short line.
alter table announcements add constraint announcements_banner_len
  check (kind <> 'banner' or char_length(title) <= 120);

-- ---------------------------------------------------------------------------
-- Staff CRUD gains kind + the two link fields. Adding parameters to a function
-- creates an OVERLOAD rather than replacing it (migration 028's trap), and an
-- ambiguous 7-arg/10-arg pair would break every call — so the old signatures
-- are DROPPED and recreated, and the ACL (which a drop discards) re-asserted
-- at the bottom.
-- ---------------------------------------------------------------------------
drop function if exists create_announcement(uuid, text, text, timestamptz, timestamptz, text, boolean);
drop function if exists update_announcement(uuid, text, text, timestamptz, timestamptz, text, boolean);

create function create_announcement(p_studio_id uuid, p_title text, p_body text,
    p_starts_at timestamptz, p_ends_at timestamptz, p_audience text,
    p_pinned boolean default false, p_kind text default 'post',
    p_link_url text default null, p_link_label text default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_kind text; v_link text; v_label text;
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers post announcements' using errcode = 'PT403';
  end if;
  v_kind := coalesce(nullif(p_kind,''),'post');
  if v_kind not in ('post','banner') then
    raise exception 'an announcement is a post or a banner' using errcode = 'PT422';
  end if;
  if coalesce(btrim(p_title),'') = '' then
    raise exception 'an announcement needs a title' using errcode = 'PT422';
  end if;
  -- A post needs a body; a banner is title-only and its body is stored empty.
  if v_kind = 'post' and coalesce(btrim(p_body),'') = '' then
    raise exception 'a What''s-on post needs a body' using errcode = 'PT422';
  end if;
  if v_kind = 'banner' and char_length(btrim(p_title)) > 120 then
    raise exception 'a banner is one short line (up to 120 characters)' using errcode = 'PT422';
  end if;
  v_link := nullif(btrim(coalesce(p_link_url,'')),'');
  if v_link is not null and v_link !~ '^https://' then
    raise exception 'a link must start with https://' using errcode = 'PT422';
  end if;
  v_label := case when v_link is not null
                  then coalesce(nullif(btrim(coalesce(p_link_label,'')),''),'Learn more')
                  else null end;
  if p_ends_at is not null and p_ends_at <= coalesce(p_starts_at, now()) then
    raise exception 'the end must be after the start' using errcode = 'PT422';
  end if;
  insert into announcements (studio_id, kind, title, body, starts_at, ends_at, audience,
                             pinned, link_url, link_label, created_by)
  values (p_studio_id, v_kind, btrim(p_title),
          case when v_kind = 'banner' then '' else btrim(p_body) end,
          coalesce(p_starts_at, now()), p_ends_at, coalesce(nullif(p_audience,''),'members'),
          case when v_kind = 'banner' then false else coalesce(p_pinned,false) end,
          v_link, v_label, auth.uid())
  returning id into v_id;
  return v_id;
end $$;

create function update_announcement(p_id uuid, p_title text, p_body text,
    p_starts_at timestamptz, p_ends_at timestamptz, p_audience text, p_pinned boolean,
    p_kind text default null, p_link_url text default null, p_link_label text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare a announcements%rowtype; v_kind text; v_link text; v_label text;
begin
  select * into a from announcements where id = p_id;
  if not found then raise exception 'no such announcement' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(a.studio_id), false) then
    raise exception 'only owners and managers edit announcements' using errcode = 'PT403';
  end if;
  v_kind := coalesce(nullif(p_kind,''), a.kind);
  if v_kind not in ('post','banner') then
    raise exception 'an announcement is a post or a banner' using errcode = 'PT422';
  end if;
  if coalesce(btrim(p_title),'') = '' then
    raise exception 'an announcement needs a title' using errcode = 'PT422';
  end if;
  if v_kind = 'post' and coalesce(btrim(p_body),'') = '' then
    raise exception 'a What''s-on post needs a body' using errcode = 'PT422';
  end if;
  if v_kind = 'banner' and char_length(btrim(p_title)) > 120 then
    raise exception 'a banner is one short line (up to 120 characters)' using errcode = 'PT422';
  end if;
  v_link := nullif(btrim(coalesce(p_link_url,'')),'');
  if v_link is not null and v_link !~ '^https://' then
    raise exception 'a link must start with https://' using errcode = 'PT422';
  end if;
  v_label := case when v_link is not null
                  then coalesce(nullif(btrim(coalesce(p_link_label,'')),''),'Learn more')
                  else null end;
  if p_ends_at is not null and p_ends_at <= coalesce(p_starts_at, a.starts_at) then
    raise exception 'the end must be after the start' using errcode = 'PT422';
  end if;
  update announcements set
    kind = v_kind,
    title = btrim(p_title),
    body = case when v_kind = 'banner' then '' else btrim(p_body) end,
    -- Switching a post to a banner drops its photo — a banner has none.
    image_url = case when v_kind = 'banner' then null else image_url end,
    starts_at = coalesce(p_starts_at, starts_at), ends_at = p_ends_at,
    audience = coalesce(nullif(p_audience,''), audience),
    pinned = case when v_kind = 'banner' then false else coalesce(p_pinned, pinned) end,
    link_url = v_link, link_label = v_label,
    updated_at = now()
   where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------------
-- Readers carry kind + the link fields. staff sees everything; member/instructor
-- see published, in range, for their audience. The app splits banner (strip)
-- from post (What's on) — the SQL returns both and never decides layout.
-- ---------------------------------------------------------------------------
create or replace function staff_announcements(p_studio_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'not authorised' using errcode = 'PT403';
  end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'id', a.id, 'kind', a.kind, 'title', a.title, 'body', a.body, 'image_url', a.image_url,
      'image_focus_x', a.image_focus_x, 'image_focus_y', a.image_focus_y,
      'link_url', a.link_url, 'link_label', a.link_label,
      'starts_at', a.starts_at, 'ends_at', a.ends_at, 'status', a.status,
      'audience', a.audience, 'pinned', a.pinned, 'notified_at', a.notified_at)
      order by a.pinned desc, a.starts_at desc), '[]'::jsonb)
    from announcements a where a.studio_id = p_studio_id);
end $$;

create or replace function member_announcements(p_studio_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_member uuid;
begin
  select m.id into v_member from members m
   where m.studio_id = p_studio_id and m.user_id = auth.uid();
  if v_member is null then
    raise exception 'you are not a member of that studio' using errcode = 'PT403';
  end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'id', a.id, 'kind', a.kind, 'title', a.title, 'body', a.body, 'image_url', a.image_url,
      'image_focus_x', a.image_focus_x, 'image_focus_y', a.image_focus_y,
      'link_url', a.link_url, 'link_label', a.link_label,
      'pinned', a.pinned, 'starts_at', a.starts_at)
      order by a.pinned desc, a.starts_at desc), '[]'::jsonb)
    from announcements a
   where a.studio_id = p_studio_id and a.status = 'published'
     and now() >= a.starts_at and (a.ends_at is null or now() < a.ends_at)
     and a.audience in ('members','both')
     and not exists (select 1 from announcement_dismissals d
                      where d.announcement_id = a.id and d.member_id = v_member));
end $$;

create or replace function instructor_announcements(p_studio_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if p_studio_id not in (select auth_staff_studios()) then
    raise exception 'not authorised' using errcode = 'PT403';
  end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'id', a.id, 'kind', a.kind, 'title', a.title, 'body', a.body, 'image_url', a.image_url,
      'image_focus_x', a.image_focus_x, 'image_focus_y', a.image_focus_y,
      'link_url', a.link_url, 'link_label', a.link_label,
      'pinned', a.pinned, 'starts_at', a.starts_at)
      order by a.pinned desc, a.starts_at desc), '[]'::jsonb)
    from announcements a
   where a.studio_id = p_studio_id and a.status = 'published'
     and now() >= a.starts_at and (a.ends_at is null or now() < a.ends_at)
     and a.audience in ('instructors','both'));
end $$;

-- Re-assert the ACL the two dropped functions lost (a drop discards it; a
-- create is born with the hosted default anon grant). CLAUDE.md's rule.
revoke execute on function create_announcement(uuid, text, text, timestamptz, timestamptz, text, boolean, text, text, text) from public, anon;
revoke execute on function update_announcement(uuid, text, text, timestamptz, timestamptz, text, boolean, text, text, text) from public, anon;
grant  execute on function create_announcement(uuid, text, text, timestamptz, timestamptz, text, boolean, text, text, text) to authenticated;
grant  execute on function update_announcement(uuid, text, text, timestamptz, timestamptz, text, boolean, text, text, text) to authenticated;

-- Anon surface must stay exactly eleven.
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 11 then
    raise exception 'anon surface is % (expected 11)', n;
  end if;
end $$;
