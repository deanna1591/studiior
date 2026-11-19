-- =============================================================================
-- Decision 116(a) an empty class is down-time, 22(e) flex state at a glance,
-- 21(c) apply the minimum to future classes, 18(b) a month's submission is not
-- the weekly pattern (migrations 20260833585000 + 20260833590000). UUID space
-- d16a, checked free.
-- =============================================================================
-- Covers: an empty hour offered; an empty flex class offered at any distance; an
-- empty core class offered inside the replace window and not outside it; a class
-- with one booking, one with a payment hold, and a committed one never offered;
-- the displaced coach offered first and never busy; the replacement cancel with
-- no member email and the coach notice; core displaced coach paid the holding
-- fee, flex the standby amount, nothing when the displaced coach teaches the
-- private; a pending replacement holding the slot while the class stays bookable;
-- the race refusal with credit back, the email and the return-screen marker;
-- schedule_range's state chip fields ("1 of 2, 1 unpaid"); apply-to-future count
-- and effect with committed and past-cut-off classes untouched; the settings
-- audit; a December submission plus a staff pattern save leaving both intact; the
-- availability function reading the pattern and the submission each for its own
-- dates, and "nothing stated" with only a next-month submission; front desk
-- PT403; anon EXACTLY FOURTEEN and the inbox table closed to anon reads.
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
create or replace function d16a_as(p_user uuid, p_sql text) returns text
language plpgsql as $$
declare v_state text := 'ok';
begin
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  perform set_config('role', 'authenticated', true);
  begin execute p_sql; exception when others then v_state := sqlstate; end;
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claim.sub', '', true);
  return v_state;
end $$;
create or replace function d16a_at(p_days int, p_time time) returns timestamptz
language sql stable as $$
  select (((now() at time zone 'Asia/Manila')::date + p_days) + p_time) at time zone 'Asia/Manila';
$$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('d16a0000-0000-0000-0000-0000000000a1'),  -- owner
  ('d16a0000-0000-0000-0000-0000000000a2'),  -- front desk
  ('d16a0000-0000-0000-0000-0000000000a3'),  -- coach Ines login
  ('d16a0000-0000-0000-0000-0000000000a4'),  -- coach Gus login
  ('d16a0000-0000-0000-0000-0000000000e1'),('d16a0000-0000-0000-0000-0000000000e2'),
  ('d16a0000-0000-0000-0000-0000000000e3');
insert into profiles (id, email)
  select id, id::text||'@example.com' from auth.users where id::text like 'd16a0000%';

insert into studios (id, name, slug, timezone, currency, status) values
  ('d16a0000-0000-0000-0000-000000000001','Replace One','d16a-s','Asia/Manila','PHP','active');
insert into studio_settings (studio_id, require_waiver, open_time, close_time,
     private_sessions_enabled, private_lead_time_hours, private_buffer_minutes, private_replace_core_hours,
     guarantees_enabled, flex_enabled, core_min_bookings, core_unmet_pay_cents, flex_min_bookings,
     flex_unmet_pay_cents, flex_deadline_mode, flex_deadline_hours) values
  ('d16a0000-0000-0000-0000-000000000001', false, '07:00', '21:00',
     true, 12, 10, 72, true, true, 1, 40000, 2, 5000, 'hours_before', 12);
insert into locations (id, studio_id, name, is_primary) values
  ('d16a0000-0000-0000-0000-00000000000a','d16a0000-0000-0000-0000-000000000001','Main',true);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('d16a0000-0000-0000-0000-0000000005a1','d16a0000-0000-0000-0000-000000000001','d16a0000-0000-0000-0000-0000000000a1','d16a-ow@example.com','owner'),
  ('d16a0000-0000-0000-0000-0000000005a2','d16a0000-0000-0000-0000-000000000001','d16a0000-0000-0000-0000-0000000000a2','d16a-fd@example.com','front_desk'),
  ('d16a0000-0000-0000-0000-0000000005a3','d16a0000-0000-0000-0000-000000000001','d16a0000-0000-0000-0000-0000000000a3','d16a-in@example.com','instructor'),
  ('d16a0000-0000-0000-0000-0000000005a4','d16a0000-0000-0000-0000-000000000001','d16a0000-0000-0000-0000-0000000000a4','d16a-gu@example.com','instructor');
