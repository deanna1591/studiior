-- =============================================================================
-- 109 — Decision 24: the numbers a studio decides with, and the one message
-- that is worth sending.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- THE REPORT, AND IT STATES BOTH READINGS OF ITS OWN MAIN NUMBER.
--
-- Exhaustion is the figure a studio will act on and it is ambiguous in a way a
-- percentage cannot express by itself. Very high means the cap is too tight and
-- is suppressing revenue — members who would have come are being turned away
-- from a class with seats in it. Near zero means it is not binding at all and
-- the whole apparatus is doing nothing. The middle is where a studio wanted to
-- be. So the function returns a `reading` alongside the number rather than
-- leaving an owner to guess which end they are at.
--
-- Null for a studio with the switch off. Not zeroes — there is nothing to say.
-- -----------------------------------------------------------------------------
create or replace function peak_allowance_report(p_studio_id uuid, p_days int default 90)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  st           studio_settings%rowtype;
  v_from       timestamptz := now() - make_interval(days => p_days);
  v_periods    int;  v_exhausted int;
  v_peak_cls   int;  v_all_cls   int;
  v_holders    int;
  v_inf        int;  v_voided    int;  v_no_show int;
  v_suspended  int;
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'that studio is not yours' using errcode = 'PT403';
  end if;
  select * into st from studio_settings where studio_id = p_studio_id;
  if not coalesce(st.peak_allowance_enabled, false)
     and not coalesce(st.suspension_enabled, false) then
    return null;
  end if;

  -- How much of the timetable is peak at all. A studio whose every class is
  -- peak has not marked its busy hours, it has marked its opening hours.
  select count(*) filter (where occurrence_is_peak(o.id)), count(*)
    into v_peak_cls, v_all_cls
    from class_occurrences o
   where o.studio_id = p_studio_id and o.starts_at >= v_from and o.starts_at < now()
     and o.status in ('scheduled', 'completed');

  select count(*) into v_holders
    from memberships ms join membership_plans mp on mp.id = ms.plan_id
   where ms.studio_id = p_studio_id and mp.peak_allowance is not null
     and ms.status in ('active', 'trialing', 'past_due', 'frozen');

  -- One row per membership per period that SPENT anything, and how many of those
  -- reached nought. Periods nobody touched are not counted: a member who booked
  -- no peak classes in March did not "fail to exhaust" an allowance, and
  -- averaging their nought in would make every cap look loose.
  with spent as (
    select l.membership_id, l.period_start,
           mp.peak_allowance + sum(l.delta) as remaining
      from peak_allowance_ledger l
      join memberships ms on ms.id = l.membership_id
      join membership_plans mp on mp.id = ms.plan_id
     where l.studio_id = p_studio_id and l.created_at >= v_from
     group by l.membership_id, l.period_start, mp.peak_allowance
  )
  select count(*), count(*) filter (where remaining <= 0)
    into v_periods, v_exhausted from spent;

  select count(*), count(*) filter (where status = 'voided'),
         count(*) filter (where kind = 'no_show')
    into v_inf, v_voided, v_no_show
    from member_infractions
   where studio_id = p_studio_id and occurred_at >= v_from;

  select count(*) into v_suspended
    from members m
   where m.studio_id = p_studio_id
     and coalesce((member_suspension(m.id) ->> 'suspended')::boolean, false);

  return jsonb_build_object(
    'days', p_days,
    'peak_classes', v_peak_cls,
    'classes', v_all_cls,
    'peak_share_pct', case when v_all_cls > 0
                           then round(100.0 * v_peak_cls / v_all_cls)::int end,
    'holders', v_holders,
    'periods_used', v_periods,
    'periods_exhausted', v_exhausted,
    'exhaustion_pct', case when v_periods > 0
                           then round(100.0 * v_exhausted / v_periods)::int end,
    -- BOTH READINGS, stated. Thresholds are round numbers on purpose: this is a
    -- sentence to start a conversation, not a measurement to act on blindly.
    'reading', case
      when v_periods = 0 then
        'Nobody has spent a peak class yet, so the limit is not doing anything either way.'
      when 100.0 * v_exhausted / v_periods >= 70 then
        'Most members are hitting the limit. That is a cap set tight enough to turn people away from classes that have seats in them — it is protecting your peak hours and costing you bookings, and which of those matters more is your call.'
      when 100.0 * v_exhausted / v_periods <= 10 then
        'Almost nobody reaches the limit, so it is not binding. Your peak hours are being shared without it, and the limit is doing nothing you could not get by removing it.'
      else
        'A minority reach the limit, which is usually what a studio is aiming for: it bites on the heaviest users and leaves everybody else alone.'
    end,
    'infractions', v_inf,
    'no_shows', v_no_show,
    'excused', v_voided,
    -- THE EXCUSE RATE IS THE SIGNAL THAT THE RULE IS WRONG, which is the whole
    -- reason an excused infraction is voided rather than deleted. A desk
    -- excusing most of them is telling you the threshold is not one they can
    -- defend to a member's face.
    'excused_pct', case when v_inf > 0 then round(100.0 * v_voided / v_inf)::int end,
    'excuse_reading', case
      when v_inf = 0 then null
      when 100.0 * v_voided / v_inf >= 50 then
        'Staff are excusing most infractions, which usually means the rule is one they cannot defend at the counter. Loosen it or stop enforcing it — a rule that is waived by default teaches members it is not real.'
      else null
    end,
    'suspended_now', v_suspended);
