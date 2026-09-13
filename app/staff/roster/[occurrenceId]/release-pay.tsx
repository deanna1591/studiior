"use client";

import { useFormState, useFormStatus } from "react-dom";
import { releasePay, type ReleasePayState } from "../actions";

function Btn() {
  const { pending } = useFormStatus();
  return <button className="rounded border border-line-2 bg-surface px-3 py-1.5 text-[13px] font-medium text-ink disabled:opacity-50" disabled={pending}>{pending ? "Releasing…" : "Release pay"}</button>;
}

/**
 * Shown on the roster when this class's pay is held (the instructor has not
 * checked in). A manager confirms it on their behalf, with a reason.
 */
export default function ReleasePay({ occurrenceId }: { occurrenceId: string }) {
  const [state, action] = useFormState<ReleasePayState, FormData>(releasePay, null);
  if (state?.ok) return <p className="mt-2 text-[12px]" style={{ color: "var(--lime-text)" }}>{state.message}</p>;
  return (
    <form action={action} className="mt-3 flex flex-wrap items-center gap-2 rounded border border-line bg-paper px-3 py-2.5">
      <span className="text-[13px] text-ink">Pay held — the instructor has not checked in.</span>
      <input type="hidden" name="occurrence_id" value={occurrenceId} />
      <input name="reason" placeholder="Reason (e.g. taught it, forgot to tap)"
             className="min-w-[16rem] flex-1 rounded border border-line-2 bg-surface px-2.5 py-1.5 text-[13px] text-ink" />
      <Btn />
      {state && !state.ok && <span className="text-[12px] text-ink-2">{state.message}</span>}
    </form>
  );
}
