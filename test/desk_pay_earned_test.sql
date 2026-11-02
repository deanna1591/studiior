-- =============================================================================
-- Decision 73 (c) — pay at the desk is EARNED. Migration 20260833130000.
-- =============================================================================
-- UUID space d73c (hex), checked free. Run after `supabase db reset`.
--
-- A desk (unpaid drop-in) booking is offered only while the member has no
-- no-show and no late cancellation on a desk booking; after one, book_class
-- refuses it (desk_pay_blocked) and they pay online. 'first_visit_only' mode
-- caps it at one desk booking ever. Staff restore it (audited). Instructor
-- walk-ins are unaffected.
--
-- RED proof: on the pre-73c schema members.desk_pay_blocked_at and
-- studio_settings.desk_pay_mode do not exist and book_class has no
-- desk_pay_blocked branch, so the block / refusal / restore cases fail.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to warning;

create or replace function login(uid text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', uid, true); set local role authenticated; end $$;
create or replace function expect_text(label text, actual text, want text) returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'BAD  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if; end $$;
create or replace function expect_true(label text, actual boolean) returns void language plpgsql as $$
begin if actual then raise notice 'PASS  %', label; else raise exception 'BAD  %  expected true', label; end if; end $$;
create or replace function expect_null(label text, actual anyelement) returns void language plpgsql as $$
begin if actual is null then raise notice 'PASS  %', label; else raise exception 'BAD  %  expected null, got %', label, actual::text; end if; end $$;
create or replace function expect_num(label text, actual bigint, want bigint) returns void language plpgsql as $$
begin if actual = want then raise notice 'PASS  %  (got %)', label, actual; else raise exception 'BAD  %  expected %, got %', label, want, actual; end if; end $$;
create or replace function as_json(uid text, sql text) returns jsonb language plpgsql as $$
declare r jsonb; begin perform set_config('request.jwt.claim.sub', uid, true); set local role authenticated;
  begin execute sql into r; return r; exception when others then return jsonb_build_object('err', sqlstate, 'msg', sqlerrm); end; end $$;

reset role;

-- ---- Studios: SA earned, SB first_visit_only --------------------------------
insert into studios (id, name, slug, timezone, currency, status) values
  ('d73c0000-0000-0000-0000-0000000000a0','Alpha','d73c-sa','UTC','PHP','active'),
  ('d73c0000-0000-0000-0000-0000000000b0','Bravo','d73c-sb','UTC','PHP','active');
insert into studio_settings (studio_id, desk_pay_mode, require_waiver, free_first_class_enabled, cancellation_cutoff_minutes) values
  ('d73c0000-0000-0000-0000-0000000000a0','earned', false, false, 720),
  ('d73c0000-0000-0000-0000-0000000000b0','first_visit_only', false, false, 720);
insert into locations (id, studio_id, name, timezone, is_primary) values
  ('d73c0000-0000-0000-0000-00000000a0a0','d73c0000-0000-0000-0000-0000000000a0','Main','UTC',true),
  ('d73c0000-0000-0000-0000-00000000b0b0','d73c0000-0000-0000-0000-0000000000b0','Main','UTC',true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('d73c0000-0000-0000-0000-00000000aa01','d73c0000-0000-0000-0000-0000000000a0','d73c0000-0000-0000-0000-00000000a0a0','R',20),
  ('d73c0000-0000-0000-0000-00000000bb02','d73c0000-0000-0000-0000-0000000000b0','d73c0000-0000-0000-0000-00000000b0b0','R',20);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('d73c0000-0000-0000-0000-00000000c0a1','d73c0000-0000-0000-0000-0000000000a0','Flow',50,20),
  ('d73c0000-0000-0000-0000-00000000c0b2','d73c0000-0000-0000-0000-0000000000b0','Flow',50,20);

-- an instructor with a login on SA (for add_walk_in)
insert into auth.users (id) values ('d73c0000-0000-0000-0000-000000005001');
insert into profiles (id, email, full_name) values ('d73c0000-0000-0000-0000-000000005001','d73c-ins@example.com','Ina Structor');
insert into studio_staff (id, studio_id, user_id, email, role, status) values
  ('d73c0000-0000-0000-0000-00000000ff01','d73c0000-0000-0000-0000-0000000000a0','d73c0000-0000-0000-0000-000000005001','d73c-ins@example.com','instructor','active');
insert into instructors (id, studio_id, staff_id, display_name, status) values
  ('d73c0000-0000-0000-0000-0000000000e1','d73c0000-0000-0000-0000-0000000000a0','d73c0000-0000-0000-0000-00000000ff01','Ina','active');

-- Members with logins
insert into auth.users (id) values
  ('d73c0000-0000-0000-0000-000000001001'),('d73c0000-0000-0000-0000-000000001002'),
  ('d73c0000-0000-0000-0000-000000001003'),('d73c0000-0000-0000-0000-000000001004'),
  ('d73c0000-0000-0000-0000-000000001005'),('d73c0000-0000-0000-0000-000000001006'),
  ('d73c0000-0000-0000-0000-000000002001'),('d73c0000-0000-0000-0000-000000002002');
insert into profiles (id, email, full_name) values
  ('d73c0000-0000-0000-0000-000000001001','m1@a.co','M1'),('d73c0000-0000-0000-0000-000000001002','m2@a.co','M2'),
  ('d73c0000-0000-0000-0000-000000001003','m3@a.co','M3'),('d73c0000-0000-0000-0000-000000001004','m4@a.co','M4'),
  ('d73c0000-0000-0000-0000-000000001005','m5@a.co','M5'),('d73c0000-0000-0000-0000-000000001006','m6@a.co','M6'),
  ('d73c0000-0000-0000-0000-000000002001','n1@b.co','N1'),('d73c0000-0000-0000-0000-000000002002','n2@b.co','N2');
insert into members (id, studio_id, user_id, first_name, last_name, email, status, joined_on) values
  ('d73c0000-0000-0000-0000-00000000dd01','d73c0000-0000-0000-0000-0000000000a0','d73c0000-0000-0000-0000-000000001001','M','One','m1@a.co','active', now()),
  ('d73c0000-0000-0000-0000-00000000dd02','d73c0000-0000-0000-0000-0000000000a0','d73c0000-0000-0000-0000-000000001002','M','Two','m2@a.co','active', now()),
  ('d73c0000-0000-0000-0000-00000000dd03','d73c0000-0000-0000-0000-0000000000a0','d73c0000-0000-0000-0000-000000001003','M','Three','m3@a.co','active', now()),
  ('d73c0000-0000-0000-0000-00000000dd04','d73c0000-0000-0000-0000-0000000000a0','d73c0000-0000-0000-0000-000000001004','M','Four','m4@a.co','active', now()),
  ('d73c0000-0000-0000-0000-00000000dd05','d73c0000-0000-0000-0000-0000000000a0','d73c0000-0000-0000-0000-000000001005','M','Five','m5@a.co','active', now()),
  ('d73c0000-0000-0000-0000-00000000dd06','d73c0000-0000-0000-0000-0000000000a0','d73c0000-0000-0000-0000-000000001006','M','Six','m6@a.co','active', now()),
  ('d73c0000-0000-0000-0000-00000000dd11','d73c0000-0000-0000-0000-0000000000b0','d73c0000-0000-0000-0000-000000002001','N','One','n1@b.co','active', now()),
  ('d73c0000-0000-0000-0000-00000000dd12','d73c0000-0000-0000-0000-0000000000b0','d73c0000-0000-0000-0000-000000002002','N','Two','n2@b.co','active', now());

-- a pack plan + a membership with a credit for M6 (the online path while blocked)
insert into membership_plans (id, studio_id, name, type, visibility, status, price_cents, currency, credits, validity_days) values
  ('d73c0000-0000-0000-0000-00000000f001','d73c0000-0000-0000-0000-0000000000a0','5 pack','class_pack','public','active',100000,'PHP',5,90);
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on, expires_on, credits_remaining) values
  ('d73c0000-0000-0000-0000-00000000f106','d73c0000-0000-0000-0000-0000000000a0','d73c0000-0000-0000-0000-00000000dd06','d73c0000-0000-0000-0000-00000000f001','active',100000,'PHP', now()::date, (now()+interval '60 day')::date, 5);

-- Occurrences: c1/c3 far-future on SA (in-time + restore rebook); c2 moved near (late);
-- cb on SB; cd today (add_walk_in).
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, starts_at, ends_at, capacity, status, staffing, name) values
  ('d73c0000-0000-0000-0000-0000000000c1','d73c0000-0000-0000-0000-0000000000a0','d73c0000-0000-0000-0000-00000000a0a0','d73c0000-0000-0000-0000-00000000c0a1','d73c0000-0000-0000-0000-00000000aa01',null, now()+interval '3 day', now()+interval '3 day'+interval '50 min', 20,'scheduled','open','Flow'),
  ('d73c0000-0000-0000-0000-0000000000c2','d73c0000-0000-0000-0000-0000000000a0','d73c0000-0000-0000-0000-00000000a0a0','d73c0000-0000-0000-0000-00000000c0a1','d73c0000-0000-0000-0000-00000000aa01',null, now()+interval '5 day', now()+interval '5 day'+interval '50 min', 20,'scheduled','open','Flow'),
  ('d73c0000-0000-0000-0000-0000000000c3','d73c0000-0000-0000-0000-0000000000a0','d73c0000-0000-0000-0000-00000000a0a0','d73c0000-0000-0000-0000-00000000c0a1','d73c0000-0000-0000-0000-00000000aa01',null, now()+interval '6 day', now()+interval '6 day'+interval '50 min', 20,'scheduled','open','Flow'),
  ('d73c0000-0000-0000-0000-0000000000cb','d73c0000-0000-0000-0000-0000000000b0','d73c0000-0000-0000-0000-00000000b0b0','d73c0000-0000-0000-0000-00000000c0b2','d73c0000-0000-0000-0000-00000000bb02',null, now()+interval '4 day', now()+interval '4 day'+interval '50 min', 20,'scheduled','open','Flow'),
  ('d73c0000-0000-0000-0000-0000000000cc','d73c0000-0000-0000-0000-0000000000b0','d73c0000-0000-0000-0000-00000000b0b0','d73c0000-0000-0000-0000-00000000c0b2','d73c0000-0000-0000-0000-00000000bb02',null, now()+interval '5 day', now()+interval '5 day'+interval '50 min', 20,'scheduled','open','Flow'),
  ('d73c0000-0000-0000-0000-0000000000cd','d73c0000-0000-0000-0000-0000000000a0','d73c0000-0000-0000-0000-00000000a0a0','d73c0000-0000-0000-0000-00000000c0a1','d73c0000-0000-0000-0000-00000000aa01','d73c0000-0000-0000-0000-0000000000e1', date_trunc('day',now())+interval '9 h', date_trunc('day',now())+interval '9 h 50 min', 20,'scheduled','assigned','Flow');

