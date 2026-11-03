-- =============================================================================
-- Decision 77b — closure notice for multi-day closures. UUID space: c107.
--
-- A multi-day closure with the notice ON: NO per-class class_cancelled emails
-- (suppressed by studiior.closure_notice), ONE studio_closure_notice per member
-- (booked or not), instructor_class_cancelled per class, credits back, and a
-- CONFIRMED free-first seat eligible again. A single-day closure is identical to
-- today (per-class class_cancelled, no studio_closure_notice). Test studio only.
-- =============================================================================
\set SA  '''c1070000-0000-0000-0000-000000000001'''
\set CT  '''c1070000-0000-0000-0000-0000000000c1'''
\set M1  '''c1070000-0000-0000-0000-00000000a001'''
\set M2  '''c1070000-0000-0000-0000-00000000a002'''
\set M3  '''c1070000-0000-0000-0000-00000000a003'''
\set MF  '''c1070000-0000-0000-0000-00000000a00f'''
\set IA  '''c1070000-0000-0000-0000-0000000000d1'''
\set O1  '''c1070000-0000-0000-0000-00000000e001'''
\set O2  '''c1070000-0000-0000-0000-00000000e002'''

create or replace function expect_true(label text, actual boolean) returns void language plpgsql as $$
begin if coalesce(actual,false) then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_num(label text, actual bigint, want bigint) returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (%)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_raises(label text, sql text, code text) returns void language plpgsql as $$
begin execute sql; raise exception 'FAIL  %  expected %, nothing raised', label, code;
exception when others then
  if sqlstate = code then raise notice 'PASS  %  (%)', label, code;
  else raise exception 'FAIL  %  expected %, got % (%)', label, code, sqlstate, sqlerrm; end if; end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('c1070000-0000-0000-0000-0000000000a1'),  -- owner OA
  ('c1070000-0000-0000-0000-0000000000c9');  -- instructor login UA
insert into profiles (id, email) values
  ('c1070000-0000-0000-0000-0000000000a1','c107-oa@example.com'),
  ('c1070000-0000-0000-0000-0000000000c9','c107-ia@example.com');

insert into studios (id, name, slug, timezone, currency, status) values
  (:SA,'Closure Studio','closure-c107','Asia/Manila','PHP','active');
-- Free-first on, so the eligibility check is meaningful; 12h cutoff.
insert into studio_settings (studio_id, cancellation_cutoff_minutes, free_first_class_enabled)
  values (:SA, 720, true);
insert into studio_staff (id, studio_id, user_id, email, role, status) values
  ('c1070000-0000-0000-0000-0000000aa0a1',:SA,'c1070000-0000-0000-0000-0000000000a1','c107-oa@example.com','owner','active');

