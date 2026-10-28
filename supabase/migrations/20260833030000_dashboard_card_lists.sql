-- Decision 86 — every dashboard card opens the list it counted.
--
-- re-issues: dashboard_kpis(uuid), member_plan_overview(uuid),
--            dashboard_challenge_kpi(uuid), dashboard_free_first_kpi(uuid)
-- creates:   dashboard_payments_on(uuid, date), dashboard_today_classes(uuid, date),
--            dashboard_occupancy_30d(uuid), dashboard_free_first_members(uuid)
--
-- The card definitions change (today = studio local day everywhere, which the
-- KPI already is): bookings become SEATS IN TODAY'S CLASSES rather than bookings
-- made today; attendance is over classes that have ENDED; active members are
-- those who CAN BOOK NOW (a live plan or classes left) with a second line of who
-- came in the last 30 days. Each card's href points at the list of exactly the
-- things it counted. The conversion card is the free-first one (Decision 30);
-- the host-brought-guest card (Decision 26) is dropped from the dashboard and its
-- number survives as one line on the free-class members list.
--
-- No new anon surface. Every list reader is authenticated desk-up (or service),
-- mirroring member_plan_overview, so front desk reaches the same lists the cards
-- open. anon stays EXACTLY THIRTEEN.

-- ---------------------------------------------------------------------------
-- member_plan_overview gains joined_on, so /members can serve the active-member
-- filters (can_book from plan_state, attended_30d from last_visit_at, and
-- joined_month from this new column) and dashboard_kpis can read all three from
-- the ONE definition rather than inventing a second. A returns-table column add
-- is a drop+recreate (migration 277/294's shape); the body is byte-for-byte the
-- 20260832940000 definition plus joined_on. ACL re-asserted — authenticated,
-- never anon.
-- ---------------------------------------------------------------------------
drop function if exists member_plan_overview(uuid);
create function member_plan_overview(p_studio_id uuid)
returns table (
  id uuid, first_name text, last_name text, email text, status text,
  lifetime_visits int, last_visit_at timestamptz,
  health_band text, health_reason text, user_id uuid,
  membership_id uuid, current_plan_name text, plan_type text,
  membership_status text, expires_on date, credits_remaining int,
  had_free_class boolean, has_ever_paid boolean, plan_state text,
  complimentary boolean, free_stage text, has_unpaid_booking boolean,
  joined_on date
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare v_tz text; v_today date;
begin
  if not (is_desk_up(p_studio_id) or is_service_context()) then
    raise exception 'that is another studio''s members' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios s where s.id = p_studio_id;
  v_today := (now() at time zone v_tz)::date;

  return query
  with mem as (
    select m.id, m.first_name, m.last_name, m.email, m.status::text as status,
           m.lifetime_visits, m.last_visit_at,
           m.health_band::text as health_band, m.health_reason, m.user_id,
           m.joined_on
      from members m
     where m.studio_id = p_studio_id and m.status <> 'archived'
       and m.deleted_at is null
  ),
  live as (
    select distinct on (ms.member_id)
           ms.member_id, ms.id as membership_id, ms.status as ms_status,
           ms.expires_on, ms.credits_remaining, mp.name as plan_name, mp.type as plan_type,
           ms.complimentary,
           (ms.status in ('active','trialing','past_due','frozen')
            and (mp.type = 'recurring'
                 or coalesce(ms.credits_remaining,0) > 0)
            and (ms.expires_on is null or ms.expires_on >= v_today)) as usable
      from memberships ms
      join membership_plans mp on mp.id = ms.plan_id
     where ms.studio_id = p_studio_id and ms.status <> 'cancelled'
     order by ms.member_id,
              (ms.status in ('active','trialing','past_due','frozen')) desc,
              ms.expires_on desc nulls first, ms.created_at desc
  ),
  paid as (
    select distinct member_id from payments
     where studio_id = p_studio_id and status in ('succeeded','partially_refunded')
  ),
  freebie as (
    select distinct guest_member_id as member_id from guest_passes
     where studio_id = p_studio_id
  ),
  comp as (
    select b.member_id,
           bool_or(b.status = 'attended') as any_attended,
           bool_or(b.status = 'booked')   as any_booked,
           bool_or(b.status = 'no_show')  as any_no_show,
           max(o.starts_at) filter (where b.status = 'no_show') as last_no_show_at
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
     where b.studio_id = p_studio_id
       and b.payment_source = 'comp'
       and b.status in ('booked','attended','no_show')
     group by b.member_id
  ),
  unpaid as (
    select distinct b.member_id
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
     where b.studio_id = p_studio_id
       and b.payment_source = 'drop_in'
       and b.status in ('booked','pending_payment')
       and o.starts_at > now()
       and not exists (select 1 from payments p
                        where p.booking_id = b.id
                          and p.status in ('succeeded','partially_refunded'))
  )
  select mem.id, mem.first_name, mem.last_name, mem.email, mem.status,
         mem.lifetime_visits, mem.last_visit_at, mem.health_band, mem.health_reason, mem.user_id,
         live.membership_id, live.plan_name, live.plan_type::text,
         live.ms_status::text, live.expires_on, live.credits_remaining,
         (freebie.member_id is not null) as had_free_class,
         (paid.member_id is not null) as has_ever_paid,
         case
           when coalesce(live.usable, false) then
             case when live.expires_on is not null
                       and live.expires_on <= v_today + 14 then 'expiring' else 'on_plan' end
           when paid.member_id is not null then 'expired'
           when freebie.member_id is not null then 'free_only'
           else 'none'
         end as plan_state,
         coalesce(live.complimentary, false) as complimentary,
         case
           when comp.any_attended then 'taken'
           when comp.any_booked   then 'booked'
           when comp.any_no_show
                and not exists (
                  select 1 from bookings b2
                  join class_occurrences o2 on o2.id = b2.occurrence_id
                  where b2.member_id = mem.id and b2.studio_id = p_studio_id
                    and b2.status not in ('cancelled','late_cancelled')
                    and o2.starts_at > comp.last_no_show_at
                ) then 'missed'
           else null
         end as free_stage,
         (unpaid.member_id is not null) as has_unpaid_booking,
         mem.joined_on
    from mem
    left join live    on live.member_id = mem.id
    left join paid    on paid.member_id = mem.id
    left join freebie on freebie.member_id = mem.id
    left join comp    on comp.member_id = mem.id
    left join unpaid  on unpaid.member_id = mem.id;
end $$;

revoke all on function member_plan_overview(uuid) from public, anon;
grant execute on function member_plan_overview(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- dashboard_kpis — re-issued with Decision 86's definitions and hrefs. Cards 1,
-- 3, 6 keep their computation and change only their href; card 2 (bookings)
-- changes from made-today to seats-in-today's-classes; card 4 (active) changes
-- from status-active to can-book-now, with the attended-30d and joined-this-month
-- links; card 5 (at risk) points at the retention board's at-risk section.
-- ---------------------------------------------------------------------------
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
  v_active int; v_attended_30d int; v_joined_m int; v_members_ever int;
  v_at_risk int; v_banded int;
  v_occ_b bigint; v_occ_c bigint; v_occ_pb bigint; v_occ_pc bigint;
  v_months int; v_forecast bigint;
begin
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
  v_dayname := 'last ' || trim(to_char(v_today, 'Day'));

  -- 1. Today's revenue -- unchanged figure (studio_revenue_between is the sum of
  -- every succeeded/partially-refunded payment in today's bounds), now opening
  -- the per-payment list whose total is that same number.
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
    'href', '/dashboard/revenue/today',
    'empty_hint', 'Once you take your first payment this shows what came in today, against the same day last week.'));

  -- 2. Today's bookings -- SEATS IN TODAY'S CLASSES (Decision 86), not bookings
  -- made today. The same set the Today's classes list shows: a seat on a
  -- non-cancelled occurrence starting today, held or taken or already attended.
  select count(*) into v_bk_today
    from bookings b join class_occurrences o on o.id = b.occurrence_id
   where b.studio_id = p_studio_id and o.status <> 'cancelled'
     and b.status in ('booked','attended','no_show','pending_payment')
     and o.starts_at >= v_t0 and o.starts_at < v_t1;
  select count(*) into v_bk_prior
    from bookings b join class_occurrences o on o.id = b.occurrence_id
   where b.studio_id = p_studio_id and o.status <> 'cancelled'
     and b.status in ('booked','attended','no_show','pending_payment')
     and o.starts_at >= v_p0 and o.starts_at < v_p1;
  select count(*) into v_bk_ever from bookings b where b.studio_id = p_studio_id;

  v_cards := v_cards || jsonb_build_array(jsonb_build_object(
    'key', 'bookings_today', 'label', 'Today''s bookings',
    'state', case when v_bk_ever = 0 then 'empty' else 'ok' end,
    'kind', 'count', 'value', v_bk_today,
    'trend', dashboard_trend(v_bk_today, v_bk_prior, v_dayname),
    'href', '/dashboard/classes',
    'empty_hint', 'Seats in today''s classes. Nobody has booked anything yet, so invite your members and this starts moving.'));

  -- 3. Attendance -- of the seats on classes that have ALREADY ENDED today, how
  -- many came. ends_at, not starts_at: a class in progress has nobody to mark
  -- a no-show yet.
  select count(*) filter (where b.status = 'attended'),
         count(*) filter (where b.status in ('attended','no_show','booked'))
    into v_att_num, v_att_den
    from bookings b join class_occurrences o on o.id = b.occurrence_id
   where b.studio_id = p_studio_id and o.status <> 'cancelled'
     and o.starts_at >= v_t0 and o.starts_at < v_t1 and o.ends_at <= now();
  select count(*) filter (where b.status = 'attended'),
         count(*) filter (where b.status in ('attended','no_show','booked'))
    into v_att_pnum, v_att_pden
    from bookings b join class_occurrences o on o.id = b.occurrence_id
   where b.studio_id = p_studio_id and o.status <> 'cancelled'
     and o.starts_at >= v_p0 and o.starts_at < v_p1;

  v_cards := v_cards || jsonb_build_array(jsonb_build_object(
    'key', 'attendance_today', 'label', 'Attendance',
    'sub', 'Turned up, of those booked in',
    'state', case when v_att_den = 0 then 'empty' else 'ok' end,
    'kind', 'percent',
    'value', case when v_att_den = 0 then null else round(100.0 * v_att_num / v_att_den) end,
    'trend', case when v_att_den = 0 or v_att_pden = 0 then null
                  else dashboard_trend(round(100.0 * v_att_num / v_att_den),
                                       round(100.0 * v_att_pnum / v_att_pden), v_dayname) end,
    'href', '/dashboard/classes?ended=1',
    'empty_hint', 'Once a class with people booked into it has ended today, this shows how many of them came.'));

  -- 4. Active members -- WHO CAN BOOK RIGHT NOW (a live plan or classes left),
  -- read from member_plan_overview so the card and the /members can-book filter
  -- cannot disagree. Second line: who came in the last 30 days. Both lines, and
  -- "joined this month", open their own filtered list.
  select
    count(*) filter (where plan_state in ('on_plan','expiring')),
    count(*) filter (where last_visit_at >= now() - interval '30 days'),
    count(*) filter (where joined_on >= date_trunc('month', v_today)::date),
    count(*)
  into v_active, v_attended_30d, v_joined_m, v_members_ever
  from member_plan_overview(p_studio_id);

  v_cards := v_cards || jsonb_build_array(jsonb_build_object(
    'key', 'active_members', 'label', 'Active members',
    'sub', v_attended_30d || ' came in the last 30 days',
    'state', case when v_members_ever = 0 then 'empty' else 'ok' end,
    'kind', 'count', 'value', v_active,
    'href', '/members?filter=can_book',
    'links', jsonb_build_array(
      jsonb_build_object('label', v_attended_30d || ' came in the last 30 days',
                         'href', '/members?filter=attended_30d'),
      jsonb_build_object('label', v_joined_m || ' joined this month',
                         'href', '/members?filter=joined_month')),
    'empty_hint', 'Nobody on the books yet. Import your members or add one at the desk, and this counts everyone who can book.'));

  -- 5. Members at risk -- opens the retention board at its at-risk section.
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
    'href', '/retention#at_risk',
    'empty_hint', 'Health is worked out overnight from each member''s own attendance rhythm. Once there are a few visits between them, anyone slipping shows up here.'));

  -- 6. Average class occupancy -- seats filled over capacity across classes that
  -- RAN in the last 30 days; opens the per-class list, emptiest first.
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
    'href', '/dashboard/occupancy',
    'empty_hint', 'How full your classes run, averaged over a month. Fills in once classes with bookings have taken place.'));

  -- 7. This month, projected -- unchanged.
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

