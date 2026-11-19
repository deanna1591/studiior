// Decision 116 — private sessions, the pure helpers (node-tested). The slot rule
// itself lives in SQL (private_slots); these only shape what it returns for the
// screen, and mirror the one cancel rule so the member is told before the tap.

/** Whole minutes between two instants. */
const mins = (a, b) => Math.round((b - a) / 60000);

/**
 * Group free 30-minute starts into contiguous GAPS. Two starts belong to the same
 * gap when they are `stepMin` apart. Input is ISO strings (any order); output is
 * [{ from, to, starts: [iso...] }] in time order, `to` being the LAST start.
 */
export function groupGaps(starts, stepMin = 30) {
  const sorted = [...new Set(starts)].map((s) => new Date(s).getTime()).sort((a, b) => a - b);
  const gaps = [];
  for (const t of sorted) {
    const g = gaps[gaps.length - 1];
    if (g && mins(g.last, t) === stepMin) {
      g.last = t; g.starts.push(t);
    } else {
      gaps.push({ first: t, last: t, starts: [t] });
    }
  }
  return gaps.map((g) => ({
    from: new Date(g.first).toISOString(),
    to: new Date(g.last).toISOString(),
    starts: g.starts.map((t) => new Date(t).toISOString()),
  }));
}

const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

/** The studio-local weekday (0 = Sunday) of an instant. */
export function localWeekday(iso, timeZone) {
  const name = new Intl.DateTimeFormat("en-US", { timeZone, weekday: "short" }).format(new Date(iso));
  return WEEKDAYS.indexOf(name);
}
/** The studio-local calendar date (YYYY-MM-DD) of an instant. */
export function localDate(iso, timeZone) {
  return new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" })
    .format(new Date(iso));
}

/**
 * Gap count per weekday: the gaps each studio-local day holds, summed by weekday
 * (Mon..Sun). A gap never spans two days (a private must start and end the same
 * day), so grouping by local date first is exact.
 */
export function gapsPerWeekday(starts, timeZone, stepMin = 30) {
  const byDate = new Map();
  for (const s of starts) {
    const d = localDate(s, timeZone);
    if (!byDate.has(d)) byDate.set(d, []);
    byDate.get(d).push(s);
  }
  const out = { Mon: 0, Tue: 0, Wed: 0, Thu: 0, Fri: 0, Sat: 0, Sun: 0 };
  for (const [, list] of byDate) {
    const n = groupGaps(list, stepMin).length;
    out[WEEKDAYS[localWeekday(list[0], timeZone)]] += n;
  }
  return out;
}

/**
 * The cancel rule, mirrored from private_cancel: ON TIME when now is earlier
 * than the start minus the studio's lead time. On time returns the payment as
 * credit (or the pack credit); late keeps the fee and the coach is paid.
 */
export function cancelIsOnTime(startsMs, leadHours, nowMs) {
  return nowMs < startsMs - leadHours * 3600 * 1000;
}

/** The sentence shown before the tap. */
export function cancelNoticeLine({ startsMs, leadHours, nowMs, fmt }) {
  if (nowMs >= startsMs) return "This session has started.";
  const cutoff = startsMs - leadHours * 3600 * 1000;
  if (nowMs < cutoff) {
    return `Free to cancel or move until ${fmt(cutoff)}. After that the fee is kept.`;
  }
  return `It's less than ${leadHours} hours before the session, so cancelling now keeps the fee.`;
}

/** Refusal sentences for every reason private_book / private_move / private_cancel return. */
export const PRIVATE_REASONS = {
  no_such_type: "That session type isn't offered any more.",
  not_enabled: "This studio isn't offering private sessions right now.",
  wrong_companion_count: "Add the names and emails of everyone joining you.",
  companion_details: "Each person joining needs a name and an email.",
  companion_duplicate: "Each person needs their own email address.",
  too_soon: "That time is too soon to book. Choose a later one.",
  outside_hours: "That time is outside the studio's hours.",
  coach_unavailable: "That coach isn't free then. Choose another time or any coach.",
  no_room: "The studio is busy then. Choose another time.",
  room_busy: "The studio is busy then. Choose another time.",
  coach_busy: "That coach is teaching then. Choose another time.",
  no_provider: "This studio isn't set up for online payment. Ask the studio to book it for you.",
  pack_1to1_only: "A private pack is for 1:1 sessions only.",
  no_pack_credit: "You have no private pack credits left.",
  not_enough_credit: "Your account credit doesn't cover this session.",
  bad_pay_mode: "That payment option isn't available.",
  unknown_method: "Choose how the session was paid.",
  already_moved: "You've already moved this session once. Ask the studio to change it.",
  too_late_to_move: "It's too close to the session to move it.",
  not_scheduled: "This session can't be changed now.",
  slot_busy: "That time was just taken. Choose another.",
  already_cancelled: "This session is already cancelled.",
};
export function privateReasonSentence(reason) {
  return PRIVATE_REASONS[reason] ?? "That didn't work. Please try again.";
}

/** The VAT split the Sales line shows (12 percent inclusive, the BIR arithmetic). */
export function vatSplit(totalCents) {
  const net = Math.round(totalCents / 1.12);
  return { netCents: net, vatCents: totalCents - net };
}
