"use client";

import { useFormState, useFormStatus } from "react-dom";
import { Notice, buttonClass } from "@/components/ui";
import { startPlatformCheckout, type BillingState } from "./actions";

function Submit({ hasCard }: { hasCard: boolean }) {
  const { pending } = useFormStatus();
  return (
    <button className={buttonClass} disabled={pending}>
      {pending ? "Opening Stripe…" : hasCard ? "Update payment details" : "Add a card"}
    </button>
  );
}

export default function SubscribeButton({ hasCard }: { hasCard: boolean }) {
  const [state, action] = useFormState<BillingState, FormData>(startPlatformCheckout, null);
  return (
    <form action={action} className="space-y-3">
      {state && !state.ok && <Notice kind="error">{state.message}</Notice>}
      <Submit hasCard={hasCard} />
    </form>
  );
}