-- Helper: a direct desk (unpaid drop-in) booking.
create or replace function mk_desk_booking(bid text, mid text, occ text) returns void language plpgsql as $$
begin insert into bookings (id, studio_id, member_id, occurrence_id, status, payment_source, booked_at)
  values (bid::uuid,'d73c0000-0000-0000-0000-0000000000a0', mid::uuid, occ::uuid,'booked','drop_in', now()); end $$;

\echo '--- 1. no-show on a desk seat blocks (reason no_show) ---'
select mk_desk_booking('d73c0000-0000-0000-0000-0000000bb001','d73c0000-0000-0000-0000-00000000dd01','d73c0000-0000-0000-0000-0000000000c1');
update bookings set status='no_show' where id='d73c0000-0000-0000-0000-0000000bb001';
select expect_true('no-show on a desk seat sets desk_pay_blocked_at',
  (select desk_pay_blocked_at is not null from members where id='d73c0000-0000-0000-0000-00000000dd01'));
select expect_text('...with reason no_show',
  (select desk_pay_blocked_reason from members where id='d73c0000-0000-0000-0000-00000000dd01'),'no_show');

\echo '--- 2. late cancel on a desk seat blocks (via the member — the guard exemption) ---'
select mk_desk_booking('d73c0000-0000-0000-0000-0000000bb002','d73c0000-0000-0000-0000-00000000dd02','d73c0000-0000-0000-0000-0000000000c2');
update class_occurrences set starts_at = now()+interval '30 min', ends_at = now()+interval '80 min'
  where id='d73c0000-0000-0000-0000-0000000000c2';   -- now within the 720-min cutoff
