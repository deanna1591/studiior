-- =============================================================================
-- Decision 97 — merge members, staff delete, invite trail. UUID space: 9700
--
-- Invite snapshot survives the host's deletion (panel + Journey read it, not the
-- live join); merge moves every table and the preview counts match; a same-class
-- collision keeps the earlier booking and frees the other; free first used on
-- either is used on the kept member; the waiver is the earliest and marketing is
-- on if either; the removed member is scrubbed with merged_into set and NO
-- account_deleted email; every refusal; delete_member scrubs, refuses a staff
-- login, keeps a multi-studio login; self-delete unchanged.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages = notice;

create or replace function expect_num(label text, actual bigint, want bigint) returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_text(label text, actual text, want text) returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if; end $$;
create or replace function expect_true(label text, actual boolean) returns void language plpgsql as $$
begin if coalesce(actual,false) then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  (expected true)', label; end if; end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('97000000-0000-0000-0000-0000000000a0'),  -- SA owner (manager)
  ('97000000-0000-0000-0000-0000000000c1'),  -- R login (sole studio -> removed on merge)
  ('97000000-0000-0000-0000-0000000000c9'),  -- staff-login member
  ('97000000-0000-0000-0000-0000000000cd'),  -- DUAL login (member in SA and SB)
  ('97000000-0000-0000-0000-0000000000b0');  -- SB member login
insert into profiles (id, email) values
  ('97000000-0000-0000-0000-0000000000a0','9700-o@example.com'),
  ('97000000-0000-0000-0000-0000000000c1','9700-r@example.com'),
  ('97000000-0000-0000-0000-0000000000c9','9700-sm@example.com'),
  ('97000000-0000-0000-0000-0000000000cd','9700-dual@example.com'),
  ('97000000-0000-0000-0000-0000000000b0','9700-sb@example.com');

insert into studios (id, name, slug, timezone, currency, status, contact_email) values
  ('97000000-0000-0000-0000-0000000000a1','Merge SA','merge-sa','UTC','CZK','active','desk@example.com'),
  ('97000000-0000-0000-0000-0000000000b1','Merge SB','merge-sb','UTC','CZK','active','desk@example.com');
insert into studio_settings (studio_id, free_first_class_enabled, guest_passes_enabled, messages_enabled,
                             waitlist_enabled, cancellation_cutoff_minutes) values
  ('97000000-0000-0000-0000-0000000000a1', true, true, true, true, 720),
  ('97000000-0000-0000-0000-0000000000b1', false, false, false, true, 720);
insert into locations (id, studio_id, name, is_primary) values
  ('97000000-0000-0000-0000-00000000000a','97000000-0000-0000-0000-0000000000a1','Main',true),
  ('97000000-0000-0000-0000-00000000000b','97000000-0000-0000-0000-0000000000b1','Main',true);
insert into studio_staff (studio_id, user_id, email, role) values
  ('97000000-0000-0000-0000-0000000000a1','97000000-0000-0000-0000-0000000000a0','9700-o@example.com','owner'),
  ('97000000-0000-0000-0000-0000000000a1','97000000-0000-0000-0000-0000000000c9','9700-sm@example.com','front_desk');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('97000000-0000-0000-0000-000000004001','97000000-0000-0000-0000-0000000000a1','97000000-0000-0000-0000-00000000000a','A',2),
  ('97000000-0000-0000-0000-000000004002','97000000-0000-0000-0000-0000000000a1','97000000-0000-0000-0000-00000000000a','B',2);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('97000000-0000-0000-0000-0000000c7001','97000000-0000-0000-0000-0000000000a1','Reformer',50,2);
insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, visibility, status) values
  ('97000000-0000-0000-0000-000000009001','97000000-0000-0000-0000-0000000000a1','5-Pack','class_pack',500000,'CZK',5,'public','active');

