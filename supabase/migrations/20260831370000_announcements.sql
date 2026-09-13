-- Decision 27 — studio announcements. A studio posts something and members see
-- it on Home: a workshop, a closure, a new instructor, a price change, an event.
--
-- ONE-WAY, studio to members. NOT a feed and NOT community — Decision 13 excluded
-- posts, comments, likes and friend connections from V1 and that stands. There
-- are no replies, no reactions, no member-authored anything here, and this must
-- not grow into one. Recorded in the decision log so the next session does not
-- turn it into a feed.
--
-- Optional per studio BY EXISTENCE, the challenge pattern: a studio with no
-- published announcement in range shows no section on Home, absent not empty.
-- No switch — the staff admin is always reachable (every studio posts a closure
-- sooner or later), and member visibility is pure existence.

create table announcements (
  id             uuid primary key default gen_random_uuid(),
  studio_id      uuid not null references studios on delete cascade,
  title          text not null,
  body           text not null,
  image_url      text,
  image_focus_x  smallint not null default 50 check (image_focus_x between 0 and 100),
  image_focus_y  smallint not null default 50 check (image_focus_y between 0 and 100),
  starts_at      timestamptz not null default now(),
  ends_at        timestamptz,                    -- null = open-ended
  status         text not null default 'draft'
                   check (status in ('draft','published')),
  -- who it is for. "closed for Christmas" wants both; "new intro offer" wants
  -- members only. Instructor-audience ones surface in the portal (096/097).
  audience       text not null default 'members'
                   check (audience in ('members','instructors','both')),
  pinned         boolean not null default false,  -- stays up until it ends
  notified_at    timestamptz,                     -- when it was emailed, if ever
  created_by     uuid references profiles on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index announcements_studio on announcements (studio_id, status, starts_at);

-- A member dismisses one they have read, so it is not shown every day.
create table announcement_dismissals (
  announcement_id uuid not null references announcements on delete cascade,
  member_id       uuid not null references members on delete cascade,
  dismissed_at    timestamptz not null default now(),
  primary key (announcement_id, member_id)
);

alter table announcements enable row level security;
alter table announcement_dismissals enable row level security;

-- Managers and up run the admin; members and instructors read what is published,
-- in range, and for their audience. Every WRITE is through the SECURITY DEFINER
-- functions below (owned by postgres, bypassing RLS), so these are read policies
-- plus the manager catch-all for a direct cover update.
create policy announcements_staff on announcements
  for all using (coalesce(is_manager_up(studio_id), false))
  with check (coalesce(is_manager_up(studio_id), false));
create policy announcements_member_read on announcements for select using (
  status = 'published' and now() >= starts_at and (ends_at is null or now() < ends_at)
  and audience in ('members','both')
  and studio_id in (select auth_member_studios())
);
create policy announcements_instructor_read on announcements for select using (
  status = 'published' and now() >= starts_at and (ends_at is null or now() < ends_at)
  and audience in ('instructors','both')
  and studio_id in (select auth_staff_studios())
);
create policy dismissals_self on announcement_dismissals for all using (
  member_id in (select id from members where user_id = auth.uid())
) with check (
  member_id in (select id from members where user_id = auth.uid())
);

grant select on announcements to authenticated;
grant select, insert on announcement_dismissals to authenticated;

-- ---------------------------------------------------------------------------
-- Staff CRUD. Manager-up, and every write refuses a studio the caller does not
-- manage. Create/edit leave status alone (draft on create); publishing is its
-- own step, so a half-written announcement is never live.
-- ---------------------------------------------------------------------------
create function create_announcement(p_studio_id uuid, p_title text, p_body text,
    p_starts_at timestamptz, p_ends_at timestamptz, p_audience text, p_pinned boolean default false)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers post announcements' using errcode = 'PT403';
  end if;
  if coalesce(btrim(p_title),'') = '' or coalesce(btrim(p_body),'') = '' then
    raise exception 'an announcement needs a title and a body' using errcode = 'PT422';
  end if;
  if p_ends_at is not null and p_ends_at <= coalesce(p_starts_at, now()) then
    raise exception 'the end must be after the start' using errcode = 'PT422';
  end if;
  insert into announcements (studio_id, title, body, starts_at, ends_at, audience, pinned, created_by)
  values (p_studio_id, btrim(p_title), btrim(p_body), coalesce(p_starts_at, now()), p_ends_at,
          coalesce(nullif(p_audience,''),'members'), coalesce(p_pinned,false), auth.uid())
  returning id into v_id;
  return v_id;
end $$;

create function update_announcement(p_id uuid, p_title text, p_body text,
    p_starts_at timestamptz, p_ends_at timestamptz, p_audience text, p_pinned boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare a announcements%rowtype;
begin
  select * into a from announcements where id = p_id;
  if not found then raise exception 'no such announcement' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(a.studio_id), false) then
    raise exception 'only owners and managers edit announcements' using errcode = 'PT403';
  end if;
  if coalesce(btrim(p_title),'') = '' or coalesce(btrim(p_body),'') = '' then
    raise exception 'an announcement needs a title and a body' using errcode = 'PT422';
  end if;
  if p_ends_at is not null and p_ends_at <= coalesce(p_starts_at, a.starts_at) then
    raise exception 'the end must be after the start' using errcode = 'PT422';
  end if;
  update announcements set title = btrim(p_title), body = btrim(p_body),
    starts_at = coalesce(p_starts_at, starts_at), ends_at = p_ends_at,
    audience = coalesce(nullif(p_audience,''), audience), pinned = coalesce(p_pinned, pinned),
    updated_at = now()
   where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- Publishing is the moment it becomes visible, and optionally the moment it is
-- emailed. A studio that emails every announcement trains members to ignore
-- them, so notify is OPT-IN and off by default; a closure is the case where it
-- genuinely should. Notifies MEMBERS of the audience (instructors see it in the
-- portal); once, keyed on the announcement, and never re-sent on a re-publish.
create function publish_announcement(p_id uuid, p_notify boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare a announcements%rowtype; v_sent int := 0; r record;
begin
  select * into a from announcements where id = p_id;
  if not found then raise exception 'no such announcement' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(a.studio_id), false) then
    raise exception 'only owners and managers publish announcements' using errcode = 'PT403';
  end if;

  update announcements set status = 'published', updated_at = now() where id = p_id;

  if coalesce(p_notify, false) and a.notified_at is null and a.audience in ('members','both') then
    for r in select id from members
              where studio_id = a.studio_id and status <> 'archived' and not is_demo
    loop
      if queue_notification(a.studio_id, r.id, 'announcement_posted',
           jsonb_build_object('title', a.title,
                              'body', left(a.body, 500)),
           'announcement:' || p_id || ':' || r.id) is not null then
        v_sent := v_sent + 1;
      end if;
    end loop;
    update announcements set notified_at = now() where id = p_id;
  end if;

  return jsonb_build_object('ok', true, 'notified', v_sent);
end $$;

create function unpublish_announcement(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a announcements%rowtype;
begin
  select * into a from announcements where id = p_id;
  if not found then raise exception 'no such announcement' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(a.studio_id), false) then
    raise exception 'not authorised' using errcode = 'PT403';
  end if;
  update announcements set status = 'draft', updated_at = now() where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

create function delete_announcement(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a announcements%rowtype;
begin
  select * into a from announcements where id = p_id;
  if not found then raise exception 'no such announcement' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(a.studio_id), false) then
    raise exception 'not authorised' using errcode = 'PT403';
  end if;
  delete from announcements where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

create function staff_announcements(p_studio_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'not authorised' using errcode = 'PT403';
  end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'id', a.id, 'title', a.title, 'body', a.body, 'image_url', a.image_url,
      'image_focus_x', a.image_focus_x, 'image_focus_y', a.image_focus_y,
      'starts_at', a.starts_at, 'ends_at', a.ends_at, 'status', a.status,
      'audience', a.audience, 'pinned', a.pinned, 'notified_at', a.notified_at)
      order by a.pinned desc, a.starts_at desc), '[]'::jsonb)
    from announcements a where a.studio_id = p_studio_id);
