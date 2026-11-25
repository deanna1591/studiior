-- Pool: Decision 109 (members export), 108 (daily money check),
-- 115 (pay period override), 113(a) (webhook inbox surface). UUID space b108.

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'BAD  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'BAD  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual then raise notice 'PASS  %  (got true)', label;
  else raise exception 'BAD  %  expected true, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_false(label text, actual boolean)
returns void language plpgsql as $$
begin
  if not coalesce(actual, true) then raise notice 'PASS  %  (got false)', label;
  else raise exception 'BAD  %  expected false, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_raise(label text, want_sqlstate text, stmt text)
returns void language plpgsql as $$
begin
  begin execute stmt; raise exception 'BAD  %  expected %, no raise', label, want_sqlstate;
  exception
    when others then
      if sqlstate = want_sqlstate then raise notice 'PASS  %  (got %)', label, sqlstate;
      else raise exception 'BAD  %  expected %, got %', label, want_sqlstate, sqlstate; end if;
  end;
end $$;

-- ====================== Fixtures ======================
insert into auth.users (id) values
  ('b1080000-0000-0000-0000-0000000000a1'),  -- owner
  ('b1080000-0000-0000-0000-0000000000a2'),  -- front desk
  ('b1080000-0000-0000-0000-0000000000a3');  -- a member login

insert into profiles (id, email, full_name) values
  ('b1080000-0000-0000-0000-0000000000a1','own@b108.test','Owner Ortega'),
  ('b1080000-0000-0000-0000-0000000000a2','fd@b108.test','Front Desk'),
  ('b1080000-0000-0000-0000-0000000000a3','mem@b108.test','Member Mendez');

-- SA: the rich studio. SB: clean (all clear).
insert into studios (id, slug, name, timezone, currency, country, status) values
  ('b1080000-0000-0000-0000-000000000001','b108a','Studio A','Asia/Manila','PHP','PH','active'),
  ('b1080000-0000-0000-0000-000000000002','b108b','Studio B','Asia/Manila','PHP','PH','active');
insert into studio_settings (studio_id, guarantees_enabled, free_first_class_enabled,
    free_first_reservation_from, free_first_reservation_fee_cents, require_waiver,
    cancellation_cutoff_minutes, daily_check_enabled) values
  ('b1080000-0000-0000-0000-000000000001', true, true, current_date - 30, 50000, true, 720, true),
  ('b1080000-0000-0000-0000-000000000002', false, false, null, 0, false, 720, true);

insert into studio_staff (id, studio_id, user_id, role, status, email) values
  ('b1080000-0000-0000-0000-0000000000f1','b1080000-0000-0000-0000-000000000001','b1080000-0000-0000-0000-0000000000a1','owner','active','own@b108.test'),
  ('b1080000-0000-0000-0000-0000000000f2','b1080000-0000-0000-0000-000000000001','b1080000-0000-0000-0000-0000000000a2','front_desk','active','fd@b108.test');

