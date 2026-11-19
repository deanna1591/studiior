// Decision 22(e): a flex class's state at a glance, on the staff Schedule and the
// Flex pending list. The count is the one the running latch uses (paid seats; an
// unpaid drop-in does not count, Decision 81b). The block colour stays staffing.

/**
 * @returns {{kind:"count"|"running"|"not_running"|"none", text:string}}
 */
export function flexStateChip({ flex, status, cancellationCause, committed, reachedMinimum,
                                paid, unpaid, minimum }) {
  if (status === "cancelled") {
    return cancellationCause === "unmet_minimum"
      ? { kind: "not_running", text: "not running" }
      : { kind: "none", text: "" };
  }
  if (!flex) return { kind: "none", text: "" };
  if (committed || reachedMinimum) return { kind: "running", text: "Running" };
  const base = `${paid ?? 0} of ${minimum ?? 0}`;
  return { kind: "count", text: unpaid > 0 ? `${base}, ${unpaid} unpaid` : base };
}

/** The staff label for a cancellation cause that has one. */
export function cancellationCauseLabel(cause) {
  return cause === "replaced_by_private" ? "Replaced by a private session" : null;
}
