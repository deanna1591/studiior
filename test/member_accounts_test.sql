-- =============================================================================
-- STUDIIOR — MEMBER ACCOUNTS (migrations 027 and 028)
--
--   a claim links exactly one member; an unverified email cannot claim an
--   existing member; a used or expired token fails; one login can hold
--   memberships at two studios without either seeing the other; and a lead may
--   book a drop-in but nothing else — Decision 15.
--
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -f test/member_accounts_test.sql
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

-- --- Fixtures: abab, checked free before use ---------------------------------------------------------

insert into auth.users (id) values ('abababab-0000-0000-0000-0000000000a1');
insert into profiles (id, email) values ('abababab-0000-0000-0000-0000000000a1','acct-desk@example.com');

insert into studios (id, name, slug, timezone, currency, status) values
  ('abababab-0000-0000-0000-000000000001','Account Studio','accounts-test','Europe/Prague','CZK','active'),
  ('abababab-0000-0000-0000-000000000002','Second Studio','accounts-other','Europe/Prague','CZK','active');
insert into studio_settings (studio_id) values
  ('abababab-0000-0000-0000-000000000001'),('abababab-0000-0000-0000-000000000002');
insert into locations (id, studio_id, name, is_primary) values
  ('abababab-0000-0000-0000-00000000000c','abababab-0000-0000-0000-000000000001','Main',true),
  ('abababab-0000-0000-0000-00000000000d','abababab-0000-0000-0000-000000000002','Main',true);
insert into studio_staff (studio_id, user_id, email, role) values
  ('abababab-0000-0000-0000-000000000001','abababab-0000-0000-0000-0000000000a1','acct-desk@example.com','front_desk'),
  ('abababab-0000-0000-0000-000000000002','abababab-0000-0000-0000-0000000000a1','acct-desk@example.com','front_desk');

insert into members (id, studio_id, first_name, last_name, email, joined_on, status, waiver_signed_at) values
  ('abababab-0000-0000-0000-00000000dd01','abababab-0000-0000-0000-000000000001',
   'Vera','Verified','vera@example.com', current_date - 60, 'active', now()),
  -- The same person at a second studio. One email, so one account is the only
  -- thing auth.users will allow.
  ('abababab-0000-0000-0000-00000000dd02','abababab-0000-0000-0000-000000000002',
   'Vera','Verified','vera@example.com', current_date - 30, 'active', now());

-- =============================================================================
-- 1. An invite claims exactly one member
-- =============================================================================

set role authenticated;
select set_config('request.jwt.claim.sub','abababab-0000-0000-0000-0000000000a1',false);
select set_config('a.tok',
  (select token from create_member_invite('abababab-0000-0000-0000-00000000dd01')), false);
reset role;

select expect_num('the invite stores a hash, never the token',
  (select count(*) from member_invites where token_hash = current_setting('a.tok')), 0);
select expect_num('and one row exists for it',
  (select count(*) from member_invites where member_id='abababab-0000-0000-0000-00000000dd01'), 1);

set role anon;
select expect_text('the link can name the studio before anyone signs in',
  (select studio_name from member_invite_preview(current_setting('a.tok'))), 'Account Studio');
select set_config('a.claim',
  (claim_member_account(current_setting('a.tok'), 'a-good-password', 'Vera Verified'))::text, false);
reset role;

select expect_text('claiming succeeds',
  coalesce((current_setting('a.claim')::member_claim).failure_reason, 'ok'), 'ok');
select expect_num('exactly one member row is linked',
  (select count(*) from members where user_id = (current_setting('a.claim')::member_claim).user_id), 1);
select expect_text('and it is the one the invite named',
  (select id::text from members where user_id = (current_setting('a.claim')::member_claim).user_id),
  'abababab-0000-0000-0000-00000000dd01');
select expect_num('the OTHER studio''s record for the same person is untouched',
  (select count(*) from members
    where id='abababab-0000-0000-0000-00000000dd02' and user_id is null), 1);

-- A used token is dead.
set role anon;
select set_config('a.again',
  (claim_member_account(current_setting('a.tok'), 'another-password'))::text, false);
