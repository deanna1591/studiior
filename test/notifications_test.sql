-- =============================================================================
-- STUDIIOR — NOTIFICATION DELIVERY (migration 030)
--
--   preferences suppress at queue time, a duplicate dedupe_key is refused, a
--   failed send keeps its row and its reason, and the worker claims work so two
--   runs cannot send the same row twice.
--
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -f test/notifications_test.sql
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

-- --- Fixtures: 1313, checked free before use --------------------------------

insert into auth.users (id) values ('13131313-0000-0000-0000-0000000000a1');
insert into profiles (id, email) values ('13131313-0000-0000-0000-0000000000a1','n-owner@example.com');

insert into studios (id, name, slug, timezone, currency, status, accent_color) values
  ('13131313-0000-0000-0000-000000000001','Notify Studio','notify-test','Europe/Prague','CZK','active','#2B6CB0');
insert into studio_settings (studio_id, reminder_hours_before)
  values ('13131313-0000-0000-0000-000000000001', 12);
insert into locations (id, studio_id, name, is_primary) values
  ('13131313-0000-0000-0000-00000000000c','13131313-0000-0000-0000-000000000001','Main',true);
insert into studio_staff (studio_id, user_id, email, role) values
  ('13131313-0000-0000-0000-000000000001','13131313-0000-0000-0000-0000000000a1','n-owner@example.com','owner');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('13131313-0000-0000-0000-00000000ee01','13131313-0000-0000-0000-000000000001',
   '13131313-0000-0000-0000-00000000000c','Studio A',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('13131313-0000-0000-0000-00000000cc01','13131313-0000-0000-0000-000000000001','Reformer',50,10);

insert into members (id, studio_id, first_name, last_name, email, joined_on, status, waiver_signed_at) values
  ('13131313-0000-0000-0000-00000000dd01','13131313-0000-0000-0000-000000000001',
   'Wants','Everything','wants@example.com', current_date - 60, 'active', now()),
  ('13131313-0000-0000-0000-00000000dd02','13131313-0000-0000-0000-000000000001',
   'Opted','Out','optedout@example.com', current_date - 60, 'active', now());

-- One member has turned reminders and bookings off and left the rest alone.
insert into notification_preferences (member_id, studio_id, booking_email, reminder_email)
values ('13131313-0000-0000-0000-00000000dd02','13131313-0000-0000-0000-000000000001', false, false);

insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               starts_at, ends_at, capacity, status) values
  ('13131313-0000-0000-0000-00000000bb01','13131313-0000-0000-0000-000000000001',
   '13131313-0000-0000-0000-00000000000c','13131313-0000-0000-0000-00000000cc01',
   '13131313-0000-0000-0000-00000000ee01','Reformer Flow',
   now() + interval '3 days', now() + interval '3 days' + interval '50 min', 10, 'scheduled');

insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source, booked_at) values
  ('13131313-0000-0000-0000-00000000fb01','13131313-0000-0000-0000-000000000001',
   '13131313-0000-0000-0000-00000000bb01','13131313-0000-0000-0000-00000000dd01',
   'booked','drop_in', now()),
  ('13131313-0000-0000-0000-00000000fb02','13131313-0000-0000-0000-000000000001',
   '13131313-0000-0000-0000-00000000bb01','13131313-0000-0000-0000-00000000dd02',
   'booked','drop_in', now());

-- =============================================================================
-- 1. Preferences suppress, at queue time
-- =============================================================================

-- The bookings above were inserted, and migration 031's trigger queued from
-- them. Asserting on what is in the table rather than on a manual call is the
-- stronger test: it proves the wiring as well as the rule.
select expect_num('a member who wants them gets both the confirmation and the reminder',
  (select count(*) from notifications where member_id='13131313-0000-0000-0000-00000000dd01'), 2);
select expect_num('one who turned them off gets neither',
  (select count(*) from notifications where member_id='13131313-0000-0000-0000-00000000dd02'), 0);
select expect_num('and queueing the same booking by hand adds nothing on top',
  queue_booking_notifications('13131313-0000-0000-0000-00000000fb01')::bigint, 0);

