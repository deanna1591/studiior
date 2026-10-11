-- =============================================================================
-- STUDIIOR — DECISION 73b: PAY NOW (apply ANY plan to the oldest unpaid booking
-- on activation)
--
-- On activation of ANY plan purchase (xendit_activate_success_internal), the new
-- membership settles the buyer's OLDEST unpaid app-booked drop-in: the booking is
-- relinked to the membership and its payment_source flips drop_in → the
-- membership source (class_pack for a pack/drop_in/trial, membership for a
-- recurring plan). A credit-granting plan consumes one credit through the
-- credit_ledger; an unlimited recurring plan links the booking with no credit
-- consumed. A plan that does not cover the held class (class-type or peak
-- restriction) leaves the booking untouched. Idempotent on a replay.
-- activate_purchase itself (desk/Stripe) is unchanged, and a Stripe
-- pending_payment hold is NOT the apply target.
--
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f test/dropin_settle_test.sql
--
-- Space: d73b. Local only — inserts fixtures. Never run against production.
-- =============================================================================

\set ON_ERROR_STOP on
set client_min_messages = notice;

create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then
    raise notice 'PASS  %  (got %)', label, coalesce(actual, 'null');
  else
    raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null');
  end if;
end $$;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then
    raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else
    raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null');
  end if;
end $$;

-- ---- Fixtures ---------------------------------------------------------------
insert into studios (id, name, slug, timezone, currency) values
  ('d73b0000-0000-0000-0000-000000000001','Settle Studio','settle73b','Europe/Prague','CZK');
insert into studio_settings (studio_id, require_waiver, booking_cutoff_minutes)
  values ('d73b0000-0000-0000-0000-000000000001', false, 0);
insert into locations (id, studio_id, name) values
  ('d73b0000-0000-0000-0000-00000000000c','d73b0000-0000-0000-0000-000000000001','Main');
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('d73b0000-0000-0000-0000-0000000000c1','d73b0000-0000-0000-0000-000000000001','Reformer',50,6);
insert into class_occurrences (id, studio_id, location_id, class_type_id, name, capacity, starts_at, ends_at, guarantee_tier)
select ('d73b0000-0000-0000-0000-0000000000f'||n)::uuid, 'd73b0000-0000-0000-0000-000000000001',
       'd73b0000-0000-0000-0000-00000000000c','d73b0000-0000-0000-0000-0000000000c1',
       'Future '||n, 6, now()+interval '2 days'+(n||' hours')::interval,
       now()+interval '2 days'+(n||' hours 50 min')::interval, 'core'
  from generate_series(1,9) n;

-- A public active drop_in plan (activate_purchase grants it exactly 1 credit,
-- migration 202). credits is null — the CHECK keeps a count off a drop_in plan.
insert into membership_plans (id, studio_id, name, type, price_cents, currency, validity_days, visibility, status)
  values ('d73b0000-0000-0000-0000-0000000000d1','d73b0000-0000-0000-0000-000000000001','Single Drop-in','drop_in',15000,'CZK',30,'public','active');

insert into members (id, studio_id, first_name, last_name, email, status) values
  ('d73b0000-0000-0000-0000-0000000000b1','d73b0000-0000-0000-0000-000000000001','One','Member','d73b-b1@t','active'),
  ('d73b0000-0000-0000-0000-0000000000b2','d73b0000-0000-0000-0000-000000000001','Two','Member','d73b-b2@t','active'),
  ('d73b0000-0000-0000-0000-0000000000b3','d73b0000-0000-0000-0000-000000000001','Three','Member','d73b-b3@t','active'),
  ('d73b0000-0000-0000-0000-0000000000b4','d73b0000-0000-0000-0000-000000000001','Four','Member','d73b-b4@t','active');

-- M1 holds TWO unpaid app-booked drop-ins. b_old is the earlier created_at.
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, created_at) values
  ('d73b0000-0000-0000-0000-0000000b1001','d73b0000-0000-0000-0000-000000000001','d73b0000-0000-0000-0000-0000000000f1','d73b0000-0000-0000-0000-0000000000b1','booked','member','drop_in', now()-interval '2 hours'),
  ('d73b0000-0000-0000-0000-0000000b1002','d73b0000-0000-0000-0000-000000000001','d73b0000-0000-0000-0000-0000000000f2','d73b0000-0000-0000-0000-0000000000b1','booked','member','drop_in', now()-interval '1 hour');

