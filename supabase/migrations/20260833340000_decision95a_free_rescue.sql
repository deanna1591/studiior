-- =============================================================================
-- Decision 95 amendment (a) — free first class rescue twins (11 Nov 2026)
-- =============================================================================
-- When the under-minimum flex booking is a FREE FIRST class (a comp seat with a
-- host-null guest_passes row, the Decision 30 signature), the sweep queues
-- free_rescue_2days / free_rescue_final instead of the flex pair — same timing,
-- same suppression, SAME dedupe keys (flex_rescue_2days:{booking} /
-- flex_rescue_final:{booking}, so a booking still gets one email per phase
-- whichever variant), same {class_list_core} and move link. The bodies say
-- "free class" instead of "credit" and end with the reminder that the free
-- class is kept when they move or when the class does not run.
--
-- The hourly cron (studiior-flex-rescue :: 0 * * * *) is unchanged; the free
-- twins ride the existing job.
--
-- No new anon RPC — anon stays EXACTLY THIRTEEN (asserted at apply).
--
-- re-issues: sweep_flex_rescue(timestamptz), member_activity(uuid, date, date)
-- =============================================================================

-- --- (1) templates (platform defaults, 80a frame) ---------------------------
insert into notification_templates (key, subject, text_body, html_body, note) values (
 'free_rescue_2days',
 'Your free {class_name} on {day} still needs {n_more} more to run',
 E'Hi {first_name},\n\nYour free {class_name} on {day} is a flex class, and it still needs {n_more} more booked to go ahead. Want a class that is already running? Move your free spot in one tap:\n\n{class_list_core_text}\n\nYour free class is kept when you move, or if this class does not run.\n\nSee you in class,\n{studio_name}',
 '<p>Hi {first_name},</p>'
 '<p>Your free <strong>{class_name}</strong> on {day} is a flex class, and it still needs <strong>{n_more}</strong> more booked to go ahead. Want a class that is already running? Move your free spot in one tap:</p>'
 '{class_list_core}'
 '<p>Your free class is kept when you move, or if this class does not run.</p>'
 '<p>See you in class,<br>{studio_name}</p>',
 'Decision 95(a). Sent 2 days before a free first class booked into an '
 'under-minimum flex class. Tokens: first_name, class_name, day, n_more, '
 'class_list_core, class_list_core_text, studio_name.')
on conflict (key) do nothing;

insert into notification_templates (key, subject, text_body, html_body, note) values (
 'free_rescue_final',
 'Last call: move your free class before {cutoff_time}',
 E'Hi {first_name},\n\nLast call. Your free {class_name} on {day} still needs {n_more} more to run, and the studio decides by {cutoff_time}. Move to a class that is already going ahead in one tap:\n\n{class_list_core_text}\n\nYour free class is kept when you move, or if this class does not run.\n\nSee you in class,\n{studio_name}',
 '<p>Hi {first_name},</p>'
 '<p>Last call. Your free <strong>{class_name}</strong> on {day} still needs <strong>{n_more}</strong> more to run, and the studio decides by {cutoff_time}. Move to a class that is already going ahead in one tap:</p>'
 '{class_list_core}'
 '<p>Your free class is kept when you move, or if this class does not run.</p>'
 '<p>See you in class,<br>{studio_name}</p>',
 'Decision 95(a). Sent {flex_rescue_hours_before} hours before the flex cut-off '
 'for a free first class still under its minimum. Tokens: first_name, class_name, '
 'day, n_more, cutoff_time, class_list_core, class_list_core_text, studio_name.')
on conflict (key) do nothing;

-- --- (2) sweep_flex_rescue — re-issued to pick the free pair -----------------
-- From the newest definition (20260833330000). The only change: a free-first
-- booking (comp + host-null guest_passes) uses free_rescue_* instead of
-- flex_rescue_*. Dedupe keys, timing, suppression and payload are unchanged.
create or replace function sweep_flex_rescue(p_now timestamptz default now())
returns jsonb
language plpgsql security definer set search_path = public as $function$
declare
  r record; s studios%rowtype; st studio_settings%rowtype; v_tz text; v_fmt text;
  v_min int; v_booked int; v_n_more int; v_deadline timestamptz; v_send timestamptz;
  v_html text; v_txt text; v_day text; v_cutoff text; v_two int := 0; v_fin int := 0; v_key text;
  v_tpl2 text; v_tplf text;
