-- =============================================================================
-- Decision 95 — flex rescue. Migration 20260833330000.
-- =============================================================================
-- UUID space 95f1 (hex), checked free. Run after `supabase db reset`.
--
-- The 2-day queue fires once and not for a latched class; the final queue fires
-- from the deadline; move_booking moves in place (seat type + free first class
-- travel); each refusal; no duplicate sends; the card order; the Journey arm.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to warning;

create or replace function login(uid text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', uid, true); set local role authenticated; end $$;
create or replace function expect_text(label text, actual text, want text) returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS %', label;
  else raise exception 'BAD % expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if; end $$;
create or replace function expect_true(label text, actual boolean) returns void language plpgsql as $$
begin if actual then raise notice 'PASS %', label; else raise exception 'BAD % expected true', label; end if; end $$;
create or replace function expect_num(label text, actual bigint, want bigint) returns void language plpgsql as $$
begin if actual = want then raise notice 'PASS %', label; else raise exception 'BAD % expected %, got %', label, want, actual; end if; end $$;
-- run move_booking and return the reason or sqlstate (service context passes the member guard)
create or replace function move_reason(booking text, target text) returns text language plpgsql as $$
declare r jsonb; begin
  begin select move_booking(booking::uuid, target::uuid) into r;
    return coalesce(r->>'reason', case when (r->>'ok')::boolean then 'ok' else 'noreason' end);
  exception when others then return sqlstate; end; end $$;

reset role;

-- ---- fixtures --------------------------------------------------------------
insert into auth.users (id) values
  ('95f10000-0000-0000-0000-0000000000f1'),   -- M1 login
  ('95f10000-0000-0000-0000-0000000000f2');   -- M2 login
insert into profiles (id, email, full_name) values
  ('95f10000-0000-0000-0000-0000000000f1','m1@e.com','Mia One'),
  ('95f10000-0000-0000-0000-0000000000f2','m2@e.com','Mo Two');

insert into studios (id, name, slug, timezone, currency, status) values
  ('95f10000-0000-0000-0000-0000000000a0','Flex Rescue Studio','95f1-sa','UTC','PHP','active');
insert into studio_settings (studio_id, require_waiver, flex_enabled, flex_min_bookings,
       flex_deadline_mode, flex_deadline_hours, flex_rescue_hours_before, free_first_class_enabled) values
  ('95f10000-0000-0000-0000-0000000000a0', false, true, 3, 'hours_before', 4, 3, true);
insert into locations (id, studio_id, name, is_primary) values
  ('95f10000-0000-0000-0000-00000000010c','95f10000-0000-0000-0000-0000000000a0','Main', true);

insert into class_types (id, studio_id, name, duration_minutes, default_capacity, status) values
  ('95f10000-0000-0000-0000-0000000000c1','95f10000-0000-0000-0000-0000000000a0','Reformer',60,10,'active'),
  ('95f10000-0000-0000-0000-0000000000c2','95f10000-0000-0000-0000-0000000000a0','Barre',60,10,'active');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('95f10000-0000-0000-0000-0000000000d1','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-00000000010c','Studio A', 10),
  ('95f10000-0000-0000-0000-0000000000d2','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-00000000010c','Studio B', 10);
insert into instructors (id, studio_id, display_name, status) values
  ('95f10000-0000-0000-0000-0000000000e1','95f10000-0000-0000-0000-0000000000a0','Ada Coach','active'),
  ('95f10000-0000-0000-0000-0000000000e2','95f10000-0000-0000-0000-0000000000a0','Bo Coach','active');

-- a CT1-only plan (for plan_not_covering)
insert into membership_plans (id, studio_id, name, type, price_cents, currency, status, visibility, credits, restrictions) values
  ('95f10000-0000-0000-0000-00000000a101','95f10000-0000-0000-0000-0000000000a0','Reformer Pack','class_pack',500000,'PHP','active','public',10,
   jsonb_build_object('class_type_ids', jsonb_build_array('95f10000-0000-0000-0000-0000000000c1')));

insert into members (id, studio_id, user_id, first_name, last_name, email, status) values
  ('95f10000-0000-0000-0000-0000000000b1','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-0000000000f1','Mia','One','m1@e.com','lead'),
  ('95f10000-0000-0000-0000-0000000000b2','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-0000000000f2','Mo','Two','m2@e.com','active'),
  ('95f10000-0000-0000-0000-0000000000b3','95f10000-0000-0000-0000-0000000000a0',null,'Len','Latch','ml@e.com','active'),
  ('95f10000-0000-0000-0000-0000000000b4','95f10000-0000-0000-0000-0000000000a0',null,'Pat','Plan','m3@e.com','active');

insert into memberships (id, studio_id, member_id, plan_id, status, credits_remaining, price_cents, currency, starts_on) values
  ('95f10000-0000-0000-0000-000000005004','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-0000000000b4','95f10000-0000-0000-0000-00000000a101','active',9,500000,'PHP', current_date);

-- flex source classes (room d1) + core targets (room d2 so no overlap)
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, minimum_bookings, flex, flex_reached_minimum_at, starts_at, ends_at, status, booked_count) values
  ('95f10000-0000-0000-0000-0000000f0001','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-00000000010c','95f10000-0000-0000-0000-0000000000c1','95f10000-0000-0000-0000-0000000000d1','95f10000-0000-0000-0000-0000000000e1','Flex Two Day',10,3,true,null, now()+interval '2 days', now()+interval '2 days 1 hour','scheduled',1),            -- FX
  ('95f10000-0000-0000-0000-0000000f0002','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-00000000010c','95f10000-0000-0000-0000-0000000000c1','95f10000-0000-0000-0000-0000000000d1','95f10000-0000-0000-0000-0000000000e1','Flex Final',10,3,true,null, now()+interval '5 hours', now()+interval '6 hours','scheduled',1),                        -- FX2
  ('95f10000-0000-0000-0000-0000000f0003','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-00000000010c','95f10000-0000-0000-0000-0000000000c1','95f10000-0000-0000-0000-0000000000d1','95f10000-0000-0000-0000-0000000000e1','Flex Latched',10,3,true,now(), now()+interval '2 days 6 hours', now()+interval '2 days 7 hours','scheduled',3),  -- FXLATCH
  ('95f10000-0000-0000-0000-0000000f0004','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-00000000010c','95f10000-0000-0000-0000-0000000000c1','95f10000-0000-0000-0000-0000000000d1','95f10000-0000-0000-0000-0000000000e1','Flex Plan',10,3,true,null, now()+interval '2 days 2 hours', now()+interval '2 days 3 hours','scheduled',1);          -- FX3
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, flex, starts_at, ends_at, status, booked_count, hidden_from_members) values
  ('95f10000-0000-0000-0000-00000000c001','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-00000000010c','95f10000-0000-0000-0000-0000000000c1','95f10000-0000-0000-0000-0000000000d2','95f10000-0000-0000-0000-0000000000e2','Core One',10,false, now()+interval '2 days 1 hour', now()+interval '2 days 2 hours','scheduled',1,false),   -- C1 booked
  ('95f10000-0000-0000-0000-00000000c002','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-00000000010c','95f10000-0000-0000-0000-0000000000c1','95f10000-0000-0000-0000-0000000000d2','95f10000-0000-0000-0000-0000000000e2','Core Two',10,false, now()+interval '2 days 3 hours', now()+interval '2 days 4 hours','scheduled',0,false),   -- C2 empty
  ('95f10000-0000-0000-0000-00000000cd03','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-00000000010c','95f10000-0000-0000-0000-0000000000c1','95f10000-0000-0000-0000-0000000000d2','95f10000-0000-0000-0000-0000000000e2','Core Hidden',10,false, now()+interval '2 days 5 hours', now()+interval '2 days 6 hours','scheduled',0,true),  -- CH hidden
  ('95f10000-0000-0000-0000-00000000cf04','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-00000000010c','95f10000-0000-0000-0000-0000000000c1','95f10000-0000-0000-0000-0000000000d2','95f10000-0000-0000-0000-0000000000e2','Core Full',1,false, now()+interval '2 days 7 hours', now()+interval '2 days 8 hours','scheduled',1,false),   -- CFULL
  ('95f10000-0000-0000-0000-00000000ca05','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-00000000010c','95f10000-0000-0000-0000-0000000000c1','95f10000-0000-0000-0000-0000000000d2','95f10000-0000-0000-0000-0000000000e2','Core Past',10,false, now()-interval '1 day', now()-interval '1 day'+interval '1 hour','scheduled',0,false),      -- CPAST
  ('95f10000-0000-0000-0000-00000000cc06','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-00000000010c','95f10000-0000-0000-0000-0000000000c2','95f10000-0000-0000-0000-0000000000d2','95f10000-0000-0000-0000-0000000000e2','Core Barre',10,false, now()+interval '2 days 9 hours', now()+interval '2 days 10 hours','scheduled',0,false); -- CX (CT2)

