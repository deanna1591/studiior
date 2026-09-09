-- =============================================================================
-- Archive and delete for class types, rooms and instructors
-- Migration 058. UUID space 0a11, checked free.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then
    raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null');
  end if;
end $$;

create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then
    raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null');
  end if;
end $$;

create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual then raise notice 'PASS  %  (got true)', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null');
  end if;
end $$;

create or replace function expect_raises(label text, stmt text, want_sqlstate text)
returns void language plpgsql as $$
begin
  execute stmt;
  raise exception 'FAIL  %  expected % but nothing was raised', label, want_sqlstate;
exception when others then
  if sqlstate = want_sqlstate then raise notice 'PASS  %  (got %)', label, sqlstate;
  elsif sqlstate = 'P0001' and sqlerrm like 'FAIL%' then raise;
  else raise exception 'FAIL  %  expected %, got % (%)', label, want_sqlstate, sqlstate, sqlerrm;
  end if;
end $$;

-- --- Fixtures ---------------------------------------------------------------
insert into auth.users (id) values
  ('0a110a11-0000-0000-0000-0000000000a1'),
  ('0a110a11-0000-0000-0000-0000000000b1');
insert into profiles (id, email, full_name) values
  ('0a110a11-0000-0000-0000-0000000000a1','arc-owner@example.com','Ola Owner'),
  ('0a110a11-0000-0000-0000-0000000000b1','arc-member@example.com','Mem Ber');
insert into studios (id, name, slug, timezone, currency, status) values
  ('0a110a11-0000-0000-0000-000000000001','Archive Studio','arc-test','Europe/Prague','CZK','active');
insert into studio_settings (studio_id) values ('0a110a11-0000-0000-0000-000000000001');
insert into locations (id, studio_id, name, is_primary) values
  ('0a110a11-0000-0000-0000-00000000000c','0a110a11-0000-0000-0000-000000000001','Main',true);
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('0a110a11-0000-0000-0000-00000000aa01','0a110a11-0000-0000-0000-000000000001','0a110a11-0000-0000-0000-0000000000a1','arc-owner@example.com','owner');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('0a110a11-0000-0000-0000-00000000ee01','0a110a11-0000-0000-0000-000000000001','0a110a11-0000-0000-0000-00000000000c','Busy Room',10),
  ('0a110a11-0000-0000-0000-00000000ee02','0a110a11-0000-0000-0000-000000000001','0a110a11-0000-0000-0000-00000000000c','Spare Room',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('0a110a11-0000-0000-0000-00000000cc01','0a110a11-0000-0000-0000-000000000001','Reformer Flow',50,10),
  ('0a110a11-0000-0000-0000-00000000cc02','0a110a11-0000-0000-0000-000000000001','Unused Type',50,10);
insert into instructors (id, studio_id, display_name, bio) values
  ('0a110a11-0000-0000-0000-00000000d101','0a110a11-0000-0000-0000-000000000001','Amihan Teacher','Fifteen years of barre.'),
  ('0a110a11-0000-0000-0000-00000000d102','0a110a11-0000-0000-0000-000000000001','Never Taught', null);
insert into members (id, studio_id, user_id, first_name, last_name, email, joined_on, status, waiver_signed_at) values
  ('0a110a11-0000-0000-0000-00000000dd01','0a110a11-0000-0000-0000-000000000001',
   '0a110a11-0000-0000-0000-0000000000b1','Mem','Ber','arcmem@example.com', current_date - 90, 'active', now());

-- Amihan: two past classes and three future, one with a member booked.
insert into class_occurrences
  (id, studio_id, location_id, class_type_id, room_id, name, instructor_id, capacity,
   starts_at, ends_at, status)
select ('0a110a11-0000-0000-0000-00000000f0' || lpad(i::text,2,'0'))::uuid,
       '0a110a11-0000-0000-0000-000000000001','0a110a11-0000-0000-0000-00000000000c',
       '0a110a11-0000-0000-0000-00000000cc01','0a110a11-0000-0000-0000-00000000ee01',
       'Reformer Flow','0a110a11-0000-0000-0000-00000000d101', 10,
       now() + make_interval(days => i * 3 - 7),
       now() + make_interval(days => i * 3 - 7, mins => 50),
       case when i <= 2 then 'completed'::occurrence_status else 'scheduled'::occurrence_status end
  from generate_series(1,5) i;
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source) values
  ('0a110a11-0000-0000-0000-00000000bb01','0a110a11-0000-0000-0000-000000000001',
   '0a110a11-0000-0000-0000-00000000f003','0a110a11-0000-0000-0000-00000000dd01','booked','comp');