-- ---------------------------------------------------------------------------
-- dashboard_payments_on — the per-payment list for a given studio-local day.
-- One row per payment, and its total is studio_revenue_between by construction
-- (identical predicate: succeeded/partially_refunded, coalesce(paid_at,created_at)
-- inside the day). item names what it paid for; method is the same label Sales
-- shows; recorded_by is the staff name on a desk payment, null otherwise.
-- ---------------------------------------------------------------------------
create function dashboard_payments_on(p_studio_id uuid, p_date date)
returns table (
  payment_id uuid, paid_at timestamptz, member_id uuid, member_name text,
  item text, amount_cents int, currency char(3), method text, recorded_by text
)
language plpgsql stable security definer set search_path = public as $$
declare v_t0 timestamptz; v_t1 timestamptz;
begin
  if not (is_desk_up(p_studio_id) or is_service_context()) then
    raise exception 'that is another studio''s takings' using errcode = 'PT403';
  end if;
  select day_start, day_end into v_t0, v_t1 from studio_day_bounds(p_studio_id, p_date);

  return query
  select p.id,
         coalesce(p.paid_at, p.created_at) as paid_at,
         p.member_id,
         case when m.id is null then null else (m.first_name || ' ' || m.last_name) end,
         coalesce(mp.name, pr.name,
                  case when p.booking_id is not null then 'Drop-in' end,
                  nullif(p.description, ''), 'Payment') as item,
         p.amount_cents, p.currency,
         coalesce(
           case when p.provider = 'stripe' then 'Card (Stripe)'
                when p.provider = 'xendit' then 'Card (Xendit)'
                when p.method = 'gcash' then 'GCash'
                when p.method = 'bank_transfer' then 'Bank transfer'
                when p.method = 'card_terminal' then 'Card (terminal)'
                when p.method = 'cash' then 'Cash'
                when p.method = 'other' then 'Other'
           end, 'Recorded') as method,
         rec.full_name as recorded_by
    from payments p
    left join members m          on m.id = p.member_id
    left join memberships ms     on ms.id = p.membership_id
    left join membership_plans mp on mp.id = ms.plan_id
    left join product_orders po  on po.id = p.product_order_id
    left join products pr        on pr.id = po.product_id
    left join profiles rec       on rec.id = p.recorded_by
   where p.studio_id = p_studio_id
     and p.status in ('succeeded', 'partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_t0
     and coalesce(p.paid_at, p.created_at) <  v_t1
   order by coalesce(p.paid_at, p.created_at);
end $$;

revoke all on function dashboard_payments_on(uuid, date) from public, anon;
grant execute on function dashboard_payments_on(uuid, date) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- dashboard_today_classes — each non-cancelled class on a studio-local day, in
-- time order, with its booked members: seat kind, checked-in, and attended /
-- no-show. The attendance card opens the same list filtered to ended classes
-- (the page does that with ?ended=1), so there is ONE list for bookings and
-- attendance. Returns jsonb: an array of classes, each carrying a members array.
-- ---------------------------------------------------------------------------
create function dashboard_today_classes(p_studio_id uuid, p_date date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_t0 timestamptz; v_t1 timestamptz;
begin
  if not (is_desk_up(p_studio_id) or is_service_context()) then
    raise exception 'that is another studio''s schedule' using errcode = 'PT403';
  end if;
  select day_start, day_end into v_t0, v_t1 from studio_day_bounds(p_studio_id, p_date);

  return (
    select coalesce(jsonb_agg(c order by c_starts), '[]'::jsonb)
    from (
      select o.starts_at as c_starts,
             jsonb_build_object(
               'occurrence_id', o.id,
               'name', coalesce(o.name, ct.name, 'Class'),
               'starts_at', o.starts_at,
               'ends_at', o.ends_at,
               'room', rm.name,
               'instructor', split_part(coalesce(i.display_name, ''), ' ', 1),
               'capacity', o.capacity,
               'booked', o.booked_count,
               'status', o.status::text,
               'ended', (o.ends_at <= now()),
               'members', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'booking_id', b.id,
                          'member_id', b.member_id,
                          'name', (m.first_name || ' ' || m.last_name),
                          'seat_kind', case
                            when exists (select 1 from guest_passes gp
                                          where gp.guest_booking_id = b.id) then 'free_first'
                            when b.payment_source = 'comp' then 'complimentary'
                            when b.payment_source = 'drop_in'
                                 and exists (select 1 from payments p
                                              where p.booking_id = b.id
                                                and p.status in ('succeeded','partially_refunded'))
                                 then 'drop_in_paid'
                            when b.payment_source = 'drop_in' then 'drop_in_unpaid'
                            else 'plan'
                          end,
                          'checked_in', (b.status = 'attended'
                            or exists (select 1 from check_ins ci where ci.booking_id = b.id)),
                          'state', case
                            when b.status = 'attended' then 'attended'
                            when b.status = 'no_show' then 'no_show'
                            when b.status = 'pending_payment' then 'pending'
                            else 'booked'
                          end)
                        order by m.first_name, m.last_name)
                   from bookings b
                   join members m on m.id = b.member_id
                  where b.occurrence_id = o.id
                    and b.status in ('booked','attended','no_show','pending_payment')
               ), '[]'::jsonb)
             ) as c
        from class_occurrences o
        left join class_types ct on ct.id = o.class_type_id
        left join rooms rm       on rm.id = o.room_id
        left join instructors i  on i.id = o.instructor_id
       where o.studio_id = p_studio_id
         and o.status <> 'cancelled'
         and o.starts_at >= v_t0 and o.starts_at < v_t1
    ) q);