reset role;
select expect_text('a used token fails',
  (current_setting('a.again')::member_claim).failure_reason, 'token_used');

-- So is an expired one.
set role authenticated;
select set_config('request.jwt.claim.sub','abababab-0000-0000-0000-0000000000a1',false);
insert into members (id, studio_id, first_name, last_name, email, joined_on)
values ('abababab-0000-0000-0000-00000000dd03','abababab-0000-0000-0000-000000000001',
        'Ex','Pired','expired@example.com', current_date - 10);
select set_config('a.tok2',
  (select token from create_member_invite('abababab-0000-0000-0000-00000000dd03')), false);
reset role;
update member_invites set expires_at = now() - interval '1 day'
 where member_id = 'abababab-0000-0000-0000-00000000dd03';
set role anon;
select expect_text('an expired token fails',
  (claim_member_account(current_setting('a.tok2'), 'a-good-password')).failure_reason,
  'token_expired');
select expect_text('and nonsense fails',
  (claim_member_account('not-a-real-token', 'a-good-password')).failure_reason,
  'invalid_token');
reset role;

-- =============================================================================
-- 2. Self signup — the match waits for verification
--
-- The whole security of this feature. members is unique on (studio_id, email),
-- so an address names a person; linking before the address is proven hands
-- their attendance and payment history to anyone who knows it.
-- =============================================================================

insert into members (id, studio_id, first_name, last_name, email, joined_on, status, waiver_signed_at)
values ('abababab-0000-0000-0000-00000000dd04','abababab-0000-0000-0000-000000000001',
        'Target','Member','target@example.com', current_date - 200, 'active', now());

-- An attacker signs up with the victim's address. Supabase creates the auth
-- user; email_confirmed_at stays null until they prove they own it.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                        email_confirmed_at, created_at, updated_at,
                        confirmation_token, recovery_token, email_change,
                        email_change_token_new, email_change_token_current,
                        phone_change, phone_change_token, reauthentication_token)
values ('abababab-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-000000000000',
        'authenticated','authenticated','target@example.com','x',
        null, now(), now(), '','','','','','','','');
insert into profiles (id, email, full_name)
values ('abababab-0000-0000-0000-0000000000b1','target@example.com','Not The Owner');

set role authenticated;
select set_config('request.jwt.claim.sub','abababab-0000-0000-0000-0000000000b1',false);
select expect_text('an UNVERIFIED email cannot claim an existing member',
  (claim_member_by_email('abababab-0000-0000-0000-000000000001')).failure_reason,
  'email_not_verified');
reset role;

select expect_num('and the member record was not touched',
  (select count(*) from members
    where id='abababab-0000-0000-0000-00000000dd04' and user_id is null), 1);

-- Verify the address, and the same call now links.
update auth.users set email_confirmed_at = now()
 where id = 'abababab-0000-0000-0000-0000000000b1';

set role authenticated;
select set_config('request.jwt.claim.sub','abababab-0000-0000-0000-0000000000b1',false);
select set_config('a.self',
  (claim_member_by_email('abababab-0000-0000-0000-000000000001'))::text, false);
select expect_text('once verified, the same call links',
  coalesce((current_setting('a.self')::member_claim).failure_reason, 'ok'), 'ok');
select expect_text('and running it again is a no-op, not a second link',
  coalesce((claim_member_by_email('abababab-0000-0000-0000-000000000001')).failure_reason, 'ok'), 'ok');
reset role;

select expect_num('still exactly one member linked to that account',
  (select count(*) from members where user_id='abababab-0000-0000-0000-0000000000b1'), 1);

-- Nobody else can take a member that is already claimed.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                        email_confirmed_at, created_at, updated_at,
                        confirmation_token, recovery_token, email_change,
                        email_change_token_new, email_change_token_current,
                        phone_change, phone_change_token, reauthentication_token)
values ('abababab-0000-0000-0000-0000000000b2','00000000-0000-0000-0000-000000000000',
        'authenticated','authenticated','target2@example.com','x',
        now(), now(), now(), '','','','','','','','');
