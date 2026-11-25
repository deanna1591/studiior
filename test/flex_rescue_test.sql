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
  ('95f10000-0000-0000-0000-0000000000b4','95f10000-0000-0000-0000-0000000000a0',null,'Pat','Plan','m3@e.com','active'),
  ('95f10000-0000-0000-0000-0000000000b5','95f10000-0000-0000-0000-0000000000a0',null,'Fay','Free','mf@e.com','lead');

insert into memberships (id, studio_id, member_id, plan_id, status, credits_remaining, price_cents, currency, starts_on) values
  ('95f10000-0000-0000-0000-000000005004','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-0000000000b4','95f10000-0000-0000-0000-00000000a101','active',9,500000,'PHP', current_date);

-- flex source classes (room d1) + core targets (room d2 so no overlap)
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, minimum_bookings, flex, flex_reached_minimum_at, starts_at, ends_at, status, booked_count) values
  ('95f10000-0000-0000-0000-0000000f0001','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-00000000010c','95f10000-0000-0000-0000-0000000000c1','95f10000-0000-0000-0000-0000000000d1','95f10000-0000-0000-0000-0000000000e1','Flex Two Day',10,3,true,null, date_trunc('day', now()) + interval '2 days', date_trunc('day', now()) + interval '2 days 1 hour','scheduled',1),            -- FX
  ('95f10000-0000-0000-0000-0000000f0002','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-00000000010c','95f10000-0000-0000-0000-0000000000c1','95f10000-0000-0000-0000-0000000000d1','95f10000-0000-0000-0000-0000000000e1','Flex Final',10,3,true,null, now()+interval '5 hours', now()+interval '6 hours','scheduled',1),                        -- FX2
  ('95f10000-0000-0000-0000-0000000f0003','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-00000000010c','95f10000-0000-0000-0000-0000000000c1','95f10000-0000-0000-0000-0000000000d1','95f10000-0000-0000-0000-0000000000e1','Flex Latched',10,3,true,now(), date_trunc('day', now()) + interval '2 days 6 hours', date_trunc('day', now()) + interval '2 days 7 hours','scheduled',3),  -- FXLATCH
  ('95f10000-0000-0000-0000-0000000f0004','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-00000000010c','95f10000-0000-0000-0000-0000000000c1','95f10000-0000-0000-0000-0000000000d1','95f10000-0000-0000-0000-0000000000e1','Flex Plan',10,3,true,null, date_trunc('day', now()) + interval '2 days 2 hours', date_trunc('day', now()) + interval '2 days 3 hours','scheduled',1),          -- FX3
  ('95f10000-0000-0000-0000-0000000f0005','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-00000000010c','95f10000-0000-0000-0000-0000000000c1','95f10000-0000-0000-0000-0000000000d2','95f10000-0000-0000-0000-0000000000e2','Flex Free Final',10,3,true,null, now()+interval '5 hours', now()+interval '5 hours 30 minutes','scheduled',1);  -- FXF (free-first, near deadline)
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, flex, starts_at, ends_at, status, booked_count, hidden_from_members) values
  ('95f10000-0000-0000-0000-00000000c001','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-00000000010c','95f10000-0000-0000-0000-0000000000c1','95f10000-0000-0000-0000-0000000000d2','95f10000-0000-0000-0000-0000000000e2','Core One',10,false, date_trunc('day', now()) + interval '2 days 1 hour', date_trunc('day', now()) + interval '2 days 2 hours','scheduled',1,false),   -- C1 booked
  ('95f10000-0000-0000-0000-00000000c002','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-00000000010c','95f10000-0000-0000-0000-0000000000c1','95f10000-0000-0000-0000-0000000000d2','95f10000-0000-0000-0000-0000000000e2','Core Two',10,false, date_trunc('day', now()) + interval '2 days 3 hours', date_trunc('day', now()) + interval '2 days 4 hours','scheduled',0,false),   -- C2 empty
  ('95f10000-0000-0000-0000-00000000cd03','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-00000000010c','95f10000-0000-0000-0000-0000000000c1','95f10000-0000-0000-0000-0000000000d2','95f10000-0000-0000-0000-0000000000e2','Core Hidden',10,false, date_trunc('day', now()) + interval '2 days 5 hours', date_trunc('day', now()) + interval '2 days 6 hours','scheduled',0,true),  -- CH hidden
  ('95f10000-0000-0000-0000-00000000cf04','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-00000000010c','95f10000-0000-0000-0000-0000000000c1','95f10000-0000-0000-0000-0000000000d2','95f10000-0000-0000-0000-0000000000e2','Core Full',1,false, date_trunc('day', now()) + interval '2 days 7 hours', date_trunc('day', now()) + interval '2 days 8 hours','scheduled',1,false),   -- CFULL
  ('95f10000-0000-0000-0000-00000000ca05','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-00000000010c','95f10000-0000-0000-0000-0000000000c1','95f10000-0000-0000-0000-0000000000d2','95f10000-0000-0000-0000-0000000000e2','Core Past',10,false, now()-interval '1 day', now()-interval '1 day'+interval '1 hour','scheduled',0,false),      -- CPAST
  ('95f10000-0000-0000-0000-00000000cc06','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-00000000010c','95f10000-0000-0000-0000-0000000000c2','95f10000-0000-0000-0000-0000000000d2','95f10000-0000-0000-0000-0000000000e2','Core Barre',10,false, date_trunc('day', now()) + interval '2 days 9 hours', date_trunc('day', now()) + interval '2 days 10 hours','scheduled',0,false); -- CX (CT2)

