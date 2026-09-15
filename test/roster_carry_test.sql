-- =============================================================================
-- G — the roster deadline and carry-forward on silence. Migration 141.
-- UUID space c4f0. Run after `supabase db reset`.
-- =============================================================================
-- A silent instructor past the 5-day deadline has last month's confirmed
-- roster carried into this one — matched on weekday + local clock time + class
-- type. Archived / moved / no-match / already-staffed do NOT carry and are
-- reported; a slot outside the instructor's availability IS carried, flagged.
-- Only assigned-AND-confirmed source classes seed it; cover-flagged ones do not.
-- OFF by default, per tenant. Studio in UTC so stored time == local clock time.
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
create or replace function expect_txt(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if;
end $$;
-- Count report entries for instructor I whose reason matches a pattern.
create or replace function report_has(inst uuid, pat text) returns bigint language sql stable as $$
  select count(*) from jsonb_array_elements(roster_carry_plan(
           'c4f0c4f0-0000-0000-0000-000000000001', inst, date '2026-12-01') -> 'report') e
   where e ->> 'reason' ilike pat;
$$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values ('c4f0c4f0-0000-0000-0000-0000000000a1');
insert into profiles (id, email) values ('c4f0c4f0-0000-0000-0000-0000000000a1','c4f0-own@example.com');
insert into studios (id,name,slug,timezone,currency,status) values
  ('c4f0c4f0-0000-0000-0000-000000000001','Carry On','c4f0-a','UTC','USD','active'),
  ('c4f0c4f0-0000-0000-0000-000000000002','Carry Off','c4f0-b','UTC','USD','active');
insert into studio_settings (studio_id, carry_forward_enabled, roster_confirm_days) values
  ('c4f0c4f0-0000-0000-0000-000000000001', true,  5),
  ('c4f0c4f0-0000-0000-0000-000000000002', false, 5);
insert into studio_staff (id,studio_id,user_id,email,role) values
  ('c4f0c4f0-0000-0000-0000-0000000a0001','c4f0c4f0-0000-0000-0000-000000000001','c4f0c4f0-0000-0000-0000-0000000000a1','c4f0-o1@example.com','owner');
insert into locations (id,studio_id,name,is_primary) values
  ('c4f0c4f0-0000-0000-0000-00000000000a','c4f0c4f0-0000-0000-0000-000000000001','Main',true),
  ('c4f0c4f0-0000-0000-0000-00000000000b','c4f0c4f0-0000-0000-0000-000000000002','Main',true);
insert into instructors (id,studio_id,display_name,status) values
  ('c4f0c4f0-0000-0000-0000-0000000d0001','c4f0c4f0-0000-0000-0000-000000000001','Ivy','active'),   -- the silent one carried
  ('c4f0c4f0-0000-0000-0000-0000000d0002','c4f0c4f0-0000-0000-0000-000000000001','Ben','active'),   -- occupies a slot (already staffed)
  ('c4f0c4f0-0000-0000-0000-0000000d0003','c4f0c4f0-0000-0000-0000-000000000001','Cy','active'),    -- source month NOT confirmed
  ('c4f0c4f0-0000-0000-0000-0000000d0004','c4f0c4f0-0000-0000-0000-000000000001','Dot','active'),   -- not past deadline
  ('c4f0c4f0-0000-0000-0000-0000000d0005','c4f0c4f0-0000-0000-0000-000000000002','Eve','active');   -- off-by-default studio
insert into class_types (id,studio_id,name,duration_minutes,default_capacity,status) values
  ('c4f0c4f0-0000-0000-0000-0000000cc001','c4f0c4f0-0000-0000-0000-000000000001','Reformer',50,8,'active'),
  ('c4f0c4f0-0000-0000-0000-0000000cc002','c4f0c4f0-0000-0000-0000-000000000001','Barre',50,8,'archived'),
  ('c4f0c4f0-0000-0000-0000-0000000cc003','c4f0c4f0-0000-0000-0000-000000000002','Reformer',50,8,'active');

-- Ivy's stated availability: only the weekday of Nov 3 (so Nov 7's weekday is
-- outside it). 06:00-22:00 covers the 07:00/08:00 slots.
insert into instructor_availability (studio_id, instructor_id, day_of_week, starts_at_time, ends_at_time) values
  ('c4f0c4f0-0000-0000-0000-000000000001','c4f0c4f0-0000-0000-0000-0000000d0001', extract(dow from date '2026-11-03')::int, '06:00','22:00');

