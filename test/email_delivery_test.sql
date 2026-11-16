-- Decision 113 (delivery: throttle, retry, 422, bounce, complaint, re-queue)
-- + Decision 114 (marketing consent + backfill). UUID space e113.
\set ON_ERROR_STOP on
set client_min_messages to warning;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$ begin
  if actual is distinct from want then raise exception 'BAD  %  expected %, got %', label, want, actual;
  else raise notice 'PASS  %  (got %)', label, actual; end if; end $$;
create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$ begin
  if actual is distinct from want then raise exception 'BAD  %  expected %, got %', label, want, actual;
  else raise notice 'PASS  %  (got %)', label, actual; end if; end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$ begin
  if actual is not true then raise exception 'BAD  %  expected true, got %', label, actual;
  else raise notice 'PASS  %', label; end if; end $$;
create or replace function expect_false(label text, actual boolean)
returns void language plpgsql as $$ begin
  if actual is distinct from false then raise exception 'BAD  %  expected false, got %', label, actual;
  else raise notice 'PASS  %', label; end if; end $$;
create or replace function expect_raise(label text, code text, sql text)
returns void language plpgsql as $$ declare got text; begin
  execute sql; raise exception 'BAD  %  expected % but nothing raised', label, code;
exception when others then
  if sqlstate = code then raise notice 'PASS  %  (%).', label, code;
  elsif sqlstate like 'PT%' or sqlstate in ('42501','23505') then
    raise exception 'BAD  %  expected %, got %', label, code, sqlstate;
  else raise notice 'PASS  %  (%).', label, sqlstate; end if; end $$;

-- helper: fabricate a provider response and point a sending notification at it
create or replace function fake_resp(p_id bigint, p_code int, p_body text, p_headers jsonb default '{}')
returns void language sql as $$
  insert into net._http_response (id, status_code, content, headers, timed_out, created)
  values (p_id, p_code, p_body, coalesce(p_headers,'{}'::jsonb), false, now());
$$;

-- ============ fixtures ============
insert into studios (id, slug, name, timezone, currency, country, status)
values ('e1130000-0000-0000-0000-000000000001','e113-sa','Delivery SA','Europe/Prague','CZK','CZ','active');
insert into studio_settings (studio_id) values ('e1130000-0000-0000-0000-000000000001');

-- members: M1 valid (with a login for consent), M2 for complaint, MB for bounce,
-- and the re-queue / backfill cohort.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
values ('e1130000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-000000000000','authenticated','authenticated',
        'm1@example.com', crypt('x', gen_salt('bf')), now(), now(), now());
insert into profiles (id, email, full_name) values ('e1130000-0000-0000-0000-0000000000a1','m1@example.com','M One');

insert into members (id, studio_id, first_name, last_name, email, status, user_id, marketing_opt_in, marketing_unsubscribed_at)
values
 ('e1130000-0000-0000-0000-000000000011','e1130000-0000-0000-0000-000000000001','M','One','m1@example.com','active','e1130000-0000-0000-0000-0000000000a1', false, null),
 ('e1130000-0000-0000-0000-000000000012','e1130000-0000-0000-0000-000000000001','M','Two','m2@example.com','active', null, true, null),
 ('e1130000-0000-0000-0000-000000000013','e1130000-0000-0000-0000-000000000001','M','Bounce','mb@example.com','active', null, true, null),
 -- re-queue cohort
 ('e1130000-0000-0000-0000-000000000021','e1130000-0000-0000-0000-000000000001','U','Nconv','u1@example.com','lead', null, true, null),  -- unconverted
 ('e1130000-0000-0000-0000-000000000022','e1130000-0000-0000-0000-000000000001','C','Onv','u2@example.com','active', null, true, null),   -- converted (has membership)
 ('e1130000-0000-0000-0000-000000000023','e1130000-0000-0000-0000-000000000001','D','Rift','u3@example.com','active', null, true, null),   -- drifting
 ('e1130000-0000-0000-0000-000000000024','e1130000-0000-0000-0000-000000000001','N','Obook','u4@example.com','lead', null, true, null),    -- no booking
 -- backfill cohort
 ('e1130000-0000-0000-0000-000000000031','e1130000-0000-0000-0000-000000000001','B','Flip','b1@example.com','active', null, false, null),  -- opt_in false, unsub null -> flips
 ('e1130000-0000-0000-0000-000000000032','e1130000-0000-0000-0000-000000000001','B','Unsub','b2@example.com','active', null, false, now()), -- unsubscribed -> not flipped
 ('e1130000-0000-0000-0000-000000000033','e1130000-0000-0000-0000-000000000001','B','Yes','b3@example.com','active', null, true, null);    -- already in -> no change

