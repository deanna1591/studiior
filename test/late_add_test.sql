-- =============================================================================
-- Decision 100 amendment (b) — late add from the roster.
-- Migration 20260833510000. UUID space 1a7e, checked free. After `supabase db reset`.
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

-- --- Fixtures ----------------------------------------------------------------
-- One Manila studio: free-first on, a reservation fee, require_waiver off and the
-- check-in window not enforced so a late-add check-in is never gated by them.
insert into auth.users (id) values
  ('1a7e0000-0000-0000-0000-0000000000a1'),   -- owner (desk-up)
  ('1a7e0000-0000-0000-0000-0000000000f1'),   -- front desk
  ('1a7e0000-0000-0000-0000-0000000000a4'),   -- the class's instructor (login)
  ('1a7e0000-0000-0000-0000-0000000000a5'),   -- another instructor (login)
  ('1a7e0000-0000-0000-0000-0000000000a6');   -- a member login (for "members cannot late add")
insert into profiles (id, email, full_name) values
  ('1a7e0000-0000-0000-0000-0000000000a1','own@1a7e.example','Olga Owner'),
  ('1a7e0000-0000-0000-0000-0000000000f1','fd@1a7e.example','Fred Desk'),
  ('1a7e0000-0000-0000-0000-0000000000a4','i1@1a7e.example','Ines Instructor'),
  ('1a7e0000-0000-0000-0000-0000000000a5','i2@1a7e.example','Ivan Other'),
  ('1a7e0000-0000-0000-0000-0000000000a6','m1@1a7e.example','Mara Member');

insert into studios (id, name, slug, timezone, currency, country, status) values
  ('1a7e0000-0000-0000-0000-000000000001','Late A','1a7e-a','Asia/Manila','PHP','PH','active');
insert into studio_settings (studio_id, free_first_class_enabled, free_first_peak_allowed,
                             free_first_reservation_fee_cents, checkin_window_enforced, require_waiver,
                             cancellation_cutoff_minutes, booking_window_days, max_unpaid_bookings,
                             desk_pay_mode, payment_grace_days, time_format) values
  ('1a7e0000-0000-0000-0000-000000000001', true, true, 50000, false, false, 720, 60, 5, 'earned', 7, '24h');
insert into locations (id, studio_id, name, is_primary) values
  ('1a7e0000-0000-0000-0000-00000000000a','1a7e0000-0000-0000-0000-000000000001','Main',true);

insert into studio_staff (id, studio_id, user_id, email, role, status) values
  ('1a7e0000-0000-0000-0000-0000000000e1','1a7e0000-0000-0000-0000-000000000001','1a7e0000-0000-0000-0000-0000000000a1','own@1a7e.example','owner','active'),
  ('1a7e0000-0000-0000-0000-0000000000e2','1a7e0000-0000-0000-0000-000000000001','1a7e0000-0000-0000-0000-0000000000f1','fd@1a7e.example','front_desk','active'),
  ('1a7e0000-0000-0000-0000-0000000000e3','1a7e0000-0000-0000-0000-000000000001','1a7e0000-0000-0000-0000-0000000000a4','i1@1a7e.example','instructor','active'),
  ('1a7e0000-0000-0000-0000-0000000000e4','1a7e0000-0000-0000-0000-000000000001','1a7e0000-0000-0000-0000-0000000000a5','i2@1a7e.example','instructor','active');
insert into instructors (id, studio_id, staff_id, display_name, status) values
  ('1a7e0000-0000-0000-0000-0000000000f4','1a7e0000-0000-0000-0000-000000000001','1a7e0000-0000-0000-0000-0000000000e3','Ines','active'),
  ('1a7e0000-0000-0000-0000-0000000000f5','1a7e0000-0000-0000-0000-000000000001','1a7e0000-0000-0000-0000-0000000000e4','Ivan','active');

insert into class_types (id, studio_id, name, default_capacity, duration_minutes, color, status) values
  ('1a7e0000-0000-0000-0000-0000000000c1','1a7e0000-0000-0000-0000-000000000001','Reformer',6,50,'#B85C38','active');

