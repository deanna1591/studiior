-- =============================================================================
-- Housekeeping — tokens, test sends, small fixes (migration 20260833080000).
-- UUID space 48ee, checked free. Run after `supabase db reset`.
-- =============================================================================
--   1. send_template_test on instructor_assigned and booking_cancelled_committed
--      returns ok with nothing stripped (the sample context carries every
--      instructor-side token).
--   2. booking emails carry {manage_link} and {book_url} in every payload.
--   3. waitlist_offer / waitlist_missed carry {first_name} and {claim_url}.
--   5. the flex cut-off cancellation notifies the assigned instructor with
--      instructor_class_cancelled and reason "didn't reach its minimum by the
--      cut-off"; the default template carries {reason}.
--   6. a member reaching 10 attended classes queues ONE '10 classes' milestone;
--      a second attended queues none; {milestone_name} is words.
--   7. convert_missed_you default template has no em dash.
-- (Task 4 — booking_cancelled_committed {cancelled_count}/{booked}/{capacity} —
--  is asserted in guarantee_contract_test, where the committed-cancel scenario
--  already exists.)
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
begin
  if actual then raise notice 'PASS  %  (got true)', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('48ee0000-0000-0000-0000-0000000000a1'),   -- owner/manager OWN (has email)
  ('48ee0000-0000-0000-0000-0000000000d1'),   -- instructor I1's login
  ('48ee0000-0000-0000-0000-0000000000e1'),   -- member M1
  ('48ee0000-0000-0000-0000-0000000000e2');   -- member M2 (milestones)
insert into profiles (id, email, full_name) values
  ('48ee0000-0000-0000-0000-0000000000a1','48ee-own@example.com','Olive Owner'),
  ('48ee0000-0000-0000-0000-0000000000d1','48ee-i1@example.com','Ada Instructor'),
  ('48ee0000-0000-0000-0000-0000000000e1','48ee-m1@example.com','Mia One'),
  ('48ee0000-0000-0000-0000-0000000000e2','48ee-m2@example.com','Noa Two');

insert into studios (id, name, slug, timezone, currency, country, accent_color, status) values
  ('48ee0000-0000-0000-0000-000000000001','House Studio','hk-48ee','Asia/Manila','PHP','PH','#B85C38','active');
insert into studio_settings (studio_id, flex_enabled, flex_deadline_mode, flex_deadline_hours,
                             free_first_class_enabled, free_first_confirm_at, reminder_hours_before) values
  ('48ee0000-0000-0000-0000-000000000001', true, 'hours_before', 168, true, 2, 12);
insert into locations (id, studio_id, name, is_primary) values
  ('48ee0000-0000-0000-0000-0000000000a0','48ee0000-0000-0000-0000-000000000001','Main',true);
insert into studio_staff (id, studio_id, user_id, email, role, status) values
  ('48ee0000-0000-0000-0000-00000a000001','48ee0000-0000-0000-0000-000000000001','48ee0000-0000-0000-0000-0000000000a1','48ee-own@example.com','owner','active'),
  ('48ee0000-0000-0000-0000-00000a0000d1','48ee0000-0000-0000-0000-000000000001','48ee0000-0000-0000-0000-0000000000d1','48ee-i1@example.com','instructor','active');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('48ee0000-0000-0000-0000-0000000ee001','48ee0000-0000-0000-0000-000000000001','48ee0000-0000-0000-0000-0000000000a0','R1',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('48ee0000-0000-0000-0000-0000000cc001','48ee0000-0000-0000-0000-000000000001','Reformer',50,10);
insert into instructors (id, studio_id, staff_id, display_name, status) values
  ('48ee0000-0000-0000-0000-0000000d0001','48ee0000-0000-0000-0000-000000000001','48ee0000-0000-0000-0000-00000a0000d1','Ada Instructor','active');
insert into members (id, studio_id, user_id, first_name, last_name, email, joined_on, status, waiver_signed_at) values
  ('48ee0000-0000-0000-0000-00000dd00001','48ee0000-0000-0000-0000-000000000001','48ee0000-0000-0000-0000-0000000000e1','Mia','One','48ee-m1@example.com', current_date-30,'active', now()),
  ('48ee0000-0000-0000-0000-00000dd00002','48ee0000-0000-0000-0000-000000000001','48ee0000-0000-0000-0000-0000000000e2','Noa','Two','48ee-m2@example.com', current_date-30,'active', now());

-- =============================================================================
-- 2. BOOKING EMAILS CARRY {manage_link} + {book_url}
-- =============================================================================
-- An ordinary (non-flex, paid) booking -> booking_confirmed + class_reminder.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name, capacity,
                               starts_at, ends_at, status, staffing, flex) values
  ('48ee0000-0000-0000-0000-00000c010001','48ee0000-0000-0000-0000-000000000001','48ee0000-0000-0000-0000-0000000000a0',
   '48ee0000-0000-0000-0000-0000000cc001','48ee0000-0000-0000-0000-0000000ee001','Plain Class',10,
   now()+interval '7 days', now()+interval '7 days'+interval '50 min','scheduled','open',false);
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source, provisional, booked_at) values
  ('48ee0000-0000-0000-0000-00000b010001','48ee0000-0000-0000-0000-000000000001','48ee0000-0000-0000-0000-00000c010001','48ee0000-0000-0000-0000-00000dd00001','booked','drop_in',false, now());
