-- =============================================================================
-- STUDIIOR — MORNING BRIEF (migration 023)
--
--   the cap holds when far more qualify, a dismissed subject stays gone for
--   seven days, every insight's action_payload resolves to a route that
--   exists, and retention_risk agrees with the member's own health band.
--
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -f test/brief_test.sql
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

-- --- Fixtures: 2222, the one space no other suite had claimed ----------------------------------------------------------

insert into auth.users (id) values
  ('22222222-0000-0000-0000-0000000000a1'),   -- owner
  ('22222222-0000-0000-0000-0000000000a2');   -- front desk
insert into profiles (id, email) values
  ('22222222-0000-0000-0000-0000000000a1','brief-owner@example.com'),
  ('22222222-0000-0000-0000-0000000000a2','brief-desk@example.com');

insert into studios (id, name, slug, timezone, currency, status) values
  ('22222222-0000-0000-0000-000000000001','Brief Studio','brief-test','Europe/Prague','CZK','active');
insert into studio_settings (studio_id, morning_brief_send_at)
  values ('22222222-0000-0000-0000-000000000001','07:00');
insert into locations (id, studio_id, name) values
  ('22222222-0000-0000-0000-00000000000c','22222222-0000-0000-0000-000000000001','Main');
insert into studio_staff (studio_id, user_id, email, role) values
  ('22222222-0000-0000-0000-000000000001','22222222-0000-0000-0000-0000000000a1','brief-owner@example.com','owner'),
  ('22222222-0000-0000-0000-000000000001','22222222-0000-0000-0000-0000000000a2','brief-desk@example.com','front_desk');

insert into membership_plans (id, studio_id, name, type, price_cents, currency, billing_interval, credits_per_period)
values ('22222222-0000-0000-0000-00000000aa01','22222222-0000-0000-0000-000000000001',
        'Monthly','recurring',300000,'CZK','month',null);

-- Twelve members whose band already says rhythm_deviation. The band is the
-- source: this suite must never assert that generation recomputes it.
insert into members (id, studio_id, first_name, last_name, email, joined_on, status,
                     lifetime_visits, last_visit_at, health_band, health_reason, health_signals)
select ('22222222-0000-0000-0000-0000000dd0' || to_char(i,'FM00'))::uuid,
       '22222222-0000-0000-0000-000000000001',
       'Drift' || i, 'Member', 'drift' || i || '@example.com',
       current_date - 400, 'active',
       30, now() - interval '20 days', 'at_risk',
       'Was coming about every 4 days, last visit 20 days ago.', '["rhythm_deviation"]'
  from generate_series(1, 12) i;

insert into memberships (studio_id, member_id, plan_id, status, price_cents, currency, starts_on)
select '22222222-0000-0000-0000-000000000001', m.id,
       '22222222-0000-0000-0000-00000000aa01', 'active', 300000, 'CZK', current_date - 100
  from members m where m.studio_id = '22222222-0000-0000-0000-000000000001';

-- =============================================================================
-- 1. The cap holds at five when twelve qualify
-- =============================================================================

set role authenticated;
select set_config('request.jwt.claim.sub','22222222-0000-0000-0000-0000000000a1',false);

select expect_num('twelve members qualify',
  (select count(*) from members
    where studio_id='22222222-0000-0000-0000-000000000001'
      and health_signals ->> 0 = 'rhythm_deviation'), 12);

select set_config('b.res', generate_morning_brief('22222222-0000-0000-0000-000000000001')::text, false);
reset role;

select expect_num('the brief keeps five',
  (current_setting('b.res')::jsonb ->> 'insights')::bigint, 5);
select expect_num('and the table holds five, not twelve',
  (select count(*) from ai_insights where studio_id='22222222-0000-0000-0000-000000000001'), 5);
select expect_num('the brief records how many it had to choose from',
  (select (metrics ->> 'candidates_considered')::bigint from morning_briefs
    where studio_id='22222222-0000-0000-0000-000000000001'), 12);
select expect_num('the summary counts what is shown, never what was dropped',
  (select count(*) from morning_briefs
    where studio_id='22222222-0000-0000-0000-000000000001'
      and summary ilike '%five members have drifted%'), 1);

-- =============================================================================
-- 2. Every insight has an action that resolves to a real route
--
-- The routes this app actually serves. An insight whose payload points
-- somewhere the app does not have is exactly the "button that does nothing"
-- §11 calls a bug, and a test that only checked the href was non-null would
-- have let it through.
-- =============================================================================

