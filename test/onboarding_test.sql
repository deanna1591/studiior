-- =============================================================================
-- STUDIIOR — ONBOARDING TEST SUITE (migration 012)
--
-- Invite-only provisioning: the platform operator creates a studio shell, the
-- owner accepts a single-use token, and that one act creates the account, makes
-- them Owner and takes the studio out of provisioning — atomically.
--
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -f test/onboarding_test.sql
--
-- Local stack only — it inserts fixtures and creates auth users.
-- =============================================================================

\set ON_ERROR_STOP on
set client_min_messages = notice;

create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then
    raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else
    raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null');
  end if;
end $$;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then
    raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else
    raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null');
  end if;
end $$;

create or replace function login(uid text) returns void
language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', uid, false); end $$;

-- --- Fixtures --------------------------------------------------------------
-- An operator (platform admin) and an ordinary staff user who is not one.

insert into auth.users (id) values
  ('88888888-0000-0000-0000-0000000000a1'),   -- operator
  ('88888888-0000-0000-0000-0000000000a2');   -- ordinary staff, NOT an admin
insert into profiles (id, email) values
  ('88888888-0000-0000-0000-0000000000a1','operator@example.com'),
  ('88888888-0000-0000-0000-0000000000a2','notadmin@example.com');
insert into platform_admins (user_id, email, note)
  values ('88888888-0000-0000-0000-0000000000a1','operator@example.com','test operator');

-- The non-admin is an owner of some other studio, so "not an admin" is being
-- tested rather than "not signed in".
insert into studios (id, name, slug, timezone, currency, status) values
  ('88888888-0000-0000-0000-000000000009','Someone Elses Studio','other-studio-test','Europe/Prague','CZK','active');
insert into studio_settings (studio_id) values ('88888888-0000-0000-0000-000000000009');
insert into studio_staff (studio_id, user_id, email, role) values
  ('88888888-0000-0000-0000-000000000009','88888888-0000-0000-0000-0000000000a2','notadmin@example.com','owner');

set role authenticated;

-- =============================================================================
-- 1. Only a platform admin may provision
-- =============================================================================

select login('88888888-0000-0000-0000-0000000000a2');   -- owner elsewhere, not an admin
select expect_text('a studio owner who is not a platform admin cannot provision',
  (select failure_reason from provision_studio('Sneaky','sneaky','Europe/Prague','CZK','CZ','x@example.com')),
  'not_platform_admin');
select expect_num('and no studio was created',
  (select count(*) from studios where slug = 'sneaky'), 0);
select expect_text('is_platform_admin says no',
  (select is_platform_admin()::text), 'false');

select login('');                                        -- signed out
select expect_text('an anonymous caller cannot provision',
  (select failure_reason from provision_studio('Anon','anon-studio','Europe/Prague','CZK','CZ','x@example.com')),
  'not_platform_admin');

select login('88888888-0000-0000-0000-0000000000a1');   -- the operator
select expect_text('is_platform_admin says yes',
  (select is_platform_admin()::text), 'true');

-- =============================================================================
-- 2. Provisioning produces a shell in 'provisioning' plus one invite
-- =============================================================================

-- The token is stashed in a session GUC rather than a temp table: this suite
-- switches roles constantly, and a temp table owned by postgres is unreadable
-- once you `set role authenticated`.
select set_config('test.token',
  (select invite_token from provision_studio(
     'Bright Pilates','bright-test','Europe/London','GBP','GB','owner@bright.example')), false);

select expect_num('one studio created', (select count(*) from studios where slug='bright-test'), 1);
select expect_text('it starts in provisioning',
  (select status from studios where slug='bright-test'), 'provisioning');

-- The next three ask "did provision_studio write these rows", not "who may read
-- them", so they run with RLS out of the way. The operator is not staff of the
-- studio they just created, so through RLS every one of these counts as zero —
-- and "it has no owner yet" would have passed for entirely the wrong reason.
reset role;
select expect_num('with a settings row',
  (select count(*) from studio_settings ss join studios s on s.id=ss.studio_id where s.slug='bright-test'), 1);
select expect_num('and a primary location, so it can hold a class',
  (select count(*) from locations l join studios s on s.id=l.studio_id
    where s.slug='bright-test' and l.is_primary), 1);
select expect_num('it has no owner yet',
  (select count(*) from studio_staff ss join studios s on s.id=ss.studio_id
    where s.slug='bright-test' and ss.role='owner'), 0);
set role authenticated;
select login('88888888-0000-0000-0000-0000000000a1');

select expect_num('exactly one invite',
  (select count(*) from studio_invites i join studios s on s.id=i.studio_id where s.slug='bright-test'), 1);

