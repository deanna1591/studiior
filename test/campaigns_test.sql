-- =============================================================================
-- Decision 50 — email campaigns: audience, send, unsubscribe, consent.
-- =============================================================================
-- UUID space ca50, checked free. Run after `supabase db reset`.
--
-- SA (Prague) carries members across consent states and plan/health bands; SB
-- proves no cross-studio leak. Campaigns are manager-up; the audience is
-- consent-gated; the unsubscribe is anon (the thirteenth anon surface).
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'BAD  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual then raise notice 'PASS  %', label;
  else raise exception 'BAD  %  expected true, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_txt(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (%)', label, coalesce(actual,'null');
  else raise exception 'BAD  %  expected "%", got "%"', label, want, coalesce(actual,'null'); end if;
end $$;
create or replace function expect_raises(label text, stmt text, want_sqlstate text)
returns void language plpgsql as $$
begin
  execute stmt; raise exception 'BAD  %  expected % but nothing was raised', label, want_sqlstate;
exception when others then
  if sqlstate = want_sqlstate then raise notice 'PASS  %  (got %)', label, sqlstate;
  elsif sqlstate = 'P0001' and sqlerrm like 'BAD%' then raise;
  else raise exception 'BAD  %  expected %, got % (%)', label, want_sqlstate, sqlstate, sqlerrm; end if;
end $$;

-- --- Fixtures: two studios, SA with owner/front-desk/instructor --------------
insert into studios (id, name, slug, timezone, currency, status) values
  ('ca50ca50-0000-0000-0000-0000000000a1','Camp A','ca50-sa','Europe/Prague','CZK','active'),
  ('ca50ca50-0000-0000-0000-0000000000b1','Camp B','ca50-sb','Europe/Prague','CZK','active');
insert into studio_settings (studio_id, require_waiver) values
  ('ca50ca50-0000-0000-0000-0000000000a1', false),
  ('ca50ca50-0000-0000-0000-0000000000b1', false);
insert into locations (id, studio_id, name, is_primary) values
  ('ca50ca50-0000-0000-0000-0000000000aa','ca50ca50-0000-0000-0000-0000000000a1','Main',true);
insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits_per_period, billing_interval) values
  ('ca50ca50-0000-0000-0000-00000000a1a1','ca50ca50-0000-0000-0000-0000000000a1','Unlimited','recurring',300000,'CZK',null,'month');

insert into auth.users (id) values
  ('ca50ca50-0000-0000-0000-0000000000f1'),
  ('ca50ca50-0000-0000-0000-0000000000f2'),
  ('ca50ca50-0000-0000-0000-0000000000f3');
insert into profiles (id, email, full_name) values
  ('ca50ca50-0000-0000-0000-0000000000f1','ca50-owner@example.com','Olive Owner'),
  ('ca50ca50-0000-0000-0000-0000000000f2','ca50-desk@example.com','Dana Desk'),
  ('ca50ca50-0000-0000-0000-0000000000f3','ca50-inst@example.com','Ira Instructor');
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('ca50ca50-0000-0000-0000-00000005f001','ca50ca50-0000-0000-0000-0000000000a1','ca50ca50-0000-0000-0000-0000000000f1','ca50-owner@example.com','owner'),
  ('ca50ca50-0000-0000-0000-00000005f002','ca50ca50-0000-0000-0000-0000000000a1','ca50ca50-0000-0000-0000-0000000000f2','ca50-desk@example.com','front_desk'),
  ('ca50ca50-0000-0000-0000-00000005f003','ca50ca50-0000-0000-0000-0000000000a1','ca50ca50-0000-0000-0000-0000000000f3','ca50-inst@example.com','instructor');

