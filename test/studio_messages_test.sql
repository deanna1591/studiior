-- =============================================================================
-- Studio messages — Decision 89, migrations 20260833100000 + 20260833110000
-- =============================================================================
-- UUID space de89, checked free. Run after `supabase db reset`.
--
-- Members message the studio; any non-instructor staff role replies; one thread
-- per member per studio; nothing crosses studios. Off by default. Every write
-- goes through a SECURITY DEFINER RPC (no client INSERT grant); size and type are
-- enforced in the RPC, refusals returned as reasons. message_to_studio is queued
-- once per member message and rides the per-email switch.
--
-- RED proof: on the pre-89 schema `member_send_message`/`thread_messages` do not
-- exist, so every case below errors (function/relation does not exist).
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'BAD  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_eq(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'BAD  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin if actual then raise notice 'PASS  %', label; else raise exception 'BAD  %  expected true', label; end if; end $$;
-- run a jsonb-returning expression as a given user, trap errors to {err,msg}
create or replace function as_json(uid text, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claim.sub', uid, true); set local role authenticated;
  begin execute sql into r; return r;
  exception when others then return jsonb_build_object('err', sqlstate, 'msg', sqlerrm); end;
end $$;
-- count rows as a given user (RLS applies), trap errors to -1
create or replace function as_count(uid text, sql text) returns bigint language plpgsql as $$
declare n bigint;
begin
  perform set_config('request.jwt.claim.sub', uid, true); set local role authenticated;
  begin execute sql into n; return n; exception when others then return -1; end;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('de890000-0000-0000-0000-0000000000a1'),  -- SA owner
  ('de890000-0000-0000-0000-0000000000f1'),  -- SA front desk
  ('de890000-0000-0000-0000-0000000000e1'),  -- SA instructor
  ('de890000-0000-0000-0000-0000000000c1'),  -- SA member MA1
  ('de890000-0000-0000-0000-0000000000c2'),  -- SA member MA2
  ('de890000-0000-0000-0000-0000000000b1'),  -- SB owner
  ('de890000-0000-0000-0000-0000000000d1');  -- SB member MB1
insert into profiles (id, email, full_name) values
  ('de890000-0000-0000-0000-0000000000a1','de89-oa@example.com','Olive Ayer'),
  ('de890000-0000-0000-0000-0000000000f1','de89-fa@example.com','Fran Deskman'),
  ('de890000-0000-0000-0000-0000000000e1','de89-ia@example.com','Ivy Teacher'),
  ('de890000-0000-0000-0000-0000000000c1','de89-m1@example.com','Member One'),
  ('de890000-0000-0000-0000-0000000000c2','de89-m2@example.com','Member Two'),
  ('de890000-0000-0000-0000-0000000000b1','de89-ob@example.com','Owen Bee'),
  ('de890000-0000-0000-0000-0000000000d1','de89-n1@example.com','Member Enn');

insert into studios (id, name, slug, timezone, currency, status, contact_email) values
  ('de890000-0000-0000-0000-0000000000a0','Alpha Studio','de89-sa','UTC','PHP','active','desk@alpha.example'),
  ('de890000-0000-0000-0000-0000000000b0','Bravo Studio','de89-sb','UTC','PHP','active','desk@bravo.example');
insert into studio_settings (studio_id, messages_enabled) values
  ('de890000-0000-0000-0000-0000000000a0', true),    -- SA: messages ON
  ('de890000-0000-0000-0000-0000000000b0', false);   -- SB: messages OFF

insert into studio_staff (id, studio_id, user_id, email, role) values
  ('de890000-0000-0000-0000-00000000aa01','de890000-0000-0000-0000-0000000000a0','de890000-0000-0000-0000-0000000000a1','de89-oa@example.com','owner'),
  ('de890000-0000-0000-0000-00000000ff01','de890000-0000-0000-0000-0000000000a0','de890000-0000-0000-0000-0000000000f1','de89-fa@example.com','front_desk'),
  ('de890000-0000-0000-0000-00000000ee01','de890000-0000-0000-0000-0000000000a0','de890000-0000-0000-0000-0000000000e1','de89-ia@example.com','instructor'),
  ('de890000-0000-0000-0000-00000000bb01','de890000-0000-0000-0000-0000000000b0','de890000-0000-0000-0000-0000000000b1','de89-ob@example.com','owner');

insert into members (id, studio_id, user_id, first_name, last_name, email) values
  ('de890000-0000-0000-0000-00000000c001','de890000-0000-0000-0000-0000000000a0','de890000-0000-0000-0000-0000000000c1','Member','One','de89-m1@example.com'),
  ('de890000-0000-0000-0000-00000000c002','de890000-0000-0000-0000-0000000000a0','de890000-0000-0000-0000-0000000000c2','Member','Two','de89-m2@example.com'),
  ('de890000-0000-0000-0000-00000000d001','de890000-0000-0000-0000-0000000000b0','de890000-0000-0000-0000-0000000000d1','Member','Enn','de89-n1@example.com');

\echo '--- 1. a member sends; the thread and message exist, the studio is told once ---'
select expect_true('MA1 send ok',
  (as_json('de890000-0000-0000-0000-0000000000c1',
    $$ select member_send_message('de890000-0000-0000-0000-0000000000a0','Hello, can I switch my class?') $$)->>'ok')::boolean);
select expect_num('one message_to_studio queued', (select count(*) from notifications
  where template_key='message_to_studio' and studio_id='de890000-0000-0000-0000-0000000000a0'), 1);
-- Capture MA1's thread id in a session temp table (an instructor cannot resolve
-- it under RLS, and a null id would hit PT404 — "no such thread" — masking the
-- PT403 guard; a temp table is visible to every role in the session).
reset role;
select id as sa_thread from message_threads where member_id='de890000-0000-0000-0000-00000000c001' \gset
select expect_eq('the notice goes to the SA owner', (select user_id::text from notifications
  where template_key='message_to_studio' and studio_id='de890000-0000-0000-0000-0000000000a0' limit 1),
  'de890000-0000-0000-0000-0000000000a1');
