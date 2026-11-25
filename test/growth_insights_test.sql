-- =============================================================================
-- Decision 106 — growth insights within the core budget.
-- Migration 20260833570000. UUID space 9106, checked free. After `supabase db reset`.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$ begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$ begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if; end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$ begin
  if coalesce(actual,false) then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_false(label text, actual boolean)
returns void language plpgsql as $$ begin
  if not coalesce(actual,true) then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected false, got %', label, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_raise(label text, code text, sql text)
returns void language plpgsql as $$ begin
  begin execute sql; raise exception 'FAIL  %  expected %, no error', label, code;
  exception when others then
    if sqlstate = code then raise notice 'PASS  %  (%)', label, code;
    else raise exception 'FAIL  %  expected %, got % (%)', label, code, sqlstate, sqlerrm; end if; end; end $$;

-- helpers to reach into growth_insights output
create or replace function g106_week() returns date language sql stable as $$
  select (date_trunc('week', now() at time zone 'Asia/Manila')::date + 7);
$$;
create or replace function g106(studio uuid) returns jsonb language sql stable as $$
  select growth_insights(studio, g106_week());
$$;
create or replace function g106_slot(gi jsonb, series uuid) returns jsonb language sql as $$
  select s from jsonb_array_elements(gi->'coaches') c,
       jsonb_array_elements(c->'days') d, jsonb_array_elements(d->'slots') s
   where (s->>'series_id')::uuid = series limit 1;
$$;
create or replace function g106_coach(gi jsonb, instr uuid) returns jsonb language sql as $$
  select c from jsonb_array_elements(gi->'coaches') c where (c->>'instructor_id')::uuid = instr limit 1;
$$;
create or replace function g106_day(gi jsonb, instr uuid, dow int) returns jsonb language sql as $$
  select d from jsonb_array_elements(gi->'coaches') c, jsonb_array_elements(c->'days') d
   where (c->>'instructor_id')::uuid = instr and (d->>'dow')::int = dow limit 1;
$$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('91060000-0000-0000-0000-00000000a0a1'),  -- GA owner
  ('91060000-0000-0000-0000-00000000a0f1'),  -- GA front desk
  ('91060000-0000-0000-0000-00000000b0b1');  -- GB owner
insert into profiles (id, email, full_name) values
  ('91060000-0000-0000-0000-00000000a0a1','ga-own@9106.example','Olga Owner'),
  ('91060000-0000-0000-0000-00000000a0f1','ga-fd@9106.example','Fred Desk'),
  ('91060000-0000-0000-0000-00000000b0b1','gb-own@9106.example','Bo Owner');

insert into studios (id, name, slug, timezone, currency, country, status) values
  ('91060000-0000-0000-0000-0000000000a1','Growth A','9106-a','Asia/Manila','PHP','PH','active'),
  ('91060000-0000-0000-0000-0000000000b1','Growth B','9106-b','Asia/Manila','PHP','PH','active');
-- flex + guarantees on, or occurrence_guarantee_run demotes every flex slot to
-- core (Decision 21: flex is opt-in per studio).
insert into studio_settings (studio_id, flex_min_bookings, core_min_bookings, ai_drafts_enabled,
                             flex_enabled, guarantees_enabled) values
  ('91060000-0000-0000-0000-0000000000a1', 2, 1, false, true, true),
  ('91060000-0000-0000-0000-0000000000b1', 2, 1, false, true, true);
insert into locations (id, studio_id, name, is_primary) values
  ('91060000-0000-0000-0000-00000000a0cc','91060000-0000-0000-0000-0000000000a1','Main',true),
  ('91060000-0000-0000-0000-00000000b0cc','91060000-0000-0000-0000-0000000000b1','Main',true);
insert into studio_staff (id, studio_id, user_id, email, role, status) values
  ('91060000-0000-0000-0000-00000000a5a1','91060000-0000-0000-0000-0000000000a1','91060000-0000-0000-0000-00000000a0a1','ga-own@9106.example','owner','active'),
  ('91060000-0000-0000-0000-00000000a5f1','91060000-0000-0000-0000-0000000000a1','91060000-0000-0000-0000-00000000a0f1','ga-fd@9106.example','front_desk','active'),
  ('91060000-0000-0000-0000-00000000b5b1','91060000-0000-0000-0000-0000000000b1','91060000-0000-0000-0000-00000000b0b1','gb-own@9106.example','owner','active');
