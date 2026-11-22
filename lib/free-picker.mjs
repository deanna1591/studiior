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

// Decision 30 (f): the picker rows use the member class card. One round button
// reads "Book for free" on every row (no asterisk), and the long reservation
// strip is gone; the header line still explains the fee.
export const FREE_PICKER_BUTTON = "Book for free";

/**
 * The tier inputs for one picker row, from free_first_class_list's own columns.
 * occ_flex is the EFFECTIVE tier (occurrence_guarantee_run), so a row that is not
 * flex is core or always and reads "Always runs" when the studio runs
 * guarantees. A flex row gets its flex state for the chip beside the time.
 * @param {{occ_flex?: boolean|null, occ_paid_count?: number|null, occ_min?: number|null,
 *          occ_reached_minimum?: boolean|null, occ_committed?: boolean|null}} c
 * @param {{guaranteesEnabled?: boolean}} [opts]
 * @returns {{alwaysRuns: boolean, flexState: null|{tier:"flex", paid:number, min:number|null, reached:boolean, committed:boolean}}}
 */
export function freePickerTier(c, { guaranteesEnabled = false } = {}) {
  if (c.occ_flex) {
    return {
      alwaysRuns: false,
      flexState: {
        tier: "flex",
        paid: c.occ_paid_count ?? 0,
        min: c.occ_min ?? null,
        reached: !!c.occ_reached_minimum,
        committed: !!c.occ_committed,
      },
    };
  }
  return { alwaysRuns: Boolean(guaranteesEnabled), flexState: null };
}
