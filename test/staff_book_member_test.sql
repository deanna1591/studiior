-- =============================================================================
-- Decision 100 — staff book for a member, and edit a member's phone.
-- Migration 20260833400000. UUID space 100b, checked free. After `supabase db reset`.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$ begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$ begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if; end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$ begin
  if coalesce(actual,false) then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_false(label text, actual boolean)
returns void language plpgsql as $$ begin
  if not coalesce(actual,true) then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected false, got %', label, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_like(label text, actual text, pattern text)
returns void language plpgsql as $$ begin
  if actual like pattern then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  % not like %', label, coalesce(actual,'null'), pattern; end if; end $$;
create or replace function expect_raise(label text, code text, sql text)
returns void language plpgsql as $$ begin
  begin execute sql; raise exception 'FAIL  %  expected %, no error', label, code;
  exception when others then
    if sqlstate = code then raise notice 'PASS  %  (%)', label, code;
    else raise exception 'FAIL  %  expected %, got % (%)', label, code, sqlstate, sqlerrm; end if; end; end $$;

-- helper: does the options jsonb contain an option of a given kind?
create or replace function has_opt(opts jsonb, kind text) returns boolean language sql as $$
  select exists (select 1 from jsonb_array_elements(opts->'options') o where o->>'kind' = kind);
$$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('100b0000-0000-0000-0000-0000000000a1'),  -- A owner
  ('100b0000-0000-0000-0000-0000000000f1'),  -- A front desk
  ('100b0000-0000-0000-0000-0000000000b1');  -- B owner
insert into profiles (id, email, full_name) values
  ('100b0000-0000-0000-0000-0000000000a1','a-own@100b.example','Olga Owner'),
  ('100b0000-0000-0000-0000-0000000000f1','a-fd@100b.example','Fred Desk'),
  ('100b0000-0000-0000-0000-0000000000b1','b-own@100b.example','Boris B');

insert into studios (id, name, slug, timezone, currency, country, status) values
  ('100b0000-0000-0000-0000-000000000001','Book A','100b-a','Asia/Manila','PHP','PH','active'),
  ('100b0000-0000-0000-0000-000000000002','Book B','100b-b','Asia/Manila','PHP','PH','active');
insert into studio_settings (studio_id, free_first_class_enabled, free_first_peak_allowed,
                             checkin_window_enforced, require_waiver, cancellation_cutoff_minutes,
                             booking_window_days, max_unpaid_bookings, desk_pay_mode, payment_grace_days) values
  ('100b0000-0000-0000-0000-000000000001', true, true, false, false, 720, 60, 1, 'earned', 7),
  ('100b0000-0000-0000-0000-000000000002', true, true, false, false, 720, 60, 1, 'earned', 7);
insert into locations (id, studio_id, name, is_primary) values
  ('100b0000-0000-0000-0000-00000000000a','100b0000-0000-0000-0000-000000000001','Main',true),
  ('100b0000-0000-0000-0000-00000000000b','100b0000-0000-0000-0000-000000000002','Main',true);

insert into studio_staff (id, studio_id, user_id, email, role, status) values
  ('100b0000-0000-0000-0000-0000000000e1','100b0000-0000-0000-0000-000000000001','100b0000-0000-0000-0000-0000000000a1','a-own@100b.example','owner','active'),
  ('100b0000-0000-0000-0000-0000000000e2','100b0000-0000-0000-0000-000000000001','100b0000-0000-0000-0000-0000000000f1','a-fd@100b.example','front_desk','active'),
  ('100b0000-0000-0000-0000-0000000000e3','100b0000-0000-0000-0000-000000000002','100b0000-0000-0000-0000-0000000000b1','b-own@100b.example','owner','active');

insert into class_types (id, studio_id, name, default_capacity, duration_minutes, color, status) values
  ('100b0000-0000-0000-0000-0000000000c1','100b0000-0000-0000-0000-000000000001','Reformer',6,50,'#B85C38','active'),
  ('100b0000-0000-0000-0000-0000000000c2','100b0000-0000-0000-0000-000000000001','Barre',6,50,'#7A6F63','active');

