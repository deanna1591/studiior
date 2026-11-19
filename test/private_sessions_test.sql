-- =============================================================================
-- Decision 116 — private sessions, and Decision 110 amendment (a) — gift card
-- presentation and corrections (migration 20260833580000). UUID space d116,
-- checked free.
-- =============================================================================
-- Covers: the free-gap computation (hours, lead time, room + buffer, coach time
-- off); a Duo booked through Xendit (pending, hidden, companion invited, webhook
-- confirms at once, no ordinary booking email, private_confirmed x2, private_booked
-- to the coach, the flat duo pay line); the hidden chicken-and-egg (the booker
-- sees it through their own booking, nobody else does, public_schedule never);
-- set_occurrence_visibility refuses to unhide; the Schedule flag; the digest
-- carries the client's first name; the Sales line (VAT, coach pay, studio keeps)
-- and the revenue bucket; a 1:1 pack booking (credit spent, never on a group
-- class, a Duo refused); move once only; cancel late (fee kept, coach paid) and
-- on time (credit back, coach told, coach not paid); the studio cancel (pack back,
-- coach not paid) and the free rebook from credit; the staff desk booking; an
-- unpaid Xendit private released on expiry and never one seat at a time by the
-- drop-in sweep; the five templates render with nothing stripped; the gift card
-- issued at exactly the amount chosen, whole hundreds, the card image on the
-- send, the Apple Pay flag, refund voiding an unredeemed card and refusing a
-- redeemed one, the Account credit split; the PT403s; anon EXACTLY FOURTEEN.
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
-- Run a statement as a signed-in user; return the SQLSTATE it raised, or 'ok'.
create or replace function d116_as(p_user uuid, p_sql text) returns text
language plpgsql as $$
declare v_state text := 'ok';
begin
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  perform set_config('role', 'authenticated', true);
  begin
    execute p_sql;
  exception when others then v_state := sqlstate;
  end;
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claim.sub', '', true);
  return v_state;
end $$;
-- A studio-local wall time on day offset d, as an instant.
create or replace function d116_at(p_days int, p_time time) returns timestamptz
language sql stable as $$
  select (((now() at time zone 'Asia/Manila')::date + p_days) + p_time) at time zone 'Asia/Manila';
$$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('d1160000-0000-0000-0000-0000000000a1'),  -- owner
  ('d1160000-0000-0000-0000-0000000000a2'),  -- front desk
  ('d1160000-0000-0000-0000-0000000000a3'),  -- coach I1 login
  ('d1160000-0000-0000-0000-0000000000e1'),('d1160000-0000-0000-0000-0000000000e2'),
  ('d1160000-0000-0000-0000-0000000000e3'),('d1160000-0000-0000-0000-0000000000e9');
insert into profiles (id, email)
  select id, id::text||'@example.com' from auth.users where id::text like 'd1160000%';

insert into studios (id, name, slug, timezone, currency, status) values
  ('d1160000-0000-0000-0000-000000000001','Private One','d116-s','Asia/Manila','PHP','active'),
  ('d1160000-0000-0000-0000-000000000002','Private Two','d116-t','Asia/Manila','PHP','active');
insert into studio_settings (studio_id, require_waiver, open_time, close_time,
                             private_sessions_enabled, private_lead_time_hours, private_buffer_minutes,
                             gift_enabled) values
  ('d1160000-0000-0000-0000-000000000001', false, '07:00', '21:00', true, 12, 10, true),
  ('d1160000-0000-0000-0000-000000000002', false, '07:00', '21:00', false, 24, 10, false);
insert into locations (id, studio_id, name, is_primary) values
  ('d1160000-0000-0000-0000-00000000000a','d1160000-0000-0000-0000-000000000001','Main',true),
  ('d1160000-0000-0000-0000-00000000000b','d1160000-0000-0000-0000-000000000002','Main',true);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('d1160000-0000-0000-0000-0000000005a1','d1160000-0000-0000-0000-000000000001','d1160000-0000-0000-0000-0000000000a1','d116-ow@example.com','owner'),
  ('d1160000-0000-0000-0000-0000000005a2','d1160000-0000-0000-0000-000000000001','d1160000-0000-0000-0000-0000000000a2','d116-fd@example.com','front_desk'),
  ('d1160000-0000-0000-0000-0000000005a3','d1160000-0000-0000-0000-000000000001','d1160000-0000-0000-0000-0000000000a3','d116-co@example.com','instructor');
insert into instructors (id, studio_id, staff_id, display_name, status, teaches_privates) values
  ('d1160000-0000-0000-0000-0000000001c1','d1160000-0000-0000-0000-000000000001','d1160000-0000-0000-0000-0000000005a3','Ines Coach','active',true),
  ('d1160000-0000-0000-0000-0000000001c2','d1160000-0000-0000-0000-000000000001',null,'Bo Group','active',false);
