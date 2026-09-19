-- =============================================================================
-- Decision 34 Part A — the versioned, signed waiver (migration 164).
-- UUID space a17e, checked free. Run after `supabase db reset`.
-- =============================================================================
-- A studio publishes a text waiver; a member signs the current version and gets
-- waiver_signed_at + a signed document + a signature row carrying the version's
-- hash and the member row's name (never client input). A new version without
-- requires_resign leaves the signature standing; with requires_resign the gate
-- (book_class 2.1.4) treats the older signature as unsigned until they re-sign.
-- The paper path records the version too. A stranger reads neither another
-- studio's waiver nor another member's signature.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if; end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin if actual then raise notice 'PASS  %  (got true)', label;
else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if; end $$;
create or replace function login(uid text) returns void
language plpgsql as $$ begin perform set_config('request.jwt.claim.sub', uid, false); end $$;
-- book_class failure_reason as text.
create or replace function bc_reason(occ uuid, mem uuid) returns text
language sql as $$ select to_jsonb(book_class(occ, mem, 'member'))->>'failure_reason' $$;

-- --- Fixtures ---------------------------------------------------------------
insert into auth.users (id) values
  ('a17ea17e-0000-0000-0000-0000000000a1'),   -- owner
  ('a17ea17e-0000-0000-0000-0000000000b1'),   -- member M (signs)
  ('a17ea17e-0000-0000-0000-0000000000b2'),   -- member N (stranger, other studio)
  ('a17ea17e-0000-0000-0000-0000000000d1');   -- desk (files paper)
insert into profiles (id, email) select id, id::text||'@example.com' from auth.users where id::text like 'a17ea17e%';

insert into studios (id, name, slug, timezone, currency, status) values
  ('a17ea17e-0000-0000-0000-000000000001','Waiver A','a17e-a','Europe/Prague','CZK','active'),
  ('a17ea17e-0000-0000-0000-000000000002','Waiver B','a17e-b','Europe/Prague','CZK','active');
insert into studio_settings (studio_id, require_waiver, booking_window_days) values
  ('a17ea17e-0000-0000-0000-000000000001', true, 30),
  ('a17ea17e-0000-0000-0000-000000000002', true, 30);