-- class C1 (Reformer, future), C2 (Reformer, future, for a second booking)
insert into class_occurrences (id, studio_id, location_id, class_type_id, name, capacity, starts_at, ends_at, status)
values
  ('100b0000-0000-0000-0000-0000000000d1','100b0000-0000-0000-0000-000000000001','100b0000-0000-0000-0000-00000000000a','100b0000-0000-0000-0000-0000000000c1','Reformer',6, now()+interval '2 days', now()+interval '2 days'+interval '50 min','scheduled'),
  ('100b0000-0000-0000-0000-0000000000d2','100b0000-0000-0000-0000-000000000001','100b0000-0000-0000-0000-00000000000a','100b0000-0000-0000-0000-0000000000c1','Reformer',6, now()+interval '3 days', now()+interval '3 days'+interval '50 min','scheduled'),
  ('100b0000-0000-0000-0000-0000000000d3','100b0000-0000-0000-0000-000000000001','100b0000-0000-0000-0000-00000000000a','100b0000-0000-0000-0000-0000000000c1','Reformer',6, now()+interval '4 days', now()+interval '4 days'+interval '50 min','scheduled');

-- plans: a pack covering all; a pack restricted to Barre (c2); a public drop-in.
insert into membership_plans (id, studio_id, name, type, credits, price_cents, currency, validity_days, visibility, status) values
  ('100b0000-0000-0000-0000-0000000000a2','100b0000-0000-0000-0000-000000000001','5-Class Pack','class_pack',5,500000,'PHP',90,'public','active'),
  ('100b0000-0000-0000-0000-0000000000a4','100b0000-0000-0000-0000-000000000001','Single Drop-in','drop_in',1,15000,'PHP',30,'public','active');
insert into membership_plans (id, studio_id, name, type, credits, price_cents, currency, validity_days, visibility, status, restrictions) values
  ('100b0000-0000-0000-0000-0000000000a3','100b0000-0000-0000-0000-000000000001','Barre Pack','class_pack',5,500000,'PHP',90,'public','active',
   jsonb_build_object('class_type_ids', jsonb_build_array('100b0000-0000-0000-0000-0000000000c2')));

-- members: M_PLAN (pack 3 left), M_LEAD (free eligible), M_USED (used free),
-- M_RESTRICT (Barre pack only), M_DROP (for drop-in paid), M_CAP (holds 1 unpaid),
-- M_PHONE (phone edit).
insert into members (id, studio_id, first_name, last_name, email, status, phone) values
  ('100b0000-0000-0000-0000-0000000000f2','100b0000-0000-0000-0000-000000000001','Mona','Plan','m1@100b.example','active', null),
  ('100b0000-0000-0000-0000-0000000000f3','100b0000-0000-0000-0000-000000000001','Lee','Lead','m2@100b.example','lead', null),
  ('100b0000-0000-0000-0000-0000000000f4','100b0000-0000-0000-0000-000000000001','Uma','Used','m3@100b.example','lead', null),
  ('100b0000-0000-0000-0000-0000000000f5','100b0000-0000-0000-0000-000000000001','Rita','Restrict','m4@100b.example','active', null),
  ('100b0000-0000-0000-0000-0000000000f6','100b0000-0000-0000-0000-000000000001','Dan','Drop','m5@100b.example','lead', null),
  ('100b0000-0000-0000-0000-0000000000f7','100b0000-0000-0000-0000-000000000001','Cap','Member','m6@100b.example','lead', null),
  ('100b0000-0000-0000-0000-0000000000f8','100b0000-0000-0000-0000-000000000001','Pia','Phone','m7@100b.example','active', null);

