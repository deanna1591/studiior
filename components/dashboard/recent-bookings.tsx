"use client";

import { useState } from "react";
import type { RecentBookingItem } from "@/lib/dashboard";
import { Block, BlockEmpty } from "./block";

/**
 * Decision 56 — the newest bookings and cancellations across the studio, the
 * member app's activity made visible at the desk.
 *
 * This is NOT the "Recent activity" feed beside it: that reads timeline_events
 * (what HAPPENED — attended, paid, membership changes) and deliberately omits
 * bookings. This is the bookings, with no amounts anywhere (a booking is not a
 * payment). Each kind composes its own line, the way the activity feed does.
 *
 * The time shown is the CLASS time (when_label), built in SQL through
 * fmt_clock, so it already honours the studio's 12h/24h setting; this side
 * never formats a clock. 30 rows arrive; 10 show, "Show more" reveals the rest.
 */
const VERB: Record<RecentBookingItem["kind"], string> = {
  booked: "booked",
  booked_free: "booked a free class",
  cancelled: "cancelled",
  cancelled_late: "cancelled late",
  class_cancelled: "",
};

function Line({ i }: { i: RecentBookingItem }) {
  if (i.kind === "class_cancelled") {
    // No member — the studio cancelled the class. "{Class} · {when} was
    // cancelled — N members notified".
    return (
      <>
        {i.class_name}
        <span className="text-ink-3"> · {i.when_label}</span>
        <span className="text-ink-2"> was cancelled</span>
        {i.detail && <span className="text-ink-2"> — {i.detail}</span>}
      </>
    );
  }
  // A free-first seat reads "booked a free class" and names no class; everything
  // else names the class the seat was for.
  const showClass = i.kind !== "booked_free";
  return (
    <>
      <span className="text-ink-2">{VERB[i.kind]}</span>
      {showClass && <> {i.class_name}</>}
      <span className="text-ink-3"> · {i.when_label}</span>
    </>
  );
}

export default function RecentBookings({
  rows, error,
}: { rows: RecentBookingItem[]; error?: string | null }) {
  const [all, setAll] = useState(false);
  const shown = all ? rows : rows.slice(0, 10);

  return (
    <Block title="Recent bookings" error={error}>
      {rows.length === 0 ? (
        <BlockEmpty>
          No bookings yet. As members book and cancel classes, the newest show
          up here — the member app&rsquo;s activity, at the desk.
        </BlockEmpty>
      ) : (
        <>
          <ul className="divide-y divide-line">
            {shown.map((i, n) => (
              <li
                key={`${i.kind}-${i.happened_at}-${n}`}
                className="flex items-baseline gap-3 px-1 py-2"
              >
                <span className="min-w-0 flex-1 text-[13px] leading-[19px] text-ink">
                  {i.member_name && <span className="font-medium">{i.member_name}</span>}
                  {i.member_name && " "}
                  <Line i={i} />
                </span>
              </li>
            ))}
          </ul>
          {rows.length > 10 && !all && (
            <button
              type="button"
              onClick={() => setAll(true)}
              className="mt-2 text-[12px] font-medium leading-4 text-lime-text underline underline-offset-4 hover:text-lime-text2"
            >
              Show more ({rows.length - 10})
            </button>
          )}
        </>
      )}
    </Block>
  );
}
