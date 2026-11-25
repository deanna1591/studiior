-- =============================================================================
-- Decision 75b-1 (g) — checked-in pay basis at finalisation.
-- =============================================================================
-- UUID space 75d0, checked free. Run after `supabase db reset`.
--
-- A committed group class pays on booked_at_cutoff at commit (Decision 32), then
-- finalise_pay_true_up re-prices it on SEATS (Decision 75(j), "pay follows the
-- seat, not the body"): the greater of the count at the cut-off and the seats
-- consumed (attended, no-show, late cancelled). Checked-in heads are recorded
-- for the statement but no longer set the pay.
--   * 6 booked, 4 attend, 2 no-show -> paid on 6 (unchanged, not lowered);
--   * a late cancel after the cut-off counts; an on-time cancel does not;
--   * pay never drops below the cut-off count;
--   * CLOSED period -> adjustment in next_open_pay_period (signed), with
--     finalise_of + original_period, idempotent on finalise_of;
--   * finalisation OFF -> skipped, row unchanged (never a silent cut);
--   * cover accepted after commit -> the row names the cover instructor;
--   * a second run changes nothing (idempotent on basis.finalised_at);
--   * a private (flat) line is untouched.
--
-- Rate: base 90000, per-head 7500 over a threshold of 2, no full-house, private
-- 50000. 6 heads = 120000; 5 = 112500; 4 = 105000; 3 = 97500; 2 = 90000.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_eq(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual,'null'); end if;
end $$;

-- the class pay record's amount / instructor / checked_in, by occurrence.
create or replace function rec_amt(p_occ uuid) returns int language sql stable as $$
  select amount_cents from instructor_pay_records where occurrence_id = p_occ and type = 'class'; $$;
create or replace function rec_instr(p_occ uuid) returns uuid language sql stable as $$
  select instructor_id from instructor_pay_records where occurrence_id = p_occ and type = 'class'; $$;
create or replace function rec_checked(p_occ uuid) returns text language sql stable as $$
  select basis ->> 'checked_in' from instructor_pay_records where occurrence_id = p_occ and type = 'class'; $$;
create or replace function rec_basis(p_occ uuid, k text) returns text language sql stable as $$
  select basis ->> k from instructor_pay_records where occurrence_id = p_occ and type = 'class'; $$;

-- --- Fixtures ----------------------------------------------------------------
insert into studios (id, name, slug, timezone, currency, status) values
  ('75d075d0-0000-0000-0000-000000000001','SG on','75d0-on','Asia/Manila','PHP','active'),
  ('75d075d0-0000-0000-0000-000000000002','SG off','75d0-off','Asia/Manila','PHP','active');
-- guarantees ON (so pay records exist); finalise ON for SG-on, OFF for SG-off;
-- window enforcement OFF so fixtures can insert past check_ins.
insert into studio_settings (studio_id, guarantees_enabled, finalise_attendance, finalise_days_after, checkin_window_enforced) values
  ('75d075d0-0000-0000-0000-000000000001', true, true,  1, false),
  ('75d075d0-0000-0000-0000-000000000002', true, false, 1, false);

insert into locations (id, studio_id, name, is_primary) values
  ('75d075d0-0000-0000-0000-00000000100c','75d075d0-0000-0000-0000-000000000001','G', true),
  ('75d075d0-0000-0000-0000-00000000200c','75d075d0-0000-0000-0000-000000000002','H', true);

insert into class_types (id, studio_id, name, duration_minutes, default_capacity, session_kind) values
  ('75d075d0-0000-0000-0000-0000000cc001','75d075d0-0000-0000-0000-000000000001','Mat',50,10,'group'),
  ('75d075d0-0000-0000-0000-0000000cc0bb','75d075d0-0000-0000-0000-000000000001','Priv',50,1,'private'),
  ('75d075d0-0000-0000-0000-0000000cc002','75d075d0-0000-0000-0000-000000000002','Mat',50,10,'group');

insert into instructors (id, studio_id, display_name, status) values
  ('75d075d0-0000-0000-0000-0000000a00a1','75d075d0-0000-0000-0000-000000000001','Coach A','active'),
  ('75d075d0-0000-0000-0000-0000000a00b2','75d075d0-0000-0000-0000-000000000001','Coach B','active'),
  ('75d075d0-0000-0000-0000-0000000a00f0','75d075d0-0000-0000-0000-000000000002','Coach O','active');

insert into instructor_rate_versions (studio_id, instructor_id, effective_from, currency,
         base_rate_cents, per_head_rate_cents, per_head_threshold, full_house_bonus_cents, private_rate_cents) values
  ('75d075d0-0000-0000-0000-000000000001','75d075d0-0000-0000-0000-0000000a00a1', current_date - 60, 'PHP', 90000, 7500, 2, 0, 50000),
  ('75d075d0-0000-0000-0000-000000000001','75d075d0-0000-0000-0000-0000000a00b2', current_date - 60, 'PHP', 90000, 7500, 2, 0, 50000),
  ('75d075d0-0000-0000-0000-000000000002','75d075d0-0000-0000-0000-0000000a00f0', current_date - 60, 'PHP', 90000, 7500, 2, 0, 50000);

insert into members (id, studio_id, first_name, last_name, email, waiver_signed_at)
select ('75d075d0-0000-0000-0000-0000000d000'||n)::uuid, '75d075d0-0000-0000-0000-000000000001', 'M', 'N'||n,
       '75d0-'||n||'@example.com', now()
  from generate_series(1,6) n;

-- Occurrences on SG-on, committed (a class pay record is written on insert at
-- booked_at_cutoff), ended two days ago, staggered an hour apart for Coach A.
--   OG1   cutoff 6: 4 attended + 2 no-show            -> 6 (cutoff), 120000
--   OGlt  cutoff 3: 3 attended + 1 late cancelled     -> 4 (consumed), 105000
--   OGot  cutoff 2: 2 attended + 1 on-time cancelled  -> 2, 90000
--   OGfl  cutoff 4: 3 attended + 1 on-time cancelled  -> 4 (cutoff floor), 105000
--   OG2   cutoff 3: 5 attended, CLOSED period         -> +15000 adjustment
--   OGcov cutoff 6: 4 attended + 2 no-show, covered    -> 120000 to Coach B
--   OGpriv private flat; OGoff on the finalise-OFF studio.
insert into class_occurrences (id, studio_id, location_id, class_type_id, instructor_id, name,
         starts_at, ends_at, capacity, booked_count, booked_at_cutoff, committed_at, status)
select o.id::uuid, '75d075d0-0000-0000-0000-000000000001', '75d075d0-0000-0000-0000-00000000100c', o.ct::uuid,
       '75d075d0-0000-0000-0000-0000000a00a1', o.nm,
       now() - interval '2 days' - make_interval(hours => o.h), now() - interval '2 days' - make_interval(hours => o.h - 1),
       o.cap, o.cut, o.cut, now() - interval '3 days', 'scheduled'
from (values
  ('75d075d0-0000-0000-0000-00000000a001','75d075d0-0000-0000-0000-0000000cc001','OG1',   15, 10, 6),
  ('75d075d0-0000-0000-0000-00000000a011','75d075d0-0000-0000-0000-0000000cc001','OGlt',  13, 10, 3),
  ('75d075d0-0000-0000-0000-00000000a021','75d075d0-0000-0000-0000-0000000cc001','OGot',  11, 10, 2),
  ('75d075d0-0000-0000-0000-00000000a031','75d075d0-0000-0000-0000-0000000cc001','OGfl',   9, 10, 4),
  ('75d075d0-0000-0000-0000-00000000a002','75d075d0-0000-0000-0000-0000000cc001','OG2',    7, 10, 3),
  ('75d075d0-0000-0000-0000-00000000c001','75d075d0-0000-0000-0000-0000000cc001','OGcov',  5, 10, 6),
  ('75d075d0-0000-0000-0000-00000000e001','75d075d0-0000-0000-0000-0000000cc0bb','OGpriv', 3,  1, 1)
) as o(id, ct, nm, h, cap, cut);
insert into class_occurrences (id, studio_id, location_id, class_type_id, instructor_id, name,
         starts_at, ends_at, capacity, booked_count, booked_at_cutoff, committed_at, status) values
  ('75d075d0-0000-0000-0000-00000000f001','75d075d0-0000-0000-0000-000000000002','75d075d0-0000-0000-0000-00000000200c','75d075d0-0000-0000-0000-0000000cc002','75d075d0-0000-0000-0000-0000000a00f0','OGoff',
     now()-interval '2 days 9 h', now()-interval '2 days 8 h', 10, 6, 6, now()-interval '3 days', 'scheduled');

-- Bookings: (occurrence suffix, member number, status).
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at)
select ('75d075d0-0000-0000-0000-0000b'||b.occ||'00'||b.mem)::uuid, '75d075d0-0000-0000-0000-000000000001',
       ('75d075d0-0000-0000-0000-00000000'||b.occ)::uuid, ('75d075d0-0000-0000-0000-0000000d000'||b.mem)::uuid,
       b.st::booking_status, 'member', 'drop_in', now()-interval '3 days'
