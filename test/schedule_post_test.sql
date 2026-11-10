-- =============================================================================
-- Decision 93 slice 2 — schedule_post_data. UUID space 93c0, checked free.
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/schedule_post_test.sql
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages = notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  (expected true)', label; end if;
end $$;
create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual,'null'); end if;
end $$;
create or replace function expect_raise(label text, uid uuid, sql text, want_sqlstate text)
returns void language plpgsql as $$
declare got text;
begin
  perform set_config('request.jwt.claim.sub', uid::text, true);
  execute 'set local role authenticated';
  begin execute sql; got := 'NO RAISE';
  exception when others then got := sqlstate; end;
  execute 'set local role postgres';
  if got = want_sqlstate then raise notice 'PASS  %  (%)', label, got;
  else raise exception 'FAIL  %  expected %, got %', label, want_sqlstate, got; end if;
end $$;
create or replace function call_jsonb(uid uuid, sql text) returns jsonb
language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claim.sub', uid::text, true);
  execute 'set local role authenticated';
  execute sql into r;
  execute 'set local role postgres';
  return r;
end $$;

-- --- Fixtures ---------------------------------------------------------------
insert into auth.users (id) values
  ('93c00000-0000-0000-0000-0000000000a2'),   -- SA manager
  ('93c00000-0000-0000-0000-0000000000a3'),   -- SA front desk
  ('93c00000-0000-0000-0000-0000000000a4'),   -- SA instructor (login)
  ('93c00000-0000-0000-0000-0000000000b1');   -- SB owner
insert into profiles (id, email) values
  ('93c00000-0000-0000-0000-0000000000a2','sp-mgr@example.com'),
  ('93c00000-0000-0000-0000-0000000000a3','sp-fd@example.com'),
  ('93c00000-0000-0000-0000-0000000000a4','sp-inst@example.com'),
  ('93c00000-0000-0000-0000-0000000000b1','sp-sb@example.com');
insert into studios (id, name, slug, timezone, currency, status, accent_color, theme_preset, logo_url) values
  ('93c00000-0000-0000-0000-00000000a000','Post Studio A','post-a','Europe/Prague','CZK','active','#B85C38','warm','https://example.com/logo.png'),
  ('93c00000-0000-0000-0000-00000000b000','Post Studio B','post-b','Europe/Prague','CZK','active','#1A2B4C','bold',null);
insert into studio_settings (studio_id, flex_min_bookings, post_footer_line, post_hashtags) values
  ('93c00000-0000-0000-0000-00000000a000', 2, 'See you on the reformer', '#poststudio #pilates'),
  ('93c00000-0000-0000-0000-00000000b000', 1, 'Book on the app', null);
insert into studio_staff (id, studio_id, user_id, email, role, status) values
  ('93c00000-0000-0000-0000-00000000a0a2','93c00000-0000-0000-0000-00000000a000','93c00000-0000-0000-0000-0000000000a2','sp-mgr@example.com','manager','active'),
  ('93c00000-0000-0000-0000-00000000a0a3','93c00000-0000-0000-0000-00000000a000','93c00000-0000-0000-0000-0000000000a3','sp-fd@example.com','front_desk','active'),
  ('93c00000-0000-0000-0000-00000000a0a4','93c00000-0000-0000-0000-00000000a000','93c00000-0000-0000-0000-0000000000a4','sp-inst@example.com','instructor','active'),
  ('93c00000-0000-0000-0000-00000000b0b1','93c00000-0000-0000-0000-00000000b000','93c00000-0000-0000-0000-0000000000b1','sp-sb@example.com','owner','active');
insert into locations (id, studio_id, name, is_primary) values
  ('93c00000-0000-0000-0000-0000000000aa','93c00000-0000-0000-0000-00000000a000','Main',true),
  ('93c00000-0000-0000-0000-0000000000bb','93c00000-0000-0000-0000-00000000b000','Main',true);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('93c00000-0000-0000-0000-0000000000a1','93c00000-0000-0000-0000-00000000a000','93c00000-0000-0000-0000-0000000000aa','RA',10),
  ('93c00000-0000-0000-0000-0000000000b1','93c00000-0000-0000-0000-00000000b000','93c00000-0000-0000-0000-0000000000bb','RB',10);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('93c00000-0000-0000-0000-0000000000c1','93c00000-0000-0000-0000-00000000a000','Reformer',50,10),
  ('93c00000-0000-0000-0000-0000000000c2','93c00000-0000-0000-0000-00000000b000','Reformer',50,10);
