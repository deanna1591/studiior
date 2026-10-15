-- =============================================================================
-- Decision 75b-1 (g) — checked-in pay basis at finalisation.
-- =============================================================================
-- UUID space 75d0, checked free. Run after `supabase db reset`.
--
-- A committed group class pays on booked_at_cutoff at commit (Decision 32), then
-- finalise_pay_true_up re-prices it on CHECKED-IN heads (count distinct member
-- from check_ins):
--   * 6 booked / 4 checked in, OPEN period -> recomputed in place, lower;
--   * CLOSED period -> adjustment in next_open_pay_period (signed), with
--     finalise_of + original_period;
--   * finalisation OFF -> skipped, row unchanged (never a silent cut);
--   * cover accepted after commit -> the row names the cover instructor;
--   * a second run changes nothing (idempotent on basis.finalised_at);
--   * a private (flat) line is untouched.
--
-- Rate: base 90000, per-head 7500 over a threshold of 2, no full-house, private
-- 50000. 6 heads = 90000 + 4*7500 = 120000; 4 heads = 90000 + 2*7500 = 105000.
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

insert into members (id, studio_id, first_name, last_name, email, waiver_signed_at) values
  ('75d075d0-0000-0000-0000-0000000d0001','75d075d0-0000-0000-0000-000000000001','M','One','75d0-1@example.com',now()),
  ('75d075d0-0000-0000-0000-0000000d0002','75d075d0-0000-0000-0000-000000000001','M','Two','75d0-2@example.com',now()),
  ('75d075d0-0000-0000-0000-0000000d0003','75d075d0-0000-0000-0000-000000000001','M','Three','75d0-3@example.com',now()),
  ('75d075d0-0000-0000-0000-0000000d0004','75d075d0-0000-0000-0000-000000000001','M','Four','75d0-4@example.com',now());

-- Group occurrences: committed (so a class pay record is written on insert),
-- booked_at_cutoff = 6, ended 2 days ago. OG1 open-in-place, OG2 closed-period,
-- OGcov cover. OGpriv private flat. OGoff on the finalise-OFF studio.
insert into class_occurrences (id, studio_id, location_id, class_type_id, instructor_id, name,
         starts_at, ends_at, capacity, booked_count, booked_at_cutoff, committed_at, status) values
  -- Staggered so Coach A is never in two overlapping classes (occ exclusion).
  ('75d075d0-0000-0000-0000-00000000a001','75d075d0-0000-0000-0000-000000000001','75d075d0-0000-0000-0000-00000000100c','75d075d0-0000-0000-0000-0000000cc001','75d075d0-0000-0000-0000-0000000a00a1','OG1',
     now()-interval '2 days 9 h', now()-interval '2 days 8 h', 10, 6, 6, now()-interval '3 days', 'scheduled'),
  ('75d075d0-0000-0000-0000-00000000a002','75d075d0-0000-0000-0000-000000000001','75d075d0-0000-0000-0000-00000000100c','75d075d0-0000-0000-0000-0000000cc001','75d075d0-0000-0000-0000-0000000a00a1','OG2',
     now()-interval '2 days 7 h', now()-interval '2 days 6 h', 10, 6, 6, now()-interval '3 days', 'scheduled'),
  ('75d075d0-0000-0000-0000-00000000c001','75d075d0-0000-0000-0000-000000000001','75d075d0-0000-0000-0000-00000000100c','75d075d0-0000-0000-0000-0000000cc001','75d075d0-0000-0000-0000-0000000a00a1','OGcov',
     now()-interval '2 days 5 h', now()-interval '2 days 4 h', 10, 6, 6, now()-interval '3 days', 'scheduled'),
  ('75d075d0-0000-0000-0000-00000000e001','75d075d0-0000-0000-0000-000000000001','75d075d0-0000-0000-0000-00000000100c','75d075d0-0000-0000-0000-0000000cc0bb','75d075d0-0000-0000-0000-0000000a00a1','OGpriv',
     now()-interval '2 days 3 h', now()-interval '2 days 2 h', 1, 1, 1, now()-interval '3 days', 'scheduled'),
  ('75d075d0-0000-0000-0000-00000000f001','75d075d0-0000-0000-0000-000000000002','75d075d0-0000-0000-0000-00000000200c','75d075d0-0000-0000-0000-0000000cc002','75d075d0-0000-0000-0000-0000000a00f0','OGoff',
     now()-interval '2 days 9 h', now()-interval '2 days 8 h', 10, 6, 6, now()-interval '3 days', 'scheduled');

-- Bookings (4 members) on OG1/OG2/OGcov, each with a check_in -> 4 checked in.
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at)
select ('75d075d0-0000-0000-0000-0000000b'||occ||mem)::uuid,
       '75d075d0-0000-0000-0000-000000000001', occ_id, mem_id, 'booked','member','drop_in', now()-interval '3 days'
