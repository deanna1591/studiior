-- Decision 102 — one name stays one name, one phone one account; plus the
-- Decision 30 amendment (the core-only picker's data source). UUID space d102.
--
-- Covers: the split rule (name_last_part; claim_member_by_email self-signup;
-- add_walk_in; import_commit; book_guest shares the empty-last outcome), the
-- one-time correction, same_person_match's empty-last rule, phone_taken for the
-- member and staff writers, a deleted member's old phone reusable, the picker's
-- core-only reader honours free_first_core_only, member_bootstrap carries it,
-- and anon stays THIRTEEN.

begin;
set local client_min_messages = warning;

create or replace function expect_text(label text, actual text, want text) returns void
  language plpgsql as $$ begin
    if actual is distinct from want then
      raise exception 'FAILED: % — got %, want %', label, coalesce(actual,'<null>'), coalesce(want,'<null>');
    else raise notice 'ok: %', label; end if; end $$;
create or replace function expect_true(label text, actual boolean) returns void
  language plpgsql as $$ begin
    if actual is not true then raise exception 'FAILED: % — got %, want true', label, coalesce(actual::text,'<null>');
    else raise notice 'ok: %', label; end if; end $$;
create or replace function expect_num(label text, actual bigint, want bigint) returns void
  language plpgsql as $$ begin
    if actual is distinct from want then raise exception 'FAILED: % — got %, want %', label, actual, want;
    else raise notice 'ok: %', label; end if; end $$;

-- ---------------------------------------------------------------- fixtures ---
insert into studios (id, slug, name, timezone, currency, country, status)
values ('d1020000-0000-0000-0000-000000000001', 'sa-d102', 'SA D102', 'Asia/Manila', 'PHP', 'PH', 'active');
insert into studio_settings (studio_id, free_first_class_enabled, free_first_core_only)
values ('d1020000-0000-0000-0000-000000000001', true, false);
insert into locations (id, studio_id, name)
values ('d1020000-0000-0000-0000-0000000000aa','d1020000-0000-0000-0000-000000000001','Main');
insert into platform_subscriptions (studio_id, status, trial_ends_at)
values ('d1020000-0000-0000-0000-000000000001','trialing', now()+interval '14 days')
on conflict (studio_id) do nothing;

-- An owner login (desk-up for staff_set_member_phone).
insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current, phone_change, phone_change_token, reauthentication_token)
values ('00000000-0000-0000-0000-000000000000','d1020000-0000-0000-0000-0000000000f1','authenticated','authenticated',
        'owner-d102@example.com', now(), now(), now(), '{}','{}','','','','','','','','');
insert into profiles (id, email, full_name) values ('d1020000-0000-0000-0000-0000000000f1','owner-d102@example.com','Olga Owner');
insert into studio_staff (studio_id, user_id, email, role)
values ('d1020000-0000-0000-0000-000000000001','d1020000-0000-0000-0000-0000000000f1','owner-d102@example.com','owner');

-- A self-signup user with a ONE-WORD full name (Madonna).
insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current, phone_change, phone_change_token, reauthentication_token)
values ('00000000-0000-0000-0000-000000000000','d1020000-0000-0000-0000-0000000000f2','authenticated','authenticated',
        'madonna-d102@example.com', now(), now(), now(), '{}','{"full_name":"Madonna"}','','','','','','','','');

-- ============================================================= name_last_part
select expect_text('name_last_part one word -> empty', name_last_part('Madonna'), '');
select expect_text('name_last_part two words', name_last_part('Jane Doe'), 'Doe');
select expect_text('name_last_part three words keeps the rest', name_last_part('Jane Van Doe'), 'Van Doe');
select expect_text('name_last_part trims', name_last_part('  Jane   Doe  '), 'Doe');
select expect_text('name_last_part empty', name_last_part(''), '');

-- ================================================= claim_member_by_email split
set role authenticated;
select set_config('request.jwt.claim.sub','d1020000-0000-0000-0000-0000000000f2', false);
select set_config('t.claim', claim_member_by_email('d1020000-0000-0000-0000-000000000001')::text, false);
select set_config('request.jwt.claim.sub','', false); reset role;
select expect_text('claim_member_by_email first = Madonna',
  (select first_name from members where id = (current_setting('t.claim')::member_claim).member_id), 'Madonna');
