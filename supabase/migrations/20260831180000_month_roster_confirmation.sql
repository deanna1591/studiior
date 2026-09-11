-- =============================================================================
-- Migration 113 — Decision 25, part two: instructors confirm the month, and
-- the studio can see who has not
-- =============================================================================
-- Publishing (112) sends each instructor their own roster. This is what they
-- do with it: confirm the whole month in one action, or flag the classes they
-- cannot do — which is request_cover() from migration 054, not a second flow.
-- Staff see who has confirmed and who has not; a roster still unconfirmed a
-- week before the month starts is a Morning Brief item; and a month that is
-- not published while it is about to start — or has started, with members
-- unable to book anything — is the brief's loudest line and an action-centre
-- row, because that state is an outage a studio may not notice from inside.
--
-- BOTH CONFIRMATIONS STAY. The month is the agreement; the week (067) is the
-- check-in. Confirming the month does not confirm any week — that would be
-- one press replacing eleven, which is not what a weekly check-in is for.
--
-- OPTIONAL, STILL. Every reader here answers "nothing to do" for a studio with
-- the switch off: no roster rows exist, the brief candidates find no
-- publication rows and the switch gate is checked first anyway.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. What an instructor sees for a month
-- -----------------------------------------------------------------------------
-- Their classes in the month — published only, through the same predicate as
-- everything else — with whether they were sent a roster, whether they have
-- confirmed, and how many classes have arrived SINCE the roster was sent, so
-- the screen can say "3 added since your roster" rather than silently showing
-- a longer list than the email did.
create function my_month_roster(p_instructor_id uuid, p_month date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_studio uuid; v_tz text; v_month date; v_from timestamptz; v_to timestamptz;
  rc roster_confirmations%rowtype; v_rows jsonb; v_added int;
begin
  select i.studio_id, s.timezone into v_studio, v_tz
    from instructors i join studios s on s.id = i.studio_id where i.id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  if not (coalesce(is_this_instructor(p_instructor_id), false) or coalesce(is_manager_up(v_studio), false)) then
    raise exception 'that is somebody else''s month' using errcode = 'PT403';
  end if;

  v_month := date_trunc('month', p_month)::date;
  v_from  := (v_month::timestamp) at time zone v_tz;
  v_to    := ((v_month + interval '1 month')::timestamp) at time zone v_tz;

  select * into rc from roster_confirmations
   where studio_id = v_studio and instructor_id = p_instructor_id and month = v_month;

  -- A draft month is not theirs to see; the answer is the state, not the list.
  if not month_published(v_studio, v_from) then
    return jsonb_build_object(
      'month', v_month, 'label', to_char(v_month, 'FMMonth YYYY'),
      'state', 'draft', 'classes', '[]'::jsonb, 'count', 0,
      'notified_at', null, 'confirmed_at', null, 'added_since', 0,
      'empty_hint', 'The studio has not published ' || to_char(v_month, 'FMMonth') || ' yet. Your classes appear here, and you get an email, as soon as it does.');
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.starts_at), '[]'::jsonb),
         coalesce(count(*) filter (where x.added_after_roster), 0)::int
    into v_rows, v_added
    from (
      select o.id as occurrence_id, o.name, o.starts_at,
             (o.starts_at at time zone v_tz)::date as local_date,
             to_char(o.starts_at at time zone v_tz, 'HH24:MI') as local_start,
             to_char(o.ends_at   at time zone v_tz, 'HH24:MI') as local_end,
             r.name as room_name, o.capacity, o.booked_count,
             o.status::text as status,
             (select c.status::text from cover_requests c
               where c.occurrence_id = o.id and c.status in ('pending','approved')
               order by c.requested_at desc limit 1) as cover_status,
             -- Created after the roster email went, so the email did not list
             -- it. created_at rather than updated_at: a booking touches
             -- updated_at, and every class somebody booked after the email
             -- would otherwise read as new. A class MOVED onto this person is
             -- emailed on its own (112) and is not counted here.
             rc.notified_at is not null and o.created_at > rc.notified_at as added_after_roster
        from class_occurrences o
        left join rooms r on r.id = o.room_id
       where o.studio_id = v_studio and o.instructor_id = p_instructor_id
         and o.status = 'scheduled'
         and o.starts_at >= v_from and o.starts_at < v_to) x;

  return jsonb_build_object(
    'month', v_month, 'label', to_char(v_month, 'FMMonth YYYY'),
    'state', case when jsonb_array_length(v_rows) = 0 then 'empty'
                  when rc.confirmed_at is not null then 'confirmed'
                  else 'unconfirmed' end,
    'classes', v_rows, 'count', jsonb_array_length(v_rows),
    'notified_at', rc.notified_at, 'confirmed_at', rc.confirmed_at,
    'added_since', v_added,
    'empty_hint', 'Nothing of yours in ' || to_char(v_month, 'FMMonth') || '. Classes you are given after publication appear here and you are emailed about each one.');
