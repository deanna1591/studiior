"use client";

import { useState } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { markNoShow, type MarkAttendedState } from "@/app/staff/roster/attendance-actions";

const quiet =
  "inline-flex items-center rounded border border-line-2 bg-surface px-3 py-1.5 text-[13px] leading-[18px] text-ink hover:bg-paper disabled:opacity-45";

function Submit() {
  const { pending } = useFormStatus();
  return (
    <button disabled={pending}
      className="inline-flex items-center rounded px-3 py-1.5 text-[13px] font-semibold leading-[18px] disabled:opacity-45"
      style={{ background: "var(--ink)", color: "var(--surface)" }}>
      {pending ? "Saving…" : "Mark no-show"}
    </button>
  );
}

/**
 * Decision 35 (b): "Mark no-show". A confirm step names the member and what it
 * costs them; `withReason` asks for a reason (required once the day is
 * finalised, manager-up only).
 */
export default function MarkNoShow({
  bookingId, occurrenceId, firstName, withReason = false,
}: {
  bookingId: string; occurrenceId: string; firstName: string; withReason?: boolean;
}) {
  const [state, action] = useFormState<MarkAttendedState, FormData>(markNoShow, null);
  const [open, setOpen] = useState(false);
  if (state && "ok" in state) {
    return <span className="text-[13px] leading-[18px] text-ink-2">{state.ok}</span>;
  }
  if (!open) {
    return <button type="button" onClick={() => setOpen(true)} className={quiet}>Mark no-show</button>;
  }
  return (
    <form action={action} role="dialog" aria-label="Mark no-show"
      className="mt-1 w-full max-w-[44ch] rounded border border-line-2 bg-surface px-3 py-2.5">
      <input type="hidden" name="booking_id" value={bookingId} />
      <input type="hidden" name="occurrence_id" value={occurrenceId} />
      <p className="text-[13px] leading-[18px] text-ink">
        Mark {firstName || "this member"} as a no-show? Their class is used.
      </p>
      {withReason && (
        <input name="reason" required autoFocus placeholder="Why (required)"
          className="mt-2 w-full rounded border border-line-2 bg-surface px-2 py-1.5 text-[13px] text-ink outline-none" />
      )}
      {state && "error" in state && <p className="mt-2 text-[12px] leading-4 text-ink">{state.error}</p>}
      <div className="mt-2 flex items-center gap-2">
        <Submit />
        <button type="button" onClick={() => setOpen(false)} className={quiet}>Cancel</button>
      </div>
    </form>
  );
}
