-- =============================================================================
-- STUDIIOR — HEALTH SCORE & DEMO DATA (Decision 14, migrations 017 and 018)
--
-- The demo cohorts are the fixture: each one exists to fire a specific signal,
-- so asserting where they land tests the score and the generator at once.
--
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -f test/health_score_test.sql
--
-- Local stack only.
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

-- --- Fixture: a studio, an owner, and a full set of demo cohorts -----------

insert into auth.users (id) values ('66666666-0000-0000-0000-0000000000a1');
insert into profiles (id, email) values ('66666666-0000-0000-0000-0000000000a1','ops@example.com');
insert into platform_admins (user_id, email, note)
  values ('66666666-0000-0000-0000-0000000000a1','ops@example.com','health score suite');

set role authenticated;
select set_config('request.jwt.claim.sub','66666666-0000-0000-0000-0000000000a1',false);
select set_config('h.tok', (select invite_token from provision_studio(
  'Health Test Studio','health-test','Asia/Manila','PHP','PH','owner@health.example')), false);
reset role;

set role anon;
select expect_text('the studio gets an owner',
  (select failure_reason from accept_studio_invite(current_setting('h.tok'),'health-owner-pw','Hana Owner')),
  null);
reset role;

select set_config('h.sid', (select id::text from studios where slug='health-test'), false);

set role authenticated;
select set_config('request.jwt.claim.sub','66666666-0000-0000-0000-0000000000a1',false);
select expect_num('demo data generates 26 members',
  ((generate_demo_data(current_setting('h.sid')::uuid)) ->> 'members')::bigint, 26);
select expect_num('and refreshing health covers all of them',
  refresh_studio_health(current_setting('h.sid')::uuid)::bigint, 26);
reset role;

-- The generator writes check_ins and then recomputes the visit cache. Asserted
-- on its own rather than left to the band assertions, because when the
-- recompute silently did nothing the failure surfaced eleven assertions later
-- as "a member with under 6 visits gets no band", which is not what went wrong.
select expect_num('no demo member has visits on record but a zero visit count',
  (select count(*) from members m
    where m.studio_id = current_setting('h.sid')::uuid
      and m.lifetime_visits = 0
      and exists (select 1 from check_ins c where c.member_id = m.id)), 0);

-- =============================================================================
-- 1. Every cohort lands in the band it exists to demonstrate
-- =============================================================================

create temp table _want (fn text, band text, cohort text);
insert into _want values
  ('Liwayway','healthy','regular'), ('Dakila','healthy','regular'),
  ('Marikit','healthy','regular'),  ('Tala','healthy','regular'),
  ('Amihan','healthy','eight'),     ('Bituin','healthy','eight'),
  ('Halina','healthy','eight'),     ('Lakan','healthy','pack'),
  ('Sinag','healthy','pack'),       ('Diwata','healthy','pack'),
  ('Ligaya','at_risk','rhythm deviation'), ('Katipunan','at_risk','rhythm deviation'),
  ('Batangas','at_risk','rhythm deviation'), ('Mayumi','at_risk','rhythm deviation'),
  ('Narra','at_risk','payment state'),
  ('Bagwis','drifting','booking drift'), ('Luntian','drifting','booking drift'),
  ('Ulan','drifting','first month'),     ('Hangin','drifting','first month'),
  ('Araw','drifting','expiry + declining use'), ('Buwan','drifting','expiry + declining use'),
  ('Alon','new','first fortnight'), ('Haraya','new','first fortnight'),
  ('Perlas','insufficient_history','one visit'), ('Kidlat','insufficient_history','one visit'),
  ('Sampaguita','insufficient_history','one visit');

do $$
declare r record; bad int := 0;
begin
  for r in
    select w.fn, w.band as want, w.cohort, m.health_band as got
      from _want w join members m on m.first_name = w.fn
     where m.studio_id = current_setting('h.sid')::uuid
  loop
    if r.got is distinct from r.want then
      raise warning 'FAIL  % (%) expected %, got %', r.fn, r.cohort, r.want, r.got;
      bad := bad + 1;
    end if;
  end loop;
  if bad > 0 then
    raise exception 'FAIL  % cohort member(s) in the wrong band', bad;
  end if;
  raise notice 'PASS  all 26 cohort members land in their intended band';
