-- =============================================================================
-- Announcements + account reads — Decision 27, migrations 131/132
-- =============================================================================
-- UUID space a11c, checked free. Run after `supabase db reset`.
--
-- A member sees only their own studio's published, in-range, member-audience
-- announcements, not dismissed; an instructor sees the instructor-audience ones
-- and never a members-only; out-of-range and drafts are invisible; a dismissed
-- one stays dismissed; a studio with none returns []; provider detection is true
-- with a connected account and false without; milestones lead with the next
-- target. Two studios in one run.
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
create or replace function expect_false(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual is not null and not actual then raise notice 'PASS  %  (got false)', label;
  else raise exception 'FAIL  %  expected false, got %', label, coalesce(actual::text,'null'); end if;
end $$;
-- call an RPC as a given user and return its jsonb, or capture the sqlstate
create or replace function as_state(uid text, sql text) returns text language plpgsql as $$
declare r text;
begin
  perform set_config('request.jwt.claim.sub', uid, true);
  set local role authenticated;
  begin execute sql into r; return coalesce(r,'null'); exception when others then return 'ERR:'||sqlstate; end;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('a11ca11c-0000-0000-0000-0000000000a1'),  -- owner A (manager-up)
  ('a11ca11c-0000-0000-0000-0000000000a2'),  -- member A
  ('a11ca11c-0000-0000-0000-0000000000a3'),  -- instructor A
  ('a11ca11c-0000-0000-0000-0000000000b2');  -- member B
insert into profiles (id, email) select id, id::text||'@example.com' from auth.users where id::text like 'a11ca11c%';

-- Studio A has a connected provider; studio B has none.
insert into studios (id, name, slug, timezone, currency, status, stripe_account_id) values
  ('a11ca11c-0000-0000-0000-000000000001','Announce A','a11c-a','Europe/Prague','CZK','active','acct_123'),
  ('a11ca11c-0000-0000-0000-000000000002','Announce B','a11c-b','Asia/Manila','PHP','active',null);
insert into studio_settings (studio_id) values
  ('a11ca11c-0000-0000-0000-000000000001'),
  ('a11ca11c-0000-0000-0000-000000000002');
insert into studio_staff (studio_id, user_id, email, role) values
  ('a11ca11c-0000-0000-0000-000000000001','a11ca11c-0000-0000-0000-0000000000a1','a11c-owa@example.com','owner'),
  ('a11ca11c-0000-0000-0000-000000000001','a11ca11c-0000-0000-0000-0000000000a3','a11c-insa@example.com','instructor');
insert into members (id, studio_id, user_id, first_name, last_name, email, lifetime_visits) values
  ('a11ca11c-0000-0000-0000-0000000d0a02','a11ca11c-0000-0000-0000-000000000001','a11ca11c-0000-0000-0000-0000000000a2','Mem','Ay','a11c-ma@example.com',60),
  ('a11ca11c-0000-0000-0000-0000000d0b02','a11ca11c-0000-0000-0000-000000000002','a11ca11c-0000-0000-0000-0000000000b2','Mem','Bee','a11c-mb@example.com',5);

-- Announcements in A: members, both (pinned), instructors, future, past, draft.
insert into announcements (id, studio_id, title, body, starts_at, ends_at, status, audience, pinned) values
  ('a11ca11c-0000-0000-0000-00000000e001','a11ca11c-0000-0000-0000-000000000001','New intro offer','Three classes for a good price.', now()-interval '1 day', now()+interval '7 days','published','members',false),
  ('a11ca11c-0000-0000-0000-00000000e002','a11ca11c-0000-0000-0000-000000000001','Closed for the holiday','We are shut 24-26 Dec.', now()-interval '2 days', now()+interval '30 days','published','both',true),
  ('a11ca11c-0000-0000-0000-00000000e003','a11ca11c-0000-0000-0000-000000000001','Cover needed Friday','Instructors, pick up a class.', now()-interval '1 day', now()+interval '3 days','published','instructors',false),
  ('a11ca11c-0000-0000-0000-00000000e004','a11ca11c-0000-0000-0000-000000000001','Coming soon','Starts next week.', now()+interval '2 days', now()+interval '9 days','published','members',false),
  ('a11ca11c-0000-0000-0000-00000000e005','a11ca11c-0000-0000-0000-000000000001','Old news','This has ended.', now()-interval '10 days', now()-interval '1 day','published','members',false),
  ('a11ca11c-0000-0000-0000-00000000e006','a11ca11c-0000-0000-0000-000000000001','Draft','Not published yet.', now()-interval '1 day', now()+interval '7 days','draft','members',false);

-- Amendment (migration 168): two BANNERS in A — one for both audiences with a
-- link (tap opens it), one members-only with no link. Title only, body empty.
insert into announcements (id, studio_id, kind, title, body, starts_at, ends_at, status, audience, pinned, link_url, link_label) values
  ('a11ca11c-0000-0000-0000-00000000e007','a11ca11c-0000-0000-0000-000000000001','banner','Studio closed Monday','', now()-interval '1 day', now()+interval '5 days','published','both',false,'https://reform.example.com/holiday','Details'),
  ('a11ca11c-0000-0000-0000-00000000e008','a11ca11c-0000-0000-0000-000000000001','banner','New timetable is live','', now()-interval '1 day', now()+interval '5 days','published','members',false,null,null);

-- =============================================================================
-- Member A: members + both, pinned first, not instr/future/past/draft.
-- =============================================================================
-- Two posts (intro, holiday) + two banners (closed, timetable) = 4.
select expect_num('member sees members + both audience only, in range (2 posts + 2 banners)',
  jsonb_array_length(as_state('a11ca11c-0000-0000-0000-0000000000a2',
    $$ select member_announcements('a11ca11c-0000-0000-0000-000000000001') $$)::jsonb), 4);
select set_config('request.jwt.claim.sub','',false); reset role;

-- The kind field is carried, and the split is right: 2 posts, 2 banners.
select expect_num('a post appears in the member payload as kind=post (2 of them)',
  (select count(*) from jsonb_array_elements(as_state('a11ca11c-0000-0000-0000-0000000000a2',
     $$ select member_announcements('a11ca11c-0000-0000-0000-000000000001') $$)::jsonb) e
    where e->>'kind' = 'post'), 2);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_num('a banner appears in the member payload as kind=banner (2 of them)',
  (select count(*) from jsonb_array_elements(as_state('a11ca11c-0000-0000-0000-0000000000a2',
     $$ select member_announcements('a11ca11c-0000-0000-0000-000000000001') $$)::jsonb) e
    where e->>'kind' = 'banner'), 2);
select set_config('request.jwt.claim.sub','',false); reset role;
-- A banner with a link carries link_url + a label; one without carries null.
select expect_true('the linked banner carries its https link and label',
  (as_state('a11ca11c-0000-0000-0000-0000000000a2',
    $$ select member_announcements('a11ca11c-0000-0000-0000-000000000001') $$)::jsonb
    @> '[{"kind":"banner","link_url":"https://reform.example.com/holiday","link_label":"Details"}]'::jsonb));
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_true('the unlinked banner carries a null link (tap does not open)',
  (as_state('a11ca11c-0000-0000-0000-0000000000a2',
    $$ select member_announcements('a11ca11c-0000-0000-0000-000000000001') $$)::jsonb
    @> '[{"title":"New timetable is live","link_url":null}]'::jsonb));
select set_config('request.jwt.claim.sub','',false); reset role;
-- pinned first
select expect_true('the pinned announcement is first',
  (as_state('a11ca11c-0000-0000-0000-0000000000a2',
    $$ select member_announcements('a11ca11c-0000-0000-0000-000000000001') $$)::jsonb -> 0 ->> 'id')
    = 'a11ca11c-0000-0000-0000-00000000e002');
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- Instructor A: instructors + both, never a members-only one.
-- =============================================================================
-- instructors (cover), both (holiday post), both (closed banner) = 3.
select expect_num('instructor sees instructors + both audience only (incl. a both-audience banner)',
  jsonb_array_length(as_state('a11ca11c-0000-0000-0000-0000000000a3',
    $$ select instructor_announcements('a11ca11c-0000-0000-0000-000000000001') $$)::jsonb), 3);
select set_config('request.jwt.claim.sub','',false); reset role;
-- and specifically NOT the members-only intro offer
select expect_false('the members-only announcement is not in the instructor portal',
  (as_state('a11ca11c-0000-0000-0000-0000000000a3',
    $$ select instructor_announcements('a11ca11c-0000-0000-0000-000000000001') $$)::jsonb
    @> '[{"title":"New intro offer"}]'::jsonb));
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- Dismissal: a dismissed one stays dismissed.
-- =============================================================================
select as_state('a11ca11c-0000-0000-0000-0000000000a2',
  $$ select dismiss_announcement('a11ca11c-0000-0000-0000-00000000e001')::text $$);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_num('after dismissing one, the member sees one fewer (4 -> 3)',
  jsonb_array_length(as_state('a11ca11c-0000-0000-0000-0000000000a2',
    $$ select member_announcements('a11ca11c-0000-0000-0000-000000000001') $$)::jsonb), 3);
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- A member sees only their own studio; studio B has none.
-- =============================================================================
select expect_num('studio B member sees no announcements (none exist)',
  jsonb_array_length(as_state('a11ca11c-0000-0000-0000-0000000000b2',
    $$ select member_announcements('a11ca11c-0000-0000-0000-000000000002') $$)::jsonb), 0);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_true('a member cannot read another studio''s announcements',
  as_state('a11ca11c-0000-0000-0000-0000000000b2',
    $$ select member_announcements('a11ca11c-0000-0000-0000-000000000001')::text $$) = 'ERR:PT403');
select set_config('request.jwt.claim.sub','',false); reset role;

-- a plain member cannot create an announcement
select expect_true('a member cannot post an announcement',
  as_state('a11ca11c-0000-0000-0000-0000000000a2',
    $$ select create_announcement('a11ca11c-0000-0000-0000-000000000001','x','y',now(),null,'members',false)::text $$) = 'ERR:PT403');
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- Amendment (168): a banner over 120 chars is refused; a link must be https.
-- =============================================================================
select expect_true('a banner over 120 characters is refused (PT422)',
  as_state('a11ca11c-0000-0000-0000-0000000000a1',
    $$ select create_announcement('a11ca11c-0000-0000-0000-000000000001', repeat('x',121), '', now(), null, 'members', false, 'banner')::text $$) = 'ERR:PT422');
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_true('an http:// link is refused (PT422)',
  as_state('a11ca11c-0000-0000-0000-0000000000a1',
    $$ select create_announcement('a11ca11c-0000-0000-0000-000000000001','With a bad link','body',now(),null,'members',false,'post','http://insecure.example.com')::text $$) = 'ERR:PT422');
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_true('an https:// link is accepted (returns a uuid, not an error)',
  as_state('a11ca11c-0000-0000-0000-0000000000a1',
    $$ select create_announcement('a11ca11c-0000-0000-0000-000000000001','With a good link','body',now(),null,'members',false,'post','https://ok.example.com')::text $$) not like 'ERR:%');
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- Provider detection: A has one, B has none.
-- =============================================================================
select expect_true('studio A reports a connected payment provider',
  (as_state('a11ca11c-0000-0000-0000-0000000000a2',
    $$ select to_jsonb(s) from studio_member_settings('a11ca11c-0000-0000-0000-000000000001') s $$)::jsonb ->> 'has_payment_provider')::boolean);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_false('studio B reports no connected provider',
  (as_state('a11ca11c-0000-0000-0000-0000000000b2',
    $$ select to_jsonb(s) from studio_member_settings('a11ca11c-0000-0000-0000-000000000002') s $$)::jsonb ->> 'has_payment_provider')::boolean);
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- Milestones lead with the next target. Member A has 60 visits.
-- =============================================================================
select expect_num('next milestone is 100',
  (as_state('a11ca11c-0000-0000-0000-0000000000a2',
    $$ select member_milestones('a11ca11c-0000-0000-0000-000000000001') $$)::jsonb ->> 'next_target')::bigint, 100);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_num('40 classes to go',
  (as_state('a11ca11c-0000-0000-0000-0000000000a2',
    $$ select member_milestones('a11ca11c-0000-0000-0000-000000000001') $$)::jsonb ->> 'to_go')::bigint, 40);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_true('50 is earned and 100 is not',
  (as_state('a11ca11c-0000-0000-0000-0000000000a2',
    $$ select member_milestones('a11ca11c-0000-0000-0000-000000000001') $$)::jsonb -> 'ladder' @> '[{"target":50,"earned":true}]'::jsonb)
  and (as_state('a11ca11c-0000-0000-0000-0000000000a2',
    $$ select member_milestones('a11ca11c-0000-0000-0000-000000000001') $$)::jsonb -> 'ladder' @> '[{"target":100,"earned":false}]'::jsonb));
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- Publish + notify: members are emailed once; a re-publish sends no more.
-- =============================================================================
select as_state('a11ca11c-0000-0000-0000-0000000000a1',
  $$ select publish_announcement('a11ca11c-0000-0000-0000-00000000e006', true)::text $$);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_num('notifying on publish queues one per member of the studio',
  (select count(*) from notifications where template_key='announcement_posted' and studio_id='a11ca11c-0000-0000-0000-000000000001'), 1);
-- re-publish with notify: no second send (notified_at latch)
select as_state('a11ca11c-0000-0000-0000-0000000000a1',
  $$ select publish_announcement('a11ca11c-0000-0000-0000-00000000e006', true)::text $$);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_num('a re-publish does not email again',
  (select count(*) from notifications where template_key='announcement_posted' and studio_id='a11ca11c-0000-0000-0000-000000000001'), 1);

-- =============================================================================
-- member_dismissals persistence + RLS (migration 166; the free_first_banner key
-- is retired by 168, so this exercises the table with a generic future key).
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','a11ca11c-0000-0000-0000-0000000000a2',false);
insert into member_dismissals (member_id, key) values ('a11ca11c-0000-0000-0000-0000000d0a02','saved_pref');
select expect_num('the member sees their own dismissal row (it persists — a row, not localStorage)',
  (select count(*) from member_dismissals where key='saved_pref'), 1);
select set_config('request.jwt.claim.sub','',false); reset role;

-- Member B (another studio, another person) sees none of A's dismissals.
set role authenticated; select set_config('request.jwt.claim.sub','a11ca11c-0000-0000-0000-0000000000b2',false);
select expect_num('a different member sees none of it (RLS self-scope)',
  (select count(*) from member_dismissals), 0);
-- ...and cannot dismiss on another member's behalf.
do $$ begin
  insert into member_dismissals (member_id, key) values ('a11ca11c-0000-0000-0000-0000000d0a02','sneaky');
  raise exception 'FAIL a member wrote a dismissal for another member';
exception when insufficient_privilege or check_violation then
  raise notice 'PASS  a member cannot dismiss for another member (RLS with check)';
end $$;
select set_config('request.jwt.claim.sub','',false); reset role;

-- =============================================================================
-- Amendment (168): the Book/Home strip is BANNER-only, not pinned. Of member
-- A's in-range items (e001 was dismissed above), two are banners and the
-- pinned holiday POST is not — it stays in What's on, never the strip.
-- =============================================================================
set role authenticated; select set_config('request.jwt.claim.sub','a11ca11c-0000-0000-0000-0000000000a2',false);
select set_config('a11c.ann',
  member_announcements('a11ca11c-0000-0000-0000-000000000001')::text, false);
select set_config('request.jwt.claim.sub','',false); reset role;
select expect_num('exactly two banners reach the strip (kind=banner)',
  (select count(*) from jsonb_array_elements(current_setting('a11c.ann')::jsonb) e
    where e->>'kind' = 'banner'), 2);
select expect_num('the pinned holiday POST is NOT a strip banner (it is What''s on)',
  (select count(*) from jsonb_array_elements(current_setting('a11c.ann')::jsonb) e
    where (e->>'pinned')::boolean and e->>'kind' = 'banner'), 0);

do $$ begin raise notice 'announcements_test: all assertions passed'; end $$;
