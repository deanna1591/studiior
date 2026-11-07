-- =============================================================================
-- Decision 92 — rebook a member from the roster. Migration 20260833210000.
-- =============================================================================
-- UUID space 9eb0 (hex), checked free. Run after `supabase db reset`.
--
-- Staff move a member's booking to another class. The seat moves in place so its
-- type travels unchanged; the vacated seat releases the normal way (waitlist
-- promoted); no strike; one booking_rebooked email and no confirmation/
-- cancellation email for the move. RED proof: pre-92 rebook_member does not
-- exist, so every assertion errors.
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
create or replace function as_reason(uid text, sql text) returns text language plpgsql as $$
declare r jsonb; begin perform set_config('request.jwt.claim.sub', uid, true); set local role authenticated;
  begin execute sql into r; return coalesce(r->>'reason', case when (r->>'ok')::boolean then 'ok' else 'noreason' end);
  exception when others then return sqlstate; end; end $$;

reset role;

-- ---- fixtures --------------------------------------------------------------
insert into auth.users (id) values
  ('9eb00000-0000-0000-0000-0000000000f0'),  -- owner
  ('9eb00000-0000-0000-0000-0000000000f1'),  -- front desk
  ('9eb00000-0000-0000-0000-0000000000f2');  -- instructor login
insert into profiles (id, email, full_name) values
  ('9eb00000-0000-0000-0000-0000000000f0','own@example.com','Owner'),
  ('9eb00000-0000-0000-0000-0000000000f1','fd@example.com','Front Desk'),
  ('9eb00000-0000-0000-0000-0000000000f2','inst@example.com','Coach');

insert into studios (id, name, slug, timezone, currency, status) values
  ('9eb00000-0000-0000-0000-0000000000a0','Rebook Studio','9eb0-sa','UTC','PHP','active');
insert into studio_settings (studio_id, require_waiver, free_first_class_enabled) values
  ('9eb00000-0000-0000-0000-0000000000a0', false, true);
insert into locations (id, studio_id, name, is_primary) values
  ('9eb00000-0000-0000-0000-00000000010c','9eb00000-0000-0000-0000-0000000000a0','Main', true);

insert into studio_staff (id, studio_id, user_id, email, role, status) values
  ('9eb00000-0000-0000-0000-00000000ff00','9eb00000-0000-0000-0000-0000000000a0','9eb00000-0000-0000-0000-0000000000f0','own@example.com','owner','active'),
  ('9eb00000-0000-0000-0000-00000000ff01','9eb00000-0000-0000-0000-0000000000a0','9eb00000-0000-0000-0000-0000000000f1','fd@example.com','front_desk','active'),
  ('9eb00000-0000-0000-0000-00000000ff02','9eb00000-0000-0000-0000-0000000000a0','9eb00000-0000-0000-0000-0000000000f2','inst@example.com','instructor','active');

insert into class_types (id, studio_id, name, duration_minutes, default_capacity, status) values
  ('9eb00000-0000-0000-0000-0000000000c1','9eb00000-0000-0000-0000-0000000000a0','Reformer',60,10,'active'),
  ('9eb00000-0000-0000-0000-0000000000c2','9eb00000-0000-0000-0000-0000000000a0','Barre',60,10,'active');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('9eb00000-0000-0000-0000-0000000000d1','9eb00000-0000-0000-0000-0000000000a0','9eb00000-0000-0000-0000-00000000010c','Studio A', 10);
insert into instructors (id, studio_id, display_name, status) values
  ('9eb00000-0000-0000-0000-0000000000e1','9eb00000-0000-0000-0000-0000000000a0','Ada Example','active');