-- Members. All SA unless noted; opted in with an email unless noted.
-- A1 on a plan, healthy, joined today      -> a recipient
-- A2 no plan, drifting, joined 100 days ago -> a recipient
-- A3 on a plan, healthy, joined today, OPTED OUT  -> excluded by consent
-- A4 opted in but UNSUBSCRIBED (stamped)          -> excluded
-- A5 ARCHIVED                                      -> excluded
-- A6 opted in but NO email ('')                    -> excluded
-- B1 another studio                                -> never in SA's audience
insert into members (id, studio_id, email, first_name, last_name, status, marketing_opt_in, health_band, joined_on, marketing_unsubscribed_at, archived_at) values
  ('ca50ca50-0000-0000-0000-0000000e0001','ca50ca50-0000-0000-0000-0000000000a1','a1@example.com','Aa','One','active',   true,  'healthy',  current_date,        null, null),
  ('ca50ca50-0000-0000-0000-0000000e0002','ca50ca50-0000-0000-0000-0000000000a1','a2@example.com','Ab','Two','active',   true,  'drifting', current_date - 100,  null, null),
  ('ca50ca50-0000-0000-0000-0000000e0003','ca50ca50-0000-0000-0000-0000000000a1','a3@example.com','Ac','Three','active', false, 'healthy',  current_date,        null, null),
  ('ca50ca50-0000-0000-0000-0000000e0004','ca50ca50-0000-0000-0000-0000000000a1','a4@example.com','Ad','Four','active',  true,  'healthy',  current_date,        now(), null),
  ('ca50ca50-0000-0000-0000-0000000e0005','ca50ca50-0000-0000-0000-0000000000a1','a5@example.com','Ae','Five','active',  true,  'healthy',  current_date,        null, now()),
  ('ca50ca50-0000-0000-0000-0000000e0006','ca50ca50-0000-0000-0000-0000000000a1','',              'Af','Six','active',   true,  'healthy',  current_date,        null, null),
  ('ca50ca50-0000-0000-0000-0000000e00b1','ca50ca50-0000-0000-0000-0000000000b1','b1@example.com','Ba','One','active',   true,  'healthy',  current_date,        null, null);

-- A1 and A3 each on an active recurring membership -> plan_state on_plan.
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on) values
  ('ca50ca50-0000-0000-0000-00000000ad01','ca50ca50-0000-0000-0000-0000000000a1','ca50ca50-0000-0000-0000-0000000e0001','ca50ca50-0000-0000-0000-00000000a1a1','active',300000,'CZK',current_date),
  ('ca50ca50-0000-0000-0000-00000000ad03','ca50ca50-0000-0000-0000-0000000000a1','ca50ca50-0000-0000-0000-0000000e0003','ca50ca50-0000-0000-0000-00000000a1a1','active',300000,'CZK',current_date);

-- Campaign fixtures (inserted as the test superuser; RLS bypassed for setup).
insert into campaigns (id, studio_id, subject, body, audience, status) values
  ('ca50ca50-0000-0000-0000-0000000c0001','ca50ca50-0000-0000-0000-0000000000a1','Hello there','Line one.\n\nLine two.','{}','draft'),
  ('ca50ca50-0000-0000-0000-0000000c0002','ca50ca50-0000-0000-0000-0000000000a1','See you soon','Scheduled body.','{}','draft'),
  ('ca50ca50-0000-0000-0000-0000000c0003','ca50ca50-0000-0000-0000-0000000000a1','Nobody home','x','{"health":"at_risk"}','draft'),
  ('ca50ca50-0000-0000-0000-0000000c0004','ca50ca50-0000-0000-0000-0000000000a1','Blank','','{}','draft'),
  ('ca50ca50-0000-0000-0000-0000000c0005','ca50ca50-0000-0000-0000-0000000000a1','Test me','Test body.','{}','draft');

-- =============================================================================
-- A. RLS — manager-up on both tables; front desk and instructor see nothing.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','ca50ca50-0000-0000-0000-0000000000f1',false);
select expect_true('owner sees the studio campaigns',
  (select count(*) = 5 from campaigns where studio_id='ca50ca50-0000-0000-0000-0000000000a1'));
reset role;

set role authenticated;
select set_config('request.jwt.claim.sub','ca50ca50-0000-0000-0000-0000000000f2',false);
select expect_num('front desk sees no campaigns (RLS)',
  (select count(*) from campaigns)::bigint, 0);
select expect_num('front desk sees no campaign_recipients (RLS)',
  (select count(*) from campaign_recipients)::bigint, 0);
select expect_raises('front desk cannot create a campaign (RLS with check)',
  $$ insert into campaigns (studio_id, subject, body) values ('ca50ca50-0000-0000-0000-0000000000a1','x','y') $$, '42501');
