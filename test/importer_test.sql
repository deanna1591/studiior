-- =============================================================================
-- STUDIIOR — MEMBER IMPORTER (migrations 016 and 019)
--
-- The guarantees a design partner's migration depends on:
--   a dry run changes nothing, commit is atomic, rollback restores exactly,
--   duplicate emails are refused, imported attendance produces correct
--   lifetime_visits and last_visit_at, and none of it fires notifications,
--   challenge progress or achievements.
--
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -f test/importer_test.sql
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

-- --- Fixtures --------------------------------------------------------------

insert into auth.users (id) values
  ('55555555-0000-0000-0000-0000000000a1'),
  ('55555555-0000-0000-0000-0000000000a2'),
  ('55555555-0000-0000-0000-0000000000a3');
insert into profiles (id, email) values
  ('55555555-0000-0000-0000-0000000000a1','mgr@example.com'),
  ('55555555-0000-0000-0000-0000000000a2','desk@example.com'),
  ('55555555-0000-0000-0000-0000000000a3','stranger@example.com');

insert into studios (id, name, slug, timezone, currency, status) values
  ('55555555-0000-0000-0000-000000000001','Importer Studio','importer-test','Europe/Prague','CZK','active');
insert into studio_settings (studio_id) values ('55555555-0000-0000-0000-000000000001');
insert into locations (id, studio_id, name) values
  ('55555555-0000-0000-0000-00000000000c','55555555-0000-0000-0000-000000000001','Main');
insert into studio_staff (studio_id, user_id, email, role) values
  ('55555555-0000-0000-0000-000000000001','55555555-0000-0000-0000-0000000000a1','mgr@example.com','manager'),
  ('55555555-0000-0000-0000-000000000001','55555555-0000-0000-0000-0000000000a2','desk@example.com','front_desk');

-- A second studio, so there is a caller who is signed in, is an owner
-- somewhere, and has no staff row in the studio being imported into. That is
-- the caller the §5 checks below never had, and the one migration 020 exists
-- for: auth_role_in() gave them NULL rather than a role, so "if not
-- is_manager_up(...)" skipped its own raise and let them through.
insert into studios (id, name, slug, timezone, currency, status) values
  ('55555555-0000-0000-0000-000000000002','Other Studio','importer-test-other','Europe/Prague','CZK','active');
insert into studio_settings (studio_id) values ('55555555-0000-0000-0000-000000000002');
insert into studio_staff (studio_id, user_id, email, role) values
  ('55555555-0000-0000-0000-000000000002','55555555-0000-0000-0000-0000000000a3','stranger@example.com','owner');

insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, validity_days) values
  ('55555555-0000-0000-0000-0000000000b1','55555555-0000-0000-0000-000000000001',
   '10-Class Pack','class_pack',500000,'CZK',10,180);

-- An existing member, so "already a member" is a real case and not hypothetical.
insert into members (id, studio_id, first_name, last_name, email, joined_on) values
  ('55555555-0000-0000-0000-0000000000d9','55555555-0000-0000-0000-000000000001',
   'Existing','Member','existing@example.com', current_date - 400);

-- =============================================================================
-- 1. Members: a dry run judges every row and changes nothing else
-- =============================================================================

insert into imports (id, studio_id, type, filename, status, created_by) values
  ('55555555-0000-0000-0000-00000000f001','55555555-0000-0000-0000-000000000001',
   'members','members.csv','uploaded','55555555-0000-0000-0000-0000000000a1');

