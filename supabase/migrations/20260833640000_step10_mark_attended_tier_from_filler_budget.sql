-- creates: staff_mark_attended(uuid, text), growth_dismiss(uuid), growth_number_word(int)
-- re-issues: mark_present(uuid), set_series_guarantee(uuid, guarantee_tier, int, int, date), bulk_update_series(uuid[], jsonb, boolean, date), bulk_update_series_run(uuid[], jsonb, boolean, date), update_series(uuid, text, uuid, uuid, uuid, int, int, text, date, date, time, text, date, boolean), assign_instructors_run(uuid, date, date, boolean), growth_insights(uuid, date), growth_apply(uuid, text, text, boolean), set_instructor_core_budget(uuid, int), seed_instructor_core_budgets(uuid), schedule_range(uuid, date, date)
--
-- Step 10 (21 Nov 2026): Decision 35 (a) staff mark attended, Decision 21 (d)
-- tier changes from a date, Decision 19 the filler keeps a coach's hours
-- together, Decision 106 (a) the core budget is per week and informs, and the
-- series end-date fix (note under Decision 42b). No new anon RPC: the anon
-- surface stays EXACTLY FOURTEEN (asserted at the bottom).

-- ---------------------------------------------------------------- schema ----
alter table instructors rename column core_classes_per_day to core_classes_per_week;
alter table instructors drop constraint if exists instructors_core_classes_per_day_check;
alter table instructors add constraint instructors_core_classes_per_week_check
  check (core_classes_per_week is null or core_classes_per_week between 1 and 21);
comment on column instructors.core_classes_per_week is
  'Decision 106(a): the weekly core budget. Informs the growth review (over-budget is flagged), never blocks.';

alter table class_series add column if not exists tier_from date;
comment on column class_series.tier_from is
  'Decision 21(d): the date the series'' current tier applies from (null = already in force). Classes before it are pinned on the class.';

create table if not exists growth_dismissals (
  id uuid primary key default gen_random_uuid(),
  studio_id uuid not null references studios(id) on delete cascade,
  series_id uuid not null references class_series(id) on delete cascade,
  dow int not null check (dow between 1 and 7),
  expires_on date not null,
  dismissed_by uuid,
  created_at timestamptz not null default now(),
  unique (series_id, dow)
);
alter table growth_dismissals enable row level security;
create policy growth_dismissals_manager_read on growth_dismissals
  for select to authenticated using (coalesce(is_manager_up(studio_id), false));
revoke all on growth_dismissals from public, anon;
grant select on growth_dismissals to authenticated;
grant all on growth_dismissals to service_role;

-- --------------------------------------------- signature changes (drop first) --
drop function if exists set_series_guarantee(uuid, guarantee_tier, integer, integer);
drop function if exists bulk_update_series(uuid[], jsonb, boolean);
drop function if exists bulk_update_series_run(uuid[], jsonb, boolean);
drop function if exists growth_apply(uuid, text, text);
drop function if exists schedule_range(uuid, date, date);

