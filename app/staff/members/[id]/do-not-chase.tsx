"use client";

import { useState, useTransition } from "react";
import { setDoNotChase } from "./do-not-chase-actions";

/**
 * Decision 112 — a per-member "do not send campaign emails" switch. Separate
 * from marketing consent: a member can be happy to hear news but marked to be
 * left out of the weekly nudges. Manager-up (the RPC/RLS is the boundary).
 */
export default function DoNotChase({ memberId, on }: { memberId: string; on: boolean }) {
  const [cur, setCur] = useState(on);
  const [pending, start] = useTransition();
  const [err, setErr] = useState<string | null>(null);
  return (
    <div className="mt-4 rounded border border-line bg-surface px-4 py-3">
      <label className="flex items-start gap-2.5">
        <input type="checkbox" className="mt-1" checked={cur} disabled={pending}
          onChange={(e) => {
            const next = e.target.checked;
            start(async () => {
              setErr(null);
              const r = await setDoNotChase(memberId, next);
              if ("error" in r) setErr(r.error); else setCur(next);
            });
          }} />
        <span className="text-[13px] leading-[19px] text-ink">
          <span className="font-medium">Don't send campaign emails</span>
          <span className="block text-[12px] leading-[18px] text-ink-3">
            Leave this member out of the weekly campaign nudges. Booking and account emails are
            unaffected.
          </span>
        </span>
      </label>
      {err && <p className="mt-1.5 text-[12px] text-coral">{err}</p>}
    </div>
  );
}
