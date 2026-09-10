/**
 * Studio time, in a browser that is somewhere else.
 *
 * THE RULE: every time displayed anywhere is the STUDIO's timezone. Never the
 * browser's, never the server's. A studio in Manila shows Manila times whether
 * the owner is in Manila, Prague or anywhere else — and whether the developer
 * is too.
 *
 * react-big-calendar has no timezone of its own: it lays out `Date` objects
 * using their BROWSER-LOCAL fields. So the calendar is handed Dates whose
 * browser-local fields have been set to the studio's wall clock, and converts
 * back the moment anything is saved. Everything between those two calls is
 * display, and nothing in it is a real instant — which is why they are named
 * `wall` rather than `date`.
 *
 * The alternative was carrying an offset through every render and every
 * comparison; this keeps the lie in two functions with the truth on both sides.
 */

const partsFmt = new Map<string, Intl.DateTimeFormat>();
function fmt(tz: string) {
  let f = partsFmt.get(tz);
  if (!f) {
    f = new Intl.DateTimeFormat("en-GB", {
      timeZone: tz, hour12: false,
      year: "numeric", month: "2-digit", day: "2-digit",
      hour: "2-digit", minute: "2-digit", second: "2-digit",
    });
    partsFmt.set(tz, f);
  }
  return f;
}

export type Parts = { y: number; m: number; d: number; h: number; mi: number; s: number };

/** The studio's wall-clock fields for a real instant. */
export function zonedParts(instant: Date, tz: string): Parts {
  const p = fmt(tz).formatToParts(instant);
  const get = (t: string) => Number(p.find((x) => x.type === t)!.value);
  // hour12:false still yields "24" at midnight in some engines. Normalise, or
  // a 00:05 class lands on the previous day at hour 24.
  const h = get("hour") % 24;
  return { y: get("year"), m: get("month"), d: get("day"), h, mi: get("minute"), s: get("second") };
}

/** 'YYYY-MM-DD' in the studio's zone — the key a calendar day is grouped by. */
export function studioDateKey(instant: Date, tz: string): string {
  const p = zonedParts(instant, tz);
  return `${p.y}-${String(p.m).padStart(2, "0")}-${String(p.d).padStart(2, "0")}`;
}

/**
 * A real instant → a Date whose BROWSER-LOCAL fields read as studio wall time.
 * For display only. Never send one of these anywhere.
 */
export function toStudioWall(instant: Date, tz: string): Date {
  const p = zonedParts(instant, tz);
  return new Date(p.y, p.m - 1, p.d, p.h, p.mi, p.s, 0);
}

/** How far the zone is from UTC at a given instant, in milliseconds. */
function offsetMs(instant: Date, tz: string): number {
  const p = zonedParts(instant, tz);
  const asUtc = Date.UTC(p.y, p.m - 1, p.d, p.h, p.mi, p.s);
  return asUtc - instant.getTime();
}

/**
 * The inverse: a display Date back to the real instant it means.
 *
 * Two passes, because the offset depends on the instant and the instant is what
 * is being solved for. The first guess is wrong by exactly the DST step on the
 * two days a year it matters, and the second pass lands on it.
 */
export function fromStudioWall(wall: Date, tz: string): Date {
  const target = Date.UTC(
    wall.getFullYear(), wall.getMonth(), wall.getDate(),
    wall.getHours(), wall.getMinutes(), wall.getSeconds());
  let guess = new Date(target - offsetMs(new Date(target), tz));
  guess = new Date(target - offsetMs(guess, tz));
  return guess;
}

/** A wall-clock Date for 'YYYY-MM-DD' at a given hour, for the grid's bounds. */
export function wallAt(dateKey: string, hour: number): Date {
  const [y, m, d] = dateKey.split("-").map(Number);
  return new Date(y, m - 1, d, hour, 0, 0, 0);
}

/** Move a 'YYYY-MM-DD' by whole days without going near a Date's timezone. */
export function shiftDateKey(dateKey: string, days: number): string {
  const [y, m, d] = dateKey.split("-").map(Number);
  const t = new Date(Date.UTC(y, m - 1, d));
  t.setUTCDate(t.getUTCDate() + days);
  return t.toISOString().slice(0, 10);
}

/**
 * Today, in the studio's zone — without asking the database.
 *
 * `studio_today()` exists and returns exactly this; the page used to spend a
 * whole serial round trip on it before it could even name the day it was about
 * to fetch. Intl carries the same IANA rules Postgres does, so the two cannot
 * disagree — checked against hosted, both say 2026-09-10 for Asia/Manila while
 * the server's own date is the 9th. The SQL function stays for callers that are
 * already in the database; nothing that has a timezone in hand should pay a hop
 * for it.
 */
export function studioToday(tz: string, now: Date = new Date()): string {
  const p = zonedParts(now, tz);
  return `${p.y}-${String(p.m).padStart(2, "0")}-${String(p.d).padStart(2, "0")}`;
}
