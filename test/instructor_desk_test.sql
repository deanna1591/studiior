-- =============================================================================
-- Instructor desk — Decision 81a, migration 20260832970000
-- =============================================================================
-- UUID space 81de, checked free. Run after `supabase db reset`.
--
-- From the roster of a class they teach TODAY an instructor can add a walk-in,
-- take a desk payment, sell a plan and move a member's same-day booking in —
-- scoped by instructor_scope(), is_desk_up NOT widened, every desk payment
-- attributed to them. Cases (a)-(i) from the decision.
--
-- "Today" is derived from now() in the studio timezone; the one fragility is a
-- run within ~45 min of UTC midnight (the class is now()+45min). Acceptable,
-- like the other date-relative suites.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'BAD  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_eq(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'BAD  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin if actual then raise notice 'PASS  %', label; else raise exception 'BAD  %  expected true', label; end if; end $$;
-- run a jsonb-returning expression as a given user, trap errors to ERR:<state>
create or replace function as_json(uid text, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claim.sub', uid, true); set local role authenticated;
  begin execute sql into r; return r; exception when others then return jsonb_build_object('err', sqlstate, 'msg', sqlerrm); end;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('81de81de-0000-0000-0000-0000000000a1'),  -- owner
  ('81de81de-0000-0000-0000-0000000000d1'),  -- instructor D1 (teaches OCC)
  ('81de81de-0000-0000-0000-0000000000d2');  -- instructor D2 (teaches OCC_OTHER)
insert into profiles (id, email) select id, id::text||'@example.com' from auth.users where id::text like '81de81de%';

insert into studios (id, name, slug, timezone, currency, status) values
  ('81de81de-0000-0000-0000-000000000001','Desk Studio','81de-sd','UTC','PHP','active');
insert into studio_settings (studio_id, free_first_class_enabled, checkin_window_enforced, require_waiver, max_unpaid_bookings)
  values ('81de81de-0000-0000-0000-000000000001', true, false, false, 1);
insert into locations (id, studio_id, name, is_primary) values
  ('81de81de-0000-0000-0000-00000000000a','81de81de-0000-0000-0000-000000000001','Main',true);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('81de81de-0000-0000-0000-0000000aa0a1','81de81de-0000-0000-0000-000000000001','81de81de-0000-0000-0000-0000000000a1','81de-own@example.com','owner'),
  ('81de81de-0000-0000-0000-0000000aa0d1','81de81de-0000-0000-0000-000000000001','81de81de-0000-0000-0000-0000000000d1','81de-d1@example.com','instructor'),
  ('81de81de-0000-0000-0000-0000000aa0d2','81de81de-0000-0000-0000-000000000001','81de81de-0000-0000-0000-0000000000d2','81de-d2@example.com','instructor');
insert into instructors (id, studio_id, staff_id, display_name, status) values
  ('81de81de-0000-0000-0000-0000000d0001','81de81de-0000-0000-0000-000000000001','81de81de-0000-0000-0000-0000000aa0d1','Dee One','active'),
  ('81de81de-0000-0000-0000-0000000d0002','81de81de-0000-0000-0000-000000000001','81de81de-0000-0000-0000-0000000aa0d2','Dee Two','active');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('81de81de-0000-0000-0000-0000000b0001','81de81de-0000-0000-0000-000000000001','81de81de-0000-0000-0000-00000000000a','Studio A',10),
  ('81de81de-0000-0000-0000-0000000b0002','81de81de-0000-0000-0000-000000000001','81de81de-0000-0000-0000-00000000000a','Studio B',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('81de81de-0000-0000-0000-00000000cc01','81de81de-0000-0000-0000-000000000001','Reformer',50,8);

-- Plans: a public drop-in (for due_cents), a pack (case c), a sellable plan
-- (case g), and a staff-only plan ("not for sale here").
insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, validity_days, visibility, status) values
  ('81de81de-0000-0000-0000-00000000a0d0','81de81de-0000-0000-0000-000000000001','Single Drop-in','drop_in',15000,'PHP',1,30,'public','active'),
  ('81de81de-0000-0000-0000-00000000a0ca','81de81de-0000-0000-0000-000000000001','5-Class Pack','class_pack',500000,'PHP',5,90,'public','active'),
  ('81de81de-0000-0000-0000-00000000a05e','81de81de-0000-0000-0000-000000000001','10-Class Pack','class_pack',900000,'PHP',10,120,'public','active'),
  ('81de81de-0000-0000-0000-00000000a0ff','81de81de-0000-0000-0000-000000000001','Staff Comp','class_pack',0,'PHP',10,120,'staff_only','active');

-- Occurrences, all TODAY (now()+45min) except the tomorrow one.
insert into class_occurrences (id, studio_id, location_id, series_id, class_type_id, room_id, instructor_id, starts_at, ends_at, capacity, status, staffing, name) values
  ('81de81de-0000-0000-0000-0000000000c1','81de81de-0000-0000-0000-000000000001','81de81de-0000-0000-0000-00000000000a',null,'81de81de-0000-0000-0000-00000000cc01','81de81de-0000-0000-0000-0000000b0001','81de81de-0000-0000-0000-0000000d0001', now()+interval '45 min', now()+interval '95 min', 6, 'scheduled','assigned','Reformer'),
  ('81de81de-0000-0000-0000-0000000000c2','81de81de-0000-0000-0000-000000000001','81de81de-0000-0000-0000-00000000000a',null,'81de81de-0000-0000-0000-00000000cc01','81de81de-0000-0000-0000-0000000b0001','81de81de-0000-0000-0000-0000000d0001', now()+interval '210 min', now()+interval '260 min', 5, 'scheduled','assigned','Reformer'),
  ('81de81de-0000-0000-0000-00000000c0fc','81de81de-0000-0000-0000-000000000001','81de81de-0000-0000-0000-00000000000a',null,'81de81de-0000-0000-0000-00000000cc01','81de81de-0000-0000-0000-0000000b0001','81de81de-0000-0000-0000-0000000d0001', now()+interval '100 min', now()+interval '150 min', 1, 'scheduled','assigned','Reformer'),
  ('81de81de-0000-0000-0000-00000000c0c6','81de81de-0000-0000-0000-000000000001','81de81de-0000-0000-0000-00000000000a',null,'81de81de-0000-0000-0000-00000000cc01','81de81de-0000-0000-0000-0000000b0001','81de81de-0000-0000-0000-0000000d0001', now()+interval '155 min', now()+interval '205 min', 3, 'scheduled','assigned','Reformer'),
  ('81de81de-0000-0000-0000-00000000c0c7','81de81de-0000-0000-0000-000000000001','81de81de-0000-0000-0000-00000000000a',null,'81de81de-0000-0000-0000-00000000cc01','81de81de-0000-0000-0000-0000000b0001','81de81de-0000-0000-0000-0000000d0001', now()+interval '1 day', now()+interval '1 day 50 min', 3, 'scheduled','assigned','Reformer'),
  ('81de81de-0000-0000-0000-00000000c0c8','81de81de-0000-0000-0000-000000000001','81de81de-0000-0000-0000-00000000000a',null,'81de81de-0000-0000-0000-00000000cc01','81de81de-0000-0000-0000-0000000b0002','81de81de-0000-0000-0000-0000000d0002', now()+interval '45 min', now()+interval '95 min', 3, 'scheduled','assigned','Reformer');

-- Members: a pack holder, a plain one, one booked elsewhere today, one for the
-- full class. All existing members have a signed waiver so their check-in is not
-- blocked by Decision 35 (a new walk-in is a different case, asserted in (a)).
insert into members (id, studio_id, first_name, last_name, email, status, waiver_signed_at) values
  ('81de81de-0000-0000-0000-00000000ad01','81de81de-0000-0000-0000-000000000001','Pat','Pack','pat.pack@example.com','active', now()),
  ('81de81de-0000-0000-0000-00000000ad02','81de81de-0000-0000-0000-000000000001','Plain','Jane','plain.jane@example.com','active', now()),
  ('81de81de-0000-0000-0000-00000000ad03','81de81de-0000-0000-0000-000000000001','Elle','Where','elle.where@example.com','active', now()),
  ('81de81de-0000-0000-0000-00000000ad04','81de81de-0000-0000-0000-000000000001','Fill','Er','fill.er@example.com','active', now());

-- A 5-class pack membership for the pack holder (5 credits).
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, credits_remaining, starts_on, expires_on) values
  ('81de81de-0000-0000-0000-00000000e501','81de81de-0000-0000-0000-000000000001','81de81de-0000-0000-0000-00000000ad01','81de81de-0000-0000-0000-00000000a0ca','active',500000,'PHP',5, current_date, current_date+90);

