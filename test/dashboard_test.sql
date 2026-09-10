-- =============================================================================
-- The Chapter 4 dashboard. Migrations 091 and 092. UUID space da58, checked free.
-- =============================================================================
-- Two studios in one run, in two timezones, one empty and one with generated
-- history — because the empty case is what every design partner sees on their
-- first morning and it is the case a suite built only from fixtures never
-- tests.
--
-- The load-bearing assertions here are the ones about the boundary between the
-- numbers and the prose: SQL produces every figure, the model writes sentences
-- about figures it is given, and a sentence containing a number nothing
-- computed is REFUSED rather than displayed. If a card says 14 at risk and the
-- narrative says 12, the dashboard is worthless.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual then raise notice 'PASS  %  (got true)', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_null(label text, actual text)
returns void language plpgsql as $$
begin
  if actual is null then raise notice 'PASS  %  (got null)', label;
  else raise exception 'FAIL  %  expected null, got %', label, actual; end if;
end $$;
create or replace function expect_raises(label text, stmt text, want_sqlstate text)
returns void language plpgsql as $$
begin
  execute stmt; raise exception 'FAIL  %  expected % but nothing was raised', label, want_sqlstate;
exception when others then
  if sqlstate = want_sqlstate then raise notice 'PASS  %  (got %)', label, sqlstate;
  elsif sqlstate = 'P0001' and sqlerrm like 'FAIL%' then raise;
  else raise exception 'FAIL  %  expected %, got % (%)', label, want_sqlstate, sqlstate, sqlerrm; end if;
end $$;

-- ===========================================================================
-- FIXTURES
--
-- A — Manila, completely empty. Day one, exactly as hosted's Reform Collective
--     stands today: nobody, nothing, no takings.
-- B — Prague, with generated history, so the populated case is real data
--     rather than three rows written to make an assertion pass.
-- C — a third studio's manager, who is the caller no guard has ever seen.
--     "A guard that never fires looks exactly like a guard that passes."
-- ===========================================================================
insert into auth.users (id) values
  ('da58da58-0000-0000-0000-0000000000a1'),   -- A owner
  ('da58da58-0000-0000-0000-0000000000b1'),   -- B owner
  ('da58da58-0000-0000-0000-0000000000b2'),   -- B front desk
  ('da58da58-0000-0000-0000-0000000000b3'),   -- B instructor
  ('da58da58-0000-0000-0000-0000000000c1'),   -- C manager, a stranger to A and B
  ('da58da58-0000-0000-0000-0000000000d1');   -- a member of B, no staff row anywhere
insert into profiles (id, email, full_name) values
  ('da58da58-0000-0000-0000-0000000000a1','da58-a-owner@example.com','A Owner'),
  ('da58da58-0000-0000-0000-0000000000b1','da58-b-owner@example.com','B Owner'),
  ('da58da58-0000-0000-0000-0000000000b2','da58-b-desk@example.com','B Desk'),
  ('da58da58-0000-0000-0000-0000000000b3','da58-b-instr@example.com','B Instructor'),
  ('da58da58-0000-0000-0000-0000000000c1','da58-c-mgr@example.com','C Manager'),
  ('da58da58-0000-0000-0000-0000000000d1','da58-b-member@example.com','B Member');
insert into platform_admins (user_id, email, note) values
  ('da58da58-0000-0000-0000-0000000000b1','da58-b-owner@example.com','dashboard suite: generates demo history');

insert into studios (id, name, slug, timezone, currency, country, status) values
  ('da58da58-0000-0000-0000-00000000000a','Day One','da58-day-one','Asia/Manila','PHP','PH','active'),
  ('da58da58-0000-0000-0000-00000000000b','Full House','da58-full-house','Europe/Prague','CZK','CZ','active'),
  ('da58da58-0000-0000-0000-00000000000c','Elsewhere','da58-elsewhere','Europe/Prague','CZK','CZ','active');
insert into studio_settings (studio_id, checkin_window_enforced) values
  ('da58da58-0000-0000-0000-00000000000a', false),
  ('da58da58-0000-0000-0000-00000000000b', false),
  ('da58da58-0000-0000-0000-00000000000c', false);
insert into locations (id, studio_id, name, timezone, is_primary) values
  ('da58da58-0000-0000-0000-0000000000fa','da58da58-0000-0000-0000-00000000000a','Main','Asia/Manila',true),
  ('da58da58-0000-0000-0000-0000000000fb','da58da58-0000-0000-0000-00000000000b','Main','Europe/Prague',true),
  ('da58da58-0000-0000-0000-0000000000fc','da58da58-0000-0000-0000-00000000000c','Main','Europe/Prague',true);
insert into studio_staff (studio_id, user_id, email, role) values
  ('da58da58-0000-0000-0000-00000000000a','da58da58-0000-0000-0000-0000000000a1','da58-a-owner@example.com','owner'),
  ('da58da58-0000-0000-0000-00000000000b','da58da58-0000-0000-0000-0000000000b1','da58-b-owner@example.com','owner'),
  ('da58da58-0000-0000-0000-00000000000b','da58da58-0000-0000-0000-0000000000b2','da58-b-desk@example.com','front_desk'),
  ('da58da58-0000-0000-0000-00000000000b','da58da58-0000-0000-0000-0000000000b3','da58-b-instr@example.com','instructor'),
  ('da58da58-0000-0000-0000-00000000000c','da58da58-0000-0000-0000-0000000000c1','da58-c-mgr@example.com','manager');

