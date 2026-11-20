// Decision 103(a) note, 19 Nov 2026: a member whose reservation fee is waived
// books their free class through the ordinary free path and never sees the
// reserve page or a fee line. Every member surface that decides "free or
// reserve" asks these two helpers, so no screen reads the studio fee alone.

/** The reservation fee THIS member is asked for: 0 when the fee is waived. */
export function memberFeeCents({ reservationFeeCents, feeWaived }) {
  if (feeWaived) return 0;
  const n = Number(reservationFeeCents ?? 0);
  return Number.isFinite(n) && n > 0 ? n : 0;
}

/**
 * Where a free-class tap goes: "free" (the ordinary book_first_free path, the
 * "Book free" button, no fee line) or "reserve" (the reservation checkout).
 */
export function freeClassRoute(settings) {
  return memberFeeCents(settings) > 0 ? "reserve" : "free";
}