-- Ines (I1) and Gus (I2) teach privates; Gus teaches the group classes.
insert into instructors (id, studio_id, staff_id, display_name, status, teaches_privates) values
  ('d16a0000-0000-0000-0000-0000000001c1','d16a0000-0000-0000-0000-000000000001','d16a0000-0000-0000-0000-0000000005a3','Ines Coach','active',true),
  ('d16a0000-0000-0000-0000-0000000001c2','d16a0000-0000-0000-0000-000000000001','d16a0000-0000-0000-0000-0000000005a4','Gus Group','active',true),
  ('d16a0000-0000-0000-0000-0000000001c3','d16a0000-0000-0000-0000-000000000001',null,'Pat Pattern','active',false),
  ('d16a0000-0000-0000-0000-0000000001c4','d16a0000-0000-0000-0000-000000000001',null,'Kim Nextmonth','active',false);
insert into instructor_rate_versions (studio_id, instructor_id, effective_from, currency, base_rate_cents,
     per_head_rate_cents, per_head_threshold, full_house_bonus_cents)
values ('d16a0000-0000-0000-0000-000000000001','d16a0000-0000-0000-0000-0000000001c2', current_date - 30, 'PHP', 90000, 7500, 2, 0);
insert into members (id, studio_id, user_id, first_name, last_name, email, status) values
  ('d16a0000-0000-0000-0000-0000000000f1','d16a0000-0000-0000-0000-000000000001','d16a0000-0000-0000-0000-0000000000e1','Maria','Booker','d16a-e1@example.com','active'),
  ('d16a0000-0000-0000-0000-0000000000f2','d16a0000-0000-0000-0000-000000000001','d16a0000-0000-0000-0000-0000000000e2','Nina','Racer','d16a-e2@example.com','active'),
  ('d16a0000-0000-0000-0000-0000000000f3','d16a0000-0000-0000-0000-000000000001','d16a0000-0000-0000-0000-0000000000e3','Olga','Group','d16a-e3@example.com','active');
insert into studio_payment_providers
  (studio_id, provider, secret_key_ciphertext, callback_token_ciphertext, callback_token_sha256,
   key_last4, test_mode, connected_by) values
  ('d16a0000-0000-0000-0000-000000000001','xendit','v1.x','v1.y',
   encode(extensions.digest('tok16a','sha256'),'hex'), 'tok0', true, 'd16a0000-0000-0000-0000-0000000000a1');
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('d16a0000-0000-0000-0000-0000000cf001','d16a0000-0000-0000-0000-000000000001','Reformer',50,8);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('d16a0000-0000-0000-0000-00000000b001','d16a0000-0000-0000-0000-000000000001','d16a0000-0000-0000-0000-00000000000a','Only Room',8);
insert into private_session_types (id, studio_id, name, price_cents, people, duration_min, coach_pay_cents, sort) values
  ('d16a0000-0000-0000-0000-0000000007a1','d16a0000-0000-0000-0000-000000000001','Private 1:1',220000,1,50,100000,1);
insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, validity_days,
                              visibility, status, private_pack, restrictions) values
  ('d16a0000-0000-0000-0000-0000000008a1','d16a0000-0000-0000-0000-000000000001','5 Privates','class_pack',1050000,'PHP',5,null,
   'public','active',true,'{"class_type_ids": ["private-only"]}'::jsonb);
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, credits_remaining, starts_on)
values ('d16a0000-0000-0000-0000-0000000009a1','d16a0000-0000-0000-0000-000000000001','d16a0000-0000-0000-0000-0000000000f1',
        'd16a0000-0000-0000-0000-0000000008a1','active',1050000,'PHP',5,current_date);
