-- =============================================================================
-- Migration 112 — Decision 25, part one: a month is a draft until the studio
-- publishes it
-- =============================================================================
-- The cycle this completes:
--
--   1. instructors submit next month's availability (Decision 18, built)
--   2. staff run "fill a month" — the engine assigns (built)
--   3. staff review, adjust, and PUBLISH the month                  ← here
--   4. on publish, each instructor gets their own roster to confirm  ← here, 113
--   5. each week during the month they confirm the week (067, built)
--
-- Both confirmations stay. The month is the agreement; the week is the check-in.
--
-- OPTIONAL, NOT MERELY CONFIGURABLE — Decision 24's rule again. A studio that
-- never turns this on sees no draft state, no publish button, no month gate
-- and no roster email: `publication_enabled` defaults false, and every predicate
-- below answers "published" for a studio with the switch off. Reform Collective
-- is the only studio that wants this; a simple studio must see none of it.
--
-- PER STUDIO PER MONTH, NOT A STATE ON THE OCCURRENCE. A month is the unit a
-- studio thinks in, and it makes the edge cases fall out rather than need
-- code: a class added to a published month is published because its month is,
-- with no trigger stamping rows; publishing twice finds the row and does
-- nothing; and "unpublish" is not offered because there is no writer for it —
-- no UPDATE or DELETE policy, no function.
--
-- "PUBLISHED" IS DERIVED, ONE PREDICATE, READ BY EVERYTHING. month_published()
-- is asked by the two RLS policies, book_class(), the instructor readers, the
-- flex sweep and the notification seam. A second definition of "may a member
-- see this" would disagree with the first about a 23:30 class on the last day
-- of the month the first time a studio west of Greenwich turned it on.
--
-- HISTORY IS PUBLISHED BY DEFINITION. A month that has already ended happened;
-- hiding it from an instructor's earlier weeks or a member's own history
-- because nobody pressed a button months after the fact would be the switch
-- rewriting the past. The predicate therefore answers true for any month
-- before the studio's current one, and turning the switch on publishes the
-- current month automatically (see set_publication_enabled) — it has already
-- started, which is the same fact.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. The switch, and the publications
-- -----------------------------------------------------------------------------
alter table studio_settings
  add column publication_enabled boolean not null default false;

comment on column studio_settings.publication_enabled is
  'Decision 25. When true, a month is a draft — invisible to members and to '
  'instructors, unbookable, and telling nobody — until the studio publishes it '
  'with publish_month(). False by default; a studio that never turns it on '
  'works exactly as before this column existed.';

create table schedule_publications (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid not null references studios(id) on delete cascade,
  -- The first day of the month, in the studio's own calendar. A CHECK rather
  -- than trusting callers to normalise.
  month         date not null,
  published_at  timestamptz not null default now(),
  published_by  uuid references auth.users(id) on delete set null,
  -- True when set_publication_enabled() published it because it had already
  -- started or already had members booked into it — nothing was emailed and
  -- nobody was asked to confirm, and the screen says so rather than showing a
  -- roster nobody sent.
  auto          boolean not null default false,
  -- What was true at the moment of publishing, so "we published with three
  -- holes" is a fact on the record rather than something reconstructed later.
  classes       int not null default 0,
  open_shifts   int not null default 0,
  constraint schedule_publications_month_is_first
    check (month = date_trunc('month', month)::date),
  unique (studio_id, month)
);

comment on table schedule_publications is
  'Decision 25. One row per studio per month that has been published. Absence '
  'means draft (when the studio''s switch is on). There is deliberately no way '
  'to remove a row: a month members have booked into cannot be withdrawn.';

alter table schedule_publications enable row level security;

-- Every staff role may READ which months are published — an instructor's own
-- portal has to be able to say "October is not out yet" rather than draw an
-- empty week. Nobody writes through the table: publish_month() is the only
-- writer and it is SECURITY DEFINER, so no INSERT policy and no INSERT grant.
create policy publications_staff_read on schedule_publications for select
  using (studio_id in (select auth_staff_studios()));

-- Default privileges on this stack (and on hosted) hand `authenticated` every
-- verb on a new table, so SELECT alone is not what it looks like: the other
-- three have to be taken away by name, and the assertion at the end checks.
revoke all on schedule_publications from public, anon, authenticated;
grant select on schedule_publications to authenticated;
grant all    on schedule_publications to service_role;

-- Who has been sent their roster for a month, and (migration 113) who has
-- confirmed it. One row per instructor per published month they had classes
-- in. Created here because publish_month() writes the notified half.
create table roster_confirmations (
  id                uuid primary key default gen_random_uuid(),
  studio_id         uuid not null references studios(id) on delete cascade,
  instructor_id     uuid not null references instructors(id) on delete cascade,
  month             date not null,
  classes_at_notify int  not null default 0,
  -- Null when the instructor had no login to send it to. The publish result
  -- names them, because "published" must not imply "everybody was told".
  notified_at       timestamptz,
  confirmed_at      timestamptz,
  constraint roster_confirmations_month_is_first
    check (month = date_trunc('month', month)::date),
  unique (studio_id, instructor_id, month)
);

alter table roster_confirmations enable row level security;

-- Managers read the lot; an instructor reads their own row. Written only by
-- functions.
create policy roster_conf_manager_read on roster_confirmations for select
  using (is_manager_up(studio_id));
create policy roster_conf_own_read on roster_confirmations for select
  using (instructor_id = auth_instructor_id(studio_id));

revoke all on roster_confirmations from public, anon, authenticated;
grant select on roster_confirmations to authenticated;
grant all    on roster_confirmations to service_role;

-- -----------------------------------------------------------------------------
-- 2. The predicates
-- -----------------------------------------------------------------------------
-- Is the switch on. An internal; nothing outside should ask it directly.
create function publication_enabled(p_studio_id uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select st.publication_enabled from studio_settings st
                    where st.studio_id = p_studio_id), false)
$$;

-- THE predicate. May a member see, and book, a class at this instant; may an
-- instructor see it; may a sweep decide it. True when the switch is off, true
-- for any month before the studio's current one, otherwise true only when a
-- publication row exists for that studio-local month.
--
-- Studio-local: a class at 23:30 UTC on 30 September is 1 October in Manila
-- and belongs to October there. Every other day boundary in this codebase is
-- resolved the same way (070, 091) and this one must agree with them.
--
-- coalesce(..., false): a boolean guard that can return null is the hole
-- migration 020 closed, and this one is asked inside `if not ...`.
create function month_published(p_studio_id uuid, p_at timestamptz)
returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select case
      when not publication_enabled(p_studio_id) then true
      when date_trunc('month', p_at at time zone s.timezone)
           < date_trunc('month', now() at time zone s.timezone) then true
      else exists (
        select 1 from schedule_publications sp
         where sp.studio_id = p_studio_id
           and sp.month = date_trunc('month', p_at at time zone s.timezone)::date)
    end
    from studios s where s.id = p_studio_id), false)
$$;

-- The same question by occurrence id, for the SECURITY DEFINER readers that
-- already hold one. Closed to client roles below: an id-keyed boolean tells a
-- stranger whether an id exists, which is the leak migration 086 closed on
-- occurrence_is_adjacent().
create function occurrence_published(p_occurrence_id uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select month_published(o.studio_id, o.starts_at)
                     from class_occurrences o where o.id = p_occurrence_id), false)
$$;

-- -----------------------------------------------------------------------------
-- 3. Who may read a class — the two policies
-- -----------------------------------------------------------------------------
-- MEMBERS: an unpublished month is not on the timetable. This is the boundary,
-- not the screen: the member app selects class_occurrences directly, and a
-- rule that lived in its query would be missing from the next query.
-- occ_member_own_read (025) is untouched — a member the desk has pencilled into
-- a draft with an override still sees the class they are booked on.
drop policy occ_member_read on class_occurrences;
create policy occ_member_read on class_occurrences for select
  using (studio_id in (select auth_member_studios())
         and status = 'scheduled'
         and month_published(studio_id, starts_at));

