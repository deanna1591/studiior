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

/** A class line: "7:00 AM Reformer Flow with Ada" (coach optional). The time is
 *  the studio-clock string the RPC returns (fmt_clock); never an em dash. */
export function classLine(c) {
  const base = `${c.time} ${c.name}`;
  return c.coach ? `${base} with ${c.coach}` : base;
}

/** The plain-text caption: each day's classes under its label, blank line
 *  between days, then the hashtag line. In coach mode it STARTS with the coach's
 *  name. Empty when there is nothing to post. */
export function captionText({ days, hashtags, coachFirst } = {}) {
  const list = Array.isArray(days) ? days : [];
  const blocks = list
    .filter((d) => (d.classes ?? []).length > 0)
    .map((d) => [d.label, ...d.classes.map(classLine)].join("\n"));
  let body = blocks.join("\n\n");
  const coach = (coachFirst ?? "").trim();
  if (body && coach) body = `${coach}'s classes\n\n${body}`;
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

// --- Auto-fit (slice 3) -----------------------------------------------------
// A square post (1080×1080) has a fixed body area after the header and footer.
// When the classes do not fit, the renderer shrinks the body in STEPS (font +
// gaps multiplied by `scale`) down to a floor; past the floor we SPLIT into
// "part 1 of 2" posts rather than clipping. These constants are a conservative
// row-height model (px at scale 1) shared by the helper and the renderer so the
// chosen scale and the drawn post agree; overflow:hidden + the split are the
// backstops if the estimate is slightly off. A story post (1920 tall) and the
// month grid never need it, so they always come back as a single page at 1.
export const FIT = {
  budget: 600,      // px of square body area (after header ~254 + footer ~54)
  floor: 0.72,      // smallest scale before splitting
  steps: [1, 0.9, 0.82, 0.76, 0.72],
  dayRow: 170,      // a Day-mode class card at scale 1 (incl. its gap)
  weekHeader: 42,   // a Week-mode day label (incl. margin)
  weekClass: 44,    // a Week-mode class line at scale 1
  weekGap: 24,      // between Week-mode day blocks
};

/** Estimated body height (px, scale 1) for a day list in a mode. */
export function bodyHeight(days, mode) {
  const list = Array.isArray(days) ? days : [];
  if (mode === "day") return (list[0]?.classes?.length ?? 0) * FIT.dayRow;
  // week: each day = header + its classes, with a gap between day blocks
  let h = 0;
  list.forEach((d, i) => {
    h += FIT.weekHeader + (d.classes?.length ?? 0) * FIT.weekClass;
    if (i > 0) h += FIT.weekGap;
  });
  return h;
}

/** The largest step scale at which `h1` fits the budget, else the floor with
 *  fits:false (the caller then splits). */
export function fitScale(h1) {
  for (const s of FIT.steps) if (h1 * s <= FIT.budget) return { scale: s, fits: true };
  return { scale: FIT.floor, fits: false };
}

/** Split a day list for a square when even the floor cannot hold it. Week packs
 *  WHOLE days (a day is never split across posts); Day chunks one day's classes.
 *  Returns an array of day-arrays, one per page. */
export function splitForSquare(days, mode) {
  const list = Array.isArray(days) ? days : [];
  const cap = FIT.budget / FIT.floor;   // max bodyHeight allowed at the floor
  if (mode === "day") {
    const day = list[0];
    if (!day) return [[]];
    const per = Math.max(1, Math.floor(cap / FIT.dayRow));
    const out = [];
    for (let i = 0; i < day.classes.length; i += per) {
      const slice = day.classes.slice(i, i + per);
      out.push([{ ...day, classes: slice, count: slice.length }]);
    }
    return out.length ? out : [[day]];
  }
  const pages = [];
  let cur = [];
  for (const d of list) {
    if (cur.length && bodyHeight([...cur, d], "week") > cap) { pages.push(cur); cur = [d]; }
    else cur = [...cur, d];
  }
  if (cur.length) pages.push(cur);
  return pages.length ? pages : [list];
}

/** The render plan: one or more pages, each with the days it shows, its scale,
 *  and its part number. A story post, the month grid and anything that fits come
 *  back as a single page; a dense square day/week auto-fits, then splits. */
export function fitPlan({ days, mode, format } = {}) {
  const list = Array.isArray(days) ? days : [];
  const single = (d, scale) => ({ pages: [{ days: d, part: 1, parts: 1, scale }] });
  if (format === "story" || mode === "month" || list.length === 0) return single(list, 1);
  const fit = fitScale(bodyHeight(list, mode));
  if (fit.fits) return single(list, fit.scale);
  const chunks = splitForSquare(list, mode);
  const parts = chunks.length;
  return { pages: chunks.map((d, i) => ({ days: d, part: i + 1, parts, scale: fitScale(bodyHeight(d, mode)).scale })) };
}

// --- Undo stack (slice 3) ---------------------------------------------------
// The edit history is a stack of specs with the base at index 0; each Claude
// edit pushes, Undo pops to the previous. Pure so the reducer is node-tested.

/** Push a spec onto the history. */
export function pushSpec(stack, spec) {
  return [...(Array.isArray(stack) ? stack : []), spec];
}

/** Step back one edit; returns the trimmed stack and its current (top) spec. */
export function undoStack(stack) {
  const s = Array.isArray(stack) ? stack : [];
  if (s.length <= 1) return { stack: s, current: s[0] ?? null };
  const next = s.slice(0, -1);
  return { stack: next, current: next[next.length - 1] };
}

/** True while there is an edit above the base to undo. */
export function canUndo(stack) {
  return Array.isArray(stack) && stack.length > 1;
}

// --- Editorial styles (amendment) -------------------------------------------
// Four styles the studio chooses between per post, each treating the timetable
// as an object (docs/post-design). The pure layer here is the headline parts,
// the short studio name, the receipt number, and a style-aware auto-fit that
// tightens rows then splits a dense DAY (week is a bounded 7-row/7-col summary
// and never splits; the month grid and a story post never split). Lock screen
// is day only. The renderer draws each layout from the brand spec.

export const POST_STYLES = ["guest_check", "times", "invitation", "lock_screen"];
export const STYLE_LABELS = {
  guest_check: "Guest Check", times: "The Times", invitation: "Invitation", lock_screen: "Lock screen",
};

/** The headline, split so the renderer can set the accent-italic word apart.
 *  All classes: "this week's / Monday's / November's" + accent "schedule".
 *  Coach mode: "{First}'s week" / "{First} on Monday" / "{First}'s November". */
export function headlineParts({ mode, weekday, monthName, coachFirst } = {}) {
  const c = (coachFirst ?? "").trim();
  if (c) {
    if (mode === "day") return { lead: `${c} on `, accent: weekday || "today" };
    if (mode === "month") return { lead: `${c}'s `, accent: monthName || "month" };
    return { lead: `${c}'s `, accent: "week" };
  }
  if (mode === "day") return { lead: `${weekday || "today"}'s `, accent: "schedule" };
  if (mode === "month") return { lead: `${monthName || "this month"}'s `, accent: "schedule" };
  return { lead: "this week's ", accent: "schedule" };
}

/** The studio's short name for The Times masthead/headline — the first word. */
export function shortName(name) {
  const s = String(name ?? "").trim();
  return s.split(/\s+/)[0] || s;
}

/** A receipt number from a date: "N° 1109" (month+day), the Guest Check conceit. */
export function receiptNo(isoDate) {
  const [, mm, dd] = String(isoDate ?? "").split("-");
  return `N° ${mm ?? "01"}${dd ?? "01"}`;
}

// Per-style row models (px at scale 1, for a ~1080 square body). A DAY list
// tightens in STEPS down to the style floor, then SPLITS past it (whole classes
// kept, none lost). A WEEK is a bounded summary (guest_check/invitation: one row
// per day; times: a 7-col grid scaled to its tallest column) and never splits.
export const STYLE_FIT = {
  guest_check: { dayBudget: 450, dayRow: 54, weekBudget: 470, weekHeadingRow: 40, weekClassRow: 42, floor: 0.70, steps: [1, 0.9, 0.82, 0.76, 0.72, 0.70], weekKind: "classes" },
  times:       { dayBudget: 560, dayRow: 62, gridRow: 46, weekBudget: 560, floor: 0.68, steps: [1, 0.9, 0.82, 0.76, 0.72, 0.68], weekKind: "grid" },
  invitation:  { dayBudget: 540, dayRow: 54, weekBudget: 520, weekHeadingRow: 44, weekClassRow: 42, floor: 0.70, steps: [1, 0.9, 0.82, 0.76, 0.72, 0.70], weekKind: "classes" },
  lock_screen: { dayBudget: 760, dayRow: 98, floor: 0.70, steps: [1, 0.9, 0.84, 0.78, 0.74, 0.70], weekKind: "none" },
};

/** The flattened per-class week rows a style renders in Week mode: one group per
 *  day (its label) with its classes carrying a tier icon, time, name and coach.
 *  In Coach mode the "with {coach}" is dropped (the whole post is one coach). */
export function weekRows(days, { coachMode = false } = {}) {
  return (Array.isArray(days) ? days : []).map((d) => ({
    label: d.label,
    classes: (d.classes || []).map((c) => ({
      icon: c.tier === "core" ? "✦" : "○",
      time: c.time,
      name: c.name,
      coach: coachMode ? "" : (c.coach ? `with ${c.coach}` : ""),
    })),
  }));
}

/** True iff any class on these days is not core (a flex class is on the page) —
 *  the "✦ = always runs" legend shows only then. */
export function anyFlex(days) {
  return (Array.isArray(days) ? days : []).some((d) => (d.classes || []).some((c) => c.tier !== "core"));
}

/** px of the per-class week body for a style: a heading per day + a row per class. */
function weekClassesHeight(list, p) {
  return list.reduce((n, d) => n + p.weekHeadingRow + (d.classes?.length ?? 0) * p.weekClassRow, 0);
}

/** The largest step at which `h` fits `budget`, else the floor with fits:false. */
export function stepFit(h, budget, steps, floor) {
  for (const s of steps) if (h * s <= budget) return { scale: s, fits: true };
  return { scale: floor, fits: false };
}

/** Title case for a class name on the Lock screen: "Reformer Sculpt", never all
 *  caps. Lowercases, then capitalises the first letter of each word. */
export function titleCase(s) {
  return String(s ?? "").toLowerCase().replace(/\b[a-z]/g, (ch) => ch.toUpperCase());
}

/** Drop a single leading zero from a clock string: "06:00" -> "6:00", while
 *  "12:00" and "7:00" are unchanged. Used for the lock-screen clock. */
export function stripLeadingZero(t) {
  return String(t ?? "").replace(/^0(?=\d)/, "");
}

/** The render plan for an editorial style: pages (each with its days, part and
 *  scale). The month grid is always one page. A story post gets 840 px more body
 *  room and splits like square past that (Week by whole days, Day by classes).
 *  Lock screen (day only) is fixed pages of 3 cards (square) / 5 (story), in time
 *  order, no scaling. The Times week is a grid that never splits. */
export function editorialPlan({ days, mode, format, style } = {}) {
  const list = Array.isArray(days) ? days : [];
  const p = STYLE_FIT[style] || STYLE_FIT.invitation;
  const single = (d, scale) => ({ pages: [{ days: d, part: 1, parts: 1, scale }] });
  if (list.length === 0) return single(list, 1);
  if (mode === "month") return single(list, 1);           // month is always one page

  // A story post is taller: give every budget 840 px more room before splitting.
  const add = format === "story" ? 840 : 0;

  // Lock screen (day only): fixed pages of N cards in time order, no scaling —
  // 3 per square page, 5 per story page.
  if (style === "lock_screen") {
    const day = list[0];
    if (!day || !(day.classes?.length)) return single(list, 1);
    const per = format === "story" ? 5 : 3;
    const chunks = [];
    for (let i = 0; i < day.classes.length; i += per) {
      const slice = day.classes.slice(i, i + per);
      chunks.push([{ ...day, classes: slice, count: slice.length }]);
    }
    const parts = chunks.length;
    return { pages: chunks.map((d, i) => ({ days: d, part: i + 1, parts, scale: 1 })) };
  }

  if (mode === "week") {
    const weekBudget = p.weekBudget + add;
    if (p.weekKind === "grid") {
      const maxCol = list.reduce((m, d) => Math.max(m, d.classes?.length ?? 0), 0);
      const h = 60 + maxCol * p.gridRow;      // the tallest column; the grid never splits
      return single(list, stepFit(h, weekBudget, p.steps, p.floor).scale);
    }
    // weekKind "classes": a heading per day + a row per class. Tighten in steps;
    // past the floor, split into parts by WHOLE DAYS (a day's classes stay together).
    const fit = stepFit(weekClassesHeight(list, p), weekBudget, p.steps, p.floor);
    if (fit.fits) return single(list, fit.scale);
    const cap = weekBudget / p.floor;
    const pages = [];
    let cur = [];
    for (const d of list) {
      const dH = p.weekHeadingRow + (d.classes?.length ?? 0) * p.weekClassRow;
      if (cur.length && weekClassesHeight(cur, p) + dH > cap) { pages.push(cur); cur = []; }
      cur.push(d);
    }
    if (cur.length) pages.push(cur);
    const parts = pages.length;
    return { pages: pages.map((dd, i) => ({ days: dd, part: i + 1, parts, scale: stepFit(weekClassesHeight(dd, p), weekBudget, p.steps, p.floor).scale })) };
  }

  // day: tighten in steps, then split the classes across parts.
  const dayBudget = p.dayBudget + add;
  const day = list[0];
  const n = day?.classes?.length ?? 0;
  const fit = stepFit(n * p.dayRow, dayBudget, p.steps, p.floor);
  if (fit.fits || !day) return single(list, fit.scale);
  const per = Math.max(1, Math.floor((dayBudget / p.floor) / p.dayRow));
  const pages = [];
  for (let i = 0; i < day.classes.length; i += per) {
    const slice = day.classes.slice(i, i + per);
    pages.push([{ ...day, classes: slice, count: slice.length }]);
  }
  const parts = pages.length;
  return { pages: pages.map((d, i) => ({ days: d, part: i + 1, parts, scale: stepFit(d[0].classes.length * p.dayRow, dayBudget, p.steps, p.floor).scale })) };
}
