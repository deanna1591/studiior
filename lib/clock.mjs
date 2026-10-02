// Decision 55 — the ONE clock-time formatter, as plain ESM so `node --test` can
// exercise it without a bundler (this project has no JS test runner for .ts).
// lib/time.ts re-exports fmtClock from here. It mirrors the SQL fmt_clock():
// 24h -> "13:00", 12h -> "1:00 PM" (midnight "12:00 AM", noon "12:00 PM").
// Accepts an ISO instant string, a Date, or minutes-of-day (0..1439, zoneless,
// used only for the staff calendar gutter). Dates and day names are untouched.

export function fmtClock(value, timeZone, format = "24h") {
  const hour12 = format === "12h";
  if (typeof value === "number") {
    const h = Math.floor(value / 60), m = value % 60;
    if (!hour12) return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`;
    const ap = h < 12 ? "AM" : "PM";
    const h12 = h % 12 === 0 ? 12 : h % 12;
    return `${h12}:${String(m).padStart(2, "0")} ${ap}`;
  }
  // hourCycle, not hour12: en-US with hour12:false renders midnight as "24:00",
  // which disagrees with the SQL to_char('HH24:MI') "00:00". "h23" gives 00..23;
  // "h12" gives 12:00 AM / 1:00 PM / 12:00 PM.
  return new Intl.DateTimeFormat("en-US", {
    timeZone, hour: hour12 ? "numeric" : "2-digit", minute: "2-digit",
    hourCycle: hour12 ? "h12" : "h23",
  }).format(typeof value === "string" ? new Date(value) : value);
}