-- OF future (cap 2), OP past, OFREE future for the free-first scenario.
insert into class_occurrences (id, studio_id, class_type_id, location_id, room_id, name, starts_at, ends_at, capacity, booked_count, status) values
  ('97000000-0000-0000-0000-0000000c0f00','97000000-0000-0000-0000-0000000000a1','97000000-0000-0000-0000-0000000c7001','97000000-0000-0000-0000-00000000000a','97000000-0000-0000-0000-000000004001','Reformer', now()+interval '2 days', now()+interval '2 days'+interval '50 min',2,2,'scheduled'),
  ('97000000-0000-0000-0000-0000000c0900','97000000-0000-0000-0000-0000000000a1','97000000-0000-0000-0000-0000000c7001','97000000-0000-0000-0000-00000000000a','97000000-0000-0000-0000-000000004002','Reformer', now()-interval '3 days', now()-interval '3 days'+interval '50 min',2,1,'scheduled'),
  ('97000000-0000-0000-0000-0000000cf400','97000000-0000-0000-0000-0000000000a1','97000000-0000-0000-0000-0000000c7001','97000000-0000-0000-0000-00000000000a','97000000-0000-0000-0000-000000004002','Reformer', now()-interval '5 days', now()-interval '5 days'+interval '50 min',2,1,'scheduled');

-- Members: K keep, R remove (login, sole studio), H host, SM staff-login,
-- DUAL (SA+SB same login), SBM (SB), K2/R2 free-first pair.
insert into members (id, studio_id, user_id, first_name, last_name, email, status, marketing_opt_in, waiver_signed_at, joined_on) values
  ('97000000-0000-0000-0000-0000000e0500','97000000-0000-0000-0000-0000000000a1', null, 'Kate','Keep','9700-k@example.com','active', false, now()-interval '10 days', current_date-20),
  ('97000000-0000-0000-0000-0000000e0400','97000000-0000-0000-0000-0000000000a1','97000000-0000-0000-0000-0000000000c1','Rhea','Remove','9700-r@example.com','active', true, now()-interval '40 days', current_date-40),
  ('97000000-0000-0000-0000-0000000e0000','97000000-0000-0000-0000-0000000000a1', null, 'Holly','Host','9700-h@example.com','active', false, null, current_date-30),
  ('97000000-0000-0000-0000-0000000e0560','97000000-0000-0000-0000-0000000000a1','97000000-0000-0000-0000-0000000000c9','Stan','Staff','9700-sm@example.com','active', false, null, current_date-5),
  ('97000000-0000-0000-0000-0000000e0d20','97000000-0000-0000-0000-0000000000a1','97000000-0000-0000-0000-0000000000cd','Dana','Dual','9700-dual@example.com','active', false, null, current_date-5),
  ('97000000-0000-0000-0000-0000000e05b0','97000000-0000-0000-0000-0000000000b1','97000000-0000-0000-0000-0000000000b0','Bob','SB','9700-sb@example.com','active', false, null, current_date-5),
  ('97000000-0000-0000-0000-0000000e0d21','97000000-0000-0000-0000-0000000000b1','97000000-0000-0000-0000-0000000000cd','Dana','DualB','9700-dual@example.com','active', false, null, current_date-5),
  ('97000000-0000-0000-0000-0000000e0520','97000000-0000-0000-0000-0000000000a1', null, 'Kara','Keep2','9700-k2@example.com','active', false, null, current_date-2),
  ('97000000-0000-0000-0000-0000000e0420','97000000-0000-0000-0000-0000000000a1', null, 'Remy','Remove2','9700-r2@example.com','active', false, null, current_date-2);

