-- =============================================================================
-- Decision 75b-2 (i) statements + (h) close-with-a-reason.
-- =============================================================================
-- UUID space b252, checked free. Run after `supabase db reset`.
--
--   * a finalised class line carries checked_in; before finalisation it is null;
--   * a straggler (recorded in a later period) carries from_previous_period, and
--     record_class_pay stamps basis.original_period;
--   * a conversion line carries first_class_on;
--   * header status is Paid only when a settlement row exists;
--   * an instructor reads their own statement, not another's (PT403); a manager
--     reads anyone's; instructor_pay_periods lists their periods newest-first;
--   * close_pay_period returns held_records as a REASON listing the classes,
--     and succeeds once none are held.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_eq(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual,'null'); end if;
end $$;

-- run a query as a given session, returning its jsonb (or null on error).
create or replace function as_jsonb(p_uid text, p_sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claim.sub', p_uid, true); set local role authenticated;
  begin execute p_sql into r; reset role; return r;
  exception when others then reset role; return jsonb_build_object('err', sqlstate); end;
end $$;

-- the state token for a guard probe.
create or replace function as_state(p_uid text, p_sql text) returns text language plpgsql as $$
declare r text;
begin
  perform set_config('request.jwt.claim.sub', p_uid, true); set local role authenticated;
  begin execute p_sql into r; reset role; return coalesce(r,'null');
  exception when others then reset role; return 'ERR:'||sqlstate; end;
end $$;

-- the one line for an occurrence out of a pay_statement jsonb.
create or replace function line_for(p_stmt jsonb, p_occ_name text) returns jsonb language sql immutable as $$
  select l from jsonb_array_elements(p_stmt -> 'lines') l where l ->> 'name' = p_occ_name limit 1; $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('b252b252-0000-0000-0000-00000000000f'),   -- owner/manager
  ('b252b252-0000-0000-0000-0000000000a1'),   -- instructor A login
  ('b252b252-0000-0000-0000-0000000000b2');   -- instructor B login
insert into profiles (id, email) select id, id::text||'@example.com' from auth.users where id::text like 'b252%';

insert into studios (id, name, slug, timezone, currency, status, contact_email) values
  ('b252b252-0000-0000-0000-000000000001','Pay S','b252-s','UTC','USD','active','desk@b252.example');
-- guarantees ON; finalise ON; anchor 2 days ago so the "2 days ago" classes
-- share ONE fortnight deterministically (never straddle a boundary).
insert into studio_settings (studio_id, guarantees_enabled, finalise_attendance, finalise_days_after, checkin_window_enforced, pay_period_anchor)
  values ('b252b252-0000-0000-0000-000000000001', true, true, 1, false, (now() - interval '2 days')::date);

insert into studio_staff (id, studio_id, user_id, email, role, status) values
  ('b252b252-0000-0000-0000-0000000005ff','b252b252-0000-0000-0000-000000000001','b252b252-0000-0000-0000-00000000000f','b252-owner@example.com','owner','active'),
  ('b252b252-0000-0000-0000-0000000005a1','b252b252-0000-0000-0000-000000000001','b252b252-0000-0000-0000-0000000000a1','b252-ia@example.com','instructor','active'),
  ('b252b252-0000-0000-0000-0000000005b2','b252b252-0000-0000-0000-000000000001','b252b252-0000-0000-0000-0000000000b2','b252-ib@example.com','instructor','active');

insert into instructors (id, studio_id, staff_id, display_name, status) values
  ('b252b252-0000-0000-0000-0000000a00a1','b252b252-0000-0000-0000-000000000001','b252b252-0000-0000-0000-0000000005a1','Coach A','active'),
  ('b252b252-0000-0000-0000-0000000a00b2','b252b252-0000-0000-0000-000000000001','b252b252-0000-0000-0000-0000000005b2','Coach B','active');

insert into instructor_rate_versions (studio_id, instructor_id, effective_from, currency,
         base_rate_cents, per_head_rate_cents, per_head_threshold, full_house_bonus_cents) values
  ('b252b252-0000-0000-0000-000000000001','b252b252-0000-0000-0000-0000000a00a1', current_date - 60, 'USD', 9000, 750, 2, 0);

insert into locations (id, studio_id, name, is_primary) values
  ('b252b252-0000-0000-0000-00000000100c','b252b252-0000-0000-0000-000000000001','S', true);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity, session_kind) values
  ('b252b252-0000-0000-0000-0000000cc001','b252b252-0000-0000-0000-000000000001','Mat',50,10,'group');