-- bookings
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source, provisional) values
  ('95f10000-0000-0000-0000-0000000b0001','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-0000000f0001','95f10000-0000-0000-0000-0000000000b1','booked','comp', true),   -- M1 free-first on FX
  ('95f10000-0000-0000-0000-0000000b0002','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-0000000f0002','95f10000-0000-0000-0000-0000000000b2','booked','drop_in', false), -- M2 on FX2 (final)
  ('95f10000-0000-0000-0000-0000000b0003','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-0000000f0003','95f10000-0000-0000-0000-0000000000b3','booked','drop_in', false), -- ML on FXLATCH
  ('95f10000-0000-0000-0000-0000000b0004','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-00000000c001','95f10000-0000-0000-0000-0000000000b2','booked','drop_in', false), -- M2 on C1 (makes it "booked")
  ('95f10000-0000-0000-0000-0000000b0005','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-00000000cf04','95f10000-0000-0000-0000-0000000000b3','booked','drop_in', false), -- filler on CFULL
  ('95f10000-0000-0000-0000-0000000b0006','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-0000000f0004','95f10000-0000-0000-0000-0000000000b4','booked','class_pack', false), -- M3 plan seat on FX3
  ('95f10000-0000-0000-0000-0000000b0007','95f10000-0000-0000-0000-0000000000a0','95f10000-0000-0000-0000-0000000f0005','95f10000-0000-0000-0000-0000000000b5','booked','comp', true);   -- MF free-first on FXF (near-deadline)
update bookings set membership_id = '95f10000-0000-0000-0000-000000005004' where id = '95f10000-0000-0000-0000-0000000b0006';
-- free-first host-null guest_passes rows (M1 on FX, MF on FXF)
insert into guest_passes (id, studio_id, host_member_id, guest_member_id, guest_email, occurrence_id, guest_booking_id, status) values
  ('95f10000-0000-0000-0000-00000000a001','95f10000-0000-0000-0000-0000000000a0', null,'95f10000-0000-0000-0000-0000000000b1','m1@e.com','95f10000-0000-0000-0000-0000000f0001','95f10000-0000-0000-0000-0000000b0001','confirmed'),
  ('95f10000-0000-0000-0000-00000000a002','95f10000-0000-0000-0000-0000000000a0', null,'95f10000-0000-0000-0000-0000000000b5','mf@e.com','95f10000-0000-0000-0000-0000000f0005','95f10000-0000-0000-0000-0000000b0007','confirmed');

delete from notifications where studio_id = '95f10000-0000-0000-0000-0000000000a0';

-- =============================================================================
-- 1. the sweep queues 2-day once, final from the deadline, and nothing latched
-- =============================================================================
select sweep_flex_rescue(now());

-- Decision 95(a): b1 is a FREE FIRST class (comp + host-null pass) -> the free
-- twin; b4 is a PAID plan seat -> the flex twin.
select expect_num('a free first 2-day booking gets free_rescue_2days',
  (select count(*) from notifications where template_key='free_rescue_2days' and member_id='95f10000-0000-0000-0000-0000000000b1'), 1);
select expect_num('...and NOT flex_rescue_2days',
  (select count(*) from notifications where template_key='flex_rescue_2days' and member_id='95f10000-0000-0000-0000-0000000000b1'), 0);
select expect_num('a paid flex 2-day booking gets flex_rescue_2days',
  (select count(*) from notifications where template_key='flex_rescue_2days' and member_id='95f10000-0000-0000-0000-0000000000b4'), 1);
select expect_num('...and NOT free_rescue_2days',
  (select count(*) from notifications where template_key='free_rescue_2days' and member_id='95f10000-0000-0000-0000-0000000000b4'), 0);
