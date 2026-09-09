-- =============================================================================
-- Migration 054: Decision 18, part two — cover requests, escalation, and the
--                notifications that were never sent
-- =============================================================================
-- An instructor who cannot teach a class ASKS. Staff always answer. There is no
-- self-release at any notice, which is Decision 9's rule about the timetable and
-- matters most exactly when it is most tempting to break.
--
-- REQUESTING COVER CHANGES NOTHING ABOUT WHO IS TEACHING. The class stays
-- assigned to the original instructor until staff act. A cover request is a row
-- in its own table and does not touch class_occurrences at all.
--
-- The schema makes the bad pair unreachable, but NOT by refusing it. Migration
-- 047's occ_staffing_matches_instructor forbids staffing='open' beside a
-- non-null instructor_id, and it never fires, because tg_derive_staffing() runs
-- first and silently rewrites staffing to agree with instructor_id. A stray
-- `set staffing = 'open'` therefore SUCCEEDS and leaves the row 'assigned'.
-- That is the right outcome and the wrong mental model: reading the constraint
-- alone, you would expect a bad write to raise, and it does not. The only way
-- to release a class is to clear the instructor on purpose, which is what
-- approve_cover_request does through move_occurrence().
--
-- Also here, because Decision 18 is the moment they stop being acceptable:
--   * queue_substitution() has existed since migration 030 WITH NO CALLER, so
--     changing a class's instructor has told the booked members nothing.
--   * Nothing has ever told an instructor they were given a class.
--   * send_due_notifications() claims every scheduled row regardless of
--     channel, so the first push row anyone queues gets posted to Resend and
--     delivered as an email.
-- =============================================================================

alter table studio_settings
  add column if not exists cover_escalation_hours int not null default 4,
  add column if not exists commitment_shortfall_weeks int not null default 2;

comment on column studio_settings.cover_escalation_hours is
  'Decision 18: an unanswered cover request this close to the class becomes the '
  'loudest thing in the product.';
comment on column studio_settings.commitment_shortfall_weeks is
  'How many consecutive weeks under the agreed minimum before the brief raises '
  'it. One week under is a holiday and everybody knows it.';

-- -----------------------------------------------------------------------------
-- The request
-- -----------------------------------------------------------------------------
-- status is text with a check, not an enum, for the reason recorded three times
-- in CLAUDE.md: a new enum value cannot be USED in the transaction that adds it,
-- so an enum here would cost a separate migration the first time this grows a
-- state. shift_applications made the same call.
create table if not exists cover_requests (
  id             uuid primary key default gen_random_uuid(),
  studio_id      uuid not null references studios on delete cascade,
  occurrence_id  uuid not null references class_occurrences on delete cascade,
  -- Who is asking. Kept even after the class is reassigned, because "who handed
  -- this over" is the question the record exists to answer.
  instructor_id  uuid not null references instructors on delete cascade,
  reason         text,
  status         text not null default 'pending'
                 check (status in ('pending','approved','declined','withdrawn')),
  -- How it was settled, once it was: a named replacement or an open shift.
  resolution     text check (resolution in ('assigned','opened')),
  covered_by     uuid references instructors on delete set null,
  requested_at   timestamptz not null default now(),
  decided_by     uuid references profiles on delete set null,
  decided_at     timestamptz,
  decision_note  text,
  -- Stamped when the escalation sweep first shouts about it, so the sweep can
  -- tell "nobody has been told" from "everybody has been told twice".
  escalated_at   timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index if not exists cover_requests_open
  on cover_requests (studio_id, status) where status = 'pending';
create index if not exists cover_requests_occ on cover_requests (occurrence_id);

-- One LIVE request per instructor per class. They may ask again after
-- withdrawing or being declined, so this is partial rather than a plain unique.
create unique index if not exists cover_requests_one_live
  on cover_requests (occurrence_id, instructor_id) where status = 'pending';

drop trigger if exists cover_requests_updated on cover_requests;
create trigger cover_requests_updated before update on cover_requests
  for each row execute function set_updated_at();

alter table cover_requests enable row level security;
grant select, insert, update, delete on cover_requests to authenticated;
grant all on cover_requests to service_role;

create policy cover_requests_staff_read on cover_requests for select
  using (studio_id in (select auth_staff_studios()));
create policy cover_requests_manager_all on cover_requests for all
  using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));