end $$;

-- -----------------------------------------------------------------------------
-- 2. Confirming it
-- -----------------------------------------------------------------------------
-- One action for the whole month. Classes with a cover request pending are not
-- an obstacle: the request IS the flag, and confirming the rest is exactly
-- what "confirm, or flag the ones you cannot do" means. The studio may record
-- it on the instructor's behalf, as confirm_week() allows — a yes at the desk
-- should not need the app opened first.
create function confirm_month_roster(p_instructor_id uuid, p_month date)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_studio uuid; v_tz text; v_month date; v_n int; v_cover int; rc roster_confirmations%rowtype;
begin
  select i.studio_id, s.timezone into v_studio, v_tz
    from instructors i join studios s on s.id = i.studio_id where i.id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  if not (coalesce(is_this_instructor(p_instructor_id), false) or coalesce(is_manager_up(v_studio), false)) then
    raise exception 'only the instructor or the studio confirms a roster' using errcode = 'PT403';
  end if;

  v_month := date_trunc('month', p_month)::date;
  if not month_published(v_studio, (v_month::timestamp) at time zone v_tz) then
    raise exception '% is not published, so there is nothing to confirm yet',
      to_char(v_month, 'FMMonth') using errcode = 'PT409';
  end if;

  select count(*)::int,
         count(*) filter (where exists (select 1 from cover_requests c
                                          where c.occurrence_id = o.id and c.status in ('pending','approved')))::int
    into v_n, v_cover
    from class_occurrences o
   where o.studio_id = v_studio and o.instructor_id = p_instructor_id and o.status = 'scheduled'
     and o.starts_at >= (v_month::timestamp) at time zone v_tz
     and o.starts_at <  ((v_month + interval '1 month')::timestamp) at time zone v_tz;
  if v_n = 0 then
    raise exception 'nothing of yours in % to confirm', to_char(v_month, 'FMMonth') using errcode = 'PT409';
  end if;

  -- A row may not exist: somebody given their first class in the month AFTER
  -- it was published was told per class and never sent a roster. They can
  -- still confirm, and the row records that they did.
  insert into roster_confirmations (studio_id, instructor_id, month, classes_at_notify, confirmed_at)
  values (v_studio, p_instructor_id, v_month, v_n, now())
  on conflict (studio_id, instructor_id, month) do update
     set confirmed_at = coalesce(roster_confirmations.confirmed_at, excluded.confirmed_at)
  returning * into rc;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (v_studio, auth.uid(), 'roster.confirmed', 'instructors', p_instructor_id,
          jsonb_build_object('month', v_month, 'classes', v_n, 'cover_requested', v_cover));

  return jsonb_build_object('ok', true, 'month', v_month, 'confirmed_at', rc.confirmed_at,
                            'classes', v_n, 'cover_requested', v_cover);
end $$;

-- -----------------------------------------------------------------------------
-- 3. The brief's thresholds — rows a studio can move, like every other one
-- -----------------------------------------------------------------------------
insert into insight_config (studio_id, key, value, note) values
  (null, 'roster_unconfirmed_days', 7,
   'Decision 25. A published month starting within this many days whose roster an instructor has not confirmed is a brief item.'),
  (null, 'month_unpublished_days', 7,
   'Decision 25. A month with classes on it that is not published and starts within this many days — or has already started — is the brief''s loudest line: members cannot book it.')