-- R's data to move: a membership, a payment, credits, a check-in, a past booking,
-- a note, notification prefs, a tag, a message thread, and a guest pass as GUEST
-- (invited by H, with the snapshot). K gets a notification prefs row (dedupe) and
-- books OF too (the collision), booked LATER than R.
insert into member_tags (id, studio_id, name) values ('97000000-0000-0000-0000-00000007a610','97000000-0000-0000-0000-0000000000a1','VIP');
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, credits_remaining, starts_on) values
  ('97000000-0000-0000-0000-000000065040','97000000-0000-0000-0000-0000000000a1','97000000-0000-0000-0000-0000000e0400','97000000-0000-0000-0000-000000009001','active',500000,'CZK',4,current_date),
  ('97000000-0000-0000-0000-000000065050','97000000-0000-0000-0000-0000000000a1','97000000-0000-0000-0000-0000000e0500','97000000-0000-0000-0000-000000009001','active',500000,'CZK',3,current_date);
insert into payments (id, studio_id, member_id, membership_id, amount_cents, currency, status, provider, method, created_at, paid_at) values
  ('97000000-0000-0000-0000-00000009a700','97000000-0000-0000-0000-0000000000a1','97000000-0000-0000-0000-0000000e0400','97000000-0000-0000-0000-000000065040',500000,'CZK','succeeded','manual','cash', now()-interval '1 day', now()-interval '1 day');
insert into credit_ledger (studio_id, member_id, membership_id, delta, reason, balance_after, created_at) values
  ('97000000-0000-0000-0000-0000000000a1','97000000-0000-0000-0000-0000000e0400','97000000-0000-0000-0000-000000065040',5,'purchase',5, now()-interval '1 day'),
  ('97000000-0000-0000-0000-0000000000a1','97000000-0000-0000-0000-0000000e0400','97000000-0000-0000-0000-000000065040',-1,'booking',4, now()-interval '3 days');
-- R booked OF EARLIER, K booked OF LATER (collision: keep the earlier = R's).
insert into bookings (id, studio_id, occurrence_id, member_id, status, booked_at) values
  ('97000000-0000-0000-0000-0000000b5940','97000000-0000-0000-0000-0000000000a1','97000000-0000-0000-0000-0000000c0900','97000000-0000-0000-0000-0000000e0400','attended', now()-interval '3 days'),
  ('97000000-0000-0000-0000-0000000b5f40','97000000-0000-0000-0000-0000000000a1','97000000-0000-0000-0000-0000000c0f00','97000000-0000-0000-0000-0000000e0400','booked', now()-interval '2 hours'),
  ('97000000-0000-0000-0000-0000000b5f50','97000000-0000-0000-0000-0000000000a1','97000000-0000-0000-0000-0000000c0f00','97000000-0000-0000-0000-0000000e0500','booked', now()-interval '1 hour');
insert into check_ins (id, studio_id, booking_id, member_id, occurrence_id, checked_in_at, method) values
  ('97000000-0000-0000-0000-0000000c1040','97000000-0000-0000-0000-0000000000a1','97000000-0000-0000-0000-0000000b5940','97000000-0000-0000-0000-0000000e0400','97000000-0000-0000-0000-0000000c0900', now()-interval '3 days','self');
insert into member_notes (studio_id, member_id, body) values
  ('97000000-0000-0000-0000-0000000000a1','97000000-0000-0000-0000-0000000e0400','Prefers morning classes');
insert into notification_preferences (member_id, studio_id) values
  ('97000000-0000-0000-0000-0000000e0400','97000000-0000-0000-0000-0000000000a1'),
  ('97000000-0000-0000-0000-0000000e0500','97000000-0000-0000-0000-0000000000a1');
insert into member_tag_assignments (member_id, tag_id, studio_id) values
  ('97000000-0000-0000-0000-0000000e0400','97000000-0000-0000-0000-00000007a610','97000000-0000-0000-0000-0000000000a1');
insert into message_threads (id, studio_id, member_id) values
  ('97000000-0000-0000-0000-000000067040','97000000-0000-0000-0000-0000000000a1','97000000-0000-0000-0000-0000000e0400');
insert into thread_messages (thread_id, studio_id, sender_kind, body) values
  ('97000000-0000-0000-0000-000000067040','97000000-0000-0000-0000-0000000000a1','member','Hi there');
-- H invited R as a guest; the snapshot names Holly.
insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email, occurrence_id, status) values
  ('97000000-0000-0000-0000-0000000000a1','97000000-0000-0000-0000-0000000e0000','97000000-0000-0000-0000-0000000e0400','9700-r@example.com','97000000-0000-0000-0000-0000000c0f00','confirmed');