-- M_PLAN holds the covering pack with 3 credits.
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, credits_remaining, starts_on, expires_on)
values ('100b0000-0000-0000-0000-0000000000fa','100b0000-0000-0000-0000-000000000001','100b0000-0000-0000-0000-0000000000f2','100b0000-0000-0000-0000-0000000000a2','active',500000,'PHP',3,current_date,current_date+90);
insert into credit_ledger (studio_id, member_id, membership_id, delta, reason, balance_after)
values ('100b0000-0000-0000-0000-000000000001','100b0000-0000-0000-0000-0000000000f2','100b0000-0000-0000-0000-0000000000fa',3,'purchase',3);

-- M_RESTRICT holds the Barre-only pack.
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency, credits_remaining, starts_on, expires_on)
values ('100b0000-0000-0000-0000-0000000000fb','100b0000-0000-0000-0000-000000000001','100b0000-0000-0000-0000-0000000000f5','100b0000-0000-0000-0000-0000000000a3','active',500000,'PHP',5,current_date,current_date+90);

-- M_USED used their free class and LATE-cancelled it (post the Decision 30d
-- cut-over): member_has_had_free true, eligibility reason late_cancel, which the
-- manager-up override (convert_booking_to_free_first) can override.
insert into bookings (id, studio_id, member_id, occurrence_id, status, payment_source, cancelled_at)
values ('100b0000-0000-0000-0000-0000000000bc','100b0000-0000-0000-0000-000000000001','100b0000-0000-0000-0000-0000000000f4','100b0000-0000-0000-0000-0000000000d3','late_cancelled','comp', now());
insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email, occurrence_id, guest_booking_id, status)
values ('100b0000-0000-0000-0000-000000000001', null, '100b0000-0000-0000-0000-0000000000f4','m3@100b.example','100b0000-0000-0000-0000-0000000000d3','100b0000-0000-0000-0000-0000000000bc','cancelled');

-- M_CAP holds one unpaid drop-in (the cap is 1).
insert into bookings (id, studio_id, member_id, occurrence_id, status, payment_source)
values ('100b0000-0000-0000-0000-0000000000bd','100b0000-0000-0000-0000-000000000001','100b0000-0000-0000-0000-0000000000f7','100b0000-0000-0000-0000-0000000000d3','booked','drop_in');


\echo ''
\echo '=== 1. OPTIONS per member state ==='
reset role; set role authenticated; select set_config('request.jwt.claim.sub','100b0000-0000-0000-0000-0000000000a1',false);  -- owner

-- M_PLAN: plan + drop_in_paid + drop_in_later + override + complimentary
select expect_true('owner options(M_PLAN) has a plan',
  has_opt(staff_booking_options('100b0000-0000-0000-0000-0000000000f2','100b0000-0000-0000-0000-0000000000d1'),'plan'));
