-- =============================================================================
-- Step 12b (migration 368): Decision 22(f) members see a flex class's state.
-- member_flex_states, public_schedule, free_first_class_list and the schedule
-- post data carry the count the running latch uses (paid seats), the minimum
-- and the latch; schedule_range already carries them (22 e).
-- UUID space 22f0, checked free. Run after `supabase db reset`.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_eq(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual,'null'); end if;
end $$;
create or replace function expect_err(label text, sql text, code text)
returns void language plpgsql as $$
begin
  execute sql;
  raise exception 'FAIL  %  expected error %, got none', label, code;
exception when others then
  if sqlstate = code then raise notice 'PASS  %  (raised %)', label, code;
  else raise exception 'FAIL  %  expected %, got % %', label, code, sqlstate, sqlerrm; end if;
end $$;

insert into auth.users (id) values
  ('22f00000-0000-0000-0000-0000000000a1'),   -- owner
  ('22f00000-0000-0000-0000-0000000000c1'),   -- member (a lead, free first eligible)
  ('22f00000-0000-0000-0000-0000000000c9');   -- a member of another studio
insert into profiles (id, email, full_name) values
  ('22f00000-0000-0000-0000-0000000000a1','22f0-owner@example.com','Olive Owner'),
  ('22f00000-0000-0000-0000-0000000000c1','22f0-m1@example.com','Lea Lead'),
  ('22f00000-0000-0000-0000-0000000000c9','22f0-x@example.com','Xan Elsewhere');
insert into studios (id, name, slug, timezone, currency, status) values
  ('22f00000-0000-0000-0000-0000000000a0','Flex State Studio','22f0-s','Asia/Manila','PHP','active'),
  ('22f00000-0000-0000-0000-0000000000b0','Other Studio','22f0-o','Asia/Manila','PHP','active');
insert into studio_settings (studio_id, require_waiver, flex_enabled, flex_min_bookings, guarantees_enabled,
                             free_first_class_enabled, booking_cutoff_minutes) values
  ('22f00000-0000-0000-0000-0000000000a0', false, true, 2, true, true, 0),
  ('22f00000-0000-0000-0000-0000000000b0', false, false, 1, false, false, 0);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('22f00000-0000-0000-0000-0000000005a1','22f00000-0000-0000-0000-0000000000a0','22f00000-0000-0000-0000-0000000000a1','22f0-owner@example.com','owner');
insert into locations (id, studio_id, name, is_primary) values
  ('22f00000-0000-0000-0000-00000000010c','22f00000-0000-0000-0000-0000000000a0','Main', true);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity, status) values
  ('22f00000-0000-0000-0000-0000000000e1','22f00000-0000-0000-0000-0000000000a0','Reformer',50,8,'active');
insert into members (id, studio_id, user_id, first_name, last_name, email, status) values
  ('22f00000-0000-0000-0000-0000000d0001','22f00000-0000-0000-0000-0000000000a0','22f00000-0000-0000-0000-0000000000c1','Lea','Lead','22f0-m1@example.com','lead'),
  ('22f00000-0000-0000-0000-0000000d0009','22f00000-0000-0000-0000-0000000000b0','22f00000-0000-0000-0000-0000000000c9','Xan','Elsewhere','22f0-x@example.com','active');
insert into members (id, studio_id, first_name, last_name, email, status)
select ('22f00000-0000-0000-0000-0000000f00' || lpad(g::text, 2, '0'))::uuid,
       '22f00000-0000-0000-0000-0000000000a0', 'F' || g, 'Filler', '22f0-f' || g || '@example.com', 'active'
  from generate_series(1, 6) g;

