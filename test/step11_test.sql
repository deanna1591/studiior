-- =============================================================================
-- Step 11 (migration 365): Decision 103 (i) the reservation state is always
-- visible, (j) a seat is released only after it was asked for, (k) staff paths
-- ask for the fee at booking; Decision 21 (e) a day tier switch clears stale
-- latches; Decision 89 (b) message paragraphs; Decision 108 (a) two pay
-- watchdogs; Decision 80 note, three email tokens.
-- UUID space b11a, checked free. Run after `supabase db reset`.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_eq(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if coalesce(actual, false) then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_err(label text, sql text, code text)
returns void language plpgsql as $$
begin
  execute sql;
  raise exception 'FAIL  %  expected error %, got none', label, code;
exception when others then
  if sqlstate = code then raise notice 'PASS  %  (raised %)', label, code;
  else raise exception 'FAIL  %  expected %, got % %', label, code, sqlstate, sqlerrm; end if;
end $$;

-- --- studio, logins ----------------------------------------------------------
insert into auth.users (id) values
  ('b11a0000-0000-0000-0000-0000000000a1'),   -- owner
  ('b11a0000-0000-0000-0000-0000000000f1'),   -- front desk
  ('b11a0000-0000-0000-0000-0000000000c1');   -- a member login (self call)
insert into profiles (id, email, full_name) values
  ('b11a0000-0000-0000-0000-0000000000a1','b11a-owner@example.com','Olive Owner'),
  ('b11a0000-0000-0000-0000-0000000000f1','b11a-desk@example.com','Dee Desk'),
  ('b11a0000-0000-0000-0000-0000000000c1','b11a-self@example.com','Sam Self');

insert into studios (id, name, slug, timezone, currency, status) values
  ('b11a0000-0000-0000-0000-0000000000a0','Step Eleven','b11a-s','Asia/Manila','PHP','active'),
  ('b11a0000-0000-0000-0000-0000000000b0','No Fee','b11a-z','Asia/Manila','PHP','active');
insert into studio_settings (studio_id, guarantees_enabled, flex_enabled, flex_min_bookings,
       flex_deadline_mode, flex_deadline_time, flex_deadline_hours, time_format,
       free_first_class_enabled, free_first_reservation_fee_cents, free_first_reservation_from,
       cancellation_cutoff_minutes, booking_cutoff_minutes, checkin_window_enforced, require_waiver)
values ('b11a0000-0000-0000-0000-0000000000a0', true, true, 2, 'previous_day_at', '20:00', 12, '12h',
        true, 50000, current_date - 10, 720, 0, false, false),
       ('b11a0000-0000-0000-0000-0000000000b0', true, true, 2, 'previous_day_at', '20:00', 12, '12h',
        true, 0, null, 720, 0, false, false);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('b11a0000-0000-0000-0000-0000000005a1','b11a0000-0000-0000-0000-0000000000a0','b11a0000-0000-0000-0000-0000000000a1','b11a-owner@example.com','owner'),
  ('b11a0000-0000-0000-0000-0000000005f1','b11a0000-0000-0000-0000-0000000000a0','b11a0000-0000-0000-0000-0000000000f1','b11a-desk@example.com','front_desk'),
  ('b11a0000-0000-0000-0000-0000000005b1','b11a0000-0000-0000-0000-0000000000b0','b11a0000-0000-0000-0000-0000000000f1','b11a-desk@example.com','front_desk');

insert into locations (id, studio_id, name, is_primary) values
  ('b11a0000-0000-0000-0000-00000000010c','b11a0000-0000-0000-0000-0000000000a0','Main', true),
  ('b11a0000-0000-0000-0000-00000000020c','b11a0000-0000-0000-0000-0000000000b0','Main', true);
insert into rooms (id, studio_id, location_id, name, capacity)
select ('b11a0000-0000-0000-0000-0000000001'||lpad(n::text,2,'0'))::uuid, 'b11a0000-0000-0000-0000-0000000000a0',
       'b11a0000-0000-0000-0000-00000000010c', 'Room '||n, 10
  from generate_series(1,12) n;
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('b11a0000-0000-0000-0000-0000000002b1','b11a0000-0000-0000-0000-0000000000b0','b11a0000-0000-0000-0000-00000000020c','Z Room',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity, session_kind) values
  ('b11a0000-0000-0000-0000-0000000cc001','b11a0000-0000-0000-0000-0000000000a0','Reformer',50,10,'group'),
  ('b11a0000-0000-0000-0000-0000000cc002','b11a0000-0000-0000-0000-0000000000b0','Reformer',50,10,'group');
insert into instructors (id, studio_id, display_name, status) values
  ('b11a0000-0000-0000-0000-0000000a00c1','b11a0000-0000-0000-0000-0000000000a0','Cora Coach','active');

insert into members (id, studio_id, first_name, last_name, email, status, waiver_signed_at)
select ('b11a0000-0000-0000-0000-0000000d00'||lpad(n::text,2,'0'))::uuid, 'b11a0000-0000-0000-0000-0000000000a0',
       'M'||n, 'N'||n, 'b11a-'||n||'@example.com', 'lead', now()
  from generate_series(1,40) n;
insert into members (id, studio_id, user_id, first_name, last_name, email, status) values
  ('b11a0000-0000-0000-0000-0000000d0099','b11a0000-0000-0000-0000-0000000000a0','b11a0000-0000-0000-0000-0000000000c1','Sam','Self','b11a-self@example.com','lead'),
  ('b11a0000-0000-0000-0000-0000000d0098','b11a0000-0000-0000-0000-0000000000b0',null,'Zed','Zero','b11a-zero@example.com','lead');

-- one occurrence per letter: a distinct room each so nothing overlaps.
create or replace function mk_occ(p_id text, p_room int, p_name text, p_starts timestamptz, p_flex boolean default false,
                                  p_min int default null)
returns uuid language plpgsql as $$
declare v uuid := ('b11a0000-0000-0000-0000-00000000'||p_id)::uuid;
begin
  insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
         starts_at, ends_at, capacity, booked_count, status, flex, minimum_bookings)
  values (v, 'b11a0000-0000-0000-0000-0000000000a0', 'b11a0000-0000-0000-0000-00000000010c',
          'b11a0000-0000-0000-0000-0000000cc001',
          ('b11a0000-0000-0000-0000-0000000001'||lpad(p_room::text,2,'0'))::uuid,
          p_name, p_starts, p_starts + interval '50 min', 10, 0, 'scheduled', p_flex, p_min);
  return v;
