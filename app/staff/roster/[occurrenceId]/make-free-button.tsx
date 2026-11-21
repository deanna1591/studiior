"use client";

import { useEffect, useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { convertToFreeFirst, type ConvertFreeState } from "../actions";
import { feeTerms, type FeeTerms } from "@/app/staff/members/book-actions";

function Submit({ label }: { label: string }) {
  const { pending } = useFormStatus();
  return (
    <button
      className="inline-flex items-center rounded border border-line-2 bg-surface px-3 py-1.5 text-[12px] leading-[16px] text-ink hover:bg-paper disabled:opacity-45"
      disabled={pending}
    >
      {pending ? "Converting…" : label}
    </button>
  );
}

/**
 * Decision 30 amendment (c). Shown under a live unpaid drop-in on the roster
 * (owners and managers). Converts it, in place, into the member's free first
 * class. Decision 103 (k): when a reservation fee applies the sheet shows it
 * with a waive switch (off by default); the choice is sent with the convert,
 * and convert_booking_to_free_first refuses without one.
 */
export default function MakeFreeButton({ bookingId, occurrenceId, memberId }: {
  bookingId: string; occurrenceId: string; memberId: string;
}) {
  const [state, action] = useFormState<ConvertFreeState, FormData>(convertToFreeFirst, null);
  const [open, setOpen] = useState(false);
  const [terms, setTerms] = useState<FeeTerms>(null);
  const [waive, setWaive] = useState(false);
  const [note, setNote] = useState("");
  useEffect(() => {
    if (!open) return;
    let live = true;
    feeTerms(occurrenceId, memberId).then((t) => { if (live) setTerms(t); }).catch(() => {});
    return () => { live = false; };
  }, [open, occurrenceId, memberId]);

  if (state?.ok) {
    return <p className="mt-1 pl-9 text-[12px] leading-[18px]" style={{ color: "var(--lime-text)" }}>{state.message}</p>;
  }
  if (!open) {
    return (
      <div className="mt-1 pl-9">
        <button onClick={() => setOpen(true)}
                className="inline-flex items-center rounded border border-line-2 bg-surface px-3 py-1.5 text-[12px] leading-[16px] text-ink hover:bg-paper">
          Make this their free class
        </button>
      </div>
    );
  }
  return (
    <form action={action} className="mt-1 pl-9">
      <input type="hidden" name="booking_id" value={bookingId} />
      <input type="hidden" name="occurrence_id" value={occurrenceId} />
      {terms?.required && (
        <div className="mb-2 max-w-md rounded-lg bg-paper px-3 py-2.5" data-testid="fee-line">
          <input type="hidden" name="fee_choice" value={waive ? "waive" : "due"} />
          <p className="text-[13px] text-ink">
            Reservation fee <span className="num font-semibold">{terms.fee_text}</span> due by {terms.deadline_label}
          </p>
          <label className="mt-2 flex items-start gap-2 text-[13px] text-ink-2">
            <input type="checkbox" className="mt-0.5" checked={waive} onChange={(e) => setWaive(e.target.checked)} />
            <span>
              <span className="font-medium text-ink">Waive the reservation fee</span>
              <span className="mt-0.5 block text-[12px] text-ink-3">
                {waive ? "No fee is asked for this booking." : "Off: the pay-to-keep email goes out now."}
              </span>
            </span>
          </label>
          {waive && (
            <input name="fee_note" className="mt-2 w-full rounded-lg border border-line-2 bg-surface px-3 py-2 text-[13px] text-ink"
                   placeholder="Why it is waived (optional)" value={note} onChange={(e) => setNote(e.target.value)} />
          )}
        </div>
      )}
      <div className="flex items-center gap-2">
        <Submit label="Make this their free class" />
        <button type="button" onClick={() => setOpen(false)} className="text-[12px] text-ink-3">Cancel</button>
        {state && !state.ok && <span className="text-[12px] leading-4 text-ink-2">{state.message}</span>}
      </div>
    </form>
  );
}
