-- Decision 80a — the email frame + the re-dressed templates.
-- Space e804. Two studios: SA has a logo, an Instagram handle and an address and
-- a terracotta accent; SB is bare (no logo, no instagram, no address, no accent).
--
--   psql "$DB" -f test/email_frame_test.sql
--
-- Asserts: the 600px MSO-safe frame (logo vs name header, @instagram, address,
-- manage-emails); a re-dressed convert_after_class carries a plan card and EXACTLY
-- one button with the accent filled (no {accent} token left) and a paired text
-- colour; booking_confirmed carries a class card; email_on_accent pairs correctly.

\set ON_ERROR_STOP on

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
create or replace function expect_like(label text, actual text, pattern text)
returns void language plpgsql as $$
begin
  if actual like pattern then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected to match %, got %', label, pattern, left(coalesce(actual,'null'),400); end if;
end $$;
create or replace function expect_notlike(label text, actual text, pattern text)
returns void language plpgsql as $$
begin
  if actual not like pattern then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected NOT to match %', label, pattern; end if;
end $$;

-- helper: count a substring's occurrences
create or replace function ef_count(hay text, needle text) returns int
language sql immutable as $$ select (length(hay) - length(replace(hay, needle, ''))) / nullif(length(needle),0) $$;

-- ---- Fixtures ---------------------------------------------------------------
insert into auth.users (id) values ('e8040000-0000-0000-0000-0000000000a1');
insert into profiles (id, email) values ('e8040000-0000-0000-0000-0000000000a1','ef-owner@example.com');

-- SA: logo + instagram + address + terracotta accent
insert into studios (id, name, slug, timezone, currency, status, accent_color, logo_url, instagram_handle, contact_email, contact_phone)
values ('e8040000-0000-0000-0000-000000000001','Frame Studio','ef-sa','Europe/Prague','CZK','active',
        '#B85C38','https://cdn.example.com/logo.png','framestudio','hello@frame.example','0201234567');
insert into studio_settings (studio_id) values ('e8040000-0000-0000-0000-000000000001');
insert into locations (id, studio_id, name, is_primary, status, address) values
  ('e8040000-0000-0000-0000-00000000000c','e8040000-0000-0000-0000-000000000001','Main',true,'active',
   '{"line1":"12 High Street","city":"Prague","postal_code":"11000","country":"CZ"}'::jsonb);
insert into members (id, studio_id, first_name, last_name, email, status) values
  ('e8040000-0000-0000-0000-000000000a01'::uuid,'e8040000-0000-0000-0000-000000000001','Mia','Member','mia@frame.example','active');

-- SB: bare — no logo, no instagram, no accent, an active location with no address
insert into studios (id, name, slug, timezone, currency, status) values
  ('e8040000-0000-0000-0000-000000000002','Bare Studio','ef-sb','Europe/Prague','CZK','active');
insert into studio_settings (studio_id) values ('e8040000-0000-0000-0000-000000000002');
insert into locations (id, studio_id, name, is_primary, status) values
  ('e8040000-0000-0000-0000-00000000000d','e8040000-0000-0000-0000-000000000002','Main',true,'active');
insert into members (id, studio_id, first_name, last_name, email, status) values
  ('e8040000-0000-0000-0000-000000000b02'::uuid,'e8040000-0000-0000-0000-000000000002','Bo','Bare','bo@bare.example','active');

-- notifications to render
insert into notifications (id, studio_id, member_id, recipient_type, channel, template_key, payload, status, scheduled_for, dedupe_key) values
  ('e8040000-0000-0000-0000-0000000000f1','e8040000-0000-0000-0000-000000000001','e8040000-0000-0000-0000-000000000a01'::uuid,'member','email','convert_after_class',
   '{"class_name":"Reformer Flow","instructor_first_name":"Ada","offer_plan_name":"8 Classes Monthly","buy_url":"https://ef-sa.studiior.app/buy/abc"}'::jsonb,'scheduled',now(),'ef:convert'),
  ('e8040000-0000-0000-0000-0000000000f2','e8040000-0000-0000-0000-000000000001','e8040000-0000-0000-0000-000000000a01'::uuid,'member','email','booking_confirmed',
   '{"class_name":"Reformer Flow","when":"Mon 9 Nov, 07:00","where_line":", in Studio A","free_first_line":"","free_first_html":"","manage_link":"https://ef-sa.studiior.app/class/x"}'::jsonb,'scheduled',now(),'ef:booking'),
  ('e8040000-0000-0000-0000-0000000000f3','e8040000-0000-0000-0000-000000000001','e8040000-0000-0000-0000-000000000a01'::uuid,'member','email','flex_booking_pending',
   '{"class_name":"Mat Pilates","when":"Tue 10 Nov, 18:00","deadline_short":"20:00 Mon"}'::jsonb,'scheduled',now(),'ef:flexpending'),
  ('e8040000-0000-0000-0000-0000000000f4','e8040000-0000-0000-0000-000000000002','e8040000-0000-0000-0000-000000000b02'::uuid,'member','email','convert_after_class',
   '{"class_name":"Reformer Flow","instructor_first_name":"Ada","offer_plan_name":"Starter","buy_url":"https://ef-sb.studiior.app/buy/abc"}'::jsonb,'scheduled',now(),'ef:convertsb');

