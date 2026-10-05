-- =============================================================================
-- Decision 64 — removing and re-issuing an instructor's app login.
-- UUID space: 6409
--
-- remove_instructor_login detaches the login (staff_id null, staff row removed,
-- pending invite withdrawn, audit) and leaves classes/availability/pay/history
-- untouched; every instructor-facing guard then refuses the old user; re-invite
-- with a new email works and the new user passes the guards. The is_this_instructor
-- status fix is RED-proven on a removed-but-still-linked staff row.
-- =============================================================================
\set A '''64096409-0000-0000-0000-000000000001'''
\set B '''64096409-0000-0000-0000-000000000002'''

create or replace function expect_true(label text, actual boolean) returns void language plpgsql as $$
begin if coalesce(actual,false) then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_false(label text, actual boolean) returns void language plpgsql as $$
begin if actual is not null and not actual then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected false, got %', label, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_num(label text, actual bigint, want bigint) returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (%)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_text(label text, actual text, want text) returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (%)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if; end $$;
create or replace function expect_raises(label text, sql text, code text) returns void language plpgsql as $$
begin execute sql; raise exception 'FAIL  %  expected %, nothing raised', label, code;
exception when others then
  if sqlstate = code then raise notice 'PASS  %  (%)', label, code;
  else raise exception 'FAIL  %  expected %, got % (%)', label, code, sqlstate, sqlerrm; end if; end $$;
create or replace function expect_noraise(label text, sql text) returns void language plpgsql as $$
begin execute sql; raise notice 'PASS  %  (no raise)', label;
exception when others then raise exception 'FAIL  %  expected no raise, got % (%)', label, sqlstate, sqlerrm; end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('64096409-0000-0000-0000-0000000000a1'),  -- owner A
  ('64096409-0000-0000-0000-0000000000f1'),  -- front desk A
  ('64096409-0000-0000-0000-0000000000b1'),  -- owner B
  ('64096409-0000-0000-0000-0000000000c1'),  -- I1's login (to be removed)
  ('64096409-0000-0000-0000-0000000000c2'),  -- I2's login
  ('64096409-0000-0000-0000-0000000000ce'),  -- IX's login (removed-but-linked, RED proof)
  ('64096409-0000-0000-0000-0000000000e1');  -- I1's NEW login after re-invite
insert into profiles (id, email) values
  ('64096409-0000-0000-0000-0000000000a1','6409-oa@example.com'),
  ('64096409-0000-0000-0000-0000000000f1','6409-fa@example.com'),
  ('64096409-0000-0000-0000-0000000000b1','6409-ob@example.com'),
  ('64096409-0000-0000-0000-0000000000c1','6409-u1@example.com'),
  ('64096409-0000-0000-0000-0000000000c2','6409-u2@example.com'),
  ('64096409-0000-0000-0000-0000000000ce','6409-ux@example.com'),
  ('64096409-0000-0000-0000-0000000000e1','6409-n1@example.com');

insert into studios (id, name, slug, timezone, currency, status) values
  (:A,'Login A','login-a','Europe/Prague','CZK','active'),
  (:B,'Login B','login-b','Europe/Prague','CZK','active');
