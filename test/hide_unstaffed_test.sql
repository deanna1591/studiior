-- =============================================================================
-- Decision 48 — hide unstaffed classes from members, per tenant. UUID space
-- 48ad, checked free. Run after `supabase db reset`.
-- SA: switch ON. SB: switch OFF. Publication off at both (month_published true),
-- so visibility turns purely on staffing + the switch.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual then raise notice 'PASS  %  (got true)', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_false(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual is not null and not actual then raise notice 'PASS  %  (got false)', label;
  else raise exception 'FAIL  %  expected false, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('48ad48ad-0000-0000-0000-0000000000a1'),  -- owner SA
  ('48ad48ad-0000-0000-0000-0000000a0001'),  -- MA (SA member)
  ('48ad48ad-0000-0000-0000-0000000c0001'),  -- MC (SA, a different member)
  ('48ad48ad-0000-0000-0000-000000010001'),  -- ML (SA, a fresh lead for free-first)
  ('48ad48ad-0000-0000-0000-0000000000b1'),  -- owner SB
  ('48ad48ad-0000-0000-0000-0000000b0001');  -- MB (SB member)
insert into profiles (id, email) values
  ('48ad48ad-0000-0000-0000-0000000000a1','48ad-owner-a@example.com'),
  ('48ad48ad-0000-0000-0000-0000000a0001','48ad-ma@example.com'),
  ('48ad48ad-0000-0000-0000-0000000c0001','48ad-mc@example.com'),
  ('48ad48ad-0000-0000-0000-000000010001','48ad-ml@example.com'),
  ('48ad48ad-0000-0000-0000-0000000000b1','48ad-owner-b@example.com'),
  ('48ad48ad-0000-0000-0000-0000000b0001','48ad-mb@example.com');

insert into studios (id, name, slug, timezone, currency, status) values
  ('48ad48ad-0000-0000-0000-000000000001','Hide On','48ad-a','Europe/Prague','CZK','active'),
  ('48ad48ad-0000-0000-0000-000000000002','Hide Off','48ad-b','Europe/Prague','CZK','active');
-- SA hides unstaffed + runs free-first and guest passes; SB is all defaults.
insert into studio_settings (studio_id, hide_unstaffed_from_members, free_first_class_enabled, guest_passes_enabled) values
  ('48ad48ad-0000-0000-0000-000000000001', true, true, true);
insert into studio_settings (studio_id) values
  ('48ad48ad-0000-0000-0000-000000000002');  -- SB: hide_unstaffed_from_members defaults false

insert into locations (id, studio_id, name, is_primary) values
  ('48ad48ad-0000-0000-0000-0000000000aa','48ad48ad-0000-0000-0000-000000000001','Main',true),
  ('48ad48ad-0000-0000-0000-0000000000bb','48ad48ad-0000-0000-0000-000000000002','Main',true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('48ad48ad-0000-0000-0000-0000000000a1','48ad48ad-0000-0000-0000-000000000001','48ad48ad-0000-0000-0000-0000000000aa','RA',10),
  ('48ad48ad-0000-0000-0000-0000000000b1','48ad48ad-0000-0000-0000-000000000002','48ad48ad-0000-0000-0000-0000000000bb','RB',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('48ad48ad-0000-0000-0000-00000000c7a1','48ad48ad-0000-0000-0000-000000000001','Flow',50,10),
  ('48ad48ad-0000-0000-0000-00000000c7b1','48ad48ad-0000-0000-0000-000000000002','Flow',50,10);
insert into instructors (id, studio_id, display_name, staff_id) values
  ('48ad48ad-0000-0000-0000-00000000001a','48ad48ad-0000-0000-0000-000000000001','Ina SA',null),
  ('48ad48ad-0000-0000-0000-00000000001b','48ad48ad-0000-0000-0000-000000000002','Ivo SB',null);
-- Members. MA/MC active-ish members at SA; ML a fresh lead; MB a member at SB.
insert into members (id, studio_id, user_id, first_name, last_name, email, status, waiver_signed_at) values
  ('48ad48ad-0000-0000-0000-00000000a0aa','48ad48ad-0000-0000-0000-000000000001','48ad48ad-0000-0000-0000-0000000a0001','Mia','A','48ad-ma@example.com','active', now()),
  ('48ad48ad-0000-0000-0000-00000000c0cc','48ad48ad-0000-0000-0000-000000000001','48ad48ad-0000-0000-0000-0000000c0001','Cal','C','48ad-mc@example.com','active', now()),
  ('48ad48ad-0000-0000-0000-0000000001ee','48ad48ad-0000-0000-0000-000000000001','48ad48ad-0000-0000-0000-000000010001','Lee','L','48ad-ml@example.com','lead', now()),
  ('48ad48ad-0000-0000-0000-00000000b0bb','48ad48ad-0000-0000-0000-000000000002','48ad48ad-0000-0000-0000-0000000b0001','Bea','B','48ad-mb@example.com','active', now());

-- Occurrences, scheduled, 10 days out (published — publication off).
-- U1 (SA) unstaffed (instructor null → staffing 'open'); A1, A2 (SA) assigned.
-- U2 (SB) unstaffed.
insert into class_occurrences
  (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, starts_at, ends_at, status) values
  ('48ad48ad-0000-0000-0000-00000000c001','48ad48ad-0000-0000-0000-000000000001','48ad48ad-0000-0000-0000-0000000000aa','48ad48ad-0000-0000-0000-00000000c7a1','48ad48ad-0000-0000-0000-0000000000a1',null,'Flow U1',10, now()+interval '10 days', now()+interval '10 days'+interval '50 min','scheduled'),
  ('48ad48ad-0000-0000-0000-00000000c0a1','48ad48ad-0000-0000-0000-000000000001','48ad48ad-0000-0000-0000-0000000000aa','48ad48ad-0000-0000-0000-00000000c7a1','48ad48ad-0000-0000-0000-0000000000a1','48ad48ad-0000-0000-0000-00000000001a','Flow A1',10, now()+interval '11 days', now()+interval '11 days'+interval '50 min','scheduled'),
  ('48ad48ad-0000-0000-0000-00000000c0a2','48ad48ad-0000-0000-0000-000000000001','48ad48ad-0000-0000-0000-0000000000aa','48ad48ad-0000-0000-0000-00000000c7a1','48ad48ad-0000-0000-0000-0000000000a1','48ad48ad-0000-0000-0000-00000000001a','Flow A2',10, now()+interval '12 days', now()+interval '12 days'+interval '50 min','scheduled'),
  ('48ad48ad-0000-0000-0000-00000000c002','48ad48ad-0000-0000-0000-000000000002','48ad48ad-0000-0000-0000-0000000000bb','48ad48ad-0000-0000-0000-00000000c7b1','48ad48ad-0000-0000-0000-0000000000b1',null,'Flow U2',10, now()+interval '10 days', now()+interval '10 days'+interval '50 min','scheduled');

-- Sanity: the trigger derived staffing from instructor_id.
select expect_text('U1 derived staffing open', (select staffing::text from class_occurrences where id='48ad48ad-0000-0000-0000-00000000c001'), 'open');
select expect_text('A1 derived staffing assigned', (select staffing::text from class_occurrences where id='48ad48ad-0000-0000-0000-00000000c0a1'), 'assigned');

-- =============================================================================
-- 1. occurrence_member_visible_run — the canonical predicate.
-- =============================================================================
select expect_false('visible: U1 hidden to MA (unstaffed, switch on, not booked)',
  occurrence_member_visible_run('48ad48ad-0000-0000-0000-00000000c001','48ad48ad-0000-0000-0000-00000000a0aa'));
select expect_true('visible: A1 shown to MA (assigned)',
  occurrence_member_visible_run('48ad48ad-0000-0000-0000-00000000c0a1','48ad48ad-0000-0000-0000-00000000a0aa'));
select expect_true('visible: U2 shown to MB (switch OFF at SB)',
  occurrence_member_visible_run('48ad48ad-0000-0000-0000-00000000c002','48ad48ad-0000-0000-0000-00000000b0bb'));
select expect_false('visible: U1 hidden with null member too (public rule)',
  occurrence_member_visible_run('48ad48ad-0000-0000-0000-00000000c001', null));

-- =============================================================================
-- 2. RLS occ_member_read — as the member session.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','48ad48ad-0000-0000-0000-0000000a0001',false);
select expect_num('RLS: MA cannot see U1 (unstaffed, hidden)',
  (select count(*) from class_occurrences where id='48ad48ad-0000-0000-0000-00000000c001')::bigint, 0);
select expect_num('RLS: MA sees A1 (assigned)',
  (select count(*) from class_occurrences where id='48ad48ad-0000-0000-0000-00000000c0a1')::bigint, 1);
reset role; select set_config('request.jwt.claim.sub', null, false);
set role authenticated;
select set_config('request.jwt.claim.sub','48ad48ad-0000-0000-0000-0000000b0001',false);
select expect_num('RLS: MB sees U2 (switch off)',
  (select count(*) from class_occurrences where id='48ad48ad-0000-0000-0000-00000000c002')::bigint, 1);
reset role; select set_config('request.jwt.claim.sub', null, false);

-- =============================================================================
-- 3. book_class / book_first_free / book_guest refuse an unstaffed class.
-- =============================================================================
select expect_text('book_class U1 → not_staffed_yet (the sentence''s reason)',
  (book_class('48ad48ad-0000-0000-0000-00000000c001','48ad48ad-0000-0000-0000-00000000a0aa','member')).failure_reason, 'not_staffed_yet');
select expect_false('book_class A1 (assigned) is NOT refused for staffing',
  (book_class('48ad48ad-0000-0000-0000-00000000c0a1','48ad48ad-0000-0000-0000-00000000a0aa','member')).failure_reason is not distinct from 'not_staffed_yet');
select expect_false('book_class U2 at SB (switch off) is NOT refused for staffing',
  (book_class('48ad48ad-0000-0000-0000-00000000c002','48ad48ad-0000-0000-0000-00000000b0bb','member')).failure_reason is not distinct from 'not_staffed_yet');
-- book_first_free as ML (a fresh lead — eligible, so it reaches the staffing gate).
select set_config('request.jwt.claim.sub','48ad48ad-0000-0000-0000-000000010001',false);
select expect_text('book_first_free U1 → not_staffed_yet',
  book_first_free('48ad48ad-0000-0000-0000-00000000c001') ->> 'reason', 'not_staffed_yet');
select set_config('request.jwt.claim.sub', null, false);
-- book_guest as MA (the host), bringing a guest to U1.
select set_config('request.jwt.claim.sub','48ad48ad-0000-0000-0000-0000000a0001',false);
select expect_text('book_guest U1 → not_staffed_yet',
  book_guest('48ad48ad-0000-0000-0000-00000000c001','48ad-guest@example.com','Guy','Est') ->> 'reason', 'not_staffed_yet');
select set_config('request.jwt.claim.sub', null, false);

-- =============================================================================
-- 4. public_schedule — the website embed omits unstaffed classes.
-- =============================================================================
select expect_false('public_schedule SA omits U1',
  (select exists (select 1 from jsonb_array_elements(public_schedule('48ad-a', 30) -> 'classes') e
                   where e ->> 'id' = '48ad48ad-0000-0000-0000-00000000c001')));
select expect_true('public_schedule SA includes A1 (assigned)',
  (select exists (select 1 from jsonb_array_elements(public_schedule('48ad-a', 30) -> 'classes') e
                   where e ->> 'id' = '48ad48ad-0000-0000-0000-00000000c0a1')));
select expect_true('public_schedule SB includes U2 (switch off)',
  (select exists (select 1 from jsonb_array_elements(public_schedule('48ad-b', 30) -> 'classes') e
                   where e ->> 'id' = '48ad48ad-0000-0000-0000-00000000c002')));

-- =============================================================================
-- 5. assign an instructor → the class appears and is bookable.
-- =============================================================================
update class_occurrences set instructor_id='48ad48ad-0000-0000-0000-00000000001a'
 where id='48ad48ad-0000-0000-0000-00000000c001';
select expect_text('after assign: U1 staffing assigned',
  (select staffing::text from class_occurrences where id='48ad48ad-0000-0000-0000-00000000c001'), 'assigned');
select expect_true('after assign: U1 now visible to MA',
  occurrence_member_visible_run('48ad48ad-0000-0000-0000-00000000c001','48ad48ad-0000-0000-0000-00000000a0aa'));
select expect_false('after assign: book_class U1 no longer refused for staffing',
  (book_class('48ad48ad-0000-0000-0000-00000000c001','48ad48ad-0000-0000-0000-00000000a0aa','member')).failure_reason is not distinct from 'not_staffed_yet');
set role authenticated;
select set_config('request.jwt.claim.sub','48ad48ad-0000-0000-0000-0000000a0001',false);
select expect_num('after assign: RLS MA now sees U1',
  (select count(*) from class_occurrences where id='48ad48ad-0000-0000-0000-00000000c001')::bigint, 1);
reset role; select set_config('request.jwt.claim.sub', null, false);

-- =============================================================================
-- 6. an existing booking survives losing the instructor: that member keeps
--    seeing it; a different member cannot see or book it.
-- =============================================================================
insert into bookings (studio_id, occurrence_id, member_id, status) values
  ('48ad48ad-0000-0000-0000-000000000001','48ad48ad-0000-0000-0000-00000000c0a2','48ad48ad-0000-0000-0000-00000000a0aa','booked');
-- Unassign A2 (instructor off → staffing open).
update class_occurrences set instructor_id=null where id='48ad48ad-0000-0000-0000-00000000c0a2';
select expect_text('A2 unassigned → staffing open', (select staffing::text from class_occurrences where id='48ad48ad-0000-0000-0000-00000000c0a2'), 'open');
select expect_true('booked member MA still sees A2 (visible predicate true)',
  occurrence_member_visible_run('48ad48ad-0000-0000-0000-00000000c0a2','48ad48ad-0000-0000-0000-00000000a0aa'));
select expect_false('a DIFFERENT member MC cannot see A2',
  occurrence_member_visible_run('48ad48ad-0000-0000-0000-00000000c0a2','48ad48ad-0000-0000-0000-00000000c0cc'));
set role authenticated;
select set_config('request.jwt.claim.sub','48ad48ad-0000-0000-0000-0000000a0001',false);
select expect_num('RLS: booked MA still sees A2 (own-read)',
  (select count(*) from class_occurrences where id='48ad48ad-0000-0000-0000-00000000c0a2')::bigint, 1);
reset role; select set_config('request.jwt.claim.sub', null, false);
set role authenticated;
select set_config('request.jwt.claim.sub','48ad48ad-0000-0000-0000-0000000c0001',false);
select expect_num('RLS: non-booked MC cannot see A2',
  (select count(*) from class_occurrences where id='48ad48ad-0000-0000-0000-00000000c0a2')::bigint, 0);
reset role; select set_config('request.jwt.claim.sub', null, false);
select expect_text('MC cannot book A2 either → not_staffed_yet',
  (book_class('48ad48ad-0000-0000-0000-00000000c0a2','48ad48ad-0000-0000-0000-00000000c0cc','member')).failure_reason, 'not_staffed_yet');

-- =============================================================================
-- 7. the switch is the only thing: turn SA off → U2-equivalent visible again.
-- =============================================================================
-- Re-unassign U1 and turn SA's switch off: the unstaffed class is visible.
update class_occurrences set instructor_id=null where id='48ad48ad-0000-0000-0000-00000000c001';
update studio_settings set hide_unstaffed_from_members=false where studio_id='48ad48ad-0000-0000-0000-000000000001';
select expect_true('switch OFF: the unstaffed U1 is visible to a non-booked member',
  occurrence_member_visible_run('48ad48ad-0000-0000-0000-00000000c001','48ad48ad-0000-0000-0000-00000000c0cc'));
select expect_false('switch OFF: book_class U1 no longer refused for staffing',
  (book_class('48ad48ad-0000-0000-0000-00000000c001','48ad48ad-0000-0000-0000-00000000c0cc','member')).failure_reason is not distinct from 'not_staffed_yet');

select 'hide unstaffed suite finished' as done;
