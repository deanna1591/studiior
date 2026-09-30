// Types for the plain-ESM lib/schedule-bounds.mjs (see lib/auth-redirect.d.ts
// for why the runtime is .mjs and the types live in a sibling .d.ts).

/** A wall-clock Date for 'YYYY-MM-DD' at `hour`; hour >= 24 is end-of-same-day. */
export function wallAt(dateKey: string, hour: number): Date;

/**
 * The grid's [minHour, maxHour] from the in-range classes' start/end minutes,
 * and (Decision 44) the studio's opening window when set — the window is the
 * base, widened to include any class outside it.
 */
export function hourBounds(
  startMinutes: number[],
  endMinutes: number[],
  openMinutes?: number | null,
  closeMinutes?: number | null,
): { minHour: number; maxHour: number };
