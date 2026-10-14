// Decision 78 — pure helpers for the convert/keep sequences, mirroring the SQL
// (convert_keep_sweep, intro_window, quiet_hours_shift) so the logic has a
// node-tested twin. No I/O, no Date-timezone surprises: callers pass plain
// numbers (epoch ms, day counts, local hours).

const DAY_MS = 86_400_000;

/** The intro window end: `days` after the free class. */
export function windowEndMs(startMs, days) {
  return startMs + days * DAY_MS;
}

/** Active iff inside [start, end) and the member has not purchased. */
export function windowActive(startMs, endMs, nowMs, hasMembership) {
  if (startMs == null) return false;
  return nowMs >= startMs && nowMs < endMs && !hasMembership;
}

/**
 * Quiet hours 21:00–08:00 studio time: a target at or after 21:00 moves to 08:00
 * the next day; before 08:00 moves to 08:00 the same day; otherwise unchanged.
 * Returns { hour, dayDelta } — the same decision quiet_hours_shift makes in SQL.
 */
export function quietShift(localHour) {
  if (localHour >= 21) return { hour: 8, dayDelta: 1 };
  if (localHour < 8) return { hour: 8, dayDelta: 0 };
  return { hour: localHour, dayDelta: 0 };
}

/** Whole studio-local days from the class day to "now" (floored, never negative). */
export function daysSince(classDate, nowDate) {
  const d = Math.floor((Date.parse(nowDate + "T00:00:00Z") - Date.parse(classDate + "T00:00:00Z")) / DAY_MS);
  return d > 0 ? d : 0;
}

/**
 * Whether a date-anchored rule is due today: before_class one day BEFORE the
 * class (delta -1), missed_you the day after (+1), day3/day7/last_day at their
 * offsets. `delta` = nowDate − classDate in whole days.
 */
export function dateRuleDue(rule, delta) {
  switch (rule) {
    case "before_class": return delta === -1;
    case "missed_you":   return delta === 1;
    case "day3":         return delta === 3;
    case "day7":         return delta === 7;
    default:             return false;
  }
}

/** after_class is due from 2h after the class ends until a day later. */
export function afterClassDue(endMs, nowMs) {
  return nowMs >= endMs + 2 * 3_600_000 && nowMs < endMs + 26 * 3_600_000;
}

/** The copyable Viber text staff paste — the same wording the sweep stores. */
export function viberText(firstName, studioName, offerName) {
  const first = (firstName && firstName.trim()) || "there";
  return `Hi ${first}! It's ${studioName} — hope you enjoyed your first class. `
    + `If you'd like to keep going, ${offerName || "a membership"} is a lovely place to start. `
    + `Any questions, just message me here.`;
}

export const CONVERT_TEMPLATES = [
  "convert_before_class", "convert_after_class", "convert_day3",
  "convert_day7", "convert_last_day", "convert_missed_you",
];