update members set health_band = 'drifting' where id = 'e1130000-0000-0000-0000-000000000023';

-- a plan + membership so U2 is "converted", and a booking so Nobook/U1 differ
insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, status, visibility)
values ('e1130000-0000-0000-0000-0000000000f1','e1130000-0000-0000-0000-000000000001','Pack','class_pack',100000,'CZK',10,'active','public');
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on)
values ('e1130000-0000-0000-0000-0000000000f2','e1130000-0000-0000-0000-000000000001','e1130000-0000-0000-0000-000000000022','e1130000-0000-0000-0000-0000000000f1','active',100000,'CZK', current_date);

-- a location + room + class + a booking for U1 (unconverted but HAS booked, so convert_book_first excludes it)
insert into locations (id, studio_id, name) values ('e1130000-0000-0000-0000-0000000000a0','e1130000-0000-0000-0000-000000000001','Main');
insert into rooms (id, studio_id, location_id, name, capacity) values ('e1130000-0000-0000-0000-0000000000e1','e1130000-0000-0000-0000-000000000001','e1130000-0000-0000-0000-0000000000a0','R',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values ('e1130000-0000-0000-0000-0000000000c1','e1130000-0000-0000-0000-000000000001','C',50,10);
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name, starts_at, ends_at, capacity, status)
values ('e1130000-0000-0000-0000-0000000000d1','e1130000-0000-0000-0000-000000000001','e1130000-0000-0000-0000-0000000000a0','e1130000-0000-0000-0000-0000000000c1','e1130000-0000-0000-0000-0000000000e1','C', now()+interval '2 day', now()+interval '2 day' + interval '50 min', 10, 'scheduled');
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source)
values ('e1130000-0000-0000-0000-0000000000b1','e1130000-0000-0000-0000-000000000001','e1130000-0000-0000-0000-0000000000d1','e1130000-0000-0000-0000-000000000021','booked','member','drop_in');

\echo '==== 1. retry on 429 (reschedule with backoff, then marked failed at the max) ===='
-- a sending row on its first attempt, 429 rate-limit
insert into notifications (id, studio_id, member_id, recipient_type, template_key, channel, payload, dedupe_key, scheduled_for, status, attempts, net_request_id)
values ('e1130000-0000-0000-0000-000000000101','e1130000-0000-0000-0000-000000000001','e1130000-0000-0000-0000-000000000011','member','convert_day3','email','{}','d3:101', now()-interval '1 min','sending',1, 900001);
select fake_resp(900001, 429, '{"message":"Too many requests. 30 per second.","name":"rate_limit_exceeded"}');
select reconcile_notification_sends();
select expect_text('a 429 reschedules, not fails', (select status::text from notifications where id='e1130000-0000-0000-0000-000000000101'), 'scheduled');
select expect_true('attempt 1 backs off ~1 minute', (select scheduled_for between now()+interval '55 sec' and now()+interval '65 sec' from notifications where id='e1130000-0000-0000-0000-000000000101'));
select expect_true('next_attempt_at is stamped', (select next_attempt_at is not null from notifications where id='e1130000-0000-0000-0000-000000000101'));