-- occurrences (all UTC studio; tomorrow-ish)
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, starts_at, ends_at, status, booked_count) values
  ('9eb00000-0000-0000-0000-000000005c00','9eb00000-0000-0000-0000-0000000000a0','9eb00000-0000-0000-0000-00000000010c','9eb00000-0000-0000-0000-0000000000c1','9eb00000-0000-0000-0000-0000000000d1','9eb00000-0000-0000-0000-0000000000e1','Reformer Flow',10, now()+interval '1 day', now()+interval '1 day 1 hour','scheduled',6),   -- SRC
  ('9eb00000-0000-0000-0000-00000000700c','9eb00000-0000-0000-0000-0000000000a0','9eb00000-0000-0000-0000-00000000010c','9eb00000-0000-0000-0000-0000000000c1','9eb00000-0000-0000-0000-0000000000d1','9eb00000-0000-0000-0000-0000000000e1','Reformer Burn',10, now()+interval '1 day 2 hours', now()+interval '1 day 3 hours','scheduled',0),  -- T_OK
  ('9eb00000-0000-0000-0000-0000000ba77e','9eb00000-0000-0000-0000-0000000000a0','9eb00000-0000-0000-0000-00000000010c','9eb00000-0000-0000-0000-0000000000c2','9eb00000-0000-0000-0000-0000000000d1','9eb00000-0000-0000-0000-0000000000e1','Barre Burn',10, now()+interval '2 days', now()+interval '2 days 1 hour','scheduled',0),       -- T_BARRE (CT2)
  ('9eb00000-0000-0000-0000-00000000f017','9eb00000-0000-0000-0000-0000000000a0','9eb00000-0000-0000-0000-00000000010c','9eb00000-0000-0000-0000-0000000000c1','9eb00000-0000-0000-0000-0000000000d1','9eb00000-0000-0000-0000-0000000000e1','Reformer Full',1, now()+interval '2 days 2 hours', now()+interval '2 days 3 hours','scheduled',1),  -- T_FULL (cap 1, 1 booked)
  ('9eb00000-0000-0000-0000-00000000a517','9eb00000-0000-0000-0000-0000000000a0','9eb00000-0000-0000-0000-00000000010c','9eb00000-0000-0000-0000-0000000000c1','9eb00000-0000-0000-0000-0000000000d1','9eb00000-0000-0000-0000-0000000000e1','Reformer Past',10, now()-interval '1 day', now()-interval '1 day' + interval '1 hour','scheduled',0); -- T_PAST

-- SRC_FULL for the waitlist-promotion test (cap 1: 1 booked, 1 waitlisted)
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, starts_at, ends_at, status, booked_count) values
  ('9eb00000-0000-0000-0000-00000005f011','9eb00000-0000-0000-0000-0000000000a0','9eb00000-0000-0000-0000-00000000010c','9eb00000-0000-0000-0000-0000000000c1','9eb00000-0000-0000-0000-0000000000d1','9eb00000-0000-0000-0000-0000000000e1','Reformer Queue',1, now()+interval '1 day 4 hours', now()+interval '1 day 5 hours','scheduled',1);

-- a CT1-only plan (for plan_not_covering)
insert into membership_plans (id, studio_id, name, type, price_cents, currency, status, visibility, credits, restrictions) values
  ('9eb00000-0000-0000-0000-aaaa00001a01'::uuid,'9eb00000-0000-0000-0000-0000000000a0','Reformer Pack','class_pack',500000,'PHP','active','public',10,
   jsonb_build_object('class_type_ids', jsonb_build_array('9eb00000-0000-0000-0000-0000000000c1')));

-- members (M1 plan, M2 comp, M3 free-first, M4 desk-unpaid, M5 paid-drop, M6 guest, M7 wait, M8 filler, M9 move-out, M0 second-move)
insert into members (id, studio_id, first_name, last_name, email, status) values
  ('9eb00000-0000-0000-0000-0000000000b1','9eb00000-0000-0000-0000-0000000000a0','Plan','Member','m1@e.com','active'),
  ('9eb00000-0000-0000-0000-0000000000b2','9eb00000-0000-0000-0000-0000000000a0','Comp','Member','m2@e.com','active'),
  ('9eb00000-0000-0000-0000-0000000000b3','9eb00000-0000-0000-0000-0000000000a0','Free','First','m3@e.com','lead'),
  ('9eb00000-0000-0000-0000-0000000000b4','9eb00000-0000-0000-0000-0000000000a0','Desk','Unpaid','m4@e.com','active'),
  ('9eb00000-0000-0000-0000-0000000000b5','9eb00000-0000-0000-0000-0000000000a0','Paid','Drop','m5@e.com','active'),
  ('9eb00000-0000-0000-0000-0000000000b6','9eb00000-0000-0000-0000-0000000000a0','The','Guest','m6@e.com','lead'),
  ('9eb00000-0000-0000-0000-0000000000b7','9eb00000-0000-0000-0000-0000000000a0','Wait','Member','m7@e.com','active'),
  ('9eb00000-0000-0000-0000-0000000000b8','9eb00000-0000-0000-0000-0000000000a0','Filler','Member','m8@e.com','active'),
  ('9eb00000-0000-0000-0000-0000000000b9','9eb00000-0000-0000-0000-0000000000a0','Moveout','Member','m9@e.com','active'),
  ('9eb00000-0000-0000-0000-0000000000ba','9eb00000-0000-0000-0000-0000000000a0','Host','Member','m0@e.com','active');

