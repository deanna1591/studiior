"use client";

import { useState, useTransition } from "react";
import { resendSetup, refundUnclaimed } from "./actions";

/** Decision 118: Resend setup email / Refund on one unclaimed purchase. */
export default function RowActions({ purchaseId, paymentId, held }: {
  purchaseId: string; paymentId: string | null; held: boolean;
}) {
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<string | null>(null);
  const [confirming, setConfirming] = useState(false);
  if (msg) return <span className="text-[12px] leading-4 text-ink-2">{msg}</span>;
  return (
    <div className="flex flex-wrap items-center gap-2">
      {held && (
        <button type="button" disabled={pending}
          onClick={() => start(async () => setMsg((await resendSetup(purchaseId)).message))}
          className="rounded border border-line-2 bg-surface px-2.5 py-1 text-[12px] font-medium text-ink hover:bg-paper disabled:opacity-60">
          Resend setup email
        </button>
      )}
      {paymentId && (confirming ? (
        <>
          <span className="text-[12px] text-ink-2">Refund in full?</span>
          <button type="button" disabled={pending}
            onClick={() => start(async () => setMsg((await refundUnclaimed(paymentId)).message))}
            className="rounded bg-ink px-2.5 py-1 text-[12px] font-medium text-paper disabled:opacity-60">
            Refund
          </button>
          <button type="button" onClick={() => setConfirming(false)}
            className="text-[12px] text-ink-3 underline underline-offset-4">Keep</button>
        </>
      ) : (
        <button type="button" onClick={() => setConfirming(true)}
          className="rounded border border-line-2 bg-surface px-2.5 py-1 text-[12px] font-medium text-ink hover:bg-paper">
          Refund
        </button>
      ))}
    </div>
  );
}
