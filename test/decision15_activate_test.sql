-- =============================================================================
-- Decision 15 amendment — a purchase activates the member.
-- Migration 20260833410000. UUID space 15ac, checked free. After `supabase db reset`.
--
-- The exact failed path: a lead buys an intro offer ONLINE, then book_class with
-- that plan succeeds. "Online" is activate_purchase in service context, which is
-- exactly what the Xendit webhook (xendit_activate_success_internal) calls.
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

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('15ac0000-0000-0000-0000-0000000000a1'),  -- owner (desk)
  ('15ac0000-0000-0000-0000-0000000000f2');  -- M_LEAD login (bought online)
insert into profiles (id, email, full_name) values
  ('15ac0000-0000-0000-0000-0000000000a1','own@15ac.example','Olga Owner'),
  ('15ac0000-0000-0000-0000-0000000000f2','lead@15ac.example','Lea Lead');

insert into studios (id, name, slug, timezone, currency, country, status) values
  ('15ac0000-0000-0000-0000-000000000001','Activate A','15ac-a','Asia/Manila','PHP','PH','active');
insert into studio_settings (studio_id, free_first_class_enabled, checkin_window_enforced,
                             require_waiver, cancellation_cutoff_minutes, booking_window_days,
                             max_unpaid_bookings, desk_pay_mode, payment_grace_days) values
  ('15ac0000-0000-0000-0000-000000000001', false, false, false, 720, 60, 1, 'earned', 7);
insert into locations (id, studio_id, name, is_primary) values
  ('15ac0000-0000-0000-0000-00000000000a','15ac0000-0000-0000-0000-000000000001','Main',true);
insert into studio_staff (id, studio_id, user_id, email, role, status) values
  ('15ac0000-0000-0000-0000-0000000000e1','15ac0000-0000-0000-0000-000000000001','15ac0000-0000-0000-0000-0000000000a1','own@15ac.example','owner','active');

insert into class_types (id, studio_id, name, default_capacity, duration_minutes, color, status) values
  ('15ac0000-0000-0000-0000-0000000000c1','15ac0000-0000-0000-0000-000000000001','Reformer',6,50,'#B85C38','active');
insert into class_occurrences (id, studio_id, location_id, class_type_id, name, capacity, starts_at, ends_at, status) values
  ('15ac0000-0000-0000-0000-0000000000d1','15ac0000-0000-0000-0000-000000000001','15ac0000-0000-0000-0000-00000000000a','15ac0000-0000-0000-0000-0000000000c1','Reformer',6, now()+interval '2 days', now()+interval '2 days'+interval '50 min','scheduled');

-- plans: the intro offer (trial, 3 classes) and a pack (desk sale).
insert into membership_plans (id, studio_id, name, type, credits, price_cents, currency, validity_days, visibility, status) values
  ('15ac0000-0000-0000-0000-0000000000a2','15ac0000-0000-0000-0000-000000000001','Intro Offer','trial',3,179900,'PHP',14,'public','active'),
  ('15ac0000-0000-0000-0000-0000000000a3','15ac0000-0000-0000-0000-000000000001','5-Class Pack','class_pack',5,500000,'PHP',90,'public','active');

-- members: all leads except the two that must not be touched.
insert into members (id, studio_id, first_name, last_name, email, status, user_id) values
  ('15ac0000-0000-0000-0000-0000000000f2','15ac0000-0000-0000-0000-000000000001','Lea','Lead','lead@15ac.example','lead','15ac0000-0000-0000-0000-0000000000f2');
insert into members (id, studio_id, first_name, last_name, email, status) values
  ('15ac0000-0000-0000-0000-0000000000f3','15ac0000-0000-0000-0000-000000000001','Desi','Desk','desk@15ac.example','lead'),
  ('15ac0000-0000-0000-0000-0000000000f4','15ac0000-0000-0000-0000-000000000001','Ina','Active','ina@15ac.example','inactive'),
  ('15ac0000-0000-0000-0000-0000000000f5','15ac0000-0000-0000-0000-000000000001','Archie','Ved','arch@15ac.example','archived'),
  ('15ac0000-0000-0000-0000-0000000000f6','15ac0000-0000-0000-0000-000000000001','Bill','Fill','bf@15ac.example','lead');

-- =============================================================================
-- 1. THE FAILED PATH — a lead buys the intro offer online, becomes active, books.
-- =============================================================================
-- before: a lead
select expect_text('before: M_LEAD is a lead',
  (select status::text from members where id='15ac0000-0000-0000-0000-0000000000f2'), 'lead');

-- online purchase = activate_purchase in service context (the Xendit webhook path)
select activate_purchase('15ac0000-0000-0000-0000-000000000001','15ac0000-0000-0000-0000-0000000000f2',
  '15ac0000-0000-0000-0000-0000000000a2', 179900, 'PHP', null, null, false);

select expect_text('online purchase flips M_LEAD to active',
  (select status::text from members where id='15ac0000-0000-0000-0000-0000000000f2'), 'active');
select expect_num('one member_activated event',
  (select count(*) from membership_events me join memberships ms on ms.id=me.membership_id
    where ms.member_id='15ac0000-0000-0000-0000-0000000000f2' and me.type='member_activated'), 1);
select expect_num('one member.status_changed audit',
  (select count(*) from audit_logs where entity_id='15ac0000-0000-0000-0000-0000000000f2'
    and action='member.status_changed'), 1);