end $$;
-- a free first class seat: comp booking + the host-null once-ever pass.
create or replace function mk_free(p_member int, p_occ uuid)
returns uuid language plpgsql as $$
declare b uuid; m uuid := ('b11a0000-0000-0000-0000-0000000d00'||lpad(p_member::text,2,'0'))::uuid;
begin
  insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source)
  values ('b11a0000-0000-0000-0000-0000000000a0', p_occ, m, 'booked', 'member', 'comp') returning id into b;
  insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email, occurrence_id, guest_booking_id, status)
  values ('b11a0000-0000-0000-0000-0000000000a0', null, m, 'b11a-'||p_member||'@example.com', p_occ, b, 'confirmed');
  return b;
end $$;
create or replace function mk_due(p_booking uuid, p_member int, p_status text, p_created timestamptz, p_suffix text default '')
returns void language plpgsql as $$
begin
  insert into notifications (studio_id, member_id, recipient_type, template_key, channel, dedupe_key,
                             scheduled_for, status, created_at, sent_at, failed_at)
  values ('b11a0000-0000-0000-0000-0000000000a0', ('b11a0000-0000-0000-0000-0000000d00'||lpad(p_member::text,2,'0'))::uuid,
          'member', 'free_reservation_due', 'email', 'free_reservation_due:'||p_booking||p_suffix,
          p_created, p_status::notif_status, p_created,
          case when p_status = 'sent' then p_created end,
          case when p_status = 'failed' then p_created end);
end $$;

-- =============================================================================
-- 1. Decision 103 (i): the five chip states, the Flex pending line, the card
-- =============================================================================
select mk_occ('0c01', 1, 'Chip Flex', now() + interval '3 days', true, 2);
do $$ declare b uuid; begin
  b := mk_free(1, 'b11a0000-0000-0000-0000-000000000c01'::uuid);   -- paid
  insert into payments (studio_id, member_id, booking_id, kind, amount_cents, currency, status, provider, paid_at)
  values ('b11a0000-0000-0000-0000-0000000000a0', 'b11a0000-0000-0000-0000-0000000d0001', b, 'reservation_fee', 50000, 'PHP', 'succeeded', 'manual', now());
  perform set_config('t.c1', b::text, false);
  b := mk_free(2, 'b11a0000-0000-0000-0000-000000000c01'::uuid);   -- covered
  update bookings set reservation_credit_covered = true where id = b;
  perform set_config('t.c2', b::text, false);
  b := mk_free(3, 'b11a0000-0000-0000-0000-000000000c01'::uuid);   -- waived
  update bookings set reservation_fee_waived = true where id = b;
  perform set_config('t.c3', b::text, false);
  b := mk_free(4, 'b11a0000-0000-0000-0000-000000000c01'::uuid);   -- due (sent)
  perform mk_due(b, 4, 'sent', now() - interval '1 hour');
  perform set_config('t.c4', b::text, false);
  b := mk_free(5, 'b11a0000-0000-0000-0000-000000000c01'::uuid);   -- not asked (failed only)
  perform mk_due(b, 5, 'failed', now() - interval '1 hour');
  perform set_config('t.c5', b::text, false);
