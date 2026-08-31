-- =============================================================================
-- MIGRATION 023 — the Morning Brief
--
-- ai_insights and morning_briefs have existed since migration 001 and nothing
-- has ever written a row to either. This writes them.
--
-- Two things this is not:
--
--   It is not a model. Nothing here calls an LLM; the observations are read
--   off the data and the summary is composed from them. `model` and
--   `prompt_version` are left null on purpose — a row claiming a model it
--   never saw would be worse than an empty column, and when a model does
--   draft the wording these are the columns that say which one.
--
--   It does not send. Generation writes rows; a person reads them and acts.
--   Business Rules §11 makes that a hard architectural rule and there is no
--   code path here that messages anybody.
--
-- Thresholds are rows in insight_config, not literals in the queries below.
-- §11 says design partners will move them, and a number a partner can move is
-- a number that cannot be buried in a WHERE clause.
-- =============================================================================

create table insight_config (
  studio_id uuid references studios on delete cascade,
  key       text not null,
  value     numeric not null,
  note      text,
  updated_at timestamptz not null default now(),
  unique (studio_id, key)
);
create unique index insight_config_system_key on insight_config (key) where studio_id is null;

alter table insight_config enable row level security;
create policy insight_config_read on insight_config
  for select using (studio_id is null or is_manager_up(studio_id));
create policy insight_config_manager_write on insight_config
  for all using (studio_id is not null and is_manager_up(studio_id))
  with check (studio_id is not null and is_manager_up(studio_id));
grant select, insert, update, delete on insight_config to authenticated;
grant all on insight_config to service_role;

insert into insight_config (studio_id, key, value, note) values
  (null, 'max_insights',              5,    'Business Rules §11. More than five and the owner stops reading, which defeats the feature.'),
  (null, 'dedupe_days',               7,    '§11. Same subject and type actioned or dismissed inside this window stays suppressed.'),
  (null, 'retention_gap_multiplier',  2,    '§11 retention_risk. Held here for the record — the band computes it (Decision 14 signal 1) and this does not recompute it.'),
  (null, 'retention_min_days',        10,   '§11 retention_risk floor, likewise the band''s.'),
  (null, 'underfilled_pct',           0.40, '§11 class_underfilled: an occurrence below this share of capacity.'),
  (null, 'underfilled_series_pct',    0.70, '§11 class_underfilled: only where the series historically averages above this.'),
  (null, 'underfilled_window_days',   7,    '§11 class_underfilled: how far ahead to look.'),
  (null, 'underfilled_min_history',   4,    'Occurrences needed before a series average means anything. Not in §11; without it one quiet week reads as a trend.'),
  (null, 'overfilled_pct',            0.95, '§11 class_overfilled.'),
  (null, 'overfilled_weeks',          3,    '§11 class_overfilled: consecutive weeks at or above.'),
  (null, 'stalled_max_days',          30,   '§11 new_member_stalled: joined within this many days.'),
  (null, 'stalled_max_visits',        2,    '§11 new_member_stalled: fewer than this many visits.'),
  (null, 'stalled_no_booking_days',   7,    '§11 new_member_stalled: and nothing booked this far ahead.'),
  (null, 'milestone_within_visits',   1,    '§11 milestone_upcoming: within this many visits of a threshold.'),
  (null, 'milestone_days_ahead',      7,    '§11 milestone_upcoming: anniversary or birthday inside this window.'),
  (null, 'challenge_min_members',     5,    '§11 challenge_opportunity.'),
  (null, 'challenge_enabled',         0,    'Off. The threshold below is implemented, but launching a challenge has no screen to open yet and §11 is explicit that an insight without a working button is a bug. Set to 1 when challenges ship.'),
  (null, 'brief_lead_minutes',        30,   'Generation runs this many minutes before morning_brief_send_at, in studio time.');

create function insight_threshold(p_studio_id uuid, p_key text) returns numeric
language sql stable security definer set search_path = public as $$
  select value from insight_config
   where key = p_key and (studio_id = p_studio_id or studio_id is null)
   order by studio_id nulls last
   limit 1
$$;

