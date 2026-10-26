-- =============================================================================
-- Decision 78b (Keep) — migrations 20260832600000..630000
-- =============================================================================
-- UUID space d078, checked free. Run after `supabase db reset`.
--
-- Each keep rule fires once at the right studio-local day; auto-renewing gets
-- nothing; a renewal (end date pushed) stops the rest; win-back stops on a new
-- membership; keep ON suppresses membership_expiring + credit_expiry for THAT
-- studio only; sequence_email=false suppresses keep_* only; the retention board
-- gains Expiring/Lapsed sections; keep OFF writes nothing.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual then raise notice 'PASS  %  (got true)', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into studios (id, name, slug, timezone, currency, status) values
  ('d0780000-0000-0000-0000-000000000001','Keep A','d078-a','Asia/Manila','PHP','active'),
  ('d0780000-0000-0000-0000-000000000002','Keep B','d078-b','Asia/Manila','PHP','active');
select set_config('t.today', (now() at time zone 'Asia/Manila')::date::text, false);
select set_config('t.pnow',  ((current_setting('t.today')::date + time '12:00') at time zone 'Asia/Manila')::text, false);

-- KA: keep ON (convert off). KB: keep OFF.
insert into studio_settings (studio_id, keep_sequence_enabled, convert_sequence_enabled, time_format) values
  ('d0780000-0000-0000-0000-000000000001', true,  false, '24h'),
  ('d0780000-0000-0000-0000-000000000002', false, false, '24h');
insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, credits_per_period, billing_interval, validity_days, visibility, status) values
  ('d0780000-0000-0000-0000-00000000f0a1','d0780000-0000-0000-0000-000000000001','Monthly','recurring',250000,'PHP',null,null,'month',null,'public','active'),
  ('d0780000-0000-0000-0000-00000000f0a2','d0780000-0000-0000-0000-000000000001','10 Pack','class_pack',500000,'PHP',10,null,null,180,'public','active'),
  ('d0780000-0000-0000-0000-00000000f0b1','d0780000-0000-0000-0000-000000000002','Monthly B','recurring',250000,'PHP',null,null,'month',null,'public','active'),
  ('d0780000-0000-0000-0000-00000000f0b2','d0780000-0000-0000-0000-000000000002','10 Pack B','class_pack',500000,'PHP',10,null,null,180,'public','active');

-- Members (no logins needed — the sweep runs as service, retention_board read as postgres).
insert into members (id, studio_id, first_name, last_name, email, phone, status, joined_on, source) values
  ('d0780000-0000-0000-0000-00000000ad01','d0780000-0000-0000-0000-000000000001','R','Seven','r7@example.com','0917000001','active',current_date-30,'walk_in'),
  ('d0780000-0000-0000-0000-00000000ad02','d0780000-0000-0000-0000-000000000001','R','One','r1@example.com','0917000002','active',current_date-30,'walk_in'),
  ('d0780000-0000-0000-0000-00000000ad03','d0780000-0000-0000-0000-000000000001','R','Zero','r0@example.com','0917000003','active',current_date-30,'walk_in'),
  ('d0780000-0000-0000-0000-00000000ad04','d0780000-0000-0000-0000-000000000001','L','Three','l3@example.com','0917000004','active',current_date-40,'walk_in'),
  ('d0780000-0000-0000-0000-00000000ad05','d0780000-0000-0000-0000-000000000001','C','Seven','c7@example.com','0917000005','active',current_date-10,'walk_in'),
  ('d0780000-0000-0000-0000-00000000ad06','d0780000-0000-0000-0000-000000000001','C','Two','c2@example.com','0917000006','active',current_date-10,'walk_in'),
  ('d0780000-0000-0000-0000-00000000ad07','d0780000-0000-0000-0000-000000000001','W','Thirty','w30@example.com','0917000007','inactive',current_date-60,'walk_in'),
  ('d0780000-0000-0000-0000-00000000ad08','d0780000-0000-0000-0000-000000000001','W','Sixty','w60@example.com','0917000008','inactive',current_date-90,'walk_in'),
  ('d0780000-0000-0000-0000-00000000ad09','d0780000-0000-0000-0000-000000000001','Au','To','auto@example.com','0917000009','active',current_date-30,'walk_in'),
  ('d0780000-0000-0000-0000-00000000ad10','d0780000-0000-0000-0000-000000000001','Stripe','Sub','stripe@example.com','0917000010','active',current_date-30,'walk_in'),
  ('d0780000-0000-0000-0000-00000000ad11','d0780000-0000-0000-0000-000000000001','Ren','Stop','ren@example.com','0917000011','active',current_date-30,'walk_in'),
  ('d0780000-0000-0000-0000-00000000ad12','d0780000-0000-0000-0000-000000000001','Win','Stop','winstop@example.com','0917000012','active',current_date-60,'walk_in'),
  ('d0780000-0000-0000-0000-00000000ad13','d0780000-0000-0000-0000-000000000001','Opt','Out','optk@example.com','0917000013','active',current_date-30,'walk_in'),
  ('d0780000-0000-0000-0000-00000000ad20','d0780000-0000-0000-0000-000000000002','KB','Renew','kbr@example.com','0917000020','active',current_date-30,'walk_in'),
  ('d0780000-0000-0000-0000-00000000ad21','d0780000-0000-0000-0000-000000000002','KB','Credits','kbc@example.com','0917000021','active',current_date-10,'walk_in');