select expect_num('2-day did NOT fire for the latched class member (neither twin)',
  (select count(*) from notifications where template_key in ('flex_rescue_2days','free_rescue_2days') and member_id='95f10000-0000-0000-0000-0000000000b3'), 0);
-- finals: b2 paid -> flex twin, b5 free-first -> free twin
select expect_num('a paid flex final gets flex_rescue_final',
  (select count(*) from notifications where template_key='flex_rescue_final' and member_id='95f10000-0000-0000-0000-0000000000b2'), 1);
select expect_num('a free first final gets free_rescue_final',
  (select count(*) from notifications where template_key='free_rescue_final' and member_id='95f10000-0000-0000-0000-0000000000b5'), 1);
select expect_num('...and the free-first final is NOT the flex one',
  (select count(*) from notifications where template_key='flex_rescue_final' and member_id='95f10000-0000-0000-0000-0000000000b5'), 0);
select expect_num('the free-first 2-day class did NOT also get a final (deadline far off)',
  (select count(*) from notifications where template_key in ('flex_rescue_final','free_rescue_final') and member_id='95f10000-0000-0000-0000-0000000000b1'), 0);
-- the free 2-day payload carries the same card list + tokens
select expect_true('the free 2-day payload carries class_list_core html + n_more',
  (select (payload ->> 'class_list_core') like '%Move me to this class%'
       and (payload ->> 'n_more') = '2'
     from notifications where template_key='free_rescue_2days' and member_id='95f10000-0000-0000-0000-0000000000b1'));

-- a second sweep adds nothing (dedupe is the SAME key whichever twin)
select sweep_flex_rescue(now());
select expect_num('a second sweep queues no duplicate free 2-day',
  (select count(*) from notifications where template_key='free_rescue_2days' and member_id='95f10000-0000-0000-0000-0000000000b1'), 1);
select expect_num('a second sweep queues no duplicate free final',
  (select count(*) from notifications where template_key='free_rescue_final' and member_id='95f10000-0000-0000-0000-0000000000b5'), 1);

-- =============================================================================
-- 2. core_classes_for_rescue — ordered, filtered
-- =============================================================================
-- Decision 95(b): the flex class two short (Flex Plan, 1 of 3) now leads the
-- list, then the core classes (a booked one first). The latched flex class is
-- running and never offered as one needing people.
select expect_text('the first card is the flex class two short (Flex Plan)',
  (select name from core_classes_for_rescue('95f10000-0000-0000-0000-0000000f0001') limit 1), 'Flex Plan');
select expect_text('...labelled Needs 2 more',
  (select label from core_classes_for_rescue('95f10000-0000-0000-0000-0000000f0001') limit 1), 'Needs 2 more');
select expect_text('the second card is the core class with a booking (C1), Always runs',
  (select name || ' / ' || label from core_classes_for_rescue('95f10000-0000-0000-0000-0000000f0001') offset 1 limit 1),
  'Core One / Always runs');
select expect_num('hidden, full and past classes are excluded (4 shown: Flex Plan, C1, C2, CX)',
  (select count(*) from core_classes_for_rescue('95f10000-0000-0000-0000-0000000f0001')), 4);
select expect_true('a latched (running) flex class is never offered as needing people',
  (select not exists (select 1 from core_classes_for_rescue('95f10000-0000-0000-0000-0000000f0001')
                       where occurrence_id = '95f10000-0000-0000-0000-0000000f0003')));

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


-- =============================================================================
-- 7. Decision 95(b): the order. One short first (nearest), two short only while
--    fewer than four rows, core last (booked first), the member's own classes
--    left out, and a free first class rescue stays core-only when
--    free_first_core_only is on. A studio of its own (suffix a9).
-- =============================================================================
insert into studios (id, name, slug, timezone, currency, status) values
  ('95f10000-0000-0000-0000-0000000000a9','Rescue Order Studio','95f1-sb','UTC','PHP','active');
insert into studio_settings (studio_id, require_waiver, flex_enabled, flex_min_bookings,
       flex_deadline_mode, flex_deadline_hours, free_first_class_enabled) values
  ('95f10000-0000-0000-0000-0000000000a9', false, true, 3, 'hours_before', 4, true);
insert into locations (id, studio_id, name, is_primary) values
  ('95f10000-0000-0000-0000-00000000a90c','95f10000-0000-0000-0000-0000000000a9','Main', true);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity, status) values
  ('95f10000-0000-0000-0000-00000000a9c1','95f10000-0000-0000-0000-0000000000a9','Reformer',60,10,'active');