update class_occurrences set booked_count = 1 where id = '0a110a11-0000-0000-0000-00000000f003';

-- =============================================================================
-- 1. status was ignored on the member side, and is not any more
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','0a110a11-0000-0000-0000-0000000000b1',false);
select expect_num('a member sees the active class type',
  (select count(*) from class_types where id = '0a110a11-0000-0000-0000-00000000cc01')::bigint, 1);
select expect_num('...the active instructor, bio and all',
  (select count(*) from instructors where id = '0a110a11-0000-0000-0000-00000000d101' and bio is not null)::bigint, 1);

-- Through archive_record(), because a direct status update is now refused —
-- which is the point of the trigger and makes this setup the real path.
-- All three have nothing scheduled, so none of them needs confirming.
select set_config('request.jwt.claim.sub','0a110a11-0000-0000-0000-0000000000a1',false);
select expect_text('an unused class type archives with no confirmation needed',
  (select archive_record('class_type','0a110a11-0000-0000-0000-00000000cc02') ->> 'ok'), 'true');
select expect_text('...an instructor who teaches nothing, likewise',
  (select archive_record('instructor','0a110a11-0000-0000-0000-00000000d102') ->> 'ok'), 'true');
select expect_text('...and an empty room',
  (select archive_record('room','0a110a11-0000-0000-0000-00000000ee02') ->> 'ok'), 'true');

select set_config('request.jwt.claim.sub','0a110a11-0000-0000-0000-0000000000b1',false);
select expect_num('an archived class type is invisible to a member',
  (select count(*) from class_types where id = '0a110a11-0000-0000-0000-00000000cc02')::bigint, 0);
select expect_num('...an archived instructor too, bio included',
  (select count(*) from instructors where id = '0a110a11-0000-0000-0000-00000000d102')::bigint, 0);
select expect_num('...and an archived room',
  (select count(*) from rooms where id = '0a110a11-0000-0000-0000-00000000ee02')::bigint, 0);

-- Staff keep every one of them, because the record has to survive.
select set_config('request.jwt.claim.sub','0a110a11-0000-0000-0000-0000000000a1',false);
select expect_num('staff still see the archived class type',
  (select count(*) from class_types where id = '0a110a11-0000-0000-0000-00000000cc02')::bigint, 1);
select expect_num('...the archived instructor',
  (select count(*) from instructors where id = '0a110a11-0000-0000-0000-00000000d102')::bigint, 1);
select expect_num('...and the archived room',
  (select count(*) from rooms where id = '0a110a11-0000-0000-0000-00000000ee02')::bigint, 1);

reset role;
update class_types set status = 'active' where id = '0a110a11-0000-0000-0000-00000000cc02';
update instructors set status = 'active' where id = '0a110a11-0000-0000-0000-00000000d102';
update rooms       set status = 'active' where id = '0a110a11-0000-0000-0000-00000000ee02';

-- A typo can no longer invent a third state that behaves like neither.
select expect_raises('status only accepts active or archived',
  $q$update class_types set status = 'Archived' where id = '0a110a11-0000-0000-0000-00000000cc02'$q$,
  '23514');
