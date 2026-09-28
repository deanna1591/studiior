"use client";

import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import { Icon } from "@/components/member/icons";
import { purchaseStatus } from "./actions";

const TERMINAL = ["succeeded", "failed", "expired", "cancelled"];

/**
 * The member lands here from Xendit's hosted checkout (success_return_url). The
 * callback is what actually grants the plan, so we poll our own purchase row
 * until it flips (every 3s, up to 2 minutes) rather than trusting the return.
 */
export default function PurchasePoll({ id, initialStatus }: { id: string; initialStatus: string | null }) {
  const [status, setStatus] = useState<string | null>(initialStatus);
  const [timedOut, setTimedOut] = useState(false);
  const started = useRef(Date.now());

  useEffect(() => {
    if (status && TERMINAL.includes(status)) return;
    let alive = true;
    const tick = async () => {
      if (!alive) return;
      if (Date.now() - started.current > 120_000) { setTimedOut(true); return; }
      const s = await purchaseStatus(id);
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
        <p className="m-sub mt-1 text-ink-2">Your payment went through and your plan is ready.</p>
        <Link href="/account/plan" className="m-press mt-3 inline-block text-lime-text underline underline-offset-4">
          See your plan
        </Link>
      </div>
    );
  }

  if (status && ["failed", "expired", "cancelled"].includes(status)) {
    return (
      <div className="m-card p-5 text-center">
        <p className="text-[16px] font-semibold text-ink">Payment didn’t go through</p>
        <p className="m-sub mt-1 text-ink-2">Nothing was charged and no plan was added.</p>
        <Link href="/account/plan" className="m-press mt-3 inline-block text-lime-text underline underline-offset-4">
          Back to plans
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
        <Link href="/account/plan" className="m-press mt-3 inline-block text-lime-text underline underline-offset-4">
          Back to plans
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