-- jump to the 5th attempt -> ~240 minutes
update notifications set status='sending', attempts=5, net_request_id=900005 where id='e1130000-0000-0000-0000-000000000101';
select fake_resp(900005, 429, '{"name":"rate_limit_exceeded"}');
select reconcile_notification_sends();
select expect_true('attempt 5 backs off ~240 minutes', (select scheduled_for between now()+interval '239 min' and now()+interval '241 min' from notifications where id='e1130000-0000-0000-0000-000000000101'));

-- the 6th attempt exhausts -> failed
update notifications set status='sending', attempts=6, net_request_id=900006 where id='e1130000-0000-0000-0000-000000000101';
select fake_resp(900006, 429, '{"name":"rate_limit_exceeded"}');
select reconcile_notification_sends();
select expect_text('the sixth attempt is terminal failed', (select status::text from notifications where id='e1130000-0000-0000-0000-000000000101'), 'failed');

\echo '==== 2. a retry-after header wins over the backoff ===='
insert into notifications (id, studio_id, member_id, recipient_type, template_key, channel, payload, dedupe_key, scheduled_for, status, attempts, net_request_id)
values ('e1130000-0000-0000-0000-000000000102','e1130000-0000-0000-0000-000000000001','e1130000-0000-0000-0000-000000000011','member','convert_day7','email','{}','d7:102', now(),'sending',1, 900010);
select fake_resp(900010, 429, '{"name":"rate_limit_exceeded"}', '{"retry-after":"30"}');
select reconcile_notification_sends();
select expect_true('retry-after 30s is honoured', (select scheduled_for between now()+interval '25 sec' and now()+interval '35 sec' from notifications where id='e1130000-0000-0000-0000-000000000102'));

\echo '==== 3. a 422 fails at once and marks the address invalid ===='
insert into notifications (id, studio_id, member_id, recipient_type, template_key, channel, payload, dedupe_key, scheduled_for, status, attempts, net_request_id)
values ('e1130000-0000-0000-0000-000000000103','e1130000-0000-0000-0000-000000000001','e1130000-0000-0000-0000-000000000012','member','convert_last_day','email','{}','ld:103', now(),'sending',1, 900020);
select fake_resp(900020, 422, '{"message":"Invalid `to` field.","name":"validation_error"}');
select reconcile_notification_sends();
select expect_text('422 is terminal failed', (select status::text from notifications where id='e1130000-0000-0000-0000-000000000103'), 'failed');
select expect_text('and the member email is marked invalid', (select email_status from members where id='e1130000-0000-0000-0000-000000000012'), 'invalid');

\echo '==== 4. a quota 429 is not retried ===='
-- reset M2 so a fresh send is possible
update members set email_status='valid' where id='e1130000-0000-0000-0000-000000000012';
insert into notifications (id, studio_id, member_id, recipient_type, template_key, channel, payload, dedupe_key, scheduled_for, status, attempts, net_request_id)
values ('e1130000-0000-0000-0000-000000000104','e1130000-0000-0000-0000-000000000001','e1130000-0000-0000-0000-000000000012','member','convert_day3','email','{}','d3:104', now(),'sending',1, 900030);
select fake_resp(900030, 429, '{"message":"daily_quota_exceeded","name":"daily_quota_exceeded"}');
select reconcile_notification_sends();
select expect_text('a quota 429 is terminal failed, not rescheduled', (select status::text from notifications where id='e1130000-0000-0000-0000-000000000104'), 'failed');