-- M1's membership on the CT1-only plan
insert into memberships (id, studio_id, member_id, plan_id, status, credits_remaining, price_cents, currency, starts_on) values
  ('9eb00000-0000-0000-0000-000000005001','9eb00000-0000-0000-0000-0000000000a0','9eb00000-0000-0000-0000-0000000000b1','9eb00000-0000-0000-0000-aaaa00001a01'::uuid,'active',9,500000,'PHP', current_date);

-- bookings in SRC (one per seat type)
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source, membership_id, provisional) values
  ('9eb00000-0000-0000-0000-0000000b0001','9eb00000-0000-0000-0000-0000000000a0','9eb00000-0000-0000-0000-000000005c00','9eb00000-0000-0000-0000-0000000000b1','booked','class_pack','9eb00000-0000-0000-0000-000000005001', false),  -- plan seat
  ('9eb00000-0000-0000-0000-0000000b0002','9eb00000-0000-0000-0000-0000000000a0','9eb00000-0000-0000-0000-000000005c00','9eb00000-0000-0000-0000-0000000000b2','booked','comp',null, false),                                              -- comp
  ('9eb00000-0000-0000-0000-0000000b0003','9eb00000-0000-0000-0000-0000000000a0','9eb00000-0000-0000-0000-000000005c00','9eb00000-0000-0000-0000-0000000000b3','booked','comp',null, true),                                               -- free-first provisional
  ('9eb00000-0000-0000-0000-0000000b0004','9eb00000-0000-0000-0000-0000000000a0','9eb00000-0000-0000-0000-000000005c00','9eb00000-0000-0000-0000-0000000000b4','booked','drop_in',null, false),                                           -- desk unpaid
  ('9eb00000-0000-0000-0000-0000000b0005','9eb00000-0000-0000-0000-0000000000a0','9eb00000-0000-0000-0000-000000005c00','9eb00000-0000-0000-0000-0000000000b5','booked','drop_in',null, false),                                           -- paid drop-in
  ('9eb00000-0000-0000-0000-0000000b0006','9eb00000-0000-0000-0000-0000000000a0','9eb00000-0000-0000-0000-000000005c00','9eb00000-0000-0000-0000-0000000000b6','booked','comp',null, false);                                             -- guest seat
-- a paid payment for the paid drop-in (booking-keyed)
insert into payments (id, studio_id, member_id, booking_id, amount_cents, currency, status, provider, method) values
  ('9eb00000-0000-0000-0000-aaaa00000a05','9eb00000-0000-0000-0000-0000000000a0','9eb00000-0000-0000-0000-0000000000b5','9eb00000-0000-0000-0000-0000000b0005',105000,'PHP','succeeded','manual','cash');
-- free-first host-null guest_passes row (M3)
insert into guest_passes (id, studio_id, host_member_id, guest_member_id, guest_email, occurrence_id, guest_booking_id, status) values
  ('9eb00000-0000-0000-0000-aaaa00000003'::uuid,'9eb00000-0000-0000-0000-0000000000a0', null,'9eb00000-0000-0000-0000-0000000000b3','m3@e.com','9eb00000-0000-0000-0000-000000005c00','9eb00000-0000-0000-0000-0000000b0003','confirmed');
-- guest brought by a host (M6 guest, MA host) guest_passes row
insert into guest_passes (id, studio_id, host_member_id, guest_member_id, guest_email, occurrence_id, guest_booking_id, status) values
  ('9eb00000-0000-0000-0000-aaaa00000006'::uuid,'9eb00000-0000-0000-0000-0000000000a0','9eb00000-0000-0000-0000-0000000000ba','9eb00000-0000-0000-0000-0000000000b6','m6@e.com','9eb00000-0000-0000-0000-000000005c00','9eb00000-0000-0000-0000-0000000b0006','confirmed');

-- T_FULL already has 1 filler booked (M8)
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source) values
  ('9eb00000-0000-0000-0000-0000000b0008','9eb00000-0000-0000-0000-0000000000a0','9eb00000-0000-0000-0000-00000000f017','9eb00000-0000-0000-0000-0000000000b8','booked','drop_in');