-- A past class (yesterday) with attended bookings for Pat and Jane, so they are
-- not first-timers — otherwise a fresh member with the free-first switch on gets
-- a FREE seat (case a), and (b)/(c) need the drop-in / plan branches.
insert into class_occurrences (id, studio_id, location_id, series_id, class_type_id, room_id, instructor_id, starts_at, ends_at, capacity, status, staffing, name) values
  ('81de81de-0000-0000-0000-00000000c0a0','81de81de-0000-0000-0000-000000000001','81de81de-0000-0000-0000-00000000000a',null,'81de81de-0000-0000-0000-00000000cc01','81de81de-0000-0000-0000-0000000b0001','81de81de-0000-0000-0000-0000000d0001', now()-interval '1 day', now()-interval '1 day' + interval '50 min', 5, 'scheduled','assigned','Reformer');
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source) values
  ('81de81de-0000-0000-0000-00000000b0a1','81de81de-0000-0000-0000-000000000001','81de81de-0000-0000-0000-00000000c0a0','81de81de-0000-0000-0000-00000000ad01','attended','member','drop_in'),
  ('81de81de-0000-0000-0000-00000000b0a2','81de81de-0000-0000-0000-000000000001','81de81de-0000-0000-0000-00000000c0a0','81de81de-0000-0000-0000-00000000ad02','attended','member','drop_in');

