-- =============================================================================
-- Migration 046: the platform endpoint, the warnings, and the lock
-- =============================================================================
-- A SECOND endpoint with a SECOND signing secret. Connect events and platform
-- events are different deliveries from different Stripe objects, and the two
-- must not be able to be mistaken for one another: this function refuses any
-- event carrying an `account` field, and migration 038's refuses any event
-- without one. A Connect event delivered here is recorded and rejected rather
-- than acted on against our own subscription table.
--
-- Idempotency is the same stripe_events insert, keyed on Stripe's event id, so
-- a replayed platform event is a no-op exactly as a replayed Connect one is.
--
-- WARNINGS ARE LOUD ON PURPOSE. Lockout stops classes running, so a studio
-- must not be able to arrive at it by surprise: an in-app banner from day one
-- of grace, and email on days 1, 7, 12 and 14. Fourteen days is long enough
-- that nobody loses a Saturday to an expired card.
-- =============================================================================

insert into notification_config (key, value, note) values
  ('staff_app_origin', 'https://app.studiior.com',
   'Where a studio''s own billing screen lives. Used in staff-addressed emails, '
   'which must not link a member''s settings screen.')
on conflict (key) do nothing;

insert into notification_templates (key, subject, text_body, html_body, note) values
('platform_billing_warning',
 '{studio_name}: your Studiior subscription needs attention',
 E'Hi {first_name},\n\n{headline}\n\nYour classes, members and bookings are all still here and nothing has been deleted. If the subscription is not reactivated by {grace_ends}, {studio_name} will be locked for staff and members until it is.\n\nReactivate: {billing_url}\n\nIf a card was declined it is usually the bank rather than the card — updating it takes a minute.',
 E'<p>Hi {first_name},</p><p><strong>{headline}</strong></p><p>Your classes, members and bookings are all still here and nothing has been deleted. If the subscription is not reactivated by {grace_ends}, {studio_name} will be locked for staff and members until it is.</p><p><a href="{billing_url}">Reactivate your subscription</a></p><p>If a card was declined it is usually the bank rather than the card — updating it takes a minute.</p>',
 'Days 1, 7, 12 and 14 of the grace period. Addressed to the owner, not a member. Not opt-outable: it ends in classes not running.')
on conflict (key) do nothing;
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
                                 'platform_billing_warning');

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
-- Warning a studio, by email, at the owner
-- -----------------------------------------------------------------------------
create or replace function queue_platform_warning(p_studio_id uuid, p_day int)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  sub platform_subscriptions%rowtype;
  s   studios%rowtype;
  v_owner uuid; v_id uuid; v_headline text;
begin
  select * into sub from platform_subscriptions where studio_id = p_studio_id;
  select * into s   from studios where id = p_studio_id;
  if not found or sub.grace_ends_at is null then
    return null;
  end if;

  -- The owner. Not every staff member: this is the studio's bank relationship
  -- and a front desk being emailed about a declined card is neither useful to
  -- them nor the owner's choice.
  select ss.user_id into v_owner from studio_staff ss
   where ss.studio_id = p_studio_id and ss.role = 'owner' and ss.status = 'active'
   order by ss.created_at limit 1;
  if v_owner is null then
    return null;
  end if;

  v_headline := case
    when p_day >= 14 then 'This is the last day before ' || s.name || ' is locked.'
    when p_day >= 12 then 'Two days left before ' || s.name || ' is locked.'
    when p_day >= 7  then 'A week left to reactivate ' || s.name || '.'
    else 'We could not take payment for your Studiior subscription.'
  end;

  insert into notifications (studio_id, recipient_type, user_id, template_key,
                             channel, payload, dedupe_key, scheduled_for, status)
  values (p_studio_id, 'staff', v_owner, 'platform_billing_warning', 'email',
          jsonb_build_object(
            'headline', v_headline,
            'grace_ends', to_char(sub.grace_ends_at at time zone s.timezone, 'FMDay FMDD FMMonth'),
            'billing_url', coalesce(nullif(notification_setting('staff_app_origin'), ''),
                                    'https://app.studiior.com') || '/billing'),
          -- One per studio per grace period per day, so a sweep that runs twice
          -- cannot email the owner twice about the same day.
          'platform_warning:' || p_studio_id || ':'
            || to_char(sub.grace_ends_at, 'YYYYMMDD') || ':' || p_day,
          now(), 'scheduled')
  on conflict (dedupe_key) do nothing
  returning id into v_id;

  return v_id;
