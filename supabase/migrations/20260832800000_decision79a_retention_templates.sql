-- Decision 79a — retention email templates.
--
-- The FIVE retention_<situation> templates hold the warm seed copy the composer
-- pre-fills from (editable at /settings/templates, group "Retention"). The owner
-- edits that copy for this one member and sends it, so the SENT body is whatever
-- is in the composer — carried in the payload and emitted by ONE passthrough
-- template `retention` (subject {subject}, body {body}, html {body_html}), the
-- same mechanism campaigns use. Keeping the send on a `retention` key (not
-- `campaign`) means notification_wanted gates it on sequence_email, not on
-- marketing consent — a member who muted the sequences is not emailed by it.
--
-- creates: templates retention, retention_unconverted, retention_at_risk,
--          retention_drifting, retention_expiring, retention_lapsed

insert into notification_templates (key, subject, text_body, html_body, note) values
-- The passthrough the sender renders the composer's content through.
('retention', '{subject}', E'{body}', E'{body_html}',
 'Retention outreach — the body comes from the composer; the five retention_<situation> templates are the seed copy.'),

('retention_unconverted',
 'Come back for more, {first_name}?',
 E'Hi {first_name},\n\nIt was lovely having you in for {last_class} on {last_class_date} with {instructor_first}. We would love to see you again.\n\nYour first class was on us — if you enjoyed it, {offer_plan_name} is a gentle way to keep going. You can grab it here: {buy_url}\n\nAny questions, just reply to this email.\n\n{studio_name}',
 E'<p>Hi {first_name},</p><p>It was lovely having you in for {last_class} on {last_class_date} with {instructor_first}. We would love to see you again.</p><p>Your first class was on us — if you enjoyed it, {offer_plan_name} is a gentle way to keep going. <a href="{buy_url}">Grab it here</a>.</p><p>Any questions, just reply to this email.</p><p>{studio_name}</p>',
 'Seed copy — unconverted free class.'),

('retention_at_risk',
 'We have missed you, {first_name}',
 E'Hi {first_name},\n\nI noticed it has been {days_since} days since your last class, and I wanted to check in — no pressure at all. You were coming so regularly and we have missed you on the {last_class} mat.\n\nIf something got in the way, tell me and we will sort it. Otherwise, your next class is ready when you are: {book_url}\n\nWarmly,\n{studio_name}',
 E'<p>Hi {first_name},</p><p>I noticed it has been {days_since} days since your last class, and I wanted to check in — no pressure at all. You were coming so regularly and we have missed you on the {last_class} mat.</p><p>If something got in the way, tell me and we will sort it. Otherwise, your next class is ready when you are: <a href="{book_url}">book here</a>.</p><p>Warmly,<br>{studio_name}</p>',
 'Seed copy — at risk. Reads like a person wrote it.'),

('retention_drifting',
 'Still here when you are ready, {first_name}',
 E'Hi {first_name},\n\nJust a soft note — we have not seen you in a little while and wanted you to know the mat is always here. No rush, no pressure.\n\nWhenever you fancy it, here is the timetable: {book_url}\n\n{studio_name}',
 E'<p>Hi {first_name},</p><p>Just a soft note — we have not seen you in a little while and wanted you to know the mat is always here. No rush, no pressure.</p><p>Whenever you fancy it, here is <a href="{book_url}">the timetable</a>.</p><p>{studio_name}</p>',
 'Seed copy — drifting. Soft.'),

('retention_expiring',
 'Your {plan_name} is nearly up, {first_name}',
 E'Hi {first_name},\n\nA quick heads-up: your {plan_name} ends on {expires_on}. If you would like to keep your spot and your rhythm going, you can renew here: {buy_url}\n\nSee you on the mat,\n{studio_name}',
 E'<p>Hi {first_name},</p><p>A quick heads-up: your {plan_name} ends on {expires_on}. If you would like to keep your spot and your rhythm going, you can <a href="{buy_url}">renew here</a>.</p><p>See you on the mat,<br>{studio_name}</p>',
 'Seed copy — expiring membership.'),

('retention_lapsed',
 'Come back and move with us, {first_name}',
 E'Hi {first_name},\n\nIt has been a little while since your {plan_name} wrapped up, and we would genuinely love to have you back.\n\nIf you are ready, here is a fresh start: {buy_url}\n\nAnd if there is anything we could do better, just reply — I read every one.\n\n{studio_name}',
 E'<p>Hi {first_name},</p><p>It has been a little while since your {plan_name} wrapped up, and we would genuinely love to have you back.</p><p>If you are ready, here is <a href="{buy_url}">a fresh start</a>.</p><p>And if there is anything we could do better, just reply — I read every one.</p><p>{studio_name}</p>',
 'Seed copy — lapsed / win-back.')
on conflict (key) do nothing;