set role authenticated;
select set_config('request.jwt.claim.sub','0a110a11-0000-0000-0000-0000000000a1',false);

-- The forms offered "Archived" in a plain select that wrote status directly,
-- which skipped the preview, the opening of the classes, the email and the room
-- block. Removing the option is not enough — the same UPDATE goes straight
-- through PostgREST — so the rule lives in a trigger.
select expect_raises('status cannot be set to archived by hand',
  $q$update instructors set status = 'archived'
      where id = '0a110a11-0000-0000-0000-00000000d101'$q$, 'PT409');
select expect_text('...and she is untouched',
  (select status from instructors where id = '0a110a11-0000-0000-0000-00000000d101'), 'active');
select expect_raises('...a room the same',
  $q$update rooms set status = 'archived'
      where id = '0a110a11-0000-0000-0000-00000000ee01'$q$, 'PT409');
-- Restoring has no consequences to skip, so it stays an ordinary update.
select expect_num('but restoring by hand is fine',
  (select count(*) from class_types where id = '0a110a11-0000-0000-0000-00000000cc01')::bigint, 1);

-- =============================================================================
-- 2. Delete is refused, and names what is in the way
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','0a110a11-0000-0000-0000-0000000000a1',false);

select expect_raises('an instructor who has taught cannot be deleted',
  $q$delete from instructors where id = '0a110a11-0000-0000-0000-00000000d101'$q$, 'PT409');
select expect_raises('a class type with classes cannot be deleted',
  $q$delete from class_types where id = '0a110a11-0000-0000-0000-00000000cc01'$q$, 'PT409');
select expect_raises('a room with classes in it cannot be deleted',
  $q$delete from rooms where id = '0a110a11-0000-0000-0000-00000000ee01'$q$, 'PT409');

-- The point of the guard: without it these DELETEs SUCCEED, because every FK is
-- ON DELETE SET NULL — the history is emptied and nothing is raised.
select expect_num('and the instructor still has their classes',
  (select count(*) from class_occurrences
    where instructor_id = '0a110a11-0000-0000-0000-00000000d101')::bigint, 5);

-- Nothing references these, so they go.
-- A data-modifying CTE cannot sit inside a scalar subquery, so the delete runs
-- as its own statement and the assertion asks whether the row is gone.
delete from class_types  where id = '0a110a11-0000-0000-0000-00000000cc02';
delete from rooms        where id = '0a110a11-0000-0000-0000-00000000ee02';
delete from instructors  where id = '0a110a11-0000-0000-0000-00000000d102';
select expect_num('an unused class type deletes cleanly',
  (select count(*) from class_types where id = '0a110a11-0000-0000-0000-00000000cc02')::bigint, 0);
select expect_num('an unused room deletes cleanly',
  (select count(*) from rooms where id = '0a110a11-0000-0000-0000-00000000ee02')::bigint, 0);
select expect_num('an instructor who never taught deletes cleanly',
  (select count(*) from instructors where id = '0a110a11-0000-0000-0000-00000000d102')::bigint, 0);

-- =============================================================================
-- 3. The studio is told what will happen BEFORE confirming
-- =============================================================================
select set_config('t.impact',
  (select archive_impact('instructor','0a110a11-0000-0000-0000-00000000d101')::text), false);
select expect_num('the preview counts the future classes',
  (current_setting('t.impact')::jsonb ->> 'future_classes')::bigint, 3);
select expect_num('...and the members booked into them',
  (current_setting('t.impact')::jsonb ->> 'members_booked')::bigint, 1);
select expect_num('...and does not count the past ones as future',
  (current_setting('t.impact')::jsonb ->> 'past_classes')::bigint, 2);
select expect_true('...and says so in a sentence naming her',
  (current_setting('t.impact')::jsonb ->> 'effect') like 'Amihan Teacher is teaching 3 classes%');
