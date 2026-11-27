"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { runAnywayPreview, runCancelledClassAnyway, type RunAnywayPreview } from "@/app/staff/schedule/run-anyway-actions";

/** Decision 21 (g): "Run it anyway" on a class cancelled at its cut-off, with a
 *  confirm sheet listing who comes back. */
export default function RunAnyway({ occurrenceId, className }: { occurrenceId: string; className?: string }) {
  const router = useRouter();
  const [preview, setPreview] = useState<RunAnywayPreview | null>(null);
  const [msg, setMsg] = useState<{ ok?: string; error?: string } | null>(null);
  const [pending, start] = useTransition();

  function open() {
    setMsg(null);
    start(async () => {
      const p = await runAnywayPreview(occurrenceId);
      if ("error" in p) { setMsg({ error: p.error }); return; }
      setPreview(p);
    });
  }
  function run() {
    start(async () => {
      const r = await runCancelledClassAnyway(occurrenceId);
      setPreview(null);
      setMsg(r);
      if ("ok" in r) {
        // The row may leave the page on refresh, so the sentence rides the page toast too.
        window.dispatchEvent(new CustomEvent("studiior:toast", { detail: r.ok }));
        router.refresh();
      }
    });
  }

  const booked = preview?.members.filter((m) => !m.waitlisted) ?? [];
  const waiting = preview?.members.filter((m) => m.waitlisted) ?? [];

  return (
    <div className={className}>
      {!preview && (
        <button type="button" onClick={open} disabled={pending} data-testid="run-anyway"
                className="rounded-full px-3.5 py-1.5 text-[13px] font-semibold disabled:opacity-50"
                style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
          {pending ? "Checking…" : "Run it anyway"}
        </button>
      )}
      {preview && (
        <div className="mt-2 rounded-xl border border-line bg-surface px-3.5 py-3" role="dialog"
             aria-label="Run this class anyway" data-testid="run-anyway-sheet">
          {preview.offered ? (
            <>
              <p className="text-[14px] font-medium text-ink">Run this class anyway?</p>
              <p className="mt-1 text-[13px] leading-[19px] text-ink-2">
                It goes back on the schedule, pinned to run on this date, and the coach is told.
                {booked.length > 0
                  ? ` These ${booked.length === 1 ? "member gets their seat" : `${booked.length} members get their seats`} back, with any free class, fee or credit exactly as before, and one email each:`
                  : " Nobody was booked, so nobody comes back."}
              </p>
              {booked.length > 0 && (
                <ul className="mt-2 space-y-0.5 text-[13px] text-ink">
                  {booked.map((m) => <li key={m.booking_id}>{m.name}</li>)}
                </ul>
              )}
              {waiting.length > 0 && (
                <p className="mt-2 text-[12px] text-ink-3">
                  Back on the waitlist: {waiting.map((m) => m.name).join(", ")}.
                </p>
              )}
              <div className="mt-3 flex gap-2">
                <button type="button" onClick={run} disabled={pending}
                        className="rounded-full px-3.5 py-1.5 text-[13px] font-semibold disabled:opacity-50"
                        style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
                  {pending ? "Running…" : "Run it"}
                </button>
                <button type="button" onClick={() => setPreview(null)} disabled={pending}
                        className="rounded-full border border-line-2 px-3.5 py-1.5 text-[13px] text-ink">
                  Keep it cancelled
                </button>
              </div>
            </>
          ) : (
            <p className="text-[13px] text-ink-2">
              {preview.reason === "started" ? "This class has started." : "This class cannot be run anyway."}
            </p>
          )}
        </div>
      )}
      {msg && (
        <p className={`mt-2 text-[13px] ${msg.error ? "text-ink-2" : "text-lime-text"}`} role="status">
          {msg.ok ?? msg.error}
        </p>
      )}
    </div>
  );
}