from (values
  ('a001',1,'attended'),('a001',2,'attended'),('a001',3,'attended'),('a001',4,'attended'),('a001',5,'no_show'),('a001',6,'no_show'),
  ('a011',1,'attended'),('a011',2,'attended'),('a011',3,'attended'),('a011',4,'late_cancelled'),
  ('a021',1,'attended'),('a021',2,'attended'),('a021',3,'cancelled'),
  ('a031',1,'attended'),('a031',2,'attended'),('a031',3,'attended'),('a031',4,'cancelled'),
  ('a002',1,'attended'),('a002',2,'attended'),('a002',3,'attended'),('a002',4,'attended'),('a002',5,'attended'),
  ('c001',1,'attended'),('c001',2,'attended'),('c001',3,'attended'),('c001',4,'attended'),('c001',5,'no_show'),('c001',6,'no_show')
) as b(occ, mem, st);

-- A check-in for every attended seat (the statement still says "M checked in").
insert into check_ins (studio_id, booking_id, member_id, occurrence_id, method, checked_in_at)
select b.studio_id, b.id, b.member_id, b.occurrence_id, 'instructor', now()-interval '2 days 1 h'
  from bookings b where b.studio_id = '75d075d0-0000-0000-0000-000000000001' and b.status = 'attended';

