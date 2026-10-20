// Members list polish (20 Oct 2026) — pure helpers, node-tested, no I/O. The
// free-stage rule mirrors member_plan_overview's SQL so the test can prove the
// logic; the actual value is read from the row. The default-sort decision picks
// newest-signup for a studio where nobody has visited yet, else By attention.

const LIVE = new Set(["booked", "attended", "no_show"]); // a cancelled comp doesn't count

/**
 * The free stage from a member's bookings — 'taken' > 'booked' > 'missed' > null.
 * bookings: [{ paymentSource, status, startsAt }] (startsAt an ISO string or ms).
 *   'taken'  — an attended comp booking
 *   'booked' — a comp booking still booked (future or not yet finalised)
 *   'missed' — only no_show comp bookings, and no later booking of ANY kind
 *   null     — otherwise (no comp booking, or cancelled-only)
 */
export function freeStage(bookings = []) {
  const bs = bookings || [];
  const comps = bs.filter((b) => b && b.paymentSource === "comp" && LIVE.has(b.status));
  if (comps.length === 0) return null;
  if (comps.some((b) => b.status === "attended")) return "taken";
  if (comps.some((b) => b.status === "booked")) return "booked";
  // Only no_show comp bookings left. Missed unless there is a later booking of
  // any kind (a cancelled/late-cancelled one does not count).
  const noShows = comps.filter((b) => b.status === "no_show");
  if (noShows.length === 0) return null;
  const lastNoShow = Math.max(...noShows.map((b) => ms(b.startsAt)));
  const hasLater = bs.some(
    (b) => b && !["cancelled", "late_cancelled"].includes(b.status) && ms(b.startsAt) > lastNoShow,
  );
  return hasLater ? null : "missed";
}

function ms(v) {
  return typeof v === "number" ? v : Date.parse(v);
}

/**
 * Which sort to default to when no sort is chosen: 'newest' (by sign-up) when no
 * member in the studio has a visit yet, else 'attention' (as today).
 */
export function defaultSortMode(members = []) {
  return (members || []).some((m) => (m?.lifetime_visits ?? 0) > 0) ? "attention" : "newest";
}
