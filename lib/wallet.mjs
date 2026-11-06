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

/**
 * Decision 88(c) — the Payments tab as ONE newest-first list. Merges the four
 * member_wallet sources into flat rows, each tagged with its chip:
 *   paid     -> "Paid"              (a succeeded payment; invoice downloadable)
 *   refunded -> "Refunded"          (a refund recorded; invoice downloadable)
 *   desk     -> "Owed at the desk"  (an unpaid future drop-in)
 *   unpaid   -> "Not completed"     (an online checkout never finished)
 * invoiceable is true for Paid and Refunded only. "at" is the refund date for a
 * refunded row (so it sorts by when the money last moved), else the payment /
 * class date.
 * @param {{payments?: any[], online?: any[], desk?: any[]}} wallet
 */
export function paymentRows(wallet) {
  const { paid, refunded, desk, unpaid } = walletBuckets(wallet);
  const rows = [];
  for (const p of paid) rows.push({
    key: `paid-${p.id}`, kind: "paid", chip: "Paid", invoiceable: true,
    paymentId: p.id, item: p.item, at: p.at,
    amount_cents: p.amount_cents, currency: p.currency, refunded_cents: 0,
  });
  for (const p of refunded) rows.push({
    key: `ref-${p.id}`, kind: "refunded", chip: "Refunded", invoiceable: true,
    paymentId: p.id, item: p.item, at: p.refunded_at ?? p.at,
    amount_cents: p.amount_cents, currency: p.currency, refunded_cents: p.refunded_cents ?? 0,
  });
  for (const d of desk) rows.push({
    key: `desk-${d.booking_id}`, kind: "desk", chip: "Owed at the desk", invoiceable: false,
    paymentId: null, item: d.item, at: d.starts_at,
    amount_cents: d.due_cents, currency: d.currency, refunded_cents: 0,
  });
  for (const u of unpaid) rows.push({
    key: `unpaid-${u.id}`, kind: "unpaid", chip: "Not completed", invoiceable: false,
    paymentId: null, item: u.item, at: u.at,
    amount_cents: u.amount_cents, currency: u.currency, refunded_cents: 0,
  });
  rows.sort((a, b) => (a.at < b.at ? 1 : a.at > b.at ? -1 : 0));
  return rows;
}

/** The four filter chips at the top of the Payments tab (all shown by default). */
export const PAYMENT_FILTERS = [
  { key: "paid", label: "Paid" },
  { key: "refunded", label: "Refunded" },
  { key: "desk", label: "Owed at the desk" },
  { key: "unpaid", label: "Not completed" },
];

/** The status line on an unpaid online checkout card. */
export function onlineStatusLabel(status) {
  if (status === "pending") return "Not finished";
  if (status === "expired") return "Expired before it was paid";
  return "Didn’t go through"; // failed, cancelled
}
