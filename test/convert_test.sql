-- =============================================================================
-- Decision 78a (Convert) — migrations 20260832520000..20260832580000
-- =============================================================================
-- UUID space c078, checked free. Run after `supabase db reset`.
--
-- Eligibility's no-show second chance; intro_window maths + quiet hours; the
-- convert sweep's six rules at a fixed studio-local anchor (p_now); idempotency;
-- stop-on-purchase; the day-7 task (unique per kind); contacted writes a Journey
-- event; the exclusive intro plan refused outside the window; sequence_email
-- suppresses convert_* and nothing else; a convert-off studio writes nothing.
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
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual then raise notice 'PASS  %  (got true)', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('c0780000-0000-0000-0000-0000000000a0'),
  ('c0780000-0000-0000-0000-000000000e01'),('c0780000-0000-0000-0000-000000000e02'),
  ('c0780000-0000-0000-0000-000000000e03'),('c0780000-0000-0000-0000-000000000e04'),
  ('c0780000-0000-0000-0000-000000000e05'),('c0780000-0000-0000-0000-000000000e06'),
  ('c0780000-0000-0000-0000-000000000e07'),('c0780000-0000-0000-0000-000000000e08'),
  ('c0780000-0000-0000-0000-000000000e09'),('c0780000-0000-0000-0000-000000000e10'),
  ('c0780000-0000-0000-0000-000000000e11'),('c0780000-0000-0000-0000-000000000e12'),
  ('c0780000-0000-0000-0000-000000000e13'),('c0780000-0000-0000-0000-000000000e14'),
  ('c0780000-0000-0000-0000-000000000e15'),('c0780000-0000-0000-0000-000000000e16'),
  ('c0780000-0000-0000-0000-000000000e20');
insert into profiles (id, email)
  select id, id::text||'@example.com' from auth.users where id::text like 'c0780000%';

insert into studios (id, name, slug, timezone, currency, status) values
  ('c0780000-0000-0000-0000-000000000001','Convert A','c078-a','Asia/Manila','PHP','active'),
  ('c0780000-0000-0000-0000-000000000002','Convert B','c078-b','Asia/Manila','PHP','active');

-- The studio-local anchor: "today noon Manila", a fixed instant so every rule is
-- deterministic regardless of the wall clock the suite runs at.
select set_config('t.today', (now() at time zone 'Asia/Manila')::date::text, false);
select set_config('t.pnow',  ((current_setting('t.today')::date + time '12:00') at time zone 'Asia/Manila')::text, false);

-- A: convert ON, an exclusive class_pack intro offer, 14-day window. B: convert OFF.
insert into studio_settings (studio_id, free_first_class_enabled, convert_sequence_enabled,
                             intro_offer_plan_id, intro_offer_days, intro_offer_exclusive,
                             retention_tasks_to, time_format, booking_window_days) values
  ('c0780000-0000-0000-0000-000000000001', true,  true,
   null, 14, true, 'owner_manager', '24h', 30),
  ('c0780000-0000-0000-0000-000000000002', true,  false,
   null, 14, false, 'owner_manager', '24h', 30);
insert into locations (id, studio_id, name, is_primary) values
  ('c0780000-0000-0000-0000-00000000000a','c0780000-0000-0000-0000-000000000001','Main',true),
  ('c0780000-0000-0000-0000-00000000000b','c0780000-0000-0000-0000-000000000002','Main',true);
insert into studio_staff (studio_id, user_id, email, role) values
  ('c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-0000000000a0','c078-owa@example.com','owner'),
  ('c0780000-0000-0000-0000-000000000002','c0780000-0000-0000-0000-0000000000a0','c078-owb@example.com','owner');
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('c0780000-0000-0000-0000-0000000cc001','c0780000-0000-0000-0000-000000000001','Reformer',50,10),
  ('c0780000-0000-0000-0000-0000000cc002','c0780000-0000-0000-0000-000000000002','Reformer',50,10);
insert into instructors (id, studio_id, display_name, status) values
  ('c0780000-0000-0000-0000-0000000d1001','c0780000-0000-0000-0000-000000000001','Ada Example','active');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('c0780000-0000-0000-0000-0000000ee001','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000000a','R1',20),
  ('c0780000-0000-0000-0000-0000000ee003','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000000a','R2',20),
  ('c0780000-0000-0000-0000-0000000ee004','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000000a','R3',20),
  ('c0780000-0000-0000-0000-0000000ee002','c0780000-0000-0000-0000-000000000002','c0780000-0000-0000-0000-00000000000b','R1',20);