end $$;

-- ---------------------------------------------------------------------------
-- Member read — published, in range, for members, NOT dismissed by this member,
-- pinned first then newest. Empty array for a studio with none, so the Home
-- section renders nothing (the challenge pattern).
-- ---------------------------------------------------------------------------
create function member_announcements(p_studio_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_member uuid;
begin
  select m.id into v_member from members m
   where m.studio_id = p_studio_id and m.user_id = auth.uid();
  if v_member is null then
    raise exception 'you are not a member of that studio' using errcode = 'PT403';
  end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'id', a.id, 'title', a.title, 'body', a.body, 'image_url', a.image_url,
      'image_focus_x', a.image_focus_x, 'image_focus_y', a.image_focus_y,
      'pinned', a.pinned, 'starts_at', a.starts_at)
      order by a.pinned desc, a.starts_at desc), '[]'::jsonb)
    from announcements a
   where a.studio_id = p_studio_id and a.status = 'published'
     and now() >= a.starts_at and (a.ends_at is null or now() < a.ends_at)
     and a.audience in ('members','both')
     and not exists (select 1 from announcement_dismissals d
                      where d.announcement_id = a.id and d.member_id = v_member));
end $$;

create function dismiss_announcement(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_member uuid; v_studio uuid;
begin
  select studio_id into v_studio from announcements where id = p_id;
  if v_studio is null then raise exception 'no such announcement' using errcode = 'PT404'; end if;
  select m.id into v_member from members m where m.studio_id = v_studio and m.user_id = auth.uid();
  if v_member is null then raise exception 'not authorised' using errcode = 'PT403'; end if;
  insert into announcement_dismissals (announcement_id, member_id)
  values (p_id, v_member) on conflict do nothing;
  return jsonb_build_object('ok', true);
end $$;

-- Instructor read — the portal. Audience instructors/both, no dismissal (a
-- roster-relevant notice is not something to swipe away).
create function instructor_announcements(p_studio_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if p_studio_id not in (select auth_staff_studios()) then
    raise exception 'not authorised' using errcode = 'PT403';
  end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'id', a.id, 'title', a.title, 'body', a.body, 'image_url', a.image_url,
      'image_focus_x', a.image_focus_x, 'image_focus_y', a.image_focus_y,
      'pinned', a.pinned, 'starts_at', a.starts_at)
      order by a.pinned desc, a.starts_at desc), '[]'::jsonb)
    from announcements a
   where a.studio_id = p_studio_id and a.status = 'published'
     and now() >= a.starts_at and (a.ends_at is null or now() < a.ends_at)
     and a.audience in ('instructors','both'));