insert into credit_ledger (studio_id, member_id, membership_id, delta, reason, balance_after)
values ('d16a0000-0000-0000-0000-000000000001','d16a0000-0000-0000-0000-0000000000f1','d16a0000-0000-0000-0000-0000000009a1',5,'purchase',5);

-- Group classes in the only room, Gus teaching. g = core / flex set on the occurrence.
create temp table d16a_cls (k text, id uuid, d int, t time, tier text);
insert into d16a_cls values
  ('core_in',   'd16a0000-0000-0000-0000-00000000c001', 2, '10:00', 'core'),
  ('core_out',  'd16a0000-0000-0000-0000-00000000c002', 5, '10:00', 'core'),
  ('flex_far',  'd16a0000-0000-0000-0000-00000000c003', 5, '12:00', 'flex'),
  ('booked',    'd16a0000-0000-0000-0000-00000000c004', 2, '12:00', 'flex'),
  ('hold',      'd16a0000-0000-0000-0000-00000000c005', 2, '14:00', 'flex'),
  ('committed', 'd16a0000-0000-0000-0000-00000000c006', 2, '16:00', 'flex'),
  ('core_paid', 'd16a0000-0000-0000-0000-00000000c007', 2, '18:00', 'core'),
  ('race',      'd16a0000-0000-0000-0000-00000000c008', 2, '20:00', 'flex'),
  ('flex_paid', 'd16a0000-0000-0000-0000-00000000c009', 4, '10:00', 'flex');
insert into class_occurrences (id, studio_id, class_type_id, room_id, location_id, name, instructor_id,
     starts_at, ends_at, capacity, status, staffing, guarantee_tier, flex, minimum_bookings)
select c.id, 'd16a0000-0000-0000-0000-000000000001','d16a0000-0000-0000-0000-0000000cf001',
       'd16a0000-0000-0000-0000-00000000b001','d16a0000-0000-0000-0000-00000000000a','Reformer Flow',
       'd16a0000-0000-0000-0000-0000000001c2', d16a_at(c.d, c.t), d16a_at(c.d, c.t) + interval '50 minutes',
       8, 'scheduled', 'assigned', c.tier::guarantee_tier, c.tier = 'flex',
       case when c.tier = 'flex' then 2 end
  from d16a_cls c;
-- one booking (paid) on 'booked'; a payment hold on 'hold'; 'committed' is committed
insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source) values
  ('d16a0000-0000-0000-0000-000000000001','d16a0000-0000-0000-0000-00000000c004','d16a0000-0000-0000-0000-0000000000f3','booked','member','comp'),
  ('d16a0000-0000-0000-0000-000000000001','d16a0000-0000-0000-0000-00000000c005','d16a0000-0000-0000-0000-0000000000f3','pending_payment','member','drop_in');
update class_occurrences set booked_count = 1 where id in ('d16a0000-0000-0000-0000-00000000c004','d16a0000-0000-0000-0000-00000000c005');
update class_occurrences set committed_at = now() where id = 'd16a0000-0000-0000-0000-00000000c006';

create or replace function d16a_slots(p_day int) returns table(starts_at timestamptz, replaces uuid, coach_ids uuid[])
language sql as $$
  select s.starts_at, s.replaces_occurrence_id, s.coach_ids
    from private_slots('d16a0000-0000-0000-0000-000000000001','d16a0000-0000-0000-0000-0000000007a1',
                       null, d16a_at(p_day,'00:00'), d16a_at(p_day + 1,'00:00')) s;
$$;
create or replace function d16a_cid(p_k text) returns uuid language sql as $$ select id from d16a_cls where k = p_k $$;

\echo '==== 1. which hours are offered ===='
select expect_true('an empty hour is offered with nothing to replace (day 2, 08:00)',
  exists (select 1 from d16a_slots(2) where starts_at = d16a_at(2,'08:00') and replaces is null));
select expect_true('an empty core class inside the replace window is offered (day 2, 10:00)',
  exists (select 1 from d16a_slots(2) where starts_at = d16a_at(2,'10:00') and replaces = d16a_cid('core_in')));