-- bookings
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source, provisional) values
  ('95f10000-0000-0000-0000-0000000b0001','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-0000000f0001','95f10000-0000-0000-0000-0000000000b1','booked','comp', true),   -- M1 free-first on FX
  ('95f10000-0000-0000-0000-0000000b0002','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-0000000f0002','95f10000-0000-0000-0000-0000000000b2','booked','drop_in', false), -- M2 on FX2 (final)
  ('95f10000-0000-0000-0000-0000000b0003','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-0000000f0003','95f10000-0000-0000-0000-0000000000b3','booked','drop_in', false), -- ML on FXLATCH
  ('95f10000-0000-0000-0000-0000000b0004','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-00000000c001','95f10000-0000-0000-0000-0000000000b2','booked','drop_in', false), -- M2 on C1 (makes it "booked")
  ('95f10000-0000-0000-0000-0000000b0005','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-00000000cf04','95f10000-0000-0000-0000-0000000000b3','booked','drop_in', false), -- filler on CFULL
  ('95f10000-0000-0000-0000-0000000b0006','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-0000000f0004','95f10000-0000-0000-0000-0000000000b4','booked','class_pack', false); -- M3 plan seat on FX3
update bookings set membership_id = '95f10000-0000-0000-0000-000000005004' where id = '95f10000-0000-0000-0000-0000000b0006';
-- M1's free-first host-null guest_passes row (travels with the move)
insert into guest_passes (id, studio_id, host_member_id, guest_member_id, guest_email, occurrence_id, guest_booking_id, status) values
  ('95f10000-0000-0000-0000-00000000a001','95f10000-0000-0000-0000-0000000000a0', null,'95f10000-0000-0000-0000-0000000000b1','m1@e.com','95f10000-0000-0000-0000-0000000f0001','95f10000-0000-0000-0000-0000000b0001','confirmed');