insert into locations (id, studio_id, name, timezone) values
  ('b1080000-0000-0000-0000-00000000000a','b1080000-0000-0000-0000-000000000001','Main','Asia/Manila');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('b1080000-0000-0000-0000-00000000000d','b1080000-0000-0000-0000-000000000001','b1080000-0000-0000-0000-00000000000a','R1',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('b1080000-0000-0000-0000-00000000000c','b1080000-0000-0000-0000-000000000001','Flow',50,10);
insert into instructors (id, studio_id, display_name, status) values
  ('b1080000-0000-0000-0000-0000000000fa','b1080000-0000-0000-0000-000000000001','Ida Coach','active');
insert into waiver_versions (id, studio_id, format, body, content_hash, requires_resign, created_by) values
  ('b1080000-0000-0000-0000-0000000000fb','b1080000-0000-0000-0000-000000000001','text','Waiver','h1',false,'b1080000-0000-0000-0000-0000000000a1');
insert into membership_plans (id, studio_id, name, type, billing_interval, price_cents, currency, visibility, status) values
  ('b1080000-0000-0000-0000-0000000000fc','b1080000-0000-0000-0000-000000000001','Monthly','recurring','month',180000,'PHP','public','active');

-- Members (marketing yes/no + the daily-check subjects)
insert into members (id, studio_id, first_name, last_name, email, phone, status, joined_on,
                     marketing_opt_in, marketing_unsubscribed_at, waiver_signed_at) values
  ('b1080000-0000-0000-0000-0000000000d1','b1080000-0000-0000-0000-000000000001','Anna','Yes','anna@b108.test','09170000001','active',current_date-10, true,  null, now()),
  ('b1080000-0000-0000-0000-0000000000d2','b1080000-0000-0000-0000-000000000001','Bea','No','bea@b108.test','09170000002','active',current_date-9,  false, null, now()),
  ('b1080000-0000-0000-0000-0000000000d3','b1080000-0000-0000-0000-000000000001','Cora','Unsub','cora@b108.test','09170000003','active',current_date-8, true,  now(), now()),  -- opted in but unsubscribed => no
  ('b1080000-0000-0000-0000-0000000000d4','b1080000-0000-0000-0000-000000000001','Lia','Lead','lia@b108.test','09170000004','lead',current_date-7,  false, null, now()),   -- lead w/ active plan
  ('b1080000-0000-0000-0000-0000000000d5','b1080000-0000-0000-0000-000000000001','Dory','Double','dory@b108.test','09170000005','active',current_date-6,false, null, now()),
  ('b1080000-0000-0000-0000-0000000000d6','b1080000-0000-0000-0000-000000000001','Edsel','Nowaiver','edsel@b108.test','09170000006','active',current_date-5,false,null, null),  -- attended, no waiver
  ('b1080000-0000-0000-0000-0000000000d7','b1080000-0000-0000-0000-000000000001','Fely','Resfee','fely@b108.test','09170000007','lead',current_date-4, false, null, now()),
  ('b1080000-0000-0000-0000-0000000000d8','b1080000-0000-0000-0000-000000000001','Gina','Hold','gina@b108.test','09170000008','lead',current_date-3, false, null, now()),
  ('b1080000-0000-0000-0000-0000000000d9','b1080000-0000-0000-0000-000000000001','Hana','Cancd','hana@b108.test','09170000009','active',current_date-2,false,null, now()),
  ('b1080000-0000-0000-0000-0000000000da','b1080000-0000-0000-0000-000000000001','Ivy','Nothing','ivy@b108.test','09170000010','active',current_date-1,false,null, now());

-- lead m4 holds an active plan
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on) values
  ('b1080000-0000-0000-0000-0000000000e4','b1080000-0000-0000-0000-000000000001','b1080000-0000-0000-0000-0000000000d4','b1080000-0000-0000-0000-0000000000fc','active',180000,'PHP',current_date-7);
update members set status='lead' where id='b1080000-0000-0000-0000-0000000000d4';  -- re-stick the anomaly the Decision 15 trigger auto-corrects