-- --- the pay records were written on insert at the cut-off count -----------
select expect_eq('OG1 recorded at 6 booked = 120000', rec_amt('75d075d0-0000-0000-0000-00000000a001')::text, '120000');
select expect_eq('OG2 recorded at 3 booked = 97500',  rec_amt('75d075d0-0000-0000-0000-00000000a002')::text, '97500');

-- --- 6 booked, 4 attend, 2 no-show: paid on 6 ---------------------------------
select finalise_pay_true_up('75d075d0-0000-0000-0000-00000000a001');
select expect_eq('OG1 4 attended + 2 no-show is paid on 6 = 120000', rec_amt('75d075d0-0000-0000-0000-00000000a001')::text, '120000');
select expect_eq('OG1 basis checked_in = 4',      rec_checked('75d075d0-0000-0000-0000-00000000a001'), '4');
-- Decision 75 (l) with 81b: this suite's seats are unpaid drop-ins, and an unpaid
-- drop-in no-show adds no seat used, so 4 are used; the cut-off count of 6 still pays.
select expect_eq('OG1 basis heads_consumed = 4 (unpaid drop-in no-shows add none)',  rec_basis('75d075d0-0000-0000-0000-00000000a001','heads_consumed'), '4');
select expect_eq('OG1 basis heads_basis = cutoff (a tie stays cutoff)', rec_basis('75d075d0-0000-0000-0000-00000000a001','heads_basis'), 'cutoff');
select expect_eq('OG1 basis heads_paid = 6',      rec_basis('75d075d0-0000-0000-0000-00000000a001','heads_paid'), '6');
select expect_eq('OG1 basis keeps finalise_of',   rec_basis('75d075d0-0000-0000-0000-00000000a001','finalise_of'), '75d075d0-0000-0000-0000-00000000a001');
-- idempotent: a second run changes nothing.
select expect_eq('OG1 second finalise is a no-op',
  finalise_pay_true_up('75d075d0-0000-0000-0000-00000000a001') ->> 'already', 'finalised');
