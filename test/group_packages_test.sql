-- =============================================================================
-- Decision 76 (76a) — group packages (Barkada). UUID space: 6a0a.
--
-- Covers: desk activation creates a group_purchase + tagged payment (no
-- membership); book_group books host + existing-member + non-member leads
-- atomically; the guest's free-first is untouched (no guest_passes row); an
-- already-booked email is refused BY NAME and nothing is written (all-or-none);
-- class_full when seats run out writes nothing; class-type restriction; swap;
-- early vs late cancel (late never stamps the guests); expiry; host-or-staff
-- only; anon stays THIRTEEN; member_activity group lines.
-- =============================================================================
\set A   '''6a0a0000-0000-0000-0000-000000000001'''
\set CT  '''6a0a0000-0000-0000-0000-0000000000c1'''
\set CT2 '''6a0a0000-0000-0000-0000-0000000000c2'''
\set GP  '''6a0a0000-0000-0000-0000-0000000000f1'''
\set GR  '''6a0a0000-0000-0000-0000-0000000000f2'''
\set M1  '''6a0a0000-0000-0000-0000-00000000a001'''
\set M2  '''6a0a0000-0000-0000-0000-00000000a002'''
\set M3  '''6a0a0000-0000-0000-0000-00000000a003'''
\set MB  '''6a0a0000-0000-0000-0000-00000000a00b'''
\set MC  '''6a0a0000-0000-0000-0000-00000000a00c'''
\set O1  '''6a0a0000-0000-0000-0000-00000000e001'''
\set O2  '''6a0a0000-0000-0000-0000-00000000e002'''
\set O3  '''6a0a0000-0000-0000-0000-00000000e003'''
\set O4  '''6a0a0000-0000-0000-0000-00000000e004'''
\set O5  '''6a0a0000-0000-0000-0000-00000000e005'''
\set O6  '''6a0a0000-0000-0000-0000-00000000e006'''

create or replace function expect_true(label text, actual boolean) returns void language plpgsql as $$
begin if coalesce(actual,false) then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_num(label text, actual bigint, want bigint) returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (%)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_text(label text, actual text, want text) returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (%)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if; end $$;
create or replace function expect_raises(label text, sql text, code text) returns void language plpgsql as $$
begin execute sql; raise exception 'FAIL  %  expected %, nothing raised', label, code;
exception when others then
  if sqlstate = code then raise notice 'PASS  %  (%)', label, code;
  else raise exception 'FAIL  %  expected %, got % (%)', label, code, sqlstate, sqlerrm; end if; end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('6a0a0000-0000-0000-0000-0000000000a1'),  -- owner OA
  ('6a0a0000-0000-0000-0000-00000000a001'),  -- host M1
  ('6a0a0000-0000-0000-0000-00000000a002'),  -- member M2 (existing guest)
  ('6a0a0000-0000-0000-0000-00000000a003'),  -- member M3 (already booked)
  ('6a0a0000-0000-0000-0000-00000000a00b'),  -- host MB
  ('6a0a0000-0000-0000-0000-00000000a00c');  -- stranger MC
insert into profiles (id, email) values
  ('6a0a0000-0000-0000-0000-0000000000a1','6a0a-oa@example.com'),
  ('6a0a0000-0000-0000-0000-00000000a001','g-host@example.com'),
  ('6a0a0000-0000-0000-0000-00000000a002','g-m2@example.com'),
  ('6a0a0000-0000-0000-0000-00000000a003','g-m3@example.com'),
  ('6a0a0000-0000-0000-0000-00000000a00b','g-hostb@example.com'),
  ('6a0a0000-0000-0000-0000-00000000a00c','g-mc@example.com');

insert into studios (id, name, slug, timezone, currency, status) values
  (:A,'Barkada Studio','barkada','Asia/Manila','PHP','active');
-- A 12-hour cut-off, so a class 30 min out is a LATE cancellation.
insert into studio_settings (studio_id, cancellation_cutoff_minutes) values (:A, 720);
insert into studio_staff (id, studio_id, user_id, email, role, status) values
  ('6a0a0000-0000-0000-0000-0000000aa0a1',:A,'6a0a0000-0000-0000-0000-0000000000a1','6a0a-oa@example.com','owner','active');

