-- =============================================================================
-- MIGRATION 022 — messages to a member
--
-- One person writing to one member. Not `notifications`, which is the system's
-- automated queue and is keyed by template_key, dedupe_key and scheduled_for
-- because nothing there has an author. These have an author, and the author
-- reads every one before it goes.
--
-- Nothing sends. `send_message()` moves a draft to 'queued' and stops, so the
-- transport — Resend, SES, an SMTP relay — arrives later as one adapter that
-- reads queued rows and moves them to sent or failed. That is a job to write,
-- not a refactor of this.
--
-- Business Rules §11: nothing AI-drafted sends itself, and this is the same
-- shape one step earlier. `message_draft_for()` composes; a person edits and
-- presses send. The draft is never queued on the member's behalf and there is
-- no code path from "compose a draft" to "queued" that skips a human.
-- =============================================================================

create type message_status as enum ('draft', 'queued', 'sent', 'failed');

create table messages (
  id          uuid primary key default gen_random_uuid(),
  studio_id   uuid not null references studios on delete cascade,
  member_id   uuid not null references members on delete cascade,
  -- notif_channel already has email | push | in_app. Only email is reachable
  -- today, and the constraint says so out loud rather than leaving a column
  -- that looks configurable and is not.
  channel     notif_channel not null default 'email',
  subject     text not null,
  body        text not null,
  status      message_status not null default 'draft',
  template_key text,
  created_by  uuid references profiles on delete set null,
  sent_at     timestamptz,
  error       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint messages_email_only check (channel = 'email'),
  constraint messages_body_not_blank check (length(btrim(body)) > 0),
  constraint messages_subject_not_blank check (length(btrim(subject)) > 0)
);

create index on messages (studio_id, member_id, created_at desc);
create index on messages (status) where status = 'queued';

create trigger messages_updated before update on messages
  for each row execute function set_updated_at();

alter table messages enable row level security;

-- Permissions §12: "Send a message to a member" is Owner, Manager and Front
-- Desk. Instructors never — and that is is_desk_up, which excludes them, not a
-- hidden button.
create policy messages_desk_all on messages
  for all using (is_desk_up(studio_id)) with check (is_desk_up(studio_id));

grant select, insert, update, delete on messages to authenticated;
grant all on messages to service_role;

-- -----------------------------------------------------------------------------
-- Drafts live in a table, not in the application
--
-- Same shape as plan_templates (migration 008): studio_id null is a system
-- template, and a studio may later own a row of its own that shadows it. The
-- studio's voice is the studio's business, and a studio that wants to rewrite
-- "haven't seen you in a couple of weeks" should not need a deploy.
-- -----------------------------------------------------------------------------
create table message_templates (
  id         uuid primary key default gen_random_uuid(),
  studio_id  uuid references studios on delete cascade,
  key        text not null,
  subject    text not null,
  body       text not null,
  note       text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (studio_id, key)
);
create unique index message_templates_system_key
  on message_templates (key) where studio_id is null;

create trigger message_templates_updated before update on message_templates
  for each row execute function set_updated_at();

alter table message_templates enable row level security;

create policy templates_read on message_templates
  for select using (studio_id is null or is_desk_up(studio_id));
create policy templates_manager_write on message_templates
  for all using (studio_id is not null and is_manager_up(studio_id))
  with check (studio_id is not null and is_manager_up(studio_id));

grant select, insert, update, delete on message_templates to authenticated;
grant all on message_templates to service_role;

-- One per reason, because the reasons are not interchangeable. A member whose
-- card was declined does not want to hear that they have been missed; they
-- want to know what to do about the card.
insert into message_templates (studio_id, key, subject, body, note) values
(null, 'rhythm_deviation',
 'Missing you at {studio}',
 E'Hi {first_name} — haven''t seen you in {gap_phrase}, everything okay?\n\n{slot_line}\n\nNo pressure at all, just wanted to check in.\n\n{studio}',
 'Was coming regularly and has gone quiet. Warm, short, no guilt, and an easy way back in.'),

(null, 'booking_drift',
 'Everything okay?',
 E'Hi {first_name} — I noticed you''ve had to drop a few classes lately. If the times have stopped working for you, tell me what would suit and I''ll see what I can do.\n\n{studio}',
 'Still booking, stopped turning up. Assume a scheduling problem before assuming a motivation one.'),