-- Elle is booked into OCC2 today (drop-in) — for "booked elsewhere today" + move.
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source) values
  ('81de81de-0000-0000-0000-00000000b0e1','81de81de-0000-0000-0000-000000000001','81de81de-0000-0000-0000-0000000000c2','81de81de-0000-0000-0000-00000000ad03','booked','member','drop_in');
update class_occurrences set booked_count = 1 where id = '81de81de-0000-0000-0000-0000000000c2';
-- Fill the full class (capacity 1).
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source) values
  ('81de81de-0000-0000-0000-00000000b0f1','81de81de-0000-0000-0000-000000000001','81de81de-0000-0000-0000-00000000c0fc','81de81de-0000-0000-0000-00000000ad04','booked','member','drop_in');
update class_occurrences set booked_count = 1 where id = '81de81de-0000-0000-0000-00000000c0fc';

-- Case (g) needs a BOOKED (not yet checked-in) unpaid drop-in so the Decision
-- 73b apply-on-activation path (apply_plan_to_unpaid, which targets status
-- 'booked') can settle it from the plan. A desk-added walk-in is checked in at
-- once (attended), so this seat is inserted directly, booked, waiver signed.
insert into members (id, studio_id, first_name, last_name, email, status, waiver_signed_at) values
  ('81de81de-0000-0000-0000-00000000ad05','81de81de-0000-0000-0000-000000000001','Gail','Guest','gail.guest@example.com','active', now());
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source) values
  ('81de81de-0000-0000-0000-00000000b051','81de81de-0000-0000-0000-000000000001','81de81de-0000-0000-0000-0000000000c1','81de81de-0000-0000-0000-00000000ad05','booked','member','drop_in');
update class_occurrences set booked_count = 1 where id = '81de81de-0000-0000-0000-0000000000c1';

-- clear any seed-less notification noise for clean counts
delete from notifications where studio_id = '81de81de-0000-0000-0000-000000000001';

