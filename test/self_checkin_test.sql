-- =============================================================================
-- Member self check-in at the door — Decision 35, Part A (migrations 169/170)
-- =============================================================================
-- UUID space 5e1c, checked free. Run after `supabase db reset`.
--
-- self_check_in: own booking only (PT403 otherwise); window closed refused; the
-- geofence with a CAPPED reported accuracy (too_far / low_accuracy); no location
-- supplied -> no_location; a studio without coordinates -> studio_has_no_location;
-- a stale/missing waiver -> PT422 at self AND at the desk (the trigger); trust-
-- based (require off) checks in with no coordinates; idempotent; method 'self'
-- with the distance stored, never the coordinates.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_eq(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected true', label; end if;
end $$;

-- Run self_check_in as a member and normalise the outcome to one token:
-- 'OK' | 'ALREADY' | a soft reason | 'ERR:<sqlstate>'.
create or replace function sci(p_uid text, p_booking uuid,
    p_lat double precision, p_lng double precision, p_acc double precision)
returns text language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claim.sub', p_uid, true);
  set local role authenticated;
  begin
    r := self_check_in(p_booking, p_lat, p_lng, p_acc);
    if coalesce((r->>'ok')::boolean, false) then
      return case when coalesce((r->>'already')::boolean, false) then 'ALREADY' else 'OK' end;
    end if;
    return coalesce(r->>'reason', '?');
  exception when others then return 'ERR:'||sqlstate; end;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('5e1c5e1c-0000-0000-0000-0000000000a1'),  -- M1 (studio A, acts as self)
  ('5e1c5e1c-0000-0000-0000-0000000000a2'),  -- M2 (studio A, attacker)
  ('5e1c5e1c-0000-0000-0000-0000000000a6'),  -- M6 (studio A, accuracy-honoured)
  ('5e1c5e1c-0000-0000-0000-0000000000b5'),  -- M5 (studio B, trust-based)
  ('5e1c5e1c-0000-0000-0000-0000000000c4'),  -- M4 (studio C, no coords)
  ('5e1c5e1c-0000-0000-0000-0000000000d3');  -- M3 (studio D, stale waiver)
insert into profiles (id, email) select id, id::text||'@example.com' from auth.users where id::text like '5e1c%';

insert into studios (id, name, slug, timezone, currency, status) values
  ('5e1c5e1c-0000-0000-0000-000000000001','SC A','5e1c-a','Asia/Manila','PHP','active'),
  ('5e1c5e1c-0000-0000-0000-000000000002','SC B','5e1c-b','Asia/Manila','PHP','active'),
  ('5e1c5e1c-0000-0000-0000-000000000003','SC C','5e1c-c','Asia/Manila','PHP','active'),
  ('5e1c5e1c-0000-0000-0000-000000000004','SC D','5e1c-d','Asia/Manila','PHP','active');
-- Default settings everywhere (require_waiver defaults true). A/B/C have no
-- waiver_versions, so their members pass the door via "nothing to sign".
insert into studio_settings (studio_id) values
  ('5e1c5e1c-0000-0000-0000-000000000001'),
  ('5e1c5e1c-0000-0000-0000-000000000002'),
  ('5e1c5e1c-0000-0000-0000-000000000003'),
  ('5e1c5e1c-0000-0000-0000-000000000004');

-- Locations: A geofenced (coords, radius 200, cap 150, require on); B trust-
-- based (require off, no coords); C require on with NO coords; D require off.
insert into locations (id, studio_id, name, is_primary, latitude, longitude,
                       self_checkin_radius_m, self_checkin_accuracy_cap_m, self_checkin_requires_location) values
  ('5e1c5e1c-0000-0000-0000-0000000a000a','5e1c5e1c-0000-0000-0000-000000000001','A', true, 14.5995, 120.9842, 200, 150, true),
  ('5e1c5e1c-0000-0000-0000-0000000b000b','5e1c5e1c-0000-0000-0000-000000000002','B', true, null,    null,     200, 150, false),
  ('5e1c5e1c-0000-0000-0000-0000000c000c','5e1c5e1c-0000-0000-0000-000000000003','C', true, null,    null,     200, 150, true),
  ('5e1c5e1c-0000-0000-0000-0000000d000d','5e1c5e1c-0000-0000-0000-000000000004','D', true, 14.5995, 120.9842, 200, 150, true);

insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('5e1c5e1c-0000-0000-0000-0000000cc001','5e1c5e1c-0000-0000-0000-000000000001','Mat',50,10),
  ('5e1c5e1c-0000-0000-0000-0000000cc002','5e1c5e1c-0000-0000-0000-000000000002','Mat',50,10),
  ('5e1c5e1c-0000-0000-0000-0000000cc003','5e1c5e1c-0000-0000-0000-000000000003','Mat',50,10),
  ('5e1c5e1c-0000-0000-0000-0000000cc004','5e1c5e1c-0000-0000-0000-000000000004','Mat',50,10);

insert into members (id, studio_id, user_id, first_name, last_name, email, waiver_signed_at) values
  ('5e1c5e1c-0000-0000-0000-0000000d0a01','5e1c5e1c-0000-0000-0000-000000000001','5e1c5e1c-0000-0000-0000-0000000000a1','M','One','5e1c-m1@example.com',now()),
  ('5e1c5e1c-0000-0000-0000-0000000d0a02','5e1c5e1c-0000-0000-0000-000000000001','5e1c5e1c-0000-0000-0000-0000000000a2','M','Two','5e1c-m2@example.com',now()),
  ('5e1c5e1c-0000-0000-0000-0000000d0a06','5e1c5e1c-0000-0000-0000-000000000001','5e1c5e1c-0000-0000-0000-0000000000a6','M','Six','5e1c-m6@example.com',now()),
  ('5e1c5e1c-0000-0000-0000-0000000d0b05','5e1c5e1c-0000-0000-0000-000000000002','5e1c5e1c-0000-0000-0000-0000000000b5','M','Five','5e1c-m5@example.com',now()),
  ('5e1c5e1c-0000-0000-0000-0000000d0c04','5e1c5e1c-0000-0000-0000-000000000003','5e1c5e1c-0000-0000-0000-0000000000c4','M','Four','5e1c-m4@example.com',now()),
  ('5e1c5e1c-0000-0000-0000-0000000d0d03','5e1c5e1c-0000-0000-0000-000000000004','5e1c5e1c-0000-0000-0000-0000000000d3','M','Three','5e1c-m3@example.com',now());

-- Studio D publishes a requires_resign waiver; M3 has a bare timestamp but no
-- signature on the current version -> stale -> refused at every door.
insert into waiver_versions (studio_id, format, body, content_hash, requires_resign) values
  ('5e1c5e1c-0000-0000-0000-000000000004','text','Sign here','hash-d1', true);

-- Occurrences: in-window ones start +10 min (checkin opens 60 before, closes 30
-- after -> now is inside); OA2 starts +180 (window not open yet).
insert into class_occurrences (id, studio_id, location_id, class_type_id, name,
                               starts_at, ends_at, capacity, booked_count, status) values
  ('5e1c5e1c-0000-0000-0000-00000000a001','5e1c5e1c-0000-0000-0000-000000000001','5e1c5e1c-0000-0000-0000-0000000a000a','5e1c5e1c-0000-0000-0000-0000000cc001','OA1', now()+interval '10 min', now()+interval '60 min',10,1,'scheduled'),
  ('5e1c5e1c-0000-0000-0000-00000000a002','5e1c5e1c-0000-0000-0000-000000000001','5e1c5e1c-0000-0000-0000-0000000a000a','5e1c5e1c-0000-0000-0000-0000000cc001','OA2', now()+interval '180 min', now()+interval '230 min',10,1,'scheduled'),
  ('5e1c5e1c-0000-0000-0000-00000000a006','5e1c5e1c-0000-0000-0000-000000000001','5e1c5e1c-0000-0000-0000-0000000a000a','5e1c5e1c-0000-0000-0000-0000000cc001','OA6', now()+interval '10 min', now()+interval '60 min',10,1,'scheduled'),
  ('5e1c5e1c-0000-0000-0000-00000000b001','5e1c5e1c-0000-0000-0000-000000000002','5e1c5e1c-0000-0000-0000-0000000b000b','5e1c5e1c-0000-0000-0000-0000000cc002','OB1', now()+interval '10 min', now()+interval '60 min',10,1,'scheduled'),
  ('5e1c5e1c-0000-0000-0000-00000000c001','5e1c5e1c-0000-0000-0000-000000000003','5e1c5e1c-0000-0000-0000-0000000c000c','5e1c5e1c-0000-0000-0000-0000000cc003','OC1', now()+interval '10 min', now()+interval '60 min',10,1,'scheduled'),
  ('5e1c5e1c-0000-0000-0000-00000000d001','5e1c5e1c-0000-0000-0000-000000000004','5e1c5e1c-0000-0000-0000-0000000d000d','5e1c5e1c-0000-0000-0000-0000000cc004','OD1', now()+interval '10 min', now()+interval '60 min',10,1,'scheduled');

insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at) values
  ('5e1c5e1c-0000-0000-0000-0000000b0a01','5e1c5e1c-0000-0000-0000-000000000001','5e1c5e1c-0000-0000-0000-00000000a001','5e1c5e1c-0000-0000-0000-0000000d0a01','booked','member','drop_in', now()-interval '1 h'),  -- BA1 (M1)
  ('5e1c5e1c-0000-0000-0000-0000000b0a02','5e1c5e1c-0000-0000-0000-000000000001','5e1c5e1c-0000-0000-0000-00000000a002','5e1c5e1c-0000-0000-0000-0000000d0a01','booked','member','drop_in', now()-interval '1 h'),  -- BA2 (M1, out-window)
  ('5e1c5e1c-0000-0000-0000-0000000b0a06','5e1c5e1c-0000-0000-0000-000000000001','5e1c5e1c-0000-0000-0000-00000000a006','5e1c5e1c-0000-0000-0000-0000000d0a06','booked','member','drop_in', now()-interval '1 h'),  -- BA6 (M6)
  ('5e1c5e1c-0000-0000-0000-0000000b0b05','5e1c5e1c-0000-0000-0000-000000000002','5e1c5e1c-0000-0000-0000-00000000b001','5e1c5e1c-0000-0000-0000-0000000d0b05','booked','member','drop_in', now()-interval '1 h'),  -- BB1 (M5)
  ('5e1c5e1c-0000-0000-0000-0000000b0c04','5e1c5e1c-0000-0000-0000-000000000003','5e1c5e1c-0000-0000-0000-00000000c001','5e1c5e1c-0000-0000-0000-0000000d0c04','booked','member','drop_in', now()-interval '1 h'),  -- BC1 (M4)
  ('5e1c5e1c-0000-0000-0000-0000000b0d03','5e1c5e1c-0000-0000-0000-000000000004','5e1c5e1c-0000-0000-0000-00000000d001','5e1c5e1c-0000-0000-0000-0000000d0d03','booked','member','drop_in', now()-interval '1 h');  -- BD1 (M3)