-- B gets generated history. auth.uid() survives `reset role`, so the claim is
-- cleared explicitly afterwards — two suites promoted a demo fixture by
-- accident before that was noticed.
set role authenticated;
select set_config('request.jwt.claim.sub','da58da58-0000-0000-0000-0000000000b1',false);
select set_config('da58.gen', (select generate_demo_data('da58da58-0000-0000-0000-00000000000b')::text), false);
reset role;
select set_config('request.jwt.claim.sub','',false);
select expect_true('B has generated history',
  (current_setting('da58.gen')::jsonb ->> 'occurrences')::int > 0);

-- A member of B with a login, for the permission half.
insert into members (id, studio_id, user_id, first_name, last_name, email, status, joined_on)
values ('da58da58-0000-0000-0000-0000000000d0','da58da58-0000-0000-0000-00000000000b',
        'da58da58-0000-0000-0000-0000000000d1','Bea','Member','da58-b-member@example.com','active', current_date - 90);

\echo ''
\echo '=== 1. DAY ONE — every block distinguishes "never happened" from "not today" ==='
set role authenticated;
select set_config('request.jwt.claim.sub','da58da58-0000-0000-0000-0000000000a1',false);

select set_config('da58.k', dashboard_kpis('da58da58-0000-0000-0000-00000000000a')::text, false);

select expect_num('an empty studio gets six cards, not eight',
  jsonb_array_length(current_setting('da58.k')::jsonb -> 'cards')::bigint, 6);

select expect_num('every one of them is empty rather than zero',
  (select count(*) from jsonb_array_elements(current_setting('da58.k')::jsonb -> 'cards') c
    where c ->> 'state' = 'empty'), 6);

-- ZERO BOOKED SEATS IS NOT NOUGHT PER CENT. Answering "0%" tells an owner
-- their morning went badly when in fact nothing has run.
select expect_null('attendance with nothing booked is null, not 0',
  (select c ->> 'value' from jsonb_array_elements(current_setting('da58.k')::jsonb -> 'cards') c
    where c ->> 'key' = 'attendance_today'));

-- Decision 14: absence of evidence is not evidence of health.
select expect_text('members at risk with no bands computed is empty, not a clean bill of health',
  (select c ->> 'state' from jsonb_array_elements(current_setting('da58.k')::jsonb -> 'cards') c
    where c ->> 'key' = 'members_at_risk'), 'empty');

select expect_num('every empty card explains what will fill it',
  (select count(*) from jsonb_array_elements(current_setting('da58.k')::jsonb -> 'cards') c
    where c ->> 'state' = 'empty' and length(coalesce(c ->> 'empty_hint','')) > 40), 6);

select expect_text('revenue is empty',
  dashboard_revenue('da58da58-0000-0000-0000-00000000000a',
                    studio_today('da58da58-0000-0000-0000-00000000000a') - 29,
                    studio_today('da58da58-0000-0000-0000-00000000000a')) ->> 'state', 'empty');
select expect_text('the heat map is empty',
  dashboard_heatmap('da58da58-0000-0000-0000-00000000000a', 90) ->> 'state', 'empty');
select expect_text('member health is empty',
  dashboard_health('da58da58-0000-0000-0000-00000000000a') ->> 'state', 'empty');
select expect_text('the activity feed is empty',
  dashboard_activity('da58da58-0000-0000-0000-00000000000a', 12) ->> 'state', 'empty');
select expect_text('the month is empty',
  dashboard_month('da58da58-0000-0000-0000-00000000000a') ->> 'state', 'empty');

select expect_num('every empty block says what it will show',
  (select count(*) from (values
     (dashboard_revenue('da58da58-0000-0000-0000-00000000000a',
        studio_today('da58da58-0000-0000-0000-00000000000a') - 29,
        studio_today('da58da58-0000-0000-0000-00000000000a')) ->> 'empty_hint'),
     (dashboard_heatmap('da58da58-0000-0000-0000-00000000000a', 90) ->> 'empty_hint'),
     (dashboard_health('da58da58-0000-0000-0000-00000000000a') ->> 'empty_hint'),
     (dashboard_activity('da58da58-0000-0000-0000-00000000000a', 12) ->> 'empty_hint'),
     (dashboard_month('da58da58-0000-0000-0000-00000000000a') ->> 'empty_hint')
   ) v(h) where length(coalesce(h,'')) > 40), 5);

-- A card that can never populate is the insight-without-a-button mistake; one
-- silently missing is how it is rediscovered as a bug in six months.
select expect_num('both absent cards are named, with a reason',
  jsonb_array_length(dashboard_absent_cards('da58da58-0000-0000-0000-00000000000a'))::bigint, 2);
select expect_true('challenge participation is named as waiting on challenges',
  (dashboard_absent_cards('da58da58-0000-0000-0000-00000000000a'))::text like '%Challenges have no screens yet%');
select expect_true('the forecast names how many months it still needs',
  (dashboard_absent_cards('da58da58-0000-0000-0000-00000000000a'))::text like '%3 complete months%');

reset role;
\echo ''
\echo '=== 2. FULL HOUSE — the figures are the data, not a second opinion of it ==='
set role authenticated;
select set_config('request.jwt.claim.sub','da58da58-0000-0000-0000-0000000000b1',false);
select set_config('da58.kb', dashboard_kpis('da58da58-0000-0000-0000-00000000000b')::text, false);

select expect_num('nothing on a studio with history reads as empty',
  (select count(*) from jsonb_array_elements(current_setting('da58.kb')::jsonb -> 'cards') c
    where c ->> 'state' = 'empty' and c ->> 'key' in
      ('revenue_today','bookings_today','active_members','members_at_risk','avg_occupancy')), 0);

