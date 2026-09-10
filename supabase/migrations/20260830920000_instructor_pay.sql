-- =============================================================================
-- 082  Decision 22, part 3: instructor pay.
-- =============================================================================
-- THIS OVERTURNS PART OF DECISION 10, which put anything resolving to money
-- owed in Wave 3 and drew the boundary at "classes taught multiplied by
-- anything is compensation". That test is exactly why the overturn is necessary
-- rather than optional: guarantee tiers create an obligation the studio owes
-- whether or not the class runs, and an obligation nobody computes is one that
-- gets settled from memory. Decision 10's OTHER half stands unchanged —
-- recognition is not compensation, and a public leaderboard is still a setting,
-- default off.
--
-- THREE THINGS THAT MAKE PAYROLL UNTRUSTWORTHY, and what is done about each:
--
--   a rate change rewriting the past   rates are VERSIONED with an effective
--                                      date and the version used is stored on
--                                      the record
--   recomputing on read                the amount is written ONCE at the
--                                      terminal transition and never derived
--                                      again
--   editing a closed period            a closed period is immutable at the
--                                      trigger level; corrections are
--                                      adjustment lines in the next open one
--
-- MULTI-INSTRUCTOR CLASSES ARE OUT OF SCOPE. One instructor_id, one pay record.
-- Deliberately not half-modelled: there is no array, no join table and no
-- "primary" flag for a later feature to reinterpret.
-- =============================================================================

create type pay_model        as enum ('per_class');
create type pay_record_type  as enum ('class', 'conversion', 'adjustment');
create type pay_period_status as enum ('open', 'closed');
create type session_kind     as enum ('group', 'private', 'duo', 'trio');

-- pay_model carries ONE value on purpose. Adding an enum to a payroll system
-- that already has closed periods and live records is the expensive version of
-- this; 'retainer' arrives later without touching a single existing row.

-- -----------------------------------------------------------------------------
-- Private, duo and trio are CLASS TYPES, not headcounts
-- -----------------------------------------------------------------------------
-- A group class with two people booked is an underfilled group class, not a duo.
-- RPC's price list has Private 1-on-1, Duo and Trio as distinct products at
-- distinct prices, so they are distinct class types with capacities 1, 2 and 3 —
-- and the rate follows the product, never the number of people who turned up.
alter table class_types
  add column if not exists session_kind session_kind not null default 'group';

comment on column class_types.session_kind is
  'What kind of session this product is. private/duo/trio REPLACE the base + '
  'per-head + full-house calculation with their own flat rate. Never inferred '
  'from headcount: an underfilled group class is not a duo.';

-- -----------------------------------------------------------------------------
-- Rate versions
-- -----------------------------------------------------------------------------
create table instructor_rate_versions (
  id             uuid primary key default gen_random_uuid(),
  studio_id      uuid not null references studios(id) on delete cascade,
  instructor_id  uuid not null references instructors(id) on delete cascade,
  effective_from date not null,
  pay_model      pay_model not null default 'per_class',
  -- Descriptive, not a lookup. It is how a studio talks about the rate —
  -- "senior", "standard" — and the rates themselves are on this same row.
  pay_tier            text,
  currency            char(3) not null,
  base_rate_cents     int not null default 0,
  per_head_rate_cents int not null default 0,
  per_head_threshold  int not null default 0,
  -- ITS OWN FIELD, not a steeper final rung. Some studios pay only a cliff at
  -- capacity and no ladder; others only a ladder. It keys off the CLASS's
  -- capacity, which varies by room, never off a number stored here.
  full_house_bonus_cents int not null default 0,
  private_rate_cents  int,
  duo_rate_cents      int,
  trio_rate_cents     int,
  note        text,
  created_by  uuid references auth.users(id),
  created_at  timestamptz not null default now(),
  is_demo     boolean not null default false,
  constraint rate_amounts_non_negative check (
    base_rate_cents >= 0 and per_head_rate_cents >= 0 and per_head_threshold >= 0
    and full_house_bonus_cents >= 0
    and coalesce(private_rate_cents, 0) >= 0
    and coalesce(duo_rate_cents, 0) >= 0
    and coalesce(trio_rate_cents, 0) >= 0),
  unique (instructor_id, effective_from)
);
create index on instructor_rate_versions (instructor_id, effective_from desc);
create index on instructor_rate_versions (studio_id);