begin
  for r in
    select b.id as booking_id, b.member_id, o.id as occ_id, o.studio_id, o.starts_at,
           coalesce(nullif(o.name, ''), ct.name) as class_name,
           coalesce(o.minimum_bookings, 0) as min_src,
           (b.payment_source = 'comp' and exists (
              select 1 from guest_passes gp
               where gp.guest_booking_id = b.id and gp.host_member_id is null)) as is_free_first
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
      join class_types ct on ct.id = o.class_type_id
     where b.status in ('booked','pending_payment')
       and o.status = 'scheduled'
       and o.flex
       and o.flex_reached_minimum_at is null
       and o.committed_at is null
       and o.starts_at > p_now
       and o.starts_at < p_now + interval '9 days'
  loop
    select * into s from studios where id = r.studio_id;
    select * into st from studio_settings where studio_id = r.studio_id;
    v_tz := s.timezone; v_fmt := coalesce(st.time_format, '24h');
    v_min := greatest(coalesce(nullif(r.min_src, 0),
                               coalesce(st.flex_min_bookings, 1)), 1);
    v_booked := occurrence_seats_taken(r.occ_id);
    v_n_more := greatest(v_min - v_booked, 1);
    v_day := to_char(r.starts_at at time zone v_tz, 'FMDay FMDD FMMonth');
    -- Decision 95(a): a free first class gets the free twin, same keys/payload.
    v_tpl2 := case when r.is_free_first then 'free_rescue_2days' else 'flex_rescue_2days' end;
    v_tplf := case when r.is_free_first then 'free_rescue_final' else 'flex_rescue_final' end;

    if (p_now at time zone v_tz)::date = (r.starts_at at time zone v_tz)::date - 2 then
      v_send := quiet_hours_shift(
        ((r.starts_at at time zone v_tz)::date - 2 + time '10:00') at time zone v_tz, v_tz);
      v_key := 'flex_rescue_2days:' || r.booking_id::text;
      if not exists (select 1 from notifications where dedupe_key = v_key) then
        select html, txt into v_html, v_txt from flex_rescue_block(r.booking_id);
        perform queue_notification(r.studio_id, r.member_id, v_tpl2,
          jsonb_build_object('class_name', r.class_name, 'day', v_day, 'n_more', v_n_more,
            'class_list_core', v_html, 'class_list_core_text', v_txt,
            'studio_name', s.name, 'occurrence_id', r.occ_id),
          v_key, greatest(v_send, p_now));
        v_two := v_two + 1;
      end if;
    end if;

    select deadline_at into v_deadline from flex_deadline_for_run(r.occ_id);
    if v_deadline is not null
       and p_now >= v_deadline - make_interval(hours => coalesce(st.flex_rescue_hours_before, 3))
       and p_now < r.starts_at then
      v_cutoff := to_char(v_deadline at time zone v_tz, 'FMDy FMDD FMMon, ') || fmt_clock(v_deadline, v_tz, v_fmt);
      v_key := 'flex_rescue_final:' || r.booking_id::text;
      if not exists (select 1 from notifications where dedupe_key = v_key) then
        select html, txt into v_html, v_txt from flex_rescue_block(r.booking_id);
        perform queue_notification(r.studio_id, r.member_id, v_tplf,
          jsonb_build_object('class_name', r.class_name, 'day', v_day, 'n_more', v_n_more,
            'cutoff_time', v_cutoff, 'class_list_core', v_html, 'class_list_core_text', v_txt,
            'studio_name', s.name, 'occurrence_id', r.occ_id),
          v_key, p_now);
        v_fin := v_fin + 1;
      end if;
    end if;
  end loop;
  return jsonb_build_object('two_day', v_two, 'final', v_fin);
end $function$;
revoke execute on function sweep_flex_rescue(timestamptz) from public, anon, authenticated;
grant  execute on function sweep_flex_rescue(timestamptz) to service_role;

-- --- member_activity — rescue Journey arm broadened to the free twins ----
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
    -- booked / waitlisted / free first
    select b.booked_at,
           case when b.status = 'waitlisted' then 'waitlisted'
                when b.payment_source = 'comp'
                     and exists (select 1 from guest_passes gp where gp.guest_booking_id = b.id and gp.host_member_id is null)
                     then 'free_first'
                else 'booked' end,
           case when b.status = 'waitlisted' then 'Joined the waitlist for ' || coalesce(o.name, 'a class')
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
           case when b.release_reason = 'studio_released' then 'studio_cancelled'
                when b.status = 'late_cancelled' or b.is_late_cancel then 'late_cancelled'
                else 'cancelled' end,
           case when b.release_reason = 'studio_released' then 'Studio cancelled ' || coalesce(o.name, 'a class')
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
                else 'purchase' end,
           case when p.refunded_at is not null or p.status in ('refunded','partially_refunded') then 'Refund — ' || coalesce(p.description, 'a payment')
                when p.status = 'failed' then 'Payment failed — ' || coalesce(p.description, 'a payment')
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

-- --- Anon stays EXACTLY THIRTEEN --------------------------------------------
do $$ declare n int; begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % (want 13)', n; end if;
end $$;