-- Milestones a studio actually marks. A round number of visits is a thing to
-- say something about; 47 is not.
create function milestone_visit_targets() returns int[]
language sql immutable as $$ select array[10, 25, 50, 100, 200, 365, 500] $$;

revoke execute on function insight_threshold(uuid, text) from public;
revoke execute on function milestone_visit_targets() from public;
grant execute on function insight_threshold(uuid, text) to authenticated, service_role;
grant execute on function milestone_visit_targets() to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Which studios are due
--
-- The clock lives outside the database: a scheduler calls this, then calls
-- generate_morning_brief() for each studio it names. Same shape as the message
-- queue — the thing that fires is an adapter, not a rewrite.
-- -----------------------------------------------------------------------------
create function studios_due_for_brief(p_now timestamptz default now())
returns table (studio_id uuid, local_date date)
language sql stable security definer set search_path = public as $$
  select s.id,
         (p_now at time zone s.timezone)::date
    from studios s
    join studio_settings ss on ss.studio_id = s.id
   where s.status = 'active'
     and (p_now at time zone s.timezone)::time
         >= (ss.morning_brief_send_at
             - make_interval(mins => insight_threshold(s.id, 'brief_lead_minutes')::int))
     and not exists (
       select 1 from morning_briefs b
        where b.studio_id = s.id
          and b.brief_date = (p_now at time zone s.timezone)::date)
$$;
revoke execute on function studios_due_for_brief(timestamptz) from public;
grant execute on function studios_due_for_brief(timestamptz) to service_role;

