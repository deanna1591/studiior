/**
 * Studio-local time <-> UTC.
 *
 * CLAUDE.md: time is timestamptz stored UTC, and the studio timezone governs
 * display and every day boundary. A 7am class is 7am on both sides of a DST
 * transition, so a local wall-clock time is converted at the instant it refers
 * to — never by adding a fixed offset.
 */

function zoneOffsetMs(instant: Date, timeZone: string): number {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    hour12: false,
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit",
  }).formatToParts(instant);

  const p = Object.fromEntries(parts.map((x) => [x.type, x.value])) as Record<string, string>;
  const asIfUtc = Date.UTC(
    Number(p.year), Number(p.month) - 1, Number(p.day),
    Number(p.hour) % 24, Number(p.minute), Number(p.second),
  );
  return asIfUtc - instant.getTime();
}

/**
 * "2027-03-02" + "07:00" in Europe/Prague -> the UTC instant.
 * Two passes: the first guess can sit on the wrong side of a DST change, and
 * re-measuring the offset at the candidate instant settles it.
 */
export function zonedToUtc(date: string, time: string, timeZone: string): Date {
  const guess = new Date(`${date}T${time}:00Z`);
  let ms = guess.getTime() - zoneOffsetMs(guess, timeZone);
  ms = guess.getTime() - zoneOffsetMs(new Date(ms), timeZone);
  return new Date(ms);
}

export function fmtTime(iso: string, timeZone: string): string {
  return new Intl.DateTimeFormat("en-GB", {
    timeZone, hour: "2-digit", minute: "2-digit", hour12: false,
  }).format(new Date(iso));
}

export function fmtDayLabel(iso: string, timeZone: string): string {
  return new Intl.DateTimeFormat("en-GB", {
    timeZone, weekday: "short", day: "numeric", month: "short",
  }).format(new Date(iso));
}

/** ISO date (yyyy-mm-dd) of an instant, in the studio's timezone. */
export function zonedDateKey(iso: string, timeZone: string): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone, year: "numeric", month: "2-digit", day: "2-digit",
  }).format(new Date(iso));
}

/** Monday 00:00 studio-local of the week containing `ref`, as a UTC instant. */
export function weekStart(ref: Date, timeZone: string, weekOffset = 0): Date {
  const key = zonedDateKey(ref.toISOString(), timeZone);
  const [y, m, d] = key.split("-").map(Number);
  const noon = Date.UTC(y, m - 1, d, 12);
  const dow = new Date(noon).getUTCDay();          // 0 Sun .. 6 Sat
  const backToMonday = (dow + 6) % 7;
  const monday = new Date(noon - backToMonday * 86_400_000 + weekOffset * 7 * 86_400_000);
  const mk = monday.toISOString().slice(0, 10);
  return zonedToUtc(mk, "00:00", timeZone);
}

export function addDays(d: Date, n: number): Date {
  return new Date(d.getTime() + n * 86_400_000);
}