-- Occurrences: a normal future one, a cancelled one, an ended-but-booked one, a reservation one
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, starts_at, ends_at, capacity, status) values
  ('b1080000-0000-0000-0000-00000000a100','b1080000-0000-0000-0000-000000000001','b1080000-0000-0000-0000-00000000000a','b1080000-0000-0000-0000-00000000000c','b1080000-0000-0000-0000-00000000000d','b1080000-0000-0000-0000-0000000000fa','Flow A', now()+interval '3 days', now()+interval '3 days'+interval '50 min',10,'scheduled'),
  ('b1080000-0000-0000-0000-00000000a200','b1080000-0000-0000-0000-000000000001','b1080000-0000-0000-0000-00000000000a','b1080000-0000-0000-0000-00000000000c','b1080000-0000-0000-0000-00000000000d','b1080000-0000-0000-0000-0000000000fa','Flow Cancelled', now()+interval '2 days', now()+interval '2 days'+interval '50 min',10,'cancelled'),
  ('b1080000-0000-0000-0000-00000000a300','b1080000-0000-0000-0000-000000000001','b1080000-0000-0000-0000-00000000000a','b1080000-0000-0000-0000-00000000000c','b1080000-0000-0000-0000-00000000000d','b1080000-0000-0000-0000-0000000000fa','Flow Ended', now()-interval '2 days', now()-interval '2 days'+interval '50 min',10,'scheduled'),
  ('b1080000-0000-0000-0000-00000000a400','b1080000-0000-0000-0000-000000000001','b1080000-0000-0000-0000-00000000000a','b1080000-0000-0000-0000-00000000000c','b1080000-0000-0000-0000-00000000000d','b1080000-0000-0000-0000-0000000000fa','Flow Resfee', now()+interval '5 days', now()+interval '5 days'+interval '50 min',10,'scheduled'),
  ('b1080000-0000-0000-0000-00000000a500','b1080000-0000-0000-0000-000000000001','b1080000-0000-0000-0000-00000000000a','b1080000-0000-0000-0000-00000000000c','b1080000-0000-0000-0000-00000000000d','b1080000-0000-0000-0000-0000000000fa','Flow Hold', now()+interval '4 days', now()+interval '4 days'+interval '50 min',10,'scheduled'),
  -- pay-period held classes: one EMPTY, one with a live booking (staggered to clear occ_room_no_overlap)
  ('b1080000-0000-0000-0000-00000000a600','b1080000-0000-0000-0000-000000000001','b1080000-0000-0000-0000-00000000000a','b1080000-0000-0000-0000-00000000000c','b1080000-0000-0000-0000-00000000000d','b1080000-0000-0000-0000-0000000000fa','Held Empty', now()-interval '1 day'-interval '2 hours', now()-interval '1 day'-interval '2 hours'+interval '50 min',10,'scheduled'),
  ('b1080000-0000-0000-0000-00000000a700','b1080000-0000-0000-0000-000000000001','b1080000-0000-0000-0000-00000000000a','b1080000-0000-0000-0000-00000000000c','b1080000-0000-0000-0000-00000000000d','b1080000-0000-0000-0000-0000000000fa','Held Booked', now()-interval '1 day'-interval '4 hours', now()-interval '1 day'-interval '4 hours'+interval '50 min',10,'scheduled');

-- Double booking (m5 twice in o100). The one-live-per-member index normally
-- prevents this; the daily check is defensive against a would-be bug, so the
-- fixture drops the index to create the anomaly it must detect.
drop index bookings_one_live_per_member;
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source) values
  ('b1080000-0000-0000-0000-0000000000b1','b1080000-0000-0000-0000-000000000001','b1080000-0000-0000-0000-00000000a100','b1080000-0000-0000-0000-0000000000d5','booked','drop_in'),
  ('b1080000-0000-0000-0000-0000000000b2','b1080000-0000-0000-0000-000000000001','b1080000-0000-0000-0000-00000000a100','b1080000-0000-0000-0000-0000000000d5','booked','drop_in'),
  -- attended no waiver (m6 on ended class)
  ('b1080000-0000-0000-0000-0000000000b3','b1080000-0000-0000-0000-000000000001','b1080000-0000-0000-0000-00000000a300','b1080000-0000-0000-0000-0000000000d6','attended','drop_in'),
  -- live booking in a cancelled class (m9)
  ('b1080000-0000-0000-0000-0000000000b4','b1080000-0000-0000-0000-000000000001','b1080000-0000-0000-0000-00000000a200','b1080000-0000-0000-0000-0000000000d9','booked','drop_in'),
  -- reservation-fee comp booking, cancelled (m7)
  ('b1080000-0000-0000-0000-0000000000b5','b1080000-0000-0000-0000-000000000001','b1080000-0000-0000-0000-00000000a400','b1080000-0000-0000-0000-0000000000d7','cancelled','comp'),
  -- expired hold (m8)
  ('b1080000-0000-0000-0000-0000000000b6','b1080000-0000-0000-0000-000000000001','b1080000-0000-0000-0000-00000000a500','b1080000-0000-0000-0000-0000000000d8','booked','drop_in'),
  -- a live booking on the held-booked class (keeps did_not_run off it)
  ('b1080000-0000-0000-0000-0000000000b7','b1080000-0000-0000-0000-000000000001','b1080000-0000-0000-0000-00000000a700','b1080000-0000-0000-0000-0000000000d1','attended','drop_in');