select expect_true('an empty core class outside the replace window is not offered (day 5, 10:00)',
  not exists (select 1 from d16a_slots(5) where starts_at = d16a_at(5,'10:00')));
select expect_true('an empty flex class is offered at any distance (day 5, 12:00)',
  exists (select 1 from d16a_slots(5) where starts_at = d16a_at(5,'12:00') and replaces = d16a_cid('flex_far')));
select expect_true('a class with one booking is not offered (day 2, 12:00)',
  not exists (select 1 from d16a_slots(2) where starts_at = d16a_at(2,'12:00')));
select expect_true('a class with a payment hold is not offered (day 2, 14:00)',
  not exists (select 1 from d16a_slots(2) where starts_at = d16a_at(2,'14:00')));
select expect_true('a committed class is not offered (day 2, 16:00)',
  not exists (select 1 from d16a_slots(2) where starts_at = d16a_at(2,'16:00')));
select expect_true('a replacement starts with the class: 10:30 on the core class is not offered',
  not exists (select 1 from d16a_slots(2) where starts_at = d16a_at(2,'10:30')));
select expect_text('the displaced coach (Gus) is offered first and is not busy',
  (select coach_ids[1]::text from d16a_slots(2) where starts_at = d16a_at(2,'10:00')),
  'd16a0000-0000-0000-0000-0000000001c2');

