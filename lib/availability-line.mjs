/**
 * The "Availability" line shown for an instructor, on BOTH the Instructors list
 * and the instructor detail page — pure, so `node --test` can guard it.
 *
 * Decision 46 follow-up: the line used to be driven by `availability_cycle`
 * alone, which only looks at `availability_submissions`. But an owner who enters
 * each instructor's weekly availability from the admin side writes a STANDING
 * PATTERN (rows in `instructor_availability`: day_of_week set, submission_id
 * null, approved) — no submission exists — so every one of them read
 * "Availability: nothing yet" while the scheduler (instructor_available_at_run
 * step 4) was reading the pattern perfectly well. This was a display bug only.
 *
 * Precedence: a submission for the collected month wins; only when there is no
 * submission does a covering standing pattern show; neither is "nothing yet".
 */

/** "YYYY-MM-DD" → "30 Nov 2026", parsed as a tz-less date (noon UTC). */
function formatThrough(isoDate) {
  return new Intl.DateTimeFormat("en-GB", {
    day: "numeric", month: "short", year: "numeric", timeZone: "UTC",
  }).format(new Date(`${isoDate}T12:00:00Z`));
}

/**
 * @typedef {Object} AvailabilityLineInput
 * @property {string|null|undefined} submissionStatus  the collected month's
 *   submission status: "submitted" | "approved" | "changes_requested" | "none"
 *   | null (none/null => no submission).
 * @property {string} monthLabel  the collected month, e.g. "November 2026",
 *   used in the approved line.
 * @property {{ endsOn: string|null }|null} standing  a covering standing
 *   pattern, or null when there is none; endsOn null means open-ended (no end
 *   date), else the latest effective_to ("YYYY-MM-DD").
 * @property {string} instructorId  for the weekly-pattern link.
 */

/**
 * @param {AvailabilityLineInput} input
 * @returns {{ text: string, href: string, linkLabel: string }}
 */
export function availabilityLine({ submissionStatus, monthLabel, standing, instructorId }) {
  switch (submissionStatus) {
    case "submitted":
      return { text: "Availability: submitted · waiting for you",
               href: "/availability", linkLabel: "Review" };
    case "approved":
      return { text: `Availability: approved for ${monthLabel}`,
               href: "/availability", linkLabel: "Review" };
    case "changes_requested":
      return { text: "Availability: sent back",
               href: "/availability", linkLabel: "Review" };
  }
  // No submission for the month. A standing pattern that covers it is not
  // "nothing" — it is exactly what the scheduler is reading.
  if (standing) {
    const tail = standing.endsOn
      ? ` through ${formatThrough(standing.endsOn)}`
      : ", no end date";
    return { text: `Availability: weekly pattern${tail}`,
             href: `/instructors/${instructorId}/availability`,
             linkLabel: "View the week" };
  }
  return { text: "Availability: nothing yet",
           href: "/availability", linkLabel: "Review" };
}

/**
 * The "covered" state of a month for an instructor — the pure TS twin of the SQL
 * instructor_month_covered (Decision 46 amendment). A real submission wins (its
 * status, except a draft, which is treated as no submission just as
 * availabilityLine does); else a covering standing pattern is 'pattern'; else
 * 'none'. The node test asserts this agrees with the SQL on the five cases.
 *
 * @param {string|null|undefined} submissionStatus  submitted | approved |
 *   changes_requested | draft | none | null
 * @param {boolean} hasPattern  a covering standing pattern exists
 * @returns {'submitted'|'approved'|'changes_requested'|'pattern'|'none'}
 */
export function monthCoveredState(submissionStatus, hasPattern) {
  if (submissionStatus === "submitted"
   || submissionStatus === "approved"
   || submissionStatus === "changes_requested") {
    return submissionStatus;
  }
  return hasPattern ? "pattern" : "none";
}

/**
 * The short note placed beside a "not sent yet" instructor on the /availability
 * review page when they have a covering standing pattern — they are not
 * actually missing. Empty when there is no such pattern.
 *
 * @param {{ endsOn: string|null }|null} standing
 * @returns {string}
 */