-- A flex 0 of 2, B flex 1 of 2, C flex 2 of 2, H hidden flex, K core.
insert into class_occurrences (id, studio_id, location_id, class_type_id, name, capacity, minimum_bookings, flex,
                               starts_at, ends_at, status, hidden_from_members) values
  ('22f00000-0000-0000-0000-00000000a0a1','22f00000-0000-0000-0000-0000000000a0','22f00000-0000-0000-0000-00000000010c','22f00000-0000-0000-0000-0000000000e1','Flex Empty',8,2,true,
   date_trunc('day', now()) + interval '2 days 1 hour', date_trunc('day', now()) + interval '2 days 2 hours','scheduled',false),
  ('22f00000-0000-0000-0000-00000000a0a2','22f00000-0000-0000-0000-0000000000a0','22f00000-0000-0000-0000-00000000010c','22f00000-0000-0000-0000-0000000000e1','Flex One Short',8,2,true,
   date_trunc('day', now()) + interval '2 days 3 hours', date_trunc('day', now()) + interval '2 days 4 hours','scheduled',false),
  ('22f00000-0000-0000-0000-00000000a0a3','22f00000-0000-0000-0000-0000000000a0','22f00000-0000-0000-0000-00000000010c','22f00000-0000-0000-0000-0000000000e1','Flex Running',8,2,true,
   date_trunc('day', now()) + interval '2 days 5 hours', date_trunc('day', now()) + interval '2 days 6 hours','scheduled',false),
  ('22f00000-0000-0000-0000-00000000a0a4','22f00000-0000-0000-0000-0000000000a0','22f00000-0000-0000-0000-00000000010c','22f00000-0000-0000-0000-0000000000e1','Flex Hidden',8,2,true,
   date_trunc('day', now()) + interval '2 days 7 hours', date_trunc('day', now()) + interval '2 days 8 hours','scheduled',true),
  ('22f00000-0000-0000-0000-00000000a0a5','22f00000-0000-0000-0000-0000000000a0','22f00000-0000-0000-0000-00000000010c','22f00000-0000-0000-0000-0000000000e1','Core Class',8,null,false,
   date_trunc('day', now()) + interval '2 days 9 hours', date_trunc('day', now()) + interval '2 days 10 hours','scheduled',false);
insert into bookings (studio_id, occurrence_id, member_id, status, payment_source)
select '22f00000-0000-0000-0000-0000000000a0', o::uuid, ('22f00000-0000-0000-0000-0000000f00' || m)::uuid, 'booked', s::payment_source
  from (values ('22f00000-0000-0000-0000-00000000a0a2','01','comp'),
               ('22f00000-0000-0000-0000-00000000a0a3','02','comp'), ('22f00000-0000-0000-0000-00000000a0a3','03','class_pack'),
               -- an unpaid drop-in does not count (Decision 81b)
               ('22f00000-0000-0000-0000-00000000a0a1','04','drop_in')) v(o, m, s);

-- =============================================================================
-- 1. member_flex_states: only the flex classes the member can see.
-- =============================================================================
reset role; set role authenticated; select set_config('request.jwt.claim.sub','22f00000-0000-0000-0000-0000000000c1',false);
select expect_eq('1.1 three flex classes come back (not the hidden one, not core)',
  (select string_agg(o.name || ':' || f.paid_count || '/' || f.min_bookings || '/' || f.reached_minimum, ', ' order by o.starts_at)
     from member_flex_states('22f00000-0000-0000-0000-0000000000a0', now(), now() + interval '7 days') f
     join class_occurrences o on o.id = f.occurrence_id),
  'Flex Empty:0/2/false, Flex One Short:1/2/false, Flex Running:2/2/false');
select expect_eq('1.2 one occurrence when asked for one',
  (select count(*)::text from member_flex_states('22f00000-0000-0000-0000-0000000000a0', '-infinity', 'infinity',
                                                 '22f00000-0000-0000-0000-00000000a0a2')), '1');
select expect_eq('1.3 an unpaid drop-in does not count toward the minimum',
  (select paid_count::text from member_flex_states('22f00000-0000-0000-0000-0000000000a0', '-infinity', 'infinity',
                                                   '22f00000-0000-0000-0000-00000000a0a1')), '0');

-- =============================================================================
-- 2. free_first_class_list carries the state.
-- =============================================================================
select expect_eq('2.1 the free picker row for the one-short class',
  (select occ_flex || '/' || occ_paid_count || '/' || occ_min || '/' || occ_reached_minimum || '/' || occ_committed
     from free_first_class_list('22f00000-0000-0000-0000-0000000000a0')
    where occurrence_id = '22f00000-0000-0000-0000-00000000a0a2'), 'true/1/2/false/false');
