-- Challenges, part 3: the five messages (§12) and the date-based sweep.
--
-- joined / milestone / completed / ending-soon / opening. All go through
-- queue_notification, so a member's opt-out (challenge_email) is checked at
-- queue time and each has a deterministic dedupe key — the same fact queued
-- twice is one row.

insert into notification_templates (key, subject, text_body, html_body, note) values
('challenge_joined', 'You''re in — {challenge_title}',
 E'Hi {first_name},\n\nYou''ve joined {challenge_title}. Your goal: {goal_line}.\n\n{reward_line}\n\nEvery class you attend from the start of the challenge counts. Good luck.\n\n{studio_name}',
 E'<p>Hi {first_name},</p><p>You''ve joined <strong>{challenge_title}</strong>. Your goal: {goal_line}.</p><p>{reward_line}</p><p>Every class you attend from the start of the challenge counts. Good luck.</p>',
 '§9 joined.'),
('challenge_milestone', 'Halfway there — {challenge_title}',
 E'Hi {first_name},\n\nYou''re halfway through {challenge_title} — {progress_line}. Keep going.\n\n{studio_name}',
 E'<p>Hi {first_name},</p><p>You''re halfway through <strong>{challenge_title}</strong> — {progress_line}. Keep going.</p>',
 '§9 milestone.'),
('challenge_completed', 'You did it — {challenge_title}',
 E'Hi {first_name},\n\nYou''ve completed {challenge_title}. {reward_line}\n\n{studio_name}',
 E'<p>Hi {first_name},</p><p>You''ve completed <strong>{challenge_title}</strong>.</p><p>{reward_line}</p>',
 '§9.3 completion.'),
('challenge_ending_soon', '{challenge_title} ends {ends_word}',
 E'Hi {first_name},\n\n{challenge_title} ends {ends_word}. You''re at {progress_line} — there''s still time.\n\n{studio_name}',
 E'<p>Hi {first_name},</p><p><strong>{challenge_title}</strong> ends {ends_word}. You''re at {progress_line} — there''s still time.</p>',
 '§9 ending soon.'),
('challenge_opening', 'New challenge — {challenge_title}',
 E'Hi {first_name},\n\n{challenge_title} is open to join. {goal_line}.\n\n{reward_line}\n\nJoin in the app before {deadline_word}.\n\n{studio_name}',
 E'<p>Hi {first_name},</p><p><strong>{challenge_title}</strong> is open to join. {goal_line}.</p><p>{reward_line}</p><p>Join in the app before {deadline_word}.</p>',
 '§9 opening.');

