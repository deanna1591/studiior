-- =============================================================================
-- Free first class — Decision 30, migration 20260831630000
-- =============================================================================
-- UUID space f9ee, checked free. Run after `supabase db reset`.
--
-- A self-signup books their first class at zero cost; the same person is refused
-- a second free class; a guest is refused a free signup class and a signup is
-- refused as a guest (the shared once-ever ledger, both doors); a studio with it
-- off sees nothing; an unsigned waiver books but cannot check in until signed;
-- turning it off leaves an existing free booking alone; the conversion report
-- counts the signup route; two studios with different settings in one run.
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
  ('f9eef9ee-0000-0000-0000-0000000000a1'),  -- owner (A + B desk)
  ('f9eef9ee-0000-0000-0000-000000000e01'),  -- NEW1  (self-signup, books free at A)
  ('f9eef9ee-0000-0000-0000-000000000e02'),  -- HOST  (brings a guest at A)
  ('f9eef9ee-0000-0000-0000-000000000e03'),  -- GVERT (guest who later signs up: cross-door)
  ('f9eef9ee-0000-0000-0000-000000000e04'),  -- BMEM  (member at studio B, feature off)
  ('f9eef9ee-0000-0000-0000-000000000e05');  -- NEW2  (books free after off? — for "off leaves existing")
insert into profiles (id, email)
  select id, id::text||'@example.com' from auth.users where id::text like 'f9eef9ee%';

insert into studios (id, name, slug, timezone, currency, status) values
  ('f9eef9ee-0000-0000-0000-000000000001','Free A','f9ee-a','Europe/Prague','CZK','active'),
  ('f9eef9ee-0000-0000-0000-000000000002','Free B','f9ee-b','Asia/Manila','PHP','active');
-- A runs the free first class AND guest passes (so the cross-door check is real);
-- B has the free first class OFF. Waiver required, check-in window off so the
-- waiver gate is isolated.
insert into studio_settings (studio_id, free_first_class_enabled, free_first_peak_allowed,
                             guest_passes_enabled, checkin_window_enforced, require_waiver,
                             booking_window_days) values
  ('f9eef9ee-0000-0000-0000-000000000001', true,  true,  true,  false, true, 30),
  ('f9eef9ee-0000-0000-0000-000000000002', false, true,  false, false, true, 30);
insert into locations (id, studio_id, name, is_primary) values
  ('f9eef9ee-0000-0000-0000-00000000000a','f9eef9ee-0000-0000-0000-000000000001','Main',true),
  ('f9eef9ee-0000-0000-0000-00000000000b','f9eef9ee-0000-0000-0000-000000000002','Main',true);
insert into studio_staff (studio_id, user_id, email, role) values
  ('f9eef9ee-0000-0000-0000-000000000001','f9eef9ee-0000-0000-0000-0000000000a1','f9ee-owa@example.com','owner'),
  ('f9eef9ee-0000-0000-0000-000000000002','f9eef9ee-0000-0000-0000-0000000000a1','f9ee-owb@example.com','owner');
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('f9eef9ee-0000-0000-0000-0000000cc001','f9eef9ee-0000-0000-0000-000000000001','Reformer',50,10),
  ('f9eef9ee-0000-0000-0000-0000000cc002','f9eef9ee-0000-0000-0000-000000000002','Reformer',50,10);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('f9eef9ee-0000-0000-0000-0000000ee001','f9eef9ee-0000-0000-0000-000000000001','f9eef9ee-0000-0000-0000-00000000000a','R1',20),
  ('f9eef9ee-0000-0000-0000-0000000ee002','f9eef9ee-0000-0000-0000-000000000001','f9eef9ee-0000-0000-0000-00000000000a','R2',20),
  ('f9eef9ee-0000-0000-0000-0000000ee00b','f9eef9ee-0000-0000-0000-000000000002','f9eef9ee-0000-0000-0000-00000000000b','R1',20);

