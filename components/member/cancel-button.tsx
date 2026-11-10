"use client";

import { useEffect, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { haptic } from "@/lib/haptics";
import { cancelNotice } from "@/lib/cancel-notice";
import type { SeatKind } from "@/lib/cancel-notice";
import { fmtTime, fmtDayLong } from "@/lib/time";
import { Note } from "@/components/member/ui";
import type { ActionResult } from "@/app/member/actions";

/**
 * Decision 36 amendment — the cancellation rule shown BEFORE the tap.
 *
 * Under the Cancel button sits the one line cancelNotice() produces for this
 * seat kind and the studio's cutoff, re-evaluated on a 30s clock so it flips
 * from "free to cancel until X" to "less than N hours before class" on its own.
 * Before the cutoff the button cancels straight away; after it, the tap opens a
 * confirm sheet repeating the same sentence with Cancel anyway / Keep my spot.
 * Once the class has started there is no button, only the line. The result
 * sentence is the one cancelBooking builds (through the same helper), shown in
 * place of the button for a moment before the view refreshes (the booking is
 * gone, so the whole cancel block is replaced).
 */
export default function CancelButton({
  bookingId, seatKind, startsAt, cutoffMinutes, timeZone, timeFormat, cancel,
}: {
  bookingId: string;
  seatKind: SeatKind;
  startsAt: string;
  cutoffMinutes: number;
  timeZone: string;
  timeFormat?: "24h" | "12h";
  cancel: (p: ActionResult, f: FormData) => Promise<ActionResult>;
}) {
  const router = useRouter();
  const [now, setNow] = useState(() => Date.now());
  const [confirming, setConfirming] = useState(false);
  const [done, setDone] = useState<ActionResult | null>(null);
  const [pending, start] = useTransition();

  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 30_000);
    return () => clearInterval(id);
  }, []);

  const startsMs = new Date(startsAt).getTime();
  const notice = cancelNotice({
    startsMs, cutoffMinutes, nowMs: now, seatKind,
    fmtTime: (ms) => fmtTime(new Date(ms).toISOString(), timeZone, timeFormat),
    fmtDay: (ms) => fmtDayLong(new Date(ms).toISOString(), timeZone),
  });

  function submit() {
    setConfirming(false);
    start(async () => {
      const fd = new FormData();
      fd.set("booking_id", bookingId);
      fd.set("seat_kind", seatKind);
      const res = (await cancel(null, fd)) ?? { ok: false, message: "Something went wrong." };
      setDone(res);
      haptic(res.ok ? "success" : "warning");
      // Let the sentence land, then bring the view in line.
      if (res.ok) setTimeout(() => router.refresh(), 1900);
    });
  }

  function onTap() {
    haptic("tap");
    if (notice.phase === "after") { setConfirming(true); return; }
    submit();
  }

  // Class started: no button, the line only.
  if (notice.phase === "started" && !done) {
    return <p className="m-sub text-ink-2">{notice.line}</p>;
  }

  // Succeeded: the result sentence in place of the button (the view refreshes
  // shortly). A failure keeps the button so they can retry.
  if (done?.ok) {
    return <Note ok>{done.message}</Note>;
  }

  return (
    <div>
      {done && !done.ok && <Note ok={false}>{done.message}</Note>}
      <button
        type="button"
        onClick={onTap}
        disabled={pending}
        style={{ background: "var(--accent-chip)", color: "var(--ink)" }}
        className="m-tap m-press min-w-[84px] rounded-full px-4 text-[13px] font-bold disabled:opacity-60"
      >
        {pending ? "…" : "Cancel booking"}
      </button>
      <p className="m-micro mt-1.5 text-ink-3">{notice.line}</p>

      {confirming && (
        <div className="m-card mt-3 p-4" role="alertdialog" aria-label="Confirm cancellation">
          <p className="m-body text-ink">{notice.line}</p>
          <div className="mt-3 flex gap-2">
            <button type="button" onClick={submit} disabled={pending}
              style={{ background: "var(--coral-deep)", color: "#FFFFFF" }}
              className="m-tap m-press rounded-full px-4 text-[13px] font-bold disabled:opacity-60">
              {pending ? "…" : "Cancel anyway"}
            </button>
            <button type="button" onClick={() => setConfirming(false)}
              style={{ background: "var(--accent-chip)", color: "var(--ink)" }}
              className="m-tap m-press rounded-full px-4 text-[13px] font-bold">
              Keep my spot
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