select expect_text('member late-cancels their own desk booking',
  (as_json('d73c0000-0000-0000-0000-000000001002',
    $$ select jsonb_build_object('s',(cancel_booking('d73c0000-0000-0000-0000-0000000bb002')).status::text) $$)->>'s'),
  'late_cancelled');
reset role;
select expect_true('late cancel on a desk seat sets desk_pay_blocked_at',
  (select desk_pay_blocked_at is not null from members where id='d73c0000-0000-0000-0000-00000000dd02'));
select expect_text('...with reason late_cancel',
  (select desk_pay_blocked_reason from members where id='d73c0000-0000-0000-0000-00000000dd02'),'late_cancel');

\echo '--- 3. an in-time cancel does NOT block ---'
select mk_desk_booking('d73c0000-0000-0000-0000-0000000bb003','d73c0000-0000-0000-0000-00000000dd03','d73c0000-0000-0000-0000-0000000000c1');
select expect_text('member cancels in time',
  (as_json('d73c0000-0000-0000-0000-000000001003',
    $$ select jsonb_build_object('s',(cancel_booking('d73c0000-0000-0000-0000-0000000bb003')).status::text) $$)->>'s'),
  'cancelled');
reset role;
select expect_null('in-time cancel leaves desk pay clean',
  (select desk_pay_blocked_at from members where id='d73c0000-0000-0000-0000-00000000dd03'));

