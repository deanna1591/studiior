-- =============================================================================
-- Migration 055: Decision 18, part three — what the brief has to notice
-- =============================================================================
-- Two types §11 has no room for, and both were the point of building the tables
-- underneath them:
--
--   cover_unanswered     rank 0 inside the escalation window — ABOVE
--                        unstaffed_class, which Decision 17 already put above a
--                        declined card. Approval being required is exactly what
--                        makes an unanswered request an emergency.
--   commitment_shortfall the whole reason instructor_commitments exists. A
--                        three-month agreement running two classes a week short
--                        is a conversation for week three, not month three.
--
-- Both functions replaced from their LIVE definitions, which are already ahead
-- of the files that created them — 023's temp-table fix and 049's insight are
-- in the live body and in no single file.
-- =============================================================================

insert into insight_config (studio_id, key, value, note) values
  (null, 'commitment_weeks', 2,
   'Decision 18 commitment_shortfall: consecutive complete weeks under the '
   'agreed minimum before the brief raises it. One week under is a holiday.')
on conflict do nothing;

CREATE OR REPLACE FUNCTION public.generate_morning_brief(p_studio_id uuid, p_for_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  -- ---- unstaffed_class (Decision 17) ----------------------------------------
  -- §11 lists nine insight types and none of them covers a class with nobody
  -- teaching it. Ranked 1 and 'urgent', above a failed card: a declined card
  -- can be sorted out on Thursday; a 7am class tomorrow with people booked and
  -- no instructor cannot.
  insert into _cand
  select 'unstaffed_class', 'urgent', 1,
         o.name || ' on ' || to_char(o.starts_at at time zone v_tz, 'FMDay') ||
           ' has nobody teaching it',
         case when o.booked_count > 0
              then format('%s member%s booked, and the class is unstaffed.',
                          o.booked_count, case when o.booked_count = 1 then '' else 's' end)
              else 'Published with no instructor, and nobody has picked it up.' end,
         case when o.booked_count > 0
              then 'Members are expecting a class that currently has nobody to run it.'
              else 'It is on the timetable with nobody assigned.' end,
         case when exists (select 1 from shift_applications sa
                            where sa.occurrence_id = o.id and sa.status = 'pending')
              then 'Somebody has applied. Approve them.'
              else 'Assign someone, or leave it open for an instructor to take.' end,
         'open_shift',
         jsonb_build_object('occurrence_id', o.id, 'href', '/schedule?occurrence=' || o.id),
         'occurrence', o.id,
         0
    from class_occurrences o
   where o.studio_id = p_studio_id
     and o.status = 'scheduled'
     and o.staffing <> 'assigned'
     and o.starts_at > now()
     -- The studio's own staffing deadline, in hours, rather than a window of
     -- days invented here. Past it with nobody assigned is precisely the state
     -- the brief exists to surface: a class members can book that nobody has
     -- agreed to teach.
     and o.starts_at < now() + make_interval(hours => coalesce(
           (select st.unstaffed_deadline_hours from studio_settings st
             where st.studio_id = p_studio_id), 48));

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

  -- ---- cover_unanswered (Decision 18) ---------------------------------------
  -- RANK 0, above unstaffed_class, which Decision 17 put above a declined card.
  -- An unanswered cover request inside the escalation window is the same
  -- emergency as a class with nobody teaching it, arriving earlier and still
  -- fixable — and it is only an emergency BECAUSE approval is required. Outside
  -- the window it is rank 1: still urgent, not yet the loudest thing.
  insert into _cand
  select 'cover_unanswered',
         'urgent',
         case when cr_urgent then 0 else 1 end,
         v_who || ' needs cover for ' || v_cls ||
           case when cr_urgent then ' in ' || v_left else '' end,
         case when v_booked > 0
              then format('Asked %s and nobody has answered. %s member%s booked.',
                          v_ago, v_booked,
                          case when v_booked = 1 then ' is' else 's are' end)
              else format('Asked %s and nobody has answered.', v_ago) end,
         case when cr_urgent
              then 'They are still on the class until somebody decides, and the class is about to run.'
              else 'They stay on the class until this is answered, so nothing is broken yet — but nothing is arranged either.' end,
         'Assign someone, or open it up for another instructor.',
         'cover_request',
         jsonb_build_object('request_id', cr_id, 'occurrence_id', cr_occ,
                            'href', '/shifts/cover?request=' || cr_id),
         'occurrence', cr_occ,
         0
    from (
      select cr.id as cr_id, cr.occurrence_id as cr_occ,
             i.display_name as v_who, o.name as v_cls, o.booked_count as v_booked,
             o.starts_at <= now() + make_interval(
               hours => coalesce(st.cover_escalation_hours, 4)) as cr_urgent,
             case when extract(epoch from o.starts_at - now()) < 3600
                  then round(extract(epoch from o.starts_at - now()) / 60) || ' minutes'
                  else round(extract(epoch from o.starts_at - now()) / 3600) || ' hours' end as v_left,
             case when now() - cr.requested_at < interval '1 hour'
                  then round(extract(epoch from now() - cr.requested_at) / 60) || ' minutes ago'
                  when now() - cr.requested_at < interval '48 hours'
                  then round(extract(epoch from now() - cr.requested_at) / 3600) || ' hours ago'
                  else round(extract(epoch from now() - cr.requested_at) / 86400) || ' days ago' end as v_ago
        from cover_requests cr
        join class_occurrences o on o.id = cr.occurrence_id
        join instructors i       on i.id = cr.instructor_id
        left join studio_settings st on st.studio_id = cr.studio_id
       where cr.studio_id = p_studio_id
         and cr.status = 'pending'
         and o.status = 'scheduled'
         and o.starts_at > now()
    ) c;

  -- ---- commitment_shortfall (Decision 18) -----------------------------------
  -- The entire reason instructor_commitments exists. A three-month agreement
  -- that quietly ran at six classes a week instead of nine is a conversation
  -- that has to happen in week three; found in month three it is a grievance.
  -- Consecutive weeks, not a total: one week under is a holiday and everybody
  -- at the studio already knows about it.
  insert into _cand
  select 'commitment_shortfall', 'warning', 3,
         v_name || ' is under what was agreed',
         format('%s week%s in a row below %s classes — %s.',
                v_weeks, case when v_weeks = 1 then '' else 's' end,
                v_min, v_detail),
         'They committed to a weekly minimum and the weeks are going by. This is a conversation, not a problem yet.',
         'Have a word before it becomes three months of it.',
         'open_instructor',
         jsonb_build_object('instructor_id', v_iid,
                            'href', '/instructors/' || v_iid),
         'instructor', v_iid,
         0
    from (
      select c.instructor_id as v_iid, i.display_name as v_name,
             c.min_per_week as v_min,
             (select count(*) from unnest(w.loads) l where l < c.min_per_week)::int as v_weeks,
             array_to_string(w.loads, ', ') as v_detail
        from instructor_commitments c
        join instructors i on i.id = c.instructor_id
        join lateral (
          -- The most recent N COMPLETE weeks, newest last.
          select array_agg(classes order by week_start) as loads
            from (select * from instructor_weekly_load(c.instructor_id,
                    insight_threshold(p_studio_id,'commitment_weeks')::int)
                   order by week_start desc
                   limit insight_threshold(p_studio_id,'commitment_weeks')::int) z
        ) w on true
       where c.studio_id = p_studio_id
         and c.status = 'active'
         and c.min_per_week > 0
         and c.starts_on <= v_date
         and (c.ends_on is null or c.ends_on >= v_date)
         -- Every one of the last N weeks under. `all` rather than a count, so a
         -- good week resets it — which is what "persistently" has to mean.
         and w.loads is not null
         and array_length(w.loads, 1) >= insight_threshold(p_studio_id,'commitment_weeks')::int
         and not exists (select 1 from unnest(w.loads) l where l >= c.min_per_week)
    ) s;

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
end $function$
;

CREATE OR REPLACE FUNCTION public.brief_summary(p_studio_id uuid, p_date date)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  n_drift int; n_pay int; n_stall int; n_under int; n_over int; n_mile int;
  n_unstaffed int; n_cover int; n_short int;
  detail  text;
  parts   text[] := '{}';
  out     text;
begin
  select count(*) filter (where type = 'retention_risk'),
         count(*) filter (where type = 'payment_failed'),
         count(*) filter (where type = 'new_member_stalled'),
         count(*) filter (where type = 'class_underfilled'),
         count(*) filter (where type = 'class_overfilled'),
         count(*) filter (where type = 'milestone_upcoming'),
         count(*) filter (where type = 'unstaffed_class'),
         count(*) filter (where type = 'cover_unanswered'),
         count(*) filter (where type = 'commitment_shortfall')
    into n_drift, n_pay, n_stall, n_under, n_over, n_mile, n_unstaffed,
         n_cover, n_short
    from ai_insights where studio_id = p_studio_id and for_date = p_date;

  if n_drift + n_pay + n_stall + n_under + n_over + n_mile + n_unstaffed
     + n_cover + n_short = 0 then
    return 'Nothing needs you this morning. Everyone who was coming is still '
           'coming, every card went through, and no class is unusually empty.';
  end if;

  -- Ordered by what it costs to ignore, so the sentence and the list below it
  -- lead with the same thing.
  -- FIRST, ahead of a declined card. The list below is ranked that way and the
  -- sentence has to agree with it, or the loudest thing in the brief is the one
  -- thing the opening line does not mention. A class is named rather than
  -- counted, for the same reason class_underfilled is.
  -- BEFORE the unstaffed class, which is itself before a declined card. The
  -- list below is ranked that way and the sentence has to agree with it, or the
  -- loudest thing in the brief is the one thing the opening line does not
  -- mention. Named rather than counted, and NOT lowercased — a person's name
  -- and a class name are proper nouns and are not ours to restyle.
  if n_cover > 0 then
    select i.title into detail from ai_insights i
     where i.studio_id = p_studio_id and i.for_date = p_date
       and i.type = 'cover_unanswered'
     order by i.title limit 1;
    parts := parts || (detail
             || case when n_cover > 1
                     then format(' (and %s other%s)', say_count(n_cover - 1),
                                 case when n_cover = 2 then '' else 's' end)
                     else '' end);
  end if;
  if n_unstaffed > 0 then
    select i.title into detail from ai_insights i
     where i.studio_id = p_studio_id and i.for_date = p_date
       and i.type = 'unstaffed_class'
     order by i.title limit 1;
    -- Parenthesised. `text[] || text || text` appends TWO elements, so without
    -- these brackets a single unstaffed class produced an empty part and the
    -- sentence read "...has nobody teaching it; ; one card has been declined".
    -- NOT lowercased, unlike the branch below. This part is always first in the
    -- sentence, and lowercasing turned "Reformer Flow on Wednesday" into
    -- "Reformer flow on wednesday" — a studio's class name and a weekday are
    -- proper nouns, and they are not ours to restyle.
    parts := parts || (detail
             || case when n_unstaffed > 1
                     then format(' (and %s other%s)', say_count(n_unstaffed - 1),
                                 case when n_unstaffed = 2 then '' else 's' end)
                     else '' end);
  end if;
  if n_pay > 0 then
    parts := parts || format('%s card%s been declined',
      say_count(n_pay), case when n_pay = 1 then ' has' else 's have' end);
  end if;
  if n_drift > 0 then
    parts := parts || format('%s member%s drifted',
      say_count(n_drift),
      case when n_drift = 1 then ' has' else 's have' end);
  end if;
  if n_short > 0 then
    parts := parts || format('%s instructor%s under what they agreed to teach',
      say_count(n_short), case when n_short = 1 then ' is' else 's are' end);
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
    -- Same fix as above. This branch has had the bug since migration 023 and
    -- only shows it when exactly one class is underfilled, which is why it has
    -- never been noticed: the fixture that exercises it has two.
    parts := parts || (lower(detail)
             || case when n_under > 1
                     then format(' (and %s other%s)', say_count(n_under - 1),
                                 case when n_under = 2 then '' else 's' end)
                     else '' end);
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
end $function$
;
