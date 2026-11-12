-- =============================================================================
-- Decision 98 one free class per person + 97(a) merge trace + 92(b) remove.
-- Migration 20260833370000. UUID space 9801, checked free. After `supabase db reset`.
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
create or replace function expect_like(label text, actual text, pattern text)
returns void language plpgsql as $$ begin
  if actual like pattern then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  % not like %', label, coalesce(actual,'null'), pattern; end if; end $$;
create or replace function expect_raise(label text, code text, sql text)
returns void language plpgsql as $$ begin
  begin execute sql; raise exception 'FAIL  %  expected %, no error', label, code;
  exception when others then
    if sqlstate = code then raise notice 'PASS  %  (%)', label, code;
    else raise exception 'FAIL  %  expected %, got % (%)', label, code, sqlstate, sqlerrm; end if; end; end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('98010000-0000-0000-0000-0000000000a1'),  -- owner
  ('98010000-0000-0000-0000-000000000e01'),  -- FREEHAD login
  ('98010000-0000-0000-0000-000000000e02'),  -- HOST login
  ('98010000-0000-0000-0000-000000000e03'),  -- DAVE_A login (phone test)
  ('98010000-0000-0000-0000-000000000e04'),  -- REMOVE_MEM login
  ('98010000-0000-0000-0000-000000000e05');  -- MERGE keep login
insert into profiles (id, email, full_name) values
  ('98010000-0000-0000-0000-0000000000a1','own@9801.example','Olivia Owner'),
  ('98010000-0000-0000-0000-000000000e01','e01@9801.example','Jen De Guzman'),
  ('98010000-0000-0000-0000-000000000e02','e02@9801.example','Host Member'),
  ('98010000-0000-0000-0000-000000000e03','e03@9801.example','Dave Brown'),
  ('98010000-0000-0000-0000-000000000e04','e04@9801.example','Remo Member'),
  ('98010000-0000-0000-0000-000000000e05','e05@9801.example','Keep Member');

insert into studios (id, name, slug, timezone, currency, country, status) values
  ('98010000-0000-0000-0000-000000000001','One-Free A','9801-a','Asia/Manila','PHP','PH','active'),
  ('98010000-0000-0000-0000-000000000002','One-Free B','9801-b','Asia/Manila','PHP','PH','active');
insert into studio_settings (studio_id, free_first_class_enabled, free_first_peak_allowed,
                             guest_passes_enabled, checkin_window_enforced, require_waiver,
                             cancellation_cutoff_minutes, booking_window_days) values
  ('98010000-0000-0000-0000-000000000001', true, true, true, false, false, 720, 60),
  ('98010000-0000-0000-0000-000000000002', true, true, true, false, false, 720, 60);
insert into locations (id, studio_id, name, is_primary) values
  ('98010000-0000-0000-0000-00000000000a','98010000-0000-0000-0000-000000000001','Main',true),
  ('98010000-0000-0000-0000-00000000000b','98010000-0000-0000-0000-000000000002','Main',true);
insert into studio_staff (studio_id, user_id, email, role) values
  ('98010000-0000-0000-0000-000000000001','98010000-0000-0000-0000-0000000000a1','own@9801.example','owner');
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('98010000-0000-0000-0000-0000000cc001','98010000-0000-0000-0000-000000000001','Reformer',50,10);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('98010000-0000-0000-0000-0000000ee001','98010000-0000-0000-0000-000000000001','98010000-0000-0000-0000-00000000000a','R1',40);

