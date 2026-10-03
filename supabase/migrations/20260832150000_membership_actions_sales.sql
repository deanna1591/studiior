-- =============================================================================
-- Decision 49 — membership actions, a Members plan-overview, and a Sales page.
-- =============================================================================
-- creates:   end_membership(uuid, boolean, text), freeze_membership(uuid, date),
--            unfreeze_membership(uuid), extend_membership(uuid, date, text),
--            mark_membership_paid(uuid, integer, text),
--            refund_membership(uuid, integer, text, boolean),
--            member_plan_overview(uuid),
--            sales_history(uuid, date, date, uuid, text),
--            sales_totals(uuid, date, date, uuid, text)
-- re-issues: notification_wanted(uuid, text),
--            book_class(uuid, uuid, booking_source, text, payment_source)
--
-- The five actions a membership needs (none existed), two read functions behind
-- the Members overview and the Sales page, and a one-line gate in book_class so
-- a frozen membership refuses with its own reason. Every figure is SQL; the
-- Sales total reuses dashboard_revenue's own paid/refunded set so the two can
-- never disagree. A refund is RECORDED here and never pushed to Xendit.
-- =============================================================================

-- --- Templates: the two member emails (End and Freeze). Always-send. ---------
insert into notification_templates (key, subject, text_body, html_body, note) values
('membership_ended', 'Your {plan_name} has ended',
 E'Hi {first_name},\n\nYour {plan_name} at {studio_name} has ended.\n\nAny classes you have already booked are still booked. If this is a surprise, just reply and we''ll sort it out.\n\n{studio_name}',
 E'<p>Hi {first_name},</p><p>Your <strong>{plan_name}</strong> at {studio_name} has ended.</p><p>Any classes you have already booked are still booked. If this is a surprise, just reply and we''ll sort it out.</p>',
 'Decision 49. Sent when staff end a membership. Always-send (account-level).'),
('membership_frozen', 'Your {plan_name} is paused',
 E'Hi {first_name},\n\nYour {plan_name} at {studio_name} is paused until {until}. You won''t be able to book while it''s paused, and your remaining time is held for you — it picks up where it left off.\n\n{studio_name}',
 E'<p>Hi {first_name},</p><p>Your <strong>{plan_name}</strong> at {studio_name} is paused until {until}. You won''t be able to book while it''s paused, and your remaining time is held for you — it picks up where it left off.</p>',
 'Decision 49. Sent when staff freeze a membership. Always-send (account-level).')
on conflict (key) do nothing;

-- --- notification_wanted: the two account emails always send -----------------
-- Re-issued VERBATIM from 20260832120000 with the two keys added to the
-- always-send list; create-or-replace keeps its (service-role-only) ACL.
create or replace function notification_wanted(p_member_id uuid, p_template text)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare p notification_preferences%rowtype;
begin
  if p_template in ('class_cancelled', 'instructor_substituted',
                    'payment_failed', 'staff_message', 'class_moved',
                    'member_invite', 'guest_invite', 'guest_host_cancelled',
                    'guest_waiver_reminder', 'guest_waiver_host_nudge',
                    'flex_booking_confirmed', 'flex_booking_not_confirmed',
                    -- Decision 30 amendment: the free-booking outcome, either way.
                    'free_booking_confirmed', 'free_booking_not_confirmed',
                    -- Decision 49: account-level membership emails.
                    'membership_ended', 'membership_frozen') then
    return true;
  end if;

  select * into p from notification_preferences where member_id = p_member_id;
  if not found then
    return true;
  end if;

  return case p_template
    when 'booking_confirmed' then p.booking_email
    when 'flex_booking_pending' then p.booking_email
    -- Decision 30 amendment: the provisional free receipt is a booking receipt.
    when 'free_booking_pending' then p.booking_email
    when 'class_reminder'    then p.reminder_email
    when 'waitlist_offer'    then p.waitlist_email
    when 'waitlist_missed'   then p.waitlist_email
    when 'credit_expiry'     then p.credit_expiry_email
    when 'milestone'         then p.milestone_email
    when 'challenge_started' then p.challenge_email
    when 'challenge_ending'  then p.challenge_email
    when 'challenge_completed' then p.challenge_email
    else true
  end;
end $$;

-- =============================================================================
-- 1. MEMBERSHIP ACTIONS — manager-up, an audit row and a sentence each.
-- =============================================================================