insert into instructors (id, studio_id, display_name, status) values
  ('91060000-0000-0000-0000-0000000001a1','91060000-0000-0000-0000-0000000000a1','Ann Coach','active'),
  ('91060000-0000-0000-0000-0000000002a1','91060000-0000-0000-0000-0000000000a1','Ben Coach','active'),
  ('91060000-0000-0000-0000-0000000003b1','91060000-0000-0000-0000-0000000000b1','Cara Three','active'),
  ('91060000-0000-0000-0000-0000000004b1','91060000-0000-0000-0000-0000000000b1','Dan Four','active'),
  ('91060000-0000-0000-0000-0000000005b1','91060000-0000-0000-0000-0000000000b1','Eve Five','active');
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('91060000-0000-0000-0000-00000000c7a1','91060000-0000-0000-0000-0000000000a1','Reformer',50,8),
  ('91060000-0000-0000-0000-00000000c7b1','91060000-0000-0000-0000-0000000000b1','Reformer',50,8);

-- GA member pool (12) + a nudge member
do $$ declare i int; begin
  for i in 1..12 loop
    insert into members (id, studio_id, first_name, last_name, email, status)
    values (('91060000-0000-0000-0000-0000000d00' || lpad(i::text,2,'0'))::uuid,
            '91060000-0000-0000-0000-0000000000a1', 'Mem'||i, 'Pool',
            'mem'||i||'@9106.example', 'active');
  end loop;
  insert into members (id, studio_id, first_name, last_name, email, phone, status)
  values ('91060000-0000-0000-0000-0000000d0099','91060000-0000-0000-0000-0000000000a1',
          'Nadia','Nudge','nudge@9106.example','+63 900 000 0099','active');
end $$;

-- --- GA slots: series + past occurrences (history) + the coming-week class ----
-- starts_on far out so nothing auto-materialises; one room per series, times
-- staggered so the GiST exclusion constraints never fire.
do $$
declare
  ga  uuid := '91060000-0000-0000-0000-0000000000a1';
  loc uuid := '91060000-0000-0000-0000-00000000a0cc';
  ct  uuid := '91060000-0000-0000-0000-00000000c7a1';
  nextmon date := g106_week();
  pool uuid[] := array[
    '91060000-0000-0000-0000-0000000d0001','91060000-0000-0000-0000-0000000d0002',
    '91060000-0000-0000-0000-0000000d0003','91060000-0000-0000-0000-0000000d0004',
    '91060000-0000-0000-0000-0000000d0005','91060000-0000-0000-0000-0000000d0006',
    '91060000-0000-0000-0000-0000000d0007','91060000-0000-0000-0000-0000000d0008',
    '91060000-0000-0000-0000-0000000d0009','91060000-0000-0000-0000-0000000d0010',
    '91060000-0000-0000-0000-0000000d0011','91060000-0000-0000-0000-0000000d0012']::uuid[];
  rec record; rm uuid; occ uuid; k int; j int; st timestamptz; cstart timestamptz; sidx int := 0;