-- The point of checking at queue time: nothing is written, so no future worker
-- can send it by forgetting to ask.
select expect_num('and nothing was written for them at all',
  (select count(*) from notifications where member_id='13131313-0000-0000-0000-00000000dd02'), 0);

select expect_num('the reminder is scheduled, not due now',
  (select count(*) from notifications
    where studio_id='13131313-0000-0000-0000-000000000001' and template_key='class_reminder' and scheduled_for > now()), 1);
select expect_text('twelve hours before the class, per reminder_hours_before',
  (select to_char(scheduled_for, 'YYYY-MM-DD HH24:MI') from notifications
     where studio_id='13131313-0000-0000-0000-000000000001' and template_key='class_reminder'),
  (select to_char(starts_at - interval '12 hours', 'YYYY-MM-DD HH24:MI')
     from class_occurrences where id='13131313-0000-0000-0000-00000000bb01'));

-- Three events are not opt-outable however the preferences read.
update notification_preferences set booking_email=false, reminder_email=false,
       waitlist_email=false, milestone_email=false, credit_expiry_email=false
 where member_id='13131313-0000-0000-0000-00000000dd02';
select expect_text('a cancelled class is not opt-outable',
  notification_wanted('13131313-0000-0000-0000-00000000dd02','class_cancelled')::text, 'true');
select expect_text('nor is a substitution',
  notification_wanted('13131313-0000-0000-0000-00000000dd02','instructor_substituted')::text, 'true');
select expect_text('nor is a failed payment',
  notification_wanted('13131313-0000-0000-0000-00000000dd02','payment_failed')::text, 'true');
select expect_text('but a milestone is',
  notification_wanted('13131313-0000-0000-0000-00000000dd02','milestone')::text, 'false');
select expect_text('a member with no preferences row has opted out of nothing',
  notification_wanted('13131313-0000-0000-0000-00000000dd01','milestone')::text, 'true');

-- =============================================================================
-- 2. A duplicate dedupe_key is refused
-- =============================================================================

select expect_num('still one confirmation',
  (select count(*) from notifications where studio_id='13131313-0000-0000-0000-000000000001' and template_key='booking_confirmed'), 1);

select expect_text('the same dedupe key returns null rather than raising',
  coalesce(queue_notification('13131313-0000-0000-0000-000000000001',
    '13131313-0000-0000-0000-00000000dd01', 'milestone', '{}'::jsonb,
    'booking_confirmed:13131313-0000-0000-0000-00000000fb01')::text, 'null'), 'null');

do $$
begin
  insert into notifications (studio_id, recipient_type, member_id, template_key, channel,
                             payload, dedupe_key, scheduled_for)
  values ('13131313-0000-0000-0000-000000000001','member','13131313-0000-0000-0000-00000000dd01',
          'milestone','email','{}','booking_confirmed:13131313-0000-0000-0000-00000000fb01', now());
  raise exception 'FAIL  a duplicate dedupe_key was accepted';
exception when unique_violation then
  raise notice 'PASS  the unique index refuses a duplicate dedupe_key outright';
end $$;

-- =============================================================================
-- 3. Rendering — the studio, not us
-- =============================================================================

select set_config('n.id',
  (select id::text from notifications where studio_id='13131313-0000-0000-0000-000000000001' and template_key='booking_confirmed'), false);

select expect_text('the from-name is the studio',
  (select from_name from render_notification(current_setting('n.id')::uuid)), 'Notify Studio');
select expect_like('the subject carries the class',
  (select subject from render_notification(current_setting('n.id')::uuid)), '%Reformer Flow%');
select expect_like('the body greets them by name',
  (select text_body from render_notification(current_setting('n.id')::uuid)), '%Hi Wants%');
select expect_num('no placeholder survives into the text',
  (select count(*) from render_notification(current_setting('n.id')::uuid)
    where text_body ~ '\{[a-z_]+\}'), 0);
select expect_like('the html is branded with the studio accent',
  (select html_body from render_notification(current_setting('n.id')::uuid)), '%#2B6CB0%');