on conflict (key) where studio_id is null do nothing;

-- -----------------------------------------------------------------------------
-- 4. The brief learns two types — generate_morning_brief() from 20260830840000
-- -----------------------------------------------------------------------------
-- Rebuilt from the newest FILE that defines it, with two candidate blocks
-- added ahead of the dedupe. Nothing else in it changes.
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

  -- ---- studio_closed_with_bookings (migration 074) --------------------------
  -- Closing the studio cancels what is already on the calendar, so a class
  -- inside a closure is one that arrived AFTER it: typed in by hand, or dragged
  -- there. Nobody meant that, and the members booked on it think they have a
  -- class. Ranked beside an unstaffed class because it is the same shape — a
  -- room of people expecting a session that is not going to happen.
  insert into _cand
  select 'studio_closed_with_bookings', 'warning', 1,
         'Classes on a day the studio is shut',
         -- The reason is free text a studio wrote, so it is QUOTED as its own
         -- clause rather than folded into a sentence: "closed for Closed for
         -- Christmas" is what folding it produced.
         format('%s on %s, and you are shut that day — "%s". %s still booked.',
                case when v_n = 1 then '1 class' else v_n || ' classes' end,
                to_char(v_when, 'FMDD FMMonth'), v_why,
                case when v_bk = 1 then '1 member is' else v_bk || ' members are' end),
         'They are expecting a class. The closure did not remove these because '
         'they were put on the calendar after it.',
         'Cancel them, or lift the closure for that day.',
         'open_schedule',
         jsonb_build_object('href', '/schedule?d=' || v_when || '&view=day',
                            'date', v_when),
         'studio', p_studio_id,
         0
    from (
      select (o.starts_at at time zone v_tz)::date as v_when,
             min(cl.reason) as v_why,
             count(*)::int as v_n,
             coalesce(sum((select count(*) from bookings b
                            where b.occurrence_id = o.id
                              and b.status in ('booked','waitlisted','pending_payment'))), 0)::int as v_bk
        from class_occurrences o
        join studio_closures cl
          on cl.studio_id = o.studio_id
         and (o.starts_at at time zone v_tz)::date between cl.starts_on and cl.ends_on
         and (cl.starts_at_time is null
              or ((o.starts_at at time zone v_tz)::time < cl.ends_at_time
                  and (o.ends_at at time zone v_tz)::time > cl.starts_at_time))
       where o.studio_id = p_studio_id
         and o.status = 'scheduled'
         and o.starts_at > now()
       group by 1
       having coalesce(sum((select count(*) from bookings b
                             where b.occurrence_id = o.id
                               and b.status in ('booked','waitlisted','pending_payment'))), 0) > 0
    ) z;


  -- ---- month_unpublished (Decision 25) --------------------------------------
  -- The loudest thing this brief can say. A studio that publishes its months
  -- and has not published the one about to start — or the one that HAS
  -- started — has a timetable members cannot see and cannot book, and nothing
  -- inside the staff app looks broken: the calendar is full and only the
  -- member app is empty. Ranked 0, above an unstaffed class, because it is
  -- every class at once. One candidate per studio, naming the earliest month
  -- in that state. Absent entirely for a studio with the switch off.
  insert into _cand
  select 'month_unpublished', 'urgent', 0,
         v_label || case when v_started then ' has started and is not published'
                         else ' starts in ' || v_days || case when v_days = 1 then ' day' else ' days' end
                              || ' and is not published' end,
         format('%s class%s on it that members cannot see or book.',
                v_n, case when v_n = 1 then ' is' else 'es are' end)
         || case when v_started then ' Nothing this month is bookable until it is published.' else '' end,
         'Members can only book as far as the published month. Until this one is out, the timetable looks empty to them.',
         'Publish it — with holes if you must; they become open shifts.',
         'open_publication',
         jsonb_build_object('href', '/publish?m=' || to_char(v_month, 'YYYY-MM'), 'month', v_month),
         'studio', p_studio_id,
         0
    from (
      select m.month as v_month, to_char(m.month, 'FMMonth') as v_label,
             m.month <= v_date as v_started,
             greatest(0, m.month - v_date) as v_days,
             m.n as v_n
        from (
          select date_trunc('month', o.starts_at at time zone v_tz)::date as month, count(*)::int as n
            from class_occurrences o
           where o.studio_id = p_studio_id and o.status = 'scheduled'
             and o.starts_at >= now()
           group by 1) m
       where publication_enabled(p_studio_id)
         and m.month >= date_trunc('month', v_date)::date
         and m.month <= v_date + insight_threshold(p_studio_id, 'month_unpublished_days')::int
         and not exists (select 1 from schedule_publications sp
                          where sp.studio_id = p_studio_id and sp.month = m.month)
       order by m.month
       limit 1
    ) z;

  -- ---- month_roster_unconfirmed (Decision 25) -------------------------------
  -- A published month starting within the window whose roster an instructor
  -- was SENT and has not confirmed. One per instructor, so the button opens
  -- the month with that person in the list. Somebody who could not be sent it
  -- (no login) is not chased here — the publish result already named them and
  -- a brief item asking somebody to confirm an email they never got would be
  -- the insight-without-a-button mistake.
  insert into _cand
  select 'month_roster_unconfirmed', 'warning', 2,
         i.display_name || ' has not confirmed ' || to_char(rc.month, 'FMMonth'),
         format('Sent their roster %s — %s class%s — and %s starts in %s day%s.',
                to_char(rc.notified_at at time zone v_tz, 'FMDD FMMonth'),
                rc.classes_at_notify, case when rc.classes_at_notify = 1 then '' else 'es' end,
                to_char(rc.month, 'FMMonth'),
                greatest(0, rc.month - v_date), case when greatest(0, rc.month - v_date) = 1 then '' else 's' end),
         'An unconfirmed month is a month you are assuming. The week-by-week check-in only starts once it does.',
         'Ask them, or confirm it for them if they have said yes some other way.',
         'open_publication',
         jsonb_build_object('href', '/publish?m=' || to_char(rc.month, 'YYYY-MM'),
                            'month', rc.month, 'instructor_id', rc.instructor_id),
         'instructor', rc.instructor_id,
         0
    from roster_confirmations rc
    join instructors i on i.id = rc.instructor_id
   where rc.studio_id = p_studio_id
     and rc.notified_at is not null
     and rc.confirmed_at is null
     and i.status = 'active'
     and rc.month > v_date
     and rc.month <= v_date + insight_threshold(p_studio_id, 'roster_unconfirmed_days')::int
     and exists (select 1 from schedule_publications sp
                  where sp.studio_id = p_studio_id and sp.month = rc.month);

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
end $function$;

