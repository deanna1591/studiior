-- =============================================================================
-- Decision 88 slice B — member_wallet scoping. Migration 20260833160000.
-- =============================================================================
-- UUID space 88b0 (hex), checked free. Run after `supabase db reset`.
--
-- /payments is served by ONE member-guarded read, member_wallet(studio), that
-- returns the member's own payments (succeeded / with a refund), their open
-- online checkouts, and their unpaid desk seats. This suite proves: the three
-- groups bucket correctly (a failed payment is NOT shown; a refund lands in
-- the refunded set); the reader is scoped to the CALLER's own member row (it
-- never returns another member's payment); and it is own-STUDIO + member-only
-- (a member of another studio, and a login with no member row, are both PT403).
-- Anon surface stays EXACTLY THIRTEEN.
--
-- RED proof: on the pre-88b schema member_wallet does not exist, so wal(...)
-- errors 42883 rather than returning the three groups.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to warning;

create or replace function expect_num(label text, actual bigint, want bigint) returns void language plpgsql as $$
begin if actual = want then raise notice 'PASS  %  (got %)', label, actual; else raise exception 'BAD  %  expected %, got %', label, want, actual; end if; end $$;
create or replace function expect_text(label text, actual text, want text) returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'BAD  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if; end $$;
-- Runs member_wallet AS the given member session, a refusal captured as its
-- SQLSTATE so a PT403 is asserted rather than aborting the suite.
create or replace function wal(uid text, studio uuid) returns jsonb language plpgsql as $$
declare j jsonb; begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role','authenticated')::text, true);
  set local role authenticated;
  begin j := member_wallet(studio); reset role; return j;
  exception when others then reset role; return jsonb_build_object('err', sqlstate); end;
end $$;

reset role;

-- ---- Two studios ------------------------------------------------------------
insert into studios (id, name, slug, timezone, currency, status) values
  ('88b00000-0000-0000-0000-0000000000a0','Wallet SA','88b0-sa','UTC','PHP','active'),
  ('88b00000-0000-0000-0000-0000000000b0','Wallet SB','88b0-sb','UTC','PHP','active');
insert into studio_settings (studio_id, require_waiver) values
  ('88b00000-0000-0000-0000-0000000000a0', false),
  ('88b00000-0000-0000-0000-0000000000b0', false);
insert into locations (id, studio_id, name) values
  ('88b00000-0000-0000-0000-00000000a0a0','88b00000-0000-0000-0000-0000000000a0','Main'),
  ('88b00000-0000-0000-0000-00000000b0b0','88b00000-0000-0000-0000-0000000000b0','Main');
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('88b00000-0000-0000-0000-0000000aa001','88b00000-0000-0000-0000-0000000000a0','88b00000-0000-0000-0000-00000000a0a0','Studio',20);
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('88b00000-0000-0000-0000-0000000c0a01','88b00000-0000-0000-0000-0000000000a0','Reformer',50,20);

-- A future class at A (named), for the desk-owed seat.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, starts_at, ends_at, capacity, status, staffing, name) values
  ('88b00000-0000-0000-0000-00000000c1a0','88b00000-0000-0000-0000-0000000000a0','88b00000-0000-0000-0000-00000000a0a0','88b00000-0000-0000-0000-0000000c0a01','88b00000-0000-0000-0000-0000000aa001',null, now()+interval '3 day', now()+interval '3 day'+interval '50 min', 20,'scheduled','open','Reformer Flow');

-- ---- Plans: a pack at A (the paid item) + a public drop-in (the desk price) --
insert into membership_plans (id, studio_id, name, type, visibility, status, price_cents, currency, credits, validity_days) values
  ('88b00000-0000-0000-0000-0000000f0a01','88b00000-0000-0000-0000-0000000000a0','5 Pack','class_pack','public','active',100000,'PHP',5,90),
  ('88b00000-0000-0000-0000-0000000f0a02','88b00000-0000-0000-0000-0000000000a0','Single Drop-in','drop_in','public','active',50000,'PHP',1,30),
  ('88b00000-0000-0000-0000-0000000f0b01','88b00000-0000-0000-0000-0000000000b0','B Pack','class_pack','public','active',100000,'PHP',5,90);

-- ---- Logins + profiles + members -------------------------------------------
insert into auth.users (id) values
  ('88b00000-0000-0000-0000-000000001001'),  -- member A
  ('88b00000-0000-0000-0000-000000001002'),  -- member B
  ('88b00000-0000-0000-0000-000000009999');  -- a login with no member row at A
insert into profiles (id, email, full_name) values
  ('88b00000-0000-0000-0000-000000001001','a@w.co','A Member'),
  ('88b00000-0000-0000-0000-000000001002','b@w.co','B Member'),
  ('88b00000-0000-0000-0000-000000009999','x@w.co','Stranger');
insert into members (id, studio_id, user_id, first_name, last_name, email, status, joined_on) values
  ('88b00000-0000-0000-0000-00000000dd01','88b00000-0000-0000-0000-0000000000a0','88b00000-0000-0000-0000-000000001001','A','Member','a@w.co','active', now()),
  ('88b00000-0000-0000-0000-00000000dd02','88b00000-0000-0000-0000-0000000000b0','88b00000-0000-0000-0000-000000001002','B','Member','b@w.co','active', now());
-- The stranger (…9999) is a member of NEITHER studio.