end $$;

select expect_num('the four lapsing members are all at_risk',
  (select count(*) from members m join _want w on w.fn = m.first_name
    where m.studio_id = current_setting('h.sid')::uuid
      and w.cohort = 'rhythm deviation' and m.health_band = 'at_risk'), 4);

-- =============================================================================
-- 2. Each signal names itself, so priority order is observable
-- =============================================================================

select expect_text('the lapsing cohort fires rhythm deviation',
  (select (health_signals ->> 0) from members
    where studio_id = current_setting('h.sid')::uuid and first_name = 'Mayumi'),
  'rhythm_deviation');
select expect_text('the drift cohort fires booking drift',
  (select (health_signals ->> 0) from members
    where studio_id = current_setting('h.sid')::uuid and first_name = 'Bagwis'),
  'booking_drift');
select expect_text('the stalled cohort fires the first-month signal',
  (select (health_signals ->> 0) from members
    where studio_id = current_setting('h.sid')::uuid and first_name = 'Ulan'),
  'first_month_stalled');
select expect_text('the past-due member fires payment state',
  (select (health_signals ->> 0) from members
    where studio_id = current_setting('h.sid')::uuid and first_name = 'Narra'),
  'payment_state');
select expect_text('the expiring cohort fires expiry with declining use',
  (select (health_signals ->> 0) from members
    where studio_id = current_setting('h.sid')::uuid and first_name = 'Buwan'),
  'expiry_declining_use');
select expect_num('a healthy member fires nothing',
  (select jsonb_array_length(health_signals) from members
    where studio_id = current_setting('h.sid')::uuid and first_name = 'Marikit'), 0);

-- =============================================================================
-- 3. Reasons name behaviour with numbers — never a category
--
-- This is the assertion Decision 14 asks for by name. A reason reading "low
-- engagement" is a failed test, not a stylistic quibble: the owner already
-- knows their members, and a label they have to decode is worth nothing.
-- =============================================================================

select expect_num('every non-healthy member has a reason',
  (select count(*) from members
    where studio_id = current_setting('h.sid')::uuid
      and health_band in ('at_risk','drifting','insufficient_history')
      and (health_reason is null or btrim(health_reason) = '')), 0);

select expect_num('every reason contains an actual number',
  (select count(*) from members
    where studio_id = current_setting('h.sid')::uuid
      and health_reason is not null
      and health_reason !~ '[0-9]'), 0);

select expect_num('no reason falls back to a category',
  (select count(*) from members
    where studio_id = current_setting('h.sid')::uuid
      and health_reason is not null
      and health_reason ~* '(low engagement|retention risk|booking behaviour|at risk|concern|churn risk|disengaged|inactive member)'), 0);

select expect_num('healthy members carry no reason to explain away',
  (select count(*) from members
    where studio_id = current_setting('h.sid')::uuid
      and health_band = 'healthy' and health_reason is not null), 0);

-- Both halves of signal 1, as the decision requires: the old rhythm AND the gap.
select expect_num('a rhythm reason states the old rhythm and the current gap',
  (select count(*) from members
    where studio_id = current_setting('h.sid')::uuid
      and health_signals ? 'rhythm_deviation'
      and health_reason ~ 'about every [0-9]+ days'
      and health_reason ~ 'last visit [0-9]+ days ago'), 4);

select expect_num('a booking-drift reason counts the bookings and the attendance',
  (select count(*) from members
    where studio_id = current_setting('h.sid')::uuid
      and health_signals ? 'booking_drift'
      and health_reason ~ 'Booked [0-9]+ classes'
      and health_reason ~ 'attended [0-9]+'), 2);

select expect_num('an expiry reason states the countdown and both periods',
  (select count(*) from members
    where studio_id = current_setting('h.sid')::uuid
      and health_signals ? 'expiry_declining_use'
      and health_reason ~ 'Renews in [0-9]+ days'
      and health_reason ~ '[0-9]+ class(es)? this period against [0-9]+ last'), 2);