-- -----------------------------------------------------------------------------
-- 5. The sentence agrees with the list — brief_summary() from 20260830650000
-- -----------------------------------------------------------------------------
-- Three types counted that were not: the two above, and migration 074's
-- studio_closed_with_bookings, which had never been added here — so a brief
-- whose only item was a class on a closed day opened with "Nothing needs you
-- this morning" above it.
CREATE OR REPLACE FUNCTION public.brief_summary(p_studio_id uuid, p_date date)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  n_drift int; n_pay int; n_stall int; n_under int; n_over int; n_mile int;
  n_unstaffed int; n_cover int; n_short int;
  -- 074's closure type had never been counted here, so a brief whose only item
  -- was one read "Nothing needs you this morning" above it. Counted with the
  -- two Decision 25 types this migration adds.
  n_closed int; n_unpub int; n_roster int;
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
         count(*) filter (where type = 'commitment_shortfall'),
         count(*) filter (where type = 'studio_closed_with_bookings'),
         count(*) filter (where type = 'month_unpublished'),
         count(*) filter (where type = 'month_roster_unconfirmed')
    into n_drift, n_pay, n_stall, n_under, n_over, n_mile, n_unstaffed,
         n_cover, n_short, n_closed, n_unpub, n_roster
    from ai_insights where studio_id = p_studio_id and for_date = p_date;

  if n_drift + n_pay + n_stall + n_under + n_over + n_mile + n_unstaffed
     + n_cover + n_short + n_closed + n_unpub + n_roster = 0 then
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
  -- Decision 25's unpublished month leads everything: it is every class at
  -- once, and the list ranks it 0. Named, and not lowercased — a month is a
  -- proper noun.
  if n_unpub > 0 then
    select i.title into detail from ai_insights i
     where i.studio_id = p_studio_id and i.for_date = p_date
       and i.type = 'month_unpublished' limit 1;
    parts := parts || detail;
  end if;
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
  if n_closed > 0 then
    parts := parts || format('%s class%s on a day you are shut',
      say_count(n_closed), case when n_closed = 1 then ' is' else 'es are' end);
  end if;
  if n_roster > 0 then
    parts := parts || format('%s instructor%s not confirmed next month''s roster',
      say_count(n_roster), case when n_roster = 1 then ' has' else 's have' end);
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