end $$;

-- The email, for a studio that opts to send one. Placeholders single-brace.
insert into notification_templates (key, subject, text_body, html_body, note) values
('announcement_posted', '{title} — {studio_name}',
 E'Hi {first_name},\n\n{title}\n\n{body}\n\n{studio_name}',
 E'<p>Hi {first_name},</p><h3>{title}</h3><p>{body}</p>',
 'Decision 27. Sent only when a studio chooses to notify on publishing an announcement.');

revoke execute on function create_announcement(uuid, text, text, timestamptz, timestamptz, text, boolean) from public, anon;
revoke execute on function update_announcement(uuid, text, text, timestamptz, timestamptz, text, boolean) from public, anon;
revoke execute on function publish_announcement(uuid, boolean)   from public, anon;
revoke execute on function unpublish_announcement(uuid)          from public, anon;
revoke execute on function delete_announcement(uuid)             from public, anon;
revoke execute on function staff_announcements(uuid)             from public, anon;
revoke execute on function member_announcements(uuid)            from public, anon;
revoke execute on function instructor_announcements(uuid)        from public, anon;
revoke execute on function dismiss_announcement(uuid)            from public, anon;
grant  execute on function create_announcement(uuid, text, text, timestamptz, timestamptz, text, boolean) to authenticated;
grant  execute on function update_announcement(uuid, text, text, timestamptz, timestamptz, text, boolean) to authenticated;
grant  execute on function publish_announcement(uuid, boolean)   to authenticated;
grant  execute on function unpublish_announcement(uuid)          to authenticated;
grant  execute on function delete_announcement(uuid)             to authenticated;
grant  execute on function staff_announcements(uuid)             to authenticated, service_role;
grant  execute on function member_announcements(uuid)            to authenticated;
grant  execute on function instructor_announcements(uuid)        to authenticated;
grant  execute on function dismiss_announcement(uuid)            to authenticated;