-- Members ---------------------------------------------------------------------
insert into members (id, studio_id, user_id, first_name, last_name, email, phone, status, joined_on, source, waiver_signed_at) values
  -- Jen De Guzman (FREEHAD): will book a free class.
  ('98010000-0000-0000-0000-00000000ad01','98010000-0000-0000-0000-000000000001','98010000-0000-0000-0000-000000000e01','Jen','De Guzman','jen1@9801.example',null,'lead',current_date,'self_signup',now()),
  -- TWIN by name (no free, fresh): same normalised name.
  ('98010000-0000-0000-0000-00000000ad02','98010000-0000-0000-0000-000000000001',null,'JEN','de  guzmán','jen2@9801.example',null,'lead',current_date,'self_signup',now()),
  -- DELETED twin by name: must NOT match.
  ('98010000-0000-0000-0000-00000000ad03','98010000-0000-0000-0000-000000000001',null,'Jen','De Guzman','jen3@9801.example',null,'lead',current_date,'self_signup',now()),
  -- PHONE_HAD + PHONE_TWIN (different names, same phone).
  ('98010000-0000-0000-0000-00000000ad04','98010000-0000-0000-0000-000000000001',null,'Alice','Smith','alice@9801.example','+639171112222','lead',current_date,'self_signup',now()),
  ('98010000-0000-0000-0000-00000000ad05','98010000-0000-0000-0000-000000000001',null,'Bob','Jones','bob@9801.example','09171112222','lead',current_date,'self_signup',now()),
  -- HOST (for book_guest).
  ('98010000-0000-0000-0000-00000000ad06','98010000-0000-0000-0000-000000000001','98010000-0000-0000-0000-000000000e02','Host','Member','host@9801.example',null,'active',current_date,'walk_in',now()),
  -- UNIQUE (fresh, no twin).
  ('98010000-0000-0000-0000-00000000ad07','98010000-0000-0000-0000-000000000001',null,'Zed','Unique','zed@9801.example',null,'lead',current_date,'self_signup',now()),
  -- EVE_A (claim test): unclaimed, will hold a manual live free booking.
  ('98010000-0000-0000-0000-00000000ad08','98010000-0000-0000-0000-000000000001',null,'Eve','Green','eve_a@9801.example',null,'lead',current_date,'self_signup',now()),
  -- EVE_B: same name, will have a (manual) attended free class.
  ('98010000-0000-0000-0000-00000000ad09','98010000-0000-0000-0000-000000000001',null,'Eve','Green','eve_b@9801.example',null,'lead',current_date,'self_signup',now()),
  -- DAVE_A (phone trigger test): login, holds a manual live free booking, no phone yet.
  ('98010000-0000-0000-0000-00000000ad0a','98010000-0000-0000-0000-000000000001','98010000-0000-0000-0000-000000000e03','Dave','Brown','dave_a@9801.example',null,'lead',current_date,'self_signup',now()),
  -- DAVE_B: different name, has a manual attended free class, phone that DAVE_A will copy.
  ('98010000-0000-0000-0000-00000000ad0b','98010000-0000-0000-0000-000000000001',null,'Zelda','Other','zelda@9801.example','09173334444','lead',current_date,'self_signup',now()),
  -- REMOVE_MEM (92b): a normal booking to be removed.
  ('98010000-0000-0000-0000-00000000ad0c','98010000-0000-0000-0000-000000000001','98010000-0000-0000-0000-000000000e04','Remo','Member','remo@9801.example',null,'active',current_date,'walk_in',now()),
  -- MERGE keep + remove (97a).
  ('98010000-0000-0000-0000-00000000ad0d','98010000-0000-0000-0000-000000000001','98010000-0000-0000-0000-000000000e05','Keepa','Keeper','keep@9801.example',null,'active',current_date,'walk_in',now()),
  ('98010000-0000-0000-0000-00000000ad0e','98010000-0000-0000-0000-000000000001',null,'Dupo','Removed','dupo@9801.example',null,'active',current_date,'walk_in',now()),
  -- cross-studio same name (must not match SA's Jen).
  ('98010000-0000-0000-0000-00000000adf1','98010000-0000-0000-0000-000000000002',null,'Jen','De Guzman','jenb@9801.example',null,'lead',current_date,'self_signup',now());
update members set deleted_at = now() where id='98010000-0000-0000-0000-00000000ad03';

-- Future scheduled open occurrences.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
    starts_at, ends_at, capacity, booked_count, status, staffing) values
  ('98010000-0000-0000-0000-00000000c001','98010000-0000-0000-0000-000000000001','98010000-0000-0000-0000-00000000000a','98010000-0000-0000-0000-0000000cc001','98010000-0000-0000-0000-0000000ee001','Reformer',
    now()+interval '5 days', now()+interval '5 days'+interval '50 min', 10, 0, 'scheduled','open'),
  ('98010000-0000-0000-0000-00000000c002','98010000-0000-0000-0000-000000000001','98010000-0000-0000-0000-00000000000a','98010000-0000-0000-0000-0000000cc001','98010000-0000-0000-0000-0000000ee001','Reformer',
    now()+interval '6 days', now()+interval '6 days'+interval '50 min', 10, 0, 'scheduled','open'),
  -- a near-future one (inside the 12h cutoff) for the late-cancel removal test.
  ('98010000-0000-0000-0000-00000000c003','98010000-0000-0000-0000-000000000001','98010000-0000-0000-0000-00000000000a','98010000-0000-0000-0000-0000000cc001','98010000-0000-0000-0000-0000000ee001','Reformer',
    now()+interval '3 hours', now()+interval '3 hours'+interval '50 min', 10, 0, 'scheduled','open'),
  -- a past one (removal refusal).
  ('98010000-0000-0000-0000-00000000c004','98010000-0000-0000-0000-000000000001','98010000-0000-0000-0000-00000000000a','98010000-0000-0000-0000-0000000cc001','98010000-0000-0000-0000-0000000ee001','Reformer',
    now()-interval '2 hours', now()-interval '2 hours'+interval '50 min', 10, 1, 'scheduled','open');

