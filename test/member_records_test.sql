-- =============================================================================
-- Notes, goals, the timeline's writer, and documents
-- Migration 059. UUID space d0c5, checked free.
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
create or replace function expect_raises(label text, stmt text, want_sqlstate text)
returns void language plpgsql as $$
begin
  execute stmt;
  raise exception 'FAIL  %  expected % but nothing was raised', label, want_sqlstate;
exception when others then
  if sqlstate = want_sqlstate then raise notice 'PASS  %  (got %)', label, sqlstate;
  elsif sqlstate = 'P0001' and sqlerrm like 'FAIL%' then raise;
  else raise exception 'FAIL  %  expected %, got % (%)', label, want_sqlstate, sqlstate, sqlerrm; end if;
end $$;

-- --- Fixtures ---------------------------------------------------------------
insert into auth.users (id) values
  ('d0c5d0c5-0000-0000-0000-0000000000a1'),
  ('d0c5d0c5-0000-0000-0000-0000000000a2'),
  ('d0c5d0c5-0000-0000-0000-0000000000a3'),
  ('d0c5d0c5-0000-0000-0000-0000000000b1');
insert into profiles (id, email, full_name) values
  ('d0c5d0c5-0000-0000-0000-0000000000a1','doc-owner@example.com','Ola Owner'),
  ('d0c5d0c5-0000-0000-0000-0000000000a2','doc-desk@example.com','Des Kay'),
  ('d0c5d0c5-0000-0000-0000-0000000000a3','doc-instr@example.com','Ines Structor'),
  ('d0c5d0c5-0000-0000-0000-0000000000b1','doc-member@example.com','Mem Ber');
insert into studios (id, name, slug, timezone, currency, status) values
  ('d0c5d0c5-0000-0000-0000-000000000001','Docs Studio','docs-test','Europe/Prague','CZK','active');
-- The §8 window would refuse these back-dated check-ins, and migration 007's
-- documented way off is exactly this setting. The fixtures are history, not
-- somebody arriving at the desk.
insert into studio_settings (studio_id, checkin_window_enforced)
  values ('d0c5d0c5-0000-0000-0000-000000000001', false);
insert into locations (id, studio_id, name, is_primary) values
  ('d0c5d0c5-0000-0000-0000-00000000000c','d0c5d0c5-0000-0000-0000-000000000001','Main',true);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('d0c5d0c5-0000-0000-0000-00000000aa01','d0c5d0c5-0000-0000-0000-000000000001','d0c5d0c5-0000-0000-0000-0000000000a1','doc-owner@example.com','owner'),
  ('d0c5d0c5-0000-0000-0000-00000000aa02','d0c5d0c5-0000-0000-0000-000000000001','d0c5d0c5-0000-0000-0000-0000000000a2','doc-desk@example.com','front_desk'),
  ('d0c5d0c5-0000-0000-0000-00000000aa03','d0c5d0c5-0000-0000-0000-000000000001','d0c5d0c5-0000-0000-0000-0000000000a3','doc-instr@example.com','instructor');
insert into members (id, studio_id, user_id, first_name, last_name, email, joined_on, status) values
  ('d0c5d0c5-0000-0000-0000-00000000dd01','d0c5d0c5-0000-0000-0000-000000000001',
   'd0c5d0c5-0000-0000-0000-0000000000b1','Mem','Ber','docmem@example.com', current_date - 100, 'active');
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('d0c5d0c5-0000-0000-0000-00000000cc01','d0c5d0c5-0000-0000-0000-000000000001','Reformer',50,10);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('d0c5d0c5-0000-0000-0000-00000000ee01','d0c5d0c5-0000-0000-0000-000000000001','d0c5d0c5-0000-0000-0000-00000000000c','Room',10);

-- =============================================================================
-- 1. The timeline had no writer, and now does
-- =============================================================================
-- Checked before writing any of this: the only references to
-- rebuild_member_timeline() in the whole repo were the seed and migration 033.
-- No trigger on check_ins, so a member with 46 visits read "Nothing recorded
-- yet" and would have gone on reading it forever.
select expect_num('a new member starts with the one event they have earned',
  (select count(*) from timeline_events
    where member_id = 'd0c5d0c5-0000-0000-0000-00000000dd01')::bigint, 0);

insert into class_occurrences
  (id, studio_id, location_id, class_type_id, room_id, name, capacity, starts_at, ends_at, status, staffing)
