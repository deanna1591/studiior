-- Pooled build: Decision 109 (members export), Decision 108 (daily money check),
-- Decision 115 (pay period override), Decision 113 amendment (a) (webhook inbox
-- is public surface), and the convert_test:347 pin.
--
-- creates: members_export(uuid, text, text, text), daily_money_check(uuid),
--          sweep_daily_money_checks(), resolve_unrecorded_class(uuid, text),
--          resolve_unrecorded_all_ran(uuid), tg_resend_inbox_cap(),
--          mname(uuid), cname(uuid), ago(timestamptz), money_txt(int, text)
-- re-issues: close_pay_period(uuid), tg_record_class_pay(), sweep_resend_webhooks()
--
-- No new anon RPC. The resend_webhook_inbox table stays the one public table
-- surface (anon INSERT only). Anon function surface stays EXACTLY THIRTEEN.

----------------------------------------------------------------------
-- 1. Schema
----------------------------------------------------------------------
alter table studio_settings
  add column if not exists daily_check_enabled boolean not null default true;

alter table class_occurrences
  add column if not exists unrecorded_resolved_at   timestamptz,
  add column if not exists unrecorded_resolved_by    uuid,
  add column if not exists unrecorded_resolved_choice text
    check (unrecorded_resolved_choice is null or unrecorded_resolved_choice in ('ran','did_not_run'));

-- Decision 108: the owner's morning diagnostic. Always-send by nature (it is a
-- read-only health report to the owner), gated by daily_check_enabled and the
-- per-template switch queue_shift_notice already honours.
insert into notification_templates (key, subject, text_body, html_body, note) values (
  'owner_daily_check',
  'Studiior daily check for {studio_name}: {count_label}',
  E'Good morning.\n\nHere is this morning''s check for {studio_name}: {count_label}.\n\n{items_text}\n\nNothing here was changed by this check. Open your dashboard to act on anything that needs you: {dashboard_url}',
  '<p>Good morning.</p><p>Here is this morning''s check for <strong>{studio_name}</strong>: {count_label}.</p>{items_html}<p style="color:#78716C;font-size:13px">Nothing here was changed by this check.</p><p><a href="{dashboard_url}">Open your dashboard</a></p>',
  'Decision 108: daily read-only money/data check, emailed to the owner at 07:00 studio time.'
) on conflict (key) do nothing;

----------------------------------------------------------------------
-- 2. Decision 109: members_export — owner or manager, reuses members_list
--    (same search / filter / sort / order), adds marketing + E.164 phone.
----------------------------------------------------------------------
create or replace function members_export(
  p_studio_id uuid, p_search text default '', p_filter text default 'all', p_sort text default 'attention')
returns jsonb
language plpgsql
volatile security definer
set search_path to 'public'
as $function$
declare
  v_country text; v_tz text;
  v_page int := 1; v_j jsonb; v_rows jsonb := '[]'::jsonb; v_total int;
  v_out jsonb;