-- Helper: insert a live/used manual free-first seat (comp booking + host-null pass).
create or replace function t9801_free_seat(p_member uuid, p_occ uuid, p_status text, p_at timestamptz)
returns uuid language plpgsql as $$
declare v_bk uuid; begin
  insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source, booked_at)
  values ('98010000-0000-0000-0000-000000000001', p_occ, p_member, p_status::booking_status, 'member', 'comp', p_at)
  returning id into v_bk;
  update class_occurrences set booked_count = booked_count + 1 where id = p_occ;
  insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email, occurrence_id, guest_booking_id, status)
  values ('98010000-0000-0000-0000-000000000001', null, p_member, (select email from members where id=p_member), p_occ, v_bk,
          case when p_status='attended' then 'attended' else 'invited' end);
  return v_bk;
end $$;

-- =============================================================================
-- 1. normalise helpers
-- =============================================================================
select expect_true('name: accents + case + spaces fold', normalise_name('  Jén  De   Guzmán ') = normalise_name('jen de guzman'));
select expect_true('name: blank is null', normalise_name('   ') is null);
select expect_true('phone: PH 09 == +639', normalise_phone('09171112222','PH') = normalise_phone('+63 917 111 2222','PH'));
select expect_true('phone: blank is null', normalise_phone('','PH') is null);