-- The exclusive intro plan (P) and a non-exclusive pack (Q), both at A; a Xendit
-- provider so xendit_begin_purchase runs its gate.
insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, validity_days, visibility, status) values
  ('c0780000-0000-0000-0000-0000000f0001','c0780000-0000-0000-0000-000000000001','Intro Pack','class_pack',179900,'PHP',4,30,'public','active'),
  ('c0780000-0000-0000-0000-0000000f0002','c0780000-0000-0000-0000-000000000001','Open Pack', 'class_pack',250000,'PHP',10,180,'public','active');
insert into studio_payment_providers
  (studio_id, provider, secret_key_ciphertext, callback_token_ciphertext, callback_token_sha256,
   key_last4, test_mode, connected_by) values
  ('c0780000-0000-0000-0000-000000000001','xendit','v1.opaque','v1.opaque',
   encode(digest('tok','sha256'),'hex'),'tok0', true, 'c0780000-0000-0000-0000-0000000000a0');
-- now that the plan exists, point the exclusive intro offer at it
update studio_settings set intro_offer_plan_id='c0780000-0000-0000-0000-0000000f0001'
 where studio_id='c0780000-0000-0000-0000-000000000001';

-- Members (each with a login). ad01..ad16 at A, ad20 at B.
insert into members (id, studio_id, user_id, first_name, last_name, email, phone, status, joined_on, source) values
  ('c0780000-0000-0000-0000-00000000ad01','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-000000000e01','Ns','One','ns1@example.com','0917000001','lead',current_date,'self_signup'),
  ('c0780000-0000-0000-0000-00000000ad02','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-000000000e02','Ns','Two','ns2@example.com','0917000002','lead',current_date,'self_signup'),
  ('c0780000-0000-0000-0000-00000000ad03','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-000000000e03','Att','Free','att@example.com','0917000003','lead',current_date,'self_signup'),
  ('c0780000-0000-0000-0000-00000000ad04','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-000000000e04','Paid','Att','paid@example.com','0917000004','lead',current_date,'self_signup'),
  ('c0780000-0000-0000-0000-00000000ad05','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-000000000e05','Before','Class','mb@example.com','0917000005','lead',current_date,'self_signup'),
  ('c0780000-0000-0000-0000-00000000ad06','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-000000000e06','After','Class','ma@example.com','0917000006','lead',current_date,'self_signup'),
  ('c0780000-0000-0000-0000-00000000ad07','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-000000000e07','After','Night','man@example.com','0917000007','lead',current_date,'self_signup'),
  ('c0780000-0000-0000-0000-00000000ad08','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-000000000e08','Day','Three','m3@example.com','0917000008','lead',current_date,'self_signup'),
  ('c0780000-0000-0000-0000-00000000ad09','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-000000000e09','Day','Seven','m7@example.com','0917000009','lead',current_date,'self_signup'),
  ('c0780000-0000-0000-0000-00000000ad10','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-000000000e10','Last','Day','ml@example.com','0917000010','lead',current_date,'self_signup'),
  ('c0780000-0000-0000-0000-00000000ad11','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-000000000e11','Missed','You','mm@example.com','0917000011','lead',current_date,'self_signup'),
  ('c0780000-0000-0000-0000-00000000ad12','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-000000000e12','Pur','Chase','mp@example.com','0917000012','lead',current_date,'self_signup'),
  ('c0780000-0000-0000-0000-00000000ad13','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-000000000e13','Opt','Out','mo@example.com','0917000013','lead',current_date,'self_signup'),
  ('c0780000-0000-0000-0000-00000000ad14','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-000000000e14','Win','Dow','mw@example.com','0917000014','lead',current_date,'self_signup'),
  ('c0780000-0000-0000-0000-00000000ad15','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-000000000e15','In','Window','min@example.com','0917000015','lead',current_date,'self_signup'),
  ('c0780000-0000-0000-0000-00000000ad16','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-000000000e16','Out','Window','mout@example.com','0917000016','lead',current_date,'self_signup'),
  ('c0780000-0000-0000-0000-00000000ad20','c0780000-0000-0000-0000-000000000002','c0780000-0000-0000-0000-000000000e20','B','Mem','bm@example.com','0917000020','lead',current_date,'self_signup');

