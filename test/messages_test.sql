-- =============================================================================
-- STUDIIOR — MESSAGES TO A MEMBER (migration 022)
--
--   the draft matches the reason, sending queues and never sends, the timeline
--   learns about it once and only once, and Permissions §12 holds against a
--   caller the guard has never seen.
--
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -f test/messages_test.sql
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

create or replace function expect_like(label text, actual text, pattern text)
returns void language plpgsql as $$
begin
  if actual ilike pattern then
    raise notice 'PASS  %', label;
  else
    raise exception 'FAIL  %  expected to match %, got %', label, pattern, coalesce(actual,'null');
  end if;
end $$;

-- --- Fixtures: 3333, disjoint from every other suite --------------------------

insert into auth.users (id) values
  ('33333333-0000-0000-0000-0000000000a1'),   -- owner
  ('33333333-0000-0000-0000-0000000000a2'),   -- front desk
  ('33333333-0000-0000-0000-0000000000a3'),   -- instructor
  ('33333333-0000-0000-0000-0000000000a4');   -- owner of somewhere else
insert into profiles (id, email) values
  ('33333333-0000-0000-0000-0000000000a1','msg-owner@example.com'),
  ('33333333-0000-0000-0000-0000000000a2','msg-desk@example.com'),
  ('33333333-0000-0000-0000-0000000000a3','msg-inst@example.com'),
  ('33333333-0000-0000-0000-0000000000a4','msg-stranger@example.com');

insert into studios (id, name, slug, timezone, currency, status) values
  ('33333333-0000-0000-0000-000000000001','Message Studio','messages-test','Europe/Prague','CZK','active'),
  ('33333333-0000-0000-0000-000000000002','Elsewhere','messages-other','Europe/Prague','CZK','active');
insert into studio_settings (studio_id) values
  ('33333333-0000-0000-0000-000000000001'),('33333333-0000-0000-0000-000000000002');
insert into studio_staff (studio_id, user_id, email, role) values
  ('33333333-0000-0000-0000-000000000001','33333333-0000-0000-0000-0000000000a1','msg-owner@example.com','owner'),
  ('33333333-0000-0000-0000-000000000001','33333333-0000-0000-0000-0000000000a2','msg-desk@example.com','front_desk'),
  ('33333333-0000-0000-0000-000000000001','33333333-0000-0000-0000-0000000000a3','msg-inst@example.com','instructor'),
  ('33333333-0000-0000-0000-000000000002','33333333-0000-0000-0000-0000000000a4','msg-stranger@example.com','owner');

-- Two members whose bands fired for different reasons, because the point of
-- one draft per reason is that they do not receive the same note.
insert into members (id, studio_id, first_name, last_name, email, joined_on,
                     health_band, health_reason, health_signals, last_visit_at, marketing_opt_in)
values
  ('33333333-0000-0000-0000-00000000dd01','33333333-0000-0000-0000-000000000001',
   'Rhona','Rhythm','rhona@example.com', current_date - 200, 'at_risk',
   'Was coming about every 4 days, last visit 14 days ago.', '["rhythm_deviation"]',
   now() - interval '14 days', true),
  ('33333333-0000-0000-0000-00000000dd02','33333333-0000-0000-0000-000000000001',
   'Pavel','Payment','pavel@example.com', current_date - 300, 'at_risk',
   'Membership payment failed on 1 August.', '["payment_state"]',
   now() - interval '3 days', false);

-- =============================================================================
-- 1. The draft matches the reason
-- =============================================================================

set role authenticated;
select set_config('request.jwt.claim.sub','33333333-0000-0000-0000-0000000000a1',false);

select expect_text('a rhythm member gets the rhythm draft',
  message_draft_for('33333333-0000-0000-0000-00000000dd01') ->> 'template_key',
  'rhythm_deviation');
select expect_text('a failed payment gets the payment draft, not a we-miss-you',
  message_draft_for('33333333-0000-0000-0000-00000000dd02') ->> 'template_key',
  'payment_state');

-- The band knows "14 days"; the draft must use it without reciting it.
select expect_like('the rhythm draft speaks like a person, not a report',
  message_draft_for('33333333-0000-0000-0000-00000000dd01') ->> 'body',
  '%haven''t seen you in a couple of weeks%');
select expect_text('and it does not quote the health reason back at them',
  case when (message_draft_for('33333333-0000-0000-0000-00000000dd01') ->> 'body')
            ilike '%every 4 days%' then 'recites the reason' else 'uses it, does not recite it' end,
  'uses it, does not recite it');
