// Decision 58 fix — where an instructor's notification should open.
//
// Pure: notificationHref(kind, payload) → a portal route, or null when there is
// nothing specific to open (an unknown kind, or a kind whose payload lacks the
// id it would need — e.g. a week/day class-reminder digest carries a class_list,
// not a single occurrence_id, so there is no one roster to open). Never guesses
// an id, and never needs a new column: the ids it reads (occurrence_id,
// month_ym / period_start) are already on the stored payloads.

/**
 * @param {string} kind  the notification's template_key
 * @param {Record<string, unknown> | null | undefined} payload
 * @returns {string | null}
 */
export function notificationHref(kind, payload) {
  const p = payload || {};
  const occ = typeof p.occurrence_id === "string" ? p.occurrence_id : null;
  const roster = occ ? `/instructor/roster/${occ}` : null;

  switch (kind) {
    // A cover request directed at me, an urgent one, or open shifts I could take,
    // and the outcome of a shift application — all live on Open shifts.
    case "cover_available":
    case "cover_urgent":
    case "cover_asked":
    case "open_shifts_available":
    case "shift_approved":
    case "shift_declined":
    case "shift_withdrawn":
      return "/instructor/shifts";

    // A cover outcome (taken by someone, approved, declined) → the class it was
    // about if the payload names it, else My schedule.
    case "cover_approved":
    case "cover_declined":
    case "cover_auto_covered":
    case "cover_asked_confirmed":
    case "cover_asked_declined":
    case "cover_colleague_declined":
      return roster ?? "/instructor/schedule";

    // The monthly roster → that month.
    case "month_roster":
    case "month_roster_plain": {
      const m = monthKey(p);
      return m ? `/instructor/month?m=${m}` : null;
    }

    // A single class: assigned, changed, cancelled, a booking landed, or I was
    // booked in → that class's roster. A payload with no occurrence_id (the
    // week/day reminder digests) has no one class to open, so → null.
    case "instructor_assigned":
    case "instructor_class_cancelled":
    case "instructor_substituted":
    case "class_reassigned_off":
    case "instructor_booking_alert":
    case "booking_for_instructor":
    case "shift_taken_off":
    case "instructor_week_ahead":
    case "instructor_tomorrow":
      return roster;

    // Availability due / sent back / approved / narrowed → the availability editor.
    case "availability_due":
    case "availability_changes_requested":
    case "availability_approved":
    case "availability_narrowed_instructor":
      return "/instructor/availability";

    // Pay — no instructor-facing pay/period-closed notification exists today;
    // mapped defensively so one would land on My pay without a code change.
    case "period_closed":
    case "pay_ready":
      return "/instructor/pay";

    default:
      return null;
  }
}

/** The YYYY-MM the month page wants (?m=), from month_ym, period_start, or month. */
function monthKey(p) {
  const ym = p.month_ym;
  if (typeof ym === "string" && /^\d{4}-\d{2}$/.test(ym)) return ym;
  const ps = p.period_start;
  if (typeof ps === "string" && /^\d{4}-\d{2}/.test(ps)) return ps.slice(0, 7);
  const m = p.month;
  if (typeof m === "string" && /^\d{4}-\d{2}$/.test(m)) return m;
  return null;
}