insert into profiles (id, email, full_name)
values ('abababab-0000-0000-0000-0000000000b2','target2@example.com','Someone Else');
update members set email = 'target2@example.com' where id='abababab-0000-0000-0000-00000000dd04';

set role authenticated;
select set_config('request.jwt.claim.sub','abababab-0000-0000-0000-0000000000b2',false);
select expect_text('a claimed member cannot be claimed again',
  (claim_member_by_email('abababab-0000-0000-0000-000000000001')).failure_reason,
  'already_claimed');
reset role;

-- No match at all: a genuinely new walk-in becomes a lead.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                        email_confirmed_at, created_at, updated_at,
                        confirmation_token, recovery_token, email_change,
                        email_change_token_new, email_change_token_current,
                        phone_change, phone_change_token, reauthentication_token)
values ('abababab-0000-0000-0000-0000000000b3','00000000-0000-0000-0000-000000000000',
        'authenticated','authenticated','walkin@example.com','x',
        now(), now(), now(), '','','','','','','','');
insert into profiles (id, email, full_name)
values ('abababab-0000-0000-0000-0000000000b3','walkin@example.com','Walk In');

set role authenticated;
select set_config('request.jwt.claim.sub','abababab-0000-0000-0000-0000000000b3',false);
select set_config('a.lead',
  (claim_member_by_email('abababab-0000-0000-0000-000000000001'))::text, false);
reset role;
select expect_text('an unmatched signup becomes a lead',
  (select status::text from members
    where id = (current_setting('a.lead')::member_claim).member_id), 'lead');
select expect_text('recorded as having come in on their own',
  (select source from members
    where id = (current_setting('a.lead')::member_claim).member_id), 'self_signup');

-- =============================================================================
-- 3. One login, two studios — the correction to Permissions line 267
-- =============================================================================

set role authenticated;
select set_config('request.jwt.claim.sub','abababab-0000-0000-0000-0000000000a1',false);
select set_config('a.tok3',
  (select token from create_member_invite('abababab-0000-0000-0000-00000000dd02')), false);
reset role;

set role anon;
select set_config('a.claim2',
  (claim_member_account(current_setting('a.tok3'), 'a-good-password'))::text, false);
reset role;

select expect_text('the second studio links to the SAME account, not a new one',
  (current_setting('a.claim2')::member_claim).user_id::text,
  (current_setting('a.claim')::member_claim).user_id::text);
select expect_num('one login, two member records',
  (select count(*) from members where user_id = (current_setting('a.claim')::member_claim).user_id), 2);
select expect_num('in two different studios',
  (select count(distinct studio_id) from members
    where user_id = (current_setting('a.claim')::member_claim).user_id), 2);

-- What that account can reach is its own two records and nobody else's.
set role authenticated;
select set_config('request.jwt.claim.sub',
  (current_setting('a.claim')::member_claim).user_id::text, false);
select expect_num('and it sees only its own two member rows, not the studios'' others',
  (select count(*) from members), 2);
reset role;

-- =============================================================================
-- 4. Decision 15 — a lead may book a drop-in, and only that
-- =============================================================================

insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('abababab-0000-0000-0000-00000000cc01','abababab-0000-0000-0000-000000000001','Reformer',50,10);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('abababab-0000-0000-0000-00000000ee01','abababab-0000-0000-0000-000000000001',
   'abababab-0000-0000-0000-00000000000c','Studio A',10);
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               starts_at, ends_at, capacity, status) values
  ('abababab-0000-0000-0000-00000000bb01','abababab-0000-0000-0000-000000000001',
   'abababab-0000-0000-0000-00000000000c','abababab-0000-0000-0000-00000000cc01',
   'abababab-0000-0000-0000-00000000ee01','Tomorrow 7am',
   now() + interval '1 day', now() + interval '1 day' + interval '50 min', 10, 'scheduled');

select set_config('a.leadid',
  (current_setting('a.lead')::member_claim).member_id::text, false);
update members set waiver_signed_at = now() where id = current_setting('a.leadid')::uuid;

set role authenticated;
select set_config('request.jwt.claim.sub','abababab-0000-0000-0000-0000000000b3',false);
select set_config('a.book',
  (book_class('abababab-0000-0000-0000-00000000bb01',
              current_setting('a.leadid')::uuid, 'member'))::text, false);
