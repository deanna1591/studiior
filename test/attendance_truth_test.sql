-- =============================================================================
-- Decision 75b-1 (f) — attendance truth is check_ins, not booking status.
-- =============================================================================
-- UUID space a75f, checked free. Run after `supabase db reset`.
--
--   * finalise_attendance_sweep flips a booked booking that HAS a check_in to
--     attended (never no-shows a scanned-in member), and no_shows the rest;
--   * a self-checked (already attended) booking is untouched;
--   * record_check_in (the single path) inserts + flips to attended, idempotent,
--     and refuses a caller who is not staff of the studio (PT403);
--   * the backfill is idempotent (second pass flips nothing).
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_eq(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual,'null'); end if;
end $$;

-- record_check_in run as a given session, normalised to one token.
create or replace function rci(p_uid text, p_booking uuid, p_method text)
returns text language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claim.sub', p_uid, true);
  set local role authenticated;
  begin
    r := record_check_in(p_booking, p_method);
    reset role;
    if coalesce((r->>'ok')::boolean, false) then
      return case when coalesce((r->>'already')::boolean, false) then 'ALREADY' else 'OK' end;
    end if;
    return coalesce(r->>'reason', '?');
  exception when others then reset role; return 'ERR:'||sqlstate; end;
end $$;

-- the backfill statement, returning how many rows it flipped.
create or replace function bf() returns int language plpgsql as $$
declare n int;
begin
  update bookings b set status = 'attended', updated_at = now()
    from class_occurrences o
   where b.occurrence_id = o.id and b.status = 'booked'
     and o.ends_at < now()
     and exists (select 1 from check_ins ci where ci.booking_id = b.id);
  get diagnostics n = row_count;
  return n;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('a75fa75f-0000-0000-0000-00000000000f'),   -- an owner-staff of SF
  ('a75fa75f-0000-0000-0000-0000000000ff');   -- a stranger (not staff anywhere)
insert into profiles (id, email) select id, id::text||'@example.com' from auth.users where id::text like 'a75f%';

insert into studios (id, name, slug, timezone, currency, status) values
  ('a75fa75f-0000-0000-0000-000000000001','SF','a75f-f','Asia/Manila','PHP','active'),
  ('a75fa75f-0000-0000-0000-000000000002','SF2','a75f-f2','Asia/Manila','PHP','active');
-- SF finalise ON; SF2 finalise OFF (the sweep never touches it — the backfill
-- subject lives there). Window enforcement OFF so fixtures can insert past check_ins.
insert into studio_settings (studio_id, finalise_attendance, finalise_days_after, checkin_window_enforced) values
  ('a75fa75f-0000-0000-0000-000000000001', true,  1, false),
  ('a75fa75f-0000-0000-0000-000000000002', false, 1, false);

insert into studio_staff (id, studio_id, user_id, email, role, status) values
  ('a75fa75f-0000-0000-0000-0000000005ff','a75fa75f-0000-0000-0000-000000000001','a75fa75f-0000-0000-0000-00000000000f','a75f-owner@example.com','owner','active');

insert into locations (id, studio_id, name, is_primary) values
  ('a75fa75f-0000-0000-0000-00000000100c','a75fa75f-0000-0000-0000-000000000001','F', true),
  ('a75fa75f-0000-0000-0000-00000000200c','a75fa75f-0000-0000-0000-000000000002','F2', true);

insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('a75fa75f-0000-0000-0000-0000000cc001','a75fa75f-0000-0000-0000-000000000001','Mat',50,10),
  ('a75fa75f-0000-0000-0000-0000000cc002','a75fa75f-0000-0000-0000-000000000002','Mat',50,10);