insert into members (id, studio_id, user_id, first_name, last_name, email, status) values
  ('d1160000-0000-0000-0000-0000000000f1','d1160000-0000-0000-0000-000000000001','d1160000-0000-0000-0000-0000000000e1','Maria','Booker','e1@example.com','active'),
  ('d1160000-0000-0000-0000-0000000000f2','d1160000-0000-0000-0000-000000000001','d1160000-0000-0000-0000-0000000000e2','Nina','Other','e2@example.com','active'),
  ('d1160000-0000-0000-0000-0000000000f3','d1160000-0000-0000-0000-000000000001','d1160000-0000-0000-0000-0000000000e3','Pia','Pack','e3@example.com','active'),
  ('d1160000-0000-0000-0000-0000000000f9','d1160000-0000-0000-0000-000000000002','d1160000-0000-0000-0000-0000000000e9','Tess','Twostudio','e9@example.com','active');
insert into studio_payment_providers
  (studio_id, provider, secret_key_ciphertext, callback_token_ciphertext, callback_token_sha256,
   key_last4, test_mode, connected_by) values
  ('d1160000-0000-0000-0000-000000000001','xendit','v1.x','v1.y',
   encode(digest('tok116','sha256'),'hex'), 'tok0', true, 'd1160000-0000-0000-0000-0000000000a1');
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('d1160000-0000-0000-0000-0000000cf001','d1160000-0000-0000-0000-000000000001','Reformer',50,8);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('d1160000-0000-0000-0000-00000000b001','d1160000-0000-0000-0000-000000000001','d1160000-0000-0000-0000-00000000000a','Only Room',8);
insert into private_session_types (id, studio_id, name, price_cents, people, duration_min, coach_pay_cents, sort) values
  ('d1160000-0000-0000-0000-0000000007a1','d1160000-0000-0000-0000-000000000001','Private 1:1',220000,1,50,100000,1),
  ('d1160000-0000-0000-0000-0000000007a2','d1160000-0000-0000-0000-000000000001','Duo',        300000,2,50,140000,2),
  ('d1160000-0000-0000-0000-0000000007a3','d1160000-0000-0000-0000-000000000001','Trio',       360000,3,50,160000,3);
insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, validity_days,
                              visibility, status, private_pack, restrictions) values
  ('d1160000-0000-0000-0000-0000000008a1','d1160000-0000-0000-0000-000000000001','5 Privates','class_pack',1050000,'PHP',5,null,
   'public','active',true,'{"class_type_ids": ["private-only"]}'::jsonb);
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, credits_remaining, starts_on)
values ('d1160000-0000-0000-0000-0000000009a1','d1160000-0000-0000-0000-000000000001','d1160000-0000-0000-0000-0000000000f3',
        'd1160000-0000-0000-0000-0000000008a1','active',1050000,'PHP',5,current_date);
insert into credit_ledger (studio_id, member_id, membership_id, delta, reason, balance_after)
values ('d1160000-0000-0000-0000-000000000001','d1160000-0000-0000-0000-0000000000f3','d1160000-0000-0000-0000-0000000009a1',5,'purchase',5);

-- A group class on day 3 at 09:00 in the only room (Bo teaches it).
insert into class_occurrences (id, studio_id, class_type_id, room_id, location_id, name, instructor_id,
                               starts_at, ends_at, capacity, status, staffing)
values ('d1160000-0000-0000-0000-00000000c001','d1160000-0000-0000-0000-000000000001','d1160000-0000-0000-0000-0000000cf001',
        'd1160000-0000-0000-0000-00000000b001','d1160000-0000-0000-0000-00000000000a','Reformer Flow',
        'd1160000-0000-0000-0000-0000000001c2', d116_at(3,'09:00'), d116_at(3,'09:50'), 8, 'scheduled','assigned');

-- =============================================================================
-- 1. FREE GAPS: hours, room + buffer, lead time, coach time off.
-- =============================================================================
create temp table d116_slots as
  select starts_at from private_slots('d1160000-0000-0000-0000-000000000001','d1160000-0000-0000-0000-0000000007a1',
         null, d116_at(3,'00:00'), d116_at(4,'00:00'));
select expect_true('slots: 08:00 free (ends 08:50, buffer meets the class edge)',
  exists (select 1 from d116_slots where starts_at = d116_at(3,'08:00')));
select expect_true('slots: 08:30 refused (buffer runs into the 09:00 group class)',
  not exists (select 1 from d116_slots where starts_at = d116_at(3,'08:30')));
