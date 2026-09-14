-- =============================================================================
-- Payroll is optional — migration 139. UUID space 0b71.
-- =============================================================================
-- Reform Collective's ladder is ONE studio's contract, not a product rule.
-- A studio that uses neither guarantees nor flex must generate NO instructor
-- pay — absent, not zero — even if a rate version is on file. And a studio whose
-- rate sets only base_rate gets a flat amount per class with no ladder.
-- Run after `supabase db reset`.
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
begin if actual then raise notice 'PASS  %', label; else raise exception 'FAIL  %  expected true', label; end if; end $$;

-- --- Fixtures ----------------------------------------------------------------
-- OFF_NORATE: guarantees off, no rate versions (the studio that never opted in).
-- OFF_RATE:   guarantees off, a stray rate version on file (import or by hand).
-- ON_FLAT:    guarantees on, a base-only rate version (flat pay, no ladder).
insert into studios (id,name,slug,timezone,currency,status) values
  ('0b710b71-0000-0000-0000-000000000001','Off NoRate','0b71-a','Asia/Manila','PHP','active'),
  ('0b710b71-0000-0000-0000-000000000002','Off Rate','0b71-b','Asia/Manila','PHP','active'),
  ('0b710b71-0000-0000-0000-000000000003','On Flat','0b71-c','Asia/Manila','PHP','active');
insert into studio_settings (studio_id, guarantees_enabled, flex_enabled, core_min_bookings, core_cutoff_hours) values
  ('0b710b71-0000-0000-0000-000000000001', false, false, 1, 12),
  ('0b710b71-0000-0000-0000-000000000002', false, false, 1, 12),
  ('0b710b71-0000-0000-0000-000000000003', true,  false, 1, 12);
insert into locations (id,studio_id,name,is_primary) values
  ('0b710b71-0000-0000-0000-00000000000a','0b710b71-0000-0000-0000-000000000001','M',true),
  ('0b710b71-0000-0000-0000-00000000000b','0b710b71-0000-0000-0000-000000000002','M',true),
  ('0b710b71-0000-0000-0000-00000000000c','0b710b71-0000-0000-0000-000000000003','M',true);
insert into instructors (id,studio_id,display_name,status) values
  ('0b710b71-0000-0000-0000-0000000d0001','0b710b71-0000-0000-0000-000000000001','I1','active'),
  ('0b710b71-0000-0000-0000-0000000d0002','0b710b71-0000-0000-0000-000000000002','I2','active'),
  ('0b710b71-0000-0000-0000-0000000d0003','0b710b71-0000-0000-0000-000000000003','I3','active');
insert into class_types (id,studio_id,name,duration_minutes,default_capacity) values
  ('0b710b71-0000-0000-0000-0000000cc001','0b710b71-0000-0000-0000-000000000001','R',50,6),
  ('0b710b71-0000-0000-0000-0000000cc002','0b710b71-0000-0000-0000-000000000002','R',50,6),
  ('0b710b71-0000-0000-0000-0000000cc003','0b710b71-0000-0000-0000-000000000003','R',50,6);
insert into rooms (id,studio_id,location_id,name,capacity) values
  ('0b710b71-0000-0000-0000-0000000ee001','0b710b71-0000-0000-0000-000000000001','0b710b71-0000-0000-0000-00000000000a','R',6),
  ('0b710b71-0000-0000-0000-0000000ee002','0b710b71-0000-0000-0000-000000000002','0b710b71-0000-0000-0000-00000000000b','R',6),
  ('0b710b71-0000-0000-0000-0000000ee003','0b710b71-0000-0000-0000-000000000003','0b710b71-0000-0000-0000-00000000000c','R',6);
-- OFF_RATE and ON_FLAT have rate versions; OFF_NORATE has NONE. ON_FLAT sets
-- ONLY base — per_head, threshold, full_house and the private rates default 0/null.
insert into instructor_rate_versions (studio_id,instructor_id,effective_from,currency,base_rate_cents) values
  ('0b710b71-0000-0000-0000-000000000002','0b710b71-0000-0000-0000-0000000d0002', current_date-10,'PHP',90000),
  ('0b710b71-0000-0000-0000-000000000003','0b710b71-0000-0000-0000-0000000d0003', current_date-10,'PHP',90000);

