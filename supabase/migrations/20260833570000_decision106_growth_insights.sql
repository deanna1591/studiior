-- Decision 106: growth insights within the core budget.
--
-- creates: seed_instructor_core_budgets(uuid), set_instructor_core_budget(uuid, int),
--          growth_insights(uuid, date), growth_apply(uuid, text, text),
--          sweep_growth_insights(uuid, date), sweep_growth_insights_all(timestamptz)
-- re-issues: dashboard_facts(uuid, text, date, uuid)
--
-- Each instructor carries a budget, "Core classes per day" (1..3), seeded once
-- from the studio's actual pattern (the per-coach mode of core classes per day,
-- floored at 1), and editable by a manager on the profile. Every Monday at 7am
-- studio time a card on the dashboard and a page under Retention rank each
-- coach's slots by a score over the last 8 weeks weighted to the last 4, and
-- propose the top {budget} per weekday as core and the rest as flex. A slot
-- qualifies as core only if it reached the flex minimum in 3 of the last 4
-- weeks; fewer than 4 weeks shows "Collecting data" with no proposal. Nothing
-- is applied without a tap. A one-paragraph summary goes through the existing
-- ai_insights / dashboard_narratives machinery, gated on the studio's AI drafts
-- and the platform key, so the Decision 92 verifier still holds.
--
-- No new anon RPC. The anon surface stays EXACTLY FOURTEEN, plus the inbox table.

-- ===========================================================================
-- 1. The budget column.
-- ===========================================================================
alter table instructors
  add column if not exists core_classes_per_day int
  check (core_classes_per_day is null or core_classes_per_day between 1 and 3);

