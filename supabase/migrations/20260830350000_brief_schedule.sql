-- =============================================================================
-- MIGRATION 024 — the clock behind the Morning Brief
--
-- studios_due_for_brief() has existed since migration 023 and nothing has ever
-- called it, so no brief has ever generated on its own. This is the caller.
--
-- Every fifteen minutes, not hourly. morning_brief_send_at is per studio and
-- studios span timezones, so an hourly job delivers some briefs up to 59
-- minutes late — and a brief that arrives after the owner has opened the
-- studio is a brief about a morning they have already had.
--
-- The interesting part is the guard. pg_cron runs the job as `postgres` with
-- no JWT at all, so auth.uid() is null, is_platform_admin() is false and
-- is_manager_up() is false — correctly false, since migration 020. A job that
-- cannot get past its own permission check is no use, and the wrong way to fix
-- it is to let a null through: "auth.uid() is null means trusted" is exactly
-- the hole migration 002 had and migration 020 finished closing, and it would
-- hand the brief to any caller PostgREST failed to identify.
--
-- So the new path is a POSITIVE check on who the caller actually is:
-- is_service_context() asks whether the effective role is one Postgres itself
-- marks as superuser or BYPASSRLS. `postgres`, `service_role` and
-- `supabase_admin` are; `authenticated` and `anon` are not, and no request
-- arriving through PostgREST from a browser can become one. It returns a
-- boolean, never null.
-- =============================================================================

create function is_service_context() returns boolean
language sql stable security definer set search_path = public as $$
  -- The caller's EFFECTIVE role, not current_user: inside a SECURITY DEFINER
  -- function current_user is the owner, so asking it would answer "postgres"
  -- for everybody and trust the whole world. Same reasoning as book_class()
  -- in migration 002. current_setting('role') is 'none' on a connection that
  -- never SET one, which is the pg_cron case, hence the fallback.
  select coalesce(
    exists (
      select 1 from pg_roles
       where rolname = coalesce(nullif(current_setting('role', true), 'none'), session_user)
         and (rolsuper or rolbypassrls)
    ), false)
$$;

comment on function is_service_context() is
  'True when the caller is a trusted backend role (superuser or BYPASSRLS): '
  'pg_cron, service_role, supabase_admin. Never true for authenticated or '
  'anon, and never null. This is a positive check on the role — it is not, and '
  'must never become, a test for a missing JWT.';

revoke execute on function is_service_context() from public;
grant execute on function is_service_context() to authenticated, service_role;

