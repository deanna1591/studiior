-- =============================================================================
-- MIGRATION 009 — make the plan-type field rules real, and stop duplicate names
--
-- Until now "billing_interval is meaningless on a class pack" was enforced by
-- the form and by the server action that strips it. Both live in one
-- application. An import, a job, a psql session or a second client could all
-- write a pack that bills monthly, and nothing would object.
--
-- These are the rules the form already encodes (lib/plans.ts FIELDS), moved to
-- where they hold for every writer.
-- =============================================================================

-- A recurring plan bills on a schedule and needs an interval; nothing else has
-- one, because everything else is bought once. Stated as an equivalence so it
-- catches both directions — a pack that bills, and a subscription that doesn't.
alter table membership_plans
  add constraint plan_billing_interval_matches_type
  check ((type = 'recurring') = (billing_interval is not null));

-- validity_days is pack expiry, counted from purchase. A recurring plan renews
-- instead of expiring, so the column means nothing there.
alter table membership_plans
  add constraint plan_validity_days_not_on_recurring
  check (type <> 'recurring' or validity_days is null);

-- credits_per_period is an allowance that resets at each billing boundary
-- (Decision 3). Without billing periods there is nothing for it to reset on.
alter table membership_plans
  add constraint plan_credits_per_period_recurring_only
  check (type = 'recurring' or credits_per_period is null);

-- Commitment terms and freeze caps are properties of an ongoing subscription.
-- A pack has nothing to commit to and nothing to freeze.
--
-- freeze_allowed is deliberately NOT included: it defaults to true, so every
-- pack ever inserted without naming it already carries true, and constraining
-- it would fail on existing rows. Nothing reads freeze_allowed for a
-- non-recurring plan (§7.4 freezes are a membership-period concept), so it is
-- inert rather than wrong. Worth tidying the day the default changes.
alter table membership_plans
  add constraint plan_commitment_recurring_only
  check (
    type = 'recurring'
    or (commitment_months = 0
        and cancellation_notice_days = 0
        and max_freeze_days is null)
  );

-- NOT constrained: `credits` on a recurring plan.
--
-- The data model annotates it "null on 'recurring' = unlimited", which reads as
-- though a recurring plan may carry credits. book_class() never looks at it —
-- it resolves recurring allowances through credits_per_period and
-- memberships.credits_remaining — and no plan anywhere sets it on a recurring
-- row. But the canonical doc is ambiguous, and CLAUDE.md says code that
-- contradicts it is wrong, so this waits for the doc to be settled rather than
-- being decided by a migration.

-- =============================================================================
-- One active plan per name per studio.
--
-- Three plans called "Unlimited Monthly" is a support call: staff sell the
-- wrong one, reports split across all three, and members see duplicates.
-- Case-insensitive, because "Unlimited Monthly" and "unlimited monthly" are the
-- same plan to everyone except the database.
--
-- Partial on status: archived plans keep their names. A studio that retires
-- "Unlimited Monthly" and launches a new one must be able to reuse the name,
-- and the old one must keep it so the members still on it see something
-- sensible.
-- =============================================================================

create unique index membership_plans_active_name
  on membership_plans (studio_id, lower(name))
  where status = 'active';

comment on index membership_plans_active_name is
  'One active plan per name per studio, case-insensitive. Archived plans are '
  'excluded so a retired name can be reused and the retired plan keeps it.';