insert into members (id, studio_id, first_name, last_name, email, status, user_id) values
  (:M1,:A,'Hugo','Host','g-host@example.com','active','6a0a0000-0000-0000-0000-00000000a001'),
  (:M2,:A,'Mina','Two','g-m2@example.com','active','6a0a0000-0000-0000-0000-00000000a002'),
  (:M3,:A,'Theo','Three','g-m3@example.com','active','6a0a0000-0000-0000-0000-00000000a003'),
  (:MB,:A,'Bebe','HostB','g-hostb@example.com','active','6a0a0000-0000-0000-0000-00000000a00b'),
  (:MC,:A,'Cass','Stranger','g-mc@example.com','active','6a0a0000-0000-0000-0000-00000000a00c');

insert into locations (id, studio_id, name) values
  ('6a0a0000-0000-0000-0000-00000000000c',:A,'Main');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('6a0a0000-0000-0000-0000-000000000b01',:A,'6a0a0000-0000-0000-0000-00000000000c','Studio A',20);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  (:CT ,:A,'Reformer',50,10),
  (:CT2,:A,'Mat',50,10);

-- Occurrences on distinct days (same room, no overlap). O5 is 30 min out.
insert into class_occurrences
  (id, studio_id, class_type_id, location_id, room_id, name, starts_at, ends_at, capacity, booked_count, status)
values
  (:O1,:A,:CT ,'6a0a0000-0000-0000-0000-00000000000c','6a0a0000-0000-0000-0000-000000000b01','Reformer',
   now()+interval '10 days', now()+interval '10 days'+interval '50 min', 10, 0, 'scheduled'),
  (:O2,:A,:CT ,'6a0a0000-0000-0000-0000-00000000000c','6a0a0000-0000-0000-0000-000000000b01','Reformer',
   now()+interval '11 days', now()+interval '11 days'+interval '50 min', 3, 0, 'scheduled'),
  (:O3,:A,:CT2,'6a0a0000-0000-0000-0000-00000000000c','6a0a0000-0000-0000-0000-000000000b01','Mat',
   now()+interval '12 days', now()+interval '12 days'+interval '50 min', 10, 0, 'scheduled'),
  (:O4,:A,:CT ,'6a0a0000-0000-0000-0000-00000000000c','6a0a0000-0000-0000-0000-000000000b01','Reformer',
   now()+interval '13 days', now()+interval '13 days'+interval '50 min', 10, 0, 'scheduled'),
  (:O5,:A,:CT ,'6a0a0000-0000-0000-0000-00000000000c','6a0a0000-0000-0000-0000-000000000b01','Reformer',
   now()+interval '30 min', now()+interval '80 min', 10, 0, 'scheduled'),
  (:O6,:A,:CT ,'6a0a0000-0000-0000-0000-00000000000c','6a0a0000-0000-0000-0000-000000000b01','Reformer',
   now()+interval '14 days', now()+interval '14 days'+interval '50 min', 10, 0, 'scheduled');

-- A group plan (3 seats) and a class-type-restricted group plan (2 seats, CT).
insert into membership_plans (id, studio_id, name, type, price_cents, currency, group_size, visibility, status) values
  (:GP,:A,'Barkada 3','group',300000,'PHP',3,'public','active');
insert into membership_plans (id, studio_id, name, type, price_cents, currency, group_size, restrictions, visibility, status) values
  (:GR,:A,'Barkada Reformer','group',250000,'PHP',2,
   jsonb_build_object('class_type_ids', jsonb_build_array('6a0a0000-0000-0000-0000-0000000000c1')),
   'public','active');