-- STAFF: desk and up read everything, because they are the ones building the
-- draft. An INSTRUCTOR reads only published months — a roster they can see
-- before the studio has approved it is a promise the studio has not made. The
-- instructor portal reads through SECURITY DEFINER functions, each of which
-- carries the same clause below (056's rule: the grant is not a guard), and
-- the open-shifts board reads this table directly, which is where this policy
-- is the one doing the work.
drop policy occ_staff_read on class_occurrences;
create policy occ_staff_read on class_occurrences for select
  using (studio_id in (select auth_staff_studios())
         and (is_desk_up(studio_id) or month_published(studio_id, starts_at)));

-- -----------------------------------------------------------------------------
-- 4. What a month looks like before it is published — the facts, once
-- -----------------------------------------------------------------------------
-- Used by the preview and by publish_month() itself, so the numbers a manager
-- read before pressing the button are the numbers recorded when they did.
-- Internal: the two public callers guard.
create function month_publication_facts(p_studio_id uuid, p_month date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tz text; v_month date; v_from timestamptz; v_to timestamptz;
  v_pub schedule_publications%rowtype;
  v_classes int; v_open int; v_booked int; v_instructors jsonb;
begin
  select timezone into v_tz from studios where id = p_studio_id;
  if v_tz is null then raise exception 'no such studio' using errcode = 'PT404'; end if;

  v_month := date_trunc('month', p_month)::date;
  -- The month's two ends as instants: studio-local midnight on the first, and
  -- on the first of the next month. Converted once here rather than comparing
  -- each row's local date, so the range can use the index on starts_at.
  v_from := (v_month::timestamp) at time zone v_tz;
  v_to   := ((v_month + interval '1 month')::timestamp) at time zone v_tz;

  select * into v_pub from schedule_publications
   where studio_id = p_studio_id and month = v_month;

  select count(*)::int,
         count(*) filter (where staffing = 'open')::int
    into v_classes, v_open
    from class_occurrences o
   where o.studio_id = p_studio_id and o.status = 'scheduled'
     and o.starts_at >= v_from and o.starts_at < v_to;

  select count(*)::int into v_booked
    from bookings b join class_occurrences o on o.id = b.occurrence_id
   where o.studio_id = p_studio_id and o.status = 'scheduled'
     and o.starts_at >= v_from and o.starts_at < v_to
     and b.status in ('booked','waitlisted','pending_payment');

  -- Who is affected and how many classes each — the thing a studio should see
  -- before publishing, beside the holes. `reachable` because an instructor
  -- with no login (the ordinary case — instructors.staff_id is null for most)
  -- cannot be sent anything, and "published" must not read as "told".
  select coalesce(jsonb_agg(x order by x ->> 'name'), '[]'::jsonb) into v_instructors
    from (
      select jsonb_build_object(
               'instructor_id', i.id,
               'name', i.display_name,
               'classes', count(*),
               'reachable', instructor_user_id(i.id) is not null,
               'notified_at', rc.notified_at,
               'confirmed_at', rc.confirmed_at,
               -- Classes they have flagged rather than confirmed — a pending
               -- cover request is the flag, so the publish screen can say
               -- "confirmed, 2 flagged" instead of only "confirmed".
               'cover_pending', count(*) filter (where exists (
                   select 1 from cover_requests c
                    where c.occurrence_id = o.id and c.status = 'pending'))) as x
        from class_occurrences o
        join instructors i on i.id = o.instructor_id
        left join roster_confirmations rc
          on rc.studio_id = p_studio_id and rc.instructor_id = i.id and rc.month = v_month
       where o.studio_id = p_studio_id and o.status = 'scheduled'
         and o.starts_at >= v_from and o.starts_at < v_to
       group by i.id, i.display_name, rc.notified_at, rc.confirmed_at) z;

  return jsonb_build_object(
    'month', v_month,
    'label', to_char(v_month, 'FMMonth YYYY'),
    'enabled', publication_enabled(p_studio_id),
    'is_current', v_month = date_trunc('month', now() at time zone v_tz)::date,
    'is_past',    v_month < date_trunc('month', now() at time zone v_tz)::date,
    'published',  v_pub.id is not null,
    'published_at', v_pub.published_at,
    'published_by', v_pub.published_by,
    'auto', coalesce(v_pub.auto, false),
    'classes', v_classes,
    'open_shifts', v_open,
    'bookings', v_booked,
    'instructors', v_instructors);
end $$;

-- The preview a manager reads before deciding. Read-only.
create function publish_month_preview(p_studio_id uuid, p_month date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers publish the timetable' using errcode = 'PT403';
  end if;
  return month_publication_facts(p_studio_id, p_month);
end $$;

-- -----------------------------------------------------------------------------
-- 5. The roster email
-- -----------------------------------------------------------------------------
-- Their own classes for the month, dates and times, IN the email — not a link
-- to a calendar. An instructor reads this on a phone between two classes and
-- decides whether to say yes; sending them somewhere to look it up is sending
-- them nothing. The link is where they say yes.
insert into notification_templates (key, subject, text_body, html_body, note) values
('month_roster',
 'Your {month} classes at {studio_name} — please confirm',
 E'Hi {instructor_name},\n\n{studio_name} has published {month}. You are down for {count} class{plural}:\n\n{roster}\n\nConfirm the month in one go, or flag any you cannot do and the studio will arrange cover: {href}\n\nThank you,\n{studio_name}',
 '<p>Hi {instructor_name},</p><p>{studio_name} has published <strong>{month}</strong>. You are down for <strong>{count}</strong> class{plural}:</p><ul>{roster_html}</ul><p><a href="{href}">Confirm the month</a> in one go, or flag any you cannot do and the studio will arrange cover.</p><p>Thank you,<br>{studio_name}</p>',
 'Migration 112, Decision 25. Sent once per instructor per published month, '
 'from publish_month(). The classes are listed in the body on purpose.')
on conflict (key) do nothing;

-- -----------------------------------------------------------------------------
-- 6. Publishing
-- -----------------------------------------------------------------------------
-- Manager-up and deliberate. Allowed with holes — an open shift is a real
-- state and Decision 17 handles it — but the caller has seen them, because
-- the preview and this function read the same facts.
--
-- IDEMPOTENT ON THE ROW. A second call for a published month returns what is
-- already true and sends nothing; the dedupe key on each roster notice is the
-- belt to that brace.
create function publish_month(p_studio_id uuid, p_month date)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_facts jsonb; v_month date; v_tz text; v_name text; v_slug text;
  v_from timestamptz; v_to timestamptz;
  r record; v_lines text; v_lines_html text; v_user uuid;
  n_notified int := 0; v_unreachable jsonb := '[]'::jsonb;
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers publish the timetable' using errcode = 'PT403';
  end if;
  if not publication_enabled(p_studio_id) then
    raise exception 'publication is not turned on for this studio'
      using errcode = 'PT409',
            hint = 'Turn it on under Settings first. Until then every month is already live.';
  end if;

  v_facts := month_publication_facts(p_studio_id, p_month);
  v_month := (v_facts ->> 'month')::date;

  if (v_facts ->> 'is_past')::boolean then
    raise exception '% has already ended and is on the record whatever anybody presses',
      v_facts ->> 'label' using errcode = 'PT409';
  end if;

  if (v_facts ->> 'published')::boolean then
    return v_facts || jsonb_build_object('ok', true, 'already_published', true,
                                         'notified', 0, 'unreachable', '[]'::jsonb);
  end if;

  select s.timezone, s.name, s.slug into v_tz, v_name, v_slug from studios s where s.id = p_studio_id;
  v_from := (v_month::timestamp) at time zone v_tz;
  v_to   := ((v_month + interval '1 month')::timestamp) at time zone v_tz;

  insert into schedule_publications (studio_id, month, published_by, classes, open_shifts)
  values (p_studio_id, v_month, auth.uid(),
          (v_facts ->> 'classes')::int, (v_facts ->> 'open_shifts')::int);

  -- One roster per instructor with at least one class, their own classes only.
  for r in
    select i.id, i.display_name, count(*)::int as n,
           string_agg(format('%s — %s%s',
                             to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMon, HH24:MI'),
                             o.name,
                             case when rm.name is null then '' else ' (' || rm.name || ')' end),
                      E'\n' order by o.starts_at) as lines,
           string_agg(format('<li>%s — %s%s</li>',
                             to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMon, HH24:MI'),
                             -- Studio-typed names go into an HTML body, so the
                             -- three characters that matter are escaped.
                             replace(replace(replace(o.name, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'),
                             case when rm.name is null then '' else ' (' ||
                               replace(replace(replace(rm.name, '&', '&amp;'), '<', '&lt;'), '>', '&gt;') || ')' end),
                      '' order by o.starts_at) as lines_html
      from class_occurrences o
      join instructors i on i.id = o.instructor_id
      left join rooms rm on rm.id = o.room_id
     where o.studio_id = p_studio_id and o.status = 'scheduled'
       and o.starts_at >= v_from and o.starts_at < v_to
     group by i.id, i.display_name
     order by i.display_name
  loop
    v_user := instructor_user_id(r.id);

    insert into roster_confirmations (studio_id, instructor_id, month, classes_at_notify, notified_at)
    values (p_studio_id, r.id, v_month, r.n, case when v_user is null then null else now() end)
    on conflict (studio_id, instructor_id, month) do update
       set classes_at_notify = excluded.classes_at_notify,
           notified_at = coalesce(roster_confirmations.notified_at, excluded.notified_at);

    if v_user is null then
      v_unreachable := v_unreachable || jsonb_build_object('instructor_id', r.id, 'name', r.display_name, 'classes', r.n);
      continue;
    end if;

    if queue_shift_notice(p_studio_id, v_user, 'month_roster',
         jsonb_build_object(
           'instructor_name', r.display_name,
           'studio_name', v_name,
           'month', v_facts ->> 'label',
           'count', r.n,
           'plural', case when r.n = 1 then '' else 'es' end,
           'roster', r.lines,
           'roster_html', r.lines_html,
           -- A full URL, the shape 073's invite uses: this lands in an email,
           -- where a path is a broken link.
           'href', 'https://' || v_slug || '.'
                   || coalesce(notification_setting('member_app_domain'), 'studiior.app')
                   || '/instructor/month?m=' || to_char(v_month, 'YYYY-MM')),
         -- Keyed on the instructor and the MONTH: one roster per month, ever.
         -- A class added later is told about on its own (create_occurrence,
         -- move_occurrence), not by re-sending the month.
         'month_roster:' || r.id || ':' || v_month) is not null
    then
      n_notified := n_notified + 1;
    end if;
  end loop;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (p_studio_id, auth.uid(), 'month.published', 'studios', p_studio_id,
          jsonb_build_object('month', v_month,
                             'classes', (v_facts ->> 'classes')::int,
                             'open_shifts', (v_facts ->> 'open_shifts')::int,
                             'notified', n_notified,
                             'unreachable', v_unreachable));

  return month_publication_facts(p_studio_id, v_month)
         || jsonb_build_object('ok', true, 'already_published', false,
                               'notified', n_notified, 'unreachable', v_unreachable);
end $$;

-- -----------------------------------------------------------------------------
-- 7. Turning it on, and what that has to publish at once
-- -----------------------------------------------------------------------------
-- The switch is a settings column and could be a plain UPDATE, except that
-- flipping it hides every unpublished month from members THE SAME INSTANT — and
-- two kinds of month must not be hidden by that:
--
--   - the CURRENT month, which has already started. Hiding this month's classes
--     from every member because the studio turned on a feature is an outage.
--   - any future month members have already booked into. "A month members have
--     booked into cannot be withdrawn" is an edge in Decision 25, and a switch
--     that withdrew three of them on its way on would break it by the back door.
--
-- Both are published automatically, marked `auto`, with no roster email — the
-- instructors have had these months on their schedule all along — and the
-- result names them so the screen can say what happened rather than leave it
-- to be discovered.
create function set_publication_enabled(p_studio_id uuid, p_enabled boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_was boolean; v_tz text; v_cur date; v_auto jsonb := '[]'::jsonb; r record;
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers change this' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  if v_tz is null then raise exception 'no such studio' using errcode = 'PT404'; end if;

  select publication_enabled into v_was from studio_settings where studio_id = p_studio_id;
  update studio_settings set publication_enabled = p_enabled, updated_at = now()
   where studio_id = p_studio_id;

  if p_enabled and not coalesce(v_was, false) then
    v_cur := date_trunc('month', now() at time zone v_tz)::date;
    for r in
      select m.month
        from (
          select v_cur as month
          union
          select date_trunc('month', o.starts_at at time zone v_tz)::date
            from class_occurrences o
            join bookings b on b.occurrence_id = o.id
           where o.studio_id = p_studio_id and o.status = 'scheduled'
             and o.starts_at >= now()
             and b.status in ('booked','waitlisted','pending_payment')
        ) m
       where not exists (select 1 from schedule_publications sp
                          where sp.studio_id = p_studio_id and sp.month = m.month)
       order by m.month
    loop
      insert into schedule_publications (studio_id, month, published_by, auto, classes, open_shifts)
      select p_studio_id, r.month, auth.uid(), true,
             count(*)::int, count(*) filter (where o.staffing = 'open')::int
        from class_occurrences o
       where o.studio_id = p_studio_id and o.status = 'scheduled'
         and o.starts_at >= (r.month::timestamp) at time zone v_tz
         and o.starts_at <  ((r.month + interval '1 month')::timestamp) at time zone v_tz;
      v_auto := v_auto || jsonb_build_object('month', r.month, 'label', to_char(r.month, 'FMMonth YYYY'),
                                             'why', case when r.month = v_cur
                                                         then 'it has already started'
                                                         else 'members have already booked into it' end);
    end loop;

    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (p_studio_id, auth.uid(), 'publication.enabled', 'studios', p_studio_id,
            jsonb_build_object('auto_published', v_auto));
  elsif not p_enabled and coalesce(v_was, false) then
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (p_studio_id, auth.uid(), 'publication.disabled', 'studios', p_studio_id, '{}'::jsonb);
  end if;

  return jsonb_build_object('ok', true, 'enabled', p_enabled, 'auto_published', v_auto);
end $$;

-- -----------------------------------------------------------------------------
-- 8. What the member app says about how far the timetable goes
-- -----------------------------------------------------------------------------
-- "Members can only book as far as the published month" has to be ON THE
-- SCREEN, or an empty November reads as a studio with nothing on. One call in
-- the book page's existing parallel batch — never a second hop.
--
-- `published_through` is the last day of the latest month in the CONTIGUOUS
-- run of published months starting at the current one, because that is the
-- sentence a member can use; `months` is the raw list for a day-by-day check.
-- Null everything when the switch is off, so the screen draws nothing.
create function timetable_horizon(p_studio_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_tz text; v_cur date; v_through date; v_months jsonb; m date;
begin
  if not (p_studio_id in (select auth_member_studios())
          or p_studio_id in (select auth_staff_studios())) then
    raise exception 'not your studio' using errcode = 'PT403';
  end if;
  if not publication_enabled(p_studio_id) then
    return jsonb_build_object('enabled', false);
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  v_cur := date_trunc('month', now() at time zone v_tz)::date;

  select coalesce(jsonb_agg(sp.month order by sp.month), '[]'::jsonb) into v_months
    from schedule_publications sp
   where sp.studio_id = p_studio_id and sp.month >= v_cur;

  m := v_cur;
  while exists (select 1 from schedule_publications sp
                 where sp.studio_id = p_studio_id and sp.month = m) loop
    v_through := (m + interval '1 month' - interval '1 day')::date;
    m := (m + interval '1 month')::date;
  end loop;

  return jsonb_build_object(
    'enabled', true,
    'current_month', v_cur,
    'published_through', v_through,          -- null: not even this month
    'next_unpublished', m,                    -- the first draft month from now
    'months', v_months);
end $$;

-- -----------------------------------------------------------------------------
-- 9. Everything that has to ask the predicate, re-issued from its newest FILE
-- -----------------------------------------------------------------------------
-- Each of these is the text of the migration that last defined it, with the
-- one clause this migration adds — and, in move_occurrence(), one check moved
-- ahead of the write it was supposed to prevent. Rebuilt from the files, never
-- from the live database (CLAUDE.md's rule, and the Stripe handler in 102 is
-- what ignoring it looks like).

-- 9a. book_class() — rule 2.1.1b. From 20260831130000.
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

  -- 2.1.4 Waiver. Not overridable.
  if v_set.require_waiver and v_member.waiver_signed_at is null then
    return (null, null, null, null, 'waiver_not_signed')::book_class_result;
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

  v_full := v_occ.booked_count >= v_occ.capacity;

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
    -- §2.3 / §5: a staff override for a walk-in books over capacity. This is
    -- displayed as over-capacity, not corrected.
    v_bypassed := v_bypassed || 'capacity'::text;
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

-- 9b. queue_instructor_assigned() — the seam every caller goes through. From 20260830640000.
create or replace function queue_instructor_assigned(p_occurrence_id uuid)
returns uuid
language plpgsql security definer set search_path = public as $$
declare o class_occurrences%rowtype; s studios%rowtype; v_user uuid; v_room text;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found or o.instructor_id is null then return null; end if;
  -- Decision 25: a roster an instructor sees before the studio has published
  -- the month is a promise the studio has not made. Every caller — the engine,
  -- cover approval, a hand-made class — goes through here, so the gate lives
  -- here rather than in each of them. True for every studio with the switch
  -- off, so nothing changes for them.
  if not occurrence_published(o.id) then return null; end if;
  select * into s from studios where id = o.studio_id;
  v_user := instructor_user_id(o.instructor_id);
  if v_user is null then return null; end if;
  select name into v_room from rooms where id = o.room_id;

  return queue_shift_notice(
    o.studio_id, v_user, 'instructor_assigned',
    jsonb_build_object(
      'class_name', o.name,
      'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth, HH24:MI'),
      'where_line', case when v_room is null then '' else ' in ' || v_room end,
      'booked_line', case when o.booked_count > 0
        then format('%s member%s booked in so far.', o.booked_count,
                    case when o.booked_count = 1 then ' is' else 's are' end)
        else 'Nobody has booked yet.' end),
    -- Keyed on the instructor AND the time, so being reassigned after a move is
    -- a second notice rather than a silent no-op on the dedupe index.
    'instructor_assigned:' || o.id || ':' || o.instructor_id || ':' || extract(epoch from o.starts_at)::bigint);
end $$;

-- 9c. create_occurrence() — a class added to a published month tells its instructor. From 20260830990000.
create or replace function create_occurrence(
  p_studio_id     uuid,
  p_class_type_id uuid,
  p_starts_at     timestamptz,
  p_ends_at       timestamptz,
  p_instructor_id uuid default null,
  p_room_id       uuid default null,
  p_capacity      int  default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  ct        class_types%rowtype;
  v_loc     uuid;
  v_room    uuid;
  v_tz      text;
  v_cap     int;
  v_id      uuid;
  v_rooms   int;
  v_clash   class_occurrences%rowtype;
  v_conflict text;
  v_warnings text[] := '{}';
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers change the timetable' using errcode = 'PT403';
  end if;
  if studio_is_locked(p_studio_id) then
    raise exception 'this studio''s Studiior subscription is not active'
      using errcode = 'PT402',
            hint = 'Reactivate it from Billing. Nothing has been deleted.';
  end if;

  select timezone into v_tz from studios where id = p_studio_id;
  select * into ct from class_types
   where id = p_class_type_id and studio_id = p_studio_id and status = 'active';
  if ct.id is null then
    raise exception 'pick a class type that belongs to this studio and is not archived'
      using errcode = 'PT422';
  end if;

  if p_ends_at <= p_starts_at then
    raise exception 'a class cannot end before it starts' using errcode = 'PT400';
  end if;

  select id into v_loc from locations
   where studio_id = p_studio_id and is_primary order by created_at limit 1;
  if v_loc is null then
    raise exception 'this studio has no location to put a class in' using errcode = 'PT422';
  end if;

  -- A CLASS WITH NO ROOM SKIPS THE EXCLUSION CONSTRAINT, which is partial on a
  -- non-null room_id — so "no room" is not a neutral default, it is opting out
  -- of the only thing that stops two classes in one space. One room: use it,
  -- because asking a studio with one room which room is a question with one
  -- answer. Several: refuse until told.
  select count(*) into v_rooms from rooms
   where studio_id = p_studio_id and status = 'active';
  v_room := p_room_id;
  if v_room is null then
    if v_rooms = 1 then
      select id into v_room from rooms where studio_id = p_studio_id and status = 'active';
    elsif v_rooms > 1 then
      return jsonb_build_object('ok', false, 'reason', 'room_required',
        'rooms', (select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'capacity', capacity)
                                   order by name)
                    from rooms where studio_id = p_studio_id and status = 'active'));
    end if;
  end if;
  if v_room is not null
     and not exists (select 1 from rooms
                      where id = v_room and studio_id = p_studio_id and status = 'active') then
    raise exception 'that room does not belong to this studio' using errcode = 'PT422';
  end if;

  if p_instructor_id is not null
     and not exists (select 1 from instructors
                      where id = p_instructor_id and studio_id = p_studio_id and status = 'active') then
    raise exception 'that instructor does not belong to this studio' using errcode = 'PT422';
  end if;

  -- THE VALIDITY WINDOW IS A HARD REFUSAL. Decision 18: an instructor whose
  -- pattern runs only through November has not agreed to be anywhere in
  -- December, and creating a class for them there produces one nobody turns up
  -- to teach. Same gate, same reason string, as move_occurrence().
  if p_instructor_id is not null
     and not instructor_valid_on(p_instructor_id, (p_starts_at at time zone v_tz)::date) then
    return jsonb_build_object(
      'ok', false, 'reason', 'outside_availability_dates',
      'blocked_by', jsonb_build_object(
        'who', (select display_name from instructors where id = p_instructor_id),
        'on', to_char(p_starts_at at time zone v_tz, 'FMDay FMDD FMMonth YYYY')));
  end if;

  -- The day and time INSIDE that window is a WARNING, per Decision 9: a human
  -- assigning outside stated hours knows what they are doing.
  if p_instructor_id is not null
     and not instructor_available_at(p_instructor_id, p_starts_at, p_ends_at) then
    -- array_append, NOT `|| 'literal'`. An untyped literal on the right makes
    -- Postgres resolve `anyarray || anyarray` and try to parse the string as an
    -- array: `22P02 malformed array literal: "outside_availability"`. The same
    -- line in move_occurrence() has been raising since it was written; 090.
    v_warnings := array_append(v_warnings, 'outside_availability');
  end if;

  v_cap := coalesce(p_capacity, ct.default_capacity,
                    (select capacity from rooms where id = v_room), 10);
  if v_cap < 1 then
    raise exception 'a class needs room for at least one person' using errcode = 'PT422';
  end if;

  begin
    insert into class_occurrences (
      studio_id, location_id, class_type_id, name, instructor_id, room_id,
      capacity, starts_at, ends_at)
    values (p_studio_id, v_loc, ct.id, ct.name, p_instructor_id, v_room,
            v_cap, p_starts_at, p_ends_at)
    returning id into v_id;
  exception when exclusion_violation then
    get stacked diagnostics v_conflict = constraint_name;
    -- Named, with the class actually in the way. "Conflict detected" tells
    -- somebody holding a mouse nothing they can act on.
    select * into v_clash from class_occurrences o
     where o.status <> 'cancelled'
       and tstzrange(o.starts_at, o.ends_at) && tstzrange(p_starts_at, p_ends_at)
       and ((v_conflict = 'occ_room_no_overlap'       and o.room_id = v_room)
         or (v_conflict = 'occ_instructor_no_overlap' and o.instructor_id = p_instructor_id))
     limit 1;
    return jsonb_build_object(
      'ok', false,
      'reason', case when v_conflict = 'occ_room_no_overlap'
                     then 'room_busy' else 'instructor_busy' end,
      'blocked_by', case when v_clash.id is null then null else jsonb_build_object(
        'occurrence_id', v_clash.id,
        'name', v_clash.name,
        'at', to_char(v_clash.starts_at at time zone v_tz, 'HH24:MI'),
        'who', (select i.display_name from instructors i where i.id = v_clash.instructor_id),
        'room', (select rm.name from rooms rm where rm.id = v_clash.room_id)) end);
  end;

  -- Decision 25: a class added to an already-published month is bookable at
  -- once (month_published() says so) and its instructor is told, because the
  -- roster they were sent no longer lists everything. Gated on the studio's
  -- switch and not only on the month, so a studio that never publishes keeps
  -- working exactly as today — this path has never told anybody. Inside the
  -- call, queue_instructor_assigned() refuses a draft month and an instructor
  -- with no login.
  if p_instructor_id is not null and publication_enabled(p_studio_id) then
    perform queue_instructor_assigned(v_id);
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (p_studio_id, auth.uid(), 'occurrence.created', 'class_occurrences', v_id,
          jsonb_build_object('starts_at', p_starts_at, 'ends_at', p_ends_at,
                             'instructor_id', p_instructor_id, 'room_id', v_room,
                             'class_type_id', ct.id, 'capacity', v_cap,
                             'warnings', to_jsonb(v_warnings)));

  return jsonb_build_object(
    'ok', true, 'occurrence_id', v_id,
    -- tg_derive_staffing() decides this from instructor_id; read back rather
    -- than assumed, so "open shift" on the screen is what the row actually says.
    'staffing', (select staffing from class_occurrences where id = v_id),
    'capacity', v_cap, 'room_id', v_room,
    'local_when', to_char(p_starts_at at time zone v_tz, 'FMDay FMDD FMMon, HH24:MI'),
    'warnings', to_jsonb(v_warnings));
end $$;

-- 9d. move_occurrence() — the validity refusal moved BEFORE the update, and a changed roster tells its instructor. From 20260831000000.
create or replace function move_occurrence(p_occurrence_id uuid, p_starts_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_ends_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_instructor_id uuid DEFAULT NULL::uuid, p_room_id uuid DEFAULT NULL::uuid, p_confirm boolean DEFAULT false, p_clear_instructor boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  occ        class_occurrences%rowtype;
  v_starts   timestamptz;
  v_ends     timestamptz;
  v_instr    uuid;
  v_room     uuid;
  v_staffing staffing_state;
  v_warnings text[] := '{}';
  v_set      studio_settings%rowtype;
  v_tz       text;
  v_clash    class_occurrences%rowtype;
  v_significant boolean := false;
  v_undo     boolean := false;
  v_conflict text;
  v_moved    boolean;
begin
  select * into occ from class_occurrences where id = p_occurrence_id for update;
  if not found then
    raise exception 'no such class' using errcode = 'PT404';
  end if;
  if not is_manager_up(occ.studio_id) then
    raise exception 'only owners and managers change the timetable'
      using errcode = 'PT403';
  end if;
  if studio_is_locked(occ.studio_id) then
    raise exception 'this studio''s Studiior subscription is not active'
      using errcode = 'PT402',
            hint = 'Reactivate it from Billing. Nothing has been deleted.';
  end if;
  if occ.status <> 'scheduled' then
    raise exception 'a % class cannot be moved', occ.status using errcode = 'PT409';
  end if;

  -- ONCE, HERE, BEFORE ANYTHING USES IT. It used to be resolved only inside the
  -- "members are booked" branch and inside the clash handler, so on the ordinary
  -- path — assigning somebody to a class nobody has booked — it was still null
  -- when the validity window was checked below. See migration 090's header.
  select s.timezone into v_tz from studios s where s.id = occ.studio_id;

  v_starts := coalesce(p_starts_at, occ.starts_at);
  v_ends   := coalesce(p_ends_at,   occ.ends_at);
  v_room   := coalesce(p_room_id,   occ.room_id);
  -- p_clear_instructor because a null p_instructor_id has to be able to mean
  -- "leave it alone" as well as "make this an open shift", and one nullable
  -- parameter cannot say both.
  v_instr  := case when p_clear_instructor then null
                   else coalesce(p_instructor_id, occ.instructor_id) end;

  if v_ends <= v_starts then
    raise exception 'a class cannot end before it starts' using errcode = 'PT400';
  end if;

  v_staffing := case when v_instr is null then
                       (case when occ.staffing = 'pending_approval'
                             then 'pending_approval' else 'open' end)
                     else 'assigned' end::staffing_state;

  -- TWO LEVELS, and only one of them is a warning.
  --
  -- THIS CHECK USED TO SIT AFTER THE UPDATE. It returned ok:false with the row
  -- already reassigned, so a refusal for outside_availability_dates was a
  -- refusal in words only: proved on the seed before migration 112 moved it —
  -- instructor 41's window ended yesterday, move_occurrence() answered
  -- {"ok": false, "reason": "outside_availability_dates"}, and the class was
  -- 41's afterwards. A refusal has to come before anything is written.
  --
  -- The VALIDITY WINDOW is a hard refusal: an instructor whose stated pattern
  -- runs only through November has not agreed to be anywhere in December, and
  -- assigning them produces a class nobody turns up to teach. Decision 9's
  -- "warns, never blocks" is about a human overriding somebody's stated HOURS,
  -- which they can do knowing why — it was never about putting a person outside
  -- the dates they agreed to at all.
  if v_instr is not null
     and not instructor_valid_on(v_instr, (v_starts at time zone v_tz)::date) then
    return jsonb_build_object(
      'ok', false, 'requires_confirmation', false,
      'reason', 'outside_availability_dates',
      'blocked_by', jsonb_build_object(
        'who', (select display_name from instructors where id = v_instr),
        'on', to_char(v_starts at time zone v_tz, 'FMDay FMDD FMMonth YYYY')));
  end if;

  -- Members are the reason to stop and ask.
  if occ.booked_count > 0 and not p_confirm
     and (v_starts <> occ.starts_at or v_ends <> occ.ends_at
          or v_instr is distinct from occ.instructor_id) then
    return jsonb_build_object(
      'ok', false,
      'requires_confirmation', true,
      'booked_count', occ.booked_count,
      'reason', 'members_booked');
  end if;

  begin
    update class_occurrences
       set starts_at = v_starts, ends_at = v_ends,
           instructor_id = v_instr, room_id = v_room,
           staffing = v_staffing, updated_at = now()
     where id = p_occurrence_id;
  exception when exclusion_violation then
    -- Which of the two, in words a person can act on.
    get stacked diagnostics v_conflict = constraint_name;

    -- "Conflict detected" tells somebody holding a mouse nothing. Find the
    -- class that is actually in the way so the screen can name it and offer to
    -- open it.
    select * into v_clash from class_occurrences o
     where o.id <> p_occurrence_id
       and o.status <> 'cancelled'
       and tstzrange(o.starts_at, o.ends_at) && tstzrange(v_starts, v_ends)
       and ((v_conflict = 'occ_room_no_overlap'       and o.room_id = v_room)
         or (v_conflict = 'occ_instructor_no_overlap' and o.instructor_id = v_instr))
     limit 1;

    select s.timezone into v_tz from studios s where s.id = occ.studio_id;

    return jsonb_build_object(
      'ok', false,
      'requires_confirmation', false,
      'reason', case when v_conflict = 'occ_room_no_overlap'
                     then 'room_busy' else 'instructor_busy' end,
      'conflict', v_conflict,
      'blocked_by', case when v_clash.id is null then null else jsonb_build_object(
        'occurrence_id', v_clash.id,
        'name', v_clash.name,
        'starts_at', v_clash.starts_at,
        'at', to_char(v_clash.starts_at at time zone v_tz, 'HH24:MI'),
        'who', (select i.display_name from instructors i where i.id = v_clash.instructor_id),
        'room', (select rm.name from rooms rm where rm.id = v_clash.room_id)) end);
  end;

  v_moved := v_starts <> occ.starts_at or v_ends <> occ.ends_at;

  -- Everybody who is booked in, told. This is the reason the confirmation step
  -- exists: by the time we are here the caller has said yes to sending it.
  if v_moved and occ.booked_count > 0 then
    select * into v_set from studio_settings where studio_id = occ.studio_id;
    select s.timezone into v_tz from studios s where s.id = occ.studio_id;

    -- Significant: further than the studio's threshold, or landing on a
    -- different day in their own timezone. A class pushed fifteen minutes is a
    -- delay; a class pushed to the evening is a different arrangement.
    v_significant :=
      abs(extract(epoch from v_starts - occ.starts_at)) >
        coalesce(v_set.significant_move_hours, 2) * 3600
      or (v_starts at time zone v_tz)::date <> (occ.starts_at at time zone v_tz)::date;

    -- The undo window. A class that has just been moved and is now going back
    -- where it came from is somebody correcting a mis-drag, and the members
    -- should not hear about either leg of it. The first email has not gone out
    -- yet — the worker runs every minute — so it is withdrawn rather than
    -- apologised for.
    v_undo := exists (
      select 1 from audit_logs al
       where al.entity_id = occ.id
         and al.action = 'occurrence.moved'
         and al.created_at > now() - interval '60 seconds'
         and (al.before ->> 'starts_at')::timestamptz = v_starts);

    -- Any unsent notice about this class is now stale whatever happens next:
    -- it describes a move that has been superseded.
    delete from notifications
     where template_key = 'class_moved'
       and status = 'scheduled'
       and dedupe_key like 'class_moved:' || occ.id || ':%';

    if not v_undo then
      perform queue_class_moved(occ.id, occ.starts_at);

      if v_significant then
        -- Decision 2's reasoning, applied to a move: they agreed to a time and
        -- the time changed. They may cancel without it counting against them,
        -- right up to the class.
        update bookings
           set free_cancel_until = v_ends
         where occurrence_id = occ.id and status = 'booked';
      end if;
    end if;
  end if;

  -- The day and time INSIDE that window stays a warning, per Decision 9.
  if v_instr is not null and not instructor_available_at(v_instr, v_starts, v_ends) then
    v_warnings := array_append(v_warnings, 'outside_availability');
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (occ.studio_id, auth.uid(), 'occurrence.moved', 'class_occurrences', occ.id,
          jsonb_build_object('starts_at', occ.starts_at, 'ends_at', occ.ends_at,
                             'instructor_id', occ.instructor_id, 'room_id', occ.room_id),
          jsonb_build_object('starts_at', v_starts, 'ends_at', v_ends,
                             'instructor_id', v_instr, 'room_id', v_room));

  -- Decision 25: a class in a PUBLISHED month whose instructor or time has
  -- changed is a roster that no longer matches what its instructor was sent, so
  -- they are told. Gated on the studio's switch so a studio that never publishes
  -- keeps working exactly as today — a drag-assign has never emailed anybody.
  -- queue_instructor_assigned() reads the row as it now is, refuses a draft
  -- month, and keys on instructor AND start time, so the same person moved to a
  -- new time hears about the new time and nobody hears twice about one change.
  if v_instr is not null
     and (v_moved or v_instr is distinct from occ.instructor_id)
     and publication_enabled(occ.studio_id) then
    perform queue_instructor_assigned(occ.id);
  end if;

  return jsonb_build_object(
    'ok', true,
    'moved', v_moved,
    'staffing', v_staffing,
    'significant', v_significant,
    'undo', v_undo,
    'booked_count', occ.booked_count,
    'warnings', to_jsonb(v_warnings));
end $function$;

-- 9e. commitment_pending() — a draft month is not decided. From 20260830910000.
create or replace function commitment_pending(p_studio_id uuid)
returns table (occ_id uuid, occ_name text, starts_at timestamptz, local_when text,
               tier guarantee_tier, booked int, minimum int, short_by int,
               due_at timestamptz, cutoff_shape text, past_due boolean,
               instructor_id uuid, is_adjacent boolean)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_tz text; s studio_settings%rowtype;
begin
  if not coalesce(is_manager_up(p_studio_id), false) and not is_service_context() then
    raise exception 'only owners and managers see this' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  if v_tz is null then raise exception 'no such studio' using errcode = 'PT404'; end if;
  select * into s from studio_settings where studio_id = p_studio_id;
  -- Either switch puts classes in scope; occurrence_guarantee() decides which
  -- tiers those are. Neither means nothing is ever pending, which is what
  -- "sees no change" means.
  if not coalesce(s.guarantees_enabled, false)
     and not coalesce(s.flex_enabled, false) then
    return;
  end if;

  return query
  select o.id, o.name, o.starts_at,
         to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMon, HH24:MI'),
         g.tier, b.n, g.minimum, greatest(0, g.minimum - b.n),
         g.cutoff_at, g.cutoff_shape, now() >= g.cutoff_at,
         o.instructor_id, occurrence_is_adjacent(o.id)
    from class_occurrences o
    cross join lateral occurrence_guarantee(o.id) g
    cross join lateral (
      select count(*)::int as n from bookings bk
       where bk.occurrence_id = o.id
         and bk.status in ('booked','attended','no_show','pending_payment')
    ) b
   where o.studio_id = p_studio_id
     and o.status = 'scheduled'
     and o.committed_at is null
     and o.starts_at > now()
     -- 'always' is included: it commits at its start time. Only a class with no
     -- cutoff at all — a studio with both switches off — is out of scope.
     and g.cutoff_at is not null
     -- Decision 25: a draft month is not decided. Nobody can book a class in
     -- it, so a flex class evaluated there would be cancelled for want of the
     -- bookings it was never allowed to take.
     and occurrence_published(o.id)
   order by o.starts_at;
end $$;

-- 9f. instructor_week(uuid, date), confirm_week(), unconfirmed_summary(), sweep_week_confirmations() — from 20260830770000.
create or replace function instructor_week(
  p_instructor_id uuid, p_week_start date default null
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_tz text; v_week date;
begin
  select i.studio_id, s.timezone into v_studio, v_tz
    from instructors i join studios s on s.id = i.studio_id where i.id = p_instructor_id;
  if v_studio is null then
    raise exception 'no such instructor' using errcode = 'PT404';
  end if;
  if not coalesce(is_manager_up(v_studio), false)
     and p_instructor_id is distinct from auth_instructor_id(v_studio)
     and not is_service_context() then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;

  v_week := coalesce(p_week_start,
                     studio_week_start(v_studio, (now() at time zone v_tz)::date));

  return jsonb_build_object(
    'instructor_id', p_instructor_id,
    'week_start', v_week,
    'week_end', v_week + 6,
    'classes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'occurrence_id', o.id,
               'name', o.name,
               'starts_at', o.starts_at,
               'local', to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMon, HH24:MI'),
               'booked', o.booked_count,
               'confirmed', o.instructor_confirmed_at is not null,
               'cover_status', cr.status)
             order by o.starts_at)
        from class_occurrences o
        left join lateral (
          select status from cover_requests c
           where c.occurrence_id = o.id and c.status in ('pending','approved')
           order by c.requested_at desc limit 1) cr on true
       where o.instructor_id = p_instructor_id
         and o.status = 'scheduled'
         and (o.starts_at at time zone v_tz)::date between v_week and v_week + 6
         and month_published(v_studio, o.starts_at)
    ), '[]'::jsonb),
    'unanswered', (
      select count(*) from class_occurrences o
       where o.instructor_id = p_instructor_id
         and o.status = 'scheduled'
         and o.instructor_confirmed_at is null
         and (o.starts_at at time zone v_tz)::date between v_week and v_week + 6
         and month_published(v_studio, o.starts_at)
         and not exists (select 1 from cover_requests c
                          where c.occurrence_id = o.id and c.status in ('pending','approved'))));
end $$;

-- -----------------------------------------------------------------------------
-- Confirming
-- -----------------------------------------------------------------------------

create or replace function confirm_week(
  p_instructor_id uuid, p_week_start date default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_studio uuid; v_tz text; v_week date; n int; v_cover int;
begin
  select i.studio_id, s.timezone into v_studio, v_tz
    from instructors i join studios s on s.id = i.studio_id where i.id = p_instructor_id;
  if v_studio is null then
    raise exception 'no such instructor' using errcode = 'PT404';
  end if;
  -- The instructor, or the studio on their behalf: somebody who says yes at the
  -- desk should not have to open the app for a manager to record it.
  if not coalesce(is_manager_up(v_studio), false)
     and p_instructor_id is distinct from auth_instructor_id(v_studio) then
    raise exception 'only the studio or the instructor confirms their week'
      using errcode = 'PT403';
  end if;

  v_week := coalesce(p_week_start,
                     studio_week_start(v_studio, (now() at time zone v_tz)::date));

  -- Everything in the week at once, which is the whole point: eleven presses is
  -- how a studio ends up with nine confirmations and two people it has to chase
  -- about a button rather than about a class.
  with done as (
    update class_occurrences o
       set instructor_confirmed_at = now(), updated_at = now()
     where o.instructor_id = p_instructor_id
       and o.status = 'scheduled'
       and o.instructor_confirmed_at is null
       -- Decision 25: nothing in a draft month is theirs to confirm yet.
       and month_published(v_studio, o.starts_at)
       and (o.starts_at at time zone v_tz)::date between v_week and v_week + 6
       -- A class they have asked for cover on is not theirs to confirm.
       and not exists (select 1 from cover_requests c
                        where c.occurrence_id = o.id and c.status in ('pending','approved'))
    returning 1)
  select count(*) into n from done;

  select count(*) into v_cover from class_occurrences o
   where o.instructor_id = p_instructor_id and o.status = 'scheduled'
     and month_published(v_studio, o.starts_at)
     and (o.starts_at at time zone v_tz)::date between v_week and v_week + 6
     and exists (select 1 from cover_requests c
                  where c.occurrence_id = o.id and c.status in ('pending','approved'));

  return jsonb_build_object(
    'ok', true, 'week_start', v_week, 'confirmed', n, 'cover_requested', v_cover);
end $$;


create or replace function unconfirmed_summary(
  p_studio_id uuid, p_week_start date default null, p_within_days int default null
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_tz text; v_week date; v_today date; v_cut date;
begin
  if not coalesce(is_manager_up(p_studio_id), false) and not is_service_context() then
    raise exception 'only owners and managers see who has not confirmed'
      using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  if v_tz is null then
    raise exception 'no such studio' using errcode = 'PT404';
  end if;

  v_today := (now() at time zone v_tz)::date;
  v_week  := coalesce(p_week_start, studio_week_start(p_studio_id, v_today));
  -- The window closes on the earlier of the week's end and the cut-off, and it
  -- never opens behind today: a class that has already run is not something
  -- anybody can confirm now.
  v_cut := case when p_within_days is null then v_week + 6
                else least(v_week + 6, v_today + p_within_days) end;

  return (
    with bad as (
      select o.id, o.name, o.starts_at, o.booked_count, o.instructor_id,
             i.display_name
        from class_occurrences o
        join instructors i on i.id = o.instructor_id
       where o.studio_id = p_studio_id
         and o.status = 'scheduled'
         and o.instructor_confirmed_at is null
         and (o.starts_at at time zone v_tz)::date
             between greatest(v_week, v_today) and v_cut
         -- Decision 25: a class in a draft month has not been asked about.
         and month_published(p_studio_id, o.starts_at)
         and not exists (select 1 from cover_requests c
                          where c.occurrence_id = o.id and c.status in ('pending','approved'))
    )
    select jsonb_build_object(
      'week_start', v_week,
      'through', v_cut,
      'instructors', (select count(distinct instructor_id) from bad),
      'classes', (select count(*) from bad),
      -- One line, composed here rather than in a screen, so the brief, the
      -- email and the page cannot each say it slightly differently.
      'line', case when (select count(*) from bad) = 0 then null else
        format('%s instructor%s %s not confirmed %s class%s this week',
               (select count(distinct instructor_id) from bad),
               case when (select count(distinct instructor_id) from bad) = 1 then '' else 's' end,
               case when (select count(distinct instructor_id) from bad) = 1 then 'has' else 'have' end,
               (select count(*) from bad),
               case when (select count(*) from bad) = 1 then '' else 'es' end) end,
      'detail', coalesce((
        select jsonb_agg(x order by x ->> 'name')
          from (
            select jsonb_build_object(
                     'instructor_id', b.instructor_id,
                     'name', b.display_name,
                     'classes', count(*),
                     'booked', sum(b.booked_count),
                     'next', min(b.starts_at),
                     'list', jsonb_agg(jsonb_build_object(
                               'occurrence_id', b.id, 'name', b.name,
                               'local', to_char(b.starts_at at time zone v_tz,
                                                'FMDay FMDD FMMon, HH24:MI'))
                             order by b.starts_at)) as x
              from bad b group by b.instructor_id, b.display_name) z
      ), '[]'::jsonb)));
end $$;

-- -----------------------------------------------------------------------------
-- Ask, remind, escalate
-- -----------------------------------------------------------------------------
insert into notification_templates (key, subject, text_body, html_body, note) values
('week_confirm_ask',
 'Confirm your classes for {week}',
 E'Hi {instructor_name},\n\nYou have {count} classes at {studio_name} in the week of {week}.\n\nConfirm them all in one go, or ask for cover on any you cannot make: {href}\n\nThank you,\n{studio_name}',
 '<p>Hi {instructor_name},</p><p>You have <strong>{count}</strong> classes at {studio_name} in the week of {week}.</p><p><a href="{href}">Confirm them all</a>, or ask for cover on any you cannot make.</p><p>Thank you,<br>{studio_name}</p>',
 'Migration 067. Sent on the studio''s week_confirm_ask_dow for the week ahead.'),
('week_confirm_reminder',
 'Still to confirm: {count} classes next week',
 E'Hi {instructor_name},\n\n{count} of your classes in the week of {week} are still unconfirmed.\n\nConfirm them, or ask for cover: {href}\n\nThank you,\n{studio_name}',
 '<p>Hi {instructor_name},</p><p><strong>{count}</strong> of your classes in the week of {week} are still unconfirmed.</p><p><a href="{href}">Confirm them</a>, or ask for cover.</p><p>Thank you,<br>{studio_name}</p>',
 'Migration 067. ONE reminder, on week_confirm_remind_dow, only if something is '
 'still unanswered. Confirming after it arrives clears everything silently.'),
('week_unconfirmed',
 'Classes not yet confirmed in the next {days} days',
 E'{line}.\n\n{detail}\n\nOpen the staff app to see who and which classes.',
 '<p>{line}.</p><p>{detail}</p><p>Open the staff app to see who and which classes.</p>',
 'Migration 067. ONE email to the studio on week_confirm_escalate_dow, covering '
 'only classes inside week_confirm_escalate_days. Never one per class.')
on conflict (key) do nothing;


create or replace function sweep_week_confirmations()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  s record; r record;
  v_tz text; v_today date; v_dow int; v_week date; v_n int;
  n_ask int := 0; n_remind int := 0; n_escalate int := 0; v_studios int := 0;
  v_sum jsonb;
begin
  if not is_service_context() then
    raise exception 'the confirmation sweep is a background job' using errcode = 'PT403';
  end if;

  for s in
    select st.id, st.name, st.timezone,
           coalesce(cfg.week_confirm_enabled, true)        as enabled,
           coalesce(cfg.week_confirm_ask_dow, 4)           as ask_dow,
           coalesce(cfg.week_confirm_remind_dow, 6)        as remind_dow,
           coalesce(cfg.week_confirm_escalate_dow, 0)      as esc_dow,
           coalesce(cfg.week_confirm_escalate_days, 3)     as esc_days
      from studios st
      left join studio_settings cfg on cfg.studio_id = st.id
     where st.status = 'active'
     order by st.id
  loop
    v_studios := v_studios + 1;
    if not s.enabled then continue; end if;

    v_tz    := s.timezone;
    v_today := (now() at time zone v_tz)::date;
    v_dow   := extract(dow from v_today)::int;

    -- ---- ask, for the week AHEAD ------------------------------------------
    if v_dow = s.ask_dow then
      v_week := studio_week_start(s.id, v_today) + 7;
      for r in
        -- instructors.staff_id is a studio_staff id, not an auth user id.
        select i.id, i.display_name, instructor_user_id(i.id) as user_id, count(*)::int as n
          from instructors i
          join class_occurrences o on o.instructor_id = i.id and o.status = 'scheduled'
         where i.studio_id = s.id and i.status = 'active'
           and instructor_user_id(i.id) is not null
           and (o.starts_at at time zone v_tz)::date between v_week and v_week + 6
           -- Decision 25: do not ask anybody to confirm a week the studio has
           -- not published yet.
           and month_published(s.id, o.starts_at)
         group by i.id, i.display_name
      loop
        if queue_shift_notice(s.id, r.user_id, 'week_confirm_ask',
             jsonb_build_object('instructor_name', r.display_name, 'studio_name', s.name,
                                'count', r.n, 'week', to_char(v_week, 'FMDD FMMonth'),
                                -- A full URL. 067 wrote a path here, which in an email is
                                -- a link to nowhere; fixed while this is re-issued.
                                'href', coalesce(nullif(notification_setting('staff_app_origin'), ''),
                                                 'https://app.studiior.com') || '/my/week?w=' || v_week),
             'week_ask:' || r.id || ':' || v_week) is not null
        then n_ask := n_ask + 1; end if;
      end loop;
    end if;

    -- ---- remind, once, and only if something is unanswered -----------------
    if v_dow = s.remind_dow then
      v_week := studio_week_start(s.id, v_today) + 7;
      for r in
        select i.id, i.display_name, instructor_user_id(i.id) as user_id,
               (instructor_week(i.id, v_week) ->> 'unanswered')::int as n
          from instructors i
         where i.studio_id = s.id and i.status = 'active'
           and instructor_user_id(i.id) is not null
      loop
        if r.n > 0 and queue_shift_notice(s.id, r.user_id, 'week_confirm_reminder',
             jsonb_build_object('instructor_name', r.display_name, 'studio_name', s.name,
                                'count', r.n, 'week', to_char(v_week, 'FMDD FMMonth'),
                                -- A full URL. 067 wrote a path here, which in an email is
                                -- a link to nowhere; fixed while this is re-issued.
                                'href', coalesce(nullif(notification_setting('staff_app_origin'), ''),
                                                 'https://app.studiior.com') || '/my/week?w=' || v_week),
             -- One reminder for that week, ever. A second is nagging, and the
             -- escalation is the next step rather than a louder repeat.
             'week_remind:' || r.id || ':' || v_week) is not null
        then n_remind := n_remind + 1; end if;
      end loop;
    end if;

    -- ---- escalate, to the studio, about the next few days only -------------
    if v_dow = s.esc_dow then
      v_sum := unconfirmed_summary(s.id, studio_week_start(s.id, v_today) + 7, s.esc_days);
      -- The window straddles the week boundary on a Sunday, so ask about the
      -- week that is starting as well as the one just ending.
      if coalesce((v_sum ->> 'classes')::int, 0) = 0 then
        v_sum := unconfirmed_summary(s.id, studio_week_start(s.id, v_today), s.esc_days);
      end if;
      if coalesce((v_sum ->> 'classes')::int, 0) > 0 then
        v_n := queue_shift_notice_to_staff(s.id, 'week_unconfirmed',
          jsonb_build_object(
            'line', v_sum ->> 'line',
            'days', s.esc_days,
            'detail', coalesce((
              select string_agg(format('%s — %s class(es), next %s',
                                       d ->> 'name', d ->> 'classes',
                                       to_char((d ->> 'next')::timestamptz at time zone v_tz,
                                               'FMDay HH24:MI')), E'\n')
                from jsonb_array_elements(v_sum -> 'detail') d), '')),
          -- Per studio per day, so the same Sunday cannot send twice.
          'week_unconfirmed:' || s.id || ':' || v_today);
        n_escalate := n_escalate + coalesce(v_n, 0);
      end if;
    end if;
  end loop;

  return jsonb_build_object('studios', v_studios, 'asked', n_ask,
                            'reminded', n_remind, 'escalated', n_escalate);
end $$;

-- 9g. instructor_roster(), instructor_week(uuid, date, date) — from 20260831070000.
create or replace function instructor_roster(p_occurrence_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare occ class_occurrences%rowtype; v_tz text; v_rows jsonb;
begin
  select * into occ from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  -- Their own class, or staff who may see any. An instructor asking about
  -- somebody else's roster is asking about members they are not teaching.
  if not (is_desk_up(occ.studio_id)
          or (occ.instructor_id is not null and is_this_instructor(occ.instructor_id)
              -- Decision 25: an instructor reads nothing in a draft month, by
              -- id or otherwise. Desk and up, above, still can.
              and occurrence_published(occ.id))) then
    raise exception 'that is not your class' using errcode = 'PT403';
  end if;
  select s.timezone into v_tz from studios s where s.id = occ.studio_id;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.first_timer desc, x.name), '[]'::jsonb)
    into v_rows from (
    select b.id as booking_id, m.id as member_id,
           coalesce(nullif(m.preferred_name, ''), m.first_name) || ' ' || m.last_name as name,
           m.avatar_url, b.status::text as booking_status,
           ci.id is not null as checked_in,
           -- A MEMBER'S FIRST EVER CLASS is the one an instructor most needs to
           -- know about, and it is the fact that decides how the next hour
           -- goes. Counted from check-ins BEFORE this class, so somebody on
           -- their fourth booking who has never turned up still reads as new.
           not exists (select 1 from check_ins c2
                        where c2.member_id = m.id and c2.studio_id = occ.studio_id
                          and c2.checked_in_at < occ.starts_at) as first_timer,
           -- §5 note 5 gives an instructor the birthday flag, and nothing else
           -- from the date: the day and month, never the year or the age.
           (m.date_of_birth is not null
            and to_char(m.date_of_birth, 'MM-DD')
                = to_char((occ.starts_at at time zone v_tz)::date, 'MM-DD')) as birthday,
           (select coalesce(jsonb_agg(jsonb_build_object(
                     'category', n.category, 'body', n.body) order by
                     case n.category when 'injury' then 0 when 'medical' then 1 else 2 end),
                   '[]'::jsonb)
              from member_notes n
             where n.member_id = m.id and n.pinned and n.active
               -- NOT is_manager_up(): this function is SECURITY DEFINER and
               -- would otherwise hand an instructor every managers-only note
               -- in the studio.
               and not n.managers_only) as pinned_notes
      from bookings b
      join members m on m.id = b.member_id
      left join check_ins ci on ci.booking_id = b.id
     where b.occurrence_id = p_occurrence_id
       and b.status in ('booked', 'attended', 'no_show')) x;

  return jsonb_build_object(
    'occurrence_id', occ.id, 'name', occ.name,
    'starts_at', occ.starts_at, 'capacity', occ.capacity,
    'booked', occ.booked_count, 'status', occ.status,
    'local_time', to_char(occ.starts_at at time zone v_tz, 'HH24:MI'),
    'local_date', (occ.starts_at at time zone v_tz)::date,
    'members', v_rows,
    -- §8: an instructor may check somebody in. They may NOT correct a no-show
    -- or create a walk-in booking, so those are absent rather than refused.
    'can_check_in', true,
    'withheld', 'Contact details and any documents on file are not shown here — '
                || '§14 keeps those with the office.');
end $$;

-- -----------------------------------------------------------------------------
-- THEIR WEEK — the thing they open
--
-- schedule_range() is manager-up (the timetable is the studio's to see), so
-- this is the instructor's own slice, in the studio's clock, with the two
-- states that decide whether they are working: a flex class still waiting on
-- its deadline, and one that will not run, with the reason.
-- -----------------------------------------------------------------------------

create or replace function instructor_week(
  p_instructor_id uuid, p_from date, p_to date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_tz text; v_rows jsonb;
begin
  select i.studio_id into v_studio from instructors i where i.id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  if not (is_this_instructor(p_instructor_id) or is_manager_up(v_studio)) then
    raise exception 'that is somebody else''s week' using errcode = 'PT403';
  end if;
  select s.timezone into v_tz from studios s where s.id = v_studio;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.starts_at), '[]'::jsonb)
    into v_rows from (
    select o.id as occurrence_id, o.name, o.starts_at, o.ends_at,
           (o.starts_at at time zone v_tz)::date as local_date,
           to_char(o.starts_at at time zone v_tz, 'HH24:MI') as local_start,
           to_char(o.ends_at   at time zone v_tz, 'HH24:MI') as local_end,
           r.name as room_name, o.capacity, o.booked_count, o.waitlist_count,
           o.status::text as status, o.cancellation_reason,
           o.cancellation_cause::text as cancellation_cause,
           o.flex, o.minimum_bookings, o.committed_at is not null as committed,
           -- occurrence_guarantee() RETURNS TABLE, not jsonb. It is readable
           -- by any staff of the studio, an instructor included, so this is a
           -- call-shape fix and not a permission one.
           (select g.tier::text from occurrence_guarantee(o.id) g) as tier,
           -- Confirmed for the week (migration 067) is a fact about the class,
           -- not about the instructor, so it travels with the row.
           o.instructor_confirmed_at is not null as confirmed,
           exists (select 1 from cover_requests c
                    where c.occurrence_id = o.id and c.status = 'pending') as cover_requested
      from class_occurrences o
      left join rooms r on r.id = o.room_id
     where o.studio_id = v_studio and o.instructor_id = p_instructor_id
       and (o.starts_at at time zone v_tz)::date between p_from and p_to
       -- Decision 25: a draft month is not on their schedule.
       and month_published(v_studio, o.starts_at)) x;

  return jsonb_build_object(
    'from', p_from, 'to', p_to, 'timezone', v_tz, 'classes', v_rows,
    'state', case when jsonb_array_length(v_rows) = 0 then 'empty' else 'ok' end,
    'empty_hint', 'Nothing on this week. Classes you are down to teach appear here as soon as the studio schedules them, and open shifts you can apply for are under Shifts.');
end $$;

-- -----------------------------------------------------------------------------
-- 9h. staff_bootstrap() carries the switch — from 20260831040000
-- -----------------------------------------------------------------------------
-- A RETURNS TABLE cannot gain a column through create or replace, so this drops
-- first and re-asserts its ACL, exactly as 094 did.
drop function if exists staff_bootstrap();

create function staff_bootstrap()
returns table (
  staff_id             uuid,
  user_id              uuid,
  email                text,
  role                 staff_role,
  studio_id            uuid,
  studio_name          text,
  studio_timezone      text,
  studio_currency      char(3),
  studio_status        text,
  location_name        text,
  onboarding_complete  boolean,
  is_platform_admin    boolean,
  billing_status       platform_status,
  billing_locked       boolean,
  billing_days_left    int,
  -- 0 = Sunday .. 6 = Saturday, matching JavaScript's getDay() and date-fns'
  -- weekStartsOn, so it travels to the browser without a translation step.
  studio_week_starts_on int,
  -- Decision 25 (migration 112). The rail offers "Publish" only when this is
  -- on: a link to a screen that does nothing for a studio that never publishes
  -- is the decorative control this build refuses to draw. On the bootstrap
  -- rather than read per render for the same reason week_starts_on is.
  publication_enabled   boolean
)
language sql stable security definer set search_path = public as $$
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
    -- Default 1 rather than 0: a studio with no settings row at all is a
    -- Monday studio, which is what the column's own default has always said.
    coalesce(st.week_starts_on, 1),
    coalesce(st.publication_enabled, false)
  from studio_staff ss
  join studios s on s.id = ss.studio_id
  left join studio_settings st on st.studio_id = ss.studio_id
  left join platform_subscriptions ps on ps.studio_id = ss.studio_id
  -- auth.uid(), never a parameter.
  where ss.user_id = auth.uid()
    and ss.status = 'active'
  order by ss.created_at
  limit 1
$$;

revoke execute on function staff_bootstrap() from public, anon;
grant execute on function staff_bootstrap() to authenticated;

comment on function staff_bootstrap() is
  'The staff context in one request: who is asking, their studio, its primary '
  'location, onboarding state, the platform-admin flag, billing, and which day '
  'its week starts on. Migration 094 added the last of those so the calendar '
  'and the query behind it cannot disagree about which seven days a week is. '
  'Migration 112 added publication_enabled, which decides whether the rail '
  'offers Publish at all.';

-- The drop reopened the default grant (094's assertion, re-run here); prove the revoke closed it again rather
-- than trusting that it did. Local and hosted have different default ACLs, so
-- this assertion is the only thing that holds on both.
do $$
begin
  if has_function_privilege('anon', 'staff_bootstrap()', 'execute') then
    raise exception 'staff_bootstrap() is anon-callable after being recreated';
  end if;
  if not has_function_privilege('authenticated', 'staff_bootstrap()', 'execute') then
    raise exception 'staff_bootstrap() is not reachable by a signed-in user';
  end if;
end $$;


-- -----------------------------------------------------------------------------
-- 10. Grants, and the assertion that they held
-- -----------------------------------------------------------------------------
-- Internals: closed to every client role. month_published() is the exception,
-- because the two RLS policies above call it as the querying role — and what
-- it answers ("is this studio's month out yet") is what the studio's own
-- public timetable already shows.
revoke execute on function publication_enabled(uuid)              from public, anon, authenticated;
revoke execute on function month_published(uuid, timestamptz)     from public, anon;
revoke execute on function occurrence_published(uuid)             from public, anon, authenticated;
revoke execute on function month_publication_facts(uuid, date)    from public, anon, authenticated;
revoke execute on function publish_month_preview(uuid, date)      from public, anon;
revoke execute on function publish_month(uuid, date)              from public, anon;
revoke execute on function set_publication_enabled(uuid, boolean) from public, anon;
revoke execute on function timetable_horizon(uuid)                from public, anon;

grant execute on function publication_enabled(uuid)               to service_role;
grant execute on function month_published(uuid, timestamptz)      to authenticated, service_role;
grant execute on function occurrence_published(uuid)              to service_role;
grant execute on function month_publication_facts(uuid, date)     to service_role;
grant execute on function publish_month_preview(uuid, date)       to authenticated, service_role;
grant execute on function publish_month(uuid, date)               to authenticated, service_role;
grant execute on function set_publication_enabled(uuid, boolean)  to authenticated, service_role;
grant execute on function timetable_horizon(uuid)                 to authenticated, service_role;

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure::text as sig,
           has_function_privilege('anon', p.oid, 'execute') as anon,
           has_function_privilege('authenticated', p.oid, 'execute') as authed
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('publication_enabled', 'month_published', 'occurrence_published',
                         'month_publication_facts', 'publish_month_preview', 'publish_month',
                         'set_publication_enabled', 'timetable_horizon',
                         -- the re-issued ones: create or replace keeps an ACL,
                         -- and this is the check that it did
                         'book_class', 'queue_instructor_assigned', 'create_occurrence',
                         'move_occurrence', 'commitment_pending', 'instructor_week',
                         'confirm_week', 'unconfirmed_summary', 'sweep_week_confirmations',
                         'instructor_roster')
  loop
    if r.anon then raise exception 'migration 112: % is reachable by anon', r.sig; end if;
    if r.authed and r.sig ~ '^(publication_enabled|occurrence_published|month_publication_facts|queue_instructor_assigned|sweep_week_confirmations)\(' then
      raise exception 'migration 112: % is reachable by authenticated', r.sig;
    end if;
    if not r.authed and r.sig ~ '^(month_published|publish_month|publish_month_preview|set_publication_enabled|timetable_horizon|book_class|create_occurrence|move_occurrence|commitment_pending|instructor_week|confirm_week|unconfirmed_summary|instructor_roster)\(' then
      raise exception 'migration 112: % lost the grant it needs', r.sig;
    end if;
  end loop;

  -- Nothing about publications is writable through the table by any client.
  if has_table_privilege('authenticated', 'schedule_publications', 'insert')
     or has_table_privilege('authenticated', 'schedule_publications', 'update')
     or has_table_privilege('authenticated', 'schedule_publications', 'delete')
     or has_table_privilege('authenticated', 'roster_confirmations', 'insert')
     or has_table_privilege('authenticated', 'roster_confirmations', 'update')
     or has_table_privilege('authenticated', 'roster_confirmations', 'delete') then
    raise exception 'migration 112: a client role can write publication state directly';
  end if;
end $$;
