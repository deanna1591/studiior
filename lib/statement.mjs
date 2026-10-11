// Decision 75a — pure helpers for the member/staff activity statement. No deps,
// so they run under `node --test` (test/statement.test.mjs) and in the member
// /history page + the staff member profile.

// The event kinds that are "class" activity (the Classes filter), vs the ones
// that are purely money (shown only under Credits & payments). A row can be both
// a class event AND carry a credit (a booked row with a -1 consume).
const CLASS_KINDS = new Set([
  "booked", "waitlisted", "free_first", "attended", "no_show",
  "cancelled", "late_cancelled", "studio_cancelled",
  "rescheduled", "instructor_changed", "joined",
]);

/** A row belongs to the "Credits & payments" view iff it moves credit or carries
 *  a money amount — exactly the brief's rule. */
export function isMoneyRow(r) {
  return (r.credit_delta ?? 0) !== 0 || r.amount_cents != null;
}

/** Filter the statement for one of the three tabs. `which` is 'all' | 'classes'
 *  | 'credits'. */
export function filterStatement(rows, which) {
  if (which === "credits") return rows.filter(isMoneyRow);
  if (which === "classes") return rows.filter((r) => CLASS_KINDS.has(r.kind));
  return rows.slice();
}

/** Group rows (already newest-first) into month sections, preserving order.
 *  `monthLabel(at)` turns a row's `at` into its heading (so the timezone and
 *  locale stay with the caller). */
export function groupByMonth(rows, monthLabel) {
  const out = [];
  for (const r of rows) {
    const label = monthLabel(r.at);
    const last = out[out.length - 1];
    if (last && last.label === label) last.items.push(r);
    else out.push({ label, items: [r] });
  }
  return out;
}

/** Recompute the running balance from the deltas, OLDEST first, so a caller can
 *  verify (or display) balance_after without trusting the stored column. Returns
 *  a new array in the SAME order as the input with balance_after filled; the
 *  input is assumed newest-first (as member_activity returns it). */
export function withRunningBalance(rowsNewestFirst) {
  const asc = [...rowsNewestFirst].reverse();
  let bal = 0;
  const byIdx = new Map();
  asc.forEach((r, i) => {
    bal += r.credit_delta ?? 0;
    byIdx.set(i, bal);
  });
  // Map back to newest-first order.
  const n = asc.length;
  return rowsNewestFirst.map((r, i) => ({ ...r, balance_after: byIdx.get(n - 1 - i) }));
}
