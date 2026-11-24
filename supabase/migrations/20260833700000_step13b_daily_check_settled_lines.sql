-- creates: pay_line_review_run(uuid)
-- re-issues: daily_money_check(uuid)
--
-- Step 13b, Decision 108 (c): the daily check respects settled lines.
-- Both pay items (12, a line differs from its own basis, and 12b, a line
-- differs from 75 (l)) read one helper, pay_line_review_run, which says
-- whether a line is settled (a pay.line_corrected, pay.line_voided or
-- pay.line_restored audit) and which tier the class had when it was decided
-- (recorded on the line, else the occurrence pin). Settled lines are skipped
-- by both; a class whose tier changed since it was decided is judged by its
-- recorded basis (item 12), never by today's tier (item 12b is not made).
-- daily_money_check is re-issued from 20260833690000 with only items 12 and
-- 12b changed.

create or replace function pay_line_review_run(p_line_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  ipr  instructor_pay_records%rowtype;
  v_today text;
  v_decision text;
  v_settled boolean;
  v_expected int;
begin
  select * into ipr from instructor_pay_records where id = p_line_id;
  if not found then return null; end if;

  v_settled := exists (select 1 from audit_logs a where a.entity_id = ipr.id
                        and a.action in ('pay.line_corrected','pay.line_voided','pay.line_restored'));

  if ipr.occurrence_id is not null then
    select g.tier into v_today from occurrence_guarantee_run(ipr.occurrence_id) g;
  end if;
  -- The tier at decision time: recorded on the line, else the occurrence's pin.
  v_decision := coalesce(ipr.basis ->> 'tier',
                         (select o.guarantee_tier::text from class_occurrences o where o.id = ipr.occurrence_id),
                         v_today);

  v_expected := case
      when (ipr.basis ->> 'full_house_total_cents') is not null then
        (ipr.basis ->> 'full_house_total_cents')::int
      when coalesce((ipr.basis ->> 'holding_fee')::boolean, false) then null
      when ipr.basis ? 'per_head_cents' and ipr.basis ? 'booked_paid' then
        (ipr.basis ->> 'base_cents')::int
        + greatest(0, (ipr.basis ->> 'booked_paid')::int - (ipr.basis ->> 'per_head_threshold')::int)
          * (ipr.basis ->> 'per_head_cents')::int
        + coalesce((ipr.basis ->> 'full_house_bonus_cents')::int, 0)
      when ipr.basis ->> 'outcome' = 'not_running' and v_decision = 'flex' then
        coalesce((ipr.basis ->> 'unmet_pay_cents')::int, 0) + coalesce((ipr.basis ->> 'standby_cents')::int, 0)
      when ipr.basis ->> 'outcome' = 'not_running' and v_decision in ('core','always') then
        case when ipr.basis ->> 'holding_model' = 'flat' then (ipr.basis ->> 'holding_flat_cents')::int
             else ((ipr.basis ->> 'base_cents')::int * coalesce((ipr.basis ->> 'holding_pct')::int, 0)) / 100 end
      end;

  return jsonb_build_object('settled', v_settled, 'decision_tier', v_decision,
                            'today_tier', v_today, 'basis_expected', v_expected);
end $$;
revoke all on function pay_line_review_run(uuid) from public, anon, authenticated;
grant execute on function pay_line_review_run(uuid) to service_role;

create or replace function daily_money_check(p_studio_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_tz text; v_items jsonb := '[]'::jsonb; v_html text := ''; v_text text := '';
  r record; v_n int; v_line text;
begin
  if not is_service_context() then
    raise exception 'the daily check runs as the backend' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;

  for r in
    -- 1. reservation fee paid, no seat, no credit
    select mname(b.member_id) || ': paid a reservation fee for ' || cname(b.occurrence_id)
           || ' but has no seat and no credit' as line
      from payments p
      join bookings b on b.id = p.booking_id
     where p.studio_id = p_studio_id and p.kind = 'reservation_fee'
       and p.status in ('succeeded','partially_refunded')
       and b.status in ('cancelled','late_cancelled')
       and not exists (select 1 from member_credits mc
                        where mc.booking_id = b.id and mc.reason = 'reservation_credit' and mc.voided_at is null)
    union all
    -- 2. a hold older than its window
    select mname(b.member_id) || ': the hold on ' || cname(b.occurrence_id)
           || ' expired ' || ago(b.hold_until) || ' and is still open'
      from bookings b
     where b.studio_id = p_studio_id and b.hold_until is not null and b.hold_until < now()
       and b.status in ('booked','pending_payment')
    union all
    -- 3. a succeeded payment attached to nothing
    select mname(p.member_id) || ': a succeeded payment of ' || money_txt(p.amount_cents, p.currency)
           || ' is attached to nothing'
      from payments p
     where p.studio_id = p_studio_id and p.status = 'succeeded'
       and p.membership_id is null and p.booking_id is null
       and p.product_order_id is null and p.group_purchase_id is null
       -- Decision 108 (b): a member-less payment (a gift card) is attached to its card.
       and p.member_id is not null
    union all
    -- 4. a member with an active plan still marked lead
    select mname(m.id) || ': has an active plan but is still marked lead'
      from members m
     where m.studio_id = p_studio_id and m.status = 'lead' and m.deleted_at is null
       and exists (select 1 from memberships ms where ms.member_id = m.id and ms.status = 'active')
    union all
    -- 5. a live booking in a cancelled or ended class
    select mname(b.member_id) || ': booked in ' || cname(b.occurrence_id)
           || case when o.status = 'cancelled' then ' which was cancelled' else ' which has already ended' end
      from bookings b join class_occurrences o on o.id = b.occurrence_id
     where b.studio_id = p_studio_id and b.status in ('booked','pending_payment')
       and (o.status = 'cancelled' or (o.status = 'scheduled' and o.ends_at < now()))
    union all
    -- 6. a member double-booked in one class
    select mname(x.member_id) || ': booked twice in ' || cname(x.occurrence_id)
      from (select member_id, occurrence_id from bookings
             where studio_id = p_studio_id and status in ('booked','attended','pending_payment')
             group by member_id, occurrence_id having count(*) > 1) x
    union all
    -- 7. a notification unsent for more than an hour
    select (select count(*) from notifications n
             where n.studio_id = p_studio_id and n.status = 'scheduled'
               and n.scheduled_for < now() - interval '1 hour')::text
           || ' emails have been waiting over an hour to send'
     where exists (select 1 from notifications n
                    where n.studio_id = p_studio_id and n.status = 'scheduled'
                      and n.scheduled_for < now() - interval '1 hour')
    union all
    -- 8. an attended booking with no signed waiver
    select mname(b.member_id) || ': attended ' || cname(b.occurrence_id) || ' without signing the waiver'
      from bookings b join members m on m.id = b.member_id
     where b.studio_id = p_studio_id and b.status = 'attended'
       and coalesce((select require_waiver from studio_settings where studio_id = p_studio_id), false)
       and exists (select 1 from waiver_versions wv where wv.studio_id = p_studio_id)
       and m.waiver_signed_at is null
    union all
    -- 9. emails that failed in the last day, with the reason
    select count(*)::text || ' emails failed: ' || coalesce(nullif(btrim(fx.reason), ''), 'no reason given')
      from (select coalesce(split_part(error, ':', 1), 'unknown') as reason
              from notifications
             where studio_id = p_studio_id and status = 'failed'
               and coalesce(failed_at, created_at) > now() - interval '1 day') fx
     group by fx.reason
    union all
    -- 10. Decision 103(h): a credit-covered booking the owing shape would dun
    -- (the covered marker is missing). The belt against a covered booking being
    -- reported as due; member_reservation_dues excludes covered bookings.
    select mname(b.member_id) || ': covered booking ' || cname(b.occurrence_id)
           || ' is reported as owing the fee'
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
      join studio_settings st on st.studio_id = b.studio_id
     where b.studio_id = p_studio_id
       and not coalesce(b.reservation_credit_covered, false)
       and exists (select 1 from audit_logs a where a.action = 'reservation.credit_used'
                    and a.entity_table = 'bookings' and a.entity_id = b.id)
       and b.status = 'booked' and b.payment_source = 'comp'
       and coalesce(st.free_first_reservation_fee_cents, 0) > 0
       and st.free_first_reservation_from is not null
       and o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)) > now()
       and not exists (select 1 from payments p where p.booking_id = b.id
                        and p.kind = 'reservation_fee' and p.status in ('succeeded','partially_refunded'))
    union all
    -- 11. Decision 108 (a): a flex class before its cut-off carrying a
    -- reached-minimum mark with fewer paid seats than its minimum.
    select cname(o.id) || ' is marked as reached its minimum with '
           || pc.paid || ' paid of ' || o.minimum_bookings
      from class_occurrences o
      cross join lateral (select count(*)::int as paid from bookings b
             where b.occurrence_id = o.id
               and b.status in ('booked','attended','no_show','pending_payment')
               and not (coalesce(b.payment_source = 'drop_in', false)
                        and not exists (select 1 from payments pmt where pmt.booking_id = b.id
                                         and pmt.status in ('succeeded','partially_refunded')))) pc
     where o.studio_id = p_studio_id and o.status = 'scheduled'
       and coalesce(o.flex, false) and o.committed_at is null
       and (o.flex_reached_minimum_at is not null or o.core_reached_minimum_at is not null)
       and o.minimum_bookings is not null and pc.paid < o.minimum_bookings
       and now() < coalesce((select g.cutoff_at from occurrence_guarantee_run(o.id) g), o.starts_at)
    union all
    -- 12. Decision 108 (a) and (c): a pay line whose amount does not match its
    -- own recorded basis, read at the tier the class had when it was decided.
    -- Settled lines (corrected, voided, restored) are skipped.
    select coalesce((select display_name from instructors where id = ipr.instructor_id), 'An instructor')
           || ': the pay line for ' || coalesce(cname(ipr.occurrence_id), 'a class') || ' is '
           || money_txt(ipr.amount_cents, ipr.currency) || ' but its basis gives '
           || money_txt((rv ->> 'basis_expected')::int, ipr.currency)
      from instructor_pay_records ipr
      cross join lateral pay_line_review_run(ipr.id) rv
     where ipr.studio_id = p_studio_id and ipr.type = 'class'
       and not (rv ->> 'settled')::boolean
       and (rv ->> 'basis_expected') is not null
       and (rv ->> 'basis_expected')::int <> ipr.amount_cents
    union all
    -- 12b. Decision 108 (b) and (c): a pay line on a decided class whose amount
    -- differs from 75 (l). Settled lines are skipped, and a class whose tier
    -- changed since it was decided is left to item 12's basis check.
    select coalesce((select display_name from instructors where id = ipr.instructor_id), 'An instructor')
           || ': the pay line for ' || coalesce(cname(ipr.occurrence_id), 'a class') || ' is '
           || money_txt(ipr.amount_cents, ipr.currency)
           || case when x.expected = 0 and o.status = 'cancelled'
                   then ' but the class did not run and pays nothing'
                   else ' but the rules give ' || money_txt(x.expected, ipr.currency) end
      from instructor_pay_records ipr
      join pay_periods pp on pp.id = ipr.period_id and pp.status = 'open'
      join class_occurrences o on o.id = ipr.occurrence_id
      cross join lateral pay_line_review_run(ipr.id) rv
      cross join lateral (select (compute_class_pay_run(o.id) ->> 'amount_cents')::int as expected) x
     where ipr.studio_id = p_studio_id and ipr.type = 'class'
       and (o.status = 'cancelled' or o.attendance_finalised_at is not null)
       and not (rv ->> 'settled')::boolean
       and (rv ->> 'decision_tier') is not distinct from (rv ->> 'today_tier')
       and x.expected is not null and x.expected <> ipr.amount_cents
    union all
    -- 13. Decision 103 (j): a free first class seat past its deadline that was
    -- kept because its due email was never sent.
    select mname(b.member_id) || ': ' || cname(b.occurrence_id)
           || ' was kept because the pay-to-keep email never reached them'
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
      join studio_settings st on st.studio_id = b.studio_id
      join members mb on mb.id = b.member_id
     where b.studio_id = p_studio_id and b.status = 'booked' and b.payment_source = 'comp'
       and o.starts_at > now() - interval '1 day'
       and not coalesce(b.reservation_credit_covered, false)
       and mb.reservation_fee_waived_at is null and not coalesce(b.reservation_fee_waived, false)
       and coalesce(st.free_first_reservation_fee_cents, 0) > 0
       and st.free_first_reservation_from is not null
       and o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)) <= now()
       and exists (select 1 from guest_passes gp where gp.guest_booking_id = b.id and gp.host_member_id is null)
       and not exists (select 1 from payments p where p.booking_id = b.id
                        and p.kind = 'reservation_fee' and p.status in ('succeeded','partially_refunded'))
       and exists (select 1 from notifications n
                    where n.dedupe_key = 'free_reservation_due:' || b.id
                       or n.dedupe_key like 'free_reservation_due:' || b.id || ':%')
       and not free_due_sent(b.id, o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)))
    union all
    -- 14. Decision 108 (b): a class that ran with no pay line.
    select coalesce(cname(o.id), 'A class') || ' ran with no pay line'
      from class_occurrences o
      join studio_settings st on st.studio_id = o.studio_id
     where o.studio_id = p_studio_id and o.status = 'scheduled' and o.instructor_id is not null
       and (coalesce(st.guarantees_enabled, false) or coalesce(st.flex_enabled, false))
       and o.ends_at < now() - interval '1 hour' and o.starts_at > now() - interval '14 days'
       and not exists (select 1 from instructor_pay_records ipr2 where ipr2.occurrence_id = o.id)
    union all
    -- 15. Decision 108 (b): an always-runs class past its start never committed.
    select coalesce(cname(o.id), 'An always-runs class') || ' started and was never committed'
      from class_occurrences o
      cross join lateral occurrence_guarantee_run(o.id) g
     where o.studio_id = p_studio_id and o.status = 'scheduled' and g.tier = 'always'
       and o.committed_at is null
       and o.starts_at < now() - interval '30 minutes' and o.starts_at > now() - interval '14 days'
    union all
    -- 16. Decision 108 (b): a pay line held for more than 3 days.
    select coalesce((select display_name from instructors where id = ipr.instructor_id), 'An instructor')
           || ': the pay line for ' || coalesce(cname(ipr.occurrence_id), 'a class') || ' has been held for '
           || extract(day from now() - ipr.created_at)::int || ' days'
      from instructor_pay_records ipr
      join pay_periods pp on pp.id = ipr.period_id and pp.status = 'open'
     where ipr.studio_id = p_studio_id and ipr.confirmed_at is null
       and ipr.created_at < now() - interval '3 days'
  loop
    -- Decision 108 (b): one null line must never wipe the list.
    v_line := coalesce(r.line, 'An item with a missing name');
    v_items := v_items || to_jsonb(v_line);
    v_html  := v_html  || '<li>' || replace(replace(v_line, '&', '&amp;'), '<', '&lt;') || '</li>';
    v_text  := v_text  || '- ' || v_line || E'\n';
  end loop;

  v_n := jsonb_array_length(v_items);
  return jsonb_build_object(
    'n', v_n,
    'all_clear', v_n = 0,
    'items', v_items,
    'items_html', case when v_n = 0 then '<p>All clear.</p>' else '<ul>' || v_html || '</ul>' end,
    'items_text', case when v_n = 0 then 'All clear.' else v_text end,
    'count_label', case when v_n = 0 then 'all clear'
                        else v_n::text || ' item' || case when v_n = 1 then '' else 's' end end);
end $function$;

revoke execute on function daily_money_check(uuid) from public, anon, authenticated;
grant  execute on function daily_money_check(uuid) to service_role;

do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'expect\_%' and p.proname not in ('call_jsonb');
  if n <> 14 then raise exception 'anon surface is %, expected 14', n; end if;
end $$;
