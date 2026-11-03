-- =============================================================================
-- Decision 91 — hide a SINGLE class from members (per class, not a setting).
-- UUID space 91de, checked free. Run after `supabase db reset`.
-- One studio SA (publication off → month_published true; hide_unstaffed off).
-- Occurrences: H (to hide), V (visible control), B (MA booked, flex), F (free-
-- first eligible). All scheduled, assigned, future, distinct days.
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

-- set_occurrence_visibility as a session: 'OK:hidden' | 'OK:shown' | <reason> | 'ERR:<code>'
create or replace function t91x_sov(p_uid text, p_occ uuid, p_visible boolean) returns text language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claim.sub', p_uid, true); set local role authenticated;
  begin
    r := set_occurrence_visibility(p_occ, p_visible); reset role;
    if coalesce((r->>'ok')::boolean,false) then
      return case when coalesce((r->>'hidden_from_members')::boolean,false) then 'OK:hidden' else 'OK:shown' end;
    end if;
    return coalesce(r->>'reason','?');
  exception when others then reset role; return 'ERR:'||sqlstate; end;
end $$;

-- book_class failure reason as text (top level; the hidden gate is session-independent)
create or replace function t91x_bk(p_occ uuid, p_member uuid, p_src booking_source) returns text language plpgsql as $$
declare r book_class_result;
begin r := book_class(p_occ, p_member, p_src); return coalesce(r.failure_reason, 'OK'); end $$;

-- the count of a member's own-read of an occurrence under RLS: 0 or 1
create or replace function t91x_sees(p_uid text, p_occ uuid) returns bigint language plpgsql as $$
declare n bigint;
begin
  perform set_config('request.jwt.claim.sub', p_uid, true); set local role authenticated;
  select count(*) into n from class_occurrences where id = p_occ;
  reset role; perform set_config('request.jwt.claim.sub', null, false);
  return n;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('91de91de-0000-0000-0000-0000000000a1'),  -- owner
  ('91de91de-0000-0000-0000-0000000000fd'),  -- front desk
  ('91de91de-0000-0000-0000-0000000000e5'),  -- instructor login
  ('91de91de-0000-0000-0000-0000000a0001'),  -- MA (booked on B)
  ('91de91de-0000-0000-0000-0000000c0001'),  -- MC (not booked)
  ('91de91de-0000-0000-0000-000000010001');  -- ML (lead, free-first)
insert into profiles (id, email) select id, id::text||'@example.com' from auth.users where id::text like '91de%';

insert into studios (id, name, slug, timezone, currency, status) values
  ('91de91de-0000-0000-0000-000000000001','Hide Class','91de-a','Europe/Prague','CZK','active');
-- free-first + flex on so F is eligible and B can be a flex pending booking.
insert into studio_settings (studio_id, free_first_class_enabled, flex_enabled, booking_window_days)
  values ('91de91de-0000-0000-0000-000000000001', true, true, 90);

insert into studio_staff (id, studio_id, user_id, email, role, status) values
  ('91de91de-0000-0000-0000-000000005501','91de91de-0000-0000-0000-000000000001','91de91de-0000-0000-0000-0000000000a1','91de-owner@example.com','owner','active'),
  ('91de91de-0000-0000-0000-000000005502','91de91de-0000-0000-0000-000000000001','91de91de-0000-0000-0000-0000000000fd','91de-fd@example.com','front_desk','active'),
  ('91de91de-0000-0000-0000-000000005503','91de91de-0000-0000-0000-000000000001','91de91de-0000-0000-0000-0000000000e5','91de-ins@example.com','instructor','active');
insert into instructors (id, studio_id, staff_id, display_name, status) values
  ('91de91de-0000-0000-0000-00000000001a','91de91de-0000-0000-0000-000000000001','91de91de-0000-0000-0000-000000005503','Coach','active');