-- An instructor sees and raises their own. They cannot DECIDE one — every
-- write path that changes status goes through a SECURITY DEFINER function with
-- its own manager check, and this policy only lets them insert their own row.
create policy cover_requests_self_insert on cover_requests for insert
  with check (instructor_id = auth_instructor_id(studio_id));

comment on table cover_requests is
  'Decision 18. An instructor asks to be released from a class; staff always '
  'answer. The class stays assigned to them until staff act.';

-- -----------------------------------------------------------------------------
-- Templates
-- -----------------------------------------------------------------------------
insert into notification_templates (key, subject, text_body, html_body, note) values
('instructor_assigned',
 'You''re teaching {class_name} on {when}',
 E'Hi {first_name},\n\nYou''ve been put down to teach {class_name} on {when}{where_line}.\n\n{booked_line}\n\nIf you can''t make it, ask the studio for cover as early as you can — you stay on the class until they find someone.',
 E'<p>Hi {first_name},</p><p>You''ve been put down to teach <strong>{class_name}</strong> on {when}{where_line}.</p><p>{booked_line}</p><p>If you can''t make it, ask the studio for cover as early as you can — you stay on the class until they find someone.</p>',
 'Decision 18. Nothing told an instructor they had been given a class; they found out by looking.'),

('cover_requested',
 '{instructor_name} needs cover for {class_name}',
 E'Hi {first_name},\n\n{instructor_name} has asked for cover for {class_name} on {when}.\n\n{reason_line}{booked_line}\n\nThey are still on the class until you act. Assign someone, or open it up: {cover_url}',
 E'<p>Hi {first_name},</p><p><strong>{instructor_name}</strong> has asked for cover for {class_name} on {when}.</p><p>{reason_line}{booked_line}</p><p>They are still on the class until you act. <a href="{cover_url}">Assign someone, or open it up</a></p>',
 'To every owner and manager the moment a cover request arrives.'),

('cover_urgent',
 'Still no cover for {class_name} — it starts in {hours_line}',
 E'Hi {first_name},\n\n{instructor_name} asked for cover for {class_name} and nobody has answered. It starts in {hours_line}.\n\n{booked_line}\n\nThis one needs deciding now: {cover_url}',
 E'<p>Hi {first_name},</p><p><strong>{instructor_name}</strong> asked for cover for {class_name} and nobody has answered. It starts in <strong>{hours_line}</strong>.</p><p>{booked_line}</p><p><a href="{cover_url}">This one needs deciding now</a></p>',
 'The escalation. Repeats the request when the class is inside cover_escalation_hours and nobody has answered.'),

('cover_approved',
 'You''re off {class_name} on {when}',
 E'Hi {first_name},\n\nThe studio has covered {class_name} on {when}. You are no longer on it.\n\n{cover_line}',
 E'<p>Hi {first_name},</p><p>The studio has covered <strong>{class_name}</strong> on {when}. You are no longer on it.</p><p>{cover_line}</p>',
 'To the instructor who asked, once cover is actually arranged.'),

('cover_declined',
 'You''re still on {class_name} on {when}',
 E'Hi {first_name},\n\nThe studio could not arrange cover for {class_name} on {when}, so you are still teaching it.\n\n{reason_line}Talk to them if that is a problem.',
 E'<p>Hi {first_name},</p><p>The studio could not arrange cover for <strong>{class_name}</strong> on {when}, so you are still teaching it.</p><p>{reason_line}Talk to them if that is a problem.</p>',
 'Declining a cover request has to be unambiguous: the class did not move and they are still on it.')
on conflict (key) do nothing;

-- -----------------------------------------------------------------------------
-- Telling an instructor they have a class
-- -----------------------------------------------------------------------------
create or replace function queue_instructor_assigned(p_occurrence_id uuid)
returns uuid
language plpgsql security definer set search_path = public as $$
declare o class_occurrences%rowtype; s studios%rowtype; v_user uuid; v_room text;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found or o.instructor_id is null then return null; end if;
  select * into s from studios where id = o.studio_id;
  v_user := instructor_user_id(o.instructor_id);
  if v_user is null then return null; end if;
  select name into v_room from rooms where id = o.room_id;

  return queue_shift_notice(
    o.studio_id, v_user, 'instructor_assigned',
    jsonb_build_object(
      'class_name', o.name,
      'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth, HH24:MI'),
      'where_line', case when v_room is null then '' else ' in ' || v_room end,
      'booked_line', case when o.booked_count > 0
        then format('%s member%s booked in so far.', o.booked_count,
                    case when o.booked_count = 1 then ' is' else 's are' end)
        else 'Nobody has booked yet.' end),
    -- Keyed on the instructor AND the time, so being reassigned after a move is
    -- a second notice rather than a silent no-op on the dedupe index.
    'instructor_assigned:' || o.id || ':' || o.instructor_id || ':' || extract(epoch from o.starts_at)::bigint);
