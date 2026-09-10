-- =============================================================================
-- Migration 091 — the Chapter 4 dashboard: every number, computed in SQL
--
-- Bible Ch. 4 lays the dashboard out as ten blocks against five questions an
-- owner should be able to answer in thirty seconds. We had two of them.
--
-- THE BOUNDARY THIS FILE EXISTS TO DRAW: every figure the dashboard shows is
-- produced here. The AI layer (migration 092) receives numbers that are
-- already computed and writes prose about them. It never produces one. If a
-- card says 14 at risk and the sentence says 12 the dashboard is worthless, so
-- the prose and the number can never come out of the same code.
--
-- EMPTY IS A STATE, NOT A ZERO. Reform Collective on hosted today: 1 member,
-- 0 bookings, 1 payment, 70 classes on the calendar. Every block here can tell
-- "this has never happened" from "it did not happen today", and says which. A
-- dashboard of zeros looks broken, and it is the first thing every design
-- partner sees.
--
-- Manager-up throughout. Permissions §12 note 21 keeps revenue and churn away
-- from instructors and front desk, and these are SECURITY DEFINER — the grant
-- is not a guard (migration 056's rule).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Studio-local day arithmetic
--
-- studio_today() is already the one definition of the studio's date. This is
-- the range form: a local date becomes the pair of instants bounding it, so
-- every aggregate below compares instants and never casts a timestamptz to a
-- date in the server's zone.
-- -----------------------------------------------------------------------------
create or replace function studio_day_bounds(p_studio_id uuid, p_day date)
returns table (day_start timestamptz, day_end timestamptz)
language sql stable security definer set search_path = public as $$
  select (p_day::timestamp at time zone s.timezone),
         ((p_day + 1)::timestamp at time zone s.timezone)
    from studios s where s.id = p_studio_id
$$;

comment on function studio_day_bounds(uuid, date) is
  'The instants bounding one of the studio''s own days. Never cast starts_at to '
  'a date to get a studio day — that uses the server''s zone.';

-- -----------------------------------------------------------------------------
-- A trend against a comparable prior period
--
-- One shape for every card, so "↑ 18% compared to last Tuesday" is composed in
-- one place.
--
-- A PERCENTAGE NEEDS A BASE BIG ENOUGH TO DIVIDE BY. Three bookings last
-- Thursday and thirty-five today is "↑ 1067%", which is arithmetically true
-- and reads as a broken widget. Below the floor the percentage is null and the
-- screen shows the change itself — "+32", which is the Bible's own treatment
-- of the bookings card. A prior of zero has no percentage at all: anything
-- over nothing is not an increase of any number of per cent, and printing one
-- would be this dashboard's first invented figure.
-- -----------------------------------------------------------------------------
create or replace function dashboard_pct_floor() returns numeric
language sql immutable as $$ select 5 $$;

create or replace function dashboard_trend(
  p_now numeric, p_prior numeric, p_basis text)
returns jsonb
language sql immutable as $$
  select jsonb_build_object(
    'direction', case when p_now > p_prior then 'up'
                      when p_now < p_prior then 'down' else 'flat' end,
    'delta',     p_now - p_prior,
    'pct',       case when p_prior is null or abs(p_prior) < dashboard_pct_floor()
                      then null
                      else round(100.0 * (p_now - p_prior) / abs(p_prior)) end,
    'prior',     p_prior,
    'basis',     p_basis)
$$;

-- -----------------------------------------------------------------------------
-- Money taken between two instants
--
-- Succeeded payments by paid_at: a payment recorded today for a class last
-- week is today's takings, which is what a studio reconciling the till means
-- by the word. Refunds are reported beside revenue and never netted off it
-- silently — a studio that took 2,000 and refunded 500 had both of those
-- happen, and one number hides one of them.
-- -----------------------------------------------------------------------------
create or replace function studio_revenue_between(
  p_studio_id uuid, p_from timestamptz, p_to timestamptz)
returns bigint
language sql stable security definer set search_path = public as $$
  select coalesce(sum(p.amount_cents), 0)::bigint
    from payments p
   where p.studio_id = p_studio_id
     and p.status in ('succeeded', 'partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= p_from
     and coalesce(p.paid_at, p.created_at) <  p_to
$$;
-- -----------------------------------------------------------------------------
-- How much history a forecast needs, and what it is
--
-- THREE COMPLETE CALENDAR MONTHS, and the number is here rather than inline so
-- the screen can say what it is waiting for. Two points draw a line through
-- any amount of noise; three is the fewest that can show whether the second
-- was an outlier. Below that a projection is a made-up number wearing a
-- currency symbol, and the Bible's own card calls it "AI generated", which is
-- exactly the label that would stop anybody questioning it.
--
-- The projection itself is arithmetic, not a model: recurring revenue that is
-- contracted to renew this month, plus the month's observed daily rate of
-- everything else run out to the end of the month. Both halves are things
-- that have already happened or are already agreed.
-- -----------------------------------------------------------------------------
create or replace function dashboard_forecast_min_months() returns int
language sql immutable as $$ select 3 $$;

create or replace function dashboard_forecast_cents(p_studio_id uuid)
returns bigint
language plpgsql stable security definer set search_path = public as $$
declare
  v_tz text; v_today date; v_m0 date; v_m1 date;
  v_start timestamptz; v_now timestamptz; v_end timestamptz;
  v_so_far bigint; v_days_done numeric; v_days_total numeric;
  v_contracted bigint;
begin
  select s.timezone into v_tz from studios s where s.id = p_studio_id;
  v_today := studio_today(p_studio_id);
  v_m0 := date_trunc('month', v_today)::date;
  v_m1 := (v_m0 + interval '1 month')::date;

  select day_start into v_start from studio_day_bounds(p_studio_id, v_m0);
  select day_start into v_end   from studio_day_bounds(p_studio_id, v_m1);
  select day_start into v_now   from studio_day_bounds(p_studio_id, v_today + 1);

  v_so_far := studio_revenue_between(p_studio_id, v_start, v_now);
  v_days_done  := greatest(1, (v_today - v_m0) + 1);
  v_days_total := (v_m1 - v_m0);

  -- Memberships already agreed to renew before the month is out, at the price
  -- snapshotted on the membership (§7.1 — a plan price change never reprices
  -- somebody already on it, so the plan's price is the wrong number here).
  select coalesce(sum(ms.price_cents), 0)::bigint into v_contracted
    from memberships ms
   where ms.studio_id = p_studio_id and ms.status = 'active' and ms.auto_renew
     and ms.renews_on is not null
     and ms.renews_on > v_today and ms.renews_on < v_m1;

  return round(v_so_far * (v_days_total / v_days_done))::bigint + v_contracted;
end $$;


-- -----------------------------------------------------------------------------
-- 4.3 KPI CARDS
--
-- Never more than eight, per the Bible. Six are computable today; a seventh
-- appears once there is enough history to forecast from. The eighth —
-- challenge participation — is deliberately absent and dashboard_absent_cards()
-- at the foot of this file says so out loud, because a card that can never
-- populate is worse than a missing one and a silently missing one is worse
-- than both.
--
-- Every card carries its own state. 'empty' means the studio has never done
-- this thing at all, and the card shows what will fill it instead of a zero.
-- 'ok' means the number is real, including when it is zero: a studio that took
-- money yesterday and none today has taken none today and should be told so.
-- -----------------------------------------------------------------------------
create or replace function dashboard_kpis(p_studio_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tz text; v_currency char(3); v_today date; v_dayname text;
  v_t0 timestamptz; v_t1 timestamptz; v_p0 timestamptz; v_p1 timestamptz;
  v_cards jsonb := '[]'::jsonb;
  v_rev_today bigint; v_rev_prior bigint; v_rev_ever bigint;
  v_bk_today int; v_bk_prior int; v_bk_ever int;
  v_att_num int; v_att_den int; v_att_pnum int; v_att_pden int;
  v_active int; v_joined_m int; v_members_ever int;
  v_at_risk int; v_banded int;
  v_occ_b bigint; v_occ_c bigint; v_occ_pb bigint; v_occ_pc bigint;
  v_months int; v_forecast bigint;
begin
  -- Manager-up, or the backend. is_service_context() is a POSITIVE identity
  -- (a role Postgres itself marks rolsuper or rolbypassrls) and is never true
  -- for authenticated or anon, with or without a token — migration 024's rule.
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'the dashboard is for owners and managers'
      using errcode = 'PT403';
  end if;
  select s.timezone, s.currency into v_tz, v_currency
    from studios s where s.id = p_studio_id;
  if v_tz is null then raise exception 'no such studio' using errcode = 'PT404'; end if;

  v_today := studio_today(p_studio_id);
  select day_start, day_end into v_t0, v_t1 from studio_day_bounds(p_studio_id, v_today);
  select day_start, day_end into v_p0, v_p1 from studio_day_bounds(p_studio_id, v_today - 7);
  -- "Compared to last Tuesday", per the Bible's own card. The comparable
  -- period for a studio is the same weekday, never yesterday: a Sunday
  -- compared with a Saturday says nothing about either.
  v_dayname := 'last ' || trim(to_char(v_today, 'Day'));

  -- 1. Today's revenue --------------------------------------------------------
  v_rev_today := studio_revenue_between(p_studio_id, v_t0, v_t1);
  v_rev_prior := studio_revenue_between(p_studio_id, v_p0, v_p1);
  select coalesce(sum(p.amount_cents), 0)::bigint into v_rev_ever
    from payments p where p.studio_id = p_studio_id
     and p.status in ('succeeded', 'partially_refunded');

  v_cards := v_cards || jsonb_build_array(jsonb_build_object(
    'key', 'revenue_today', 'label', 'Today''s revenue',
    'state', case when v_rev_ever = 0 then 'empty' else 'ok' end,
    'kind', 'money', 'value', v_rev_today, 'currency', v_currency,
    'trend', dashboard_trend(v_rev_today, v_rev_prior, v_dayname),
    'href', '/dashboard/revenue',
    'empty_hint', 'Once you take your first payment this shows what came in today, against the same day last week.'));

  -- 2. Today's bookings -------------------------------------------------------
  -- Bookings MADE today, which is the number that moves when a studio does
  -- something. A waitlist entry is not a booking; a booking later cancelled
  -- still happened, so the filter is WHEN IT WAS MADE and not its state now.
  --
  -- booked_at, never created_at. created_at is when the ROW arrived, which for
  -- an import, the seed or the demo generator is one single day — 1,011
  -- bookings spread over six months all read as "today" against it, and the
  -- card would have looked plausible and been nonsense.
  select count(*) into v_bk_today from bookings b
   where b.studio_id = p_studio_id and b.status <> 'waitlisted'
     and b.booked_at >= v_t0 and b.booked_at < v_t1;
  select count(*) into v_bk_prior from bookings b
   where b.studio_id = p_studio_id and b.status <> 'waitlisted'
     and b.booked_at >= v_p0 and b.booked_at < v_p1;
  select count(*) into v_bk_ever from bookings b where b.studio_id = p_studio_id;

  v_cards := v_cards || jsonb_build_array(jsonb_build_object(
    'key', 'bookings_today', 'label', 'Today''s bookings',
    'state', case when v_bk_ever = 0 then 'empty' else 'ok' end,
    'kind', 'count', 'value', v_bk_today,
    'trend', dashboard_trend(v_bk_today, v_bk_prior, v_dayname),
    'href', '/schedule',
    'empty_hint', 'Bookings as they come in. Nobody has booked anything yet — invite your members and this starts moving.'));

  -- 3. Attendance -------------------------------------------------------------
  -- Of the seats taken on classes that have already STARTED today, how many
  -- turned up. A class at 18:00 is not a no-show at 09:00, so the window ends
  -- at now() rather than at midnight.
  select count(*) filter (where b.status = 'attended'),
         count(*) filter (where b.status in ('attended','no_show','booked'))
    into v_att_num, v_att_den
    from bookings b join class_occurrences o on o.id = b.occurrence_id
   where b.studio_id = p_studio_id and o.status <> 'cancelled'
     and o.starts_at >= v_t0 and o.starts_at < v_t1 and o.starts_at <= now();
  select count(*) filter (where b.status = 'attended'),
         count(*) filter (where b.status in ('attended','no_show','booked'))
    into v_att_pnum, v_att_pden
    from bookings b join class_occurrences o on o.id = b.occurrence_id
   where b.studio_id = p_studio_id and o.status <> 'cancelled'
     and o.starts_at >= v_p0 and o.starts_at < v_p1;

  v_cards := v_cards || jsonb_build_array(jsonb_build_object(
    'key', 'attendance_today', 'label', 'Attendance',
    'sub', 'Turned up, of those booked in',
    -- ZERO BOOKED SEATS IS NOT NOUGHT PER CENT. It is a question with no
    -- answer yet, and answering it "0%" tells an owner their morning went
    -- badly when in fact nothing has run.
    'state', case when v_att_den = 0 then 'empty' else 'ok' end,
    'kind', 'percent',
    'value', case when v_att_den = 0 then null else round(100.0 * v_att_num / v_att_den) end,
    'trend', case when v_att_den = 0 or v_att_pden = 0 then null
                  else dashboard_trend(round(100.0 * v_att_num / v_att_den),
                                       round(100.0 * v_att_pnum / v_att_pden), v_dayname) end,
    'href', '/dashboard/attendance',
    'empty_hint', 'Once a class with people booked into it has run today, this shows how many of them came.'));

  -- 4. Active members ---------------------------------------------------------
  select count(*) filter (where m.status = 'active'), count(*)
    into v_active, v_members_ever
    from members m where m.studio_id = p_studio_id;
  -- joined_on, for the same reason: it is the studio's own fact about the
  -- member and survives an import, where created_at is the day the CSV was
  -- uploaded.
  select count(*) into v_joined_m from members m
   where m.studio_id = p_studio_id
     and m.joined_on >= date_trunc('month', v_today)::date;

  v_cards := v_cards || jsonb_build_array(jsonb_build_object(
    'key', 'active_members', 'label', 'Active members',
    'state', case when v_members_ever = 0 then 'empty' else 'ok' end,
    'kind', 'count', 'value', v_active,
    'trend', case when v_joined_m = 0 then null
                  else jsonb_build_object('direction','up','delta',v_joined_m,
                                          'pct', null, 'prior', null,
                                          'basis','joined this month') end,
    'href', '/members',
    'empty_hint', 'Nobody on the books yet. Import your members or add one at the desk, and this counts everyone active.'));

  -- 5. Members at risk --------------------------------------------------------
  -- A band that has never been computed is not a clean bill of health.
  -- Decision 14 is explicit that absence of evidence is not evidence of
  -- health, and a reassuring zero here would be exactly that.
  select count(*) filter (where m.health_band = 'at_risk'),
         count(*) filter (where m.health_band is not null)
    into v_at_risk, v_banded
    from members m where m.studio_id = p_studio_id and m.status <> 'archived';

  v_cards := v_cards || jsonb_build_array(jsonb_build_object(
    'key', 'members_at_risk', 'label', 'Members at risk',
    'sub', case when v_at_risk > 0 then 'Needs attention' else null end,
    'state', case when v_banded = 0 then 'empty' else 'ok' end,
    'kind', 'count', 'value', v_at_risk,
    'tone', case when v_at_risk > 0 then 'amber' else 'normal' end,
    'href', '/members?band=at_risk',
    'empty_hint', 'Health is worked out overnight from each member''s own attendance rhythm. Once there are a few visits between them, anyone slipping shows up here.'));

  -- 6. Average class occupancy ------------------------------------------------
  select coalesce(sum(o.booked_count),0)::bigint, coalesce(sum(o.capacity),0)::bigint
    into v_occ_b, v_occ_c
    from class_occurrences o
   where o.studio_id = p_studio_id and o.status <> 'cancelled'
     and o.starts_at >= v_t0 - interval '30 days' and o.starts_at <= least(v_t1, now());
  select coalesce(sum(o.booked_count),0)::bigint, coalesce(sum(o.capacity),0)::bigint
    into v_occ_pb, v_occ_pc
    from class_occurrences o
   where o.studio_id = p_studio_id and o.status <> 'cancelled'
     and o.starts_at >= v_t0 - interval '60 days' and o.starts_at < v_t0 - interval '30 days';

  v_cards := v_cards || jsonb_build_array(jsonb_build_object(
    'key', 'avg_occupancy', 'label', 'Average class occupancy',
    'sub', 'Last 30 days',
    'state', case when v_occ_c = 0 then 'empty' else 'ok' end,
    'kind', 'percent',
    'value', case when v_occ_c = 0 then null else round(100.0 * v_occ_b / v_occ_c) end,
    'trend', case when v_occ_c = 0 or v_occ_pc = 0 then null
                  else dashboard_trend(round(100.0 * v_occ_b / v_occ_c),
                                       round(100.0 * v_occ_pb / v_occ_pc),
                                       'the 30 days before') end,
    'href', '/dashboard/attendance',
    'empty_hint', 'How full your classes run, averaged over a month. Fills in once classes with bookings have taken place.'));

  -- 7. This month, projected --------------------------------------------------
  -- Complete calendar months of takings BEFORE this one. The month in progress
  -- is a number still going up and cannot be one of the points you fit to —
  -- the same reason commitment_report() counts complete weeks only.
  select count(*) into v_months from (
    select 1 from payments p
     where p.studio_id = p_studio_id and p.status in ('succeeded','partially_refunded')
       and coalesce(p.paid_at, p.created_at)
           < (date_trunc('month', v_today)::date::timestamp at time zone v_tz)
     group by date_trunc('month', (coalesce(p.paid_at, p.created_at) at time zone v_tz))
  ) x;

  if v_months >= dashboard_forecast_min_months() then
    v_forecast := dashboard_forecast_cents(p_studio_id);
    v_cards := v_cards || jsonb_build_array(jsonb_build_object(
      'key', 'revenue_forecast', 'label', 'This month, projected',
      'sub', 'From ' || v_months || ' complete months and what is already agreed',
      'state', 'ok', 'kind', 'money', 'value', v_forecast, 'currency', v_currency,
      'href', '/dashboard/revenue', 'forecast', true));
  end if;

  return jsonb_build_object(
    'today', v_today, 'currency', v_currency, 'cards', v_cards,
    'forecast_months_needed', dashboard_forecast_min_months(),
    'forecast_months_have', v_months);
end $$;

create or replace function dashboard_source_label(p_src text) returns text
language sql immutable as $$
  select case p_src
    when 'membership' then 'Memberships'
    when 'pack'       then 'Class packs'
    when 'drop_in'    then 'Drop-ins'
    when 'private'    then 'Private sessions'
    when 'trial'      then 'Trials'
    else 'Other' end
$$;

-- -----------------------------------------------------------------------------
-- 4.4 REVENUE ANALYTICS
--
-- 7 / 30 / 90 / 365 and custom, by source, in the studio's own days.
--
-- RETAIL AND GIFT CARDS ARE NOT IN THIS PRODUCT and are omitted rather than
-- rendered as a zero row. The Bible's example splits revenue four ways
-- including retail at 15%; a legend with two permanent noughts in it teaches
-- an owner that this chart has categories it does not fill in. promo_code_id
-- and gift_card_id exist on payments (migration 001) and nothing writes them.
--
-- Private sessions ARE here, keyed on class_types.session_kind from migration
-- 082 — a marked class, never a headcount, per Decision 22.
-- -----------------------------------------------------------------------------
create or replace function dashboard_revenue(
  p_studio_id uuid, p_from date, p_to date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tz text; v_currency char(3); v_today date;
  v_f0 timestamptz; v_t1 timestamptz;
  v_span int; v_pf0 timestamptz; v_pt1 timestamptz;
  v_total bigint; v_prior bigint; v_refunds bigint; v_ever bigint;
  v_series jsonb; v_sources jsonb; v_counts jsonb;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'revenue is for owners and managers' using errcode = 'PT403';
  end if;
  select s.timezone, s.currency into v_tz, v_currency from studios s where s.id = p_studio_id;
  if v_tz is null then raise exception 'no such studio' using errcode = 'PT404'; end if;
  if p_to < p_from then
    raise exception 'the range ends before it starts' using errcode = 'PT422';
  end if;

  v_today := studio_today(p_studio_id);
  select day_start into v_f0 from studio_day_bounds(p_studio_id, p_from);
  select day_start into v_t1 from studio_day_bounds(p_studio_id, p_to + 1);
  v_span := (p_to - p_from) + 1;
  select day_start into v_pf0 from studio_day_bounds(p_studio_id, p_from - v_span);
  select day_start into v_pt1 from studio_day_bounds(p_studio_id, p_from);

  v_total := studio_revenue_between(p_studio_id, v_f0, v_t1);
  v_prior := studio_revenue_between(p_studio_id, v_pf0, v_pt1);
  select coalesce(sum(p.amount_cents),0)::bigint into v_ever from payments p
   where p.studio_id = p_studio_id and p.status in ('succeeded','partially_refunded');

  select coalesce(sum(r.amount_cents),0)::bigint into v_refunds
    from refunds r join payments p on p.id = r.payment_id
   where p.studio_id = p_studio_id
     and r.created_at >= v_f0 and r.created_at < v_t1;

  -- One row per day of the range, including the days with nothing: a line
  -- chart that skips its empty days draws a slope where there was a gap.
  select coalesce(jsonb_agg(jsonb_build_object('date', d.day, 'cents', coalesce(x.cents,0))
                            order by d.day), '[]'::jsonb)
    into v_series
    from generate_series(p_from, p_to, interval '1 day') g(day_ts)
    cross join lateral (select g.day_ts::date as day) d
    left join lateral (
      select coalesce(sum(p.amount_cents),0)::bigint as cents
        from payments p
       where p.studio_id = p_studio_id and p.status in ('succeeded','partially_refunded')
         and (coalesce(p.paid_at, p.created_at) at time zone v_tz)::date = d.day
    ) x on true;

  -- By source. A payment reaches its category through what it PAID FOR: the
  -- membership's plan type, or the booking's payment_source, or the class
  -- type's session_kind for a private. Never through a category column on the
  -- payment, which nothing writes.
  with classified as (
    select p.amount_cents,
           case
             when ct.session_kind in ('private','duo','trio') then 'private'
             when pl.type = 'recurring'  then 'membership'
             when pl.type = 'class_pack' then 'pack'
             when pl.type = 'trial'      then 'trial'
             when b.payment_source = 'drop_in' then 'drop_in'
             when pl.type = 'drop_in'    then 'drop_in'
             else 'other'
           end as src
      from payments p
      left join memberships ms on ms.id = p.membership_id
      left join membership_plans pl on pl.id = ms.plan_id
      left join bookings b on b.id = p.booking_id
      left join class_occurrences o on o.id = b.occurrence_id
      left join class_types ct on ct.id = o.class_type_id
     where p.studio_id = p_studio_id and p.status in ('succeeded','partially_refunded')
       and coalesce(p.paid_at, p.created_at) >= v_f0
       and coalesce(p.paid_at, p.created_at) <  v_t1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'source', src, 'label', dashboard_source_label(src), 'cents', cents,
           'pct', case when v_total = 0 then 0 else round(100.0 * cents / v_total) end)
           order by cents desc), '[]'::jsonb)
    into v_sources
    from (select src, sum(amount_cents)::bigint as cents from classified group by src) s;

  -- The other metrics 4.4 lists beside revenue.
  select jsonb_build_object(
      'bookings', (select count(*) from bookings b
                    where b.studio_id = p_studio_id and b.status <> 'waitlisted'
                      and b.booked_at >= v_f0 and b.booked_at < v_t1),
      'memberships_sold', (select count(*) from memberships ms
                    where ms.studio_id = p_studio_id
                      and ms.created_at >= v_f0 and ms.created_at < v_t1),
      'refunds_cents', v_refunds)
    into v_counts;

  return jsonb_build_object(
    'from', p_from, 'to', p_to, 'days', v_span, 'currency', v_currency,
    'state', case when v_ever = 0 then 'empty' else 'ok' end,
    'total_cents', v_total,
    'trend', dashboard_trend(v_total, v_prior, 'the ' || v_span || ' days before'),
    'series', v_series, 'by_source', v_sources, 'counts', v_counts,
    'empty_hint', 'Every payment you take shows up here — by day, and split by what it was for. Record a payment at the desk or connect Stripe and this starts filling.');
end $$;


-- -----------------------------------------------------------------------------
-- 4.5 ATTENDANCE HEAT MAP
--
-- Day of week by hour, in the STUDIO's clock. A 07:00 Manila class is stored
-- at 23:00 UTC the previous day, so extracting dow and hour from the raw
-- instant puts it in the wrong cell AND on the wrong row — the exact fault
-- migration 070 was written for, one screen along.
--
-- Only classes that have RUN. A fortnight of empty future classes averaged in
-- would make every hour look quiet and argue against the slots that work.
-- -----------------------------------------------------------------------------
create or replace function dashboard_heatmap(p_studio_id uuid, p_days int default 90)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tz text; v_today date; v_from timestamptz; v_to timestamptz;
  v_cells jsonb; v_ran int; v_peak jsonb; v_quiet jsonb; v_min_classes int := 3;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'attendance is for owners and managers' using errcode = 'PT403';
  end if;
  select s.timezone into v_tz from studios s where s.id = p_studio_id;
  if v_tz is null then raise exception 'no such studio' using errcode = 'PT404'; end if;

  v_today := studio_today(p_studio_id);
  select day_start into v_from from studio_day_bounds(p_studio_id, v_today - p_days);
  select day_start into v_to   from studio_day_bounds(p_studio_id, v_today + 1);

  with cell as (
    select extract(dow  from (o.starts_at at time zone v_tz))::int as dow,
           extract(hour from (o.starts_at at time zone v_tz))::int as hour,
           count(*)::int as classes,
           sum(o.booked_count)::bigint as booked,
           sum(o.capacity)::bigint as capacity
      from class_occurrences o
     where o.studio_id = p_studio_id and o.status <> 'cancelled'
       and o.starts_at >= v_from and o.starts_at < least(v_to, now())
     group by 1, 2)
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'dow', dow, 'hour', hour, 'classes', classes,
      'booked', booked, 'capacity', capacity,
      'occupancy', case when capacity = 0 then null
                        else round(100.0 * booked / capacity) end)
      order by dow, hour), '[]'::jsonb),
    count(*)::int,
    -- The one cell worth acting on at each end, and only where there is
    -- enough of it to mean anything. One busy Thursday is not a pattern, and
    -- an insight drawn from a single class is how a studio learns to stop
    -- believing this screen.
    (select to_jsonb(x) from (
       select dow, hour, classes, round(100.0 * booked / capacity) as occupancy
         from cell where classes >= v_min_classes and capacity > 0
        order by booked::numeric / capacity desc, classes desc limit 1) x),
    (select to_jsonb(x) from (
       select dow, hour, classes, round(100.0 * booked / capacity) as occupancy
         from cell where classes >= v_min_classes and capacity > 0
        order by booked::numeric / capacity asc, classes desc limit 1) x)
    into v_cells, v_ran, v_peak, v_quiet
  from cell;

  return jsonb_build_object(
    'days', p_days, 'timezone', v_tz,
    'state', case when coalesce(v_ran,0) = 0 then 'empty' else 'ok' end,
    'cells', coalesce(v_cells, '[]'::jsonb), 'peak', v_peak, 'quiet', v_quiet,
    'min_classes_for_pattern', v_min_classes,
    'empty_hint', 'Once classes have run, this shows which hours of which days fill and which do not — the shape of your week at a glance.');
