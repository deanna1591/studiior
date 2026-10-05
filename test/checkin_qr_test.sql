-- =============================================================================
-- Check-in QR — Decision 35 Part B (migration 20260832360000)
-- =============================================================================
-- UUID space c035, checked free. Run after `supabase db reset`.
--
-- §3 the printed slug: minted once (ensure_checkin_slug idempotent), re-mint
-- changes it and the old slug resolves to nothing (checkin_slug_studio); a slug
-- for another studio resolves to that studio (the page's "different studio");
-- a garbage slug → null; opt-in by existence (null until minted); non-manager
-- refused PT403. §4 instructor_resolve_code: the class's own instructor inside
-- the window → the booked member; a member not booked in that occurrence → not
-- found; another instructor → PT403; window closed → PT409; manager-up allowed;
-- the resulting check_in has method 'instructor'; the waiver gate still fires at
-- the instructor door (PT422). The slug page reuses self_check_in (no new
-- writer). Anon stays EXACTLY THIRTEEN, named; the four new functions are not anon.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_eq(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected true', label; end if;
end $$;
create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if;
end $$;

-- instructor_resolve_code as a user → the member id, 'NONE', or 'ERR:<state>'.
create or replace function c35_irc(p_uid text, p_occ uuid, p_code text)
returns text language plpgsql as $$
declare v uuid;
begin
  perform set_config('request.jwt.claim.sub', p_uid, true);
  set local role authenticated;
  begin
    select member_id into v from instructor_resolve_code(p_occ, p_code) limit 1;
    return coalesce(v::text, 'NONE');
  exception when others then return 'ERR:'||sqlstate; end;
end $$;

-- checkin_slug_studio as a user → the studio id, 'NONE', or 'ERR:<state>'.
create or replace function c35_css(p_uid text, p_slug text)
returns text language plpgsql as $$
declare v uuid;
begin
  perform set_config('request.jwt.claim.sub', p_uid, true);
  set local role authenticated;
  begin v := checkin_slug_studio(p_slug); return coalesce(v::text, 'NONE');
  exception when others then return 'ERR:'||sqlstate; end;
end $$;

-- ensure/remint as a user → the slug or 'ERR:<state>'.
create or replace function c35_slug(p_uid text, p_studio uuid, p_remint boolean)
returns text language plpgsql as $$
declare v text;
begin
  perform set_config('request.jwt.claim.sub', p_uid, true);
  set local role authenticated;
  begin
    if p_remint then v := remint_checkin_slug(p_studio); else v := ensure_checkin_slug(p_studio); end if;
    return v;
  exception when others then return 'ERR:'||sqlstate; end;
end $$;

-- An instructor checks a member in (method 'instructor') → 'OK' or 'ERR:<state>'.
create or replace function c35_ins(p_uid text, p_studio uuid, p_booking uuid, p_member uuid, p_occ uuid)
returns text language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid, true);
  set local role authenticated;
  begin
    insert into check_ins (studio_id, booking_id, member_id, occurrence_id, method)
    values (p_studio, p_booking, p_member, p_occ, 'instructor');
    return 'OK';
  exception when others then return 'ERR:'||sqlstate; end;
end $$;

-- The current rotating code for a member (same bucket resolve_checkin_code uses).
create or replace function c35_code(p_member uuid)
returns text language sql stable as $$
  select checkin_code_for(p_member, floor(extract(epoch from now()) / 30)::bigint);
$$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('c035c035-0000-0000-0000-0000000000a1'),  -- O1  owner of A
  ('c035c035-0000-0000-0000-0000000000a2'),  -- I1  instructor of A, teaches OCC1/OCC2
  ('c035c035-0000-0000-0000-0000000000a3'),  -- I2  another instructor of A
  ('c035c035-0000-0000-0000-0000000000a4'),  -- M1  member of A, booked OCC1
  ('c035c035-0000-0000-0000-0000000000a5'),  -- M2  member of A, booked OCC2
  ('c035c035-0000-0000-0000-0000000000b1'),  -- IB  instructor of B
  ('c035c035-0000-0000-0000-0000000000b2');  -- M3  member of B (stale waiver)
insert into profiles (id, email) select id, id::text||'@example.com' from auth.users where id::text like 'c035%';

insert into studios (id, name, slug, timezone, currency, status) values
  ('c035c035-0000-0000-0000-000000000001','QR A','c035-a','Asia/Manila','PHP','active'),
  ('c035c035-0000-0000-0000-000000000002','QR B','c035-b','Asia/Manila','PHP','active');
insert into studio_settings (studio_id) values
  ('c035c035-0000-0000-0000-000000000001'),
  ('c035c035-0000-0000-0000-000000000002');

insert into locations (id, studio_id, name, is_primary, latitude, longitude,
                       self_checkin_radius_m, self_checkin_accuracy_cap_m, self_checkin_requires_location) values
  ('c035c035-0000-0000-0000-0000000a000a','c035c035-0000-0000-0000-000000000001','A',true,14.5995,120.9842,200,150,true),
  ('c035c035-0000-0000-0000-0000000b000b','c035c035-0000-0000-0000-000000000002','B',true,14.5995,120.9842,200,150,true);

-- studio_staff with explicit ids so instructors can link (auth_instructor_id
-- joins instructors.staff_id -> studio_staff where user_id = auth.uid()).
insert into studio_staff (id, studio_id, user_id, email, role, status) values
  ('c035c035-0000-0000-0000-00000000550a','c035c035-0000-0000-0000-000000000001','c035c035-0000-0000-0000-0000000000a1','c035-o1@example.com','owner','active'),
  ('c035c035-0000-0000-0000-000000005501','c035c035-0000-0000-0000-000000000001','c035c035-0000-0000-0000-0000000000a2','c035-i1@example.com','instructor','active'),
  ('c035c035-0000-0000-0000-000000005502','c035c035-0000-0000-0000-000000000001','c035c035-0000-0000-0000-0000000000a3','c035-i2@example.com','instructor','active'),
  ('c035c035-0000-0000-0000-0000000055b1','c035c035-0000-0000-0000-000000000002','c035c035-0000-0000-0000-0000000000b1','c035-ib@example.com','instructor','active');

insert into instructors (id, studio_id, display_name, staff_id, status) values
  ('c035c035-0000-0000-0000-0000000e0001','c035c035-0000-0000-0000-000000000001','Ins One','c035c035-0000-0000-0000-000000005501','active'),
  ('c035c035-0000-0000-0000-0000000e0002','c035c035-0000-0000-0000-000000000001','Ins Two','c035c035-0000-0000-0000-000000005502','active'),
  ('c035c035-0000-0000-0000-0000000e00b1','c035c035-0000-0000-0000-000000000002','Ins Bee','c035c035-0000-0000-0000-0000000055b1','active');

insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('c035c035-0000-0000-0000-0000000cc001','c035c035-0000-0000-0000-000000000001','Mat',50,10),
  ('c035c035-0000-0000-0000-0000000cc002','c035c035-0000-0000-0000-000000000002','Mat',50,10);

insert into members (id, studio_id, user_id, first_name, last_name, email, waiver_signed_at) values
  ('c035c035-0000-0000-0000-0000000d0a01','c035c035-0000-0000-0000-000000000001','c035c035-0000-0000-0000-0000000000a4','Mem','One','c035-m1@example.com',now()),
  ('c035c035-0000-0000-0000-0000000d0a02','c035c035-0000-0000-0000-000000000001','c035c035-0000-0000-0000-0000000000a5','Mem','Two','c035-m2@example.com',now()),
  ('c035c035-0000-0000-0000-0000000d0b03','c035c035-0000-0000-0000-000000000002','c035c035-0000-0000-0000-0000000000b2','Mem','Three','c035-m3@example.com',now());

-- B requires a re-signed waiver M3 has not signed → stale → refused at the door.
insert into waiver_versions (studio_id, format, body, content_hash, requires_resign) values
  ('c035c035-0000-0000-0000-000000000002','text','Sign here','c035-hash-b', true);

-- OCC1 window-open (taught by I1); OCC2 window-closed (+180); OCCB1 window-open (I_B).
insert into class_occurrences (id, studio_id, location_id, class_type_id, instructor_id, name,
                               starts_at, ends_at, capacity, booked_count, status) values
  ('c035c035-0000-0000-0000-00000000c101','c035c035-0000-0000-0000-000000000001','c035c035-0000-0000-0000-0000000a000a','c035c035-0000-0000-0000-0000000cc001','c035c035-0000-0000-0000-0000000e0001','OCC1', now()+interval '10 min', now()+interval '60 min',10,1,'scheduled'),
  ('c035c035-0000-0000-0000-00000000c102','c035c035-0000-0000-0000-000000000001','c035c035-0000-0000-0000-0000000a000a','c035c035-0000-0000-0000-0000000cc001','c035c035-0000-0000-0000-0000000e0001','OCC2', now()+interval '180 min', now()+interval '230 min',10,1,'scheduled'),
  ('c035c035-0000-0000-0000-00000000c1b1','c035c035-0000-0000-0000-000000000002','c035c035-0000-0000-0000-0000000b000b','c035c035-0000-0000-0000-0000000cc002','c035c035-0000-0000-0000-0000000e00b1','OCCB1', now()+interval '10 min', now()+interval '60 min',10,1,'scheduled');

insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at) values
  ('c035c035-0000-0000-0000-0000000b0101','c035c035-0000-0000-0000-000000000001','c035c035-0000-0000-0000-00000000c101','c035c035-0000-0000-0000-0000000d0a01','booked','member','drop_in', now()-interval '1 h'),  -- M1 in OCC1
  ('c035c035-0000-0000-0000-0000000b0102','c035c035-0000-0000-0000-000000000001','c035c035-0000-0000-0000-00000000c102','c035c035-0000-0000-0000-0000000d0a02','booked','member','drop_in', now()-interval '1 h'),  -- M2 in OCC2
  ('c035c035-0000-0000-0000-0000000b01b1','c035c035-0000-0000-0000-000000000002','c035c035-0000-0000-0000-00000000c1b1','c035c035-0000-0000-0000-0000000d0b03','booked','member','drop_in', now()-interval '1 h');  -- M3 in OCCB1