-- ============================================================================
-- 1. email_on_accent pairs a readable text colour
-- ============================================================================
select expect_text('email_on_accent: pale lime → dark ink', email_on_accent('#BEF738'), '#14170E');
select expect_text('email_on_accent: dark navy → white', email_on_accent('#1A2B4C'), '#FFFFFF');
select expect_text('email_on_accent: neutral grey → white', email_on_accent('#78716C'), '#FFFFFF');
select expect_text('email_on_accent: bad input → white (safe)', email_on_accent('nope'), '#FFFFFF');

-- ============================================================================
-- 2. SA frame — logo, @instagram, address, 600px, MSO
-- ============================================================================
select expect_like('SA frame: 600px table', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f1')), '%width="600"%');
select expect_like('SA frame: MSO ghost table', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f1')), '%[if mso]%');
select expect_like('SA frame: logo img on white', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f1')), '%<img src="https://cdn.example.com/logo.png"%');
select expect_like('SA frame: @instagram link', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f1')), '%instagram.com/framestudio%');
select expect_like('SA frame: address in footer', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f1')), '%12 High Street, Prague, 11000, CZ%');
select expect_like('SA frame: manage-emails link', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f1')), '%Choose which emails you get%');
select expect_like('SA frame: accent rule uses the studio accent', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f1')), '%height:3px;width:44px;background:#B85C38%');

-- ============================================================================
-- 3. convert_after_class — plan card + EXACTLY one button, accent filled
-- ============================================================================
select expect_text('convert: subject preserved',
  (select subject from render_notification('e8040000-0000-0000-0000-0000000000f1')), 'How was your first class?');
select expect_like('convert: a card (border)', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f1')), '%border:1px solid #E7E5E4%');
select expect_like('convert: plan name in the card', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f1')), '%8 Classes Monthly%');
select expect_num('convert: EXACTLY one button',
  (select ef_count(html_body, 'display:inline-block;padding:11px 24px') from render_notification('e8040000-0000-0000-0000-0000000000f1')), 1);
select expect_like('convert: buy url in the button', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f1')), '%href="https://ef-sa.studiior.app/buy/abc"%');
select expect_like('convert: button bg is the studio accent', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f1')), '%background:#B85C38%');
select expect_like('convert: button text paired white on terracotta', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f1')), '%color:#FFFFFF%');
select expect_notlike('convert: no {accent} token left', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f1')), '%{accent%');

-- ============================================================================
-- 4. booking_confirmed — a class card; flex_booking_pending — a class card
-- ============================================================================
select expect_like('booking_confirmed: class in a card', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f2')), '%border:1px solid #E7E5E4%');
select expect_like('booking_confirmed: class name shown', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f2')), '%Reformer Flow%');
select expect_like('booking_confirmed: a manage button', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f2')), '%href="https://ef-sa.studiior.app/class/x"%');
select expect_like('flex_pending: class in a card', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f3')), '%border:1px solid #E7E5E4%');
select expect_num('flex_pending: no button (nothing to do)',
  (select ef_count(html_body, 'display:inline-block;padding:11px 24px') from render_notification('e8040000-0000-0000-0000-0000000000f3')), 0);

-- ============================================================================
-- 5. SB frame — bare studio: name header (no img), no instagram, neutral accent
-- ============================================================================
select expect_notlike('SB frame: no logo img', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f4')), '%<img src=%');
select expect_like('SB frame: name header instead', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f4')), '%font-weight:600;font-size:18px;color:#14170E">Bare Studio%');
select expect_notlike('SB frame: no instagram link', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f4')), '%instagram.com/%');
select expect_like('SB frame: accent rule falls back to neutral grey', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f4')), '%width:44px;background:#78716C%');
select expect_notlike('SB frame: never Studiior lime', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f4')), '%#BEF738%');
select expect_notlike('SB frame: no {accent} token left', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f4')), '%{accent%');
select expect_like('SB frame: button text white on neutral', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f4')), '%color:#FFFFFF%');
select expect_like('SB frame: manage-emails link present', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f4')), '%Choose which emails you get%');

select 'email_frame_test OK' as result;