select queue_booking_notifications('48ee0000-0000-0000-0000-00000b010001');

select expect_true('booking_confirmed carries manage_link (the class page)',
  (select payload->>'manage_link' like '%/class/48ee0000-0000-0000-0000-00000c010001' from notifications
    where template_key='booking_confirmed' and member_id='48ee0000-0000-0000-0000-00000dd00001'));
select expect_true('booking_confirmed carries book_url (the Book tab)',
  (select payload->>'book_url' like '%/book' from notifications
    where template_key='booking_confirmed' and member_id='48ee0000-0000-0000-0000-00000dd00001'));
select expect_true('class_reminder carries manage_link + book_url',
  (select payload->>'manage_link' like '%/class/%' and payload->>'book_url' like '%/book' from notifications
    where template_key='class_reminder' and member_id='48ee0000-0000-0000-0000-00000dd00001'));

-- A flex booking (undecided) -> flex_booking_pending.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name, capacity,
                               starts_at, ends_at, status, staffing, flex, minimum_bookings) values
  ('48ee0000-0000-0000-0000-00000c010002','48ee0000-0000-0000-0000-000000000001','48ee0000-0000-0000-0000-0000000000a0',
   '48ee0000-0000-0000-0000-0000000cc001','48ee0000-0000-0000-0000-0000000ee001','Flex Pending',10,
   now()+interval '5 days', now()+interval '5 days'+interval '50 min','scheduled','open',true,3);
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source, provisional, booked_at) values
  ('48ee0000-0000-0000-0000-00000b010002','48ee0000-0000-0000-0000-000000000001','48ee0000-0000-0000-0000-00000c010002','48ee0000-0000-0000-0000-00000dd00001','booked','drop_in',false, now());
select queue_booking_notifications('48ee0000-0000-0000-0000-00000b010002');
select expect_true('flex_booking_pending carries manage_link + book_url',
  (select payload->>'manage_link' like '%/class/%' and payload->>'book_url' like '%/book' from notifications
    where template_key='flex_booking_pending' and member_id='48ee0000-0000-0000-0000-00000dd00001'));

-- A comp+provisional free seat -> free_booking_pending.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name, capacity,
                               starts_at, ends_at, status, staffing, flex, minimum_bookings) values
  ('48ee0000-0000-0000-0000-00000c010003','48ee0000-0000-0000-0000-000000000001','48ee0000-0000-0000-0000-0000000000a0',
   '48ee0000-0000-0000-0000-0000000cc001','48ee0000-0000-0000-0000-0000000ee001','Free Pending',10,
   now()+interval '6 days', now()+interval '6 days'+interval '50 min','scheduled','open',true,2);
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source, provisional, booked_at) values
  ('48ee0000-0000-0000-0000-00000b010003','48ee0000-0000-0000-0000-000000000001','48ee0000-0000-0000-0000-00000c010003','48ee0000-0000-0000-0000-00000dd00002','booked','comp',true, now()),
  -- a second (paid) seat, so headcount reaches free_first_confirm_at (2).
  ('48ee0000-0000-0000-0000-00000b01003b','48ee0000-0000-0000-0000-000000000001','48ee0000-0000-0000-0000-00000c010003','48ee0000-0000-0000-0000-00000dd00001','booked','drop_in',false, now());
select queue_booking_notifications('48ee0000-0000-0000-0000-00000b010003');
select expect_true('free_booking_pending carries manage_link + book_url',
  (select payload->>'manage_link' like '%/class/%' and payload->>'book_url' like '%/book' from notifications
    where template_key='free_booking_pending' and member_id='48ee0000-0000-0000-0000-00000dd00002'));

