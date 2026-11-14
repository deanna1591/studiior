"use client";

import { useState, useTransition } from "react";
import { setReservationFeeWaiver } from "./reservation-fee-actions";

/**
 * Decision 103a — the "No reservation fee" switch on a member profile. Shown
 * only when the studio charges a reservation fee. Manager-up (enforced in the
 * RPC). While on, the member's free class books straight away with no fee.
 */
export default function ReservationFeeWaiver({
  memberId, waived, since, note,
}: {
  memberId: string;
  waived: boolean;
  since: string | null;
  note: string | null;
}) {
  const [pending, start] = useTransition();
  const [err, setErr] = useState<string | null>(null);
  const [draftNote, setDraftNote] = useState("");

  const toggle = (on: boolean, n?: string | null) =>
    start(async () => {
      setErr(null);
      const r = await setReservationFeeWaiver(memberId, on, n ?? null);
      if ("error" in r) setErr(r.error);
    });

  if (waived) {
    const when = since
      ? new Date(since).toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric" })
      : "";
    return (
      <div className="mt-4 rounded border border-line bg-surface px-4 py-3">
        <p className="text-[13px] font-semibold text-ink">No reservation fee</p>
        <p className="mt-0.5 text-[12px] text-ink-2">
          On since {when}. Their free class books with no fee.{note ? ` Note: ${note}` : ""}
        </p>
        <button
          type="button"
          disabled={pending}
          onClick={() => toggle(false)}
          className="mt-2 rounded border border-line px-3 py-1 text-[12px] font-semibold text-ink disabled:opacity-50"
        >
          {pending ? "Saving…" : "Charge the reservation fee again"}
        </button>
        {err && <p className="mt-1.5 text-[12px] text-coral">{err}</p>}
      </div>
    );
  }

  return (
    <div className="mt-4 rounded border border-line bg-surface px-4 py-3">
      <p className="text-[13px] font-semibold text-ink">No reservation fee</p>
      <p className="mt-0.5 text-[12px] text-ink-2">
        Let this member book their free class with no reservation fee.
      </p>
      <input
        value={draftNote}
        onChange={(e) => setDraftNote(e.target.value)}
        placeholder="Note (optional)"
        className="mt-2 w-full rounded border border-line bg-paper px-2 py-1 text-[12px] text-ink"
      />
      <button
        type="button"
        disabled={pending}
        onClick={() => toggle(true, draftNote)}
        className="mt-2 rounded border border-line px-3 py-1 text-[12px] font-semibold text-ink disabled:opacity-50"
      >
        {pending ? "Saving…" : "Waive the reservation fee"}
      </button>
      {err && <p className="mt-1.5 text-[12px] text-coral">{err}</p>}
    </div>
  );
}