-- IP = in progress (started 10 min ago, ends in 40, taught by Ines);
-- EN = ended an hour ago;  FU = future (for the Decision 100 regression).
insert into class_occurrences (id, studio_id, location_id, class_type_id, instructor_id, name, capacity, starts_at, ends_at, status) values
  ('1a7e0000-0000-0000-0000-0000000000d1','1a7e0000-0000-0000-0000-000000000001','1a7e0000-0000-0000-0000-00000000000a','1a7e0000-0000-0000-0000-0000000000c1','1a7e0000-0000-0000-0000-0000000000f4','Reformer', 6, now()-interval '10 min', now()+interval '40 min','scheduled'),
  ('1a7e0000-0000-0000-0000-0000000000d2','1a7e0000-0000-0000-0000-000000000001','1a7e0000-0000-0000-0000-00000000000a','1a7e0000-0000-0000-0000-0000000000c1','1a7e0000-0000-0000-0000-0000000000f4','Reformer', 6, now()-interval '2 hours', now()-interval '70 min','scheduled'),
  ('1a7e0000-0000-0000-0000-0000000000d3','1a7e0000-0000-0000-0000-000000000001','1a7e0000-0000-0000-0000-00000000000a','1a7e0000-0000-0000-0000-0000000000c1','1a7e0000-0000-0000-0000-0000000000f4','Reformer', 6, now()+interval '2 days', now()+interval '2 days'+interval '50 min','scheduled');

-- Members: fresh free-first-eligible leads (signed waiver, no prior bookings).
insert into members (id, studio_id, user_id, first_name, last_name, email, status, waiver_signed_at) values
  ('1a7e0000-0000-0000-0000-0000000000b1','1a7e0000-0000-0000-0000-000000000001', null, 'Mara','One','mara1@1a7e.example','lead', now()-interval '1 day'),
  ('1a7e0000-0000-0000-0000-0000000000b2','1a7e0000-0000-0000-0000-000000000001', null, 'Nina','Two','nina2@1a7e.example','lead', now()-interval '1 day'),
  ('1a7e0000-0000-0000-0000-0000000000b3','1a7e0000-0000-0000-0000-000000000001', null, 'Owen','Three','owen3@1a7e.example','lead', now()-interval '1 day'),
  ('1a7e0000-0000-0000-0000-0000000000b4','1a7e0000-0000-0000-0000-000000000001', null, 'Pia','Four','pia4@1a7e.example','lead', now()-interval '1 day'),
  ('1a7e0000-0000-0000-0000-0000000000b5','1a7e0000-0000-0000-0000-000000000001','1a7e0000-0000-0000-0000-0000000000a6','Mara','Login','m1@1a7e.example','lead', now()-interval '1 day');

-- =============================================================================
-- 1. Desk late add (owner), free first, waiver ON by default: seat attended, fee
--    waived on the booking, NO free_reservation_due, audit booking.late_add.
-- =============================================================================
reset role; set role authenticated; select set_config('request.jwt.claim.sub','1a7e0000-0000-0000-0000-0000000000a1',false);  -- owner
select expect_true('desk late add into the in-progress class succeeds',
  (staff_book_member('1a7e0000-0000-0000-0000-0000000000b1','1a7e0000-0000-0000-0000-0000000000d1',
     '{"kind":"free_first"}'::jsonb, null) ->> 'ok')::boolean);
reset role;
select expect_true('...it is a late add',
  exists(select 1 from audit_logs where action='booking.late_add' and entity_id='1a7e0000-0000-0000-0000-0000000000b1'));
select expect_text('...the seat is attended',
  (select status::text from bookings where member_id='1a7e0000-0000-0000-0000-0000000000b1' and occurrence_id='1a7e0000-0000-0000-0000-0000000000d1'), 'attended');
select expect_true('...with a check-in (method staff)',
  exists(select 1 from check_ins ci join bookings b on b.id=ci.booking_id
          where b.member_id='1a7e0000-0000-0000-0000-0000000000b1' and ci.method='staff'));
select expect_true('...the reservation fee is waived on the booking',
  (select reservation_fee_waived from bookings where member_id='1a7e0000-0000-0000-0000-0000000000b1' and occurrence_id='1a7e0000-0000-0000-0000-0000000000d1'));
select expect_num('...and NO free_reservation_due queued',
  (select count(*) from notifications where member_id='1a7e0000-0000-0000-0000-0000000000b1' and template_key='free_reservation_due'), 0);