end $$;

reset role; set role authenticated; select set_config('request.jwt.claim.sub','b11a0000-0000-0000-0000-0000000000f1',false);
select expect_eq('chip: paid', (select state from occurrence_free_seat_states('b11a0000-0000-0000-0000-000000000c01') where booking_id = current_setting('t.c1')::uuid), 'paid');
select expect_eq('chip: covered', (select state from occurrence_free_seat_states('b11a0000-0000-0000-0000-000000000c01') where booking_id = current_setting('t.c2')::uuid), 'covered');
select expect_eq('chip: waived', (select state from occurrence_free_seat_states('b11a0000-0000-0000-0000-000000000c01') where booking_id = current_setting('t.c3')::uuid), 'waived');
select expect_eq('chip: due (a sent due email)', (select state from occurrence_free_seat_states('b11a0000-0000-0000-0000-000000000c01') where booking_id = current_setting('t.c4')::uuid), 'due');
select expect_eq('chip: not asked (the due failed)', (select state from occurrence_free_seat_states('b11a0000-0000-0000-0000-000000000c01') where booking_id = current_setting('t.c5')::uuid), 'not_asked');
select expect_eq('chip: paid carries the amount', (select fee_cents::text from occurrence_free_seat_states('b11a0000-0000-0000-0000-000000000c01') where booking_id = current_setting('t.c1')::uuid), '50000');
select expect_true('chip: due carries a deadline label', (select deadline_label like '%PM%' or deadline_label like '%AM%' from occurrence_free_seat_states('b11a0000-0000-0000-0000-000000000c01') where booking_id = current_setting('t.c4')::uuid));
select expect_eq('flex pending line: 5 seats, 2 paid, 2 due, 1 waived',
  (select n||'/'||paid||'/'||due||'/'||waived from flex_pending_free_seats('b11a0000-0000-0000-0000-0000000000a0') where occurrence_id = 'b11a0000-0000-0000-0000-000000000c01'), '5/2/2/1');
select expect_eq('profile card: the waived seat reads waived',
  (select state from member_reservation_fees('b11a0000-0000-0000-0000-0000000d0003') limit 1), 'waived');
select expect_eq('profile card: the not-asked seat reads not_asked',
  (select state from member_reservation_fees('b11a0000-0000-0000-0000-0000000d0005') limit 1), 'not_asked');
reset role; set role authenticated; select set_config('request.jwt.claim.sub','b11a0000-0000-0000-0000-0000000000c1',false);
select expect_err('a member cannot read a class''s seat states',
  $q$select * from occurrence_free_seat_states('b11a0000-0000-0000-0000-000000000c01')$q$, 'PT403');
reset role;

-- =============================================================================
-- 2. Decision 103 (k): staff paths ask for the fee at booking
-- =============================================================================
select mk_occ('0d01', 2, 'Desk Core', now() + interval '2 days');
reset role; set role authenticated; select set_config('request.jwt.claim.sub','b11a0000-0000-0000-0000-0000000000f1',false);
select expect_eq('terms: required while a fee applies',
  (reservation_fee_terms('b11a0000-0000-0000-0000-000000000d01','b11a0000-0000-0000-0000-0000000d0010') ->> 'required'), 'true');
select expect_eq('staff free first with no choice is refused',
  (staff_book_member('b11a0000-0000-0000-0000-0000000d0010','b11a0000-0000-0000-0000-000000000d01',
     '{"kind":"free_first"}'::jsonb) ->> 'reason'), 'fee_choice_required');
select expect_eq('book_first_free studio call with no choice is refused',
  (book_first_free('b11a0000-0000-0000-0000-000000000d01','b11a0000-0000-0000-0000-0000000d0010') ->> 'reason'), 'fee_choice_required');
reset role;
select expect_eq('refusal wrote no booking', (select count(*)::text from bookings where member_id = 'b11a0000-0000-0000-0000-0000000d0010'), '0');
reset role; set role authenticated; select set_config('request.jwt.claim.sub','b11a0000-0000-0000-0000-0000000000f1',false);
select expect_eq('staff free first, due: booked',
  (staff_book_member('b11a0000-0000-0000-0000-0000000d0010','b11a0000-0000-0000-0000-000000000d01',
     '{"kind":"free_first","fee_choice":"due"}'::jsonb) ->> 'ok'), 'true');