-- Members: NEW1 (fresh self-signup lead, waiver UNSIGNED), a HOST (member with a
-- signed waiver), BMEM at studio B, NEW2 (fresh) at A.
insert into members (id, studio_id, user_id, first_name, last_name, email, status, joined_on, source, waiver_signed_at) values
  ('f9eef9ee-0000-0000-0000-00000000ad01','f9eef9ee-0000-0000-0000-000000000001','f9eef9ee-0000-0000-0000-000000000e01','New','One','new1@example.com','lead',current_date,'self_signup', null),
  ('f9eef9ee-0000-0000-0000-00000000ad02','f9eef9ee-0000-0000-0000-000000000001','f9eef9ee-0000-0000-0000-000000000e02','Host','Member','host@example.com','active',current_date,'walk_in', now()),
  ('f9eef9ee-0000-0000-0000-00000000ad04','f9eef9ee-0000-0000-0000-000000000002','f9eef9ee-0000-0000-0000-000000000e04','B','Member','bmem@example.com','lead',current_date,'self_signup', now()),
  ('f9eef9ee-0000-0000-0000-00000000ad05','f9eef9ee-0000-0000-0000-000000000001','f9eef9ee-0000-0000-0000-000000000e05','New','Two','new2@example.com','lead',current_date,'self_signup', now());

-- Item 1: an existing member under a Gmail variant. VERA is already a member as
-- a.b@gmail.com; VIC is a fresh signup as ab+x@gmail.com (same normalized key);
-- FREDA is a spare host with no live guest. normalize_email_key folds both Gmail
-- addresses to ab@gmail.com, so the variant must be caught at both doors.
insert into members (id, studio_id, first_name, last_name, email, status, joined_on, source) values
  ('f9eef9ee-0000-0000-0000-00000000ad06','f9eef9ee-0000-0000-0000-000000000001','Vera','Existing','a.b@gmail.com','active',current_date,'walk_in'),
  ('f9eef9ee-0000-0000-0000-00000000ad07','f9eef9ee-0000-0000-0000-000000000001','Vic','Variant','ab+x@gmail.com','lead',current_date,'self_signup'),
  ('f9eef9ee-0000-0000-0000-00000000ad08','f9eef9ee-0000-0000-0000-000000000001','Freda','Host','freshhost@example.com','active',current_date,'walk_in');

-- Future scheduled classes, inside the window, publication off => month_published true.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name,
    starts_at, ends_at, capacity, booked_count, status, staffing) values
  ('f9eef9ee-0000-0000-0000-00000000c001','f9eef9ee-0000-0000-0000-000000000001','f9eef9ee-0000-0000-0000-00000000000a','f9eef9ee-0000-0000-0000-0000000cc001','f9eef9ee-0000-0000-0000-0000000ee001',null,'Reformer',
    now()+interval '3 days', now()+interval '3 days'+interval '50 min', 10, 0, 'scheduled','open'),
  ('f9eef9ee-0000-0000-0000-00000000c002','f9eef9ee-0000-0000-0000-000000000001','f9eef9ee-0000-0000-0000-00000000000a','f9eef9ee-0000-0000-0000-0000000cc001','f9eef9ee-0000-0000-0000-0000000ee002',null,'Reformer',
    now()+interval '4 days', now()+interval '4 days'+interval '50 min', 10, 0, 'scheduled','open'),
  ('f9eef9ee-0000-0000-0000-00000000cB01','f9eef9ee-0000-0000-0000-000000000002','f9eef9ee-0000-0000-0000-00000000000b','f9eef9ee-0000-0000-0000-0000000cc002','f9eef9ee-0000-0000-0000-0000000ee00b',null,'Reformer',
    now()+interval '3 days', now()+interval '3 days'+interval '50 min', 10, 0, 'scheduled','open');