-- Memberships. Recurring end = current_period_end (studio-local midnight); pack end = expires_on.
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on, auto_renew, stripe_subscription_id, current_period_end, expires_on, credits_remaining) values
  ('d0780000-0000-0000-0000-00000000ee01','d0780000-0000-0000-0000-000000000001','d0780000-0000-0000-0000-00000000ad01','d0780000-0000-0000-0000-00000000f0a1','active',250000,'PHP',current_date-23,false,null,((current_setting('t.today')::date + 7) at time zone 'Asia/Manila'),null,null),
  ('d0780000-0000-0000-0000-00000000ee02','d0780000-0000-0000-0000-000000000001','d0780000-0000-0000-0000-00000000ad02','d0780000-0000-0000-0000-00000000f0a1','active',250000,'PHP',current_date-29,false,null,((current_setting('t.today')::date + 1) at time zone 'Asia/Manila'),null,null),
  ('d0780000-0000-0000-0000-00000000ee03','d0780000-0000-0000-0000-000000000001','d0780000-0000-0000-0000-00000000ad03','d0780000-0000-0000-0000-00000000f0a1','active',250000,'PHP',current_date-30,false,null,(current_setting('t.today')::date at time zone 'Asia/Manila'),null,null),
  ('d0780000-0000-0000-0000-00000000ee04','d0780000-0000-0000-0000-000000000001','d0780000-0000-0000-0000-00000000ad04','d0780000-0000-0000-0000-00000000f0a1','past_due',250000,'PHP',current_date-33,false,null,((current_setting('t.today')::date - 3) at time zone 'Asia/Manila'),null,null),
  ('d0780000-0000-0000-0000-00000000ee05','d0780000-0000-0000-0000-000000000001','d0780000-0000-0000-0000-00000000ad05','d0780000-0000-0000-0000-00000000f0a2','active',500000,'PHP',current_date-10,false,null,null,(current_setting('t.today')::date + 7),4),
  ('d0780000-0000-0000-0000-00000000ee06','d0780000-0000-0000-0000-000000000001','d0780000-0000-0000-0000-00000000ad06','d0780000-0000-0000-0000-00000000f0a2','active',500000,'PHP',current_date-10,false,null,null,(current_setting('t.today')::date + 2),2),
  ('d0780000-0000-0000-0000-00000000ee07','d0780000-0000-0000-0000-000000000001','d0780000-0000-0000-0000-00000000ad07','d0780000-0000-0000-0000-00000000f0a1','expired',250000,'PHP',current_date-60,false,null,((current_setting('t.today')::date - 30) at time zone 'Asia/Manila'),null,null),
  ('d0780000-0000-0000-0000-00000000ee08','d0780000-0000-0000-0000-000000000001','d0780000-0000-0000-0000-00000000ad08','d0780000-0000-0000-0000-00000000f0a1','expired',250000,'PHP',current_date-90,false,null,((current_setting('t.today')::date - 60) at time zone 'Asia/Manila'),null,null),
  ('d0780000-0000-0000-0000-00000000ee09','d0780000-0000-0000-0000-000000000001','d0780000-0000-0000-0000-00000000ad09','d0780000-0000-0000-0000-00000000f0a1','active',250000,'PHP',current_date-23,true, null,((current_setting('t.today')::date + 7) at time zone 'Asia/Manila'),null,null),
  ('d0780000-0000-0000-0000-00000000ee10','d0780000-0000-0000-0000-000000000001','d0780000-0000-0000-0000-00000000ad10','d0780000-0000-0000-0000-00000000f0a1','active',250000,'PHP',current_date-23,false,'sub_123',((current_setting('t.today')::date + 7) at time zone 'Asia/Manila'),null,null),
  ('d0780000-0000-0000-0000-00000000ee11','d0780000-0000-0000-0000-000000000001','d0780000-0000-0000-0000-00000000ad11','d0780000-0000-0000-0000-00000000f0a1','active',250000,'PHP',current_date-29,false,null,((current_setting('t.today')::date + 1) at time zone 'Asia/Manila'),null,null),
  -- WINSTOP: an expired membership 30 days ago AND a current active one (bought back)
  ('d0780000-0000-0000-0000-00000000ee12','d0780000-0000-0000-0000-000000000001','d0780000-0000-0000-0000-00000000ad12','d0780000-0000-0000-0000-00000000f0a1','expired',250000,'PHP',current_date-60,false,null,((current_setting('t.today')::date - 30) at time zone 'Asia/Manila'),null,null),
  ('d0780000-0000-0000-0000-00000000ee1b','d0780000-0000-0000-0000-000000000001','d0780000-0000-0000-0000-00000000ad12','d0780000-0000-0000-0000-00000000f0a1','active',250000,'PHP',current_date-2, false,null,((current_setting('t.today')::date + 28) at time zone 'Asia/Manila'),null,null),
  ('d0780000-0000-0000-0000-00000000ee13','d0780000-0000-0000-0000-000000000001','d0780000-0000-0000-0000-00000000ad13','d0780000-0000-0000-0000-00000000f0a1','active',250000,'PHP',current_date-23,false,null,((current_setting('t.today')::date + 7) at time zone 'Asia/Manila'),null,null),
  ('d0780000-0000-0000-0000-00000000ee20','d0780000-0000-0000-0000-000000000002','d0780000-0000-0000-0000-00000000ad20','d0780000-0000-0000-0000-00000000f0b1','active',250000,'PHP',current_date-23,false,null,((current_setting('t.today')::date + 7) at time zone 'Asia/Manila'),null,null),
  ('d0780000-0000-0000-0000-00000000ee21','d0780000-0000-0000-0000-000000000002','d0780000-0000-0000-0000-00000000ad21','d0780000-0000-0000-0000-00000000f0b2','active',500000,'PHP',current_date-10,false,null,null,(current_setting('t.today')::date + 7),4);

