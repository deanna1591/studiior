-- Decision 57 follow-up (item 2) — deleting a plan with ONLY cancelled/expired
-- memberships showed a raw FK error instead of the guard's sentence.
--
-- re-issues: guard_plan_delete()
-- creates: (none)
--
-- guard_plan_delete (BEFORE DELETE on membership_plans) counted only
-- memberships with status NOT IN ('cancelled','expired'), but
-- memberships_plan_id_fkey is NO ACTION and references EVERY membership row
-- regardless of status. So a plan whose memberships are all cancelled/expired
-- passed the guard (n = 0) and then hit the raw
-- `memberships_plan_id_fkey` violation (hosted: deleting "Test Payment").
--
-- Fix: count ALL memberships (matching the FK's reality — a plan with any
-- membership ever cannot be hard-deleted) and raise the user-facing sentence.
-- A BEFORE trigger fires ahead of the FK check, so the friendly PT409 always
-- wins; the FK remains the ultimate backstop. A plan with zero memberships
-- still deletes. Re-issued from its 20260830190000 body; ACL unchanged (the
-- trigger function is reachable by no client role).

create or replace function guard_plan_delete() returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare n int;
begin
  -- ALL memberships, any status — the FK blocks on every one of them.
  select count(*) into n
    from memberships
   where plan_id = old.id;

  if n > 0 then
    raise exception
      'This plan has % memberships on it, so it can''t be deleted. Archive it instead — archived plans can''t be bought and keep their history.', n
      using errcode = 'PT409',
            hint = 'Set status = ''archived'' instead. Existing members keep '
                   'the plan and the price they bought at; it stops being '
                   'sellable.';
  end if;
  return old;
end $$;