end $$;

revoke all on function dashboard_today_classes(uuid, date) from public, anon;
grant execute on function dashboard_today_classes(uuid, date) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- dashboard_occupancy_30d — classes that ran in the last 30 studio-local days,
-- booked over capacity, emptiest first. The per-class list behind the occupancy
-- card.
-- ---------------------------------------------------------------------------
create function dashboard_occupancy_30d(p_studio_id uuid)
returns table (
  occurrence_id uuid, name text, starts_at timestamptz, room text,
  instructor text, booked int, capacity int, pct int
)
language plpgsql stable security definer set search_path = public as $$
declare v_today date; v_t0 timestamptz; v_t1 timestamptz;
begin
  if not (is_desk_up(p_studio_id) or is_service_context()) then
    raise exception 'that is another studio''s classes' using errcode = 'PT403';
  end if;
  v_today := studio_today(p_studio_id);
  select day_start into v_t0 from studio_day_bounds(p_studio_id, v_today);

  return query
  select o.id, coalesce(o.name, ct.name, 'Class'), o.starts_at, rm.name,
         split_part(coalesce(i.display_name, ''), ' ', 1),
         o.booked_count, o.capacity,
         (round(100.0 * o.booked_count / nullif(o.capacity, 0)))::int as pct
    from class_occurrences o
    left join class_types ct on ct.id = o.class_type_id
    left join rooms rm       on rm.id = o.room_id
    left join instructors i  on i.id = o.instructor_id
   where o.studio_id = p_studio_id and o.status <> 'cancelled'
     and o.starts_at >= v_t0 - interval '30 days'
     and o.starts_at <= least((select day_end from studio_day_bounds(p_studio_id, v_today)), now())
   order by pct asc nulls first, o.starts_at;