begin
  for rec in select * from (values
    -- sid, instr, cur_tier, day_off, ctime(min), counts (newest-first)
    ('91060000-0000-0000-0000-00000000a001'::uuid,'91060000-0000-0000-0000-0000000001a1'::uuid,'flex',0,420, array[5,5,5,5,5,5,5,5]),
    ('91060000-0000-0000-0000-00000000a002'::uuid,'91060000-0000-0000-0000-0000000001a1'::uuid,'core',0,480, array[4,4,4,4,4,4,4,4]),
    ('91060000-0000-0000-0000-00000000a003'::uuid,'91060000-0000-0000-0000-0000000001a1'::uuid,'core',1,420, array[1,1,1,1,1,1,1,1]),
    ('91060000-0000-0000-0000-00000000a004'::uuid,'91060000-0000-0000-0000-0000000001a1'::uuid,'flex',1,480, array[6,6]),
    ('91060000-0000-0000-0000-00000000a005'::uuid,'91060000-0000-0000-0000-0000000001a1'::uuid,'flex',2,420, array[2,2,2,0,2,2,2,2]),
    ('91060000-0000-0000-0000-00000000a006'::uuid,'91060000-0000-0000-0000-0000000001a1'::uuid,'core',2,480, array[2,2,0,0,2,2,2,2]),
    ('91060000-0000-0000-0000-00000000a007'::uuid,'91060000-0000-0000-0000-0000000002a1'::uuid,'flex',0,420, array[10,5,5,5,5,5,5,5]),
    ('91060000-0000-0000-0000-00000000a008'::uuid,'91060000-0000-0000-0000-0000000002a1'::uuid,'core',0,480, array[1,1,1,1]),
    ('91060000-0000-0000-0000-00000000a009'::uuid,'91060000-0000-0000-0000-0000000002a1'::uuid,'flex',1,420, array[10,10,10,10]),
    ('91060000-0000-0000-0000-00000000a010'::uuid,'91060000-0000-0000-0000-0000000002a1'::uuid,'flex',1,480, array[8,8,8,8])
  ) as t(sid, instr, cur, doff, ctime, counts)
  loop
    sidx := sidx + 1;
    insert into rooms (id, studio_id, location_id, name, capacity)
      values (gen_random_uuid(), ga, loc, 'R'||sidx, 8) returning id into rm;
    insert into class_series (id, studio_id, location_id, class_type_id, room_id, name, capacity,
      duration_minutes, rrule, starts_on, time_of_day, status, instructor_id, guarantee_tier, flex)
    values (rec.sid, ga, loc, ct, rm, 'Slot '||sidx, 8, 50, 'FREQ=WEEKLY;BYDAY=MO',
            current_date + 400, time '07:00', 'active', rec.instr,
            (case when rec.cur='flex' then 'flex' else 'core' end)::guarantee_tier, (rec.cur='flex'));
    for k in 1 .. coalesce(array_length(rec.counts,1),0) loop
      st := now() - (k * interval '7 days') + (sidx * interval '90 minutes');
      insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
        capacity, booked_count, starts_at, ends_at, status, series_id, instructor_id)
      values (gen_random_uuid(), ga, loc, ct, rm, 'Slot '||sidx, 8, greatest(rec.counts[k],0),
              st, st + interval '50 min', 'scheduled', rec.sid, rec.instr) returning id into occ;
      for j in 1 .. rec.counts[k] loop
        insert into bookings (studio_id, occurrence_id, member_id, status, payment_source, booked_at)
        values (ga, occ, pool[j], 'attended', 'membership', st);
      end loop;
    end loop;
    -- the coming-week occurrence (future), the one the proposals act on
    cstart := ((rec.doff + nextmon) + (rec.ctime * interval '1 minute')) at time zone 'Asia/Manila';
    insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
      capacity, booked_count, starts_at, ends_at, status, series_id, instructor_id)
    values (gen_random_uuid(), ga, loc, ct, rm, 'Slot '||sidx, 8, 0,
            cstart, cstart + interval '50 min', 'scheduled', rec.sid, rec.instr);
  end loop;

  -- A history-only slot for the nudge list: Nadia attended 4 classes, all more
  -- than 21 days ago (no coming occurrence, so it is never proposed).
  insert into rooms (id, studio_id, location_id, name, capacity)
    values (gen_random_uuid(), ga, loc, 'Rn', 8) returning id into rm;
  insert into class_series (id, studio_id, location_id, class_type_id, room_id, name, capacity,
    duration_minutes, rrule, starts_on, time_of_day, status, instructor_id, guarantee_tier, flex)
  values ('91060000-0000-0000-0000-00000000a011', ga, loc, ct, rm, 'Nudge', 8, 50,
          'FREQ=WEEKLY;BYDAY=MO', current_date + 400, time '07:00', 'active',
          '91060000-0000-0000-0000-0000000001a1', 'core', false);
  for k in 4 .. 7 loop
    st := now() - (k * interval '7 days') + (interval '20 hours');
    insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
      capacity, booked_count, starts_at, ends_at, status, series_id, instructor_id)
    values (gen_random_uuid(), ga, loc, ct, rm, 'Nudge', 8, 1,
            st, st + interval '50 min', 'scheduled', '91060000-0000-0000-0000-00000000a011',
            '91060000-0000-0000-0000-0000000001a1') returning id into occ;
    insert into bookings (studio_id, occurrence_id, member_id, status, payment_source, booked_at)
    values (ga, occ, '91060000-0000-0000-0000-0000000d0099', 'attended', 'membership', st);
  end loop;
