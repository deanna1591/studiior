// Decision 75a / 83 — pure helpers for the member/staff activity statement. The
// only dependency is the pure fmtClock (lib/clock.mjs), so they run under
// `node --test` (test/statement.test.mjs) and in the member /history page + the
// staff member profile.
import { fmtClock } from "./clock.mjs";

// The event kinds that are "class" activity (the Classes filter), vs the ones
// that are purely money (shown only under Credits & payments). A row can be both
// a class event AND carry a credit (a booked row with a -1 consume).
const CLASS_KINDS = new Set([
  "booked", "waitlisted", "free_first", "attended", "no_show",
  "cancelled", "late_cancelled", "studio_cancelled",
  "rescheduled", "instructor_changed", "joined",
]);

/** A row belongs to the "Credits & payments" view iff it moves credit or carries
 *  a money amount — exactly the brief's rule. */
export function isMoneyRow(r) {
  return (r.credit_delta ?? 0) !== 0 || r.amount_cents != null;
}

/** Filter the statement for one of the three tabs. `which` is 'all' | 'classes'
 *  | 'credits'. */
export function filterStatement(rows, which) {
  if (which === "credits") return rows.filter(isMoneyRow);
  if (which === "classes") return rows.filter((r) => CLASS_KINDS.has(r.kind));
  return rows.slice();
}

/** Group rows (already newest-first) into month sections, preserving order.
 *  `monthLabel(at)` turns a row's `at` into its heading (so the timezone and
 *  locale stay with the caller). */
export function groupByMonth(rows, monthLabel) {
  const out = [];
  for (const r of rows) {
    const label = monthLabel(r.at);
    const last = out[out.length - 1];
    if (last && last.label === label) last.items.push(r);
    else out.push({ label, items: [r] });
  }
  return out;
}

// Decision 83 (a) — one shared helper builds every row's wording, so the member
// /history statement and the staff Journey never drift and no surface keeps its
// own phrasing. No em dashes anywhere (the SQL titles carry some; normalise them
// out). The canonical wording is the table in Decision 83 amendment (a).

// Studio-local "{Day} {date}, {time}" for a class instant. tz may be a string
// (format defaults 24h) or { tz, timeFormat }. Day + date via Intl in the zone;
// time via fmtClock, the SQL fmt_clock() twin, so it honours 12h/24h.
function classWhen(at, tz, timeFormat) {
  if (!at) return null;
  const d = new Date(at);
  if (isNaN(d.getTime())) return null;
  const dayDate = new Intl.DateTimeFormat("en-GB", {
    weekday: "short", day: "numeric", month: "short", timeZone: tz,
  }).format(d);
  return `${dayDate}, ${fmtClock(d, tz, timeFormat)}`;
}

// A plan validity date ("5 Nov 2026"). plan_valid_to is a 'YYYY-MM-DD' date with
// no time; pin it to UTC noon so no zone shifts the day.
function validToLabel(ymd) {
  if (!ymd) return null;
  const d = new Date(`${ymd}T12:00:00Z`);
  if (isNaN(d.getTime())) return null;
  return new Intl.DateTimeFormat("en-GB", {
    day: "numeric", month: "short", year: "numeric", timeZone: "UTC",
  }).format(d);
}

const METHOD_LABEL = { gcash: "GCash", cash: "Cash", card_terminal: "Card", card: "Card", manual: "Manual", bank_transfer: "Bank transfer" };
function methodLabel(m) {
  if (!m) return null;
  return METHOD_LABEL[m] || (m.charAt(0).toUpperCase() + m.slice(1));
}

function tzParts(tz) {
  if (tz && typeof tz === "object") return { zone: tz.tz, fmt: tz.timeFormat || "24h" };
  return { zone: tz, fmt: "24h" };
}

const seg = (...parts) => parts.filter(Boolean).join(" · ");

/** The row's FIRST line (title), per the Decision 83 (a) table. Reshapes the SQL
 *  title where the table reorders it, and strips any em dash. */
export function statementTitle(row) {
  const t = (row.title || "").replace(/\s—\s/g, " ");
  switch (row.kind) {
    case "no_show": return t.replace(/^Did not attend /, "Missed ");
    case "rescheduled": return `${t.replace(/^Class rescheduled /, "")} moved`;
    case "free_first": return t.replace(/^Booked a free first class /, "Booked ");
    case "plan_ended": return `${row.plan_name || "Your plan"} ended`;
    case "credits_added":
      return row.plan_name ? `${row.credit_delta ?? 0} classes added to ${row.plan_name}` : t;
    case "purchase":
      // A paid drop-in is a payment tied to a booking, no membership.
      if (row.booking_id && !row.membership_id) return `Paid for ${t.replace(/^Bought /, "")}`;
      return t;
    default: return t;
  }
}

