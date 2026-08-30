-- =============================================================================
-- MIGRATION 018 — Member Health Score (Decision 14)
--
-- A band with a stated reason, not a number. Five signals in priority order;
-- the first to fire sets the band and the reason. Signals are not summed.
--
-- Two things this migration is careful about, because both are the point of the
-- decision rather than details of it:
--
--   * Signal 1 measures a member against THEIR OWN baseline. Nowhere in here
--     is a studio average computed. A twice-weekly member and a fortnightly
--     member are both healthy; comparing either to a mean invents a problem.
--
--   * Reasons name behaviour with numbers in them. "Low engagement" is a label
--     the owner has to decode; "was coming about every 4 days, last visit 16
--     days ago" is a fact they can act on before lunch. Every reason string
--     below interpolates real values, and the test suite fails on categorical
--     language.
-- =============================================================================

alter table members
  add column health_band        text,
  add column health_reason      text,
  add column health_signals     jsonb not null default '[]'::jsonb,
  add column health_computed_at timestamptz;

alter table members
  add constraint members_health_band_known
  check (health_band is null or health_band in
         ('healthy','drifting','at_risk','insufficient_history'));

create index on members (studio_id, health_band) where health_band is not null;

comment on column members.health_band is
  'Decision 14. A cache: derived from check_ins, bookings, memberships and '
  'credit_ledger, never edited in place. If cache and source disagree the '
  'source wins — recompute rather than trusting this column.';
comment on column members.health_reason is
  'Member-level and specific, with real numbers. Never a category.';

-- =============================================================================
-- member_health(member) -> {band, reason, signals}
--
-- Pure: reads, computes, returns. Writes nothing. That is what makes "always
-- recomputable, source wins" true rather than aspirational — the cache is this
-- function's output and can be regenerated at any time.
-- =============================================================================