insert into locations (id, studio_id, name, is_primary) values
  ('91de91de-0000-0000-0000-0000000000aa','91de91de-0000-0000-0000-000000000001','Main',true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('91de91de-0000-0000-0000-0000000000a1','91de91de-0000-0000-0000-000000000001','91de91de-0000-0000-0000-0000000000aa','RA',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('91de91de-0000-0000-0000-00000000c7a1','91de91de-0000-0000-0000-000000000001','Flow',50,10);

insert into members (id, studio_id, user_id, first_name, last_name, email, status, waiver_signed_at) values
  ('91de91de-0000-0000-0000-00000000a0aa','91de91de-0000-0000-0000-000000000001','91de91de-0000-0000-0000-0000000a0001','Mia','A','91de-ma@example.com','active', now()),
  ('91de91de-0000-0000-0000-00000000c0cc','91de91de-0000-0000-0000-000000000001','91de91de-0000-0000-0000-0000000c0001','Cal','C','91de-mc@example.com','active', now()),
  ('91de91de-0000-0000-0000-0000000001ee','91de91de-0000-0000-0000-000000000001','91de91de-0000-0000-0000-000000010001','Lee','L','91de-ml@example.com','lead', now());

-- H +10 (core), V +13 (core), B +15 (flex, MA books), F +17 (core, free-first).
insert into class_occurrences
  (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, starts_at, ends_at, status, guarantee_tier, flex) values
  ('91de91de-0000-0000-0000-0000000000f1','91de91de-0000-0000-0000-000000000001','91de91de-0000-0000-0000-0000000000aa','91de91de-0000-0000-0000-00000000c7a1','91de91de-0000-0000-0000-0000000000a1','91de91de-0000-0000-0000-00000000001a','Flow H',10, now()+interval '10 days', now()+interval '10 days'+interval '50 min','scheduled','core',false),
  ('91de91de-0000-0000-0000-0000000000f2','91de91de-0000-0000-0000-000000000001','91de91de-0000-0000-0000-0000000000aa','91de91de-0000-0000-0000-00000000c7a1','91de91de-0000-0000-0000-0000000000a1','91de91de-0000-0000-0000-00000000001a','Flow V',10, now()+interval '13 days', now()+interval '13 days'+interval '50 min','scheduled','core',false),
  ('91de91de-0000-0000-0000-0000000000f3','91de91de-0000-0000-0000-000000000001','91de91de-0000-0000-0000-0000000000aa','91de91de-0000-0000-0000-00000000c7a1','91de91de-0000-0000-0000-0000000000a1','91de91de-0000-0000-0000-00000000001a','Flow B',10, now()+interval '15 days', now()+interval '15 days'+interval '50 min','scheduled','flex',true),
  ('91de91de-0000-0000-0000-0000000000f4','91de91de-0000-0000-0000-000000000001','91de91de-0000-0000-0000-0000000000aa','91de91de-0000-0000-0000-00000000c7a1','91de91de-0000-0000-0000-0000000000a1','91de91de-0000-0000-0000-00000000001a','Flow F',10, now()+interval '17 days', now()+interval '17 days'+interval '50 min','scheduled','core',false);

-- MA books B (flex, not committed → a pending booking).
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at) values
  ('91de91de-0000-0000-0000-00000000b0ab','91de91de-0000-0000-0000-000000000001','91de91de-0000-0000-0000-0000000000f3','91de91de-0000-0000-0000-00000000a0aa','booked','member','comp', now());
update class_occurrences set booked_count = 1 where id = '91de91de-0000-0000-0000-0000000000f3';

-- =============================================================================
-- 1. set_occurrence_visibility — manager-up, front desk & instructor refused.
-- =============================================================================
select expect_text('front desk cannot hide a class (PT403)',
  t91x_sov('91de91de-0000-0000-0000-0000000000fd','91de91de-0000-0000-0000-0000000000f1', false), 'ERR:PT403');
select expect_text('an instructor cannot hide a class (PT403)',
  t91x_sov('91de91de-0000-0000-0000-0000000000e5','91de91de-0000-0000-0000-0000000000f1', false), 'ERR:PT403');
select expect_text('owner hides H',
  t91x_sov('91de91de-0000-0000-0000-0000000000a1','91de91de-0000-0000-0000-0000000000f1', false), 'OK:hidden');
select expect_true('H is now hidden_from_members',
  (select hidden_from_members from class_occurrences where id='91de91de-0000-0000-0000-0000000000f1'));
select expect_num('hiding wrote exactly one audit row',
  (select count(*) from audit_logs where entity_id='91de91de-0000-0000-0000-0000000000f1' and action='occurrence.visibility_set')::bigint, 1);
select expect_text('the audit row records hidden=true',
  (select after->>'hidden_from_members' from audit_logs where entity_id='91de91de-0000-0000-0000-0000000000f1' and action='occurrence.visibility_set'), 'true');
select expect_text('set_occurrence_visibility on a missing class → no_such_class',
  t91x_sov('91de91de-0000-0000-0000-0000000000a1','91de91de-0000-0000-0000-00000000dead', false), 'no_such_class');

-- =============================================================================
-- 2. member RLS (occ_member_read) — H gone for a member, present for staff.
-- =============================================================================
select expect_num('RLS: MC cannot see hidden H', t91x_sees('91de91de-0000-0000-0000-0000000c0001','91de91de-0000-0000-0000-0000000000f1'), 0);
select expect_num('RLS: MC sees visible V', t91x_sees('91de91de-0000-0000-0000-0000000c0001','91de91de-0000-0000-0000-0000000000f2'), 1);
-- staff (owner) and the instructor still see H directly.
set role authenticated; select set_config('request.jwt.claim.sub','91de91de-0000-0000-0000-0000000000a1',false);
select expect_num('RLS: owner still sees hidden H', (select count(*) from class_occurrences where id='91de91de-0000-0000-0000-0000000000f1')::bigint, 1);
reset role; select set_config('request.jwt.claim.sub', null, false);
set role authenticated; select set_config('request.jwt.claim.sub','91de91de-0000-0000-0000-0000000000e5',false);
select expect_num('RLS: instructor (staff) still sees hidden H', (select count(*) from class_occurrences where id='91de91de-0000-0000-0000-0000000000f1')::bigint, 1);
reset role; select set_config('request.jwt.claim.sub', null, false);

-- =============================================================================
-- 3. public_schedule omits the hidden class; book paths refuse it.
-- =============================================================================
select expect_false('public_schedule omits hidden H',
  (select exists (select 1 from jsonb_array_elements(public_schedule('91de-a', 30) -> 'classes') e
                   where e ->> 'id' = '91de91de-0000-0000-0000-0000000000f1')));
select expect_true('public_schedule includes visible V',
  (select exists (select 1 from jsonb_array_elements(public_schedule('91de-a', 30) -> 'classes') e
                   where e ->> 'id' = '91de91de-0000-0000-0000-0000000000f2')));
select expect_text('book_class H (member) → class_hidden',
  t91x_bk('91de91de-0000-0000-0000-0000000000f1','91de91de-0000-0000-0000-00000000c0cc','member'), 'class_hidden');
select expect_text('book_class H from the DESK (front_desk source) → class_hidden',
  t91x_bk('91de91de-0000-0000-0000-0000000000f1','91de91de-0000-0000-0000-00000000c0cc','front_desk'), 'class_hidden');
select expect_text('book_class V (visible) is NOT refused for hiding',
  (case when t91x_bk('91de91de-0000-0000-0000-0000000000f2','91de91de-0000-0000-0000-00000000c0cc','member') = 'class_hidden' then 'class_hidden' else 'other' end), 'other');

-- =============================================================================
-- 4. a member already booked keeps the class and can cancel it.
-- =============================================================================
-- MA is booked on flex B (pending). Hide B.
select expect_text('owner hides B (MA is booked on it)',
  t91x_sov('91de91de-0000-0000-0000-0000000000a1','91de91de-0000-0000-0000-0000000000f3', false), 'OK:hidden');
select expect_num('RLS: booked MA still sees hidden B (own-read)', t91x_sees('91de91de-0000-0000-0000-0000000a0001','91de91de-0000-0000-0000-0000000000f3'), 1);
select expect_num('RLS: non-booked MC cannot see hidden B', t91x_sees('91de91de-0000-0000-0000-0000000c0001','91de91de-0000-0000-0000-0000000000f3'), 0);
select expect_text('book_class B for the already-booked MA is NOT class_hidden',
  (case when t91x_bk('91de91de-0000-0000-0000-0000000000f3','91de91de-0000-0000-0000-00000000a0aa','member') = 'class_hidden' then 'class_hidden' else 'other' end), 'other');
-- member_pending_bookings (flex, not committed) still returns B for MA while hidden.
set role authenticated; select set_config('request.jwt.claim.sub','91de91de-0000-0000-0000-0000000a0001',false);
select expect_num('MA still has B in member_pending_bookings while hidden',
  (select count(*) from member_pending_bookings('91de91de-0000-0000-0000-000000000001') where occurrence_id='91de91de-0000-0000-0000-0000000000f3')::bigint, 1);
-- and MA can cancel their hidden booking.
select cancel_booking('91de91de-0000-0000-0000-00000000b0ab');
reset role; select set_config('request.jwt.claim.sub', null, false);
select expect_text('MA cancelled their booking on the hidden class',
  (select status::text from bookings where id='91de91de-0000-0000-0000-00000000b0ab'), 'cancelled');

-- =============================================================================
-- 5. member_next_class_day skips a hidden day.
-- =============================================================================
-- With H (+10) hidden, the earliest member-visible day is V (+13). Compare to the
-- studio-local date of each occurrence so the assertion holds on any run date.
set role authenticated; select set_config('request.jwt.claim.sub','91de91de-0000-0000-0000-0000000c0001',false);
select expect_text('member_next_class_day returns V''s day, not hidden H''s',
  (member_next_class_day('91de91de-0000-0000-0000-000000000001') ->> 'date'),
  (select (starts_at at time zone 'Europe/Prague')::date::text from class_occurrences where id='91de91de-0000-0000-0000-0000000000f2'));
reset role; select set_config('request.jwt.claim.sub', null, false);
-- show H again → it is the earliest once more.
select expect_text('owner shows H again', t91x_sov('91de91de-0000-0000-0000-0000000000a1','91de91de-0000-0000-0000-0000000000f1', true), 'OK:shown');
set role authenticated; select set_config('request.jwt.claim.sub','91de91de-0000-0000-0000-0000000c0001',false);
select expect_text('with H shown, member_next_class_day returns H''s day',
  (member_next_class_day('91de91de-0000-0000-0000-000000000001') ->> 'date'),
  (select (starts_at at time zone 'Europe/Prague')::date::text from class_occurrences where id='91de91de-0000-0000-0000-0000000000f1'));
reset role; select set_config('request.jwt.claim.sub', null, false);

-- =============================================================================
-- 6. the free-first nudge/picker excludes a hidden class.
-- =============================================================================
select expect_true('F is in the free-first eligible list while visible',
  (select exists (select 1 from free_first_eligible_classes_run('91de91de-0000-0000-0000-000000000001','91de91de-0000-0000-0000-0000000001ee', 0)
                   where occurrence_id='91de91de-0000-0000-0000-0000000000f4')));
select expect_text('owner hides F', t91x_sov('91de91de-0000-0000-0000-0000000000a1','91de91de-0000-0000-0000-0000000000f4', false), 'OK:hidden');
select expect_false('F is GONE from the free-first eligible list once hidden',
  (select exists (select 1 from free_first_eligible_classes_run('91de91de-0000-0000-0000-000000000001','91de91de-0000-0000-0000-0000000001ee', 0)
                   where occurrence_id='91de91de-0000-0000-0000-0000000000f4')));
set role authenticated; select set_config('request.jwt.claim.sub','91de91de-0000-0000-0000-000000010001',false);
select expect_text('book_first_free on the hidden F → class_hidden',
  coalesce(book_first_free('91de91de-0000-0000-0000-0000000000f4') ->> 'reason', 'OK'), 'class_hidden');
reset role; select set_config('request.jwt.claim.sub', null, false);

-- =============================================================================
-- 7. schedule_range (staff) still returns H, flagged occ_hidden=true.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','91de91de-0000-0000-0000-0000000000a1',false);
-- H was shown again in step 5; hide it once more so the flag is observable here.
select set_occurrence_visibility('91de91de-0000-0000-0000-0000000000f1', false);
select expect_true('schedule_range returns H for staff with occ_hidden=true',
  (select occ_hidden from schedule_range('91de91de-0000-0000-0000-000000000001',
     (now() at time zone 'Europe/Prague')::date, (now() at time zone 'Europe/Prague')::date + 20)
    where occ_id='91de91de-0000-0000-0000-0000000000f1'));
select expect_false('schedule_range V occ_hidden=false',
  (select occ_hidden from schedule_range('91de91de-0000-0000-0000-000000000001',
     (now() at time zone 'Europe/Prague')::date, (now() at time zone 'Europe/Prague')::date + 20)
    where occ_id='91de91de-0000-0000-0000-0000000000f2'));
reset role; select set_config('request.jwt.claim.sub', null, false);

-- =============================================================================
-- 8. hiding/showing writes NO notification rows (a hide/show cycle on V, which
--    has no bookings, leaves the SA notification count unchanged — set_occurrence_
--    visibility writes only audit_logs, never a member message).
-- =============================================================================
do $$
declare before_n bigint; after_n bigint;
begin
  select count(*) into before_n from notifications where studio_id='91de91de-0000-0000-0000-000000000001';
  perform set_config('request.jwt.claim.sub','91de91de-0000-0000-0000-0000000000a1', true);
  set local role authenticated;
  perform set_occurrence_visibility('91de91de-0000-0000-0000-0000000000f2', false);
  perform set_occurrence_visibility('91de91de-0000-0000-0000-0000000000f2', true);
  reset role;
  select count(*) into after_n from notifications where studio_id='91de91de-0000-0000-0000-000000000001';
  perform expect_num('a hide/show cycle queues no notifications (delta 0)', after_n - before_n, 0);
end $$;

-- =============================================================================
-- 9. the anon surface is still EXACTLY THIRTEEN (suite helpers excluded).
-- =============================================================================
select expect_num('anon surface is exactly thirteen',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname='public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not like 'expect%' and p.proname not like 't91x%')::bigint, 13);

select 'hide_class_test OK' as result;