create temp table _routes (pattern text);
insert into _routes values
  ('^/members/[0-9a-f-]{36}$'),
  ('^/members/[0-9a-f-]{36}/message$'),
  ('^/roster/[0-9a-f-]{36}$'),
  ('^/plans/[0-9a-f-]{36}$');

select expect_num('every insight carries an action_type',
  (select count(*) from ai_insights
    where studio_id='22222222-0000-0000-0000-000000000001'
      and coalesce(action_type,'') = ''), 0);
select expect_num('every insight carries an href',
  (select count(*) from ai_insights
    where studio_id='22222222-0000-0000-0000-000000000001'
      and coalesce(action_payload ->> 'href','') = ''), 0);
select expect_num('and every href matches a route this app serves',
  (select count(*) from ai_insights i
    where i.studio_id='22222222-0000-0000-0000-000000000001'
      and not exists (select 1 from _routes r
                       where (i.action_payload ->> 'href') ~ r.pattern)), 0);
select expect_num('the subject in the href is the subject of the insight',
  (select count(*) from ai_insights i
    where i.studio_id='22222222-0000-0000-0000-000000000001'
      and i.subject_type = 'member'
      and (i.action_payload ->> 'href') not like '%' || i.subject_id::text || '%'), 0);

-- =============================================================================
-- 3. retention_risk agrees with the member's band
-- =============================================================================

select expect_num('every retention_risk names a member the band already flagged',
  (select count(*) from ai_insights i
     join members m on m.id = i.subject_id
    where i.studio_id='22222222-0000-0000-0000-000000000001'
      and i.type = 'retention_risk'
      and (m.health_band not in ('at_risk','drifting')
           or m.health_signals ->> 0 <> 'rhythm_deviation')), 0);
select expect_num('and quotes the band''s own reason rather than writing a new one',
  (select count(*) from ai_insights i
     join members m on m.id = i.subject_id
    where i.studio_id='22222222-0000-0000-0000-000000000001'
      and i.type = 'retention_risk'
      and i.observation is distinct from m.health_reason), 0);

-- A member the band clears must not appear, even though nothing else about
-- them changed. This is the assertion that fails if generation ever starts
-- deciding for itself who is at risk.
update members set health_band = 'healthy', health_signals = '[]', health_reason = null
 where id = '22222222-0000-0000-0000-0000000dd001';
delete from ai_insights where studio_id = '22222222-0000-0000-0000-000000000001';
delete from morning_briefs where studio_id = '22222222-0000-0000-0000-000000000001';

set role authenticated;
select set_config('request.jwt.claim.sub','22222222-0000-0000-0000-0000000000a1',false);
select generate_morning_brief('22222222-0000-0000-0000-000000000001');
reset role;

select expect_num('a member the band cleared is not in the brief',
  (select count(*) from ai_insights
    where studio_id='22222222-0000-0000-0000-000000000001'
      and subject_id = '22222222-0000-0000-0000-0000000dd001'), 0);

-- =============================================================================
-- 4. Dedupe — a dismissed subject stays gone for seven days
-- =============================================================================

select set_config('b.subj',
  (select subject_id::text from ai_insights
    where studio_id='22222222-0000-0000-0000-000000000001' limit 1), false);

set role authenticated;
select set_config('request.jwt.claim.sub','22222222-0000-0000-0000-0000000000a1',false);
select expect_text('dismissing one records it',
  (set_insight_status(
     (select id from ai_insights
       where studio_id='22222222-0000-0000-0000-000000000001'
         and subject_id = current_setting('b.subj')::uuid limit 1),
     'dismissed')).status::text,
  'dismissed');
reset role;

-- Regenerating the same day must not resurrect it.
delete from ai_insights
 where studio_id='22222222-0000-0000-0000-000000000001' and status = 'new';
set role authenticated;
select set_config('request.jwt.claim.sub','22222222-0000-0000-0000-0000000000a1',false);
select generate_morning_brief('22222222-0000-0000-0000-000000000001');
reset role;

select expect_num('a dismissed subject does not come back the same day',
  (select count(*) from ai_insights
    where studio_id='22222222-0000-0000-0000-000000000001'
      and subject_id = current_setting('b.subj')::uuid
      and status = 'new'), 0);

-- Six days later: still suppressed.
update ai_insights set dismissed_at = now() - interval '6 days'
 where studio_id='22222222-0000-0000-0000-000000000001' and status = 'dismissed';