-- ===========================================================================
-- 2. The November seed (service only, audited). Only fills a null budget, so a
--    re-run is a no-op and a manager's edit is never overwritten. An occurrence
--    with no instructor is ignored (joined on instructor_id). The window is this
--    studio-local month plus the next, which captures the full recurring pattern
--    whatever day of the month this runs on.
-- ===========================================================================
create or replace function seed_instructor_core_budgets(p_studio_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_set int := 0; r record; v_tz text; v_from date; v_to date; v_mode int; v_budget int;
begin
  if not is_service_context() then
    raise exception 'budgets are seeded by the backend, not by a user' using errcode = 'PT403';
  end if;
  for r in
    select i.id as instructor_id, i.studio_id, s.timezone as tz
      from instructors i join studios s on s.id = i.studio_id
     where (p_studio_id is null or i.studio_id = p_studio_id)
       and i.status = 'active' and i.core_classes_per_day is null
  loop
    v_tz := r.tz;
    v_from := date_trunc('month', (now() at time zone v_tz))::date;
    v_to   := (date_trunc('month', (now() at time zone v_tz)) + interval '2 months')::date;
    -- Per teaching day, this coach's count of core (core or always) classes;
    -- then the most common value across days. mode() over no rows is NULL (the
    -- coach does not teach in the window) and we leave them unseeded; a mode of
    -- 0 (teaches, but all flex) floors to 1.
    select mode() within group (order by d.core_cnt) into v_mode
      from (
        select (o.starts_at at time zone v_tz)::date as day_d,
               count(*) filter (where g.tier in ('core','always')) as core_cnt
          from class_occurrences o
          cross join lateral occurrence_guarantee_run(o.id) g
         where o.studio_id = r.studio_id and o.instructor_id = r.instructor_id
           and o.status = 'scheduled'
           and (o.starts_at at time zone v_tz)::date >= v_from
           and (o.starts_at at time zone v_tz)::date <  v_to
         group by (o.starts_at at time zone v_tz)::date
      ) d;
    if v_mode is null then continue; end if;
    v_budget := greatest(least(v_mode, 3), 1);
    update instructors set core_classes_per_day = v_budget, updated_at = now()
     where id = r.instructor_id and core_classes_per_day is null;
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (r.studio_id, null, 'instructor.core_budget_seeded', 'instructors', r.instructor_id,
            jsonb_build_object('core_classes_per_day', v_budget, 'window_from', v_from, 'window_to', v_to));
    v_set := v_set + 1;
  end loop;
  return jsonb_build_object('seeded', v_set);
end $$;

-- ===========================================================================
-- 3. A manager sets the budget (also the "Raise to {n+1}" tap).
-- ===========================================================================
create or replace function set_instructor_core_budget(p_instructor_id uuid, p_n int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_studio uuid; v_old int;
begin
  select studio_id, core_classes_per_day into v_studio, v_old from instructors where id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(v_studio), false) then
    raise exception 'only owners and managers set a budget' using errcode = 'PT403';
  end if;
  if p_n is null or p_n < 1 or p_n > 3 then
    raise exception 'the budget is a number from 1 to 3' using errcode = 'PT422';
  end if;
  update instructors set core_classes_per_day = p_n, updated_at = now() where id = p_instructor_id;
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (v_studio, auth.uid(), 'instructor.core_budget_set', 'instructors', p_instructor_id,
          jsonb_build_object('core_classes_per_day', v_old),
          jsonb_build_object('core_classes_per_day', p_n));
  return jsonb_build_object('ok', true, 'core_classes_per_day', p_n);
end $$;

-- ===========================================================================
-- 4. growth_insights(studio, week) — service only.
--
--    The score, the clamp, the weighting, the 4-weeks rule and the qualifying
--    rule mirror lib/growth-score.mjs exactly (each piece labelled with the name
--    it carries there). Returns the coaches -> days -> slots tree, the wanted
--    slots, the members to nudge, and a deterministic summary (text + the
--    figures and the allowed numbers the optional Claude paragraph may name).
-- ===========================================================================
create or replace function growth_insights(p_studio_id uuid, p_week date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_tz text; v_flexmin int;
  v_coaches jsonb; v_wanted jsonb; v_nudge jsonb;
  v_n_core int; v_n_flex int; v_n_make_core int; v_n_make_flex int;
  v_n_wanted int; v_n_collecting int; v_n_nudge int; v_n_coaches int;
  v_summary_text text; v_figures jsonb; v_allowed jsonb;
begin
  if not is_service_context() then
    raise exception 'growth insights are produced by the backend, not by a user'
      using errcode = 'PT403';
  end if;
  select s.timezone into v_tz from studios s where s.id = p_studio_id;
  if v_tz is null then raise exception 'no such studio' using errcode = 'PT404'; end if;
  select coalesce(flex_min_bookings, 2) into v_flexmin from studio_settings where studio_id = p_studio_id;
  v_flexmin := coalesce(v_flexmin, 2);

  -- One class-tracker-safe run per transaction (the temp table pattern: drop at
  -- the top rather than relying on ON COMMIT, so a second call in one txn works).
  if to_regclass('pg_temp._gi_slots') is not null then drop table _gi_slots; end if;

  create temp table _gi_slots on commit drop as
  with
  coming as (
    select distinct on (o.series_id)
           o.series_id, o.id as occ_id, o.instructor_id, o.capacity,
           extract(isodow from o.starts_at at time zone v_tz)::int as dow,
           to_char(o.starts_at at time zone v_tz, 'HH24:MI') as slot_time,
           coalesce(o.name, ct.name) as class_name,
           (case when g.tier in ('core','always') then 'core' else 'flex' end) as cur_tier
      from class_occurrences o
      left join class_types ct on ct.id = o.class_type_id
      cross join lateral occurrence_guarantee_run(o.id) g
     where o.studio_id = p_studio_id and o.series_id is not null and o.instructor_id is not null
       and o.status = 'scheduled'
       and (o.starts_at at time zone v_tz)::date >= p_week
       and (o.starts_at at time zone v_tz)::date <  p_week + 7
     order by o.series_id, o.starts_at
  ),
  pastocc as (
    select x.*
      from (
        select o.series_id, o.id as occ_id, o.capacity,
               row_number() over (partition by o.series_id order by o.starts_at desc) as rn,
               (select count(*) from bookings b where b.occurrence_id = o.id and b.status in ('booked','attended','no_show')) as booked,
               (select count(*) from bookings b where b.occurrence_id = o.id and b.status = 'attended') as attended,
               (select count(*) from bookings b where b.occurrence_id = o.id and b.status = 'waitlisted') as waitlist,
               (select count(*) from bookings b where b.occurrence_id = o.id and b.status = 'no_show') as no_show,
               (select count(*) from bookings b where b.occurrence_id = o.id and b.status = 'late_cancelled') as late_cancel
          from class_occurrences o
         where o.studio_id = p_studio_id and o.series_id is not null
           and o.status <> 'cancelled'
           and o.starts_at < now() and o.starts_at >= now() - interval '56 days'
           and o.series_id in (select series_id from coming)
      ) x
     where x.rn <= 8
  ),
  occscore as (
    select series_id, rn, booked, capacity, attended, waitlist, no_show, late_cancel,
           ( 0.6  * least(booked::numeric / nullif(capacity,0), 1)
           + 0.25 * (case when booked > 0 then least(attended::numeric / booked, 1) else 0 end)
           + 0.15 * least(waitlist::numeric / greatest(capacity,1), 0.5)
           - 0.2  * ((no_show + late_cancel)::numeric / greatest(capacity,1)) ) as s,
           (case when rn <= 4 then 2 else 1 end) as wt,
           (booked >= v_flexmin) as met,
           (waitlist > 0 or booked >= capacity) as demand
      from pastocc
  ),
  slotagg as (
    select series_id,
           count(*)::int as n_weeks,
           (sum(wt * s) / nullif(sum(wt),0))::numeric as score,
           ((count(*) filter (where rn <= 4 and met) >= 3) and count(*) >= 4) as qualifies,
           bool_or(demand) as wanted,
           round(avg(booked))::int as avg_booked,
           max(capacity)::int as capacity,
           sum(booked)::int as sum_booked,
           sum(attended)::int as sum_attended,
           sum(waitlist)::int as sum_waitlist,
           sum(no_show)::int as sum_no_show,
           sum(late_cancel)::int as sum_late_cancel
      from occscore group by series_id
  ),
  joined as (
    select c.series_id, c.occ_id, c.instructor_id, c.dow, c.slot_time, c.class_name, c.cur_tier,
           coalesce(a.n_weeks, 0) as n_weeks, a.score,
           coalesce(a.qualifies, false) as qualifies,
           coalesce(a.wanted, false) as wanted,
           coalesce(a.avg_booked, 0) as avg_booked,
           coalesce(a.capacity, c.capacity) as capacity,
           coalesce(a.sum_booked, 0) as sum_booked,
           coalesce(a.sum_attended, 0) as sum_attended,
           coalesce(a.sum_waitlist, 0) as sum_waitlist,
           coalesce(a.sum_no_show, 0) as sum_no_show,
           coalesce(a.sum_late_cancel, 0) as sum_late_cancel,
           coalesce(i.core_classes_per_day, 1) as budget
      from coming c
      left join slotagg a on a.series_id = c.series_id
      join instructors i on i.id = c.instructor_id
  ),
  ranked as (
    select j.*,
           row_number() over (partition by j.instructor_id, j.dow, j.qualifies
                              order by j.score desc nulls last, j.slot_time) as grp_rank,
           count(*) filter (where j.qualifies) over (partition by j.instructor_id, j.dow) as qual_in_day
      from joined j
  )
  select r.series_id, r.occ_id, r.instructor_id, r.dow, r.slot_time, r.class_name, r.cur_tier,
         r.n_weeks, r.score, r.qualifies, r.wanted, r.avg_booked, r.capacity,
         r.sum_booked, r.sum_attended, r.sum_waitlist, r.sum_no_show, r.sum_late_cancel,
         r.budget, r.grp_rank, r.qual_in_day,
         (case when r.n_weeks < 4 then null
               when r.qualifies and r.grp_rank <= r.budget then 'core'
               else 'flex' end) as proposed_tier
    from ranked r;

  -- coaches -> days -> slots
  select jsonb_agg(coach order by coach ->> 'name') into v_coaches
  from (
    select jsonb_build_object(
             'instructor_id', s.instructor_id,
             'name', split_part(i.display_name, ' ', 1),
             'budget', max(s.budget),
             'raise_to', case when bool_or(s.qualifies and s.qual_in_day > s.budget) and max(s.budget) < 3
                              then max(s.budget) + 1 else null end,
             'days', (
               select jsonb_agg(day_obj order by (day_obj->>'dow')::int)
               from (
                 select jsonb_build_object(
                          'dow', d.dow,
                          'day_name', (array['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'])[d.dow],
                          'budget', max(d.budget),
                          'unfilled', greatest(max(d.budget) - least(count(*) filter (where d.qualifies), max(d.budget)), 0),
                          'slots', jsonb_agg(
                            jsonb_build_object(
                              'series_id', d.series_id, 'occurrence_id', d.occ_id,
                              'class_name', d.class_name, 'time', d.slot_time,
                              'weeks', d.n_weeks,
                              'collecting', (d.n_weeks < 4),
                              'collecting_label', case when d.n_weeks < 4 then 'Collecting data, ' || d.n_weeks || ' of 4 weeks' else null end,
                              'score', round(coalesce(d.score, 0), 3),
                              'avg_booked', d.avg_booked, 'capacity', d.capacity,
                              'attended_rate', case when d.sum_booked > 0 then round(d.sum_attended::numeric / d.sum_booked, 2) else null end,
                              'waitlist', d.sum_waitlist, 'no_shows', d.sum_no_show, 'late_cancels', d.sum_late_cancel,
                              'qualifies', d.qualifies, 'wanted', d.wanted,
                              'current_tier', d.cur_tier, 'proposed_tier', d.proposed_tier,
                              'action', case when d.proposed_tier is null then null
                                             when d.proposed_tier = d.cur_tier then null
                                             else 'make_' || d.proposed_tier end
                            ) order by d.score desc nulls last, d.slot_time)
                        ) as day_obj
                 from _gi_slots d
                 where d.instructor_id = s.instructor_id
                 group by d.dow
               ) days
             )
           ) as coach
    from _gi_slots s
    join instructors i on i.id = s.instructor_id
    group by s.instructor_id, i.display_name
  ) coaches;

  -- Wanted slots: ran full or took a waitlist. "Add a class here".
  select jsonb_agg(w order by (w->>'day_name'), (w->>'time')) into v_wanted
  from (
    select distinct on (s.series_id)
           jsonb_build_object(
             'series_id', s.series_id, 'occurrence_id', s.occ_id,
             'class_name', s.class_name,
             'instructor_name', split_part(i.display_name, ' ', 1),
             'time', s.slot_time,
             'day_name', (array['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'])[s.dow],
             'reason', case when s.sum_waitlist > 0 then 'had a waitlist' else 'ran full' end
           ) as w
      from _gi_slots s join instructors i on i.id = s.instructor_id
     where s.wanted
     order by s.series_id
  ) wanted;

  -- Members to nudge: booked often (>= 4 attended) but not in the last 21 days.
  select jsonb_agg(n order by (n->>'last_visit') nulls first) into v_nudge
  from (
    select jsonb_build_object(
             'member_id', m.id,
             'name', btrim(m.first_name || ' ' || coalesce(m.last_name, '')),
             'phone', m.phone, 'email', m.email,
             'last_visit', (select max((ci.checked_in_at at time zone v_tz)::date)
                              from check_ins ci where ci.member_id = m.id)
           ) as n
      from members m
     where m.studio_id = p_studio_id and m.status = 'active' and m.deleted_at is null
       and (select count(*) from bookings b where b.member_id = m.id and b.status = 'attended') >= 4
       and not exists (
         select 1 from bookings b join class_occurrences o on o.id = b.occurrence_id
          where b.member_id = m.id and o.starts_at >= now() - interval '21 days'
            and b.status in ('booked','attended'))
     limit 10
  ) nudge;

  v_coaches := coalesce(v_coaches, '[]'::jsonb);
  v_wanted  := coalesce(v_wanted, '[]'::jsonb);
  v_nudge   := coalesce(v_nudge, '[]'::jsonb);

  -- Deterministic summary numbers (the only figures the optional Claude summary
  -- may name, Decision 92).
  select count(*) filter (where proposed_tier = 'core'),
         count(*) filter (where proposed_tier = 'flex'),
         count(*) filter (where proposed_tier = 'core' and proposed_tier is distinct from cur_tier),
         count(*) filter (where proposed_tier = 'flex' and proposed_tier is distinct from cur_tier),
         count(*) filter (where wanted),
         count(*) filter (where n_weeks < 4),
         count(distinct instructor_id)
    into v_n_core, v_n_flex, v_n_make_core, v_n_make_flex, v_n_wanted, v_n_collecting, v_n_coaches
    from _gi_slots;
  v_n_nudge := jsonb_array_length(v_nudge);

  v_summary_text :=
    'This week ' || v_n_core || ' class slots earn core and ' || v_n_flex
    || ' stay flex across ' || v_n_coaches || ' instructors.'
    || case when v_n_make_core + v_n_make_flex > 0
            then ' ' || (v_n_make_core + v_n_make_flex) || ' are a change from today.' else '' end
    || case when v_n_wanted > 0 then ' ' || v_n_wanted || ' slots are in demand.' else '' end
    || case when v_n_collecting > 0 then ' ' || v_n_collecting || ' are still collecting data.' else '' end;

  v_figures := jsonb_build_object(
    'proposed_core', jsonb_build_object('what','class slots recommended for core this week','text', v_n_core::text, 'n', v_n_core),
    'proposed_flex', jsonb_build_object('what','class slots staying flex','text', v_n_flex::text, 'n', v_n_flex),
    'changes',       jsonb_build_object('what','slots that would change from today','text',(v_n_make_core+v_n_make_flex)::text,'n',v_n_make_core+v_n_make_flex),
    'wanted',        jsonb_build_object('what','slots members want more of','text', v_n_wanted::text, 'n', v_n_wanted),
    'collecting',    jsonb_build_object('what','slots still collecting data','text', v_n_collecting::text, 'n', v_n_collecting),
    'coaches',       jsonb_build_object('what','instructors looked at','text', v_n_coaches::text, 'n', v_n_coaches),
    'nudge',         jsonb_build_object('what','members to nudge','text', v_n_nudge::text, 'n', v_n_nudge));

  v_allowed := to_jsonb(array[v_n_core::text, v_n_flex::text, (v_n_make_core+v_n_make_flex)::text,
                              v_n_wanted::text, v_n_collecting::text, v_n_coaches::text, v_n_nudge::text]);

  return jsonb_build_object(
    'week', p_week, 'flex_min', v_flexmin,
    'coaches', v_coaches, 'wanted', v_wanted, 'nudge', v_nudge,
    'summary', jsonb_build_object('text', v_summary_text, 'figures', v_figures, 'allowed', v_allowed));
end $$;

-- ===========================================================================
-- 5. growth_apply(occurrence, tier, scope) — manager-up, audited. Delegates to
--    the existing writers: set_occurrence_day_tier for the coming week, or
--    set_series_guarantee for every week. Each of those audits its own change;
--    this adds a growth.applied row tying it to the proposal.
-- ===========================================================================
create or replace function growth_apply(p_occurrence_id uuid, p_tier text, p_scope text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o class_occurrences%rowtype; v_series uuid; v_res jsonb; v_flexmin int; v_coremin int;
begin
  if p_tier not in ('core','flex') then
    raise exception 'tier must be core or flex' using errcode = 'PT422';
  end if;
  if p_scope not in ('week','series') then
    raise exception 'scope must be week or series' using errcode = 'PT422';
  end if;
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(o.studio_id), false) then
    raise exception 'only owners and managers change the timetable' using errcode = 'PT403';
  end if;

  if p_scope = 'week' then
    v_res := set_occurrence_day_tier(p_occurrence_id, p_tier);
  else
    v_series := o.series_id;
    if v_series is null then
      raise exception 'this class is a one-off, so there is no series to change' using errcode = 'PT409';
    end if;
    select coalesce(flex_min_bookings,2), coalesce(core_min_bookings,1)
      into v_flexmin, v_coremin from studio_settings where studio_id = o.studio_id;
    if p_tier = 'flex' then
      v_res := set_series_guarantee(v_series, 'flex'::guarantee_tier, coalesce(v_flexmin, 2));
    else
      v_res := set_series_guarantee(v_series, 'core'::guarantee_tier, nullif(v_coremin, 0));
    end if;
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (o.studio_id, auth.uid(), 'growth.applied', 'class_occurrences', p_occurrence_id,
          jsonb_build_object('scope', p_scope, 'tier', p_tier, 'series_id', o.series_id));
  return jsonb_build_object('ok', true, 'scope', p_scope, 'tier', p_tier, 'result', v_res);
end $$;

-- ===========================================================================
-- 6. dashboard_facts re-issued byte-faithfully (from 20260831020000) with a
--    growth arm that reads the week's stored growth numbers back, so the
--    Decision 92 verifier runs against the same figures the card shows.
-- ===========================================================================
create or replace function dashboard_facts(
  p_studio_id uuid, p_kind text, p_for_date date default null,
  p_subject_id uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_name text; v_currency char(3); v_tz text; v_day date;
  v_fig jsonb := '{}'::jsonb; v_allowed text[] := '{}'; v_fallback text;
  v_ctx jsonb := '{}'::jsonb;
  r jsonb; hm jsonb; k jsonb; ins jsonb;
  v_days int := 30;
  v_top jsonb; v_dow text[] := array['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
  m record; v_draft jsonb; v_spend bigint; v_rank int; v_gap int;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'dashboard facts are for owners, managers and the backend'
      using errcode = 'PT403';
  end if;
  select s.name, s.currency, s.timezone into v_name, v_currency, v_tz
    from studios s where s.id = p_studio_id;
  if v_name is null then raise exception 'no such studio' using errcode = 'PT404'; end if;
  v_day := coalesce(p_for_date, studio_today(p_studio_id));

  if p_kind = 'revenue' then
    r := dashboard_revenue(p_studio_id, v_day - (v_days - 1), v_day);
    if (r ->> 'state') = 'empty' then
      return jsonb_build_object('skip', true,
        'reason', 'no payments have ever been recorded, so there is nothing to explain');
    end if;

    v_fig := jsonb_build_object(
      'total',       jsonb_build_object('what','money taken in the period',
                       'text', dashboard_money_text((r->>'total_cents')::bigint, v_currency),
                       'n', round((r->>'total_cents')::bigint / 100.0)),
      'prior',       jsonb_build_object('what','money taken in the period before',
                       'text', dashboard_money_text((r->'trend'->>'prior')::bigint, v_currency),
                       'n', round((r->'trend'->>'prior')::bigint / 100.0)),
      'change_pct',  jsonb_build_object('what','per cent change against that period',
                       'text', coalesce((r->'trend'->>'pct'), 'not comparable'),
                       'n', (r->'trend'->>'pct')::numeric),
      'direction',   jsonb_build_object('what','which way it moved',
                       'text', r->'trend'->>'direction'),
      'days',        jsonb_build_object('what','length of the period in days','text', v_days::text, 'n', v_days),
      'bookings',    jsonb_build_object('what','bookings made in the period',
                       'text', r->'counts'->>'bookings', 'n', (r->'counts'->>'bookings')::numeric),
      'memberships_sold', jsonb_build_object('what','memberships sold in the period',
                       'text', r->'counts'->>'memberships_sold', 'n', (r->'counts'->>'memberships_sold')::numeric),
      'by_source',   r -> 'by_source');

    -- Every token the answer may contain: the figures above, plus each
    -- source's own amount and share.
    select array_agg(distinct t) into v_allowed from (
      select round((r->>'total_cents')::bigint / 100.0)::text as t
      union all select round((r->'trend'->>'prior')::bigint / 100.0)::text
      union all select abs((r->'trend'->>'pct')::numeric)::text where (r->'trend'->>'pct') is not null
      union all select v_days::text
      union all select (r->'counts'->>'bookings')
      union all select (r->'counts'->>'memberships_sold')
      union all select round((s->>'cents')::bigint / 100.0)::text from jsonb_array_elements(r->'by_source') s
      union all select (s->>'pct') from jsonb_array_elements(r->'by_source') s
    ) x where t is not null;

    select s into v_top from jsonb_array_elements(r->'by_source') s limit 1;
    v_fallback := 'You took ' || dashboard_money_text((r->>'total_cents')::bigint, v_currency)
      || ' in the last ' || v_days || ' days'
      || case when (r->'trend'->>'pct') is null then '.'
              else ', ' || abs((r->'trend'->>'pct')::numeric) || '% '
                   || case when (r->'trend'->>'direction') = 'down' then 'less' else 'more' end
                   || ' than the ' || v_days || ' days before.' end
      || case when v_top is null then ''
              else ' ' || (v_top->>'label') || ' were ' || (v_top->>'pct') || '% of it.' end;
    v_ctx := jsonb_build_object('period_days', v_days, 'currency', v_currency);

  elsif p_kind = 'attendance' then
    hm := dashboard_heatmap(p_studio_id, 90);
    -- jsonb_typeof, not IS NULL. jsonb_build_object with a SQL NULL stores a
    -- JSON null, and `hm -> 'peak'` reads that back as the jsonb value 'null'
    -- — which is not SQL NULL, so `is null` is false and the guard never
    -- fires. Found by a studio with classes but too few in any one slot to
    -- call a pattern.
    if (hm ->> 'state') = 'empty'
       or hm -> 'peak' is null or jsonb_typeof(hm -> 'peak') = 'null' then
      return jsonb_build_object('skip', true,
        'reason', 'not enough classes have run to see a pattern');
    end if;
    v_fig := jsonb_build_object(
      'peak_day',   jsonb_build_object('what','busiest day','text', v_dow[(hm->'peak'->>'dow')::int + 1]),
      'peak_hour',  jsonb_build_object('what','busiest hour, 24-hour clock','text', lpad(hm->'peak'->>'hour', 2, '0') || ':00',
                                       'n', (hm->'peak'->>'hour')::numeric),
      'peak_pct',   jsonb_build_object('what','how full that slot runs','text', hm->'peak'->>'occupancy',
                                       'n', (hm->'peak'->>'occupancy')::numeric),
      'peak_classes', jsonb_build_object('what','classes counted in that slot','text', hm->'peak'->>'classes',
                                       'n', (hm->'peak'->>'classes')::numeric),
      'quiet_day',  jsonb_build_object('what','quietest day','text', v_dow[(hm->'quiet'->>'dow')::int + 1]),
      'quiet_hour', jsonb_build_object('what','quietest hour','text', lpad(hm->'quiet'->>'hour', 2, '0') || ':00',
                                       'n', (hm->'quiet'->>'hour')::numeric),
      'quiet_pct',  jsonb_build_object('what','how full that slot runs','text', hm->'quiet'->>'occupancy',
                                       'n', (hm->'quiet'->>'occupancy')::numeric),
      'window_days', jsonb_build_object('what','how far back this looks','text','90','n',90));

    v_allowed := array[
      (hm->'peak'->>'hour'), (hm->'peak'->>'occupancy'), (hm->'peak'->>'classes'),
      (hm->'quiet'->>'hour'), (hm->'quiet'->>'occupancy'), (hm->'quiet'->>'classes'), '90',
      lpad(hm->'peak'->>'hour', 2, '0') || '00', lpad(hm->'quiet'->>'hour', 2, '0') || '00'];

    v_fallback := v_dow[(hm->'peak'->>'dow')::int + 1] || ' at '
      || lpad(hm->'peak'->>'hour', 2, '0') || ':00 is your fullest slot, running '
      || (hm->'peak'->>'occupancy') || '% across ' || (hm->'peak'->>'classes')
      || ' classes. ' || v_dow[(hm->'quiet'->>'dow')::int + 1] || ' at '
      || lpad(hm->'quiet'->>'hour', 2, '0') || ':00 is the quietest, at '
      || (hm->'quiet'->>'occupancy') || '%.';
    v_ctx := jsonb_build_object('window_days', 90, 'timezone', v_tz);

  elsif p_kind = 'lead' then
    select jsonb_agg(jsonb_build_object(
             'id', i.id, 'type', i.type, 'severity', i.severity, 'title', i.title,
             'observation', i.observation, 'why_it_matters', i.why_it_matters,
             'impact', case when i.estimated_impact_cents is null then null
                            else dashboard_money_text(i.estimated_impact_cents, v_currency) end)
             order by case i.severity when 'urgent' then 0 when 'warning' then 1 else 2 end,
                      i.estimated_impact_cents desc nulls last)
      into ins
      from ai_insights i
     where i.studio_id = p_studio_id and i.for_date = v_day and i.status = 'new';

    if ins is null or jsonb_array_length(ins) = 0 then
      return jsonb_build_object('skip', true,
        -- SAYING NOTHING IS A FEATURE. A brief that manufactures five items
        -- every morning to look busy trains the owner to stop reading it.
        'reason', 'nothing needs the owner today, which is an honest answer and not a gap');
    end if;

    v_fig := jsonb_build_object('insights', ins,
      'count', jsonb_build_object('what','how many are open','text', jsonb_array_length(ins)::text,
                                  'n', jsonb_array_length(ins)));
    select array_agg(distinct t) into v_allowed from (
      select jsonb_array_length(ins)::text as t
      union all select regexp_replace(x, '[^0-9.]', '', 'g')
        from jsonb_array_elements(ins) i,
             lateral unnest(narrative_numbers((i->>'observation') || ' ' || (i->>'title')
                            || ' ' || coalesce(i->>'impact',''))) x
    ) y where t is not null and t <> '';

    v_fallback := (ins->0->>'title') || ' — ' || (ins->0->>'observation');
    v_ctx := jsonb_build_object('open_insights', jsonb_array_length(ins));

  elsif p_kind = 'draft' then
    -- The message a retention insight offers to send. The DETERMINISTIC draft
    -- from migration 022 is the fallback, so the compose screen always has
    -- something in the field; the model's job is to make it sound like a
    -- person wrote it, and to use the two facts that make it land — how long
    -- it has been, and what this member is worth.
    --
    -- "IT NAMES PEOPLE AND MONEY." "Maria hasn't been in for three weeks and
    -- she is your fourth-highest spender this year" lands; "retention risk
    -- detected" does not. Both of those numbers are computed here.
    select mm.id, mm.first_name, coalesce(mm.preferred_name, mm.first_name) as calls_them,
           mm.health_band, mm.health_reason
      into m from members mm
     where mm.id = p_subject_id and mm.studio_id = p_studio_id;
    if m.id is null then
      raise exception 'no such member here' using errcode = 'PT404';
    end if;

    v_draft := message_draft_for(p_subject_id);
    select coalesce(sum(p.amount_cents), 0)::bigint into v_spend
      from payments p where p.member_id = p_subject_id
       and p.status in ('succeeded','partially_refunded')
       and coalesce(p.paid_at, p.created_at) >= now() - interval '365 days';
    select count(*) + 1 into v_rank from (
      select mm.id, coalesce(sum(p.amount_cents), 0) tot
        from members mm left join payments p on p.member_id = mm.id
             and p.status in ('succeeded','partially_refunded')
             and coalesce(p.paid_at, p.created_at) >= now() - interval '365 days'
       where mm.studio_id = p_studio_id and mm.status <> 'archived'
       group by mm.id) t where t.tot > v_spend;
    select (studio_today(p_studio_id) - max((ci.checked_in_at at time zone v_tz)::date))
      into v_gap from check_ins ci where ci.member_id = p_subject_id;

    v_fig := jsonb_build_object(
      'name',       jsonb_build_object('what','what to call them','text', m.calls_them),
      'band',       jsonb_build_object('what','their health band','text', m.health_band),
      'reason',     jsonb_build_object('what','why, in the words the studio already uses','text', m.health_reason),
      'days_since', jsonb_build_object('what','days since their last visit',
                      'text', coalesce(v_gap::text, 'never been in'), 'n', v_gap),
      'spend_year', jsonb_build_object('what','what they have spent in the last year',
                      'text', dashboard_money_text(v_spend, v_currency),
                      'n', round(v_spend / 100.0)),
      'spend_rank', jsonb_build_object('what','where that ranks them among members',
                      'text', v_rank::text, 'n', v_rank),
      'subject',    jsonb_build_object('what','the deterministic subject line','text', v_draft ->> 'subject'));

    select array_agg(distinct t) into v_allowed from (
      select coalesce(v_gap::text, '') as t
      union all select round(v_spend / 100.0)::text
      union all select v_rank::text
      union all select x from unnest(narrative_numbers(coalesce(m.health_reason,'') || ' '
                                     || coalesce(v_draft ->> 'body',''))) x
    ) y where t is not null and t <> '';

    v_fallback := v_draft ->> 'body';
    v_ctx := jsonb_build_object(
      'subject', v_draft ->> 'subject',
      'template_key', v_draft ->> 'template_key',
      'marketing_opt_in', v_draft -> 'marketing_opt_in',
      'never_sends_itself', 'This is a draft. It lands in an editable field and a person presses send.');
  elsif p_kind = 'growth' then
    -- Decision 106. The growth numbers were computed by growth_insights() and
    -- stored on the week's ai_insights row; this arm only reads them back, so
    -- the verifier runs against the same figures the card shows, and
    -- growth_insights stays service-only (no transitive guard to trip here).
    select ai.action_payload into r
      from ai_insights ai
     where ai.studio_id = p_studio_id and ai.type = 'growth'
       and ai.subject_id is null and ai.for_date = v_day;
    if r is null or (r -> 'summary') is null or jsonb_typeof(r -> 'summary') = 'null' then
      return jsonb_build_object('skip', true,
        'reason', 'no growth numbers have been produced for this week yet');
    end if;
    v_fig := coalesce(r -> 'summary' -> 'figures', '{}'::jsonb);
    select array_agg(x) into v_allowed
      from jsonb_array_elements_text(coalesce(r -> 'summary' -> 'allowed', '[]'::jsonb)) x;
    v_fallback := r -> 'summary' ->> 'text';
    v_ctx := jsonb_build_object('week', r ->> 'week');

  else
    raise exception 'unknown narrative kind %', p_kind using errcode = 'PT422';
  end if;

  return jsonb_build_object(
    'studio', v_name, 'currency', v_currency, 'date', v_day, 'kind', p_kind,
    'subject_id', p_subject_id,
    'figures', v_fig, 'allowed', to_jsonb(coalesce(v_allowed, '{}')),
    'fallback', v_fallback, 'context', v_ctx);
end $$;

-- ===========================================================================
-- 7. The weekly sweep: write the week's growth insight row, and (gated) queue
--    the optional summary through the existing narrative machinery.
-- ===========================================================================
create or replace function sweep_growth_insights(p_studio_id uuid, p_week date)
returns jsonb language plpgsql security definer set search_path = public, net as $$
declare v_gi jsonb; v_ai boolean; v_key boolean; v_queued boolean := false;
begin
  if not is_service_context() then
    raise exception 'growth insights run as the backend, not as a user' using errcode = 'PT403';
  end if;
  v_gi := growth_insights(p_studio_id, p_week);

  -- One row per studio per week. The unique index treats a NULL subject as
  -- distinct, so ON CONFLICT would not catch it; delete then insert makes a
  -- re-run idempotent.
  delete from ai_insights
   where studio_id = p_studio_id and type = 'growth' and subject_id is null and for_date = p_week;
  insert into ai_insights
    (studio_id, type, severity, title, observation, why_it_matters, recommended_action,
     action_type, action_payload, subject_type, subject_id, for_date, status)
  values (p_studio_id, 'growth', 'info',
          'Classes to grow this week',
          coalesce(v_gi -> 'summary' ->> 'text', 'No growth numbers this week.'),
          'Core classes run regardless of bookings and pay the instructor; flex classes run only if they fill. Keeping the balance right is what grows the studio.',
          'Review this week''s proposals.',
          'growth', v_gi, 'studio', null, p_week, 'new');

  -- The optional one-paragraph summary: only when this studio's AI drafts are on
  -- AND the platform key is present. Either absent, the numbers stand without it.
  select coalesce(ai_drafts_enabled, false) into v_ai from studio_settings where studio_id = p_studio_id;
  v_key := anthropic_api_key() is not null;
  if coalesce(v_ai, false) and v_key then
    begin
      perform queue_dashboard_narrative(p_studio_id, 'growth', null, p_week);
      v_queued := true;
    exception when others then
      -- A narrative failure never breaks the week's numbers.
      v_queued := false;
    end;
  end if;

  return jsonb_build_object('ok', true, 'week', p_week, 'summary_queued', v_queued);
end $$;

-- ===========================================================================
-- 8. The driver: hourly, each studio fires once on Monday at or after 7am in
--    its own clock. job_runs (unique on job_key, run_for) makes it once-a-week
--    per studio however many times the hourly job fires.
-- ===========================================================================
create or replace function sweep_growth_insights_all(p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record; v_job uuid; v_local timestamp; v_monday date;
        n_done int := 0; n_skip int := 0; n_fail int := 0;
begin
  if not is_service_context() then
    raise exception 'the growth sweep runs as the backend, not as a user' using errcode = 'PT403';
  end if;
  for r in select s.id as studio_id, s.timezone as tz from studios s where s.status = 'active' loop
    v_local := p_now at time zone r.tz;
    if extract(isodow from v_local)::int <> 1 or extract(hour from v_local)::int < 7 then
      continue;
    end if;
    v_monday := v_local::date;
    insert into job_runs (job_key, run_for, status)
    values ('growth_insights:' || r.studio_id, v_monday, 'running')
    on conflict (job_key, run_for) do update
       set attempts = job_runs.attempts + 1, started_at = now(), status = 'running'
     where job_runs.status <> 'done'
    returning id into v_job;
    if v_job is null then n_skip := n_skip + 1; continue; end if;
    begin
      perform sweep_growth_insights(r.studio_id, v_monday);
      update job_runs set status = 'done', finished_at = now(), error = null where id = v_job;
      n_done := n_done + 1;
    exception when others then
      update job_runs set status = 'failed', finished_at = now(), error = sqlerrm where id = v_job;
      n_fail := n_fail + 1;
    end;
  end loop;
  return jsonb_build_object('generated', n_done, 'skipped', n_skip, 'failed', n_fail);
end $$;

-- ===========================================================================
-- 9. Grants. Everything new is closed by default on this platform.
-- ===========================================================================
revoke execute on function seed_instructor_core_budgets(uuid)   from public, anon, authenticated;
revoke execute on function growth_insights(uuid, date)          from public, anon, authenticated;
revoke execute on function sweep_growth_insights(uuid, date)     from public, anon, authenticated;
revoke execute on function sweep_growth_insights_all(timestamptz) from public, anon, authenticated;
grant  execute on function seed_instructor_core_budgets(uuid)   to service_role;
grant  execute on function growth_insights(uuid, date)          to service_role;
grant  execute on function sweep_growth_insights(uuid, date)     to service_role;
grant  execute on function sweep_growth_insights_all(timestamptz) to service_role;

-- Guarded manager-up inside, so the client role may hold them.
revoke execute on function set_instructor_core_budget(uuid, int) from public, anon;
revoke execute on function growth_apply(uuid, text, text)        from public, anon;
grant  execute on function set_instructor_core_budget(uuid, int) to authenticated, service_role;
grant  execute on function growth_apply(uuid, text, text)        to authenticated, service_role;

-- dashboard_facts was re-issued above; re-assert its ACL (guarded manager-up).
revoke execute on function dashboard_facts(uuid, text, date, uuid) from public, anon;
grant  execute on function dashboard_facts(uuid, text, date, uuid) to authenticated, service_role;

-- ===========================================================================
-- 10. The weekly cron (hourly driver).
-- ===========================================================================
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('studiior-growth-insights');
  end if;
exception when others then null;
end $$;
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('studiior-growth-insights', '0 * * * *',
      $c$select sweep_growth_insights_all()$c$);
  end if;
end $$;

-- ===========================================================================
-- 11. Seed the budgets once, for every studio (service context at apply).
-- ===========================================================================
do $$ begin perform seed_instructor_core_budgets(null); end $$;

-- ===========================================================================
-- 12. Surface assertions: anon functions EXACTLY FOURTEEN; the inbox table is
--     the one public table (anon INSERT only, never readable).
-- ===========================================================================
do $mig$ declare n int; begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.prokind = 'f'
     and has_function_privilege('anon', p.oid, 'execute');
  if n <> 14 then raise exception 'anon function surface is % not FOURTEEN', n; end if;
  if not has_table_privilege('anon', 'public.resend_webhook_inbox', 'insert') then
    raise exception 'resend_webhook_inbox lost its anon insert surface';
  end if;
  if has_table_privilege('anon', 'public.resend_webhook_inbox', 'select') then
    raise exception 'resend_webhook_inbox must not be anon-readable';
  end if;
end $mig$;
