// Decision 88 slice B — the pure wallet logic, shared by /payments and
// /purchases and node-tested. Which payment lands in which tab, and the
// "{used} of {total} classes used" line, live here so they are tested once and
// cannot drift between the screen and the test.

/**
 * The four /payments tabs from the one member_wallet() read. Paid vs Refunded
 * is decided per payment (a refund recorded against it → Refunded); Unpaid is
 * the online-checkout list and Desk the unpaid-drop-in list, already separated
 * by source in the reader.
 * @param {{payments?: any[], online?: any[], desk?: any[]}} wallet
 */
export function walletBuckets(wallet) {
  const payments = wallet?.payments ?? [];
  const paid = [];
  const refunded = [];
  for (const p of payments) {
    if ((p.refunded_cents ?? 0) > 0) refunded.push(p);
    else if (p.status === "succeeded") paid.push(p);
  }
  return { unpaid: wallet?.online ?? [], paid, refunded, desk: wallet?.desk ?? [] };
}

/**
 * A pass card's "{used} of {total} classes used". Null when the plan carries no
 * finite total (an unlimited recurring plan), so the caller shows nothing
 * rather than "0 of null". used never goes below 0 (a topped-up pack can read
 * credits above its original total).
 * @param {{plan_credits?: number|null, credits_remaining?: number|null}} m
 */
export function usedOfTotal(m) {
  const total = m?.plan_credits;
  if (total == null) return null;
  const used = Math.max(0, total - (m?.credits_remaining ?? 0));
  return `${used} of ${total} classes used`;
}

/** Subscriptions tab holds recurring plans; Passes holds packs/drop-ins/trials. */
export function membershipTab(planType) {
  return planType === "recurring" ? "subscriptions" : "passes";
}

/** "Active" for a live membership, "Expired" once it has ended. */
export function membershipChip(status) {
  return status === "cancelled" || status === "expired" ? "Expired" : "Active";
}

/**
 * The payment method named on a receipt: Card, GCash or Desk. A manual (desk)
 * payment is "Desk"; Stripe is a card; Xendit presents card and GCash on its
 * hosted page, so a stored gcash method shows GCash and anything else Card.
 */
export function receiptMethod(provider, method) {
  if (provider === "manual") return "Desk";
  if (provider === "stripe") return "Card";
  if (provider === "xendit") return method === "gcash" ? "GCash" : "Card";
  return method === "gcash" ? "GCash" : method === "cash" || method === "card_terminal" || method === "bank_transfer" ? "Desk" : "Card";
}

/** The status line on an unpaid online checkout card. */
export function onlineStatusLabel(status) {
  if (status === "pending") return "Not finished";
  if (status === "expired") return "Expired before it was paid";
  return "Didn’t go through"; // failed, cancelled
}