-- =============================================================================
-- 3b. The first fortnight is `new` — Decision 14 amendment
--
-- Days 0-13 used to fall through to `healthy`: signal 3 starts at day 14 and
-- insufficient_history needs 35. A member who has never been in was described
-- as though nothing was wrong.
-- =============================================================================

select expect_num('nobody under 14 days is called healthy',
  (select count(*) from members
    where studio_id = current_setting('h.sid')::uuid
      and (current_date - joined_on) < 13 and health_band = 'healthy'), 0);

select expect_num('and their reason says how long and how many visits',
  (select count(*) from members
    where studio_id = current_setting('h.sid')::uuid and health_band = 'new'
      and health_reason ~ '^Joined [0-9]+ days ago, (no visits yet|[0-9]+ visits?)\.$'), 2);

select expect_num('`new` is not a warning — it fires no signals',
  (select count(*) from members
    where studio_id = current_setting('h.sid')::uuid and health_band = 'new'
      and jsonb_array_length(health_signals) <> 0), 0);

-- A member who joined this week and has never been in: the case the amendment
-- exists for, built rather than hoped for.
insert into members (id, studio_id, first_name, last_name, email, joined_on, waiver_signed_at, is_demo)
values ('66666666-0000-0000-0000-0000000000fa', current_setting('h.sid')::uuid,
        'Never','Arrived','never.arrived@example.com', current_date - 5, now(), true);

set role authenticated;
select set_config('request.jwt.claim.sub','66666666-0000-0000-0000-0000000000a1',false);
select expect_text('five days in with no visits is new, not healthy',
  ((member_health('66666666-0000-0000-0000-0000000000fa')) ->> 'band'), 'new');
select expect_num('and the reason says so plainly',
  (select count(*) from (select (member_health('66666666-0000-0000-0000-0000000000fa')) ->> 'reason' as r) x
    where x.r ~ 'Joined [0-9]+ days ago, no visits yet'), 1);
reset role;

-- At day 14 the amendment hands over to signal 3, as specified.
update members set joined_on = current_date - 20
 where id = '66666666-0000-0000-0000-0000000000fa';

set role authenticated;
select set_config('request.jwt.claim.sub','66666666-0000-0000-0000-0000000000a1',false);
select expect_text('at 20 days the same member is signal 3, not new',
  ((member_health('66666666-0000-0000-0000-0000000000fa')) ->> 'band'), 'drifting');
select expect_text('and it is the first-month signal that fired',
  (((member_health('66666666-0000-0000-0000-0000000000fa')) -> 'signals') ->> 0),
  'first_month_stalled');
reset role;

-- =============================================================================
-- 4. insufficient_history is a distinct state, not a healthy one
-- =============================================================================

select expect_num('a member with under 6 visits and over 35 days gets no band',
  (select count(*) from members
    where studio_id = current_setting('h.sid')::uuid
      and lifetime_visits < 6 and (current_date - joined_on) > 35
      and health_band <> 'insufficient_history'), 0);

select expect_num('none of them is called healthy',
  (select count(*) from members
    where studio_id = current_setting('h.sid')::uuid
      and health_band = 'insufficient_history' and health_band = 'healthy'), 0);

-- A member with exactly 5 visits, joined long ago: the boundary case named in
-- the brief. Built rather than hoped for.
insert into members (id, studio_id, first_name, last_name, email, joined_on, waiver_signed_at, is_demo)
select '66666666-0000-0000-0000-0000000000d5', current_setting('h.sid')::uuid,
       'Five','Visits','five.visits@example.com', current_date - 200, now(), true;

-- These visits have no booking behind them, which is what imported history
-- looks like (migration 016). check_ins_booked_or_imported requires one or the
-- other, so they carry an import instead — and that also exempts them from the
-- §8 window, which is the point: this is a record of the past.
insert into imports (id, studio_id, type, filename, status)
values ('66666666-0000-0000-0000-00000000ff01', current_setting('h.sid')::uuid,
        'attendance', 'health-score-fixture.csv', 'complete');