-- The member app is served from {slug}.studiior.app, so the settings link in
-- the footer necessarily carries our domain — a member sees it in the URL bar
-- of the app itself already. The rule is about the words we write, so the link
-- is stripped before asking, rather than the rule being quietly dropped.
select expect_num('and Studiior appears nowhere in the copy',
  (select count(*) from render_notification(current_setting('n.id')::uuid)
    where replace(html_body, 'notify-test.studiior.app', '') ilike '%studiior%'
       or replace(text_body, 'notify-test.studiior.app', '') ilike '%studiior%'), 0);

-- =============================================================================
-- 3b. What a delivered email actually looked like (migration 034)
-- =============================================================================

-- The room was its own sentence in its own paragraph: "In Studio A." stranded
-- under the booking. It is a fragment now, inside the sentence.
select expect_like('the room is folded into the sentence',
  (select text_body from render_notification(current_setting('n.id')::uuid)),
  '%, in Studio A.%');
select expect_num('and never stands alone as its own line',
  (select count(*) from render_notification(current_setting('n.id')::uuid)
    where text_body ~ '(^|\n)In Studio A\.'), 0);

-- Reply-to. The studio has no contact address yet, and an absent header is the
-- right answer — pointing replies at our own notifications@ mailbox would look
-- like somewhere to write.
select expect_text('no contact address means no reply-to at all',
  (select coalesce(reply_to,'null') from render_notification(current_setting('n.id')::uuid)), 'null');

update studios set contact_email = 'hello@notify.example.com', contact_phone = '020 7946 0102'
 where id = '13131313-0000-0000-0000-000000000001';

select expect_text('reply-to is the studio''s own address',
  (select reply_to from render_notification(current_setting('n.id')::uuid)),
  'hello@notify.example.com');
select expect_like('and the footer carries the contact details',
  (select text_body from render_notification(current_setting('n.id')::uuid)),
  '%hello@notify.example.com · 020 7946 0102%');

-- The footer used to be the studio name, already in the header, under a rule.
select expect_like('the footer offers a way to change what we send',
  (select text_body from render_notification(current_setting('n.id')::uuid)),
  '%https://notify-test.studiior.app/settings%');

-- An always-send template must not offer a switch that does not exist.
select set_config('n.cancel',
  (select queue_notification('13131313-0000-0000-0000-000000000001',
     '13131313-0000-0000-0000-00000000dd01', 'class_cancelled',
     jsonb_build_object('class_name','Reformer Flow','when','Thursday'),
     'test:cancelled:1313')::text), false);
select expect_like('an always-send email says so rather than pretending',
  (select text_body from render_notification(current_setting('n.cancel')::uuid)),
  '%always send this one%');
-- Taken back off the queue: it was queued to be rendered, not to be sent, and
-- section 5 counts what the worker failed. Leaving it here made that count 2.
delete from notifications where id = current_setting('n.cancel')::uuid;

-- The accent rule took Studiior's lime when a studio had not chosen a colour,
-- in mail sent over that studio's own name.
update studios set accent_color = null where id = '13131313-0000-0000-0000-000000000001';
select expect_num('an accentless studio does not get Studiior lime in its email',
  (select count(*) from render_notification(current_setting('n.id')::uuid)
    where html_body like '%#BEF738%'), 0);
select expect_like('it falls back to neutral grey',
  (select html_body from render_notification(current_setting('n.id')::uuid)), '%#78716C%');
update studios set accent_color = '#2B6CB0' where id = '13131313-0000-0000-0000-000000000001';

-- =============================================================================
-- 4. A failed send keeps the row and the reason
--
-- No API key is configured on a fresh stack, which is the realistic case and
-- the one that must not take the cron down.
-- =============================================================================

select expect_text('no key is configured here',
  coalesce(notification_api_key(), 'NONE'), 'NONE');

select set_config('n.run1', send_due_notifications()::text, false);

select expect_num('the worker returned rather than raising, and failed this row',
  (select count(*) from notifications where studio_id='13131313-0000-0000-0000-000000000001' and status='failed'), 1);
