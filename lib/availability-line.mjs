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