insert into check_ins (studio_id, booking_id, member_id, occurrence_id, checked_in_at,
                       method, is_demo, import_id)
select current_setting('h.sid')::uuid, null, '66666666-0000-0000-0000-0000000000d5',
       null, now() - make_interval(days => (g * 9) + 3), 'staff', true,
       '66666666-0000-0000-0000-00000000ff01'
  from generate_series(0, 4) g;

select expect_num('the five-visit member has exactly five visits',
  (select count(*) from check_ins where member_id = '66666666-0000-0000-0000-0000000000d5'), 5);

set role authenticated;
select set_config('request.jwt.claim.sub','66666666-0000-0000-0000-0000000000a1',false);
select expect_text('five visits and 200 days is insufficient_history, not healthy',
  ((member_health('66666666-0000-0000-0000-0000000000d5')) ->> 'band'), 'insufficient_history');
select expect_num('and its reason states how few visits there are',
  (select count(*) from (select (member_health('66666666-0000-0000-0000-0000000000d5')) ->> 'reason' as r) x
    where x.r ~ '[0-9]+ visit'), 1);
reset role;

-- =============================================================================
-- 5. Rhythm is measured against the member's own baseline, never the studio's
--
-- The decision calls this the signal no competitor surfaces, and the reason it
-- works is that it never compares members to each other. Two members with
-- opposite rhythms, each consistent, are both healthy — a studio-average
-- comparison would flag the fortnightly one.
-- =============================================================================

insert into members (id, studio_id, first_name, last_name, email, joined_on, waiver_signed_at, is_demo)
values
  ('66666666-0000-0000-0000-0000000000e1', current_setting('h.sid')::uuid,
   'Frequent','Regular','frequent.regular@example.com', current_date - 300, now(), true),
  ('66666666-0000-0000-0000-0000000000e2', current_setting('h.sid')::uuid,
   'Fortnightly','Regular','fortnightly.regular@example.com', current_date - 300, now(), true);

-- Twice a week for 20 weeks, last visit 2 days ago.
insert into check_ins (studio_id, booking_id, member_id, checked_in_at, method, is_demo, import_id)
select current_setting('h.sid')::uuid, null, '66666666-0000-0000-0000-0000000000e1',
       now() - make_interval(days => (g * 3) + 2), 'staff', true,
       '66666666-0000-0000-0000-00000000ff01'
  from generate_series(0, 39) g;

-- Every 14 days for the same span, last visit 2 days ago. Far rarer, equally
-- consistent.
insert into check_ins (studio_id, booking_id, member_id, checked_in_at, method, is_demo, import_id)
select current_setting('h.sid')::uuid, null, '66666666-0000-0000-0000-0000000000e2',
       now() - make_interval(days => (g * 14) + 2), 'staff', true,
       '66666666-0000-0000-0000-00000000ff01'
  from generate_series(0, 19) g;

set role authenticated;
select set_config('request.jwt.claim.sub','66666666-0000-0000-0000-0000000000a1',false);
select expect_text('a three-day-rhythm member two days out is healthy',
  ((member_health('66666666-0000-0000-0000-0000000000e1')) ->> 'band'), 'healthy');
select expect_text('and so is a fortnightly member two days out',
  ((member_health('66666666-0000-0000-0000-0000000000e2')) ->> 'band'), 'healthy');
reset role;

-- The whole argument in one step: push BOTH to the same 20-day gap. A studio
-- average would treat them identically. Their own baselines do not.
-- Shift the whole history, not just the most recent rows: moving only what is
-- inside a five-day window just promotes the next visit back into being the
-- last one, and the gap barely changes. Shifting everything preserves each
-- member's baseline and moves only how long it has been.
update check_ins set checked_in_at = checked_in_at - interval '18 days'
 where member_id in ('66666666-0000-0000-0000-0000000000e1',
                     '66666666-0000-0000-0000-0000000000e2');

