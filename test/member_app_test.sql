-- =============================================================================
-- STUDIIOR — THE MEMBER APP (migration 025)
--
--   the four things a member session could not previously see, the rotating
--   check-in code, and cancelling — including what happens to the credit and
--   to the seat.
--
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -f test/member_app_test.sql
-- =============================================================================

\set ON_ERROR_STOP on
set client_min_messages = notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then
    raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else
    raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null');
  end if;
end $$;

create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then
    raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else
    raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null');
  end if;
end $$;

-- --- Fixtures: eeee ---------------------------------------------------------

insert into auth.users (id) values
  ('eeeeeeee-0000-0000-0000-0000000000a1'),   -- the member
  ('eeeeeeee-0000-0000-0000-0000000000a2'),   -- front desk
  ('eeeeeeee-0000-0000-0000-0000000000a3');   -- second member, on the waitlist
insert into profiles (id, email) values
  ('eeeeeeee-0000-0000-0000-0000000000a1','m-one@example.com'),
  ('eeeeeeee-0000-0000-0000-0000000000a2','m-desk@example.com'),
  ('eeeeeeee-0000-0000-0000-0000000000a3','m-two@example.com');

insert into studios (id, name, slug, timezone, currency, status) values
  ('eeeeeeee-0000-0000-0000-000000000001','Member App Studio','member-test','Europe/Prague','CZK','active');
insert into studio_settings (studio_id, cancellation_cutoff_minutes, late_cancel_consumes_credit,
                             waitlist_enabled, waitlist_offer_window_minutes, waitlist_cutoff_minutes)
  values ('eeeeeeee-0000-0000-0000-000000000001', 720, true, true, 120, 60);
insert into locations (id, studio_id, name) values
  ('eeeeeeee-0000-0000-0000-00000000000c','eeeeeeee-0000-0000-0000-000000000001','Main');
insert into studio_staff (studio_id, user_id, email, role) values
  ('eeeeeeee-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-0000000000a2','m-desk@example.com','front_desk');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('eeeeeeee-0000-0000-0000-00000000ee01','eeeeeeee-0000-0000-0000-000000000001',
   'eeeeeeee-0000-0000-0000-00000000000c','Studio A',1);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('eeeeeeee-0000-0000-0000-00000000cc01','eeeeeeee-0000-0000-0000-000000000001','Reformer',50,1);
insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, validity_days) values
  ('eeeeeeee-0000-0000-0000-00000000aa01','eeeeeeee-0000-0000-0000-000000000001',
   '10-Class Pack','class_pack',500000,'CZK',10,180);

insert into members (id, studio_id, user_id, first_name, last_name, email, joined_on, waiver_signed_at) values
  ('eeeeeeee-0000-0000-0000-00000000dd01','eeeeeeee-0000-0000-0000-000000000001',
   'eeeeeeee-0000-0000-0000-0000000000a1','Mem','One','m-one@example.com', current_date - 100, now()),
  ('eeeeeeee-0000-0000-0000-00000000dd02','eeeeeeee-0000-0000-0000-000000000001',
   'eeeeeeee-0000-0000-0000-0000000000a3','Mem','Two','m-two@example.com', current_date - 100, now());

insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on, expires_on, credits_remaining) values
  ('eeeeeeee-0000-0000-0000-00000000fa01','eeeeeeee-0000-0000-0000-000000000001',
   'eeeeeeee-0000-0000-0000-00000000dd01','eeeeeeee-0000-0000-0000-00000000aa01',
   'active',500000,'CZK', current_date - 10, current_date + 170, 10),
  ('eeeeeeee-0000-0000-0000-00000000fa02','eeeeeeee-0000-0000-0000-000000000001',
   'eeeeeeee-0000-0000-0000-00000000dd02','eeeeeeee-0000-0000-0000-00000000aa01',
   'active',500000,'CZK', current_date - 10, current_date + 170, 10);