reset role;

select expect_text('a lead can book tomorrow''s 7am',
  coalesce((current_setting('a.book')::book_class_result).failure_reason, 'ok'), 'ok');
select expect_text('and it resolves to drop-in, because they have bought nothing',
  (current_setting('a.book')::book_class_result).payment_source::text, 'drop_in');
select expect_text('booking does not promote them — status is what staff set',
  (select status::text from members where id = current_setting('a.leadid')::uuid), 'lead');

-- A lead with a plan attached but never activated must not spend its credits.
insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, validity_days)
values ('abababab-0000-0000-0000-00000000aa01','abababab-0000-0000-0000-000000000001',
        '10-Class Pack','class_pack',500000,'CZK',10,180);
insert into memberships (studio_id, member_id, plan_id, status, price_cents, currency,
                         starts_on, expires_on, credits_remaining)
values ('abababab-0000-0000-0000-000000000001', current_setting('a.leadid')::uuid,
        'abababab-0000-0000-0000-00000000aa01','active',500000,'CZK',
        current_date, current_date + 180, 10);
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               starts_at, ends_at, capacity, status) values
  ('abababab-0000-0000-0000-00000000bb02','abababab-0000-0000-0000-000000000001',
   'abababab-0000-0000-0000-00000000000c','abababab-0000-0000-0000-00000000cc01',
   'abababab-0000-0000-0000-00000000ee01','Day after',
   now() + interval '2 days', now() + interval '2 days' + interval '50 min', 10, 'scheduled');

set role authenticated;
select set_config('request.jwt.claim.sub','abababab-0000-0000-0000-0000000000b3',false);
select expect_text('a lead may not spend credits nobody activated them for',
  (book_class('abababab-0000-0000-0000-00000000bb02',
              current_setting('a.leadid')::uuid, 'member')).failure_reason,
  'member_not_active');
reset role;
select expect_num('and the credits are untouched',
  (select credits_remaining from memberships where member_id = current_setting('a.leadid')::uuid), 10);

-- Everything else rule 5 refused, it still refuses.
update members set status = 'inactive' where id = current_setting('a.leadid')::uuid;
set role authenticated;
select set_config('request.jwt.claim.sub','abababab-0000-0000-0000-0000000000b3',false);
select expect_text('an inactive member is still refused',
  (book_class('abababab-0000-0000-0000-00000000bb02',
              current_setting('a.leadid')::uuid, 'member')).failure_reason,
  'member_not_active');
reset role;

select expect_text('rule 5 passes exactly two statuses',
  book_class_status_ok('active')::text || book_class_status_ok('lead')::text
  || book_class_status_ok('inactive')::text || book_class_status_ok('archived')::text,
  'truetruefalsefalse');

-- =============================================================================
-- 5. Permissions §5 — instructors never
-- =============================================================================

insert into auth.users (id) values ('abababab-0000-0000-0000-0000000000a9');
insert into profiles (id, email) values ('abababab-0000-0000-0000-0000000000a9','acct-inst@example.com');
insert into studio_staff (studio_id, user_id, email, role) values
  ('abababab-0000-0000-0000-000000000001','abababab-0000-0000-0000-0000000000a9','acct-inst@example.com','instructor');

set role authenticated;
select set_config('request.jwt.claim.sub','abababab-0000-0000-0000-0000000000a9',false);
do $$
begin
  perform create_member_invite('abababab-0000-0000-0000-00000000dd03');
  raise exception 'FAIL  an instructor invited a member';
exception when sqlstate 'PT403' then
  raise notice 'PASS  an instructor cannot invite a member';
end $$;
select expect_num('and cannot read the invites',
  (select count(*) from member_invites), 0);
reset role;

-- =============================================================================
-- A member owns their contact details and nothing else (migration 035)
-- =============================================================================
-- members_self_update is `using (user_id = auth.uid())` with no column
-- restriction, and authenticated holds UPDATE on all 28 columns — RLS is
-- row-level and decides which ROWS, never which columns. Before the guard a
-- member could sign her own waiver and promote herself past the §2.1 gate.