select expect_eq('staff free first, waive: booked',
  (staff_book_member('b11a0000-0000-0000-0000-0000000d0011','b11a0000-0000-0000-0000-000000000d01',
     '{"kind":"free_first","fee_choice":"waive","fee_note":"Comes with her sister"}'::jsonb) ->> 'ok'), 'true');
reset role;
select expect_eq('due: the pay-to-keep email is queued at once',
  (select count(*)::text from notifications n join bookings b on n.dedupe_key = 'free_reservation_due:' || b.id
    where b.member_id = 'b11a0000-0000-0000-0000-0000000d0010'), '1');
select expect_eq('due: an audit row', (select count(*)::text from audit_logs a join bookings b on b.id = a.entity_id
    where a.action = 'booking.reservation_fee_asked' and b.member_id = 'b11a0000-0000-0000-0000-0000000d0010'), '1');
select expect_eq('waive: the booking is flagged waived',
  (select reservation_fee_waived::text from bookings where member_id = 'b11a0000-0000-0000-0000-0000000d0011'), 'true');
select expect_eq('waive: no due email',
  (select count(*)::text from notifications n join bookings b on n.dedupe_key like 'free_reservation_due:' || b.id || '%'
    where b.member_id = 'b11a0000-0000-0000-0000-0000000d0011'), '0');
select expect_eq('waive: the note is on the audit row',
  (select a.after ->> 'note' from audit_logs a join bookings b on b.id = a.entity_id
    where a.action = 'booking.reservation_fee_waived' and b.member_id = 'b11a0000-0000-0000-0000-0000000d0011'), 'Comes with her sister');

-- convert: an unpaid drop-in made a free class
do $$ declare b uuid; begin
  insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source)
  values ('b11a0000-0000-0000-0000-0000000000a0','b11a0000-0000-0000-0000-000000000d01','b11a0000-0000-0000-0000-0000000d0012','booked','front_desk','drop_in')
  returning id into b;
  perform set_config('t.cv', b::text, false);
end $$;
reset role; set role authenticated; select set_config('request.jwt.claim.sub','b11a0000-0000-0000-0000-0000000000a1',false);
select expect_eq('convert with no choice is refused',
  (convert_booking_to_free_first(current_setting('t.cv')::uuid) ->> 'reason'), 'fee_choice_required');
reset role;
select expect_eq('convert refusal left the drop-in alone', (select payment_source::text from bookings where id = current_setting('t.cv')::uuid), 'drop_in');
reset role; set role authenticated; select set_config('request.jwt.claim.sub','b11a0000-0000-0000-0000-0000000000a1',false);
select expect_eq('convert with waive: ok',
  (convert_booking_to_free_first(current_setting('t.cv')::uuid, 'waive', 'Trial week') ->> 'ok'), 'true');
reset role;
select expect_eq('convert with waive: comp and waived',
  (select payment_source::text || '/' || reservation_fee_waived::text from bookings where id = current_setting('t.cv')::uuid), 'comp/true');

-- free class on a flex class (core-only on)
update studio_settings set free_first_core_only = true where studio_id = 'b11a0000-0000-0000-0000-0000000000a0';
select mk_occ('0e01', 3, 'Desk Flex', now() + interval '2 days 2 hours', true, 2);
reset role; set role authenticated; select set_config('request.jwt.claim.sub','b11a0000-0000-0000-0000-0000000000a1',false);
select expect_eq('free on flex with no choice is refused',
  (staff_book_member('b11a0000-0000-0000-0000-0000000d0013','b11a0000-0000-0000-0000-000000000e01',
     '{"kind":"free_first","allow_free_on_flex":true}'::jsonb) ->> 'reason'), 'fee_choice_required');
select expect_eq('free on flex, due: booked',
  (staff_book_member('b11a0000-0000-0000-0000-0000000d0013','b11a0000-0000-0000-0000-000000000e01',
     '{"kind":"free_first","allow_free_on_flex":true,"fee_choice":"due"}'::jsonb) ->> 'ok'), 'true');
reset role;
select expect_eq('free on flex, due: the email is queued',
  (select count(*)::text from notifications n join bookings b on n.dedupe_key = 'free_reservation_due:' || b.id
    where b.member_id = 'b11a0000-0000-0000-0000-0000000d0013'), '1');
update studio_settings set free_first_core_only = false where studio_id = 'b11a0000-0000-0000-0000-0000000000a0';