-- The plaintext token is never stored — only its sha256.
select expect_num('the raw token is nowhere in the table',
  (select count(*) from studio_invites where token_hash = current_setting('test.token')), 0);
select expect_num('but its hash is',
  (select count(*) from studio_invites
    where token_hash = encode(extensions.digest(current_setting('test.token'),'sha256'),'hex')), 1);

select expect_text('a duplicate slug is refused',
  (select failure_reason from provision_studio('Copy','bright-test','Europe/London','GBP','GB','x@example.com')),
  'slug_taken');
select expect_text('a malformed slug is refused',
  (select failure_reason from provision_studio('Bad','Not A Slug!','Europe/London','GBP','GB','x@example.com')),
  'invalid_slug');
select expect_text('a malformed owner email is refused',
  (select failure_reason from provision_studio('Bad','bad-email-test','Europe/London','GBP','GB','nope')),
  'invalid_email');

-- A timezone typo does not fail loudly on its own: Europe/Pragu is not a zone,
-- and a studio stored with it has every class time quietly wrong from then on,
-- because occurrences are materialised against it (migration 015).
select expect_text('a timezone typo is refused',
  (select failure_reason from provision_studio('Typo','tz-typo-test','Europe/Pragu','CZK','CZ','a@example.com')),
  'invalid_timezone');
select expect_text('IANA matching is case-sensitive, so lowercase is refused too',
  (select failure_reason from provision_studio('Lower','tz-lower-test','europe/prague','CZK','CZ','a@example.com')),
  'invalid_timezone');
select expect_num('and neither wrote a studio',
  (select count(*) from studios where slug in ('tz-typo-test','tz-lower-test')), 0);
select expect_text('a non-ISO currency is refused',
  (select failure_reason from provision_studio('Cur','cur-test','Europe/London','pounds','GB','a@example.com')),
  'invalid_currency');
select expect_text('a non-ISO country is refused',
  (select failure_reason from provision_studio('Ctry','ctry-test','Europe/London','GBP','GBR','a@example.com')),
  'invalid_country');

-- =============================================================================
-- 3. A provisioning studio has no member-facing surface
-- =============================================================================

reset role; set role anon;
select expect_num('studio_by_slug does not return a provisioning studio',
  (select count(*) from studio_by_slug('bright-test')), 0);

-- =============================================================================
-- 4. The invite preview, for every state, as anon
-- =============================================================================

select expect_text('a garbage token previews as invalid',
  (select state from studio_invite_preview('not-a-real-token')), 'invalid');
select expect_text('a null token previews as invalid',
  (select state from studio_invite_preview(null)), 'invalid');
select expect_text('the real token previews as valid',
  (select state from studio_invite_preview(current_setting('test.token'))), 'valid');
select expect_text('and names the studio it is for',
  (select studio_name from studio_invite_preview(current_setting('test.token'))), 'Bright Pilates');

-- =============================================================================
-- 5. Accepting: one owner, atomically, and the studio leaves provisioning
-- =============================================================================

select expect_text('a short password is refused',
  (select failure_reason from accept_studio_invite(current_setting('test.token'), 'short', 'Bea Owner')),
  'password_too_short');
select expect_text('a missing name is refused',
  (select failure_reason from accept_studio_invite(current_setting('test.token'), 'longenoughpw', '   ')),
  'name_required');
-- Reading studio_invites is the operator's privilege, not anon's, so this
-- fixture check drops out of RLS rather than pretending otherwise.
reset role;
select expect_num('neither attempt consumed the invite',
  (select count(*) from studio_invites where accepted_at is not null), 0);
set role anon;

select expect_text('accepting succeeds',
  (select failure_reason from accept_studio_invite(
     current_setting('test.token'), 'a-good-password', 'Bea Owner')), null);

-- What follows verifies what the acceptance wrote. Reading studio_staff,
-- profiles and auth.users is nobody's business as anon, so this steps out of
-- RLS; the permission questions are section 1 and the end of section 7.
reset role;
select expect_num('exactly one owner now exists for that studio',
  (select count(*) from studio_staff ss join studios s on s.id=ss.studio_id
    where s.slug='bright-test' and ss.role='owner' and ss.status='active'), 1);
select expect_num('and exactly one staff row in total',
  (select count(*) from studio_staff ss join studios s on s.id=ss.studio_id
    where s.slug='bright-test'), 1);
select expect_text('the studio has left provisioning',
  (select status from studios where slug='bright-test'), 'active');
select expect_num('an auth account exists for the invited address',
  (select count(*) from auth.users where email='owner@bright.example'), 1);
select expect_num('with a profile',
  (select count(*) from profiles where email='owner@bright.example'), 1);
select expect_text('the email counts as verified — the token proved the inbox',
  (select (email_confirmed_at is not null)::text from auth.users where email='owner@bright.example'), 'true');
