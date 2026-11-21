// Decision 117 — promotions. Pure, no imports, node-tested. The SQL twin of
// salePriceCents is promo_sale_cents(); the two must round the same way.

/** List price less the percent, rounded half up to the whole currency unit. */
export function salePriceCents(listCents, pct) {
  return Math.floor((listCents * (100 - pct) + 5000) / 10000) * 100;
}

const PERIOD_WORD = { week: "week", month: "month", quarter: "quarter", year: "year" };

/** The tag beside a struck price: "{name}, {pct}% off until {end day}". A
 *  recurring plan (Decision 117 a) is on sale for the period paid for while the
 *  promotion runs: "{name}, {pct}% off this month". */
export function promoTag(p) {
  if (!p || !p.promotion_id) return null;
  if (p.plan_type === "recurring") {
    return `${p.promotion_name}, ${p.pct}% off this ${PERIOD_WORD[p.billing_interval] ?? "month"}`;
  }
  return `${p.promotion_name}, ${p.pct}% off until ${p.ends_label}`;
}

/** The plan picker's note for a recurring plan: "monthly". */
export function intervalAdjective(interval) {
  return { week: "weekly", month: "monthly", quarter: "quarterly", year: "yearly" }[interval] ?? "recurring";
}

/** The staff sell sheet line. */
export function saleAppliedLine(p) {
  if (!p || !p.promotion_id) return null;
  return `Sale price applied: ${p.promotion_name}, ${p.pct}% off`;
}

/** A Sales row's note: "{pct}% off". */
export function pctOffLabel(pct) {
  return pct ? `${pct}% off` : null;
}

/** Overlay the price in force onto a plan row: price_cents becomes the sale
 *  price and list_cents/promo carry what the screen needs to strike and tag. */
export function withPrice(plan, prices) {
  const p = prices?.get ? prices.get(plan.id) : null;
  if (!p || !p.promotion_id) return { ...plan, list_cents: plan.price_cents, promo: null };
  return { ...plan, list_cents: p.list_cents, price_cents: p.price_cents, promo: p };
}