-- A drop_in plan purchase for M1, pending, through the Xendit rail.
insert into xendit_purchases (id, studio_id, member_id, plan_id, amount_cents, currency) values
  ('d73b0000-0000-0000-0000-0000000e1001','d73b0000-0000-0000-0000-000000000001','d73b0000-0000-0000-0000-0000000000b1','d73b0000-0000-0000-0000-0000000000d1',15000,'CZK');

-- ---- 1. Activation settles the OLDEST unpaid drop-in; the newer is untouched -
select expect_text('73b: activation returns activated',
  xendit_activate_success_internal('d73b0000-0000-0000-0000-0000000e1001','py_1'), 'activated');

select expect_text('73b: the OLDEST booking flips drop_in -> class_pack',
  (select payment_source::text from bookings where id='d73b0000-0000-0000-0000-0000000b1001'), 'class_pack');
select expect_text('73b: the oldest booking is linked to the new membership',
  (select case when membership_id is not null then 'linked' else 'null' end
     from bookings where id='d73b0000-0000-0000-0000-0000000b1001'), 'linked');
select expect_text('73b: the oldest booking carries a credit_entry_id',
  (select case when credit_entry_id is not null then 'set' else 'null' end
     from bookings where id='d73b0000-0000-0000-0000-0000000b1001'), 'set');
-- The NEWER unpaid booking is left alone (one credit, oldest only).
select expect_text('73b: the NEWER booking stays an unpaid drop-in',
  (select payment_source::text from bookings where id='d73b0000-0000-0000-0000-0000000b1002'), 'drop_in');
select expect_num('73b: the newer booking has no membership',
  (select count(*) from bookings where id='d73b0000-0000-0000-0000-0000000b1002' and membership_id is null), 1);
-- A single -1 'booking' ledger row against the oldest booking.
select expect_num('73b: one booking ledger row for the oldest',
  (select count(*) from credit_ledger where booking_id='d73b0000-0000-0000-0000-0000000b1001' and delta=-1 and reason='booking'), 1);
-- The drop_in membership's one credit is spent.
select expect_num('73b: the membership credit is consumed (0 left)',
  (select credits_remaining from memberships m
     where m.member_id='d73b0000-0000-0000-0000-0000000000b1' and m.plan_id='d73b0000-0000-0000-0000-0000000000d1'), 0);
-- The plan payment itself is recorded against the membership (Decision 40).
select expect_num('73b: a xendit payment is recorded for the plan',
  (select count(*) from payments where member_id='d73b0000-0000-0000-0000-0000000000b1' and provider='xendit' and membership_id is not null), 1);

-- ---- 2. Replay applies nothing twice ----------------------------------------
select expect_text('73b: a replay returns already_succeeded',
  xendit_activate_success_internal('d73b0000-0000-0000-0000-0000000e1001','py_1'), 'already_succeeded');
select expect_text('73b replay: the newer booking is STILL an unpaid drop-in',
  (select payment_source::text from bookings where id='d73b0000-0000-0000-0000-0000000b1002'), 'drop_in');
select expect_num('73b replay: the membership credit stays 0 (no second apply)',
  (select credits_remaining from memberships m
     where m.member_id='d73b0000-0000-0000-0000-0000000000b1' and m.plan_id='d73b0000-0000-0000-0000-0000000000d1'), 0);

-- ---- 3. No unpaid booking: the credit stays unused ---------------------------
insert into xendit_purchases (id, studio_id, member_id, plan_id, amount_cents, currency) values
  ('d73b0000-0000-0000-0000-0000000e2001','d73b0000-0000-0000-0000-000000000001','d73b0000-0000-0000-0000-0000000000b2','d73b0000-0000-0000-0000-0000000000d1',15000,'CZK');
select expect_text('73b none: activation returns activated',
  xendit_activate_success_internal('d73b0000-0000-0000-0000-0000000e2001','py_2'), 'activated');