insert into studio_settings (studio_id) values (:A), (:B);
insert into locations (id, studio_id, name, is_primary) values
  ('64096409-0000-0000-0000-00000000000a',:A,'Main',true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('64096409-0000-0000-0000-0000000ee0a1',:A,'64096409-0000-0000-0000-00000000000a','R',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('64096409-0000-0000-0000-0000000cc0a1',:A,'Reformer',50,10);

-- Staff rows: owner/front-desk/owner-B, plus three instructor logins.
insert into studio_staff (id, studio_id, user_id, email, role, status, joined_at) values
  ('64096409-0000-0000-0000-000000aa00a1',:A,'64096409-0000-0000-0000-0000000000a1','6409-oa@example.com','owner','active', now()),
  ('64096409-0000-0000-0000-000000aa00f1',:A,'64096409-0000-0000-0000-0000000000f1','6409-fa@example.com','front_desk','active', now()),
  ('64096409-0000-0000-0000-000000aa00b1',:B,'64096409-0000-0000-0000-0000000000b1','6409-ob@example.com','owner','active', now()),
  ('64096409-0000-0000-0000-000000aa00c1',:A,'64096409-0000-0000-0000-0000000000c1','6409-i1@example.com','instructor','active', now()),
  ('64096409-0000-0000-0000-000000aa00c2',:A,'64096409-0000-0000-0000-0000000000c2','6409-i2@example.com','instructor','active', now()),
  ('64096409-0000-0000-0000-000000aa00ce',:A,'64096409-0000-0000-0000-0000000000ce','6409-ix@example.com','instructor','active', now());

-- Instructors: I1/I2/IX linked to logins, I3 no login, IO = the OWNER's own
-- instructor record (self-removal test).
insert into instructors (id, studio_id, display_name, staff_id) values
  ('64096409-0000-0000-0000-00000000d001',:A,'Ivy One',  '64096409-0000-0000-0000-000000aa00c1'),
  ('64096409-0000-0000-0000-00000000d002',:A,'Bo Two',   '64096409-0000-0000-0000-000000aa00c2'),
  ('64096409-0000-0000-0000-00000000d0ce',:A,'Xy Linked','64096409-0000-0000-0000-000000aa00ce'),
  ('64096409-0000-0000-0000-00000000d003',:A,'Cy Three',  null),
  ('64096409-0000-0000-0000-00000000d0a0',:A,'Olga Owner','64096409-0000-0000-0000-000000aa00a1');

-- I1 teaches a future class; has availability + a rate; and a PENDING invite.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, booked_count, starts_at, ends_at, status) values
  ('64096409-0000-0000-0000-00000000c001',:A,'64096409-0000-0000-0000-00000000000a','64096409-0000-0000-0000-0000000cc0a1','64096409-0000-0000-0000-0000000ee0a1','64096409-0000-0000-0000-00000000d001','Reformer',10,0, now()+interval '8 days', now()+interval '8 days'+interval '50 min','scheduled');
insert into instructor_availability (id, studio_id, instructor_id, day_of_week, starts_at_time, ends_at_time, approval_status) values
  ('64096409-0000-0000-0000-00000000a001',:A,'64096409-0000-0000-0000-00000000d001',1,'09:00','17:00','approved');
insert into instructor_rate_versions (studio_id, instructor_id, effective_from, currency, base_rate_cents, per_head_rate_cents, per_head_threshold, full_house_bonus_cents) values
  (:A,'64096409-0000-0000-0000-00000000d001', current_date, 'CZK', 90000, 0, 0, 0);
insert into studio_invites (studio_id, email, token_hash, expires_at, created_by, role, instructor_id) values
  (:A,'6409-i1@example.com', encode(digest('tok6409','sha256'),'hex'), now()+interval '14 days',
   '64096409-0000-0000-0000-0000000000a1','instructor','64096409-0000-0000-0000-00000000d001');

-- Baselines (untouched proof).
select set_config('t.cls', (select count(*) from class_occurrences where instructor_id='64096409-0000-0000-0000-00000000d001')::text, false);
select set_config('t.avl', (select count(*) from instructor_availability where instructor_id='64096409-0000-0000-0000-00000000d001')::text, false);
select set_config('t.rate',(select count(*) from instructor_rate_versions where instructor_id='64096409-0000-0000-0000-00000000d001')::text, false);

-- =============================================================================
-- (1) Guard refusals on the write itself.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','64096409-0000-0000-0000-0000000000f1',false);
select expect_raises('front desk cannot remove a login → PT403',
  $$ select remove_instructor_login('64096409-0000-0000-0000-00000000d001') $$, 'PT403');
select set_config('request.jwt.claim.sub','',false); reset role;

set role authenticated; select set_config('request.jwt.claim.sub','64096409-0000-0000-0000-0000000000b1',false);
select expect_raises('cross-studio owner cannot remove → PT403',
  $$ select remove_instructor_login('64096409-0000-0000-0000-00000000d001') $$, 'PT403');
select set_config('request.jwt.claim.sub','',false); reset role;

set role authenticated; select set_config('request.jwt.claim.sub','64096409-0000-0000-0000-0000000000a1',false);
select expect_raises('an instructor with no login → PT409',
  $$ select remove_instructor_login('64096409-0000-0000-0000-00000000d003') $$, 'PT409');
select expect_raises('owner cannot remove their OWN login → PT409',
  $$ select remove_instructor_login('64096409-0000-0000-0000-00000000d0a0') $$, 'PT409');
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- (2) The removal itself (owner).
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','64096409-0000-0000-0000-0000000000a1',false);
select expect_true('owner removes I1''s login → ok',
  (remove_instructor_login('64096409-0000-0000-0000-00000000d001')::jsonb ->> 'ok')::boolean);
select set_config('request.jwt.claim.sub','',false); reset role;

select expect_true('...instructors.staff_id is null',
  (select staff_id is null from instructors where id='64096409-0000-0000-0000-00000000d001'));
select expect_text('...the staff row is removed + removed_at set',
  (select status || ':' || (removed_at is not null)::text from studio_staff where id='64096409-0000-0000-0000-000000aa00c1'),
  'removed:true');
select expect_num('...the pending invite was withdrawn',
  (select count(*) from studio_invites where instructor_id='64096409-0000-0000-0000-00000000d001' and accepted_at is null)::bigint, 0);
select expect_num('...an audit row was written',
  (select count(*) from audit_logs where action='instructor.login_removed' and entity_id='64096409-0000-0000-0000-00000000d001')::bigint, 1);

select expect_num('...I1''s classes untouched',
  (select count(*) from class_occurrences where instructor_id='64096409-0000-0000-0000-00000000d001')::bigint, current_setting('t.cls')::bigint);
select expect_num('...I1''s availability untouched',
  (select count(*) from instructor_availability where instructor_id='64096409-0000-0000-0000-00000000d001')::bigint, current_setting('t.avl')::bigint);
select expect_num('...I1''s pay rates untouched',
  (select count(*) from instructor_rate_versions where instructor_id='64096409-0000-0000-0000-00000000d001')::bigint, current_setting('t.rate')::bigint);

-- =============================================================================
-- (3) Every instructor-facing guard now refuses the old user u1.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','64096409-0000-0000-0000-0000000000c1',false);
select expect_true('the removed user has no instructor context (my_instructor null)',
  my_instructor() is null);
select expect_raises('instructor_week refuses the removed user → PT403',
  $$ select instructor_week('64096409-0000-0000-0000-00000000d001', current_date, current_date + 14) $$, 'PT403');
select expect_raises('instructor_open_classes refuses the removed user → PT403',
  $$ select instructor_open_classes('64096409-0000-0000-0000-00000000d001') $$, 'PT403');
select expect_raises('submit_availability refuses the removed user → PT403',
  $$ select submit_availability('64096409-0000-0000-0000-00000000d001', date_trunc('month', current_date + interval '1 month')::date, '[]'::jsonb) $$, 'PT403');
select expect_raises('accept_cover refuses the removed user → PT403',
  $$ select accept_cover('64096409-0000-0000-0000-00000000c001') $$, 'PT403');
select expect_raises('request_cover refuses the removed user → PT403',
  $$ select request_cover('64096409-0000-0000-0000-00000000c001') $$, 'PT403');
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- (4) RED proof: is_this_instructor's status filter is load-bearing.
--     IX's staff row is marked removed but IX.staff_id STILL points at it (a
--     deactivated-but-linked staff row). WITH the fix, IX's user is refused;
--     reverting the status check lets them through.
-- =============================================================================
update studio_staff set status='removed', removed_at=now() where id='64096409-0000-0000-0000-000000aa00ce';
set role authenticated; select set_config('request.jwt.claim.sub','64096409-0000-0000-0000-0000000000ce',false);
select expect_false('is_this_instructor(IX) is false for a removed-but-linked row (the fix)',
  is_this_instructor('64096409-0000-0000-0000-00000000d0ce'));