insert into instructors (id, studio_id, display_name, staff_id, avatar_url) values
  ('93c00000-0000-0000-0000-0000000000f1','93c00000-0000-0000-0000-00000000a000','Ada Example','93c00000-0000-0000-0000-00000000a0a4','https://example.com/ada.jpg'),
  ('93c00000-0000-0000-0000-0000000000f3','93c00000-0000-0000-0000-00000000a000','Cleo Sampleton',null,'https://example.com/cleo.jpg'),
  ('93c00000-0000-0000-0000-0000000000f2','93c00000-0000-0000-0000-00000000b000','Bo Fictitious',null,null);

-- SA occurrences on 2027-03-15 (Prague, +01, before DST): a visible core at 07:00,
-- a visible flex at 09:00, a HIDDEN at 08:00, a CANCELLED at 10:00. Distinct times
-- in one room (no overlap). SB has one visible class the same day.
insert into class_occurrences
  (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, starts_at, ends_at, status, flex, hidden_from_members, guarantee_tier) values
  ('93c00000-0000-0000-0000-00000000e001','93c00000-0000-0000-0000-00000000a000','93c00000-0000-0000-0000-0000000000aa','93c00000-0000-0000-0000-0000000000c1','93c00000-0000-0000-0000-0000000000a1','93c00000-0000-0000-0000-0000000000f1','Reformer Flow',10,
     (date '2027-03-15' + time '07:00') at time zone 'Europe/Prague', (date '2027-03-15' + time '07:50') at time zone 'Europe/Prague','scheduled', false, false, 'core'),
  ('93c00000-0000-0000-0000-00000000e002','93c00000-0000-0000-0000-00000000a000','93c00000-0000-0000-0000-0000000000aa','93c00000-0000-0000-0000-0000000000c1','93c00000-0000-0000-0000-0000000000a1','93c00000-0000-0000-0000-0000000000f1','Reformer Flex',10,
     (date '2027-03-15' + time '09:00') at time zone 'Europe/Prague', (date '2027-03-15' + time '09:50') at time zone 'Europe/Prague','scheduled', true,  false, null),
  ('93c00000-0000-0000-0000-00000000e003','93c00000-0000-0000-0000-00000000a000','93c00000-0000-0000-0000-0000000000aa','93c00000-0000-0000-0000-0000000000c1','93c00000-0000-0000-0000-0000000000a1','93c00000-0000-0000-0000-0000000000f1','Private Hidden',10,
     (date '2027-03-15' + time '08:00') at time zone 'Europe/Prague', (date '2027-03-15' + time '08:50') at time zone 'Europe/Prague','scheduled', false, true,  'core'),
  ('93c00000-0000-0000-0000-00000000e004','93c00000-0000-0000-0000-00000000a000','93c00000-0000-0000-0000-0000000000aa','93c00000-0000-0000-0000-0000000000c1','93c00000-0000-0000-0000-0000000000a1','93c00000-0000-0000-0000-0000000000f1','Reformer Cancelled',10,
     (date '2027-03-15' + time '10:00') at time zone 'Europe/Prague', (date '2027-03-15' + time '10:50') at time zone 'Europe/Prague','cancelled', false, false, 'core'),
  ('93c00000-0000-0000-0000-00000000e0b1','93c00000-0000-0000-0000-00000000b000','93c00000-0000-0000-0000-0000000000bb','93c00000-0000-0000-0000-0000000000c2','93c00000-0000-0000-0000-0000000000b1','93c00000-0000-0000-0000-0000000000f2','SB Reformer',10,
     (date '2027-03-15' + time '07:00') at time zone 'Europe/Prague', (date '2027-03-15' + time '07:50') at time zone 'Europe/Prague','scheduled', false, false, 'core'),
  -- a SECOND SA coach's class (Cleo, 11:00) — distinct time in RA, no overlap
  ('93c00000-0000-0000-0000-00000000e005','93c00000-0000-0000-0000-00000000a000','93c00000-0000-0000-0000-0000000000aa','93c00000-0000-0000-0000-0000000000c1','93c00000-0000-0000-0000-0000000000a1','93c00000-0000-0000-0000-0000000000f3','Reformer Sculpt',10,
     (date '2027-03-15' + time '11:00') at time zone 'Europe/Prague', (date '2027-03-15' + time '11:50') at time zone 'Europe/Prague','scheduled', false, false, 'core');

