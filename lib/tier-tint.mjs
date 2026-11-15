// Decision 22 amendment: a core (or always-runs) class stands out on the
// timetable with a pale accent tint and an "Always runs" chip. Flex and any
// other class keep a plain background and no chip.
//
// isCore resolves the EFFECTIVE tier the same coalesce way occurrence_guarantee_run
// does: occurrence tier, occurrence flex, series tier, series flex, then core.
// It returns true for core OR always (a class that runs regardless), false for
// flex. The caller tints only when the studio runs guarantees AND isCore.

export const ALWAYS_RUNS_CHIP = "Always runs";

/**
 * @param {{ tier?: string|null, flex?: boolean|null, seriesTier?: string|null, seriesFlex?: boolean|null }} row
 * @returns {"core"|"flex"|"always"}
 */
export function effectiveTier(row) {
  if (row.tier) return row.tier;
  if (row.flex) return "flex";
  if (row.seriesTier) return row.seriesTier;
  if (row.seriesFlex) return "flex";
  return "core";
}

/** True for a class that runs regardless of bookings (core or always). */
export function isCore(row) {
  const t = effectiveTier(row);
  return t === "core" || t === "always";
}

/**
 * Whether to tint this row: the studio runs guarantees AND the class is core.
 * @param {boolean} guaranteesEnabled
 * @param {object} row
 */
export function showsAlwaysRuns(guaranteesEnabled, row) {
  return Boolean(guaranteesEnabled) && isCore(row);
}

/**
 * The tint style for a THEMED surface (member app, instructor portal): the
 * studio accent at 0.12 via the --accent-chip token. The chip takes ink on
 * that tint (safe on every accent).
 */
export function tierTintStyle() {
  return { background: "var(--accent-chip)" };
}

/** The chip style for a themed surface: ink on the accent chip. */
export function alwaysRunsChipStyle() {
  return { background: "var(--accent-chip)", color: "var(--ink)" };
}
