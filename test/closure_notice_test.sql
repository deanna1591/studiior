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
  perform expect_num('1.7 instructor_class_cancelled per class (2)',
    (select count(*) from notifications where template_key = 'instructor_class_cancelled'
       and studio_id = current_setting('t.sa')::uuid), 2);
  -- M1's credit came back.
  perform expect_num('1.8 M1 got their credit back',
    (select coalesce(sum(delta),0) from credit_ledger where member_id = 'c1070000-0000-0000-0000-00000000a001'
       and reason = 'cancellation_refund'), 1);
  -- M1's notice carries their cancelled-class list; M3 (no booking) does not.
  perform expect_true('1.9 M1 notice lists their cancelled class',
    (select payload->>'system_html' like '%were cancelled%' and payload->>'system_html' like '%Reformer%'
       from notifications where template_key = 'studio_closure_notice' and member_id = 'c1070000-0000-0000-0000-00000000a001'));
  perform expect_true('1.10 M3 (no booking) notice has no cancelled list, still resumes line + book link',
    (select payload->>'system_html' not like '%were cancelled%' and payload->>'system_html' like '%Classes resume%'
       and payload->>'system_html' like '%/book?d=%'
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

select 'closure_notice_test: all assertions passed' as result;