-- =============================================================================
-- Optionality: a cancelled class generates NO pay record at a studio that uses
-- neither guarantees nor flex — with or without a rate version on file.
-- =============================================================================
insert into class_occurrences (id,studio_id,location_id,class_type_id,room_id,instructor_id,name,starts_at,ends_at,capacity,booked_count,status) values
  ('0b710b71-0000-0000-0000-00000000c001','0b710b71-0000-0000-0000-000000000001','0b710b71-0000-0000-0000-00000000000a','0b710b71-0000-0000-0000-0000000cc001','0b710b71-0000-0000-0000-0000000ee001','0b710b71-0000-0000-0000-0000000d0001','A', now()+interval '2 h', now()+interval '3 h',6,0,'scheduled'),
  ('0b710b71-0000-0000-0000-00000000c002','0b710b71-0000-0000-0000-000000000002','0b710b71-0000-0000-0000-00000000000b','0b710b71-0000-0000-0000-0000000cc002','0b710b71-0000-0000-0000-0000000ee002','0b710b71-0000-0000-0000-0000000d0002','B', now()+interval '2 h', now()+interval '3 h',6,0,'scheduled');
update class_occurrences set status='cancelled', cancellation_cause='studio_fault', cancelled_at=now()
 where id in ('0b710b71-0000-0000-0000-00000000c001','0b710b71-0000-0000-0000-00000000c002');

select expect_num('guarantees off + NO rate version: a cancelled class generates no pay record',
  (select count(*) from instructor_pay_records where studio_id='0b710b71-0000-0000-0000-000000000001'), 0);
select expect_num('guarantees off + a stray rate version: STILL no pay record (the leak, closed)',
  (select count(*) from instructor_pay_records where studio_id='0b710b71-0000-0000-0000-000000000002'), 0);

-- Teeth: turn guarantees ON at OFF_RATE and the same cancellation DOES pay,
-- proving the switch is the only thing standing between it and a record.
update studio_settings set guarantees_enabled = true where studio_id='0b710b71-0000-0000-0000-000000000002';
update class_occurrences set status='scheduled', cancellation_cause=null, cancelled_at=null where id='0b710b71-0000-0000-0000-00000000c002';
update class_occurrences set status='cancelled', cancellation_cause='studio_fault', cancelled_at=now() where id='0b710b71-0000-0000-0000-00000000c002';
select expect_num('teeth: with guarantees ON, the identical cancellation pays base (900)',
  (select amount_cents from instructor_pay_records where occurrence_id='0b710b71-0000-0000-0000-00000000c002'), 90000);
update studio_settings set guarantees_enabled = false where studio_id='0b710b71-0000-0000-0000-000000000002';

-- studio_uses_payroll is the predicate the app gates its Pay surfaces on.
select expect_true('studio_uses_payroll is false for a guarantees-off studio',
  studio_uses_payroll('0b710b71-0000-0000-0000-000000000001') = false);
select expect_true('studio_uses_payroll is true for a guarantees-on studio',
  studio_uses_payroll('0b710b71-0000-0000-0000-000000000003') = true);

-- =============================================================================
-- A base-only rate is a FLAT amount per class — no ladder implied.
-- =============================================================================
-- A class that RAN (committed), at headcount 1 and at capacity 6: both pay base,
-- because per_head, threshold and full_house are all zero.
insert into class_occurrences (id,studio_id,location_id,class_type_id,room_id,instructor_id,name,starts_at,ends_at,capacity,booked_count,booked_at_cutoff,committed_at,status) values
  ('0b710b71-0000-0000-0000-00000000f001','0b710b71-0000-0000-0000-000000000003','0b710b71-0000-0000-0000-00000000000c','0b710b71-0000-0000-0000-0000000cc003','0b710b71-0000-0000-0000-0000000ee003','0b710b71-0000-0000-0000-0000000d0003','Ran 1', now()+interval '2 h', now()+interval '3 h',6,1,1, now(),'scheduled'),
  ('0b710b71-0000-0000-0000-00000000f006','0b710b71-0000-0000-0000-000000000003','0b710b71-0000-0000-0000-00000000000c','0b710b71-0000-0000-0000-0000000cc003','0b710b71-0000-0000-0000-0000000ee003','0b710b71-0000-0000-0000-0000000d0003','Ran 6', now()+interval '4 h', now()+interval '5 h',6,6,6, now(),'scheduled');

select expect_num('base-only rate: a class of 1 pays base (900), no ladder',
  (compute_class_pay_run('0b710b71-0000-0000-0000-00000000f001') ->> 'amount_cents')::bigint, 90000);
select expect_num('base-only rate: a FULL class of 6 pays the SAME base (900) — no per-head, no full-house',
  (compute_class_pay_run('0b710b71-0000-0000-0000-00000000f006') ->> 'amount_cents')::bigint, 90000);
select expect_true('the basis shows no per-head rate and no full-house bonus were applied',
  (select (b ->> 'per_head_cents')::int = 0 and (b ->> 'full_house_bonus_cents')::int = 0
     from (select compute_class_pay_run('0b710b71-0000-0000-0000-00000000f006') -> 'basis' as b) x));

do $$ begin raise notice 'payroll_optional_test: all assertions passed'; end $$;