-- A VERSION IS HISTORY. Changing a rate means inserting the next version, and
-- editing one in place is the single commonest way a payroll feature quietly
-- starts lying about a period that was already paid.
create or replace function guard_rate_version_immutable()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  raise exception 'a rate version is history: add the next one instead of editing this'
    using errcode = 'PT409',
          hint = 'set_instructor_rate() writes a new version with its own '
                 'effective date. Existing pay records keep the version they '
                 'were calculated with.';
end $$;

create trigger tg_rate_version_immutable
  before update or delete on instructor_rate_versions
  for each row execute function guard_rate_version_immutable();

-- -----------------------------------------------------------------------------
-- Periods
-- -----------------------------------------------------------------------------
create table pay_periods (
  id         uuid primary key default gen_random_uuid(),
  studio_id  uuid not null references studios(id) on delete cascade,
  starts_on  date not null,
  ends_on    date not null,
  status     pay_period_status not null default 'open',
  closed_at  timestamptz,
  closed_by  uuid references auth.users(id),
  created_at timestamptz not null default now(),
  is_demo    boolean not null default false,
  constraint period_dates_ordered check (ends_on >= starts_on),
  unique (studio_id, starts_on)
);
create index on pay_periods (studio_id, starts_on desc);

alter table studio_settings
  add column if not exists pay_period_days   int not null default 14,
  add column if not exists pay_period_anchor date;
alter table studio_settings
  add constraint pay_period_days_sane check (pay_period_days between 1 and 31);

-- -----------------------------------------------------------------------------
-- Pay records
-- -----------------------------------------------------------------------------
-- THE SHAPE, settled now because it is the largest structural change later.
-- occurrence_id is NULLABLE: a conversion bonus and an adjustment belong to an
-- instructor and a period, not to a class.
create table instructor_pay_records (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid not null references studios(id) on delete cascade,
  -- COPIED, never joined live through the occurrence. A substitution next week
  -- must not silently rewrite who was paid last week.
  instructor_id uuid not null references instructors(id),
  period_id     uuid not null references pay_periods(id),
  type          pay_record_type not null,
  -- RESTRICT, not SET NULL. SET NULL would violate this table's own shape check
  -- the moment a class was deleted, and the honest rule is the one migration 078
  -- already applies to a series: you cannot delete a class somebody was paid for.
  occurrence_id uuid references class_occurrences(id) on delete restrict,
  source_id     uuid,          -- the purchase behind a conversion; free for adjustments
  amount_cents  int not null,  -- signed: an adjustment may claw back
  currency      char(3) not null,
  rate_version_id uuid references instructor_rate_versions(id),
  basis         jsonb,         -- what the number was made of, for the statement
  note          text,
  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  is_demo       boolean not null default false,
  constraint pay_record_shape check (
    (type = 'class'      and occurrence_id is not null) or
    (type = 'conversion' and occurrence_id is null and source_id is not null) or
    (type = 'adjustment' and occurrence_id is null))
);
-- One class record per occurrence, ever. The uniqueness is the idempotency:
-- a second evaluation, a retry or a re-run cannot pay for the same class twice.
create unique index pay_one_class_record_per_occurrence
  on instructor_pay_records (occurrence_id) where type = 'class';
create index on instructor_pay_records (studio_id, period_id);
create index on instructor_pay_records (instructor_id, period_id);

-- A CLOSED PERIOD IS IMMUTABLE, at the trigger rather than in a screen, because
-- the same UPDATE goes straight through PostgREST.
create or replace function guard_closed_period()
returns trigger
language plpgsql
set search_path to 'public'
as $$
declare v_status pay_period_status;
begin
  select status into v_status from pay_periods
   where id = coalesce(new.period_id, old.period_id);
  if v_status = 'closed' then
    raise exception 'that pay period is closed'
      using errcode = 'PT409',
            hint = 'Corrections go in the next open period as an adjustment. '
                   'A closed period is what somebody has already been paid.';
  end if;
  return coalesce(new, old);
end $$;

create trigger tg_pay_records_closed_period
  before insert or update or delete on instructor_pay_records
  for each row execute function guard_closed_period();

alter table instructor_rate_versions enable row level security;
alter table pay_periods              enable row level security;
alter table instructor_pay_records   enable row level security;

-- Manager-up writes and reads everything. An instructor reads THEIR OWN records
-- and rates and nothing else — Permissions §11 keeps instructors out of revenue,
-- and what they are paid is theirs.
create policy rates_manager_all on instructor_rate_versions
  for all using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));