insert into members (id, studio_id, first_name, last_name, email, waiver_signed_at) values
  ('a75fa75f-0000-0000-0000-0000000d0001','a75fa75f-0000-0000-0000-000000000001','Ci','One','a75f-ci@example.com',now()),
  ('a75fa75f-0000-0000-0000-0000000d0002','a75fa75f-0000-0000-0000-000000000001','No','Two','a75f-no@example.com',now()),
  ('a75fa75f-0000-0000-0000-0000000d0003','a75fa75f-0000-0000-0000-000000000001','Att','Three','a75f-att@example.com',now()),
  ('a75fa75f-0000-0000-0000-0000000d0005','a75fa75f-0000-0000-0000-000000000001','New','Five','a75f-new@example.com',now()),
  ('a75fa75f-0000-0000-0000-0000000d2004','a75fa75f-0000-0000-0000-000000000002','Bf','Four','a75f-bf@example.com',now());

-- OF1 ended 2 days ago (past midnight+1day => finalisation is due).
-- OF_bf also ended 2 days ago, for the backfill test (not swept here).
-- OF_live ends in +1h, for the record_check_in direct test.
insert into class_occurrences (id, studio_id, location_id, class_type_id, name,
                               starts_at, ends_at, capacity, booked_count, status) values
  ('a75fa75f-0000-0000-0000-0000000f0001','a75fa75f-0000-0000-0000-000000000001','a75fa75f-0000-0000-0000-00000000100c','a75fa75f-0000-0000-0000-0000000cc001','OF1',
     now()-interval '2 days 1 h', now()-interval '2 days', 10, 3, 'scheduled'),
  ('a75fa75f-0000-0000-0000-0000000f00bf','a75fa75f-0000-0000-0000-000000000002','a75fa75f-0000-0000-0000-00000000200c','a75fa75f-0000-0000-0000-0000000cc002','OFbf',
     now()-interval '2 days 1 h', now()-interval '2 days', 10, 1, 'scheduled'),
  ('a75fa75f-0000-0000-0000-0000000f001e','a75fa75f-0000-0000-0000-000000000001','a75fa75f-0000-0000-0000-00000000100c','a75fa75f-0000-0000-0000-0000000cc001','OFlive',
     now()-interval '10 min', now()+interval '40 min', 10, 1, 'scheduled');

insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, booked_at) values
  ('a75fa75f-0000-0000-0000-0000000b0001','a75fa75f-0000-0000-0000-000000000001','a75fa75f-0000-0000-0000-0000000f0001','a75fa75f-0000-0000-0000-0000000d0001','booked','member','drop_in', now()-interval '3 days'),   -- B_ci  (has check_in, still booked)
  ('a75fa75f-0000-0000-0000-0000000b0002','a75fa75f-0000-0000-0000-000000000001','a75fa75f-0000-0000-0000-0000000f0001','a75fa75f-0000-0000-0000-0000000d0002','booked','member','drop_in', now()-interval '3 days'),   -- B_no  (no check_in)
  ('a75fa75f-0000-0000-0000-0000000b0003','a75fa75f-0000-0000-0000-000000000001','a75fa75f-0000-0000-0000-0000000f0001','a75fa75f-0000-0000-0000-0000000d0003','attended','member','drop_in', now()-interval '3 days'), -- B_att (self-checked)
  ('a75fa75f-0000-0000-0000-0000000b00bf','a75fa75f-0000-0000-0000-000000000002','a75fa75f-0000-0000-0000-0000000f00bf','a75fa75f-0000-0000-0000-0000000d2004','booked','member','drop_in', now()-interval '3 days'),   -- B_bf  (backfill)
  ('a75fa75f-0000-0000-0000-0000000b001e','a75fa75f-0000-0000-0000-000000000001','a75fa75f-0000-0000-0000-0000000f001e','a75fa75f-0000-0000-0000-0000000d0005','booked','member','drop_in', now()-interval '1 h');    -- B_live (record_check_in)