-- confirm_provisional_seats_run -> free_booking_confirmed (free_first_confirm_at=1, one head).
select confirm_provisional_seats_run('48ee0000-0000-0000-0000-00000c010003');
select expect_true('free_booking_confirmed carries manage_link + book_url',
  (select payload->>'manage_link' like '%/class/%' and payload->>'book_url' like '%/book' from notifications
    where template_key='free_booking_confirmed' and member_id='48ee0000-0000-0000-0000-00000dd00002'));

-- release_provisional_seats_run -> free_booking_not_confirmed (fresh provisional seat).
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name, capacity,
                               starts_at, ends_at, status, staffing, flex, minimum_bookings) values
  ('48ee0000-0000-0000-0000-00000c010004','48ee0000-0000-0000-0000-000000000001','48ee0000-0000-0000-0000-0000000000a0',
   '48ee0000-0000-0000-0000-0000000cc001','48ee0000-0000-0000-0000-0000000ee001','Free Release',10,
   now()+interval '9 days', now()+interval '9 days'+interval '50 min','scheduled','open',true,5);
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source, provisional, booked_at) values
  ('48ee0000-0000-0000-0000-00000b010004','48ee0000-0000-0000-0000-000000000001','48ee0000-0000-0000-0000-00000c010004','48ee0000-0000-0000-0000-00000dd00001','booked','comp',true, now());
select release_provisional_seats_run('48ee0000-0000-0000-0000-00000c010004');
select expect_true('free_booking_not_confirmed carries manage_link + book_url',
  (select payload->>'manage_link' like '%/class/%' and payload->>'book_url' like '%/book' from notifications
    where template_key='free_booking_not_confirmed' and member_id='48ee0000-0000-0000-0000-00000dd00001'));

-- queue_class_moved -> class_moved.
select queue_class_moved('48ee0000-0000-0000-0000-00000c010001', now()+interval '7 days'-interval '1 day');
select expect_true('class_moved carries manage_link + book_url',
  (select payload->>'manage_link' like '%/class/%' and payload->>'book_url' like '%/book' from notifications
    where template_key='class_moved' and member_id='48ee0000-0000-0000-0000-00000dd00001'));

-- queue_occurrence_cancelled studio_fault -> class_cancelled.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name, capacity,
                               starts_at, ends_at, status, staffing) values
  ('48ee0000-0000-0000-0000-00000c010005','48ee0000-0000-0000-0000-000000000001','48ee0000-0000-0000-0000-0000000000a0',
   '48ee0000-0000-0000-0000-0000000cc001','48ee0000-0000-0000-0000-0000000ee001','Cancel Me',10,
   now()+interval '8 days', now()+interval '8 days'+interval '50 min','scheduled','open');
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source, booked_at) values
  ('48ee0000-0000-0000-0000-00000b010005','48ee0000-0000-0000-0000-000000000001','48ee0000-0000-0000-0000-00000c010005','48ee0000-0000-0000-0000-00000dd00001','booked','drop_in', now());
select queue_occurrence_cancelled('48ee0000-0000-0000-0000-00000c010005', 'studio_fault');
select expect_true('class_cancelled carries manage_link + book_url',
  (select payload->>'manage_link' like '%/class/%' and payload->>'book_url' like '%/book' from notifications
    where template_key='class_cancelled' and member_id='48ee0000-0000-0000-0000-00000dd00001'));

-- =============================================================================
-- 5. FLEX CUT-OFF CANCELS -> INSTRUCTOR TOLD, WITH THE REASON
-- =============================================================================
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity,
                               starts_at, ends_at, status, staffing, flex, minimum_bookings) values
  ('48ee0000-0000-0000-0000-00000c010006','48ee0000-0000-0000-0000-000000000001','48ee0000-0000-0000-0000-0000000000a0',
   '48ee0000-0000-0000-0000-0000000cc001','48ee0000-0000-0000-0000-0000000ee001','48ee0000-0000-0000-0000-0000000d0001','Flex Shortfall',10,
   now()+interval '2 days', now()+interval '2 days'+interval '50 min','scheduled','assigned',true,2);
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source, booked_at) values
  ('48ee0000-0000-0000-0000-00000b010006','48ee0000-0000-0000-0000-000000000001','48ee0000-0000-0000-0000-00000c010006','48ee0000-0000-0000-0000-00000dd00001','booked','drop_in', now());
