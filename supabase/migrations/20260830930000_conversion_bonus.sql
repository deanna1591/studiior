-- =============================================================================
-- 083  Decision 22: the conversion bonus.
-- =============================================================================
-- Per studio, default off. It pays the instructor who taught a member's FIRST
-- EVER class when that member later buys something that counts.
--
-- FIRST EVER, NOT MOST RECENT. Last-class attribution rewards whoever happened
-- to be teaching on the day somebody's card went through, which is close to
-- random and rewards nothing anybody did. The first class is the one that
-- decided whether they came back.
-- =============================================================================

alter table studio_settings
  add column if not exists conversion_bonus_enabled boolean not null default false,
  add column if not exists conversion_bonus_cents   int     not null default 0,
  add column if not exists conversion_window_days   int     not null default 30,
  add column if not exists conversion_attribution   text    not null default 'first_class';
alter table studio_settings
  add constraint conversion_bonus_sane check (conversion_bonus_cents >= 0),
  add constraint conversion_window_sane check (conversion_window_days between 1 and 365),
  add constraint conversion_attribution_known
    check (conversion_attribution in ('first_class'));

-- WHICH PLANS COUNT, and this deviates from the brief's shape deliberately.
-- The brief named a `conversion_qualifying_plans` setting. It is a column on the
-- PLAN instead, because an allowlist held as an array of ids on the studio has
-- no referential integrity and goes stale the moment a plan is archived — and
-- because "a trial or intro plan must not itself count" is guaranteed by the
-- DEFAULT here rather than by somebody remembering to leave it out of a list.
-- A plan counts only if a studio has said so.
alter table membership_plans
  add column if not exists counts_for_conversion boolean not null default false;

comment on column membership_plans.counts_for_conversion is
  'Whether buying this plan earns the first-class instructor a conversion bonus. '
  'Default false, so a trial or intro offer never converts unless a studio '
  'deliberately says it does.';

-- One bonus per member, ever. A unique index rather than a check inside the
-- function: the index holds against every writer, including a retry, a second
-- membership bought the same minute, and anything written by hand.
create unique index pay_one_conversion_per_member
  on instructor_pay_records (studio_id, source_id)
  where type = 'conversion';

-- source_id on a conversion record is the MEMBER, not the payment: the rule is
-- one bonus per member ever, so that is what has to be unique. The membership
-- and plan that triggered it are in `basis`.

-- -----------------------------------------------------------------------------
-- Who taught them first
-- -----------------------------------------------------------------------------
create or replace function member_first_class(p_member_id uuid)
returns table (occurrence_id uuid, instructor_id uuid, attended_at timestamptz)
language sql
stable
security definer
set search_path to 'public'
as $$
  -- A class they actually turned up to. A booking they never attended did not
  -- convert anybody, and an imported visit has no occurrence and so no
  -- instructor to credit — both fall out of this naturally.
  select o.id, o.instructor_id, c.checked_in_at
    from check_ins c
    join class_occurrences o on o.id = c.occurrence_id
   where c.member_id = p_member_id
     and o.instructor_id is not null
   order by c.checked_in_at
   limit 1;
$$;