-- One class that already ran and one well in the future.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               starts_at, ends_at, capacity, status) values
  ('eeeeeeee-0000-0000-0000-00000000bb01','eeeeeeee-0000-0000-0000-000000000001',
   'eeeeeeee-0000-0000-0000-00000000000c','eeeeeeee-0000-0000-0000-00000000cc01',
   'eeeeeeee-0000-0000-0000-00000000ee01','Past Reformer',
   now() - interval '3 days', now() - interval '3 days' + interval '50 min', 1, 'completed'),
  ('eeeeeeee-0000-0000-0000-00000000bb02','eeeeeeee-0000-0000-0000-000000000001',
   'eeeeeeee-0000-0000-0000-00000000000c','eeeeeeee-0000-0000-0000-00000000cc01',
   'eeeeeeee-0000-0000-0000-00000000ee01','Future Reformer',
   now() + interval '5 days', now() + interval '5 days' + interval '50 min', 1, 'scheduled'),
  -- A completed class the member had nothing to do with.
  ('eeeeeeee-0000-0000-0000-00000000bb03','eeeeeeee-0000-0000-0000-000000000001',
   'eeeeeeee-0000-0000-0000-00000000000c','eeeeeeee-0000-0000-0000-00000000cc01',
   'eeeeeeee-0000-0000-0000-00000000ee01','Someone Else''s Class',
   now() - interval '2 days', now() - interval '2 days' + interval '50 min', 1, 'completed');

insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source, booked_at) values
  ('eeeeeeee-0000-0000-0000-00000000fb01','eeeeeeee-0000-0000-0000-000000000001',
   'eeeeeeee-0000-0000-0000-00000000bb01','eeeeeeee-0000-0000-0000-00000000dd01',
   'attended','class_pack', now() - interval '4 days');
insert into check_ins (studio_id, booking_id, member_id, occurrence_id, checked_in_at, method) values
  ('eeeeeeee-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-00000000fb01',
   'eeeeeeee-0000-0000-0000-00000000dd01','eeeeeeee-0000-0000-0000-00000000bb01',
   now() - interval '3 days', 'staff');

-- =============================================================================
-- 1. The four things a member could not see
-- =============================================================================

set role authenticated;
select set_config('request.jwt.claim.sub','eeeeeeee-0000-0000-0000-0000000000a1',false);

select expect_num('a member sees the class they attended, even though it is completed',
  (select count(*) from class_occurrences where id='eeeeeeee-0000-0000-0000-00000000bb01'), 1);
select expect_num('and their history joins up to a real class name',
  (select count(o.id) from check_ins ci join class_occurrences o on o.id = ci.occurrence_id), 1);
select expect_text('with the name, not a blank',
  (select o.name from check_ins ci join class_occurrences o on o.id = ci.occurrence_id limit 1),
  'Past Reformer');

-- The narrow bit: their own history, not the studio's whole past.
select expect_num('a completed class they were not at stays hidden',
  (select count(*) from class_occurrences where id='eeeeeeee-0000-0000-0000-00000000bb03'), 0);

select expect_num('rooms are readable, so they know where to go',
  (select count(*) from rooms), 1);
select expect_num('studio_settings itself is still hidden',
  (select count(*) from studio_settings), 0);
select expect_num('but the member-facing settings come through',
  (select checkin_opens_minutes_before::bigint
     from studio_member_settings('eeeeeeee-0000-0000-0000-000000000001')), 60);
reset role;

-- =============================================================================
-- 2. The rotating code — Permissions §8 note 13
-- =============================================================================

set role authenticated;
select set_config('request.jwt.claim.sub','eeeeeeee-0000-0000-0000-0000000000a1',false);
select set_config('m.code', (select code from member_checkin_code()), false);
select expect_num('the code is eight characters',
  length(current_setting('m.code'))::bigint, 8);
select expect_num('a member cannot resolve a code — not even their own',
  (select count(*) from resolve_checkin_code(current_setting('m.code'))), 0);
reset role;

set role authenticated;
select set_config('request.jwt.claim.sub','eeeeeeee-0000-0000-0000-0000000000a2',false);  -- front desk
select expect_text('the desk resolves it to the right member',
  (select first_name || ' ' || last_name from resolve_checkin_code(current_setting('m.code'))),
  'Mem One');