select expect_num('73b none: with no unpaid booking the credit is unused (1 left)',
  (select credits_remaining from memberships m
     where m.member_id='d73b0000-0000-0000-0000-0000000000b2' and m.plan_id='d73b0000-0000-0000-0000-0000000000d1'), 1);
select expect_num('73b none: no booking ledger row written',
  (select count(*) from credit_ledger cl join memberships m on m.id=cl.membership_id
     where m.member_id='d73b0000-0000-0000-0000-0000000000b2' and cl.reason='booking'), 0);

-- ---- 4. A Stripe pending_payment hold is NOT the apply target ----------------
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, created_at) values
  ('d73b0000-0000-0000-0000-0000000b3001','d73b0000-0000-0000-0000-000000000001','d73b0000-0000-0000-0000-0000000000f7','d73b0000-0000-0000-0000-0000000000b3','pending_payment','member','drop_in', now()-interval '3 hours');
insert into xendit_purchases (id, studio_id, member_id, plan_id, amount_cents, currency) values
  ('d73b0000-0000-0000-0000-0000000e3001','d73b0000-0000-0000-0000-000000000001','d73b0000-0000-0000-0000-0000000000b3','d73b0000-0000-0000-0000-0000000000d1',15000,'CZK');
select expect_text('73b stripe: activation returns activated',
  xendit_activate_success_internal('d73b0000-0000-0000-0000-0000000e3001','py_3'), 'activated');
select expect_text('73b stripe: the pending_payment hold is untouched (still drop_in)',
  (select payment_source::text from bookings where id='d73b0000-0000-0000-0000-0000000b3001'), 'drop_in');
select expect_text('73b stripe: the pending_payment hold keeps its status',
  (select status::text from bookings where id='d73b0000-0000-0000-0000-0000000b3001'), 'pending_payment');
select expect_num('73b stripe: the credit is unused — a hold is not the target (1 left)',
  (select credits_remaining from memberships m
     where m.member_id='d73b0000-0000-0000-0000-0000000000b3' and m.plan_id='d73b0000-0000-0000-0000-0000000000d1'), 1);

-- ---- 5. The helper is idempotent when called directly ------------------------
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, created_at) values
  ('d73b0000-0000-0000-0000-0000000b4001','d73b0000-0000-0000-0000-000000000001','d73b0000-0000-0000-0000-0000000000f8','d73b0000-0000-0000-0000-0000000000b4','booked','member','drop_in', now()-interval '1 hour');
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, starts_on, credits_remaining, expires_on) values
  ('d73b0000-0000-0000-0000-0000000a4001','d73b0000-0000-0000-0000-000000000001','d73b0000-0000-0000-0000-0000000000b4','d73b0000-0000-0000-0000-0000000000d1','active',15000,'CZK',current_date,1,current_date+30);
select expect_text('73b helper: first call settles the booking',
  (select case when apply_plan_to_unpaid('d73b0000-0000-0000-0000-000000000001','d73b0000-0000-0000-0000-0000000000b4','d73b0000-0000-0000-0000-0000000a4001') is not null then 'applied' else 'none' end), 'applied');
select expect_text('73b helper: the booking is now a class_pack seat',
  (select payment_source::text from bookings where id='d73b0000-0000-0000-0000-0000000b4001'), 'class_pack');
select expect_num('73b helper: the credit is spent',
  (select credits_remaining from memberships where id='d73b0000-0000-0000-0000-0000000a4001'), 0);
select expect_text('73b helper: a second call applies nothing (idempotent)',
  (select case when apply_plan_to_unpaid('d73b0000-0000-0000-0000-000000000001','d73b0000-0000-0000-0000-0000000000b4','d73b0000-0000-0000-0000-0000000a4001') is not null then 'applied' else 'none' end), 'none');
select expect_num('73b helper: still one booking ledger row (no double consume)',
  (select count(*) from credit_ledger where membership_id='d73b0000-0000-0000-0000-0000000a4001' and reason='booking'), 1);