-- SRC_FULL: M9 booked + M7 waitlisted
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source, waitlist_position) values
  ('9eb00000-0000-0000-0000-0000000b0009','9eb00000-0000-0000-0000-0000000000a0','9eb00000-0000-0000-0000-00000005f011','9eb00000-0000-0000-0000-0000000000b9','booked','drop_in',null),
  ('9eb00000-0000-0000-0000-0000000b0007','9eb00000-0000-0000-0000-0000000000a0','9eb00000-0000-0000-0000-00000005f011','9eb00000-0000-0000-0000-0000000000b7','waitlisted','drop_in',1);

\echo '--- 1. refusals (no state change): plan not covering, same class, past, full, instructor ---'
-- M1 is on a Reformer-only plan; moving to Barre is not covered
select expect_text('plan not covering', as_reason('9eb00000-0000-0000-0000-0000000000f1',
  'select rebook_member(''9eb00000-0000-0000-0000-0000000b0001'',''9eb00000-0000-0000-0000-0000000ba77e'')'), 'plan_not_covering');
reset role;
select expect_text('same class refused', as_reason('9eb00000-0000-0000-0000-0000000000f1',
  'select rebook_member(''9eb00000-0000-0000-0000-0000000b0002'',''9eb00000-0000-0000-0000-000000005c00'')'), 'already_in_class');
reset role;
select expect_text('past class refused', as_reason('9eb00000-0000-0000-0000-0000000000f1',
  'select rebook_member(''9eb00000-0000-0000-0000-0000000b0002'',''9eb00000-0000-0000-0000-00000000a517'')'), 'class_in_past');
reset role;
select expect_text('full class refused', as_reason('9eb00000-0000-0000-0000-0000000000f1',
  'select rebook_member(''9eb00000-0000-0000-0000-0000000b0002'',''9eb00000-0000-0000-0000-00000000f017'')'), 'class_full');
reset role;
-- an instructor is not desk-up -> PT403
select expect_text('instructor refused', as_reason('9eb00000-0000-0000-0000-0000000000f2',
  'select rebook_member(''9eb00000-0000-0000-0000-0000000b0002'',''9eb00000-0000-0000-0000-00000000700c'')'), 'PT403');
reset role;
-- nothing moved: M1 and M2 still in SRC, booked_count unchanged
select expect_num('src booked_count unchanged after refusals',
  (select booked_count from class_occurrences where id='9eb00000-0000-0000-0000-000000005c00'), 6);

-- the fixture inserts fired booking_confirmed/free_booking_pending at insert
-- time; clear so the counts below reflect ONLY what the moves queue.
delete from notifications;

\echo '--- 2. each seat type moves (front desk), type preserved ---'
select expect_text('plan seat moves (FD allowed)', as_reason('9eb00000-0000-0000-0000-0000000000f1',
  'select rebook_member(''9eb00000-0000-0000-0000-0000000b0001'',''9eb00000-0000-0000-0000-00000000700c'')'), 'ok');
reset role;
select expect_text('plan seat now in T_OK', (select occurrence_id::text from bookings where id='9eb00000-0000-0000-0000-0000000b0001'), '9eb00000-0000-0000-0000-00000000700c');
select expect_text('plan seat kept membership', (select membership_id::text from bookings where id='9eb00000-0000-0000-0000-0000000b0001'), '9eb00000-0000-0000-0000-000000005001');
select expect_text('plan seat kept payment_source', (select payment_source::text from bookings where id='9eb00000-0000-0000-0000-0000000b0001'), 'class_pack');

select expect_text('comp seat moves', as_reason('9eb00000-0000-0000-0000-0000000000f1',
  'select rebook_member(''9eb00000-0000-0000-0000-0000000b0002'',''9eb00000-0000-0000-0000-00000000700c'')'), 'ok');
reset role;
select expect_text('comp seat still comp', (select payment_source::text from bookings where id='9eb00000-0000-0000-0000-0000000b0002'), 'comp');

select expect_text('free-first moves', as_reason('9eb00000-0000-0000-0000-0000000000f1',
  'select rebook_member(''9eb00000-0000-0000-0000-0000000b0003'',''9eb00000-0000-0000-0000-00000000700c'')'), 'ok');