end $$;

-- -----------------------------------------------------------------------------
-- Ask
-- -----------------------------------------------------------------------------
create or replace function request_cover(p_occurrence_id uuid, p_reason text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  o class_occurrences%rowtype; s studios%rowtype; st studio_settings%rowtype;
  v_instr uuid; v_req cover_requests%rowtype; v_hours numeric; v_urgent boolean;
  v_name text; n int;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then
    raise exception 'no such class' using errcode = 'PT404';
  end if;
  select * into s  from studios        where id = o.studio_id;
  select * into st from studio_settings where studio_id = o.studio_id;

  v_instr := auth_instructor_id(o.studio_id);

  -- Manager-up may raise one on an instructor's behalf — a text message at 6am
  -- is how this actually arrives, and the desk should be able to record it
  -- rather than telling the instructor to open the app first.
  if v_instr is null or v_instr is distinct from o.instructor_id then
    if not is_manager_up(o.studio_id) then
      raise exception 'only the instructor teaching this class may ask for cover'
        using errcode = 'PT403';
    end if;
    v_instr := o.instructor_id;
  end if;

  if v_instr is null then
    raise exception 'this class has nobody teaching it, so there is nothing to cover'
      using errcode = 'PT422';
  end if;
  if o.status <> 'scheduled' then
    raise exception 'this class is not running' using errcode = 'PT422';
  end if;
  if o.starts_at <= now() then
    raise exception 'this class has already started' using errcode = 'PT422';
  end if;

  insert into cover_requests (studio_id, occurrence_id, instructor_id, reason)
  values (o.studio_id, o.id, v_instr, nullif(btrim(p_reason), ''))
  on conflict (occurrence_id, instructor_id) where status = 'pending' do nothing
  returning * into v_req;

  if v_req.id is null then
    select * into v_req from cover_requests
     where occurrence_id = o.id and instructor_id = v_instr and status = 'pending';
    return jsonb_build_object('ok', true, 'already_open', true,
                              'request_id', v_req.id);
  end if;

  select display_name into v_name from instructors where id = v_instr;
  v_hours  := extract(epoch from o.starts_at - now()) / 3600;
  v_urgent := v_hours <= coalesce(st.cover_escalation_hours, 4);

  -- Loud immediately if it is already inside the window. Waiting for the sweep
  -- would cost up to fifteen minutes on the one request that cannot spare them.
  n := queue_shift_notice_to_staff(
    o.studio_id,
    case when v_urgent then 'cover_urgent' else 'cover_requested' end,
    jsonb_build_object(
      'instructor_name', v_name,
      'class_name', o.name,
      'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth, HH24:MI'),
      'hours_line', case when v_hours < 1
                         then round(v_hours * 60) || ' minutes'
                         else round(v_hours) || ' hour' ||
                              case when round(v_hours) = 1 then '' else 's' end end,
      'reason_line', case when nullif(btrim(coalesce(p_reason,'')), '') is null then ''
                          else 'They said: ' || btrim(p_reason) || E'\n\n' end,
      'booked_line', case when o.booked_count > 0
        then format('%s member%s booked.', o.booked_count,
                    case when o.booked_count = 1 then ' is' else 's are' end)
        else 'Nobody has booked yet.' end,
      'cover_url', '/shifts/cover'),
    'cover_req:' || v_req.id || case when v_urgent then ':urgent' else '' end);

  if v_urgent then
    update cover_requests set escalated_at = now() where id = v_req.id;
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (o.studio_id, auth.uid(), 'cover.requested', 'cover_requests', v_req.id,
          jsonb_build_object('occurrence_id', o.id, 'instructor_id', v_instr,
                             'urgent', v_urgent, 'notified', n));

  return jsonb_build_object('ok', true, 'request_id', v_req.id,
                            'urgent', v_urgent, 'notified_staff', n,
                            'still_assigned_to', v_instr);