-- Vera claimed an account earlier in this suite, so she is a member editing her
-- own row — which is exactly the case the guard exists for.
select set_config('a.vera_uid',
  (select user_id::text from members where id = 'abababab-0000-0000-0000-00000000dd01'), false);

set role authenticated;
select set_config('request.jwt.claim.sub', current_setting('a.vera_uid'), false);

do $$
begin
  update members set waiver_signed_at = now() - interval '1 day'
   where id = 'abababab-0000-0000-0000-00000000dd01';
  raise exception 'FAIL  a member signed her own waiver';
exception when sqlstate 'PT403' then
  raise notice 'PASS  a member cannot sign her own waiver';
end $$;

do $$
begin
  update members set status = 'lead' where id = 'abababab-0000-0000-0000-00000000dd01';
  raise exception 'FAIL  a member changed her own status';
exception when sqlstate 'PT403' then
  raise notice 'PASS  a member cannot change her own status';
end $$;

do $$
begin
  update members set health_band = 'healthy', lifetime_visits = 999
   where id = 'abababab-0000-0000-0000-00000000dd01';
  raise exception 'FAIL  a member rewrote her own health and visit count';
exception when sqlstate 'PT403' then
  raise notice 'PASS  a member cannot rewrite her health band or visit count';
end $$;

-- Moving a row to another studio would be a tenant break, not just an edit.
do $$
begin
  update members set studio_id = 'abababab-0000-0000-0000-000000000002'
   where id = 'abababab-0000-0000-0000-00000000dd01';
  raise exception 'FAIL  a member moved herself to another studio';
exception when sqlstate 'PT403' or sqlstate '42501' then
  raise notice 'PASS  a member cannot move herself to another studio';
end $$;

-- And the things that ARE hers.
update members
   set preferred_name = 'Vee', phone = '+420 700 000 111',
       avatar_url = 'abababab-0000-0000-0000-00000000dd01/a.jpg',
       emergency_contact = '{"name":"Kin","phone":"+420 700 000 222"}'::jsonb
 where id = 'abababab-0000-0000-0000-00000000dd01';
select expect_text('a member can set what we call her',
  (select preferred_name from members where id = 'abababab-0000-0000-0000-00000000dd01'), 'Vee');
select expect_text('...her own photograph',
  (select avatar_url from members where id = 'abababab-0000-0000-0000-00000000dd01'),
  'abababab-0000-0000-0000-00000000dd01/a.jpg');
select expect_text('...and her emergency contact',
  (select emergency_contact ->> 'name' from members where id = 'abababab-0000-0000-0000-00000000dd01'), 'Kin');
reset role;

-- Front desk is unaffected: editing a member is their job (Permissions §5).
-- Counting rows, because RLS refuses an UPDATE by making the row invisible and
-- PostgREST calls that a 200 with an empty array.
-- The front desk this suite already created at the top, reused rather than
-- inserted again: studio_staff is unique on (studio_id, lower(email)).
set role authenticated;
select set_config('request.jwt.claim.sub','abababab-0000-0000-0000-0000000000a1',false);
do $$
declare n int;
begin
  update members set status = 'lead', waiver_signed_at = now()
   where id = 'abababab-0000-0000-0000-00000000dd01';
  get diagnostics n = row_count;
  if n <> 1 then
    raise exception 'FAIL  the guard blocked front desk (% rows)', n;
  end if;
  raise notice 'PASS  front desk still edits a member, guard and all';
end $$;
reset role;

-- The storage policy scopes on the member's own id, the same shape as the
-- studio prefix in migration 029.
set role authenticated;
select set_config('request.jwt.claim.sub', current_setting('a.vera_uid'), false);
do $$
begin
  insert into storage.objects (bucket_id, name)
  values ('member-avatars', 'abababab-0000-0000-0000-00000000dd03/hijack.jpg');
  raise exception 'FAIL  a member wrote into another member''s avatar folder';
exception when insufficient_privilege or check_violation then
  raise notice 'PASS  a member cannot write into another member''s avatar folder';
end $$;
reset role;

select 'ALL MEMBER ACCOUNT TESTS PASSED' as result;