from (values
  ('a1','75d075d0-0000-0000-0000-00000000a001'::uuid),
  ('a2','75d075d0-0000-0000-0000-00000000a002'::uuid),
  ('c1','75d075d0-0000-0000-0000-00000000c001'::uuid)
) as o(occ, occ_id)
cross join (values
  ('01','75d075d0-0000-0000-0000-0000000d0001'::uuid),
  ('02','75d075d0-0000-0000-0000-0000000d0002'::uuid),
  ('03','75d075d0-0000-0000-0000-0000000d0003'::uuid),
  ('04','75d075d0-0000-0000-0000-0000000d0004'::uuid)
) as m(mem, mem_id);

insert into check_ins (studio_id, booking_id, member_id, occurrence_id, method, checked_in_at)
select '75d075d0-0000-0000-0000-000000000001', b.id, b.member_id, b.occurrence_id, 'instructor', now()-interval '2 days 1 h'
  from bookings b where b.studio_id = '75d075d0-0000-0000-0000-000000000001'
   and b.occurrence_id in ('75d075d0-0000-0000-0000-00000000a001','75d075d0-0000-0000-0000-00000000a002','75d075d0-0000-0000-0000-00000000c001');

-- --- the pay records were written on insert at 6 heads --------------------
select expect_eq('OG1 recorded at 6 booked = 120000', rec_amt('75d075d0-0000-0000-0000-00000000a001')::text, '120000');
select expect_eq('OG2 recorded at 6 booked = 120000', rec_amt('75d075d0-0000-0000-0000-00000000a002')::text, '120000');

-- --- OPEN period: finalise on 4 checked in -> recomputed in place (lower) -----
select finalise_pay_true_up('75d075d0-0000-0000-0000-00000000a001');
select expect_eq('OG1 trued up on 4 checked in = 105000', rec_amt('75d075d0-0000-0000-0000-00000000a001')::text, '105000');
select expect_eq('OG1 basis records checked_in = 4', rec_checked('75d075d0-0000-0000-0000-00000000a001'), '4');
-- idempotent: a second run changes nothing.
select finalise_pay_true_up('75d075d0-0000-0000-0000-00000000a001');
select expect_eq('OG1 second finalise is a no-op', rec_amt('75d075d0-0000-0000-0000-00000000a001')::text, '105000');

-- --- cover accepted after commit: the row names the cover instructor ---------
update class_occurrences set instructor_id = '75d075d0-0000-0000-0000-0000000a00b2'
 where id = '75d075d0-0000-0000-0000-00000000c001';
select finalise_pay_true_up('75d075d0-0000-0000-0000-00000000c001');
select expect_eq('OGcov pay row is re-copied to the cover instructor (Coach B)',
  rec_instr('75d075d0-0000-0000-0000-00000000c001')::text, '75d075d0-0000-0000-0000-0000000a00b2');
select expect_eq('OGcov trued up on 4 = 105000', rec_amt('75d075d0-0000-0000-0000-00000000c001')::text, '105000');

-- --- private flat line untouched ---------------------------------------------
select expect_eq('OGpriv recorded at the flat private rate', rec_amt('75d075d0-0000-0000-0000-00000000e001')::text, '50000');
select finalise_pay_true_up('75d075d0-0000-0000-0000-00000000e001');
select expect_eq('OGpriv flat line is unchanged after finalise', rec_amt('75d075d0-0000-0000-0000-00000000e001')::text, '50000');

-- --- CLOSED period: an adjustment in the next open period --------------------
-- Close the period OG2's record sits in (direct, since close_pay_period needs a
-- manager session). finalise then leaves the record alone and adjusts forward.
update pay_periods set status = 'closed'
 where id = (select period_id from instructor_pay_records where occurrence_id = '75d075d0-0000-0000-0000-00000000a002' and type='class');
select finalise_pay_true_up('75d075d0-0000-0000-0000-00000000a002');
select expect_eq('OG2 original class record is untouched (closed period)',
  rec_amt('75d075d0-0000-0000-0000-00000000a002')::text, '120000');
select expect_eq('an adjustment of -15000 lands for OG2',
  (select amount_cents::text from instructor_pay_records
    where type='adjustment' and basis->>'finalise_of' = '75d075d0-0000-0000-0000-00000000a002'), '-15000');
select expect_eq('the adjustment names its original period',
  (select (basis->>'original_period' is not null)::text from instructor_pay_records
    where type='adjustment' and basis->>'finalise_of' = '75d075d0-0000-0000-0000-00000000a002'), 'true');
select expect_eq('the adjustment lands in an OPEN period',
  (select p.status::text from instructor_pay_records r join pay_periods p on p.id = r.period_id
    where r.type='adjustment' and r.basis->>'finalise_of' = '75d075d0-0000-0000-0000-00000000a002'), 'open');

-- --- finalisation OFF: the row is never silently cut -------------------------
select expect_eq('OGoff (finalise off studio) recorded at 6 = 120000', rec_amt('75d075d0-0000-0000-0000-00000000f001')::text, '120000');
select expect_eq('finalise on an OFF studio is skipped',
  (finalise_pay_true_up('75d075d0-0000-0000-0000-00000000f001') ->> 'skipped'), 'finalisation_off');
select expect_eq('OGoff row is unchanged with finalisation off', rec_amt('75d075d0-0000-0000-0000-00000000f001')::text, '120000');

select 'finalise_pay_test OK' as result;
