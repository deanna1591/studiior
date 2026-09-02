-- =============================================================================
-- Migration 048: applying, approving, and telling people
-- =============================================================================
-- Decision 17's edges, each one settled here rather than left to the screen:
--
--   * Several instructors apply for one shift: every application stands until
--     staff approve one. Approving auto-declines the rest IN THE SAME
--     TRANSACTION, so there is no window where two people both believe they
--     have it, and each of the declined is told.
--   * An approved instructor withdraws: the class goes back to `open`, staff
--     are notified, and it is loud. A class with members booked and nobody
--     teaching it is the worst state this system can be in.
--   * Applying outside stated availability: permitted, warned. Decision 9's
--     rule for assignment, applied to application for the same reason — a hard
--     block gets worked around by not using the feature.
-- =============================================================================

insert into notification_templates (key, subject, text_body, html_body, note) values
('shift_application_received',
 'Someone wants to teach {class_name}',
 E'Hi {first_name},\n\n{instructor_name} has applied to teach {class_name} on {when}.\n\n{availability_note}Approve or decline: {applications_url}',
 E'<p>Hi {first_name},</p><p><strong>{instructor_name}</strong> has applied to teach {class_name} on {when}.</p><p>{availability_note}</p><p><a href="{applications_url}">Approve or decline</a></p>',
 'To the studio when an instructor applies for an open shift. Decision 17.'),

('shift_approved',
 'You''re teaching {class_name}',
 E'Hi {first_name},\n\nYou''re confirmed to teach {class_name} on {when}{where_line}.\n\nIf anything changes, tell the studio as soon as you can — there may be members booked.',
 E'<p>Hi {first_name},</p><p>You''re confirmed to teach <strong>{class_name}</strong> on {when}{where_line}.</p><p>If anything changes, tell the studio as soon as you can — there may be members booked.</p>',
 'To the instructor whose application was approved.'),

('shift_declined',
 '{class_name} has been covered',
 E'Hi {first_name},\n\n{class_name} on {when} has been covered by someone else. Thanks for putting your name down.\n\nThere may be other open shifts: {shifts_url}',
 E'<p>Hi {first_name},</p><p>{class_name} on {when} has been covered by someone else. Thanks for putting your name down.</p><p>There may be other open shifts: <a href="{shifts_url}">have a look</a></p>',
 'To an instructor who was not chosen, including the ones auto-declined when somebody else was approved.'),

('shift_withdrawn',
 '{instructor_name} has withdrawn from {class_name}',
 E'Hi {first_name},\n\n{instructor_name} has withdrawn from {class_name} on {when}, so it has no instructor.\n\n{booked_line}\n\nFind cover: {applications_url}',
 E'<p>Hi {first_name},</p><p><strong>{instructor_name}</strong> has withdrawn from {class_name} on {when}, so it has no instructor.</p><p>{booked_line}</p><p><a href="{applications_url}">Find cover</a></p>',
 'To the studio, loudly. A class with members booked and nobody teaching it is the worst state in the system.'),

('class_moved',
 '{class_name} has moved to {when}',
 E'Hi {first_name},\n\n{class_name} has moved. It was {old_when}; it is now {when}{where_line}.\n\nYour place has moved with it — there is nothing for you to do. If the new time does not work, you can cancel in the app.',
 E'<p>Hi {first_name},</p><p><strong>{class_name}</strong> has moved. It was {old_when}; it is now {when}{where_line}.</p><p>Your place has moved with it — there is nothing for you to do. If the new time does not work, you can cancel in the app.</p>',
 'To every booked member when a class is rescheduled. Not opt-outable: there is no reading of "I turned off emails" that makes it right to let somebody arrive at the old time.')
on conflict (key) do nothing;

-- -----------------------------------------------------------------------------
-- class_moved joins the three §12 events that always send
--
-- render_notification() decides its footer copy from this list, so leaving
-- class_moved out would print "Choose which emails you get" under an email
-- that cannot be turned off — a control that would do nothing for the person
-- reading it.
-- -----------------------------------------------------------------------------
create or replace function notification_wanted(p_member_id uuid, p_template text)
returns boolean
language plpgsql stable security definer set search_path = public as $$
declare p notification_preferences%rowtype;
begin
  if p_template in ('class_cancelled', 'instructor_substituted',
                    'payment_failed', 'staff_message', 'class_moved') then
    return true;
  end if;

  select * into p from notification_preferences where member_id = p_member_id;
  if not found then
    return true;
  end if;

  return case p_template
    when 'booking_confirmed' then p.booking_email
    when 'class_reminder'    then p.reminder_email
    when 'waitlist_offer'    then p.waitlist_email
    when 'credit_expiry'     then p.credit_expiry_email
    when 'milestone'         then p.milestone_email
    else true
  end;
