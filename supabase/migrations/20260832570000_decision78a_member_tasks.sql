-- Decision 78a/78e — the retention task table (as far as the convert build needs
-- it), the contacted/dismiss RPCs, the unconverted-free readers, and the
-- 'contacted' Journey event in both its write sites.
--
-- creates:    mark_task_contacted(uuid), dismiss_task(uuid), retention_board(uuid), retention_unconverted_count(uuid)
-- re-issues:  rebuild_timeline_rows(uuid), member_activity(uuid, date, date)

create table member_tasks (
  id                uuid primary key default gen_random_uuid(),
  studio_id         uuid not null references studios on delete cascade,
  member_id         uuid not null references members on delete cascade,
  kind              text not null check (kind in ('unconverted_day7','at_risk','drifting_fyi')),
  reason            text,
  suggested_message text,
  assigned_role     text not null default 'owner_manager' check (assigned_role in ('owner_manager','front_desk')),
  status            text not null default 'open' check (status in ('open','contacted','dismissed')),
  created_at        timestamptz not null default now(),
  contacted_at      timestamptz,
  contacted_by      uuid references profiles,
  closed_at         timestamptz
);
-- One OPEN task per member per kind — the sweep upserts against this.
create unique index member_tasks_one_open on member_tasks (member_id, kind) where status = 'open';
create index member_tasks_studio on member_tasks (studio_id, status, kind);

alter table member_tasks enable row level security;

-- Manager-up read; front desk reads only when the studio routes tasks to them.
-- Writes are the SECURITY DEFINER RPCs + the service sweep, never a direct client
-- write, so there is no insert/update/delete policy.
create policy member_tasks_read on member_tasks for select using (
  coalesce(is_manager_up(studio_id), false)
  or (coalesce(is_desk_up(studio_id), false)
      and coalesce((select retention_tasks_to from studio_settings ss
                     where ss.studio_id = member_tasks.studio_id), 'owner_manager') = 'front_desk')
);
grant select on member_tasks to authenticated;

