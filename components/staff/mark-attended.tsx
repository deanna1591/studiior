"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { markAttended, type MarkAttendedState } from "@/app/staff/roster/attendance-actions";

function Submit({ label }: { label: string }) {
  const { pending } = useFormStatus();
  return (
    <button disabled={pending}
      className="inline-flex items-center rounded border border-line-2 bg-surface px-3 py-1.5 text-[13px] leading-[18px] text-ink hover:bg-paper disabled:opacity-45">
      {pending ? "Saving…" : label}
    </button>
  );
}

/**
 * Decision 35 (a): "Mark attended". `withReason` shows a reason box first (a
 * no-show correction by a manager; required once the day is finalised).
 */
export default function MarkAttended({
  bookingId, occurrenceId, withReason = false, reasonRequired = false,
}: {
  bookingId: string; occurrenceId: string; withReason?: boolean; reasonRequired?: boolean;
}) {
  const [state, action] = useFormState<MarkAttendedState, FormData>(markAttended, null);
  const [open, setOpen] = useState(false);
  if (state && "ok" in state) {
    return <span className="text-[13px] leading-[18px] text-ink-2">{state.ok}</span>;
  }
  if (withReason && !open) {
    return (
      <button type="button" onClick={() => setOpen(true)}
        className="inline-flex items-center rounded border border-line-2 bg-surface px-3 py-1.5 text-[13px] leading-[18px] text-ink hover:bg-paper">
        Mark attended
      </button>
    );
  }
  return (
    <form action={action} className="flex flex-wrap items-center gap-2">
      <input type="hidden" name="booking_id" value={bookingId} />
      <input type="hidden" name="occurrence_id" value={occurrenceId} />
      {withReason && (
        <input name="reason" required={reasonRequired} autoFocus
          placeholder={reasonRequired ? "Why (required)" : "Why (optional)"}
          className="w-[22ch] rounded border border-line-2 bg-surface px-2 py-1.5 text-[13px] text-ink outline-none" />
      )}
      {state && "error" in state && <span className="max-w-[42ch] text-[12px] leading-4 text-ink">{state.error}</span>}
      <Submit label="Mark attended" />
    </form>
  );
}