-- -----------------------------------------------------------------------------
-- Generation
-- -----------------------------------------------------------------------------
create function generate_morning_brief(
  p_studio_id uuid,
  p_for_date  date default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_tz        text;
  v_cur       text;
  v_date      date;
  v_max       int;
  v_dedupe    int;
  n_kept      int;
  v_summary   text;
  v_ids       uuid[];
  v_brief_id  uuid;
begin
  if not is_manager_up(p_studio_id) and not is_platform_admin() then
    raise exception 'only owners and managers may generate a brief'
      using errcode = 'PT403';
  end if;

  select timezone, currency into v_tz, v_cur from studios where id = p_studio_id;
  if v_tz is null then
    raise exception 'no such studio' using errcode = 'PT404';
  end if;

  v_date   := coalesce(p_for_date, (now() at time zone v_tz)::date);
  v_max    := insight_threshold(p_studio_id, 'max_insights')::int;
  v_dedupe := insight_threshold(p_studio_id, 'dedupe_days')::int;

  create temp table _cand (
    type text, severity text, rank int,
    title text, observation text, why_it_matters text, recommended_action text,
    action_type text, action_payload jsonb,
    subject_type text, subject_id uuid,
    estimated_impact_cents int
  ) on commit drop;

  -- ---- retention_risk -------------------------------------------------------
  -- Reads the band. Decision 14 computes "gap beyond 2x their own median, floor
  -- ten days" already and stores the reason as a sentence; recomputing it here
  -- would give two answers to one question and eventually disagree.
  insert into _cand
  select 'retention_risk', 'warning', 2,
         m.first_name || ' ' || m.last_name || ' is drifting',
         m.health_reason,
         'They are still a member and have not decided to leave. The gap is the moment to say something.',
         'Send them a note — the draft is already written.',
         'message_member',
         jsonb_build_object('member_id', m.id,
                            'href', '/members/' || m.id || '/message'),
         'member', m.id,
         coalesce((select ms.price_cents from memberships ms
                    where ms.member_id = m.id
                      and ms.status not in ('cancelled','expired')
                    order by ms.starts_on desc limit 1), 0)
    from members m
   where m.studio_id = p_studio_id
     and m.status = 'active'
     and m.health_band in ('at_risk','drifting')
     and m.health_signals ->> 0 = 'rhythm_deviation';

  -- ---- payment_failed -------------------------------------------------------
  insert into _cand
  select 'payment_failed', 'urgent', 1,
         m.first_name || ' ' || m.last_name || ' cannot book',
         'Their membership is past due, so booking is closed to them until it is settled.',
         'This is money already earned and not collected, and they cannot use what they are paying for.',
         'Tell them the card failed and how to fix it.',
         'message_member',
         jsonb_build_object('member_id', m.id,
                            'href', '/members/' || m.id || '/message'),
         'member', m.id,
         ms.price_cents
    from memberships ms
    join members m on m.id = ms.member_id
   where ms.studio_id = p_studio_id
     and ms.status = 'past_due'
     and m.status = 'active';

  -- ---- new_member_stalled ---------------------------------------------------
  insert into _cand
  select 'new_member_stalled', 'warning', 3,
         m.first_name || ' ' || m.last_name || ' has not got going',
         format('Joined %s days ago, %s visit%s, and nothing booked.',
                v_date - m.joined_on, m.lifetime_visits,
                case when m.lifetime_visits = 1 then '' else 's' end),
         'The first month decides whether someone stays. This is the most rescuable member you have.',
         'Ask how they got on and help them pick a class.',
         'message_member',
         jsonb_build_object('member_id', m.id,
                            'href', '/members/' || m.id || '/message'),
         'member', m.id, 0
    from members m
   where m.studio_id = p_studio_id
     and m.status = 'active'
     and v_date - m.joined_on <= insight_threshold(p_studio_id,'stalled_max_days')::int
     and m.lifetime_visits < insight_threshold(p_studio_id,'stalled_max_visits')::int
     and not exists (
       select 1 from bookings b
         join class_occurrences o on o.id = b.occurrence_id
        where b.member_id = m.id
          and b.status in ('booked','waitlisted')
          and o.starts_at between now()
              and now() + make_interval(days => insight_threshold(p_studio_id,'stalled_no_booking_days')::int));

  -- ---- milestone_upcoming ---------------------------------------------------
  insert into _cand
  select 'milestone_upcoming', 'info', 5,
         m.first_name || ' ' || m.last_name || ' is one visit from ' || t.target,
         format('%s visits so far. The next one makes %s.', m.lifetime_visits, t.target),
         'Noticing is free and it is the kind of thing people tell their friends about.',
         'Say something when they come in.',
         'celebrate',
         jsonb_build_object('member_id', m.id, 'milestone', t.target,
                            'href', '/members/' || m.id),
         'member', m.id, 0
    from members m
    cross join lateral unnest(milestone_visit_targets()) as t(target)
   where m.studio_id = p_studio_id
     and m.status = 'active'
     and t.target - m.lifetime_visits
         between 1 and insight_threshold(p_studio_id,'milestone_within_visits')::int;

  -- Anniversaries and birthdays inside the window, same type.
  insert into _cand
  select 'milestone_upcoming', 'info', 5,
         m.first_name || ' ' || m.last_name || ' has an anniversary coming up',
         format('%s years with you on %s.',
                extract(year from age(v_date, m.joined_on))::int + 1,
                to_char(m.joined_on, 'FMDD Month')),
         'A year is worth marking, and nobody else is going to mention it.',
         'Say something when they come in.',
         'celebrate',
         jsonb_build_object('member_id', m.id, 'href', '/members/' || m.id),
         'member', m.id, 0
    from members m
   where m.studio_id = p_studio_id
     and m.status = 'active'
     and m.joined_on < v_date - interval '300 days'
     and ((to_char(m.joined_on, 'MM-DD')::text) in (
            select to_char(v_date + i, 'MM-DD')
              from generate_series(0, insight_threshold(p_studio_id,'milestone_days_ahead')::int) i));

  -- ---- class_underfilled ----------------------------------------------------
  insert into _cand
  select 'class_underfilled', 'info', 4,
         o.name || ' on ' || to_char(o.starts_at at time zone v_tz, 'FMDay') ||
           ' is half empty',
         format('%s of %s booked, against a usual %s%% for this class.',
                o.booked_count, o.capacity, round(h.avg_fill * 100)),
         'A class that normally fills and suddenly does not is worth a look before it runs.',
         'Open the class and see who usually comes.',
         'open_class',
         jsonb_build_object('occurrence_id', o.id, 'href', '/roster/' || o.id),
         'occurrence', o.id,
         (o.capacity - o.booked_count) * coalesce(
           (select price_cents from membership_plans
             where studio_id = p_studio_id and type = 'drop_in' and status = 'active'
             order by price_cents limit 1), 0)
    from class_occurrences o
    join lateral (
      select avg(p.booked_count::numeric / nullif(p.capacity,0)) as avg_fill,
             count(*) as n
        from class_occurrences p
       where p.series_id is not distinct from o.series_id
         and p.studio_id = p_studio_id
         and p.starts_at < now()
         and p.status <> 'cancelled'
    ) h on true
   where o.studio_id = p_studio_id
     and o.status = 'scheduled'
     and o.starts_at between now()
         and now() + make_interval(days => insight_threshold(p_studio_id,'underfilled_window_days')::int)
     and o.capacity > 0
     and o.booked_count::numeric / o.capacity < insight_threshold(p_studio_id,'underfilled_pct')
     and h.n >= insight_threshold(p_studio_id,'underfilled_min_history')::int
     and h.avg_fill > insight_threshold(p_studio_id,'underfilled_series_pct');

  -- ---- class_overfilled -----------------------------------------------------
  insert into _cand
  select 'class_overfilled', 'info', 4,
         nxt.name || ' has been full for ' ||
           insight_threshold(p_studio_id,'overfilled_weeks')::int || ' weeks',
         format('Averaging %s%% of capacity. People are being turned away.',
                round(w.min_fill * 100)),
         'A class this full is a second class waiting to be scheduled, or a bigger room.',
         'Open it and see the waitlist.',
         'open_class',
         jsonb_build_object('occurrence_id', nxt.id, 'series_id', w.series_id,
                            'href', '/roster/' || nxt.id),
         'occurrence', nxt.id, 0
    from (
      select p.series_id,
             min(wk.fill) as min_fill
        from class_occurrences p
        join lateral (
          select avg(q.booked_count::numeric / nullif(q.capacity,0)) as fill
            from class_occurrences q
           where q.series_id = p.series_id and q.studio_id = p_studio_id
             and q.starts_at >= now() - make_interval(weeks => 1)
             and q.starts_at < now()
        ) wk on true
       where p.studio_id = p_studio_id and p.series_id is not null
       group by p.series_id
    ) w
    join lateral (
      select o.id, o.name from class_occurrences o
       where o.series_id = w.series_id and o.starts_at > now()
         and o.status = 'scheduled'
       order by o.starts_at limit 1
    ) nxt on true
   where w.min_fill >= insight_threshold(p_studio_id,'overfilled_pct');

  -- ---- challenge_opportunity ------------------------------------------------
  -- Implemented and switched off. There is no screen that launches a
  -- challenge, so its button would go nowhere, and §11 calls an insight
  -- without a working button a bug. The threshold is here so that turning it
  -- on later is a config change.
  if insight_threshold(p_studio_id, 'challenge_enabled') >= 1 then
    insert into _cand
    select 'challenge_opportunity', 'info', 6,
           'Enough members for a challenge',
           format('%s members are coming regularly and none of them is in a challenge.',
                  count(*)),
           'A challenge gives regulars a reason to come more often without discounting anything.',
           'Launch one.',
           'launch_challenge',
           jsonb_build_object('href', '/challenges/new'),
           'studio', p_studio_id, 0
      from members m
     where m.studio_id = p_studio_id and m.status = 'active'
       and m.health_band = 'healthy'
    having count(*) >= insight_threshold(p_studio_id,'challenge_min_members')::int;
  end if;

  -- ---- dedupe, rank, cap ----------------------------------------------------
  -- §11: same subject and type actioned or dismissed inside the window stays
  -- suppressed. Applied before the cap so a suppressed item does not consume
  -- one of the five slots and hide something the owner has not seen.
  delete from _cand c
   where exists (
     select 1 from ai_insights i
      where i.studio_id = p_studio_id
        and i.type = c.type
        and i.subject_id is not distinct from c.subject_id
        and i.status in ('actioned','dismissed')
        and coalesce(i.actioned_at, i.dismissed_at)
            > now() - make_interval(days => v_dedupe));

  -- One per (type, subject) before the unique index has to care.
  delete from _cand a
   using _cand b
   where a.type = b.type
     and a.subject_id is not distinct from b.subject_id
     and a.ctid > b.ctid;

  -- And one per SUBJECT, keeping the most severe. §11's key is (type, subject,
  -- date), which permits the same member appearing twice under two types — and
  -- on real data it does: a member whose card was declined cannot book, so she
  -- shows up as payment_failed and again as retention_risk, taking two of the
  -- five slots and pushing out two other people. The second insight is also
  -- downstream of the first; fixing the card fixes the drifting. Stricter than
  -- §11 asks, and §11's own reason — more than five and the owner stops
  -- reading — is the argument for it.
  delete from _cand a
   using _cand b
   where a.subject_id is not distinct from b.subject_id
     and a.subject_id is not null
     and (b.rank < a.rank or (b.rank = a.rank and b.ctid < a.ctid));

  insert into ai_insights
    (studio_id, type, severity, title, observation, why_it_matters,
     recommended_action, action_type, action_payload, subject_type, subject_id,
     estimated_impact_cents, for_date, status)
  select p_studio_id, c.type, c.severity, c.title, c.observation, c.why_it_matters,
         c.recommended_action, c.action_type, c.action_payload, c.subject_type,
         c.subject_id, nullif(c.estimated_impact_cents, 0), v_date, 'new'
    from (
      select * from _cand
       order by rank, estimated_impact_cents desc nulls last, subject_id
       limit v_max
    ) c
  on conflict (studio_id, type, subject_id, for_date) do update
     set title = excluded.title,
         observation = excluded.observation,
         action_payload = excluded.action_payload,
         estimated_impact_cents = excluded.estimated_impact_cents;

  select count(*), array_agg(id order by
           case severity when 'urgent' then 1 when 'warning' then 2 else 3 end,
           estimated_impact_cents desc nulls last)
    into n_kept, v_ids
    from ai_insights
   where studio_id = p_studio_id and for_date = v_date;

  v_summary := brief_summary(p_studio_id, v_date);

  insert into morning_briefs (studio_id, brief_date, summary, metrics, insight_ids)
  values (p_studio_id, v_date, v_summary,
          jsonb_build_object(
            'insight_count', n_kept,
            'candidates_considered', (select count(*) from _cand),
            'money_at_stake_cents', coalesce((
              select sum(estimated_impact_cents) from ai_insights
               where studio_id = p_studio_id and for_date = v_date), 0),
            'currency', v_cur),
          coalesce(v_ids, '{}'))
  on conflict (studio_id, brief_date) do update
     set summary = excluded.summary,
         metrics = excluded.metrics,
         insight_ids = excluded.insight_ids,
         generated_at = now()
  returning id into v_brief_id;

  return jsonb_build_object('brief_id', v_brief_id, 'for_date', v_date,
                            'insights', n_kept, 'summary', v_summary);
