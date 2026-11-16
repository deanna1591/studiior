-- Decision 113 (every email gets delivered) + Decision 114 (marketing consent)
-- + the coach photo on the Book rows and free class picker.
--
-- creates: sweep_resend_webhooks(), member_set_marketing(boolean),
--          email_delivery_failures(uuid), requeue_rate_limit_drops(),
--          backfill_marketing_optin()
-- re-issues: send_due_notifications(), reconcile_notification_sends(),
--            guard_member_self_update(), members_list(uuid, text, text, text, int),
--            free_first_class_list(uuid), free_first_eligible_classes_run(uuid, uuid, int)
--
-- Decision 113: the worker throttles to 20 posts a second and 1,000 a run; a
-- 429 or network failure re-schedules with backoff 1/5/15/60/240 minutes (five
-- retries) honouring a retry-after header, then fails; a 422 (bad address) fails
-- at once and marks the member's email invalid; a quota 429 is not retried.
-- Resend delivery events arrive at a webhook (Svix-verified in the Next route,
-- then inserted into an anon-insert inbox table) and a service sweep applies
-- them, matching on provider_message_id so a forged insert is a no-op. No new
-- anon RPC: anon stays EXACTLY THIRTEEN (asserted at apply).
--
-- Decision 114: the signup checkbox is ticked by default; a backfill opts in the
-- members who never ticked it and never unsubscribed, with an audit row each.

----------------------------------------------------------------------
-- 1. Schema
----------------------------------------------------------------------
alter table notifications
  add column if not exists next_attempt_at timestamptz,
  add column if not exists delivered_at timestamptz,
  add column if not exists bounced_at timestamptz;

-- A member's email is 'valid' until Resend tells us otherwise. 'invalid' is a
-- 422 at send (bad address); 'bounced' is a hard bounce from the webhook. Both
-- stop further email until the address changes.
alter table members
  add column if not exists email_status text not null default 'valid'
    check (email_status in ('valid', 'invalid', 'bounced'));

-- The webhook inbox. The Next route verifies the Svix signature and inserts the
-- event; the service sweep applies and deletes it. Anon may INSERT only (the
-- route uses the anon client); it can never read, update or delete, and the
-- sweep only acts on an event whose provider_message_id matches a notification
-- we actually sent, so a forged insert does nothing.
create table if not exists resend_webhook_inbox (
  id                  uuid primary key default gen_random_uuid(),
  event_type          text not null,
  provider_message_id text,
  email               text,
  raw                 jsonb,
  received_at         timestamptz not null default now()
);
alter table resend_webhook_inbox enable row level security;
revoke all on resend_webhook_inbox from anon, authenticated;
grant insert on resend_webhook_inbox to anon, authenticated;
drop policy if exists resend_inbox_insert on resend_webhook_inbox;
create policy resend_inbox_insert on resend_webhook_inbox
  for insert to anon, authenticated with check (true);

-- Config: pacing and the per-run cap, plus the retry ceiling.
insert into notification_config (key, value) values
  ('send_per_run_cap', '1000'),
  ('send_rate_per_second', '20')
on conflict (key) do nothing;
update notification_config set value = '6' where key = 'max_attempts';

----------------------------------------------------------------------
-- 2. send_due_notifications: throttle + per-run cap + skip a bounced address
----------------------------------------------------------------------
create or replace function send_due_notifications()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  r record; v_req bigint; n_posted int := 0; n_failed int := 0; n_bridged int := 0;
  v_cap int; v_max int; v_rate int; v_sleep double precision; v_status text;
