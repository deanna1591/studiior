"use client";

import { useFormState, useFormStatus } from "react-dom";
import { confirmClass, type InstructorState } from "./actions";

function Btn() {
  const { pending } = useFormStatus();
  return (
    <button type="submit" disabled={pending}
            className="m-tap m-press mt-2 w-full rounded-xl py-2.5 text-[13px] font-bold"
            style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}>
      {pending ? "Checking in…" : "Check in — your pay depends on it"}
    </button>
  );
}

/**
 * Decision 28: the obvious thing to do on a class you are teaching, because the
 * pay depends on it. Shown only while the window is open and you have not tapped.
 */
export default function PayCheckIn({ occurrenceId }: { occurrenceId: string }) {
  const [state, action] = useFormState<InstructorState, FormData>(confirmClass, null);
  if (state && "ok" in state) {
    return <p className="mt-2 text-[12px] font-medium" style={{ color: "var(--lime-text)" }}>Checked in for pay ✓</p>;
  }
  return (
    <form action={action}>
      <input type="hidden" name="occurrence_id" value={occurrenceId} />
      {state && "error" in state && <p className="mb-1 text-[12px] text-ink-2">{state.error}</p>}
      <Btn />
    </form>
  );
}