end $$;

-- The budgets: Ann 1 (ranking / raise / actions), Ben 2 (unfilled).
update instructors set core_classes_per_week = 1 where id = '91060000-0000-0000-0000-0000000001a1';
update instructors set core_classes_per_week = 2 where id = '91060000-0000-0000-0000-0000000002a1';

-- --- GB: the seed test. Cara teaches 2 core + 1 flex per day (mode 2); Dan all
--     flex (mode 0 -> floors to 1); Eve teaches nothing in the window (stays null).
do $$
declare
  gb  uuid := '91060000-0000-0000-0000-0000000000b1';
  loc uuid := '91060000-0000-0000-0000-00000000b0cc';
  ct  uuid := '91060000-0000-0000-0000-00000000c7b1';
  cara uuid := '91060000-0000-0000-0000-0000000003b1';
  dan  uuid := '91060000-0000-0000-0000-0000000004b1';
  r1 uuid; r2 uuid; r3 uuid; st timestamptz; k int;
begin
  insert into rooms (id, studio_id, location_id, name, capacity) values
    (gen_random_uuid(), gb, loc, 'B1', 8) returning id into r1;
  insert into rooms (id, studio_id, location_id, name, capacity) values
    (gen_random_uuid(), gb, loc, 'B2', 8) returning id into r2;
  insert into rooms (id, studio_id, location_id, name, capacity) values
    (gen_random_uuid(), gb, loc, 'B3', 8) returning id into r3;
  for k in 2 .. 5 loop
    -- Anchored to studio-local midnight so +7h..+12h stay on one Manila day
    -- whatever the wall clock (now()+k*7d crossed midnight at some hours).
    st := (date_trunc('day', now() at time zone 'Asia/Manila') + k * interval '7 days') at time zone 'Asia/Manila';
    -- Cara: 2 core (default tier) + 1 flex, so the day's core count is 2.
    insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
      capacity, starts_at, ends_at, status, instructor_id) values
      (gen_random_uuid(), gb, loc, ct, r1, 'Core A', 8, st + interval '7 h',  st + interval '7 h'  + interval '50 min', 'scheduled', cara),
      (gen_random_uuid(), gb, loc, ct, r2, 'Core B', 8, st + interval '8 h',  st + interval '8 h'  + interval '50 min', 'scheduled', cara),
      (gen_random_uuid(), gb, loc, ct, r3, 'Flex C', 8, st + interval '9 h',  st + interval '9 h'  + interval '50 min', 'scheduled', cara);
    update class_occurrences set flex = true, minimum_bookings = 2
     where instructor_id = cara and name = 'Flex C' and starts_at = st + interval '9 h';
    -- Dan: one flex each day, so the day's core count is 0.
    insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
      capacity, starts_at, ends_at, status, instructor_id, flex, minimum_bookings) values
      (gen_random_uuid(), gb, loc, ct, r1, 'Dan Flex', 8, st + interval '12 h', st + interval '12 h' + interval '50 min', 'scheduled', dan, true, 2);
  end loop;
end $$;

-- =============================================================================
-- SECTION 1 — the seed (service context).
-- =============================================================================
select seed_instructor_core_budgets('91060000-0000-0000-0000-0000000000b1');
select expect_num('seed: Cara (2 core + 1 flex a week) -> mode 2',
  (select core_classes_per_week from instructors where id='91060000-0000-0000-0000-0000000003b1'), 2);
