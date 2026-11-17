"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { refundPayment } from "@/app/staff/members/[id]/refund-actions";

type Props = {
  memberId: string;
  paymentId: string;
  remainingCents: number;
  currency: string;
  isXendit: boolean;
};

function peso(cents: number, ccy: string) {
  const whole = cents % 100 === 0;
  return `${ccy} ${(cents / 100).toLocaleString(undefined, {
    minimumFractionDigits: whole ? 0 : 2, maximumFractionDigits: 2 })}`;
}

/** Decision 111: the refund sheet on a payment. Xendit payments refund through
 *  Xendit (reads "Refund pending" until the webhook confirms); a studio-taken
 *  payment is recorded with a required reference. */
export function RefundSheet({ memberId, paymentId, remainingCents, currency, isXendit }: Props) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [amount, setAmount] = useState(String(remainingCents / 100));
  const [method, setMethod] = useState(isXendit ? "xendit" : "gcash");
  const [reference, setReference] = useState("");
  const [reason, setReason] = useState("");
  const [err, setErr] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);
  const [pending, start] = useTransition();

  if (done) {
    return <span className="text-[12px]" style={{ color: "var(--lime-text)" }}>{done}</span>;
  }
  if (!open) {
    return (
      <button onClick={() => setOpen(true)}
        className="text-[12px] text-ink-2 underline underline-offset-2">Refund</button>
    );
  }
  const studio = method !== "xendit";
  return (
    <div className="mt-2 rounded-lg border border-line-2 bg-surface p-3 text-[12.5px]">
      <div className="flex flex-wrap items-center gap-2">
        <label className="text-ink-2">Amount</label>
        <input value={amount} onChange={(e) => setAmount(e.target.value)}
          inputMode="decimal" className="w-24 rounded border border-line-2 px-2 py-1" />
        <span className="text-ink-3">of {peso(remainingCents, currency)} left</span>
      </div>
      <div className="mt-2 flex flex-wrap items-center gap-2">
        <label className="text-ink-2">Method</label>
        <select value={method} onChange={(e) => setMethod(e.target.value)}
          className="rounded border border-line-2 px-2 py-1">
          {isXendit && <option value="xendit">Xendit (card or GCash)</option>}
          <option value="gcash">GCash (in person)</option>
          <option value="cash">Cash</option>
          <option value="bank_transfer">Bank transfer</option>
          <option value="card_terminal">Card terminal</option>
          <option value="other">Other</option>
        </select>
      </div>
      {studio && (
        <div className="mt-2 flex flex-wrap items-center gap-2">
          <label className="text-ink-2">Reference</label>
          <input value={reference} onChange={(e) => setReference(e.target.value)}
            placeholder="transaction ref" className="w-40 rounded border border-line-2 px-2 py-1" />
        </div>
      )}
      <div className="mt-2 flex flex-wrap items-center gap-2">
        <input value={reason} onChange={(e) => setReason(e.target.value)}
          placeholder="reason (optional)" className="w-56 rounded border border-line-2 px-2 py-1" />
      </div>
      {err && <p className="mt-2 text-[11px]" style={{ color: "var(--coral)" }}>{err}</p>}
      <div className="mt-3 flex items-center gap-2">
        <button disabled={pending}
          onClick={() => start(async () => {
            setErr(null);
            const cents = Math.round(parseFloat(amount || "0") * 100);
            if (!Number.isFinite(cents) || cents <= 0) { setErr("Enter an amount."); return; }
            const full = cents >= remainingCents;
            const r = await refundPayment(
              memberId, paymentId, full ? null : cents, reason || null, method,
              studio ? (reference || null) : null);
            if (!r.ok) { setErr(r.error ?? "Could not refund."); return; }
            setDone(r.status === "pending" ? "Refund pending." : "Refunded.");
            router.refresh();
          })}
          className="rounded-full bg-ink px-4 py-1.5 text-[12px] font-semibold text-paper disabled:opacity-60">
          {pending ? "Refunding…" : "Refund"}
        </button>
        <button onClick={() => setOpen(false)} className="text-[12px] text-ink-2">Cancel</button>
      </div>
    </div>
  );
}