-- What a real export looks like: a good row, a duplicate of someone already
-- here, the same address twice within the file, a blank email, and a malformed
-- one.
insert into import_rows (import_id, row_number, raw, normalized) values
  ('55555555-0000-0000-0000-00000000f001',1,'{}','{"email":"ana@example.com","first_name":"Ana","last_name":"Novak","joined_on":"2024-03-01","status":"Active"}'),
  ('55555555-0000-0000-0000-00000000f001',2,'{}','{"email":"bo@example.com","first_name":"Bo","last_name":"Svoboda","joined_on":"2024-06-15","status":"Cancelled"}'),
  ('55555555-0000-0000-0000-00000000f001',3,'{}','{"email":"existing@example.com","first_name":"Existing","last_name":"Member"}'),
  ('55555555-0000-0000-0000-00000000f001',4,'{}','{"email":"dup@example.com","first_name":"Dup","last_name":"One"}'),
  ('55555555-0000-0000-0000-00000000f001',5,'{}','{"email":"dup@example.com","first_name":"Dup","last_name":"Two"}'),
  ('55555555-0000-0000-0000-00000000f001',6,'{}','{"email":"","first_name":"No","last_name":"Email"}'),
  ('55555555-0000-0000-0000-00000000f001',7,'{}','{"email":"not-an-address","first_name":"Bad","last_name":"Email"}'),
  -- A word the enum has never heard of. This has to be caught here, at review,
  -- and not by the cast inside the commit transaction — the whole promise of a
  -- dry run is that what it passed will go in.
  ('55555555-0000-0000-0000-00000000f001',8,'{}','{"email":"vip@example.com","first_name":"Vip","last_name":"Person","status":"Gold Tier"}');

select set_config('i.members_before',
  (select count(*)::text from members where studio_id='55555555-0000-0000-0000-000000000001'), false);

set role authenticated;
select set_config('request.jwt.claim.sub','55555555-0000-0000-0000-0000000000a1',false);
select expect_num('dry run finds 2 rows it can create',
  ((import_dry_run('55555555-0000-0000-0000-00000000f001')) ->> 'ok')::bigint, 2);
reset role;

select expect_num('and it changed no members at all',
  (select count(*) from members where studio_id='55555555-0000-0000-0000-000000000001'),
  current_setting('i.members_before')::bigint);
select expect_num('nothing was committed',
  (select count(*) from import_rows
    where import_id='55555555-0000-0000-0000-00000000f001' and entity_id is not null), 0);
select expect_text('the import is marked as dry run only',
  (select status::text from imports where id='55555555-0000-0000-0000-00000000f001'),
  'dry_run_complete');

-- Every refusal says which row and why, in the owner's words.
select expect_text('an existing member skips rather than errors',
  (select status from import_rows where import_id='55555555-0000-0000-0000-00000000f001' and row_number=3),
  'skip');
select expect_text('and says so',
  (select error from import_rows where import_id='55555555-0000-0000-0000-00000000f001' and row_number=3),
  'existing@example.com is already a member');
select expect_num('both halves of an in-file duplicate are refused, not one picked',
  (select count(*) from import_rows
    where import_id='55555555-0000-0000-0000-00000000f001'
      and row_number in (4,5) and status='error'), 2);
select expect_text('a blank email is refused by name',
  (select error from import_rows where import_id='55555555-0000-0000-0000-00000000f001' and row_number=6),
  'No email address in this row');
select expect_text('a malformed one quotes what it read',
  (select error from import_rows where import_id='55555555-0000-0000-0000-00000000f001' and row_number=7),
  'not-an-address is not an email address');
select expect_text('an unrecognised status is refused at the dry run, not at commit',
  (select status from import_rows where import_id='55555555-0000-0000-0000-00000000f001' and row_number=8),
  'error');
select expect_text('and it quotes the word and lists what would work',
  (select error from import_rows where import_id='55555555-0000-0000-0000-00000000f001' and row_number=8),
  '"Gold Tier" is not a member status — use active, inactive, archived or lead, or leave the column unmapped');

-- =============================================================================
-- 2. Commit creates exactly the rows the dry run promised
-- =============================================================================

set role authenticated;
select set_config('request.jwt.claim.sub','55555555-0000-0000-0000-0000000000a1',false);
select expect_num('commit creates 2', ((import_commit('55555555-0000-0000-0000-00000000f001')) ->> 'created')::bigint, 2);
reset role;

select expect_num('the studio has 2 more members',
  (select count(*) from members where studio_id='55555555-0000-0000-0000-000000000001'),
  current_setting('i.members_before')::bigint + 2);
select expect_num('every committed row recorded what it made',
  (select count(*) from import_rows
    where import_id='55555555-0000-0000-0000-00000000f001'
      and status='committed' and entity_table='members' and entity_id is not null), 2);
