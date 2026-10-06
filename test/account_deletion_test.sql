-- =============================================================================
-- STUDIIOR — MEMBER SELF-SERVICE ACCOUNT DELETION (Decision 69, migration 237)
--
--   A member deletes their own account: the row is SCRUBBED (kept for the
--   studio's records, personal fields blanked, deleted_at set), the login is
--   removed, future bookings cancelled (waitlist promotes), memberships ended,
--   marketing off. History (attendance, sales) stays. delete_my_account acts on
--   auth.uid() only; staff/instructor logins and anon are refused.
--
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/account_deletion_test.sql
-- =============================================================================

\set ON_ERROR_STOP on
set client_min_messages = notice;

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
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  (expected true)', label; end if;
end $$;

-- --- Fixtures: de1e ---------------------------------------------------------
insert into auth.users (id) values
  ('de1e0000-0000-0000-0000-0000000000a1'),   -- M1, the deleter
  ('de1e0000-0000-0000-0000-0000000000a2'),   -- M2, waitlisted (gets promoted)
  ('de1e0000-0000-0000-0000-0000000000a3'),   -- M3, the "other" caller
  ('de1e0000-0000-0000-0000-0000000000a9');   -- a studio staff login
insert into profiles (id, email) values
  ('de1e0000-0000-0000-0000-0000000000a1','d-one@example.com'),
  ('de1e0000-0000-0000-0000-0000000000a2','d-two@example.com'),
  ('de1e0000-0000-0000-0000-0000000000a3','d-three@example.com'),
  ('de1e0000-0000-0000-0000-0000000000a9','d-staff@example.com');

insert into studios (id, name, slug, timezone, currency, status, contact_email) values
  ('de1e0000-0000-0000-0000-000000000001','Delete Studio','delete-test','Europe/Prague','CZK','active','desk@example.com');
insert into studio_settings (studio_id, waitlist_enabled, waitlist_offer_window_minutes,
                             waitlist_cutoff_minutes, cancellation_cutoff_minutes)
  values ('de1e0000-0000-0000-0000-000000000001', true, 120, 60, 720);
insert into locations (id, studio_id, name) values
  ('de1e0000-0000-0000-0000-00000000000c','de1e0000-0000-0000-0000-000000000001','Main');
insert into studio_staff (studio_id, user_id, email, role) values
  ('de1e0000-0000-0000-0000-000000000001','de1e0000-0000-0000-0000-0000000000a9','d-staff@example.com','owner');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('de1e0000-0000-0000-0000-0000000ee001','de1e0000-0000-0000-0000-000000000001','de1e0000-0000-0000-0000-00000000000c','A',1);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('de1e0000-0000-0000-0000-000000cc0001','de1e0000-0000-0000-0000-000000000001','Reformer',50,1);
insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, visibility, status) values
  ('de1e0000-0000-0000-0000-0000000d1001','de1e0000-0000-0000-0000-000000000001','5-Pack','class_pack',500000,'CZK',5,'public','active');

-- O1 future (capacity 1): M1 booked, M2 waitlisted. O2 past: M1 attended.
insert into class_occurrences
  (id, studio_id, class_type_id, location_id, room_id, name, starts_at, ends_at, capacity, booked_count, waitlist_count, status)
values
  ('de1e0000-0000-0000-0000-00000000c001','de1e0000-0000-0000-0000-000000000001',
   'de1e0000-0000-0000-0000-000000cc0001','de1e0000-0000-0000-0000-00000000000c','de1e0000-0000-0000-0000-0000000ee001',
   'Reformer', now() + interval '2 days', now() + interval '2 days' + interval '50 min', 1, 1, 1, 'scheduled'),
  ('de1e0000-0000-0000-0000-00000000c002','de1e0000-0000-0000-0000-000000000001',
   'de1e0000-0000-0000-0000-000000cc0001','de1e0000-0000-0000-0000-00000000000c','de1e0000-0000-0000-0000-0000000ee001',
   'Reformer', now() - interval '3 days', now() - interval '3 days' + interval '50 min', 1, 1, 0, 'scheduled');

insert into members (id, studio_id, user_id, first_name, last_name, email, status, marketing_opt_in) values
  ('de1e0000-0000-0000-0000-0000000e1001','de1e0000-0000-0000-0000-000000000001','de1e0000-0000-0000-0000-0000000000a1','Mia','One','d-one@example.com','active',true),
  ('de1e0000-0000-0000-0000-0000000e1002','de1e0000-0000-0000-0000-000000000001','de1e0000-0000-0000-0000-0000000000a2','Mo','Two','d-two@example.com','active',true),
  ('de1e0000-0000-0000-0000-0000000e1003','de1e0000-0000-0000-0000-000000000001','de1e0000-0000-0000-0000-0000000000a3','Mel','Three','d-three@example.com','active',true);

