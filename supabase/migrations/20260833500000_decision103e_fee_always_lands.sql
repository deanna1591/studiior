-- ============================================================================
-- Decision 103(e) — a paid reservation fee always lands.
-- ============================================================================
-- creates: restore_reservation_booking(uuid), member_reservation_fees(uuid)
-- re-issues: xendit_begin_reservation(uuid, uuid), sweep_unpaid_dropins(),
--   member_pending_bookings(uuid), xendit_fail_purchase_internal(uuid, text, text),
--   xendit_activate_success_internal(uuid, text), reserve_free_first(uuid),
--   member_activity(uuid, date, date), sales_history(uuid, date, date, uuid, text),
--   sales_totals(uuid, date, date, uuid, text), dashboard_revenue(uuid, date, date),
--   dashboard_source_label(text)
--
-- A reservation hold lasts as long as the Xendit payment it belongs to:
-- xendit_begin_reservation sets hold_until to 30 minutes out (the app sets the
-- session to expire at the same moment); sweep_unpaid_dropins releases a hold
-- only after its hold_until, and xendit_fail_purchase_internal releases it at
-- once on a Xendit expiry/failure. When a reservation payment succeeds and the
-- hold has already been released: if a seat is still free the booking is
-- restored through the real book_first_free_run (restore_reservation_booking);
-- if the class is full or past the fee becomes reservation credit at once with
-- the free_reservation_lost_seat email. Reservation credit of at least the fee
-- books a free class directly, no Xendit (reserve_free_first). The Journey
-- (member_activity) never shows a hold as Booked and gains eight reservation
-- lines; Sales (sales_history / sales_totals / dashboard_revenue) group and list
-- reservation fees; the profile Reservation fee card reads member_reservation_fees.
-- No new anon RPC: the anon surface stays EXACTLY THIRTEEN (asserted at apply).
-- ============================================================================