select expect_num('the skipped and errored rows created nothing',
  (select count(*) from import_rows
    where import_id='55555555-0000-0000-0000-00000000f001'
      and status in ('skip','error') and entity_id is not null), 0);

-- "Active" and "Cancelled" are what the file said; the enum has never seen
-- either spelling. Both halves — dry run and commit — go through one resolver,
-- so what review accepted is what the row ends up as.
select expect_text('a capitalised "Active" lands as active',
  (select status::text from members where email='ana@example.com'), 'active');
select expect_text('"Cancelled" lands as inactive, not silently as active',
  (select status::text from members where email='bo@example.com'), 'inactive');

-- The unique index is the real guard, not the dry run's opinion of it.
do $$
begin
  insert into members (studio_id, first_name, last_name, email)
  values ('55555555-0000-0000-0000-000000000001','Ana','Again','ANA@example.com');
  raise exception 'FAIL  a duplicate email was accepted';
exception when unique_violation then
  raise notice 'PASS  members_email refuses a duplicate regardless of case';
end $$;

-- A committed import cannot be committed twice.
set role authenticated;
select set_config('request.jwt.claim.sub','55555555-0000-0000-0000-0000000000a1',false);
do $$
begin
  perform import_commit('55555555-0000-0000-0000-00000000f001');
  raise exception 'FAIL  a completed import was committed again';
exception when sqlstate 'PT409' then
  raise notice 'PASS  a completed import cannot be committed twice';
end $$;
reset role;

-- =============================================================================
-- 3. Attendance: the numbers it exists to produce
-- =============================================================================

insert into imports (id, studio_id, type, filename, status, created_by) values
  ('55555555-0000-0000-0000-00000000f003','55555555-0000-0000-0000-000000000001',
   'attendance','attendance.csv','uploaded','55555555-0000-0000-0000-0000000000a1');

insert into import_rows (import_id, row_number, raw, normalized)
select '55555555-0000-0000-0000-00000000f003', g,
       '{}'::jsonb,
       jsonb_build_object('email','ana@example.com',
                          'attended_at', (now() - make_interval(days => g * 7))::text)
  from generate_series(1, 8) g;
insert into import_rows (import_id, row_number, raw, normalized) values
  ('55555555-0000-0000-0000-00000000f003', 9, '{}', '{"email":"nobody@example.com","attended_at":"2025-01-01"}'),
  ('55555555-0000-0000-0000-00000000f003',10, '{}',
   jsonb_build_object('email','ana@example.com','attended_at',(now() + interval '3 days')::text));

set role authenticated;
select set_config('request.jwt.claim.sub','55555555-0000-0000-0000-0000000000a1',false);
select expect_num('8 attendance rows are creatable',
  ((import_dry_run('55555555-0000-0000-0000-00000000f003')) ->> 'ok')::bigint, 8);
select expect_num('2 are refused', ((import_dry_run('55555555-0000-0000-0000-00000000f003')) ->> 'error')::bigint, 2);
reset role;

select expect_text('an unknown member is refused by name, pointing at the fix',
  (select error from import_rows where import_id='55555555-0000-0000-0000-00000000f003' and row_number=9),
  'No member with the email nobody@example.com — import members first');
select expect_text('a future visit is refused',
  (select error from import_rows where import_id='55555555-0000-0000-0000-00000000f003' and row_number=10),
  'That visit is in the future');

set role authenticated;
select set_config('request.jwt.claim.sub','55555555-0000-0000-0000-0000000000a1',false);
select expect_num('commit writes 8 visits',
  ((import_commit('55555555-0000-0000-0000-00000000f003')) ->> 'created')::bigint, 8);
reset role;

select expect_num('lifetime_visits is right',
  (select lifetime_visits from members where email='ana@example.com'), 8);
select expect_num('last_visit_at is the most recent imported visit, to the day',
  (select (date_trunc('day', last_visit_at) = date_trunc('day', now() - interval '7 days'))::int
     from members where email='ana@example.com'), 1);
select expect_num('first_visit_at is the oldest',
  (select (date_trunc('day', first_visit_at) = date_trunc('day', now() - interval '56 days'))::int
     from members where email='ana@example.com'), 1);
