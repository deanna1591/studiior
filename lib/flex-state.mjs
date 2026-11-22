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
  if (committed || reachedMinimum) return { kind: "running", text: "Confirmed" };
  const base = `${paid ?? 0} of ${minimum ?? 0}`;
  return { kind: "count", text: unpaid > 0 ? `${base}, ${unpaid} unpaid` : base };
}

/** The staff label for a cancellation cause that has one. */
export function cancellationCauseLabel(cause) {
  return cause === "replaced_by_private" ? "Replaced by a private session" : null;
}

// Decision 22(f): the member-facing chip on a class row, the class page, the
// free picker and the embed. The same count the latch uses (paid seats), so the
// chip never says more than the truth. tier is the EFFECTIVE tier: "core" or
// "always" (only when the studio runs guarantees, the caller decides) gives
// "Always runs"; "flex" gives the state. A private or hidden class shows nothing.
//   tone: "core" (the existing Always runs chip), "running" (green),
//         "needs" (the invitation, ink on the accent chip), "first" (quiet).
/**
 * @returns {{label:string, tone:"core"|"running"|"needs"|"first"} | null}
 */
// Wording settled 22 Nov 2026: nothing counting "Needs {min} to run"; short
// "Needs {n} more to run"; reached or committed "Confirmed" (the class page
// header passes long: true for "Confirmed to run"). {min} is always the class's
// own flex minimum, never a typed number.
export function memberFlexChip({ tier, paid, min, reached, committed, isPrivate = false, hidden = false, long = false }) {
  if (isPrivate || hidden) return null;
  if (tier === "core" || tier === "always") return { label: "Always runs", tone: "core" };
  if (tier !== "flex") return null;
  const p = Math.max(0, Number(paid) || 0);
  const m = Math.max(0, Number(min) || 0);
  if (committed || reached || p >= m) return { label: long ? "Confirmed to run" : "Confirmed", tone: "running" };
  if (p === 0) return { label: `Needs ${m} to run`, tone: "first" };
  return { label: `Needs ${m - p} more to run`, tone: "needs" };
}
