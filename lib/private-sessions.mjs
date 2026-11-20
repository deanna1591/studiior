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
  time_taken: "That time was just taken. Pick another time.",
};
export function privateReasonSentence(reason) {
  return PRIVATE_REASONS[reason] ?? "That didn't work. Please try again.";
}

/** The VAT split the Sales line shows (12 percent inclusive, the BIR arithmetic). */
export function vatSplit(totalCents) {
  const net = Math.round(totalCents / 1.12);
  return { netCents: net, vatCents: totalCents - net };
}

/** Decision 116(a): the label on a slot that replaces an empty class. */
export const REPLACES_LABEL = "Replaces an empty class";
export function slotLabel(replacesOccurrenceId) {
  return replacesOccurrenceId ? REPLACES_LABEL : null;
}

/**
 * Decision 116(a), mirrored from SQL private_replace_ok for display and tests: an
 * empty class may be replaced when it is flex (any time), or when it is core or
 * always-runs and the private starts within the studio's replace window.
 */
export function replaceAllowed({ empty, targeted, tier, hoursUntilStart, windowHours }) {
  if (!empty || targeted) return false;
  if (tier === "flex") return true;
  return hoursUntilStart <= (windowHours ?? 48);
}

/**
 * Decision 116(b): private_slots rows ({ starts_at, coach_ids, replaces_occurrence_id })
 * merged into one entry per start, each carrying its coaches. A free hour lists
 * every available private coach; an empty class lists only its own coach and is
 * marked `replaces`. Starts are normalised to toISOString() so they match
 * groupGaps' keys (PostgREST returns "+00:00").
 */
export function mergeSlots(rows) {
  const by = new Map();
  for (const r of rows ?? []) {
    const start = new Date(r.starts_at).toISOString();
    if (!by.has(start)) by.set(start, { start, coaches: [] });
    const slot = by.get(start);
    for (const id of r.coach_ids ?? []) {
      if (!slot.coaches.some((c) => c.id === id)) {
        slot.coaches.push({ id, replaces: !!r.replaces_occurrence_id });
      }
    }
  }
  return [...by.values()].sort((a, b) => a.start.localeCompare(b.start));
}

/**
 * The coach filter: all coaches (null) shows every slot; one coach shows only
 * that coach's open times, each slot narrowed to that coach.
 */
export function slotsForCoach(slots, coachId) {
  if (!coachId) return slots;
  return slots
    .filter((s) => s.coaches.some((c) => c.id === coachId))
    .map((s) => ({ ...s, coaches: s.coaches.filter((c) => c.id === coachId) }));
}

/**
 * The coach step after a time is picked: skipped (the coach is set) when the slot
 * has exactly one coach, otherwise the member picks from the slot's coaches.
 */
export function coachStep(slot) {
  if (!slot || slot.coaches.length === 0) return { skip: false, coachId: null, choices: [] };
  if (slot.coaches.length === 1) return { skip: true, coachId: slot.coaches[0].id, choices: [] };
  return { skip: false, coachId: null, choices: slot.coaches.map((c) => c.id) };
}

/** True when booking this slot with this coach replaces an empty class. */
export function slotReplaces(slot, coachId) {
  if (!slot) return false;
  const pool = coachId ? slot.coaches.filter((c) => c.id === coachId) : slot.coaches;
  return pool.length > 0 && pool.every((c) => c.replaces);
}

/**
 * Decision 116(c): the "Coaches" filter row. "All" first, then each private
 * coach as a round photo (initials when there is none) with the first name
 * under it; the selected one is marked. Pure, node-tested.
 */
export function coachAvatarRow(coaches, selectedId) {
  const sel = selectedId ?? null;
  return [
    { id: null, label: "All", photo: null, initials: null, selected: sel === null },
    ...(coaches || []).map((c) => {
      const display = String(c.display_name || c.name || "").trim();
      const first = String(c.first_name || display.split(/\s+/)[0] || "").trim();
      const photo = c.avatar_url && String(c.avatar_url).trim() ? String(c.avatar_url) : null;
      const initials = String(display || first).split(/\s+/).filter(Boolean).slice(0, 2)
        .map((w) => (w[0] || "").toUpperCase()).join("") || "?";
      return { id: c.id, label: first, photo, initials: photo ? null : initials, selected: sel === c.id };
    }),
  ];
}

/** The profile sheet's certification lines: trimmed, empty ones dropped. */
export function certificationLines(certs) {
  return Array.isArray(certs) ? certs.map((c) => String(c ?? "").trim()).filter(Boolean) : [];
}