begin
  if not is_service_context() then
    raise exception 'the notification worker runs as the backend, not as a user'
      using errcode = 'PT403';
  end if;

  v_cap  := coalesce(notification_setting('send_per_run_cap')::int, 1000);
  v_max  := coalesce(notification_setting('max_attempts')::int, 6);
  v_rate := greatest(coalesce(notification_setting('send_rate_per_second')::int, 20), 1);
  v_sleep := 1.0 / v_rate;

  -- Staff messages (migration 022) join the same queue.
  for r in select * from messages where status = 'queued' loop
    if queue_notification(r.studio_id, r.member_id, 'staff_message',
         jsonb_build_object('subject', r.subject,
                            'body', r.body,
                            'body_html', '<p>' || replace(
                                replace(r.body, '&', '&amp;'), E'\n\n', '</p><p>') || '</p>'),
         'message:' || r.id) is not null
    then n_bridged := n_bridged + 1; end if;
    update messages set status = 'sent', sent_at = now() where id = r.id;
  end loop;

  for r in
    update notifications
       set status = 'sending', claimed_at = now(), attempts = attempts + 1
     where id in (
       select id from notifications
        where status = 'scheduled'
          and scheduled_for <= now()
          and attempts < v_max
          and channel = 'email'
        order by scheduled_for
        limit v_cap
        for update skip locked
     )
    returning *
  loop
    -- Decision 113: a member whose address bounced or is invalid gets no
    -- further email. The row is cancelled with the reason, never posted.
    v_status := 'valid';
    if r.member_id is not null then
      select coalesce(email_status, 'valid') into v_status from members where id = r.member_id;
    end if;
    if coalesce(v_status, 'valid') <> 'valid' then
      update notifications
         set status = 'cancelled', failed_at = now(),
             error = 'email ' || v_status || ', not sent'
       where id = r.id;
      continue;
    end if;

    -- Decision 113: never post faster than the rate. The claim already set
    -- these rows to 'sending', so the pacing is on the posts, not the lock.
    if n_posted > 0 then perform pg_sleep(v_sleep); end if;

    begin
      v_req := deliver_notification(r.id);
      if v_req is not null then
        update notifications set net_request_id = v_req where id = r.id;
        n_posted := n_posted + 1;
      end if;
    exception when others then
      update notifications
         set status = 'failed', failed_at = now(), error = sqlerrm
       where id = r.id;
      n_failed := n_failed + 1;
    end;
  end loop;

  return jsonb_build_object('posted', n_posted, 'failed', n_failed,
                            'messages_bridged', n_bridged);
end $function$;

----------------------------------------------------------------------
-- 3. reconcile_notification_sends: the retry / 422 / quota / backoff path
----------------------------------------------------------------------
create or replace function reconcile_notification_sends()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  r record; resp record;
  n_sent int := 0; n_failed int := 0; n_retried int := 0;
  v_max int; v_backoff int[] := array[1, 5, 15, 60, 240];  -- minutes, five retries
  v_body text; v_retry_after int; v_delay interval; v_reason text;
  v_retriable boolean; v_quota boolean; v_invalid boolean;