reset role;

set role authenticated;
select set_config('request.jwt.claim.sub','ca50ca50-0000-0000-0000-0000000000f3',false);
select expect_num('instructor sees no campaigns (RLS)',
  (select count(*) from campaigns)::bigint, 0);
reset role;

-- =============================================================================
-- B. campaign_audience — the filters AND the consent gate.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','ca50ca50-0000-0000-0000-0000000000f1',false);

-- No filter: A1 + A2 only (A3 opted out, A4 unsubscribed, A5 archived, A6 no email).
select expect_num('audience {}: only the two opted-in, emailable, non-archived',
  (select count(*) from campaign_audience('ca50ca50-0000-0000-0000-0000000000a1','{}'::jsonb))::bigint, 2);
select expect_num('audience {}: the opted-out member matching every filter is excluded',
  (select count(*) from campaign_audience('ca50ca50-0000-0000-0000-0000000000a1','{}'::jsonb)
     where member_id='ca50ca50-0000-0000-0000-0000000e0003')::bigint, 0);
select expect_num('audience {}: the archived member is excluded',
  (select count(*) from campaign_audience('ca50ca50-0000-0000-0000-0000000000a1','{}'::jsonb)
     where member_id='ca50ca50-0000-0000-0000-0000000e0005')::bigint, 0);
select expect_num('audience {}: no SB member leaks in',
  (select count(*) from campaign_audience('ca50ca50-0000-0000-0000-0000000000a1','{}'::jsonb)
     where member_id='ca50ca50-0000-0000-0000-0000000e00b1')::bigint, 0);
-- plan_state filter: on_plan -> A1 only (A3 on_plan but opted out).
select expect_num('audience plan_state=on_plan -> A1 only',
  (select count(*) from campaign_audience('ca50ca50-0000-0000-0000-0000000000a1','{"plan_state":"on_plan"}'::jsonb))::bigint, 1);
select expect_txt('audience plan_state=on_plan names A1',
  (select member_id::text from campaign_audience('ca50ca50-0000-0000-0000-0000000000a1','{"plan_state":"on_plan"}'::jsonb)),
  'ca50ca50-0000-0000-0000-0000000e0001');
select expect_num('audience plan_state=none -> A2 only',
  (select count(*) from campaign_audience('ca50ca50-0000-0000-0000-0000000000a1','{"plan_state":"none"}'::jsonb))::bigint, 1);
-- health filter.
select expect_num('audience health=drifting -> A2 only',
  (select count(*) from campaign_audience('ca50ca50-0000-0000-0000-0000000000a1','{"health":"drifting"}'::jsonb))::bigint, 1);
-- joined_days filter: last 7 days -> A1 (today), not A2 (100 days ago).
select expect_num('audience joined_days=7 -> A1 only',
  (select count(*) from campaign_audience('ca50ca50-0000-0000-0000-0000000000a1','{"joined_days":7}'::jsonb))::bigint, 1);
select expect_txt('audience joined_days=7 names A1',
  (select member_id::text from campaign_audience('ca50ca50-0000-0000-0000-0000000000a1','{"joined_days":7}'::jsonb)),
  'ca50ca50-0000-0000-0000-0000000e0001');
reset role;

-- front desk / SB owner guards on the reader.
set role authenticated;
select set_config('request.jwt.claim.sub','ca50ca50-0000-0000-0000-0000000000f2',false);
select expect_raises('front desk PT403 on campaign_audience',
  $$ select * from campaign_audience('ca50ca50-0000-0000-0000-0000000000a1','{}'::jsonb) $$, 'PT403');
reset role;

-- =============================================================================
-- C. send_campaign — rows, dedupe, status, sentence, refusals.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','ca50ca50-0000-0000-0000-0000000000f1',false);

-- Send now: 2 recipients, status sending, exact sentence.
select expect_txt('send now sentence',
  (send_campaign('ca50ca50-0000-0000-0000-0000000c0001') ->> 'sentence'), 'Sending to 2 members.');
select expect_num('send now: 2 campaign_recipients',
  (select count(*) from campaign_recipients where campaign_id='ca50ca50-0000-0000-0000-0000000c0001')::bigint, 2);
