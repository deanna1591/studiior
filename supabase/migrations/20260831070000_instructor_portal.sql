-- =============================================================================
-- Migration 097 — instructors can sign in, and there is something for them to
-- open when they do
--
-- ALL SIX OF REFORM COLLECTIVE'S INSTRUCTORS HAVE staff_id NULL. No studio_staff
-- row, no auth user, no email. So every instructor notification built so far —
-- assignment, cover request, weekly confirmation, availability reminder, flex
-- cancellation — has been queued for people with no address;
-- queue_instructor_assigned() returns null for every one of them and
-- approve_cover_request() has been honestly reporting them as unreachable.
--
-- (There is no `can_sign_in` column and never has been. The fact is real; the
-- mechanism is a null staff_id.)
--
-- THREE THINGS, AND GETTING THEM CONFUSED HAS ALREADY COST ONE BUG:
--
--   auth.users      the login
--   studio_staff    (studio_id, user_id, email, role) — belonging to a studio
--   instructors     the teaching record; staff_id -> studio_staff(id)
--
-- `instructors.staff_id` IS A studio_staff ID, NOT A USER ID. Migration 054
-- passed it straight to queue_shift_notice() three times, which takes the
-- latter, and a foreign key in a test fixture caught it rather than a reader.
--
-- No third invite table. studio_staff.user_id is already nullable with
-- `invited_at` and `status`, because the table was built for an
-- invited-but-not-joined row; studio_invites already carries the hashed,
-- single-use, expiring token. Both gain a role instead.
-- =============================================================================

alter table studio_invites
  add column if not exists role staff_role not null default 'owner',
  add column if not exists instructor_id uuid references instructors on delete cascade;

comment on column studio_invites.role is
  'Which seat this invite is for. ''owner'' is migration 012''s provisioning '
  'path, which also flips the studio out of ''provisioning''; every other role '
  'joins a studio that already exists.';

create index if not exists studio_invites_instructor
  on studio_invites (instructor_id) where instructor_id is not null;
-- One live invite per instructor, the same rule member_invites already has.
-- A resend supersedes rather than accumulating, so "who has an open invite" is
-- a question with one answer.
create unique index if not exists studio_invites_one_live_per_instructor
  on studio_invites (instructor_id) where instructor_id is not null and accepted_at is null;

insert into notification_templates (key, subject, text_body, html_body, note) values
('instructor_invite', 'Your {studio_name} instructor account',
 E'Hi {first_name},\n\n{studio_name} has set up your instructor account.\n\nOpen this link to choose a password:\n{claim_url}\n\nOnce you are in you can see your week, confirm the classes you are teaching, ask for cover, put your availability in and check what you are owed.\n\nIt is a web page, not an app to download — add it to your home screen and it opens like one.\n\nThe link works once and expires in {days} days.\n\n{studio_name}',
 E'<p>Hi {first_name},</p><p><strong>{studio_name}</strong> has set up your instructor account.</p><p><a href="{claim_url}">Choose a password</a></p><p>Once you are in you can see your week, confirm the classes you are teaching, ask for cover, put your availability in and check what you are owed.</p><p>It is a web page, not an app to download — add it to your home screen and it opens like one.</p><p>The link works once and expires in {days} days.</p>',
 'Migration 097. Sent by invite_instructor(). Like member_invite it gets no '
 'email-settings link: the reader has no account yet, and the preferences '
 'screen it would point at is a member surface.')
on conflict (key) do nothing;

-- -----------------------------------------------------------------------------
-- Invite an instructor
--
-- Creates the studio_staff row NOW, with user_id null and status 'invited', so
-- instructors.staff_id points at something the moment somebody is asked. That
-- is what makes instructor_user_id() start returning an address — and it is
-- why every notification queued for this person before today went nowhere.
-- -----------------------------------------------------------------------------
create or replace function invite_instructor(
  p_instructor_id uuid, p_email text, p_days int default 14)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  i instructors%rowtype; s studios%rowtype;
  v_email text; v_staff uuid; v_token text; v_id uuid; v_first text;