end $$;

-- -----------------------------------------------------------------------------
-- THE REMINDER AT THE FREE-WINDOW BOUNDARY.
--
-- The highest-value message in this feature, and the argument is simple: at the
-- moment it is sent, cancelling costs the member nothing and gives the studio a
-- seat it can still fill. An hour later, cancelling costs them a peak slot and
-- the studio has an empty reformer. Every other message in this product reports
-- something that has already happened; this one changes what happens.
--
-- ONLY WHERE IT IS TRUE. Sent for a booking that actually SPENT a peak
-- allowance, at a studio with peak hours on, before a cutoff that has not
-- passed. A studio with the feature off sends nothing, and a member whose
-- cancellation would cost them nothing is not told it will.
-- -----------------------------------------------------------------------------
alter table studio_settings
  add column if not exists peak_cutoff_reminder_minutes int not null default 120;

comment on column studio_settings.peak_cutoff_reminder_minutes is
  'How long before the free-cancellation window closes to remind a member holding a peak class. '
  'Nought switches the reminder off without switching peak hours off.';

alter table studio_settings drop constraint if exists peak_reminder_lead_sane;
alter table studio_settings add constraint peak_reminder_lead_sane
  check (peak_cutoff_reminder_minutes between 0 and 2880);

-- Single braces, which is what render_notification() substitutes, and an
-- html_body, which is NOT NULL — both checked against an existing template
-- rather than assumed.
insert into notification_templates (key, subject, text_body, html_body, note) values (
  'peak_cancel_window',
  '{class_name} — free to cancel until {cutoff_time}',
  E'Hi {first_name},\n\n'
  'You are booked into {class_name} at {class_time} on {class_date}.\n\n'
  'If you cannot make it, cancelling before {cutoff_time} gives you your peak '
  'class back. After that the class is still yours to cancel, but the peak slot '
  'is used either way.\n\n'
  'You have {remaining} peak {remaining_word} left this period.\n\n'
  '{studio_name}',
  '<p>Hi {first_name},</p>'
  '<p>You are booked into <strong>{class_name}</strong> at {class_time} on {class_date}.</p>'
  '<p>If you cannot make it, cancelling before <strong>{cutoff_time}</strong> gives you '
  'your peak class back. After that the class is still yours to cancel, but the peak '
  'slot is used either way.</p>'
  '<p>You have {remaining} peak {remaining_word} left this period.</p>',
  'Decision 24. Sent once, before the free-cancellation window closes, only for a booking that spent a peak allowance.')