begin
  if not is_service_context() then
    raise exception 'the notification worker runs as the backend, not as a user'
      using errcode = 'PT403';
  end if;

  v_max := coalesce(notification_setting('max_attempts')::int, 6);

  for r in select * from notifications
            where status = 'sending' and net_request_id is not null
  loop
    select * into resp from net._http_response where id = r.net_request_id;

    -- Still in flight, or lost. A missing response past ten minutes is a
    -- network failure, so it takes the retriable path like any other.
    if not found then
      if r.claimed_at >= now() - interval '10 minutes' then continue; end if;
      v_retriable := true; v_quota := false; v_invalid := false;
      v_reason := 'No response from the provider within ten minutes.';
      v_retry_after := null;
    elsif resp.status_code between 200 and 299 then
      update notifications
         set status = 'sent', sent_at = now(), error = null,
             provider_message_id = (resp.content::jsonb ->> 'id')
       where id = r.id;
      n_sent := n_sent + 1;
      continue;
    else
      v_body := lower(coalesce(resp.content, '') || ' ' || coalesce(resp.error_msg, ''));
      v_reason := coalesce(resp.error_msg,
                    'HTTP ' || coalesce(resp.status_code::text, '?')
                    || ': ' || left(coalesce(resp.content, ''), 300));
      v_invalid := resp.status_code = 422;
      v_quota   := resp.status_code = 429
                   and (v_body like '%quota_exceeded%'
                        or v_body like '%daily_quota%' or v_body like '%monthly_quota%');
      -- Retriable: a rate-limit 429 (not a quota stop) or a network error.
      v_retriable := (resp.status_code = 429 and not v_quota)
                     or coalesce(resp.timed_out, false)
                     or resp.status_code is null
                     or (resp.error_msg is not null and resp.status_code is null);
      v_retry_after := nullif(resp.headers ->> 'retry-after', '')::int;
    end if;

    -- 422: a bad address. Fail now and mark the member's email invalid so no
    -- further email is attempted until it is changed.
    if v_invalid then
      update notifications set status = 'failed', failed_at = now(), error = v_reason where id = r.id;
      if r.member_id is not null then
        update members set email_status = 'invalid' where id = r.member_id and email_status = 'valid';
      end if;
      n_failed := n_failed + 1;
      continue;
    end if;

    -- Retriable and attempts left: re-schedule with backoff, honouring a
    -- retry-after header when Resend sends one.
    if v_retriable and r.attempts < v_max then
      if v_retry_after is not null and v_retry_after > 0 then
        v_delay := make_interval(secs => least(v_retry_after, 3600));
      else
        v_delay := make_interval(mins => v_backoff[least(r.attempts, array_length(v_backoff, 1))]);
      end if;
      update notifications
         set status = 'scheduled', scheduled_for = now() + v_delay,
             next_attempt_at = now() + v_delay, net_request_id = null,
             failed_at = null, error = v_reason
       where id = r.id;
      n_retried := n_retried + 1;
      continue;
    end if;

    -- Terminal: a quota stop, a non-retriable error, or retries exhausted.
    update notifications set status = 'failed', failed_at = now(), error = v_reason where id = r.id;
    n_failed := n_failed + 1;
  end loop;

  return jsonb_build_object('sent', n_sent, 'failed', n_failed, 'retried', n_retried);
end $function$;

----------------------------------------------------------------------
-- 4. sweep_resend_webhooks: apply delivered / bounced / complained
----------------------------------------------------------------------
create or replace function sweep_resend_webhooks()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  r record; v_note notifications%rowtype;
  n_delivered int := 0; n_bounced int := 0; n_complained int := 0; n_unmatched int := 0;
begin
  if not is_service_context() then
    raise exception 'the webhook sweep runs as the backend, not as a user'
      using errcode = 'PT403';
  end if;

  for r in select * from resend_webhook_inbox order by received_at loop
    v_note := null;
    if r.provider_message_id is not null then
      select * into v_note from notifications
       where provider_message_id = r.provider_message_id limit 1;
    end if;

    if v_note.id is null then
      n_unmatched := n_unmatched + 1;        -- forged or stale: no-op
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

    delete from resend_webhook_inbox where id = r.id;
  end loop;

  return jsonb_build_object('delivered', n_delivered, 'bounced', n_bounced,
                            'complained', n_complained, 'unmatched', n_unmatched);
end $function$;

revoke all on function sweep_resend_webhooks() from public, anon, authenticated;
grant execute on function sweep_resend_webhooks() to service_role;

select cron.schedule('studiior-resend-webhooks', '* * * * *', 'select sweep_resend_webhooks()')
 where not exists (select 1 from cron.job where jobname = 'studiior-resend-webhooks');

----------------------------------------------------------------------
-- 5. member_set_marketing: the Account -> Emails switch
----------------------------------------------------------------------
create or replace function member_set_marketing(p_on boolean)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if auth.uid() is null then
    raise exception 'sign in first' using errcode = 'PT403';
  end if;
  perform set_config('studiior.marketing_consent', '1', true);
  if coalesce(p_on, false) then
    update members
       set marketing_opt_in = true, marketing_unsubscribed_at = null, updated_at = now()
     where user_id = auth.uid();
  else
    update members set marketing_opt_in = false, updated_at = now() where user_id = auth.uid();
  end if;
  perform set_config('studiior.marketing_consent', '', true);
end $function$;

revoke all on function member_set_marketing(boolean) from public, anon;
grant execute on function member_set_marketing(boolean) to authenticated, service_role;

