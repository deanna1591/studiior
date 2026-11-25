"use client";

import { useState, useTransition } from "react";
import { accentSolid } from "@/lib/accent-pair";
import { claimGuestPlans } from "@/app/member/guest-claim-actions";

/**
 * Decision 118: a plan paid for under this member's email while they were
 * already signed in (or before they verified). One tap adds it; the plan starts
 * today. An intro offer they have already had is refunded instead.
 */
export default function GuestPlansWaiting({ names }: { names: string[] }) {
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<string | null>(null);
  const label = names.length === 1 ? `Your ${names[0]} is paid and waiting` : `${names.length} plans are paid and waiting`;
  return (
    <section className="m-card mb-4 p-4">
      <p className="m-body text-ink">{msg ?? label}</p>
      {!msg && (
        <button type="button" disabled={pending}
          onClick={() => start(async () => {
            const r = await claimGuestPlans();
            setMsg(r.message);
            window.location.reload();
          })}
          className="m-press mt-3 w-full rounded-full py-3 text-center text-[15px] font-semibold disabled:opacity-60"
          style={accentSolid()}>
          {pending ? "One moment…" : "Add it to my account"}
        </button>
      )}
    </section>
  );
}