-- KA has opened: a past class with an attended booking, so studio_opened_on(KA) is set.
-- (Decision 14(c) — convert_keep_sweep is a no-op until the studio opens, and a studio
-- running keep reminders has, in reality, opened.) KB stays keep-OFF; its precedence
-- assertions ride sweep_membership_expiring/queue_credit_expiries, which the clock never gates.
insert into locations (id, studio_id, name, is_primary) values
  ('d0780000-0000-0000-0000-00000000100c','d0780000-0000-0000-0000-000000000001','KA Loc', true);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('d0780000-0000-0000-0000-0000000cc001','d0780000-0000-0000-0000-000000000001','Mat',50,10);
insert into class_occurrences (id, studio_id, location_id, class_type_id, name, starts_at, ends_at, capacity, booked_count, status) values
  ('d0780000-0000-0000-0000-0000000f0001','d0780000-0000-0000-0000-000000000001','d0780000-0000-0000-0000-00000000100c','d0780000-0000-0000-0000-0000000cc001','KA open',
     now()-interval '25 days', now()-interval '25 days'+interval '50 min', 10, 1, 'scheduled');
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at) values
  ('d0780000-0000-0000-0000-0000000bb001','d0780000-0000-0000-0000-000000000001','d0780000-0000-0000-0000-0000000f0001','d0780000-0000-0000-0000-00000000ad01','attended','member','drop_in', now()-interval '26 days');