insert into locations (id, studio_id, name) values ('c1070000-0000-0000-0000-00000000000c',:SA,'Main');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('c1070000-0000-0000-0000-000000000b01',:SA,'c1070000-0000-0000-0000-00000000000c','Studio',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values (:CT,:SA,'Reformer',50,10);

-- An instructor WITH a login (the staff row first — instructors.staff_id FKs it).
insert into studio_staff (id, studio_id, user_id, email, role, status) values
  ('c1070000-0000-0000-0000-0000000ee0a1',:SA,'c1070000-0000-0000-0000-0000000000c9','c107-ia@example.com','instructor','active');
insert into instructors (id, studio_id, display_name, staff_id, status) values
  (:IA,:SA,'Ada Coach','c1070000-0000-0000-0000-0000000ee0a1','active');

insert into members (id, studio_id, first_name, last_name, email, status) values
  (:M1,:SA,'Mara','One','c107-m1@example.com','active'),
  (:M2,:SA,'Ben','Two','c107-m2@example.com','active'),
  (:M3,:SA,'Cleo','Three','c107-m3@example.com','active'),  -- no booking; still gets the notice
  (:MF,:SA,'Faye','Free','c107-mf@example.com','lead');       -- a free-first seat

-- Two classes two days out (multi-day closure spans both). Instructor assigned.
insert into class_occurrences
  (id, studio_id, class_type_id, location_id, room_id, instructor_id, name, starts_at, ends_at, capacity, booked_count, status)
values
  (:O1,:SA,:CT,'c1070000-0000-0000-0000-00000000000c','c1070000-0000-0000-0000-000000000b01',:IA,'Reformer',
   (now() at time zone 'Asia/Manila')::date + 2 + time '07:00' at time zone 'Asia/Manila',
   (now() at time zone 'Asia/Manila')::date + 2 + time '07:50' at time zone 'Asia/Manila', 10, 2, 'scheduled'),
  (:O2,:SA,:CT,'c1070000-0000-0000-0000-00000000000c','c1070000-0000-0000-0000-000000000b01',:IA,'Reformer',
   (now() at time zone 'Asia/Manila')::date + 3 + time '07:00' at time zone 'Asia/Manila',
   (now() at time zone 'Asia/Manila')::date + 3 + time '07:50' at time zone 'Asia/Manila', 10, 1, 'scheduled');

-- M1 on O1 with a PACK credit (so a studio cancellation returns a credit).
insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, validity_days, visibility, status)
  values ('c1070000-0000-0000-0000-00000000df01',:SA,'5 Pack','class_pack',500000,'PHP',5,90,'public','active');
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on, credits_remaining)
  values ('c1070000-0000-0000-0000-00000000df02',:SA,:M1,'c1070000-0000-0000-0000-00000000df01','active',500000,'PHP',(now())::date,4);
insert into credit_ledger (id, studio_id, member_id, membership_id, delta, reason, balance_after)
  values ('c1070000-0000-0000-0000-00000000df03',:SA,:M1,'c1070000-0000-0000-0000-00000000df02',-1,'booking',4);
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, membership_id, credit_entry_id)
  values ('c1070000-0000-0000-0000-00000000bb01',:SA,:O1,:M1,'booked','member','class_pack','c1070000-0000-0000-0000-00000000df02','c1070000-0000-0000-0000-00000000df03');
-- M2 on O1 (a plain seat).
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source)
  values ('c1070000-0000-0000-0000-00000000bb02',:SA,:O1,:M2,'booked','member','drop_in');
-- MF a CONFIRMED free first class on O2 (a host-null guest_passes row).
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source)
  values ('c1070000-0000-0000-0000-00000000bb0f',:SA,:O2,:MF,'booked','member','comp');
insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email, occurrence_id, guest_booking_id, status)
  values (:SA, null, :MF, 'c107-mf@example.com', :O2, 'c1070000-0000-0000-0000-00000000bb0f', 'confirmed');

select set_config('t.sa', :SA, false);
select set_config('t.ia', :IA, false);