create function member_health(p_member_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  m            members%rowtype;
  tz           text;
  today        date;
  visits       int;
  last_visit   timestamptz;
  baseline     numeric;      -- median gap in days, the member's own rhythm
  gap_days     numeric;
  signals      jsonb := '[]'::jsonb;
  reason       text;
  band         text;
  severe       boolean := false;   -- signal 1 at >=3x, or signal 4
  -- signal 2
  bk_total     int;  bk_bad int;  bk_attended int;
  -- signal 4
  pd_when      date;
  pack_expired date;
  -- signal 5
  renews       date;  cur_use int;  prev_use int;
begin
  select * into m from members where id = p_member_id;
  if not found then return null; end if;

  select timezone into tz from studios where id = m.studio_id;
  today := (now() at time zone tz)::date;

  select count(*), max(checked_in_at) into visits, last_visit
    from check_ins where member_id = p_member_id;

  -- --- Signal 1: rhythm deviation, against the member's own baseline -------
  -- Minimum 6 visits to establish a baseline; below that there is no rhythm to
  -- deviate from and this signal stays silent rather than guessing.
  if visits >= 6 then
    select percentile_cont(0.5) within group (order by gap) into baseline
      from (
        select extract(epoch from (checked_in_at
               - lag(checked_in_at) over (order by checked_in_at))) / 86400 as gap
          from check_ins where member_id = p_member_id
      ) g where gap is not null;

    gap_days := extract(epoch from (now() - last_visit)) / 86400;

    if baseline is not null and baseline > 0
       and gap_days > greatest(baseline * 2, 10) then
      signals := signals || '"rhythm_deviation"'::jsonb;
      severe  := severe or gap_days >= baseline * 3;
      reason  := format(
        'Was coming about every %s days, last visit %s days ago (%s).',
        round(baseline)::int, floor(gap_days)::int,
        to_char(last_visit at time zone tz, 'FMDD FMMonth'));
    end if;
  end if;

  -- --- Signal 2: booking-to-attendance drift ------------------------------
  -- Intent persists, follow-through is going. Earlier than absence.
  select count(*),
         count(*) filter (where status in ('late_cancelled','no_show')),
         count(*) filter (where status = 'attended')
    into bk_total, bk_bad, bk_attended
    from bookings
   where member_id = p_member_id
     and booked_at >= now() - interval '6 weeks'
     and status in ('attended','no_show','late_cancelled');

  if bk_total >= 4 and bk_bad::numeric / bk_total >= 0.40 then
    signals := signals || '"booking_drift"'::jsonb;
    if reason is null then
      reason := format(
        'Booked %s classes in the last six weeks and attended %s — %s late cancellation%s and %s no-show%s.',
        bk_total, bk_attended,
        (select count(*) from bookings where member_id = p_member_id
          and booked_at >= now() - interval '6 weeks' and status = 'late_cancelled'),
        case when (select count(*) from bookings where member_id = p_member_id
                    and booked_at >= now() - interval '6 weeks' and status = 'late_cancelled') = 1
             then '' else 's' end,
        (select count(*) from bookings where member_id = p_member_id
          and booked_at >= now() - interval '6 weeks' and status = 'no_show'),
        case when (select count(*) from bookings where member_id = p_member_id
                    and booked_at >= now() - interval '6 weeks' and status = 'no_show') = 1
             then '' else 's' end);
    end if;
  end if;

  -- --- Signal 3: the first thirty days -------------------------------------
  if today - m.joined_on between 14 and 35 and visits < 3 then
    signals := signals || '"first_month_stalled"'::jsonb;
    if reason is null then
      reason := format('Joined %s days ago, %s visit%s since.',
                       today - m.joined_on, visits, case when visits = 1 then '' else 's' end);
    end if;
  end if;

  -- --- Signal 4: payment state ---------------------------------------------
  -- Factual rather than predictive, but a live reason they cannot book.
  -- Dated from the failed payment, not from current_period_end: the period end
  -- is in the future for a membership that has only just failed, and a reason
  -- reading "unpaid since 1 September" on 30 August is not a fact.
  select coalesce(
           (select p.created_at::date from payments p
             where p.member_id = p_member_id and p.membership_id = ms.id
               and p.status = 'failed'
             order by p.created_at desc limit 1),
           ms.current_period_start::date)
    into pd_when
    from memberships ms
   where ms.member_id = p_member_id and ms.status = 'past_due'
   order by ms.current_period_end desc nulls last limit 1;

  if pd_when is not null then
    signals := signals || '"payment_state"'::jsonb;
    severe  := true;
    if reason is null then
      reason := format('Membership payment failed on %s, %s days ago.',
                       to_char(pd_when, 'FMDD FMMonth'), today - pd_when);
    end if;
  else
    select ms.expires_on into pack_expired
      from memberships ms join membership_plans p on p.id = ms.plan_id
     where ms.member_id = p_member_id and p.type = 'class_pack'
       and ms.expires_on between today - 30 and today
     order by ms.expires_on desc limit 1;

    if pack_expired is not null
       and not exists (
         select 1 from memberships ms2
          where ms2.member_id = p_member_id
            and ms2.starts_on > pack_expired
       ) then
      signals := signals || '"payment_state"'::jsonb;
      severe  := true;
      if reason is null then
        reason := format('Class pack expired %s days ago and nothing has been bought since.',
                         today - pack_expired);
      end if;
    end if;
  end if;

  -- --- Signal 5: renewal approaching, usage falling ------------------------
  -- Either half alone is not a signal. Together they are the moment someone
  -- decides not to renew.
  select ms.renews_on into renews
    from memberships ms
   where ms.member_id = p_member_id and ms.status = 'active'
     and ms.renews_on between today and today + 21
   order by ms.renews_on limit 1;

  if renews is not null then
    select count(*) into cur_use from check_ins
     where member_id = p_member_id
       and (checked_in_at at time zone tz)::date >= date_trunc('month', today)::date;
    select count(*) into prev_use from check_ins
     where member_id = p_member_id
       and (checked_in_at at time zone tz)::date
           >= (date_trunc('month', today) - interval '1 month')::date
       and (checked_in_at at time zone tz)::date < date_trunc('month', today)::date;

    if prev_use > 0 and cur_use::numeric / prev_use < 0.60 then
      signals := signals || '"expiry_declining_use"'::jsonb;
      if reason is null then
        reason := format(
          'Renews in %s days; %s class%s this period against %s last.',
          renews - today, cur_use, case when cur_use = 1 then '' else 'es' end, prev_use);
      end if;
    end if;
  end if;

  -- --- Band ----------------------------------------------------------------
  if jsonb_array_length(signals) = 0 then
    -- Absence of evidence is not evidence of health. Checked after the signals
    -- rather than before: if something did fire we know a fact about this
    -- member, and a fact beats "we cannot tell".
    if visits < 6 and today - m.joined_on > 35 then
      band := 'insufficient_history';
      reason := format('Only %s visit%s on record since joining %s days ago — not enough to read a pattern.',
                       visits, case when visits = 1 then '' else 's' end, today - m.joined_on);
    else
      band := 'healthy';
      reason := null;
    end if;
  elsif severe or jsonb_array_length(signals) >= 2 then
    band := 'at_risk';
  else
    band := 'drifting';
  end if;

  return jsonb_build_object('band', band, 'reason', reason, 'signals', signals);
end $$;

revoke execute on function member_health(uuid) from public, anon;
grant execute on function member_health(uuid) to authenticated, service_role;

-- =============================================================================
-- Writing the cache
-- =============================================================================

create function refresh_member_health(p_member_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare h jsonb;
begin
  h := member_health(p_member_id);
  if h is null then return null; end if;
  update members
     set health_band        = h ->> 'band',
         health_reason      = h ->> 'reason',
         health_signals     = h -> 'signals',
         health_computed_at = now()
   where id = p_member_id;
  return h;
end $$;

create function refresh_studio_health(p_studio_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare n int := 0; r record;
begin
  if not is_manager_up(p_studio_id) and not is_platform_admin() then
    return 0;
  end if;
  for r in select id from members
            where studio_id = p_studio_id and status <> 'archived'
  loop
    perform refresh_member_health(r.id);
    n := n + 1;
  end loop;
  return n;
end $$;

revoke execute on function refresh_member_health(uuid) from public, anon;
revoke execute on function refresh_studio_health(uuid) from public, anon;
grant execute on function refresh_member_health(uuid) to authenticated, service_role;
grant execute on function refresh_studio_health(uuid) to authenticated, service_role;

-- Nightly is a job; this is the other half of Decision 14's "and on check-in,
-- so a returning member's band updates before they leave the building."
create function health_on_check_in() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform refresh_member_health(new.member_id);
  return new;
end $$;

create trigger check_ins_refresh_health
  after insert on check_ins
  for each row execute function health_on_check_in();

revoke execute on function health_on_check_in() from public, anon, authenticated, service_role;