-- -----------------------------------------------------------------------------
-- Decision 35 (a): staff mark attended. ONE path; mark_present is folded in.
--   booked, class started, not finalised  -> desk-up or the class's coach; a
--     check_in row at the class start (method staff, or instructor for the coach),
--     booking attended. Reason optional.
--   no_show, not finalised                -> desk-up or the class's coach.
--   no_show, finalised                    -> manager-up, reason required.
-- The no-show reversal voids the infraction, clears the desk-pay strike it
-- caused (only when no other no-show or late cancel on an unpaid drop-in
-- stands), returns a kept reservation fee as credit through tg_reservation_credit
-- (fired by the status change), and leaves pay alone (a no-show seat was already
-- paid under 75(j); finalise_pay_true_up is idempotent).
-- -----------------------------------------------------------------------------
create or replace function staff_mark_attended(p_booking_id uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b bookings%rowtype; o class_occurrences%rowtype;
  v_final boolean; v_coach boolean; v_desk boolean; v_mgr boolean;
  v_voided int := 0; v_ci boolean := false; v_strike boolean := false;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_prev text;
begin
  select * into b from bookings where id = p_booking_id for update;
  if not found then raise exception 'no such booking' using errcode = 'PT404'; end if;
  select * into o from class_occurrences where id = b.occurrence_id;

  v_desk  := coalesce(is_desk_up(b.studio_id), false);
  v_mgr   := coalesce(is_manager_up(b.studio_id), false);
  v_coach := o.instructor_id is not null and coalesce(is_this_instructor(o.instructor_id), false);
  v_final := o.attendance_finalised_at is not null;

  if b.status not in ('booked', 'no_show') then
    raise exception 'only a booked or no-show booking can be marked attended' using errcode = 'PT409';
  end if;
  if b.status = 'booked' and o.starts_at > now() then
    raise exception 'the class has not started yet' using errcode = 'PT409';
  end if;
  if b.status = 'booked' and v_final then
    raise exception 'the day is finalised; this booking is not booked any more' using errcode = 'PT409';
  end if;

  if v_final then
    if not v_mgr and not is_service_context() then
      raise exception 'only owners and managers correct a finalised day' using errcode = 'PT403';
    end if;
    if v_reason is null then
      raise exception 'say why this member is being marked attended' using errcode = 'PT400';
    end if;
  elsif not (v_desk or v_coach or is_service_context()) then
    raise exception 'only staff or the class''s instructor mark attendance' using errcode = 'PT403';
  end if;

  v_prev := b.status::text;

  -- The visit itself, at the class start, if there is none yet.
  if not exists (select 1 from check_ins where booking_id = b.id) then
    insert into check_ins (studio_id, booking_id, member_id, occurrence_id, checked_in_at,
                           method, checked_in_by)
    values (b.studio_id, b.id, b.member_id, o.id, o.starts_at,
            (case when v_coach and not v_desk then 'instructor' else 'staff' end)::checkin_method,
            auth.uid());
    v_ci := true;
  end if;

  update bookings set status = 'attended', updated_at = now() where id = b.id;

  if v_prev = 'no_show' then
    update member_infractions
       set status = 'voided', voided_at = now(), voided_by = auth.uid(),
           voided_reason = coalesce(v_reason, 'Marked attended')
     where booking_id = b.id and status = 'active';
    get diagnostics v_voided = row_count;

    -- The desk-pay strike, only if this no-show caused it and nothing else would.
    if b.payment_source = 'drop_in'
       and exists (select 1 from members m where m.id = b.member_id
                    and m.desk_pay_blocked_at is not null and m.desk_pay_blocked_reason = 'no_show')
       and not exists (
         select 1 from bookings x
          where x.member_id = b.member_id and x.id <> b.id
            and x.status in ('no_show', 'late_cancelled')
            and x.payment_source = 'drop_in'
            and not exists (select 1 from payments p where p.booking_id = x.id
                             and p.status in ('succeeded', 'partially_refunded'))) then
      perform set_config('studiior.desk_pay_system', '1', true);
      update members set desk_pay_blocked_at = null, desk_pay_blocked_reason = null, updated_at = now()
       where id = b.member_id;
      perform set_config('studiior.desk_pay_system', '', true);
      v_strike := true;
    end if;

    -- Pay does not move (a no-show seat was already paid under 75(j)); the
    -- true-up is idempotent and manager/service only, so it runs only there.
    if v_mgr or is_service_context() then
      perform finalise_pay_true_up(o.id);
    end if;
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (b.studio_id, auth.uid(), 'booking.marked_attended', 'bookings', b.id,
          jsonb_build_object('status', v_prev),
          jsonb_build_object('status', 'attended', 'reason', v_reason, 'finalised', v_final,
                             'by', case when v_coach and not v_desk then 'instructor' else 'staff' end,
                             'check_in_written', v_ci, 'infractions_voided', v_voided,
                             'desk_pay_restored', v_strike));

  return jsonb_build_object('ok', true, 'from', v_prev, 'infractions_voided', v_voided,
                            'desk_pay_restored', v_strike, 'check_in_written', v_ci,
                            -- member_suspension is desk-up guarded; a coach gets null.
                            'suspension', case when v_desk or is_service_context()
                                               then member_suspension(b.member_id) end);
end $$;

-- mark_present is the same act; it goes through the one path.
create or replace function mark_present(p_booking_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare b bookings%rowtype; v jsonb;
begin
  select * into b from bookings where id = p_booking_id;
  if not found then raise exception 'no such booking' using errcode = 'PT404'; end if;
  if b.status <> 'no_show' then
    raise exception 'that booking is not marked as a no-show' using errcode = 'PT409';
  end if;
  v := staff_mark_attended(p_booking_id, 'Marked present');
  return jsonb_build_object('ok', true, 'infractions_voided', v -> 'infractions_voided',
                            'suspension', v -> 'suspension');
end $$;

-- Decision 106(a): hide a growth suggestion for four weeks.
create or replace function growth_dismiss(p_occurrence_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare o class_occurrences%rowtype; v_tz text; v_dow int; v_until date;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(o.studio_id), false) then
    raise exception 'only owners and managers change the timetable' using errcode = 'PT403';
  end if;
  if o.series_id is null then
    raise exception 'this class is a one-off, so there is no suggestion to dismiss' using errcode = 'PT409';
  end if;
  select timezone into v_tz from studios where id = o.studio_id;
  v_dow := extract(isodow from o.starts_at at time zone v_tz)::int;
  v_until := (now() at time zone v_tz)::date + 28;
  insert into growth_dismissals (studio_id, series_id, dow, expires_on, dismissed_by)
  values (o.studio_id, o.series_id, v_dow, v_until, auth.uid())
  on conflict (series_id, dow) do update
     set expires_on = excluded.expires_on, dismissed_by = excluded.dismissed_by, created_at = now();
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (o.studio_id, auth.uid(), 'growth.dismissed', 'class_series', o.series_id,
          jsonb_build_object('dow', v_dow, 'until', v_until, 'occurrence_id', p_occurrence_id));
  return jsonb_build_object('ok', true, 'series_id', o.series_id, 'dow', v_dow, 'until', v_until);
end $$;

create or replace function growth_number_word(p_n int)
returns text language sql immutable set search_path = public as $$
  select case p_n when 0 then 'zero' when 1 then 'one' when 2 then 'two' when 3 then 'three'
                  when 4 then 'four' when 5 then 'five' when 6 then 'six' when 7 then 'seven'
                  when 8 then 'eight' else p_n::text end
$$;

CREATE OR REPLACE FUNCTION public.growth_insights(p_studio_id uuid, p_week date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
           (case when g.tier in ('core','always') then 'core' else 'flex' end) as cur_tier,
           -- Decision 106(a): how many classes this series holds in the week, the
           -- unit the weekly core budget counts in.
           (select count(*)::int from class_occurrences w
             where w.series_id = o.series_id and w.status = 'scheduled'
               and (w.starts_at at time zone v_tz)::date >= p_week
               and (w.starts_at at time zone v_tz)::date <  p_week + 7) as occ_in_week
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
           sum(late_cancel)::int as sum_late_cancel,
           -- The plain-language streaks behind the Schedule suggestion line.
           (coalesce(min(rn) filter (where not met), count(*) + 1) - 1)::int as met_streak,
           (coalesce(min(rn) filter (where booked > 0), count(*) + 1) - 1)::int as empty_streak,
           (count(*) filter (where rn <= 4 and met))::int as met4,
           (max(booked) filter (where rn = 1))::int as last_booked
      from occscore group by series_id
  ),
  joined as (
    select c.series_id, c.occ_id, c.instructor_id, c.dow, c.slot_time, c.class_name, c.cur_tier, c.occ_in_week,
           coalesce(a.met_streak, 0) as met_streak, coalesce(a.empty_streak, 0) as empty_streak,
           coalesce(a.met4, 0) as met4, coalesce(a.last_booked, 0) as last_booked,
           exists (select 1 from growth_dismissals gd
                    where gd.series_id = c.series_id and gd.dow = c.dow
                      and gd.expires_on > (now() at time zone v_tz)::date) as dismissed,
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
           coalesce(i.core_classes_per_week, 1) as budget
      from coming c
      left join slotagg a on a.series_id = c.series_id
      join instructors i on i.id = c.instructor_id
  ),
  proposed as (
    -- Decision 106(a): the budget INFORMS, it does not block. Every qualifying
    -- slot is proposed core; a slot that would take the coach past their weekly
    -- budget is flagged over_budget with the count it would reach.
    select j.*,
           (case when j.n_weeks < 4 then null
                 when j.qualifies then 'core' else 'flex' end) as proposed_tier,
           sum(case when j.cur_tier = 'core' then j.occ_in_week else 0 end)
             over (partition by j.instructor_id) as core_now
      from joined j
  ),
  ranked as (
    select p.*,
           (p.proposed_tier = 'core' and p.cur_tier <> 'core' and not p.dismissed) as adds_core,
           p.core_now + sum(case when p.proposed_tier = 'core' and p.cur_tier <> 'core' and not p.dismissed
                                 then p.occ_in_week else 0 end)
             over (partition by p.instructor_id
                   order by p.score desc nulls last, p.dow, p.slot_time, p.series_id
                   rows between unbounded preceding and current row) as would_hold
      from proposed p
  )
  select r.series_id, r.occ_id, r.instructor_id, r.dow, r.slot_time, r.class_name, r.cur_tier,
         r.n_weeks, r.score, r.qualifies, r.wanted, r.avg_booked, r.capacity,
         r.sum_booked, r.sum_attended, r.sum_waitlist, r.sum_no_show, r.sum_late_cancel,
         r.budget, r.occ_in_week, r.core_now, r.met_streak, r.empty_streak, r.met4, r.last_booked,
         r.dismissed, r.proposed_tier,
         (case when r.adds_core then r.would_hold::int end) as would_hold,
         (r.adds_core and r.would_hold > r.budget) as over_budget,
         (case
            when r.proposed_tier = 'core' and r.cur_tier <> 'core' then
              case when r.met_streak >= 2
                   then 'Reached ' || least(r.last_booked, v_flexmin) || ' of ' || v_flexmin || ' '
                        || growth_number_word(r.met_streak) || ' weeks running. Make it core?'
                   else 'Reached the minimum in ' || growth_number_word(r.met4)
                        || ' of the last four weeks. Make it core?' end
            when r.proposed_tier = 'flex' and r.cur_tier = 'core' then
              case when r.empty_streak >= 2
                   then 'Empty ' || growth_number_word(r.empty_streak) || ' weeks running. Make it flex?'
                   else 'Reached the minimum in ' || growth_number_word(r.met4)
                        || ' of the last four weeks. Make it flex?' end
          end) as line
    from ranked r;

  -- coaches -> days -> slots
  select jsonb_agg(coach order by coach ->> 'name') into v_coaches
  from (
    select jsonb_build_object(
             'instructor_id', s.instructor_id,
             'name', split_part(i.display_name, ' ', 1),
             'budget', max(s.budget),
             'core_now', max(s.core_now),
             'raise_to', case when max(s.would_hold) filter (where s.over_budget) is not null
                              then least(max(s.would_hold) filter (where s.over_budget), 21) else null end,
             'days', (
               select jsonb_agg(day_obj order by (day_obj->>'dow')::int)
               from (
                 select jsonb_build_object(
                          'dow', d.dow,
                          'day_name', (array['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'])[d.dow],
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
                              'dow', d.dow, 'occ_in_week', d.occ_in_week,
                              'would_hold', d.would_hold, 'over_budget', coalesce(d.over_budget, false),
                              'dismissed', d.dismissed, 'line', d.line,
                              'action', case when d.proposed_tier is null then null
                                             when d.proposed_tier = d.cur_tier then null
                                             when d.dismissed then null
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
         count(*) filter (where proposed_tier = 'core' and proposed_tier is distinct from cur_tier and not dismissed),
         count(*) filter (where proposed_tier = 'flex' and proposed_tier is distinct from cur_tier and not dismissed),
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
end $function$;

CREATE OR REPLACE FUNCTION public.growth_apply(p_occurrence_id uuid, p_tier text, p_scope text, p_raise_budget boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o class_occurrences%rowtype; v_series uuid; v_res jsonb; v_flexmin int; v_coremin int;
  v_tz text; v_wk date; v_count int; v_old int; v_raised int;
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

  -- Decision 106(a): "Make core and raise budget" sets the coach's weekly budget
  -- to the number of core classes they now hold in this class's week.
  if p_raise_budget and p_tier = 'core' and o.instructor_id is not null then
    select timezone into v_tz from studios where id = o.studio_id;
    v_wk := date_trunc('week', (o.starts_at at time zone v_tz)::date)::date;
    select count(*)::int into v_count
      from class_occurrences w
      cross join lateral occurrence_guarantee_run(w.id) g
     where w.instructor_id = o.instructor_id and w.status = 'scheduled'
       and g.tier in ('core','always')
       and (w.starts_at at time zone v_tz)::date >= v_wk
       and (w.starts_at at time zone v_tz)::date <  v_wk + 7;
    select core_classes_per_week into v_old from instructors where id = o.instructor_id;
    if v_count > coalesce(v_old, 0) then
      v_raised := least(greatest(v_count, 1), 21);
      update instructors set core_classes_per_week = v_raised, updated_at = now()
       where id = o.instructor_id;
      insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
      values (o.studio_id, auth.uid(), 'instructor.core_budget_raised', 'instructors', o.instructor_id,
              jsonb_build_object('core_classes_per_week', v_old),
              jsonb_build_object('core_classes_per_week', v_raised, 'occurrence_id', p_occurrence_id));
    end if;
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (o.studio_id, auth.uid(), 'growth.applied', 'class_occurrences', p_occurrence_id,
          jsonb_build_object('scope', p_scope, 'tier', p_tier, 'series_id', o.series_id));
  return jsonb_build_object('ok', true, 'scope', p_scope, 'tier', p_tier, 'result', v_res,
                            'budget_raised_to', v_raised);
end $function$;

CREATE OR REPLACE FUNCTION public.set_instructor_core_budget(p_instructor_id uuid, p_n integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_studio uuid; v_old int;
begin
  select studio_id, core_classes_per_week into v_studio, v_old from instructors where id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(v_studio), false) then
    raise exception 'only owners and managers set a budget' using errcode = 'PT403';
  end if;
  if p_n is null or p_n < 1 or p_n > 21 then
    raise exception 'the budget is a number from 1 to 21' using errcode = 'PT422';
  end if;
  update instructors set core_classes_per_week = p_n, updated_at = now() where id = p_instructor_id;
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (v_studio, auth.uid(), 'instructor.core_budget_set', 'instructors', p_instructor_id,
          jsonb_build_object('core_classes_per_week', v_old),
          jsonb_build_object('core_classes_per_week', p_n));
  return jsonb_build_object('ok', true, 'core_classes_per_week', p_n);
end $function$;

CREATE OR REPLACE FUNCTION public.seed_instructor_core_budgets(p_studio_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_set int := 0; r record; v_tz text; v_from date; v_to date; v_mode int; v_budget int;
begin
  if not is_service_context() then
    raise exception 'budgets are seeded by the backend, not by a user' using errcode = 'PT403';
  end if;
  for r in
    select i.id as instructor_id, i.studio_id, s.timezone as tz
      from instructors i join studios s on s.id = i.studio_id
     where (p_studio_id is null or i.studio_id = p_studio_id)
       and i.status = 'active' and i.core_classes_per_week is null
  loop
    v_tz := r.tz;
    v_from := date_trunc('month', (now() at time zone v_tz))::date;
    v_to   := (date_trunc('month', (now() at time zone v_tz)) + interval '2 months')::date;
    -- Decision 106(a): per teaching WEEK, this coach's count of core (core or
    -- always) classes; then the most common value across weeks. mode() over no
    -- rows is NULL (the coach does not teach in the window) and we leave them
    -- unseeded; a mode of 0 (teaches, but all flex) floors to 1.
    select mode() within group (order by d.core_cnt) into v_mode
      from (
        select date_trunc('week', (o.starts_at at time zone v_tz)::date)::date as week_d,
               count(*) filter (where g.tier in ('core','always')) as core_cnt
          from class_occurrences o
          cross join lateral occurrence_guarantee_run(o.id) g
         where o.studio_id = r.studio_id and o.instructor_id = r.instructor_id
           and o.status = 'scheduled'
           and (o.starts_at at time zone v_tz)::date >= v_from
           and (o.starts_at at time zone v_tz)::date <  v_to
         group by date_trunc('week', (o.starts_at at time zone v_tz)::date)::date
      ) d;
    if v_mode is null then continue; end if;
    v_budget := greatest(least(v_mode, 21), 1);
    update instructors set core_classes_per_week = v_budget, updated_at = now()
     where id = r.instructor_id and core_classes_per_week is null;
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (r.studio_id, null, 'instructor.core_budget_seeded', 'instructors', r.instructor_id,
            jsonb_build_object('core_classes_per_week', v_budget, 'window_from', v_from, 'window_to', v_to));
    v_set := v_set + 1;
  end loop;
  return jsonb_build_object('seeded', v_set);
end $function$;

CREATE OR REPLACE FUNCTION public.schedule_range(p_studio_id uuid, p_from date, p_to date)
 RETURNS TABLE(occ_id uuid, occ_name text, starts_at timestamp with time zone, ends_at timestamp with time zone, local_date date, local_start text, local_end text, start_minutes integer, end_minutes integer, occ_instructor_id uuid, room_name text, occ_capacity integer, occ_booked integer, occ_waitlist integer, occ_staffing text, occ_status text, occ_flex boolean, occ_confirmed boolean, occ_tier text, occ_standalone boolean, occ_series_tier text, occ_minimum integer, occ_cancellation_cause text, occ_assignment_requested boolean, occ_assignment_confirmed boolean, occ_free_first jsonb, occ_hidden boolean, occ_is_private boolean, occ_reached_minimum boolean, occ_paid_count integer, occ_unpaid_count integer, has_growth_suggestion boolean, growth_suggestion jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_tz text; v_ff boolean; v_growth jsonb; v_today date;
begin
  if not coalesce(is_manager_up(p_studio_id), false) and not is_service_context() then
    raise exception 'the timetable is the owner''s and managers'' to see'
      using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  if v_tz is null then
    raise exception 'no such studio' using errcode = 'PT404';
  end if;
  if p_to < p_from then
    raise exception 'that range ends before it starts' using errcode = 'PT400';
  end if;
  if p_to - p_from > 62 then
    raise exception 'ask for at most 62 days at a time' using errcode = 'PT422';
  end if;

  -- Decision 30 amendment (b) follow-up: only compute the per-class free-first
  -- state when the studio uses the feature — otherwise it is null and the popup
  -- card and the "Trials" marker are hidden.
  select free_first_class_enabled into v_ff from studio_settings where studio_id = p_studio_id;

  -- Decision 106(a): the latest weekly growth review's live proposals, keyed on
  -- series plus weekday, minus the ones a manager dismissed.
  v_today := (now() at time zone v_tz)::date;
  select coalesce(jsonb_object_agg((s ->> 'series_id') || '|' || (s ->> 'dow'), s), '{}'::jsonb)
    into v_growth
    from (select action_payload from ai_insights
           where studio_id = p_studio_id and type = 'growth' and subject_id is null
           order by for_date desc, created_at desc limit 1) gi
    cross join lateral jsonb_array_elements(coalesce(gi.action_payload -> 'coaches', '[]'::jsonb)) c
    cross join lateral jsonb_array_elements(coalesce(c -> 'days', '[]'::jsonb)) d
    cross join lateral jsonb_array_elements(coalesce(d -> 'slots', '[]'::jsonb)) s
   where s ->> 'action' is not null and s ? 'dow'
     and not exists (select 1 from growth_dismissals gd
                      where gd.series_id = (s ->> 'series_id')::uuid
                        and gd.dow = (s ->> 'dow')::int and gd.expires_on > v_today);

  return query
  select o.id, o.name, o.starts_at, o.ends_at,
         (o.starts_at at time zone v_tz)::date,
         to_char(o.starts_at at time zone v_tz, 'HH24:MI'),
         to_char(o.ends_at   at time zone v_tz, 'HH24:MI'),
         (extract(hour from o.starts_at at time zone v_tz) * 60
          + extract(minute from o.starts_at at time zone v_tz))::int,
         (extract(hour from o.ends_at at time zone v_tz) * 60
          + extract(minute from o.ends_at at time zone v_tz))::int,
         o.instructor_id, r.name, o.capacity, o.booked_count, o.waitlist_count,
         o.staffing::text, o.status::text,
         o.flex, o.committed_at is not null,
         g.tier::text,
         (g.tier = 'flex' and not occurrence_is_adjacent_run(o.id)),
         coalesce(
           o.guarantee_tier,
           case when o.flex then 'flex'::guarantee_tier end,
           ser.guarantee_tier,
           case when ser.flex then 'flex'::guarantee_tier end,
           'core'::guarantee_tier)::text,
         g.minimum,
         o.cancellation_cause::text,
         o.assignment_requested_at is not null,
         o.assignment_confirmed_at is not null,
         case when coalesce(v_ff, false) then effective_free_first(o.id) else null end,
         o.hidden_from_members,
         coalesce(o.is_private, false),
         -- Decision 22(e): the running latch and the count it uses (paid seats;
         -- an unpaid drop-in does not count, Decision 81b), plus the unpaid seats.
         o.flex_reached_minimum_at is not null,
         pc.paid, pc.unpaid,
         gs.sug is not null,
         gs.sug
    from class_occurrences o
    cross join lateral (
      select count(*) filter (where not unpaid_dropin)::int as paid,
             count(*) filter (where unpaid_dropin)::int as unpaid
        from (select coalesce(b.payment_source = 'drop_in', false)
                     and not exists (select 1 from payments pmt
                                      where pmt.booking_id = b.id
                                        and pmt.status in ('succeeded','partially_refunded')) as unpaid_dropin
                from bookings b
               where b.occurrence_id = o.id
                 and b.status in ('booked','attended','no_show','pending_payment')) bb) pc
    cross join lateral occurrence_guarantee_run(o.id) g
    left join class_series ser on ser.id = o.series_id
    left join lateral (
      select case
               when o.series_id is null or o.status <> 'scheduled' or o.starts_at <= now() then null
               when sg is null then null
               -- Already the tier the review proposes: nothing to suggest.
               when coalesce(o.guarantee_tier, case when o.flex then 'flex'::guarantee_tier end,
                             ser.guarantee_tier, case when ser.flex then 'flex'::guarantee_tier end,
                             'core'::guarantee_tier)::text
                    = (sg ->> 'proposed_tier') then null
               else sg || jsonb_build_object('class_occurrence_id', o.id,
                      'budget', (select core_classes_per_week from instructors where id = o.instructor_id))
             end as sug
        from (select v_growth -> (o.series_id::text || '|'
                                  || extract(isodow from o.starts_at at time zone v_tz)::int::text) as sg) z
    ) gs on true
    left join rooms r on r.id = o.room_id
   where o.studio_id = p_studio_id
     and (o.status <> 'cancelled'
          or (not coalesce(o.is_private, false)
              and o.cancellation_cause in ('unmet_minimum','no_instructor','studio_fault','force_majeure','replaced_by_private')))
     and (o.starts_at at time zone v_tz)::date between p_from and p_to
   order by o.starts_at;
end $function$;

CREATE OR REPLACE FUNCTION public.set_series_guarantee(p_series_id uuid, p_tier guarantee_tier, p_min_bookings integer DEFAULT NULL::integer, p_core_cutoff_hours integer DEFAULT NULL::integer, p_applies_from date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare ser class_series%rowtype; n int; n_standalone int := 0;
  v_tz text; v_today date; v_from date; n_pinned int := 0;
begin
  select * into ser from class_series where id = p_series_id;
  if not found then raise exception 'no such series' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(ser.studio_id), false) then
    raise exception 'only owners and managers set a guarantee' using errcode = 'PT403';
  end if;
  if p_min_bookings is not null and p_min_bookings < 0 then
    raise exception 'a minimum cannot be negative' using errcode = 'PT422';
  end if;

  -- Decision 21 (d): a tier change applies from a date (default the studio's
  -- today). Classes before that date keep the tier they have NOW, pinned on the
  -- class (with the minimums they read today), so the series change below
  -- cannot reach them. Committed classes are never touched.
  select timezone into v_tz from studios where id = ser.studio_id;
  v_today := (now() at time zone coalesce(v_tz, 'UTC'))::date;
  v_from  := coalesce(p_applies_from, v_today);

  update class_occurrences o
     set guarantee_tier = coalesce(
           o.guarantee_tier,
           case when o.flex then 'flex'::guarantee_tier end,
           ser.guarantee_tier,
           case when ser.flex then 'flex'::guarantee_tier end,
           'core'::guarantee_tier),
         flex = (coalesce(
           o.guarantee_tier,
           case when o.flex then 'flex'::guarantee_tier end,
           ser.guarantee_tier,
           case when ser.flex then 'flex'::guarantee_tier end,
           'core'::guarantee_tier) = 'flex'),
         minimum_bookings  = coalesce(o.minimum_bookings, ser.minimum_bookings),
         core_min_bookings = coalesce(o.core_min_bookings, ser.core_min_bookings),
         updated_at = now()
   where o.series_id = p_series_id
     and o.starts_at > now()
     and o.status = 'scheduled'
     and o.committed_at is null
     and (o.starts_at at time zone coalesce(v_tz, 'UTC'))::date < v_from;
  get diagnostics n_pinned = row_count;

  update class_series
     set guarantee_tier   = p_tier,
         tier_from        = case when v_from > v_today then v_from else null end,
         flex             = (p_tier = 'flex'),
         minimum_bookings = case when p_tier = 'flex'
                                 then coalesce(p_min_bookings, minimum_bookings)
                                 else minimum_bookings end,
         core_min_bookings = case when p_tier = 'core'
                                  then coalesce(p_min_bookings, core_min_bookings)
                                  else core_min_bookings end,
         core_cutoff_hours = coalesce(p_core_cutoff_hours, core_cutoff_hours),
         updated_at = now()
   where id = p_series_id;

  update class_occurrences o
     set guarantee_tier = p_tier,
         flex           = (p_tier = 'flex'),
         minimum_bookings = case when p_tier = 'flex'
                                 then coalesce(p_min_bookings, o.minimum_bookings)
                                 else o.minimum_bookings end,
         core_min_bookings = case when p_tier = 'core'
                                  then coalesce(p_min_bookings, o.core_min_bookings)
                                  else o.core_min_bookings end,
         updated_at = now()
   where o.series_id = p_series_id
     and o.starts_at > now()
     and o.status = 'scheduled'
     and o.committed_at is null
     and (o.starts_at at time zone coalesce(v_tz, 'UTC'))::date >= v_from;
  get diagnostics n = row_count;

  -- A standalone flex slot (nothing of the instructor's beside it) is a
  -- standby-fee obligation. Reported so the editor warns rather than creating
  -- one silently; a warning, never a refusal (adjacency is dynamic).
  if p_tier = 'flex' then
    select count(*) into n_standalone
      from class_occurrences o
     where o.series_id = p_series_id
       and o.status = 'scheduled'
       and o.starts_at > now()
       and coalesce(o.flex, false)
       and not occurrence_is_adjacent_run(o.id);
  end if;

  return jsonb_build_object('ok', true, 'tier', p_tier, 'occurrences_updated', n,
                            'standalone_count', n_standalone,
                            'applies_from', v_from, 'pinned', n_pinned);
end $function$;

CREATE OR REPLACE FUNCTION public.bulk_update_series_run(p_series_ids uuid[], p_change jsonb, p_preview boolean, p_applies_from date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_studio uuid; v_type text; v_have int; v_cnt int;
  rec record; ser class_series%rowtype;
  v_res jsonb; v_bad boolean; v_reason text;
  v_cur text; v_new text; v_when text; v_day text;
  v_changed jsonb := '[]'::jsonb;
  v_refused jsonb := '[]'::jsonb;
  v_warn    jsonb := '[]'::jsonb;
  v_n_changed int := 0; v_n_refused int := 0;
  r_name text;
begin
  if p_series_ids is null or array_length(p_series_ids, 1) is null then
    raise exception 'select at least one series' using errcode = 'PT422';
  end if;

  -- One studio, every id present, and the caller manages it. A foreign or
  -- unknown id anywhere -> PT403 (never act on a partial, mixed-studio set).
  select count(distinct studio_id), (array_agg(distinct studio_id))[1] into v_cnt, v_studio
    from class_series where id = any(p_series_ids);
  if v_cnt <> 1 then
    raise exception 'those series are not all in one studio you manage' using errcode = 'PT403';
  end if;
  if not coalesce(is_manager_up(v_studio), false) then
    raise exception 'only owners and managers change the timetable' using errcode = 'PT403';
  end if;
  select count(*) into v_have from class_series
   where studio_id = v_studio and id = any(p_series_ids);
  if v_have <> (select count(distinct x) from unnest(p_series_ids) x) then
    raise exception 'those series are not all in one studio you manage' using errcode = 'PT403';
  end if;

  -- Which single change family.
  v_type := case
    when p_change ? 'tier'          then 'tier'
    when p_change ? 'room_id'       then 'room'
    when p_change ? 'ends_on'       then 'ends_on'
    when p_change ? 'starts_on'     then 'starts_on'
    when p_change ? 'instructor_id' then 'instructor'
    when p_change ? 'free_first_allowed' then 'free_first'
    when p_change ? 'minimum'       then 'minimum'
    else null end;
  if v_type is null then
    raise exception 'that is not a change this can apply' using errcode = 'PT422';
  end if;

  for rec in
    select cs.id from class_series cs
     where cs.id = any(p_series_ids)
     order by cs.name, cs.time_of_day
  loop
    select * into ser from class_series where id = rec.id;
    r_name := ser.name;

    -- "Mon 07:00": the first BYDAY of the rule plus the time. Built in SQL so the
    -- refusal sentence the UI renders carries the database's own label.
    v_day := substring(ser.rrule from 'BYDAY=([A-Z]{2})');
    v_when := trim(coalesce(
      case v_day when 'MO' then 'Mon' when 'TU' then 'Tue' when 'WE' then 'Wed'
                 when 'TH' then 'Thu' when 'FR' then 'Fri' when 'SA' then 'Sat'
                 when 'SU' then 'Sun' else '' end, '')
      || ' ' || to_char(ser.time_of_day, 'HH24:MI'));

    -- current -> new, for the preview table.
    if v_type = 'minimum' then
      v_cur := 'min ' || coalesce((case ser.guarantee_tier
                 when 'flex' then ser.minimum_bookings
                 when 'core' then ser.core_min_bookings else null end)::text, '—');
      v_new := 'min ' || (p_change ->> 'minimum');
    elsif v_type = 'tier' then
      v_cur := ser.guarantee_tier::text;
      v_new := (p_change ->> 'tier')
               || case when nullif(p_change ->> 'minimum','') is not null
                       then ' · min ' || (p_change ->> 'minimum') else '' end;
    elsif v_type = 'room' then
      v_cur := coalesce((select name from rooms where id = ser.room_id), 'no room');
      v_new := coalesce((select name from rooms where id = (p_change ->> 'room_id')::uuid), 'no room');
    elsif v_type = 'ends_on' then
      v_cur := coalesce(ser.ends_on::text, 'no end');
      v_new := coalesce(nullif(p_change ->> 'ends_on','')::date::text, 'no end');
    elsif v_type = 'starts_on' then
      v_cur := ser.starts_on::text;
      v_new := (p_change ->> 'starts_on');
    elsif v_type = 'free_first' then
      v_cur := case when ser.free_first_allowed then 'free classes on' else 'free classes off' end;
      v_new := case when (p_change ->> 'free_first_allowed')::boolean then 'free classes on' else 'free classes off' end;
    else  -- instructor
      v_cur := coalesce((select display_name from instructors where id = ser.instructor_id), 'Unassigned');
      v_new := coalesce((select display_name from instructors where id = nullif(p_change ->> 'instructor_id','')::uuid), 'Unassigned');
    end if;

    v_res := null;
    begin   -- SAVEPOINT per series
      if v_type = 'minimum' then
        v_res := set_series_guarantee(rec.id, ser.guarantee_tier, (p_change ->> 'minimum')::int, null);
      elsif v_type = 'tier' then
        v_res := set_series_guarantee(rec.id, (p_change ->> 'tier')::guarantee_tier,
                                      nullif(p_change ->> 'minimum','')::int, null, p_applies_from);
      elsif v_type = 'room' then
        v_res := update_series(rec.id, ser.name, ser.class_type_id, (p_change ->> 'room_id')::uuid,
                   ser.instructor_id, ser.capacity, ser.duration_minutes, ser.rrule,
                   ser.starts_on, ser.ends_on, ser.time_of_day, ser.description, null, true);
      elsif v_type = 'ends_on' then
        v_res := update_series(rec.id, ser.name, ser.class_type_id, ser.room_id,
                   ser.instructor_id, ser.capacity, ser.duration_minutes, ser.rrule,
                   ser.starts_on, nullif(p_change ->> 'ends_on','')::date, ser.time_of_day,
                   ser.description, null, true);
      elsif v_type = 'starts_on' then
        v_res := update_series(rec.id, ser.name, ser.class_type_id, ser.room_id,
                   ser.instructor_id, ser.capacity, ser.duration_minutes, ser.rrule,
                   (p_change ->> 'starts_on')::date, ser.ends_on, ser.time_of_day,
                   ser.description, null, true);
      elsif v_type = 'free_first' then
        -- Decision 30 amendment: free_first_allowed is NOT a materialise-trigger
        -- column, so a direct template write touches no occurrence and fires no
        -- trigger — no series_editing flag needed.
        update class_series set free_first_allowed = (p_change ->> 'free_first_allowed')::boolean,
               updated_at = now() where id = rec.id;
        v_res := jsonb_build_object('ok', true);
      else  -- instructor: template only, zero occurrences touched (42a/43).
        -- instructor_id is a materialise-trigger column, so suppress the trigger
        -- (series_editing) — the write must touch no occurrence, not generate.
        perform set_config('studiior.series_editing', 'on', true);
        update class_series set instructor_id = nullif(p_change ->> 'instructor_id','')::uuid,
               updated_at = now() where id = rec.id;
        perform set_config('studiior.series_editing', 'off', true);
        v_res := jsonb_build_object('ok', true);
      end if;

      -- Refused: the function said no, or (a room change) left a per-occurrence
      -- clash — all-or-nothing per series in a batch, so the whole series rolls
      -- back and is listed.
      v_bad := (not coalesce((v_res ->> 'ok')::boolean, true))
            or (jsonb_array_length(coalesce(v_res -> 'conflicts', '[]'::jsonb)) > 0);

      if p_preview or v_bad then
        raise exception 'discard' using errcode = 'PT000';
      end if;

      -- Apply, kept.
      v_changed := v_changed || jsonb_build_object('series_id', rec.id, 'name', r_name,
                     'when', v_when, 'current', v_cur, 'new', v_new);
      v_n_changed := v_n_changed + 1;
      if coalesce((v_res ->> 'standalone_count')::int, 0) > 0 then
        v_warn := v_warn || jsonb_build_object('series_id', rec.id, 'code', 'standalone_flex');
      end if;

    exception
      when sqlstate 'PT000' then
        -- Our own forced rollback. v_res holds what the function returned.
        if (not coalesce((v_res ->> 'ok')::boolean, true))
           or (jsonb_array_length(coalesce(v_res -> 'conflicts', '[]'::jsonb)) > 0) then
          v_reason := case
            when jsonb_array_length(coalesce(v_res -> 'conflicts', '[]'::jsonb)) > 0
                 then 'the room is taken on some of its classes'
            when (v_res ->> 'reason') = 'members_booked_on_dropped_classes' and v_type = 'starts_on'
                 then 'earlier classes have bookings'
            when (v_res ->> 'reason') = 'members_booked_on_dropped_classes'
                 then 'later classes have bookings'
            else coalesce(v_res ->> 'reason', 'refused') end;
          v_refused := v_refused || jsonb_build_object('series_id', rec.id, 'name', r_name,
                         'when', v_when, 'reason', v_reason);
          v_n_refused := v_n_refused + 1;
        else
          -- Preview: this one WOULD change (nothing kept).
          v_changed := v_changed || jsonb_build_object('series_id', rec.id, 'name', r_name,
                         'when', v_when, 'current', v_cur, 'new', v_new);
          v_n_changed := v_n_changed + 1;
          if coalesce((v_res ->> 'standalone_count')::int, 0) > 0 then
            v_warn := v_warn || jsonb_build_object('series_id', rec.id, 'code', 'standalone_flex');
          end if;
        end if;
      when others then
        -- The single-series function itself raised (bad input, locked studio …).
        v_reason := case
          when sqlstate = 'PT402' then 'this studio''s subscription is not active'
          when sqlstate = 'PT422' then 'that change is not allowed for this series'
          else coalesce(sqlerrm, 'refused') end;
        v_refused := v_refused || jsonb_build_object('series_id', rec.id, 'name', r_name,
                       'when', v_when, 'reason', v_reason);
        v_n_refused := v_n_refused + 1;
    end;
  end loop;

  -- One batch audit line on apply (the single-series functions write their own
  -- rows; this records the batch and its counts).
  if not p_preview then
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (v_studio, auth.uid(), 'series.bulk_updated', 'class_series', v_studio,
            jsonb_build_object('change', p_change, 'change_type', v_type,
                               'changed', v_n_changed, 'refused', v_n_refused,
                               'series', p_series_ids));
  end if;

  return jsonb_build_object('ok', true, 'preview', p_preview, 'change_type', v_type,
                            'changed', v_changed, 'refused', v_refused, 'warnings', v_warn);
end $function$;

CREATE OR REPLACE FUNCTION public.bulk_update_series(p_series_ids uuid[], p_change jsonb, p_preview boolean DEFAULT true, p_applies_from date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return bulk_update_series_run(p_series_ids, p_change, p_preview, p_applies_from);
end $function$;

CREATE OR REPLACE FUNCTION public.update_series(p_series_id uuid, p_name text, p_class_type_id uuid, p_room_id uuid, p_instructor_id uuid, p_capacity integer, p_duration_minutes integer, p_rrule text, p_starts_on date, p_ends_on date, p_time_of_day time without time zone, p_description text, p_effective_from date DEFAULT NULL::date, p_confirm boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  ser         class_series%rowtype;
  v_tz        text;
  v_today     date;
  v_from      date;
  v_to        date;
  v_days_out  int;
  v_slot_day  date;
  v_new_start timestamptz;
  v_new_end   timestamptz;
  r           record;
  v_move      jsonb;
  v_moves     int := 0;
  -- What the APPLY loop actually did, as opposed to what the preview predicted.
  v_did_move    int := 0;
  v_did_cancel  int := 0;
  v_did_restore int := 0;
  v_drift       int := 0;
  v_cancels   int := 0;
  v_restores  int := 0;
  v_same      int := 0;
  v_adds      int := 0;
  v_exc       int := 0;
  v_emails    int := 0;
  v_blocked   jsonb := '[]'::jsonb;
  v_overcap   jsonb := '[]'::jsonb;
  v_conf      jsonb := '[]'::jsonb;
  v_clear_i   boolean;
  v_push_i    boolean;
  d           date;
  v_gen       jsonb;
  v_narrow    boolean;
  v_drop      int := 0;
begin
  select * into ser from class_series where id = p_series_id for update;
  if not found then
    raise exception 'no such series' using errcode = 'PT404';
  end if;
  if not is_manager_up(ser.studio_id) then
    raise exception 'only owners and managers change the timetable'
      using errcode = 'PT403';
  end if;
  if studio_is_locked(ser.studio_id) then
    raise exception 'this studio''s Studiior subscription is not active'
      using errcode = 'PT402',
            hint = 'Reactivate it from Billing. Nothing has been deleted.';
  end if;

  if coalesce(btrim(p_name), '') = '' then
    raise exception 'a series needs a name' using errcode = 'PT400';
  end if;
  if p_capacity < 1 then
    raise exception 'capacity must be at least 1' using errcode = 'PT400';
  end if;
  if p_duration_minutes < 1 then
    raise exception 'a class must last at least a minute' using errcode = 'PT400';
  end if;
  if p_ends_on is not null and p_ends_on < p_starts_on then
    raise exception 'a series cannot end before it starts' using errcode = 'PT400';
  end if;
  -- Raises PT422 on FREQ=MONTHLY, a missing BYDAY, an unrecognised day or a
  -- COUNT/INTERVAL below one. Better here, where somebody is holding a mouse,
  -- than inside the trigger at 03:10 the next morning.
  perform rrule_last_date(p_rrule, p_starts_on);

  select timezone into v_tz from studios where id = ser.studio_id;
  v_today := (now() at time zone v_tz)::date;
  -- The past is not editable. Default tomorrow rather than today so an edit made
  -- at 18:00 cannot retime this morning's 07:00 class, which has already run.
  v_from := greatest(coalesce(p_effective_from, v_today + 1), v_today);

  -- Migration 068: days, not months, and 60 rather than 12.
  select coalesce(occurrence_horizon_days, 60) into v_days_out
    from studio_settings where studio_id = ser.studio_id;
  v_days_out := coalesce(v_days_out, 60);
  v_to := least(
    v_today + v_days_out,
    coalesce(p_ends_on, 'infinity'::date),
    coalesce(rrule_last_date(p_rrule, p_starts_on), 'infinity'::date));

  -- ---------------------------------------------------------------------------
  -- Series end-date fix (21 Nov 2026, note under Decision 42b). When the ONLY
  -- thing that changed is the end date, set it and cancel the series' classes
  -- after it, nothing else: the template is never replayed over earlier dates,
  -- so a class staff moved off its series time stays where staff put it. A
  -- later end date also brings back classes an earlier end cancelled (nobody
  -- booked) and fills the newly allowed dates. Classes after the new end with
  -- members booked refuse the change, exactly as the full path does.
  -- ---------------------------------------------------------------------------
  v_narrow := btrim(p_name) = ser.name
    and p_class_type_id = ser.class_type_id
    and p_room_id is not distinct from ser.room_id
    and p_instructor_id is not distinct from ser.instructor_id
    and p_capacity = ser.capacity
    and p_duration_minutes = ser.duration_minutes
    and p_rrule = ser.rrule
    and p_starts_on = ser.starts_on
    and p_time_of_day = ser.time_of_day
    and nullif(btrim(coalesce(p_description,'')), '') is not distinct from ser.description
    and p_ends_on is distinct from ser.ends_on;

  if v_narrow then
    for r in
      select o.id, o.starts_at, o.booked_count
        from class_occurrences o
       where o.series_id = p_series_id
         and o.status = 'scheduled'
         and p_ends_on is not null
         and (o.starts_at at time zone v_tz)::date > p_ends_on
         and (o.starts_at at time zone v_tz)::date >= v_today
       order by o.starts_at
    loop
      if r.booked_count > 0 then
        v_blocked := v_blocked || jsonb_build_object(
          'occurrence_id', r.id,
          'local', to_char(r.starts_at at time zone v_tz, 'FMDay FMDD FMMon, HH24:MI'),
          'booked', r.booked_count);
      else
        v_cancels := v_cancels + 1;
      end if;
    end loop;
    -- A later end: the classes an earlier end cancelled (nobody booked, no
    -- other cause) come back.
    select count(*) into v_restores
      from class_occurrences o
     where o.series_id = p_series_id
       and o.status = 'cancelled' and o.cancellation_cause is null
       and o.booked_count = 0
       and (o.starts_at at time zone v_tz)::date >= v_today
       and (ser.ends_on is not null and (o.starts_at at time zone v_tz)::date > ser.ends_on)
       and (p_ends_on is null or (o.starts_at at time zone v_tz)::date <= p_ends_on);

    if jsonb_array_length(v_blocked) > 0 then
      return jsonb_build_object(
        'ok', false, 'reason', 'members_booked_on_dropped_classes',
        'blocked', v_blocked, 'effective_from', v_from);
    end if;
    if not p_confirm then
      return jsonb_build_object(
        'ok', false, 'requires_confirmation', true,
        'effective_from', v_from,
        'will_move', 0, 'will_cancel', v_cancels, 'will_add', 0,
        'will_restore', v_restores, 'unchanged', 0, 'left_as_edited', 0,
        'members_emailed', 0, 'horizon_to', v_to, 'end_date_only', true);
    end if;

    perform set_config('studiior.series_editing', 'on', true);
    update class_series set ends_on = p_ends_on, updated_at = now() where id = p_series_id;
    update class_occurrences o
       set status = 'cancelled', updated_at = now()
     where o.series_id = p_series_id
       and o.status = 'scheduled'
       and p_ends_on is not null
       and (o.starts_at at time zone v_tz)::date > p_ends_on
       and (o.starts_at at time zone v_tz)::date >= v_today
       and o.booked_count = 0;
    get diagnostics v_did_cancel = row_count;
    for r in
      select o.id, o.starts_at
        from class_occurrences o
       where o.series_id = p_series_id
         and o.status = 'cancelled' and o.cancellation_cause is null
         and o.booked_count = 0
         and (o.starts_at at time zone v_tz)::date >= v_today
         and (ser.ends_on is not null and (o.starts_at at time zone v_tz)::date > ser.ends_on)
         and (p_ends_on is null or (o.starts_at at time zone v_tz)::date <= p_ends_on)
    loop
      begin
        update class_occurrences set status = 'scheduled', updated_at = now() where id = r.id;
        v_did_restore := v_did_restore + 1;
      exception when exclusion_violation then
        v_conf := v_conf || jsonb_build_object(
          'occurrence_id', r.id,
          'local', to_char(r.starts_at at time zone v_tz, 'YYYY-MM-DD HH24:MI'),
          'reason', case when sqlerrm like '%occ_room_no_overlap%' then 'room_busy' else 'instructor_busy' end);
      end;
    end loop;
    perform set_config('studiior.series_editing', 'off', true);

    -- Only a later end can add classes; a shorter one never generates.
    if p_ends_on is null or (ser.ends_on is not null and p_ends_on > ser.ends_on) then
      v_gen := generate_occurrences(p_series_id, null, greatest(v_from, coalesce(ser.ends_on + 1, v_from)));
    end if;

    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
    values (ser.studio_id, auth.uid(), 'series.updated', 'class_series', p_series_id,
            jsonb_build_object('ends_on', ser.ends_on),
            jsonb_build_object('ends_on', p_ends_on, 'end_date_only', true,
                               'applied', jsonb_build_object('cancel', v_did_cancel, 'restore', v_did_restore)));

    return jsonb_build_object(
      'ok', true, 'effective_from', v_from, 'end_date_only', true,
      'moved', 0, 'cancelled', v_did_cancel, 'restored', v_did_restore,
      'added', coalesce((v_gen ->> 'created')::int, 0),
      'predicted', jsonb_build_object('moved', 0, 'cancelled', v_cancels, 'restored', v_restores),
      'still_out_of_step', 0, 'unchanged', 0, 'left_as_edited', 0, 'members_emailed', 0,
      'conflicts', v_conf || coalesce(v_gen -> 'conflicts', '[]'::jsonb));
  end if;

  -- ---------------------------------------------------------------------------
  -- What the edit would do to what already exists
  -- ---------------------------------------------------------------------------
  -- Cancelled rows are in scope, and that is not tidiness. Dropping Monday
  -- cancels fifty-two classes and the row goes on holding its slot, so putting
  -- Monday back would generate nothing and the studio's Monday would stay empty
  -- for a year with no error anywhere. Only ones nobody was booked on come
  -- back: a class a member was TOLD was cancelled is not something an edit to a
  -- rule may quietly reinstate.
  for r in
    select o.id, o.starts_at, o.ends_at, o.series_slot_at, o.booked_count,
           o.instructor_id, o.room_id, o.assigned_by, o.name, o.status,
           (o.series_slot_at at time zone v_tz)::date as slot_day
      from class_occurrences o
     where o.series_id = p_series_id
       and o.status in ('scheduled','cancelled')
       and o.series_slot_at is not null
       and (o.series_slot_at at time zone v_tz)::date >= v_from
     order by o.series_slot_at
  loop
    -- §5: an occurrence somebody has already moved is theirs. It keeps its own
    -- time and is not counted against the edit either way.
    if exists (select 1 from class_occurrences x
                where x.id = r.id and x.is_exception) then
      v_exc := v_exc + 1;
      continue;
    end if;

    v_slot_day := r.slot_day;

    if series_rule_matches(p_rrule, p_starts_on, p_ends_on, v_slot_day) then
      if r.status = 'cancelled' then
        if r.booked_count = 0 then v_restores := v_restores + 1; end if;
        continue;
      end if;

      -- §5 again, and the reason capacity is checked before anything moves: the
      -- system never silently picks who loses their spot.
      if p_capacity < r.booked_count then
        v_overcap := v_overcap || jsonb_build_object(
          'occurrence_id', r.id,
          'local', to_char(r.starts_at at time zone v_tz, 'FMDay FMDD FMMon, HH24:MI'),
          'booked', r.booked_count);
      end if;

      v_new_start := (v_slot_day + p_time_of_day) at time zone v_tz;
      v_new_end   := v_new_start + make_interval(mins => p_duration_minutes);
      if v_new_start <> r.starts_at or v_new_end <> r.ends_at
         or p_room_id is distinct from r.room_id then
        v_moves  := v_moves + 1;
        v_emails := v_emails + case when v_new_start <> r.starts_at
                                    then r.booked_count else 0 end;
      else
        v_same := v_same + 1;
      end if;
    else
      -- The new rule does not produce this day any more.
      if r.status = 'cancelled' then
        continue;                       -- already gone; nothing to do or report
      elsif r.booked_count > 0 then
        v_blocked := v_blocked || jsonb_build_object(
          'occurrence_id', r.id,
          'local', to_char(r.starts_at at time zone v_tz, 'FMDay FMDD FMMon, HH24:MI'),
          'booked', r.booked_count);
      else
        v_cancels := v_cancels + 1;
      end if;
    end if;
  end loop;

  -- Recurrences the new rule adds that nothing holds yet.
  d := greatest(v_from, p_starts_on);
  while d <= v_to loop
    if series_rule_matches(p_rrule, p_starts_on, p_ends_on, d)
       and not exists (
         select 1 from class_occurrences o
          where o.series_id = p_series_id
            and (o.series_slot_at at time zone v_tz)::date = d) then
      v_adds := v_adds + 1;
    end if;
    d := d + 1;
  end loop;

  -- ---------------------------------------------------------------------------
  -- Refusals that hold whether or not the studio confirmed
  -- ---------------------------------------------------------------------------
  if jsonb_array_length(v_blocked) > 0 then
    return jsonb_build_object(
      'ok', false, 'reason', 'members_booked_on_dropped_classes',
      'blocked', v_blocked, 'effective_from', v_from);
  end if;
  if jsonb_array_length(v_overcap) > 0 then
    return jsonb_build_object(
      'ok', false, 'reason', 'capacity_below_booked',
      'over_capacity', v_overcap, 'capacity', p_capacity,
      'effective_from', v_from);
  end if;

  if not p_confirm then
    return jsonb_build_object(
      'ok', false, 'requires_confirmation', true,
      'effective_from', v_from,
      'will_move', v_moves, 'will_cancel', v_cancels, 'will_add', v_adds,
      'will_restore', v_restores,
      'unchanged', v_same, 'left_as_edited', v_exc,
      'members_emailed', v_emails,
      'horizon_to', v_to);
  end if;

  -- ---------------------------------------------------------------------------
  -- Apply
  -- ---------------------------------------------------------------------------
  perform set_config('studiior.series_editing', 'on', true);

  update class_series
     set name = btrim(p_name), class_type_id = p_class_type_id,
         room_id = p_room_id, instructor_id = p_instructor_id,
         capacity = p_capacity, duration_minutes = p_duration_minutes,
         rrule = p_rrule, starts_on = p_starts_on, ends_on = p_ends_on,
         time_of_day = p_time_of_day, description = nullif(btrim(coalesce(p_description,'')), ''),
         updated_at = now()
   where id = p_series_id;

  -- The series' instructor is the DEFAULT for the classes it makes, not an
  -- override of decisions already taken about them. It is pushed only when it
  -- actually changed, and never onto an occurrence a human assigned — 061's
  -- rule that `assigned_by` marks a person choosing a person.
  v_push_i  := p_instructor_id is distinct from ser.instructor_id;
  v_clear_i := v_push_i and p_instructor_id is null;

  for r in
    select o.id, o.starts_at, o.ends_at, o.booked_count, o.room_id,
           o.assigned_by, o.is_exception, o.status,
           (o.series_slot_at at time zone v_tz)::date as slot_day
      from class_occurrences o
     where o.series_id = p_series_id
       and o.status in ('scheduled','cancelled')
       and o.series_slot_at is not null
       and not o.is_exception
       and (o.series_slot_at at time zone v_tz)::date >= v_from
     order by o.series_slot_at
  loop
    if series_rule_matches(p_rrule, p_starts_on, p_ends_on, r.slot_day) then
      v_new_start := (r.slot_day + p_time_of_day) at time zone v_tz;
      v_new_end   := v_new_start + make_interval(mins => p_duration_minutes);

      -- Bringing a cancelled slot back. Not through move_occurrence(), which
      -- refuses a cancelled class outright and would have nobody to email
      -- anyway; the room and instructor exclusions only start applying again at
      -- the moment status leaves 'cancelled', so this is the one place they can
      -- bite on a row that is merely being restored.
      if r.status = 'cancelled' then
        if r.booked_count = 0 then
          begin
            update class_occurrences
               set status = 'scheduled', starts_at = v_new_start, ends_at = v_new_end,
                   series_slot_at = v_new_start, room_id = p_room_id,
                   updated_at = now()
             where id = r.id;
            v_did_restore := v_did_restore + 1;
          exception when exclusion_violation then
            v_conf := v_conf || jsonb_build_object(
              'occurrence_id', r.id,
              'local', to_char(v_new_start at time zone v_tz, 'YYYY-MM-DD HH24:MI'),
              'reason', case when sqlerrm like '%occ_room_no_overlap%'
                             then 'room_busy' else 'instructor_busy' end);
          end;
        end if;
        continue;
      end if;

      if v_new_start <> r.starts_at or v_new_end <> r.ends_at
         or p_room_id is distinct from r.room_id
         or (v_push_i and r.assigned_by is null) then
        -- Through move_occurrence(), which is the only thing that moves a
        -- class: it owes Decision 2's free cancellation on a significant move
        -- and the class_moved email, and a second implementation of that here
        -- would agree with it exactly once.
        v_move := move_occurrence(
          r.id, v_new_start, v_new_end,
          case when v_push_i and r.assigned_by is null then p_instructor_id end,
          p_room_id, true,
          v_clear_i and r.assigned_by is null);
        if coalesce((v_move ->> 'ok')::boolean, false) then
          -- The row keeps holding the recurrence it now materialises. Without
          -- this the nightly job sees the new slot standing empty and fills it,
          -- and the studio has two classes where it made one.
          update class_occurrences
             set series_slot_at = v_new_start
           where id = r.id;
          v_did_move := v_did_move + 1;
        else
          v_conf := v_conf || jsonb_build_object(
            'occurrence_id', r.id,
            'local', to_char(v_new_start at time zone v_tz, 'YYYY-MM-DD HH24:MI'),
            'reason', coalesce(v_move ->> 'reason', 'refused'),
            'detail', v_move -> 'clash_with');
        end if;
      end if;
    elsif r.status = 'scheduled' then
      -- Nobody is booked: checked above, and the check is what makes this safe.
      update class_occurrences
         set status = 'cancelled', updated_at = now()
       where id = r.id;
      v_did_cancel := v_did_cancel + 1;
    end if;
  end loop;

  -- Fields that are not timing, on everything the edit reaches — including the
  -- occurrences that did not move. Editing capacity used to change the series
  -- and leave every materialised class on the old number, which is the half of
  -- this bug that looks like nothing happening.
  update class_occurrences o
     set name = btrim(p_name), class_type_id = p_class_type_id,
         description = nullif(btrim(coalesce(p_description,'')), ''),
         capacity = p_capacity, updated_at = now()
   where o.series_id = p_series_id
     and o.status = 'scheduled'
     and not o.is_exception
     and o.series_slot_at is not null
     and (o.series_slot_at at time zone v_tz)::date >= v_from;
  -- 'scheduled' only, and after the loop above, so a slot restored in this same
  -- edit picks up the new name and capacity too.

  perform set_config('studiior.series_editing', 'off', true);

  -- Now, and only now, materialise what the new rule adds.
  v_gen := generate_occurrences(p_series_id, null, v_from);

  -- THE POST-CONDITION. Everything above reports what each step believed it was
  -- doing; this asks the calendar. A studio that edits a series and sees it
  -- unchanged has no way to tell that from success, and until now neither did
  -- this function — it returned the PREVIEW's counters whatever the apply loop
  -- managed, so an edit that moved nothing still answered "19 moved".
  select count(*) into v_drift
    from class_occurrences o
   where o.series_id = p_series_id
     and o.status = 'scheduled'
     and not o.is_exception
     and o.series_slot_at is not null
     and (o.series_slot_at at time zone v_tz)::date >= v_from
     and o.starts_at <> (((o.series_slot_at at time zone v_tz)::date + p_time_of_day)
                         at time zone v_tz);

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (ser.studio_id, auth.uid(), 'series.updated', 'class_series', p_series_id,
          jsonb_build_object('time_of_day', ser.time_of_day, 'rrule', ser.rrule,
                             'starts_on', ser.starts_on, 'ends_on', ser.ends_on,
                             'capacity', ser.capacity, 'room_id', ser.room_id,
                             'instructor_id', ser.instructor_id),
          jsonb_build_object('time_of_day', p_time_of_day, 'rrule', p_rrule,
                             'starts_on', p_starts_on, 'ends_on', p_ends_on,
                             'capacity', p_capacity, 'room_id', p_room_id,
                             'instructor_id', p_instructor_id,
                             'effective_from', v_from,
                             'predicted', jsonb_build_object('move', v_moves, 'cancel', v_cancels,
                                            'restore', v_restores),
                             'applied', jsonb_build_object('move', v_did_move, 'cancel', v_did_cancel,
                                            'restore', v_did_restore),
                             'still_out_of_step', v_drift));

  return jsonb_build_object(
    'ok', true,
    'effective_from', v_from,
    -- WHAT HAPPENED, not what was predicted.
    'moved', v_did_move, 'cancelled', v_did_cancel, 'restored', v_did_restore,
    'added', coalesce((v_gen ->> 'created')::int, 0),
    'predicted', jsonb_build_object('moved', v_moves, 'cancelled', v_cancels,
                                    'restored', v_restores),
    'still_out_of_step', v_drift,
    'unchanged', v_same, 'left_as_edited', v_exc,
    'members_emailed', v_emails,
    'conflicts', v_conf || coalesce(v_gen -> 'conflicts', '[]'::jsonb));
end $function$;

CREATE OR REPLACE FUNCTION public.assign_instructors_run(p_studio_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_dry_run boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_tz text;
  o record;
  cand record;
  v_from date; v_to date;
  v_local date;
  v_week date;
  v_picked uuid;
  v_picked_name text;
  n_assigned int := 0;
  n_open int := 0;
  v_log jsonb := '[]'::jsonb;
  v_prev uuid; v_next uuid;
begin
  select timezone into v_tz from studios where id = p_studio_id;
  if v_tz is null then
    raise exception 'no such studio' using errcode = 'PT404';
  end if;

  v_from := coalesce(p_from, (now() at time zone v_tz)::date);
  v_to   := coalesce(p_to, (v_from + interval '3 months')::date);

  -- The engine's own writes must not look like a human's.
  perform set_config('studiior.assigning', '1', true);

  -- Decision 19: the run's own picks, kept in memory so a DRY RUN sees what it
  -- has already given out (adjacency, the weekly count, double-booking) exactly
  -- as the real run, whose picks are also written to the table.
  if to_regclass('pg_temp._fill_picks') is not null then drop table _fill_picks; end if;
  create temp table _fill_picks (occ_id uuid, instructor_id uuid, room_id uuid,
                                 starts_at timestamptz, ends_at timestamptz,
                                 local_date date, week date) on commit drop;

  for o in
    select c.id, c.class_type_id, c.starts_at, c.ends_at, c.name, c.booked_count, c.room_id
      from class_occurrences c
     where c.studio_id = p_studio_id
       and c.status = 'scheduled'
       and c.staffing = 'open'
       -- OVERRIDE ALWAYS WINS. A class a person has touched is never revisited.
       and c.assigned_by is null
       and (c.starts_at at time zone v_tz)::date between v_from and v_to
     order by c.starts_at, c.id
  loop
    v_local := (o.starts_at at time zone v_tz)::date;
    v_week  := date_trunc('week', v_local)::date;
    v_picked := null; v_picked_name := null;

    -- Decision 19: the coach of the class immediately before and after this one
    -- in the same room that day (a coach given out earlier in this run counts).
    v_prev := null; v_next := null;
    if o.room_id is not null then
      select coalesce(n.instructor_id, (select p.instructor_id from _fill_picks p where p.occ_id = n.id))
        into v_prev
        from class_occurrences n
       where n.room_id = o.room_id and n.id <> o.id and n.status <> 'cancelled'
         and (n.starts_at at time zone v_tz)::date = v_local
         and n.starts_at < o.starts_at
       order by n.starts_at desc limit 1;
      select coalesce(n.instructor_id, (select p.instructor_id from _fill_picks p where p.occ_id = n.id))
        into v_next
        from class_occurrences n
       where n.room_id = o.room_id and n.id <> o.id and n.status <> 'cancelled'
         and (n.starts_at at time zone v_tz)::date = v_local
         and n.starts_at > o.starts_at
       order by n.starts_at asc limit 1;
    end if;

    select i.id, i.display_name, x.this_week, x.adjacent
      into cand
      from instructors i
      join lateral (
        -- The whole ranking input: how many classes this person already has
        -- that week. NOT measured against their commitment — that agreement is
        -- how the studio reviews them, not how the studio staffs a Tuesday.
        select (select count(*)::int from class_occurrences w
                 where w.instructor_id = i.id
                   and w.status <> 'cancelled'
                   and date_trunc('week', (w.starts_at at time zone v_tz)::date)::date = v_week
               ) + (select count(*)::int from _fill_picks fp
                     where fp.instructor_id = i.id and fp.week = v_week
                       and not exists (select 1 from class_occurrences w2
                                        where w2.id = fp.occ_id and w2.instructor_id = i.id)) as this_week,
               (i.id = v_prev or i.id = v_next) as adjacent
      ) x on true
     where i.studio_id = p_studio_id
       and i.status = 'active'
       -- (a) qualified. An empty mapping means nothing, not everything.
       and instructor_qualified(i.id, o.class_type_id)
       -- (b) inside their validity window AND free at that time. Both hard for
       --     the engine; the window is hard for humans too.
       and instructor_valid_on(i.id, v_local)
       and instructor_available_at(i.id, o.starts_at, o.ends_at)
       -- (c) not already teaching. Rows assigned earlier in this same run are
       --     already visible here, so two occurrences cannot take one person.
       and not exists (
         select 1 from class_occurrences b
          where b.instructor_id = i.id
            and b.status <> 'cancelled'
            and tstzrange(b.starts_at, b.ends_at) && tstzrange(o.starts_at, o.ends_at))
       and not exists (
         select 1 from _fill_picks fp
          where fp.instructor_id = i.id
            and tstzrange(fp.starts_at, fp.ends_at) && tstzrange(o.starts_at, o.ends_at))
     -- Deterministic, so a re-run is stable: fewest classes, then the id. The
     -- id is arbitrary and that is the point — it is STABLE.
     -- Decision 19: the coach already teaching the class before or after in this
     -- room first, then the fewest classes that week, then the stable id.
     order by coalesce(x.adjacent, false) desc, x.this_week asc, i.id asc
     limit 1;

    if cand.id is null then
      n_open := n_open + 1;
      v_log := v_log || jsonb_build_object(
        'occurrence_id', o.id, 'class', o.name,
        'when', to_char(o.starts_at at time zone v_tz, 'YYYY-MM-DD HH24:MI'),
        'outcome', 'left_open',
        'why', case
          when not exists (select 1 from instructor_class_types t
                            where t.studio_id = p_studio_id and t.class_type_id = o.class_type_id)
            then 'nobody is down to teach this class type'
          when not exists (select 1 from instructors i
                            where i.studio_id = p_studio_id and i.status = 'active'
                              and instructor_qualified(i.id, o.class_type_id)
                              and instructor_valid_on(i.id, v_local))
            then 'everybody qualified is outside their availability dates for this day'
          when not exists (select 1 from instructors i
                            where i.studio_id = p_studio_id and i.status = 'active'
                              and instructor_qualified(i.id, o.class_type_id)
                              and instructor_valid_on(i.id, v_local)
                              and instructor_available_at(i.id, o.starts_at, o.ends_at))
            then 'nobody qualified has said they are free at this time'
          else 'everybody qualified and free is already teaching then' end,
        'booked', o.booked_count);
      continue;
    end if;

    v_picked := cand.id; v_picked_name := cand.display_name;
    insert into _fill_picks values (o.id, v_picked, o.room_id, o.starts_at, o.ends_at, v_local, v_week);

    if not p_dry_run then
      update class_occurrences
         set instructor_id = v_picked, staffing = 'assigned', updated_at = now()
       where id = o.id;
      perform queue_instructor_assigned(o.id);
    end if;
    n_assigned := n_assigned + 1;

    v_log := v_log || jsonb_build_object(
      'occurrence_id', o.id, 'class', o.name,
      'when', to_char(o.starts_at at time zone v_tz, 'YYYY-MM-DD HH24:MI'),
      'outcome', 'assigned',
      'instructor', v_picked_name,
      -- The working: why this person and not the other one. One sentence now,
      -- because there is one rule.
      'why', case when coalesce(cand.adjacent, false) then 'continues their block'
                  else format('%s classes that week, fewest of the candidates', cand.this_week) end);
  end loop;

  if not p_dry_run then
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (p_studio_id, auth.uid(), 'occurrences.assigned', 'studios', p_studio_id,
            jsonb_build_object('from', v_from, 'to', v_to,
                               'assigned', n_assigned, 'left_open', n_open));
  end if;

  return jsonb_build_object(
    'ok', true, 'dry_run', p_dry_run,
    'from', v_from, 'to', v_to,
    'assigned', n_assigned, 'left_open', n_open,
    'detail', v_log);
end $function$;

-- --------------------------------------------------------------- grants ----
revoke all on function staff_mark_attended(uuid, text) from public, anon;
grant execute on function staff_mark_attended(uuid, text) to authenticated, service_role;
revoke all on function mark_present(uuid) from public, anon;
grant execute on function mark_present(uuid) to authenticated, service_role;
revoke all on function growth_dismiss(uuid) from public, anon;
grant execute on function growth_dismiss(uuid) to authenticated, service_role;
revoke all on function growth_number_word(int) from public, anon, authenticated;
grant execute on function growth_number_word(int) to service_role;
revoke all on function growth_insights(uuid, date) from public, anon, authenticated;
grant execute on function growth_insights(uuid, date) to service_role;
revoke all on function growth_apply(uuid, text, text, boolean) from public, anon;
grant execute on function growth_apply(uuid, text, text, boolean) to authenticated, service_role;
revoke all on function set_instructor_core_budget(uuid, integer) from public, anon;
grant execute on function set_instructor_core_budget(uuid, integer) to authenticated, service_role;
revoke all on function seed_instructor_core_budgets(uuid) from public, anon, authenticated;
grant execute on function seed_instructor_core_budgets(uuid) to service_role;
revoke all on function schedule_range(uuid, date, date) from public, anon;
grant execute on function schedule_range(uuid, date, date) to authenticated, service_role;
revoke all on function set_series_guarantee(uuid, guarantee_tier, integer, integer, date) from public, anon;
grant execute on function set_series_guarantee(uuid, guarantee_tier, integer, integer, date) to authenticated, service_role;
revoke all on function bulk_update_series(uuid[], jsonb, boolean, date) from public, anon;
grant execute on function bulk_update_series(uuid[], jsonb, boolean, date) to authenticated, service_role;
revoke all on function bulk_update_series_run(uuid[], jsonb, boolean, date) from public, anon, authenticated;
grant execute on function bulk_update_series_run(uuid[], jsonb, boolean, date) to service_role;
revoke all on function assign_instructors_run(uuid, date, date, boolean) from public, anon, authenticated;
grant execute on function assign_instructors_run(uuid, date, date, boolean) to service_role;

do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 14 then raise exception 'anon surface is % not 14', n; end if;
  if has_table_privilege('anon', 'growth_dismissals', 'select') then
    raise exception 'growth_dismissals is open to anon';
  end if;
end $$;