select expect_raises('instructor_week(IX) refuses the removed-but-linked user → PT403',
  $$ select instructor_week('64096409-0000-0000-0000-00000000d0ce', current_date, current_date + 14) $$, 'PT403');
select set_config('request.jwt.claim.sub','',false); reset role;

create or replace function is_this_instructor(p_instructor_id uuid)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce(exists (
    select 1 from instructors i join studio_staff ss on ss.id = i.staff_id
     where i.id = p_instructor_id and ss.user_id = auth.uid()
  ), false);
$$;
set role authenticated; select set_config('request.jwt.claim.sub','64096409-0000-0000-0000-0000000000ce',false);
select expect_true('RED: without the status filter, is_this_instructor(IX) is TRUE (the hole)',
  is_this_instructor('64096409-0000-0000-0000-00000000d0ce'));
select expect_noraise('RED: without the fix, instructor_week(IX) does NOT refuse',
  $$ select instructor_week('64096409-0000-0000-0000-00000000d0ce', current_date, current_date + 14) $$);
select set_config('request.jwt.claim.sub','',false); reset role;

create or replace function is_this_instructor(p_instructor_id uuid)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce(exists (
    select 1 from instructors i join studio_staff ss on ss.id = i.staff_id
     where i.id = p_instructor_id and ss.user_id = auth.uid() and ss.status = 'active'
  ), false);