-- fee at zero: books exactly as today
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name, starts_at, ends_at, capacity, booked_count, status)
values ('b11a0000-0000-0000-0000-000000000f01','b11a0000-0000-0000-0000-0000000000b0','b11a0000-0000-0000-0000-00000000020c',
        'b11a0000-0000-0000-0000-0000000cc002','b11a0000-0000-0000-0000-0000000002b1','Zero Fee', now() + interval '2 days', now() + interval '2 days 50 min', 10, 0, 'scheduled');
reset role; set role authenticated; select set_config('request.jwt.claim.sub','b11a0000-0000-0000-0000-0000000000f1',false);
select expect_eq('fee at zero: no choice needed, booked',
  (staff_book_member('b11a0000-0000-0000-0000-0000000d0098','b11a0000-0000-0000-0000-000000000f01',
     '{"kind":"free_first"}'::jsonb) ->> 'ok'), 'true');
-- a member's own call is unchanged
reset role; set role authenticated; select set_config('request.jwt.claim.sub','b11a0000-0000-0000-0000-0000000000c1',false);
select expect_true('a member''s own book_first_free is not asked for a choice',
  coalesce(book_first_free('b11a0000-0000-0000-0000-000000000d01') ->> 'reason', '') <> 'fee_choice_required');
reset role;

-- =============================================================================
-- 3. Decision 103 (j): release only when the due was sent
-- =============================================================================
-- deadline (start - 12 h) passed an hour ago.
select mk_occ('0a01', 4, 'Release Me', now() + interval '11 hours');
do $$ declare b uuid; begin
  b := mk_free(20, 'b11a0000-0000-0000-0000-000000000a01'::uuid);
  perform mk_due(b, 20, 'sent', now() - interval '3 hours');                       -- sent before the deadline
  perform set_config('t.r1', b::text, false);
  b := mk_free(21, 'b11a0000-0000-0000-0000-000000000a01'::uuid);
  perform mk_due(b, 21, 'failed', now() - interval '3 hours');                     -- failed only
  perform set_config('t.r2', b::text, false);
  b := mk_free(22, 'b11a0000-0000-0000-0000-000000000a01'::uuid);
  perform mk_due(b, 22, 'failed', now() - interval '4 hours');                     -- failed original
  perform mk_due(b, 22, 'sent', now() - interval '3 hours', ':requeue:2026-11-20'); -- delivered resend
  perform set_config('t.r3', b::text, false);
  b := mk_free(23, 'b11a0000-0000-0000-0000-000000000a01'::uuid);
  perform mk_due(b, 23, 'sent', now() - interval '30 min');                        -- sent AFTER the deadline
  perform set_config('t.r4', b::text, false);
end $$;
select sweep_free_reservation_dues(now());
select expect_eq('release: a sent due releases the seat', (select status::text from bookings where id = current_setting('t.r1')::uuid), 'cancelled');
select expect_eq('release: a failed due keeps the seat', (select status::text from bookings where id = current_setting('t.r2')::uuid), 'booked');
select expect_eq('release: a delivered resend counts', (select status::text from bookings where id = current_setting('t.r3')::uuid), 'cancelled');
select expect_eq('release: a due sent after the deadline keeps the seat', (select status::text from bookings where id = current_setting('t.r4')::uuid), 'booked');
select expect_eq('release: the released member is told once',
  (select count(*)::text from notifications where dedupe_key = 'free_reservation_released:' || current_setting('t.r1')), '1');
select expect_true('daily check lists the seat kept because its email never reached them',
  exists (select 1 from jsonb_array_elements_text(daily_money_check('b11a0000-0000-0000-0000-0000000000a0') -> 'items') i
           where i like 'M21 N21%Release Me%never reached them%'));

-- =============================================================================
-- 4. A failed due is retried like any other email (Decision 113)
-- =============================================================================
insert into net._http_response (id, status_code, content, headers, timed_out, error_msg)
values (999111, 429, '{"name":"rate_limit_exceeded","message":"Too many requests"}', '{}'::jsonb, false, null);
insert into notifications (id, studio_id, member_id, recipient_type, template_key, channel, dedupe_key,
                           scheduled_for, status, attempts, claimed_at, net_request_id)
values ('b11a0000-0000-0000-0000-00000000aa01','b11a0000-0000-0000-0000-0000000000a0','b11a0000-0000-0000-0000-0000000d0030',
        'member','free_reservation_due','email','free_reservation_due:retry-test', now(), 'sending', 1, now(), 999111);