select expect_true('member_messages returns MA1 own thread with 1 message',
  (as_json('de890000-0000-0000-0000-0000000000c1',
    $$ select member_messages('de890000-0000-0000-0000-0000000000a0') $$) -> 'messages') is not null
  and jsonb_array_length(as_json('de890000-0000-0000-0000-0000000000c1',
    $$ select member_messages('de890000-0000-0000-0000-0000000000a0') $$) -> 'messages') = 1);

\echo '--- 2. a second member message queues a second studio notice (once per message) ---'
select expect_true('MA1 second send ok',
  (as_json('de890000-0000-0000-0000-0000000000c1',
    $$ select member_send_message('de890000-0000-0000-0000-0000000000a0','One more thing') $$)->>'ok')::boolean);
select expect_num('two message_to_studio queued', (select count(*) from notifications
  where template_key='message_to_studio' and studio_id='de890000-0000-0000-0000-0000000000a0'), 2);

\echo '--- 3. a different member cannot see MA1 thread; their own thread is empty ---'
-- MA2 opening messages creates their own (empty) thread, never MA1's.
select expect_num('MA2 own thread empty',
  jsonb_array_length(as_json('de890000-0000-0000-0000-0000000000c2',
    $$ select member_messages('de890000-0000-0000-0000-0000000000a0') $$) -> 'messages'), 0);
-- direct RLS: MA2 cannot read any of MA1's messages.
select expect_num('MA2 sees 0 of MA1 messages via RLS',
  as_count('de890000-0000-0000-0000-0000000000c2',
    $$ select count(*) from thread_messages tm join message_threads t on t.id=tm.thread_id
         where t.member_id='de890000-0000-0000-0000-00000000c001' $$), 0);

