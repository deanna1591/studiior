-- =============================================================================
-- 162  Decision 33 Part B: the subscribable calendar feed.
-- =============================================================================
-- Part A was the one-tap half (an .ics on a booking email). This is the feed:
-- a member (or an instructor) subscribes their phone's calendar to one URL, and
-- from then on the studio's changes flow in on their own — a new class, a moved
-- one, a cancelled one, a booking that changes the headcount. That is the sync
-- channel Decision 33 named: there is deliberately no email on a member's own
-- self-cancel, because the feed carries it.
--
-- THE TOKEN IS THE CREDENTIAL. calendar_feed(token) is the ELEVENTH pre-login
-- surface — anon, like the two Stripe webhooks and public_schedule, because a
-- calendar app subscribing carries no session. The token is hashed at rest
-- exactly like member_invites (only the sha256 is stored), shown once at mint,
-- and re-mintable (a new URL supersedes the old) and revocable (the feed goes
-- dark). An unknown or revoked token returns null → the route 404s.
--
-- ONE .ics BUILDER. The feed reuses ics_member_vevent / ics_instructor_vevent /
-- ics_calendar from Part A. The month-roster attachment deferred from Part A
-- lands here too, on the same instructor multi-event builder — the roster .ics
-- IS the feed content for a month, so building it twice is the thing the
-- decision forbids.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. The token: one live per person per role, hashed at rest.
-- -----------------------------------------------------------------------------
create table if not exists calendar_tokens (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid not null references studios on delete cascade,
  kind          text not null check (kind in ('member','instructor')),
  member_id     uuid references members     on delete cascade,
  instructor_id uuid references instructors on delete cascade,
  token_hash    text not null unique,
  created_at    timestamptz not null default now(),
  last_used_at  timestamptz,
  revoked_at    timestamptz,
  -- Exactly one subject, matching the kind. A member token names a member and
  -- no instructor; an instructor token the reverse.
  constraint calendar_tokens_subject check (
    (kind = 'member'     and member_id is not null and instructor_id is null) or
    (kind = 'instructor' and instructor_id is not null and member_id is null))
);
-- One LIVE token per subject: a re-mint revokes the old, so a person never has
-- two working URLs, and a leaked-then-replaced link is dead.
create unique index calendar_tokens_one_live_member
  on calendar_tokens (member_id)     where revoked_at is null and member_id is not null;
create unique index calendar_tokens_one_live_instructor
  on calendar_tokens (instructor_id) where revoked_at is null and instructor_id is not null;

alter table calendar_tokens enable row level security;
-- No policies, grants revoked: the token_hash is a credential and no client
-- reads or writes this table directly. Everything goes through the SECURITY
-- DEFINER functions below. Same shape as public_schedule_cache.
revoke all on calendar_tokens from public, anon, authenticated;
grant  all on calendar_tokens to service_role;

-- A read-through cache, keyed on the token hash, exactly like public_schedule's.
-- calendar_feed is anon-reachable, so a subscriber's app (or anyone holding the
-- token) can poll it; a hit within the TTL is one indexed read, not the joins.
create table if not exists calendar_feed_cache (
  token_hash  text primary key,
  payload     text        not null,
  computed_at timestamptz not null default now()
);
alter table calendar_feed_cache enable row level security;
revoke all on calendar_feed_cache from public, anon, authenticated;
grant  all on calendar_feed_cache to service_role;

-- -----------------------------------------------------------------------------
-- 2. The instructor month multi-event builder (shared by the button and, now,
--    the roster email attachment — the deferred half of Part A).
-- -----------------------------------------------------------------------------
-- One implementation of "an instructor's classes for a calendar month". A null
-- instructor filter means every instructor (a manager viewing for support, the
-- Part A behaviour of instructor_month_ics). Scheduled + published only
-- (Decision 25). Internal — the callers are all guarded or definer.
create or replace function instructor_month_vevents(
  p_studio_id uuid, p_instructor_id uuid, p_month date
) returns text
language plpgsql stable security definer set search_path = public as $$
declare v_tz text; v_from date; v_to date; v_events text;
begin
  select timezone into v_tz from studios where id = p_studio_id;
  v_from := date_trunc('month', p_month)::date;
  v_to   := (v_from + interval '1 month')::date;
  select string_agg(ics_instructor_vevent(o.id, false), E'\r\n' order by o.starts_at)
    into v_events
    from class_occurrences o
   where o.studio_id = p_studio_id
     and o.instructor_id = coalesce(p_instructor_id, o.instructor_id)
     and o.status = 'scheduled'
     and (o.starts_at at time zone v_tz)::date >= v_from
     and (o.starts_at at time zone v_tz)::date <  v_to
     and month_published(o.studio_id, o.starts_at);
  return coalesce(v_events, '');