select expect_num('a code from an old bucket does not work',
  (select count(*) from resolve_checkin_code(
     checkin_code_for('eeeeeeee-0000-0000-0000-00000000dd01',
                      floor(extract(epoch from now()) / 30)::bigint - 5))), 0);
select expect_num('but the one just before does, so a scan mid-rotation still lands',
  (select count(*) from resolve_checkin_code(
     checkin_code_for('eeeeeeee-0000-0000-0000-00000000dd01',
                      floor(extract(epoch from now()) / 30)::bigint - 1))), 1);
select expect_num('nonsense matches nobody',
  (select count(*) from resolve_checkin_code('ZZZZZZZZ')), 0);
reset role;

-- The secret is what makes it unforgeable, so the member must never see it.
set role authenticated;
select set_config('request.jwt.claim.sub','eeeeeeee-0000-0000-0000-0000000000a1',false);
select expect_num('the signing secret is not readable by the member',
  (select count(*) from studio_settings where checkin_secret is not null), 0);
reset role;

-- =============================================================================
-- 3. Cancelling — Business Rules §3.1
-- =============================================================================

set role authenticated;
select set_config('request.jwt.claim.sub','eeeeeeee-0000-0000-0000-0000000000a1',false);
select set_config('m.book1',
  ((book_class('eeeeeeee-0000-0000-0000-00000000bb02',
               'eeeeeeee-0000-0000-0000-00000000dd01','member')).booking_id)::text, false);
reset role;

select expect_num('booking took a credit',
  (select credits_remaining from memberships where id='eeeeeeee-0000-0000-0000-00000000fa01'), 9);
select expect_num('and filled the only seat',
  (select booked_count from class_occurrences where id='eeeeeeee-0000-0000-0000-00000000bb02'), 1);

-- Second member joins the waitlist. §4.1: no credit taken.
set role authenticated;
select set_config('request.jwt.claim.sub','eeeeeeee-0000-0000-0000-0000000000a3',false);
select set_config('m.wait',
  ((book_class('eeeeeeee-0000-0000-0000-00000000bb02',
               'eeeeeeee-0000-0000-0000-00000000dd02','member')).booking_id)::text, false);
reset role;

select expect_text('the second member is waitlisted, not booked',
  (select status::text from bookings where id=current_setting('m.wait')::uuid), 'waitlisted');
select expect_num('and joining the waitlist took no credit — §4.1',
  (select credits_remaining from memberships where id='eeeeeeee-0000-0000-0000-00000000fa02'), 10);

-- Cancel well before the cutoff: credit back, seat released, offer made.
set role authenticated;
select set_config('request.jwt.claim.sub','eeeeeeee-0000-0000-0000-0000000000a1',false);
select set_config('m.cancel', (cancel_booking(current_setting('m.book1')::uuid))::text, false);
reset role;

select expect_text('cancelling in good time is a plain cancel',
  (select status::text from bookings where id=current_setting('m.book1')::uuid), 'cancelled');
select expect_num('the credit came back',
  (select credits_remaining from memberships where id='eeeeeeee-0000-0000-0000-00000000fa01'), 10);
select expect_text('and the ledger says why',
  (select reason::text from credit_ledger
    where booking_id=current_setting('m.book1')::uuid and delta > 0), 'cancellation_refund');
select expect_num('the seat was released',
  (select booked_count from class_occurrences where id='eeeeeeee-0000-0000-0000-00000000bb02'), 0);
select expect_num('and the person waiting was offered it — §4.2',
  (select count(*) from waitlist_offers where occurrence_id='eeeeeeee-0000-0000-0000-00000000bb02'), 1);

-- Accepting re-runs the gate and books them for real.
set role authenticated;
select set_config('request.jwt.claim.sub','eeeeeeee-0000-0000-0000-0000000000a3',false);
select set_config('m.resp',
  (respond_to_offer((select id from waitlist_offers
                      where occurrence_id='eeeeeeee-0000-0000-0000-00000000bb02'), true))::text, false);
reset role;

select expect_text('accepting works',
  (current_setting('m.resp')::jsonb ->> 'accepted'), 'true');