reset role;
select expect_text('free-first still comp', (select payment_source::text from bookings where id='9eb00000-0000-0000-0000-0000000b0003'), 'comp');
select expect_text('free-first guest_pass followed', (select occurrence_id::text from guest_passes where id='9eb00000-0000-0000-0000-aaaa00000003'), '9eb00000-0000-0000-0000-00000000700c');

select expect_text('paid drop-in moves', as_reason('9eb00000-0000-0000-0000-0000000000f1',
  'select rebook_member(''9eb00000-0000-0000-0000-0000000b0005'',''9eb00000-0000-0000-0000-00000000700c'')'), 'ok');
reset role;
select expect_text('paid drop-in still drop_in', (select payment_source::text from bookings where id='9eb00000-0000-0000-0000-0000000b0005'), 'drop_in');
select expect_text('payment still keyed to the booking in T_OK',
  (select b.occurrence_id::text from payments p join bookings b on b.id=p.booking_id where p.id='9eb00000-0000-0000-0000-aaaa00000a05'), '9eb00000-0000-0000-0000-00000000700c');

select expect_text('guest seat moves', as_reason('9eb00000-0000-0000-0000-0000000000f1',
  'select rebook_member(''9eb00000-0000-0000-0000-0000000b0006'',''9eb00000-0000-0000-0000-00000000700c'')'), 'ok');
reset role;
select expect_text('guest_pass followed', (select occurrence_id::text from guest_passes where id='9eb00000-0000-0000-0000-aaaa00000006'), '9eb00000-0000-0000-0000-00000000700c');

\echo '--- 3. exactly one booking_rebooked, zero cancel/confirm, no infraction (for M2) ---'
select expect_num('one booking_rebooked for M2',
  (select count(*) from notifications where member_id='9eb00000-0000-0000-0000-0000000000b2' and template_key='booking_rebooked'), 1);
select expect_num('zero class_cancelled for M2',
  (select count(*) from notifications where member_id='9eb00000-0000-0000-0000-0000000000b2' and template_key='class_cancelled'), 0);
select expect_num('zero booking_confirmed for M2',
  (select count(*) from notifications where member_id='9eb00000-0000-0000-0000-0000000000b2' and template_key='booking_confirmed'), 0);
select expect_num('no infraction for M2',
  (select count(*) from member_infractions where member_id='9eb00000-0000-0000-0000-0000000000b2'), 0);
-- the booking_rebooked payload carries the new class + when + studio
select expect_text('rebooked payload class_name',
  (select payload->>'class_name' from notifications where member_id='9eb00000-0000-0000-0000-0000000000b2' and template_key='booking_rebooked'), 'Reformer Burn');

\echo '--- 4. old seat released, waitlist promoted ---'
select expect_text('move-out from a full class', as_reason('9eb00000-0000-0000-0000-0000000000f1',
  'select rebook_member(''9eb00000-0000-0000-0000-0000000b0009'',''9eb00000-0000-0000-0000-00000000700c'')'), 'ok');
reset role;
select expect_num('a waitlist offer was made on SRC_FULL',
  (select count(*) from waitlist_offers where occurrence_id='9eb00000-0000-0000-0000-00000005f011' and outcome is null), 1);

\echo '--- 5. per-email switch suppresses booking_rebooked ---'
update studio_settings set disabled_templates = array['booking_rebooked']::text[] where studio_id='9eb00000-0000-0000-0000-0000000000a0';
select expect_text('desk-unpaid moves (switch on)', as_reason('9eb00000-0000-0000-0000-0000000000f1',
  'select rebook_member(''9eb00000-0000-0000-0000-0000000b0004'',''9eb00000-0000-0000-0000-00000000700c'')'), 'ok');
reset role;
select expect_text('desk-unpaid still drop_in', (select payment_source::text from bookings where id='9eb00000-0000-0000-0000-0000000b0004'), 'drop_in');
select expect_num('no booking_rebooked for M4 (switch suppressed)',
  (select count(*) from notifications where member_id='9eb00000-0000-0000-0000-0000000000b4' and template_key='booking_rebooked'), 0);

\echo '--- 6. anon THIRTEEN ---'
select expect_num('anon surface is thirteen',
  (select count(*) from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
    where ns.nspname='public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not in ('login','as_reason','expect_text','expect_true','expect_num')), 13);

reset role;
drop function login(text); drop function as_reason(text,text);
drop function expect_text(text,text,text); drop function expect_true(text,boolean); drop function expect_num(text,bigint,bigint);
\echo 'rebook_test: all assertions passed'
