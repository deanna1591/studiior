-- =============================================================================
-- Decision 105 — members_list: the staff Members reader (search, filters,
-- counts, attention signals). UUID space d105, checked free. Run after
-- `supabase db reset`.
-- =============================================================================
-- One Manila studio with an owner and a front desk. Members cover every filter:
-- active, lead, an unpaid future drop-in, a free-first booked comp (with the
-- reservation fee due), a plan member who still owes a waiver, a phone-sharing
-- duplicate pair, and a deleted-and-merged member. A plain member is refused.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'BAD  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual then raise notice 'PASS  %', label;
  else raise exception 'BAD  %  expected true, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_false(label text, actual boolean)
returns void language plpgsql as $$
begin
  if not actual then raise notice 'PASS  %', label;
  else raise exception 'BAD  %  expected false, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_raises(label text, stmt text, want_sqlstate text)
returns void language plpgsql as $$
begin
  execute stmt; raise exception 'BAD  %  expected % but nothing was raised', label, want_sqlstate;
exception when others then
  if sqlstate = want_sqlstate then raise notice 'PASS  %  (got %)', label, sqlstate;
  elsif sqlstate = 'P0001' and sqlerrm like 'BAD%' then raise;
  else raise exception 'BAD  %  expected %, got % (%)', label, want_sqlstate, sqlstate, sqlerrm; end if;
end $$;

-- A small reader helper: does a members_list call hold a row for member X with
-- a boolean flag set? Runs as whoever the session is.
create or replace function ml_flag(studio uuid, member uuid, flag text)
returns boolean language sql stable as $$
  select exists (
    select 1 from jsonb_array_elements(members_list(studio, '', 'all', 'attention', 1) -> 'rows') r
     where (r->>'id')::uuid = member and (r->>flag)::boolean
  );
$$;
create or replace function ml_count(studio uuid, q text, filt text)
returns bigint language sql stable as $$
  select jsonb_array_length(members_list(studio, q, filt, 'attention', 1) -> 'rows')::bigint;
$$;
create or replace function ml_countkey(studio uuid, key text)
returns bigint language sql stable as $$
  select (members_list(studio, '', 'all', 'attention', 1) -> 'counts' ->> key)::bigint;
$$;

-- --- Fixtures ----------------------------------------------------------------
insert into studios (id, name, slug, timezone, currency, country, status) values
  ('d105d105-0000-0000-0000-0000000000a1','Members A','d105-ma','Asia/Manila','PHP','PH','active');
insert into studio_settings
  (studio_id, require_waiver, booking_window_days, cancellation_cutoff_minutes,
   free_first_class_enabled, free_first_reservation_from, free_first_reservation_fee_cents)
values
  ('d105d105-0000-0000-0000-0000000000a1', true, 400, 60,
   true, (now() at time zone 'Asia/Manila')::date, 50000);
insert into locations (id, studio_id, name, is_primary) values
  ('d105d105-0000-0000-0000-0000000000aa','d105d105-0000-0000-0000-0000000000a1','Main',true);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('d105d105-0000-0000-0000-0000000c7a01','d105d105-0000-0000-0000-0000000000a1','Reformer',50,10);
-- One future occurrence holds the comp, credit and unpaid drop-in bookings.
insert into class_occurrences (id, studio_id, location_id, class_type_id, name, capacity, starts_at, ends_at, status) values
  ('d105d105-0000-0000-0000-00000000c001','d105d105-0000-0000-0000-0000000000a1','d105d105-0000-0000-0000-0000000000aa','d105d105-0000-0000-0000-0000000c7a01','Class',10,
    now() + interval '2 days', now() + interval '2 days' + interval '50 min','scheduled');
-- A waiver version (unsigned members with a future booking then need it).
insert into waiver_versions (id, studio_id, format, body, content_hash) values
  ('d105d105-0000-0000-0000-0000000fa001','d105d105-0000-0000-0000-0000000000a1','text','Please sign.','hash-105');

-- Staff logins.
insert into auth.users (id) values
  ('d105d105-0000-0000-0000-0000000000f1'),  -- owner
  ('d105d105-0000-0000-0000-0000000000f2'),  -- front desk
  ('d105d105-0000-0000-0000-0000000000f3');  -- a plain member login
insert into profiles (id, email) values
  ('d105d105-0000-0000-0000-0000000000f1','d105-owner@example.com'),
  ('d105d105-0000-0000-0000-0000000000f2','d105-desk@example.com'),
  ('d105d105-0000-0000-0000-0000000000f3','d105-member@example.com');
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('d105d105-0000-0000-0000-00000005f001','d105d105-0000-0000-0000-0000000000a1','d105d105-0000-0000-0000-0000000000f1','d105-owner@example.com','owner'),
  ('d105d105-0000-0000-0000-00000005f002','d105d105-0000-0000-0000-0000000000a1','d105d105-0000-0000-0000-0000000000f2','d105-desk@example.com','front_desk');