-- ids into GUCs so do-blocks / later statements can reach them.
select set_config('t.a',:A,false), set_config('t.m1',:M1,false), set_config('t.m2',:M2,false),
       set_config('t.mb',:MB,false), set_config('t.gp',:GP,false), set_config('t.gr',:GR,false),
       set_config('t.o1',:O1,false), set_config('t.o2',:O2,false), set_config('t.o3',:O3,false),
       set_config('t.o4',:O4,false), set_config('t.o5',:O5,false), set_config('t.o6',:O6,false);

-- =============================================================================
-- 1. DESK ACTIVATION — a group plan creates a group_purchase + tagged payment.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','6a0a0000-0000-0000-0000-0000000000a1',false);  -- OA
select set_config('t.gp1',
  (record_manual_payment(:A::uuid, :M1::uuid, 'plan', 300000, 'cash', :GP::uuid) ->> 'group_purchase_id'),
  false);
select set_config('request.jwt.claim.sub','',false); reset role;

do $$ begin
  perform expect_true('1.1 desk activation returned a group_purchase id',
    coalesce(current_setting('t.gp1', true), '') <> '');
  perform expect_num('1.2 one unbooked group purchase for the host',
    (select count(*) from group_purchases
      where id = current_setting('t.gp1')::uuid and host_member_id = current_setting('t.m1')::uuid
        and status = 'unbooked'), 1);
  perform expect_num('1.3 no membership was created for a group plan',
    (select count(*) from memberships where member_id = current_setting('t.m1')::uuid
       and plan_id = current_setting('t.gp')::uuid), 0);
  perform expect_num('1.4 payment tagged group_purchase_id, membership_id null',
    (select count(*) from payments where group_purchase_id = current_setting('t.gp1')::uuid
       and membership_id is null and amount_cents = 300000), 1);
  perform expect_text('1.5 the purchase expires on today + 30 days (default window)',
    (select expires_on::text from group_purchases where id = current_setting('t.gp1')::uuid),
    (studio_today(current_setting('t.a')::uuid) + 30)::text);
end $$;

-- =============================================================================
-- 2. BOOK_GROUP — host + existing member + non-member lead, atomically.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','6a0a0000-0000-0000-0000-00000000a001',false);  -- host M1
select set_config('t.r2',
  (book_group(current_setting('t.gp1')::uuid, :O1::uuid,
              array['g-m2@example.com','g-new1@example.com'])::text), false);
select set_config('request.jwt.claim.sub','',false); reset role;

do $$ begin
  perform expect_true('2.1 book_group ok',
    (current_setting('t.r2')::jsonb ->> 'ok')::boolean);
  perform expect_num('2.2 three group seats booked on O1',
    (select count(*) from bookings where occurrence_id = current_setting('t.o1')::uuid
       and payment_source = 'group' and status = 'booked'), 3);
  perform expect_num('2.3 three group_bookings, one host',
    (select count(*) from group_bookings where group_purchase_id = current_setting('t.gp1')::uuid), 3);
  perform expect_num('2.4 exactly one is_host',
    (select count(*) from group_bookings where group_purchase_id = current_setting('t.gp1')::uuid
       and is_host), 1);
  perform expect_num('2.5 O1 booked_count is 3',
    (select booked_count from class_occurrences where id = current_setting('t.o1')::uuid), 3);
  perform expect_text('2.6 group purchase now booked on O1',
    (select status||':'||coalesce(occurrence_id::text,'null') from group_purchases
      where id = current_setting('t.gp1')::uuid),
    'booked:'||current_setting('t.o1'));
  perform expect_num('2.7 a new lead was created for the non-member guest',
    (select count(*) from members where studio_id = current_setting('t.a')::uuid
       and lower(email) = 'g-new1@example.com' and status = 'lead' and source = 'group'), 1);
  perform expect_num('2.8 the lead got a claim invite',
    (select count(*) from member_invites mi join members m on m.id = mi.member_id
      where lower(m.email) = 'g-new1@example.com'), 1);
  perform expect_num('2.9 the lead got a guest_invite notification',
    (select count(*) from notifications n join members m on m.id = n.member_id
      where lower(m.email) = 'g-new1@example.com' and n.template_key = 'guest_invite'), 1);
  -- Free-first untouched: NO guest_passes row for the group guest's email.
  perform expect_num('2.10 free-first untouched — no guest_passes row for the guest',
    (select count(*) from guest_passes where studio_id = current_setting('t.a')::uuid
       and lower(guest_email) = 'g-new1@example.com'), 0);
  -- The existing member consumed no credit (a group seat is payment_source group).
  perform expect_num('2.11 existing-member guest consumed no credit',
    (select count(*) from credit_ledger where member_id = current_setting('t.m2')::uuid), 0);
