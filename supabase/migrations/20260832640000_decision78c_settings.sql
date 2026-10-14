-- Decision 78c (Act) — the retention-tasks switch, the drifting/task-copy
-- templates, the composer override table, and the task close-note.
--
-- Schema/data only (no functions).

alter table studio_settings
  add column retention_tasks_enabled boolean not null default false;
comment on column studio_settings.retention_tasks_enabled is
  'Decision 78c: turn health-band retention tasks on (at_risk tasks, drifting FYI, '
  'the soft drifting email). Default off. Needs the health refresh the sweep runs.';

-- The sweep closes an at_risk/drifting task when the member recovers; the note
-- records why.
alter table member_tasks add column close_note text;

-- Templates. keep_drifting is a member email; the two task_* templates are the
-- staff-side Viber copy, rendered into a task's suggested_message and editable in
-- the composer. On conflict do nothing.
insert into notification_templates (key, subject, text_body, html_body, note) values
  ('keep_drifting',
   'We haven''t seen you at {studio_name}',
   E'Hi {first_name},\n\nWe''ve missed you at {studio_name} — it''s been a little while. No pressure at all; here is this week''s schedule if you''d like to drop back in:\n\n{schedule_url}\n\n— {studio_name}',
   '<p>Hi {first_name},</p><p>We''ve missed you at {studio_name} — it''s been a little while. No pressure at all; here is this week''s schedule if you''d like to drop back in.</p><p><a href="{schedule_url}">This week''s classes</a></p><p>— {studio_name}</p>',
   'Decision 78c: the soft drifting email, once per 30 days.'),

  ('task_at_risk_message',
   'At-risk outreach',
   E'Hi {first_name}, it''s {studio_name}. We''ve noticed it''s been a while and wanted to check in — is everything OK? We''d love to help you get back into a rhythm. Anything we can do?',
   '<p>Hi {first_name}, it''s {studio_name}. We''ve noticed it''s been a while and wanted to check in — is everything OK? We''d love to help you get back into a rhythm. Anything we can do?</p>',
   'Decision 78c: the Viber copy a staff member sends an at-risk member (rendered into the task).'),

  ('task_unconverted_message',
   'Unconverted outreach',
   E'Hi {first_name}! It''s {studio_name} — hope you enjoyed your first class. If you''d like to keep going, {offer_plan_name} is a lovely place to start. Any questions, just message me here.',
   '<p>Hi {first_name}! It''s {studio_name} — hope you enjoyed your first class. If you''d like to keep going, {offer_plan_name} is a lovely place to start. Any questions, just message me here.</p>',
   'Decision 78c: the Viber copy for a day-7 unconverted member (rendered into the task).')
on conflict (key) do nothing;

-- Per-studio template overrides, edited in the composer. render_notification
-- prefers an override when present. body is the raw markup the staff typed;
-- body_html is renderBody(body).html (the sender escapes/renders in Next, so the
-- SQL never parses markup).
create table notification_templates_overrides (
  studio_id  uuid not null references studios on delete cascade,
  key        text not null,
  subject    text not null,
  body       text not null,
  body_html  text not null,
  updated_by uuid references profiles,
  updated_at timestamptz not null default now(),
  primary key (studio_id, key)
);
alter table notification_templates_overrides enable row level security;
-- Manager-up read and write; the composer edits under this policy.
create policy template_overrides_manager on notification_templates_overrides
  for all using (coalesce(is_manager_up(studio_id), false))
  with check (coalesce(is_manager_up(studio_id), false));
grant select, insert, update, delete on notification_templates_overrides to authenticated;