-- A pack plan for the active members.
insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, validity_days, visibility, status) values
  ('d105d105-0000-0000-0000-0000000a1001','d105d105-0000-0000-0000-0000000000a1','5-Pack','class_pack',500000,'PHP',5,60,'public','active');

-- Members. M1/M2 share a phone (duplicate). M3 is a free-first booked comp with
-- the fee due. M4 is a plan member who still owes a waiver. M5 is a lead. M6 is
-- an unpaid future drop-in. M7 is deleted, merged into M1. Waivers are signed
-- for everyone but M4, so only M4 reads needs_waiver.
insert into members (id, studio_id, first_name, last_name, email, phone, status, waiver_signed_at) values
  ('d105d105-0000-0000-0000-0000000e0001','d105d105-0000-0000-0000-0000000000a1','Ana','Reyes','ana@example.com','+639171234567','active', now()),
  ('d105d105-0000-0000-0000-0000000e0002','d105d105-0000-0000-0000-0000000000a1','Bea','Cruz','bea@example.com','+639171234567','active', now()),
  ('d105d105-0000-0000-0000-0000000e0003','d105d105-0000-0000-0000-0000000000a1','Cora','Diaz','cora@example.com','+639180000001','lead', now()),
  ('d105d105-0000-0000-0000-0000000e0004','d105d105-0000-0000-0000-0000000000a1','Dina','Lim','dina@example.com','+639180000002','active', null),
  ('d105d105-0000-0000-0000-0000000e0005','d105d105-0000-0000-0000-0000000000a1','Edo','Reyes','edo@example.com', null,'lead', now()),
  ('d105d105-0000-0000-0000-0000000e0006','d105d105-0000-0000-0000-0000000000a1','Fay','Tan','fay@example.com','+639180000003','active', now()),
  ('d105d105-0000-0000-0000-0000000e0007','d105d105-0000-0000-0000-0000000000a1','Gio','Deleted','gio@example.com','+639180000004','inactive', now());
update members set deleted_at = now(), merged_into = 'd105d105-0000-0000-0000-0000000e0001'
  where id = 'd105d105-0000-0000-0000-0000000e0007';

-- Active memberships for M1, M2, M4 (pack, credits).
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on, expires_on, credits_remaining) values
  ('d105d105-0000-0000-0000-00000000cd01','d105d105-0000-0000-0000-0000000000a1','d105d105-0000-0000-0000-0000000e0001','d105d105-0000-0000-0000-0000000a1001','active',500000,'PHP',(now() at time zone 'Asia/Manila')::date,(now() at time zone 'Asia/Manila')::date + 60, 5),
  ('d105d105-0000-0000-0000-00000000cd02','d105d105-0000-0000-0000-0000000000a1','d105d105-0000-0000-0000-0000000e0002','d105d105-0000-0000-0000-0000000a1001','active',500000,'PHP',(now() at time zone 'Asia/Manila')::date,(now() at time zone 'Asia/Manila')::date + 60, 5),
  ('d105d105-0000-0000-0000-00000000cd04','d105d105-0000-0000-0000-0000000000a1','d105d105-0000-0000-0000-0000000e0004','d105d105-0000-0000-0000-0000000a1001','active',500000,'PHP',(now() at time zone 'Asia/Manila')::date,(now() at time zone 'Asia/Manila')::date + 60, 5);

-- M3: a booked free-first comp seat (host-null guest_pass) -> free_only, fee due.
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source) values
  ('d105d105-0000-0000-0000-0000000bb003','d105d105-0000-0000-0000-0000000000a1','d105d105-0000-0000-0000-00000000c001','d105d105-0000-0000-0000-0000000e0003','booked','comp');
insert into guest_passes (id, studio_id, host_member_id, guest_member_id, guest_email, occurrence_id, guest_booking_id, status) values
  ('d105d105-0000-0000-0000-0000000ad003','d105d105-0000-0000-0000-0000000000a1', null,'d105d105-0000-0000-0000-0000000e0003','cora@example.com','d105d105-0000-0000-0000-00000000c001','d105d105-0000-0000-0000-0000000bb003','confirmed');
-- M4: a plan (credit) booking on the future class -> needs_waiver (unsigned).
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source, membership_id) values
  ('d105d105-0000-0000-0000-0000000bb004','d105d105-0000-0000-0000-0000000000a1','d105d105-0000-0000-0000-00000000c001','d105d105-0000-0000-0000-0000000e0004','booked','class_pack','d105d105-0000-0000-0000-00000000cd04');
-- M6: an unpaid future drop-in (no succeeded payment) -> has_unpaid_booking.
insert into bookings (id, studio_id, occurrence_id, member_id, status, payment_source) values
  ('d105d105-0000-0000-0000-0000000bb006','d105d105-0000-0000-0000-0000000000a1','d105d105-0000-0000-0000-00000000c001','d105d105-0000-0000-0000-0000000e0006','booked','drop_in');

-- =============================================================================
-- As the FRONT DESK (desk-up): the reader is allowed, and everything resolves.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','d105d105-0000-0000-0000-0000000000f2',false);