-- =============================================================================
-- §3. The printed slug.
-- =============================================================================
select expect_eq('slug is null until minted (opt-in by existence)',
  (select checkin_slug from studios where id = 'c035c035-0000-0000-0000-000000000001'), null);

select set_config('t.s1', c35_slug('c035c035-0000-0000-0000-0000000000a1','c035c035-0000-0000-0000-000000000001', false), false);
select expect_num('ensure_checkin_slug mints 32 hex chars', length(current_setting('t.s1'))::bigint, 32);
select set_config('t.s2', c35_slug('c035c035-0000-0000-0000-0000000000a1','c035c035-0000-0000-0000-000000000001', false), false);
select expect_eq('ensure_checkin_slug is idempotent — same slug the second time', current_setting('t.s2'), current_setting('t.s1'));

-- B's slug set directly (minting is manager-up; B's only login here is an
-- instructor), to prove "a different studio" resolves to B (not A).
update studios set checkin_slug = 'c035bbbbc035bbbbc035bbbbc035bbbb'
  where id = 'c035c035-0000-0000-0000-000000000002';

select expect_eq('checkin_slug_studio resolves A''s slug to A',
  c35_css('c035c035-0000-0000-0000-0000000000a4', current_setting('t.s1')), 'c035c035-0000-0000-0000-000000000001');