-- --- Geofence arithmetic sanity (haversine along a meridian) ------------------
select expect_true('~111 m for +0.001 deg latitude',
  earth_distance_m(14.5995,120.9842, 14.6005,120.9842) between 105 and 118);
select expect_true('~334 m for +0.003 deg latitude',
  earth_distance_m(14.5995,120.9842, 14.6025,120.9842) between 320 and 348);

-- --- PT403: another member's booking (before BA1 is checked in) ---------------
select expect_eq('a member cannot self check-in another member''s booking (PT403)',
  sci('5e1c5e1c-0000-0000-0000-0000000000a2','5e1c5e1c-0000-0000-0000-0000000b0a01', 14.6005,120.9842, 10),
  'ERR:PT403');

-- --- Window closed (BA2 starts +180) -----------------------------------------
select expect_eq('a class outside the check-in window is refused',
  sci('5e1c5e1c-0000-0000-0000-0000000000a1','5e1c5e1c-0000-0000-0000-0000000b0a02', 14.6005,120.9842, 10),
  'window_closed');

-- --- Geofence refusals on BA1 (no write) --------------------------------------
select expect_eq('no location supplied -> no_location',
  sci('5e1c5e1c-0000-0000-0000-0000000000a1','5e1c5e1c-0000-0000-0000-0000000b0a01', null,null,null),
  'no_location');