update bookings set hold_until = now() - interval '30 minutes', hold_reason = 'reservation'
 where id = 'b1080000-0000-0000-0000-0000000000b6';

-- the reservation-fee comp booking needs a host-null guest_pass to look like free-first
insert into guest_passes (id, studio_id, occurrence_id, guest_email, guest_booking_id, guest_member_id, host_member_id) values
  ('b1080000-0000-0000-0000-0000000000fd','b1080000-0000-0000-0000-000000000001','b1080000-0000-0000-0000-00000000a400','fely@b108.test','b1080000-0000-0000-0000-0000000000b5','b1080000-0000-0000-0000-0000000000d7',null);

-- Payments: a succeeded reservation fee (booking cancelled, no credit) + a succeeded payment attached to nothing
insert into payments (id, studio_id, member_id, booking_id, kind, amount_cents, currency, status) values
  ('b1080000-0000-0000-0000-0000000000ba','b1080000-0000-0000-0000-000000000001','b1080000-0000-0000-0000-0000000000d7','b1080000-0000-0000-0000-0000000000b5','reservation_fee',50000,'PHP','succeeded'),
  ('b1080000-0000-0000-0000-0000000000bb','b1080000-0000-0000-0000-000000000001','b1080000-0000-0000-0000-0000000000da',null,null,100000,'PHP','succeeded');

-- Notifications: one scheduled > 1h, one failed < 1 day
insert into notifications (id, studio_id, member_id, recipient_type, template_key, channel, dedupe_key, scheduled_for, status, failed_at, error) values
  ('b1080000-0000-0000-0000-0000000000ca','b1080000-0000-0000-0000-000000000001','b1080000-0000-0000-0000-0000000000d1','member','class_reminder','email','n1', now()-interval '2 hours','scheduled', null, null),
  ('b1080000-0000-0000-0000-0000000000cb','b1080000-0000-0000-0000-000000000001','b1080000-0000-0000-0000-0000000000d1','member','class_reminder','email','n2', now()-interval '3 hours','failed', now()-interval '3 hours','HTTP 422: bad address');

-- Pay period + two held class records (type class, confirmed_at null)
insert into pay_periods (id, studio_id, starts_on, ends_on, status) values
  ('b1080000-0000-0000-0000-0000000000ef','b1080000-0000-0000-0000-000000000001', current_date-14, current_date-1, 'open');
insert into instructor_pay_records (id, studio_id, instructor_id, period_id, type, occurrence_id, amount_cents, currency, confirmed_at) values
  ('b1080000-0000-0000-0000-0000000000f6','b1080000-0000-0000-0000-000000000001','b1080000-0000-0000-0000-0000000000fa','b1080000-0000-0000-0000-0000000000ef','class','b1080000-0000-0000-0000-00000000a600',90000,'PHP', null),
  ('b1080000-0000-0000-0000-0000000000f7','b1080000-0000-0000-0000-000000000001','b1080000-0000-0000-0000-0000000000fa','b1080000-0000-0000-0000-0000000000ef','class','b1080000-0000-0000-0000-00000000a700',90000,'PHP', null);

-- SB clean studio: one owner + one tidy member, nothing wrong
insert into studio_staff (id, studio_id, user_id, role, status, email) values
  ('b1080000-0000-0000-0000-0000000000f3','b1080000-0000-0000-0000-000000000002','b1080000-0000-0000-0000-0000000000a1','owner','active','own@b108.test');

\echo '==== 1. Decision 109: members export ===='
-- owner allowed
reset role; set role authenticated; select set_config('request.jwt.claim.sub','b1080000-0000-0000-0000-0000000000a1',false);
select set_config('t.exp', members_export('b1080000-0000-0000-0000-000000000001','','all','attention')::text, false);
select expect_num('export has 10 rows', jsonb_array_length((current_setting('t.exp')::jsonb)->'rows'), 10);
select expect_num('count field is 10', (current_setting('t.exp')::jsonb->>'count')::bigint, 10);
select expect_text('Anna is marketing yes',
  (select r->>'marketing' from jsonb_array_elements(current_setting('t.exp')::jsonb->'rows') r where r->>'email'='anna@b108.test'), 'yes');