select expect_like('the payment draft is about the card',
  message_draft_for('33333333-0000-0000-0000-00000000dd02') ->> 'body',
  '%didn''t go through%');
select expect_num('a failed payment is transactional, so consent does not gate it',
  ((message_draft_for('33333333-0000-0000-0000-00000000dd02') ->> 'transactional')::boolean)::int::bigint, 1);
select expect_num('a we-miss-you note is not',
  ((message_draft_for('33333333-0000-0000-0000-00000000dd01') ->> 'transactional')::boolean)::int::bigint, 0);
reset role;

-- A studio's own wording beats ours.
insert into message_templates (studio_id, key, subject, body) values
  ('33333333-0000-0000-0000-000000000001','rhythm_deviation','Ahoj {first_name}','Custom body for {first_name}.');
set role authenticated;
select set_config('request.jwt.claim.sub','33333333-0000-0000-0000-0000000000a1',false);
select expect_text('a studio template overrides the system one',
  message_draft_for('33333333-0000-0000-0000-00000000dd01') ->> 'subject', 'Ahoj Rhona');
reset role;
delete from message_templates where studio_id = '33333333-0000-0000-0000-000000000001';

-- =============================================================================
-- 2. Sending queues, and stops
-- =============================================================================

set role authenticated;
select set_config('request.jwt.claim.sub','33333333-0000-0000-0000-0000000000a1',false);

insert into messages (id, studio_id, member_id, subject, body, template_key, created_by)
values ('33333333-0000-0000-0000-00000000ff01','33333333-0000-0000-0000-000000000001',
        '33333333-0000-0000-0000-00000000dd01','Missing you','Hi Rhona — edited by hand.',
        'rhythm_deviation','33333333-0000-0000-0000-0000000000a1');

select expect_text('a new message starts as a draft',
  (select status::text from messages where id='33333333-0000-0000-0000-00000000ff01'), 'draft');
select expect_text('sending queues it',
  (send_message('33333333-0000-0000-0000-00000000ff01')).status::text, 'queued');
select expect_text('and nothing claims it was sent',
  coalesce((select sent_at::text from messages where id='33333333-0000-0000-0000-00000000ff01'), '<null>'),
  '<null>');

do $$
begin
  perform send_message('33333333-0000-0000-0000-00000000ff01');
  raise exception 'FAIL  a queued message was sent a second time';
exception when sqlstate 'PT409' then
  raise notice 'PASS  a message cannot be sent twice';
end $$;
reset role;

select expect_text('the body that was queued is the body that was written',
  (select body from messages where id='33333333-0000-0000-0000-00000000ff01'),
  'Hi Rhona — edited by hand.');

-- =============================================================================
-- 3. The timeline learns about it once
-- =============================================================================

select expect_num('sending puts one event on the journey',
  (select count(*) from timeline_events
    where member_id='33333333-0000-0000-0000-00000000dd01' and type='message_sent'), 1);
select expect_text('and it carries the subject, so the journey says what was said',
  (select description from timeline_events
    where member_id='33333333-0000-0000-0000-00000000dd01' and type='message_sent'),
  'Missing you');

set role authenticated;
select set_config('request.jwt.claim.sub','33333333-0000-0000-0000-0000000000a1',false);
-- Two statements, not two arguments: inside one select the count is free to be
-- evaluated before the rebuild it is meant to be checking, and the first
-- version of this assertion compared a before to an after and called it a bug.
select set_config('m.rebuilt',
  rebuild_member_timeline('33333333-0000-0000-0000-00000000dd01')::text, false);
select expect_num('a rebuild returns the count it actually wrote',
  current_setting('m.rebuilt')::bigint,
  (select count(*) from timeline_events where member_id='33333333-0000-0000-0000-00000000dd01'));
reset role;
select expect_num('exactly one after rebuilding',
  (select count(*) from timeline_events
    where member_id='33333333-0000-0000-0000-00000000dd01' and type='message_sent'), 1);

set role authenticated;
select set_config('request.jwt.claim.sub','33333333-0000-0000-0000-0000000000a1',false);
select set_config('m.rebuilt2',
  rebuild_member_timeline('33333333-0000-0000-0000-00000000dd01')::text, false);
select expect_num('rebuilding twice does not double it',
  current_setting('m.rebuilt2')::bigint,
  (select count(*) from timeline_events where member_id='33333333-0000-0000-0000-00000000dd01'));
