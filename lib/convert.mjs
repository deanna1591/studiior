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

// --- Keep (78b) --------------------------------------------------------------
/**
 * Whether a keep rule is due today, given `delta` = nowDate − refDate in whole
 * studio-local days (refDate = the membership end for renew/lapsed/win-back, the
 * credit expiry for credits). Mirrors convert_keep_sweep's keep block.
 */
export function keepRuleDue(rule, delta) {
  switch (rule) {
    case "renew_7":    return delta === -7;
    case "renew_1":    return delta === -1;
    case "renew_0":    return delta === 0;
    case "lapsed_3":   return delta === 3;
    case "credits_7":  return delta === -7;
    case "credits_2":  return delta === -2;
    case "winback_30": return delta === 30;
    case "winback_60": return delta === 60;
    default:           return false;
  }
}

export const KEEP_TEMPLATES = [
  "keep_renew_7", "keep_renew_1", "keep_renew_0", "keep_lapsed_3",
  "keep_credits_7", "keep_credits_2", "keep_winback_30", "keep_winback_60",
];

// --- Tasks (78c) -------------------------------------------------------------
/** The task kind a health band raises: at_risk → an actioned task, drifting → a
 *  hidden FYI marker, anything else → none. Mirrors convert_keep_sweep. */
export function taskKindForBand(band) {
  if (band === "at_risk") return "at_risk";
  if (band === "drifting") return "drifting_fyi";
  return null;
}

/** Whether an open at_risk/drifting task should auto-close: the band recovered
 *  to healthy/new, or the member has checked in since the task was raised. */
export function taskRecovered(band, checkedInSinceTask) {
  return band === "healthy" || band === "new" || checkedInSinceTask === true;
}