-- OPT (ad13): mute the sequences.
insert into notification_preferences (studio_id, member_id, sequence_email) values
  ('d0780000-0000-0000-0000-000000000001','d0780000-0000-0000-0000-00000000ad13', false);

-- =============================================================================
-- 1. THE KEEP SWEEP — one call at the anchor; each rule fires once.
-- =============================================================================
select set_config('t.s1', convert_keep_sweep('d0780000-0000-0000-0000-000000000001', current_setting('t.pnow')::timestamptz)::text, false);

select expect_num('renew_7 queued', (select count(*) from notifications where member_id='d0780000-0000-0000-0000-00000000ad01' and template_key='keep_renew_7'), 1);
select expect_num('renew_7 scheduled at 10:00 local',
  (select extract(hour from scheduled_for at time zone 'Asia/Manila')::bigint from notifications where member_id='d0780000-0000-0000-0000-00000000ad01' and template_key='keep_renew_7'), 10);
select expect_num('renew_1 queued', (select count(*) from notifications where member_id='d0780000-0000-0000-0000-00000000ad02' and template_key='keep_renew_1'), 1);
select expect_num('renew_0 queued', (select count(*) from notifications where member_id='d0780000-0000-0000-0000-00000000ad03' and template_key='keep_renew_0'), 1);
select expect_num('lapsed_3 queued', (select count(*) from notifications where member_id='d0780000-0000-0000-0000-00000000ad04' and template_key='keep_lapsed_3'), 1);
select expect_num('credits_7 queued', (select count(*) from notifications where member_id='d0780000-0000-0000-0000-00000000ad05' and template_key='keep_credits_7'), 1);
select expect_num('credits_7 carries the credits left',
  (select (payload->>'credits_left')::int from notifications where member_id='d0780000-0000-0000-0000-00000000ad05' and template_key='keep_credits_7'), 4);
select expect_num('credits_2 queued', (select count(*) from notifications where member_id='d0780000-0000-0000-0000-00000000ad06' and template_key='keep_credits_2'), 1);
select expect_num('winback_30 queued', (select count(*) from notifications where member_id='d0780000-0000-0000-0000-00000000ad07' and template_key='keep_winback_30'), 1);
select expect_num('winback_60 queued', (select count(*) from notifications where member_id='d0780000-0000-0000-0000-00000000ad08' and template_key='keep_winback_60'), 1);
-- renew payload buy_url points at /buy/{plan}
select expect_true('renew buy_url points at /buy/{plan}',
  (select payload->>'buy_url' like '%/buy/d0780000-0000-0000-0000-00000000f0a1' from notifications where member_id='d0780000-0000-0000-0000-00000000ad01' and template_key='keep_renew_7'));

-- auto-renewing (saved card / subscription) get nothing
select expect_num('an auto-renewing membership gets no keep mail',
  (select count(*) from notifications where member_id='d0780000-0000-0000-0000-00000000ad09' and template_key like 'keep_%'), 0);
select expect_num('a subscription membership gets no keep mail',
  (select count(*) from notifications where member_id='d0780000-0000-0000-0000-00000000ad10' and template_key like 'keep_%'), 0);
-- win-back stops on a purchase (member has an active membership now)
select expect_num('win-back stops on a new membership',
  (select count(*) from notifications where member_id='d0780000-0000-0000-0000-00000000ad12' and template_key like 'keep_winback_%'), 0);
-- sequence_email=false suppresses keep_* only
select expect_num('sequence_email off suppresses keep mail',
  (select count(*) from notifications where member_id='d0780000-0000-0000-0000-00000000ad13' and template_key like 'keep_%'), 0);