\echo '==== 5. a bounce webhook stops further sends ===='
-- a sent notification with a provider message id, to MB
insert into notifications (id, studio_id, member_id, recipient_type, template_key, channel, payload, dedupe_key, scheduled_for, status, provider_message_id, sent_at)
values ('e1130000-0000-0000-0000-000000000105','e1130000-0000-0000-0000-000000000001','e1130000-0000-0000-0000-000000000013','member','booking_confirmed','email','{}','bc:105', now()-interval '1 h','sent','pm-bounce-1', now()-interval '1 h');
insert into resend_webhook_inbox (event_type, provider_message_id, email, raw)
values ('email.bounced','pm-bounce-1','mb@example.com','{}');
-- a FORGED insert with an unknown id is a no-op
insert into resend_webhook_inbox (event_type, provider_message_id, email, raw)
values ('email.bounced','pm-forged-xyz','nobody@example.com','{}');
select sweep_resend_webhooks();
select expect_text('a real bounce marks the member bounced', (select email_status from members where id='e1130000-0000-0000-0000-000000000013'), 'bounced');
select expect_num('the inbox is emptied', (select count(*) from resend_webhook_inbox), 0);
-- a new scheduled row for MB is cancelled by the worker, never posted
insert into notifications (id, studio_id, member_id, recipient_type, template_key, channel, payload, dedupe_key, scheduled_for, status)
values ('e1130000-0000-0000-0000-000000000106','e1130000-0000-0000-0000-000000000001','e1130000-0000-0000-0000-000000000013','member','keep_drifting','email','{}','kd:106', now()-interval '1 min','scheduled');
select send_due_notifications();
select expect_text('a bounced member gets no further email', (select status::text from notifications where id='e1130000-0000-0000-0000-000000000106'), 'cancelled');
select expect_true('and it was never posted', (select net_request_id is null from notifications where id='e1130000-0000-0000-0000-000000000106'));

\echo '==== 6. a complaint unsubscribes the member ===='
insert into notifications (id, studio_id, member_id, recipient_type, template_key, channel, payload, dedupe_key, scheduled_for, status, provider_message_id, sent_at)
values ('e1130000-0000-0000-0000-000000000107','e1130000-0000-0000-0000-000000000001','e1130000-0000-0000-0000-000000000012','member','campaign','email','{}','cm:107', now()-interval '1 h','sent','pm-complain-1', now()-interval '1 h');
insert into resend_webhook_inbox (event_type, provider_message_id, email, raw)
values ('email.complained','pm-complain-1','m2@example.com','{}');
select sweep_resend_webhooks();
select expect_true('a complaint unsubscribes the member', (select marketing_unsubscribed_at is not null from members where id='e1130000-0000-0000-0000-000000000012'));

\echo '==== 7. the one-time re-queue relevance rules ===='
-- rate-limit failures in the last 30 days
insert into notifications (id, studio_id, member_id, recipient_type, template_key, channel, payload, dedupe_key, scheduled_for, status, attempts, failed_at, error) values
 ('e1130000-0000-0000-0000-000000000201','e1130000-0000-0000-0000-000000000001','e1130000-0000-0000-0000-000000000024','member','convert_book_first','email','{}','rq1', now()-interval '2 day','failed',1, now()-interval '2 day','HTTP 429: rate'),   -- no booking -> requeue
 ('e1130000-0000-0000-0000-000000000202','e1130000-0000-0000-0000-000000000001','e1130000-0000-0000-0000-000000000021','member','convert_book_first','email','{}','rq2', now()-interval '2 day','failed',1, now()-interval '2 day','HTTP 429: rate'),   -- has booking -> NOT
 ('e1130000-0000-0000-0000-000000000203','e1130000-0000-0000-0000-000000000001','e1130000-0000-0000-0000-000000000021','member','convert_day3','email','{}','rq3', now()-interval '2 day','failed',1, now()-interval '2 day','HTTP 429: rate'),        -- unconverted -> requeue
 ('e1130000-0000-0000-0000-000000000204','e1130000-0000-0000-0000-000000000001','e1130000-0000-0000-0000-000000000022','member','convert_day3','email','{}','rq4', now()-interval '2 day','failed',1, now()-interval '2 day','HTTP 429: rate'),        -- converted -> NOT
 ('e1130000-0000-0000-0000-000000000205','e1130000-0000-0000-0000-000000000001','e1130000-0000-0000-0000-000000000023','member','keep_drifting','email','{}','rq5', now()-interval '2 day','failed',1, now()-interval '2 day','HTTP 429: rate'),       -- drifting -> requeue
 ('e1130000-0000-0000-0000-000000000206','e1130000-0000-0000-0000-000000000001','e1130000-0000-0000-0000-000000000011','member','convert_before_class','email','{}','rq6', now()-interval '2 day','failed',1, now()-interval '2 day','HTTP 429: rate'), -- before_class -> NEVER
 ('e1130000-0000-0000-0000-000000000207','e1130000-0000-0000-0000-000000000001','e1130000-0000-0000-0000-000000000021','member','convert_day7','email','{}','rq7', now()-interval '2 day','failed',1, now()-interval '2 day','HTTP 429: daily_quota'); -- quota -> NOT