select expect_num('the visits carry no occurrence and no booking — the class is unknown',
  (select count(*) from check_ins
    where import_id='55555555-0000-0000-0000-00000000f003'
      and (occurrence_id is not null or booking_id is not null)), 0);
select expect_num('and every one is marked with the import that made it',
  (select count(*) from check_ins where import_id='55555555-0000-0000-0000-00000000f003'), 8);

-- Weekly visits for eight weeks is a streak by Decision 5.
select expect_num('the streak computes from imported history',
  (select (current_streak > 0)::int from members where email='ana@example.com'), 1);

-- And the health score reads it, which is the reason attendance is not optional.
select expect_text('a member with imported history is not flagged at risk on day one',
  (select health_band from members where email='ana@example.com'), 'healthy');

-- =============================================================================
-- 4. Historical attendance is a record, not activity
-- =============================================================================

select expect_num('no notifications',
  (select count(*) from notifications where studio_id='55555555-0000-0000-0000-000000000001'), 0);
select expect_num('no challenge progress',
  (select count(*) from challenge_progress_events where studio_id='55555555-0000-0000-0000-000000000001'), 0);
select expect_num('no achievements',
  (select count(*) from member_achievements where studio_id='55555555-0000-0000-0000-000000000001'), 0);
select expect_num('no timeline events',
  (select count(*) from timeline_events where studio_id='55555555-0000-0000-0000-000000000001'), 0);

-- The §8 window would have refused every one of these on the normal path.
do $$
declare s uuid := '55555555-0000-0000-0000-000000000001'; m uuid;
begin
  select id into m from members where email='ana@example.com';
  insert into check_ins (studio_id, booking_id, member_id, occurrence_id, checked_in_at, method)
  values (s, null, m, null, now() - interval '400 days', 'staff');
  raise exception 'FAIL  a check-in with no booking and no import was accepted';
exception when check_violation then
  raise notice 'PASS  a visit with neither a booking nor an import is refused';
end $$;

-- =============================================================================
-- 5. Rollback restores exactly
-- =============================================================================

set role authenticated;
select set_config('request.jwt.claim.sub','55555555-0000-0000-0000-0000000000a1',false);
select expect_num('rolling back the attendance removes all 8',
  ((import_rollback('55555555-0000-0000-0000-00000000f003')) ->> 'removed')::bigint, 8);
reset role;

select expect_num('no imported visits remain',
  (select count(*) from check_ins where import_id='55555555-0000-0000-0000-00000000f003'), 0);
select expect_num('lifetime_visits went back to zero',
  (select lifetime_visits from members where email='ana@example.com'), 0);
select expect_text('and so did last_visit_at',
  (select last_visit_at::text from members where email='ana@example.com'), null);
select expect_text('the import is marked rolled back',
  (select status::text from imports where id='55555555-0000-0000-0000-00000000f003'), 'rolled_back');

-- Rolling back the members import must not silently take a later import with it.
insert into imports (id, studio_id, type, filename, status, created_by, created_at) values
  ('55555555-0000-0000-0000-00000000f004','55555555-0000-0000-0000-000000000001',
   'memberships','m.csv','uploaded','55555555-0000-0000-0000-0000000000a1', now() + interval '1 minute');
insert into import_rows (import_id, row_number, raw, normalized) values
  ('55555555-0000-0000-0000-00000000f004',1,'{}','{"email":"ana@example.com","plan":"10-Class Pack"}');

set role authenticated;
select set_config('request.jwt.claim.sub','55555555-0000-0000-0000-0000000000a1',false);
select expect_num('the membership row is creatable',
  ((import_dry_run('55555555-0000-0000-0000-00000000f004')) ->> 'ok')::bigint, 1);
select expect_num('and commits', ((import_commit('55555555-0000-0000-0000-00000000f004')) ->> 'created')::bigint, 1);

do $$
begin
  perform import_rollback('55555555-0000-0000-0000-00000000f001');
  raise exception 'FAIL  rolling back members silently deleted a later import''s rows';
exception when sqlstate 'PT409' then
  raise notice 'PASS  rolling back members is refused while a later import depends on them';
