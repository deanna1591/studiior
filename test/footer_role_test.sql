-- =============================================================================
-- Decision 80 note (20 Nov 2026): the billing footer line is for the owner.
-- =============================================================================
-- UUID space f0a7, checked free. Run after `supabase db reset`.
--
-- render_notification looks up the recipient's studio_staff role and passes it
-- to render_email. Only the owner gets "Your billing"; an instructor and a
-- front desk get the footer without it. A member's always-send email carries
-- the plain sentence "We always send this one. It is about your booking..."
-- =============================================================================
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function expect_eq(label text, actual text, want text)
returns void language plpgsql as $$
begin
  if actual is not distinct from want then raise notice 'PASS  %  (got %)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, want, coalesce(actual,'null'); end if;
end $$;

insert into auth.users (id) values
  ('f0a70000-0000-0000-0000-0000000000a1'),
  ('f0a70000-0000-0000-0000-0000000000e1'),
  ('f0a70000-0000-0000-0000-0000000000f1');
insert into profiles (id, email, full_name) values
  ('f0a70000-0000-0000-0000-0000000000a1','f0a7-owner@example.com','Olive Owner'),
  ('f0a70000-0000-0000-0000-0000000000e1','f0a7-coach@example.com','Cora Coach'),
  ('f0a70000-0000-0000-0000-0000000000f1','f0a7-desk@example.com','Dee Desk');
insert into studios (id, name, slug, timezone, currency, status, contact_email) values
  ('f0a70000-0000-0000-0000-0000000000a0','Footer Studio','f0a7-sa','UTC','PHP','active','desk@footer.example');
insert into studio_settings (studio_id) values ('f0a70000-0000-0000-0000-0000000000a0');
insert into studio_staff (studio_id, user_id, email, role) values
  ('f0a70000-0000-0000-0000-0000000000a0','f0a70000-0000-0000-0000-0000000000a1','f0a7-owner@example.com','owner'),
  ('f0a70000-0000-0000-0000-0000000000a0','f0a70000-0000-0000-0000-0000000000e1','f0a7-coach@example.com','instructor'),
  ('f0a70000-0000-0000-0000-0000000000a0','f0a70000-0000-0000-0000-0000000000f1','f0a7-desk@example.com','front_desk');
insert into members (id, studio_id, first_name, last_name, email) values
  ('f0a70000-0000-0000-0000-00000000c001','f0a70000-0000-0000-0000-0000000000a0','Mia','Member','f0a7-m@example.com');

-- One staff template sent to each of the three staff logins, and one always-send
-- member email (class_cancelled).
insert into notifications (id, studio_id, recipient_type, user_id, member_id, template_key, channel, payload, dedupe_key, scheduled_for, status) values
  ('f0a70000-0000-0000-0000-00000000aa01','f0a70000-0000-0000-0000-0000000000a0','staff','f0a70000-0000-0000-0000-0000000000a1',null,
     'availability_edited_by_studio','email','{"first_name":"Olive","month":"December 2026","change_lines":"Tue added","change_html":"<li>Tue added</li>","availability_url":"https://x"}','f0a7-1', now()+interval '1 day','scheduled'),
  ('f0a70000-0000-0000-0000-00000000aa02','f0a70000-0000-0000-0000-0000000000a0','staff','f0a70000-0000-0000-0000-0000000000e1',null,
     'availability_edited_by_studio','email','{"first_name":"Cora","month":"December 2026","change_lines":"Tue added","change_html":"<li>Tue added</li>","availability_url":"https://x"}','f0a7-2', now()+interval '1 day','scheduled'),
  ('f0a70000-0000-0000-0000-00000000aa03','f0a70000-0000-0000-0000-0000000000a0','staff','f0a70000-0000-0000-0000-0000000000f1',null,
     'availability_edited_by_studio','email','{"first_name":"Dee","month":"December 2026","change_lines":"Tue added","change_html":"<li>Tue added</li>","availability_url":"https://x"}','f0a7-3', now()+interval '1 day','scheduled'),
  ('f0a70000-0000-0000-0000-00000000aa04','f0a70000-0000-0000-0000-0000000000a0','member',null,'f0a70000-0000-0000-0000-00000000c001',
     'class_cancelled','email','{"first_name":"Mia","class_name":"Mat","when":"Monday 7 December 2026, 07:00"}','f0a7-4', now()+interval '1 day','scheduled');

select expect_eq('the owner gets the billing line (text)',
  (select (text_body like '%Your billing: %')::text from render_notification('f0a70000-0000-0000-0000-00000000aa01')), 'true');
select expect_eq('the owner gets the billing link (html)',
  (select (html_body like '%>Your billing</a>%')::text from render_notification('f0a70000-0000-0000-0000-00000000aa01')), 'true');
select expect_eq('a coach email carries no billing line (text)',
  (select (text_body like '%billing%')::text from render_notification('f0a70000-0000-0000-0000-00000000aa02')), 'false');
select expect_eq('a coach email carries no billing link (html)',
  (select (html_body like '%Your billing%')::text from render_notification('f0a70000-0000-0000-0000-00000000aa02')), 'false');
select expect_eq('a coach email still carries the studio contact in the footer',
  (select (text_body like '%desk@footer.example%')::text from render_notification('f0a70000-0000-0000-0000-00000000aa02')), 'true');
select expect_eq('a front desk email carries no billing line',
  (select (text_body like '%billing%')::text from render_notification('f0a70000-0000-0000-0000-00000000aa03')), 'false');
select expect_eq('a member always-send email uses the plain sentence',
  (select (text_body like '%We always send this one. It is about your booking or your membership.%')::text
     from render_notification('f0a70000-0000-0000-0000-00000000aa04')), 'true');
select expect_eq('the member footer carries no em dash',
  (select (strpos(text_body, 'We always send this one —') = 0 and strpos(html_body, 'We always send this one —') = 0)::text
     from render_notification('f0a70000-0000-0000-0000-00000000aa04')), 'true');
select expect_eq('render_email is closed to every client role',
  (has_function_privilege('authenticated','render_email(uuid,text,text,text,text,text,jsonb,text,text)','execute')
   or has_function_privilege('anon','render_email(uuid,text,text,text,text,text,jsonb,text,text)','execute'))::text, 'false');

select expect_eq('anon surface is EXACTLY FIFTEEN',
  (select count(*)::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and has_function_privilege('anon', p.oid, 'execute') and p.proname <> 'expect_eq'), '15');
select expect_eq('the webhook inbox table is closed to anon reads with RLS on',
  (select (not has_table_privilege('anon','resend_webhook_inbox','select') and relrowsecurity)::text
     from pg_class where relname='resend_webhook_inbox'), 'true');

select 'footer_role_test OK' as result;