select expect_num('the password is hashed, not stored',
  (select count(*) from auth.users where email='owner@bright.example'
     and encrypted_password = 'a-good-password'), 0);
select expect_text('and it verifies',
  (select (encrypted_password = extensions.crypt('a-good-password', encrypted_password))::text
     from auth.users where email='owner@bright.example'), 'true');

-- Now that it is active, the member surface opens.
select expect_num('studio_by_slug now returns it',
  (select count(*) from studio_by_slug('bright-test')), 1);

-- =============================================================================
-- 6. Single use, expiry, and no second owner
-- =============================================================================

set role anon;
select expect_text('the same token cannot be used twice',
  (select failure_reason from accept_studio_invite(
     current_setting('test.token'), 'another-password', 'Imposter')),
  'token_already_used');
reset role;
select expect_num('and no second account was created',
  (select count(*) from auth.users where email='owner@bright.example'), 1);
set role anon;
select expect_text('a used token previews as used',
  (select state from studio_invite_preview(current_setting('test.token'))), 'used');

-- A second, still-valid invite for a studio that already has an Owner.
-- Planted directly: invites are created by provision_studio(), which refuses a
-- studio that already exists, so a second one has to be written as a fixture.
-- The operator holds SELECT on studio_invites and nothing more, by design.
reset role;
select set_config('test.token2', encode(extensions.gen_random_bytes(32),'hex'), false);
insert into studio_invites (studio_id, email, token_hash, expires_at, created_by)
select s.id, 'second@bright.example',
       encode(extensions.digest(current_setting('test.token2'),'sha256'),'hex'),
       now() + interval '7 days', '88888888-0000-0000-0000-0000000000a1'
  from studios s where s.slug='bright-test';

reset role; set role anon;
select expect_text('an invite for a studio that already has an Owner is refused',
  (select failure_reason from accept_studio_invite(
     current_setting('test.token2'), 'a-good-password', 'Second Owner')),
  'studio_already_has_owner');
reset role;
select expect_num('still exactly one owner',
  (select count(*) from studio_staff ss join studios s on s.id=ss.studio_id
    where s.slug='bright-test' and ss.role='owner' and ss.status='active'), 1);

-- Expiry, on a fresh studio so the owner check cannot mask it.
set role authenticated;
select login('88888888-0000-0000-0000-0000000000a1');
select set_config('test.token3',
  (select invite_token from provision_studio(
     'Stale Studio','stale-test','Europe/London','GBP','GB','owner@stale.example')), false);
reset role;
update studio_invites set expires_at = now() - interval '1 minute'
 where studio_id = (select id from studios where slug='stale-test');

reset role; set role anon;
select expect_text('an expired token previews as expired',
  (select state from studio_invite_preview(current_setting('test.token3'))), 'expired');
select expect_text('and cannot be accepted',
  (select failure_reason from accept_studio_invite(
     current_setting('test.token3'), 'a-good-password', 'Too Late')),
  'token_expired');
reset role;
select expect_text('that studio is still provisioning',
  (select status from studios where slug='stale-test'), 'provisioning');
select expect_num('and has no owner',
  (select count(*) from studio_staff ss join studios s on s.id=ss.studio_id
    where s.slug='stale-test' and ss.role='owner'), 0);

-- =============================================================================
-- 7. The checklist derives from live data, so it cannot go stale
-- =============================================================================

reset role;
select set_config('test.owner_uid',
  (select id::text from auth.users where email='owner@bright.example'), false);
set role authenticated;
select login(current_setting('test.owner_uid'));

select expect_text('a fresh studio has nothing done',
  (select (studio_setup_state((select id from studios where slug='bright-test')) -> 'rooms' ->> 'done')), 'false');
select expect_text('nor any class types',
  (select (studio_setup_state((select id from studios where slug='bright-test')) -> 'class_types' ->> 'done')), 'false');
select expect_text('staff is not done with only the owner on it',
  (select (studio_setup_state((select id from studios where slug='bright-test')) -> 'staff' ->> 'done')), 'false');

reset role;
insert into rooms (studio_id, location_id, name, capacity)
select s.id, l.id, 'Studio One', 10 from studios s join locations l on l.studio_id=s.id
 where s.slug='bright-test';
set role authenticated;
select login(current_setting('test.owner_uid'));
select expect_text('adding a room ticks rooms off, with nothing written to setup_progress',
  (select (studio_setup_state((select id from studios where slug='bright-test')) -> 'rooms' ->> 'done')), 'true');

reset role;
delete from rooms where studio_id = (select id from studios where slug='bright-test');
set role authenticated;
select login(current_setting('test.owner_uid'));
select expect_text('and deleting it unticks — a stored flag would have lied here',
  (select (studio_setup_state((select id from studios where slug='bright-test')) -> 'rooms' ->> 'done')), 'false');