end $$;

-- =============================================================================
-- 3. MEMBER_ACTIVITY — the group statement lines.
-- =============================================================================
do $$
declare v_guest_title text; v_host_title text; v_host_detail text; v_purchase text;
begin
  select title into v_guest_title
    from member_activity(current_setting('t.m2')::uuid, current_date - 30, current_date + 60)
   where occurrence_id = current_setting('t.o1')::uuid and kind = 'booked';
  perform expect_text('3.1 guest statement names the host and plan',
    v_guest_title, 'Booked by Hugo · Barkada 3');

  select title, detail into v_host_title, v_host_detail
    from member_activity(current_setting('t.m1')::uuid, current_date - 30, current_date + 60)
   where occurrence_id = current_setting('t.o1')::uuid and kind = 'booked';
  perform expect_text('3.2 host statement reads as a group booking',
    v_host_title, 'Group booking — Reformer · Barkada 3');
  -- Lists both guests: the existing member by name ("Mina") and the new lead by
  -- its placeholder name ("Guest", until they claim and set their own).
  perform expect_true('3.3 host booking lists the guest names',
    v_host_detail like '%Mina%' and v_host_detail like '%Guest%' and v_host_detail like '%,%');

  select title into v_purchase
    from member_activity(current_setting('t.m1')::uuid, current_date - 30, current_date + 60)
   where kind = 'purchase' and amount_cents = 300000;
  perform expect_text('3.4 host statement shows the group purchase', v_purchase, 'Bought Barkada 3');
end $$;

-- =============================================================================
-- 4. ALREADY-BOOKED EMAIL refused BY NAME, and nothing is written (atomic).
-- =============================================================================
-- A fresh group for host MB (service context — postgres is service), and M3
-- booked individually on O4.
select set_config('t.gp2', activate_purchase(:A::uuid, :MB::uuid, :GP::uuid, 300000, 'PHP')::text, false);
insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source)
  values (:A, :O4, :M3, 'booked', 'member', 'drop_in');
update class_occurrences set booked_count = 1 where id = :O4;

set role authenticated;
select set_config('request.jwt.claim.sub','6a0a0000-0000-0000-0000-00000000a00b',false);  -- host MB
select set_config('t.r4',
  (book_group(current_setting('t.gp2')::uuid, :O4::uuid,
              array['g-m3@example.com','g-new2@example.com'])::text), false);
select set_config('request.jwt.claim.sub','',false); reset role;

do $$ begin
  perform expect_true('4.1 book_group refused (ok false)',
    (current_setting('t.r4')::jsonb ->> 'ok')::boolean is not true);
  perform expect_text('4.2 reason is already_booked', current_setting('t.r4')::jsonb ->> 'reason', 'already_booked');
  perform expect_text('4.3 the offending email is named',
    current_setting('t.r4')::jsonb ->> 'email', 'g-m3@example.com');
  perform expect_num('4.4 NOTHING written — no group seats on O4',
    (select count(*) from bookings where occurrence_id = current_setting('t.o4')::uuid
       and payment_source = 'group'), 0);
  perform expect_num('4.5 no group_bookings for that purchase',
    (select count(*) from group_bookings where group_purchase_id = current_setting('t.gp2')::uuid), 0);
  perform expect_num('4.6 no lead created for the other email (host seat not left behind)',
    (select count(*) from members where lower(email) = 'g-new2@example.com'), 0);
  perform expect_num('4.7 O4 booked_count unchanged (1)',
    (select booked_count from class_occurrences where id = current_setting('t.o4')::uuid), 1);
  perform expect_text('4.8 the group purchase is still unbooked',
    (select status from group_purchases where id = current_setting('t.gp2')::uuid), 'unbooked');