begin
  -- Owner/manager only. members_list itself allows desk-up (front desk reads the
  -- list), so the narrower gate lives here; front desk is refused the export.
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers export the member list' using errcode = 'PT403';
  end if;
  select timezone, country into v_tz, v_country from studios where id = p_studio_id;

  -- Walk every page of members_list in the shown order, so the file is exactly
  -- what the screen shows and no filter logic is duplicated.
  loop
    v_j := members_list(p_studio_id, coalesce(p_search,''), coalesce(p_filter,'all'), coalesce(p_sort,'attention'), v_page);
    v_total := coalesce((v_j->>'total')::int, 0);
    v_rows := v_rows || coalesce(v_j->'rows', '[]'::jsonb);
    exit when jsonb_array_length(coalesce(v_j->'rows','[]'::jsonb)) < 500
           or jsonb_array_length(v_rows) >= v_total;
    v_page := v_page + 1;
  end loop;

  select jsonb_build_object(
    'rows', coalesce(jsonb_agg(
      jsonb_build_object(
        'first_name',   r->>'first_name',
        'last_name',    r->>'last_name',
        'email',        r->>'email',
        'phone',        coalesce(normalise_phone(r->>'phone', v_country), r->>'phone', ''),
        'status',       r->>'status',
        'plan',         coalesce(r->>'current_plan_name', ''),
        'credits_or_expiry',
          case
            when (r->>'plan_type') = 'recurring' and (r->>'credits_remaining') is null then 'unlimited'
            when (r->>'credits_remaining') is not null then (r->>'credits_remaining')
            when (r->>'expires_on') is not null then 'expires ' || (r->>'expires_on')
            else ''
          end,
        'last_visit',   coalesce(to_char((r->>'last_visit_at')::timestamptz at time zone v_tz, 'YYYY-MM-DD'), ''),
        'joined',       coalesce((r->>'joined_on'), ''),
        'free_class',   coalesce(r->>'free_stage', ''),
        'marketing',
          case when exists (select 1 from members m
                             where m.id = (r->>'id')::uuid
                               and coalesce(m.marketing_opt_in, false)
                               and m.marketing_unsubscribed_at is null)
               then 'yes' else 'no' end
      ) order by ord), '[]'::jsonb),
    'count', jsonb_array_length(v_rows)
  ) into v_out
  from jsonb_array_elements(v_rows) with ordinality as e(r, ord);

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (p_studio_id, auth.uid(), 'members.exported', 'members', p_studio_id,
          jsonb_build_object('filter', coalesce(p_filter,'all'), 'search', coalesce(p_search,''),
                             'sort', coalesce(p_sort,'attention'), 'count', v_out->'count'));

  return v_out;
end $function$;

revoke all on function members_export(uuid, text, text, text) from public, anon;
grant execute on function members_export(uuid, text, text, text) to authenticated, service_role;