end $$;

-- -----------------------------------------------------------------------------
-- The summary
--
-- The thing that makes the brief worth opening. Not a count of cards: a
-- sentence someone could read out. Composed from the insights that survived
-- the cap, so it can never describe something the owner cannot see below it.
-- -----------------------------------------------------------------------------
-- Small numbers as words. "3 members have drifted" is a stat line; "Three
-- members have drifted" is a sentence, and the summary only earns its place
-- if it reads like one.
create function say_count(n int) returns text
language sql immutable as $$
  select case n
    when 1 then 'one'  when 2 then 'two'   when 3 then 'three' when 4 then 'four'
    when 5 then 'five' when 6 then 'six'   when 7 then 'seven' when 8 then 'eight'
    when 9 then 'nine' when 10 then 'ten'
    else n::text end
$$;

create function brief_summary(p_studio_id uuid, p_date date) returns text
language plpgsql stable security definer set search_path = public as $$
declare
  n_drift int; n_pay int; n_stall int; n_under int; n_over int; n_mile int;
  detail  text;
  parts   text[] := '{}';
  out     text;
begin
  select count(*) filter (where type = 'retention_risk'),
         count(*) filter (where type = 'payment_failed'),
         count(*) filter (where type = 'new_member_stalled'),
         count(*) filter (where type = 'class_underfilled'),
         count(*) filter (where type = 'class_overfilled'),
         count(*) filter (where type = 'milestone_upcoming')
    into n_drift, n_pay, n_stall, n_under, n_over, n_mile
    from ai_insights where studio_id = p_studio_id and for_date = p_date;

  if n_drift + n_pay + n_stall + n_under + n_over + n_mile = 0 then
    return 'Nothing needs you this morning. Everyone who was coming is still '
           'coming, every card went through, and no class is unusually empty.';
  end if;

  -- Ordered by what it costs to ignore, so the sentence and the list below it
  -- lead with the same thing.
  if n_pay > 0 then
    parts := parts || format('%s card%s been declined',
      say_count(n_pay), case when n_pay = 1 then ' has' else 's have' end);
  end if;
  if n_drift > 0 then
    parts := parts || format('%s member%s drifted',
      say_count(n_drift),
      case when n_drift = 1 then ' has' else 's have' end);
  end if;
  if n_stall > 0 then
    parts := parts || format('%s new member%s not got going',
      say_count(n_stall), case when n_stall = 1 then ' has' else 's have' end);
  end if;

  -- A class gets named rather than counted. "One class is emptier than usual"
  -- tells the owner nothing they can act on before breakfast; naming the class
  -- is the whole point of the sentence.
  if n_under > 0 then
    select i.title into detail from ai_insights i
     where i.studio_id = p_studio_id and i.for_date = p_date
       and i.type = 'class_underfilled'
     order by i.estimated_impact_cents desc nulls last limit 1;
    parts := parts || lower(detail)
             || case when n_under > 1
                     then format(' (and %s other%s)', say_count(n_under - 1),
                                 case when n_under = 2 then '' else 's' end)
                     else '' end;
  end if;
  if n_over > 0 then
    select i.title into detail from ai_insights i
     where i.studio_id = p_studio_id and i.for_date = p_date
       and i.type = 'class_overfilled'
     order by i.title limit 1;
    parts := parts || lower(detail);
  end if;
  if n_mile > 0 then
    parts := parts || format('%s milestone%s coming up',
      say_count(n_mile), case when n_mile = 1 then ' is' else 's are' end);
  end if;

  out := array_to_string(parts, '; ');
  return upper(left(out, 1)) || right(out, -1) || '.';
