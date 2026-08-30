"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice } from "@/components/ui";
import { markStripeStubDone, type ActionState } from "../onboarding-actions";

function Btn() {
  const { pending } = useFormStatus();
  return (
    <button className="rounded border border-line-2 px-3 py-1.5 text-sm hover:border-ink-3 disabled:opacity-50"
            disabled={pending}>
      {pending ? "…" : "Tick this off for now"}
    </button>
  );
}

export default function StripeStub() {
  const [state, action] = useFormState<ActionState, FormData>(markStripeStubDone, null);
  return (
    <form action={action} className="pt-2">
      {state && <Notice kind="error">{state.error}</Notice>}
      <Btn />
      <p className="mt-2 text-xs text-ink-3">
        Marks the checklist item done so it stops nagging. It connects nothing.
      </p>
    </form>
  );
}
