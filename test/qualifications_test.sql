-- =============================================================================
-- Who can teach what — migration 060. UUID space 9ca1, checked free.
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;
create or replace function expect_num(label text, actual bigint, want bigint)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual::text,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual::text,'null'); end if;
end $$;
create or replace function expect_text(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if;
end $$;
create or replace function expect_raises(label text, stmt text, want_sqlstate text)
returns void language plpgsql as $$
begin
  execute stmt; raise exception 'FAIL  %  expected % but nothing was raised', label, want_sqlstate;
exception when others then
  if sqlstate = want_sqlstate then raise notice 'PASS  %  (got %)', label, sqlstate;
  elsif sqlstate = 'P0001' and sqlerrm like 'FAIL%' then raise;
  else raise exception 'FAIL  %  expected %, got % (%)', label, want_sqlstate, sqlstate, sqlerrm; end if;
end $$;

insert into auth.users (id) values
  ('9ca19ca1-0000-0000-0000-0000000000a1'), ('9ca19ca1-0000-0000-0000-0000000000a3');
insert into profiles (id, email, full_name) values
  ('9ca19ca1-0000-0000-0000-0000000000a1','qual-owner@example.com','Ola Owner'),
  ('9ca19ca1-0000-0000-0000-0000000000a3','qual-instr@example.com','Ines Structor');
insert into studios (id, name, slug, timezone, currency, status) values
  ('9ca19ca1-0000-0000-0000-000000000001','Qual Studio','qual-test','Europe/Prague','CZK','active'),
  ('9ca19ca1-0000-0000-0000-000000000002','Other Qual','qual-other','Europe/Prague','CZK','active');
insert into studio_settings (studio_id) values
  ('9ca19ca1-0000-0000-0000-000000000001'), ('9ca19ca1-0000-0000-0000-000000000002');
insert into studio_staff (id, studio_id, user_id, email, role) values
  ('9ca19ca1-0000-0000-0000-00000000aa01','9ca19ca1-0000-0000-0000-000000000001','9ca19ca1-0000-0000-0000-0000000000a1','qual-owner@example.com','owner'),
  ('9ca19ca1-0000-0000-0000-00000000aa03','9ca19ca1-0000-0000-0000-000000000001','9ca19ca1-0000-0000-0000-0000000000a3','qual-instr@example.com','instructor');
insert into class_types (id, studio_id, name, duration_minutes, default_capacity) values
  ('9ca19ca1-0000-0000-0000-00000000cc01','9ca19ca1-0000-0000-0000-000000000001','Reformer',50,10),
  ('9ca19ca1-0000-0000-0000-00000000cc02','9ca19ca1-0000-0000-0000-000000000001','Barre',45,12),
  ('9ca19ca1-0000-0000-0000-00000000cc99','9ca19ca1-0000-0000-0000-000000000002','Foreign',50,10);
insert into instructors (id, studio_id, staff_id, display_name) values
  ('9ca19ca1-0000-0000-0000-00000000d101','9ca19ca1-0000-0000-0000-000000000001','9ca19ca1-0000-0000-0000-00000000aa03','Ines Structor');

set role authenticated;
select set_config('request.jwt.claim.sub','9ca19ca1-0000-0000-0000-0000000000a1',false);

-- EMPTY MEANS NOTHING. The expensive reading, and the one the engine needs: "no
-- rows means everything" would leave an unmapped instructor silently eligible
-- for every class while the studio believed they had configured it.
select expect_text('an unmapped instructor is qualified for nothing',
  instructor_qualified('9ca19ca1-0000-0000-0000-00000000d101',
                       '9ca19ca1-0000-0000-0000-00000000cc01')::text, 'false');
-- A class with no type is not a qualification question at all.
select expect_text('a class with no type is not a qualification question',
  instructor_qualified('9ca19ca1-0000-0000-0000-00000000d101', null)::text, 'true');

select expect_num('the whole list goes in one call',
  set_instructor_class_types('9ca19ca1-0000-0000-0000-00000000d101',
    array['9ca19ca1-0000-0000-0000-00000000cc01','9ca19ca1-0000-0000-0000-00000000cc02']::uuid[])::bigint, 2);
select expect_text('...and they are qualified for what was ticked',
  instructor_qualified('9ca19ca1-0000-0000-0000-00000000d101',
                       '9ca19ca1-0000-0000-0000-00000000cc01')::text, 'true');

select expect_num('re-saving replaces rather than appends',
  set_instructor_class_types('9ca19ca1-0000-0000-0000-00000000d101',
    array['9ca19ca1-0000-0000-0000-00000000cc02']::uuid[])::bigint, 1);
select expect_text('...so a removed type really is removed',
  instructor_qualified('9ca19ca1-0000-0000-0000-00000000d101',
                       '9ca19ca1-0000-0000-0000-00000000cc01')::text, 'false');
select expect_num('an empty list clears it',
  set_instructor_class_types('9ca19ca1-0000-0000-0000-00000000d101', '{}'::uuid[])::bigint, 0);

-- Another studio's class type cannot be mapped in by passing its id.
select expect_num('a class type from another studio is silently not mapped',
  set_instructor_class_types('9ca19ca1-0000-0000-0000-00000000d101',
    array['9ca19ca1-0000-0000-0000-00000000cc99']::uuid[])::bigint, 0);

-- The mirror, from the class type's side.
select expect_num('the class type side writes the same table',
  set_class_type_instructors('9ca19ca1-0000-0000-0000-00000000cc01',
    array['9ca19ca1-0000-0000-0000-00000000d101']::uuid[])::bigint, 1);
select expect_text('...and the instructor side agrees',
  instructor_qualified('9ca19ca1-0000-0000-0000-00000000d101',
                       '9ca19ca1-0000-0000-0000-00000000cc01')::text, 'true');

-- Instructors read their own and do not write it.
select set_config('request.jwt.claim.sub','9ca19ca1-0000-0000-0000-0000000000a3',false);
select expect_num('an instructor can read what they are down to teach',
  (select count(*) from instructor_class_types
    where instructor_id = '9ca19ca1-0000-0000-0000-00000000d101')::bigint, 1);
select expect_raises('...and cannot decide it for themselves',
  $q$select set_instructor_class_types('9ca19ca1-0000-0000-0000-00000000d101', '{}'::uuid[])$q$,
  'PT403');
delete from instructor_class_types where instructor_id = '9ca19ca1-0000-0000-0000-00000000d101';
select expect_num('...nor delete the row directly',
  (select count(*) from instructor_class_types
    where instructor_id = '9ca19ca1-0000-0000-0000-00000000d101')::bigint, 1);
