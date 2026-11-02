// Decision 88 slice A — the pure pieces of the checkout picker, in a .mjs so
// `node --test` (test/checkout.test.mjs) can reach them with no bundler. The
// screen's money path is the existing Xendit flow (beginXenditCheckout +
// apply_plan_to_unpaid); only the ORDER of the plan radio and the one-line help
// text are decided here, so they are what the node test pins.

const RANK = { drop_in: 0, trial: 1, class_pack: 2, recurring: 3 };

/**
 * The plans the checkout radio offers, in Decision 88's order: the drop-in
 * first (and so preselected — it is element 0), then the intro offer when the
 * member is eligible, then packs, then memberships. Group plans are not a
 * single-seat purchase and are excluded; an exclusive intro plan the member is
 * outside the window for is excluded exactly as /account/plan hides it (the DB
 * refuses it too, so this is presentation). Within a rank the caller's own
 * order is kept (the query already sorts by sort_order).
 */
export function checkoutPlanOrder(plans, opts = {}) {
  const { trialUsed = false, introPlanId = null, hideExclusiveIntro = false } = opts;
  const kept = (plans ?? []).filter((p) => {
    if (!(p.type in RANK)) return false;            // group / unknown: never here
    if (p.type === "trial" && trialUsed) return false;
    if (hideExclusiveIntro && introPlanId && p.id === introPlanId) return false;
    return true;
  });
  // Stable sort by rank only — equal ranks keep their incoming order.
  return kept
    .map((p, i) => [p, i])
    .sort((a, b) => (RANK[a[0].type] - RANK[b[0].type]) || (a[1] - b[1]))
    .map(([p]) => p);
}

/**
 * The one line of help under a plan name — classes and validity as already
 * stored on the plan, never computed money. Mirrors /account/plan's `includes`.
 */
export function planHelpLine(plan) {
  if (!plan) return "";
  const parts =
    plan.type === "class_pack"
      ? [plan.credits != null ? `${plan.credits} classes` : null,
         plan.validity_days ? `use within ${plan.validity_days} days` : null]
      : plan.type === "drop_in"
      ? ["Single class"]
      : plan.type === "trial"
      ? [`${plan.credits ?? 1} class${(plan.credits ?? 1) === 1 ? "" : "es"}`,
         plan.validity_days ? `use within ${plan.validity_days} days` : null]
      : // recurring, sold one period at a time (Decision 66)
        [plan.credits_per_period == null ? "Unlimited classes" : `${plan.credits_per_period} classes each period`,
         `one ${plan.billing_interval ?? "period"} — renew by hand`];
  return parts.filter(Boolean).join(" · ");
}

/**
 * The summary total. Discounts are out of scope (Decision 88), so the total is
 * the chosen plan's price — stated as its own function so the one place a total
 * is formed is named and testable rather than an inline sum in the component.
 */
export function checkoutTotalCents(plan) {
  return plan ? plan.price_cents : 0;
}
