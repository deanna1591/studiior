// Decision 77b — pure helpers for the closure-notice form. No imports, so
// `node --test` (test/closure-notice.test.mjs) runs them. The ACTUAL email's
// per-member system block is built in SQL (close_studio has each member's
// cancelled-class list); these cover the FORM: the default resume date, the
// horizon warning, and the illustrative system block shown in the preview.

/** "YYYY-MM-DD" + 1 day, as "YYYY-MM-DD" (the default "classes resume on"). */
export function resumeDefault(endsOn) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(String(endsOn ?? ""))) return "";
  const d = new Date(`${endsOn}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + 1);
  return d.toISOString().slice(0, 10);
}

/**
 * Warn (never block) when the resume date is past the last day the generator
 * has materialised classes for — today + occurrence_horizon_days. A member
 * following the link would see an empty timetable.
 *
 * @param {string} resumesOn       "YYYY-MM-DD"
 * @param {string} today           studio-local "YYYY-MM-DD"
 * @param {number} horizonDays     studio_settings.occurrence_horizon_days
 */
export function beyondHorizon(resumesOn, today, horizonDays) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(String(resumesOn ?? ""))
   || !/^\d{4}-\d{2}-\d{2}$/.test(String(today ?? ""))) return false;
  const end = new Date(`${today}T00:00:00Z`);
  end.setUTCDate(end.getUTCDate() + (Number(horizonDays) || 0));
  return new Date(`${resumesOn}T00:00:00Z`).getTime() > end.getTime();
}

/** A human date "Monday 16 November 2026" for a tz-less calendar date — no
 *  comma, matching the SQL to_char(…, 'FMDay FMDD FMMonth YYYY'). */
export function longDate(iso) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(String(iso ?? ""))) return "";
  return new Intl.DateTimeFormat("en-GB",
    { weekday: "long", day: "numeric", month: "long", year: "numeric", timeZone: "UTC" })
    .format(new Date(`${iso}T00:00:00Z`))
    .replace(",", "");
}

/**
 * The illustrative system block shown in the form preview (the real email
 * builds each member's own list in SQL). Mirrors the SQL wording.
 *
 * @param {{ resumesOn: string, sampleCancelled?: string[] }} input
 * @returns {{ html: string, text: string }}
 */
export function previewSystemBlock({ resumesOn, sampleCancelled = [] }) {
  const resume = `Classes resume ${longDate(resumesOn)}.`;
  const listHtml = sampleCancelled.length
    ? `<p>These classes of yours were cancelled:</p><ul>${sampleCancelled.map((c) => `<li>${c}</li>`).join("")}</ul><p>Your credit (or free first class) is back.</p>`
    : "";
  const listText = sampleCancelled.length
    ? `These classes of yours were cancelled:\n${sampleCancelled.join("\n")}\n\nYour credit (or free first class) is back.\n\n`
    : "";
  return {
    html: `${listHtml}<p>${resume}</p><p><a href="#">Book your week</a></p>`,
    text: `${listText}${resume}\n\nBook your week.`,
  };
}
