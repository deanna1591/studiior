-- =============================================================================
-- 086  Eight SECURITY DEFINER functions from 080-083 had no guard inside them.
-- =============================================================================
-- Found by running the advisor query against hosted after 085 landed, and then
-- asking the other half of the question — which is the half migration 056 was
-- written about. The grant surface was CORRECT: everything 079-085 created is
-- closed to anon, and the triggers are callable by nobody. What was wrong is
-- what happens INSIDE a function once a signed-in user reaches it.
--
-- REPRODUCED as an ordinary member of Reform Collective — not staff, not an
-- instructor, no relationship whatever to the studio being read. The direct
-- reads return 0 rows, which is what makes the diagnosis certain: RLS was
-- working and the wrappers walked around it.
--
--   instructor_rate_at      -> 80000            a named instructor's base rate
--   compute_class_pay       -> the whole calculation: base, per-head, threshold,
--                              full-house bonus and the total owed
--   member_first_class      -> which instructor taught a named member first
--   occurrence_guarantee    -> another studio's tier and minimum
--   occurrence_is_adjacent  -> true             a boolean about somebody's day
--   ensure_pay_period       -> CREATED A ROW in another studio
--   next_open_pay_period    -> CREATED A ROW in another studio
--   award_conversion_bonus  -> ran against another studio's membership
--
-- Rate versions and pay records are money owed to a named person. Six of these
-- read that; two of them write.
--
-- EVERY SECURITY DEFINER FUNCTION THAT TAKES AN ID AND RETURNS TENANT DATA NEEDS
-- ITS OWN CHECK. The grant is not one, and the rule was already in CLAUDE.md.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Who may see what one instructor is paid
-- -----------------------------------------------------------------------------
-- Manager-up of that instructor's studio, or the instructor themselves. An
-- instructor reading their own rate is the point of the feature; reading
-- somebody else's is Permissions §11 in reverse.
create or replace function is_this_instructor(p_instructor_id uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(exists (
    select 1 from instructors i
      join studio_staff ss on ss.id = i.staff_id
     where i.id = p_instructor_id and ss.user_id = auth.uid()
  ), false);
$$;

create or replace function instructor_rate_at(p_instructor_id uuid, p_on date)
returns instructor_rate_versions
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_studio uuid; rv instructor_rate_versions%rowtype;
begin
  select studio_id into v_studio from instructors where id = p_instructor_id;
  if v_studio is null then
    raise exception 'no such instructor' using errcode = 'PT404';
  end if;
  if not coalesce(is_manager_up(v_studio), false)
     and not is_this_instructor(p_instructor_id)
     and not is_service_context() then
    raise exception 'that is not your rate' using errcode = 'PT403';
  end if;
  select * into rv from instructor_rate_versions
   where instructor_id = p_instructor_id and effective_from <= p_on
   order by effective_from desc limit 1;
  return rv;
end $$;

-- -----------------------------------------------------------------------------
-- What a class is worth
-- -----------------------------------------------------------------------------
-- The calculation names a rate and a total owed. Manager-up of that class's
-- studio, the instructor teaching it, or the sweep.
--
-- The internal is UNGUARDED and callable by nobody, because record_class_pay()
-- and the statement need it after their own check has already passed and an
-- instructor must not be refused their own class's number. Same shape as
-- migration 059's rebuild_timeline_rows behind rebuild_member_timeline.
alter function compute_class_pay(uuid) rename to compute_class_pay_run;

create or replace function compute_class_pay(p_occurrence_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare o class_occurrences%rowtype;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(o.studio_id), false)
     and not (o.instructor_id is not null and is_this_instructor(o.instructor_id))
     and not is_service_context() then
    raise exception 'that is not your class to price' using errcode = 'PT403';
  end if;
  return compute_class_pay_run(p_occurrence_id);
end $$;

-- -----------------------------------------------------------------------------
-- A member's first class
-- -----------------------------------------------------------------------------
-- Staff of that studio. Front desk may read a member's visit history under
-- Permissions §5, and this is a fact about one visit.
alter function member_first_class(uuid) rename to member_first_class_run;

create or replace function member_first_class(p_member_id uuid)
returns table (occurrence_id uuid, instructor_id uuid, attended_at timestamptz)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_studio uuid;
begin
  select studio_id into v_studio from members where id = p_member_id;
  if v_studio is null then raise exception 'no such member' using errcode = 'PT404'; end if;
  if not coalesce(is_desk_up(v_studio), false) and not is_service_context() then
    raise exception 'that is not your member' using errcode = 'PT403';
  end if;
  return query select * from member_first_class_run(p_member_id);
end $$;

-- -----------------------------------------------------------------------------
-- The tier, the cutoff, and whether a slot stands alone
-- -----------------------------------------------------------------------------
-- Staff of that studio, any role: an instructor needs to know whether their own
-- class is a flex slot and when it decides. Not members — a member is never
-- told a class might not run, which is Decision 21's whole point.
alter function occurrence_guarantee(uuid) rename to occurrence_guarantee_run;

create or replace function occurrence_guarantee(p_occurrence_id uuid)
returns table (tier guarantee_tier, minimum int, cutoff_at timestamptz, cutoff_shape text)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_studio uuid;
begin
  select studio_id into v_studio from class_occurrences where id = p_occurrence_id;
  if v_studio is null then return; end if;
  if v_studio not in (select auth_staff_studios()) and not is_service_context() then
    raise exception 'that is not your studio''s timetable' using errcode = 'PT403';
  end if;
  return query select * from occurrence_guarantee_run(p_occurrence_id);
end $$;

alter function occurrence_is_adjacent(uuid) rename to occurrence_is_adjacent_run;

create or replace function occurrence_is_adjacent(p_occurrence_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_studio uuid;
begin
  select studio_id into v_studio from class_occurrences where id = p_occurrence_id;
  if v_studio is null then return false; end if;
  if v_studio not in (select auth_staff_studios()) and not is_service_context() then
    raise exception 'that is not your studio''s timetable' using errcode = 'PT403';
  end if;
  return occurrence_is_adjacent_run(p_occurrence_id);
end $$;

-- -----------------------------------------------------------------------------
-- The two that WROTE
-- -----------------------------------------------------------------------------
-- ensure_pay_period() and next_open_pay_period() create a pay period row. They
-- are pure internals — record_class_pay() and the bonus reach them after their
-- own checks — so rather than a guard they lose their grant entirely. Closed to
-- every client role is a stronger statement than a check, and it is what
-- "functions are closed by default" means when nothing outside should call them.

-- award_conversion_bonus() is reached from a TRIGGER on memberships, and the
-- person who caused that insert may be front desk selling a pack, or the Stripe
-- webhook with no session at all. A manager-up check on the public entry point
-- would refuse a legitimate counter sale, so the trigger calls the unguarded
-- internal and the public name gets the check.
alter function award_conversion_bonus(uuid) rename to award_conversion_bonus_run;

create or replace function award_conversion_bonus(p_membership_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_studio uuid;
begin
  select studio_id into v_studio from memberships where id = p_membership_id;
  if v_studio is null then raise exception 'no such membership' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(v_studio), false) and not is_service_context() then
    raise exception 'only owners and managers award a bonus by hand' using errcode = 'PT403';
  end if;
  return award_conversion_bonus_run(p_membership_id);
end $$;

create or replace function tg_award_conversion_bonus()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  -- The internal, deliberately: whoever legitimately caused this insert — front
  -- desk at the counter, or a webhook with no session — must not be refused.
  if new.status in ('active', 'trialing') then
    perform award_conversion_bonus_run(new.id);
  end if;
  return new;
end $$;

-- -----------------------------------------------------------------------------
-- Grants: the internals are callable by nobody, the entry points by clients
-- -----------------------------------------------------------------------------
revoke execute on function compute_class_pay_run(uuid)        from public, anon, authenticated;
revoke execute on function member_first_class_run(uuid)       from public, anon, authenticated;
revoke execute on function occurrence_guarantee_run(uuid)     from public, anon, authenticated;
revoke execute on function occurrence_is_adjacent_run(uuid)   from public, anon, authenticated;
revoke execute on function award_conversion_bonus_run(uuid)   from public, anon, authenticated;
revoke execute on function ensure_pay_period(uuid, date)      from public, anon, authenticated;
revoke execute on function next_open_pay_period(uuid)         from public, anon, authenticated;

revoke execute on function is_this_instructor(uuid)           from public, anon, authenticated;
revoke execute on function instructor_rate_at(uuid, date)     from public, anon, authenticated;
revoke execute on function compute_class_pay(uuid)            from public, anon, authenticated;
revoke execute on function member_first_class(uuid)           from public, anon, authenticated;
revoke execute on function occurrence_guarantee(uuid)         from public, anon, authenticated;
revoke execute on function occurrence_is_adjacent(uuid)       from public, anon, authenticated;
revoke execute on function award_conversion_bonus(uuid)       from public, anon, authenticated;
revoke execute on function tg_award_conversion_bonus()        from public, anon, authenticated;

grant execute on function is_this_instructor(uuid)         to authenticated, service_role;
grant execute on function instructor_rate_at(uuid, date)   to authenticated, service_role;
grant execute on function compute_class_pay(uuid)          to authenticated, service_role;
grant execute on function member_first_class(uuid)         to authenticated, service_role;
grant execute on function occurrence_guarantee(uuid)       to authenticated, service_role;
grant execute on function occurrence_is_adjacent(uuid)     to authenticated, service_role;
grant execute on function award_conversion_bonus(uuid)     to authenticated, service_role;
grant execute on function ensure_pay_period(uuid, date)    to service_role;
grant execute on function next_open_pay_period(uuid)       to service_role;

-- -----------------------------------------------------------------------------
-- And two of Decision 21's, which hosted grants anon and local does not
-- -----------------------------------------------------------------------------
-- set_series_flex() and set_occurrence_guaranteed() came out anon-callable on
-- hosted. Both refuse anon inside — is_manager_up() is false for a caller with
-- no session — so nothing was reachable through them; but an anon caller can
-- still tell an id that exists (PT403) from one that does not (PT404), and the
-- grant should never have been there. This is migrations 006, 011, 030 and 033's
-- lesson for the fifth time: revoking from PUBLIC is not revoking from anon, and
-- ONLY HOSTED CAN TELL YOU.
revoke execute on function set_series_flex(uuid, boolean, integer) from public, anon;
revoke execute on function set_occurrence_guaranteed(uuid)         from public, anon;

-- -----------------------------------------------------------------------------
-- claw_back_conversion_bonus() checked its caller AFTER an early return
-- -----------------------------------------------------------------------------
-- Found while re-running the member probe: with no bonus on file it answered
-- "no bonus to reverse" and returned before reaching is_manager_up(), so any
-- signed-in user could ask whether a named member of any studio had ever
-- converted. A boolean, which is exactly what migration 056 was written about.
-- The guard now keys on the MEMBER's studio and runs first.
create or replace function claw_back_conversion_bonus(p_member_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare r instructor_pay_records%rowtype; p pay_periods%rowtype; v_id uuid; v_studio uuid;
begin
  select studio_id into v_studio from members where id = p_member_id;
  if v_studio is null then
    raise exception 'no such member' using errcode = 'PT404';
  end if;
  if not coalesce(is_manager_up(v_studio), false) and not is_service_context() then
    raise exception 'only owners and managers reverse a bonus' using errcode = 'PT403';
  end if;

  select * into r from instructor_pay_records
   where type = 'conversion' and source_id = p_member_id
   order by created_at limit 1;
  if not found then
    return jsonb_build_object('ok', true, 'clawed_back', false, 'reason', 'no bonus to reverse');
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

revoke execute on function claw_back_conversion_bonus(uuid, text) from public, anon, authenticated;
grant execute on function claw_back_conversion_bonus(uuid, text) to authenticated, service_role;