/** The row's SECOND line, per the Decision 83 (a) table. `money` is a caller-
 *  bound cents->string formatter (the studio's currency). `tz` is the studio zone
 *  (string, or { tz, timeFormat }). `forStaff` appends " · recorded by {name}" on
 *  a desk payment (member surfaces never show the recorder). Returns null when
 *  the title already says everything (joined, instructor_changed, payment_failed). */
export function rowLine(row, money, tz, forStaff) {
  const { zone, fmt } = tzParts(tz);
  const m = (c) => (money ? money(c) : String(c));
  const when = classWhen(row.occurrence_start, zone, fmt);           // class date/time, or null
  const head = when ? when + (row.instructor_first ? ` with ${row.instructor_first}` : "") : null;
  const left = row.credits_left_after;
  const plan = row.plan_name;
  const leftPart = left != null ? `, ${left} left` : "";

  switch (row.kind) {
    case "free_first":
      return seg(head, "Free first class");
    case "booked":
      if (row.due_cents != null) return seg(head, `Drop-in, ${m(row.due_cents)} due at the desk`);
      if (plan) return seg(head, `1 class from ${plan}${leftPart}`);
      return seg(head, "Drop-in, paid");
    case "attended":
      return head;
    case "no_show":
      // No instructor on a miss, per the table.
      if (plan && left != null) return seg(when, `Class used from ${plan}${leftPart}`);
      if (row.is_free_first) return seg(when, "Free class used");
      return seg(when, "Nothing owed");
    case "cancelled":
      if (row.is_free_first) return seg(when, "Free class kept");
      if (plan) return seg(when, `Class returned to ${plan}${leftPart}`);
      return when;
    case "late_cancelled":
      if (plan) return seg(when, `Class used from ${plan}${leftPart}`);
      if (row.is_free_first) return seg(when, "Free class used");
      return when;
    case "studio_cancelled":
      if (row.is_free_first) return seg(when, "Free class kept");
      if (plan) return seg(when, `Class returned to ${plan}${leftPart}`);
      return when;
    case "rescheduled":
      return when ? `Now ${when}` : null;
    case "purchase": {
      const amt = row.amount_cents != null ? m(row.amount_cents) : null;
      const desk = row.payment_method ? `${methodLabel(row.payment_method)} at the desk` : null;
      const recorded = forStaff && row.recorded_by_name ? `recorded by ${row.recorded_by_name}` : null;
      if (row.booking_id && !row.membership_id) return seg(amt, desk, recorded);   // paid drop-in
      const classes = row.plan_classes != null
        ? `${row.plan_classes} classes${row.plan_valid_to ? `, valid to ${validToLabel(row.plan_valid_to)}` : ""}`
        : null;
      return seg(amt, classes, desk, recorded);
    }
    case "refund": {
      const amt = row.amount_cents != null ? m(row.amount_cents) : null;
      const recorded = forStaff && row.recorded_by_name ? `recorded by ${row.recorded_by_name}` : null;
      return seg(amt ? `Refunded ${amt}` : null, recorded);
    }
    case "credits_added":
    case "credit_adjustment":
      return left != null ? `${left} left` : null;
    case "plan_ended": {
      const u = row.unused_credits ?? 0;
      return `${u} class${u === 1 ? "" : "es"} unused`;
    }
    default:
      return null;   // joined, instructor_changed, payment_failed, message_sent, …
  }
}

/** Recompute the running balance from the deltas, OLDEST first, so a caller can
 *  verify (or display) balance_after without trusting the stored column. Returns
 *  a new array in the SAME order as the input with balance_after filled; the
 *  input is assumed newest-first (as member_activity returns it). */
export function withRunningBalance(rowsNewestFirst) {
  const asc = [...rowsNewestFirst].reverse();
  let bal = 0;
  const byIdx = new Map();
  asc.forEach((r, i) => {
    bal += r.credit_delta ?? 0;
    byIdx.set(i, bal);
  });
  // Map back to newest-first order.
  const n = asc.length;
  return rowsNewestFirst.map((r, i) => ({ ...r, balance_after: byIdx.get(n - 1 - i) }));
}