select expect_eq('OG1 still 120000', rec_amt('75d075d0-0000-0000-0000-00000000a001')::text, '120000');

-- --- a late cancel after the cut-off counts ---------------------------------
select finalise_pay_true_up('75d075d0-0000-0000-0000-00000000a011');
select expect_eq('OGlt 3 attended + 1 late cancel is paid on 4 = 105000', rec_amt('75d075d0-0000-0000-0000-00000000a011')::text, '105000');
select expect_eq('OGlt heads_basis = consumed', rec_basis('75d075d0-0000-0000-0000-00000000a011','heads_basis'), 'consumed');
select expect_eq('OGlt heads_consumed = 4',     rec_basis('75d075d0-0000-0000-0000-00000000a011','heads_consumed'), '4');

-- --- an on-time cancel does not count ------------------------------------------
select finalise_pay_true_up('75d075d0-0000-0000-0000-00000000a021');
select expect_eq('OGot 2 attended + 1 on-time cancel is paid on 2 = 90000', rec_amt('75d075d0-0000-0000-0000-00000000a021')::text, '90000');
select expect_eq('OGot heads_consumed = 2 (the on-time cancel is not a seat)', rec_basis('75d075d0-0000-0000-0000-00000000a021','heads_consumed'), '2');

-- --- pay never drops below the cut-off count ----------------------------------
select finalise_pay_true_up('75d075d0-0000-0000-0000-00000000a031');
select expect_eq('OGfl 3 consumed against 4 at the cut-off is paid on 4 = 105000', rec_amt('75d075d0-0000-0000-0000-00000000a031')::text, '105000');
select expect_eq('OGfl heads_basis = cutoff', rec_basis('75d075d0-0000-0000-0000-00000000a031','heads_basis'), 'cutoff');
select expect_eq('OGfl heads_consumed = 3',   rec_basis('75d075d0-0000-0000-0000-00000000a031','heads_consumed'), '3');

-- --- cover accepted after commit: the row names the cover instructor ---------
update class_occurrences set instructor_id = '75d075d0-0000-0000-0000-0000000a00b2'
 where id = '75d075d0-0000-0000-0000-00000000c001';
select finalise_pay_true_up('75d075d0-0000-0000-0000-00000000c001');
select expect_eq('OGcov pay row is re-copied to the cover instructor (Coach B)',
  rec_instr('75d075d0-0000-0000-0000-00000000c001')::text, '75d075d0-0000-0000-0000-0000000a00b2');
select expect_eq('OGcov paid on 6 = 120000', rec_amt('75d075d0-0000-0000-0000-00000000c001')::text, '120000');

-- --- private flat line untouched ---------------------------------------------
select expect_eq('OGpriv recorded at the flat private rate', rec_amt('75d075d0-0000-0000-0000-00000000e001')::text, '50000');
select finalise_pay_true_up('75d075d0-0000-0000-0000-00000000e001');
select expect_eq('OGpriv flat line is unchanged after finalise', rec_amt('75d075d0-0000-0000-0000-00000000e001')::text, '50000');

-- --- CLOSED period: an adjustment in the next open period --------------------
update pay_periods set status = 'closed'
 where id = (select period_id from instructor_pay_records where occurrence_id = '75d075d0-0000-0000-0000-00000000a002' and type='class');