-- ---- the lost-seat email (modelled on free_reservation_credited, 80a frame) ----
insert into notification_templates (key, subject, text_body, html_body, note) values
('free_reservation_lost_seat',
 'Your {fee} is now credit at {studio_name}',
 E'Hi {first_name},\n\nYour seat was gone before the payment arrived, so the fee is credit on your account. Book another class and it is used for that.\n\nSee plans: {plans_url}',
 '<p>Hi {first_name},</p>
<p>Your seat was gone before the payment arrived, so the fee is credit on your account. Book another class and it is used for that.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{plans_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">See plans</a></td></tr></table>
<p>{studio_name}</p>',
 'Decision 103(e): a reservation payment landed after the hold was released and the class was full or past; the fee became credit.')
on conflict (key) do nothing;

-- ---- restore_reservation_booking: re-book a released hold after a late payment ----
-- The automated form of the Decision 103(e) one-off repair. Faithful to
-- book_first_free_run: restore to pending_payment, reseat, then complete it, so
-- the booked flip queues the usual free_booking_pending/confirmed. Service-only.
create or replace function restore_reservation_booking(p_booking_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_b bookings%rowtype;
begin
  select * into v_b from bookings where id = p_booking_id for update;
  if v_b.id is null or v_b.payment_source <> 'comp' then return; end if;
  if v_b.status = 'booked' then return; end if;  -- already restored

  update bookings
     set status = 'pending_payment', provisional = true, confirmed_at = null,
         cancelled_at = null, cancelled_by = null, release_reason = null,
         is_late_cancel = false, hold_until = null, hold_reason = null
   where id = p_booking_id;
  update class_occurrences set booked_count = occurrence_seats_taken(id)
   where id = v_b.occurrence_id;

  perform book_first_free_run(p_booking_id);
  update class_occurrences set booked_count = occurrence_seats_taken(id)
   where id = v_b.occurrence_id;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (v_b.studio_id, null, 'reservation.restored', 'bookings', p_booking_id,
          jsonb_build_object('note', 'Decision 103(e): seat restored after a late reservation payment.'));
end $$;
revoke execute on function restore_reservation_booking(uuid) from public, anon, authenticated;
grant  execute on function restore_reservation_booking(uuid) to service_role;

-- ---- member_reservation_fees: the profile card, one row per fee with its state ----
-- held for {class} | credited back | kept (no-show / late cancel) | used as
-- credit | refunded. A credit-covered reservation writes no payment, so method
-- excludes it (those appear only as the "Credit used" Journey line).
create or replace function member_reservation_fees(p_member_id uuid)
returns table(payment_id uuid, paid_at timestamptz, fee_cents int, currency text,
              class_name text, occurrence_start timestamptz, state text, state_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare v_studio uuid;
begin
  select studio_id into v_studio from members where id = p_member_id;
  if v_studio is null then raise exception 'no such member' using errcode = 'PT404'; end if;
  if not (coalesce(is_desk_up(v_studio), false) or is_service_context()
          or exists (select 1 from members m where m.id = p_member_id and m.user_id = auth.uid())) then
    raise exception 'that is not your statement' using errcode = 'PT403';
  end if;

  return query
  select p.id, p.paid_at, p.amount_cents, p.currency::text,
         coalesce(o.name, 'a class') as class_name, o.starts_at,
         case
           when p.refunded_at is not null or p.status = 'refunded'
                or coalesce(p.refunded_cents, 0) >= p.amount_cents then 'refunded'
           when mc.used_cents >= mc.amount_cents then 'used'
           when mc.id is not null then 'credited'
           when b.status in ('no_show', 'late_cancelled') then 'kept'
           else 'held'
         end as state,
         coalesce(mc.created_at, b.cancelled_at, p.refunded_at) as state_at
    from payments p
    left join bookings b on b.id = p.booking_id
    left join class_occurrences o on o.id = b.occurrence_id
    left join lateral (
      select id, amount_cents, used_cents, created_at
        from member_credits mc2
       where mc2.payment_id = p.id and mc2.voided_at is null
         and mc2.reason in ('reservation_credit', 'reservation_lost_seat')
       order by created_at limit 1) mc on true
   where p.member_id = p_member_id and p.kind = 'reservation_fee'
     and coalesce(p.method, '') <> 'reservation_credit'
   order by p.paid_at desc nulls last, p.created_at desc;
end $$;
revoke execute on function member_reservation_fees(uuid) from public, anon;
grant  execute on function member_reservation_fees(uuid) to authenticated, service_role;


-- ---- begin ----
create or replace function xendit_begin_reservation(p_studio_id uuid, p_booking_id uuid)
returns table(purchase_id uuid, amount_cents int, currency char(3))
language plpgsql security definer set search_path = public as $$
declare v_member uuid; b bookings%rowtype; v_fee int; v_ccy char(3); v_id uuid;
begin
  select id into v_member from members where studio_id = p_studio_id and user_id = auth.uid();
  if v_member is null then
    raise exception 'you are not a member of that studio' using errcode = 'PT403';
  end if;
  if not exists (select 1 from studio_payment_providers where studio_id = p_studio_id and provider = 'xendit') then
    raise exception 'this studio is not set up to take online payments' using errcode = 'PT409';
  end if;

  select * into b from bookings where id = p_booking_id;
  if b.id is null or b.member_id <> v_member or b.studio_id <> p_studio_id
     or b.payment_source <> 'comp' then
    raise exception 'that is not a held reservation' using errcode = 'PT409';
  end if;

  -- Already reserved (the fee is paid): nothing to begin.
  if exists (select 1 from payments p
              where p.booking_id = b.id and p.kind = 'reservation_fee'
                and p.status in ('succeeded', 'partially_refunded')) then
    raise exception 'this booking is already reserved' using errcode = 'PT409';
  end if;

  -- Accept either a NEW hold (pending_payment, from reserve_free_first) or an
  -- EXISTING free first class (a booked comp booking carrying the once-ever
  -- host-null guest pass). Both are the member's own free seat; neither needs an
  -- eligibility check, which is for a brand-new first-timer.
  if not (
    b.status = 'pending_payment'
    or (b.status = 'booked'
        and exists (select 1 from guest_passes gp
                     where gp.guest_booking_id = b.id and gp.host_member_id is null))
  ) then
    raise exception 'that is not a held reservation' using errcode = 'PT409';
  end if;

  select ss.free_first_reservation_fee_cents into v_fee from studio_settings ss where ss.studio_id = p_studio_id;
  if coalesce(v_fee, 0) <= 0 then
    raise exception 'this studio has no reservation fee' using errcode = 'PT409';
  end if;
  select st.currency into v_ccy from studios st where st.id = p_studio_id;

  insert into xendit_purchases (studio_id, member_id, booking_id, amount_cents, currency)
  values (p_studio_id, v_member, p_booking_id, v_fee, v_ccy)
  returning id into v_id;

  -- Decision 103(e): the hold lasts as long as the invoice (30 minutes); the app
  -- sets the Xendit session to expire at the same moment.
  update bookings set hold_until = now() + interval '30 minutes', hold_reason = 'reservation'
   where id = p_booking_id;

  return query select v_id, v_fee, v_ccy;
end $$;
revoke execute on function xendit_begin_reservation(uuid, uuid) from public, anon;
grant  execute on function xendit_begin_reservation(uuid, uuid) to authenticated, service_role;


-- ---- sweep ----
create or replace function sweep_unpaid_dropins() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r record;
  n_cancelled int := 0;
  n_offered   int := 0;
  v_res       cancel_result;
begin
  if not is_service_context() then
    raise exception 'the drop-in sweep runs as the backend, not as a user'
      using errcode = 'PT403';
  end if;

  for r in
    select b.id, b.studio_id
      from bookings b
      join studio_settings st on st.studio_id = b.studio_id
     where b.status = 'pending_payment'
       and coalesce(b.hold_reason, '') <> 'free_class_duplicate'  -- Decision 98 holds have their own 24h sweep
       and (
         -- Decision 103(e): a reservation hold lasts until its hold_until (30 min).
         (b.hold_until is not null and now() >= b.hold_until)
         -- an unpaid drop-in (and a legacy reservation hold) at booked_at + window.
         or (b.hold_until is null and b.booked_at < now()
               - make_interval(mins => coalesce(st.dropin_payment_window_minutes, 15)))
       )
  loop
    begin
      v_res := cancel_booking(r.id);
      n_cancelled := n_cancelled + 1;
      if v_res.offer_made then
        n_offered := n_offered + 1;
      end if;

      -- The abandoned charge, marked so it stops looking like money in flight.
      update payments
         set status = 'failed',
             failure_code = 'checkout_abandoned',
             failure_message = 'The member did not finish paying inside the window.',
             updated_at = now()
       where booking_id = r.id and status = 'pending';

      -- Decision 103(c): expire the matching pending xendit purchase now, rather
      -- than leaving it for the daily reconcile — its booking is cancelled.
      update xendit_purchases
         set status = 'expired',
             failure_reason = 'hold_released',
             updated_at = now()
       where booking_id = r.id and status = 'pending';
    exception when others then
      -- One studio's bad row must not stop every other studio's sweep, the same
      -- reasoning as a missing API key not taking the notification cron down.
      raise warning 'sweep_unpaid_dropins: booking % failed: %', r.id, sqlerrm;
    end;
  end loop;

  return jsonb_build_object('cancelled', n_cancelled, 'waitlist_offers', n_offered);
end $$;

revoke execute on function sweep_unpaid_dropins() from public, anon, authenticated;
grant execute on function sweep_unpaid_dropins() to service_role;


-- ---- pending ----
drop function if exists member_pending_bookings(uuid);
create function member_pending_bookings(p_studio_id uuid)
returns table(occurrence_id uuid, booking_id uuid, status text,
              hold_until timestamptz, pending_until timestamptz)
language plpgsql stable security definer set search_path to 'public' as $function$
declare v_member uuid;
begin
  select id into v_member from members where user_id = auth.uid() and studio_id = p_studio_id;
  if v_member is null then
    raise exception 'not a member of that studio' using errcode = 'PT403';
  end if;
  return query
  -- Decision 103(c): a RESERVATION HOLD — a pending_payment comp seat with
  -- hold_until null, created by reserve_free_first when a member starts paying
  -- the reservation fee — is never shown as booked. It reports 'pending_payment'
  -- with the hold expiry (booked_at + the drop-in payment window), on any class,
  -- so the app shows "Payment pending" with the minutes left, Finish paying and
  -- Cancel. The Decision 98 free-class-duplicate holds (hold_until set) have
  -- their own 24h flow and are not reported here.
  select b.occurrence_id, b.id, 'pending_payment'::text,
         coalesce(b.hold_until,
                  b.booked_at + make_interval(mins => coalesce(st.dropin_payment_window_minutes, 15))),
         null::timestamptz
    from bookings b
    join class_occurrences o on o.id = b.occurrence_id
    join studio_settings st  on st.studio_id = b.studio_id
   where b.member_id = v_member
     and b.status = 'pending_payment' and b.payment_source = 'comp'
     and coalesce(b.hold_reason, '') <> 'free_class_duplicate'  -- Decision 103(e): hold_until is now set (30 min)
     and o.status = 'scheduled'
  union all
  -- Decision 21 (byte-faithful from the prior reader's flex arm, minus the hold):
  -- a BOOKED flex class not yet committed carries its cutoff. The prior reader's
  -- flex arm also matched pending_payment rows; a hold is now Arm A above, so this
  -- arm is status='booked' only. A provisional free seat on a flex class is
  -- status='booked' and is still returned here with its deadline, exactly as
  -- before; the booked-side output is otherwise unchanged.
  select o.id, b.id, 'booked'::text, null::timestamptz, d.deadline_at
    from bookings b
    join class_occurrences o on o.id = b.occurrence_id
    cross join lateral flex_deadline_for_run(o.id) d
   where b.member_id = v_member
     and b.status = 'booked'
     and coalesce(o.flex, false) and o.committed_at is null and o.status = 'scheduled'
     and d.deadline_at is not null
  union all
  -- Decision 30 (byte-faithful from the prior reader's provisional arm): a
  -- PROVISIONAL free seat is pending too, with NO time shown (pending_until null)
  -- — it confirms the moment the class is on, so a deadline would mislead. On any
  -- class (flex or core); on a flex class it is also returned by the arm above
  -- with its cutoff, exactly as the prior reader did. status='booked', so the
  -- Book list renders it as the bare "Waiting for confirmation" chip.
  select b.occurrence_id, b.id, 'booked'::text, null::timestamptz, null::timestamptz
    from bookings b
    join class_occurrences o on o.id = b.occurrence_id
   where b.member_id = v_member
     and b.status = 'booked' and b.provisional
     and o.status = 'scheduled';
end $function$;
revoke execute on function member_pending_bookings(uuid) from public, anon;
grant  execute on function member_pending_bookings(uuid) to authenticated, service_role;


-- ---- fail ----
create or replace function xendit_fail_purchase_internal(p_purchase_id uuid, p_status text, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare p xendit_purchases%rowtype; o product_orders%rowtype; prod products%rowtype; n int;
begin
  select * into p from xendit_purchases where id = p_purchase_id for update;
  if p.id is null or p.status in ('succeeded') then return; end if;

  update xendit_purchases
     set status = p_status, failure_reason = p_reason, completed_at = now(), updated_at = now()
   where id = p_purchase_id and status = 'pending';

  if p.booking_id is not null then
    -- Decision 103(e): release the held seat at once rather than waiting for the
    -- sweep. No email (the class page tells the member "Your spot wasn't held.").
    if exists (select 1 from bookings b where b.id = p.booking_id and b.status = 'pending_payment') then
      perform cancel_booking(p.booking_id);
    end if;
    return;
  elsif p.product_order_id is not null then
    select * into o from product_orders where id = p.product_order_id for update;
    update product_orders set status = 'cancelled'
     where id = p.product_order_id and status in ('reserved', 'pending');
    get diagnostics n = row_count;
    if n = 1 then
      select * into prod from products where id = o.product_id for update;
      if prod.track_stock then
        update products set stock = stock + o.quantity where id = prod.id;
        insert into stock_movements (studio_id, product_id, delta, reason, order_id)
        values (p.studio_id, prod.id, o.quantity, 'release', o.id);
      end if;
    end if;
    perform queue_notification(
      p.studio_id, p.member_id, 'xendit_purchase_failed',
      jsonb_build_object('plan_name', (select name from products where id = o.product_id)),
      'xendit_failed:' || p_purchase_id::text);
  else
    perform queue_notification(
      p.studio_id, p.member_id, 'xendit_purchase_failed',
      jsonb_build_object('plan_name', (select name from membership_plans where id = p.plan_id)),
      'xendit_failed:' || p_purchase_id::text);
  end if;
end $$;
revoke execute on function xendit_fail_purchase_internal(uuid, text, text) from public, anon, authenticated;
grant  execute on function xendit_fail_purchase_internal(uuid, text, text) to service_role;


-- ---- activate ----
create or replace function xendit_activate_success_internal(p_purchase_id uuid, p_payment_id text)
returns text
language plpgsql security definer set search_path = public as $$
declare p xendit_purchases%rowtype; v_ms uuid; v_prior text;
        v_group uuid; v_is_group boolean;
        o product_orders%rowtype; prod products%rowtype;
        v_b bookings%rowtype; v_occ class_occurrences%rowtype; v_free int; v_pay_id uuid;
begin
  select * into p from xendit_purchases where id = p_purchase_id for update;
  if p.id is null then return 'unknown_purchase'; end if;
  if p.status = 'succeeded' then return 'already_succeeded'; end if;
  v_prior := p.status;

  if p.booking_id is not null then
    -- Decision 103: record the reservation fee FIRST, then complete the held
    -- free-first seat. The seat flip to 'booked' fires bookings_queue_notifications,
    -- which reads the now-present reservation payment to add its sentence. A
    -- reservation purchase never consumes credit itself.
    insert into payments (studio_id, member_id, booking_id, kind, amount_cents, currency,
                          status, provider, reference, description, paid_at)
    values (p.studio_id, p.member_id, p.booking_id, 'reservation_fee', p.amount_cents, p.currency,
            'succeeded', 'xendit', nullif(p_payment_id, ''), 'Reservation fee', now())
    returning id into v_pay_id;
    -- Decision 103(e): the hold may have been released before the payment landed.
    select * into v_b from bookings where id = p.booking_id;
    if v_b.status in ('booked', 'pending_payment') then
      perform book_first_free_run(p.booking_id);   -- normal completion
    else
      select * into v_occ from class_occurrences where id = v_b.occurrence_id;
      v_free := coalesce(v_occ.capacity, 0) - occurrence_seats_taken(v_occ.id)
                - occurrence_seats_held(v_occ.id);
      if v_occ.id is not null and v_occ.status = 'scheduled'
         and v_occ.starts_at > now() and v_free >= 1 then
        perform restore_reservation_booking(p.booking_id);   -- seat still free: re-book
      else
        -- full or past: the fee becomes reservation credit, with the lost-seat email.
        insert into member_credits (studio_id, member_id, amount_cents, currency, reason,
                                    payment_id, booking_id)
        values (p.studio_id, p.member_id, p.amount_cents, p.currency, 'reservation_lost_seat',
                v_pay_id, p.booking_id);
        perform queue_notification(p.studio_id, p.member_id, 'free_reservation_lost_seat',
          jsonb_build_object('fee', fmt_money(p.amount_cents, p.currency),
            'class_name', coalesce(v_occ.name, 'a class'),
            'plans_url', member_portal_url(p.studio_id, '/account/plan')),
          'free_reservation_lost_seat:' || p.booking_id::text);
      end if;
    end if;

  elsif p.product_order_id is not null then
    select * into o from product_orders where id = p.product_order_id for update;
    select * into prod from products where id = o.product_id for update;

    update product_orders set status = 'paid' where id = o.id and status in ('reserved', 'pending');

    if prod.track_stock then
      update products set stock = stock + o.quantity where id = prod.id;
      insert into stock_movements (studio_id, product_id, delta, reason, order_id)
      values (p.studio_id, prod.id, o.quantity, 'release', o.id);
      update products set stock = stock - o.quantity where id = prod.id;
      insert into stock_movements (studio_id, product_id, delta, reason, order_id)
      values (p.studio_id, prod.id, -o.quantity, 'sale', o.id);
    end if;

    insert into payments (studio_id, member_id, product_order_id, amount_cents, currency,
                          status, provider, reference, description, paid_at)
    values (p.studio_id, p.member_id, o.id, p.amount_cents, p.currency, 'succeeded', 'xendit',
            nullif(p_payment_id, ''), prod.name || ' ×' || o.quantity, now());

    if p.credit_applied_cents > 0 then
      perform consume_reservation_credit(p.studio_id, p.member_id, p.credit_applied_cents);
    end if;

    perform queue_notification(
      p.studio_id, p.member_id, 'product_order_paid',
      jsonb_build_object('product', prod.name, 'quantity', o.quantity),
      'product_order_paid:' || o.id::text);

  else
    select type = 'group' into v_is_group from membership_plans where id = p.plan_id;
    if v_is_group then
      v_group := activate_purchase(p.studio_id, p.member_id, p.plan_id, p.amount_cents, p.currency, null, null, false);
      insert into payments (studio_id, member_id, group_purchase_id, amount_cents, currency,
                            status, provider, reference, description, paid_at)
      select p.studio_id, p.member_id, v_group, p.amount_cents, p.currency, 'succeeded', 'xendit',
             nullif(p_payment_id, ''), mp.name, now()
        from membership_plans mp where mp.id = p.plan_id;
    else
    if p.renews_membership_id is not null and exists (
         select 1 from memberships where id = p.renews_membership_id
            and status in ('active', 'past_due') and not membership_frozen_now(id)) then
      v_ms := p.renews_membership_id;
      perform advance_membership_period_run(p.renews_membership_id);
    else
      v_ms := activate_purchase(p.studio_id, p.member_id, p.plan_id, p.amount_cents, p.currency,
                                null, null, false);
      update memberships set auto_renew = false where id = v_ms;
    end if;

    perform apply_plan_to_unpaid(p.studio_id, p.member_id, v_ms);

    insert into payments (studio_id, member_id, membership_id, amount_cents, currency,
                          status, provider, reference, description, paid_at)
    select p.studio_id, p.member_id, v_ms, p.amount_cents, p.currency, 'succeeded', 'xendit',
           nullif(p_payment_id, ''), mp.name, now()
      from membership_plans mp where mp.id = p.plan_id;
    end if;

    -- Decision 103: a plan/pack purchase consumes any reservation credit applied
    -- at begin (the amount at Xendit was already reduced by this).
    if p.credit_applied_cents > 0 then
      perform consume_reservation_credit(p.studio_id, p.member_id, p.credit_applied_cents);
    end if;
  end if;

  if v_prior = 'expired' then
    insert into audit_logs (studio_id, action, entity_table, entity_id, after)
    values (p.studio_id, 'xendit.expiry_overridden', 'xendit_purchases', p.id,
            jsonb_build_object('prior_status', v_prior,
                               'payment_id', nullif(p_payment_id, ''),
                               'note', 'paid after local expiry'));
  end if;

  update xendit_purchases
     set status = 'succeeded', xendit_payment_id = nullif(p_payment_id, ''),
         completed_at = now(), failure_reason = null, updated_at = now()
   where id = p_purchase_id;

  return case when v_prior = 'expired' then 'activated_after_expiry' else 'activated' end;
end $$;
revoke execute on function xendit_activate_success_internal(uuid, text) from public, anon, authenticated;
grant  execute on function xendit_activate_success_internal(uuid, text) to service_role;


-- ---- reserve ----
create or replace function reserve_free_first(p_occurrence_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare
  v_occ class_occurrences%rowtype; v_member members%rowtype; v_set studio_settings%rowtype;
  v_ser class_series%rowtype; v_cfg_tier guarantee_tier; v_elig jsonb; v_free int; v_booking uuid;
  v_credit int;
begin
  select * into v_occ from class_occurrences where id = p_occurrence_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;

  select * into v_member from members where studio_id = v_occ.studio_id and user_id = auth.uid();
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_authorised'); end if;

  -- Decision 103a: a waived member never needs the fee path; the app routes them
  -- to the ordinary free book, and this is the belt if reached directly.
  if v_member.reservation_fee_waived_at is not null then
    return jsonb_build_object('ok', false, 'reason', 'fee_waived');
  end if;

  select * into v_set from studio_settings where studio_id = v_occ.studio_id;
  if coalesce(v_set.free_first_reservation_fee_cents, 0) <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_reservation_fee');
  end if;

  v_elig := free_first_eligibility(v_occ.studio_id, v_member.id);
  if not (v_elig ->> 'ok')::boolean then return v_elig; end if;

  if v_occ.status <> 'scheduled' then return jsonb_build_object('ok', false, 'reason', 'class_not_bookable'); end if;
  if v_occ.starts_at <= now() then return jsonb_build_object('ok', false, 'reason', 'class_in_past'); end if;
  if not month_published(v_occ.studio_id, v_occ.starts_at) then
    return jsonb_build_object('ok', false, 'reason', 'month_not_published'); end if;
  if studio_hides_unstaffed(v_occ.studio_id) and v_occ.staffing <> 'assigned' then
    return jsonb_build_object('ok', false, 'reason', 'not_staffed_yet'); end if;
  if v_occ.hidden_from_members then
    return jsonb_build_object('ok', false, 'reason', 'class_hidden'); end if;
  if v_occ.starts_at > now() + make_interval(days => coalesce(v_set.booking_window_days, 30)) then
    return jsonb_build_object('ok', false, 'reason', 'outside_booking_window'); end if;
  if v_occ.starts_at < now() + make_interval(mins => coalesce(v_set.booking_cutoff_minutes, 0)) then
    return jsonb_build_object('ok', false, 'reason', 'past_booking_cutoff'); end if;
  if v_occ.free_first_override = 'closed' then
    return jsonb_build_object('ok', false, 'reason', 'free_first_closed_here'); end if;
  if not coalesce(v_set.free_first_peak_allowed, true) and occurrence_is_peak(p_occurrence_id) then
    return jsonb_build_object('ok', false, 'reason', 'peak_not_allowed'); end if;

  if v_occ.series_id is not null then select * into v_ser from class_series where id = v_occ.series_id; end if;
  v_cfg_tier := coalesce(v_occ.guarantee_tier,
                         case when v_occ.flex then 'flex'::guarantee_tier end,
                         v_ser.guarantee_tier,
                         case when v_ser.flex then 'flex'::guarantee_tier end,
                         'core'::guarantee_tier);
  if coalesce(v_set.free_first_core_only, false) and v_cfg_tier <> 'core'
     and v_occ.free_first_override is distinct from 'open' then
    return jsonb_build_object('ok', false, 'reason', 'flex_not_allowed'); end if;
  if v_occ.series_id is not null and not coalesce(v_ser.free_first_allowed, true)
     and v_occ.free_first_override is distinct from 'open' then
    return jsonb_build_object('ok', false, 'reason', 'not_trial_class'); end if;
  if v_set.free_first_seats_per_class is not null
     and (select count(*) from bookings b
           where b.occurrence_id = p_occurrence_id and b.status = 'booked'
             and b.payment_source = 'comp'
             and exists (select 1 from guest_passes gp
                          where gp.guest_booking_id = b.id and gp.host_member_id is null))
         >= v_set.free_first_seats_per_class then
    return jsonb_build_object('ok', false, 'reason', 'free_seats_full'); end if;

  v_free := v_occ.capacity - occurrence_seats_taken(p_occurrence_id) - occurrence_seats_held(p_occurrence_id);
  if v_free < 1 then return jsonb_build_object('ok', false, 'reason', 'class_full'); end if;

  -- Hold the seat: a comp booking in pending_payment, no guest_passes yet. The
  -- AFTER-INSERT notification trigger sends nothing (status <> 'booked'), and the
  -- existing sweep_unpaid_dropins (status='pending_payment' and hold_until is null)
  -- frees it if the member abandons Xendit.
  -- Decision 103(e): reservation credit of at least the fee covers it directly,
  -- with no Xendit page. Book the free class now and consume the credit; the audit
  -- row drives the "Credit used for a reservation" Journey line and the app's
  -- confirmation. This is how a kept credit (on-time cancel, lost seat, refund) is
  -- spent on the next free class.
  v_credit := reservation_credit_available(v_occ.studio_id, v_member.id);
  if v_credit >= v_set.free_first_reservation_fee_cents then
    insert into bookings (studio_id, occurrence_id, member_id, status, source,
                          payment_source, provisional, confirmed_at, booked_at)
    values (v_occ.studio_id, p_occurrence_id, v_member.id, 'pending_payment', 'member', 'comp',
            false, null, now())
    returning id into v_booking;
    update class_occurrences set booked_count = booked_count + 1 where id = p_occurrence_id;
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (v_occ.studio_id, auth.uid(), 'reservation.credit_used', 'bookings', v_booking,
            jsonb_build_object('fee_cents', v_set.free_first_reservation_fee_cents));
    perform consume_reservation_credit(v_occ.studio_id, v_member.id,
                                       v_set.free_first_reservation_fee_cents);
    perform book_first_free_run(v_booking);
    return jsonb_build_object('ok', true, 'booking_id', v_booking, 'credit_covered', true,
      'fee_cents', v_set.free_first_reservation_fee_cents);
  end if;

  insert into bookings (studio_id, occurrence_id, member_id, status, source,
                        payment_source, provisional, confirmed_at, booked_at)
  values (v_occ.studio_id, p_occurrence_id, v_member.id, 'pending_payment', 'member', 'comp',
          false, null, now())
  returning id into v_booking;
  update class_occurrences set booked_count = booked_count + 1 where id = p_occurrence_id;

  return jsonb_build_object('ok', true, 'booking_id', v_booking,
    'fee_cents', v_set.free_first_reservation_fee_cents);
end $$;
revoke execute on function reserve_free_first(uuid) from public, anon;
grant  execute on function reserve_free_first(uuid) to authenticated, service_role;


-- ---- member_activity ----
CREATE OR REPLACE FUNCTION public.member_activity(p_member_id uuid, p_from date, p_to date)
 RETURNS TABLE(at timestamp with time zone, kind text, title text, detail text, credit_delta integer, balance_after integer, amount_cents integer, currency text, occurrence_id uuid, booking_id uuid, membership_id uuid, plan_name text, due_cents integer, is_free_first boolean, occurrence_start timestamp with time zone, instructor_first text, credits_left_after integer, payment_method text, recorded_by_name text, plan_classes integer, plan_valid_to date, unused_credits integer, payment_source text, is_paid boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
declare v_studio uuid; v_is_staff boolean; v_owns boolean;
begin
  select studio_id into v_studio from members where id = p_member_id;
  if v_studio is null then raise exception 'no such member' using errcode = 'PT404'; end if;
  v_owns := exists (select 1 from members m where m.id = p_member_id and m.user_id = auth.uid());
  v_is_staff := coalesce(is_desk_up(v_studio), false) or is_service_context();
  if not (v_owns or v_is_staff) then
    raise exception 'that is not your statement' using errcode = 'PT403';
  end if;

  return query
  with led as (
    select cl.id, cl.delta, cl.reason::text as reason, cl.booking_id, cl.membership_id,
           cl.created_at,
           (sum(cl.delta) over (order by cl.created_at, cl.id))::int as bal,
           (sum(cl.delta) over (partition by cl.membership_id order by cl.created_at, cl.id))::int as membership_bal
      from credit_ledger cl
     where cl.member_id = p_member_id
  ),
  -- A purchase payment claims the Nth 'purchase' ledger row of its membership;
  -- a refunded payment claims the Nth negative 'manual' row of its membership.
  -- Rank joins, so each ledger id is claimed at most once; a grant with no
  -- payment (e.g. a complimentary membership) stays unclaimed and surfaces as its
  -- own "Credits added" line.
  purch_led as (
    select id, membership_id, row_number() over (partition by membership_id order by created_at, id) rn
      from led where reason = 'purchase' and membership_id is not null),
  purch_pay as (
    select p.id as payment_id, p.membership_id,
           row_number() over (partition by p.membership_id order by coalesce(p.paid_at, p.created_at), p.id) rn
      from payments p
     where p.member_id = p_member_id and p.membership_id is not null
       and p.status in ('succeeded', 'partially_refunded')),
  pay_grant as (
    select pp.payment_id, pl.id as ledger_id
      from purch_pay pp join purch_led pl on pl.membership_id = pp.membership_id and pl.rn = pp.rn),
  forfeit_led as (
    select id, membership_id, row_number() over (partition by membership_id order by created_at, id) rn
      from led where reason = 'manual' and delta < 0 and membership_id is not null),
  refund_pay as (
    select p.id as payment_id, p.membership_id,
           row_number() over (partition by p.membership_id order by coalesce(p.refunded_at, p.updated_at), p.id) rn
      from payments p
     where p.member_id = p_member_id and p.membership_id is not null
       and (p.refunded_at is not null or p.status in ('refunded', 'partially_refunded'))),
  pay_forfeit as (
    select rp.payment_id, fl.id as ledger_id
      from refund_pay rp join forfeit_led fl on fl.membership_id = rp.membership_id and fl.rn = rp.rn),
  ev as (
    -- Decision 95: a flex-rescue email was sent (staff only).
    select coalesce(nt.sent_at, nt.scheduled_for, nt.created_at) as at,
           'rescue_email' as kind, 'Rescue email sent' as title,
           case when nt.template_key = 'flex_rescue_2days'
                then 'Flex class still needs numbers'
                else 'Last call to move the booking' end as detail,
           null::uuid as ledger_id, null::int as amount_cents, null::text as currency,
           null::uuid as occurrence_id, null::uuid as booking_id, null::uuid as membership_id
      from notifications nt
     where nt.member_id = p_member_id and v_is_staff
       and nt.template_key in ('flex_rescue_2days','flex_rescue_final','free_rescue_2days','free_rescue_final')
    union all
    -- joined (staff only)
    select m.joined_on::timestamptz as at, 'joined' as kind, 'Joined the studio' as title,
           nullif('Came via ' || coalesce(m.source, ''), 'Came via ') as detail,
           null::uuid as ledger_id, null::int as amount_cents, null::text as currency,
           null::uuid as occurrence_id, null::uuid as booking_id, null::uuid as membership_id
      from members m where m.id = p_member_id and v_is_staff and m.joined_on is not null
    union all
    -- Decision 97: invited a guest (this member is the host). Derived from
    -- the invite snapshot, so it survives the guest's deletion or merge.
    select gp.invited_at as at, 'invited_guest' as kind,
           'Invited ' || coalesce(g.first_name, 'a guest') || ' to ' || coalesce(o.name, ct.name, 'a class') as title,
           null::text as detail,
           null::uuid as ledger_id, null::int as amount_cents, null::text as currency,
           gp.occurrence_id as occurrence_id, null::uuid as booking_id, null::uuid as membership_id
      from guest_passes gp
      join class_occurrences o on o.id = gp.occurrence_id
      left join class_types ct on ct.id = o.class_type_id
      left join members g on g.id = gp.guest_member_id
     where gp.host_member_id = p_member_id and gp.invited_at is not null
    union all
    -- Decision 97: invited by a host (this member is the guest). The host
    -- name is the invite snapshot, surviving the host's deletion or merge.
    select gp.invited_at as at, 'invited_by' as kind,
           'Invited by ' || coalesce(gp.host_name_at_invite, 'a member') as title,
           null::text as detail,
           null::uuid as ledger_id, null::int as amount_cents, null::text as currency,
           gp.occurrence_id as occurrence_id, null::uuid as booking_id, null::uuid as membership_id
      from guest_passes gp
     where gp.guest_member_id = p_member_id and gp.host_member_id is not null and gp.invited_at is not null
    union all
    -- Decision 97 (a): a member merged into this account (staff only). Read from
    -- the member.merged audit row so a past merge shows and the removed email survives.
    select al.created_at as at, 'merged' as kind,
           'Merged ' || coalesce(al.before->>'removed_email', 'an account') || ' into this account' as title,
           null::text as detail,
           null::uuid, null::int, null::text, null::uuid, null::uuid, null::uuid
      from audit_logs al
     where al.action = 'member.merged' and v_is_staff
       and (al.after->>'merged_into')::uuid = p_member_id
    union all
    -- Decision 100: a staff member booked a class for this member (staff only).
    -- Read from the booking.booked_by_staff audit row so the attribution survives.
    select al.created_at as at, 'booked_by_staff' as kind,
           'Booked by ' || coalesce(al.after->>'staff_first', 'the studio')
             || coalesce(' with ' || (al.after->>'source'), '') as title,
           null::text as detail,
           null::uuid, null::int, null::text, null::uuid, null::uuid, null::uuid
      from audit_logs al
     where al.action = 'booking.booked_by_staff' and v_is_staff
       and al.entity_id = p_member_id
    union all
    -- Decision 92 (b): removed from a class by staff. From the audit row, so the
    -- class name and the staff first name survive.
    select al.created_at as at, 'removed_by_studio' as kind,
           'Removed from ' || coalesce(al.after->>'class_name', 'a class')
             || ' by ' || coalesce(al.after->>'staff_first', 'the studio') as title,
           null::text as detail,
           null::uuid, null::int, null::text, null::uuid, al.entity_id, null::uuid
      from audit_logs al
     where al.action = 'booking.removed_by_staff' and v_is_staff
       and (al.before->>'member_id')::uuid = p_member_id

    union all
    -- booked / waitlisted / free first
    select b.booked_at,
           case when b.status = 'pending_payment' and b.payment_source = 'comp' then 'reservation_hold'
                when b.status = 'waitlisted' then 'waitlisted'
                when b.payment_source = 'comp'
                     and exists (select 1 from guest_passes gp where gp.guest_booking_id = b.id and gp.host_member_id is null)
                     then 'free_first'
                else 'booked' end,
           case when b.status = 'pending_payment' and b.payment_source = 'comp' then 'Payment pending for ' || coalesce(o.name, 'a class')
                when b.status = 'waitlisted' then 'Joined the waitlist for ' || coalesce(o.name, 'a class')
                when b.payment_source = 'comp'
                     and exists (select 1 from guest_passes gp where gp.guest_booking_id = b.id and gp.host_member_id is null)
                     then 'Booked a free first class — ' || coalesce(o.name, 'a class')
                when b.payment_source = 'group' then
                     (select case when gb.is_host
                                  then 'Group booking — ' || coalesce(o.name, 'a class') || ' · ' || mp.name
                                  else 'Booked by ' || hm.first_name || ' · ' || mp.name end
                        from group_bookings gb
                        join group_purchases gpu on gpu.id = gb.group_purchase_id
                        join membership_plans mp on mp.id = gpu.plan_id
                        join members hm on hm.id = gpu.host_member_id
                       where gb.booking_id = b.id)
                else 'Booked ' || coalesce(o.name, 'a class') end,
           case when b.payment_source = 'group' then
                  (select case when gb.is_host then (
                            select string_agg(coalesce(nullif(m2.first_name,''), m2.email), ', ')
                              from group_bookings gb2 join members m2 on m2.id = gb2.member_id
                             where gb2.group_purchase_id = gb.group_purchase_id and not gb2.is_host)
                          end
                     from group_bookings gb where gb.booking_id = b.id)
                when exists (select 1 from waitlist_offers wo where wo.booking_id = b.id and wo.outcome = 'accepted')
                then 'From the waitlist' end,
           b.credit_entry_id, null, null, b.occurrence_id, b.id, b.membership_id
      from bookings b left join class_occurrences o on o.id = b.occurrence_id
     where b.member_id = p_member_id
       and b.status in ('booked','attended','no_show','cancelled','late_cancelled','waitlisted','pending_payment')
    union all
    -- cancelled (carries the cancellation_refund, or 0 "class used")
    select b.cancelled_at,
           case when b.payment_source = 'comp'
                     and not exists (select 1 from guest_passes gp where gp.guest_booking_id = b.id and gp.host_member_id is null)
                     and not exists (select 1 from payments p2 where p2.booking_id = b.id and p2.kind = 'reservation_fee' and p2.status in ('succeeded','partially_refunded'))
                     then 'hold_released'
                when b.release_reason = 'studio_released' then 'studio_cancelled'
                when b.status = 'late_cancelled' or b.is_late_cancel then 'late_cancelled'
                else 'cancelled' end,
           case when b.payment_source = 'comp'
                     and not exists (select 1 from guest_passes gp where gp.guest_booking_id = b.id and gp.host_member_id is null)
                     and not exists (select 1 from payments p2 where p2.booking_id = b.id and p2.kind = 'reservation_fee' and p2.status in ('succeeded','partially_refunded'))
                     then 'Reservation hold released'
                when b.release_reason = 'studio_released' then 'Studio cancelled ' || coalesce(o.name, 'a class')
                when b.status = 'late_cancelled' or b.is_late_cancel then 'Cancelled late — ' || coalesce(o.name, 'a class')
                else 'Cancelled ' || coalesce(o.name, 'a class') end,
           case when b.release_reason = 'studio_released' then 'Credit returned'
                when (b.status = 'late_cancelled' or b.is_late_cancel)
                     and not exists (select 1 from led cl where cl.booking_id = b.id and cl.reason = 'cancellation_refund')
                then 'Class used' end,
           (select cl.id from led cl where cl.booking_id = b.id and cl.reason = 'cancellation_refund' order by cl.created_at, cl.id limit 1),
           null, null, b.occurrence_id, b.id, b.membership_id
      from bookings b left join class_occurrences o on o.id = b.occurrence_id
     where b.member_id = p_member_id and b.status in ('cancelled','late_cancelled')
       and not exists (select 1 from audit_logs al
                        where al.action = 'booking.removed_by_staff' and al.entity_id = b.id)
    union all
    -- checked in / attended
    select ci.checked_in_at, 'attended',
           case when o.id is null then 'Attended a class (imported)' else 'Attended ' || o.name end,
           null, null::uuid, null, null, ci.occurrence_id, ci.booking_id, null
      from check_ins ci left join class_occurrences o on o.id = ci.occurrence_id
     where ci.member_id = p_member_id
    union all
    -- no-show
    select coalesce(b.no_show_at, o.ends_at, b.updated_at), 'no_show',
           'Did not attend ' || coalesce(o.name, 'a class'), null,
           null::uuid, null, null, b.occurrence_id, b.id, b.membership_id
      from bookings b left join class_occurrences o on o.id = b.occurrence_id
     where b.member_id = p_member_id and b.status = 'no_show'
    union all
    -- purchase / refund / failed payment (carries the matched grant/forfeit)
    select coalesce(p.paid_at, p.created_at),
           case when p.refunded_at is not null or p.status in ('refunded','partially_refunded') then 'refund'
                when p.status = 'failed' then 'payment_failed'
                when p.kind = 'reservation_fee'
                     and exists (select 1 from bookings b2 where b2.id = p.booking_id and b2.status in ('no_show','late_cancelled'))
                     and not exists (select 1 from member_credits mc2 where mc2.booking_id = p.booking_id and mc2.reason = 'reservation_credit' and mc2.voided_at is null)
                     then 'reservation_fee_kept'
                when p.kind = 'reservation_fee' then 'reservation_fee_paid'
                else 'purchase' end,
           case when p.refunded_at is not null or p.status in ('refunded','partially_refunded') then 'Refund — ' || coalesce(p.description, 'a payment')
                when p.status = 'failed' then 'Payment failed — ' || coalesce(p.description, 'a payment')
                when p.kind = 'reservation_fee'
                     and exists (select 1 from bookings b2 where b2.id = p.booking_id and b2.status in ('no_show','late_cancelled'))
                     and not exists (select 1 from member_credits mc2 where mc2.booking_id = p.booking_id and mc2.reason = 'reservation_credit' and mc2.voided_at is null)
                     then 'Reservation fee kept'
                when p.kind = 'reservation_fee' then 'Reservation fee paid'
                else 'Bought ' || coalesce(p.description, 'a plan') end,
           null,
           case when p.refunded_at is not null or p.status in ('refunded','partially_refunded')
                then (select ledger_id from pay_forfeit pf where pf.payment_id = p.id)
                when p.status = 'failed' then null
                else (select ledger_id from pay_grant pg where pg.payment_id = p.id) end,
           case when p.refunded_at is not null then coalesce(p.refunded_cents, p.amount_cents) else p.amount_cents end,
           p.currency, null::uuid, p.booking_id, p.membership_id
      from payments p where p.member_id = p_member_id
    union all
    -- rescheduled / instructor changed, for occurrences the member holds a live booking on
    select oe.at,
           case when oe.kind = 'moved' then 'rescheduled' else 'instructor_changed' end,
           case when oe.kind = 'moved' then 'Class rescheduled — ' || coalesce(o.name, 'a class')
                else 'Instructor changed — ' || coalesce(o.name, 'a class') end,
           null, null::uuid, null, null, oe.occurrence_id, null, null
      from occurrence_events oe left join class_occurrences o on o.id = oe.occurrence_id
     where oe.kind in ('moved','instructor_changed')
       and exists (select 1 from bookings b where b.occurrence_id = oe.occurrence_id
                    and b.member_id = p_member_id and b.status <> 'cancelled')
    union all
    -- message_sent (staff only)
    select coalesce(msg.sent_at, msg.updated_at), 'message_sent', 'Message sent', msg.subject,
           null::uuid, null, null, null, null, null
      from messages msg
     where msg.member_id = p_member_id and v_is_staff and msg.status in ('queued','sent')
    union all
    -- contacted (staff only) — a task contacted the old way (no member_contacts
    -- row). A task linked to a contact (contact_id set) shows via the arm below.
    select mt.contacted_at, 'contacted', 'Contacted', mt.reason,
           null::uuid, null, null, null, null, null
      from member_tasks mt
     where mt.member_id = p_member_id and v_is_staff
       and mt.status = 'contacted' and mt.contacted_at is not null
       and mt.contact_id is null
    union all
    -- Decision 79: retention outreach logged in member_contacts (staff only).
    select mc.contacted_at, 'contacted',
           case when mc.method = 'email' then 'Emailed'
                when mc.method = 'viber' then 'Contacted (Viber)'
                when mc.method = 'call'  then 'Called'
                else 'Contacted (in person)' end
             || coalesce(' by ' || nullif(pr.full_name, ''), ''),
           mc.subject,
           null::uuid, null, null, null, null, null
      from member_contacts mc
      left join profiles pr on pr.id = mc.staff_id
     where mc.member_id = p_member_id and v_is_staff
    union all
    -- Decision 83 (a): a plan that ended (expired, or ended by staff) — NOT
    -- a refund, which tells its own story. Claims the end-forfeit ledger row
    -- so it is not also a bare "Credit adjustment"; unused = classes forfeited.
    select coalesce(ms2.cancelled_at, (ms2.expires_on)::timestamptz), 'plan_ended', 'Plan ended', null,
           (select cl.id from led cl
             where cl.membership_id = ms2.id and cl.reason = 'manual' and cl.delta < 0
               and cl.id not in (select ledger_id from pay_forfeit)
             order by cl.created_at desc, cl.id desc limit 1),
           null, null, null::uuid, null, ms2.id
      from memberships ms2
     where ms2.member_id = p_member_id
       and ms2.status in ('cancelled','expired')
       and coalesce(ms2.cancelled_at, (ms2.expires_on)::timestamptz) is not null
       and not exists (select 1 from payments p where p.membership_id = ms2.id
                        and (p.refunded_at is not null or p.status in ('refunded','partially_refunded')))
    union all
    -- Decision 103(e): reservation credit granted (attended, on-time cancel, or a
    -- lost seat). From member_credits, which the Journey did not read before.
    select mc.created_at, 'reservation_credit_back', 'Fee credited back', null::text,
           null::uuid, mc.amount_cents, mc.currency::text, null::uuid, mc.booking_id, null::uuid
      from member_credits mc
     where mc.member_id = p_member_id and mc.voided_at is null
       and mc.reason in ('reservation_credit', 'reservation_lost_seat')
    union all
    -- Decision 103(e): a released hold re-booked after the payment, or a
    -- reservation covered by credit. From audit_logs (entity = the booking).
    select al.created_at,
           case when al.action = 'reservation.credit_used' then 'reservation_credit_used'
                else 'reservation_restored' end,
           case when al.action = 'reservation.credit_used' then 'Credit used for a reservation'
                else 'Seat restored after payment' end,
           null::text, null::uuid, null::int, null::text, null::uuid, al.entity_id, null::uuid
      from audit_logs al
     where al.entity_table = 'bookings'
       and al.action in ('reservation.restored', 'reservation.repaired', 'reservation.credit_used')
       and exists (select 1 from bookings b where b.id = al.entity_id and b.member_id = p_member_id)
  ),
  claimed as (select distinct ledger_id from ev where ledger_id is not null),
  -- ledger rows no event claims: complimentary grants, manual adjustments,
  -- lockout, merch. Shown as their own credit lines.
  adj as (
    select l.created_at as at,
           case when l.reason = 'booking' then 'credit_used'
                when l.delta >= 0 then 'credits_added' else 'credit_adjustment' end as kind,
           case when l.reason = 'booking' then 'Class credit used'
                when l.reason = 'cancellation_refund' then 'Credit returned'
                when l.delta >= 0 then 'Credits added' else 'Credit adjustment' end as title,
           null::text as detail, l.id as ledger_id, null::int as amount_cents, null::text as currency,
           null::uuid as occurrence_id, l.booking_id, l.membership_id
      from led l where l.id not in (select ledger_id from claimed where ledger_id is not null)
  ),
  all_rows as (
    select * from ev
    union all
    select * from adj
  )
  select
    x.at, x.kind, x.title, x.detail,
    coalesce(l.delta, 0) as credit_delta,
    coalesce(l.bal,
             (select l2.bal from led l2 where l2.created_at <= x.at order by l2.created_at desc, l2.id desc limit 1),
             0) as balance_after,
    x.amount_cents, x.currency, x.occurrence_id, x.booking_id, x.membership_id,
    -- Decision 83. plan_name: the plan a booking drew from, a cancellation or a
    -- no-show consumed/returned to, or the ended plan. null on every other kind.
    case when x.kind in ('booked','cancelled','late_cancelled','studio_cancelled','no_show','plan_ended')
         then mp.name end as plan_name,
    -- due_cents: a LIVE unpaid drop-in booking only — the cheapest active public
    -- drop_in plan price, what Pay-now charges (bookings store no per-row price).
    case when x.kind = 'booked' and exists (
           select 1 from bookings b
            where b.id = x.booking_id and b.payment_source = 'drop_in' and b.status = 'booked'
              and not exists (select 1 from payments p
                               where p.booking_id = b.id and p.status in ('succeeded','partially_refunded')))
         then (select dp.price_cents from membership_plans dp
                where dp.studio_id = v_studio and dp.type = 'drop_in'
                  and dp.visibility = 'public' and dp.status = 'active'
                order by dp.price_cents asc, dp.sort_order asc, dp.id limit 1)
         end as due_cents,
    -- is_free_first: true on a free-first comp booking AND on its later cancel /
    -- no-show rows, so the helper can say "Free class used" / "Free class kept".
    (x.booking_id is not null and exists (
       select 1 from bookings b join guest_passes gp on gp.guest_booking_id = b.id
        where b.id = x.booking_id and b.payment_source = 'comp' and gp.host_member_id is null))
      as is_free_first,
    -- Decision 83 (a): the class instant + instructor, for the "{Day} {date},
    -- {time} with {instructor}" line (rowLine renders in the studio timezone).
    occ.starts_at as occurrence_start,
    nullif(split_part(coalesce(inst.display_name, ''), ' ', 1), '') as instructor_first,
    -- credits_left_after: the plan balance after this row. A no-show and a late
    -- cancel that used the credit carry no ledger of their own (the credit was
    -- spent at booking), so read that booking's consume row; a late cancel that
    -- refunded (consumes-off) has a refund ledger row, so coalesce keeps it. null
    -- = no plan credit touched (free first, unlimited, drop-in, money rows).
    case when x.kind in ('no_show','late_cancelled')
         then coalesce(l.membership_bal,
                       (select l2.membership_bal from led l2 join bookings b2 on b2.credit_entry_id = l2.id
                         where b2.id = x.booking_id))
         else l.membership_bal end as credits_left_after,
    -- payment_method / recorded_by_name: the money row's own payment (lateral,
    -- keyed on member + the arm's `at`). recorded_by is null for an online
    -- payment, so recorded_by_name is null unless it was taken at the desk.
    pm.method as payment_method,
    rec.full_name as recorded_by_name,
    case when x.kind = 'purchase' then coalesce(mp.credits, mp.credits_per_period) end as plan_classes,
    case when x.kind = 'purchase' then ms.expires_on end as plan_valid_to,
    case when x.kind = 'plan_ended' then abs(coalesce(l.delta, 0)) end as unused_credits,
    -- Decision 83 (a) follow-up: the booking's own payment_source (comp / drop_in /
    -- class_pack / membership / group), null for a non-booking row; and whether a
    -- booking row has a succeeded or partially_refunded payment, null otherwise.
    -- rowLine reads these to say "Complimentary" vs "Drop-in, paid" vs "due".
    (select b.payment_source::text from bookings b where b.id = x.booking_id) as payment_source,
    case when x.booking_id is not null
         then exists (select 1 from payments p
                       where p.booking_id = x.booking_id and p.status in ('succeeded','partially_refunded'))
         end as is_paid
  from all_rows x
  left join led l on l.id = x.ledger_id
  left join memberships ms on ms.id = x.membership_id
  left join membership_plans mp on mp.id = ms.plan_id
  left join class_occurrences occ on occ.id = x.occurrence_id
  left join instructors inst on inst.id = occ.instructor_id
  left join lateral (
    select p2.method, p2.recorded_by
      from payments p2
     where x.kind in ('purchase','refund','payment_failed')
       and p2.member_id = p_member_id
       and coalesce(p2.paid_at, p2.created_at) = x.at
     order by p2.id limit 1) pm on true
  left join profiles rec on rec.id = pm.recorded_by
  where x.at is not null and x.at::date between p_from and p_to
  order by x.at desc, x.kind;
end $function$;
revoke execute on function member_activity(uuid, date, date) from public, anon;
grant  execute on function member_activity(uuid, date, date) to authenticated, service_role;


-- ---- saleshist ----
create or replace function sales_history(
  p_studio_id uuid, p_from date, p_to date,
  p_plan_id uuid default null, p_status text default null
) returns table (
  membership_id uuid, member_id uuid, member_name text,
  plan_id uuid, plan_name text, plan_type text,
  amount_cents int, currency char(3), payment_source text,
  bought_on timestamptz, starts_on date, expires_on date, sale_status text,
  is_renewal boolean
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
                when pay.provider = 'xendit' then 'Card (Xendit)'
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
          end) as sale_status,
         -- Decision 66: the row is a renewal when its membership has more than
         -- one succeeded payment (the shown one is the latest). No shape change.
         (select count(*) from payments p2
           where p2.membership_id = ms.id
             and p2.status in ('succeeded', 'partially_refunded')) > 1 as is_renewal
    from memberships ms
    join members m on m.id = ms.member_id
    join membership_plans mp on mp.id = ms.plan_id
    left join pay on pay.membership_id = ms.id
   where ms.studio_id = p_studio_id
     and not coalesce(ms.complimentary, false)
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

  union all

  -- Decision 63: merchandise sales. plan_type 'merch'; no membership, so never
  -- a renewal.
  select null::uuid, p.member_id,
         coalesce(m.first_name || ' ' || m.last_name, 'Walk-in') as member_name,
         null::uuid, (pr.name || ' ×' || po.quantity) as plan_name, 'merch' as plan_type,
         p.amount_cents, p.currency,
         (case when p.provider = 'xendit' then 'Card (Xendit)'
               when p.provider = 'stripe' then 'Card (Stripe)'
               when p.method = 'gcash' then 'GCash'
               when p.method = 'bank_transfer' then 'Bank transfer'
               when p.method = 'card_terminal' then 'Card (terminal)'
               when p.method = 'cash' then 'Cash'
               when p.method = 'other' then 'Other'
               else 'Recorded' end) as payment_source,
         coalesce(p.paid_at, p.created_at) as bought_on,
         null::date, null::date,
         (case when p.status in ('refunded','partially_refunded') or coalesce(p.refunded_cents,0) > 0
               then 'refunded' else 'active' end) as sale_status,
         false as is_renewal
    from payments p
    join product_orders po on po.id = p.product_order_id
    join products pr on pr.id = po.product_id
    left join members m on m.id = p.member_id
   where p.studio_id = p_studio_id and p.status in ('succeeded','partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1
     and p_plan_id is null
     and (p_status is null or p_status = (case
            when p.status in ('refunded','partially_refunded') or coalesce(p.refunded_cents,0) > 0
            then 'refunded' else 'active' end))

  union all

  -- Decision 103(e): reservation fees paid online (real money). plan_type
  -- 'reservation_fee'; no membership. A credit-covered reservation writes no
  -- payment, so these rows are always cash received.
  select null::uuid, p.member_id,
         coalesce(m.first_name || ' ' || m.last_name, 'Walk-in') as member_name,
         null::uuid, ('Reservation · ' || coalesce(o.name, 'a class')) as plan_name,
         'reservation_fee' as plan_type,
         p.amount_cents, p.currency,
         (case when p.provider = 'xendit' then 'Card (Xendit)'
               when p.provider = 'stripe' then 'Card (Stripe)'
               when p.method = 'gcash' then 'GCash'
               when p.method = 'card_terminal' then 'Card (terminal)'
               when p.method = 'cash' then 'Cash'
               else 'Recorded' end) as payment_source,
         coalesce(p.paid_at, p.created_at) as bought_on,
         null::date, null::date,
         (case when p.status in ('refunded','partially_refunded') or coalesce(p.refunded_cents,0) > 0
               then 'refunded' else 'active' end) as sale_status,
         false as is_renewal
    from payments p
    left join bookings b on b.id = p.booking_id
    left join class_occurrences o on o.id = b.occurrence_id
    left join members m on m.id = p.member_id
   where p.studio_id = p_studio_id and p.kind = 'reservation_fee'
     and coalesce(p.method, '') <> 'reservation_credit'
     and p.status in ('succeeded','partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1
     and p_plan_id is null
     and (p_status is null or p_status = (case
            when p.status in ('refunded','partially_refunded') or coalesce(p.refunded_cents,0) > 0
            then 'refunded' else 'active' end))

  order by bought_on desc;
end $$;
revoke all on function sales_history(uuid, date, date, uuid, text) from public, anon;
grant execute on function sales_history(uuid, date, date, uuid, text) to authenticated, service_role;


-- ---- salestot ----
create or replace function sales_totals(
  p_studio_id uuid, p_from date, p_to date,
  p_plan_id uuid default null, p_status text default null
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_currency char(3); v_count int; v_gross bigint; v_refunded bigint; v_studio_total bigint;
  v_f0 timestamptz; v_t1 timestamptz; v_resv_count int; v_resv_total bigint;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'sales are for owners and managers' using errcode = 'PT403';
  end if;
  select currency into v_currency from studios s where s.id = p_studio_id;
  select day_start into v_f0 from studio_day_bounds(p_studio_id, p_from);
  select day_start into v_t1 from studio_day_bounds(p_studio_id, p_to + 1);

  select count(*) into v_count
    from sales_history(p_studio_id, p_from, p_to, p_plan_id, p_status);

  -- Gross/refunded over the filtered set: membership sales (by plan filter) OR
  -- merchandise sales. A plan filter excludes merch (merch has no plan).
  select coalesce(sum(p.amount_cents), 0)::bigint,
         coalesce(sum(p.refunded_cents), 0)::bigint
    into v_gross, v_refunded
    from payments p
    left join memberships ms on ms.id = p.membership_id
   where p.studio_id = p_studio_id
     and p.status in ('succeeded', 'partially_refunded')
     and (p.membership_id is not null or p.product_order_id is not null)
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1
     and (p_plan_id is null or ms.plan_id = p_plan_id);

  v_studio_total := studio_revenue_between(p_studio_id, v_f0, v_t1);

  -- Decision 103(e): reservation fees as their own line (cash received; a
  -- credit-covered reservation writes no payment, so method excludes it).
  select count(*), coalesce(sum(p.amount_cents - coalesce(p.refunded_cents, 0)), 0)::bigint
    into v_resv_count, v_resv_total
    from payments p
   where p.studio_id = p_studio_id and p.kind = 'reservation_fee'
     and coalesce(p.method, '') <> 'reservation_credit'
     and p.status in ('succeeded', 'partially_refunded')
     and coalesce(p.paid_at, p.created_at) >= v_f0
     and coalesce(p.paid_at, p.created_at) <  v_t1;

  return jsonb_build_object(
    'reservation_fees', jsonb_build_object('count', v_resv_count, 'total_cents', v_resv_total),
    'count', v_count,
    'gross_cents', v_gross,
    'refunded_cents', v_refunded,
    'net_cents', v_gross - v_refunded,
    'studio_total_cents', v_studio_total,
    'currency', v_currency);
end $$;


-- ---- dashrev ----
create or replace function dashboard_revenue(
  p_studio_id uuid, p_from date, p_to date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tz text; v_currency char(3); v_today date;
  v_f0 timestamptz; v_t1 timestamptz;
  v_span int; v_pf0 timestamptz; v_pt1 timestamptz;
  v_total bigint; v_prior bigint; v_refunds bigint; v_ever bigint;
  v_series jsonb; v_sources jsonb; v_counts jsonb;
begin
  if not (is_manager_up(p_studio_id) or is_service_context()) then
    raise exception 'revenue is for owners and managers' using errcode = 'PT403';
  end if;
  select s.timezone, s.currency into v_tz, v_currency from studios s where s.id = p_studio_id;
  if v_tz is null then raise exception 'no such studio' using errcode = 'PT404'; end if;
  if p_to < p_from then
    raise exception 'the range ends before it starts' using errcode = 'PT422';
  end if;

  v_today := studio_today(p_studio_id);
  select day_start into v_f0 from studio_day_bounds(p_studio_id, p_from);
  select day_start into v_t1 from studio_day_bounds(p_studio_id, p_to + 1);
  v_span := (p_to - p_from) + 1;
  select day_start into v_pf0 from studio_day_bounds(p_studio_id, p_from - v_span);
  select day_start into v_pt1 from studio_day_bounds(p_studio_id, p_from);

  v_total := studio_revenue_between(p_studio_id, v_f0, v_t1);
  v_prior := studio_revenue_between(p_studio_id, v_pf0, v_pt1);
  select coalesce(sum(p.amount_cents),0)::bigint into v_ever from payments p
   where p.studio_id = p_studio_id and p.status in ('succeeded','partially_refunded');

  select coalesce(sum(r.amount_cents),0)::bigint into v_refunds
    from refunds r join payments p on p.id = r.payment_id
   where p.studio_id = p_studio_id
     and r.created_at >= v_f0 and r.created_at < v_t1;

  select coalesce(jsonb_agg(jsonb_build_object('date', d.day, 'cents', coalesce(x.cents,0))
                            order by d.day), '[]'::jsonb)
    into v_series
    from generate_series(p_from, p_to, interval '1 day') g(day_ts)
    cross join lateral (select g.day_ts::date as day) d
    left join lateral (
      select coalesce(sum(p.amount_cents),0)::bigint as cents
        from payments p
       where p.studio_id = p_studio_id and p.status in ('succeeded','partially_refunded')
         and (coalesce(p.paid_at, p.created_at) at time zone v_tz)::date = d.day
    ) x on true;

  with classified as (
    select p.amount_cents,
           case
             when p.product_order_id is not null then 'merch'
             when p.kind = 'reservation_fee' and coalesce(p.method, '') <> 'reservation_credit' then 'reservation'
             when ct.session_kind in ('private','duo','trio') then 'private'
             when pl.type = 'recurring'  then 'membership'
             when pl.type = 'class_pack' then 'pack'
             when pl.type = 'trial'      then 'trial'
             when b.payment_source = 'drop_in' then 'drop_in'
             when pl.type = 'drop_in'    then 'drop_in'
             else 'other'
           end as src
      from payments p
      left join memberships ms on ms.id = p.membership_id
      left join membership_plans pl on pl.id = ms.plan_id
      left join bookings b on b.id = p.booking_id
      left join class_occurrences o on o.id = b.occurrence_id
      left join class_types ct on ct.id = o.class_type_id
     where p.studio_id = p_studio_id and p.status in ('succeeded','partially_refunded')
       and coalesce(p.paid_at, p.created_at) >= v_f0
       and coalesce(p.paid_at, p.created_at) <  v_t1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'source', src, 'label', dashboard_source_label(src), 'cents', cents,
           'pct', case when v_total = 0 then 0 else round(100.0 * cents / v_total) end)
           order by cents desc), '[]'::jsonb)
    into v_sources
    from (select src, sum(amount_cents)::bigint as cents from classified group by src) s;

  select jsonb_build_object(
      'bookings', (select count(*) from bookings b
                    where b.studio_id = p_studio_id and b.status <> 'waitlisted'
                      and b.booked_at >= v_f0 and b.booked_at < v_t1),
      'memberships_sold', (select count(*) from memberships ms
                    where ms.studio_id = p_studio_id
                      and ms.created_at >= v_f0 and ms.created_at < v_t1
                      and not coalesce(ms.complimentary, false)),
      'refunds_cents', v_refunds)
    into v_counts;

  return jsonb_build_object(
    'from', p_from, 'to', p_to, 'days', v_span, 'currency', v_currency,
    'state', case when v_ever = 0 then 'empty' else 'ok' end,
    'total_cents', v_total,
    'trend', dashboard_trend(v_total, v_prior, 'the ' || v_span || ' days before'),
    'series', v_series, 'by_source', v_sources, 'counts', v_counts,
    'empty_hint', 'Every payment you take shows up here — by day, and split by what it was for. Record a payment at the desk or connect Stripe and this starts filling.');
end $$;


-- ---- srclabel ----
create or replace function dashboard_source_label(p_src text) returns text
language sql immutable as $$
  select case p_src
    when 'membership' then 'Memberships'
    when 'pack'       then 'Class packs'
    when 'drop_in'    then 'Drop-ins'
    when 'private'    then 'Private sessions'
    when 'trial'      then 'Trials'
    when 'merch'      then 'Merchandise'
    when 'reservation' then 'Reservation fees'
    else 'Other' end
$$;

-- --- Anon stays EXACTLY THIRTEEN -------------------------------------------
do $mig$ declare n int; begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % (want 13)', n; end if;
end $mig$;