end $$;

-- =============================================================================
-- 5. CLASS FULL mid-transaction → all-or-none (nothing written).
-- =============================================================================
-- O2 capacity 3, one seat filled → 2 free < group of 3.
insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source)
  values (:A, :O2, :M3, 'booked', 'member', 'drop_in');
update class_occurrences set booked_count = 1 where id = :O2;
select set_config('t.gp3', activate_purchase(:A::uuid, :MB::uuid, :GP::uuid, 300000, 'PHP')::text, false);

set role authenticated;
select set_config('request.jwt.claim.sub','6a0a0000-0000-0000-0000-00000000a00b',false);  -- host MB
select set_config('t.r5',
  (book_group(current_setting('t.gp3')::uuid, :O2::uuid,
              array['g-new2@example.com','g-new3@example.com'])::text), false);
select set_config('request.jwt.claim.sub','',false); reset role;

do $$ begin
  perform expect_text('5.1 reason class_full', current_setting('t.r5')::jsonb ->> 'reason', 'class_full');
  perform expect_num('5.2 nothing written — no group seats on O2',
    (select count(*) from bookings where occurrence_id = current_setting('t.o2')::uuid
       and payment_source = 'group'), 0);
  perform expect_num('5.3 O2 booked_count unchanged (1)',
    (select booked_count from class_occurrences where id = current_setting('t.o2')::uuid), 1);
  perform expect_num('5.4 no leads created',
    (select count(*) from members where lower(email) in ('g-new2@example.com','g-new3@example.com')), 0);
end $$;

-- =============================================================================
-- 6. CLASS-TYPE RESTRICTION — a restricted group refuses the wrong type.
-- =============================================================================
select set_config('t.gpR', activate_purchase(:A::uuid, :MB::uuid, :GR::uuid, 250000, 'PHP')::text, false);
set role authenticated;
select set_config('request.jwt.claim.sub','6a0a0000-0000-0000-0000-00000000a00b',false);  -- host MB
select set_config('t.r6a',
  (book_group(current_setting('t.gpR')::uuid, :O3::uuid, array['g-new3@example.com'])::text), false);  -- CT2, refused
select set_config('t.r6b',
  (book_group(current_setting('t.gpR')::uuid, :O6::uuid, array['g-new3@example.com'])::text), false);  -- CT, allowed
select set_config('request.jwt.claim.sub','',false); reset role;

do $$ begin
  perform expect_text('6.1 restricted group refuses the wrong class type',
    current_setting('t.r6a')::jsonb ->> 'reason', 'class_type_not_allowed');
  perform expect_true('6.2 restricted group books the allowed class type',
    (current_setting('t.r6b')::jsonb ->> 'ok')::boolean);
  perform expect_num('6.3 the allowed group took 2 seats on O6',
    (select booked_count from class_occurrences where id = current_setting('t.o6')::uuid), 2);
end $$;

-- =============================================================================
-- 7. SWAP a guest (before the cut-off), then EARLY vs LATE cancel.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','6a0a0000-0000-0000-0000-00000000a001',false);  -- host M1
-- swap the non-member guest g-new1 → g-new4 on the booked group gp1 (O1 far off).
select set_config('t.r7',
  (swap_group_guest(current_setting('t.gp1')::uuid, 'g-new1@example.com', 'g-new4@example.com')::text), false);
-- refuse: swapping a guest IN to the host's own email, and a non-guest OUT.
select set_config('t.r7host',
  (swap_group_guest(current_setting('t.gp1')::uuid, 'g-m2@example.com', 'g-host@example.com')::text), false);
select set_config('t.r7miss',
  (swap_group_guest(current_setting('t.gp1')::uuid, 'g-nobody@example.com', 'g-new9@example.com')::text), false);
select set_config('request.jwt.claim.sub','',false); reset role;