select expect_eq('~334 m with accuracy 0 -> too_far',
  sci('5e1c5e1c-0000-0000-0000-0000000000a1','5e1c5e1c-0000-0000-0000-0000000b0a01', 14.6025,120.9842, 0),
  'too_far');
-- The cap is the whole point: accuracy 4000 at ~56 m is refused, not passed.
select expect_eq('accuracy 4000 at distance ~56 m -> low_accuracy, not a pass',
  sci('5e1c5e1c-0000-0000-0000-0000000000a1','5e1c5e1c-0000-0000-0000-0000000b0a01', 14.6000,120.9842, 4000),
  'low_accuracy');
-- BA1 is still not checked in after three refusals.
select expect_true('the refusals wrote nothing',
  not exists (select 1 from check_ins where booking_id = '5e1c5e1c-0000-0000-0000-0000000b0a01'));

-- --- Success inside the radius, then idempotent -------------------------------
select expect_eq('inside the radius (~111 m, acc 20) -> checked in',
  sci('5e1c5e1c-0000-0000-0000-0000000000a1','5e1c5e1c-0000-0000-0000-0000000b0a01', 14.6005,120.9842, 20),
  'OK');
select expect_eq('a second call for the same booking is idempotent',
  sci('5e1c5e1c-0000-0000-0000-0000000000a1','5e1c5e1c-0000-0000-0000-0000000b0a01', 14.6005,120.9842, 20),
  'ALREADY');
