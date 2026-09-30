/**
 * The availability week, shared by the desktop editor and the phone editor.
 *
 * One shape, one status vocabulary, one validator — because the two editors
 * post the SAME payload to the SAME `submit_availability`, and a second copy of
 * any of this is how the two quietly disagree about what a valid week is. The
 * database's own `to > from` check is still the boundary; this is the friendly
 * pre-check that gives a sentence instead of a raw Postgres error, and it is the
 * only place the 15-minute-step and no-overlap rules live.
 */
export type Range = { from: string; to: string };
export type Day = { day: number; ranges: Range[] };

export const DAY_NAMES = [
  "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
];

/** The one status line, moved out of the staff page so both editors read it. */
export const STATUS_LINE: Record<string, string> = {
  none: "Not sent yet.",
  draft: "Saved as a draft. The studio has not seen it.",
  submitted: "Sent. Waiting for the studio.",
  approved: "Approved. Classes are being scheduled around it.",
  changes_requested: "The studio has asked for a change.",
};

/** The verb under the status line — what the instructor can do about it now. */
export function statusHelp(status: string, locked: boolean): string {
  if (locked) return "To change it now, ask the studio to reopen the month.";
  if (status === "submitted") return "You can still change it until they look at it.";
  return "Fill in the hours you can teach in each day. Copy a day across the week rather than typing it seven times.";
}

/** Seven days, in order, each carrying whatever the submission held. */
export function emptyWeek(initial: Day[] = []): Day[] {
  return Array.from({ length: 7 }, (_, d) =>
    initial.find((x) => x.day === d) ?? { day: d, ranges: [] });
}

const HHMM = /^([01]\d|2[0-3]):([0-5]\d)$/;

/** Minutes since midnight, or null if the value is not a valid HH:MM. */
function minutes(t: string): number | null {
  const m = HHMM.exec(t);
  if (!m) return null;
  return Number(m[1]) * 60 + Number(m[2]);
}

/**
 * Returns the first problem as a sentence, or null when the week is clean.
 *
 * The three rules are the ones the desktop's help text promises: a range ends
 * after it starts, times sit on a 15-minute step (a phone's native time picker
 * can offer finer, and a 07:07 start is a mistake not a plan), and two ranges
 * on one day do not overlap. It never rejects an empty day — "not available" is
 * a legitimate answer, not an incomplete one.
 */
export function validateWeek(days: Day[]): string | null {
  for (const d of days) {
    const name = DAY_NAMES[d.day] ?? "that day";
    const spans: [number, number][] = [];
    for (const r of d.ranges ?? []) {
      const a = minutes(r.from);
      const b = minutes(r.to);
      if (a === null || b === null) return `${name} has a time that isn't a real clock time.`;
      if (a % 15 !== 0 || b % 15 !== 0) return `${name}'s times need to be on the quarter hour.`;
      if (b <= a) return `On ${name}, a range has to end after it starts.`;
      spans.push([a, b]);
    }
    spans.sort((x, y) => x[0] - y[0]);
    for (let i = 1; i < spans.length; i++) {
      if (spans[i][0] < spans[i - 1][1]) return `${name} has two ranges that overlap.`;
    }
  }
  return null;
}
