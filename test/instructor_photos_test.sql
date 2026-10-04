-- =============================================================================
-- Decision 60 — an instructor's photo is uploaded, not linked (migration 216).
-- The public `instructor-photos` bucket + its four storage policies: a manager
-- of the path's studio OR the instructor themselves may write; anyone may read.
-- UUID space: ac60
-- =============================================================================
-- Storage policies cannot be meaningfully asserted from pg catalogs alone, so
-- they are exercised as real roles (set role authenticated + a jwt sub), the
-- same way member_accounts_test proves the member-avatar folder scope. The
-- bucket's own shape (public, size, mime) is read from storage.buckets.

\set A '''ac60ac60-0000-0000-0000-000000000001'''
\set B '''ac60ac60-0000-0000-0000-000000000002'''

create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if coalesce(actual,false) then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if;
end $$;

-- A write that must be allowed: the row persists (so the anon read test can see
-- it). A write that must be refused: RLS raises insufficient_privilege (a
-- with-check violation) and the sub-block rolls back just that insert.
create or replace function sp_ok(label text, bkt text, nm text)
returns void language plpgsql as $$
begin
  insert into storage.objects (bucket_id, name) values (bkt, nm);
  raise notice 'PASS  %', label;
end $$;
create or replace function sp_refused(label text, bkt text, nm text)
returns void language plpgsql as $$
begin
  insert into storage.objects (bucket_id, name) values (bkt, nm);
  raise exception 'FAIL  %  (the write was allowed)', label;
exception when insufficient_privilege or check_violation then
  raise notice 'PASS  %', label;
end $$;

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values
  ('ac60ac60-0000-0000-0000-0000000000a1'),   -- owner of A
  ('ac60ac60-0000-0000-0000-000000000d11'),   -- instructor IA1 login (studio A)
  ('ac60ac60-0000-0000-0000-0000000000b1');   -- owner of B
insert into profiles (id, email) values
  ('ac60ac60-0000-0000-0000-0000000000a1','ac60-ownerA@example.com'),
  ('ac60ac60-0000-0000-0000-000000000d11','ac60-ia1@example.com'),
  ('ac60ac60-0000-0000-0000-0000000000b1','ac60-ownerB@example.com');

insert into studios (id, name, slug, timezone, currency, status) values
  (:A,'Photo Studio A','photo-a','Europe/Prague','CZK','active'),
  (:B,'Photo Studio B','photo-b','Europe/Prague','CZK','active');
insert into studio_settings (studio_id) values (:A), (:B);

insert into studio_staff (id, studio_id, user_id, email, role, status) values
  ('ac60ac60-0000-0000-0000-000000aa00a1',:A,'ac60ac60-0000-0000-0000-0000000000a1','ac60-ownerA@example.com','owner','active'),
  ('ac60ac60-0000-0000-0000-000000aa00d1',:A,'ac60ac60-0000-0000-0000-000000000d11','ac60-ia1@example.com','instructor','active'),
  ('ac60ac60-0000-0000-0000-000000aa00b1',:B,'ac60ac60-0000-0000-0000-0000000000b1','ac60-ownerB@example.com','owner','active');

-- IA1: login instructor on A. IA2: no login (staff_id null) on A. IB1: on B.
insert into instructors (id, studio_id, display_name, staff_id) values
  ('ac60ac60-0000-0000-0000-00000000ca01',:A,'Ada Example','ac60ac60-0000-0000-0000-000000aa00d1'),
  ('ac60ac60-0000-0000-0000-00000000ca02',:A,'Nora Nologin',null),
  ('ac60ac60-0000-0000-0000-00000000cb01',:B,'Bo Fictitious',null);

-- =============================================================================
-- 1. The bucket's shape
-- =============================================================================
select expect_true('the instructor-photos bucket exists',
  exists(select 1 from storage.buckets where id='instructor-photos'));
select expect_true('it is public',
  (select public from storage.buckets where id='instructor-photos'));
select expect_true('its size limit is 5 MB',
  (select file_size_limit from storage.buckets where id='instructor-photos') = 5242880);
select expect_true('it allows png, jpeg and webp only',
  (select allowed_mime_types from storage.buckets where id='instructor-photos')
    @> array['image/png','image/jpeg','image/webp']
  and array_length((select allowed_mime_types from storage.buckets where id='instructor-photos'),1) = 3);

-- =============================================================================
-- 2. The four policies exist and say what they should
-- =============================================================================
select expect_true('the public read policy exists',
  exists(select 1 from pg_policies where schemaname='storage' and tablename='objects'
         and policyname='instructor photos are publicly readable'));