select expect_num('send now: 2 notifications with template campaign',
  (select count(*) from notifications where template_key='campaign'
     and dedupe_key like 'campaign:ca50ca50-0000-0000-0000-0000000c0001:%')::bigint, 2);
select expect_true('send now: payload carries the unsubscribe_url',
  (select bool_and(payload ? 'unsubscribe_url' and (payload->>'unsubscribe_url') like '%/unsubscribe/%')
     from notifications where dedupe_key like 'campaign:ca50ca50-0000-0000-0000-0000000c0001:%'));
select expect_txt('send now: campaign is sending',
  (select status from campaigns where id='ca50ca50-0000-0000-0000-0000000c0001'), 'sending');
select expect_num('send now: recipient_count 2',
  (select recipient_count from campaigns where id='ca50ca50-0000-0000-0000-0000000c0001')::bigint, 2);

-- Schedule for the future: status scheduled + scheduled_for set.
select expect_true('schedule sentence starts "Scheduled for"',
  (send_campaign('ca50ca50-0000-0000-0000-0000000c0002', now() + interval '1 day') ->> 'sentence') like 'Scheduled for %to 2 members.');
select expect_txt('scheduled: campaign is scheduled',
  (select status from campaigns where id='ca50ca50-0000-0000-0000-0000000c0002'), 'scheduled');
select expect_true('scheduled: scheduled_for is in the future',
  (select scheduled_for > now() from campaigns where id='ca50ca50-0000-0000-0000-0000000c0002'));

-- Zero audience -> PT409.
select expect_raises('zero audience PT409',
  $$ select send_campaign('ca50ca50-0000-0000-0000-0000000c0003') $$, 'PT409');
-- Blank body -> PT400.
select expect_raises('blank body PT400',
  $$ select send_campaign('ca50ca50-0000-0000-0000-0000000c0004') $$, 'PT400');
-- Already sent -> PT409.
select expect_raises('already sent PT409',
  $$ select send_campaign('ca50ca50-0000-0000-0000-0000000c0001') $$, 'PT409');
reset role;

-- =============================================================================
-- D. send_campaign_test — one row to the caller, campaign untouched.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','ca50ca50-0000-0000-0000-0000000000f1',false);
select expect_true('test send sentence names the owner email',
  (send_campaign_test('ca50ca50-0000-0000-0000-0000000c0005') ->> 'sentence') = 'Sent a test to ca50-owner@example.com.');
select expect_num('test: exactly one notification to the owner',
  (select count(*) from notifications where template_key='campaign'
     and payload->>'to_email'='ca50-owner@example.com' and payload->>'subject' like '[Test]%')::bigint, 1);
select expect_txt('test: the campaign stays a draft',
  (select status from campaigns where id='ca50ca50-0000-0000-0000-0000000c0005'), 'draft');
select expect_num('test: no campaign_recipients were written',
  (select count(*) from campaign_recipients where campaign_id='ca50ca50-0000-0000-0000-0000000c0005')::bigint, 0);
reset role;

-- =============================================================================
-- E. cancel_campaign — cancels the scheduled rows, refuses after send.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','ca50ca50-0000-0000-0000-0000000000f1',false);
select expect_true('cancel the scheduled campaign',
  (cancel_campaign('ca50ca50-0000-0000-0000-0000000c0002') ->> 'ok')::boolean);
select expect_txt('cancelled: campaign status',
  (select status from campaigns where id='ca50ca50-0000-0000-0000-0000000c0002'), 'cancelled');
select expect_num('cancelled: its notifications are cancelled',
  (select count(*) from notifications where dedupe_key like 'campaign:ca50ca50-0000-0000-0000-0000000c0002:%'
     and status='cancelled')::bigint, 2);
-- a sent (sending) campaign cannot be cancelled.
select expect_raises('cancel after send PT409',
  $$ select cancel_campaign('ca50ca50-0000-0000-0000-0000000c0001') $$, 'PT409');
reset role;

-- =============================================================================
-- F. campaign_status — flips sending -> sent when nothing is pending.
-- =============================================================================
-- Simulate the worker marking CMP_SEND's rows sent (as the superuser).
update notifications set status='sent', sent_at=now()
 where dedupe_key like 'campaign:ca50ca50-0000-0000-0000-0000000c0001:%';
