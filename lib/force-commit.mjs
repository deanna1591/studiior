// Decision 22 — which "Run anyway" control the staff class page should show.
// Pure, so `node --test` runs it and the roster page and any later caller agree.
//
// force_commit_occurrence (migration 20260830910000) lets an owner/manager make
// a class run even when it is below its minimum. It is correct ONLY for a
// scheduled, not-yet-committed, FUTURE occurrence (it adds the latch and leaves
// the bookings alone). Reviving a cancelled class is NOT offered — cancel_occurrence
// cancels the bookings and force_commit does not restore them.
//
// Returns "none" or "run_anyway":
//   - flex (and flex is on): show it whenever scheduled/uncommitted/future.
//   - core (and guarantees is on): only when the core minimum is > 1 and not yet
//     reached — a core minimum of 1 (or less) runs anyway, so there is nothing to
//     force.
//   - 'always', or a tier whose switch is off (so it behaves as always): nothing.

/**
 * @typedef {Object} FCOccurrence
 * @property {boolean} flex
 * @property {string|null} [guaranteeTier]  'core' | 'flex' | 'always' | null
 * @property {number|null} [minimumBookings]
 * @property {string|null} [committedAt]
 * @property {string} status
 * @property {number} startsMs
 * @property {number} bookedCount
 *
 * @typedef {Object} FCSettings
 * @property {boolean} guaranteesEnabled
 * @property {boolean} flexEnabled
 * @property {number} coreMin
 * @property {number} flexMin
 * @property {number} nowMs
 */

/** The occurrence's effective tier once the studio's switches are applied —
 *  mirrors occurrence_guarantee's occurrence-level resolution and its demotion
 *  of a tier whose switch is off to 'always'. */
function effectiveTier(occ, settings) {
  const base = occ.flex ? "flex" : (occ.guaranteeTier ?? "core");
  if (base === "flex" && !settings.flexEnabled) return "always";
  if (base === "core" && !settings.guaranteesEnabled) return "always";
  return base;
}

/**
 * @param {FCOccurrence} occ
 * @param {FCSettings} settings
 * @returns {"none" | "run_anyway"}
 */
export function canForceCommit(occ, settings) {
  if (occ.status !== "scheduled") return "none";
  if (occ.committedAt != null) return "none";
  if (!(occ.startsMs > settings.nowMs)) return "none"; // future only

  const tier = effectiveTier(occ, settings);
  if (tier === "flex") return "run_anyway";
  if (tier === "core") {
    return settings.coreMin > 1 && occ.bookedCount < settings.coreMin ? "run_anyway" : "none";
  }
  return "none"; // 'always' runs regardless — nothing to force
}

/** The minimum named in the help text — the flex minimum (occurrence override,
 *  else the studio default) for a flex class, the studio core minimum for a core
 *  one. Only meaningful when canForceCommit is "run_anyway". */
export function forceCommitMinimum(occ, settings) {
  const tier = effectiveTier(occ, settings);
  if (tier === "flex") return occ.minimumBookings ?? settings.flexMin;
  if (tier === "core") return settings.coreMin;
  return 0;
}
