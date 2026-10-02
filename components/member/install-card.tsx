"use client";

import Link from "next/link";
import { useEffect, useState, useTransition } from "react";
import { dismissInstallCard } from "@/app/member/actions";

/**
 * Decision 51 — the one-time "Add {studio} to your home screen" card on Home.
 * Hidden once dismissed (a durable member_dismissals row, passed as `dismissed`)
 * AND hidden when the app is already running standalone (installed), via the
 * display-mode media query — which only the client can read, so the card mounts
 * hidden and reveals itself after that check to avoid a flash in the installed app.
 */
export default function InstallCard({ studioName, dismissed }: {
  studioName: string; dismissed: boolean;
}) {
  const [show, setShow] = useState(false);
  const [, start] = useTransition();

  useEffect(() => {
    if (dismissed) return;
    const standalone =
      window.matchMedia?.("(display-mode: standalone)").matches ||
      // iOS Safari's own installed-app flag.
      (window.navigator as unknown as { standalone?: boolean }).standalone === true;
    if (!standalone) setShow(true);
  }, [dismissed]);

  if (!show) return null;

  const close = () => {
    setShow(false);
    start(() => { void dismissInstallCard(); });
  };

  return (
    <div className="m-card mb-4 flex items-center gap-3 p-3.5">
      <div className="min-w-0 flex-1">
        <p className="m-head text-[14px] text-ink">Add {studioName} to your home screen</p>
        <p className="m-sub mt-0.5 text-ink-2">One tap to book, check in and see your plan.</p>
        <Link href="/install" className="m-sub mt-1.5 inline-block font-medium"
              style={{ color: "var(--lime-text)" }}>
          Show me how →
        </Link>
      </div>
      <button onClick={close} aria-label="Dismiss"
              className="m-press shrink-0 rounded-full px-2 py-1 text-[13px] text-ink-3">
        ✕
      </button>
    </div>
  );
}