select expect_eq('a slug for another studio resolves to THAT studio (page shows "different studio")',
  c35_css('c035c035-0000-0000-0000-0000000000a4', 'c035bbbbc035bbbbc035bbbbc035bbbb'), 'c035c035-0000-0000-0000-000000000002');
select expect_eq('a garbage slug resolves to nothing',
  c35_css('c035c035-0000-0000-0000-0000000000a4', 'not-a-real-slug'), 'NONE');

-- Re-mint: a fresh slug, and the OLD one now resolves to nothing.
select set_config('t.s3', c35_slug('c035c035-0000-0000-0000-0000000000a1','c035c035-0000-0000-0000-000000000001', true), false);
select expect_true('re-mint changes the slug', current_setting('t.s3') <> current_setting('t.s1'));
select expect_eq('the old slug resolves to nothing after a re-mint',
  c35_css('c035c035-0000-0000-0000-0000000000a4', current_setting('t.s1')), 'NONE');
select expect_eq('the new slug resolves to A',
  c35_css('c035c035-0000-0000-0000-0000000000a4', current_setting('t.s3')), 'c035c035-0000-0000-0000-000000000001');

-- A non-manager cannot mint or re-mint.
select expect_eq('a non-manager cannot mint the slug (PT403)',
  c35_slug('c035c035-0000-0000-0000-0000000000a4','c035c035-0000-0000-0000-000000000001', false), 'ERR:PT403');
select expect_eq('a non-manager cannot re-mint the slug (PT403)',
  c35_slug('c035c035-0000-0000-0000-0000000000a4','c035c035-0000-0000-0000-000000000001', true), 'ERR:PT403');