export function standingNote(standing) {
  if (!standing) return "";
  return standing.endsOn
    ? `weekly pattern through ${formatThrough(standing.endsOn)}`
    : "weekly pattern, no end date";
}

/** "November" for a (y, m1) — m1 is 1-12 — as a tz-less calendar month. */
function monthName(y, m1) {
  return new Intl.DateTimeFormat("en-GB", { month: "long", timeZone: "UTC" })
    .format(new Date(Date.UTC(y, m1 - 1, 1)));
}
/** "20 October" for a (y, m1, day). */
function dayMonth(y, m1, day) {
  return new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "long", timeZone: "UTC" })
    .format(new Date(Date.UTC(y, m1 - 1, day)));
}
/** The calendar month after (y, m1), with the year roll (December → January). */
function monthAfter(y, m1) {
  return m1 === 12 ? { y: y + 1, m1: 1 } : { y, m1: m1 + 1 };
}
/** The calendar month before (y, m1), with the year roll (January → December). */
function monthBefore(y, m1) {
  return m1 === 1 ? { y: y - 1, m1: 12 } : { y, m1: m1 - 1 };
}

/**
 * The one-line status at the top of the instructor availability page — when the
 * next month opens and its deadline, in plain language (Decision 46). Pure so
 * `node --test` can guard it; the page resolves the state and passes it in.
 *
 * The collection cycle is fixed: the month being collected opens on the 1st of
 * the PREVIOUS month and is due on `availability_due_day` of that previous
 * month. So the deadline for a shown month M is always dueDay-of-(M − 1), and a
 * cycle that points at the NEXT month N = M + 1 opens on 1 M and is due dueDay M.
 *
 *  - `open`     — M is being collected now:  "M availability is open · submit by {due}."
 *  - `overdue`  — M was due and is not in:   "M availability was due {due} — submit now; …"
 *                 (also derived from `today` when the caller passes `open` but the
 *                  due date has already passed, so a stale page cannot under-warn.)
 *  - `locked`   — M is published/approved (done); point at the next cycle N:
 *  - `submitted`— M is sent, waiting; point at the next cycle N:
 *                 "N availability opens on 1 M · submit by {dueDay M}."
 *  - `pattern`  — the studio holds a standing pattern (no form); the extra clause
 *                 appended after the on-file sentence, pointing at the next cycle:
 *                 "If your hours change for N, tell the studio by {dueDay M}."
 *
 * @param {Object} input
 * @param {string} input.today        studio-local "YYYY-MM-DD".
 * @param {string} input.shownMonth   the collected month, "YYYY-MM-01".
 * @param {number} input.dueDay       studio_settings.availability_due_day (1-28).
 * @param {'locked'|'submitted'|'open'|'overdue'|'pattern'} input.state
 * @returns {string}
 */
export function availabilityStatusLine({ today, shownMonth, dueDay, state }) {
  const [sy, sm] = shownMonth.split("-").map(Number); // sm is 1-12
  const prev = monthBefore(sy, sm);
  const next = monthAfter(sy, sm);

  if (state === "open" || state === "overdue") {
    // M is being collected; due is dueDay of the month before it.
    const dueISO = `${prev.y}-${String(prev.m1).padStart(2, "0")}-${String(dueDay).padStart(2, "0")}`;
    const dueFmt = dayMonth(prev.y, prev.m1, dueDay);
    const name = monthName(sy, sm);
    const overdue = state === "overdue" || (state === "open" && today > dueISO);
    return overdue
      ? `${name} availability was due ${dueFmt} — submit now; the studio may already be building the timetable.`
      : `${name} availability is open · submit by ${dueFmt}.`;
  }

  if (state === "pattern") {
    // The extra clause after the on-file sentence — the next cycle's deadline.
    return `If your hours change for ${monthName(next.y, next.m1)}, tell the studio by ${dayMonth(sy, sm, dueDay)}.`;
  }

  // locked | submitted — M is done; point at the next cycle N = M + 1, which
  // opens on the 1st of M and is due on dueDay of M.
  return `${monthName(next.y, next.m1)} availability opens on ${dayMonth(sy, sm, 1)} · submit by ${dayMonth(sy, sm, dueDay)}.`;
}
