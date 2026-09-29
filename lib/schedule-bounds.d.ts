// Types for the plain-ESM lib/schedule-bounds.mjs (see lib/auth-redirect.d.ts
// for why the runtime is .mjs and the types live in a sibling .d.ts).

/** A wall-clock Date for 'YYYY-MM-DD' at `hour`; hour >= 24 is end-of-same-day. */
export function wallAt(dateKey: string, hour: number): Date;

/** The grid's [minHour, maxHour] from the in-range classes' start/end minutes. */
export function hourBounds(
  startMinutes: number[],
  endMinutes: number[],
): { minHour: number; maxHour: number };