-- check_ins for B_ci, B_att, B_bf (method 'instructor' leaves booking booked; B_att is already attended).
insert into check_ins (studio_id, booking_id, member_id, occurrence_id, method, checked_in_at) values
  ('a75fa75f-0000-0000-0000-000000000001','a75fa75f-0000-0000-0000-0000000b0001','a75fa75f-0000-0000-0000-0000000d0001','a75fa75f-0000-0000-0000-0000000f0001','instructor', now()-interval '2 days 1 h'),
  ('a75fa75f-0000-0000-0000-000000000001','a75fa75f-0000-0000-0000-0000000b0003','a75fa75f-0000-0000-0000-0000000d0003','a75fa75f-0000-0000-0000-0000000f0001','self',       now()-interval '2 days 1 h'),
  ('a75fa75f-0000-0000-0000-000000000002','a75fa75f-0000-0000-0000-0000000b00bf','a75fa75f-0000-0000-0000-0000000d2004','a75fa75f-0000-0000-0000-0000000f00bf','instructor', now()-interval '2 days 1 h');

-- --- before the sweep --------------------------------------------------------
select expect_eq('B_ci starts booked',  (select status::text from bookings where id='a75fa75f-0000-0000-0000-0000000b0001'), 'booked');
select expect_eq('B_no starts booked',  (select status::text from bookings where id='a75fa75f-0000-0000-0000-0000000b0002'), 'booked');
select expect_eq('B_att starts attended',(select status::text from bookings where id='a75fa75f-0000-0000-0000-0000000b0003'), 'attended');

-- --- run the sweep (superuser => is_service_context) -------------------------
select finalise_attendance_sweep();

select expect_eq('B_ci (had a check_in) is flipped to attended, never no_show',
  (select status::text from bookings where id='a75fa75f-0000-0000-0000-0000000b0001'), 'attended');
select expect_eq('B_no (no check_in) is no_show',
  (select status::text from bookings where id='a75fa75f-0000-0000-0000-0000000b0002'), 'no_show');
select expect_eq('B_no carries no_show_at',
  (select (no_show_at is not null)::text from bookings where id='a75fa75f-0000-0000-0000-0000000b0002'), 'true');
select expect_eq('B_att (self-checked) is unchanged',
  (select status::text from bookings where id='a75fa75f-0000-0000-0000-0000000b0003'), 'attended');
select expect_eq('OF1 is stamped finalised',
  (select (attendance_finalised_at is not null)::text from class_occurrences where id='a75fa75f-0000-0000-0000-0000000f0001'), 'true');

-- --- record_check_in: the single path flips the booking + is idempotent ------
select expect_eq('record_check_in by a stranger is refused (PT403)',
  rci('a75fa75f-0000-0000-0000-0000000000ff','a75fa75f-0000-0000-0000-0000000b001e','instructor'), 'ERR:PT403');
select expect_eq('record_check_in by studio staff checks in',
  rci('a75fa75f-0000-0000-0000-00000000000f','a75fa75f-0000-0000-0000-0000000b001e','instructor'), 'OK');
select expect_eq('B_live is now attended',
  (select status::text from bookings where id='a75fa75f-0000-0000-0000-0000000b001e'), 'attended');
select expect_eq('record_check_in again is idempotent (already)',
  rci('a75fa75f-0000-0000-0000-00000000000f','a75fa75f-0000-0000-0000-0000000b001e','instructor'), 'ALREADY');
select expect_eq('B_live still has exactly one check_in',
  (select count(*)::text from check_ins where booking_id='a75fa75f-0000-0000-0000-0000000b001e'), '1');

-- --- backfill is idempotent --------------------------------------------------
select expect_eq('backfill flips the one booked-with-check-in ended booking', bf()::text, '1');
select expect_eq('B_bf is now attended',
  (select status::text from bookings where id='a75fa75f-0000-0000-0000-0000000b00bf'), 'attended');
select expect_eq('backfill run again flips nothing', bf()::text, '0');

select 'attendance_truth_test OK' as result;