end $$;

revoke execute on function notification_wanted(uuid, text) from public, anon, authenticated;

-- The footer copy for the five new templates. All of them are things a person
-- has to act on, so none offers a way to switch it off.
create or replace function public.render_notification(p_notification_id uuid)
 RETURNS TABLE(to_email text, from_name text, reply_to text, subject text, text_body text, html_body text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  n notifications%rowtype; t notification_templates%rowtype;
  m members%rowtype; s studios%rowtype;
  v_staff_email text; v_staff_name text; v_is_staff boolean;
  v_sub text; v_txt text; v_html text; k text; rule text;
  v_addr text; v_link text; v_contact text;
  v_always boolean; v_foot_txt text; v_foot_html text;
begin
  select * into n from notifications where id = p_notification_id;
  select * into t from notification_templates where key = n.template_key;
  select * into m from members where id = n.member_id;

  -- A notification can be addressed to a person at the studio rather than to a
  -- member — platform billing is the first of those, and it has to reach the
  -- owner rather than somebody who books classes. The renderer had only ever
  -- looked in `members`, so this branch is what a staff-addressed row needs to
  -- render at all rather than as an email to nobody.
  v_is_staff := n.recipient_type = 'staff';
  if v_is_staff then
    select coalesce(ss.email, pr.email), coalesce(pr.full_name, ss.email)
      into v_staff_email, v_staff_name
      from studio_staff ss
      left join profiles pr on pr.id = ss.user_id
     where ss.user_id = n.user_id and ss.studio_id = n.studio_id
     limit 1;
  end if;
  select * into s from studios where id = n.studio_id;
  if t.key is null then
    raise exception 'no template %', n.template_key using errcode = 'PT404';
  end if;

  v_sub  := t.subject;
  v_txt  := t.text_body;
  v_html := t.html_body;

  for k in select jsonb_object_keys(n.payload) loop
    v_sub  := replace(v_sub,  '{' || k || '}', coalesce(n.payload ->> k, ''));
    v_txt  := replace(v_txt,  '{' || k || '}', coalesce(n.payload ->> k, ''));
    v_html := replace(v_html, '{' || k || '}', coalesce(n.payload ->> k, ''));
  end loop;
  for k in select unnest(array['first_name','studio_name']) loop
    -- falls through to the same replace below, with m.first_name null-safe
    v_sub  := replace(v_sub,  '{' || k || '}',
                      case k when 'first_name'
                             then coalesce(m.first_name, split_part(coalesce(v_staff_name,''), ' ', 1), 'there')
                             else s.name end);
    v_txt  := replace(v_txt,  '{' || k || '}',
                      case k when 'first_name'
                             then coalesce(m.first_name, split_part(coalesce(v_staff_name,''), ' ', 1), 'there')
                             else s.name end);
    v_html := replace(v_html, '{' || k || '}',
                      case k when 'first_name'
                             then coalesce(m.first_name, split_part(coalesce(v_staff_name,''), ' ', 1), 'there')
                             else s.name end);
  end loop;

  -- Neutral, not Studiior's lime. A studio that has not picked an accent gets
  -- grey in its own mail rather than another company's brand colour.
  rule := coalesce(s.accent_color, '#78716C');

  -- locations.address is jsonb with no fixed shape (data model line 101), so
  -- assigning it straight into a text variable put a raw JSON object in the
  -- footer of a real email: {"city": "Prague", "line1": ...}. Assembled by key,
  -- skipping whatever a given studio has not filled in.
  select nullif(concat_ws(', ',
           nullif(l.address ->> 'line1', ''),
           nullif(l.address ->> 'line2', ''),
           nullif(l.address ->> 'city', ''),
           nullif(l.address ->> 'postal_code', ''),
           nullif(l.address ->> 'country', '')), '')
    into v_addr
    from locations l
   where l.studio_id = s.id and l.status = 'active'
   order by l.is_primary desc, l.created_at limit 1;

  -- A member's email-settings screen means nothing to a studio owner being
  -- told their subscription lapsed, so a staff email points at their billing
  -- screen instead. Offering the member link would be a control that does
  -- nothing for the person reading it.
  if v_is_staff then
    v_link := coalesce(nullif(notification_setting('staff_app_origin'), ''),
                       'https://app.studiior.com') || '/billing';
  else
  v_link := 'https://' || s.slug || '.'
            || coalesce(notification_setting('member_app_domain'), 'studiior.app')
            || '/settings';
  end if;

  v_contact := nullif(concat_ws(' · ', s.contact_email, s.contact_phone), '');

  -- §12: three events have no opt-out, and staff_message is a person writing to
  -- one member. Saying "always sends" is what stops the footer being a lie.
  v_always := n.template_key in ('class_cancelled', 'instructor_substituted',
                                 'payment_failed', 'staff_message',
                                 'platform_billing_warning', 'class_moved',
                                 'shift_application_received', 'shift_approved',
                                 'shift_declined', 'shift_withdrawn');

  v_foot_txt := concat_ws(E'\n',
    v_contact,
    v_addr,
    case when v_is_staff then 'Your billing: ' || v_link
         when v_always
         then 'We always send this one — it''s about your booking or your membership. '
              || 'Choose which other emails you get: ' || v_link
         else 'Choose which emails you get: ' || v_link end);

  v_foot_html := concat_ws('<br>',
    v_contact,
    v_addr,
    case when v_is_staff
         then '<a href="' || v_link || '" style="color:#57534E">Your billing</a>'
         when v_always
         then 'We always send this one — it''s about your booking or your membership. '
              || '<a href="' || v_link || '" style="color:#57534E">Choose which other emails you get</a>'
         else '<a href="' || v_link || '" style="color:#57534E">Choose which emails you get</a>' end);

  return query select
    coalesce(v_staff_email, m.email),
    s.name,              -- the from-name is the studio, never Studiior
    s.contact_email,     -- null means no reply-to header, not a fake one
    v_sub,
    v_txt || E'\n\n--\n' || v_foot_txt,
    '<div style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;'
      || 'font-size:15px;line-height:22px;color:#14170E;max-width:520px;margin:0 auto;padding:24px">'
      || case when s.logo_url is not null
              then '<img src="' || s.logo_url || '" alt="' || s.name
                   || '" width="40" height="40" style="border-radius:6px;display:block;margin-bottom:16px">'
              else '<div style="font-weight:600;font-size:17px;margin-bottom:16px">' || s.name || '</div>'
         end
      || '<div style="height:3px;width:44px;background:' || rule || ';margin-bottom:20px"></div>'
      || v_html
      || '<p style="color:#78716C;font-size:13px;line-height:18px;margin-top:28px;'
      || 'border-top:1px solid #E7E5E4;padding-top:14px">' || v_foot_html || '</p></div>';
end $function$

;

-- -----------------------------------------------------------------------------
-- Telling the studio and the instructor
--
-- Staff-addressed rows go in directly with recipient_type = 'staff', which
-- migration 046 taught render_notification() to resolve. queue_notification()
-- is member-only and checks member preferences, neither of which applies here.
-- -----------------------------------------------------------------------------
/**
 * The login behind an instructor, if they have one.
 *
 * instructors.staff_id references studio_staff(id) — NOT a user id. Passing it
 * straight to a notification addresses a user that does not exist, which is
 * exactly the bug this function exists to stop being written three times.
 */
create or replace function instructor_user_id(p_instructor_id uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select ss.user_id
    from instructors i
    join studio_staff ss on ss.id = i.staff_id
   where i.id = p_instructor_id and ss.status = 'active'
$$;

create or replace function queue_shift_notice(
  p_studio_id uuid, p_user_id uuid, p_template text, p_payload jsonb, p_dedupe text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if p_user_id is null then
    -- An instructor with no login has no address. instructors carries no email
    -- of its own, and only a signed-in instructor can apply in the first place,
    -- so in practice this is the studio-side path with no owner set.
    return null;
  end if;
  insert into notifications (studio_id, recipient_type, user_id, template_key,
                             channel, payload, dedupe_key, scheduled_for, status)
  values (p_studio_id, 'staff', p_user_id, p_template, 'email',
          p_payload, p_dedupe, now(), 'scheduled')
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  return v_id;
end $$;

/** Everyone at the studio who should hear about staffing: owner and managers. */
create or replace function queue_shift_notice_to_staff(
  p_studio_id uuid, p_template text, p_payload jsonb, p_dedupe_prefix text
) returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in
    select ss.user_id from studio_staff ss
     where ss.studio_id = p_studio_id and ss.status = 'active'
       and ss.role in ('owner', 'manager') and ss.user_id is not null
  loop
    if queue_shift_notice(p_studio_id, r.user_id, p_template, p_payload,
                          p_dedupe_prefix || ':' || r.user_id) is not null then
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- -----------------------------------------------------------------------------
-- Apply
-- -----------------------------------------------------------------------------
create or replace function apply_for_shift(p_occurrence_id uuid, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  occ class_occurrences%rowtype;
  v_instructor uuid;
  v_app uuid;
  v_available boolean;
  v_when text; v_tz text;
begin
  select * into occ from class_occurrences where id = p_occurrence_id for update;
  if not found then
    raise exception 'no such class' using errcode = 'PT404';
  end if;

  -- auth_instructor_id() maps the signed-in user to their instructor row at
  -- that studio, and returns null for anybody who is not one. An instructor
  -- never assigns themselves — Decision 9 still holds — they ask.
  v_instructor := auth_instructor_id(occ.studio_id);
  if v_instructor is null then
    raise exception 'only an instructor at this studio can apply for a shift'
      using errcode = 'PT403';
  end if;
  if studio_is_locked(occ.studio_id) then
    raise exception 'this studio''s Studiior subscription is not active'
      using errcode = 'PT402';
  end if;
  if occ.staffing = 'assigned' then
    raise exception 'that class already has an instructor' using errcode = 'PT409';
  end if;
  if occ.status <> 'scheduled' then
    raise exception 'that class is %', occ.status using errcode = 'PT409';
  end if;
  if occ.starts_at < now() then
    raise exception 'that class has already happened' using errcode = 'PT409';
  end if;

  insert into shift_applications (studio_id, occurrence_id, instructor_id, note)
  values (occ.studio_id, occ.id, v_instructor, p_note)
  on conflict (occurrence_id, instructor_id) where status = 'pending'
  do nothing
  returning id into v_app;

  if v_app is null then
    raise exception 'you have already applied for that shift' using errcode = 'PT409';
  end if;

  update class_occurrences set staffing = 'pending_approval', updated_at = now()
   where id = occ.id and staffing = 'open';

  v_available := instructor_available_at(v_instructor, occ.starts_at, occ.ends_at);

  select s.timezone into v_tz from studios s where s.id = occ.studio_id;
  v_when := to_char(occ.starts_at at time zone v_tz, 'FMDay FMDD FMMonth, HH24:MI');

  perform queue_shift_notice_to_staff(occ.studio_id, 'shift_application_received',
    jsonb_build_object(
      'class_name', occ.name,
      'when', v_when,
      'instructor_name', (select display_name from instructors where id = v_instructor),
      -- Decision 9's warning, carried into the email so the person deciding
      -- sees it at the moment they decide rather than having to go and check.
      'availability_note', case when v_available then ''
        else 'This is outside the availability they have given us. ' end,
      'applications_url', coalesce(nullif(notification_setting('staff_app_origin'), ''),
                                   'https://app.studiior.com') || '/shifts/applications'),
    'shift_applied:' || v_app);

  return jsonb_build_object('application_id', v_app,
                            'outside_availability', not v_available);
end $$;

-- -----------------------------------------------------------------------------
-- Approve — and decline everyone else, in the same transaction
-- -----------------------------------------------------------------------------
create or replace function approve_shift_application(p_application_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  app  shift_applications%rowtype;
  occ  class_occurrences%rowtype;
  r    record;
  v_tz text; v_when text; v_where text;
  n_declined int := 0;
  v_res jsonb;
begin
  select * into app from shift_applications where id = p_application_id for update;
  if not found then
    raise exception 'no such application' using errcode = 'PT404';
  end if;
  if not is_manager_up(app.studio_id) then
    raise exception 'approving a shift is the owner''s or a manager''s to do'
      using errcode = 'PT403';
  end if;
  if app.status <> 'pending' then
    raise exception 'that application is already %', app.status using errcode = 'PT409';
  end if;

  select * into occ from class_occurrences where id = app.occurrence_id for update;

  -- Assignment goes through move_occurrence() like every other change to the
  -- timetable, so approving cannot put an instructor into a slot the calendar
  -- would have refused — the double-booking constraint applies here too.
  v_res := move_occurrence(occ.id, null, null, app.instructor_id, null, true);
  if not (v_res ->> 'ok')::boolean then
    raise exception 'cannot assign them: %', v_res ->> 'reason'
      using errcode = 'PT409',
            hint = 'They are teaching something else at that time.';
  end if;

  update shift_applications
     set status = 'approved', decided_by = auth.uid(), decided_at = now()
   where id = p_application_id;

  select s.timezone into v_tz from studios s where s.id = occ.studio_id;
  v_when  := to_char(occ.starts_at at time zone v_tz, 'FMDay FMDD FMMonth, HH24:MI');
  v_where := coalesce((select ', in ' || rm.name from rooms rm where rm.id = occ.room_id), '');

  perform queue_shift_notice(
    occ.studio_id,
    instructor_user_id(app.instructor_id),
    'shift_approved',
    jsonb_build_object('class_name', occ.name, 'when', v_when, 'where_line', v_where),
    'shift_approved:' || app.id);

  -- Everybody else, told. Silently dropping the other applications would leave
  -- instructors believing they are still in the running for a class that has
  -- been covered.
  for r in
    select sa.*, instructor_user_id(sa.instructor_id) as staff_user
      from shift_applications sa
     where sa.occurrence_id = occ.id and sa.status = 'pending' and sa.id <> app.id
    for update
  loop
    update shift_applications
       set status = 'declined', decided_by = auth.uid(), decided_at = now()
     where id = r.id;
    perform queue_shift_notice(occ.studio_id, r.staff_user, 'shift_declined',
      jsonb_build_object('class_name', occ.name, 'when', v_when,
        'shifts_url', coalesce(nullif(notification_setting('staff_app_origin'), ''),
                               'https://app.studiior.com') || '/shifts'),
      'shift_declined:' || r.id);
    n_declined := n_declined + 1;
  end loop;

  return jsonb_build_object('approved', app.id, 'auto_declined', n_declined,
                            'warnings', v_res -> 'warnings');
end $$;

/** Decline one application without approving anybody. */
create or replace function decline_shift_application(p_application_id uuid, p_reason text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare app shift_applications%rowtype; occ class_occurrences%rowtype; v_tz text; v_when text;
begin
  select * into app from shift_applications where id = p_application_id for update;
  if not found then
    raise exception 'no such application' using errcode = 'PT404';
  end if;
  if not is_manager_up(app.studio_id) then
    raise exception 'declining a shift is the owner''s or a manager''s to do'
      using errcode = 'PT403';
  end if;
  if app.status <> 'pending' then
    raise exception 'that application is already %', app.status using errcode = 'PT409';
  end if;

  update shift_applications
     set status = 'declined', decided_by = auth.uid(), decided_at = now()
   where id = p_application_id;

  select * into occ from class_occurrences where id = app.occurrence_id;
  select s.timezone into v_tz from studios s where s.id = occ.studio_id;
  v_when := to_char(occ.starts_at at time zone v_tz, 'FMDay FMDD FMMonth, HH24:MI');

  perform queue_shift_notice(occ.studio_id,
    instructor_user_id(app.instructor_id),
    'shift_declined',
    jsonb_build_object('class_name', occ.name, 'when', v_when,
      'shifts_url', coalesce(nullif(notification_setting('staff_app_origin'), ''),
                             'https://app.studiior.com') || '/shifts'),
    'shift_declined:' || app.id);

  -- Back to open if that was the last one waiting.
  update class_occurrences set staffing = 'open', updated_at = now()
   where id = occ.id and staffing = 'pending_approval'
     and not exists (select 1 from shift_applications sa
                      where sa.occurrence_id = occ.id and sa.status = 'pending');

  return jsonb_build_object('declined', app.id);
end $$;

-- -----------------------------------------------------------------------------
-- Withdraw — the loud one
-- -----------------------------------------------------------------------------
create or replace function withdraw_from_shift(p_occurrence_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  occ class_occurrences%rowtype;
  v_instructor uuid; v_name text; v_tz text; v_when text; v_res jsonb;
begin
  select * into occ from class_occurrences where id = p_occurrence_id for update;
  if not found then
    raise exception 'no such class' using errcode = 'PT404';
  end if;

  v_instructor := auth_instructor_id(occ.studio_id);
  if v_instructor is null or occ.instructor_id is distinct from v_instructor then
    raise exception 'you are not teaching that class' using errcode = 'PT403';
  end if;
  if occ.status <> 'scheduled' then
    raise exception 'that class is %', occ.status using errcode = 'PT409';
  end if;

  select display_name into v_name from instructors where id = v_instructor;

  -- Withdrawing does NOT go through move_occurrence's confirmation step: the
  -- instructor is not moving anybody's class, they are telling the studio they
  -- cannot teach it, and blocking that would just mean they tell nobody.
  update class_occurrences
     set instructor_id = null, staffing = 'open', updated_at = now()
   where id = occ.id;

  update shift_applications
     set status = 'withdrawn', decided_at = now()
   where occurrence_id = occ.id and instructor_id = v_instructor and status = 'approved';

  select s.timezone into v_tz from studios s where s.id = occ.studio_id;
  v_when := to_char(occ.starts_at at time zone v_tz, 'FMDay FMDD FMMonth, HH24:MI');

  perform queue_shift_notice_to_staff(occ.studio_id, 'shift_withdrawn',
    jsonb_build_object(
      'class_name', occ.name, 'when', v_when, 'instructor_name', v_name,
      -- The number is the point. "Nobody is teaching this" and "nobody is
      -- teaching this and eleven people are coming" are different emergencies.
      'booked_line', case when occ.booked_count > 0
        then occ.booked_count || ' member' || case when occ.booked_count = 1 then ' is' else 's are' end
             || ' booked in and expecting a class.'
        else 'Nobody is booked in yet.' end,
      'applications_url', coalesce(nullif(notification_setting('staff_app_origin'), ''),
                                   'https://app.studiior.com') || '/shifts/applications'),
    'shift_withdrawn:' || occ.id || ':' || v_instructor);

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (occ.studio_id, auth.uid(), 'occurrence.withdrawn', 'class_occurrences', occ.id,
          jsonb_build_object('instructor_id', v_instructor, 'booked_count', occ.booked_count));

  return jsonb_build_object('occurrence_id', occ.id, 'booked_count', occ.booked_count);
end $$;

revoke execute on function instructor_user_id(uuid) from public, anon, authenticated;
revoke execute on function queue_shift_notice(uuid,uuid,text,jsonb,text) from public, anon, authenticated;
revoke execute on function queue_shift_notice_to_staff(uuid,text,jsonb,text) from public, anon, authenticated;
revoke execute on function apply_for_shift(uuid, text) from public, anon;
grant execute on function apply_for_shift(uuid, text) to authenticated;
revoke execute on function approve_shift_application(uuid) from public, anon;
grant execute on function approve_shift_application(uuid) to authenticated;
revoke execute on function decline_shift_application(uuid, text) from public, anon;
grant execute on function decline_shift_application(uuid, text) to authenticated;
revoke execute on function withdraw_from_shift(uuid) from public, anon;
grant execute on function withdraw_from_shift(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- Telling the members a class has moved
--
-- §12 had no event for this. Cancelling and rebooking would have been the
-- alternative and is wrong in the data: it puts a cancellation in every
-- member's history for a class that ran, and would return credits it should
-- not.
-- -----------------------------------------------------------------------------
create or replace function queue_class_moved(p_occurrence_id uuid, p_old_starts_at timestamptz)
returns int
language plpgsql security definer set search_path = public as $$
declare
  occ class_occurrences%rowtype; r record; v_tz text;
  v_when text; v_old text; v_where text; n int := 0;
begin
  select * into occ from class_occurrences where id = p_occurrence_id;
  select s.timezone into v_tz from studios s where s.id = occ.studio_id;

  v_when  := to_char(occ.starts_at   at time zone v_tz, 'FMDay FMDD FMMonth, HH24:MI');
  v_old   := to_char(p_old_starts_at at time zone v_tz, 'FMDay FMDD FMMonth, HH24:MI');
  v_where := coalesce((select ', in ' || rm.name from rooms rm where rm.id = occ.room_id), '');

  for r in
    select b.member_id from bookings b
     where b.occurrence_id = occ.id and b.status = 'booked'
  loop
    if queue_notification(occ.studio_id, r.member_id, 'class_moved',
         jsonb_build_object('class_name', occ.name, 'when', v_when,
                            'old_when', v_old, 'where_line', v_where),
         'class_moved:' || occ.id || ':' || r.member_id || ':'
           || to_char(occ.starts_at, 'YYYYMMDDHH24MI')) is not null then
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

revoke execute on function queue_class_moved(uuid, timestamptz) from public, anon, authenticated;

create or replace function public.move_occurrence(p_occurrence_id uuid, p_starts_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_ends_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_instructor_id uuid DEFAULT NULL::uuid, p_room_id uuid DEFAULT NULL::uuid, p_confirm boolean DEFAULT false, p_clear_instructor boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  occ        class_occurrences%rowtype;
  v_starts   timestamptz;
  v_ends     timestamptz;
  v_instr    uuid;
  v_room     uuid;
  v_staffing staffing_state;
  v_warnings text[] := '{}';
  v_conflict text;
  v_moved    boolean;
begin
  select * into occ from class_occurrences where id = p_occurrence_id for update;
  if not found then
    raise exception 'no such class' using errcode = 'PT404';
  end if;
  if not is_manager_up(occ.studio_id) then
    raise exception 'only owners and managers change the timetable'
      using errcode = 'PT403';
  end if;
  if studio_is_locked(occ.studio_id) then
    raise exception 'this studio''s Studiior subscription is not active'
      using errcode = 'PT402',
            hint = 'Reactivate it from Billing. Nothing has been deleted.';
  end if;
  if occ.status <> 'scheduled' then
    raise exception 'a % class cannot be moved', occ.status using errcode = 'PT409';
  end if;

  v_starts := coalesce(p_starts_at, occ.starts_at);
  v_ends   := coalesce(p_ends_at,   occ.ends_at);
  v_room   := coalesce(p_room_id,   occ.room_id);
  -- p_clear_instructor because a null p_instructor_id has to be able to mean
  -- "leave it alone" as well as "make this an open shift", and one nullable
  -- parameter cannot say both.
  v_instr  := case when p_clear_instructor then null
                   else coalesce(p_instructor_id, occ.instructor_id) end;

  if v_ends <= v_starts then
    raise exception 'a class cannot end before it starts' using errcode = 'PT400';
  end if;

  v_staffing := case when v_instr is null then
                       (case when occ.staffing = 'pending_approval'
                             then 'pending_approval' else 'open' end)
                     else 'assigned' end::staffing_state;

  -- Members are the reason to stop and ask.
  if occ.booked_count > 0 and not p_confirm
     and (v_starts <> occ.starts_at or v_ends <> occ.ends_at
          or v_instr is distinct from occ.instructor_id) then
    return jsonb_build_object(
      'ok', false,
      'requires_confirmation', true,
      'booked_count', occ.booked_count,
      'reason', 'members_booked');
  end if;

  begin
    update class_occurrences
       set starts_at = v_starts, ends_at = v_ends,
           instructor_id = v_instr, room_id = v_room,
           staffing = v_staffing, updated_at = now()
     where id = p_occurrence_id;
  exception when exclusion_violation then
    -- Which of the two, in words a person can act on.
    get stacked diagnostics v_conflict = constraint_name;
    return jsonb_build_object(
      'ok', false,
      'requires_confirmation', false,
      'reason', case when v_conflict = 'occ_room_no_overlap'
                     then 'room_busy' else 'instructor_busy' end,
      'conflict', v_conflict);
  end;

  v_moved := v_starts <> occ.starts_at or v_ends <> occ.ends_at;

  -- Everybody who is booked in, told. This is the reason the confirmation step
  -- exists: by the time we are here the caller has said yes to sending it.
  if v_moved and occ.booked_count > 0 then
    perform queue_class_moved(occ.id, occ.starts_at);
  end if;

  if v_instr is not null and not instructor_available_at(v_instr, v_starts, v_ends) then
    -- Decision 9: permitted, and said out loud. Never blocked.
    v_warnings := v_warnings || 'outside_availability';
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (occ.studio_id, auth.uid(), 'occurrence.moved', 'class_occurrences', occ.id,
          jsonb_build_object('starts_at', occ.starts_at, 'ends_at', occ.ends_at,
                             'instructor_id', occ.instructor_id, 'room_id', occ.room_id),
          jsonb_build_object('starts_at', v_starts, 'ends_at', v_ends,
                             'instructor_id', v_instr, 'room_id', v_room));

  return jsonb_build_object(
    'ok', true,
    'moved', v_moved,
    'staffing', v_staffing,
    'booked_count', occ.booked_count,
    'warnings', to_jsonb(v_warnings));
end $function$

;