insert into members (id, studio_id, first_name, last_name, email, status)
select ('95f10000-0000-0000-0000-0000000a90' || lpad(g::text, 2, '0'))::uuid,
       '95f10000-0000-0000-0000-0000000000a9', 'F' || g, 'Filler', 'f' || g || '@e.com', 'active'
  from generate_series(1, 12) g;
-- S source (flex, empty); O1a/O1b one short (2 of 3); T2a..T2c two short (1 of 3); K1 core booked, K2 core empty.
insert into class_occurrences (id, studio_id, location_id, class_type_id, name, capacity, minimum_bookings, flex, starts_at, ends_at, status) values
  ('95f10000-0000-0000-0000-00000000a901','95f10000-0000-0000-0000-0000000000a9','95f10000-0000-0000-0000-00000000a90c','95f10000-0000-0000-0000-00000000a9c1','Source',10,3,true, date_trunc('day', now()) + interval '3 days', date_trunc('day', now()) + interval '3 days 1 hour','scheduled'),
  ('95f10000-0000-0000-0000-00000000a902','95f10000-0000-0000-0000-0000000000a9','95f10000-0000-0000-0000-00000000a90c','95f10000-0000-0000-0000-00000000a9c1','One Late',10,3,true, date_trunc('day', now()) + interval '3 days 3 hours', date_trunc('day', now()) + interval '3 days 4 hours','scheduled'),
  ('95f10000-0000-0000-0000-00000000a903','95f10000-0000-0000-0000-0000000000a9','95f10000-0000-0000-0000-00000000a90c','95f10000-0000-0000-0000-00000000a9c1','One Early',10,3,true, date_trunc('day', now()) + interval '3 days 1 hour', date_trunc('day', now()) + interval '3 days 2 hours','scheduled'),
  ('95f10000-0000-0000-0000-00000000a904','95f10000-0000-0000-0000-0000000000a9','95f10000-0000-0000-0000-00000000a90c','95f10000-0000-0000-0000-00000000a9c1','Two A',10,3,true, date_trunc('day', now()) + interval '3 days 30 minutes', date_trunc('day', now()) + interval '3 days 90 minutes','scheduled'),
  ('95f10000-0000-0000-0000-00000000a905','95f10000-0000-0000-0000-0000000000a9','95f10000-0000-0000-0000-00000000a90c','95f10000-0000-0000-0000-00000000a9c1','Two B',10,3,true, date_trunc('day', now()) + interval '3 days 2 hours', date_trunc('day', now()) + interval '3 days 3 hours','scheduled'),
  ('95f10000-0000-0000-0000-00000000a906','95f10000-0000-0000-0000-0000000000a9','95f10000-0000-0000-0000-00000000a90c','95f10000-0000-0000-0000-00000000a9c1','Two C',10,3,true, date_trunc('day', now()) + interval '3 days 4 hours', date_trunc('day', now()) + interval '3 days 5 hours','scheduled'),
  ('95f10000-0000-0000-0000-00000000a907','95f10000-0000-0000-0000-0000000000a9','95f10000-0000-0000-0000-00000000a90c','95f10000-0000-0000-0000-00000000a9c1','Core Booked',10,null,false, date_trunc('day', now()) + interval '3 days 6 hours', date_trunc('day', now()) + interval '3 days 7 hours','scheduled'),
  ('95f10000-0000-0000-0000-00000000a908','95f10000-0000-0000-0000-0000000000a9','95f10000-0000-0000-0000-00000000a90c','95f10000-0000-0000-0000-00000000a9c1','Core Empty',10,null,false, date_trunc('day', now()) + interval '3 days 5 hours', date_trunc('day', now()) + interval '3 days 6 hours','scheduled');
insert into bookings (studio_id, occurrence_id, member_id, status, payment_source)
select '95f10000-0000-0000-0000-0000000000a9', o::uuid, ('95f10000-0000-0000-0000-0000000a90' || m)::uuid, 'booked', 'comp'
  from (values ('95f10000-0000-0000-0000-00000000a902','01'), ('95f10000-0000-0000-0000-00000000a902','02'),
               ('95f10000-0000-0000-0000-00000000a903','03'), ('95f10000-0000-0000-0000-00000000a903','04'),
               ('95f10000-0000-0000-0000-00000000a904','05'), ('95f10000-0000-0000-0000-00000000a905','06'),
               ('95f10000-0000-0000-0000-00000000a906','07'), ('95f10000-0000-0000-0000-00000000a907','08')) v(o, m);
