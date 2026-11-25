-- =============================================================================
-- Decision 116(c): member_coaches, the member-only coach profile reader.
-- UUID space c9c0, checked free. Run after `supabase db reset`.
-- A member of the studio reads its ACTIVE coaches (name, photo, bio,
-- certifications); an archived coach is absent; a member of another studio, a
-- front desk login and anon are refused.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'BAD  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_true(label text, actual boolean)
returns void language plpgsql as $$
begin
  if actual then raise notice 'PASS  %', label;
  else raise exception 'BAD  %  expected true, got %', label, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_txt(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (%)', label, coalesce(actual,'null');
  else raise exception 'BAD  %  expected "%", got "%"', label, want, coalesce(actual,'null'); end if;
end $$;
create or replace function expect_raises(label text, stmt text, want_sqlstate text)
returns void language plpgsql as $$
begin
  execute stmt; raise exception 'BAD  %  expected % but nothing was raised', label, want_sqlstate;
exception when others then
  if sqlstate = want_sqlstate then raise notice 'PASS  %  (got %)', label, sqlstate;
  elsif sqlstate = 'P0001' and sqlerrm like 'BAD%' then raise;
  else raise exception 'BAD  %  expected %, got % (%)', label, want_sqlstate, sqlstate, sqlerrm; end if;
end $$;

insert into studios (id, name, slug, timezone, currency, status) values
  ('c9c0c9c0-0000-0000-0000-0000000000a1','Coach A','c9c0-sa','Asia/Manila','PHP','active'),
  ('c9c0c9c0-0000-0000-0000-0000000000b1','Coach B','c9c0-sb','Asia/Manila','PHP','active');
insert into studio_settings (studio_id) values
  ('c9c0c9c0-0000-0000-0000-0000000000a1'), ('c9c0c9c0-0000-0000-0000-0000000000b1');
insert into auth.users (id) values
  ('c9c0c9c0-0000-0000-0000-0000000000f1'), ('c9c0c9c0-0000-0000-0000-0000000000f2'),
  ('c9c0c9c0-0000-0000-0000-0000000000f3');
insert into profiles (id, email) values
  ('c9c0c9c0-0000-0000-0000-0000000000f1','c9c0-ma@example.com'),
  ('c9c0c9c0-0000-0000-0000-0000000000f2','c9c0-mb@example.com'),
  ('c9c0c9c0-0000-0000-0000-0000000000f3','c9c0-fd@example.com');
insert into members (id, studio_id, user_id, first_name, last_name, email, status) values
  ('c9c0c9c0-0000-0000-0000-00000000aa01','c9c0c9c0-0000-0000-0000-0000000000a1','c9c0c9c0-0000-0000-0000-0000000000f1','Mia','A','c9c0-ma@example.com','active'),
  ('c9c0c9c0-0000-0000-0000-00000000bb01','c9c0c9c0-0000-0000-0000-0000000000b1','c9c0c9c0-0000-0000-0000-0000000000f2','Ben','B','c9c0-mb@example.com','active');
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('c9c0c9c0-0000-0000-0000-00000005f003','c9c0c9c0-0000-0000-0000-0000000000a1','c9c0c9c0-0000-0000-0000-0000000000f3','c9c0-fd@example.com','front_desk');
insert into instructors (id, studio_id, display_name, bio, avatar_url, certifications, status) values
  ('c9c0c9c0-0000-0000-0000-00000000d101','c9c0c9c0-0000-0000-0000-0000000000a1','Ada Example','Reformer and mat.','https://x/ada.jpg','["BASI","Reformer 1-3"]','active'),
  ('c9c0c9c0-0000-0000-0000-00000000d102','c9c0c9c0-0000-0000-0000-0000000000a1','Bo Quiet',null,null,'[]','active'),
  ('c9c0c9c0-0000-0000-0000-00000000d103','c9c0c9c0-0000-0000-0000-0000000000a1','Gone Coach','Left us.',null,'[]','archived'),
  ('c9c0c9c0-0000-0000-0000-00000000d201','c9c0c9c0-0000-0000-0000-0000000000b1','Other Studio Coach','B bio',null,'[]','active');

-- A member of studio A
set role authenticated;
select set_config('request.jwt.claim.sub','c9c0c9c0-0000-0000-0000-0000000000f1',false);
select expect_num('a member sees the studio''s two active coaches',
  (select count(*) from member_coaches('c9c0c9c0-0000-0000-0000-0000000000a1'))::bigint, 2);
select expect_num('...the archived coach is absent',
  (select count(*) from member_coaches('c9c0c9c0-0000-0000-0000-0000000000a1') where display_name = 'Gone Coach')::bigint, 0);
select expect_num('...no other studio''s coach',
  (select count(*) from member_coaches('c9c0c9c0-0000-0000-0000-0000000000a1') where display_name = 'Other Studio Coach')::bigint, 0);
select expect_txt('...Ada carries first name, photo, bio and certifications',
  (select first_name || '|' || avatar_url || '|' || bio || '|' || certifications::text
     from member_coaches('c9c0c9c0-0000-0000-0000-0000000000a1') where display_name = 'Ada Example'),
  'Ada|https://x/ada.jpg|Reformer and mat.|["BASI", "Reformer 1-3"]');
select expect_true('...a coach with no bio still comes back (bio null, empty certifications)',
  (select bio is null and certifications = '[]'::jsonb
     from member_coaches('c9c0c9c0-0000-0000-0000-0000000000a1') where display_name = 'Bo Quiet'));
select expect_txt('...the reader returns exactly six columns',
  (select string_agg(a, ',' order by ord) from unnest(
     (select proargnames from pg_proc where proname = 'member_coaches')) with ordinality t(a, ord)
     where a <> 'p_studio_id'), 'id,first_name,display_name,avatar_url,bio,certifications');
-- A member of another studio
select set_config('request.jwt.claim.sub','c9c0c9c0-0000-0000-0000-0000000000f2',false);
select expect_raises('a member of another studio is refused',
  $q$select * from member_coaches('c9c0c9c0-0000-0000-0000-0000000000a1')$q$, 'PT403');
-- Front desk (staff, not a member)
select set_config('request.jwt.claim.sub','c9c0c9c0-0000-0000-0000-0000000000f3',false);
select expect_raises('front desk is refused',
  $q$select * from member_coaches('c9c0c9c0-0000-0000-0000-0000000000a1')$q$, 'PT403');
select set_config('request.jwt.claim.sub','',false);
reset role;
-- Anon
set role anon;
select expect_raises('anon cannot execute it',
  $q$select * from member_coaches('c9c0c9c0-0000-0000-0000-0000000000a1')$q$, '42501');
reset role;

select expect_num('anon surface is EXACTLY FIFTEEN',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not like 'expect_%')::bigint, 15);
select expect_true('the inbox table is closed to anon reads with RLS on',
  not has_table_privilege('anon','public.resend_webhook_inbox','select')
  and (select relrowsecurity from pg_class where oid = 'public.resend_webhook_inbox'::regclass));

select 'member_coaches_test: all assertions passed' as done;
