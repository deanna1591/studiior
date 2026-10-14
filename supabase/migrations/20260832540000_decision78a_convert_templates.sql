-- Decision 78a — the six convert-sequence email templates. Pre-written, warm,
-- short, one call to action each; editable in the shared composer in 78c.
-- Single-brace placeholders resolved by render_notification; on conflict do
-- nothing so a re-run is a no-op. Schema/data only (no functions).
--
-- Placeholders the sweep provides: {first_name} {studio_name} {class_name}
-- {when} {instructor_first_name} {offer_plan_name} {offer_price} {offer_ends}
-- {buy_url} {plans_url} {book_url}. The sweep points {buy_url} at the intro offer
-- when one is set, else at the plans page, and sets {offer_plan_name} to the
-- plan's name (or "a membership" when no offer), so the copy reads either way.
-- Price/ends wording lives only in convert_last_day, which is sent only when an
-- offer is set.

insert into notification_templates (key, subject, text_body, html_body, note) values
  ('convert_before_class',
   'See you tomorrow at {studio_name}',
   E'Hi {first_name},\n\nYou''re booked for {class_name} on {when}. A few things to make it easy:\n\n- Wear something you can move in; we have everything else.\n- Come about 10 minutes early so {instructor_first_name} can show you around.\n- Water and a towel are handy.\n\nSee you there!\n\n— {studio_name}',
   '<p>Hi {first_name},</p><p>You''re booked for <strong>{class_name}</strong> on {when}. A few things to make it easy:</p><ul><li>Wear something you can move in; we have everything else.</li><li>Come about 10 minutes early so {instructor_first_name} can show you around.</li><li>Water and a towel are handy.</li></ul><p>See you there!</p><p>— {studio_name}</p>',
   'Decision 78a convert: evening before the free class.'),

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
   'Decision 78a convert: the window''s final day, only when an offer is set.'),

  ('convert_missed_you',
   'We missed you at {studio_name}',
   E'Hi {first_name},\n\nWe had you down for {class_name} and didn''t get to meet you — no problem at all. Your first class is still on us, so pick another time whenever suits:\n\n{book_url}\n\n— {studio_name}',
   '<p>Hi {first_name},</p><p>We had you down for <strong>{class_name}</strong> and didn''t get to meet you — no problem at all. Your first class is still on us, so pick another time whenever suits.</p><p><a href="{book_url}">Rebook your free class</a></p><p>— {studio_name}</p>',
   'Decision 78a convert: a no-show, once; their free class is offered again.')
on conflict (key) do nothing;