select finalise_pay_true_up('75d075d0-0000-0000-0000-00000000a002');
select expect_eq('OG2 original class record is untouched (closed period)',
  rec_amt('75d075d0-0000-0000-0000-00000000a002')::text, '97500');
select expect_eq('an adjustment of +15000 lands for OG2 (5 consumed against 3)',
  (select amount_cents::text from instructor_pay_records
    where type='adjustment' and basis->>'finalise_of' = '75d075d0-0000-0000-0000-00000000a002'), '15000');
select expect_eq('the adjustment records heads_consumed = 5 and heads_basis = consumed',
  (select (basis->>'heads_consumed') || '/' || (basis->>'heads_basis') from instructor_pay_records
    where type='adjustment' and basis->>'finalise_of' = '75d075d0-0000-0000-0000-00000000a002'), '5/consumed');
select expect_eq('the adjustment names its original period',
  (select (basis->>'original_period' is not null)::text from instructor_pay_records
    where type='adjustment' and basis->>'finalise_of' = '75d075d0-0000-0000-0000-00000000a002'), 'true');
select expect_eq('the adjustment lands in an OPEN period',
  (select p.status::text from instructor_pay_records r join pay_periods p on p.id = r.period_id
    where r.type='adjustment' and r.basis->>'finalise_of' = '75d075d0-0000-0000-0000-00000000a002'), 'open');
select finalise_pay_true_up('75d075d0-0000-0000-0000-00000000a002');
select expect_eq('a second finalise of OG2 adds no second adjustment (idempotent on finalise_of)',
  (select count(*)::text from instructor_pay_records
    where type='adjustment' and basis->>'finalise_of' = '75d075d0-0000-0000-0000-00000000a002'), '1');

-- --- finalisation OFF: the row is never silently cut -------------------------
select expect_eq('OGoff (finalise off studio) recorded at 6 = 120000', rec_amt('75d075d0-0000-0000-0000-00000000f001')::text, '120000');
select expect_eq('finalise on an OFF studio is skipped',
  (finalise_pay_true_up('75d075d0-0000-0000-0000-00000000f001') ->> 'skipped'), 'finalisation_off');
select expect_eq('OGoff row is unchanged with finalisation off', rec_amt('75d075d0-0000-0000-0000-00000000f001')::text, '120000');

-- --- the statement says "paid on H" from heads_paid -----------------------------
-- pay_statement is self-or-manager; read it as the studio's owner.
insert into auth.users (id) values ('75d075d0-0000-0000-0000-0000000000a9');
insert into profiles (id, email, full_name) values ('75d075d0-0000-0000-0000-0000000000a9','75d0-owner@example.com','Owner');
insert into studio_staff (studio_id, user_id, email, role) values
  ('75d075d0-0000-0000-0000-000000000001','75d075d0-0000-0000-0000-0000000000a9','75d0-owner@example.com','owner');
select set_config('request.jwt.claim.sub', '75d075d0-0000-0000-0000-0000000000a9', false);
select expect_eq('pay_statement carries heads_paid = 6 for OG1',
  (select l ->> 'heads_paid' from jsonb_array_elements(
     pay_statement('75d075d0-0000-0000-0000-0000000a00a1',
       (select period_id from instructor_pay_records where occurrence_id='75d075d0-0000-0000-0000-00000000a001' and type='class')) -> 'lines') l
   where l ->> 'name' = 'OG1'), '6');
select set_config('request.jwt.claim.sub', '', false);

-- --- anon surface and the inbox table -----------------------------------------
select expect_eq('anon surface is EXACTLY FIFTEEN',
  (select count(*)::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not in ('expect_eq','rec_amt','rec_instr','rec_checked','rec_basis')), '15');
select expect_eq('the webhook inbox table is closed to anon reads with RLS on',
  (select (not has_table_privilege('anon','resend_webhook_inbox','select') and relrowsecurity)::text
     from pg_class where relname='resend_webhook_inbox'), 'true');

select 'finalise_pay_test OK' as result;