end $$;

revoke execute on function say_count(int) from public;
grant execute on function say_count(int) to authenticated, service_role;

revoke execute on function generate_morning_brief(uuid, date) from public;
revoke execute on function brief_summary(uuid, date) from public;
grant execute on function generate_morning_brief(uuid, date) to authenticated, service_role;
grant execute on function brief_summary(uuid, date) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Acting on one
-- -----------------------------------------------------------------------------
create function set_insight_status(p_insight_id uuid, p_status insight_status)
returns ai_insights
language plpgsql security definer set search_path = public as $$
declare ins ai_insights%rowtype;
begin
  select * into ins from ai_insights where id = p_insight_id;
  if not found then
    raise exception 'no such insight' using errcode = 'PT404';
  end if;
  if not is_manager_up(ins.studio_id) then
    raise exception 'only owners and managers may action an insight'
      using errcode = 'PT403';
  end if;
  if p_status not in ('actioned','dismissed') then
    raise exception 'an insight can only be actioned or dismissed'
      using errcode = 'PT422';
  end if;

  update ai_insights
     set status = p_status,
         actioned_at  = case when p_status = 'actioned'  then now() else actioned_at end,
         actioned_by  = case when p_status = 'actioned'  then auth.uid() else actioned_by end,
         dismissed_at = case when p_status = 'dismissed' then now() else dismissed_at end
   where id = p_insight_id
  returning * into ins;

  return ins;
end $$;
revoke execute on function set_insight_status(uuid, insight_status) from public;
grant execute on function set_insight_status(uuid, insight_status) to authenticated, service_role;

comment on function generate_morning_brief(uuid, date) is
  'Writes today''s insights and brief for one studio. Deterministic, reads no '
  'model, sends nothing. Business Rules §11.';