delete from notifications where studio_id = '95f10000-0000-0000-0000-0000000000a0';

-- =============================================================================
-- 1. the sweep queues 2-day once, final from the deadline, and nothing latched
-- =============================================================================
select sweep_flex_rescue(now());

select expect_num('2-day fired once for the flex-two-day member',
  (select count(*) from notifications where template_key='flex_rescue_2days' and member_id='95f10000-0000-0000-0000-0000000000b1'), 1);
select expect_num('2-day did NOT fire for the latched class member',
  (select count(*) from notifications where template_key='flex_rescue_2days' and member_id='95f10000-0000-0000-0000-0000000000b3'), 0);
select expect_num('final fired once for the near-deadline member',
  (select count(*) from notifications where template_key='flex_rescue_final' and member_id='95f10000-0000-0000-0000-0000000000b2'), 1);
select expect_num('the 2-day class did NOT also get a final (deadline far off)',
  (select count(*) from notifications where template_key='flex_rescue_final' and member_id='95f10000-0000-0000-0000-0000000000b1'), 0);
-- the payload carries the card list and the scalar tokens
select expect_true('the 2-day payload carries class_list_core html + n_more',
  (select (payload ->> 'class_list_core') like '%Move me to this class%'
       and (payload ->> 'n_more') = '2'
     from notifications where template_key='flex_rescue_2days' and member_id='95f10000-0000-0000-0000-0000000000b1'));

-- a second sweep adds nothing (dedupe on the queue key)
select sweep_flex_rescue(now());
select expect_num('a second sweep queues no duplicate 2-day',
  (select count(*) from notifications where template_key='flex_rescue_2days' and member_id='95f10000-0000-0000-0000-0000000000b1'), 1);
select expect_num('a second sweep queues no duplicate final',
  (select count(*) from notifications where template_key='flex_rescue_final' and member_id='95f10000-0000-0000-0000-0000000000b2'), 1);

-- =============================================================================
-- 2. core_classes_for_rescue — ordered, filtered
-- =============================================================================
select expect_text('the first card is the core class with a booking (C1)',
  (select name from core_classes_for_rescue('95f10000-0000-0000-0000-0000000f0001') limit 1), 'Core One');