update class_occurrences set booked_count = 1 where id='48ee0000-0000-0000-0000-00000c010006';
select expect_text('the flex class with one booking does not run',
  (evaluate_commitment('48ee0000-0000-0000-0000-00000c010006'))->>'decision', 'not_running');
select expect_num('task 5: the assigned instructor is told once, via instructor_class_cancelled',
  (select count(*) from notifications where template_key='instructor_class_cancelled'
     and user_id='48ee0000-0000-0000-0000-0000000000d1'
     and payload->>'occurrence_id'='48ee0000-0000-0000-0000-00000c010006'), 1);
select expect_text('task 5: the reason is the cut-off wording',
  (select payload->>'reason' from notifications where template_key='instructor_class_cancelled'
     and payload->>'occurrence_id'='48ee0000-0000-0000-0000-00000c010006' limit 1),
  'didn''t reach its minimum by the cut-off');
select expect_true('the member on the shortfall class got flex_booking_not_confirmed with the keys',
  (select payload->>'manage_link' like '%/class/%' and payload->>'book_url' like '%/book' from notifications
    where template_key='flex_booking_not_confirmed' and member_id='48ee0000-0000-0000-0000-00000dd00001'
      and payload->>'occurrence_id'='48ee0000-0000-0000-0000-00000c010006'));

-- =============================================================================
-- 3. WAITLIST EMAILS CARRY {first_name} + {claim_url}
-- =============================================================================
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name, capacity,
                               starts_at, ends_at, status, staffing) values
  ('48ee0000-0000-0000-0000-00000c010007','48ee0000-0000-0000-0000-000000000001','48ee0000-0000-0000-0000-0000000000a0',
   '48ee0000-0000-0000-0000-0000000cc001','48ee0000-0000-0000-0000-0000000ee001','Waitlist Class',1,
   now()+interval '3 days', now()+interval '3 days'+interval '50 min','scheduled','open');
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source, booked_at) values
  ('48ee0000-0000-0000-0000-00000b010007','48ee0000-0000-0000-0000-000000000001','48ee0000-0000-0000-0000-00000c010007','48ee0000-0000-0000-0000-00000dd00001','waitlisted','drop_in', now());
insert into waitlist_offers (id, studio_id, booking_id, occurrence_id, offered_at, expires_at) values
  ('48ee0000-0000-0000-0000-00000f010001','48ee0000-0000-0000-0000-000000000001','48ee0000-0000-0000-0000-00000b010007','48ee0000-0000-0000-0000-00000c010007', now(), now()+interval '30 min');
select queue_waitlist_offer('48ee0000-0000-0000-0000-00000f010001');
select expect_text('waitlist_offer carries {first_name}',
  (select payload->>'first_name' from notifications where template_key='waitlist_offer'
    and member_id='48ee0000-0000-0000-0000-00000dd00001' limit 1), 'Mia');
select expect_true('waitlist_offer carries {claim_url} (the class page)',
  (select payload->>'claim_url' like '%/class/48ee0000-0000-0000-0000-00000c010007' from notifications
    where template_key='waitlist_offer' and member_id='48ee0000-0000-0000-0000-00000dd00001' limit 1));
select queue_waitlist_missed('48ee0000-0000-0000-0000-00000b010007');
select expect_text('waitlist_missed carries {first_name}',
  (select payload->>'first_name' from notifications where template_key='waitlist_missed'
    and member_id='48ee0000-0000-0000-0000-00000dd00001' limit 1), 'Mia');
select expect_true('waitlist_missed carries {claim_url}',
  (select payload->>'claim_url' like '%/class/%' from notifications where template_key='waitlist_missed'
    and member_id='48ee0000-0000-0000-0000-00000dd00001' limit 1));

