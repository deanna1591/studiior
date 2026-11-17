"use client";

import { useEffect, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { holdCountdownText } from "@/lib/reservation-hold";
import { releaseHold } from "@/app/staff/roster/actions";

type Hold = { id: string; holdUntil: string; name: string };

/**
 * Decision 26(e): a payment hold on the roster. The row reads
 * "Payment pending, mm:ss left", counting down live to zero on the same clock
 * the member sees; at zero it reads "Hold ended, fee not received, releasing"
 * until the sweep frees the seat and the row disappears. A Release hold button
 * (desk-up) frees the seat at once.
 */
function HoldRow({ hold, canRelease }: { hold: Hold; canRelease: boolean }) {
  const router = useRouter();
  // null until mounted: the server and the client's first paint both render the
  // plain "Payment pending" placeholder, so there is no hydration mismatch
  // (server-time and client-time differ). The clock starts after mount.
  const [now, setNow] = useState<number | null>(null);
  const [pending, start] = useTransition();
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    setNow(Date.now());
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, []);

  const label = now === null ? "Payment pending" : holdCountdownText(hold.holdUntil, now);
  return (
    <div className="flex items-center justify-between gap-4 px-3 py-2.5">
      <div className="min-w-0">
        <div className="truncate text-[14px] text-ink">{hold.name}</div>
        <div className="num text-[12px] text-ink-2">{label}</div>
      </div>
      {canRelease && (
        <div className="flex items-center gap-2">
          {err && <span className="text-[11px] text-ink-2">{err}</span>}
          <button
            disabled={pending}
            onClick={() =>
              start(async () => {
                setErr(null);
                const r = await releaseHold(hold.id);
                if (!r.ok) { setErr(r.error ?? "Could not release."); return; }
                router.refresh();
              })}
            className="rounded-full border border-line-2 bg-surface px-3 py-1 text-[12px] font-semibold text-ink disabled:opacity-60">
            {pending ? "Releasing…" : "Release hold"}
          </button>
        </div>
      )}
    </div>
  );
}

export function HoldRows({ holds, canRelease }: { holds: Hold[]; canRelease: boolean }) {
  if (holds.length === 0) return null;
  return (
    <section className="mt-4">
      <h3 className="mb-1 text-[12px] font-semibold uppercase tracking-wide text-ink-3">Payment holds</h3>
      <div className="rounded-xl bg-surface shadow-[0_1px_2px_rgba(0,0,0,.04)] divide-y divide-line">
        {holds.map((h) => <HoldRow key={h.id} hold={h} canRelease={canRelease} />)}
      </div>
    </section>
  );
}
