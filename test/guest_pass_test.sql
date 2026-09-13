-- =============================================================================
-- Guest passes — Decision 26, migration 127
-- =============================================================================
-- UUID space 9e57, checked free. Run after `supabase db reset`.
--
-- A guest books the host's class and no other; a second free class for the same
-- email is refused; an existing member's email is refused; a host cannot invite
-- a second guest until the first attends; a full class refuses at one free seat;
-- the guest seat consumes no credit and no peak; the host cancelling leaves the
-- guest booked and tells them; an unsigned waiver blocks check-in; the guest
-- claims and becomes an ordinary member; a studio with the feature off sees
-- nothing; two studios in one run.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual then raise notice 'PASS  %  (got true)', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('9e579e57-0000-0000-0000-0000000000a1'),  -- owner (A + B desk)
  ('9e579e57-0000-0000-0000-000000000e01'),  -- HOST1 login
  ('9e579e57-0000-0000-0000-000000000e02'),  -- HOSTB login
  ('9e579e57-0000-0000-0000-000000000e03');  -- HOST3 (existing-member email test)
insert into profiles (id, email)
  select id, id::text||'@example.com' from auth.users where id::text like '9e579e57%';

insert into studios (id, name, slug, timezone, currency, status) values
  ('9e579e57-0000-0000-0000-000000000001','Guest A','9e57-a','Europe/Prague','CZK','active'),
  ('9e579e57-0000-0000-0000-000000000002','Guest B','9e57-b','Asia/Manila','PHP','active'),
  ('9e579e57-0000-0000-0000-000000000003','Guest C','9e57-c','Europe/Prague','CZK','active');
-- A + B run guest passes; the check-in window is off so the waiver gate is isolated.
-- C has the feature OFF (no trace).
insert into studio_settings (studio_id, guest_passes_enabled, checkin_window_enforced, require_waiver) values
  ('9e579e57-0000-0000-0000-000000000001', true,  false, true),
  ('9e579e57-0000-0000-0000-000000000002', true,  false, true),
  ('9e579e57-0000-0000-0000-000000000003', false, false, true);
insert into locations (id, studio_id, name, is_primary) values
  ('9e579e57-0000-0000-0000-00000000000a','9e579e57-0000-0000-0000-000000000001','Main',true),
  ('9e579e57-0000-0000-0000-00000000000b','9e579e57-0000-0000-0000-000000000002','Main',true);
insert into studio_staff (studio_id, user_id, email, role) values
  ('9e579e57-0000-0000-0000-000000000001','9e579e57-0000-0000-0000-0000000000a1','9e57-owa@example.com','owner'),
  ('9e579e57-0000-0000-0000-000000000002','9e579e57-0000-0000-0000-0000000000a1','9e57-owb@example.com','owner');
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('9e579e57-0000-0000-0000-0000000cc001','9e579e57-0000-0000-0000-000000000001','Reformer',50,10),
  ('9e579e57-0000-0000-0000-0000000cc002','9e579e57-0000-0000-0000-000000000002','Reformer',50,10);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('9e579e57-0000-0000-0000-0000000ee001','9e579e57-0000-0000-0000-000000000001','9e579e57-0000-0000-0000-00000000000a','R1',20),
  ('9e579e57-0000-0000-0000-0000000ee002','9e579e57-0000-0000-0000-000000000001','9e579e57-0000-0000-0000-00000000000a','R2',20),
  ('9e579e57-0000-0000-0000-0000000ee003','9e579e57-0000-0000-0000-000000000001','9e579e57-0000-0000-0000-00000000000a','R3',20),
  ('9e579e57-0000-0000-0000-0000000ee004','9e579e57-0000-0000-0000-000000000001','9e579e57-0000-0000-0000-00000000000a','R4',20),
  ('9e579e57-0000-0000-0000-0000000ee00b','9e579e57-0000-0000-0000-000000000002','9e579e57-0000-0000-0000-00000000000b','R1',20);

-- An unlimited recurring plan so a host's own seat books outright (no drop-in).
insert into membership_plans (id, studio_id, name, type, price_cents, currency, billing_interval, credits_per_period, status) values
  ('9e579e57-0000-0000-0000-0000000f1001','9e579e57-0000-0000-0000-000000000001','Unlimited','recurring',900000,'CZK','month',null,'active'),
  ('9e579e57-0000-0000-0000-0000000f100b','9e579e57-0000-0000-0000-000000000002','Unlimited','recurring',900000,'PHP','month',null,'active');

