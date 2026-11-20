/**
 * Decision 18(c)/(d): a month's availability as flat, editable lines.
 *
 * A line is {day, from, to} (a weekday), {date, from, to} (a specific date with
 * its own hours) or {date, unavailable: true} (a date off). changeLines mirrors
 * the SQL availability_change_lines exactly, so the review card can preview what
 * the instructor's email will say. Pure, node-tested.
 */

const DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** "9:00" -> "09:00"; anything unreadable passes through. */
export function hhmm(t) {
  const m = /^(\d{1,2}):(\d{2})/.exec(String(t ?? ""));
  return m ? `${m[1].padStart(2, "0")}:${m[2]}` : String(t ?? "");
}

/** "Tue" for a weekday line, "Mon 14 Dec" for a date line. */
export function lineLabel(line) {
  if (line && line.day != null && line.day !== "") return DAYS[Number(line.day)] ?? "";
  const [y, m, d] = String(line?.date ?? "").split("-").map(Number);
  if (!y || !m || !d) return "";
  const wd = new Date(Date.UTC(y, m - 1, d)).getUTCDay();
  return `${DAYS[wd]} ${d} ${MONTHS[m - 1]}`;
}

/** The text after the label: "09:00 to 20:00" or "not available". */
export function lineHours(line) {
  return line?.unavailable ? "not available" : `${hhmm(line?.from)} to ${hhmm(line?.to)}`;
}

/** The whole line as the review card shows it: "Tue 09:00 to 20:00". */
export function lineText(line) {
  return `${lineLabel(line)} ${lineHours(line)}`;
}

/** availability_submission_week's {days, dates} -> flat lines, weekdays Monday first, then dates. */
export function linesFromWeek(week) {
  const out = [];
  const days = [...(week?.days ?? [])].sort((a, b) => ((a.day + 6) % 7) - ((b.day + 6) % 7));
  for (const d of days) for (const r of d.ranges ?? []) out.push({ day: d.day, from: hhmm(r.from), to: hhmm(r.to) });
  const dates = [...(week?.dates ?? [])].sort((a, b) => String(a.date).localeCompare(String(b.date)));
  for (const d of dates) {
    if (d.unavailable) out.push({ date: d.date, unavailable: true });
    else for (const r of d.ranges ?? []) out.push({ date: d.date, from: hhmm(r.from), to: hhmm(r.to) });
  }
  return out;
}

function groups(lines) {
  const g = new Map();
  for (const l of lines ?? []) {
    const isDay = l.day != null && l.day !== "";
    const k = isDay ? `d${l.day}` : `t${l.date}`;
    const sortk = isDay ? `0${(Number(l.day) + 6) % 7}` : `1${l.date}`;
    const cur = g.get(k) ?? { sortk, label: lineLabel(l), off: false, rngs: [] };
    if (l.unavailable) cur.off = true; else cur.rngs.push(`${hhmm(l.from)} to ${hhmm(l.to)}`);
    g.set(k, cur);
  }
  for (const v of g.values()) v.txt = v.off ? "not available" : [...v.rngs].sort().join(", ");
  return g;
}

/**
 * One line per changed day or date, weekdays Monday first, then dates:
 * "Tue 09:00 to 20:00 is now 10:00 to 20:00", "Wed 09:00 to 12:00 added",
 * "Thu 09:00 to 20:00 removed".
 */
export function changeLines(before, after) {
  const b = groups(before), a = groups(after);
  const keys = [...new Set([...b.keys(), ...a.keys()])];
  const rows = [];
  for (const k of keys) {
    const x = b.get(k), y = a.get(k);
    if (!x) rows.push([y.sortk, `${y.label} ${y.txt} added`]);
    else if (!y) rows.push([x.sortk, `${x.label} ${x.txt} removed`]);
    else if (x.txt !== y.txt) rows.push([y.sortk, `${y.label} ${x.txt} is now ${y.txt}`]);
  }
  return rows.sort((p, q) => (p[0] < q[0] ? -1 : p[0] > q[0] ? 1 : 0)).map((r) => r[1]);
}

/** The card's warning when the new hours leave assigned classes outside them. */
export function outsideWarning(first, n) {
  if (!n || n < 1) return null;
  return `${first || "This coach"} is assigned to ${n} ${n === 1 ? "class" : "classes"} in these hours. The assignments stay; reassign them from the Schedule.`;
}

/** Client-side check before saving, the same rules the database applies. */
export function lineError(line, periodStart, periodEnd) {
  const isDay = line.day != null && line.day !== "";
  if (!isDay) {
    if (!line.date) return "Pick a date.";
    if (periodStart && line.date < periodStart) return "That date is before this month.";
    if (periodEnd && line.date > periodEnd) return "That date is after this month.";
    if (line.unavailable) return null;
  }
  if (!line.from || !line.to) return "Give a from and a to time.";
  if (hhmm(line.to) <= hhmm(line.from)) return "A time must end after it starts.";
  return null;
}