select expect_num('never more than eight cards',
  (select count(*) from jsonb_array_elements(current_setting('da58.kb')::jsonb -> 'cards') c
    where jsonb_array_length(current_setting('da58.kb')::jsonb -> 'cards') > 8), 0);

reset role;
select set_config('da58.b_rev', (
  select coalesce(sum(p.amount_cents),0)::text from payments p
   where p.studio_id = 'da58da58-0000-0000-0000-00000000000b'
     and p.status in ('succeeded','partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= ((studio_today('da58da58-0000-0000-0000-00000000000b') - 29)::timestamp at time zone 'Europe/Prague')
     and coalesce(p.paid_at, p.created_at) <  ((studio_today('da58da58-0000-0000-0000-00000000000b') + 1)::timestamp at time zone 'Europe/Prague')), false);
set role authenticated;
select set_config('request.jwt.claim.sub','da58da58-0000-0000-0000-0000000000b1',false);
select set_config('da58.r', dashboard_revenue('da58da58-0000-0000-0000-00000000000b',
  studio_today('da58da58-0000-0000-0000-00000000000b') - 29,
  studio_today('da58da58-0000-0000-0000-00000000000b'))::text, false);

select expect_num('revenue agrees with the payments table to the cent',
  (current_setting('da58.r')::jsonb ->> 'total_cents')::bigint,
  current_setting('da58.b_rev')::numeric::bigint);

select expect_num('the sources add up to the total',
  (select coalesce(sum((s->>'cents')::bigint),0)::bigint from jsonb_array_elements(current_setting('da58.r')::jsonb -> 'by_source') s),
  (current_setting('da58.r')::jsonb ->> 'total_cents')::bigint);

-- Retail and gift cards are not in this product. A legend with two permanent
-- noughts teaches an owner the chart has categories it does not fill in.
select expect_num('there is no retail row and no gift-card row',
  (select count(*) from jsonb_array_elements(current_setting('da58.r')::jsonb -> 'by_source') s
    where s ->> 'source' in ('retail','gift_card')), 0);
select expect_num('every source is one of the five this product actually has',
  (select count(*) from jsonb_array_elements(current_setting('da58.r')::jsonb -> 'by_source') s
    where s ->> 'source' not in ('membership','pack','drop_in','private','trial','other')), 0);

select expect_num('the day series has one point per day, gaps included',
  jsonb_array_length(current_setting('da58.r')::jsonb -> 'series')::bigint, 30);

select set_config('da58.h', dashboard_heatmap('da58da58-0000-0000-0000-00000000000b', 90)::text, false);
select expect_text('the heat map has run', current_setting('da58.h')::jsonb ->> 'state', 'ok');
select expect_true('it names a busiest slot',
  jsonb_typeof(current_setting('da58.h')::jsonb -> 'peak') = 'object');
-- One busy Thursday is not a pattern.
select expect_true('the busiest slot has enough classes behind it to mean something',
  (current_setting('da58.h')::jsonb -> 'peak' ->> 'classes')::int
   >= (current_setting('da58.h')::jsonb ->> 'min_classes_for_pattern')::int);
select expect_num('no cell claims more people than seats',
  (select count(*) from jsonb_array_elements(current_setting('da58.h')::jsonb -> 'cells') c
    where (c->>'booked')::int > (c->>'capacity')::int), 0);

select set_config('da58.hb', dashboard_health('da58da58-0000-0000-0000-00000000000b')::text, false);
select expect_num('the bands account for every banded member',
  (select coalesce(sum((b->>'count')::int),0)::bigint from jsonb_array_elements(current_setting('da58.hb')::jsonb -> 'bands') b),
  (current_setting('da58.hb')::jsonb ->> 'banded')::bigint);
-- The Bible says thriving/drifting/at risk/critical; Decision 14 settled five
-- bands and the decision log is canonical. "critical" would have to be
-- invented at render time — a number the screen made up, in the one widget
-- whose whole argument is that it does not do that.
select expect_num('the five bands are Decision 14''s, and there is no invented sixth',
  (select count(*) from jsonb_array_elements(current_setting('da58.hb')::jsonb -> 'bands') b
    where b ->> 'band' not in ('healthy','drifting','at_risk','new','insufficient_history')), 0);
select expect_num('there are exactly five of them',
  jsonb_array_length(current_setting('da58.hb')::jsonb -> 'bands')::bigint, 5);

select expect_text('the activity feed has something in it',
  dashboard_activity('da58da58-0000-0000-0000-00000000000b', 12) ->> 'state', 'ok');
select expect_num('it reads timeline_events and derives nothing a second time',
  (select count(*) from jsonb_array_elements(dashboard_activity('da58da58-0000-0000-0000-00000000000b', 12) -> 'items') i
    where not exists (select 1 from timeline_events te where te.id = (i->>'id')::uuid)), 0);

reset role;
select set_config('da58.b_month', (
  select count(*)::text from class_occurrences o
   where o.studio_id = 'da58da58-0000-0000-0000-00000000000b' and o.status <> 'cancelled'
     and (o.starts_at at time zone 'Europe/Prague')::date
         between date_trunc('month', studio_today('da58da58-0000-0000-0000-00000000000b'))::date
             and (date_trunc('month', studio_today('da58da58-0000-0000-0000-00000000000b')) + interval '1 month - 1 day')::date), false);
set role authenticated;
select set_config('request.jwt.claim.sub','da58da58-0000-0000-0000-0000000000b1',false);
select expect_num('the month counts the classes that are actually on it',
  (dashboard_month('da58da58-0000-0000-0000-00000000000b') ->> 'total_classes')::bigint,
  current_setting('da58.b_month')::numeric::bigint);
select expect_num('the month grid carries the studio''s own week start',
  (dashboard_month('da58da58-0000-0000-0000-00000000000b') ->> 'week_starts_on')::bigint,
  (select week_starts_on::bigint from studio_settings where studio_id = 'da58da58-0000-0000-0000-00000000000b'));
reset role;

\echo ''
\echo '=== 3. THE BOUNDARY — SQL makes every number; the model may only repeat them ==='

-- The verifier, on its own, both ways. This is the mechanical form of "the AI
-- never computes anything": a prompt is a request, this is a rule.
select expect_null('a sentence using only the figures it was given is accepted',
  narrative_offending_number(
    'You took 42,900 CZK over the last 30 days, 1% ahead of the 42,450 CZK before it.',
    array['42900','42450','1','30']));

select expect_text('a figure nothing computed is caught and named',
  narrative_offending_number('Revenue was 42,900 CZK, up 8% on last month.',
    array['42900','42450','1','30']), '8');

-- The exact case the whole layer exists for: the card says 12, the sentence
-- says 14. Refused.
select expect_text('a sentence that disagrees with the card is refused, not shown with a caveat',
  narrative_offending_number('14 members are at risk.', array['12']), '14');

select expect_null('a sentence with no numbers in it at all is fine',
  narrative_offending_number('Revenue held steady, carried by memberships.', array['42900']));

-- 42900.0 and 42900 are the same figure; 42900 and 429 are not. The first
-- version of this compared strings and turned an allowed 42900 into 429.
select expect_null('the same number written with a trailing zero is the same number',
  narrative_offending_number('You took 42900.0 this month.', array['42900']));

-- A CLOCK TIME IS ONE FIGURE. Split on the colon it becomes 19 and 00, and 00
-- is in no fact set anywhere, so every sentence naming an hour was refused for
-- a number nobody wrote.
select expect_null('a clock time survives the split',
  narrative_offending_number('Tuesday at 19:00 runs 38% full across 13 classes.',
    array['1900','38','13']));

-- A thousands separator is a comma plus exactly three digits. The looser rule
-- swallowed the gap between two numbers and glued "19:00, 38" into 190038.
select expect_num('two numbers either side of a comma stay two numbers',
  array_length(narrative_numbers('Tuesday at 19:00, 38% full'), 1)::bigint, 2);

select expect_text('a stray year is not a figure it was given',
  narrative_offending_number('Since 2026 revenue is 42,900.', array['42900']), '2026');

\echo ''
\echo '--- and the same rule applied to a real answer coming back ---'
reset role;

-- Queue three narratives for B, then hand each a hand-written answer as though
-- the API had replied. Nothing here reaches the network.
select expect_true('narratives queue for a studio with a brief',
  (select queue_dashboard_narrative('da58da58-0000-0000-0000-00000000000b','revenue') is not null));
select expect_true('and for the heat map',
  (select queue_dashboard_narrative('da58da58-0000-0000-0000-00000000000b','attendance') is not null));

-- With no key configured — the ordinary state on a fresh stack — the row keeps
-- its written sentence and says why, rather than raising and taking the cron
-- down for every other studio with it.
select expect_text('no API key is an ordinary state, not an error',
  (select status from dashboard_narratives
    where studio_id='da58da58-0000-0000-0000-00000000000b' and kind='revenue'), 'failed');
select expect_true('and the written sentence is already there',
  (select length(fallback) > 20 from dashboard_narratives
    where studio_id='da58da58-0000-0000-0000-00000000000b' and kind='revenue'));

-- Pretend a key exists so the request path runs, then answer it by hand.
select set_config('app.anthropic_api_key','sk-ant-not-a-real-key',false);
select set_config('da58.n1', queue_dashboard_narrative('da58da58-0000-0000-0000-00000000000b','revenue')::text, false);
update dashboard_narratives set net_request_id = 950001
 where id = current_setting('da58.n1')::uuid;

select set_config('da58.allowed',
  (select (facts -> 'allowed') ->> 0 from dashboard_narratives where id = current_setting('da58.n1')::uuid), false);

insert into net._http_response (id,status_code,content_type,headers,content,timed_out,error_msg,created)
values (950001, 200, 'application/json', '{}',
  jsonb_build_object('content', jsonb_build_array(jsonb_build_object('type','text','text',
    '{"text":"Revenue moved on the back of memberships this month."}')))::text,
  false, null, now());

select set_config('da58.rc', reconcile_dashboard_narratives()::text, false);
select expect_text('a clean answer is accepted and becomes the sentence on the screen',
  (select status from dashboard_narratives where id = current_setting('da58.n1')::uuid), 'ready');
select expect_true('and it is the model''s words, not the fallback',
  (select body is not null and body <> fallback from dashboard_narratives
    where id = current_setting('da58.n1')::uuid));

-- Now the same row, answered with an invented figure.
update dashboard_narratives set status='pending', net_request_id=950002, body=null, error=null
 where id = current_setting('da58.n1')::uuid;
insert into net._http_response (id,status_code,content_type,headers,content,timed_out,error_msg,created)
values (950002, 200, 'application/json', '{}',
  jsonb_build_object('content', jsonb_build_array(jsonb_build_object('type','text','text',
    '{"text":"You took 999999 CZK, which is 47% up."}')))::text,
  false, null, now());
select set_config('da58.rc', reconcile_dashboard_narratives()::text, false);
select expect_text('an answer carrying a number nothing computed is refused',
  (select status from dashboard_narratives where id = current_setting('da58.n1')::uuid), 'rejected');
select expect_null('and the wrong sentence is not stored at all',
  (select body from dashboard_narratives where id = current_setting('da58.n1')::uuid));
-- It names ONE of them and stops. Both 999999 and 47 are invented here and
-- either is enough to diagnose the answer; naming every one would be a longer
-- message for a row nobody is going to display.
select expect_true('the refusal names an offending figure',
  (select error like '%999999%' or error like '%47%'
     from dashboard_narratives where id = current_setting('da58.n1')::uuid));
-- The written sentence survives a refusal, which is what makes the screen
-- complete either way.
select expect_true('the deterministic sentence is untouched by the refusal',
  (select length(fallback) > 20 from dashboard_narratives where id = current_setting('da58.n1')::uuid));

-- The lead may be REORDERED by the model. It may not be invented.
select set_config('da58.lead', queue_dashboard_narrative('da58da58-0000-0000-0000-00000000000b','lead')::text, false);
update dashboard_narratives set status='pending', net_request_id=950003
 where id = current_setting('da58.lead')::uuid;
insert into net._http_response (id,status_code,content_type,headers,content,timed_out,error_msg,created)
values (950003, 200, 'application/json', '{}',
  jsonb_build_object('content', jsonb_build_array(jsonb_build_object('type','text','text',
    '{"text":"Somebody needs a nudge.","lead_id":"00000000-0000-0000-0000-0000000000ff"}')))::text,
  false, null, now());
-- THIS ROW, not "at least one row somewhere". A counter of >= 1 passes when
-- some other row in the same pass was rejected, which is the same shape as a
-- guard that never fires looking exactly like one that passes.
select set_config('da58.rc', reconcile_dashboard_narratives()::text, false);
select expect_text('leading on an insight that was never offered is refused',
  (select status from dashboard_narratives where id = current_setting('da58.lead')::uuid), 'rejected');
select expect_true('and says so',
  (select error like '%not in the list%' from dashboard_narratives where id = current_setting('da58.lead')::uuid));
select expect_null('the invented lead is not stored',
  (select lead_insight_id::text from dashboard_narratives where id = current_setting('da58.lead')::uuid));

-- A malformed answer is a failure, not a crash.
update dashboard_narratives set status='pending', net_request_id=950004, error=null
 where id = current_setting('da58.n1')::uuid;
insert into net._http_response (id,status_code,content_type,headers,content,timed_out,error_msg,created)
values (950004, 200, 'application/json', '{}',
  jsonb_build_object('content', jsonb_build_array(jsonb_build_object('type','text','text',
    'here you go, no JSON at all')))::text, false, null, now());
select set_config('da58.rc', reconcile_dashboard_narratives()::text, false);
select expect_text('an answer that is not the JSON asked for fails the row and nothing else',
  (select status from dashboard_narratives where id = current_setting('da58.n1')::uuid), 'failed');
select expect_true('and the raw answer is kept so it can be diagnosed',
  (select response_body is not null from dashboard_narratives where id = current_setting('da58.n1')::uuid));

-- An HTTP failure at Anthropic.
update dashboard_narratives set status='pending', net_request_id=950005, error=null
 where id = current_setting('da58.n1')::uuid;
insert into net._http_response (id,status_code,content_type,headers,content,timed_out,error_msg,created)
values (950005, 503, 'application/json', '{}', '{"error":"overloaded"}', false, null, now());
select set_config('da58.rc', reconcile_dashboard_narratives()::text, false);
select expect_text('an outage at the provider fails the row and nothing else',
  (select status from dashboard_narratives where id = current_setting('da58.n1')::uuid), 'failed');
select expect_true('and names the status code rather than swallowing it',
  (select error like '%503%' from dashboard_narratives where id = current_setting('da58.n1')::uuid));

\echo ''
\echo '--- THE AI FAILING LEAVES EVERY NUMBER INTACT ---'
-- Every narrative for B is now failed or rejected. The figures must be
-- identical to what they were before any of it, because they never came from
-- the model in the first place.
set role authenticated;
select set_config('request.jwt.claim.sub','da58da58-0000-0000-0000-0000000000b1',false);
select expect_text('the KPI cards are byte-identical with the AI in ruins',
  md5(dashboard_kpis('da58da58-0000-0000-0000-00000000000b')::text),
  md5(current_setting('da58.kb')));
select expect_text('so is revenue',
  md5(dashboard_revenue('da58da58-0000-0000-0000-00000000000b',
        studio_today('da58da58-0000-0000-0000-00000000000b') - 29,
        studio_today('da58da58-0000-0000-0000-00000000000b'))::text),
  md5(current_setting('da58.r')));
select expect_text('so is the heat map',
  md5(dashboard_heatmap('da58da58-0000-0000-0000-00000000000b', 90)::text),
  md5(current_setting('da58.h')));
select expect_text('so is member health',
  md5(dashboard_health('da58da58-0000-0000-0000-00000000000b')::text),
  md5(current_setting('da58.hb')));

-- And the screen still has a sentence for every block.
select expect_true('a rejected narrative still shows the written sentence',
  (dashboard_narrative('da58da58-0000-0000-0000-00000000000b','revenue') ->> 'text') is not null);
select expect_text('and says it is the written one',
  dashboard_narrative('da58da58-0000-0000-0000-00000000000b','revenue') ->> 'source', 'written');

-- No row at all — the cron has never run for this studio — is still a sentence.
select expect_true('a studio the cron has never reached still gets a sentence',
  (dashboard_narrative('da58da58-0000-0000-0000-00000000000b','attendance') ->> 'text') is not null);

-- THE WINDOW TRAVELS WITH THE SENTENCE, so a screen showing 90 days cannot put
-- a 30-day sentence over it.
select expect_num('a revenue sentence declares the window it describes',
  (dashboard_narrative('da58da58-0000-0000-0000-00000000000b','revenue') ->> 'covers_days')::bigint, 30);
select expect_num('and an attendance sentence declares its own',
  (dashboard_narrative('da58da58-0000-0000-0000-00000000000b','attendance') ->> 'covers_days')::bigint, 90);

-- Nothing to say is an answer, not a gap.
reset role;
select expect_text('a studio with no takings is skipped rather than given an empty sentence',
  (dashboard_facts('da58da58-0000-0000-0000-00000000000a','revenue') ->> 'skip'), 'true');
set role authenticated;
select set_config('request.jwt.claim.sub','da58da58-0000-0000-0000-0000000000a1',false);
select expect_text('and the screen is told why rather than shown a blank',
  dashboard_narrative('da58da58-0000-0000-0000-00000000000a','revenue') ->> 'state', 'nothing_to_say');
reset role;

-- Switching the layer off changes the voice and nothing else.
update dashboard_ai_config set value = '0' where key = 'enabled';
select set_config('da58.off', queue_dashboard_narrative('da58da58-0000-0000-0000-00000000000b','attendance')::text, false);
select expect_true('with the AI switched off the row says so and keeps its sentence',
  (select status = 'failed' and length(fallback) > 20 from dashboard_narratives
    where id = current_setting('da58.off')::uuid));
update dashboard_ai_config set value = '1' where key = 'enabled';

\echo ''
\echo '=== 4. WHO MAY LOOK — the guard is inside, never the grant ==='
-- Every function here is SECURITY DEFINER, and migration 056's rule is that a
-- function taking an id and returning tenant data needs its own check. The
-- callers below include one the guard has never seen: a manager of a THIRD
-- studio, who is real staff with a real role and no relationship to B.
-- "A guard that never fires looks exactly like a guard that passes."

set role authenticated;
select set_config('request.jwt.claim.sub','da58da58-0000-0000-0000-0000000000c1',false);
select expect_raises('another studio''s manager cannot read the figures',
  $$ select dashboard_kpis('da58da58-0000-0000-0000-00000000000b') $$, 'PT403');
select expect_raises('nor the revenue',
  $$ select dashboard_revenue('da58da58-0000-0000-0000-00000000000b', current_date - 7, current_date) $$, 'PT403');
select expect_raises('nor the heat map',
  $$ select dashboard_heatmap('da58da58-0000-0000-0000-00000000000b', 90) $$, 'PT403');
select expect_raises('nor member health',
  $$ select dashboard_health('da58da58-0000-0000-0000-00000000000b') $$, 'PT403');
select expect_raises('nor the activity feed',
  $$ select dashboard_activity('da58da58-0000-0000-0000-00000000000b', 5) $$, 'PT403');
select expect_raises('nor the action centre',
  $$ select dashboard_tasks('da58da58-0000-0000-0000-00000000000b') $$, 'PT403');
select expect_raises('nor the month',
  $$ select dashboard_month('da58da58-0000-0000-0000-00000000000b') $$, 'PT403');
select expect_raises('nor the written sentence',
  $$ select dashboard_narrative('da58da58-0000-0000-0000-00000000000b','revenue') $$, 'PT403');
select expect_raises('nor the figures behind it',
  $$ select dashboard_facts('da58da58-0000-0000-0000-00000000000b','revenue') $$, 'PT403');
select expect_num('and the narratives table itself returns them nothing',
  (select count(*) from dashboard_narratives where studio_id = 'da58da58-0000-0000-0000-00000000000b'), 0);

-- Permissions §12 note 21: revenue and churn stay away from front desk and
-- instructors, and it is the database that says so rather than the nav.
select set_config('request.jwt.claim.sub','da58da58-0000-0000-0000-0000000000b2',false);
select expect_raises('front desk of this very studio cannot read the figures',
  $$ select dashboard_kpis('da58da58-0000-0000-0000-00000000000b') $$, 'PT403');
select expect_raises('nor the revenue',
  $$ select dashboard_revenue('da58da58-0000-0000-0000-00000000000b', current_date - 7, current_date) $$, 'PT403');

select set_config('request.jwt.claim.sub','da58da58-0000-0000-0000-0000000000b3',false);
select expect_raises('nor can the instructor',
  $$ select dashboard_kpis('da58da58-0000-0000-0000-00000000000b') $$, 'PT403');
select expect_num('and the instructor sees no narratives either',
  (select count(*) from dashboard_narratives where studio_id = 'da58da58-0000-0000-0000-00000000000b'), 0);

-- An ordinary member of the studio, which is every signed-in person on the
-- internet as far as the `authenticated` role is concerned.
select set_config('request.jwt.claim.sub','da58da58-0000-0000-0000-0000000000d1',false);
select expect_raises('a member cannot read their studio''s takings',
  $$ select dashboard_kpis('da58da58-0000-0000-0000-00000000000b') $$, 'PT403');
select expect_raises('nor who is at risk',
  $$ select dashboard_health('da58da58-0000-0000-0000-00000000000b') $$, 'PT403');
select expect_num('nor any narrative row',
  (select count(*) from dashboard_narratives), 0);

-- The backend-only surface. These reach the network or return a credential,
-- and closed to every client role is a stronger statement than a check.
select expect_raises('a member cannot ask for the API key',
  $$ select anthropic_api_key() $$, '42501');
select expect_raises('nor queue a call to Anthropic',
  $$ select queue_dashboard_narrative('da58da58-0000-0000-0000-00000000000b','revenue') $$, '42501');
select expect_raises('nor reconcile one',
  $$ select reconcile_dashboard_narratives() $$, '42501');
select expect_raises('nor run the job',
  $$ select run_due_dashboard_narratives() $$, '42501');
select expect_raises('nor read the studio''s money by the day',
  $$ select studio_revenue_between('da58da58-0000-0000-0000-00000000000b', now() - interval '1 day', now()) $$, '42501');

reset role;
-- anon reaches none of it. Hosted grants anon explicitly by default, which no
-- local stack shows and which has cost this project five migrations.
set role anon;
select expect_raises('anon cannot reach the dashboard',
  $$ select dashboard_kpis('da58da58-0000-0000-0000-00000000000b') $$, '42501');
select expect_raises('anon cannot reach the narratives',
  $$ select dashboard_narrative('da58da58-0000-0000-0000-00000000000b','revenue') $$, '42501');
select expect_raises('anon cannot reach the key',
  $$ select anthropic_api_key() $$, '42501');
reset role;

-- The owner of B can, which is what makes the refusals above mean something
-- rather than being a function that refuses everybody.
set role authenticated;
select set_config('request.jwt.claim.sub','da58da58-0000-0000-0000-0000000000b1',false);
select expect_true('the owner of this studio can read all of it',
  (dashboard_kpis('da58da58-0000-0000-0000-00000000000b') ->> 'today') is not null
  and (dashboard_health('da58da58-0000-0000-0000-00000000000b') ->> 'state') is not null
  and (dashboard_tasks('da58da58-0000-0000-0000-00000000000b') ->> 'state') is not null);
select expect_true('and their own narratives',
  (select count(*) > 0 from dashboard_narratives where studio_id = 'da58da58-0000-0000-0000-00000000000b'));
reset role;

\echo ''
\echo '=== 5. TWO STUDIOS, TWO CLOCKS, ONE RUN ==='
-- THE RULE: every time shown anywhere is the STUDIO's timezone. A fixture
-- where the studio, the server and the browser share a zone tests nothing
-- about this, which is why both studios are exercised in one pass.
--
-- 07:00 in Manila is 23:00 UTC the previous day. Reading dow and hour off the
-- raw instant puts that class in the wrong cell AND on the wrong row.
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('da58da58-0000-0000-0000-0000000000e1','da58da58-0000-0000-0000-00000000000a','Sunrise',60,10);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('da58da58-0000-0000-0000-0000000000e2','da58da58-0000-0000-0000-00000000000a','da58da58-0000-0000-0000-0000000000fa','Studio',10);

-- Five Wednesdays at 07:00 Manila, all in the past so they count as having run.
insert into class_occurrences
  (studio_id, location_id, class_type_id, name, room_id, capacity, starts_at, ends_at, booked_count, status)
select 'da58da58-0000-0000-0000-00000000000a','da58da58-0000-0000-0000-0000000000fa',
       'da58da58-0000-0000-0000-0000000000e1','Sunrise','da58da58-0000-0000-0000-0000000000e2', 10,
       (d + time '07:00') at time zone 'Asia/Manila',
       (d + time '08:00') at time zone 'Asia/Manila', 8, 'scheduled'
  -- ::date on the loop variable. generate_series over dates yields TIMESTAMPTZ,
  -- so `(d + time) at time zone tz` converts the wrong way and the classes
  -- land three hours out — a trap this repo has paid for twice.
  from generate_series(
    (studio_today('da58da58-0000-0000-0000-00000000000a') - 35)::date,
    (studio_today('da58da58-0000-0000-0000-00000000000a') - 7)::date,
    interval '7 days') g(ts), lateral (select g.ts::date as d) x;

set role authenticated;
select set_config('request.jwt.claim.sub','da58da58-0000-0000-0000-0000000000a1',false);
select set_config('da58.hm_a', dashboard_heatmap('da58da58-0000-0000-0000-00000000000a', 90)::text, false);

select expect_num('a 07:00 Manila class lands on Manila''s 07:00 row, not the server''s 23:00',
  (select (c ->> 'hour')::int from jsonb_array_elements(current_setting('da58.hm_a')::jsonb -> 'cells') c
    where (c->>'classes')::int > 0 limit 1)::bigint, 7);
select expect_num('and on Wednesday, not Tuesday',
  (select (c ->> 'dow')::int from jsonb_array_elements(current_setting('da58.hm_a')::jsonb -> 'cells') c
    where (c->>'classes')::int > 0 limit 1)::bigint,
  extract(dow from (studio_today('da58da58-0000-0000-0000-00000000000a') - 7))::bigint);
select expect_text('the heat map says which clock it is in',
  current_setting('da58.hm_a')::jsonb ->> 'timezone', 'Asia/Manila');
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub','da58da58-0000-0000-0000-0000000000b1',false);
select expect_text('and the other studio, in the same run, says its own',
  dashboard_heatmap('da58da58-0000-0000-0000-00000000000b', 90) ->> 'timezone', 'Europe/Prague');
reset role;

\echo ''
\echo '=== 6. EMPTY IS NOT ZERO, AND ZERO IS NOT EMPTY ==='
-- The mirror of section 1. A studio that HAS taken money and took none today
-- has taken none today, and must be told so rather than shown the first-day
-- copy again.
insert into members (id, studio_id, first_name, last_name, email, status, joined_on)
values ('da58da58-0000-0000-0000-0000000000e5','da58da58-0000-0000-0000-00000000000a',
        'Ana','Onlyone','da58-a-m1@example.com','active',
        studio_today('da58da58-0000-0000-0000-00000000000a') - 200);
insert into payments (studio_id, member_id, amount_cents, currency, status, paid_at)
values ('da58da58-0000-0000-0000-00000000000a','da58da58-0000-0000-0000-0000000000e5',
        150000,'PHP','succeeded',
        ((studio_today('da58da58-0000-0000-0000-00000000000a') - 40)::timestamp at time zone 'Asia/Manila'));

set role authenticated;
select set_config('request.jwt.claim.sub','da58da58-0000-0000-0000-0000000000a1',false);
select set_config('da58.k2', dashboard_kpis('da58da58-0000-0000-0000-00000000000a')::text, false);
select expect_text('a studio that took money once shows today''s nought as a real nought',
  (select c ->> 'state' from jsonb_array_elements(current_setting('da58.k2')::jsonb -> 'cards') c
    where c ->> 'key' = 'revenue_today'), 'ok');
select expect_num('and the nought is nought',
  (select (c ->> 'value')::bigint from jsonb_array_elements(current_setting('da58.k2')::jsonb -> 'cards') c
    where c ->> 'key' = 'revenue_today'), 0);
select expect_text('while attendance, with nothing booked, is still empty rather than 0%',
  (select c ->> 'state' from jsonb_array_elements(current_setting('da58.k2')::jsonb -> 'cards') c
    where c ->> 'key' = 'attendance_today'), 'empty');

-- The forecast appears only once there is enough history, and until then the
-- absent card says how much is still needed.
select expect_num('one month of takings does not buy a forecast',
  (select count(*) from jsonb_array_elements(current_setting('da58.k2')::jsonb -> 'cards') c
    where c ->> 'key' = 'revenue_forecast'), 0);
select expect_true('and the screen says how many months it is short',
  (dashboard_absent_cards('da58da58-0000-0000-0000-00000000000a'))::text like '%You have 1.%');
reset role;

-- A percentage needs a base big enough to divide by.
select expect_null('no percentage against a prior of nothing',
  dashboard_trend(35, 0, 'last Thursday') ->> 'pct');
select expect_null('nor against a prior below the floor',
  dashboard_trend(35, 3, 'last Thursday') ->> 'pct');
select expect_num('but the change itself is always there',
  (dashboard_trend(35, 3, 'last Thursday') ->> 'delta')::bigint, 32);
select expect_num('and above the floor the percentage is real',
  (dashboard_trend(120, 100, 'the 30 days before') ->> 'pct')::bigint, 20);

\echo ''
\echo '=== 7. THE ACTION CENTRE IS DERIVED, SO IT CANNOT GO STALE ==='
set role authenticated;
select set_config('request.jwt.claim.sub','da58da58-0000-0000-0000-0000000000a1',false);
select expect_true('an unfinished studio is told what setup is left',
  (select count(*) > 0 from jsonb_array_elements(dashboard_tasks('da58da58-0000-0000-0000-00000000000a') -> 'tasks') t
    where t ->> 'key' = 'setup_incomplete'));
select expect_true('every task carries somewhere to go and something to press',
  (select bool_and(length(t ->> 'href') > 1 and length(t ->> 'action') > 1)
     from jsonb_array_elements(dashboard_tasks('da58da58-0000-0000-0000-00000000000a') -> 'tasks') t));
reset role;

-- A failed payment is urgent and is GATHERED LAST, after setup. A list whose
-- order is an accident of how it was built is one an owner reads top to bottom
-- and acts on in the wrong order.
insert into payments (studio_id, member_id, amount_cents, currency, status)
values ('da58da58-0000-0000-0000-00000000000a','da58da58-0000-0000-0000-0000000000e5',
        150000,'PHP','failed');
set role authenticated;
select set_config('request.jwt.claim.sub','da58da58-0000-0000-0000-0000000000a1',false);
select expect_num('the studio now has both an urgent task and a whenever one',
  (select count(distinct t ->> 'urgency')
     from jsonb_array_elements(dashboard_tasks('da58da58-0000-0000-0000-00000000000a') -> 'tasks') t), 2);
select expect_true('and the urgent one is ranked first, not left where it was gathered',
  (select coalesce(max(n) filter (where u = 'urgent'), 0)
        < coalesce(min(n) filter (where u <> 'urgent'), 99)
     from (select t ->> 'urgency' as u, n
             from jsonb_array_elements(dashboard_tasks('da58da58-0000-0000-0000-00000000000a') -> 'tasks')
                  with ordinality e(t, n)) z));
reset role;

-- Finish the setup, and the task leaves on its own. Nothing is ticked.
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('da58da58-0000-0000-0000-0000000000e6','da58da58-0000-0000-0000-00000000000a','da58da58-0000-0000-0000-0000000000fa','Second',8);
set role authenticated;
select set_config('request.jwt.claim.sub','da58da58-0000-0000-0000-0000000000a1',false);
select expect_num('adding a room reduces the setup count without anybody ticking anything',
  (select (t ->> 'count')::int from jsonb_array_elements(dashboard_tasks('da58da58-0000-0000-0000-00000000000a') -> 'tasks') t
    where t ->> 'key' = 'setup_incomplete')::bigint,
  (select count(*) from jsonb_each(studio_setup_state('da58da58-0000-0000-0000-00000000000a')) e(k, item)
    where (item ->> 'done')::boolean is not true
      and (item ->> 'optional')::boolean is not true
      and (item ->> 'dismissed')::boolean is not true));
reset role;

\echo ''
\echo '=== dashboard suite complete ==='