select expect_true('the read policy is scoped to the bucket',
  (select qual from pg_policies where policyname='instructor photos are publicly readable')
   like '%instructor-photos%');
select expect_true('the insert policy exists and names the bucket, is_manager_up and the self join',
  (select coalesce(qual,'')||coalesce(with_check,'')
     from pg_policies where policyname='managers or the instructor write instructor photos')
   like '%instructor-photos%'
  and (select coalesce(with_check,'') from pg_policies
         where policyname='managers or the instructor write instructor photos')
      like '%is_manager_up%'
  and (select coalesce(with_check,'') from pg_policies
         where policyname='managers or the instructor write instructor photos')
      like '%studio_staff%');
select expect_true('the update policy names the bucket and is_manager_up',
  (select coalesce(qual,'') from pg_policies
     where policyname='managers or the instructor replace instructor photos')
   like '%instructor-photos%'
  and (select coalesce(qual,'') from pg_policies
         where policyname='managers or the instructor replace instructor photos')
       like '%is_manager_up%');
select expect_true('the delete policy names the bucket and is_manager_up',
  (select coalesce(qual,'') from pg_policies
     where policyname='managers or the instructor delete instructor photos')
   like '%instructor-photos%'
  and (select coalesce(qual,'') from pg_policies
         where policyname='managers or the instructor delete instructor photos')
       like '%is_manager_up%');

-- =============================================================================
-- 3. A manager of the studio may write any of its instructors' folders
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','ac60ac60-0000-0000-0000-0000000000a1',false);
select sp_ok('A manager writes a login instructor''s folder',
  'instructor-photos','ac60ac60-0000-0000-0000-000000000001/ac60ac60-0000-0000-0000-00000000ca01/m1.jpg');
select sp_ok('A manager writes a NO-login instructor''s folder',
  'instructor-photos','ac60ac60-0000-0000-0000-000000000001/ac60ac60-0000-0000-0000-00000000ca02/m2.jpg');
select sp_refused('A manager cannot write into studio B''s folder',
  'instructor-photos','ac60ac60-0000-0000-0000-000000000002/ac60ac60-0000-0000-0000-00000000cb01/m3.jpg');
reset role;

-- =============================================================================
-- 4. An instructor may write only their OWN folder
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','ac60ac60-0000-0000-0000-000000000d11',false);
select sp_ok('IA1 writes their own folder',
  'instructor-photos','ac60ac60-0000-0000-0000-000000000001/ac60ac60-0000-0000-0000-00000000ca01/self.jpg');
select sp_refused('IA1 cannot write another instructor''s folder',
  'instructor-photos','ac60ac60-0000-0000-0000-000000000001/ac60ac60-0000-0000-0000-00000000ca02/x.jpg');
select sp_refused('IA1 cannot write into studio B''s folder',
  'instructor-photos','ac60ac60-0000-0000-0000-000000000002/ac60ac60-0000-0000-0000-00000000cb01/x.jpg');
reset role;

-- =============================================================================
-- 5. A manager of another studio is refused
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub','ac60ac60-0000-0000-0000-0000000000b1',false);
select sp_refused('B''s owner cannot write into A''s folder',
  'instructor-photos','ac60ac60-0000-0000-0000-000000000001/ac60ac60-0000-0000-0000-00000000ca01/x.jpg');
reset role;

-- (Public readability is the bucket's public=true flag [section 1] plus the
--  bucket-scoped select policy [section 2]; a role-level `select from
--  storage.objects` as anon trips the UNRELATED member-avatar select policy,
--  which references `members` — a table anon has no grant on — so it is not a
--  meaningful test of THIS bucket. The embed render proves the public read.)

-- A pure member of A is not staff, so the self join is invisible to them —
-- they cannot write an instructor folder (defends the "only staff or the
-- instructor" boundary against a member session).
insert into auth.users (id) values ('ac60ac60-0000-0000-0000-00000000de01');
insert into profiles (id, email) values ('ac60ac60-0000-0000-0000-00000000de01','ac60-member@example.com');
insert into members (id, studio_id, user_id, first_name, last_name, email, status) values
  ('ac60ac60-0000-0000-0000-00000000de0f',:A,'ac60ac60-0000-0000-0000-00000000de01','Member','A','ac60-member@example.com','active');
set role authenticated;
select set_config('request.jwt.claim.sub','ac60ac60-0000-0000-0000-00000000de01',false);
select sp_refused('a member cannot write an instructor''s folder',
  'instructor-photos','ac60ac60-0000-0000-0000-000000000001/ac60ac60-0000-0000-0000-00000000ca01/x.jpg');
reset role;

select 'ALL INSTRUCTOR PHOTO TESTS PASSED' as result;