-- -----------------------------------------------------------------------------
-- A challenge's goal and reward as a human line, composed once here so every
-- message phrases them the same way. A streak counts weeks; the others count
-- classes.
-- -----------------------------------------------------------------------------
create function challenge_goal_line(p_challenge_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select case c.type
           when 'streak' then c.goal_value || ' weeks in a row'
           else c.goal_value || ' classes'
         end
    from challenges c where c.id = p_challenge_id;
$$;

create function queue_challenge_joined(p_participant_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare p challenge_participants%rowtype; c challenges%rowtype;
begin
  select * into p from challenge_participants where id = p_participant_id;
  select * into c from challenges where id = p.challenge_id;
  if p.member_id is null then return 0; end if;
  return case when queue_notification(p.studio_id, p.member_id, 'challenge_joined',
      jsonb_build_object(
        'challenge_title', c.title,
        'goal_line', challenge_goal_line(c.id),
        'reward_line', coalesce(nullif(c.reward_description, ''),
                                'Bragging rights and a healthier habit.')),
      'challenge_joined:' || p_participant_id) is not null then 1 else 0 end;
end $$;

create function queue_challenge_milestone(p_participant_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare p challenge_participants%rowtype; c challenges%rowtype; v_line text;
begin
  select * into p from challenge_participants where id = p_participant_id;
  select * into c from challenges where id = p.challenge_id;
  if p.member_id is null then return 0; end if;
  v_line := case c.type when 'streak' then p.progress || ' of ' || c.goal_value || ' weeks'
                        else p.progress || ' of ' || c.goal_value || ' classes' end;
  return case when queue_notification(p.studio_id, p.member_id, 'challenge_milestone',
      jsonb_build_object('challenge_title', c.title, 'progress_line', v_line),
      'challenge_milestone:' || p_participant_id) is not null then 1 else 0 end;
end $$;

create function queue_challenge_completed(p_participant_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare p challenge_participants%rowtype; c challenges%rowtype;
begin
  select * into p from challenge_participants where id = p_participant_id;
  select * into c from challenges where id = p.challenge_id;
  if p.member_id is null then return 0; end if;
  return case when queue_notification(p.studio_id, p.member_id, 'challenge_completed',
      jsonb_build_object(
        'challenge_title', c.title,
        'reward_line', coalesce(nullif(c.reward_description, ''),
                                'The studio will be in touch about your reward.')),
      'challenge_completed:' || p_participant_id) is not null then 1 else 0 end;
end $$;

create function queue_challenge_ending_soon(p_participant_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare p challenge_participants%rowtype; c challenges%rowtype; v_line text; v_word text;
begin
  select * into p from challenge_participants where id = p_participant_id;
  select * into c from challenges where id = p.challenge_id;
  if p.member_id is null then return 0; end if;
  v_line := case c.type when 'streak' then p.progress || ' of ' || c.goal_value || ' weeks'
                        else p.progress || ' of ' || c.goal_value || ' classes' end;
  v_word := to_char(c.ends_on, 'FMDay DD Mon');
  return case when queue_notification(p.studio_id, p.member_id, 'challenge_ending_soon',
      jsonb_build_object('challenge_title', c.title, 'progress_line', v_line, 'ends_word', v_word),
      'challenge_ending_soon:' || p_participant_id) is not null then 1 else 0 end;
end $$;

-- Opening is the announce: a broadcast to the studio's members inviting them to
-- join. Deduped per member per challenge, opt-outable like the rest.
create function queue_challenge_opening(p_challenge_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare c challenges%rowtype; v_n int := 0; r record;
begin
  select * into c from challenges where id = p_challenge_id;
  if c.id is null or c.audience <> 'member' then return 0; end if;
  for r in select id as member_id from members where studio_id = c.studio_id loop
    v_n := v_n + case when queue_notification(c.studio_id, r.member_id, 'challenge_opening',
        jsonb_build_object(
          'challenge_title', c.title,
          'goal_line', challenge_goal_line(c.id),
          'reward_line', coalesce(nullif(c.reward_description, ''),
                                  'A healthier habit and something to aim for.'),
          'deadline_word', to_char(c.join_deadline, 'FMDay DD Mon')),
        'challenge_opening:' || p_challenge_id || ':' || r.member_id) is not null
      then 1 else 0 end;
  end loop;
  return v_n;
end $$;

-- -----------------------------------------------------------------------------
-- The date-based sweep — status transitions and ending-soon. Studio-local,
-- because a challenge's dates are wall-calendar dates. Idempotent: transitions
-- are one-way and ending-soon is deduped per participant, so a repeat run is a
-- no-op. Two studios with different challenges are decided in one run.
-- -----------------------------------------------------------------------------
create function sweep_challenges() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_opened int := 0; v_ended int := 0; v_ending int := 0; r record;
begin
  if not is_service_context() then
    raise exception 'the challenge sweep is a background job' using errcode = 'PT403';
  end if;

  update challenges c set status = 'active', updated_at = now()
    from studios s
   where s.id = c.studio_id and c.audience = 'member' and c.status = 'scheduled'
     and c.starts_on <= (now() at time zone s.timezone)::date;
  get diagnostics v_opened = row_count;

  update challenges c set status = 'ended', updated_at = now()
    from studios s
   where s.id = c.studio_id and c.audience = 'member' and c.status = 'active'
     and c.ends_on < (now() at time zone s.timezone)::date;
  get diagnostics v_ended = row_count;

  for r in
    select cp.id as pid
      from challenge_participants cp
      join challenges c on c.id = cp.challenge_id
      join studios s   on s.id = c.studio_id
     where c.status = 'active' and cp.completed_at is null and cp.audience = 'member'
       and (c.ends_on - (now() at time zone s.timezone)::date) between 1 and 3
  loop
    v_ending := v_ending + queue_challenge_ending_soon(r.pid);
  end loop;

  insert into job_runs (job_key, run_for, status, finished_at)
  values ('challenges', current_date, 'done', now())
  on conflict (job_key, run_for) do update
     set attempts = job_runs.attempts + 1, started_at = now(),
         status = 'done', finished_at = now();

  return jsonb_build_object('opened', v_opened, 'ended', v_ended, 'ending_soon', v_ending);
end $$;

select cron.schedule('studiior-challenges', '*/30 * * * *', $$ select sweep_challenges(); $$);

-- Grants. The queue wrappers and the sweep are internals reached through the
-- engine, the sweep cron and publish_challenge — no client calls them.
do $$
declare f text;
begin
  foreach f in array array[
    'challenge_goal_line(uuid)', 'queue_challenge_joined(uuid)',
    'queue_challenge_milestone(uuid)', 'queue_challenge_completed(uuid)',
    'queue_challenge_ending_soon(uuid)', 'queue_challenge_opening(uuid)',
    'sweep_challenges()']
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
    execute format('grant  execute on function %s to service_role', f);
  end loop;
end $$;