-- The guard lets a member clear their own marketing_unsubscribed_at under the
-- studiior.marketing_consent flag (it is not otherwise member-owned), exactly
-- the narrow pattern used for waiver signing and the check-in health cascade.
-- Re-issued byte-faithfully from its newest definition, with only the
-- marketing_cols array and the marketing_consent branch added.
create or replace function guard_member_self_update()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  owned constant text[] := array[
    'preferred_name', 'phone', 'avatar_url', 'emergency_contact',
    'address', 'date_of_birth', 'marketing_opt_in', 'updated_at'
  ];
  waiver_cols constant text[] := array['waiver_signed_at', 'updated_at'];
  health_cols constant text[] := array['health_band', 'health_reason',
                                       'health_signals', 'health_computed_at', 'updated_at'];
  desk_pay_cols constant text[] := array['desk_pay_blocked_at', 'desk_pay_blocked_reason', 'updated_at'];
  -- Decision 114: the member turns marketing back on under Account -> Emails.
  marketing_cols constant text[] := array['marketing_opt_in', 'marketing_unsubscribed_at', 'updated_at'];
  -- Decision 69 / 97: the exact set the scrub (and a merge) sets. NARROW.
  delete_cols constant text[] := array[
    'first_name', 'last_name', 'email', 'phone', 'date_of_birth', 'avatar_url',
    'address', 'emergency_contact', 'preferred_name', 'source', 'status',
    'marketing_opt_in', 'marketing_unsubscribed_at',
    'health_band', 'health_reason', 'health_signals', 'health_computed_at',
    'deleted_at', 'merged_into', 'merged_at', 'user_id', 'updated_at'
  ];
begin
  if is_service_context() then
    return new;
  end if;
  if coalesce(current_setting('studiior.waiver_signing', true), '') = '1' then
    if (to_jsonb(new) - waiver_cols) <> (to_jsonb(old) - waiver_cols) then
      raise exception 'waiver signing may set only the signature timestamp'
        using errcode = 'PT403';
    end if;
    return new;
  end if;
  if coalesce(current_setting('studiior.checkin_health', true), '') = '1' then
    if (to_jsonb(new) - health_cols) <> (to_jsonb(old) - health_cols) then
      raise exception 'the check-in health cascade may set only the health columns'
        using errcode = 'PT403';
    end if;
    return new;
  end if;
  if coalesce(current_setting('studiior.account_deleting', true), '') = '1' then
    if (to_jsonb(new) - delete_cols) <> (to_jsonb(old) - delete_cols) then
      raise exception 'account deletion may set only the scrub columns'
        using errcode = 'PT403';
    end if;
    return new;
  end if;
  if coalesce(current_setting('studiior.desk_pay_system', true), '') = '1' then
    if (to_jsonb(new) - desk_pay_cols) <> (to_jsonb(old) - desk_pay_cols) then
      raise exception 'the desk-pay block may set only the desk-pay columns'
        using errcode = 'PT403';
    end if;
    return new;
  end if;
  if coalesce(current_setting('studiior.marketing_consent', true), '') = '1' then
    if (to_jsonb(new) - marketing_cols) <> (to_jsonb(old) - marketing_cols) then
      raise exception 'a marketing consent change may set only the marketing columns'
        using errcode = 'PT403';
    end if;
    return new;
  end if;
  if is_desk_up(new.studio_id) then
    return new;
  end if;
  if old.user_id is null then
    return new;
  end if;
  if auth.uid() is null or old.user_id is distinct from auth.uid() then
    return new;
  end if;
  if (to_jsonb(new) - owned) <> (to_jsonb(old) - owned) then
    raise exception 'a member may change their own contact details, not their membership'
      using errcode = 'PT403',
            hint = 'Editable by the member: ' || array_to_string(owned, ', ')
                   || '. Everything else is the studio''s to set.';
  end if;
  return new;
end $function$;

