// Decision 24 (a) and 103 (p): the copy for a sold-out plan and for a studio
// with no online payment, in one place so every screen says the same thing.

export const SOLD_OUT_CHIP = "Sold out";
export const SOLD_OUT_SENTENCE = "This plan is sold out.";

/** True when the plan has a cap and it is reached. */
export function isSoldOut(state) {
  return !!state && state.sold_out === true;
}

/** "{sold} of {max} sold" for staff, null when the plan has no cap. */
export function soldLine(state) {
  if (!state || state.max_sold == null) return null;
  return `${state.sold ?? 0} of ${state.max_sold} sold`;
}

/** The /buy fallback when online payment is off (103 p). */
export function offlineBuyLine(staffOnly) {
  return staffOnly
    ? "Online payment isn’t set up yet. Message the studio to buy."
    : "Online payment isn’t set up yet. Pay at the studio.";
}