-- roster_confirmations. Nov = source month, Dec = the silent month.
insert into roster_confirmations (studio_id, instructor_id, month, notified_at, confirmed_at) values
  -- Ivy: confirmed Nov, silent Dec past the 5-day deadline
  ('c4f0c4f0-0000-0000-0000-000000000001','c4f0c4f0-0000-0000-0000-0000000d0001','2026-11-01', now()-interval '40 days', now()-interval '35 days'),
  ('c4f0c4f0-0000-0000-0000-000000000001','c4f0c4f0-0000-0000-0000-0000000d0001','2026-12-01', now()-interval '6 days',  null),
  -- Cy: Nov NOT confirmed
  ('c4f0c4f0-0000-0000-0000-000000000001','c4f0c4f0-0000-0000-0000-0000000d0003','2026-11-01', now()-interval '40 days', null),
  ('c4f0c4f0-0000-0000-0000-000000000001','c4f0c4f0-0000-0000-0000-0000000d0003','2026-12-01', now()-interval '6 days',  null),
  -- Dot: confirmed Nov, but Dec notified only yesterday (deadline not passed)
  ('c4f0c4f0-0000-0000-0000-000000000001','c4f0c4f0-0000-0000-0000-0000000d0004','2026-11-01', now()-interval '40 days', now()-interval '35 days'),
  ('c4f0c4f0-0000-0000-0000-000000000001','c4f0c4f0-0000-0000-0000-0000000d0004','2026-12-01', now()-interval '1 day',   null),
  -- Eve at the OFF studio: confirmed Nov, silent Dec past deadline
  ('c4f0c4f0-0000-0000-0000-000000000002','c4f0c4f0-0000-0000-0000-0000000d0005','2026-11-01', now()-interval '40 days', now()-interval '35 days'),
  ('c4f0c4f0-0000-0000-0000-000000000002','c4f0c4f0-0000-0000-0000-0000000d0005','2026-12-01', now()-interval '6 days',  null);