select expect_text('Bea (never opted in) is no',
  (select r->>'marketing' from jsonb_array_elements(current_setting('t.exp')::jsonb->'rows') r where r->>'email'='bea@b108.test'), 'no');
select expect_text('Cora (opted in but unsubscribed) is no',
  (select r->>'marketing' from jsonb_array_elements(current_setting('t.exp')::jsonb->'rows') r where r->>'email'='cora@b108.test'), 'no');
select expect_text('phone is E.164',
  (select r->>'phone' from jsonb_array_elements(current_setting('t.exp')::jsonb->'rows') r where r->>'email'='anna@b108.test'), '+639170000001');
reset role;
select expect_num('an export audit row with the count', (select (after->>'count')::bigint from audit_logs where action='members.exported' and studio_id='b1080000-0000-0000-0000-000000000001' order by created_at desc limit 1), 10);
-- front desk refused
reset role; set role authenticated; select set_config('request.jwt.claim.sub','b1080000-0000-0000-0000-0000000000a2',false);
select expect_raise('front desk cannot export', 'PT403', 'select members_export(''b1080000-0000-0000-0000-000000000001'','''',''all'',''attention'')');
reset role;

\echo '==== 2. Decision 108: daily money check ===='
select set_config('t.chk', daily_money_check('b1080000-0000-0000-0000-000000000001')::text, false);
select expect_true('at least nine items found', (current_setting('t.chk')::jsonb->>'n')::int >= 9);
select expect_false('not all clear', (current_setting('t.chk')::jsonb->>'all_clear')::boolean);
-- each of the nine kinds present (substring on the joined items text)
select set_config('t.items', (current_setting('t.chk')::jsonb->>'items_text'), false);
select expect_true('1 reservation fee no seat no credit', current_setting('t.items') ilike '%reservation fee%no seat and no credit%');
select expect_true('2 hold expired',                      current_setting('t.items') ilike '%hold on%expired%');
select expect_true('3 payment attached to nothing',       current_setting('t.items') ilike '%attached to nothing%');
select expect_true('4 lead with active plan',             current_setting('t.items') ilike '%active plan but is still marked lead%');
select expect_true('5 live booking cancelled/ended',      current_setting('t.items') ilike '%which was cancelled%' or current_setting('t.items') ilike '%which has already ended%');
select expect_true('6 double booked',                     current_setting('t.items') ilike '%booked twice%');
select expect_true('7 notification unsent over an hour',  current_setting('t.items') ilike '%waiting over an hour to send%');
select expect_true('8 attended no waiver',                current_setting('t.items') ilike '%without signing the waiver%');
select expect_true('9 emails failed in the last day',     current_setting('t.items') ilike '%emails failed%');
-- clean studio: all clear
select expect_text('SB is all clear', daily_money_check('b1080000-0000-0000-0000-000000000002')->>'count_label', 'all clear');
-- service-only
reset role; set role authenticated; select set_config('request.jwt.claim.sub','b1080000-0000-0000-0000-0000000000a3',false);
select expect_raise('a member cannot run the daily check', '42501', 'select daily_money_check(''b1080000-0000-0000-0000-000000000001'')');
reset role;

\echo '==== 3. Decision 115: pay period override ===='
-- close refuses with the two held classes, carrying occurrence_id + booked
reset role; set role authenticated; select set_config('request.jwt.claim.sub','b1080000-0000-0000-0000-0000000000a1',false);
select set_config('t.close1', close_pay_period('b1080000-0000-0000-0000-0000000000ef')::text, false);
select expect_text('close refused: held_records', current_setting('t.close1')::jsonb->>'reason', 'held_records');
select expect_num('two held classes listed', jsonb_array_length(current_setting('t.close1')::jsonb->'classes'), 2);
select expect_num('held-booked carries its booked count',
  (select (c->>'booked')::bigint from jsonb_array_elements(current_setting('t.close1')::jsonb->'classes') c where c->>'occurrence_id'='b1080000-0000-0000-0000-00000000a700'), 1);
-- did_not_run on a BOOKED class is refused
reset role; set role authenticated; select set_config('request.jwt.claim.sub','b1080000-0000-0000-0000-0000000000a1',false);
select expect_raise('did not run refused on a booked class', 'PT409', 'select resolve_unrecorded_class(''b1080000-0000-0000-0000-00000000a700'',''did_not_run'')');
-- front desk cannot resolve
reset role; set role authenticated; select set_config('request.jwt.claim.sub','b1080000-0000-0000-0000-0000000000a2',false);
select expect_raise('front desk cannot resolve', 'PT403', 'select resolve_unrecorded_class(''b1080000-0000-0000-0000-00000000a600'',''ran'')');
-- owner: did_not_run on the EMPTY class -> cancelled, no pay, no record
reset role; set role authenticated; select set_config('request.jwt.claim.sub','b1080000-0000-0000-0000-0000000000a1',false);
select resolve_unrecorded_class('b1080000-0000-0000-0000-00000000a600','did_not_run');
reset role;
select expect_text('empty class cancelled', (select status::text from class_occurrences where id='b1080000-0000-0000-0000-00000000a600'), 'cancelled');
select expect_text('reason is not held', (select cancellation_reason from class_occurrences where id='b1080000-0000-0000-0000-00000000a600'), 'not held');
select expect_num('its held pay record is gone', (select count(*) from instructor_pay_records where occurrence_id='b1080000-0000-0000-0000-00000000a600'), 0);
select expect_num('no new pay record was written for the cancel', (select count(*) from instructor_pay_records where occurrence_id='b1080000-0000-0000-0000-00000000a600'), 0);
select expect_text('note choice recorded', (select unrecorded_resolved_choice from class_occurrences where id='b1080000-0000-0000-0000-00000000a600'), 'did_not_run');
select expect_true('did_not_run queued no member email', not exists(select 1 from notifications where studio_id='b1080000-0000-0000-0000-000000000001' and template_key='class_cancelled'));
-- owner: ran on the BOOKED class -> confirmed for pay (method manager), pay stands
reset role; set role authenticated; select set_config('request.jwt.claim.sub','b1080000-0000-0000-0000-0000000000a1',false);
select resolve_unrecorded_class('b1080000-0000-0000-0000-00000000a700','ran');
reset role;
select expect_true('held-booked now confirmed', (select confirmed_at is not null from instructor_pay_records where occurrence_id='b1080000-0000-0000-0000-00000000a700'));
select expect_text('confirm method manager', (select confirm_method from instructor_pay_records where occurrence_id='b1080000-0000-0000-0000-00000000a700'), 'manager');
select expect_true('an unrecorded_resolved audit row', exists(select 1 from audit_logs where action='pay.unrecorded_resolved' and entity_id='b1080000-0000-0000-0000-00000000a700'));
-- the period now closes (no held records left)
reset role; set role authenticated; select set_config('request.jwt.claim.sub','b1080000-0000-0000-0000-0000000000a1',false);
select set_config('t.close2', close_pay_period('b1080000-0000-0000-0000-0000000000ef')::text, false);
reset role;
select expect_true('period closes after resolving', (current_setting('t.close2')::jsonb->>'ok')::boolean);
select expect_text('period is closed', (select status::text from pay_periods where id='b1080000-0000-0000-0000-0000000000ef'), 'closed');
-- the booked class's 90000 pay survived; the empty one's did not
select expect_num('period total is just the ran class (90000)', (select coalesce(sum(amount_cents),0) from instructor_pay_records where period_id='b1080000-0000-0000-0000-0000000000ef'), 90000);

\echo '==== 3b. resolve_all_as_ran ===='
-- fresh held period for the all-ran path
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, starts_at, ends_at, capacity, status) values
  ('b1080000-0000-0000-0000-00000000a800','b1080000-0000-0000-0000-000000000001','b1080000-0000-0000-0000-00000000000a','b1080000-0000-0000-0000-00000000000c','b1080000-0000-0000-0000-00000000000d','b1080000-0000-0000-0000-0000000000fa','H8', now()-interval '2 day'-interval '2 hours', now()-interval '2 day'-interval '2 hours'+interval '50 min',10,'scheduled'),
  ('b1080000-0000-0000-0000-00000000a900','b1080000-0000-0000-0000-000000000001','b1080000-0000-0000-0000-00000000000a','b1080000-0000-0000-0000-00000000000c','b1080000-0000-0000-0000-00000000000d','b1080000-0000-0000-0000-0000000000fa','H9', now()-interval '2 day'-interval '4 hours', now()-interval '2 day'-interval '4 hours'+interval '50 min',10,'scheduled');
insert into pay_periods (id, studio_id, starts_on, ends_on, status) values
  ('b1080000-0000-0000-0000-0000000000ee','b1080000-0000-0000-0000-000000000001', current_date-28, current_date-15, 'open');
insert into instructor_pay_records (id, studio_id, instructor_id, period_id, type, occurrence_id, amount_cents, currency, confirmed_at) values
  ('b1080000-0000-0000-0000-0000000000f8','b1080000-0000-0000-0000-000000000001','b1080000-0000-0000-0000-0000000000fa','b1080000-0000-0000-0000-0000000000ee','class','b1080000-0000-0000-0000-00000000a800',90000,'PHP',null),
  ('b1080000-0000-0000-0000-0000000000f9','b1080000-0000-0000-0000-000000000001','b1080000-0000-0000-0000-0000000000fa','b1080000-0000-0000-0000-0000000000ee','class','b1080000-0000-0000-0000-00000000a900',90000,'PHP',null);
reset role; set role authenticated; select set_config('request.jwt.claim.sub','b1080000-0000-0000-0000-0000000000a1',false);
select expect_num('resolve all as ran resolves two', (resolve_unrecorded_all_ran('b1080000-0000-0000-0000-0000000000ee')->>'resolved')::bigint, 2);
select set_config('t.close3', close_pay_period('b1080000-0000-0000-0000-0000000000ee')::text, false);
reset role;
select expect_true('period q2 closes after resolve-all', (current_setting('t.close3')::jsonb->>'ok')::boolean);

\echo '==== 4. Decision 113(a): inbox cap, purge, surface ===='
-- an unmatched row older than a day is purged; a fresh unmatched row is kept
insert into resend_webhook_inbox (id, event_type, provider_message_id, received_at) values
  ('b1080000-0000-0000-0000-0000000000c1','email.delivered','no-match-old', now()-interval '2 days'),
  ('b1080000-0000-0000-0000-0000000000c2','email.delivered','no-match-new', now());
reset role;  -- service context
select sweep_resend_webhooks();
select expect_num('old unmatched row purged', (select count(*) from resend_webhook_inbox where id='b1080000-0000-0000-0000-0000000000c1'), 0);
select expect_num('fresh unmatched row kept', (select count(*) from resend_webhook_inbox where id='b1080000-0000-0000-0000-0000000000c2'), 1);
-- the cap: with 600 already in the last minute, the 601st is dropped silently
insert into resend_webhook_inbox (event_type, provider_message_id, received_at)
  select 'email.delivered', 'cap'||g, now() from generate_series(1,600) g;
select expect_num('the cap holds the last minute at 600', (select count(*) from resend_webhook_inbox where received_at > now()-interval '1 minute'), 600);
insert into resend_webhook_inbox (event_type, provider_message_id) values ('email.delivered','over-cap');
select expect_num('the over-cap insert was dropped', (select count(*) from resend_webhook_inbox where provider_message_id='over-cap'), 0);
-- surface: anon FIFTEEN functions + the inbox table (anon insert, not select)
select expect_num('anon surface is fifteen functions',
  (select count(*) from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
    where ns.nspname='public' and p.prokind='f' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not like 'expect_%'), 15);
select expect_true('inbox is anon-insertable', has_table_privilege('anon','public.resend_webhook_inbox','insert'));
select expect_false('inbox is not anon-readable', has_table_privilege('anon','public.resend_webhook_inbox','select'));

\echo 'pool_109_108_115_test: all assertions passed'
