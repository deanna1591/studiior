-- Challenges, follow-up: a join deadline that has already passed produces a
-- challenge nobody can ever join, and the create form let one through (the
-- deadline need only fall within the challenge, and a challenge that already
-- started can have a deadline in the past). Reject it at the boundary. And
-- member_challenge_detail gains can_join, so the member screen shows a running,
-- closed challenge as exactly that rather than offering a Join that would 409 —
-- the deadline governs JOINING, not visibility.

create or replace function create_challenge(
  p_studio_id      uuid,
  p_title          text,
  p_type           challenge_type,
  p_goal_value     int,
  p_starts_on      date,
  p_ends_on        date,
  p_join_deadline  date,
  p_class_type_ids jsonb    default '[]',
  p_reward         text     default null,
  p_leaderboard    boolean  default false,
  p_description    text     default null,
  p_template_id    uuid     default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers create challenges' using errcode = 'PT403';
  end if;
  if coalesce(p_goal_value, 0) <= 0 then
    raise exception 'a challenge needs a goal above zero' using errcode = 'PT422';
  end if;
  if p_ends_on < p_starts_on then
    raise exception 'the challenge ends before it starts' using errcode = 'PT422';
  end if;
  if p_join_deadline < p_starts_on or p_join_deadline > p_ends_on then
    raise exception 'the join deadline must fall within the challenge' using errcode = 'PT422';
  end if;
  -- A deadline already in the past is a challenge nobody could ever join.
  if p_join_deadline < studio_today(p_studio_id) then
    raise exception 'the join deadline has already passed — members could never join'
      using errcode = 'PT422';
  end if;

  insert into challenges (studio_id, template_id, title, description, audience, type,
                          goal_value, class_type_ids, starts_on, ends_on, join_deadline,
                          reward_description, leaderboard_enabled, status, created_by)
  values (p_studio_id, p_template_id, p_title, p_description, 'member', p_type,
          p_goal_value, coalesce(p_class_type_ids, '[]'::jsonb), p_starts_on, p_ends_on,
          p_join_deadline, p_reward, coalesce(p_leaderboard, false), 'draft', auth.uid())
  returning id into v_id;
  return v_id;
end $$;

create or replace function update_challenge(
  p_challenge_id   uuid,
  p_title          text,
  p_type           challenge_type,
  p_goal_value     int,
  p_starts_on      date,
  p_ends_on        date,
  p_join_deadline  date,
  p_class_type_ids jsonb    default '[]',
  p_reward         text     default null,
  p_leaderboard    boolean  default false,
  p_description    text     default null
) returns void
language plpgsql security definer set search_path = public as $$
declare c challenges%rowtype;
begin
  select * into c from challenges where id = p_challenge_id;
  if c.id is null then raise exception 'no such challenge' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(c.studio_id), false) then
    raise exception 'only owners and managers edit challenges' using errcode = 'PT403';
  end if;
  if c.status not in ('draft', 'scheduled') then
    raise exception 'a live challenge cannot be reshaped' using errcode = 'PT409';
  end if;
  if coalesce(p_goal_value, 0) <= 0 then
    raise exception 'a challenge needs a goal above zero' using errcode = 'PT422';
  end if;
  if p_ends_on < p_starts_on then
    raise exception 'the challenge ends before it starts' using errcode = 'PT422';
  end if;
  if p_join_deadline < p_starts_on or p_join_deadline > p_ends_on then
    raise exception 'the join deadline must fall within the challenge' using errcode = 'PT422';
  end if;
  if p_join_deadline < studio_today(c.studio_id) then
    raise exception 'the join deadline has already passed — members could never join'
      using errcode = 'PT422';
  end if;

  update challenges
     set title = p_title, description = p_description, type = p_type,
         goal_value = p_goal_value, class_type_ids = coalesce(p_class_type_ids, '[]'::jsonb),
         starts_on = p_starts_on, ends_on = p_ends_on, join_deadline = p_join_deadline,
         reward_description = p_reward, leaderboard_enabled = coalesce(p_leaderboard, false),
         updated_at = now()
   where id = p_challenge_id;
end $$;

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
    'joined', p.id is not null,
    'progress', coalesce(p.progress, 0),
    'completed_at', p.completed_at,
    -- The deadline governs JOINING, not visibility: a joined member always sees
    -- their progress (above), and a member who has not joined sees whether the
    -- door is still open. Closed-but-running is a state the screen shows, not a
    -- reason to hide the challenge.
    'can_join', p.id is null and c.status in ('scheduled','active') and v_today <= c.join_deadline,
    'history', coalesce((
      select jsonb_agg(jsonb_build_object(
        'occurred_at', e.occurred_at,
        'class_name', o.name)
        order by e.occurred_at desc)
        from challenge_progress_events e
        left join class_occurrences o on o.id = e.occurrence_id
       where e.challenge_id = c.id and e.member_id = v_member), '[]'::jsonb),
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