-- SOURCE occurrences (November), all Ivy's unless noted. Nov 3 + 28 days = Dec 1
-- (same weekday); Nov 7 + 28 = Dec 5.
insert into class_occurrences (id,studio_id,location_id,class_type_id,room_id,instructor_id,name,starts_at,ends_at,capacity,booked_count,status,is_exception) values
  ('c4f0c4f0-0000-0000-0000-0000000a0001','c4f0c4f0-0000-0000-0000-000000000001','c4f0c4f0-0000-0000-0000-00000000000a','c4f0c4f0-0000-0000-0000-0000000cc001',null,'c4f0c4f0-0000-0000-0000-0000000d0001','P1 Reformer','2026-11-03 07:00+00','2026-11-03 07:50+00',8,0,'scheduled',false),
  ('c4f0c4f0-0000-0000-0000-0000000a0002','c4f0c4f0-0000-0000-0000-000000000001','c4f0c4f0-0000-0000-0000-00000000000a','c4f0c4f0-0000-0000-0000-0000000cc002',null,'c4f0c4f0-0000-0000-0000-0000000d0001','P2 Barre','2026-11-03 09:00+00','2026-11-03 09:50+00',8,0,'scheduled',false),
  ('c4f0c4f0-0000-0000-0000-0000000a0003','c4f0c4f0-0000-0000-0000-000000000001','c4f0c4f0-0000-0000-0000-00000000000a','c4f0c4f0-0000-0000-0000-0000000cc001',null,'c4f0c4f0-0000-0000-0000-0000000d0001','P3 moved','2026-11-03 18:00+00','2026-11-03 18:50+00',8,0,'scheduled',true),
  ('c4f0c4f0-0000-0000-0000-0000000a0004','c4f0c4f0-0000-0000-0000-000000000001','c4f0c4f0-0000-0000-0000-00000000000a','c4f0c4f0-0000-0000-0000-0000000cc001',null,'c4f0c4f0-0000-0000-0000-0000000d0001','P4 nomatch','2026-11-03 12:00+00','2026-11-03 12:50+00',8,0,'scheduled',false),
  ('c4f0c4f0-0000-0000-0000-0000000a0005','c4f0c4f0-0000-0000-0000-000000000001','c4f0c4f0-0000-0000-0000-00000000000a','c4f0c4f0-0000-0000-0000-0000000cc001',null,'c4f0c4f0-0000-0000-0000-0000000d0001','P5 staffed','2026-11-03 10:00+00','2026-11-03 10:50+00',8,0,'scheduled',false),
  ('c4f0c4f0-0000-0000-0000-0000000a0006','c4f0c4f0-0000-0000-0000-000000000001','c4f0c4f0-0000-0000-0000-00000000000a','c4f0c4f0-0000-0000-0000-0000000cc001',null,'c4f0c4f0-0000-0000-0000-0000000d0001','P6 avail','2026-11-07 08:00+00','2026-11-07 08:50+00',8,0,'scheduled',false),
  ('c4f0c4f0-0000-0000-0000-0000000a0007','c4f0c4f0-0000-0000-0000-000000000001','c4f0c4f0-0000-0000-0000-00000000000a','c4f0c4f0-0000-0000-0000-0000000cc001',null,'c4f0c4f0-0000-0000-0000-0000000d0001','P7 cover','2026-11-03 14:00+00','2026-11-03 14:50+00',8,0,'scheduled',false),
  -- Cy source (Nov 4 -> Dec 2), Dot source (Nov 5 -> Dec 3), Eve source (Nov 3 -> Dec 1)
  ('c4f0c4f0-0000-0000-0000-0000000a0008','c4f0c4f0-0000-0000-0000-000000000001','c4f0c4f0-0000-0000-0000-00000000000a','c4f0c4f0-0000-0000-0000-0000000cc001',null,'c4f0c4f0-0000-0000-0000-0000000d0003','Cy src','2026-11-04 07:00+00','2026-11-04 07:50+00',8,0,'scheduled',false),
  ('c4f0c4f0-0000-0000-0000-0000000a0009','c4f0c4f0-0000-0000-0000-000000000001','c4f0c4f0-0000-0000-0000-00000000000a','c4f0c4f0-0000-0000-0000-0000000cc001',null,'c4f0c4f0-0000-0000-0000-0000000d0004','Dot src','2026-11-05 07:00+00','2026-11-05 07:50+00',8,0,'scheduled',false),
  ('c4f0c4f0-0000-0000-0000-0000000a000e','c4f0c4f0-0000-0000-0000-000000000002','c4f0c4f0-0000-0000-0000-00000000000b','c4f0c4f0-0000-0000-0000-0000000cc003',null,'c4f0c4f0-0000-0000-0000-0000000d0005','Eve src','2026-11-03 07:00+00','2026-11-03 07:50+00',8,0,'scheduled',false);

-- P7 was handed back through cover last month -> not "assigned AND confirmed".
insert into cover_requests (studio_id, occurrence_id, instructor_id, status) values
  ('c4f0c4f0-0000-0000-0000-000000000001','c4f0c4f0-0000-0000-0000-0000000a0007','c4f0c4f0-0000-0000-0000-0000000d0001','pending');