-- --- End ---------------------------------------------------------------------
create or replace function end_membership(
  p_membership_id uuid, p_keep_credits boolean default false, p_reason text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  ms       memberships%rowtype;
  v_future int;
  v_bal    int;
  v_take   int := 0;
  v_name   text;
begin
  select * into ms from memberships where id = p_membership_id for update;
  if not found then raise exception 'no such membership' using errcode = 'PT404'; end if;
  if not is_manager_up(ms.studio_id) then
    raise exception 'ending a membership is the owner''s or a manager''s to do' using errcode = 'PT403';
  end if;
  if ms.status = 'cancelled' then
    raise exception 'this membership has already ended' using errcode = 'PT409';
  end if;

  -- Classes already booked on this membership stay booked (§3 is a separate
  -- decision); we only count them so the sentence can say so.
  select count(*) into v_future
    from bookings b join class_occurrences o on o.id = b.occurrence_id
   where b.membership_id = p_membership_id
     and b.status in ('booked', 'waitlisted', 'pending_payment')
     and o.starts_at > now();

  -- Credits are forfeited (a reversing ledger row) unless the tick says keep.
  if not coalesce(p_keep_credits, false) and coalesce(ms.credits_remaining, 0) > 0 then
    select coalesce(sum(delta), 0) into v_bal
      from credit_ledger where studio_id = ms.studio_id and member_id = ms.member_id;
    v_take := least(ms.credits_remaining, greatest(v_bal, 0));
    if v_take > 0 then
      insert into credit_ledger (studio_id, member_id, membership_id, delta, reason,
                                 balance_after, actor_user_id)
      values (ms.studio_id, ms.member_id, ms.id, -v_take, 'manual', v_bal - v_take, auth.uid());
    end if;
    update memberships set credits_remaining = coalesce(credits_remaining, 0) - v_take
     where id = ms.id;
  end if;

  update memberships
     set status = 'cancelled', cancelled_at = now(),
         cancellation_reason = coalesce(nullif(btrim(p_reason), ''), 'ended by staff'),
         updated_at = now()
   where id = ms.id;

  insert into membership_events (studio_id, membership_id, type, from_status, to_status,
                                 actor_user_id, metadata)
  values (ms.studio_id, ms.id, 'cancelled', ms.status, 'cancelled', auth.uid(),
          jsonb_build_object('reason', p_reason, 'kept_credits', coalesce(p_keep_credits, false),
                             'credits_forfeited', v_take, 'future_bookings', v_future));

  select name into v_name from membership_plans where id = ms.plan_id;
  perform queue_notification(ms.studio_id, ms.member_id, 'membership_ended',
    jsonb_build_object('plan_name', coalesce(v_name, 'membership')),
    'membership_ended:' || ms.id::text);

  return jsonb_build_object('ok', true, 'sentence',
    'Ended.'
    || case when v_future > 0 then ' ' || v_future || ' future booking'
                                   || case when v_future = 1 then '' else 's' end || ' stay booked.' else '' end
    || case when v_take > 0 then ' ' || v_take || ' credit'
                                 || case when v_take = 1 then '' else 's' end || ' forfeited.'
            when coalesce(p_keep_credits, false) and coalesce(ms.credits_remaining, 0) > 0
                 then ' Credits kept.'
            else '' end);
end $$;

-- --- Freeze ------------------------------------------------------------------
create or replace function freeze_membership(p_membership_id uuid, p_until date)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  ms     memberships%rowtype;
  plan   membership_plans%rowtype;
  v_tz   text; v_today date; v_days int; v_name text;
begin
  select * into ms from memberships where id = p_membership_id for update;
  if not found then raise exception 'no such membership' using errcode = 'PT404'; end if;
  if not is_manager_up(ms.studio_id) then
    raise exception 'pausing a membership is the owner''s or a manager''s to do' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = ms.studio_id;
  v_today := (now() at time zone v_tz)::date;

  if ms.status in ('cancelled', 'expired') then
    raise exception 'this membership has ended — it cannot be paused' using errcode = 'PT409';
  end if;
  if ms.status = 'frozen' then
    raise exception 'this membership is already paused' using errcode = 'PT409';
  end if;
  select * into plan from membership_plans where id = ms.plan_id;
  if not coalesce(plan.freeze_allowed, false) then
    raise exception 'this plan cannot be paused' using errcode = 'PT422';
  end if;
  if p_until is null or p_until <= v_today then
    raise exception 'choose a date in the future to pause until' using errcode = 'PT400';
  end if;
  v_days := p_until - v_today;
  if plan.max_freeze_days is not null
     and coalesce(ms.freeze_days_used, 0) + v_days > plan.max_freeze_days then
    raise exception 'that is more than the % paused days this plan allows (% already used)',
      plan.max_freeze_days, coalesce(ms.freeze_days_used, 0) using errcode = 'PT422';
  end if;

  update memberships
     set status = 'frozen', freeze_start = v_today, freeze_end = p_until, updated_at = now()
   where id = ms.id;

  insert into membership_events (studio_id, membership_id, type, from_status, to_status,
                                 actor_user_id, metadata)
  values (ms.studio_id, ms.id, 'frozen', ms.status, 'frozen', auth.uid(),
          jsonb_build_object('until', p_until, 'days', v_days));

  select name into v_name from membership_plans where id = ms.plan_id;
  perform queue_notification(ms.studio_id, ms.member_id, 'membership_frozen',
    jsonb_build_object('plan_name', coalesce(v_name, 'membership'),
                       'until', to_char(p_until, 'FMDD FMMonth YYYY')),
    'membership_frozen:' || ms.id::text || ':' || p_until::text);

  return jsonb_build_object('ok', true, 'sentence',
    'Paused until ' || to_char(p_until, 'FMDD FMMon YYYY') || '.');
end $$;

-- --- Unfreeze ----------------------------------------------------------------
create or replace function unfreeze_membership(p_membership_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  ms      memberships%rowtype;
  v_tz    text; v_today date; v_days int; v_new_exp date; v_new_renew date;
begin
  select * into ms from memberships where id = p_membership_id for update;
  if not found then raise exception 'no such membership' using errcode = 'PT404'; end if;
  if not is_manager_up(ms.studio_id) then
    raise exception 'unpausing a membership is the owner''s or a manager''s to do' using errcode = 'PT403';
  end if;
  if ms.status <> 'frozen' then
    raise exception 'this membership is not paused' using errcode = 'PT409';
  end if;
  select timezone into v_tz from studios where id = ms.studio_id;
  v_today := (now() at time zone v_tz)::date;

  -- The days actually paused: from the freeze start to today, never past the
  -- date it was due to end. Expiry and renewal move by exactly those days.
  v_days := greatest(0, least(coalesce(ms.freeze_end, v_today), v_today) - coalesce(ms.freeze_start, v_today));
  v_new_exp   := case when ms.expires_on is not null then ms.expires_on + v_days else null end;
  v_new_renew := case when ms.renews_on  is not null then ms.renews_on  + v_days else null end;

  update memberships
     set status = 'active', freeze_start = null, freeze_end = null,
         freeze_days_used = coalesce(freeze_days_used, 0) + v_days,
         expires_on = v_new_exp, renews_on = v_new_renew, updated_at = now()
   where id = ms.id;

  insert into membership_events (studio_id, membership_id, type, from_status, to_status,
                                 actor_user_id, metadata)
  values (ms.studio_id, ms.id, 'unfrozen', 'frozen', 'active', auth.uid(),
          jsonb_build_object('paused_days', v_days, 'new_expires_on', v_new_exp));

  return jsonb_build_object('ok', true, 'sentence',
    'Unpaused.'
    || case when v_days > 0 and v_new_exp is not null
            then ' Expiry moved to ' || to_char(v_new_exp, 'FMDD FMMon YYYY') || '.' else '' end);
end $$;

-- --- Extend ------------------------------------------------------------------
create or replace function extend_membership(
  p_membership_id uuid, p_new_expires_on date, p_reason text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare ms memberships%rowtype;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'a reason is needed to extend' using errcode = 'PT400';
  end if;
  select * into ms from memberships where id = p_membership_id for update;
  if not found then raise exception 'no such membership' using errcode = 'PT404'; end if;
  if not is_manager_up(ms.studio_id) then
    raise exception 'extending a membership is the owner''s or a manager''s to do' using errcode = 'PT403';
  end if;
  if ms.status in ('cancelled', 'expired') then
    raise exception 'this membership has ended — sell a new plan instead' using errcode = 'PT409';
  end if;
  if p_new_expires_on is null then
    raise exception 'choose the new expiry date' using errcode = 'PT400';
  end if;

  update memberships set expires_on = p_new_expires_on, updated_at = now() where id = ms.id;

  insert into membership_events (studio_id, membership_id, type, from_status, to_status,
                                 actor_user_id, metadata)
  values (ms.studio_id, ms.id, 'extended', ms.status, ms.status, auth.uid(),
          jsonb_build_object('old_expires_on', ms.expires_on, 'new_expires_on', p_new_expires_on,
                             'reason', p_reason));

  return jsonb_build_object('ok', true, 'sentence',
    'Expiry moved to ' || to_char(p_new_expires_on, 'FMDD FMMon YYYY') || '.');
end $$;

-- --- Mark paid ---------------------------------------------------------------
create or replace function mark_membership_paid(
  p_membership_id uuid, p_amount_cents int, p_method text default 'cash'
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare ms memberships%rowtype; v_paid int; v_method text;
begin
  select * into ms from memberships where id = p_membership_id for update;
  if not found then raise exception 'no such membership' using errcode = 'PT404'; end if;
  if not is_manager_up(ms.studio_id) then
    raise exception 'recording a payment is the owner''s or a manager''s to do' using errcode = 'PT403';
  end if;
  select count(*) into v_paid from payments
   where membership_id = ms.id and status in ('succeeded', 'partially_refunded');
  if v_paid > 0 then
    raise exception 'this purchase is already paid' using errcode = 'PT409';
  end if;
  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'enter the amount paid' using errcode = 'PT400';
  end if;
  v_method := coalesce(nullif(btrim(p_method), ''), 'cash');
  if v_method not in ('cash', 'bank_transfer', 'card_terminal', 'gcash', 'other') then
    raise exception 'unknown payment method' using errcode = 'PT400';
  end if;

  insert into payments (studio_id, member_id, membership_id, amount_cents, currency, status,
                        description, provider, method, recorded_by, paid_at)
  values (ms.studio_id, ms.member_id, ms.id, p_amount_cents, ms.currency, 'succeeded',
          'Marked paid at desk', 'manual', v_method, auth.uid(), now());

  -- A trial / past-due purchase becomes active once paid; a frozen one stays
  -- paused, an active one stays active.
  update memberships
     set status = case when status in ('trialing', 'past_due') then 'active'::membership_status
                       else status end,
         updated_at = now()
   where id = ms.id;

  insert into membership_events (studio_id, membership_id, type, from_status, to_status,
                                 actor_user_id, metadata)
  values (ms.studio_id, ms.id, 'payment', ms.status,
          case when ms.status in ('trialing', 'past_due') then 'active'::membership_status else ms.status end,
          auth.uid(),
          jsonb_build_object('amount_cents', p_amount_cents, 'method', v_method));

  return jsonb_build_object('ok', true, 'sentence', 'Marked paid.');
end $$;

-- --- Refund (recorded here, NEVER pushed to Xendit) --------------------------
-- The decision names this record_refund(p_membership_id, …, p_end). It is built
-- as refund_membership rather than overloading the existing payment-keyed
-- record_refund(uuid, int, text) — two record_refunds differing only by a
-- trailing boolean is the 028 overload footgun — and DELEGATES to that
-- function so Sales and the dashboard share one refund definition.
create or replace function refund_membership(
  p_membership_id uuid, p_amount_cents int default null,
  p_reason text default null, p_end boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare ms memberships%rowtype; v_pay uuid;
begin
  select * into ms from memberships where id = p_membership_id for update;
  if not found then raise exception 'no such membership' using errcode = 'PT404'; end if;
  if not is_manager_up(ms.studio_id) then
    raise exception 'refunds are the owner''s or a manager''s to make' using errcode = 'PT403';
  end if;

  -- The membership's originating payment — the most recent one still carrying a
  -- refundable balance.
  select id into v_pay from payments
   where membership_id = ms.id and status in ('succeeded', 'partially_refunded')
   order by coalesce(paid_at, created_at) desc
   limit 1;
  if v_pay is null then
    raise exception 'nothing has been paid on this to refund' using errcode = 'PT409';
  end if;

  -- One refund implementation. record_refund handles partial/full, forfeits
  -- credits and cancels the membership on a full refund, and audits.
  perform record_refund(v_pay, p_amount_cents, p_reason);

  -- A partial refund that should also end the membership.
  if coalesce(p_end, false) then
    update memberships
       set status = 'cancelled', cancelled_at = now(),
           cancellation_reason = coalesce(nullif(btrim(p_reason), ''), 'refunded'),
           updated_at = now()
     where id = ms.id and status <> 'cancelled';
    if found then
      insert into membership_events (studio_id, membership_id, type, from_status, to_status,
                                     actor_user_id, metadata)
      values (ms.studio_id, ms.id, 'cancelled', ms.status, 'cancelled', auth.uid(),
              jsonb_build_object('reason', p_reason, 'via', 'refund'));
    end if;
  end if;

  return jsonb_build_object('ok', true, 'sentence',
    'Recorded. Refund the money in Xendit if it was paid there.');
end $$;

-- =============================================================================
-- 2. READ FUNCTIONS
-- =============================================================================

-- --- member_plan_overview: the Members list, with plan state. No amounts. ----
-- Desk-up callable (front desk sees the filters, never Sales money).
create or replace function member_plan_overview(p_studio_id uuid)
returns table (
  id uuid, first_name text, last_name text, email text, status text,
  lifetime_visits int, last_visit_at timestamptz,
  health_band text, health_reason text, user_id uuid,
  membership_id uuid, current_plan_name text, plan_type text,
  membership_status text, expires_on date, credits_remaining int,
  had_free_class boolean, has_ever_paid boolean, plan_state text
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare v_tz text; v_today date;
begin
  if not (is_desk_up(p_studio_id) or is_service_context()) then
    raise exception 'that is another studio''s members' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios s where s.id = p_studio_id;
  v_today := (now() at time zone v_tz)::date;

  return query
  with mem as (
    select m.id, m.first_name, m.last_name, m.email, m.status::text as status,
           m.lifetime_visits, m.last_visit_at,
           m.health_band::text as health_band, m.health_reason, m.user_id
      from members m
     where m.studio_id = p_studio_id and m.status <> 'archived'
  ),
  -- The one membership to show per member: a usable (non-ended) one, the one
  -- with the furthest reach first.
  live as (
    select distinct on (ms.member_id)
           ms.member_id, ms.id as membership_id, ms.status as ms_status,
           ms.expires_on, ms.credits_remaining, mp.name as plan_name, mp.type as plan_type,
           -- usable right now?
           (ms.status in ('active','trialing','past_due','frozen')
            and (mp.type = 'recurring'
                 or coalesce(ms.credits_remaining,0) > 0)
            and (ms.expires_on is null or ms.expires_on >= v_today)) as usable
      from memberships ms
      join membership_plans mp on mp.id = ms.plan_id
     where ms.studio_id = p_studio_id and ms.status <> 'cancelled'
     order by ms.member_id,
              (ms.status in ('active','trialing','past_due','frozen')) desc,
              ms.expires_on desc nulls first, ms.created_at desc
  ),
  paid as (
    select distinct member_id from payments
     where studio_id = p_studio_id and status in ('succeeded','partially_refunded')
  ),
  freebie as (
    select distinct guest_member_id as member_id from guest_passes
     where studio_id = p_studio_id
  )
  select mem.id, mem.first_name, mem.last_name, mem.email, mem.status,
         mem.lifetime_visits, mem.last_visit_at, mem.health_band, mem.health_reason, mem.user_id,
         live.membership_id, live.plan_name, live.plan_type::text,
         live.ms_status::text, live.expires_on, live.credits_remaining,
         (freebie.member_id is not null) as had_free_class,
         (paid.member_id is not null) as has_ever_paid,
         case
           when coalesce(live.usable, false) then
             case when live.expires_on is not null
                       and live.expires_on <= v_today + 14 then 'expiring' else 'on_plan' end
           when paid.member_id is not null then 'expired'
           when freebie.member_id is not null then 'free_only'
           else 'none'
         end as plan_state
    from mem
    left join live    on live.member_id = mem.id
    left join paid    on paid.member_id = mem.id
    left join freebie on freebie.member_id = mem.id;
end $$;

-- --- sales_history: every plan purchase, newest first. Manager-up. -----------
create or replace function sales_history(
  p_studio_id uuid, p_from date, p_to date,
  p_plan_id uuid default null, p_status text default null
) returns table (
  membership_id uuid, member_id uuid, member_name text,
  plan_id uuid, plan_name text, plan_type text,
  amount_cents int, currency char(3), payment_source text,
  bought_on timestamptz, starts_on date, expires_on date, sale_status text
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare v_tz text; v_today date; v_f0 timestamptz; v_t1 timestamptz;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'sales are for owners and managers' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios s where s.id = p_studio_id;
  v_today := (now() at time zone v_tz)::date;
  select day_start into v_f0 from studio_day_bounds(p_studio_id, p_from);
  select day_start into v_t1 from studio_day_bounds(p_studio_id, p_to + 1);

  return query
  with pay as (
    -- The originating payment per membership (most recent refundable one).
    select distinct on (p.membership_id)
           p.membership_id, p.amount_cents, p.currency, p.provider, p.method, p.status as pstatus,
           coalesce(p.paid_at, p.created_at) as paid_ts
      from payments p
     where p.studio_id = p_studio_id and p.membership_id is not null
     order by p.membership_id, coalesce(p.paid_at, p.created_at) desc
  )
  select ms.id, ms.member_id,
         (m.first_name || ' ' || m.last_name) as member_name,
         ms.plan_id, mp.name, mp.type::text,
         coalesce(pay.amount_cents, ms.price_cents) as amount_cents,
         ms.currency,
         coalesce(
           case when pay.provider = 'stripe' then 'Card (Stripe)'
                when pay.method = 'gcash' then 'GCash'
                when pay.method = 'bank_transfer' then 'Bank transfer'
                when pay.method = 'card_terminal' then 'Card (terminal)'
                when pay.method = 'cash' then 'Cash'
                when pay.method = 'other' then 'Other'
                when pay.membership_id is not null then 'Recorded'
           end, 'Unpaid') as payment_source,
         coalesce(pay.paid_ts, ms.created_at) as bought_on,
         ms.starts_on, ms.expires_on,
         (case
            when pay.pstatus = 'refunded' then 'refunded'
            when ms.status = 'frozen' then 'frozen'
            when pay.membership_id is null or pay.pstatus = 'pending' then 'unpaid'
            when ms.status in ('cancelled', 'expired') then 'expired'
            when ms.expires_on is not null and ms.expires_on <= v_today + 14 then 'expiring'
            else 'active'
          end) as sale_status
    from memberships ms
    join members m on m.id = ms.member_id
    join membership_plans mp on mp.id = ms.plan_id
    left join pay on pay.membership_id = ms.id
   where ms.studio_id = p_studio_id
     and coalesce(pay.paid_ts, ms.created_at) >= v_f0
     and coalesce(pay.paid_ts, ms.created_at) <  v_t1
     and (p_plan_id is null or ms.plan_id = p_plan_id)
     and (p_status  is null or p_status = (case
            when pay.pstatus = 'refunded' then 'refunded'
            when ms.status = 'frozen' then 'frozen'
            when pay.membership_id is null or pay.pstatus = 'pending' then 'unpaid'
            when ms.status in ('cancelled', 'expired') then 'expired'
            when ms.expires_on is not null and ms.expires_on <= v_today + 14 then 'expiring'
            else 'active' end))
   order by coalesce(pay.paid_ts, ms.created_at) desc;
end $$;

-- --- sales_totals: the filtered set's totals. Reuses the revenue definition. -
create or replace function sales_totals(
  p_studio_id uuid, p_from date, p_to date,
  p_plan_id uuid default null, p_status text default null
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_currency char(3); v_count int; v_gross bigint; v_refunded bigint; v_studio_total bigint;
  v_f0 timestamptz; v_t1 timestamptz;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'sales are for owners and managers' using errcode = 'PT403';
  end if;
  select currency into v_currency from studios s where s.id = p_studio_id;
  select day_start into v_f0 from studio_day_bounds(p_studio_id, p_from);
  select day_start into v_t1 from studio_day_bounds(p_studio_id, p_to + 1);

  -- Count of purchases in the filtered set (every row sales_history returns).
  select count(*) into v_count
    from sales_history(p_studio_id, p_from, p_to, p_plan_id, p_status);

  -- Paid money (gross) and refunded money for the filtered set, over the SAME
  -- status set dashboard_revenue uses.
  select coalesce(sum(p.amount_cents), 0)::bigint,
         coalesce(sum(p.refunded_cents), 0)::bigint
    into v_gross, v_refunded
    from payments p
    join memberships ms on ms.id = p.membership_id
   where p.studio_id = p_studio_id
     and p.status in ('succeeded', 'partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1
     and (p_plan_id is null or ms.plan_id = p_plan_id);

  -- The whole studio's revenue over the window — the dashboard's own figure, so
  -- a caller can confirm the unfiltered Sales total agrees with the dashboard.
  v_studio_total := studio_revenue_between(p_studio_id, v_f0, v_t1);

  return jsonb_build_object(
    'count', v_count,
    'gross_cents', v_gross,
    'refunded_cents', v_refunded,
    'net_cents', v_gross - v_refunded,
    'studio_total_cents', v_studio_total,
    'currency', v_currency);
end $$;

-- =============================================================================
-- Grants. The actions and sales readers are authenticated-callable and guard
-- inside; member_plan_overview is desk-up; none is anon.
-- =============================================================================
revoke all on function end_membership(uuid, boolean, text) from public, anon;
revoke all on function freeze_membership(uuid, date) from public, anon;
revoke all on function unfreeze_membership(uuid) from public, anon;
revoke all on function extend_membership(uuid, date, text) from public, anon;
revoke all on function mark_membership_paid(uuid, integer, text) from public, anon;
revoke all on function refund_membership(uuid, integer, text, boolean) from public, anon;
revoke all on function member_plan_overview(uuid) from public, anon;
revoke all on function sales_history(uuid, date, date, uuid, text) from public, anon;
revoke all on function sales_totals(uuid, date, date, uuid, text) from public, anon;

grant execute on function end_membership(uuid, boolean, text) to authenticated, service_role;
grant execute on function freeze_membership(uuid, date) to authenticated, service_role;
grant execute on function unfreeze_membership(uuid) to authenticated, service_role;
grant execute on function extend_membership(uuid, date, text) to authenticated, service_role;
grant execute on function mark_membership_paid(uuid, integer, text) to authenticated, service_role;
grant execute on function refund_membership(uuid, integer, text, boolean) to authenticated, service_role;
grant execute on function member_plan_overview(uuid) to authenticated, service_role;
grant execute on function sales_history(uuid, date, date, uuid, text) to authenticated, service_role;
grant execute on function sales_totals(uuid, date, date, uuid, text) to authenticated, service_role;

-- --- book_class re-issue: the membership_frozen gate (Decision 49) -----------
CREATE OR REPLACE FUNCTION public.book_class(p_occurrence_id uuid, p_member_id uuid, p_source booking_source, p_override_reason text DEFAULT NULL::text, p_payment_source payment_source DEFAULT NULL::payment_source)
 RETURNS book_class_result
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_result       book_class_result;
  v_occ          class_occurrences%rowtype;
  v_member       members%rowtype;
  v_set          studio_settings%rowtype;
  v_tz           text;

  v_actor        uuid := auth.uid();
  v_caller_role  text;
  v_trusted      boolean;
  v_is_desk      boolean;
  v_is_self      boolean;
  v_override     boolean := false;
  v_bypassed     text[] := '{}';
  v_comp         boolean := false;
  -- 'booked' unless the member is paying for a drop-in themselves, in which
  -- case the seat is held as 'pending_payment' until Stripe says otherwise.
  v_status       booking_status := 'booked';

  v_window_days  int;
  v_max_per_day  int;
  v_day_count    int;
  v_future_count int;
  v_today        date;

  v_cand         record;
  v_covers       boolean;
  v_restricted   boolean := false;   -- a live plan was blocked purely on class type
  v_peak         jsonb;             -- Decision 24: the paying plan's peak allowance, or null
  v_susp         jsonb;             -- Decision 24: where this member stands on the ladder
  v_pay          payment_source;
  v_membership   uuid;
  v_consume      boolean := false;

  v_booking_id   uuid;
  v_ledger_id    uuid;
  v_balance      int;
  v_position     int;
  v_full         boolean;
  v_phys_full    boolean;   -- capacity reached by REAL seats
  v_held         int;       -- §4.2: seats a live waitlist offer is holding for someone else
begin
  -- ===========================================================================
  -- 0. Locate and authorise. Nothing is written before this passes.
  -- ===========================================================================

  select * into v_occ from class_occurrences where id = p_occurrence_id;
  if not found then
    return (null, null, null, null, 'not_found')::book_class_result;
  end if;

  -- Lockout (migration 044). The studio's own subscription to Studiior has
  -- lapsed past its grace period. Reads stay open everywhere so nothing looks
  -- lost; this is one of the four places where DOING something stops.
  if studio_is_locked(v_occ.studio_id) then
    raise exception 'this studio''s Studiior subscription is not active'
      using errcode = 'PT402',
            hint = 'Reactivate it from Billing. Nothing has been deleted.';
  end if;

  select * into v_member from members where id = p_member_id;
  if not found then
    return (null, null, null, null, 'member_not_found')::book_class_result;
  end if;
  if v_member.studio_id <> v_occ.studio_id then
    return (null, null, null, null, 'member_wrong_studio')::book_class_result;
  end if;

  select * into v_set from studio_settings where studio_id = v_occ.studio_id;
  select timezone into v_tz from studios where id = v_occ.studio_id;

  -- --- Trust is a property of the ROLE, never of a missing auth.uid() -------
  --
  -- A null auth.uid() proves nothing: an `authenticated` caller whose JWT
  -- carries no `sub` claim has one too, and migration 002 handed that caller
  -- full booking rights over every member in the studio.
  --
  -- current_user is useless here — inside a security definer function it is
  -- always the function owner, not the caller. The caller's effective role is
  -- the `role` GUC, which is what PostgREST sets per request and what SET ROLE
  -- sets in a direct session; it is NOT changed by security definer entry.
  -- 'none' means no SET ROLE happened at all, i.e. a direct login session.
  --
  -- rolbypassrls is the honest test of "already privileged above RLS":
  -- service_role, postgres and supabase_admin have it, and gain nothing from
  -- this function that they could not do by writing the tables directly.
  -- authenticated, anon and authenticator do not have it.
  v_caller_role := coalesce(nullif(current_setting('role', true), 'none'),
                            session_user);
  v_trusted := exists (
    select 1 from pg_roles
     where rolname = v_caller_role
       and (rolsuper or rolbypassrls)
  );

  v_is_desk := coalesce(is_desk_up(v_occ.studio_id), false);
  v_is_self := v_actor is not null
               and v_member.user_id is not null
               and v_member.user_id = v_actor;

  if not (v_trusted or v_is_desk or v_is_self) then
    return (null, null, null, null, 'not_authorised')::book_class_result;
  end if;
  -- A member may only book as themselves, and never on a staff source.
  if not (v_trusted or v_is_desk) and p_source <> 'member' then
    return (null, null, null, null, 'not_authorised')::book_class_result;
  end if;

  -- --- §2.4 comp -----------------------------------------------------------
  -- payment_source is otherwise resolved, never chosen (§2.2). 'comp' is the
  -- single exception the business rules allow, and it is staff-only.
  if p_payment_source is not null then
    if p_payment_source <> 'comp' then
      return (null, null, null, null, 'unsupported_payment_source')
             ::book_class_result;
    end if;
    if not (v_trusted or v_is_desk) then
      return (null, null, null, null, 'not_authorised')::book_class_result;
    end if;
    v_comp := true;
  end if;

  -- Business Rules §2.3: overrides are front desk and above only, and always
  -- carry a reason. Rules 1 (past/cancelled), 4 (waiver) and 6 (duplicate)
  -- stay unoverridable below.
  v_override := p_override_reason is not null
                and btrim(p_override_reason) <> ''
                and (v_trusted or v_is_desk);

  -- ===========================================================================
  -- 1. THE LOCK. Data Model §6 — before anything reads booked_count.
  -- ===========================================================================

  select * into v_occ
    from class_occurrences
   where id = p_occurrence_id
     for update;

  -- Then the member row, which serialises this member's own concurrent
  -- bookings so credits_remaining and credit_ledger.balance_after stay
  -- consistent. Lock order is always occurrence -> member; the nightly expiry
  -- job and the Stripe webhook handlers must take the member lock the same way.
  select * into v_member from members where id = p_member_id for update;

  v_today := (now() at time zone v_tz)::date;

  -- ===========================================================================
  -- 2. Eligibility gate — Business Rules §2.1, in order. First failure wins.
  -- ===========================================================================

  -- 2.1.1 Occurrence is scheduled, not cancelled, not in the past. Not overridable.
  if v_occ.status = 'cancelled' then
    return (null, null, null, null, 'class_cancelled')::book_class_result;
  end if;
  if v_occ.status = 'completed' then
    return (null, null, null, null, 'class_completed')::book_class_result;
  end if;
  if v_occ.starts_at <= now() then
    return (null, null, null, null, 'class_in_past')::book_class_result;
  end if;

  -- 2.1.1b Decision 25: the class is on a PUBLISHED month. Placed with the
  -- occurrence checks and BEFORE the booking window, deliberately: an
  -- unpublished class is invisible to members under occ_member_read, so a
  -- member can only reach here with an id they cannot see, and the refusal
  -- names the reason the class is invisible rather than a rule about how far
  -- ahead their plan lets them book. That keeps the two gates composed the
  -- same way on this side as on the screen: "not published" is about the
  -- class, "outside the window" is about the member, and outside_booking_window
  -- goes on meaning exactly what it has since migration 002 — a class on the
  -- timetable that this member may not book YET. month_published() is true for
  -- every studio with the switch off, so nothing changes for them.
  -- Overridable with a reason, like the window: the desk pencilling somebody
  -- into a draft is a deliberate act and is recorded as one.
  if not month_published(v_occ.studio_id, v_occ.starts_at) then
    if v_override then
      v_bypassed := v_bypassed || 'month_not_published'::text;
    else
      return (null, null, null, null, 'month_not_published')::book_class_result;
    end if;
  end if;

  -- 2.1.1c Decision 48: a studio may keep an unstaffed class off the member side
  -- until an instructor is on it. The staffing arm of occurrence_member_visible
  -- (the published/scheduled arms are the checks just above): with the switch on
  -- and the class not assigned, it is closed to NEW bookings. A member who
  -- ALREADY holds a non-cancelled booking is unaffected — they keep their seat
  -- and the class stays visible to them (occ_member_own_read). Hard refusal: a
  -- class nobody is teaching is not something even the desk books into.
  if studio_hides_unstaffed(v_occ.studio_id)
     and v_occ.staffing <> 'assigned'
     and not exists (select 1 from bookings b
                      where b.occurrence_id = p_occurrence_id and b.member_id = p_member_id
                        and b.status <> 'cancelled') then
    return (null, null, null, null, 'not_staffed_yet')::book_class_result;
  end if;

  -- Plan-level overrides for rules 2 and 7 come from the member's highest
  -- priority usable plan (§2.1.2 "plan-level override wins over studio
  -- default"). Read before the gate; the paying source is resolved in §3.
  -- The WINDOW is resolved through member_booking_window_days() — the single
  -- definition of §2.1.2 the member app reads too, so the "Opens for booking"
  -- screen and this rule can never disagree (Decision 36). The daily cap keeps
  -- its own read of the SAME row (identical selection) so behaviour is unchanged.
  v_window_days := member_booking_window_days(p_member_id);
  select mp.max_bookings_per_day
    into v_max_per_day
    from memberships ms
    join membership_plans mp on mp.id = ms.plan_id
   where ms.member_id  = p_member_id
     and ms.studio_id  = v_occ.studio_id
     and ms.status in ('active','trialing')
     and (ms.expires_on is null or ms.expires_on >= v_today)
     and (mp.booking_window_days is not null or mp.max_bookings_per_day is not null)
   order by case mp.type when 'recurring' then 1 when 'trial' then 2 else 3 end,
            ms.expires_on asc nulls last
   limit 1;

  v_max_per_day := coalesce(v_max_per_day, v_set.max_bookings_per_day);

  -- 2.1.2 Booking window.
  if not v_override then
    if v_occ.starts_at > now() + make_interval(days => v_window_days) then
      return (null, null, null, null, 'outside_booking_window')::book_class_result;
    end if;
  elsif v_occ.starts_at > now() + make_interval(days => v_window_days) then
    v_bypassed := v_bypassed || 'booking_window'::text;
  end if;

  -- 2.1.3 Booking cutoff. Default 0 — booking allowed right up to start.
  if not v_override then
    if v_occ.starts_at < now() + make_interval(mins => v_set.booking_cutoff_minutes) then
      return (null, null, null, null, 'past_booking_cutoff')::book_class_result;
    end if;
  elsif v_occ.starts_at < now() + make_interval(mins => v_set.booking_cutoff_minutes) then
    v_bypassed := v_bypassed || 'booking_cutoff'::text;
  end if;

  -- 2.1.3b Decision 30 belt: a self-serve LEAD owed a free first class must
  -- spend it on the free path (book_first_free), not a paid drop-in. Gated on
  -- status = 'lead' — Decision 15's self-signup with no plan; an active member
  -- (including one bringing a guest through book_guest, which books their own
  -- seat here) is never a lead and books normally. Fires only when they book
  -- themselves (not desk/override) and are still eligible, and before the waiver
  -- gate, so a fresh unsigned lead is routed to the free path (which gates the
  -- waiver at check-in) rather than told to sign. The switch off makes
  -- free_first_eligibility return ok=false, so nothing here fires.
  if v_is_self and not (v_is_desk or v_trusted or v_override)
     and v_member.status = 'lead'
     and (free_first_eligibility(v_occ.studio_id, v_member.id) ->> 'ok')::boolean then
    return (null, null, null, null, 'use_free_first')::book_class_result;
  end if;

  -- 2.1.4 Waiver. Not overridable. Decision 34: a signature is tied to a waiver
  -- version, and a NEW version marked requires_resign turns an older signature
  -- stale — a member who signed only an earlier required version is treated as
  -- unsigned. A studio with no version yet is unaffected (the current-version
  -- subquery finds nothing), so existing bare-timestamp signatures stand.
  if v_set.require_waiver then
    if v_member.waiver_signed_at is null then
      -- Part B: require_waiver is on but the studio has published NO version, so
      -- there is nothing to sign in the app. A distinct reason, so the member is
      -- pointed at the studio rather than told to "please sign" a screen with
      -- nothing on it. The desk paper path can still sign them.
      if not exists (select 1 from waiver_versions where studio_id = v_occ.studio_id) then
        return (null, null, null, null, 'waiver_unavailable')::book_class_result;
      end if;
      return (null, null, null, null, 'waiver_not_signed')::book_class_result;
    end if;
    if exists (
      select 1 from waiver_versions wv
       where wv.studio_id = v_occ.studio_id
         and wv.requires_resign
         and wv.created_at = (select max(created_at) from waiver_versions
                               where studio_id = v_occ.studio_id)
         and not exists (select 1 from waiver_signatures ws
                          where ws.member_id = v_member.id and ws.version_id = wv.id))
    then
      return (null, null, null, null, 'waiver_not_signed')::book_class_result;
    end if;
  end if;

  -- 2.1.5 Member status — Decision 15. A `lead` passes here, and is held to
  -- drop-in by the guard after §2.2 resolution below.
  if not book_class_status_ok(v_member.status) then
    return (null, null, null, null, 'member_not_active')::book_class_result;
  end if;

  -- 2.1.6 No existing live booking for this occurrence. Not overridable.
  -- Mirrors the bookings_one_live_per_member partial unique index.
  if exists (
    select 1 from bookings
     where occurrence_id = p_occurrence_id
       and member_id     = p_member_id
       and status in ('booked','waitlisted','attended','no_show','pending_payment')
  ) then
    -- 'pending_payment' is in this list, and deliberately NOT in the daily or
    -- forward limit counts below: a member may not start two checkouts for the
    -- same class, but three abandoned checkouts must not exhaust the limits on
    -- classes they never paid for.
    return (null, null, null, null, 'already_booked')::book_class_result;
  end if;

  -- 2.1.7 Daily limit, counted in studio-local days.
  if v_max_per_day is not null then
    select count(*) into v_day_count
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
     where b.member_id = p_member_id
       and b.studio_id = v_occ.studio_id
       and b.status in ('booked','waitlisted','attended','no_show')
       and (o.starts_at at time zone v_tz)::date
         = (v_occ.starts_at at time zone v_tz)::date;

    if v_day_count >= v_max_per_day then
      if v_override then
        v_bypassed := v_bypassed || 'daily_limit'::text;
      else
        return (null, null, null, null, 'daily_limit_reached')::book_class_result;
      end if;
    end if;
  end if;

  -- 2.1.8 Forward limit on live future bookings.
  if v_set.max_future_bookings is not null then
    select count(*) into v_future_count
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
     where b.member_id = p_member_id
       and b.studio_id = v_occ.studio_id
       and b.status in ('booked','waitlisted')
       and o.starts_at > now();

    if v_future_count >= v_set.max_future_bookings then
      if v_override then
        v_bypassed := v_bypassed || 'future_limit'::text;
      else
        return (null, null, null, null, 'future_limit_reached')::book_class_result;
      end if;
    end if;
  end if;

  -- ===========================================================================
  -- 3. Payment source resolution — Business Rules §2.2, Decision 1.
  --    unlimited membership -> limited membership allowance -> pack credits
  --    soonest expiry first -> drop-in. The member never chooses.
  --    Consumed at booking time, not at attendance (§2.2, §6).
  -- ===========================================================================

  if v_comp then
    -- §2.4: nothing consumed, nothing charged. The booking is an ordinary
    -- 'booked' row, so check-in, challenges and milestones count it exactly
    -- like any other attendance. Rule 2.1.9 is vacuous — no membership is
    -- paying, so no membership's class-type restriction applies.
    v_pay     := 'comp';
    v_consume := false;
  else
    for v_cand in
      select ms.id,
             ms.credits_remaining,
             mp.restrictions,
             case
               -- credits_per_period null on a recurring plan == unlimited
               -- (Data Model §7).
               when mp.type = 'recurring'
                    and mp.credits_per_period is null
                    and ms.credits_remaining is null              then 1
               when mp.type = 'recurring'
                    and coalesce(ms.credits_remaining, 0) > 0     then 2
               when mp.type in ('class_pack','drop_in','trial')
                    and coalesce(ms.credits_remaining, 0) > 0     then 3
               else 99
             end as priority
        from memberships ms
        join membership_plans mp on mp.id = ms.plan_id
       where ms.member_id = p_member_id
         and ms.studio_id = v_occ.studio_id
         -- §7.3 / Decision 4: past_due blocks NEW bookings only once the
         -- studio's grace period has run out.
         and (
               ms.status in ('active','trialing')
            or (ms.status = 'past_due'
                and now() < coalesce(ms.current_period_end, now())
                            + make_interval(days => v_set.payment_grace_days))
         )
         -- §7.4: a frozen membership cannot book.
         and not (ms.freeze_start is not null and ms.freeze_end is not null
                  and v_today between ms.freeze_start and ms.freeze_end)
         -- §6: a credit cannot be spent past its expiry.
         and (ms.expires_on is null or ms.expires_on >= v_today)
       order by priority,
                ms.expires_on asc nulls last,   -- soonest expiry first
                ms.created_at asc
    loop
      exit when v_cand.priority = 99;

      -- §2.1.9 plan restrictions: an empty or absent class_type_ids covers
      -- everything.
      v_covers := (v_cand.restrictions -> 'class_type_ids') is null
               or jsonb_typeof(v_cand.restrictions -> 'class_type_ids') <> 'array'
               or jsonb_array_length(v_cand.restrictions -> 'class_type_ids') = 0
               or (v_occ.class_type_id is not null
                   and jsonb_exists(v_cand.restrictions -> 'class_type_ids',
                                    v_occ.class_type_id::text));

      if not v_covers then
        v_restricted := true;   -- remembered for the §2.1.9 failure below
        continue;
      end if;

      v_pay        := case when v_cand.priority in (1, 2)
                           then 'membership'::payment_source
                           else 'class_pack'::payment_source end;
      v_membership := v_cand.id;
      v_consume    := v_cand.priority in (2, 3);
      exit;
    end loop;

    if v_pay is null then
      -- §2.1.9: the member holds a live plan and it does not cover this class
      -- type. That is a specific refusal, not a silent fall-through to drop-in.
      if v_restricted then
        if v_override then
          v_bypassed := v_bypassed || 'plan_restriction'::text;
        else
          return (null, null, null, null, 'class_type_not_in_plan')::book_class_result;
        end if;
      end if;
      -- §2.2 priority 4: nothing covers it, so the class is a drop-in. The
      -- charge itself is a payments row raised by the caller against the
      -- returned booking; no credit is consumed here.
      -- Decision 49: the plan they would book on is frozen. Rather than
      -- silently charge a drop-in, refuse with its own reason (the member app
      -- says "paused until {date}"). A usable non-frozen pack was already
      -- resolved above, so this only fires when a frozen membership is the
      -- only plan they have.
      if exists (
        select 1 from memberships ms2
         where ms2.member_id = p_member_id and ms2.studio_id = v_occ.studio_id
           and ms2.freeze_start is not null and ms2.freeze_end is not null
           and v_today between ms2.freeze_start and ms2.freeze_end
      ) then
        return (null, null, null, null, 'membership_frozen')::book_class_result;
      end if;
      v_pay := 'drop_in';
    end if;
  end if;

  -- The seat is held while the member pays for it.
  --
  -- Only when the MEMBER is booking their own drop-in and the studio has a
  -- connected Stripe account. A staff booking at the desk is money changing
  -- hands in the room, and a studio with no Stripe connected has no checkout to
  -- send anyone to — both of those still book outright, exactly as before, which
  -- is also why every existing fixture in the suite is unaffected.
  if v_pay = 'drop_in' and p_source = 'member'
     and exists (
       select 1 from studios s
        where s.id = v_occ.studio_id and s.stripe_account_id is not null
     )
  then
    v_status := 'pending_payment';
  end if;

  -- Decision 15's second half, after §2.2 has resolved who pays. A lead has
  -- bought nothing, so it should always be drop-in by this point; if it is
  -- not, staff have attached a plan to somebody they never activated, and
  -- spending its credits is not what `lead` is meant to allow.
  if v_member.status = 'lead' and v_pay <> 'drop_in' then
    return (null, null, null, null, 'member_not_active')::book_class_result;
  end if;

  -- ===========================================================================
  -- 2.1.9 SUSPENSION — Decision 24.
  --
  -- In the §2.1 gate and not beside the peak rule, because it has nothing to do
  -- with which plan pays: a suspended member is suspended whatever they were
  -- going to book it with, including a drop-in they would have paid cash for.
  --
  -- IT RESTRICTS ADVANCE BOOKING ONLY. Same-day still works, on whatever seats
  -- are left — the penalty is losing the ability to hold a place ahead of
  -- everyone else, not being shut out of the studio. A suspension that stopped
  -- somebody walking in would cost the studio the sale as well as the member the
  -- class, and it would be a harsher thing than any studio described wanting.
  --
  -- The allowance still applies on top: a suspension does not hand out free peak
  -- slots, and a member with nothing left is refused by the rule below whether
  -- or not they are suspended.
  --
  -- Overridable, like the other capacity-shaped rules. A studio that wants to
  -- let somebody in anyway has heard the reason at the counter.
  -- ===========================================================================
  v_susp := member_suspension(p_member_id);
  if v_susp is not null and (v_susp ->> 'suspended')::boolean
     and (v_occ.starts_at at time zone v_tz)::date > v_today
  then
    if v_override then
      v_bypassed := v_bypassed || 'suspended'::text;
    else
      return (null, null, null, null, 'suspended')::book_class_result;
    end if;
  end if;

  -- ===========================================================================
  -- 3b. THE PEAK ALLOWANCE — Decision 24.
  --
  -- AFTER §2.2, and that placement is the whole correctness argument: the plan
  -- that PAYS is the plan held to its allowance. Resolving it up in the §2.1
  -- gate would mean a second plan-priority query beside the one rules 2 and 7
  -- use, and the two would pick the same plan right up until they did not —
  -- a member holding both an unlimited plan and a pack would have the pack's
  -- booking measured against the unlimited plan's allowance.
  --
  -- Only a membership can consume one. A drop-in and a pack cannot carry an
  -- allowance at all (migration 104's CHECK), so `v_pay = 'membership'` is not
  -- an optimisation, it is the rule.
  --
  -- peak_allowance_state() answers null for a plan with no allowance AND for a
  -- studio with the switch off, so a studio that has never heard of this
  -- feature takes one null check and nothing else.
  --
  -- WAITLISTING NEEDS NO SPECIAL CASE. This refuses before §4, so a member with
  -- nothing left cannot join the queue for a peak class either — which is the
  -- honest answer, rather than letting them wait for an offer they could not
  -- accept. And nothing is CONSUMED here: the ledger row is written by the
  -- trigger when a seat actually becomes real, so a waitlisted row costs
  -- nothing and a promotion costs one. `respond_to_offer()` cancels the
  -- waitlist row and calls this function again, so a promotion is measured
  -- against the allowance as it stands at that moment, not at join time.
  -- ===========================================================================
  if v_pay = 'membership' and v_membership is not null
     and occurrence_is_peak(p_occurrence_id)
  then
    v_peak := peak_allowance_state(v_membership,
                                   (v_occ.starts_at at time zone v_tz)::date);
    if v_peak is not null and (v_peak ->> 'remaining')::int <= 0 then
      if v_override then
        v_bypassed := v_bypassed || 'peak_allowance'::text;
      else
        return (null, null, null, null, 'peak_allowance_exhausted')::book_class_result;
      end if;
    end if;
  end if;

  -- ===========================================================================
  -- 4. Capacity — §2.1.10, §4.1, §5. booked_count was read under the lock.
  -- ===========================================================================

  -- §4.2: a pending waitlist offer HOLDS its seat — the offered member was
  -- formally offered it, and general booking must not take it from under them.
  -- Derived from live offers at gate time rather than cached: booked_count goes
  -- on counting real seats only, so the nightly reconcile stays a no-op, and the
  -- hold ends the instant the offer does (expired-but-unswept offers hold
  -- nothing — occurrence_seats_held gates on expires_at > now()). The offered
  -- member's own offer is excluded, or accepting through respond_to_offer would
  -- be refused for the very seat they were offered.
  v_held      := occurrence_seats_held(p_occurrence_id, p_member_id);
  v_phys_full := v_occ.booked_count >= v_occ.capacity;
  v_full      := (v_occ.booked_count + v_held) >= v_occ.capacity;

  if v_full and not v_override then
    if not v_set.waitlist_enabled then
      return (null, null, null, null, 'class_full')::book_class_result;
    end if;

    -- §4.4: no promotions inside waitlist_cutoff_minutes, so joining there is
    -- an offer that can never be made.
    if v_occ.starts_at < now() + make_interval(mins => v_set.waitlist_cutoff_minutes) then
      return (null, null, null, null, 'waitlist_closed')::book_class_result;
    end if;

    -- §4.1: strictly FIFO, no priority tiers in V1, and NO credit consumed on
    -- joining. The paying source is re-resolved when the offer is accepted
    -- (§4.2.4), so it is deliberately left null on the row — including for a
    -- comp, whose comp intent must be supplied again at promotion.
    select coalesce(max(waitlist_position), 0) + 1
      into v_position
      from bookings
     where occurrence_id = p_occurrence_id
       and status = 'waitlisted';

    insert into bookings (
      studio_id, occurrence_id, member_id, status, source,
      payment_source, membership_id, waitlist_position
    ) values (
      v_occ.studio_id, p_occurrence_id, p_member_id, 'waitlisted', p_source,
      null, null, v_position
    ) returning id into v_booking_id;

    update class_occurrences
       set waitlist_count = waitlist_count + 1
     where id = p_occurrence_id;

    return (v_booking_id, 'waitlisted'::booking_status, null, v_position, null)
           ::book_class_result;
  end if;

  if v_full then
    -- §2.3 / §5 / §14: a staff override reaches here. Two shapes, told apart for
    -- the audit: physically full is a walk-in booked OVER capacity; held-only is
    -- the desk deliberately taking a seat reserved for a waitlisted member (the
    -- offer stands and will fail on acceptance — a deliberate act, §14). The hold
    -- is never applied to an override, so front desk can always seat someone.
    if v_phys_full then
      v_bypassed := v_bypassed || 'capacity'::text;
    else
      v_bypassed := v_bypassed || 'held_seat'::text;
    end if;
  end if;

  -- ===========================================================================
  -- 5. Write. Booking, ledger and booked_count, one transaction.
  -- ===========================================================================

  insert into bookings (
    studio_id, occurrence_id, member_id, status, source,
    payment_source, membership_id, override_reason, overridden_rules
  ) values (
    v_occ.studio_id, p_occurrence_id, p_member_id, v_status, p_source,
    v_pay, case when v_pay in ('membership','class_pack') then v_membership end,
    -- §2.3: a reason that bypassed nothing was not an override, so it is not
    -- recorded as one.
    case when array_length(v_bypassed, 1) is not null then p_override_reason end,
    case when array_length(v_bypassed, 1) is not null then v_bypassed end
  ) returning id into v_booking_id;

  if v_consume then
    -- §6: the balance is derived from the ledger, never edited in place, and
    -- every row carries balance_after so any point in history is
    -- reconstructable without replaying. balance_after is the member's total
    -- credit balance across every source; the member row lock above makes the
    -- read-then-write safe.
    select coalesce(sum(delta), 0) into v_balance
      from credit_ledger
     where studio_id = v_occ.studio_id
       and member_id = p_member_id;

    insert into credit_ledger (
      studio_id, member_id, membership_id, delta, reason,
      booking_id, balance_after, expires_at, actor_user_id
    )
    select v_occ.studio_id, p_member_id, v_membership, -1, 'booking',
           v_booking_id, v_balance - 1,
           case when ms.expires_on is not null
                then (ms.expires_on + 1)::timestamp at time zone v_tz end,
           v_actor
      from memberships ms
     where ms.id = v_membership
    returning id into v_ledger_id;

    -- credits_remaining is a cache. Written in the same transaction as the
    -- ledger row, never independently of it.
    update memberships
       set credits_remaining = credits_remaining - 1
     where id = v_membership;

    update bookings set credit_entry_id = v_ledger_id where id = v_booking_id;
  end if;

  update class_occurrences
     set booked_count = booked_count + 1
   where id = p_occurrence_id;

  -- §2.3 / §13: every override that actually bypassed a rule is audited with
  -- actor and reason. The booking row carries the same reason (above) so it is
  -- visible without a join to audit_logs.
  if v_override and array_length(v_bypassed, 1) is not null then
    insert into audit_logs (
      studio_id, actor_user_id, action, entity_table, entity_id, after
    ) values (
      v_occ.studio_id, v_actor, 'booking.override', 'bookings', v_booking_id,
      jsonb_build_object(
        'reason',        p_override_reason,
        'rules_bypassed', to_jsonb(v_bypassed),
        'occurrence_id', p_occurrence_id,
        'member_id',     p_member_id,
        'over_capacity', v_occ.booked_count + 1 > v_occ.capacity
      )
    );
  end if;

  -- Decision 30 amendment: a seat that counts toward the headcount may have just
  -- completed a free class's confirm-at total, confirming its provisional free
  -- seats at once. A no-op when the class has none or is still short.
  if v_status in ('booked', 'pending_payment') then
    perform confirm_provisional_seats_run(p_occurrence_id);
  end if;

  -- The caller needs to know it is holding rather than booked, because that is
  -- what decides whether the member is sent to Checkout next.
  return (v_booking_id, v_status, v_pay, null, null)
         ::book_class_result;
end $function$

;

-- =============================================================================
-- The anon surface is unchanged — exactly TWELVE pre-login functions. None of
-- the Decision 49 functions is anon, and book_class kept its ACL through
-- create-or-replace.
-- =============================================================================
do $$
declare v_n int;
begin
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and has_function_privilege('anon', p.oid, 'execute');
  if v_n <> 12 then
    raise exception 'anon surface is %, expected exactly twelve', v_n;
  end if;
end $$;