select expect_text('the row is failed, not lost',
  (select status::text from notifications where id=current_setting('n.id')::uuid), 'failed');
select expect_like('and it says why, in words a person can act on',
  (select error from notifications where id=current_setting('n.id')::uuid),
  '%RESEND_API_KEY is not configured%');
select expect_num('the attempt was counted',
  (select attempts from notifications where id=current_setting('n.id')::uuid), 1);
select expect_num('the scheduled reminder was left alone — it is not due',
  (select count(*) from notifications where studio_id='13131313-0000-0000-0000-000000000001' and status='scheduled'), 1);

-- It retries up to max_attempts and then stops, rather than for ever.
update notifications set status='scheduled' where id=current_setting('n.id')::uuid;
select send_due_notifications();
update notifications set status='scheduled' where id=current_setting('n.id')::uuid;
select send_due_notifications();
select expect_num('after three attempts it has stopped being picked up',
  (select attempts from notifications where id=current_setting('n.id')::uuid), 3);
update notifications set status='scheduled' where id=current_setting('n.id')::uuid;
select send_due_notifications();
select expect_num('a fourth run does not touch it',
  (select attempts from notifications where id=current_setting('n.id')::uuid), 3);

-- =============================================================================
-- 5. The worker claims, so two runs cannot send one row twice
-- =============================================================================

delete from notifications where studio_id='13131313-0000-0000-0000-000000000001';
select queue_notification('13131313-0000-0000-0000-000000000001',
  '13131313-0000-0000-0000-00000000dd01', 'milestone',
  jsonb_build_object('milestone_name','50 classes','milestone_body','That is fifty.'),
  'claimtest:1');

-- Configure a key so the post is attempted rather than failing early. The URL
-- is unreachable, which is fine: what is being tested is the claim, not Resend.
select set_config('app.resend_api_key', 're_test_not_a_real_key', false);

select set_config('n.a', send_due_notifications()::text, false);
select expect_num('the first run claims and posts it',
  (select count(*) from notifications where studio_id='13131313-0000-0000-0000-000000000001' and status='sending'), 1);
select expect_text('the row is now sending, not scheduled',
  (select status::text from notifications where dedupe_key='claimtest:1'), 'sending');

select set_config('n.b', send_due_notifications()::text, false);
select expect_num('a second run posts nothing — the row is already claimed',
  (select count(*) from notifications where studio_id='13131313-0000-0000-0000-000000000001' and status='scheduled'), 0);
select expect_num('and it was only ever attempted once',
  (select attempts from notifications where dedupe_key='claimtest:1'), 1);
select expect_num('one row, one request id',
  (select count(*) from notifications
    where dedupe_key='claimtest:1' and net_request_id is not null), 1);

-- =============================================================================
-- 6. Staff messages join the same queue
-- =============================================================================

delete from notifications where studio_id='13131313-0000-0000-0000-000000000001';
insert into messages (id, studio_id, member_id, subject, body, created_by, status)
values ('13131313-0000-0000-0000-00000000ff01','13131313-0000-0000-0000-000000000001',
        '13131313-0000-0000-0000-00000000dd01','Missing you',
        E'Hi Wants — haven''t seen you in a while.\n\nNotify Studio',
        '13131313-0000-0000-0000-0000000000a1','queued');

select set_config('n.msg', send_due_notifications()::text, false);
select expect_num('a queued message becomes one notification',
  (select count(*) from notifications where studio_id='13131313-0000-0000-0000-000000000001' and dedupe_key like 'message:%'), 1);
select expect_text('the message is marked sent, not left queued for ever',
  (select status::text from messages where id='13131313-0000-0000-0000-00000000ff01'), 'sent');
select expect_like('and the notification carries the person''s own words',
  (select payload ->> 'body' from notifications where studio_id='13131313-0000-0000-0000-000000000001' and dedupe_key like 'message:%'),
  '%haven''t seen you in a while%');
select set_config('n.again', send_due_notifications()::text, false);
select expect_num('running the worker again does not queue it twice',
  (select count(*) from notifications where studio_id='13131313-0000-0000-0000-000000000001' and dedupe_key like 'message:%'), 1);

