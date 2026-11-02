"use client";

import { useState, useTransition } from "react";
import { restoreDeskPay } from "./desk-pay-actions";

/**
 * Decision 73 (c) — shown on a member whose pay at the desk is off. States when
 * and why, and offers the one-tap restore (manager-up, enforced in the RPC).
 */
export default function DeskPay({
  memberId, since, reason,
}: {
  memberId: string;
  since: string;
  reason: "no_show" | "late_cancel" | null;
}) {
  const [pending, start] = useTransition();
  const [err, setErr] = useState<string | null>(null);

  const when = new Date(since).toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric" });
  const why = reason === "late_cancel" ? "late cancellation" : "no-show";

  return (
    <div className="mt-4 rounded border border-line bg-surface px-4 py-3">
      <p className="text-[13px] text-ink">
        Pay at the desk is off since {when} ({why}).
      </p>
      <button
        type="button"
        disabled={pending}
        onClick={() =>
          start(async () => {
            setErr(null);
            const r = await restoreDeskPay(memberId);
            if ("error" in r) setErr(r.error);
          })
        }
        className="mt-2 rounded border border-line px-3 py-1 text-[12px] font-semibold text-ink disabled:opacity-50"
      >
        {pending ? "Restoring…" : "Allow pay at the desk again"}
      </button>
      {err && <p className="mt-1.5 text-[12px] text-coral">{err}</p>}
    </div>
  );
}