----------------------------------------------------------------------
-- 6. email_delivery_failures: the daily check (last day's failures)
----------------------------------------------------------------------
create or replace function email_delivery_failures(p_studio_id uuid)
returns table(template_key text, reason text, n int)
language sql
stable security definer
set search_path to 'public'
as $function$
  select n.template_key,
         case when n.error ilike '%429%' then 'rate limit'
              when n.error ilike '%422%' then 'bad address'
              when n.error ilike '%quota%' then 'quota'
              when n.error ilike '%ten minutes%' then 'no response'
              else 'other' end as reason,
         count(*)::int
    from notifications n
   where n.studio_id = p_studio_id
     and n.status = 'failed'
     and coalesce(n.failed_at, n.created_at) > now() - interval '1 day'
     and (coalesce(is_desk_up(p_studio_id), false) or is_service_context())
   group by 1, 2
   order by 3 desc
$function$;

revoke all on function email_delivery_failures(uuid) from public, anon;
grant execute on function email_delivery_failures(uuid) to authenticated, service_role;

----------------------------------------------------------------------
-- 7. members_list: carry email_status for the Email bounced chip
--    (re-issued byte-faithfully from newest, + email_status in ph/rows/del)
----------------------------------------------------------------------
create or replace function members_list(p_studio_id uuid, p_search text default ''::text, p_filter text default 'all'::text, p_sort text default 'attention'::text, p_page integer default 1)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_country text;
  v_today date;
  v_tz text;
  v_q text := btrim(coalesce(p_search, ''));
  v_digits text := regexp_replace(coalesce(p_search, ''), '\D', '', 'g');
  v_page int := greatest(coalesce(p_page, 1), 1);
  v_size int := 500;
  v_result jsonb;
begin
  if not (is_desk_up(p_studio_id) or is_service_context()) then
    raise exception 'that is another studio''s members' using errcode = 'PT403';
  end if;
  select timezone, country into v_tz, v_country from studios where id = p_studio_id;
  v_today := (now() at time zone v_tz)::date;

  with base as (
    select * from member_plan_overview(p_studio_id)
  ),
  ph as (
    select m.id, m.phone, m.email_status,
           normalise_name(coalesce(m.first_name,'') || ' ' || coalesce(m.last_name,'')) as nn,
           btrim(coalesce(m.last_name,'')) as ln,
           normalise_phone(m.phone, v_country) as np
      from members m
     where m.studio_id = p_studio_id and m.deleted_at is null
  ),
  dup_name as (
    select nn from ph where ln <> '' and nn is not null group by nn having count(*) > 1
  ),
  dup_phone as (
    select np from ph where np is not null group by np having count(*) > 1
  ),
  dup as (
    select p.id,
           (exists (select 1 from dup_name d where d.nn = p.nn and p.ln <> '')
            or exists (select 1 from dup_phone d where d.np = p.np)) as has_duplicate
      from ph p
  ),
  fee_due as (
    select distinct b.member_id
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
      join studio_settings st on st.studio_id = b.studio_id
      join members mb on mb.id = b.member_id
     where b.studio_id = p_studio_id
       and b.status = 'booked' and b.payment_source = 'comp'
       and mb.reservation_fee_waived_at is null and not b.reservation_fee_waived
       and st.free_first_reservation_from is not null
       and coalesce(st.free_first_reservation_fee_cents, 0) > 0
       and o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)) > now()
       and exists (select 1 from guest_passes gp where gp.guest_booking_id = b.id and gp.host_member_id is null)
       and not exists (select 1 from payments p where p.booking_id = b.id and p.kind = 'reservation_fee'
                        and p.status in ('succeeded','partially_refunded'))
  ),
  needs_waiver as (
    select m.id
      from members m
     where m.studio_id = p_studio_id and m.deleted_at is null
       and coalesce((select require_waiver from studio_settings where studio_id = p_studio_id), false)
       and exists (select 1 from waiver_versions wv where wv.studio_id = p_studio_id)
       and (
         m.waiver_signed_at is null
         or exists (
           select 1 from waiver_versions wv
            where wv.studio_id = p_studio_id and wv.requires_resign
              and wv.created_at = (select max(created_at) from waiver_versions where studio_id = p_studio_id)
              and not exists (select 1 from waiver_signatures ws where ws.member_id = m.id and ws.version_id = wv.id))
       )
       and exists (select 1 from bookings b join class_occurrences o on o.id = b.occurrence_id
                    where b.member_id = m.id and b.status in ('booked','attended','pending_payment','waitlisted')
                      and o.starts_at > now())
  ),
  rows as (
    select base.id, base.first_name, base.last_name, base.email, ph.phone, ph.email_status,
           base.status, base.lifetime_visits, base.last_visit_at, base.user_id,
           base.health_band, base.health_reason,
           base.current_plan_name, base.plan_type, base.expires_on, base.credits_remaining,
           base.plan_state, base.complimentary, base.free_stage, base.has_unpaid_booking,
           base.joined_on, base.reservation_fee_waived,
           coalesce(dup.has_duplicate, false) as has_duplicate,
           (fee_due.member_id is not null) as has_fee_due,
           (needs_waiver.id is not null) as needs_waiver,
           false as deleted
      from base
      left join ph on ph.id = base.id
      left join dup on dup.id = base.id
      left join fee_due on fee_due.member_id = base.id
      left join needs_waiver on needs_waiver.id = base.id
  ),
  del as (
    select m.id, m.first_name, m.last_name, m.email, m.phone, m.email_status,
           'deleted'::text as status, 0 as lifetime_visits, null::timestamptz as last_visit_at,
           m.user_id, null::text as health_band, null::text as health_reason,
           null::text as current_plan_name, null::text as plan_type,
           null::date as expires_on, null::int as credits_remaining, 'none'::text as plan_state,
           false as complimentary, null::text as free_stage, false as has_unpaid_booking,
           m.joined_on, false as reservation_fee_waived, false as has_duplicate,
           false as has_fee_due, false as needs_waiver, true as deleted,
           m.deleted_at, m.merged_into
      from members m
     where m.studio_id = p_studio_id and m.deleted_at is not null
  ),
  searched as (
    select r.* from rows r
     where v_q = ''
        or (coalesce(r.first_name,'') || ' ' || coalesce(r.last_name,'')) ilike '%' || v_q || '%'
        or coalesce(r.email,'') ilike '%' || v_q || '%'
        or (length(v_digits) >= 4 and regexp_replace(coalesce(r.phone,''), '\D', '', 'g') like '%' || v_digits || '%')
  ),
  searched_del as (
    select d.* from del d
     where v_q = ''
        or (coalesce(d.first_name,'') || ' ' || coalesce(d.last_name,'')) ilike '%' || v_q || '%'
        or coalesce(d.email,'') ilike '%' || v_q || '%'
        or (length(v_digits) >= 4 and regexp_replace(coalesce(d.phone,''), '\D', '', 'g') like '%' || v_digits || '%')
  ),
  counts as (
    select jsonb_build_object(
      'all',           count(*),
      'active',        count(*) filter (where status = 'active'),
      'leads',         count(*) filter (where status = 'lead'),
      'unpaid',        count(*) filter (where has_unpaid_booking),
      'free_pending',  count(*) filter (where plan_state = 'free_only' and free_stage = 'booked'),
      'attention',     count(*) filter (where has_fee_due or has_duplicate or needs_waiver),
      'deleted',       (select count(*) from searched_del)
    ) as c from searched
  ),
  filtered as (
    select * from (
      select s.*, null::timestamptz as deleted_at, null::uuid as merged_into from searched s
       where case p_filter
               when 'active'       then status = 'active'
               when 'leads'        then status = 'lead'
               when 'unpaid'       then has_unpaid_booking
               when 'free_pending' then plan_state = 'free_only' and free_stage = 'booked'
               when 'attention'    then has_fee_due or has_duplicate or needs_waiver
               else true
             end
         and p_filter <> 'deleted'
      union all
      select sd.* from searched_del sd where p_filter = 'deleted'
    ) u
    order by
      case when p_sort = 'name' then lower(coalesce(u.first_name,'') || ' ' || coalesce(u.last_name,'')) end asc,
      case when p_sort = 'last_visit' then u.last_visit_at end desc nulls last,
      case when p_sort = 'joined' then u.joined_on end desc nulls last,
      case when p_sort not in ('name','last_visit','joined')
           then (case when (u.has_fee_due or u.has_duplicate or u.needs_waiver or u.has_unpaid_booking) then 0 else 1 end) end asc,
      u.last_visit_at desc nulls last,
      lower(coalesce(u.first_name,''))
  )
  select jsonb_build_object(
    'rows', coalesce((
      select jsonb_agg(row_to_json(f)) from (
        select * from filtered offset (v_page - 1) * v_size limit v_size
      ) f
    ), '[]'::jsonb),
    'counts', (select c from counts),
    'total', (select count(*) from filtered),
    'page', v_page,
    'page_size', v_size
  ) into v_result;

  return v_result;