end $$;

revoke all on function dashboard_occupancy_30d(uuid) from public, anon;
grant execute on function dashboard_occupancy_30d(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- dashboard_free_first_members — members who took a free first class (the
-- self-signup free-first cohort, host-null guest passes), with the date, whether
-- they converted, and the plan they bought. brought_by_member carries the
-- host-brought count (Decision 26) as one line, since that card is gone from the
-- dashboard. Returns jsonb { members:[...], brought_by_member:int }.
-- ---------------------------------------------------------------------------
create function dashboard_free_first_members(p_studio_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_tz text; v_members jsonb; v_brought int;
begin
  if not (is_desk_up(p_studio_id) or is_service_context()) then
    raise exception 'that is another studio''s members' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios s where s.id = p_studio_id;

  select coalesce(jsonb_agg(row order by free_at desc), '[]'::jsonb)
    into v_members
  from (
    select gp.guest_member_id as member_id,
           coalesce(o.starts_at, gp.created_at) as free_at,
           jsonb_build_object(
             'member_id', gp.guest_member_id,
             'name', (m.first_name || ' ' || m.last_name),
             'free_class_date', (coalesce(o.starts_at, gp.created_at) at time zone v_tz)::date,
             'converted', conv.membership_id is not null,
             'plan_bought', conv.plan_name
           ) as row
      from guest_passes gp
      join members m on m.id = gp.guest_member_id
      left join bookings b on b.id = gp.guest_booking_id
      left join class_occurrences o on o.id = b.occurrence_id
      left join lateral (
        select ms.id as membership_id, mp.name as plan_name
          from memberships ms
          join membership_plans mp on mp.id = ms.plan_id
         where ms.member_id = gp.guest_member_id
         order by ms.created_at
         limit 1
      ) conv on true
     where gp.studio_id = p_studio_id and gp.host_member_id is null
  ) t;

  select count(*) into v_brought
    from guest_passes gp
   where gp.studio_id = p_studio_id and gp.host_member_id is not null;

  return jsonb_build_object('members', v_members, 'brought_by_member', coalesce(v_brought, 0));
end $$;

revoke all on function dashboard_free_first_members(uuid) from public, anon;
grant execute on function dashboard_free_first_members(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- dashboard_challenge_kpi — re-issued so the card's href carries the challenge
-- id (the detail page lists participants with progress), not the challenge list.
-- Body otherwise unchanged from migration 20260831260000.
-- ---------------------------------------------------------------------------
create or replace function dashboard_challenge_kpi(p_studio_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_active int; v_joined int; v_completed int; v_cid uuid;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'the dashboard is for owners and managers' using errcode = 'PT403';
  end if;

  if not exists (select 1 from challenges
                  where studio_id = p_studio_id and audience = 'member'
                    and status in ('scheduled','active','ended')) then
    return null;
  end if;

  select count(*) into v_active from challenges
   where studio_id = p_studio_id and audience = 'member' and status = 'active';

  if v_active > 0 then
    select id into v_cid from challenges
     where studio_id = p_studio_id and audience = 'member' and status = 'active'
     order by ends_on desc limit 1;
    select count(*), count(*) filter (where p.completed_at is not null)
      into v_joined, v_completed
      from challenge_participants p
      join challenges c on c.id = p.challenge_id
     where c.studio_id = p_studio_id and c.audience = 'member' and c.status = 'active';
  else
    select id into v_cid from challenges
      where studio_id = p_studio_id and audience = 'member'
        and status in ('scheduled','ended')
      order by ends_on desc limit 1;
    select count(*), count(*) filter (where p.completed_at is not null)
      into v_joined, v_completed
      from challenge_participants p
     where p.challenge_id = v_cid;
  end if;

  return jsonb_build_object(
    'key', 'challenge_participation',
    'label', 'Challenge participation',
    'state', case when coalesce(v_joined,0) = 0 then 'empty' else 'ok' end,
    'kind', 'count',
    'value', coalesce(v_joined, 0),
    'sub', coalesce(v_completed,0) || ' completed'
           || case when v_active > 0 then ' · ' || v_active || ' running' else '' end,
    'href', '/challenges/' || v_cid,
    'empty_hint', 'Nobody has joined yet. It fills as members opt in.');
end $$;

revoke execute on function dashboard_challenge_kpi(uuid) from public, anon;
grant  execute on function dashboard_challenge_kpi(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- dashboard_free_first_kpi — re-issued so the conversion card opens the new
-- Members-who-took-a-free-class list. This is Decision 86's eighth card (the
-- host-guest card is dropped from the dashboard). Body otherwise unchanged from
-- migration 20260831630000.
-- ---------------------------------------------------------------------------
create or replace function dashboard_free_first_kpi(p_studio_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_total int; v_conv int;
begin
  if not (coalesce(is_manager_up(p_studio_id), false) or is_service_context()) then
    raise exception 'not authorised' using errcode = 'PT403';
  end if;
  if not coalesce((select free_first_class_enabled from studio_settings where studio_id = p_studio_id), false) then
    return null;
  end if;
  select count(*),
         count(*) filter (where exists (select 1 from memberships ms where ms.member_id = gp.guest_member_id))
    into v_total, v_conv
    from guest_passes gp where gp.studio_id = p_studio_id and gp.host_member_id is null;
  if coalesce(v_total, 0) = 0 then return null; end if;
  return jsonb_build_object(
    'key', 'free_first_conversion', 'label', 'First-timers converted',
    'state', case when v_conv = 0 then 'empty' else 'ok' end,
    'kind', 'count', 'value', v_conv,
    'sub', 'of ' || v_total || ' free first ' || case when v_total = 1 then 'class' else 'classes' end,
    'href', '/dashboard/free-classes', 'empty_hint', 'None have bought a plan yet.');
end $$;

revoke all on function dashboard_free_first_kpi(uuid) from public, anon;
grant execute on function dashboard_free_first_kpi(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- anon stays EXACTLY THIRTEEN. None of the above is anon; member_plan_overview's
-- drop+recreate re-asserted authenticated-only.
-- ---------------------------------------------------------------------------
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'expect_%' and p.proname not in ('login','sig','psig');
  if n <> 13 then
    raise exception 'anon surface is %, expected 13', n;
  end if;
end $$;
