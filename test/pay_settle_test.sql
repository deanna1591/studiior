-- =============================================================================
-- F — the payment date ("Friday after close"). Migration 140. UUID space 5e77.
-- =============================================================================
-- pay_settle_on() is the first occurrence of a day STRICTLY AFTER a period's
-- ends_on. OFF by default (null dow -> null date), PER TENANT. Two studios on
-- different settle days compute different dates for the same period end, and a
-- studio that has not set a day shows nothing. Run after `supabase db reset`.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_txt(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if;
end $$;

-- Call pay_statement as a given user and return just settle_on.
create or replace function stmt_settle(uid text, inst uuid, per uuid) returns text language plpgsql as $$
declare r text;
begin
  perform set_config('request.jwt.claim.sub', uid, true); set local role authenticated;
  begin select (pay_statement(inst, per) ->> 'settle_on') into r; return coalesce(r,'null');
  exception when others then return 'ERR:'||sqlstate; end;
end $$;
-- Same for the manager-only export.
create or replace function exp_settle(uid text, per uuid) returns text language plpgsql as $$
declare r text;
begin
  perform set_config('request.jwt.claim.sub', uid, true); set local role authenticated;
  begin select (pay_period_export(per) ->> 'settle_on') into r; return coalesce(r,'null');
  exception when others then return 'ERR:'||sqlstate; end;
end $$;

-- =============================================================================
-- The date arithmetic, with teeth. 2026-09-17 is a Thursday (dow 4),
-- 2026-09-18 a Friday (5), 2026-09-19 a Saturday (6).
-- =============================================================================
-- The WEEKDAY shape is unchanged (now the 3-arg form, offset null).
select expect_txt('Thursday end, Friday settle -> the very next day',
  pay_settle_on(date '2026-09-17', 5, null)::text, '2026-09-18');
select expect_txt('Friday end, Friday settle -> the NEXT Friday, never the same day (strictly after)',
  pay_settle_on(date '2026-09-18', 5, null)::text, '2026-09-25');
select expect_txt('Saturday end, Friday settle -> the following Friday',
  pay_settle_on(date '2026-09-19', 5, null)::text, '2026-09-25');
select expect_txt('Thursday end, Sunday settle -> that Sunday',
  pay_settle_on(date '2026-09-17', 0, null)::text, '2026-09-20');
select expect_txt('no settle day set -> no date (off)',
  coalesce(pay_settle_on(date '2026-09-18', null, null)::text, 'null'), 'null');
select expect_txt('an out-of-range day -> no date',
  coalesce(pay_settle_on(date '2026-09-18', 9, null)::text, 'null'), 'null');

-- Decision 31: the OFFSET shape. 0 = the close date itself.
select expect_txt('offset 0 on a 15th close pays the 15th',
  pay_settle_on(date '2026-03-15', null, 0)::text, '2026-03-15');
select expect_txt('offset 0 on a month-end close pays that last day (February, no special case)',
  pay_settle_on(date '2026-02-28', null, 0)::text, '2026-02-28');
select expect_txt('a leap February end pays the 29th',
  pay_settle_on(date '2028-02-29', null, 0)::text, '2028-02-29');
select expect_txt('offset 2 lands two days after close',
  pay_settle_on(date '2026-03-15', null, 2)::text, '2026-03-17');
select expect_txt('offset crossing a month boundary is a real date',
  pay_settle_on(date '2026-03-31', null, 3)::text, '2026-04-03');

-- =============================================================================
-- Per tenant, through the statement. Three studios, same period ends_on
-- (Friday 2026-09-18): Friday settle, Wednesday settle, and OFF.
-- =============================================================================
insert into auth.users (id) values ('5e775e77-0000-0000-0000-0000000000a1');
insert into profiles (id, email) values ('5e775e77-0000-0000-0000-0000000000a1','5e77-own@example.com');
insert into studios (id,name,slug,timezone,currency,status) values
  ('5e775e77-0000-0000-0000-000000000001','Set A','5e77-a','Asia/Manila','PHP','active'),
  ('5e775e77-0000-0000-0000-000000000002','Set B','5e77-b','Asia/Manila','PHP','active'),
  ('5e775e77-0000-0000-0000-000000000003','Set C','5e77-c','Asia/Manila','PHP','active');
-- Friday=5, Wednesday=3, and null (never set).
insert into studio_settings (studio_id, pay_settle_dow) values
  ('5e775e77-0000-0000-0000-000000000001', 5),
  ('5e775e77-0000-0000-0000-000000000002', 3),
  ('5e775e77-0000-0000-0000-000000000003', null);
-- One person owns all three, so pay_statement's manager-up guard passes for each.
insert into studio_staff (id,studio_id,user_id,email,role) values
  ('5e775e77-0000-0000-0000-0000000a0001','5e775e77-0000-0000-0000-000000000001','5e775e77-0000-0000-0000-0000000000a1','5e77-o1@example.com','owner'),
  ('5e775e77-0000-0000-0000-0000000a0002','5e775e77-0000-0000-0000-000000000002','5e775e77-0000-0000-0000-0000000000a1','5e77-o2@example.com','owner'),
  ('5e775e77-0000-0000-0000-0000000a0003','5e775e77-0000-0000-0000-000000000003','5e775e77-0000-0000-0000-0000000000a1','5e77-o3@example.com','owner');
insert into instructors (id,studio_id,display_name,status) values
  ('5e775e77-0000-0000-0000-0000000d0001','5e775e77-0000-0000-0000-000000000001','I1','active'),
  ('5e775e77-0000-0000-0000-0000000d0002','5e775e77-0000-0000-0000-000000000002','I2','active'),
  ('5e775e77-0000-0000-0000-0000000d0003','5e775e77-0000-0000-0000-000000000003','I3','active');
insert into pay_periods (id,studio_id,starts_on,ends_on,status) values
  ('5e775e77-0000-0000-0000-0000000f0001','5e775e77-0000-0000-0000-000000000001', date '2026-09-05', date '2026-09-18','open'),
  ('5e775e77-0000-0000-0000-0000000f0002','5e775e77-0000-0000-0000-000000000002', date '2026-09-05', date '2026-09-18','open'),
  ('5e775e77-0000-0000-0000-0000000f0003','5e775e77-0000-0000-0000-000000000003', date '2026-09-05', date '2026-09-18','open');

select expect_txt('studio on Friday settle: statement names the next Friday',
  stmt_settle('5e775e77-0000-0000-0000-0000000000a1','5e775e77-0000-0000-0000-0000000d0001','5e775e77-0000-0000-0000-0000000f0001'),
  '2026-09-25');
select expect_txt('SAME period end, studio on Wednesday settle: a different date',
  stmt_settle('5e775e77-0000-0000-0000-0000000000a1','5e775e77-0000-0000-0000-0000000d0002','5e775e77-0000-0000-0000-0000000f0002'),
  '2026-09-23');
select expect_txt('studio with no settle day: the statement shows no payment date',
  stmt_settle('5e775e77-0000-0000-0000-0000000000a1','5e775e77-0000-0000-0000-0000000d0003','5e775e77-0000-0000-0000-0000000f0003'),
  'null');

-- The export carries the same period-level date (manager only).
select expect_txt('export names the settle date at period level',
  exp_settle('5e775e77-0000-0000-0000-0000000000a1','5e775e77-0000-0000-0000-0000000f0001'), '2026-09-25');
select expect_txt('export shows no date for a studio with no settle day',
  exp_settle('5e775e77-0000-0000-0000-0000000000a1','5e775e77-0000-0000-0000-0000000f0003'), 'null');

-- =============================================================================
-- Decision 31: exactly one shape (the CHECK), the offset bounded, and the offset
-- carried through the statement. Studio A has dow=5, B has dow=3 (from above).
-- =============================================================================
do $$
begin
  begin
    update studio_settings set pay_settle_offset_days = 0
      where studio_id = '5e775e77-0000-0000-0000-000000000001';   -- already has dow=5
    raise exception 'NO_REFUSAL';
  exception
    when check_violation then raise notice 'PASS  both settle shapes at once is refused by the CHECK (23514)';
    when others then raise exception 'FAIL  expected check_violation, got %', sqlstate;
  end;
end $$;
do $$
begin
  begin
    update studio_settings set pay_settle_dow = null, pay_settle_offset_days = 32
      where studio_id = '5e775e77-0000-0000-0000-000000000002';
    raise exception 'NO_REFUSAL';
  exception
    when check_violation then raise notice 'PASS  an offset of 32 is refused by the bounds CHECK';
    when others then raise exception 'FAIL  expected check_violation for offset 32, got %', sqlstate;
  end;
end $$;

-- A studio on the OFFSET shape (0 = close date), semimonthly second period ending
-- on a month-end: the statement names that last day. Proves the re-issued reader
-- passes the offset into pay_settle_on.
insert into studios (id,name,slug,timezone,currency,status) values
  ('5e775e77-0000-0000-0000-000000000004','Set D','5e77-d','Asia/Manila','PHP','active');
insert into studio_settings (studio_id, pay_settle_offset_days) values
  ('5e775e77-0000-0000-0000-000000000004', 0);
insert into studio_staff (id,studio_id,user_id,email,role) values
  ('5e775e77-0000-0000-0000-0000000a0004','5e775e77-0000-0000-0000-000000000004','5e775e77-0000-0000-0000-0000000000a1','5e77-o4@example.com','owner');
insert into instructors (id,studio_id,display_name,status) values
  ('5e775e77-0000-0000-0000-0000000d0004','5e775e77-0000-0000-0000-000000000004','I4','active');
insert into pay_periods (id,studio_id,starts_on,ends_on,status) values
  ('5e775e77-0000-0000-0000-0000000f0004','5e775e77-0000-0000-0000-000000000004', date '2026-02-16', date '2026-02-28','open');
select expect_txt('offset-0 studio: the statement pays on the period end (Feb month-end)',
  stmt_settle('5e775e77-0000-0000-0000-0000000000a1','5e775e77-0000-0000-0000-0000000d0004','5e775e77-0000-0000-0000-0000000f0004'),
  '2026-02-28');

do $$ begin raise notice 'pay_settle_test: all assertions passed'; end $$;