select expect_text('claim_member_by_email last is empty (not a copy)',
  (select last_name from members where id = (current_setting('t.claim')::member_claim).member_id), '');

-- ====================================================== add_walk_in one word
-- As service (instructor_scope passes with no today/own-class restriction), on a
-- scheduled future occurrence with a seat.
insert into class_types (id, studio_id, name, duration_minutes, default_capacity)
values ('d1020000-0000-0000-0000-0000000000c0','d1020000-0000-0000-0000-000000000001','Flow', 50, 8);
insert into rooms (id, studio_id, location_id, name, capacity)
values ('d1020000-0000-0000-0000-0000000000a0','d1020000-0000-0000-0000-000000000001','d1020000-0000-0000-0000-0000000000aa','Room', 8);
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name, starts_at, ends_at, capacity, status)
values ('d1020000-0000-0000-0000-00000000a001','d1020000-0000-0000-0000-000000000001','d1020000-0000-0000-0000-0000000000aa',
        'd1020000-0000-0000-0000-0000000000c0','d1020000-0000-0000-0000-0000000000a0','Flow',
        now() + interval '2 days', now() + interval '2 days' + interval '50 min', 8, 'scheduled');
select set_config('t.walk', add_walk_in('d1020000-0000-0000-0000-00000000a001','Cher','cher-d102@example.com','+639170000001')::text, false);
select expect_text('add_walk_in one word -> last empty',
  (select last_name from members where email='cher-d102@example.com'), '');
select expect_text('add_walk_in one word -> first kept',
  (select first_name from members where email='cher-d102@example.com'), 'Cher');

-- ===================================================== import_commit no last
insert into imports (id, studio_id, type, status, filename, created_by)
values ('d1020000-0000-0000-0000-0000000000e0','d1020000-0000-0000-0000-000000000001','members','dry_run_complete','members.csv',
        'd1020000-0000-0000-0000-0000000000f1');
insert into import_rows (import_id, row_number, status, raw, normalized)
values ('d1020000-0000-0000-0000-0000000000e0', 1, 'ok', '{}',
        '{"first_name":"Prince","last_name":"","email":"prince-d102@example.com","status":"active"}');
set role authenticated; select set_config('request.jwt.claim.sub','d1020000-0000-0000-0000-0000000000f1', false);
select set_config('t.imp', import_commit('d1020000-0000-0000-0000-0000000000e0')::text, false);
select set_config('request.jwt.claim.sub','', false); reset role;
select expect_text('import_commit empty last -> empty (not the dash)',
  (select last_name from members where email='prince-d102@example.com'), '');
select expect_text('import_commit first kept',
  (select first_name from members where email='prince-d102@example.com'), 'Prince');

-- ================================================= the one-time correction DO
-- A member staged with first = last (the copy shape). Re-run the migration's
-- exact correction and assert it clears + audits.
insert into members (id, studio_id, first_name, last_name, email, status)
values ('d1020000-0000-0000-0000-00000000b001','d1020000-0000-0000-0000-000000000001','Ara','Ara','ara-d102@example.com','active');
do $$
declare r record;
begin
  for r in select id, studio_id, first_name, last_name from members
            where deleted_at is null and btrim(coalesce(first_name,'')) <> ''
              and lower(btrim(first_name)) = lower(btrim(last_name))
  loop
    update members set last_name = '' where id = r.id;
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
      values (r.studio_id, null, 'member.name_corrected', 'members', r.id,
              jsonb_build_object('first_name', r.first_name, 'last_name', r.last_name),
              jsonb_build_object('first_name', r.first_name, 'last_name', ''));
  end loop;
end $$;
select expect_text('correction cleared the copied last name',
  (select last_name from members where id='d1020000-0000-0000-0000-00000000b001'), '');
select expect_num('correction wrote an audit row', (select count(*) from audit_logs
  where action='member.name_corrected' and entity_id='d1020000-0000-0000-0000-00000000b001'), 1);