-- A's membership on the pack (so the paid payment resolves an item name).
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on, expires_on, credits_remaining) values
  ('88b00000-0000-0000-0000-00000000ec01','88b00000-0000-0000-0000-0000000000a0','88b00000-0000-0000-0000-00000000dd01','88b00000-0000-0000-0000-0000000f0a01','active',100000,'PHP', now()::date, (now()+interval '60 day')::date, 5);

-- ---- A's payments: one succeeded, one partially refunded, one failed --------
insert into payments (id, studio_id, member_id, membership_id, amount_cents, currency, status, provider, method, paid_at, refunded_cents, refunded_at) values
  ('88b00000-0000-0000-0000-00000000fa01','88b00000-0000-0000-0000-0000000000a0','88b00000-0000-0000-0000-00000000dd01','88b00000-0000-0000-0000-00000000ec01',100000,'PHP','succeeded','manual','cash', now()-interval '5 day', 0, null),
  ('88b00000-0000-0000-0000-00000000fa02','88b00000-0000-0000-0000-0000000000a0','88b00000-0000-0000-0000-00000000dd01',null,50000,'PHP','partially_refunded','xendit','gcash', now()-interval '3 day', 3000, now()-interval '1 day'),
  ('88b00000-0000-0000-0000-00000000fa03','88b00000-0000-0000-0000-0000000000a0','88b00000-0000-0000-0000-00000000dd01',null,50000,'PHP','failed','xendit',null, null, 0, null);

-- ---- A's open online checkout (never completed) -----------------------------
insert into xendit_purchases (id, studio_id, member_id, plan_id, amount_cents, currency, status) values
  ('88b00000-0000-0000-0000-00000000de01','88b00000-0000-0000-0000-0000000000a0','88b00000-0000-0000-0000-00000000dd01','88b00000-0000-0000-0000-0000000f0a01',100000,'PHP','pending');

-- ---- A's unpaid desk seat on the future class -------------------------------
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source) values
  ('88b00000-0000-0000-0000-00000000bc01','88b00000-0000-0000-0000-0000000000a0','88b00000-0000-0000-0000-00000000c1a0','88b00000-0000-0000-0000-00000000dd01','booked','member','drop_in');

-- ---- B's succeeded payment (must never appear in A's wallet) -----------------
insert into payments (id, studio_id, member_id, amount_cents, currency, status, provider, method, paid_at) values
  ('88b00000-0000-0000-0000-00000000fb0b','88b00000-0000-0000-0000-0000000000b0','88b00000-0000-0000-0000-00000000dd02',100000,'PHP','succeeded','manual','cash', now()-interval '2 day');

reset role;

-- =============================================================================
do $$
declare
  w jsonb;
  pays jsonb; onl jsonb; dsk jsonb;
  paid_item text; ref_cents int; desk_item text; desk_due int;
  b_present boolean;
  r jsonb;
begin
  -- Member A reads their own wallet.
  w := wal('88b00000-0000-0000-0000-000000001001','88b00000-0000-0000-0000-0000000000a0');
  pays := w->'payments'; onl := w->'online'; dsk := w->'desk';

  -- The failed payment is excluded; the succeeded + partially-refunded remain.
  perform expect_num('A payments: succeeded + refunded, not the failed one',
    jsonb_array_length(pays), 2);
  perform expect_num('A online: one open checkout', jsonb_array_length(onl), 1);
  perform expect_num('A desk: one unpaid seat', jsonb_array_length(dsk), 1);

  -- The succeeded payment resolves its plan name.
  select e->>'item' into paid_item from jsonb_array_elements(pays) e
   where e->>'id' = '88b00000-0000-0000-0000-00000000fa01';
  perform expect_text('A paid item = plan name', paid_item, '5 Pack');

  -- The refunded payment carries the amount refunded.
  select (e->>'refunded_cents')::int into ref_cents from jsonb_array_elements(pays) e
   where e->>'id' = '88b00000-0000-0000-0000-00000000fa02';
  perform expect_num('A refunded_cents', ref_cents, 3000);

  -- The desk seat: item = the class name, due = the public drop-in price.
  desk_item := dsk->0->>'item';
  desk_due  := (dsk->0->>'due_cents')::int;
  perform expect_text('A desk item = class name', desk_item, 'Reformer Flow');
  perform expect_num('A desk due = drop-in price', desk_due, 50000);

  -- Scoping by member: B's payment is NOT in A's wallet.
  select exists(select 1 from jsonb_array_elements(pays) e
                 where e->>'id' = '88b00000-0000-0000-0000-00000000fb0b') into b_present;
  perform expect_text('B payment absent from A wallet', b_present::text, 'false');

  -- Own-studio: A asking for B's studio is refused (A is not a member of B).
  r := wal('88b00000-0000-0000-0000-000000001001','88b00000-0000-0000-0000-0000000000b0');
  perform expect_text('A → B studio refused PT403', r->>'err', 'PT403');

  -- A login with no member row at A is refused.
  r := wal('88b00000-0000-0000-0000-000000009999','88b00000-0000-0000-0000-0000000000a0');
  perform expect_text('stranger refused PT403', r->>'err', 'PT403');
end $$;

-- ---- Anon surface is EXACTLY THIRTEEN (suite helpers excluded) --------------
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not in ('expect_num','expect_text','wal','login');
  perform expect_num('anon surface is thirteen', n, 13);
end $$;

select 'wallet_scope_test: all assertions passed' as result;
