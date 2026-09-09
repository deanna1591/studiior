/**
 * The only rules this product can keep.
 *
 * `rrule_weekdays()` (migration 057) handles FREQ=WEEKLY with BYDAY, INTERVAL,
 * UNTIL and COUNT and raises PT422 on everything else — deliberately, because a
 * parser that shrugs at what it does not understand is how a monthly series
 * silently generates weekly. So the form is a set of controls that can only
 * produce those, never a text field: a studio should not be able to type a rule
 * that fails at save, and the failure would otherwise arrive from a trigger.
 *
 * The database is still the boundary. This module is what makes the screen
 * pleasant; `update_series()` raises PT422 either way.
 */

export const DAYS = [
  { code: "SU", short: "Sun", long: "Sunday" },
  { code: "MO", short: "Mon", long: "Monday" },
  { code: "TU", short: "Tue", long: "Tuesday" },
  { code: "WE", short: "Wed", long: "Wednesday" },
  { code: "TH", short: "Thu", long: "Thursday" },
  { code: "FR", short: "Fri", long: "Friday" },
  { code: "SA", short: "Sat", long: "Saturday" },
] as const;

export type DayCode = (typeof DAYS)[number]["code"];

export type Rule = {
  days: DayCode[];
  /** Weeks between repeats. 1 = every week. */
  interval: number;
  /** Stop after this many classes. Null = no count. */
  count: number | null;
};

const ORDER: DayCode[] = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"];
const part = (rrule: string, key: string) =>
  new RegExp(`(?:^|;)${key}=([^;]*)`, "i").exec(rrule.toUpperCase())?.[1] ?? null;

export function buildRrule(rule: Rule): string {
  const days = ORDER.filter((d) => rule.days.includes(d));
  const bits = [`FREQ=WEEKLY`, `BYDAY=${days.join(",")}`];
  if (rule.interval > 1) bits.push(`INTERVAL=${rule.interval}`);
  if (rule.count && rule.count > 0) bits.push(`COUNT=${rule.count}`);
  return bits.join(";");
}

/**
 * Reading an existing series back into the controls.
 *
 * UNTIL comes back as a DATE rather than as part of the rule: it and
 * `class_series.ends_on` are two spellings of one fact, the generator already
 * takes the earlier of them, and a form offering both is a form where somebody
 * sets one and wonders why the other won. Anything the controls cannot express
 * is reported instead of being quietly dropped.
 */
export function parseRrule(rrule: string | null): {
  rule: Rule; until: string | null; unsupported: string | null;
} {
  const empty: Rule = { days: [], interval: 1, count: null };
  if (!rrule) return { rule: empty, until: null, unsupported: null };

  const freq = part(rrule, "FREQ");
  if (freq !== "WEEKLY") {
    return { rule: empty, until: null, unsupported: `FREQ=${freq ?? "(none)"}` };
  }
  const byday = part(rrule, "BYDAY");
  if (!byday) return { rule: empty, until: null, unsupported: "no BYDAY" };

  const days: DayCode[] = [];
  for (const raw of byday.split(",")) {
    const d = raw.trim() as DayCode;
    if (!ORDER.includes(d)) {
      return { rule: empty, until: null, unsupported: `BYDAY=${raw}` };
    }
    days.push(d);
  }

  const n = (v: string | null) => (v && /^\d+$/.test(v) ? Number(v) : null);
  const u = part(rrule, "UNTIL");
  // RFC 5545 writes it 20261231 or 20261231T235959Z; only the date matters here.
  const until = u && /^\d{8}/.test(u)
    ? `${u.slice(0, 4)}-${u.slice(4, 6)}-${u.slice(6, 8)}` : null;

  return {
    rule: { days, interval: n(part(rrule, "INTERVAL")) ?? 1, count: n(part(rrule, "COUNT")) },
    until,
    unsupported: null,
  };
}

/** The rule as a sentence. Nobody should have to read RFC 5545 to check their timetable. */
export function describeRule(rule: Rule, endsOn: string | null, time: string): string {
  if (rule.days.length === 0) return "Pick at least one day.";
  const names = ORDER.filter((d) => rule.days.includes(d))
    .map((d) => DAYS.find((x) => x.code === d)!.long);
  const list = names.length === 1 ? names[0]
    : `${names.slice(0, -1).join(", ")} and ${names[names.length - 1]}`;
  const every = rule.interval === 1 ? "Every"
    : rule.interval === 2 ? "Every other"
    : `Every ${rule.interval}th`;
  const when = `${every} ${list} at ${time.slice(0, 5)}`;
  if (rule.count) return `${when}, ${rule.count} times.`;
  if (endsOn) return `${when}, until ${endsOn}.`;
  return `${when}, ongoing.`;
}
