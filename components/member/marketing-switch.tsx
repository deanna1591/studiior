"use client";

import { useState, useTransition } from "react";
import { setMarketingConsent } from "@/app/member/actions";

/**
 * Decision 114: the Account -> Emails switch for studio news and offers. On
 * turns consent on and clears any one-tap unsubscribe; off turns it off. It
 * flips optimistically and reverts if the server refuses.
 */
export default function MarketingSwitch({ initial }: { initial: boolean }) {
  const [on, setOn] = useState(initial);
  const [pending, start] = useTransition();

  function toggle() {
    const next = !on;
    setOn(next);
    start(async () => {
      const r = await setMarketingConsent(next);
      if ("error" in r) setOn(!next); // revert
    });
  }

  return (
    <label className="flex min-h-[56px] cursor-pointer items-center justify-between gap-4 py-3">
      <span className="m-body text-ink">Studio news and offers</span>
      <button type="button" role="switch" aria-checked={on} aria-label="Studio news and offers"
              onClick={toggle} disabled={pending}
              className="relative h-7 w-12 shrink-0 rounded-full transition-colors"
              style={{ background: on ? "var(--accent-solid)" : "var(--line-2)" }}>
        <span className="absolute top-1 h-5 w-5 rounded-full bg-white transition-all"
              style={{ left: on ? "1.5rem" : "0.25rem" }} />
      </button>
    </label>
  );
}