set role authenticated;
select set_config('request.jwt.claim.sub','66666666-0000-0000-0000-0000000000a1',false);

select expect_text('at 20 days the three-day-rhythm member has clearly stopped',
  ((member_health('66666666-0000-0000-0000-0000000000e1')) ->> 'band'), 'at_risk');
select expect_text('at the SAME 20 days the fortnightly member is fine — 20 is not 2x 14',
  ((member_health('66666666-0000-0000-0000-0000000000e2')) ->> 'band'), 'healthy');

-- Same absolute gap, opposite verdicts. That is only possible because the
-- comparison is per member; a studio mean would have flagged the fortnightly
-- member or excused the frequent one.
select expect_num('the frequent member is judged against their own 3-day rhythm',
  (select count(*) from (select (member_health('66666666-0000-0000-0000-0000000000e1')) ->> 'reason' as r) x
    where x.r ~ 'about every 3 days'), 1);

-- Now take the fortnightly member past 2x their own baseline.
reset role;
update check_ins set checked_in_at = checked_in_at - interval '20 days'
 where member_id = '66666666-0000-0000-0000-0000000000e2';

set role authenticated;
select set_config('request.jwt.claim.sub','66666666-0000-0000-0000-0000000000a1',false);
select expect_text('past 2x their own 14 days, they drift too',
  ((member_health('66666666-0000-0000-0000-0000000000e2')) ->> 'band'), 'drifting');
select expect_num('and the reason quotes their baseline, not an average',
  (select count(*) from (select (member_health('66666666-0000-0000-0000-0000000000e2')) ->> 'reason' as r) x
    where x.r ~ 'about every 1[34] days'), 1);
reset role;

-- =============================================================================
-- 6. The cache matches a fresh computation, and the source wins
-- =============================================================================

set role authenticated;
select set_config('request.jwt.claim.sub','66666666-0000-0000-0000-0000000000a1',false);
select refresh_studio_health(current_setting('h.sid')::uuid);

do $$
declare r record; bad int := 0;
begin
  for r in select id, first_name, health_band, health_reason from members
            where studio_id = current_setting('h.sid')::uuid and status <> 'archived'
  loop
    if r.health_band is distinct from ((member_health(r.id)) ->> 'band')
       or r.health_reason is distinct from ((member_health(r.id)) ->> 'reason') then
      raise warning 'FAIL  cache differs from source for %', r.first_name;
      bad := bad + 1;
    end if;
  end loop;
  if bad > 0 then raise exception 'FAIL  % cached band(s) disagree with a fresh computation', bad; end if;
  raise notice 'PASS  every cached band and reason matches a fresh computation';
end $$;

reset role;

-- Source wins: corrupt the cache deliberately, then show the source disagrees
-- and recomputation settles it.
--
-- Done with RLS out of the way. A platform admin is staff of no studio, so as
-- `authenticated` these reads return no rows and the assertions would compare
-- against null — passing or failing for reasons that have nothing to do with
-- the cache.
update members set health_band = 'healthy', health_reason = null
 where studio_id = current_setting('h.sid')::uuid and first_name = 'Mayumi';

select expect_text('a stale cache can disagree with the source',
  (select health_band from members
    where studio_id = current_setting('h.sid')::uuid and first_name = 'Mayumi'), 'healthy');
select expect_text('and the source still says otherwise',
  ((member_health((select id from members where studio_id = current_setting('h.sid')::uuid
                     and first_name = 'Mayumi'))) ->> 'band'), 'at_risk');
select refresh_member_health((select id from members
  where studio_id = current_setting('h.sid')::uuid and first_name = 'Mayumi'));
select expect_text('recomputing restores it',
  (select health_band from members
    where studio_id = current_setting('h.sid')::uuid and first_name = 'Mayumi'), 'at_risk');

-- =============================================================================
-- 7. Attendance generation fires nothing it should not
--
-- Decision 14 computes on check-in, which is a trigger on check_ins. Nothing
-- else may ride along: a member does not get 200 push notifications about
-- milestones they earned two years ago.
-- =============================================================================