-- Occurrences, at studio-local offsets from the anchor day. 07:00–07:50 unless noted.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, starts_at, ends_at, capacity, booked_count, status, staffing) values
  -- eligibility members: 30 days ago, so no sweep rule fires for them
  ('c0780000-0000-0000-0000-00000000c001','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000000a','c0780000-0000-0000-0000-0000000cc001','c0780000-0000-0000-0000-0000000ee001',null,'R', ((current_setting('t.today')::date - 30) + time '07:00') at time zone 'Asia/Manila', ((current_setting('t.today')::date - 30) + time '07:50') at time zone 'Asia/Manila',10,1,'scheduled','open'),
  ('c0780000-0000-0000-0000-00000000c002','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000000a','c0780000-0000-0000-0000-0000000cc001','c0780000-0000-0000-0000-0000000ee001',null,'R', ((current_setting('t.today')::date - 29) + time '07:00') at time zone 'Asia/Manila', ((current_setting('t.today')::date - 29) + time '07:50') at time zone 'Asia/Manila',10,1,'scheduled','open'),
  -- before_class: tomorrow
  ('c0780000-0000-0000-0000-00000000cb05','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000000a','c0780000-0000-0000-0000-0000000cc001','c0780000-0000-0000-0000-0000000ee001',null,'R', ((current_setting('t.today')::date + 1) + time '07:00') at time zone 'Asia/Manila', ((current_setting('t.today')::date + 1) + time '07:50') at time zone 'Asia/Manila',10,1,'scheduled','open'),
  -- after_class: this morning, ended 09:00
  ('c0780000-0000-0000-0000-00000000ca06','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000000a','c0780000-0000-0000-0000-0000000cc001','c0780000-0000-0000-0000-0000000ee001',null,'R', (current_setting('t.today')::date + time '08:10') at time zone 'Asia/Manila', (current_setting('t.today')::date + time '09:00') at time zone 'Asia/Manila',10,1,'scheduled','open'),
  -- after_class quiet: ended 05:00 (ends+2h=07:00 -> quiet -> 08:00)
  ('c0780000-0000-0000-0000-00000000ca07','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000000a','c0780000-0000-0000-0000-0000000cc001','c0780000-0000-0000-0000-0000000ee001',null,'R', (current_setting('t.today')::date + time '04:10') at time zone 'Asia/Manila', (current_setting('t.today')::date + time '05:00') at time zone 'Asia/Manila',10,1,'scheduled','open'),
  -- day3: 3 days ago
  ('c0780000-0000-0000-0000-00000000c308','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000000a','c0780000-0000-0000-0000-0000000cc001','c0780000-0000-0000-0000-0000000ee001',null,'R', ((current_setting('t.today')::date - 3) + time '07:00') at time zone 'Asia/Manila', ((current_setting('t.today')::date - 3) + time '07:50') at time zone 'Asia/Manila',10,1,'scheduled','open'),
  -- day7: 7 days ago
  ('c0780000-0000-0000-0000-00000000c709','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000000a','c0780000-0000-0000-0000-0000000cc001','c0780000-0000-0000-0000-0000000ee001',null,'R', ((current_setting('t.today')::date - 7) + time '07:00') at time zone 'Asia/Manila', ((current_setting('t.today')::date - 7) + time '07:50') at time zone 'Asia/Manila',10,1,'scheduled','open'),
  -- last_day: 14 days ago (window ends today)
  ('c0780000-0000-0000-0000-00000000cd10','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000000a','c0780000-0000-0000-0000-0000000cc001','c0780000-0000-0000-0000-0000000ee001',null,'R', ((current_setting('t.today')::date - 14) + time '07:00') at time zone 'Asia/Manila', ((current_setting('t.today')::date - 14) + time '07:50') at time zone 'Asia/Manila',10,1,'scheduled','open'),
  -- missed_you: yesterday
  ('c0780000-0000-0000-0000-00000000ce11','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000000a','c0780000-0000-0000-0000-0000000cc001','c0780000-0000-0000-0000-0000000ee001',null,'R', ((current_setting('t.today')::date - 1) + time '07:00') at time zone 'Asia/Manila', ((current_setting('t.today')::date - 1) + time '07:50') at time zone 'Asia/Manila',10,1,'scheduled','open'),
  -- purchase-stop: 3 days ago (day3), but member has a membership
  ('c0780000-0000-0000-0000-00000000cf12','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000000a','c0780000-0000-0000-0000-0000000cc001','c0780000-0000-0000-0000-0000000ee003',null,'R', ((current_setting('t.today')::date - 3) + time '07:00') at time zone 'Asia/Manila', ((current_setting('t.today')::date - 3) + time '07:50') at time zone 'Asia/Manila',10,1,'scheduled','open'),
  -- optout: tomorrow (before_class), sequence_email false
  ('c0780000-0000-0000-0000-00000000ca13','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000000a','c0780000-0000-0000-0000-0000000cc001','c0780000-0000-0000-0000-0000000ee001',null,'R', ((current_setting('t.today')::date + 1) + time '18:00') at time zone 'Asia/Manila', ((current_setting('t.today')::date + 1) + time '18:50') at time zone 'Asia/Manila',10,1,'scheduled','open'),
  -- window-maths: 10 days ago
  ('c0780000-0000-0000-0000-00000000cb14','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000000a','c0780000-0000-0000-0000-0000000cc001','c0780000-0000-0000-0000-0000000ee001',null,'R', ((current_setting('t.today')::date - 10) + time '10:00') at time zone 'Asia/Manila', ((current_setting('t.today')::date - 10) + time '10:50') at time zone 'Asia/Manila',10,1,'scheduled','open'),
  -- in-window / out-window (exclusive), real-now relative
  ('c0780000-0000-0000-0000-00000000cc15','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000000a','c0780000-0000-0000-0000-0000000cc001','c0780000-0000-0000-0000-0000000ee004',null,'R', now()-interval '3 days', now()-interval '3 days'+interval '50 min',10,1,'scheduled','open'),
  -- B studio, day3-aged class
  ('c0780000-0000-0000-0000-00000000cB20','c0780000-0000-0000-0000-000000000002','c0780000-0000-0000-0000-00000000000b','c0780000-0000-0000-0000-0000000cc002','c0780000-0000-0000-0000-0000000ee002',null,'R', ((current_setting('t.today')::date - 3) + time '07:00') at time zone 'Asia/Manila', ((current_setting('t.today')::date - 3) + time '07:50') at time zone 'Asia/Manila',10,1,'scheduled','open');