-- K2/R2 free-first: R2 attended a free (comp) class with a host-null pass.
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source, booked_at) values
  ('97000000-0000-0000-0000-000000b5f200','97000000-0000-0000-0000-0000000000a1','97000000-0000-0000-0000-0000000cf400','97000000-0000-0000-0000-0000000e0420','attended','comp', now()-interval '5 days');
insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email, occurrence_id, guest_booking_id, status) values
  ('97000000-0000-0000-0000-0000000000a1', null,'97000000-0000-0000-0000-0000000e0420','9700-r2@example.com','97000000-0000-0000-0000-0000000cf400','97000000-0000-0000-0000-000000b5f200','confirmed');

reset role;

-- =============================================================================
-- A. Invite snapshot: filled at insert, survives the host's deletion.
-- =============================================================================
select expect_text('guest pass carries the host snapshot at insert',
  (select host_name_at_invite from guest_passes where guest_member_id='97000000-0000-0000-0000-0000000e0400' and host_member_id is not null), 'Holly');
select expect_true('invited_at is filled from created_at',
  (select invited_at is not null from guest_passes where guest_member_id='97000000-0000-0000-0000-0000000e0400' and host_member_id is not null));
select expect_true('R Journey: Invited by Holly',
  exists(select 1 from member_activity('97000000-0000-0000-0000-0000000e0400', current_date-60, current_date+1) where kind='invited_by' and title='Invited by Holly'));
select expect_true('H Journey: Invited Rhea to a class',
  exists(select 1 from member_activity('97000000-0000-0000-0000-0000000e0000', current_date-60, current_date+1) where kind='invited_guest' and title like 'Invited Rhea to %'));

set role authenticated; select set_config('request.jwt.claim.sub','97000000-0000-0000-0000-0000000000a0',false);
select delete_member('97000000-0000-0000-0000-0000000e0000');
select set_config('request.jwt.claim.sub','',false); reset role;

select expect_text('host scrubbed to Deleted member (live join source)', (select first_name from members where id='97000000-0000-0000-0000-0000000e0000'), 'Deleted');
select expect_text('the invite snapshot STILL reads Holly after the host is deleted',
  (select host_name_at_invite from guest_passes where guest_member_id='97000000-0000-0000-0000-0000000e0400' and host_member_id is not null), 'Holly');
select expect_true('R Journey still reads Invited by Holly after host deletion',
  exists(select 1 from member_activity('97000000-0000-0000-0000-0000000e0400', current_date-60, current_date+1) where kind='invited_by' and title='Invited by Holly'));