-- -----------------------------------------------------------------------------
-- Awarding it
-- -----------------------------------------------------------------------------
-- Fired by a TRIGGER on memberships, which is where both payment paths already
-- converge: activate_purchase() inserts the membership, and per Decision 16 it
-- is called by the Stripe handler AND by record_manual_payment(). Hooking the
-- Stripe checkout instead would pay nothing to a studio taking cash, which is
-- most of them.
create or replace function award_conversion_bonus(p_membership_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  m memberships%rowtype; s studio_settings%rowtype; pl membership_plans%rowtype;
  f record; p pay_periods%rowtype; v_tz text; v_first date; v_buy date; v_id uuid;
  v_name text;
begin
  select * into m from memberships where id = p_membership_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such membership'); end if;

  select * into s from studio_settings where studio_id = m.studio_id;
  if not coalesce(s.conversion_bonus_enabled, false) then
    return jsonb_build_object('ok', true, 'awarded', false, 'reason', 'not enabled');
  end if;
  if coalesce(s.conversion_bonus_cents, 0) = 0 then
    return jsonb_build_object('ok', true, 'awarded', false, 'reason', 'bonus is zero');
  end if;

  select * into pl from membership_plans where id = m.plan_id;
  if not coalesce(pl.counts_for_conversion, false) then
    return jsonb_build_object('ok', true, 'awarded', false,
                              'reason', 'plan does not count for conversion');
  end if;

  select * into f from member_first_class(m.member_id);
  if f.instructor_id is null then
    return jsonb_build_object('ok', true, 'awarded', false,
                              'reason', 'no attended class to attribute to');
  end if;

  select timezone into v_tz from studios where id = m.studio_id;
  v_first := (f.attended_at at time zone v_tz)::date;
  v_buy   := (coalesce(m.created_at, now()) at time zone v_tz)::date;
  if v_buy - v_first > coalesce(s.conversion_window_days, 30) then
    return jsonb_build_object('ok', true, 'awarded', false, 'reason', 'outside the window',
      'days', v_buy - v_first, 'window', s.conversion_window_days);
  end if;

  select btrim(coalesce(preferred_name, first_name) || ' ' || coalesce(last_name, ''))
    into v_name from members where id = m.member_id;
  p := next_open_pay_period(m.studio_id);

  begin
    insert into instructor_pay_records (
      studio_id, instructor_id, period_id, type, source_id, amount_cents, currency,
      basis, note, created_by)
    values (m.studio_id, f.instructor_id, p.id, 'conversion', m.member_id,
            s.conversion_bonus_cents,
            (select currency from studios where id = m.studio_id),
            jsonb_build_object('member_id', m.member_id, 'member_name', v_name,
              'plan_id', pl.id, 'plan_name', pl.name, 'membership_id', m.id,
              'first_class_occurrence', f.occurrence_id,
              'first_class_on', v_first, 'purchased_on', v_buy,
              'attribution', 'first_class'),
            'Conversion bonus', auth.uid())
    returning id into v_id;
  exception when unique_violation then
    -- One per member EVER. A second qualifying purchase is not a second bonus.
    return jsonb_build_object('ok', true, 'awarded', false,
                              'reason', 'this member has already converted');
  end;

  return jsonb_build_object('ok', true, 'awarded', true, 'pay_record_id', v_id,
    'instructor_id', f.instructor_id, 'amount_cents', s.conversion_bonus_cents);
end $$;

create or replace function tg_award_conversion_bonus()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  -- Only a membership that is actually live. A pending or failed one has not
  -- converted anybody yet.
  if new.status in ('active', 'trialing') then
    perform award_conversion_bonus(new.id);
  end if;
  return new;
end $$;

create trigger tg_memberships_conversion_bonus
  after insert on memberships
  for each row execute function tg_award_conversion_bonus();

-- -----------------------------------------------------------------------------
-- Clawing it back
-- -----------------------------------------------------------------------------
-- A refund does not edit the bonus. The period it was paid in may be closed, and
-- a closed period is what somebody has already been paid — so the correction is
-- an ADJUSTMENT in the next open one, which is the same mechanism a mis-recorded
-- substitution uses.
create or replace function claw_back_conversion_bonus(p_member_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare r instructor_pay_records%rowtype; p pay_periods%rowtype; v_id uuid;
begin
  select * into r from instructor_pay_records
   where type = 'conversion' and source_id = p_member_id
   order by created_at limit 1;
  if not found then
    return jsonb_build_object('ok', true, 'clawed_back', false, 'reason', 'no bonus to reverse');
  end if;
  if not coalesce(is_manager_up(r.studio_id), false) and not is_service_context() then
    raise exception 'only owners and managers reverse a bonus' using errcode = 'PT403';
  end if;
  if exists (select 1 from instructor_pay_records
              where type = 'adjustment' and source_id = p_member_id
                and basis ->> 'reverses' = r.id::text) then
    return jsonb_build_object('ok', true, 'clawed_back', false, 'reason', 'already reversed');
  end if;

  p := next_open_pay_period(r.studio_id);
  insert into instructor_pay_records (
    studio_id, instructor_id, period_id, type, source_id, amount_cents, currency,
    basis, note, created_by)
  values (r.studio_id, r.instructor_id, p.id, 'adjustment', p_member_id,
          -r.amount_cents, r.currency,
          jsonb_build_object('reverses', r.id, 'original_period', r.period_id,
                             'reason', coalesce(p_reason, 'refund')),
          'Conversion bonus reversed: ' || coalesce(p_reason, 'refund'), auth.uid())
  returning id into v_id;

  return jsonb_build_object('ok', true, 'clawed_back', true, 'adjustment_id', v_id,
    'amount_cents', -r.amount_cents, 'period_id', p.id);
end $$;

revoke execute on function member_first_class(uuid)            from public, anon, authenticated;
revoke execute on function award_conversion_bonus(uuid)        from public, anon, authenticated;
revoke execute on function tg_award_conversion_bonus()         from public, anon, authenticated;
revoke execute on function claw_back_conversion_bonus(uuid, text) from public, anon, authenticated;
grant execute on function member_first_class(uuid)             to authenticated, service_role;
grant execute on function award_conversion_bonus(uuid)         to authenticated, service_role;
grant execute on function claw_back_conversion_bonus(uuid, text) to authenticated, service_role;

-- A FULL refund reverses the bonus; a partial one does not. Same rule migration
-- 040 already applies to credits: what a half-refunded pack is worth is the
-- studio's judgement, not a function's guess. Wired to the payment rather than
-- called from record_refund(), so a refund recorded by any other path reverses
-- it too.
create or replace function tg_refund_claws_back_bonus()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if new.member_id is not null
     and coalesce(new.refunded_cents, 0) >= new.amount_cents
     and coalesce(old.refunded_cents, 0) < old.amount_cents then
    perform claw_back_conversion_bonus(new.member_id, 'payment refunded in full');
  end if;
  return new;
end $$;

create trigger tg_payments_claw_back_bonus
  after update of refunded_cents on payments
  for each row execute function tg_refund_claws_back_bonus();

revoke execute on function tg_refund_claws_back_bonus() from public, anon, authenticated;
