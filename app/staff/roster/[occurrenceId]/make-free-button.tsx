"use client";

import { useFormState, useFormStatus } from "react-dom";
import { convertToFreeFirst, type ConvertFreeState } from "../actions";

function Submit() {
  const { pending } = useFormStatus();
  return (
    <button
      className="inline-flex items-center rounded border border-line-2 bg-surface px-3 py-1.5 text-[12px] leading-[16px] text-ink hover:bg-paper disabled:opacity-45"
      disabled={pending}
    >
      {pending ? "Converting…" : "Make this their free class"}
    </button>
  );
}

/**
 * Decision 30 amendment (c). Shown under a live unpaid drop-in on the roster
 * (owners and managers). Converts it, in place, into the member's free first
 * class — the booking becomes a confirmed free seat and free_booking_confirmed is
 * queued. convert_booking_to_free_first is the boundary; refusals show inline.
 */
export default function MakeFreeButton({ bookingId, occurrenceId }: {
  bookingId: string; occurrenceId: string;
}) {
  const [state, action] = useFormState<ConvertFreeState, FormData>(convertToFreeFirst, null);
  if (state?.ok) {
    return <p className="mt-1 pl-9 text-[12px] leading-[18px]" style={{ color: "var(--lime-text)" }}>{state.message}</p>;
  }
  return (
    <form action={action} className="mt-1 flex items-center gap-2 pl-9">
      <input type="hidden" name="booking_id" value={bookingId} />
      <input type="hidden" name="occurrence_id" value={occurrenceId} />
      <Submit />
      {state && !state.ok && <span className="text-[12px] leading-4 text-ink-2">{state.message}</span>}
    </form>
  );
}
