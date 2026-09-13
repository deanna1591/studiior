"use client";

import { useFormState, useFormStatus } from "react-dom";
import { signMyWaiver } from "@/app/member/actions";
import type { BookResult } from "@/app/member/actions";

function Sign() {
  const { pending } = useFormStatus();
  return (
    <button type="submit" disabled={pending}
            className="m-tap m-press mt-2 rounded-full px-4 py-2.5 text-[13px] font-bold"
            style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
      {pending ? "Signing…" : "Sign the waiver"}
    </button>
  );
}

/**
 * Decision 26 — a guest brought to a class holds a place that is only confirmed
 * once they sign the waiver. Shown on Home until they do; the desk will not
 * check them in without it.
 */
export default function WaiverBanner({ memberId }: { memberId: string }) {
  const [state, action] = useFormState<BookResult, FormData>(signMyWaiver, null);
  if (state?.ok) {
    return (
      <p className="m-sub mb-4 rounded-xl px-3 py-2.5 text-ink" role="status"
         style={{ background: "var(--accent-chip)" }}>
        Waiver signed — your place is confirmed. See you in class.
      </p>
    );
  }
  return (
    <form action={action} className="m-card mb-4 p-4">
      <p className="m-name text-ink">One thing before your class</p>
      <p className="m-sub mt-1 text-ink-2">
        Please sign the studio waiver. Your place is confirmed once you have — the
        front desk can&rsquo;t check you in without it.
      </p>
      {state && !state.ok && <p className="m-micro mt-2 text-ink-2">{state.message}</p>}
      <input type="hidden" name="member_id" value={memberId} />
      <Sign />
    </form>
  );
}