\echo '==== 2. replace a core class; the displaced coach teaches it, so nothing is paid ===='
set role authenticated; select set_config('request.jwt.claim.sub','d16a0000-0000-0000-0000-0000000000e1',false);
select set_config('t.r1', private_book('d16a0000-0000-0000-0000-0000000007a1', null, d16a_at(2,'10:00'), '[]'::jsonb, 'pack')::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select set_config('t.p1', current_setting('t.r1')::jsonb ->> 'occurrence_id', false);
select expect_text('replace: the pack booking is confirmed', current_setting('t.r1')::jsonb ->> 'ok', 'true');
select expect_text('replace: the class is cancelled replaced_by_private',
  (select status::text || '/' || cancellation_cause::text from class_occurrences where id = d16a_cid('core_in')),
  'cancelled/replaced_by_private');
select expect_text('replace: the private took the room',
  (select room_id::text from class_occurrences where id = current_setting('t.p1')::uuid),
  'd16a0000-0000-0000-0000-00000000b001');
select expect_text('replace: the displaced coach teaches the private',
  (select instructor_id::text from class_occurrences where id = current_setting('t.p1')::uuid),
  'd16a0000-0000-0000-0000-0000000001c2');
select expect_num('replace: no member email for the replaced class',
  (select count(*) from notifications where recipient_type = 'member'
     and payload ->> 'occurrence_id' = d16a_cid('core_in')::text), 0);
select expect_num('replace: no coach notice when the displaced coach teaches the private',
  (select count(*) from notifications where template_key = 'private_replaced_class'
     and payload ->> 'occurrence_id' = d16a_cid('core_in')::text), 0);
select expect_num('replace: the displaced coach is paid nothing for the replaced class',
  (select amount_cents from instructor_pay_records where occurrence_id = d16a_cid('core_in')), 0);
select expect_num('replace: one audit row',
  (select count(*) from audit_logs where action = 'private.replaced_class' and entity_id = d16a_cid('core_in')), 1);

\echo '==== 3. replace with another coach: core pays the holding fee, flex the standby amount ===='
set role authenticated; select set_config('request.jwt.claim.sub','d16a0000-0000-0000-0000-0000000000e1',false);
select set_config('t.r2', private_book('d16a0000-0000-0000-0000-0000000007a1', 'd16a0000-0000-0000-0000-0000000001c1',
  d16a_at(2,'18:00'), '[]'::jsonb, 'pack')::text, false);
select set_config('t.r3', private_book('d16a0000-0000-0000-0000-0000000007a1', 'd16a0000-0000-0000-0000-0000000001c1',
  d16a_at(4,'10:00'), '[]'::jsonb, 'pack')::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('core paid: the class is replaced', (select cancellation_cause::text from class_occurrences where id = d16a_cid('core_paid')), 'replaced_by_private');
select expect_num('core paid: the displaced coach is paid the core holding fee',
  (select amount_cents from instructor_pay_records where occurrence_id = d16a_cid('core_paid')), 40000);
select expect_num('flex paid: the displaced coach is paid the flex standby amount',
  (select amount_cents from instructor_pay_records where occurrence_id = d16a_cid('flex_paid')), 5000);
select expect_num('another coach: the displaced coach is told (private_replaced_class)',
  (select count(*) from notifications where template_key = 'private_replaced_class'
     and payload ->> 'occurrence_id' = d16a_cid('core_paid')::text), 1);
select expect_true('the coach notice renders with nothing stripped and no token left',
  (select coalesce(array_length(r.stripped, 1), 0) = 0 and r.html_body !~ '\{[a-z_]+\}'
     from notifications n cross join lateral render_notification(n.id) r
    where n.template_key = 'private_replaced_class' and n.payload ->> 'occurrence_id' = d16a_cid('core_paid')::text));

\echo '==== 4. the race: a pending replacement holds the slot; a member books the class; refusal ===='
set role authenticated; select set_config('request.jwt.claim.sub','d16a0000-0000-0000-0000-0000000000e2',false);
select set_config('t.r4', private_book('d16a0000-0000-0000-0000-0000000007a1', null, d16a_at(2,'20:00'), '[]'::jsonb, 'xendit')::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select set_config('t.p4', current_setting('t.r4')::jsonb ->> 'occurrence_id', false);
select set_config('t.pur4', current_setting('t.r4')::jsonb ->> 'purchase_id', false);
select expect_true('race: the pending private takes no room and records the class',
  (select room_id is null and replaces_occurrence_id = d16a_cid('race') from class_occurrences where id = current_setting('t.p4')::uuid));
select expect_true('race: while pending, nobody else is offered that slot',
  not exists (select 1 from d16a_slots(2) where starts_at = d16a_at(2,'20:00')));
set role authenticated; select set_config('request.jwt.claim.sub','d16a0000-0000-0000-0000-0000000000e3',false);
select set_config('t.bk', (book_class('d16a0000-0000-0000-0000-00000000c008', 'd16a0000-0000-0000-0000-0000000000f3', 'member'))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_num('race: the group class stays bookable while the private is pending',
  (select count(*) from bookings where occurrence_id = d16a_cid('race') and member_id = 'd16a0000-0000-0000-0000-0000000000f3'
     and status in ('booked','pending_payment')), 1);
select xendit_activate_success_internal(current_setting('t.pur4')::uuid, 'py-d16a-race');
select expect_text('race: the private is refused (cancelled, time_taken)',
  (select status::text || '/' || cancellation_reason from class_occurrences where id = current_setting('t.p4')::uuid),
  'cancelled/time_taken');
select expect_text('race: the group class is untouched', (select status::text from class_occurrences where id = d16a_cid('race')), 'scheduled');
select expect_num('race: the payment comes back as credit',
  (select sum(amount_cents) from member_credits where member_id = 'd16a0000-0000-0000-0000-0000000000f2' and reason = 'private_refund'), 220000);
select expect_num('race: the member is emailed private_time_taken',
  (select count(*) from notifications where template_key = 'private_time_taken'
     and payload ->> 'occurrence_id' = current_setting('t.p4')), 1);
select expect_true('race: the email says the money is back as credit',
  (select payload ->> 'refund_line' like '%is back on your account as credit.%' from notifications
    where template_key = 'private_time_taken' and payload ->> 'occurrence_id' = current_setting('t.p4')));
select expect_true('race: the refusal email renders with nothing stripped',
  (select coalesce(array_length(r.stripped, 1), 0) = 0 and r.html_body !~ '\{[a-z_]+\}'
     from notifications n cross join lateral render_notification(n.id) r
    where n.template_key = 'private_time_taken' and n.payload ->> 'occurrence_id' = current_setting('t.p4')));
select expect_num('race: one refusal audit row',
  (select count(*) from audit_logs where action = 'private.refused_time_taken' and entity_id = current_setting('t.p4')::uuid), 1);

\echo '==== 5. the state chip fields: 1 of 2, 1 unpaid ===='
-- the race class now holds one booking; add a paid comp seat so the count reads 1 of 2 with 1 unpaid
update bookings set payment_source = 'drop_in', status = 'booked'
 where occurrence_id = d16a_cid('race') and member_id = 'd16a0000-0000-0000-0000-0000000000f3';
insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source) values
  ('d16a0000-0000-0000-0000-000000000001', d16a_cid('race'), 'd16a0000-0000-0000-0000-0000000000f1', 'booked', 'member', 'comp');
select expect_text('schedule_range: paid 1, unpaid 1, minimum 2, not yet running',
  (select occ_paid_count || '/' || occ_unpaid_count || '/' || occ_minimum || '/' || occ_reached_minimum
     from schedule_range('d16a0000-0000-0000-0000-000000000001', (d16a_at(2,'12:00') at time zone 'Asia/Manila')::date,
                         (d16a_at(2,'12:00') at time zone 'Asia/Manila')::date) where occ_id = d16a_cid('race')),
  '1/1/2/false');
select expect_text('schedule_range: a replaced class stays visible with its cause',
  (select occ_cancellation_cause from schedule_range('d16a0000-0000-0000-0000-000000000001',
      (d16a_at(2,'12:00') at time zone 'Asia/Manila')::date, (d16a_at(2,'12:00') at time zone 'Asia/Manila')::date)
    where occ_id = d16a_cid('core_in')), 'replaced_by_private');

\echo '==== 6. apply the flex minimum to future classes ===='
-- three flex classes carrying 3: one open (to update), one committed, one past its cut-off (starts in 6h, 12h deadline)
insert into class_occurrences (id, studio_id, class_type_id, room_id, location_id, name, instructor_id,
     starts_at, ends_at, capacity, status, staffing, guarantee_tier, flex, minimum_bookings, committed_at) values
  ('d16a0000-0000-0000-0000-00000000c010','d16a0000-0000-0000-0000-000000000001','d16a0000-0000-0000-0000-0000000cf001',
   null,'d16a0000-0000-0000-0000-00000000000a','Flex Open',null, d16a_at(6,'09:00'), d16a_at(6,'09:50'), 8,'scheduled','open','flex',true,3,null),
  ('d16a0000-0000-0000-0000-00000000c011','d16a0000-0000-0000-0000-000000000001','d16a0000-0000-0000-0000-0000000cf001',
   null,'d16a0000-0000-0000-0000-00000000000a','Flex Committed',null, d16a_at(6,'11:00'), d16a_at(6,'11:50'), 8,'scheduled','open','flex',true,3,now()),
  ('d16a0000-0000-0000-0000-00000000c012','d16a0000-0000-0000-0000-000000000001','d16a0000-0000-0000-0000-0000000cf001',
   null,'d16a0000-0000-0000-0000-00000000000a','Flex Past Cutoff',null, now() + interval '6 hours', now() + interval '6 hours 50 minutes', 8,'scheduled','open','flex',true,3,null);
select expect_text('front desk cannot count or apply (PT403)',
  d16a_as('d16a0000-0000-0000-0000-0000000000a2', $q$select apply_flex_minimum_to_future('d16a0000-0000-0000-0000-000000000001', 2)$q$)
  || '/' || d16a_as('d16a0000-0000-0000-0000-0000000000a2', $q$select flex_minimum_mismatch_count('d16a0000-0000-0000-0000-000000000001')$q$),
  'PT403/PT403');
select expect_num('apply: one future flex class still carries a different minimum',
  flex_minimum_mismatch_count('d16a0000-0000-0000-0000-000000000001'), 1);
select set_config('t.ap', d16a_as('d16a0000-0000-0000-0000-0000000000a1',
  $q$select apply_flex_minimum_to_future('d16a0000-0000-0000-0000-000000000001', 2)$q$), false);
select expect_text('apply: the owner applies it', current_setting('t.ap'), 'ok');
select expect_num('apply: the open class now carries 2',
  (select minimum_bookings from class_occurrences where id = 'd16a0000-0000-0000-0000-00000000c010'), 2);
select expect_num('apply: the committed class is untouched',
  (select minimum_bookings from class_occurrences where id = 'd16a0000-0000-0000-0000-00000000c011'), 3);
select expect_num('apply: the class past its cut-off is untouched',
  (select minimum_bookings from class_occurrences where id = 'd16a0000-0000-0000-0000-00000000c012'), 3);
select expect_num('apply: nothing left to apply', flex_minimum_mismatch_count('d16a0000-0000-0000-0000-000000000001'), 0);
select expect_true('apply: one audit row with the counts',
  (select after ->> 'classes_updated' = '1' and after ? 'left_committed' and after ? 'left_past_cutoff'
     from audit_logs where action = 'flex.minimum_applied' and studio_id = 'd16a0000-0000-0000-0000-000000000001'));
update studio_settings set flex_min_bookings = 3 where studio_id = 'd16a0000-0000-0000-0000-000000000001';
select expect_true('saving the setting writes an audit row with before and after',
  (select before ->> 'flex_min_bookings' = '2' and after ->> 'flex_min_bookings' = '3'
     from audit_logs where action = 'settings.guarantees_saved' and studio_id = 'd16a0000-0000-0000-0000-000000000001'
    order by created_at desc limit 1));

\echo '==== 7. a month''s submission is not the weekly pattern ===='
-- Pat: a standing Monday 15-20 pattern, and an approved next-month submission Monday 07-09.
select set_config('t.nm', to_char(date_trunc('month', (now() at time zone 'Asia/Manila')::date) + interval '1 month', 'YYYY-MM-DD'), false);
select set_config('t.mon_in', (select d::date::text from generate_series(current_setting('t.nm')::date, current_setting('t.nm')::date + 6, '1 day') d
   where extract(dow from d) = 1), false);
select set_config('t.mon_out', (current_setting('t.mon_in')::date + 35)::text, false);  -- the month after
insert into instructor_availability (studio_id, instructor_id, day_of_week, starts_at_time, ends_at_time, is_available, approval_status)
values ('d16a0000-0000-0000-0000-000000000001','d16a0000-0000-0000-0000-0000000001c3', 1, '15:00', '20:00', true, 'approved');
insert into availability_submissions (id, studio_id, instructor_id, period_start, status, submitted_at)
values ('d16a0000-0000-0000-0000-00000000d001','d16a0000-0000-0000-0000-000000000001','d16a0000-0000-0000-0000-0000000001c3',
        current_setting('t.nm')::date, 'approved', now());
insert into instructor_availability (studio_id, instructor_id, day_of_week, starts_at_time, ends_at_time,
     effective_from, effective_to, is_available, submission_id, approval_status)
values ('d16a0000-0000-0000-0000-000000000001','d16a0000-0000-0000-0000-0000000001c3', 1, '07:00', '09:00',
        current_setting('t.nm')::date, (current_setting('t.nm')::date + interval '1 month' - interval '1 day')::date,
        true, 'd16a0000-0000-0000-0000-00000000d001', 'approved');
select expect_num('the staff editor reads only the pattern (one range on Monday)',
  (select jsonb_array_length(d -> 'ranges') from jsonb_array_elements(
     instructor_availability_week('d16a0000-0000-0000-0000-0000000001c3') -> 'days') d where (d ->> 'day')::int = 1), 1);
select expect_text('a staff pattern save succeeds',
  d16a_as('d16a0000-0000-0000-0000-0000000000a1', $q$select set_instructor_availability('d16a0000-0000-0000-0000-0000000001c3',
     '[{"day":1,"ranges":[{"from":"16:00","to":"20:00"}]}]'::jsonb, null, null)$q$), 'ok');
select expect_num('after the save the submission rows are intact',
  (select count(*) from instructor_availability where submission_id = 'd16a0000-0000-0000-0000-00000000d001'), 1);
select expect_true('the save audit row carries the before ranges',
  (select before -> 'ranges' @> '[{"from":"15:00","to":"20:00"}]'::jsonb from audit_logs
    where action = 'availability.set' and entity_id = 'd16a0000-0000-0000-0000-0000000001c3' order by created_at desc limit 1));
select expect_true('a date in the submission''s month reads the submission (Monday 07:00 yes, 17:00 no)',
  instructor_available_at_run('d16a0000-0000-0000-0000-0000000001c3',
    (current_setting('t.mon_in')::date + time '07:00') at time zone 'Asia/Manila',
    (current_setting('t.mon_in')::date + time '07:50') at time zone 'Asia/Manila')
  and not instructor_available_at_run('d16a0000-0000-0000-0000-0000000001c3',
    (current_setting('t.mon_in')::date + time '17:00') at time zone 'Asia/Manila',
    (current_setting('t.mon_in')::date + time '17:50') at time zone 'Asia/Manila'));
select expect_true('a date outside it reads the pattern (Monday 17:00 yes, 07:00 no)',
  instructor_available_at_run('d16a0000-0000-0000-0000-0000000001c3',
    (current_setting('t.mon_out')::date + time '17:00') at time zone 'Asia/Manila',
    (current_setting('t.mon_out')::date + time '17:50') at time zone 'Asia/Manila')
  and not instructor_available_at_run('d16a0000-0000-0000-0000-0000000001c3',
    (current_setting('t.mon_out')::date + time '07:00') at time zone 'Asia/Manila',
    (current_setting('t.mon_out')::date + time '07:50') at time zone 'Asia/Manila'));
-- Kim: only an approved next-month submission, no pattern: outside that month, nothing stated means available.
insert into availability_submissions (id, studio_id, instructor_id, period_start, status, submitted_at)
values ('d16a0000-0000-0000-0000-00000000d002','d16a0000-0000-0000-0000-000000000001','d16a0000-0000-0000-0000-0000000001c4',
        current_setting('t.nm')::date, 'approved', now());
insert into instructor_availability (studio_id, instructor_id, day_of_week, starts_at_time, ends_at_time,
     effective_from, effective_to, is_available, submission_id, approval_status)
values ('d16a0000-0000-0000-0000-000000000001','d16a0000-0000-0000-0000-0000000001c4', 0, '07:00', '13:00',
        current_setting('t.nm')::date, (current_setting('t.nm')::date + interval '1 month' - interval '1 day')::date,
        true, 'd16a0000-0000-0000-0000-00000000d002', 'approved');
select expect_true('only a next-month submission: a Monday outside it is available (nothing stated)',
  instructor_available_at_run('d16a0000-0000-0000-0000-0000000001c4',
    (current_setting('t.mon_out')::date + time '12:00') at time zone 'Asia/Manila',
    (current_setting('t.mon_out')::date + time '12:50') at time zone 'Asia/Manila'));

\echo '==== 8. surfaces ===='
select expect_num('anon surface is fourteen',
  (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not like 'expect\_%' and p.proname not like 'd16a\_%'), 14);
select expect_true('the new functions are not anon',
  not has_function_privilege('anon', 'apply_flex_minimum_to_future(uuid, integer)', 'execute')
  and not has_function_privilege('anon', 'flex_minimum_mismatch_count(uuid)', 'execute')
  and not has_function_privilege('anon', 'occurrence_empty_run(uuid)', 'execute')
  and not has_function_privilege('authenticated', 'private_replace_ok(uuid, timestamptz)', 'execute'));
select expect_true('the inbox table is closed to anon reads, with RLS on',
  not has_table_privilege('anon', 'resend_webhook_inbox', 'select')
  and (select relrowsecurity from pg_class where relname = 'resend_webhook_inbox'));

\echo 'private_replace_test: all assertions passed'