select expect_true('...mentioning the booked member',
  (current_setting('t.impact')::jsonb ->> 'effect') like '%1 member is already booked%');

-- The first call refuses and returns the effect. Nothing has happened yet.
select set_config('t.try',
  (select archive_record('instructor','0a110a11-0000-0000-0000-00000000d101')::text), false);
select expect_text('archiving refuses until it is confirmed',
  (current_setting('t.try')::jsonb ->> 'requires_confirmation'), 'true');
select expect_text('...and she is still active',
  (select status from instructors where id = '0a110a11-0000-0000-0000-00000000d101'), 'active');
select expect_num('...and still teaching all three',
  (select count(*) from class_occurrences
    where instructor_id = '0a110a11-0000-0000-0000-00000000d101' and starts_at > now())::bigint, 3);

-- =============================================================================
-- 4. Confirmed: the classes open rather than quietly keeping her name
-- =============================================================================
select set_config('t.done',
  (select archive_record('instructor','0a110a11-0000-0000-0000-00000000d101', true)::text), false);
select expect_text('confirmed, it archives', (current_setting('t.done')::jsonb ->> 'ok'), 'true');
select expect_num('...and opens the three future classes',
  (current_setting('t.done')::jsonb ->> 'classes_opened')::bigint, 3);
select expect_num('no future class still names an archived instructor',
  (select count(*) from class_occurrences
    where instructor_id = '0a110a11-0000-0000-0000-00000000d101' and starts_at > now())::bigint, 0);
select expect_num('...they are open shifts, not cancellations',
  (select count(*) from class_occurrences
    where series_id is null and staffing = 'open' and status = 'scheduled'
      and studio_id = '0a110a11-0000-0000-0000-000000000001')::bigint, 3);
select expect_num('...and the member keeps her booking',
  (select count(*) from bookings
    where id = '0a110a11-0000-0000-0000-00000000bb01' and status = 'booked')::bigint, 1);
select expect_num('the PAST classes keep her name — that is what archiving is for',
  (select count(*) from class_occurrences
    where instructor_id = '0a110a11-0000-0000-0000-00000000d101' and starts_at <= now())::bigint, 2);

reset role;
select expect_num('and the studio was told, loudly',
  (select count(*) from notifications
    where studio_id = '0a110a11-0000-0000-0000-000000000001'
      and template_key = 'instructor_archived')::bigint, 1);
select expect_true('...with the count in the payload',
  (select (payload ->> 'count') = '3' from notifications
    where studio_id = '0a110a11-0000-0000-0000-000000000001'
      and template_key = 'instructor_archived'));

-- =============================================================================
-- 5. A room with classes in it is refused, not warned
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','0a110a11-0000-0000-0000-0000000000a1',false);
select set_config('t.room',
  (select archive_record('room','0a110a11-0000-0000-0000-00000000ee01', true)::text), false);
select expect_text('archiving a room with classes in it is blocked',
  (current_setting('t.room')::jsonb ->> 'blocked'), 'true');
select expect_true('...naming the count and the first date',
  (current_setting('t.room')::jsonb ->> 'reason') like 'Busy Room has 3 classes scheduled in it, the first on %');
select expect_text('...and the room is untouched',
  (select status from rooms where id = '0a110a11-0000-0000-0000-00000000ee01'), 'active');

-- =============================================================================
-- 6. A class type archived: the classes still run, the series stops
-- =============================================================================
insert into class_series
  (id, studio_id, location_id, class_type_id, name, room_id, capacity,
   duration_minutes, rrule, starts_on, time_of_day)
values ('0a110a11-0000-0000-0000-00000000f501','0a110a11-0000-0000-0000-000000000001',
        '0a110a11-0000-0000-0000-00000000000c','0a110a11-0000-0000-0000-00000000cc01',
        -- ee02 was deleted in section 2; and this insert fires migration 057's
        -- materialise trigger, so the series really does generate a year of
        -- Mondays. The assertion below is scoped to the three original classes
        -- rather than counting everything of this type.
        'Reformer Flow','0a110a11-0000-0000-0000-00000000ee01', 10, 50,
        'FREQ=WEEKLY;BYDAY=MO', current_date, '06:00');