insert into members (id, studio_id, first_name, last_name, email, waiver_signed_at) values
  ('b252b252-0000-0000-0000-0000000d0001','b252b252-0000-0000-0000-000000000001','M','One','b252-1@example.com',now()),
  ('b252b252-0000-0000-0000-0000000d0002','b252b252-0000-0000-0000-000000000001','M','Two','b252-2@example.com',now()),
  ('b252b252-0000-0000-0000-0000000d0003','b252b252-0000-0000-0000-000000000001','M','Three','b252-3@example.com',now()),
  ('b252b252-0000-0000-0000-0000000d0004','b252b252-0000-0000-0000-000000000001','M','Four','b252-4@example.com',now());

-- F "Finalised" (committed, 6 booked, 4 checked in), U "Unfinalised" (committed,
-- 5 booked, no check-ins). Both land in P0 (anchor = 2 days ago). Committing
-- writes a HELD class record for Coach A via the trigger.
insert into class_occurrences (id, studio_id, location_id, class_type_id, instructor_id, name,
         starts_at, ends_at, capacity, booked_count, booked_at_cutoff, committed_at, status) values
  -- Fixed mid-day times on (now-2d), all in one UTC period (anchor = that date),
  -- so F, U and the straggler never straddle a day/period boundary.
  ('b252b252-0000-0000-0000-0000000000f1','b252b252-0000-0000-0000-000000000001','b252b252-0000-0000-0000-00000000100c','b252b252-0000-0000-0000-0000000cc001','b252b252-0000-0000-0000-0000000a00a1','Finalised Class',
     (((now()-interval '2 days')::date + time '10:00') at time zone 'UTC'), (((now()-interval '2 days')::date + time '10:50') at time zone 'UTC'), 10, 6, 6, (((now()-interval '2 days')::date + time '08:00') at time zone 'UTC'), 'scheduled'),
  ('b252b252-0000-0000-0000-0000000000f2','b252b252-0000-0000-0000-000000000001','b252b252-0000-0000-0000-00000000100c','b252b252-0000-0000-0000-0000000cc001','b252b252-0000-0000-0000-0000000a00a1','Unfinalised Class',
     (((now()-interval '2 days')::date + time '12:00') at time zone 'UTC'), (((now()-interval '2 days')::date + time '12:50') at time zone 'UTC'), 10, 5, 5, (((now()-interval '2 days')::date + time '08:00') at time zone 'UTC'), 'scheduled');

insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at)
select ('b252b252-0000-0000-0000-0000000b00'||mem)::uuid, 'b252b252-0000-0000-0000-000000000001',
       'b252b252-0000-0000-0000-0000000000f1', mem_id, 'booked','member','drop_in', now()-interval '3 days'
from (values ('01','b252b252-0000-0000-0000-0000000d0001'::uuid),('02','b252b252-0000-0000-0000-0000000d0002'::uuid),
             ('03','b252b252-0000-0000-0000-0000000d0003'::uuid),('04','b252b252-0000-0000-0000-0000000d0004'::uuid)) as m(mem, mem_id);
insert into check_ins (studio_id, booking_id, member_id, occurrence_id, method, checked_in_at)
select 'b252b252-0000-0000-0000-000000000001', b.id, b.member_id, b.occurrence_id, 'instructor', now()-interval '2 days 9 h'
  from bookings b where b.occurrence_id = 'b252b252-0000-0000-0000-0000000000f1';