select expect_num('seed: Dan (all flex, mode 0) -> floors to 1',
  (select core_classes_per_week from instructors where id='91060000-0000-0000-0000-0000000004b1'), 1);
select expect_num('seed: Eve (no classes in window) stays null',
  (select core_classes_per_week from instructors where id='91060000-0000-0000-0000-0000000005b1'), null);
-- idempotent + does not overwrite a manager's number
update instructors set core_classes_per_week = 3 where id='91060000-0000-0000-0000-0000000003b1';
select seed_instructor_core_budgets('91060000-0000-0000-0000-0000000000b1');
select expect_num('seed: a re-run does not overwrite an existing budget',
  (select core_classes_per_week from instructors where id='91060000-0000-0000-0000-0000000003b1'), 3);

-- =============================================================================
-- SECTION 2 — growth_insights: ranking, qualifying, collecting, proposals.
-- =============================================================================
do $g2$
declare gi jsonb; sa jsonb; sb jsonb; sc jsonb; sd jsonb; se jsonb; sf jsonb; sg jsonb; sh jsonb;
begin
  gi := g106('91060000-0000-0000-0000-0000000000a1');
  sa := g106_slot(gi,'91060000-0000-0000-0000-00000000a001');
  sb := g106_slot(gi,'91060000-0000-0000-0000-00000000a002');
  sc := g106_slot(gi,'91060000-0000-0000-0000-00000000a003');
  sd := g106_slot(gi,'91060000-0000-0000-0000-00000000a004');
  se := g106_slot(gi,'91060000-0000-0000-0000-00000000a005');
  sf := g106_slot(gi,'91060000-0000-0000-0000-00000000a006');
  sg := g106_slot(gi,'91060000-0000-0000-0000-00000000a007');
  sh := g106_slot(gi,'91060000-0000-0000-0000-00000000a008');

  -- ranking: fuller slot scores higher
  perform expect_true('ranking: Slot A (5 booked) outscores Slot B (4 booked)',
    (sa->>'score')::numeric > (sb->>'score')::numeric);

  -- Decision 106(a): the weekly budget informs, it does not block. Ann's budget
  -- is 1 and she already holds 3 core classes this week (B, C, F), so Slot A
  -- (qualifying) is still proposed core and flagged over budget with the count
  -- it would reach (4).
  perform expect_text('Slot A proposed core', sa->>'proposed_tier', 'core');
  perform expect_text('Slot A action make_core (it is flex today)', sa->>'action', 'make_core');
  perform expect_true('Slot A over budget', (sa->>'over_budget')::boolean);
  perform expect_num('Slot A would hold 4 core classes', (sa->>'would_hold')::int, 4);
  perform expect_text('Slot B stays core (it qualifies; never dropped for budget)', sb->>'proposed_tier', 'core');
  perform expect_true('Slot B has no action (already core)', (sb->'action') is null or jsonb_typeof(sb->'action')='null');

  -- a slot that never met the minimum: not core
  perform expect_false('Slot C does not qualify (1 booked < flex min 2)', (sc->>'qualifies')::boolean);
  perform expect_text('Slot C proposed flex', sc->>'proposed_tier', 'flex');

  -- collecting data: fewer than 4 weeks -> no proposal
  perform expect_num('Slot D has 2 weeks of history', (sd->>'weeks')::int, 2);
  perform expect_true('Slot D is collecting', (sd->>'collecting')::boolean);
  perform expect_text('Slot D collecting label', sd->>'collecting_label', 'Collecting data, 2 of 4 weeks');
  perform expect_true('Slot D has no proposed tier', (sd->'proposed_tier') is null or jsonb_typeof(sd->'proposed_tier')='null');
  perform expect_true('Slot D has no action', (sd->'action') is null or jsonb_typeof(sd->'action')='null');

  -- 3 of the last 4 weeks -> qualifies; 2 of 4 -> does not
  perform expect_true('Slot E qualifies (met in 3 of last 4)', (se->>'qualifies')::boolean);
  perform expect_text('Slot E proposed core', se->>'proposed_tier', 'core');
  perform expect_false('Slot F does not qualify (met in 2 of last 4)', (sf->>'qualifies')::boolean);
  perform expect_text('Slot F proposed flex', sf->>'proposed_tier', 'flex');

  -- Ben's budget is 2 and only Slot G qualifies; the weak Slot H is not
  -- promoted to fill a place.
  perform expect_text('Slot G proposed core', sg->>'proposed_tier', 'core');
  perform expect_text('Slot H stays flex, not filled into the empty place', sh->>'proposed_tier', 'flex');

  -- raise signal: with A then E made core Ann would hold 5 against a budget of 1
  perform expect_num('Ann raise_to is the most she would hold',
    (g106_coach(gi,'91060000-0000-0000-0000-0000000001a1')->>'raise_to')::int, 5);
  -- Ben holds 1 core (H) and three qualifying flex slots (G and the two clamp
  -- slots) all proposed core: counted per week he would hold 4 against 2.
  perform expect_num('Ben raise_to counts the whole week (4 against a budget of 2)',
    (g106_coach(gi,'91060000-0000-0000-0000-0000000002a1')->>'raise_to')::int, 4);

  -- clamp: over-capacity booked does not inflate the score beyond a full room
  perform expect_text('clamp: 10/8 scores the same as 8/8',
    g106_slot(gi,'91060000-0000-0000-0000-00000000a009')->>'score',
    g106_slot(gi,'91060000-0000-0000-0000-00000000a010')->>'score');

  -- wanted: Slot G ran full -> "Add a class here"
  perform expect_true('Slot G is in the wanted list',
    exists (select 1 from jsonb_array_elements(gi->'wanted') w
            where (w->>'series_id')::uuid = '91060000-0000-0000-0000-00000000a007'));

  -- nudge: Nadia booked often but not lately
  perform expect_true('Nadia is in the nudge list',
    exists (select 1 from jsonb_array_elements(gi->'nudge') n
            where (n->>'member_id')::uuid = '91060000-0000-0000-0000-0000000d0099'));
  raise notice 'PASS  section 2 (growth_insights) complete';