end $$;

select expect_num('rolling the later one back first is allowed',
  ((import_rollback('55555555-0000-0000-0000-00000000f004')) ->> 'removed')::bigint, 1);
select expect_num('and then the members import rolls back too',
  ((import_rollback('55555555-0000-0000-0000-00000000f001')) ->> 'removed')::bigint, 2);
reset role;

select expect_num('the imported members are gone',
  (select count(*) from members where studio_id='55555555-0000-0000-0000-000000000001'),
  current_setting('i.members_before')::bigint);
select expect_num('and the member who was already there is untouched',
  (select count(*) from members where email='existing@example.com'), 1);

-- =============================================================================
-- 6. Owners and Managers only — Permissions §5
-- =============================================================================

insert into imports (id, studio_id, type, filename, status, created_by) values
  ('55555555-0000-0000-0000-00000000f005','55555555-0000-0000-0000-000000000001',
   'members','x.csv','uploaded','55555555-0000-0000-0000-0000000000a1');

set role authenticated;
select set_config('request.jwt.claim.sub','55555555-0000-0000-0000-0000000000a2',false);  -- front desk
do $$
begin
  perform import_dry_run('55555555-0000-0000-0000-00000000f005');
  raise exception 'FAIL  front desk ran a dry run';
exception when sqlstate 'PT403' then
  raise notice 'PASS  front desk cannot run an import';
end $$;
do $$
begin
  perform import_commit('55555555-0000-0000-0000-00000000f005');
  raise exception 'FAIL  front desk committed an import';
exception when sqlstate 'PT403' then
  raise notice 'PASS  front desk cannot commit an import';
end $$;
reset role;

-- =============================================================================
-- 7. A stranger to this studio — migration 020
--
-- The §5 checks above use a front desk OF THIS STUDIO, whose auth_role_in() is
-- 'front_desk'. Not null, so the guards worked and the assertions passed. The
-- caller who got through was the one with no staff row here at all. These
-- functions are SECURITY DEFINER, so nothing else was standing behind them.
-- =============================================================================

set role authenticated;
select set_config('request.jwt.claim.sub','55555555-0000-0000-0000-0000000000a3',false);

select expect_text('a stranger to the studio has no role in it',
  coalesce(auth_role_in('55555555-0000-0000-0000-000000000001')::text, '<null>'), '<null>');
select expect_text('but is_manager_up says false, not null',
  coalesce(is_manager_up('55555555-0000-0000-0000-000000000001')::text, '<null>'), 'false');
select expect_text('and so does is_desk_up',
  coalesce(is_desk_up('55555555-0000-0000-0000-000000000001')::text, '<null>'), 'false');

do $$
begin
  perform import_dry_run('55555555-0000-0000-0000-00000000f005');
  raise exception 'FAIL  a stranger ran a dry run on another studio''s import';
exception when sqlstate 'PT403' then
  raise notice 'PASS  a stranger cannot dry run another studio''s import';
end $$;
do $$
begin
  perform import_commit('55555555-0000-0000-0000-00000000f005');
  raise exception 'FAIL  a stranger committed another studio''s import';
exception when sqlstate 'PT403' then
  raise notice 'PASS  a stranger cannot commit another studio''s import';
end $$;
do $$
begin
  perform import_rollback('55555555-0000-0000-0000-00000000f001');
  raise exception 'FAIL  a stranger rolled back another studio''s import';
exception when sqlstate 'PT403' then
  raise notice 'PASS  a stranger cannot roll back another studio''s import';
end $$;
select expect_num('recompute_member_stats updates nothing for a stranger',
  recompute_member_stats('55555555-0000-0000-0000-000000000001',
                         array['55555555-0000-0000-0000-0000000000d9']::uuid[]), 0);
reset role;

-- Asserted with the role reset, because a stranger cannot see the row either:
-- run as them, the subquery returns null and the assertion passes for the
-- wrong reason.
select expect_num('and the member''s visit count is untouched',
  (select lifetime_visits from members where id='55555555-0000-0000-0000-0000000000d9'), 0);

select 'ALL IMPORTER TESTS PASSED' as result;
