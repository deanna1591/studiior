-- Decision 78 amendment (e) — per-email on/off switch. Space 7e78.
-- One predicate (studio_template_enabled) checked in BOTH queue_notification and
-- queue_shift_notice; default nothing disabled; the master switch always wins
-- (the sweep returns before the per-email gate); an already-queued row is untouched.
\set ON_ERROR_STOP on
begin;

create or replace function expect(p_cond boolean, p_label text) returns void
language plpgsql as $$ begin
  if p_cond then raise notice 'PASS: %', p_label;
  else raise exception 'FAIL: %', p_label; end if;
end $$;

insert into auth.users (id) values ('7e780000-0000-0000-0000-0000000000a1');  -- instructor login
insert into profiles (id, email) select id, id::text||'@example.com'
  from auth.users where id::text like '7e78%';

insert into studios (id, name, slug, timezone, currency, country)
values ('7e780000-0000-0000-0000-000000000001', 'Switch Studio', 'switch-7e78', 'Asia/Manila', 'PHP', 'PH'),
       ('7e780000-0000-0000-0000-000000000002', 'All Off 7e78', 'alloff-7e78', 'Asia/Manila', 'PHP', 'PH');
insert into studio_settings (studio_id) values
  ('7e780000-0000-0000-0000-000000000001'),
  ('7e780000-0000-0000-0000-000000000002');

insert into members (id, studio_id, first_name, last_name, email, status)
values ('7e780000-0000-0000-0000-00000000de01', '7e780000-0000-0000-0000-000000000001',
        'Mara', 'Member', 'mara@7e78.example.com', 'active');

-- 1. Default: nothing disabled, every template enabled.
select expect(disabled_templates = '{}'::text[], '1 disabled_templates defaults to empty')
  from studio_settings where studio_id = '7e780000-0000-0000-0000-000000000001';
select expect(studio_template_enabled('7e780000-0000-0000-0000-000000000001', 'booking_confirmed'),
  '1b booking_confirmed enabled by default');

-- Silence two keys: one member (class_cancelled), one instructor (instructor_assigned).
update studio_settings
   set disabled_templates = array['class_cancelled','instructor_assigned']
 where studio_id = '7e780000-0000-0000-0000-000000000001';

-- 2. The predicate: a silenced key is off, a sibling is on.
select expect(not studio_template_enabled('7e780000-0000-0000-0000-000000000001', 'class_cancelled'),
  '2 class_cancelled now disabled');
select expect(studio_template_enabled('7e780000-0000-0000-0000-000000000001', 'class_moved'),
  '2b class_moved still enabled');

-- 3. Member path: a disabled key queues NOTHING.
select expect(queue_notification('7e780000-0000-0000-0000-000000000001',
    '7e780000-0000-0000-0000-00000000de01', 'class_cancelled', '{}'::jsonb, '7e78:mem:off') is null,
  '3 queue_notification returns null for a disabled member key');
select expect((select count(*) from notifications where dedupe_key = '7e78:mem:off') = 0,
  '3b no member row written for the disabled key');

-- 4. Member path: an enabled key queues normally.
select expect(queue_notification('7e780000-0000-0000-0000-000000000001',
    '7e780000-0000-0000-0000-00000000de01', 'class_moved', '{}'::jsonb, '7e78:mem:on') is not null,
  '4 queue_notification returns an id for an enabled member key');
select expect((select count(*) from notifications where dedupe_key = '7e78:mem:on') = 1,
  '4b one member row written for the enabled key');

-- 5. Instructor path: the SAME predicate gates queue_shift_notice.
select expect(queue_shift_notice('7e780000-0000-0000-0000-000000000001',
    '7e780000-0000-0000-0000-0000000000a1', 'instructor_assigned', '{}'::jsonb, '7e78:stf:off') is null,
  '5 queue_shift_notice returns null for a disabled instructor key');
select expect((select count(*) from notifications where dedupe_key = '7e78:stf:off') = 0,
  '5b no instructor row written for the disabled key');
select expect(queue_shift_notice('7e780000-0000-0000-0000-000000000001',
    '7e780000-0000-0000-0000-0000000000a1', 'cover_asked', '{}'::jsonb, '7e78:stf:on') is not null,
  '5c queue_shift_notice returns an id for an enabled instructor key');
select expect((select count(*) from notifications where dedupe_key = '7e78:stf:on') = 1,
  '5d one instructor row written for the enabled key');

-- 6. The master switch wins: all three sequence masters OFF, nothing disabled, yet
--    the sweep queues nothing — it returns before the per-email gate is ever consulted.
select expect((convert_keep_sweep('7e780000-0000-0000-0000-000000000002') ->> 'queued')::int = 0,
  '6 convert_keep_sweep returns 0 when the master switch is off (master wins)');

-- 7. Already-queued rows are untouched: the gate is at queue time, not at send time.
select queue_notification('7e780000-0000-0000-0000-000000000001',
    '7e780000-0000-0000-0000-00000000de01', 'class_reminder', '{}'::jsonb, '7e78:already') ;
update studio_settings
   set disabled_templates = array_append(disabled_templates, 'class_reminder')
 where studio_id = '7e780000-0000-0000-0000-000000000001';
select expect((select count(*) from notifications
               where dedupe_key = '7e78:already' and status = 'scheduled') = 1,
  '7 a row queued before the key was disabled still stands, scheduled');

-- 8. The anon surface is unchanged.
select expect((select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                where ns.nspname = 'public'
                  and has_function_privilege('anon', p.oid, 'execute')
                  and p.proname not like 'expect%') = 13,
  '8 anon surface is exactly THIRTEEN');

rollback;