-- The brief generator gains that third door and nothing else changes.
create or replace function generate_morning_brief(
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
  if not is_manager_up(p_studio_id)
     and not is_platform_admin()
     and not is_service_context() then
    raise exception 'only owners, managers or the scheduler may generate a brief'
      using errcode = 'PT403';
  end if;

  select timezone, currency into v_tz, v_cur from studios where id = p_studio_id;
  if v_tz is null then
    raise exception 'no such studio' using errcode = 'PT404';
  end if;

  v_date   := coalesce(p_for_date, (now() at time zone v_tz)::date);
  v_max    := insight_threshold(p_studio_id, 'max_insights')::int;
  v_dedupe := insight_threshold(p_studio_id, 'dedupe_days')::int;

  -- Dropped first, not merely created. `on commit drop` cleans up at COMMIT,
  -- and the scheduler loops over every due studio inside ONE transaction — so
  -- the second studio hit "relation _cand already exists" and failed, and with
  -- ten design partners nine briefs would fail every morning while the first
  -- one looked fine. Exactly the shape of the generate_demo_data() bug already
  -- in CLAUDE.md, which is why that note says "once per transaction".
  -- Checked rather than DROP IF EXISTS, which emits a NOTICE every time it
  -- finds nothing — ninety-six runs a day of "table _cand does not exist,
  -- skipping" in the cron log is how real messages get missed.
  if to_regclass('pg_temp._cand') is not null then
    drop table _cand;
  end if;
  create temp table _cand (
    type text, severity text, rank int,
    title text, observation text, why_it_matters text, recommended_action text,
    action_type text, action_payload jsonb,
    subject_type text, subject_id uuid,
    estimated_impact_cents int
  ) on commit drop;

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

  delete from _cand c
   where exists (
     select 1 from ai_insights i
      where i.studio_id = p_studio_id
        and i.type = c.type
        and i.subject_id is not distinct from c.subject_id
        and i.status in ('actioned','dismissed')
        and coalesce(i.actioned_at, i.dismissed_at)
            > now() - make_interval(days => v_dedupe));

  delete from _cand a
   using _cand b
   where a.type = b.type
     and a.subject_id is not distinct from b.subject_id
     and a.ctid > b.ctid;

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
-- The job
--
-- job_runs has a unique constraint on (job_key, run_for) and exists for exactly
-- this. The key carries the studio and the date is the studio's own local date,
-- so a studio gets at most one generation per local day however many times the
-- job fires — which at a quarter past every hour is ninety-six times.
--
-- The claim is an upsert with a WHERE on the DO UPDATE: a row already marked
-- done returns nothing and the studio is skipped, while a row left 'running' by
-- a crashed run is claimed again and retried. Doing it the other way — plain
-- ON CONFLICT DO NOTHING — makes a crash permanent, and that studio silently
-- never gets a brief again.
-- -----------------------------------------------------------------------------
create function run_due_morning_briefs() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r        record;
  v_job    uuid;
  n_done   int := 0;
  n_skip   int := 0;
  n_fail   int := 0;
begin
  if not is_service_context() then
    raise exception 'the brief scheduler runs as the backend, not as a user'
      using errcode = 'PT403',
            hint = 'Owners generate a brief with generate_morning_brief().';
  end if;

  for r in select * from studios_due_for_brief(now()) loop
    insert into job_runs (job_key, run_for, status)
    values ('morning_brief:' || r.studio_id, r.local_date, 'running')
    on conflict (job_key, run_for) do update
       set attempts   = job_runs.attempts + 1,
           started_at = now(),
           status     = 'running'
     where job_runs.status <> 'done'
    returning id into v_job;

    if v_job is null then
      n_skip := n_skip + 1;
      continue;
    end if;

    begin
      perform generate_morning_brief(r.studio_id, r.local_date);
      update job_runs
         set status = 'done', finished_at = now(), error = null
       where id = v_job;
      n_done := n_done + 1;
    exception when others then
      -- One studio's bad data must not stop every other studio's brief.
      update job_runs
         set status = 'failed', finished_at = now(), error = sqlerrm
       where id = v_job;
      n_fail := n_fail + 1;
    end;
  end loop;

  return jsonb_build_object('generated', n_done, 'skipped', n_skip, 'failed', n_fail);
end $$;

revoke execute on function run_due_morning_briefs() from public;
grant execute on function run_due_morning_briefs() to service_role;

comment on function run_due_morning_briefs() is
  'Generates today''s brief for every studio whose local clock has passed '
  'morning_brief_send_at minus the lead time. Idempotent per (studio, local '
  'date) through job_runs. Called by pg_cron every 15 minutes.';

-- -----------------------------------------------------------------------------
-- Schedule it
--
-- Guarded, the way migration 013 is: pg_cron is present on hosted Supabase and
-- on this local stack, but a bare Postgres without it should not fail the whole
-- migration chain — and a scheduler that is missing is a visible NOTICE, not a
-- silent nothing.
-- -----------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron is not available here; the Morning Brief will not '
                 'generate on its own. Schedule run_due_morning_briefs() '
                 'externally, or install pg_cron and re-run this migration.';
    return;
  end if;

  create extension if not exists pg_cron;

  -- Replayable: db reset builds a fresh database, but re-running against a
  -- live one must not leave two jobs racing each other.
  if exists (select 1 from cron.job where jobname = 'studiior-morning-brief') then
    perform cron.unschedule('studiior-morning-brief');
  end if;

  -- Every 15 minutes. morning_brief_send_at is per studio and studios span
  -- timezones, so the job has to wake more often than the thing it is waiting
  -- for; hourly would deliver some briefs up to 59 minutes late.
  perform cron.schedule(
    'studiior-morning-brief',
    '*/15 * * * *',
    $job$select run_due_morning_briefs()$job$);
end $$;