-- Free-first comp bookings + the host-null ledger row for each member.
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at) values
  ('c0780000-0000-0000-0000-00000000b001','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000c001','c0780000-0000-0000-0000-00000000ad01','no_show','member','comp', ((current_setting('t.today')::date - 30) + time '06:00') at time zone 'Asia/Manila'),
  ('c0780000-0000-0000-0000-00000000b002','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000c001','c0780000-0000-0000-0000-00000000ad02','no_show','member','comp', ((current_setting('t.today')::date - 30) + time '06:00') at time zone 'Asia/Manila'),
  ('c0780000-0000-0000-0000-00000000b02b','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000c002','c0780000-0000-0000-0000-00000000ad02','no_show','member','comp', ((current_setting('t.today')::date - 29) + time '06:00') at time zone 'Asia/Manila'),
  ('c0780000-0000-0000-0000-00000000b003','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000c001','c0780000-0000-0000-0000-00000000ad03','attended','member','comp', ((current_setting('t.today')::date - 30) + time '06:00') at time zone 'Asia/Manila'),
  ('c0780000-0000-0000-0000-00000000b004','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000c002','c0780000-0000-0000-0000-00000000ad04','attended','member','drop_in', ((current_setting('t.today')::date - 29) + time '06:00') at time zone 'Asia/Manila'),
  ('c0780000-0000-0000-0000-00000000b005','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000cb05','c0780000-0000-0000-0000-00000000ad05','booked','member','comp', ((current_setting('t.today')::date) + time '06:00') at time zone 'Asia/Manila'),
  ('c0780000-0000-0000-0000-00000000b006','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000ca06','c0780000-0000-0000-0000-00000000ad06','attended','member','comp', ((current_setting('t.today')::date) + time '06:00') at time zone 'Asia/Manila'),
  ('c0780000-0000-0000-0000-00000000b007','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000ca07','c0780000-0000-0000-0000-00000000ad07','attended','member','comp', ((current_setting('t.today')::date) + time '03:00') at time zone 'Asia/Manila'),
  ('c0780000-0000-0000-0000-00000000b008','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000c308','c0780000-0000-0000-0000-00000000ad08','attended','member','comp', ((current_setting('t.today')::date - 3) + time '06:00') at time zone 'Asia/Manila'),
  ('c0780000-0000-0000-0000-00000000b009','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000c709','c0780000-0000-0000-0000-00000000ad09','attended','member','comp', ((current_setting('t.today')::date - 7) + time '06:00') at time zone 'Asia/Manila'),
  ('c0780000-0000-0000-0000-00000000b010','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000cd10','c0780000-0000-0000-0000-00000000ad10','attended','member','comp', ((current_setting('t.today')::date - 14) + time '06:00') at time zone 'Asia/Manila'),
  ('c0780000-0000-0000-0000-00000000b011','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000ce11','c0780000-0000-0000-0000-00000000ad11','no_show','member','comp', ((current_setting('t.today')::date - 1) + time '06:00') at time zone 'Asia/Manila'),
  ('c0780000-0000-0000-0000-00000000b012','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000cf12','c0780000-0000-0000-0000-00000000ad12','attended','member','comp', ((current_setting('t.today')::date - 3) + time '06:00') at time zone 'Asia/Manila'),
  ('c0780000-0000-0000-0000-00000000b013','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000ca13','c0780000-0000-0000-0000-00000000ad13','booked','member','comp', ((current_setting('t.today')::date) + time '06:00') at time zone 'Asia/Manila'),
  ('c0780000-0000-0000-0000-00000000b014','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000cb14','c0780000-0000-0000-0000-00000000ad14','attended','member','comp', ((current_setting('t.today')::date - 10) + time '09:00') at time zone 'Asia/Manila'),
  ('c0780000-0000-0000-0000-00000000b015','c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000cc15','c0780000-0000-0000-0000-00000000ad15','attended','member','comp', now()-interval '3 days'-interval '1 hour'),
  ('c0780000-0000-0000-0000-00000000b020','c0780000-0000-0000-0000-000000000002','c0780000-0000-0000-0000-00000000cB20','c0780000-0000-0000-0000-00000000ad20','attended','member','comp', ((current_setting('t.today')::date - 3) + time '06:00') at time zone 'Asia/Manila');

insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email, occurrence_id, guest_booking_id, status) values
  ('c0780000-0000-0000-0000-000000000001',null,'c0780000-0000-0000-0000-00000000ad01','ns1@example.com','c0780000-0000-0000-0000-00000000c001','c0780000-0000-0000-0000-00000000b001','confirmed'),
  ('c0780000-0000-0000-0000-000000000001',null,'c0780000-0000-0000-0000-00000000ad02','ns2@example.com','c0780000-0000-0000-0000-00000000c002','c0780000-0000-0000-0000-00000000b02b','confirmed'),
  ('c0780000-0000-0000-0000-000000000001',null,'c0780000-0000-0000-0000-00000000ad03','att@example.com','c0780000-0000-0000-0000-00000000c001','c0780000-0000-0000-0000-00000000b003','confirmed'),
  ('c0780000-0000-0000-0000-000000000001',null,'c0780000-0000-0000-0000-00000000ad05','mb@example.com','c0780000-0000-0000-0000-00000000cb05','c0780000-0000-0000-0000-00000000b005','confirmed'),
  ('c0780000-0000-0000-0000-000000000001',null,'c0780000-0000-0000-0000-00000000ad06','ma@example.com','c0780000-0000-0000-0000-00000000ca06','c0780000-0000-0000-0000-00000000b006','confirmed'),
  ('c0780000-0000-0000-0000-000000000001',null,'c0780000-0000-0000-0000-00000000ad07','man@example.com','c0780000-0000-0000-0000-00000000ca07','c0780000-0000-0000-0000-00000000b007','confirmed'),
  ('c0780000-0000-0000-0000-000000000001',null,'c0780000-0000-0000-0000-00000000ad08','m3@example.com','c0780000-0000-0000-0000-00000000c308','c0780000-0000-0000-0000-00000000b008','confirmed'),
  ('c0780000-0000-0000-0000-000000000001',null,'c0780000-0000-0000-0000-00000000ad09','m7@example.com','c0780000-0000-0000-0000-00000000c709','c0780000-0000-0000-0000-00000000b009','confirmed'),
  ('c0780000-0000-0000-0000-000000000001',null,'c0780000-0000-0000-0000-00000000ad10','ml@example.com','c0780000-0000-0000-0000-00000000cd10','c0780000-0000-0000-0000-00000000b010','confirmed'),
  ('c0780000-0000-0000-0000-000000000001',null,'c0780000-0000-0000-0000-00000000ad11','mm@example.com','c0780000-0000-0000-0000-00000000ce11','c0780000-0000-0000-0000-00000000b011','confirmed'),
  ('c0780000-0000-0000-0000-000000000001',null,'c0780000-0000-0000-0000-00000000ad12','mp@example.com','c0780000-0000-0000-0000-00000000cf12','c0780000-0000-0000-0000-00000000b012','confirmed'),
  ('c0780000-0000-0000-0000-000000000001',null,'c0780000-0000-0000-0000-00000000ad13','mo@example.com','c0780000-0000-0000-0000-00000000ca13','c0780000-0000-0000-0000-00000000b013','confirmed'),
  ('c0780000-0000-0000-0000-000000000001',null,'c0780000-0000-0000-0000-00000000ad14','mw@example.com','c0780000-0000-0000-0000-00000000cb14','c0780000-0000-0000-0000-00000000b014','confirmed'),
  ('c0780000-0000-0000-0000-000000000001',null,'c0780000-0000-0000-0000-00000000ad15','min@example.com','c0780000-0000-0000-0000-00000000cc15','c0780000-0000-0000-0000-00000000b015','confirmed'),
  ('c0780000-0000-0000-0000-000000000002',null,'c0780000-0000-0000-0000-00000000ad20','bm@example.com','c0780000-0000-0000-0000-00000000cB20','c0780000-0000-0000-0000-00000000b020','confirmed');