-- M1: a membership + a succeeded payment (for sales_history), a future booking
-- on O1, a past ATTENDED booking + check-in on O2.
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, credits_remaining, starts_on) values
  ('de1e0000-0000-0000-0000-0000000f1001','de1e0000-0000-0000-0000-000000000001','de1e0000-0000-0000-0000-0000000e1001','de1e0000-0000-0000-0000-0000000d1001','active',500000,'CZK',4,current_date);
insert into payments (id, studio_id, member_id, membership_id, amount_cents, currency, status, provider, method, created_at, paid_at) values
  ('de1e0000-0000-0000-0000-0000000a1001','de1e0000-0000-0000-0000-000000000001','de1e0000-0000-0000-0000-0000000e1001','de1e0000-0000-0000-0000-0000000f1001',500000,'CZK','succeeded','manual','cash', now()-interval '1 day', now()-interval '1 day');
insert into bookings (id, studio_id, occurrence_id, member_id, status, booked_at) values
  ('de1e0000-0000-0000-0000-0000000b0001','de1e0000-0000-0000-0000-000000000001','de1e0000-0000-0000-0000-00000000c001','de1e0000-0000-0000-0000-0000000e1001','booked', now()),
  ('de1e0000-0000-0000-0000-0000000b0002','de1e0000-0000-0000-0000-000000000001','de1e0000-0000-0000-0000-00000000c001','de1e0000-0000-0000-0000-0000000e1002','waitlisted', now()),
  ('de1e0000-0000-0000-0000-0000000b0003','de1e0000-0000-0000-0000-000000000001','de1e0000-0000-0000-0000-00000000c002','de1e0000-0000-0000-0000-0000000e1001','attended', now()-interval '3 days');
update bookings set waitlist_position = 1 where id = 'de1e0000-0000-0000-0000-0000000b0002';
insert into check_ins (id, studio_id, booking_id, member_id, occurrence_id, checked_in_at, method) values
  ('de1e0000-0000-0000-0000-0000000c1a01','de1e0000-0000-0000-0000-000000000001','de1e0000-0000-0000-0000-0000000b0003','de1e0000-0000-0000-0000-0000000e1001','de1e0000-0000-0000-0000-00000000c002', now()-interval '3 days','self');

-- === A staff/instructor login is REFUSED =====================================
set role authenticated;
select set_config('request.jwt.claim.sub','de1e0000-0000-0000-0000-0000000000a9',false);
do $$
declare ok boolean := false;
begin
  begin perform delete_my_account();
  exception when sqlstate 'PT403' then ok := true; end;
  perform expect_true('a studio staff login is refused (PT403)', ok);
end $$;
reset role;

-- === ANON is refused (no execute grant) ======================================
set role anon;
do $$
declare ok boolean := false;
begin
  begin perform delete_my_account();
  exception when insufficient_privilege then ok := true; when others then ok := true; end;
  perform expect_true('anon cannot execute delete_my_account', ok);
end $$;
reset role;

-- === Teeth: the account_deleting flag is COLUMN-NARROWED =====================
set role authenticated;
select set_config('request.jwt.claim.sub','de1e0000-0000-0000-0000-0000000000a2',false);  -- M2, a live member
do $$
declare ok boolean := false;
begin
  perform set_config('studiior.account_deleting','1',true);
  begin
    update members set lifetime_visits = 999  -- NOT a scrub column
     where id = 'de1e0000-0000-0000-0000-0000000e1002';
  exception when sqlstate 'PT403' then ok := true; end;
  perform expect_true('account_deleting flag refuses a non-scrub column', ok);
  -- a scrub column is allowed (no-op change)
  update members set deleted_at = null where id = 'de1e0000-0000-0000-0000-0000000e1002';
  perform expect_true('account_deleting flag allows a scrub column', true);
end $$;
reset role;

-- === M3 calls delete: only M3 is affected (auth.uid() only) ==================
set role authenticated;
select set_config('request.jwt.claim.sub','de1e0000-0000-0000-0000-0000000000a3',false);
select delete_my_account();
reset role;
do $$
begin
  perform expect_true('M3 (the caller) is scrubbed',
    (select deleted_at is not null from members where id='de1e0000-0000-0000-0000-0000000e1003'));
  perform expect_true('M1 is UNTOUCHED when M3 deletes (auth.uid() only)',
    (select deleted_at is null and first_name='Mia' from members where id='de1e0000-0000-0000-0000-0000000e1001'));
end $$;

-- === M1 deletes their own account ============================================
set role authenticated;
select set_config('request.jwt.claim.sub','de1e0000-0000-0000-0000-0000000000a1',false);
select delete_my_account();
reset role;

