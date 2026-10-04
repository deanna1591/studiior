-- Decision 61 follow-up — a member must be able to read the plan of their OWN
-- membership, even when the plan is staff-only.
--
-- creates: (no functions — one RLS policy only)
-- re-issues: (none)
--
-- The decision says a complimentary membership is "usually a staff-only
-- 'Complimentary' plan the studio creates once", and that the member "sees it
-- in the app as their plan, named as the plan is named". But plans_member_read
-- only exposes visibility='public' plans, so the member app's membership->plan
-- join returned null for a staff-only comp plan — an empty plan name and
-- "0 classes left" (the recurring/unlimited branch could not see the type).
--
-- This adds a second, additive SELECT policy: a member may read a plan they
-- hold (or held) a membership on, whatever its visibility. It reveals nothing
-- they are not already on, and leaves the public-plan catalogue policy
-- untouched. Null-safe: auth.uid() appears only inside exists().

drop policy if exists plans_member_own_membership on membership_plans;
create policy plans_member_own_membership on membership_plans
  for select
  using (
    exists (
      select 1 from memberships ms
       where ms.plan_id = membership_plans.id
         and exists (
           select 1 from members m
            where m.id = ms.member_id and m.user_id = auth.uid()
         )
    )
  );