\echo '--- 4. staff of another studio cannot read; an instructor cannot either ---'
select expect_eq('SB owner staff_message_threads(SA) → PT403',
  as_json('de890000-0000-0000-0000-0000000000b1',
    $$ select staff_message_threads('de890000-0000-0000-0000-0000000000a0') $$)->>'err', 'PT403');
select expect_eq('SA instructor staff_message_threads → PT403',
  as_json('de890000-0000-0000-0000-0000000000e1',
    $$ select staff_message_threads('de890000-0000-0000-0000-0000000000a0') $$)->>'err', 'PT403');

\echo '--- 5. SA front desk sees the one thread with a message, unread, and can open it ---'
select expect_num('front desk sees 1 thread',
  jsonb_array_length(as_json('de890000-0000-0000-0000-0000000000f1',
    $$ select staff_message_threads('de890000-0000-0000-0000-0000000000a0') $$)), 1);
select expect_true('that thread is unread',
  (as_json('de890000-0000-0000-0000-0000000000f1',
    $$ select staff_message_threads('de890000-0000-0000-0000-0000000000a0') $$) -> 0 ->> 'unread')::boolean);
-- the instructor's thread list / a cross-studio open are both refused
select expect_eq('SA instructor staff_message_thread → PT403',
  as_json('de890000-0000-0000-0000-0000000000e1',
    format('select staff_message_thread(%L)', :'sa_thread'))->>'err', 'PT403');

\echo '--- 6. a front-desk reply: ok, queues message_to_member once, lands on MA1 thread ---'
select expect_true('FA reply ok',
  (as_json('de890000-0000-0000-0000-0000000000f1',
    format('select staff_send_message(%L, %L)', :'sa_thread', 'Of course, which day suits?'))->>'ok')::boolean);
select expect_num('one message_to_member queued', (select count(*) from notifications
  where template_key='message_to_member' and studio_id='de890000-0000-0000-0000-0000000000a0'), 1);
select expect_eq('message_to_member goes to MA1', (select member_id::text from notifications
  where template_key='message_to_member' and studio_id='de890000-0000-0000-0000-0000000000a0' limit 1),
  'de890000-0000-0000-0000-00000000c001');
select expect_num('MA1 now sees 3 messages (2 sent + 1 reply)',
  jsonb_array_length(as_json('de890000-0000-0000-0000-0000000000c1',
    $$ select member_messages('de890000-0000-0000-0000-0000000000a0') $$) -> 'messages'), 3);

\echo '--- 7. an instructor cannot reply ---'
select expect_eq('SA instructor staff_send_message → PT403',
  as_json('de890000-0000-0000-0000-0000000000e1',
    format('select staff_send_message(%L, %L)', :'sa_thread', 'no'))->>'err', 'PT403');

\echo '--- 8. opening a thread marks it read ---'
select as_json('de890000-0000-0000-0000-0000000000f1',
  format('select staff_mark_thread_read(%L)', :'sa_thread'));
-- after staff send + mark read, the member message is older than last_staff_read_at → not unread.
select expect_true('thread no longer unread after mark read',
  not (as_json('de890000-0000-0000-0000-0000000000f1',
    $$ select staff_message_threads('de890000-0000-0000-0000-0000000000a0') $$) -> 0 ->> 'unread')::boolean);

\echo '--- 9. disabled studio refuses, as a reason, both read and send ---'
select expect_eq('SB member send refused (off)',
  as_json('de890000-0000-0000-0000-0000000000d1',
    $$ select member_send_message('de890000-0000-0000-0000-0000000000b0','hi?') $$)->>'reason',
  'Messages are off for this studio');
select expect_eq('SB member_messages refused (off)',
  as_json('de890000-0000-0000-0000-0000000000d1',
    $$ select member_messages('de890000-0000-0000-0000-0000000000b0') $$)->>'reason',
  'Messages are off for this studio');