-- =============================================================================
-- B. merge_preview counts match the removed member's rows (manager session).
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','97000000-0000-0000-0000-0000000000a0',false);
select expect_num('preview bookings', (merge_preview('97000000-0000-0000-0000-0000000e0500','97000000-0000-0000-0000-0000000e0400')->'counts'->>'bookings')::bigint, 2);
select expect_num('preview payments', (merge_preview('97000000-0000-0000-0000-0000000e0500','97000000-0000-0000-0000-0000000e0400')->'counts'->>'payments')::bigint, 1);
select expect_num('preview check_ins',(merge_preview('97000000-0000-0000-0000-0000000e0500','97000000-0000-0000-0000-0000000e0400')->'counts'->>'check_ins')::bigint, 1);
select expect_num('preview credits',  (merge_preview('97000000-0000-0000-0000-0000000e0500','97000000-0000-0000-0000-0000000e0400')->'counts'->>'credits')::bigint, 2);
select expect_num('preview messages', (merge_preview('97000000-0000-0000-0000-0000000e0500','97000000-0000-0000-0000-0000000e0400')->'counts'->>'messages')::bigint, 1);
select expect_text('preview keeps the kept email', merge_preview('97000000-0000-0000-0000-0000000e0500','97000000-0000-0000-0000-0000000e0400')->>'keep_email', '9700-k@example.com');
select expect_true('preview flags two active memberships', (merge_preview('97000000-0000-0000-0000-0000000e0500','97000000-0000-0000-0000-0000000e0400')->>'two_active')::boolean);
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- C/D/F/G. Merge K <- R.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','97000000-0000-0000-0000-0000000000a0',false);
select merge_members('97000000-0000-0000-0000-0000000e0500','97000000-0000-0000-0000-0000000e0400');
select set_config('request.jwt.claim.sub','',false); reset role;

select expect_num('R has no bookings',   (select count(*) from bookings where member_id='97000000-0000-0000-0000-0000000e0400'), 0);
select expect_num('R has no payments',   (select count(*) from payments where member_id='97000000-0000-0000-0000-0000000e0400'), 0);
select expect_num('R has no credit rows',(select count(*) from credit_ledger where member_id='97000000-0000-0000-0000-0000000e0400'), 0);
select expect_num('R has no check-ins',  (select count(*) from check_ins where member_id='97000000-0000-0000-0000-0000000e0400'), 0);
select expect_num('R has no memberships',(select count(*) from memberships where member_id='97000000-0000-0000-0000-0000000e0400'), 0);
select expect_num('R has no notes',      (select count(*) from member_notes where member_id='97000000-0000-0000-0000-0000000e0400'), 0);
select expect_num('R guest pass moved',  (select count(*) from guest_passes where guest_member_id='97000000-0000-0000-0000-0000000e0400'), 0);
select expect_num('R tag moved',         (select count(*) from member_tag_assignments where member_id='97000000-0000-0000-0000-0000000e0400'), 0);
select expect_num('R prefs deduped away',(select count(*) from notification_preferences where member_id='97000000-0000-0000-0000-0000000e0400'), 0);
select expect_num('R thread folded away',(select count(*) from message_threads where member_id='97000000-0000-0000-0000-0000000e0400'), 0);
select expect_num('K has payments now',  (select count(*) from payments where member_id='97000000-0000-0000-0000-0000000e0500'), 1);
select expect_num('K has the check-in',  (select count(*) from check_ins where member_id='97000000-0000-0000-0000-0000000e0500'), 1);
select expect_num('K has 2 memberships', (select count(*) from memberships where member_id='97000000-0000-0000-0000-0000000e0500'), 2);
select expect_num('K has the moved note',(select count(*) from member_notes where member_id='97000000-0000-0000-0000-0000000e0500'), 1);
select expect_num('K has one prefs row', (select count(*) from notification_preferences where member_id='97000000-0000-0000-0000-0000000e0500'), 1);
select expect_num('K thread has the folded message', (select count(*) from thread_messages tm join message_threads mt on mt.id=tm.thread_id where mt.member_id='97000000-0000-0000-0000-0000000e0500'), 1);
select expect_num('OF has one LIVE booking for K', (select count(*) from bookings where occurrence_id='97000000-0000-0000-0000-0000000c0f00' and member_id='97000000-0000-0000-0000-0000000e0500' and status in ('booked','waitlisted','attended')), 1);
select expect_text('the surviving OF booking is R''s earlier one', (select id::text from bookings where occurrence_id='97000000-0000-0000-0000-0000000c0f00' and member_id='97000000-0000-0000-0000-0000000e0500' and status='booked'), '97000000-0000-0000-0000-0000000b5f40');
select expect_true('the later booking was cancelled, no penalty', (select status::text='cancelled' and not coalesce(is_late_cancel,false) from bookings where id='97000000-0000-0000-0000-0000000b5f50'));
select expect_true('K waiver is the earliest of the two', (select waiver_signed_at < (now()-interval '10 days') from members where id='97000000-0000-0000-0000-0000000e0500'));
select expect_true('K marketing opt-in on (R was on)', (select marketing_opt_in from members where id='97000000-0000-0000-0000-0000000e0500'));
select expect_text('R scrubbed to Deleted member', (select first_name||' '||last_name from members where id='97000000-0000-0000-0000-0000000e0400'), 'Deleted member');
select expect_true('R deleted_at set', (select deleted_at is not null from members where id='97000000-0000-0000-0000-0000000e0400'));
select expect_text('R merged_into K', (select merged_into::text from members where id='97000000-0000-0000-0000-0000000e0400'), '97000000-0000-0000-0000-0000000e0500');
select expect_true('R merged_at set', (select merged_at is not null from members where id='97000000-0000-0000-0000-0000000e0400'));
select expect_num('merge sends NO account_deleted email', (select count(*) from notifications where template_key='account_deleted' and payload->>'to_email'='9700-r@example.com'), 0);
select expect_num('one member.merged audit row', (select count(*) from audit_logs where action='member.merged' and entity_id='97000000-0000-0000-0000-0000000e0400'), 1);
select expect_true('R login removed (sole studio)', (select not exists(select 1 from auth.users where id='97000000-0000-0000-0000-0000000000c1')));