select expect_true('slots: 09:00 and 09:30 refused (room busy)',
  not exists (select 1 from d116_slots where starts_at in (d116_at(3,'09:00'), d116_at(3,'09:30'))));
select expect_true('slots: 10:00 free (buffer after the class)',
  exists (select 1 from d116_slots where starts_at = d116_at(3,'10:00')));
select expect_true('slots: nothing before opening (07:00 first)',
  (select min(starts_at) from d116_slots) = d116_at(3,'07:00'));
select expect_true('slots: 20:00 last (a 20:30 start would end after close)',
  (select max(starts_at) from d116_slots) = d116_at(3,'20:00'));
select expect_true('slots: lead time, nothing inside 12 hours from now',
  not exists (select 1 from private_slots('d1160000-0000-0000-0000-000000000001','d1160000-0000-0000-0000-0000000007a1',
     null, now(), now() + interval '12 hours')));
-- coach time off on day 4: no slots with that coach that day
insert into instructor_availability (studio_id, instructor_id, exception_date, is_available)
values ('d1160000-0000-0000-0000-000000000001','d1160000-0000-0000-0000-0000000001c1',
        ((now() at time zone 'Asia/Manila')::date + 4), false);
select expect_num('slots: a coach on time off has no slots that day',
  (select count(*) from private_slots('d1160000-0000-0000-0000-000000000001','d1160000-0000-0000-0000-0000000007a1',
     'd1160000-0000-0000-0000-0000000001c1', d116_at(4,'00:00'), d116_at(5,'00:00'))), 0);
-- a coach already teaching a group class in ANOTHER room is not offered then
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('d1160000-0000-0000-0000-00000000b002','d1160000-0000-0000-0000-000000000001','d1160000-0000-0000-0000-00000000000a','Second Room',8);
insert into class_occurrences (id, studio_id, class_type_id, room_id, location_id, name, instructor_id,
                               starts_at, ends_at, capacity, status, staffing)
values ('d1160000-0000-0000-0000-00000000c002','d1160000-0000-0000-0000-000000000001','d1160000-0000-0000-0000-0000000cf001',
        'd1160000-0000-0000-0000-00000000b002','d1160000-0000-0000-0000-00000000000a','Ines Group',
        'd1160000-0000-0000-0000-0000000001c1', d116_at(5,'09:00'), d116_at(5,'09:50'), 8, 'scheduled','assigned');
select expect_true('slots: a coach teaching elsewhere is not offered (room 1 free at 09:00 day 5)',
  not exists (select 1 from private_slots('d1160000-0000-0000-0000-000000000001','d1160000-0000-0000-0000-0000000007a1',
     null, d116_at(5,'00:00'), d116_at(6,'00:00')) where starts_at = d116_at(5,'09:00')));
select expect_text('book: a busy chosen coach is refused coach_busy before anything is created',
  (private_book_run('d1160000-0000-0000-0000-0000000000f2','d1160000-0000-0000-0000-0000000007a1',
     'd1160000-0000-0000-0000-0000000001c1', d116_at(5,'09:00'), '[]'::jsonb, 'xendit') ->> 'reason'), 'coach_busy');
select expect_text('slots: a stranger is refused (PT403)',
  d116_as('d1160000-0000-0000-0000-0000000000e9',
    $q$select * from private_slots('d1160000-0000-0000-0000-000000000001','d1160000-0000-0000-0000-0000000007a1',null,now(),now()+interval '3 days')$q$),
  'PT403');

