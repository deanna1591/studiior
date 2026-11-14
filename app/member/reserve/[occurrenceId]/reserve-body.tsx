"use client";

import { useState, useTransition } from "react";
import { startReservation } from "@/app/member/account/plan/actions";

/**
 * Decision 103: Continue to pay. Holds the seat and opens the Xendit session,
 * then navigates to the hosted checkout (a full external navigation, not a
 * server redirect to a member path).
 */
export default function ReserveBody({ occId, feeLabel }: { occId: string; feeLabel: string }) {
  const [pending, start] = useTransition();
  const [err, setErr] = useState<string | null>(null);

  const go = () => start(async () => {
    setErr(null);
    const res = await startReservation(occId);
    if (res?.ok && res.url) { window.location.assign(res.url); return; }
    setErr(res?.message ?? "That didn’t work — please try again.");
  });

  return (
    <div>
      {err && (
        <p className="mb-3 rounded-lg px-3 py-2 text-[12.5px] leading-[18px]"
           style={{ background: "var(--coral-tint)", color: "var(--ink)" }}>{err}</p>
      )}
      <button onClick={go} disabled={pending}
              className="m-press w-full rounded-full py-3.5 text-[15px] font-semibold disabled:opacity-60"
              style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
        {pending ? "Opening checkout…" : `Continue to pay ${feeLabel}`}
      </button>
      <p className="m-micro mt-2 text-center text-ink-3">Card or GCash, on the next screen.</p>
    </div>
  );
}
