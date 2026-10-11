-- Decision 75a — Statements: occurrence history, attendance finalisation, and
-- the member activity statement.
--
-- (b) occurrence_events — a per-occurrence history (moved / instructor_changed /
--     cancelled / committed / reopened), written by a trigger on
--     class_occurrences rather than by editing the eight write sites
--     (move_occurrence, reassign_occurrence, cancel_occurrence,
--     cancel_occurrences_for_period, open_shift, assign_occurrences_for_period_run,
--     force_commit_occurrence, the commit sweep). The trigger captures the SAME
--     column changes those functions make — a single, comprehensive capture that
--     avoids re-issuing eight book-critical scheduling functions right before the
--     9 Nov timeline start. history starts now (the trigger only fires on updates
--     from here on).
-- (c) Attendance finalisation — studio_settings.finalise_attendance (default
--     false; Reform turns it on). finalise_attendance_sweep() marks any booking
--     still `booked` as `no_show` (no_show_at = now, actor null) at midnight
--     studio time finalise_days_after the class, independent of the suspension
--     switch, stamps class_occurrences.attendance_finalised_at, and queues the
--     instructor an `instructor_unmarked_bookings` reminder once per occurrence.
--     It NEVER creates infractions (that stays sweep_no_shows).
-- (a) member_activity(member, from, to) — the itemised statement reader: ONE row
--     per event (a booking row carries its own ledger consume via
--     bookings.credit_entry_id; a cancellation row its cancellation_refund; a
--     purchase/refund row its matched grant/forfeit; unclaimed ledger rows appear
--     as their own "Credits added"/"Credit adjustment" lines), with a running
--     balance computed from credit_ledger (sum of deltas in (created_at, id)
--     order). Self-scoped (the member) OR studio staff; no anon.
--
-- No new anon RPC — anon stays EXACTLY THIRTEEN.
--
-- creates: tg_occurrence_events(), finalise_attendance_sweep(), member_activity(uuid, date, date)

-- =============================================================================
-- 1. occurrence_events
-- =============================================================================
create table occurrence_events (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid not null references studios(id) on delete cascade,
  occurrence_id uuid not null references class_occurrences(id) on delete cascade,
  kind          text not null check (kind in ('moved','instructor_changed','cancelled','committed','reopened')),
  before        jsonb,
  after         jsonb,
  actor_user_id uuid,
  at            timestamptz not null default now()
);
create index occurrence_events_occ_idx on occurrence_events (occurrence_id, at);
create index occurrence_events_studio_idx on occurrence_events (studio_id, at);

alter table occurrence_events enable row level security;

-- Staff of the studio read all of it; a member reads events for an occurrence
-- they hold a booking on. No client write policy — only the SECURITY DEFINER
-- trigger writes (it runs as owner and bypasses RLS).
create policy occurrence_events_staff_read on occurrence_events for select
  using (coalesce(is_desk_up(studio_id), false)
         or exists (select 1 from instructors i join studio_staff ss on ss.id = i.staff_id
                     where i.studio_id = occurrence_events.studio_id and ss.user_id = auth.uid()));
create policy occurrence_events_member_read on occurrence_events for select
  using (exists (select 1 from bookings b join members m on m.id = b.member_id
                  where b.occurrence_id = occurrence_events.occurrence_id
                    and m.user_id = auth.uid()));

grant select on occurrence_events to authenticated, service_role;

-- The capture. AFTER UPDATE on the columns a move / reassign / cancel / open /
-- assign / commit changes. Multiple kinds can fire in one update (a move that
-- also changes instructor emits both). Demo occurrences are skipped so the table
-- holds only real history (and so purge_demo_data needs no change).
create or replace function tg_occurrence_events()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_actor uuid := auth.uid();
begin
  if coalesce(new.is_demo, false) then return new; end if;

  -- moved: time or room changed.
  if new.starts_at is distinct from old.starts_at
     or new.ends_at is distinct from old.ends_at
     or new.room_id is distinct from old.room_id then
    insert into occurrence_events (studio_id, occurrence_id, kind, before, after, actor_user_id)
    values (new.studio_id, new.id, 'moved',
            jsonb_build_object('starts_at', old.starts_at, 'ends_at', old.ends_at, 'room_id', old.room_id),
            jsonb_build_object('starts_at', new.starts_at, 'ends_at', new.ends_at, 'room_id', new.room_id),
            v_actor);
  end if;

  -- instructor_changed: assigned, reassigned or cleared (open shift).
  if new.instructor_id is distinct from old.instructor_id then
    insert into occurrence_events (studio_id, occurrence_id, kind, before, after, actor_user_id)
    values (new.studio_id, new.id, 'instructor_changed',
            jsonb_build_object('instructor_id', old.instructor_id, 'staffing', old.staffing),
            jsonb_build_object('instructor_id', new.instructor_id, 'staffing', new.staffing),
            v_actor);
  end if;

  -- cancelled / reopened.
  if new.status is distinct from old.status then
    if new.status = 'cancelled' then
      insert into occurrence_events (studio_id, occurrence_id, kind, before, after, actor_user_id)
      values (new.studio_id, new.id, 'cancelled',
              jsonb_build_object('status', old.status),
              jsonb_build_object('status', new.status, 'cause', new.cancellation_cause),
              v_actor);
    elsif old.status = 'cancelled' and new.status = 'scheduled' then
      insert into occurrence_events (studio_id, occurrence_id, kind, before, after, actor_user_id)
      values (new.studio_id, new.id, 'reopened',
              jsonb_build_object('status', old.status),
              jsonb_build_object('status', new.status),
              v_actor);
    end if;
  end if;

  -- committed: the cutoff (or force-commit) latched the class.
  if new.committed_at is not null and old.committed_at is null then
    insert into occurrence_events (studio_id, occurrence_id, kind, before, after, actor_user_id)
    values (new.studio_id, new.id, 'committed',
            jsonb_build_object('committed_at', old.committed_at),
            jsonb_build_object('committed_at', new.committed_at, 'booked_at_cutoff', new.booked_at_cutoff),
            v_actor);
  end if;

  return new;
