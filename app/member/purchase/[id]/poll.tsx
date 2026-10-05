"use client";

import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import { Icon } from "@/components/member/icons";
import { purchaseStatus, confirmWithXendit } from "./actions";

const TERMINAL = ["succeeded", "failed", "expired", "cancelled"];

/**
 * The member lands here from Xendit's hosted checkout (success_return_url). The
 * callback is the primary path that grants the plan, so we poll our own purchase
 * row every 3s (up to 2 minutes). As a BELT (Decision 40 amendment 8) we ask
 * Xendit directly on every OTHER tick — confirmWithXendit is server-rate-limited
 * to once per 5s per purchase, so a ~6s cadence never over-asks — which recovers
 * a payment whose webhook was late or never delivered.
 */
export default function PurchasePoll({ id, initialStatus, kind = "plan" }:
  { id: string; initialStatus: string | null; kind?: "plan" | "product" }) {
  const isProduct = kind === "product";
  const backHref = isProduct ? "/shop" : "/account/plan";
  const backLabel = isProduct ? "Back to the shop" : "Back to plans";
  const [status, setStatus] = useState<string | null>(initialStatus);
  const [timedOut, setTimedOut] = useState(false);
  const started = useRef(Date.now());
  const ticks = useRef(0);

  useEffect(() => {
    if (status && TERMINAL.includes(status)) return;
    let alive = true;
    const tick = async () => {
      if (!alive) return;
      if (Date.now() - started.current > 120_000) { setTimedOut(true); return; }
      // Even ticks ask Xendit directly (the belt); odd ticks read our own row
      // (catches a webhook that landed in between).
      const n = ticks.current++;
      const s = n % 2 === 0 ? await confirmWithXendit(id) : await purchaseStatus(id);
      if (!alive) return;
      if (s) setStatus(s);
      if (!s || !TERMINAL.includes(s)) setTimeout(tick, 3000);
    };
    const t = setTimeout(tick, 3000);
    return () => { alive = false; clearTimeout(t); };
  }, [id, status]);

  if (status === "succeeded") {
    return (
      <div className="m-card p-5 text-center">
        <div className="mx-auto mb-2 flex h-11 w-11 items-center justify-center rounded-full"
             style={{ background: "var(--accent-chip)", color: "var(--ink)" }}>
          <Icon name="tick" size={22} />
        </div>
        <p className="text-[16px] font-semibold text-ink">You’re all set</p>
        <p className="m-sub mt-1 text-ink-2">
          {isProduct
            ? "Your payment went through. Pick it up at the front desk whenever suits you."
            : "Your payment went through and your plan is ready."}
        </p>
        <Link href={isProduct ? "/account/orders" : "/account/plan"}
              className="m-press mt-3 inline-block text-lime-text underline underline-offset-4">
          {isProduct ? "See your orders" : "See your plan"}
        </Link>
      </div>
    );
  }

  if (status && ["failed", "expired", "cancelled"].includes(status)) {
    return (
      <div className="m-card p-5 text-center">
        <p className="text-[16px] font-semibold text-ink">Payment didn’t go through</p>
        <p className="m-sub mt-1 text-ink-2">
          {isProduct ? "Nothing was charged." : "Nothing was charged and no plan was added."}
        </p>
        <Link href={backHref} className="m-press mt-3 inline-block text-lime-text underline underline-offset-4">
          {backLabel}
        </Link>
      </div>
    );
  }

  if (timedOut) {
    return (
      <div className="m-card p-5 text-center">
        <p className="text-[16px] font-semibold text-ink">Still confirming your payment</p>
        <p className="m-sub mt-1 text-ink-2">
          This is taking longer than usual. If you completed the payment, we’ll email you once it’s confirmed —
          you don’t need to pay again.
        </p>
        <Link href={backHref} className="m-press mt-3 inline-block text-lime-text underline underline-offset-4">
          {backLabel}
        </Link>
      </div>
    );
  }

  return (
    <div className="m-card p-5 text-center">
      <div className="mx-auto mb-3 h-6 w-6 animate-spin rounded-full border-2 border-line border-t-ink" />
      <p className="text-[16px] font-semibold text-ink">Confirming your payment…</p>
      <p className="m-sub mt-1 text-ink-2">One moment — this usually takes a few seconds.</p>
    </div>
  );
}