-- -----------------------------------------------------------------------------
-- 6. The action centre — dashboard_tasks() from 20260831010000
-- -----------------------------------------------------------------------------
-- Two derived rows, in the shape of the eight already there. No table.
create or replace function dashboard_tasks(p_studio_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tz text; v_today date; v_now timestamptz; v_soon timestamptz;
  v_tasks jsonb := '[]'::jsonb;
  n int; v_unconf jsonb; v_cycle jsonb; r record; v_win int;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'the action centre is for owners and managers'
      using errcode = 'PT403';
  end if;
  select s.timezone into v_tz from studios s where s.id = p_studio_id;
  if v_tz is null then raise exception 'no such studio' using errcode = 'PT404'; end if;

  v_today := studio_today(p_studio_id);
  select day_start into v_now  from studio_day_bounds(p_studio_id, v_today);
  select day_start into v_soon from studio_day_bounds(p_studio_id, v_today + 7);

  -- 1. A class with people booked and nobody teaching it. Ranked first for
  --    migration 049's reason: a declined card can wait until Thursday, a
  --    7am class with eight people in it cannot.
  select count(*) into n from class_occurrences o
   where o.studio_id = p_studio_id and o.status = 'scheduled'
     and o.staffing = 'open' and o.booked_count > 0
     and o.starts_at >= now() and o.starts_at < v_soon;
  if n > 0 then
    v_tasks := v_tasks || jsonb_build_array(jsonb_build_object(
      'key','unstaffed_booked','urgency','urgent','count',n,
      'title', n || case when n = 1 then ' class has people booked and nobody teaching it'
                         else ' classes have people booked and nobody teaching them' end,
      'detail','In the next seven days.',
      'href','/shifts','action','Find cover'));
  end if;

  -- 2. Cover requests nobody has answered. Decision 18: staff always approve,
  --    so an unanswered request is the studio's, not the instructor's.
  select count(*) into n from cover_requests c
   where c.studio_id = p_studio_id and c.status = 'pending';
  if n > 0 then
    v_tasks := v_tasks || jsonb_build_array(jsonb_build_object(
      'key','cover_pending',
      'urgency', case when exists (select 1 from cover_requests c2
                                    where c2.studio_id = p_studio_id
                                      and c2.status = 'pending' and c2.escalated_at is not null)
                      then 'urgent' else 'soon' end,
      'count',n,
      'title', n || (case when n = 1 then ' instructor has' else ' instructors have' end)
               || ' asked for cover',
      'detail','Nobody has answered yet.',
      'href','/shifts/cover','action','Answer'));
  end if;

  -- 3. Instructors applying for open shifts. Decision 17 — the shift stays
  --    open until somebody approves, so an unanswered application is a class
  --    still unstaffed with a volunteer already waiting.
  select count(*) into n from shift_applications a
   where a.studio_id = p_studio_id and a.status = 'pending';
  if n > 0 then
    v_tasks := v_tasks || jsonb_build_array(jsonb_build_object(
      'key','applications_pending','urgency','soon','count',n,
      'title', n || (case when n = 1 then ' instructor has' else ' instructors have' end)
               || ' applied for an open class',
      'detail','Approving one declines the rest for that class.',
      'href','/shifts','action','Review'));
  end if;

  -- 4. Availability months waiting to be approved. Until somebody does, the
  --    submitted pattern narrows nothing (migration 066).
  select count(*) into n from availability_submissions s
   where s.studio_id = p_studio_id and s.status = 'submitted';
  if n > 0 then
    v_tasks := v_tasks || jsonb_build_array(jsonb_build_object(
      'key','availability_to_review','urgency','soon','count',n,
      'title', n || (case when n = 1 then ' availability month is' else ' availability months are' end)
               || ' waiting on you',
      'detail','A submitted month does nothing until it is approved.',
      'href','/availability','action','Review'));
  end if;

  -- 5. This week's unconfirmed classes, composed by unconfirmed_summary() so
  --    the escalation email, /availability and this line cannot phrase the
  --    same fact three slightly different ways.
  v_unconf := unconfirmed_summary(p_studio_id);
  if coalesce((v_unconf ->> 'classes')::int, 0) > 0 then
    v_tasks := v_tasks || jsonb_build_array(jsonb_build_object(
      'key','week_unconfirmed','urgency','soon',
      'count',(v_unconf ->> 'classes')::int,
      'title', v_unconf ->> 'line',
      'detail','They have been asked. Nothing is released.',
      'href','/availability','action','See who'));
  end if;

  -- 6. Money that failed. Decision 4's grace period is running while this sits.
  select count(*) into n from payments p
   where p.studio_id = p_studio_id and p.status = 'failed'
     and p.created_at >= now() - interval '30 days';
  if n > 0 then
    v_tasks := v_tasks || jsonb_build_array(jsonb_build_object(
      'key','payments_failed','urgency','urgent','count',n,
      'title', n || (case when n = 1 then ' payment has' else ' payments have' end) || ' failed',
      'detail','In the last thirty days. They cannot book while it stands.',
      'href','/members?filter=payment_failed','action','See who'));
  end if;

  -- 7. Members who have never been invited to the app. Migration 073 made
  --    this group knowable for the first time; before it, nobody could tell
  --    "not asked" from "asked and ignored".
  select count(*) into n from members m
   where m.studio_id = p_studio_id and m.status = 'active' and m.user_id is null
     and coalesce(m.email, '') <> ''
     and not exists (select 1 from member_invites i where i.member_id = m.id);
  if n > 0 then
    v_tasks := v_tasks || jsonb_build_array(jsonb_build_object(
      'key','never_invited','urgency','whenever','count',n,
      'title', n || (case when n = 1 then ' member has' else ' members have' end)
               || ' never been invited to the app',
      'detail','They cannot book for themselves until they are.',
      'href','/members','action','Invite them'));
  end if;

  -- 8. Setup, while it is unfinished. It leaves this list the moment it is
  --    done — a permanent link to a one-time job is clutter every day after
  --    the first, which is why the rail already drops it.
  -- studio_setup_state() returns an OBJECT keyed by item, not an array under
  -- 'items'. Reading it the other way was a silent no-op — `-> 'items'` is
  -- null, jsonb_array_elements(null) yields no rows and raises nothing, so the
  -- setup task never appeared and nothing said why. Found by opening the
  -- screen as a studio whose setup was plainly unfinished.
  select count(*) into n
    from jsonb_each(studio_setup_state(p_studio_id)) as e(key, item)
   where (item ->> 'done')::boolean is not true
     and (item ->> 'optional')::boolean is not true
     and (item ->> 'dismissed')::boolean is not true;
  if n > 0 then
    v_tasks := v_tasks || jsonb_build_array(jsonb_build_object(
      'key','setup_incomplete','urgency','whenever','count',n,
      'title', n || (case when n = 1 then ' setup step is' else ' setup steps are' end) || ' left',
      'detail','Members cannot book until the essentials are in.',
      'href','/setup','action','Finish setup'));
  end if;

  -- 9. Decision 25: a month that is not published and is about to start, or
  --    has started. Members cannot see or book it, and nothing in this app
  --    looks wrong. Absent entirely for a studio with the switch off. Within
  --    fourteen days — or the brief's own window, whichever is wider — it is
  --    worth a row; within the brief's window, or once started, it is urgent.
  if publication_enabled(p_studio_id) then
    v_win := greatest(14, insight_threshold(p_studio_id, 'month_unpublished_days')::int);
    for r in
      select m.month, m.n
        from (
          select date_trunc('month', o.starts_at at time zone v_tz)::date as month, count(*)::int as n
            from class_occurrences o
           where o.studio_id = p_studio_id and o.status = 'scheduled' and o.starts_at >= now()
           group by 1) m
       where m.month >= date_trunc('month', v_today)::date
         and m.month <= v_today + v_win
         and not exists (select 1 from schedule_publications sp
                          where sp.studio_id = p_studio_id and sp.month = m.month)
       order by m.month
    loop
      v_tasks := v_tasks || jsonb_build_array(jsonb_build_object(
        'key','month_unpublished',
        'urgency', case when r.month <= v_today + insight_threshold(p_studio_id, 'month_unpublished_days')::int
                        then 'urgent' else 'soon' end,
        'count', r.n,
        'title', to_char(r.month, 'FMMonth') ||
                 case when r.month <= v_today then ' has started and is not published'
                      else ' is not published' end,
        'detail', r.n || (case when r.n = 1 then ' class members' else ' classes members' end)
                  || ' cannot see or book.',
        'href','/publish?m=' || to_char(r.month, 'YYYY-MM'),'action','Publish it'));
    end loop;

    -- 10. Rosters sent and not confirmed, for a month within a fortnight (or
    --     the brief's window).
    v_win := greatest(14, insight_threshold(p_studio_id, 'roster_unconfirmed_days')::int);
    select count(*) into n
      from roster_confirmations rc
      join instructors i on i.id = rc.instructor_id and i.status = 'active'
     where rc.studio_id = p_studio_id
       and rc.notified_at is not null and rc.confirmed_at is null
       and rc.month > v_today and rc.month <= v_today + v_win;
    if n > 0 then
      v_tasks := v_tasks || jsonb_build_array(jsonb_build_object(
        'key','rosters_unconfirmed','urgency','soon','count',n,
        'title', n || (case when n = 1 then ' instructor has' else ' instructors have' end)
                 || ' not confirmed next month',
        'detail','They were sent their classes and have not said yes.',
        'href','/publish','action','See who'));
    end if;
  end if;

  -- Ranked at the end, not by the order they were gathered in. A failed
  -- payment is urgent and is collected sixth; a list whose order is an
  -- accident of how it was built is one an owner reads top to bottom and
  -- acts on in the wrong order.
  select coalesce(jsonb_agg(t order by
           case t ->> 'urgency' when 'urgent' then 0 when 'soon' then 1 else 2 end,
           (t ->> 'count')::int desc), '[]'::jsonb)
    into v_tasks from jsonb_array_elements(v_tasks) t;

  return jsonb_build_object(
    'state', case when jsonb_array_length(v_tasks) = 0 then 'clear' else 'ok' end,
    'tasks', v_tasks,
    'clear_hint', 'Nothing needs you. Cover requests, shift applications, availability to approve and failed payments all land here.',
    -- Named rather than half-built. A checkbox nothing else can see is the
    -- shape of bug this file exists to avoid.
    'not_built', 'Tasks you write yourself are not here — everything in this list is derived from something real, so it disappears when you deal with it.');
end $$;

-- -----------------------------------------------------------------------------
-- 7. Grants, and the assertion that they held
-- -----------------------------------------------------------------------------
revoke execute on function my_month_roster(uuid, date)       from public, anon;
revoke execute on function confirm_month_roster(uuid, date)  from public, anon;
grant  execute on function my_month_roster(uuid, date)       to authenticated, service_role;
grant  execute on function confirm_month_roster(uuid, date)  to authenticated, service_role;

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure::text as sig,
           has_function_privilege('anon', p.oid, 'execute') as anon,
           has_function_privilege('authenticated', p.oid, 'execute') as authed
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('my_month_roster', 'confirm_month_roster',
                         'generate_morning_brief', 'brief_summary', 'dashboard_tasks')
  loop
    if r.anon then raise exception 'migration 113: % is reachable by anon', r.sig; end if;
    if not r.authed then raise exception 'migration 113: % lost the grant it needs', r.sig; end if;
  end loop;
end $$;
