-- Challenges, part 4: the functions the two apps call — staff create/publish
-- and read, member list/detail. Members only throughout; audience is fixed to
-- 'member' and never taken from the caller.

-- -----------------------------------------------------------------------------
-- Create — manager-up. A challenge is born a DRAFT; publish is the deliberate
-- go-live. The date rules are enforced here (and by the table's own CHECKs), so
-- a bad range is refused with a sentence rather than a raw constraint error —
-- the create_occurrence lesson: creating goes through the same gate as editing.
-- -----------------------------------------------------------------------------
create function create_challenge(
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

  insert into challenges (studio_id, template_id, title, description, audience, type,
                          goal_value, class_type_ids, starts_on, ends_on, join_deadline,
                          reward_description, leaderboard_enabled, status, created_by)
  values (p_studio_id, p_template_id, p_title, p_description, 'member', p_type,
          p_goal_value, coalesce(p_class_type_ids, '[]'::jsonb), p_starts_on, p_ends_on,
          p_join_deadline, p_reward, coalesce(p_leaderboard, false), 'draft', auth.uid())
  returning id into v_id;
  return v_id;
end $$;

-- Edit while it is still a draft or scheduled — once it is active, members have
-- joined against its terms and the shape is fixed. Manager-up.
create function update_challenge(
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

  update challenges
     set title = p_title, description = p_description, type = p_type,
         goal_value = p_goal_value, class_type_ids = coalesce(p_class_type_ids, '[]'::jsonb),
         starts_on = p_starts_on, ends_on = p_ends_on, join_deadline = p_join_deadline,
         reward_description = p_reward, leaderboard_enabled = coalesce(p_leaderboard, false),
         updated_at = now()
   where id = p_challenge_id;
end $$;

-- Publish — draft to scheduled, or straight to active if it has already begun.
-- Announces to the studio's members (challenge_opening). Manager-up.
create function publish_challenge(p_challenge_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare c challenges%rowtype; v_tz text; v_today date; v_status challenge_status;
begin
  select * into c from challenges where id = p_challenge_id;
  if c.id is null then raise exception 'no such challenge' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(c.studio_id), false) then
    raise exception 'only owners and managers publish challenges' using errcode = 'PT403';
  end if;
  if c.status <> 'draft' then
    raise exception 'this challenge is already %', c.status using errcode = 'PT409';
  end if;

  select timezone into v_tz from studios where id = c.studio_id;
  v_today := (now() at time zone v_tz)::date;
  v_status := case when c.starts_on <= v_today then 'active' else 'scheduled' end;

  update challenges set status = v_status, updated_at = now() where id = p_challenge_id;
  perform queue_challenge_opening(p_challenge_id);
  return v_status::text;
end $$;

-- -----------------------------------------------------------------------------
-- Staff read: the list, with join and completion counts, and one challenge's
-- full participant board. Manager-up.
-- -----------------------------------------------------------------------------
create function staff_challenges(p_studio_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (coalesce(is_manager_up(p_studio_id), false) or is_service_context()) then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id, 'title', c.title, 'type', c.type, 'goal_value', c.goal_value,
      'status', c.status, 'starts_on', c.starts_on, 'ends_on', c.ends_on,
      'join_deadline', c.join_deadline, 'leaderboard_enabled', c.leaderboard_enabled,
      'class_type_ids', c.class_type_ids, 'reward_description', c.reward_description,
      'joined_count', (select count(*) from challenge_participants p where p.challenge_id = c.id),
      'completed_count', (select count(*) from challenge_participants p
                           where p.challenge_id = c.id and p.completed_at is not null))
      order by c.created_at desc)
      from challenges c
     where c.studio_id = p_studio_id and c.audience = 'member'), '[]'::jsonb);
end $$;

create function challenge_overview(p_challenge_id uuid) returns jsonb
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

-- -----------------------------------------------------------------------------
-- Member read: the list this member can see, and one challenge in full.
--
-- The list is the member app's Home section and /challenges — open challenges,
-- whether they have joined, and their own progress. A studio with no member
-- challenges returns an empty array, which is what makes the whole feature
-- ABSENT rather than empty for it.
-- -----------------------------------------------------------------------------
create function member_challenges(p_studio_id uuid) returns jsonb
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

create function member_challenge_detail(p_challenge_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c challenges%rowtype; v_member uuid; p challenge_participants%rowtype;
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

  return jsonb_build_object(
    'id', c.id, 'title', c.title, 'description', c.description, 'type', c.type,
    'goal_value', c.goal_value, 'status', c.status, 'starts_on', c.starts_on,
    'ends_on', c.ends_on, 'join_deadline', c.join_deadline,
    'reward_description', c.reward_description, 'leaderboard_enabled', c.leaderboard_enabled,
    'joined', p.id is not null,
    'progress', coalesce(p.progress, 0),
    'completed_at', p.completed_at,
    'history', coalesce((
      select jsonb_agg(jsonb_build_object(
        'occurred_at', e.occurred_at,
        'class_name', o.name)
        order by e.occurred_at desc)
        from challenge_progress_events e
        left join class_occurrences o on o.id = e.occurrence_id
       where e.challenge_id = c.id and e.member_id = v_member), '[]'::jsonb),
    -- The board only when the studio turned it on. A member's OWN progress is
    -- above, always; this is the ranking against others, which is the opt-in.
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
-- Grants — the client-callable ones guard inside; granted to authenticated.
-- -----------------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'create_challenge(uuid,text,challenge_type,int,date,date,date,jsonb,text,boolean,text,uuid)',
    'update_challenge(uuid,text,challenge_type,int,date,date,date,jsonb,text,boolean,text)',
    'publish_challenge(uuid)', 'staff_challenges(uuid)', 'challenge_overview(uuid)',
    'member_challenges(uuid)', 'member_challenge_detail(uuid)']
  loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant  execute on function %s to authenticated, service_role', f);
  end loop;
end $$;