create policy rates_own_read on instructor_rate_versions
  for select using (instructor_id in (
    select i.id from instructors i join studio_staff ss on ss.id = i.staff_id
     where ss.user_id = auth.uid()));

create policy periods_manager_all on pay_periods
  for all using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));

create policy pay_manager_all on instructor_pay_records
  for all using (is_manager_up(studio_id)) with check (is_manager_up(studio_id));
create policy pay_own_read on instructor_pay_records
  for select using (instructor_id in (
    select i.id from instructors i join studio_staff ss on ss.id = i.staff_id
     where ss.user_id = auth.uid()));

grant select, insert, update, delete on instructor_rate_versions to authenticated;
grant select, insert, update, delete on pay_periods              to authenticated;
grant select, insert, update, delete on instructor_pay_records   to authenticated;
grant select, insert, update, delete on instructor_rate_versions to service_role;
grant select, insert, update, delete on pay_periods              to service_role;
grant select, insert, update, delete on instructor_pay_records   to service_role;

-- -----------------------------------------------------------------------------
-- The rate in force on a date
-- -----------------------------------------------------------------------------
create or replace function instructor_rate_at(p_instructor_id uuid, p_on date)
returns instructor_rate_versions
language sql
stable
security definer
set search_path to 'public'
as $$
  select * from instructor_rate_versions
   where instructor_id = p_instructor_id and effective_from <= p_on
   order by effective_from desc limit 1;
$$;

create or replace function set_instructor_rate(
  p_instructor_id uuid, p_effective_from date,
  p_base_rate_cents int default 0, p_per_head_rate_cents int default 0,
  p_per_head_threshold int default 0, p_full_house_bonus_cents int default 0,
  p_private_rate_cents int default null, p_duo_rate_cents int default null,
  p_trio_rate_cents int default null, p_pay_tier text default null,
  p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_studio uuid; v_cur char(3); v_id uuid;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(v_studio), false) then
    raise exception 'only owners and managers set a rate' using errcode = 'PT403';
  end if;
  select currency into v_cur from studios where id = v_studio;

  -- Inserting, never updating. If a version already starts on that date this
  -- raises rather than replacing it: overwriting the version a period was paid
  -- from is the exact failure this table exists to prevent.
  insert into instructor_rate_versions (
    studio_id, instructor_id, effective_from, currency, pay_tier,
    base_rate_cents, per_head_rate_cents, per_head_threshold,
    full_house_bonus_cents, private_rate_cents, duo_rate_cents, trio_rate_cents,
    note, created_by)
  values (v_studio, p_instructor_id, p_effective_from, v_cur, p_pay_tier,
          p_base_rate_cents, p_per_head_rate_cents, p_per_head_threshold,
          p_full_house_bonus_cents, p_private_rate_cents, p_duo_rate_cents,
          p_trio_rate_cents, p_note, auth.uid())
  returning id into v_id;

  return jsonb_build_object('ok', true, 'rate_version_id', v_id,
                            'effective_from', p_effective_from);
exception when unique_violation then
  raise exception 'this instructor already has a rate starting on %', p_effective_from
    using errcode = 'PT409',
          hint = 'Pick a different effective date. A version is history and is '
                 'never edited, because a pay record already points at it.';
end $$;

-- -----------------------------------------------------------------------------
-- The period a date belongs to
-- -----------------------------------------------------------------------------
create or replace function ensure_pay_period(p_studio_id uuid, p_on date)
returns pay_periods
language plpgsql
security definer
set search_path to 'public'
as $$
declare p pay_periods%rowtype; v_days int; v_anchor date; v_start date; v_n int;
begin
  select * into p from pay_periods
   where studio_id = p_studio_id and p_on between starts_on and ends_on;
  if found then return p; end if;

  select coalesce(pay_period_days, 14), pay_period_anchor into v_days, v_anchor
    from studio_settings where studio_id = p_studio_id;
  v_days := coalesce(v_days, 14);
  -- Fortnightly by default, counted from the studio's anchor. Whole days in
  -- studio-local dates, never intervals on instants: a period boundary that
  -- moved an hour at a clock change would put a class in the wrong fortnight.
  v_anchor := coalesce(v_anchor, date_trunc('month', p_on)::date);
  v_n := floor((p_on - v_anchor)::numeric / v_days);
  v_start := v_anchor + (v_n * v_days);

  insert into pay_periods (studio_id, starts_on, ends_on)
  values (p_studio_id, v_start, v_start + v_days - 1)
  on conflict (studio_id, starts_on) do update set starts_on = excluded.starts_on
  returning * into p;
  return p;