-- =============================================================================
-- 6. CLASS-COUNT MILESTONES (10, once; {milestone_name} is words)
-- =============================================================================
-- Ten past occurrences + ten booked bookings for M2, then flip to attended one
-- at a time so the count crosses 10 exactly once.
do $$
declare i int;
begin
  for i in 1..11 loop
    insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name, capacity,
                                   starts_at, ends_at, status, staffing)
    values (('48ee0000-0000-0000-0000-00000ca000' || lpad(i::text,2,'0'))::uuid,
            '48ee0000-0000-0000-0000-000000000001','48ee0000-0000-0000-0000-0000000000a0',
            '48ee0000-0000-0000-0000-0000000cc001','48ee0000-0000-0000-0000-0000000ee001','Past ' || i, 10,
            now()-make_interval(days => i), now()-make_interval(days => i)+interval '50 min','scheduled','open');
    insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source, booked_at)
    values (('48ee0000-0000-0000-0000-00000cb000' || lpad(i::text,2,'0'))::uuid,
            '48ee0000-0000-0000-0000-000000000001',
            ('48ee0000-0000-0000-0000-00000ca000' || lpad(i::text,2,'0'))::uuid,
            '48ee0000-0000-0000-0000-00000dd00002','booked','drop_in', now()-make_interval(days => i));
  end loop;
  -- Flip the first ten to attended, one statement each: the 10th crosses 10.
  for i in 1..10 loop
    update bookings set status='attended'
     where id = ('48ee0000-0000-0000-0000-00000cb000' || lpad(i::text,2,'0'))::uuid;
  end loop;
end $$;
select expect_num('task 6: reaching 10 attended queues exactly one "10 classes" milestone',
  (select count(*) from notifications where template_key='milestone'
     and member_id='48ee0000-0000-0000-0000-00000dd00002' and payload->>'milestone_name'='10 classes'), 1);
select expect_num('task 6: no "50 classes" milestone at ten',
  (select count(*) from notifications where template_key='milestone'
     and member_id='48ee0000-0000-0000-0000-00000dd00002' and payload->>'milestone_name'='50 classes'), 0);
-- An eleventh attended: count goes to 11, no new milestone.
update bookings set status='attended' where id='48ee0000-0000-0000-0000-00000cb00011';
select expect_num('task 6: a second recompute (11 attended) queues no new milestone',
  (select count(*) from notifications where template_key='milestone'
     and member_id='48ee0000-0000-0000-0000-00000dd00002' and payload->>'milestone_name'='10 classes'), 1);
-- {milestone_name} is words ('10 classes'), and the body is the new class-count
-- wording carrying the {studio_name} token (render_email fills it at send time,
-- as every other template's tokens are filled).
select expect_true('task 6: {milestone_name} is words and the body is the class-count wording',
  (select (payload->>'milestone_name')='10 classes'
          and (payload->>'milestone_body') like 'Ten classes at {studio_name}%' from notifications
    where template_key='milestone' and member_id='48ee0000-0000-0000-0000-00000dd00002'
      and payload->>'milestone_name'='10 classes' limit 1));
-- And the full fill works: render the queued milestone and confirm the studio name lands.
select expect_true('task 6: rendering the milestone fills {studio_name}',
  (select html_body like '%House Studio%' from render_notification(
    (select id from notifications where template_key='milestone'
       and member_id='48ee0000-0000-0000-0000-00000dd00002'
       and payload->>'milestone_name'='10 classes' limit 1))));

-- =============================================================================
-- 1. send_template_test ON INSTRUCTOR TEMPLATES -> ok, nothing stripped
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','48ee0000-0000-0000-0000-0000000000a1', false);  -- OWN (owner)
select expect_true('task 1: send_template_test(instructor_assigned) returns ok',
  (send_template_test('48ee0000-0000-0000-0000-000000000001','instructor_assigned'))->>'ok' = 'true');
select expect_true('task 1: send_template_test(booking_cancelled_committed) returns ok',
  (send_template_test('48ee0000-0000-0000-0000-000000000001','booking_cancelled_committed'))->>'ok' = 'true');
reset role;
select set_config('request.jwt.claim.sub', '', false);
-- ok => the row survived (a stripped token would have deleted it and raised).
select expect_num('task 1: the two test sends left their notification rows (nothing stripped)',
  (select count(*) from notifications where template_key in ('instructor_assigned','booking_cancelled_committed')
     and dedupe_key like 'tpl_test:%'), 2);

-- =============================================================================
-- 5/7. TEMPLATE FIXES
-- =============================================================================
select expect_true('task 5: instructor_class_cancelled default body carries {reason}',
  (select text_body like '%{reason}%' and html_body like '%{reason}%' from notification_templates
    where key='instructor_class_cancelled'));
select expect_num('task 7: convert_missed_you default template has no em dash',
  (select position(chr(8212) in coalesce(text_body,'')||coalesce(html_body,'')) from notification_templates
    where key='convert_missed_you'), 0);

select 'housekeeping_test: ALL PASSED' as result;