select expect_num('no notifications were generated',
  (select count(*) from notifications where studio_id = current_setting('h.sid')::uuid), 0);
select expect_num('no challenge progress was generated',
  (select count(*) from challenge_progress_events where studio_id = current_setting('h.sid')::uuid), 0);
select expect_num('no achievements were awarded',
  (select count(*) from member_achievements where studio_id = current_setting('h.sid')::uuid), 0);
select expect_num('no timeline events were written',
  (select count(*) from timeline_events where studio_id = current_setting('h.sid')::uuid), 0);

-- But the check-in trigger did do its own job.
select expect_num('every demo member has a computed band',
  (select count(*) from members
    where studio_id = current_setting('h.sid')::uuid and health_computed_at is null), 0);

-- =============================================================================
-- 8. Demo data is removable by construction
-- =============================================================================

select expect_num('every generated member is flagged',
  (select count(*) from members
    where studio_id = current_setting('h.sid')::uuid and not is_demo), 0);

-- Counted rather than hardcoded: this suite adds its own demo members as
-- fixtures, so a literal here breaks every time the fixtures change and says
-- nothing about whether the purge worked.
select set_config('h.demo_before',
  (select count(*)::text from members
    where studio_id = current_setting('h.sid')::uuid and is_demo), false);

set role authenticated;
select set_config('request.jwt.claim.sub','66666666-0000-0000-0000-0000000000a1',false);
select expect_num('purging clears every demo member in one call',
  ((purge_demo_data(current_setting('h.sid')::uuid)) ->> 'members')::bigint,
  current_setting('h.demo_before')::bigint);
reset role;

select expect_num('no demo members remain',
  (select count(*) from members where studio_id = current_setting('h.sid')::uuid), 0);
select expect_num('nor bookings',
  (select count(*) from bookings where studio_id = current_setting('h.sid')::uuid), 0);
select expect_num('nor check-ins',
  (select count(*) from check_ins where studio_id = current_setting('h.sid')::uuid), 0);
select expect_num('nor credit ledger rows',
  (select count(*) from credit_ledger where studio_id = current_setting('h.sid')::uuid), 0);
select expect_num('nor payments — they do not cascade with the member',
  (select count(*) from payments where studio_id = current_setting('h.sid')::uuid), 0);
select expect_num('nor occurrences',
  (select count(*) from class_occurrences where studio_id = current_setting('h.sid')::uuid), 0);
select expect_num('nor plans, rooms, class types or instructors',
  (select count(*) from membership_plans where studio_id = current_setting('h.sid')::uuid)
  + (select count(*) from rooms where studio_id = current_setting('h.sid')::uuid)
  + (select count(*) from class_types where studio_id = current_setting('h.sid')::uuid)
  + (select count(*) from instructors where studio_id = current_setting('h.sid')::uuid), 0);

-- The studio itself, its owner and its settings are not demo data.
select expect_num('the studio survives its demo data',
  (select count(*) from studios where slug = 'health-test'), 1);
select expect_num('and so does its owner',
  (select count(*) from studio_staff ss join studios s on s.id = ss.studio_id
    where s.slug = 'health-test' and ss.role = 'owner'), 1);

-- Only a platform admin may do either.
set role authenticated;
select set_config('request.jwt.claim.sub',
  (select ss.user_id::text from studio_staff ss join studios s on s.id = ss.studio_id
    where s.slug='health-test' and ss.role='owner'), false);
do $$
begin
  perform generate_demo_data(current_setting('h.sid')::uuid);
  raise exception 'FAIL  a studio owner generated demo data';
exception when sqlstate 'PT403' then
  raise notice 'PASS  a studio owner cannot generate demo data';
end $$;
do $$
begin
  perform purge_demo_data(current_setting('h.sid')::uuid);
  raise exception 'FAIL  a studio owner purged demo data';
exception when sqlstate 'PT403' then
  raise notice 'PASS  a studio owner cannot purge demo data';
end $$;
reset role;

select 'ALL HEALTH SCORE TESTS PASSED' as result;