end $$;

-- -----------------------------------------------------------------------------
-- 4.8 MEMBER HEALTH WIDGET
--
-- Decision 14's bands, counted. NOT COMPUTED IS ITS OWN ROW, and that is the
-- point: a studio whose nightly pass has never run has five zeros and no at-
-- risk members, which reads as a clean bill of health for a question nobody
-- has asked yet.
-- -----------------------------------------------------------------------------
create or replace function dashboard_health(p_studio_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_bands jsonb; v_total int; v_banded int; v_computed timestamptz;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'member health is for owners and managers' using errcode = 'PT403';
  end if;

  select count(*), count(*) filter (where health_band is not null), max(health_computed_at)
    into v_total, v_banded, v_computed
    from members where studio_id = p_studio_id and status <> 'archived';

  select jsonb_agg(jsonb_build_object(
           'band', b.band, 'count', coalesce(c.n, 0),
           'href', '/members?band=' || b.band) order by b.ord)
    into v_bands
    from (values ('healthy',1),('new',2),('drifting',3),('at_risk',4),
                 ('insufficient_history',5)) b(band, ord)
    left join (
      select health_band, count(*)::int n from members
       where studio_id = p_studio_id and status <> 'archived' and health_band is not null
       group by 1) c on c.health_band = b.band;

  return jsonb_build_object(
    'state', case when v_total = 0 then 'empty'
                  when v_banded = 0 then 'not_computed' else 'ok' end,
    'bands', v_bands, 'total', v_total, 'banded', v_banded,
    'not_computed', v_total - v_banded,
    'computed_at', v_computed,
    'empty_hint', 'Every member gets a band and a reason in plain words — who is settled, who is slipping, and why. Add or import members and it starts working overnight.',
    'not_computed_hint', 'Nobody has a band yet. Bands are worked out overnight from each member''s own attendance rhythm, so this fills in after the first pass.');
end $$;

-- -----------------------------------------------------------------------------
-- 4.9 RECENT ACTIVITY
--
-- timeline_events, which is already the one derived record of what happened to
-- a member (migration 021, rebuilt by 059). Nothing is derived a second time
-- here — a second derivation would disagree with the member's own journey the
-- first time either changed.
--
-- `booked` is deliberately absent from that table, so this feed is what
-- HAPPENED rather than what was arranged. Said in the UI, because a feed
-- missing the most frequent event looks broken otherwise.
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
           '/members/' || te.member_id as href
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
-- 4.11 TASKS — an action centre, derived, never a table
--
-- The Bible says "Instead of reminders. Action Center." and lists tasks
-- generated by AI, automation, users, calendar and integrations.
--
-- THERE IS NO TASKS TABLE AND THERE MUST NOT BE ONE YET. This project's most
-- repeated bug is a schema with no writer — instructor_availability,
-- class_series, class_types.color, cancellation_reason, and the twenty-six
-- settings columns in docs/SETTINGS_WITHOUT_UI.md. A `tasks` table would be
-- the next one: a studio would tick a row that nothing else knows about, and
-- the six "Approve instructor / Review refund" examples in 4.11 are every one
-- of them a state that ALREADY EXISTS somewhere in this schema.
--
-- So every task here is derived from the thing itself and disappears when the
-- thing is dealt with. Nothing to tick, nothing to go stale, nothing to
-- disagree with the screen it links to. User-authored tasks are the one part
-- of 4.11 this cannot do, and that is named rather than half-built.
-- -----------------------------------------------------------------------------
create or replace function dashboard_tasks(p_studio_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tz text; v_today date; v_now timestamptz; v_soon timestamptz;
  v_tasks jsonb := '[]'::jsonb;
  n int; v_unconf jsonb; v_cycle jsonb;
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
-- 4.10 CALENDAR SNAPSHOT
--
-- A month at a glance, in the studio's own days.
--
-- The Bible marks classes, workshops, events, staff leave, maintenance,
-- launches, marketing campaigns and challenge deadlines. SIX OF THOSE EIGHT DO
-- NOT EXIST IN THIS PRODUCT. What does: classes, and studio closures from
-- migration 074 — which is staff leave and maintenance under the one name the
-- schema actually has for them. Drawing eight legend entries where two have
-- data is the same mistake as a revenue chart with a permanent retail row.
-- -----------------------------------------------------------------------------
create or replace function dashboard_month(p_studio_id uuid, p_month date default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tz text; v_today date; v_m0 date; v_m1 date;
  v_f timestamptz; v_t timestamptz; v_days jsonb; v_total int;
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

  return jsonb_build_object(
    'month', v_m0, 'today', v_today, 'timezone', v_tz,
    -- date_trunc('week') always means Monday, and week_starts_on has been a
    -- setting since migration 001. The grid asks for it here rather than the
    -- page making a second round trip to learn which column Sunday is in.
    'week_starts_on', coalesce((select ss.week_starts_on from studio_settings ss
                                 where ss.studio_id = p_studio_id), 1),
    'state', case when v_total = 0 then 'empty' else 'ok' end,
    'days', v_days, 'total_classes', v_total,
    'empty_hint', 'Nothing on the calendar this month. Set up a recurring class and the month fills itself.',
    'marks', jsonb_build_array('classes', 'closures'));
end $$;

-- -----------------------------------------------------------------------------
-- The cards that are NOT here, and why
--
-- The Bible specifies eight KPI cards. Rendering a card that can never
-- populate is the insight-without-a-button mistake in a new place; leaving one
-- out silently is how it gets rediscovered as a bug in six months. So the
-- screen says which two are absent and what each is waiting for.
-- -----------------------------------------------------------------------------
create or replace function dashboard_absent_cards(p_studio_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_have int; v_need int; v_tz text; v_today date;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'the dashboard is for owners and managers' using errcode = 'PT403';
  end if;
  select s.timezone into v_tz from studios s where s.id = p_studio_id;
  v_today := studio_today(p_studio_id);
  v_need := dashboard_forecast_min_months();
  select count(*) into v_have from (
    select 1 from payments p
     where p.studio_id = p_studio_id and p.status in ('succeeded','partially_refunded')
       and coalesce(p.paid_at, p.created_at)
           < (date_trunc('month', v_today)::date::timestamp at time zone v_tz)
     group by date_trunc('month', (coalesce(p.paid_at, p.created_at) at time zone v_tz))) x;

  return (
    select coalesce(jsonb_agg(c), '[]'::jsonb) from (
      select jsonb_build_object(
        'key','challenge_participation',
        'label','Challenge participation',
        'why','Challenges have no screens yet, so this card would have nothing '
              'to count and nowhere to send you. It arrives with them.') as c
      union all
      select jsonb_build_object(
        'key','revenue_forecast',
        'label','Monthly revenue forecast',
        'why','A projection needs ' || v_need || ' complete months of takings to '
              || 'sit on. You have ' || v_have || '. Anything sooner is a made-up '
              || 'number with a currency symbol on it.')
       where v_have < v_need
    ) t(c));
end $$;


-- -----------------------------------------------------------------------------
-- Closed by default, because this platform's default is the opposite: a new
-- function is born executable by anon AND authenticated, and withholding a
-- grant does nothing. Every one of these is guarded manager-up INSIDE — the
-- grant is not the guard (migration 056) — and is granted to authenticated so
-- the screens can reach it.
-- -----------------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'studio_day_bounds(uuid,date)',
    'dashboard_pct_floor()',
    'dashboard_trend(numeric,numeric,text)',
    'studio_revenue_between(uuid,timestamptz,timestamptz)',
    'dashboard_forecast_min_months()',
    'dashboard_forecast_cents(uuid)',
    'dashboard_source_label(text)',
    'dashboard_kpis(uuid)',
    'dashboard_revenue(uuid,date,date)',
    'dashboard_heatmap(uuid,int)',
    'dashboard_health(uuid)',
    'dashboard_activity(uuid,int)',
    'dashboard_tasks(uuid)',
    'dashboard_month(uuid,date)',
    'dashboard_absent_cards(uuid)']
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
end $$;

-- The seven that a screen calls. Each raises PT403 for a caller who is not
-- manager-up of that studio, proved in test/dashboard_test.sql.
grant execute on function dashboard_kpis(uuid)            to authenticated, service_role;
grant execute on function dashboard_revenue(uuid,date,date) to authenticated, service_role;
grant execute on function dashboard_heatmap(uuid,int)     to authenticated, service_role;
grant execute on function dashboard_health(uuid)          to authenticated, service_role;
grant execute on function dashboard_activity(uuid,int)    to authenticated, service_role;
grant execute on function dashboard_tasks(uuid)           to authenticated, service_role;
grant execute on function dashboard_month(uuid,date)      to authenticated, service_role;
grant execute on function dashboard_absent_cards(uuid)    to authenticated, service_role;

-- The internals. Nothing outside should call them at all, which is a stronger
-- statement than a check — migration 086's rule for ensure_pay_period().
grant execute on function studio_day_bounds(uuid,date)    to service_role;
grant execute on function dashboard_pct_floor()           to service_role;
grant execute on function dashboard_trend(numeric,numeric,text) to service_role;
grant execute on function studio_revenue_between(uuid,timestamptz,timestamptz) to service_role;
grant execute on function dashboard_forecast_min_months() to service_role;
grant execute on function dashboard_forecast_cents(uuid)  to service_role;
grant execute on function dashboard_source_label(text)    to service_role;