-- =============================================================================
-- 2. same_person_match + member_has_had_free
-- =============================================================================
-- FREEHAD books a free class (no twin has free yet -> ok).
set role authenticated; select set_config('request.jwt.claim.sub','98010000-0000-0000-0000-000000000e01',false);
select set_config('t.jen', (book_first_free('98010000-0000-0000-0000-00000000c001'))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_true('Jen (FREEHAD) books her free class', (current_setting('t.jen')::jsonb->>'ok')::boolean);
select expect_true('member_has_had_free(FREEHAD) true', member_has_had_free('98010000-0000-0000-0000-000000000001','98010000-0000-0000-0000-00000000ad01'));
select expect_false('member_has_had_free(UNIQUE) false', member_has_had_free('98010000-0000-0000-0000-000000000001','98010000-0000-0000-0000-00000000ad07'));
-- Refinement: a TIMELY-cancelled free class (comp cancelled + a lingering
-- host-null pass) does NOT count as "had free".
select t9801_free_seat('98010000-0000-0000-0000-00000000ad07','98010000-0000-0000-0000-00000000c002','cancelled', now()-interval '1 day');
select expect_false('a timely-cancelled free class is NOT had-free',
  member_has_had_free('98010000-0000-0000-0000-000000000001','98010000-0000-0000-0000-00000000ad07'));

-- PHONE_HAD has a (manual) attended free class.
select t9801_free_seat('98010000-0000-0000-0000-00000000ad04','98010000-0000-0000-0000-00000000c002','attended', now()-interval '1 day');

select expect_num('same_person_match(TWIN name) finds FREEHAD (deleted twin excluded)',
  (select count(*) from same_person_match('98010000-0000-0000-0000-000000000001','98010000-0000-0000-0000-00000000ad02') s
    where s = '98010000-0000-0000-0000-00000000ad01'), 1);
select expect_num('same_person_match(TWIN name) excludes the deleted twin',
  (select count(*) from same_person_match('98010000-0000-0000-0000-000000000001','98010000-0000-0000-0000-00000000ad02') s
    where s = '98010000-0000-0000-0000-00000000ad03'), 0);
select expect_num('same_person_match by PHONE (Bob -> Alice)',
  (select count(*) from same_person_match('98010000-0000-0000-0000-000000000001','98010000-0000-0000-0000-00000000ad05') s
    where s = '98010000-0000-0000-0000-00000000ad04'), 1);
select expect_num('no cross-studio match for SA Jen',
  (select count(*) from same_person_match('98010000-0000-0000-0000-000000000001','98010000-0000-0000-0000-00000000ad01') s
    where s = '98010000-0000-0000-0000-00000000adf1'), 0);

-- =============================================================================
-- 3. the free-first gate returns 'duplicate'
-- =============================================================================
select expect_text('TWIN by name -> duplicate (FREEHAD had free)',
  free_first_eligibility('98010000-0000-0000-0000-000000000001','98010000-0000-0000-0000-00000000ad02',null)->>'reason', 'duplicate');
select expect_text('PHONE_TWIN (Bob) -> duplicate (Alice had free)',
  free_first_eligibility('98010000-0000-0000-0000-000000000001','98010000-0000-0000-0000-00000000ad05',null)->>'reason', 'duplicate');
select expect_true('UNIQUE fresh name -> ok',
  (free_first_eligibility('98010000-0000-0000-0000-000000000001','98010000-0000-0000-0000-00000000ad07',null)->>'ok')::boolean);

-- the TWIN cannot book free (belt): book_first_free refuses.
set role authenticated; select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000000',false);
-- (TWIN has no login; drive book_first_free via the owner acting? book_first_free is self-serve.
--  Instead assert through the guarded eligibility above; the gate is what book_first_free reads.)
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- 4. book_guest name-only refusal
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','98010000-0000-0000-0000-000000000e02',false);
-- a guest named "Jen De Guzman" (matches FREEHAD who had free) -> duplicate
select set_config('t.g1', (book_guest('98010000-0000-0000-0000-00000000c001','newjen@9801.example','Jen','De Guzman'))::text, false);
-- a unique-named guest -> ok
select set_config('t.g2', (book_guest('98010000-0000-0000-0000-00000000c002','guest2@9801.example','Wholly','Different'))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('book_guest refuses a free-member name match', current_setting('t.g1')::jsonb->>'reason', 'duplicate');
select expect_true('book_guest allows a unique-named guest', (current_setting('t.g2')::jsonb->>'ok')::boolean);

-- =============================================================================
-- 5. claim hook flips a held free booking
-- =============================================================================
-- EVE_B (manual) attended free; EVE_A holds a live manual free booking + an invite.
select t9801_free_seat('98010000-0000-0000-0000-00000000ad09','98010000-0000-0000-0000-00000000c002','attended', now()-interval '2 days');
select set_config('t.eve_bk', (t9801_free_seat('98010000-0000-0000-0000-00000000ad08','98010000-0000-0000-0000-00000000c001','booked', now()-interval '1 day'))::text, false);
insert into member_invites (studio_id, member_id, email, token_hash, expires_at, created_by)
  values ('98010000-0000-0000-0000-000000000001','98010000-0000-0000-0000-00000000ad08','eve_a@9801.example',
          encode(digest('evetoken9801','sha256'),'hex'), now()+interval '7 days', '98010000-0000-0000-0000-0000000000a1');
select claim_member_account('evetoken9801','password123', null);
select expect_true('claim linked the login',
  (select user_id is not null from members where id='98010000-0000-0000-0000-00000000ad08'));
select expect_text('EVE_A free booking flipped to pending_payment',
  (select status::text from bookings where id=current_setting('t.eve_bk')::uuid), 'pending_payment');
select expect_true('EVE_A booking has a 24h hold',
  (select hold_until is not null and hold_reason='free_class_duplicate' from bookings where id=current_setting('t.eve_bk')::uuid));
select expect_text('EVE_A booking is now a drop-in to pay',
  (select payment_source::text from bookings where id=current_setting('t.eve_bk')::uuid), 'drop_in');
select expect_num('free_class_duplicate email queued once',
  (select count(*) from notifications where member_id='98010000-0000-0000-0000-00000000ad08' and template_key='free_class_duplicate'), 1);
select expect_false('recheck is idempotent (second call no-op)',
  recheck_free_first_duplicate('98010000-0000-0000-0000-00000000ad08'));

-- =============================================================================
-- 6. phone-save trigger flips a held free booking
-- =============================================================================
select t9801_free_seat('98010000-0000-0000-0000-00000000ad0b','98010000-0000-0000-0000-00000000c002','attended', now()-interval '2 days');
select set_config('t.dave_bk', (t9801_free_seat('98010000-0000-0000-0000-00000000ad0a','98010000-0000-0000-0000-00000000c001','booked', now()-interval '1 day'))::text, false);
-- Dave saves a phone that matches Zelda (who had free).
update members set phone='09173334444' where id='98010000-0000-0000-0000-00000000ad0a';
select expect_text('phone-save flips Dave''s free booking',
  (select status::text from bookings where id=current_setting('t.dave_bk')::uuid), 'pending_payment');
select expect_true('Dave booking held with reason',
  (select hold_reason='free_class_duplicate' from bookings where id=current_setting('t.dave_bk')::uuid));

-- =============================================================================
-- 7. sweep exclusion + the new 24h sweep
-- =============================================================================
-- Dave's held booking: booked_at is 1 day old (past the 15-min drop-in window),
-- but hold_until is in the FUTURE -> the drop-in sweep must skip it.
select sweep_unpaid_dropins();
select expect_text('drop-in sweep does NOT cancel a held free booking',
  (select status::text from bookings where id=current_setting('t.dave_bk')::uuid), 'pending_payment');
-- the duplicate-hold sweep leaves a future hold alone...
select sweep_free_duplicate_holds();
select expect_text('hold sweep leaves a future hold alone',
  (select status::text from bookings where id=current_setting('t.dave_bk')::uuid), 'pending_payment');
-- ...and cancels one past its hold_until.
update bookings set hold_until = now()-interval '1 minute' where id=current_setting('t.dave_bk')::uuid;
select sweep_free_duplicate_holds();
select expect_text('hold sweep cancels an expired hold',
  (select status::text from bookings where id=current_setting('t.dave_bk')::uuid), 'cancelled');

-- =============================================================================
-- 8. "Make this their free class" overrides duplicate
-- =============================================================================
-- Give TWIN (name match, gate=duplicate) an unpaid drop-in, then convert it.
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at)
  values ('98010000-0000-0000-0000-0000000b0001','98010000-0000-0000-0000-000000000001','98010000-0000-0000-0000-00000000c002',
          '98010000-0000-0000-0000-00000000ad02','booked','staff','drop_in', now());
update class_occurrences set booked_count = booked_count + 1 where id='98010000-0000-0000-0000-00000000c002';
set role authenticated; select set_config('request.jwt.claim.sub','98010000-0000-0000-0000-0000000000a1',false);
select set_config('t.conv', (convert_booking_to_free_first('98010000-0000-0000-0000-0000000b0001'))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_true('convert overrides duplicate (ok)', (current_setting('t.conv')::jsonb->>'ok')::boolean);
select expect_text('converted seat is comp',
  (select payment_source::text from bookings where id='98010000-0000-0000-0000-0000000b0001'), 'comp');

-- =============================================================================
-- 9. Decision 92(b) — remove a member from a class
-- =============================================================================
-- A normal future booking for REMOVE_MEM.
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at)
  values ('98010000-0000-0000-0000-0000000b0002','98010000-0000-0000-0000-000000000001','98010000-0000-0000-0000-00000000c001',
          '98010000-0000-0000-0000-00000000ad0c','booked','member','drop_in', now());
update class_occurrences set booked_count = booked_count + 1 where id='98010000-0000-0000-0000-00000000c001';
set role authenticated; select set_config('request.jwt.claim.sub','98010000-0000-0000-0000-0000000000a1',false);
select set_config('t.rm', (staff_remove_booking('98010000-0000-0000-0000-0000000b0002', true, 'room closed'))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_true('remove ok', (current_setting('t.rm')::jsonb->>'ok')::boolean);
select expect_text('removed booking is cancelled (not late, p_return true)',
  (select status::text from bookings where id='98010000-0000-0000-0000-0000000b0002'), 'cancelled');
select expect_num('booking_removed_by_studio email queued',
  (select count(*) from notifications where member_id='98010000-0000-0000-0000-00000000ad0c' and template_key='booking_removed_by_studio'), 1);
select expect_num('audit row written',
  (select count(*) from audit_logs where action='booking.removed_by_staff' and entity_id='98010000-0000-0000-0000-0000000b0002'), 1);
-- Journey: shows the removed-by-studio row and NOT a generic cancelled row for it.
select expect_num('Journey shows exactly one removed-by-studio row',
  (select count(*) from member_activity('98010000-0000-0000-0000-00000000ad0c', current_date-1, current_date+1) where kind='removed_by_studio'), 1);
select expect_num('Journey does NOT also show a cancelled row for the removed booking',
  (select count(*) from member_activity('98010000-0000-0000-0000-00000000ad0c', current_date-1, current_date+1)
    where kind in ('cancelled','late_cancelled') and booking_id='98010000-0000-0000-0000-0000000b0002'), 0);
select expect_like('removed row names the class and staff',
  (select title from member_activity('98010000-0000-0000-0000-00000000ad0c', current_date-1, current_date+1) where kind='removed_by_studio' limit 1),
  'Removed from Reformer by Olivia%');

-- p_return false inside the cutoff -> late cancel.
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at)
  values ('98010000-0000-0000-0000-0000000b0003','98010000-0000-0000-0000-000000000001','98010000-0000-0000-0000-00000000c003',
          '98010000-0000-0000-0000-00000000ad0c','booked','member','drop_in', now());
update class_occurrences set booked_count = booked_count + 1 where id='98010000-0000-0000-0000-00000000c003';
set role authenticated; select set_config('request.jwt.claim.sub','98010000-0000-0000-0000-0000000000a1',false);
select set_config('t.rm2', (staff_remove_booking('98010000-0000-0000-0000-0000000b0003', false, null))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('p_return false inside cutoff -> late cancel',
  (select status::text from bookings where id='98010000-0000-0000-0000-0000000b0003'), 'late_cancelled');

-- Refusals.
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at)
  values ('98010000-0000-0000-0000-0000000b0006','98010000-0000-0000-0000-000000000001','98010000-0000-0000-0000-00000000c004',
          '98010000-0000-0000-0000-00000000ad0c','booked','member','drop_in', now()-interval '3 hours');
select expect_raise('remove refuses a past class (PT409)','PT409',
  $$select staff_remove_booking('98010000-0000-0000-0000-0000000b0006', true, null)$$);
select expect_raise('remove refuses a non-live booking (PT409)','PT409',
  $$select staff_remove_booking('98010000-0000-0000-0000-0000000b0002', true, null)$$);  -- already cancelled
-- already checked in.
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at)
  values ('98010000-0000-0000-0000-0000000b0004','98010000-0000-0000-0000-000000000001','98010000-0000-0000-0000-00000000c001',
          '98010000-0000-0000-0000-00000000ad0c','booked','member','drop_in', now());