end $$;

-- -----------------------------------------------------------------------------
-- Answer
-- -----------------------------------------------------------------------------
-- p_mode 'assign' names a replacement; 'open' publishes it as an open shift and
-- hands it to Decision 17's application flow, unchanged.
create or replace function approve_cover_request(
  p_request_id uuid, p_mode text, p_instructor_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  req cover_requests%rowtype; o class_occurrences%rowtype; s studios%rowtype;
  st studio_settings%rowtype; v_move jsonb; v_old text; v_new text;
  v_cut timestamptz; v_late boolean; v_subs int := 0; v_user uuid;
  v_told boolean := false;
begin
  select * into req from cover_requests where id = p_request_id;
  if not found then
    raise exception 'no such cover request' using errcode = 'PT404';
  end if;
  if not is_manager_up(req.studio_id) then
    raise exception 'only owners and managers may answer a cover request'
      using errcode = 'PT403';
  end if;
  if req.status <> 'pending' then
    raise exception 'this request has already been answered' using errcode = 'PT409';
  end if;
  if p_mode not in ('assign', 'open') then
    raise exception 'mode must be assign or open' using errcode = 'PT422';
  end if;
  if p_mode = 'assign' and p_instructor_id is null then
    raise exception 'assigning cover needs somebody to assign it to'
      using errcode = 'PT422';
  end if;
  if p_mode = 'assign' and p_instructor_id = req.instructor_id then
    raise exception 'that is the instructor who asked to be taken off it'
      using errcode = 'PT422';
  end if;

  select * into o  from class_occurrences where id = req.occurrence_id;
  select * into s  from studios           where id = req.studio_id;
  select * into st from studio_settings   where studio_id = req.studio_id;
  select display_name into v_old from instructors where id = req.instructor_id;

  -- move_occurrence() is the only thing that moves a class, and that includes
  -- changing who teaches it: the exclusion constraints, the availability
  -- warning and the audit entry are all already there. p_confirm is true
  -- because the caller has just been shown the booked count on the approval
  -- screen — this is the confirmation.
  v_move := move_occurrence(
    p_occurrence_id   => req.occurrence_id,
    p_instructor_id   => case when p_mode = 'assign' then p_instructor_id else null end,
    p_confirm         => true,
    p_clear_instructor=> (p_mode = 'open'));

  if not (v_move ->> 'ok')::boolean then
    -- The replacement is busy. Refused rather than forced: two classes for one
    -- person at one time is the thing the constraint exists to prevent, and a
    -- cover request is not a reason to make an exception.
    return v_move;
  end if;

  update cover_requests
     set status = 'approved',
         resolution = case when p_mode = 'assign' then 'assigned' else 'opened' end,
         covered_by = case when p_mode = 'assign' then p_instructor_id end,
         decided_by = auth.uid(), decided_at = now()
   where id = req.id;

  -- Decision 2, finally called. queue_substitution() has existed since
  -- migration 030 with nothing invoking it, so until now changing a class's
  -- instructor told the booked members nothing whatsoever.
  -- Read outside the booked_count branch: the name is needed for the reply and
  -- for the message to the instructor who asked, both of which happen whether
  -- or not anybody is booked in.
  if p_mode = 'assign' then
    select display_name into v_new from instructors where id = p_instructor_id;
  end if;

  if p_mode = 'assign' and o.booked_count > 0 then
    v_subs := queue_substitution(req.occurrence_id, v_old, v_new);

    -- "Announced after the cancellation cutoff has already passed." Three days'
    -- notice is normal policy; ninety minutes is not, because by then the
    -- member can no longer decide about it.
    v_cut  := o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0));
    v_late := now() > v_cut;
    if v_late and coalesce(st.sub_late_free_cancel, true) then
      update bookings
         set free_cancel_until = o.starts_at
       where occurrence_id = req.occurrence_id and status = 'booked';
    end if;
  end if;

  -- The person who asked, told they are off it.
  v_user := instructor_user_id(req.instructor_id);
  if v_user is not null then
    perform queue_shift_notice(req.studio_id, v_user, 'cover_approved',
      jsonb_build_object(
        'class_name', o.name,
        'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth, HH24:MI'),
        'cover_line', case when p_mode = 'assign'
          then coalesce(v_new, 'Someone else') || ' is taking it.'
          else 'It has been opened up for another instructor to pick up.' end),
      'cover_approved:' || req.id);
  end if;

  -- And the replacement, told they have a class — IF WE CAN REACH THEM. An
  -- instructor is a teaching record and `instructors` carries no email of its
  -- own, so one with staff_id null has no address anywhere in the schema. That
  -- is the common case, not an edge: two of the three seeded instructors have
  -- no login. Reported back rather than swallowed, so the screen can say "tell
  -- them yourself" instead of implying an email went out.
  if p_mode = 'assign' then
    v_told := queue_instructor_assigned(req.occurrence_id) is not null;
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (req.studio_id, auth.uid(), 'cover.approved', 'cover_requests', req.id,
          jsonb_build_object('instructor_id', req.instructor_id),
          jsonb_build_object('mode', p_mode, 'covered_by', p_instructor_id,
                             'members_told', v_subs, 'free_cancel', v_late));

  return jsonb_build_object('ok', true, 'mode', p_mode,
                            'members_told', v_subs,
                            'free_cancellation_granted', coalesce(v_late, false),
                            'cover_notified', v_told,
                            'cover_name', v_new,
                            'move', v_move);
