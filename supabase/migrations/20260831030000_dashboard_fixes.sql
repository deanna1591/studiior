-- =============================================================================
-- Migration 093 — three things the dashboard got wrong on real data
--
-- Fixing forward: 091 and 092 are applied on hosted and an applied migration is
-- immutable. This project has broken that rule three times (062, 070, 075) and
-- twice the symptom appeared weeks later as a screen rendering nothing.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. THE ACTIVITY FEED READ A STATUS AS THOUGH IT WERE A THING
--
-- "Deanna Sallao paid for Paid."
--
-- A timeline row's `title` is a NOUN for some types and a PHRASE for others,
-- and migration 021 has always known which: an `attended` row titles itself
-- with the class, a `payment` row titles itself with its STATUS — 'Paid',
-- 'Payment failed', 'Refunded' — and puts what was actually bought in
-- `description`, with the amount and the status in `metadata`.
--
-- This reader selected the title and dropped both. So the one row that carries
-- a plan name and a sum of money rendered as the word "Paid".
--
-- The columns were always there. Nothing new is derived; the reader stops
-- discarding what the writer wrote.
-- -----------------------------------------------------------------------------
create or replace function dashboard_activity(p_studio_id uuid, p_limit int default 12)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_rows jsonb; v_ever int;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'the activity feed is for owners and managers' using errcode = 'PT403';
  end if;

  select count(*) into v_ever from timeline_events where studio_id = p_studio_id;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.occurred_at desc), '[]'::jsonb)
    into v_rows from (
    select te.id, te.type, te.title, te.description, te.occurred_at,
           te.member_id, m.first_name || ' ' || m.last_name as member_name,
           '/members/' || te.member_id as href,
           -- The AMOUNT and the STATUS, which migration 021 has always put in
           -- the metadata and this reader was throwing away.
           (te.metadata ->> 'amount_cents')::bigint as amount_cents,
           te.metadata ->> 'currency'  as currency,
           te.metadata ->> 'status'    as payment_status
      from timeline_events te join members m on m.id = te.member_id
     where te.studio_id = p_studio_id
     order by te.occurred_at desc
     limit greatest(1, least(p_limit, 50))) x;

  return jsonb_build_object(
    'state', case when v_ever = 0 then 'empty' else 'ok' end,
    'items', v_rows,
    'empty_hint', 'Attendance, payments, membership changes and messages, newest first. Fills in as soon as anybody visits or pays.');
end $$;


-- -----------------------------------------------------------------------------
-- 2. AN EMPTY MONTH THAT COULD NOT POINT AT THE TIMETABLE
--
-- Reform Collective: September empty and correct, eleven series, 72 classes
-- from 9 November — and the block offered to set up a recurring class.
--
-- The month now carries `next` when it is empty, so the copy can say when the
-- classes start and link there. Exactly what migration 072 built for the
-- schedule after "the calendar is empty" turned out four times to be a correct
-- empty day with no way to navigate off it.
-- -----------------------------------------------------------------------------
create or replace function dashboard_month(p_studio_id uuid, p_month date default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tz text; v_today date; v_m0 date; v_m1 date;
  v_f timestamptz; v_t timestamptz; v_days jsonb; v_total int; v_next jsonb;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'the calendar snapshot is for owners and managers'
      using errcode = 'PT403';
  end if;
  select s.timezone into v_tz from studios s where s.id = p_studio_id;
  if v_tz is null then raise exception 'no such studio' using errcode = 'PT404'; end if;

  v_today := studio_today(p_studio_id);
  v_m0 := date_trunc('month', coalesce(p_month, v_today))::date;
  v_m1 := (v_m0 + interval '1 month')::date;
  select day_start into v_f from studio_day_bounds(p_studio_id, v_m0);
  select day_start into v_t from studio_day_bounds(p_studio_id, v_m1);

  select coalesce(jsonb_agg(jsonb_build_object(
           'date', d.day, 'classes', coalesce(c.n, 0),
           'booked', coalesce(c.booked, 0), 'capacity', coalesce(c.cap, 0),
           'closed', cl.closed, 'closure_reason', cl.reason,
           'is_today', d.day = v_today) order by d.day), '[]'::jsonb),
         coalesce(sum(coalesce(c.n, 0))::int, 0)
    into v_days, v_total
    from (select g::date as day from generate_series(v_m0, v_m1 - 1, interval '1 day') g) d
    left join lateral (
      select count(*)::int n, sum(o.booked_count)::int booked, sum(o.capacity)::int cap
        from class_occurrences o
       where o.studio_id = p_studio_id and o.status <> 'cancelled'
         and (o.starts_at at time zone v_tz)::date = d.day) c on true
    left join lateral (
      -- One predicate for "is this closed", asked here the same way the
      -- generator, the impact preview, the member app and the brief ask it.
      select exists (select 1 from studio_closures sc
                      where sc.studio_id = p_studio_id
                        and d.day between sc.starts_on and sc.ends_on) as closed,
             (select sc.reason from studio_closures sc
               where sc.studio_id = p_studio_id
                 and d.day between sc.starts_on and sc.ends_on
               order by sc.starts_on limit 1) as reason) cl on true;

  -- AN EMPTY MONTH IS NOT AN EMPTY TIMETABLE, and telling a studio with eleven
  -- series to "set up a recurring class" because September is quiet is the
  -- calendar's own bug in a new place: a correct empty view that cannot point
  -- at the timetable it is a view OF is indistinguishable from a broken one.
  -- next_class_day() is the same answer the schedule's empty day already
  -- gives, asked here rather than reasoned about again.
  if v_total = 0 then
    v_next := next_class_day(p_studio_id, v_today);
  end if;

  return jsonb_build_object(
    'month', v_m0, 'today', v_today, 'timezone', v_tz,
    -- Absent when the month has classes; present, and possibly saying there
    -- are none anywhere, when it does not.
    'next', v_next,
    -- date_trunc('week') always means Monday, and week_starts_on has been a
    -- setting since migration 001. The grid asks for it here rather than the
    -- page making a second round trip to learn which column Sunday is in.
    'week_starts_on', coalesce((select ss.week_starts_on from studio_settings ss
                                 where ss.studio_id = p_studio_id), 1),
    'state', case when v_total = 0 then 'empty' else 'ok' end,
    'days', v_days, 'total_classes', v_total,
    -- Kept for the studio that genuinely has nothing anywhere. Where a
    -- timetable exists but starts later, the screen says WHEN from `next`
    -- instead of repeating this.
    'empty_hint', 'Nothing on the calendar this month. Set up a recurring class and the month fills itself.',
    'marks', jsonb_build_array('classes', 'closures'));
end $$;