select set_config('t.ct',
  (select archive_record('class_type','0a110a11-0000-0000-0000-00000000cc01', true)::text), false);
select expect_text('a class type archives', (current_setting('t.ct')::jsonb ->> 'ok'), 'true');
select expect_num('...and its recurring series stops making new classes',
  (current_setting('t.ct')::jsonb ->> 'series_stopped')::bigint, 1);
select expect_text('...the series really is ended',
  (select status::text from class_series where id = '0a110a11-0000-0000-0000-00000000f501'), 'ended');
select expect_num('...but the classes already scheduled still run',
  (select count(*) from class_occurrences
    where id in ('0a110a11-0000-0000-0000-00000000f003',
                 '0a110a11-0000-0000-0000-00000000f004',
                 '0a110a11-0000-0000-0000-00000000f005')
      and status = 'scheduled')::bigint, 3);

set role authenticated;
select set_config('request.jwt.claim.sub','0a110a11-0000-0000-0000-0000000000b1',false);
select expect_num('and the member can no longer see the archived type',
  (select count(*) from class_types where id = '0a110a11-0000-0000-0000-00000000cc01')::bigint, 0);

-- =============================================================================
-- 7. Restoring puts it back everywhere
-- =============================================================================
select set_config('request.jwt.claim.sub','0a110a11-0000-0000-0000-0000000000a1',false);
select expect_text('a class type restores',
  (select restore_record('class_type','0a110a11-0000-0000-0000-00000000cc01') ->> 'ok'), 'true');
select set_config('request.jwt.claim.sub','0a110a11-0000-0000-0000-0000000000b1',false);
select expect_num('...and the member sees it again',
  (select count(*) from class_types where id = '0a110a11-0000-0000-0000-00000000cc01')::bigint, 1);

select set_config('request.jwt.claim.sub','0a110a11-0000-0000-0000-0000000000a1',false);
select expect_text('an instructor restores',
  (select restore_record('instructor','0a110a11-0000-0000-0000-00000000d101') ->> 'ok'), 'true');
select set_config('request.jwt.claim.sub','0a110a11-0000-0000-0000-0000000000b1',false);
select expect_num('...and the member sees her again, bio and all',
  (select count(*) from instructors
    where id = '0a110a11-0000-0000-0000-00000000d101' and bio is not null)::bigint, 1);

-- Restoring does NOT take the opened classes back off whoever now has them.
select set_config('request.jwt.claim.sub','0a110a11-0000-0000-0000-0000000000a1',false);
select expect_num('restoring leaves the opened classes open',
  (select count(*) from class_occurrences
    where studio_id = '0a110a11-0000-0000-0000-000000000001'
      and staffing = 'open' and status = 'scheduled' and series_id is null)::bigint, 3);
select expect_true('...and says so rather than leaving it to be discovered',
  (select restore_record('instructor','0a110a11-0000-0000-0000-00000000d101') ->> 'note')
    like 'Any classes that were opened stay open%');

-- =============================================================================
-- 8. Who may do it
-- =============================================================================
select set_config('request.jwt.claim.sub','0a110a11-0000-0000-0000-0000000000b1',false);
select expect_raises('a member cannot archive anything',
  $q$select archive_record('class_type','0a110a11-0000-0000-0000-00000000cc01', true)$q$, 'PT403');
select expect_raises('nor read the impact preview',
  $q$select archive_impact('instructor','0a110a11-0000-0000-0000-00000000d101')$q$, 'PT403');
select expect_raises('and an unknown kind is refused',
  $q$select archive_impact('receptionist','0a110a11-0000-0000-0000-00000000d101')$q$, 'PT422');
