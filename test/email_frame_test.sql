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

-- Fluid frame (80 follow-up): the content card is width 100% / max-width 600px and
-- reflows on a phone — a <style> media query shrinks padding/text under 480px, and
-- images are capped. The fixed width:600px style is gone (the MSO ghost keeps the
-- width="600" attribute for Outlook, asserted above).
select expect_like('SA frame: fluid media query present', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f1')), '%@media only screen and (max-width:480px)%');
select expect_like('SA frame: fluid content card', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f1')), '%class="sd-card"%');
select expect_like('SA frame: card carries max-width:600px', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f1')), '%max-width:600px%');
select expect_like('SA frame: images capped to max-width 100%', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f1')), '%.sd-body img{max-width:100%%');
-- The fluid card is width:100% (not the old fixed width:600px); it carries max-width:600px.
select expect_like('SA frame: fluid card is width 100%', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f1')), '%style="width:100%;max-width:600px;background:#FFFFFF%');

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

-- ============================================================================
-- 6. Decision 80a fix — NO token ever reaches a member: render EVERY member-facing
--    template with a COMPLETE realistic context and assert no "{" remains in the
--    subject, html or text, and that nothing was stripped (every token resolved).
--    Plus: the class card's {class_line} (Day · time · room · with instructor), and
--    the plan card's offer_detail / offer_price / "Buy … — …" button.
-- ============================================================================
-- A small class so {class_line} resolves from occurrence_id.
insert into class_types (id, studio_id, name, color, duration_minutes, default_capacity) values
  ('e8040000-0000-0000-0000-00000000c7a1','e8040000-0000-0000-0000-000000000001','Reformer Flow','#B85C38',50,10);
insert into rooms (id, studio_id, location_id, name, capacity) values
  ('e8040000-0000-0000-0000-00000000c7b1','e8040000-0000-0000-0000-000000000001','e8040000-0000-0000-0000-00000000000c','Reformer Studio',10);
insert into instructors (id, studio_id, display_name, status) values
  ('e8040000-0000-0000-0000-00000000c7c1','e8040000-0000-0000-0000-000000000001','Ada Example','active');
insert into class_occurrences (id, studio_id, location_id, class_type_id, room_id, instructor_id, name,
    starts_at, ends_at, capacity, booked_count, status, staffing) values
  ('e8040000-0000-0000-0000-00000000c7d1','e8040000-0000-0000-0000-000000000001','e8040000-0000-0000-0000-00000000000c',
   'e8040000-0000-0000-0000-00000000c7a1','e8040000-0000-0000-0000-00000000c7b1','e8040000-0000-0000-0000-00000000c7c1','Reformer Flow',
   now()+interval '2 days', now()+interval '2 days'+interval '50 min', 10, 0, 'scheduled','assigned');

do $$
declare
  v_occ uuid := 'e8040000-0000-0000-0000-00000000c7d1';
  v_ctx jsonb := jsonb_build_object(
    'class_name','Reformer Flow','occurrence_id', v_occ,
    'when','Mon 09 Nov at 07:00','where_line',', in Reformer Studio',
    'when_short','tomorrow','when_time','7:00 AM','day','Monday','time','7:00 AM',
    'deadline_short','8:00 PM Sun','cancel_deadline','Sun 08 Nov',
    'manage_link','https://ef-sa.studiior.app/class/x','book_url','https://ef-sa.studiior.app/book',
    'schedule_url','https://ef-sa.studiior.app/book',
    'offer_plan_name','Intro Pack','offer_detail','3 classes · valid 30 days','offer_price','₱1,500',
    'offer_ends','20 Nov 2026','buy_url','https://ef-sa.studiior.app/buy/x',
    'plan_name','8 Classes Monthly','credits','3','credits_left','3',
    'expires_on','20 Nov 2026','ends_on','20 Nov 2026','renew_url','https://ef-sa.studiior.app/buy/x',
    'last_class','Reformer Flow','last_class_date','09 Nov','instructor_first','Ada','instructor_first_name','Ada',
    'days_since','10','product','Grip socks','quantity','1');
  k text; v_nid uuid; r record; v_n int := 0;
  v_keys text[] := array[
    'booking_confirmed','free_booking_confirmed','flex_booking_pending','flex_booking_confirmed',
    'flex_booking_not_confirmed','class_reminder','convert_before_class','convert_after_class',
    'convert_day3','convert_day7','convert_last_day','convert_missed_you',
    'keep_renew_7','keep_renew_1','keep_renew_0','keep_lapsed_3','keep_credits_7','keep_credits_2',
    'keep_winback_30','keep_winback_60','keep_drifting','membership_expiring','credit_expiry',
    'product_order_paid'];
  -- retention_* are composer SEEDS (sent via the `retention` passthrough with the
  -- composer's rendered html, never rendered directly), so their text_body carries
  -- composer markup — not a directly-rendered template.
begin
  foreach k in array v_keys loop
    v_nid := gen_random_uuid();
    insert into notifications (id, studio_id, member_id, recipient_type, channel, template_key, payload, status, scheduled_for, dedupe_key)
    values (v_nid,'e8040000-0000-0000-0000-000000000001','e8040000-0000-0000-0000-000000000a01','member','email',
            k, v_ctx || jsonb_build_object('to_email','mia@frame.example'), 'scheduled', now(), 'every:'||k);
    select * into r from render_notification(v_nid);
    -- The fluid frame carries a <style> media query, whose CSS braces are legit;
    -- strip it before checking the BODY for a leftover {token}.
    if position('{' in coalesce(r.subject,'')) > 0
       or position('{' in regexp_replace(coalesce(r.html_body,''), '<style>[^<]*</style>', '', 'g')) > 0
       or position('{' in coalesce(r.text_body,'')) > 0 then
      raise exception 'FAIL  template % leaked a brace', k;
    end if;
    if coalesce(array_length(r.stripped,1),0) > 0 then
      raise exception 'FAIL  template % left tokens unresolved: %', k, array_to_string(r.stripped,', ');
    end if;
    v_n := v_n + 1;
  end loop;
  raise notice 'PASS  every member-facing template (%) renders with no brace and nothing stripped', v_n;
end $$;

-- The class card's one detail line, built from the occurrence (Decision 80a fix).
insert into notifications (id, studio_id, member_id, recipient_type, channel, template_key, payload, status, scheduled_for, dedupe_key) values
  ('e8040000-0000-0000-0000-0000000000f5','e8040000-0000-0000-0000-000000000001','e8040000-0000-0000-0000-000000000a01','member','email','booking_confirmed',
   jsonb_build_object('class_name','Reformer Flow','occurrence_id','e8040000-0000-0000-0000-00000000c7d1','where_line','','free_first_html','','manage_link','https://ef-sa.studiior.app/c'),'scheduled',now(),'classline');
select expect_like('class_line: room in the detail', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f5')), '%Reformer Studio%');
select expect_like('class_line: with instructor', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f5')), '%with Ada%');
select expect_like('class_line: separated by middots', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f5')), '% · %');

-- The plan card's detail + price + a specific "Buy … — …" button.
insert into notifications (id, studio_id, member_id, recipient_type, channel, template_key, payload, status, scheduled_for, dedupe_key) values
  ('e8040000-0000-0000-0000-0000000000f6','e8040000-0000-0000-0000-000000000001','e8040000-0000-0000-0000-000000000a01','member','email','convert_after_class',
   jsonb_build_object('class_name','Reformer Flow','instructor_first_name','Ada','offer_plan_name','Intro Pack','offer_detail','3 classes · valid 30 days','offer_price','₱1,500','buy_url','https://ef-sa.studiior.app/buy/x'),'scheduled',now(),'plancard');
select expect_like('plan card: detail line', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f6')), '%3 classes · valid 30 days%');
select expect_like('plan card: price line', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f6')), '%₱1,500%');
select expect_like('plan card: specific button label', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f6')), '%Buy Intro Pack — ₱1,500%');
select expect_notlike('plan card: no "See your options"', (select html_body from render_notification('e8040000-0000-0000-0000-0000000000f6')), '%See your options%');

-- The strip belt: a required token missing is stripped AND surfaced; a known-optional
-- one (where_line / free_first_html) is not.
insert into notifications (id, studio_id, member_id, recipient_type, channel, template_key, payload, status, scheduled_for, dedupe_key) values
  ('e8040000-0000-0000-0000-0000000000f7','e8040000-0000-0000-0000-000000000001','e8040000-0000-0000-0000-000000000a01','member','email','booking_confirmed',
   jsonb_build_object('class_name','X','occurrence_id','e8040000-0000-0000-0000-00000000c7d1'),'scheduled',now(),'strip');
select expect_like('strip: a missing required token is reported in stripped',
  (select array_to_string(stripped,',') from render_notification('e8040000-0000-0000-0000-0000000000f7')), '%manage_link%');
select expect_notlike('strip: a known-optional token is NOT reported',
  (select array_to_string(stripped,',') from render_notification('e8040000-0000-0000-0000-0000000000f7')), '%free_first_html%');
select expect_num('strip: no brace survives in the body',
  (select case when position('{' in regexp_replace(html_body, '<style>[^<]*</style>', '', 'g'))>0 then 1 else 0 end
     from render_notification('e8040000-0000-0000-0000-0000000000f7')), 0);

-- fmt_money + plan_card_detail
select expect_text('fmt_money PHP whole → ₱1,500', fmt_money(150000, 'PHP'), '₱1,500');
select expect_text('fmt_money CZK suffix', fmt_money(150000, 'CZK'), '1,500 Kč');
select expect_text('fmt_money USD with cents', fmt_money(149950, 'USD'), '$1,499.50');

select 'email_frame_test OK' as result;