\echo '--- 4. a no-show on a PAID seat does NOT block ---'
select mk_desk_booking('d73c0000-0000-0000-0000-0000000bb004','d73c0000-0000-0000-0000-00000000dd04','d73c0000-0000-0000-0000-0000000000c1');
insert into payments (id, studio_id, member_id, booking_id, amount_cents, currency, status, method, provider)
  values ('d73c0000-0000-0000-0000-0000000aa004','d73c0000-0000-0000-0000-0000000000a0','d73c0000-0000-0000-0000-00000000dd04','d73c0000-0000-0000-0000-0000000bb004',15000,'PHP','succeeded','cash','manual');
update bookings set status='no_show' where id='d73c0000-0000-0000-0000-0000000bb004';
select expect_null('no-show on a paid seat leaves desk pay clean',
  (select desk_pay_blocked_at from members where id='d73c0000-0000-0000-0000-00000000dd04'));

\echo '--- 5. a blocked member is refused a desk booking; online (credit) still works ---'
select expect_text('blocked M1 desk booking refused',
  (as_json('d73c0000-0000-0000-0000-000000001001',
    $$ select jsonb_build_object('r',(book_class('d73c0000-0000-0000-0000-0000000000c3','d73c0000-0000-0000-0000-00000000dd01','member')).failure_reason) $$)->>'r'),
  'desk_pay_blocked');
reset role;
update members set desk_pay_blocked_at = now(), desk_pay_blocked_reason='no_show' where id='d73c0000-0000-0000-0000-00000000dd06';
select expect_text('blocked M6 still books online with a credit',
  (as_json('d73c0000-0000-0000-0000-000000001006',
    $$ select jsonb_build_object('s',(book_class('d73c0000-0000-0000-0000-0000000000c1','d73c0000-0000-0000-0000-00000000dd06','member')).status::text) $$)->>'s'),
  'booked');
select expect_text('...and that seat is NOT a desk drop-in',
  (select payment_source::text from bookings where member_id='d73c0000-0000-0000-0000-00000000dd06' and occurrence_id='d73c0000-0000-0000-0000-0000000000c1'),
  'class_pack');