end $function$;

----------------------------------------------------------------------
-- 8. free_first_class_list / _run: return the coach avatar
----------------------------------------------------------------------
drop function if exists free_first_eligible_classes_run(uuid, uuid, integer);
create function free_first_eligible_classes_run(p_studio_id uuid, p_member_id uuid, p_min_headcount integer default 0)
returns table(occurrence_id uuid, name text, starts_at timestamptz, duration_min integer,
              room_name text, instructor_first text, instructor_avatar text,
              headcount integer, capacity integer, free_bookable boolean)
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare st studio_settings%rowtype; v_elig jsonb;
begin
  select * into st from studio_settings where studio_id = p_studio_id;
  v_elig := free_first_eligibility(p_studio_id, p_member_id);
  if not coalesce((v_elig ->> 'ok')::boolean, false) then return; end if;

  return query
  select o.id, o.name, o.starts_at,
         coalesce(ct.duration_minutes, 0),
         (select r.name from rooms r where r.id = o.room_id),
         (select split_part(i.display_name, ' ', 1) from instructors i where i.id = o.instructor_id),
         (select i.avatar_url from instructors i where i.id = o.instructor_id),
         coalesce(o.booked_count, 0), o.capacity,
         ( o.capacity - occurrence_seats_taken(o.id) - occurrence_seats_held(o.id) >= 1
           and (st.free_first_seats_per_class is null
                or (select count(*) from bookings b
                     where b.occurrence_id = o.id and b.status = 'booked'
                       and b.payment_source = 'comp'
                       and exists (select 1 from guest_passes gp
                                    where gp.guest_booking_id = b.id and gp.host_member_id is null))
                    < st.free_first_seats_per_class) )
    from class_occurrences o
    left join class_series ser on ser.id = o.series_id
    left join class_types  ct  on ct.id  = o.class_type_id
   where o.studio_id = p_studio_id
     and o.status = 'scheduled' and not o.hidden_from_members
     and o.starts_at > now()
     and o.starts_at <= now() + make_interval(days => coalesce(st.booking_window_days, 30))
     and o.starts_at >= now() + make_interval(mins => coalesce(st.booking_cutoff_minutes, 0))
     and occurrence_member_visible_run(o.id, p_member_id)
     and o.free_first_override is distinct from 'closed'
     and (o.free_first_override = 'open' or (
            (not coalesce(st.free_first_core_only, false)
             or coalesce(o.guarantee_tier, case when o.flex then 'flex'::guarantee_tier end,
                         ser.guarantee_tier, case when ser.flex then 'flex'::guarantee_tier end,
                         'core'::guarantee_tier) = 'core')
            and (o.series_id is null or coalesce(ser.free_first_allowed, true))
          ))
     and not (not coalesce(st.free_first_peak_allowed, true) and occurrence_is_peak(o.id))
     and coalesce(o.booked_count, 0) >= p_min_headcount
   order by coalesce(o.booked_count, 0) desc, o.starts_at;