-- booked_count is the cache book_class keeps; direct inserts do not touch it.
update class_occurrences set booked_count = 1 where id = '95f10000-0000-0000-0000-00000000a907';
-- The rescued member (F10) holds a free first class on Source.
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source) values
  ('95f10000-0000-0000-0000-00000000a9b0','95f10000-0000-0000-0000-0000000000a9','95f10000-0000-0000-0000-00000000a901','95f10000-0000-0000-0000-0000000a9010','booked','comp');
insert into guest_passes (id, studio_id, host_member_id, guest_member_id, guest_email, occurrence_id, guest_booking_id, status) values
  ('95f10000-0000-0000-0000-00000000a9a1','95f10000-0000-0000-0000-0000000000a9', null,'95f10000-0000-0000-0000-0000000a9010','f10@e.com','95f10000-0000-0000-0000-00000000a901','95f10000-0000-0000-0000-00000000a9b0','confirmed');

select expect_text('the order: one short by start, two short while under four rows, then core booked first',
  (select string_agg(name || ':' || label, ', ' order by ord)
     from (select name, label, row_number() over () as ord
             from core_classes_for_rescue('95f10000-0000-0000-0000-00000000a901')) z),
  'One Early:Needs 1 more, One Late:Needs 1 more, Two A:Needs 2 more, Two B:Needs 2 more, Core Booked:Always runs, Core Empty:Always runs');
select expect_true('the third two-short class (Two C) is left out: four rows were reached',
  (select not exists (select 1 from core_classes_for_rescue('95f10000-0000-0000-0000-00000000a901') where name = 'Two C')));

-- F10 is also booked on One Early: their own class is left out when the booking is passed.
insert into bookings (studio_id, occurrence_id, member_id, status, payment_source) values
  ('95f10000-0000-0000-0000-0000000000a9','95f10000-0000-0000-0000-00000000a903','95f10000-0000-0000-0000-0000000a9010','booked','class_pack');
select expect_true('a class the member already holds is not offered',
  (select not exists (select 1 from core_classes_for_rescue('95f10000-0000-0000-0000-00000000a901',
                                                            '95f10000-0000-0000-0000-00000000a9b0')
                        where name = 'One Early')));
select expect_text('with the booking, Two C comes in (only one one-short row now)',
  (select string_agg(name, ', ' order by ord) from (select name, row_number() over () as ord
     from core_classes_for_rescue('95f10000-0000-0000-0000-00000000a901','95f10000-0000-0000-0000-00000000a9b0')) z),
  'One Late, Two A, Two B, Two C, Core Booked, Core Empty');

update studio_settings set free_first_core_only = true where studio_id = '95f10000-0000-0000-0000-0000000000a9';
select expect_text('free_first_core_only on: a free first class rescue lists core only',
  (select string_agg(label, ', ' order by ord) from (select label, row_number() over () as ord
     from core_classes_for_rescue('95f10000-0000-0000-0000-00000000a901','95f10000-0000-0000-0000-00000000a9b0')) z),
  'Always runs, Always runs');
select expect_true('...but a paid rescue still leads with flex (no booking passed)',
  (select label from core_classes_for_rescue('95f10000-0000-0000-0000-00000000a901') limit 1) = 'Needs 1 more');

-- The email card carries the label; the platform default intro sentence changed.
select expect_true('the rescue card prints its label',
  (select html from flex_rescue_block('95f10000-0000-0000-0000-00000000a9b0')) like '%Always runs%');
select expect_true('the 2-day default intro reads "Pick one that needs you"',
  (select text_body from notification_templates where key='flex_rescue_2days')
    like '%Pick one that needs you, or one that always runs:%');
select expect_true('the free final default intro reads "Pick one that needs you"',
  (select html_body from notification_templates where key='free_rescue_final')
    like '%Pick one that needs you, or one that always runs:%');

-- Only the booking's member (or the desk/service) may pass the booking.
do $$ declare st text; begin
  perform set_config('request.jwt.claim.sub', '95f10000-0000-0000-0000-0000000000f2', true);
  set local role authenticated;
  begin perform * from core_classes_for_rescue('95f10000-0000-0000-0000-00000000a901','95f10000-0000-0000-0000-00000000a9b0');
    st := 'none'; exception when others then st := sqlstate; end;
  reset role;
  if st <> 'PT403' then raise exception 'BAD another member passing a booking: got %', st; end if;
  raise notice 'PASS another member passing a booking is refused PT403';
end $$;

-- anon stays FOURTEEN
select expect_num('anon surface is exactly fourteen',
  (select count(*) from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
    where ns.nspname='public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not in ('login','expect_text','expect_true','expect_num','move_reason')), 14);

select 'ALL FLEX RESCUE TESTS PASSED' as result;
