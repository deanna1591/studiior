"use client";

import { useEffect } from "react";
import { useFormState, useFormStatus } from "react-dom";
import { buyPlan, type BuyState } from "./actions";

function BuyButton() {
  const { pending } = useFormStatus();
  return (
    <button
      disabled={pending}
      style={{ background: "var(--accent-solid)", color: "var(--accent-on-solid)" }}
      className="m-tap m-press shrink-0 rounded-full px-4 text-[13px] font-bold disabled:opacity-60"
    >
      {pending ? "Opening…" : "Buy"}
    </button>
  );
}

/** Decision 40: Buy a one-time plan online. On success we get the Xendit hosted
 *  checkout URL and navigate to it (full external navigation). */
export default function BuyPlan({ planId }: { planId: string }) {
  const [state, action] = useFormState<BuyState, FormData>(buyPlan, null);
  useEffect(() => {
    if (state?.ok && state.url) window.location.assign(state.url);
  }, [state]);
  return (
    <form action={action}>
      <input type="hidden" name="plan_id" value={planId} />
      <BuyButton />
      {state && !state.ok && state.message && (
        <p className="m-sub mt-1 text-coral">{state.message}</p>
      )}
    </form>
  );
}
