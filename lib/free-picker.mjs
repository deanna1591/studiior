// Decision 30 amendment — the free class picker's heading and sub-line. The one
// definition the component renders, so the test tests the real copy. No em
// dashes.

/** The picker heading, the same whether or not the core-only limit is on. */
export const FREE_PICKER_HEADING = "Book your free class";

/**
 * The line under the heading. Core-only: "These classes always run. Pick one.";
 * otherwise "Pick one." The reservation sentence follows when the fee is on.
 * @param {{coreOnly?: boolean, reservationFeeLabel?: string|null}} opts
 * @returns {string}
 */
export function freePickerSubline({ coreOnly = false, reservationFeeLabel = null } = {}) {
  const base = coreOnly ? "These classes always run. Pick one." : "Pick one.";
  return reservationFeeLabel
    ? `${base} A ${reservationFeeLabel} reservation fee holds your spot and comes off your next purchase when you show up.`
    : base;
}