end $g2$;

-- a member cannot ask for the insights (service only: the grant is the boundary)
reset role; set role authenticated; select set_config('request.jwt.claim.sub','91060000-0000-0000-0000-00000000a0a1',false);
select expect_raise('growth_insights refuses a user (service only)', '42501',
  $$select growth_insights('91060000-0000-0000-0000-0000000000a1', g106_week())$$);
reset role;

-- =============================================================================
-- SECTION 3 — the summary gate (ai_drafts off / key absent -> skipped).
-- =============================================================================
reset role;
-- make sure no leftover key, and AI drafts off for GA
select set_config('app.anthropic_api_key', '', false);
update studio_settings set ai_drafts_enabled = false where studio_id = '91060000-0000-0000-0000-0000000000a1';
select expect_true('sweep (ai drafts off): the numbers are written, the summary is skipped',
  ((sweep_growth_insights('91060000-0000-0000-0000-0000000000a1', g106_week())) ->> 'summary_queued')::boolean = false);
select expect_true('sweep writes the ai_insights growth row',
  exists (select 1 from ai_insights where studio_id='91060000-0000-0000-0000-0000000000a1'
          and type='growth' and subject_id is null and for_date=g106_week()));
select expect_false('no growth narrative queued when AI drafts are off',
  exists (select 1 from dashboard_narratives where studio_id='91060000-0000-0000-0000-0000000000a1'
          and kind='growth' and for_date=g106_week()));

-- AI drafts ON but the platform key is absent -> still skipped (Decision 106)
update studio_settings set ai_drafts_enabled = true where studio_id = '91060000-0000-0000-0000-0000000000a1';
select set_config('app.anthropic_api_key', '', false);
select expect_true('sweep (ai drafts on, no key): the summary is skipped without a key',
  ((sweep_growth_insights('91060000-0000-0000-0000-0000000000a1', g106_week())) ->> 'summary_queued')::boolean = false);