reset role;
select expect_num('still exactly one',
  (select count(*) from timeline_events
    where member_id='33333333-0000-0000-0000-00000000dd01' and type='message_sent'), 1);

-- A draft is not an event.
insert into messages (id, studio_id, member_id, subject, body, created_by)
values ('33333333-0000-0000-0000-00000000ff02','33333333-0000-0000-0000-000000000001',
        '33333333-0000-0000-0000-00000000dd01','Unsent draft','Never sent.',
        '33333333-0000-0000-0000-0000000000a1');
set role authenticated;
select set_config('request.jwt.claim.sub','33333333-0000-0000-0000-0000000000a1',false);
select set_config('m.rebuilt3',
  rebuild_member_timeline('33333333-0000-0000-0000-00000000dd01')::text, false);
select expect_num('an unsent draft rebuilds to nothing',
  current_setting('m.rebuilt3')::bigint,
  (select count(*) from timeline_events where member_id='33333333-0000-0000-0000-00000000dd01'));
reset role;
select expect_num('and there is still only one message event',
  (select count(*) from timeline_events
    where member_id='33333333-0000-0000-0000-00000000dd01' and type='message_sent'), 1);

-- =============================================================================
-- 4. Permissions §12 — front desk yes, instructor never, stranger never
-- =============================================================================

set role authenticated;
select set_config('request.jwt.claim.sub','33333333-0000-0000-0000-0000000000a2',false);  -- front desk
select expect_text('front desk may compose — §12 gives them this',
  message_draft_for('33333333-0000-0000-0000-00000000dd01') ->> 'template_key', 'rhythm_deviation');
insert into messages (id, studio_id, member_id, subject, body, created_by)
values ('33333333-0000-0000-0000-00000000ff03','33333333-0000-0000-0000-000000000001',
        '33333333-0000-0000-0000-00000000dd02','From the desk','Your card did not go through.',
        '33333333-0000-0000-0000-0000000000a2');
select expect_text('and front desk may send',
  (send_message('33333333-0000-0000-0000-00000000ff03')).status::text, 'queued');

select set_config('request.jwt.claim.sub','33333333-0000-0000-0000-0000000000a3',false);  -- instructor
select expect_num('an instructor cannot even see a message',
  (select count(*) from messages), 0);
do $$
begin
  perform message_draft_for('33333333-0000-0000-0000-00000000dd01');
  raise exception 'FAIL  an instructor composed a message';
exception when sqlstate 'PT403' then
  raise notice 'PASS  an instructor cannot compose a message';
end $$;
do $$
begin
  perform send_message('33333333-0000-0000-0000-00000000ff02');
  raise exception 'FAIL  an instructor sent a message';
exception when sqlstate 'PT403' then
  raise notice 'PASS  an instructor cannot send a message';
end $$;

-- The caller migration 020 exists for: real staff, of a different studio, so
-- auth_role_in() has nothing to say about this one.
select set_config('request.jwt.claim.sub','33333333-0000-0000-0000-0000000000a4',false);
select expect_text('a stranger is not desk-up here',
  is_desk_up('33333333-0000-0000-0000-000000000001')::text, 'false');
do $$
begin
  perform message_draft_for('33333333-0000-0000-0000-00000000dd01');
  raise exception 'FAIL  an outsider composed a message to another studio''s member';
exception when sqlstate 'PT403' then
  raise notice 'PASS  an outsider cannot compose to another studio''s member';
end $$;
do $$
begin
  perform send_message('33333333-0000-0000-0000-00000000ff02');
  raise exception 'FAIL  an outsider sent another studio''s message';
exception when sqlstate 'PT403' then
  raise notice 'PASS  an outsider cannot send another studio''s message';
end $$;
select expect_num('and cannot see the messages either',
  (select count(*) from messages), 0);
reset role;

select expect_num('the drafts and queued messages are all still there',
  (select count(*) from messages), 3);

-- =============================================================================
-- 5. Nothing sends itself — Business Rules §11
-- =============================================================================

select expect_num('no message has ever been marked sent',
  (select count(*) from messages where status = 'sent'), 0);
select expect_num('and nothing is queued that nobody wrote',
  (select count(*) from messages where created_by is null), 0);
select expect_num('email is the only channel that exists',
  (select count(*) from messages where channel <> 'email'), 0);

select 'ALL MESSAGE TESTS PASSED' as result;