select reconcile_notification_sends();
select expect_eq('retry: a rate-limited due is rescheduled, not failed',
  (select status::text from notifications where id = 'b11a0000-0000-0000-0000-00000000aa01'), 'scheduled');

-- =============================================================================
-- 5. Decision 103 (j): the nudge and the last call
-- =============================================================================
-- class 23 h out: the nudge window (24 h before) is open, the last call
-- (3 h before the deadline = 15 h before the class) is not.
select mk_occ('0b01', 5, 'Nudge Me', now() + interval '23 hours');
do $$ declare b uuid; begin
  b := mk_free(24, 'b11a0000-0000-0000-0000-000000000b01'::uuid); perform set_config('t.n1', b::text, false);
  b := mk_free(25, 'b11a0000-0000-0000-0000-000000000b01'::uuid);
  update members set reservation_fee_waived_at = now() where id = 'b11a0000-0000-0000-0000-0000000d0025';
  perform set_config('t.n2', b::text, false);
  b := mk_free(26, 'b11a0000-0000-0000-0000-000000000b01'::uuid);
  update bookings set reservation_credit_covered = true where id = b;
  perform set_config('t.n3', b::text, false);
end $$;
select sweep_free_reservation_dues(now());
select expect_eq('nudge: queued for the unpaid seat', (select count(*)::text from notifications where dedupe_key = 'free_reservation_nudge:' || current_setting('t.n1')), '1');
select expect_eq('last call: not yet', (select count(*)::text from notifications where dedupe_key = 'free_reservation_last_call:' || current_setting('t.n1')), '0');
select expect_eq('nudge: not to a waived member', (select count(*)::text from notifications where dedupe_key = 'free_reservation_nudge:' || current_setting('t.n2')), '0');
select expect_eq('nudge: not to a credit-covered seat', (select count(*)::text from notifications where dedupe_key = 'free_reservation_nudge:' || current_setting('t.n3')), '0');
select sweep_free_reservation_dues(now());
select expect_eq('nudge: a second sweep sends no second', (select count(*)::text from notifications where dedupe_key = 'free_reservation_nudge:' || current_setting('t.n1')), '1');
select sweep_free_reservation_dues(now() + interval '8 hours 5 minutes');
select expect_eq('last call: queued 3 h before the deadline', (select count(*)::text from notifications where dedupe_key = 'free_reservation_last_call:' || current_setting('t.n1')), '1');
select expect_eq('last call: not to a waived member', (select count(*)::text from notifications where dedupe_key = 'free_reservation_last_call:' || current_setting('t.n2')), '0');

-- the two new emails render with nothing left over
select expect_eq('nudge renders clean',
  (select array_length(re.stripped, 1)::text from notification_templates t,
     render_email('b11a0000-0000-0000-0000-0000000000a0', t.key, 'member', t.subject, t.text_body, t.html_body,
                  template_sample_context('b11a0000-0000-0000-0000-0000000000a0', 'x@example.com', 'Ana'), 'Ana') re
    where t.key = 'free_reservation_nudge'), null);
select expect_eq('last call renders clean',
  (select array_length(re.stripped, 1)::text from notification_templates t,
     render_email('b11a0000-0000-0000-0000-0000000000a0', t.key, 'member', t.subject, t.text_body, t.html_body,
                  template_sample_context('b11a0000-0000-0000-0000-0000000000a0', 'x@example.com', 'Ana'), 'Ana') re
    where t.key = 'free_reservation_last_call'), null);
select expect_true('both carry the credit line',
  (select bool_and(text_body like '%comes back to you as studio credit%') from notification_templates
    where key in ('free_reservation_nudge','free_reservation_last_call')));

-- =============================================================================
-- 6. Decision 21 (e): a day tier switch clears stale latches
-- =============================================================================
select mk_occ('0f11', 6, 'Stale Core', now() + interval '4 days');
select mk_occ('0f12', 7, 'Earned Core', now() + interval '4 days 2 hours');
insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source)
values ('b11a0000-0000-0000-0000-0000000000a0','b11a0000-0000-0000-0000-000000000f11','b11a0000-0000-0000-0000-0000000d0031','booked','member','class_pack'),
       ('b11a0000-0000-0000-0000-0000000000a0','b11a0000-0000-0000-0000-000000000f12','b11a0000-0000-0000-0000-0000000d0032','booked','member','class_pack'),
       ('b11a0000-0000-0000-0000-0000000000a0','b11a0000-0000-0000-0000-000000000f12','b11a0000-0000-0000-0000-0000000d0033','booked','member','class_pack');
update class_occurrences set flex_reached_minimum_at = now() - interval '1 day', core_reached_minimum_at = now() - interval '1 day'
 where id in ('b11a0000-0000-0000-0000-000000000f11','b11a0000-0000-0000-0000-000000000f12');