select expect_num('the seat is theirs',
  (select booked_count from class_occurrences where id='eeeeeeee-0000-0000-0000-00000000bb02'), 1);
select expect_num('and now the credit is taken, not before',
  (select credits_remaining from memberships where id='eeeeeeee-0000-0000-0000-00000000fa02'), 9);
select expect_text('the offer is closed',
  (select outcome from waitlist_offers where occurrence_id='eeeeeeee-0000-0000-0000-00000000bb02'),
  'accepted');

-- A late cancel: the class is used, and the seat still opens. §3.1.
update class_occurrences set starts_at = now() + interval '2 hours',
                             ends_at   = now() + interval '2 hours' + interval '50 min'
 where id = 'eeeeeeee-0000-0000-0000-00000000bb02';

set role authenticated;
select set_config('request.jwt.claim.sub','eeeeeeee-0000-0000-0000-0000000000a3',false);
select set_config('m.late',
  (cancel_booking((select id from bookings
                    where occurrence_id='eeeeeeee-0000-0000-0000-00000000bb02'
                      and member_id='eeeeeeee-0000-0000-0000-00000000dd02'
                      and status='booked')))::text, false);
reset role;

select expect_text('cancelling late is recorded as a late cancel',
  (select status::text from bookings
    where occurrence_id='eeeeeeee-0000-0000-0000-00000000bb02'
      and member_id='eeeeeeee-0000-0000-0000-00000000dd02'
      and status = 'late_cancelled'), 'late_cancelled');
select expect_num('the class is used, per late_cancel_consumes_credit',
  (select credits_remaining from memberships where id='eeeeeeee-0000-0000-0000-00000000fa02'), 9);
select expect_num('and the seat opens anyway — holding it empty helps nobody',
  (select booked_count from class_occurrences where id='eeeeeeee-0000-0000-0000-00000000bb02'), 0);

-- §4.3: no offer worth making inside the cutoff.
select expect_num('no offer is made when the window would be too short',
  (select count(*) from waitlist_offers
    where occurrence_id='eeeeeeee-0000-0000-0000-00000000bb02' and outcome is null), 0);

-- Somebody else's booking is not yours to cancel.
set role authenticated;
select set_config('request.jwt.claim.sub','eeeeeeee-0000-0000-0000-0000000000a1',false);
do $$
begin
  perform cancel_booking('eeeeeeee-0000-0000-0000-00000000fb01');
  raise exception 'FAIL  cancelled an already-attended booking';
exception when sqlstate 'PT409' then
  raise notice 'PASS  an attended booking cannot be cancelled';
end $$;
reset role;

-- =============================================================================
-- member_bootstrap() — the one call every member screen now depends on
-- =============================================================================
-- It replaced four sequential requests, so if it is wrong the whole app is
-- wrong quietly rather than loudly. Keyed on auth.uid(): the slug picks which
-- of the caller's memberships is meant and can never reach past them.

set role authenticated;
select set_config('request.jwt.claim.sub','eeeeeeee-0000-0000-0000-0000000000a1',false);

select expect_num('the bootstrap returns exactly one row for its caller',
  (select count(*) from member_bootstrap('member-test')), 1);
select expect_text('...it is the caller''s own member row',
  (select member_id::text from member_bootstrap('member-test')),
  'eeeeeeee-0000-0000-0000-00000000dd01');
select expect_text('...carrying the studio, so nothing has to ask again',
  (select studio_name from member_bootstrap('member-test')), 'Member App Studio');
select expect_text('...and the member-facing settings, which they cannot read directly',
  (select (cancellation_cutoff_minutes is not null)::text from member_bootstrap('member-test')), 'true');
select expect_num('a member still cannot read studio_settings itself',
  (select count(*) from studio_settings), 0);
select expect_num('a slug they are not a member of returns nothing',
  (select count(*) from member_bootstrap('some-other-studio')), 0);
reset role;

-- Somebody else's session gets their own context, never the first caller's.
set role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000000',false);
select expect_num('a stranger gets no context at all',
  (select count(*) from member_bootstrap('member-test')), 0);
reset role;

select 'ALL MEMBER APP TESTS PASSED' as result;