-- MP has a membership (converted); MO has sequence_email off.
insert into memberships (studio_id, member_id, plan_id, status, price_cents, currency, starts_on) values
  ('c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000ad12','c0780000-0000-0000-0000-0000000f0002','active',250000,'PHP',current_date);
insert into notification_preferences (studio_id, member_id, sequence_email) values
  ('c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000ad13', false);

-- =============================================================================
-- 1. ELIGIBILITY — Decision 30 (d): one no-show uses the free class.
-- =============================================================================
select expect_text('one no-show => missed (Decision 30 (d))',
  free_first_eligibility('c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000ad01')->>'reason', 'missed');
select expect_text('two no-shows => still missed (missed_twice retired)',
  free_first_eligibility('c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000ad02')->>'reason', 'missed');
select expect_text('attended a free class => already_had_free (not eligible)',
  free_first_eligibility('c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000ad03')->>'reason', 'already_had_free');
select expect_text('a paid attended class => not_first',
  free_first_eligibility('c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-00000000ad04')->>'reason', 'not_first');

-- =============================================================================
-- 2. INTRO WINDOW maths + quiet hours.
-- =============================================================================
select expect_true('window active 10 days into a 14-day window',
  (intro_window('c0780000-0000-0000-0000-00000000ad14', current_setting('t.pnow')::timestamptz)->>'active')::boolean);
select expect_text('window ends 14 days after the free class (local date)',
  (((intro_window('c0780000-0000-0000-0000-00000000ad14', current_setting('t.pnow')::timestamptz)->>'ends_at')::timestamptz) at time zone 'Asia/Manila')::date::text,
  (current_setting('t.today')::date + 4)::text);
-- quiet hours: 22:00 -> next 08:00; 05:00 -> same-day 08:00; 14:00 unchanged.
select expect_num('22:00 shifts to next-day 08:00',
  extract(hour from quiet_hours_shift((current_setting('t.today')::date + time '22:00') at time zone 'Asia/Manila','Asia/Manila') at time zone 'Asia/Manila')::bigint, 8);
select expect_text('...and onto the next day',
  ((quiet_hours_shift((current_setting('t.today')::date + time '22:00') at time zone 'Asia/Manila','Asia/Manila') at time zone 'Asia/Manila')::date)::text,
  (current_setting('t.today')::date + 1)::text);
select expect_num('05:00 shifts to 08:00 the same day',
  extract(hour from quiet_hours_shift((current_setting('t.today')::date + time '05:00') at time zone 'Asia/Manila','Asia/Manila') at time zone 'Asia/Manila')::bigint, 8);
select expect_num('14:00 is left alone',
  extract(hour from quiet_hours_shift((current_setting('t.today')::date + time '14:00') at time zone 'Asia/Manila','Asia/Manila') at time zone 'Asia/Manila')::bigint, 14);

-- =============================================================================
-- 3. THE SWEEP — run once at the anchor; each rule queues the right template.
-- =============================================================================
select set_config('t.sweep1', convert_keep_sweep('c0780000-0000-0000-0000-000000000001', current_setting('t.pnow')::timestamptz)::text, false);

select expect_num('before_class queued for MB',
  (select count(*) from notifications where member_id='c0780000-0000-0000-0000-00000000ad05' and template_key='convert_before_class'), 1);
select expect_num('before_class scheduled for 18:00 local',
  (select extract(hour from scheduled_for at time zone 'Asia/Manila')::bigint from notifications where member_id='c0780000-0000-0000-0000-00000000ad05' and template_key='convert_before_class'), 18);