\echo '--- 6. restore clears the block; the next desk booking is accepted ---'
select expect_text('an instructor (not manager) cannot restore',
  as_json('d73c0000-0000-0000-0000-000000005001',
    $$ select restore_desk_pay('d73c0000-0000-0000-0000-00000000dd01') $$)->>'err', 'PT403');
reset role;
select expect_true('restore_desk_pay clears the block',
  (restore_desk_pay('d73c0000-0000-0000-0000-00000000dd01')->>'ok')::boolean);
select expect_null('block cleared', (select desk_pay_blocked_at from members where id='d73c0000-0000-0000-0000-00000000dd01'));
select expect_true('restore stamped', (select desk_pay_restored_at is not null from members where id='d73c0000-0000-0000-0000-00000000dd01'));
select expect_text('restored M1 now books a desk seat',
  (as_json('d73c0000-0000-0000-0000-000000001001',
    $$ select jsonb_build_object('s',(book_class('d73c0000-0000-0000-0000-0000000000c3','d73c0000-0000-0000-0000-00000000dd01','member')).status::text) $$)->>'s'),
  'booked');
reset role;
select expect_num('restore wrote an audit row',
  (select count(*) from audit_logs where action='member.desk_pay_restored' and entity_id='d73c0000-0000-0000-0000-00000000dd01'),1);

\echo '--- 7. first_visit_only refuses the SECOND ever desk booking ---'
reset role;
insert into bookings (id, studio_id, member_id, occurrence_id, status, payment_source, booked_at) values
  ('d73c0000-0000-0000-0000-0000000bb011','d73c0000-0000-0000-0000-0000000000b0','d73c0000-0000-0000-0000-00000000dd11','d73c0000-0000-0000-0000-0000000000cb','attended','drop_in', now()-interval '1 day');
select expect_text('first_visit_only: N1 second desk booking refused',
  (as_json('d73c0000-0000-0000-0000-000000002001',
    $$ select jsonb_build_object('r',(book_class('d73c0000-0000-0000-0000-0000000000cc','d73c0000-0000-0000-0000-00000000dd11','member')).failure_reason) $$)->>'r'),
  'desk_pay_blocked');
select expect_text('first_visit_only: N2 first desk booking accepted',
  (as_json('d73c0000-0000-0000-0000-000000002002',
    $$ select jsonb_build_object('s',(book_class('d73c0000-0000-0000-0000-0000000000cb','d73c0000-0000-0000-0000-00000000dd12','member')).status::text) $$)->>'s'),
  'booked');

\echo '--- 8. instructor add_walk_in still works for a blocked member ---'
reset role;
update members set desk_pay_blocked_at = now(), desk_pay_blocked_reason='no_show' where id='d73c0000-0000-0000-0000-00000000dd05';
select expect_text('add_walk_in books the blocked member (unaffected)',
  (as_json('d73c0000-0000-0000-0000-000000005001',
    $$ select jsonb_build_object('ok', ((add_walk_in('d73c0000-0000-0000-0000-0000000000cd','M Five','m5@a.co',null))->>'booking_id') is not null) $$)->>'ok'),
  'true');

\echo '--- 9. the Members chip + the class-page flag + anon THIRTEEN ---'
reset role;
select expect_true('overview desk_pay_blocked true for a blocked member',
  (select desk_pay_blocked from member_plan_overview('d73c0000-0000-0000-0000-0000000000a0') where id='d73c0000-0000-0000-0000-00000000dd05'));
select expect_true('overview desk_pay_blocked false for a clean member',
  (select not desk_pay_blocked from member_plan_overview('d73c0000-0000-0000-0000-0000000000a0') where id='d73c0000-0000-0000-0000-00000000dd03'));
select expect_num('anon surface is thirteen',
  (select count(*) from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
    where ns.nspname='public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not in ('login','as_json','expect_text','expect_true','expect_null','expect_num','mk_desk_booking')), 13);

reset role;
drop function login(text); drop function as_json(text,text); drop function mk_desk_booking(text,text,text);
drop function expect_text(text,text,text); drop function expect_true(text,boolean);
drop function expect_null(text,anyelement); drop function expect_num(text,bigint,bigint);
\echo 'desk_pay_earned_test: all assertions passed'