-- COMPLETENESS: not one row references R across any member FK after the merge
-- (push/calendar tokens are deleted; everything else moved to K).
do $$
declare c record; n bigint; bad text := '';
begin
  for c in
    select rel.relname as t, a.attname as col
      from pg_constraint k
      join pg_class rel on rel.oid=k.conrelid
      join unnest(k.conkey) with ordinality ck(attnum,ord) on true
      join pg_attribute a on a.attrelid=k.conrelid and a.attnum=ck.attnum
     where k.contype='f' and k.confrelid='public.members'::regclass
  loop
    execute format('select count(*) from %I where %I = $1', c.t, c.col)
      into n using '97000000-0000-0000-0000-0000000e0400'::uuid;
    if n > 0 then bad := bad || format(' %s.%s=%s', c.t, c.col, n); end if;
  end loop;
  if bad = '' then raise notice 'PASS  no table references R after the merge (all 38 FK columns clear)';
  else raise exception 'FAIL  rows still reference R:%', bad; end if;
end $$;

-- =============================================================================
-- E. Free first used on either -> used on the kept member.
-- =============================================================================
select expect_true('K2 was free-first eligible before merge',
  (free_first_eligibility_run('97000000-0000-0000-0000-0000000000a1','97000000-0000-0000-0000-0000000e0520')->>'ok')::boolean);
set role authenticated; select set_config('request.jwt.claim.sub','97000000-0000-0000-0000-0000000000a0',false);
select merge_members('97000000-0000-0000-0000-0000000e0520','97000000-0000-0000-0000-0000000e0420');
select set_config('request.jwt.claim.sub','',false); reset role;

select expect_true('K2 no longer free-first eligible after inheriting R2 free class',
  not (free_first_eligibility_run('97000000-0000-0000-0000-0000000000a1','97000000-0000-0000-0000-0000000e0520')->>'ok')::boolean);

-- =============================================================================
-- K. merge refusals (manager session).
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','97000000-0000-0000-0000-0000000000a0',false);
do $$ begin perform merge_members('97000000-0000-0000-0000-0000000e0500','97000000-0000-0000-0000-0000000e0500'); raise exception 'FAIL same';
  exception when sqlstate 'PT409' then raise notice 'PASS  merge same member refused PT409'; end $$;
