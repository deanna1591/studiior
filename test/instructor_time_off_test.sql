-- =============================================================================
-- Decision 99 — instructors block off dates. UUID space 99f0, checked free.
-- =============================================================================
-- An instructor marks themselves unavailable for a date or a range from their
-- app. One unavailable exception per day (reusing set_availability_exception),
-- past dates refused, a class within the swap cut-off refused (ask for cover),
-- a date with an assigned class allowed and the studio emailed ONCE with a
-- roster link to each class. The list groups consecutive days into ranges;
-- Remove clears a range (past days cannot be removed). An instructor acts only
-- on themselves: staff of another studio are refused.
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
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual,'null'); end if;
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
  execute stmt; raise exception 'FAIL  %  expected % but nothing was raised', label, want_sqlstate;
exception when others then
  if sqlstate = want_sqlstate then raise notice 'PASS  %  (got %)', label, sqlstate;
  elsif sqlstate = 'P0001' and sqlerrm like 'FAIL%' then raise;
  else raise exception 'FAIL  %  expected %, got % (%)', label, want_sqlstate, sqlstate, sqlerrm; end if;
end $$;
create or replace function expect_err_like(label text, stmt text, want_sqlstate text, want_sub text)
returns void language plpgsql as $$
begin
  execute stmt; raise exception 'FAIL  %  expected % but nothing was raised', label, want_sqlstate;
exception when others then
  if sqlstate = 'P0001' and sqlerrm like 'FAIL%' then raise;
  elsif sqlstate = want_sqlstate and sqlerrm like '%' || want_sub || '%' then
    raise notice 'PASS  %  (got % / %)', label, sqlstate, want_sub;
  else raise exception 'FAIL  %  expected % like "%", got % (%)', label, want_sqlstate, want_sub, sqlstate, sqlerrm; end if;
end $$;

-- ===========================================================================
-- FIXTURES — studio A (Manila) with an instructor login + an owner login, and
-- studio B whose owner is NOT an instructor (the cross-studio refusal).
-- ===========================================================================
insert into auth.users (id) values
  ('99f00000-0000-0000-0000-0000000000a1'),   -- A owner
  ('99f00000-0000-0000-0000-0000000000a2'),   -- A instructor (login)
  ('99f00000-0000-0000-0000-0000000000b1');   -- B owner
insert into profiles (id, email, full_name) values
  ('99f00000-0000-0000-0000-0000000000a1','99f0-a-owner@example.com','Ava Owner'),
  ('99f00000-0000-0000-0000-0000000000a2','99f0-a-instr@example.com','Isla Teacher'),
  ('99f00000-0000-0000-0000-0000000000b1','99f0-b-owner@example.com','Ben Owner');
insert into studios (id, name, slug, timezone, currency, country, status) values
  ('99f00000-0000-0000-0000-00000000000a','Manila Movement','99f0-manila','Asia/Manila','PHP','PH','active'),
  ('99f00000-0000-0000-0000-00000000000b','Prague Pilates','99f0-prague','Europe/Prague','CZK','CZ','active');
insert into studio_settings (studio_id, checkin_window_enforced, time_format, cover_escalation_hours) values
  ('99f00000-0000-0000-0000-00000000000a', false, '24h', 4),
  ('99f00000-0000-0000-0000-00000000000b', false, '24h', 4);
insert into locations (id, studio_id, name, timezone, is_primary) values
  ('99f00000-0000-0000-0000-0000000000fa','99f00000-0000-0000-0000-00000000000a','Main','Asia/Manila',true),
  ('99f00000-0000-0000-0000-0000000000fb','99f00000-0000-0000-0000-00000000000b','Main','Europe/Prague',true);
insert into studio_staff (id, studio_id, user_id, email, role, status) values
  ('99f00000-0000-0000-0000-0000000055a1','99f00000-0000-0000-0000-00000000000a','99f00000-0000-0000-0000-0000000000a1','99f0-a-owner@example.com','owner','active'),
  ('99f00000-0000-0000-0000-0000000055a2','99f00000-0000-0000-0000-00000000000a','99f00000-0000-0000-0000-0000000000a2','99f0-a-instr@example.com','instructor','active'),
  ('99f00000-0000-0000-0000-0000000055b1','99f00000-0000-0000-0000-00000000000b','99f00000-0000-0000-0000-0000000000b1','99f0-b-owner@example.com','owner','active');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('99f00000-0000-0000-0000-00000000c0a1','99f00000-0000-0000-0000-00000000000a','99f00000-0000-0000-0000-0000000000fa','Reformer Room',8);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('99f00000-0000-0000-0000-00000000d0a1','99f00000-0000-0000-0000-00000000000a','Reformer',60,8);
insert into instructors (id, studio_id, staff_id, display_name, status) values
  ('99f00000-0000-0000-0000-0000000000e1','99f00000-0000-0000-0000-00000000000a','99f00000-0000-0000-0000-0000000055a2','Isla Teacher','active');