select expect_false('still no growth narrative queued without a key',
  exists (select 1 from dashboard_narratives where studio_id='91060000-0000-0000-0000-0000000000a1'
          and kind='growth' and for_date=g106_week()));
update studio_settings set ai_drafts_enabled = false where studio_id = '91060000-0000-0000-0000-0000000000a1';

-- the growth arm of dashboard_facts reads the stored numbers back
select expect_true('dashboard_facts(growth) publishes the figures',
  (dashboard_facts('91060000-0000-0000-0000-0000000000a1','growth',g106_week(),null) -> 'figures' -> 'proposed_core' ->> 'n') is not null);

-- =============================================================================
-- SECTION 4 — apply (manager), audit, and the front-desk / range guards.
-- =============================================================================
-- as owner: make Slot B flex for the coming week (set_occurrence_day_tier)
reset role; set role authenticated; select set_config('request.jwt.claim.sub','91060000-0000-0000-0000-00000000a0a1',false);
do $g4$
declare occb uuid; occa uuid;
begin
  select id into occb from class_occurrences
   where series_id='91060000-0000-0000-0000-00000000a002' and starts_at > now() limit 1;
  perform growth_apply(occb, 'flex', 'week');
  if not exists (select 1 from class_occurrences where id=occb and flex = true) then
    raise exception 'FAIL  growth_apply week: the occurrence was not set to flex';
  end if;
  raise notice 'PASS  growth_apply week sets the coming occurrence to flex';

  -- as owner: make Slot A core for every week (set_series_guarantee)
  select id into occa from class_occurrences
   where series_id='91060000-0000-0000-0000-00000000a001' and starts_at > now() limit 1;
  perform growth_apply(occa, 'core', 'series');
  if not exists (select 1 from class_series where id='91060000-0000-0000-0000-00000000a001' and guarantee_tier='core') then
    raise exception 'FAIL  growth_apply series: the series tier was not set to core';
  end if;
  raise notice 'PASS  growth_apply series sets the series to core';
end $g4$;
select expect_num('growth.applied audit rows written (week + series)',
  (select count(*) from audit_logs where action='growth.applied'
   and studio_id='91060000-0000-0000-0000-0000000000a1'), 2);

-- the budget setter (owner)
select expect_num('set_instructor_core_budget sets the number',
  ((set_instructor_core_budget('91060000-0000-0000-0000-0000000001a1', 3)) ->> 'core_classes_per_week')::int, 3);
select expect_raise('set_instructor_core_budget rejects out of range (1..21)', 'PT422',
  $$select set_instructor_core_budget('91060000-0000-0000-0000-0000000001a1', 22)$$);

-- front desk is refused both the apply and the budget
reset role; set role authenticated; select set_config('request.jwt.claim.sub','91060000-0000-0000-0000-00000000a0f1',false);
select expect_raise('front desk cannot set a budget', 'PT403',
  $$select set_instructor_core_budget('91060000-0000-0000-0000-0000000001a1', 2)$$);
select expect_raise('front desk cannot apply a growth proposal', 'PT403',
  $$select growth_apply((select id from class_occurrences where series_id='91060000-0000-0000-0000-00000000a003' and starts_at > now() limit 1), 'flex', 'week')$$);
reset role;

-- =============================================================================
-- SECTION 5 — the anon surface stays EXACTLY FIFTEEN, plus the inbox table.
-- =============================================================================
do $anon$ declare n int; begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.prokind = 'f'
     and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not in ('expect_num','expect_text','expect_true','expect_false','expect_raise',
                           'g106_week','g106','g106_slot','g106_coach','g106_day');
  perform expect_num('anon function surface is FIFTEEN', n, 15);
  perform expect_true('resend_webhook_inbox keeps anon INSERT',
    has_table_privilege('anon','public.resend_webhook_inbox','insert'));
  perform expect_false('resend_webhook_inbox is not anon-readable',
    has_table_privilege('anon','public.resend_webhook_inbox','select'));
end $anon$;

select 'growth_insights_test PASS' as result;