\echo '--- (a) new email, eligible, class open -> comp free-first seat, token, one walk_in_welcome ---'
do $$
declare r jsonb; v_bk uuid; v_mid uuid;
begin
  r := as_json('81de81de-0000-0000-0000-0000000000d1',
    $q$ select add_walk_in('81de81de-0000-0000-0000-0000000000c1','Wanda Walkin','wanda.walkin@example.com','09170000001') $q$);
  perform set_config('request.jwt.claim.sub','',false); reset role;
  perform expect_true('(a) ok', (r->>'ok')::boolean);
  perform expect_eq('(a) seat=free_first', r->>'seat', 'free_first');
  perform expect_true('(a) new_member', (r->>'new_member')::boolean);
  v_bk := (r->>'booking_id')::uuid; v_mid := (r->>'member_id')::uuid;
  perform expect_eq('(a) booking comp', (select payment_source::text from bookings where id=v_bk), 'comp');
  perform expect_true('(a) non-provisional', (select not provisional from bookings where id=v_bk));
  perform expect_true('(a) confirmed_at set', (select confirmed_at is not null from bookings where id=v_bk));
  perform expect_num('(a) host-null guest pass', (select count(*) from guest_passes where guest_booking_id=v_bk and host_member_id is null), 1);
  perform expect_true('(a) member unclaimed (user_id null)', (select user_id is null from members where id=v_mid));
  perform expect_num('(a) invite token minted', (select count(*) from member_invites where member_id=v_mid and accepted_at is null), 1);
  perform expect_num('(a) exactly one walk_in_welcome', (select count(*) from notifications where member_id=v_mid and template_key='walk_in_welcome'), 1);
  perform expect_num('(a) zero booking_confirmed', (select count(*) from notifications where member_id=v_mid and template_key in ('booking_confirmed','free_booking_confirmed')), 0);
  -- Decision 35: a brand-new walk-in has not signed, so the free-first seat is
  -- booked but check-in is deferred (the guest-waiver gate). checked_in=false.
  perform expect_true('(a) check-in deferred (waiver)', (r->>'checked_in')::boolean is false);
end $$;

\echo '--- (b) existing member, not eligible, no plan -> unpaid drop-in, checked in, due = live price ---'
do $$
declare r jsonb; v_bk uuid;
begin
  r := as_json('81de81de-0000-0000-0000-0000000000d1',
    $q$ select add_walk_in('81de81de-0000-0000-0000-0000000000c1','Plain Jane','plain.jane@example.com',null) $q$);
  perform set_config('request.jwt.claim.sub','',false); reset role;
  perform expect_eq('(b) seat=drop_in', r->>'seat', 'drop_in');
  perform expect_true('(b) not new_member', (r->>'new_member')::boolean is false);
  perform expect_num('(b) due_cents = live drop-in price', (r->>'due_cents')::bigint, 15000);
  v_bk := (r->>'booking_id')::uuid;
  perform expect_eq('(b) checked in (attended)', (select status::text from bookings where id=v_bk), 'attended');
  perform expect_num('(b) one booking_confirmed', (select count(*) from notifications where member_id='81de81de-0000-0000-0000-00000000ad02' and template_key='booking_confirmed'), 1);
  perform expect_num('(b) zero walk_in_welcome (existing member)', (select count(*) from notifications where member_id='81de81de-0000-0000-0000-00000000ad02' and template_key='walk_in_welcome'), 0);
end $$;

\echo '--- (c) existing member with a pack -> plan seat, one credit drawn ---'
do $$
declare r jsonb; v_bk uuid;
begin
  r := as_json('81de81de-0000-0000-0000-0000000000d1',
    $q$ select add_walk_in('81de81de-0000-0000-0000-0000000000c1','Pat Pack','pat.pack@example.com',null) $q$);
  perform set_config('request.jwt.claim.sub','',false); reset role;
  perform expect_eq('(c) seat=plan', r->>'seat', 'plan');
  v_bk := (r->>'booking_id')::uuid;
  perform expect_eq('(c) payment_source class_pack', (select payment_source::text from bookings where id=v_bk), 'class_pack');
  perform expect_num('(c) credits 5 -> 4', (select credits_remaining from memberships where id='81de81de-0000-0000-0000-00000000e501'), 4);
  perform expect_num('(c) one booking consume ledger row', (select count(*) from credit_ledger where booking_id=v_bk and delta=-1 and reason='booking'), 1);