do $$ begin
  perform expect_true('7.1 swap ok', (current_setting('t.r7')::jsonb ->> 'ok')::boolean);
  perform expect_num('7.2 still three group seats, booked_count unchanged (3)',
    (select booked_count from class_occurrences where id = current_setting('t.o1')::uuid), 3);
  perform expect_num('7.3 g-new1 seat is now cancelled',
    (select count(*) from bookings b join members m on m.id = b.member_id
      where b.occurrence_id = current_setting('t.o1')::uuid and lower(m.email) = 'g-new1@example.com'
        and b.status = 'cancelled'), 1);
  perform expect_num('7.4 g-new4 is booked as a group seat',
    (select count(*) from bookings b join members m on m.id = b.member_id
      where b.occurrence_id = current_setting('t.o1')::uuid and lower(m.email) = 'g-new4@example.com'
        and b.status = 'booked' and b.payment_source = 'group'), 1);
  perform expect_text('7.5 cannot swap a guest in to the host''s own email',
    current_setting('t.r7host')::jsonb ->> 'reason', 'email_is_host');
  perform expect_text('7.6 cannot swap a non-guest',
    current_setting('t.r7miss')::jsonb ->> 'reason', 'guest_not_found');
end $$;

-- EARLY cancel (O1 is 10 days out) → group back to unbooked, seats plain cancelled.
set role authenticated;
select set_config('request.jwt.claim.sub','6a0a0000-0000-0000-0000-00000000a001',false);  -- host M1
select set_config('t.r7e', (cancel_group(current_setting('t.gp1')::uuid)::text), false);
select set_config('request.jwt.claim.sub','',false); reset role;

do $$ begin
  perform expect_true('7.7 early cancel: late is false',
    (current_setting('t.r7e')::jsonb ->> 'late')::boolean is not true);
  perform expect_text('7.8 group returns to unbooked (rebookable in its window)',
    (select status||':'||coalesce(occurrence_id::text,'null') from group_purchases
      where id = current_setting('t.gp1')::uuid), 'unbooked:null');
  perform expect_num('7.9 O1 booked_count back to 0',
    (select booked_count from class_occurrences where id = current_setting('t.o1')::uuid), 0);
  perform expect_num('7.10 NO group seat was stamped late_cancelled',
    (select count(*) from bookings b join group_bookings gb on gb.booking_id = b.id
      where gb.group_purchase_id = current_setting('t.gp1')::uuid
        and (b.status = 'late_cancelled' or b.is_late_cancel)), 0);
end $$;

-- LATE cancel: a group on O5 (30 min out, inside the 12h cut-off).
select set_config('t.gp5', activate_purchase(:A::uuid, :MB::uuid, :GP::uuid, 300000, 'PHP')::text, false);
set role authenticated;
select set_config('request.jwt.claim.sub','6a0a0000-0000-0000-0000-00000000a00b',false);  -- host MB
select set_config('t.r5book',
  (book_group(current_setting('t.gp5')::uuid, :O5::uuid,
              array['g-m2@example.com','g-new5@example.com'])::text), false);
select set_config('t.r5late', (cancel_group(current_setting('t.gp5')::uuid)::text), false);
select set_config('request.jwt.claim.sub','',false); reset role;

do $$ begin
  perform expect_true('7.11 late cancel: late is true',
    (current_setting('t.r5late')::jsonb ->> 'late')::boolean);
  perform expect_text('7.12 the group purchase is forfeited (cancelled)',
    (select status from group_purchases where id = current_setting('t.gp5')::uuid), 'cancelled');
  perform expect_num('7.13 the late group seats are PLAIN cancelled (no late stamp on guests)',
    (select count(*) from bookings b join group_bookings gb on gb.booking_id = b.id
      where gb.group_purchase_id = current_setting('t.gp5')::uuid
        and (b.status = 'late_cancelled' or b.is_late_cancel)), 0);
  perform expect_num('7.14 those seats are cancelled',
    (select count(*) from bookings b join group_bookings gb on gb.booking_id = b.id
      where gb.group_purchase_id = current_setting('t.gp5')::uuid and b.status = 'cancelled'), 3);
