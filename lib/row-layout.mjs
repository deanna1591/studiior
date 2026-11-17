/**
 * Decision 22(d): the phone layout rule for a class row (the member Book list,
 * the free-class picker, the class page header, and the Home hero / next-class
 * cards). A one-word action ("Book") sits inline on the right; anything longer,
 * or any booked/held/waiting state, drops to its own full-width line BELOW the
 * text so the class name and coach never truncate and the time stays on one
 * line — which is what keeps the row readable at phone width with Android large
 * text turned on.
 *
 * Pure so it is one decision, node-tested, and the same on every surface.
 */
export function shouldStackAction(actionLabel, state = {}) {
  if (state.booked || state.held || state.waiting) return true;
  const label = (actionLabel || "").trim();
  if (!label) return false;
  return label.split(/\s+/).length > 1;
}