end $$;
revoke execute on function instructor_month_vevents(uuid, uuid, date) from public, anon, authenticated;
grant  execute on function instructor_month_vevents(uuid, uuid, date) to service_role;

-- instructor_month_ics (the Add-to-calendar button, Part A §11) now goes through
-- the shared builder rather than inlining the string_agg. Same guard, same
-- output, one implementation.
create or replace function instructor_month_ics(p_studio_id uuid, p_month text) returns text
language plpgsql stable security definer set search_path = public as $$
declare v_instr uuid;
begin
  v_instr := auth_instructor_id(p_studio_id);
  if v_instr is null and not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'that is not your schedule' using errcode = 'PT403';
  end if;
  return ics_calendar('PUBLISH',
    instructor_month_vevents(p_studio_id, v_instr, to_date(p_month || '-01', 'YYYY-MM-DD')));
end $$;
revoke execute on function instructor_month_ics(uuid, text) from public, anon;
grant  execute on function instructor_month_ics(uuid, text) to authenticated;

-- -----------------------------------------------------------------------------
-- 3. The feed itself — the eleventh pre-login surface.
-- -----------------------------------------------------------------------------
-- Anon: a calendar app subscribing carries no session, so the token is the whole
-- of the authorisation. A member sees only their OWN future booked classes; an
-- instructor only their OWN assigned future classes. No other member's data
-- beyond the headcount an instructor event already carries. Scheduled +
-- published only (Decision 25) — a draft month is not on anybody's calendar.
-- An unknown or revoked token returns null, and writes nothing.
create or replace function calendar_feed(p_token text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare
  t calendar_tokens%rowtype; v_hash text; v_tz text; v_from timestamptz;
  v_events text; v_result text; v_cached text;
begin
  if nullif(p_token, '') is null then return null; end if;
  v_hash := encode(digest(p_token, 'sha256'), 'hex');

  select * into t from calendar_tokens where token_hash = v_hash and revoked_at is null;
  if not found then return null; end if;   -- unknown or revoked → the route 404s

  select payload into v_cached from calendar_feed_cache
   where token_hash = v_hash and computed_at > now() - interval '5 minutes';
  if v_cached is not null then return v_cached; end if;

  select timezone into v_tz from studios where id = t.studio_id;
  -- From the start of the studio's LOCAL today, forward. Wall arithmetic then
  -- converted (the project rule — never add an interval to an instant).
  v_from := date_trunc('day', now() at time zone v_tz) at time zone v_tz;

  if t.kind = 'member' then
    select string_agg(ics_member_vevent(o.id, t.member_id, false), E'\r\n' order by o.starts_at)
      into v_events
      from class_occurrences o
      join bookings b on b.occurrence_id = o.id
     where b.member_id = t.member_id and b.status = 'booked'
       and o.status = 'scheduled' and o.starts_at >= v_from
       and month_published(o.studio_id, o.starts_at);
  else
    select string_agg(ics_instructor_vevent(o.id, false), E'\r\n' order by o.starts_at)
      into v_events
      from class_occurrences o
     where o.instructor_id = t.instructor_id
       and o.status = 'scheduled' and o.starts_at >= v_from
       and month_published(o.studio_id, o.starts_at);
  end if;

  v_result := ics_calendar('PUBLISH', coalesce(v_events, ''));

  update calendar_tokens set last_used_at = now() where id = t.id;
  insert into calendar_feed_cache (token_hash, payload, computed_at)
  values (v_hash, v_result, now())
  on conflict (token_hash) do update
    set payload = excluded.payload, computed_at = excluded.computed_at;

  return v_result;
end $$;

comment on function calendar_feed(text) is
  'The eleventh pre-login surface. Anon. A subscribable text/calendar feed of a '
  'person''s own future classes, resolved from a hashed token (member = their '
  'booked classes, instructor = their assigned classes). Scheduled + published '
  'only (Decision 25). Unknown/revoked token → null. Read-through cached (5 min).';

-- Anon, deliberately — the eleventh pre-login surface. Also authenticated and
-- service_role. Never PUBLIC.
revoke all on function calendar_feed(text) from public;
grant  execute on function calendar_feed(text) to anon, authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 4. Mint / revoke / state — the settings controls (authenticated, guarded).
-- -----------------------------------------------------------------------------
-- Mint (or re-mint): returns the raw token ONCE — only its hash is stored, so a
-- leaked database hands nobody a feed. A re-mint revokes the live one first, so
-- the old URL dies. Guarded per kind: a member by their own membership, an
-- instructor by auth_instructor_id (RLS on instructors is manager-write, so they
-- cannot flip this by hand).
create or replace function mint_calendar_feed(p_studio_id uuid, p_kind text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare v_member uuid; v_instr uuid; v_token text;
begin
  if p_kind = 'member' then
    select id into v_member from members where studio_id = p_studio_id and user_id = auth.uid();
    if v_member is null then
      raise exception 'you are not a member of that studio' using errcode = 'PT403';
    end if;
  elsif p_kind = 'instructor' then
    v_instr := auth_instructor_id(p_studio_id);
    if v_instr is null then
      raise exception 'that is not your feed' using errcode = 'PT403';
    end if;
  else
    raise exception 'unknown feed kind %', p_kind using errcode = 'PT422';
  end if;

  v_token := encode(gen_random_bytes(24), 'hex');

  update calendar_tokens set revoked_at = now()
   where revoked_at is null
     and ((p_kind = 'member'     and member_id     = v_member)
       or (p_kind = 'instructor' and instructor_id = v_instr));

  insert into calendar_tokens (studio_id, kind, member_id, instructor_id, token_hash)
  values (p_studio_id, p_kind, v_member, v_instr, encode(digest(v_token, 'sha256'), 'hex'));

  return v_token;
end $$;
revoke execute on function mint_calendar_feed(uuid, text) from public, anon;
grant  execute on function mint_calendar_feed(uuid, text) to authenticated;

-- Turn the feed off. The URL goes dead; a later mint makes a fresh one.
create or replace function revoke_calendar_feed(p_studio_id uuid, p_kind text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_member uuid; v_instr uuid; v_n int;
begin
  if p_kind = 'member' then
    select id into v_member from members where studio_id = p_studio_id and user_id = auth.uid();
    if v_member is null then raise exception 'you are not a member of that studio' using errcode = 'PT403'; end if;
  elsif p_kind = 'instructor' then
    v_instr := auth_instructor_id(p_studio_id);
    if v_instr is null then raise exception 'that is not your feed' using errcode = 'PT403'; end if;
  else
    raise exception 'unknown feed kind %', p_kind using errcode = 'PT422';
  end if;

  update calendar_tokens set revoked_at = now()
   where revoked_at is null
     and ((p_kind = 'member'     and member_id     = v_member)
       or (p_kind = 'instructor' and instructor_id = v_instr));
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'active', false, 'revoked', v_n);
end $$;
revoke execute on function revoke_calendar_feed(uuid, text) from public, anon;
grant  execute on function revoke_calendar_feed(uuid, text) to authenticated;

-- Whether a live feed exists, and when it was last polled. Never returns the
-- token — that is shown once at mint and cannot be recovered, only replaced.
create or replace function calendar_feed_state(p_studio_id uuid, p_kind text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_member uuid; v_instr uuid; t calendar_tokens%rowtype;
begin
  if p_kind = 'member' then
    select id into v_member from members where studio_id = p_studio_id and user_id = auth.uid();
    if v_member is null then raise exception 'you are not a member of that studio' using errcode = 'PT403'; end if;
    select * into t from calendar_tokens
      where member_id = v_member and revoked_at is null order by created_at desc limit 1;
  elsif p_kind = 'instructor' then
    v_instr := auth_instructor_id(p_studio_id);
    if v_instr is null then raise exception 'that is not your feed' using errcode = 'PT403'; end if;
    select * into t from calendar_tokens
      where instructor_id = v_instr and revoked_at is null order by created_at desc limit 1;
  else
    raise exception 'unknown feed kind %', p_kind using errcode = 'PT422';
  end if;

  return jsonb_build_object(
    'active',       t.id is not null,
    'created_at',   t.created_at,
    'last_used_at', t.last_used_at);
end $$;
revoke execute on function calendar_feed_state(uuid, text) from public, anon;
grant  execute on function calendar_feed_state(uuid, text) to authenticated;

-- -----------------------------------------------------------------------------
-- 5. notification_ics learns the month roster, so publish_month's email carries
--    the whole month as one attachment. Re-issued from Part A (161).
-- -----------------------------------------------------------------------------
create or replace function notification_ics(p_notification_id uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare n notifications%rowtype; v_occ uuid; v_ve text; v_method text;
        v_instr uuid; v_month text; v_events text;
begin
  select * into n from notifications where id = p_notification_id;
  if not found then return null; end if;

  -- The month roster (Decision 33 Part B, deferred from Part A): the instructor's
  -- whole published month as one multi-event calendar, from the instructor id and
  -- month the payload now carries.
  if n.template_key = 'month_roster' then
    v_instr := nullif(n.payload ->> 'instructor_id', '')::uuid;
    v_month := nullif(n.payload ->> 'month_ym', '');
    if v_instr is null or v_month is null then return null; end if;
    v_events := instructor_month_vevents(n.studio_id, v_instr, to_date(v_month || '-01', 'YYYY-MM-DD'));
    if nullif(v_events, '') is null then return null; end if;
    return ics_calendar('PUBLISH', v_events);
  end if;

  v_occ := nullif(n.payload ->> 'occurrence_id', '')::uuid;
  if v_occ is null then return null; end if;

  if n.template_key in ('booking_confirmed', 'class_moved') then
    v_ve := ics_member_vevent(v_occ, n.member_id, false); v_method := 'PUBLISH';
  elsif n.template_key = 'class_cancelled' then
    v_ve := ics_member_vevent(v_occ, n.member_id, true);  v_method := 'CANCEL';
  elsif n.template_key in ('instructor_assigned', 'booking_for_instructor') then
    v_ve := ics_instructor_vevent(v_occ, false);          v_method := 'PUBLISH';
  else
    return null;
  end if;

  if v_ve is null then return null; end if;
  return ics_calendar(v_method, v_ve);
end $$;
revoke execute on function notification_ics(uuid) from public, anon, authenticated;
grant  execute on function notification_ics(uuid) to service_role;

-- -----------------------------------------------------------------------------
-- 6. publish_month: the month_roster payload gains instructor_id + month_ym, so
--    notification_ics can build the attachment. Re-issued verbatim from 112 with
--    those two keys added — nothing else changes.
-- -----------------------------------------------------------------------------
create or replace function publish_month(p_studio_id uuid, p_month date)
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
           -- Part B: the ids notification_ics needs to build the whole-month .ics
           -- attachment. The classes are still listed in the body; the .ics is on
           -- top, so the instructor can add the month to their calendar in one tap.
           'instructor_id', r.id,
           'month_ym', to_char(v_month, 'YYYY-MM'),
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
revoke execute on function publish_month(uuid, date) from public, anon;
grant  execute on function publish_month(uuid, date) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 7. Assert the anon surface is EXACTLY ELEVEN — the ten plus calendar_feed.
-- -----------------------------------------------------------------------------
do $$
declare v_n int;
begin
  select count(*) into v_n from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
   where nsp.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if v_n <> 11 then
    raise exception 'anon surface is % functions, expected exactly 11 (the ten + calendar_feed)', v_n;
  end if;
  if not has_function_privilege('anon', 'calendar_feed(text)'::regprocedure, 'execute') then
    raise exception 'calendar_feed is not anon-executable';
  end if;
end $$;