-- TARGET occurrences (December). Open unless noted.
insert into class_occurrences (id,studio_id,location_id,class_type_id,room_id,instructor_id,name,starts_at,ends_at,capacity,booked_count,status,is_exception,staffing) values
  ('c4f0c4f0-0000-0000-0000-0000000b0001','c4f0c4f0-0000-0000-0000-000000000001','c4f0c4f0-0000-0000-0000-00000000000a','c4f0c4f0-0000-0000-0000-0000000cc001',null,null,'T P1','2026-12-01 07:00+00','2026-12-01 07:50+00',8,0,'scheduled',false,'open'),
  ('c4f0c4f0-0000-0000-0000-0000000b0005','c4f0c4f0-0000-0000-0000-000000000001','c4f0c4f0-0000-0000-0000-00000000000a','c4f0c4f0-0000-0000-0000-0000000cc001',null,'c4f0c4f0-0000-0000-0000-0000000d0002','T P5','2026-12-01 10:00+00','2026-12-01 10:50+00',8,0,'scheduled',false,'assigned'),
  ('c4f0c4f0-0000-0000-0000-0000000b0006','c4f0c4f0-0000-0000-0000-000000000001','c4f0c4f0-0000-0000-0000-00000000000a','c4f0c4f0-0000-0000-0000-0000000cc001',null,null,'T P6','2026-12-05 08:00+00','2026-12-05 08:50+00',8,0,'scheduled',false,'open'),
  ('c4f0c4f0-0000-0000-0000-0000000b0007','c4f0c4f0-0000-0000-0000-000000000001','c4f0c4f0-0000-0000-0000-00000000000a','c4f0c4f0-0000-0000-0000-0000000cc001',null,null,'T P7','2026-12-01 14:00+00','2026-12-01 14:50+00',8,0,'scheduled',false,'open'),
  ('c4f0c4f0-0000-0000-0000-0000000b0008','c4f0c4f0-0000-0000-0000-000000000001','c4f0c4f0-0000-0000-0000-00000000000a','c4f0c4f0-0000-0000-0000-0000000cc001',null,null,'T Cy','2026-12-02 07:00+00','2026-12-02 07:50+00',8,0,'scheduled',false,'open'),
  ('c4f0c4f0-0000-0000-0000-0000000b0009','c4f0c4f0-0000-0000-0000-000000000001','c4f0c4f0-0000-0000-0000-00000000000a','c4f0c4f0-0000-0000-0000-0000000cc001',null,null,'T Dot','2026-12-03 07:00+00','2026-12-03 07:50+00',8,0,'scheduled',false,'open'),
  ('c4f0c4f0-0000-0000-0000-0000000b000e','c4f0c4f0-0000-0000-0000-000000000002','c4f0c4f0-0000-0000-0000-00000000000b','c4f0c4f0-0000-0000-0000-0000000cc003',null,null,'T Eve','2026-12-01 07:00+00','2026-12-01 07:50+00',8,0,'scheduled',false,'open');

-- =============================================================================
-- The plan's report, before applying (Ivy).
-- =============================================================================
select expect_num('archived class type -> not carried, reported',
  report_has('c4f0c4f0-0000-0000-0000-0000000d0001','%archived%'), 1);
select expect_num('moved source (a one-off, not a standing slot) -> not carried, reported',
  report_has('c4f0c4f0-0000-0000-0000-0000000d0001','%moved%'), 1);
select expect_num('no matching class this month -> reported',
  report_has('c4f0c4f0-0000-0000-0000-0000000d0001','%no matching%'), 1);
select expect_num('a slot already staffed -> reported',
  report_has('c4f0c4f0-0000-0000-0000-0000000d0001','%already staffed%'), 1);
select expect_num('outside availability -> carried WITH a warning',
  report_has('c4f0c4f0-0000-0000-0000-0000000d0001','%outside%availability%'), 1);
select expect_num('two slots would carry (the clean one and the flagged one)',
  jsonb_array_length(roster_carry_plan('c4f0c4f0-0000-0000-0000-000000000001','c4f0c4f0-0000-0000-0000-0000000d0001', date '2026-12-01') -> 'carry'), 2);
select expect_true('cover-flagged source is excluded entirely (not in the report)',
  (report_has('c4f0c4f0-0000-0000-0000-0000000d0001','%')) = 5);  -- 4 not-carried + 1 warning, P7 absent