end $$;

/**
 * The daily pass: lapse trials, start grace, warn, and lock.
 *
 * Every transition is driven from a stored date rather than from a clock this
 * function keeps, so running it twice in a day changes nothing and missing a
 * day catches up.
 */
create or replace function sweep_platform_billing() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r record;
  n_lapsed int := 0; n_locked int := 0; n_warned int := 0; v_day int;
begin
  if not is_service_context() then
    raise exception 'platform billing runs as the backend, not as a user'
      using errcode = 'PT403';
  end if;

  -- A trial that ran out without a card becomes past_due and starts the same
  -- fourteen days a failed payment gets. Not locked immediately: somebody who
  -- meant to pay and forgot deserves the same fortnight as somebody whose card
  -- expired.
  for r in
    select * from platform_subscriptions
     where status = 'trialing' and trial_ends_at < now()
  loop
    update platform_subscriptions
       set status = 'past_due',
           grace_ends_at = coalesce(grace_ends_at, r.trial_ends_at + interval '14 days'),
           updated_at = now()
     where id = r.id;
    n_lapsed := n_lapsed + 1;
  end loop;

  -- Warn, on days 1, 7, 12 and 14 of the grace period.
  for r in
    select * from platform_subscriptions
     where status = 'past_due' and grace_ends_at is not null
  loop
    -- ROUNDED, not truncated. grace_ends_at is set to "now + 14 days" and the
    -- sweep runs some hours later, so the remaining interval is 13.4 days, not
    -- 14 — extract(day) truncates that to 13 and day one of grace would never
    -- have fired at all. Rounding to the nearest day makes each of the four
    -- warnings land on the day it is named after.
    v_day := 14 - round(extract(epoch from r.grace_ends_at - now()) / 86400.0)::int;
    if v_day in (1, 7, 12, 14) then
      if queue_platform_warning(r.studio_id, v_day) is not null then
        n_warned := n_warned + 1;
      end if;
    end if;
  end loop;

  -- And lock what has run out.
  for r in
    select * from platform_subscriptions
     where status = 'past_due' and grace_ends_at is not null and grace_ends_at < now()
  loop
    update platform_subscriptions
       set status = 'locked', locked_at = now(), updated_at = now()
     where id = r.id;
    n_locked := n_locked + 1;
  end loop;

  return jsonb_build_object('lapsed', n_lapsed, 'warned', n_warned, 'locked', n_locked);
end $$;

revoke execute on function queue_platform_warning(uuid, int) from public, anon, authenticated;
revoke execute on function sweep_platform_billing() from public, anon, authenticated;
grant execute on function sweep_platform_billing() to service_role;

-- =============================================================================
-- The platform endpoint
-- =============================================================================
create or replace function stripe_platform_handle(p_type text, p_obj jsonb)
returns text
language plpgsql security definer set search_path = public as $$
declare sub platform_subscriptions%rowtype; v_studio uuid; v_end timestamptz;
begin
  -- Resolved from OUR customer id, or from the metadata we set on our own
  -- checkout session. Both are ours: this is our account, not a connected one,
  -- so there is no tenant to be misattributed to somebody else's studio.
  v_studio := nullif(p_obj -> 'metadata' ->> 'studio_id', '')::uuid;
  if v_studio is null then
    select studio_id into v_studio from platform_subscriptions
     where stripe_customer_id = nullif(p_obj ->> 'customer', '')
        or stripe_subscription_id = nullif(p_obj ->> 'subscription', '')
        or stripe_subscription_id = nullif(p_obj ->> 'id', '');
  end if;
  if v_studio is null then
    return 'no_matching_studio';
  end if;
  select * into sub from platform_subscriptions where studio_id = v_studio;

  if p_type = 'checkout.session.completed' then
    update platform_subscriptions
       set status = 'active',
           stripe_customer_id = coalesce(p_obj ->> 'customer', stripe_customer_id),
           stripe_subscription_id = coalesce(nullif(p_obj ->> 'subscription',''), stripe_subscription_id),
           grace_ends_at = null, locked_at = null, updated_at = now()
     where studio_id = v_studio;
    return 'subscribed';

  elsif p_type = 'invoice.paid' then
    v_end := to_timestamp((p_obj -> 'lines' -> 'data' -> 0 -> 'period' ->> 'end')::bigint);
    -- Paying reinstates everything. The lock is a status, never a deletion, so
    -- there is nothing to restore — the studio simply stops being locked.
    update platform_subscriptions
       set status = 'active', current_period_end = coalesce(v_end, current_period_end),
           grace_ends_at = null, locked_at = null,
           stripe_customer_id = coalesce(p_obj ->> 'customer', stripe_customer_id),
           updated_at = now()
     where studio_id = v_studio;
    return 'active';

  elsif p_type = 'invoice.payment_failed' then
    update platform_subscriptions
       set status = case when status = 'locked' then 'locked' else 'past_due' end,
           grace_ends_at = coalesce(grace_ends_at, now() + interval '14 days'),
           updated_at = now()
     where studio_id = v_studio;
    -- Day one, immediately. The rest of the schedule is the daily sweep's.
    perform queue_platform_warning(v_studio, 1);
    return 'past_due';

  elsif p_type = 'customer.subscription.deleted' then
    update platform_subscriptions
       set status = 'cancelled', cancelled_at = now(), updated_at = now()
     where studio_id = v_studio;
    return 'cancelled';
  end if;

  return 'ignored';