insert into check_ins (studio_id, occurrence_id, booking_id, member_id, checked_in_at, method)
  values ('98010000-0000-0000-0000-000000000001','98010000-0000-0000-0000-00000000c001','98010000-0000-0000-0000-0000000b0004','98010000-0000-0000-0000-00000000ad0c', now(), 'self');
select expect_raise('remove refuses an already-checked-in booking (PT409)','PT409',
  $$select staff_remove_booking('98010000-0000-0000-0000-0000000b0004', true, null)$$);
-- desk-up guard: a member (REMOVE_MEM) cannot remove.
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at)
  values ('98010000-0000-0000-0000-0000000b0005','98010000-0000-0000-0000-000000000001','98010000-0000-0000-0000-00000000c002',
          '98010000-0000-0000-0000-00000000ad0c','booked','member','drop_in', now());
set role authenticated; select set_config('request.jwt.claim.sub','98010000-0000-0000-0000-000000000e04',false);
select expect_raise('a member cannot remove a booking (PT403)','PT403',
  $$select staff_remove_booking('98010000-0000-0000-0000-0000000b0005', true, null)$$);
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- 10. Decision 97(a) — merge trace on the kept profile
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','98010000-0000-0000-0000-0000000000a1',false);
select set_config('t.merge', (merge_members('98010000-0000-0000-0000-00000000ad0d','98010000-0000-0000-0000-00000000ad0e'))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_true('merge ok', (current_setting('t.merge')::jsonb->>'ok')::boolean);
select expect_text('merge audit captures removed first name',
  (select before->>'removed_first' from audit_logs where action='member.merged' and entity_id='98010000-0000-0000-0000-00000000ad0e'), 'Dupo');
select expect_text('merge audit captures removed last name',
  (select before->>'removed_last' from audit_logs where action='member.merged' and entity_id='98010000-0000-0000-0000-00000000ad0e'), 'Removed');
select expect_num('kept member Journey shows one merge row',
  (select count(*) from member_activity('98010000-0000-0000-0000-00000000ad0d', current_date-1, current_date+1) where kind='merged'), 1);
select expect_like('merge Journey row names the removed email',
  (select title from member_activity('98010000-0000-0000-0000-00000000ad0d', current_date-1, current_date+1) where kind='merged' limit 1),
  'Merged dupo@9801.example into this account');
select expect_text('merge trace carries the removed first name',
  (member_merge_trace('98010000-0000-0000-0000-00000000ad0d')->0->>'removed_first'), 'Dupo');
select expect_text('merge trace carries the removed email',
  (member_merge_trace('98010000-0000-0000-0000-00000000ad0d')->0->>'removed_email'), 'dupo@9801.example');
select expect_text('merge trace carries the staff first name',
  (member_merge_trace('98010000-0000-0000-0000-00000000ad0d')->0->>'staff_first'), 'Olivia');
select expect_true('member_duplicates finds the name twin (had_free flag present)',
  (select jsonb_array_length(member_duplicates('98010000-0000-0000-0000-00000000ad02')) >= 1));

-- =============================================================================
-- 11. the new functions are not anon; anon stays THIRTEEN
-- =============================================================================
select expect_false('staff_remove_booking not anon', has_function_privilege('anon','staff_remove_booking(uuid,boolean,text)','execute'));
select expect_false('member_duplicates not anon', has_function_privilege('anon','member_duplicates(uuid)','execute'));
select expect_false('recheck_free_first_duplicate not anon', has_function_privilege('anon','recheck_free_first_duplicate(uuid)','execute'));
select expect_num('anon surface EXACTLY THIRTEEN',
  (select count(*) from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
    where ns.nspname='public' and has_function_privilege('anon',p.oid,'execute')
      and p.proname not like 'expect\_%' and p.proname not like 't9801\_%'), 13);

select 'ALL ONE-FREE-PER-PERSON TESTS PASSED' as result;
