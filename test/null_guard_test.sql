-- =============================================================================
-- Null-guard ownership fixes — migration 130
-- =============================================================================
-- UUID space 40a1, checked free. Run after `supabase db reset`.
--
-- The bug: `if not (m.user_id = auth.uid() or is_desk_up(...)) then raise` does
-- NOT fire when m.user_id is NULL (an unclaimed guest/lead/import), because
-- `null = uid` is NULL and `if NULL then raise` is skipped. A signed-in member
-- (ATK) must NOT be able to act on an unclaimed member's (VIC, user_id null)
-- booking through cancel_booking, respond_to_offer or choose_pay_at_desk.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if;
end $$;

-- Run a call as ATK (authenticated) and return the sqlstate it raised, or a
-- sentinel if it did NOT raise (the hole).
create or replace function atk_state(sql text) returns text language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub','40a140a1-0000-0000-0000-0000000000a2', true);
  set local role authenticated;
  begin execute sql; return 'NOT REFUSED'; exception when others then return sqlstate; end;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values ('40a140a1-0000-0000-0000-0000000000a2');  -- ATK login
insert into profiles (id, email) values ('40a140a1-0000-0000-0000-0000000000a2','40a1-atk@example.com');

insert into studios (id, name, slug, timezone, currency, status) values
  ('40a140a1-0000-0000-0000-000000000001','Guard A','40a1-a','Europe/Prague','CZK','active');
insert into studio_settings (studio_id, waitlist_enabled) values ('40a140a1-0000-0000-0000-000000000001', true);
insert into locations (id, studio_id, name, is_primary) values
  ('40a140a1-0000-0000-0000-00000000000a','40a140a1-0000-0000-0000-000000000001','Main',true);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('40a140a1-0000-0000-0000-0000000cc001','40a140a1-0000-0000-0000-000000000001','Reformer',50,10);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('40a140a1-0000-0000-0000-0000000ee001','40a140a1-0000-0000-0000-000000000001','40a140a1-0000-0000-0000-00000000000a','R1',10),
  ('40a140a1-0000-0000-0000-0000000ee002','40a140a1-0000-0000-0000-000000000001','40a140a1-0000-0000-0000-00000000000a','R2',10),
  ('40a140a1-0000-0000-0000-0000000ee003','40a140a1-0000-0000-0000-000000000001','40a140a1-0000-0000-0000-00000000000a','R3',10);

-- ATK is a real member with a login; VIC is UNCLAIMED (user_id null), the
-- population the bug exposes. Neither is staff.
insert into members (id, studio_id, user_id, first_name, last_name, email, waiver_signed_at) values
  ('40a140a1-0000-0000-0000-0000000d0a02','40a140a1-0000-0000-0000-000000000001','40a140a1-0000-0000-0000-0000000000a2','Att','Acker','40a1-atk@example.com',now()),
  ('40a140a1-0000-0000-0000-0000000d0a1c','40a140a1-0000-0000-0000-000000000001',null,'Vic','Tim','40a1-vic@example.com',now());

insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name,
                               starts_at, ends_at, capacity, booked_count, waitlist_count, status) values
  ('40a140a1-0000-0000-0000-00000000c001','40a140a1-0000-0000-0000-000000000001','40a140a1-0000-0000-0000-00000000000a','40a140a1-0000-0000-0000-0000000cc001','40a140a1-0000-0000-0000-0000000ee001','Cancel me', now()+interval '2 days', now()+interval '2 days' + interval '50 min',10,1,0,'scheduled'),
  ('40a140a1-0000-0000-0000-00000000c002','40a140a1-0000-0000-0000-000000000001','40a140a1-0000-0000-0000-00000000000a','40a140a1-0000-0000-0000-0000000cc001','40a140a1-0000-0000-0000-0000000ee002','Offer me', now()+interval '2 days', now()+interval '2 days' + interval '50 min',10,10,1,'scheduled'),
  ('40a140a1-0000-0000-0000-00000000c003','40a140a1-0000-0000-0000-000000000001','40a140a1-0000-0000-0000-00000000000a','40a140a1-0000-0000-0000-0000000cc001','40a140a1-0000-0000-0000-0000000ee003','Pay me', now()+interval '2 days', now()+interval '2 days' + interval '50 min',10,1,0,'scheduled');

-- VIC's bookings: a live 'booked', a 'waitlisted' with a pending offer, and a
-- 'pending_payment'.
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, waitlist_position) values
  ('40a140a1-0000-0000-0000-00000000b001','40a140a1-0000-0000-0000-000000000001','40a140a1-0000-0000-0000-00000000c001','40a140a1-0000-0000-0000-0000000d0a1c','booked','member','drop_in',null),
  ('40a140a1-0000-0000-0000-00000000b002','40a140a1-0000-0000-0000-000000000001','40a140a1-0000-0000-0000-00000000c002','40a140a1-0000-0000-0000-0000000d0a1c','waitlisted','member',null,1),
  ('40a140a1-0000-0000-0000-00000000b003','40a140a1-0000-0000-0000-000000000001','40a140a1-0000-0000-0000-00000000c003','40a140a1-0000-0000-0000-0000000d0a1c','pending_payment','member','drop_in',null);
insert into waitlist_offers (id, studio_id, booking_id, occurrence_id, expires_at) values
  ('40a140a1-0000-0000-0000-00000000f002','40a140a1-0000-0000-0000-000000000001','40a140a1-0000-0000-0000-00000000b002','40a140a1-0000-0000-0000-00000000c002', now()+interval '30 min');

-- =============================================================================
-- The three guards must refuse ATK acting on VIC's (null user_id) bookings.
-- =============================================================================
select expect_text('a member cannot cancel an unclaimed member''s booking',
  atk_state($$ select cancel_booking('40a140a1-0000-0000-0000-00000000b001') $$), 'PT403');
select set_config('request.jwt.claim.sub','',false); reset role;

select expect_text('a member cannot respond to an unclaimed member''s waitlist offer',
  atk_state($$ select respond_to_offer('40a140a1-0000-0000-0000-00000000f002', false) $$), 'PT403');
select set_config('request.jwt.claim.sub','',false); reset role;

select expect_text('a member cannot pay-at-desk an unclaimed member''s booking',
  atk_state($$ select choose_pay_at_desk('40a140a1-0000-0000-0000-00000000b003') $$), 'PT403');
select set_config('request.jwt.claim.sub','',false); reset role;

do $$ begin raise notice 'null_guard_test: all assertions passed'; end $$;