-- =============================================================================
-- §4. instructor_resolve_code.
-- =============================================================================
select expect_eq('the class''s own instructor, inside the window, resolves the booked member',
  c35_irc('c035c035-0000-0000-0000-0000000000a2','c035c035-0000-0000-0000-00000000c101', c35_code('c035c035-0000-0000-0000-0000000d0a01')),
  'c035c035-0000-0000-0000-0000000d0a01');

select expect_eq('a manager resolves it too',
  c35_irc('c035c035-0000-0000-0000-0000000000a1','c035c035-0000-0000-0000-00000000c101', c35_code('c035c035-0000-0000-0000-0000000d0a01')),
  'c035c035-0000-0000-0000-0000000d0a01');

select expect_eq('a member not booked in THAT occurrence is not found (M2''s code against OCC1)',
  c35_irc('c035c035-0000-0000-0000-0000000000a2','c035c035-0000-0000-0000-00000000c101', c35_code('c035c035-0000-0000-0000-0000000d0a02')),
  'NONE');

select expect_eq('another instructor (not this class''s) is refused PT403',
  c35_irc('c035c035-0000-0000-0000-0000000000a3','c035c035-0000-0000-0000-00000000c101', c35_code('c035c035-0000-0000-0000-0000000d0a01')),
  'ERR:PT403');

select expect_eq('the window being closed refuses PT409 (OCC2 is +180 min)',
  c35_irc('c035c035-0000-0000-0000-0000000000a2','c035c035-0000-0000-0000-00000000c102', c35_code('c035c035-0000-0000-0000-0000000d0a02')),
  'ERR:PT409');

-- The check-in the roster writes carries method 'instructor'.
select expect_eq('the instructor checks M1 in',
  c35_ins('c035c035-0000-0000-0000-0000000000a2','c035c035-0000-0000-0000-000000000001','c035c035-0000-0000-0000-0000000b0101','c035c035-0000-0000-0000-0000000d0a01','c035c035-0000-0000-0000-00000000c101'),
  'OK');
select expect_eq('the resulting check-in has method ''instructor''',
  (select method::text from check_ins where booking_id = 'c035c035-0000-0000-0000-0000000b0101'), 'instructor');

-- The waiver gate fires at the instructor door too (B requires a re-sign M3 lacks).
select expect_eq('instructor_resolve_code still finds M3 (identity, not the waiver)',
  c35_irc('c035c035-0000-0000-0000-0000000000b1','c035c035-0000-0000-0000-00000000c1b1', c35_code('c035c035-0000-0000-0000-0000000d0b03')),
  'c035c035-0000-0000-0000-0000000d0b03');
select expect_eq('but checking M3 in is refused PT422 — the waiver gate at the door',
  c35_ins('c035c035-0000-0000-0000-0000000000b1','c035c035-0000-0000-0000-000000000002','c035c035-0000-0000-0000-0000000b01b1','c035c035-0000-0000-0000-0000000d0b03','c035c035-0000-0000-0000-00000000c1b1'),
  'ERR:PT422');

-- =============================================================================
-- The slug page reuses self_check_in — no NEW check-in writer was added.
-- =============================================================================
select expect_true('self_check_in (the reused writer) is authenticated, not anon',
  (select has_function_privilege('authenticated', p.oid, 'execute') and not has_function_privilege('anon', p.oid, 'execute')
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'self_check_in'));

-- =============================================================================
-- Anon surface — EXACTLY THIRTEEN, named; the four new functions are NOT anon.
-- =============================================================================
select expect_num('the thirteen pre-login surfaces are all anon-executable',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname in ('accept_studio_invite','claim_instructor_account','claim_member_account',
        'instructor_invite_preview','member_invite_preview','public_schedule',
        'stripe_platform_webhook','stripe_webhook','studio_by_slug','studio_invite_preview',
        'calendar_feed','xendit_webhook','unsubscribe_marketing'))::bigint, 13);

select expect_num('the anon surface is EXACTLY thirteen (suite helpers excluded)',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not like 'expect%' and p.proname not like 'c35\_%')::bigint, 13);

select expect_num('the four new functions are NOT anon',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname in ('ensure_checkin_slug','remint_checkin_slug','checkin_slug_studio','instructor_resolve_code'))::bigint, 0);

select 'checkin_qr_test: all assertions passed' as result;