select expect_eq('the row is method self with the distance stored (~111 m)',
  (select method::text||':'||distance_m::text||':'||accuracy_m::text from check_ins
    where booking_id = '5e1c5e1c-0000-0000-0000-0000000b0a01'),
  'self:111:20');
select expect_true('the booking is now attended',
  (select status from bookings where id='5e1c5e1c-0000-0000-0000-0000000b0a01') = 'attended');

-- --- Accuracy honoured: ~334 m with accuracy 150 (cap) passes -----------------
select expect_eq('~334 m with accuracy 150 -> checked in (accuracy widened the radius)',
  sci('5e1c5e1c-0000-0000-0000-0000000000a6','5e1c5e1c-0000-0000-0000-0000000b0a06', 14.6025,120.9842, 150),
  'OK');

-- --- Trust-based (studio B, require off): no coordinates still checks in ------
select expect_eq('require-location off -> checks in with no coordinates',
  sci('5e1c5e1c-0000-0000-0000-0000000000b5','5e1c5e1c-0000-0000-0000-0000000b0b05', null,null,null),
  'OK');
select expect_true('the trust-based row has no distance and no coordinates were stored',
  (select distance_m is null from check_ins where booking_id='5e1c5e1c-0000-0000-0000-0000000b0b05'));

-- --- Studio C: require on but no coordinates set -> studio_has_no_location ----
select expect_eq('a studio that has not set coordinates -> studio_has_no_location',
  sci('5e1c5e1c-0000-0000-0000-0000000000c4','5e1c5e1c-0000-0000-0000-0000000b0c04', 14.6005,120.9842, 10),
  'studio_has_no_location');

-- --- Waiver at the door (studio D): stale -> PT422 at self AND the desk -------
select expect_eq('a stale waiver is refused at self check-in (PT422)',
  sci('5e1c5e1c-0000-0000-0000-0000000000d3','5e1c5e1c-0000-0000-0000-0000000b0d03', 14.6005,120.9842, 10),
  'ERR:PT422');
-- The desk door: a direct check_ins insert (as staff) hits the same trigger.
do $$ begin
  insert into check_ins (studio_id, booking_id, member_id, occurrence_id, method)
  values ('5e1c5e1c-0000-0000-0000-000000000004','5e1c5e1c-0000-0000-0000-0000000b0d03',
          '5e1c5e1c-0000-0000-0000-0000000d0d03','5e1c5e1c-0000-0000-0000-00000000d001','staff');
  raise exception 'FAIL  a stale-waiver member was checked in at the desk';
exception when sqlstate 'PT422' then
  raise notice 'PASS  a stale waiver is refused at the desk too (PT422 from the trigger)';
end $$;

-- --- The all_off / no-version studio is unaffected: a member at a studio with
--     require_waiver on (default) but NO published version passes the door. -----
select expect_true('a studio with no published waiver version does not gate the door',
  member_waiver_current('5e1c5e1c-0000-0000-0000-0000000d0a01','5e1c5e1c-0000-0000-0000-000000000001'));

-- --- TEETH: the checkin_health exemption is NARROW ---------------------------
-- A member session can never hold studiior.checkin_health (a client cannot
-- set_config), but if one ever leaked, the exemption must still let through
-- ONLY the four health columns. A non-health write while the flag is set is
-- refused. The successful self_check_in path above is the positive control:
-- the real cascade writes only health columns and passes.
do $$
begin
  perform set_config('request.jwt.claim.sub','5e1c5e1c-0000-0000-0000-0000000000a1', true);
  set local role authenticated;
  perform set_config('studiior.checkin_health','1', true);
  update members set preferred_name = 'hacked'
    where id = '5e1c5e1c-0000-0000-0000-0000000d0a01';
  reset role;
  raise exception 'FAIL  checkin_health let a member edit a non-health column';
exception
  when sqlstate 'PT403' then
    reset role;
    raise notice 'PASS  checkin_health exempts only the health columns (PT403 on a non-health write)';
end $$;
-- Positive control: a health-column write under the flag still passes.
do $$
begin
  perform set_config('request.jwt.claim.sub','5e1c5e1c-0000-0000-0000-0000000000a1', true);
  set local role authenticated;
  perform set_config('studiior.checkin_health','1', true);
  update members set health_band = 'drifting'
    where id = '5e1c5e1c-0000-0000-0000-0000000d0a01';
  reset role;
  raise notice 'PASS  checkin_health still lets the health cascade through';
exception
  when others then
    reset role;
    raise exception 'FAIL  checkin_health blocked a health-column write (%)', sqlstate;
end $$;

do $$ begin raise notice 'self_checkin_test: all assertions passed'; end $$;
