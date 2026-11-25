-- creates: checkout_rescue_run(uuid, timestamptz, boolean), sweep_checkout_rescue(timestamptz), checkout_rescue_backfill(timestamptz)
-- re-issues: studio_by_slug(text, boolean)
--
-- Decision 119: a checkout that expires gets one rescue email.
--
-- ONE DECISION PER CHECKOUT. checkout_rescues holds one row per xendit
-- purchase the rescue has looked at: 'sent' with the notification, or
-- 'skipped' with the reason (paid since, sent in the last 7 days, invalid
-- email, the owner's own account, switched off, no address). The sweep and
-- the backfill both skip a purchase that already has a row, so neither can
-- send twice and the backfill is idempotent.
--
-- WHAT COUNTS AS EXPIRED. A purchase whose status is 'failed' (a Xendit
-- expiry or failure) or 'expired' (the local reconcile sweep, or a released
-- reservation hold), looked at one hour after it ended. A pending checkout
-- that is simply abandoned becomes 'expired' through the reconcile sweep, so
-- it is covered too. Private session checkouts are not in Decision 119's list
-- and are recorded as skipped ('not_covered').
--
-- THE PERSON. A member when the purchase has one; otherwise the guest buyer
-- (Decision 118) or the gift card buyer, by email. "The same person" for the
-- seven day rule is the lower-cased email.
--
-- RESERVATION FEE. Only checkouts started on or after 25 Nov 2026 (studio
-- local), never by the backfill. Before that date the purchase is recorded
-- as skipped so nothing ever reconsiders it.
--
-- REPLY-TO. render_notification already returns the studio's contact email
-- as reply_to for every template and send_via_resend names it, so nothing on
-- the send path changes.

-- ---- The record ---------------------------------------------------------------
create table if not exists checkout_rescues (
  purchase_id     uuid primary key references xendit_purchases(id) on delete cascade,
  studio_id       uuid not null references studios(id) on delete cascade,
  email           text,
  item_key        text,
  kind            text,
  outcome         text not null check (outcome in ('sent', 'skipped')),
  reason          text,
  notification_id uuid references notifications(id) on delete set null,
  created_at      timestamptz not null default now()
);
create index if not exists checkout_rescues_person_item
  on checkout_rescues (studio_id, lower(email), item_key, created_at desc)
  where outcome = 'sent';

alter table checkout_rescues enable row level security;
drop policy if exists checkout_rescues_manager_read on checkout_rescues;
create policy checkout_rescues_manager_read on checkout_rescues
  for select to authenticated using (coalesce(is_manager_up(studio_id), false));
revoke all on checkout_rescues from public, anon, authenticated;
grant select on checkout_rescues to authenticated;
grant all on checkout_rescues to service_role;

-- ---- checkout_rescue_run ------------------------------------------------------
-- Looks at one purchase and either sends its rescue email or records why not.
-- Returns the outcome ('sent', a skip reason, or a reason it was not ready).
create or replace function checkout_rescue_run(
  p_purchase_id uuid, p_now timestamptz default now(), p_backfill boolean default false
) returns text
language plpgsql security definer set search_path = public as $$
declare
  x xendit_purchases%rowtype;
  m members%rowtype;
  gc gift_cards%rowtype;
  v_tz text; v_fmt text; v_studio_name text; v_msg_on boolean;
  v_end timestamptz;
  v_kind text; v_key text; v_template text;
  v_mid uuid; v_email text; v_first text;
  v_item text; v_retry text; v_label text; v_spots_line text;
  v_payload jsonb; v_reason text; v_nid uuid;
  v_plan membership_plans%rowtype;
  v_prod uuid; v_prod_name text; v_prod_live boolean;
  o class_occurrences%rowtype; v_class text; v_spots int; v_open boolean;
begin
  select * into x from xendit_purchases where id = p_purchase_id;
  if not found then return 'no_such_purchase'; end if;
  if exists (select 1 from checkout_rescues where purchase_id = x.id) then return 'done'; end if;
  if x.status not in ('failed', 'expired') then return 'not_ended'; end if;
  v_end := coalesce(x.completed_at, x.updated_at, x.created_at);
  if v_end > p_now - interval '1 hour' then return 'too_soon'; end if;

  select s.timezone, s.name, coalesce(ss.time_format, '24h'), coalesce(ss.messages_enabled, false)
    into v_tz, v_studio_name, v_fmt, v_msg_on
    from studios s left join studio_settings ss on ss.studio_id = s.id
   where s.id = x.studio_id;

  v_kind := case when x.plan_id is not null then 'plan'
                 when x.gift_card_id is not null then 'gift'
                 when x.product_order_id is not null then 'shop'
                 when x.booking_id is not null then 'reservation'
                 else 'other' end;

  if v_kind = 'reservation' and p_backfill then
    return 'backfill_excludes_reservation';
  end if;

  if v_kind = 'other' then
    v_reason := 'not_covered';
  elsif v_kind = 'reservation'
        and x.created_at < ('2026-11-25'::date::timestamp at time zone v_tz) then
    v_reason := 'reservation_before_cutover';
  end if;

  if x.gift_card_id is not null then
    select * into gc from gift_cards where id = x.gift_card_id;
  end if;
  v_mid := coalesce(x.member_id, x.claimed_member_id, gc.buyer_member_id, gc.purchaser_member_id);
  if v_mid is not null then
    select * into m from members where id = v_mid and studio_id = x.studio_id;
    if not found then v_mid := null; end if;
  end if;
  v_email := lower(btrim(coalesce(nullif(btrim(m.email), ''), nullif(btrim(x.buyer_email), ''),
                                  nullif(btrim(gc.buyer_email), ''))));
  v_first := coalesce(nullif(btrim(m.first_name), ''),
                      nullif(split_part(btrim(coalesce(x.buyer_name, gc.buyer_name, '')), ' ', 1), ''),
                      'there');

  v_key := case v_kind
             when 'plan' then 'plan:' || x.plan_id
             when 'gift' then 'gift'
             when 'reservation' then 'reservation'
             else null end;
  if v_kind = 'shop' then
    select po.product_id, p.name, (p.status = 'active')
      into v_prod, v_prod_name, v_prod_live
      from product_orders po join products p on p.id = po.product_id
     where po.id = x.product_order_id;
    v_key := 'product:' || v_prod;
  end if;

  if v_reason is null and v_email is null then v_reason := 'no_email'; end if;
  if v_reason is null and m.id is not null and m.deleted_at is not null then v_reason := 'member_deleted'; end if;

  -- The studio owner's own account.
  if v_reason is null and exists (
       select 1 from studio_staff ss
        where ss.studio_id = x.studio_id and ss.role = 'owner' and ss.status = 'active'
          and (coalesce(ss.user_id = m.user_id, false) or lower(ss.email) = v_email)) then
    v_reason := 'owner';
  end if;

  -- An address marked invalid or bounced.
  if v_reason is null and (
       coalesce(m.email_status, 'valid') <> 'valid'
       or exists (select 1 from members m2
                   where m2.studio_id = x.studio_id and lower(m2.email) = v_email
                     and coalesce(m2.email_status, 'valid') <> 'valid')
       or exists (select 1 from notifications n
                   where n.studio_id = x.studio_id and n.bounced_at is not null
                     and lower(n.payload ->> 'to_email') = v_email)) then
    v_reason := 'invalid_email';
  end if;

  -- Paid since (for plans, any plan).
  if v_reason is null then
    if v_kind = 'plan' and (
         exists (select 1 from xendit_purchases x2
                  where x2.studio_id = x.studio_id and x2.status = 'succeeded'
                    and x2.plan_id is not null and x2.created_at > x.created_at
                    and (coalesce(x2.member_id = v_mid, false) or coalesce(x2.claimed_member_id = v_mid, false)
                         or lower(x2.buyer_email) = v_email))
         or exists (select 1 from memberships ms
                     where ms.member_id = v_mid and ms.created_at > x.created_at)) then
      v_reason := 'paid_since';
    elsif v_kind = 'gift' and exists (
         select 1 from xendit_purchases x2 join gift_cards g2 on g2.id = x2.gift_card_id
          where x2.studio_id = x.studio_id and x2.status = 'succeeded' and x2.created_at > x.created_at
            and (lower(g2.buyer_email) = v_email or coalesce(x2.member_id = v_mid, false))) then
      v_reason := 'paid_since';
    elsif v_kind = 'shop' and exists (
         select 1 from product_orders po2
          where po2.product_id = v_prod and po2.status in ('paid', 'collected')
            and po2.member_id = v_mid and po2.created_at > x.created_at) then
      v_reason := 'paid_since';
    elsif v_kind = 'reservation' and (
         exists (select 1 from xendit_purchases x2
                  where x2.studio_id = x.studio_id and x2.status = 'succeeded'
                    and x2.booking_id is not null and x2.member_id = v_mid
                    and x2.created_at > x.created_at)
         or exists (select 1 from bookings b2
                     where b2.member_id = v_mid and b2.created_at > x.created_at
                       and b2.status in ('booked', 'attended'))
         or not coalesce((free_first_eligibility_run(x.studio_id, v_mid, null) ->> 'ok')::boolean, false)) then
      v_reason := 'paid_since';
    end if;
  end if;

  -- One rescue per person per item in seven days.
  if v_reason is null and exists (
       select 1 from checkout_rescues cr
        where cr.studio_id = x.studio_id and cr.outcome = 'sent'
          and lower(cr.email) = v_email and cr.item_key = v_key
          and cr.created_at > p_now - interval '7 days') then
    v_reason := 'sent_recently';
  end if;

  if v_reason is not null then
    insert into checkout_rescues (purchase_id, studio_id, email, item_key, kind, outcome, reason)
    values (x.id, x.studio_id, v_email, v_key, v_kind, 'skipped', v_reason);
    return v_reason;
  end if;

  -- What to say and where the button goes.
  if v_kind = 'plan' then
    select * into v_plan from membership_plans where id = x.plan_id;
    v_template := 'checkout_rescue_plan';
    v_item := v_plan.name;
    v_retry := case when v_plan.status = 'active' and v_plan.visibility = 'public'
                    then '/buy/' || x.plan_id else '/buy' end;
    v_label := 'Finish my purchase';
  elsif v_kind = 'gift' then
    v_template := 'checkout_rescue_gift';
    v_item := 'Gift card';
    v_retry := '/gift?amount=' || (coalesce(gc.amount_cents, x.amount_cents) / 100)::text;
    v_label := 'Finish my gift';
  elsif v_kind = 'shop' then
    v_template := 'checkout_rescue_shop';
    v_item := v_prod_name;
    v_retry := case when coalesce(v_prod_live, false) then '/shop#product-' || v_prod else '/shop' end;
    v_label := 'Finish my order';
  else
    v_template := 'checkout_rescue_reservation';
    select o2.* into o from bookings b join class_occurrences o2 on o2.id = b.occurrence_id
     where b.id = x.booking_id;
    select coalesce(o.name, ct.name) into v_class from class_types ct where ct.id = o.class_type_id;
    v_class := coalesce(v_class, o.name, 'your class');
    v_spots := greatest(o.capacity - occurrence_seats_taken(o.id) - occurrence_seats_held(o.id, null), 0);
    v_open := o.status = 'scheduled' and o.starts_at > p_now
              and not coalesce(o.hidden_from_members, false) and v_spots > 0;
    v_item := v_class;
    if v_open then
      v_spots_line := case when v_spots = 1
        then 'There is only 1 spot left in that class. Grab yours before someone else does.'
        else 'There are only ' || v_spots || ' spots left in that class. Grab yours before someone else does.' end;
      v_label := 'Hold my spot';
      v_retry := '/class/' || o.id;
    else
      v_spots_line := 'That class filled up, but your free class is still waiting. Pick another time this week.';
      v_label := 'Book my free class';
      v_retry := '/book';
    end if;
  end if;

  v_payload := jsonb_build_object(
    'to_email', v_email,
    'first_name', v_first,
    'studio_name', v_studio_name,
    'item_name', v_item,
    'retry_label', v_label,
    'retry_url', member_portal_url(x.studio_id, v_retry),
    'message_url', member_portal_url(x.studio_id,
                     case when v_mid is not null and v_msg_on then '/messages' else '/buy#contact' end),
    'amount', fmt_money(x.amount_cents, x.currency),
    'purchase_id', x.id);
  if v_kind = 'gift' then
    v_payload := v_payload || jsonb_build_object(
      'recipient_name', coalesce(nullif(btrim(gc.recipient_name), ''), 'your friend'));
  elsif v_kind = 'reservation' then
    v_payload := v_payload || jsonb_build_object(
      'class_name', v_class,
      'day', to_char(o.starts_at at time zone v_tz, 'FMDay FMDD FMMonth'),
      'time', fmt_clock(o.starts_at, v_tz, v_fmt),
      'spots_left', v_spots,
      'spots_line', v_spots_line,
      'fee', fmt_money(x.amount_cents, x.currency),
      'occurrence_id', o.id);
  end if;

  v_nid := queue_notification(x.studio_id, v_mid, v_template, v_payload,
                              'checkout_rescue:' || x.id, quiet_hours_shift(p_now, v_tz));
  if v_nid is null then
    insert into checkout_rescues (purchase_id, studio_id, email, item_key, kind, outcome, reason)
    values (x.id, x.studio_id, v_email, v_key, v_kind, 'skipped', 'switched_off');
    return 'switched_off';
  end if;

  insert into checkout_rescues (purchase_id, studio_id, email, item_key, kind, outcome, notification_id)
  values (x.id, x.studio_id, v_email, v_key, v_kind, 'sent', v_nid);
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (x.studio_id, auth.uid(), 'checkout.rescue_sent', 'xendit_purchases', x.id,
          jsonb_build_object('kind', v_kind, 'template', v_template, 'email', v_email,
                             'item', v_item, 'notification_id', v_nid, 'backfill', p_backfill));
  return 'sent';
end $$;
revoke execute on function checkout_rescue_run(uuid, timestamptz, boolean) from public, anon, authenticated;
grant  execute on function checkout_rescue_run(uuid, timestamptz, boolean) to service_role;

-- ---- sweep_checkout_rescue ----------------------------------------------------
-- Every 15 minutes: checkouts that ended between one hour and three days ago
-- and have not been looked at. Newest first, so with two attempts at one item
-- the newer one is the one rescued.
create or replace function sweep_checkout_rescue(p_now timestamptz default now())
returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; v text; n_sent int := 0; n_skipped int := 0;
begin
  if not is_service_context() then
    raise exception 'sweep_checkout_rescue runs as a background job' using errcode = 'PT403';
  end if;
  for r in
    select xp.id from xendit_purchases xp
     where xp.status in ('failed', 'expired')
       and coalesce(xp.completed_at, xp.updated_at, xp.created_at) <= p_now - interval '1 hour'
       and coalesce(xp.completed_at, xp.updated_at, xp.created_at) >  p_now - interval '3 days'
       and not exists (select 1 from checkout_rescues cr where cr.purchase_id = xp.id)
     order by xp.created_at desc
  loop
    v := checkout_rescue_run(r.id, p_now, false);
    if v = 'sent' then n_sent := n_sent + 1;
    elsif v not in ('done', 'too_soon', 'not_ended') then n_skipped := n_skipped + 1; end if;
  end loop;
  return jsonb_build_object('sent', n_sent, 'skipped', n_skipped);
end $$;
revoke execute on function sweep_checkout_rescue(timestamptz) from public, anon, authenticated;
grant  execute on function sweep_checkout_rescue(timestamptz) to service_role;

-- ---- checkout_rescue_backfill -------------------------------------------------
-- The one-time send at release: every expired or failed checkout since 9 Nov
-- 2026 (studio local), reservation fee checkouts excluded. Idempotent.
create or replace function checkout_rescue_backfill(p_now timestamptz default now())
returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; v text; v_out jsonb := '{}'::jsonb;
begin
  if not is_service_context() then
    raise exception 'checkout_rescue_backfill runs as a background job' using errcode = 'PT403';
  end if;
  for r in
    select xp.id,
           case when xp.plan_id is not null then 'plan' when xp.gift_card_id is not null then 'gift'
                when xp.product_order_id is not null then 'shop' else 'other' end as kind
      from xendit_purchases xp join studios s on s.id = xp.studio_id
     where xp.status in ('failed', 'expired')
       and xp.booking_id is null
       and xp.created_at >= ('2026-11-09'::date::timestamp at time zone s.timezone)
       and not exists (select 1 from checkout_rescues cr where cr.purchase_id = xp.id)
     order by xp.created_at desc
  loop
    v := checkout_rescue_run(r.id, p_now, true);
    if v not in ('done', 'too_soon', 'not_ended') then
      v_out := jsonb_set(v_out, array[r.kind || ':' || v],
                         to_jsonb(coalesce((v_out ->> (r.kind || ':' || v))::int, 0) + 1));
    end if;
  end loop;
  return v_out;
end $$;
revoke execute on function checkout_rescue_backfill(timestamptz) from public, anon, authenticated;
grant  execute on function checkout_rescue_backfill(timestamptz) to service_role;

select cron.schedule('studiior-checkout-rescue', '*/15 * * * *', $c$select sweep_checkout_rescue()$c$);

-- ---- The four emails: platform defaults + Reform overrides --------------------
insert into notification_templates (key, subject, text_body, html_body, note) values
('checkout_rescue_plan', 'Still thinking about {item_name}, {first_name}?', E'Hi {first_name},\n\nYour payment link for {item_name} at {studio_name} timed out before it went through, so nothing was charged.\n\nIt is still here when you are ready.\n\nFinish my purchase: {retry_url}\n\nGot a question first? Message the studio.\n\nMessage the studio: {message_url}\n\n{studio_name}', '<p>Hi {first_name},</p>
<p>Your payment link for {item_name} at {studio_name} timed out before it went through, so nothing was charged.</p>
<p>It is still here when you are ready.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{retry_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Finish my purchase</a></td></tr></table>
<p>Got a question first? Message the studio.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{message_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Message the studio</a></td></tr></table>
<p>{studio_name}</p>', 'Decision 119: checkout rescue'),
('checkout_rescue_reservation', 'Your spot in {class_name} is still open, {first_name}', E'Hi {first_name},\n\nYour payment link for {class_name} on {day} at {time} timed out, so your spot is not held yet.\n\n{spots_line}\n\nThe {fee} is not a charge for the class. Show up and it comes back to you as studio credit, to use on your next class pack or merchandise.\n\n{retry_label}: {retry_url}\n\nGot a question first? Message the studio.\n\nMessage the studio: {message_url}\n\n{studio_name}', '<p>Hi {first_name},</p>
<p>Your payment link for {class_name} on {day} at {time} timed out, so your spot is not held yet.</p>
<p>{spots_line}</p>
<p>The {fee} is not a charge for the class. Show up and it comes back to you as studio credit, to use on your next class pack or merchandise.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{retry_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">{retry_label}</a></td></tr></table>
<p>Got a question first? Message the studio.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{message_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Message the studio</a></td></tr></table>
<p>{studio_name}</p>', 'Decision 119: checkout rescue'),
('checkout_rescue_gift', 'Your gift card didn''t go through, {first_name}', E'Hi {first_name},\n\nYour gift card for {recipient_name} from {studio_name} did not go through, so nothing was charged.\n\nIt only takes a minute to finish.\n\nFinish my gift: {retry_url}\n\nGot a question first? Message the studio.\n\nMessage the studio: {message_url}\n\n{studio_name}', '<p>Hi {first_name},</p>
<p>Your gift card for {recipient_name} from {studio_name} did not go through, so nothing was charged.</p>
<p>It only takes a minute to finish.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{retry_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Finish my gift</a></td></tr></table>
<p>Got a question first? Message the studio.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{message_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Message the studio</a></td></tr></table>
<p>{studio_name}</p>', 'Decision 119: checkout rescue'),
('checkout_rescue_shop', 'Your {item_name} is still here, {first_name}', E'Hi {first_name},\n\nYour order for {item_name} from {studio_name} did not go through, so nothing was charged.\n\nIt is still here when you are ready.\n\nFinish my order: {retry_url}\n\nGot a question first? Message the studio.\n\nMessage the studio: {message_url}\n\n{studio_name}', '<p>Hi {first_name},</p>
<p>Your order for {item_name} from {studio_name} did not go through, so nothing was charged.</p>
<p>It is still here when you are ready.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{retry_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Finish my order</a></td></tr></table>
<p>Got a question first? Message the studio.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{message_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Message the studio</a></td></tr></table>
<p>{studio_name}</p>', 'Decision 119: checkout rescue')
on conflict (key) do nothing;

insert into notification_templates_overrides (studio_id, key, subject, body, body_html)
select s.id, 'checkout_rescue_plan', 'Still thinking about {item_name}, {first_name}?',
 E'Hi {first_name},\n\nWe saw you looking at the {item_name}. Your payment link timed out before it went through, so nothing was charged.\n\nIt''s still here when you''re ready.\n\n[Finish my purchase]({retry_url}){button}\n\nGot a question first? Message us and we''ll help.\n\n[Message the studio]({message_url}){button}\n\nSee you at the reformer!🎀\n\nRPC Studio',
 '<p>Hi {first_name},</p>
<p>We saw you looking at the {item_name}. Your payment link timed out before it went through, so nothing was charged.</p>
<p>It&#39;s still here when you&#39;re ready.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{retry_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Finish my purchase</a></td></tr></table>
<p>Got a question first? Message us and we&#39;ll help.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{message_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Message the studio</a></td></tr></table>
<p>See you at the reformer!🎀</p>
<p>RPC Studio</p>'
  from studios s where s.slug = 'reformcollective'
on conflict (studio_id, key) do nothing;

insert into notification_templates_overrides (studio_id, key, subject, body, body_html)
select s.id, 'checkout_rescue_reservation', 'Your spot in {class_name} is still open, {first_name}',
 E'Hi {first_name},\n\nYou were so close! Your payment link for {class_name} on {day} at {time} timed out, so your spot isn''t held yet.\n\n{spots_line}\n\nThe {fee} isn''t a charge for the class. Show up and it comes straight back to you as studio credit, to use on your next class pack or merchandise.\n\n[{retry_label}]({retry_url}){button}\n\nGot a question first? Message us and we''ll help.\n\n[Message the studio]({message_url}){button}\n\nSee you at the reformer!🎀\n\nRPC Studio',
 '<p>Hi {first_name},</p>
<p>You were so close! Your payment link for {class_name} on {day} at {time} timed out, so your spot isn&#39;t held yet.</p>
<p>{spots_line}</p>
<p>The {fee} isn&#39;t a charge for the class. Show up and it comes straight back to you as studio credit, to use on your next class pack or merchandise.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{retry_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">{retry_label}</a></td></tr></table>
<p>Got a question first? Message us and we&#39;ll help.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{message_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Message the studio</a></td></tr></table>
<p>See you at the reformer!🎀</p>
<p>RPC Studio</p>'
  from studios s where s.slug = 'reformcollective'
on conflict (studio_id, key) do nothing;

insert into notification_templates_overrides (studio_id, key, subject, body, body_html)
select s.id, 'checkout_rescue_gift', 'Your gift card didn''t go through, {first_name}',
 E'Hi {first_name},\n\nYour gift card for {recipient_name} didn''t go through, so nothing was charged.\n\nIt only takes a minute to finish.\n\n[Finish my gift]({retry_url}){button}\n\nGot a question first? Message us and we''ll help.\n\n[Message the studio]({message_url}){button}\n\nSee you at the reformer!🎀\n\nRPC Studio',
 '<p>Hi {first_name},</p>
<p>Your gift card for {recipient_name} didn&#39;t go through, so nothing was charged.</p>
<p>It only takes a minute to finish.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{retry_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Finish my gift</a></td></tr></table>
<p>Got a question first? Message us and we&#39;ll help.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{message_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Message the studio</a></td></tr></table>
<p>See you at the reformer!🎀</p>
<p>RPC Studio</p>'
  from studios s where s.slug = 'reformcollective'
on conflict (studio_id, key) do nothing;

insert into notification_templates_overrides (studio_id, key, subject, body, body_html)
select s.id, 'checkout_rescue_shop', 'Your {item_name} is still here, {first_name}',
 E'Hi {first_name},\n\nYour order for {item_name} didn''t go through, so nothing was charged.\n\nIt''s still here when you''re ready.\n\n[Finish my order]({retry_url}){button}\n\nGot a question first? Message us and we''ll help.\n\n[Message the studio]({message_url}){button}\n\nSee you at the reformer!🎀\n\nRPC Studio',
 '<p>Hi {first_name},</p>
<p>Your order for {item_name} didn&#39;t go through, so nothing was charged.</p>
<p>It&#39;s still here when you&#39;re ready.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{retry_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Finish my order</a></td></tr></table>
<p>Got a question first? Message us and we&#39;ll help.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{message_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Message the studio</a></td></tr></table>
<p>See you at the reformer!🎀</p>
<p>RPC Studio</p>'
  from studios s where s.slug = 'reformcollective'
on conflict (studio_id, key) do nothing;


-- ---- studio_by_slug: re-issued (20260833710000), + buy.contact_email --------
create or replace function studio_by_slug(p_slug text, p_with_plans boolean default false)
 returns table(id uuid, name text, slug text, timezone text, currency text, logo_url text,
   theme_preset theme_preset, accent_color text, login_image_url text,
   login_image_focus_x smallint, login_image_focus_y smallint,
   free_first_class_enabled boolean, login_tagline text, install_welcome text, time_format text,
   android_package text, android_sha256_fingerprints text, ios_team_id text, ios_bundle_id text,
   gift_enabled boolean, gift_presets int[], gift_min_cents int, gift_card_image_url text,
   buy jsonb)
 language sql stable security definer set search_path to 'public' as $function$
  select s.id, s.name, s.slug, s.timezone, s.currency,
         s.logo_url, s.theme_preset, s.accent_color, s.login_image_url,
         s.login_image_focus_x, s.login_image_focus_y,
         coalesce(ss.free_first_class_enabled, false),
         s.login_tagline, s.install_welcome,
         coalesce(ss.time_format, '24h'),
         s.android_package, s.android_sha256_fingerprints, s.ios_team_id, s.ios_bundle_id,
         coalesce(ss.gift_enabled, false),
         coalesce(ss.gift_presets, array[100000, 250000, 500000]),
         coalesce(ss.gift_min_cents, 50000),
         ss.gift_card_image_path,
         -- Decision 118: the plans anybody may buy, with today's price
         -- (plan_price_now_run, so a running promotion shows). Only when asked.
         case when p_with_plans then jsonb_build_object(
           -- Decision 119: the studio contact for a guest's "Message the studio".
           'contact_email', s.contact_email,
           'online', exists (select 1 from studio_payment_providers spp
                              where spp.studio_id = s.id and spp.provider = 'xendit'),
           'plans', coalesce((
             select jsonb_agg(jsonb_build_object(
                      'id', mp.id, 'name', mp.name, 'description', mp.description, 'type', mp.type,
                      'credits', mp.credits, 'validity_days', mp.validity_days,
                      'credits_per_period', mp.credits_per_period, 'billing_interval', mp.billing_interval,
                      'featured', mp.featured, 'badge', mp.badge, 'group_size', mp.group_size,
                      'private_pack', coalesce(mp.private_pack, false),
                      'full', coalesce(ss.seat_caps_enabled, false) and mp.max_active_members is not null
                              and plan_seats_taken(mp.id) >= mp.max_active_members,
                      'price', plan_price_now_run(mp.id, now()))
                    order by mp.featured desc, mp.sort_order, mp.name)
               from membership_plans mp
              where mp.studio_id = s.id and mp.status = 'active' and mp.visibility = 'public'
                and mp.type in ('class_pack', 'drop_in', 'trial', 'recurring', 'group')), '[]'::jsonb))
         end
    from studios s
    left join studio_settings ss on ss.studio_id = s.id
   where s.slug = p_slug and s.status = 'active'
$function$;
revoke execute on function studio_by_slug(text, boolean) from public;
grant  execute on function studio_by_slug(text, boolean) to anon, authenticated, service_role;

-- ---- The public surface is unchanged: exactly fifteen anon functions --------
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'expect\_%' and p.proname not in ('call_jsonb');
  if n <> 15 then raise exception 'anon surface is %, expected 15', n; end if;
  if has_table_privilege('anon', 'checkout_rescues', 'select') and not exists (
       select 1 from pg_class where relname = 'checkout_rescues' and relrowsecurity) then
    raise exception 'checkout_rescues is readable by anon without RLS';
  end if;
end $$;