$$;
set role authenticated; select set_config('request.jwt.claim.sub','64096409-0000-0000-0000-0000000000ce',false);
select expect_raises('restored: instructor_week(IX) refuses again → PT403',
  $$ select instructor_week('64096409-0000-0000-0000-00000000d0ce', current_date, current_date + 14) $$, 'PT403');
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- (5) Re-invite I1 with a NEW email; the new user passes the guards.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','64096409-0000-0000-0000-0000000000a1',false);
select expect_text('re-invite I1 with a new email → staff row + email',
  (invite_instructor('64096409-0000-0000-0000-00000000d001','6409-i1-new@example.com')::jsonb ->> 'email'),
  '6409-i1-new@example.com');
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_true('...I1 has a login line again (staff_id set, invited)',
  (select ss.status='invited' from instructors i join studio_staff ss on ss.id=i.staff_id
    where i.id='64096409-0000-0000-0000-00000000d001'));
select expect_false('...it is a DIFFERENT staff row than the removed one',
  (select staff_id = '64096409-0000-0000-0000-000000aa00c1' from instructors where id='64096409-0000-0000-0000-00000000d001'));

update studio_staff set user_id='64096409-0000-0000-0000-0000000000e1', status='active', joined_at=now()
 where id = (select staff_id from instructors where id='64096409-0000-0000-0000-00000000d001');
set role authenticated; select set_config('request.jwt.claim.sub','64096409-0000-0000-0000-0000000000e1',false);
select expect_true('...the new user now resolves to I1 (my_instructor)',
  (my_instructor() ->> 'instructor_id') = '64096409-0000-0000-0000-00000000d001');
select expect_noraise('...and passes instructor_week',
  $$ select instructor_week('64096409-0000-0000-0000-00000000d001', current_date, current_date + 14) $$);
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- (6) Same-email re-invite reactivates the removed row (no conflict).
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','64096409-0000-0000-0000-0000000000a1',false);
select remove_instructor_login('64096409-0000-0000-0000-00000000d002');
select expect_text('same-email re-invite reactivates the removed row',
  (invite_instructor('64096409-0000-0000-0000-00000000d002','6409-i2@example.com')::jsonb ->> 'email'),
  '6409-i2@example.com');
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_num('...exactly ONE staff row for that email (reused, not duplicated)',
  (select count(*) from studio_staff where studio_id=:A and lower(email)='6409-i2@example.com')::bigint, 1);
select expect_text('...the reused row is invited again, removed_at cleared',
  (select status || ':' || (removed_at is null)::text from studio_staff where id='64096409-0000-0000-0000-000000aa00c2'),
  'invited:true');

-- --- cleanup -----------------------------------------------------------------
drop function expect_true(text, boolean);
drop function expect_false(text, boolean);
drop function expect_num(text, bigint, bigint);
drop function expect_text(text, text, text);
drop function expect_raises(text, text, text);
drop function expect_noraise(text, text);
select 'instructor_login_test: all assertions passed' as result;
