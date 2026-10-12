-- Decision 77b — the closure notice for multi-day closures, and the scheduled-
-- campaign renderer fix from STEP 0.
--
-- creates: close_studio(uuid, date, date, text, time, time, boolean, boolean, boolean, text, text, text, text, date),
--   closure_notice_test(uuid, text, text, text, date),
--   send_campaign(uuid, timestamptz), send_campaign_test(uuid)
-- re-issues: closure_impact(uuid, date, date, time, time), cancel_occurrence(uuid, text, cancellation_cause),
--   queue_occurrence_cancelled(uuid, cancellation_cause), release_provisional_seats_run(uuid)
--
-- STEP 0 fix: a scheduled campaign is sent by send_campaign(id, when) at SCHEDULE
-- time (it bakes each member's html into their notification payload, scheduled
-- for `when`; the generic worker delivers it — there is no later sweep that
-- re-renders). 77a passed the rendered html/text as params; to make it
-- structural and kill the SQL fallback entirely, the rendered body now lives on
-- the campaign row (body_html/body_text), written by Next on every save, and the
-- senders READ those columns. One renderer, in Next.
--
-- The closure notice (Decision 77): with a multi-day closure's notice ON,
-- close_studio suppresses the per-class member emails (studiior.closure_notice
-- flag, read at the two member-email queue points), tells each assigned
-- instructor, and sends ONE studio_closure_notice per member. No new anon RPC —
-- THIRTEEN stays THIRTEEN.

-- =============================================================================
-- 1. Campaigns: the rendered body lives on the row (STEP 0).
-- =============================================================================
alter table campaigns add column if not exists body_html text;
alter table campaigns add column if not exists body_text text;
-- Backfill existing rows (all plain paragraphs) with the retiring split — which
-- equals renderBody for plain bodies, so existing drafts render identically.
update campaigns
   set body_html = '<p>' || replace(replace(coalesce(body, ''), '&', '&amp;'), E'\n\n', '</p><p>') || '</p>',
       body_text = body
 where body_html is null;

drop function if exists send_campaign_test(uuid, text, text);
create function send_campaign_test(p_campaign_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c campaigns%rowtype; s studios%rowtype; v_email text;
begin
  select * into c from campaigns where id = p_campaign_id;
  if not found then raise exception 'no such campaign' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(c.studio_id), false) then
    raise exception 'campaigns are for owners and managers' using errcode = 'PT403';
  end if;
  if nullif(c.body_html, '') is null then
    raise exception 'Save the draft first.' using errcode = 'PT400';
  end if;
  select * into s from studios where id = c.studio_id;
  select pr.email into v_email
    from studio_staff ss join profiles pr on pr.id = ss.user_id
   where ss.user_id = auth.uid() and ss.studio_id = c.studio_id limit 1;
  if nullif(v_email, '') is null then
    raise exception 'no staff email to send the test to' using errcode = 'PT404';
  end if;

  insert into notifications
    (studio_id, recipient_type, member_id, template_key, channel, payload, dedupe_key, scheduled_for, status)
  values
    (c.studio_id, 'member', null, 'campaign', 'email',
     jsonb_build_object('to_email', v_email, 'subject', '[Test] ' || c.subject,
       'body', c.body_text, 'body_html', c.body_html, 'studio_name', s.name,
       'unsubscribe_url', member_portal_url(c.studio_id, '/unsubscribe/preview')),
     'campaign_test:' || c.id || ':' || gen_random_uuid(), now(), 'scheduled');

  return jsonb_build_object('ok', true, 'sentence', 'Sent a test to ' || v_email || '.');
end $$;
revoke all on function send_campaign_test(uuid) from public, anon;
grant execute on function send_campaign_test(uuid) to authenticated, service_role;