begin
  select * into i from instructors where id = p_instructor_id;
  if not found then
    raise exception 'no such instructor' using errcode = 'PT404';
  end if;
  if not is_manager_up(i.studio_id) then
    raise exception 'only an owner or a manager can invite an instructor'
      using errcode = 'PT403';
  end if;
  if i.status <> 'active' then
    raise exception 'that instructor is %, so there is nothing to invite them to',
      i.status using errcode = 'PT409';
  end if;

  v_email := lower(nullif(btrim(p_email), ''));
  -- AN INSTRUCTOR WITH NO EMAIL CANNOT BE INVITED, and is refused BY NAME
  -- rather than queueing a notification with a null address — which is what
  -- has been happening silently to all six of them.
  if v_email is null then
    raise exception '% has no email address, so there is nowhere to send an invite',
      i.display_name
      using errcode = 'PT422',
            hint = 'Add one on their record first. `instructors` carries no email '
                   'of its own — it lives on the staff row this creates.';
  end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'that does not look like an email address' using errcode = 'PT422';
  end if;

  select * into s from studios where id = i.studio_id;

  -- Already signed in? Then there is nothing to claim.
  if i.staff_id is not null and exists (
       select 1 from studio_staff ss where ss.id = i.staff_id and ss.user_id is not null) then
    raise exception '% already has a login', i.display_name using errcode = 'PT409';
  end if;

  if i.staff_id is null then
    insert into studio_staff (studio_id, user_id, email, role, status, invited_at)
    values (i.studio_id, null, v_email, 'instructor', 'invited', now())
    returning id into v_staff;
    update instructors set staff_id = v_staff where id = p_instructor_id;
  else
    v_staff := i.staff_id;
    update studio_staff set email = v_email, invited_at = now(), status = 'invited'
     where id = v_staff;
  end if;

  -- A resend supersedes: the old link dies, which is the whole point of
  -- sending a new one. Migration 073 learned this the hard way — keying the
  -- dedupe on the person made a resend silently do nothing.
  delete from studio_invites
   where instructor_id = p_instructor_id and accepted_at is null;

  v_token := encode(gen_random_bytes(24), 'hex');
  insert into studio_invites (studio_id, email, token_hash, expires_at,
                              created_by, role, instructor_id)
  values (i.studio_id, v_email,
          encode(digest(v_token, 'sha256'), 'hex'),
          now() + make_interval(days => greatest(1, p_days)),
          auth.uid(), 'instructor', p_instructor_id)
  returning id into v_id;

  v_first := split_part(i.display_name, ' ', 1);
  perform queue_notification(
    i.studio_id, null, 'instructor_invite',
    jsonb_build_object(
      'to_email', v_email, 'first_name', v_first,
      'studio_name', s.name, 'days', greatest(1, p_days),
      -- The raw token lives in the payload until sent, exactly as
      -- member_invite does: only its hash is on the invite row, and the email
      -- needs the token itself. It is dead the moment it is used.
      'claim_url', 'https://' || s.slug || '.studiior.app/instructor/claim/' || v_token),
    'instructor_invite:' || v_token);

  return jsonb_build_object(
    'invite_id', v_id, 'staff_id', v_staff, 'email', v_email,
    'expires_at', now() + make_interval(days => greatest(1, p_days)));
end $$;