select requeue_rate_limit_drops();
select expect_text('no-booking book_first re-queued', (select status::text from notifications where id='e1130000-0000-0000-0000-000000000201'), 'scheduled');
select expect_text('has-booking book_first NOT re-queued', (select status::text from notifications where id='e1130000-0000-0000-0000-000000000202'), 'failed');
select expect_text('unconverted day3 re-queued', (select status::text from notifications where id='e1130000-0000-0000-0000-000000000203'), 'scheduled');
select expect_text('converted day3 NOT re-queued', (select status::text from notifications where id='e1130000-0000-0000-0000-000000000204'), 'failed');
select expect_text('drifting keep_drifting re-queued', (select status::text from notifications where id='e1130000-0000-0000-0000-000000000205'), 'scheduled');
select expect_text('before_class NEVER re-queued', (select status::text from notifications where id='e1130000-0000-0000-0000-000000000206'), 'failed');
select expect_text('a quota drop is NOT re-queued', (select status::text from notifications where id='e1130000-0000-0000-0000-000000000207'), 'failed');

\echo '==== 8. consent: the switch and the backfill ===='
-- the switch, as the member
reset role; set role authenticated; select set_config('request.jwt.claim.sub','e1130000-0000-0000-0000-0000000000a1',false);
select member_set_marketing(true);
reset role;
select expect_true('switch on opts in and clears any unsubscribe',
  (select marketing_opt_in and marketing_unsubscribed_at is null from members where id='e1130000-0000-0000-0000-000000000011'));
reset role; set role authenticated; select set_config('request.jwt.claim.sub','e1130000-0000-0000-0000-0000000000a1',false);
select member_set_marketing(false);
reset role;
select expect_false('switch off opts out', (select marketing_opt_in from members where id='e1130000-0000-0000-0000-000000000011'));

-- the backfill (service-only)
select backfill_marketing_optin();
select expect_true('an opt_in-false, never-unsubscribed member is flipped in',
  (select marketing_opt_in from members where id='e1130000-0000-0000-0000-000000000031'));
select expect_false('an unsubscribed member is NOT flipped', (select marketing_opt_in from members where id='e1130000-0000-0000-0000-000000000032'));
select expect_true('the flip is audited',
  (select exists(select 1 from audit_logs where entity_id='e1130000-0000-0000-0000-000000000031' and action='member.marketing_backfilled')));
-- a non-service caller cannot run the backfill (service-only; the grant is the boundary)
reset role; set role authenticated; select set_config('request.jwt.claim.sub','e1130000-0000-0000-0000-0000000000a1',false);
select expect_raise('a member cannot run the backfill', '42501', 'select backfill_marketing_optin()');
-- and neither can a member run the re-queue
select expect_raise('a member cannot run the re-queue', '42501', 'select requeue_rate_limit_drops()');
reset role;

\echo '==== 9. anon stays EXACTLY THIRTEEN ===='
select expect_num('anon surface is thirteen', (select count(*) from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where ns.nspname='public' and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'expect_%' and p.proname not in ('fake_resp')), 13);

\echo 'email_delivery_test: all assertions passed'