-- Before: MF already had their free class. (closure_impact is manager-up, so
-- these run in the owner's session.)
set role authenticated;
select set_config('request.jwt.claim.sub','c1070000-0000-0000-0000-0000000000a1',false);  -- owner
do $$ begin
  perform expect_true('0.1 MF is already_had_free before the closure',
    (free_first_eligibility(current_setting('t.sa')::uuid, 'c1070000-0000-0000-0000-00000000a00f') ->> 'reason') = 'already_had_free');
  -- closure_impact.members_total counts every member with an email.
  perform expect_num('0.2 closure_impact.members_total counts members with an email',
    (closure_impact(current_setting('t.sa')::uuid,
       (now() at time zone 'Asia/Manila')::date + 2,
       (now() at time zone 'Asia/Manila')::date + 3) ->> 'members_total')::bigint, 4);
end $$;
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- 1. MULTI-DAY with the notice ON.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','c1070000-0000-0000-0000-0000000000a1',false);  -- owner
select set_config('t.r1', (close_studio(
  current_setting('t.sa')::uuid,
  (now() at time zone 'Asia/Manila')::date + 2,
  (now() at time zone 'Asia/Manila')::date + 3,
  'Reformers are late', null, null, true, false,
  true, 'We open on the 16th', E'Hi everyone,\n\nThe studio is closed while we wait for the machines.',
  '<p>Hi everyone,</p><p>The studio is closed while we wait for the machines.</p>',
  E'Hi everyone,\n\nThe studio is closed while we wait for the machines.',
  (now() at time zone 'Asia/Manila')::date + 4
)::text), false);
select set_config('request.jwt.claim.sub','',false); reset role;

do $$ begin
  perform expect_true('1.1 closed ok', (current_setting('t.r1')::jsonb ->> 'ok')::boolean);
  perform expect_num('1.2 two classes cancelled', (current_setting('t.r1')::jsonb ->> 'classes_cancelled')::bigint, 2);
  perform expect_num('1.3 NO per-class class_cancelled emails (suppressed by the flag)',
    (select count(*) from notifications where template_key = 'class_cancelled'
       and studio_id = current_setting('t.sa')::uuid), 0);
  perform expect_num('1.4 NO per-class free_booking_not_confirmed either',
    (select count(*) from notifications where template_key = 'free_booking_not_confirmed'
       and studio_id = current_setting('t.sa')::uuid), 0);
  perform expect_num('1.5 ONE studio_closure_notice per member with an email (4)',
    (select count(*) from notifications where template_key = 'studio_closure_notice'
       and studio_id = current_setting('t.sa')::uuid and member_id is not null), 4);
  perform expect_num('1.6 the notice count is reported', (current_setting('t.r1')::jsonb ->> 'notice_sent')::bigint, 4);
  -- Amendment (2): the per-class instructor email is gone; ONE digest instead.
  perform expect_num('1.7 NO per-class instructor_class_cancelled (digest replaces it)',
    (select count(*) from notifications where template_key = 'instructor_class_cancelled'
       and studio_id = current_setting('t.sa')::uuid), 0);
  perform expect_num('1.7b ONE instructor_closure_notice digest (both classes are Ada)',
    (select count(*) from notifications where template_key = 'instructor_closure_notice'
       and dedupe_key = 'closure:' || (current_setting('t.r1')::jsonb ->> 'closure_id') || ':' || current_setting('t.ia')), 1);
  perform expect_true('1.7c the digest lists BOTH of Ada''s cancelled classes',
    (select payload->>'class_list' like '%Reformer%'
        and strpos(payload->>'class_list', E'\n') > 0
       from notifications where template_key = 'instructor_closure_notice'
        and dedupe_key = 'closure:' || (current_setting('t.r1')::jsonb ->> 'closure_id') || ':' || current_setting('t.ia')));
  perform expect_num('1.7d the result reports instructors_notified = 1',
    (current_setting('t.r1')::jsonb ->> 'instructors_notified')::bigint, 1);
  -- STEP 0b: the cancelled class line reads "Mon 9 Nov, 7:00" — a comma before
  -- the fmt_clock time (month word, comma, space, then a digit).
  perform expect_true('1.7e the digest class line uses the "Mon 9 Nov, 7:00" format',
    (select payload->>'class_list' ~ ' [A-Z][a-z]+, [0-9]'
       from notifications where template_key = 'instructor_closure_notice'
        and dedupe_key = 'closure:' || (current_setting('t.r1')::jsonb ->> 'closure_id') || ':' || current_setting('t.ia')));
  -- M1's credit came back.
  perform expect_num('1.8 M1 got their credit back',
    (select coalesce(sum(delta),0) from credit_ledger where member_id = 'c1070000-0000-0000-0000-00000000a001'
       and reason = 'cancellation_refund'), 1);
  -- M1's notice carries their cancelled-class list; M3 (no booking) does not.
  perform expect_true('1.9 M1 notice lists their cancelled class',
    (select payload->>'system_html' like '%were cancelled%' and payload->>'system_html' like '%Reformer%'
       from notifications where template_key = 'studio_closure_notice' and member_id = 'c1070000-0000-0000-0000-00000000a001'));
  -- Amendment (1): the book affordance moved from the system block into
  -- {upcoming_classes}. M3 (no booking) still gets the resume line in system.
  perform expect_true('1.10 M3 (no booking): no cancelled list, resume line in system',
    (select payload->>'system_html' not like '%were cancelled%' and payload->>'system_html' like '%Classes resume%'
       and payload->>'system_html' not like '%/book?d=%'
       from notifications where template_key = 'studio_closure_notice' and member_id = 'c1070000-0000-0000-0000-00000000a003'));
  perform expect_true('1.10b the book affordance is in {upcoming_classes}',
    (select payload->>'upcoming_classes' like '%/book?d=%'
       from notifications where template_key = 'studio_closure_notice' and member_id = 'c1070000-0000-0000-0000-00000000a003'));
  -- MF's CONFIRMED free-first seat is eligible again.
  perform expect_true('1.11 MF is free-first eligible again (guest_passes row deleted)',
    (free_first_eligibility(current_setting('t.sa')::uuid, 'c1070000-0000-0000-0000-00000000a00f') ->> 'ok')::boolean);
  -- notice_sent_at stamped on the closure.
  perform expect_true('1.12 notice_sent_at stamped',
    (select notice_sent_at is not null from studio_closures where id = (current_setting('t.r1')::jsonb ->> 'closure_id')::uuid));
end $$;

-- =============================================================================
-- 2. A one-day closure cannot use the all-member notice (PT422).
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','c1070000-0000-0000-0000-0000000000a1',false);
select expect_raises('2.1 single-day + notice is refused PT422',
  'select close_studio('||quote_literal(current_setting('t.sa'))||'::uuid,'
  ||'(now() at time zone ''Asia/Manila'')::date + 10, (now() at time zone ''Asia/Manila'')::date + 10,'
  ||'''x'', null, null, true, false, true, ''s'', ''m'', ''<p>m</p>'', ''m'','
  ||'(now() at time zone ''Asia/Manila'')::date + 11)', 'PT422');
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- 3. A single-day closure WITHOUT the notice is identical to today.
-- =============================================================================
insert into class_occurrences
  (id, studio_id, class_type_id, location_id, room_id, instructor_id, name, starts_at, ends_at, capacity, booked_count, status)
values
  ('c1070000-0000-0000-0000-00000000e005',:SA,:CT,'c1070000-0000-0000-0000-00000000000c','c1070000-0000-0000-0000-000000000b01',:IA,'Reformer',
   (now() at time zone 'Asia/Manila')::date + 20 + time '07:00' at time zone 'Asia/Manila',
   (now() at time zone 'Asia/Manila')::date + 20 + time '07:50' at time zone 'Asia/Manila', 10, 1, 'scheduled');
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source)
  values ('c1070000-0000-0000-0000-00000000bb05',:SA,'c1070000-0000-0000-0000-00000000e005',:M2,'booked','member','drop_in');

set role authenticated;
select set_config('request.jwt.claim.sub','c1070000-0000-0000-0000-0000000000a1',false);
select set_config('t.r3', (close_studio(
  p_studio_id := current_setting('t.sa')::uuid,
  p_starts_on := (now() at time zone 'Asia/Manila')::date + 20,
  p_ends_on := (now() at time zone 'Asia/Manila')::date + 20,
  p_reason := 'Public holiday', p_confirm := true)::text), false);
select set_config('request.jwt.claim.sub','',false); reset role;

do $$ begin
  perform expect_true('3.1 single-day closed ok', (current_setting('t.r3')::jsonb ->> 'ok')::boolean);
  -- The per-class class_cancelled went out as today (M2 on the holiday class).
  perform expect_num('3.2 single-day: a class_cancelled email went to the booked member',
    (select count(*) from notifications where template_key = 'class_cancelled'
       and member_id = 'c1070000-0000-0000-0000-00000000a002'), 1);
  -- No NEW studio_closure_notice from the single-day closure (still 4 from §1).
  perform expect_num('3.3 single-day: no studio_closure_notice',
    (select count(*) from notifications where template_key = 'studio_closure_notice'
       and studio_id = current_setting('t.sa')::uuid and member_id is not null), 4);
end $$;

-- =============================================================================
-- 4. closure_notice_test — one hand-addressed row to the caller's own email.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','c1070000-0000-0000-0000-0000000000a1',false);
select closure_notice_test(current_setting('t.sa')::uuid, 'Test subject',
  '<p>body</p>', 'body', (now() at time zone 'Asia/Manila')::date + 30);
select set_config('request.jwt.claim.sub','',false); reset role;

do $$ begin
  perform expect_num('4.1 a [Test] studio_closure_notice to the owner email',
    (select count(*) from notifications where template_key = 'studio_closure_notice'
       and payload->>'to_email' = 'c107-oa@example.com' and payload->>'subject' like '[Test]%'), 1);
end $$;

-- =============================================================================
-- Decision 77 amendment (3 Nov 2026) — upcoming classes, instructor digest,
-- preview before send. RED on the pre-amendment schema: closure_preview /
-- closure_upcoming_block / closure_instructor_test / p_send_emails do not exist.
-- =============================================================================

-- Fixtures for §5/§6/§8 (SA) + two tiny studios SB/SC for the upcoming block.
insert into auth.users (id) values ('c1070000-0000-0000-0000-0000000000fd');  -- front desk
insert into profiles (id, email) values ('c1070000-0000-0000-0000-0000000000fd','c107-fd@example.com');
insert into studio_staff (id, studio_id, user_id, email, role, status) values
  ('c1070000-0000-0000-0000-0000000ff0fd',:SA,'c1070000-0000-0000-0000-0000000000fd','c107-fd@example.com','front_desk','active');

-- §5: a class in the window (M2 booked, Ada) + an upcoming class after resume.
insert into class_occurrences
  (id, studio_id, class_type_id, location_id, room_id, instructor_id, name, starts_at, ends_at, capacity, booked_count, status)
values
  ('c1070000-0000-0000-0000-00000000e050',:SA,:CT,'c1070000-0000-0000-0000-00000000000c','c1070000-0000-0000-0000-000000000b01',:IA,'Reformer',
   (now() at time zone 'Asia/Manila')::date + 41 + time '07:00' at time zone 'Asia/Manila',
   (now() at time zone 'Asia/Manila')::date + 41 + time '07:50' at time zone 'Asia/Manila', 10, 1, 'scheduled'),
  ('c1070000-0000-0000-0000-00000000e060',:SA,:CT,'c1070000-0000-0000-0000-00000000000c','c1070000-0000-0000-0000-000000000b01',:IA,'Upcoming Flow',
   (now() at time zone 'Asia/Manila')::date + 45 + time '09:00' at time zone 'Asia/Manila',
   (now() at time zone 'Asia/Manila')::date + 45 + time '09:50' at time zone 'Asia/Manila', 10, 0, 'scheduled');
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source)
  values ('c1070000-0000-0000-0000-0000000bb050',:SA,'c1070000-0000-0000-0000-00000000e050',:M2,'booked','member','drop_in');

-- §6: a class to close with no emails.
insert into class_occurrences
  (id, studio_id, class_type_id, location_id, room_id, instructor_id, name, starts_at, ends_at, capacity, booked_count, status)
values
  ('c1070000-0000-0000-0000-00000000e070',:SA,:CT,'c1070000-0000-0000-0000-00000000000c','c1070000-0000-0000-0000-000000000b01',:IA,'Reformer',
   (now() at time zone 'Asia/Manila')::date + 51 + time '07:00' at time zone 'Asia/Manila',
   (now() at time zone 'Asia/Manila')::date + 51 + time '07:50' at time zone 'Asia/Manila', 10, 1, 'scheduled');
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source)
  values ('c1070000-0000-0000-0000-0000000bb070',:SA,'c1070000-0000-0000-0000-00000000e070',:M2,'booked','member','drop_in');

-- §8: a class to close with the instructor switch OFF.
insert into class_occurrences
  (id, studio_id, class_type_id, location_id, room_id, instructor_id, name, starts_at, ends_at, capacity, booked_count, status)
values
  ('c1070000-0000-0000-0000-00000000e080',:SA,:CT,'c1070000-0000-0000-0000-00000000000c','c1070000-0000-0000-0000-000000000b01',:IA,'Reformer',
   (now() at time zone 'Asia/Manila')::date + 71 + time '07:00' at time zone 'Asia/Manila',
   (now() at time zone 'Asia/Manila')::date + 71 + time '07:50' at time zone 'Asia/Manila', 10, 1, 'scheduled');
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source)
  values ('c1070000-0000-0000-0000-0000000bb080',:SA,'c1070000-0000-0000-0000-00000000e080',:M2,'booked','member','drop_in');

-- SB (core-first + empty) and SC (the eight cap). No members needed.
insert into studios (id, name, slug, timezone, currency, status) values
  ('c1070000-0000-0000-0000-0000000000b0','C107 B','c107-b','Asia/Manila','PHP','active'),
  ('c1070000-0000-0000-0000-0000000000c0','C107 C','c107-c','Asia/Manila','PHP','active');
insert into studio_settings (studio_id) values
  ('c1070000-0000-0000-0000-0000000000b0'), ('c1070000-0000-0000-0000-0000000000c0');
insert into locations (id, studio_id, name) values
  ('c1070000-0000-0000-0000-0000000000cb','c1070000-0000-0000-0000-0000000000b0','Main'),
  ('c1070000-0000-0000-0000-0000000000cc','c1070000-0000-0000-0000-0000000000c0','Main');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('c1070000-0000-0000-0000-000000000bb1','c1070000-0000-0000-0000-0000000000b0','c1070000-0000-0000-0000-0000000000cb','Studio',10),
  ('c1070000-0000-0000-0000-000000000cc1','c1070000-0000-0000-0000-0000000000c0','c1070000-0000-0000-0000-0000000000cc','Studio',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('c1070000-0000-0000-0000-00000000cb01'::uuid,'c1070000-0000-0000-0000-0000000000b0','Reformer',50,10),
  ('c1070000-0000-0000-0000-00000000cc01'::uuid,'c1070000-0000-0000-0000-0000000000c0','Reformer',50,10);
-- SB: a core class (later) and a flex class (earlier) — core must render first.
insert into class_occurrences
  (id, studio_id, class_type_id, location_id, room_id, name, flex, starts_at, ends_at, capacity, booked_count, status)
values
  ('c1070000-0000-0000-0000-000000000bc1','c1070000-0000-0000-0000-0000000000b0','c1070000-0000-0000-0000-00000000cb01'::uuid,'c1070000-0000-0000-0000-0000000000cb','c1070000-0000-0000-0000-000000000bb1','Core Class', false,
   (now() at time zone 'Asia/Manila')::date + 2 + time '07:00' at time zone 'Asia/Manila',
   (now() at time zone 'Asia/Manila')::date + 2 + time '07:50' at time zone 'Asia/Manila', 10, 0, 'scheduled'),
  ('c1070000-0000-0000-0000-000000000bf1','c1070000-0000-0000-0000-0000000000b0','c1070000-0000-0000-0000-00000000cb01'::uuid,'c1070000-0000-0000-0000-0000000000cb','c1070000-0000-0000-0000-000000000bb1','Flex Class', true,
   (now() at time zone 'Asia/Manila')::date + 1 + time '07:00' at time zone 'Asia/Manila',
   (now() at time zone 'Asia/Manila')::date + 1 + time '07:50' at time zone 'Asia/Manila', 10, 0, 'scheduled');
-- SC: nine bookable classes after a resume date (the limit is eight).
insert into class_occurrences
  (id, studio_id, class_type_id, location_id, room_id, name, starts_at, ends_at, capacity, booked_count, status)
select ('c1070000-0000-0000-0000-0000000c70'||lpad(g::text,2,'0'))::uuid,
       'c1070000-0000-0000-0000-0000000000c0','c1070000-0000-0000-0000-00000000cc01'::uuid,
       'c1070000-0000-0000-0000-0000000000cc','c1070000-0000-0000-0000-000000000cc1','SC Class '||g,
       (now() at time zone 'Asia/Manila')::date + (10+g) + time '07:00' at time zone 'Asia/Manila',
       (now() at time zone 'Asia/Manila')::date + (10+g) + time '07:50' at time zone 'Asia/Manila', 10, 0, 'scheduled'
  from generate_series(1,9) g;

select set_config('t.sb', 'c1070000-0000-0000-0000-0000000000b0', false);
select set_config('t.sc', 'c1070000-0000-0000-0000-0000000000c0', false);

-- =============================================================================
-- 5. closure_preview — both emails rendered, the counts, front desk refused.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','c1070000-0000-0000-0000-0000000000a1',false);  -- owner
select set_config('t.p5', (closure_preview(
  current_setting('t.sa')::uuid,
  (now() at time zone 'Asia/Manila')::date + 41,
  (now() at time zone 'Asia/Manila')::date + 42,
  (now() at time zone 'Asia/Manila')::date + 43,
  'We are closed', '<p>Back soon.</p>', 'Back soon.')::text), false);
select set_config('request.jwt.claim.sub','',false); reset role;

do $$ declare p jsonb := current_setting('t.p5')::jsonb; begin
  perform expect_num('5.1 preview counts 4 members', (p->>'members')::bigint, 4);
  perform expect_num('5.2 preview counts 1 instructor', (p->>'instructors')::bigint, 1);
  perform expect_true('5.3 member email names the cancelled class',
    (p->'member'->>'html') like '%Reformer%');
  perform expect_true('5.4 member email shows the upcoming class + button',
    (p->'member'->>'html') like '%Upcoming Flow%' and (p->'member'->>'html') like '%See the full schedule%');
  perform expect_true('5.5 instructor digest renders with its button',
    (p->'instructor'->>'html') like '%Check my schedule%' and (p->'instructor'->>'html') like '%Reformer%');
  perform expect_true('5.6 the accent token was filled, not left raw',
    (p->'member'->>'html') not like '%{accent}%' and (p->'instructor'->>'html') not like '%{accent}%');
  -- STEP 0b: the cancelled class line in both emails reads "Mon 9 Nov, 7:00".
  perform expect_true('5.6b member + instructor class lines use the comma format',
    (p->'member'->>'html') ~ ' [A-Z][a-z]+, [0-9]' and (p->'instructor'->>'html') ~ ' [A-Z][a-z]+, [0-9]');
end $$;

set role authenticated;
select set_config('request.jwt.claim.sub','c1070000-0000-0000-0000-0000000000fd',false);  -- front desk
select expect_raises('5.7 front desk cannot preview a closure',
  'select closure_preview('||quote_literal(current_setting('t.sa'))||'::uuid,'
  ||'(now() at time zone ''Asia/Manila'')::date + 41, (now() at time zone ''Asia/Manila'')::date + 42,'
  ||'(now() at time zone ''Asia/Manila'')::date + 43, ''x'', ''<p>x</p>'', ''x'')', 'PT403');
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- 6. p_send_emails = false — cancels and sends nothing.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','c1070000-0000-0000-0000-0000000000a1',false);
select set_config('t.r6', (close_studio(
  current_setting('t.sa')::uuid,
  (now() at time zone 'Asia/Manila')::date + 51,
  (now() at time zone 'Asia/Manila')::date + 52,
  'Deep clean', null, null, true, false,
  true, 'Closed for a clean', E'Hi,\n\nWe are shut for a deep clean.',
  '<p>Hi,</p><p>We are shut for a deep clean.</p>', E'Hi,\n\nWe are shut for a deep clean.',
  (now() at time zone 'Asia/Manila')::date + 53, false)::text), false);  -- p_send_emails := false
select set_config('request.jwt.claim.sub','',false); reset role;

do $$ declare cid text := current_setting('t.r6')::jsonb ->> 'closure_id'; begin
  perform expect_true('6.1 closed ok', (current_setting('t.r6')::jsonb ->> 'ok')::boolean);
  perform expect_num('6.2 the class is cancelled', (current_setting('t.r6')::jsonb ->> 'classes_cancelled')::bigint, 1);
  perform expect_true('6.3 the occurrence is cancelled',
    (select status = 'cancelled' from class_occurrences where id = 'c1070000-0000-0000-0000-00000000e070'));
  perform expect_num('6.4 NO member notice for this closure',
    (select count(*) from notifications where template_key='studio_closure_notice' and dedupe_key like 'studio_closure_notice:'||cid||':%'), 0);
  perform expect_num('6.5 NO instructor digest for this closure',
    (select count(*) from notifications where template_key='instructor_closure_notice' and dedupe_key = 'closure:'||cid||':'||current_setting('t.ia')), 0);
  perform expect_num('6.6 NO per-class class_cancelled for the booked member (suppressed)',
    (select count(*) from notifications where template_key='class_cancelled'
       and member_id='c1070000-0000-0000-0000-00000000a002'
       and payload->>'occurrence_id' = 'c1070000-0000-0000-0000-00000000e070'), 0);
  perform expect_num('6.7 result reports notice_sent 0 and instructors_notified 0',
    ((current_setting('t.r6')::jsonb ->> 'notice_sent')::bigint
     + (current_setting('t.r6')::jsonb ->> 'instructors_notified')::bigint), 0);
end $$;

-- =============================================================================
-- 7. closure_upcoming_block — eight cards max, core first, empty → plain link.
--    Run as postgres (service-only function).
-- =============================================================================
do $$
declare h text; t text; v_cards int;
begin
  -- Core-first (SB): the core class renders before the flex one.
  select html, txt into h, t from closure_upcoming_block(current_setting('t.sb')::uuid,
    (now() at time zone 'Asia/Manila')::date + 1);
  perform expect_true('7.1 core before flex', strpos(h, 'Core Class') > 0
    and strpos(h, 'Core Class') < strpos(h, 'Flex Class'));
  perform expect_true('7.2 cards carry the See-the-full-schedule button', h like '%See the full schedule%');

  -- Empty (SB): nothing published past a far resume date → plain book link.
  select html into h from closure_upcoming_block(current_setting('t.sb')::uuid,
    (now() at time zone 'Asia/Manila')::date + 90);
  perform expect_true('7.3 empty → plain book link, no button',
    h like '%Book your week%' and h not like '%See the full schedule%');

  -- Eight cap (SC): nine bookable classes → eight cards.
  select html into h from closure_upcoming_block(current_setting('t.sc')::uuid,
    (now() at time zone 'Asia/Manila')::date + 11);
  v_cards := (length(h) - length(replace(h, 'border:1px solid #E7E5E4;border-radius:8px', ''))) /
             length('border:1px solid #E7E5E4;border-radius:8px');
  perform expect_num('7.4 at most eight cards', v_cards, 8);
end $$;

-- =============================================================================
-- 8. The per-email switch suppresses the instructor digest while the member
--    notice still goes.
-- =============================================================================
update studio_settings
   set disabled_templates = array_append(coalesce(disabled_templates, '{}'), 'instructor_closure_notice')
 where studio_id = :SA;

set role authenticated;
select set_config('request.jwt.claim.sub','c1070000-0000-0000-0000-0000000000a1',false);
select set_config('t.r8', (close_studio(
  current_setting('t.sa')::uuid,
  (now() at time zone 'Asia/Manila')::date + 71,
  (now() at time zone 'Asia/Manila')::date + 72,
  'Holiday', null, null, true, false,
  true, 'We are away', E'Hi,\n\nWe are away.', '<p>Hi,</p><p>We are away.</p>', E'Hi,\n\nWe are away.',
  (now() at time zone 'Asia/Manila')::date + 73, true)::text), false);
select set_config('request.jwt.claim.sub','',false); reset role;

do $$ declare cid text := current_setting('t.r8')::jsonb ->> 'closure_id'; begin
  perform expect_num('8.1 the instructor digest is suppressed by the switch',
    (select count(*) from notifications where template_key='instructor_closure_notice' and dedupe_key = 'closure:'||cid||':'||current_setting('t.ia')), 0);
  perform expect_num('8.2 but the member notice still goes',
    (select count(*) from notifications where template_key='studio_closure_notice' and dedupe_key like 'studio_closure_notice:'||cid||':%'), 4);
end $$;

select 'closure_notice_test: all assertions passed' as result;