-- ================================================== same_person_match empties
-- Two members, same first, empty last, DIFFERENT phones -> no match (never on
-- first name alone). Same phone -> match. Full names match as before.
insert into members (id, studio_id, first_name, last_name, email, phone, status) values
 ('d1020000-0000-0000-0000-00000000b010','d1020000-0000-0000-0000-000000000001','Mia','','mia1-d102@example.com','+639171111111','active'),
 ('d1020000-0000-0000-0000-00000000b011','d1020000-0000-0000-0000-000000000001','Mia','','mia2-d102@example.com','+639172222222','active'),
 ('d1020000-0000-0000-0000-00000000b012','d1020000-0000-0000-0000-000000000001','Nia','','nia1-d102@example.com','+639178888888','active'),
 ('d1020000-0000-0000-0000-00000000b013','d1020000-0000-0000-0000-000000000001','Dan','','dan1-d102@example.com','+639178888888','active'),
 ('d1020000-0000-0000-0000-00000000b020','d1020000-0000-0000-0000-000000000001','Leah','Cruz','leah1-d102@example.com','+639173333333','active'),
 ('d1020000-0000-0000-0000-00000000b021','d1020000-0000-0000-0000-000000000001','Leah','Cruz','leah2-d102@example.com','+639174444444','active');
-- b010 and b011 are both "Mia" with empty last and DIFFERENT phones -> no match.
select expect_num('empty-last same-first different-phone -> no match',
  (select count(*) from same_person_match('d1020000-0000-0000-0000-000000000001','d1020000-0000-0000-0000-00000000b010')), 0);
-- b012 and b013 share a phone (different first) -> match on phone.
select expect_true('empty-last same-phone -> match (b013 shares b012 phone)',
  exists(select 1 from same_person_match('d1020000-0000-0000-0000-000000000001','d1020000-0000-0000-0000-00000000b012') x where x = 'd1020000-0000-0000-0000-00000000b013'));
select expect_true('full-name match still fires (Leah Cruz pair)',
  exists(select 1 from same_person_match('d1020000-0000-0000-0000-000000000001','d1020000-0000-0000-0000-00000000b020') x where x = 'd1020000-0000-0000-0000-00000000b021'));

-- ================================================= phone_taken (member + staff)
-- A has a phone; B tries to take it -> phone_taken. A deleted member's phone is
-- reusable.
insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current, phone_change, phone_change_token, reauthentication_token)
values ('00000000-0000-0000-0000-000000000000','d1020000-0000-0000-0000-0000000000f3','authenticated','authenticated',
        'phb-d102@example.com', now(), now(), now(), '{}','{}','','','','','','','','');
insert into profiles (id, email) values ('d1020000-0000-0000-0000-0000000000f3','phb-d102@example.com');
insert into members (id, studio_id, user_id, first_name, last_name, email, phone, status) values
 ('d1020000-0000-0000-0000-00000000c010','d1020000-0000-0000-0000-000000000001', null, 'Ann','','pha-d102@example.com','+639175555555','active'),
 ('d1020000-0000-0000-0000-00000000c011','d1020000-0000-0000-0000-000000000001','d1020000-0000-0000-0000-0000000000f3','Bea','','phb-d102@example.com','+639176666666','active'),
 ('d1020000-0000-0000-0000-00000000c012','d1020000-0000-0000-0000-000000000001', null, 'Del','','phd-d102@example.com','+639177777777','active');
update members set deleted_at = now() where id='d1020000-0000-0000-0000-00000000c012';

-- Member B (session) tries to take Ann's number.
set role authenticated;
select set_config('request.jwt.claim.sub','d1020000-0000-0000-0000-0000000000f3', false);
select set_config('t.mset', member_set_phone('d1020000-0000-0000-0000-00000000c011','09175555555')::text, false);
select set_config('request.jwt.claim.sub','', false); reset role;
select expect_text('member_set_phone taken -> phone_taken',
  (current_setting('t.mset')::jsonb) ->> 'reason', 'phone_taken');
select expect_true('member_set_phone taken -> a masked email',
  (current_setting('t.mset')::jsonb) ->> 'masked_email' like '%@%');
select expect_text('B phone unchanged after refusal',
  (select phone from members where id='d1020000-0000-0000-0000-00000000c011'), '+639176666666');