-- ---------------------------------------------------------------------------
-- mark_task_contacted — a human has reached out. Writes a 'contacted' Journey
-- event, field-for-field with the rebuild derivation below so a later rebuild
-- reproduces it identically (the send_message rule).
create function mark_task_contacted(p_task_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t member_tasks%rowtype; v_routed boolean;
begin
  select * into t from member_tasks where id = p_task_id;
  if not found then raise exception 'no such task' using errcode = 'PT404'; end if;
  v_routed := coalesce((select retention_tasks_to from studio_settings
                         where studio_id = t.studio_id), 'owner_manager') = 'front_desk';
  if not (coalesce(is_manager_up(t.studio_id), false)
          or (coalesce(is_desk_up(t.studio_id), false) and v_routed)) then
    raise exception 'that is not your task to act on' using errcode = 'PT403';
  end if;
  if t.status <> 'open' then
    raise exception 'that task is already %', t.status using errcode = 'PT409';
  end if;

  update member_tasks
     set status = 'contacted', contacted_at = now(), contacted_by = auth.uid()
   where id = p_task_id
   returning * into t;

  insert into timeline_events (studio_id, member_id, type, occurred_at, title, description, actor_user_id, ref_table, ref_id)
  values (t.studio_id, t.member_id, 'contacted', t.contacted_at, 'Contacted', t.reason, t.contacted_by, 'member_tasks', t.id);

  return jsonb_build_object('ok', true, 'status', 'contacted');
end $$;
revoke execute on function mark_task_contacted(uuid) from public, anon;
grant  execute on function mark_task_contacted(uuid) to authenticated;

-- dismiss_task — not worth chasing. Closes the task; no Journey event.
create function dismiss_task(p_task_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t member_tasks%rowtype; v_routed boolean;
begin
  select * into t from member_tasks where id = p_task_id;
  if not found then raise exception 'no such task' using errcode = 'PT404'; end if;
  v_routed := coalesce((select retention_tasks_to from studio_settings
                         where studio_id = t.studio_id), 'owner_manager') = 'front_desk';
  if not (coalesce(is_manager_up(t.studio_id), false)
          or (coalesce(is_desk_up(t.studio_id), false) and v_routed)) then
    raise exception 'that is not your task to act on' using errcode = 'PT403';
  end if;
  if t.status <> 'open' then
    raise exception 'that task is already %', t.status using errcode = 'PT409';
  end if;

  update member_tasks set status = 'dismissed', closed_at = now() where id = p_task_id;
  return jsonb_build_object('ok', true, 'status', 'dismissed');
end $$;
revoke execute on function dismiss_task(uuid) from public, anon;
grant  execute on function dismiss_task(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- retention_board — the "free class, not yet converted" list (78a). A member
-- with a free first class (their OWN comp booking, not a guest seat) and no
-- membership yet: their class date, days since, the instructor, their intro
-- window end, and any open/contacted unconverted_day7 task. Manager-up, or front
-- desk when routed, or a background job (so the sweep and dashboard can read it).
create function retention_board(p_studio_id uuid)
returns table (
  member_id uuid, member_name text, phone text,
  class_at timestamptz, days_since int, instructor_name text,
  offer_ends timestamptz, window_active boolean,
  task_id uuid, task_status text, suggested_message text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (coalesce(is_manager_up(p_studio_id), false)
          or (coalesce(is_desk_up(p_studio_id), false)
              and coalesce((select retention_tasks_to from studio_settings
                             where studio_id = p_studio_id), 'owner_manager') = 'front_desk')
          or is_service_context()) then
    raise exception 'that is another studio''s retention board' using errcode = 'PT403';
  end if;

  return query
  with free_members as (
    select distinct on (b.member_id)
           b.member_id, b.occurrence_id, o.starts_at, o.instructor_id
      from bookings b join class_occurrences o on o.id = b.occurrence_id
     where b.studio_id = p_studio_id and b.payment_source = 'comp'
       and not exists (select 1 from guest_passes gp
                        where gp.guest_booking_id = b.id and gp.host_member_id is not null)
     order by b.member_id, b.booked_at
  )
  select m.id,
         coalesce(nullif(m.first_name, ''), m.email),
         m.phone,
         fm.starts_at,
         greatest(0, (now()::date - fm.starts_at::date))::int,
         split_part(coalesce(i.display_name, ''), ' ', 1),
         (intro_window(m.id) ->> 'ends_at')::timestamptz,
         coalesce((intro_window(m.id) ->> 'active')::boolean, false),
         t.id, t.status, t.suggested_message
    from free_members fm
    join members m on m.id = fm.member_id and m.deleted_at is null
    left join instructors i on i.id = fm.instructor_id
    left join lateral (
      select mt.id, mt.status, mt.suggested_message
        from member_tasks mt
       where mt.member_id = m.id and mt.kind = 'unconverted_day7' and mt.status <> 'dismissed'
       order by mt.created_at desc limit 1) t on true
   where not exists (select 1 from memberships ms where ms.member_id = m.id)
   order by fm.starts_at desc;
end $$;
revoke execute on function retention_board(uuid) from public, anon;
grant  execute on function retention_board(uuid) to authenticated, service_role;

-- The count behind the dashboard tile and the morning-brief line — ONE universe,
-- read through retention_board so the number and the list can never disagree.
create function retention_unconverted_count(p_studio_id uuid)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from retention_board(p_studio_id);
$$;
revoke execute on function retention_unconverted_count(uuid) from public, anon;
grant  execute on function retention_unconverted_count(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- rebuild_timeline_rows re-issued (from 20260830690000) + a 'contacted' row.
CREATE OR REPLACE FUNCTION public.rebuild_timeline_rows(p_member_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_studio uuid;
  n int;
begin
  select studio_id into v_studio from members where id = p_member_id;
  if not found then
    raise exception 'no such member' using errcode = 'PT404';
  end if;

  delete from timeline_events where member_id = p_member_id;

  insert into timeline_events (studio_id, member_id, type, occurred_at, title, description, ref_table, ref_id)
  select v_studio, p_member_id, 'joined',
         (m.joined_on::timestamp at time zone s.timezone),
         'Joined the studio',
         case when m.source is null then null else 'Came via ' || m.source end,
         'members', m.id
    from members m join studios s on s.id = m.studio_id
   where m.id = p_member_id;

  insert into timeline_events (studio_id, member_id, type, occurred_at, title, description, ref_table, ref_id)
  select v_studio, p_member_id, 'attended', ci.checked_in_at,
         coalesce(o.name, 'Visit'),
         case when o.id is null
              then 'Imported from your previous system — the class is not known'
              else null end,
         'check_ins', ci.id
    from check_ins ci
    left join class_occurrences o on o.id = ci.occurrence_id
   where ci.member_id = p_member_id;

  insert into timeline_events (studio_id, member_id, type, occurred_at, title, description, ref_table, ref_id)
  select v_studio, p_member_id, 'cancelled',
         coalesce(b.cancelled_at, b.booked_at),
         case when b.is_late_cancel then 'Cancelled late' else 'Cancelled' end,
         o.name,
         'bookings', b.id
    from bookings b
    left join class_occurrences o on o.id = b.occurrence_id
   where b.member_id = p_member_id
     and b.status in ('cancelled', 'late_cancelled');

  insert into timeline_events (studio_id, member_id, type, occurred_at, title, description, ref_table, ref_id, metadata)
  select v_studio, p_member_id, 'payment',
         coalesce(p.paid_at, p.created_at),
         case p.status
           when 'succeeded'          then 'Paid'
           when 'failed'             then 'Payment failed'
           when 'refunded'           then 'Refunded'
           when 'partially_refunded' then 'Partly refunded'
           else 'Payment pending'
         end,
         p.description,
         'payments', p.id,
         jsonb_build_object('amount_cents', p.amount_cents, 'currency', p.currency,
                            'status', p.status)
    from payments p
   where p.member_id = p_member_id;

  insert into timeline_events (studio_id, member_id, type, occurred_at, title, description, ref_table, ref_id)
  select v_studio, p_member_id, 'membership_changed',
         coalesce(ms.starts_on::timestamptz, ms.created_at),
         'Started on ' || pl.name,
         null,
         'memberships', ms.id
    from memberships ms join membership_plans pl on pl.id = ms.plan_id
   where ms.member_id = p_member_id;

  -- A draft is not an event. Only a message that has left the desk appears.
  insert into timeline_events (studio_id, member_id, type, occurred_at, title, description, actor_user_id, ref_table, ref_id, metadata)
  select v_studio, p_member_id, 'message_sent',
         coalesce(msg.sent_at, msg.updated_at),
         'Message sent',
         msg.subject,
         msg.created_by,
         'messages', msg.id,
         jsonb_build_object('status', msg.status, 'template_key', msg.template_key)
    from messages msg
   where msg.member_id = p_member_id
     and msg.status in ('queued', 'sent');

  -- Decision 78: a retention task marked contacted is logged, the same shape and
  -- fields as mark_task_contacted writes, so a rebuild reproduces it exactly.
  insert into timeline_events (studio_id, member_id, type, occurred_at, title, description, actor_user_id, ref_table, ref_id)
  select v_studio, p_member_id, 'contacted',
         mt.contacted_at, 'Contacted', mt.reason, mt.contacted_by,
         'member_tasks', mt.id
    from member_tasks mt
   where mt.member_id = p_member_id
     and mt.status = 'contacted' and mt.contacted_at is not null;

  select count(*) into n from timeline_events where member_id = p_member_id;
  return n;
end $function$;

-- ---------------------------------------------------------------------------
-- member_activity re-issued (from 20260832480000) + a 'contacted' union arm.
create or replace function member_activity(p_member_id uuid, p_from date, p_to date)
returns table (
  at timestamptz, kind text, title text, detail text,
  credit_delta int, balance_after int, amount_cents int, currency text,
  occurrence_id uuid, booking_id uuid, membership_id uuid)
language plpgsql stable security definer set search_path = public as $$
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
           (sum(cl.delta) over (order by cl.created_at, cl.id))::int as bal
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
    -- contacted (staff only) — Decision 78 retention outreach, logged on the task
    select mt.contacted_at, 'contacted', 'Contacted', mt.reason,
           null::uuid, null, null, null, null, null
      from member_tasks mt
     where mt.member_id = p_member_id and v_is_staff
       and mt.status = 'contacted' and mt.contacted_at is not null
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
    x.amount_cents, x.currency, x.occurrence_id, x.booking_id, x.membership_id
  from all_rows x
  left join led l on l.id = x.ledger_id
  where x.at is not null and x.at::date between p_from and p_to
  order by x.at desc, x.kind;
end $$;
revoke execute on function member_activity(uuid, date, date) from public, anon;
grant  execute on function member_activity(uuid, date, date) to authenticated, service_role;