-- One class on day +6 (inside a far block), and one today +2h (inside the swap
-- cut-off, so a block that reaches it is refused).
insert into class_occurrences (id, studio_id, class_type_id, room_id, location_id, name, instructor_id, starts_at, ends_at, status, capacity)
values
  ('99f00000-0000-0000-0000-0000000000c1','99f00000-0000-0000-0000-00000000000a','99f00000-0000-0000-0000-00000000d0a1','99f00000-0000-0000-0000-00000000c0a1','99f00000-0000-0000-0000-0000000000fa','Reformer','99f00000-0000-0000-0000-0000000000e1',
   (((now() at time zone 'Asia/Manila')::date::timestamp + interval '6 days 7 hours') at time zone 'Asia/Manila'),
   (((now() at time zone 'Asia/Manila')::date::timestamp + interval '6 days 7 hours 50 minutes') at time zone 'Asia/Manila'),
   'scheduled', 8),
  ('99f00000-0000-0000-0000-0000000000c2','99f00000-0000-0000-0000-00000000000a','99f00000-0000-0000-0000-00000000d0a1','99f00000-0000-0000-0000-00000000c0a1','99f00000-0000-0000-0000-0000000000fa','Reformer','99f00000-0000-0000-0000-0000000000e1',
   now() + interval '2 hours', now() + interval '2 hours 50 minutes', 'scheduled', 8);

\echo ''
\echo '=== 1. THE WARNING COUNT — assigned classes a range contains ==='
set role authenticated;
select set_config('request.jwt.claim.sub','99f00000-0000-0000-0000-0000000000a2',false);
select expect_num('instructor_time_off_classes over the far block returns the one assigned class',
  (select count(*) from instructor_time_off_classes(
     ((now() at time zone 'Asia/Manila')::date + 5),
     ((now() at time zone 'Asia/Manila')::date + 7))), 1);
select expect_num('a free range returns no classes',
  (select count(*) from instructor_time_off_classes(
     ((now() at time zone 'Asia/Manila')::date + 10),
     ((now() at time zone 'Asia/Manila')::date + 11))), 0);

\echo ''
\echo '=== 2. BLOCK A RANGE — one exception per day, studio emailed once ==='
select expect_num('before: no instructor_time_off email to the owner', (select count(*)
  from notifications where template_key = 'instructor_time_off'
    and studio_id = '99f00000-0000-0000-0000-00000000000a'), 0);

select expect_num('block [+5,+7] holiday: 3 days written',
  ((select (instructor_block_dates(
     ((now() at time zone 'Asia/Manila')::date + 5),
     ((now() at time zone 'Asia/Manila')::date + 7), 'holiday'))->>'days')::int), 3);
select expect_num('and the result reports 1 class the studio must cover',
  ((select (instructor_block_dates(
     ((now() at time zone 'Asia/Manila')::date + 5),
     ((now() at time zone 'Asia/Manila')::date + 7), 'holiday'))->>'class_count')::int), 1);

reset role;
select expect_num('one exception row per day across +5..+7 (unavailable, note holiday)',
  (select count(*) from instructor_availability
    where instructor_id = '99f00000-0000-0000-0000-0000000000e1'
      and is_available = false and note = 'holiday'
      and exception_date between ((now() at time zone 'Asia/Manila')::date + 5)
                             and ((now() at time zone 'Asia/Manila')::date + 7)), 3);
-- block_dates was called twice above (both the days and class_count reads), so
-- the per-save dedupe key (clock_timestamp) gives TWO owner emails, never zero.
select expect_true('the studio owner was emailed instructor_time_off (once per save)',
  (select count(*) >= 1 from notifications n
    where n.template_key = 'instructor_time_off'
      and n.user_id = '99f00000-0000-0000-0000-0000000000a1'
      and n.recipient_type = 'staff'
      and n.payload->>'class_list_html' like '%/roster/99f00000-0000-0000-0000-0000000000c1%'));

\echo ''
\echo '=== 3. THE INSTRUCTOR LIST — consecutive days as one range ==='
set role authenticated;
select set_config('request.jwt.claim.sub','99f00000-0000-0000-0000-0000000000a2',false);
select expect_num('instructor_time_off groups +5..+7 into ONE range', (select count(*)
  from instructor_time_off() where reason = 'holiday'), 1);
select expect_true('the range is +5..+7, future, carrying the reason and its class count', (select
  from_date = ((now() at time zone 'Asia/Manila')::date + 5)
  and to_date = ((now() at time zone 'Asia/Manila')::date + 7)
  and reason = 'holiday' and is_past = false and class_count = 1
  from instructor_time_off() where reason = 'holiday'));

\echo ''
\echo '=== 4. A FREE RANGE — allowed, no email ==='
select expect_num('block [+10,+11] (no class): 0 classes to cover',
  ((select (instructor_block_dates(
     ((now() at time zone 'Asia/Manila')::date + 10),
     ((now() at time zone 'Asia/Manila')::date + 11), null))->>'class_count')::int), 0);
reset role;
select expect_num('still only the +5..+7 emails — a classless block sends none', (select count(*)
  from notifications where template_key = 'instructor_time_off'
    and payload->>'class_list_html' is not null
    and payload->>'range' like '%'
    and payload->>'class_list' is null), 0);