select expect_num('the hidden, full and past core classes are excluded (3 shown: C1,C2,CX)',
  (select count(*) from core_classes_for_rescue('95f10000-0000-0000-0000-0000000f0001')), 3);
select expect_true('a flex class is never a rescue target',
  (select not exists (select 1 from core_classes_for_rescue('95f10000-0000-0000-0000-0000000f0001')
                       where occurrence_id = '95f10000-0000-0000-0000-0000000f0004')));

-- =============================================================================
-- 3. refusals (service context passes the member guard; logic is what is tested)
-- =============================================================================
select expect_text('full target => class_full',
  move_reason('95f10000-0000-0000-0000-0000000b0001','95f10000-0000-0000-0000-00000000cf04'), 'class_full');
select expect_text('past target => class_in_past',
  move_reason('95f10000-0000-0000-0000-0000000b0001','95f10000-0000-0000-0000-00000000ca05'), 'class_in_past');
select expect_text('hidden target => class_hidden',
  move_reason('95f10000-0000-0000-0000-0000000b0001','95f10000-0000-0000-0000-00000000cd03'), 'class_hidden');
select expect_text('same class => already_in_class',
  move_reason('95f10000-0000-0000-0000-0000000b0001','95f10000-0000-0000-0000-0000000f0001'), 'already_in_class');
select expect_text('a latched source => source_confirmed',
  move_reason('95f10000-0000-0000-0000-0000000b0003','95f10000-0000-0000-0000-00000000c002'), 'source_confirmed');
select expect_text('a plan seat to an uncovered class type => plan_not_covering',
  move_reason('95f10000-0000-0000-0000-0000000b0006','95f10000-0000-0000-0000-00000000cc06'), 'plan_not_covering');

-- =============================================================================
-- 4. ownership: another member cannot move your booking
-- =============================================================================
do $$ declare r jsonb; begin
  perform login('95f10000-0000-0000-0000-0000000000f2');  -- M2
  begin
    select move_booking('95f10000-0000-0000-0000-0000000b0001','95f10000-0000-0000-0000-00000000c002') into r;
    raise exception 'BAD another member moved M1''s booking';
  exception when sqlstate 'PT403' then raise notice 'PASS another member is refused PT403';
  end;
end $$;
reset role;

-- =============================================================================
-- 5. success as the member: seat type + free first class travel, email queued
-- =============================================================================
do $$ declare r jsonb; begin
  perform login('95f10000-0000-0000-0000-0000000000f1');  -- M1
  select move_booking('95f10000-0000-0000-0000-0000000b0001','95f10000-0000-0000-0000-00000000c002') into r;
  if not (r->>'ok')::boolean then raise exception 'BAD move refused: %', r->>'reason'; end if;
end $$;
reset role;

select expect_text('the booking is now in Core Two',
  (select occurrence_id::text from bookings where id='95f10000-0000-0000-0000-0000000b0001'),
  '95f10000-0000-0000-0000-00000000c002');
select expect_text('the seat type is unchanged (comp)',
  (select payment_source::text from bookings where id='95f10000-0000-0000-0000-0000000b0001'), 'comp');
select expect_text('the free first class travelled (guest_passes row moved)',
  (select occurrence_id::text from guest_passes where guest_booking_id='95f10000-0000-0000-0000-0000000b0001'),
  '95f10000-0000-0000-0000-00000000c002');
select expect_num('one booking_rebooked email was queued by the move',
  (select count(*) from notifications where template_key='booking_rebooked' and member_id='95f10000-0000-0000-0000-0000000000b1'), 1);

-- =============================================================================
-- 6. the Journey shows "Rescue email sent" (member_activity staff arm)
-- =============================================================================
select expect_num('the member statement carries a rescue_email row',
  (select count(*) from member_activity('95f10000-0000-0000-0000-0000000000b1', current_date - 1, current_date + 30)
    where kind = 'rescue_email'), 1);

-- anon stays THIRTEEN
select expect_num('anon surface is exactly thirteen',
  (select count(*) from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
    where ns.nspname='public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not in ('login','expect_text','expect_true','expect_num','move_reason')), 13);

select 'ALL FLEX RESCUE TESTS PASSED' as result;