-- =============================================================================
-- 2. A DUO THROUGH XENDIT.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','d1160000-0000-0000-0000-0000000000e1',false);
select set_config('t.duo', private_book('d1160000-0000-0000-0000-0000000007a2', 'd1160000-0000-0000-0000-0000000001c1',
  d116_at(3,'11:00'), '[{"name":"Carla Friend","email":"carla.d116@example.com"}]'::jsonb, 'xendit')::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select set_config('t.occ', current_setting('t.duo')::jsonb ->> 'occurrence_id', false);
select set_config('t.pur', current_setting('t.duo')::jsonb ->> 'purchase_id', false);
select expect_text('duo: begins pending with a purchase', current_setting('t.duo')::jsonb ->> 'confirmed', 'false');
select expect_true('duo: the occurrence is private and hidden',
  (select is_private and hidden_from_members and class_type_id is null and capacity = 2
     from class_occurrences where id = current_setting('t.occ')::uuid));
select expect_text('duo: the name carries the client first name',
  (select name from class_occurrences where id = current_setting('t.occ')::uuid), 'Duo · Maria');
select expect_num('duo: two pending seats',
  (select count(*) from bookings where occurrence_id = current_setting('t.occ')::uuid and status = 'pending_payment'), 2);
select expect_text('duo: the companion is a lead member',
  (select status::text from members where email = 'carla.d116@example.com'), 'lead');
select expect_num('duo: wrong companion count refused',
  (select count(*) from (select 1) x where (
    (select private_book_run('d1160000-0000-0000-0000-0000000000f2','d1160000-0000-0000-0000-0000000007a2',null,
       d116_at(5,'10:00'), '[]'::jsonb, 'xendit') ->> 'reason') = 'wrong_companion_count')), 1);
-- a pending private is never one seat at a time for the drop-in sweep
update bookings set booked_at = now() - interval '2 hours' where occurrence_id = current_setting('t.occ')::uuid;
select sweep_unpaid_dropins();
select expect_num('duo: the drop-in sweep leaves a private''s pending seats alone',
  (select count(*) from bookings where occurrence_id = current_setting('t.occ')::uuid and status = 'pending_payment'), 2);

-- the webhook confirms
select xendit_activate_success_internal(current_setting('t.pur')::uuid, 'py-d116-duo');
select expect_true('duo: committed at once',
  (select committed_at is not null from class_occurrences where id = current_setting('t.occ')::uuid));
select expect_num('duo: both seats booked',
  (select count(*) from bookings where occurrence_id = current_setting('t.occ')::uuid and status = 'booked'), 2);
select expect_num('duo: one succeeded private payment of 300000',
  (select sum(amount_cents) from payments p join bookings b on b.id = p.booking_id
    where b.occurrence_id = current_setting('t.occ')::uuid and p.kind = 'private' and p.status = 'succeeded'), 300000);
select expect_num('duo: private_confirmed to booker and companion',
  (select count(*) from notifications where template_key = 'private_confirmed'
    and payload ->> 'occurrence_id' = current_setting('t.occ')), 2);
select expect_true('duo: the companion''s email carries a claim link',
  (select payload ->> 'claim_url' like 'https://d116-s.%/claim/%' from notifications n
     join members m on m.id = n.member_id
    where n.template_key = 'private_confirmed' and m.email = 'carla.d116@example.com'));
select expect_num('duo: no ordinary booking_confirmed for a private',
  (select count(*) from notifications n join bookings b on b.member_id = n.member_id
    where b.occurrence_id = current_setting('t.occ')::uuid and n.template_key = 'booking_confirmed'), 0);
select expect_num('duo: private_booked to the coach login',
  (select count(*) from notifications where template_key = 'private_booked'
    and user_id = 'd1160000-0000-0000-0000-0000000000a3' and payload ->> 'occurrence_id' = current_setting('t.occ')), 1);
select expect_num('duo: the coach is paid the flat duo rate',
  (select amount_cents from instructor_pay_records where occurrence_id = current_setting('t.occ')::uuid and type = 'class'), 140000);
select expect_text('duo: the pay line is kind duo with no rate version',
  (select (basis ->> 'kind') || ':' || coalesce(rate_version_id::text, 'none')
     from instructor_pay_records where occurrence_id = current_setting('t.occ')::uuid), 'duo:none');
select expect_true('duo: an audit row for the booking',
  exists (select 1 from audit_logs where entity_id = current_setting('t.occ')::uuid and action = 'private.booked'));

-- =============================================================================
-- 3. HIDDEN: the booker sees it through their own booking; nobody else does.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','d1160000-0000-0000-0000-0000000000e1',false);
select expect_num('hidden: the booker sees their private', (select count(*) from class_occurrences where id = current_setting('t.occ')::uuid), 1);
select set_config('request.jwt.claim.sub','d1160000-0000-0000-0000-0000000000e2',false);
select expect_num('hidden: another member does not', (select count(*) from class_occurrences where id = current_setting('t.occ')::uuid), 0);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_true('hidden: public_schedule never lists it',
  not (public_schedule('d116-s') -> 'classes') @> jsonb_build_array(jsonb_build_object('id', current_setting('t.occ'))));
select expect_text('hidden: unhiding a private is refused (PT409)',
  d116_as('d1160000-0000-0000-0000-0000000000a1',
    format('select set_occurrence_visibility(%L, true)', current_setting('t.occ'))), 'PT409');
select expect_true('schedule: the staff Schedule flags it private',
  (select occ_is_private from schedule_range('d1160000-0000-0000-0000-000000000001',
     (now() at time zone 'Asia/Manila')::date + 3, (now() at time zone 'Asia/Manila')::date + 3)
    where occ_id = current_setting('t.occ')::uuid));
select expect_true('digest: the coach''s Running list names the client',
  (instructor_digest_block('d1160000-0000-0000-0000-000000000001','d1160000-0000-0000-0000-0000000001c1',
     (now() at time zone 'Asia/Manila')::date + 3) ->> 'going_ahead') like '%Duo · Maria%');

-- =============================================================================
-- 4. SALES: the Private sessions line and the revenue bucket.
-- =============================================================================
select set_config('t.st', sales_totals('d1160000-0000-0000-0000-000000000001',
  (now() at time zone 'Asia/Manila')::date - 1, (now() at time zone 'Asia/Manila')::date + 1)::text, false);
select expect_num('sales: one private sold', (current_setting('t.st')::jsonb -> 'private' ->> 'count')::bigint, 1);
select expect_num('sales: price 300000', (current_setting('t.st')::jsonb -> 'private' ->> 'total_cents')::bigint, 300000);
select expect_num('sales: after VAT 267857 (12 percent inclusive)', (current_setting('t.st')::jsonb -> 'private' ->> 'after_vat_cents')::bigint, 267857);
select expect_num('sales: coach pay 140000', (current_setting('t.st')::jsonb -> 'private' ->> 'coach_pay_cents')::bigint, 140000);
select expect_num('sales: studio keeps 160000', (current_setting('t.st')::jsonb -> 'private' ->> 'studio_keeps_cents')::bigint, 160000);
select expect_num('sales: the history lists it as a private',
  (select count(*) from sales_history('d1160000-0000-0000-0000-000000000001',
     (now() at time zone 'Asia/Manila')::date - 1, (now() at time zone 'Asia/Manila')::date + 1) where plan_type = 'private'), 1);
select expect_true('revenue: Private sessions bucket',
  (dashboard_revenue('d1160000-0000-0000-0000-000000000001',
     (now() at time zone 'Asia/Manila')::date, (now() at time zone 'Asia/Manila')::date) -> 'by_source')
   @> '[{"source":"private"}]');

-- =============================================================================
-- 5. A 1:1 PACK: credit spent, never on a group class, never a Duo.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','d1160000-0000-0000-0000-0000000000e3',false);
select set_config('t.pk', private_book('d1160000-0000-0000-0000-0000000007a1', null, d116_at(3,'15:00'), '[]'::jsonb, 'pack')::text, false);
select set_config('t.pkduo', private_book('d1160000-0000-0000-0000-0000000007a2', null, d116_at(3,'17:00'),
  '[{"name":"Al","email":"al.d116@example.com"}]'::jsonb, 'pack')::text, false);
select set_config('t.grp', (book_class('d1160000-0000-0000-0000-00000000c001', 'd1160000-0000-0000-0000-0000000000f3', 'member'))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select set_config('t.pkocc', current_setting('t.pk')::jsonb ->> 'occurrence_id', false);
select expect_text('pack: confirmed at once', current_setting('t.pk')::jsonb ->> 'confirmed', 'true');
select expect_num('pack: one credit spent (5 -> 4)',
  (select credits_remaining from memberships where id = 'd1160000-0000-0000-0000-0000000009a1'), 4);
select expect_text('pack: a Duo cannot use a 1:1 pack', current_setting('t.pkduo')::jsonb ->> 'reason', 'pack_1to1_only');
select expect_true('pack: a group class never draws on a private pack',
  (select payment_source::text <> 'class_pack' and membership_id is null from bookings
    where occurrence_id = 'd1160000-0000-0000-0000-00000000c001' and member_id = 'd1160000-0000-0000-0000-0000000000f3'));
select expect_num('pack: still 4 after the group booking',
  (select credits_remaining from memberships where id = 'd1160000-0000-0000-0000-0000000009a1'), 4);
select expect_num('pack: the coach is paid the 1:1 rate',
  (select amount_cents from instructor_pay_records where occurrence_id = current_setting('t.pkocc')::uuid), 100000);
set role authenticated; select set_config('request.jwt.claim.sub','d1160000-0000-0000-0000-0000000000e3',false);
select set_config('t.bs3', (select private_pack_credits::text || ':' || private_sessions_enabled::text from member_bootstrap('d116-s')), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('bootstrap: private pack credits and the Book entry', current_setting('t.bs3'), '4:true');

-- =============================================================================
-- 6. MOVE once; CANCEL late (fee kept, coach paid) and on time (credit back).
-- =============================================================================
select expect_text('move: the booker moves once',
  d116_as('d1160000-0000-0000-0000-0000000000e1', format('select private_move(%L, %L)', current_setting('t.occ'), d116_at(3,'13:00'))), 'ok');
select expect_true('move: the occurrence moved', (select starts_at = d116_at(3,'13:00') from class_occurrences where id = current_setting('t.occ')::uuid));
select expect_num('move: private_moved to both seats',
  (select count(*) from notifications where template_key = 'private_moved' and payload ->> 'type_name' = 'Duo'), 2);
set role authenticated; select set_config('request.jwt.claim.sub','d1160000-0000-0000-0000-0000000000e1',false);
select set_config('t.mv2', private_move(current_setting('t.occ')::uuid, d116_at(3,'14:00'))::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('move: a second move is refused', current_setting('t.mv2')::jsonb ->> 'reason', 'already_moved');
select expect_text('cancel: another member cannot cancel it (PT403)',
  d116_as('d1160000-0000-0000-0000-0000000000e2', format('select private_cancel(%L)', current_setting('t.occ'))), 'PT403');

-- late: Pia's 1:1, pulled inside the lead time
update class_occurrences set starts_at = now() + interval '5 hours', ends_at = now() + interval '5 hours 50 minutes'
 where id = current_setting('t.pkocc')::uuid;
set role authenticated; select set_config('request.jwt.claim.sub','d1160000-0000-0000-0000-0000000000e3',false);
select set_config('t.late', private_cancel(current_setting('t.pkocc')::uuid)::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('cancel late: not on time', current_setting('t.late')::jsonb ->> 'on_time', 'false');
select expect_text('cancel late: the seat is a late cancel',
  (select status::text from bookings where occurrence_id = current_setting('t.pkocc')::uuid), 'late_cancelled');
select expect_num('cancel late: the pack credit is kept (still 4)',
  (select credits_remaining from memberships where id = 'd1160000-0000-0000-0000-0000000009a1'), 4);
select expect_num('cancel late: the coach is still paid',
  (select count(*) from instructor_pay_records where occurrence_id = current_setting('t.pkocc')::uuid), 1);

-- on time: Maria's Duo (13:00 on day 3, far outside 12 hours)
set role authenticated; select set_config('request.jwt.claim.sub','d1160000-0000-0000-0000-0000000000e1',false);
select set_config('t.ot', private_cancel(current_setting('t.occ')::uuid)::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('cancel on time: on time', current_setting('t.ot')::jsonb ->> 'on_time', 'true');
select expect_text('cancel on time: the occurrence is cancelled',
  (select status::text from class_occurrences where id = current_setting('t.occ')::uuid), 'cancelled');
select expect_num('cancel on time: the 300000 is back as credit',
  (select sum(amount_cents) from member_credits where member_id = 'd1160000-0000-0000-0000-0000000000f1' and reason = 'private_refund'), 300000);
select expect_num('cancel on time: the coach is not paid',
  (select count(*) from instructor_pay_records where occurrence_id = current_setting('t.occ')::uuid), 0);
select expect_num('cancel on time: the coach is told it is off',
  (select count(*) from notifications where template_key = 'instructor_class_cancelled' and payload ->> 'occurrence_id' = current_setting('t.occ')), 1);
select expect_num('cancel on time: no false "pay unchanged" to the coach',
  (select count(*) from notifications where template_key = 'booking_cancelled_committed' and payload::text like '%' || current_setting('t.occ') || '%'), 0);
select expect_num('cancel on time: private_cancelled to both',
  (select count(*) from notifications where template_key = 'private_cancelled' and dedupe_key like '%' || current_setting('t.occ')), 2);

-- =============================================================================
-- 7. FREE REBOOK FROM CREDIT; STUDIO CANCEL; DESK BOOKING.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','d1160000-0000-0000-0000-0000000000e1',false);
select set_config('t.rb', private_book('d1160000-0000-0000-0000-0000000007a1', null, d116_at(5,'10:00'), '[]'::jsonb, 'xendit')::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('rebook: account credit covers it, no checkout', current_setting('t.rb')::jsonb ->> 'mode', 'credit');
select expect_num('rebook: 220000 of the credit used',
  (select sum(used_cents) from member_credits where member_id = 'd1160000-0000-0000-0000-0000000000f1'), 220000);
select expect_text('rebook: the payment is source credit (not a sale)',
  (select p.source from payments p join bookings b on b.id = p.booking_id
    where b.occurrence_id = (current_setting('t.rb')::jsonb ->> 'occurrence_id')::uuid), 'credit');

set role authenticated; select set_config('request.jwt.claim.sub','d1160000-0000-0000-0000-0000000000e3',false);
select set_config('t.sc', private_book('d1160000-0000-0000-0000-0000000007a1', null, d116_at(6,'10:00'), '[]'::jsonb, 'pack')::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_num('studio cancel: pack at 3 after the booking',
  (select credits_remaining from memberships where id = 'd1160000-0000-0000-0000-0000000009a1'), 3);
select expect_text('studio cancel: front desk cannot (PT403)',
  d116_as('d1160000-0000-0000-0000-0000000000a2', format('select private_studio_cancel(%L, %L)',
    current_setting('t.sc')::jsonb ->> 'occurrence_id', 'Coach unwell')), 'PT403');
select expect_text('studio cancel: the owner can',
  d116_as('d1160000-0000-0000-0000-0000000000a1', format('select private_studio_cancel(%L, %L)',
    current_setting('t.sc')::jsonb ->> 'occurrence_id', 'Coach unwell')), 'ok');
select expect_num('studio cancel: the pack credit is back (3 -> 4)',
  (select credits_remaining from memberships where id = 'd1160000-0000-0000-0000-0000000009a1'), 4);
select expect_num('studio cancel: the coach is not paid',
  (select count(*) from instructor_pay_records where occurrence_id = (current_setting('t.sc')::jsonb ->> 'occurrence_id')::uuid), 0);
select expect_num('studio cancel: private_studio_cancelled sent',
  (select count(*) from notifications where template_key = 'private_studio_cancelled'), 1);

select expect_text('desk: a member cannot book at the desk (PT403)',
  d116_as('d1160000-0000-0000-0000-0000000000e2', format('select private_book_desk(%L,%L,null,%L)',
    'd1160000-0000-0000-0000-0000000000f2','d1160000-0000-0000-0000-0000000007a1', d116_at(5,'14:00'))), 'PT403');
set role authenticated; select set_config('request.jwt.claim.sub','d1160000-0000-0000-0000-0000000000a2',false);
select set_config('t.dk', private_book_desk('d1160000-0000-0000-0000-0000000000f2','d1160000-0000-0000-0000-0000000007a1',
  null, d116_at(5,'14:00'), '[]'::jsonb, 'cash', 'OR-116')::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('desk: confirmed at once', current_setting('t.dk')::jsonb ->> 'confirmed', 'true');
select expect_text('desk: a cash payment recorded by the desk',
  (select p.method || ':' || p.provider::text || ':' || (p.recorded_by = 'd1160000-0000-0000-0000-0000000000a2')::text
     from payments p join bookings b on b.id = p.booking_id
    where b.occurrence_id = (current_setting('t.dk')::jsonb ->> 'occurrence_id')::uuid), 'cash:manual:true');

-- =============================================================================
-- 8. AN UNPAID XENDIT PRIVATE IS RELEASED ON EXPIRY.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','d1160000-0000-0000-0000-0000000000e2',false);
select set_config('t.un', private_book('d1160000-0000-0000-0000-0000000007a1', null, d116_at(6,'16:00'), '[]'::jsonb, 'xendit')::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select xendit_fail_purchase_internal((current_setting('t.un')::jsonb ->> 'purchase_id')::uuid, 'expired', 'test');
select expect_text('release: the unpaid private is cancelled',
  (select status::text from class_occurrences where id = (current_setting('t.un')::jsonb ->> 'occurrence_id')::uuid), 'cancelled');
select expect_true('release: the room is free again at that time',
  exists (select 1 from private_slots('d1160000-0000-0000-0000-000000000001','d1160000-0000-0000-0000-0000000007a1',
    null, d116_at(6,'16:00'), d116_at(6,'17:00')) where starts_at = d116_at(6,'16:00')));

-- =============================================================================
-- 9. TEMPLATES render with nothing stripped.
-- =============================================================================
select expect_num('templates: the five private templates exist',
  (select count(*) from notification_templates where key in
   ('private_confirmed','private_booked','private_moved','private_cancelled','private_studio_cancelled')), 5);
select expect_num('templates: every queued private email renders with nothing stripped',
  (select count(*) from notifications n
     cross join lateral render_notification(n.id) r
    where n.studio_id = 'd1160000-0000-0000-0000-000000000001' and n.template_key like 'private_%'
      and (coalesce(array_length(r.stripped, 1), 0) > 0 or r.html_body like '%{%_%}%' and r.html_body ~ '\{[a-z_]+\}')), 0);

-- =============================================================================
-- 10. PT403s and setup.
-- =============================================================================
select expect_text('pt403: a member of another studio cannot book here',
  d116_as('d1160000-0000-0000-0000-0000000000e9', format('select private_book(%L,null,%L)',
    'd1160000-0000-0000-0000-0000000007a1', d116_at(7,'10:00'))), 'PT403');
select expect_text('setup: front desk cannot save a type (PT403)',
  d116_as('d1160000-0000-0000-0000-0000000000a2', format('select private_type_save(%L,null,%L,1000,1,50,500)',
    'd1160000-0000-0000-0000-000000000001', 'X')), 'PT403');
select expect_text('setup: a fourth active type is refused (PT409)',
  d116_as('d1160000-0000-0000-0000-0000000000a1', format('select private_type_save(%L,null,%L,1000,1,50,500)',
    'd1160000-0000-0000-0000-000000000001', 'Fourth')), 'PT409');
select expect_num('setup: a studio with privates off offers no types',
  (select count(*) from private_session_types_for('d1160000-0000-0000-0000-000000000002')), 0);

-- =============================================================================
-- 11. GIFT (110a): exact amount, whole hundreds, the card image, Apple Pay, refund.
-- =============================================================================
do $$ begin
  perform gift_card_begin('d1160000-0000-0000-0000-000000000001', 50050,
     'Buyer','b.d116@example.com','Rita','r.d116@example.com',null,null);
  raise exception 'FAIL  gift: 50050 should be refused';
exception when sqlstate 'PT422' then raise notice 'PASS  gift: 50050 refused (PT422)';
end $$;
select set_config('t.g', (select purchase_id::text from gift_card_begin('d1160000-0000-0000-0000-000000000001', 250000,
  'Buyer','b.d116@example.com','Rita','r.d116@example.com','Enjoy!',null)), false);
select expect_text('gift: Apple Pay is not verified by default',
  (select apple_pay_verified::text from gift_card_begin('d1160000-0000-0000-0000-000000000001', 100000,
     'Buyer2','b2.d116@example.com','Rex','x.d116@example.com',null,null)), 'false');
select xendit_activate_success_internal(current_setting('t.g')::uuid, 'py-d116-gift');
select set_config('t.gc', (select gift_card_id::text from xendit_purchases where id = current_setting('t.g')::uuid), false);
select expect_num('gift: issued at exactly the amount chosen',
  (select amount_cents from gift_cards where id = current_setting('t.gc')::uuid), 250000);
select expect_true('gift: the composited card path is stored at issue',
  (select card_image_path like '/giftcard/%/' || code || '/250000' from gift_cards where id = current_setting('t.gc')::uuid));
select expect_true('gift: gift_card_sent carries the card image and the new subject renders',
  (select (n.payload ->> 'card_image_url') like 'https://d116-s.%/giftcard/%' and r.subject = 'A gift of Pilates from Buyer at Private One'
       and r.html_body like '%<img src="https://d116-s.%' and coalesce(array_length(r.stripped,1),0) = 0
     from notifications n cross join lateral render_notification(n.id) r
    where n.template_key = 'gift_card_sent' and n.dedupe_key = 'gift_card_sent:' || current_setting('t.gc')));
-- refund the unredeemed card: it is voided
select set_config('t.gp', (select id::text from payments where gift_card_id = current_setting('t.gc')::uuid), false);
select expect_text('gift refund: unredeemed card refund succeeds',
  d116_as('d1160000-0000-0000-0000-0000000000a1', format('select refund_payment(%L, null, %L, %L, %L)',
    current_setting('t.gp'), 'changed mind', 'cash', 'R-116')), 'ok');
select expect_text('gift refund: the card is void', (select status from gift_cards where id = current_setting('t.gc')::uuid), 'void');
-- a redeemed card cannot be refunded; the credit split shows gift credit
select set_config('t.g2', (select purchase_id::text from gift_card_begin('d1160000-0000-0000-0000-000000000001', 100000,
  'Buyer3','b3.d116@example.com','Nina','e2@example.com',null,null)), false);
select xendit_activate_success_internal(current_setting('t.g2')::uuid, 'py-d116-gift2');
select set_config('t.gc2', (select gift_card_id::text from xendit_purchases where id = current_setting('t.g2')::uuid), false);
select expect_text('gift: Nina redeems the card',
  d116_as('d1160000-0000-0000-0000-0000000000e2', format('select gift_card_redeem(%L)',
    (select code from gift_cards where id = current_setting('t.gc2')::uuid))), 'ok');
select expect_text('gift refund: a redeemed card is refused (PT409)',
  d116_as('d1160000-0000-0000-0000-0000000000a1', format('select refund_payment(%L, null, %L, %L, %L)',
    (select id from payments where gift_card_id = current_setting('t.gc2')::uuid), 'x', 'cash', 'R-2')), 'PT409');
set role authenticated; select set_config('request.jwt.claim.sub','d1160000-0000-0000-0000-0000000000e2',false);
select set_config('t.bs2', (select gift_credit_cents::text || ':' || reservation_credit_cents::text || ':' || gift_enabled::text
  from member_bootstrap('d116-s')), false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('credits: gift credit named apart from the total', current_setting('t.bs2'), '100000:100000:true');

-- =============================================================================
-- 12. ANON STAYS EXACTLY FOURTEEN.
-- =============================================================================
select expect_num('anon surface is exactly fourteen',
  (select count(*) from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
    where ns.nspname='public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not in ('expect_num','expect_text','expect_true','d116_as','d116_at')), 14);

select 'private_sessions_test PASS' as result;
