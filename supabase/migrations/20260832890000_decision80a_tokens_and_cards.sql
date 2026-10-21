-- Decision 80a fix — no token ever reaches a member, and the cards say something.
--
-- creates: fmt_money(int, text), plan_card_detail(uuid)
-- re-issues: render_notification(uuid), deliver_notification(uuid),
--   convert_keep_sweep(uuid, timestamptz), retention_email_context(uuid, text),
--   send_template_test(uuid, text)
--
-- Authorised by Deanna, 21 Oct 2026 — DDL + template rows only, no data writes.
--
-- (1) render_notification builds the class card's one detail line centrally from
--     the payload's occurrence_id (Day · time · room · with {instructor}, times via
--     fmt_clock in the studio format, missing parts omitted cleanly), and after all
--     substitution STRIPS any residual {token}: a known-optional one (where_line,
--     free_first_html, …) silently, anything else to empty AND into a `stripped`
--     output column. deliver_notification logs those to notification_render_warnings.
-- (2) The plan card gets offer_detail ("3 classes · valid 30 days") and a currency-
--     formatted offer_price ("₱1,500") from convert_keep_sweep + retention_email_context.
-- (3) send_template_test builds a COMPLETE realistic context from the caller's own
--     studio (next class, its offer plan, the caller's name, real URLs) and REFUSES
--     with the list of tokens if the chosen template is still unresolved — never a
--     test with braces.

-- A small diagnostic log: an email that reached delivery with an unfillable token.
create table if not exists notification_render_warnings (
  id              bigint generated always as identity primary key,
  notification_id uuid not null references notifications on delete cascade,
  studio_id       uuid not null references studios on delete cascade,
  template_key    text not null,
  token           text not null,
  created_at      timestamptz not null default now()
);
alter table notification_render_warnings enable row level security;
create policy nrw_manager_read on notification_render_warnings
  for select using (is_manager_up(studio_id));
grant select on notification_render_warnings to authenticated;
grant all on notification_render_warnings to service_role;

-- ---------------------------------------------------------------------------
-- fmt_money(cents, currency) → "₱1,500" / "1,500 Kč" / "$1,500" / "CODE 1,500".
-- Thousands-separated; no decimals when whole, two otherwise.
create or replace function fmt_money(p_cents int, p_currency text) returns text
language sql immutable as $$
  with c as (
    select upper(coalesce(p_currency, '')) as cur,
           trim(to_char(coalesce(p_cents, 0) / 100.0,
             case when coalesce(p_cents, 0) % 100 = 0 then 'FM999,999,999,990'
                  else 'FM999,999,999,990.00' end)) as amt)
  select case cur
    when 'PHP' then '₱' || amt
    when 'USD' then '$' || amt
    when 'GBP' then '£' || amt
    when 'EUR' then '€' || amt
    when 'CZK' then amt || ' Kč'
    when ''    then amt
    else cur || ' ' || amt end
  from c;
$$;
revoke execute on function fmt_money(int, text) from public, anon;
grant  execute on function fmt_money(int, text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- plan_card_detail(plan) → the card's detail line.
--   recurring:  "Unlimited · monthly"  /  "{n} classes · monthly"
--   pack/trial: "{credits} classes · valid {days} days"  /  "… · no expiry"
create or replace function plan_card_detail(p_plan_id uuid) returns text
language sql stable as $$
  select case
    when p.id is null then ''
    when p.type = 'recurring' then
      (case when p.credits_per_period is null then 'Unlimited'
            else p.credits_per_period || ' classes' end)
      || ' · ' ||
      (case lower(coalesce(p.billing_interval::text, 'month'))
         when 'month' then 'monthly' when 'week' then 'weekly'
         when 'year' then 'yearly'  when 'day'  then 'daily'
         else coalesce(p.billing_interval::text, 'monthly') end)
    else
      coalesce(p.credits, 0) || ' classes · ' ||
      (case when p.validity_days is null then 'no expiry'
            else 'valid ' || p.validity_days || ' days' end)
  end
  from membership_plans p where p.id = p_plan_id;
$$;
revoke execute on function plan_card_detail(uuid) from public, anon;
grant  execute on function plan_card_detail(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- render_notification — the frame (80a) + the class card line + token stripping.
-- DROP + recreate: a `stripped text[]` output column is added.
drop function if exists render_notification(uuid);
CREATE FUNCTION public.render_notification(p_notification_id uuid)
 RETURNS TABLE(to_email text, from_name text, reply_to text, subject text, text_body text, html_body text, stripped text[])
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  n notifications%rowtype; t notification_templates%rowtype;
  m members%rowtype; s studios%rowtype;
  v_staff_email text; v_staff_name text; v_is_staff boolean;
  v_sub text; v_txt text; v_html text; k text; rule text; v_on text;
  v_addr text; v_link text; v_contact text; v_contact_html text; v_ig text;
  v_always boolean; v_foot_txt text; v_foot_html text;
  v_ov_key text; v_ov_subject text; v_ov_body text; v_ov_html text;
  v_logo text; v_fmt text; v_occ_id uuid; v_class_line text;
  v_tok text; v_stripped text[] := '{}';
begin
  select * into n from notifications where id = p_notification_id;
  select * into t from notification_templates where key = n.template_key;
  select o.key, o.subject, o.body, o.body_html
    into v_ov_key, v_ov_subject, v_ov_body, v_ov_html
    from notification_templates_overrides o
   where o.studio_id = n.studio_id and o.key = n.template_key;
  select * into m from members where id = n.member_id;

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
  select coalesce(time_format, '24h') into v_fmt from studio_settings where studio_id = n.studio_id;
  v_fmt := coalesce(v_fmt, '24h');

  if v_ov_key is not null then
    v_sub := v_ov_subject; v_txt := v_ov_body; v_html := v_ov_html;
  else
    v_sub := t.subject; v_txt := t.text_body; v_html := t.html_body;
  end if;

  for k in select jsonb_object_keys(n.payload) loop
    v_sub  := replace(v_sub,  '{' || k || '}', coalesce(n.payload ->> k, ''));
    v_txt  := replace(v_txt,  '{' || k || '}', coalesce(n.payload ->> k, ''));
    v_html := replace(v_html, '{' || k || '}', coalesce(n.payload ->> k, ''));
  end loop;
  for k in select unnest(array['first_name','studio_name']) loop
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

  -- Decision 80a fix: the class card's ONE detail line, built from the occurrence
  -- so every class email reads the same — Day · time · room · with {instructor},
  -- times via fmt_clock in the studio format, missing parts dropped cleanly.
  v_occ_id := nullif(n.payload ->> 'occurrence_id', '')::uuid;
  if v_occ_id is not null then
    select concat_ws(' · ',
             nullif(to_char(o.starts_at at time zone s.timezone, 'FMDy FMDD FMMon'), ''),
             fmt_clock(o.starts_at, s.timezone, v_fmt),
             nullif(rm.name, ''),
             nullif('with ' || split_part(coalesce(i.display_name, ''), ' ', 1), 'with '))
      into v_class_line
      from class_occurrences o
      left join rooms rm on rm.id = o.room_id
      left join instructors i on i.id = o.instructor_id
     where o.id = v_occ_id;
  end if;
  v_sub  := replace(v_sub,  '{class_line}', coalesce(v_class_line, ''));
  v_txt  := replace(v_txt,  '{class_line}', coalesce(v_class_line, ''));
  v_html := replace(v_html, '{class_line}', coalesce(v_class_line, ''));

  -- Accent (80a): a static template button carries {accent}/{accent_on}.
  rule := coalesce(s.accent_color, '#78716C');
  v_on := email_on_accent(rule);
  v_html := replace(replace(v_html, '{accent_on}', v_on), '{accent}', rule);
  v_txt  := replace(replace(v_txt,  '{accent_on}', v_on), '{accent}', rule);

  -- STRIP any residual {token}: a known-optional one silently, anything else to
  -- empty AND recorded in `stripped` (deliver_notification logs it). No token
  -- ever reaches a member.
  for v_tok in
    select distinct (regexp_matches(coalesce(v_sub,'') || E'\n' || coalesce(v_txt,'') || E'\n' || coalesce(v_html,''),
                                    '\{([a-z_][a-z0-9_]*)\}', 'g'))[1]
  loop
    if not (v_tok = any (array['where_line','free_first_line','free_first_html',
                               'next_three_line','next_three_html','system_text','system_html','class_line'])) then
      v_stripped := array_append(v_stripped, v_tok);
    end if;
    v_sub  := replace(v_sub,  '{' || v_tok || '}', '');
    v_txt  := replace(v_txt,  '{' || v_tok || '}', '');
    v_html := replace(v_html, '{' || v_tok || '}', '');
  end loop;

  select nullif(concat_ws(', ',
           nullif(l.address ->> 'line1', ''), nullif(l.address ->> 'line2', ''),
           nullif(l.address ->> 'city', ''), nullif(l.address ->> 'postal_code', ''),
           nullif(l.address ->> 'country', '')), '')
    into v_addr
    from locations l
   where l.studio_id = s.id and l.status = 'active'
   order by l.is_primary desc, l.created_at limit 1;

  if v_is_staff then
    v_link := coalesce(nullif(notification_setting('staff_app_origin'), ''),
                       'https://app.studiior.com') || '/billing';
  else
  v_link := 'https://' || s.slug || '.'
            || coalesce(notification_setting('member_app_domain'), 'studiior.app') || '/settings';
  end if;

  v_ig := nullif(s.instagram_handle, '');
  v_contact := nullif(concat_ws(' · ', s.contact_email, s.contact_phone,
                 case when v_ig is not null then '@' || v_ig else null end), '');
  v_contact_html := nullif(concat_ws(' · ', s.contact_email, s.contact_phone,
                 case when v_ig is not null
                      then '<a href="https://instagram.com/' || v_ig || '" style="color:#78716C">@' || v_ig || '</a>'
                      else null end), '');

  v_always := n.template_key in ('class_cancelled', 'instructor_substituted',
                                 'guest_invite', 'guest_host_cancelled',
                                 'guest_waiver_reminder', 'guest_waiver_host_nudge',
                                 'member_invite', 'payment_failed', 'staff_message',
                                 'platform_billing_warning', 'class_moved',
                                 'shift_application_received', 'shift_approved',
                                 'shift_declined', 'shift_withdrawn');

  v_foot_txt := concat_ws(E'\n',
    v_contact, v_addr,
    case when v_is_staff then 'Your billing: ' || v_link
         when n.template_key in ('member_invite', 'instructor_invite', 'guest_invite', 'guest_waiver_reminder')
         then 'You are getting this because ' || s.name || ' set up your account.'
         when v_always
         then 'We always send this one — it''s about your booking or your membership. '
              || 'Choose which other emails you get: ' || v_link
         else 'Choose which emails you get: ' || v_link end);

  v_foot_html := concat_ws('<br>',
    v_contact_html, v_addr,
    case when v_is_staff then '<a href="' || v_link || '" style="color:#78716C">Your billing</a>'
         when n.template_key in ('member_invite', 'instructor_invite', 'guest_invite', 'guest_waiver_reminder')
         then 'You are getting this because ' || s.name || ' set up your account.'
         when v_always
         then 'We always send this one — it''s about your booking or your membership. '
              || '<a href="' || v_link || '" style="color:#78716C">Choose which other emails you get</a>'
         else '<a href="' || v_link || '" style="color:#78716C">Choose which emails you get</a>' end);

  v_logo := case when s.logo_url is not null
    then '<img src="' || s.logo_url || '" alt="' || replace(s.name, '"', '')
         || '" width="40" height="40" style="display:block;border:0;border-radius:6px" />'
    else '<div style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;'
         || 'font-weight:600;font-size:18px;color:#14170E">' || s.name || '</div>' end;

  return query select
    coalesce(nullif(n.payload ->> 'to_email', ''), v_staff_email, m.email),
    s.name, s.contact_email, v_sub,
    v_txt || E'\n\n--\n' || v_foot_txt,
    '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" '
      || 'style="background:#F5F5F4;margin:0;padding:0;width:100%"><tr>'
      || '<td align="center" style="padding:24px 12px">'
      || '<!--[if mso]><table role="presentation" width="600" cellspacing="0" cellpadding="0" border="0"><tr><td><![endif]-->'
      || '<table role="presentation" width="600" cellspacing="0" cellpadding="0" border="0" '
      || 'style="width:600px;max-width:600px;background:#FFFFFF;border-radius:12px">'
      || '<tr><td style="padding:28px 28px 0 28px">'
      || v_logo
      || '<div style="height:3px;width:44px;background:' || rule || ';margin:16px 0 4px"></div>'
      || '</td></tr>'
      || '<tr><td style="padding:12px 28px 8px 28px;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;'
      || 'font-size:15px;line-height:22px;color:#14170E">'
      || v_html
      || '</td></tr>'
      || '<tr><td style="padding:16px 28px 28px 28px">'
      || '<div style="border-top:1px solid #E7E5E4;padding-top:14px;'
      || 'font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif;'
      || 'font-size:13px;line-height:18px;color:#78716C">' || v_foot_html || '</div>'
      || '</td></tr></table>'
      || '<!--[if mso]></td></tr></table><![endif]-->'
      || '</td></tr></table>',
    v_stripped;
end $function$;
revoke execute on function render_notification(uuid) from public, anon, authenticated;
grant  execute on function render_notification(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- deliver_notification — re-issued (from 20260832170000) to log any stripped token.
create or replace function deliver_notification(p_notification_id uuid) returns bigint
language plpgsql security definer set search_path = public as $$
declare r record; v_transport text; v_ics text; n notifications%rowtype; v_tok text;
begin
  select * into n from notifications where id = p_notification_id;

  if n.template_key = 'campaign' and n.member_id is not null
     and not notification_wanted(n.member_id, 'campaign') then
    update notifications set status = 'cancelled' where id = p_notification_id;
    return null;
  end if;

  select * into r from render_notification(p_notification_id);

  -- Decision 80a fix: a token that could not be filled never reaches a member
  -- (render_notification stripped it); record it so we see it.
  if r.stripped is not null and array_length(r.stripped, 1) > 0 then
    foreach v_tok in array r.stripped loop
      insert into notification_render_warnings (notification_id, studio_id, template_key, token)
      values (p_notification_id, n.studio_id, n.template_key, v_tok);
    end loop;
  end if;

  if nullif(r.to_email, '') is null then
    raise exception 'notification % has no recipient address', p_notification_id
      using errcode = 'PT422',
            hint = 'Queued with no member, no staff user and no payload to_email.';
  end if;

  v_ics := notification_ics(p_notification_id);

  v_transport := notification_setting('transport');
  if v_transport = 'resend' then
    return send_via_resend(r.to_email, r.from_name, r.reply_to,
                           r.subject, r.text_body, r.html_body, v_ics,
                           notification_envelope_domain(n.template_key));
  end if;
  raise exception 'unknown transport %', v_transport using errcode = 'PT501';
end $$;
revoke execute on function deliver_notification(uuid) from public, anon, authenticated;
grant  execute on function deliver_notification(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- convert_keep_sweep — re-issued (from 20260832660000) to add offer_detail and a
-- currency-formatted offer_price to the convert payload. Everything else byte-same.
create or replace function convert_keep_sweep(p_studio_id uuid, p_now timestamptz default now())
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  st studio_settings%rowtype;
  s  studios%rowtype;
  v_offer membership_plans%rowtype;
  v_tz text; v_fmt text; v_now_date date;
  v_plans text; v_book text; v_buy text;
  v_offer_name text; v_offer_price text; v_offer_detail text;
  r record;
  v_iw jsonb; v_ends timestamptz; v_end_date date;
  v_attended boolean; v_noshow boolean; v_notpurch boolean;
  v_class_date date; v_when text; v_offer_ends text;
  v_payload jsonb; v_sched timestamptz;
  km record; v_newer boolean; v_has_active boolean; v_mend date; v_auto boolean;
  v_kbuy text; v_kpayload jsonb;
  v_atrisk_tpl text; v_unconv_tpl text;
  n int := 0;
begin
  if not is_service_context() then
    raise exception 'this is a scheduled job, not a user action' using errcode = 'PT403';
  end if;

  select * into st from studio_settings where studio_id = p_studio_id;
  if not found or not (coalesce(st.convert_sequence_enabled, false)
                       or coalesce(st.keep_sequence_enabled, false)
                       or coalesce(st.retention_tasks_enabled, false)) then
    return jsonb_build_object('queued', 0);
  end if;
  select * into s from studios where id = p_studio_id;
  v_tz  := s.timezone;
  v_fmt := coalesce(st.time_format, '24h');
  v_now_date := (p_now at time zone v_tz)::date;

  v_plans := member_portal_url(p_studio_id, '/account/plan');
  v_book  := member_portal_url(p_studio_id, '/book');
  if st.intro_offer_plan_id is not null then
    select * into v_offer from membership_plans where id = st.intro_offer_plan_id;
  end if;
  if v_offer.id is not null then
    v_buy        := member_portal_url(p_studio_id, '/buy/' || v_offer.id::text);
    v_offer_name := v_offer.name;
    v_offer_price  := fmt_money(v_offer.price_cents, v_offer.currency);
    v_offer_detail := plan_card_detail(v_offer.id);
  else
    v_buy        := v_plans;
    v_offer_name := 'a membership';
    v_offer_price := ''; v_offer_detail := '';
  end if;

  if coalesce(st.retention_tasks_enabled, false) or coalesce(st.keep_sequence_enabled, false) then
    insert into job_runs (job_key, run_for, status)
    values ('health_refresh:' || p_studio_id::text, v_now_date, 'done')
    on conflict (job_key, run_for) do nothing;
    if found then perform refresh_studio_health(p_studio_id); end if;
  end if;

  select coalesce(ov.body, df.text_body) into v_unconv_tpl
    from notification_templates df
    left join notification_templates_overrides ov on ov.studio_id = p_studio_id and ov.key = 'task_unconverted_message'
   where df.key = 'task_unconverted_message';
  select coalesce(ov.body, df.text_body) into v_atrisk_tpl
    from notification_templates df
    left join notification_templates_overrides ov on ov.studio_id = p_studio_id and ov.key = 'task_at_risk_message'
   where df.key = 'task_at_risk_message';

  if coalesce(st.convert_sequence_enabled, false) then
  for r in
    select b.id as booking_id, b.member_id, b.status as bstatus,
           o.id as occ_id, o.starts_at, o.ends_at,
           coalesce(ct.name, 'your class') as class_name,
           split_part(coalesce(i.display_name, ''), ' ', 1) as instr_first,
           coalesce(nullif(m.first_name, ''), 'there') as first_name
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
      left join class_types ct on ct.id = o.class_type_id
      left join instructors i on i.id = o.instructor_id
      join members m on m.id = b.member_id
     where b.studio_id = p_studio_id
       and b.payment_source = 'comp'
       and m.deleted_at is null
       and not exists (select 1 from guest_passes gp
                        where gp.guest_booking_id = b.id and gp.host_member_id is not null)
  loop
    v_notpurch := not exists (select 1 from memberships ms where ms.member_id = r.member_id);
    v_attended := r.bstatus = 'attended'
                  or exists (select 1 from check_ins ci where ci.booking_id = r.booking_id);
    v_noshow   := r.bstatus = 'no_show';
    v_class_date := (r.starts_at at time zone v_tz)::date;
    v_iw   := intro_window(r.member_id, p_now);
    v_ends := nullif(v_iw ->> 'ends_at', '')::timestamptz;
    v_end_date := (v_ends at time zone v_tz)::date;
    v_when := to_char(r.starts_at at time zone v_tz, 'FMDay FMDD Mon') || ' at ' || fmt_clock(r.starts_at, v_tz, v_fmt);
    v_offer_ends := case when v_ends is not null then to_char(v_ends at time zone v_tz, 'FMDD Mon YYYY') else '' end;

    v_payload := jsonb_build_object(
      'first_name', r.first_name, 'studio_name', s.name,
      'class_name', r.class_name, 'when', v_when, 'occurrence_id', r.occ_id,
      'instructor_first_name', coalesce(nullif(r.instr_first, ''), 'your instructor'),
      'offer_plan_name', v_offer_name, 'offer_price', v_offer_price, 'offer_detail', v_offer_detail,
      'offer_ends', v_offer_ends, 'buy_url', v_buy,
      'plans_url', v_plans, 'book_url', v_book);

    if r.bstatus = 'booked' and v_class_date = v_now_date + 1 then
      v_sched := quiet_hours_shift((v_now_date + time '18:00') at time zone v_tz, v_tz);
      if queue_notification(p_studio_id, r.member_id, 'convert_before_class', v_payload,
            'convert_before_class:' || r.booking_id::text, v_sched) is not null then n := n + 1; end if;
    end if;

    if v_noshow and v_notpurch and v_now_date = v_class_date + 1 then
      v_sched := quiet_hours_shift((v_now_date + time '10:00') at time zone v_tz, v_tz);
      if queue_notification(p_studio_id, r.member_id, 'convert_missed_you', v_payload,
            'convert_missed_you:' || r.booking_id::text, v_sched) is not null then n := n + 1; end if;
    end if;

    if v_attended and v_notpurch then
      if p_now >= r.ends_at + interval '2 hours' and p_now < r.ends_at + interval '26 hours' then
        v_sched := quiet_hours_shift(r.ends_at + interval '2 hours', v_tz);
        if queue_notification(p_studio_id, r.member_id, 'convert_after_class', v_payload,
              'convert_after_class:' || r.booking_id::text, v_sched) is not null then n := n + 1; end if;
      end if;
      if v_now_date = v_class_date + 3 then
        v_sched := quiet_hours_shift((v_now_date + time '10:00') at time zone v_tz, v_tz);
        if queue_notification(p_studio_id, r.member_id, 'convert_day3', v_payload,
              'convert_day3:' || r.booking_id::text, v_sched) is not null then n := n + 1; end if;
      end if;
      if v_now_date = v_class_date + 7 then
        v_sched := quiet_hours_shift((v_now_date + time '10:00') at time zone v_tz, v_tz);
        if queue_notification(p_studio_id, r.member_id, 'convert_day7', v_payload,
              'convert_day7:' || r.booking_id::text, v_sched) is not null then n := n + 1; end if;
        insert into member_tasks (studio_id, member_id, kind, reason, suggested_message, assigned_role)
        values (p_studio_id, r.member_id, 'unconverted_day7',
                'Free class ' || (v_now_date - v_class_date) || ' days ago, not yet booked again',
                replace(replace(replace(v_unconv_tpl, '{first_name}', r.first_name), '{studio_name}', s.name), '{offer_plan_name}', v_offer_name),
                st.retention_tasks_to)
        on conflict (member_id, kind) where status = 'open' do nothing;
      end if;
      if v_offer.id is not null and v_ends is not null and v_now_date = v_end_date then
        v_sched := quiet_hours_shift((v_now_date + time '10:00') at time zone v_tz, v_tz);
        if queue_notification(p_studio_id, r.member_id, 'convert_last_day', v_payload,
              'convert_last_day:' || r.booking_id::text || ':' || v_end_date::text, v_sched) is not null then n := n + 1; end if;
      end if;
    end if;
  end loop;
  end if;

  if coalesce(st.keep_sequence_enabled, false) then
    v_sched := quiet_hours_shift((v_now_date + time '10:00') at time zone v_tz, v_tz);
    for km in
      select ms.id as mid, ms.member_id, ms.plan_id, ms.status, ms.starts_on,
             ms.expires_on, ms.current_period_end, ms.credits_remaining,
             ms.auto_renew, ms.stripe_subscription_id,
             pl.name as plan_name, pl.type as plan_type, pl.status as plan_status,
             coalesce(nullif(m.first_name, ''), 'there') as first_name
        from memberships ms
        join membership_plans pl on pl.id = ms.plan_id
        join members m on m.id = ms.member_id
       where ms.studio_id = p_studio_id and m.deleted_at is null
    loop
      v_mend := coalesce(km.expires_on, (km.current_period_end at time zone v_tz)::date);
      v_auto := coalesce(km.auto_renew, false) or km.stripe_subscription_id is not null;
      v_newer := exists (select 1 from memberships ms2
                          where ms2.member_id = km.member_id and ms2.id <> km.mid
                            and ms2.status = 'active'
                            and coalesce(ms2.starts_on, '-infinity'::date) >= coalesce(km.starts_on, '-infinity'::date));
      v_has_active := exists (select 1 from memberships ms2
                               where ms2.member_id = km.member_id and ms2.status = 'active'
                                 and coalesce(ms2.expires_on, 'infinity'::date) > v_now_date);
      v_kbuy := case when coalesce(km.plan_status, 'active') <> 'archived'
                     then member_portal_url(p_studio_id, '/buy/' || km.plan_id::text)
                     else v_plans end;
      v_kpayload := jsonb_build_object(
        'first_name', km.first_name, 'studio_name', s.name,
        'plan_name', km.plan_name,
        'expires_on', case when v_mend is not null then to_char(v_mend, 'FMDD Mon YYYY') else '' end,
        'credits_left', coalesce(km.credits_remaining, 0),
        'buy_url', v_kbuy, 'book_url', v_book, 'schedule_url', v_book);

      if km.plan_type = 'recurring' and not v_auto and km.status in ('active', 'past_due')
         and not v_newer and v_mend is not null then
        if v_now_date = v_mend - 7 and queue_notification(p_studio_id, km.member_id, 'keep_renew_7',
              v_kpayload, 'keep_renew_7:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
        if v_now_date = v_mend - 1 and queue_notification(p_studio_id, km.member_id, 'keep_renew_1',
              v_kpayload, 'keep_renew_1:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
        if v_now_date = v_mend and queue_notification(p_studio_id, km.member_id, 'keep_renew_0',
              v_kpayload, 'keep_renew_0:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
        if v_now_date = v_mend + 3 and not v_has_active
           and queue_notification(p_studio_id, km.member_id, 'keep_lapsed_3',
              v_kpayload, 'keep_lapsed_3:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
      end if;

      if km.credits_remaining > 0 and km.expires_on is not null
         and km.status = 'active' and not v_newer then
        if v_now_date = km.expires_on - 7 and queue_notification(p_studio_id, km.member_id, 'keep_credits_7',
              v_kpayload, 'keep_credits_7:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
        if v_now_date = km.expires_on - 2 and queue_notification(p_studio_id, km.member_id, 'keep_credits_2',
              v_kpayload, 'keep_credits_2:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
      end if;

      if v_mend is not null and not v_has_active
         and not exists (select 1 from memberships ms3
                          where ms3.member_id = km.member_id
                            and coalesce(ms3.starts_on, '-infinity'::date) > v_mend) then
        if v_now_date = v_mend + 30 and queue_notification(p_studio_id, km.member_id, 'keep_winback_30',
              v_kpayload, 'keep_winback_30:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
        if v_now_date = v_mend + 60 and queue_notification(p_studio_id, km.member_id, 'keep_winback_60',
              v_kpayload, 'keep_winback_60:' || km.mid::text, v_sched) is not null then n := n + 1; end if;
      end if;
    end loop;
  end if;

  if coalesce(st.retention_tasks_enabled, false) then
    update member_tasks mt
       set status = 'dismissed', closed_at = now(), close_note = 'recovered'
     where mt.studio_id = p_studio_id and mt.status = 'open'
       and mt.kind in ('at_risk', 'drifting_fyi')
       and ( coalesce((select m.health_band from members m where m.id = mt.member_id), 'new') in ('healthy', 'new')
          or exists (select 1 from check_ins ci where ci.member_id = mt.member_id and ci.checked_in_at > mt.created_at) );

    for km in
      select m.id as member_id, m.health_band as hb, m.health_reason as hr,
             coalesce(nullif(m.first_name, ''), 'there') as first_name
        from members m
       where m.studio_id = p_studio_id and m.status <> 'archived'
         and m.health_band in ('at_risk', 'drifting')
    loop
      if km.hb = 'at_risk' then
        insert into member_tasks (studio_id, member_id, kind, reason, suggested_message, assigned_role)
        values (p_studio_id, km.member_id, 'at_risk', km.hr,
                replace(replace(v_atrisk_tpl, '{first_name}', km.first_name), '{studio_name}', s.name),
                st.retention_tasks_to)
        on conflict (member_id, kind) where status = 'open' do nothing;
      elsif km.hb = 'drifting' then
        if not exists (select 1 from notifications nx where nx.member_id = km.member_id
                        and nx.template_key = 'keep_drifting' and nx.created_at > p_now - interval '30 days') then
          v_sched := quiet_hours_shift((v_now_date + time '10:00') at time zone v_tz, v_tz);
          if queue_notification(p_studio_id, km.member_id, 'keep_drifting',
                jsonb_build_object('first_name', km.first_name, 'studio_name', s.name, 'schedule_url', v_book, 'book_url', v_book),
                'keep_drifting:' || km.member_id::text || ':' || v_now_date::text, v_sched) is not null then n := n + 1; end if;
        end if;
        insert into member_tasks (studio_id, member_id, kind, reason, suggested_message, assigned_role)
        values (p_studio_id, km.member_id, 'drifting_fyi', km.hr, null, st.retention_tasks_to)
        on conflict (member_id, kind) where status = 'open' do nothing;
      end if;
    end loop;
  end if;

  return jsonb_build_object('queued', n);
end $$;
revoke execute on function convert_keep_sweep(uuid, timestamptz) from public, anon, authenticated;
grant  execute on function convert_keep_sweep(uuid, timestamptz) to service_role;

-- ---------------------------------------------------------------------------
-- retention_email_context — re-issued (from 20260832830000) to add offer_detail
-- and a currency-formatted offer_price for the plan card.
create or replace function retention_email_context(p_member_id uuid, p_situation text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  s studios%rowtype; st studio_settings%rowtype; m members%rowtype;
  v_studio uuid; v_tz text; v_today date;
  v_last_class text; v_last_date date; v_instr text;
  v_days int; v_plan text; v_expires date;
  v_offer membership_plans%rowtype; v_offer_name text; v_buy text; v_book text;
  v_offer_price text; v_offer_detail text;
begin
  select studio_id into v_studio from members where id = p_member_id;
  if v_studio is null then raise exception 'no such member' using errcode = 'PT404'; end if;
  if not retention_can_act(v_studio) then
    raise exception 'that is not your member' using errcode = 'PT403';
  end if;
  select * into s from studios where id = v_studio;
  select * into st from studio_settings where studio_id = v_studio;
  select * into m from members where id = p_member_id;
  v_tz := s.timezone;
  v_today := (now() at time zone v_tz)::date;

  select coalesce(ct.name, o.name, 'your class'),
         (o.starts_at at time zone v_tz)::date,
         split_part(coalesce(i.display_name, ''), ' ', 1)
    into v_last_class, v_last_date, v_instr
    from check_ins ci
    join class_occurrences o on o.id = ci.occurrence_id
    left join class_types ct on ct.id = o.class_type_id
    left join instructors i on i.id = o.instructor_id
   where ci.member_id = p_member_id
   order by ci.checked_in_at desc limit 1;
  if v_last_class is null then
    select coalesce(ct.name, o.name, 'your class'),
           (o.starts_at at time zone v_tz)::date,
           split_part(coalesce(i.display_name, ''), ' ', 1)
      into v_last_class, v_last_date, v_instr
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
      left join class_types ct on ct.id = o.class_type_id
      left join instructors i on i.id = o.instructor_id
     where b.member_id = p_member_id
     order by o.starts_at desc limit 1;
  end if;

  v_days := greatest(0, v_today - coalesce(m.last_visit_at::date, m.first_visit_at::date, v_last_date, v_today));

  select mp.name, coalesce(ms.expires_on, (ms.current_period_end at time zone v_tz)::date)
    into v_plan, v_expires
    from memberships ms join membership_plans mp on mp.id = ms.plan_id
   where ms.member_id = p_member_id
   order by (ms.status = 'active') desc,
            coalesce(ms.expires_on, (ms.current_period_end at time zone v_tz)::date, '-infinity'::date) desc
   limit 1;

  v_book := member_portal_url(v_studio, '/book');
  if st.intro_offer_plan_id is not null then
    select * into v_offer from membership_plans where id = st.intro_offer_plan_id;
  end if;
  if v_offer.id is not null then
    v_buy := member_portal_url(v_studio, '/buy/' || v_offer.id::text);
    v_offer_name := v_offer.name;
    v_offer_price  := fmt_money(v_offer.price_cents, v_offer.currency);
    v_offer_detail := plan_card_detail(v_offer.id);
  else
    v_buy := member_portal_url(v_studio, '/account/plan');
    v_offer_name := 'a membership';
    v_offer_price := ''; v_offer_detail := '';
  end if;

  return jsonb_build_object(
    'first_name', coalesce(nullif(m.first_name, ''), 'there'),
    'last_class', v_last_class,
    'last_class_date', case when v_last_date is not null then to_char(v_last_date, 'FMDD Mon') else '' end,
    'instructor_first', coalesce(nullif(v_instr, ''), 'your instructor'),
    'days_since', v_days::text,
    'plan_name', coalesce(v_plan, 'your plan'),
    'expires_on', case when v_expires is not null then to_char(v_expires, 'FMDay FMDD Mon') else '' end,
    'offer_plan_name', v_offer_name, 'offer_price', v_offer_price, 'offer_detail', v_offer_detail,
    'buy_url', v_buy, 'book_url', v_book, 'studio_name', s.name);
end $$;
revoke execute on function retention_email_context(uuid, text) from public, anon;
grant  execute on function retention_email_context(uuid, text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- send_template_test — a test built from the caller's REAL studio (next class, its
-- offer plan, the caller's name, real URLs), and REFUSED with the token list if the
-- chosen template still has an unresolved token (never a test with braces).
create or replace function send_template_test(p_studio_id uuid, p_key text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_email text; v_fname text; s studios%rowtype; st studio_settings%rowtype;
  v_tz text; v_fmt text; v_plan membership_plans%rowtype;
  o record; v_payload jsonb; v_notif uuid; v_stripped text[];
  v_when text; v_offer_ends text;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'only owners and managers can send a test' using errcode = 'PT403';
  end if;

  select ss.email, split_part(coalesce(pr.full_name, ss.email), ' ', 1)
    into v_email, v_fname
    from studio_staff ss left join profiles pr on pr.id = ss.user_id
   where ss.studio_id = p_studio_id and ss.user_id = auth.uid() and ss.status = 'active';
  if coalesce(v_email, '') = '' then
    raise exception 'no email on file for your account' using errcode = 'PT422';
  end if;

  select * into s from studios where id = p_studio_id;
  select * into st from studio_settings where studio_id = p_studio_id;
  v_tz := s.timezone; v_fmt := coalesce(st.time_format, '24h');

  -- The next scheduled class (for the class card). Null-safe when none.
  select o2.id, coalesce(ct.name, o2.name, 'a class') as cname, o2.starts_at,
         rm.name as room, split_part(coalesce(i.display_name, ''), ' ', 1) as instr
    into o
    from class_occurrences o2
    left join class_types ct on ct.id = o2.class_type_id
    left join rooms rm on rm.id = o2.room_id
    left join instructors i on i.id = o2.instructor_id
   where o2.studio_id = p_studio_id and o2.status = 'scheduled' and o2.starts_at > now()
   order by o2.starts_at limit 1;

  -- The offer plan: the intro offer when set, else the first active plan.
  if st.intro_offer_plan_id is not null then
    select * into v_plan from membership_plans where id = st.intro_offer_plan_id;
  end if;
  if v_plan.id is null then
    select * into v_plan from membership_plans
     where studio_id = p_studio_id and status = 'active' order by sort_order limit 1;
  end if;

  v_when := case when o.starts_at is not null
    then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD Mon') || ' at ' || fmt_clock(o.starts_at, v_tz, v_fmt)
    else '' end;
  v_offer_ends := to_char((now() + interval '14 days') at time zone v_tz, 'FMDD Mon YYYY');

  -- A COMPLETE context — every token any member-facing template uses.
  v_payload := jsonb_build_object(
    'to_email', v_email,
    'first_name', coalesce(nullif(v_fname, ''), 'there'),
    'studio_name', s.name,
    -- class
    'class_name', coalesce(o.cname, 'a class'),
    'occurrence_id', o.id,
    'when', v_when,
    'where_line', case when nullif(o.room, '') is not null then ', in ' || o.room else '' end,
    'when_short', 'tomorrow',
    'when_time', case when o.starts_at is not null then fmt_clock(o.starts_at, v_tz, v_fmt) else '' end,
    'day', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDay') else 'Monday' end,
    'time', case when o.starts_at is not null then fmt_clock(o.starts_at, v_tz, v_fmt) else '' end,
    'deadline_short', case when o.starts_at is not null then fmt_clock(o.starts_at - interval '12 hours', v_tz, v_fmt) || ' ' || to_char((o.starts_at - interval '12 hours') at time zone v_tz, 'FMDy') else 'the evening before' end,
    'cancel_deadline', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDay FMDD Mon') else 'the day before' end,
    'manage_link', member_portal_url(p_studio_id, '/class/' || coalesce(o.id::text, '')),
    'book_url', member_portal_url(p_studio_id, '/book'),
    'schedule_url', member_portal_url(p_studio_id, '/book'),
    -- plan / offer
    'offer_plan_name', coalesce(v_plan.name, 'a membership'),
    'offer_detail', coalesce(plan_card_detail(v_plan.id), ''),
    'offer_price', case when v_plan.id is not null then fmt_money(v_plan.price_cents, v_plan.currency) else '' end,
    'offer_ends', v_offer_ends,
    'buy_url', case when v_plan.id is not null then member_portal_url(p_studio_id, '/buy/' || v_plan.id::text) else member_portal_url(p_studio_id, '/account/plan') end,
    'plan_name', coalesce(v_plan.name, 'your plan'),
    'credits', '3', 'credits_left', '3',
    'expires_on', v_offer_ends, 'ends_on', v_offer_ends,
    'renew_url', case when v_plan.id is not null then member_portal_url(p_studio_id, '/buy/' || v_plan.id::text) else member_portal_url(p_studio_id, '/account/plan') end,
    -- retention / misc
    'last_class', coalesce(o.cname, 'your class'),
    'last_class_date', case when o.starts_at is not null then to_char(o.starts_at at time zone v_tz, 'FMDD Mon') else '' end,
    'instructor_first', coalesce(nullif(o.instr, ''), 'your instructor'),
    'instructor_first_name', coalesce(nullif(o.instr, ''), 'your instructor'),
    'days_since', '10',
    'product', 'Grip socks', 'quantity', '1');

  insert into notifications (studio_id, recipient_type, member_id, template_key, channel,
                             payload, dedupe_key, scheduled_for, status)
  values (p_studio_id, 'member', null, p_key, 'email',
          v_payload, 'tpl_test:' || p_key || ':' || extract(epoch from clock_timestamp())::bigint,
          now(), 'scheduled')
  returning id into v_notif;

  -- Refuse (and don't send) if the chosen template still has an unresolved token.
  select stripped into v_stripped from render_notification(v_notif);
  if v_stripped is not null and array_length(v_stripped, 1) > 0 then
    delete from notifications where id = v_notif;
    raise exception 'This test needs data we could not fill: %',
      array_to_string(v_stripped, ', ') using errcode = 'PT422';
  end if;

  return jsonb_build_object('ok', true, 'to_email', v_email);
end;
$$;
revoke execute on function send_template_test(uuid, text) from public, anon;
grant  execute on function send_template_test(uuid, text) to authenticated, service_role;

-- Decision 80a fix: re-render every re-dressed template through lib/email-body.mjs.
-- Class card detail = {class_line}; plan card = name/{offer_detail}/{offer_price}/a specific button.
-- Subject + (non-retention) text_body UNCHANGED; per-studio overrides untouched.

update notification_templates set html_body = '<p>Hi {first_name},</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{class_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">{class_line}</div></td></tr></table>
{free_first_html}
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{manage_link}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Manage this booking</a></td></tr></table>
<p>If you can&#39;t make it, cancel in the app and the place goes to someone on the list.</p>
<p>{studio_name}</p>' where key = 'booking_confirmed';
update notification_templates set html_body = '<p>{class_name} on {day} is confirmed — see you at {time}.</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{class_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">{class_line}</div></td></tr></table>
<p>This is your free first class: if you can&#39;t make it, cancel before {cancel_deadline} or rebook another class, otherwise the free class is used.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{manage_link}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Manage your booking</a></td></tr></table>' where key = 'free_booking_confirmed';
update notification_templates set html_body = '<p>You&#39;re booked for {class_name}, {when}.</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{class_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">{class_line}</div></td></tr></table>
<p>We&#39;ll email you by {deadline_short} to confirm this class is going ahead. Nothing else to do.</p>' where key = 'flex_booking_pending';
update notification_templates set html_body = '<p>Your class is going ahead.</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{class_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">{class_line}</div></td></tr></table>
<p>See you {when} at {studio_name}.</p>' where key = 'flex_booking_confirmed';
update notification_templates set html_body = '<p>Your booking for {class_name} on {when} wasn&#39;t confirmed this time.</p>
<p>Your credit is back on your account and ready to use, so you can book another class straight away.</p>
{next_three_html}' where key = 'flex_booking_not_confirmed';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{class_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">{when_short} · {when_time}</div></td></tr></table>
<p>See you there.</p>
<p>{studio_name}</p>' where key = 'class_reminder';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<p>You&#39;re booked for {class_name} on {when}. A few things to make it easy:</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{class_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">{class_line}</div></td></tr></table>
<p>• Wear something you can move in; we have everything else.<br>• Come about 10 minutes early so {instructor_first_name} can show you around.<br>• Water and a towel are handy.</p>
<p>See you there!</p>
<p>— {studio_name}</p>' where key = 'convert_before_class';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<p>We hope you enjoyed {class_name} with {instructor_first_name}. If it felt good, the easiest way to keep going is {offer_plan_name}:</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{offer_plan_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">{offer_detail}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;color:#14170E;margin-top:8px">{offer_price}</div><div style="margin-top:4px"><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{buy_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Buy {offer_plan_name} — {offer_price}</a></td></tr></table></div></td></tr></table>
<p>— {studio_name}</p>' where key = 'convert_after_class';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<p>Ready for round two? {offer_plan_name} keeps it simple, and the schedule is here whenever you want to book:</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{offer_plan_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">{offer_detail}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;color:#14170E;margin-top:8px">{offer_price}</div><div style="margin-top:4px"><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{buy_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Buy {offer_plan_name} — {offer_price}</a></td></tr></table></div></td></tr></table>
<p>— {studio_name}</p>' where key = 'convert_day3';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<p>No rush — your spot at {studio_name} is here when you want it. If you&#39;d like to come back, {offer_plan_name} is the easiest start:</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{offer_plan_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">{offer_detail}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;color:#14170E;margin-top:8px">{offer_price}</div><div style="margin-top:4px"><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{buy_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Buy {offer_plan_name} — {offer_price}</a></td></tr></table></div></td></tr></table>
<p>— {studio_name}</p>' where key = 'convert_day7';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<p>Today is the last day to start with {offer_plan_name} ({offer_price}) — it&#39;s open until {offer_ends}. If you&#39;ve been meaning to come back, this is the moment:</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{offer_plan_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">{offer_detail}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;color:#14170E;margin-top:8px">{offer_price}</div><div style="margin-top:4px"><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{buy_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Buy {offer_plan_name} — {offer_price}</a></td></tr></table></div></td></tr></table>
<p>— {studio_name}</p>' where key = 'convert_last_day';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<p>We had you down for {class_name} and didn&#39;t get to meet you — no problem at all. Your first class is still on us, so pick another time whenever suits:</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{book_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Book your free class</a></td></tr></table>
<p>— {studio_name}</p>' where key = 'convert_missed_you';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<p>Your {plan_name} at {studio_name} ends on {expires_on}. Renewing keeps your spot and takes a moment:</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{plan_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">Ends {expires_on}</div><div style="margin-top:4px"><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{buy_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Renew {plan_name}</a></td></tr></table></div></td></tr></table>
<p>— {studio_name}</p>' where key = 'keep_renew_7';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<p>A quick reminder — your {plan_name} at {studio_name} ends tomorrow ({expires_on}). Renew to keep going without a gap:</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{plan_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">Ends tomorrow — {expires_on}</div><div style="margin-top:4px"><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{buy_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Renew {plan_name}</a></td></tr></table></div></td></tr></table>
<p>— {studio_name}</p>' where key = 'keep_renew_1';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<p>Your {plan_name} at {studio_name} ends today. If you&#39;d like to keep your spot, renewing takes a moment:</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{plan_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">Ends today — {expires_on}</div><div style="margin-top:4px"><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{buy_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Renew {plan_name}</a></td></tr></table></div></td></tr></table>
<p>— {studio_name}</p>' where key = 'keep_renew_0';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<p>Your {plan_name} ended a few days ago, but your spot is still here — no need to start over. Pick up where you left off whenever you&#39;re ready:</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{plan_name}</div><div style="margin-top:4px"><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{buy_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Pick up where you left off</a></td></tr></table></div></td></tr></table>
<p>— {studio_name}</p>' where key = 'keep_lapsed_3';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<p>You have {credits_left} classes left at {studio_name}, and they expire on {expires_on}. Here is this week&#39;s schedule so none go to waste:</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{credits_left} classes left</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">Expire {expires_on}</div><div style="margin-top:4px"><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{schedule_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Book a class</a></td></tr></table></div></td></tr></table>
<p>— {studio_name}</p>' where key = 'keep_credits_7';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<p>Just a nudge — your {credits_left} remaining classes at {studio_name} expire on {expires_on}. Grab a spot this week:</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{credits_left} classes left</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">Expire {expires_on}</div><div style="margin-top:4px"><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{schedule_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Book a class</a></td></tr></table></div></td></tr></table>
<p>— {studio_name}</p>' where key = 'keep_credits_2';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<p>It&#39;s been a few weeks since your last class at {studio_name}, and we&#39;d love to see you again. Come back whenever suits — your first step is here:</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{buy_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Come back</a></td></tr></table>
<p>— {studio_name}</p>' where key = 'keep_winback_30';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<p>Still thinking about coming back? Your spot at {studio_name} is here whenever you&#39;re ready — no pressure, no catch:</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{buy_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Come back to {studio_name}</a></td></tr></table>
<p>— {studio_name}</p>' where key = 'keep_winback_60';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<p>Your {plan_name} at {studio_name} ends on {ends_on}. To keep going, renew for another period — it takes a moment and there is nothing to set up:</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{plan_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">Ends {ends_on}</div><div style="margin-top:4px"><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{renew_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Renew {plan_name}</a></td></tr></table></div></td></tr></table>
<p>— {studio_name}</p>' where key = 'membership_expiring';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{credits} classes left</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">Run out on {expires_on}</div></td></tr></table>
<p>That&#39;s a week from now, so there&#39;s still time to use them.</p>
<p>{studio_name}</p>' where key = 'credit_expiry';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{product} ×{quantity}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">Paid — ready to collect</div></td></tr></table>
<p>Pick it up at the front desk whenever suits you.</p>
<p>— {studio_name}</p>' where key = 'product_order_paid';
update notification_templates set text_body = 'Hi {first_name},

It was lovely having you in for {last_class} on {last_class_date} with {instructor_first}. We would love to see you again.

Your first class was on us — if you enjoyed it, {offer_plan_name} is a gentle way to keep going.

::: card
name: {offer_plan_name}
detail: {offer_detail}
price: {offer_price}
button: See {offer_plan_name} — {offer_price} | {buy_url}
:::

Any questions, just reply to this email.

{studio_name}', html_body = '<p>Hi {first_name},</p>
<p>It was lovely having you in for {last_class} on {last_class_date} with {instructor_first}. We would love to see you again.</p>
<p>Your first class was on us — if you enjoyed it, {offer_plan_name} is a gentle way to keep going.</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{offer_plan_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">{offer_detail}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;color:#14170E;margin-top:8px">{offer_price}</div><div style="margin-top:4px"><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{buy_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">See {offer_plan_name} — {offer_price}</a></td></tr></table></div></td></tr></table>
<p>Any questions, just reply to this email.</p>
<p>{studio_name}</p>' where key = 'retention_unconverted';
update notification_templates set text_body = 'Hi {first_name},

I noticed it has been {days_since} days since your last class, and I wanted to check in — no pressure at all. You were coming so regularly and we have missed you on the {last_class} mat.

If something got in the way, tell me and we will sort it. Otherwise, your next class is ready when you are.

[Book a class]({book_url}){button}

Warmly,
{studio_name}', html_body = '<p>Hi {first_name},</p>
<p>I noticed it has been {days_since} days since your last class, and I wanted to check in — no pressure at all. You were coming so regularly and we have missed you on the {last_class} mat.</p>
<p>If something got in the way, tell me and we will sort it. Otherwise, your next class is ready when you are.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{book_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Book a class</a></td></tr></table>
<p>Warmly,<br>{studio_name}</p>' where key = 'retention_at_risk';
update notification_templates set text_body = 'Hi {first_name},

Just a soft note — we have not seen you in a little while and wanted you to know the mat is always here. No rush, no pressure.

Whenever you fancy it, here is the timetable.

[See the timetable]({book_url}){button}

{studio_name}', html_body = '<p>Hi {first_name},</p>
<p>Just a soft note — we have not seen you in a little while and wanted you to know the mat is always here. No rush, no pressure.</p>
<p>Whenever you fancy it, here is the timetable.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{book_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">See the timetable</a></td></tr></table>
<p>{studio_name}</p>' where key = 'retention_drifting';
update notification_templates set text_body = 'Hi {first_name},

A quick heads-up: your {plan_name} ends on {expires_on}. If you would like to keep your spot and your rhythm going, you can renew here.

::: card
name: {plan_name}
detail: Ends {expires_on}
button: Renew {plan_name} | {buy_url}
:::

See you on the mat,
{studio_name}', html_body = '<p>Hi {first_name},</p>
<p>A quick heads-up: your {plan_name} ends on {expires_on}. If you would like to keep your spot and your rhythm going, you can renew here.</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{plan_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">Ends {expires_on}</div><div style="margin-top:4px"><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{buy_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Renew {plan_name}</a></td></tr></table></div></td></tr></table>
<p>See you on the mat,<br>{studio_name}</p>' where key = 'retention_expiring';
update notification_templates set text_body = 'Hi {first_name},

It has been a little while since your {plan_name} wrapped up, and we would genuinely love to have you back.

If you are ready, here is a fresh start.

::: card
name: {plan_name}
button: A fresh start | {buy_url}
:::

And if there is anything we could do better, just reply — I read every one.

{studio_name}', html_body = '<p>Hi {first_name},</p>
<p>It has been a little while since your {plan_name} wrapped up, and we would genuinely love to have you back.</p>
<p>If you are ready, here is a fresh start.</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{plan_name}</div><div style="margin-top:4px"><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{buy_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">A fresh start</a></td></tr></table></div></td></tr></table>
<p>And if there is anything we could do better, just reply — I read every one.</p>
<p>{studio_name}</p>' where key = 'retention_lapsed';