-- Finalise F on checked-in heads (4).
select finalise_pay_true_up('b252b252-0000-0000-0000-0000000000f1');

-- A conversion bonus record for Coach A in P0, carrying the first-class date.
insert into instructor_pay_records (studio_id, instructor_id, period_id, type, source_id, amount_cents, currency, basis, note)
select 'b252b252-0000-0000-0000-000000000001','b252b252-0000-0000-0000-0000000a00a1',
       (select period_id from instructor_pay_records where occurrence_id='b252b252-0000-0000-0000-0000000000f1' and type='class'),
       'conversion','b252b252-0000-0000-0000-0000000d0001', 50000, 'USD',
       jsonb_build_object('member_name','M One','plan_name','Unlimited','first_class_on','2026-10-01'), 'Conversion bonus';

-- P0 = the period F/U/conversion live in. Read statements as the owner (manager).
create or replace function p0() returns uuid language sql stable as $$
  select period_id from instructor_pay_records where occurrence_id='b252b252-0000-0000-0000-0000000000f1' and type='class'; $$;
create or replace function stmt0() returns jsonb language sql stable as $$
  select as_jsonb('b252b252-0000-0000-0000-00000000000f',
    format('select pay_statement(%L, %L)', 'b252b252-0000-0000-0000-0000000a00a1', p0())); $$;

-- =============================================================================
-- (i) statement lines
-- =============================================================================
select expect_eq('F line carries checked_in = 4 once finalised',
  line_for(stmt0(), 'Finalised Class') ->> 'checked_in', '4');
select expect_eq('F line is finalised',
  line_for(stmt0(), 'Finalised Class') ->> 'finalised', 'true');
select expect_eq('F line shows 6 booked',
  line_for(stmt0(), 'Finalised Class') ->> 'booked', '6');
select expect_eq('U line checked_in is null before finalisation',
  coalesce(line_for(stmt0(), 'Unfinalised Class') ->> 'checked_in', 'NULL'), 'NULL');
select expect_eq('U line is not finalised',
  line_for(stmt0(), 'Unfinalised Class') ->> 'finalised', 'false');
select expect_eq('conversion line carries first_class_on',
  line_for(stmt0(), 'Conversion — M One (Unlimited)') ->> 'first_class_on', '2026-10-01');
select expect_eq('F line is not from a previous period',
  line_for(stmt0(), 'Finalised Class') ->> 'from_previous_period', 'false');

-- =============================================================================
-- (h) close: held records are a reason, not a raise; then it closes
-- =============================================================================
-- F and U are both committed => HELD (unconfirmed) class records in P0.
select expect_eq('close with held records returns a reason, not an error',
  as_jsonb('b252b252-0000-0000-0000-00000000000f',
    format('select close_pay_period(%L)', p0())) ->> 'reason', 'held_records');
select expect_eq('the reason lists both held classes',
  jsonb_array_length(as_jsonb('b252b252-0000-0000-0000-00000000000f',
    format('select close_pay_period(%L)', p0())) -> 'classes')::text, '2');

-- Confirm both (a manager release), then close succeeds.
update instructor_pay_records set confirmed_at = now(), confirm_method = 'manager'
 where period_id = p0() and type = 'class' and confirmed_at is null;
select expect_eq('close succeeds once nothing is held',
  as_jsonb('b252b252-0000-0000-0000-00000000000f',
    format('select close_pay_period(%L)', p0())) ->> 'ok', 'true');

-- =============================================================================
-- (i) header status: Closed, then Paid once a settlement exists
-- =============================================================================
select expect_eq('status is Closed before a settlement', stmt0() ->> 'status', 'closed');
insert into instructor_pay_settlements (studio_id, period_id, instructor_id, paid_on, method, reference)
  values ('b252b252-0000-0000-0000-000000000001', p0(), 'b252b252-0000-0000-0000-0000000a00a1', date '2026-02-15', 'bank_transfer', 'INV-9');