-- =============================================================================
-- 1. A self-signup books their first class at ZERO cost.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','f9eef9ee-0000-0000-0000-000000000e01',false);
select set_config('t.f1', (book_first_free('f9eef9ee-0000-0000-0000-00000000c001'))::text, false);
-- ...and a second free class is refused for the same person.
select set_config('t.f1b', (book_first_free('f9eef9ee-0000-0000-0000-00000000c002'))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;

select expect_true('a first-timer books their free class', (current_setting('t.f1')::jsonb->>'ok')::boolean);
select expect_text('the seat is comp — nothing charged',
  (select payment_source::text from bookings where id = (current_setting('t.f1')::jsonb->>'booking_id')::uuid), 'comp');
select expect_num('booked_count moved with it',
  (select booked_count from class_occurrences where id='f9eef9ee-0000-0000-0000-00000000c001'), 1);
select expect_num('it is recorded in the shared ledger, with NO host',
  (select count(*) from guest_passes where guest_member_id='f9eef9ee-0000-0000-0000-00000000ad01' and host_member_id is null), 1);
select expect_text('a second free class is refused', current_setting('t.f1b')::jsonb->>'reason', 'already_had_free');

-- =============================================================================
-- 2. Cross-door. NEW1 took the free class via signup; a HOST trying to bring
--    new1@example.com as a guest is refused the same way.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','f9eef9ee-0000-0000-0000-000000000e02',false);
select set_config('t.gx', (book_guest('f9eef9ee-0000-0000-0000-00000000c002','new1@example.com','New','One'))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('a signup free class blocks the guest door too',
  current_setting('t.gx')::jsonb->>'reason', 'already_had_free');

-- ...and the reverse: a guest takes their free class, then signs up and is
-- refused a free signup class. The HOST brings guest 'gvert@example.com'.
set role authenticated; select set_config('request.jwt.claim.sub','f9eef9ee-0000-0000-0000-000000000e02',false);
select set_config('t.gv', (book_guest('f9eef9ee-0000-0000-0000-00000000c002','gvert@example.com','Guest','Vert'))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_true('the guest is booked', (current_setting('t.gv')::jsonb->>'ok')::boolean);
-- book_guest made a lead member with that email. Link the GVERT login to it, then
-- have them try to claim a free signup class.
update members set user_id='f9eef9ee-0000-0000-0000-000000000e03'
 where studio_id='f9eef9ee-0000-0000-0000-000000000001' and lower(email)='gvert@example.com';
set role authenticated; select set_config('request.jwt.claim.sub','f9eef9ee-0000-0000-0000-000000000e03',false);
select set_config('t.gv2', (book_first_free('f9eef9ee-0000-0000-0000-00000000c001'))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('a guest is refused a free signup class', current_setting('t.gv2')::jsonb->>'reason', 'already_had_free');

-- =============================================================================
-- 3. A studio with the feature OFF sees nothing — booking is refused not_enabled.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','f9eef9ee-0000-0000-0000-000000000e04',false);
select set_config('t.off', (book_first_free('f9eef9ee-0000-0000-0000-00000000cB01'))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('feature off => not_enabled', current_setting('t.off')::jsonb->>'reason', 'not_enabled');
select expect_text('and eligibility says not_enabled too',
  (free_first_eligibility('f9eef9ee-0000-0000-0000-000000000002','f9eef9ee-0000-0000-0000-00000000ad04')->>'reason'), 'not_enabled');

-- =============================================================================
-- 4. The unsigned waiver: NEW1 booked their free class with waiver UNSIGNED
--    (require_waiver is on) — booking is allowed, check-in is not until signed.
-- =============================================================================
-- The free booking exists despite the unsigned waiver (waiver gates CHECK-IN).
select expect_num('booked with an unsigned waiver',
  (select count(*) from bookings b join members m on m.id=b.member_id
    where b.member_id='f9eef9ee-0000-0000-0000-00000000ad01' and m.waiver_signed_at is null and b.payment_source='comp'), 1);
-- Check-in is refused until they sign.
do $$
begin
  begin
    insert into check_ins (studio_id, occurrence_id, booking_id, member_id, method)
      select b.studio_id, b.occurrence_id, b.id, b.member_id, 'staff' from bookings b
       where b.member_id='f9eef9ee-0000-0000-0000-00000000ad01' and b.payment_source='comp' limit 1;
    raise exception 'FAIL  unsigned waiver did not block check-in';
  exception when sqlstate 'PT422' then raise notice 'PASS  unsigned waiver blocks check-in';
  end;
end $$;
-- Signing it (the pass confirms) then lets them in.
set role authenticated; select set_config('request.jwt.claim.sub','f9eef9ee-0000-0000-0000-000000000e01',false);
select sign_waiver('f9eef9ee-0000-0000-0000-00000000ad01');
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('signing confirms the free-class pass',
  (select status from guest_passes where guest_member_id='f9eef9ee-0000-0000-0000-00000000ad01' and host_member_id is null), 'confirmed');
insert into check_ins (studio_id, occurrence_id, booking_id, member_id, method)
  select b.studio_id, b.occurrence_id, b.id, b.member_id, 'staff' from bookings b
   where b.member_id='f9eef9ee-0000-0000-0000-00000000ad01' and b.payment_source='comp' limit 1;
select expect_num('signed => check-in goes through',
  (select count(*) from check_ins where member_id='f9eef9ee-0000-0000-0000-00000000ad01'), 1);

-- =============================================================================
-- 5. Turning it OFF leaves an existing free booking alone — no retroactive charge.
-- =============================================================================
update studio_settings set free_first_class_enabled=false where studio_id='f9eef9ee-0000-0000-0000-000000000001';
select expect_num('NEW1 keeps their comp booking after the switch is turned off',
  (select count(*) from bookings where member_id='f9eef9ee-0000-0000-0000-00000000ad01' and payment_source='comp' and status in ('booked','attended')), 1);
select expect_num('and the ledger row still stands',
  (select count(*) from guest_passes where guest_member_id='f9eef9ee-0000-0000-0000-00000000ad01'), 1);
-- A fresh member is now refused while it is off.
set role authenticated; select set_config('request.jwt.claim.sub','f9eef9ee-0000-0000-0000-000000000e05',false);
select set_config('t.after', (book_first_free('f9eef9ee-0000-0000-0000-00000000c002'))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('and a new person cannot start a free class', current_setting('t.after')::jsonb->>'reason', 'not_enabled');
update studio_settings set free_first_class_enabled=true where studio_id='f9eef9ee-0000-0000-0000-000000000001';

-- =============================================================================
-- 6. The conversion report counts BOTH routes, each on its own door.
-- =============================================================================
-- NEW1 (signup route) buys a plan => converted. Give them a membership.
insert into membership_plans (id, studio_id, name, type, price_cents, currency, billing_interval)
  values ('f9eef9ee-0000-0000-0000-00000000bd01','f9eef9ee-0000-0000-0000-000000000001','Monthly','recurring',900000,'CZK','month');
insert into memberships (studio_id, member_id, plan_id, status, price_cents, currency, starts_on)
  values ('f9eef9ee-0000-0000-0000-000000000001','f9eef9ee-0000-0000-0000-00000000ad01','f9eef9ee-0000-0000-0000-00000000bd01','active',900000,'CZK',current_date);
-- Mark the signup class attended so conversion_rate has a denominator.
update guest_passes set status='attended' where guest_member_id='f9eef9ee-0000-0000-0000-00000000ad01' and host_member_id is null;
select expect_num('free_first_report total is the signup route only',
  (free_first_report('f9eef9ee-0000-0000-0000-000000000001')->>'total')::bigint, 1);
select expect_num('...and it counts the conversion',
  (free_first_report('f9eef9ee-0000-0000-0000-000000000001')->>'converted')::bigint, 1);
-- The guest route (gvert) is on its own report, not mixed in.
select expect_num('guest_pass_report is the guest route only (gvert)',
  (guest_pass_report('f9eef9ee-0000-0000-0000-000000000001')->>'total')::bigint, 1);
select expect_num('...and the signup class does not inflate the guest total',
  (guest_pass_report('f9eef9ee-0000-0000-0000-000000000001')->>'converted')::bigint, 0);
-- The dashboard KPI is null (absent) at studio B, which does not run it.
select expect_true('studio B free-first KPI is null (feature off)',
  dashboard_free_first_kpi('f9eef9ee-0000-0000-0000-000000000002') is null);

-- =============================================================================
-- 7. Two studios, one run: A offers it, B does not — already exercised above
--    (t.f1 ok at A, t.off not_enabled at B). One explicit cross-check.
-- =============================================================================
select expect_true('A runs it', (select free_first_class_enabled from studio_settings where studio_id='f9eef9ee-0000-0000-0000-000000000001'));
select expect_true('B does not', (select not free_first_class_enabled from studio_settings where studio_id='f9eef9ee-0000-0000-0000-000000000002'));

-- =============================================================================
-- 8. The once-ever key catches an existing member using an email VARIANT, at
--    BOTH doors. a.b@gmail.com is already a member; ab+x@gmail.com folds to the
--    same key, so a free class through either door is refused already_member.
--    (Teeth: revert the already_member comparisons to lower() and both fail.)
-- =============================================================================
reset role;
-- The probe email is a Gmail variant that NO member holds exactly (a.b@gmail.com
-- is the member; a.b+promo@gmail.com only matches it once dots+plus are folded),
-- so lower() alone would miss it — which is exactly what the teeth check shows.
select expect_text('guest door: a Gmail variant of an existing member is already_member',
  guest_pass_eligibility('f9eef9ee-0000-0000-0000-000000000001',
    'f9eef9ee-0000-0000-0000-00000000ad08','a.b+promo@gmail.com') ->> 'reason', 'already_member');
select expect_text('free-first door: the same variant is refused the same way',
  free_first_eligibility('f9eef9ee-0000-0000-0000-000000000001',
    'f9eef9ee-0000-0000-0000-00000000ad07') ->> 'reason', 'already_member');

select 'ALL FREE-FIRST TESTS PASSED' as done;
