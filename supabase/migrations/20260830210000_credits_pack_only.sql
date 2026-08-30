-- =============================================================================
-- MIGRATION 010 — credits is class-pack only (Decision 12)
--
-- Migration 009 added four of the five plan-shape constraints and deliberately
-- left this one out: the data model annotated `credits` as "null on 'recurring'
-- = unlimited", which reads as though a recurring plan may carry a bundle size.
-- Constraining against an ambiguous canonical doc is how you get a migration
-- you have to reverse, so it waited for the doc to be settled.
--
-- It is settled now (Decision 12):
--
--   credits             class_pack only — the size of a bundle bought once
--   credits_per_period  recurring only  — an allowance that resets each period,
--                                          and null there means unlimited
--
-- There is no lifetime-cap concept in V1.
--
-- Why it is worth a constraint rather than a convention: book_class() §2.2 has
-- never read membership_plans.credits. A recurring plan carrying
-- credits = 8 with credits_per_period = null would read as capped in every
-- admin screen and resolve as UNLIMITED at booking time, and the first anyone
-- hears of it is a member taking their ninth class of the month for free. Two
-- columns for one concept is precisely how a plan ends up disagreeing with what
-- the booking function reads.
--
-- No existing row violates this — in the seed, the six system templates or any
-- of the five test suites — so it applies without a backfill.
-- =============================================================================

alter table membership_plans
  add constraint plan_credits_pack_only
  check (type <> 'recurring' or credits is null);

comment on column membership_plans.credits is
  'class_pack only: the size of the bundle, e.g. 10. Null on every other type. '
  'A recurring allowance is credits_per_period, where null means unlimited '
  '(Decision 12). book_class() never reads this column — a pack credit reaches '
  'a booking through memberships.credits_remaining.';

comment on column membership_plans.credits_per_period is
  'recurring only: classes granted at each billing boundary, not rolled over '
  '(Decision 3). Null on a recurring plan means unlimited; null on any other '
  'type means nothing (Decision 12).';

-- The same rule on the templates plans are created from, so a studio cannot
-- save a template that can only ever produce a row membership_plans rejects.
alter table plan_templates
  add constraint plan_template_credits_pack_only
  check (type <> 'recurring' or credits is null);

-- -----------------------------------------------------------------------------
-- Left alone on purpose: freeze_allowed.
--
-- It is `not null default true`, so every pack and drop-in ever inserted
-- without naming it carries true — including rows in the seed and in three of
-- the test suites. Constraining it to false on non-recurring types would fail
-- on data that already exists, and would need a backfill to buy nothing:
-- §7.4 freezes pause a billing period, and a pack has no billing period, so
-- nothing reads the flag for those types. It is inert, not wrong.
--
-- The day that default changes to false, this becomes a one-line constraint
-- and a backfill of rows nobody was reading. Not before.
-- -----------------------------------------------------------------------------