----------------------------------------------------------------------
-- 3. Decision 108: daily_money_check — read-only, service-only, nine checks.
----------------------------------------------------------------------
create or replace function daily_money_check(p_studio_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_tz text; v_items jsonb := '[]'::jsonb; v_html text := ''; v_text text := '';
  r record; v_n int;
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
  loop
    v_items := v_items || to_jsonb(r.line);
    v_html  := v_html  || '<li>' || replace(replace(r.line, '&', '&amp;'), '<', '&lt;') || '</li>';
    v_text  := v_text  || '- ' || r.line || E'\n';
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

revoke all on function daily_money_check(uuid) from public, anon, authenticated;
grant execute on function daily_money_check(uuid) to service_role;

-- Tiny formatting helpers used only by the check (service-reachable, not anon).
create or replace function mname(p_member uuid) returns text
language sql stable security definer set search_path to 'public' as $$
  select coalesce(nullif(btrim(coalesce(first_name,'') || ' ' || coalesce(last_name,'')), ''), email, 'A member')
    from members where id = p_member;
$$;
create or replace function cname(p_occ uuid) returns text
language sql stable security definer set search_path to 'public' as $$
  select coalesce(o.name, ct.name, 'a class') || ' on '
         || to_char(o.starts_at at time zone s.timezone, 'FMDy FMDD FMMon')
    from class_occurrences o
    join studios s on s.id = o.studio_id
    left join class_types ct on ct.id = o.class_type_id
   where o.id = p_occ;
$$;
create or replace function ago(p_ts timestamptz) returns text
language sql immutable as $$
  select case
    when p_ts is null then 'a while ago'
    when now() - p_ts < interval '1 hour' then round(extract(epoch from now() - p_ts)/60)::text || ' minutes ago'
    when now() - p_ts < interval '48 hours' then round(extract(epoch from now() - p_ts)/3600)::text || ' hours ago'
    else round(extract(epoch from now() - p_ts)/86400)::text || ' days ago' end;
$$;
create or replace function money_txt(p_cents int, p_currency text) returns text
language sql immutable as $$ select fmt_money(coalesce(p_cents,0), coalesce(p_currency,'PHP')); $$;
revoke all on function mname(uuid) from public, anon;
revoke all on function cname(uuid) from public, anon;
revoke all on function ago(timestamptz) from public, anon;
revoke all on function money_txt(int, text) from public, anon;
grant execute on function mname(uuid) to authenticated, service_role;
grant execute on function cname(uuid) to authenticated, service_role;
grant execute on function ago(timestamptz) to authenticated, service_role;
grant execute on function money_txt(int, text) to authenticated, service_role;

----------------------------------------------------------------------
-- 3b. sweep_daily_money_checks — one owner email per studio per studio-local day
--     at or after 07:00 local, idempotent via the queue dedupe key.
----------------------------------------------------------------------
create or replace function sweep_daily_money_checks()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare s record; v_owner uuid; v_chk jsonb; v_sent int := 0; v_today date; v_origin text;
begin
  if not is_service_context() then
    raise exception 'the daily check sweep runs as the backend' using errcode = 'PT403';
  end if;
  v_origin := coalesce(nullif(notification_setting('staff_app_origin'), ''), 'https://app.studiior.com');

  for s in
    select st.id, st.timezone from studios st
     join studio_settings ss on ss.studio_id = st.id
    where st.status = 'active' and coalesce(ss.daily_check_enabled, true)
      and (now() at time zone st.timezone)::time >= time '07:00'
  loop
    v_today := (now() at time zone s.timezone)::date;
    select ss.user_id into v_owner from studio_staff ss
     where ss.studio_id = s.id and ss.role = 'owner' and ss.status = 'active'
     order by ss.created_at limit 1;
    if v_owner is null then continue; end if;

    v_chk := daily_money_check(s.id);
    if queue_shift_notice(s.id, v_owner, 'owner_daily_check',
         jsonb_build_object(
           'count_label', v_chk->>'count_label',
           'items_html',  v_chk->>'items_html',
           'items_text',  v_chk->>'items_text',
           'dashboard_url', v_origin || '/'),
         'owner_daily_check:' || s.id || ':' || to_char(v_today, 'YYYYMMDD')) is not null then
      v_sent := v_sent + 1;
    end if;
  end loop;
  return jsonb_build_object('emailed', v_sent);
end $function$;

revoke all on function sweep_daily_money_checks() from public, anon, authenticated;
grant execute on function sweep_daily_money_checks() to service_role;

select cron.schedule('studiior-daily-money-check', '*/15 * * * *', 'select sweep_daily_money_checks()')
 where not exists (select 1 from cron.job where jobname = 'studiior-daily-money-check');

----------------------------------------------------------------------
-- 4. Decision 115: resolve an unrecorded class so a period can close.
----------------------------------------------------------------------
-- tg_record_class_pay re-issued byte-faithfully from 20260831440000 with ONE
-- addition: skip when the pay-resolve flag is set, so a "did not run" cancel
-- writes no pay.
create or replace function tg_record_class_pay()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_uses boolean;
begin
  if coalesce(current_setting('studiior.pay_resolve', true), '') = '1' then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.committed_at is not null then
      perform record_class_pay(new.id);
    elsif new.status = 'cancelled' then
      select coalesce(guarantees_enabled, false) or coalesce(flex_enabled, false)
        into v_uses from studio_settings where studio_id = new.studio_id;
      if coalesce(v_uses, false) then perform record_class_pay(new.id); end if;
    end if;
  elsif new.committed_at is not null and old.committed_at is null then
    perform record_class_pay(new.id);
  elsif new.status = 'cancelled' and old.status is distinct from new.status then
    select coalesce(guarantees_enabled, false) or coalesce(flex_enabled, false)
      into v_uses from studio_settings where studio_id = new.studio_id;
    if coalesce(v_uses, false) then perform record_class_pay(new.id); end if;
  end if;
  return new;
end $$;

create or replace function resolve_unrecorded_class(p_occurrence_id uuid, p_choice text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare o class_occurrences%rowtype; v_rec instructor_pay_records%rowtype; v_booked int;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(o.studio_id), false) then
    raise exception 'only owners and managers resolve a class for pay' using errcode = 'PT403';
  end if;
  if p_choice not in ('ran','did_not_run') then
    raise exception 'choose ran or did_not_run' using errcode = 'PT422';
  end if;

  select count(*) into v_booked from bookings
   where occurrence_id = p_occurrence_id and status in ('booked','attended','pending_payment','waitlisted');

  if p_choice = 'ran' then
    -- Ran as scheduled: confirm the held pay record (method manager), pay stands.
    perform confirm_class_for_pay(p_occurrence_id, 'Resolved as ran (attendance not recorded)');
  else
    -- Did not run: only on an empty class. Delete the held record, cancel with no
    -- pay write (the flag) and no member email, reason text 'not held'.
    if v_booked > 0 then
      raise exception 'that class has members booked; use Cancel class, which refunds and notifies'
        using errcode = 'PT409';
    end if;
    delete from instructor_pay_records where occurrence_id = p_occurrence_id and type = 'class';
    perform set_config('studiior.pay_resolve', '1', true);
    update class_occurrences
       set status = 'cancelled', cancellation_reason = 'not held', cancelled_at = coalesce(cancelled_at, now())
     where id = p_occurrence_id;
    perform set_config('studiior.pay_resolve', '', true);
  end if;

  update class_occurrences
     set unrecorded_resolved_at = now(), unrecorded_resolved_by = auth.uid(),
         unrecorded_resolved_choice = p_choice
   where id = p_occurrence_id;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (o.studio_id, auth.uid(), 'pay.unrecorded_resolved', 'class_occurrences', p_occurrence_id,
          jsonb_build_object('choice', p_choice, 'booked', v_booked));

  return jsonb_build_object('ok', true, 'choice', p_choice);
end $function$;

revoke all on function resolve_unrecorded_class(uuid, text) from public, anon;
grant execute on function resolve_unrecorded_class(uuid, text) to authenticated, service_role;

-- Resolve every held class in a period as ran, at once.
create or replace function resolve_unrecorded_all_ran(p_period_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare p pay_periods%rowtype; r record; v_n int := 0;
begin
  select * into p from pay_periods where id = p_period_id;
  if not found then raise exception 'no such period' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(p.studio_id), false) then
    raise exception 'only owners and managers resolve a period' using errcode = 'PT403';
  end if;
  for r in
    select rec.occurrence_id from instructor_pay_records rec
     where rec.period_id = p_period_id and rec.type = 'class' and rec.confirmed_at is null
  loop
    perform resolve_unrecorded_class(r.occurrence_id, 'ran');
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'resolved', v_n);
end $function$;

