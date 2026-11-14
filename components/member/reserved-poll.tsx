"use client";

import { useEffect } from "react";
import { useRouter } from "next/navigation";

/**
 * Decision 103: the "Finishing your payment…" state. The webhook confirms the
 * reservation a moment after the member returns from Xendit; this refreshes the
 * class page every few seconds (stopping after two minutes) so the "You're in"
 * state appears on its own.
 */
export default function ReservedPoll({ line }: { line: string }) {
  const router = useRouter();
  useEffect(() => {
    const started = Date.now();
    const t = setInterval(() => {
      if (Date.now() - started > 120_000) { clearInterval(t); return; }
      router.refresh();
    }, 4000);
    return () => clearInterval(t);
  }, [router]);

  return (
    <div className="mb-4 flex items-center gap-2 rounded-2xl px-3.5 py-3 text-[13px] leading-[19px]"
         style={{ background: "var(--accent-chip)", color: "var(--ink)" }}>
      <span className="inline-block h-3.5 w-3.5 animate-spin rounded-full border-2 border-current border-t-transparent" />
      {line}
    </div>
  );
}
