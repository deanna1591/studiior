-- Decision 80d — preview_template renders the real frame with no notification row. Space b080.
\set ON_ERROR_STOP on
begin;

create or replace function expect(p_cond boolean, p_label text) returns void
language plpgsql as $$ begin
  if p_cond then raise notice 'PASS: %', p_label;
  else raise exception 'FAIL: %', p_label; end if;
end $$;

insert into auth.users (id) values ('b0800000-0000-0000-0000-0000000000a1');  -- a plain member login
insert into profiles (id, email) select id, id::text||'@example.com'
  from auth.users where id::text like 'b080%';

insert into studios (id, name, slug, timezone, currency, country, accent_color)
values ('b0800000-0000-0000-0000-000000000001', 'Preview Studio', 'preview-b080', 'Asia/Manila', 'PHP', 'PH', '#B85C38');
insert into locations (id, studio_id, name, status, is_primary)
values ('b0800000-0000-0000-0000-00000000100c', 'b0800000-0000-0000-0000-000000000001', 'Main', 'active', true);
insert into membership_plans (id, studio_id, name, type, price_cents, currency, credits, validity_days, status, visibility)
values ('b0800000-0000-0000-0000-00000000ab01', 'b0800000-0000-0000-0000-000000000001',
        'Intro Pack', 'class_pack', 150000, 'PHP', 3, 14, 'active', 'public');
insert into studio_settings (studio_id, intro_offer_plan_id)
values ('b0800000-0000-0000-0000-000000000001', 'b0800000-0000-0000-0000-00000000ab01');

insert into class_types (id, studio_id, name, default_capacity, duration_minutes, status)
values ('b0800000-0000-0000-0000-0000000000c1', 'b0800000-0000-0000-0000-000000000001', 'Reformer Preview', 8, 50, 'active');
insert into rooms (id, studio_id, location_id, name, capacity, status)
values ('b0800000-0000-0000-0000-00000000cd01', 'b0800000-0000-0000-0000-000000000001', 'b0800000-0000-0000-0000-00000000100c', 'Studio A', 8, 'active');
insert into instructors (id, studio_id, display_name, status)
values ('b0800000-0000-0000-0000-00000000ef01', 'b0800000-0000-0000-0000-000000000001', 'Ada Preview', 'active');
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id,
                               name, starts_at, ends_at, capacity, status)
values ('b0800000-0000-0000-0000-0000000000f1', 'b0800000-0000-0000-0000-000000000001',
        'b0800000-0000-0000-0000-00000000100c',
        'b0800000-0000-0000-0000-0000000000c1', 'b0800000-0000-0000-0000-00000000cd01',
        'b0800000-0000-0000-0000-00000000ef01',
        'Reformer Preview', now() + interval '2 days', now() + interval '2 days' + interval '50 min', 8, 'scheduled');

-- The call: a draft body (already-rendered HTML, as the server action supplies it) with tokens.
create temporary table _p as
  select preview_template('b0800000-0000-0000-0000-000000000001', 'convert_after_class',
    'Your subject, {first_name}',
    '<p>Hi {first_name}, you tried {class_name}. {offer_price} to keep going.</p>') as r;

-- 1. The REAL frame, not a hand-built look-alike.
select expect((select r->>'html' from _p) like '%width="600"%', '1 html carries the 600px frame');
select expect((select r->>'html' from _p) like '%[if mso]%', '1b html carries the MSO ghost table');
select expect((select r->>'html' from _p) like '%#B85C38%', '1c html carries the studio accent rule');
select expect((select r->>'html' from _p) like '%Preview Studio%', '1d html carries the studio name (header/footer)');

-- 2. Sample tokens are FILLED, no raw braces survive.
select expect((select r->>'html' from _p) like '%Reformer Preview%', '2 {class_name} filled from the sample context');
select expect((select r->>'html' from _p) like '%' || chr(8369) || '1,500%', '2b {offer_price} filled (peso)');
select expect((select r->>'subject' from _p) like 'Your subject,%' and (select r->>'subject' from _p) not like '%{first_name}%',
  '2c {first_name} filled in the subject');
select expect((select r->>'html' from _p) not like '%{class_name}%' and (select r->>'html' from _p) not like '%{first_name}%',
  '2d no raw token survives in the body');
select expect(coalesce(jsonb_array_length((select r->'stripped' from _p)), 0) = 0, '2e nothing stripped');

-- 3. NO notification row is written — a live preview never queues mail.
select expect((select count(*) from notifications where studio_id = 'b0800000-0000-0000-0000-000000000001') = 0,
  '3 zero notification rows after a preview call');

-- 4. Manager-up guard: a plain member is refused.
do $$
declare ok boolean := false;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub','b0800000-0000-0000-0000-0000000000a1','role','authenticated')::text, true);
  set local role authenticated;
  begin
    perform preview_template('b0800000-0000-0000-0000-000000000001', 'convert_after_class', 's', '<p>x</p>');
  exception when others then
    if sqlstate = 'PT403' then ok := true; end if;
  end;
  reset role;
  if not ok then raise exception 'FAIL: 4 a non-manager was not refused PT403'; end if;
  raise notice 'PASS: 4 a non-manager is refused PT403';
end $$;

-- 5. The anon surface is unchanged.
select expect((select count(*) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                where ns.nspname = 'public'
                  and has_function_privilege('anon', p.oid, 'execute')
                  and p.proname not like 'expect%') = 13,
  '5 anon surface is exactly THIRTEEN');

rollback;