revoke all on function resolve_unrecorded_all_ran(uuid) from public, anon;
grant execute on function resolve_unrecorded_all_ran(uuid) to authenticated, service_role;

-- close_pay_period re-issued from 20260832730000, held payload gains
-- occurrence_id + booked so the page can offer Decision 115 resolution.
create or replace function close_pay_period(p_period_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare p pay_periods%rowtype; n int; v_total bigint; v_tz text; v_classes jsonb;
begin
  select * into p from pay_periods where id = p_period_id;
  if not found then raise exception 'no such period' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(p.studio_id), false) then
    raise exception 'only owners and managers close a period' using errcode = 'PT403';
  end if;
  if p.status = 'closed' then
    raise exception 'that period is already closed' using errcode = 'PT409';
  end if;

  select timezone into v_tz from studios where id = p.studio_id;
  select jsonb_agg(jsonb_build_object(
           'occurrence_id', o.id,
           'name', o.name,
           'when', to_char(o.starts_at at time zone v_tz, 'FMDy FMDD FMMon') || ' ' || fmt_clock_s(o.starts_at, p.studio_id),
           'instructor', i.display_name,
           'booked', (select count(*) from bookings b where b.occurrence_id = o.id
                       and b.status in ('booked','attended','pending_payment','waitlisted'))) order by o.starts_at)
    into v_classes
    from instructor_pay_records r
    join class_occurrences o on o.id = r.occurrence_id
    join instructors i on i.id = r.instructor_id
   where r.period_id = p_period_id and r.type = 'class' and r.confirmed_at is null;
  if v_classes is not null then
    return jsonb_build_object('ok', false, 'reason', 'held_records', 'classes', v_classes);
  end if;

  select count(*), coalesce(sum(amount_cents), 0) into n, v_total
    from instructor_pay_records where period_id = p_period_id;

  update pay_periods set status = 'closed', closed_at = now(), closed_by = auth.uid()
   where id = p_period_id;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (p.studio_id, auth.uid(), 'pay_period.closed', 'pay_periods', p_period_id,
          jsonb_build_object('records', n, 'total_cents', v_total,
                             'starts_on', p.starts_on, 'ends_on', p.ends_on));

  return jsonb_build_object('ok', true, 'period_id', p_period_id,
    'records', n, 'total_cents', v_total,
    'note', 'Closed. Corrections from here are adjustments in the next period.');