-- Staff (desk-up) tries to set Bea's number to Ann's.
set role authenticated;
select set_config('request.jwt.claim.sub','d1020000-0000-0000-0000-0000000000f1', false);
select set_config('t.sset', staff_set_member_phone('d1020000-0000-0000-0000-00000000c011','09175555555')::text, false);
select set_config('request.jwt.claim.sub','', false); reset role;
select expect_text('staff_set_member_phone taken -> phone_taken',
  (current_setting('t.sset')::jsonb) ->> 'reason', 'phone_taken');
select expect_text('staff refusal names the other member id',
  (current_setting('t.sset')::jsonb) ->> 'other_member_id', 'd1020000-0000-0000-0000-00000000c010');

-- The DELETED member (c012) held +639177777777; a live member may take it.
set role authenticated;
select set_config('request.jwt.claim.sub','d1020000-0000-0000-0000-0000000000f3', false);
select set_config('t.reuse', member_set_phone('d1020000-0000-0000-0000-00000000c011','09177777777')::text, false);
select set_config('request.jwt.claim.sub','', false); reset role;
select expect_true('a deleted member''s old phone is reusable',
  (current_setting('t.reuse')::jsonb) ->> 'ok' = 'true');
select expect_text('B now holds the reused number',
  (select phone from members where id='d1020000-0000-0000-0000-00000000c011'), '+639177777777');

-- ====================================== Decision 30: the core-only reader
-- A core and a flex occurrence, both free-first eligible to a fresh lead.
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, name, series_id, starts_at, ends_at, capacity, status, guarantee_tier, flex, minimum_bookings)
values
 ('d1020000-0000-0000-0000-00000000f0c0','d1020000-0000-0000-0000-000000000001','d1020000-0000-0000-0000-0000000000aa','d1020000-0000-0000-0000-0000000000c0','d1020000-0000-0000-0000-0000000000a0','Flow', null, now()+interval '3 days', now()+interval '3 days'+interval '50 min', 8,'scheduled','core', false, null),
 ('d1020000-0000-0000-0000-00000000f0f0','d1020000-0000-0000-0000-000000000001','d1020000-0000-0000-0000-0000000000aa','d1020000-0000-0000-0000-0000000000c0','d1020000-0000-0000-0000-0000000000a0','Flow', null, now()+interval '4 days', now()+interval '4 days'+interval '50 min', 8,'scheduled','flex', true, 3);
insert into members (id, studio_id, first_name, last_name, email, status)
values ('d1020000-0000-0000-0000-00000000d001','d1020000-0000-0000-0000-000000000001','Fin','','fin-d102@example.com','lead');

-- Limit OFF: both the core and the flex class are offered.
update studio_settings set free_first_core_only = false where studio_id='d1020000-0000-0000-0000-000000000001';
select expect_true('core-only off: flex class is in the picker list',
  exists(select 1 from free_first_eligible_classes_run('d1020000-0000-0000-0000-000000000001','d1020000-0000-0000-0000-00000000d001') r
         where r.occurrence_id = 'd1020000-0000-0000-0000-00000000f0f0'));
-- Limit ON: the flex class disappears, the core class stays.
update studio_settings set free_first_core_only = true where studio_id='d1020000-0000-0000-0000-000000000001';
select expect_true('core-only on: core class stays in the picker list',
  exists(select 1 from free_first_eligible_classes_run('d1020000-0000-0000-0000-000000000001','d1020000-0000-0000-0000-00000000d001') r
         where r.occurrence_id = 'd1020000-0000-0000-0000-00000000f0c0'));
select expect_true('core-only on: flex class is gone from the picker list',
  not exists(select 1 from free_first_eligible_classes_run('d1020000-0000-0000-0000-000000000001','d1020000-0000-0000-0000-00000000d001') r
         where r.occurrence_id = 'd1020000-0000-0000-0000-00000000f0f0'));

-- ========================================= member_bootstrap carries the flag
set role authenticated;
select set_config('request.jwt.claim.sub','d1020000-0000-0000-0000-0000000000f3', false);
select expect_true('member_bootstrap.free_first_core_only true when the limit is on',
  (select free_first_core_only from member_bootstrap('sa-d102')));
select set_config('request.jwt.claim.sub','', false); reset role;

-- ================================================= anon stays THIRTEEN
select expect_num('anon surface is THIRTEEN (suite helpers excluded)',
  (select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not like 'expect\_%'), 13);

rollback;
