import { fmtClock } from "@/lib/clock";
import type { Deadline } from "@/components/staff/post-styles-v5";

/** Decision 93 (d): the flex deadline as the v5 posts word it, from the studio's
 *  flex deadline settings: the evening-before time in the studio clock, or the
 *  hours before the class. */
export function deadlineFrom(
  s: { flex_deadline_mode?: string | null; flex_deadline_time?: string | null; flex_deadline_hours?: number | null; time_format?: string | null } | null | undefined,
  tz: string,
): Deadline {
  if (!s) return {};
  const [h, m] = String(s.flex_deadline_time ?? "").split(":").map(Number);
  const time = Number.isFinite(h) && Number.isFinite(m) ? fmtClock(h * 60 + m, tz, (s.time_format === "12h" ? "12h" : "24h")) : null;
  return { mode: s.flex_deadline_mode ?? null, time, hours: s.flex_deadline_hours ?? null };
}