end $$;

\echo '--- (d) full class -> class is full with up to three alternatives that have seats ---'
do $$
declare r jsonb;
begin
  r := as_json('81de81de-0000-0000-0000-0000000000d1',
    $q$ select add_walk_in('81de81de-0000-0000-0000-00000000c0fc','New Full','new.full@example.com',null) $q$);
  perform set_config('request.jwt.claim.sub','',false); reset role;
  perform expect_eq('(d) reason class is full', r->>'reason', 'class is full');
  perform expect_true('(d) alternatives listed', jsonb_array_length(r->'alternatives') between 1 and 3);
  perform expect_true('(d) every alternative has a free seat', not exists (
    select 1 from jsonb_array_elements(r->'alternatives') a where (a->>'seats_left')::int < 1));
end $$;

\echo '--- (e) booked elsewhere today -> reason + booking id; then move succeeds; tomorrow refused ---'
do $$
declare r jsonb; v_mv jsonb;
begin
  r := as_json('81de81de-0000-0000-0000-0000000000d1',
    $q$ select add_walk_in('81de81de-0000-0000-0000-0000000000c1','Elle Where','elle.where@example.com',null) $q$);
  perform set_config('request.jwt.claim.sub','',false); reset role;
  perform expect_eq('(e) reason booked elsewhere today', r->>'reason', 'booked elsewhere today');
  perform expect_eq('(e) carries the other booking id', r->>'booking_id', '81de81de-0000-0000-0000-00000000b0e1');

  -- Move Elle's OCC2 booking into OCC1 (free seat). Keeps drop_in, checks in,
  -- source OCC2 seat opens to the waitlist (none here), audit row written.
  v_mv := as_json('81de81de-0000-0000-0000-0000000000d1',
    $q$ select move_booking_here('81de81de-0000-0000-0000-00000000b0e1','81de81de-0000-0000-0000-0000000000c1') $q$);
  perform set_config('request.jwt.claim.sub','',false); reset role;
  perform expect_true('(e) move ok', (v_mv->>'ok')::boolean);
  perform expect_eq('(e) booking now in OCC1', (select occurrence_id::text from bookings where id='81de81de-0000-0000-0000-00000000b0e1'), '81de81de-0000-0000-0000-0000000000c1');
  perform expect_eq('(e) payment_source unchanged (drop_in)', (select payment_source::text from bookings where id='81de81de-0000-0000-0000-00000000b0e1'), 'drop_in');
  perform expect_eq('(e) checked in', (select status::text from bookings where id='81de81de-0000-0000-0000-00000000b0e1'), 'attended');
  perform expect_num('(e) audit row written', (select count(*) from audit_logs where action='booking.moved_by_staff' and entity_id='81de81de-0000-0000-0000-00000000b0e1'), 1);
  perform expect_num('(e) OCC2 booked_count back to 0', (select booked_count from class_occurrences where id='81de81de-0000-0000-0000-0000000000c2'), 0);
end $$;

