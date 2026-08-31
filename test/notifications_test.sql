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
select expect_num('and Studiior appears nowhere in it',
  (select count(*) from render_notification(current_setting('n.id')::uuid)
    where html_body ilike '%studiior%' or text_body ilike '%studiior%'), 0);

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

set role authenticated;
select set_config('request.jwt.claim.sub','13131313-0000-0000-0000-0000000000a1',false);
do $$
begin
  perform send_due_notifications();
  raise exception 'FAIL  an owner ran the notification worker';
exception when sqlstate 'PT403' then
  raise notice 'PASS  an owner cannot run the notification worker';
end $$;
do $$
begin
  perform reconcile_notification_sends();
  raise exception 'FAIL  an owner ran the reconciler';
exception when sqlstate 'PT403' then
  raise notice 'PASS  an owner cannot run the reconciler';
end $$;
select expect_text('and an authenticated session is not a service context',
  is_service_context()::text, 'false');
reset role;

select expect_num('both cron jobs are scheduled every minute',
  (select count(*) from cron.job
    where jobname in ('studiior-send-notifications','studiior-reconcile-notifications')
      and schedule = '* * * * *' and active), 2);

select 'ALL NOTIFICATION TESTS PASSED' as result;
