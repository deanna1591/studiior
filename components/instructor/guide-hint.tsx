"use client";

import { useState, useTransition } from "react";
import { Icon } from "@/components/member/icons";
import { GuideText } from "@/components/instructor/guide-ui";

/**
 * Decision 85 — a one-line first-time hint on a screen that matters (the roster,
 * My pay, the class page). Dismissed once and remembered on the instructor's
 * account: the X calls instructor_guide_mark(key), and the parent re-reads
 * hints_seen next render so it does not come back. Optimistic hide so the tap is
 * instant. Ink on the accent tint — the safe pairing on every preset and accent.
 */
export default function GuideHint({
  text, onDismiss,
}: { text: string; onDismiss: () => Promise<void> }) {
  const [hidden, setHidden] = useState(false);
  const [, start] = useTransition();
  if (hidden) return null;
  return (
    <div className="mb-3 flex items-start gap-2 rounded-xl px-3 py-2.5"
         style={{ background: "var(--accent-chip)" }}>
      <span className="min-w-0 flex-1 text-[13px] leading-[22px] text-ink">
        <GuideText text={text} />
      </span>
      <button type="button" aria-label="Got it"
        onClick={() => { setHidden(true); start(() => { onDismiss(); }); }}
        className="-mr-1 -mt-0.5 flex h-6 w-6 shrink-0 items-center justify-center rounded-lg text-ink-2">
        <Icon name="x" size={15} />
      </button>
    </div>
  );
}
