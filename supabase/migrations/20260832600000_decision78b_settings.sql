-- Decision 78b (Keep) — the keep-sequence switch and its eight templates, plus a
-- re-assert of the four convert "sell" templates (78a item 0: their CTA is
-- {buy_url}, which the sweep resolves to /buy/{intro_offer_plan_id} when an
-- offer is set, else /account/plan — already the behaviour; re-asserted here).
--
-- Schema/data only (no functions).

alter table studio_settings
  add column keep_sequence_enabled boolean not null default false;

comment on column studio_settings.keep_sequence_enabled is
  'Decision 78b: the keep sequence (renewal/credit/win-back). Default off. '
  'While ON it REPLACES the standard expiry mail for this studio — '
  'sweep_membership_expiring and queue_credit_expiries skip this studio; while '
  'OFF both behave exactly as before.';

-- The eight keep templates. Single-brace placeholders resolved by
-- render_notification; on conflict do nothing so a re-run is a no-op. The sweep
-- provides {first_name} {studio_name} {plan_name} {expires_on} {credits_left}
-- {buy_url} {book_url} {schedule_url}.
insert into notification_templates (key, subject, text_body, html_body, note) values
  ('keep_renew_7',
   'Your {plan_name} ends in a week',
   E'Hi {first_name},\n\nYour {plan_name} at {studio_name} ends on {expires_on}. Renewing keeps your spot and takes a moment:\n\n{buy_url}\n\n— {studio_name}',
   '<p>Hi {first_name},</p><p>Your <strong>{plan_name}</strong> at {studio_name} ends on {expires_on}. Renewing keeps your spot and takes a moment.</p><p><a href="{buy_url}">Renew now</a></p><p>— {studio_name}</p>',
   'Decision 78b keep: 7 days before a membership ends.'),

  ('keep_renew_1',
   'Your {plan_name} ends tomorrow',
   E'Hi {first_name},\n\nA quick reminder — your {plan_name} at {studio_name} ends tomorrow ({expires_on}). Renew to keep going without a gap:\n\n{buy_url}\n\n— {studio_name}',
   '<p>Hi {first_name},</p><p>A quick reminder — your <strong>{plan_name}</strong> at {studio_name} ends tomorrow ({expires_on}). Renew to keep going without a gap.</p><p><a href="{buy_url}">Renew now</a></p><p>— {studio_name}</p>',
   'Decision 78b keep: 1 day before.'),

  ('keep_renew_0',
   'Your {plan_name} ends today',
   E'Hi {first_name},\n\nYour {plan_name} at {studio_name} ends today. If you''d like to keep your spot, renewing takes a moment:\n\n{buy_url}\n\n— {studio_name}',
   '<p>Hi {first_name},</p><p>Your <strong>{plan_name}</strong> at {studio_name} ends today. If you''d like to keep your spot, renewing takes a moment.</p><p><a href="{buy_url}">Renew now</a></p><p>— {studio_name}</p>',
   'Decision 78b keep: the day it ends.'),

  ('keep_lapsed_3',
   'We kept your spot at {studio_name}',
   E'Hi {first_name},\n\nYour {plan_name} ended a few days ago, but your spot is still here — no need to start over. Pick up where you left off whenever you''re ready:\n\n{buy_url}\n\n— {studio_name}',
   '<p>Hi {first_name},</p><p>Your {plan_name} ended a few days ago, but your spot is still here — no need to start over. Pick up where you left off whenever you''re ready.</p><p><a href="{buy_url}">Come back</a></p><p>— {studio_name}</p>',
   'Decision 78b keep: 3 days after a lapse, no replacement.'),

  ('keep_credits_7',
   'You have {credits_left} classes left',
   E'Hi {first_name},\n\nYou have {credits_left} classes left at {studio_name}, and they expire on {expires_on}. Here is this week''s schedule so none go to waste:\n\n{schedule_url}\n\n— {studio_name}',
   '<p>Hi {first_name},</p><p>You have <strong>{credits_left}</strong> classes left at {studio_name}, and they expire on {expires_on}. Here is this week''s schedule so none go to waste.</p><p><a href="{schedule_url}">Book a class</a></p><p>— {studio_name}</p>',
   'Decision 78b keep: 7 days before pack credits expire.'),

  ('keep_credits_2',
   'Last days for your classes',
   E'Hi {first_name},\n\nJust a nudge — your {credits_left} remaining classes at {studio_name} expire on {expires_on}. Grab a spot this week:\n\n{schedule_url}\n\n— {studio_name}',
   '<p>Hi {first_name},</p><p>Just a nudge — your <strong>{credits_left}</strong> remaining classes at {studio_name} expire on {expires_on}. Grab a spot this week.</p><p><a href="{schedule_url}">Book a class</a></p><p>— {studio_name}</p>',
   'Decision 78b keep: 2 days before pack credits expire.'),

  ('keep_winback_30',
   'We''d love to see you back',
   E'Hi {first_name},\n\nIt''s been a few weeks since your last class at {studio_name}, and we''d love to see you again. Come back whenever suits — your first step is here:\n\n{buy_url}\n\n— {studio_name}',
   '<p>Hi {first_name},</p><p>It''s been a few weeks since your last class at {studio_name}, and we''d love to see you again. Come back whenever suits.</p><p><a href="{buy_url}">Come back</a></p><p>— {studio_name}</p>',
   'Decision 78b keep: 30 days after a membership ends, no membership since.'),

  ('keep_winback_60',
   'Your spot at {studio_name} is still here',
   E'Hi {first_name},\n\nStill thinking about coming back? Your spot at {studio_name} is here whenever you''re ready — no pressure, no catch:\n\n{buy_url}\n\n— {studio_name}',
   '<p>Hi {first_name},</p><p>Still thinking about coming back? Your spot at {studio_name} is here whenever you''re ready — no pressure, no catch.</p><p><a href="{buy_url}">Come back</a></p><p>— {studio_name}</p>',
   'Decision 78b keep: 60 days after, then silence.')