end $$;
revoke execute on function tg_occurrence_events() from public, anon, authenticated, service_role;

create trigger occurrence_events_capture
  after update of starts_at, ends_at, room_id, instructor_id, status, committed_at
  on class_occurrences
  for each row execute function tg_occurrence_events();

-- =============================================================================
-- 2. no-show provenance + finalisation stamp + the switch
-- =============================================================================
alter table bookings
  add column if not exists no_show_at timestamptz,
  add column if not exists no_show_by uuid;

alter table class_occurrences
  add column if not exists attendance_finalised_at timestamptz;

alter table studio_settings
  add column if not exists finalise_attendance boolean not null default false,
  add column if not exists finalise_days_after int not null default 1;
alter table studio_settings
  add constraint studio_settings_finalise_days check (finalise_days_after between 0 and 7);

-- =============================================================================
-- 3. finalise_attendance_sweep — booked -> no_show past the boundary, for
--    studios with the switch on. No infractions (that is sweep_no_shows).
-- =============================================================================
insert into notification_templates (key, subject, text_body, html_body, note) values
('instructor_unmarked_bookings',
 'Unmarked bookings for {class_name}',
 E'Hi {first_name},\n\n{count} booking(s) on {class_name} ({when}) were not marked as attended, so they have been recorded as no-shows. If that is wrong, tell the studio.\n\n{studio_name}',
 E'<p>Hi {first_name},</p><p>{count} booking(s) on {class_name} ({when}) were not marked as attended, so they have been recorded as no-shows. If that is wrong, tell the studio.</p><p>{studio_name}</p>',
 'Decision 75a. Queued once per occurrence the morning after finalisation when bookings were auto-marked no-show.')
on conflict (key) do nothing;

create or replace function finalise_attendance_sweep()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_marked int := 0; v_occs int := 0; r record; v_n int; v_tz text; v_fname text; v_when text; v_morning timestamptz;
begin
  if not is_service_context() then
    raise exception 'the finalisation sweep is a background job' using errcode = 'PT403';
  end if;

  for r in
    select o.id, o.studio_id, o.name, o.starts_at, o.ends_at, o.instructor_id, s.timezone as tz, s.name as studio_name
      from class_occurrences o
      join studios s on s.id = o.studio_id
      join studio_settings ss on ss.studio_id = o.studio_id
     where ss.finalise_attendance
       and o.status = 'scheduled'
       and o.attendance_finalised_at is null
       and o.ends_at < now()
       -- midnight studio time, finalise_days_after days after the class's local day
       and now() >= (((o.ends_at at time zone s.timezone)::date + ss.finalise_days_after)::timestamp at time zone s.timezone)
  loop
    update bookings set status = 'no_show', no_show_at = now(), no_show_by = null, updated_at = now()
     where occurrence_id = r.id and status = 'booked';
    get diagnostics v_n = row_count;

    update class_occurrences set attendance_finalised_at = now(), updated_at = now() where id = r.id;
    v_occs := v_occs + 1;
    v_marked := v_marked + v_n;

    -- Tell the instructor (if they have a login), once per occurrence, scheduled
    -- for 08:00 studio-local of the finalisation day. Only when something was
    -- auto-marked.
    if v_n > 0 and r.instructor_id is not null and instructor_user_id(r.instructor_id) is not null then
      v_tz := r.tz;
      select split_part(coalesce(i.display_name, ''), ' ', 1) into v_fname
        from instructors i where i.id = r.instructor_id;
      v_when := to_char(r.starts_at at time zone v_tz, 'FMDay FMDD FMMon, HH24:MI');
      v_morning := (date_trunc('day', now() at time zone v_tz) + interval '8 hours') at time zone v_tz;
      insert into notifications (studio_id, recipient_type, user_id, template_key, channel,
                                 payload, dedupe_key, scheduled_for, status)
      values (r.studio_id, 'staff', instructor_user_id(r.instructor_id), 'instructor_unmarked_bookings', 'email',
              jsonb_build_object('first_name', coalesce(nullif(v_fname, ''), 'there'),
                                 'count', v_n, 'class_name', r.name, 'when', v_when,
                                 'studio_name', r.studio_name),
              'unmarked:' || r.id::text, v_morning, 'scheduled')
      on conflict (dedupe_key) do nothing;
    end if;
  end loop;

  insert into job_runs (job_key, run_for, status, finished_at)
  values ('finalise_attendance', current_date, 'done', now())
  on conflict (job_key, run_for) do update
     set attempts = job_runs.attempts + 1, started_at = now(), status = 'done', finished_at = now();

  return jsonb_build_object('occurrences', v_occs, 'marked', v_marked);
end $$;
revoke execute on function finalise_attendance_sweep() from public, anon, authenticated;
grant  execute on function finalise_attendance_sweep() to service_role;

select cron.schedule('studiior-finalise-attendance', '15 * * * *',
  $$select finalise_attendance_sweep()$$);

-- =============================================================================
-- 4. member_activity — the itemised statement, ONE row per event.
-- =============================================================================
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
                else 'Booked ' || coalesce(o.name, 'a class') end,
           case when exists (select 1 from waitlist_offers wo where wo.booking_id = b.id and wo.outcome = 'accepted')
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

-- =============================================================================
-- Anon surface stays EXACTLY THIRTEEN.
-- =============================================================================
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then
    raise exception 'anon surface is % functions, expected exactly 13', n;
  end if;
end $$;
