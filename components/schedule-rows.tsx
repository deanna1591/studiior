import Link from "next/link";
import { fmtTime } from "@/lib/time";

export type Occ = {
  id: string;
  name: string;
  starts_at: string;
  capacity: number;
  booked_count: number;
  waitlist_count?: number | null;
  status: string;
  instructors?: { display_name: string } | null;
  rooms?: { name: string } | null;
};

/**
 * A class is a row, not a card.
 *
 * Status is carried by the row itself rather than by a chip sitting on it:
 * a class that has been and gone is greyed, a cancelled one is hatched and
 * struck through, and whether a class is full is answered by the count and the
 * action — "4 spaces" or "Full · 2 waiting" — not by a coloured badge. Badges
 * turn a schedule into a colour-matching exercise; this is meant to be read.
 */
export function ScheduleRow({ o, timeZone, now }: { o: Occ; timeZone: string; now: number }) {
  const past = new Date(o.starts_at).getTime() < now;
  const cancelled = o.status === "cancelled";
  const full = o.booked_count >= o.capacity;
  const waiting = o.waitlist_count ?? 0;

  const spaces = o.capacity - o.booked_count;
  const state = cancelled
    ? "Cancelled"
    : full
      ? waiting > 0 ? `Full · ${waiting} waiting` : "Full"
      : `${spaces} space${spaces === 1 ? "" : "s"}`;

  // Greying stops at --ink-3 (4.59). A past class is still a thing people read
  // — who taught it, who came — so it is de-emphasised, never faded out.
  const tone = past || cancelled ? "text-ink-3" : "text-ink";

  return (
    <Link
      href={`/roster/${o.id}`}
      className={`grid grid-cols-[64px_1fr_auto] items-center gap-x-4 px-3 py-2.5 md:grid-cols-[72px_minmax(0,1fr)_150px_120px_96px] md:gap-x-5 ${
        cancelled ? "hatched" : ""
      } ${past ? "" : "hover:bg-paper"}`}
    >
      <span className={`num text-[13px] ${past || cancelled ? "text-ink-3" : "text-ink-2"}`}>
        {fmtTime(o.starts_at, timeZone)}
      </span>

      <span className={`min-w-0 truncate text-[14px] leading-5 ${tone} ${cancelled ? "line-through" : ""}`}>
        {o.name}
      </span>

      <span className="hidden truncate text-[13px] leading-[18px] text-ink-3 md:block">
        {o.instructors?.display_name ?? "No instructor"}
      </span>

      <span className="hidden truncate text-[13px] leading-[18px] text-ink-3 md:block">
        {o.rooms?.name ?? "—"}
      </span>

      <span className="text-right">
        <span className={`num block text-[13px] ${past || cancelled ? "text-ink-3" : "text-ink"}`}>
          {o.booked_count}/{o.capacity}
        </span>
        <span className="block text-[11px] leading-[15px] text-ink-3">{state}</span>
      </span>
    </Link>
  );
}