select expect_eq('status is Paid once a settlement exists', stmt0() ->> 'status', 'paid');
select expect_eq('the paid method rides the header', stmt0() ->> 'paid_method', 'bank_transfer');

-- =============================================================================
-- (i)+(1) straggler: a class committed into the now-CLOSED P0 records in the
--         next open period with basis.original_period, tagged from_previous_period.
-- =============================================================================
insert into class_occurrences (id, studio_id, location_id, class_type_id, instructor_id, name,
         starts_at, ends_at, capacity, booked_count, booked_at_cutoff, committed_at, status) values
  ('b252b252-0000-0000-0000-0000000000f3','b252b252-0000-0000-0000-000000000001','b252b252-0000-0000-0000-00000000100c','b252b252-0000-0000-0000-0000000cc001','b252b252-0000-0000-0000-0000000a00a1','Straggler Class',
     (((now()-interval '2 days')::date + time '14:00') at time zone 'UTC'), (((now()-interval '2 days')::date + time '14:50') at time zone 'UTC'), 10, 3, 3, (((now()-interval '2 days')::date + time '08:00') at time zone 'UTC'), 'scheduled');
-- Its class record landed in a DIFFERENT (next open) period, with original_period = P0.
select expect_eq('straggler record stamps original_period = P0 (record_class_pay)',
  (select (basis ->> 'original_period') from instructor_pay_records where occurrence_id='b252b252-0000-0000-0000-0000000000f3' and type='class'), p0()::text);
select expect_eq('straggler is not in P0',
  (select (period_id <> p0())::text from instructor_pay_records where occurrence_id='b252b252-0000-0000-0000-0000000000f3' and type='class'), 'true');
select expect_eq('straggler line is tagged from_previous_period',
  (line_for(as_jsonb('b252b252-0000-0000-0000-00000000000f',
     format('select pay_statement(%L, %L)', 'b252b252-0000-0000-0000-0000000a00a1',
       (select period_id from instructor_pay_records where occurrence_id='b252b252-0000-0000-0000-0000000000f3' and type='class'))),
     'Straggler Class') ->> 'from_previous_period'), 'true');

-- =============================================================================
-- instructor_pay_periods — the picker list, newest first, with status
-- =============================================================================
select expect_eq('the instructor has two periods (P0 paid, the straggler period open)',
  jsonb_array_length(as_jsonb('b252b252-0000-0000-0000-0000000000a1',
    format('select instructor_pay_periods(%L)', 'b252b252-0000-0000-0000-0000000a00a1')))::text, '2');
select expect_eq('P0 reads paid in the picker',
  (select p ->> 'status' from jsonb_array_elements(as_jsonb('b252b252-0000-0000-0000-0000000000a1',
      format('select instructor_pay_periods(%L)', 'b252b252-0000-0000-0000-0000000a00a1'))) p
    where (p ->> 'period_id') = p0()::text), 'paid');

-- =============================================================================
-- guards: own vs another's statement
-- =============================================================================
select expect_eq('an instructor cannot read another instructor''s statement (PT403)',
  as_state('b252b252-0000-0000-0000-0000000000b2',
    format('select pay_statement(%L, %L)::text', 'b252b252-0000-0000-0000-0000000a00a1', p0())), 'ERR:PT403');
select expect_eq('the instructor reads their own statement',
  as_jsonb('b252b252-0000-0000-0000-0000000000a1',
    format('select pay_statement(%L, %L)', 'b252b252-0000-0000-0000-0000000a00a1', p0())) ->> 'ok', 'true');
select expect_eq('a manager reads any instructor''s statement',
  as_jsonb('b252b252-0000-0000-0000-00000000000f',
    format('select pay_statement(%L, %L)', 'b252b252-0000-0000-0000-0000000a00a1', p0())) ->> 'ok', 'true');

select 'pay_statement_test OK' as result;
