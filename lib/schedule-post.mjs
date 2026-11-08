// Decision 93 slice 2 — pure helpers for Schedule posts. These shape the
// grouped data schedule_post_data returns (days -> classes) into a caption, a
// month grid and the client-side core-only toggle, and pick the date range for
// each mode. No DOM, no network — node-testable, mirrored by the SQL side.

/** A date string 'YYYY-MM-DD' -> a UTC Date at noon (DST-safe arithmetic). */
function parse(iso) {
  const [y, m, d] = iso.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d, 12, 0, 0));
}
/** A UTC Date -> 'YYYY-MM-DD'. */
function iso(dt) {
  return dt.toISOString().slice(0, 10);
}
function addDays(isoDate, n) {
  const dt = parse(isoDate);
  dt.setUTCDate(dt.getUTCDate() + n);
  return iso(dt);
}
/** Monday of the week containing isoDate (Mon-based week). */
function mondayOf(isoDate) {
  const dt = parse(isoDate);
  const dow = dt.getUTCDay();            // 0=Sun..6=Sat
  const back = (dow + 6) % 7;            // days since Monday
  return addDays(isoDate, -back);
}

export const MODES = ["day", "week", "month"];
export const FORMATS = ["square", "story"];

/** The default date for a mode: tomorrow (day), next Monday (week), the 1st of
 *  next month (month). `todayIso` is the studio-local today. */
export function defaultDate(mode, todayIso) {
  if (mode === "day") return addDays(todayIso, 1);
  if (mode === "week") return addDays(mondayOf(todayIso), 7);
  // month -> first day of next month
  const dt = parse(todayIso);
  return iso(new Date(Date.UTC(dt.getUTCFullYear(), dt.getUTCMonth() + 1, 1, 12)));
}

/** The {from, to} date range a mode asks schedule_post_data for. */
export function rangeFor(mode, isoDate) {
  if (mode === "day") return { from: isoDate, to: isoDate };
  if (mode === "week") {
    const from = mondayOf(isoDate);
    return { from, to: addDays(from, 6) };
  }
  // month
  const dt = parse(isoDate);
  const first = iso(new Date(Date.UTC(dt.getUTCFullYear(), dt.getUTCMonth(), 1, 12)));
  const last = iso(new Date(Date.UTC(dt.getUTCFullYear(), dt.getUTCMonth() + 1, 0, 12)));
  return { from: first, to: last };
}

/** Core-only defaults ON while the studio's flex minimum is above 1. */
export function coreOnlyDefault(flexMin) {
  return Number(flexMin) > 1;
}

/** Keep only core classes when coreOnly; drop any day left with none. The data
 *  the RPC returns carries every class with its tier, so the toggle is instant. */
export function filterDays(days, coreOnly) {
  const list = Array.isArray(days) ? days : [];
  if (!coreOnly) return list;
  return list
    .map((d) => ({ ...d, classes: (d.classes ?? []).filter((c) => c.tier === "core") }))
    .filter((d) => d.classes.length > 0)
    .map((d) => ({ ...d, count: d.classes.length }));
}

/** A class line: "7:00 AM Reformer Flow — Ada" (coach optional). */
export function classLine(c) {
  const base = `${c.time} ${c.name}`;
  return c.coach ? `${base} — ${c.coach}` : base;
}

/** The plain-text caption: each day's classes under its label, blank line
 *  between days, then the hashtag line. Empty when there is nothing to post. */
export function captionText({ days, hashtags } = {}) {
  const list = Array.isArray(days) ? days : [];
  const blocks = list
    .filter((d) => (d.classes ?? []).length > 0)
    .map((d) => [d.label, ...d.classes.map(classLine)].join("\n"));
  const body = blocks.join("\n\n");
  const tags = (hashtags ?? "").trim();
  if (!body) return tags;
  return tags ? `${body}\n\n${tags}` : body;
}

/** The month grid: one cell per day that has classes, with the count and the
 *  first three class names (a full month does not fit on a post). */
export function monthCells(days, limit = 3) {
  const list = Array.isArray(days) ? days : [];
  return list
    .filter((d) => (d.classes ?? []).length > 0)
    .map((d) => ({
      date: d.date,
      label: d.label,
      count: d.classes.length,
      first: d.classes.slice(0, limit).map((c) => c.name),
      more: Math.max(0, d.classes.length - limit),
    }));
}

/** Total classes across a day list (for the empty-state check and the header). */
export function totalClasses(days) {
  return (Array.isArray(days) ? days : []).reduce((n, d) => n + (d.classes ?? []).length, 0);
}
