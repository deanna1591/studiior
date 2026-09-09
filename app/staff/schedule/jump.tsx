"use client";

import { useRouter } from "next/navigation";

/**
 * Go to a date.
 *
 * react-big-calendar's toolbar offers Today, Back and Next and nothing else,
 * which is fine for a studio whose timetable starts this week and useless for
 * one whose data begins seven weeks out: fifty-two presses, or nothing. This is
 * the control whose absence made a correct empty day read as a broken calendar.
 */
export default function JumpToDate({
  anchor, view,
}: { anchor: string; view: "day" | "week" }) {
  const router = useRouter();
  return (
    <label className="flex items-center gap-2 text-[12.5px] leading-4 text-ink-2">
      <span>Go to</span>
      <input
        type="date"
        value={anchor}
        onChange={(e) => {
          const v = e.target.value;
          if (/^\d{4}-\d{2}-\d{2}$/.test(v)) router.push(`/schedule?d=${v}&view=${view}`);
        }}
        className="rounded-lg border border-line-2 bg-surface px-2 py-1 text-[13px] text-ink"
      />
    </label>
  );
}
