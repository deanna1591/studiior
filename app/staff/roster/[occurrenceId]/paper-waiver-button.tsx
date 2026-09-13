"use client";

import { useFormState, useFormStatus } from "react-dom";
import { recordPaperWaiver, type PaperWaiverState } from "../actions";

function Submit() {
  const { pending } = useFormStatus();
  return (
    <button
      className="inline-flex items-center rounded border border-line-2 bg-surface px-3 py-1.5 text-[12px] leading-[16px] text-ink hover:bg-paper disabled:opacity-45"
      disabled={pending}
    >
      {pending ? "Recording…" : "Waiver signed on paper"}
    </button>
  );
}

/**
 * Shown under an unsigned guest on the roster. The desk hands them the form,
 * they sign, and this records it — confirming the pass and clearing check-in.
 */
export default function PaperWaiverButton({ memberId, occurrenceId }: {
  memberId: string; occurrenceId: string;
}) {
  const [state, action] = useFormState<PaperWaiverState, FormData>(recordPaperWaiver, null);
  if (state?.ok) {
    return <p className="mt-1 pl-9 text-[12px] leading-[18px]" style={{ color: "var(--lime-text)" }}>{state.message}</p>;
  }
  return (
    <form action={action} className="mt-1 flex items-center gap-2 pl-9">
      <input type="hidden" name="member_id" value={memberId} />
      <input type="hidden" name="occurrence_id" value={occurrenceId} />
      <Submit />
      {state && !state.ok && <span className="text-[12px] leading-4 text-ink-2">{state.message}</span>}
    </form>
  );
}