-- -----------------------------------------------------------------------------
-- Who has been asked, who has claimed, who has never been asked
--
-- The third group is the one that could not previously be known to exist —
-- the same gap migration 073 closed for members.
-- -----------------------------------------------------------------------------
create or replace function instructor_invite_status(p_studio_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_manager_up(p_studio_id) then
    raise exception 'only an owner or a manager can see this' using errcode = 'PT403';
  end if;
  return (
    select coalesce(jsonb_agg(to_jsonb(x) order by x.rank, x.display_name), '[]'::jsonb)
      from (
      select i.id, i.display_name, ss.email,
             case
               when ss.user_id is not null then 'signed_in'
               when inv.id is not null and inv.expires_at > now() then 'invited'
               when inv.id is not null then 'invite_expired'
               when coalesce(ss.email, '') = '' then 'no_email'
               else 'never_asked'
             end as state,
             case
               when ss.user_id is not null then 3
               when inv.id is not null and inv.expires_at > now() then 2
               else 1 end as rank,
             inv.expires_at, ss.invited_at
        from instructors i
        left join studio_staff ss on ss.id = i.staff_id
        left join studio_invites inv
               on inv.instructor_id = i.id and inv.accepted_at is null
       where i.studio_id = p_studio_id and i.status = 'active') x);
end $$;

-- -----------------------------------------------------------------------------
-- The claim, and TWO NEW PRE-LOGIN SURFACES
--
-- CLAUDE.md tracks the anon-executable list exactly, and it has been seven
-- since migration 014. It is NINE from here: an instructor with no account has
-- to be shown whose invite this is before signing up, and then has to be able
-- to create the account. Both are pre-login by nature, and they are the same
-- pair the member path already has (member_invite_preview,
-- claim_member_account).
--
-- The preview returns the studio and a first name and NOTHING ELSE. A token is
-- a bearer credential and whoever holds it sees only enough to know they are
-- in the right place.
-- -----------------------------------------------------------------------------
create or replace function instructor_invite_preview(p_token text)
returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare inv studio_invites%rowtype; i instructors%rowtype; s studios%rowtype;
begin
  select * into inv from studio_invites
   where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex')
     and role = 'instructor';
  if not found then return jsonb_build_object('state', 'invalid'); end if;
  if inv.accepted_at is not null then return jsonb_build_object('state', 'used'); end if;
  if inv.expires_at <= now() then return jsonb_build_object('state', 'expired'); end if;

  select * into i from instructors where id = inv.instructor_id;
  select * into s from studios where id = inv.studio_id;
  return jsonb_build_object(
    'state', 'ok',
    'first_name', split_part(i.display_name, ' ', 1),
    'studio_name', s.name, 'studio_slug', s.slug,
    'accent_color', s.accent_color, 'theme_preset', s.theme_preset,
    'logo_url', s.logo_url, 'email', inv.email);
end $$;

create or replace function claim_instructor_account(
  p_token text, p_password text, p_full_name text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  inv studio_invites%rowtype; i instructors%rowtype; s studios%rowtype;
  v_user uuid;
begin
  select * into inv from studio_invites
   where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex')
     and role = 'instructor';
  if not found then return jsonb_build_object('state', 'invalid'); end if;
  if inv.accepted_at is not null then return jsonb_build_object('state', 'used'); end if;
  if inv.expires_at <= now() then return jsonb_build_object('state', 'expired'); end if;
  if length(coalesce(p_password, '')) < 8 then
    return jsonb_build_object('state', 'password_too_short');
  end if;

  select * into i from instructors where id = inv.instructor_id;
  select * into s from studios where id = inv.studio_id;
  if i.staff_id is not null and exists (
       select 1 from studio_staff ss where ss.id = i.staff_id and ss.user_id is not null) then
    return jsonb_build_object('state', 'already_claimed');
  end if;

  -- ONE EMAIL IS ONE ACCOUNT, project-wide: auth.users carries a global unique
  -- index on it. An instructor who is also a member somewhere, or teaches at
  -- two studios on this platform, links their existing login rather than
  -- minting a second one Postgres would refuse anyway.
  select id into v_user from auth.users where lower(email) = lower(inv.email);
  if v_user is null then
    v_user := gen_random_uuid();
    insert into auth.users (
      id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
      created_at, updated_at, confirmation_token, recovery_token, email_change,
      email_change_token_new, email_change_token_current, phone_change,
      phone_change_token, reauthentication_token
    ) values (
      v_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
      inv.email, crypt(p_password, gen_salt('bf')), now(), now(), now(),
      '', '', '', '', '', '', '', '');
    insert into profiles (id, email, full_name)
    values (v_user, inv.email, coalesce(nullif(btrim(p_full_name), ''), i.display_name));
  else
    insert into profiles (id, email, full_name)
    values (v_user, inv.email, coalesce(nullif(btrim(p_full_name), ''), i.display_name))
    on conflict (id) do nothing;
  end if;

  update studio_staff
     set user_id = v_user, status = 'active', joined_at = now()
   where id = i.staff_id;
  update studio_invites
     set accepted_at = now(), accepted_by = v_user where id = inv.id;

  return jsonb_build_object(
    'state', 'ok', 'user_id', v_user, 'instructor_id', i.id,
    'studio_slug', s.slug, 'display_name', i.display_name);
end $$;

-- -----------------------------------------------------------------------------
-- The portal's bootstrap: which instructor is asking
--
-- auth.uid() -> studio_staff -> instructors, never a parameter. The one
-- request every screen in the portal starts from.
-- -----------------------------------------------------------------------------
create or replace function my_instructor()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r record;
begin
  select i.id as instructor_id, i.display_name, i.avatar_url, i.bio,
         s.id as studio_id, s.name as studio_name, s.slug, s.timezone, s.currency,
         s.accent_color, s.theme_preset, s.logo_url, ss.email, ss.role
    into r
    from studio_staff ss
    join instructors i on i.staff_id = ss.id
    join studios s on s.id = ss.studio_id
   where ss.user_id = auth.uid() and ss.status = 'active' and i.status = 'active'
   order by ss.created_at limit 1;
  if r.instructor_id is null then return null; end if;
  return to_jsonb(r);
end $$;

-- -----------------------------------------------------------------------------
-- THE ROSTER AN INSTRUCTOR MAY SEE — §14, drawn as a function so the rule is
-- in one place rather than in every screen that asks
--
-- What is here: preferred name, photo, whether they have been before, pinned
-- notes, birthday. Enough to teach the class well — to know about the shoulder
-- BEFORE rather than after.
--
-- WHAT IS DELIBERATELY NOT HERE, and cannot be added by forgetting a filter:
--   * contact details. §14 denies an instructor email and phone outright.
--   * member_documents. Manager-up since migration 059; front desk see
--     everything except the medical one and an instructor sees none at all. A
--     waiver is a filing matter and a diagnosis is nobody's business at the
--     door.
--   * managers_only notes. RLS says `is_manager_up(studio_id) or not
--     managers_only` — but this is SECURITY DEFINER and steps over RLS, so the
--     filter is written out. That is migration 056's whole lesson.
-- -----------------------------------------------------------------------------
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
          or (occ.instructor_id is not null and is_this_instructor(occ.instructor_id))) then
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
       and (o.starts_at at time zone v_tz)::date between p_from and p_to) x;

  return jsonb_build_object(
    'from', p_from, 'to', p_to, 'timezone', v_tz, 'classes', v_rows,
    'state', case when jsonb_array_length(v_rows) = 0 then 'empty' else 'ok' end,
    'empty_hint', 'Nothing on this week. Classes you are down to teach appear here as soon as the studio schedules them, and open shifts you can apply for are under Shifts.');