-- =============================================================================
-- Apply, and check the assignments.
-- =============================================================================
select carry_forward_roster('c4f0c4f0-0000-0000-0000-000000000001', date '2026-12-01') \gset
select expect_txt('the clean match is assigned to Ivy',
  (select instructor_id::text from class_occurrences where id='c4f0c4f0-0000-0000-0000-0000000b0001'),
  'c4f0c4f0-0000-0000-0000-0000000d0001');
select expect_txt('the outside-availability match is STILL assigned (carried with a warning)',
  (select instructor_id::text from class_occurrences where id='c4f0c4f0-0000-0000-0000-0000000b0006'),
  'c4f0c4f0-0000-0000-0000-0000000d0001');
select expect_true('the cover-flagged slot is left open',
  (select instructor_id is null from class_occurrences where id='c4f0c4f0-0000-0000-0000-0000000b0007'));
select expect_txt('an already-staffed slot is never overwritten',
  (select instructor_id::text from class_occurrences where id='c4f0c4f0-0000-0000-0000-0000000b0005'),
  'c4f0c4f0-0000-0000-0000-0000000d0002');
select expect_true('Ivy''s December row is marked carried',
  (select carried_at is not null from roster_confirmations where instructor_id='c4f0c4f0-0000-0000-0000-0000000d0001' and month='2026-12-01'));

-- Source not confirmed -> nothing carried for Cy.
select expect_true('a month the instructor never confirmed does not seed a carry',
  (select instructor_id is null from class_occurrences where id='c4f0c4f0-0000-0000-0000-0000000b0008'));
-- Not past the deadline -> Dot is not carried.
select expect_true('before the deadline passes, nothing is carried',
  (select instructor_id is null from class_occurrences where id='c4f0c4f0-0000-0000-0000-0000000b0009'));

-- Idempotent: a second pass assigns nothing more.
select (carry_forward_roster('c4f0c4f0-0000-0000-0000-000000000001', date '2026-12-01') ->> 'classes_assigned')::int as second_pass \gset
select expect_num('a second carry pass assigns nothing (idempotent)', :second_pass, 0);

-- =============================================================================
-- OFF by default: the switch is the only thing between a studio and this.
-- =============================================================================
select expect_true('preview at a switched-off studio reports disabled',
  (roster_carry_preview('c4f0c4f0-0000-0000-0000-000000000002', date '2026-12-01') ->> 'enabled')::boolean = false);
select (carry_forward_roster('c4f0c4f0-0000-0000-0000-000000000002', date '2026-12-01') ->> 'classes_assigned')::int as off_assigned \gset
select expect_num('a switched-off studio carries nothing even with a silent instructor', :off_assigned, 0);
select expect_true('the off studio''s open slot stays open',
  (select instructor_id is null from class_occurrences where id='c4f0c4f0-0000-0000-0000-0000000b000e'));

-- Teeth: turn the ON studio OFF, undo the carry, and it no longer carries.
update roster_confirmations set carried_at = null where instructor_id='c4f0c4f0-0000-0000-0000-0000000d0001' and month='2026-12-01';
update class_occurrences set instructor_id = null, staffing='open' where id='c4f0c4f0-0000-0000-0000-0000000b0001';
update studio_settings set carry_forward_enabled = false where studio_id='c4f0c4f0-0000-0000-0000-000000000001';
select (carry_forward_roster('c4f0c4f0-0000-0000-0000-000000000001', date '2026-12-01') ->> 'classes_assigned')::int as teeth_assigned \gset
select expect_num('teeth: with the switch off, the same silent instructor carries nothing', :teeth_assigned, 0);
select expect_true('teeth: the clean slot stays open with the switch off',
  (select instructor_id is null from class_occurrences where id='c4f0c4f0-0000-0000-0000-0000000b0001'));

do $$ begin raise notice 'roster_carry_test: all assertions passed'; end $$;