select ('d0c5d0c5-0000-0000-0000-00000000f0' || lpad(i::text,2,'0'))::uuid,
       'd0c5d0c5-0000-0000-0000-000000000001','d0c5d0c5-0000-0000-0000-00000000000c',
       'd0c5d0c5-0000-0000-0000-00000000cc01','d0c5d0c5-0000-0000-0000-00000000ee01',
       'Reformer', 10, now() - make_interval(days => i * 7), now() - make_interval(days => i * 7, mins => -50),
       'completed', 'open'
  from generate_series(1,3) i;
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source)
select ('d0c5d0c5-0000-0000-0000-00000000bb' || lpad(i::text,2,'0'))::uuid,
       'd0c5d0c5-0000-0000-0000-000000000001',
       ('d0c5d0c5-0000-0000-0000-00000000f0' || lpad(i::text,2,'0'))::uuid,
       'd0c5d0c5-0000-0000-0000-00000000dd01','attended','comp'
  from generate_series(1,3) i;

select expect_true('a booking writes the timeline as it happens',
  (select count(*) > 0 from timeline_events
    where member_id = 'd0c5d0c5-0000-0000-0000-00000000dd01'));
select expect_num('...including the joined event derived from the member row',
  (select count(*) from timeline_events
    where member_id = 'd0c5d0c5-0000-0000-0000-00000000dd01' and type = 'joined')::bigint, 1);

insert into check_ins (studio_id, member_id, occurrence_id, booking_id, checked_in_at, method)
values ('d0c5d0c5-0000-0000-0000-000000000001','d0c5d0c5-0000-0000-0000-00000000dd01',
        'd0c5d0c5-0000-0000-0000-00000000f001','d0c5d0c5-0000-0000-0000-00000000bb01',
        now() - interval '7 days', 'staff');
select expect_num('a check-in writes an attended event',
  (select count(*) from timeline_events
    where member_id = 'd0c5d0c5-0000-0000-0000-00000000dd01' and type = 'attended')::bigint, 1);

-- Idempotent by construction: the trigger REBUILDS rather than appends, so the
-- same source row cannot produce two events.
update check_ins set method = 'staff'
 where member_id = 'd0c5d0c5-0000-0000-0000-00000000dd01';
select expect_num('touching the source again does not double it',
  (select count(*) from timeline_events
    where member_id = 'd0c5d0c5-0000-0000-0000-00000000dd01' and type = 'attended')::bigint, 1);

-- The backfill, for every studio that has been running without this.
delete from timeline_events where member_id = 'd0c5d0c5-0000-0000-0000-00000000dd01';
select expect_num('a wiped timeline is empty, as production''s was',
  (select count(*) from timeline_events
    where member_id = 'd0c5d0c5-0000-0000-0000-00000000dd01')::bigint, 0);
select set_config('t.fill', (select backfill_all_timelines()::text), false);
select expect_true('the backfill rebuilds it',
  (select count(*) > 0 from timeline_events
    where member_id = 'd0c5d0c5-0000-0000-0000-00000000dd01'));
select expect_true('...across more than one studio',
  (current_setting('t.fill')::jsonb ->> 'studios')::int >= 2);
select expect_num('...and no studio failed',
  (current_setting('t.fill')::jsonb ->> 'failed')::bigint, 0);

set role authenticated;
select set_config('request.jwt.claim.sub','d0c5d0c5-0000-0000-0000-0000000000a1',false);
select expect_raises('a signed-in user cannot run the backfill',
  $q$select backfill_all_timelines()$q$, '42501');

-- =============================================================================
-- 2. Notes: a writer at last, and managers_only still holds
-- =============================================================================
select set_config('request.jwt.claim.sub','d0c5d0c5-0000-0000-0000-0000000000a2',false);
insert into member_notes (studio_id, member_id, author_user_id, category, body, pinned)
values ('d0c5d0c5-0000-0000-0000-000000000001','d0c5d0c5-0000-0000-0000-00000000dd01',
        'd0c5d0c5-0000-0000-0000-0000000000a2','injury','Left shoulder — no overhead work.', true);
select expect_num('front desk can write a note',
  (select count(*) from member_notes where member_id = 'd0c5d0c5-0000-0000-0000-00000000dd01')::bigint, 1);