\echo '--- (e2) a second move into a full target -> class is full; a tomorrow booking -> not today ---'
do $$
declare r jsonb;
begin
  -- Pat (pack) booked OCC_TARGET today; fill OCC_TARGET to capacity, then a move in is full.
  update class_occurrences set capacity = 1, booked_count = 1 where id = '81de81de-0000-0000-0000-00000000c0c6';
  insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source)
  values ('81de81de-0000-0000-0000-00000000b0d6','81de81de-0000-0000-0000-000000000001','81de81de-0000-0000-0000-00000000c0c6','81de81de-0000-0000-0000-00000000ad04','booked','member','drop_in')
  on conflict do nothing;
  -- a live booking today for Plain Jane in OCC1 (she was added in b) — move to full OCC_TARGET
  r := as_json('81de81de-0000-0000-0000-0000000000d1',
    $q$ select move_booking_here((select id from bookings where member_id='81de81de-0000-0000-0000-00000000ad02' and occurrence_id='81de81de-0000-0000-0000-0000000000c1' limit 1),'81de81de-0000-0000-0000-00000000c0c6') $q$);
  perform set_config('request.jwt.claim.sub','',false); reset role;
  perform expect_eq('(e2) move to full target -> class is full', r->>'reason', 'class is full');

  -- a booking for TOMORROW cannot be moved into today's class
  insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source)
  values ('81de81de-0000-0000-0000-00000000b0d7','81de81de-0000-0000-0000-000000000001','81de81de-0000-0000-0000-00000000c0c7','81de81de-0000-0000-0000-00000000ad03','booked','member','drop_in');
  r := as_json('81de81de-0000-0000-0000-0000000000d1',
    $q$ select move_booking_here('81de81de-0000-0000-0000-00000000b0d7','81de81de-0000-0000-0000-00000000c0c6') $q$);
  perform set_config('request.jwt.claim.sub','',false); reset role;
  perform expect_eq('(e2) tomorrow booking -> that booking is not today', r->>'reason', 'that booking is not today');
end $$;

\echo '--- (f) record_desk_dropin_paid: payment with recorded_by; settled; repeat refused; bad method refused ---'
do $$
declare r jsonb; v_bk uuid;
begin
  -- Plain Jane's OCC1 drop-in from (b) is unpaid.
  v_bk := (select id from bookings where member_id='81de81de-0000-0000-0000-00000000ad02' and occurrence_id='81de81de-0000-0000-0000-0000000000c1' limit 1);
  r := as_json('81de81de-0000-0000-0000-0000000000d1',
    format($q$ select record_desk_dropin_paid('%s','gcash',15000,'ref-123') $q$, v_bk));
  perform set_config('request.jwt.claim.sub','',false); reset role;
  perform expect_true('(f) paid ok', (r->>'ok')::boolean);
  perform expect_num('(f) a succeeded payment on the booking, recorded_by the instructor',
    (select count(*) from payments where booking_id=v_bk and status='succeeded' and recorded_by='81de81de-0000-0000-0000-0000000000d1' and method='gcash' and reference='ref-123'), 1);
  -- second call: already recorded
  r := as_json('81de81de-0000-0000-0000-0000000000d1',
    format($q$ select record_desk_dropin_paid('%s','cash',15000,null) $q$, v_bk));
  perform set_config('request.jwt.claim.sub','',false); reset role;
  perform expect_eq('(f) repeat -> payment already recorded', r->>'reason', 'payment already recorded');
  -- bad method
  r := as_json('81de81de-0000-0000-0000-0000000000d1',
    $q$ select record_desk_dropin_paid((select id from bookings where member_id='81de81de-0000-0000-0000-00000000ad03' and occurrence_id='81de81de-0000-0000-0000-0000000000c1' limit 1),'bitcoin',15000,null) $q$);
  perform set_config('request.jwt.claim.sub','',false); reset role;
  perform expect_eq('(f) bad method refused', r->>'reason', 'unknown payment method');
end $$;