delete from ai_insights
 where studio_id='22222222-0000-0000-0000-000000000001' and status = 'new';
set role authenticated;
select set_config('request.jwt.claim.sub','22222222-0000-0000-0000-0000000000a1',false);
select generate_morning_brief('22222222-0000-0000-0000-000000000001', current_date + 1);
reset role;
select expect_num('still suppressed six days later',
  (select count(*) from ai_insights
    where studio_id='22222222-0000-0000-0000-000000000001'
      and subject_id = current_setting('b.subj')::uuid
      and status = 'new'), 0);

-- Eight days later: it is allowed back. The window is a window, not a delete.
update ai_insights set dismissed_at = now() - interval '8 days'
 where studio_id='22222222-0000-0000-0000-000000000001' and status = 'dismissed';
delete from ai_insights
 where studio_id='22222222-0000-0000-0000-000000000001' and status = 'new';
set role authenticated;
select set_config('request.jwt.claim.sub','22222222-0000-0000-0000-0000000000a1',false);
select generate_morning_brief('22222222-0000-0000-0000-000000000001', current_date + 2);
reset role;
select expect_num('and comes back once the window has passed',
  (select count(*) from ai_insights
    where studio_id='22222222-0000-0000-0000-000000000001'
      and subject_id = current_setting('b.subj')::uuid
      and status = 'new'), 1);

-- Actioned counts the same as dismissed: §11 suppresses on either.
update ai_insights set status = 'actioned', actioned_at = now(), dismissed_at = null
 where studio_id='22222222-0000-0000-0000-000000000001'
   and subject_id = current_setting('b.subj')::uuid;
set role authenticated;
select set_config('request.jwt.claim.sub','22222222-0000-0000-0000-0000000000a1',false);
select generate_morning_brief('22222222-0000-0000-0000-000000000001', current_date + 3);
reset role;
select expect_num('an actioned subject is suppressed too',
  (select count(*) from ai_insights
    where studio_id='22222222-0000-0000-0000-000000000001'
      and subject_id = current_setting('b.subj')::uuid
      and status = 'new' and for_date = current_date + 3), 0);

-- =============================================================================
-- 5. Thresholds are config, and one member is never two of five
-- =============================================================================

select expect_num('the cap is a row, not a literal',
  (select value::bigint from insight_config where studio_id is null and key = 'max_insights'), 5);

insert into insight_config (studio_id, key, value)
  values ('22222222-0000-0000-0000-000000000001','max_insights',2);
delete from ai_insights where studio_id='22222222-0000-0000-0000-000000000001';
set role authenticated;
select set_config('request.jwt.claim.sub','22222222-0000-0000-0000-0000000000a1',false);
select generate_morning_brief('22222222-0000-0000-0000-000000000001', current_date + 4);
reset role;
select expect_num('a studio moving the cap moves the brief',
  (select count(*) from ai_insights
    where studio_id='22222222-0000-0000-0000-000000000001' and for_date = current_date + 4), 2);
delete from insight_config where studio_id='22222222-0000-0000-0000-000000000001';

select expect_num('no member occupies two slots in one brief',
  (select coalesce(count(*),0) from (
     select subject_id from ai_insights
      where studio_id='22222222-0000-0000-0000-000000000001'
        and for_date = current_date + 4 and subject_id is not null
      group by subject_id having count(*) > 1) x), 0);

-- =============================================================================
-- 6. Permissions, and nothing sends
-- =============================================================================

set role authenticated;
select set_config('request.jwt.claim.sub','22222222-0000-0000-0000-0000000000a2',false);  -- front desk
do $$
begin
  perform generate_morning_brief('22222222-0000-0000-0000-000000000001');
  raise exception 'FAIL  front desk generated a brief';
exception when sqlstate 'PT403' then
  raise notice 'PASS  front desk cannot generate a brief';
end $$;
select expect_num('and cannot read the insights either',
  (select count(*) from ai_insights), 0);
reset role;

select expect_num('generation queued no messages',
  (select count(*) from messages
    where studio_id = '22222222-0000-0000-0000-000000000001'), 0);
select expect_num('and sent no notifications',
  (select count(*) from notifications
    where studio_id = '22222222-0000-0000-0000-000000000001'), 0);
select expect_num('no insight claims a model it never used',
  (select count(*) from ai_insights
    where studio_id='22222222-0000-0000-0000-000000000001' and model is not null), 0);

select 'ALL BRIEF TESTS PASSED' as result;