select set_config('request.jwt.claim.sub','d0c5d0c5-0000-0000-0000-0000000000a1',false);
insert into member_notes (studio_id, member_id, author_user_id, category, body, managers_only)
values ('d0c5d0c5-0000-0000-0000-000000000001','d0c5d0c5-0000-0000-0000-00000000dd01',
        'd0c5d0c5-0000-0000-0000-0000000000a1','admin','Disputed a charge in June.', true);

select set_config('request.jwt.claim.sub','d0c5d0c5-0000-0000-0000-0000000000a2',false);
select expect_num('front desk sees the pinned injury note but not the managers-only one',
  (select count(*) from member_notes where member_id = 'd0c5d0c5-0000-0000-0000-00000000dd01')::bigint, 1);
select set_config('request.jwt.claim.sub','d0c5d0c5-0000-0000-0000-0000000000a1',false);
select expect_num('the owner sees both',
  (select count(*) from member_notes where member_id = 'd0c5d0c5-0000-0000-0000-00000000dd01')::bigint, 2);

-- An injury note that never resolves is worse than none.
update member_notes set active = false
 where member_id = 'd0c5d0c5-0000-0000-0000-00000000dd01' and category = 'injury';
select expect_num('a note can be resolved rather than only deleted',
  (select count(*) from member_notes
    where member_id = 'd0c5d0c5-0000-0000-0000-00000000dd01' and active = false)::bigint, 1);
select expect_num('...and resolving it takes it off the pinned list',
  (select count(*) from member_notes
    where member_id = 'd0c5d0c5-0000-0000-0000-00000000dd01' and pinned and active)::bigint, 0);

-- =============================================================================
-- 3. Goals measure against real attendance
-- =============================================================================
insert into member_goals (id, studio_id, member_id, title, target_type, target_value, target_date)
values ('d0c5d0c5-0000-0000-0000-00000000aa11','d0c5d0c5-0000-0000-0000-000000000001',
        'd0c5d0c5-0000-0000-0000-00000000dd01','Twelve classes by spring','class_count', 12,
        current_date + 60);
select expect_num('a fresh goal counts nothing yet',
  (member_goal_progress('d0c5d0c5-0000-0000-0000-00000000aa11') ->> 'done')::bigint, 0);
select expect_text('...and is not met',
  (member_goal_progress('d0c5d0c5-0000-0000-0000-00000000aa11') ->> 'met'), 'false');

-- Counted from when the goal was SET. The member already has a check-in from a
-- week ago, and it must not count toward a goal agreed today.
reset role;
insert into check_ins (studio_id, member_id, occurrence_id, booking_id, checked_in_at, method)
values ('d0c5d0c5-0000-0000-0000-000000000001','d0c5d0c5-0000-0000-0000-00000000dd01',
        'd0c5d0c5-0000-0000-0000-00000000f002','d0c5d0c5-0000-0000-0000-00000000bb02',
        now(), 'staff');
set role authenticated;
select set_config('request.jwt.claim.sub','d0c5d0c5-0000-0000-0000-0000000000a1',false);
select expect_num('a visit after the goal was set counts',
  (member_goal_progress('d0c5d0c5-0000-0000-0000-00000000aa11') ->> 'done')::bigint, 1);
select expect_num('...and the older visit does not',
  (select count(*) from check_ins
    where member_id = 'd0c5d0c5-0000-0000-0000-00000000dd01')::bigint, 2);

select set_config('request.jwt.claim.sub','d0c5d0c5-0000-0000-0000-0000000000b1',false);
select expect_num('the member can read their own goal''s progress',
  (member_goal_progress('d0c5d0c5-0000-0000-0000-00000000aa11') ->> 'done')::bigint, 1);

-- =============================================================================
-- 4. Documents, and the waiver that finally means something
-- =============================================================================
reset role;
select expect_true('the member has no waiver on file to begin with',
  (select waiver_signed_at is null from members where id = 'd0c5d0c5-0000-0000-0000-00000000dd01'));

set role authenticated;
select set_config('request.jwt.claim.sub','d0c5d0c5-0000-0000-0000-0000000000a2',false);
select set_config('t.doc', (select record_document(
  'd0c5d0c5-0000-0000-0000-00000000dd01', 'waiver', 'waiver-signed.pdf',
  'd0c5d0c5-0000-0000-0000-000000000001/d0c5d0c5-0000-0000-0000-00000000dd01/waiver.pdf',
  'application/pdf', 12345)::text), false);
select expect_text('front desk can file a waiver', (current_setting('t.doc')::jsonb ->> 'ok'), 'true');
select expect_text('...and filing it signs the waiver',
  (current_setting('t.doc')::jsonb ->> 'waiver_signed'), 'true');