(null, 'first_month_stalled',
 'How did you get on?',
 E'Hi {first_name} — you joined us {joined_phrase} and I wanted to see how you got on.\n\nThe first few weeks are the hardest part of building a habit, so if you would like a hand picking a class that fits around you, just say the word.\n\n{studio}',
 'Joined recently and stalled. The most rescuable member there is — ask a question rather than making an offer.'),

(null, 'payment_state',
 'Your card didn''t go through',
 E'Hi {first_name} — your last payment didn''t go through, so your membership is on hold until it''s sorted. Nothing is lost and nothing has been cancelled.\n\nPop in and we can sort it at the desk in a minute, or reply to this and I''ll send you a payment link.\n\nIf the card is fine and it keeps failing, tell me and I''ll chase it from this end.\n\n{studio}',
 'Factual, not apologetic, and not a sales note. They cannot book until this is fixed, so the fix is the whole message.'),

(null, 'expiry_declining_use',
 'Your membership renews soon',
 E'Hi {first_name} — your membership renews shortly, and I noticed you have not been using all of it lately.\n\nIf the plan has stopped fitting, we can move you to a smaller one rather than have you pay for classes you are not taking. Happy either way — just wanted to say it before it renews rather than after.\n\n{studio}',
 'The renewal decision is made before the renewal date. Offering the smaller plan first is what keeps them.'),

(null, 'new_member',
 'Welcome to {studio}',
 E'Hi {first_name} — glad to have you with us.\n\nIf you tell me what you are hoping to get out of it, I can point you at the classes and the instructor that will suit you best.\n\n{studio}',
 'Joined under two weeks ago. The signals do not apply yet, so this is a welcome and not an intervention.'),

(null, 'general',
 'A note from {studio}',
 E'Hi {first_name} —\n\n{studio}',
 'Fallback when there is no reason on file. Deliberately almost empty: with nothing to say, an empty page is more honest than a filled one.');

-- -----------------------------------------------------------------------------
-- Composing a draft
--
-- The band knows the member has not been in for fourteen days and used to come
-- every four. The draft uses that and does not recite it — "haven't seen you in
-- a couple of weeks" is what a person writes; "your attendance has declined by
-- 71%" is what gets deleted unread. So the numbers are rounded into language on
-- the way out, and the member's usual slot is looked up so the note sounds like
-- it came from someone who knows them.
-- -----------------------------------------------------------------------------
create function message_gap_phrase(p_days int) returns text
language sql immutable as $$
  select case
    when p_days is null then 'a while'
    when p_days <= 10   then 'a little while'
    when p_days <= 17   then 'a couple of weeks'
    when p_days <= 31   then 'a few weeks'
    when p_days <= 60   then 'over a month'
    else 'a good while'
  end
$$;