select expect_num('nothing queued for SB', (select count(*) from notifications
  where studio_id='de890000-0000-0000-0000-0000000000b0'), 0);

\echo '--- 10. a non-member is refused the studio outright (PT403) ---'
select expect_eq('MB1 (not an SA member) member_messages(SA) → PT403',
  as_json('de890000-0000-0000-0000-0000000000d1',
    $$ select member_messages('de890000-0000-0000-0000-0000000000a0') $$)->>'err', 'PT403');

\echo '--- 11. validation: length, size, type (each a reason, nothing written) ---'
select expect_eq('2001 chars refused',
  as_json('de890000-0000-0000-0000-0000000000c1',
    $$ select member_send_message('de890000-0000-0000-0000-0000000000a0', repeat('x',2001)) $$)->>'reason',
  'Keep your message to 2000 characters or fewer.');
select expect_eq('over 1 MB refused',
  as_json('de890000-0000-0000-0000-0000000000c1',
    $$ select member_send_message('de890000-0000-0000-0000-0000000000a0','see this',
         'de890000-0000-0000-0000-0000000000a0/t/f.jpg','f.jpg',1048577,'image/jpeg') $$)->>'reason',
  'That file is over 1 MB. Try a smaller photo or PDF.');
select expect_eq('wrong type refused',
  as_json('de890000-0000-0000-0000-0000000000c1',
    $$ select member_send_message('de890000-0000-0000-0000-0000000000a0','see this',
         'de890000-0000-0000-0000-0000000000a0/t/f.txt','f.txt',100,'text/plain') $$)->>'reason',
  'Photos and PDFs only.');
-- 2000 chars is accepted (the boundary); an image/webp attachment at the cap is accepted.
select expect_true('2000 chars accepted',
  (as_json('de890000-0000-0000-0000-0000000000c1',
    $$ select member_send_message('de890000-0000-0000-0000-0000000000a0', repeat('y',2000)) $$)->>'ok')::boolean);
select expect_true('webp at exactly 1 MB accepted',
  (as_json('de890000-0000-0000-0000-0000000000c1',
    $$ select member_send_message('de890000-0000-0000-0000-0000000000a0','photo',
         'de890000-0000-0000-0000-0000000000a0/t/p.webp','p.webp',1048576,'image/webp') $$)->>'ok')::boolean);

\echo '--- 12. the per-email switch suppresses message_to_studio ---'
reset role;
select count(*) as pre_cnt from notifications
  where template_key='message_to_studio' and studio_id='de890000-0000-0000-0000-0000000000a0' \gset
update studio_settings
  set disabled_templates = array['message_to_studio']
  where studio_id='de890000-0000-0000-0000-0000000000a0';
-- a fresh member message still sends, but queues NO new studio notice.
select expect_true('send still ok with the studio notice switched off',
  (as_json('de890000-0000-0000-0000-0000000000c1',
    $$ select member_send_message('de890000-0000-0000-0000-0000000000a0','quiet one') $$)->>'ok')::boolean);
select expect_num('switch suppressed the new studio notice (count unchanged)',
  (select count(*) from notifications
   where template_key='message_to_studio' and studio_id='de890000-0000-0000-0000-0000000000a0'), :pre_cnt);
update studio_settings set disabled_templates = '{}' where studio_id='de890000-0000-0000-0000-0000000000a0';

\echo '--- 12b. the member header unread dot (member_bootstrap.has_unread_studio_message) ---'
reset role;
select id as thr from message_threads where member_id='de890000-0000-0000-0000-00000000c001' limit 1 \gset
-- Deterministic clock: read-mark 1h ago, a staff message 1m ago (newer) → the dot
-- lights; move the read-mark to now() (newer than the message) → it clears. No
-- reliance on statement-to-statement wall-clock ordering.
update message_threads set last_member_read_at = now() - interval '1 hour' where id = :'thr'::uuid;
insert into thread_messages (thread_id, studio_id, sender_kind, sender_user_id, body, created_at)
  values (:'thr'::uuid, 'de890000-0000-0000-0000-0000000000a0', 'staff',
          'de890000-0000-0000-0000-0000000000f1', 'any news?', now() - interval '1 minute');
