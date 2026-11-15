// Decision 103(c) — the reservation-hold label. A pending_payment comp seat is
// never shown as booked: it reads "Payment pending" with the minutes left on the
// hold. Pure so a client can re-evaluate it on a clock and a node test can prove
// the boundaries.

/** Whole minutes left until the hold expires, floored, never below 0. */
export function holdMinutesLeft(holdUntilIso, nowMs = Date.now()) {
  if (!holdUntilIso) return 0;
  const end = new Date(holdUntilIso).getTime();
  if (!Number.isFinite(end)) return 0;
  return Math.max(0, Math.floor((end - nowMs) / 60000));
}

/** The row/status label for a hold. "Payment pending" plus the minutes left,
 *  or "less than a minute left" when under a minute. */
export function holdLabel(minutes) {
  const m = Math.max(0, Math.floor(minutes ?? 0));
  if (m <= 0) return "Payment pending · less than a minute left";
  return `Payment pending · ${m} min left`;
}

/** The re-tap refusal shown when a member tries to book a class they already
 *  hold (Decision 103(c)). */
export const RESERVATION_HOLD_RETAP =
  "Finish paying for this class first, or cancel the hold.";
