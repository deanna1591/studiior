-- =============================================================================
-- 139  Payroll is opt-in: a studio that uses neither guarantees nor flex
--      generates no instructor pay, even if a rate version is on file.
-- =============================================================================
-- THE LEAK, found by proving optionality. Instructor pay IS the guarantee
-- system (Decision 22): a class that RAN only generates a record via
-- committed_at, which is only ever set when guarantees or flex are on. But the
-- CANCELLED path was gated differently — tg_record_class_pay called
-- record_class_pay for ANY cancelled class, and record_class_pay writes a record
-- whenever a rate version exists (its only skip is "no rate on file"). So a
-- studio that never turned guarantees on but had a rate version (set by hand,
-- or carried in by an import) started accruing instructor pay on a studio_fault
-- or closure cancellation — a cost it never opted into. Reform Collective's
-- ladder is ONE studio's contract, not a product rule; another studio pays
-- differently or handles payroll entirely in its own books and must see no
-- trace.
--
-- The fix gates the CANCELLED path to match the committed one: a cancellation
-- generates a pay record only when the studio uses guarantees or flex. Both off
-- => nothing, absent not zero. A guarantees-ON studio is unchanged: its
-- not_running sweep, its studio_fault and its closures still pay.
-- =============================================================================

create or replace function tg_record_class_pay()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_uses boolean;
begin
  -- The committed path needs no gate: committed_at is only set when guarantees
  -- or flex are on. The cancelled path is gated here on the same opt-in.
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

-- studio_uses_payroll(): the one predicate the app asks to decide whether to
-- show any payroll surface at all — the staff rail's Pay, the instructor
-- portal's Pay tab. True when the studio has opted into the guarantee system.
-- SECURITY DEFINER over studio_settings, guarded to that studio's staff /
-- instructors so it leaks nothing across tenants.
create or replace function studio_uses_payroll(p_studio_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v boolean;
begin
  if not (coalesce(is_desk_up(p_studio_id), false)
          or exists (select 1 from instructors i join studio_staff ss on ss.id = i.staff_id
                      where i.studio_id = p_studio_id and ss.user_id = auth.uid())
          or is_service_context()) then
    raise exception 'not your studio' using errcode = 'PT403';
  end if;
  select coalesce(guarantees_enabled, false) or coalesce(flex_enabled, false)
    into v from studio_settings where studio_id = p_studio_id;
  return coalesce(v, false);
end $$;

revoke execute on function studio_uses_payroll(uuid) from public, anon;
grant  execute on function studio_uses_payroll(uuid) to authenticated, service_role;