\set SA '93c00000-0000-0000-0000-00000000a000'
\set SB '93c00000-0000-0000-0000-00000000b000'
\set MGR '93c00000-0000-0000-0000-0000000000a2'
\set FD  '93c00000-0000-0000-0000-0000000000a3'
\set INST '93c00000-0000-0000-0000-0000000000a4'

-- ===========================================================================
-- 1. Excludes hidden and cancelled; carries the visible classes
select expect_num('one day in range', jsonb_array_length(
  call_jsonb(:'MGR', 'select schedule_post_data('''|| :'SA' ||''',''2027-03-15'',''2027-03-15'',false)') -> 'days'), 1);
select expect_num('three visible classes (hidden + cancelled excluded)', jsonb_array_length(
  call_jsonb(:'MGR', 'select schedule_post_data('''|| :'SA' ||''',''2027-03-15'',''2027-03-15'',false)') -> 'days' -> 0 -> 'classes'), 3);
select expect_text('first class is the 07:00 core',
  call_jsonb(:'MGR', 'select schedule_post_data('''|| :'SA' ||''',''2027-03-15'',''2027-03-15'',false)') -> 'days' -> 0 -> 'classes' -> 0 ->> 'name', 'Reformer Flow');
select expect_text('first class carries the instructor first name',
  call_jsonb(:'MGR', 'select schedule_post_data('''|| :'SA' ||''',''2027-03-15'',''2027-03-15'',false)') -> 'days' -> 0 -> 'classes' -> 0 ->> 'coach', 'Ada');
select expect_text('first class time via fmt_clock (24h default)',
  call_jsonb(:'MGR', 'select schedule_post_data('''|| :'SA' ||''',''2027-03-15'',''2027-03-15'',false)') -> 'days' -> 0 -> 'classes' -> 0 ->> 'time', '07:00');
-- the hidden "Private Hidden" and the cancelled one appear nowhere
select expect_num('hidden class never appears', (
  select count(*) from jsonb_array_elements(
    call_jsonb(:'MGR', 'select schedule_post_data('''|| :'SA' ||''',''2027-03-15'',''2027-03-15'',false)') -> 'days' -> 0 -> 'classes') c
  where c ->> 'name' in ('Private Hidden','Reformer Cancelled')), 0);
-- the studio chrome
select expect_text('footer line carried', call_jsonb(:'MGR', 'select schedule_post_data('''|| :'SA' ||''',''2027-03-15'',''2027-03-15'',false)') ->> 'footer_line', 'See you on the reformer');
select expect_text('hashtags carried', call_jsonb(:'MGR', 'select schedule_post_data('''|| :'SA' ||''',''2027-03-15'',''2027-03-15'',false)') ->> 'hashtags', '#poststudio #pilates');
select expect_num('flex_min carried', (call_jsonb(:'MGR', 'select schedule_post_data('''|| :'SA' ||''',''2027-03-15'',''2027-03-15'',false)') ->> 'flex_min')::bigint, 2);

-- 2. core_only respects the tier — the flex class drops out (2 core remain)
select expect_num('core_only: two core classes', jsonb_array_length(
  call_jsonb(:'MGR', 'select schedule_post_data('''|| :'SA' ||''',''2027-03-15'',''2027-03-15'',true)') -> 'days' -> 0 -> 'classes'), 2);
select expect_text('core_only: it is the core one',
  call_jsonb(:'MGR', 'select schedule_post_data('''|| :'SA' ||''',''2027-03-15'',''2027-03-15'',true)') -> 'days' -> 0 -> 'classes' -> 0 ->> 'name', 'Reformer Flow');

-- 3. An empty range -> no days
select expect_num('empty range -> zero days', jsonb_array_length(
  call_jsonb(:'MGR', 'select schedule_post_data('''|| :'SA' ||''',''2027-03-16'',''2027-03-16'',false)') -> 'days'), 0);

-- 4. Front desk may make posts
select expect_num('front desk may read post data', jsonb_array_length(
  call_jsonb(:'FD', 'select schedule_post_data('''|| :'SA' ||''',''2027-03-15'',''2027-03-15'',false)') -> 'days'), 1);

-- 5. Guards: instructor refused, cross-studio refused, bad range refused
select expect_raise('instructor cannot read post data', :'INST'::uuid,
  'select schedule_post_data('''|| :'SA' ||''',''2027-03-15'',''2027-03-15'',false)', 'PT403');
select expect_raise('SA manager cannot read SB''s post data', :'MGR'::uuid,
  'select schedule_post_data('''|| :'SB' ||''',''2027-03-15'',''2027-03-15'',false)', 'PT403');
select expect_raise('range ending before it starts is refused', :'MGR'::uuid,
  'select schedule_post_data('''|| :'SA' ||''',''2027-03-15'',''2027-03-14'',false)', 'PT400');

-- =============================================================================
-- Decision 93 slice 3 — post editing: the extended validator + the edit run gate
-- =============================================================================

-- 7a. brand_kit_valid still accepts an old spec, accepts valid layout fields,
--     and rejects out-of-range ones (mirrors lib/brand-kit.mjs isValidSpec).
do $$
declare base jsonb := jsonb_build_object(
  'colors', jsonb_build_object('background','#FAFAF7','surface','#FFFFFF','ink','#14170E','accent','#B85C38','secondary','#57534E'),
  'display_font','Space Grotesk','body_font','Space Grotesk','layout','list','radius','small',
  'tone','Clean.','logo_placement','top-left','background_treatment','none');
begin
  perform expect_true('validator: an old spec (no layout fields) is valid', brand_kit_valid(base));
  perform expect_true('validator: valid layout fields pass', brand_kit_valid(
    base || jsonb_build_object('background_image','studio/2027-03/edit-1.jpg','image_placement','full',
      'overlay_strength',0.4,'text_align','center','size_scale',jsonb_build_object('time',1.5,'name',0.8),
      'element_order', jsonb_build_array('title','classes','footer','logo'))));
  perform expect_true('validator: a bad image_placement is rejected',
    not brand_kit_valid(base || jsonb_build_object('image_placement','diagonal')));
  perform expect_true('validator: overlay_strength out of 0..1 is rejected',
    not brand_kit_valid(base || jsonb_build_object('overlay_strength',1.5)));
  perform expect_true('validator: a size_scale out of 0.5..2 is rejected',
    not brand_kit_valid(base || jsonb_build_object('size_scale', jsonb_build_object('time',5))));
  perform expect_true('validator: an unknown element_order token is rejected',
    not brand_kit_valid(base || jsonb_build_object('element_order', jsonb_build_array('title','banner'))));
end $$;

-- 7b. post_edit_run_allowed: front desk (desk-up) runs it and the count climbs.
select expect_true('edit gate: front desk may run, ok=true',
  (call_jsonb(:'FD', 'select post_edit_run_allowed('''|| :'SA' ||''')') ->> 'ok')::boolean);
select expect_num('edit gate: used climbed to 2 on a second run',
  (call_jsonb(:'FD', 'select post_edit_run_allowed('''|| :'SA' ||''')') ->> 'used')::bigint, 2);

-- 7c. The sixty-first is refused with reason post_edit_limit (pin the counter at
--     the cap with a far-future reset so it does not roll over).
update studio_settings set post_edit_runs_month = 60, post_edit_runs_reset_on = '2099-01-01'
  where studio_id = :'SA';
select expect_text('edit gate: the 61st is refused post_edit_limit',
  call_jsonb(:'MGR', 'select post_edit_run_allowed('''|| :'SA' ||''')') ->> 'reason', 'post_edit_limit');
select expect_true('edit gate: a refused run is ok=false',
  not (call_jsonb(:'MGR', 'select post_edit_run_allowed('''|| :'SA' ||''')') ->> 'ok')::boolean);

-- 7d. An instructor and a cross-studio manager are refused (PT403).
select expect_raise('edit gate: instructor refused', :'INST'::uuid,
  'select post_edit_run_allowed('''|| :'SA' ||''')', 'PT403');
select expect_raise('edit gate: SA manager cannot run SB''s gate', :'MGR'::uuid,
  'select post_edit_run_allowed('''|| :'SB' ||''')', 'PT403');

-- =============================================================================
-- Decision 93 amendment — the coach filter (p_instructor_id)
-- =============================================================================
\set F1 '93c00000-0000-0000-0000-0000000000f1'
\set F3 '93c00000-0000-0000-0000-0000000000f3'
\set SBF2 '93c00000-0000-0000-0000-0000000000f2'

-- 8a. Filtering to Ada returns ONLY her visible classes (07:00 core + 09:00 flex);
--     Cleo's 11:00 and the hidden/cancelled are excluded.
select expect_num('coach filter: Ada has two visible classes', jsonb_array_length(
  call_jsonb(:'MGR', 'select schedule_post_data('''|| :'SA' ||''',''2027-03-15'',''2027-03-15'',false,'''|| :'F1' ||''')') -> 'days' -> 0 -> 'classes'), 2);
select expect_text('coach filter: every class is Ada''s (first)',
  call_jsonb(:'MGR', 'select schedule_post_data('''|| :'SA' ||''',''2027-03-15'',''2027-03-15'',false,'''|| :'F1' ||''')') -> 'days' -> 0 -> 'classes' -> 0 ->> 'name', 'Reformer Flow');
select expect_num('coach filter: Cleo''s class is absent from Ada''s post', (
  select count(*) from jsonb_array_elements(
    call_jsonb(:'MGR', 'select schedule_post_data('''|| :'SA' ||''',''2027-03-15'',''2027-03-15'',false,'''|| :'F1' ||''')') -> 'days' -> 0 -> 'classes') c
  where c ->> 'name' = 'Reformer Sculpt'), 0);
select expect_text('coach filter: coach_first is the chosen coach',
  call_jsonb(:'MGR', 'select schedule_post_data('''|| :'SA' ||''',''2027-03-15'',''2027-03-15'',false,'''|| :'F1' ||''')') ->> 'coach_first', 'Ada');
select expect_text('coach filter: coach_photo is the chosen coach''s',
  call_jsonb(:'MGR', 'select schedule_post_data('''|| :'SA' ||''',''2027-03-15'',''2027-03-15'',false,'''|| :'F1' ||''')') ->> 'coach_photo', 'https://example.com/ada.jpg');

-- 8b. Filtering to Cleo returns only her one class; hidden stays excluded.
select expect_num('coach filter: Cleo has one class', jsonb_array_length(
  call_jsonb(:'MGR', 'select schedule_post_data('''|| :'SA' ||''',''2027-03-15'',''2027-03-15'',false,'''|| :'F3' ||''')') -> 'days' -> 0 -> 'classes'), 1);
select expect_text('coach filter: it is Cleo''s Sculpt',
  call_jsonb(:'MGR', 'select schedule_post_data('''|| :'SA' ||''',''2027-03-15'',''2027-03-15'',false,'''|| :'F3' ||''')') -> 'days' -> 0 -> 'classes' -> 0 ->> 'name', 'Reformer Sculpt');

-- 8c. No coach -> coach_first/photo are null (the "All classes" default).
select expect_true('coach filter: null coach -> no coach_first',
  call_jsonb(:'MGR', 'select schedule_post_data('''|| :'SA' ||''',''2027-03-15'',''2027-03-15'',false)') ->> 'coach_first' is null);

-- 8d. A cross-studio instructor is refused (SB's Bo against SA).
select expect_raise('coach filter: a cross-studio instructor is refused', :'MGR'::uuid,
  'select schedule_post_data('''|| :'SA' ||''',''2027-03-15'',''2027-03-15'',false,'''|| :'SBF2' ||''')', 'PT403');

-- ===========================================================================
-- 9. spots_left (Decision 93 amendment): capacity minus live seats, floored at 0.
-- occurrence_seats_taken is the live count (cancelled / late_cancelled / waitlisted
-- never count). s001 on 2027-03-16 is capacity 6 with 4 live seats (booked,
-- attended, no_show, pending_payment) + 1 cancelled + 1 late_cancelled + 1
-- waitlisted -> spots_left 2. s002 is capacity 2 fully booked -> 0.
insert into members (id, studio_id, first_name, last_name, email) values
  ('93c00000-0000-0000-0000-00000000d001','93c00000-0000-0000-0000-00000000a000','M','One','spm1@example.com'),
  ('93c00000-0000-0000-0000-00000000d002','93c00000-0000-0000-0000-00000000a000','M','Two','spm2@example.com'),
  ('93c00000-0000-0000-0000-00000000d003','93c00000-0000-0000-0000-00000000a000','M','Three','spm3@example.com'),
  ('93c00000-0000-0000-0000-00000000d004','93c00000-0000-0000-0000-00000000a000','M','Four','spm4@example.com'),
  ('93c00000-0000-0000-0000-00000000d005','93c00000-0000-0000-0000-00000000a000','M','Five','spm5@example.com'),
  ('93c00000-0000-0000-0000-00000000d006','93c00000-0000-0000-0000-00000000a000','M','Six','spm6@example.com'),
  ('93c00000-0000-0000-0000-00000000d007','93c00000-0000-0000-0000-00000000a000','M','Seven','spm7@example.com'),
  ('93c00000-0000-0000-0000-00000000d008','93c00000-0000-0000-0000-00000000a000','M','Eight','spm8@example.com'),
  ('93c00000-0000-0000-0000-00000000d009','93c00000-0000-0000-0000-00000000a000','M','Nine','spm9@example.com');
insert into class_occurrences
  (id, studio_id, location_id, class_type_id, room_id, instructor_id, name, capacity, starts_at, ends_at, status, flex, hidden_from_members, guarantee_tier) values
  ('93c00000-0000-0000-0000-00000000e101','93c00000-0000-0000-0000-00000000a000','93c00000-0000-0000-0000-0000000000aa','93c00000-0000-0000-0000-0000000000c1','93c00000-0000-0000-0000-0000000000a1','93c00000-0000-0000-0000-0000000000f1','Spots Two',6,
     '2027-03-16 06:00:00+00','2027-03-16 06:50:00+00','scheduled',false,false,'core'),
  ('93c00000-0000-0000-0000-00000000e102','93c00000-0000-0000-0000-00000000a000','93c00000-0000-0000-0000-0000000000aa','93c00000-0000-0000-0000-0000000000c1','93c00000-0000-0000-0000-0000000000a1','93c00000-0000-0000-0000-0000000000f1','Spots Full',2,
     '2027-03-16 08:00:00+00','2027-03-16 08:50:00+00','scheduled',false,false,'core');
insert into bookings (studio_id, occurrence_id, member_id, status) values
  -- s001 (e101): 4 live seats
  ('93c00000-0000-0000-0000-00000000a000','93c00000-0000-0000-0000-00000000e101','93c00000-0000-0000-0000-00000000d001','booked'),
  ('93c00000-0000-0000-0000-00000000a000','93c00000-0000-0000-0000-00000000e101','93c00000-0000-0000-0000-00000000d002','attended'),
  ('93c00000-0000-0000-0000-00000000a000','93c00000-0000-0000-0000-00000000e101','93c00000-0000-0000-0000-00000000d003','no_show'),
  ('93c00000-0000-0000-0000-00000000a000','93c00000-0000-0000-0000-00000000e101','93c00000-0000-0000-0000-00000000d004','pending_payment'),
  -- s001: not-counted seats
  ('93c00000-0000-0000-0000-00000000a000','93c00000-0000-0000-0000-00000000e101','93c00000-0000-0000-0000-00000000d005','cancelled'),
  ('93c00000-0000-0000-0000-00000000a000','93c00000-0000-0000-0000-00000000e101','93c00000-0000-0000-0000-00000000d006','late_cancelled'),
  ('93c00000-0000-0000-0000-00000000a000','93c00000-0000-0000-0000-00000000e101','93c00000-0000-0000-0000-00000000d007','waitlisted'),
  -- s002 (e102): full
  ('93c00000-0000-0000-0000-00000000a000','93c00000-0000-0000-0000-00000000e102','93c00000-0000-0000-0000-00000000d008','booked'),
  ('93c00000-0000-0000-0000-00000000a000','93c00000-0000-0000-0000-00000000e102','93c00000-0000-0000-0000-00000000d009','attended');

select expect_num('spots_left: capacity 6, 4 live seats -> 2',
  (call_jsonb(:'MGR', 'select schedule_post_data('''|| :'SA' ||''',''2027-03-16'',''2027-03-16'',false)') -> 'days' -> 0 -> 'classes' -> 0 ->> 'spots_left')::bigint, 2);
select expect_num('spots_left: full class (capacity 2, 2 live) -> 0',
  (call_jsonb(:'MGR', 'select schedule_post_data('''|| :'SA' ||''',''2027-03-16'',''2027-03-16'',false)') -> 'days' -> 0 -> 'classes' -> 1 ->> 'spots_left')::bigint, 0);
select expect_text('spots_left: the counted class is the 06:00 "Spots Two"',
  call_jsonb(:'MGR', 'select schedule_post_data('''|| :'SA' ||''',''2027-03-16'',''2027-03-16'',false)') -> 'days' -> 0 -> 'classes' -> 0 ->> 'name', 'Spots Two');

-- ===========================================================================
-- 10. Decision 93 part (c): instructor posts. INST (user a4) resolves to
-- instructor Ada (f1). On 2027-03-15 Ada teaches the visible e001 (07:00) and
-- e002 (09:00); Cleo (f3) teaches Reformer Sculpt (e005, 11:00), which is NOT
-- Ada's. The reader resolves the caller from auth, never a parameter.
select expect_num('instructor posts: Ada sees her 2 visible classes',
  jsonb_array_length(call_jsonb(:'INST','select instructor_schedule_post_data(''2027-03-15'',''2027-03-15'',false)') -> 'days' -> 0 -> 'classes'), 2);
select expect_text('instructor posts: coach_first is Ada',
  call_jsonb(:'INST','select instructor_schedule_post_data(''2027-03-15'',''2027-03-15'',false)') ->> 'coach_first', 'Ada');
select expect_true('instructor posts: Cleo''s Reformer Sculpt is absent from Ada''s post',
  not (call_jsonb(:'INST','select instructor_schedule_post_data(''2027-03-15'',''2027-03-15'',false)') -> 'days' -> 0 -> 'classes' @> '[{"name":"Reformer Sculpt"}]'::jsonb));
select expect_true('instructor posts: a class carries spots_left (same shape)',
  call_jsonb(:'INST','select instructor_schedule_post_data(''2027-03-15'',''2027-03-15'',false)') -> 'days' -> 0 -> 'classes' -> 0 ? 'spots_left');
select expect_raise('instructor posts: front desk refused (no instructor row)', :'FD'::uuid,
  'select instructor_schedule_post_data(''2027-03-15'',''2027-03-15'',false)', 'PT403');
select expect_raise('instructor posts: manager refused (no instructor row)', :'MGR'::uuid,
  'select instructor_schedule_post_data(''2027-03-15'',''2027-03-15'',false)', 'PT403');

-- instructor_brand_kit returns the caller's studio kit, read-only.
select expect_text('instructor brand kit: footer is the studio''s',
  call_jsonb(:'INST','select instructor_brand_kit()') ->> 'footer_line', 'See you on the reformer');
select expect_text('instructor brand kit: hashtags are the studio''s',
  call_jsonb(:'INST','select instructor_brand_kit()') ->> 'hashtags', '#poststudio #pilates');
select expect_true('instructor brand kit: carries a spec',
  call_jsonb(:'INST','select instructor_brand_kit()') ? 'spec');
select expect_raise('instructor brand kit: front desk refused', :'FD'::uuid,
  'select instructor_brand_kit()', 'PT403');

-- 6. anon refused, and the surface is EXACTLY THIRTEEN
do $$
declare got text;
begin
  set local role anon;
  begin perform schedule_post_data('93c00000-0000-0000-0000-00000000a000','2027-03-15','2027-03-15',false); got := 'NO RAISE';
  exception when others then got := 'refused'; end;
  set local role postgres;
  perform expect_true('anon cannot read post data', got = 'refused');
end $$;
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname='public' and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'expect%' and p.proname <> 'call_jsonb';
  perform expect_num('anon surface is exactly thirteen', n::bigint, 13);
end $$;

select 'schedule_post_test OK' as result;