-- =============================================================================
-- 2. Instructor late add (the class's own instructor), free first, no switch:
--    fee DUE, ONE free_reservation_due with the end-of-day deadline, method
--    instructor. Then the dues sweep past the deadline KEEPS it (attended), not
--    released.
-- =============================================================================
reset role; set role authenticated; select set_config('request.jwt.claim.sub','1a7e0000-0000-0000-0000-0000000000a4',false);  -- Ines, the class instructor
select expect_true('the class instructor late-adds a member',
  (staff_book_member('1a7e0000-0000-0000-0000-0000000000b2','1a7e0000-0000-0000-0000-0000000000d1',
     '{"kind":"free_first"}'::jsonb, null) ->> 'ok')::boolean);
reset role;
select expect_text('...the seat is attended',
  (select status::text from bookings where member_id='1a7e0000-0000-0000-0000-0000000000b2' and occurrence_id='1a7e0000-0000-0000-0000-0000000000d1'), 'attended');
select expect_true('...checked in as instructor',
  exists(select 1 from check_ins ci join bookings b on b.id=ci.booking_id
          where b.member_id='1a7e0000-0000-0000-0000-0000000000b2' and ci.method='instructor'));
select expect_false('...the fee is NOT waived on the booking',
  (select reservation_fee_waived from bookings where member_id='1a7e0000-0000-0000-0000-0000000000b2' and occurrence_id='1a7e0000-0000-0000-0000-0000000000d1'));
select expect_num('...ONE free_reservation_due queued',
  (select count(*) from notifications where member_id='1a7e0000-0000-0000-0000-0000000000b2' and template_key='free_reservation_due'), 1);
select expect_text('...the deadline is the end of today',
  (select payload->>'deadline' from notifications where member_id='1a7e0000-0000-0000-0000-0000000000b2' and template_key='free_reservation_due'), 'the end of today');
-- Unpaid at the deadline: the sweep (tomorrow) does not release an attended seat.
select sweep_free_reservation_dues(now() + interval '1 day');
select expect_text('...past the deadline the attended seat is KEPT, not released',
  (select status::text from bookings where member_id='1a7e0000-0000-0000-0000-0000000000b2' and occurrence_id='1a7e0000-0000-0000-0000-0000000000d1'), 'attended');

-- =============================================================================
-- 3. Another instructor (not the class's) is refused PT403.
-- =============================================================================
reset role; set role authenticated; select set_config('request.jwt.claim.sub','1a7e0000-0000-0000-0000-0000000000a5',false);  -- Ivan, not this class
select expect_raise('another instructor cannot late add into this class', 'PT403',
  $$ select staff_book_member('1a7e0000-0000-0000-0000-0000000000b3','1a7e0000-0000-0000-0000-0000000000d1','{"kind":"free_first"}'::jsonb, null) $$);
reset role;
select expect_false('...and nothing was booked for that member',
  exists(select 1 from bookings where member_id='1a7e0000-0000-0000-0000-0000000000b3' and occurrence_id='1a7e0000-0000-0000-0000-0000000000d1'));

-- =============================================================================
-- 4. Members cannot late add: a member's own staff_book_member is PT403, and a
--    member booking the started class the normal way is class_in_past (not
--    class_ended) — the starts_at guard stands for members.
-- =============================================================================
reset role; set role authenticated; select set_config('request.jwt.claim.sub','1a7e0000-0000-0000-0000-0000000000a6',false);  -- a member login
select expect_raise('a member cannot call staff_book_member', 'PT403',
  $$ select staff_book_member('1a7e0000-0000-0000-0000-0000000000b5','1a7e0000-0000-0000-0000-0000000000d1','{"kind":"free_first"}'::jsonb, null) $$);
select expect_text('...a member booking a started class is class_in_past, never class_ended',
  (book_class('1a7e0000-0000-0000-0000-0000000000d1','1a7e0000-0000-0000-0000-0000000000b5','member',null,null,null)).failure_reason, 'class_in_past');
reset role;

-- =============================================================================
-- 5. After the class ends the add is refused class_ended.
-- =============================================================================
reset role; set role authenticated; select set_config('request.jwt.claim.sub','1a7e0000-0000-0000-0000-0000000000a1',false);  -- owner
select expect_text('after the class ends the late add is refused class_ended',
  staff_book_member('1a7e0000-0000-0000-0000-0000000000b3','1a7e0000-0000-0000-0000-0000000000d2','{"kind":"free_first"}'::jsonb, null) ->> 'reason', 'class_ended');
reset role;
select expect_false('...nothing was booked on the ended class',
  exists(select 1 from bookings where member_id='1a7e0000-0000-0000-0000-0000000000b3' and occurrence_id='1a7e0000-0000-0000-0000-0000000000d2'));

-- =============================================================================
-- 6. Desk late add with the waiver switch OFF: fee DUE (one free_reservation_due).
-- =============================================================================
reset role; set role authenticated; select set_config('request.jwt.claim.sub','1a7e0000-0000-0000-0000-0000000000a1',false);  -- owner
select expect_true('desk late add with waive_fee=false succeeds',
  (staff_book_member('1a7e0000-0000-0000-0000-0000000000b4','1a7e0000-0000-0000-0000-0000000000d1',
     '{"kind":"free_first","waive_fee":false}'::jsonb, null) ->> 'ok')::boolean);
reset role;
select expect_false('...the fee is not waived on the booking',
  (select reservation_fee_waived from bookings where member_id='1a7e0000-0000-0000-0000-0000000000b4' and occurrence_id='1a7e0000-0000-0000-0000-0000000000d1'));
select expect_num('...ONE free_reservation_due queued',
  (select count(*) from notifications where member_id='1a7e0000-0000-0000-0000-0000000000b4' and template_key='free_reservation_due'), 1);

-- =============================================================================
-- 7. The picker reports the late-add context; a FUTURE booking is unaffected
--    (Decision 100 regression): booked, not attended, audit booked_by_staff.
-- =============================================================================
reset role; set role authenticated; select set_config('request.jwt.claim.sub','1a7e0000-0000-0000-0000-0000000000a1',false);  -- owner
select expect_true('staff_booking_options flags the in-progress class as late_add',
  (staff_booking_options('1a7e0000-0000-0000-0000-0000000000b3','1a7e0000-0000-0000-0000-0000000000d1') ->> 'late_add')::boolean);
select expect_false('...and not ended',
  (staff_booking_options('1a7e0000-0000-0000-0000-0000000000b3','1a7e0000-0000-0000-0000-0000000000d1') ->> 'ended')::boolean);
select expect_false('...a future class is not a late add',
  (staff_booking_options('1a7e0000-0000-0000-0000-0000000000b3','1a7e0000-0000-0000-0000-0000000000d3') ->> 'late_add')::boolean);
-- The instructor may read the options for their class.
reset role; set role authenticated; select set_config('request.jwt.claim.sub','1a7e0000-0000-0000-0000-0000000000a4',false);
select expect_text('the class instructor sees method instructor in the options',
  staff_booking_options('1a7e0000-0000-0000-0000-0000000000b3','1a7e0000-0000-0000-0000-0000000000d1') ->> 'method', 'instructor');
-- Future booking: Decision 100 unchanged.
reset role; set role authenticated; select set_config('request.jwt.claim.sub','1a7e0000-0000-0000-0000-0000000000a1',false);  -- owner
select expect_true('a future booking still succeeds (Decision 100)',
  (staff_book_member('1a7e0000-0000-0000-0000-0000000000b3','1a7e0000-0000-0000-0000-0000000000d3','{"kind":"free_first"}'::jsonb, null) ->> 'ok')::boolean);
reset role;
select expect_text('...it is NOT attended (future class, no late add)',
  (select status::text from bookings where member_id='1a7e0000-0000-0000-0000-0000000000b3' and occurrence_id='1a7e0000-0000-0000-0000-0000000000d3'), 'booked');
select expect_true('...and the audit is booking.booked_by_staff, not late_add',
  exists(select 1 from audit_logs where action='booking.booked_by_staff' and entity_id='1a7e0000-0000-0000-0000-0000000000b3'
          and (after->>'booking_id')::uuid = (select id from bookings where member_id='1a7e0000-0000-0000-0000-0000000000b3' and occurrence_id='1a7e0000-0000-0000-0000-0000000000d3')));

-- =============================================================================
-- 8. Anon surface EXACTLY THIRTEEN (suite helpers excluded).
-- =============================================================================
select expect_num('anon surface EXACTLY THIRTEEN',
  (select count(*) from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
    where ns.nspname='public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not in ('expect_num','expect_text','expect_true','expect_false','expect_raise')), 13);

select 'late_add_test PASS' as result;