-- Hosts (with logins, waiver signed so their own booking passes §2.1) + one
-- plain existing member whose email will be offered as a guest (refused).
insert into members (id, studio_id, user_id, first_name, last_name, email, waiver_signed_at) values
  ('9e579e57-0000-0000-0000-0000000d0a01','9e579e57-0000-0000-0000-000000000001','9e579e57-0000-0000-0000-000000000e01','Host','One','9e57-host1@example.com',now()),
  ('9e579e57-0000-0000-0000-0000000d0a03','9e579e57-0000-0000-0000-000000000001','9e579e57-0000-0000-0000-000000000e03','Host','Three','9e57-host3@example.com',now()),
  ('9e579e57-0000-0000-0000-0000000d0e11','9e579e57-0000-0000-0000-000000000001',null,'Exist','Ing','9e57-existing@example.com',now()),
  ('9e579e57-0000-0000-0000-0000000d0a0b','9e579e57-0000-0000-0000-000000000002','9e579e57-0000-0000-0000-000000000e02','Host','Bee','9e57-hostb@example.com',now());
insert into memberships (studio_id, member_id, plan_id, status, price_cents, currency, starts_on) values
  ('9e579e57-0000-0000-0000-000000000001','9e579e57-0000-0000-0000-0000000d0a01','9e579e57-0000-0000-0000-0000000f1001','active',900000,'CZK',current_date),
  ('9e579e57-0000-0000-0000-000000000001','9e579e57-0000-0000-0000-0000000d0a03','9e579e57-0000-0000-0000-0000000f1001','active',900000,'CZK',current_date),
  ('9e579e57-0000-0000-0000-000000000002','9e579e57-0000-0000-0000-0000000d0a0b','9e579e57-0000-0000-0000-0000000f100b','active',900000,'PHP',current_date);

-- Occurrences. OCC1 roomy; FULL cap 1 with a filler; ONE cap 1 empty; REINVITE roomy.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               starts_at, ends_at, capacity, booked_count, status) values
  ('9e579e57-0000-0000-0000-00000000c001','9e579e57-0000-0000-0000-000000000001','9e579e57-0000-0000-0000-00000000000a','9e579e57-0000-0000-0000-0000000cc001','9e579e57-0000-0000-0000-0000000ee001','Reformer AM', now()+interval '120 min', now()+interval '170 min',10,0,'scheduled'),
  ('9e579e57-0000-0000-0000-00000000c0f1','9e579e57-0000-0000-0000-000000000001','9e579e57-0000-0000-0000-00000000000a','9e579e57-0000-0000-0000-0000000cc001','9e579e57-0000-0000-0000-0000000ee002','Full', now()+interval '120 min', now()+interval '170 min',1,1,'scheduled'),
  ('9e579e57-0000-0000-0000-00000000c051','9e579e57-0000-0000-0000-000000000001','9e579e57-0000-0000-0000-00000000000a','9e579e57-0000-0000-0000-0000000cc001','9e579e57-0000-0000-0000-0000000ee003','OneSeat', now()+interval '120 min', now()+interval '170 min',1,0,'scheduled'),
  ('9e579e57-0000-0000-0000-00000000c0e1','9e579e57-0000-0000-0000-000000000001','9e579e57-0000-0000-0000-00000000000a','9e579e57-0000-0000-0000-0000000cc001','9e579e57-0000-0000-0000-0000000ee004','Reinvite', now()+interval '120 min', now()+interval '170 min',10,0,'scheduled'),
  ('9e579e57-0000-0000-0000-00000000c00b','9e579e57-0000-0000-0000-000000000002','9e579e57-0000-0000-0000-00000000000b','9e579e57-0000-0000-0000-0000000cc002','9e579e57-0000-0000-0000-0000000ee00b','Reformer B', now()+interval '120 min', now()+interval '170 min',10,0,'scheduled');
-- The filler that makes 'Full' full.
insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source)
values ('9e579e57-0000-0000-0000-000000000001','9e579e57-0000-0000-0000-00000000c0f1','9e579e57-0000-0000-0000-0000000d0e11','booked','member','comp');

