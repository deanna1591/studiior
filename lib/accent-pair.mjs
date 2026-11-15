// Decision 80 amendment (e): text on an accent-coloured surface always uses the
// studio's accent_on colour, never a hard-coded white or ink. One helper supplies
// the pair so every accent card, chip and button uses the same measured values
// (accentRamp sets --accent-solid / --accent-on-solid and --accent-chip as CSS
// vars; this routes the repeated inline literal through one place).

/** A solid accent surface: the accent fill with its measured on-accent text. */
export function accentSolid(extra) {
  return { background: "var(--accent-solid)", color: "var(--accent-on-solid)", ...(extra || {}) };
}

/** An accent-tint (chip) surface: the light accent tint with ink text (the
 *  measured-safe pairing; accent text on the tint is never a measured pair). */
export function accentChip(extra) {
  return { background: "var(--accent-chip)", color: "var(--ink)", ...(extra || {}) };
}
