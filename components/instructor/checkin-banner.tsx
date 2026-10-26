"use client";

import { useEffect, useState } from "react";

/**
 * Decision 82(a) — the "check everyone in" banner, shown on the roster while the
 * class is live (the server decides that via instructor_roster's `live`). Dismiss
 * is per class and per device — a localStorage key on the occurrence; the class
 * is over within the hour, so a durable store would be the wrong shape.
 */
export default function CheckinBanner({ occurrenceId }: { occurrenceId: string }) {
  const [dismissed, setDismissed] = useState(false);
  const key = `ci-banner:${occurrenceId}`;

  useEffect(() => {
    try { if (localStorage.getItem(key) === "1") setDismissed(true); } catch { /* no storage */ }
  }, [key]);

  if (dismissed) return null;
  return (
    <div className="m-card mb-4 px-4 py-3" style={{ boxShadow: "0 0 0 1.5px var(--lime-text)" }}>
      <div className="flex items-start gap-3">
        <p className="flex-1 text-[14px] leading-[20px] text-ink">
          <span className="font-semibold">Check everyone in</span> — ask members to check in on their
          app, or enter their code / scan their QR below. You&rsquo;re paid on who&rsquo;s checked in.
        </p>
        <button
          type="button"
          aria-label="Dismiss"
          onClick={() => { try { localStorage.setItem(key, "1"); } catch { /* no storage */ } setDismissed(true); }}
          className="m-press -mr-1 -mt-1 shrink-0 p-1 text-[18px] leading-none text-ink-3"
        >
          ×
        </button>
      </div>
    </div>
  );
}