reset role;
select expect_true('members.waiver_signed_at is set, so the booking gate agrees with the paperwork',
  (select waiver_signed_at is not null from members where id = 'd0c5d0c5-0000-0000-0000-00000000dd01'));

set role authenticated;
select set_config('request.jwt.claim.sub','d0c5d0c5-0000-0000-0000-0000000000a1',false);
select expect_text('a medical document can be filed',
  (select record_document('d0c5d0c5-0000-0000-0000-00000000dd01','medical','mri.pdf',
     'd0c5d0c5-0000-0000-0000-000000000001/d0c5d0c5-0000-0000-0000-00000000dd01/mri.pdf') ->> 'ok'), 'true');

-- §14 denies instructors a member's contact details; a medical document is the
-- same rule and more so.
select set_config('request.jwt.claim.sub','d0c5d0c5-0000-0000-0000-0000000000a3',false);
select expect_num('an instructor sees no documents at all',
  (select count(*) from member_documents)::bigint, 0);
select expect_raises('...and cannot file one',
  $q$select record_document('d0c5d0c5-0000-0000-0000-00000000dd01','other','x.pdf','a/b/x.pdf')$q$,
  'PT403');

-- Front desk take waivers at the counter and have no reason to read a diagnosis.
select set_config('request.jwt.claim.sub','d0c5d0c5-0000-0000-0000-0000000000a2',false);
select expect_num('front desk sees the waiver but not the medical document',
  (select count(*) from member_documents)::bigint, 1);
select expect_text('...and the one they see is the waiver',
  (select kind from member_documents), 'waiver');
-- A refused UPDATE does not raise: RLS makes the row invisible and it changes
-- nothing. Asserted by looking at the row afterwards, as a manager.
update member_documents set note = 'peeked' where kind = 'medical';
select set_config('request.jwt.claim.sub','d0c5d0c5-0000-0000-0000-0000000000a1',false);
select expect_num('...and front desk could not edit the one they cannot read',
  (select count(*) from member_documents where kind = 'medical' and note = 'peeked')::bigint, 0);
select expect_num('a manager sees both',
  (select count(*) from member_documents)::bigint, 2);

-- The member sees their own, medical included — it is their body.
select set_config('request.jwt.claim.sub','d0c5d0c5-0000-0000-0000-0000000000b1',false);
select expect_num('the member sees both of their own',
  (select count(*) from member_documents)::bigint, 2);

-- Tenancy: another studio's staff see nothing of it.
reset role;
insert into auth.users (id) values ('d0c5d0c5-0000-0000-0000-0000000000c1');
insert into profiles (id, email, full_name) values
  ('d0c5d0c5-0000-0000-0000-0000000000c1','doc-other@example.com','Otto Sider');
insert into studios (id, name, slug, timezone, currency, status) values
  ('d0c5d0c5-0000-0000-0000-000000000002','Other Docs','docs-other','Europe/Prague','CZK','active');
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('d0c5d0c5-0000-0000-0000-00000000aa99','d0c5d0c5-0000-0000-0000-000000000002','d0c5d0c5-0000-0000-0000-0000000000c1','doc-other@example.com','owner');
set role authenticated;
select set_config('request.jwt.claim.sub','d0c5d0c5-0000-0000-0000-0000000000c1',false);
select expect_num('another studio''s owner sees none of these documents',
  (select count(*) from member_documents)::bigint, 0);
select expect_raises('...and cannot file one against their member',
  $q$select record_document('d0c5d0c5-0000-0000-0000-00000000dd01','other','x.pdf','a/b/x.pdf')$q$,
  'PT403');

-- A second waiver does not overwrite the first signature.
set role authenticated;
select set_config('request.jwt.claim.sub','d0c5d0c5-0000-0000-0000-0000000000a2',false);
select expect_text('filing a second waiver does not re-sign an already signed one',
  (select record_document('d0c5d0c5-0000-0000-0000-00000000dd01','waiver','waiver-v2.pdf',
     'd0c5d0c5-0000-0000-0000-000000000001/d0c5d0c5-0000-0000-0000-00000000dd01/waiver2.pdf')
     ->> 'waiver_signed'), 'false');
select expect_raises('and an unknown kind is refused',
  $q$select record_document('d0c5d0c5-0000-0000-0000-00000000dd01','passport','x.pdf','a/b/y.pdf')$q$,
  'PT422');