insert into locations (id, studio_id, name, is_primary) values
  ('a17ea17e-0000-0000-0000-00000000000a','a17ea17e-0000-0000-0000-000000000001','Main',true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('a17ea17e-0000-0000-0000-0000000000e1','a17ea17e-0000-0000-0000-000000000001','a17ea17e-0000-0000-0000-00000000000a','R1',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('a17ea17e-0000-0000-0000-0000000000c9','a17ea17e-0000-0000-0000-000000000001','Reformer',50,10);
insert into studio_staff (studio_id, user_id, email, role) values
  ('a17ea17e-0000-0000-0000-000000000001','a17ea17e-0000-0000-0000-0000000000a1','owa@example.com','owner'),
  ('a17ea17e-0000-0000-0000-000000000001','a17ea17e-0000-0000-0000-0000000000d1','deska@example.com','front_desk');
insert into members (id, studio_id, user_id, first_name, last_name, email, status, joined_on, source) values
  ('a17ea17e-0000-0000-0000-00000000ad01','a17ea17e-0000-0000-0000-000000000001','a17ea17e-0000-0000-0000-0000000000b1','Mimi','Signer','m@example.com','active',current_date,'walk_in'),
  ('a17ea17e-0000-0000-0000-00000000ad02','a17ea17e-0000-0000-0000-000000000002','a17ea17e-0000-0000-0000-0000000000b2','Nils','Stranger','n@example.com','active',current_date,'walk_in');
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, starts_at, ends_at, capacity, booked_count, status, staffing) values
  ('a17ea17e-0000-0000-0000-00000000c001','a17ea17e-0000-0000-0000-000000000001','a17ea17e-0000-0000-0000-00000000000a','a17ea17e-0000-0000-0000-0000000000c9','a17ea17e-0000-0000-0000-0000000000e1',null,'Reformer',now()+interval '3 days', now()+interval '3 days'+interval '50 min', 10, 0, 'scheduled','open');

-- =============================================================================
-- 1. The studio publishes a text waiver (v1).
-- =============================================================================
set role authenticated; select login('a17ea17e-0000-0000-0000-0000000000a1');
select set_config('t.v1', set_waiver_version('a17ea17e-0000-0000-0000-000000000001','text','WAIVER V1: I accept the risks.') ->> 'version_id', false);
select login(''); reset role;

select expect_num('one version exists', (select count(*) from waiver_versions where studio_id='a17ea17e-0000-0000-0000-000000000001'), 1);
select expect_text('its hash is sha256 of the body',
  (select content_hash from waiver_versions where id=current_setting('t.v1')::uuid),
  encode(digest('WAIVER V1: I accept the risks.','sha256'),'hex'));

-- =============================================================================
-- 2. The member reads the current version, unsigned; and cannot book yet.
-- =============================================================================
set role authenticated; select login('a17ea17e-0000-0000-0000-0000000000b1');
select expect_true('current_waiver returns v1, unsigned',
  (current_waiver('a17ea17e-0000-0000-0000-000000000001')->>'exists')::boolean
   and (current_waiver('a17ea17e-0000-0000-0000-000000000001')->>'version_id') = current_setting('t.v1')
   and not (current_waiver('a17ea17e-0000-0000-0000-000000000001')->>'signed')::boolean);
select expect_text('unsigned member is gated by the waiver',
  bc_reason('a17ea17e-0000-0000-0000-00000000c001','a17ea17e-0000-0000-0000-00000000ad01'), 'waiver_not_signed');

-- =============================================================================
-- 3. The member signs v1 (self-sign). waiver_signed_at set, document + signature.
-- =============================================================================
select sign_waiver_document('a17ea17e-0000-0000-0000-00000000ad01', current_setting('t.v1')::uuid,
  encode(digest('WAIVER V1: I accept the risks.','sha256'),'hex'),
  'a17ea17e-0000-0000-0000-000000000001/a17ea17e-0000-0000-0000-00000000ad01/waiver.pdf', 'waiver.pdf', 12345,
  'a17ea17e-0000-0000-0000-000000000001/a17ea17e-0000-0000-0000-00000000ad01/signature.png',
  'Mozilla/5.0 test', '203.0.113.9');
select login(''); reset role;

select expect_true('waiver_signed_at is set',
  (select waiver_signed_at is not null from members where id='a17ea17e-0000-0000-0000-00000000ad01'));
select expect_num('a signed waiver document was filed',
  (select count(*) from member_documents where member_id='a17ea17e-0000-0000-0000-00000000ad01' and kind='waiver'), 1);
select expect_num('a signature row was recorded against v1',
  (select count(*) from waiver_signatures where member_id='a17ea17e-0000-0000-0000-00000000ad01' and version_id=current_setting('t.v1')::uuid), 1);
select expect_text('the record carries v1''s hash',
  (select content_hash from waiver_signatures where member_id='a17ea17e-0000-0000-0000-00000000ad01' and version_id=current_setting('t.v1')::uuid),
  encode(digest('WAIVER V1: I accept the risks.','sha256'),'hex'));
select expect_text('the stored name is the MEMBER ROW''s, not client input',
  (select signed_name from waiver_signatures where member_id='a17ea17e-0000-0000-0000-00000000ad01' and version_id=current_setting('t.v1')::uuid),
  'Mimi Signer');
select expect_text('the provenance is captured (ip, method app)',
  (select method || ' ' || host(ip) from waiver_signatures where member_id='a17ea17e-0000-0000-0000-00000000ad01' and version_id=current_setting('t.v1')::uuid),
  'app 203.0.113.9');

-- Now the member passes the waiver gate.
set role authenticated; select login('a17ea17e-0000-0000-0000-0000000000b1');
select expect_true('a signed member is no longer waiver-gated',
  bc_reason('a17ea17e-0000-0000-0000-00000000c001','a17ea17e-0000-0000-0000-00000000ad01') is distinct from 'waiver_not_signed');
select login(''); reset role;

-- =============================================================================
-- 4. A new version WITHOUT requires_resign leaves the signature standing.
-- =============================================================================
set role authenticated; select login('a17ea17e-0000-0000-0000-0000000000a1');
select set_config('t.v2', set_waiver_version('a17ea17e-0000-0000-0000-000000000001','text','WAIVER V2: minor wording change.', null, null, false) ->> 'version_id', false);
select login(''); reset role;
set role authenticated; select login('a17ea17e-0000-0000-0000-0000000000b1');
select expect_true('v2 (no re-sign) — the v1 signature still passes the gate',
  bc_reason('a17ea17e-0000-0000-0000-00000000c001','a17ea17e-0000-0000-0000-00000000ad01') is distinct from 'waiver_not_signed');
select login(''); reset role;

-- =============================================================================
-- 5. A new version WITH requires_resign re-gates until they sign it.
-- =============================================================================
set role authenticated; select login('a17ea17e-0000-0000-0000-0000000000a1');
select set_config('t.v3', set_waiver_version('a17ea17e-0000-0000-0000-000000000001','text','WAIVER V3: NEW LIABILITY TERMS.', null, null, true) ->> 'version_id', false);
select login(''); reset role;
set role authenticated; select login('a17ea17e-0000-0000-0000-0000000000b1');
select expect_text('v3 requires re-sign — the member is gated again',
  bc_reason('a17ea17e-0000-0000-0000-00000000c001','a17ea17e-0000-0000-0000-00000000ad01'), 'waiver_not_signed');
select expect_true('current_waiver now reports v3 unsigned',
  (current_waiver('a17ea17e-0000-0000-0000-000000000001')->>'version_id')=current_setting('t.v3')
   and not (current_waiver('a17ea17e-0000-0000-0000-000000000001')->>'signed')::boolean);
select sign_waiver_document('a17ea17e-0000-0000-0000-00000000ad01', current_setting('t.v3')::uuid,
  encode(digest('WAIVER V3: NEW LIABILITY TERMS.','sha256'),'hex'),
  'a17ea17e-0000-0000-0000-000000000001/a17ea17e-0000-0000-0000-00000000ad01/waiver3.pdf', 'waiver3.pdf', 22222,
  'a17ea17e-0000-0000-0000-000000000001/a17ea17e-0000-0000-0000-00000000ad01/signature3.png', 'UA', null);
select expect_true('after re-signing v3 the gate opens again',
  bc_reason('a17ea17e-0000-0000-0000-00000000c001','a17ea17e-0000-0000-0000-00000000ad01') is distinct from 'waiver_not_signed');
select login(''); reset role;

-- Signing a NON-current version is refused (must sign the current one).
set role authenticated; select login('a17ea17e-0000-0000-0000-0000000000b1');
do $$ begin
  perform sign_waiver_document('a17ea17e-0000-0000-0000-00000000ad01', current_setting('t.v1')::uuid,
    encode(digest('WAIVER V1: I accept the risks.','sha256'),'hex'),
    'p/w.pdf','w.pdf',1,'p/s.png',null,null);
  raise exception 'FAIL signing a stale version was allowed';
exception when sqlstate 'PT409' then raise notice 'PASS  signing a non-current version is refused (PT409)';
end $$;
select login(''); reset role;

-- =============================================================================
-- 6. The paper path records the version too (method 'paper', no image).
-- =============================================================================
set role authenticated; select login('a17ea17e-0000-0000-0000-0000000000d1');   -- desk
-- Unsign the member's stamp is not needed; use a fresh unsigned member so the
-- paper filing sets the stamp AND records the current version (v3).
insert into members (id, studio_id, user_id, first_name, last_name, email, status, joined_on, source)
  values ('a17ea17e-0000-0000-0000-00000000ad03','a17ea17e-0000-0000-0000-000000000001',null,'Paula','Paper','paula@example.com','lead',current_date,'walk_in');
select record_document('a17ea17e-0000-0000-0000-00000000ad03','waiver','paper.pdf',
  'a17ea17e-0000-0000-0000-000000000001/a17ea17e-0000-0000-0000-00000000ad03/paper.pdf','application/pdf',999);
select login(''); reset role;
select expect_num('the paper filing recorded a signature against the current version (v3)',
  (select count(*) from waiver_signatures where member_id='a17ea17e-0000-0000-0000-00000000ad03'
     and version_id=current_setting('t.v3')::uuid and method='paper' and signature_path is null), 1);
select expect_text('...with the member row name',
  (select signed_name from waiver_signatures where member_id='a17ea17e-0000-0000-0000-00000000ad03'), 'Paula Paper');

-- =============================================================================
-- 7. A stranger reads neither another studio's waiver nor another's signature.
-- =============================================================================
set role authenticated; select login('a17ea17e-0000-0000-0000-0000000000b2');   -- Nils, studio B
do $$ begin
  perform current_waiver('a17ea17e-0000-0000-0000-000000000001');   -- studio A, not his
  raise exception 'FAIL a stranger read studio A''s waiver';
exception when sqlstate 'PT403' then raise notice 'PASS  a stranger cannot read another studio''s waiver (PT403)';
end $$;
select expect_num('a stranger sees none of another member''s signatures',
  (select count(*) from waiver_signatures where member_id='a17ea17e-0000-0000-0000-00000000ad01'), 0);
select login(''); reset role;

select 'ALL WAIVER TESTS PASSED' as done;
