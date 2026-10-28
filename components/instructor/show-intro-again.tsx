"use client";

import { useTransition } from "react";

/**
 * Decision 85 — "Show the intro again" on Me. Clears guide_seen_at
 * (instructor_guide_mark('reset')) and sends the instructor to Home, where the
 * five-card intro shows again because the flag is null.
 */
export default function ShowIntroAgain({ onReset }: { onReset: () => Promise<void> }) {
  const [pending, start] = useTransition();
  return (
    <button type="button" disabled={pending}
      onClick={() => start(async () => { await onReset(); window.location.assign("/instructor"); })}
      className="m-sub mt-3 inline-block underline underline-offset-4 disabled:opacity-60"
      style={{ color: "var(--accent-text)" }}>
      Show the intro again
    </button>
  );
}
