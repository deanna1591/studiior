"use client";

import { useFormState, useFormStatus } from "react-dom";
import { checkIn } from "../../actions";

function Submit({ alreadyIn }: { alreadyIn: boolean }) {
  const { pending } = useFormStatus();
  if (alreadyIn) {
    return (
      <span className="inline-flex items-center gap-1.5 text-[13px] leading-[18px] text-ink-2">
        <span className="flex h-4 w-4 items-center justify-center rounded-full bg-lime" aria-hidden>
          <svg width="9" height="9" viewBox="0 0 9 9">
            <path d="M1 4.6l2.2 2.2L8 2" stroke="var(--ink)" strokeWidth="1.6" fill="none"
                  strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </span>
        Checked in
      </span>
    );
  }
  return (
    <button
      className="inline-flex items-center rounded border border-line-2 bg-surface px-3 py-1.5 text-[13px] leading-[18px] text-ink hover:bg-paper disabled:opacity-45"
      disabled={pending}
    >
      {pending ? "Checking in…" : "Check in"}
    </button>
  );
}

export default function CheckInButton({
  bookingId, memberId, occurrenceId, alreadyIn,
}: {
  bookingId: string; memberId: string; occurrenceId: string; alreadyIn: boolean;
}) {
  const [error, action] = useFormState(checkIn, null);

  return (
    <form action={action} className="flex shrink-0 items-center gap-3">
      <input type="hidden" name="booking_id" value={bookingId} />
      <input type="hidden" name="member_id" value={memberId} />
      <input type="hidden" name="occurrence_id" value={occurrenceId} />
      {/* The reason a check-in was refused is the whole message — §8's window
          error names the bound and the way round it. Truncating it would leave
          front desk with "failed" and nothing to do. */}
      {error && <span className="max-w-[42ch] text-[12px] leading-4 text-ink">{error}</span>}
      <Submit alreadyIn={alreadyIn} />
    </form>
  );
}
