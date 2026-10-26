-- =============================================================================
-- Decision 82 STEP 1 (cause 4) — History bounds member_activity to the last 3
-- months, and the running balance stays correct across the boundary.
-- =============================================================================
-- UUID space b082, checked free. Run after `supabase db reset`.
--
-- member_activity computes the running balance over the ALL-TIME credit_ledger
-- (the per-row balance is the ledger balance as of that row), then filters the
-- DISPLAY rows by [from, to]. So a bounded window carries the opening balance by
-- construction. This asserts the brief's invariant: opening-before-window +
-- sum(window credit_delta) == the all-time balance, and the window's newest row
-- shows the same balance whether bounded or not.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_eq(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual,'null'); end if;
end $$;

insert into studios (id, name, slug, timezone, currency, status) values
  ('b082b082-0000-0000-0000-000000000001','BW','b082-bw','Asia/Manila','PHP','active');
insert into studio_settings (studio_id) values ('b082b082-0000-0000-0000-000000000001');
insert into members (id, studio_id, first_name, last_name, email, waiver_signed_at) values
  ('b082b082-0000-0000-0000-0000000d0001','b082b082-0000-0000-0000-000000000001','Win','Dow','b082-m@example.com', now());

-- Ledger spanning four months. 120/70 days ago straddle "first of the month two
-- months back"; 10/2 days ago are firmly inside. Unclaimed (no payment), so they
-- surface as their own credit lines in member_activity's `adj` arm.
-- balance_after is the stored cumulative; member_activity recomputes the running
-- balance from delta over the all-time ledger and does not read it, but the
-- column is NOT NULL, so the honest cumulative is stored here.
insert into credit_ledger (studio_id, member_id, delta, balance_after, reason, created_at) values
  ('b082b082-0000-0000-0000-000000000001','b082b082-0000-0000-0000-0000000d0001', 10, 10,'manual',  now()-interval '120 days'),
  ('b082b082-0000-0000-0000-000000000001','b082b082-0000-0000-0000-0000000d0001', -1,  9,'booking', now()-interval '120 days' + interval '1 h'),
  ('b082b082-0000-0000-0000-000000000001','b082b082-0000-0000-0000-0000000d0001', -1,  8,'booking', now()-interval '70 days'),
  ('b082b082-0000-0000-0000-000000000001','b082b082-0000-0000-0000-0000000d0001', -1,  7,'booking', now()-interval '10 days'),
  ('b082b082-0000-0000-0000-000000000001','b082b082-0000-0000-0000-0000000d0001',  5, 12,'manual',  now()-interval '2 days');

-- The window `from` the History page computes: first of the month two months back.
\set m 'b082b082-0000-0000-0000-0000000d0001'

-- A: all-time — the final running balance equals the sum of ledger deltas.
select expect_eq('all-time: final balance == sum(ledger delta)',
  (select balance_after::text from member_activity(:'m'::uuid,'2000-01-01','2100-01-01') order by at desc limit 1),
  (select sum(delta)::text from credit_ledger where member_id=:'m'::uuid));

-- B: the bounded window's NEWEST row shows the SAME balance as all-time — the
-- window did not reset it; the opening balance is carried.
select expect_eq('bounded window newest-row balance == all-time final (carried)',
  (select balance_after::text from member_activity(:'m'::uuid,
       (date_trunc('month', now()) - interval '2 months')::date, '2100-01-01')
     order by at desc limit 1),
  (select balance_after::text from member_activity(:'m'::uuid,'2000-01-01','2100-01-01') order by at desc limit 1));

-- C: the invariant — opening-before-window + sum(window credit_delta) == all-time.
select expect_eq('invariant: opening + sum(window credit_delta) == all-time balance',
  ((select coalesce(sum(delta),0) from credit_ledger
      where member_id=:'m'::uuid and created_at::date < (date_trunc('month', now()) - interval '2 months')::date)
   + (select coalesce(sum(credit_delta),0) from member_activity(:'m'::uuid,
        (date_trunc('month', now()) - interval '2 months')::date, '2100-01-01')))::text,
  (select sum(delta)::text from credit_ledger where member_id=:'m'::uuid));

-- D: the bounded window genuinely returns FEWER rows than all-time (it bounds
-- the display), while the two 120-days-ago rows are the ones excluded.
select expect_eq('bounded window excludes the two pre-window rows',
  ((select count(*) from member_activity(:'m'::uuid,'2000-01-01','2100-01-01'))
   - (select count(*) from member_activity(:'m'::uuid,
        (date_trunc('month', now()) - interval '2 months')::date, '2100-01-01')))::text,
  '2');

do $$ begin raise notice 'history_window_test: all assertions passed'; end $$;