select expect_num('after_class queued for MA',
  (select count(*) from notifications where member_id='c0780000-0000-0000-0000-00000000ad06' and template_key='convert_after_class'), 1);
select expect_num('after_class at 05:00+2h is pushed out of quiet hours to 08:00 for MAN',
  (select extract(hour from scheduled_for at time zone 'Asia/Manila')::bigint from notifications where member_id='c0780000-0000-0000-0000-00000000ad07' and template_key='convert_after_class'), 8);
select expect_num('day3 queued for M3',
  (select count(*) from notifications where member_id='c0780000-0000-0000-0000-00000000ad08' and template_key='convert_day3'), 1);
select expect_num('day7 queued for M7',
  (select count(*) from notifications where member_id='c0780000-0000-0000-0000-00000000ad09' and template_key='convert_day7'), 1);
select expect_num('day7 created exactly one unconverted_day7 task',
  (select count(*) from member_tasks where member_id='c0780000-0000-0000-0000-00000000ad09' and kind='unconverted_day7'), 1);
select expect_num('last_day queued for ML',
  (select count(*) from notifications where member_id='c0780000-0000-0000-0000-00000000ad10' and template_key='convert_last_day'), 1);
select expect_num('missed_you queued for MM',
  (select count(*) from notifications where member_id='c0780000-0000-0000-0000-00000000ad11' and template_key='convert_missed_you'), 1);
select expect_num('a no-show gets NO after/day3 ladder mail',
  (select count(*) from notifications where member_id='c0780000-0000-0000-0000-00000000ad11' and template_key in ('convert_after_class','convert_day3','convert_day7')), 0);
select expect_num('MB email carries the member first name',
  (select 1 from notifications where member_id='c0780000-0000-0000-0000-00000000ad05' and template_key='convert_before_class' and payload->>'first_name'='Before'), 1);
-- 78a item 0: the "sell" mail links to /buy/{intro_offer_plan_id} when an offer is set.
select expect_true('convert mail buy_url points at /buy/{intro_offer_plan_id}',
  (select payload->>'buy_url' like '%/buy/c0780000-0000-0000-0000-0000000f0001' from notifications where member_id='c0780000-0000-0000-0000-00000000ad06' and template_key='convert_after_class'));

-- stop on purchase: MP (day3 aged, has a membership) gets nothing.
select expect_num('a converted member gets no convert mail',
  (select count(*) from notifications where member_id='c0780000-0000-0000-0000-00000000ad12' and template_key like 'convert_%'), 0);
-- sequence_email off: MO (before_class due) gets nothing, and nothing-else is suppressed.
select expect_num('sequence_email off suppresses convert mail',
  (select count(*) from notifications where member_id='c0780000-0000-0000-0000-00000000ad13' and template_key like 'convert_%'), 0);
select expect_true('...but notification_wanted still allows booking mail',
  notification_wanted('c0780000-0000-0000-0000-00000000ad13','booking_confirmed'));
select expect_true('...and convert mail is the thing it blocks',
  not notification_wanted('c0780000-0000-0000-0000-00000000ad13','convert_day3'));

-- =============================================================================
-- 4. IDEMPOTENT across two runs.
-- =============================================================================
select set_config('t.sweep2', convert_keep_sweep('c0780000-0000-0000-0000-000000000001', current_setting('t.pnow')::timestamptz)::text, false);
select expect_num('a second run adds no duplicate before_class',
  (select count(*) from notifications where member_id='c0780000-0000-0000-0000-00000000ad05' and template_key='convert_before_class'), 1);
select expect_num('a second run adds no second day7 task',
  (select count(*) from member_tasks where member_id='c0780000-0000-0000-0000-00000000ad09' and kind='unconverted_day7'), 1);

