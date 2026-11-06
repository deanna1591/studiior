-- =============================================================================
-- Decision 88 (c) — invoice numbering. Migration 20260833200000.
-- =============================================================================
-- UUID space 88c0 (hex), checked free. Run after `supabase db reset`.
--
-- Invoice numbers are per studio, sequential, assigned the moment a payment
-- succeeds (a trigger on payments: status → succeeded), stored on the payment,
-- and a refund of a numbered payment keeps its number. A member can number
-- their own pre-existing payment on first download (guarded wrapper); another
-- member cannot.
--
-- RED proof: pre-88c payments.invoice_no / studio_settings.invoice_next_no and
-- assign_invoice_no do not exist, so every assertion errors.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to warning;

create or replace function login(uid text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', uid, true); set local role authenticated; end $$;
create or replace function expect_text(label text, actual text, want text) returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'BAD  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if; end $$;
create or replace function expect_null(label text, actual anyelement) returns void language plpgsql as $$
begin if actual is null then raise notice 'PASS  %', label; else raise exception 'BAD  %  expected null, got %', label, actual::text; end if; end $$;
create or replace function expect_num(label text, actual bigint, want bigint) returns void language plpgsql as $$
begin if actual = want then raise notice 'PASS  %  (got %)', label, actual; else raise exception 'BAD  %  expected %, got %', label, want, actual; end if; end $$;
create or replace function inv(pid text) returns text language sql as $$ select invoice_no from payments where id = pid::uuid $$;
create or replace function nextno(sid text) returns bigint language sql as $$ select invoice_next_no from studio_settings where studio_id = sid::uuid $$;
create or replace function as_err(uid text, sql text) returns text language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', uid, true); set local role authenticated;
  begin execute sql; return 'ok'; exception when others then return sqlstate; end; end $$;

reset role;

-- ---- fixtures ---------------------------------------------------------------
insert into auth.users (id) values
  ('88c00000-0000-0000-0000-0000000000f1'),   -- desk recorder
  ('88c00000-0000-0000-0000-0000000000f2'),   -- member m1 (owner)
  ('88c00000-0000-0000-0000-0000000000f3');   -- member m2 (other)
insert into profiles (id, email, full_name) values
  ('88c00000-0000-0000-0000-0000000000f1','clerk@example.com','Desk Clerk'),
  ('88c00000-0000-0000-0000-0000000000f2','m1@example.com','Member One'),
  ('88c00000-0000-0000-0000-0000000000f3','m2@example.com','Member Two');

insert into studios (id, name, slug, timezone, currency, status) values
  ('88c00000-0000-0000-0000-0000000000a0','Alpha','88c0-sa','UTC','PHP','active'),
  ('88c00000-0000-0000-0000-0000000000b0','Bravo','88c0-sb','UTC','PHP','active');
insert into studio_settings (studio_id, invoice_registered_name, invoice_tin) values
  ('88c00000-0000-0000-0000-0000000000a0','ALPHA STUDIO','000-1'),   -- A has invoice details
  ('88c00000-0000-0000-0000-0000000000b0', null, null);             -- B does not (numbers anyway)

insert into members (id, studio_id, first_name, last_name, email, user_id) values
  ('88c00000-0000-0000-0000-0000000000c1'::uuid,'88c00000-0000-0000-0000-0000000000a0','Member','One','m1@example.com','88c00000-0000-0000-0000-0000000000f2'),
  ('88c00000-0000-0000-0000-0000000000c2'::uuid,'88c00000-0000-0000-0000-0000000000a0','Member','Two','m2@example.com','88c00000-0000-0000-0000-0000000000f3');

\echo '--- 1. the trigger numbers a succeeded payment, sequential per studio ---'
insert into payments (id, studio_id, amount_cents, currency, status, provider) values
  ('88c00000-0000-0000-0000-0000000000a1','88c00000-0000-0000-0000-0000000000a0',180000,'PHP','succeeded','manual'),
  ('88c00000-0000-0000-0000-0000000000a2','88c00000-0000-0000-0000-0000000000a0',150000,'PHP','succeeded','manual'),
  ('88c00000-0000-0000-0000-0000000000a3','88c00000-0000-0000-0000-0000000000a0',105000,'PHP','succeeded','xendit');
select expect_text('A #1', inv('88c00000-0000-0000-0000-0000000000a1'), 'No. 0000001');
select expect_text('A #2', inv('88c00000-0000-0000-0000-0000000000a2'), 'No. 0000002');
select expect_text('A #3', inv('88c00000-0000-0000-0000-0000000000a3'), 'No. 0000003');

\echo '--- 2. a demo payment is not numbered, counter not bumped ---'
insert into payments (id, studio_id, amount_cents, currency, status, provider, is_demo) values
  ('88c00000-0000-0000-0000-0000000000ad','88c00000-0000-0000-0000-0000000000a0',999,'PHP','succeeded','manual',true);
select expect_null('demo not numbered', inv('88c00000-0000-0000-0000-0000000000ad'));

\echo '--- 3. a non-succeeded payment is not numbered until it succeeds ---'
insert into payments (id, studio_id, amount_cents, currency, status, provider) values
  ('88c00000-0000-0000-0000-0000000000a4','88c00000-0000-0000-0000-0000000000a0',105000,'PHP','pending','xendit');
select expect_null('pending not numbered', inv('88c00000-0000-0000-0000-0000000000a4'));

\echo '--- 4. more successes, then promote the pending one ---'
insert into payments (id, studio_id, amount_cents, currency, status, provider) values
  ('88c00000-0000-0000-0000-0000000000a5','88c00000-0000-0000-0000-0000000000a0',105000,'PHP','succeeded','manual');
insert into payments (id, studio_id, amount_cents, currency, status, provider, recorded_by) values
  ('88c00000-0000-0000-0000-0000000000a6','88c00000-0000-0000-0000-0000000000a0',105000,'PHP','succeeded','manual','88c00000-0000-0000-0000-0000000000f1');
insert into payments (id, studio_id, member_id, amount_cents, currency, status, provider) values
  ('88c00000-0000-0000-0000-0000000000a7','88c00000-0000-0000-0000-0000000000a0','88c00000-0000-0000-0000-0000000000c1'::uuid,180000,'PHP','succeeded','manual');
update payments set status='succeeded' where id='88c00000-0000-0000-0000-0000000000a4';
select expect_text('A #5 (after demo+pending skipped)', inv('88c00000-0000-0000-0000-0000000000a5'), 'No. 0000004');
select expect_text('A recorder pay',                     inv('88c00000-0000-0000-0000-0000000000a6'), 'No. 0000005');
select expect_text('A member pay',                       inv('88c00000-0000-0000-0000-0000000000a7'), 'No. 0000006');
select expect_text('promoted pending',                   inv('88c00000-0000-0000-0000-0000000000a4'), 'No. 0000007');

\echo '--- 5. received_by derived from recorded_by ---'
select expect_text('received_by from recorder',
  (select received_by from payments where id='88c00000-0000-0000-0000-0000000000a6'), 'Desk Clerk');

\echo '--- 6. no gaps, counter advances ---'
select expect_num('A has 7 distinct numbers',
  (select count(distinct invoice_no) from payments where studio_id='88c00000-0000-0000-0000-0000000000a0' and invoice_no is not null), 7);
select expect_num('A min number', (select min(substring(invoice_no from 5)::int) from payments where studio_id='88c00000-0000-0000-0000-0000000000a0' and invoice_no is not null), 1);
select expect_num('A max number', (select max(substring(invoice_no from 5)::int) from payments where studio_id='88c00000-0000-0000-0000-0000000000a0' and invoice_no is not null), 7);
select expect_num('A next_no = 8', nextno('88c00000-0000-0000-0000-0000000000a0'), 8);

\echo '--- 7. a second studio numbers independently from 1 ---'
insert into payments (id, studio_id, amount_cents, currency, status, provider) values
  ('88c00000-0000-0000-0000-0000000000b1','88c00000-0000-0000-0000-0000000000b0',105000,'PHP','succeeded','manual');
select expect_text('B #1', inv('88c00000-0000-0000-0000-0000000000b1'), 'No. 0000001');
select expect_num('B next_no = 2', nextno('88c00000-0000-0000-0000-0000000000b0'), 2);

\echo '--- 8. a refund keeps the number ---'
update payments set refunded_cents=150000, refunded_at=now(), status='partially_refunded'
 where id='88c00000-0000-0000-0000-0000000000a2';
select expect_text('refund keeps number', inv('88c00000-0000-0000-0000-0000000000a2'), 'No. 0000002');

\echo '--- 9. assign_invoice_no is idempotent (service twin) ---'
select expect_text('re-assign returns existing', assign_invoice_no_run('88c00000-0000-0000-0000-0000000000a1'), 'No. 0000001');
select expect_num('counter not bumped by re-assign', nextno('88c00000-0000-0000-0000-0000000000a0'), 8);

\echo '--- 10. a pre-existing (unnumbered) payment gets a number via the run twin ---'
-- simulate a payment that predates the trigger: insert succeeded, then clear its number
update payments set invoice_no=null where id='88c00000-0000-0000-0000-0000000000a7';
select expect_text('lazy assign numbers it', assign_invoice_no_run('88c00000-0000-0000-0000-0000000000a7'), 'No. 0000008');

\echo '--- 11. guard: a member numbers their own, another member cannot ---'
-- a7 is m1''s payment; it already carries a number, so the wrapper returns it for m1 and PT403s for m2
select expect_text('owner passes', assign_invoice_no('88c00000-0000-0000-0000-0000000000a7'), 'No. 0000008')
  from (select login('88c00000-0000-0000-0000-0000000000f2')) _;
reset role;
select expect_text('other member PT403', as_err('88c00000-0000-0000-0000-0000000000f3',
  'select assign_invoice_no(''88c00000-0000-0000-0000-0000000000a7'')'), 'PT403');
reset role;

\echo '--- 12. anon surface is THIRTEEN ---'
select expect_num('anon surface is thirteen',
  (select count(*) from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
    where ns.nspname='public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not in ('login','as_err','expect_text','expect_null','expect_num','inv','nextno')), 13);

reset role;
drop function login(text); drop function as_err(text,text); drop function inv(text); drop function nextno(text);
drop function expect_text(text,text,text); drop function expect_null(text,anyelement); drop function expect_num(text,bigint,bigint);
\echo 'invoice_test: all assertions passed'
