-- =============================================================================
-- Decision 56 — recent bookings feed + core/flex tier suggestions.
-- =============================================================================
-- UUID space 56de, checked free. Run after `supabase db reset`.
--
-- SA (Prague, guarantees + flex on, core_min 3) carries the booking feed and
-- the tier series; SB exists only to prove another studio's data never leaks;
-- SC has both tiers off, to prove the suggestions block is inert (the canary).
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'BAD  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual then raise notice 'PASS  %', label;
  else raise exception 'BAD  %  expected true, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_txt(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (%)', label, coalesce(actual,'null');
  else raise exception 'BAD  %  expected "%", got "%"', label, want, coalesce(actual,'null'); end if;
end $$;
create or replace function expect_raises(label text, stmt text, want_sqlstate text)
returns void language plpgsql as $$
begin
  execute stmt; raise exception 'BAD  %  expected % but nothing was raised', label, want_sqlstate;
exception when others then
  if sqlstate = want_sqlstate then raise notice 'PASS  %  (got %)', label, sqlstate;
  elsif sqlstate = 'P0001' and sqlerrm like 'BAD%' then raise;
  else raise exception 'BAD  %  expected %, got % (%)', label, want_sqlstate, sqlstate, sqlerrm; end if;
end $$;

-- --- Fixtures: three studios ------------------------------------------------
insert into studios (id, name, slug, timezone, currency, status) values
  ('56de56de-0000-0000-0000-0000000000a1','Sugg A','56de-sa','Europe/Prague','CZK','active'),
  ('56de56de-0000-0000-0000-0000000000b1','Sugg B','56de-sb','Europe/Prague','CZK','active'),
  ('56de56de-0000-0000-0000-0000000000c1','Sugg C','56de-sc','Europe/Prague','CZK','active');
-- SA and SB run tiers (core_min 3); SC runs neither (the canary).
insert into studio_settings (studio_id, require_waiver, guarantees_enabled, flex_enabled, core_min_bookings, time_format) values
  ('56de56de-0000-0000-0000-0000000000a1', false, true,  true,  3, '24h'),
  ('56de56de-0000-0000-0000-0000000000b1', false, true,  true,  3, '24h'),
  ('56de56de-0000-0000-0000-0000000000c1', false, false, false, 3, '24h');
