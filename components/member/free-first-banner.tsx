"use client";

import { useState, useTransition } from "react";
import { dismissFreeFirst } from "@/app/member/actions";
import { Icon } from "@/components/member/icons";

/**
 * Decision 30 — "your first class is on us" at the top of /book, now dismissible.
 * Dismissal is a member_dismissals row (persists per member, across devices), so
 * X'ing it keeps it gone. The offer is not lost: every eligible class row still
 * says "Book — first class free", and when eligibility ends the banner is gone
 * anyway.
 */
export default function FreeFirstBanner() {
  const [hidden, setHidden] = useState(false);
  const [, startTransition] = useTransition();
  if (hidden) return null;

  function dismiss() {
    setHidden(true);
    startTransition(() => { dismissFreeFirst(); });
  }

  return (
    <div className="m-card mb-4 flex items-start gap-2 px-4 py-3">
      <p className="min-w-0 flex-1 text-[14px] leading-5 text-ink">
        <span className="font-semibold">Your first class is on us.</span> Pick any class below — no card, no plan.
      </p>
      <button type="button" onClick={dismiss} aria-label="Dismiss"
              className="m-press -mr-1 -mt-0.5 shrink-0 rounded-full p-1 text-ink-3">
        <Icon name="x" size={16} />
      </button>
    </div>
  );
}