end $function$;

revoke all on function free_first_eligible_classes_run(uuid, uuid, integer) from public, anon, authenticated;
grant execute on function free_first_eligible_classes_run(uuid, uuid, integer) to service_role;

drop function if exists free_first_class_list(uuid);
create function free_first_class_list(p_studio_id uuid)
returns table(occurrence_id uuid, name text, starts_at timestamptz, duration_min integer,
              room_name text, instructor_first text, instructor_avatar text,
              headcount integer, capacity integer, free_bookable boolean)
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare v_member uuid;
begin
  select id into v_member from members where user_id = auth.uid() and studio_id = p_studio_id;
  if v_member is null then
    raise exception 'not a member of that studio' using errcode = 'PT403';
  end if;
  return query select * from free_first_eligible_classes_run(p_studio_id, v_member, 0);
end $function$;

revoke all on function free_first_class_list(uuid) from public, anon;
grant execute on function free_first_class_list(uuid) to authenticated, service_role;

----------------------------------------------------------------------
-- 9. Re-queue of the rate-limit drops (Decision 113). Idempotent: it only
--    re-schedules rows that are still 'failed', so a second call is a no-op.
----------------------------------------------------------------------
create or replace function requeue_rate_limit_drops()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_counts jsonb;
begin
  if not is_service_context() then
    raise exception 'the re-queue runs as the backend, not as a user' using errcode = 'PT403';
  end if;
  with relevant as (
    update notifications n
       set status = 'scheduled', scheduled_for = now(), attempts = 0,
           next_attempt_at = now(), failed_at = null, net_request_id = null
      where n.status = 'failed'
        and coalesce(n.failed_at, n.created_at) > now() - interval '30 days'
        and n.error ilike '%429%' and n.error not ilike '%quota%'
        and n.member_id is not null
        and n.template_key in ('convert_day3','convert_day7','convert_last_day',
                               'convert_missed_you','keep_drifting','convert_book_first')
        -- relevance: still unconverted / drifting / no booking, address still good
        and exists (select 1 from members m where m.id = n.member_id
                     and m.deleted_at is null and coalesce(m.email_status,'valid') = 'valid')
        and case n.template_key
              when 'keep_drifting' then
                exists (select 1 from members m where m.id = n.member_id and m.health_band = 'drifting')
              when 'convert_book_first' then
                not exists (select 1 from bookings b where b.member_id = n.member_id)
              else
                not exists (select 1 from memberships ms where ms.member_id = n.member_id)
            end
      returning n.template_key
  )
  select coalesce(jsonb_object_agg(template_key, c), '{}'::jsonb) into v_counts
    from (select template_key, count(*)::int c from relevant group by template_key) s;
  return v_counts;
