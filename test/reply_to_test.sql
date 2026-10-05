-- =============================================================================
-- Decision 65 — the Reply-To header carries the studio's name.
-- UUID space: 4e65
-- =============================================================================
\set S '''4e654e65-0000-0000-0000-000000000001'''

create or replace function expect_true(label text, actual boolean) returns void language plpgsql as $$
begin if coalesce(actual,false) then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %  expected true, got %', label, coalesce(actual::text,'null'); end if; end $$;
create or replace function expect_text(label text, actual text, want text) returns void language plpgsql as $$
begin if actual is not distinct from want then raise notice 'PASS  %  (%)', label, coalesce(actual,'null');
  else raise exception 'FAIL  %  expected %, got %', label, coalesce(want,'null'), coalesce(actual,'null'); end if; end $$;

-- =============================================================================
-- (1) resend_reply_to — the one pure definition of the header value.
-- =============================================================================
select expect_text('a bare address is wrapped with the studio name',
  resend_reply_to('Reply Studio', 'desk@reply.example.com'), 'Reply Studio <desk@reply.example.com>');
select expect_text('a null address is no header',
  coalesce(resend_reply_to('Reply Studio', null), 'null'), 'null');
select expect_text('an empty address is no header',
  coalesce(resend_reply_to('Reply Studio', ''), 'null'), 'null');
select expect_text('an address that already has a display part is left as-is',
  resend_reply_to('Reply Studio', 'Front Desk <desk@reply.example.com>'), 'Front Desk <desk@reply.example.com>');
select expect_text('the from-name quote wash matches the From header',
  resend_reply_to('Pete "Big" Smith', 'desk@reply.example.com'), 'Pete Big Smith <desk@reply.example.com>');

-- --- Fixtures ----------------------------------------------------------------
insert into auth.users (id) values ('4e654e65-0000-0000-0000-00000000c001');
insert into profiles (id, email) values ('4e654e65-0000-0000-0000-00000000c001','4e65-m@example.com');
insert into studios (id, name, slug, timezone, currency, status, contact_email)
  values (:S,'Reply Studio','reply-studio','Europe/Prague','CZK','active','desk@reply.example.com');
insert into studio_settings (studio_id) values (:S);
insert into members (id, studio_id, first_name, last_name, email, status, user_id)
  values ('4e654e65-0000-0000-0000-0000000000a1',:S,'Mia','Member','4e65-m@example.com','active','4e654e65-0000-0000-0000-00000000c001');

-- A booking email and a hand-addressed campaign email. render_notification sets
-- from_name / reply_to from the STUDIO (template-agnostic), so a bare notifications
-- row is enough to read them.
insert into notifications (studio_id, recipient_type, member_id, template_key, channel, payload, dedupe_key, scheduled_for)
  values (:S,'member','4e654e65-0000-0000-0000-0000000000a1','booking_confirmed','email','{}','rt:booking', now());
insert into notifications (studio_id, recipient_type, member_id, template_key, channel, payload, dedupe_key, scheduled_for)
  values (:S,'member', null,'campaign','email',
          jsonb_build_object('to_email','4e65-m@example.com','subject','Hi','body','x','body_html','<p>x</p>','studio_name','Reply Studio'),
          'rt:campaign', now());
select set_config('rt.booking', (select id::text from notifications where dedupe_key='rt:booking'), false);
select set_config('rt.campaign', (select id::text from notifications where dedupe_key='rt:campaign'), false);

-- =============================================================================
-- (2) With contact_email set: render_notification feeds the bare address and the
--     studio name; the sent header (resend_reply_to of the two) is named. The From
--     name is the studio, unchanged, for a booking AND a campaign.
-- =============================================================================
select expect_text('booking reply_to resolves to the bare contact_email',
  (select reply_to from render_notification(current_setting('rt.booking')::uuid)), 'desk@reply.example.com');
select expect_text('booking from-name is the studio (From unchanged)',
  (select from_name from render_notification(current_setting('rt.booking')::uuid)), 'Reply Studio');
select expect_text('the booking header a send would carry is named',
  (select resend_reply_to(from_name, reply_to) from render_notification(current_setting('rt.booking')::uuid)),
  'Reply Studio <desk@reply.example.com>');

select expect_text('campaign reply_to resolves to the same bare contact_email',
  (select reply_to from render_notification(current_setting('rt.campaign')::uuid)), 'desk@reply.example.com');
select expect_text('campaign from-name is the studio (From unchanged)',
  (select from_name from render_notification(current_setting('rt.campaign')::uuid)), 'Reply Studio');
select expect_text('the campaign header a send would carry is named',
  (select resend_reply_to(from_name, reply_to) from render_notification(current_setting('rt.campaign')::uuid)),
  'Reply Studio <desk@reply.example.com>');

-- =============================================================================
-- (3) Off by default: with contact_email null there is no header, and the From
--     name is still the studio (nothing about From changed).
-- =============================================================================
update studios set contact_email = null where id = :S;
select expect_text('null contact_email → booking render reply_to is null',
  coalesce((select reply_to from render_notification(current_setting('rt.booking')::uuid)), 'null'), 'null');
select expect_text('null contact_email → no booking reply_to header',
  coalesce((select resend_reply_to(from_name, reply_to) from render_notification(current_setting('rt.booking')::uuid)), 'null'), 'null');
select expect_text('null contact_email → no campaign reply_to header',
  coalesce((select resend_reply_to(from_name, reply_to) from render_notification(current_setting('rt.campaign')::uuid)), 'null'), 'null');
select expect_text('from-name is still the studio with no contact_email',
  (select from_name from render_notification(current_setting('rt.booking')::uuid)), 'Reply Studio');

-- =============================================================================
-- (4) A fresh studio defaults to no reply-to (contact_email null).
-- =============================================================================
insert into studios (id, name, slug, timezone, currency, status)
  values ('4e654e65-0000-0000-0000-000000000002','Bare Studio','bare-reply','Europe/Prague','CZK','active');
select expect_text('a studio created without a contact_email has null (off by default)',
  coalesce((select contact_email from studios where id='4e654e65-0000-0000-0000-000000000002'), 'null'), 'null');

-- --- cleanup -----------------------------------------------------------------
drop function expect_true(text,boolean);
drop function expect_text(text,text,text);
