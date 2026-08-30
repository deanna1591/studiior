"use client";

import { useFormState, useFormStatus } from "react-dom";
import { bookClass, type BookResult } from "./actions";

function Submit({ full }: { full: boolean }) {
  const { pending } = useFormStatus();
  return (
    <button
      className="rounded bg-stone-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-stone-700 disabled:opacity-50"
      disabled={pending}
    >
      {pending ? "…" : full ? "Join waitlist" : "Book"}
    </button>
  );
}

export default function BookButton({ occurrenceId, full }: { occurrenceId: string; full: boolean }) {
  const [result, action] = useFormState<BookResult, FormData>(bookClass, null);

  return (
    <form action={action} className="flex items-center gap-3">
      <input type="hidden" name="occurrence_id" value={occurrenceId} />
      {result && (
        <span className={`text-xs ${result.ok ? "text-emerald-700" : "text-red-700"}`}>
          {result.message}
        </span>
      )}
      <Submit full={full} />
    </form>
  );
}