end $function$;

revoke all on function requeue_rate_limit_drops() from public, anon, authenticated;
grant execute on function requeue_rate_limit_drops() to service_role;

do $rq$ begin raise notice 'Decision 113 re-queue by template: %', requeue_rate_limit_drops(); end $rq$;

----------------------------------------------------------------------
-- 10. Opt-in backfill (Decision 114), with an audit row each. One-time at
--     apply; service-only so clients cannot re-run it.
----------------------------------------------------------------------
create or replace function backfill_marketing_optin()
returns int
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_n int;
begin
  if not is_service_context() then
    raise exception 'the backfill runs as the backend, not as a user' using errcode = 'PT403';
  end if;
  with flipped as (
    update members
       set marketing_opt_in = true, updated_at = now()
     where marketing_opt_in = false
       and marketing_unsubscribed_at is null
       and deleted_at is null
      returning id, studio_id
  ), audited as (
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
    select studio_id, null, 'member.marketing_backfilled', 'members', id,
           jsonb_build_object('marketing_opt_in', false),
           jsonb_build_object('marketing_opt_in', true,
                              'why', 'Decision 114: receiving sequence emails with the unsubscribe link throughout')
      from flipped
    returning 1
  )
  select count(*) into v_n from audited;
  return v_n;
end $function$;

revoke all on function backfill_marketing_optin() from public, anon, authenticated;
grant execute on function backfill_marketing_optin() to service_role;

do $bf$ begin raise notice 'Decision 114 opt-in backfill: % members', backfill_marketing_optin(); end $bf$;

----------------------------------------------------------------------
-- anon stays EXACTLY THIRTEEN
----------------------------------------------------------------------
do $anon$
declare v_n int;
begin
  select count(*) into v_n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if v_n <> 13 then
    raise exception 'anon surface is %, expected exactly 13', v_n;
  end if;
end $anon$;