end $$;

-- =============================================================================
-- 8. EXPIRY — an unbooked group past its window expires; others untouched.
-- =============================================================================
select set_config('t.gpExp', activate_purchase(:A::uuid, :MB::uuid, :GP::uuid, 300000, 'PHP')::text, false);
update group_purchases set expires_on = studio_today(:A) - 1
  where id = current_setting('t.gpExp')::uuid;
select expire_group_purchases();  -- postgres is service context

do $$ begin
  perform expect_text('8.1 the past-window unbooked group is expired',
    (select status from group_purchases where id = current_setting('t.gpExp')::uuid), 'expired');
  perform expect_text('8.2 a future-window unbooked group is untouched',
    (select status from group_purchases where id = current_setting('t.gp2')::uuid), 'unbooked');
end $$;

-- =============================================================================
-- 9. HOST-OR-STAFF only, and anon THIRTEEN.
-- =============================================================================
-- A booked group owned by MB on O4 (M3's seat was on O4; O4 has room). Book it
-- cleanly on O6? O6 already has the restricted group (2 seats). Use a fresh
-- host group on O4 — but M3 is booked there. Book MB's group on O2? O2 has 1.
-- Simplest: a booked group for MB on O1 (now empty again after the early cancel).
select set_config('t.gpX', activate_purchase(:A::uuid, :MB::uuid, :GP::uuid, 300000, 'PHP')::text, false);
set role authenticated;
select set_config('request.jwt.claim.sub','6a0a0000-0000-0000-0000-00000000a00b',false);  -- host MB
select set_config('t.rX',
  (book_group(current_setting('t.gpX')::uuid, :O1::uuid,
              array['g-m2@example.com','g-new6@example.com'])::text), false);
select set_config('request.jwt.claim.sub','',false); reset role;

-- A stranger (MC) cannot book MB's unbooked group, nor cancel MB's booked group.
set role authenticated;
select set_config('request.jwt.claim.sub','6a0a0000-0000-0000-0000-00000000a00c',false);  -- stranger MC
select set_config('t.r9book',
  (book_group(current_setting('t.gp2')::uuid, :O4::uuid, array['g-new7@example.com','g-new8@example.com'])::text), false);
select set_config('request.jwt.claim.sub','',false); reset role;

do $$ begin
  perform expect_true('9.1 the staff/host group booked', (current_setting('t.rX')::jsonb ->> 'ok')::boolean);
  perform expect_text('9.2 a stranger cannot book someone else''s group',
    current_setting('t.r9book')::jsonb ->> 'reason', 'not_authorised');
end $$;

-- cancel_group: a stranger is PT403; a manager (OA, desk) can cancel.
set role authenticated;
select set_config('request.jwt.claim.sub','6a0a0000-0000-0000-0000-00000000a00c',false);  -- stranger MC
select expect_raises('9.3 a stranger cannot cancel a group (PT403)',
  'select cancel_group('||quote_literal(current_setting('t.gpX'))||'::uuid)', 'PT403');
select set_config('request.jwt.claim.sub','6a0a0000-0000-0000-0000-0000000000a1',false);  -- OA (staff)
select set_config('t.r9cancel', (cancel_group(current_setting('t.gpX')::uuid)::text), false);
select set_config('request.jwt.claim.sub','',false); reset role;

do $$ begin
  perform expect_true('9.4 staff can cancel a group', (current_setting('t.r9cancel')::jsonb ->> 'ok')::boolean);
  -- The enum values landed, and the anon surface is EXACTLY THIRTEEN.
  perform expect_true('9.5 plan_type has group',
    exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
             where t.typname = 'plan_type' and e.enumlabel = 'group'));
  perform expect_true('9.6 payment_source has group',
    exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
             where t.typname = 'payment_source' and e.enumlabel = 'group'));
  perform expect_num('9.7 anon surface is exactly THIRTEEN',
    (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
      where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
        and p.proname not like 'expect_%'), 13);
end $$;

select 'group_packages_test: all assertions passed' as result;