-- Dismissal is the part that genuinely needs storing.
select expect_text('an item starts undismissed',
  (select (studio_setup_state((select id from studios where slug='bright-test')) -> 'connect_stripe' ->> 'dismissed')), 'false');
select expect_text('the owner can dismiss it',
  (select dismiss_setup_item((select id from studios where slug='bright-test'), 'connect_stripe')::text), 'true');
select expect_text('and it stays dismissed',
  (select (studio_setup_state((select id from studios where slug='bright-test')) -> 'connect_stripe' ->> 'dismissed')), 'true');
select expect_text('the Stripe stub can be marked done',
  (select mark_stripe_stub_done((select id from studios where slug='bright-test'))::text), 'true');
select expect_text('and reads as done',
  (select (studio_setup_state((select id from studios where slug='bright-test')) -> 'connect_stripe' ->> 'done')), 'true');

-- Front desk has no business dismissing setup items.
reset role;
insert into auth.users (id) values ('88888888-0000-0000-0000-0000000000a3');
insert into profiles (id, email) values ('88888888-0000-0000-0000-0000000000a3','deskB@example.com');
insert into studio_staff (studio_id, user_id, email, role)
select id, '88888888-0000-0000-0000-0000000000a3', 'deskB@example.com', 'front_desk'
  from studios where slug='bright-test';
set role authenticated;
select login('88888888-0000-0000-0000-0000000000a3');
select expect_text('front desk cannot dismiss a checklist item',
  (select dismiss_setup_item((select id from studios where slug='bright-test'), 'plans')::text), 'false');

-- =============================================================================
-- 7b. The timezone guard holds for writers that never touch provision_studio
--
-- The wizard updates studios directly through RLS, and an import would not go
-- near either path. The trigger is what makes the rule true for all of them.
-- =============================================================================

reset role;
do $$
begin
  update studios set timezone = 'Europe/Pragu' where slug = 'bright-test';
  raise exception 'FAIL  a direct update stored a bogus timezone';
exception
  when sqlstate 'PT422' then
    raise notice 'PASS  a direct update with a bogus timezone is refused';
end $$;

select expect_text('and the studio kept its real zone',
  (select timezone from studios where slug='bright-test'), 'Europe/London');

do $$
begin
  update studios set timezone = 'America/New_York' where slug = 'bright-test';
  raise notice 'PASS  a real zone is still accepted';
exception when others then
  raise exception 'FAIL  a valid timezone was refused: %', sqlerrm;
end $$;
update studios set timezone = 'Europe/London' where slug='bright-test';

-- =============================================================================
-- 8. The state that caused the sign-in loop
--
-- A platform admin is staff of no studio — that is the whole point of the role.
-- getStaffContext() returned null for them, callers read null as "not signed
-- in", and app.studiior.com bounced them to /login forever.
--
-- SQL can only pin the data condition; which screen each case lands on is
-- verified in the browser. But the condition is the part that a seed with a
-- studio_staff row for every user will never produce.
-- =============================================================================

reset role;
select expect_num('a platform admin is staff of no studio, anywhere',
  (select count(*) from studio_staff
    where user_id = '88888888-0000-0000-0000-0000000000a1'), 0);
select expect_text('and is still a platform admin',
  (select exists (select 1 from platform_admins
                   where user_id = '88888888-0000-0000-0000-0000000000a1')::text), 'true');

-- The third case: signed in, no staff row, not an admin either. Nothing in the
-- seed looks like this, which is exactly why the loop reached production.
insert into auth.users (id) values ('88888888-0000-0000-0000-0000000000a9');
insert into profiles (id, email) values ('88888888-0000-0000-0000-0000000000a9','stranded@example.com');
select expect_num('a stranded user has no staff row',
  (select count(*) from studio_staff where user_id = '88888888-0000-0000-0000-0000000000a9'), 0);
select expect_text('and is not a platform admin',
  (select exists (select 1 from platform_admins
                   where user_id = '88888888-0000-0000-0000-0000000000a9')::text), 'false');

-- These three are distinguishable in SQL, so they are distinguishable in the
-- app: anonymous, no-studio-but-admin, no-studio-and-not-admin.
select expect_num('the three cases are distinct users',
  (select count(distinct u) from (values
     ('88888888-0000-0000-0000-0000000000a1'),   -- admin, no studio
     ('88888888-0000-0000-0000-0000000000a2'),   -- staff of a studio
     ('88888888-0000-0000-0000-0000000000a9')    -- neither
   ) v(u)), 3);

reset role;
select 'ALL ONBOARDING TESTS PASSED' as result;