reset role; set role authenticated; select set_config('request.jwt.claim.sub','b11a0000-0000-0000-0000-0000000000a1',false);
select set_occurrence_day_tier('b11a0000-0000-0000-0000-000000000f11', 'flex');
select set_occurrence_day_tier('b11a0000-0000-0000-0000-000000000f12', 'flex');
reset role;
select expect_eq('day flex: 1 paid of 2 clears both marks',
  (select (flex_reached_minimum_at is null)::text || '/' || (core_reached_minimum_at is null)::text
     from class_occurrences where id = 'b11a0000-0000-0000-0000-000000000f11'), 'true/true');
select expect_eq('day flex: 2 paid of 2 re-latches',
  (select (flex_reached_minimum_at is not null)::text from class_occurrences where id = 'b11a0000-0000-0000-0000-000000000f12'), 'true');
select expect_eq('day flex: the new mark is fresh, not the stale one',
  (select (flex_reached_minimum_at > now() - interval '1 minute')::text from class_occurrences where id = 'b11a0000-0000-0000-0000-000000000f12'), 'true');

-- =============================================================================
-- 7. Decision 108 (a): the two pay watchdogs
-- =============================================================================
select mk_occ('0f21', 8, 'Stale Flex', now() + interval '5 days', true, 2);
insert into bookings (studio_id, occurrence_id, member_id, status, source, payment_source)
values ('b11a0000-0000-0000-0000-0000000000a0','b11a0000-0000-0000-0000-000000000f21','b11a0000-0000-0000-0000-0000000d0034','booked','member','class_pack');
update class_occurrences set flex_reached_minimum_at = now() where id = 'b11a0000-0000-0000-0000-000000000f21';
select expect_true('watchdog 11: a stale latch on a flex class is listed',
  exists (select 1 from jsonb_array_elements_text(daily_money_check('b11a0000-0000-0000-0000-0000000000a0') -> 'items') i
           where i like 'Stale Flex%1 paid of 2%'));

insert into instructor_pay_records (studio_id, instructor_id, period_id, type, amount_cents, currency, occurrence_id, basis)
values ('b11a0000-0000-0000-0000-0000000000a0','b11a0000-0000-0000-0000-0000000a00c1',
        (ensure_pay_period('b11a0000-0000-0000-0000-0000000000a0', current_date)).id, 'class', 99000, 'PHP',
        'b11a0000-0000-0000-0000-000000000f11',
        jsonb_build_object('kind','group','base_cents',90000,'per_head_cents',7500,'per_head_threshold',2,
                           'booked_paid',4,'full_house_bonus_cents',0)),
       ('b11a0000-0000-0000-0000-0000000000a0','b11a0000-0000-0000-0000-0000000a00c1',
        (ensure_pay_period('b11a0000-0000-0000-0000-0000000000a0', current_date)).id, 'class', 105000, 'PHP',
        'b11a0000-0000-0000-0000-000000000f12',
        jsonb_build_object('kind','group','base_cents',90000,'per_head_cents',7500,'per_head_threshold',2,
                           'booked_paid',4,'full_house_bonus_cents',0));
select expect_true('watchdog 12: a pay line that does not match its basis is listed',
  exists (select 1 from jsonb_array_elements_text(daily_money_check('b11a0000-0000-0000-0000-0000000000a0') -> 'items') i
           where i like '%Stale Core%990%but its basis gives%1,050%'));
select expect_true('watchdog 12: a matching pay line is not listed',
  not exists (select 1 from jsonb_array_elements_text(daily_money_check('b11a0000-0000-0000-0000-0000000000a0') -> 'items') i
               where i like '%Earned Core%but its basis gives%'));

-- =============================================================================
-- 8. Decision 89 (b): message paragraphs
-- =============================================================================
select expect_true('message html: paragraphs and line breaks, CRLF normalised',
  (select position('<blockquote><p style="margin:0 0 10px">Hi Ana,</p><p style="margin:0 0 10px">See you &lt;b&gt;tomorrow&lt;/b&gt;.<br>Bring socks.</p></blockquote>' in re.html_body) > 0
     from render_email('b11a0000-0000-0000-0000-0000000000a0', 'message_to_member', 'member',
     's', '{message}', '<blockquote>{message_html}</blockquote>',
     jsonb_build_object('message', E'Hi Ana,\r\n\r\n\r\nSee you <b>tomorrow</b>.\r\nBring socks.', 'message_html', 'old'), 'Ana') re));