select expect_true('owner options(M_PLAN) has drop_in_paid with a price',
  (staff_booking_options('100b0000-0000-0000-0000-0000000000f2','100b0000-0000-0000-0000-0000000000d1')
    #>> '{options}') like '%"price_cents": 15000%');
select expect_true('owner options(M_PLAN) has complimentary',
  has_opt(staff_booking_options('100b0000-0000-0000-0000-0000000000f2','100b0000-0000-0000-0000-0000000000d1'),'complimentary'));
select expect_true('owner options(M_PLAN) offers free_first (eligible, never took one)',
  has_opt(staff_booking_options('100b0000-0000-0000-0000-0000000000f2','100b0000-0000-0000-0000-0000000000d1'),'free_first'));
-- M_USED took a free class already -> override for manager-up.
select expect_true('owner options(M_USED) offers free_first_override (not eligible)',
  has_opt(staff_booking_options('100b0000-0000-0000-0000-0000000000f4','100b0000-0000-0000-0000-0000000000d1'),'free_first_override'));
select expect_false('owner options(M_USED) does NOT offer plain free_first',
  has_opt(staff_booking_options('100b0000-0000-0000-0000-0000000000f4','100b0000-0000-0000-0000-0000000000d1'),'free_first'));
select expect_like('owner options(M_PLAN) plan label shows credits',
  (select o->>'label' from jsonb_array_elements(
     (staff_booking_options('100b0000-0000-0000-0000-0000000000f2','100b0000-0000-0000-0000-0000000000d1')->'options')) o
    where o->>'kind'='plan' limit 1), '%5-Class Pack, 3 of 5 credits%');
select expect_num('owner options(M_PLAN) preselect is the plan (0)',
  (staff_booking_options('100b0000-0000-0000-0000-0000000000f2','100b0000-0000-0000-0000-0000000000d1')->>'preselect')::int, 0);

-- M_LEAD as FRONT DESK: free_first present, NO complimentary, NO override.
reset role; set role authenticated; select set_config('request.jwt.claim.sub','100b0000-0000-0000-0000-0000000000f1',false);
select expect_true('front-desk options(M_LEAD) has free_first (eligible)',
  has_opt(staff_booking_options('100b0000-0000-0000-0000-0000000000f3','100b0000-0000-0000-0000-0000000000d1'),'free_first'));
select expect_false('front-desk options(M_LEAD) has NO complimentary',
  has_opt(staff_booking_options('100b0000-0000-0000-0000-0000000000f3','100b0000-0000-0000-0000-0000000000d1'),'complimentary'));
select expect_false('front-desk options(M_LEAD) has NO free_first_override',
  has_opt(staff_booking_options('100b0000-0000-0000-0000-0000000000f3','100b0000-0000-0000-0000-0000000000d1'),'free_first_override'));
select expect_true('front-desk options(M_LEAD) has drop_in_later (cap allows)',
  has_opt(staff_booking_options('100b0000-0000-0000-0000-0000000000f3','100b0000-0000-0000-0000-0000000000d1'),'drop_in_later'));

-- M_CAP already holds one unpaid drop-in -> NO drop_in_later.
select expect_false('options(M_CAP) has NO drop_in_later (cap reached)',
  has_opt(staff_booking_options('100b0000-0000-0000-0000-0000000000f7','100b0000-0000-0000-0000-0000000000d1'),'drop_in_later'));

\echo ''
\echo '=== 2. BOOKING through the existing paths ==='
reset role; set role authenticated; select set_config('request.jwt.claim.sub','100b0000-0000-0000-0000-0000000000a1',false);  -- owner

-- plan: pins the pack, consumes a credit.
select expect_true('book M_PLAN with the pinned plan -> ok',
  (staff_book_member('100b0000-0000-0000-0000-0000000000f2','100b0000-0000-0000-0000-0000000000d1',
     jsonb_build_object('kind','plan','membership_id','100b0000-0000-0000-0000-0000000000fa'), null) ->> 'ok')::boolean);
select expect_num('the pack is down to 2 credits',
  (select credits_remaining from memberships where id='100b0000-0000-0000-0000-0000000000fa'), 2);
select expect_num('M_PLAN has one live booking on d1',
  (select count(*) from bookings where member_id='100b0000-0000-0000-0000-0000000000f2' and occurrence_id='100b0000-0000-0000-0000-0000000000d1' and status<>'cancelled'), 1);
select expect_true('an audit booking.booked_by_staff row for M_PLAN',
  exists(select 1 from audit_logs where action='booking.booked_by_staff' and entity_id='100b0000-0000-0000-0000-0000000000f2'));
-- Journey: member_activity shows "Booked by Olga with a plan".
select expect_like('Journey shows "Booked by Olga with a plan"',
  (select title from member_activity('100b0000-0000-0000-0000-0000000000f2', current_date-1, current_date+10)
    where kind='booked_by_staff' limit 1), 'Booked by Olga with a plan');

-- pinned plan that does not cover (Barre pack on a Reformer class) -> plan_not_covering.
select expect_text('pinned non-covering plan -> plan_not_covering',
  staff_book_member('100b0000-0000-0000-0000-0000000000f5','100b0000-0000-0000-0000-0000000000d1',
    jsonb_build_object('kind','plan','membership_id','100b0000-0000-0000-0000-0000000000fb'), null) ->> 'reason',
  'plan_not_covering');

-- free_first (M_LEAD) as front desk -> comp seat via book_first_free.
reset role; set role authenticated; select set_config('request.jwt.claim.sub','100b0000-0000-0000-0000-0000000000f1',false);
select expect_true('front desk books M_LEAD free_first -> ok',
  (staff_book_member('100b0000-0000-0000-0000-0000000000f3','100b0000-0000-0000-0000-0000000000d1',
     jsonb_build_object('kind','free_first'), null) ->> 'ok')::boolean);
select expect_text('the free_first seat is comp',
  (select payment_source::text from bookings where member_id='100b0000-0000-0000-0000-0000000000f3' and occurrence_id='100b0000-0000-0000-0000-0000000000d1' and status<>'cancelled' limit 1), 'comp');

-- free_first_override (M_USED, not eligible) as owner -> comp seat via convert.
reset role; set role authenticated; select set_config('request.jwt.claim.sub','100b0000-0000-0000-0000-0000000000a1',false);
select expect_true('owner override-books M_USED free first -> ok',
  (staff_book_member('100b0000-0000-0000-0000-0000000000f4','100b0000-0000-0000-0000-0000000000d1',
     jsonb_build_object('kind','free_first_override'), null) ->> 'ok')::boolean);
select expect_text('the override seat is comp',
  (select payment_source::text from bookings where member_id='100b0000-0000-0000-0000-0000000000f4' and occurrence_id='100b0000-0000-0000-0000-0000000000d1' and status<>'cancelled' limit 1), 'comp');

-- drop_in_paid (M_DROP) as front desk -> a succeeded payment.
reset role; set role authenticated; select set_config('request.jwt.claim.sub','100b0000-0000-0000-0000-0000000000f1',false);
select expect_true('front desk drop_in_paid M_DROP -> ok',
  (staff_book_member('100b0000-0000-0000-0000-0000000000f6','100b0000-0000-0000-0000-0000000000d1',
     jsonb_build_object('kind','drop_in_paid','method','cash','amount_cents',15000), null) ->> 'ok')::boolean);
select expect_num('a succeeded payment exists for M_DROP',
  (select count(*) from payments where member_id='100b0000-0000-0000-0000-0000000000f6' and status='succeeded'), 1);

-- drop_in_later when the cap is reached (M_CAP) -> pay_first.
select expect_text('drop_in_later over the unpaid cap -> pay_first',
  staff_book_member('100b0000-0000-0000-0000-0000000000f7','100b0000-0000-0000-0000-0000000000d1',
    jsonb_build_object('kind','drop_in_later'), null) ->> 'reason', 'pay_first');

-- complimentary (owner) -> comp seat with reason staff_comp.
reset role; set role authenticated; select set_config('request.jwt.claim.sub','100b0000-0000-0000-0000-0000000000a1',false);
-- A comp needs an active member (Decision 15: a lead books drop-in only), so
-- give it to M_RESTRICT (active). Its Barre pack does not cover Reformer d2, so
-- the comp path is what seats them.
select expect_true('owner complimentary M_RESTRICT on d2 -> ok',
  (staff_book_member('100b0000-0000-0000-0000-0000000000f5','100b0000-0000-0000-0000-0000000000d2',
     jsonb_build_object('kind','complimentary'), null) ->> 'ok')::boolean);
select expect_text('the comp booking payment_source is comp',
  (select payment_source::text from bookings where member_id='100b0000-0000-0000-0000-0000000000f5' and occurrence_id='100b0000-0000-0000-0000-0000000000d2' limit 1), 'comp');
-- The staff-comp attribution lives on the audit + Journey (the booking row's
-- override_reason only records a bypassed rule).
select expect_like('Journey shows "Booked by Olga with a complimentary seat"',
  (select title from member_activity('100b0000-0000-0000-0000-0000000000f5', current_date-1, current_date+10)
    where kind='booked_by_staff' limit 1), 'Booked by Olga with a complimentary seat');

\echo ''
\echo '=== 3. ROLE + CROSS-STUDIO refusals ==='
reset role; set role authenticated; select set_config('request.jwt.claim.sub','100b0000-0000-0000-0000-0000000000f1',false);  -- front desk
select expect_raise('front desk cannot override free first (PT403)','PT403'::text,
  $q$ select staff_book_member('100b0000-0000-0000-0000-0000000000f4','100b0000-0000-0000-0000-0000000000d2', jsonb_build_object('kind','free_first_override'), null) $q$);
select expect_raise('front desk cannot give complimentary (PT403)','PT403'::text,
  $q$ select staff_book_member('100b0000-0000-0000-0000-0000000000f3','100b0000-0000-0000-0000-0000000000d2', jsonb_build_object('kind','complimentary'), null) $q$);

reset role; set role authenticated; select set_config('request.jwt.claim.sub','100b0000-0000-0000-0000-0000000000b1',false);  -- B owner on A
select expect_raise('cross-studio staff_booking_options -> PT403','PT403'::text,
  $q$ select staff_booking_options('100b0000-0000-0000-0000-0000000000f2','100b0000-0000-0000-0000-0000000000d1') $q$);
select expect_raise('cross-studio staff_book_member -> PT403','PT403'::text,
  $q$ select staff_book_member('100b0000-0000-0000-0000-0000000000f2','100b0000-0000-0000-0000-0000000000d2', jsonb_build_object('kind','plan','membership_id','100b0000-0000-0000-0000-0000000000fa'), null) $q$);

\echo ''
\echo '=== 4. PHONE edit ==='
reset role; set role authenticated; select set_config('request.jwt.claim.sub','100b0000-0000-0000-0000-0000000000f1',false);  -- front desk (desk-up)
select expect_text('front desk sets a PH mobile -> E.164',
  staff_set_member_phone('100b0000-0000-0000-0000-0000000000f8','09171234567') ->> 'phone', '+639171234567');
select expect_text('the member row now holds the E.164 phone',
  (select phone from members where id='100b0000-0000-0000-0000-0000000000f8'), '+639171234567');
select expect_raise('a bad number is refused (PT422)','PT422'::text,
  $q$ select staff_set_member_phone('100b0000-0000-0000-0000-0000000000f8','12') $q$);
reset role; set role authenticated; select set_config('request.jwt.claim.sub','100b0000-0000-0000-0000-0000000000b1',false);
select expect_raise('cross-studio phone edit -> PT403','PT403'::text,
  $q$ select staff_set_member_phone('100b0000-0000-0000-0000-0000000000f8','09181234567') $q$);
reset role; set role authenticated; select set_config('request.jwt.claim.sub','100b0000-0000-0000-0000-0000000000a1',false);
select expect_true('a member.phone_changed audit row exists',
  exists(select 1 from audit_logs where action='member.phone_changed' and entity_id='100b0000-0000-0000-0000-0000000000f8'));

\echo ''
\echo '=== 5. the new functions are not anon + anon THIRTEEN ==='
reset role;
select expect_false('staff_book_member not anon',
  has_function_privilege('anon','public.staff_book_member(uuid,uuid,jsonb,text)','execute'));
select expect_false('staff_booking_options not anon',
  has_function_privilege('anon','public.staff_booking_options(uuid,uuid)','execute'));
select expect_false('staff_set_member_phone not anon',
  has_function_privilege('anon','public.staff_set_member_phone(uuid,text)','execute'));
select expect_num('anon surface EXACTLY THIRTEEN',
  (select count(*) from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
    where ns.nspname='public' and has_function_privilege('anon',p.oid,'execute')
      and p.proname not like 'expect_%' and p.proname not in ('has_opt','act')), 13);

\echo ''
\echo 'ALL DECISION 100 (staff book for a member) ASSERTIONS PASSED'