select expect_true('bootstrap shows the unread dot for a newer staff message',
  (as_json('de890000-0000-0000-0000-0000000000c1',
    $$ select to_jsonb(b) from member_bootstrap('de89-sa') b $$)->>'has_unread_studio_message')::boolean);
reset role;
update message_threads set last_member_read_at = now() where id = :'thr'::uuid;
select expect_true('the dot clears once the member has read',
  not (as_json('de890000-0000-0000-0000-0000000000c1',
    $$ select to_jsonb(b) from member_bootstrap('de89-sa') b $$)->>'has_unread_studio_message')::boolean);

\echo '--- 12c. staff delete a whole conversation (Decision 89 (a)) ---'
reset role;
-- stage an attachment under MA1's thread prefix {studio}/{thread}/.
insert into storage.objects (bucket_id, name)
  values ('message-attachments', 'de890000-0000-0000-0000-0000000000a0/' || :'thr' || '/photo.jpg');
-- another studio's owner is refused; an instructor is refused; the thread stands.
select expect_eq('another studio''s owner cannot delete the thread',
  as_json('de890000-0000-0000-0000-0000000000b1', format('select staff_delete_thread(%L)', :'thr'))->>'err', 'PT403');
select expect_eq('an instructor cannot delete the thread',
  as_json('de890000-0000-0000-0000-0000000000e1', format('select staff_delete_thread(%L)', :'thr'))->>'err', 'PT403');
reset role;
select expect_num('after the refusals the thread still exists',
  (select count(*) from message_threads where id = :'thr'::uuid), 1);
select expect_num('after the refusals the attachment still exists',
  (select count(*) from storage.objects where bucket_id='message-attachments'
     and name like 'de890000-0000-0000-0000-0000000000a0/' || :'thr' || '/%'), 1);
-- SA front desk deletes the conversation.
select expect_true('front desk deletes the conversation',
  (as_json('de890000-0000-0000-0000-0000000000f1', format('select staff_delete_thread(%L)', :'thr'))->>'ok')::boolean);
reset role;
select expect_num('the thread_messages are gone',
  (select count(*) from thread_messages where thread_id = :'thr'::uuid), 0);
select expect_num('the attachment storage objects are gone',
  (select count(*) from storage.objects where bucket_id='message-attachments'
     and name like 'de890000-0000-0000-0000-0000000000a0/' || :'thr' || '/%'), 0);
select expect_num('a thread_deleted audit row was written',
  (select count(*) from audit_logs where action='message.thread_deleted' and entity_id = :'thr'::uuid), 1);
-- the member's screen returns to the empty state (member_messages re-opens an empty thread).
select expect_num('the member now sees an empty thread',
  jsonb_array_length(as_json('de890000-0000-0000-0000-0000000000c1',
    $$ select member_messages('de890000-0000-0000-0000-0000000000a0') $$) -> 'messages'), 0);

\echo '--- 13. the anon surface is still EXACTLY THIRTEEN ---'
-- The suite's own helpers (as_json/as_count/expect_*) are anon-executable locally;
-- exclude them. The migration itself asserts the clean thirteen at apply time.
reset role;
select expect_num('anon surface is thirteen',
  (select count(*) from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
    where ns.nspname='public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not in ('as_json','as_count','expect_num','expect_eq','expect_true')), 13);

reset role;
drop function as_json(text, text); drop function as_count(text, text);
drop function expect_num(text, bigint, bigint); drop function expect_eq(text, text, text); drop function expect_true(text, boolean);
\echo 'studio_messages_test: all assertions passed'