select expect_true('message text: breaks kept, CRLF normalised',
  (select position(E'Hi Ana,\n\nLine two\nLine three' in re.text_body) = 1 and position(E'\r' in re.text_body) = 0
     from render_email('b11a0000-0000-0000-0000-0000000000a0', 'message_to_member', 'member',
     's', '{message}', '<p>x</p>',
     jsonb_build_object('message', E'Hi Ana,\r\n\r\n\r\nLine two\r\nLine three'), 'Ana') re));

-- =============================================================================
-- 9. Decision 80 note: the three tokens
-- =============================================================================
select expect_eq('flex_min and flex_cutoff render per the studio rule',
  (select split_part(re.text_body, E'\n', 1) from render_email('b11a0000-0000-0000-0000-0000000000a0', 'x', 'member',
     's', 'min {flex_min}, cut-off {flex_cutoff}', '<p>x</p>', '{}'::jsonb, 'Ana') re),
  'min 2, cut-off 8:00 PM the evening before');
update studio_settings set flex_deadline_mode = 'hours_before', flex_deadline_hours = 6 where studio_id = 'b11a0000-0000-0000-0000-0000000000a0';
select expect_eq('flex_cutoff in the hours-before shape',
  (select split_part(re.text_body, E'\n', 1) from render_email('b11a0000-0000-0000-0000-0000000000a0', 'x', 'member',
     's', '{flex_cutoff}', '<p>x</p>', '{}'::jsonb, 'Ana') re), '6 hours before class');
update studio_settings set flex_deadline_mode = 'previous_day_at', flex_deadline_hours = 12 where studio_id = 'b11a0000-0000-0000-0000-0000000000a0';
select expect_true('roster_table: an HTML table from the payload rows',
  (select re.html_body like '%<table%Day%Time%Class%Reformer Flow%' from render_email('b11a0000-0000-0000-0000-0000000000a0', 'month_roster', 'staff',
     's', '{roster_table}', '{roster_table}',
     jsonb_build_object('roster_rows', jsonb_build_array(jsonb_build_object('day','Mon 7 Dec','time','7:00 AM','class','Reformer Flow'))), 'Ana') re));
select expect_eq('roster_table: an aligned text fallback',
  (select split_part(re.text_body, E'\n\n', 1) from render_email('b11a0000-0000-0000-0000-0000000000a0', 'month_roster', 'staff',
     's', '{roster_table}', '{roster_table}',
     jsonb_build_object('roster_rows', jsonb_build_array(
       jsonb_build_object('day','Mon 7 Dec','time','7:00 AM','class','Reformer Flow'),
       jsonb_build_object('day','Wed 9 Dec','time','10:00 AM','class','Sculpt'))), 'Ana') re),
  E'Mon 7 Dec  7:00 AM   Reformer Flow\nWed 9 Dec  10:00 AM  Sculpt');
update class_occurrences set instructor_id = 'b11a0000-0000-0000-0000-0000000a00c1' where id = 'b11a0000-0000-0000-0000-000000000f11';
select expect_true('roster_table: built from the instructor''s classes that month',
  (select re.html_body like '%Stale Core%' from render_email('b11a0000-0000-0000-0000-0000000000a0', 'month_roster', 'staff',
     's', '{roster_table}', '{roster_table}',
     jsonb_build_object('instructor_id', 'b11a0000-0000-0000-0000-0000000a00c1',
                        'month_ym', to_char((now() + interval '4 days') at time zone 'Asia/Manila', 'YYYY-MM')), 'Ana') re));

-- =============================================================================
-- 10. The surface
-- =============================================================================
select expect_eq('anon surface EXACTLY FOURTEEN',
  (select count(*)::text from pg_proc p join pg_namespace s on s.oid = p.pronamespace
    where s.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not in ('expect_eq','expect_true','expect_err','mk_occ','mk_free','mk_due')), '14');
select expect_true('the new readers are not anon',
  not has_function_privilege('anon', 'occurrence_free_seat_states(uuid)', 'execute')
  and not has_function_privilege('anon', 'reservation_fee_terms(uuid,uuid)', 'execute')
  and not has_function_privilege('anon', 'book_first_free(uuid,uuid,text,text)', 'execute')
  and not has_function_privilege('authenticated', 'apply_free_fee_choice(uuid,text,text)', 'execute'));
select expect_true('only one book_first_free exists (no second overload)',
  (select count(*) = 1 from pg_proc where proname = 'book_first_free'));
select expect_true('the Resend inbox table stays closed to anon reads',
  not has_table_privilege('anon', 'resend_webhook_inbox', 'select'));

\echo 'step11_test: all assertions passed'
