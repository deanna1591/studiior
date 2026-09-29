/**
 * The schedule grid's day bounds — pure, and testable with `node --test`.
 *
 * These two functions decide react-big-calendar's `min`/`max`/`date`, so they
 * are kept in plain ESM (a sibling .d.ts types them for the app under
 * `moduleResolution: bundler`) rather than in a `.ts` Node 20 cannot import.
 * `lib/tz.ts` re-exports `wallAt` from here so there is ONE implementation.
 */

/**
 * A wall-clock Date for 'YYYY-MM-DD' at a given hour, for the grid's bounds.
 *
 * HOUR 24 IS THE END OF THE SAME DAY, NOT MIDNIGHT OF THE NEXT ONE. A studio
 * open until 22:50 makes `hourBounds` return maxHour = 24 (ceil(1370/60)+1), and
 * `new Date(y, m-1, d, 24, ...)` rolls JavaScript over to the FOLLOWING day at
 * 00:00 — so react-big-calendar was handed a `max` on a different calendar day
 * than its `min`/`date`, which it cannot lay out: every event collapsed to
 * top:100% height:0%, a single strip at the very bottom of the grid. Clamping to
 * 23:59:59.999 keeps `max` on the anchor day (rbc's own end-of-day convention).
 * Only `max` ever reaches 24 (minHour ≤ 22, `date` is noon, scrollToTime is
 * minHour), so nothing else changes.
 */
export function wallAt(dateKey, hour) {
  const [y, m, d] = dateKey.split("-").map(Number);
  if (hour >= 24) return new Date(y, m - 1, d, 23, 59, 59, 999);
  return new Date(y, m - 1, d, hour, 0, 0, 0);
}

/**
 * The visible hours, from the studio-local minutes of the classes in view. Given
 * the start/end minute lists (0..1439) of the occurrences in range, returns the
 * grid's minHour/maxHour, floored an hour either side and clamped to [0, 24]. An
 * empty schedule falls back to 07:00–20:00 rather than a blank grid.
 *
 * maxHour can be 24 (a class ending after ~23:00) — `wallAt` reads that as the
 * end of the SAME day, so `wallAt(anchor, maxHour)` is never on the next day.
 */
export function hourBounds(startMinutes, endMinutes) {
  const hasAny = startMinutes.length > 0 && endMinutes.length > 0;
  const earliest = hasAny ? Math.min(...startMinutes) : 7 * 60;
  const latest = hasAny ? Math.max(...endMinutes) : 20 * 60;
  const minHour = Math.max(0, Math.floor(earliest / 60) - 1);
  const maxHour = Math.min(24, Math.ceil(latest / 60) + 1);
  return { minHour, maxHour };
}