-- ---- 6. A 5-class PACK settles one booking and leaves 4 credits --------------
-- (Decision 73b extension: ANY plan settles the held drop-in, not only a drop_in
-- plan. A pack consumes one of its credits through the ledger and links the
-- booking as a class_pack seat.)
insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, validity_days, visibility, status)
  values ('d73b0000-0000-0000-0000-0000000000d2','d73b0000-0000-0000-0000-000000000001','5-Class Pack','class_pack',500000,'CZK',5,60,'public','active');
insert into members (id, studio_id, first_name, last_name, email, status) values
  ('d73b0000-0000-0000-0000-0000000000b5','d73b0000-0000-0000-0000-000000000001','Five','Member','d73b-b5@t','active');
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, created_at) values
  ('d73b0000-0000-0000-0000-0000000b5001','d73b0000-0000-0000-0000-000000000001','d73b0000-0000-0000-0000-0000000000f3','d73b0000-0000-0000-0000-0000000000b5','booked','member','drop_in', now()-interval '1 hour');
insert into xendit_purchases (id, studio_id, member_id, plan_id, amount_cents, currency) values
  ('d73b0000-0000-0000-0000-0000000e5001','d73b0000-0000-0000-0000-000000000001','d73b0000-0000-0000-0000-0000000000b5','d73b0000-0000-0000-0000-0000000000d2',500000,'CZK');
select expect_text('73b pack: activation returns activated',
  xendit_activate_success_internal('d73b0000-0000-0000-0000-0000000e5001','py_5'), 'activated');
select expect_text('73b pack: the unpaid drop-in flips drop_in -> class_pack',
  (select payment_source::text from bookings where id='d73b0000-0000-0000-0000-0000000b5001'), 'class_pack');
select expect_text('73b pack: the booking is linked to the pack membership',
  (select case when membership_id is not null then 'linked' else 'null' end
     from bookings where id='d73b0000-0000-0000-0000-0000000b5001'), 'linked');
select expect_num('73b pack: a 5-class pack has 4 credits left after settling one',
  (select credits_remaining from memberships m
     where m.member_id='d73b0000-0000-0000-0000-0000000000b5' and m.plan_id='d73b0000-0000-0000-0000-0000000000d2'), 4);
select expect_num('73b pack: one booking ledger row against the settled booking',
  (select count(*) from credit_ledger where booking_id='d73b0000-0000-0000-0000-0000000b5001' and delta=-1 and reason='booking'), 1);

-- ---- 7. An UNLIMITED recurring plan links with NO credit consumed ------------
insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits_per_period, billing_interval, billing_interval_count, visibility, status)
  values ('d73b0000-0000-0000-0000-0000000000d3','d73b0000-0000-0000-0000-000000000001','Unlimited Monthly','recurring',800000,'CZK',null,'month',1,'public','active');
insert into members (id, studio_id, first_name, last_name, email, status) values
  ('d73b0000-0000-0000-0000-0000000000b6','d73b0000-0000-0000-0000-000000000001','Six','Member','d73b-b6@t','active');
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, created_at) values
  ('d73b0000-0000-0000-0000-0000000b6001','d73b0000-0000-0000-0000-000000000001','d73b0000-0000-0000-0000-0000000000f4','d73b0000-0000-0000-0000-0000000000b6','booked','member','drop_in', now()-interval '1 hour');
insert into xendit_purchases (id, studio_id, member_id, plan_id, amount_cents, currency) values
  ('d73b0000-0000-0000-0000-0000000e6001','d73b0000-0000-0000-0000-000000000001','d73b0000-0000-0000-0000-0000000000b6','d73b0000-0000-0000-0000-0000000000d3',800000,'CZK');
select expect_text('73b unlimited: activation returns activated',
  xendit_activate_success_internal('d73b0000-0000-0000-0000-0000000e6001','py_6'), 'activated');
select expect_text('73b unlimited: the unpaid drop-in flips drop_in -> membership',
  (select payment_source::text from bookings where id='d73b0000-0000-0000-0000-0000000b6001'), 'membership');
select expect_text('73b unlimited: the booking is linked to the membership',
  (select case when membership_id is not null then 'linked' else 'null' end
     from bookings where id='d73b0000-0000-0000-0000-0000000b6001'), 'linked');