-- Counts.
select expect_num('count all = 6 live members', ml_countkey('d105d105-0000-0000-0000-0000000000a1','all'), 6);
select expect_num('count active = 4 (M1,M2,M4,M6)', ml_countkey('d105d105-0000-0000-0000-0000000000a1','active'), 4);
select expect_num('count leads = 2 (M3,M5)', ml_countkey('d105d105-0000-0000-0000-0000000000a1','leads'), 2);
select expect_num('count unpaid = 1 (M6)', ml_countkey('d105d105-0000-0000-0000-0000000000a1','unpaid'), 1);
select expect_num('count free_pending = 1 (M3 booked comp)', ml_countkey('d105d105-0000-0000-0000-0000000000a1','free_pending'), 1);
select expect_num('count attention = 4 (M1,M2 dup; M3 fee; M4 waiver)', ml_countkey('d105d105-0000-0000-0000-0000000000a1','attention'), 4);
select expect_num('count deleted = 1 (M7)', ml_countkey('d105d105-0000-0000-0000-0000000000a1','deleted'), 1);

-- Search: name, email, and 4 phone digits.
select expect_num('search "Reyes" -> M1 + M5 = 2', ml_count('d105d105-0000-0000-0000-0000000000a1','Reyes','all'), 2);
select expect_num('search "ana@example.com" -> 1', ml_count('d105d105-0000-0000-0000-0000000000a1','ana@example.com','all'), 1);
select expect_num('search "1234" (phone digits) -> M1 + M2 = 2', ml_count('d105d105-0000-0000-0000-0000000000a1','1234','all'), 2);
select expect_num('search "999" (< 4 digits) matches nothing by phone', ml_count('d105d105-0000-0000-0000-0000000000a1','999','all'), 0);

-- Filters return the right members.
select expect_num('filter leads -> 2 rows', ml_count('d105d105-0000-0000-0000-0000000000a1','','leads'), 2);
select expect_num('filter unpaid -> 1 row', ml_count('d105d105-0000-0000-0000-0000000000a1','','unpaid'), 1);
select expect_num('filter free_pending -> 1 row', ml_count('d105d105-0000-0000-0000-0000000000a1','','free_pending'), 1);
select expect_num('filter attention -> 4 rows', ml_count('d105d105-0000-0000-0000-0000000000a1','','attention'), 4);
select expect_num('filter deleted -> 1 row', ml_count('d105d105-0000-0000-0000-0000000000a1','','deleted'), 1);

-- Needs attention picks up each signal.
select expect_true('M1 has_duplicate (shared phone)', ml_flag('d105d105-0000-0000-0000-0000000000a1','d105d105-0000-0000-0000-0000000e0001','has_duplicate'));
select expect_true('M2 has_duplicate (shared phone)', ml_flag('d105d105-0000-0000-0000-0000000000a1','d105d105-0000-0000-0000-0000000e0002','has_duplicate'));
select expect_false('M3 has no duplicate', ml_flag('d105d105-0000-0000-0000-0000000000a1','d105d105-0000-0000-0000-0000000e0003','has_duplicate'));
select expect_true('M3 has_fee_due (reservation fee)', ml_flag('d105d105-0000-0000-0000-0000000000a1','d105d105-0000-0000-0000-0000000e0003','has_fee_due'));
select expect_true('M4 needs_waiver (unsigned + future booking)', ml_flag('d105d105-0000-0000-0000-0000000000a1','d105d105-0000-0000-0000-0000000e0004','needs_waiver'));
select expect_false('M1 does not need a waiver (signed)', ml_flag('d105d105-0000-0000-0000-0000000000a1','d105d105-0000-0000-0000-0000000e0001','needs_waiver'));
select expect_true('M6 has_unpaid_booking', ml_flag('d105d105-0000-0000-0000-0000000000a1','d105d105-0000-0000-0000-0000000e0006','has_unpaid_booking'));

-- The deleted row carries merged_into.
select expect_true('deleted row names who it was merged into',
  exists (select 1 from jsonb_array_elements(members_list('d105d105-0000-0000-0000-0000000000a1','','deleted','attention',1) -> 'rows') r
           where (r->>'id')::uuid = 'd105d105-0000-0000-0000-0000000e0007'
             and (r->>'merged_into')::uuid = 'd105d105-0000-0000-0000-0000000e0001'
             and (r->>'deleted')::boolean));

-- Front desk is allowed (it returned rows above); confirm explicitly.
select expect_true('front desk may read members_list',
  jsonb_array_length(members_list('d105d105-0000-0000-0000-0000000000a1','','all','attention',1) -> 'rows') > 0);
reset role;

-- =============================================================================
-- As a PLAIN MEMBER: refused PT403.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','d105d105-0000-0000-0000-0000000000f3',false);
select expect_raises('a member cannot read members_list',
  $$ select members_list('d105d105-0000-0000-0000-0000000000a1','','all','attention',1) $$, 'PT403');
reset role;

select 'members_list_test: all assertions passed' as done;
