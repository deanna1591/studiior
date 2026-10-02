-- =============================================================================
-- Decision 51 — studio_by_slug returns the two new branding fields, and the
-- anon surface is still EXACTLY TWELVE. UUID space 9a51, checked free.
-- Run after `supabase db reset`.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if;
end $$;
create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if;
end $$;

insert into studios (id, name, slug, timezone, currency, status, login_tagline, install_welcome) values
  ('9a519a51-0000-0000-0000-000000000001','PWA Studio','9a51-pwa','Europe/Prague','CZK','active',
   'Move well, book fast.', 'Add PWA Studio to your phone.'),
  ('9a519a51-0000-0000-0000-000000000002','Bare Studio','9a51-bare','Europe/Prague','CZK','active',
   null, null);

-- studio_by_slug returns the two new fields (the configured studio).
select expect_text('studio_by_slug returns login_tagline',
  (select login_tagline from studio_by_slug('9a51-pwa')), 'Move well, book fast.');
select expect_text('studio_by_slug returns install_welcome',
  (select install_welcome from studio_by_slug('9a51-pwa')), 'Add PWA Studio to your phone.');
-- NULL comes back as NULL (the app shows its default sentence; the function
-- does not invent one).
select expect_text('studio_by_slug returns NULL tagline when unset',
  (select login_tagline from studio_by_slug('9a51-bare')), null);
select expect_text('studio_by_slug returns NULL welcome when unset',
  (select install_welcome from studio_by_slug('9a51-bare')), null);
-- The existing fields still come back (nothing lost in the drop+recreate).
select expect_text('studio_by_slug still returns name',
  (select name from studio_by_slug('9a51-pwa')), 'PWA Studio');

-- The function returns EXACTLY the 14 documented columns — the two new ones and
-- nothing else new.
select expect_num('studio_by_slug returns exactly 14 columns',
  (select count(*) from pg_proc p
     cross join lateral unnest(coalesce(p.proargnames, '{}'::text[])) as a
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='studio_by_slug'
     and a <> 'p_slug')::bigint, 14);

-- THE ANON SURFACE IS EXACTLY TWELVE — the drop+recreate of studio_by_slug (one
-- of the twelve) must not have lost or widened its anon grant. The suite's own
-- expect_* helpers are anon-executable on LOCAL (the documented local tell), so
-- they are excluded here; the migration asserts the clean 12 at apply.
select expect_num('anon surface is exactly twelve (suite helpers excluded)',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname='public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not like 'expect%')::bigint, 12);

select 'pwa suite finished' as done;