end $$;

create or replace function decline_cover_request(
  p_request_id uuid, p_reason text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare req cover_requests%rowtype; o class_occurrences%rowtype;
        s studios%rowtype; v_user uuid;
begin
  select * into req from cover_requests where id = p_request_id;
  if not found then
    raise exception 'no such cover request' using errcode = 'PT404';
  end if;
  if not is_manager_up(req.studio_id) then
    raise exception 'only owners and managers may answer a cover request'
      using errcode = 'PT403';
  end if;
  if req.status <> 'pending' then
    raise exception 'this request has already been answered' using errcode = 'PT409';
  end if;

  select * into o from class_occurrences where id = req.occurrence_id;
  select * into s from studios where id = req.studio_id;

  update cover_requests
     set status = 'declined', decided_by = auth.uid(), decided_at = now(),
         decision_note = nullif(btrim(p_reason), '')
   where id = req.id;

  -- The class was never touched, so there is nothing to undo. That is the whole
  -- reason a request does not release the class the moment it is made.
  v_user := instructor_user_id(req.instructor_id);
  if v_user is not null then
    perform queue_shift_notice(req.studio_id, v_user, 'cover_declined',
      jsonb_build_object(
        'class_name', o.name,
        'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth, HH24:MI'),
        'reason_line', case when nullif(btrim(coalesce(p_reason,'')), '') is null then ''
                            else 'They said: ' || btrim(p_reason) || E'\n\n' end),
      'cover_declined:' || req.id);
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (req.studio_id, auth.uid(), 'cover.declined', 'cover_requests', req.id,
          jsonb_build_object('reason', p_reason));
  return jsonb_build_object('ok', true, 'still_assigned_to', req.instructor_id);
end $$;