end $function$;

revoke execute on function close_pay_period(uuid) from public, anon;
grant  execute on function close_pay_period(uuid) to authenticated, service_role;

----------------------------------------------------------------------
-- 5. Decision 113 (a): the inbox is public surface. Cap, keep-and-purge, narrow.
----------------------------------------------------------------------
create or replace function tg_resend_inbox_cap()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  -- 600 a minute from the one source (the webhook endpoint). Over the cap, drop
  -- silently so the public endpoint is not an error amplifier.
  if (select count(*) from resend_webhook_inbox where received_at > now() - interval '1 minute') >= 600 then
    return null;
  end if;
  return new;
end $$;

revoke all on function tg_resend_inbox_cap() from public, anon, authenticated;

drop trigger if exists resend_inbox_rate on resend_webhook_inbox;
create trigger resend_inbox_rate before insert on resend_webhook_inbox
  for each row execute function tg_resend_inbox_cap();

-- sweep re-issued: reads only id, provider_message_id, event_type; matched rows
-- deleted at once; unmatched rows kept and purged after one day.
create or replace function sweep_resend_webhooks()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  r record; v_note notifications%rowtype;
  n_delivered int := 0; n_bounced int := 0; n_complained int := 0; n_unmatched int := 0; n_purged int := 0;
begin
  if not is_service_context() then
    raise exception 'the webhook sweep runs as the backend, not as a user'
      using errcode = 'PT403';
  end if;

  for r in select id, provider_message_id, event_type from resend_webhook_inbox order by received_at loop
    v_note := null;
    if r.provider_message_id is not null then
      select * into v_note from notifications
       where provider_message_id = r.provider_message_id limit 1;
    end if;

    if v_note.id is null then
      n_unmatched := n_unmatched + 1;        -- forged or not-yet-matched: keep, purge after a day
      continue;
    elsif r.event_type in ('email.delivered', 'delivered') then
      update notifications set delivered_at = coalesce(delivered_at, now()) where id = v_note.id;
      n_delivered := n_delivered + 1;
    elsif r.event_type in ('email.bounced', 'bounced') then
      update notifications set bounced_at = coalesce(bounced_at, now()) where id = v_note.id;
      if v_note.member_id is not null then
        update members set email_status = 'bounced'
         where id = v_note.member_id and email_status <> 'bounced';
      end if;
      n_bounced := n_bounced + 1;
    elsif r.event_type in ('email.complained', 'complained') then
      if v_note.member_id is not null then
        update members
           set marketing_unsubscribed_at = coalesce(marketing_unsubscribed_at, now())
         where id = v_note.member_id;
      end if;
      n_complained := n_complained + 1;
    end if;

    delete from resend_webhook_inbox where id = r.id;   -- matched: done
  end loop;

  delete from resend_webhook_inbox where received_at < now() - interval '1 day';
  get diagnostics n_purged = row_count;

  return jsonb_build_object('delivered', n_delivered, 'bounced', n_bounced,
                            'complained', n_complained, 'unmatched', n_unmatched, 'purged', n_purged);
end $function$;

revoke all on function sweep_resend_webhooks() from public, anon, authenticated;
grant execute on function sweep_resend_webhooks() to service_role;

----------------------------------------------------------------------
-- 6. Surface assertions: anon functions EXACTLY THIRTEEN; the inbox table is the
--    one public table (anon INSERT only).
----------------------------------------------------------------------
do $$ declare n int; begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.prokind = 'f'
     and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon function surface is % not THIRTEEN', n; end if;
  if not has_table_privilege('anon', 'public.resend_webhook_inbox', 'insert') then
    raise exception 'resend_webhook_inbox lost its anon insert surface';
  end if;
  if has_table_privilege('anon', 'public.resend_webhook_inbox', 'select') then
    raise exception 'resend_webhook_inbox must not be anon-readable';
  end if;
end $$;