drop function if exists send_campaign(uuid, timestamptz, text, text);
create function send_campaign(p_campaign_id uuid, p_when timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c campaigns%rowtype; s studios%rowtype; v_tz text; v_fmt text;
  r record; v_nid uuid; v_n int := 0; v_date text;
begin
  select * into c from campaigns where id = p_campaign_id for update;
  if not found then raise exception 'no such campaign' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(c.studio_id), false) then
    raise exception 'campaigns are for owners and managers' using errcode = 'PT403';
  end if;
  if c.status not in ('draft', 'scheduled') then
    raise exception 'This campaign has already been sent.' using errcode = 'PT409';
  end if;
  if nullif(btrim(c.subject), '') is null or nullif(btrim(c.body), '') is null then
    raise exception 'A campaign needs a subject and a message.' using errcode = 'PT400';
  end if;
  if nullif(c.body_html, '') is null then
    raise exception 'Save the draft first.' using errcode = 'PT400';
  end if;

  select * into s from studios where id = c.studio_id;
  v_tz  := s.timezone;
  v_fmt := coalesce((select time_format from studio_settings where studio_id = c.studio_id), '24h');

  for r in select * from campaign_audience(c.studio_id, c.audience) loop
    v_nid := queue_notification(c.studio_id, r.member_id, 'campaign',
      jsonb_build_object('subject', c.subject, 'body', c.body_text, 'body_html', c.body_html,
        'studio_name', s.name,
        'unsubscribe_url', member_portal_url(c.studio_id,
          '/unsubscribe/' || (select marketing_token from members where id = r.member_id))),
      'campaign:' || c.id || ':' || r.member_id, p_when);
    if v_nid is not null then
      insert into campaign_recipients (campaign_id, member_id, notification_id)
        values (c.id, r.member_id, v_nid)
        on conflict (campaign_id, member_id) do update set notification_id = excluded.notification_id;
      v_n := v_n + 1;
    end if;
  end loop;

  if v_n = 0 then
    raise exception 'Nobody in this audience has opted in to news.' using errcode = 'PT409';
  end if;

  update campaigns set
    status = case when p_when > now() then 'scheduled' else 'sending' end,
    scheduled_for = p_when, recipient_count = v_n, updated_at = now()
  where id = c.id;

  v_date := to_char(p_when at time zone v_tz, 'FMDD FMMonth YYYY') || ' ' || fmt_clock(p_when, v_tz, v_fmt);
  return jsonb_build_object('ok', true, 'count', v_n,
    'sentence', case when p_when > now()
      then 'Scheduled for ' || v_date || ' to ' || v_n || ' member' || case when v_n = 1 then '' else 's' end || '.'
      else 'Sending to ' || v_n || ' member' || case when v_n = 1 then '' else 's' end || '.' end);
end $$;
revoke all on function send_campaign(uuid, timestamptz) from public, anon;
grant execute on function send_campaign(uuid, timestamptz) to authenticated, service_role;

-- =============================================================================
-- 2. Closure columns + the notice template.
-- =============================================================================
alter table studio_closures add column if not exists subject        text;
alter table studio_closures add column if not exists message        text;
alter table studio_closures add column if not exists resumes_on     date;
alter table studio_closures add column if not exists notice_sent_at timestamptz;

insert into notification_templates (key, subject, text_body, html_body, note) values
  ('studio_closure_notice',
   '{subject}',
   E'{body}\n\n{system_text}',
   '{body_html}{system_html}',
   'Decision 77 — one notice to every member when a multi-day closure is announced with the notice on. Transactional (from_domain, consent ignored, no unsubscribe).')
on conflict (key) do nothing;