end $$;

/**
 * The platform webhook. Same verification path as Connect, different secret.
 *
 * Refuses anything carrying an `account`: that is a Connect event delivered to
 * the wrong endpoint, and acting on it here would apply a studio's member
 * payment to our own subscription table.
 */
create or replace function stripe_platform_webhook(p_payload text, p_signature text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_secret text; e jsonb; v_id text; v_type text; v_result text; n int;
begin
  v_secret := stripe_secret('STRIPE_PLATFORM_WEBHOOK_SECRET');
  if v_secret is null then
    raise exception 'STRIPE_PLATFORM_WEBHOOK_SECRET is not configured'
      using errcode = 'PT503',
            hint = 'The platform endpoint has its own signing secret, separate '
                   'from the Connect one. Set it in Vault.';
  end if;

  if not verify_stripe_signature(p_payload, p_signature, v_secret) then
    raise exception 'bad Stripe signature' using errcode = 'PT401';
  end if;

  e      := p_payload::jsonb;
  v_id   := e ->> 'id';
  v_type := e ->> 'type';
  if v_id is null or v_type is null then
    raise exception 'not a Stripe event' using errcode = 'PT400';
  end if;

  if coalesce((e ->> 'livemode')::boolean, false)
     <> coalesce(stripe_setting('livemode_expected')::boolean, false) then
    raise exception 'livemode mismatch' using errcode = 'PT400';
  end if;

  -- A Connect event has an account. This endpoint is for our own.
  if e ->> 'account' is not null then
    insert into stripe_events (id, stripe_account_id, type, payload, error)
    values (v_id, e ->> 'account', v_type, e,
            'connect event delivered to the platform endpoint')
    on conflict (id) do nothing;
    return jsonb_build_object('status', 'not_a_platform_event', 'type', v_type);
  end if;

  insert into stripe_events (id, type, payload)
  values (v_id, v_type, e)
  on conflict (id) do nothing;
  get diagnostics n = row_count;
  if n = 0 then
    return jsonb_build_object('status', 'duplicate', 'id', v_id);
  end if;

  v_result := stripe_platform_handle(v_type, e -> 'data' -> 'object');
  update stripe_events set processed_at = now() where id = v_id;
  return jsonb_build_object('status', 'processed', 'id', v_id,
                            'type', v_type, 'result', v_result);
end $$;

revoke execute on function stripe_platform_handle(text, jsonb) from public, anon, authenticated;
revoke execute on function stripe_platform_webhook(text, text) from public;
grant execute on function stripe_platform_webhook(text, text) to anon, authenticated, service_role;

do $$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron unavailable; call sweep_platform_billing() externally.';
    return;
  end if;
  create extension if not exists pg_cron;
  if exists (select 1 from cron.job where jobname = 'studiior-platform-billing') then
    perform cron.unschedule('studiior-platform-billing');
  end if;
  -- Daily. Everything it does is driven from stored dates, so a missed day
  -- catches up and a double run changes nothing.
  perform cron.schedule('studiior-platform-billing', '20 3 * * *',
    $job$select sweep_platform_billing()$job$);
end $$;