-- =============================================================================
-- 7. The worker is backend-only
-- =============================================================================

-- 7a. Privilege first: migration 033. A signed-in member cannot reach these
-- functions at all — not the worker, not the transport, and above all not the
-- key. Until 033 every one of them was executable by `authenticated`, because
-- migration 030 revoked from PUBLIC and the hosted default privileges name
-- `authenticated` explicitly. Counting rather than spot-checking, so a function
-- added later without a revoke fails here instead of shipping open.
select expect_num('no notification internal is executable by authenticated',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = any (array['notification_setting','notification_api_key',
        'notification_wanted','queue_notification','queue_booking_notifications',
        'queue_waitlist_offer','queue_occurrence_cancelled','queue_substitution',
        'queue_payment_failed','queue_milestone','queue_credit_expiries',
        'queue_all_credit_expiries','render_notification','send_via_resend',
        'deliver_notification','send_due_notifications',
        'reconcile_notification_sends','tg_queue_booking_notifications',
        'tg_queue_waitlist_offer','tg_cancel_booking_notifications'])
      and has_function_privilege('authenticated', p.oid, 'execute')), 0);
select expect_num('...nor by anon, including the three trigger functions',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = any (array['notification_api_key','send_via_resend',
        'render_notification','deliver_notification','queue_notification',
        'tg_queue_booking_notifications','tg_queue_waitlist_offer',
        'tg_cancel_booking_notifications'])
      and has_function_privilege('anon', p.oid, 'execute')), 0);

-- The concrete attack, run for real: this returned the key before 033.
set role authenticated;
select set_config('request.jwt.claim.sub','13131313-0000-0000-0000-0000000000a1',false);
do $$
begin
  perform notification_api_key();
  raise exception 'FAIL  a signed-in member read the Resend API key';
exception when insufficient_privilege then
  raise notice 'PASS  a signed-in member cannot read the Resend API key';
end $$;
do $$
begin
  perform send_via_resend('anyone@example.com','Reform',null,'hi','hi','<p>hi</p>');
  raise exception 'FAIL  a signed-in member sent mail from the studio domain';
exception when insufficient_privilege then
  raise notice 'PASS  a signed-in member cannot send mail from the studio domain';
end $$;
do $$
begin
  perform send_due_notifications();
  raise exception 'FAIL  an authenticated caller ran the notification worker';
exception when insufficient_privilege then
  raise notice 'PASS  an authenticated caller is denied execute on the worker';
end $$;
reset role;

-- 7b. And the guard behind the privilege still refuses on its own, which is
-- what actually protects us if a grant is ever restored by a future migration
-- or by a hosted default. Granted deliberately here so the guard is tested
-- rather than merely shadowed by 7a, then taken back.
grant execute on function send_due_notifications()       to authenticated;
grant execute on function reconcile_notification_sends() to authenticated;
set role authenticated;
select set_config('request.jwt.claim.sub','13131313-0000-0000-0000-0000000000a1',false);
do $$
begin
  perform send_due_notifications();
  raise exception 'FAIL  an owner ran the notification worker';
exception when sqlstate 'PT403' then
  raise notice 'PASS  with execute granted, the worker still refuses a non-service caller';
end $$;
do $$
begin
  perform reconcile_notification_sends();
  raise exception 'FAIL  an owner ran the reconciler';
exception when sqlstate 'PT403' then
  raise notice 'PASS  with execute granted, the reconciler still refuses a non-service caller';
end $$;
select expect_text('and an authenticated session is not a service context',
  is_service_context()::text, 'false');
reset role;
revoke execute on function send_due_notifications()       from authenticated;
revoke execute on function reconcile_notification_sends() from authenticated;

select expect_num('both cron jobs are scheduled every minute',
  (select count(*) from cron.job
    where jobname in ('studiior-send-notifications','studiior-reconcile-notifications')
      and schedule = '* * * * *' and active), 2);

select 'ALL NOTIFICATION TESTS PASSED' as result;
