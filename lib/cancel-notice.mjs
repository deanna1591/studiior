// Decision 36 amendment — the cancellation rule shown BEFORE the tap, and the
// result shown after. ONE source of the sentences, read by the class page, the
// confirm sheet, and cancelBooking in app/member/actions.ts, so the before-tap
// line, the confirm sheet and the result cannot drift. Pure; no I/O, no clock.
//
// Numbers come from settings (cancellation_cutoff_minutes), never typed; times
// are formatted by the caller in the studio clock; no em dashes anywhere.

const MIN = 60_000;

/**
 * Which bucket a booked seat falls in, for the cancel wording:
 *  - 'free'      the member's free first class (comp + free-first).
 *  - 'credit'    a pack / intro credit seat (a credit was drawn).
 *  - 'unlimited' an unlimited membership seat, or a complimentary comp seat —
 *                nothing to spend; a late cancel is only recorded.
 *  - 'drop_in'   a drop-in (paid or unpaid) — no credit, no free class.
 */
export function seatKindOf({ paymentSource, creditEntryId, isFreeBooking } = {}) {
  if (isFreeBooking) return "free";
  if (paymentSource === "drop_in") return "drop_in";
  if (creditEntryId != null) return "credit";
  if (paymentSource === "class_pack") return "credit"; // belt: a pack seat is a credit
  return "unlimited";
}

/**
 * The line shown UNDER the Cancel button, repeated verbatim in the confirm sheet
 * for the after-cutoff case. `fmtTime(ms)` and `fmtDay(ms)` format the cutoff in
 * the studio clock. Returns { phase, line } — phase 'before' | 'after' | 'started'.
 * On 'started' the caller drops the button and shows the line.
 */
export function cancelNotice({ startsMs, cutoffMinutes, nowMs, seatKind, fmtTime, fmtDay } = {}) {
  if (nowMs >= startsMs) return { phase: "started", line: "This class has started." };

  const cutoffAt = startsMs - cutoffMinutes * MIN;
  if (nowMs < cutoffAt) {
    const when = `Free to cancel until ${fmtTime(cutoffAt)} on ${fmtDay(cutoffAt)}.`;
    const tail = seatKind === "free" ? " After that your free class is used."
      : seatKind === "credit" ? " After that your credit is used."
      : seatKind === "unlimited" ? " After that it counts as a late cancel."
      : ""; // drop_in: no consequence to warn about
    return { phase: "before", line: when + tail };
  }

  const n = Math.max(1, Math.round(cutoffMinutes / 60));
  const head = `It's less than ${n} ${n === 1 ? "hour" : "hours"} before class.`;
  const tail = seatKind === "free" ? " Cancelling now uses your free class."
    : seatKind === "credit" ? " Cancelling now uses your credit."
    : seatKind === "unlimited" ? " Cancelling now counts as a late cancel."
    : ""; // drop_in
  return { phase: "after", line: head + tail };
}

/**
 * The sentence shown AFTER cancelling, from the RPC result + the seat kind.
 * `late` is status === 'late_cancelled'; `creditReturned` is the cancel result's
 * credit_returned (true both for an on-time credit and a late one at a studio
 * that does not consume the credit).
 */
export function cancelResult({ seatKind, late, creditReturned } = {}) {
  if (seatKind === "free") {
    return late ? "Cancelled. Your free class was used." : "Cancelled. Your free class is still yours.";
  }
  if (seatKind === "credit") {
    return creditReturned ? "Cancelled. Your credit is back on your account." : "Cancelled. Your credit was used.";
  }
  return "Cancelled.";
}