create or replace function withdraw_cover_request(p_request_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare req cover_requests%rowtype;
begin
  select * into req from cover_requests where id = p_request_id;
  if not found then
    raise exception 'no such cover request' using errcode = 'PT404';
  end if;
  if req.instructor_id is distinct from auth_instructor_id(req.studio_id)
     and not is_manager_up(req.studio_id) then
    raise exception 'only the instructor who asked may take it back'
      using errcode = 'PT403';
  end if;
  if req.status <> 'pending' then
    raise exception 'this request has already been answered' using errcode = 'PT409';
  end if;

  update cover_requests set status = 'withdrawn' where id = req.id;
  -- Any unsent shout about it is now describing a request that no longer
  -- exists. Same reasoning as move_occurrence deleting a superseded class_moved.
  delete from notifications
   where status = 'scheduled'
     and template_key in ('cover_requested','cover_urgent')
     and dedupe_key like 'cover_req:' || req.id || '%';
  return jsonb_build_object('ok', true);
end $$;

-- -----------------------------------------------------------------------------
-- Escalation
-- -----------------------------------------------------------------------------
-- Runs on the same cadence as the brief scheduler. A request that was raised
-- three days out and is now four hours out has to become loud on its own — the
-- moment it was made is not the moment it became urgent.
create or replace function sweep_cover_escalations() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; v_hours numeric;
begin
  if not is_service_context() and not is_platform_admin() then
    raise exception 'only the scheduler may sweep cover requests' using errcode = 'PT403';
  end if;

  for r in
    select cr.id, cr.studio_id, cr.occurrence_id, cr.instructor_id,
           o.name, o.starts_at, o.booked_count, s.timezone,
           i.display_name,
           coalesce(st.cover_escalation_hours, 4) as window_hours
      from cover_requests cr
      join class_occurrences o on o.id = cr.occurrence_id
      join studios s           on s.id = cr.studio_id
      join instructors i       on i.id = cr.instructor_id
      left join studio_settings st on st.studio_id = cr.studio_id
     where cr.status = 'pending'
       and cr.escalated_at is null
       and o.status = 'scheduled'
       and o.starts_at > now()
       and o.starts_at <= now() + make_interval(hours => coalesce(st.cover_escalation_hours, 4))
  loop
    v_hours := extract(epoch from r.starts_at - now()) / 3600;
    perform queue_shift_notice_to_staff(r.studio_id, 'cover_urgent',
      jsonb_build_object(
        'instructor_name', r.display_name,
        'class_name', r.name,
        'when', to_char(r.starts_at at time zone r.timezone, 'FMDay FMDD FMMonth, HH24:MI'),
        'hours_line', case when v_hours < 1
                           then round(v_hours * 60) || ' minutes'
                           else round(v_hours) || ' hour' ||
                                case when round(v_hours) = 1 then '' else 's' end end,
        'booked_line', case when r.booked_count > 0
          then format('%s member%s booked.', r.booked_count,
                      case when r.booked_count = 1 then ' is' else 's are' end)
          else 'Nobody has booked yet.' end,
        'cover_url', '/shifts/cover'),
      'cover_req:' || r.id || ':urgent');
    update cover_requests set escalated_at = now() where id = r.id;
    n := n + 1;
  end loop;
  return n;
end $$;


-- -----------------------------------------------------------------------------
-- The worker only ever meant email
-- -----------------------------------------------------------------------------
-- Replaced from the LIVE definition, which is already ahead of migration 040's
-- file: the staff-message bridge was added after it.
CREATE OR REPLACE FUNCTION public.send_due_notifications()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r record; v_req bigint; n_posted int := 0; n_failed int := 0; n_bridged int := 0;
  v_batch int; v_max int;
begin
  if not is_service_context() then
    raise exception 'the notification worker runs as the backend, not as a user'
      using errcode = 'PT403';
  end if;

  v_batch := coalesce(notification_setting('batch_size')::int, 50);
  v_max   := coalesce(notification_setting('max_attempts')::int, 3);

  -- Messages written by staff (migration 022) join the same queue rather than
  -- getting their own sender. send_message() moves a draft to 'queued' and
  -- stops; this is the thing that was always going to pick it up.
  for r in select * from messages where status = 'queued' loop
    if queue_notification(r.studio_id, r.member_id, 'staff_message',
         jsonb_build_object('subject', r.subject,
                            'body', r.body,
                            'body_html', '<p>' || replace(
                                replace(r.body, '&', '&amp;'), E'\n\n', '</p><p>') || '</p>'),
         'message:' || r.id) is not null
    then n_bridged := n_bridged + 1; end if;
    update messages set status = 'sent', sent_at = now() where id = r.id;
  end loop;

  for r in
    update notifications
       set status = 'sending', claimed_at = now(), attempts = attempts + 1
     where id in (
       select id from notifications
        where status = 'scheduled'
          and scheduled_for <= now()
          and attempts < v_max
          -- Decision 18. This worker posts to Resend and always has. It used
          -- to claim EVERY scheduled row regardless of channel, so the first
          -- push row anyone queued would have been delivered as an email to
          -- whatever address the recipient happened to have. push_subscriptions
          -- has existed since migration 001 with nothing writing it and there
          -- is no transport, so a push row now waits for one instead.
          and channel = 'email'
        order by scheduled_for
        limit v_batch
        for update skip locked
     )
    returning *
  loop
    begin
      v_req := deliver_notification(r.id);
      update notifications set net_request_id = v_req where id = r.id;
      n_posted := n_posted + 1;
    exception when others then
      -- Including the missing-key case. The row keeps its error and its
      -- attempt count; the cron survives.
      update notifications
         set status = 'failed', failed_at = now(), error = sqlerrm
       where id = r.id;
      n_failed := n_failed + 1;
    end;
  end loop;

  return jsonb_build_object('posted', n_posted, 'failed', n_failed,
                            'messages_bridged', n_bridged);
end $function$
;

revoke execute on function request_cover(uuid, text)                        from public, anon, authenticated;
revoke execute on function approve_cover_request(uuid, text, uuid)          from public, anon, authenticated;
revoke execute on function decline_cover_request(uuid, text)                from public, anon, authenticated;
revoke execute on function withdraw_cover_request(uuid)                     from public, anon, authenticated;
revoke execute on function queue_instructor_assigned(uuid)                  from public, anon, authenticated;
revoke execute on function sweep_cover_escalations()                        from public, anon, authenticated;
revoke execute on function send_due_notifications()                         from public, anon, authenticated;
grant execute on function request_cover(uuid, text)               to authenticated, service_role;
grant execute on function approve_cover_request(uuid, text, uuid) to authenticated, service_role;
grant execute on function decline_cover_request(uuid, text)       to authenticated, service_role;
grant execute on function withdraw_cover_request(uuid)            to authenticated, service_role;
grant execute on function sweep_cover_escalations()               to service_role;
grant execute on function send_due_notifications()                to service_role;
-- queue_instructor_assigned stays callable by nobody: it is an internal, and
-- migration 033 exists because five of these were reachable by any signed-in
-- member of any studio.

-- -----------------------------------------------------------------------------
-- The clock
-- -----------------------------------------------------------------------------
do $cron$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron unavailable; cover escalation not scheduled';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'studiior-cover-escalations') then
    perform cron.unschedule('studiior-cover-escalations');
  end if;
  -- Every five minutes, not fifteen. The brief scheduler can afford quarter of
  -- an hour because it is delivering a summary of yesterday; this one is
  -- counting down to a class starting in four hours, and fifteen minutes is a
  -- twentieth of the whole window.
  perform cron.schedule('studiior-cover-escalations', '*/5 * * * *',
    $job$select sweep_cover_escalations()$job$);
end $cron$;

-- -----------------------------------------------------------------------------
-- The one place Decision 18 OVERTURNS Decision 17 rather than extending it
-- -----------------------------------------------------------------------------
-- Decision 17's edge said: "an approved instructor withdraws — the class returns
-- to open, staff are notified, and it is loud." withdraw_from_shift() implements
-- exactly that, and it is unconditional self-release: it clears instructor_id
-- and sets staffing = 'open' with nobody's approval.
--
-- Decision 18 says staff always approve, no self-release, however urgent. Both
-- cannot be true, and a rule with a button next to it that breaks the rule is
-- decorative. So withdrawing from an ASSIGNED class now RAISES A COVER REQUEST.
-- The instructor stays on the class, the studio still hears immediately and
-- loudly with the booked count, and a person decides.
--
-- What is NOT changed: withdrawing a PENDING APPLICATION. Nobody is counting on
-- you before you have been approved, and taking your name off a list you put it
-- on is not releasing a class. That path never went through here.
create or replace function withdraw_from_shift(p_occurrence_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare occ class_occurrences%rowtype; v_res jsonb;
begin
  select * into occ from class_occurrences where id = p_occurrence_id;
  if not found then
    raise exception 'no such class' using errcode = 'PT404';
  end if;
  if auth_instructor_id(occ.studio_id) is distinct from occ.instructor_id then
    raise exception 'you are not teaching that class' using errcode = 'PT403';
  end if;

  -- Everything this used to do, minus the release. request_cover() carries the
  -- same staff notification and the same booked count, plus the escalation the
  -- old path had no concept of.
  v_res := request_cover(p_occurrence_id, 'Withdrawn from the shift they took');

  return jsonb_build_object(
    'occurrence_id', occ.id,
    'booked_count', occ.booked_count,
    -- Named so a caller cannot mistake this for the old behaviour. Anything
    -- still reading `released` gets null rather than a quiet false.
    'cover_requested', true,
    'still_assigned', true,
    'request_id', v_res ->> 'request_id');
end $$;
revoke execute on function withdraw_from_shift(uuid) from public, anon;
grant execute on function withdraw_from_shift(uuid) to authenticated;

comment on function withdraw_from_shift(uuid) is
  'Decision 18 overturns Decision 17 here: withdrawing raises a cover request '
  'rather than releasing the class. The instructor stays on it until staff act.';
