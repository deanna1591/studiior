"use client";

import { useRouter } from "next/navigation";

/**
 * One instructor at a time, across all three views.
 *
 * Instructor COLUMNS do not scale past a handful and are meaningless in a month
 * (six people across thirty days is 180 cells). What a studio wants is "show me
 * Christian's November" or "where are my gaps" — so this is a filter, not
 * columns. It narrows the day columns, and what week and month draw.
 * "Unassigned only" is the view for filling a month: every gap, one click.
 *
 * The value lives in the URL (`?instructor=`), so it survives navigation and
 * the view toggle, which read it back.
 */
export default function InstructorFilter({
  anchor, view, value, instructors,
}: {
  anchor: string;
  view: "day" | "week" | "month";
  value: string;
  instructors: { id: string; display_name: string }[];
}) {
  const router = useRouter();
  return (
    <label className="flex items-center gap-2 text-[12.5px] leading-4 text-ink-2">
      <span className="sr-only">Instructor</span>
      <select
        value={value}
        aria-label="Filter by instructor"
        onChange={(e) => {
          const v = e.target.value;
          const f = v ? `&instructor=${encodeURIComponent(v)}` : "";
          router.push(`/schedule?d=${anchor}&view=${view}${f}`);
        }}
        className="rounded-lg border border-line-2 bg-surface px-2 py-1 text-[13px] text-ink"
      >
        <option value="">All instructors</option>
        <option value="unassigned">Unassigned only</option>
        {instructors.map((i) => (
          <option key={i.id} value={i.id}>{i.display_name}</option>
        ))}
      </select>
    </label>
  );
}