create function message_draft_for(p_member_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  m        members%rowtype;
  v_studio studios%rowtype;
  v_key    text;
  t        message_templates%rowtype;
  v_days   int;
  v_slot   text;
  v_slot_line text;
  v_subject text;
  v_body    text;
begin
  select * into m from members where id = p_member_id;
  if not found then
    raise exception 'no such member' using errcode = 'PT404';
  end if;
  if not is_desk_up(m.studio_id) then
    raise exception 'only owners, managers and front desk may message a member'
      using errcode = 'PT403',
            hint = 'Permissions §12.';
  end if;

  select * into v_studio from studios where id = m.studio_id;

  -- The first signal is the reason the band fired, and the reason decides the
  -- draft. Falling back to the band covers `new`, which has no signals by
  -- design, and `general` covers a member nothing has been computed for.
  v_key := coalesce(
    m.health_signals ->> 0,
    case when m.health_band = 'new' then 'new_member' else null end,
    'general');

  -- A studio's own wording wins over ours.
  select * into t from message_templates
   where key = v_key and (studio_id = m.studio_id or studio_id is null)
   order by studio_id nulls last limit 1;
  if not found then
    select * into t from message_templates where key = 'general' and studio_id is null;
  end if;

  v_days := case when m.last_visit_at is null then null
                 else (current_date - (m.last_visit_at at time zone v_studio.timezone)::date) end;

  -- Their usual slot: the day and hour they turn up at most often, in studio
  -- time. Six visits is the same floor Decision 14 uses before it will call
  -- anything a rhythm.
  -- Grouped on the class's start time, not the check-in's. People arrive at
  -- 06:37 and 06:54 for the same 07:00 class, so grouping on when they walked
  -- through the door means no two visits ever match and every member looks
  -- like they have no usual slot.
  select to_char(o.starts_at at time zone v_studio.timezone, 'FMDay HH24:MI')
    into v_slot
    from check_ins ci
    join class_occurrences o on o.id = ci.occurrence_id
   where ci.member_id = p_member_id
   group by to_char(o.starts_at at time zone v_studio.timezone, 'FMDay HH24:MI')
  having count(*) >= 3
   order by count(*) desc, max(o.starts_at) desc
   limit 1;

  v_slot_line := case
    when v_slot is null
      then 'There is space in most classes this week if you fancy it.'
    else format('Your usual %s still has space if you fancy it.', v_slot)
  end;

  v_subject := replace(replace(t.subject, '{studio}', v_studio.name),
                       '{first_name}', m.first_name);
  v_body := t.body;
  v_body := replace(v_body, '{first_name}',  m.first_name);
  v_body := replace(v_body, '{studio}',      v_studio.name);
  v_body := replace(v_body, '{gap_phrase}',  message_gap_phrase(v_days));
  v_body := replace(v_body, '{slot_line}',   v_slot_line);
  v_body := replace(v_body, '{joined_phrase}',
                    message_gap_phrase(current_date - m.joined_on) || ' ago');

  return jsonb_build_object(
    'template_key', t.key,
    'subject',      v_subject,
    'body',         v_body,
    'marketing_opt_in', m.marketing_opt_in,
    -- A card that failed is something they need to know regardless of what
    -- they ticked; a we-miss-you note is not. The screen decides what to say
    -- about that, but it should not have to work out which is which.
    'transactional', t.key in ('payment_state', 'expiry_declining_use'));
end $$;

-- -----------------------------------------------------------------------------
-- Sending — which today means queueing
-- -----------------------------------------------------------------------------
create function send_message(p_message_id uuid) returns messages
language plpgsql security definer set search_path = public as $$
declare msg messages%rowtype;
begin
  select * into msg from messages where id = p_message_id;
  if not found then
    raise exception 'no such message' using errcode = 'PT404';
  end if;
  if not is_desk_up(msg.studio_id) then
    raise exception 'only owners, managers and front desk may send a message'
      using errcode = 'PT403', hint = 'Permissions §12.';
  end if;
  if msg.status <> 'draft' then
    raise exception 'this message has already been sent' using errcode = 'PT409';
  end if;

  update messages set status = 'queued' where id = p_message_id
  returning * into msg;

  -- Written here as well as derived in rebuild_member_timeline(), and the two
  -- must agree field for field. Only deriving it would mean the event did not
  -- exist until somebody happened to rebuild; only writing it here would mean
  -- the next rebuild deleted it. Doing both, identically, is what makes it
  -- appear at once and still survive.
  insert into timeline_events
    (studio_id, member_id, type, occurred_at, title, description,
     actor_user_id, ref_table, ref_id, metadata)
  values
    (msg.studio_id, msg.member_id, 'message_sent',
     coalesce(msg.sent_at, msg.updated_at), 'Message sent', msg.subject,
     msg.created_by, 'messages', msg.id,
     jsonb_build_object('status', msg.status, 'template_key', msg.template_key));

  return msg;
end $$;

revoke execute on function message_draft_for(uuid) from public;
revoke execute on function send_message(uuid) from public;
revoke execute on function message_gap_phrase(int) from public;
grant execute on function message_draft_for(uuid) to authenticated, service_role;
grant execute on function send_message(uuid) to authenticated, service_role;
grant execute on function message_gap_phrase(int) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- The timeline learns about messages — by deriving them, not by being told
--
-- timeline_events has carried a `message_sent` type since migration 001 and
-- nothing has ever written one. The obvious way to write it now would be from
-- send_message(), and it would be wrong: rebuild_member_timeline() deletes a
-- member's events and re-derives them, so a hand-written row survives until the
-- next rebuild and then vanishes without trace. Migration 021's own comment
-- guessed that such events would "append rather than rebuild"; they would not.
--
-- A message is a row in a table, so it is derivable like everything else.
-- -----------------------------------------------------------------------------
create or replace function rebuild_member_timeline(p_member_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_studio uuid;
  n int;
begin
  select studio_id into v_studio from members where id = p_member_id;
  if not found then
    raise exception 'no such member' using errcode = 'PT404';
  end if;

  if not is_manager_up(v_studio) and not is_platform_admin() then
    raise exception 'only owners and managers may rebuild a timeline'
      using errcode = 'PT403';
  end if;

  delete from timeline_events where member_id = p_member_id;

  insert into timeline_events (studio_id, member_id, type, occurred_at, title, description, ref_table, ref_id)
  select v_studio, p_member_id, 'joined',
         (m.joined_on::timestamp at time zone s.timezone),
         'Joined the studio',
         case when m.source is null then null else 'Came via ' || m.source end,
         'members', m.id
    from members m join studios s on s.id = m.studio_id
   where m.id = p_member_id;

  insert into timeline_events (studio_id, member_id, type, occurred_at, title, description, ref_table, ref_id)
  select v_studio, p_member_id, 'attended', ci.checked_in_at,
         coalesce(o.name, 'Visit'),
         case when o.id is null
              then 'Imported from your previous system — the class is not known'
              else null end,
         'check_ins', ci.id
    from check_ins ci
    left join class_occurrences o on o.id = ci.occurrence_id
   where ci.member_id = p_member_id;

  insert into timeline_events (studio_id, member_id, type, occurred_at, title, description, ref_table, ref_id)
  select v_studio, p_member_id, 'cancelled',
         coalesce(b.cancelled_at, b.booked_at),
         case when b.is_late_cancel then 'Cancelled late' else 'Cancelled' end,
         o.name,
         'bookings', b.id
    from bookings b
    left join class_occurrences o on o.id = b.occurrence_id
   where b.member_id = p_member_id
     and b.status in ('cancelled', 'late_cancelled');

  insert into timeline_events (studio_id, member_id, type, occurred_at, title, description, ref_table, ref_id, metadata)
  select v_studio, p_member_id, 'payment',
         coalesce(p.paid_at, p.created_at),
         case p.status
           when 'succeeded'          then 'Paid'
           when 'failed'             then 'Payment failed'
           when 'refunded'           then 'Refunded'
           when 'partially_refunded' then 'Partly refunded'
           else 'Payment pending'
         end,
         p.description,
         'payments', p.id,
         jsonb_build_object('amount_cents', p.amount_cents, 'currency', p.currency,
                            'status', p.status)
    from payments p
   where p.member_id = p_member_id;

  insert into timeline_events (studio_id, member_id, type, occurred_at, title, description, ref_table, ref_id)
  select v_studio, p_member_id, 'membership_changed',
         coalesce(ms.starts_on::timestamptz, ms.created_at),
         'Started on ' || pl.name,
         null,
         'memberships', ms.id
    from memberships ms join membership_plans pl on pl.id = ms.plan_id
   where ms.member_id = p_member_id;

  -- A draft is not an event. Only a message that has left the desk appears.
  insert into timeline_events (studio_id, member_id, type, occurred_at, title, description, actor_user_id, ref_table, ref_id, metadata)
  select v_studio, p_member_id, 'message_sent',
         coalesce(msg.sent_at, msg.updated_at),
         'Message sent',
         msg.subject,
         msg.created_by,
         'messages', msg.id,
         jsonb_build_object('status', msg.status, 'template_key', msg.template_key)
    from messages msg
   where msg.member_id = p_member_id
     and msg.status in ('queued', 'sent');

  select count(*) into n from timeline_events where member_id = p_member_id;
  return n;
end $$;

comment on table messages is
  'One-to-one messages from staff to a member. Nothing sends them yet: '
  'send_message() moves a draft to queued and a transport adapter picks it up '
  'later. Permissions §12 — owner, manager and front desk; never instructors.';