select expect_text('73b unlimited: NO credit is consumed — the booking carries no credit_entry_id',
  (select case when credit_entry_id is not null then 'set' else 'null' end
     from bookings where id='d73b0000-0000-0000-0000-0000000b6001'), 'null');
select expect_num('73b unlimited: no booking ledger row written',
  (select count(*) from credit_ledger where booking_id='d73b0000-0000-0000-0000-0000000b6001' and reason='booking'), 0);
select expect_text('73b unlimited: credits_remaining stays unlimited (null)',
  (select case when credits_remaining is null then 'unlimited' else credits_remaining::text end
     from memberships m where m.member_id='d73b0000-0000-0000-0000-0000000000b6' and m.plan_id='d73b0000-0000-0000-0000-0000000000d3'), 'unlimited');

-- ---- 8. A plan that does NOT cover the class leaves the booking untouched -----
-- A pack restricted to another class type (c2) cannot settle a drop-in on a c1
-- class. The membership is still activated (its credits granted), but the apply
-- finds the plan does not cover the held class and leaves it alone.
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('d73b0000-0000-0000-0000-0000000000c2','d73b0000-0000-0000-0000-000000000001','Mat',50,6);
insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, validity_days, visibility, status, restrictions)
  values ('d73b0000-0000-0000-0000-0000000000d4','d73b0000-0000-0000-0000-000000000001','Mat 5-Pack','class_pack',400000,'CZK',5,60,'public','active',
          jsonb_build_object('class_type_ids', jsonb_build_array('d73b0000-0000-0000-0000-0000000000c2')));
insert into members (id, studio_id, first_name, last_name, email, status) values
  ('d73b0000-0000-0000-0000-0000000000b7','d73b0000-0000-0000-0000-000000000001','Seven','Member','d73b-b7@t','active');
-- The unpaid drop-in is on f5, a Reformer (c1) class — NOT covered by the Mat pack.
insert into bookings (id, studio_id, occurrence_id, member_id, status, source, payment_source, created_at) values
  ('d73b0000-0000-0000-0000-0000000b7001','d73b0000-0000-0000-0000-000000000001','d73b0000-0000-0000-0000-0000000000f5','d73b0000-0000-0000-0000-0000000000b7','booked','member','drop_in', now()-interval '1 hour');
insert into xendit_purchases (id, studio_id, member_id, plan_id, amount_cents, currency) values
  ('d73b0000-0000-0000-0000-0000000e7001','d73b0000-0000-0000-0000-000000000001','d73b0000-0000-0000-0000-0000000000b7','d73b0000-0000-0000-0000-0000000000d4',400000,'CZK');
select expect_text('73b non-covering: activation returns activated',
  xendit_activate_success_internal('d73b0000-0000-0000-0000-0000000e7001','py_7'), 'activated');
select expect_text('73b non-covering: the drop-in on an uncovered class stays unpaid (drop_in)',
  (select payment_source::text from bookings where id='d73b0000-0000-0000-0000-0000000b7001'), 'drop_in');
select expect_num('73b non-covering: the booking is NOT linked to the membership',
  (select count(*) from bookings where id='d73b0000-0000-0000-0000-0000000b7001' and membership_id is null), 1);
select expect_num('73b non-covering: the pack keeps all 5 credits (none consumed)',
  (select credits_remaining from memberships m
     where m.member_id='d73b0000-0000-0000-0000-0000000000b7' and m.plan_id='d73b0000-0000-0000-0000-0000000000d4'), 5);
select expect_num('73b non-covering: no booking ledger row written',
  (select count(*) from credit_ledger where booking_id='d73b0000-0000-0000-0000-0000000b7001' and reason='booking'), 0);

-- ---- 9. Anon surface stays EXACTLY THIRTEEN ----------------------------------
select expect_num('73b: anon surface is exactly thirteen',
  (select count(*) from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
     where ns.nspname='public' and has_function_privilege('anon', p.oid, 'execute')
       and p.proname not like 'expect_%' and p.proname not in ('login','sig','psig')), 13);

do $$ begin raise notice 'ALL DECISION 73b ASSERTIONS PASSED'; end $$;