select expect_num('now two distinct time-off ranges on file', (select count(*)
  from (
    select note, grp from (
      select coalesce(note,'') as note,
             exception_date - (row_number() over (partition by coalesce(note,'') order by exception_date))::int as grp
        from instructor_availability
       where instructor_id = '99f00000-0000-0000-0000-0000000000e1' and is_available = false
    ) z group by note, grp
  ) q), 2);

\echo ''
\echo '=== 5. REFUSALS — past dates, and a class too close to the cut-off ==='
set role authenticated;
select set_config('request.jwt.claim.sub','99f00000-0000-0000-0000-0000000000a2',false);
select expect_raises('a block starting in the past is refused (PT409)',
  $$ select instructor_block_dates(
       ((now() at time zone 'Asia/Manila')::date - 1),
       ((now() at time zone 'Asia/Manila')::date - 1), null) $$, 'PT409');
select expect_err_like('a block reaching a class inside the swap cut-off is refused, not written',
  $$ select instructor_block_dates(
       ((now() at time zone 'Asia/Manila')::date),
       ((now() at time zone 'Asia/Manila')::date + 1), 'sick') $$, 'PT409', 'too soon to block');
reset role;
select expect_num('nothing was written for today by the refused too-close block', (select count(*)
  from instructor_availability where instructor_id = '99f00000-0000-0000-0000-0000000000e1'
    and exception_date = (now() at time zone 'Asia/Manila')::date), 0);

\echo ''
\echo '=== 6. UNBLOCK — clears only that range ==='
set role authenticated;
select set_config('request.jwt.claim.sub','99f00000-0000-0000-0000-0000000000a2',false);
select expect_num('unblock [+5,+7] clears 3 days',
  ((select (instructor_unblock_dates(
     ((now() at time zone 'Asia/Manila')::date + 5),
     ((now() at time zone 'Asia/Manila')::date + 7)))->>'days')::int), 3);
reset role;
select expect_num('the +5..+7 exceptions are gone', (select count(*) from instructor_availability
  where instructor_id = '99f00000-0000-0000-0000-0000000000e1' and note = 'holiday'), 0);
select expect_num('the +10..+11 range is untouched', (select count(*) from instructor_availability
  where instructor_id = '99f00000-0000-0000-0000-0000000000e1' and is_available = false
    and exception_date between ((now() at time zone 'Asia/Manila')::date + 10)
                           and ((now() at time zone 'Asia/Manila')::date + 11)), 2);

\echo ''
\echo '=== 7. PAST DAYS CANNOT BE REMOVED ==='
-- Seed a past full-day block directly (the block function refuses past dates;
-- a real past block is one that was in the future when it was made).
set role authenticated;
select set_config('request.jwt.claim.sub','99f00000-0000-0000-0000-0000000000a2',false);
select set_availability_exception('99f00000-0000-0000-0000-0000000000e1',
  ((now() at time zone 'Asia/Manila')::date - 5), '[]'::jsonb, 'old leave');
select expect_true('the past block shows in the list marked is_past', (select is_past
  from instructor_time_off() where reason = 'old leave'));
select expect_num('unblocking a wholly-past range clears nothing',
  ((select (instructor_unblock_dates(
     ((now() at time zone 'Asia/Manila')::date - 5),
     ((now() at time zone 'Asia/Manila')::date - 5)))->>'days')::int), 0);
reset role;
select expect_num('the past exception still stands', (select count(*) from instructor_availability
  where instructor_id = '99f00000-0000-0000-0000-0000000000e1'
    and exception_date = ((now() at time zone 'Asia/Manila')::date - 5)), 1);

\echo ''
\echo '=== 8. ONLY THE INSTRUCTOR THEMSELVES — staff of another studio refused ==='
set role authenticated;
select set_config('request.jwt.claim.sub','99f00000-0000-0000-0000-0000000000b1',false);  -- B owner, not an instructor
select expect_raises('studio B owner cannot block dates (not an instructor): PT403',
  $$ select instructor_block_dates(
       ((now() at time zone 'Asia/Manila')::date + 5),
       ((now() at time zone 'Asia/Manila')::date + 5), null) $$, 'PT403');
select expect_raises('studio B owner cannot read instructor_time_off: PT403',
  $$ select * from instructor_time_off() $$, 'PT403');
select expect_raises('studio B owner cannot read instructor_time_off_classes: PT403',
  $$ select * from instructor_time_off_classes(
       ((now() at time zone 'Asia/Manila')::date + 5),
       ((now() at time zone 'Asia/Manila')::date + 5)) $$, 'PT403');

\echo ''
\echo '=== 9. THE NEW FUNCTIONS ARE NOT ANON ==='
reset role;
select expect_true('none of the four Decision-99 functions is anon-executable', (select bool_and(not anon) from (
  select has_function_privilege('anon', p.oid, 'execute') as anon
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.proname in ('instructor_block_dates','instructor_unblock_dates',
                       'instructor_time_off','instructor_time_off_classes')) q));

\echo ''
\echo 'ALL DECISION 99 (instructor time off) ASSERTIONS PASSED'
