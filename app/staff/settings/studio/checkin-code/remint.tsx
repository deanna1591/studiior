"use client";

import { useFormState, useFormStatus } from "react-dom";
import { remintCheckinCode, type PlainState } from "../../actions";

function Btn() {
  const { pending } = useFormStatus();
  return (
    <button
      className="rounded border border-line px-3 py-1.5 text-[13px] font-medium text-ink hover:bg-paper"
      disabled={pending}
      onClick={(e) => {
        if (!window.confirm("Re-mint the check-in code? The current printout will stop working the moment you do.")) {
          e.preventDefault();
        }
      }}
    >
      {pending ? "Minting…" : "Re-mint code"}
    </button>
  );
}

/** Decision 35 §3 — re-mint, behind a confirm. The print-only CSS hides this. */
export default function RemintCode() {
  const [state, action] = useFormState<PlainState, FormData>(remintCheckinCode, null);
  return (
    <form action={action} className="no-print mt-6">
      <Btn />
      {state && (
        <p className={`mt-2 text-[12px] leading-[18px] ${state.ok ? "text-ink-2" : "text-ink"}`}
           role={state.ok ? "status" : "alert"}>
          {state.message}
        </p>
      )}
    </form>
  );
}