end $$;

-- -----------------------------------------------------------------------------
-- WHAT THEY ARE OWED — Decision 22, which built the records and no screen
--
-- Theirs to READ and never to change. Every figure comes from
-- instructor_pay_records, written once by a trigger at the terminal
-- transition; nothing here computes pay.
--
-- A NOT-RUNNING CLASS IS SHOWN AS SUCH, with what it paid. That is the whole
-- argument for guarantee tiers: a class that did not run and still paid a
-- holding rate is the number an instructor most wants to see, and the one they
-- will not believe unless it is itemised.
-- -----------------------------------------------------------------------------
create or replace function instructor_pay_summary(p_instructor_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_tz text; v_cur char(3); v_period pay_periods%rowtype; v_rows jsonb;
begin
  select i.studio_id into v_studio from instructors i where i.id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  -- An instructor reads their OWN. Migration 086 exists because eight
  -- functions in this area took an id and answered for anybody.
  if not (is_this_instructor(p_instructor_id) or is_manager_up(v_studio)) then
    raise exception 'that is somebody else''s pay' using errcode = 'PT403';
  end if;
  select s.timezone, s.currency into v_tz, v_cur from studios s where s.id = v_studio;

  select * into v_period from pay_periods
   where studio_id = v_studio and status = 'open'
   order by starts_on limit 1;

  if v_period.id is null then
    return jsonb_build_object('state', 'no_period', 'currency', v_cur,
      'empty_hint', 'Your studio has not opened a pay period yet. Once it does, every class you teach lands here with what it paid.');
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.starts_at desc), '[]'::jsonb)
    into v_rows from (
    select pr.id, pr.occurrence_id, o.name, o.starts_at,
           to_char(o.starts_at at time zone v_tz, 'DD Mon HH24:MI') as local_when,
           pr.amount_cents, pr.base_cents, pr.per_head_cents, pr.bonus_cents,
           pr.head_count, pr.kind::text as kind,
           o.status::text as occurrence_status,
           o.cancellation_cause::text as cancellation_cause,
           o.status = 'cancelled' as did_not_run
      from instructor_pay_records pr
      left join class_occurrences o on o.id = pr.occurrence_id
     where pr.instructor_id = p_instructor_id and pr.pay_period_id = v_period.id) x;

  return jsonb_build_object(
    'state', case when jsonb_array_length(v_rows) = 0 then 'empty' else 'ok' end,
    'currency', v_cur,
    'period', jsonb_build_object('id', v_period.id, 'starts_on', v_period.starts_on,
                                 'ends_on', v_period.ends_on, 'status', v_period.status),
    'total_cents', (select coalesce(sum((r ->> 'amount_cents')::bigint), 0)
                      from jsonb_array_elements(v_rows) r),
    'classes_paid', (select count(*) from jsonb_array_elements(v_rows) r
                      where (r ->> 'did_not_run')::boolean is not true),
    'not_running_paid', (select count(*) from jsonb_array_elements(v_rows) r
                          where (r ->> 'did_not_run')::boolean),
    'records', v_rows,
    'empty_hint', 'Nothing in this period yet. A class pays once it is done, so today''s classes appear tonight.',
    'read_only', 'These are the studio''s figures. If something looks wrong, tell them — nothing here can be edited from this screen.');