end $$;

-- The next period that can still take a correction. A clawback or a
-- substitution fix lands here and never in a period somebody has been paid for.
create or replace function next_open_pay_period(p_studio_id uuid)
returns pay_periods
language plpgsql
security definer
set search_path to 'public'
as $$
declare p pay_periods%rowtype; v_tz text; v_today date; v_probe date; v_guard int := 0;
begin
  select timezone into v_tz from studios where id = p_studio_id;
  v_today := (now() at time zone v_tz)::date;

  -- WALKS FORWARD until it finds one that is open. Returning the period that
  -- merely CONTAINS today would hand back a closed one the moment a studio
  -- closes the current fortnight — and then a clawback or a late class would
  -- raise instead of landing somewhere, which is the opposite of what "goes in
  -- the next open period" is for.
  v_probe := v_today;
  loop
    p := ensure_pay_period(p_studio_id, v_probe);
    exit when p.status = 'open';
    v_probe := p.ends_on + 1;
    v_guard := v_guard + 1;
    if v_guard > 60 then
      raise exception 'no open pay period within 60 periods of today'
        using errcode = 'PT409',
              hint = 'Every period from now on is closed. Open one, or let the '
                     'next one be created before recording a correction.';
    end if;
  end loop;
  return p;
end $$;

-- -----------------------------------------------------------------------------
-- What a class is worth
-- -----------------------------------------------------------------------------
-- Pure: it computes and returns, and writes nothing. The write happens once, at
-- the terminal transition, in record_class_pay().
create or replace function compute_class_pay(p_occurrence_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  o class_occurrences%rowtype; s studio_settings%rowtype; g record;
  rv instructor_rate_versions%rowtype; v_kind session_kind; v_tz text;
  v_local date; v_amount int; v_basis jsonb; v_heads int; v_flat int;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if o.instructor_id is null then
    return jsonb_build_object('ok', false, 'reason', 'no instructor on this class');
  end if;

  select * into s from studio_settings where studio_id = o.studio_id;
  select timezone into v_tz from studios where id = o.studio_id;
  v_local := (o.starts_at at time zone v_tz)::date;

  -- The version in force ON THE DAY OF THE CLASS, not today. This is what makes
  -- a rate change next month leave last month alone.
  select * into rv from instructor_rate_at(o.instructor_id, v_local);
  if rv.id is null then
    return jsonb_build_object('ok', false, 'reason', 'no rate on file for that date');
  end if;

  select coalesce(ct.session_kind, 'group') into v_kind
    from class_types ct where ct.id = o.class_type_id;
  v_kind := coalesce(v_kind, 'group');

  select * into g from occurrence_guarantee(p_occurrence_id);
  v_heads := coalesce(o.booked_at_cutoff, 0);

  -- 1. A private, duo or trio REPLACES the whole calculation. Flat, by product.
  if v_kind <> 'group' then
    v_flat := case v_kind
      when 'private' then rv.private_rate_cents
      when 'duo'     then rv.duo_rate_cents
      else                rv.trio_rate_cents end;
    if v_flat is null then
      return jsonb_build_object('ok', false,
        'reason', format('no %s rate on file', v_kind));
    end if;
    -- A private that did not run follows the same cancellation rules as any
    -- other class, against its flat rate rather than a base.
    if o.status = 'cancelled' then
      v_amount := case o.cancellation_cause
        when 'unmet_minimum' then
          case when g.tier = 'flex' then coalesce(s.flex_unmet_pay_cents, 0)
               else (v_flat * coalesce(s.core_unmet_pay_pct, 0)) / 100 end
        when 'studio_fault'  then v_flat
        when 'force_majeure' then 0
        when 'closure'       then case when coalesce(o.cancellation_pays, false) then v_flat else 0 end
        else 0 end;
    else
      v_amount := v_flat;
    end if;
    v_basis := jsonb_build_object('kind', v_kind, 'flat_rate_cents', v_flat,
                                  'status', o.status, 'cause', o.cancellation_cause);

  -- 2. It ran, or it is committed and therefore owed in full whatever happened
  --    afterwards.
  elsif o.status <> 'cancelled' or o.committed_at is not null then
    v_amount := rv.base_rate_cents
              + greatest(0, v_heads - rv.per_head_threshold) * rv.per_head_rate_cents
              -- Keys off THE CLASS's capacity, which varies by room. A capacity
              -- 5 studio and a capacity 6 studio both reach a full house.
              + case when o.capacity is not null and v_heads >= o.capacity
                     then rv.full_house_bonus_cents else 0 end;
    v_basis := jsonb_build_object(
      'kind', 'group', 'base_cents', rv.base_rate_cents,
      'booked_at_cutoff', v_heads, 'capacity', o.capacity,
      'per_head_cents', rv.per_head_rate_cents, 'per_head_threshold', rv.per_head_threshold,
      'heads_paid', greatest(0, v_heads - rv.per_head_threshold),
      'full_house', (o.capacity is not null and v_heads >= o.capacity),
      'full_house_bonus_cents', case when o.capacity is not null and v_heads >= o.capacity
                                     then rv.full_house_bonus_cents else 0 end);

  -- 3. It is not running.
  else
    if o.cancellation_cause = 'unmet_minimum' then
      if g.tier = 'flex' then
        -- Standby is paid when the slot was STANDALONE. A flex class next to
        -- another of the instructor's classes costs them nothing extra; one on
        -- its own cost them the trip. Both settings default to 0, so a studio
        -- that has not set them is unaffected either way.
        v_amount := coalesce(s.flex_unmet_pay_cents, 0)
                  + case when occurrence_is_adjacent(p_occurrence_id)
                         then 0 else coalesce(s.flex_standby_pay_cents, 0) end;
        v_basis := jsonb_build_object('kind', 'group', 'outcome', 'not_running',
          'tier', 'flex', 'unmet_pay_cents', coalesce(s.flex_unmet_pay_cents, 0),
          'standby_cents', case when occurrence_is_adjacent(p_occurrence_id)
                                then 0 else coalesce(s.flex_standby_pay_cents, 0) end,
          'adjacent', occurrence_is_adjacent(p_occurrence_id));
      else
        v_amount := (rv.base_rate_cents * coalesce(s.core_unmet_pay_pct, 0)) / 100;
        v_basis := jsonb_build_object('kind', 'group', 'outcome', 'not_running',
          'tier', 'core', 'base_cents', rv.base_rate_cents,
          'holding_pct', coalesce(s.core_unmet_pay_pct, 0));
      end if;
    else
      v_amount := case o.cancellation_cause
        when 'studio_fault'  then rv.base_rate_cents
        when 'force_majeure' then 0
        when 'closure' then case when coalesce(o.cancellation_pays, false)
                                 then rv.base_rate_cents else 0 end
        else 0 end;
      v_basis := jsonb_build_object('kind', 'group', 'outcome', 'cancelled',
        'cause', o.cancellation_cause, 'base_cents', rv.base_rate_cents,
        'closure_pays', o.cancellation_pays);
    end if;
  end if;

  return jsonb_build_object('ok', true, 'amount_cents', v_amount,
    'currency', rv.currency, 'rate_version_id', rv.id,
    'instructor_id', o.instructor_id, 'local_date', v_local, 'basis', v_basis);
end $$;

-- -----------------------------------------------------------------------------
-- Writing it, once
-- -----------------------------------------------------------------------------
create or replace function record_class_pay(p_occurrence_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare o class_occurrences%rowtype; c jsonb; p pay_periods%rowtype; v_id uuid; v_tz text;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(o.studio_id), false) and not is_service_context() then
    raise exception 'only owners, managers and the sweep write pay' using errcode = 'PT403';
  end if;

  -- Already paid for. The unique index would refuse it anyway; answering here
  -- keeps a retry quiet rather than making it an error somebody has to read.
  if exists (select 1 from instructor_pay_records
              where occurrence_id = p_occurrence_id and type = 'class') then
    return jsonb_build_object('ok', true, 'already_recorded', true);
  end if;

  c := compute_class_pay(p_occurrence_id);
  if not (c ->> 'ok')::boolean then
    return c;  -- no instructor, or no rate on file. Not an error: a studio that
               -- has not set rates yet still runs classes.
  end if;

  select timezone into v_tz from studios where id = o.studio_id;
  p := ensure_pay_period(o.studio_id, (c ->> 'local_date')::date);
  if p.status = 'closed' then
    -- The class belongs to a period already paid. It goes in the next open one
    -- as an adjustment rather than reopening history.
    p := next_open_pay_period(o.studio_id);
    insert into instructor_pay_records (
      studio_id, instructor_id, period_id, type, occurrence_id, amount_cents,
      currency, rate_version_id, basis, note, created_by)
    values (o.studio_id, (c ->> 'instructor_id')::uuid, p.id, 'class',
            p_occurrence_id, (c ->> 'amount_cents')::int, c ->> 'currency',
            (c ->> 'rate_version_id')::uuid, c -> 'basis',
            'Class fell in a closed period; recorded here instead', auth.uid())
    returning id into v_id;
    return jsonb_build_object('ok', true, 'pay_record_id', v_id, 'period_id', p.id,
      'amount_cents', (c ->> 'amount_cents')::int, 'late', true);
  end if;

  insert into instructor_pay_records (
    studio_id, instructor_id, period_id, type, occurrence_id, amount_cents,
    currency, rate_version_id, basis, created_by)
  values (o.studio_id, (c ->> 'instructor_id')::uuid, p.id, 'class',
          p_occurrence_id, (c ->> 'amount_cents')::int, c ->> 'currency',
          (c ->> 'rate_version_id')::uuid, c -> 'basis', auth.uid())
  returning id into v_id;

  return jsonb_build_object('ok', true, 'pay_record_id', v_id, 'period_id', p.id,
    'amount_cents', (c ->> 'amount_cents')::int,
    'rate_version_id', c ->> 'rate_version_id');
end $$;

create or replace function close_pay_period(p_period_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare p pay_periods%rowtype; n int; v_total bigint;
begin
  select * into p from pay_periods where id = p_period_id;
  if not found then raise exception 'no such period' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(p.studio_id), false) then
    raise exception 'only owners and managers close a period' using errcode = 'PT403';
  end if;
  if p.status = 'closed' then
    raise exception 'that period is already closed' using errcode = 'PT409';
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
end $$;

revoke execute on function instructor_rate_at(uuid, date)  from public, anon, authenticated;
revoke execute on function set_instructor_rate(uuid, date, int, int, int, int, int, int, int, text, text)
  from public, anon, authenticated;
revoke execute on function ensure_pay_period(uuid, date)   from public, anon, authenticated;
revoke execute on function next_open_pay_period(uuid)      from public, anon, authenticated;
revoke execute on function compute_class_pay(uuid)         from public, anon, authenticated;
revoke execute on function record_class_pay(uuid)          from public, anon, authenticated;
revoke execute on function close_pay_period(uuid)          from public, anon, authenticated;
revoke execute on function guard_rate_version_immutable()  from public, anon, authenticated;
revoke execute on function guard_closed_period()           from public, anon, authenticated;

grant execute on function instructor_rate_at(uuid, date) to authenticated, service_role;
grant execute on function set_instructor_rate(uuid, date, int, int, int, int, int, int, int, text, text)
  to authenticated;
grant execute on function ensure_pay_period(uuid, date)  to authenticated, service_role;
grant execute on function next_open_pay_period(uuid)     to authenticated, service_role;
grant execute on function compute_class_pay(uuid)        to authenticated, service_role;
grant execute on function record_class_pay(uuid)         to authenticated, service_role;
grant execute on function close_pay_period(uuid)         to authenticated;

-- -----------------------------------------------------------------------------
-- Pay is written AT the terminal transition, by a trigger
-- -----------------------------------------------------------------------------
-- A trigger rather than a call in each of evaluate_commitment(),
-- force_commit_occurrence() and cancel_occurrence(). A class reaches a terminal
-- state from several directions and a write that depends on each caller
-- remembering is one the next caller will miss — migration 031's lesson, and the
-- reason notifications are wired this way too.
--
-- record_class_pay() is idempotent: one class record per occurrence is a unique
-- index, and it answers quietly rather than raising when one already exists. So
-- a class that commits and is later cancelled keeps the pay it was committed
-- for, which is what "committed is terminal" means in money.
create or replace function tg_record_class_pay()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  -- INSERT counts too. A row that arrives already committed — an import, a
  -- fixture, a backfill — is still a class somebody is owed for, and "committed
  -- implies paid" has to hold however the row got there rather than only on the
  -- one path that happens to be an UPDATE today.
  if tg_op = 'INSERT' then
    if new.committed_at is not null or new.status = 'cancelled' then
      perform record_class_pay(new.id);
    end if;
  elsif (new.committed_at is not null and old.committed_at is null)
     or (new.status = 'cancelled' and old.status is distinct from new.status) then
    perform record_class_pay(new.id);
  end if;
  return new;
end $$;

create trigger tg_occurrence_record_pay
  after insert or update on class_occurrences
  for each row execute function tg_record_class_pay();

revoke execute on function tg_record_class_pay() from public, anon, authenticated;
