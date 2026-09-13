-- Challenges: a cover photograph, and a progress trail worth reading.
--
-- challenges.cover_image_url has existed since migration 001; it needs a focal
-- point of its own for the same reason class types and the login photo got one
-- in 116 — object-fit: cover on a phone keeps about a sixth of a wide picture,
-- so the studio has to say what must survive the crop.
--
-- The trail (member_challenge_detail.history) becomes a record of what the
-- member did: each counted class with its instructor, AND each class in the
-- window that did NOT count with the reason — a late cancel or a no-show — so
-- the number is something they can trust rather than argue with.

alter table challenges
  add column if not exists cover_image_focus_x smallint not null default 50,
  add column if not exists cover_image_focus_y smallint not null default 50;
alter table challenges drop constraint if exists challenge_cover_focus_in_range;
alter table challenges add constraint challenge_cover_focus_in_range check (
  cover_image_focus_x between 0 and 100 and cover_image_focus_y between 0 and 100);

comment on column challenges.cover_image_focus_x is
  'Per cent across the cover photograph that must survive the crop, for the member challenge card and detail hero.';

-- -----------------------------------------------------------------------------
-- member_challenges — add the cover so the list can be photograph cards.
-- -----------------------------------------------------------------------------
create or replace function member_challenges(p_studio_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_member uuid; v_tz text; v_today date;
begin
  select id into v_member from members where studio_id = p_studio_id and user_id = auth.uid();
  if v_member is null and not is_service_context() then
    raise exception 'no membership at this studio' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  v_today := (now() at time zone v_tz)::date;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id, 'title', c.title, 'type', c.type, 'goal_value', c.goal_value,
      'status', c.status, 'starts_on', c.starts_on, 'ends_on', c.ends_on,
      'join_deadline', c.join_deadline, 'reward_description', c.reward_description,
      'cover_image_url', c.cover_image_url,
      'cover_focus_x', c.cover_image_focus_x, 'cover_focus_y', c.cover_image_focus_y,
      'joined', p.id is not null,
      'progress', coalesce(p.progress, 0),
      'completed', p.completed_at is not null,
      'can_join', p.id is null and c.status in ('scheduled','active') and v_today <= c.join_deadline)
      order by (p.id is not null) desc, c.starts_on)
      from challenges c
      left join challenge_participants p
        on p.challenge_id = c.id and p.member_id = v_member
     where c.studio_id = p_studio_id and c.audience = 'member'
       and c.status in ('scheduled','active','ended')), '[]'::jsonb);
end $$;

-- -----------------------------------------------------------------------------
-- member_challenge_detail — the cover for the hero, and a real trail.
-- -----------------------------------------------------------------------------
create or replace function member_challenge_detail(p_challenge_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c challenges%rowtype; v_member uuid; p challenge_participants%rowtype; v_today date;
begin
  select * into c from challenges where id = p_challenge_id;
  if c.id is null or c.audience <> 'member'
     or c.status not in ('scheduled','active','ended') then
    raise exception 'no such challenge' using errcode = 'PT404';
  end if;
  select id into v_member from members where studio_id = c.studio_id and user_id = auth.uid();
  if v_member is null and not is_service_context() then
    raise exception 'no membership at this studio' using errcode = 'PT403';
  end if;
  select * into p from challenge_participants
   where challenge_id = c.id and member_id = v_member;
  v_today := studio_today(c.studio_id);

  return jsonb_build_object(
    'id', c.id, 'title', c.title, 'description', c.description, 'type', c.type,
    'goal_value', c.goal_value, 'status', c.status, 'starts_on', c.starts_on,
    'ends_on', c.ends_on, 'join_deadline', c.join_deadline,
    'reward_description', c.reward_description, 'leaderboard_enabled', c.leaderboard_enabled,
    'cover_image_url', c.cover_image_url,
    'cover_focus_x', c.cover_image_focus_x, 'cover_focus_y', c.cover_image_focus_y,
    'joined', p.id is not null,
    'progress', coalesce(p.progress, 0),
    'completed_at', p.completed_at,
    'can_join', p.id is null and c.status in ('scheduled','active') and v_today <= c.join_deadline,
    -- The trail: what counted, with the instructor, and what did NOT count and
    -- why. A member who cancelled late on a challenge class will look for it
    -- here, and finding it — marked, with the reason — is the difference
    -- between trusting the number and arguing with it.
    'history', coalesce((
      select jsonb_agg(jsonb_build_object(
        'occurred_at', at, 'class_name', class_name, 'instructor', instructor,
        'counted', counted, 'reason', reason) order by at desc)
      from (
        select o.starts_at as at, o.name as class_name, i.display_name as instructor,
               true as counted, null::text as reason
          from challenge_progress_events e
          join class_occurrences o on o.id = e.occurrence_id
          left join instructors i on i.id = o.instructor_id
         where e.challenge_id = c.id and e.member_id = v_member
        union all
        select o.starts_at, o.name, i.display_name, false,
               case b.status when 'late_cancelled' then 'You cancelled late'
                             else 'You didn''t show' end
          from bookings b
          join class_occurrences o on o.id = b.occurrence_id
          left join instructors i on i.id = o.instructor_id
         where b.member_id = v_member
           and b.status in ('late_cancelled', 'no_show')
           and challenge_qualifies(c.id, o.id)
      ) trail), '[]'::jsonb),
    'leaderboard', case when c.leaderboard_enabled then coalesce((
      select jsonb_agg(jsonb_build_object(
        'name', m.first_name || ' ' || left(coalesce(m.last_name, ''), 1),
        'progress', lp.progress, 'rank', lp.rank,
        'is_me', lp.member_id = v_member)
        order by lp.rank nulls last, lp.joined_at)
        from challenge_participants lp
        join members m on m.id = lp.member_id
       where lp.challenge_id = c.id), '[]'::jsonb)
      else null end);
end $$;

-- -----------------------------------------------------------------------------
-- challenge_overview — carry the cover so the staff edit surface can show and
-- re-anchor it.
-- -----------------------------------------------------------------------------
create or replace function challenge_overview(p_challenge_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c challenges%rowtype;
begin
  select * into c from challenges where id = p_challenge_id;
  if c.id is null then raise exception 'no such challenge' using errcode = 'PT404'; end if;
  if not (coalesce(is_manager_up(c.studio_id), false) or is_service_context()) then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;
  return jsonb_build_object(
    'id', c.id, 'title', c.title, 'description', c.description, 'type', c.type,
    'goal_value', c.goal_value, 'status', c.status, 'starts_on', c.starts_on,
    'ends_on', c.ends_on, 'join_deadline', c.join_deadline,
    'leaderboard_enabled', c.leaderboard_enabled, 'reward_description', c.reward_description,
    'cover_image_url', c.cover_image_url,
    'cover_focus_x', c.cover_image_focus_x, 'cover_focus_y', c.cover_image_focus_y,
    'class_type_ids', c.class_type_ids,
    'participants', coalesce((
      select jsonb_agg(jsonb_build_object(
        'member_id', p.member_id,
        'name', m.first_name || ' ' || left(coalesce(m.last_name, ''), 1),
        'progress', p.progress, 'goal', p.goal_value,
        'completed_at', p.completed_at, 'rank', p.rank, 'joined_at', p.joined_at)
        order by p.rank nulls last, p.joined_at)
        from challenge_participants p
        join members m on m.id = p.member_id
       where p.challenge_id = c.id), '[]'::jsonb));
end $$;