-- ===========================================================================
-- 3. closure_impact — members_total for the confirm step.
-- ===========================================================================
create or replace function closure_impact(
  p_studio_id uuid, p_starts_on date, p_ends_on date,
  p_starts_at_time time default null, p_ends_at_time time default null
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_tz text; v_classes int := 0; v_members int := 0; v_total int := 0; v_detail jsonb := '[]'::jsonb;
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers close the studio' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  if v_tz is null then
    raise exception 'no such studio' using errcode = 'PT404';
  end if;
  if p_ends_on < p_starts_on then
    raise exception 'that closure ends before it starts' using errcode = 'PT400';
  end if;

  with hit as (
    select o.id, o.name, o.starts_at, o.booked_count,
           to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMon, HH24:MI') as local,
           (select count(*) from bookings b
             where b.occurrence_id = o.id
               and b.status in ('booked','waitlisted','pending_payment')) as booked
      from class_occurrences o
     where o.studio_id = p_studio_id
       and o.status = 'scheduled'
       -- Only what is still ahead: a class that already ran cannot be cancelled
       -- by closing next Christmas.
       and o.starts_at > now()
       and (o.starts_at at time zone v_tz)::date between p_starts_on and p_ends_on
       and (p_starts_at_time is null
            or ((o.starts_at at time zone v_tz)::time < p_ends_at_time
                and (o.ends_at at time zone v_tz)::time > p_starts_at_time))
  )
  select count(*)::int, coalesce(sum(booked), 0)::int,
         coalesce(jsonb_agg(jsonb_build_object('occurrence_id', id, 'name', name,
                                               'local', local, 'booked', booked)
                            order by starts_at), '[]'::jsonb)
    into v_classes, v_members, v_detail from hit;

  -- Decision 77: how many members the closure notice would reach (every
  -- member with an address, booked or not), so the confirm step can say it.
  select count(*)::int into v_total from members
   where studio_id = p_studio_id and deleted_at is null and nullif(email, '') is not null;

  return jsonb_build_object(
    'starts_on', p_starts_on, 'ends_on', p_ends_on,
    'partial', p_starts_at_time is not null,
    'classes', v_classes, 'members_booked', v_members, 'members_total', v_total, 'detail', v_detail);
end $$;


-- ===========================================================================
-- 4. release_provisional_seats_run + queue_occurrence_cancelled — read the flag.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.release_provisional_seats_run(p_occurrence_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o class_occurrences%rowtype; s studios%rowtype; r record; n int := 0;
        v_when text; v_when_short text; v_list text; v_fmt text;
        v_notice boolean := coalesce(current_setting('studiior.closure_notice', true), '') = '1';
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then return 0; end if;
  select * into s from studios where id = o.studio_id;
  select coalesce(time_format, '24h') into v_fmt from studio_settings where studio_id = o.studio_id;
  v_fmt := coalesce(v_fmt, '24h');
  v_when       := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY');
  v_when_short := to_char(o.starts_at at time zone s.timezone, 'FMDy FMDD FMMon ')
                 || fmt_clock(o.starts_at, s.timezone, v_fmt);

  for r in select b.id, b.member_id from bookings b
            where b.occurrence_id = p_occurrence_id and b.status = 'booked' and b.provisional
  loop
    -- Release, directly: the explicit release_reason means the BEFORE stamp
    -- trigger leaves it, is_late_cancel false means no infraction, and a comp
    -- seat has no credit to return.
    update bookings
       set status = 'cancelled', release_reason = 'trial_not_confirmed',
           cancelled_at = now(), cancelled_by = null, is_late_cancel = false
     where id = r.id;
    update class_occurrences set booked_count = greatest(0, booked_count - 1)
     where id = p_occurrence_id;
    -- The once-ever row goes, so the person is eligible again and keeps their
    -- free class. Removed, not left 'cancelled' — free_first_eligibility's
    -- already_had_free check does not look at status.
    delete from guest_passes where guest_booking_id = r.id;

    -- Decision 77: under the closure-notice flag the member gets ONE
    -- studio_closure_notice instead of this per-class email — skip it here.
    if not v_notice then
    -- Now eligible again, so the "next ones" are computed with this person's own
    -- gates: fullest first, with someone already in; fall back to any eligible.
    select string_agg(z.line, '; ' order by z.ord)
      into v_list
      from (
        select to_char(c.starts_at at time zone s.timezone, 'FMDay ') || fmt_clock(c.starts_at, s.timezone, v_fmt) || ' ' || c.name as line,
               row_number() over (order by c.headcount desc, c.starts_at) as ord
          from free_first_eligible_classes_run(o.studio_id, r.member_id, 1) c
         where c.occurrence_id <> p_occurrence_id and c.free_bookable
         limit 3) z;
    if v_list is null then
      select string_agg(z.line, '; ' order by z.ord)
        into v_list
        from (
          select to_char(c.starts_at at time zone s.timezone, 'FMDay ') || fmt_clock(c.starts_at, s.timezone, v_fmt) || ' ' || c.name as line,
                 row_number() over (order by c.headcount desc, c.starts_at) as ord
            from free_first_eligible_classes_run(o.studio_id, r.member_id, 0) c
           where c.occurrence_id <> p_occurrence_id and c.free_bookable
           limit 3) z;
    end if;

    perform queue_notification(o.studio_id, r.member_id, 'free_booking_not_confirmed',
      jsonb_build_object('class_name', o.name, 'when', v_when, 'day_short', v_when_short,
        'time', fmt_clock(o.starts_at, s.timezone, v_fmt),
        'next_three', coalesce(v_list, 'see the full schedule'),
        'occurrence_id', p_occurrence_id),
      'free_not_confirmed:' || r.id);
    n := n + 1;
    end if;
  end loop;
  return n;
end $function$
;

CREATE OR REPLACE FUNCTION public.queue_occurrence_cancelled(p_occurrence_id uuid, p_cause cancellation_cause DEFAULT NULL::cancellation_cause)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o class_occurrences%rowtype; s studios%rowtype; r record; n int := 0;
        v_when text; v_when_short text; v_base text; v_fmt text;
        v_list_txt text; v_list_html text; v_line_txt text; v_line_html text;
        v_notice boolean := coalesce(current_setting('studiior.closure_notice', true), '') = '1';
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  select * into s from studios where id = o.studio_id;
  select coalesce(time_format, '24h') into v_fmt from studio_settings where studio_id = o.studio_id;
  v_fmt := coalesce(v_fmt, '24h');
  v_when := to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMonth YYYY');
  v_when_short := to_char(o.starts_at at time zone s.timezone, 'FMDy FMDD FMMon ')
                 || fmt_clock(o.starts_at, s.timezone, v_fmt);
  v_base := 'https://' || s.slug || '.'
            || coalesce(notification_setting('member_app_domain'), 'studiior.app') || '/class/';

  -- Decision 77: under the closure-notice flag, the member gets ONE
  -- studio_closure_notice instead of a per-class class_cancelled — skip these.
  if not v_notice then
  for r in select b.member_id from bookings b
            where b.occurrence_id = p_occurrence_id
              and b.status in ('booked','waitlisted')
  loop
    if p_cause = 'unmet_minimum' then
      -- Up to three upcoming, scheduled, published classes with a free space.
      select string_agg(x.line, '; ' order by x.starts_at),
             string_agg('<a href="' || v_base || x.id || '">' || x.line || '</a>', ', ' order by x.starts_at)
        into v_list_txt, v_list_html
        from (
          select o2.id, o2.starts_at,
                 to_char(o2.starts_at at time zone s.timezone, 'FMDay ') || fmt_clock(o2.starts_at, s.timezone, v_fmt) || ' ' || o2.name as line
            from class_occurrences o2
           where o2.studio_id = o.studio_id
             and o2.status = 'scheduled'
             and o2.starts_at > now()
             and o2.id <> p_occurrence_id
             and coalesce(o2.booked_count, 0) < o2.capacity
             and occurrence_published(o2.id)
           order by o2.starts_at
           limit 3) x;
      v_line_txt  := case when v_list_txt  is null then '' else ' Here are the next ones with space: ' || v_list_txt || '.' end;
      v_line_html := case when v_list_html is null then '' else '<p>Here are the next ones with space: ' || v_list_html || '.</p>' end;

      if queue_notification(o.studio_id, r.member_id, 'flex_booking_not_confirmed',
            jsonb_build_object('class_name', o.name, 'when', v_when, 'day_short', v_when_short,
              'time', fmt_clock(o.starts_at, s.timezone, v_fmt),
              'next_three_line', v_line_txt, 'next_three_html', v_line_html,
              'occurrence_id', p_occurrence_id),
            'class_cancelled:' || p_occurrence_id || ':' || r.member_id) is not null
      then n := n + 1; end if;
    else
      if queue_notification(o.studio_id, r.member_id, 'class_cancelled',
            jsonb_build_object('class_name', o.name, 'when', v_when,
                               'occurrence_id', p_occurrence_id),
            'class_cancelled:' || p_occurrence_id || ':' || r.member_id) is not null
      then n := n + 1; end if;
    end if;
  end loop;
  end if;

  update notifications set status = 'cancelled'
   where status = 'scheduled'
     and dedupe_key like 'class_reminder:%'
     and payload ->> 'class_name' = o.name
     and member_id in (select member_id from bookings where occurrence_id = p_occurrence_id);

  return n;
end $function$
;


-- ===========================================================================
-- 5. cancel_occurrence — delete a confirmed free-first guest_passes row (any cause).
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.cancel_occurrence(p_occurrence_id uuid, p_reason text DEFAULT NULL::text, p_cause cancellation_cause DEFAULT 'studio_fault'::cancellation_cause)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  occ class_occurrences%rowtype;
  r record;
  n_notified int := 0; n_cancelled int := 0; n_credited int := 0;
  v_res record;
begin
  select * into occ from class_occurrences where id = p_occurrence_id for update;
  if not found then
    raise exception 'no such class' using errcode = 'PT404';
  end if;
  if not coalesce(is_manager_up(occ.studio_id), false) and not is_service_context() then
    raise exception 'only owners and managers cancel a class' using errcode = 'PT403';
  end if;
  if occ.status = 'cancelled' then
    return jsonb_build_object('ok', true, 'already_cancelled', true,
                              'notified', 0, 'bookings_cancelled', 0);
  end if;

  -- Decision 30 amendment: release any still-provisional free seats FIRST, so
  -- those members get the "booking not confirmed" treatment and keep their free
  -- class, rather than the ordinary class_cancelled. They are cancelled by the
  -- time queue_occurrence_cancelled and the booking loop below run, so neither
  -- touches them again.
  perform release_provisional_seats_run(p_occurrence_id);

  perform set_config('studiior.releasing', '1', true);

  n_notified := coalesce(queue_occurrence_cancelled(p_occurrence_id, p_cause), 0);

  update class_occurrences
     set status = 'cancelled', updated_at = now(),
         cancelled_at = coalesce(cancelled_at, now()),
         cancellation_reason = coalesce(p_reason, cancellation_reason),
         cancellation_cause = p_cause
   where id = p_occurrence_id;

  update bookings set free_cancel_until = now() + interval '1 hour'
   where occurrence_id = p_occurrence_id
     and status in ('booked', 'waitlisted', 'pending_payment');

  for r in
    select id from bookings
     where occurrence_id = p_occurrence_id
       and status in ('booked', 'waitlisted', 'pending_payment')
     order by (status = 'waitlisted') desc, booked_at
  loop
    select * into v_res from cancel_booking(r.id);
    n_cancelled := n_cancelled + 1;
    if coalesce(v_res.credit_returned, false) then n_credited := n_credited + 1; end if;
  end loop;

  -- Decision 77: a CONFIRMED free first class cancelled by the studio is never
  -- taken — delete the member's host-null guest_passes row so free_first_
  -- eligibility treats it as never used (provisional free seats were already
  -- restored by release_provisional_seats_run above). Any cause: §3.2, the member
  -- owes nothing for a studio cancellation, and that includes their free class.
  delete from guest_passes gp
   where gp.host_member_id is null
     and gp.guest_booking_id in (select id from bookings where occurrence_id = p_occurrence_id);

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (occ.studio_id, auth.uid(), 'occurrence.cancelled', 'class_occurrences',
          p_occurrence_id, jsonb_build_object('reason', p_reason, 'cause', p_cause,
                                              'notified', n_notified,
                                              'bookings_cancelled', n_cancelled));

  perform set_config('studiior.releasing', '', true);

  return jsonb_build_object('ok', true, 'cause', p_cause, 'notified', n_notified,
                            'bookings_cancelled', n_cancelled,
                            'credits_returned', n_credited);
end $function$
;

-- =============================================================================
-- 6. close_studio — gains the all-member notice (signature change → drop+create).
-- =============================================================================
drop function if exists close_studio(uuid, date, date, text, time, time, boolean, boolean);
create function close_studio(
  p_studio_id uuid, p_starts_on date, p_ends_on date, p_reason text,
  p_starts_at_time time default null, p_ends_at_time time default null,
  p_confirm boolean default false, p_pays_instructors boolean default false,
  p_notice boolean default false, p_subject text default null, p_message text default null,
  p_message_html text default null, p_message_text text default null, p_resumes_on date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_impact jsonb; v_id uuid; r record; v jsonb; s studios%rowtype;
  v_cancelled int := 0; v_notified int := 0; v_notice_sent int := 0;
  v_tz text; v_fmt text; v_occ_ids uuid[]; o2 class_occurrences%rowtype; v_iu uuid;
  rm record; v_book text; v_resume text; v_sys_text text; v_sys_html text;
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers close the studio' using errcode = 'PT403';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'say why — a closure with no reason is one nobody can explain to a member'
      using errcode = 'PT422';
  end if;
  if (p_starts_at_time is null) <> (p_ends_at_time is null) then
    raise exception 'a partial day needs both a start and an end time' using errcode = 'PT422';
  end if;
  -- Decision 77: the all-member notice is for a closure spanning more than a day.
  if p_notice and p_ends_on = p_starts_on then
    raise exception 'A one-day closure tells the members who are booked, as usual — the notice to everyone is for a closure spanning more than a day.'
      using errcode = 'PT422';
  end if;
  if p_notice and (nullif(btrim(coalesce(p_subject, '')), '') is null
                   or nullif(btrim(coalesce(p_message, '')), '') is null) then
    raise exception 'The notice needs a subject and a message.' using errcode = 'PT422';
  end if;

  v_impact := closure_impact(p_studio_id, p_starts_on, p_ends_on, p_starts_at_time, p_ends_at_time);
  if not p_confirm then
    return v_impact || jsonb_build_object('ok', false, 'requires_confirmation', true);
  end if;

  select * into s from studios where id = p_studio_id;
  v_tz  := s.timezone;
  v_fmt := coalesce((select time_format from studio_settings where studio_id = p_studio_id), '24h');

  insert into studio_closures (studio_id, starts_on, ends_on, starts_at_time, ends_at_time,
                               reason, created_by, pays_instructors, subject, message, resumes_on)
  values (p_studio_id, p_starts_on, p_ends_on, p_starts_at_time, p_ends_at_time,
          btrim(p_reason), auth.uid(), coalesce(p_pays_instructors, false),
          case when p_notice then p_subject end, case when p_notice then p_message end,
          case when p_notice then p_resumes_on end)
  returning id into v_id;

  select array_agg((d ->> 'occurrence_id')::uuid)
    into v_occ_ids from jsonb_array_elements(v_impact -> 'detail') d;

  -- Decision 77: with the notice on, the per-class member emails are suppressed
  -- (the flag is read in queue_occurrence_cancelled and release_provisional_
  -- seats_run) — one notice goes out below instead. Credits, waitlist, calendar
  -- cancel, audit and status all happen exactly as today.
  if p_notice then perform set_config('studiior.closure_notice', '1', true); end if;

  for r in select (d ->> 'occurrence_id')::uuid as id
             from jsonb_array_elements(v_impact -> 'detail') d
  loop
    v := cancel_occurrence(r.id, 'Studio closed: ' || btrim(p_reason), 'closure'::cancellation_cause);
    update class_occurrences set cancellation_pays = coalesce(p_pays_instructors, false) where id = r.id;
    v_cancelled := v_cancelled + 1;
    v_notified := v_notified + coalesce((v ->> 'notified')::int, 0);
    -- Decision 77: closures have never emailed instructors; with the notice on,
    -- tell the assigned instructor per class, as the Decision 47 path does.
    if p_notice then
      select * into o2 from class_occurrences where id = r.id;
      if o2.instructor_id is not null then
        v_iu := instructor_user_id(o2.instructor_id);
        if v_iu is not null then
          perform queue_shift_notice(p_studio_id, v_iu, 'instructor_class_cancelled',
            jsonb_build_object('class_name', o2.name,
              'when', to_char(o2.starts_at at time zone v_tz, 'FMDay FMDD FMMonth YYYY'),
              'occurrence_id', r.id),
            'instructor_class_cancelled:' || r.id);
        end if;
      end if;
    end if;
  end loop;

  if p_notice then perform set_config('studiior.closure_notice', '', true); end if;

  -- Decision 77: ONE studio_closure_notice per member with an address (booked or
  -- not; deleted members excluded). Transactional — from_domain, consent
  -- ignored (unlisted template → always-send), no unsubscribe footer. Their own
  -- cancelled-class list when they had one, "Classes resume {date}", and a button
  -- to the timetable on that day.
  if p_notice then
    v_book   := member_portal_url(p_studio_id, '/book?d=' || p_resumes_on::text);
    v_resume := 'Classes resume ' || to_char(p_resumes_on, 'FMDay FMDD FMMonth YYYY') || '.';
    for rm in
      select m.id,
        (select string_agg(o.name || ' · '
                  || to_char(o.starts_at at time zone v_tz, 'FMDy FMDD FMMon ')
                  || fmt_clock(o.starts_at, v_tz, v_fmt), E'\n' order by o.starts_at)
           from bookings b join class_occurrences o on o.id = b.occurrence_id
          where b.member_id = m.id and o.id = any(v_occ_ids)
            and b.status in ('cancelled', 'late_cancelled')) as list_txt,
        (select string_agg('<li>' || o.name || ' · '
                  || to_char(o.starts_at at time zone v_tz, 'FMDy FMDD FMMon ')
                  || fmt_clock(o.starts_at, v_tz, v_fmt) || '</li>', '' order by o.starts_at)
           from bookings b join class_occurrences o on o.id = b.occurrence_id
          where b.member_id = m.id and o.id = any(v_occ_ids)
            and b.status in ('cancelled', 'late_cancelled')) as list_html
      from members m
     where m.studio_id = p_studio_id and m.deleted_at is null and nullif(m.email, '') is not null
    loop
      v_sys_text := case when rm.list_txt is not null
        then E'These classes of yours were cancelled:\n' || rm.list_txt
             || E'\n\nYour credit (or free first class) is back.\n\n'
        else '' end || v_resume || E'\n\nBook your week: ' || v_book;
      v_sys_html := case when rm.list_html is not null
        then '<p>These classes of yours were cancelled:</p><ul>' || rm.list_html
             || '</ul><p>Your credit (or free first class) is back.</p>'
        else '' end || '<p>' || v_resume || '</p><p><a href="' || v_book || '">Book your week</a></p>';
      perform queue_notification(p_studio_id, rm.id, 'studio_closure_notice',
        jsonb_build_object('subject', p_subject, 'studio_name', s.name,
          'body', coalesce(p_message_text, p_message), 'body_html', coalesce(p_message_html, ''),
          'system_text', v_sys_text, 'system_html', v_sys_html),
        'studio_closure_notice:' || v_id || ':' || rm.id);
      v_notice_sent := v_notice_sent + 1;
    end loop;
    update studio_closures set notice_sent_at = now() where id = v_id;
  end if;

  return jsonb_build_object(
    'ok', true, 'closure_id', v_id, 'starts_on', p_starts_on, 'ends_on', p_ends_on,
    'classes_cancelled', v_cancelled, 'members_notified', v_notified,
    'notice', coalesce(p_notice, false), 'notice_sent', v_notice_sent,
    'pays_instructors', coalesce(p_pays_instructors, false));
end $$;
revoke all on function close_studio(uuid, date, date, text, time, time, boolean, boolean, boolean, text, text, text, text, date) from public, anon;
grant execute on function close_studio(uuid, date, date, text, time, time, boolean, boolean, boolean, text, text, text, text, date) to authenticated, service_role;

-- =============================================================================
-- 7. closure_notice_test — the composer's "Send me a test" for the closure
--    notice. Manager-up, hand-addressed to the caller's own staff email, with a
--    SAMPLE system block (the resume line only — the real email builds each
--    member's cancelled-class list). Not through queue_notification (null member).
-- =============================================================================
create function closure_notice_test(p_studio_id uuid, p_subject text,
  p_body_html text, p_body_text text, p_resumes_on date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s studios%rowtype; v_email text; v_resume text; v_sys_text text; v_sys_html text; v_book text;
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers close the studio' using errcode = 'PT403';
  end if;
  select * into s from studios where id = p_studio_id;
  select pr.email into v_email
    from studio_staff ss join profiles pr on pr.id = ss.user_id
   where ss.user_id = auth.uid() and ss.studio_id = p_studio_id limit 1;
  if nullif(v_email, '') is null then
    raise exception 'no staff email to send the test to' using errcode = 'PT404';
  end if;

  v_resume := case when p_resumes_on is not null
    then 'Classes resume ' || to_char(p_resumes_on, 'FMDay FMDD FMMonth YYYY') || '.' else '' end;
  v_book := member_portal_url(p_studio_id, '/book?d=' || coalesce(p_resumes_on::text, ''));
  v_sys_text := case when v_resume <> '' then v_resume || E'\n\nBook your week: ' || v_book else '' end;
  v_sys_html := case when v_resume <> ''
    then '<p>' || v_resume || '</p><p><a href="' || v_book || '">Book your week</a></p>' else '' end;

  insert into notifications
    (studio_id, recipient_type, member_id, template_key, channel, payload, dedupe_key, scheduled_for, status)
  values
    (p_studio_id, 'member', null, 'studio_closure_notice', 'email',
     jsonb_build_object('to_email', v_email, 'subject', '[Test] ' || p_subject, 'studio_name', s.name,
       'body', p_body_text, 'body_html', p_body_html, 'system_text', v_sys_text, 'system_html', v_sys_html),
     'closure_notice_test:' || p_studio_id || ':' || gen_random_uuid(), now(), 'scheduled');

  return jsonb_build_object('ok', true, 'sentence', 'Sent a test to ' || v_email || '.');
end $$;
revoke all on function closure_notice_test(uuid, text, text, text, date) from public, anon;
grant execute on function closure_notice_test(uuid, text, text, text, date) to authenticated, service_role;

-- =============================================================================
-- Anon surface stays EXACTLY THIRTEEN.
-- =============================================================================
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % functions, expected exactly 13', n; end if;
end $$;