end $$;

-- -----------------------------------------------------------------------------
-- RECOGNITION — Decision 10, and only what Decision 10 allows
--
-- Classes taught and a streak. NOT a leaderboard and not a comparison: §12
-- note 20 is explicit that analytics for an instructor is a coaching tool, and
-- Decision 10 adds a personal count, not a ranking.
-- -----------------------------------------------------------------------------
create or replace function instructor_recognition(p_instructor_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid; v_tz text; v_total int; v_this_month int; v_weeks int; v_first date;
begin
  select i.studio_id into v_studio from instructors i where i.id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  if not (is_this_instructor(p_instructor_id) or is_manager_up(v_studio)) then
    raise exception 'that is somebody else''s record' using errcode = 'PT403';
  end if;
  select s.timezone into v_tz from studios s where s.id = v_studio;

  select count(*)::int,
         count(*) filter (where (o.starts_at at time zone v_tz)::date
                                >= date_trunc('month', studio_today(v_studio))::date)::int,
         min((o.starts_at at time zone v_tz)::date)
    into v_total, v_this_month, v_first
    from class_occurrences o
   where o.studio_id = v_studio and o.instructor_id = p_instructor_id
     and o.status <> 'cancelled' and o.starts_at <= now();

  -- Decision 5: streaks are WEEKLY, not daily. Consecutive weeks with at
  -- least one class taught, counting back from the week just gone.
  with weeks as (
    select distinct studio_week_start(v_studio, (o.starts_at at time zone v_tz)::date) as w
      from class_occurrences o
     where o.studio_id = v_studio and o.instructor_id = p_instructor_id
       and o.status <> 'cancelled' and o.starts_at <= now()),
  ranked as (select w, row_number() over (order by w desc) rn from weeks)
  select count(*)::int into v_weeks from ranked
   where w = studio_week_start(v_studio, studio_today(v_studio)) - (((rn - 1) * 7)::int);

  return jsonb_build_object(
    'classes_taught', v_total, 'this_month', v_this_month,
    'week_streak', coalesce(v_weeks, 0), 'first_class_on', v_first,
    'state', case when v_total = 0 then 'empty' else 'ok' end,
    'empty_hint', 'Once you have taught a class it is counted here.',
    'not_a_leaderboard', 'Yours only. Nothing here compares you with anybody else.');
end $$;

-- -----------------------------------------------------------------------------
-- Grants. Two of these are the eighth and ninth anon-executable functions in
-- the codebase and CLAUDE.md's list is updated in the same breath.
-- -----------------------------------------------------------------------------
revoke execute on function invite_instructor(uuid, text, int) from public, anon, authenticated;
revoke execute on function instructor_invite_status(uuid) from public, anon, authenticated;
revoke execute on function instructor_invite_preview(text) from public, anon, authenticated;
revoke execute on function claim_instructor_account(text, text, text) from public, anon, authenticated;
revoke execute on function my_instructor() from public, anon, authenticated;
revoke execute on function instructor_roster(uuid) from public, anon, authenticated;
revoke execute on function instructor_week(uuid, date, date) from public, anon, authenticated;
revoke execute on function instructor_pay_summary(uuid) from public, anon, authenticated;
revoke execute on function instructor_recognition(uuid) from public, anon, authenticated;

grant execute on function invite_instructor(uuid, text, int) to authenticated, service_role;
grant execute on function instructor_invite_status(uuid) to authenticated, service_role;
grant execute on function my_instructor() to authenticated, service_role;
grant execute on function instructor_roster(uuid) to authenticated, service_role;
grant execute on function instructor_week(uuid, date, date) to authenticated, service_role;
grant execute on function instructor_pay_summary(uuid) to authenticated, service_role;
grant execute on function instructor_recognition(uuid) to authenticated, service_role;
-- Pre-login, deliberately: somebody with an invite has no account yet.
grant execute on function instructor_invite_preview(text) to anon, authenticated, service_role;
grant execute on function claim_instructor_account(text, text, text) to anon, authenticated, service_role;
