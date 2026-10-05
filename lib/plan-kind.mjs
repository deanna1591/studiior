// Decision 62 — the shared one-time-plan predicate and the intro-once sentence.
// Pure, no imports, so it runs under `node --test` (test/plan-kind.test.mjs) and
// is re-exported from lib/plans.ts for the app. /account/plan, /buy/[plan] and
// the staff plan page all key on isOneTimePlan so they can never disagree about
// which plans carry a website buy link.

/**
 * A ONE-TIME plan — bought outright, no subscription: a class pack, a drop-in,
 * or a trial (the intro offer, Decision 62). A recurring plan is a subscription.
 */
export function isOneTimePlan(type) {
  return type === "class_pack" || type === "drop_in" || type === "trial";
}

/**
 * Decision 62: an intro offer is bought once per person. The exact sentence the
 * database raises (PT409) and every buyable surface shows in place of Buy.
 */
export const INTRO_USED_SENTENCE =
  "The intro offer is for first-timers — you've had yours. Choose a pack or membership instead.";