select expect_true('...but booking mail still allowed',
  notification_wanted('d0780000-0000-0000-0000-00000000ad13','booking_confirmed'));

-- =============================================================================
-- 2. IDEMPOTENT + renewal-before-expiry stops the rest.
-- =============================================================================
-- RENSTOP had renew_1 due; renew it (push the period out) and re-run.
update memberships set current_period_end = ((current_setting('t.today')::date + 30) at time zone 'Asia/Manila')
 where id='d0780000-0000-0000-0000-00000000ee11';
select set_config('t.s2', convert_keep_sweep('d0780000-0000-0000-0000-000000000001', current_setting('t.pnow')::timestamptz)::text, false);
select expect_num('a second run adds no duplicate renew_7',
  (select count(*) from notifications where member_id='d0780000-0000-0000-0000-00000000ad01' and template_key='keep_renew_7'), 1);
select expect_num('a renewal before expiry stops renew_0',
  (select count(*) from notifications where member_id='d0780000-0000-0000-0000-00000000ad11' and template_key='keep_renew_0'), 0);
select expect_num('RENSTOP got its renew_1 before the renewal, and only that',
  (select count(*) from notifications where member_id='d0780000-0000-0000-0000-00000000ad11' and template_key like 'keep_%'), 1);

-- =============================================================================
-- 3. PRECEDENCE — keep ON suppresses membership_expiring + credit_expiry for KA
--    only; KB (keep off) still gets them.
-- =============================================================================
select set_config('t.sme', sweep_membership_expiring()::text, false);
select expect_num('KA (keep on) gets NO membership_expiring',
  (select count(*) from notifications where member_id='d0780000-0000-0000-0000-00000000ad01' and template_key='membership_expiring'), 0);
select expect_num('KB (keep off) gets membership_expiring',
  (select count(*) from notifications where member_id='d0780000-0000-0000-0000-00000000ad20' and template_key='membership_expiring'), 1);
select expect_num('queue_credit_expiries is 0 for the keep-on studio',
  (queue_credit_expiries('d0780000-0000-0000-0000-000000000001'))::bigint, 0);
select expect_num('queue_credit_expiries fires for the keep-off studio',
  (queue_credit_expiries('d0780000-0000-0000-0000-000000000002'))::bigint, 1);

-- =============================================================================
-- 4. CANARY — the keep-off studio's sweep writes no keep mail.
-- =============================================================================
select set_config('t.kb', convert_keep_sweep('d0780000-0000-0000-0000-000000000002', current_setting('t.pnow')::timestamptz)::text, false);
select expect_num('keep off => 0 keep notifications at KB',
  (select count(*) from notifications n join members m on m.id=n.member_id where m.studio_id='d0780000-0000-0000-0000-000000000002' and n.template_key like 'keep_%'), 0);

-- =============================================================================
-- 5. RETENTION BOARD — the two new sections.
-- =============================================================================
select expect_true('an expiring membership shows in the Expiring section',
  exists(select 1 from retention_board('d0780000-0000-0000-0000-000000000001') where member_id='d0780000-0000-0000-0000-00000000ad01' and section='expiring'));
select expect_true('a lapsed membership shows in the Lapsed section',
  exists(select 1 from retention_board('d0780000-0000-0000-0000-000000000001') where member_id='d0780000-0000-0000-0000-00000000ad07' and section='lapsed'));
select expect_true('an auto-renewing membership is NOT in Expiring',
  not exists(select 1 from retention_board('d0780000-0000-0000-0000-000000000001') where member_id='d0780000-0000-0000-0000-00000000ad09' and section='expiring'));
select expect_true('the Expiring row carries the plan name and end date',
  exists(select 1 from retention_board('d0780000-0000-0000-0000-000000000001') where member_id='d0780000-0000-0000-0000-00000000ad01' and section='expiring' and plan_name='Monthly' and expires_on=current_setting('t.today')::date+7));
select expect_num('retention_unconverted_count ignores expiring/lapsed (0 here, no free classes)',
  (retention_unconverted_count('d0780000-0000-0000-0000-000000000001'))::bigint, 0);

select 'keep_test: all assertions passed' as done;