-- =============================================================================
-- 5. TASKS — contacted writes a Journey event; dismiss closes without one.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','c0780000-0000-0000-0000-0000000000a0',false);
select set_config('t.task7', (select id::text from member_tasks where member_id='c0780000-0000-0000-0000-00000000ad09' and kind='unconverted_day7'), false);
select set_config('t.cont', mark_task_contacted(current_setting('t.task7')::uuid)::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('mark_task_contacted => contacted', current_setting('t.cont')::jsonb->>'status', 'contacted');
select expect_num('a contacted Journey event is written',
  (select count(*) from timeline_events where member_id='c0780000-0000-0000-0000-00000000ad09' and type='contacted'), 1);
select expect_num('member_activity shows the contacted line to staff',
  (select count(*) from member_activity('c0780000-0000-0000-0000-00000000ad09', current_date - 30, current_date + 1) where kind='contacted'), 1);
-- a rebuild reproduces the event field-for-field (no duplicate, still present)
select set_config('t.rebuilt', rebuild_timeline_rows('c0780000-0000-0000-0000-00000000ad09')::text, false);
select expect_num('rebuild keeps exactly one contacted event',
  (select count(*) from timeline_events where member_id='c0780000-0000-0000-0000-00000000ad09' and type='contacted'), 1);
-- a non-owner may not act on a task
set role authenticated; select set_config('request.jwt.claim.sub','c0780000-0000-0000-0000-000000000e01',false);
do $$ begin perform mark_task_contacted(current_setting('t.task7')::uuid); exception when others then perform set_config('t.badcont', sqlstate, false); end $$;
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('a member cannot mark a task contacted', current_setting('t.badcont'), 'PT403');

-- =============================================================================
-- 6. EXCLUSIVE intro plan — refused outside the window, allowed inside, and only
--    that plan is gated.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','c0780000-0000-0000-0000-000000000e16',false);
do $$ begin
  perform purchase_id from xendit_begin_purchase('c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-0000000f0001');
  perform set_config('t.exout', 'NO_RAISE', false);
exception when others then perform set_config('t.exout', sqlstate, false); end $$;
do $$ begin
  perform purchase_id from xendit_begin_purchase('c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-0000000f0002');
  perform set_config('t.qout', 'OK', false);
exception when others then perform set_config('t.qout', sqlstate, false); end $$;
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('an out-of-window member is refused the exclusive plan', current_setting('t.exout'), 'PT409');
select expect_text('...but may buy a non-exclusive plan', current_setting('t.qout'), 'OK');

set role authenticated; select set_config('request.jwt.claim.sub','c0780000-0000-0000-0000-000000000e15',false);
do $$ begin
  perform purchase_id from xendit_begin_purchase('c0780000-0000-0000-0000-000000000001','c0780000-0000-0000-0000-0000000f0001');
  perform set_config('t.exin', 'OK', false);
exception when others then perform set_config('t.exin', sqlstate, false); end $$;
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('an in-window member may buy the exclusive plan', current_setting('t.exin'), 'OK');

-- =============================================================================
-- 7. CANARY — a convert-off studio writes nothing; the driver skips it.
-- =============================================================================
select set_config('t.offb', convert_keep_sweep('c0780000-0000-0000-0000-000000000002', current_setting('t.pnow')::timestamptz)::text, false);
select expect_num('convert off => queued 0', (current_setting('t.offb')::jsonb->>'queued')::bigint, 0);
select expect_num('convert off => no convert notifications at all',
  (select count(*) from notifications n join members m on m.id=n.member_id where m.studio_id='c0780000-0000-0000-0000-000000000002' and n.template_key like 'convert_%'), 0);
select set_config('t.all', convert_keep_sweep_all(current_setting('t.pnow')::timestamptz)::text, false);
select expect_num('the driver runs only studios with a 78 toggle on',
  (current_setting('t.all')::jsonb->>'studios')::bigint, 1);

-- =============================================================================
-- 8. RETENTION BOARD — the unconverted-free list + count.
-- =============================================================================
select expect_true('MB is on the unconverted-free board',
  exists(select 1 from retention_board('c0780000-0000-0000-0000-000000000001') where member_id='c0780000-0000-0000-0000-00000000ad05'));
select expect_true('a converted member is NOT on the board',
  not exists(select 1 from retention_board('c0780000-0000-0000-0000-000000000001') where member_id='c0780000-0000-0000-0000-00000000ad12'));
select expect_true('the count agrees with the board',
  retention_unconverted_count('c0780000-0000-0000-0000-000000000001')
    = (select count(*)::int from retention_board('c0780000-0000-0000-0000-000000000001')));

-- =============================================================================
-- 9. MORNING BRIEF — the unconverted-free summary line (convert on + unconverted
--    members present => one studio-level insight).
-- =============================================================================
select set_config('t.brief', generate_morning_brief('c0780000-0000-0000-0000-000000000001')::text, false);
select expect_true('the brief carries an unconverted_free line',
  exists(select 1 from ai_insights where studio_id='c0780000-0000-0000-0000-000000000001' and type='unconverted_free'));
select expect_text('...and its button opens the retention list',
  (select action_payload->>'href' from ai_insights where studio_id='c0780000-0000-0000-0000-000000000001' and type='unconverted_free' limit 1), '/retention');

select 'convert_test: all assertions passed' as done;