do $$ begin perform merge_members('97000000-0000-0000-0000-0000000e0500','97000000-0000-0000-0000-0000000e05b0'); raise exception 'FAIL diff studio';
  exception when sqlstate 'PT409' then raise notice 'PASS  merge across studios refused PT409'; end $$;
do $$ begin perform merge_members('97000000-0000-0000-0000-0000000e0560','97000000-0000-0000-0000-0000000e0d20'); raise exception 'FAIL staff';
  exception when sqlstate 'PT409' then raise notice 'PASS  merge with a staff login refused PT409'; end $$;
do $$ begin perform merge_members('97000000-0000-0000-0000-0000000e0500','97000000-0000-0000-0000-0000000e0400'); raise exception 'FAIL deleted';
  exception when sqlstate 'PT409' then raise notice 'PASS  merge an already-deleted member refused PT409'; end $$;
select expect_text('preview reports staff_login reason', merge_preview('97000000-0000-0000-0000-0000000e0560','97000000-0000-0000-0000-0000000e0d20')->>'reason', 'staff_login');
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- L/M. delete_member: refuses a staff login / non-manager, keeps a dual login.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','97000000-0000-0000-0000-0000000000a0',false);
do $$ begin perform delete_member('97000000-0000-0000-0000-0000000e0560'); raise exception 'FAIL staff del';
  exception when sqlstate 'PT409' then raise notice 'PASS  delete_member refuses a staff login PT409'; end $$;
select set_config('request.jwt.claim.sub','',false); reset role;

set role authenticated; select set_config('request.jwt.claim.sub','97000000-0000-0000-0000-0000000000b0',false);
do $$ begin perform delete_member('97000000-0000-0000-0000-0000000e0d20'); raise exception 'FAIL non-mgr';
  exception when sqlstate 'PT403' then raise notice 'PASS  delete_member refuses a non-manager PT403'; end $$;
select set_config('request.jwt.claim.sub','',false); reset role;

set role authenticated; select set_config('request.jwt.claim.sub','97000000-0000-0000-0000-0000000000a0',false);
select delete_member('97000000-0000-0000-0000-0000000e0d20');
select set_config('request.jwt.claim.sub','',false); reset role;

select expect_text('DUAL SA row scrubbed', (select first_name from members where id='97000000-0000-0000-0000-0000000e0d20'), 'Deleted');
select expect_true('DUAL login kept (still a member in SB)', (select exists(select 1 from auth.users where id='97000000-0000-0000-0000-0000000000cd')));
select expect_true('DUAL account_deleted email sent', exists(select 1 from notifications where template_key='account_deleted' and payload->>'to_email'='9700-dual@example.com'));
set role authenticated; select set_config('request.jwt.claim.sub','97000000-0000-0000-0000-0000000000a0',false);
do $$ begin perform delete_member('97000000-0000-0000-0000-0000000e0d20'); raise exception 'FAIL redelete';
  exception when sqlstate 'PT409' then raise notice 'PASS  delete_member refuses an already-deleted member PT409'; end $$;
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- N. Self-delete unchanged: scrubs + removes the sole-studio login.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','97000000-0000-0000-0000-0000000000b0',false);
select delete_my_account();
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_text('self-delete scrubs the member', (select first_name from members where id='97000000-0000-0000-0000-0000000e05b0'), 'Deleted');
select expect_true('self-delete removes the login', (select not exists(select 1 from auth.users where id='97000000-0000-0000-0000-0000000000b0')));

-- =============================================================================
-- Anon surface unchanged.
-- =============================================================================
select expect_true('merge_members is NOT anon', not has_function_privilege('anon','merge_members(uuid, uuid)','execute'));
select expect_true('delete_member is NOT anon', not has_function_privilege('anon','delete_member(uuid)','execute'));
select expect_true('delete_member_run is service-only', not has_function_privilege('authenticated','delete_member_run(uuid, boolean, uuid)','execute'));

select 'merge_delete_test PASS' as result;