insert into locations (id, studio_id, name, is_primary) values
  ('56de56de-0000-0000-0000-0000000000aa','56de56de-0000-0000-0000-0000000000a1','Main',true),
  ('56de56de-0000-0000-0000-0000000000bb','56de56de-0000-0000-0000-0000000000b1','Main',true),
  ('56de56de-0000-0000-0000-0000000000cc','56de56de-0000-0000-0000-0000000000c1','Main',true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('56de56de-0000-0000-0000-00000000aa01','56de56de-0000-0000-0000-0000000000a1','56de56de-0000-0000-0000-0000000000aa','RA',12),
  ('56de56de-0000-0000-0000-00000000bb01','56de56de-0000-0000-0000-0000000000b1','56de56de-0000-0000-0000-0000000000bb','RB',12),
  ('56de56de-0000-0000-0000-00000000cc01','56de56de-0000-0000-0000-0000000000c1','56de56de-0000-0000-0000-0000000000cc','RC',12);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('56de56de-0000-0000-0000-0000000c7a01','56de56de-0000-0000-0000-0000000000a1','Reformer',50,12),
  ('56de56de-0000-0000-0000-0000000c7b01','56de56de-0000-0000-0000-0000000000b1','Reformer',50,12),
  ('56de56de-0000-0000-0000-0000000c7c01','56de56de-0000-0000-0000-0000000000c1','Reformer',50,12);

-- Staff logins: SA owner (manager-up) + SA front desk; SB owner.
insert into auth.users (id) values
  ('56de56de-0000-0000-0000-0000000000f1'),
  ('56de56de-0000-0000-0000-0000000000f2'),
  ('56de56de-0000-0000-0000-0000000000f3');
insert into profiles (id, email) values
  ('56de56de-0000-0000-0000-0000000000f1','56de-owner@example.com'),
  ('56de56de-0000-0000-0000-0000000000f2','56de-desk@example.com'),
  ('56de56de-0000-0000-0000-0000000000f3','56de-sbowner@example.com');
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('56de56de-0000-0000-0000-00000005f001','56de56de-0000-0000-0000-0000000000a1','56de56de-0000-0000-0000-0000000000f1','56de-owner@example.com','owner'),
  ('56de56de-0000-0000-0000-00000005f002','56de56de-0000-0000-0000-0000000000a1','56de56de-0000-0000-0000-0000000000f2','56de-desk@example.com','front_desk'),
  ('56de56de-0000-0000-0000-00000005f003','56de56de-0000-0000-0000-0000000000b1','56de56de-0000-0000-0000-0000000000f3','56de-sbowner@example.com','owner');

-- Member pools. SA tier pool (reused across occurrences), SA recent-feed members,
-- SB member, SC member.
insert into members (id, studio_id, email, first_name, last_name, status) values
  ('56de56de-0000-0000-0000-0000000d0001','56de56de-0000-0000-0000-0000000000a1','d1@example.com','D','One','active'),
  ('56de56de-0000-0000-0000-0000000d0002','56de56de-0000-0000-0000-0000000000a1','d2@example.com','D','Two','active'),
  ('56de56de-0000-0000-0000-0000000d0003','56de56de-0000-0000-0000-0000000000a1','d3@example.com','D','Three','active'),
  ('56de56de-0000-0000-0000-0000000d0004','56de56de-0000-0000-0000-0000000000a1','d4@example.com','D','Four','active'),
  ('56de56de-0000-0000-0000-0000000d0005','56de56de-0000-0000-0000-0000000000a1','d5@example.com','D','Five','active'),
  ('56de56de-0000-0000-0000-0000000d0006','56de56de-0000-0000-0000-0000000000a1','d6@example.com','D','Six','active'),
  ('56de56de-0000-0000-0000-0000000e0001','56de56de-0000-0000-0000-0000000000a1','r1@example.com','Ray','Booker','active'),
  ('56de56de-0000-0000-0000-0000000e0002','56de56de-0000-0000-0000-0000000000a1','r2@example.com','Fay','Free','active'),
  ('56de56de-0000-0000-0000-0000000e0003','56de56de-0000-0000-0000-0000000000a1','r3@example.com','Cay','Cancel','active'),
  ('56de56de-0000-0000-0000-0000000e0004','56de56de-0000-0000-0000-0000000000a1','r4@example.com','Lay','Late','active'),
  ('56de56de-0000-0000-0000-0000000e0005','56de56de-0000-0000-0000-0000000000a1','r5@example.com','Nay','Notified','active'),
  ('56de56de-0000-0000-0000-0000000e0006','56de56de-0000-0000-0000-0000000000a1','r6@example.com','May','Notified','active'),
  ('56de56de-0000-0000-0000-0000000e00b1','56de56de-0000-0000-0000-0000000000b1','sb@example.com','Es','Bee','active'),
  ('56de56de-0000-0000-0000-0000000e00c1','56de56de-0000-0000-0000-0000000000c1','sc@example.com','See','Cee','active');

-- --- Recent-feed occurrences (SA) + the one SB occurrence -------------------
insert into class_occurrences
  (id, studio_id, location_id, class_type_id, room_id, name, capacity, booked_count, starts_at, ends_at, status, cancelled_at)
values
  -- Morning Flow, future, 10:00 local — the booked/free/cancel/late rows hang off it.
  ('56de56de-0000-0000-0000-00000000cc01','56de56de-0000-0000-0000-0000000000a1','56de56de-0000-0000-0000-0000000000aa',
   '56de56de-0000-0000-0000-0000000c7a01','56de56de-0000-0000-0000-00000000aa01','Morning Flow',12,1,
   ((current_date + 1) + time '10:00') at time zone 'Europe/Prague',
   ((current_date + 1) + time '10:50') at time zone 'Europe/Prague','scheduled', null),
  -- Evening Burn, cancelled now() — the class_cancelled row, 2 members notified.
  ('56de56de-0000-0000-0000-00000000cc02','56de56de-0000-0000-0000-0000000000a1','56de56de-0000-0000-0000-0000000000aa',
   '56de56de-0000-0000-0000-0000000c7a01','56de56de-0000-0000-0000-00000000aa01','Evening Burn',12,0,
   ((current_date + 1) + time '18:00') at time zone 'Europe/Prague',
   ((current_date + 1) + time '18:50') at time zone 'Europe/Prague','cancelled', now()),
  -- SB occurrence, future.
  ('56de56de-0000-0000-0000-00000000cb01','56de56de-0000-0000-0000-0000000000b1','56de56de-0000-0000-0000-0000000000bb',
   '56de56de-0000-0000-0000-0000000c7b01','56de56de-0000-0000-0000-00000000bb01','SB Class',12,1,
   ((current_date + 1) + time '09:00') at time zone 'Europe/Prague',
   ((current_date + 1) + time '09:50') at time zone 'Europe/Prague','scheduled', null);

insert into bookings
  (studio_id, occurrence_id, member_id, status, payment_source, provisional, is_late_cancel, release_reason, booked_at, cancelled_at)
values
  -- a seat taken (booked)
  ('56de56de-0000-0000-0000-0000000000a1','56de56de-0000-0000-0000-00000000cc01','56de56de-0000-0000-0000-0000000e0001','booked','membership',false,false,null, now() - interval '1 hour', null),
  -- a free-first/comp seat (booked_free)
  ('56de56de-0000-0000-0000-0000000000a1','56de56de-0000-0000-0000-00000000cc01','56de56de-0000-0000-0000-0000000e0002','booked','comp',true,false,null, now() - interval '2 hour', null),
  -- a member cancellation
  ('56de56de-0000-0000-0000-0000000000a1','56de56de-0000-0000-0000-00000000cc01','56de56de-0000-0000-0000-0000000e0003','cancelled','membership',false,false,'member_cancelled', now() - interval '1 day', now() - interval '3 hour'),
  -- a late cancellation
  ('56de56de-0000-0000-0000-0000000000a1','56de56de-0000-0000-0000-00000000cc01','56de56de-0000-0000-0000-0000000e0004','late_cancelled','membership',false,true,'late_cancelled', now() - interval '1 day', now() - interval '4 hour'),
  -- two seats released by the studio cancellation of Evening Burn
  ('56de56de-0000-0000-0000-0000000000a1','56de56de-0000-0000-0000-00000000cc02','56de56de-0000-0000-0000-0000000e0005','cancelled','membership',false,false,'studio_released', now() - interval '2 day', now() - interval '30 minute'),
  ('56de56de-0000-0000-0000-0000000000a1','56de56de-0000-0000-0000-00000000cc02','56de56de-0000-0000-0000-0000000e0006','cancelled','membership',false,false,'studio_released', now() - interval '2 day', now() - interval '30 minute'),
  -- the SB booking (must never appear in SA's feed)
  ('56de56de-0000-0000-0000-0000000000b1','56de56de-0000-0000-0000-00000000cb01','56de56de-0000-0000-0000-0000000e00b1','booked','membership',false,false,null, now() - interval '1 hour', null);

-- --- Tier series (SA) + SC's would-qualify-but-off series -------------------
-- Each series' past occurrences carry a controlled confirmed headcount. starts_on
-- is set far out so the materialise trigger creates nothing now; the only
-- occurrences that exist are the ones inserted here, all in the last 28 days.
do $$
declare
  sa  uuid := '56de56de-0000-0000-0000-0000000000a1';
  loc uuid := '56de56de-0000-0000-0000-0000000000aa';
  rm  uuid := '56de56de-0000-0000-0000-00000000aa01';
  ct  uuid := '56de56de-0000-0000-0000-0000000c7a01';
  pool uuid[] := array[
    '56de56de-0000-0000-0000-0000000d0001','56de56de-0000-0000-0000-0000000d0002',
    '56de56de-0000-0000-0000-0000000d0003','56de56de-0000-0000-0000-0000000d0004',
    '56de56de-0000-0000-0000-0000000d0005','56de56de-0000-0000-0000-0000000d0006']::uuid[];
  rec   record;
  v_ser uuid; occ uuid; i int; j int; st timestamptz; s_idx int := 0;
begin
  for rec in
    select * from (values
      ('Core Low','core', false, array[1,2,2,3], false, false),
      ('Core Ok', 'core', false, array[2,2,3,4], false, false),
      ('Flex All',null,   true,  array[3,3,4,4], false, false),
      ('Flex Three',null, true,  array[3,3,3,2], false, false),
      ('Only Three','core',false,array[1,1,1],   false, false),
      ('Prov Core','core',false, array[4,4,4,4], true,  false),
      ('Canx Core','core',false, array[2,2,2,2], false, true )
    ) as t(nm, gt, fx, counts, prov, canx)
  loop
    insert into class_series
      (id, studio_id, location_id, class_type_id, room_id, name, capacity, duration_minutes,
       rrule, starts_on, time_of_day, status, guarantee_tier, flex)
    values
      (gen_random_uuid(), sa, loc, ct, rm, rec.nm, 12, 50,
       'FREQ=WEEKLY;BYDAY=MO', current_date + 400, time '07:00', 'active',
       coalesce(rec.gt,'core')::guarantee_tier, rec.fx)
    returning id into v_ser;
    s_idx := s_idx + 1;

    for i in 1 .. array_length(rec.counts, 1) loop
      -- Stagger each series by an hour so occurrences never overlap in the one
      -- room (the GiST exclusion constraint); 2 days apart across i, 1h across series.
      st := now() - (i * interval '2 days') - (s_idx * interval '1 hour');
      insert into class_occurrences
        (id, studio_id, location_id, class_type_id, room_id, name, capacity, booked_count,
         starts_at, ends_at, status, series_id)
      values
        (gen_random_uuid(), sa, loc, ct, rm, rec.nm, 12, rec.counts[i],
         st, st + interval '50 min', 'scheduled', v_ser)
      returning id into occ;
      for j in 1 .. rec.counts[i] loop
        insert into bookings (studio_id, occurrence_id, member_id, status, payment_source, provisional, booked_at)
        values (sa, occ, pool[j], 'attended', 'membership', rec.prov, st);
        -- when prov: the seat is a provisional comp one, which booked_start excludes.
        if rec.prov then
          update bookings set payment_source = 'comp'
           where occurrence_id = occ and member_id = pool[j];
        end if;
      end loop;
    end loop;

    -- Canx Core: a cancelled occurrence (newest for the series) whose 3 seats
    -- would flip below_or_met from 4 to 3 if it were counted. It must not be.
    if rec.canx then
      st := now() - interval '1 day';
      insert into class_occurrences
        (id, studio_id, location_id, class_type_id, room_id, name, capacity, booked_count,
         starts_at, ends_at, status, cancelled_at, series_id)
      values
        (gen_random_uuid(), sa, loc, ct, rm, rec.nm, 12, 3,
         st, st + interval '50 min', 'cancelled', now() - interval '10 days', v_ser)
      returning id into occ;
      for j in 1 .. 3 loop
        insert into bookings (studio_id, occurrence_id, member_id, status, payment_source, provisional, booked_at)
        values (sa, occ, pool[j], 'attended', 'membership', false, st);
      end loop;
    end if;
  end loop;

  -- SC: a core series that WOULD suggest flex (4 past occ, 1 booked each, below
  -- min 3) — but SC has both tiers off, so tier_suggestions returns nothing.
  insert into class_series
    (id, studio_id, location_id, class_type_id, room_id, name, capacity, duration_minutes,
     rrule, starts_on, time_of_day, status, guarantee_tier, flex)
  values
    (gen_random_uuid(), '56de56de-0000-0000-0000-0000000000c1',
     '56de56de-0000-0000-0000-0000000000cc', '56de56de-0000-0000-0000-0000000c7c01',
     '56de56de-0000-0000-0000-00000000cc01', 'SC Low', 12, 50,
     'FREQ=WEEKLY;BYDAY=MO', current_date + 400, time '07:00', 'active', 'core', false)
  returning id into v_ser;
  for i in 1 .. 4 loop
    st := now() - (i * interval '2 days') - interval '1 hour';
    insert into class_occurrences
      (id, studio_id, location_id, class_type_id, room_id, name, capacity, booked_count,
       starts_at, ends_at, status, series_id)
    values
      (gen_random_uuid(), '56de56de-0000-0000-0000-0000000000c1',
       '56de56de-0000-0000-0000-0000000000cc', '56de56de-0000-0000-0000-0000000c7c01',
       '56de56de-0000-0000-0000-00000000cc01', 'SC Low', 12, 1,
       st, st + interval '50 min', 'scheduled', v_ser)
    returning id into occ;
    insert into bookings (studio_id, occurrence_id, member_id, status, payment_source, provisional, booked_at)
    values ('56de56de-0000-0000-0000-0000000000c1', occ, '56de56de-0000-0000-0000-0000000e00c1', 'attended', 'membership', false, st);
  end loop;
end $$;

-- =============================================================================
-- A. Recent bookings — the five kinds, ordering, limit, isolation, clock.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','56de56de-0000-0000-0000-0000000000f1',false);

select expect_txt('recent: a seat taken reads booked',
  (select kind from dashboard_recent_bookings('56de56de-0000-0000-0000-0000000000a1', 30)
     where member_name = 'Ray Booker' and class_name = 'Morning Flow'), 'booked');
select expect_txt('recent: a comp/provisional seat reads booked_free',
  (select kind from dashboard_recent_bookings('56de56de-0000-0000-0000-0000000000a1', 30)
     where member_name = 'Fay Free'), 'booked_free');
select expect_txt('recent: a member cancellation reads cancelled',
  (select kind from dashboard_recent_bookings('56de56de-0000-0000-0000-0000000000a1', 30)
     where member_name = 'Cay Cancel'), 'cancelled');
select expect_txt('recent: a late cancellation reads cancelled_late',
  (select kind from dashboard_recent_bookings('56de56de-0000-0000-0000-0000000000a1', 30)
     where member_name = 'Lay Late'), 'cancelled_late');
select expect_txt('recent: a studio class cancellation reads class_cancelled',
  (select kind from dashboard_recent_bookings('56de56de-0000-0000-0000-0000000000a1', 30)
     where class_name = 'Evening Burn' and kind = 'class_cancelled'), 'class_cancelled');
select expect_txt('recent: class_cancelled names how many were notified',
  (select detail from dashboard_recent_bookings('56de56de-0000-0000-0000-0000000000a1', 30)
     where class_name = 'Evening Burn' and kind = 'class_cancelled'), '2 members notified');
select expect_true('recent: a studio release is NOT also a member cancellation',
  (select count(*) = 0 from dashboard_recent_bookings('56de56de-0000-0000-0000-0000000000a1', 30)
     where (member_name = 'Nay Notified' or member_name = 'May Notified') and kind like 'cancelled%'));

-- newest first: the Evening Burn cancellation happened now(), so it leads.
select expect_txt('recent: newest first (Evening Burn now() leads)',
  (select class_name from dashboard_recent_bookings('56de56de-0000-0000-0000-0000000000a1', 30) limit 1), 'Evening Burn');
-- limit respected.
select expect_num('recent: limit respected',
  (select count(*) from dashboard_recent_bookings('56de56de-0000-0000-0000-0000000000a1', 2))::bigint, 2);
-- no cross-studio row.
select expect_num('recent: no SB booking in SA feed',
  (select count(*) from dashboard_recent_bookings('56de56de-0000-0000-0000-0000000000a1', 30)
     where member_name = 'Es Bee')::bigint, 0);
-- clock: 24h shows "10:00".
select expect_true('recent: when_label is 24h (10:00)',
  (select when_label ~ ' 10:00$' from dashboard_recent_bookings('56de56de-0000-0000-0000-0000000000a1', 30)
     where member_name = 'Ray Booker'));
reset role;

-- flip SA to 12h and re-read the same row.
update studio_settings set time_format = '12h' where studio_id = '56de56de-0000-0000-0000-0000000000a1';
set role authenticated;
select set_config('request.jwt.claim.sub','56de56de-0000-0000-0000-0000000000f1',false);
select expect_true('recent: when_label honours 12h (10:00 AM)',
  (select when_label ~ ' 10:00 AM$' from dashboard_recent_bookings('56de56de-0000-0000-0000-0000000000a1', 30)
     where member_name = 'Ray Booker'));
reset role;
update studio_settings set time_format = '24h' where studio_id = '56de56de-0000-0000-0000-0000000000a1';

-- =============================================================================
-- B. Tier suggestions — thresholds, provisional/cancelled exclusion.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','56de56de-0000-0000-0000-0000000000f1',false);

-- core, 3 of last 4 below min (3) -> suggest flex, exact sentence.
select expect_txt('tier: core 3/4 below -> suggest flex',
  (select suggested_tier from tier_suggestions('56de56de-0000-0000-0000-0000000000a1') where class_name = 'Core Low'), 'flex');
select expect_num('tier: Core Low below count = 3',
  (select below_or_met from tier_suggestions('56de56de-0000-0000-0000-0000000000a1') where class_name = 'Core Low')::bigint, 3);
select expect_txt('tier: Core Low exact sentence',
  (select sentence from tier_suggestions('56de56de-0000-0000-0000-0000000000a1') where class_name = 'Core Low'),
  'Consider making Core Low flex — 3 of the last 4 classes had fewer than 3 booked (avg 2.0)');

-- core, only 2 of 4 below -> NO row (the case the brief insists on proving).
select expect_num('tier: core 2/4 below -> no row',
  (select count(*) from tier_suggestions('56de56de-0000-0000-0000-0000000000a1') where class_name = 'Core Ok')::bigint, 0);

-- flex, all 4 met -> suggest core, exact sentence.
select expect_txt('tier: flex 4/4 met -> suggest core',
  (select suggested_tier from tier_suggestions('56de56de-0000-0000-0000-0000000000a1') where class_name = 'Flex All'), 'core');
select expect_txt('tier: Flex All exact sentence',
  (select sentence from tier_suggestions('56de56de-0000-0000-0000-0000000000a1') where class_name = 'Flex All'),
  'Consider making Flex All core — all of the last 4 met the core minimum (avg 3.5)');

-- flex, only 3 of 4 met -> NO row.
select expect_num('tier: flex 3/4 met -> no row',
  (select count(*) from tier_suggestions('56de56de-0000-0000-0000-0000000000a1') where class_name = 'Flex Three')::bigint, 0);

-- only 3 completed occurrences -> NO row.
select expect_num('tier: fewer than 4 completed -> no row',
  (select count(*) from tier_suggestions('56de56de-0000-0000-0000-0000000000a1') where class_name = 'Only Three')::bigint, 0);

-- provisional seats are not counted: 4 provisional on a core class reads below
-- the min in all 4, so it still suggests flex (below = 4).
select expect_txt('tier: provisional seats excluded -> still below min',
  (select suggested_tier from tier_suggestions('56de56de-0000-0000-0000-0000000000a1') where class_name = 'Prov Core'), 'flex');
select expect_num('tier: Prov Core below count = 4 (nothing confirmed)',
  (select below_or_met from tier_suggestions('56de56de-0000-0000-0000-0000000000a1') where class_name = 'Prov Core')::bigint, 4);

-- a cancelled occurrence is not counted: Canx Core has 4 valid below-min classes
-- (below = 4); the cancelled one with 3 seats would drop below to 3 if counted.
select expect_num('tier: cancelled occurrence excluded (below stays 4)',
  (select below_or_met from tier_suggestions('56de56de-0000-0000-0000-0000000000a1') where class_name = 'Canx Core')::bigint, 4);

-- considered is always 4.
select expect_num('tier: considered = 4',
  (select considered from tier_suggestions('56de56de-0000-0000-0000-0000000000a1') where class_name = 'Core Low')::bigint, 4);
reset role;

-- =============================================================================
-- C. Guards.
-- =============================================================================
-- Front desk: refused tier_suggestions, allowed recent bookings.
set role authenticated;
select set_config('request.jwt.claim.sub','56de56de-0000-0000-0000-0000000000f2',false);
select expect_raises('front desk PT403 on tier_suggestions',
  $$ select * from tier_suggestions('56de56de-0000-0000-0000-0000000000a1') $$, 'PT403');
select expect_true('front desk may read recent bookings',
  (select count(*) >= 0 from dashboard_recent_bookings('56de56de-0000-0000-0000-0000000000a1', 30)));
reset role;

-- SA owner on SB: refused both.
set role authenticated;
select set_config('request.jwt.claim.sub','56de56de-0000-0000-0000-0000000000f1',false);
select expect_raises('SA owner PT403 on SB tier_suggestions',
  $$ select * from tier_suggestions('56de56de-0000-0000-0000-0000000000b1') $$, 'PT403');
select expect_raises('SA owner PT403 on SB recent bookings',
  $$ select * from dashboard_recent_bookings('56de56de-0000-0000-0000-0000000000b1', 30) $$, 'PT403');
reset role;

-- =============================================================================
-- D. The canary — guarantees + flex both off -> zero rows, data regardless.
-- =============================================================================
-- Run as service context (postgres); SC has a core series that would suggest
-- flex if tiers were on, so zero rows here is the switch, not an empty studio.
select expect_num('canary: SC has the would-qualify series',
  (select count(*) from class_series where studio_id = '56de56de-0000-0000-0000-0000000000c1' and status = 'active')::bigint, 1);
select expect_num('canary: tiers off -> tier_suggestions returns nothing',
  (select count(*) from tier_suggestions('56de56de-0000-0000-0000-0000000000c1'))::bigint, 0);

select 'tier_suggestions_test: all assertions passed' as result;