do $$
begin
  -- 1. Row scrubbed, deleted_at set, auth user gone, unlinked.
  perform expect_text('M1 first name scrubbed', (select first_name from members where id='de1e0000-0000-0000-0000-0000000e1001'), 'Deleted');
  perform expect_text('M1 last name scrubbed',  (select last_name  from members where id='de1e0000-0000-0000-0000-0000000e1001'), 'member');
  perform expect_true('M1 email is a sentinel', (select email like 'deleted+%@deleted.invalid' from members where id='de1e0000-0000-0000-0000-0000000e1001'));
  perform expect_true('M1 deleted_at set',      (select deleted_at is not null from members where id='de1e0000-0000-0000-0000-0000000e1001'));
  perform expect_true('M1 phone/dob blanked',   (select phone is null and date_of_birth is null from members where id='de1e0000-0000-0000-0000-0000000e1001'));
  perform expect_num ('M1 auth user deleted',   (select count(*) from auth.users where id='de1e0000-0000-0000-0000-0000000000a1'), 0);
  perform expect_true('M1 member row unlinked (user_id null)', (select user_id is null from members where id='de1e0000-0000-0000-0000-0000000e1001'));

  -- 2. Future booking cancelled (no late penalty) + waitlist promoted.
  perform expect_text('M1 future booking cancelled', (select status::text from bookings where id='de1e0000-0000-0000-0000-0000000b0001'), 'cancelled');
  perform expect_true('M1 future cancel is NOT late', (select coalesce(is_late_cancel,false)=false from bookings where id='de1e0000-0000-0000-0000-0000000b0001'));
  perform expect_true('M2 got a waitlist offer (promotion fired)',
    (select exists(select 1 from waitlist_offers wo
       join bookings bk on bk.id = wo.booking_id
      where wo.occurrence_id='de1e0000-0000-0000-0000-00000000c001'
        and bk.member_id='de1e0000-0000-0000-0000-0000000e1002')));

  -- 3. Past attended booking still present and still joined to the scrubbed row.
  perform expect_text('past booking still attended', (select status::text from bookings where id='de1e0000-0000-0000-0000-0000000b0003'), 'attended');
  perform expect_text('past booking joins the scrubbed row', (select m.first_name||' '||m.last_name from bookings b join members m on m.id=b.member_id where b.id='de1e0000-0000-0000-0000-0000000b0003'), 'Deleted member');

  -- 4. Sales history row still present (payment kept).
  perform expect_num('payment kept for accounting', (select count(*) from payments where id='de1e0000-0000-0000-0000-0000000a1001' and status='succeeded'), 1);

  -- 5. Memberships ended.
  perform expect_text('membership ended', (select status::text from memberships where id='de1e0000-0000-0000-0000-0000000f1001'), 'cancelled');

  -- 6. Marketing unsubscribed.
  perform expect_true('marketing off + stamped',
    (select marketing_opt_in=false and marketing_unsubscribed_at is not null from members where id='de1e0000-0000-0000-0000-0000000e1001'));

  -- a confirmation email was queued to the PRE-SCRUB address.
  perform expect_true('account_deleted email queued to the old address',
    (select exists(select 1 from notifications where template_key='account_deleted'
       and payload->>'to_email'='d-one@example.com')));
end $$;

-- === Deleted member absent from staff list / campaign audience / roster ======
set role authenticated;
select set_config('request.jwt.claim.sub','de1e0000-0000-0000-0000-0000000000a9',false);  -- staff/owner
do $$
begin
  perform expect_num('deleted M1 absent from member_plan_overview',
    (select count(*) from member_plan_overview('de1e0000-0000-0000-0000-000000000001') where id='de1e0000-0000-0000-0000-0000000e1001'), 0);
  perform expect_num('live M2 still present in member_plan_overview',
    (select count(*) from member_plan_overview('de1e0000-0000-0000-0000-000000000001') where id='de1e0000-0000-0000-0000-0000000e1002'), 1);
  perform expect_num('deleted M1 absent from campaign_audience',
    (select count(*) from campaign_audience('de1e0000-0000-0000-0000-000000000001','{}'::jsonb) where member_id='de1e0000-0000-0000-0000-0000000e1001'), 0);
  -- Roster: the deleted member has no LIVE booking on the future class.
  perform expect_num('deleted M1 absent from the future-class roster',
    (select count(*) from bookings where occurrence_id='de1e0000-0000-0000-0000-00000000c001'
       and member_id='de1e0000-0000-0000-0000-0000000e1001' and status in ('booked','attended')), 0);
end $$;
reset role;

\echo 'account_deletion_test: all assertions passed'
