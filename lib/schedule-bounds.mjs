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
 * grid's minHour/maxHour, clamped to [0, 24].
 *
 * DECISION 44 — when the studio has set opening hours (openMinutes/closeMinutes,
 * 0..1439), the window is the base: minHour = floor(open) and maxHour =
 * ceil(close)+1, then WIDENED (never narrowed) to include any class that falls
 * outside it — a 05:30 class pulls minHour down to 5, and a 22:00–22:50 class at
 * a 22:00 close pushes maxHour to 24. With no hours set, behaviour is exactly as
 * before: floored an hour either side of the classes, falling back to 07:00–20:00
 * on an empty schedule rather than a blank grid.
 *
 * maxHour can be 24 (a class ending after ~23:00, or a late close) — `wallAt`
 * reads that as the end of the SAME day, so `wallAt(anchor, maxHour)` is never on
 * the next day (the strip-at-the-bottom regression).
 */
export function hourBounds(startMinutes, endMinutes, openMinutes = null, closeMinutes = null) {
  const hasAny = startMinutes.length > 0 && endMinutes.length > 0;
  const hasHours = openMinutes != null && closeMinutes != null;
  let minHour, maxHour;
  if (hasHours) {
    minHour = Math.floor(openMinutes / 60);
    maxHour = Math.ceil(closeMinutes / 60) + 1;
    if (hasAny) {
      minHour = Math.min(minHour, Math.floor(Math.min(...startMinutes) / 60));
      maxHour = Math.max(maxHour, Math.ceil(Math.max(...endMinutes) / 60) + 1);
    }
  } else {
    const earliest = hasAny ? Math.min(...startMinutes) : 7 * 60;
    const latest = hasAny ? Math.max(...endMinutes) : 20 * 60;
    minHour = Math.floor(earliest / 60) - 1;
    maxHour = Math.ceil(latest / 60) + 1;
  }
  return { minHour: Math.max(0, minHour), maxHour: Math.min(24, maxHour) };
}
