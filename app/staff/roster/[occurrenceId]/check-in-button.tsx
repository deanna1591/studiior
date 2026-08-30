"use client";

import { useFormState, useFormStatus } from "react-dom";
import { checkIn } from "../../actions";

function Submit({ alreadyIn }: { alreadyIn: boolean }) {
  const { pending } = useFormStatus();
  if (alreadyIn) {
    return <span className="text-sm font-medium text-emerald-700">Checked in ✓</span>;
  }
  return (
    <button
      className="rounded border border-stone-300 px-3 py-1 text-sm hover:border-stone-500 disabled:opacity-50"
      disabled={pending}
    >
      {pending ? "…" : "Check in"}
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
    <form action={action} className="flex items-center gap-3">
      <input type="hidden" name="booking_id" value={bookingId} />
      <input type="hidden" name="member_id" value={memberId} />
      <input type="hidden" name="occurrence_id" value={occurrenceId} />
      {error && <span className="text-xs text-red-700">{error}</span>}
      <Submit alreadyIn={alreadyIn} />
    </form>
  );
}