set role authenticated;
select set_config('request.jwt.claim.sub','ca50ca50-0000-0000-0000-0000000000f1',false);
select expect_txt('campaign_status flips sending -> sent',
  (campaign_status('ca50ca50-0000-0000-0000-0000000c0001') ->> 'status'), 'sent');
select expect_num('campaign_status: sent = 2',
  (campaign_status('ca50ca50-0000-0000-0000-0000000c0001') ->> 'sent')::bigint, 2);
select expect_num('campaign_status: pending = 0',
  (campaign_status('ca50ca50-0000-0000-0000-0000000c0001') ->> 'pending')::bigint, 0);
select expect_true('campaign_status set sent_at',
  (select sent_at is not null from campaigns where id='ca50ca50-0000-0000-0000-0000000c0001'));
reset role;

-- =============================================================================
-- G. unsubscribe_marketing — the anon one-tap, consent off, audit, idempotent.
-- =============================================================================
-- Resolve A1's token as the superuser (anon cannot read members), then call as
-- the signed-out recipient would.
reset role;
select set_config('t.tok', (select marketing_token::text from members where id='ca50ca50-0000-0000-0000-0000000e0001'), false);
set role anon;
-- ONE call, capturing both columns: the studio name only, and already = false.
select expect_txt('unsubscribe returns the studio name only', r.studio_name, 'Camp A'),
       expect_true('first unsubscribe: already = false', r.already = false)
  from unsubscribe_marketing(current_setting('t.tok')::uuid) r;
reset role;
-- opt_in is now false, stamped; exactly one audit row (so far).
select expect_true('A1 marketing_opt_in is now false',
  (select not marketing_opt_in from members where id='ca50ca50-0000-0000-0000-0000000e0001'));
select expect_true('A1 marketing_unsubscribed_at is stamped',
  (select marketing_unsubscribed_at is not null from members where id='ca50ca50-0000-0000-0000-0000000e0001'));
select expect_num('an unsubscribe audit row was written',
  (select count(*) from audit_logs where action='member.marketing_unsubscribed'
     and entity_id='ca50ca50-0000-0000-0000-0000000e0001')::bigint, 1);
-- second call: already = true (the stamp is kept, not overwritten).
set role anon;
select expect_true('unsubscribe second time: already = true',
  (select already from unsubscribe_marketing(current_setting('t.tok')::uuid)));
-- unknown token -> PT404.
select expect_raises('unknown token PT404',
  $$ select * from unsubscribe_marketing('ca50ca50-dead-dead-dead-dead00000000'::uuid) $$, 'PT404');
reset role;

-- =============================================================================
-- H. Consent re-checked at send time, and the campaign From domain.
-- =============================================================================
-- A2 unsubscribes AFTER scheduling -> notification_wanted('campaign') is false,
-- which is exactly what deliver_notification consults at send time.
update members set marketing_opt_in=false, marketing_unsubscribed_at=now()
 where id='ca50ca50-0000-0000-0000-0000000e0002';
select expect_true('unsubscribed member is no longer wanted for a campaign',
  notification_wanted('ca50ca50-0000-0000-0000-0000000e0002','campaign') = false);
select expect_true('a still-consented member is wanted for a campaign',
  notification_wanted('ca50ca50-0000-0000-0000-0000000e00b1','campaign') = true);

-- From domain: campaign uses marketing_from_domain, booking uses from_domain.
update notification_config set value='mail.campaign.test' where key='marketing_from_domain';
select expect_txt('campaign envelope domain = marketing_from_domain',
  notification_envelope_domain('campaign'), 'mail.campaign.test');
select expect_txt('booking envelope domain = from_domain',
  notification_envelope_domain('booking_confirmed'), 'studiior.app');

-- =============================================================================
-- I. The anon surface is EXACTLY THIRTEEN, naming unsubscribe_marketing.
-- =============================================================================
select expect_num('anon surface is exactly thirteen (suite helpers excluded)',
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not like 'expect\_%')::bigint, 13);
select expect_true('unsubscribe_marketing is anon-executable',
  has_function_privilege('anon', 'unsubscribe_marketing(uuid)'::regprocedure, 'execute'));

select 'campaigns_test: all assertions passed' as result;