select expect_eq('2.2 the core class is not flex in the picker',
  (select occ_flex::text from free_first_class_list('22f00000-0000-0000-0000-0000000000a0')
    where occurrence_id = '22f00000-0000-0000-0000-00000000a0a5'), 'false');

-- Another studio's member is refused.
reset role; set role authenticated; select set_config('request.jwt.claim.sub','22f00000-0000-0000-0000-0000000000c9',false);
select expect_err('2.3 another studio''s member cannot read the flex states',
  $$select * from member_flex_states('22f00000-0000-0000-0000-0000000000a0', now(), now() + interval '7 days')$$, 'PT403');

-- =============================================================================
-- 3. public_schedule (anon) carries the count and the minimum.
-- =============================================================================
reset role; set role anon;
select expect_eq('3.1 the embed row for the one-short class',
  (select c ->> 'flex' || '/' || (c ->> 'paid_count') || '/' || (c ->> 'min_bookings') || '/' || (c ->> 'reached_minimum')
     from jsonb_array_elements(public_schedule('22f0-s') -> 'classes') c where c ->> 'class_name' = 'Reformer'
      and c ->> 'id' = '22f00000-0000-0000-0000-00000000a0a2'), 'true/1/2/false');
select expect_eq('3.2 a core class carries no count',
  (select (c ->> 'flex') || '/' || coalesce(c ->> 'paid_count', 'null')
     from jsonb_array_elements(public_schedule('22f0-s') -> 'classes') c
    where c ->> 'id' = '22f00000-0000-0000-0000-00000000a0a5'), 'false/null');
select expect_eq('3.3 the hidden class is not in the embed',
  (select count(*)::text from jsonb_array_elements(public_schedule('22f0-s') -> 'classes') c
    where c ->> 'id' = '22f00000-0000-0000-0000-00000000a0a4'), '0');

-- =============================================================================
-- 4. Staff: schedule_range carries the same three (22 e), the post data the need.
-- =============================================================================
reset role; set role authenticated; select set_config('request.jwt.claim.sub','22f00000-0000-0000-0000-0000000000a1',false);
select expect_eq('4.1 schedule_range: paid, minimum, latch for the one-short class',
  (select occ_paid_count || '/' || occ_minimum || '/' || occ_reached_minimum
     from schedule_range('22f00000-0000-0000-0000-0000000000a0', current_date, current_date + 5)
    where occ_id = '22f00000-0000-0000-0000-00000000a0a2'), '1/2/false');
select expect_eq('4.2 the post rows: needs 2, needs 1, running (null), core (null)',
  (select string_agg((c ->> 'name') || ':' || coalesce(c ->> 'needs', '-'), ', ' order by c ->> 'time')
     from jsonb_array_elements(schedule_post_data('22f00000-0000-0000-0000-0000000000a0', current_date, current_date + 5, false) -> 'days') d,
          jsonb_array_elements(d -> 'classes') c),
  'Flex Empty:2, Flex One Short:1, Flex Running:-, Core Class:-');

-- =============================================================================
-- 5. The surface.
-- =============================================================================
reset role;
select expect_eq('5.1 member_flex_states is not anon',
  has_function_privilege('anon', 'member_flex_states(uuid, timestamptz, timestamptz, uuid)', 'execute')::text, 'false');
select expect_eq('5.2 occurrence_flex_state_run is service-only',
  (has_function_privilege('authenticated', 'occurrence_flex_state_run(uuid)', 'execute')
   or has_function_privilege('anon', 'occurrence_flex_state_run(uuid)', 'execute'))::text, 'false');
select expect_eq('5.3 public_schedule is still anon', has_function_privilege('anon', 'public_schedule(text, integer)', 'execute')::text, 'true');
select expect_eq('5.4 anon surface EXACTLY FIFTEEN', (select count(*)::text from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.proname not like 'expect\_%' and p.proname not in ('call_jsonb')
     and has_function_privilege('anon', p.oid, 'execute')), '15');

do $$ begin raise notice 'flex_state_test: all assertions passed'; end $$;