-- =============================================================================
-- 1. HOST1 brings GUEST1 to OCC1. The host is booked and the guest gets a
--    second seat in the SAME class, and no other.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','9e579e57-0000-0000-0000-000000000e01',false);
select set_config('t.g1', (book_guest('9e579e57-0000-0000-0000-00000000c001','GUEST1@Example.com','Gwen','Guest'))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;

select expect_true('book_guest ok', (current_setting('t.g1')::jsonb->>'ok')::boolean);
select expect_num('it took two seats (host had none)', (current_setting('t.g1')::jsonb->>'seats_taken')::bigint, 2);
select expect_num('OCC1 booked_count is 2', (select booked_count from class_occurrences where id='9e579e57-0000-0000-0000-00000000c001'), 2);
-- the guest booking is on OCC1 and nowhere else
select expect_num('guest has exactly one booking, on the host class',
  (select count(*) from bookings where member_id=(current_setting('t.g1')::jsonb->>'guest_member_id')::uuid
     and occurrence_id='9e579e57-0000-0000-0000-00000000c001'), 1);
select expect_num('guest has no booking on any other class',
  (select count(*) from bookings where member_id=(current_setting('t.g1')::jsonb->>'guest_member_id')::uuid
     and occurrence_id<>'9e579e57-0000-0000-0000-00000000c001'), 0);
select expect_text('the guest is a lead',
  (select status::text from members where id=(current_setting('t.g1')::jsonb->>'guest_member_id')::uuid), 'lead');

-- 6. The guest seat consumes no credit and no peak allowance.
select expect_text('guest seat is comp',
  (select payment_source::text from bookings where id=(current_setting('t.g1')::jsonb->>'guest_booking_id')::uuid), 'comp');
select expect_num('guest seat carries no membership',
  (select count(*) from bookings where id=(current_setting('t.g1')::jsonb->>'guest_booking_id')::uuid and membership_id is not null), 0);
select expect_num('guest consumed no credit',
  (select count(*) from credit_ledger where member_id=(current_setting('t.g1')::jsonb->>'guest_member_id')::uuid), 0);
select expect_num('guest consumed no peak allowance',
  (select count(*) from peak_allowance_ledger where booking_id=(current_setting('t.g1')::jsonb->>'guest_booking_id')::uuid), 0);

-- =============================================================================
-- 1b. sign_waiver guards against signing SOMEONE ELSE's waiver (migration 129).
--     The guest (t.g1) has a null user_id; a null auth-guard must still refuse.
-- =============================================================================
do $$
declare v_guest uuid := (current_setting('t.g1')::jsonb->>'guest_member_id')::uuid; v_raised text := 'NOT REFUSED';
begin
  perform set_config('request.jwt.claim.sub','9e579e57-0000-0000-0000-000000000e03', true);
  set local role authenticated;
  begin perform sign_waiver(v_guest); exception when others then v_raised := sqlstate; end;
  perform expect_text('a member cannot sign another member''s waiver', v_raised, 'PT403');
end $$;
select set_config('request.jwt.claim.sub','',false);

-- =============================================================================
-- 2/3. Refusals: second free class for the same email; an existing member's email.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','9e579e57-0000-0000-0000-000000000e03',false);
select set_config('t.dup', (book_guest('9e579e57-0000-0000-0000-00000000c0e1','guest1@example.com','Gwen','Guest'))::text, false);
select set_config('t.mem', (book_guest('9e579e57-0000-0000-0000-00000000c0e1','9e57-existing@example.com','Ex','Ist'))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('same email refused a second free class', current_setting('t.dup')::jsonb->>'reason', 'already_had_free');
select expect_text('an existing member email is refused', current_setting('t.mem')::jsonb->>'reason', 'already_member');

-- =============================================================================
-- 4. One guest at a time — HOST1 already has a live guest.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','9e579e57-0000-0000-0000-000000000e01',false);
select set_config('t.two', (book_guest('9e579e57-0000-0000-0000-00000000c0e1','another@example.com','An','Other'))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('a second live guest is refused', current_setting('t.two')::jsonb->>'reason', 'have_active_guest');

-- GUEST1 attends -> the pass frees the host, who may invite again.
update bookings set status='attended' where id=(current_setting('t.g1')::jsonb->>'guest_booking_id')::uuid;
select expect_text('the pass is now attended',
  (select status from guest_passes where guest_booking_id=(current_setting('t.g1')::jsonb->>'guest_booking_id')::uuid), 'attended');
set role authenticated; select set_config('request.jwt.claim.sub','9e579e57-0000-0000-0000-000000000e01',false);
select set_config('t.g2', (book_guest('9e579e57-0000-0000-0000-00000000c0e1','another@example.com','An','Other'))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_true('after the first attends the host can invite again', (current_setting('t.g2')::jsonb->>'ok')::boolean);

-- =============================================================================
-- 5. Capacity: only one seat left (need two) and a full class.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','9e579e57-0000-0000-0000-000000000e03',false);
select set_config('t.one', (book_guest('9e579e57-0000-0000-0000-00000000c051','fresh1@example.com','F','One'))::text, false);
select set_config('t.full',(book_guest('9e579e57-0000-0000-0000-00000000c0f1','fresh2@example.com','F','Two'))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('one free seat, needing two, is refused as only_one_seat', current_setting('t.one')::jsonb->>'reason', 'only_one_seat');
select expect_text('a full class is refused as class_full', current_setting('t.full')::jsonb->>'reason', 'class_full');

-- =============================================================================
-- 7. Host cancels -> guest booking stands, guest is told.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','9e579e57-0000-0000-0000-000000000e01',false);
select cancel_booking((current_setting('t.g2')::jsonb->>'host_booking_id')::uuid);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('the guest booking still stands',
  (select status::text from bookings where id=(current_setting('t.g2')::jsonb->>'guest_booking_id')::uuid), 'booked');
select expect_num('the guest was told their host cancelled',
  (select count(*) from notifications where template_key='guest_host_cancelled'
     and member_id=(current_setting('t.g2')::jsonb->>'guest_member_id')::uuid), 1);


-- =============================================================================
-- 8. Unsigned waiver blocks check-in; signing in the app clears it.
-- =============================================================================
do $$
declare v_guest uuid := (current_setting('t.g1')::jsonb->>'guest_member_id')::uuid;  -- attended already, waiver still unsigned
  v_occ uuid := '9e579e57-0000-0000-0000-00000000c001'; v_raised boolean := false;
begin
  begin
    insert into check_ins (studio_id, member_id, occurrence_id, booking_id, checked_in_at, method)
    values ('9e579e57-0000-0000-0000-000000000001', v_guest, v_occ,
            (current_setting('t.g1')::jsonb->>'guest_booking_id')::uuid, now(), 'staff');
  exception when sqlstate 'PT422' then v_raised := true;
  end;
  perform expect_true('unsigned guest waiver blocks check-in', v_raised);
end $$;

-- The guest signs in the app (self). We need their user_id; simulate a claimed
-- guest by signing as the desk here — sign_waiver allows self OR desk.
set role authenticated; select set_config('request.jwt.claim.sub','9e579e57-0000-0000-0000-0000000000a1',false);  -- owner/desk
select sign_waiver((current_setting('t.g1')::jsonb->>'guest_member_id')::uuid);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('signing confirms the pass',
  (select status from guest_passes where guest_member_id=(current_setting('t.g1')::jsonb->>'guest_member_id')::uuid), 'attended');  -- already attended; stays
select expect_num('the guest waiver is now signed',
  (select count(*) from members where id=(current_setting('t.g1')::jsonb->>'guest_member_id')::uuid and waiver_signed_at is not null), 1);
-- check-in now succeeds
do $$
declare v_guest uuid := (current_setting('t.g1')::jsonb->>'guest_member_id')::uuid; v_ok boolean := false;
begin
  insert into check_ins (studio_id, member_id, occurrence_id, booking_id, checked_in_at, method)
  values ('9e579e57-0000-0000-0000-000000000001', v_guest, '9e579e57-0000-0000-0000-00000000c001',
          (current_setting('t.g1')::jsonb->>'guest_booking_id')::uuid, now(), 'staff');
  v_ok := true;
  perform expect_true('a signed guest checks in', v_ok);
end $$;

-- =============================================================================
-- 9. The guest account claims and becomes an ordinary member.
-- =============================================================================
-- Pull the raw token out of the queued invite email (the app's real path).
select set_config('t.claim', (claim_member_account(
   (select split_part(payload->>'claim_url','/claim/',2) from notifications
      where template_key='guest_invite'
        and member_id=(current_setting('t.g2')::jsonb->>'guest_member_id')::uuid limit 1),
   'guest-password-123', 'Gwen Guest'))::text, false);
select expect_text('the guest claim has no failure',
  (current_setting('t.claim')::member_claim).failure_reason, null);
select expect_num('the guest member now has a login',
  (select count(*) from members where id=(current_setting('t.g2')::jsonb->>'guest_member_id')::uuid and user_id is not null), 1);
select expect_num('the invite is marked accepted',
  (select count(*) from member_invites where member_id=(current_setting('t.g2')::jsonb->>'guest_member_id')::uuid and accepted_at is not null), 1);

-- =============================================================================
-- 10. A studio with the feature OFF sees nothing.
-- =============================================================================
select expect_text('eligibility says not_enabled for studio C',
  guest_pass_eligibility('9e579e57-0000-0000-0000-000000000003','9e579e57-0000-0000-0000-0000000d0a01','x@example.com')->>'reason', 'not_enabled');
select expect_true('the guest KPI is null for a studio with the feature off',
  dashboard_guest_kpi('9e579e57-0000-0000-0000-000000000003') is null);

-- =============================================================================
-- 11. Two studios in one run — B works independently, and the report counts B's own.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','9e579e57-0000-0000-0000-000000000e02',false);
select set_config('t.gb', (book_guest('9e579e57-0000-0000-0000-00000000c00b','bguest@example.com','B','Guest'))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_true('studio B host brings a guest', (current_setting('t.gb')::jsonb->>'ok')::boolean);
select expect_num('B booked_count is 2', (select booked_count from class_occurrences where id='9e579e57-0000-0000-0000-00000000c00b'), 2);
select expect_num('A''s report counts only A''s guests',
  (guest_pass_report('9e579e57-0000-0000-0000-000000000001')->>'total')::bigint, 2);
select expect_num('B''s report counts only B''s one guest',
  (guest_pass_report('9e579e57-0000-0000-0000-000000000002')->>'total')::bigint, 1);

-- =============================================================================
-- 12. The waiver chase (migration 128). An unsigned guest within a few hours of
--     the class is reminded, and their host is nudged — each once.
-- =============================================================================
-- t.g2's guest is claimed (section 9) but has NOT signed; their class is ~2h
-- out, so the sweep should catch them.
select set_config('t.sweep1', (sweep_guest_waivers())::text, false);
select expect_num('the unsigned guest is reminded',
  (select count(*) from notifications where template_key='guest_waiver_reminder'
     and member_id=(current_setting('t.g2')::jsonb->>'guest_member_id')::uuid), 1);
select expect_num('the host is nudged about their guest',
  (select count(*) from notifications where template_key='guest_waiver_host_nudge'
     and member_id='9e579e57-0000-0000-0000-0000000d0a01'), 1);
select set_config('t.sweep2', (sweep_guest_waivers())::text, false);
select expect_num('a second sweep reminds nobody twice',
  (select count(*) from notifications where template_key='guest_waiver_reminder'
     and member_id=(current_setting('t.g2')::jsonb->>'guest_member_id')::uuid), 1);

-- =============================================================================
-- 13. The paper fallback. Front desk files the waiver signed on paper through
--     record_document, which confirms the pass and clears the check-in gate.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','9e579e57-0000-0000-0000-0000000000a1',false);  -- desk
select set_config('t.paper', (record_document(
   (current_setting('t.g2')::jsonb->>'guest_member_id')::uuid,
   'waiver', 'Paper waiver.pdf', 'guest/paper/'||(current_setting('t.g2')::jsonb->>'guest_member_id'),
   null, null, 'Signed on paper at the desk', now()))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_true('the paper waiver was recorded', (current_setting('t.paper')::jsonb->>'ok')::boolean);
select expect_text('filing the paper waiver confirms the pass',
  (select status from guest_passes where guest_member_id=(current_setting('t.g2')::jsonb->>'guest_member_id')::uuid), 'confirmed');
select expect_num('the guest waiver is now signed',
  (select count(*) from members where id=(current_setting('t.g2')::jsonb->>'guest_member_id')::uuid and waiver_signed_at is not null), 1);
-- and the check-in the gate would have blocked now goes through
do $$
declare v_guest uuid := (current_setting('t.g2')::jsonb->>'guest_member_id')::uuid; v_ok boolean := false;
begin
  insert into check_ins (studio_id, member_id, occurrence_id, booking_id, checked_in_at, method)
  values ('9e579e57-0000-0000-0000-000000000001', v_guest, '9e579e57-0000-0000-0000-00000000c0e1',
          (current_setting('t.g2')::jsonb->>'guest_booking_id')::uuid, now(), 'staff');
  v_ok := true;
  perform expect_true('the guest with a paper waiver checks in', v_ok);
end $$;

do $$ begin raise notice 'guest_pass_test: all assertions passed'; end $$;