on conflict (key) do update
  set subject = excluded.subject, text_body = excluded.text_body,
      html_body = excluded.html_body, note = excluded.note;

create or replace function sweep_peak_cutoff_reminders()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; v_sent int := 0; v_state jsonb; v_rem int;
begin
  if not is_service_context() then
    raise exception 'this is a background job' using errcode = 'PT403';
  end if;

  for r in
    select b.id as booking_id, b.member_id, b.membership_id, b.studio_id,
           o.name, o.starts_at, s.timezone, s.name as studio_name,
           m.first_name,
           o.starts_at - make_interval(mins => ss.cancellation_cutoff_minutes) as cutoff_at
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
      join studios s           on s.id = b.studio_id
      join studio_settings ss  on ss.studio_id = b.studio_id
      join members m           on m.id = b.member_id
     where b.status = 'booked'
       and ss.peak_allowance_enabled
       and ss.peak_cutoff_reminder_minutes > 0
       and o.status = 'scheduled'
       -- Inside the lead-up to the cutoff, and not past it: a reminder that the
       -- free window is closing is worthless once it has closed.
       and now() >= o.starts_at - make_interval(mins => ss.cancellation_cutoff_minutes)
                                - make_interval(mins => ss.peak_cutoff_reminder_minutes)
       and now() <  o.starts_at - make_interval(mins => ss.cancellation_cutoff_minutes)
       -- It spent a peak slot. Nothing else has anything to lose.
       and exists (select 1 from peak_allowance_ledger l
                    where l.booking_id = b.id and l.reason = 'booked')
       and not exists (select 1 from peak_allowance_ledger l
                        where l.booking_id = b.id and l.delta = 1)
  loop
    v_state := peak_allowance_state(r.membership_id,
                                    (r.starts_at at time zone r.timezone)::date);
    v_rem := coalesce((v_state ->> 'remaining')::int, 0);

    if queue_notification(
         r.studio_id, r.member_id, 'peak_cancel_window',
         jsonb_build_object(
           'first_name',  r.first_name,
           'class_name',  r.name,
           'studio_name', r.studio_name,
           'class_time',  to_char(r.starts_at at time zone r.timezone, 'HH24:MI'),
           'class_date',  to_char(r.starts_at at time zone r.timezone, 'FMDay DD FMMonth'),
           'cutoff_time', to_char(r.cutoff_at at time zone r.timezone, 'HH24:MI'),
           'remaining',   v_rem,
           'remaining_word', case when v_rem = 1 then 'class' else 'classes' end),
         -- Keyed on the BOOKING, so a fifteen-minute sweep sends it once and a
         -- member who cancels and rebooks the same class gets a new one.
         'peak_cutoff:' || r.booking_id::text
       ) is not null
    then v_sent := v_sent + 1; end if;
  end loop;

  return jsonb_build_object('sent', v_sent);
end $$;

select cron.schedule('studiior-peak-cutoff-reminders', '*/15 * * * *',
                     $$ select sweep_peak_cutoff_reminders(); $$);

revoke execute on function peak_allowance_report(uuid, int) from public, anon;
grant  execute on function peak_allowance_report(uuid, int) to authenticated, service_role;
revoke execute on function sweep_peak_cutoff_reminders() from public, anon, authenticated;
grant  execute on function sweep_peak_cutoff_reminders() to service_role;

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure::text as sig,
           has_function_privilege('anon', p.oid, 'execute') as anon,
           has_function_privilege('authenticated', p.oid, 'execute') as authed
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('peak_allowance_report', 'sweep_peak_cutoff_reminders')
  loop
    if r.anon then raise exception 'migration 109: % is reachable by anon', r.sig; end if;
    if r.authed and r.sig like 'sweep_%' then
      raise exception 'migration 109: % is reachable by authenticated', r.sig;
    end if;
  end loop;
end $$;