-- the exact failed path: book_class with that plan now succeeds (not member_not_active)
set role authenticated;
select set_config('request.jwt.claim.sub','15ac0000-0000-0000-0000-0000000000f2', false);
select expect_text('book_class succeeds after purchase (no member_not_active)',
  (book_class('15ac0000-0000-0000-0000-0000000000d1','15ac0000-0000-0000-0000-0000000000f2',
     'member', null, null, null)).failure_reason, null);
reset role;
select expect_num('booking exists and is booked',
  (select count(*) from bookings where occurrence_id='15ac0000-0000-0000-0000-0000000000d1'
    and member_id='15ac0000-0000-0000-0000-0000000000f2' and status='booked'), 1);

-- =============================================================================
-- 2. DESK SALE — record_manual_payment as a desk-up owner flips the lead.
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','15ac0000-0000-0000-0000-0000000000a1', false);
select record_manual_payment('15ac0000-0000-0000-0000-000000000001','15ac0000-0000-0000-0000-0000000000f3',
  'plan', 500000, 'cash', '15ac0000-0000-0000-0000-0000000000a3', null, 'PHP', null, null, null, null);
reset role;
select expect_text('desk sale flips M_DESK to active',
  (select status::text from members where id='15ac0000-0000-0000-0000-0000000000f3'), 'active');

-- =============================================================================
-- 3. INACTIVE / ARCHIVED are not touched (the trigger only flips 'lead').
-- =============================================================================
select activate_purchase('15ac0000-0000-0000-0000-000000000001','15ac0000-0000-0000-0000-0000000000f4',
  '15ac0000-0000-0000-0000-0000000000a3', 500000, 'PHP', null, null, false);
select expect_text('inactive member stays inactive',
  (select status::text from members where id='15ac0000-0000-0000-0000-0000000000f4'), 'inactive');
select activate_purchase('15ac0000-0000-0000-0000-000000000001','15ac0000-0000-0000-0000-0000000000f5',
  '15ac0000-0000-0000-0000-0000000000a3', 500000, 'PHP', null, null, false);
select expect_text('archived member stays archived',
  (select status::text from members where id='15ac0000-0000-0000-0000-0000000000f5'), 'archived');
select expect_num('no member_activated event for inactive/archived',
  (select count(*) from membership_events me join memberships ms on ms.id=me.membership_id
    where ms.member_id in ('15ac0000-0000-0000-0000-0000000000f4','15ac0000-0000-0000-0000-0000000000f5')
      and me.type='member_activated'), 0);

-- =============================================================================
-- 4. BACKFILL — a lead already holding an active membership (pre-amendment
--    state) is activated once by the backfill loop, idempotently.
-- =============================================================================
-- stage the stuck state: disable the trigger, create a lead + active membership.
alter table memberships disable trigger membership_activates_lead;
insert into memberships (id, studio_id, member_id, plan_id, status, price_cents, currency,
                         credits_remaining, starts_on)
values ('15ac0000-0000-0000-0000-0000000000b1','15ac0000-0000-0000-0000-000000000001',
        '15ac0000-0000-0000-0000-0000000000f6','15ac0000-0000-0000-0000-0000000000a3','active',
        500000,'PHP',5, current_date);
alter table memberships enable trigger membership_activates_lead;
select expect_text('staged: M_BACKFILL still a lead with an active membership',
  (select status::text from members where id='15ac0000-0000-0000-0000-0000000000f6'), 'lead');

-- run the backfill loop (the migration's logic) and assert the flip + one audit.
do $$
declare r record;
begin
  for r in
    select distinct on (m.id) m.id as member_id, m.studio_id, ms.id as membership_id
      from members m join memberships ms on ms.member_id=m.id and ms.status in ('active','trialing')
     where m.status='lead' and m.deleted_at is null order by m.id, ms.created_at
  loop
    update members set status='active', updated_at=now() where id=r.member_id and status='lead';
    insert into membership_events (studio_id, membership_id, type, actor_user_id, metadata)
      values (r.studio_id, r.membership_id, 'member_activated', null,
              jsonb_build_object('member_from','lead','member_to','active','reason','purchase','backfill',true));
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
      values (r.studio_id, null, 'member.status_changed', 'members', r.member_id,
              jsonb_build_object('status','lead'),
              jsonb_build_object('status','active','note','lead to active, Decision 15 amendment backfill'));
  end loop;
end $$;
select expect_text('backfill flips M_BACKFILL to active',
  (select status::text from members where id='15ac0000-0000-0000-0000-0000000000f6'), 'active');
select expect_num('backfill wrote one audit row',
  (select count(*) from audit_logs where entity_id='15ac0000-0000-0000-0000-0000000000f6'
    and action='member.status_changed' and after->>'note' like '%backfill%'), 1);

-- idempotent: a second backfill pass touches no one (nobody is a lead now).
do $$
declare r record;
begin
  for r in
    select distinct on (m.id) m.id as member_id from members m
      join memberships ms on ms.member_id=m.id and ms.status in ('active','trialing')
     where m.status='lead' and m.deleted_at is null order by m.id
  loop raise exception 'backfill not idempotent: % still a lead', r.member_id; end loop;
end $$;
select expect_num('backfill idempotent: still one audit row for M_BACKFILL',
  (select count(*) from audit_logs where entity_id='15ac0000-0000-0000-0000-0000000000f6'
    and action='member.status_changed'), 1);

-- --- anon surface unchanged (excluding this suite's own expect_* helpers) -----
select expect_num('anon surface is exactly thirteen',
  (select count(*) from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
    where ns.nspname='public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not like 'expect\_%'), 13);

do $$ begin raise notice 'Decision 15 amendment — all assertions passed'; end $$;