\echo '--- (g) sell_plan_at_desk use-for-today pays today''s drop-in; a not-for-sale plan refused ---'
do $$
declare r jsonb; v_bk uuid;
begin
  -- Gail (ad05) holds a BOOKED (not yet checked-in) unpaid drop-in in OCC1. Sell
  -- her the 10-pack, use it for today -> that booked drop-in is paid from the new
  -- plan (Decision 73b apply-on-activation, which settles the oldest BOOKED drop-in).
  v_bk := '81de81de-0000-0000-0000-00000000b051';
  r := as_json('81de81de-0000-0000-0000-0000000000d1',
    $q$ select sell_plan_at_desk('81de81de-0000-0000-0000-0000000000c1','81de81de-0000-0000-0000-00000000ad05','81de81de-0000-0000-0000-00000000a05e','card_terminal','sold-1',true) $q$);
  perform set_config('request.jwt.claim.sub','',false); reset role;
  perform expect_true('(g) sold ok', (r->>'ok')::boolean);
  perform expect_true('(g) membership created active', (select exists(select 1 from memberships where member_id='81de81de-0000-0000-0000-00000000ad05' and plan_id='81de81de-0000-0000-0000-00000000a05e' and status='active')));
  perform expect_true('(g) today''s seat drawn from the plan (no longer an unpaid drop_in)',
    (select payment_source::text from bookings where id=v_bk) in ('class_pack','membership'));
  -- a staff-only plan is not for sale here
  r := as_json('81de81de-0000-0000-0000-0000000000d1',
    $q$ select sell_plan_at_desk('81de81de-0000-0000-0000-0000000000c1','81de81de-0000-0000-0000-00000000ad01','81de81de-0000-0000-0000-00000000a0ff','cash',null,false) $q$);
  perform set_config('request.jwt.claim.sub','',false); reset role;
  perform expect_eq('(g) not-for-sale plan refused', r->>'reason', 'plan not for sale here');
end $$;

\echo '--- (h) instructor of a different class -> not your class; an owner passes every function ---'
do $$
declare r jsonb;
begin
  -- D2 teaches OCC_OTHER, not OCC1.
  perform expect_eq('(h) scope for D2 on OCC1', as_json('81de81de-0000-0000-0000-0000000000d2', $q$ select jsonb_build_object('x', instructor_scope('81de81de-0000-0000-0000-0000000000c1')) $q$)->>'x', 'not your class');
  perform set_config('request.jwt.claim.sub','',false); reset role;
  r := as_json('81de81de-0000-0000-0000-0000000000d2',
    $q$ select add_walk_in('81de81de-0000-0000-0000-0000000000c1','No Access','no.access@example.com',null) $q$);
  perform set_config('request.jwt.claim.sub','',false); reset role;
  perform expect_eq('(h) D2 add_walk_in on OCC1 refused', r->>'reason', 'not your class');
  -- an owner passes the scope on any class
  perform expect_eq('(h) owner scope null on OCC_OTHER', coalesce(as_json('81de81de-0000-0000-0000-0000000000a1', $q$ select jsonb_build_object('x', instructor_scope('81de81de-0000-0000-0000-00000000c0c8')) $q$)->>'x','null'), 'null');
  perform set_config('request.jwt.claim.sub','',false); reset role;
  -- owner can add a walk-in to OCC_OTHER (a class they do not teach)
  r := as_json('81de81de-0000-0000-0000-0000000000a1',
    $q$ select add_walk_in('81de81de-0000-0000-0000-00000000c0c8','Owner Add','owner.add@example.com',null) $q$);
  perform set_config('request.jwt.claim.sub','',false); reset role;
  perform expect_true('(h) owner add_walk_in ok', (r->>'ok')::boolean);
end $$;

\echo '--- (i) my_desk_payments shows exactly the payments that instructor recorded ---'
do $$
declare r jsonb; n bigint;
begin
  -- D1 recorded the gcash drop-in (f) and the card_terminal plan sale (g) = 2.
  select jsonb_array_length(as_json('81de81de-0000-0000-0000-0000000000d1',
    $q$ select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from my_desk_payments() x $q$)) into n;
  perform set_config('request.jwt.claim.sub','',false); reset role;
  perform expect_num('(i) D1 sees their 2 desk payments', n, 2);
  -- D2 recorded none
  select jsonb_array_length(as_json('81de81de-0000-0000-0000-0000000000d2',
    $q$ select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from my_desk_payments() x $q$)) into n;
  perform set_config('request.jwt.claim.sub','',false); reset role;
  perform expect_num('(i) D2 sees none', n, 0);
end $$;

\echo '--- anon surface stays THIRTEEN (excluding this suite''s own helpers) ---'
select expect_num('anon surface = 13',
  (select count(*) from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
    where ns.nspname='public' and has_function_privilege('anon',p.oid,'execute')
      and p.proname not in ('expect_num','expect_eq','expect_true','as_json')), 13);

\echo 'instructor_desk_test: all assertions passed.'