on conflict (key) do nothing;

-- 78a item 0 — re-assert the four convert "sell" templates (on conflict do
-- update) so {buy_url} is their call to action; the sweep resolves it to
-- /buy/{intro_offer_plan_id} when an offer is set, else /account/plan.
insert into notification_templates (key, subject, text_body, html_body, note) values
  ('convert_after_class',
   'How was your first class?',
   E'Hi {first_name},\n\nWe hope you enjoyed {class_name} with {instructor_first_name}. If it felt good, the easiest way to keep going is {offer_plan_name} — have a look whenever you''re ready:\n\n{buy_url}\n\n— {studio_name}',
   '<p>Hi {first_name},</p><p>We hope you enjoyed <strong>{class_name}</strong> with {instructor_first_name}. If it felt good, the easiest way to keep going is {offer_plan_name} — have a look whenever you''re ready.</p><p><a href="{buy_url}">See your options</a></p><p>— {studio_name}</p>',
   'Decision 78a convert: 2h after the class, checked in only.'),

  ('convert_day3',
   'Your next class at {studio_name}',
   E'Hi {first_name},\n\nReady for round two? {offer_plan_name} keeps it simple, and the schedule is here whenever you want to book:\n\n{buy_url}\n\n— {studio_name}',
   '<p>Hi {first_name},</p><p>Ready for round two? {offer_plan_name} keeps it simple, and you can book whenever you want.</p><p><a href="{buy_url}">Keep going</a></p><p>— {studio_name}</p>',
   'Decision 78a convert: day 3, if not yet purchased.'),

  ('convert_day7',
   'Still thinking it over?',
   E'Hi {first_name},\n\nNo rush — your spot at {studio_name} is here when you want it. If you''d like to come back, {offer_plan_name} is the easiest start:\n\n{buy_url}\n\n— {studio_name}',
   '<p>Hi {first_name},</p><p>No rush — your spot at {studio_name} is here when you want it. If you''d like to come back, {offer_plan_name} is the easiest start.</p><p><a href="{buy_url}">Come back</a></p><p>— {studio_name}</p>',
   'Decision 78a convert: day 7, if not yet purchased.'),

  ('convert_last_day',
   'Last day for your intro offer',
   E'Hi {first_name},\n\nToday is the last day to start with {offer_plan_name} ({offer_price}) — it''s open until {offer_ends}. If you''ve been meaning to come back, this is the moment:\n\n{buy_url}\n\n— {studio_name}',
   '<p>Hi {first_name},</p><p>Today is the last day to start with <strong>{offer_plan_name}</strong> ({offer_price}) — it''s open until {offer_ends}. If you''ve been meaning to come back, this is the moment.</p><p><a href="{buy_url}">Start now</a></p><p>— {studio_name}</p>',
   'Decision 78a convert: the window''s final day, only when an offer is set.')
on conflict (key) do update set
  subject = excluded.subject, text_body = excluded.text_body, html_body = excluded.html_body;
